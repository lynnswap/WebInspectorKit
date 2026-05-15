# V2_WebInspectorCore

`V2_WebInspectorCore` is the package-internal semantic model target for the V2 inspector stack.

The target models WebKit protocol concepts before they reach UIKit presentation code. Runtime and transport targets decode protocol traffic and apply semantic events here.

## Goals

- Model WebKit protocol concepts directly, starting with DOM and Network.
- Keep page, frame, document, protocol target, execution context, and DOM node identities explicit.
- Treat iframe documents as frame-document projections, not regular DOM children.
- Treat Network redirects as request history, not separate request identities.
- Make iframe refresh and cross-origin selection behavior testable without UIKit/TextKit2.
- Avoid compatibility paths from the old WebView-rendered DOM tree.

## Domain Notes

- [Transport research](Docs/TransportResearch.md)
- [DOM model research](Docs/DOMModelResearch.md)
- [Network model research](Docs/NetworkModelResearch.md)
- [WebInspector V2 architecture overview](../../Docs/V2ArchitectureOverview.md)

## Model Boundary

Mutable model classes are `@MainActor @Observable` so the native UI can observe the same semantic source of truth directly. Expensive work must stay outside this boundary:

- raw transport I/O
- JSON parsing
- protocol payload decoding
- search/tokenization/markup generation

The model should only apply already-decoded semantic events and produce Sendable snapshots/command intents.

## Tests

Run the headless V2 core tests with:

```sh
swift test --filter V2_WebInspectorCoreTests
```
