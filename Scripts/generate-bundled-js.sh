#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
OBFUSCATE_DIR="$REPO_ROOT/Plugins/WebInspectorKitObfuscatePlugin/ObfuscateJS"
INPUT_DIR="$REPO_ROOT/Sources/WebInspectorScripts/TypeScript"
OUTPUT_FILE="$REPO_ROOT/Generated/WebInspectorScriptsGenerated/CommittedBundledJavaScriptData.swift"
CONFIG_FILE="$OBFUSCATE_DIR/obfuscate.config.json"
SCRIPT_FILE="$OBFUSCATE_DIR/obfuscate.js"

if [[ -n "${WEBINSPECTORKIT_NODE:-}" ]]; then
    NODE_BIN="$WEBINSPECTORKIT_NODE"
else
    NODE_BIN="$(command -v node || true)"
fi

if [[ -z "$NODE_BIN" || ! -x "$NODE_BIN" ]]; then
    echo "node not found. Install Node.js or set WEBINSPECTORKIT_NODE." >&2
    exit 1
fi

PNPM_BIN="$(command -v pnpm || true)"
if [[ -z "$PNPM_BIN" ]]; then
    echo "pnpm not found. Install pnpm to sync ObfuscateJS dependencies." >&2
    exit 1
fi

(
    cd "$OBFUSCATE_DIR"
    "$PNPM_BIN" install --frozen-lockfile
)

"$NODE_BIN" "$SCRIPT_FILE" \
    --input "$INPUT_DIR" \
    --output "$OUTPUT_FILE" \
    --config "$CONFIG_FILE" \
    --mode release
