# DOM Model Research

This note records the WebKit DOM model behavior that `V2_WebInspectorCore` is intentionally matching.

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
- iframe documents are not stored as regular DOM children. Projection renders `DOMFrame.currentDocumentID` under the iframe owner node.
- Frame document refresh updates only that frame's current document generation and does not mutate the parent page document.
- Selection stores node identifiers and request generation, not stale node object references.

## Model Shape

```text
DOMSession
  └─ DOMPage
      └─ DOMFrame tree
          └─ DOMDocument
              └─ #document DOMNode
                  └─ iframe DOMNode
                      └─ projected DOMFrame.currentDocument
```

## Identity Rules

- `ProtocolTarget.ID`: WebKit target identifier.
- `DOMFrame.ID`: WebKit frame identifier.
- `DOMDocument.ID`: `targetID + documentGeneration`.
- `DOMNode.ID`: `documentID + nodeID`.
- `DOMNodeCurrentKey`: `targetID + nodeID` for resolving the current node mirror within one target.

`backendNodeId`, URL strings, and `page-*` naming are not DOM identity.

## Frame Documents

Frame documents are owned by `DOMFrame.currentDocumentID`.

An iframe node may point to a frame with `frameID`, and projection renders that frame's current document under the iframe row. The projected document is not stored as an iframe regular child.

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

- V2 does not use URL matching as identity. Frame ownership should come from frame/target metadata.
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
