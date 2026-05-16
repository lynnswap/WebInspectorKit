# Network Model Research

This note records the WebKit Network model behavior that `WebInspectorCore` is
comparing against.

## WebKit Shape

- The Network domain is available for `itml`, `page`, and `service-worker`
  targets in the checked protocol metadata. Many commands and events, including
  interception and WebSocket events, are narrower and are marked `page` only.
- `Network.RequestId`, `Network.FrameId`, and `Network.LoaderId` are protocol
  string identifiers.
- The backend creates `requestId` from `ResourceLoaderIdentifier` through
  `IdentifiersFactory::requestId`, which formats non-zero identifiers through
  the shared `0.<identifier>` inspector id scheme.
- `requestWillBeSent` carries `requestId`, `frameId`, `loaderId`,
  `documentURL`, request payload, timestamps, initiator, optional
  `redirectResponse`, optional resource type, and optional `targetId`.
- The optional `requestWillBeSent.targetId` describes the origin context of the
  load, such as a target identifier or worker id. It is payload metadata, not
  the protocol event envelope target.
- `responseReceived`, `dataReceived`, `loadingFinished`, and `loadingFailed`
  continue the same request by `requestId`.
- WebInspectorUI stores one `Resource` per active `requestIdentifier` in
  `NetworkManager._resourceRequestIdentifierMap`.
- When `requestWillBeSent` arrives for an existing `requestIdentifier`,
  WebInspectorUI treats it as a redirect and updates the same `Resource` by
  calling `Resource.updateForRedirectResponse`.
- Redirects are stored as `WI.Redirect` history on the parent `Resource`.
  Network table redirect rows are derived entries, not separate protocol
  request identities.
- `requestServedFromMemoryCache` is a one-shot event in WebInspectorUI: it
  creates a finished cached `Resource`, fills response/source/size state, and
  does not keep the `requestIdentifier` in the active request map.
- Initial `Page.getResourceTree` import creates finished `Resource` objects
  from frame/resource payloads. These resources may not have a
  `requestIdentifier` until a later live network event can associate one.
- WebSocket events use `requestId` too, but current WebInspectorUI has a FIXME
  for iframe and worker WebSockets and attaches WebSocket resources to the main
  frame path.

## Source Evidence

| Area | WebKit source | Relevant fact |
| --- | --- | --- |
| Protocol target availability | `Source/JavaScriptCore/inspector/protocol/Network.json`, `Source/WebInspectorUI/UserInterface/Protocol/Legacy/iOS/26.4/InspectorBackendCommands.js`, `Source/WebInspectorUI/UserInterface/Protocol/Legacy/macOS/26.4/InspectorBackendCommands.js` | Network is registered for `itml`, `page`, and `service-worker`; it activates for `itml`, `service-worker`, and `web-page`. Several commands/events are still `page`-only. |
| Protocol identifiers | `Source/JavaScriptCore/inspector/protocol/Network.json` | `RequestId`, `FrameId`, and `LoaderId` are separate string types. Continuation events carry `requestId`; only selected events also carry frame/loader. |
| Request id generation | `Source/JavaScriptCore/inspector/IdentifiersFactory.cpp`, `Source/WebCore/inspector/agents/InspectorNetworkAgent.cpp` | `InspectorNetworkAgent` converts `ResourceLoaderIdentifier` to `Network.RequestId` with `IdentifiersFactory::requestId`. |
| Request start payload | `Source/JavaScriptCore/inspector/protocol/Network.json`, `Source/WebCore/inspector/agents/InspectorNetworkAgent.cpp` | `requestWillBeSent` contains request metadata, optional `redirectResponse`, optional resource type, and optional origin `targetId`. |
| Redirect handling | `Source/WebInspectorUI/UserInterface/Controllers/NetworkManager.js`, `Source/WebInspectorUI/UserInterface/Models/Resource.js`, `Source/WebInspectorUI/UserInterface/Models/Redirect.js` | An existing `requestIdentifier` causes `Resource.updateForRedirectResponse`, which updates current request fields and appends a `WI.Redirect`. |
| Redirect rows | `Source/WebInspectorUI/UserInterface/Views/NetworkTableContentView.js` | Redirect rows are populated from `resource.redirects`; their size/timing/type values are derived UI estimates. |
| Response/data/finish/fail | `Source/WebInspectorUI/UserInterface/Controllers/NetworkManager.js`, `Source/WebInspectorUI/UserInterface/Models/Resource.js` | Response events update type, headers, timing, source, and security. Data events increment counters. Finish/fail removes the active request map entry. Finish applies final `Network.Metrics` when present. |
| Memory cache event | `Source/WebInspectorUI/UserInterface/Controllers/NetworkManager.js` | `requestServedFromMemoryCache` creates and finishes a cached resource and intentionally does not store the id for future loading events. |
| Initial resource tree | `Source/WebInspectorUI/UserInterface/Controllers/NetworkManager.js` | `Page.getResourceTree` import resets frame/resource maps and creates already-finished resources that may lack `requestIdentifier`. |
| WebSocket events | `Source/JavaScriptCore/inspector/protocol/Network.json`, `Source/WebInspectorUI/UserInterface/Controllers/NetworkManager.js`, `Source/WebInspectorUI/UserInterface/Protocol/NetworkObserver.js` | WebSocket events use `requestId`; WebInspectorUI maps them through the same active request map, but frame/worker placement is explicitly incomplete and `webSocketFrameError` is not implemented in `NetworkObserver`. |
| Resource content commands | `Source/WebInspectorUI/UserInterface/Models/Resource.js`, `Source/JavaScriptCore/inspector/protocol/Network.json` | Response body and serialized certificate commands use the parent resource's `requestIdentifier` on its target's `NetworkAgent`; redirect history ids are not sent to the backend. |

