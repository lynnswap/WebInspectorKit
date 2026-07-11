# ``WebInspectorProxyKit``

Typed Web Inspector protocol transport for an inspected `WKWebView`.

## Overview

Use WebInspectorProxyKit when you want direct access to WebKit's inspector
protocol commands and events. ProxyKit attaches to a `WKWebView`, tracks the
current physical page internally, and exposes typed domain handles from one
stable ``WebInspectorPage``.

Create a ``WebInspectorProxy`` and send protocol commands through its logical
page handle:

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

    let evaluation = try await proxy.page.runtime.evaluate("document.title")
    print(evaluation.object.description ?? "")
}
```

Domain clients expose atomically registered event scopes. The scope registers
its subscriber before WebKit domain activation and balances deactivation when
the operation finishes:

```swift
try await proxy.page.network.withEvents { events in
    for try await pageEvent in events {
        switch pageEvent {
        case .reset:
            resetNetworkPresentation()
        case let .event(_, event):
            handleNetworkEvent(event)
        }
    }
}
```

ProxyKit is the lowest public layer in WebInspectorKit. Prefer
WebInspectorDataKit when you want observable model objects for UI binding,
selection, collection updates, and DOM tree snapshots.

## Topics

### Attaching to WebKit

- ``WebInspectorProxy``
- ``WebInspectorProxy/Configuration``
- ``WebInspectorPage``
- ``WebInspectorProxyError``

### Protocol Domains

- ``DOM``
- ``CSS``
- ``Network``
- ``Console``
- ``Runtime``
- ``Page``

### Events and Identity

- ``WebInspectorPageEvent``
- ``WebInspectorEventBufferingPolicy``
- ``RawEvent``
- ``FrameID``
