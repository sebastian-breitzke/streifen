import Cocoa

@MainActor
final class StripLayout {
    var config: StreifenConfig

    init(config: StreifenConfig) {
        self.config = config
    }

    /// Lay out all windows in the workspace horizontally.
    ///
    /// Apps like WhatsApp and Teams enforce a minimum window width and silently
    /// ignore AX size requests below that threshold. We detect this by re-reading
    /// the actual AX size after setFrame; when an app refused to shrink, we bump
    /// its `minSliceCount` so the next layout pass allocates a slot that fits.
    /// A single re-layout pass resolves the mismatch.
    func layout(workspace: Workspace, screenFrame: CGRect) {
        layoutPass(workspace: workspace, screenFrame: screenFrame, remainingRetries: 1)
    }

    private func layoutPass(workspace: Workspace, screenFrame: CGRect, remainingRetries: Int) {
        let gap = config.gap
        let windows = workspace.windows
        guard !windows.isEmpty else { return }

        let availableHeight = screenFrame.height - (2 * gap)
        let y = screenFrame.origin.y + gap

        var x = screenFrame.origin.x + gap + workspace.scrollOffset

        let sc = ScreenClass.current
        var needsRelayout = false

        for window in windows {
            let windowWidth = screenFrame.width * CGFloat(window.sliceCount) / CGFloat(sc.totalSlices) - (2 * gap)
            let clampedWidth = max(windowWidth, 200) // minimum 200px

            // Calculate virtual position
            window.virtualX = x

            // Clamp to screen bounds
            let visibleFrame: CGRect
            if x + clampedWidth < screenFrame.origin.x || x > screenFrame.maxX {
                // Fully off-screen: park far away
                visibleFrame = CGRect(
                    x: offscreenPark.x,
                    y: offscreenPark.y,
                    width: clampedWidth,
                    height: availableHeight
                )
            } else {
                // Visible or partially visible
                visibleFrame = CGRect(
                    x: x,
                    y: y,
                    width: clampedWidth,
                    height: availableHeight
                )
            }

            window.setFrame(visibleFrame)

            // Detect apps that refused to shrink and bump their min slice count.
            if syncMinSliceCount(window: window, targetWidth: clampedWidth,
                                 screenWidth: screenFrame.width, gap: gap,
                                 totalSlices: sc.totalSlices) {
                needsRelayout = true
            }

            x += clampedWidth + gap
        }

        if needsRelayout && remainingRetries > 0 {
            layoutPass(workspace: workspace, screenFrame: screenFrame,
                       remainingRetries: remainingRetries - 1)
        }
    }

    /// After setFrame, check whether the app honored the requested width.
    /// Returns true if `window.sliceCount` was bumped and a re-layout is needed.
    private func syncMinSliceCount(window: TrackedWindow, targetWidth: CGFloat,
                                   screenWidth: CGFloat, gap: CGFloat,
                                   totalSlices: Int) -> Bool {
        // Tolerance covers sub-pixel AX rounding; real refusals are tens of pixels.
        let tolerance: CGFloat = 10
        guard let actual: CGSize = try? window.axElement.attribute(.size),
              actual.width > targetWidth + tolerance else { return false }

        // Slot width for N slices: screenWidth * N / totalSlices - 2*gap ≥ actual.width
        // → N ≥ (actual.width + 2*gap) * totalSlices / screenWidth
        let slicesNeeded = Int(ceil((actual.width + 2 * gap) * CGFloat(totalSlices) / screenWidth))
        let newMin = max(1, min(slicesNeeded, totalSlices))

        guard newMin > window.minSliceCount else { return false }
        window.minSliceCount = newMin

        if window.sliceCount < newMin {
            window.sliceCount = newMin
            slog("Bumped \(window.app.localizedName ?? "?") minSliceCount → \(newMin) (actual width \(Int(actual.width)) > target \(Int(targetWidth)))")
            return true
        }
        return false
    }

    /// Total strip width for all windows
    func totalWidth(workspace: Workspace, screenFrame: CGRect) -> CGFloat {
        let gap = config.gap
        let sc = ScreenClass.current
        var total: CGFloat = gap
        for window in workspace.windows {
            let windowWidth = screenFrame.width * CGFloat(window.sliceCount) / CGFloat(sc.totalSlices) - (2 * gap)
            total += max(windowWidth, 200) + gap
        }
        return total
    }
}
