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
}

extension Notification.Name {
    static let switchWorkspace = Notification.Name("streifen.switchWorkspace")
}
