import Cocoa
import AXSwift

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowTracker: WindowTracker?
    private var workspaceManager: WorkspaceManager?
    private var hotkeyManager: HotkeyManager?
    private var stripLayout: StripLayout?

    func applicationDidFinishLaunching(_ notification: Notification) {
        killOtherInstances()
        guard checkAccessibility() else { return }

        let config = StreifenConfig.default
        windowTracker = WindowTracker()
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

        // Discover windows and do initial sort before wiring up live updates
        windowTracker?.startTracking()
        workspaceManager?.initialSort(windowTracker!.allWindows)

        windowTracker?.onWindowsChanged = { [weak self] windows in
            self?.workspaceManager?.handleWindowsUpdate(windows)
        }

        hotkeyManager?.registerHotkeys()

        NSLog("[Streifen] Started — tracking windows")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Crash safety: move all windows back on-screen
        workspaceManager?.restoreAllWindowsOnScreen()
        NSLog("[Streifen] Shutdown — windows restored")
    }

    private func killOtherInstances() {
        let myPid = ProcessInfo.processInfo.processIdentifier
        let myName = ProcessInfo.processInfo.processName

        // Kill by process name (works for debug builds without bundle ID)
        let all = NSWorkspace.shared.runningApplications
        for app in all {
            if app.processIdentifier != myPid,
               app.localizedName == myName || app.bundleIdentifier == "de.s16e.streifen" {
                NSLog("[Streifen] Killing old instance (pid \(app.processIdentifier))")
                app.terminate()
            }
        }
    }

    private func checkAccessibility() -> Bool {
        let trusted = UIElement.isProcessTrusted(withPrompt: true)
        if !trusted {
            NSLog("[Streifen] Accessibility not granted — prompting user")
        }
        return trusted
    }
}
