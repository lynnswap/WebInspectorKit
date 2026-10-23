#!/usr/bin/env python3
"""Test installed runtimes sequentially using this runner's local build products."""

import argparse
import json
import os
import subprocess
from pathlib import Path


def version_components(version):
    return tuple((list(map(int, version.split("."))) + [0, 0])[:3])


def phone_device_types(runtime):
    # iPhone Duo layout support is deferred, so CI uses only other iPhones.
    return [device_type["identifier"] for device_type in runtime["supportedDeviceTypes"]
            if device_type["productFamily"] == "iPhone"
            and device_type["identifier"] != "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"]


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
        if not phone_device_types(runtime):
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
               platform=None):
    if platform == "macOS":
        runtimes = []
    elif suite == "workspace":
        runtimes = [max(runtimes, key=lambda runtime: version_components(runtime["version"]))]
    elif not all_native_runtimes:
        runtimes = native_test_runtimes(runtimes, latest_ios_major)
    cases = [
        {"runtime": runtime["identifier"], "version": runtime["version"], "platform": "iOS",
         "suite": suite}
        for runtime in runtimes
    ]
    if platform != "iOS":
        cases.append({"runtime": "", "version": macos_version, "platform": "macOS", "suite": suite})
    return cases


def simctl(*arguments):
    return subprocess.check_output(["xcrun", "simctl", *arguments], text=True, timeout=60)


def create_device(runtime):
    device_type = phone_device_types(runtime)[0]
    return simctl("create", "WebInspectorKit CI", device_type, runtime["identifier"]).strip()


def reusable_device(runtime, devices):
    phone_types = phone_device_types(runtime)
    return next((device["udid"] for device in devices.get(runtime["identifier"], [])
                 if device.get("isAvailable", False) and device["state"] == "Shutdown"
                 and device.get("deviceTypeIdentifier") in phone_types), None)


def select_device(runtime, reuse_simulators):
    if reuse_simulators:
        devices = json.loads(simctl("list", "devices", "available", "--json"))["devices"]
        if udid := reusable_device(runtime, devices):
            return udid, False
    return create_device(runtime), True


def simulator_state_path(build_root):
    return build_root / "runtime-tests" / "prepared-simulator.json"


def cleanup_device(udid, runtime, created, diagnostics):
    if created:
        run_logged(["xcrun", "simctl", "delete", udid], diagnostics / "cleanup.log", timeout=30)
    else:
        # The watchdog may already have shut down a stalled test device.
        devices = json.loads(simctl("list", "devices", "available", "--json"))["devices"]
        if any(device["udid"] == udid and device["state"] != "Shutdown"
               for device in devices.get(runtime, [])):
            run_logged(["xcrun", "simctl", "shutdown", udid], diagnostics / "cleanup.log", timeout=30)


def prepare_simulator(runtimes, build_root, suite, latest_ios_major, *, all_native_runtimes=False,
                      reuse_simulators=False):
    case = test_cases(runtimes, "", suite, latest_ios_major,
                      all_native_runtimes=all_native_runtimes, platform="iOS")[0]
    runtime = next(runtime for runtime in runtimes if runtime["identifier"] == case["runtime"])
    state_path = simulator_state_path(build_root)
    state_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        udid, created = select_device(runtime, reuse_simulators)
        # Persist ownership before boot so an interrupted build can still clean up.
        state_path.write_text(json.dumps({"udid": udid, "runtime": case["runtime"], "created": created}) + "\n")
        run_logged(["xcrun", "simctl", "boot", udid], state_path.parent / "prepare-simulator.log", timeout=60)
    except (subprocess.SubprocessError, OSError) as error:
        print(f"::error::Prepare simulator: {error}", flush=True)
        return 1
    return 0


