# DOM Model Research

This note records the WebKit DOM model behavior that `V2_WebInspectorCore` is intentionally matching.

## WebKit Shape

- `DOMManager` owns the frontend node index and current document state.
- `DOMNode` instances are created from WebKit DOM protocol payloads and are indexed by protocol node identity.
- Frame targets are handled separately from the page document. A frame target document is fetched from that target and then spliced into the matching iframe as `contentDocument`.
- If the iframe owner is not yet available, WebKit keeps the frame document unspliced and retries when more page nodes are loaded.

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

## Source References

- `Source/WebInspectorUI/UserInterface/Controllers/DOMManager.js`
- `Source/WebInspectorUI/UserInterface/Models/DOMNode.js`
- `Source/JavaScriptCore/inspector/protocol/DOM.json`
