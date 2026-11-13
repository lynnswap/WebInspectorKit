# Migration Guide

This standalone guide records source changes that are likely to affect app code
when upgrading WebInspectorKit. Sections are grouped by release, newest first.

## Unreleased

### Prepare the UIKit runtimes before creating inspector views

Await the shared observation, hosted menu, and syntax preview runtimes during
asynchronous app setup:

```swift
try await WebInspectorSession.prepare()
```

Handle preparation errors before constructing the inspector UI. Repeated calls
reuse the dependencies' preparation across the process. The inspector's
initializers remain synchronous after preparation. DataKit, ProxyKit, and
WebKitRuntime consumers that do not use the built-in UIKit UI do not need this
UI preparation step.

### State and operations live on the domain objects

`WebInspectorContext` no longer repeats the state and operations of
`context.dom`, `context.css`, `context.network`, `context.console`,
`context.runtime`, and `context.page`. `DOMNode`, `NetworkRequest`, and
`RuntimeObject` no longer start commands themselves, and DOM operations take
the `DOMNode` instead of its ID.

| Before | After |
| --- | --- |
| `context.registeredRequest(for: id)` | `context.network.request(for: id)` |
| `context.clearNetworkRequests()` | `context.network.clearRequests()` |
| `context.networkResourceTreeError` | `context.network.resourceTreeError` |
| `request.fetchResponseBody()` | `context.network.fetchResponseBody(for: request)` |
| `context.registeredMessage(for: id)` | `context.console.message(for: id)` |
| `context.executionContexts`, `context.selectedContext` | `context.runtime.executionContexts`, `context.runtime.selectedContext` |
| `context.selectContext(runtimeContext)` | `context.runtime.select(runtimeContext)` |
| `context.evaluate(expression)` | `context.runtime.evaluate(expression)` |
| `object.properties()`, `object.collectionEntries()` | `context.runtime.properties(of: object)`, `context.runtime.collectionEntries(of: object)` |
| `context.reloadPage()` | `context.page.reload()` |
| `context.rootNode`, `context.selectedNode`, `context.isElementPickerEnabled` | `context.dom.rootNode`, `context.dom.selectedNode`, `context.dom.isElementPickerEnabled` |
| `context.node(for: id)` | `context.dom.node(for: id)` |
| `context.select(node)`, `context.dom.select(id)` | `context.dom.select(node)` |
| `node.requestChildren()`, `context.dom.requestChildren(of: id)` | `context.dom.requestChildren(of: node)` |
| `node.highlight()`, `context.highlight(node)`, `context.dom.highlight(id)` | `context.dom.highlight(node)` |
| `node.copyText(kind)`, `context.copyText(kind, for: node)` | `context.dom.copyText(kind, of: node)` |
| `node.delete()`, `context.delete(nodes)`, `context.dom.remove(ids)` | `context.dom.remove(nodes)`, which returns the removed nodes |
| `context.dom.setAttribute(_:value:on: id)`, `context.dom.setOuterHTML(_:of: id)` | The same methods with the node |
| `context.selectorPath(for:)`, `context.xPath(for:)`, `context.hideHighlight()` | The same methods on `context.dom` |
| `context.setElementPickerEnabled(_:)`, `context.dom.setInspectMode(enabled:)` | `context.dom.setElementPickerEnabled(_:)` |
| `context.treeController()`, `context.treeController(root:)` | `context.dom.treeController()`, `context.dom.treeController(root:)` |
| `context.editHistory.undo()`, `context.editHistory.redo()` | `context.dom.undo()`, `context.dom.redo()` |
| `context.css.styles(for: id)`, `context.css.refreshStyles(for: id)` | The same methods with the node |
| `context.setStyleHydrationActive(_:)`, `context.requestSetCSSProperty(_:enabled:options:)` | `context.css.setStyleHydrationActive(_:)`, `context.css.requestSetProperty(_:enabled:)` |
| `options: WebInspectorMutationOptions(undo: .disabled)` | `registersUndo: false` |

`WebInspectorMutationOptions`, `WebInspectorUndoPolicy`,
`WebInspectorStaleModelPolicy`, `DOMMutationResult`, and
`WebInspectorEditHistory` are removed.

### Queries and fetched results become ordered collections

