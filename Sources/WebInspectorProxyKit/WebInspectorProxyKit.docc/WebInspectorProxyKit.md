# WebInspectorProxyKit

Typed Web Inspector protocol transport for an inspected `WKWebView`.

## Overview

Use WebInspectorProxyKit when you want direct access to WebKit's inspector
protocol commands and events. ProxyKit attaches to a `WKWebView`, tracks the
current page target, and exposes typed domain clients from ``WebInspectorTarget``.

Create a ``WebInspectorProxy``, wait for the current page, and send protocol
commands through target-scoped clients:

```swift
import WebKit
import WebInspectorProxyKit

@MainActor
func printPageTitle(from webView: WKWebView) async throws {
    let proxy = try await WebInspectorProxy(attachingTo: webView)
    defer {
        Task {
            await proxy.close()
        }
    }

    let page = try await proxy.waitForCurrentPage()
    try await page.runtime.enable()

    let evaluation = try await page.runtime.evaluate("document.title")
    print(evaluation.object.description ?? "")
}
```

Domain clients can also expose event streams. Enable the domain before consuming
events that require WebKit to start reporting that domain:

```swift
let page = try await proxy.waitForCurrentPage()
try await page.network.enable()

for await event in page.network.events {
    handleNetworkEvent(event)
}
```

ProxyKit is the lowest public layer in WebInspectorKit. Prefer
WebInspectorDataKit when you want observable model objects for UI binding,
selection, collection updates, and DOM tree snapshots.

## Topics

### Attaching to WebKit

- ``WebInspectorProxy``
- ``WebInspectorProxy/Configuration``
- ``WebInspectorTarget``
- ``WebInspectorProxyError``

### Protocol Domains

- ``DOM``
- ``CSS``
- ``Network``
- ``Console``
- ``Runtime``
- ``Page``

### Events and Targets

- ``RawEvent``
- ``FrameID``
