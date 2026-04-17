import Cocoa
import AXSwift

@MainActor
final class Workspace {
    let id: Int
    var windows: [TrackedWindow] = []
    var minimizedWindows: [TrackedWindow] = []
    var scrollOffset: CGFloat = 0
    var focusIndex: Int = 0

    init(id: Int) {
        self.id = id
    }

    var isVisible: Bool = false
}

/// Park position for hidden windows — far off-screen.
/// macOS clamps this to a tiny corner at the bottom-right edge (~40x20px),
/// well behind raised visible windows.
let offscreenPark = CGPoint(x: 99999, y: 99999)

@MainActor
final class WorkspaceManager {
    private struct WindowStripMetrics {
        let x: CGFloat
        let width: CGFloat
    }

    private(set) var workspaces: [Int: Workspace] = [:]
    private(set) var activeWorkspaceId: Int = 1
    var config: StreifenConfig

    private weak var windowTracker: WindowTracker?
    private var stripLayout: StripLayout?
    private var lastLayoutTime: CFAbsoluteTime = 0
    private var lastSwitchTime: CFAbsoluteTime = 0

    /// In-flight spawn attempts — bundleId → deadline (CFAbsoluteTime).
    /// Cleared when the matching new window appears in `handleWindowsUpdate`,
    /// or by the timeout handler which then triggers a switch-to-existing fallback.
    private var pendingSpawns: [String: CFAbsoluteTime] = [:]
    private let spawnTimeout: CFAbsoluteTime = 1.5

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
        // Delay: NSScreen.screens may not reflect the new configuration immediately
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let sc = ScreenClass.current
            let screen = NSScreen.managed?.visibleFrame
            slog("Screen parameters changed → \(sc.rawValue) (\(Int(screen?.width ?? 0))×\(Int(screen?.height ?? 0))) — recalculating all sizes")

            // Recalculate all slice counts for the new screen class.
            // Reset minSliceCount — its value is relative to totalSlices, which
            // just changed. The next layout pass will re-detect any refusals.
            for ws in self.workspaces.values {
                for window in ws.windows {
                    window.minSliceCount = 1
                    window.sliceCount = window.appSize.slices(for: sc)
                }
            }

            self.clampScrollOffset(self.activeWorkspace)
            self.layoutActiveWorkspace()
            self.activateFocusedWindow()
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

            // Floating apps stay where they are — not managed by workspaces
            if config.floatingApps.contains(bundleId) { continue }

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

        layoutActiveWorkspace()  // schedules endProgrammaticUpdate after 50ms
        activateFocusedWindow()
        updateMenuBar()

