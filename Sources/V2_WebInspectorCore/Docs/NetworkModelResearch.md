# Network Model Research

This note records the WebKit Network model behavior that `V2_WebInspectorCore` is intentionally matching.

## WebKit Shape

- The Network protocol defines `RequestId`, `FrameId`, and `LoaderId` as protocol string identifiers.
- `requestWillBeSent` carries `requestId`, `frameId`, `loaderId`, `documentURL`, request payload, timestamps, initiator, optional `redirectResponse`, optional resource type, and optional `targetId`.
- `responseReceived`, `dataReceived`, `loadingFinished`, and `loadingFailed` continue the same request by `requestId`.
- WebKit backend creates `requestId` from `ResourceLoaderIdentifier`.
- WebInspectorUI stores one `Resource` per `requestIdentifier`.
- When `requestWillBeSent` arrives for an existing `requestIdentifier`, WebInspectorUI treats it as a redirect and updates the same `Resource`.
- Redirects are stored as history on the `Resource`, not as separate request identities.

## V2 Model Decisions

- `NetworkRequest.ID` is `targetID + requestID`.
- `targetID` is the protocol event envelope target, not the optional payload `targetId`.
- `requestID` remains the WebKit protocol `Network.RequestId` string.
- `NetworkRedirectHopIdentifier` is `NetworkRequest.ID + redirectIndex`.
- Redirect hops are derived history records on a request. They are valid for headers UI, expandable table rows, and HAR export, but not for the primary request identity.
- A duplicate `requestWillBeSent` for an existing request updates the request only when `redirectResponse` is present.
- Target-scoped identity avoids collisions when different protocol targets emit the same raw `requestId`.
- The request record intentionally mirrors WebKit's `Resource` data shape even when a property is not currently rendered by WebInspectorKit UI.
- `requestWillBeSent` preserves request headers, POST data, referrer policy, integrity, initiator, optional resource type, and optional protocol `targetId`.
- `responseReceived` is authoritative for resource type, response headers, MIME type, response source, refined request headers, timing, and security.
- `loadingFinished` is authoritative for source map URL and final `Network.Metrics`; size counters are overwritten by exact metrics when available, matching WebInspectorUI's `Resource.updateWithMetrics`.
- `requestServedFromMemoryCache` creates a finished cached request with cached body size and response source.
- WebSocket events are represented as the same target-scoped request identity with handshake payloads, ready state, and frame history.

## Model Shape

```text
NetworkSession
  ├─ orderedRequestIDs: [NetworkRequest.ID]
  └─ requestsByID
      └─ NetworkRequest.ID = targetID + requestID
          ├─ frameID
          ├─ loaderID
          ├─ documentURL
          ├─ originatingTargetID?
          ├─ initiator?
          ├─ current request payload
          ├─ current response payload?
          ├─ sourceMapURL?
          ├─ metrics?
          ├─ cachedResourceBodySize?
          ├─ websocket handshake/state/frames
          ├─ redirects
          │   └─ NetworkRedirectHop.ID = NetworkRequest.ID + redirectIndex
          │       ├─ original request payload
          │       └─ redirect response payload
          ├─ timestamps
          ├─ transfer counters
          └─ state
```

## Event Flow

```text
Network.requestWillBeSent
  ├─ no existing request:
  │   └─ create NetworkRequest(targetID + requestID), preserving request metadata and initiator
  ├─ existing request + redirectResponse:
  │   ├─ append NetworkRedirectHop(requestID + redirectIndex)
  │   └─ replace current request payload with redirected request
  └─ existing request without redirectResponse:
      └─ keep existing request

Network.responseReceived
  └─ set frame/loader/type/current response/timing/security and mark responded

Network.dataReceived
  └─ add decoded/encoded byte counters

Network.loadingFinished
  ├─ preserve sourceMapURL
  ├─ apply exact Network.Metrics if present
  └─ mark finished

Network.loadingFailed
  └─ mark failed(errorText, canceled)

Network.requestServedFromMemoryCache
  └─ create finished cached request from CachedResource payload

Network.webSocket*
  └─ keep handshake, ready state, and frame history on targetID + requestID
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

`redirectIndex` never goes back to WebKit as a protocol request identity. It is a V2 UI/HAR/history identifier only.

## Current Coverage

Implemented in the V2 model:

- request start
- redirect history
- response received
- data received counters
- loading finished
- loading failed
- refined request headers
- referrer policy and integrity
- initiator metadata
- response timing and security metadata
- loading metrics and exact byte sizes
- source map URL
- memory cache event
- target-scoped request identity
- WebSocket handshake, frames, errors, and close state
- body and serialized certificate command intents

Not implemented yet:

- initial Page resource tree import
- request interception
- initiator node/script stack modeling
- resource override/local resource integration

These should not be faked with placeholder state.

## Source References

- `Source/JavaScriptCore/inspector/protocol/Network.json`
- `Source/WebInspectorUI/UserInterface/Controllers/NetworkManager.js`
- `Source/WebInspectorUI/UserInterface/Models/Resource.js`
- `Source/WebInspectorUI/UserInterface/Views/NetworkTableContentView.js`
- `Source/WebCore/inspector/agents/InspectorNetworkAgent.cpp`
- `Source/JavaScriptCore/inspector/IdentifiersFactory.cpp`
