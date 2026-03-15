import Cocoa
import Carbon

@MainActor
final class HotkeyManager {
    private weak var workspaceManager: WorkspaceManager?
    private weak var stripLayout: StripLayout?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    // Hyper = Ctrl+Alt+Cmd
    private let hyperMask: NSEvent.ModifierFlags = [.control, .option, .command]
    private let hyperShiftMask: NSEvent.ModifierFlags = [.control, .option, .command, .shift]
    private let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .command, .shift]

    // Width presets: 1/4, 1/3, 1/2, 2/3, 3/4, 1
    static let widthPresets: [CGFloat] = [0.25, 1.0/3.0, 0.50, 2.0/3.0, 0.75, 1.0]

    init(workspaceManager: WorkspaceManager, stripLayout: StripLayout) {
        self.workspaceManager = workspaceManager
        self.stripLayout = stripLayout
    }

    func registerHotkeys() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyEvent(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyEvent(event)
            }
            return event
        }
        NSLog("[Streifen] Hotkeys registered (NSEvent monitor)")
    }

    func unregisterHotkeys() {
        if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
        if let l = localMonitor { NSEvent.removeMonitor(l); localMonitor = nil }
    }

    // MARK: - Event Routing

    private func handleKeyEvent(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(relevantModifiers)
        let keyCode = event.keyCode
        let isHyper = mods == hyperMask
        let isHyperShift = mods == hyperShiftMask

        guard isHyper || isHyperShift else { return }

        // Number keys 1-9
        let numberCodes: [UInt16: Int] = [
            18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9
        ]
        // Numpad 1-9
        let padCodes: [UInt16: Int] = [
            83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9
        ]

        // Hyper+1-9 / Pad1-9: Switch workspace
        if isHyper, let ws = numberCodes[keyCode] ?? padCodes[keyCode] {
            workspaceManager?.switchTo(workspace: ws)
            return
        }

        // Hyper+Shift+1-9 / Pad1-9: Move window to workspace
        if isHyperShift, let ws = numberCodes[keyCode] ?? padCodes[keyCode] {
            guard let mgr = workspaceManager else { return }
            let active = mgr.activeWorkspace
            guard active.focusIndex < active.windows.count else { return }
            let window = active.windows[active.focusIndex]
            NSLog("[Streifen] Moving window \(window.windowId) → ws\(ws)")
            mgr.moveWindow(window, toWorkspace: ws)
            return
        }

        // Hyper+H / Hyper+Left: Focus left
        if isHyper && (keyCode == 4 || keyCode == 123) { // H or LeftArrow
            workspaceManager?.focusLeft()
            return
        }

        // Hyper+L / Hyper+Right: Focus right
        if isHyper && (keyCode == 37 || keyCode == 124) { // L or RightArrow
            workspaceManager?.focusRight()
            return
        }

        // Hyper+Up: Width up (next bigger preset)
        if isHyper && keyCode == 126 { // UpArrow
            workspaceManager?.widthStep(up: true)
            return
        }

        // Hyper+Down: Width down (next smaller preset)
        if isHyper && keyCode == 125 { // DownArrow
            workspaceManager?.widthStep(up: false)
            return
        }

        // Hyper+Pad0: Cycle width forward
        if isHyper && keyCode == 82 { // Keypad0
            workspaceManager?.cycleWidth()
            return
        }

        // Hyper+Shift+Pad0: Cycle width backward
        if isHyperShift && keyCode == 82 {
            workspaceManager?.cycleWidth(reverse: true)
            return
        }

        // Hyper+PadEnter: Toggle full width
        if isHyper && keyCode == 76 { // KeypadEnter
            workspaceManager?.toggleFullWidth()
            return
        }
    }

    // MARK: - Width Preset Logic

    /// Find nearest preset index for a given width ratio
    static func nearestPresetIndex(for ratio: CGFloat) -> Int {
        var bestIdx = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (i, preset) in widthPresets.enumerated() {
            let dist = abs(ratio - preset)
            if dist < bestDist {
                bestDist = dist
                bestIdx = i
            }
        }
        return bestIdx
    }
}