`NetworkRequestQuery`, `ConsoleMessageQuery`, `WebInspectorFetchedResults`,
`WebInspectorFetchedResultsController`, and their snapshot, section, and
transaction types are removed. DataKit no longer filters, sorts, sections, or
windows requests and messages; that belongs to the code that presents them.

| Before | After |
| --- | --- |
| `context.network.fetchedResults().items` | `context.network.requests` |
| `context.console.fetchedResults().items` | `context.console.messages` |
| `fetchedResultsController().transactions` | `context.network.requestChanges` or `context.console.messageChanges` |
| A filter, sort, section, limit, or offset on a query | Apply it to the collection in your own model |

Both collections are in arrival order and observable. A change stream reports
the `inserted`, `updated`, and `removed` model objects and `removedAll`. Copy
the collection when you subscribe and apply every change in order:

```swift
let changes = context.network.requestChanges
var rows = context.network.requests
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
object.

The v0.5.0 notes below describe the query API this replaces.

### WebInspectorDataKit is main-actor isolated

`WebInspectorContext`, the domain controllers, and the model classes (`DOMNode`, `NetworkRequest`, `NetworkBody`,
`WebSocketState`, `ConsoleMessage`, `RuntimeContext`, `RuntimeObject`,
`CSSStyles`) are now `@MainActor`. Their methods no longer take an
`isolation:` parameter, and a call from another actor is a compile-time error
where it used to trap at run time.

Remove `isolation:` arguments, and create contexts with
`WebInspectorContext(container)` or `container.mainContext`. Code that kept a
context on its own actor must hop to the main actor to use it. Model
identities (`id`) stay readable from any isolation.

### Element picker requests ignore caller cancellation

`WebInspectorContext.setElementPickerEnabled(_:)` and
`WebInspectorDOMController.setInspectMode(enabled:)` apply the latest requested
state. Cancelling the calling task after the request is recorded no longer
restores the earlier state or sends a compensating command, and the call
returns normally once the picker matches the latest request. To undo a
request, call the method again with the state you want.

### UIKit declarations move into WebInspectorKit

Continue importing `WebInspectorKit` and using `WebInspectorSession`,
`WebInspectorViewController`, and `WebInspectorTab` as before. These types are
now declared in the `WebInspectorKit` module; the `WebInspectorUI` module and
its re-export have been removed.

Replace direct `import WebInspectorUI` statements with `import WebInspectorKit`.
Change module-qualified names such as
`WebInspectorUI.WebInspectorViewController` to
`WebInspectorKit.WebInspectorViewController`. Rebuild all clients: moving the
declaration module changes Swift symbol identities and is not binary-compatible
with already-compiled clients.

DocC now documents the UIKit API under `documentation/webinspectorkit/`.
Update links that pointed into `documentation/webinspectorui/` accordingly.

### Emit test events with a target handle

`WebInspectorTestBackend.emit(_:target:)` now requires a `WebInspectorTarget`.
Replace `target: target.id` with `target: target` for Network, DOM, CSS, Console,
and Runtime events:

```swift
let runtime = try await WebInspectorProxyTestRuntime.start()
let target = try await runtime.proxy.waitForCurrentPage()
var events = target.dom.events.makeAsyncIterator()
try await runtime.backend.waitForSubscribers(domain: "DOM", target: target, count: 1)
await runtime.backend.emit(.documentUpdated, target: target)
let event = await events.next()
await runtime.proxy.close()
```

Keep the target handle for the route being exercised. A target ID alone cannot
distinguish routes that share an identity. Emitting before a subscription is
registered or after it is cancelled is valid; an event with no recipient is
not replayed later. Wait for subscribers explicitly when asserting delivery.

## v0.5.0

These notes apply when upgrading from `v0.4.1` to `v0.5.0`.

### 1. Replace generic fetched-results construction

DataKit now exposes closed query values for Network and Console fetched results.
Replace the removed generic fetch surface with the corresponding domain query
API:

| `v0.4.1` | `v0.5.0` |
| --- | --- |
| `WebInspectorFetchDescriptor<NetworkRequest>` | `NetworkRequestQuery` |
| `WebInspectorFetchDescriptor<ConsoleMessage>` | `ConsoleMessageQuery` |
| Foundation `Predicate` | A model-specific `Filter` value |
| Foundation `SortDescriptor` | A model-specific `Sort` value |
| `WebInspectorSectionDescriptor` or a `sectionBy` key path | A model-specific `Section` value |
| `context.fetchedResults(...)` | `context.network.fetchedResults(...)` or `context.console.fetchedResults(...)` |
| `context.fetchedResultsController(...)` | `context.network.fetchedResultsController(...)` or `context.console.fetchedResultsController(...)` |
| `WebInspectorFetchRequest` | Copy, change, and resubmit a query value |
| `results.fetchDescriptor` or `controller.fetchDescriptor` | `results.query` or `controller.query` |
| `results.sectionBy` | `results.query.sectionBy` |
| `updateFetchDescriptor` | `try updateQuery` |

For example, construct Network results with one query that owns filtering,
ordering, sectioning, and the visible window:

```swift
let query = NetworkRequestQuery(
    filter: .method(equals: "POST"),
    sortBy: [.requestSentTimestamp(order: .reverse)],
    sectionBy: .method,
    fetchLimit: 100
)
let requests = context.network.fetchedResults(for: query)
```

Use `ConsoleMessageQuery` with `context.console` for Console messages. Only
`NetworkRequest` and `ConsoleMessage` can be queried from a context.
If a consumer-defined model used the removed `WebInspectorFetchableModel` for
generic snapshots or transactions, conform it to `WebInspectorPersistentModel`
instead. Custom models cannot be fetched from a context.

### 2. Update live queries with a throwing operation

`WebInspectorFetchedResults` and `WebInspectorFetchedResultsController` now
expose their current `query`. Copy it, apply all semantic changes, and submit it
as one update:

```swift
var query = requests.query
query.fetchLimit = 200
query.fetchOffset = 100
try requests.updateQuery(query)
```

`fetchLimit` changes from `Int?` to `UInt?`, and `fetchOffset` changes from
`Int` to `UInt`. Values larger than the current collection safely describe the
remaining prefix or an empty result. `updateQuery` throws
`WebInspectorProxyError.disconnected` after the results are no longer registered
in their originating context.

Fetched results do not retain that context. When the context is released, active
and future transaction streams finish while the last query, items, sections,
and controller snapshot remain readable. Keep the context alive for as long as
the results must accept query updates. Detaching, restarting, or failing an
inspection does not invalidate the results while that context remains alive.

### 3. Re-resolve models after their registration changes

Retained DataKit models preserve identity and their last reported properties,
but operations require the exact object to remain registered in its originating
context. A DOM document update, Runtime context destruction, or release of the
context can end that registration. DataKit does not redirect a stale model to a
new object that happens to reuse the same protocol ID.

Resolve a current model from its context or a current tree snapshot immediately
before performing an operation:

```swift
let tree = context.dom.treeController()
if let nodeID = tree.snapshot.selectedNodeID,
   let node = context.node(for: nodeID) {
    try await node.highlight()
}
```

Throwing operations on stale or foreign models report
`WebInspectorProxyError.disconnected` without sending a protocol command.
Nonthrowing selection operations ignore a stale or foreign non-`nil` model and
preserve the current selection; passing `nil` still clears it.
`DOMNode.requestChildren` also ignores a stale node.

See [Model Registration Lifetimes](../Sources/WebInspectorDataKit/WebInspectorDataKit.docc/ModelRegistrationLifetimes.md)
for the complete model lifetime contract.

## v0.4.0

These notes apply when upgrading from `v0.3.0` to `v0.4.0`.

### 1. Update Network event patterns for request initiators

`Network.Event.requestWillBeSent` and
`Network.Event.requestServedFromMemoryCache` now include a
`Network.Initiator` associated value. The initiator exposes WebKit's kind and
source location together with an optional, target-scoped `DOM.Node.ID`:

```swift
case let .requestWillBeSent(_, request, initiator, _, _, _):
    if let nodeID = initiator.nodeID {
        associate(request, with: nodeID)
    }
