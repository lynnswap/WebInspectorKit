# Implementation Gate — Coverage, Contract Tests, Delegation

Status: implementation gate status (2026-07-03). This file keeps
[05-two-layer-sdk-design.md](05-two-layer-sdk-design.md) implementation-ready by
recording the measured status of coverage, DTO field lists, contract tests, and
worker boundaries.

05 remains the source of truth for architecture and public API shape. This file
owns the measured evidence and the remaining delegation boundaries. Rows marked
implemented are current binding surface; rows marked planned/pending are
accepted architecture but not shipped public API.

## Locked Decisions

- No non-UI umbrella product. Consumers import `WebInspectorProxyKit` and/or
  `WebInspectorDataKit` explicitly.
- Final public products are `WebInspectorProxyKit`, `WebInspectorProxyKitTesting`,
  `WebInspectorDataKit`, and `WebInspectorKit`. Existing public
  `WebInspectorCore`, `WebInspectorTransport`, `WebInspectorNativeBridge`,
  `WebInspectorNativeSymbols`, and `WebInspectorUI` products are migration
  artifacts and must be internalized or removed from the public package surface
  before the rearchitecture contract is considered shipped.
- Domain model names in `WebInspectorDataKit` stay unprefixed: `DOMNode`,
  `NetworkRequest`, `ConsoleMessage`, `RuntimeObject`, etc.
- SwiftData/CoreData-style infrastructure stays `WebInspector`-prefixed:
  `WebInspectorContext`, `WebInspectorFetchDescriptor`,
  `WebInspectorFetchedResults`. `WebInspectorFetchedResultsController` is a planned
  transaction surface, not part of the current M3 public contract.
- `currentPage` keeps semantic identity across provisional commit; ProxyKit owns
  the hidden route-ID swap.
- `WebInspectorProxy.targets` is not part of the initial public surface. A future
  target-change API must be a real live stream that replays the current target
  set before yielding created/committed/destroyed changes; a one-shot snapshot
  stream must not be published under a target-change API name.
- DOM ordered row projection is a planned DataKit contract via
  `DOMTreeController`; it is not part of the current M3 shipped surface.
- `WebInspectorSession` remains the UIKit facade and compatibility owner;
  custom tabs continue to receive `WebInspectorSession`.
- `WKWebView`, `isInspectable`, native bridge attach/send/detach, and private
  WebKit controller calls stay behind a small `@MainActor` boundary. MainActor
  detachment is downstream-only: transport actors, event stream consumption,
  JSON decode, target multiplexing, domain mutation preparation, and DataKit
  event pumps move off main. DataKit applies live model mutations on the owning
  serial actor; `MainActor` is only one possible owner via `mainContext`.
- `WebInspectorDataKit` public APIs must not require `@MainActor` except for
  `WKWebView` attachment and `mainContext` convenience. `WebInspectorContext`
  and live models are actor-confined, non-`Sendable` references; public
  cross-actor payloads are Sendable IDs, DTOs, snapshots, and transactions.

## Gate Checklist

Implementation work can be delegated only against the status and owner boundary
recorded in these rows.

| Gate | Required artifact | Status |
| --- | --- | --- |
| G0 | Final public product/API surface is listed and legacy public products are marked migration-only | Implemented for product graph: `Package.swift` now exports only `WebInspectorProxyKit`, `WebInspectorProxyKitTesting`, `WebInspectorDataKit`, and `WebInspectorKit`; legacy targets remain internal implementation/test dependencies |
| G1 | DTO / model field lists filled from current payload structs and model types | Implemented for the M3/M4 binding subset; remaining field expansion rows are marked planned/pending below |
| G2 | Every typed Proxy event has exactly one DataKit destination or an explicit no-op owner | Implemented for the current DOM/CSS/Network/Console/Runtime subset; detached roots, shadow/pseudo binding, Target, and Page remain explicit planned/pending rows |
| G3 | Story A/A2/B/C contract-test package shape is defined with validation commands | Implemented as standalone `ContractTests/` package over public products; Story B custom tabs compile against `WebInspectorSession`, while direct `session.modelContext` access remains a public API gap |
| G4 | Worker branches are split by owner boundary and write set, with no overlapping primary files | Binding split recorded below, with W1/W2/W3/W5 current-shell work completed and W4/UI rebase pending |
| G5 | MainActor detachment owner map is fixed before stream/runtime refactors | Revised as owner map: native WebKit boundary remains `@MainActor`; protocol/domain stream detachment is M1/M2; DataKit selected owner-actor application is M3/M4 and must not be collapsed back into MainActor |
| G6 | DataKit public isolation contract is fixed before W3 implementation | Implemented for current M3/M4 shell: unconditional DataKit `@MainActor` removed from the public context/models/results, `WebInspectorContainer` hides raw proxy storage and owns shared wire-domain enablement, `WebInspectorContext` hides container/proxy internals, fixes owner actor at init, model `modelContext` stays internal, no public model-actor/executor, target-change stream, or fetched-results-controller compatibility layer is shipped, and non-MainActor Story A runtime coverage exists |

## Event Coverage Table

Each row must resolve to one of:

- `Model field`: event mutates a public model field.
- `Controller invalidation`: event invalidates or transactions a planned DataKit
  controller (`WebInspectorFetchedResultsController`, `DOMTreeController`, etc.).
- `Private coordinator`: event updates route/frame/context ownership that is not
  itself public state.
- `Intentional no-op`: event is decoded for forward compatibility or parity but
  has no public semantic effect. The reason must be written down.

