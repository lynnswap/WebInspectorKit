import importlib.util
import unittest
from pathlib import Path


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
    def test_every_installed_minor_and_patch_version_is_selected(self):
        installed = [runtime(version) for version in ("27.2", "18.6", "26.4.1", "18.4", "26.2", "27.0")]
        self.assertEqual(
            [item["version"] for item in matrix.supported_runtimes(installed)],
            ["18.4", "18.6", "26.2", "26.4.1", "27.0", "27.2"],
        )

    def test_deployment_floor_unavailable_runtimes_and_other_platforms(self):
        installed = [runtime("18.3.1"), runtime("18.4"), runtime("26.0", available=False),
                     runtime("26.0", platform="tvOS")]
        self.assertEqual(matrix.supported_runtimes(installed), [installed[1]])

    def test_runtime_identifier_is_preserved_when_version_contains_a_patch(self):
        installed = [runtime("26.4.1", identifier="com.apple.CoreSimulator.SimRuntime.iOS-26-4")]
        jobs = matrix.test_matrix(matrix.supported_runtimes(installed), True)["include"]
        self.assertEqual(len(jobs), 5)
        self.assertEqual({job["runtime"] for job in jobs}, {installed[0]["identifier"]})
        self.assertEqual({job["version"] for job in jobs}, {"26.4.1"})
        self.assertIn("MonoclyTests", {job["test_filter"] for job in jobs})

    def test_native_bridge_runs_on_older_toolchain_for_each_runtime(self):
        jobs = matrix.test_matrix([runtime("18.5"), runtime("18.6")], False)["include"]
        self.assertEqual(len(jobs), 2)
        self.assertEqual({job["product"] for job in jobs}, {"native"})


if __name__ == "__main__":
    unittest.main()
