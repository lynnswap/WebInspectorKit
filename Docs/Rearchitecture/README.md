# WebInspectorKit SDK-Surface Rearchitecture — Working Set

Produced 2026-07-02 (baseline commit `45c6d880`) following the
`rearchitect` workflow (measure → design gate → delegate). Implementation is
delegated to Codex; these documents are the design contract.

| Doc | Role |
| --- | --- |
| [01-scope-contract.md](01-scope-contract.md) | Phase 0 — outcomes, compatibility policy, consumers, non-goals, resolved design forks |
| [02-findings.md](02-findings.md) | Phase 1 — numbered measured findings F-01…F-39 (baselines for acceptance re-measurement) |
| [03-design-doc.md](03-design-doc.md) | Phase 2 — design gate document: target graph, public API sketch, consumer stories, access plan, deletion list, Avoided Shapes, test plan, finding-response table |
| [04-codex-prompt.md](04-codex-prompt.md) | Delegation prompt — copy into the Codex task as-is |
| [measurements/](measurements/) | Raw measurement reports (10) with evidence tables and re-measure commands |

Headline: the package currently exposes **3 public types (32 declarations)
against 2,376 package declarations**; 3 of 6 library products are empty
modules; custom tabs receive a session with zero domain access; attach works
only via an `@_exported` + `@_disfavoredOverload` umbrella trick. The design
collapses this to 2 products (`WebInspectorCore` engine — iOS+macOS,
`WebInspectorKit` UIKit UI) with a designed public surface, unlocking custom
tabs, a headless second app, and a future AppKit UI.

Lifecycle: after the migration lands, fold §7 (Avoided Shapes) and the new
module map into `Docs/ArchitectureOverview.md`, then this directory can be
deleted or archived.