| Domain | Proxy event | Existing dispatch / mutation evidence | DataKit owner | Destination kind | Status |
| --- | --- | --- | --- | --- | --- |
| DOM | `documentUpdated` | `DOMSession.handleDOMProtocolEvent` removes styles, invalidates document, and refreshes document request; `WebInspectorContext.apply(.documentUpdated)` resets `rootNode`, selection, and node identity before reloading the document | `WebInspectorContext` + DOM coordinator | `rootNode`, node identity map, `DOMTreeController.transactions`; selected `CSSStyles.phase` invalidation | Implemented current DataKit subset; `DOMTreeController.transactions` pending |
| DOM | `setChildNodes` | `WebInspectorContext.applySetChildNodes` materializes loaded children, prunes removed descendants from the identity map when replacement payloads prove absence, and preserves registered node identity for reused/reparented payload IDs | DOM coordinator | `DOMNode.children`, node identity map, `DOMTreeController.transactions` | Implemented current DataKit subset; `DOMTreeController.transactions` pending |
| DOM | `detachedRoot` | WebKit emits detached roots as `DOM.setChildNodes(parentId: 0, nodes: [...])`; current Core `DOMDocument.applyDetachedRoot` imports a private detached subtree, while ProxyKit/DataKit M3 intentionally do not bind a public detached-root model yet | DOM coordinator | Private detached-root registry; no public tree mutation unless a consumer story reaches detached roots | Planned; no M3 public effect |
| DOM | `childNodeInserted`, `childNodeRemoved`, `childNodeCountUpdated` | `WebInspectorContext.applyChildNodeInserted`, `applyChildNodeRemoved`, and count handler update loaded children or `.unrequested(count)` and purge removed subtrees from the identity map | DOM coordinator | `DOMNode.children`, `.unrequested(count)`, node identity map, `DOMTreeController.transactions` | Implemented current DataKit subset; `DOMTreeController.transactions` pending |
| DOM | `attributeModified`, `attributeRemoved`, `characterDataModified` | `WebInspectorContext.apply` updates attributes/node value and marks selected element styles stale only for the affected node | DOM + CSS selection coordinator | `DOMNode.attributes`, `DOMNode.nodeValue`, selected `CSSStyles.phase = needsRefresh`; DOM update transactions pending | Implemented current DataKit subset; `DOMTreeController.transactions` pending |
| DOM / Inspector | `DOM.inspect`, `Inspector.inspect` | Inspect alias selects protocol node and closes picker state; `WebInspectorContext.apply(.inspect)` selects registered nodes, or requests the current root subtree with `DOM.requestChildNodes(depth: -1)` before resolving collapsed nodes from subsequent `setChildNodes` events, including inspect events that arrive before the root document is applied. ProxyKit normalizes node-subtype `Inspector.inspect(Runtime.RemoteObject)` through `DOM.requestNode` before emitting `DOM.Event.inspect` | DOM selection coordinator + ProxyKit protocol normalization | `WebInspectorContext.selectedNode`, selection-driven `DOMNode.elementStyles` | Implemented current DataKit/ProxyKit shell; picker-mode command lifecycle and `DOMTreeController.transactions` pending |
| DOM | `shadowRootPushed/Popped`, `pseudoElementAdded/Removed` | ProxyKit already decodes shadow/pseudo DTO fields and events; current DataKit importer only materializes `children` and intentionally gives these events no public model effect | DOM coordinator | `DOMNode.shadowRoots`, pseudo element fields, `DOMTreeController.transactions` | ProxyKit typed decode implemented; DataKit binding planned |
| CSS | `styleSheetChanged` | `CSSSession.markNeedsRefresh(targetID:)`; no style ID in current event; `WebInspectorContext.apply(.styleSheetChanged)` marks selected styles stale | CSS coordinator | Target-wide `CSSStyles.phase = needsRefresh` | Implemented current DataKit subset |
| CSS | `styleSheetAdded`, `styleSheetRemoved` | Current Core registers/removes stylesheet headers for source offsets; current DataKit handler marks selected styles stale without retaining headers | CSS stylesheet registry | Internal `StyleSheetHeader` registry + affected `CSSStyles.phase` refresh | Implemented as selected-style invalidation; stylesheet registry/header offsets pending |
| CSS | `mediaQueryResultChanged`, `nodeLayoutFlagsChanged` | Current dispatcher marks target/node styles stale; DataKit marks selected styles stale target-wide for media changes and node-scoped for layout flags | CSS coordinator | `CSSStyles.phase = needsRefresh` | Implemented current DataKit subset |
| Network | `requestWillBeSent` | `applyRequestWillBeSent` inserts/updates request and redirect hop | Network coordinator | `NetworkRequest.url/method/requestHeaders/resourceType/state`, `requestSentTimestamp`, `redirects` | Implemented in DataKit shell |
| Network | `responseReceived` | `applyResponseReceived` updates response, body placeholders, state | Network coordinator | `NetworkRequest.status/mimeType/responseHeaders/responseBody/state`, `responseReceivedTimestamp` | Implemented in DataKit shell |
| Network | `dataReceived` | Updates decoded/encoded byte counts and last-data timestamp | Network coordinator | `NetworkRequest.decodedDataLength`, `NetworkRequest.encodedDataLength`, `lastDataReceivedTimestamp` | Implemented in DataKit shell |
| Network | `loadingFinished`, `loadingFailed` | Updates final state, metrics/sourceMapURL/timestamp, active-close data | Network coordinator | `NetworkRequest.state`, body availability/failure, `finishedOrFailedTimestamp`, `sourceMapURL`, `metrics`; terminal metric totals overwrite accumulated decoded/encoded byte counts | Implemented current DataKit/ProxyKit subset |
| Network | `requestServedFromMemoryCache` | Upserts cached request/response and finished state | Network coordinator | `NetworkRequest.status/mimeType/responseHeaders/state/responseBody`, request/response/finish timestamps; cached body size/type/source map need a ProxyKit DTO expansion before binding | Implemented current ProxyKit subset |
| Network | WebSocket family | Created/handshake/frame/error/closed mutate websocket state and frames | Network/WebSocket coordinator | `NetworkRequest.webSocket`, `WebSocketState.readyState`, frames, semantic handshake request/response snapshots, lifecycle timestamps | Implemented in DataKit shell |
| Console | `messageAdded` | Registers runtime objects in `.console`, then applies message | Console + Runtime coordinator | `ConsoleMessage.*`, `RuntimeObject` parameters, `networkRequestID` cross-link | Implemented in DataKit shell |
| Console | `messageRepeatCountUpdated` | Updates last message repeat count per target | Console coordinator | `ConsoleMessage.repeatCount`; private last-message-per-target owner | Implemented in DataKit shell |
| Console | `messagesCleared` | Clears console and releases `.console` runtime object group | Console + Runtime coordinator | Fetched console results clear; console-owned `RuntimeObject` invalidation; `Runtime.releaseObjectGroup(.console)` | Implemented in DataKit shell |
| Runtime | `executionContextCreated` | Runtime and DOM target graph record context | Runtime + target graph coordinator | `RuntimeContext`, `executionContexts`, `selectedContext`, frame/context mapping | Implemented in DataKit shell |
| Runtime | `executionContextDestroyed`, `executionContextsCleared` | Current code removes contexts/remote objects/default/selected context | Runtime coordinator | `RuntimeContext` removal, runtime object invalidation, selected context fallback | Implemented in DataKit shell |
| Page | `frameNavigated`, `frameDetached` | No current Page dispatcher registered; WebKit treats these as frame/resource-tree signals, not a standalone initial consumer story | `WebInspectorContext` private frame projection coordinator when a frame/resource-tree story lands | Private coordinator; no public `Page.Event`/`Page.Frame` in the initial surface | Deferred |
| Page | `loadEventFired`, `domContentEventFired` | No current Page dispatcher registered; current consumer stories do not observe page lifecycle milestones | None in initial DataKit; future Timeline/Page owner if a story reaches lifecycle milestones | Intentional no-op in the initial public surface | Deferred no-op |
| Target | `targetCreated`, `targetDestroyed` | `TransportSession` already owns route records and target lifecycle; public consumers need semantic targets, not raw route IDs | Proxy target registry + `WebInspectorContext` target lifecycle coordinator | Private coordinator; optional semantic target-change API only after a consumer story requires it | Required private contract; no raw target-route event surface |
| Target | `didCommitProvisionalTarget` | Provisional commit swaps hidden route IDs while `currentPage` must keep semantic identity | Proxy target registry owns route swap; DataKit retarget coordinator owns DOM/CSS invalidation, Runtime cleanup, Console order, and Network ownership | Private coordinator preserving stable `currentPage` identity and preventing request/context ID collisions | Required private contract |

