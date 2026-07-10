#!/bin/zsh

set -euo pipefail

repo_root=${0:A:h:h}
build_root="$repo_root/.build/arm64-apple-macosx/debug"
fixture="$repo_root/Tests/ConcurrencyFixtures/ModelContextCannotCrossActors.swift"
diagnostics=$(mktemp -t webinspector-model-context-confinement)
trap 'rm -f "$diagnostics"' EXIT

swift build --package-path "$repo_root" --target WebInspectorDataKit >/dev/null

if xcrun swiftc \
    -typecheck \
    -swift-version 6 \
    -strict-concurrency=complete \
    -target arm64-apple-macosx15.4 \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -I "$build_root/Modules" \
    -module-cache-path "$build_root/ModuleCache" \
    -Xcc -fmodule-map-file="$build_root/MachOKitC.build/module.modulemap" \
    -Xcc -I \
    -Xcc "$repo_root/.build/checkouts/MachOKit/Sources/MachOKitC/include" \
    -Xcc -fmodule-map-file="$build_root/WebInspectorNativeBridgeObjC.build/module.modulemap" \
    -Xcc -I \
    -Xcc "$repo_root/Packages/WebInspectorNativeBridge/Sources/WebInspectorNativeBridgeObjC/include" \
    "$fixture" >"$diagnostics" 2>&1
then
    print -u2 "Expected WebInspectorModelContext Sendable misuse to fail type checking."
    exit 1
fi

if ! /usr/bin/grep -q "WebInspectorModelContext.*does not conform to the 'Sendable' protocol" "$diagnostics"; then
    /bin/cat "$diagnostics" >&2
    print -u2 "The confinement fixture failed for an unexpected reason."
    exit 1
fi

print "WebInspectorModelContext confinement fixture passed."
