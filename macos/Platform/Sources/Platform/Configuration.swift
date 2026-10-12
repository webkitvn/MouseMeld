@_exported import Bridge
import Foundation

public struct PersistedConfiguration: Equatable, Sendable {
    public var enabled: Bool
    public var direction: ScrollDirection
    public var amountPercent: UInt32
    public var binding: ButtonBinding?

    public init(enabled: Bool, direction: ScrollDirection, amountPercent: UInt32 = 100, binding: ButtonBinding? = nil) {
        self.enabled = enabled
        self.direction = direction
        self.amountPercent = amountPercent
        self.binding = binding
    }

    public static let `default` = Self(enabled: false, direction: .preserve)
}

public enum ConfigurationAttention: Equatable {
    case none
    case malformed
    case newerSchema
    case saveFailed
}

public final class ConfigurationStore {
    private struct Document: Encodable {
        struct Scroll: Encodable {
            let enabled: Bool
            let lineDirection: ScrollDirection
            let lineAmountPercent: UInt32
            enum CodingKeys: String, CodingKey {
                case enabled
                case lineDirection = "line_direction"
                case lineAmountPercent = "line_amount_percent"
            }
        }
        struct ButtonBinding: Encodable {
            let enabled: Bool
            let buttonNumber: UInt32
            enum CodingKeys: String, CodingKey {
                case enabled
                case buttonNumber = "button_number"
            }
        }
        let schemaVersion: Int
        let scroll: Scroll
        let buttonBinding: ButtonBinding?
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case scroll
            case buttonBinding = "button_binding"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(scroll, forKey: .scroll)
            try container.encodeIfPresent(buttonBinding, forKey: .buttonBinding)
        }
    }

    public let url: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MouseMeld", isDirectory: true)
        url = base.appendingPathComponent("configuration.json")
    }

    public func load() -> (PersistedConfiguration, ConfigurationAttention) {
        let result = loadOutcome()
        return (result.configuration, result.attention)
    }

    func loadOutcome() -> (configuration: PersistedConfiguration, attention: ConfigurationAttention, result: String) {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return (.default, .none, "fresh") }
        catch { return (.default, .malformed, "read_failed") }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (.default, .malformed, "malformed") }
        let decoded = Self.decode(object)
        guard decoded.1 == .none else { return (decoded.0, decoded.1, decoded.1 == .newerSchema ? "newer_schema_read_only" : "malformed") }
        if let version = Self.schemaVersion(in: object)?.intValue, version == 1 || version == 2 {
            let result = persistResult(decoded.0)
            guard result == .none else { return (.default, result, "migration_failed") }
            return (decoded.0, .none, "migrated")
        }
        return (decoded.0, .none, "loaded")
    }

    private static func decode(_ object: [String: Any]) -> (PersistedConfiguration, ConfigurationAttention) {
        if let attention = Self.newerSchemaAttention(in: object) { return (.default, attention) }
        guard let version = Self.schemaVersion(in: object), [1, 2, 3].contains(version.intValue),
              (version.intValue == 3
                ? Set(object.keys) == ["schema_version", "scroll"] || Set(object.keys) == ["schema_version", "scroll", "button_binding"]
                : Set(object.keys) == ["schema_version", "scroll"]),
              let scroll = object["scroll"] as? [String: Any],
              Set(scroll.keys) == (version.intValue == 1 ? ["enabled", "line_direction"] : ["enabled", "line_direction", "line_amount_percent"]),
              let enabled = scroll["enabled"] as? NSNumber,
              CFGetTypeID(enabled) == CFBooleanGetTypeID(),
              let direction = scroll["line_direction"] as? String,
              let lineDirection = ScrollDirection(rawValue: direction) else { return (.default, .malformed) }
        var amountPercent: UInt32 = 100
        if version.intValue >= 2 {
            guard let amount = integer(scroll["line_amount_percent"]), let value = UInt32(exactly: amount) else { return (.default, .malformed) }
            amountPercent = value
        }
        let binding: ButtonBinding?
        if version.intValue == 3, let bindingObject = object["button_binding"] {
            guard let rawBinding = bindingObject as? [String: Any], Set(rawBinding.keys) == ["enabled", "button_number"],
                  let bindingEnabled = rawBinding["enabled"] as? NSNumber, CFGetTypeID(bindingEnabled) == CFBooleanGetTypeID(),
                  let buttonNumber = integer(rawBinding["button_number"]), let number = UInt32(exactly: buttonNumber),
                  let parsedBinding = ButtonBinding(enabled: bindingEnabled.boolValue, buttonNumber: number) else { return (.default, .malformed) }
            binding = parsedBinding
        } else if version.intValue == 3 {
            binding = nil
        } else {
            binding = nil
        }
        guard validate(direction: lineDirection, amountPercent: amountPercent, binding: binding) else { return (.default, .malformed) }
        return (.init(enabled: enabled.boolValue, direction: lineDirection, amountPercent: amountPercent, binding: binding), .none)
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)) else { return nil }
        return number.int64Value
    }
    private static func schemaVersion(in object: [String: Any]) -> NSNumber? {
        guard let version = object["schema_version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: version.objCType)) else { return nil }
        return version
    }
    private static func newerSchemaAttention(in object: [String: Any]) -> ConfigurationAttention? {
        guard let version = object["schema_version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.compare(NSNumber(value: 3)) == .orderedDescending || version.decimalValue > Decimal(3) else { return nil }
        // ponytail: preservation is bounded by Foundation decoding/distinct representation (#108); raw-token parsing requires a new contract.
        return .newerSchema
    }

    public func persist(_ configuration: PersistedConfiguration) -> Bool { persistResult(configuration) == .none }
    func persistResult(_ configuration: PersistedConfiguration, resettingMalformed: Bool = false) -> ConfigurationAttention {
        persistOutcome(configuration, resettingMalformed: resettingMalformed).attention
    }
    func persistOutcome(_ configuration: PersistedConfiguration, resettingMalformed: Bool = false) -> (attention: ConfigurationAttention, result: String) {
        guard validate(direction: configuration.direction, amountPercent: configuration.amountPercent, binding: configuration.binding) else { return (.saveFailed, "validation_rejected") }
        let document = Document(
            schemaVersion: 3,
            scroll: .init(enabled: configuration.enabled, lineDirection: configuration.direction, lineAmountPercent: configuration.amountPercent),
            buttonBinding: configuration.binding.map { .init(enabled: $0.enabled, buttonNumber: $0.buttonNumber) }
        )
        guard let data = try? JSONEncoder().encode(document) else { return (.saveFailed, "write_failed") }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existing: Data?
            do { existing = try Data(contentsOf: url) } catch CocoaError.fileReadNoSuchFile { existing = nil }
            if let existing {
                let object = try? JSONSerialization.jsonObject(with: existing) as? [String: Any]
                let attention = object.map { Self.decode($0).1 } ?? .malformed
                guard attention == .none || (resettingMalformed && attention == .malformed) else { return (attention, attention == .newerSchema ? "newer_schema_read_only" : "malformed") }
            }
            try data.write(to: url, options: .atomic)
            return (.none, "persisted")
        } catch { return (.saveFailed, "write_failed") }
    }
}
