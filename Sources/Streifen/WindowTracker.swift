import Cocoa
import AXSwift

@MainActor
final class WindowTracker {
    var onWindowsChanged: (([TrackedWindow]) -> Void)?
    var onAppActivated: ((NSRunningApplication) -> Void)?
    var onWindowFocused: ((CGWindowID) -> Void)?
    var onWindowResized: ((CGWindowID) -> Void)?
    var onWindowMinimizeChanged: ((CGWindowID, Bool) -> Void)?
    var config: StreifenConfig

    private var trackedWindows: [CGWindowID: TrackedWindow] = [:]
    private var observers: [pid_t: Observer] = [:]
    private var isUpdating = false

    init(config: StreifenConfig) {
        self.config = config
    }

    private var livenessTimer: Timer?

    func startTracking() {
        discoverAllWindows()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appLaunched(_:)),
                           name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appTerminated(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )

        // Periodic liveness check — catch windows that disappeared without AX notification
        // and re-discover windows that were missed (dropped AX notifications, Electron restarts)
        livenessTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pruneDeadWindows()
                self?.rediscoverMissingWindows()
            }
        }
    }

    func stopTracking() {
        livenessTimer?.invalidate()
        livenessTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        observers.removeAll()
        trackedWindows.removeAll()
    }

    var allWindows: [TrackedWindow] {
        Array(trackedWindows.values)
    }

    // MARK: - Window Discovery

    private func discoverAllWindows() {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }

        for app in apps {
            discoverWindows(for: app)
        }

        notifyChanged()
    }

    // Apps that should never be tracked (overlays, screen tools, utilities)
    private static let ignoredBundleIds: Set<String> = [
        "pl.maketheweb.cleanshotx",         // CleanShot X
        "com.surteesstudios.Bartender",      // Bartender
        "com.hegenberg.BetterSnapTool",      // BetterSnapTool
        "com.betterdisplay.BetterDisplay",   // BetterDisplay
        "de.s16e.streifen",                  // Ourselves
    ]

    private func discoverWindows(for app: NSRunningApplication) {
        if let bid = app.bundleIdentifier, Self.ignoredBundleIds.contains(bid) { return }
        guard let appElement = AXSwift.Application(app) else { return }
        guard let axWindows = try? appElement.windows() else { return }

        for axWindow in axWindows {
            guard let position: CGPoint = try? axWindow.attribute(.position),
                  let size: CGSize = try? axWindow.attribute(.size) else { continue }

            // Skip tiny windows (toolbars, popups)
            guard size.width >= 100 && size.height >= 100 else { continue }

            // Skip floating/popup windows: dialogs, sheets, utility panels
            let subrole: String? = try? axWindow.attribute(.subrole)
            let isJetBrains = app.bundleIdentifier?.hasPrefix("com.jetbrains.") == true

            if isJetBrains {
                // JetBrains has unreliable subroles — main windows report AXDialog
                // or AXStandardWindow depending on dialog state. Use alternative filtering.
                if let sr = subrole, sr == "AXUnknown" || sr == "AXFloatingWindow" { continue }
                let title: String? = try? axWindow.attribute(.title)
                if title == nil || title!.isEmpty { continue }
            } else {
                // Only track standard windows — skip popups, dialogs, dropdowns, etc.
                guard subrole == "AXStandardWindow" else { continue }
            }

            // Skip small windows (Calculator, color pickers, etc.)
            guard size.width >= 400 || size.height >= 400 else { continue }

            // Skip non-resizable windows with small height — popups, reminders, notifications
            let isResizable = (try? axWindow.attributeIsSettable(.size)) ?? false
            if !isResizable && (size.height < 200 || size.width < 200) { continue }

            let frame = CGRect(origin: position, size: size)
            let windowId = getWindowId(from: axWindow) ?? 0

            guard windowId != 0, trackedWindows[windowId] == nil else { continue }

            let title: String? = try? axWindow.attribute(.title)
            slog("Track window \(windowId): \(app.localizedName ?? "?") — \"\(title ?? "")\" [\(Int(size.width))×\(Int(size.height))] subrole=\(subrole ?? "nil")")

            let appSize = config.sizeFor(bundleId: app.bundleIdentifier)
            let tracked = TrackedWindow(
                windowId: windowId,
                axElement: axWindow,
                app: app,
                frame: frame,
                appSize: appSize
            )

            // Apply persisted minimum width so first layout allocates enough slices
            if let screen = NSScreen.managed?.visibleFrame {
                let sc = ScreenClass.current
                let persistedMin = config.minSlicesFor(
                    bundleId: app.bundleIdentifier,
                    screenWidth: screen.width, gap: config.gap,
                    totalSlices: sc.totalSlices
                )
                if persistedMin > 1 {
                    tracked.minSliceCount = persistedMin
                    if tracked.sliceCount < persistedMin {
                        tracked.sliceCount = persistedMin
                    }
                }
            }

            trackedWindows[windowId] = tracked
        }

        setupObserver(for: app)
    }

    // MARK: - AX Observer

    private func setupObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }

        guard let appElement = AXSwift.Application(forProcessID: pid) else { return }
        guard let observer = appElement.createObserver({ [weak self] (observer, element, notification) in
            self?.handleAXNotification(notification, element: element, pid: pid)
        }) else { return }

        do {
            // Application IS a UIElement — register notifications directly on it
            try observer.addNotification(.windowCreated, forElement: appElement)
            try observer.addNotification(.uiElementDestroyed, forElement: appElement)
            try observer.addNotification(.moved, forElement: appElement)
            try observer.addNotification(.resized, forElement: appElement)
            try observer.addNotification(.focusedWindowChanged, forElement: appElement)
            try observer.addNotification(.windowMiniaturized, forElement: appElement)
            try observer.addNotification(.windowDeminiaturized, forElement: appElement)
        } catch {
            slog("Observer setup failed for pid \(pid): \(error)")
        }

        observers[pid] = observer
    }

    private func handleAXNotification(_ notification: AXNotification, element: UIElement, pid: pid_t) {
        // Allow create and destroy notifications even during programmatic updates —
        // window closures during layout must not be silently dropped, and new windows
        // must not be lost just because a layout pass is in progress.
        if isUpdating && notification != .uiElementDestroyed && notification != .windowCreated { return }

        switch notification {
        case .windowCreated:
            if let app = NSRunningApplication(processIdentifier: pid) {
                discoverWindows(for: app)
                // Retry after delay — torn-off tabs may not be ready on first attempt
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self else { return }
                    let before = self.trackedWindows.count
                    self.discoverWindows(for: app)
                    if self.trackedWindows.count > before {
                        self.notifyChanged()
                    }
                }
            }
        case .uiElementDestroyed:
            // Try to match the destroyed element directly
            if let wid = getWindowId(from: element) {
                if let removed = trackedWindows[wid] {
                    slog("Untrack window \(wid): \(removed.app.localizedName ?? "?")")
                }
                trackedWindows.removeValue(forKey: wid)
            } else {
                // Fallback: remove any windows of this app that are no longer readable
                let candidates = trackedWindows.filter { $0.value.app.processIdentifier == pid }
                for (id, window) in candidates {
                    if (try? window.axElement.attribute(.position) as CGPoint?) == nil {
                        trackedWindows.removeValue(forKey: id)
                    }
                }
            }
            // Delayed second pass — catch windows that were still readable during the first check
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                let candidates = self.trackedWindows.filter { $0.value.app.processIdentifier == pid }
                var changed = false
                for (id, window) in candidates {
                    if (try? window.axElement.attribute(.position) as CGPoint?) == nil {
                        self.trackedWindows.removeValue(forKey: id)
                        changed = true
                    }
                }
                if changed { self.notifyChanged() }
            }
        case .focusedWindowChanged:
            // Only act on windows we're tracking — ignore popups, dropdowns, etc.
            if let wid = getWindowId(from: element),
               trackedWindows[wid] != nil {
                onWindowFocused?(wid)
            }
        case .windowMiniaturized:
            if let wid = getWindowId(from: element), trackedWindows[wid] != nil {
                onWindowMinimizeChanged?(wid, true)
            }
        case .windowDeminiaturized:
            if let wid = getWindowId(from: element), trackedWindows[wid] != nil {
                onWindowMinimizeChanged?(wid, false)
            }
        case .moved, .resized:
            for (wid, window) in trackedWindows where window.app.processIdentifier == pid {
                if let pos: CGPoint = try? window.axElement.attribute(.position),
                   let size: CGSize = try? window.axElement.attribute(.size) {
                    let oldSize = window.frame.size
                    window.frame = CGRect(origin: pos, size: size)
                    // If width changed (manual resize), snap sliceCount to nearest grid
                    if notification == .resized && abs(size.width - oldSize.width) > 10 {
                        onWindowResized?(wid)
                    }
                }
            }
        default:
            break
        }

        notifyChanged()
    }

    // MARK: - Programmatic Move Flag

    func beginProgrammaticUpdate() {
        isUpdating = true
    }

    func endProgrammaticUpdate() {
        isUpdating = false
    }

    // MARK: - NSWorkspace Notifications

    @objc private func appLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.discoverWindows(for: app)
            self?.notifyChanged()
        }
    }

    @objc private func appTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        observers.removeValue(forKey: pid)
        trackedWindows = trackedWindows.filter { $0.value.app.processIdentifier != pid }
        notifyChanged()
    }

    @objc private func activeAppChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        onAppActivated?(app)
    }

    // MARK: - Liveness Check

    /// Remove tracked windows whose AX element is no longer readable.
    /// Catches cases where AX destroy notifications are missed (Teams screen sharing, etc.)
    /// Windows get a staleness counter — after maxStaleChecks consecutive failures (30s),
    /// they are force-pruned even if the app returns an empty window list.
    private static let maxStaleChecks = 15  // 15 × 2s timer = 30 seconds

    private func pruneDeadWindows() {
        guard !isUpdating else { return }
        var pruned = false
        for (id, window) in trackedWindows {
            if (try? window.axElement.attribute(.position) as CGPoint?) == nil {
                if window.app.isTerminated {
                    slog("Prune dead window \(id): \(window.app.localizedName ?? "?") (app terminated)")
                    trackedWindows.removeValue(forKey: id)
                    pruned = true
                    continue
                }

                window.staleCount += 1

                // Try to verify via app's window list
                if let appElement = AXSwift.Application(window.app),
                   let axWindows = try? appElement.windows() {
                    let liveIds = Set(axWindows.compactMap { getWindowId(from: $0) })
                    if !liveIds.isEmpty && !liveIds.contains(id) {
                        slog("Prune dead window \(id): \(window.app.localizedName ?? "?") (window closed, \(liveIds.count) siblings alive)")
                        trackedWindows.removeValue(forKey: id)
                        pruned = true
                        continue
                    }
                    // App returned empty list or window still in list — log periodically
                    if window.staleCount == 3 || window.staleCount % 10 == 0 {
                        slog("Stale window \(id): \(window.app.localizedName ?? "?") — AX unreadable, app reports \(liveIds.count) windows (attempt \(window.staleCount)/\(Self.maxStaleChecks))")
                    }
                }

                // Force-prune after max attempts
                if window.staleCount >= Self.maxStaleChecks {
                    slog("Force-prune zombie \(id): \(window.app.localizedName ?? "?") (unreadable for \(window.staleCount) checks)")
                    trackedWindows.removeValue(forKey: id)
                    pruned = true
                }
            } else {
                // Position readable — reset stale counter
                if window.staleCount > 0 {
                    window.staleCount = 0
                }
            }
        }
        if pruned { notifyChanged() }
    }

    // MARK: - Re-Discovery

    /// Re-discover windows for all running apps — catches windows that were missed
    /// because AX windowCreated was dropped, Electron app restarted, or a new window
    /// was opened in an app that already had some windows tracked.
    private func rediscoverMissingWindows() {
        guard !isUpdating else { return }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
        }

        var totalFound = 0
        for app in apps {
            if let bid = app.bundleIdentifier, Self.ignoredBundleIds.contains(bid) { continue }
            let before = trackedWindows.count
            discoverWindows(for: app)
            let added = trackedWindows.count - before
            if added > 0 {
                slog("Re-discovered \(added) window(s) for \(app.localizedName ?? "?")")
                totalFound += added
            }
        }
        if totalFound > 0 { notifyChanged() }
    }

    // MARK: - Helpers

    private func notifyChanged() {
        onWindowsChanged?(allWindows)
    }

    /// Bridge AXUIElement to CGWindowID via private API
    private func getWindowId(from element: UIElement) -> CGWindowID? {
        var windowId: CGWindowID = 0
        let result = _AXUIElementGetWindow(element.element, &windowId)
        return result == .success ? windowId : nil
    }
}

// Private API declaration — bridge AXUIElement ↔ CGWindowID
// Used by AeroSpace, yabai, and others. Stable since macOS 10.x.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowId: inout CGWindowID) -> AXError
