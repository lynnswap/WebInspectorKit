# WebInspectorKit

[English README](README.md)

![WebInspectorKit preview](WebInspectorKit/Resources/preview.webp)

`WKWebView`（iOS / macOS）向けの Web Inspector です。

## 製品

- `WebInspectorKit`: コンテナ UI、ペイン記述子、Observation ベースの状態管理
- `WebInspectorKitCore`（Core）: DOM/Network エンジン、ランタイム actor、同梱 inspector script

`WebInspectorKit` は `WebInspectorKitCore` に依存します。

## 機能

- DOM ツリーの参照（要素ピック、ハイライト、削除、属性編集）
- Network リクエストログ（fetch/XHR/WebSocket）と、buffering/active モード切り替え
- `WIPaneDescriptor` によるペイン構成のカスタマイズ
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
    private let inspector = WISessionController()

    @objc private func presentInspector() {
        let container = WIContainerViewController(
            inspector,
            webView: pageWebView,
            tabs: [.dom(), .element(), .network()]
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

### AppKit

```swift
import AppKit
import WebKit
import WebInspectorKit

final class BrowserWindowController: NSWindowController {
    let pageWebView = WKWebView(frame: .zero)
    let inspector = WISessionController()

    @objc func presentInspector() {
        let container = WIContainerViewController(
            inspector,
            webView: pageWebView,
            tabs: [.dom(), .element(), .network()]
        )
        let inspectorWindow = NSWindow(contentViewController: container)
        inspectorWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        inspectorWindow.title = "Web Inspector"
        inspectorWindow.setContentSize(NSSize(width: 960, height: 720))
        inspectorWindow.makeKeyAndOrderFront(nil)
    }
}
```

## カスタムペイン

```swift
let customPane = WIPaneDescriptor(
    id: "my_custom_pane",
    title: "Custom",
    systemImage: "folder",
    role: .other
) { context in
    #if canImport(UIKit)
    return UIViewController()
    #else
    return NSViewController()
    #endif
}

let container = WIContainerViewController(
    inspector,
    webView: pageWebView,
    tabs: [.dom(), .element(), .network(), customPane]
)
```

## 移行

破壊的変更の詳細は [`MIGRATION.md`](MIGRATION.md) を参照してください。

## テスト

リポジトリルートで `xcodebuild` を実行します。macOS と iOS Simulator の両方のテストを実行してください。

```bash
# macOS: Package tests (Core)
xcodebuild -workspace WebInspectorKit.xcworkspace \
  -scheme WebInspectorKitCoreTests \
  -destination 'platform=macOS' \
  test

# macOS: Package tests (Feature)
xcodebuild -workspace WebInspectorKit.xcworkspace \
  -scheme WebInspectorKitFeatureTests \
  -destination 'platform=macOS' \
  test

# iOS Simulator: Package tests (Core)
xcodebuild -workspace WebInspectorKit.xcworkspace \
  -scheme WebInspectorKitCoreTests \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  test

# iOS Simulator: Package tests (Feature)
xcodebuild -workspace WebInspectorKit.xcworkspace \
  -scheme WebInspectorKitFeatureTests \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  test
```

手元に destination がない場合は、次で利用可能な Simulator を確認してください。

```bash
xcrun simctl list devices available
```

TypeScript テスト（Vitest）はリポジトリルートで次を実行してください。

```bash
pnpm -s run test:ts
pnpm -s run typecheck:ts
```

## ライセンス

[LICENSE](LICENSE) を参照してください。
