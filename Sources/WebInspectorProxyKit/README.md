# WebInspectorProxyKit

WebInspectorProxyKit provides typed Web Inspector protocol commands and events
for an inspected `WKWebView`.

Use this package when app or framework code wants to build a custom inspector UI
directly on WebKit's inspector protocol. Use WebInspectorDataKit instead when
you want identity-preserving DOM, Network, Console, Runtime, and CSS models.

This README is the package contract for the rearchitecture. Transport sessions,
native symbol lookup, protocol routing, and WebKit private attachment details are
implementation details of this package unless explicitly listed here.

## Main Types

- `WebInspectorProxy`: Actor that owns the attached inspector connection,
  target lifecycle, command dispatch, and close lifecycle.
- `WebInspectorProxy.Configuration`: Timeout configuration for command replies
  and current-page bootstrap.
- `WebInspectorTarget`: A typed protocol target such as the current page or a
  frame target. It vends domain clients.
- `DOM.Client`, `CSS.Client`, `Network.Client`, `Console.Client`,
  `Runtime.Client`, `Page.Client`: Typed domain command clients.
- `DOM.EventStream`, `CSS.EventStream`, `Network.EventStream`,
  `Console.EventStream`, `Runtime.EventStream`: Typed domain event streams.
- `WebInspectorProxyError`: Public error model for closed/disconnected proxy
  state and protocol command failures.

## Quick Start

```swift
import WebInspectorProxyKit
import WebKit

let proxy = try await WebInspectorProxy(attachingTo: webView)
let page = try await proxy.waitForCurrentPage()

try await page.runtime.enable()

let result = try await page.runtime.evaluate("document.title")
print(result.object.description ?? "")

try await proxy.close()
```

## Attachment and Lifecycle

Attach to a `WKWebView` on the main actor:

```swift
let proxy = try await WebInspectorProxy(
    attachingTo: webView,
    configuration: WebInspectorProxy.Configuration(
        responseTimeout: .seconds(5),
        bootstrapTimeout: .seconds(5)
    )
)
```

The proxy discovers the current page target during bootstrap. Call
`waitForCurrentPage()` when code needs a page target and should fail if the proxy
is closed or detached.

```swift
let page = try await proxy.waitForCurrentPage()
```

Close is explicit and waitable:

```swift
Task {
    try await proxy.waitUntilClosed()
}

await proxy.close()
```

`waitUntilClosed()` returns immediately when already closed. While open, it
suspends until `close()` completes or the waiting task is cancelled.

## Targets and Domain Clients

`WebInspectorTarget` is a lightweight handle for a protocol target:

```swift
public struct WebInspectorTarget: Identifiable, Sendable {
    public var id: ID { get }
    public var kind: Kind { get }
    public var frameID: FrameID? { get }
    public var dom: DOM.Client { get }
    public var css: CSS.Client { get }
    public var network: Network.Client { get }
    public var console: Console.Client { get }
    public var runtime: Runtime.Client { get }
    public var page: Page.Client { get }
}
```

Command routing across page/frame targets is owned by `WebInspectorProxy`.
Consumers should call the typed domain client on the target they were given, not
construct protocol routes or transport target IDs themselves.

## DOM Domain

```swift
let document = try await page.dom.getDocument()
try await page.dom.requestChildNodes(document.id, depth: 1)
try await page.dom.highlightNode(document.id)
try await page.dom.hideHighlight()
try await page.dom.setInspectMode(enabled: true)
```

DOM editing commands stay protocol-level in ProxyKit:

```swift
try await page.dom.setAttributeValue(document.id, name: "class", value: "selected")
try await page.dom.setAttributesAsText(document.id, text: #"class="selected""#)
try await page.dom.removeAttribute(document.id, name: "hidden")
try await page.dom.setOuterHTML(document.id, html: "<main></main>")
try await page.dom.removeNode(document.id)

try await page.dom.markUndoableState()
try await page.dom.undo()
try await page.dom.redo()
```

ProxyKit does not decide whether an edit should be undoable, which node should
be selected after replacement, or how stale DOM generations should be handled.
Those are DataKit responsibilities. ProxyKit only routes the typed command to
the target represented by `WebInspectorTarget`.

DOM events are typed:

```swift
Task {
    for await event in page.dom.events {
        switch event {
        case .documentUpdated:
            reloadDocument()
        case let .childNodeInserted(parent, previous, node):
            applyInsertion(parent: parent, previous: previous, node: node)
        case let .inspect(nodeID):
            reveal(nodeID)
        case let .inlineStyleInvalidated(nodeIDs):
            reloadAttributesAndStyles(for: nodeIDs)
        case let .willDestroyDOMNode(nodeID):
            releaseNodeState(nodeID)
        default:
            break
        }
    }
}
```

`Inspector.inspect` is projected into DOM inspection events. Consumers that use
`DOM.Client.events` do not need to subscribe to the Inspector domain separately
for picker selection.

## Network Domain

