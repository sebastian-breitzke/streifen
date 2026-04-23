import Cocoa
import AXSwift

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowTracker: WindowTracker?
    private var workspaceManager: WorkspaceManager?
    private var hotkeyManager: HotkeyManager?
    private var stripLayout: StripLayout?
    private var debugServer: DebugServer?
    private var accessibilityTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        killOtherInstances()

        if UIElement.isProcessTrusted(withPrompt: true) {
            startEngine()
        } else {
            slog("lifecycle", "waiting_for_accessibility")
            accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                guard UIElement.isProcessTrusted(withPrompt: false) else { return }
                timer.invalidate()
                DispatchQueue.main.async {
                    self?.accessibilityTimer = nil
                    self?.startEngine()
                }
            }
        }
    }

    private func startEngine() {
        slog("lifecycle", "accessibility_granted")
        let config = StreifenConfig.load()
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

        debugServer = DebugServer(workspaceManager: workspaceManager!)
        debugServer?.start()

        slog("lifecycle", "tracking_started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        debugServer?.stop()
        // Crash safety: move all windows back on-screen
        workspaceManager?.restoreAllWindowsOnScreen()
        // Dev mode: re-enable brew service on exit
        restoreBrewService()
        slog("lifecycle", "shutdown")
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
            slog("lifecycle", "brew_stopped")
            return
        }

        // Non-dev: kill other instances by name or bundle ID
        let all = NSWorkspace.shared.runningApplications
        for app in all {
            if app.processIdentifier != myPid,
               app.localizedName?.lowercased() == "streifen" || app.bundleIdentifier == "de.s16e.streifen" {
                slog("lifecycle", "killed_old", ["pid": app.processIdentifier])
                app.terminate()
            }
        }
    }

    private func restoreBrewService() {
        guard isDevBuild else { return }
        let plistPath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/LaunchAgents/\(Self.serviceLabel).plist"
        guard FileManager.default.fileExists(atPath: plistPath) else { return }
        launchctl("bootstrap", "gui/\(getuid())", plistPath)
        slog("lifecycle", "brew_restored")
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

}
