# Migration from v0.1.x

This guide lists only the source changes that matter when upgrading from `v0.1.x` to the current API.

Internal refactors, transport rewrites, module splits, and cache changes are intentionally omitted unless they require changes in app code.

## 1. Replace the old inspector entry point

`WebInspectorView` was removed.

Use `WIViewController` or `WISession`.

```swift
@objc private func presentInspector() {
    let inspector = WIViewController()
    Task { @MainActor in
        await inspector.attach(to: pageWebView)
        present(inspector, animated: true)
    }
}
```

If your app used the default inspector UI, this is the main migration.

AppKit inspector UI is no longer shipped. macOS runtime and bridge support remains available
where it does not depend on the removed AppKit UI.

## 2. Rename the model and lifecycle API

| `v0.1.x` | Current |
| --- | --- |
| `WebInspectorModel` | `WISession` / `WIViewController` on UIKit |
| `WebInspectorConfiguration` | `WIModelConfiguration` |
| `attach(webView:)` | `attach(to:)` |
| `detach()` | `detach()` |

The old `connect(to:)`, `suspend()`, and `disconnect()` lifecycle path was removed.

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

Current:

```swift
let inspector = WIViewController(
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
    $0.domFrontend = WIInspectorDOMFrontendClient(
        domTreeViewScript: { "" },
        mainFileURL: { nil },
        resourcesDirectoryURL: { nil }
    )
}

let inspector = WIViewController(
    configuration: WIModelConfiguration(),
    dependencies: dependencies,
    tabs: [.dom, .network]
)
```

Use `WIInspectorDependencies.liveValue` for production defaults and
`WIInspectorDependencies.testing { ... }` for tests.

## 4. Update custom tab definitions

The important source-level changes are:

- UIKit custom tabs should use `WITab`.
- The old `WITabBuilder`-based `WebInspectorView { ... }` API is gone.
- Custom tabs provide a `UIViewController`.

```swift
let customTab = WITab.custom(
    id: "custom",
    title: "Custom",
    systemImage: "folder"
) { context in
    _ = context.runtime
    MyCustomViewController()
}

let controller = WIViewController(
    tabs: [.dom, .network, customTab]
)
```

If you only use the built-in tabs, keep using `.dom` and `.network`.

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
