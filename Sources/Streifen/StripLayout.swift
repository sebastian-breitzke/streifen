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
        let windows = workspace.windows
        guard !windows.isEmpty else { return }

        let availableHeight = screenFrame.height - (2 * gap)
        let y = screenFrame.origin.y + gap

        var x = screenFrame.origin.x + gap + workspace.scrollOffset

        for window in windows {
            let windowWidth = screenFrame.width * window.widthRatio - (2 * gap)
            let clampedWidth = max(windowWidth, 200) // minimum 200px

            // Calculate virtual position
            window.virtualX = x

            // Clamp to screen bounds — off-screen windows get 1px margin
            let visibleFrame: CGRect
            if x + clampedWidth < screenFrame.origin.x {
                // Fully off-screen left: park just off-screen
                visibleFrame = CGRect(
                    x: screenFrame.origin.x - clampedWidth + 1,
                    y: y,
                    width: clampedWidth,
                    height: availableHeight
                )
            } else if x > screenFrame.maxX {
                // Fully off-screen right: park just off-screen
                visibleFrame = CGRect(
                    x: screenFrame.maxX - 1,
                    y: y,
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
        var total: CGFloat = gap
        for window in workspace.windows {
            let windowWidth = screenFrame.width * window.widthRatio - (2 * gap)
            total += max(windowWidth, 200) + gap
        }
        return total
    }
}
