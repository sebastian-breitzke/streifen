import Cocoa
import AXSwift

@MainActor
final class WindowTracker {
    var onWindowsChanged: (([TrackedWindow]) -> Void)?
    var onAppActivated: ((NSRunningApplication) -> Void)?

    private var trackedWindows: [CGWindowID: TrackedWindow] = [:]
    private var observers: [pid_t: Observer] = [:]
    private var isUpdating = false

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
    }

    func stopTracking() {
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

    private func discoverWindows(for app: NSRunningApplication) {
        guard let appElement = AXSwift.Application(app) else { return }
        guard let axWindows = try? appElement.windows() else { return }

        for axWindow in axWindows {
            guard let position: CGPoint = try? axWindow.attribute(.position),
                  let size: CGSize = try? axWindow.attribute(.size) else { continue }

            // Skip tiny windows (toolbars, popups)
            guard size.width >= 100 && size.height >= 100 else { continue }

            let frame = CGRect(origin: position, size: size)
            let windowId = getWindowId(from: axWindow) ?? 0

            guard windowId != 0, trackedWindows[windowId] == nil else { continue }

            let tracked = TrackedWindow(
                windowId: windowId,
                axElement: axWindow,
                app: app,
                frame: frame
            )
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
        } catch {
            NSLog("[Streifen] Observer setup failed for pid \(pid): \(error)")
        }

        observers[pid] = observer
    }

    private func handleAXNotification(_ notification: AXNotification, element: UIElement, pid: pid_t) {
        guard !isUpdating else { return }

        switch notification {
        case .windowCreated:
            if let app = NSRunningApplication(processIdentifier: pid) {
                discoverWindows(for: app)
            }
        case .uiElementDestroyed:
            let toRemove = trackedWindows.filter { $0.value.app.processIdentifier == pid }
            for (id, window) in toRemove {
                if (try? window.axElement.attribute(.position) as CGPoint?) == nil {
                    trackedWindows.removeValue(forKey: id)
                }
            }
        case .moved, .resized:
            for (_, window) in trackedWindows where window.app.processIdentifier == pid {
                if let pos: CGPoint = try? window.axElement.attribute(.position),
                   let size: CGSize = try? window.axElement.attribute(.size) {
                    window.frame = CGRect(origin: pos, size: size)
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