Event-coverage notes:

- CSS target-wide invalidation: bind `styleSheetChanged`,
  `mediaQueryResultChanged`, and `nodeLayoutFlagsChanged` as refresh invalidation
  events; do not expose a fake style ID.
- Page events: current implementation has no Page dispatcher. Initial public
  surface keeps Page command-only. Frame/lifecycle projection requires a
  measured consumer story and a private coordinator first.

## DTO Field Lists

Every public DTO/model field must be justified by at least one consumer story,
model apply path, or transitive closure requirement. Public fields that are only
wire passthrough trivia stay package unless a consumer story reaches them.

DataKit intentionally reuses a small ProxyKit value vocabulary when the type is
already semantic and `Sendable`. This is a transitive public surface of
`WebInspectorDataKit`; adding to it requires updating this table and the
DataKit-only import contract. Current allowlist:

- `FrameID`
- `Network.ResourceType`, `Network.Metrics`
- `Console.Source`, `Console.Level`, `Console.Kind`, `Console.StackTrace`
- `Runtime.Kind`, `Runtime.Subtype`, `Runtime.JSONValue`, `Runtime.ObjectPreview`
- `CSS.Rule`, `CSS.ComputedProperty`

Route/wire-owned ProxyKit DTOs remain banned from DataKit public surface:
`Network.Request`, `Network.Response`, `RawEvent`, `WebInspectorTargetChanges`,
backend/proxy command envelopes, and target-route IDs.

