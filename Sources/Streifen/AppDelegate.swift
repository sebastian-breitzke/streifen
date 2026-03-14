import Cocoa
import AXSwift

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowTracker: WindowTracker?
    private var workspaceManager: WorkspaceManager?
    private var hotkeyManager: HotkeyManager?
    private var stripLayout: StripLayout?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard checkAccessibility() else { return }

        let config = StreifenConfig.default
        windowTracker = WindowTracker()
        workspaceManager = WorkspaceManager(config: config)
        stripLayout = StripLayout(config: config)
        hotkeyManager = HotkeyManager(workspaceManager: workspaceManager!, stripLayout: stripLayout!)

        windowTracker?.onWindowsChanged = { [weak self] windows in
            self?.workspaceManager?.handleWindowsUpdate(windows)
        }

        windowTracker?.startTracking()
        hotkeyManager?.registerHotkeys()

        NSLog("[Streifen] Started — tracking windows")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Crash safety: move all windows back on-screen
        workspaceManager?.restoreAllWindowsOnScreen()
        NSLog("[Streifen] Shutdown — windows restored")
    }

    private func checkAccessibility() -> Bool {
        let trusted = UIElement.isProcessTrusted(withPrompt: true)
        if !trusted {
            NSLog("[Streifen] Accessibility not granted — prompting user")
        }
        return trusted
    }
}
