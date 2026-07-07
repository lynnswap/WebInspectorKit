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

## Platform Notes

- The current implementation targets UIKit on iOS.
- AppKit support is planned to be rebuilt separately.

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

Start with [`MIGRATION.md`](Docs/MIGRATION.md) when updating from an older
release.

For implementation work, [`ArchitectureOverview.md`](Docs/ArchitectureOverview.md)
is the top-level map for module boundaries, runtime ownership, and WebKit
communication flow. The current SDK split is:

- `WebInspectorProxyKit` for custom UIs that want typed domain commands and
  events directly over an inspected `WKWebView`.
- `WebInspectorDataKit` for custom UIs that want observable DOM, Network,
  Console, Runtime, and CSS models built on top of `WebInspectorProxyKit`.
- `WebInspectorKit` for the built-in UIKit inspector UI.

`WebInspectorNativeBridge`, `WebInspectorNativeSymbols`, and the internal
protocol-routing code are implementation details of `WebInspectorProxyKit`;
SDK consumers should not import or depend on them.

## License

See [LICENSE](LICENSE).