        // Log assignment details
        for (wsId, ws) in workspaces.sorted(by: { $0.key < $1.key }) where !ws.windows.isEmpty {
            let names = ws.windows.map { "\($0.app.localizedName ?? "?")(\($0.windowId))" }.joined(separator: ", ")
            slog("  WS \(wsId): \(names)")
        }
        slog("Initial sort: \(windows.count) windows")
        saveState()
    }

    // MARK: - Window Updates

    func handleWindowsUpdate(_ windows: [TrackedWindow]) {
        let knownIds = Set(workspaces.values.flatMap {
            $0.windows.map { $0.windowId } + $0.minimizedWindows.map { $0.windowId }
        })
        let ws = activeWorkspace
        var added = false
        var pinnedSwitchTarget: (Int, TrackedWindow)? = nil

        // Insert new windows — pinned apps go to their workspace (first window only)
        for window in windows {
            if !knownIds.contains(window.windowId) {
                let bundleId = window.bundleId ?? ""

                // A pending spawn for this bundleId just produced a window —
                // clear the entry so the timeout handler doesn't trigger a fallback.
                if !bundleId.isEmpty, pendingSpawns.removeValue(forKey: bundleId) != nil {
                    slog("spawn: fulfilled \(bundleId) by window \(window.windowId)")
                }

                // Floating apps — not managed
                if config.floatingApps.contains(bundleId) { continue }
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

                // If target is not the active workspace, hide — and check if we should switch
                if targetWs !== ws {
                    window.setPosition(offscreenPark)
                    // If the app is currently frontmost, switch to its pinned workspace
                    if window.app.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier {
                        pinnedSwitchTarget = (targetWs.id, window)
                    }
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
            workspace.minimizedWindows.removeAll { !currentIds.contains($0.windowId) }
            if workspace.windows.count != before { removed = true }
        }

        // Clamp focus index
        if ws.focusIndex >= ws.windows.count {
            ws.focusIndex = max(0, ws.windows.count - 1)
        }

        // Re-layout strip
        if added || removed {
            if removed {
                clampScrollOffset(ws)
            }
            if added {
                ensureWindowVisible(at: ws.focusIndex)
            } else {
                layoutActiveWorkspace()
            }
            activateFocusedWindow()
            saveState()
        }

        updateMenuBar()

        // Switch to pinned workspace if the frontmost app's first window was just placed there
        if let (targetWsId, window) = pinnedSwitchTarget {
            if let targetWs = workspaces[targetWsId],
               let idx = targetWs.windows.firstIndex(where: { $0.windowId == window.windowId }) {
                targetWs.focusIndex = idx
            }
            switchTo(workspace: targetWsId)
            slog("Auto-switched to ws\(targetWsId) (pinned app \(window.bundleId ?? "?") activated)")
        }
    }

    // MARK: - Minimize Handling

    func handleWindowMinimizeChanged(windowId: CGWindowID, minimized: Bool) {
        for ws in workspaces.values {
            if minimized {
                // Move from windows → minimizedWindows
                if let idx = ws.windows.firstIndex(where: { $0.windowId == windowId }) {
                    let window = ws.windows.remove(at: idx)
                    ws.minimizedWindows.append(window)
                    slog("Minimized \(window.app.localizedName ?? "?") (\(windowId)) on ws\(ws.id)")

                    if ws.id == activeWorkspaceId {
                        // Clamp focus index
                        if ws.focusIndex >= ws.windows.count {
                            ws.focusIndex = max(0, ws.windows.count - 1)
                        }
                        clampScrollOffset(ws)
                        layoutActiveWorkspace()
                        if !ws.windows.isEmpty {
                            activateFocusedWindow()
                        }
                        saveState()
                    }
                    updateMenuBar()
                    return
                }
            } else {
                // Move from minimizedWindows → windows
                if let idx = ws.minimizedWindows.firstIndex(where: { $0.windowId == windowId }) {
                    let window = ws.minimizedWindows.remove(at: idx)
                    slog("Unminimized \(window.app.localizedName ?? "?") (\(windowId)) on ws\(ws.id)")

                    if ws.id == activeWorkspaceId {
                        // Insert near current focus
                        let insertIdx = min(ws.focusIndex + 1, ws.windows.count)
                        ws.windows.insert(window, at: insertIdx)
                        ws.focusIndex = insertIdx
                        ensureWindowVisible(at: insertIdx)
                        activateFocusedWindow()
                    } else {
                        // Not active workspace — just append and park
                        ws.windows.append(window)
                        window.setPosition(offscreenPark)
                    }
                    saveState()
                    updateMenuBar()
                    return
                }
            }
        }
    }

    /// Snap a manually resized window to the nearest slice count
    func handleManualResize(windowId: CGWindowID) {
        // Ignore resizes triggered by our own layout (cooldown 500ms)
        guard CFAbsoluteTimeGetCurrent() - lastLayoutTime > 0.5 else { return }

        guard let screen = NSScreen.managed?.visibleFrame else { return }
        let ws = activeWorkspace
        guard let window = ws.windows.first(where: { $0.windowId == windowId }) else { return }

        let sc = ScreenClass.current
        let sliceWidth = screen.width / CGFloat(sc.totalSlices)
        let newSlices = max(1, min(Int(round(window.frame.width / sliceWidth)), sc.totalSlices))

        guard newSlices != window.sliceCount else { return }
        window.setSliceCount(newSlices)
        slog("Manual resize → \(window.title): \(window.sliceCount) slices")
        ensureWindowVisible(at: ws.focusIndex)
        saveState()
    }

    // MARK: - Workspace Switching

    func switchTo(workspace targetId: Int) {
        guard targetId >= 1 && targetId <= 9 else { return }
        guard targetId != activeWorkspaceId else { return }

        lastSwitchTime = CFAbsoluteTimeGetCurrent()
        windowTracker?.beginProgrammaticUpdate()

        // Hide current workspace windows off-screen (skip already-parked)
        for window in activeWorkspace.windows {
            if window.frame.origin.x != offscreenPark.x {
                window.setPosition(offscreenPark)
            }
        }
        activeWorkspace.isVisible = false

        // Show target workspace
        activeWorkspaceId = targetId
        activeWorkspace.isVisible = true
        ensureWindowVisible(at: activeWorkspace.focusIndex)

        activateFocusedWindow()
        raiseFloatingWindows()

        windowTracker?.endProgrammaticUpdate()
        updateMenuBar()

        // Delayed sweep: some apps ignore AX position changes when not frontmost
        scheduleOffscreenSweep()

        saveState()
        OverlayPanel.shared.showWorkspace(targetId)
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
        OverlayPanel.shared.showMovedToWorkspace(targetId)
        layoutActiveWorkspace()
        activateFocusedWindow()
        updateMenuBar()
        saveState()
    }

    // MARK: - Focus Navigation

    func focusLeft() {
        let ws = activeWorkspace
        guard !ws.windows.isEmpty else { return }
        let newIdx = max(0, ws.focusIndex - 1)
        guard newIdx != ws.focusIndex else { return }  // hard stop at left edge
        ws.focusIndex = newIdx
        focusCurrentWindow()
    }

    func focusRight() {
        let ws = activeWorkspace
        guard !ws.windows.isEmpty else { return }
        let newIdx = min(ws.windows.count - 1, ws.focusIndex + 1)
        guard newIdx != ws.focusIndex else { return }  // hard stop at right edge
        ws.focusIndex = newIdx
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

        let metrics = stripMetrics(for: ws, screen: screen)
        let windowX = metrics[index].x
        let windowWidth = metrics[index].width

        let gap = config.gap
        let tolerance: CGFloat = 5
        let currentLeft = windowX + ws.scrollOffset
        let currentRight = currentLeft + windowWidth
        let screenLeft = gap
        let screenRight = screen.width - gap

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

    func scrollActiveWorkspace(by delta: CGFloat) {
        let ws = activeWorkspace
        guard !ws.windows.isEmpty else { return }
        ws.scrollOffset += delta
        clampScrollOffset(ws)
        layoutActiveWorkspace()
    }

    func snapActiveWorkspaceToNearestWindow() {
        guard let screen = NSScreen.managed?.visibleFrame else { return }
        let ws = activeWorkspace
        guard !ws.windows.isEmpty else { return }

        let metrics = stripMetrics(for: ws, screen: screen)
        let screenCenter = screen.width / 2

        guard let nearest = metrics.enumerated().min(by: { lhs, rhs in
            let lhsCenter = lhs.element.x + ws.scrollOffset + lhs.element.width / 2
            let rhsCenter = rhs.element.x + ws.scrollOffset + rhs.element.width / 2
            return abs(lhsCenter - screenCenter) < abs(rhsCenter - screenCenter)
        }) else {
            return
        }

        ws.focusIndex = nearest.offset
        ws.scrollOffset = screenCenter - (nearest.element.x + nearest.element.width / 2)
        clampScrollOffset(ws)
        layoutActiveWorkspace()
        activateFocusedWindow()
    }

    // MARK: - App Focus (Cmd+Tab etc.)

    func handleAppActivated(_ app: NSRunningApplication) {
        // Cooldown after programmatic workspace switch — activateFocusedWindow raises
        // all windows which triggers cascading app activation notifications. Without
        // this guard, apps with windows on multiple workspaces cause a ping-pong loop.
        guard CFAbsoluteTimeGetCurrent() - lastSwitchTime > 0.5 else { return }

        let pid = app.processIdentifier
        let ws = activeWorkspace

        // If this app has a window on the active workspace, prefer staying here.
        // AX's focusedWindow might report a window from another workspace (stale focus).
        let localWindow = ws.windows.first(where: { $0.app.processIdentifier == pid })

        // If no local window and the app is configured to spawn one, try that
        // before any workspace switch. On success the new window will land on
        // the active workspace through `handleWindowsUpdate` (which already
        // routes new non-pinned windows there).
        if localWindow == nil, let bundleId = app.bundleIdentifier {
            let behavior = config.activateBehavior(for: bundleId)
            if behavior == .spawnLocalIfMissing, LocalWindowSpawner.isSupported(bundleId: bundleId) {
                slog("activation: spawn attempt \(bundleId)")
                if LocalWindowSpawner.spawnNewWindow(bundleId: bundleId) {
                    pendingSpawns[bundleId] = CFAbsoluteTimeGetCurrent() + spawnTimeout
                    scheduleSpawnTimeout(bundleId: bundleId)
                    return
                }
                slog("activation: spawn failed \(bundleId) — falling back to switch")
            }
        }

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
        switchToWorkspaceContaining(pid: pid, reason: "app activated, fallback")
    }

    /// Switch to whichever workspace contains any window for the given pid.
    /// Used both by the normal activation fallback and by the spawn-timeout path.
    @discardableResult
    private func switchToWorkspaceContaining(pid: pid_t, reason: String) -> Bool {
        for (wsId, otherWs) in workspaces where wsId != activeWorkspaceId {
            if let window = otherWs.windows.first(where: { $0.app.processIdentifier == pid }) {
                // Set focus on target workspace BEFORE switching so switchTo
                // scrolls to the correct window instead of the old focusIndex
                if let idx = otherWs.windows.firstIndex(where: { $0.windowId == window.windowId }) {
                    otherWs.focusIndex = idx
                }
                switchTo(workspace: wsId)
                do {
                    try window.axElement.setAttribute(.main, value: true)
                    window.app.activate()
                } catch {}
                slog("Auto-switched to workspace \(wsId) (\(reason))")
                return true
            }
        }
        return false
    }

    /// Schedule a fallback if the expected spawn window does not appear in time.
    private func scheduleSpawnTimeout(bundleId: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + spawnTimeout + 0.1) { [weak self] in
            guard let self else { return }
            // If `handleWindowsUpdate` already saw the new window it will have
            // removed this entry. Anything still here is a real timeout.
            guard self.pendingSpawns.removeValue(forKey: bundleId) != nil else { return }
            slog("spawn: timeout \(bundleId) — switching to existing window")
            // Look up any running app with this bundleId; prefer the one the
            // user activated (frontmost), but any instance works for the lookup
            // by pid because WorkspaceManager tracks pid on each window.
            let matching = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
            guard let pid = matching?.processIdentifier else { return }
            _ = self.switchToWorkspaceContaining(pid: pid, reason: "spawn timeout \(bundleId)")
        }
    }

    func handleWindowFocused(windowId: CGWindowID, allowWorkspaceSwitch: Bool = true) {
        let ws = activeWorkspace

        // Already in active workspace? Just update focus index.
        if let idx = ws.windows.firstIndex(where: { $0.windowId == windowId }) {
            // When called from AX focusedWindowChanged (not workspace switch),
            // only accept focus changes from the currently frontmost app.
            // Prevents stale notifications from deactivating apps from
            // overriding the scroll position set by handleAppActivated.
            if !allowWorkspaceSwitch {
                let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
                if ws.windows[idx].app.processIdentifier != frontPid {
                    return
                }
            }
            ws.focusIndex = idx
            ensureWindowVisible(at: idx)
            return
        }

        // Find which workspace has this window
        guard let (sourceWsId, sourceWs, window) = findWindow(byId: windowId) else { return }
        let bundleId = window.bundleId ?? ""

        // Follow app? Always pull to current workspace, even from AX events.
        if config.followApps.contains(bundleId) {
            sourceWs.windows.removeAll { $0.windowId == windowId }
            ws.windows.append(window)
            ws.focusIndex = ws.windows.count - 1
            ensureWindowVisible(at: ws.focusIndex)
            slog("Pulled follow-app \(bundleId) to workspace \(activeWorkspaceId)")
            return
        }

        // Don't switch workspaces unless explicitly allowed (Cmd+Tab, Dock click).
        // AX focusedWindowChanged is too noisy — browser popups, autocomplete
        // dropdowns, and internal window management cause false switches.
        guard allowWorkspaceSwitch else { return }

        // Window is on another workspace → switch to that workspace
        if sourceWsId != activeWorkspaceId {
            // Set focus on target workspace BEFORE switching so switchTo
            // scrolls to the correct window immediately
            if let idx = sourceWs.windows.firstIndex(where: { $0.windowId == windowId }) {
                sourceWs.focusIndex = idx
            }
            switchTo(workspace: sourceWsId)
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
        OverlayPanel.shared.showReorder(position: ws.focusIndex + 1, total: ws.windows.count, direction: "◀")
        ensureWindowVisible(at: ws.focusIndex)
    }

    func moveWindowRight() {
        let ws = activeWorkspace
        guard ws.focusIndex < ws.windows.count - 1 else { return }
        ws.windows.swapAt(ws.focusIndex, ws.focusIndex + 1)
        ws.focusIndex += 1
        OverlayPanel.shared.showReorder(position: ws.focusIndex + 1, total: ws.windows.count, direction: "▶")
        ensureWindowVisible(at: ws.focusIndex)
    }

    // MARK: - Slice Sizing

    /// Set focused window to a specific slice count
    func setSliceCount(_ count: Int) {
        let ws = activeWorkspace
        guard ws.focusIndex < ws.windows.count else { return }
        let window = ws.windows[ws.focusIndex]
        window.setSliceCount(count)
        let sc = ScreenClass.current
        OverlayPanel.shared.showSlices(window.sliceCount, total: sc.totalSlices)
        slog("Slices → \(window.sliceCount)/\(sc.totalSlices)")
        ensureWindowVisible(at: ws.focusIndex)
    }

    /// Step focused window's slice count by delta (+1 or -1)
    func stepSlice(_ delta: Int) {
        let ws = activeWorkspace
        guard ws.focusIndex < ws.windows.count else { return }
        let window = ws.windows[ws.focusIndex]
        window.setSliceCount(window.sliceCount + delta)
        let sc = ScreenClass.current
        OverlayPanel.shared.showSlices(window.sliceCount, total: sc.totalSlices)
        slog("Slices → \(window.sliceCount)/\(sc.totalSlices)")
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

        config.save()
        OverlayPanel.shared.showAppDefault(size.rawValue.uppercased(), appName: window.app.localizedName ?? "App")
        slog("App default → \(bundleId): \(size.rawValue) (\(count) windows updated)")
        ensureWindowVisible(at: ws.focusIndex)
    }

    // MARK: - App Info Panel

    func showAppInfo() {
        let ws = activeWorkspace
        guard ws.focusIndex < ws.windows.count else { return }
        let window = ws.windows[ws.focusIndex]
        guard let bundleId = window.bundleId else { return }

        let currentSize = config.sizeFor(bundleId: bundleId)
        let pinnedWs = config.pinnedApps[bundleId]
        let isFollow = config.followApps.contains(bundleId)
        let isFloating = config.floatingApps.contains(bundleId)

        AppInfoPanel.shared.show(
            appName: window.app.localizedName ?? "Unknown",
            bundleId: bundleId,
            icon: window.app.icon,
            sliceCount: window.sliceCount,
            workspace: activeWorkspaceId,
            currentSize: currentSize,
            pinnedWorkspace: pinnedWs,
            isFollow: isFollow,
            isFloating: isFloating
        ) { [weak self] size, pinned, follow, floating in
            self?.updateAppConfig(bundleId: bundleId, size: size, pinnedWs: pinned, follow: follow, floating: floating)
        }
    }

    func updateAppConfig(bundleId: String, size: AppSize, pinnedWs: Int?, follow: Bool, floating: Bool) {
        config.appSizes[bundleId] = size

        if let ws = pinnedWs {
            config.pinnedApps[bundleId] = ws
        } else {
            config.pinnedApps.removeValue(forKey: bundleId)
        }

        if follow {
            config.followApps.insert(bundleId)
        } else {
            config.followApps.remove(bundleId)
        }

        if floating {
            config.floatingApps.insert(bundleId)
        } else {
            config.floatingApps.remove(bundleId)
        }

        // Update all windows of this app
        for workspace in workspaces.values {
            for w in workspace.windows where w.bundleId == bundleId {
                w.applySize(size)
            }
        }

        config.save()
        ensureWindowVisible(at: activeWorkspace.focusIndex)
        slog("App config updated → \(bundleId): size=\(size.rawValue) pinned=\(pinnedWs.map(String.init) ?? "—") follow=\(follow) floating=\(floating)")
    }

    /// Reset all windows in active workspace to their app-default sizes
    func resetAllWidths() {
        let ws = activeWorkspace
        for window in ws.windows {
            let size = config.sizeFor(bundleId: window.bundleId)
            window.applySize(size)
        }
        ws.scrollOffset = 0
        OverlayPanel.shared.showMessage("Reset")
        slog("Reset all widths to app defaults (\(ws.windows.count) windows)")
        ensureWindowVisible(at: ws.focusIndex)
    }


    // MARK: - Layout

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

    private func stripMetrics(for ws: Workspace, screen: CGRect) -> [WindowStripMetrics] {
        let gap = config.gap
        let sc = ScreenClass.current

        var x: CGFloat = gap
        var metrics: [WindowStripMetrics] = []
        metrics.reserveCapacity(ws.windows.count)

        for window in ws.windows {
            let width = max(screen.width * CGFloat(window.sliceCount) / CGFloat(sc.totalSlices) - (2 * gap), 200)
            metrics.append(WindowStripMetrics(x: x, width: width))
            x += width + gap
        }

        return metrics
    }

    private func layoutActiveWorkspace() {
        guard let screen = NSScreen.managed?.visibleFrame else { return }
        lastLayoutTime = CFAbsoluteTimeGetCurrent()
        windowTracker?.beginProgrammaticUpdate()
        stripLayout?.layout(workspace: activeWorkspace, screenFrame: screen)
        // Delay re-enabling observer to let AX notifications drain
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.windowTracker?.endProgrammaticUpdate()
        }
    }

    /// Force-park all windows on inactive workspaces. Retries multiple times
    /// because some apps (Ghostty, Zen, Teams, Edge) silently ignore AX position
    /// changes when they are not the frontmost app.
    private func scheduleOffscreenSweep() {
        guard let screen = NSScreen.managed?.visibleFrame else { return }
        let screenMaxX = screen.maxX

        for delay in [0.1, 0.3, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.windowTracker?.beginProgrammaticUpdate()
                for ws in self.workspaces.values where !ws.isVisible {
                    for window in ws.windows {
                        // Check actual AX position — macOS clamps offscreenPark (99999)
                        // to ~1688, so compare against screen bounds instead
                        let actualPos: CGPoint? = try? window.axElement.attribute(.position)
                        if let pos = actualPos, pos.x <= screenMaxX {
                            window.setPosition(offscreenPark)
                        }
                    }
                }
                self.windowTracker?.endProgrammaticUpdate()
            }
        }
    }

    /// Raise all floating app windows so they stay on top after workspace switches.
    private func raiseFloatingWindows() {
        guard let tracker = windowTracker else { return }
        for window in tracker.allWindows {
            guard let bid = window.bundleId, config.floatingApps.contains(bid) else { continue }
            try? window.axElement.performAction(.raise)
        }
    }

    /// Activate windows on the active workspace so they render at their AX-set positions.
    /// Apps like Ghostty ignore AX position changes unless their window is raised.
    private func activateFocusedWindow() {
        let ws = activeWorkspace
        guard ws.focusIndex < ws.windows.count else { return }

        // Raise each window and re-confirm its position.
        // Apps like Ghostty ignore AX position changes on non-raised windows,
        // so we raise first, then re-apply the cached target position.
        for window in ws.windows {
            try? window.axElement.performAction(.raise)
            if window.frame.origin.x != offscreenPark.x {
                try? window.axElement.setAttribute(.position, value: window.frame.origin)
            }
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
            ws1.minimizedWindows.append(contentsOf: ws.minimizedWindows)
            ws.windows.removeAll()
            ws.minimizedWindows.removeAll()
            ws.scrollOffset = 0
        }

        activeWorkspaceId = 1
        ws1.isVisible = true
        ws1.scrollOffset = 0
        ws1.focusIndex = 0

        layoutActiveWorkspace()  // schedules endProgrammaticUpdate after 50ms
        activateFocusedWindow()
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
                    "sliceCount": window.sliceCount,
                    "appSize": window.appSize.rawValue,
                    "bundleId": window.bundleId ?? "",
                    "title": window.title,
                ])
            }
            for window in ws.minimizedWindows {
                state.append([
                    "windowId": Int(window.windowId),
                    "workspace": wsId,
                    "sliceCount": window.sliceCount,
                    "appSize": window.appSize.rawValue,
                    "bundleId": window.bundleId ?? "",
                    "title": window.title,
                    "minimized": true,
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
        var idLookup: [CGWindowID: (Int, Int?, Bool)] = [:]  // wsId, sliceCount, minimized
        var keyLookup: [String: (Int, Int?, Bool)] = [:]
        for entry in windowStates {
            guard let wsId = entry["workspace"] as? Int else { continue }
            let slices = entry["sliceCount"] as? Int
            let minimized = entry["minimized"] as? Bool ?? false
            if let wid = entry["windowId"] as? Int {
                idLookup[CGWindowID(wid)] = (wsId, slices, minimized)
            }
            if let bid = entry["bundleId"] as? String, let title = entry["title"] as? String {
                keyLookup["\(bid)|\(title)"] = (wsId, slices, minimized)
            }
        }

        guard !idLookup.isEmpty || !keyLookup.isEmpty else { return false }

        // Use passed-in windows (from windowTracker) since workspaces are empty at startup
        let allWindows = currentWindows
        for ws in workspaces.values {
            ws.windows.removeAll()
            ws.minimizedWindows.removeAll()
        }
        let sc = ScreenClass.current

        var restored = 0

        for window in allWindows {
            // Floating apps — skip
            if let bid = window.bundleId, config.floatingApps.contains(bid) { continue }

            let match = idLookup[window.windowId]
                ?? keyLookup["\(window.bundleId ?? "")|\(window.title)"]

            if let (wsId, slices, minimized) = match {
                if let slices {
                    window.sliceCount = max(1, min(slices, sc.totalSlices))
                } else {
                    window.sliceCount = window.appSize.slices(for: sc)
                }
                window.appSize = config.sizeFor(bundleId: window.bundleId)
                if minimized {
                    workspaces[wsId]?.minimizedWindows.append(window)
                } else {
                    workspaces[wsId]?.windows.append(window)
                }
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
        scheduleOffscreenSweep()
        slog("State restored (\(restored)/\(allWindows.count) windows matched, age \(Int(age))s)")
        saveState()
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
