# ``WebInspectorDataKit``

Observable Web Inspector models for building custom inspector interfaces.

## Overview

Use WebInspectorDataKit when an inspector UI needs identity-preserving DOM,
Network, Console, Runtime, and CSS models instead of direct protocol payloads.
One ``WebInspectorModelContainer`` owns the physical attachment, canonical
feature stores, and bounded feature recovery. Container-issued
``WebInspectorModelContext`` instances own only a caller-confined identity map
and generic fetch registrations.

On UIKit, attach the container to a `WKWebView`, obtain its main context, and
explicitly fetch a flat result set:

```swift
import Foundation
import WebKit
import WebInspectorDataKit

@MainActor
final class InspectorModel {
    private let container = WebInspectorModelContainer()
    private var nodes: WebInspectorFetchedResultsController<DOMNode>?
    private var updatesTask: Task<Void, Never>?

    func attach(to webView: WKWebView) async throws {
        try await container.attach(to: webView)
        let controller = WebInspectorFetchedResultsController<DOMNode>(
            modelContext: container.mainContext
        )
        try await controller.performFetch()
        nodes = controller

        updatesTask = Task { @MainActor in
            for await update in controller.updates {
                render(update)
            }
        }
    }

    func close() async {
        updatesTask?.cancel()
        await nodes?.close()
        await container.close()
    }
}
```

Use a generic ``WebInspectorFetchDescriptor`` to filter, sort, offset, or limit
any shipped persistent model. Predicate and sort evaluation use immutable
`QueryValue` fields away from the context owner. The controller publishes one
flat ``WebInspectorFetchedResultsSnapshot`` and atomic initial, changes, or
reset updates; it does not expose sections.

```swift
let descriptor = WebInspectorFetchDescriptor<NetworkRequest>(
    predicate: #Predicate { $0.method == "GET" },
    sortBy: [SortDescriptor(\.insertionIndex)]
)
let requests = WebInspectorFetchedResultsController(
    fetchDescriptor: descriptor,
    modelContext: container.mainContext
)
try await requests.performFetch()

if let requestID = requests.snapshot?.itemIDs.first,
   let request = container.mainContext.model(for: requestID) {
    print(request.url)
}
```

Observable model instances stay on their context's executor. Carry stable IDs
or immutable query values across actor boundaries. A custom actor declares
``WebInspectorModelActor()`` so its stored binding, context, and retained
serial executor are issued together by the container.

Feature commands belong to the feature owner, not to ModelContext. Runtime
remote objects additionally belong to an explicit scope whose close is
awaited:

```swift
try await container.dom.highlight(nodeID)
try await container.network.clear()

let scope = await container.runtime.makeObjectScope()
let result = try await scope.evaluate("document.title")
print(result.object.description ?? "")
await scope.close()
```

DOM and Console/Runtime failures use bounded feature-local recovery and may
become unavailable. Observe ``WebInspectorFeatureHandle/stateUpdates`` and use
the concrete retryable handle's `retry()` when explicit retry is appropriate.
Network uses the same feature-local failure boundary but does not expose retry;
an explicit detach/attach creates its next runner. Feature failure does not end
the physical ``WebInspectorModelContainer`` attachment or disable sibling
features. Reach for WebInspectorProxyKit when direct typed protocol access is
preferable to the model layer.

## Topics

### Containers and Contexts

- ``WebInspectorModelContainer``
- ``WebInspectorModelContext``
- ``WebInspectorModelActor()``
- ``WebInspectorModelActor``
- ``WebInspectorModelActorBinding``

### Generic Fetching

- ``WebInspectorFetchDescriptor``
- ``WebInspectorFetchedResultsController``
- ``WebInspectorFetchedResultsSnapshot``
- ``WebInspectorFetchedResultsRevision``
- ``WebInspectorFetchedResultsItemChange``
- ``WebInspectorFetchedResultsUpdate``
- ``WebInspectorFetchedResultsUpdateSequence``

### DOM and CSS

- ``DOMNode``
- ``CSSStyles``
- ``CSSStyleSection``
- ``CSSStyleProperty``
- ``WebInspectorDOM``

### Network

- ``NetworkEntry``
- ``NetworkRequest``
- ``WebInspectorNetwork``

### Console and Runtime

- ``ConsoleMessage``
- ``RuntimeContext``
- ``RuntimeObject``
- ``RuntimeEvaluation``
- ``WebInspectorConsole``
- ``WebInspectorRuntime``
- ``WebInspectorRuntimeObjectScope``

### Feature and Command Boundaries

- ``WebInspectorFeatureID``
- ``WebInspectorFeatureState``
- ``WebInspectorFeatureHandle``
- ``WebInspectorRetryableFeatureHandle``
- ``WebInspectorConnectionFailure``
- ``WebInspectorCommandError``
- ``WebInspectorElementPickerState``
- ``WebInspectorElementPickerError``
