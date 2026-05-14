# DOM Model Research

This note records the WebKit DOM model behavior that `V2_WebInspectorCore` is intentionally matching.

## 2026-05-14 Corrections

The earlier debugging direction was too flow-oriented. The model boundary must
be fixed first. The important WebKit facts are:

- `DOM.Node.frameId` is not the iframe owner's child-frame id. The protocol
  defines it as the "Identifier of the containing frame" and
  `InspectorDOMAgent::buildObjectForNode` fills it from the node's own
  document/frame. For a page-target iframe element, that value is the page
  document's frame, not the out-of-process child document.
- `Target.TargetInfo` in current WebKit protocol contains `targetId`, `type`,
  `isProvisional`, and `isPaused`; it does not expose `frameId` or
  `parentFrameId` as protocol fields. WebKit's implementation-generated frame
  target id currently has the shape `frame-<frameID>-<processID>`, but that is
  an implementation detail, not a DOM model identity contract.
- `Runtime.ExecutionContextDescription.frameId` is "Id of the owning frame".
  It can supplement target/frame mapping, but it is not an iframe owner
  relation by itself.
- `DOM.Node.contentDocument` is the protocol field for frame owner elements,
  but Site Isolation means a cross-origin frame document often arrives through
  the frame target's `DOM.getDocument`, not as the page-target iframe payload's
  `contentDocument`.
- WebInspectorUI keeps frame-target DOM nodes target-scoped by prefixing the
  raw node id with the frame target id. It does not let raw protocol node ids
  collide across page/frame targets.
- WebInspectorUI does not use page reload as iframe recovery. A frame-target
  `DOM.documentUpdated` calls `_frameTargetDocumentUpdated`, which cleans up
  only that frame target and reinitializes that target's document.
- `_ensurePageBodyChildrenLoaded` is not a generic missing-parent repair
  mechanism. It exists because `_unsplicedFrameDocuments` need iframe owner
  nodes to be present in `_idToDOMNode`; it requests `<html>` children if
  needed, then `<body>` children, and then retries frame document splice.
- `InspectorDOMAgent` only emits DOM mutation events for nodes it has already
  bound for the frontend. `didInsertDOMNode` returns if the parent has no bound
  node id. If the parent is bound but its children were not requested, it emits
  `childNodeCountUpdated`; only when children were requested does it emit
  `childNodeInserted`. Therefore a V2-side `missingParent` for a page-target
  `childNodeInserted` means V2 lost, replaced, or misrouted a node that the
  backend believes was already sent. It is an invariant breach in V2's target /
  document / node mirror, not a picker problem and not something to solve by
  blindly reloading the page document.

The immediate modeling conclusion is:

```text
Target-scoped document identity must be primary.
Frame document projection must be explicit state.
Page DOM mutation handling must preserve the current target/document mirror.
Iframe owner discovery may request page html/body children, but only as part of
pending frame-document splice, not as a standalone event-drop workaround.
```

## Source Evidence

