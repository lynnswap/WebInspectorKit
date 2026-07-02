# Implementation Gate — Coverage, Contract Tests, Delegation

Status: draft gate document. This file turns
[05-two-layer-sdk-design.md](05-two-layer-sdk-design.md) from an interface
sketch into an implementation-ready contract.

05 remains the source of truth for architecture and public API shape. This file
owns the pre-delegation checks that need measured code evidence: event coverage,
DTO field lists, consumer contract tests, and worker boundaries.

## Locked Decisions

- No non-UI umbrella product. Consumers import `WebViewProxyKit` and/or
  `WebViewDataKit` explicitly.
- Domain model names in `WebViewDataKit` stay unprefixed: `DOMNode`,
  `NetworkRequest`, `ConsoleMessage`, `RuntimeObject`, etc.
- SwiftData/CoreData-style infrastructure stays `WebView`-prefixed:
  `WebViewModelContext`, `WebViewFetchDescriptor`,
  `WebViewFetchedResultsController`.
- `currentPage` keeps semantic identity across provisional commit; ProxyKit owns
  the hidden route-ID swap.
- DOM ordered row projection is a DataKit contract via `DOMTreeController`.
- `WebInspectorSession` remains the UIKit facade and compatibility owner;
  custom tabs continue to receive `WebInspectorSession`.

## Gate Checklist

Implementation can be delegated only after these rows are complete.

| Gate | Required artifact | Status |
| --- | --- | --- |
| G1 | DTO / model field lists filled from current payload structs and model types | Drafted; Page events/frames are out of initial public surface |
| G2 | Every typed Proxy event has exactly one DataKit destination or an explicit no-op owner | Drafted; Page events are explicitly out of initial public surface |
| G3 | Story A/A2/B/C contract-test package shape is defined with validation commands | Drafted; B/C runtime behavior is covered by WebInspectorKit tests, not by adding public test-only DI |
| G4 | Worker branches are split by owner boundary and write set, with no overlapping primary files | Drafted below |

## Event Coverage Table

Each row must resolve to one of:

- `Model field`: event mutates a public model field.
- `Controller invalidation`: event invalidates or transactions a DataKit
  controller (`WebViewFetchedResultsController`, `DOMTreeController`, etc.).
- `Private coordinator`: event updates route/frame/context ownership that is not
  itself public state.
- `Intentional no-op`: event is decoded for forward compatibility or parity but
  has no public semantic effect. The reason must be written down.

