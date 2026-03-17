import Cocoa
import Carbon

// Global ref for CGEvent tap re-enable (accessed only from main thread)
nonisolated(unsafe) private var hotkeyEventTap: CFMachPort?

@MainActor
final class HotkeyManager {
    private weak var workspaceManager: WorkspaceManager?
    private weak var stripLayout: StripLayout?
    private var runLoopSource: CFRunLoopSource?

    init(workspaceManager: WorkspaceManager, stripLayout: StripLayout) {
        self.workspaceManager = workspaceManager
        self.stripLayout = stripLayout
    }

    func registerHotkeys() {
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: CGEventTapPlacement(rawValue: 0)!,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: hotkeyCallback,
            userInfo: refcon
        ) else {
            slog("Failed to create CGEvent tap — check accessibility permissions")
            return
        }

        hotkeyEventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        slog("Hotkeys registered (CGEvent tap)")
    }

    func unregisterHotkeys() {
        if let tap = hotkeyEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        hotkeyEventTap = nil
        runLoopSource = nil
    }

    // MARK: - Event Handling (dispatched from CGEvent tap callback)

    fileprivate func handleHotkey(keyCode: UInt16, isHyper: Bool, isHyperShift: Bool) {
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
        if isHyper && (keyCode == 4 || keyCode == 123 || keyCode == 27) {
            workspaceManager?.focusLeft()
            return
        }

        // Hyper+L / Hyper+Right / Hyper+´(DE)/=(US): Focus right
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
        if isHyper && keyCode == 126 {
            workspaceManager?.switchNext()
            return
        }

        // Hyper+Down: Switch to previous (lower number) workspace
        if isHyper && keyCode == 125 {
            workspaceManager?.switchPrevious()
            return
        }

        // Hyper+Shift+Up: Move window to next workspace
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

        // Hyper+Shift+Down: Move window to previous workspace
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

        // Hyper+F1-F5: Set T-Shirt size
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
        if isHyperShift && keyCode == 53 {
            workspaceManager?.resetAllWidths()
            return
        }

        // Hyper+Shift+F12: Dump focused window AX properties
        if isHyperShift && keyCode == 111 {
            dumpFocusedWindow()
            return
        }
    }

    // MARK: - Debug

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

        var windowId: CGWindowID = 0
        _AXUIElementGetWindow(axEl, &windowId)

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
        let isTracked = workspaceManager?.activeWorkspace.windows.contains(where: { $0.windowId == windowId }) ?? false

        slog("🔍 WINDOW DUMP")
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

// MARK: - CGEvent Tap Callback

// Modifier flags for matching
private let hyperCGFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
private let hyperShiftCGFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
private let relevantCGFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]

// Registered keycode sets for fast matching
private let numberKeyCodes: Set<UInt16> = [18, 19, 20, 21, 23, 22, 26, 28, 25]
private let numpadKeyCodes: Set<UInt16> = [83, 84, 85, 86, 87, 88, 89, 91, 92]
private let navLeftCodes: Set<UInt16> = [4, 123, 27]   // H, Left, ß
private let navRightCodes: Set<UInt16> = [37, 124, 24]  // L, Right, ´
private let arrowVertCodes: Set<UInt16> = [126, 125]     // Up, Down
private let fKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96] // F1-F5

private func isRegisteredHotkey(_ keyCode: UInt16, isHyper: Bool, isHyperShift: Bool) -> Bool {
    let allNav = numberKeyCodes.union(numpadKeyCodes).union(arrowVertCodes)

    if isHyper {
        if allNav.contains(keyCode) { return true }
        if navLeftCodes.contains(keyCode) || navRightCodes.contains(keyCode) { return true }
        if fKeyCodes.contains(keyCode) { return true }
    }
    if isHyperShift {
        if allNav.contains(keyCode) { return true }
        if keyCode == 123 || keyCode == 27 || keyCode == 124 || keyCode == 24 { return true }
        if fKeyCodes.contains(keyCode) { return true }
        if keyCode == 53 || keyCode == 111 { return true } // Esc, F12
    }
    return false
}

/// CGEvent tap callback — runs on main run loop, consumes Hyper key events
private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Re-enable tap if macOS disabled it (timeout or user input)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = hotkeyEventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passRetained(event)
    }

    guard type == .keyDown else {
        return Unmanaged.passRetained(event)
    }

    let flags = event.flags.intersection(relevantCGFlags)
    let isHyper = flags == hyperCGFlags
    let isHyperShift = flags == hyperShiftCGFlags

    guard isHyper || isHyperShift else {
        return Unmanaged.passRetained(event)
    }

    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

    guard isRegisteredHotkey(keyCode, isHyper: isHyper, isHyperShift: isHyperShift) else {
        return Unmanaged.passRetained(event)
    }

    // Dispatch action to MainActor, consume the event
    if let refcon = refcon {
        let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                manager.handleHotkey(keyCode: keyCode, isHyper: isHyper, isHyperShift: isHyperShift)
            }
        }
    }

    return nil // Consume — event does NOT reach the target app
}
