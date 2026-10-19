import importlib.util
import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "runtime_tests", Path(__file__).resolve().parents[1] / "runtime-tests.py"
)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def runtime(version, *, available=True, platform="iOS", identifier=None):
    return {
        "version": version,
        "identifier": identifier or f"com.apple.CoreSimulator.SimRuntime.{platform}-{version.replace('.', '-')}",
        "isAvailable": available,
    }


class RuntimeSelectionTests(unittest.TestCase):
    def test_resolution_creates_an_isolated_device_for_the_exact_runtime(self):
        installed = runtime("26.4.1", identifier="com.apple.CoreSimulator.SimRuntime.iOS-26-4")
        installed.update({
            "buildversion": "test-build",
            "supportedDeviceTypes": [
                {"identifier": "tablet", "productFamily": "iPad"},
                {"identifier": "phone", "productFamily": "iPhone"},
            ],
        })
        with patch.object(runner, "simctl", return_value="fresh-udid\n") as simctl:
            self.assertEqual(runner.create_device(installed), "fresh-udid")
        self.assertEqual(simctl.call_args_list[-1].args,
                         ("create", "WebInspectorKit CI", "phone", installed["identifier"]))

    def test_reuse_selects_only_an_available_shutdown_iphone_for_the_exact_runtime(self):
        installed = runtime("26.4.1")
        installed["supportedDeviceTypes"] = [
            {"identifier": "tablet", "productFamily": "iPad"},
            {"identifier": "phone", "productFamily": "iPhone"},
        ]
        devices = {
            runtime("26.4")["identifier"]: [
                {"udid": "wrong-runtime", "state": "Shutdown", "isAvailable": True,
                 "deviceTypeIdentifier": "phone"},
            ],
            installed["identifier"]: [
                {"udid": "running", "state": "Booted", "isAvailable": True,
                 "deviceTypeIdentifier": "phone"},
                {"udid": "unavailable", "state": "Shutdown", "isAvailable": False,
                 "deviceTypeIdentifier": "phone"},
                {"udid": "ipad", "state": "Shutdown", "isAvailable": True,
                 "deviceTypeIdentifier": "tablet"},
                {"udid": "borrowed", "state": "Shutdown", "isAvailable": True,
                 "deviceTypeIdentifier": "phone"},
            ],
        }
        self.assertEqual(runner.reusable_device(installed, devices), "borrowed")
        self.assertIsNone(runner.reusable_device(installed, {}))

    def test_inventory_preserves_supported_minor_and_patch_versions(self):
        installed = [runtime(version) for version in (
            "27.2", "18.6", "26.4.1", "18.4", "26.2", "27.0",
            "26.0", "26.0.1", "26.0.2", "26.1", "26.1.1",
        )]
        self.assertEqual(
            [item["version"] for item in runner.supported_runtimes(installed)],
            ["18.4", "18.6", "26.1", "26.1.1", "26.2", "26.4.1", "27.0", "27.2"],
        )

    def test_deployment_floor_unavailable_runtimes_and_other_platforms(self):
        installed = [runtime("18.3.1"), runtime("18.4"), runtime("26.0", available=False),
                     runtime("26.0", platform="tvOS")]
        self.assertEqual(runner.supported_runtimes(installed), [installed[1]])

    def test_runtime_identifier_is_preserved_when_version_contains_a_patch(self):
        installed = [runtime("26.4.1", identifier="com.apple.CoreSimulator.SimRuntime.iOS-26-4")]
        jobs = runner.test_cases(runner.supported_runtimes(installed), "26.6.2", "native", latest_ios_major=27)
        self.assertEqual(jobs[0], {"runtime": installed[0]["identifier"], "version": "26.4.1",
                                   "platform": "iOS", "suite": "native"})

    def test_native_keeps_all_newest_major_minors_and_latest_older_releases(self):
        installed = [runtime(version) for version in (
            "27.2", "18.4", "26.9", "27.0", "18.6", "26.10.1", "26.10.2", "27.10",
        )]
        jobs = runner.test_cases(installed, "26.6.2", "native", latest_ios_major=27)
        self.assertEqual([job["version"] for job in jobs if job["platform"] == "iOS"],
                         ["18.6", "26.10.2", "27.0", "27.2", "27.10"])
        self.assertEqual(jobs[-1], {"runtime": "", "version": "26.6.2", "platform": "macOS", "suite": "native"})
        self.assertTrue(all(job["suite"] == "native" for job in jobs))
        reversed_jobs = runner.test_cases(list(reversed(installed)), "26.6.2", "native", latest_ios_major=27)
        self.assertEqual(jobs, reversed_jobs)

    def test_older_host_does_not_treat_its_local_latest_major_as_current(self):
        installed = [runtime(version) for version in ("18.5", "18.6", "26.1", "26.4.1")]
        jobs = runner.test_cases(installed, "15.7", "native", latest_ios_major=27)
        self.assertEqual([job["version"] for job in jobs if job["platform"] == "iOS"],
                         ["18.6", "26.4.1"])

    def test_current_major_keeps_all_available_patch_runtimes(self):
        installed = [runtime(version) for version in ("27.1", "27.1.1", "27.2")]
        jobs = runner.test_cases(installed, "26.6.2", "native", latest_ios_major=27)
        self.assertEqual([job["version"] for job in jobs if job["platform"] == "iOS"],
                         ["27.1", "27.1.1", "27.2"])

    def test_advancing_the_shared_major_retires_previous_major_minors(self):
        installed = [runtime(version) for version in ("27.0", "27.2", "28.0", "28.1")]
        jobs = runner.test_cases(installed, "27.1", "native", latest_ios_major=28)
        self.assertEqual([job["version"] for job in jobs if job["platform"] == "iOS"],
                         ["27.2", "28.0", "28.1"])

    def test_release_validation_restores_all_supported_native_runtimes(self):
        installed = [runtime(version) for version in (
            "27.2", "18.3", "18.4", "18.6", "26.0.1", "26.1", "26.1.1", "26.5", "27.0",
        )] + [runtime("27.1", available=False), runtime("27.0", platform="tvOS")]
        jobs = runner.test_cases(runner.supported_runtimes(installed), "26.6.2", "native",
                                 latest_ios_major=27, all_native_runtimes=True)
        self.assertEqual([job["version"] for job in jobs if job["platform"] == "iOS"],
                         ["18.4", "18.6", "26.1", "26.1.1", "26.5", "27.0", "27.2"])
        self.assertEqual(jobs[-1], {"runtime": "", "version": "26.6.2", "platform": "macOS", "suite": "native"})

    def test_workspace_suites_run_only_on_the_latest_ios_and_host_macos(self):
        installed = [runtime(version) for version in ("27.2", "18.6", "27.10", "27.9", "26.5")]
        for full_coverage in (False, True):
            with self.subTest(all_native_runtimes=full_coverage):
                jobs = runner.test_cases(installed, "27.1", "workspace", latest_ios_major=27,
                                         all_native_runtimes=full_coverage)
                self.assertEqual(len(jobs), 2)
                self.assertEqual([(job["platform"], job["version"]) for job in jobs],
                                 [("iOS", "27.10"), ("macOS", "27.1")])
                self.assertTrue(all(job["suite"] == "workspace" for job in jobs))

    def test_latest_runner_with_one_ios_runtime_keeps_full_coverage(self):
        jobs = runner.test_cases([runtime("27.0")], "27.0", "workspace", latest_ios_major=27)
        self.assertEqual([job["suite"] for job in jobs], ["workspace", "workspace"])

    def test_platform_filter_preserves_every_selected_ios_runtime(self):
        installed = [runtime(version) for version in ("18.4", "18.6", "27.0", "27.1")]
        for suite in ("native", "workspace"):
            for full_coverage in (False, True):
                with self.subTest(suite=suite, all_native_runtimes=full_coverage):
                    cases = runner.test_cases(installed, "27.1", suite, latest_ios_major=27,
                                              all_native_runtimes=full_coverage)
                    ios = runner.test_cases(installed, "27.1", suite, latest_ios_major=27,
                                            all_native_runtimes=full_coverage, platform="iOS")
                    self.assertEqual(ios, [case for case in cases if case["platform"] == "iOS"])
        self.assertEqual(runner.test_cases([], "27.1", "workspace", 27, platform="macOS"),
                         [{"runtime": "", "version": "27.1", "platform": "macOS", "suite": "workspace"}])

class RuntimeExecutionTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        for platform in ("iOS", "macOS"):
            products = self.root / f"build-{platform}" / "Build/Products"
            products.mkdir(parents=True)
            (products / "tests.xctestrun").touch()
        self.runtimes = [runtime("18.6"), runtime("27.0")]
        for installed in self.runtimes:
            installed["supportedDeviceTypes"] = [{"identifier": "phone", "productFamily": "iPhone"}]
        self.commands = []
        self.output = io.StringIO()
        self.summary = self.root / "summary.md"
        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(contextlib.redirect_stdout(self.output))
        stack.enter_context(patch.dict(os.environ, GITHUB_STEP_SUMMARY=str(self.summary)))
        stack.enter_context(patch.object(runner, "simctl", side_effect=["first-device", "second-device"]))

    def execute(self, suite, fail=None, *, all_native_runtimes=False, platform=None,
                reuse_simulators=False):
        def run(command, **options):
            self.commands.append((command, options))
            if fail:
                fail(command, **options)
            return subprocess.CompletedProcess(command, 0)
        with patch.object(runner.subprocess, "run", side_effect=run):
            return runner.run_tests(self.runtimes, "27.0", self.root, suite, latest_ios_major=27,
                                    all_native_runtimes=all_native_runtimes, platform=platform,
                                    reuse_simulators=reuse_simulators)

    def test_workspace_runs_latest_only_and_excludes_low_level_suite(self):
        def require_existing_result_stream(command, **options):
            if "xcodebuild" in command:
                self.assertIn("-verbose", command)
                self.assertTrue(Path(command[command.index("-resultStreamPath") + 1]).is_file())
        self.assertEqual(self.execute("workspace", require_existing_result_stream), 0)
        commands = [command for command, _ in self.commands if "xcodebuild" in command]
        self.assertEqual(len(commands), 2)
        self.assertIn("-skip-testing:WebInspectorNativeBridgeTests", commands[0])
        self.assertIn("-only-testing:WebInspectorConsumerContractTests", commands[1])
        self.assertNotIn("-only-testing:WebInspectorNativeBridgeTests", commands[1])
        self.assertNotIn("18.6", self.summary.read_text())

    def test_release_validation_runs_older_minors_and_cleans_each_device(self):
        older = runtime("18.4")
        older["supportedDeviceTypes"] = [{"identifier": "phone", "productFamily": "iPhone"}]
        self.runtimes.insert(0, older)
        with patch.object(runner, "simctl", side_effect=["older-device", "first-device", "second-device"]):
            self.assertEqual(self.execute("native", all_native_runtimes=True), 0)
        commands = [command for command, _ in self.commands]
        tests = [command for command in commands if "xcodebuild" in command]
        self.assertEqual(len(tests), 4)
        self.assertTrue(all("-only-testing:WebInspectorNativeBridgeTests" in command for command in tests))
        for device in ("older-device", "first-device", "second-device"):
            self.assertIn(["xcrun", "simctl", "delete", device], commands)
        self.assertIn("| iOS 18.4 / native | Passed |", self.summary.read_text())
        self.assertIn("| iOS 18.6 / native | Passed |", self.summary.read_text())

    def test_command_line_passes_platform_and_full_native_coverage_to_execution(self):
        arguments = ["runtime-tests.py", str(self.root), "--suite", "native",
                     "--latest-ios-major", "27", "--all-native-runtimes", "--platform", "iOS"]
        with patch.object(sys, "argv", arguments), \
                patch.object(runner, "simctl", return_value=json.dumps({"runtimes": self.runtimes})), \
                patch.object(runner.subprocess, "check_output", return_value="27.0\n"), \
                patch.object(runner, "run_tests", return_value=0) as execute:
            self.assertEqual(runner.main(), 0)
        execute.assert_called_once_with(self.runtimes, "27.0", self.root, "native", 27,
                                        all_native_runtimes=True, platform="iOS", reuse_simulators=False)

    def test_prepare_starts_only_the_first_runtime_selected_by_the_test_policy(self):
        older = dict(self.runtimes[0], version="18.4", identifier=runtime("18.4")["identifier"])
        installed = [older, *self.runtimes]
        for suite, full_coverage, expected in (("native", False, "18.6"),
                                                ("native", True, "18.4"),
                                                ("workspace", False, "27.0")):
            with self.subTest(suite=suite, full_coverage=full_coverage):
                def start(command, path, **options):
                    state = json.loads(runner.simulator_state_path(self.root).read_text())
                    self.assertEqual(state, {"udid": "prepared-device", "runtime": runtime(expected)["identifier"],
                                             "created": True})
                    self.assertEqual(command, ["xcrun", "simctl", "boot", "prepared-device"])
                with patch.object(runner, "create_device", return_value="prepared-device") as create, \
                        patch.object(runner, "run_logged", side_effect=start) as start_boot:
                    self.assertEqual(runner.prepare_simulator(
                        installed, self.root, suite, 27, all_native_runtimes=full_coverage), 0)
                self.assertEqual(create.call_args.args[0]["version"], expected)
                start_boot.assert_called_once()
                runner.simulator_state_path(self.root).unlink()

    def test_prepared_borrowed_device_is_joined_and_cleaned_using_the_same_udid(self):
        installed = self.runtimes[-1]
        borrowed = {"udid": "borrowed", "state": "Shutdown", "isAvailable": True,
                    "deviceTypeIdentifier": "phone"}
        unrelated = dict(borrowed, udid="unrelated", state="Booted")
        before = json.dumps({"devices": {installed["identifier"]: [unrelated, borrowed]}})
        after = json.dumps({"devices": {installed["identifier"]: [unrelated, dict(borrowed, state="Booted")]}})
        with patch.object(runner, "simctl", side_effect=[before, after]) as simctl, \
                patch.object(runner.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as prepare:
            self.assertEqual(runner.prepare_simulator(
                self.runtimes, self.root, "workspace", 27, reuse_simulators=True), 0)
            self.assertEqual(self.execute("workspace", platform="iOS", reuse_simulators=True), 0)
        self.assertEqual(prepare.call_args.args[0], ["xcrun", "simctl", "boot", "borrowed"])
        commands = [command for command, _ in self.commands]
        self.assertIn(["xcrun", "simctl", "bootstatus", "borrowed", "-b"], commands)
        self.assertIn(["xcrun", "simctl", "shutdown", "borrowed"], commands)
        self.assertFalse(any("unrelated" in str(command) or "delete" in command for command in commands))
        self.assertEqual(simctl.call_count, 2)
        self.assertFalse(runner.simulator_state_path(self.root).exists())
        test = next(command for command in commands if "xcodebuild" in command)
        self.assertIn("platform=iOS Simulator,id=borrowed", test)

    def test_cleanup_command_recovers_ownership_when_tests_are_skipped_or_prepare_fails(self):
        arguments = ["runtime-tests.py", str(self.root), "--suite", "native",
                     "--latest-ios-major", "27", "--platform", "iOS"]
        for boot_fails in (False, True):
            with self.subTest(boot_fails=boot_fails):
                commands = []
                def run(command, path, **options):
                    commands.append(command)
                    self.assertTrue(runner.simulator_state_path(self.root).exists())
                    if boot_fails and command[2] == "boot":
                        raise subprocess.CalledProcessError(1, command)
                with patch.object(runner, "create_device", return_value="owned-device"), \
                        patch.object(runner, "run_logged", side_effect=run), \
                        patch.object(runner, "simctl", return_value=json.dumps({"runtimes": self.runtimes})) as simctl, \
                        patch.object(runner.subprocess, "check_output") as host_version:
                    with patch.object(sys, "argv", [*arguments, "--prepare-simulator"]):
                        self.assertEqual(runner.main(), int(boot_fails))
                    self.assertTrue(runner.simulator_state_path(self.root).exists())
                    simctl.assert_called_once_with("list", "runtimes", "--json")
                    simctl.reset_mock()
                    with patch.object(sys, "argv", [*arguments, "--cleanup-simulator"]):
                        self.assertEqual(runner.main(), 0)
                        self.assertEqual(runner.main(), 0)
                    simctl.assert_not_called()
                    host_version.assert_not_called()
                self.assertEqual(commands, [["xcrun", "simctl", "boot", "owned-device"],
                                            ["xcrun", "simctl", "delete", "owned-device"]])
                self.assertFalse(runner.simulator_state_path(self.root).exists())

    def test_failed_prepared_cleanup_retains_ownership_for_workflow_cleanup(self):
        with patch.object(runner, "create_device", return_value="owned-device"), \
                patch.object(runner, "run_logged"):
            self.assertEqual(runner.prepare_simulator(self.runtimes, self.root, "workspace", 27), 0)
        def fail_cleanup(command, **options):
            if command == ["xcrun", "simctl", "delete", "owned-device"]:
                raise subprocess.TimeoutExpired(command, 30)
        self.assertEqual(self.execute("workspace", fail_cleanup, platform="iOS"), 1)
        self.assertTrue(runner.simulator_state_path(self.root).exists())
        with patch.object(runner, "run_logged") as cleanup:
            self.assertEqual(runner.cleanup_prepared_simulator(self.root), 0)
        self.assertEqual(cleanup.call_args.args[0], ["xcrun", "simctl", "delete", "owned-device"])
        self.assertFalse(runner.simulator_state_path(self.root).exists())

    def test_macos_command_line_does_not_require_or_access_simulators(self):
        arguments = ["runtime-tests.py", str(self.root), "--suite", "native",
                     "--latest-ios-major", "27", "--platform", "macOS", "--reuse-simulators"]
        with patch.object(sys, "argv", arguments), \
                patch.object(runner, "simctl") as simctl, \
                patch.object(runner.subprocess, "check_output", return_value="27.0\n"), \
                patch.object(runner, "run_tests", return_value=0) as execute:
            self.assertEqual(runner.main(), 0)
        simctl.assert_not_called()
        execute.assert_called_once_with([], "27.0", self.root, "native", 27,
                                        all_native_runtimes=False, platform="macOS", reuse_simulators=True)

    def test_reused_device_is_shut_down_without_being_deleted(self):
        device = {"udid": "borrowed", "state": "Shutdown", "isAvailable": True,
                  "deviceTypeIdentifier": "phone"}
        installed = self.runtimes[-1]
        before = json.dumps({"devices": {installed["identifier"]: [device]}})
        after = json.dumps({"devices": {installed["identifier"]: [dict(device, state="Booted")]}})
        with patch.object(runner, "simctl", side_effect=[before, after]) as simctl:
            self.assertEqual(self.execute("workspace", platform="iOS", reuse_simulators=True), 0)
        commands = [command for command, _ in self.commands]
        self.assertIn(["xcrun", "simctl", "shutdown", "borrowed"], commands)
        self.assertFalse(any("delete" in command for command in commands))
        tests = [command for command in commands if "xcodebuild" in command]
        self.assertEqual(len(tests), 1)
        self.assertIn("platform=iOS Simulator,id=borrowed", tests[0])
        self.assertTrue(all(call.args == ("list", "devices", "available", "--json")
                            for call in simctl.call_args_list))

    def test_reuse_falls_back_to_creation_without_touching_a_running_device(self):
        installed = self.runtimes[-1]
        devices = json.dumps({"devices": {installed["identifier"]: [
            {"udid": "unrelated", "state": "Booted", "isAvailable": True,
             "deviceTypeIdentifier": "phone"},
        ]}})
        with patch.object(runner, "simctl", side_effect=[devices, "fresh-device\n"]):
            self.assertEqual(self.execute("workspace", platform="iOS", reuse_simulators=True), 0)
        commands = [command for command, _ in self.commands]
        self.assertIn(["xcrun", "simctl", "delete", "fresh-device"], commands)
        self.assertFalse(any("unrelated" in str(command) for command in commands))
        self.assertFalse(any("shutdown" in command for command in commands))

    def test_borrowed_boot_failure_still_cleans_up_and_runs_remaining_platform(self):
        installed = self.runtimes[-1]
        device = {"udid": "borrowed", "state": "Shutdown", "isAvailable": True,
                  "deviceTypeIdentifier": "phone"}
        before = json.dumps({"devices": {installed["identifier"]: [device]}})
        after = json.dumps({"devices": {installed["identifier"]: [dict(device, state="Booting")]}})
        def fail(command, **options):
            if command == ["xcrun", "simctl", "bootstatus", "borrowed", "-b"]:
                raise subprocess.TimeoutExpired(command, options["timeout"])
        with patch.object(runner, "simctl", side_effect=[before, after]):
            self.assertEqual(self.execute("workspace", fail, reuse_simulators=True), 1)
        commands = [command for command, _ in self.commands]
        self.assertIn(["xcrun", "simctl", "shutdown", "borrowed"], commands)
        self.assertEqual(sum("xcodebuild" in command for command in commands), 1)
        self.assertIn("| iOS 27.0 / workspace | Failed |", self.summary.read_text())
        self.assertIn("| macOS 27.0 / workspace | Passed |", self.summary.read_text())

    def test_watchdog_shutdown_does_not_cause_a_second_cleanup_failure(self):
        installed = self.runtimes[-1]
        devices = json.dumps({"devices": {installed["identifier"]: [
            {"udid": "borrowed", "state": "Shutdown", "isAvailable": True,
             "deviceTypeIdentifier": "phone"},
        ]}})
        def fail(command, **options):
            if "xcodebuild" in command:
                raise subprocess.CalledProcessError(70, command)
        with patch.object(runner, "simctl", side_effect=[devices, devices]):
            self.assertEqual(self.execute("workspace", fail, platform="iOS", reuse_simulators=True), 1)
        self.assertFalse(any("shutdown" in command for command, _ in self.commands))
        self.assertNotIn("cleanup:", self.output.getvalue())

    def test_test_failure_continues_with_remaining_runtimes_and_cleans_devices(self):
        def fail(command, **options):
            if "platform=iOS Simulator,id=first-device" in command:
                raise subprocess.CalledProcessError(65, command)
        self.assertEqual(self.execute("native", fail), 1)
        commands = [command for command, _ in self.commands]
        tests = [command for command in commands if "xcodebuild" in command]
        self.assertEqual(len(tests), 3)
        self.assertTrue(all("-only-testing:WebInspectorNativeBridgeTests" in command for command in tests))
        self.assertLess(commands.index(["xcrun", "simctl", "delete", "first-device"]), commands.index(tests[1]))
        self.assertLess(commands.index(["xcrun", "simctl", "delete", "second-device"]), commands.index(tests[2]))
        self.assertIn("| iOS 18.6 / native | Failed |", self.summary.read_text())
        self.assertIn("| macOS 27.0 / native | Passed |", self.summary.read_text())
        paths = [command[command.index("-resultBundlePath") + 1] for command in tests]
        self.assertEqual(len(set(paths)), 3)
        environments = [options["env"]["WATCHDOG_SIMULATOR_UDID"]
                        for command, options in self.commands if "xcodebuild" in command]
        self.assertEqual(environments, ["first-device", "second-device", ""])
        diagnostics = [options["env"]["WATCHDOG_DIAGNOSTICS_DIR"]
                       for command, options in self.commands if "xcodebuild" in command]
        self.assertEqual(diagnostics, [str(self.root / "runtime-tests" / case / "startup")
                                      for case in ("iOS-18.6", "iOS-27.0", "macOS-27.0")])

    def test_slow_initial_migration_still_runs_tests_and_cleans_devices(self):
        def slow_boot(command, **options):
            if command[:3] == ["xcrun", "simctl", "bootstatus"]:
                if options["timeout"] < 240:
                    raise subprocess.TimeoutExpired(command, options["timeout"])
        self.assertEqual(self.execute("native", slow_boot), 0)
        commands = [command for command, _ in self.commands]
        self.assertEqual(sum("xcodebuild" in command for command in commands), 3)
        for device in ("first-device", "second-device"):
            self.assertIn(["xcrun", "simctl", "delete", device], commands)
        self.assertIn("| iOS 18.6 / native | Passed |", self.summary.read_text())
        self.assertIn("| iOS 27.0 / native | Passed |", self.summary.read_text())

    def test_boot_timeout_cleans_device_and_does_not_block_later_tests(self):
        def fail(command, **options):
            if command == ["xcrun", "simctl", "bootstatus", "first-device", "-b"]:
                self.assertLessEqual(options["timeout"], 300)
                raise subprocess.TimeoutExpired(command, options["timeout"])
        self.assertEqual(self.execute("native", fail), 1)
        commands = [command for command, _ in self.commands]
        self.assertIn(["xcrun", "simctl", "delete", "first-device"], commands)
        self.assertEqual(sum("xcodebuild" in command for command in commands), 2)
        self.assertIn("| iOS 18.6 / native | Failed |", self.summary.read_text())
        self.assertIn("| iOS 27.0 / native | Passed |", self.summary.read_text())

    def test_cleanup_failure_is_reported_without_hiding_test_failure(self):
        def fail(command, **options):
            if "platform=iOS Simulator,id=first-device" in command:
                raise subprocess.CalledProcessError(65, command)
            if command == ["xcrun", "simctl", "delete", "first-device"]:
                raise subprocess.TimeoutExpired(command, 30)
        self.assertEqual(self.execute("native", fail), 1)
        self.assertIn("::error::iOS 18.6 / native:", self.output.getvalue())
        self.assertIn("::error::iOS 18.6 / native cleanup:", self.output.getvalue())
        self.assertEqual(sum("xcodebuild" in command for command, _ in self.commands), 3)


if __name__ == "__main__":
    unittest.main()
