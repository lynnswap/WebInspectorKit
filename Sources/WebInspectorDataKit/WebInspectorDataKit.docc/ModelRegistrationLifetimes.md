# Model Registration Lifetimes

Retain the last reported model state independently from the registration that
permits operations.

## Model Objects and Current Registration

DataKit model objects preserve identity and their last reported properties for as
long as your code retains them. Their operational registration is shorter: a DOM
document update, Runtime context destruction, or the end of the attachment that
produced them can end it. Attaching a ``WebInspector`` again starts with new
models, even for the same web view.

The inspector's current registration is authoritative. DataKit never replaces a
stale object with a different object that happens to have the same ID.
Operations take the model object for that reason. An ID, such as one read from a
``DOMTreeSnapshot``, resolves to the model currently registered; it is not a
generation-spanning model handle.

Operations use these stale semantics:

- Throwing operations report `WebInspectorProxyError.disconnected` without
  sending a protocol command.
- Nonthrowing selection operations ignore a stale or foreign non-`nil` model and
  preserve the current selection. Passing `nil` still clears the selection.
- ``DOMInspector/requestChildren(of:depth:)`` ignores a stale node. It
  never redirects the request to a same-ID node from a later document.
- ``NetworkInspector/fetchResponseBody(for:)`` ignores a stale or
  foreign request and leaves its response body as it is.

Resolve current models from the inspector or a current tree snapshot immediately
before an operation:

```swift
if let nodeID = tree.snapshot.selectedNodeID,
   let node = inspector.dom.node(for: nodeID) {
    try await inspector.dom.highlight(node)
}
```

A ``DOMTreeController`` follows the inspector across attachments: it publishes
a `reset` snapshot when the attachment changes and then shows the new page's
document.

## Collection Changes Across Attachments

The change streams from ``NetworkInspector/requestChanges`` and
``ConsoleInspector/messageChanges`` continue across attachments. Detaching,
attaching again, or clearing publishes `removedAll`, and a new attachment then
publishes the models it starts with as `inserted`.

The streams do not retain the inspector. They finish when the inspector and its
domain objects are released.
