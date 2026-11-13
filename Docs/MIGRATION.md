# Migration Guide

This guide covers the source changes since v0.9.7. For earlier releases, read
the guide at the
[v0.9.7 tag](https://github.com/lynnswap/WebInspectorKit/blob/v0.9.7/Docs/MIGRATION.md).

## The built-in UI

`WebInspectorViewController` presents a `WebInspector`. `WebInspectorSession`
and `WebInspectorSession.prepare()` are removed.

```swift
// Before
try await WebInspectorSession.prepare()
let session = WebInspectorSession(tabs: [.dom, .network, customTab])
let controller = WebInspectorViewController(session: session)
try await controller.attach(to: webView)

// After
let controller = WebInspectorViewController(tabs: [.dom, .network, customTab])
controller.inspector.attach(to: webView)
```

- Remove the `prepare()` call. The view controller warms up the observation,
  hosted menu, and syntax preview runtimes itself, and works before that
  finishes.
- `controller.attach(to:)` and `controller.detach()` become
  `controller.inspector.attach(to:)` and `controller.inspector.detach()`. They
  return immediately. Remove code that waits for a detach before attaching to
  another web view; attaching again replaces the current attachment.
- To keep the inspection while the UI is off screen, keep the `WebInspector`
  where you kept the session, pass it to
  `WebInspectorViewController(inspector:tabs:)`, and set
  `automaticallyDetachesOnDismiss` to `false` as before. The tabs and the
  selected tab stay with the inspector, and `tabs: nil` keeps them.
- A custom tab's factory receives the `WebInspector` instead of the session, so
  the tab can read `inspector.dom`, `inspector.network`, and the other domains.
- `session.pageUserInterfaceStyle` becomes `inspector.pageUserInterfaceStyle`.
- `import WebInspectorKit` also provides `WebInspector` and its models.

## The model layer

### `WebInspector` replaces the container and the context

`WebInspectorContainer` and `WebInspectorContext` are no longer public. Create
a `WebInspector` and keep it for as long as you inspect. It owns the connection
and replaces its models when the attachment changes.

```swift
// Before
let container = try await WebInspectorContainer(attachingTo: webView)
let context = container.mainContext
// ...
await container.close()

// After
let inspector = WebInspector()
inspector.attach(to: webView)
// ...
inspector.detach()
```

- `attach(to:)` and `detach()` return immediately. Read `inspector.state` for
  the progress and for an attachment failure. After `detach()` the state is
  `detaching` until the connection is closed, and then `detached`.
- Calling `attach(to:)` with another web view replaces the current
  attachment. Calling it with the web view that is already inspected does
  nothing, and `inspector.inspectedWebView` names that web view. Releasing the
  inspector ends the attachment.
- `inspector.dom`, `css`, `network`, `console`, `runtime`, and `page` replace
  the same properties of the context. They stay valid across attachments.
- The domain types are renamed: `DOMModelController` to `DOMInspector`,
  `CSSModelController` to `CSSInspector`, `NetworkModelController` to
  `NetworkInspector`, `ConsoleModelController` to `ConsoleInspector`,
  `RuntimeModelController` to `RuntimeInspector`, and `PageModelController` to
  `PageInspector`.
- `context.state` becomes `inspector.state`, whose `failed` case carries the
  error of a failed attachment. `context.teardownError` has no replacement: the
  inspector closes the connection when an attachment ends and logs a domain
  that could not be disabled first.
- `WebInspectorPersistentModel` is renamed to `WebInspectorModel`.
- The inspector and its models are bound to the main actor. Methods no longer
  take an `isolation:` parameter. Model identities (`id`) stay readable from
  any isolation.

### State and operations live on the domain objects

The context no longer repeats the state and operations of its domains.
`DOMNode`, `NetworkRequest`, and `RuntimeObject` no longer start commands
themselves, and DOM operations take the `DOMNode` instead of its ID.

| Before | After |
| --- | --- |
| `context.rootNode`, `context.selectedNode`, `context.isElementPickerEnabled` | `inspector.dom.rootNode`, `inspector.dom.selectedNode`, `inspector.dom.isElementPickerEnabled` |
| `context.node(for: id)` | `inspector.dom.node(for: id)` |
| `context.select(node)`, `context.dom.select(id)` | `inspector.dom.select(node)` |
| `node.requestChildren()`, `context.dom.requestChildren(of: id)` | `inspector.dom.requestChildren(of: node)` |
| `node.highlight()`, `context.highlight(node)`, `context.dom.highlight(id)` | `inspector.dom.highlight(node)` |
| `node.copyText(kind)`, `context.copyText(kind, for: node)` | `inspector.dom.copyText(kind, of: node)` |
| `node.delete()`, `context.delete(nodes)`, `context.dom.remove(ids)` | `inspector.dom.remove(nodes)`, which returns the removed nodes |
| `context.dom.setAttribute(_:value:on: id)`, `context.dom.setOuterHTML(_:of: id)` | The same methods with the node |
| `context.selectorPath(for:)`, `context.xPath(for:)`, `context.hideHighlight()` | The same methods on `inspector.dom` |
| `context.setElementPickerEnabled(_:)`, `context.dom.setInspectMode(enabled:)` | `inspector.dom.setElementPickerEnabled(_:)` |
| `context.treeController()` | `inspector.dom.treeController()` |
| `context.treeController(root: node)` | Removed. A tree controller follows the document of the inspected page. |
| `context.editHistory.undo()`, `context.editHistory.redo()` | `inspector.dom.undo()`, `inspector.dom.redo()` |
| `context.css.styles(for: id)`, `context.css.refreshStyles(for: id)` | The same methods on `inspector.css`, with the node |
| `context.setStyleHydrationActive(_:)`, `context.requestSetCSSProperty(_:enabled:options:)` | `inspector.css.setStyleHydrationActive(_:)`, `inspector.css.requestSetProperty(_:enabled:)` |
| `options: WebInspectorMutationOptions(undo: .disabled)` | `registersUndo: false` |
| `context.registeredRequest(for: id)` | `inspector.network.request(for: id)` |
| `context.clearNetworkRequests()` | `inspector.network.clearRequests()` |
| `context.networkResourceTreeError` | `inspector.network.resourceTreeError` |
| `request.fetchResponseBody()` | `inspector.network.fetchResponseBody(for: request)` |
| `context.registeredMessage(for: id)` | `inspector.console.message(for: id)` |
| `context.executionContexts`, `context.selectedContext` | `inspector.runtime.executionContexts`, `inspector.runtime.selectedContext` |
| `context.selectContext(runtimeContext)` | `inspector.runtime.select(runtimeContext)` |
| `context.evaluate(expression)` | `inspector.runtime.evaluate(expression)` |
| `object.properties()`, `object.collectionEntries()` | `inspector.runtime.properties(of: object)`, `inspector.runtime.collectionEntries(of: object)` |
| `context.reloadPage()` | `inspector.page.reload()` |

`WebInspectorMutationOptions`, `WebInspectorUndoPolicy`,
`WebInspectorStaleModelPolicy`, `DOMMutationResult`, and
`WebInspectorEditHistory` are removed.

The element picker applies the latest requested state. Cancelling the calling
task after the request is recorded no longer restores the earlier state. To
undo a request, call `setElementPickerEnabled(_:)` again with the state you
want.

### Queries and fetched results become ordered collections

`NetworkRequestQuery`, `ConsoleMessageQuery`, `WebInspectorFetchedResults`,
`WebInspectorFetchedResultsController`, and their snapshot, section, and
transaction types are removed. DataKit no longer filters, sorts, sections, or
windows requests and messages; that belongs to the code that presents them.

| Before | After |
| --- | --- |
| `context.network.fetchedResults().items` | `inspector.network.requests` |
| `context.console.fetchedResults().items` | `inspector.console.messages` |
| `fetchedResultsController().transactions` | `inspector.network.requestChanges` or `inspector.console.messageChanges` |
| A filter, sort, section, limit, or offset on a query | Apply it to the collection in your own model |

Both collections are in arrival order and observable. A change stream reports
the `inserted`, `updated`, and `removed` model objects and `removedAll`. Copy
the collection when you subscribe and apply every change in order:

```swift
let changes = inspector.network.requestChanges
var rows = inspector.network.requests
for await change in changes {
    switch change {
    case .removedAll:
        rows.removeAll()
    case let .inserted(requests):
        rows.append(contentsOf: requests)
    case let .removed(requests):
        rows.removeAll { requests.contains($0) }
    case let .updated(requests):
        reconfigure(requests)
    }
}
```

A change carries the objects themselves because a request identifier can be
admitted again after a clear; the earlier change still names the earlier
object. The streams continue across attachments: a new attachment is reported
as `removedAll`, followed by the insertion of what it starts with.

### Models end with their attachment

Retained models keep their identity and their last reported properties, but
operations need the object that is currently registered. A DOM document
update, the destruction of a Runtime context, or the end of the attachment ends
a registration, and a later object with the same protocol ID does not take the
place of a stale one.

Resolve a current model immediately before an operation:

```swift
let tree = inspector.dom.treeController()
if let nodeID = tree.snapshot.selectedNodeID,
   let node = inspector.dom.node(for: nodeID) {
    try await inspector.dom.highlight(node)
}
```

Throwing operations on stale or foreign models report
`WebInspectorProxyError.disconnected` without sending a protocol command.
Selection, child requests, and response body fetches ignore them.

## Testing

`WebInspectorContext.startAndWaitForStartupForTesting()` becomes
`inspector.attachForTesting(to: proxy)`, which attaches through the proxy of a
`WebInspectorProxyTestRuntime` and waits for startup. `inspector.detachForTesting()`
waits until the attachment has ended.

`WebInspectorDataKitTestingError.statusUpdatesEndedBeforeStartupCompleted` is
removed. Startup is observed on the inspector's state, which has no stream that
can end.
