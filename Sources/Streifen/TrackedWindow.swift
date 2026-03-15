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
        // Default width ratio based on screen aspect ratio
        self.widthRatio = TrackedWindow.defaultWidthRatio()
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

    /// Default width ratio based on screen aspect ratio:
    /// Ultrawide (≥2.3:1) → 1/3, Wide (≥1.5:1) → 1/2, Normal → 1/1
    static func defaultWidthRatio() -> CGFloat {
        guard let screen = NSScreen.main?.visibleFrame else { return 0.5 }
        let aspect = screen.width / screen.height
        if aspect >= 2.3 {
            return 1.0 / 3.0  // ultrawide
        } else if aspect >= 1.5 {
            return 0.5         // wide (16:10, 16:9)
        } else {
            return 1.0         // normal / portrait
        }
    }
}
