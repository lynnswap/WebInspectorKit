# Codex Task Prompt — Execute the WebInspectorKit SDK-Surface Rearchitecture

Copy everything below the line into the Codex task. It assumes the repo
contains `Docs/Rearchitecture/` (this directory) at the task's base commit.

---

You are executing a pre-approved rearchitecture of this repository
(WebInspectorKit). The analysis and the target design are already done and
committed under `Docs/Rearchitecture/`. Your job is to make the codebase match
the design — not to redesign it.

## Read first, in this order

1. `Docs/Rearchitecture/01-scope-contract.md` — goal, non-goals, resolved
   design forks, declared deviations.
2. `Docs/Rearchitecture/02-findings.md` — numbered findings (F-01…F-39);
   the quantitative claims are the acceptance baselines.
3. `Docs/Rearchitecture/03-design-doc.md` — **the design contract.** Design
   elements E1–E14 are indexed at the top; target package graph (§1), public
   API sketch (§2 — note the `(existing)`/`(new)` notation rules and the
   E5 rename table in §2.9), consumer stories (§3), access plan (§4),
   variation axes + E6/E7 precise scopes (§5), deletion list (§6), Avoided
   Shapes (§7), test plan (§8), finding-response table (§9).
4. `Docs/Rearchitecture/measurements/` — raw evidence with file:line cites;
   consult when a claim needs verification.
5. Repo context: `Docs/ArchitectureOverview.md`, `Docs/MIGRATION.md`,
   `Sources/WebInspectorCore/README.md`, root `AGENTS.md`,
   `.github/workflows/ci.yml`.

## Contract rules

- 03-design-doc.md is binding. `(existing)` = keep the current declaration
  shape (verified against the code — if you find a residual mismatch, the
  CODE shape wins and you note it in the PR). `(new)`/`(new shape)` = the
  written signature is binding. Renames: only the §2.9 table.
- **Transitive closure rule (03 §2.8):** every type reachable from a public
  member must be enumerated in §2. If implementing a listed member would drag
  an unlisted type public, that is an escalation — do not silently publish or
  silently demote.
