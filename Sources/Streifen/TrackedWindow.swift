import Cocoa
import AXSwift

final class TrackedWindow: @unchecked Sendable {
    let windowId: CGWindowID
    let axElement: UIElement
    let app: NSRunningApplication
    var frame: CGRect
    var virtualX: CGFloat
    var widthRatio: CGFloat
    var category: String?

    init(windowId: CGWindowID, axElement: UIElement, app: NSRunningApplication, frame: CGRect) {
        self.windowId = windowId
        self.axElement = axElement
        self.app = app
        self.frame = frame
        self.virtualX = frame.origin.x
        self.widthRatio = 0.50
        self.category = nil
    }

    var bundleId: String? {
        app.bundleIdentifier
    }

    var title: String {
        (try? axElement.attribute(.title) as String?) ?? app.localizedName ?? "Unknown"
    }

    func setPosition(_ point: CGPoint) {
        do {
            try axElement.setAttribute(.position, value: point)
            frame.origin = point
        } catch {
            NSLog("[Streifen] Failed to set position for window \(windowId): \(error)")
        }
    }

    func setSize(_ size: CGSize) {
        do {
            try axElement.setAttribute(.size, value: size)
            frame.size = size
        } catch {
            NSLog("[Streifen] Failed to set size for window \(windowId): \(error)")
        }
    }

    func setFrame(_ rect: CGRect) {
        setPosition(rect.origin)
        setSize(rect.size)
    }
}