| Domain | Proxy event | Existing dispatch / mutation evidence | DataKit owner | Destination kind | Status |
| --- | --- | --- | --- | --- | --- |
| DOM | `documentUpdated` | `DOMSession.handleDOMProtocolEvent` removes styles, invalidates document, and refreshes document request | `WebViewModelContext` + DOM coordinator | `rootNode`, node identity map, `DOMTreeController.transactions`; selected `CSSStyles.phase` invalidation | Draft |
| DOM | `setChildNodes` / `detachedRoot` | `applySetChildNodes`; `parentId == 0` currently imports detached root | DOM coordinator | `DOMNode.children`, `DOMObservation.childrenChanged`, `DOMTreeController.transactions`; detached roots go to private detached-root registry | Draft |
| DOM | `childNodeInserted`, `childNodeRemoved`, `childNodeCountUpdated` | `applyChildInserted`, `applyNodeRemoved`, `applyChildNodeCountUpdated` | DOM coordinator | `DOMNode.children`, `.unrequested(count)`, `DOMUpdate.childrenChanged`, `DOMTreeController.transactions` | Draft |
| DOM | `attributeModified`, `attributeRemoved`, `characterDataModified` | `applyAttributeModified/Removed`, `applyCharacterDataModified`; selected style marked stale | DOM + CSS selection coordinator | `DOMNode.attributes`, `DOMNode.nodeValue`, `DOMUpdate.attributesChanged/characterDataChanged`, selected `CSSStyles.phase = needsRefresh` | Draft |
| DOM / Inspector | `DOM.inspect`, `Inspector.inspect` | Inspect alias selects protocol node and closes picker state | DOM selection coordinator | `WebViewModelContext.selectedNode`, selection-driven `DOMNode.elementStyles` | Add Inspector alias to Proxy event coverage |
| DOM | `shadowRootPushed/Popped`, `pseudoElementAdded/Removed` | Current code imports these mostly through payload subtree import, not event dispatch | DOM coordinator | `DOMNode.shadowRoots`, pseudo element fields, `DOMTreeController.transactions` | Verify WebKit event coverage before binding |
| CSS | `styleSheetChanged` | `CSSSession.markNeedsRefresh(targetID:)`; no style ID in current event | CSS coordinator | Target-wide `CSSStyles.phase = needsRefresh` | Draft |
| CSS | `styleSheetAdded`, `styleSheetRemoved` | `registerStyleSheetHeader` / `removeStyleSheetHeader` and refresh | CSS stylesheet registry | Internal `StyleSheetHeader` registry + affected `CSSStyles.phase` refresh | Draft |
| CSS | `mediaQueryResultChanged`, `nodeLayoutFlagsChanged` | Current dispatcher marks target/node styles stale | CSS coordinator | `CSSStyles.phase = needsRefresh` | Draft |
| Network | `requestWillBeSent` | `applyRequestWillBeSent` inserts/updates request and redirect hop | Network coordinator | `NetworkRequest.url/method/requestHeaders/resourceType/state`, `redirects` | Draft |
| Network | `responseReceived` | `applyResponseReceived` updates response, body placeholders, state | Network coordinator | `NetworkRequest.status/mimeType/responseHeaders/requestBody/responseBody/state` | Draft |
| Network | `dataReceived` | Updates decoded/encoded byte counts and last-data timestamp | Network coordinator | `NetworkRequest` byte/timestamp fields | Draft |
| Network | `loadingFinished`, `loadingFailed` | Updates final state, metrics/sourceMapURL/timestamp, active-close data | Network coordinator | `NetworkRequest.state`, body availability/failure, metrics/sourceMapURL/timestamps | Draft |
| Network | `requestServedFromMemoryCache` | Upserts cached request/response, cached body size, byte lengths, finished state | Network coordinator | `NetworkRequest.response/state/responseBody`, cached body size | Draft |
| Network | WebSocket family | Created/handshake/frame/error/closed mutate websocket state and frames | Network/WebSocket coordinator | `NetworkRequest.webSocket`, `WebSocketState.readyState`, frames, handshake request/response | Draft |
| Console | `messageAdded` | Registers runtime objects in `.console`, then applies message | Console + Runtime coordinator | `ConsoleMessage.*`, `RuntimeObject` parameters, `networkRequestID` cross-link | Draft |
| Console | `messageRepeatCountUpdated` | Updates last message repeat count per target | Console coordinator | `ConsoleMessage.repeatCount`; private last-message-per-target owner | Draft |
| Console | `messagesCleared` | Clears console and releases `.console` runtime object group | Console + Runtime coordinator | Fetched console results clear; runtime object group release | Draft |
| Runtime | `executionContextCreated` | Runtime and DOM target graph record context | Runtime + target graph coordinator | `RuntimeContext`, `executionContexts`, `selectedContext`, frame/context mapping | Draft |
| Runtime | `executionContextDestroyed`, `executionContextsCleared` | Current code removes contexts/remote objects/default/selected context | Runtime coordinator | `RuntimeContext` removal, runtime object invalidation, selected context fallback | Draft |
| Page | `frameNavigated`, `frameDetached`, `loadEventFired`, `domContentEventFired` | No current Page dispatcher registered | Unknown | Unknown | Keep out of initial public surface or measure Page protocol before binding |
| Target | `targetCreated`, `targetDestroyed`, `didCommitProvisionalTarget` | Target graph/document/selection updates; `AttachedInspection` retargets Runtime/Console/Network | Proxy target registry + DataKit private coordinators | `WebViewTargetChange`, frame projection, console retarget, runtime object/context cleanup, network retarget | Draft |

