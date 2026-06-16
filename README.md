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

The current public tab surface exposes the built-in DOM and Network tabs.

## Documentation

Start with [`MIGRATION.md`](Docs/MIGRATION.md) when updating from an older
release.

For implementation work, [`ArchitectureOverview.md`](Docs/ArchitectureOverview.md)
is the top-level map for module boundaries, runtime ownership, and transport
flow. Core-specific model notes are rooted at the
[`WebInspectorCore README`](Sources/WebInspectorCore/README.md), which links to
the detailed DOM, CSS, Network, and transport research docs kept next to the
Core target.

## License

See [LICENSE](LICENSE).
