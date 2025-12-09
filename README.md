# WebInspectorKit

![WebInspectorKit preview](Resources/preview.webp)

iOS-ready Web inspector, SwiftUI-friendly and easy to add.

## Features
- DOM tree browsing with selection highlights and node deletion
- Attribute editing/removal plus copying HTML, CSS selector, and XPath
- Configurable tabs via a SwiftUI-style result builder (DOM and Detail tabs included)
- Dedicated view models for DOM / Detail / Network views so each view can run standalone
- Network tab for fetch/XHR requests (status, headers, timing)
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

## Inspect an existing WKWebView
```swift
struct ContentView: View {
    @State private var inspector = WebInspectorModel()
    @State private var isInspectorPresented = false
    let pageWebView: WKWebView // your app's WKWebView that renders the page

    var body: some View {
        NavigationStack {
            YourPageView(webView: pageWebView) // your page UI that hosts the WKWebView
                .sheet(isPresented: $isInspectorPresented) {
                    NavigationStack {
                        WebInspectorView(inspector, webView: pageWebView)
                    }
                    .presentationDetents([.medium, .large])
                }
                .toolbar {
                    Button("Inspect page") {
                        isInspectorPresented = true
                    }
                }
        }
    }
}

```
For a more complete preview setup, see [`Sources/WebInspectorKit/WebInspector/Views/WebInspectorView.swift`](Sources/WebInspectorKit/WebInspector/Views/WebInspectorView.swift) (`#Preview`).

## Customize tabs
```swift
WebInspectorView(inspector, webView: pageWebView) {
    WITab.dom()
    WITab.element()
    WITab("Custom", systemImage: "folder") { _ in
        List{
            Text("Custom tab content")
        }
    }
}
```

## Configuration (snapshot depth, subtree depth, debounce)
```swift
let config = WebInspectorConfiguration(
    snapshotDepth: 6,       // max depth for initial/full snapshots
    subtreeDepth: 4,        // depth for child subtree requests
    autoUpdateDebounce: 0.8 // seconds for automatic snapshot debounce
)
let inspector = WebInspectorModel(configuration: config)
```
If selection mode requires deeper nodes, the inspector automatically raises `snapshotDepth` and reloads while preserving state.

## Key APIs and behavior
- Lifecycle is handled inside `WebInspectorView` (`attach`, `suspend`, `detach` on appear/disappear).
- `dom.toggleSelectionMode()` starts/stops element selection with page highlighting.
- `dom.reloadInspector()` refreshes the DOM snapshot using the current `snapshotDepth`.
- `dom.copySelection(_:)` copies HTML, selectorPath, or XPath for the selected node.
- `dom.deleteSelectedNode()` removes the selected DOM node.
- Attribute editing uses `dom.updateAttributeValue` / `dom.removeAttribute`.
- Network capture uses `network.setRecording(_:)` and `network.clearNetworkLogs()`.
- Auto-updates are managed internally using `autoUpdateDebounce`.

## How it works
- `DOMAgent.js` is injected into the page WKWebView to stream DOM snapshots and mutation bundles.
- `NetworkAgent.js` observes network activity in the inspected page when recording is enabled.
- The inspector UI uses bundled HTML/CSS/JS assets resolved via `WIAssets` and rendered in a dedicated inspector WebView.

## Limitations
- WKWebView only; JavaScript must be enabled.
- For very large DOMs, tune `snapshotDepth` and `autoUpdateDebounce` to balance performance.
- Network and console features are not implemented.

## Apps Using

<p float="left">
    <a href="https://apps.apple.com/jp/app/tweetpd/id1671411031"><img src="https://i.imgur.com/AC6eGdx.png" width="65" height="65"></a>
</p>

## License
See [LICENSE](LICENSE).
