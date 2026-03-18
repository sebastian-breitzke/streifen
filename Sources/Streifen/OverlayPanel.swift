import Cocoa
import SwiftUI

// Streifen brand colors
extension Color {
    static let streifenBlue   = Color(red: 0x7B/255, green: 0xA3/255, blue: 0xC9/255) // #7BA3C9
    static let streifenMint   = Color(red: 0x7D/255, green: 0xC9/255, blue: 0xA7/255) // #7DC9A7
    static let streifenGold   = Color(red: 0xE8/255, green: 0xC8/255, blue: 0x5A/255) // #E8C85A
    static let streifenOrange = Color(red: 0xE0/255, green: 0x95/255, blue: 0x60/255) // #E09560
    static let streifenPurple = Color(red: 0x9B/255, green: 0x82/255, blue: 0xB5/255) // #9B82B5
}

/// Transparent HUD overlay that briefly shows action feedback (workspace switch, slice count, etc.)
@MainActor
final class OverlayPanel {
    static let shared = OverlayPanel()

    private var panel: NSPanel?
    private var hideTask: DispatchWorkItem?

    private let displayDuration: TimeInterval = 0.6
    private let fadeDuration: TimeInterval = 0.25

    /// Show a workspace switch indicator
    func showWorkspace(_ number: Int) {
        show(primary: "\(number)", secondary: "Workspace", accent: .streifenBlue)
    }

    /// Show slice count change
    func showSlices(_ count: Int, total: Int) {
        let bar = String(repeating: "▮", count: count) + String(repeating: "▯", count: total - count)
        show(primary: bar, secondary: "\(count) / \(total) slices", accent: .streifenGold, fontSize: 18)
    }

    /// Show app default set
    func showAppDefault(_ sizeName: String, appName: String) {
        show(primary: sizeName, secondary: appName, accent: .streifenOrange, fontSize: 36)
    }

    /// Show window moved to another workspace
    func showMovedToWorkspace(_ number: Int) {
        show(primary: "→ \(number)", secondary: "Moved", accent: .streifenPurple, fontSize: 36)
    }

    /// Show window reorder position
    func showReorder(position: Int, total: Int, direction: String) {
        show(primary: "\(direction) \(position)/\(total)", secondary: "Position", accent: .streifenMint, fontSize: 28)
    }

    /// Show a generic message
    func showMessage(_ text: String) {
        show(primary: text, secondary: nil, accent: .streifenMint, fontSize: 28)
    }

    // MARK: - Internal

    private func show(primary: String, secondary: String?, accent: Color = .white, fontSize: CGFloat = 56) {
        hideTask?.cancel()

        let view = NSHostingView(rootView: OverlayView(
            primary: primary,
            secondary: secondary,
            accent: accent,
            fontSize: fontSize
        ))

        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(origin: .zero, size: NSSize(width: 200, height: 120)),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            p.ignoresMouseEvents = true
            p.animationBehavior = .none
            panel = p
        }

        guard let panel else { return }

        // Size to content
        let fittingSize = view.fittingSize
        let contentSize = NSSize(
            width: max(fittingSize.width + 48, 140),
            height: max(fittingSize.height + 32, 80)
        )

        // Center on managed screen
        let screen = NSScreen.managed ?? NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.frame
        let origin = NSPoint(
            x: screenFrame.midX - contentSize.width / 2,
            y: screenFrame.midY - contentSize.height / 2 + screenFrame.height * 0.1
        )

        panel.setFrame(NSRect(origin: origin, size: contentSize), display: false)
        panel.contentView = view
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        // Schedule hide
        let task = DispatchWorkItem { [weak self] in
            self?.fadeOut()
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration, execute: task)
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = fadeDuration
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
        }
    }
}

// MARK: - SwiftUI View

private struct OverlayView: View {
    let primary: String
    let secondary: String?
    let accent: Color
    let fontSize: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            Text(primary)
                .font(.system(size: fontSize, weight: .black, design: .rounded))
                .foregroundStyle(accent)
                .minimumScaleFactor(0.5)
                .lineLimit(1)

            if let secondary {
                Text(secondary)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .textCase(.uppercase)
                    .tracking(2)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.8))
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
    }
}
