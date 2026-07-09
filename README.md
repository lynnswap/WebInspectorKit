# WebInspectorKit

![WebInspectorKit preview](Resources/preview.webp)

UIKit Web Inspector for `WKWebView`.

> [!WARNING]
> This package relies on undocumented APIs and runtime behavior, so extra care is needed before using it in App Store-bound projects.

## Features

- DOM tree browsing
- Network request logging
- Built-in DOM and Network tabs

## Requirements

- Swift 6.3+
- iOS 18+
- ARM64/ARM64e Apple runtime; Intel Mac / x86_64 simulator environments are not
  supported.

## Platform Notes

- The current implementation targets UIKit on iOS.
- AppKit support is planned to be rebuilt separately.

## Products

| Product | Use when |
| --- | --- |
| `WebInspectorKit` | You want the built-in UIKit inspector UI. |
| `WebInspectorDataKit` | You want observable DOM, Network, Console, Runtime, and CSS models for a custom UI. |
| `WebInspectorProxyKit` | You want typed Web Inspector protocol commands and events directly over an inspected `WKWebView`. |
| `WebInspectorProxyKitTesting` | You want a public test runtime for ProxyKit/DataKit consumers without the native WebKit bridge. |

## Quick Start

### UIKit

```swift
import UIKit
import WebKit
import WebInspectorKit

final class BrowserViewController: UIViewController {
    private let pageWebView = WKWebView(frame: .zero)

    @objc private func presentInspector() {
        let inspector = WebInspectorViewController()
        inspector.modalPresentationStyle = .pageSheet
        if let sheet = inspector.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .medium
        }
        Task { @MainActor in
            try await inspector.attach(to: pageWebView)
            present(inspector, animated: true)
        }
    }
}
```

## Tabs

```swift
let inspector = WebInspectorViewController(
    tabs: [.dom, .network]
)
```

The built-in tab surface exposes DOM and Network tabs. Apps can also add UIKit
tabs with a `UIViewController` factory:

```swift
let consoleTab = WebInspectorTab(
    id: "app_console",
    title: "Console",
    systemImage: "terminal"
) { session in
    ConsoleViewController(inspectorSession: session)
}

let inspector = WebInspectorViewController(
    tabs: [.dom, .network, consoleTab]
)
```

## Documentation

The DocC workflow publishes symbol-level documentation to GitHub Pages:

- [Package Documentation](https://lynnswap.github.io/WebInspectorKit/documentation/)
- [WebInspectorUI](https://lynnswap.github.io/WebInspectorKit/documentation/webinspectorui/)
- [WebInspectorDataKit](https://lynnswap.github.io/WebInspectorKit/documentation/webinspectordatakit/)
- [WebInspectorProxyKit](https://lynnswap.github.io/WebInspectorKit/documentation/webinspectorproxykit/)
- [WebInspectorProxyKitTesting](https://lynnswap.github.io/WebInspectorKit/documentation/webinspectorproxykittesting/)

| Document | Purpose |
| --- | --- |
| [Migration Guide](Docs/MIGRATION.md) | Version-by-version source migration notes for app code. |
| [WebInspectorUI](Sources/WebInspectorUI/README.md) | UIKit inspector implementation notes and UI/DataKit ownership boundaries. |
| [WebKit Version Mapping](Docs/WebKitVersionMapping.md) | Local notes for mapping iOS WebKit framework versions to public WebKit source refs. |

## Project Structure

```text
Sources/
  WebInspectorKit/             Public built-in inspector product.
  WebInspectorDataKit/         Observable inspector model product.
  WebInspectorProxyKit/        Typed protocol proxy product.
  WebInspectorProxyKitTesting/ Test runtime for proxy/model consumers.
  WebInspectorUI*/             Internal UIKit implementation targets.
Packages/
  WebInspectorNativeBridge/    Local native bridge package for ProxyKit internals.
Docs/
  MIGRATION.md                 Version-by-version migration notes.
  WebKitVersionMapping.md      WebKit runtime/source mapping notes.
```

## License

See [LICENSE](LICENSE).
