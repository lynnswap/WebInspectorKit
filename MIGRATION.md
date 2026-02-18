# MIGRATION (Next Release)

このリリースは**破壊的変更**です。互換レイヤは提供しません。  
product 名 (`WebInspectorKitCore` / `WebInspectorKit`) は維持されます。

## 1. 破壊的変更一覧

- `WebInspector.*` 名前空間を廃止（トップレベル公開型へ移行）。
- 旧 `SessionController` / `InspectorPaneDescriptor` / `InspectorPaneContext` / `ContainerViewController` / `SheetPresenter` / `WindowPresenter` を削除。
- 旧 `DOMPaneModel` / `NetworkPaneModel` / `InspectorStore` を削除。
- Runtime 公開型を `WIRuntimeActor` / `WIDOMRuntimeActor` / `WINetworkRuntimeActor` に刷新。
- Runtime 通信契約を `WISessionCommand` / `AsyncStream<WISessionEvent>` に統一。
- State は `@MainActor @Observable WISessionStore` + `WISessionViewState` へ統合。

## 2. 旧 -> 新 対応表

| 旧 | 新 |
|---|---|
| `WebInspector.SessionController` | `WISessionController` |
| `WebInspector.InspectorPaneDescriptor` | `WIPaneDescriptor` |
| `WebInspector.InspectorPaneContext` | `WIPaneContext` |
| `WebInspector.DOMPaneModel` | `WIDOMPaneViewModel` |
| `WebInspector.NetworkPaneModel` | `WINetworkPaneViewModel` |
| `WebInspector.InspectorStore` | `WISessionStore` |
| `InspectorRuntimeActor` | `WIRuntimeActor` |
| `DOMRuntimeActor` | `WIDOMRuntimeActor` |
| `NetworkRuntimeActor` | `WINetworkRuntimeActor` |
| `WebInspector.ContainerViewController` | `WIContainerViewController` |
| `WebInspector.SheetPresenter` | `WISheetPresenter` |
| `WebInspector.WindowPresenter` | `WIWindowPresenter` |
| `WebInspector.Configuration` | `WIConfiguration` |

## 3. attach/detach とイベント購読フロー

1. `WISessionController.connect(to:)` / `suspend()` / `disconnect()` を呼ぶ。
2. Controller は `WISessionCommand` を `WIRuntimeActor` へ dispatch する。
3. Runtime は `WISessionEvent.stateChanged(WISessionViewState)` を `AsyncStream` へ発行。
4. `WISessionStore.bind(to:)` が event stream だけで状態を再構築する。
5. UI は `WISessionStore.viewState` を読むだけで表示更新する。

## 4. DOM/Network 置換コード例

### 旧

```swift
let inspector = WebInspector.SessionController()
WebInspector.SheetPresenter.shared.present(
    from: presenter,
    inspector: inspector,
    webView: webView,
    tabs: [.dom(), .element(), .network()]
)
```

### 新

```swift
let inspector = WISessionController()
WISheetPresenter.shared.present(
    from: presenter,
    inspector: inspector,
    webView: webView,
    tabs: [.dom(), .element(), .network()]
)
```

### カスタムタブ

```swift
let custom = WIPaneDescriptor(
    id: "my_custom_tab",
    title: "Custom",
    systemImage: "folder",
    role: .other
) { _ in
    #if canImport(UIKit)
    return UIViewController()
    #else
    return NSViewController()
    #endif
}
```

## 5. Strict Concurrency で出やすい典型エラー

- `non-Sendable` 境界エラー:
  - Cross-actor で渡す型を `Sendable` にする。
  - UI専用参照型は `@MainActor` に閉じる。
- MainActor 境界エラー:
  - UI状態は `@MainActor`、実行制御は actor 側に分離する。
- fire-and-forget の競合:
  - `Task {}` 乱立を避け、`WIRuntimeActor.dispatch(_:)` に集約する。
- JSON payload デコード不正:
  - `[String: Any]` に依存せず `Codable` で decode し、recoverable error event に変換する。

## 備考

- MiniBrowser は Observation + async に統一され、Combine 依存を除去しています。
- `SWIFT_STRICT_CONCURRENCY = complete` 前提で動作します。
