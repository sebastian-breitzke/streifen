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

    init(workspaceManager: WorkspaceManager, stripLayout: StripLayout) {
        self.workspaceManager = workspaceManager
        self.stripLayout = stripLayout
    }

    func registerHotkeys() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleKeyEvent(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleKeyEvent(event)
            }
            return event
        }
        slog("Hotkeys registered (NSEvent monitor)")
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
            slog("Moving window \(window.windowId) → ws\(ws)")
            mgr.moveWindow(window, toWorkspace: ws)
            return
        }

        // Hyper+H / Hyper+Left / Hyper+ß(DE)/--(US): Focus left
        // keyCode 27 = ß on DE / - on US (key after 0)
        if isHyper && (keyCode == 4 || keyCode == 123 || keyCode == 27) {
            workspaceManager?.focusLeft()
            return
        }

        // Hyper+L / Hyper+Right / Hyper+´(DE)/=(US): Focus right
        // keyCode 24 = ´ on DE / = on US (key after ß/-)
        if isHyper && (keyCode == 37 || keyCode == 124 || keyCode == 24) {
            workspaceManager?.focusRight()
            return
        }

        // Hyper+Shift+Left / Hyper+Shift+ß/- : Move window left in strip
        if isHyperShift && (keyCode == 123 || keyCode == 27) {
            workspaceManager?.moveWindowLeft()
            return
        }

        // Hyper+Shift+Right / Hyper+Shift+´/= : Move window right in strip
        if isHyperShift && (keyCode == 124 || keyCode == 24) {
            workspaceManager?.moveWindowRight()
            return
        }

        // Hyper+Up: Switch to next (higher number) workspace
        if isHyper && keyCode == 126 { // UpArrow
            workspaceManager?.switchNext()
            return
        }

        // Hyper+Down: Switch to previous (lower number) workspace
        if isHyper && keyCode == 125 { // DownArrow
            workspaceManager?.switchPrevious()
            return
        }

        // Hyper+Shift+Up: Move window to next (higher number) workspace
        if isHyperShift && keyCode == 126 {
            guard let mgr = workspaceManager else { return }
            let active = mgr.activeWorkspace
            guard active.focusIndex < active.windows.count else { return }
            let window = active.windows[active.focusIndex]
            let targetWs = mgr.activeWorkspaceId + 1
            guard targetWs <= 9 else { return }
            slog("Moving window \(window.windowId) → ws\(targetWs)")
            mgr.moveWindow(window, toWorkspace: targetWs)
            return
        }

        // Hyper+Shift+Down: Move window to previous (lower number) workspace
        if isHyperShift && keyCode == 125 {
            guard let mgr = workspaceManager else { return }
            let active = mgr.activeWorkspace
            guard active.focusIndex < active.windows.count else { return }
            let window = active.windows[active.focusIndex]
            let targetWs = mgr.activeWorkspaceId - 1
            guard targetWs >= 1 else { return }
            slog("Moving window \(window.windowId) → ws\(targetWs)")
            mgr.moveWindow(window, toWorkspace: targetWs)
            return
        }


        // Hyper+F1-F5: Set T-Shirt size (screen-adaptive)
        let fKeySizes: [(UInt16, AppSize)] = [
            (122, .full),  // F1
            (120, .xl),    // F2
            (99,  .l),     // F3
            (118, .m),     // F4
            (96,  .s),     // F5
        ]

        for (fKey, size) in fKeySizes {
            if isHyper && keyCode == fKey {
                workspaceManager?.setSize(size)
                return
            }
            if isHyperShift && keyCode == fKey {
                workspaceManager?.setAppDefaultSize(size)
                return
            }
        }

        // Hyper+Shift+Escape: Reset all windows in workspace to app defaults
        if isHyperShift && keyCode == 53 { // Escape
            workspaceManager?.resetAllWidths()
            return
        }

        // Hyper+Shift+F12: Dump focused window AX properties
        if isHyperShift && keyCode == 111 { // F12
            dumpFocusedWindow()
            return
        }
    }

    // MARK: - Debug

    /// Dump all AX properties of the currently focused window to the log.
    private func dumpFocusedWindow() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            slog("⚠️ DUMP: No frontmost app")
            return
        }

        let pid = frontApp.processIdentifier
        let appRef = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedRef)
        guard result == .success, let windowEl = focusedRef else {
            slog("⚠️ DUMP: No focused window for \(frontApp.localizedName ?? "?")")
            return
        }

        let axEl = windowEl as! AXUIElement

        // Get window ID
        var windowId: CGWindowID = 0
        _AXUIElementGetWindow(axEl, &windowId)

        // Read common attributes
        func axStr(_ attr: String) -> String {
            var val: CFTypeRef?
            AXUIElementCopyAttributeValue(axEl, attr as CFString, &val)
            return val.map { "\($0)" } ?? "nil"
        }
        func axPoint(_ attr: String) -> CGPoint? {
            var val: CFTypeRef?
            AXUIElementCopyAttributeValue(axEl, attr as CFString, &val)
            guard let v = val else { return nil }
            var point = CGPoint.zero
            AXValueGetValue(v as! AXValue, .cgPoint, &point)
            return point
        }
        func axSize(_ attr: String) -> CGSize? {
            var val: CFTypeRef?
            AXUIElementCopyAttributeValue(axEl, attr as CFString, &val)
            guard let v = val else { return nil }
            var size = CGSize.zero
            AXValueGetValue(v as! AXValue, .cgSize, &size)
            return size
        }

        let pos = axPoint(kAXPositionAttribute as String)
        let size = axSize(kAXSizeAttribute as String)

        // Check if tracked
        let isTracked = workspaceManager?.activeWorkspace.windows.contains(where: { $0.windowId == windowId }) ?? false

        slog("🔍 SUSPICIOUS WINDOW DUMP")
        slog("  app: \(frontApp.localizedName ?? "?") (\(frontApp.bundleIdentifier ?? "?"))")
        slog("  windowId: \(windowId)")
        slog("  title: \(axStr(kAXTitleAttribute as String))")
        slog("  role: \(axStr(kAXRoleAttribute as String))")
        slog("  subrole: \(axStr(kAXSubroleAttribute as String))")
        slog("  main: \(axStr(kAXMainAttribute as String))")
        slog("  modal: \(axStr(kAXModalAttribute as String))")
        slog("  fullScreen: \(axStr("AXFullScreen"))")
        slog("  identifier: \(axStr(kAXIdentifierAttribute as String))")
        slog("  pos: \(pos.map { "\($0)" } ?? "nil")")
        slog("  size: \(size.map { "\($0)" } ?? "nil")")
        slog("  tracked: \(isTracked)")
        slog("  --- END DUMP ---")
    }

}
