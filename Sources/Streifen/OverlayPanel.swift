import Cocoa
import SwiftUI

/// Transparent HUD overlay that briefly shows action feedback (workspace switch, slice count, etc.)
@MainActor
final class OverlayPanel {
    static let shared = OverlayPanel()

    private var panel: NSPanel?
    private var hideTask: DispatchWorkItem?

    private let panelSize = NSSize(width: 200, height: 120)
    private let displayDuration: TimeInterval = 0.6
    private let fadeDuration: TimeInterval = 0.25

    /// Show a workspace switch indicator
    func showWorkspace(_ number: Int) {
        show(primary: "\(number)", secondary: "Workspace")
    }

    /// Show slice count change
    func showSlices(_ count: Int, total: Int) {
        let bar = String(repeating: "▮", count: count) + String(repeating: "▯", count: total - count)
        show(primary: bar, secondary: "\(count) / \(total) slices", fontSize: 18)
    }

    /// Show app default set
    func showAppDefault(_ sizeName: String, appName: String) {
        show(primary: sizeName, secondary: appName, fontSize: 36)
    }

    /// Show a generic message
    func showMessage(_ text: String) {
        show(primary: text, secondary: nil, fontSize: 28)
    }

    // MARK: - Internal

    private func show(primary: String, secondary: String?, fontSize: CGFloat = 56) {
        hideTask?.cancel()

        let view = NSHostingView(rootView: OverlayView(
            primary: primary,
            secondary: secondary,
            fontSize: fontSize
        ))

        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(origin: .zero, size: panelSize),
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
    let fontSize: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            Text(primary)
                .font(.system(size: fontSize, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)

            if let secondary {
                Text(secondary)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .textCase(.uppercase)
                    .tracking(2)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.75))
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
    }
}
