import Cocoa

// MARK: - Managed Screen

extension NSScreen {
    /// The screen Streifen manages — the widest connected screen.
    /// Unlike `.main` (which follows keyboard focus and can flip between
    /// displays), this is stable regardless of which app is focused.
    static var managed: NSScreen? {
        NSScreen.screens.max(by: { $0.visibleFrame.width < $1.visibleFrame.width })
    }
}

// MARK: - App Size System

enum AppSize: String, Sendable, Codable, CaseIterable {
    case xs, s, m, l, xl, full

    /// Default slice count for this size on a given screen class
    func slices(for screenClass: ScreenClass) -> Int {
        switch (self, screenClass) {
        case (.xs, _):            return 1
        case (.s,  _):            return 2
        case (.m,  .laptop):      return 4
        case (.m,  .desktop):     return 2
        case (.m,  .ultrawide):   return 3
        case (.l,  .laptop):      return 4
        case (.l,  .desktop):     return 3
        case (.l,  .ultrawide):   return 3
        case (.xl, .laptop):      return 4
        case (.xl, .desktop):     return 4
        case (.xl, .ultrawide):   return 6
        case (.full, .laptop):    return 4
        case (.full, .desktop):   return 6
        case (.full, .ultrawide): return 8
        }
    }
}

enum ScreenClass: String, Sendable {
    case laptop     // aspect < 1.5
    case desktop    // 1.5 – 2.3
    case ultrawide  // ≥ 2.3

    /// Total number of horizontal slices for this screen class
    var totalSlices: Int {
        switch self {
        case .laptop:    return 4
        case .desktop:   return 6
        case .ultrawide: return 8
        }
    }

    static var current: ScreenClass {
        guard let screen = NSScreen.managed?.visibleFrame else { return .desktop }
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

struct StreifenConfig: Sendable, Codable {
    var gap: CGFloat
    /// Pinned apps: first window goes to target workspace, additional windows → current workspace
    var pinnedApps: [String: Int]  // bundleId → workspace

    /// Follow apps: when focused from another workspace, move to current workspace
    var followApps: Set<String>    // bundleIds

    /// Floating apps: tracked but not in strip layout, always visible, survive workspace switches
    var floatingApps: Set<String>  // bundleIds

    /// App-specific T-Shirt sizes
    var appSizes: [String: AppSize]  // bundleId → size

    /// Learned minimum widths (px) — apps that refuse to shrink below this
    var appMinWidths: [String: CGFloat]  // bundleId → minimum pixel width

    /// Default size for unknown apps
    var defaultSize: AppSize

    /// Resolve size for a bundle ID
    func sizeFor(bundleId: String?) -> AppSize {
        guard let bid = bundleId else { return defaultSize }
        return appSizes[bid] ?? defaultSize
    }

    /// Calculate persisted minSliceCount for current screen class
    func minSlicesFor(bundleId: String?, screenWidth: CGFloat, gap: CGFloat, totalSlices: Int) -> Int {
        guard let bid = bundleId, let minWidth = appMinWidths[bid] else { return 1 }
        return max(1, min(Int(ceil((minWidth + 2 * gap) * CGFloat(totalSlices) / screenWidth)), totalSlices))
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case gap, pinnedApps, followApps, floatingApps, appSizes, appMinWidths, defaultSize
    }

    init(
        gap: CGFloat,
        pinnedApps: [String: Int],
        followApps: Set<String>,
        floatingApps: Set<String>,
        appSizes: [String: AppSize],
        appMinWidths: [String: CGFloat] = [:],
        defaultSize: AppSize
    ) {
        self.gap = gap
        self.pinnedApps = pinnedApps
        self.followApps = followApps
        self.floatingApps = floatingApps
        self.appSizes = appSizes
        self.appMinWidths = appMinWidths
        self.defaultSize = defaultSize
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gap = try c.decode(CGFloat.self, forKey: .gap)
        pinnedApps = try c.decode([String: Int].self, forKey: .pinnedApps)
        followApps = try c.decode(Set<String>.self, forKey: .followApps)
        floatingApps = try c.decode(Set<String>.self, forKey: .floatingApps)
        appSizes = try c.decode([String: AppSize].self, forKey: .appSizes)
        appMinWidths = (try? c.decode([String: CGFloat].self, forKey: .appMinWidths)) ?? [:]
        defaultSize = try c.decode(AppSize.self, forKey: .defaultSize)
    }

    // MARK: - File Persistence

    private static let configURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/streifen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()

    static func load() -> StreifenConfig {
        let url = configURL
        if let data = try? Data(contentsOf: url),
           let config = try? JSONDecoder().decode(StreifenConfig.self, from: data) {
            slog("Config loaded from \(url.path)")
            return config
        }
        // First launch or corrupt file — write defaults
        let config = StreifenConfig.hardcodedDefault
        config.save()
        slog("Config written to \(url.path) (defaults)")
        return config
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.configURL, options: .atomic)
    }

    static let hardcodedDefault = StreifenConfig(
        gap: 10,
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
        ],
        floatingApps: [
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
            // Code Editor → L
            "com.microsoft.VSCode": .l,
            // IDEs → XL
            "com.jetbrains.rider": .xl,
            "com.jetbrains.intellij": .xl,
            "com.jetbrains.WebStorm": .xl,
            // Spreadsheet → XL
            "com.microsoft.Excel": .xl,
            // Communication → M
            "com.microsoft.teams2": .m,
            "com.microsoft.Outlook": .m,
            "com.tinyspeck.slackmacgap": .m,
            "com.tdesktop.Telegram": .m,
            "net.whatsapp.WhatsApp": .m,
            "org.whispersystems.signal-desktop": .m,
            "com.hnc.Discord": .m,
            // Video → M
            "us.zoom.xos": .m,
            "com.electron.realtimeboard": .m,
            // Calculator is floating (see floatingApps)
            // Utilities → S
            "com.binarynights.ForkLift": .s,
            "com.apple.finder": .s,
            "com.spotify.client": .s,
        ],
        defaultSize: .l
    )
}
