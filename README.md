# WebInspectorKit

[日本語版 README](README.ja.md)

![WebInspectorKit preview](Resources/preview.webp)

Web Inspector for `WKWebView` (iOS / macOS).

## Products

- `WebInspectorKit`: Container UI, `WITab`-based tab composition, Observation state
- `WebInspectorEngine` (Core): DOM/Network engines, runtime actors, bundled inspector scripts
- `WKViewport`: Explicit `WKWebView` viewport coordination for bars, safe area, keyboard overlap, and managed hosting

`WebInspectorKit` depends on `WebInspectorEngine`.

## Features

- DOM tree browsing (element picking, highlights, deletion, attribute editing)
- Network request logging (fetch/XHR/WebSocket) with buffering/active mode switching
- Configurable tabs via `WITab` (`viewControllerProvider` for custom tabs)
- Explicit lifecycle via `WIModel` (`connect(to:)`, `suspend()`, `disconnect()`)

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
    private let inspector = WIModel()

    @objc private func presentInspector() {
        let container = WITabViewController(
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

On iOS, `WITabViewController` defaults to `DOM + Network`.

- `compact` (`horizontalSizeClass == .compact`): `DOM`, `Element` (auto inserted when missing), `Network`
- `regular/unspecified` (`horizontalSizeClass != .compact`): `DOM` (split DOM + Element), `Network`
- In `regular/unspecified`, `wi_element` is always merged into `wi_dom` and never shown as a standalone tab.
- `UISplitViewController` is used only in `regular/unspecified` (`DOM`, `Network`). `compact` keeps single-column tab flows.
- `compact`: hosted by `UITabBarController`; each tab root is wrapped in `UINavigationController`.
- `regular/unspecified`: hosted by `UINavigationController` with a centered segmented tab switcher.
- Network search/filter use standard UIKit navigation APIs (`UISearchController`, `UIBarButtonItem` menu).
- `WITabViewController` now inherits from `UIViewController` (it no longer subclasses `UITabBarController`).

### AppKit

```swift
import AppKit
import WebKit
import WebInspectorKit

final class BrowserWindowController: NSWindowController {
    let pageWebView = WKWebView(frame: .zero)
    let inspector = WIModel()

    @objc func presentInspector() {
        let container = WITabViewController(
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
let customTab = WITab(
    title: "Custom",
    image: nil,
    identifier: "my_custom_tab",
    role: .other
) { tab in
    _ = tab
    #if canImport(UIKit)
    return UIViewController()
    #else
    return NSViewController()
    #endif
}

let container = WITabViewController(
    inspector,
    webView: pageWebView,
    tabs: [.dom(), .network(), customTab]
)
```

## WKViewport

`WKViewport` is a separate product in this package. Import it explicitly when you want viewport coordination without pulling it through `WebInspectorKit`.

```swift
import UIKit
import WebKit
import WKViewport

final class BrowserViewController: UIViewController {
    private let pageWebView = WKWebView(frame: .zero)
    private var viewportCoordinator: ViewportCoordinator?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(pageWebView)
        pageWebView.frame = view.bounds
        pageWebView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        viewportCoordinator = ViewportCoordinator(webView: pageWebView)
    }
}
```

`ManagedViewportWebView` is also available when you want a `WKWebView` subclass that manages viewport coordination automatically. `WKViewport` keeps iOS 18 era private selector fallback behavior for inset/chrome coordination, so treat it as an iOS-focused utility product.

## Migration

See [`MIGRATION.md`](Docs/MIGRATION.md) for details on breaking changes.

## License

See [LICENSE](LICENSE).
