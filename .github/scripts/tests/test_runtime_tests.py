import importlib.util
import contextlib
import io
import os
import subprocess
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

    def test_workspace_suites_run_only_on_the_latest_ios_and_host_macos(self):
        installed = [runtime(version) for version in ("27.2", "18.6", "27.10", "27.9", "26.5")]
        jobs = runner.test_cases(installed, "27.1", "workspace", latest_ios_major=27)
        self.assertEqual(len(jobs), 2)
        self.assertEqual([(job["platform"], job["version"]) for job in jobs if job["suite"] == "workspace"],
                         [("iOS", "27.10"), ("macOS", "27.1")])
        self.assertEqual([job["version"] for job in jobs if job["suite"] == "native"],
                         [])

    def test_latest_runner_with_one_ios_runtime_keeps_full_coverage(self):
        jobs = runner.test_cases([runtime("27.0")], "27.0", "workspace", latest_ios_major=27)
        self.assertEqual([job["suite"] for job in jobs], ["workspace", "workspace"])


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

    def execute(self, suite, fail=None):
        def run(command, **options):
            self.commands.append((command, options))
            if fail:
                fail(command)
            return subprocess.CompletedProcess(command, 0)
        with patch.object(runner.subprocess, "run", side_effect=run):
            return runner.run_tests(self.runtimes, "27.0", self.root, suite, latest_ios_major=27)

    def test_workspace_runs_latest_only_and_excludes_low_level_suite(self):
        self.assertEqual(self.execute("workspace"), 0)
        commands = [command for command, _ in self.commands if "xcodebuild" in command]
        self.assertEqual(len(commands), 2)
        self.assertIn("-skip-testing:WebInspectorNativeBridgeTests", commands[0])
        self.assertIn("-only-testing:WebInspectorConsumerContractTests", commands[1])
        self.assertNotIn("-only-testing:WebInspectorNativeBridgeTests", commands[1])
        self.assertNotIn("18.6", self.summary.read_text())

    def test_test_failure_continues_with_remaining_runtimes_and_cleans_devices(self):
        def fail(command):
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

    def test_boot_timeout_cleans_device_and_does_not_block_later_tests(self):
        def fail(command):
            if command == ["xcrun", "simctl", "bootstatus", "first-device", "-b"]:
                raise subprocess.TimeoutExpired(command, 180)
        self.assertEqual(self.execute("native", fail), 1)
        commands = [command for command, _ in self.commands]
        self.assertIn(["xcrun", "simctl", "delete", "first-device"], commands)
        self.assertEqual(sum("xcodebuild" in command for command in commands), 2)
        self.assertIn("| iOS 27.0 / native | Passed |", self.summary.read_text())

    def test_cleanup_failure_is_reported_without_hiding_test_failure(self):
        def fail(command):
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
