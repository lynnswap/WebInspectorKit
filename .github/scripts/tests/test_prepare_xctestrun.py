import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path


spec = importlib.util.spec_from_file_location(
    "prepare_xctestrun", Path(__file__).resolve().parents[1] / "prepare-xctestrun.py"
)
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class PrepareTestRunTests(unittest.TestCase):
    def test_enables_smoke_tests_in_scheme_and_test_plan_formats(self):
        for uses_test_plan in (False, True):
            with self.subTest(uses_test_plan=uses_test_plan), tempfile.TemporaryDirectory() as temporary:
                products = Path(temporary)
                target = {"TestBundlePath": "__TESTROOT__/Debug-iphonesimulator/Native.xctest",
                          "EnvironmentVariables": {"EXISTING": "preserved"}}
                data = ({"TestConfigurations": [{"TestTargets": [target]}]}
                        if uses_test_plan else {"Native": target})
                path = products / "Native.xctestrun"
                path.write_bytes(plistlib.dumps(data))
                self.assertEqual(prepare.prepare(products, "native"), path)
                updated = plistlib.loads(path.read_bytes())
                updated_target = (updated["TestConfigurations"][0]["TestTargets"][0]
                                  if uses_test_plan else updated["Native"])
                self.assertEqual(updated_target["EnvironmentVariables"], {
                    "EXISTING": "preserved", "WEBINSPECTORKIT_RUN_NATIVE_RUNTIME_SMOKE": "1"
                })
                self.assertEqual(updated_target["TestBundlePath"], target["TestBundlePath"])

    def test_workspace_plan_remains_unchanged(self):
        with tempfile.TemporaryDirectory() as temporary:
            products = Path(temporary)
            path = products / "Workspace.xctestrun"
            content = plistlib.dumps({"TestConfigurations": [{"TestTargets": []}]})
            path.write_bytes(content)
            prepare.prepare(products, "workspace")
            self.assertEqual(path.read_bytes(), content)


if __name__ == "__main__":
    unittest.main()
