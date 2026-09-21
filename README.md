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
- iOS 18.4+
- macOS 15.4+ for the non-UI products
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
| `WebInspectorDataKitTesting` | You want deterministic `WebInspectorContext` startup synchronization in tests. |
| `WebInspectorProxyKit` | You want typed Web Inspector protocol commands and events directly over an inspected `WKWebView`. |
| `WebInspectorProxyKitTesting` | You want a controllable proxy backend and protocol fixtures without the native WebKit bridge. |

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

Attaching to a loaded page populates Network with the page and frame resources
that WebKit still retains, then continues recording live requests. Restored
resources may have no HTTP status, headers, or timing information. This matches
Web Inspector's resource-tree snapshot; it does not recover every past request.
If the snapshot fails, `WebInspectorContext.networkResourceTreeError` reports
the failure while live Network recording continues.

## Tabs

```swift
let inspector = WebInspectorViewController(
    tabs: [.dom, .network]
)
```

The built-in tab surface exposes DOM and Network tabs. Apps can also add UIKit
tabs with a `UIViewController` factory:

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

## Testing against real WebKit

CI discovers installed iOS 18.4+ Simulator runtimes on the `macos-15`,
`macos-26`, and `xcode-27` runners, with coverage of the iOS 26 series starting
at 26.1. Each runtime runs the NativeBridge tests,
including native symbol resolution, string ABI round trips, and Inspector
protocol communication. The ProxyKit, DataKit, UI, full Monocly, and consumer
contract suites run only on the newest installed iOS runtime on `xcode-27`.
The ordinary suites have a separate job, which also runs the macOS consumer
contract suites and excludes the NativeBridge test target. Low-level coverage
uses one job per host environment; each builds NativeBridge once per platform
and tests its installed runtimes sequentially. The ordinary job also builds
and tests on the same runner, so no build products are transferred between jobs.
Each iOS case uses a fresh Simulator that is deleted afterward. A failed case
does not skip the remaining runtimes; per-OS logs and results are retained,
and any failure fails the job.
Runtimes absent from the runner images are not downloaded or covered.
The NativeBridge tests also exercise each runner's host macOS and WebKit.

The repository includes a self-authored, loopback-only integration site for
manual Monocly verification through a real `WKWebView` and WebKit protocol
backend. It combines a large DOM, mutation burst, iframe, shadow/pseudo nodes,
navigation, and representative Network traffic without third-party assets:

```sh
DEVICE_UDID=<booted-simulator-udid> Scripts/run-monocly-fixture.sh
```

See [Inspector Integration Fixture](Tools/InspectorFixture/README.md) for the
verification matrix and deterministic fixture regression test.

## Documentation

The DocC workflow publishes [package documentation](https://lynnswap.github.io/WebInspectorKit/documentation/)
to GitHub Pages.

| Document | Purpose |
| --- | --- |
| [Migration Guide](Docs/MIGRATION.md) | Version-by-version source migration notes for app code. |
| [WebInspectorUI](Sources/WebInspectorUI/README.md) | UIKit inspector implementation notes and UI/DataKit ownership boundaries. |
| [WebKit Version Mapping](Docs/WebKitVersionMapping.md) | Local notes for mapping iOS WebKit framework versions to public WebKit source refs. |

## Project Structure

```text
Sources/
  WebInspectorKit/             Public built-in inspector product.
  WebInspectorDataKit/         Observable inspector model product.
  WebInspectorDataKitTesting/  Deterministic DataKit consumer test helpers.
  WebInspectorProxyKit/        Typed protocol proxy product.
  WebInspectorProxyKitTesting/ Controllable proxy test runtime and fixtures.
  WebInspectorUI*/             Internal UIKit implementation targets.
Packages/
  WebInspectorNativeBridge/    Local native bridge package for ProxyKit internals.
Docs/
  MIGRATION.md                 Version-by-version migration notes.
  WebKitVersionMapping.md      WebKit runtime/source mapping notes.
```

## License

See [LICENSE](LICENSE).
