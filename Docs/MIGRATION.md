# Migration Guide

This standalone guide records source changes that are likely to affect app code
when upgrading WebInspectorKit. Sections are grouped by release, newest first.

## Unreleased

Unreleased builds require Swift 6.3+ and a minimum deployment target of iOS
18.4+ or macOS 15.4+. The built-in UIKit inspector remains iOS-only.

### Adopt container-issued contexts and flat generic fetches

`WebInspectorModelContext` no longer attaches to WebKit or owns DOM, Network,
Console, or Runtime commands. Create a `WebInspectorModelContainer`, attach the
container, and obtain `mainContext` or a macro-backed model-actor binding from
that container.

Specialized query types and sectioned fetched results were removed. Create a
one-generic `WebInspectorFetchedResultsController`, call `performFetch()`, and
observe its flat snapshot or update sequence:

```swift
let container = WebInspectorModelContainer()
try await container.attach(to: webView)
let context = container.mainContext
let entries = WebInspectorFetchedResultsController<NetworkEntry>(
    modelContext: context
)
try await entries.performFetch()
```

Transient feature-local retry and unavailable state were removed.
`WebInspectorFeatureHandle` exposes availability observation only; DOM,
Network, Console, and Runtime have no `retry()` API. A required Web Inspector
method rejected with JSON-RPC `-32601` publishes
`WebInspectorFeatureState.unsupported` for only that feature. Dependent tabs
show a non-retryable failure while sibling tabs remain usable. Any other
bootstrap, protocol, route, or store failure fails the attachment through
`WebInspectorConnectionFailure`. After fixing or replacing the underlying
connection, explicitly attach again to start new feature runners.

Network redirects and exact initiator groups are now represented by one flat
`NetworkEntry`. Its ordered `requestIDs` contain every request in the logical
row. Filtering, sorting, offset, and limit use
`WebInspectorFetchDescriptor<Model>` over immutable `Model.QueryValue` values.

Commands move from context and persistent models to the feature facade:

| Before | After |
| --- | --- |
| `context.highlightDOMNode(node)` | `container.dom.highlight(node.id)` |
| `context.clearNetworkRequests()` | `container.network.clear()` |
| `body.load()` | `container.network.responseBody(for: request.id)` |
| `context.withRuntimeObjectGroup(...)` | `container.runtime.makeObjectScope()` plus explicit `scope.close()` |

SwiftUI consumers add the `WebInspectorSwiftUI` product, install the container
with `.webInspectorModelContainer(container)`, and use
`@WebInspectorQuery`. The wrapper preserves its last successful result after a
later fetch failure; read `fetchError` from its backing storage rather than a
custom loading/ready/failure projection.

### Read Network request initiators from request events

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

### Make custom tab factories asynchronous

`WebInspectorTab` factories are `async throws` and declare the semantic
features they require. The root inspector joins concurrent requests for the same
tab, presents native loading and factory failure states, supports retry for a
factory's own failure, and cancels and awaits unfinished factories during root
teardown. A built-in feature failure closes every presentation resource because
it fails the attachment:

```swift
let consoleTab = WebInspectorTab(
    id: .init(rawValue: "console"),
    title: "Console",
    requiredFeatures: [.consoleRuntime]
) { context in
    ConsoleViewController(modelContext: context.modelContext)
}

let catalog = try WebInspectorTabCatalog([.dom, .network, consoleTab])
let inspector = WebInspectorViewController(catalog: catalog)
```

The returned controller remains root-owned and is reused across compact and
regular hosts. Attachment and page-generation changes do not recreate it.
`WebInspectorViewController(session:catalog:)` borrows the supplied session;
the caller remains responsible for detaching or closing it. The convenience
`WebInspectorViewController(catalog:)` owns and closes its session at terminal
presentation retirement.

### Use the logical page and scoped domain events

`WebInspectorProxy.page` is now the only public page handle. Physical
`WebInspectorTarget` values, `currentPage`, `waitForCurrentPage()`, `canReload`,
and the duplicate proxy-level `reload()` were removed. Commands resolve the
current physical WebKit target when they are sent, so a stored page handle
continues across navigation and process replacement.

Separate domain `enable()` / `disable()` calls and cold `events` streams were
also removed. Use `withEvents` to register the subscriber before WebKit domain
activation and to await balanced cleanup:

```swift
let proxy = try await WebInspectorProxy(attachingTo: webView)

try await proxy.page.network.withEvents { events in
    for try await event in events {
        switch event {
        case .reset:
            resetNetworkPresentation()
        case let .event(_, event):
            handleNetworkEvent(event)
        }
    }
}

try await proxy.page.page.reload(ignoringCache: true)
```

### Replace the semantic test backend with the raw peer

`WebInspectorProxyKitTesting` now drives ProxyKit's production connection core
through a raw WebKit peer. `WebInspectorProxyTestRuntime.backend`,
`WebInspectorTestBackend`, and manually constructed `(proxy, backend)` runtimes
were removed. Start the owned runtime, use `runtime.peer`, and explicitly await
`runtime.close()` at the end of every test.

