#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FIXTURE_PORT=${FIXTURE_PORT:-8765}
DERIVED_DATA_PATH=${DERIVED_DATA_PATH:-/tmp/WebInspectorKit-Monocly-Fixture-DerivedData}
SIMULATOR_NAME=${SIMULATOR_NAME:-iPhone 17}
DEVICE_UDID=${DEVICE_UDID:-}
SERVER_PID=

cleanup() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

if [ -z "$DEVICE_UDID" ]; then
    DEVICE_UDID=$(xcrun simctl list devices booted -j | python3 -c '
import json, sys
preferred_name = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
booted = [
    device
    for runtime, runtime_devices in devices.items()
    if runtime.startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
    for device in runtime_devices
    if device.get("state") == "Booted"
]
print(next((device["udid"] for device in booted if device.get("name") == preferred_name), booted[0]["udid"] if booted else ""))
' "$SIMULATOR_NAME")
fi

if [ -z "$DEVICE_UDID" ]; then
    DEVICE_UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
print(next((
    device["udid"]
    for runtime, runtime_devices in devices.items()
    if runtime.startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
    for device in runtime_devices
    if device.get("name") == name and device.get("isAvailable", False)
), ""))
' "$SIMULATOR_NAME")
    if [ -z "$DEVICE_UDID" ]; then
        echo "No available simulator named '$SIMULATOR_NAME'. Set DEVICE_UDID explicitly." >&2
        exit 1
    fi
    xcrun simctl boot "$DEVICE_UDID"
    xcrun simctl bootstatus "$DEVICE_UDID" -b
fi

python3 "$ROOT_DIR/Tools/InspectorFixture/server.py" --port "$FIXTURE_PORT" &
SERVER_PID=$!

python3 - "$FIXTURE_PORT" "$SERVER_PID" <<'PY'
import os, sys, time, urllib.request

url = f"http://127.0.0.1:{sys.argv[1]}/healthz"
server_pid = int(sys.argv[2])

def require_spawned_server():
    try:
        os.kill(server_pid, 0)
    except ProcessLookupError:
        raise SystemExit("The fixture server exited before becoming ready")

for _ in range(100):
    require_spawned_server()
    try:
        with urllib.request.urlopen(url, timeout=0.2) as response:
            if (
                response.status == 200
                and response.headers.get("X-Inspector-Fixture") == "self-authored"
            ):
                break
            time.sleep(0.05)
    except OSError:
        time.sleep(0.05)
else:
    raise SystemExit(f"Fixture server did not become ready: {url}")
require_spawned_server()
PY

xcodebuild build \
    -workspace "$ROOT_DIR/WebInspectorKit.xcworkspace" \
    -scheme Monocly \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    -derivedDataPath "$DERIVED_DATA_PATH"

xcrun simctl terminate "$DEVICE_UDID" lynnpd.Monocly 2>/dev/null || true
xcrun simctl install "$DEVICE_UDID" "$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/Monocly.app"

SIMCTL_CHILD_WEBSPECTOR_INITIAL_URL="http://127.0.0.1:$FIXTURE_PORT/a" \
SIMCTL_CHILD_WEBSPECTOR_AUTO_OPEN_INSPECTOR=1 \
SIMCTL_CHILD_WEBSPECTOR_EPHEMERAL_SESSION=1 \
xcrun simctl launch --terminate-running-process "$DEVICE_UDID" lynnpd.Monocly

echo "Inspector fixture is running at http://127.0.0.1:$FIXTURE_PORT/a"
echo "Monocly launched on $DEVICE_UDID; press Control-C to stop the server."
wait "$SERVER_PID"
