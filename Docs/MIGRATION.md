# Migration from v0.1.x

This guide lists only the source changes that matter when upgrading from `v0.1.x` to the current public API.

Internal refactors, transport rewrites, module splits, and cache changes are intentionally omitted unless they require changes in app code.

## 1. Replace the old inspector entry point

`WebInspectorView` was removed.

Use `WebInspectorViewController` or `WebInspectorSession`.

```swift
@objc private func presentInspector() {
    let inspector = WebInspectorViewController()
    Task { @MainActor in
        try await inspector.attach(to: pageWebView)
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
| `WebInspectorModel` | `WebInspectorSession` / `WebInspectorViewController` on UIKit |
| `WebInspectorConfiguration` | no current app-facing replacement |
| `attach(webView:)` | `attach(to:)` |
| `detach()` | `detach()` |

The old `connect(to:)`, `suspend()`, and `disconnect()` lifecycle path was removed.
The DOM tree now follows the WebKit DOM protocol directly. Snapshot depth, subtree depth,
and DOM auto-update debounce are internal policies rather than public configuration.

Current:

```swift
let inspector = WebInspectorViewController()

try await inspector.attach(to: webView)
```

Remove any app-side DOM snapshot depth, subtree depth, or auto-update debounce tuning.
Those values are now owned by the native DOM runtime.

## 3. Remove old dependency injection code

The `v0.1.x` dependency injection and model configuration APIs are not part of the
current public API.

Remove app-side configuration of transport timeouts, runtime factories, and DOM reload
policies. Those boundaries are internal to the WebInspector runtime.

## 4. Remove `WebInspectorScripts` imports

The DOM tree frontend is now native UIKit/TextKit2. The `WebInspectorScripts` product and
`@_exported import WebInspectorScripts` are gone.

Remove direct `WebInspectorScripts` imports and any custom DOM frontend client
injection. Apps no longer need to run or ship the DOM tree JavaScript bundling
workflow.

## 5. Update tab definitions

The important source-level changes are:

- Use the built-in tabs exposed by `WebInspectorViewController`.
- The old custom-tab builder API is gone.
- Custom tabs are not part of the current public surface.

```swift
let controller = WebInspectorViewController(
    tabs: [.dom, .network]
)
```

If you only use the built-in tabs, keep using `.dom` and `.network`.

## 6. Remove old DOM model usage

The `v0.1.x` DOM model APIs are not part of the current public surface.

Do not migrate app code from one removed DOM API to another removed DOM API. DOM
and Network models are internal implementation details until their app-facing
command surface is explicitly published.