- **Escalate instead of improvising** when: a design element cannot be
  implemented as written, a §2 member turns out unreachable under the §4
  reachability rule, a §6 deletion looks unsafe, or the closure rule above
  fires. Escalation = record the conflict in the PR description under
  "Design deviations required" and continue with independent items. **If the
  blocked item is a prerequisite of later steps (e.g. step 3's inversion),
  stop the migration at the last green step, open the draft PR with the
  completed steps and the deviations section, and do not attempt the
  dependent steps.**
- §7 Avoided Shapes are hard constraints: no `@_exported import`, no
  `@_disfavoredOverload`, no `InspectorSession`/`WebInspectorUI` compat
  aliases, no public raw envelopes/method strings, no enum smuggling
  transport types through associated values, no `@testable` in ContractTests.
- Out of scope (do NOT do, even if tempting — tracked separately): protocol
  method-string constants / target-commit single owner (F-12, F-13), shared
  staleness primitive (F-16), preview fake-backend rework (F-18), `#if DEBUG`
  test-observability owner (F-19), internal decomposition of
  DOMSession/TransportSession/WebInspector beyond what §5 specifies (F-25,
  F-39), any AppKit UI, any remote/WebSocket transport, DOM render-diff API
  publication.

## Migration order

Work on a branch off `main`. Each numbered step must end with the package
building and the Validation suite green before the next step starts. Use one
commit (or a few cohesive commits) per step, Conventional Commits style, no
amends.

1. **Baseline + characterization.** Run the Validation suite once and record
   results (including a clean-build wall-clock time for the build-time note
   in 03). Repair the SwiftPM `WebInspectorKit` scheme's testables while you
   are here (it lists a nonexistent `WebInspectorRuntimeTests` and omits
   `WebInspectorNativeTransportTests` —
   `.swiftpm/xcode/xcshareddata/xcschemes/WebInspectorKit.xcscheme`). Then
   add the missing characterization tests from design §8. Note: the phase
   enum is `private` today — pre-change characterization asserts the
   observable proxies (`hasActiveConnection` flips, `lastError` on failure,
   detach idempotence, cancelled-attach recovery); the full
   `WebInspector.state` assertions are added in step 6 and replace the
   proxies. Semantic input→output assertions only.
2. **Move `TransportReceiver`** from WebInspectorCoreSupport into the
   WebInspectorTransport target (design §1; verified: it imports only
   Synchronization + WebInspectorTransport, and only 3 files reference it).
3. **Invert the native-attach dependency (E4).** Implement the two-stage
   package factory in WebInspectorNativeTransport exactly per design §2.1
   (`resolveSymbols()` fail-fast before any teardown; `makeComponents(...)`
   after teardown; fatal-failure sink; NT-local error type replacing
   `NativeInspectablePage`'s use of `InspectorSession.Error`). Move the
   attach orchestration from `InspectorSession+NativeAttachment.swift` into
   the **WebInspectorCore umbrella target** (where `InspectorSession` lives
   at this step) as an internal flow — not into the session type's body
   (F-39 facade discipline). Core depends on NativeTransport; NativeTransport
   stops importing Core. The seven staging APIs drop to internal (deletion
   #5). Refocus `WebInspectorNativeTransportTests` on the factory.
4. **Merge the four Core sub-targets** into `Sources/WebInspectorCore/`
   keeping domain subdirectories; delete the `@_exported` block; update
   Package.swift and test imports (`@testable import WebInspectorCore`
   replaces the 5-module imports). Apply deletion #11 (E10 hygiene).
5. **Merge WebInspectorUI into WebInspectorKit.** Move the 12 UI files into
   the Kit target; delete `WebInspectorKit.swift` and
   `WebInspectorNativeAttachment.swift`; delete both `@_disfavoredOverload`
   decoys + `AttachmentUnavailableError`; give `WebInspectorSession` and
   `WebInspectorViewController` each ONE real forwarding
   `attach(to:)`/`detach()` (design §2.7 — the VC keeps attach; the root
   README attaches via the VC). Remove the four products per deletion #6.
   Package.swift must now match the §1 diagram exactly (including the
   dashed preview-fixture edges and intra-UI edges).
6. **Public surface pass (E2, E3, E5, E11, E12).** Rename `InspectorSession`
   → `WebInspector` (no alias; 9 source + 3 test files reference it, Monocly
   does not); implement `WebInspector.State` per §2.1 (state owned by the
   attach/detach orchestration — `.attaching` starts when `attach()` is
   entered); promote exactly the §2 enumerations with the §2.8 opaque-ID
   doctrine and §2.9 renames; implement the new Console
   (`clearMessages()`) and Runtime (`evaluate` with
   `RuntimeEvaluationResult.isException` from wasThrown, `properties(of:)`
   with live child objects, `executionContexts` aggregate) APIs and the CSS
   `Phase`/`UnavailableReason` re-shape; add `@MainActor` to the CSS
   observable classes; expose `WebInspectorSession.inspector` +
   `init(inspector:tabs:)`. Upgrade the step-1 lifecycle characterization to
   the full `state` contract.
7. **Consolidations (E6, E7, E13, E8 + deletions #7-#10, #12).**
   `DomainChannelBinding` + participant registration per §5 precise scope
   (triplet 3→2 stored props per session; `requireChannel()` owns the
   unwrap-throw; no `commandChannel?.requireAttached()` no-op shapes);
   single DOM intent→method map; single `BuiltInCatalog`; delete the
   UI-side `InspectorSession(attachment:)` fabrication and migrate
   `inspector.attachment.dom.*` chains; rename
   `retireBackendInteractionForPresentationEnd` →
   `suspendBackendInteraction()`; relocate `StatusSeverity` per §2.3 E8.
8. **Consumers + contract tests (E9, E14).** Create the standalone
   `ContractTests/` SwiftPM package — package name
   `WebInspectorKitContractTests` (SwiftPM auto-generates the
   `WebInspectorKitContractTests-Package` scheme from it; confirm with
   `xcodebuild -list` inside `ContractTests/`) — with a path dependency
   `"../"` on the repo root; plain `import WebInspectorCore` /
   `import WebInspectorKit`; zero `@testable`. Story B tests are
   platform-neutral and run under `swift test`. Stories A/A2 touch
   UIKit-gated API: put them in `#if canImport(UIKit)` files and run them on
   an iOS simulator via `xcodebuild test` — `swift test` alone does NOT
   prove A/A2. Add the working custom Console tab to Monocly using public
   API only (story A2 code shape). Fix the root README Quick Start so both
   snippets compile as written; update `Docs/MIGRATION.md` (new release
   section) and `Docs/ArchitectureOverview.md` (new module map + fold in
   design §7). CI: extend `.github/workflows/ci.yml` — add to the
   `WebInspectorKitTests` matrix job (macos-26/iOS 26) a step that runs the
   ContractTests iOS tests against the already-resolved `$DESTINATION`, and
   a cheap `swift test --package-path ContractTests` step for story B; reuse
   the workflow's existing Xcode/simulator resolution, do not invent a new
   job matrix.
9. **Acceptance re-measurement + report** (commands below).

## Validation (every step)

```sh
# Test gates — the two workspace schemes CI runs (.github/workflows/ci.yml):
xcodebuild test -workspace WebInspectorKit.xcworkspace \
  -scheme WebInspectorNativeTests \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'
xcodebuild test -workspace WebInspectorKit.xcworkspace \
  -scheme WebInspectorKitTests \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'

# macOS build must stay green (story B platform claim):
swift build

# From step 8 on:
swift test --package-path ContractTests                      # story B (macOS)
( cd ContractTests && xcodebuild test \
    -scheme WebInspectorKitContractTests-Package \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' )  # stories A/A2 (verify scheme via xcodebuild -list)
xcodebuild build -project Monocly/Monocly.xcodeproj -scheme Monocly \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'
```

## Acceptance re-measurement (step 9 — run each, report before/after)

```sh
# Public surface & products
rg -c '@_exported import' Sources                                    # 5 → 0
rg -c '@_disfavoredOverload' Sources                                 # 2 → 0
rg -n '^\s*(@[A-Za-z_@() .:,]+\s+)*(public|open)\s+(final\s+)?(class|struct|actor|enum|protocol|func|var|let|init|typealias|subscript|extension)' Sources -g '*.swift' | wc -l
#   32 → the §2 enumeration; attach the full list and diff it against §2
# products: read Package.swift                                        # 6 → 2

# Access distribution per target (02 F-01 baseline table)
for t in Sources/*/; do echo "== $t"; rg -o '\b(public|package|open)\b' "$t" -g '*.swift' --no-filename | sort | uniq -c; done

# Axis / duplication counters
rg -n 'guard commandChannel != nil|guard let commandChannel' Sources # 14 → 0 hand-rolled
rg -n --fixed-strings '"Inspector session is not attached."' Sources # 10 → 1 (the requireChannel owner)
rg -n 'teardownCommandMethodName' Sources                            # duplicate map gone
rg -n 'func bindProtocolChannel' Sources                             # 6 → 1 (participant protocol)
rg -nF 'builtIn == nil' Sources ; rg -nF 'builtIn != nil' Sources    # F-17 baseline 3+2
rg -c '^#if (canImport|os)\(' Sources -g '*.swift'                   # not increased; F-23 mid-file smell gone
rg -o '@testable import \w+' Tests ContractTests -g '*.swift' | wc -l # Tests baseline 134; ContractTests contributes 0

# God-type stored props (baseline table: measurements/measure-god-types.md)
# count stored properties of DOMSession, WebInspector, NetworkSession,
# ConsoleSession, RuntimeState, CSSSession — report before/after
```

## Acceptance criteria (file moves alone do not satisfy these)

- Products = exactly `WebInspectorCore` + `WebInspectorKit` with the §2
  surfaces; zero `@_exported`; zero `@_disfavoredOverload`. (Kit's
  macOS-empty module is the accepted residual declared in 01.)
- Public declarations match the §2 enumeration under the §4 reachability
  rule; the public-API diff is attached to the PR; unplanned publics are
  demoted **and reported**.
- Stories A, A2, B compile and pass from outside the package (ContractTests
  on both platforms as specified); both README snippets compile as written;
  `WebInspectorViewController.attach(to:)` still exists and works.
- Old paths deleted per §6 — no shims, no parallel legacy surface.
- **First-consumer call-site simplification reported** (rearchitect-skill
  criterion): before/after of the F-33 sites — the 7
  `inspector.attachment.dom.*` chains, the
  `DOMSplitViewController.init(inspection:)` fabrication, and the
  NetworkTabController round-trip — with the §3 story-A table.
- Variant-addition traces reported for each §5 axis using the honest counts
  written there (the domain axis is "1 file + ~4 declaration lines + 1
  block", not "1 file + 1 registration").
- State-ownership movement reported: stored-prop before/after per the
  re-measurement block (E6 must show 3→2 triplet props per domain session;
  the staging SPI internalized; `WebInspector` body did not absorb the
  attach orchestration — F-39).
- Platform criterion per 01's declared deviation: gate count not increased,
  no new mid-file branches, F-23 resolved.
- Clean-build wall-clock before/after reported (fork 1 build-time note).

## Final report / PR

Branch + draft PR to `main`, title and body in English. Body must contain:
purpose (the three scope outcomes), diff-based change summary per migration
step, the acceptance-criteria table with measured before/after numbers, the
variant-addition traces, characterization-test ↔ contract mapping,
validation command output summaries, and a "Design deviations required"
section (empty if none). Do not report line-count deltas as an outcome;
report restored invariants and newly possible consumer stories.
