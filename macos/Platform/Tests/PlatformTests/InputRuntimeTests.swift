import Foundation
import Platform
import XCTest

final class InputRuntimeTests: XCTestCase {
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

    private func runtime() -> InputRuntime {
        InputRuntime(store: ConfigurationStore(directory: directory))
    }

    func testShutdownRemainsUnavailableAndRejectsConfigurationAndRefresh() throws {
        let store = ConfigurationStore(directory: directory)
        XCTAssertTrue(store.persist(.init(enabled: false, direction: .preserve, amountPercent: 157)))
        let bytes = try Data(contentsOf: store.url)
        let subject = InputRuntime(store: store)
        let completed = expectation(description: "retirement completed")
        subject.shutdown { completed.fulfill() }
        XCTAssertEqual(subject.state, .inputUnavailable)
        XCTAssertFalse(subject.canEditConfiguration)
        XCTAssertFalse(subject.canRefresh)
        subject.setEnabled(true)
        subject.setAmountPercent(400)
        subject.setDirection(.reverse)
        subject.resetMalformedConfiguration()
        subject.refresh()
        wait(for: [completed], timeout: 5)
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        XCTAssertEqual(subject.state, .inputUnavailable)
        XCTAssertFalse(subject.canEditConfiguration)
        XCTAssertFalse(subject.canRefresh)
        XCTAssertEqual(subject.configuration, .init(enabled: false, direction: .preserve, amountPercent: 157))
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        let repeated = expectation(description: "repeated retirement completed")
        subject.shutdown { repeated.fulfill() }
        wait(for: [repeated], timeout: 5)
        XCTAssertEqual(subject.state, .inputUnavailable)
    }

