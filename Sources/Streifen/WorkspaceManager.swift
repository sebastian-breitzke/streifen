import Cocoa
import AXSwift

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
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleResetNotification),
            name: .resetAllWorkspaces, object: nil
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

    // MARK: - Initial Sort

    /// Sort all windows into workspaces at startup based on pinned config
    func initialSort(_ windows: [TrackedWindow]) {
        windowTracker?.beginProgrammaticUpdate()
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let offscreen = CGPoint(x: screen.maxX + screen.width, y: screen.maxY + screen.height)

        // Track which pinned bundle IDs already have their first window placed
        var pinnedPlaced: Set<String> = []

        for window in windows {
            let bundleId = window.bundleId ?? ""
            let targetWs: Workspace

            if let pinnedWsId = config.pinnedApps[bundleId],
               let pinnedWs = workspaces[pinnedWsId],
               !pinnedPlaced.contains(bundleId) {
                targetWs = pinnedWs
                pinnedPlaced.insert(bundleId)
            } else {
                targetWs = activeWorkspace
            }

            targetWs.windows.append(window)

            if targetWs !== activeWorkspace {
                window.setPosition(offscreen)
            }
        }

        layoutActiveWorkspace()
        windowTracker?.endProgrammaticUpdate()
        updateMenuBar()

        // Log assignment details
        for (wsId, ws) in workspaces.sorted(by: { $0.key < $1.key }) where !ws.windows.isEmpty {
            let names = ws.windows.map { "\($0.app.localizedName ?? "?")(\($0.windowId))" }.joined(separator: ", ")
            slog("  WS \(wsId): \(names)")
        }
        slog("Initial sort: \(windows.count) windows")
    }

    // MARK: - Window Updates

    func handleWindowsUpdate(_ windows: [TrackedWindow]) {
        let knownIds = Set(workspaces.values.flatMap { $0.windows.map { $0.windowId } })
        let ws = activeWorkspace
        var added = false

        // Insert new windows — pinned apps go to their workspace (first window only)
        for window in windows {
            if !knownIds.contains(window.windowId) {
                let bundleId = window.bundleId ?? ""
                let targetWs: Workspace

                if let pinnedWsId = config.pinnedApps[bundleId],
                   let pinnedWs = workspaces[pinnedWsId],
                   !pinnedWs.windows.contains(where: { $0.bundleId == bundleId }) {
                    // First window of pinned app → target workspace
                    targetWs = pinnedWs
                } else {
                    // Normal + additional pinned windows → active workspace
                    targetWs = ws
                }

                let insertIdx = (targetWs === ws)
                    ? min(ws.focusIndex + 1, ws.windows.count)
                    : targetWs.windows.count
                targetWs.windows.insert(window, at: insertIdx)

                if targetWs === ws {
                    ws.focusIndex = insertIdx
                }

                // If target is not the active workspace, move off-screen
                if targetWs !== ws {
                    let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
                    let offscreen = CGPoint(x: screen.maxX + screen.width, y: screen.maxY + screen.height)
                    window.setPosition(offscreen)
                }

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

        // Sync widthRatio from actual window size (manual resize)
        var resized = false
        if !added && !removed, let screen = NSScreen.main?.visibleFrame {
            for window in ws.windows {
                let actualRatio = (window.frame.width + 2 * config.gap) / screen.width
                if abs(actualRatio - window.widthRatio) > 0.02 {
                    window.widthRatio = actualRatio
                    resized = true
                }
            }
        }

        // Re-layout strip
        if added || removed || resized {
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

        saveState()
        slog("Switched to workspace \(targetId)")
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
            slog("Focus failed: \(error)")
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

        // Scroll-into-view: only scroll if focused window isn't fully visible
        // Tolerance of 5px to avoid scrolling on rounding errors
        let tolerance: CGFloat = 5
        let currentLeft = windowX + ws.scrollOffset
        let currentRight = currentLeft + windowWidth
        let screenLeft = gap
        let screenRight = screen.width - gap

        if currentLeft < screenLeft - tolerance {
            // Window is off-screen left — scroll right to show its left edge
            ws.scrollOffset += screenLeft - currentLeft
        } else if currentRight > screenRight + tolerance {
            // Window is off-screen right — scroll left to show its right edge
            ws.scrollOffset -= currentRight - screenRight
        }
        // else: already fully visible, don't scroll

        layoutActiveWorkspace()
    }

    // MARK: - App Focus (Cmd+Tab etc.)

    func handleAppActivated(_ app: NSRunningApplication) {
        // App-level activation — try to find focused window via AX
        let pid = app.processIdentifier
        guard let appElement = AXSwift.Application(forProcessID: pid),
              let focusedWindow: UIElement = try? appElement.attribute(.focusedWindow),
              let wid = getWindowId(from: focusedWindow) else {
            // Fallback: find first window of this app in active workspace
            let ws = activeWorkspace
            if let idx = ws.windows.firstIndex(where: { $0.app.processIdentifier == pid }) {
                ws.focusIndex = idx
                ensureWindowVisible(at: idx)
            }
            return
        }
        handleWindowFocused(windowId: wid)
    }

    func handleWindowFocused(windowId: CGWindowID) {
        let ws = activeWorkspace

        // Already in active workspace? Just update focus index.
        if let idx = ws.windows.firstIndex(where: { $0.windowId == windowId }) {
            ws.focusIndex = idx
            ensureWindowVisible(at: idx)
            return
        }

        // Find which workspace has this window
        guard let (sourceWsId, sourceWs, window) = findWindow(byId: windowId) else { return }
        let bundleId = window.bundleId ?? ""

        // Follow app? Pull to current workspace.
        if config.followApps.contains(bundleId) {
            sourceWs.windows.removeAll { $0.windowId == windowId }
            ws.windows.append(window)
            ws.focusIndex = ws.windows.count - 1
            ensureWindowVisible(at: ws.focusIndex)
            slog("Pulled follow-app \(bundleId) to workspace \(activeWorkspaceId)")
            return
        }

        // Window is on another workspace → switch to that workspace
        if sourceWsId != activeWorkspaceId {
            switchTo(workspace: sourceWsId)
            // Update focus index in the target workspace
            if let idx = activeWorkspace.windows.firstIndex(where: { $0.windowId == windowId }) {
                activeWorkspace.focusIndex = idx
                ensureWindowVisible(at: idx)
            }
            slog("Auto-switched to workspace \(sourceWsId) (window focus)")
        }
    }

    private func findWindow(byId windowId: CGWindowID) -> (Int, Workspace, TrackedWindow)? {
        for (wsId, ws) in workspaces {
            if let window = ws.windows.first(where: { $0.windowId == windowId }) {
                return (wsId, ws, window)
            }
        }
        return nil
    }

    private func getWindowId(from element: UIElement) -> CGWindowID? {
        var windowId: CGWindowID = 0
        let result = _AXUIElementGetWindow(element.element, &windowId)
        return result == .success ? windowId : nil
    }

    // MARK: - Reorder Windows in Strip

    func moveWindowLeft() {
        let ws = activeWorkspace
        guard ws.focusIndex > 0 else { return }
        ws.windows.swapAt(ws.focusIndex, ws.focusIndex - 1)
        ws.focusIndex -= 1
        ensureWindowVisible(at: ws.focusIndex)
    }

    func moveWindowRight() {
        let ws = activeWorkspace
        guard ws.focusIndex < ws.windows.count - 1 else { return }
        ws.windows.swapAt(ws.focusIndex, ws.focusIndex + 1)
        ws.focusIndex += 1
        ensureWindowVisible(at: ws.focusIndex)
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

    // MARK: - Reset

    func resetAll() {
        windowTracker?.beginProgrammaticUpdate()

        // Move all windows to workspace 1
        let ws1 = workspaces[1]!
        for ws in workspaces.values where ws !== ws1 {
            ws1.windows.append(contentsOf: ws.windows)
            ws.windows.removeAll()
            ws.scrollOffset = 0
        }

        activeWorkspaceId = 1
        ws1.isVisible = true
        ws1.scrollOffset = 0
        ws1.focusIndex = 0

        layoutActiveWorkspace()
        windowTracker?.endProgrammaticUpdate()
        updateMenuBar()
        slog("Reset — all windows moved to workspace 1")
    }

    // MARK: - State Persistence

    private static let stateURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Streifen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    func saveState() {
        var state: [[String: Any]] = []
        for (wsId, ws) in workspaces {
            for window in ws.windows {
                state.append([
                    "windowId": Int(window.windowId),
                    "workspace": wsId,
                    "widthRatio": Double(window.widthRatio),
                    "bundleId": window.bundleId ?? "",
                    "title": window.title,
                ])
            }
        }
        let wrapper: [String: Any] = [
            "activeWorkspace": activeWorkspaceId,
            "scrollOffsets": Dictionary(uniqueKeysWithValues: workspaces.map { ("\($0.key)", $0.value.scrollOffset) }),
            "windows": state,
            "timestamp": Date().timeIntervalSince1970,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: wrapper, options: .prettyPrinted) else { return }
        try? data.write(to: Self.stateURL)
        slog("State saved (\(state.count) windows)")
    }

    /// Restore state if saved less than 15 minutes ago. Returns true if restored.
    func restoreState(_ currentWindows: [TrackedWindow]) -> Bool {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = wrapper["timestamp"] as? Double,
              let windowStates = wrapper["windows"] as? [[String: Any]] else { return false }

        // Only restore if fresh (< 15 min)
        let age = Date().timeIntervalSince1970 - timestamp
        guard age < 900 else {
            slog("State too old (\(Int(age))s), ignoring")
            return false
        }

        let savedActiveWs = wrapper["activeWorkspace"] as? Int ?? 1
        let scrollOffsets = wrapper["scrollOffsets"] as? [String: Double] ?? [:]

        // Build lookups: try windowId first, fallback to bundleId+title
        var idLookup: [CGWindowID: (Int, CGFloat)] = [:]
        var keyLookup: [String: (Int, CGFloat)] = [:]
        for entry in windowStates {
            guard let wsId = entry["workspace"] as? Int,
                  let ratio = entry["widthRatio"] as? Double else { continue }
            if let wid = entry["windowId"] as? Int {
                idLookup[CGWindowID(wid)] = (wsId, CGFloat(ratio))
            }
            if let bid = entry["bundleId"] as? String, let title = entry["title"] as? String {
                keyLookup["\(bid)|\(title)"] = (wsId, CGFloat(ratio))
            }
        }

        guard !idLookup.isEmpty || !keyLookup.isEmpty else { return false }

        // Use passed-in windows (from windowTracker) since workspaces are empty at startup
        let allWindows = currentWindows
        for ws in workspaces.values { ws.windows.removeAll() }

        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let offscreen = CGPoint(x: screen.maxX + screen.width, y: screen.maxY + screen.height)
        var restored = 0

        for window in allWindows {
            let match = idLookup[window.windowId]
                ?? keyLookup["\(window.bundleId ?? "")|\(window.title)"]

            if let (wsId, ratio) = match {
                window.widthRatio = ratio
                workspaces[wsId]?.windows.append(window)
                if wsId != savedActiveWs {
                    window.setPosition(offscreen)
                }
                restored += 1
            } else {
                // Unknown window → active workspace
                workspaces[savedActiveWs]?.windows.append(window)
            }
        }

        // Restore scroll offsets
        for (key, offset) in scrollOffsets {
            if let wsId = Int(key) {
                workspaces[wsId]?.scrollOffset = CGFloat(offset)
            }
        }

        activeWorkspaceId = savedActiveWs
        for ws in workspaces.values { ws.isVisible = (ws.id == savedActiveWs) }

        layoutActiveWorkspace()
        updateMenuBar()
        slog("State restored (\(restored)/\(allWindows.count) windows matched, age \(Int(age))s)")
        return true
    }

    // MARK: - Crash Safety

    func restoreAllWindowsOnScreen() {
        saveState()  // Save before crash recovery
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

    @objc private func handleResetNotification() {
        resetAll()
    }
}
