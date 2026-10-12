import ApplicationServices
import Combine
import Foundation

public enum InputRuntimeState: Equatable {
    case off
    case needsAccessibilityAccess
    case active
    case inputUnavailable
    case configurationNeedsAttention

    public static func resolve(enabled: Bool, accessibilityTrusted: Bool, runtimeStatus: ScrollRuntimeStatus, attention: ConfigurationAttention) -> Self {
        guard attention != .malformed, attention != .newerSchema else { return .configurationNeedsAttention }
        guard enabled else { return .off }
        guard accessibilityTrusted else { return .needsAccessibilityAccess }
        return runtimeStatus == .active ? .active : .inputUnavailable
    }
}

public final class InputRuntime: ObservableObject {
    @Published public private(set) var state: InputRuntimeState = .off
    @Published public private(set) var configuration: PersistedConfiguration
    @Published public private(set) var hasCommittedConfiguration: Bool
    @Published public private(set) var configurationAttention: ConfigurationAttention
    @Published public private(set) var isSaving = false
    @Published public private(set) var canRefresh = true

    private let store: ConfigurationStore
    public let migrationFailed: Bool
    private let trace: TracePipeline?
    private let lifecycle: LifecycleExecutor
    private var operationID = UUID()
    private var previousRevision: UInt64?
    private var accessibilityTrusted = false
    private var runtimeStatus: ScrollRuntimeStatus = .unavailable
    private var monitor: Timer?
    private var revision: UInt64 = 0

    public init(store: ConfigurationStore = ConfigurationStore()) {
        self.store = store
        trace = TracePipeline()
        lifecycle = LifecycleExecutor(trace: trace)
        let loaded = store.loadOutcome()
        configuration = loaded.configuration
        // A missing file selects the supported fresh defaults, not an unreadable fallback.
        hasCommittedConfiguration = loaded.attention == .none
        configurationAttention = loaded.attention
        migrationFailed = loaded.result == "migration_failed"
        trace?.configuration("config.load", operationID: operationID, oldRevision: nil, newRevision: loaded.attention == .none ? revision : nil, configuration: configuration, result: loaded.result)
        if loaded.result == "migrated" || loaded.result == "migration_failed" {
            trace?.configuration("config.migration", operationID: operationID, oldRevision: nil, newRevision: loaded.attention == .none ? revision : nil, configuration: configuration, result: loaded.result)
        }
        lifecycle.onStatus = { [weak self] status in
            guard let self, self.canRefresh else { return }
            self.runtimeStatus = status
            self.publishState()
        }
        reconcileIntent()
    }

    public var hasAccessibilityAccess: Bool { AXIsProcessTrusted() }
    public var canEditConfiguration: Bool { canRefresh && !migrationFailed && (configurationAttention == .none || configurationAttention == .saveFailed) && !isSaving }

    public func setEnabled(_ enabled: Bool) { commit(.init(enabled: enabled, direction: configuration.direction, amountPercent: configuration.amountPercent, binding: configuration.binding)) }
    public func setDirection(_ direction: ScrollDirection) { commit(.init(enabled: configuration.enabled, direction: direction, amountPercent: configuration.amountPercent, binding: configuration.binding)) }
    public func setAmountPercent(_ amountPercent: UInt32) { commit(.init(enabled: configuration.enabled, direction: configuration.direction, amountPercent: amountPercent, binding: configuration.binding)) }

    public func resetMalformedConfiguration() {
        guard !migrationFailed, configurationAttention == .malformed || configurationAttention == .saveFailed else { return }
        commit(.default, resettingMalformed: true)
    }

    public func refresh() { reconcileIntent() }

    public func requestAccessibilityAccess() {
        guard canRefresh else { return }
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        reconcileIntent()
    }

    public func shutdown(completion: @escaping @Sendable () -> Void) {
        canRefresh = false
        runtimeStatus = .unavailable
        state = .inputUnavailable
        monitor?.invalidate()
        monitor = nil
        lifecycle.shutdown(completion: completion)
    }

