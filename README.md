# WebInspectorKit

[日本語版 README](README.ja.md)

![WebInspectorKit preview](WebInspectorKit/Resources/preview.webp)

Web Inspector for `WKWebView` (iOS / macOS).

## Products

- `WebInspectorKit`: Container UI, tab descriptors, Observation state
- `WebInspectorKitCore` (Core): DOM/Network engines, runtime actors, bundled inspector scripts

`WebInspectorKit` depends on `WebInspectorKitCore`.

## Features

- DOM tree browsing (element picking, highlights, deletion, attribute editing)
- Network request logging (fetch/XHR/WebSocket) with buffering/active mode switching
- Configurable tabs via `WITabDescriptor`
- Explicit lifecycle via `WISessionController` (`connect(to:)`, `suspend()`, `disconnect()`)

## Requirements

- Swift 6.2+
- iOS 18 / macOS 15+
- WKWebView with JavaScript enabled

## Quick Start

### UIKit

```swift
import UIKit
import WebKit
import WebInspectorKit

final class BrowserViewController: UIViewController {
    private let pageWebView = WKWebView(frame: .zero)
    private let inspector = WISessionController()

    @objc private func presentInspector() {
        let container = WIContainerViewController(
            inspector,
            webView: pageWebView,
            tabs: [.dom(), .network()]
        )
        container.modalPresentationStyle = .pageSheet
        if let sheet = container.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .medium
        }
        present(container, animated: true)
    }
}
```

On iOS, `WIContainerViewController` defaults to `DOM + Network`.

- `compact` (`horizontalSizeClass == .compact`): `DOM`, `Element` (auto inserted when missing), `Network`
- `regular/unspecified` (`horizontalSizeClass != .compact`): `DOM` (split DOM + Element), `Network`
- In `regular/unspecified`, `wi_element` is always merged into `wi_dom` and never shown as a standalone tab.
- `UISplitViewController` is used only in `regular/unspecified` (`DOM`, `Network`). `compact` keeps single-column tab flows.
- `compact`: hosted by `UITabBarController`; each tab root is wrapped in `UINavigationController`.
- `regular/unspecified`: hosted by `UINavigationController` with a centered segmented tab switcher.
- Network search/filter use standard UIKit navigation APIs (`UISearchController`, `UIBarButtonItem` menu).
- `WIContainerViewController` now inherits from `UIViewController` (it no longer subclasses `UITabBarController`).

### AppKit

```swift
import AppKit
import WebKit
import WebInspectorKit

final class BrowserWindowController: NSWindowController {
    let pageWebView = WKWebView(frame: .zero)
    let inspector = WISessionController()

    @objc func presentInspector() {
        let container = WIContainerViewController(
            inspector,
            webView: pageWebView,
            tabs: [.dom(), .network()]
        )
        let inspectorWindow = NSWindow(contentViewController: container)
        inspectorWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        inspectorWindow.title = "Web Inspector"
        inspectorWindow.setContentSize(NSSize(width: 960, height: 720))
        inspectorWindow.makeKeyAndOrderFront(nil)
    }
}
```

## Custom Tab

```swift
let customTab = WITabDescriptor(
    id: "my_custom_tab",
    title: "Custom",
    systemImage: "folder",
    role: .other
) { context in
    #if canImport(UIKit)
    return UIViewController()
    #else
    return NSViewController()
    #endif
}

let container = WIContainerViewController(
    inspector,
    webView: pageWebView,
    tabs: [.dom(), .network(), customTab]
)
```

## Migration

See [`MIGRATION.md`](Docs/MIGRATION.md) for details on breaking changes.

## License

See [LICENSE](LICENSE).
