import CPointerInput
import Foundation

private let abiVersion: UInt32 = 3
private let successStatus: UInt32 = 0
private let busyStatus: UInt32 = 4
private let systemDirection: UInt32 = 0
private let reverseDirection: UInt32 = 1
private let unknownSource: UInt32 = 2
private let lineBasedGranularity: UInt32 = 0
private let scrollEvent: UInt32 = 0
private let preserveDecision: UInt32 = 0
private let replaceDecision: UInt32 = 1
private let suppressDecision: UInt32 = 2
private let closedCycle: UInt32 = 0

public enum InputDecision: Equatable {
    case preserve
    case replace(horizontalHundredths: Int64, verticalHundredths: Int64)
    case suppress
}

public enum ScrollDirection: String, CaseIterable, Codable, Sendable {
    case preserve
    case reverse
    fileprivate var abiValue: UInt32 { self == .preserve ? systemDirection : reverseDirection }
}

public struct ButtonBinding: Equatable, Sendable {
    public let enabled: Bool
    public let buttonNumber: UInt32
    public init?(enabled: Bool, buttonNumber: UInt32) {
        guard (3...31).contains(buttonNumber) else { return nil }
        self.enabled = enabled
        self.buttonNumber = buttonNumber
    }
}

public struct InputConfiguration: Equatable {
    public let direction: ScrollDirection
    public let amountPercent: UInt32
    public let binding: ButtonBinding?
    public init(direction: ScrollDirection, amountPercent: UInt32, binding: ButtonBinding? = nil) {
        self.direction = direction
        self.amountPercent = amountPercent
        self.binding = binding
    }
}

private func abiConfiguration(direction: ScrollDirection, amountPercent: UInt32, binding: ButtonBinding?) -> pointer_input_configuration_v3 {
    pointer_input_configuration_v3(
        version: abiVersion,
        size: UInt32(MemoryLayout<pointer_input_configuration_v3>.size),
        direction: direction.abiValue,
        amount_percent: amountPercent,
        binding_present: binding == nil ? 0 : 1,
        binding_enabled: binding?.enabled == true ? 1 : 0,
        binding_button_number: binding?.buttonNumber ?? 0,
        reserved: 0
    )
}

public func validate(direction: ScrollDirection, amountPercent: UInt32 = 100, binding: ButtonBinding? = nil) -> Bool {
    var configuration = abiConfiguration(direction: direction, amountPercent: amountPercent, binding: binding)
    return pointer_input_configuration_validate_v3(&configuration) == successStatus
}

public final class PointerInputEngine {
    private var owner: UnsafeMutableRawPointer?
    // One owning runtime serializes each engine: configure before its callback thread starts,
    // then replaces the runtime per revision. Harnesses and tests do the same sequentially.
    public private(set) var configuration = InputConfiguration(direction: .preserve, amountPercent: 100)

    public init?() {
        for _ in 0..<10 {
            let status = pointer_input_engine_create_v3(&owner)
            if status == successStatus, owner != nil { return }
            guard status == busyStatus else { return nil }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return nil
    }

    deinit { _ = pointer_input_engine_destroy_v3(&owner) }

    public func setSystemDirection() -> Bool { setDirection(.preserve) }
    public func setReverseDirection() -> Bool { setDirection(.reverse) }
    public func setDirection(_ direction: ScrollDirection, amountPercent: UInt32 = 100, binding: ButtonBinding? = nil) -> Bool {
        var configuration = abiConfiguration(direction: direction, amountPercent: amountPercent, binding: binding)
        guard pointer_input_engine_set_configuration_v3(owner, &configuration) == successStatus else { return false }
        self.configuration = InputConfiguration(direction: direction, amountPercent: amountPercent, binding: binding)
        return true
    }

    public func evaluate(horizontal: Int64, vertical: Int64) -> InputDecision? {
        var event = pointer_input_event_v3(
            version: abiVersion, size: UInt32(MemoryLayout<pointer_input_event_v3>.size),
            event_kind: scrollEvent, source_class: unknownSource, granularity: lineBasedGranularity,
            button_phase: 0, button_number: 0, modifiers_held: 0,
            horizontal_lines: horizontal, vertical_lines: vertical,
            event_number: 0, monotonic_time_ns: 0, reserved: (0, 0)
        )
        var cycle = pointer_input_decision_v3(
            version: abiVersion, size: UInt32(MemoryLayout<pointer_input_decision_v3>.size),
            decision: preserveDecision, request_back: 0, cycle_tag: closedCycle, reserved: (0, 0, 0),
            horizontal_hundredths: 0, vertical_hundredths: 0, cycle_button_number: 0, cycle_reserved: 0,
            cycle_event_number: 0, cycle_deadline_monotonic_ns: 0
        )
        var output = cycle
        guard pointer_input_engine_evaluate_v3(owner, &event, &cycle, &output) == successStatus,
              output.version == abiVersion,
              output.size == MemoryLayout<pointer_input_decision_v3>.size,
              output.reserved == (0, 0, 0),
              output.cycle_reserved == 0,
              output.request_back == 0
        else { return nil }
        switch output.decision {
        case preserveDecision: return .preserve
        case replaceDecision: return .replace(horizontalHundredths: output.horizontal_hundredths, verticalHundredths: output.vertical_hundredths)
        case suppressDecision: return .suppress
        default: return nil
        }
    }
}