Event-coverage notes:

- CSS target-wide invalidation: bind `styleSheetChanged`,
  `mediaQueryResultChanged`, and `nodeLayoutFlagsChanged` as refresh invalidation
  events; do not expose a fake style ID.
- Page events: current implementation has no Page dispatcher. Initial public
  surface should either keep Page command-only or add Page event support as a
  measured scope expansion.

## DTO Field Lists

Every public DTO/model field must be justified by at least one consumer story,
model apply path, or transitive closure requirement. Public fields that are only
wire passthrough trivia stay package unless a consumer story reaches them.

| Public type | Current source type(s) | Fields to publish | Nested public types required | Evidence | Status |
| --- | --- | --- | --- | --- | --- |
| `WebViewTarget` | `ProtocolTarget.Record`, `DOMTarget` | `id`, `kind`, `frameID`, `isProvisional`; keep capabilities/pause/routing internals package | `WebViewTarget.ID`, `FrameID` | `Sources/WebInspectorTransport/ProtocolTypes.swift`; `Sources/WebInspectorCoreDOMCSS/DOM/DOMModelTypes.swift` | Draft |
| `DOM.Node` / `DOMNode` | `DOMNode.Payload`, `DOMNode` | `id`, `nodeType`, `nodeName`, `localName`, `nodeValue`, `frameID`, `documentURL`, `baseURL`, `attributes`, `children/count`, `contentDocument`, `shadowRoots`, `templateContent`, `beforePseudoElement`, `otherPseudoElements`, `afterPseudoElement`, `pseudoType`, `shadowRootType` | `DOM.Attribute`, `DOM.Children` / `DOMNode.Children`, `DOM.PseudoType`, `DOM.ShadowRootType` | `Sources/WebInspectorCoreDOMCSS/DOM/DOMProtocol.swift`; `Sources/WebInspectorCoreDOMCSS/DOM/DOMModelTypes.swift`; `Sources/WebInspectorCoreDOMCSS/DOM/DOMProtocolDispatching.swift` | Draft |
| `Runtime.RemoteObject` / `RuntimeObject` | `RuntimeRemoteObject.Payload`, `RuntimeRemoteObject` | `id?`, `kind/type`, `subtype`, `className`, `value`, `description`, `size`, `preview`; DataKit uses synthetic IDs for by-value primitives | `Runtime.JSONValue`, open `Runtime.Kind` or type/subtype representation, `Runtime.ObjectPreview` | `Sources/WebInspectorCoreRuntime/Runtime/RuntimeProtocol.swift`; `Sources/WebInspectorCoreRuntime/Runtime/RuntimeModel.swift` | Draft |
| `Runtime.ObjectPreview` | `RuntimeRemoteObject.Preview.Payload` | `type`, `subtype`, `description`, `lossless`, `overflow`, `properties`, `entries`, `size` | `Runtime.PropertyPreview`, `Runtime.EntryPreview` | `Sources/WebInspectorCoreRuntime/Runtime/RuntimeProtocol.swift` | Draft |
| `Runtime.PropertyDescriptor` | `RuntimeRemoteObject.PropertyDescriptor.Payload` | `name`, `value`, `writable`, `get`, `set`, `wasThrown`, `configurable`, `enumerable`, `isOwn`, `symbol`, `isPrivate`, `nativeGetter` | `Runtime.RemoteObject` | `Sources/WebInspectorCoreRuntime/Runtime/RuntimeProtocol.swift` | Draft |
| `Runtime.CollectionEntry` | `RuntimeRemoteObject.CollectionEntry.Payload` | `key`, `value` | `Runtime.RemoteObject` | `Sources/WebInspectorCoreRuntime/Runtime/RuntimeProtocol.swift` | Draft |
| `Runtime.ExecutionContext` / `RuntimeContext` | `RuntimeExecutionContext.Payload`, `RuntimeContext.Record` | `id`, `name`, `frameID`, `kind/type`; keep target/runtime-agent IDs package | `Runtime.ContextKind`, `FrameID` | `Sources/WebInspectorCoreRuntime/Runtime/RuntimeProtocol.swift`; `Sources/WebInspectorTransport/RuntimeContextTypes.swift` | Draft |
| `Network.Request` | `NetworkRequest.Payload` | `id`, `url`, `method`, `headers`, `postData`, `referrerPolicy`, `integrity` | `Network.Request.ID`, `Network.ReferrerPolicy` | `Sources/WebInspectorCoreConsoleNetwork/Network/NetworkProtocol.swift` | Draft |
| `Network.Response` | `NetworkRequest.Response.Payload` | `url`, `status`, `statusText`, `headers`, `mimeType`, `source`, `requestHeaders`; keep timing/security package unless DataKit detail explicitly exposes summaries | `Network.Source` | `Sources/WebInspectorCoreConsoleNetwork/Network/NetworkProtocol.swift` | Draft |
| `NetworkRequest` | `NetworkRequest` | 05 minimum plus `documentURL`, `sourceMapURL`, request/response/data/finish timestamps, encoded/decoded lengths, `responseSource`; metrics/initiator only if UI detail requires them public | `Network.ResourceType`, `NetworkBody`, `RedirectHop`, `WebSocketState` | `Sources/WebInspectorCoreConsoleNetwork/Network/NetworkModel.swift` | Draft |
| `RedirectHop` | `NetworkRequest.RedirectHop` | `request`, `response`, `timestamp`; add opaque `id` only if DataKit identity needs it | `Network.Request`, `Network.Response` | `Sources/WebInspectorCoreConsoleNetwork/Network/NetworkModel.swift` | Draft |
| `WebSocketState.Frame` | `NetworkRequest.WebSocket.FrameEntry`, `FramePayload` | `direction`, `timestamp`, `opcode`, `mask`, `payloadData`, `payloadLength`, `errorMessage?` | `WebSocketState.ReadyState`, `WebSocketState.Frame.Direction` | `Sources/WebInspectorCoreConsoleNetwork/Network/NetworkModel.swift`; `Sources/WebInspectorCoreConsoleNetwork/Network/NetworkProtocol.swift` | Draft |
| `NetworkBody` | `NetworkBody`, `NetworkBody.Payload` | `role`, `kind`, `phase`, `text/full`, `size`, `isBase64Encoded`, `isTruncated`, `sourceSyntaxKind`, `textRepresentation`, `textRepresentationSyntaxKind` | `NetworkBody.Role`, `NetworkBody.Kind`, `NetworkBody.SyntaxKind`, `NetworkBody.Phase` | `Sources/WebInspectorCoreConsoleNetwork/Network/NetworkBody.swift` | Draft |
| `Console.Message` / `ConsoleMessage` | `ConsoleMessage.Payload`, `ConsoleMessage` | `id` for model, `source`, `level`, `text`, `type`, `url`, `line`, `column`, `repeatCount`, `parameters`, `stackTrace`, `networkRequestID`, `timestamp` | `Console.Source`, `Console.Level`, `Console.Kind`, `Console.StackTrace`, `Console.CallFrame` | `Sources/WebInspectorCoreConsoleNetwork/Console/ConsoleProtocol.swift`; `Sources/WebInspectorCoreConsoleNetwork/Console/ConsoleModel.swift` | Draft |
| `CSS.MatchedStyles` / `CSSStyles` | `CSSStyle.MatchedStylesPayload`, `InlineStylesPayload`, `CSSNodeStyles` | Proxy DTO exposes matched rules, pseudo elements, inherited, inline style, attributes style; DataKit exposes `phase`, `sections`, `computedProperties` | `CSS.Rule`, `CSS.Style`, `CSS.ComputedProperty` | `Sources/WebInspectorCoreDOMCSS/CSS/CSSProtocol.swift`; `Sources/WebInspectorCoreDOMCSS/CSS/CSSModel.swift` | Draft |
| `CSS.Style` | `CSSStyle.Payload`, `CSSStyle` | `id`, `properties`, `shorthandEntries`, `cssText`, `range`, `width`, `height`, `isEditable` | `CSS.Style.ID`, `CSS.Style.SourceRange`, `CSS.Style.ShorthandEntry`, `CSS.Property` | `Sources/WebInspectorCoreDOMCSS/CSS/CSSProtocol.swift`; `Sources/WebInspectorCoreDOMCSS/CSS/CSSModel.swift` | Draft |
| `CSS.Property` | `CSSProperty.Payload`, `CSSProperty` | `id`, `name`, `value`, `priority`, `text`, `parsedOk`, `status`, `implicit`, `range`, `isEditable`, `isModifiedByInspector` | `CSS.Property.ID`, `CSS.Property.Status`, `CSS.Style.SourceRange` | `Sources/WebInspectorCoreDOMCSS/CSS/CSSProtocol.swift`; `Sources/WebInspectorCoreDOMCSS/CSS/CSSModel.swift` | Draft |
| `CSS.Rule` | `CSSRule.Payload`, `CSSRule` | `id`, `selectorList`, `sourceURL`, `sourceLine`, `sourceLocation`, `origin`, `style`, `groupings`, `isImplicitlyNested` | `CSS.Rule.ID`, `CSS.Rule.SelectorList`, `CSS.Style.Origin`, `CSS.Rule.Grouping` | `Sources/WebInspectorCoreDOMCSS/CSS/CSSProtocol.swift`; `Sources/WebInspectorCoreDOMCSS/CSS/CSSModel.swift` | Draft |
| `CSS.StyleSheetHeader` | `CSSStyleSheet.HeaderPayload` | `styleSheetID`, `frameID`, `sourceURL`, `origin`, `title`, `disabled`, `isInline`, `startLine`, `startColumn` | `CSS.StyleSheet.ID`, `FrameID`, `CSS.Style.Origin` | `Sources/WebInspectorCoreDOMCSS/CSS/CSSProtocol.swift` | Draft |
| `Page.Frame` / `FrameID` | No current Page model in scoped sources | Out of initial public surface. Frame identity remains `FrameID`; frame projection is handled by target/DOM/Network coordinators. | `FrameID` | Current evidence only has `ProtocolFrame.ID`, target frame IDs, and Network frame/loader/document fields | Deferred |
| `RawEvent` | `ProtocolEvent` | `domain`, `method`, `params` | none beyond `Data` | `Sources/WebInspectorTransport/TransportTypes.swift`; measurement docs | Draft |

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
| A — DataKit consumer app | `WebViewDataKit` only | Compile on iOS and macOS without UIKit: `WebViewModelContainer(attachingTo:)`, `mainContext`, `rootNode`, `DOMNode.Children.loaded`, `.allRequests`, `fetchResponseBody()`, `evaluate()` | Runtime contract uses `WebViewModelContainer(proxy:)` over `WebViewProxyKitTesting`: DOM seed, network list, body fetch loaded/failed, runtime evaluation reflect into context/models | `cd ContractTests && swift test`; iOS xcodebuild once package products exist |
| A2 — Proxy-only consumer | `WebViewProxyKit` only | Compile without DataKit/UI: `WebViewProxy`, `waitForCurrentPage()`, `page.network.events`, `Network.Event.responseReceived` | Fake backend validates target replay, per-target event stream, event multicast, `close()` / `waitUntilClosed()` clean-vs-fatal behavior | `cd ContractTests && swift test`; targeted proxy fake tests |
| B — custom UIKit Console tab | `WebInspectorKit` + `WebViewDataKit` on iOS | Compile: `WebInspectorTab` factory still receives `WebInspectorSession`; custom tab reaches `session.modelContext`, `WebViewFetchedResultsController<ConsoleMessage>`, `context.evaluate`, `RuntimeObject.properties()` | No public fake-backed session initializer. Runtime behavior is covered inside WebInspectorKit tests using package/internal composition seams, because a public test-only DI initializer would bloat the product surface. | `cd ContractTests && xcodebuild test -scheme WebInspectorContractTests -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'`; WebInspectorKit workspace tests |
| C — drop-in UIKit compatibility | `WebInspectorKit` on iOS | Compile existing facade: `WebInspectorSession()`, `WebInspectorViewController(session:)`, `session.attach(to:)`, `WebInspectorViewController.attach(to:)`, `WebInspectorTab` factory shape | Runtime attach/detach/context lifecycle is covered by WebInspectorKit tests and the default workspace validation. ContractTests only assert the public UIKit shape from outside the package. | WebInspectorKit workspace tests; Monocly build/test after custom tab is added |

