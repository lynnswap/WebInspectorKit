#!/usr/bin/env python3
"""Discover supported installed runtimes and select a device on the current runner."""

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
        if version_components(runtime["version"]) < version_components("18.4"):
            continue
        selected[runtime["identifier"]] = runtime
    return sorted(selected.values(), key=lambda runtime: version_components(runtime["version"]))


def test_matrix(runtimes, macos_version):
    return {"include": [
        {"runtime": runtime["identifier"], "version": runtime["version"], "platform": "iOS"}
        for runtime in runtimes
    ] + [{"runtime": "", "version": macos_version, "platform": "macOS"}]}


def simctl(*arguments):
    return subprocess.check_output(["xcrun", "simctl", *arguments], text=True)


def append_environment(values):
    with Path(os.environ["GITHUB_ENV"]).open("a") as stream:
        for name, value in values.items():
            stream.write(f"{name}={value}\n")


def resolve_device(runtime_id):
    runtimes = supported_runtimes(json.loads(simctl("list", "runtimes", "--json"))["runtimes"])
    runtime = next((runtime for runtime in runtimes if runtime["identifier"] == runtime_id), None)
    if runtime is None:
        raise ValueError(f"Requested runtime is unavailable: {runtime_id}")
    devices = json.loads(simctl("list", "devices", "available", "--json"))["devices"]
    device = next((device for device in devices.get(runtime_id, [])
                   if device.get("isAvailable", False) and device["name"].startswith("iPhone")), None)
    if device is None:
        device_type = next(device_type for device_type in runtime["supportedDeviceTypes"]
                           if device_type["productFamily"] == "iPhone")
        udid = simctl("create", "WebInspectorKit CI", device_type["identifier"], runtime_id).strip()
    else:
        udid = device["udid"]
    append_environment({
        "DESTINATION": f"platform=iOS Simulator,id={udid}",
        "RESOLVED_IOS_VERSION": runtime["version"],
        "WATCHDOG_SIMULATOR_UDID": udid,
    })
    print(f"iOS {runtime['version']} ({runtime['buildversion']}): {udid}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("discover")
    resolve = commands.add_parser("resolve")
    resolve.add_argument("--runtime", required=True)
    args = parser.parse_args()

    if args.command == "resolve":
        resolve_device(args.runtime)
        return
    runtimes = supported_runtimes(json.loads(simctl("list", "runtimes", "--json"))["runtimes"])
    if not runtimes:
        raise ValueError("No available iOS 18.4 or later runtime is installed.")
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        macos_version = subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip()
        output.write(f"matrix={json.dumps(test_matrix(runtimes, macos_version))}\n")
    for runtime in runtimes:
        print(f"iOS {runtime['version']} ({runtime['buildversion']})")


if __name__ == "__main__":
    main()
