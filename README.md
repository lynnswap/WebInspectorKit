# WebInspectorKit

![WebInspectorKit preview](Resources/preview.webp)

SwiftUI-first Web Inspector for `WKWebView` (iOS / macOS).

## Products

- `WebInspectorKit` (UI): SwiftUI panel + tab container + DOMTreeView frontend assets.
- `WebInspectorKitCore` (Core): DOM/Network engines + bundled inspector scripts (no SwiftUI).

`WebInspectorKit` depends on `WebInspectorKitCore`. There is no compatibility layer; expect breaking API changes.

## Features

- DOM tree browsing (WebView frontend) with element picking, highlights, deletion, and attribute editing
- Network request logging (fetch/XHR/WebSocket) with buffering when the Network tab is not selected
- Configurable tabs via `WebInspector.Tab` + `WebInspector.TabBuilder`
- Explicit lifecycle via `WebInspector.Controller` (`connect(to:)`, `suspend()`, `disconnect()`)
  - `WebInspector.Panel` wires this up automatically for SwiftUI

This repository is under active development, and future updates may introduce major changes to the API or behavior.

## Requirements

- Swift 6.2+
- iOS 18 / macOS 15+
- WKWebView with JavaScript enabled

## Installation

Add this repository as a Swift Package dependency in Xcode (Package Dependencies).
Choose one or both products depending on your use case:

- `WebInspectorKit` (recommended for most apps)
- `WebInspectorKitCore` (headless / custom UI)

## Quick Start (Inspect an Existing WKWebView)

```swift
import SwiftUI
import WebKit
import WebInspectorKit

struct ContentView: View {
    @State private var inspector = WebInspector.Controller()
    @State private var isInspectorPresented = false

    let pageWebView: WKWebView // your app's WKWebView that renders the page

    var body: some View {
        NavigationStack {
            YourPageView(webView: pageWebView) // your page UI that hosts the WKWebView
                .sheet(isPresented: $isInspectorPresented) {
                    WebInspector.Panel(inspector, webView: pageWebView)
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

For a working example, see `Tools/MiniBrowser`.

## Customize Tabs

```swift
WebInspector.Panel(inspector, webView: pageWebView) {
    WebInspector.Tab.dom()
    WebInspector.Tab.element()

    WebInspector.Tab(LocalizedStringResource("Custom"), systemImage: "folder") { _ in
        NavigationStack {
            List {
                Text("Custom tab content")
            }
        }
    }
}
```

Tip: If you omit the Network tab (`WebInspector.Tab.network()`), network scripts are never installed.

## How It Works

- `DOMAgent` is injected into the inspected page to stream DOM snapshots and mutation bundles.
- `NetworkAgent` observes network activity in the inspected page.
  - When the Network tab is not selected, the agent buffers; selecting the tab switches it to active logging.

## Limitations

- WKWebView only; JavaScript must be enabled.
- Console features are not implemented.

## Apps Using

<p float="left">
    <a href="https://apps.apple.com/jp/app/tweetpd/id1671411031"><img src="https://i.imgur.com/AC6eGdx.png" width="65" height="65"></a>
</p>

## License

See [LICENSE](LICENSE).