Minimum standalone package shape:

```text
ContractTests/
  Package.swift
  Tests/WebInspectorConsumerContractTests/
    StoryADataKitCompileContract.swift
    StoryA2ProxyKitCompileContract.swift
    StoryBConsoleTabCompileContract.swift
    StoryCUIKitCompatibilityCompileContract.swift
    StoryADataKitFakeBackendTests.swift
    StoryA2ProxyKitFakeBackendTests.swift
```

`Package.swift` uses `.package(path: "..")` and depends on
`WebViewProxyKit`, `WebViewDataKit`, `WebViewProxyKitTesting`, plus the iOS-only
`WebInspectorKit` product. The current root package does not yet expose the
three `WebView*` products, so this contract package is expected to fail until
the product graph migration lands.

Local validation commands:

```sh
xcodebuild test \
  -workspace WebInspectorKit.xcworkspace \
  -scheme WebInspectorKit \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'

cd ContractTests && swift test
cd ContractTests && xcodebuild test \
  -scheme WebInspectorContractTests \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'
```

If Monocly gains the custom Console tab in this series, validate the app target
too. The production call site to change is session creation in
`Monocly/Monocly/Controllers/BrowserRootViewController+UIKit.swift`, while the
sheet/window presentation and attach/detach lifecycle keep sharing the same
`WebInspectorSession`.