## 2026-05-16 WebKit Source Reverification

The Network research was rechecked against WebKit source. The request identity
conclusion is unchanged: `Network.RequestId` is the protocol request identity,
and redirect rows are derived history. The review narrowed a few edge cases:

- The optional `requestWillBeSent.targetId` is origin metadata. The command
  target remains the protocol event envelope target.
- WebInspectorUI's live request map is keyed by raw `requestIdentifier`, but
  this is inside the active frontend target model. In a multi-target Core, the
  event envelope target is the collision boundary across targets.
- `requestServedFromMemoryCache` is not followed by the usual finish/fail
  sequence in WebInspectorUI. It creates a finished cached resource directly.
- WebSocket resources use `requestId`, but current WebInspectorUI placement is
  not a complete multi-frame or worker model.
- Redirect details intentionally contain only basic request/response header and
  status data. The redirect model comments note that detailed timing, metrics,
  and security are not populated for `redirectResponse`.

## Derived Concepts

The source evidence implies these separate concepts:

- `ProtocolTarget`: protocol routing endpoint that receives Network events and
  owns Network commands.
- `TargetCapabilities`: per-target Network domain and command availability.
  A target kind alone is not enough; WebInspectorUI enables Network only after
  `target.hasDomain("Network")`.
- `NetworkRequest`: the live request/resource identity for a
  `Network.RequestId` within one protocol event target.
- `OriginatingTargetID`: optional payload metadata from `requestWillBeSent`.
  It can place a `Resource` under a worker or other target, but it is not the
  same as the event envelope target.
- `NetworkFrameID`: protocol frame id used to place page resources in the
  frame tree. It is not DOM node identity.
- `NetworkLoaderID`: loader lifetime identifier used to group main resource
  and subresource activity for frame/provisional load state.
- `NetworkRedirectHop`: derived history attached to one `NetworkRequest`.
  It may have its own UI row and detail view, but it does not become a backend
  request id.
- `InitialResourceTreeResource`: resource imported from `Page.getResourceTree`.
  It can be finished and visible without a live `requestIdentifier`.
- `MemoryCacheResource`: one-shot cached resource created from
  `requestServedFromMemoryCache`.

## Derived Model Invariants

- Primary request identity is `ProtocolTarget.ID + Network.RequestId`.
- `redirectIndex` is a derived UI/history discriminator only. It is not sent to
  WebKit as a request id.