| Area | WebKit source | Relevant fact |
| --- | --- | --- |
| DOM protocol node identity | `Source/JavaScriptCore/inspector/protocol/DOM.json` | `DOM.Node.frameId` is the containing frame; `contentDocument` is the frame owner document field; `requestChildNodes(depth: -1)` means entire subtree but default is depth 1. |
| Backend node payload | `Source/WebCore/inspector/agents/InspectorDOMAgent.cpp` | `buildObjectForNode` sets `frameId` from the node's document frame and sets `contentDocument` only when a frame owner has an accessible content document. |
| Backend mutation contract | `Source/WebCore/inspector/agents/InspectorDOMAgent.cpp` | `didInsertDOMNode` returns when parent is not bound; otherwise it emits `childNodeCountUpdated` or `childNodeInserted` depending on whether children were requested. |
| Target protocol | `Source/JavaScriptCore/inspector/protocol/Target.json` | `TargetInfo` has no protocol-level frame id fields; `didCommitProvisionalTarget` swaps old/new target ids. |
| Frame target id implementation | `Source/WebKit/WebProcess/Inspector/FrameInspectorTarget.cpp` | Current implementation formats frame target ids as `frame-<frameID>-<processID>`. This is useful evidence, not a substitute for explicit model fields. |
| Target frontend | `Source/WebInspectorUI/UserInterface/Controllers/TargetManager.js` | WebInspectorUI creates `WI.FrameTarget` from target type and dispatches provisional messages after commit. |
| Target transport | `Source/WebInspectorUI/UserInterface/Protocol/TargetObserver.js` and `Connection.js` | `Target.dispatchMessageFromTarget` is routed to the target connection before domain dispatch. |
| Frame target DOM flow | `Source/WebInspectorUI/UserInterface/Controllers/DOMManager.js` | `_initializeFrameTarget` sends `DOM.getDocument` to the frame target, stores the frame document separately, and attempts splice. |
| Pending splice | `Source/WebInspectorUI/UserInterface/Controllers/DOMManager.js` | `_unsplicedFrameDocuments` holds frame documents until owner iframes are available; `_ensurePageBodyChildrenLoaded` requests page html/body children. |
| Projection attach | `Source/WebInspectorUI/UserInterface/Controllers/DOMManager.js` | `_trySpliceFrameDocumentIntoNode` attaches the frame document as iframe `_contentDocument`; current fallback is exact/resolved URL match with a WebKit FIXME to use frame/target identity later. |
| Frame target document refresh | `Source/WebInspectorUI/UserInterface/Controllers/DOMManager.js` | `_frameTargetDocumentUpdated` cleans up and reinitializes only that frame target. |
| Node scoping/projection | `Source/WebInspectorUI/UserInterface/Models/DOMNode.js` | Frame-target node ids are scoped as `<target id>:<raw node id>`; `_setChildrenPayload` returns if `_contentDocument` exists. |
| DOM event dispatch | `Source/WebInspectorUI/UserInterface/Protocol/DOMObserver.js` | DOM events are target-aware; frame-target document updates and setChildNodes route to frame-target handlers. |

## What This Means for V2

V2 must model these as separate concepts:

- `ProtocolTarget`: protocol routing endpoint. Owns target-local agent commands
  and target-local DOM events.
- `FrameIdentity`: WebKit frame id when known. It may come from document
  payload `frameId`, execution context `frameId`, or implementation-specific
  target id decoding only when deliberately supported.
- `DOMDocument`: target-scoped document generation and root node. Page target
  and frame target documents are never substitutes for each other.
- `DOMNode`: node mirror scoped by target document generation plus raw
  protocol node id. `ownerFrameID` means containing frame, not child frame.
- `FrameDocumentProjection`: relation between one iframe/frame owner node and
  one frame-target document root. This is not a regular `children` array.
- `PendingFrameDocument`: frame-target document that exists but has not yet
  found its iframe owner in the page DOM.
- `PageOwnerHydration`: the WebKit `_ensurePageBodyChildrenLoaded` equivalent.
  It is keyed by page document generation and exists only to make pending
  projections discover owner iframe nodes.

The invalid model is:

```text
DOM.Node.frameId == child frame id
or
frame target DOM.getDocument replaces/repairs page target document
or
missing page mutation parent -> reload page DOM
```

The valid model is:

```text
ProtocolTarget(page)
  currentDocument -> DOMDocument(page generation N)
    node ids scoped to page target/generation
    iframe owner node
      projection -> DOMDocument(frame target generation M)

ProtocolTarget(frame)
  currentDocument -> DOMDocument(frame target generation M)
    node ids scoped to frame target/generation

FrameDocumentProjection(owner node, frame document root, state: pending|attached)
```

## WebKit Shape

- `DOMManager` owns the frontend node index and current document state.
- `DOMNode` instances are created from WebKit DOM protocol payloads and are indexed by protocol node identity.
- Frame targets are handled separately from the page document. A frame target document is fetched from that target and then spliced into the matching iframe as `contentDocument`.
- If the iframe owner is not yet available, WebKit keeps the frame document unspliced and retries when more page nodes are loaded.

## WebKit Site Isolation Shape

In Site Isolation mode, WebKit treats a frame as an inspector target, not as
just another subtree inside the page target:

- Each `WebFrameProxy` creation creates a `FrameInspectorTargetProxy` in
  UIProcess and a `WI.FrameTarget` in WebInspectorUI.
- The page still has a `PageInspectorTargetProxy`, but cross-origin frame
  content can live behind a different `FrameInspectorController` in another
  WebContent process.
- Frame-to-page and frame-to-frame relationships are metadata. They are not
  the lifetime owner of protocol targets.
- Commands for frame-scoped domains are routed through the target system to the
  frame target. The frontend receives frame events as
  `Target.dispatchMessageFromTarget(targetId, message)`.
- Cross-origin iframe navigation can produce a provisional frame target before
  commit. The frontend must handle `Target.didCommitProvisionalTarget` and must
  not keep using the first provisional target as the final frame target.

