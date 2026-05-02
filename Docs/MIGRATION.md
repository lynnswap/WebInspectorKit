# Migration from v0.1.x

This guide lists only the source changes that matter when upgrading from `v0.1.x` to the current API.

Internal refactors, transport rewrites, module splits, and cache changes are intentionally omitted unless they require changes in app code.

## 1. Replace the old inspector entry point

`WebInspectorView` was removed.

On UIKit, use the V2 entry point: `V2_WIViewController` or `V2_WISession`.
The older `WIInspectorController` / `WITabViewController` path remains for compatibility,
but it is no longer the recommended architecture and is scheduled for removal after V2
stabilizes.

```swift
@objc private func presentInspector() {
    let inspector = V2_WIViewController()
    Task { @MainActor in
        await inspector.attach(to: pageWebView)
        present(inspector, animated: true)
    }
}
```

If your app used the default inspector UI, this is the main migration.

AppKit should stay on `WIInspectorController` / `WITabViewController` until a V2 AppKit
surface is available.

## 2. Rename the model and lifecycle API

| `v0.1.x` | Current |
| --- | --- |
| `WebInspectorModel` | `V2_WISession` / `V2_WIViewController` on UIKit |
| `WebInspectorConfiguration` | `WIModelConfiguration` |
| `attach(webView:)` | `attach(to:)` |
| `detach()` | `detach()` |

`WIInspectorController.connect(to:)`, `suspend()`, and `disconnect()` remain only on the
legacy compatibility path.

The DOM-related configuration fields keep the same meaning, but they now live under `WIModelConfiguration.dom`.

Before:

```swift
let inspector = WebInspectorModel(
    configuration: WebInspectorConfiguration(
        snapshotDepth: 6,
        subtreeDepth: 4,
        autoUpdateDebounce: 0.3
    )
)

inspector.attach(webView: webView)
```

Legacy compatibility:

```swift
let inspector = WIInspectorController(
    configuration: WIModelConfiguration(
        dom: DOMConfiguration(
            snapshotDepth: 6,
            subtreeDepth: 4,
            autoUpdateDebounce: 0.3
        )
    )
)

inspector.connect(to: webView)
```

V2 UIKit:

```swift
let inspector = V2_WIViewController(
    configuration: WIModelConfiguration(
        dom: DOMConfiguration(
            snapshotDepth: 6,
            subtreeDepth: 4,
            autoUpdateDebounce: 0.3
        )
    )
)

await inspector.attach(to: webView)
```

## 3. Inject side effects through `WIInspectorDependencies`

`WIModelConfiguration` now stays focused on value-only configuration. Runtime factories,
scripts, WebKit SPI, transport, sleep/timeout behavior, and UIKit scene activation can be
injected through `WIInspectorDependencies`.

```swift
let dependencies = WIInspectorDependencies.testing {
    $0.network = WIInspectorNetworkClient(
        networkAgentScript: { "" }
    )
}

let inspector = V2_WIViewController(
    configuration: WIModelConfiguration(),
    dependencies: dependencies,
    tabs: [.dom, .network]
)
```

Use `WIInspectorDependencies.liveValue` for production defaults and
`WIInspectorDependencies.testing { ... }` for tests.

## 4. Update custom tab definitions

The important source-level changes are:

- UIKit custom tabs should use `V2_WITab`.
- The old `WITabBuilder`-based `WebInspectorView { ... }` API is gone.
- V2 custom tabs provide a `UIViewController`.

```swift
let customTab = V2_WITab.custom(
    id: "custom",
    title: "Custom",
    systemImage: "folder"
) { context in
    _ = context.runtime
    MyCustomViewController()
}

let controller = V2_WIViewController(
    tabs: [.dom, .network, customTab]
)
```

If you only use the built-in V2 tabs, keep using `.dom` and `.network`.

## 5. Use intent-based DOM APIs

The DOM model no longer exposes low-level `nodeId`-driven editing and reload APIs.

Use `WIDOMModel` intent methods instead.

| Previous | Current |
| --- | --- |
| `reloadInspector(preserveState: false)` | `reloadDocument()` |
| `reloadInspector(preserveState: true)` | `reloadDocumentPreservingInspectorState()` |
| `selectedEntry` on `WIDOMModel` | `documentStore.selectedEntry` |
| `errorMessage` on `WIDOMModel` | `documentStore.errorMessage` |
| `copySelection(.html)` | `copySelectedHTML()` |
| `copySelection(.selectorPath)` | `copySelectedSelectorPath()` |
| `copySelection(.xpath)` | `copySelectedXPath()` |
| `deleteSelectedNode()` | `deleteSelection()` |
| `updateAttributeValue(name:value:)` | `updateSelectedAttribute(name:value:)` |
| `removeAttribute(name:)` | `removeSelectedAttribute(name:)` |

Low-level `DOMSession` APIs such as `removeNode(nodeId:)`, `setAttribute(nodeId:...)`, and `selectorPath(nodeId:)` are no longer part of the supported app-facing API.
