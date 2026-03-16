import Cocoa
import AXSwift

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowTracker: WindowTracker?
    private var workspaceManager: WorkspaceManager?
    private var hotkeyManager: HotkeyManager?
    private var stripLayout: StripLayout?
    private var debugServer: DebugServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        killOtherInstances()
        guard checkAccessibility() else { return }

        let config = StreifenConfig.default
        windowTracker = WindowTracker(config: config)
        workspaceManager = WorkspaceManager(config: config)
        stripLayout = StripLayout(config: config)
        hotkeyManager = HotkeyManager(workspaceManager: workspaceManager!, stripLayout: stripLayout!)

        // Wire up cross-references
        workspaceManager!.setWindowTracker(windowTracker!)
        workspaceManager!.setStripLayout(stripLayout!)

        windowTracker?.onAppActivated = { [weak self] app in
            self?.workspaceManager?.handleAppActivated(app)
        }

        windowTracker?.onWindowFocused = { [weak self] windowId in
            self?.workspaceManager?.handleWindowFocused(windowId: windowId)
        }

        // Discover windows — try to restore saved state, fallback to initial sort
        windowTracker?.startTracking()
        let discovered = windowTracker!.allWindows
        if !(workspaceManager?.restoreState(discovered) ?? false) {
            workspaceManager?.initialSort(discovered)
        }

        windowTracker?.onWindowsChanged = { [weak self] windows in
            self?.workspaceManager?.handleWindowsUpdate(windows)
        }

        hotkeyManager?.registerHotkeys()

        debugServer = DebugServer(workspaceManager: workspaceManager!)
        debugServer?.start()

        slog("Started — tracking windows")
    }

    func applicationWillTerminate(_ notification: Notification) {
        debugServer?.stop()
        // Crash safety: move all windows back on-screen
        workspaceManager?.restoreAllWindowsOnScreen()
        slog("Shutdown — windows restored")
    }

    private func killOtherInstances() {
        let myPid = ProcessInfo.processInfo.processIdentifier
        let myName = ProcessInfo.processInfo.processName

        // Kill by process name (works for debug builds without bundle ID)
        let all = NSWorkspace.shared.runningApplications
        for app in all {
            if app.processIdentifier != myPid,
               app.localizedName == myName || app.bundleIdentifier == "de.s16e.streifen" {
                slog("Killing old instance (pid \(app.processIdentifier))")
                app.terminate()
            }
        }
    }

    private func checkAccessibility() -> Bool {
        let trusted = UIElement.isProcessTrusted(withPrompt: true)
        if !trusted {
            slog("Accessibility not granted — prompting user")
        }
        return trusted
    }
}
