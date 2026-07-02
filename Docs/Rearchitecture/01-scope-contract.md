# Scope Contract — WebInspectorKit SDK Surface Rearchitecture

Status: approved by owner (2026-07-02, chat). Deviations from this contract are
escalations, not judgment calls.

## Goal, stated as outcomes

1. **Custom inspector tabs can reach domain state.** An app-provided
   `WebInspectorTab` (e.g. a Console tab) can observe and command the
   DOM / Network / Console / Runtime domain sessions of the inspected page
   through public API — the README Quick Start example becomes actually
   implementable.
2. **A second app can consume the inspector core without the built-in UI.**
   A planned (not yet started) second app can `import WebInspectorCore` and
   attach / observe / command an inspected `WKWebView` with its own
   presentation, without importing `WebInspectorUI`.
3. **The public products stop being empty modules.** Every library product
   either ships a designed public surface reachable from a consumer story, or
   is demoted to an internal target (removed from `products:`).

"Cleaner" is not a goal. Every design element must trace to one of the three
outcomes above or to a numbered finding in
[02-findings.md](02-findings.md).

## Compatibility policy

- **Breaking changes are allowed.** The only known consumers are in-repo
  (Monocly example app, built-in UI targets) plus README snippets. All in-repo
  consumers are migrated in the same change series; README / MIGRATION.md are
  updated in the same series.
- External contract to preserve: the drop-in UIKit story
  (`WebInspectorViewController` + `WebInspectorSession.attach(to:)`) keeps
  working for existing app code with at most mechanical migration, documented
  in `Docs/MIGRATION.md`.
- No compatibility alias layer, no parallel legacy surface
  (per `Docs/ArchitectureOverview.md` Avoided Shapes).

## Consumers

- **First consumer:** the built-in UI (`WebInspectorUI*` targets) and the
  Monocly example app.
- **Second consumer:** a planned app exists but is not started (owner-confirmed
  2026-07-02). Because the goal is reusability, a **proxy consumer is
  mandatory**: a contract-test target that imports only the public library
  products, never uses `@testable`, and compiles the consumer stories from the
  design doc. The Monocly app additionally gains a custom tab that consumes
  domain state through public API only.

## Non-goals

- **UI-internal decomposition.** `DOMTreeTextView.swift` (2,923 lines) and
  other `WebInspectorUI*`-internal god files are out of scope; they are behind
  the UI boundary and do not block any of the three outcomes. Track separately.
- **AppKit UI implementation.** We do not build the AppKit inspector UI. The
  redesign must, however, not entrench UIKit types into the Core public
  surface (platform axis stays at the target boundary).
- **New transport implementations.** No remote/WebSocket transport is built.
  The design only has to leave transport as a designed seam if the measurement
  shows the seam already half-exists; building a second transport is not in
  scope.
- **Protocol coverage expansion.** No new Web Inspector protocol domains or
  features. Same capabilities, redesigned ownership and surface.

## Resolved design forks (proposed 2026-07-02 — review at design gate)

These three forks were resolved by the analysis with the rationale below. They
are design-gate review points: overriding any of them invalidates the matching
sections of [03-design-doc.md](03-design-doc.md).

1. **Core sub-target split → merge into a single `WebInspectorCore` target.**
   Measured: the 4-way split has zero import-boundary meaning (43 consumer
   files import the umbrella, 0 import a sub-target; `@_exported` erases the
   boundary — finding F-03) and the domains are type-entangled anyway
   (F-29, F-30). Cost: loses intra-Core build parallelism from commit
   `0118f24b` (the larger Core-vs-UI split survives — UI targets stay
   separate). Alternative (rejected): keep 4 sub-targets and design 4 public
   surfaces — forces consumers to learn an internal taxonomy and either
   re-introduces `@_exported` or multiplies import statements.
2. **Transport stays package-internal; no public transport axis.** No second
   transport consumer exists or is planned (scope contract), so publishing
   `TransportBackend` + envelope types would be speculative generalization.
   The empty products are demoted instead (design doc §1). The half-duplex
   seam asymmetry (F-37) is recorded, not redesigned.
3. **Decomposition depth: access-boundary + shared-owner extraction only.**
   The public/package split, the channel-binding owner (F-26), and the
   attachment-precondition owner (F-14) are in scope because they sit on the
   new surface. Full internal decomposition of DOMSession (F-25) /
   TransportSession / the lifecycle owner's internals (F-39 —
   `InspectorSession`→`WebInspector`) and the remaining axis leaks (F-12,
   F-13, F-16, F-19) are deferred with tracked follow-ups (design doc §9) —
   they do not block the three outcomes. The design doc's facade discipline
   (§2.1 internal-owner note) prevents the deferral from making F-39 worse.

## Degraded-mode declarations (per rearchitect skill)

- Full Phase 1 measurement applies, including product-surface reality checks.
- The second consumer does not exist yet, but the goal is reusability, so the
  degraded "first consumer only" mode is **not** used; the proxy consumer
  (contract tests + Monocly custom tab) stands in (Phase 0 rule).
- **Declared deviation — platform-gate acceptance criterion.** The skill's
  default criterion expects the `#if canImport/#if os` count to *decrease*.
  Here the UI layer intentionally stays UIKit-only (non-goal: no AppKit UI),
  so its whole-file gates remain. The criterion for this series is: no new
  mid-file platform branches, total gate count not increased, and the one
  measured mid-file smell (F-23, `NetworkStatusSeverity.swift`) resolved.
  The `WebInspectorKit` product remaining an empty module on macOS is an
  accepted residual (SwiftPM cannot scope products per platform — design doc
  §1).
