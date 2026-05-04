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
            if syncMinSliceCount(window: window, targetOrigin: visibleFrame.origin,
                                 targetWidth: clampedWidth,
                                 screenWidth: screenFrame.width, gap: gap,
                                 totalSlices: sc.totalSlices) {
                needsRelayout = true
            }

            x += clampedWidth + gap
        }

        if needsRelayout && remainingRetries > 0 {
            layoutPass(workspace: workspace, screenFrame: screenFrame,
                       remainingRetries: remainingRetries - 1)
        } else if needsRelayout {
            // Retry exhausted but still mismatched — log for diagnostics
            for window in windows where window.minSliceCount > 1 {
                if let actual: CGSize = try? window.axElement.attribute(.size) {
                    let allocated = screenFrame.width * CGFloat(window.sliceCount) / CGFloat(sc.totalSlices) - (2 * gap)
                    if actual.width > allocated + 10 {
                        slog("resize", "min_mismatch", ["app": window.app.localizedName ?? "?", "actual": Int(actual.width), "alloc": Int(allocated), "s": window.sliceCount, "total": sc.totalSlices])
                    }
                }
            }
        }
    }

    /// After setFrame, check whether the app honored the requested width.
    /// Returns true if `window.sliceCount` was bumped and a re-layout is needed.
    /// Persists learned minimum width in config so future layouts start correct.
    private func syncMinSliceCount(window: TrackedWindow, targetOrigin: CGPoint,
                                   targetWidth: CGFloat,
                                   screenWidth: CGFloat, gap: CGFloat,
                                   totalSlices: Int) -> Bool {
        // At max slices, the slot already spans the full screen minus gaps.
        // Apps that ignore the gap and fill edge-to-edge would otherwise be
        // misread as "refusing to shrink" and get pinned to max forever.
        guard window.sliceCount < totalSlices else { return false }
        // Tolerance must absorb apps that ignore our gap and fill slot edge-to-edge
        // (up to 2*gap wider than target). Real internal-min refusals are 50px+.
        let tolerance: CGFloat = 2 * gap + 10
        guard let actual: CGSize = try? window.axElement.attribute(.size),
              actual.width > targetWidth + tolerance else { return false }
        // If the window is on a different screen (cross-screen drag, fullscreen),
        // the AX setPosition silently fails and our slot-width target is meaningless.
        // Skip min-bump rather than learning a bogus screen-spanning minimum.
        if let actualOrigin: CGPoint = try? window.axElement.attribute(.position),
           hypot(actualOrigin.x - targetOrigin.x, actualOrigin.y - targetOrigin.y) > 100 {
            slog("resize", "min_skip_offscreen", ["app": window.app.localizedName ?? "?", "actual_x": Int(actualOrigin.x), "target_x": Int(targetOrigin.x)])
            return false
        }

        // A width that wouldn't fit in (totalSlices - 1) slots is not a learnable
        // per-app minimum — it's AX failure, fullscreen, or a genuinely full-screen
        // window. The position guard above can miss these when the broken-state
        // origin happens to coincide with the target slot (e.g. slot 0 at top-left).
        // Bail rather than pinning the in-memory minSliceCount to max-1.
        let maxLearnable = screenWidth * CGFloat(totalSlices - 1) / CGFloat(totalSlices) - 2 * gap
        guard actual.width <= maxLearnable else {
            slog("resize", "min_skip_unlearnable", ["app": window.app.localizedName ?? "?", "actual": Int(actual.width)])
            return false
        }

        // Slot width for N slices: screenWidth * N / totalSlices - 2*gap ≥ actual.width
        // → N ≥ (actual.width + 2*gap) * totalSlices / screenWidth
        let slicesNeeded = Int(ceil((actual.width + 2 * gap) * CGFloat(totalSlices) / screenWidth))
        let newMin = max(1, min(slicesNeeded, totalSlices - 1))

        guard newMin > window.minSliceCount else { return false }
        window.minSliceCount = newMin

        // Persist learned minimum width so it survives restarts.
        if let bid = window.bundleId {
            let knownMin = config.appMinWidths[bid] ?? 0
            if actual.width > knownMin {
                config.appMinWidths[bid] = actual.width
                config.save()
            }
        }

        if window.sliceCount < newMin {
            window.sliceCount = newMin
            slog("resize", "min_bump", ["app": window.app.localizedName ?? "?", "min": newMin, "actual": Int(actual.width), "target": Int(targetWidth)])
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
