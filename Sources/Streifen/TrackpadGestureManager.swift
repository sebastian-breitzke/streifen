import Cocoa
import CoreFoundation

private struct MTPoint {
    var x: Float
    var y: Float
}

private struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

private enum MTTouchState: UInt32 {
    case notTracking = 0
    case startInRange = 1
    case hoverInRange = 2
    case makeTouch = 3
    case touching = 4
    case breakTouch = 5
    case lingerInRange = 6
    case outOfRange = 7
}

private struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var pathIndex: Int32
    var state: UInt32
    var fingerID: Int32
    var handID: Int32
    var normalizedVector: MTVector
    var zTotal: Float
    var field9: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absoluteVector: MTVector
    var field14: Int32
    var field15: Int32
    var zDensity: Float
}

private typealias MTDeviceRef = UnsafeMutableRawPointer
private typealias MTContactFrameCallback = @convention(c) (
    MTDeviceRef?,
    UnsafeMutableRawPointer?,
    CInt,
    Double,
    CInt,
    UnsafeMutableRawPointer?
) -> Void

@_silgen_name("MTDeviceCreateList")
private func MTDeviceCreateList() -> Unmanaged<CFArray>?

@_silgen_name("MTRegisterContactFrameCallbackWithRefcon")
private func MTRegisterContactFrameCallbackWithRefcon(
    _ device: MTDeviceRef,
    _ callback: MTContactFrameCallback,
    _ refcon: UnsafeMutableRawPointer?
)

@_silgen_name("MTUnregisterContactFrameCallback")
private func MTUnregisterContactFrameCallback(
    _ device: MTDeviceRef,
    _ callback: MTContactFrameCallback
)

@discardableResult
@_silgen_name("MTDeviceStart")
private func MTDeviceStart(_ device: MTDeviceRef, _ mode: Int32) -> Int32

@discardableResult
@_silgen_name("MTDeviceStop")
private func MTDeviceStop(_ device: MTDeviceRef) -> Int32

@_silgen_name("MTDeviceRelease")
private func MTDeviceRelease(_ device: MTDeviceRef)

private enum GestureAxisLock {
    case undecided
    case horizontal
    case vertical
}

private struct FourFingerGestureState {
    var startCentroid: CGPoint
    var lastCentroid: CGPoint
    var axisLock: GestureAxisLock
    var hasScrolled: Bool
}

final class TrackpadGestureManager {
    private weak var workspaceManager: WorkspaceManager?
    private var devices: [MTDeviceRef] = []
    private var running = false
    private let stateQueue = DispatchQueue(label: "de.s16e.streifen.trackpad-gestures")
    private var gestureStates: [UInt: FourFingerGestureState] = [:]

