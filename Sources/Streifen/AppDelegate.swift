import Cocoa
import AXSwift

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowTracker: WindowTracker?
    private var workspaceManager: WorkspaceManager?
    private var hotkeyManager: HotkeyManager?
    private var trackpadGestureManager: TrackpadGestureManager?
    private var stripLayout: StripLayout?
    private var debugServer: DebugServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        killOtherInstances()
        guard checkAccessibility() else { return }

        let config = StreifenConfig.load()
        windowTracker = WindowTracker(config: config)
        workspaceManager = WorkspaceManager(config: config)
        stripLayout = StripLayout(config: config)
        hotkeyManager = HotkeyManager(workspaceManager: workspaceManager!, stripLayout: stripLayout!)
        trackpadGestureManager = TrackpadGestureManager(workspaceManager: workspaceManager!)

        // Wire up cross-references
        workspaceManager!.setWindowTracker(windowTracker!)
        workspaceManager!.setStripLayout(stripLayout!)

        windowTracker?.onAppActivated = { [weak self] app in
            self?.workspaceManager?.handleAppActivated(app)
        }

        windowTracker?.onWindowFocused = { [weak self] windowId in
            // AX focusedWindowChanged: only update focus within active workspace.
            // Never switch workspaces — that's handleAppActivated's job.
            self?.workspaceManager?.handleWindowFocused(windowId: windowId, allowWorkspaceSwitch: false)
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

        windowTracker?.onWindowResized = { [weak self] windowId in
            self?.workspaceManager?.handleManualResize(windowId: windowId)
        }

        windowTracker?.onWindowMinimizeChanged = { [weak self] windowId, minimized in
            self?.workspaceManager?.handleWindowMinimizeChanged(windowId: windowId, minimized: minimized)
        }

        hotkeyManager?.registerHotkeys()
        trackpadGestureManager?.start()

        debugServer = DebugServer(workspaceManager: workspaceManager!)
        debugServer?.start()

        slog("Started — tracking windows")
    }

    func applicationWillTerminate(_ notification: Notification) {
        trackpadGestureManager?.stop()
        debugServer?.stop()
        // Crash safety: move all windows back on-screen
        workspaceManager?.restoreAllWindowsOnScreen()
        // Dev mode: re-enable brew service on exit
        restoreBrewService()
        slog("Shutdown — windows restored")
    }

    private static let serviceLabel = "homebrew.mxcl.streifen"

    private func killOtherInstances() {
        let myPid = ProcessInfo.processInfo.processIdentifier

        // Dev build: stop brew service via launchctl so keep_alive doesn't restart.
        // bootout kills the process AND removes the service — wait for it to exit.
        if isDevBuild {
            launchctl("bootout", "gui/\(getuid())/\(Self.serviceLabel)")
            // Wait for the brew process to actually exit
            for _ in 0..<20 {
                let others = NSWorkspace.shared.runningApplications.filter {
                    $0.processIdentifier != myPid &&
                    ($0.localizedName?.lowercased() == "streifen" || $0.bundleIdentifier == "de.s16e.streifen")
                }
                if others.isEmpty { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            slog("Stopped brew service (dev mode)")
            return
        }

        // Non-dev: kill other instances by name or bundle ID
        let all = NSWorkspace.shared.runningApplications
        for app in all {
            if app.processIdentifier != myPid,
               app.localizedName?.lowercased() == "streifen" || app.bundleIdentifier == "de.s16e.streifen" {
                slog("Killing old instance (pid \(app.processIdentifier))")
                app.terminate()
            }
        }
    }

    private func restoreBrewService() {
        guard isDevBuild else { return }
        let plistPath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/LaunchAgents/\(Self.serviceLabel).plist"
        guard FileManager.default.fileExists(atPath: plistPath) else { return }
        launchctl("bootstrap", "gui/\(getuid())", plistPath)
        slog("Re-enabled brew service")
    }

    private func launchctl(_ args: String...) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    private func checkAccessibility() -> Bool {
        let trusted = UIElement.isProcessTrusted(withPrompt: true)
        if !trusted {
            slog("Accessibility not granted — prompting user")
        }
        return trusted
    }
}
