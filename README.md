# WebInspectorKit

![WebInspectorKit preview](Resources/preview.webp)

SwiftUI inspector for WKWebView that captures DOM snapshots, renders a dedicated inspector UI, and lets you inspect and edit nodes.

## Features
- DOM tree browsing with selection highlights and node deletion
- Attribute editing/removal plus copying HTML, CSS selector, and XPath
- Configurable tabs via a SwiftUI-style result builder (DOM and Detail tabs included)
- Automatic DOM snapshot reloads with debounce and adjustable depth
- Selection mode toggle to start/stop element picking and highlighting
- Lifecycle handled by `WebInspectorView` (`attach`, `suspend`, `detach`)
- Lightweight: SwiftUI and WebKit only, no extra dependencies

This repository is under active development, and future updates may introduce major changes to the API or behavior.

## Requirements
- Swift 6.2+
- iOS 18 / macOS 15+
- WKWebView with JavaScript enabled

## Installation
Add WebInspectorKit as a Swift Package dependency in Xcode (Package Dependencies). Use a local path or your repository URL as appropriate.

## Quickstart (default DOM + Detail tabs)
```swift
import SwiftUI
import WebKit
import WebInspectorKit

struct ContentView: View {
    @State private var inspector = WebInspectorModel()
    @State private var pageWebView: WKWebView = {
        let config = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: config)
        view.load(URLRequest(url: URL(string: "https://www.example.com")!))
        return view
    }()

    var body: some View {
        NavigationStack {
            WebInspectorView(inspector, webView: pageWebView)
                .navigationTitle("Inspector")
        }
    }
}
```

## Customize tabs
```swift
WebInspectorView(inspector, webView: pageWebView) {
    WITab.dom()
    WITab.detail()
    WITab("Network", systemImage: "wave.3.right.circle") {
        NetworkInspectorView()  // your custom tab content
    }
}
```

## Configuration (snapshot depth, subtree depth, debounce)
```swift
let config = WebInspectorModel.Configuration(
    snapshotDepth: 6,       // max depth for initial/full snapshots
    subtreeDepth: 4,        // depth for child subtree requests
    autoUpdateDebounce: 0.8 // seconds for automatic snapshot debounce
)
let inspector = WebInspectorModel(configuration: config)
```
If selection mode requires deeper nodes, the inspector automatically raises `snapshotDepth` and reloads while preserving state.

## Key APIs and behavior
- Lifecycle is handled inside `WebInspectorView` (`attach`, `suspend`, `detach` on appear/disappear).
- `toggleSelectionMode()` starts/stops element selection with page highlighting.
- `reload()` refreshes the DOM snapshot using the current `snapshotDepth`.
- `copySelection(_:)` copies HTML, selectorPath, or XPath for the selected node.
- `deleteSelectedNode()` removes the selected DOM node.
- Attribute editing uses `updateAttributeValue` / `removeAttribute`.
- Auto-updates are managed internally using `autoUpdateDebounce`.

## How it works
- `InspectorAgent.js` is injected into the page WKWebView to stream DOM snapshots and mutation bundles.
- The inspector UI uses bundled HTML/CSS/JS assets resolved via `WIAssets` and rendered in a dedicated inspector WebView.

## Limitations
- WKWebView only; JavaScript must be enabled.
- For very large DOMs, tune `snapshotDepth` and `autoUpdateDebounce` to balance performance.
- Network and console features are not implemented.

## License
See [LICENSE](LICENSE).