## W3 DataKit Preflight

The current semantic owners are the `WebInspectorCore*` session/store types.
W3 must not publish those types as-is; it should relocate their apply logic into
`WebViewModelContext`-owned DataKit models and controllers.

| Domain | Current owner evidence | W3 destination |
| --- | --- | --- |
| DOM tree | `DOMSession`, `DOMDocumentStore`, `TargetGraph`, `DOMDocument.NodeStore` in `Sources/WebInspectorCoreDOMCSS/DOM` own tree identity, current-page document projection, mutation apply, and selection | `WebViewModelContext` DOM coordinator, `DOMNode`, node identity map, `DOMTreeController` transactions |
| CSS styles | `CSSSession` and `CSSNodeStyleStore` in `Sources/WebInspectorCoreDOMCSS/CSS` own selected-node style refresh, matched styles, computed styles, stylesheet headers | DataKit CSS coordinator tied to DOM selection; style phases and stylesheet registry stay model-side |
| Network requests/body | `NetworkSession`, private `NetworkRequestStore`, `NetworkRequest`, and `NetworkBody` in `Sources/WebInspectorCoreConsoleNetwork/Network` own request order, state, metrics, and body fetch phase | DataKit network coordinator, fetched request results, request identity/order, body availability/failure |
| Console messages | `ConsoleSession`, `ConsoleTargetRegistry`, and `TargetState` in `Sources/WebInspectorCoreConsoleNetwork/Console` own per-target message order and aggregation | DataKit console coordinator with target-aware message order and runtime/network cross-links |
| Runtime objects/contexts | `RuntimeState` and `RuntimeState.AgentState` in `Sources/WebInspectorCoreRuntime/Runtime` own contexts, selected context, and remote-object identity map | DataKit runtime coordinator, `RuntimeContext`, `RuntimeObject`, object-group lifecycle, context selection |

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
  the same fake-proxy data flow as tests once `WebViewProxyKitTesting` supports
  target-scoped event streams.

