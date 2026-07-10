# ``WebInspectorDataKitTesting``

Create ready DataKit model scenarios without scripting protocol startup.

`WebInspectorDataKitTesting` drives the same raw peer and production connection
core as `WebInspectorProxyKitTesting`, then owns the model bootstrap replies and
resource teardown needed by a DataKit consumer test.

```swift
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

let button = try await runtime.selectElementWithPicker(nodeID: "button")
precondition(button.localName == "button")

await runtime.close()
```

The runtime and its model are non-`Sendable` and inherit the actor passed to
``WebInspectorDataKitTestRuntime/start(scenario:isolation:)``. Immutable fixture
values are `Sendable`. Always await ``WebInspectorDataKitTestRuntime/close()``;
deinitialization only cancels the command consumer as a synchronous backstop.

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
