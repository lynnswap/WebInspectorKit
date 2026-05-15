# WebInspector Architecture Overview

This document is an orientation map for the current WebInspector inspector stack. It
focuses on module boundaries, runtime ownership, and transport flow. Detailed
UIKit containment and view-controller wiring lives in
[`UIIntegration.md`](../Sources/WebInspectorUI/Docs/UIIntegration.md).

The package now exposes the same WebInspector-named modules and types internally
and publicly. There is no parallel legacy implementation target and no
compatibility alias layer between the public API and the active implementation.

## Naming Surface

| Public / final name | Role |
| --- | --- |
| `WebInspectorSession` | UI-facing session and lifecycle owner |
| `WebInspectorViewController` | UIKit inspector container |
| `WebInspectorTab` | Public tab descriptor |
| `WebInspectorRuntime` | Session assembly target |
| `WebInspectorTransport` | Protocol command/reply and target multiplexing |
| `WebInspectorCore` | DOM/Network semantic model target |
| `WebInspectorNativeBridge` | Raw native inspector JSON bridge |
| `WebInspectorNativeSymbols` | Native symbol resolution for attach bootstrap |

`WebInspectorUI` is the UIKit implementation target. `WebInspectorKit` is the
app-facing umbrella product that re-exports the UI surface.

## Layer Overview

```mermaid
flowchart TD
    Host["Host app / WKWebView"]
    UI["WebInspectorUI<br/>current UIKit UI"]
    PublicSession["WebInspectorSession<br/>public session owner"]
    Runtime["InspectorSession<br/>current runtime owner"]
    Core["WebInspectorCore<br/>DOMSession + NetworkSession"]
    Transport["WebInspectorTransport<br/>target multiplexing + replies"]
    Bridge["WebInspectorNativeBridge<br/>raw JSON bridge"]
    Symbols["WebInspectorNativeSymbols<br/>symbol addresses for attach"]
    WebKit["WebKit private inspector backend"]

    Host --> UI
    UI --> PublicSession
    PublicSession --> Runtime
    Runtime --> Core
    Runtime --> Transport
    Transport --> Bridge
    Bridge --> WebKit
    Symbols --> Bridge
```

Responsibilities stay intentionally narrow:

- `WebInspectorNativeBridge`: attach, send raw JSON, receive raw JSON, detach.
- `WebInspectorTransport`: parse protocol envelopes, unwrap target messages,
  route commands, manage replies, track protocol targets and execution contexts.
- `InspectorSession`: bootstrap domains, own event pumps, apply decoded domain
  events to semantic sessions, perform command intents.
- `WebInspectorCore`: hold `@MainActor @Observable` semantic model state for
  DOM and Network.
- `WebInspectorUI`: render and interact with native UIKit/TextKit2 views.

## Event And Command Flow

```mermaid
sequenceDiagram
    participant WK as WebKit backend
    participant Bridge as WebInspectorNativeBridge
    participant Transport as WebInspectorTransport
    participant Runtime as InspectorSession
    participant Core as DOMSession / NetworkSession
    participant UI as WebInspectorUI

    WK->>Bridge: raw JSON message
    Bridge->>Transport: raw JSON
    Transport->>Transport: parse envelope and target routing
    Transport->>Runtime: ordered domain event
    Runtime->>Core: apply decoded semantic event
    Core-->>UI: Observation update

    UI->>Runtime: command intent
    Runtime->>Transport: protocol command
    Transport->>Bridge: raw JSON command
    Bridge->>WK: raw JSON command
    WK-->>Bridge: raw JSON reply
    Bridge-->>Transport: raw JSON reply
    Transport-->>Runtime: command result with sequence
    Runtime-->>Core: apply result if still current
```

The native bridge is deliberately not target-aware. Target wrapping,
`Target.dispatchMessageFromTarget` unwrapping, reply matching, and domain fan-out
belong to transport.

## Session Shape

`WebInspectorSession` is the UI-facing lifecycle owner. Package-internal UI
controllers observe the semantic sessions through the runtime owner:

```mermaid
flowchart TD
    Session["WebInspectorSession<br/>@MainActor @Observable"]
    Attachment["attachmentState / lastError"]
    DOM["dom: DOMSession"]
    Network["network: NetworkSession"]
    PerformDOM["perform(DOMCommandIntent)"]
    PerformNetwork["perform(NetworkCommandIntent)"]

    Session --> Attachment
    Session --> DOM
    Session --> Network
    Session --> PerformDOM
    Session --> PerformNetwork
```

The UI should receive one session object and avoid direct ownership of
transport/backend objects. Expensive work still stays outside the observable
model boundary:

- raw transport I/O
- JSON parsing
- protocol payload decoding
- DOM markup/tokenization
- search indexing
- response body decoding

## UI Integration Boundary

`WebInspectorUI` owns the current UIKit/TextKit2 presentation. The root
container observes `WebInspectorSession`; DOM and Network controllers observe
the semantic sessions exposed from it.

Detailed UI diagrams are intentionally kept with the UI source:

- [`UIIntegration.md`](../Sources/WebInspectorUI/Docs/UIIntegration.md)
- [`ViewControllerStructure.md`](../Sources/WebInspectorUI/Docs/ViewControllerStructure.md)

## Public Surface Direction

The current public shape is intentionally small:

```swift
let session = WebInspectorSession()
let viewController = WebInspectorViewController(session: session)

try await session.attach(to: webView)
```

The important boundary is that the container observes `WebInspectorSession`;
UIKit controllers do not own transport/backend objects directly.

## Maintenance Rules

1. Keep README, migration notes, and architecture notes pointed at the
   WebInspector public API.
2. Keep WebInspector regression tests for DOM, Network, transport, runtime, and
   UI behavior.
3. Keep `WebInspectorKit` as the small umbrella export surface.
4. Keep domain routing in runtime/transport and semantic state in
   `WebInspectorCore`.

## Avoided Shapes

- Do not keep a compatibility model that copies WebInspector state into a second
  model graph.
- Do not keep two long-term UI implementation targets.
- Do not let UI parse raw protocol messages.
- Do not let the native bridge understand target routing.
- Do not store iframe documents as regular DOM children.
- Do not make redirect hops separate top-level network requests.