| Public type | Current source type(s) | Fields to publish | Nested public types required | Evidence | Status |
| --- | --- | --- | --- | --- | --- |
| `WebInspectorTarget` | `ProtocolTarget.Record`, `DOMTarget` | `id`, `kind`, `frameID`, `isProvisional`; keep capabilities/pause/routing internals package | `WebInspectorTarget.ID`, `FrameID` | `Sources/WebInspectorTransport/ProtocolTypes.swift`; `Sources/WebInspectorCoreDOMCSS/DOM/DOMModelTypes.swift`; `Sources/WebInspectorProxyKit/WebInspectorTarget.swift` | Implemented current ProxyKit subset |
| `DOM.Node` / `DOMNode` | `DOMNode.Payload`, `DOMNode` | ProxyKit publishes the full decoded node payload; current DataKit M3 model publishes `id`, names/value/type, attributes, child count, children, and selection-driven `elementStyles`. Frame/document/shadow/pseudo/content fields remain planned DataKit model expansion. | `DOM.Attribute`, `DOM.Children` / `DOMNode.Children`, `DOM.PseudoType`, `DOM.ShadowRootType` | `Sources/WebInspectorCoreDOMCSS/DOM/DOMProtocol.swift`; `Sources/WebInspectorCoreDOMCSS/DOM/DOMModelTypes.swift`; `Sources/WebInspectorProxyKit/DOM.swift`; `Sources/WebInspectorDataKit/DOMNode.swift` | Implemented M3 subset; DOM expansion planned |
| `Runtime.RemoteObject` / `RuntimeObject` | `RuntimeRemoteObject.Payload`, `RuntimeRemoteObject` | `id?`, `kind/type`, `subtype`, `className`, `value`, `description`, `size`, `preview`; DataKit uses synthetic IDs for by-value primitives | `Runtime.JSONValue`, open `Runtime.Kind` or type/subtype representation, `Runtime.ObjectPreview` | `Sources/WebInspectorCoreRuntime/Runtime/RuntimeProtocol.swift`; `Sources/WebInspectorCoreRuntime/Runtime/RuntimeModel.swift`; `Sources/WebInspectorDataKit/RuntimeObject.swift` | Implemented current subset |
| `Runtime.ObjectPreview` | `RuntimeRemoteObject.Preview.Payload` | `type`, `subtype`, `description`, `lossless`, `overflow`, `properties`, `entries`, `size` | `Runtime.PropertyPreview`, `Runtime.EntryPreview` | `Sources/WebInspectorCoreRuntime/Runtime/RuntimeProtocol.swift`; `Sources/WebInspectorProxyKit/Runtime.swift` | ProxyKit typed DTO implemented; DataKit exposes it transitively through `RuntimeObject.preview` |
| `Runtime.PropertyDescriptor` | `RuntimeRemoteObject.PropertyDescriptor.Payload` | `name`, `value`, `writable`, `get`, `set`, `wasThrown`, `configurable`, `enumerable`, `isOwn`, `symbol`, `isPrivate`, `nativeGetter` | `Runtime.RemoteObject` | `Sources/WebInspectorCoreRuntime/Runtime/RuntimeProtocol.swift`; `Sources/WebInspectorProxyKit/Runtime.swift`; `Sources/WebInspectorDataKit/RuntimeObject.swift` | ProxyKit typed command result implemented; DataKit maps it to the current `RuntimeObject.Property` subset |
| `Runtime.CollectionEntry` | `RuntimeRemoteObject.CollectionEntry.Payload` | `key`, `value` | `Runtime.RemoteObject` | `Sources/WebInspectorCoreRuntime/Runtime/RuntimeProtocol.swift`; `Sources/WebInspectorProxyKit/Runtime.swift`; `Sources/WebInspectorDataKit/RuntimeObject.swift` | ProxyKit typed command result implemented; DataKit maps it to the current `RuntimeObject.Entry` subset |
| `Runtime.ExecutionContext` / `RuntimeContext` | `RuntimeExecutionContext.Payload`, `RuntimeContext.Record` | `id`, `name`, `frameID`, `kind/type`; keep target/runtime-agent IDs package | `Runtime.ContextKind`, `FrameID` | `Sources/WebInspectorCoreRuntime/Runtime/RuntimeProtocol.swift`; `Sources/WebInspectorTransport/RuntimeContextTypes.swift`; `Sources/WebInspectorDataKit/RuntimeContext.swift` | Implemented current subset |
| `Network.Request` | `NetworkRequest.Payload` | ProxyKit publishes typed request DTOs for events/commands. DataKit public models expose semantic fields and `NetworkRequestSnapshot`; raw `Network.Request` must not appear in the DataKit symbol graph. | `NetworkRequestSnapshot` in DataKit; raw ProxyKit DTO stays outside DataKit public graph | `Sources/WebInspectorCoreConsoleNetwork/Network/NetworkProtocol.swift`; `Sources/WebInspectorProxyKit/Network.swift`; `Sources/WebInspectorDataKit/NetworkRequest.swift` | ProxyKit typed DTO implemented; DataKit snapshot mapping implemented |
| `Network.Response` | `NetworkRequest.Response.Payload` | ProxyKit publishes typed response DTOs for events. DataKit public models expose semantic fields and `NetworkResponseSnapshot`; raw `Network.Response` must not appear in the DataKit symbol graph. | `NetworkResponseSnapshot` in DataKit; raw ProxyKit DTO stays outside DataKit public graph | `Sources/WebInspectorCoreConsoleNetwork/Network/NetworkProtocol.swift`; `Sources/WebInspectorProxyKit/Network.swift`; `Sources/WebInspectorDataKit/NetworkRequest.swift` | ProxyKit typed DTO implemented; DataKit snapshot mapping implemented |
| `NetworkRequest` | `NetworkRequest` | M3 publishes URL/method/resource type/state/status/mime/source-map, headers, request/response/data/terminal timestamps, decoded/encoded length, metrics, redirects, websocket state, and response-body phase/text/base64. `documentURL`, cached body size/type, `responseSource`, `initiator`, and request body are planned expansion. | `Network.ResourceType`, `NetworkBody`, `RedirectHop`, `WebSocketState` | `Sources/WebInspectorCoreConsoleNetwork/Network/NetworkModel.swift`; `Sources/WebInspectorDataKit/NetworkRequest.swift` | Implemented M3 subset; expansion planned |
| `RedirectHop` | `NetworkRequest.RedirectHop` | `request`, `response`, `timestamp`; add opaque `id` only if DataKit identity needs it | `NetworkRequestSnapshot`, `NetworkResponseSnapshot` | `Sources/WebInspectorCoreConsoleNetwork/Network/NetworkModel.swift`; `Sources/WebInspectorDataKit/NetworkRequest.swift` | Implemented current DataKit subset |
| `WebSocketState.Frame` | `NetworkRequest.WebSocket.FrameEntry`, `FramePayload` | `direction`, `timestamp`, `opcode`, `mask`, `payloadData`, `payloadLength`, `errorMessage?` | `WebSocketState.ReadyState`, `WebSocketState.FrameDirection` | `Sources/WebInspectorCoreConsoleNetwork/Network/NetworkModel.swift`; `Sources/WebInspectorCoreConsoleNetwork/Network/NetworkProtocol.swift`; `Sources/WebInspectorDataKit/NetworkRequest.swift` | Implemented current subset |
| `NetworkBody` | `NetworkBody`, `NetworkBody.Payload` | M3 publishes `phase`, `text`, and `isBase64Encoded`; role/kind/size/truncation/syntax metadata is planned expansion | `NetworkBody.Phase` | `Sources/WebInspectorCoreConsoleNetwork/Network/NetworkBody.swift`; `Sources/WebInspectorDataKit/NetworkRequest.swift` | Implemented M3 subset; expansion planned |
| `Console.Message` / `ConsoleMessage` | `ConsoleMessage.Payload`, `ConsoleMessage` | `id` for model, `source`, `level`, `text`, `type`, `url`, `line`, `column`, `repeatCount`, `parameters`, `stackTrace`, `networkRequestID`, `timestamp` | `Console.Source`, `Console.Level`, `Console.Kind`, `Console.StackTrace`, `Console.CallFrame` | `Sources/WebInspectorCoreConsoleNetwork/Console/ConsoleProtocol.swift`; `Sources/WebInspectorCoreConsoleNetwork/Console/ConsoleModel.swift`; `Sources/WebInspectorDataKit/ConsoleMessage.swift` | Implemented current subset |
| `CSS.MatchedStyles` / `CSSStyles` | `CSSStyle.MatchedStylesPayload`, `InlineStylesPayload`, `CSSNodeStyles` | Proxy DTO exposes matched rules, pseudo elements, inherited, inline style, attributes style; DataKit exposes `phase`, `sections`, `computedProperties` | `CSS.Rule`, `CSS.Style`, `CSS.ComputedProperty` | `Sources/WebInspectorCoreDOMCSS/CSS/CSSProtocol.swift`; `Sources/WebInspectorCoreDOMCSS/CSS/CSSModel.swift`; `Sources/WebInspectorDataKit/CSSStyles.swift` | Implemented read-only style subset |
| `CSS.Style` | `CSSStyle.Payload`, `CSSStyle` | `id`, `properties`, `shorthandEntries`, `cssText`, `range`, `width`, `height`, `isEditable` | `CSS.Style.ID`, `CSS.Style.SourceRange`, `CSS.Style.ShorthandEntry`, `CSS.Property` | `Sources/WebInspectorCoreDOMCSS/CSS/CSSProtocol.swift`; `Sources/WebInspectorCoreDOMCSS/CSS/CSSModel.swift`; `Sources/WebInspectorProxyKit/CSS.swift`; `Sources/WebInspectorDataKit/CSSStyles.swift` | ProxyKit typed DTO implemented; DataKit exposes read-only style sections through `CSSStyles.sections` |
| `CSS.Property` | `CSSProperty.Payload`, `CSSProperty` | `id`, `name`, `value`, `priority`, `text`, `parsedOk`, `status`, `implicit`, `range`, `isEditable`, `isModifiedByInspector` | `CSS.Property.ID`, `CSS.Property.Status`, `CSS.Style.SourceRange` | `Sources/WebInspectorCoreDOMCSS/CSS/CSSProtocol.swift`; `Sources/WebInspectorCoreDOMCSS/CSS/CSSModel.swift`; `Sources/WebInspectorProxyKit/CSS.swift` | ProxyKit typed DTO implemented; DataKit exposes it transitively through `CSS.Style`; CSS mutation remains planned |
| `CSS.Rule` | `CSSRule.Payload`, `CSSRule` | `id`, `selectorList`, `sourceURL`, `sourceLine`, `sourceLocation`, `origin`, `style`, `groupings`, `isImplicitlyNested` | `CSS.Rule.ID`, `CSS.Rule.SelectorList`, `CSS.Style.Origin`, `CSS.Rule.Grouping` | `Sources/WebInspectorCoreDOMCSS/CSS/CSSProtocol.swift`; `Sources/WebInspectorCoreDOMCSS/CSS/CSSModel.swift`; `Sources/WebInspectorProxyKit/CSS.swift`; `Sources/WebInspectorDataKit/CSSStyles.swift` | ProxyKit typed DTO implemented; DataKit exposes it through read-only style sections |
| `CSS.StyleSheetHeader` | `CSSStyleSheet.HeaderPayload` | `styleSheetID`, `frameID`, `sourceURL`, `origin`, `title`, `disabled`, `isInline`, `startLine`, `startColumn` | `CSS.StyleSheet.ID`, `FrameID`, `CSS.Style.Origin` | `Sources/WebInspectorCoreDOMCSS/CSS/CSSProtocol.swift`; `Sources/WebInspectorProxyKit/CSS.swift` | ProxyKit typed event DTO implemented; DataKit stylesheet header registry remains planned |
| `Page.Frame` / `FrameID` | No current Page model in scoped sources | Out of initial public surface. Frame identity remains `FrameID`; frame projection is handled by target/DOM/Network coordinators. | `FrameID` | Current evidence only has `ProtocolFrame.ID`, target frame IDs, and Network frame/loader/document fields | Deferred |
| `RawEvent` | `ProtocolEvent` | `domain`, `method`, `params` | none beyond `Data` | `Sources/WebInspectorTransport/TransportTypes.swift`; `Sources/WebInspectorProxyKit/RawEvent.swift` | ProxyKit forward-compat public surface; banned from DataKit public graph |

