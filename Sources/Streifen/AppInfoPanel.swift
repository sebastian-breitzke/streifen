import Cocoa
import SwiftUI

@MainActor
final class AppInfoPanel {
    static let shared = AppInfoPanel()

    private var panel: NSPanel?
    private var monitor: Any?

    typealias ChangeHandler = (AppSize, Int?, Bool, Bool) -> Void

    func show(
        appName: String,
        bundleId: String,
        icon: NSImage?,
        sliceCount: Int,
        workspace: Int,
        currentSize: AppSize,
        pinnedWorkspace: Int?,
        isFollow: Bool,
        isFloating: Bool,
        onChange: @escaping ChangeHandler
    ) {
        dismiss()

        let viewModel = AppInfoViewModel(
            appName: appName,
            bundleId: bundleId,
            icon: icon,
            sliceCount: sliceCount,
            workspace: workspace,
            size: currentSize,
            pinnedWorkspace: pinnedWorkspace,
            isFollow: isFollow,
            isFloating: isFloating,
            onChange: onChange
        )

        let view = NSHostingView(rootView: AppInfoView(viewModel: viewModel))
        let contentSize = NSSize(width: 320, height: 340)

        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.contentView = view
        p.animationBehavior = .utilityWindow

        // Center on managed screen
        let screen = NSScreen.managed ?? NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.frame
        let origin = NSPoint(
            x: screenFrame.midX - contentSize.width / 2,
            y: screenFrame.midY - contentSize.height / 2
        )
        p.setFrame(NSRect(origin: origin, size: contentSize), display: false)
        p.orderFrontRegardless()

        panel = p

        // Dismiss on click outside or Escape
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }

            if event.type == .keyDown {
                // Escape
                if event.keyCode == 53 {
                    self.dismiss()
                    return nil
                }
                // Any Hyper combo — dismiss and pass through
                let flags = event.modifierFlags.intersection([.control, .option, .command])
                if flags == [.control, .option, .command] {
                    self.dismiss()
                    return event
                }
            }

            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if event.window != panel {
                    self.dismiss()
                }
            }

            return event
        }
    }

    func dismiss() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - View Model

@MainActor
final class AppInfoViewModel: ObservableObject {
    let appName: String
    let bundleId: String
    let icon: NSImage?
    let sliceCount: Int
    let workspace: Int

    @Published var size: AppSize
    @Published var pinnedWorkspace: Int?
    @Published var isFollow: Bool
    @Published var isFloating: Bool

    private let onChange: AppInfoPanel.ChangeHandler

    init(
        appName: String,
        bundleId: String,
        icon: NSImage?,
        sliceCount: Int,
        workspace: Int,
        size: AppSize,
        pinnedWorkspace: Int?,
        isFollow: Bool,
        isFloating: Bool,
        onChange: @escaping AppInfoPanel.ChangeHandler
    ) {
        self.appName = appName
        self.bundleId = bundleId
        self.icon = icon
        self.sliceCount = sliceCount
        self.workspace = workspace
        self.size = size
        self.pinnedWorkspace = pinnedWorkspace
        self.isFollow = isFollow
        self.isFloating = isFloating
        self.onChange = onChange
    }

    func apply() {
        onChange(size, pinnedWorkspace, isFollow, isFloating)
    }
}

// MARK: - SwiftUI View

private struct AppInfoView: View {
    @ObservedObject var viewModel: AppInfoViewModel
    @Environment(\.colorScheme) var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    private let sizes: [AppSize] = [.xs, .s, .m, .l, .xl]

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack(spacing: 12) {
                if let icon = viewModel.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 48, height: 48)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.appName)
                        .font(.system(size: 16, weight: .bold))
                    Text(viewModel.bundleId)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("\(viewModel.sliceCount) slices · WS \(viewModel.workspace)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            // Size
            VStack(alignment: .leading, spacing: 6) {
                Text("SIZE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .tracking(2)

                HStack(spacing: 4) {
                    ForEach(sizes, id: \.rawValue) { size in
                        Button {
                            viewModel.size = size
                            viewModel.apply()
                        } label: {
                            Text(size.rawValue.uppercased())
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .frame(width: 44, height: 28)
                                .background(
                                    viewModel.size == size
                                        ? Color.streifenBlue.opacity(0.8)
                                        : (isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                                )
                                .foregroundStyle(viewModel.size == size ? .white : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Pinned workspace
            VStack(alignment: .leading, spacing: 6) {
                Text("PINNED WORKSPACE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .tracking(2)

                HStack(spacing: 3) {
                    Button {
                        viewModel.pinnedWorkspace = nil
                        viewModel.apply()
                    } label: {
                        Text("—")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .frame(width: 28, height: 28)
                            .background(
                                viewModel.pinnedWorkspace == nil
                                    ? Color.streifenPurple.opacity(0.8)
                                    : (isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                            )
                            .foregroundStyle(viewModel.pinnedWorkspace == nil ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)

                    ForEach(1...9, id: \.self) { ws in
                        Button {
                            viewModel.pinnedWorkspace = ws
                            viewModel.apply()
                        } label: {
                            Text("\(ws)")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .frame(width: 24, height: 28)
                                .background(
                                    viewModel.pinnedWorkspace == ws
                                        ? Color.streifenPurple.opacity(0.8)
                                        : (isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                                )
                                .foregroundStyle(viewModel.pinnedWorkspace == ws ? .white : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Toggles
            HStack(spacing: 12) {
                toggleButton(label: "Follow", isOn: viewModel.isFollow, color: .streifenMint) {
                    viewModel.isFollow.toggle()
                    viewModel.apply()
                }
                toggleButton(label: "Floating", isOn: viewModel.isFloating, color: .streifenGold) {
                    viewModel.isFloating.toggle()
                    viewModel.apply()
                }
                Spacer()
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isDark ? Color(white: 0.12) : Color(red: 0.98, green: 0.97, blue: 0.95))
                .shadow(color: .black.opacity(isDark ? 0.5 : 0.15), radius: 20, y: 6)
        )
    }

    private func toggleButton(label: String, isOn: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    isOn
                        ? color.opacity(0.8)
                        : (isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                )
                .foregroundStyle(isOn ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
