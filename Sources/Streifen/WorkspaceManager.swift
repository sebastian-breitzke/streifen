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
        let knownIds = Set(workspaces.values.flatMap { $0.windows.map { $0.windowId } })
        let ws = activeWorkspace
        var added = false

        // Insert new windows after the focused window
        for window in windows {
            if !knownIds.contains(window.windowId) {
                let insertIdx = min(ws.focusIndex + 1, ws.windows.count)
                ws.windows.insert(window, at: insertIdx)
                ws.focusIndex = insertIdx
                added = true
            }
        }

        // Remove windows that no longer exist
        let currentIds = Set(windows.map { $0.windowId })
        var removed = false
        for workspace in workspaces.values {
            let before = workspace.windows.count
            workspace.windows.removeAll { !currentIds.contains($0.windowId) }
            if workspace.windows.count != before { removed = true }
        }

        // Clamp focus index
        if ws.focusIndex >= ws.windows.count {
            ws.focusIndex = max(0, ws.windows.count - 1)
        }

        // Re-layout and center on new window
        if added || removed {
            if added {
                ensureWindowVisible(at: ws.focusIndex)
            } else {
                layoutActiveWorkspace()
            }
        }

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
        guard targetId != activeWorkspaceId else { return }
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

        // Clamp focus index and re-layout source workspace
        let ws = activeWorkspace
        if ws.focusIndex >= ws.windows.count {
            ws.focusIndex = max(0, ws.windows.count - 1)
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

        // Calculate where window sits in the strip (sum of previous widths)
        let gap = config.gap
        var windowX: CGFloat = gap
        for i in 0..<index {
            let w = screen.width * ws.windows[i].widthRatio - (2 * gap)
            windowX += max(w, 200) + gap
        }
        let windowWidth = max(screen.width * ws.windows[index].widthRatio - (2 * gap), 200)

        // Center: scroll so the window's center aligns with screen center
        let windowCenter = windowX + windowWidth / 2
        let screenCenter = screen.width / 2
        ws.scrollOffset = screenCenter - windowCenter

        layoutActiveWorkspace()
    }

    // MARK: - App Focus (Cmd+Tab etc.)

    func handleAppActivated(_ app: NSRunningApplication) {
        let ws = activeWorkspace
        let pid = app.processIdentifier

        // Find first window of this app in active workspace
        guard let idx = ws.windows.firstIndex(where: { $0.app.processIdentifier == pid }) else { return }

        ws.focusIndex = idx
        ensureWindowVisible(at: idx)
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

    /// Step width up/down through presets with snap-to-nearest
    /// Presets: 1/4, 1/3, 1/2, 2/3, 3/4, 1
    func widthStep(up: Bool) {
        let ws = activeWorkspace
        guard ws.focusIndex < ws.windows.count else { return }
        let window = ws.windows[ws.focusIndex]

        let presets = HotkeyManager.widthPresets
        let nearest = HotkeyManager.nearestPresetIndex(for: window.widthRatio)

        let nextIdx: Int
        if up {
            nextIdx = min(nearest + 1, presets.count - 1)
        } else {
            nextIdx = max(nearest - 1, 0)
        }

        // Only step if we're actually moving (handle case where nearest == current)
        if abs(window.widthRatio - presets[nearest]) > 0.02 {
            // Not on a preset — snap to nearest first
            window.widthRatio = presets[up ? min(nearest + 1, presets.count - 1) : nearest]
        } else {
            window.widthRatio = presets[nextIdx]
        }

        layoutActiveWorkspace()
    }

    // MARK: - Layout

    func layoutCurrentWorkspace() {
        layoutActiveWorkspace()
    }

    private func layoutActiveWorkspace() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        windowTracker?.beginProgrammaticUpdate()
        stripLayout?.layout(workspace: activeWorkspace, screenFrame: screen, config: config)
        // Delay re-enabling observer to let AX notifications drain
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.windowTracker?.endProgrammaticUpdate()
        }
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
