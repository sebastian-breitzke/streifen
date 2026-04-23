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
    /// Consecutive prune cycles where AX position was unreadable but window wasn't pruned.
    /// Reset to 0 when position becomes readable again.
    var staleCount: Int = 0

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

    /// Consecutive AX set failures — log first, then every 10th to avoid flooding
    private var axFailCount: Int = 0

    func setPosition(_ point: CGPoint) {
        do {
            try axElement.setAttribute(.position, value: point)
            frame.origin = point
            axFailCount = 0
        } catch {
            axFailCount += 1
            if axFailCount == 1 || axFailCount % 10 == 0 {
                slog("AX setPosition failed (\(axFailCount)x) window \(windowId): \(app.localizedName ?? "?") — \(error)")
            }
        }
    }

    func setSize(_ size: CGSize) {
        do {
            try axElement.setAttribute(.size, value: size)
            frame.size = size
        } catch {
            axFailCount += 1
            if axFailCount == 1 || axFailCount % 10 == 0 {
                slog("AX setSize failed (\(axFailCount)x) window \(windowId): \(app.localizedName ?? "?") — \(error)")
            }
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
