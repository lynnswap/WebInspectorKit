# WebInspectorKit

[日本語版 README](README.ja.md)

![WebInspectorKit preview](Resources/preview.webp)

Web Inspector for `WKWebView` (iOS / macOS).

> This package relies on undocumented APIs and runtime behavior, so extra care is needed before using it in App Store-bound projects.

## Products

- `WebInspectorKit`: Container UI, `WITab`-based tab composition, Observation state
- `WebInspectorEngine`: DOM/Network engines, runtime actors, bundled inspector scripts

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

## Migration

See [`MIGRATION.md`](Docs/MIGRATION.md) for details on breaking changes.

## Contributor Workflow

- Consumers of the Swift package do not need `node`, `pnpm`, or `esbuild`.
- If you change files under `Sources/WebInspectorScripts/TypeScript`, `Plugins/WebInspectorKitObfuscatePlugin/ObfuscateJS/obfuscate.js`, or `Plugins/WebInspectorKitObfuscatePlugin/ObfuscateJS/obfuscate.config.json`, run `./Scripts/generate-bundled-js.sh`.
- `./Scripts/generate-bundled-js.sh` syncs `Plugins/WebInspectorKitObfuscatePlugin/ObfuscateJS` with `pnpm install --frozen-lockfile`, then updates `Generated/WebInspectorScriptsGenerated/CommittedBundledJavaScriptData.swift`.
- TypeScript test files stay under `Sources/WebInspectorScripts/TypeScript/Tests`, while the pnpm/vitest harness lives under `Tools/WebInspectorScriptsTypeScriptTests`, so local `node_modules` does not end up under `Sources/`.
- Commit the TypeScript/tooling change and the regenerated `CommittedBundledJavaScriptData.swift` in the same commit.

## License

See [LICENSE](LICENSE).