    deinit {
        monitor?.invalidate()
        lifecycle.shutdown()
    }

    private func commit(_ candidate: PersistedConfiguration, resettingMalformed: Bool = false) {
        guard canRefresh else { return }
        guard resettingMalformed || (canEditConfiguration && candidate != configuration) else { return }
        let operation = UUID()
        let result = store.persistOutcome(candidate, resettingMalformed: resettingMalformed)
        let committed = result.attention == .none
        // Rejected values are not configuration evidence; retain the allowlisted committed snapshot.
        trace?.configuration("config.persist", operationID: operation, oldRevision: revision, newRevision: committed ? revision &+ 1 : nil, configuration: committed ? candidate : configuration, result: result.result)
        guard committed else {
            trace?.configuration("config.rollback", operationID: operation, oldRevision: revision, newRevision: revision, configuration: configuration, result: "retained")
            configurationAttention = result.attention
            if result.attention == .newerSchema || result.attention == .malformed { reconcileIntent() } else { publishState() }
            return
        }
        operationID = operation
        previousRevision = revision
        configuration = candidate
        hasCommittedConfiguration = true
        configurationAttention = .none
        revision &+= 1
        runtimeStatus = .unavailable
        isSaving = false
        reconcileIntent()
    }

    private func reconcileIntent() {
        guard canRefresh else { return }
        accessibilityTrusted = AXIsProcessTrusted()
        let canRun = configurationAttention != .malformed && configurationAttention != .newerSchema
        if configuration.enabled, canRun, monitor == nil {
            monitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        } else if (!configuration.enabled || !canRun), let monitor {
            monitor.invalidate()
            self.monitor = nil
        }
        publishState()
        lifecycle.request(enabled: configuration.enabled, trusted: accessibilityTrusted && canRun, direction: configuration.direction, amountPercent: configuration.amountPercent, binding: configuration.binding, revision: revision, operationID: operationID, previousRevision: previousRevision)
    }

    private func publishState() {
        state = .resolve(enabled: configuration.enabled, accessibilityTrusted: accessibilityTrusted, runtimeStatus: runtimeStatus, attention: configurationAttention)
    }
}

private final class LifecycleExecutor: @unchecked Sendable {
    private struct Intent: Equatable {
        var enabled: Bool
        var trusted: Bool
        var direction: ScrollDirection
        var amountPercent: UInt32
        var binding: ButtonBinding?
        var revision: UInt64
        var operationID: UUID
        var previousRevision: UInt64?
    }

    private let trace: TracePipeline?
    private var lastActivation: Intent?
    private var lastActivationResult: String?

    init(trace: TracePipeline?) { self.trace = trace }

    private let queue = DispatchQueue(label: "io.github.webkitvn.mousemeld.lifecycle")
    private let lock = NSLock()
    private var intent = Intent(enabled: false, trusted: false, direction: .preserve, amountPercent: 100, binding: nil, revision: 0, operationID: UUID(), previousRevision: nil)
    private var pending = false
    private var draining = false
    private var shutdownRequested = false

    var onStatus: ((ScrollRuntimeStatus) -> Void)?

    private var runtime: ScrollRuntime?
    private var activeRevision: UInt64?
    private var startFailures = 0
    private var nextStartAllowed = DispatchTime.now()

    func request(enabled: Bool, trusted: Bool, direction: ScrollDirection, amountPercent: UInt32, binding: ButtonBinding?, revision: UInt64, operationID: UUID, previousRevision: UInt64?) {
        lock.lock()
        guard !shutdownRequested else { lock.unlock(); return }
        intent = Intent(enabled: enabled, trusted: trusted, direction: direction, amountPercent: amountPercent, binding: binding, revision: revision, operationID: operationID, previousRevision: previousRevision)
        pending = true
        guard !draining else { lock.unlock(); return }
        draining = true
        lock.unlock()
        queue.async { [weak self] in self?.drain() }
    }

