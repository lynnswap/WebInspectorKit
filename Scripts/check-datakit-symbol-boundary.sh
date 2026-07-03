#!/usr/bin/env bash
set -euo pipefail

swift package dump-symbol-graph --minimum-access-level public

graph="$(find .build -path '*/symbolgraph/WebInspectorDataKit.symbols.json' -print -quit)"
if [[ -z "${graph}" ]]; then
  echo "error: WebInspectorDataKit symbol graph was not generated." >&2
  exit 1
fi

denylist='Network\.Request|Network\.Response|WebInspectorSortOrder|WebInspectorSortDescriptor|WebInspectorFetchPredicate|WebInspectorDataPhase|WebInspectorModelActor|WebInspectorModelExecutor|WebInspectorTargetChanges|RawEvent|\bWebView[A-Za-z0-9_]*|WebViewKit|@WebView'

if rg -n "${denylist}" "${graph}"; then
  echo "error: WebInspectorDataKit public symbol graph exposes forbidden boundary symbols." >&2
  exit 1
fi