Design notes from field-list review:

- `RuntimeObject.ID`: current remote object IDs are optional for by-value
  primitives. 05 resolves this by giving by-value primitives context-owned
  synthetic DataKit IDs.
- `Page.Frame`: the current scoped code does not expose a Page frame payload
  equivalent to the earlier sketch. Page events stay out of the initial public
  surface; frame projection remains an internal coordinator responsibility.

## Contract-Test Plan

Contract tests must import public products only and must not use `@testable`.

| Story | Product imports | Contract style | Fake/backend need | Validation |
| --- | --- | --- | --- | --- |
| A — DataKit consumer app | `WebInspectorDataKit`; fake-backed runtime tests also import `WebInspectorProxyKitTesting` | Compile on iOS and macOS without UIKit and without `@MainActor`: DataKit-only import for base read/evaluate surface; `WebInspectorContainer(proxy:)`, owner-private `WebInspectorContext` stored inside a consumer actor, `rootNode`, `DOMNode.Children.loaded`, `.allRequests`, `fetchResponseBody()`, `evaluate()`. A separate UI compile case may use `mainContext`. | Runtime contract uses `WebInspectorContainer(proxy:)` over `WebInspectorProxyKitTesting`: DOM seed, network list, body fetch loaded, runtime evaluation reflected into context/models on a non-main consumer actor | `cd ContractTests && swift test`; targeted DataKit package tests |
| A2 — Proxy-only consumer | `WebInspectorProxyKit`; fake-backed runtime tests also import `WebInspectorProxyKitTesting` | Compile without DataKit/UI: `WebInspectorProxy`, `waitForCurrentPage()`, `target.network.events`, `Network.Event.responseReceived` | Fake backend validates event multicast and `close()` / `waitUntilClosed()` lifecycle. Extra per-target creation remains package-only, so target live stream/per-target expansion stays out of this slice. | `cd ContractTests && swift test`; targeted ProxyKit package tests |
| B — custom UIKit Console tab | `WebInspectorKit` on iOS | Compile: `WebInspectorTab` factory still receives `WebInspectorSession`, and `WebInspectorViewController(tabs:)` / `WebInspectorViewController(session:)` remain app-constructible. Direct `session.modelContext` access is not public yet and remains a gap, not an implemented contract. | No public fake-backed session initializer. Runtime behavior is covered inside WebInspectorKit tests using package/internal composition seams, because a public test-only DI initializer would bloat the product surface. | `cd ContractTests && swift test` on macOS compiles UIKit stories behind `#if canImport(UIKit)`; workspace UIKit tests cover runtime behavior |
| C — drop-in UIKit compatibility | `WebInspectorKit` on iOS | Compile existing facade: `WebInspectorSession()`, `WebInspectorViewController(session:)`, `session.attach(to:)`, `WebInspectorViewController.attach(to:)`, `WebInspectorTab` factory shape | Runtime attach/detach/context lifecycle is covered by WebInspectorKit tests and the default workspace validation. ContractTests only assert the public UIKit shape from outside the package. | WebInspectorKit workspace tests; Monocly build/test after custom tab is added |

