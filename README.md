# WebInspectorKit

[日本語版 README](README.ja.md)

![WebInspectorKit preview](Resources/preview.webp)

Web Inspector for `WKWebView` (iOS / macOS).

## Products

- `WebInspectorKit`: UIKit container UI, `WITab`-based tab composition, Observation state
- `WebInspectorEngine`: DOM/Network engines, runtime actors, bundled inspector scripts

`WebInspectorKit` depends on `WebInspectorEngine`.

## Features

- DOM tree browsing (element picking, highlights, deletion, attribute editing)
- Network request logging (fetch/XHR/WebSocket) with buffering/active mode switching
- Configurable tabs via `WITab`
- Explicit lifecycle via `WISession` / `WIViewController` (`attach(to:)`, `detach()`)
- Dependency injection via `WIInspectorDependencies`

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

    @objc private func presentInspector() {
        let inspector = WIViewController()
        inspector.modalPresentationStyle = .pageSheet
        if let sheet = inspector.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .medium
        }
        Task { @MainActor in
            await inspector.attach(to: pageWebView)
            present(inspector, animated: true)
        }
    }
}
```

## Custom Tab

```swift
let customTab = WITab.custom(
    id: "my_custom_tab",
    title: "Custom",
    systemImage: "folder"
) { context in
    _ = context.runtime
    return UIViewController()
}

let inspector = WIViewController(
    tabs: [.dom, .network, customTab]
)
```

## Dependency Injection

Keep value-only settings in `WIModelConfiguration`, and inject side-effectful runtime
boundaries through `WIInspectorDependencies`.

```swift
let dependencies = WIInspectorDependencies.testing {
    $0.transport.configuration.responseTimeout = .milliseconds(250)
}

let inspector = WIViewController(
    configuration: WIModelConfiguration(),
    dependencies: dependencies,
    tabs: [.dom, .network]
)
```

## Migration

See [`MIGRATION.md`](Docs/MIGRATION.md) for details on breaking changes.

## Contributor Workflow

- Consumers of the Swift package do not need `node`, `pnpm`, or `esbuild`.
- The DOM tree inspector UI is native UIKit/TextKit2. There is no bundled JavaScript DOM tree frontend or generated script regeneration step.
- For internal V2 architecture notes, see [`V2ArchitectureOverview.md`](Docs/V2ArchitectureOverview.md).

## License

See [LICENSE](LICENSE).
