# ``WebInspectorDataKit``

Observable Web Inspector models for building custom inspector interfaces.

## Overview

Use WebInspectorDataKit when you want WebKit inspector data as identity-preserving
models instead of sending protocol commands directly. DataKit owns DOM, Network,
Console, Runtime, and CSS model state for one inspected page and keeps those
models updated as WebKit emits protocol events.

Attach a ``WebInspectorContainer`` to a `WKWebView`, then read the
``WebInspectorContext`` for UI-bound model state:

```swift
import WebKit
import WebInspectorDataKit

@MainActor
final class InspectorModel {
    private var container: WebInspectorContainer?
    private(set) var context: WebInspectorContext?
    private var treeTask: Task<Void, Never>?

    func attach(to webView: WKWebView) async throws {
        let container = try await WebInspectorContainer(attachingTo: webView)
        let context = container.mainContext
        let tree = context.dom.treeController()

        treeTask = Task { @MainActor in
            for await update in tree.updates {
                render(update)
            }
        }

        self.container = container
        self.context = context
    }

    func close() async {
        treeTask?.cancel()
        await container?.close()
        container = nil
        context = nil
    }
}
```

Contexts are actor-owned. Read and mutate context state from the same actor you
used to create or obtain the context. For UIKit clients, ``WebInspectorContainer``
provides ``WebInspectorContainer/mainContext`` as a main-actor context.

Use the domain controllers on ``WebInspectorContext`` for high-level operations:

```swift
try await context.dom.setElementPickerEnabled(true)
try await context.page.reload()

let result = try await context.runtime.evaluate("document.title")
print(result.object.description ?? "")
```

Reach for WebInspectorDataKit when your UI wants stable model identity, undoable
DOM edits, fetched-results style collection updates, or derived DOM tree
snapshots. Reach for WebInspectorProxyKit when you need direct typed protocol
access with no model layer.

## Topics

### Creating a Model Context

- ``WebInspectorContainer``
- ``WebInspectorContext``

### Reading DOM State

- ``DOMNode``
- ``DOMTreeController``
- ``DOMTreeSnapshot``
- ``DOMTreeUpdate``

### Reading Network and Console State

- ``NetworkRequest``
- ``ConsoleMessage``
- ``WebInspectorFetchRequest``
- ``WebInspectorFetchedResultsController``

### Runtime and CSS Models

- ``RuntimeContext``
- ``RuntimeObject``
- ``RuntimeEvaluation``
- ``CSSStyles``
- ``CSSStyleSection``
- ``CSSStyleProperty``

### Domain Operations

- ``DOMModelController``
- ``NetworkModelController``
- ``ConsoleModelController``
- ``RuntimeModelController``
- ``CSSModelController``
- ``PageModelController``
- ``WebInspectorEditHistory``