    func testProductionConfigurationActivationAndInputBundle() throws {
        guard let root = ProcessInfo.processInfo.environment["MMF_TEST_CONFIGURATION_TRACE_ROOT"] else {
            throw XCTSkip("Run through tests/test_runtime_trace_bundle.py platform-boundary fixture")
        }
        let fixture = URL(fileURLWithPath: root)
        let traceDirectory = fixture.appendingPathComponent("traces")
        setenv("MMF_TRACE_DIR", traceDirectory.path, 1)
        setenv("MMF_TRACE", "1", 1)
        defer { unsetenv("MMF_TRACE_DIR"); setenv("MMF_TRACE", "0", 1) }
        let store = ConfigurationStore(directory: fixture.appendingPathComponent("config"))
        XCTAssertTrue(store.persist(.init(enabled: true, direction: .reverse, amountPercent: 137)))
        let initialBytes = try Data(contentsOf: store.url)
        var subject: InputRuntime? = InputRuntime(store: store)
        func waitFor(_ name: String, deadline: Date = Date().addingTimeInterval(5), _ condition: () -> Bool) {
            while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            XCTAssertTrue(condition(), name)
        }
        func records() -> [[String: Any]] {
            let runs = (try? FileManager.default.contentsOfDirectory(at: traceDirectory, includingPropertiesForKeys: nil)) ?? []
            return runs.flatMap { run in
                ((try? FileManager.default.contentsOfDirectory(at: run, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "jsonl" }.flatMap { file in
                    ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                }
            }
        }
        let failure = ProcessInfo.processInfo.environment["MMF_TEST_TAP_FAILURE"] != nil
        let untrusted = ProcessInfo.processInfo.environment["MMF_TEST_UNTRUSTED"] != nil
        let stalledSink = ProcessInfo.processInfo.environment["MMF_TEST_TRACE_STALL"] != nil
        if stalledSink {
            let started = try XCTUnwrap(ProcessInfo.processInfo.environment["MMF_TEST_TRACE_STALL_STARTED"])
            let callbacksDone = try XCTUnwrap(ProcessInfo.processInfo.environment["MMF_TEST_TRACE_STALL_CALLBACKS_DONE"])
            let release = try XCTUnwrap(ProcessInfo.processInfo.environment["MMF_TEST_TRACE_STALL_RELEASE"])
            let summary = try XCTUnwrap(ProcessInfo.processInfo.environment["MMF_TEST_TRACE_STALL_SUMMARY"])
            waitFor("stalled trace write started") { FileManager.default.fileExists(atPath: started) }
            waitFor("stalled trace callbacks complete") { FileManager.default.fileExists(atPath: callbacksDone) }
            XCTAssertEqual(try String(contentsOf: fixture.appendingPathComponent("native.txt"), encoding: .utf8), "-13700 -13700\n")
            XCTAssertEqual(try String(contentsOfFile: summary, encoding: .utf8), "140000 0\n")
            waitFor("stalled trace release") { FileManager.default.fileExists(atPath: release) }
            subject = nil
            // The Python parent bounds completion after release; draining the finite queue is not a latency gate.
            waitFor("stalled trace clean drain", deadline: .distantFuture) {
                let runs = (try? FileManager.default.contentsOfDirectory(at: traceDirectory, includingPropertiesForKeys: nil)) ?? []
                return runs.contains { run in
                    guard let data = try? Data(contentsOf: run.appendingPathComponent("manifest.json")), let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                    return manifest["clean_shutdown"] as? Bool == true && manifest["writer_failed"] as? Bool == false && (manifest["drop_count"] as? Int ?? 0) > 0
                }
            }
            return
        }
        if failure || untrusted {
            waitFor("unavailable activation") { records().contains { $0["name"] as? String == "config.activation" && $0["result_code"] as? String == "unavailable" } }
            let initial = try XCTUnwrap(records().first { $0["name"] as? String == "config.load" })
            let initialActivation = try XCTUnwrap(records().first { $0["name"] as? String == "config.activation" && $0["operation_id"] as? String == initial["operation_id"] as? String })
            XCTAssertEqual(initialActivation["result_code"] as? String, "unavailable")
            XCTAssertTrue(initialActivation["old_config_revision"] is NSNull)
            XCTAssertTrue(initialActivation["new_config_revision"] is NSNull)
            XCTAssertEqual(initialActivation["line_amount_percent"] as? Int, 137)
            XCTAssertTrue(initialActivation["enabled"] as? Bool == true)
            XCTAssertEqual(try Data(contentsOf: store.url), initialBytes)
            subject?.setAmountPercent(25)
            waitFor("unavailable persisted activation") {
                let all = records()
                guard let persisted = all.first(where: { $0["result_code"] as? String == "persisted" }) else { return false }
                return all.contains { $0["name"] as? String == "config.activation" && $0["operation_id"] as? String == persisted["operation_id"] as? String && $0["result_code"] as? String == "unavailable" }
            }
            let all = records()
            let unavailable = all.filter { $0["name"] as? String == "config.activation" && $0["result_code"] as? String == "unavailable" }
            XCTAssertTrue(unavailable.allSatisfy { $0["new_config_revision"] is NSNull })
            XCTAssertFalse(all.contains { $0["name"] as? String == "input.pipeline" })
            if failure {
                XCTAssertEqual(try String(contentsOf: fixture.appendingPathComponent("native.txt"), encoding: .utf8), "tap_creation_failed\n")
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("native.txt").path))
            }
        } else {
            waitFor("initial activation") { subject?.state == .active && records().contains { $0["name"] as? String == "input.pipeline" && $0["config_revision"] as? Int == 0 } }
            subject?.setAmountPercent(25)
            waitFor("updated activation") { subject?.state == .active && records().contains { $0["name"] as? String == "input.pipeline" && $0["config_revision"] as? Int == 1 } }
            let bytes = try Data(contentsOf: store.url)
            subject?.setAmountPercent(401)
            XCTAssertEqual(subject?.configuration.amountPercent, 25)
            XCTAssertEqual(try Data(contentsOf: store.url), bytes)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store.url.deletingLastPathComponent().path)
            subject?.setAmountPercent(400)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.url.deletingLastPathComponent().path)
            XCTAssertEqual(subject?.configuration.amountPercent, 25)
            XCTAssertEqual(try Data(contentsOf: store.url), bytes)
            let previousInputs = records().filter { $0["name"] as? String == "input.pipeline" }.count
            waitFor("post-failure input") { records().filter { $0["name"] as? String == "input.pipeline" }.count > previousInputs }
            subject?.setEnabled(false)
            waitFor("disabled activation") { records().contains { $0["name"] as? String == "config.activation" && $0["result_code"] as? String == "disabled" && $0["enabled"] as? Bool == false } }
            let inputsAfterDisable = records().filter { $0["name"] as? String == "input.pipeline" }.count
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            XCTAssertEqual(records().filter { $0["name"] as? String == "input.pipeline" }.count, inputsAfterDisable)
        }
        subject = nil
        waitFor("trace clean shutdown") {
            let runs = (try? FileManager.default.contentsOfDirectory(at: traceDirectory, includingPropertiesForKeys: nil)) ?? []
            return runs.contains { run in
                guard let data = try? Data(contentsOf: run.appendingPathComponent("manifest.json")), let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                return manifest["clean_shutdown"] as? Bool == true
            }
        }
    }

    func testLoadTraceDistinguishesMigrationAndReadOnlyFailures() throws {
        let previousDirectory = ProcessInfo.processInfo.environment["MMF_TRACE_DIR"]
        defer {
            if let previousDirectory { setenv("MMF_TRACE_DIR", previousDirectory, 1) } else { unsetenv("MMF_TRACE_DIR") }
            setenv("MMF_TRACE", "0", 1)
        }
        for (text, result, readOnly) in [
            (#"{"schema_version":1,"scroll":{"enabled":false,"line_direction":"reverse"}}"#, "migrated", false),
            (#"{"schema_version":1,"scroll":{"enabled":false,"line_direction":"reverse"}}"#, "migration_failed", true),
            (#"{"schema_version":4,"future":true}"#, "newer_schema_read_only", false),
            ("broken JSON", "malformed", false),
            (#"{"schema_version":2,"scroll":{"enabled":false,"line_direction":"reverse","line_amount_percent":137}}"#, "migrated", false)
        ] {
            let configDirectory = directory.appendingPathComponent(result)
            let traceDirectory = directory.appendingPathComponent("trace-" + result)
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            let store = ConfigurationStore(directory: configDirectory)
            let source = Data(text.utf8)
            try source.write(to: store.url)
            if readOnly { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: configDirectory.path) }
            setenv("MMF_TRACE_DIR", traceDirectory.path, 1)
            setenv("MMF_TRACE", "1", 1)
            var subject: InputRuntime? = InputRuntime(store: store)
            XCTAssertEqual(subject?.configuration.amountPercent, text.contains("line_amount_percent") ? 137 : 100)
            XCTAssertEqual(subject?.hasCommittedConfiguration, result == "loaded" || result == "migrated")
            if result == "migration_failed" {
                XCTAssertTrue(subject?.migrationFailed == true)
                XCTAssertFalse(subject?.canEditConfiguration == true)
            }
            if readOnly { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: configDirectory.path) }
            if result != "migrated" { XCTAssertEqual(try Data(contentsOf: store.url), source) }
            func liveRecords() -> [[String: Any]] {
                let runs = (try? FileManager.default.contentsOfDirectory(at: traceDirectory, includingPropertiesForKeys: nil)) ?? []
                return runs.flatMap { run in
                    ((try? FileManager.default.contentsOfDirectory(at: run, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "jsonl" }.flatMap { file in
                        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                    }
                }
            }
            let discoveryDeadline = Date().addingTimeInterval(5)
            let requiresRetiredActivation = result != "loaded" && result != "migrated"
            var discovered = false
            while Date() < discoveryDeadline {
                let records = liveRecords()
                guard let load = records.first(where: { $0["name"] as? String == "config.load" && $0["result_code"] as? String == result }) else { Thread.sleep(forTimeInterval: 0.01); continue }
                if !requiresRetiredActivation || records.contains(where: { $0["name"] as? String == "config.activation" && $0["operation_id"] as? String == load["operation_id"] as? String }) {
                    discovered = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            XCTAssertTrue(discovered, "expected matching load evidence before shutdown")
            subject = nil
            let completionDeadline = Date().addingTimeInterval(5)
            var completed = [[String: Any]]()
            while Date() < completionDeadline {
                for run in (try? FileManager.default.contentsOfDirectory(at: traceDirectory, includingPropertiesForKeys: nil)) ?? [] {
                    guard let data = try? Data(contentsOf: run.appendingPathComponent("manifest.json")), let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any], manifest["clean_shutdown"] as? Bool == true else { continue }
                    completed = try FileManager.default.contentsOfDirectory(at: run, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }.flatMap { file in
                        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
                    }
                    break
                }
                if !completed.isEmpty { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            let load = try XCTUnwrap(completed.first { $0["name"] as? String == "config.load" })
            XCTAssertEqual(load["result_code"] as? String, result)
            if result == "loaded" || result == "migrated" { XCTAssertEqual(load["new_config_revision"] as? Int, 0) }
            else {
                XCTAssertTrue(load["new_config_revision"] is NSNull)
                let activation = try XCTUnwrap(completed.first { $0["name"] as? String == "config.activation" && $0["operation_id"] as? String == load["operation_id"] as? String })
                XCTAssertEqual(activation["result_code"] as? String, "disabled")
                XCTAssertTrue(activation["new_config_revision"] is NSNull)
                XCTAssertFalse(completed.contains { $0["name"] as? String == "input.pipeline" })
            }
        }
    }

    func testConfigurationTraceJoinsTransactionsAndRollback() throws {
        let traceDirectory = directory.appendingPathComponent("traces")
        let previousDirectory = ProcessInfo.processInfo.environment["MMF_TRACE_DIR"]
        setenv("MMF_TRACE_DIR", traceDirectory.path, 1)
        setenv("MMF_TRACE", "1", 1)
        defer {
            if let previousDirectory { setenv("MMF_TRACE_DIR", previousDirectory, 1) } else { unsetenv("MMF_TRACE_DIR") }
            setenv("MMF_TRACE", "0", 1)
        }
        let store = ConfigurationStore(directory: directory)
        var subject: InputRuntime? = InputRuntime(store: store)
        for amount: UInt32 in [25, 100, 137, 400] { subject?.setAmountPercent(amount) }
        let bytes = try Data(contentsOf: store.url)
        subject?.setAmountPercent(401)
        XCTAssertEqual(subject?.configuration.amountPercent, 400)
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        subject?.setAmountPercent(25)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertEqual(subject?.configuration.amountPercent, 400)
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        subject = nil
        let deadline = Date().addingTimeInterval(5)
        var records = [[String: Any]]()
        var completedRun: URL?
        while Date() < deadline {
            let runs = (try? FileManager.default.contentsOfDirectory(at: traceDirectory, includingPropertiesForKeys: nil)) ?? []
            if let run = runs.first,
               let data = try? Data(contentsOf: run.appendingPathComponent("manifest.json")),
               let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any], manifest["clean_shutdown"] as? Bool == true {
                completedRun = run
                for file in try FileManager.default.contentsOfDirectory(at: run, includingPropertiesForKeys: nil) where file.pathExtension == "jsonl" {
                    for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
                        records.append(try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]))
                    }
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        records.sort { ($0["seq"] as? Int ?? 0) < ($1["seq"] as? Int ?? 0) }
        let configurationRecords = records.filter { $0["component"] as? String == "configuration" }
        XCTAssertEqual(configurationRecords.first { $0["name"] as? String == "config.load" }?["result_code"] as? String, "fresh")
        let persisted = configurationRecords.filter { $0["result_code"] as? String == "persisted" }
        XCTAssertEqual(persisted.compactMap { $0["line_amount_percent"] as? Int }, [25, 100, 137, 400])
        for (index, record) in persisted.enumerated() {
            XCTAssertEqual(record["old_config_revision"] as? Int, index)
            XCTAssertEqual(record["new_config_revision"] as? Int, index + 1)
        }
        let rejected = try XCTUnwrap(configurationRecords.first { $0["result_code"] as? String == "validation_rejected" })
        let rollback = try XCTUnwrap(configurationRecords.first { $0["name"] as? String == "config.rollback" })
        XCTAssertEqual(rejected["operation_id"] as? String, rollback["operation_id"] as? String)
        XCTAssertTrue(rejected["new_config_revision"] is NSNull)
        XCTAssertEqual(rollback["new_config_revision"] as? Int, 4)
        let writeFailure = try XCTUnwrap(configurationRecords.first { $0["result_code"] as? String == "write_failed" })
        XCTAssertTrue(writeFailure["new_config_revision"] is NSNull)
        XCTAssertTrue(configurationRecords.contains { $0["name"] as? String == "config.rollback" && $0["operation_id"] as? String == writeFailure["operation_id"] as? String && $0["new_config_revision"] as? Int == 4 })
        XCTAssertFalse(configurationRecords.contains { $0["result_code"] as? String == "active" })
        let run = try XCTUnwrap(completedRun)
        let export = Process()
        export.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        export.arguments = ["python3", repository.appendingPathComponent("scripts/trace.py").path, "export", run.lastPathComponent, directory.appendingPathComponent("export").path]
        try export.run()
        export.waitUntilExit()
        XCTAssertEqual(export.terminationStatus, 0)
    }

    func testFreshDefaultsAndMalformedRepairHaveDistinctProvenance() throws {
        let store = ConfigurationStore(directory: directory)
        let fresh = InputRuntime(store: store)
        XCTAssertEqual(fresh.configuration, .default)
        XCTAssertTrue(fresh.hasCommittedConfiguration)
        XCTAssertTrue(fresh.canEditConfiguration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("broken JSON".utf8).write(to: store.url)
        let malformed = InputRuntime(store: store)
        XCTAssertEqual(malformed.configuration, .default)
        XCTAssertFalse(malformed.hasCommittedConfiguration)
        XCTAssertFalse(malformed.canEditConfiguration)
        malformed.setAmountPercent(137)
        XCTAssertFalse(malformed.hasCommittedConfiguration)
        malformed.resetMalformedConfiguration()
        XCTAssertEqual(malformed.configuration, .default)
        XCTAssertTrue(malformed.hasCommittedConfiguration)
        XCTAssertTrue(malformed.canEditConfiguration)
        XCTAssertEqual(store.load().0, .default)
    }

    func testLoadedAmountSurvivesRefreshAndExistingControls() throws {
        let store = ConfigurationStore(directory: directory)
        XCTAssertTrue(store.persist(.init(enabled: false, direction: .reverse, amountPercent: 137)))
        let runtime = InputRuntime(store: store)
        XCTAssertEqual(runtime.configuration.amountPercent, 137)
        runtime.refresh()
        runtime.setDirection(.preserve)
        runtime.setEnabled(false)
        XCTAssertEqual(runtime.configuration, .init(enabled: false, direction: .preserve, amountPercent: 137))
        XCTAssertEqual(store.load().0, runtime.configuration)
    }

    func testAmountTransactionsPreserveWholeConfigurationAcrossRestart() throws {
        let store = ConfigurationStore(directory: directory)
        XCTAssertTrue(store.persist(.init(enabled: false, direction: .reverse)))
        let runtime = InputRuntime(store: store)
        for amount: UInt32 in [25, 100, 137, 400] {
            runtime.setAmountPercent(amount)
            let expected = PersistedConfiguration(enabled: false, direction: .reverse, amountPercent: amount)
            XCTAssertEqual(runtime.configuration, expected)
            XCTAssertEqual(runtime.configurationAttention, .none)
            XCTAssertEqual(InputRuntime(store: store).configuration, expected)
            runtime.setDirection(.preserve)
            XCTAssertEqual(runtime.configuration, .init(enabled: false, direction: .preserve, amountPercent: amount))
            XCTAssertEqual(store.load().0, runtime.configuration)
            runtime.setDirection(.reverse)
        }
    }

    func testInvalidAmountTransactionKeepsCommittedFileAndSnapshot() throws {
        let store = ConfigurationStore(directory: directory)
        let committed = PersistedConfiguration(enabled: false, direction: .reverse, amountPercent: 137)
        XCTAssertTrue(store.persist(committed))
        let bytes = try Data(contentsOf: store.url)
        let runtime = InputRuntime(store: store)
        for amount: UInt32 in [0, 24, 401, .max] {
            runtime.setAmountPercent(amount)
            XCTAssertEqual(runtime.configuration, committed)
            XCTAssertEqual(runtime.configurationAttention, .saveFailed)
            XCTAssertTrue(runtime.hasCommittedConfiguration)
            XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        }
        runtime.setAmountPercent(25)
        XCTAssertEqual(runtime.configuration.amountPercent, 25)
        XCTAssertEqual(runtime.configurationAttention, .none)
    }

    func testBindingSurvivesRuntimeTransactionsRejectedWriteAndRetry() throws {
        let store = ConfigurationStore(directory: directory)
        let binding = try XCTUnwrap(ButtonBinding(enabled: true, buttonNumber: 3))
        let committed = PersistedConfiguration(enabled: false, direction: .reverse, amountPercent: 137, binding: binding)
        XCTAssertTrue(store.persist(committed))
        let runtime = InputRuntime(store: store)

        runtime.setEnabled(true)
        runtime.setDirection(.preserve)
        runtime.setAmountPercent(25)
        let updated = PersistedConfiguration(enabled: true, direction: .preserve, amountPercent: 25, binding: binding)
        XCTAssertEqual(runtime.configuration, updated)
        let bytes = try Data(contentsOf: store.url)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        runtime.setAmountPercent(137)
        XCTAssertEqual(runtime.configuration, updated)
        XCTAssertEqual(runtime.configurationAttention, .saveFailed)
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        runtime.setAmountPercent(137)
        let retried = PersistedConfiguration(enabled: true, direction: .preserve, amountPercent: 137, binding: binding)
        XCTAssertEqual(runtime.configuration, retried)
        XCTAssertEqual(store.load().0, retried)
    }

    func testFailedAmountWriteKeepsFileAndSnapshotAndAllowsRetry() throws {
        let store = ConfigurationStore(directory: directory)
        let committed = PersistedConfiguration(enabled: false, direction: .reverse, amountPercent: 137)
        XCTAssertTrue(store.persist(committed))
        let bytes = try Data(contentsOf: store.url)
        let runtime = InputRuntime(store: store)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        runtime.setAmountPercent(400)
        XCTAssertEqual(runtime.configuration, committed)
        XCTAssertEqual(runtime.configurationAttention, .saveFailed)
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        XCTAssertTrue(runtime.canEditConfiguration)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        runtime.setAmountPercent(400)
        XCTAssertEqual(runtime.configuration, .init(enabled: false, direction: .reverse, amountPercent: 400))
        XCTAssertEqual(store.load().0, runtime.configuration)
        XCTAssertEqual(runtime.configurationAttention, .none)
    }

    func testNewerSchemaAppearingAfterLoadBlocksAllTransactions() throws {
        let store = ConfigurationStore(directory: directory)
        let committed = PersistedConfiguration(enabled: false, direction: .reverse, amountPercent: 137)
        for version in ["4", "18446744073709551615"] {
            for operation in 0..<3 {
                try? FileManager.default.removeItem(at: store.url)
                XCTAssertTrue(store.persist(committed))
                let runtime = InputRuntime(store: store)
                let bytes = Data("{\"schema_version\":\(version),\"scroll\":\"future\"}".utf8)
                try bytes.write(to: store.url, options: .atomic)
                switch operation {
                case 0: runtime.setAmountPercent(400)
                case 1: runtime.setDirection(.preserve)
                default: runtime.setEnabled(true)
                }
                XCTAssertEqual(runtime.configuration, committed)
                XCTAssertEqual(runtime.configurationAttention, .newerSchema)
                XCTAssertTrue(runtime.hasCommittedConfiguration)
                XCTAssertEqual(runtime.state, .configurationNeedsAttention)
                XCTAssertFalse(runtime.canEditConfiguration)
                runtime.setAmountPercent(25)
                runtime.setDirection(.preserve)
                runtime.setEnabled(false)
                runtime.resetMalformedConfiguration()
                runtime.refresh()
                XCTAssertEqual(runtime.configuration, committed)
                XCTAssertEqual(try Data(contentsOf: store.url), bytes)
            }
        }
    }

    func testOversizedSchemaAppearingAfterLoadRefusesSaveAndReset() throws {
        let store = ConfigurationStore(directory: directory)
        let committed = PersistedConfiguration(enabled: false, direction: .reverse, amountPercent: 137)
        XCTAssertTrue(store.persist(committed))
        let runtime = InputRuntime(store: store)
        let bytes = Data(#"{"schema_version":18446744073709551616,"future":true}"#.utf8)
        try bytes.write(to: store.url)
        runtime.setAmountPercent(400)
        XCTAssertEqual(runtime.configuration, committed)
        XCTAssertEqual(runtime.configurationAttention, .newerSchema)
        XCTAssertFalse(runtime.canEditConfiguration)
        runtime.resetMalformedConfiguration()
        XCTAssertEqual(runtime.configuration, committed)
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
    }

    func testPreciseDecimalVersionAboveThreeRefusesSaveAndResetAfterLoad() throws {
        let store = ConfigurationStore(directory: directory)
        let committed = PersistedConfiguration(enabled: false, direction: .reverse, amountPercent: 137)
        for version in ["3.0000000000000000001", "3.0000000000000004", "1e200"] {
            try? FileManager.default.removeItem(at: store.url)
            XCTAssertTrue(store.persist(committed))
            let runtime = InputRuntime(store: store)
            let bytes = Data("{\"schema_version\":\(version),\"future\":true}".utf8)
            try bytes.write(to: store.url)
            runtime.setAmountPercent(400)
            XCTAssertEqual(runtime.configuration, committed)
            XCTAssertEqual(runtime.configurationAttention, .newerSchema)
            XCTAssertFalse(runtime.canEditConfiguration)
            runtime.resetMalformedConfiguration()
            XCTAssertEqual(runtime.configuration, committed)
            XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        }
    }

    func testResetCannotOverwriteNewerSchemaAppearingAfterMalformedLoad() throws {
        let store = ConfigurationStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: store.url)
        let runtime = InputRuntime(store: store)
        let bytes = Data(#"{"schema_version":4,"future":true}"#.utf8)
        try bytes.write(to: store.url)
        XCTAssertFalse(runtime.hasCommittedConfiguration)
        runtime.resetMalformedConfiguration()
        XCTAssertEqual(runtime.configuration, .default)
        XCTAssertFalse(runtime.hasCommittedConfiguration)
        XCTAssertEqual(runtime.configurationAttention, .newerSchema)
        XCTAssertFalse(runtime.canEditConfiguration)
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
    }

    func testMalformedReplacementBlocksNormalTransactionsButAllowsExplicitReset() throws {
        let store = ConfigurationStore(directory: directory)
        let committed = PersistedConfiguration(enabled: false, direction: .reverse, amountPercent: 137)
        for text in ["broken JSON", "{\"schema_version\":1" + String(repeating: "0", count: 166) + "}", #"{"schema_version":2}"#, #"{"schema_version":2,"scroll":{"enabled":1,"line_direction":"reverse","line_amount_percent":137}}"#, #"{"schema_version":2,"scroll":{"enabled":false,"line_direction":"reverse","line_amount_percent":401}}"#] {
            for operation in 0..<3 {
                try? FileManager.default.removeItem(at: store.url)
                XCTAssertTrue(store.persist(committed))
                let runtime = InputRuntime(store: store)
                let bytes = Data(text.utf8)
                try bytes.write(to: store.url)
                switch operation {
                case 0: runtime.setAmountPercent(400)
                case 1: runtime.setDirection(.preserve)
                default: runtime.setEnabled(true)
                }
                XCTAssertEqual(runtime.configuration, committed)
                XCTAssertEqual(runtime.configurationAttention, .malformed)
                XCTAssertTrue(runtime.hasCommittedConfiguration)
                XCTAssertFalse(runtime.canEditConfiguration)
                XCTAssertNotEqual(runtime.state, .active)
                XCTAssertEqual(try Data(contentsOf: store.url), bytes)
                runtime.resetMalformedConfiguration()
                XCTAssertEqual(runtime.configuration, .default)
                XCTAssertTrue(runtime.hasCommittedConfiguration)
                XCTAssertEqual(runtime.configurationAttention, .none)
                XCTAssertEqual(store.load().0, .default)
            }
        }
    }

    func testStateResolutionContract() {
        XCTAssertEqual(InputRuntimeState.resolve(enabled: false, accessibilityTrusted: true, runtimeStatus: .active, attention: .none), .off)
        XCTAssertEqual(InputRuntimeState.resolve(enabled: false, accessibilityTrusted: false, runtimeStatus: .unavailable, attention: .none), .off)
        XCTAssertEqual(InputRuntimeState.resolve(enabled: true, accessibilityTrusted: false, runtimeStatus: .active, attention: .none), .needsAccessibilityAccess)
        XCTAssertEqual(InputRuntimeState.resolve(enabled: true, accessibilityTrusted: false, runtimeStatus: .unavailable, attention: .none), .needsAccessibilityAccess)
        XCTAssertEqual(InputRuntimeState.resolve(enabled: true, accessibilityTrusted: true, runtimeStatus: .active, attention: .none), .active)
        XCTAssertEqual(InputRuntimeState.resolve(enabled: true, accessibilityTrusted: true, runtimeStatus: .unavailable, attention: .none), .inputUnavailable)
    }

    func testEnablingPublishesTruthfulNonActiveStateSynchronously() {
        let runtime = runtime()
        runtime.setEnabled(true)
        XCTAssertNotEqual(runtime.state, .active)
        XCTAssertNotEqual(runtime.state, .off)
        runtime.setEnabled(false)
    }

    func testDisablePublishesOffWithoutApprovalFromLifecycleExecutor() {
        let runtime = runtime()
        runtime.setEnabled(true)
        runtime.setEnabled(false)
        XCTAssertEqual(runtime.state, .off)

        runtime.refresh()
        XCTAssertEqual(runtime.state, .off)
    }

    func testFailedSaveKeepsCommittedEnabledDirectionThroughRefresh() throws {
        let store = ConfigurationStore(directory: directory)
        let committed = PersistedConfiguration(enabled: true, direction: .reverse)
        XCTAssertTrue(store.persist(committed))
        let runtime = InputRuntime(store: store)
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: true)

        runtime.setDirection(.preserve)
        runtime.refresh()

        XCTAssertEqual(runtime.configuration, committed)
        XCTAssertEqual(runtime.configurationAttention, .saveFailed)
        XCTAssertNotEqual(runtime.state, .off)
        XCTAssertNotEqual(runtime.state, .configurationNeedsAttention)
        XCTAssertTrue(runtime.canEditConfiguration)
        XCTAssertFalse(runtime.migrationFailed)

        try FileManager.default.removeItem(at: store.url)
        XCTAssertTrue(store.persist(committed))
        runtime.setDirection(.preserve)
        XCTAssertEqual(runtime.configuration, .init(enabled: true, direction: .preserve))
        XCTAssertEqual(runtime.configurationAttention, .none)
        XCTAssertEqual(store.load().0, runtime.configuration)
    }

    func testReleasingRuntimeDoesNotBlockOrPoisonSubsequentRuntimes() {
        var retiring: InputRuntime? = runtime()
        retiring?.setEnabled(true)
        retiring = nil

        let replacement = runtime()
        replacement.setEnabled(true)
        XCTAssertNotEqual(replacement.state, .active)
        replacement.setEnabled(false)
        XCTAssertEqual(replacement.state, .off)
    }
}
