import Cocoa

// MARK: - App Size System

enum AppSize: String, Sendable, Codable, CaseIterable {
    case xs, s, m, l, xl, full

    /// Resolve to a concrete width ratio based on screen class
    func ratio(for screenClass: ScreenClass) -> CGFloat {
        switch (self, screenClass) {
        case (.xs, .laptop):    return 0.33
        case (.xs, .desktop):   return 0.20
        case (.xs, .ultrawide): return 0.20

        case (.s, .laptop):     return 0.50
        case (.s, .desktop):    return 0.25
        case (.s, .ultrawide):  return 0.20

        case (.m, .laptop):     return 1.00
        case (.m, .desktop):    return 0.33
        case (.m, .ultrawide):  return 0.25

        case (.l, .laptop):     return 1.00
        case (.l, .desktop):    return 0.50
        case (.l, .ultrawide):  return 0.33

        case (.xl, .laptop):    return 1.00
        case (.xl, .desktop):   return 0.67
        case (.xl, .ultrawide): return 0.50

        case (.full, _):        return 1.00
        }
    }
}

enum ScreenClass: String, Sendable {
    case laptop     // aspect < 1.5
    case desktop    // 1.5 – 2.3
    case ultrawide  // ≥ 2.3

    static var current: ScreenClass {
        guard let screen = NSScreen.main?.visibleFrame else { return .desktop }
        let aspect = screen.width / screen.height
        if aspect >= 2.3 {
            return .ultrawide
        } else if aspect >= 1.5 {
            return .desktop
        } else {
            return .laptop
        }
    }
}

// MARK: - Config

struct StreifenConfig: Sendable {
    var gap: CGFloat
    var peekWidth: CGFloat
    /// Pinned apps: first window goes to target workspace, additional windows → current workspace
    var pinnedApps: [String: Int]  // bundleId → workspace

    /// Follow apps: when focused from another workspace, move to current workspace
    var followApps: Set<String>    // bundleIds

    /// App-specific T-Shirt sizes
    var appSizes: [String: AppSize]  // bundleId → size

    /// Default size for unknown apps
    var defaultSize: AppSize

    /// Resolve size for a bundle ID
    func sizeFor(bundleId: String?) -> AppSize {
        guard let bid = bundleId else { return defaultSize }
        return appSizes[bid] ?? defaultSize
    }

    static let `default` = StreifenConfig(
        gap: 10,
        peekWidth: 60,
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
        ],
        appSizes: [
            // Terminals → S
            "com.mitchellh.ghostty": .s,
            "com.apple.Terminal": .s,
            "com.googlecode.iterm2": .s,
            "dev.warp.Warp-Stable": .s,
            // Browsers → L
            "com.microsoft.edgemac": .l,
            "com.google.Chrome": .l,
            "com.apple.Safari": .l,
            "app.zen-browser.zen": .l,
            "org.mozilla.firefox": .l,
            // IDEs → L
            "com.microsoft.VSCode": .l,
            "com.jetbrains.rider": .l,
            "com.jetbrains.intellij": .l,
            "com.jetbrains.WebStorm": .l,
            // Communication → M
            "com.microsoft.teams2": .m,
            "com.microsoft.Outlook": .m,
            "com.tinyspeck.slackmacgap": .m,
            // Small tools → XS
            "com.apple.calculator": .xs,
            // Utilities → S
            "com.binarynights.ForkLift": .s,
            "com.apple.finder": .s,
            "com.spotify.client": .s,
        ],
        defaultSize: .l
    )
}
