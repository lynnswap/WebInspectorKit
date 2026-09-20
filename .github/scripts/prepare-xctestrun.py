#!/usr/bin/env python3
"""Enable native smoke tests and give iOS tests a UIKit application host."""

import argparse
import plistlib
from pathlib import Path


def prepare(products):
    candidates = list(products.glob("*.xctestrun"))
    if len(candidates) != 1:
        raise ValueError(f"Expected one generated test plan in {products}, found {len(candidates)}")
    path = candidates[0]
    data = plistlib.loads(path.read_bytes())
    if "TestConfigurations" in data:
        targets = [target for configuration in data["TestConfigurations"]
                   for target in configuration["TestTargets"]]
    else:
        targets = [target for target in data.values()
                   if isinstance(target, dict) and "TestBundlePath" in target]
    for target in targets:
        if target["BlueprintName"] == "WebInspectorNativeBridgeTests":
            target.setdefault("EnvironmentVariables", {})["WEBINSPECTORKIT_RUN_NATIVE_RUNTIME_SMOKE"] = "1"
            if "/iPhoneSimulator.platform/" in target["TestHostPath"]:
                # Hostless xctest can stall in UIKit's initial SpringBoard registration.
                host = Path("Debug-iphonesimulator/RuntimeTestHost.app")
                info = plistlib.loads((products / host / "Info.plist").read_bytes())
                host_path = f"__TESTROOT__/{host}"
                target["TestHostPath"] = host_path
                target["TestHostBundleIdentifier"] = info["CFBundleIdentifier"]
                target["IsAppHostedTestBundle"] = True
                target.setdefault("DependentProductPaths", []).append(host_path)
                environment = target["TestingEnvironmentVariables"]
                inject = "__PLATFORMS__/iPhoneSimulator.platform/Developer/usr/lib/libXCTestBundleInject.dylib"
                libraries = environment.get("DYLD_INSERT_LIBRARIES", "")
                environment["DYLD_INSERT_LIBRARIES"] = ":".join(filter(None, (inject, libraries)))
                environment["XCInjectBundleInto"] = "unused"
    path.write_bytes(plistlib.dumps(data))
    return path


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("products", type=Path)
    args = parser.parse_args()
    print(prepare(args.products))
