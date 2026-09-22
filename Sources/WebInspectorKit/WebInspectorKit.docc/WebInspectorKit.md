# ``WebInspectorKit``

UIKit Web Inspector components for presenting and extending the built-in inspector.

## Overview

Import `WebInspectorKit` to present the built-in UIKit inspector or add custom
UIKit tabs. The module declares the public UI entry points and provides the DOM
and Network panels, including request and response body previews.

Create a ``WebInspectorViewController``, attach it to a `WKWebView`, and present
it from your app UI:

```swift
import UIKit
import WebKit
import WebInspectorKit

final class BrowserViewController: UIViewController {
    private let webView = WKWebView(frame: .zero)

    @objc private func showInspector() {
        let inspector = WebInspectorViewController()
        inspector.modalPresentationStyle = .pageSheet

        Task { @MainActor in
            try await inspector.attach(to: webView)
            present(inspector, animated: true)
        }
    }
}
```

The default inspector includes DOM and Network tabs. Add a custom tab when your
app needs a UIKit panel that shares the same inspection session:

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

Use ``WebInspectorSession`` when you need explicit access to attachment
lifecycle, page style observation, or the DataKit context used by custom tabs.
For custom inspector UIs that do not use the built-in UIKit surface, start with
WebInspectorDataKit instead.

## Topics

### Presenting the Inspector

- ``WebInspectorViewController``
- ``WebInspectorSession``

### Configuring Tabs

- ``WebInspectorTab``
