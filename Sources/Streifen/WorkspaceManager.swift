import Cocoa

@MainActor
final class Workspace {
    let id: Int
    var windows: [TrackedWindow] = []
    var scrollOffset: CGFloat = 0
    var focusIndex: Int = 0

    init(id: Int) {
        self.id = id
    }

    var isVisible: Bool = false
}

@MainActor
final class WorkspaceManager {
    private(set) var workspaces: [Int: Workspace] = [:]
    private(set) var activeWorkspaceId: Int = 1
    var config: StreifenConfig

    private weak var windowTracker: WindowTracker?
    private var stripLayout: StripLayout?

    init(config: StreifenConfig) {
        self.config = config
        for i in 1...9 {
            workspaces[i] = Workspace(id: i)
        }
        workspaces[1]?.isVisible = true

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSwitchNotification(_:)),
            name: .switchWorkspace, object: nil
        )
    }

    func setWindowTracker(_ tracker: WindowTracker) {
        self.windowTracker = tracker
    }

    func setStripLayout(_ layout: StripLayout) {
        self.stripLayout = layout
    }

    var activeWorkspace: Workspace {
        workspaces[activeWorkspaceId]!
    }

    // MARK: - Window Updates

    func handleWindowsUpdate(_ windows: [TrackedWindow]) {
        // Assign new windows to active workspace
        let knownIds = Set(workspaces.values.flatMap { $0.windows.map { $0.windowId } })

        for window in windows {
            if !knownIds.contains(window.windowId) {
                activeWorkspace.windows.append(window)
            }
        }

        // Remove windows that no longer exist
        let currentIds = Set(windows.map { $0.windowId })
        for ws in workspaces.values {
            ws.windows.removeAll { !currentIds.contains($0.windowId) }
        }

        layoutActiveWorkspace()
        updateMenuBar()
    }

    // MARK: - Workspace Switching

    func switchTo(workspace targetId: Int) {
        guard targetId >= 1 && targetId <= 9 else { return }
        guard targetId != activeWorkspaceId else { return }

        windowTracker?.beginProgrammaticUpdate()

        // Hide current workspace windows (off-screen)
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let offscreen = CGPoint(x: screen.maxX + screen.width, y: screen.maxY + screen.height)

        for window in activeWorkspace.windows {
            window.setPosition(offscreen)
        }
        activeWorkspace.isVisible = false

        // Show target workspace
        activeWorkspaceId = targetId
        activeWorkspace.isVisible = true

        // Layout and position target workspace windows
        layoutActiveWorkspace()

        windowTracker?.endProgrammaticUpdate()
        updateMenuBar()

        NSLog("[Streifen] Switched to workspace \(targetId)")
    }

    // MARK: - Move Window to Workspace

    func moveWindow(_ window: TrackedWindow, toWorkspace targetId: Int) {
        guard targetId >= 1 && targetId <= 9 else { return }
        guard let targetWs = workspaces[targetId] else { return }

        // Remove from current workspace
        for ws in workspaces.values {
            ws.windows.removeAll { $0.windowId == window.windowId }
        }

        // Add to target
        targetWs.windows.append(window)

        // If target is not visible, move off-screen
        if !targetWs.isVisible {
            let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
            let offscreen = CGPoint(x: screen.maxX + screen.width, y: screen.maxY + screen.height)
            windowTracker?.beginProgrammaticUpdate()
            window.setPosition(offscreen)
            windowTracker?.endProgrammaticUpdate()
        }

        layoutActiveWorkspace()
        updateMenuBar()
    }

    // MARK: - Focus Navigation

    func focusLeft() {
        let ws = activeWorkspace
        guard !ws.windows.isEmpty else { return }
        ws.focusIndex = max(0, ws.focusIndex - 1)
        focusCurrentWindow()
    }

    func focusRight() {
        let ws = activeWorkspace
        guard !ws.windows.isEmpty else { return }
        ws.focusIndex = min(ws.windows.count - 1, ws.focusIndex + 1)
        focusCurrentWindow()
    }

    private func focusCurrentWindow() {
        let ws = activeWorkspace
        guard ws.focusIndex < ws.windows.count else { return }
        let window = ws.windows[ws.focusIndex]

        // Raise and focus
        do {
            try window.axElement.setAttribute(.main, value: true)
            window.app.activate()
        } catch {
            NSLog("[Streifen] Focus failed: \(error)")
        }

        // Scroll strip to ensure focused window is visible
        ensureWindowVisible(at: ws.focusIndex)
    }

    private func ensureWindowVisible(at index: Int) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let ws = activeWorkspace
        guard index < ws.windows.count else { return }
        let window = ws.windows[index]

        // If window is off-screen to the left, scroll right
        if window.frame.origin.x < screen.origin.x {
            ws.scrollOffset += screen.origin.x - window.frame.origin.x + config.gap
            layoutActiveWorkspace()
        }
        // If window is off-screen to the right
        else if window.frame.maxX > screen.maxX {
            ws.scrollOffset -= window.frame.maxX - screen.maxX + config.gap
            layoutActiveWorkspace()
        }
    }

    // MARK: - Width Cycling

    func cycleWidth(reverse: Bool = false) {
        let ws = activeWorkspace
        guard ws.focusIndex < ws.windows.count else { return }
        let window = ws.windows[ws.focusIndex]

        let widths = config.cycleWidths
        guard !widths.isEmpty else { return }

        if let currentIdx = widths.firstIndex(where: { abs($0 - window.widthRatio) < 0.01 }) {
            let nextIdx = reverse
                ? (currentIdx - 1 + widths.count) % widths.count
                : (currentIdx + 1) % widths.count
            window.widthRatio = widths[nextIdx]
        } else {
            window.widthRatio = widths[0]
        }

        layoutActiveWorkspace()
    }

    func toggleFullWidth() {
        let ws = activeWorkspace
        guard ws.focusIndex < ws.windows.count else { return }
        let window = ws.windows[ws.focusIndex]

        if abs(window.widthRatio - 1.0) < 0.01 {
            window.widthRatio = config.cycleWidths.first ?? 0.50
        } else {
            window.widthRatio = 1.0
        }

        layoutActiveWorkspace()
    }

    // MARK: - Layout

    private func layoutActiveWorkspace() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        stripLayout?.layout(workspace: activeWorkspace, screenFrame: screen, config: config)
    }

    // MARK: - Crash Safety

    func restoreAllWindowsOnScreen() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let startX = screen.origin.x + 20
        let startY = screen.origin.y + 20

        for ws in workspaces.values {
            for (i, window) in ws.windows.enumerated() {
                let offset = CGFloat(i) * 30
                window.setPosition(CGPoint(x: startX + offset, y: startY + offset))
            }
        }
    }

    // MARK: - Menu Bar

    private func updateMenuBar() {
        var counts: [Int: Int] = [:]
        var total = 0
        for (id, ws) in workspaces {
            counts[id] = ws.windows.count
            total += ws.windows.count
        }

        MenuBarViewModel.shared.update(
            activeWorkspace: activeWorkspaceId,
            windowCounts: counts,
            total: total
        )
    }

    // MARK: - Notification

    @objc private func handleSwitchNotification(_ notification: Notification) {
        guard let ws = notification.userInfo?["workspace"] as? Int else { return }
        switchTo(workspace: ws)
    }
}
