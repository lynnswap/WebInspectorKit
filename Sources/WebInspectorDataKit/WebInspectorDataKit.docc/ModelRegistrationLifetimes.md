# Model Registration Lifetimes

Retain the last reported model state independently from the context registration
that permits operations.

## Model Objects and Current Registration

DataKit model objects preserve identity and their last reported properties for as
long as your code retains them. Their operational registration is shorter: a DOM
document update, Runtime context destruction, or release of the originating
``WebInspectorContext`` can end it.

The context's current model registration is authoritative. DataKit never replaces
a stale object with a different object that happens to have the same ID. An ID
passed to a domain controller addresses the model currently registered in that
controller's context; it is not a generation-spanning model handle.

Operations use these stale semantics:

- Throwing operations report `WebInspectorProxyError.disconnected` without
  sending a protocol command.
- Nonthrowing selection operations ignore a stale or foreign non-`nil` model and
  preserve the current selection. Passing `nil` still clears the selection.
- ``DOMNode/requestChildren(depth:isolation:)`` ignores a stale node. It never
  redirects the request to a same-ID node from a later document.
- The actor-owner requirement on ``WebInspectorContext`` remains independent of
  registration lifetime. Call a context only from its owning actor.

Resolve current models from the context or a current tree snapshot immediately
before an operation:

```swift
if let nodeID = tree.snapshot.selectedNodeID,
   let node = context.node(for: nodeID) {
    try await node.highlight()
}
```

## Fetched Results After Context Release

``WebInspectorFetchedResults`` and ``WebInspectorFetchedResultsController`` do
not retain their originating context. When that context is released:

- their active transaction streams finish;
- transaction streams created later are already finished;
- their final query, items, sections, and controller snapshot remain
  readable;
- changing the query throws `WebInspectorProxyError.disconnected`.

Detaching, restarting, or failing an inspection context does not itself
invalidate fetched results while the context object remains alive.

## Updating Queries

Query updates report stale registration, so call them with `try`:

```swift
try results.updateQuery(
    NetworkRequestQuery(fetchLimit: 100)
)

try controller.updateQuery(
    NetworkRequestQuery(fetchOffset: 100)
)
```