```swift
try await page.network.enable()

Task {
    for await event in page.network.events {
        switch event {
        case let .requestWillBeSent(id, request, resourceType, redirectResponse, timestamp):
            handleRequest(id, request, resourceType, redirectResponse, timestamp)
        case let .responseReceived(id, response, resourceType, timestamp):
            handleResponse(id, response, resourceType, timestamp)
        case let .loadingFinished(id, timestamp, sourceMapURL, metrics):
            handleFinished(id, timestamp, sourceMapURL, metrics)
        default:
            break
        }
    }
}
```

ProxyKit owns typed protocol decoding and command routing only. It does not own
accumulated request models, filtering, search, sorting, resource categories, or
list membership. Those belong to WebInspectorDataKit.

Response body commands stay protocol-level in ProxyKit:

```swift
let body = try await page.network.responseBody(for: requestID)
```

## Runtime Domain

```swift
try await page.runtime.enable()

let evaluation = try await page.runtime.evaluate("document.querySelector('main')")

if let objectID = evaluation.object.id {
    let properties = try await page.runtime.properties(of: objectID)
    let preview = try await page.runtime.preview(of: objectID)
    try await page.runtime.releaseObject(objectID)
}
```

Runtime remote objects are protocol values. DataKit may wrap them in
identity-preserving observable models, but ProxyKit does not retain semantic
Runtime object ownership beyond protocol commands and events.

## CSS, Console, and Page Domains

CSS:

```swift
try await page.css.enable()
let styles = try await page.css.matchedStyles(for: nodeID)
try await page.css.setStyleText(styleID, text: "display: none;")
try await page.css.setStyleSheetText(styleSheetID, text: stylesheetText)
try await page.css.setRuleSelector(ruleID, selector: ".card.selected")
try await page.css.setGroupingHeaderText(ruleID, text: "@media (width > 600px)")
```

WebKit has no protocol command for "toggle CSS property" or "set CSS property
text". Higher layers rewrite the owning declaration and call `CSS.setStyleText`.
ProxyKit exposes only the protocol commands and typed results.

CSS events are typed:

```swift
Task {
    for await event in page.css.events {
        switch event {
        case let .styleSheetChanged(styleSheetID):
            refreshStyles(for: styleSheetID)
        case let .styleSheetAdded(header):
            registerStyleSheet(header)
        case let .styleSheetRemoved(styleSheetID):
            unregisterStyleSheet(styleSheetID)
        default:
            break
        }
    }
}
```

Console:

```swift
try await page.console.enable()

for await event in page.console.events {
    handleConsoleEvent(event)
}
```

Page:

```swift
try await page.page.reload(ignoringCache: false)
try await proxy.reload()
```

## Event Streams

Domain event streams are `AsyncSequence`s. They are cold subscriptions backed by
the active proxy backend. Cancelling the consuming task cancels the subscription.

```swift
let task = Task {
    for await event in page.dom.events {
        handle(event)
    }
}

task.cancel()
```

A backend must not emit mismatched event cases for a subscribed domain. Mismatched
events are programmer errors in the backend implementation.

## ProxyKit/DataKit Boundary

ProxyKit owns:

- Attaching to an inspectable `WKWebView`.
- Bootstrapping and tracking protocol targets.
- Typed command payload/result decoding.
- Typed event decoding.
- Routing commands to page/frame targets.
- Close and disconnect lifecycle.

ProxyKit does not own:

- DOM graph materialization or tree snapshots.
- DOM selection, reveal, or page highlight policy.
- DOM/CSS edit semantics, stale generation policy, or undo grouping decisions.
- Network request accumulation.
- Network filtering, searching, sorting, or resource-category classification.
- Console message lists.
- Runtime object identity beyond protocol object IDs.
- CSS style hydration, declaration rewriting, property toggling, matched-style
  refresh policy, or inspector modification baselines.
- UIKit/AppKit/SwiftUI rendering.

Use WebInspectorDataKit for those model responsibilities.

## Internal Transport Boundary

The following concepts are implementation details and should not appear in SDK
consumer code:

- transport sessions and transport backends
- native inspector symbols
- native bridge entry points
- routing target IDs
- provisional target message queues
- reply stores and inbound message queues

If custom UI code needs low-level protocol control, it should use
`WebInspectorProxy`, `WebInspectorTarget`, and typed domain clients. If it needs
observable inspector models, it should use WebInspectorDataKit.

## Testing

ProxyKit tests should verify protocol behavior without DataKit or UI:

- attach/bootstrap current page
- close and `waitUntilClosed()` lifecycle
- command routing to page and frame targets
- typed decoding of Runtime, DOM, CSS, Network, Console, and Page payloads
- `Inspector.inspect` projection into DOM events
- DOM edit command payloads and edit-related events such as
  `DOM.inlineStyleInvalidated` and `DOM.willDestroyDOMNode`
- CSS edit command payloads/results and typed `CSS.styleSheetChanged` routing
- transport-backed command result decoding
- disconnect and command-failure error mapping
