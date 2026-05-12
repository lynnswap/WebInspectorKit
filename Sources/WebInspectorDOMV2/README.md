# WebInspectorDOMV2

`WebInspectorDOMV2` is an experimental, package-internal DOM transport/model target. It is intentionally not connected to the existing runtime or UI yet.

The target exists to validate a cleaner DOM architecture before replacing the current DOM inspector pipeline.

## Goals

- Model WebKit DOM protocol concepts directly.
- Keep page, frame, document, protocol target, execution context, and DOM node identities explicit.
- Treat iframe documents as frame-document projections, not regular DOM children.
- Make iframe refresh and cross-origin selection behavior testable without UIKit/TextKit2.
- Avoid legacy compatibility paths from the old WebView-rendered DOM tree.

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

Mutable model classes are `@MainActor @Observable` so the future native UI can observe the same semantic source of truth directly. Expensive work must stay outside this model boundary:

- raw transport I/O
- JSON parsing
- protocol payload decoding
- search/tokenization/markup generation

The model should only apply already-decoded semantic events and produce Sendable snapshots/command intents.

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

## Tests

Run the headless V2 tests with:

```sh
swift test --filter WebInspectorDOMV2Tests
```