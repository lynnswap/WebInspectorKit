# ``WebInspectorDataKit``

Observable Web Inspector models for building custom inspector interfaces.

## Overview

Use WebInspectorDataKit when you want WebKit inspector data as identity-preserving
models instead of sending protocol commands directly. DataKit owns DOM, Network,
Console, Runtime, and CSS model state for one inspected page and keeps those
models updated as WebKit emits protocol events.

Create a ``WebInspector``, attach it to a `WKWebView`, and read its domain
objects:

```swift
import WebKit
import WebInspectorDataKit

@MainActor
final class RequestListModel {
    let inspector = WebInspector()
    private var changesTask: Task<Void, Never>?

    func inspect(_ webView: WKWebView) {
        inspector.attach(to: webView)
        let changes = inspector.network.requestChanges
        var requests = inspector.network.requests
        changesTask?.cancel()
        changesTask = Task { @MainActor in
            for await change in changes {
                apply(change, to: &requests)
            }
        }
    }
}
```

``WebInspector/attach(to:configuration:)`` and ``WebInspector/detach()`` return
immediately, and ``WebInspector/state`` reports their progress. Attaching again
replaces the current attachment, so the same call follows the user from one web
view to another. The inspector and its models are bound to the main actor and
are observable.

Each domain object holds the state of its domain and the commands that act on
its models:

```swift
try await inspector.dom.setElementPickerEnabled(true)
try await inspector.page.reload()

let result = try await inspector.runtime.evaluate("document.title")
print(result.object.description ?? "")
```

Reach for WebInspectorDataKit when your UI wants stable model identity, undoable
DOM edits, ordered request and message collections with change feeds, or
derived DOM tree snapshots. Reach for WebInspectorProxyKit when you need direct typed protocol
access with no model layer.

## Topics

### Essentials

- <doc:ModelRegistrationLifetimes>

### Inspecting a Web View

- ``WebInspector``

### Reading DOM State

- ``DOMNode``
- ``DOMTreeController``
- ``DOMTreeSnapshot``
- ``DOMTreeUpdate``

### Reading Network and Console State

- ``NetworkRequest``
- ``ConsoleMessage``
- ``WebInspectorCollectionChange``

### Runtime and CSS Models

- ``RuntimeContext``
- ``RuntimeObject``
- ``RuntimeEvaluation``
- ``CSSStyles``
- ``CSSStyleSection``
- ``CSSStyleProperty``

### Domains

- ``DOMInspector``
- ``NetworkInspector``
- ``ConsoleInspector``
- ``RuntimeInspector``
- ``CSSInspector``
- ``PageInspector``
