#!/usr/bin/env python3
"""Test installed runtimes sequentially using this runner's local build products."""

import argparse
import json
import os
import subprocess
from pathlib import Path


def version_components(version):
    return tuple((list(map(int, version.split("."))) + [0, 0])[:3])


def supported_runtimes(runtimes):
    # CoreSimulator can retain older builds with the same runtime identifier.
    # A destination selects the installed runtime for that identifier.
    selected = {}
    for runtime in runtimes:
        if not runtime["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-"):
            continue
        if not runtime.get("isAvailable", False):
            continue
        version = version_components(runtime["version"])
        if version < (18, 4, 0) or (26, 0, 0) <= version < (26, 1, 0):
            continue
        selected[runtime["identifier"]] = runtime
    return sorted(selected.values(), key=lambda runtime: version_components(runtime["version"]))


def test_cases(runtimes, macos_version, suite):
    if suite == "workspace":
        runtimes = [max(runtimes, key=lambda runtime: version_components(runtime["version"]))]
    return [
        {"runtime": runtime["identifier"], "version": runtime["version"], "platform": "iOS",
         "suite": suite}
        for runtime in runtimes
    ] + [{"runtime": "", "version": macos_version, "platform": "macOS",
          "suite": suite}]


def simctl(*arguments):
    return subprocess.check_output(["xcrun", "simctl", *arguments], text=True, timeout=60)


def create_device(runtime):
    device_type = next(device_type for device_type in runtime["supportedDeviceTypes"]
                       if device_type["productFamily"] == "iPhone")
    return simctl("create", "WebInspectorKit CI", device_type["identifier"], runtime["identifier"]).strip()


def test_selection(case):
    if case["suite"] == "native":
        return ["-only-testing:WebInspectorNativeBridgeTests"]
    if case["platform"] == "macOS":
        return [f"-only-testing:{target}" for target in (
            "WebInspectorDataKitImportOnlyContractTests", "WebInspectorConsumerContractTests",
        )]
    return ["-skip-testing:WebInspectorNativeBridgeTests"]


def run_logged(command, path, **options):
    print("Running:", " ".join(map(str, command)), flush=True)
    with path.open("w") as log:
        try:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, **options)
        finally:
            print(path.read_text(errors="replace"), flush=True)


def run_tests(runtimes, macos_version, build_root, suite):
    results = []
    for case in test_cases(runtimes, macos_version, suite):
        label = f"{case['platform']} {case['version']} / {suite}"
        print(f"::group::{label}", flush=True)
        diagnostics = build_root / "runtime-tests" / f"{case['platform']}-{case['version']}"
        diagnostics.mkdir(parents=True, exist_ok=True)
        udid = None
        passed = True
        try:
            destination = "platform=macOS,arch=arm64"
            if case["platform"] == "iOS":
                runtime = next(runtime for runtime in runtimes if runtime["identifier"] == case["runtime"])
                udid = create_device(runtime)
                destination = f"platform=iOS Simulator,id={udid}"
                # Bound startup separately so a stuck Simulator cannot consume the whole job.
                run_logged(["xcrun", "simctl", "bootstatus", udid, "-b"], diagnostics / "boot.log", timeout=180)
            products = build_root / f"build-{case['platform']}" / "Build/Products"
            xctestrun = next(products.glob("*.xctestrun"))
            run_logged([
                "bash", str(Path(__file__).resolve().parents[2] / "Scripts/ci-xcodebuild-watchdog.sh"),
                "xcodebuild", "test-without-building", "-xctestrun", str(xctestrun),
                "-destination", destination, *test_selection(case), "-parallel-testing-enabled", "NO",
                "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "30",
                "-maximum-test-execution-time-allowance", "60",
                "-resultBundlePath", str(diagnostics / "tests.xcresult"),
            ], diagnostics / "tests.log", env=dict(os.environ, WATCHDOG_SIMULATOR_UDID=udid or ""))
        except (subprocess.SubprocessError, OSError) as error:
            passed = False
            print(f"::error::{label}: {error}", flush=True)
        finally:
            if udid:
                try:
                    run_logged(["xcrun", "simctl", "delete", udid], diagnostics / "cleanup.log", timeout=30)
                except (subprocess.SubprocessError, OSError) as error:
                    passed = False
                    print(f"::error::{label} cleanup: {error}", flush=True)
            results.append((label, passed))
            print("::endgroup::", flush=True)

    rows = [f"| {label} | {'Passed' if passed else 'Failed'} |" for label, passed in results]
    summary = "| Runtime / suite | Result |\n| --- | --- |\n" + "\n".join(rows) + "\n"
    print(summary, flush=True)
    if summary_path := os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(summary_path).open("a") as output:
            output.write(summary)
    return 0 if all(passed for _, passed in results) else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_root", type=Path)
    parser.add_argument("--suite", choices=("native", "workspace"), required=True)
    args = parser.parse_args()

    runtimes = supported_runtimes(json.loads(simctl("list", "runtimes", "--json"))["runtimes"])
    if not runtimes:
        raise ValueError("No available iOS runtime supported by CI is installed.")
    macos_version = subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip()
    return run_tests(runtimes, macos_version, args.build_root, args.suite)


if __name__ == "__main__":
    raise SystemExit(main())