```

WebKit can omit the node association. In particular, an unbound protocol
`nodeId` of zero is normalized to `nil` rather than exposed as a usable DOM
identity.

### 2. Choose whether proxy operations need finite timeouts

`WebInspectorProxy.Configuration.responseTimeout` and `bootstrapTimeout` are
now optional. Their default changed from five seconds to `nil`.

With the default configuration, a proxy operation now waits until WebKit
replies or publishes a target, the connection closes, or the calling task is
cancelled. If your app owns a finite deadline, pass it explicitly:

```swift
let proxy = try await WebInspectorProxy(
    attachingTo: webView,
    configuration: .init(
        responseTimeout: .seconds(5),
        bootstrapTimeout: .seconds(5)
    )
)
```

## v0.2.0

These notes apply when upgrading from `v0.1.5` or earlier to `v0.2.0`.

Fine-grained internal model types, transport rewrites, module splits, and cache changes are intentionally omitted unless they change how an app integrates the inspector.

### 1. Update the toolchain and UI expectation

- Swift 6.3+ is now required.
- The app-facing inspector UI is UIKit-based on iOS.
- The old SwiftUI `WebInspectorView` and AppKit inspector UI are no longer shipped.

macOS runtime and native bridge targets remain in the package where they do not
depend on the removed AppKit UI, but there is no current app-facing AppKit
inspector view.

### 2. Replace the old inspector entry point

`WebInspectorView` and `WebInspectorModel` were removed.

Use `WebInspectorViewController` or `WebInspectorSession`.

```swift
@objc private func presentInspector() {
    let inspector = WebInspectorViewController()
    Task { @MainActor in
        try await inspector.attach(to: pageWebView)
        present(inspector, animated: true)
    }
}
```

If your app used the default inspector UI, this is the main migration.

If your app presents the inspector from SwiftUI, host `WebInspectorViewController`
with your own `UIViewControllerRepresentable`.

### 3. Update lifecycle calls

| `v0.1.5` | `v0.2.0` |
| --- | --- |
| `WebInspectorModel` | `WebInspectorViewController` for the default UI, or `WebInspectorSession` for lifecycle ownership |
| `WebInspectorConfiguration` | no current app-facing replacement |
| `attach(webView:)` | `attach(to:)` |
| `suspend()` | no app-facing replacement |
| synchronous `detach()` | async `detach()` |

Current:

```swift
let inspector = WebInspectorViewController()

