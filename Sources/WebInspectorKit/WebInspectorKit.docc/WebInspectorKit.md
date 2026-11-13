# ``WebInspectorKit``

UIKit Web Inspector components for presenting and extending the built-in inspector.

## Overview

Import `WebInspectorKit` to present the built-in UIKit inspector or add custom
UIKit tabs. The module declares the public UI entry points and provides the DOM
and Network panels, including request and response body previews.

Create a ``WebInspectorViewController``, attach its inspector to a `WKWebView`,
and present it from your app UI:

```swift
import UIKit
import WebKit
import WebInspectorKit

final class BrowserViewController: UIViewController {
    private let webView = WKWebView(frame: .zero)

    @objc private func showInspector() {
        let controller = WebInspectorViewController()
        controller.modalPresentationStyle = .pageSheet
        controller.inspector.attach(to: webView)
        present(controller, animated: true)
    }
}
```

`WebInspector/attach(to:configuration:)` returns immediately. Call it again to
inspect another web view. The view controller detaches its inspector when it is
dismissed unless ``WebInspectorViewController/automaticallyDetachesOnDismiss``
is `false`.

The default inspector includes DOM and Network tabs. Add a custom tab when your
app needs a UIKit panel that reads the same inspector:

```swift
let consoleTab = WebInspectorTab(
    id: "app_console",
    title: "Console",
    systemImage: "terminal"
) { inspector in
    ConsoleViewController(messages: inspector.console)
}

let controller = WebInspectorViewController(
    tabs: [.dom, .network, consoleTab]
)
```

The module re-exports WebInspectorDataKit, so `WebInspector` and its models are
available with `import WebInspectorKit`. For custom inspector UIs that do not
use the built-in UIKit surface, import WebInspectorDataKit alone.

## Topics

### Presenting the Inspector

- ``WebInspectorViewController``

### Configuring Tabs

- ``WebInspectorTab``
