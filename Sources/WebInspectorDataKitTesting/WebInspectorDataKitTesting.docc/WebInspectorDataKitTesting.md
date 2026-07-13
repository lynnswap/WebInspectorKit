# ``WebInspectorDataKitTesting``

Create ready DataKit model scenarios without scripting protocol startup.

`WebInspectorDataKitTesting` drives the same raw peer and production connection
core as `WebInspectorProxyKitTesting`, then owns the model bootstrap replies and
resource teardown needed by a DataKit consumer test.

```swift
import WebInspectorDataKit
import WebInspectorDataKitTesting

let runtime = try await WebInspectorDataKitTestRuntime.start(
    scenario: .init(
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

let nodes = try await WebInspectorFetchedResultsController<DOMNode, Never>(
    modelContext: runtime.model
)
precondition(nodes.snapshot.itemIDs.contains { id in
    runtime.model.model(for: id)?.localName == "button"
})

await nodes.close()
await runtime.close()
```

The runtime owns a ``WebInspectorModelContainer`` and a context vended by that
container. The context inherits the actor passed to
``WebInspectorDataKitTestRuntime/start(scenario:isolation:)``. Immutable fixture
values are `Sendable`. Always await ``WebInspectorDataKitTestRuntime/close()``;
deinitialization only cancels the command consumer as a synchronous backstop.
``WebInspectorDataKitTestRuntime/replacePage(with:networkReplay:isolation:)``
returns after the production feed reaches its next synchronization marker and
every Context registered with the Container has applied and acknowledged that
revision.

## Topics

### Runtime

- ``WebInspectorDataKitTestRuntime``
- ``WebInspectorDataKitTestRuntime/Scenario``
- ``WebInspectorDataKitTestRuntime/close()``

### Fixtures

- ``WebInspectorDataKitTestRuntime/Document``
- ``WebInspectorDataKitTestRuntime/Node``
- ``WebInspectorDataKitTestRuntime/NetworkRequest``
- ``WebInspectorDataKitTestRuntime/AttachFailure``
