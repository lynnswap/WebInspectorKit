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


def native_test_runtimes(runtimes, latest_ios_major):
    by_major = {}
    for runtime in runtimes:
        major = version_components(runtime["version"])[0]
        by_major.setdefault(major, []).append(runtime)
    # Older hosts may not have the newest major installed; the workflow supplies
    # the same newest-major policy to every host.
    selected = []
    for major, releases in by_major.items():
        if major == latest_ios_major:
            selected.extend(releases)
        else:
            selected.append(max(releases, key=lambda item: version_components(item["version"])))
    return sorted(selected, key=lambda item: version_components(item["version"]))


def test_cases(runtimes, macos_version, suite, latest_ios_major, *, all_native_runtimes=False,
               platform=None, runtime_identifier=None):
    if platform == "macOS":
        runtimes = []
    elif runtime_identifier is None and suite == "workspace":
        runtimes = [max(runtimes, key=lambda runtime: version_components(runtime["version"]))]
    elif runtime_identifier is None and not all_native_runtimes:
        runtimes = native_test_runtimes(runtimes, latest_ios_major)
    cases = [
        {"runtime": runtime["identifier"], "version": runtime["version"], "platform": "iOS",
         "suite": suite}
        for runtime in runtimes
    ]
    if platform != "iOS":
        cases.append({"runtime": "", "version": macos_version, "platform": "macOS", "suite": suite})
    if runtime_identifier is not None:
        cases = [case for case in cases if case["runtime"] == runtime_identifier]
        if not cases:
            raise ValueError(f"No selected iOS runtime matches {runtime_identifier}.")
    return cases


def simctl(*arguments):
    return subprocess.check_output(["xcrun", "simctl", *arguments], text=True, timeout=60)


def create_device(runtime):
    device_type = next(device_type for device_type in runtime["supportedDeviceTypes"]
                       if device_type["productFamily"] == "iPhone")
    return simctl("create", "WebInspectorKit CI", device_type["identifier"], runtime["identifier"]).strip()


def reusable_device(runtime, devices):
    phone_types = {device_type["identifier"] for device_type in runtime["supportedDeviceTypes"]
                   if device_type["productFamily"] == "iPhone"}
    return next((device["udid"] for device in devices.get(runtime["identifier"], [])
                 if device.get("isAvailable", False) and device["state"] == "Shutdown"
                 and device.get("deviceTypeIdentifier") in phone_types), None)


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


def run_tests(runtimes, macos_version, build_root, suite, latest_ios_major, *, all_native_runtimes=False,
              platform=None, reuse_simulators=False, runtime_identifier=None,
              only_testing=(), skip_testing=()):
    results = []
    for case in test_cases(runtimes, macos_version, suite, latest_ios_major,
                           all_native_runtimes=all_native_runtimes, platform=platform,
                           runtime_identifier=runtime_identifier):
        label = f"{case['platform']} {case['version']} / {suite}"
        print(f"::group::{label}", flush=True)
        diagnostics = build_root / "runtime-tests" / f"{case['platform']}-{case['version']}"
        diagnostics.mkdir(parents=True, exist_ok=True)
        udid = None
        created_device = False
        passed = True
        try:
            destination = "platform=macOS,arch=arm64"
            if case["platform"] == "iOS":
                runtime = next(runtime for runtime in runtimes if runtime["identifier"] == case["runtime"])
                if reuse_simulators:
                    devices = json.loads(simctl("list", "devices", "available", "--json"))["devices"]
                    udid = reusable_device(runtime, devices)
                if udid is None:
                    udid = create_device(runtime)
                    created_device = True
                destination = f"platform=iOS Simulator,id={udid}"
                # Leave time for test launch and cleanup within the ten-minute CI job.
                run_logged(["xcrun", "simctl", "bootstatus", udid, "-b"], diagnostics / "boot.log", timeout=300)
            products = build_root / f"build-{case['platform']}" / "Build/Products"
            xctestrun = next(products.glob("*.xctestrun"))
            run_logged([
                "bash", str(Path(__file__).resolve().parents[2] / "Scripts/ci-xcodebuild-watchdog.sh"),
                "xcodebuild", "test-without-building", "-xctestrun", str(xctestrun),
                "-destination", destination, *test_selection(case),
                *[f"-only-testing:{identifier}" for identifier in only_testing],
                *[f"-skip-testing:{identifier}" for identifier in skip_testing],
                "-parallel-testing-enabled", "NO",
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
                    if created_device:
                        run_logged(["xcrun", "simctl", "delete", udid], diagnostics / "cleanup.log", timeout=30)
                    else:
                        # The watchdog may already have shut down a stalled test device.
                        devices = json.loads(simctl("list", "devices", "available", "--json"))["devices"]
                        if any(device["udid"] == udid and device["state"] != "Shutdown"
                               for device in devices.get(case["runtime"], [])):
                            run_logged(["xcrun", "simctl", "shutdown", udid], diagnostics / "cleanup.log", timeout=30)
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
    parser.add_argument("--latest-ios-major", type=int, required=True,
                        help="Newest iOS major covered by CI, shared across all runner hosts")
    parser.add_argument("--all-native-runtimes", action="store_true",
                        help="Run Native release validation on every supported installed runtime")
    parser.add_argument("--platform", choices=("iOS", "macOS"),
                        help="Test only this platform's build products")
    parser.add_argument("--reuse-simulators", action="store_true",
                        help="Borrow available shutdown iPhones instead of creating fresh devices")
    parser.add_argument("--list-cases", action="store_true",
                        help="Print the selected runtime/platform cases as JSON without running tests")
    parser.add_argument("--runtime", help="Test only the selected iOS runtime with this exact identifier")
    parser.add_argument("--only-testing", action="append", default=[], metavar="TEST",
                        help="Include an xcodebuild test identifier; may be repeated")
    parser.add_argument("--skip-testing", action="append", default=[], metavar="TEST",
                        help="Exclude an xcodebuild test identifier; may be repeated")
    args = parser.parse_args()

    runtimes = []
    if args.platform != "macOS":
        runtimes = supported_runtimes(json.loads(simctl("list", "runtimes", "--json"))["runtimes"])
        if not runtimes:
            raise ValueError("No available iOS runtime supported by CI is installed.")
    macos_version = subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip()
    if args.list_cases:
        print(json.dumps(test_cases(runtimes, macos_version, args.suite, args.latest_ios_major,
                                   all_native_runtimes=args.all_native_runtimes, platform=args.platform,
                                   runtime_identifier=args.runtime)))
        return 0
    return run_tests(runtimes, macos_version, args.build_root, args.suite, args.latest_ios_major,
                     all_native_runtimes=args.all_native_runtimes, platform=args.platform,
                     reuse_simulators=args.reuse_simulators, runtime_identifier=args.runtime,
                     only_testing=args.only_testing, skip_testing=args.skip_testing)


if __name__ == "__main__":
    raise SystemExit(main())