For DOM specifically, the Site Isolation explainer calls out the important
model split: legacy `InspectorDOMAgent` traversed into iframe
`contentDocument`, but out-of-process frame documents must not be exposed as
ordinary page-target children. The frontend discovers child frame DOM trees via
frame targets instead.

This means a cross-origin iframe is represented by two related but separate
things:

```text
Page target DOM
  #document
    html
      body
        iframe/frame owner node

Frame target DOM
  #document
    html
      body
        ...
```

The connection between those two documents is frame/target ownership, not a
single page-target `children` array.

## WebInspectorUI Frame Document Flow

WebInspectorUI's current DOM code is a bridge between old page-DOM assumptions
and Site Isolation frame targets:

- `DOMObserver.documentUpdated()` dispatches by target type.
  - For `WI.FrameTarget`, it calls `DOMManager._frameTargetDocumentUpdated`.
  - For the page target, it calls `DOMManager._documentUpdated`.
- `DOMManager._documentUpdated()` clears the current page document by calling
  `_setDocument(null)`. A new page document is requested later through
  `requestDocument` / `ensureDocument`, not by treating every DOM update as an
  iframe recovery reload.
- `DOMManager._initializeFrameTarget(target)` calls
  `target.DOMAgent.getDocument`, creates a `DOMNode` with `{frameTarget:
  target}`, stores it in `_frameTargetDOMData`, and then tries to splice that
  frame document into the page tree.
- `DOMNode` stores frame-target nodes under a scoped frontend id:
  `<frame target id>:<raw node id>`. The raw node id remains target-local.
- `DOMManager._spliceFrameDocumentIntoPageTree` tries to attach the frame
  document to the matching iframe owner. WebKit currently does this with URL
  matching and explicitly marks that as fragile; the desired identity is
  frame/target metadata.
- If the iframe owner is not yet known, the document is kept in
  `_unsplicedFrameDocuments`. `DOMManager._ensurePageBodyChildrenLoaded`
  requests page body children, and `_trySpliceUnsplicedFrameDocuments` is
  retried from both `_setChildNodes` and `_childNodeInserted`.
- `DOMManager._frameTargetDocumentUpdated(target)` cleans up only the previous
  frame-target document and then reinitializes that frame target. It does not
  reset the parent page document.
- `DOMNode._setChildrenPayload` returns early when the node already has a
  `contentDocument`. So a later `DOM.setChildNodes` on an iframe owner must not
  replace or erase the frame document projection.

`DOM.setChildNodes(parentId: 0)` is a detached-root path used by
`pushNodePathToFrontend` when the pushed node has no parent. Normal inspect
selection path hydration walks up to a bound ancestor and emits
`setChildNodes` for real parent ids. Missing-parent events during selection are
therefore a signal that the owning target/document chain is absent or stale,
not a signal to replace the current page document.

## V2 Model Decisions

- `DOMSession` is the source of truth for page, frame, document, node, execution-context, and selection state.
- `DOMNode.ID` is `targetID + documentGeneration + nodeID`, so the same protocol `nodeID` in different targets or document generations cannot collide.
- `DOMNodeCurrentKey` is only a current mirror lookup key: `targetID + nodeID`.
- `DOMNode.ownerFrameID` is the containing frame id from protocol
  `DOM.Node.frameId`. It must never be used as the iframe owner node's child
  frame id.
- iframe documents are not stored as regular DOM children. Projection renders `DOMFrame.currentDocumentID` under the iframe owner node.
- Frame document refresh updates only that frame's current document generation and does not mutate the parent page document.
- Selection stores node identifiers and request generation, not stale node object references.

## Model Shape

```text
DOMSession
  ├─ ProtocolTarget(page)
  │   └─ currentDocumentID -> DOMDocument(page target, generation N)
  │       └─ DOMNode tree scoped by page target/generation
  │           └─ iframe/frame owner node
  │               └─ projected contentDocumentID -> frame document root
  ├─ ProtocolTarget(frame)
  │   └─ currentDocumentID -> DOMDocument(frame target, generation M)
  │       └─ DOMNode tree scoped by frame target/generation
  ├─ DOMFrame / FrameIdentity
  │   ├─ targetID?
  │   ├─ currentDocumentID?
  │   └─ ownerNodeID?
  └─ FrameDocumentProjection
      └─ pending or attached owner/contentDocument relation
```

## Identity Rules

