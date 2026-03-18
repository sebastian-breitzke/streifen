import Cocoa

@MainActor
final class StripLayout {
    var config: StreifenConfig

    init(config: StreifenConfig) {
        self.config = config
    }

    /// Lay out all windows in the workspace horizontally
    func layout(workspace: Workspace, screenFrame: CGRect, config: StreifenConfig) {
        let gap = config.gap
        let peek = config.peekWidth
        let windows = workspace.windows
        guard !windows.isEmpty else { return }

        let availableHeight = screenFrame.height - (2 * gap)
        let y = screenFrame.origin.y + gap

        // Max width: leave peek room for neighbors on both sides
        let maxWidth = screenFrame.width - (2 * gap) - (2 * peek)

        var x = screenFrame.origin.x + gap + workspace.scrollOffset

        let sc = ScreenClass.current
        for window in windows {
            var windowWidth = screenFrame.width * CGFloat(window.sliceCount) / CGFloat(sc.totalSlices) - (2 * gap)
            // Cap width for peek (only if there are neighbors)
            let hasNeighbors = windows.count > 1
            if hasNeighbors {
                windowWidth = min(windowWidth, maxWidth)
            }
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
            x += clampedWidth + gap
        }
    }

    /// Total strip width for all windows
    func totalWidth(workspace: Workspace, screenFrame: CGRect) -> CGFloat {
        let gap = config.gap
        let peek = config.peekWidth
        let maxWidth = screenFrame.width - (2 * gap) - (2 * peek)
        let hasNeighbors = workspace.windows.count > 1
        let sc = ScreenClass.current
        var total: CGFloat = gap
        for window in workspace.windows {
            var windowWidth = screenFrame.width * CGFloat(window.sliceCount) / CGFloat(sc.totalSlices) - (2 * gap)
            if hasNeighbors { windowWidth = min(windowWidth, maxWidth) }
            total += max(windowWidth, 200) + gap
        }
        return total
    }
}
