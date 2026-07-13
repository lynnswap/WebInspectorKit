# WebInspectorKit

![WebInspectorKit preview](Resources/preview.webp)

UIKit Web Inspector for `WKWebView`.

> [!WARNING]
> This package relies on undocumented APIs and runtime behavior, so extra care is needed before using it in App Store-bound projects.

## Features

- DOM tree browsing
- Network request logging
- Built-in DOM and Network tabs

## Requirements

- Swift 6.3+
- iOS 18.4+ for the built-in UIKit inspector
- iOS 18.4+ or macOS 15.4+ for ProxyKit, DataKit, and the native bridge
- ARM64/ARM64e Apple runtime; Intel Mac / x86_64 simulator environments are not
  supported.

## Platform Notes

- The current implementation targets UIKit on iOS.
- AppKit support is planned to be rebuilt separately.

## Products

| Product | Use when |
| --- | --- |
| `WebInspectorKit` | You want the built-in UIKit inspector UI. |
| `WebInspectorDataKit` | You want observable DOM, Network, Console, Runtime, and CSS models for a custom UI. |
| `WebInspectorDataKitTesting` | You want a ready DataKit model scenario with raw replay, target replacement, and attachment-failure controls. |
| `WebInspectorProxyKit` | You want typed Web Inspector protocol commands and events directly over an inspected `WKWebView`. |
| `WebInspectorProxyKitTesting` | You want to drive ProxyKit's production connection path from a concrete raw WebKit peer in tests. |

## Quick Start

### UIKit

```swift
import UIKit
import WebKit
import WebInspectorKit

final class BrowserViewController: UIViewController {
    private let pageWebView = WKWebView(frame: .zero)

    @objc private func presentInspector() {
        let inspector = WebInspectorViewController()
        inspector.modalPresentationStyle = .pageSheet
        if let sheet = inspector.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .medium
        }
        Task { @MainActor in
            try await inspector.attach(to: pageWebView)
            present(inspector, animated: true)
        }
    }
}
```

## Tabs

```swift
let inspector = WebInspectorViewController(
    tabs: [.dom, .network]
)
```

The built-in tab surface exposes DOM and Network tabs. Apps can also add UIKit
tabs with an asynchronous `UIViewController` factory:

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

## Testing the Raw Wire

`WebInspectorProxyKitTesting` attaches a concrete ``WebInspectorTestPeer``
below ProxyKit's real connection core. Commands still pass through the
production target registry, router, JSON codecs, model feed, and authority
checks. Tests receive raw commands in transport FIFO order and must complete
each command exactly once:

```swift
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

let runtime = try await WebInspectorProxyTestRuntime.start()

let reload = Task {
    try await runtime.page.page.reload()
}

let command = try await runtime.peer.commands.next()
precondition(command.method == "Page.reload")
try await runtime.peer.reply(to: command)
try await reload.value

await runtime.close()
```

Use `WebInspectorTestJSONObject` for raw `params` and result objects, and use
the peer's target lifecycle and event methods when a test needs inbound WebKit
traffic. The testing product does not provide a semantic backend or synthetic
model-state injection path.

## Testing DataKit Models

`WebInspectorDataKitTesting` composes the raw peer into model-level scenarios.
It answers only the protocol bootstrap owned by the scenario; replay and target
replacement still traverse ProxyKit's production connection core:

```swift
import WebInspectorDataKit
import WebInspectorDataKitTesting

let runtime = try await WebInspectorDataKitTestRuntime.start(
    scenario: .init(
        document: .init(children: [
            .element(id: "button", name: "button")
        ]),
        networkReplay: [
            .init(id: "initial-request", url: "https://example.test/")
        ]
    )
)

let nodes = try await WebInspectorFetchedResultsController<DOMNode, Never>(
    modelContext: runtime.model
)
precondition(nodes.snapshot.itemIDs.contains { id in
    runtime.model.model(for: id)?.localName == "button"
})
await nodes.close()
await runtime.close()
```

## Documentation

The DocC workflow publishes [package documentation](https://lynnswap.github.io/WebInspectorKit/documentation/)
to GitHub Pages.

| Document | Purpose |
| --- | --- |
| [Model Architecture](Docs/WebInspectorModelArchitecture.md) | Container, context-local identity, generic query, and snapshot/delta contracts. |
| [Migration Guide](Docs/MIGRATION.md) | Version-by-version source migration notes for app code. |
| [WebInspectorUI](Sources/WebInspectorUI/README.md) | UIKit inspector implementation notes and UI/DataKit ownership boundaries. |
| [WebKit Version Mapping](Docs/WebKitVersionMapping.md) | Local notes for mapping iOS WebKit framework versions to public WebKit source refs. |

## Project Structure

```text
Sources/
  WebInspectorKit/             Public built-in inspector product.
  WebInspectorDataKit/         Observable inspector model product.
  WebInspectorDataKitTesting/  Ready production-path DataKit test scenarios.
  WebInspectorProxyKit/        Typed protocol proxy product.
  WebInspectorProxyKitTesting/ Production-path raw peer test runtime.
  WebInspectorUI*/             Internal UIKit implementation targets.
Packages/
  WebInspectorNativeBridge/    Local native bridge package for ProxyKit internals.
Docs/
  MIGRATION.md                 Version-by-version migration notes.
  WebKitVersionMapping.md      WebKit runtime/source mapping notes.
```

## License

See [LICENSE](LICENSE).
