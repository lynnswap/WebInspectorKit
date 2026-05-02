# WebInspectorKit

[English README](README.md)

![WebInspectorKit preview](Resources/preview.webp)

`WKWebView`（iOS / macOS）向けの Web Inspector です。

## 製品

- `WebInspectorKit`: V2 UIKit コンテナ UI、`V2_WITab` ベースのタブ構成、Observation ベースの状態管理
- `WebInspectorEngine`: DOM/Network エンジン、ランタイム actor、同梱 inspector script

`WebInspectorKit` は `WebInspectorEngine` に依存します。

## 機能

- DOM ツリーの参照（要素ピック、ハイライト、削除、属性編集）
- Network リクエストログ（fetch/XHR/WebSocket）と、buffering/active モード切り替え
- `V2_WITab` による V2 タブ構成のカスタマイズ
- `V2_WISession` / `V2_WIViewController` による明示的ライフサイクル（`attach(to:)`, `detach()`）
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
        let inspector = V2_WIViewController()
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

### AppKit

V2 UI は現時点では UIKit のみです。AppKit の `WIInspectorController` / `WITabViewController`
入口は互換用に残っていますが、推奨アーキテクチャではなく、V2 安定後に削除予定です。

```swift
import AppKit
import WebKit
import WebInspectorKit

final class BrowserWindowController: NSWindowController {
    let pageWebView = WKWebView(frame: .zero)
    let inspector = WIInspectorController()

    @objc func presentInspector() {
        let container = WITabViewController(
            inspector,
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
let customTab = V2_WITab.custom(
    id: "my_custom_tab",
    title: "Custom",
    systemImage: "folder"
) { context in
    _ = context.runtime
    return UIViewController()
}

let inspector = V2_WIViewController(
    tabs: [.dom, .network, customTab]
)
```

## 依存性注入

値だけの設定は `WIModelConfiguration` に残し、副作用を持つ runtime 境界は
`WIInspectorDependencies` で注入します。

```swift
let dependencies = WIInspectorDependencies.testing {
    $0.network = WIInspectorNetworkClient(
        networkAgentScript: { "" }
    )
}

let inspector = V2_WIViewController(
    configuration: WIModelConfiguration(),
    dependencies: dependencies,
    tabs: [.dom, .network]
)
```

## 移行

破壊的変更の詳細は [`MIGRATION.md`](Docs/MIGRATION.md) を参照してください。

## コントリビュータ向け運用

- Swift package の利用者に `node` / `pnpm` / `esbuild` は不要です。
- `Sources/WebInspectorScripts/TypeScript`、`Plugins/WebInspectorKitObfuscatePlugin/ObfuscateJS/obfuscate.js`、`Plugins/WebInspectorKitObfuscatePlugin/ObfuscateJS/obfuscate.config.json` を変更したら `./Scripts/generate-bundled-js.sh` を実行してください。
- `./Scripts/generate-bundled-js.sh` は毎回 `Plugins/WebInspectorKitObfuscatePlugin/ObfuscateJS` を `pnpm install --frozen-lockfile` で同期し、その後 `Generated/WebInspectorScriptsGenerated/CommittedBundledJavaScriptData.swift` を更新します。
- TypeScript の `.test.ts` は `Sources/WebInspectorScripts/TypeScript/Tests` に残し、pnpm/vitest harness だけを `Tools/WebInspectorScriptsTypeScriptTests` に置いて、`node_modules` が `Sources/` 配下に生えないようにしています。
- TypeScript や tooling の変更と、再生成された `CommittedBundledJavaScriptData.swift` は同じコミットに含めてください。

## ライセンス

[LICENSE](LICENSE) を参照してください。
