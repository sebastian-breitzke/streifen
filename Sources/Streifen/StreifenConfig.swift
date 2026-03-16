import Foundation

struct StreifenConfig: Sendable {
    var gap: CGFloat
    var peekWidth: CGFloat
    var cycleWidths: [CGFloat]

    /// Pinned apps: first window goes to target workspace, additional windows → current workspace
    var pinnedApps: [String: Int]  // bundleId → workspace

    /// Follow apps: when focused from another workspace, move to current workspace
    var followApps: Set<String>    // bundleIds

    static let `default` = StreifenConfig(
        gap: 10,
        peekWidth: 60,
        cycleWidths: [0.25, 1.0/3.0, 0.50, 2.0/3.0, 0.75, 1.0],
        pinnedApps: [
            // Business Communication → WS 1
            "com.microsoft.teams2": 1,
            "com.microsoft.Outlook": 1,
            "us.zoom.xos": 1,
            "com.electron.realtimeboard": 1,  // Miro
            // Private → WS 3
            "com.tdesktop.Telegram": 3,
            "net.whatsapp.WhatsApp": 3,
            "org.whispersystems.signal-desktop": 3,
            "com.hnc.Discord": 3,
        ],
        followApps: [
            "com.binarynights.ForkLift",
            "com.apple.finder",
            "com.apple.calculator",
        ]
    )
}
