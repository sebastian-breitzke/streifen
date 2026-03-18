import Cocoa
import AXSwift

final class TrackedWindow: @unchecked Sendable {
    let windowId: CGWindowID
    let axElement: UIElement
    let app: NSRunningApplication
    var frame: CGRect
    var virtualX: CGFloat
    var sliceCount: Int
    var appSize: AppSize
    var category: String?
    var resizable: Bool = true

    init(windowId: CGWindowID, axElement: UIElement, app: NSRunningApplication, frame: CGRect, appSize: AppSize) {
        self.windowId = windowId
        self.axElement = axElement
        self.app = app
        self.frame = frame
        self.virtualX = frame.origin.x
        self.appSize = appSize
        self.sliceCount = appSize.slices(for: ScreenClass.current)
        self.category = nil
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

    /// Update size and recalculate slices for current screen
    func applySize(_ size: AppSize) {
        appSize = size
        sliceCount = size.slices(for: ScreenClass.current)
    }

    /// Set slice count directly, clamped to screen limits
    func setSliceCount(_ count: Int) {
        let sc = ScreenClass.current
        sliceCount = max(1, min(count, sc.totalSlices))
    }
}
