# WebInspectorKit

![WebInspectorKit preview](Resources/preview.webp)

UIKit/AppKit-native Web Inspector for `WKWebView` (iOS / macOS).

## Products

- `WebInspectorKit` (Native UI): UIKit/AppKit container, default tabs, presenters
- `WebInspectorKitCore` (Core): DOM/Network engines + bundled inspector scripts

`WebInspectorKit` depends on `WebInspectorKitCore`.

## Features

- DOM tree browsing (Web frontend hosted in `WKWebView`) with element picking, highlights, deletion, and attribute editing
- Network request logging (fetch/XHR/WebSocket) with buffering when the Network tab is not selected
- Configurable tabs via `WebInspector.TabDescriptor`
- Explicit lifecycle via `WebInspector.Controller` (`connect(to:)`, `suspend()`, `disconnect()`)
- Native presentation helpers:
  - iOS: `WebInspector.SheetPresenter`
  - macOS: `WebInspector.WindowPresenter`

## Requirements

- Swift 6.2+
- iOS 18 / macOS 15+
- WKWebView with JavaScript enabled

## Testing

```bash
swift test
npm run test:ts
```

## Installation

Add this repository as a Swift Package dependency in Xcode (Package Dependencies).
Choose one or both products depending on your use case:

- `WebInspectorKit`
- `WebInspectorKitCore`

## Quick Start (iOS)

```swift
import UIKit
import WebKit
import WebInspectorKit

final class BrowserViewController: UIViewController {
    private let pageWebView = WKWebView(frame: .zero)
    private let inspector = WebInspector.Controller()

    @objc private func presentInspector() {
        WebInspector.SheetPresenter.shared.present(
            from: self,
            inspector: inspector,
            webView: pageWebView,
            tabs: [.dom(), .element(), .network()]
        )
    }
}
```

## Quick Start (macOS)

```swift
import AppKit
import WebKit
import WebInspectorKit

final class BrowserWindowController: NSWindowController {
    let pageWebView = WKWebView(frame: .zero)
    let inspector = WebInspector.Controller()

    @objc func presentInspector() {
        WebInspector.WindowPresenter.shared.present(
            parentWindow: window,
            inspector: inspector,
            webView: pageWebView,
            tabs: [.dom(), .element(), .network()]
        )
    }
}
```

## Custom Tabs

```swift
let customTab = WebInspector.TabDescriptor(
    id: "my_custom_tab",
    title: "Custom",
    systemImage: "folder",
    role: .other
) { context in
    #if canImport(UIKit)
    return UIViewController()
    #elseif canImport(AppKit)
    return NSViewController()
    #endif
}

let container = WebInspector.ContainerViewController(
    inspector,
    webView: pageWebView,
    tabs: [.dom(), .element(), .network(), customTab]
)
```

Tip: If you omit `.network()`, network scripts are never installed.

## Limitations

- WKWebView only; JavaScript must be enabled.
- Console features are not implemented.

## Migration

Breaking changes from the SwiftUI-first API are documented in [`MIGRATION.md`](MIGRATION.md).

## License

See [LICENSE](LICENSE).
