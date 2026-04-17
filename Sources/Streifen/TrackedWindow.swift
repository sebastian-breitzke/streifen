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
    /// Minimum slice count this window can actually shrink to.
    /// Bumped by StripLayout when an app refuses AX resize below the target width
    /// (WhatsApp, Teams, etc. enforce an internal minimum width).
    var minSliceCount: Int = 1

    init(windowId: CGWindowID, axElement: UIElement, app: NSRunningApplication, frame: CGRect, appSize: AppSize) {
        self.windowId = windowId
        self.axElement = axElement
        self.app = app
        self.frame = frame
        self.virtualX = frame.origin.x
        self.appSize = appSize
        self.sliceCount = appSize.slices(for: ScreenClass.current)
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
        do {
            try axElement.setAttribute(.size, value: size)
            frame.size = size
        } catch {
            // AX resize failed — window may not support it or was destroyed
        }
    }

    func setFrame(_ rect: CGRect) {
        setPosition(rect.origin)
        setSize(rect.size)
    }

    /// Update size and recalculate slices for current screen
    func applySize(_ size: AppSize) {
        appSize = size
        let sc = ScreenClass.current
        sliceCount = max(minSliceCount, min(size.slices(for: sc), sc.totalSlices))
    }

    /// Set slice count directly, clamped to screen limits and the window's minimum.
    func setSliceCount(_ count: Int) {
        let sc = ScreenClass.current
        sliceCount = max(minSliceCount, min(count, sc.totalSlices))
    }
}