Minimum W3 contract tests after W2 lands:

| Contract | Required proof |
| --- | --- |
| DOM identity + tree transaction | Fake proxy emits document and child mutations; `rootNode`, `node(for:)`, and `DOMTreeController` transactions keep stable semantic node identity across updates |
| Network request/body lifecycle | `requestWillBeSent` → `responseReceived` → `dataReceived` → terminal event → `fetchResponseBody()` produces one ordered request and expected body phase |
| Console + Runtime linking | Runtime context plus console message parameters register `RuntimeObject` values; console messages with `networkRequestID` resolve to the matching request |
| Provisional target commit stability | Provisional target commit preserves current-page semantic identity and correctly retargets DOM/CSS invalidation, Runtime cleanup, Console order, and Network ownership |
| CSS selection refresh | Selecting a DOM node then receiving matched/computed style results transitions selected styles from loading to loaded; stylesheet changes mark affected styles stale |

## Worker Split

Workers must not change the architecture contract. If a worker discovers that a
public API shape, owner boundary, or test strategy must change, it escalates to
the main agent instead of improvising.

Initial split candidates:

| Worker | Owner boundary | Primary write set | Prerequisites | Validation |
| --- | --- | --- | --- | --- |
| W1 — package graph + ProxyKit shell | `WebViewProxyKit` owns native attach, raw transport, target registry, terminal lifecycle | `Package.swift`; new/renamed `Sources/WebViewProxyKit/**`; moved transport/native/support files; targeted transport/proxy tests | G1/G2 target + transport rows | `swift build`; targeted transport/proxy tests; no public raw envelope |
| W2 — typed proxy domain clients | `WebViewTarget` owns route-scoped typed commands/events; proxy does not accumulate semantic state | `Sources/WebViewProxyKit/**/DOM*`, `CSS*`, `Network*`, `Console*`, `Runtime*`; proxy DTO/event tests | W1 branch merged or rebased | Proxy fake tests over `WebViewProxyKitTesting`; event coverage rows remain mapped |
| W3 — DataKit model/context owners | `WebViewModelContext` owns semantic state, identity maps, apply handlers, FRC/tree controllers | new `Sources/WebViewDataKit/**`; DataKit tests over fake proxy | W1 shell and W2 DTO/event shape stable | DataKit tests; no UI imports; model identities stable across target commit |
| W4 — UIKit compatibility layer | `WebInspectorSession` owns UIKit facade over DataKit container/context; tabs keep receiving session | `Sources/WebInspectorUI/**`, `Sources/WebInspectorKit/**`, UIKit tests, Monocly call site if custom tab is included | W3 context API stable | default workspace `xcodebuild test`; Monocly build/test if changed |
| W5 — ContractTests package | Public products are the only imports; no `@testable` | `ContractTests/**`; README/MIGRATION snippets if needed | Product graph exports W1-W4 surfaces | `cd ContractTests && swift test`; iOS `xcodebuild test` for UIKit stories |

Integration order: W1 → W2 → W3 → W4 → W5. W2 and W3 can be explored in
parallel, but implementation should merge through the order above because W3
depends on the typed event/DTO contract and W4 depends on the DataKit context
surface.