Before:

```swift
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

let runtime = try await WebInspectorProxyTestRuntime.start()
let page = try await runtime.proxy.waitForCurrentPage()

await runtime.backend.enqueue((), for: "Page", method: "reload")
try await page.page.reload()

let commands = await runtime.backend.recordedCommands()
precondition(commands.contains(RecordedCommand(domain: "Page", method: "reload")))
```

After:

```swift
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

let runtime = try await WebInspectorProxyTestRuntime.start()
let reload = Task {
    try await runtime.page.page.reload()
}

let command = try await runtime.peer.commands.next()
precondition(command.destination == .target("page-main"))
precondition(command.method == "Page.reload")
precondition(command.parameters == try WebInspectorTestJSONObject(
    json: #"{"ignoreCache":false}"#
))

try await runtime.peer.reply(to: command)
try await reload.value
await runtime.close()
```

Apply these mappings to other tests:

- Replace `enqueue(result, for:domain:method:)` by starting the operation in a
  task, consuming its raw command from `runtime.peer.commands.next()`, asserting
  `destination`, the full wire `method`, and `parameters`, then calling
  `peer.reply(to:with:)`.
- Replace injected Swift errors with the boundary being tested: use
  `peer.fail(_:message:)` for a protocol error reply,
  `peer.failConnection(with:)` for a fatal transport failure, and
  `peer.closeConnection()` for clean remote EOF. Arbitrary Swift `Error`
  injection is no longer supported.
- Replace `RecordedCommand` and backend histories with a consumer-owned
  `[WebInspectorTestPeer.Command]`. Inspect command fields instead of comparing
  whole commands because each command carries an opaque correlation identity.
  An awaited `reply` or `fail` is the command-completion boundary.
- Give the command FIFO one drain owner. Multiple concurrent `next()` consumers
  race to consume commands and cannot reliably wait for a particular method.
  The owner should record or route commands for other test tasks.
- Replace `hold` and the product `WebInspectorTestGate` by retaining the command
  and delaying its reply with synchronization owned by the test. The testing
  product no longer ships a gate abstraction.
- Replace typed semantic event emission with `emitTargetEvent` or
  `emitRootEvent`, passing raw parameters as
  `WebInspectorTestJSONObject(json:)`, `WebInspectorTestJSONObject(data:)`, or
  `WebInspectorTestJSONObject(encoding:)`. Use `createTarget`,
  `commitProvisionalTarget`, and `destroyTarget` for target lifecycle input.
- `waitForSubscribers` and APIs that inject generations, replay markers, or
  synthetic snapshots have no raw-peer equivalent. Drain until the real
  `<Domain>.enable` command arrives, complete it through the peer, and let the
  production core derive event sequence, generation, replay, and snapshot
  boundaries.

### Use ready DataKit test scenarios for model-level tests

Tests whose subject is a DataKit model no longer need to consume and reply to
unrelated startup commands. Add the `WebInspectorDataKitTesting` product and
start a production-path container driven by deterministic raw input:

```swift
let runtime = try await WebInspectorDataKitTestRuntime.start(
    scenario: .init(
        configuration: .init(enabledFeatures: [.dom, .network]),
        document: .init(children: [
            .element(id: "result", name: "article")
        ]),
        networkReplay: [
            .init(id: "request-1", url: "https://example.test/result")
        ]
    )
)

let context = runtime.container.mainContext
let entries = WebInspectorFetchedResultsController<NetworkEntry>(
    modelContext: context
)
try await entries.performFetch()
var updates = entries.updates.makeAsyncIterator()
_ = await updates.next() // initial result

try await runtime.replacePage(with: .init())
_ = await updates.next() // context-applied replacement
await entries.close()
await runtime.close()
```

The runtime waits for every enabled feature owner to reach ready or static
unsupported availability. An unexpected feature or physical connection failure throws
`WebInspectorDataKitTestRuntime.RuntimeError.connectionFailed`; no failure is
returned as a feature boundary. Page replacement otherwise returns at the
feature boundary. When a test requires a context or
fetched-results revision, subscribe to and await that consumer-owned update
explicitly. Do not infer it from a testing-runtime counter.

Use `WebInspectorProxyKitTesting` directly when the wire command, raw JSON,
target registry, or exact reply ordering is the subject of the test.

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

Use a validated catalog to select the built-in tabs:

```swift
let catalog = try WebInspectorTabCatalog([.dom, .network])
let controller = WebInspectorViewController(catalog: catalog)
```

Custom tabs now use UIKit view controllers:

```swift
let consoleTab = WebInspectorTab(
    id: .init(rawValue: "app_console"),
    title: "Console",
    systemImage: "terminal"
) { context in
    ConsoleViewController(modelContext: context.modelContext)
}

let catalog = try WebInspectorTabCatalog([.dom, .network, consoleTab])
let controller = WebInspectorViewController(catalog: catalog)
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
