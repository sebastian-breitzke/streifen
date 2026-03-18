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

/// Park position for hidden windows — far enough that no screen can show them
let offscreenPark = CGPoint(x: 99999, y: 99999)

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
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    @objc private func handleScreenChange(_ notification: Notification) {
        Task { @MainActor in
            let sc = ScreenClass.current
            slog("Screen parameters changed → \(sc.rawValue) — recalculating all sizes")

            // Recalculate all widthRatios for the new screen class
            for ws in workspaces.values {
                for window in ws.windows {
                    window.widthRatio = window.appSize.ratio(for: sc)
                }
            }

            clampScrollOffset(activeWorkspace)
            layoutActiveWorkspace()
            activateFocusedWindow()
        }
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
                window.setPosition(offscreenPark)
            }
        }

        layoutActiveWorkspace()
        activateFocusedWindow()
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

                // If target is not the active workspace, hide
                if targetWs !== ws {
                    window.setPosition(offscreenPark)
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

        // Re-layout strip
        if added || removed {
            if removed {
                // After removing a window, clamp scroll offset so no gap appears at the end
                clampScrollOffset(ws)
            }
            if added {
                ensureWindowVisible(at: ws.focusIndex)
            } else {
                layoutActiveWorkspace()
            }
            activateFocusedWindow()
        }

        updateMenuBar()
    }

    // MARK: - Workspace Switching

    func switchTo(workspace targetId: Int) {
        guard targetId >= 1 && targetId <= 9 else { return }
        guard targetId != activeWorkspaceId else { return }

        windowTracker?.beginProgrammaticUpdate()

        // Hide current workspace windows off-screen
        for window in activeWorkspace.windows {
            window.setPosition(offscreenPark)
        }
        activeWorkspace.isVisible = false

        // Show target workspace
        activeWorkspaceId = targetId
        activeWorkspace.isVisible = true
        ensureWindowVisible(at: activeWorkspace.focusIndex)

        activateFocusedWindow()

        windowTracker?.endProgrammaticUpdate()
        updateMenuBar()

        saveState()
        slog("Switched to workspace \(targetId)")
    }

    func switchPrevious() {
        let target = activeWorkspaceId - 1
        guard target >= 1 else { return }
        switchTo(workspace: target)
    }

    func switchNext() {
        let target = activeWorkspaceId + 1
        guard target <= 9 else { return }
        switchTo(workspace: target)
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
            windowTracker?.beginProgrammaticUpdate()
            window.setPosition(offscreenPark)
            windowTracker?.endProgrammaticUpdate()
        }

        // Clamp focus index and re-layout source workspace
        let ws = activeWorkspace
        if ws.focusIndex >= ws.windows.count {
            ws.focusIndex = max(0, ws.windows.count - 1)
        }
        layoutActiveWorkspace()
        activateFocusedWindow()
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
        guard let screen = NSScreen.managed?.visibleFrame else { return }
        let ws = activeWorkspace
        guard index < ws.windows.count else { return }

        // Calculate where window sits in the strip (sum of previous widths)
        let gap = config.gap
        let peek = config.peekWidth
        let hasNeighbors = ws.windows.count > 1
        let maxW = screen.width - (2 * gap) - (2 * peek)

        var windowX: CGFloat = gap
        for i in 0..<index {
            var w = screen.width * ws.windows[i].widthRatio - (2 * gap)
            if hasNeighbors { w = min(w, maxW) }
            windowX += max(w, 200) + gap
        }
        var windowWidth = screen.width * ws.windows[index].widthRatio - (2 * gap)
        if hasNeighbors { windowWidth = min(windowWidth, maxW) }
        windowWidth = max(windowWidth, 200)

        // Peek margins: reserve space for neighbor peek
        let leftPeek: CGFloat = index > 0 ? peek : 0
        let rightPeek: CGFloat = index < ws.windows.count - 1 ? peek : 0

        let tolerance: CGFloat = 5
        let currentLeft = windowX + ws.scrollOffset
        let currentRight = currentLeft + windowWidth
        let screenLeft = gap + leftPeek
        let screenRight = screen.width - gap - rightPeek

        if windowWidth > screenRight - screenLeft {
            // Window wider than available space — align left edge
            ws.scrollOffset = screenLeft - windowX
        } else if currentLeft < screenLeft - tolerance {
            ws.scrollOffset += screenLeft - currentLeft
        } else if currentRight > screenRight + tolerance {
            ws.scrollOffset -= currentRight - screenRight
        }

        layoutActiveWorkspace()
    }

    // MARK: - App Focus (Cmd+Tab etc.)

    func handleAppActivated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        let ws = activeWorkspace

        // If this app has a window on the active workspace, prefer staying here.
        // AX's focusedWindow might report a window from another workspace (stale focus).
        let localWindow = ws.windows.first(where: { $0.app.processIdentifier == pid })

        // Try to find focused window via AX
        if let appElement = AXSwift.Application(forProcessID: pid),
           let focusedWindow: UIElement = try? appElement.attribute(.focusedWindow),
           let wid = getWindowId(from: focusedWindow) {

            // If the focused window is on the active workspace, use it directly
            if let idx = ws.windows.firstIndex(where: { $0.windowId == wid }) {
                ws.focusIndex = idx
                ensureWindowVisible(at: idx)
                return
            }

            // Focused window is on another workspace — but if we have a local
            // window of the same app, stay here (user likely clicked it)
            if let local = localWindow,
               let idx = ws.windows.firstIndex(where: { $0.windowId == local.windowId }) {
                ws.focusIndex = idx
                ensureWindowVisible(at: idx)
                return
            }

            // No local window — switch to the workspace with the focused window
            handleWindowFocused(windowId: wid)
            return
        }

        // Fallback: AX returned no focused window
        if let local = localWindow,
           let idx = ws.windows.firstIndex(where: { $0.windowId == local.windowId }) {
            ws.focusIndex = idx
            ensureWindowVisible(at: idx)
            return
        }

        // Search other workspaces — switch to the one containing this app's window
        for (wsId, otherWs) in workspaces where wsId != activeWorkspaceId {
            if let window = otherWs.windows.first(where: { $0.app.processIdentifier == pid }) {
                switchTo(workspace: wsId)
                if let idx = activeWorkspace.windows.firstIndex(where: { $0.windowId == window.windowId }) {
                    activeWorkspace.focusIndex = idx
                    do {
                        try window.axElement.setAttribute(.main, value: true)
                        window.app.activate()
                    } catch {}
                    ensureWindowVisible(at: idx)
                }
                slog("Auto-switched to workspace \(wsId) (app activated, fallback)")
                return
            }
        }
    }

    func handleWindowFocused(windowId: CGWindowID, allowWorkspaceSwitch: Bool = true) {
        let ws = activeWorkspace

        // Already in active workspace? Just update focus index.
        if let idx = ws.windows.firstIndex(where: { $0.windowId == windowId }) {
            ws.focusIndex = idx
            ensureWindowVisible(at: idx)
            return
        }

        // Don't switch workspaces unless explicitly allowed (Cmd+Tab, Dock click).
        // AX focusedWindowChanged is too noisy — browser popups, autocomplete
        // dropdowns, and internal window management cause false switches.
        guard allowWorkspaceSwitch else { return }

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

    // MARK: - T-Shirt Sizing

    /// Set focused window to a T-Shirt size (resolves to ratio based on screen class)
    func setSize(_ size: AppSize) {
        let ws = activeWorkspace
        guard ws.focusIndex < ws.windows.count else { return }
        let window = ws.windows[ws.focusIndex]
        window.applySize(size)
        let sc = ScreenClass.current
        slog("Size → \(size.rawValue) (\(Int(window.widthRatio * 100))% on \(sc.rawValue))")
        ensureWindowVisible(at: ws.focusIndex)
    }

    /// Set the app-default size for the focused window's app. Updates all windows of that app across all workspaces.
    func setAppDefaultSize(_ size: AppSize) {
        let ws = activeWorkspace
        guard ws.focusIndex < ws.windows.count else { return }
        let window = ws.windows[ws.focusIndex]
        guard let bundleId = window.bundleId else { return }

        // Persist in config
        config.appSizes[bundleId] = size

        // Update all windows of this app across all workspaces
        var count = 0
        for workspace in workspaces.values {
            for w in workspace.windows where w.bundleId == bundleId {
                w.applySize(size)
                count += 1
            }
        }

        slog("App default → \(bundleId): \(size.rawValue) (\(count) windows updated)")
        ensureWindowVisible(at: ws.focusIndex)
    }

    func setWidthRatio(_ ratio: CGFloat) {
        let ws = activeWorkspace
        guard ws.focusIndex < ws.windows.count else { return }
        ws.windows[ws.focusIndex].widthRatio = ratio
        slog("Width → \(ratio) (\(Int(ratio * 100))%)")
        ensureWindowVisible(at: ws.focusIndex)
    }

    /// Reset all windows in active workspace to their app-default sizes
    func resetAllWidths() {
        let ws = activeWorkspace
        for window in ws.windows {
            let size = config.sizeFor(bundleId: window.bundleId)
            window.applySize(size)
        }
        ws.scrollOffset = 0
        slog("Reset all widths to app defaults (\(ws.windows.count) windows)")
        ensureWindowVisible(at: ws.focusIndex)
    }


    // MARK: - Layout

    func layoutCurrentWorkspace() {
        layoutActiveWorkspace()
    }

    /// Ensure scroll offset doesn't leave empty space at the strip's end
    private func clampScrollOffset(_ ws: Workspace) {
        guard let screen = NSScreen.managed?.visibleFrame, let strip = stripLayout else { return }
        let totalWidth = strip.totalWidth(workspace: ws, screenFrame: screen)
        let screenWidth = screen.width

        // Don't scroll past the right end of the strip
        if totalWidth + ws.scrollOffset < screenWidth {
            ws.scrollOffset = screenWidth - totalWidth
        }
        // Don't scroll past the left end
        if ws.scrollOffset > 0 {
            ws.scrollOffset = 0
        }
    }

    private func layoutActiveWorkspace() {
        guard let screen = NSScreen.managed?.visibleFrame else { return }
        windowTracker?.beginProgrammaticUpdate()
        stripLayout?.layout(workspace: activeWorkspace, screenFrame: screen, config: config)
        // Delay re-enabling observer to let AX notifications drain
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.windowTracker?.endProgrammaticUpdate()
        }
    }

    /// Activate windows on the active workspace so they render at their AX-set positions.
    /// Apps like Zen/Firefox ignore AX position changes unless their window is raised.
    private func activateFocusedWindow() {
        let ws = activeWorkspace
        guard ws.focusIndex < ws.windows.count else { return }

        // Raise all windows — forces each app to render at AX positions
        for window in ws.windows {
            try? window.axElement.performAction(.raise)
        }

        // Activate the focused window's app last so it ends up in front
        let focused = ws.windows[ws.focusIndex]
        try? focused.axElement.setAttribute(.main, value: true)
        focused.app.activate()
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
        activateFocusedWindow()
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
                    "appSize": window.appSize.rawValue,
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

        var restored = 0

        for window in allWindows {
            let match = idLookup[window.windowId]
                ?? keyLookup["\(window.bundleId ?? "")|\(window.title)"]

            if let (wsId, ratio) = match {
                window.widthRatio = ratio
                // Restore appSize from config (ratio was persisted as override)
                window.appSize = config.sizeFor(bundleId: window.bundleId)
                workspaces[wsId]?.windows.append(window)
                if wsId != savedActiveWs {
                    window.setPosition(offscreenPark)
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
        activateFocusedWindow()
        updateMenuBar()
        slog("State restored (\(restored)/\(allWindows.count) windows matched, age \(Int(age))s)")
        return true
    }

    // MARK: - Crash Safety

    func restoreAllWindowsOnScreen() {
        saveState()  // Save before crash recovery
        guard let screen = NSScreen.managed?.visibleFrame else { return }
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
