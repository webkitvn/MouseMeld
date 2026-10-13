import AppKit
import ApplicationServices
import CPointerInput
import Foundation

private let chromeBundleIdentifier = "com.google.Chrome"
private let refreshInterval: UInt64 = 50_000_000
private let observationTTL: UInt64 = 100_000_000

private struct ChromeWitness: Equatable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    init?(_ pid: pid_t) {
        var witness = mmf_process_witness()
        guard mmf_process_witness_current(pid, &witness) else { return nil }
        self.pid = pid
        startSeconds = witness.start_seconds
        startMicroseconds = witness.start_microseconds
    }
}

private final class ChromeLivenessCache: @unchecked Sendable {
    private struct Entry {
        let application: NSRunningApplication
        let witness: ChromeWitness
    }

    static let shared = ChromeLivenessCache()
    private let lock = NSLock()
    private var entries: [pid_t: Entry] = [:]

    func instance(_ pid: pid_t) -> ChromeInstance? {
        lock.lock()
        let entry = entries[pid]
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let before = ChromeWitness(pid),
                  let application = NSRunningApplication(processIdentifier: pid),
                  application.bundleIdentifier == chromeBundleIdentifier,
                  !application.isTerminated,
                  application.processIdentifier == pid,
                  let after = ChromeWitness(pid), before == after else {
                self?.lock.lock(); self?.entries.removeValue(forKey: pid); self?.lock.unlock()
                return
            }
            self.lock.lock(); self.entries[pid] = Entry(application: application, witness: after); self.lock.unlock()
        }
        guard let entry, let current = ChromeWitness(pid), entry.witness == current else { return nil }
        return ChromeInstance(application: entry.application, witness: current)
    }
}

private struct ChromeInstance {
    let application: NSRunningApplication
    let witness: ChromeWitness

    static func current(_ pid: pid_t) -> Self? { ChromeLivenessCache.shared.instance(pid) }

    static func same(_ first: Self, _ second: Self) -> Bool {
        first.application.isEqual(second.application) && first.witness == second.witness
    }
}

final class ChromeObservationWorker: @unchecked Sendable {
    private let slot: UnsafeMutablePointer<mmf_observation_slot>
    private let lock = NSLock()
    private let stopped = DispatchSemaphore(value: 0)
    private var epoch: UInt64
    private var running = true
    private var worker: Thread?
    private var didStart = false

    init?(epoch: UInt64) {
        guard let slot = mmf_observation_slot_create() else { return nil }
        guard mmf_observation_slot_lock_free(slot) else {
            mmf_observation_slot_destroy(slot)
            return nil
        }
        self.slot = slot
        self.epoch = epoch
    }

    deinit { mmf_observation_slot_destroy(slot) }

    func start() {
        lock.lock()
        guard !didStart else { lock.unlock(); return }
        didStart = true
        let currentEpoch = epoch
        lock.unlock()
        mmf_observation_slot_enable_admissions(slot, currentEpoch)
        let thread = Thread { [self] in run() }
        thread.name = "MouseMeld Chrome observation"
        worker = thread
        thread.start()
    }

    func reserve(epoch: UInt64, point: CGPoint, now: UInt64) -> Bool {
        mmf_observation_slot_reserve(slot, epoch, point.x, point.y, now)
    }

    func abortReservation() {
        _ = mmf_observation_slot_abort_reservation(slot)
    }

    func disableAdmissions(nextEpoch: UInt64) {
        lock.lock()
        epoch = nextEpoch
        lock.unlock()
        mmf_observation_slot_disable_admissions(slot, nextEpoch)
    }

    func stop(nextEpoch: UInt64) {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        epoch = nextEpoch
        lock.unlock()
        mmf_observation_slot_disable_admissions(slot, nextEpoch)
        if didStart { _ = stopped.wait(timeout: .distantFuture) }
    }

    private func request() -> (running: Bool, epoch: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (running, epoch)
    }

    private func run() {
        while true {
            let request = request()
            guard request.running else { break }
            if let point = CGEvent(source: nil)?.location { refresh(point: point, epoch: request.epoch) }
            Thread.sleep(forTimeInterval: Double(refreshInterval) / 1_000_000_000)
        }
        releasePreparedPayload()
        stopped.signal()
    }

    private func refresh(point: CGPoint, epoch: UInt64) {
        let sampled = DispatchTime.now().uptimeNanoseconds
        var oldPayload: uintptr_t = 0
        guard mmf_observation_slot_prepare(slot, &oldPayload) else { return }
        release(oldPayload)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        var candidatePID: pid_t = 0
        guard observedWindow(system, point: point, pid: &candidatePID) != nil,
              let before = ChromeInstance.current(candidatePID) else { mmf_observation_slot_empty(slot); return }
        var windowPID: pid_t = 0
        guard let window = observedWindow(system, point: point, pid: &windowPID),
              windowPID == candidatePID,
              currentPointEquals(point),
              DispatchTime.now().uptimeNanoseconds - sampled <= observationTTL,
              let after = ChromeInstance.current(windowPID), ChromeInstance.same(before, after),
              request().running, request().epoch == epoch else {
            mmf_observation_slot_empty(slot)
            return
        }
        let retained = Unmanaged.passRetained(window).toOpaque()
        mmf_observation_slot_publish(slot, UInt(bitPattern: retained), point.x, point.y, sampled, sampled + observationTTL, epoch)
    }

    private func currentPointEquals(_ expected: CGPoint) -> Bool {
        CGEvent(source: nil)?.location == expected
    }

    private func observedWindow(_ system: AXUIElement, point: CGPoint, pid: inout pid_t) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit,
              AXUIElementGetPid(hit, &pid) == .success else { return nil }
        let window: AXUIElement
        if hasWindowRole(hit) {
            window = hit
        } else {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(hit, kAXWindowAttribute as CFString, &value) == .success,
                  let value,
                  CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            window = unsafeDowncast(value, to: AXUIElement.self)
            guard hasWindowRole(window) else { return nil }
        }
        var windowPID: pid_t = 0
        guard AXUIElementGetPid(window, &windowPID) == .success, windowPID == pid else { return nil }
        return window
    }

    private func hasWindowRole(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success
            && (value as? String) == (kAXWindowRole as String)
    }

    private func releasePreparedPayload() {
        var payload: uintptr_t = 0
        if mmf_observation_slot_prepare(slot, &payload) {
            release(payload)
            mmf_observation_slot_empty(slot)
        } else {
            precondition(mmf_observation_slot_state(slot) == 0, "#163 must not stop with a callback reservation")
        }
    }

    private func release(_ payload: uintptr_t) {
        guard payload != 0, let pointer = UnsafeRawPointer(bitPattern: payload) else { return }
        Unmanaged<AXUIElement>.fromOpaque(pointer).release()
    }
}
