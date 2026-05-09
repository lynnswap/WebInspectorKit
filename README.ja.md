# WebInspectorKit

[English README](README.md)

![WebInspectorKit preview](Resources/preview.webp)

`WKWebView`（iOS / macOS）向けの Web Inspector です。

## 製品

- `WebInspectorKit`: UIKit コンテナ UI、`WITab` ベースのタブ構成、Observation ベースの状態管理
- `WebInspectorEngine`: DOM/Network エンジン、ランタイム actor、同梱 inspector script

`WebInspectorKit` は `WebInspectorEngine` に依存します。

## 機能

- DOM ツリーの参照（要素ピック、ハイライト、削除、属性編集）
- Network リクエストログ（fetch/XHR/WebSocket）と、buffering/active モード切り替え
- `WITab` によるタブ構成のカスタマイズ
- `WISession` / `WIViewController` による明示的ライフサイクル（`attach(to:)`, `detach()`）
- `WIInspectorDependencies` による依存性注入

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

    @objc private func presentInspector() {
        let inspector = WIViewController()
        inspector.modalPresentationStyle = .pageSheet
        if let sheet = inspector.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .medium
            sheet.prefersGrabberVisible = true
        }
        Task { @MainActor in
            await inspector.attach(to: pageWebView)
            present(inspector, animated: true)
        }
    }
}
```

## カスタムタブ

```swift
let customTab = WITab.custom(
    id: "my_custom_tab",
    title: "Custom",
    systemImage: "folder"
) { context in
    _ = context.runtime
    return UIViewController()
}

let inspector = WIViewController(
    tabs: [.dom, .network, customTab]
)
```

## 依存性注入

値だけの設定は `WIModelConfiguration` に残し、副作用を持つ runtime 境界は
`WIInspectorDependencies` で注入します。

```swift
let dependencies = WIInspectorDependencies.testing {
    $0.transport.configuration.responseTimeout = .milliseconds(250)
}

let inspector = WIViewController(
    configuration: WIModelConfiguration(),
    dependencies: dependencies,
    tabs: [.dom, .network]
)
```

## 移行

破壊的変更の詳細は [`MIGRATION.md`](Docs/MIGRATION.md) を参照してください。

## コントリビュータ向け運用

- Swift package の利用者に `node` / `pnpm` / `esbuild` は不要です。
- DOM ツリー inspector UI は UIKit/TextKit2 のネイティブ実装です。bundled JavaScript DOM tree frontend や生成スクリプトの再生成手順はありません。

## ライセンス

[LICENSE](LICENSE) を参照してください。
