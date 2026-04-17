import AppKit
import Foundation

/// Per-app helper that asks an app to create a new top-level window via AppleScript.
///
/// Success here means "the script ran without error" — not "a new window is visible
/// to AX yet". Callers must still wait for the new window to show up through the
/// normal `WindowTracker` → `handleWindowsUpdate` path and time out gracefully.
enum LocalWindowSpawner {
    /// Bundle-ID → AppleScript source for creating a new window.
    /// Apps not listed here are considered unsupported and cause immediate fallback.
    private static let scripts: [String: String] = [
        // Browsers
        "com.apple.Safari":        "tell application \"Safari\" to make new document",
        "com.google.Chrome":       "tell application \"Google Chrome\" to make new window",
        "com.microsoft.edgemac":   "tell application \"Microsoft Edge\" to make new window",
        // Firefox/Zen expose OpenURL rather than a clean "make new window";
        // opening about:blank reliably creates a window without spawning a new process.
        "org.mozilla.firefox":     "tell application \"Firefox\" to OpenURL \"about:blank\"",
        "app.zen-browser.zen":     "tell application \"Zen\" to OpenURL \"about:blank\"",
        // Terminals
        "com.apple.Terminal":      "tell application \"Terminal\" to do script \"\"",
        "com.googlecode.iterm2":   "tell application \"iTerm\" to create window with default profile",
        "com.mitchellh.ghostty":   "tell application \"Ghostty\" to make new window",
        "dev.warp.Warp-Stable":    "tell application \"Warp\" to make new window",
    ]

    static func isSupported(bundleId: String) -> Bool {
        scripts[bundleId] != nil
    }

    /// Runs the per-app "new window" AppleScript synchronously on the calling thread.
    /// Returns true if the script executed without error.
    ///
    /// First invocation per target app triggers the macOS Automation permission
    /// prompt. If the user denies or automation is otherwise unavailable the script
    /// returns error `-1743`, which is surfaced as `false` here.
    static func spawnNewWindow(bundleId: String) -> Bool {
        guard let source = scripts[bundleId] else {
            slog("LocalWindowSpawner: no script for \(bundleId)")
            return false
        }
        guard let script = NSAppleScript(source: source) else {
            slog("LocalWindowSpawner: NSAppleScript init failed for \(bundleId)")
            return false
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        if let error = error {
            slog("LocalWindowSpawner: execute failed for \(bundleId): \(error)")
            return false
        }
        slog("LocalWindowSpawner: spawn ok for \(bundleId)")
        return true
    }
}