    func shutdown(completion: @escaping @Sendable () -> Void = {}) {
        lock.lock()
        if shutdownRequested {
            lock.unlock()
            queue.async(execute: completion)
            return
        }
        shutdownRequested = true
        pending = false
        intent.enabled = false
        // Enqueue under the lock so repeated requests complete only after retirement.
        queue.async {
            self.runtime?.stop()
            self.runtime = nil
            self.trace?.lifecycle(1)
            self.trace?.close()
            completion()
        }
        lock.unlock()
    }

    private func drain() {
        while true {
            lock.lock()
            guard pending, !shutdownRequested else { draining = false; lock.unlock(); return }
            pending = false
            lock.unlock()
            reconcile()
        }
    }

    private func latestIntent() -> Intent {
        lock.lock()
        defer { lock.unlock() }
        return intent
    }

    private func isShutdown() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return shutdownRequested
    }

    private func reconcile() {
        guard !isShutdown() else { return }
        let desired = latestIntent()
        guard desired.enabled, desired.trusted else {
            retire()
            activation(desired, result: desired.enabled ? "unavailable" : "disabled")
            return
        }
        if let runtime {
            guard activeRevision == desired.revision else {
                runtime.stop()
                self.runtime = nil
                activeRevision = nil
                return reconcile()
            }
            guard runtime.status == .active else {
                runtime.stop()
                self.runtime = nil
                activeRevision = nil
                registerStartFailure()
                activation(desired, result: "unavailable")
                publish(.unavailable)
                return
            }
            activation(desired, result: "active")
            publish(.active)
            return
        }
        guard DispatchTime.now() >= nextStartAllowed else {
            activation(desired, result: "unavailable")
            publish(.unavailable)
            return
        }
        guard let candidate = ScrollRuntime(direction: desired.direction, amountPercent: desired.amountPercent, binding: desired.binding, trace: trace, configRevision: desired.revision), candidate.start() else {
            registerStartFailure()
            activation(desired, result: "unavailable")
            publish(.unavailable)
            return
        }
        let latest = latestIntent()
        guard latest.enabled, latest.trusted else {
            candidate.stop()
            resetRetry()
            publish(.unavailable)
            return
        }
        guard latest.revision == desired.revision, latest.direction == desired.direction, latest.amountPercent == desired.amountPercent, latest.binding == desired.binding else {
            candidate.stop()
            return reconcile()
        }
        guard candidate.status == .active else {
            candidate.stop()
            registerStartFailure()
            activation(desired, result: "unavailable")
            publish(.unavailable)
            return
        }
        runtime = candidate
        activeRevision = desired.revision
        resetRetry()
        activation(desired, result: "active")
        publish(.active)
    }

    private func activation(_ desired: Intent, result: String) {
        guard lastActivation != desired || lastActivationResult != result else { return }
        lastActivation = desired
        lastActivationResult = result
        trace?.configuration("config.activation", operationID: desired.operationID, oldRevision: desired.previousRevision, newRevision: result == "active" ? desired.revision : nil, configuration: .init(enabled: desired.enabled, direction: desired.direction, amountPercent: desired.amountPercent, binding: desired.binding), result: result)
    }

    private func retire() {
        runtime?.stop()
        runtime = nil
        activeRevision = nil
        resetRetry()
        publish(.unavailable)
    }

    private func registerStartFailure() {
        startFailures += 1
        nextStartAllowed = DispatchTime.now() + Self.backoffDelay(failures: startFailures)
    }

    private func resetRetry() {
        startFailures = 0
        nextStartAllowed = .now()
    }

    private static func backoffDelay(failures: Int) -> DispatchTimeInterval { .seconds(1 << min(failures, 3)) }

    private func publish(_ status: ScrollRuntimeStatus) {
        guard !isShutdown() else { return }
        DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
    }
}
