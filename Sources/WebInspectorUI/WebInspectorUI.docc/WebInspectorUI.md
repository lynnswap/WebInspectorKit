# ``WebInspectorUI``

UIKit Web Inspector components for presenting and extending the built-in inspector.

## Overview

Use WebInspectorUI when you want to present the built-in UIKit inspector or add
UIKit tabs to the inspector surface. Application code normally imports
`WebInspectorKit`, which re-exports this module, but the symbols documented here
are the UI entry points behind that product.

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
    systemImage: "terminal",
    requiredDomains: [.console]
) { session in
    let messages = try await session.model.consoleMessages()
    return ConsoleViewController(messages: messages)
}

let inspector = WebInspectorViewController(
    tabs: [.dom, .network, consoleTab]
)
```

Use ``WebInspectorSession`` when you need explicit access to attachment
lifecycle, page style observation, or the stable DataKit model used by custom
tabs. Custom factories are asynchronous; the root inspector owns their
loading, failure, retry, cancellation, and controller reuse lifecycle.
For custom inspector UIs that do not use the built-in UIKit surface, start with
WebInspectorDataKit instead.

## Topics

### Presenting the Inspector

- ``WebInspectorViewController``
- ``WebInspectorSession``

### Configuring Tabs

- ``WebInspectorTab``