- `ProtocolTarget.ID`: WebKit target identifier.
- `DOMFrame.ID`: WebKit frame identifier when known. Do not assume current
  `TargetInfo` exposes this directly.
- `DOMDocument.ID`: `targetID + documentGeneration`.
- `DOMNode.ID`: `documentID + nodeID`.
- `DOMNodeCurrentKey`: `targetID + nodeID` for resolving the current node mirror within one target.

`backendNodeId`, URL strings, raw node ids, and `page-*` naming are not global
DOM identity. The current `frame-<frameID>-<processID>` target-id shape is
implementation evidence only; it may be decoded deliberately as a WebKit
compatibility signal, but the Core model still needs explicit fields for
target, frame, document, node, and projection.

## Frame Documents

Frame documents are owned by the frame target's current document and projected
through `DOMFrame.currentDocumentID` / `FrameDocumentProjection`.

An iframe node does not get its child frame identity from protocol
`DOM.Node.frameId`. That value is the iframe node's containing frame. A future
explicit child-frame field can directly bind the owner; until then, owner
discovery is a separate projection step. The projected document is not stored
as an iframe regular child.

This preserves the parent page DOM when an iframe ad refreshes or navigates.

For cross-origin frames, a page-target iframe node may initially be known
before the frame-target document arrives, or the frame-target document may
arrive before the iframe owner is loaded. The model needs an explicit pending
frame-document state for this gap. Recovery should load or hydrate the missing
owner path; it should not collapse the frame document into the page document or
rebuild the page document from a shallow `DOM.getDocument` response.

## Selection

Selection is transaction based:

1. Resolve `RemoteObject.injectedScriptID` to the owning protocol target.
2. Return a `DOM.requestNode` command intent for that target.
3. Accept the result only if the selection request, target, and document generation still match.
4. On failure or stale result, update selection failure state only. Do not mutate the DOM tree.

## WebKit Order

V2 projection uses the WebKit DOM tree order:

```text
templateContent -> ::before -> effective children -> ::after
```

For frame owner nodes, effective children prefer the projected frame document. Regular children are not used to store the projected document.

## Intentional Differences

- V2 does not use URL matching as document or node identity. URL matching is
  allowed only as WebKit-compatible iframe owner discovery when there is a
  single exact/resolved match and no explicit child-frame identity is
  available.
- V2 does not use `backendNodeId`, URL strings, or target name prefixes as DOM identity.
- V2 does not refresh the parent page document as recovery for frame document updates.
- V2 keeps UIKit/TextKit2 out of the core model. UI rows are projection output, not source-of-truth model objects.

## Debugging Implications for Cross-Origin Iframes

When a cross-origin iframe disappears from the DOM tree view, investigate in
this order:

1. Target lifecycle: confirm the frame target survived provisional commit and
   the model now points at the committed target id.
2. Frame document ownership: confirm `DOM.getDocument` result for the frame
   target is stored as a frame-owned document, not as a page document
   replacement.
3. Splice state: confirm the frame document is either projected under the iframe
   owner or kept pending until the owner node is hydrated.
4. Page document updates: confirm page-target `DOM.documentUpdated` does not
   synchronously replace an existing expanded page tree with a shallow
   `DOM.getDocument` result.
5. Selection hydration: if `DOM.requestNode` emits `setChildNodes` for missing
   parents, inspect the target/document chain first. Do not use missing-parent
   logs as a reason to reload the page document.

The core invariant is: a frame document is target-scoped state. Page DOM events
may reveal or remove the iframe owner, but they do not own the frame target
document.

## Source References

- `Web Inspector and Site Isolation`
- `Source/WebInspectorUI/UserInterface/Controllers/DOMManager.js`
- `Source/WebInspectorUI/UserInterface/Models/DOMNode.js`
- `Source/WebInspectorUI/UserInterface/Controllers/TargetManager.js`
- `Source/WebInspectorUI/UserInterface/Protocol/Connection.js`
- `Source/WebInspectorUI/UserInterface/Protocol/DOMObserver.js`
- `Source/WebKit/UIProcess/Inspector/WebPageInspectorController.cpp`
- `Source/WebKit/UIProcess/Inspector/FrameInspectorTargetProxy.cpp`
- `Source/WebCore/inspector/agents/InspectorDOMAgent.cpp`
- `Source/WebCore/inspector/agents/frame/FrameDOMAgent.cpp`
- `Source/JavaScriptCore/inspector/protocol/DOM.json`
