# Migration Guide

This standalone guide records source changes that are likely to affect app code
when upgrading WebInspectorKit. Sections are grouped by release, newest first.

## Unreleased

Unreleased builds require Swift 6.3+ and a minimum deployment target of iOS
18.4+ or macOS 15.4+. The built-in UIKit inspector remains iOS-only.

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
