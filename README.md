# WebInspectorKit

[日本語版 README](README.ja.md)

![WebInspectorKit preview](WebInspectorKit/Resources/preview.webp)

Web Inspector for `WKWebView` (iOS / macOS).

## Products

- `WebInspectorKit`: Container UI, pane descriptors, Observation state
- `WebInspectorKitCore` (Core): DOM/Network engines, runtime actors, bundled inspector scripts

`WebInspectorKit` depends on `WebInspectorKitCore`.

## Features

- DOM tree browsing (element picking, highlights, deletion, attribute editing)
- Network request logging (fetch/XHR/WebSocket) with buffering/active mode switching
- Configurable panes via `WIPaneDescriptor`
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
            tabs: [.dom(), .element(), .network()]
        )
        container.modalPresentationStyle = .pageSheet
        if let sheet = container.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .medium
            sheet.prefersGrabberVisible = true
        }
        present(container, animated: true)
    }
}
```

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
            tabs: [.dom(), .element(), .network()]
        )
        let inspectorWindow = NSWindow(contentViewController: container)
        inspectorWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        inspectorWindow.title = "Web Inspector"
        inspectorWindow.setContentSize(NSSize(width: 960, height: 720))
        inspectorWindow.makeKeyAndOrderFront(nil)
    }
}
```

## Custom Pane

```swift
let customPane = WIPaneDescriptor(
    id: "my_custom_pane",
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
    tabs: [.dom(), .element(), .network(), customPane]
)
```

## Migration

See [`MIGRATION.md`](MIGRATION.md) for details on breaking changes.

## Testing

Run tests with `xcodebuild` from the repository root. Execute both macOS and iOS Simulator test suites.

```bash
# macOS: Package tests
xcodebuild -workspace WebInspectorKit.xcworkspace \
  -scheme WebInspectorKitTests \
  -destination 'platform=macOS' \
  test

# iOS Simulator: Package tests
xcodebuild -workspace WebInspectorKit.xcworkspace \
  -scheme WebInspectorKitTests \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  test
```

If the destination does not exist on your machine, check available simulators with:

```bash
xcrun simctl list devices available
```

Run TypeScript tests (Vitest) from the repository root:

```bash
pnpm -s run test:ts
pnpm -s run typecheck:ts
```

## License

See [LICENSE](LICENSE).
