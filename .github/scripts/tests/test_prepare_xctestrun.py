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
                target = {"BlueprintName": "WebInspectorNativeBridgeTests",
                          "TestBundlePath": "__TESTROOT__/Debug-iphonesimulator/Native.xctest",
                          "EnvironmentVariables": {"EXISTING": "preserved"}}
                data = ({"TestConfigurations": [{"TestTargets": [target]}]}
                        if uses_test_plan else {"Native": target})
                path = products / "Native.xctestrun"
                path.write_bytes(plistlib.dumps(data))
                self.assertEqual(prepare.prepare(products), path)
                updated = plistlib.loads(path.read_bytes())
                updated_target = (updated["TestConfigurations"][0]["TestTargets"][0]
                                  if uses_test_plan else updated["Native"])
                self.assertEqual(updated_target["EnvironmentVariables"], {
                    "EXISTING": "preserved", "WEBINSPECTORKIT_RUN_NATIVE_RUNTIME_SMOKE": "1"
                })
                self.assertEqual(updated_target["TestBundlePath"], target["TestBundlePath"])

    def test_aggregate_plan_enables_only_the_native_smoke_tests(self):
        with tempfile.TemporaryDirectory() as temporary:
            products = Path(temporary)
            path = products / "Workspace.xctestrun"
            native = {"BlueprintName": "WebInspectorNativeBridgeTests", "TestBundlePath": "native.xctest"}
            consumer = {"BlueprintName": "WebInspectorConsumerContractTests", "EnvironmentVariables": {"OTHER": "preserved"}}
            content = plistlib.dumps({"TestConfigurations": [{"TestTargets": [native, consumer]}]})
            path.write_bytes(content)
            prepare.prepare(products)
            targets = plistlib.loads(path.read_bytes())["TestConfigurations"][0]["TestTargets"]
            self.assertEqual(targets[0]["EnvironmentVariables"]["WEBINSPECTORKIT_RUN_NATIVE_RUNTIME_SMOKE"], "1")
            self.assertEqual(targets[1], consumer)


if __name__ == "__main__":
    unittest.main()
