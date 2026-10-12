import json
import os
import pathlib
import subprocess
import tempfile
import shutil
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class RuntimeTraceBundleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(["cargo", "build", "-p", "pointer-input-ffi", "--locked"], cwd=ROOT, check=True)

    def test_app_orderly_termination_flushes_trace_without_changing_configuration(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            build_env = {**os.environ, "MMF_FFI_PROFILE": "debug"}
            subprocess.run(["swift", "build", "--product", "mousemeld", "--package-path", "macos"], cwd=ROOT, env=build_env, check=True, capture_output=True)
            binary_path = subprocess.check_output(["swift", "build", "--show-bin-path", "--package-path", "macos"], cwd=ROOT, env=build_env, text=True).strip()
            binary = pathlib.Path(binary_path) / "mousemeld"
            library = root / "quit.dylib"
            subprocess.run(["cc", "-dynamiclib", "-fobjc-arc", str(ROOT / "tests/fixtures/application_quit.m"), "-framework", "AppKit", "-o", str(library)], check=True, capture_output=True)
            helper = root / "terminate.swift"
            helper.write_text('import AppKit\nlet pid = pid_t(CommandLine.arguments[1])!\nlet deadline = Date().addingTimeInterval(5)\nvar running = NSRunningApplication(processIdentifier: pid)\nwhile running == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)); running = NSRunningApplication(processIdentifier: pid) }\nguard let app = running else { fputs("application PID registration deadline\\n", stderr); exit(1) }\nlet actual = app.executableURL?.path ?? "nil"\nguard actual == CommandLine.arguments[2] else { fputs("executable mismatch: \\(actual)\\n", stderr); exit(1) }\nwhile !app.isFinishedLaunching && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }\nguard app.isFinishedLaunching else { fputs("launch readiness deadline\\n", stderr); exit(2) }\nlet accepted = app.terminate()\nprint("termination request accepted: \\(accepted)")\nif !accepted && CommandLine.arguments.count < 4 { exit(1) }\n')
            terminator = root / "terminate"
            subprocess.run(["swiftc", str(helper), "-o", str(terminator)], check=True, capture_output=True)
            stall_library = root / "stall.dylib"
            subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-dynamiclib", str(ROOT / "tests/fixtures/configuration_trace_platform.c"), "-framework", "ApplicationServices", "-o", str(stall_library)], check=True, capture_output=True)
            for mode in ("app-action", "external", "stalled-external", "active-external"):
                with self.subTest(mode=mode):
                    home = root / mode
                    config = home / "Library/Application Support/MouseMeld/configuration.json"
                    config.parent.mkdir(parents=True)
                    original = b'{"schema_version":3,"scroll":{"enabled":false,"line_direction":"preserve","line_amount_percent":157}}\n'
                    if mode == "active-external":
                        original = b'{"schema_version":3,"scroll":{"enabled":true,"line_direction":"reverse","line_amount_percent":137}}\n'
                    config.write_bytes(original)
                    traces = home / "traces"
                    env = {**build_env, "HOME": str(home), "CFFIXED_USER_HOME": str(home), "MMF_TRACE": "1", "MMF_TRACE_DIR": str(traces)}
                    for key in list(env):
                        if key.startswith("DYLD_") or key.startswith("MMF_TEST"):
                            del env[key]
                    if mode == "app-action":
                        env["DYLD_INSERT_LIBRARIES"] = str(library)
                    if mode == "stalled-external":
                        env.update(DYLD_INSERT_LIBRARIES=str(stall_library), MMF_TEST_TRACE_STALL="1", MMF_TEST_TRACE_STALL_STARTED=str(home / "started"), MMF_TEST_TRACE_STALL_RELEASE=str(home / "release"))
                    if mode == "active-external":
                        env.update(DYLD_INSERT_LIBRARIES=str(stall_library), MMF_TEST_TAP_TEARDOWN=str(home / "tap-teardown.txt"))
                    process = subprocess.Popen([str(binary)], cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    try:
                        if mode == "stalled-external":
                            deadline = time.monotonic() + 10
                            while not (home / "started").exists() and time.monotonic() < deadline:
                                self.assertIsNone(process.poll())
                                time.sleep(0.01)
                            self.assertTrue((home / "started").exists(), "existing trace write stall marker")
                            result = subprocess.run([str(terminator), str(process.pid), str(binary), "allow-cancel"], capture_output=True, text=True, timeout=10)
                            self.assertEqual(result.returncode, 0, result.stderr)
                            with self.assertRaises(subprocess.TimeoutExpired):
                                process.communicate(timeout=6)
                            self.assertIsNone(process.poll(), "deadline must cancel quit, not exit before drain")
                            (home / "release").touch()
                            deadline = time.monotonic() + 10
                            while time.monotonic() < deadline:
                                manifests = list(traces.glob("*/manifest.json"))
                                if manifests and json.loads(manifests[0].read_text())["clean_shutdown"]:
                                    break
                                self.assertIsNone(process.poll(), "cancelled quit must remain cancelled after drain")
                                time.sleep(0.01)
                            self.assertTrue(json.loads(manifests[0].read_text())["clean_shutdown"])
                            result = subprocess.run([str(terminator), str(process.pid), str(binary)], capture_output=True, text=True, timeout=10)
                            self.assertEqual(result.returncode, 0, result.stderr)
                        if mode in ("external", "active-external"):
                            def activated(records):
                                if mode == "external":
                                    return any(record.get("result_code") == "disabled" for record in records)
                                return any(record.get("result_code") == "active" for record in records) and any(record["name"] == "input.pipeline" for record in records)
                            deadline = time.monotonic() + 10
                            while time.monotonic() < deadline:
                                records = [json.loads(line) for segment in traces.glob("*/trace-*.jsonl") for line in segment.read_text().splitlines() if line.endswith("}")]
                                if activated(records):
                                    break
                                self.assertIsNone(process.poll(), "app exited before expected activation")
                                time.sleep(0.01)
                            self.assertTrue(activated(records), "expected activation/input deadline")
                            result = subprocess.run([str(terminator), str(process.pid), str(binary)], capture_output=True, text=True, timeout=10)
                            self.assertEqual(result.returncode, 0, result.stderr)
                        stdout, stderr = process.communicate(timeout=10)
                    finally:
                        if process.poll() is None:
                            process.kill()
                            process.communicate()
                    self.assertEqual(process.returncode, 0, stdout + stderr)
                    self.assertEqual(config.read_bytes(), original)
                    manifests = list(traces.glob("*/manifest.json"))
                    self.assertEqual(len(manifests), 1)
                    manifest = json.loads(manifests[0].read_text())
                    self.assertTrue(manifest["clean_shutdown"])
                    self.assertFalse(manifest["writer_failed"])
                    self.assertEqual(manifest["drop_count"], 0)
                    records = [json.loads(line) for segment in manifests[0].parent.glob("trace-*.jsonl") for line in segment.read_text().splitlines()]
                    self.assertEqual(sum(record["name"] == "run.stop" for record in records), 1)
                    if mode == "active-external":
                        self.assertTrue(any(record["name"] == "input.pipeline" for record in records))
                        self.assertEqual((home / "tap-teardown.txt").read_text(), "disabled active=0 timer=0\n")
                    else:
                        self.assertFalse(any(record["name"] == "input.pipeline" for record in records))
                    evidence = os.environ.get("MMF_TEST_CONFIGURATION_TRACE_EVIDENCE")
                    if evidence:
                        shutil.copytree(home, pathlib.Path(evidence) / ("termination-" + mode))

    def benchmark(self, trace_dir, trace):
        environment = {
            **os.environ,
            "MMF_FFI_PROFILE": "debug",
            "MMF_BENCHMARK_SYNTHETIC": "1",
            "MMF_TRACE_DIR": str(trace_dir),
            "MMF_BENCHMARK_EVENTS": "1000",
        }
        if trace is None:
            environment.pop("MMF_TRACE", None)
        else:
            environment["MMF_TRACE"] = trace
        return subprocess.run(
            ["swift", "run", "--package-path", "macos", "benchmark"],
            cwd=ROOT,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_smoke_lifecycle_and_unavailable_with_system_boundary_fixture(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            library = root / "platform.dylib"
            subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-dynamiclib", str(ROOT / "tests/fixtures/configuration_trace_platform.c"), "-framework", "ApplicationServices", "-o", str(library)], check=True)
            build_env = {**os.environ, "MMF_FFI_PROFILE": "debug"}
            subprocess.run(["swift", "build", "--product", "smoke", "--package-path", "macos"], cwd=ROOT, env=build_env, check=True, capture_output=True)
            binary_path = subprocess.check_output(["swift", "build", "--show-bin-path", "--package-path", "macos"], cwd=ROOT, env=build_env, text=True).strip()
            env = {**build_env, "DYLD_INSERT_LIBRARIES": str(library), "MMF_TRACE": "1", "MMF_TRACE_DIR": str(root / "traces"), "MMF_SMOKE_SECONDS": "0.05", "MMF_TEST_NATIVE_OUTPUT": str(root / "native.txt")}
            result = subprocess.run([str(pathlib.Path(binary_path) / "smoke")], cwd=ROOT, env=env, text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("start: stopped/unavailable; tapDisabledByTimeout count: 0", result.stdout)
            self.assertIn("restart: stopped/unavailable; tapDisabledByTimeout count: 0", result.stdout)
            self.assertIn("Synthetic gestures are not physical proof", result.stdout)
            native = (root / "native.txt").read_text().splitlines()
            self.assertGreaterEqual(len(native), 2)
            self.assertEqual(set(native), {"-13700 -13700"})
            manifests = list((root / "traces").glob("*/manifest.json"))
            self.assertEqual(len(manifests), 2)
            for path in manifests:
                manifest = json.loads(path.read_text())
                self.assertTrue(manifest["clean_shutdown"])
                self.assertFalse(manifest["writer_failed"])
                self.assertEqual(manifest["drop_count"], 0)
                records = [json.loads(line) for segment in path.parent.glob("trace-*.jsonl") for line in segment.read_text().splitlines()]
                self.assertTrue(any(r["name"] == "input.pipeline" and r["native_outcome"] == "applied" for r in records))
                self.assertFalse(any(r["name"] == "tap.timeout" for r in records))
            failure = subprocess.run([str(pathlib.Path(binary_path) / "smoke")], cwd=ROOT, env={**env, "MMF_TEST_TAP_FAILURE": "1"}, text=True, capture_output=True, timeout=15)
            self.assertNotEqual(failure.returncode, 0)
            self.assertIn("CGEventTap startup unavailable", failure.stderr)
            for invalid in ("0", "61", "nan", "inf", "bad"):
                result = subprocess.run([str(pathlib.Path(binary_path) / "smoke")], cwd=ROOT, env={**env, "MMF_SMOKE_SECONDS": invalid}, text=True, capture_output=True, timeout=15)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("MMF_SMOKE_SECONDS must be finite", result.stderr)

    def test_configuration_activation_input_and_backoff_export(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            library = root / "platform.dylib"
            subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-dynamiclib", str(ROOT / "tests/fixtures/configuration_trace_platform.c"), "-framework", "ApplicationServices", "-o", str(library)], check=True)
            subprocess.run(["swift", "build", "--build-tests", "--package-path", "macos"], cwd=ROOT, env={**os.environ, "MMF_FFI_PROFILE": "debug"}, check=True, capture_output=True)
            binary_path = subprocess.check_output(["swift", "build", "--show-bin-path", "--package-path", "macos"], cwd=ROOT, text=True).strip()
            binary = pathlib.Path(binary_path) / "MouseMeldPackageTests.xctest/Contents/MacOS/MouseMeldPackageTests"
            for failure, untrusted in [(False, False), (True, False), (False, True)]:
                fixture = root / ("untrusted" if untrusted else "backoff" if failure else "active")
                fixture.mkdir()
                env = {**os.environ, "DYLD_INSERT_LIBRARIES": str(library), "MMF_TEST_CONFIGURATION_TRACE_ROOT": str(fixture), "MMF_TEST_NATIVE_OUTPUT": str(fixture / "native.txt"), "MMF_TRACE": "0"}
                if failure:
                    env["MMF_TEST_TAP_FAILURE"] = "1"
                if untrusted:
                    env["MMF_TEST_UNTRUSTED"] = "1"
                result = subprocess.run([str(pathlib.Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip()) / "usr/bin/xctest"), "-XCTest", "PlatformTests.InputRuntimeTests/testProductionConfigurationActivationAndInputBundle", str(binary.parents[2])], env=env, cwd=ROOT, text=True, capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("Executed 1 test", result.stdout + result.stderr)
                manifests = list((fixture / "traces").glob("*/manifest.json"))
                self.assertEqual(len(manifests), 1)
                manifest = json.loads(manifests[0].read_text())
                self.assertTrue(manifest["clean_shutdown"])
                self.assertEqual(manifest["drop_count"], 0)
                run = manifests[0].parent
                export = fixture / "export"
                result = subprocess.run(["python3", str(ROOT / "scripts/trace.py"), "export", run.name, str(export)], env={**os.environ, "MMF_TRACE_DIR": str(fixture / "traces")}, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                evidence = os.environ.get("MMF_TEST_CONFIGURATION_TRACE_EVIDENCE")
                if evidence:
                    destination = pathlib.Path(evidence) / fixture.name
                    shutil.copytree(fixture, destination)
                records = sorted([json.loads(line) for path in export.glob("trace-*.jsonl") for line in path.read_text().splitlines()], key=lambda record: record["seq"])
                persisted = next(r for r in records if r.get("result_code") == "persisted")
                self.assertEqual((persisted["old_config_revision"], persisted["new_config_revision"], persisted["line_amount_percent"]), (0, 1, 25))
                activation = next(r for r in records if r["name"] == "config.activation" and r["operation_id"] == persisted["operation_id"])
                self.assertEqual(activation["result_code"], "unavailable" if failure or untrusted else "active")
                if failure or untrusted:
                    self.assertIsNone(activation["new_config_revision"])
                    self.assertFalse(any(r["name"] == "input.pipeline" for r in records))
                    if failure:
                        self.assertEqual((fixture / "native.txt").read_text(), "tap_creation_failed\n")
                    else:
                        self.assertFalse((fixture / "native.txt").exists())
                    continue
                loaded = next(r for r in records if r["name"] == "config.load")
                self.assertTrue(any(r["name"] == "config.activation" and r["operation_id"] == loaded["operation_id"] and r["new_config_revision"] == 0 for r in records))
                inputs = [r for r in records if r["name"] == "input.pipeline"]
                self.assertEqual({r["config_revision"] for r in inputs}, {0, 1})
                self.assertTrue(all(r["horizontal_lines"] == 100 and r["vertical_lines"] == 100 and r["native_outcome"] == "applied" for r in inputs))
                self.assertTrue(all((r["config_revision"] == 0 and r["scroll_amount_percent"] == 137 and r["line_direction"] == "reverse" and r["decision_horizontal_hundredths"] == -13_700 and r["decision_vertical_hundredths"] == -13_700 and r["reason_code"] == "nonneutral_amount_transform") or (r["config_revision"] == 1 and r["scroll_amount_percent"] == 25 and r["line_direction"] == "reverse" and r["decision_horizontal_hundredths"] == -2_500 and r["decision_vertical_hundredths"] == -2_500 and r["reason_code"] == "nonneutral_amount_transform") for r in inputs))
                native = [tuple(map(int, line.split())) for line in (fixture / "native.txt").read_text().splitlines()]
                self.assertEqual(len(native), len(inputs))
                self.assertEqual(native, [(-13700, -13700) if r["config_revision"] == 0 else (-2500, -2500) for r in inputs])
                failures = [r for r in records if r.get("result_code") in {"validation_rejected", "write_failed"}]
                self.assertEqual({r["result_code"] for r in failures}, {"validation_rejected", "write_failed"})
                for rejected in failures:
                    self.assertIsNone(rejected["new_config_revision"])
                    self.assertTrue(any(r["name"] == "config.rollback" and r["operation_id"] == rejected["operation_id"] and r["new_config_revision"] == 1 for r in records))
                self.assertEqual(inputs[-1]["config_revision"], 1)

    def test_stalled_trace_sink_drops_diagnostics_without_blocking_input(self):
        self.assert_stalled_trace_sink(False)

    def test_stalled_trace_sink_slow_drain_uses_parent_completion_bound(self):
        self.assert_stalled_trace_sink(False, slow_drain=True)

    def test_stalled_trace_sink_reports_early_callback_corruption(self):
        result = self.assert_stalled_trace_sink(True)
        self.assertEqual(result["summary"], "140000 139999\n")
        self.assertTrue(result["callbacks_done"])
        self.assertEqual(result["returncode"], 1)
        self.assertIn("140000 0", result["output"])

    def assert_stalled_trace_sink(self, corrupt, slow_drain=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            library = root / "platform.dylib"
            subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-dynamiclib", str(ROOT / "tests/fixtures/configuration_trace_platform.c"), "-framework", "ApplicationServices", "-o", str(library)], check=True)
            subprocess.run(["swift", "build", "--build-tests", "--package-path", "macos"], cwd=ROOT, env={**os.environ, "MMF_FFI_PROFILE": "debug"}, check=True, capture_output=True)
            binary_path = subprocess.check_output(["swift", "build", "--show-bin-path", "--package-path", "macos"], cwd=ROOT, text=True).strip()
            binary = pathlib.Path(binary_path) / "MouseMeldPackageTests.xctest/Contents/MacOS/MouseMeldPackageTests"
            fixture = root / "stall"; fixture.mkdir()
            paths = {name: fixture / name for name in ("started", "callbacks-done", "release", "summary")}
            env = {**os.environ, "DYLD_INSERT_LIBRARIES": str(library), "MMF_TEST_CONFIGURATION_TRACE_ROOT": str(fixture), "MMF_TEST_NATIVE_OUTPUT": str(fixture / "native.txt"), "MMF_TEST_TRACE_STALL": "1", "MMF_TEST_TRACE_STALL_STARTED": str(paths["started"]), "MMF_TEST_TRACE_STALL_CALLBACKS_DONE": str(paths["callbacks-done"]), "MMF_TEST_TRACE_STALL_RELEASE": str(paths["release"]), "MMF_TEST_TRACE_STALL_SUMMARY": str(paths["summary"]), "MMF_TRACE": "0", **({"MMF_TEST_TRACE_STALL_CORRUPT_EARLY": "1"} if corrupt else {})}
            if slow_drain:
                env["MMF_TEST_TRACE_SLOW_DRAIN"] = "1"
            command = [str(pathlib.Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip()) / "usr/bin/xctest"), "-XCTest", "PlatformTests.InputRuntimeTests/testProductionConfigurationActivationAndInputBundle", str(binary.parents[2])]
            process = subprocess.Popen(command, env=env, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            stdout = stderr = ""
            try:
                for _ in range(500):
                    if paths["callbacks-done"].exists(): break
                    self.assertIsNone(process.poll(), "callback path blocked by stalled diagnostic sink")
                    time.sleep(0.01)
                self.assertTrue(paths["started"].exists())
                self.assertTrue(paths["callbacks-done"].exists())
                summary = paths["summary"].read_text()
                paths["release"].touch()
                stdout, stderr = process.communicate(timeout=20)
            finally:
                if process.poll() is None:
                    process.kill()
                    stdout, stderr = process.communicate()
            manifests = list((fixture / "traces").glob("*/manifest.json"))
            manifest = json.loads(manifests[0].read_text()) if len(manifests) == 1 else None
            result = {"callbacks_done": paths["callbacks-done"].exists(), "summary": summary, "returncode": process.returncode, "output": stdout + stderr, "manifest": manifest}
            if not corrupt:
                self.assertEqual(result["summary"], "140000 0\n")
                self.assertEqual(result["returncode"], 0, result["output"])
                self.assertIsNotNone(result["manifest"])
                self.assertTrue(result["manifest"]["clean_shutdown"], result["output"])
                self.assertFalse(result["manifest"]["writer_failed"], result["output"])
                self.assertGreater(result["manifest"]["drop_count"], 0, result["output"])
            return result

    def test_runtime_benchmark_fails_when_requested_trace_cannot_start(self):
        for trace in ("1", None):
            with self.subTest(trace=trace):
                result = self.benchmark("/dev/null", trace)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("trace bundle failed clean shutdown", result.stderr)

    def test_runtime_benchmark_trace_off_and_on_bundle_contract(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            off = self.benchmark(root / "off", "0")
            self.assertEqual(off.returncode, 0, off.stderr)
            self.assertIn("workload events=1000 amount_updates=1000 amounts=25,100,137,400 directions=preserve,reverse axes=horizontal,vertical,multi,zero pixel_preserved", off.stdout)
            self.assertEqual(list((root / "off").glob("*/manifest.json")), [])

            on_root = root / "on"
            stale = on_root / "stale"
            stale.mkdir(parents=True)
            (stale / "manifest.json").write_text(json.dumps({"schema_version": 1, "run_id": "stale", "started_monotonic_ns": 0, "clean_shutdown": True, "drop_count": 0}))
            with (stale / "trace-0.jsonl").open("wb") as trace:
                trace.truncate(64 * 1024 * 1024 - 3_000)
            unrelated = on_root / "keep"
            unrelated.mkdir()
            (unrelated / "manifest.json").write_text(json.dumps({"schema_version": True, "run_id": "keep", "started_monotonic_ns": False, "clean_shutdown": 1, "drop_count": True, "writer_failed": 0}))
            on = self.benchmark(on_root, "1")
            self.assertEqual(on.returncode, 0, on.stderr)
            manifests = [path for path in on_root.glob("*/manifest.json") if path.parent != unrelated]
            self.assertEqual(len(manifests), 1)
            self.assertFalse(stale.exists())
            self.assertTrue(unrelated.exists())
            manifest = json.loads(manifests[0].read_text())
            self.assertGreaterEqual(manifest["started_monotonic_ns"], 0)
            self.assertRegex(manifest["run_start_utc"], r".+Z$")
            self.assertTrue(manifest["clean_shutdown"])
            self.assertFalse(manifest["writer_failed"])
            self.assertEqual(manifest["drop_count"], 0)
            self.assertIn("trace bundle clean: drop_count=0 writer_failed=false clean_shutdown=true", on.stdout)
            records = [json.loads(line) for path in manifests[0].parent.glob("trace-*.jsonl") for line in path.read_text().splitlines()]
            self.assertIn("run.start", [record["name"] for record in records])
            self.assertIn("run.stop", [record["name"] for record in records])
            self.assertIn("input.pipeline", [record["name"] for record in records])
            self.assertEqual(next(record for record in records if record["name"] == "run.start")["t_ns"], 0)
            self.assertTrue(all(record["t_ns"] >= 0 for record in records if "t_ns" in record))
            self.assertEqual(next(record for record in records if record["name"] == "input.pipeline")["level"], "trace")
            self.assertEqual(next(record for record in records if record["name"] == "input.pipeline")["component"], "native.input")
            self.assertTrue(all(record["seq"] > 0 and record["t_ns"] >= 0 for record in records))


if __name__ == "__main__":
    unittest.main()
