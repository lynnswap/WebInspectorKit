# WebInspectorKit

![WebInspectorKit preview](Resources/preview.webp)

UIKit Web Inspector for `WKWebView`.

## Features

- DOM tree browsing with native UIKit/TextKit2 presentation
- Network request logging with native list/detail presentation
- Built-in DOM and Network tabs
- Explicit lifecycle via `WebInspectorSession` / `WebInspectorViewController` (`attach(to:)`, `detach()`)
- Observation-backed V2 model state

## Requirements

- Swift 6.2+
- iOS 18+
- WKWebView with JavaScript enabled

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

## Migration

See [`MIGRATION.md`](Docs/MIGRATION.md) for details on breaking changes.

## Contributor Workflow

- Consumers of the Swift package do not need `node`, `pnpm`, or `esbuild`.
- The DOM tree inspector UI is native UIKit/TextKit2. There is no bundled JavaScript DOM tree frontend or generated script regeneration step.
- For internal V2 architecture notes, see [`V2ArchitectureOverview.md`](Docs/V2ArchitectureOverview.md).

## License

See [LICENSE](LICENSE).