Task { @MainActor in
    try await inspector.attach(to: webView)
}
```

When you need to tear down the attachment explicitly:

```swift
Task { @MainActor in
    await inspector.detach()
}
```

Snapshot depth, subtree depth, and DOM auto-update debounce are no longer public
configuration. Remove app-side tuning for those values; the native DOM runtime
owns those policies.

### 4. Replace custom tab builders

The `v0.1.5` SwiftUI tab builder API was removed.

| `v0.1.5` | `v0.2.0` |
| --- | --- |
| `WITab.dom()` | `.dom` |
| `WITab.element()` | included inside the DOM UI |
| `WITab.network()` | `.network` |
| custom `WITab(...)` content | `WebInspectorTab(id:title:image:makeViewController:)` or `WebInspectorTab(id:title:systemImage:makeViewController:)` |

Use the built-in tabs exposed by `WebInspectorViewController`:

```swift
let controller = WebInspectorViewController(
    tabs: [.dom, .network]
)
```

Custom tabs now use UIKit view controllers:

```swift
let consoleTab = WebInspectorTab(
    id: "app_console",
    title: "Console",
    systemImage: "terminal"
) { session in
    ConsoleViewController(inspectorSession: session)
}

let controller = WebInspectorViewController(
    tabs: [.dom, .network, consoleTab]
)
```

### 5. Remove old DOM and Network model usage

The old SwiftUI views, view models, sessions, stores, and page-agent APIs are no
longer app-facing integration points.

Do not migrate app code from one removed DOM or Network model API to another
internal model API. DOM and Network command/model surfaces should be treated as
internal until an app-facing API is explicitly published.

### 6. Remove JavaScript-agent assumptions

`v0.1.5` inspected pages by injecting bundled JavaScript agents into the target
`WKWebView`. `v0.2.0` uses WebKit's native inspector runtime instead.

For app integration, this means:

- You no longer need to enable page JavaScript just for WebInspectorKit.
- You can remove workarounds that existed only for injected inspector scripts,
  such as script-injection ordering or content-script/CSP assumptions.
- Page JavaScript being disabled still affects the page's own behavior, but it is
  not a WebInspectorKit setup requirement.