Minimum standalone package shape:

```text
ContractTests/
  Package.swift
  Tests/WebInspectorDataKitImportOnlyContractTests/
    StoryADataKitImportOnlyContract.swift
  Tests/WebInspectorConsumerContractTests/
    ContractTestSupport.swift
    StoryADataKitCompileContract.swift
    StoryBConsoleTabCompileContract.swift
    StoryCUIKitCompatibilityCompileContract.swift
    StoryADataKitFakeBackendTests.swift
    StoryA2ProxyKitContractTests.swift
```

`Package.swift` uses `.package(path: "..")`. The import-only target depends
only on `WebInspectorDataKit`; the broader consumer target depends on
`WebInspectorProxyKit`, `WebInspectorDataKit`, `WebInspectorProxyKitTesting`,
plus the iOS-only `WebInspectorKit` product. `Sources/WebInspectorProxyKitTesting`
owns the public string-based fixture factory for package-only protocol IDs used
by external contract tests.

Current coverage limits: Story A/A2 exercise compile shape and happy-path fake
backend behavior; Story B/C are compile-shape contracts for the UIKit facade.
Wrong-actor precondition misuse is documented by the `isolation:` signatures
and DataKit tests, but is not asserted in `ContractTests` because Swift
precondition failure is process-fatal.

Local validation commands:

```sh
xcodebuild test \
  -workspace WebInspectorKit.xcworkspace \
  -scheme WebInspectorKit \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'

cd ContractTests && swift test
swift test --filter WebInspectorProxyKitTests
swift test --filter WebInspectorDataKitTests

swift package dump-symbol-graph --minimum-access-level public
graph=$(find .build -path '*/symbolgraph/WebInspectorDataKit.symbols.json' -print -quit)
test -n "$graph"
! rg 'Network\.Request|Network\.Response|WebInspectorFetchedResultsController|DOMTreeController|WebInspectorModelActor|WebInspectorModelExecutor|WebInspectorTargetChanges|RawEvent|\bWebView[A-Za-z0-9_]*|WebViewKit|@WebView' "$graph"
```

The symbol-graph denylist intentionally checks `WebInspectorDataKit` only.
`RawEvent` is a ProxyKit forward-compat escape hatch and must not leak into the
DataKit graph.

If Monocly gains the custom Console tab in this series, validate the app target
too. The production call site to change is session creation in
`Monocly/Monocly/Controllers/BrowserRootViewController+UIKit.swift`, while the
sheet/window presentation and attach/detach lifecycle keep sharing the same
`WebInspectorSession`.

## MainActor Detachment Gate

The invariant is not "make the inspector non-main." The invariant is that
WebKit-owned page and inspector controller state remains main-thread-owned, and
only downstream transport/runtime/domain work detaches from `MainActor`.

Owner map:

