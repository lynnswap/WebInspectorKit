#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: Scripts/verify-removed-architecture-symbols.sh [options]

Options:
  --repo-root PATH          Repository root to inspect (default: script parent)
  --dump-package-json PATH  Use an existing swift package dump-package JSON file
  -h, --help                Show this help
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
dump_package_json=""

while [[ $# -gt 0 ]]; do
    case "$1" in
    --repo-root)
        [[ $# -ge 2 ]] || {
            echo "error: --repo-root requires a path." >&2
            exit 2
        }
        repo_root="$2"
        shift 2
        ;;
    --dump-package-json)
        [[ $# -ge 2 ]] || {
            echo "error: --dump-package-json requires a path." >&2
            exit 2
        }
        dump_package_json="$2"
        shift 2
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        echo "error: unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
done

repo_root="$(cd "${repo_root}" && pwd)"

for command in rg python3; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "error: required command not found: ${command}" >&2
        exit 2
    fi
done

scan_roots=()
for relative_path in Sources Tests ContractTests README.md; do
    if [[ -e "${repo_root}/${relative_path}" ]]; then
        scan_roots+=("${repo_root}/${relative_path}")
    fi
done

if [[ ${#scan_roots[@]} -eq 0 ]]; then
    echo "error: no production or consumer-evidence paths were found under ${repo_root}." >&2
    exit 2
fi

failure_count=0

report_matches() {
    local title="$1"
    local pattern="$2"
    local matches
    local status

    if matches="$(rg --line-number --with-filename --pcre2 --multiline "${pattern}" "${scan_roots[@]}" 2>&1)"; then
        echo "error: ${title}" >&2
        printf '%s\n' "${matches}" >&2
        failure_count=$((failure_count + 1))
        return
    else
        status=$?
        if [[ ${status} -ne 1 ]]; then
            echo "error: symbol scan failed while checking ${title}" >&2
            printf '%s\n' "${matches}" >&2
            exit 2
        fi
    fi
}

# These are exact retired owners or retired owner-name families. Keep this
# list specific: terms such as section, load, domain, responseBody,
# protocolViolation, and precondition remain valid feature/UI vocabulary.
retired_symbol_pattern='\b(?:ConnectionModelFeed[A-Za-z0-9_]*|ModelDomain|WebInspectorProxyDomain|ProtocolDomain|WebInspectorProxyEvent|WebInspectorProxyEventDomain|ConnectionCapabilityActivationPlan|ConnectionEventScopeRegistry|ConnectionEventProjection|StructuredEventScopes|WebInspectorModelOwnerEndpoint|WebInspectorFetchedResultsControllerRegistrationLease|WebInspectorFetchedResultsControllerOwnerID|WebInspectorFetchedResultsControllerAdmissionGate|WebInspectorFetchedResultsControllerRegistrationClaim|WebInspectorFetchedResultsControllerOwnerMutationBatch|WebInspectorFetchedResultsIndexPath|WebInspectorFetchedResultsSectionChange|WebInspectorFetchSectionID|WebInspectorFetchedResults|WebInspectorResultsObserver|ResultsObserver|CSSStyles|RuntimeObjectGroup)\b'
report_matches \
    "retired architecture symbols remain in production or consumer evidence" \
    "${retired_symbol_pattern}"

# These patterns identify the old receiver-qualified API paths rather than
# banning their component words. Feature actors may continue to expose
# operations such as reload or load under new ownership.
retired_receiver_pattern='(?:\.modelFeedSequence\b|\.modelFeedFailure\b|\.makeContext\s*\(\s*isolation\s*:|\.(?:domTreeUpdates|rebaseDOMTree)\s*\(|\b(?:context|modelContext|mainContext|runtime\.model)\s*\.\s*(?:requestDOMChildren|setDOMAttribute|setOuterHTML|removeDOMNodes|highlightDOMNode|hideDOMHighlight|pickDOMNodeID|cssStyles|refreshCSSStyles|setCSSProperty|setCSSDeclarationText|clearNetworkRequests|loadCanonicalResponseBody|withRuntimeObjectGroup)\s*\(|\b(?:body|responseBody|requestBody)\s*\.\s*load\s*\(\s*(?:\)|isolation\s*:))'
report_matches \
    "retired model-feed, ModelContext-domain, or NetworkBody receiver call sites remain" \
    "${retired_receiver_pattern}"

sectioned_generic_pattern='\bWebInspectorFetchedResults(?:Controller|Snapshot|Update|UpdateSequence)\s*<\s*[^>,\n]+\s*,'
report_matches \
    "a retired sectioned fetched-results generic arity remains" \
    "${sectioned_generic_pattern}"

legacy_import_pattern='(?m)^\s*(?:@testable\s+|@_exported\s+)?import\s+(?:WebInspectorUI|WebInspectorUISyntaxBody)\s*$'
report_matches \
    "an import of a deleted UI module remains" \
    "${legacy_import_pattern}"

direct_model_actor_pattern='(?m)^\s*(?:(?:public|package|internal|private|final|nonisolated)\s+)*(?:(?:actor|class|struct|enum|protocol)\s+[A-Za-z_][A-Za-z0-9_]*(?:\s*<[^{};]+>)?|extension\s+[A-Za-z_][A-Za-z0-9_.]*(?:\s*<[^{};]+>)?)\s*:[^{};]*\bWebInspectorModelActor\b'
model_actor_scan_roots=()
for path in "${scan_roots[@]}"; do
    [[ -d "${path}" ]] || {
        model_actor_scan_roots+=("${path}")
        continue
    }
    model_actor_scan_roots+=("${path}")
done

direct_model_actor_matches=""
direct_model_actor_status=0
if direct_model_actor_matches="$(
    rg --line-number --with-filename --pcre2 --multiline \
        --glob '!**/WebInspectorDataKitMacros/**' \
        --glob '!**/WebInspectorDataKitMacroTests/**' \
        "${direct_model_actor_pattern}" \
        "${model_actor_scan_roots[@]}" 2>&1
)"; then
    echo "error: direct handwritten WebInspectorModelActor conformance remains; use @WebInspectorModelActor." >&2
    printf '%s\n' "${direct_model_actor_matches}" >&2
    failure_count=$((failure_count + 1))
else
    direct_model_actor_status=$?
    if [[ ${direct_model_actor_status} -ne 1 ]]; then
        echo "error: direct ModelActor conformance scan failed." >&2
        printf '%s\n' "${direct_model_actor_matches}" >&2
        exit 2
    fi
fi

frc_surface_status=0
python3 - "${repo_root}" <<'PY' || frc_surface_status=$?
from pathlib import Path
import re
import sys
from typing import Optional

root = Path(sys.argv[1])
source_root = root / "Sources"
swift_files = sorted(source_root.rglob("*.swift")) if source_root.is_dir() else []
source = "\n".join(path.read_text(encoding="utf-8") for path in swift_files)


def mask_comments_and_strings(text: str) -> str:
    masked = list(text)
    index = 0
    length = len(text)

    def blank(start: int, end: int) -> None:
        for position in range(start, end):
            if masked[position] != "\n":
                masked[position] = " "

    while index < length:
        if text.startswith("//", index):
            end = text.find("\n", index + 2)
            if end == -1:
                end = length
            blank(index, end)
            index = end
            continue

        if text.startswith("/*", index):
            start = index
            depth = 1
            index += 2
            while index < length and depth:
                if text.startswith("/*", index):
                    depth += 1
                    index += 2
                elif text.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            blank(start, index)
            continue

        hash_count = 0
        quote_index = index
        if text[index] == "#":
            while quote_index < length and text[quote_index] == "#":
                hash_count += 1
                quote_index += 1
        if quote_index < length and text[quote_index] == '"':
            start = index
            triple = text.startswith('"""', quote_index)
            quote_width = 3 if triple else 1
            closing = ('"""' if triple else '"') + ("#" * hash_count)
            index = quote_index + quote_width
            while index < length:
                if text.startswith(closing, index):
                    index += len(closing)
                    break
                if hash_count == 0 and not triple and text[index] == "\\":
                    index = min(index + 2, length)
                else:
                    index += 1
            blank(start, index)
            continue

        index += 1

    return "".join(masked)


masked_source = mask_comments_and_strings(source)


def matching_brace(text: str, opening: int) -> Optional[int]:
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return index
    return None


def declaration_regions(pattern: str) -> tuple[list[re.Match[str]], list[str]]:
    matches = list(re.finditer(pattern, masked_source, flags=re.DOTALL))
    regions: list[str] = []
    for match in matches:
        opening = masked_source.rfind("{", match.start(), match.end())
        closing = matching_brace(masked_source, opening)
        if closing is not None:
            regions.append(masked_source[opening + 1 : closing])
    return matches, regions


def extension_regions(type_name: str) -> list[str]:
    pattern = (
        rf"\bextension\s+{re.escape(type_name)}"
        rf"(?:\s*<[^>{{}}]*>)?[^{{}};]*\{{"
    )
    regions: list[str] = []
    for match in re.finditer(pattern, masked_source, flags=re.DOTALL):
        opening = masked_source.rfind("{", match.start(), match.end())
        closing = matching_brace(masked_source, opening)
        if closing is not None:
            regions.append(masked_source[opening + 1 : closing])
    return regions


def depth_at(text: str, position: int) -> int:
    return text.count("{", 0, position) - text.count("}", 0, position)


def top_level_matches(pattern: str, regions: str) -> list[re.Match[str]]:
    return [
        match
        for match in re.finditer(pattern, regions, flags=re.DOTALL)
        if depth_at(regions, match.start()) == 0
    ]

errors: list[str] = []

controller_matches, controller_regions = declaration_regions(
    r"\b(?:public\s+)?final\s+class\s+"
    r"WebInspectorFetchedResultsController\s*<\s*"
    r"(?P<parameter>[A-Za-z_][A-Za-z0-9_]*)"
    r"(?:\s*:\s*[^,>{}]+)?\s*>[^{};]*\{"
)
controller_parameters = [match.group("parameter") for match in controller_matches]
if controller_parameters != ["Model"] or len(controller_regions) != 1:
    errors.append(
        "expected exactly one one-parameter declaration "
        "'final class WebInspectorFetchedResultsController<Model>'"
    )
elif not any(
    re.search(
        r"\bModel\s*:\s*[^,>{}]*\bWebInspectorPersistentModel\b",
        match.group(0),
    )
    for match in controller_matches
):
    errors.append(
        "WebInspectorFetchedResultsController.Model must conform to "
        "WebInspectorPersistentModel"
    )

controller_scope = "\n".join(
    controller_regions
    + extension_regions("WebInspectorFetchedResultsController")
)

required_controller_patterns = {
    "modelContext owner": (
        r"\bpublic\s+let\s+modelContext\s*:\s*WebInspectorModelContext\b"
    ),
    "performFetch() async throws": (
        r"\bpublic\s+nonisolated\s*\(\s*nonsending\s*\)\s+"
        r"func\s+performFetch\s*\(\s*\)\s*async\s+throws\s*(?=\{)"
    ),
    "refetch(using:) async throws": (
        r"\bpublic\s+nonisolated\s*\(\s*nonsending\s*\)\s+"
        r"func\s+refetch\s*\(\s*using\s+"
        r"[A-Za-z_][A-Za-z0-9_]*\s*:\s*"
        r"WebInspectorFetchDescriptor\s*<\s*Model\s*>\s*\)\s*"
        r"async\s+throws\s*(?=\{)"
    ),
}

for description, pattern in required_controller_patterns.items():
    if not top_level_matches(pattern, controller_scope):
        errors.append(f"missing required fetched-results surface: {description}")


def has_top_level_setter(body: str) -> bool:
    setter = re.compile(
        r"(?:nonmutating\s+)?(?:set|willSet|didSet|_modify)\b"
        r"(?:\s*\([^{}]*\))?\s*\{"
    )
    return any(
        depth_at(body, match.start()) == 0
        for match in setter.finditer(body)
    )


def require_read_only_property(
    name: str,
    type_pattern: str,
    description: str,
) -> None:
    pattern = (
        r"\bpublic\s+"
        r"(?P<restricted_set>"
        r"(?:private|fileprivate|internal|package)\s*"
        r"\(\s*set\s*\)\s+)?"
        rf"var\s+{re.escape(name)}\s*:\s*{type_pattern}"
    )
    matches = top_level_matches(pattern, controller_scope)
    if not matches:
        errors.append(f"missing required fetched-results surface: {description}")
        return

    for match in matches:
        if match.group("restricted_set") is not None:
            return
        position = match.end()
        while position < len(controller_scope) and controller_scope[position].isspace():
            position += 1
        if position >= len(controller_scope) or controller_scope[position] != "{":
            continue
        closing = matching_brace(controller_scope, position)
        if closing is None:
            continue
        body = controller_scope[position + 1 : closing]
        if not has_top_level_setter(body):
            return

    errors.append(
        f"required fetched-results property is publicly settable: {description}"
    )


require_read_only_property(
    "fetchedObjects",
    r"\[\s*Model\s*\]\?",
    "read-only fetchedObjects",
)
require_read_only_property(
    "fetchDescriptor",
    r"WebInspectorFetchDescriptor\s*<\s*Model\s*>",
    "read-only fetchDescriptor",
)
require_read_only_property(
    "snapshot",
    r"WebInspectorFetchedResultsSnapshot\s*<\s*Model\.ID\s*>\?",
    "read-only snapshot",
)
require_read_only_property(
    "revision",
    r"WebInspectorFetchedResultsRevision\?",
    "read-only revision",
)
require_read_only_property(
    "fetchError",
    r"\(\s*any\s+Error\s*\)\?",
    "read-only fetchError",
)
require_read_only_property(
    "updates",
    r"WebInspectorFetchedResultsUpdateSequence\s*<\s*Model\.ID\s*>",
    "read-only nonfailing updates",
)

sequence_matches, sequence_regions = declaration_regions(
    r"\bpublic\s+struct\s+WebInspectorFetchedResultsUpdateSequence\s*<\s*"
    r"(?P<parameter>[A-Za-z_][A-Za-z0-9_]*)"
    r"(?:\s*:\s*[^,>{}]+)?\s*>[^{};]*\{"
)
sequence_parameters = [match.group("parameter") for match in sequence_matches]
if sequence_parameters != ["ItemID"] or len(sequence_regions) != 1:
    errors.append(
        "expected exactly one one-parameter declaration "
        "'struct WebInspectorFetchedResultsUpdateSequence<ItemID>'"
    )
else:
    item_constraints = " ".join(
        constraint
        for match in sequence_matches
        for constraint in re.findall(
            r"\bItemID\s*:\s*([^,>{}]*)",
            match.group(0),
        )
    )
    missing_constraints = [
        constraint
        for constraint in ("Hashable", "Sendable")
        if re.search(rf"\b{constraint}\b", item_constraints) is None
    ]
    if missing_constraints:
        errors.append(
            "WebInspectorFetchedResultsUpdateSequence.ItemID is missing "
            "constraints: " + ", ".join(missing_constraints)
        )
    sequence_scope = "\n".join(
        sequence_regions
        + extension_regions("WebInspectorFetchedResultsUpdateSequence")
    )
    if not top_level_matches(
        r"\bpublic\s+typealias\s+Failure\s*=\s*Never\b",
        sequence_scope,
    ):
        errors.append(
            "missing required fetched-results surface: "
            "update sequence Failure == Never"
        )

if errors:
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
if [[ ${frc_surface_status} -ne 0 ]]; then
    failure_count=$((failure_count + 1))
fi

deleted_paths=(
    "Docs/FetchedResultsActorIsolation.md"
    "Docs/WebInspectorKitsArchitecture.md"
    "Docs/WebInspectorModelArchitecture.md"
    "Sources/WebInspectorUI"
    "Sources/WebInspectorUISyntaxBody"
)
for deleted_path in "${deleted_paths[@]}"; do
    if [[ -e "${repo_root}/${deleted_path}" ]]; then
        echo "error: deleted architecture path still exists: ${deleted_path}" >&2
        failure_count=$((failure_count + 1))
    fi
done

for presentation_path in Sources/WebInspectorUIDOM Sources/WebInspectorUINetwork; do
    [[ -d "${repo_root}/${presentation_path}" ]] || continue
    proxy_import_matches=""
    proxy_import_status=0
    if proxy_import_matches="$(
        rg --line-number --with-filename --pcre2 \
            '(?m)^\s*(?:@testable\s+|@_exported\s+)?import\s+WebInspectorProxyKit\s*$' \
            "${repo_root}/${presentation_path}" 2>&1
    )"; then
        echo "error: ${presentation_path} imports WebInspectorProxyKit directly." >&2
        printf '%s\n' "${proxy_import_matches}" >&2
        failure_count=$((failure_count + 1))
    else
        proxy_import_status=$?
        if [[ ${proxy_import_status} -ne 1 ]]; then
            echo "error: ProxyKit import scan failed for ${presentation_path}." >&2
            printf '%s\n' "${proxy_import_matches}" >&2
            exit 2
        fi
    fi
done

temporary_dump=""
if [[ -z "${dump_package_json}" ]]; then
    if ! command -v swift >/dev/null 2>&1; then
        echo "error: swift is required when --dump-package-json is not supplied." >&2
        exit 2
    fi
    temporary_dump="$(mktemp -t webinspector-package-dump.XXXXXX)"
    trap 'rm -f "${temporary_dump}"' EXIT
    if ! (cd "${repo_root}" && swift package dump-package) >"${temporary_dump}"; then
        echo "error: swift package dump-package failed." >&2
        exit 2
    fi
    dump_package_json="${temporary_dump}"
else
    dump_package_json="$(cd "$(dirname "${dump_package_json}")" && pwd)/$(basename "${dump_package_json}")"
fi

package_graph_status=0
python3 - "${dump_package_json}" <<'PY' || package_graph_status=$?
import json
from pathlib import Path
import sys

dump_path = Path(sys.argv[1])
try:
    package = json.loads(dump_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    print(f"error: cannot read package dump JSON: {error}", file=sys.stderr)
    raise SystemExit(2)


def condition_key(condition: object) -> str:
    if condition is None:
        return "*"
    if not isinstance(condition, dict):
        return json.dumps(condition, sort_keys=True, separators=(",", ":"))
    platforms = condition.get("platformNames")
    if set(condition) == {"platformNames"} and isinstance(platforms, list):
        return "[" + ",".join(sorted(str(platform).lower() for platform in platforms)) + "]"
    return json.dumps(condition, sort_keys=True, separators=(",", ":"))


def dependency_key(dependency: object) -> str:
    if not isinstance(dependency, dict) or len(dependency) != 1:
        return "invalid:" + json.dumps(dependency, sort_keys=True)
    kind, payload = next(iter(dependency.items()))
    if not isinstance(payload, list):
        return "invalid:" + json.dumps(dependency, sort_keys=True)
    if kind in {"byName", "target"} and len(payload) >= 2:
        return f"target:{payload[0]}@{condition_key(payload[1])}"
    if kind == "product" and len(payload) >= 4:
        return (
            f"product:{payload[0]}@{payload[1]}@"
            f"{condition_key(payload[3])}"
        )
    return "invalid:" + json.dumps(dependency, sort_keys=True)


expected_dependencies = {
    "WebInspectorNativeBridgeObjC": set(),
    "WebInspectorNativeBridge": {
        "target:WebInspectorNativeBridgeObjC@*",
        "product:MachOKit@MachOKit@*",
    },
    "WebInspectorProxyKit": {"target:WebInspectorNativeBridge@*"},
    "WebInspectorProxyKitTesting": {"target:WebInspectorProxyKit@*"},
    "WebInspectorDataKitMacros": {
        "product:SwiftCompilerPlugin@swift-syntax@*",
        "product:SwiftSyntax@swift-syntax@*",
        "product:SwiftSyntaxBuilder@swift-syntax@*",
        "product:SwiftSyntaxMacros@swift-syntax@*",
    },
    "WebInspectorDataKit": {
        "target:WebInspectorProxyKit@*",
        "target:WebInspectorDataKitMacros@*",
    },
    "WebInspectorDataKitTesting": {
        "target:WebInspectorDataKit@*",
        "target:WebInspectorProxyKit@*",
        "target:WebInspectorProxyKitTesting@*",
    },
    "WebInspectorSwiftUI": {"target:WebInspectorDataKit@*"},
    "WebInspectorUIBase": set(),
    "WebInspectorUIDOM": {
        "target:WebInspectorDataKit@*",
        "target:WebInspectorUIBase@*",
        "product:ObservationBridge@ObservationBridge@*",
        "product:UIHostingMenu@UIHostingMenu@[ios]",
    },
    "WebInspectorUINetwork": {
        "target:WebInspectorDataKit@*",
        "target:WebInspectorUIBase@*",
        "product:ObservationBridge@ObservationBridge@*",
        "product:UIHostingMenu@UIHostingMenu@[ios]",
        "product:SyntaxEditorUI@SyntaxEditorUI@[ios]",
    },
    "WebInspectorKit": {
        "target:WebInspectorProxyKit@*",
        "target:WebInspectorDataKit@*",
        "target:WebInspectorUIBase@*",
        "target:WebInspectorUIDOM@*",
        "target:WebInspectorUINetwork@*",
        "product:ObservationBridge@ObservationBridge@*",
    },
    "WebInspectorUIPreviews": {
        "target:WebInspectorDataKit@*",
        "target:WebInspectorDataKitTesting@*",
        "target:WebInspectorUIDOM@*",
        "target:WebInspectorUINetwork@*",
    },
    "WebInspectorTestSupport": {
        "target:WebInspectorProxyKit@*",
        "target:WebInspectorProxyKitTesting@*",
    },
    "WebInspectorProxyKitTests": {
        "target:WebInspectorProxyKit@*",
        "target:WebInspectorProxyKitTesting@*",
        "target:WebInspectorTestSupport@*",
    },
    "WebInspectorDataKitTests": {
        "target:WebInspectorProxyKit@*",
        "target:WebInspectorProxyKitTesting@*",
        "target:WebInspectorDataKit@*",
        "target:WebInspectorDataKitTesting@*",
        "target:WebInspectorTestSupport@*",
    },
    "WebInspectorDataKitMacroTests": {
        "target:WebInspectorDataKitMacros@*",
        "product:SwiftSyntaxMacrosTestSupport@swift-syntax@*",
    },
    "WebInspectorSwiftUITests": {
        "target:WebInspectorDataKit@*",
        "target:WebInspectorDataKitTesting@*",
        "target:WebInspectorSwiftUI@*",
    },
    "WebInspectorUITests": {
        "target:WebInspectorProxyKit@*",
        "target:WebInspectorProxyKitTesting@*",
        "target:WebInspectorDataKit@*",
        "target:WebInspectorDataKitTesting@*",
        "target:WebInspectorUIBase@*",
        "target:WebInspectorUIDOM@*",
        "target:WebInspectorUINetwork@*",
        "target:WebInspectorKit@*",
        "target:WebInspectorUIPreviews@*",
        "target:WebInspectorTestSupport@*",
        "product:SyntaxEditorUI@SyntaxEditorUI@[ios]",
    },
}

expected_types = {
    name: "test" if name.endswith("Tests") else "regular"
    for name in expected_dependencies
}
expected_types["WebInspectorDataKitMacros"] = "macro"

targets = package.get("targets")
if not isinstance(targets, list):
    print("error: package dump has no targets array.", file=sys.stderr)
    raise SystemExit(2)

targets_by_name: dict[str, dict] = {}
duplicate_names: set[str] = set()
for target in targets:
    if not isinstance(target, dict) or not isinstance(target.get("name"), str):
        print("error: package dump contains a malformed target.", file=sys.stderr)
        raise SystemExit(2)
    name = target["name"]
    if name in targets_by_name:
        duplicate_names.add(name)
    targets_by_name[name] = target

errors: list[str] = []
if duplicate_names:
    errors.append("duplicate targets: " + ", ".join(sorted(duplicate_names)))

expected_names = set(expected_dependencies)
actual_names = set(targets_by_name)
missing = expected_names - actual_names
unexpected = actual_names - expected_names
if missing:
    errors.append("missing targets: " + ", ".join(sorted(missing)))
if unexpected:
    errors.append("unexpected targets: " + ", ".join(sorted(unexpected)))

for name in sorted(expected_names & actual_names):
    target = targets_by_name[name]
    actual_type = target.get("type")
    if actual_type != expected_types[name]:
        errors.append(
            f"{name} type mismatch: expected {expected_types[name]!r}, "
            f"found {actual_type!r}"
        )
    raw_dependencies = target.get("dependencies")
    if not isinstance(raw_dependencies, list):
        errors.append(f"{name} has no dependencies array")
        continue
    actual_dependencies = {dependency_key(item) for item in raw_dependencies}
    expected = expected_dependencies[name]
    missing_dependencies = expected - actual_dependencies
    unexpected_dependencies = actual_dependencies - expected
    if missing_dependencies:
        errors.append(
            f"{name} missing direct dependencies: "
            + ", ".join(sorted(missing_dependencies))
        )
    if unexpected_dependencies:
        errors.append(
            f"{name} has unexpected direct dependencies: "
            + ", ".join(sorted(unexpected_dependencies))
        )

products = package.get("products")
if not isinstance(products, list):
    errors.append("package dump has no products array")
else:
    expected_products = {
        "WebInspectorProxyKit": ("WebInspectorProxyKit",),
        "WebInspectorProxyKitTesting": ("WebInspectorProxyKitTesting",),
        "WebInspectorDataKit": ("WebInspectorDataKit",),
        "WebInspectorDataKitTesting": ("WebInspectorDataKitTesting",),
        "WebInspectorSwiftUI": ("WebInspectorSwiftUI",),
        "WebInspectorKit": ("WebInspectorKit",),
    }
    actual_products: dict[str, tuple[str, ...]] = {}
    for product in products:
        if isinstance(product, dict) and isinstance(product.get("name"), str):
            product_targets = product.get("targets")
            if isinstance(product_targets, list):
                actual_products[product["name"]] = tuple(product_targets)
    if actual_products != expected_products:
        for name in sorted(set(expected_products) | set(actual_products)):
            if actual_products.get(name) != expected_products.get(name):
                errors.append(
                    f"product {name} targets mismatch: expected "
                    f"{expected_products.get(name)!r}, found "
                    f"{actual_products.get(name)!r}"
                )

for removed_target in ("WebInspectorUI", "WebInspectorUISyntaxBody"):
    if removed_target in actual_names:
        errors.append(f"removed target remains: {removed_target}")

for presentation_target in ("WebInspectorUIDOM", "WebInspectorUINetwork"):
    target = targets_by_name.get(presentation_target)
    if target is None:
        continue
    direct = {dependency_key(item) for item in target.get("dependencies", [])}
    if "target:WebInspectorProxyKit@*" in direct:
        errors.append(f"forbidden edge: {presentation_target} -> WebInspectorProxyKit")

swiftui = targets_by_name.get("WebInspectorSwiftUI")
if swiftui is not None:
    repository_targets = {
        dependency.removeprefix("target:").split("@", 1)[0]
        for dependency in (
            dependency_key(item) for item in swiftui.get("dependencies", [])
        )
        if dependency.startswith("target:")
    }
    if repository_targets != {"WebInspectorDataKit"}:
        errors.append(
            "forbidden WebInspectorSwiftUI repository edges: "
            + ", ".join(sorted(repository_targets - {"WebInspectorDataKit"}))
        )

for product in products if isinstance(products, list) else []:
    if not isinstance(product, dict):
        continue
    if "WebInspectorDataKitMacros" in product.get("targets", []):
        errors.append(
            "host-only WebInspectorDataKitMacros must not be a library product target"
        )

if errors:
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
if [[ ${package_graph_status} -ne 0 ]]; then
    if [[ ${package_graph_status} -eq 2 ]]; then
        exit 2
    fi
    failure_count=$((failure_count + 1))
fi

if [[ ${failure_count} -ne 0 ]]; then
    echo "Removed-architecture verification failed (${failure_count} check groups)." >&2
    exit 1
fi

echo "Removed-architecture symbols, public FRC surface, deleted paths, and target DAG verified."
