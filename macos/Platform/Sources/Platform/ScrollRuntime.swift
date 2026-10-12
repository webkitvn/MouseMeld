import AppKit
import Bridge
import CoreGraphics
import Foundation

public enum ScrollRuntimeStatus: Equatable, Sendable {
    case active
    case unavailable
}

public enum ScrollAdapter {
    public static func evaluate(horizontal: Int64, vertical: Int64, engine: PointerInputEngine) -> InputDecision? {
        engine.evaluate(horizontal: horizontal, vertical: vertical)
    }

    @discardableResult public static func apply(_ event: CGEvent, decision: InputDecision) -> UInt8 {
        guard case let .replace(horizontal, vertical) = decision else { return 0 }
        // Conservative project-safe Delta bounds; not a universal platform range guarantee.
        // Preflight the selected fields before either axis can mutate the original event.
        let horizontalLimit: Int64 = horizontal % 100 == 0 ? 3_276_700 : 3_276_799
        let verticalLimit: Int64 = vertical % 100 == 0 ? 3_276_700 : 3_276_799
        guard (-3_276_800...horizontalLimit).contains(horizontal),
              (-3_276_800...verticalLimit).contains(vertical) else { return 2 }
        if vertical % 100 == 0 {
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: vertical / 100)
        } else {
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(vertical) / 100)
        }
        if horizontal % 100 == 0 {
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: horizontal / 100)
        } else {
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(horizontal) / 100)
        }
        return 1
    }

    @discardableResult public static func process(_ event: CGEvent, engine: PointerInputEngine) -> UInt8 {
        guard event.type == .scrollWheel, event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else { return 0 }
        guard let decision = evaluate(horizontal: event.getIntegerValueField(.scrollWheelEventDeltaAxis2), vertical: event.getIntegerValueField(.scrollWheelEventDeltaAxis1), engine: engine) else { return 2 }
        return apply(event, decision: decision)
    }
}

final class TapState: @unchecked Sendable {
    // Serializes lifecycle state and the published tap/source handles. The callback
    // never takes it: `tap`/`source` are written only by the tap-owner thread (the
    // thread running `run()` and the run-loop blocks), so the callback's lock-free
    // reads are same-thread. The lock makes `runtimeStatus()`'s cross-thread read safe.
    private let lock = NSLock()
    let engine: PointerInputEngine
    let trace: TracePipeline?
    let configRevision: UInt64?
    private let ownsTrace: Bool
    let ready = DispatchSemaphore(value: 0)
    let stopped = DispatchSemaphore(value: 0)
    private var lifecycle = Lifecycle.idle
    private var runLoop: CFRunLoop?
    private var timeoutCount = 0
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private enum Lifecycle { case idle, starting, running, cancelling, finished }

    init(engine: PointerInputEngine, trace: TracePipeline? = TracePipeline(), configRevision: UInt64? = nil, ownsTrace: Bool = true) {
        self.engine = engine
        self.trace = trace
        self.configRevision = configRevision
        self.ownsTrace = ownsTrace
    }

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard lifecycle == .idle else { return false }
        lifecycle = .starting
        return true
    }

    func run() {
        let runLoop = CFRunLoopGetCurrent()
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: ScrollRuntime.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            trace?.lifecycle(2)
            ready.signal()
            complete()
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            trace?.lifecycle(3)
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            ready.signal()
            complete()
            return
        }
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        lock.lock()
        self.tap = tap
        self.source = source
        let shouldRun = lifecycle == .starting && CGEvent.tapIsEnabled(tap: tap)
        lifecycle = shouldRun ? .running : .cancelling
        self.runLoop = shouldRun ? runLoop : nil
        lock.unlock()
        ready.signal()
        guard shouldRun else {
            finishOnOwnerRunLoop()
            complete()
            return
        }
        CFRunLoopRun()
        finishOnOwnerRunLoop()
        complete()
    }

    func cancelAndRunLoop() -> (join: Bool, runLoop: CFRunLoop?) {
        lock.lock()
        defer { lock.unlock() }
        switch lifecycle {
        case .idle, .finished: return (false, nil)
        case .starting, .running: lifecycle = .cancelling
        case .cancelling: break
        }
        return (true, runLoop)
    }

    func awaitReady() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lifecycle == .running
    }

    func runtimeStatus() -> ScrollRuntimeStatus {
        lock.lock()
        defer { lock.unlock() }
        // `.running` records that the run loop started, not that macOS still has the
        // tap enabled: the callback may have failed to re-enable a tap disabled by
        // timeout or user input. Report the live tap state so callers can react.
        guard lifecycle == .running, let tap else { return .unavailable }
        return CGEvent.tapIsEnabled(tap: tap) ? .active : .unavailable
    }

    func completedTimeoutCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        precondition(lifecycle == .finished)
        return timeoutCount
    }

    func finishOnOwnerRunLoop() {
        // Runs on the tap-owner thread. Publish the cleared handles under the lock
        // before tearing the tap down, so no cross-thread `runtimeStatus()` reader can
        // observe (or hold) a port that is being invalidated.
        lock.lock()
        let tap = self.tap
        let source = self.source
        self.tap = nil
        self.source = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        runLoop = nil
        lock.unlock()
    }

    func disabledByTimeout() {
        timeoutCount += 1
        trace?.callbackLifecycle(4)
    }
    func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        if CGEvent.tapIsEnabled(tap: tap) { trace?.callbackLifecycle(5) }
    }

    func complete() {
        lock.lock()
        guard lifecycle != .finished else {
            lock.unlock()
            return
        }
        lifecycle = .finished
        runLoop = nil
        if ownsTrace {
            trace?.lifecycle(1)
            trace?.close()
        }
        lock.unlock()
        stopped.signal()
    }
}