def cleanup_prepared_simulator(build_root):
    state_path = simulator_state_path(build_root)
    if not state_path.exists():
        return 0
    try:
        state = json.loads(state_path.read_text())
        cleanup_device(state["udid"], state["runtime"], state["created"], state_path.parent)
        state_path.unlink()
    except (subprocess.SubprocessError, OSError) as error:
        print(f"::error::Prepared simulator cleanup: {error}", flush=True)
        return 1
    return 0


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
              platform=None, reuse_simulators=False):
    results = []
    state_path = simulator_state_path(build_root)
    prepared = json.loads(state_path.read_text()) if platform != "macOS" and state_path.exists() else None
    for case in test_cases(runtimes, macos_version, suite, latest_ios_major,
                           all_native_runtimes=all_native_runtimes, platform=platform):
        label = f"{case['platform']} {case['version']} / {suite}"
        print(f"::group::{label}", flush=True)
        diagnostics = build_root / "runtime-tests" / f"{case['platform']}-{case['version']}"
        diagnostics.mkdir(parents=True, exist_ok=True)
        udid = None
        created_device = False
        uses_prepared_device = False
        passed = True
        try:
            destination = "platform=macOS,arch=arm64"
            if case["platform"] == "iOS":
                runtime = next(runtime for runtime in runtimes if runtime["identifier"] == case["runtime"])
                if prepared and prepared["runtime"] == case["runtime"]:
                    udid, created_device = prepared["udid"], prepared["created"]
                    uses_prepared_device = True
                else:
                    udid, created_device = select_device(runtime, reuse_simulators)
                destination = f"platform=iOS Simulator,id={udid}"
                # Bound simulator startup so a failed boot does not block later tests.
                run_logged(["xcrun", "simctl", "bootstatus", udid, "-b"], diagnostics / "boot.log", timeout=300)
            products = build_root / f"build-{case['platform']}" / "Build/Products"
            xctestrun = next(products.glob("*.xctestrun"))
            result_stream = diagnostics / "result-stream.json"
            result_stream.touch()
            run_logged([
                "bash", str(Path(__file__).resolve().parents[2] / "Scripts/ci-xcodebuild-watchdog.sh"),
                "xcodebuild", "test-without-building", "-verbose",
                "-resultStreamPath", str(result_stream), "-xctestrun", str(xctestrun),
                "-destination", destination, *test_selection(case),
                "-parallel-testing-enabled", "NO",
                "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "30",
                "-maximum-test-execution-time-allowance", "60",
                "-resultBundlePath", str(diagnostics / "tests.xcresult"),
            ], diagnostics / "tests.log", env=dict(os.environ, WATCHDOG_SIMULATOR_UDID=udid or "",
                                                   WATCHDOG_DIAGNOSTICS_DIR=str(diagnostics / "startup")))
        except (subprocess.SubprocessError, OSError) as error:
            passed = False
            print(f"::error::{label}: {error}", flush=True)
        finally:
            if udid:
                try:
                    cleanup_device(udid, case["runtime"], created_device, diagnostics)
                    if uses_prepared_device:
                        state_path.unlink()
                        prepared = None
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
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--prepare-simulator", action="store_true",
                      help="Start the first selected iOS simulator before building")
    mode.add_argument("--cleanup-simulator", action="store_true",
                      help="Clean up the simulator saved by --prepare-simulator")
    args = parser.parse_args()

    if args.cleanup_simulator:
        return cleanup_prepared_simulator(args.build_root)

    runtimes = []
    if args.platform != "macOS":
        runtimes = supported_runtimes(json.loads(simctl("list", "runtimes", "--json"))["runtimes"])
        if not runtimes:
            raise ValueError("No available iOS runtime supported by CI is installed.")
    if args.prepare_simulator:
        return prepare_simulator(runtimes, args.build_root, args.suite, args.latest_ios_major,
                                 all_native_runtimes=args.all_native_runtimes,
                                 reuse_simulators=args.reuse_simulators)
    macos_version = subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip()
    return run_tests(runtimes, macos_version, args.build_root, args.suite, args.latest_ios_major,
                     all_native_runtimes=args.all_native_runtimes, platform=args.platform,
                     reuse_simulators=args.reuse_simulators)


if __name__ == "__main__":
    raise SystemExit(main())
