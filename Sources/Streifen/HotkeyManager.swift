import Cocoa
import HotKey
import Carbon

@MainActor
final class HotkeyManager {
    private var hotkeys: [HotKey] = []
    private weak var workspaceManager: WorkspaceManager?
    private weak var stripLayout: StripLayout?

    // Hyper = Ctrl+Alt+Cmd
    private let hyperModifiers: NSEvent.ModifierFlags = [.control, .option, .command]
    private let hyperShiftModifiers: NSEvent.ModifierFlags = [.control, .option, .command, .shift]

    init(workspaceManager: WorkspaceManager, stripLayout: StripLayout) {
        self.workspaceManager = workspaceManager
        self.stripLayout = stripLayout
    }

    func registerHotkeys() {
        // Hyper+1-9: Switch workspace
        registerWorkspaceSwitchKeys()

        // Hyper+Shift+1-9: Move window to workspace
        registerWorkspaceMoveKeys()

        // Hyper+Left/H, Hyper+Right/L: Focus navigation
        registerFocusKeys()

        // Hyper+Pad0: Cycle width
        registerWidthKeys()

        NSLog("[Streifen] Hotkeys registered")
    }

    private func registerWorkspaceSwitchKeys() {
        let numberKeys: [UInt32] = [
            UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
            UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
            UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9)
        ]

        for (i, keyCode) in numberKeys.enumerated() {
            let workspace = i + 1
            let hk = HotKey(
                carbonKeyCode: keyCode,
                carbonModifiers: carbonModifiers(from: hyperModifiers)
            )
            hk.keyDownHandler = { [weak self] in
                self?.workspaceManager?.switchTo(workspace: workspace)
            }
            hotkeys.append(hk)
        }

        // Numpad variants
        let padKeys: [UInt32] = [
            UInt32(kVK_ANSI_Keypad1), UInt32(kVK_ANSI_Keypad2), UInt32(kVK_ANSI_Keypad3),
            UInt32(kVK_ANSI_Keypad4), UInt32(kVK_ANSI_Keypad5), UInt32(kVK_ANSI_Keypad6),
            UInt32(kVK_ANSI_Keypad7), UInt32(kVK_ANSI_Keypad8), UInt32(kVK_ANSI_Keypad9)
        ]

        for (i, keyCode) in padKeys.enumerated() {
            let workspace = i + 1
            let hk = HotKey(
                carbonKeyCode: keyCode,
                carbonModifiers: carbonModifiers(from: hyperModifiers)
            )
            hk.keyDownHandler = { [weak self] in
                self?.workspaceManager?.switchTo(workspace: workspace)
            }
            hotkeys.append(hk)
        }
    }

    private func registerWorkspaceMoveKeys() {
        let numberKeys: [UInt32] = [
            UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
            UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
            UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9)
        ]

        for (i, keyCode) in numberKeys.enumerated() {
            let workspace = i + 1
            let hk = HotKey(
                carbonKeyCode: keyCode,
                carbonModifiers: carbonModifiers(from: hyperShiftModifiers)
            )
            hk.keyDownHandler = { [weak self] in
                guard let mgr = self?.workspaceManager else { return }
                let ws = mgr.activeWorkspace
                guard ws.focusIndex < ws.windows.count else { return }
                let window = ws.windows[ws.focusIndex]
                mgr.moveWindow(window, toWorkspace: workspace)
            }
            hotkeys.append(hk)
        }
    }

    private func registerFocusKeys() {
        // Hyper+Left / Hyper+H
        for keyCode in [UInt32(kVK_LeftArrow), UInt32(kVK_ANSI_H)] {
            let hk = HotKey(
                carbonKeyCode: keyCode,
                carbonModifiers: carbonModifiers(from: hyperModifiers)
            )
            hk.keyDownHandler = { [weak self] in
                self?.workspaceManager?.focusLeft()
            }
            hotkeys.append(hk)
        }

        // Hyper+Right / Hyper+L
        for keyCode in [UInt32(kVK_RightArrow), UInt32(kVK_ANSI_L)] {
            let hk = HotKey(
                carbonKeyCode: keyCode,
                carbonModifiers: carbonModifiers(from: hyperModifiers)
            )
            hk.keyDownHandler = { [weak self] in
                self?.workspaceManager?.focusRight()
            }
            hotkeys.append(hk)
        }
    }

    private func registerWidthKeys() {
        // Hyper+Pad0: Cycle width forward
        let cycleKey = HotKey(
            carbonKeyCode: UInt32(kVK_ANSI_Keypad0),
            carbonModifiers: carbonModifiers(from: hyperModifiers)
        )
        cycleKey.keyDownHandler = { [weak self] in
            self?.workspaceManager?.cycleWidth()
        }
        hotkeys.append(cycleKey)

        // Hyper+Shift+Pad0: Cycle width backward
        let cycleRevKey = HotKey(
            carbonKeyCode: UInt32(kVK_ANSI_Keypad0),
            carbonModifiers: carbonModifiers(from: hyperShiftModifiers)
        )
        cycleRevKey.keyDownHandler = { [weak self] in
            self?.workspaceManager?.cycleWidth(reverse: true)
        }
        hotkeys.append(cycleRevKey)

        // Hyper+PadEnter: Toggle full width
        let fullKey = HotKey(
            carbonKeyCode: UInt32(kVK_ANSI_KeypadEnter),
            carbonModifiers: carbonModifiers(from: hyperModifiers)
        )
        fullKey.keyDownHandler = { [weak self] in
            self?.workspaceManager?.toggleFullWidth()
        }
        hotkeys.append(fullKey)
    }

    // MARK: - Helpers

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}
