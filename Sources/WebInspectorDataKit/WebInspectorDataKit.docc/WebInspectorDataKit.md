# ``WebInspectorDataKit``

Observable Web Inspector models for building custom inspector interfaces.

## Overview

Use WebInspectorDataKit when you want WebKit inspector data as identity-preserving
models instead of sending protocol commands directly. DataKit owns DOM, Network,
Console, Runtime, and CSS model state for one inspected page and keeps those
models updated as WebKit emits protocol events.

Create one ``WebInspectorModelContext`` for an inspector lifetime. The UIKit
convenience initializer attaches it to a `WKWebView` on the main actor and
returns only after the initial model synchronization boundary:

```swift
import WebKit
import WebInspectorDataKit

@MainActor
final class InspectorModel {
    private(set) var context: WebInspectorModelContext?
    private var treeTask: Task<Void, Never>?

    func attach(to webView: WKWebView) async throws {
        let context = try await WebInspectorModelContext(attachingTo: webView)
        let tree = try context.domTree

        treeTask = Task { @MainActor in
            for await update in tree.updates {
                render(update)
            }
        }

        self.context = context
    }

    func close() async {
        treeTask?.cancel()
        await context?.close()
        context = nil
    }
}
```

Contexts are actor-owned rather than main-actor-only. ``WebInspectorModelContext/attach(to:isolation:)``
confines a context permanently to the caller's current actor by default. Read
observable state and invoke commands from that actor. The `WKWebView`
convenience initializer above deliberately binds the context to `MainActor`.

Use the context directly for high-level operations. Runtime objects belong to
an explicit binding-scoped group whose cleanup is awaited:

```swift
try await context.setElementPickerEnabled(true)
try await context.reload()

let result = try await context.withRuntimeObjectGroup { group in
    try await group.evaluate("document.title")
}
print(result.object.description ?? "")
```

Reach for WebInspectorDataKit when your UI wants stable model identity, undoable
DOM edits, fetched-results style collection updates, or derived DOM tree
snapshots. Reach for WebInspectorProxyKit when you need direct typed protocol
access with no model layer.

Create live Network and Console collections with their closed query values. The
index actor evaluates filters, ordering, sections, and windows; the context's
owner actor only resolves the identities in the published window:

```swift
let requests = try await context.networkRequests(matching: NetworkQuery(
    search: "api.example.com",
    resourceCategories: [.xhrFetch],
    methods: ["GET", "POST"],
    sort: .requestTimeDescending,
    section: .method,
    limit: 100
))

try await requests.update(NetworkQuery(
    resourceCategories: [.script],
    sort: .requestTimeAscending
))

let committedQuery = requests.query
if let requestID = requests.snapshot.itemIDs.first {
    let request = requests[id: requestID]
}
if let sectionID = requests.snapshot.sectionIDs.first {
    let section = requests[section: sectionID]
}

for await update in requests.updates() {
    apply(update)
}
```

The specialized `query` property is the last query whose result was committed
and published. An in-flight, cancelled, or superseded replacement does not
change it. Query, items, sections, identity lookups, snapshot, and revision
advance as one observable state. The identity subscripts perform constant-time
lookups in that current published state.

## Topics

### Creating a Model Context

- ``WebInspectorModelContext``
- ``WebInspectorModelContext/Configuration``
- ``WebInspectorModelContext/Domain``
- ``WebInspectorModelContext/State``
- ``WebInspectorModelContext/Failure``

### Reading DOM State

- ``DOMNode``
- ``DOMTreeController``
- ``DOMTreeSnapshot``
- ``DOMTreeUpdate``

### Reading Network and Console State

- ``NetworkRequest``
- ``ConsoleMessage``
- ``NetworkQuery``
- ``NetworkSort``
- ``NetworkSection``
- ``ConsoleQuery``
- ``ConsoleSort``
- ``ConsoleSection``
- ``WebInspectorFetchedResults``
- ``WebInspectorFetchedResultsSnapshot``
- ``WebInspectorFetchedResultsTransaction``
- ``WebInspectorFetchedResultsUpdate``

### Runtime and CSS Models

- ``RuntimeContext``
- ``RuntimeObject``
- ``RuntimeEvaluation``
- ``CSSStyles``
- ``CSSStyleSection``
- ``CSSStyleProperty``

### Mutations

- ``WebInspectorUndoPolicy``
- ``DOMRevealPolicy``
- ``DOMMutationOutcome``
- ``DOMMutationFailure``
- ``DOMUndoCapability``