    private let axisLockThreshold: CGFloat = 0.015
    private let horizontalBias: CGFloat = 1.25
    private let minimumContactQuality: Float = 0.02
    private let scrollSensitivity: CGFloat = 1.1

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    func start() {
        guard !running else { return }
        guard let deviceArray = MTDeviceCreateList()?.takeRetainedValue() else {
            slog("Trackpad gestures unavailable — no multitouch devices")
            return
        }

        let count = CFArrayGetCount(deviceArray)
        guard count > 0 else {
            slog("Trackpad gestures unavailable — device list empty")
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for index in 0..<count {
            let value = CFArrayGetValueAtIndex(deviceArray, index)
            let device = unsafeBitCast(value, to: MTDeviceRef.self)
            MTRegisterContactFrameCallbackWithRefcon(device, trackpadContactCallback, refcon)
            let status = MTDeviceStart(device, 0)
            guard status == 0 else {
                slog("Trackpad gesture device start failed (\(status))")
                MTUnregisterContactFrameCallback(device, trackpadContactCallback)
                continue
            }
            devices.append(device)
        }

        running = !devices.isEmpty
        if running {
            slog("Trackpad gestures registered (\(devices.count) device(s), 4-finger smooth pan)")
        } else {
            slog("Trackpad gestures unavailable — failed to start any device")
        }
    }

    func stop() {
        guard running else { return }
        for device in devices {
            MTUnregisterContactFrameCallback(device, trackpadContactCallback)
            _ = MTDeviceStop(device)
            MTDeviceRelease(device)
        }
        devices.removeAll()

        stateQueue.sync {
            gestureStates.removeAll()
        }

        running = false
    }

    fileprivate func handleFrame(
        device: MTDeviceRef?,
        touches: UnsafeMutableRawPointer?,
        count: CInt
    ) {
        guard let device, let touches, count > 0 else { return }

        let touchPointer = touches.assumingMemoryBound(to: MTTouch.self)
        let buffer = UnsafeBufferPointer(start: touchPointer, count: Int(count))
        let activeTouches = buffer.filter { touch in
            guard touch.zTotal >= minimumContactQuality else { return false }
            return touch.state == MTTouchState.makeTouch.rawValue || touch.state == MTTouchState.touching.rawValue
        }

        let deviceKey = UInt(bitPattern: device)

        stateQueue.async { [weak self] in
            guard let self else { return }

            guard activeTouches.count == 4 else {
                if let state = self.gestureStates.removeValue(forKey: deviceKey),
                   state.axisLock == .horizontal,
                   state.hasScrolled {
                    self.dispatchSnap()
                }
                return
            }

            let centroid = self.centroid(of: activeTouches)
            var state = self.gestureStates[deviceKey] ?? FourFingerGestureState(
                startCentroid: centroid,
                lastCentroid: centroid,
                axisLock: .undecided,
                hasScrolled: false
            )

            let totalDeltaX = centroid.x - state.startCentroid.x
            let totalDeltaY = centroid.y - state.startCentroid.y
            let incrementalDeltaX = centroid.x - state.lastCentroid.x

            if state.axisLock == .undecided,
               max(abs(totalDeltaX), abs(totalDeltaY)) >= self.axisLockThreshold {
                if abs(totalDeltaX) > abs(totalDeltaY) * self.horizontalBias {
                    state.axisLock = .horizontal
                } else if abs(totalDeltaY) > abs(totalDeltaX) * self.horizontalBias {
                    state.axisLock = .vertical
                }
            }

            if state.axisLock == .horizontal, incrementalDeltaX != 0 {
                state.hasScrolled = true
                self.dispatchScroll(deltaX: incrementalDeltaX)
            }

            state.lastCentroid = centroid
            self.gestureStates[deviceKey] = state
        }
    }

    private func centroid(of touches: [MTTouch]) -> CGPoint {
        let count = CGFloat(touches.count)
        let x = touches.reduce(CGFloat.zero) { partial, touch in
            partial + CGFloat(touch.normalizedVector.position.x)
        } / count
        let y = touches.reduce(CGFloat.zero) { partial, touch in
            partial + CGFloat(touch.normalizedVector.position.y)
        } / count
        return CGPoint(x: x, y: y)
    }

    private func dispatchScroll(deltaX: CGFloat) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let screen = NSScreen.managed?.visibleFrame else { return }
            let delta = deltaX * screen.width * self.scrollSensitivity
            self.workspaceManager?.scrollActiveWorkspace(by: delta)
        }
    }

    private func dispatchSnap() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.workspaceManager?.snapActiveWorkspaceToNearestWindow()
        }
    }
}

extension GestureAxisLock: Sendable {}

extension FourFingerGestureState: Sendable {}

extension TrackpadGestureManager: @unchecked Sendable {}

private let trackpadContactCallback: MTContactFrameCallback = { device, touches, count, _, _, refcon in
    guard let refcon else { return }
    let manager = Unmanaged<TrackpadGestureManager>.fromOpaque(refcon).takeUnretainedValue()
    manager.handleFrame(device: device, touches: touches, count: count)
}