| Boundary | Owner | Isolation target | Notes |
| --- | --- | --- | --- |
| Native page handle | `NativeInspectablePage`, `NativeInspectorBackend`, `WebInspectorNativeBridge` | `@MainActor` | Owns `WKWebView`, `isInspectable`, reload, attach/send/detach, and private controller calls. Do not use `@unchecked Sendable`, `@preconcurrency`, or `nonisolated(unsafe)` to bypass this boundary. |
| Raw transport, replies, target routes, event ordering | `TransportSession` | actor | Already owns command IDs, reply table, target registry, provisional route messages, runtime context registry, and ordered protocol event streams. |
| Domain stream consumption | `DomainEventPump` | detached stream consumer plus owner-isolated applied-sequence tracker | First detachment slice. Consume `AsyncStream<ProtocolEvent>` off main and hop only the apply step to the caller's isolation. Preserve `waitUntilApplied(_:)` semantics by advancing the applied sequence only after apply returns. Current Core callers still use MainActor; DataKit must not bake that into its public API. |
| Domain decode and mutation preparation | Per-domain dispatcher/runtime processor | non-main | Second slice. Decode `ProtocolEvent.paramsData` with `decodeAsync` where payloads can be large, classify into `Sendable` domain mutations, then apply mutations on the selected model owner. |
| Semantic model apply | `WebInspectorContext` and private DataKit coordinators | caller-selected serial actor | DataKit live model mutation applies on the owning `WebInspectorContext` actor confinement. `container.mainContext` makes that owner MainActor for UIKit, but non-UI contexts keep the context as owner-private state inside a consumer serial actor. Do not add a public model-actor/executor wrapper until it replaces this boundary and has a concrete consumer. |
| Legacy semantic model apply | `AttachedInspection` and existing `WebInspectorCore*` stores | `@MainActor` until replaced | Existing Core remains UI-facing legacy state during migration. It must not define the new DataKit public isolation contract. |
| UIKit render | `WebInspectorSession` and UI modules | `@MainActor` | Public UIKit facade stays main actor owned. |

Implementation slice status:

| Slice | Scope | Primary write set | Validation | Status |
| --- | --- | --- | --- | --- |
| M1 — off-main protocol event pump | Move only `DomainEventPump` stream consumption out of `@MainActor`; keep the pump API and applied-sequence waiters on `MainActor`, and use a detached consumer so the task cannot inherit main-actor execution | `Sources/WebInspectorCoreSupport/DomainEventPump.swift`; `Sources/WebInspectorCore/AttachedInspection.swift`; focused core tests | `swift test --filter WebInspectorCoreTests`; `swift test --filter WebInspectorTransportTests` | Completed before M3/M4; keep as legacy Core boundary until UI rebase |
| M2 — two-phase domain dispatch | Split dispatch into off-main decode/mutation creation and main-owner apply; keep existing dispatchers as main-owner appliers at first, and start with Network because response-body command decode already uses `decodeAsync` | `Sources/WebInspectorCoreSupport/ProtocolDomain+Dispatching.swift`; per-domain `*ProtocolDispatching.swift`; focused domain tests | Core/domain tests plus large-payload decode tests | Completed for the current Core migration slice; future domain expansion must preserve this boundary |
| M3 — DataKit isolation contract | Remove unconditional `@MainActor` from `WebInspectorDataKit` public context/models/results, keep raw proxy/context internals out of the public surface, prove owner-private non-main context usage, and do not publish model-actor/executor or fetched-results-controller stubs before their real owners exist | `Sources/WebInspectorDataKit/**`; `ContractTests/**`; DataKit tests | `swift test --filter WebInspectorDataKitTests`; `cd ContractTests && swift test` | Implemented for current binding subset |
| M4 — DataKit typed event pump | Replace `WebInspectorContext.subscribe(to:)` inherited-main tasks with a CodexKit-style pump that consumes `WebInspectorTarget.*.events` off main and hops only `apply` to the context's selected owner actor | `Sources/WebInspectorDataKit/WebInspectorContext.swift`; small support type under `Sources/WebInspectorDataKit` | `swift test --filter WebInspectorDataKitTests`; contract tests | Implemented for current DataKit target/domain streams |
| M5 — runtime actor extraction | Introduce a runtime actor only if M3/M4 leave an actual owner gap for connection lifecycle, bootstrap, target tasks, and command channel. It must replace duplicated ownership, not wrap existing MainActor state. | New runtime/core support files if required; `AttachedInspection`; UI facade integration | Full package and workspace validation | Not authorized by current evidence; M3/M4 did not expose a real owner gap requiring this wrapper |

M1 must not change the native bridge or make `WKWebView` sendable. M2 must not
invent fallback target/page state; target identity remains owned by
`TransportSession` and WebKit protocol events. M3 is a design/API gate, not a
compatibility layer: worker implementation must first remove the public
`@MainActor` DataKit contract and prove a non-main consumer shape; that proof is
now in `ContractTests`. M5 remains disallowed until a later audit identifies a
real missing owner; adding an actor around still duplicated state is not an
acceptable intermediate layer.

## W3 DataKit Status And Remaining Contracts

The old semantic owners are the `WebInspectorCore*` session/store types. They
remain legacy implementation evidence, not public DataKit owners. The current
M3/M4 binding subset has already moved live model ownership into
`WebInspectorContext`-owned DataKit coordinators on a selected owner actor.
Remaining rows are planned expansions and must not be filled by publishing the
old Core sessions, reproducing their global `@MainActor` contract, or adding
compatibility wrappers.

| Domain | Current owner evidence | Current DataKit binding owner | Planned expansion |
| --- | --- | --- | --- |
| DOM tree | `DOMSession`, `DOMDocumentStore`, `TargetGraph`, `DOMDocument.NodeStore` in `Sources/WebInspectorCoreDOMCSS/DOM` own tree identity, current-page document projection, mutation apply, and selection | `WebInspectorContext` DOM coordinator, `DOMNode`, node identity map, root/child/attribute/selection apply paths | `DOMTreeController` ordered transactions, detached-root registry, shadow/pseudo/content model fields |
| CSS styles | `CSSSession` and `CSSNodeStyleStore` in `Sources/WebInspectorCoreDOMCSS/CSS` own selected-node style refresh, matched styles, computed styles, stylesheet headers | CSS coordinator tied to DOM selection; selected style phase, read-only sections, computed properties | Stylesheet header registry/source offsets and CSS mutation APIs |
| Network requests/body | `NetworkSession`, private `NetworkRequestStore`, `NetworkRequest`, and `NetworkBody` in `Sources/WebInspectorCoreConsoleNetwork/Network` own request order, state, metrics, and body fetch phase | Network coordinator, request identity/order, request/response/body/websocket lifecycle, response body fetch phase | Request body, cached body size/type/source, initiator, wall-time/detail metadata |
| Console messages | `ConsoleSession`, `ConsoleTargetRegistry`, and `TargetState` in `Sources/WebInspectorCoreConsoleNetwork/Console` own per-target message order and aggregation | Console coordinator with message order, runtime parameter registration, network request cross-links, repeat count, clear semantics | Target-aware retargeting proof across provisional commit |
| Runtime objects/contexts | `RuntimeState` and `RuntimeState.AgentState` in `Sources/WebInspectorCoreRuntime/Runtime` own contexts, selected context, and remote-object identity map | Runtime coordinator, `RuntimeContext`, `RuntimeObject`, object-group lifecycle, selected-context fallback | Richer property/collection commands, retained-object lifecycle controls, target commit cleanup proof |

