# WebInspectorCore

`WebInspectorCore` is the inspector session and semantic model target for the WebInspector stack.

The target models WebKit protocol concepts before they reach UIKit presentation code. `WebInspectorTransport` owns raw JSON transport and target multiplexing; Core owns attached inspection orchestration, domain protocol dispatching, and semantic event application.

## Goals

- Model WebKit protocol concepts directly, starting with DOM and Network.
- Keep page, frame, document, protocol target, execution context, and DOM node identities explicit.
- Treat iframe documents as frame-document projections, not regular DOM children.
- Treat Network redirects as request history, not separate request identities.
- Make iframe refresh and cross-origin selection behavior testable without UIKit/TextKit2.
- Avoid compatibility paths from removed `v0.1.x` DOM APIs.

## Domain Notes

- [Transport research](Docs/TransportResearch.md)
- [DOM model research](Docs/DOMModelResearch.md)
- [CSS model research](Docs/CSSModelResearch.md)
- [Network model research](Docs/NetworkModelResearch.md)
- [Console transport research](Docs/ConsoleTransportResearch.md)
- [WebInspector architecture overview](../../Docs/ArchitectureOverview.md)

## Model Boundary

Mutable model classes are `@MainActor @Observable` so the native UI can observe the same semantic source of truth directly. Expensive work must stay outside this boundary:

- raw transport I/O
- target message multiplexing
- search/tokenization/markup generation

The model should apply domain protocol payloads into semantic state and produce Sendable snapshots/command intents. Protocol command/result/event implementation lives next to each domain as `*Protocol+Dispatching.swift`; do not add cross-domain adapter buckets.

## Tests

Run the headless WebInspector core tests with:

```sh
swift test --filter WebInspectorCoreTests
```
