import SwiftUI

@main
struct StreifenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Streifen", systemImage: "rectangle.split.3x1") {
            MenuBarView()
        }
        .menuBarExtraStyle(.menu)
    }
}
