import importlib.util
import json
import unittest
from pathlib import Path
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "runtime_matrix", Path(__file__).resolve().parents[1] / "ios-runtime-matrix.py"
)
matrix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(matrix)


def runtime(version, *, available=True, platform="iOS", identifier=None):
    return {
        "version": version,
        "identifier": identifier or f"com.apple.CoreSimulator.SimRuntime.{platform}-{version.replace('.', '-')}",
        "isAvailable": available,
    }


class RuntimeMatrixTests(unittest.TestCase):
    def test_resolution_creates_an_isolated_device_for_the_exact_runtime(self):
        installed = runtime("26.4.1", identifier="com.apple.CoreSimulator.SimRuntime.iOS-26-4")
        installed.update({
            "buildversion": "test-build",
            "supportedDeviceTypes": [
                {"identifier": "tablet", "productFamily": "iPad"},
                {"identifier": "phone", "productFamily": "iPhone"},
            ],
        })
        with patch.object(matrix, "simctl", side_effect=[json.dumps({"runtimes": [installed]}), "fresh-udid\n"]) as simctl, \
                patch.object(matrix, "append_environment") as append_environment:
            matrix.resolve_device(installed["identifier"])
        self.assertEqual(simctl.call_args_list[-1].args,
                         ("create", "WebInspectorKit CI", "phone", installed["identifier"]))
        append_environment.assert_called_once_with({
            "DESTINATION": "platform=iOS Simulator,id=fresh-udid",
            "RESOLVED_IOS_VERSION": "26.4.1",
            "WATCHDOG_SIMULATOR_UDID": "fresh-udid",
        })

    def test_every_supported_minor_and_patch_version_is_selected(self):
        installed = [runtime(version) for version in (
            "27.2", "18.6", "26.4.1", "18.4", "26.2", "27.0",
            "26.0", "26.0.1", "26.0.2", "26.1", "26.1.1",
        )]
        self.assertEqual(
            [item["version"] for item in matrix.supported_runtimes(installed)],
            ["18.4", "18.6", "26.1", "26.1.1", "26.2", "26.4.1", "27.0", "27.2"],
        )

    def test_deployment_floor_unavailable_runtimes_and_other_platforms(self):
        installed = [runtime("18.3.1"), runtime("18.4"), runtime("26.0", available=False),
                     runtime("26.0", platform="tvOS")]
        self.assertEqual(matrix.supported_runtimes(installed), [installed[1]])

    def test_runtime_identifier_is_preserved_when_version_contains_a_patch(self):
        installed = [runtime("26.4.1", identifier="com.apple.CoreSimulator.SimRuntime.iOS-26-4")]
        jobs = matrix.test_matrix(matrix.supported_runtimes(installed), "26.6.2")["include"]
        self.assertEqual(jobs[0], {"runtime": installed[0]["identifier"], "version": "26.4.1", "platform": "iOS"})

    def test_one_job_per_runtime_and_one_for_the_host_macos(self):
        jobs = matrix.test_matrix([runtime("18.5"), runtime("18.6")], "15.7")["include"]
        self.assertEqual(len(jobs), 3)
        self.assertEqual([job["version"] for job in jobs if job["platform"] == "iOS"], ["18.5", "18.6"])
        self.assertEqual(jobs[-1], {"runtime": "", "version": "15.7", "platform": "macOS"})


if __name__ == "__main__":
    unittest.main()
