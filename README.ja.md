# WebInspectorKit

[English README](README.md)

![WebInspectorKit preview](Resources/preview.webp)

`WKWebView`（iOS / macOS）向けの Web Inspector です。

## 製品

- `WebInspectorKit`: 唯一の public product です。session controller、typed panel model、DOM/Network store、コンテナ UI を再公開します。

## 機能

- DOM ツリーの参照（要素ピック、ハイライト、削除、属性編集）
- Network リクエストログ（fetch/XHR/WebSocket）と、buffering/active モード切り替え
- `WITab` によるタブ構成のカスタマイズ（custom tab は `viewControllerProvider` を利用）
- `WISessionController` による明示的ライフサイクル（`connect(to:)`, `suspend()`, `disconnect()`）

## 要件

- Swift 6.2+
- iOS 18 / macOS 15+
- JavaScript が有効な WKWebView

## クイックスタート

### UIKit

```swift
import UIKit
import WebKit
import WebInspectorKit

final class BrowserViewController: UIViewController {
    private let pageWebView = WKWebView(frame: .zero)
    private let sessionController = WISessionController()

    @objc private func presentInspector() {
        let container = WIContainerViewController(
            sessionController,
            webView: pageWebView,
            tabs: [.dom(), .network()]
        )
        container.modalPresentationStyle = .pageSheet
        if let sheet = container.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .medium
            sheet.prefersGrabberVisible = true
        }
        present(container, animated: true)
    }
}
```

`WIContainerViewController` は iOS ではデフォルト `DOM + Network` です。

- `compact`（`horizontalSizeClass == .compact`）: `DOM` / `Element`（未指定時は自動追加）/ `Network`
- `regular/unspecified`（`horizontalSizeClass != .compact`）: `DOM`（DOM + Element の split）/ `Network`
- `regular/unspecified` では `wi_element` は常に `wi_dom` に統合され、独立タブとしては表示されません。
- `UISplitViewController` は `regular/unspecified` のみで利用します（`DOM` / `Network`）。`compact` は単一カラムのタブ遷移です。
- `compact` は `UITabBarController` ベースで、各タブ root は `UINavigationController` にラップされます。
- `regular/unspecified` は `UINavigationController` ベースで、中央の segmented control でタブ切り替えします。
- Network の検索/フィルタは UIKit 標準 API（`UISearchController` / `UIBarButtonItem` メニュー）を使用します。
- `WIContainerViewController` は `UIViewController` 継承です（`UITabBarController` 継承ではありません）。

### AppKit

```swift
import AppKit
import WebKit
import WebInspectorKit

final class BrowserWindowController: NSWindowController {
    let pageWebView = WKWebView(frame: .zero)
    let sessionController = WISessionController()

    @objc func presentInspector() {
        let container = WIContainerViewController(
            sessionController,
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

## カスタムタブ

```swift
let customTab = WITab(
    id: "my_custom_tab",
    title: "Custom",
    image: nil,
    role: .other
) { tab in
    _ = tab
    #if canImport(UIKit)
    return UIViewController()
    #else
    return NSViewController()
    #endif
}

let container = WIContainerViewController(
    sessionController,
    webView: pageWebView,
    tabs: [.dom(), .network(), customTab]
)
```

## テスト

- `swift test`
- `pnpm --dir Sources/WebInspectorResources/TypeScript/Tests run test`
- `pnpm --dir Sources/WebInspectorResources/TypeScript/Tests run typecheck`
- `xcodebuild -workspace WebInspectorKit.xcworkspace -scheme MiniBrowser -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' test`（MiniBrowser/UIランタイム連携に影響する変更時に実行）

## 移行

breaking change と target 再編の詳細は [`MIGRATION.md`](Docs/MIGRATION.md) を参照してください。

## ライセンス

[LICENSE](LICENSE) を参照してください。
