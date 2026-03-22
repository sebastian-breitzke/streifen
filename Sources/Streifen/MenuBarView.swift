import SwiftUI

struct MenuBarView: View {
    @StateObject private var viewModel = MenuBarViewModel.shared

    var body: some View {
        Text("Workspace \(viewModel.activeWorkspace)")
            .font(.headline)

        Divider()

        ForEach(1...9, id: \.self) { ws in
            let count = viewModel.windowCounts[ws] ?? 0
            Button("[\(ws)] \(count) window\(count == 1 ? "" : "s")") {
                viewModel.switchToWorkspace(ws)
            }
            .keyboardShortcut(.none)
            .disabled(ws == viewModel.activeWorkspace)
        }

        Divider()

        Text("\(viewModel.totalWindows) windows tracked")
            .foregroundStyle(.secondary)

        Button("Reset — all to WS 1") {
            viewModel.resetAll()
        }

        Button("Restart Streifen") {
            viewModel.restart()
        }

        Divider()

        Button("Quit Streifen") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

@MainActor
final class MenuBarViewModel: ObservableObject {
    static let shared = MenuBarViewModel()

    @Published var activeWorkspace: Int = 1
    @Published var windowCounts: [Int: Int] = [:]
    @Published var totalWindows: Int = 0

    func switchToWorkspace(_ ws: Int) {
        NotificationCenter.default.post(
            name: .switchWorkspace,
            object: nil,
            userInfo: ["workspace": ws]
        )
    }

    func update(activeWorkspace: Int, windowCounts: [Int: Int], total: Int) {
        self.activeWorkspace = activeWorkspace
        self.windowCounts = windowCounts
        self.totalWindows = total
    }

    func resetAll() {
        NotificationCenter.default.post(name: .resetAllWorkspaces, object: nil)
    }

    func restart() {
        let executablePath = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        try? process.run()
        NSApplication.shared.terminate(nil)
    }
}

extension Notification.Name {
    static let switchWorkspace = Notification.Name("streifen.switchWorkspace")
    static let resetAllWorkspaces = Notification.Name("streifen.resetAll")
}
