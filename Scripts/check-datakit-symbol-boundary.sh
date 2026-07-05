#!/usr/bin/env bash
set -euo pipefail

if [[ -d .build ]]; then
  find .build -type d -name symbolgraph -prune -exec rm -rf {} +
fi

dump_log="$(mktemp)"
trap 'rm -f "${dump_log}"' EXIT
dump_status=0
swift package dump-symbol-graph --minimum-access-level public >"${dump_log}" 2>&1 || dump_status=$?

graph="$(find .build -path '*/symbolgraph/WebInspectorDataKit.symbols.json' -print -quit)"
if [[ -z "${graph}" ]]; then
  cat "${dump_log}" >&2
  echo "error: WebInspectorDataKit symbol graph was not generated." >&2
  exit 1
fi

if rg -q "Failed to emit symbol graph for 'WebInspectorDataKit'" "${dump_log}"; then
  cat "${dump_log}" >&2
  echo "error: WebInspectorDataKit symbol graph emission failed." >&2
  exit 1
fi

if [[ "${dump_status}" -ne 0 ]]; then
  echo "warning: symbol graph dump reported failures outside WebInspectorDataKit; continuing with generated DataKit graph." >&2
fi

denylist='Network\.Request|Network\.Response|WebInspectorSortOrder|WebInspectorSortDescriptor|WebInspectorFetchPredicate|WebInspectorDataPhase|WebInspectorModelActor|WebInspectorModelExecutor|WebInspectorTargetChanges|RawEvent|\bWebView[A-Za-z0-9_]*|WebViewKit|@WebView'

if rg -n "${denylist}" "${graph}"; then
  echo "error: WebInspectorDataKit public symbol graph exposes forbidden boundary symbols." >&2
  exit 1
fi
