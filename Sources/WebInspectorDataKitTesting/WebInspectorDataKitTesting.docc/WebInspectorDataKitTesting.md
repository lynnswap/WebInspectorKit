# ``WebInspectorDataKitTesting``

Drive deterministic raw inspector input through DataKit's production owners.

`WebInspectorDataKitTesting` creates an in-memory
`WebInspectorModelContainer`, supplies protocol replies and events through
`WebInspectorProxyKitTesting`, and joins those resources during teardown. The
container remains the sole owner of models, feature state, and model contexts.

```swift
import WebInspectorDataKit
import WebInspectorDataKitTesting

@MainActor
func inspectScenario() async throws {
    let runtime = try await WebInspectorDataKitTestRuntime.start(
        scenario: .init(
            configuration: .init(enabledFeatures: [.dom, .network]),
            document: .init(children: [
                .element(id: "button", name: "button")
            ]),
            networkReplay: [
                .init(
                    id: "initial-request",
                    url: "https://example.test/"
                )
            ]
        )
    )

    let context = runtime.container.mainContext
    let nodes = WebInspectorFetchedResultsController<DOMNode>(
        modelContext: context
    )
    try await nodes.performFetch()
    precondition(
        nodes.fetchedObjects?.contains { $0.localName == "button" } == true
    )

    await nodes.close()
    await runtime.close()
}
```

Use `WebInspectorModelContainer.mainContext` for main-actor consumers. A
custom actor declares `@WebInspectorModelActor` and initializes itself with
`WebInspectorModelActor.init(modelContainer:)` so its context and executor
come from the same production binding.

``WebInspectorDataKitTestRuntime/start(scenario:)`` waits until every enabled
feature reaches its supported boundary: `ready`, or feature-local `unavailable`
for a terminal feature failure.
``WebInspectorDataKitTestRuntime/replacePage(with:networkReplay:)`` additionally
waits for previously-ready feature owners to reach a terminal state in the
replacement generation. An already-unavailable feature remains terminal without
an implicit retry. Physical connection failure still throws
``WebInspectorDataKitTestRuntime/RuntimeError/connectionFailed(_:)``. The returned
``WebInspectorDataKitTestRuntime/BoundarySnapshot`` does not assert that a
consumer context or fetched-results controller has applied that store revision.
When a test needs consumer completion, subscribe to
`WebInspectorFetchedResultsController.updates` and await that consumer-owned
sequence.

The counters in ``WebInspectorDataKitTestRuntime/CounterSnapshot`` describe
only the testing driver boundary: accepted raw input, completed command replies,
and accepted page replacements. Always await
``WebInspectorDataKitTestRuntime/close()``. The runtime reports an explicit
``WebInspectorDataKitTestRuntime/LifecycleState`` and rejects later input with
``WebInspectorDataKitTestRuntime/RuntimeError/closed``.

## Topics

### Runtime lifecycle

- ``WebInspectorDataKitTestRuntime``
- ``WebInspectorDataKitTestRuntime/start(scenario:)``
- ``WebInspectorDataKitTestRuntime/LifecycleState``
- ``WebInspectorDataKitTestRuntime/RuntimeError``
- ``WebInspectorDataKitTestRuntime/close()``

### Deterministic boundaries

- ``WebInspectorDataKitTestRuntime/BoundarySnapshot``
- ``WebInspectorDataKitTestRuntime/FeatureBoundary``
- ``WebInspectorDataKitTestRuntime/CounterSnapshot``
- ``WebInspectorDataKitTestRuntime/boundarySnapshot()``
- ``WebInspectorDataKitTestRuntime/counterSnapshot()``
- ``WebInspectorDataKitTestRuntime/replacePage(with:networkReplay:)``

### Fixtures and raw input

- ``WebInspectorDataKitTestRuntime/Scenario``
- ``WebInspectorDataKitTestRuntime/Document``
- ``WebInspectorDataKitTestRuntime/Node``
- ``WebInspectorDataKitTestRuntime/NetworkRequest``
- ``WebInspectorDataKitTestRuntime/AttachFailure``
- ``WebInspectorDataKitTestRuntime/AttachFailureDomain``
