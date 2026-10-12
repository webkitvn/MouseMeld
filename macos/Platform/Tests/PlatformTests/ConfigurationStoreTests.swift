import Bridge
import Foundation
import Platform
import XCTest

final class ConfigurationStoreTests: XCTestCase {
    private var directory: URL!
    private var traceEnvironment: String?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        traceEnvironment = ProcessInfo.processInfo.environment["MMF_TRACE"]
        setenv("MMF_TRACE", "0", 1)
    }

    override func tearDownWithError() throws {
        if let traceEnvironment { setenv("MMF_TRACE", traceEnvironment, 1) } else { unsetenv("MMF_TRACE") }
        try? FileManager.default.removeItem(at: directory)
    }

    func testFreshConfigurationDefaultsWithoutCreatingFile() {
        let store = ConfigurationStore(directory: directory)
        XCTAssertEqual(store.load().0, .default)
        XCTAssertEqual(store.load().1, .none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testV3ConfigurationPersistsAcrossRestart() throws {
        let store = ConfigurationStore(directory: directory)
        for amount: UInt32 in [25, 100, 137, 400] {
            let expected = PersistedConfiguration(enabled: true, direction: .reverse, amountPercent: amount)
            XCTAssertTrue(store.persist(expected))
            let loaded = ConfigurationStore(directory: directory).load()
            XCTAssertEqual(loaded.0, expected)
            XCTAssertEqual(loaded.1, .none)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
            XCTAssertEqual(object["schema_version"] as? Int, 3)
            XCTAssertEqual(Set(object.keys), ["schema_version", "scroll"])
            let scroll = try XCTUnwrap(object["scroll"] as? [String: Any])
            XCTAssertEqual(Set(scroll.keys), ["enabled", "line_direction", "line_amount_percent"])
            XCTAssertEqual(scroll["line_amount_percent"] as? UInt32, amount)
        }
    }

    func testV1MigratesOnlyAfterAtomicPersistence() throws {
        let store = ConfigurationStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for enabled in [false, true] {
            for direction in ScrollDirection.allCases {
                let source = Data("{\"schema_version\":1,\"scroll\":{\"enabled\":\(enabled),\"line_direction\":\"\(direction.rawValue)\"}}".utf8)
                try source.write(to: store.url)
                let loaded = store.load()
                XCTAssertEqual(loaded.0, .init(enabled: enabled, direction: direction, amountPercent: 100))
                XCTAssertEqual(loaded.1, .none)
                let migrated = try Data(contentsOf: store.url)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
                XCTAssertEqual(object["schema_version"] as? Int, 3)
                XCTAssertEqual((object["scroll"] as? [String: Any])?["line_amount_percent"] as? Int, 100)
                XCTAssertEqual(ConfigurationStore(directory: directory).load().0, loaded.0)
                XCTAssertEqual(try Data(contentsOf: store.url), migrated)
            }
        }
    }

    func testFailedMigrationPreservesV1WithoutActivation() throws {
        let store = ConfigurationStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = Data(#"{"schema_version":1,"scroll":{"enabled":true,"line_direction":"reverse"}}"#.utf8)
        try source.write(to: store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        let loaded = store.load()
        XCTAssertEqual(loaded.0, .default)
        XCTAssertEqual(loaded.1, .saveFailed)
        XCTAssertEqual(try Data(contentsOf: store.url), source)
        let runtime = InputRuntime(store: store)
        XCTAssertEqual(runtime.configuration, .default)
        XCTAssertEqual(runtime.configurationAttention, .saveFailed)
        XCTAssertNotEqual(runtime.state, .active)
        XCTAssertFalse(runtime.canEditConfiguration)
        XCTAssertTrue(runtime.migrationFailed)
        XCTAssertEqual(try Data(contentsOf: store.url), source)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        runtime.setDirection(.reverse)
        runtime.setEnabled(true)
        runtime.resetMalformedConfiguration()
        runtime.refresh()
        XCTAssertEqual(runtime.configuration, .default)
        XCTAssertEqual(runtime.configurationAttention, .saveFailed)
        XCTAssertFalse(runtime.canEditConfiguration)
        XCTAssertNotEqual(runtime.state, .active)
        XCTAssertEqual(try Data(contentsOf: store.url), source)

        let restarted = InputRuntime(store: store)
        XCTAssertEqual(restarted.configuration, .init(enabled: true, direction: .reverse, amountPercent: 100))
        XCTAssertEqual(restarted.configurationAttention, .none)
        XCTAssertTrue(restarted.canEditConfiguration)
        XCTAssertFalse(restarted.migrationFailed)
    }

    func testUnreadableConfigurationDefaultsWithAttentionWithoutRewrite() throws {
        let store = ConfigurationStore(directory: directory)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: true)

        XCTAssertEqual(store.load().0, .default)
        XCTAssertEqual(store.load().1, .malformed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testMalformedConfigurationDefaultsWithoutRewrite() throws {
        let store = ConfigurationStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data("not json".utf8)
        try data.write(to: store.url)
        XCTAssertEqual(store.load().0, .default)
        XCTAssertEqual(store.load().1, .malformed)
        XCTAssertEqual(try Data(contentsOf: store.url), data)
    }

    func testFractionalOrSurplusV1DocumentDefaultsWithoutRewrite() throws {
        let store = ConfigurationStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for text in [
            #"{"schema_version":1.0,"scroll":{"enabled":true,"line_direction":"reverse"}}"#,
            #"{"schema_version":1,"scroll":{"enabled":true,"line_direction":"reverse"},"extra":true}"#,
            #"{"schema_version":1,"scroll":{"enabled":true,"line_direction":"reverse","extra":true}}"#,
        ] {
            let data = Data(text.utf8)
            try data.write(to: store.url)
            XCTAssertEqual(store.load().0, .default)
            XCTAssertEqual(store.load().1, .malformed)
            XCTAssertEqual(try Data(contentsOf: store.url), data)
        }
    }

    func testInvalidHistoricalAndUnsupportedOlderConfigurationNeverRewrite() throws {
        let store = ConfigurationStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var documents = ["24", "401", "-1", "4294967296", "18446744073709551615", "137.5", "137.0", "true", "false", "\"137\"", "null", "{}", "[]"].map {
            "{\"schema_version\":2,\"scroll\":{\"enabled\":true,\"line_direction\":\"reverse\",\"line_amount_percent\":\($0)}}"
        }
        documents += [
            #"{"schema_version":2,"scroll":{"enabled":true,"line_direction":"reverse"}}"#,
            #"{"schema_version":2,"scroll":{"enabled":true,"line_direction":"reverse","line_amount_percent":137,"extra":true}}"#,
            #"{"schema_version":2,"scroll":{"enabled":true,"line_direction":"reverse","line_amount_percent":137},"extra":true}"#,
            #"{"schema_version":2,"scroll":{"enabled":1,"line_direction":"reverse","line_amount_percent":137}}"#,
            #"{"schema_version":2,"scroll":{"enabled":true,"line_direction":"invalid","line_amount_percent":137}}"#,
            #"{"schema_version":2,"scroll":{"line_direction":"reverse","line_amount_percent":137}}"#,
            #"{"schema_version":2,"scroll":{"enabled":true,"line_amount_percent":137}}"#,
            #"{"schema_version":0,"scroll":{"enabled":true,"line_direction":"reverse"}}"#,
            #"{"schema_version":-1,"scroll":{"enabled":true,"line_direction":"reverse"}}"#,
            #"{"schema_version":true,"scroll":{}}"#,
            #"{"schema_version":2.0,"scroll":{}}"#,
        ]
        for text in documents {
            let data = Data(text.utf8)
            try data.write(to: store.url)
            let loaded = store.load()
            XCTAssertEqual(loaded.0, .default, text)
            XCTAssertEqual(loaded.1, .malformed, text)
            XCTAssertEqual(try Data(contentsOf: store.url), data, text)
        }
    }

    func testNewerConfigurationIsReadOnlyWithoutRewrite() throws {
        let store = ConfigurationStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for version in ["4", "18446744073709551615"] {
            let data = Data("{\"schema_version\":\(version),\"scroll\":\"unknown-future-data\"}".utf8)
            try data.write(to: store.url)
            let loaded = store.load()
            XCTAssertEqual(loaded.0, .default)
            XCTAssertEqual(loaded.1, .newerSchema)
            XCTAssertEqual(try Data(contentsOf: store.url), data)
        }
    }

    func testPersistFailureLeavesExistingConfigurationUnchanged() throws {
        let store = ConfigurationStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: store.url)
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: true)
        XCTAssertFalse(store.persist(.init(enabled: true, direction: .reverse)))
    }

    func testInvalidAmountPersistNeverChangesCommittedBytes() throws {
        let store = ConfigurationStore(directory: directory)
        let committed = PersistedConfiguration(enabled: true, direction: .reverse, amountPercent: 137)
        XCTAssertTrue(store.persist(committed))
        let bytes = try Data(contentsOf: store.url)
        for amount: UInt32 in [0, 24, 401, .max] {
            XCTAssertFalse(store.persist(.init(enabled: false, direction: .preserve, amountPercent: amount)))
            XCTAssertEqual(try Data(contentsOf: store.url), bytes)
            XCTAssertEqual(store.load().0, committed)
        }
    }

    func testSharedWriterPreservesNewerSchemasAndRejectsBooleanVersionClassification() throws {
        let store = ConfigurationStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for version in ["4", "18446744073709551615"] {
            let bytes = Data("{\"schema_version\":\(version),\"future\":true}".utf8)
            try bytes.write(to: store.url)
            XCTAssertFalse(store.persist(.init(enabled: true, direction: .reverse, amountPercent: 137)))
            XCTAssertFalse(store.persist(.default))
            XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        }
        for version in ["true", "false"] {
            try Data("{\"schema_version\":\(version)}".utf8).write(to: store.url)
            let runtime = InputRuntime(store: store)
            XCTAssertEqual(runtime.configurationAttention, .malformed)
            runtime.resetMalformedConfiguration()
            XCTAssertEqual(runtime.configurationAttention, .none)
            XCTAssertEqual(store.load().0, .default)
        }
    }

    func testOversizedOrUncertainNumericSchemaCannotBeOverwritten() throws {
        let store = ConfigurationStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for version in ["18446744073709551616", "9999999999999999999999999999999999999999", "3.0000000000000000001", "3.0000000000000004", "1e200", "4.5", "4e2"] {
            let bytes = Data("{\"schema_version\":\(version),\"future\":true}".utf8)
            try bytes.write(to: store.url)
            XCTAssertEqual(store.load().1, .newerSchema)
            XCTAssertFalse(store.persist(.default))
            let runtime = InputRuntime(store: store)
            XCTAssertFalse(runtime.canEditConfiguration)
            runtime.resetMalformedConfiguration()
            runtime.setAmountPercent(137)
            runtime.setEnabled(true)
            XCTAssertEqual(runtime.configuration, .default)
            XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        }
    }

    func testUnrepresentableVersionUsesAcceptedMalformedResetRecovery() throws {
        let store = ConfigurationStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let version = "1" + String(repeating: "0", count: 166)
        let bytes = Data("{\"schema_version\":\(version),\"future\":true}".utf8)
        try bytes.write(to: store.url)
        XCTAssertThrowsError(try JSONSerialization.jsonObject(with: bytes))
        let runtime = InputRuntime(store: store)
        XCTAssertEqual(runtime.configuration, .default)
        XCTAssertEqual(runtime.configurationAttention, .malformed)
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        runtime.resetMalformedConfiguration()
        XCTAssertEqual(runtime.configuration, .default)
        XCTAssertEqual(runtime.configurationAttention, .none)
        XCTAssertEqual(runtime.state, .off)
        XCTAssertEqual(store.load().0, .default)
        XCTAssertNotEqual(try Data(contentsOf: store.url), bytes)
    }

    func testV3BindingPersistsAndRejectsInvalidDocumentsWithoutRewrite() throws {
        let store = ConfigurationStore(directory: directory)
        let binding = try XCTUnwrap(ButtonBinding(enabled: true, buttonNumber: 3))
        let configuration = PersistedConfiguration(enabled: false, direction: .reverse, amountPercent: 137, binding: binding)
        XCTAssertTrue(store.persist(configuration))
        XCTAssertEqual(ConfigurationStore(directory: directory).load().0, configuration)
        let bytes = try Data(contentsOf: store.url)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(object["schema_version"] as? Int, 3)
        XCTAssertEqual(Set(try XCTUnwrap(object["button_binding"] as? [String: Any]).keys), ["enabled", "button_number"])
        for invalid in [
            #"{"schema_version":3,"scroll":{"enabled":false,"line_direction":"reverse","line_amount_percent":137},"button_binding":null}"#,
            #"{"schema_version":3,"scroll":{"enabled":false,"line_direction":"reverse","line_amount_percent":137},"button_binding":{"enabled":true,"button_number":2}}"#,
            #"{"schema_version":3,"scroll":{"enabled":false,"line_direction":"reverse","line_amount_percent":137},"button_binding":{"enabled":true,"button_number":3,"extra":true}}"#,
        ] {
            let invalidBytes = Data(invalid.utf8)
            try invalidBytes.write(to: store.url)
            XCTAssertEqual(store.load().1, .malformed)
            XCTAssertEqual(try Data(contentsOf: store.url), invalidBytes)
        }
    }

    func testBridgeValidationAcceptsBothDirections() {
        XCTAssertTrue(validate(direction: .preserve))
        XCTAssertTrue(validate(direction: .reverse))
        XCTAssertTrue(validate(direction: .preserve, amountPercent: 25))
        XCTAssertTrue(validate(direction: .reverse, amountPercent: 400))
        XCTAssertFalse(validate(direction: .preserve, amountPercent: 24))
        XCTAssertFalse(validate(direction: .reverse, amountPercent: 401))
    }
}
