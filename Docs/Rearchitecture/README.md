# WebInspectorKit SDK-Surface Rearchitecture — Working Set

Produced 2026-07-02 (baseline commit `45c6d880`) following the
`rearchitect` workflow (measure → design gate → delegate). Implementation is
delegated to Codex; these documents are the design contract.

| Doc | Role |
| --- | --- |
| [01-scope-contract.md](01-scope-contract.md) | Phase 0 — outcomes, compatibility policy, consumers, non-goals, resolved design forks |
| [02-findings.md](02-findings.md) | Phase 1 — numbered measured findings F-01…F-39 (baselines for acceptance re-measurement) |
| [03-design-doc.md](03-design-doc.md) | Phase 2 (v1) — promote the `@Observable` god-model to a 2-product public surface. **Superseded on the public-surface question by 05.** |
| [04-codex-prompt.md](04-codex-prompt.md) | Retired delegation prompt for the 03 direction. Do not use for implementation. |
| [05-two-layer-sdk-design.md](05-two-layer-sdk-design.md) | Phase 2 (v2) — the current direction: split into `WebViewProxyKit` (typed streams/commands) + `WebViewDataKit` (SwiftData/CoreData-style models), CodexKit-style. Keeps 01/02 as inputs. |
| [measurements/](measurements/) | Raw measurement reports (10) with evidence tables and re-measure commands |

Headline: the package currently exposes **3 public types (32 declarations)
against 2,376 package declarations**; 3 of 6 library products are empty
modules; custom tabs receive a session with zero domain access; attach works
only via an `@_exported` + `@_disfavoredOverload` umbrella trick. The current
design splits the SDK into `WebViewProxyKit` (typed commands/events),
`WebViewDataKit` (observable domain models), `WebViewProxyKitTesting`
(deterministic fake runtime), and `WebInspectorKit` (UIKit drop-in UI),
unlocking custom tabs, a headless second app, and a future AppKit UI.

Lifecycle: after the migration lands, fold §7 (Avoided Shapes) and the new
module map into `Docs/ArchitectureOverview.md`, then this directory can be
deleted or archived.
