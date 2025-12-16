# WebInspectorKit

![WebInspectorKit preview](Resources/preview.webp)

iOS-ready Web inspector, SwiftUI-friendly and easy to add.

## Features
- DOM tree browsing with selection highlights and node deletion
- Attribute editing/removal plus copying HTML, CSS selector, and XPath
- Configurable tabs via a SwiftUI-style result builder (DOM and Detail tabs included)
- Dedicated view models for DOM / Detail / Network views so each view can run standalone
- Network tab for fetch/XHR requests with recording/clearing controls (status, headers, timing)
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
                    WebInspectorView(inspector, webView: pageWebView)
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
    WITab("Custom", systemImage: "folder") {
        NavigationStack{
            List {
                Text("Custom tab content")
            }
        }
    }
}
```

## How it works
- `DOMAgent.js` is injected into the page WKWebView to stream DOM snapshots and mutation bundles.
- `NetworkAgent.js` observes network activity in the inspected page when recording is enabled.

## Limitations
- WKWebView only; JavaScript must be enabled.
- Console features are not implemented.
- Documentation is in progress; fuller docs are coming soon.

## Apps Using

<p float="left">
    <a href="https://apps.apple.com/jp/app/tweetpd/id1671411031"><img src="https://i.imgur.com/AC6eGdx.png" width="65" height="65"></a>
</p>

## License
See [LICENSE](LICENSE).