@_spi(Benchmark) public final class CallbackHarness {
    private let state: TapState

    @_spi(Benchmark) public init(engine: PointerInputEngine, trace: Bool = true) { state = TapState(engine: engine, trace: trace ? TracePipeline() : nil) }

    @_spi(Benchmark) public func invoke(_ type: CGEventType, event: CGEvent) {
        _ = ScrollRuntime.callback(OpaquePointer(bitPattern: 0x1)!, type, event, Unmanaged.passUnretained(state).toOpaque())
    }

    deinit { state.complete() }

    @_spi(Benchmark) public func close() { state.complete() }

    @_spi(Benchmark) public func cleanTraceShutdown() -> Bool { state.trace?.cleanShutdown() ?? false }

    @_spi(Benchmark) public func setReverse(_ reverse: Bool) -> Bool {
        reverse ? state.engine.setReverseDirection() : state.engine.setSystemDirection()
    }

    @_spi(Benchmark) public func setConfiguration(_ direction: ScrollDirection, amountPercent: UInt32) -> Bool {
        state.engine.setDirection(direction, amountPercent: amountPercent)
    }
}

public final class ScrollRuntime {
    private let state: TapState
    private let thread: Thread
    private let coordinatorLock = NSLock()
    private var joined = false

    public convenience init?(direction: ScrollDirection = .preserve, amountPercent: UInt32 = 100, binding: ButtonBinding? = nil) {
        self.init(direction: direction, amountPercent: amountPercent, binding: binding, trace: TracePipeline(), configRevision: nil, ownsTrace: true)
    }

    init?(direction: ScrollDirection, amountPercent: UInt32, binding: ButtonBinding?, trace: TracePipeline?, configRevision: UInt64?, ownsTrace: Bool = false) {
        guard AXIsProcessTrusted(), let engine = PointerInputEngine(), engine.setDirection(direction, amountPercent: amountPercent, binding: binding) else {
            if ownsTrace { trace?.close() }
            return nil
        }
        let state = TapState(engine: engine, trace: trace, configRevision: configRevision, ownsTrace: ownsTrace)
        self.state = state
        thread = Thread { state.run() }
        thread.name = "MouseMeld CGEventTap"
    }

    public func start() -> Bool {
        coordinatorLock.lock()
        defer { coordinatorLock.unlock() }
        guard !joined, state.begin() else { return false }
        thread.start()
        guard state.ready.wait(timeout: .now() + 1) == .success else {
            stopLocked()
            return false
        }
        return state.awaitReady()
    }

    public func stop() {
        coordinatorLock.lock()
        defer { coordinatorLock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        guard !joined else { return }
        let request = state.cancelAndRunLoop()
        guard request.join else {
            state.complete()
            joined = true
            return
        }
        if let runLoop = request.runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue as NSString) {
                self.state.finishOnOwnerRunLoop()
                CFRunLoopStop(runLoop)
            }
            CFRunLoopWakeUp(runLoop)
        }
        _ = state.stopped.wait(timeout: .distantFuture)
        joined = true
    }

    public var disabledByTimeoutCount: Int {
        precondition(joined)
        return state.completedTimeoutCount()
    }

    public var status: ScrollRuntimeStatus { state.runtimeStatus() }

    deinit { stop() }

    fileprivate static let callback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        let state = Unmanaged<TapState>.fromOpaque(info).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if type == .tapDisabledByTimeout { state.disabledByTimeout() }
            state.reenable()
        } else {
            guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
            guard let trace = state.trace else {
                ScrollAdapter.process(event, engine: state.engine)
                return Unmanaged.passUnretained(event)
            }
            let start = DispatchTime.now().uptimeNanoseconds
            let lineBased = event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0
            let horizontal = lineBased ? event.getIntegerValueField(.scrollWheelEventDeltaAxis2) : 0
            let vertical = lineBased ? event.getIntegerValueField(.scrollWheelEventDeltaAxis1) : 0
            let configuration = state.engine.configuration
            let extracted = DispatchTime.now().uptimeNanoseconds
            let decision = lineBased ? ScrollAdapter.evaluate(horizontal: horizontal, vertical: vertical, engine: state.engine) : .preserve
            let evaluated = DispatchTime.now().uptimeNanoseconds
            let outcome = decision.map { ScrollAdapter.apply(event, decision: $0) } ?? 0
            let applied = DispatchTime.now().uptimeNanoseconds
            let code: UInt8
            let decisionHorizontal: Int64
            let decisionVertical: Int64
            if case let .replace(horizontal, vertical)? = decision {
                code = 1
                decisionHorizontal = horizontal
                decisionVertical = vertical
            } else {
                code = 0
                decisionHorizontal = 0
                decisionVertical = 0
            }
            let reason: UInt8
            if !lineBased { reason = 0 }
            else if decision == nil { reason = 6 }
            else if outcome != 1 && code == 1 { reason = 5 }
            else if horizontal == 0 && vertical == 0 { reason = 1 }
            else if configuration.amountPercent == 100 && configuration.direction == .preserve { reason = 2 }
            else if configuration.amountPercent == 100 { reason = 4 }
            else { reason = 3 }
            trace.enqueue(horizontal: horizontal, vertical: vertical, granularity: lineBased ? 1 : 0, decision: code, outcome: outcome == 1 ? 1 : 0, reason: reason, direction: configuration.direction == .reverse ? 1 : 0, amountPercent: configuration.amountPercent, decisionHorizontal: decisionHorizontal, decisionVertical: decisionVertical, extractionNS: extracted - start, rustNS: lineBased ? evaluated - extracted : 0, applyNS: code == 1 ? applied - evaluated : 0, totalNS: applied - start, tNS: start, configRevision: state.configRevision)
        }
        return Unmanaged.passUnretained(event)
    }
}
