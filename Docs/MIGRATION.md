# Migration from v0.1.x

This guide lists only the source changes that matter when upgrading from `v0.1.x` to the current API.

Internal refactors, transport rewrites, module splits, and cache changes are intentionally omitted unless they require changes in app code.

## 1. Replace the old inspector entry point

`WebInspectorView` was removed.

Use `WITabViewController` with a `WIModel` instead.

```swift
private let inspector = WIModel()

@objc private func presentInspector() {
    let controller = WITabViewController(
        inspector,
        webView: pageWebView,
        tabs: [.dom(), .network()]
    )
    present(controller, animated: true)
}
```

If your app used the default inspector UI, this is the main migration.

## 2. Rename the model and lifecycle API

| `v0.1.x` | Current |
| --- | --- |
| `WebInspectorModel` | `WIModel` |
| `WebInspectorConfiguration` | `WIModelConfiguration` |
| `attach(webView:)` | `connect(to:)` |
| `detach()` | `disconnect()` |

`suspend()` is still available.

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

After:

```swift
let inspector = WIModel(
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

## 3. Update custom tab definitions

The important source-level changes are:

- `WITab` changed from a value type to a reference type.
- `WITabRole` became `WITab.Role`.
- `value:` became `id:` / `identifier:`.
- Tab titles are now plain `String`.
- The old `WITabBuilder`-based `WebInspectorView { ... }` API is gone.
- Custom tabs now provide a platform view controller (`UIViewController` / `NSViewController`).

```swift
let customTab = WITab(
    id: "custom",
    title: "Custom",
    systemImage: "folder",
    role: .other
) { _ in
    MyCustomViewController()
}

let controller = WITabViewController(
    inspector,
    webView: pageWebView,
    tabs: [.dom(), .network(), customTab]
)
```

If you only use the built-in tabs, keep using `.dom()`, `.network()`, and on UIKit `.element()`.