UI-owned artifacts must stay outside the first DataKit move:

- `Sources/WebInspectorUI/**`, `Sources/WebInspectorUIDOM/**`,
  `Sources/WebInspectorUINetwork/**`, and `Sources/WebInspectorUISyntaxBody/**`
  keep UIKit/TextKit/view-controller, tab, selection UI, display filtering, row
  rendering, and syntax rendering responsibilities.
- `DOMNode.domTreeRenderSnapshot`, `DOMSession` row/render invalidation deltas,
  and `NetworkSession.requestDisplayChanges(after:)` are migration warning
  signs. W3 should expose model/controller transactions, not TextKit rows or UI
  display caches.
- Preview fixtures that call production `apply*` paths directly should move to
  the same fake-proxy data flow as tests once `WebInspectorProxyKitTesting` supports
  target-scoped event streams.

W3 contract-test status:

| Contract | Current proof | Remaining proof |
| --- | --- | --- |
| DOM identity | Fake proxy emits document and child mutations; `rootNode`, `node(for:)`, and repeated payload application keep stable semantic node identity | `DOMTreeController` ordered transactions once that controller is implemented |
| Network request/body lifecycle | `requestWillBeSent` → `responseReceived` → `dataReceived` → terminal event → `fetchResponseBody()` produces one ordered request and expected body phase | Request body/cached/initiator/detail expansion |
| Console + Runtime linking | Runtime context plus console message parameters register `RuntimeObject` values; console messages with `networkRequestID` resolve to the matching request | Retargeting proof across provisional commit |
| Provisional target commit stability | ProxyKit keeps `currentPage` as the semantic page handle and hides route IDs from public DataKit models | End-to-end fake/live proof that commit retargets DOM/CSS invalidation, Runtime cleanup, Console order, and Network ownership without semantic identity loss |
| CSS selection refresh | Selecting a DOM node then receiving matched/computed style results transitions selected styles from loading to loaded; stylesheet changes mark affected styles stale | Stylesheet header registry/source-offset behavior and mutation transactions |

## Worker Split

Workers must not change the architecture contract. If a worker discovers that a
public API shape, owner boundary, or test strategy must change, it escalates to
the main agent instead of improvising.

Worker split and current status:

| Worker | Owner boundary | Primary write set | Status | Validation |
| --- | --- | --- | --- | --- |
| W1 — package graph + ProxyKit shell | `WebInspectorProxyKit` owns native attach, raw transport, target registry, terminal lifecycle | `Package.swift`; `Sources/WebInspectorProxyKit/**`; `Sources/WebInspectorProxyKitTesting/**`; targeted transport/proxy tests | Current product/shell/rename work completed; raw inbound `TransportReceiver` now belongs to `WebInspectorTransport`; native attach and remaining legacy transport internals still need to be rebased behind ProxyKit | `swift test`; targeted transport/proxy tests; symbol graph has no public raw envelope in DataKit |
| W2 — typed proxy domain clients | `WebInspectorTarget` owns route-scoped typed commands/events; proxy does not accumulate semantic state | `Sources/WebInspectorProxyKit/DOM.swift`, `CSS.swift`, `Network.swift`, `Console.swift`, `Runtime.swift`, tests | Current DOM/CSS/Network/Console/Runtime typed subset completed; field/event expansion follows the DTO and coverage rows above | Proxy fake tests over `WebInspectorProxyKitTesting`; event coverage rows remain mapped |
| W3 — DataKit model/context owners | `WebInspectorContext` owns semantic state, identity maps, apply handlers, and initial fetched results on a selected owner actor | `Sources/WebInspectorDataKit/**`; DataKit tests; contract tests | Current M3/M4 binding subset completed; `DOMTreeController`, `WebInspectorFetchedResultsController`, richer DOM/CSS/Network fields, and target-commit proof remain planned | DataKit tests; no UI imports; non-MainActor compile/runtime proof; symbol graph denylist |
| W4 — UIKit compatibility layer | `WebInspectorSession` owns the MainActor/UIKit facade over DataKit container/context; tabs keep receiving session | `Sources/WebInspectorUI/**`, `Sources/WebInspectorKit/**`, UIKit tests, Monocly call site if custom tab is included | Pending. The current `WebInspectorSession` facade is preserved for compile compatibility, but built-in UI is still backed by legacy Core state until this slice deliberately hands DataKit context access to UIKit tabs | default workspace `xcodebuild test`; Monocly build/test if changed |
| W5 — ContractTests package | Public products are the only imports; no `@testable` | `ContractTests/**`; README/MIGRATION snippets if needed | Current Story A/A2/B/C package completed for the binding subset; expand as planned surfaces move from accepted architecture to public API | `cd ContractTests && swift test`; iOS `xcodebuild test` for UIKit stories |

Integration order for remaining work: route W4 and every planned expansion
through the same owner chain, but do not replay completed W1/W2/W3/W5 slices as
fresh prerequisites. New work still flows ProxyKit typed surface → DataKit owner
binding → UIKit facade → public contract tests, because W4 depends on the
DataKit context surface and public tests must describe the surface that actually
ships.