- `requestWillBeSent` for an existing active request id with
  `redirectResponse` appends redirect history and replaces the current request
  payload on the same request.
- `responseReceived` is authoritative for response headers, MIME type,
  response source, timing, security, and final resource type.
- `loadingFinished` is authoritative for source map URL and final
  `Network.Metrics`. Exact byte sizes from metrics supersede estimated data
  counters when available.
- `loadingFailed` and `loadingFinished` close the active request map entry.
- `requestServedFromMemoryCache` creates a completed cached request directly;
  it does not require a matching `loadingFinished`.
- Initial resource tree import is a page/frame snapshot, not a live request
  event replay.
- WebSocket handshake, frame, and close events share `requestId` with Network,
  but WebInspectorUI's current placement is a known incomplete area.

## Event Flow

```text
Network.requestWillBeSent
  ├─ no active request:
  │   └─ create NetworkRequest(eventTargetID + requestID)
  ├─ active request + redirectResponse:
  │   ├─ append NetworkRedirectHop(requestID + redirectIndex)
  │   └─ replace current request URL/method/headers/referrer/integrity
  └─ active request without redirectResponse:
      └─ ambiguous duplicate; not a new primary identity

Network.responseReceived
  └─ update current response, type, timing, source, and security

Network.dataReceived
  └─ add decoded and encoded byte counters when available

Network.loadingFinished
  ├─ apply final Network.Metrics when present
  ├─ record sourceMapURL when present
  ├─ mark finished
  └─ close active request entry

Network.loadingFailed
  ├─ mark failed/canceled
  └─ close active request entry

Network.requestServedFromMemoryCache
  └─ create finished cached request directly

Network.webSocket*
  └─ use requestID for handshake/resource/frame history, with upstream
     frame/worker placement limitations
```

## Identity Diagram

```text
Protocol event target: page-1
RequestId: 0.42

NetworkRequest.ID
  └─ page-1 + 0.42

Redirect hop rows
  ├─ page-1 + 0.42 + redirectIndex 0
  └─ page-1 + 0.42 + redirectIndex 1

Protocol commands
  └─ target page-1, requestId 0.42
```

`redirectIndex` never goes back to WebKit as a protocol request identity. It
is a WebInspector UI/HAR/history identifier only.

## Contradicted Interpretations

```text
targetID + requestID + redirectIndex == primary request identity
or
requestWillBeSent.targetId == protocol event envelope target
or
redirect response == separate Resource
or
requestServedFromMemoryCache requires a later loadingFinished
or
initial Page resource tree import is a replay of live Network events
```

## Relationship to DOM and Targets

- Network `frameId` belongs to the Page/Network frame tree. It is not a DOM
  node id and does not identify iframe owner elements.
- DOM selection can hand a target/node identity to CSS, but Network request
  identity is independent of DOM node identity.
- Network target routing follows protocol target capabilities. Optional
  `targetId` in a request payload is placement/origin metadata, not a
  replacement for the event target.
- Service worker resources can be attached to a target without a page frame.
  Page resources can be attached to frames. Orphaned resource handling exists
  when a payload references a target that is not yet available.

## Source References

- `Source/JavaScriptCore/inspector/protocol/Network.json`
- `Source/JavaScriptCore/inspector/IdentifiersFactory.cpp`
- `Source/WebCore/inspector/agents/InspectorNetworkAgent.cpp`
- `Source/WebInspectorUI/UserInterface/Protocol/NetworkObserver.js`
- `Source/WebInspectorUI/UserInterface/Controllers/NetworkManager.js`
- `Source/WebInspectorUI/UserInterface/Models/Resource.js`
- `Source/WebInspectorUI/UserInterface/Models/Redirect.js`
- `Source/WebInspectorUI/UserInterface/Views/NetworkTableContentView.js`
- `Source/WebInspectorUI/UserInterface/Protocol/Legacy/iOS/26.4/InspectorBackendCommands.js`
- `Source/WebInspectorUI/UserInterface/Protocol/Legacy/macOS/26.4/InspectorBackendCommands.js`
