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
    var resizable: Bool = true

    init(windowId: CGWindowID, axElement: UIElement, app: NSRunningApplication, frame: CGRect) {
        self.windowId = windowId
        self.axElement = axElement
        self.app = app
        self.frame = frame
        self.virtualX = frame.origin.x
        // Derive initial width ratio from actual window width vs screen
        let screenWidth = NSScreen.main?.visibleFrame.width ?? 1920
        self.widthRatio = min(max(frame.width / screenWidth, 0.15), 1.0)
        self.category = nil
        // Check if window is resizable
        self.resizable = (try? axElement.attributeIsSettable(.size)) ?? false
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
            // Silently ignore — window may have been destroyed
        }
    }

    func setSize(_ size: CGSize) {
        guard resizable else { return }
        do {
            try axElement.setAttribute(.size, value: size)
            frame.size = size
        } catch {
            // Mark as non-resizable to avoid future attempts
            resizable = false
        }
    }

    func setFrame(_ rect: CGRect) {
        setPosition(rect.origin)
        setSize(rect.size)
    }
}
