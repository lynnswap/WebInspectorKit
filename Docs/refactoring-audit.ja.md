# WebInspectorKit リファクタリング監査

## 1. 前提

- 調査日: 2026-06-13
- 対象: `/Users/kn/Dev/WebInspectorKit`
- ブランチ: `main`
- 作業内容: 調査と資料作成のみ。コードのリファクタリングは未実施。
- Package 設定: Swift tools 6.2、`.swiftLanguageMode(.v6)`、`.defaultIsolation(nil)`、`.strictMemorySafety()`。
- repo-local 検証コマンド:

```sh
xcodebuild test \
  -workspace WebInspectorKit.xcworkspace \
  -scheme WebInspectorKit \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'
```

## 2. 現行の責務境界

既存ドキュメント上の境界は明確で、基本方針として維持する。

- `WebInspectorNativeBridge`: attach、raw JSON send/receive、detach。
- `WebInspectorTransport`: protocol envelope parse、target message unwrap、command routing、reply 管理、protocol target 追跡、execution-context owner/source target identity 維持。
- `WebInspectorCore`: domain bootstrap、event pump、domain handler dispatch、command intent、`@MainActor @Observable` semantic model。
- `WebInspectorUI`: UIKit/TextKit2 表示と操作。
- `WebInspectorKit`: app-facing umbrella product。`@_exported import WebInspectorUI` はこの用途に限れば現行設計と整合している。

`Sources/WebInspectorCore/README.md` は、mutable model を `@MainActor @Observable` に置き、raw transport I/O、target multiplexing、search/tokenization/markup generation は外に置く方針を明記している。この前提を崩すリファクタリングは避ける。

## 3. 根本原因クラスタ

### A. `TransportSession` が多責務 actor になっている

`Sources/WebInspectorTransport/TransportSession.swift` は actor 1 つで次を同時に保持している。

- command ID / sequence / subscribers
- root reply と target reply
- target registry と main page target waiter
- provisional target message buffer
- frame target map
- CSS stylesheet routing と pending resolved stylesheet event
- runtime execution context registry
- inbound message queue / drain

この actor 所有自体は妥当だが、actor 内の状態カテゴリが多すぎる。特に target commit、provisional buffer、reply retarget、stylesheet retarget、runtime context retarget が同じ関数群に混ざっており、順序変更の影響範囲が読みづらい。

推奨する直し方:

- actor は残し、内部状態を小さな値型/補助型に分ける。
- まず `TransportReplyStore`、`TransportTargetRegistry`、`TransportStyleSheetRouting`、`TransportInboundMessageQueue`、`RuntimeContextRegistry` のファイル分割から始める。
- helper は actor 外で非同期副作用を持たない pure mutation に寄せる。
- event emission と backend send の順序は `TransportSession` が引き続き制御する。

やってはいけないこと:

- actor をロックベース class に置き換えない。ここは raw message ordering と reply resolution の単一 owner であることが価値。
- provisional target buffer と timeout 特例を削除しない。commit 前 reply を buffer 済みの場合に timeout 解決しない挙動がある。
- target commit 後の buffered message dispatch を並列化しない。

### B. `InspectorSession` の接続状態が暗黙の状態機械になっている

`Sources/WebInspectorCore/Inspector/AttachedInspection.swift` の `InspectorSession` は `connection` と `pendingConnection`、`TransportReceiver`、`DomainEventPump`、target ごとの runtime/console enable task を組み合わせて attach/connect/detach を実現している。

現状の重要な不変条件:

- `connect` 中は `pendingConnection` を設定し、bootstrap 完了後に `connection` へ昇格する。
- error/cancel 時は pump 停止、transport detach、inspectability restore、domain model reset をまとめて行う。
- command result は `ProtocolCommandChannel` の `isCurrent` / `isAttached` で現行接続だけが反映される。
- `DomainEventPump` は ordered event を apply してから sequence waiter を解決する。

問題は、不変条件が enum phase ではなく複数 nullable state と task 群で表現されている点。今後の変更で pending/active/detaching の扱いがずれやすい。

推奨する直し方:

- `InspectorConnectionPhase` を導入し、`.idle`、`.pending(InspectorConnection)`、`.active(InspectorConnection)`、`.detaching(...)` 程度に状態を明示する。
- public/package API は維持し、内部で phase から `hasActiveConnection`、current connection、pending connection を導出する。
- runtime/console enable task は target state に残してよいが、開始/キャンセル/完了の遷移を phase と接続 identity に結びつける。
- `TransportReceiver: @unchecked Sendable` は、transport 設定前に届いた message を順序保持で drain するための型として不変条件をテスト化する。

やってはいけないこと:

- bootstrap command を安易に並列化しない。`Inspector.enable`、`Inspector.initialized`、`DOM.enable`、Runtime/Console/CSS/Network の順序に依存するテストが多い。
- connection identity check を削除しない。detach/reconnect 中の古い async result を捨てる防波堤になっている。

### C. Core の DOM owner が大きく、target lifecycle の意味が二重化している

`DOMSessionProtocolOperations.swift` は document request、element picker、style hydration、delete/undo queue、inspect event、frame owner hydration を 1 ファイルに抱えている。`DOMModel.swift` も observable model、CSS identity helper、selection、frame document projection、snapshot を含む大きな owner になっている。

また、target lifecycle は Transport と Core の両方に存在する。

- Transport: raw protocol routing のための `targetsByID`、`frameTargetIDsByFrameID`、commit/retarget。
- Core: semantic model のための `TargetGraph`、frame/document/execution context projection、commit/retarget。

これは単純な重複ではなく、raw routing と semantic projection の層が違う。ただし、どちらがどの意味を持つかがコード上だけでは追いづらい。

推奨する直し方:

- `DOMSessionProtocolOperations.swift` を owner 単位に分割する。
  - `DOMSession+DocumentRequests.swift`
  - `DOMSession+ElementPicker.swift`
  - `DOMSession+StyleHydration.swift`
  - `DOMSession+DeleteUndo.swift`
  - `DOMSession+FrameHydration.swift`
- `DOMModel.swift` は identity/types、TargetGraph、DocumentStore、Selection、FrameDocumentProjection、Snapshot に分ける。
- Transport の target record と Core の semantic target projection の境界を短い doc comment と専用テストで固定する。

やってはいけないこと:

- README の方針に反して cross-domain adapter bucket を作らない。
- iframe document を通常 DOM child に戻さない。
- redirect hop を top-level request identity にしない。

### D. test fake と test support が production target に入っている

`Sources/WebInspectorTransport/TransportBackend.swift` に `FakeTransportBackend` と `SentTargetMessage` が package API として入っている。実利用はほぼ `Tests/WebInspectorCoreTests/InspectorSessionTests.swift` と `Tests/WebInspectorTransportTests/TransportSessionTests.swift` に集中しており、production target の責務ではない。

推奨する直し方:

- `TransportBackend` protocol は production に残す。
- `FakeTransportBackend` と `SentTargetMessage` は test support 側へ移す。
- SwiftPM では複数 test target が共有できる `WebInspectorTestSupport` test helper target を検討する。
- その移動後、production `Sources` に test waiter / sent-message parser が混ざらないことを ArchitectureTests で固定する。

注意点:

- Core tests と Transport tests の両方が fake を共有しているため、単一 test file へ閉じ込めるだけでは足りない。
- `FakeTransportBackend.waitForTargetMessage(method:ordinal:after:)` は exact command order を検査する主要 API。移動時に semantics を変えない。

### E. UI の DOM tree が god object 化している

`Sources/WebInspectorUI/DOM/Tree/DOMTreeTextView.swift` は UIKit view、TextKit2 storage/layout、rendered rows、selection/multi-selection、find decoration、hover/menu、performance counter、testing API を 1 class に持っている。

現状の構造は「動いているが変更単位が大きい」。UI delegate を無理に分離するより、まず純粋な計算と状態を外へ出すほうが安全。

推奨する直し方:

- `DOMTreeRenderedRows` / layout builder を view から分離する。
- `DOMTreeSelectionController` を切り出し、range/row selection の state owner を明示する。
- markup rendering/tokenization は既存方針どおり MainActor 外で扱える値入力/値出力に寄せる。
- `#if DEBUG` の testing/performance API は `DOMTreeTextView+Testing.swift` に隔離する。

やってはいけないこと:

- TextKit2 delegate と UIKit view lifecycle を無理に別 owner へ移さない。表示更新の ordering が崩れやすい。
- UI 側で raw protocol JSON を parse しない。

### F. `Task.detached` / `@unchecked Sendable` の安全条件が散在している

代表例:

- `TransportMessageParser.parse` は message ごとに `Task.detached` で JSON parse する。
- `DOMTreeFindCoordinator` は `Task.detached` 内で検索し、`UITextSearchAggregator` を含む `DOMTreeFindSearchRequest: @unchecked Sendable` を渡している。
- `AttachedInspection.TransportReceiver` は `@unchecked Sendable` で message buffer を保護している。
- `NetworkBody` は value input を detached task に渡し、結果だけ MainActor に戻す。これは比較的よい形。
- Native symbol/bridge 周辺には `@unsafe @preconcurrency import`、`@unsafe` helper、`@unchecked Sendable` lock state がある。

推奨する直し方:

- まず `@unchecked Sendable` と `@unsafe` の用途を ArchitectureTests または専用 audit test で列挙し、増加を検知できるようにする。
- `DOMTreeFindCoordinator` は aggregator を unchecked request に含めず、detached task は `[NSRange]` batch または `AsyncStream` だけを返し、MainActor 側で aggregator を呼ぶ形へ寄せる。
- `TransportMessageParser.parse` の detached parse は、削除前に benchmark/負荷測定する。MainActor/actor 上へ戻す判断は測定後に限る。

やってはいけないこと:

- heavy parse/search/tokenization を MainActor に戻さない。
- `@unchecked Sendable` を一括削除しない。まず送信されている値と isolation 境界を特定する。

### G. テストの待ち方が大ファイルと時間依存に偏っている

`InspectorSessionTests.swift` は 5,000 行超、`TransportSessionTests.swift` は 2,000 行超。どちらも exact order を多く検査しており、これは transport/core の契約として価値がある。一方で、補助 waiter が散在している。

確認した主な待ち:

- `InspectorSessionTests.waitForBackendTargetMessage` は backend waiter と `Task.sleep` timeout を race させる。
- `InspectorSessionTests.awaitValueAfterActorTurns` は `Task.yield()` を最大 256 回回す。
- `TransportSessionTests.ManualResponseTimeout` は response timeout を明示制御できており、よい方向。
- `Monocly/BrowserSessionRestoreTests` には `Task.sleep(nanoseconds: 100_000_000)` の実時間待ちがある。

推奨する直し方:

- `ManualResponseTimeout` のような explicit signal 型を Core tests にも広げる。
- `awaitValueAfterActorTurns` は残してもよいが、event pump sequence や domain-specific signal で待てる箇所から置換する。
- Monocly の 100ms sleep は inspector lifecycle transition の完了 signal に置換する。
- god test は同一 suite/同一 isolation 条件を維持したままファイル分割する。

やってはいけないこと:

- exact order assertion を期待値緩和で握りつぶさない。
- test timeout のための sleep と、製品挙動としての debounce/delay を混同しない。`BrowserStore` / `BrowserWindowStore` の save debounce や progress indicator hold は挙動仕様であり、単純削除対象ではない。

### H. ArchitectureTests が足りない

XcodeMCPKit では import 方向や禁止依存を機械的に固定していた。WebInspectorKit でも同じ役割のテストを追加したほうがよい。

推奨する検査:

- `WebInspectorUI` は raw protocol JSON を parse しない。
- `WebInspectorNativeBridge` は Transport/Core/UI を import しない。
- `WebInspectorTransport` は Core/UI を import しない。
- `WebInspectorCore` は UI を import しない。
- `@_exported import` は `Sources/WebInspectorKit/WebInspectorKit.swift` の umbrella に限る。
- `Sources` に `Fake*Backend` や waiter/test helper を置かない。
- `@unchecked Sendable` / `@unsafe` の新規増加をレビュー対象にする。

## 4. 反証済み・実施しないこと

次は、現行ドキュメントやテスト契約と衝突するため、リファクタリング案から外す。

- Native bridge に target routing を理解させる。
- UI で raw protocol JSON を parse する。
- Transport と Core の target state を 1 つに統合する。raw routing と semantic projection は責務が違う。
- iframe document を通常 DOM child として扱う。
- Network redirect を別 top-level request として扱う。
- bootstrap / target commit / buffered provisional dispatch を並列化する。
- `DOM.enable` や compatibility CSS enable の local/compatibility path を、実プロトコル確認なしに削除する。
- private/undocumented WebKit 接続経路、`@unsafe @preconcurrency import WebInspectorNativeBridge`、NativeSymbols の fallback を、代替 attach 経路なしに削除する。
- detached heavy work を MainActor へ戻す。

## 5. 推奨実施順

### Phase 0: behavior lock を先に追加する

- ArchitectureTests を追加する。
- `TransportReceiver` の pre-transport buffering / ordering をテスト化する。
- `TransportSession` の provisional target buffering、reply retarget、stylesheet retarget の既存テストを確認し、必要なら小さく増やす。

### Phase 1: test support を production target から外す

- `FakeTransportBackend` / `SentTargetMessage` を test support へ移す。
- Core/Transport tests の import を更新する。
- god test の分割準備として helper を共有場所に出す。

### Phase 2: `TransportSession` の内部状態を分割する

- `TransportReplyStore` を導入する。
- `TransportTargetRegistry` を導入し、commit/destroy/retarget の pure mutation を集約する。
- `TransportStyleSheetRouting` を導入し、stylesheet owner 解決を分離する。
- `TransportInboundMessageQueue` を導入し、drain loop の配列管理を切り出す。
- 各ステップで exact event order / command order tests を green にする。

### Phase 3: `InspectorSession` の phase を明示する

- `connection` / `pendingConnection` を `InspectorConnectionPhase` から導出する。
- attach/connect/detach error path を phase transition として読めるようにする。
- runtime/console enable task の cancel/finish を connection identity と phase に結びつける。

### Phase 4: DOM owner を分割する

- `DOMSessionProtocolOperations.swift` を owner 別 extension に分ける。
- `DOMModel.swift` から TargetGraph、document store、selection、snapshot を分離する。
- Transport target lifecycle と Core target projection の境界を doc/test で固定する。

### Phase 5: UI DOM tree と find の concurrency 境界を整理する

- testing/performance API を extension file へ隔離する。
- rendered rows / selection / markup rendering を小 owner に分ける。
- `DOMTreeFindCoordinator` は detached search result を value batch として MainActor に返す構造へ寄せ、aggregator を `@unchecked Sendable` request から外す。

### Phase 6: Monocly sample app の待ちと lifecycle を後追いで整理する

- `BrowserSessionRestoreTests` の 100ms sleep を explicit lifecycle signal に置換する。
- save debounce / progress hold は挙動仕様として残し、必要なら injectable scheduler/clock を導入する。

## 6. 検証計画

段階ごとに最小単位と全体確認を組み合わせる。

```sh
swift test --filter WebInspectorTransportTests
swift test --filter WebInspectorCoreTests
xcodebuild test \
  -workspace WebInspectorKit.xcworkspace \
  -scheme WebInspectorKit \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'
```

変更範囲別:

- Transport 変更: `swift test --filter WebInspectorTransportTests`
- Core session / DOM 変更: `swift test --filter WebInspectorCoreTests`
- UI DOM tree / find 変更: `xcodebuild test` の WebInspectorUI tests を含む全体実行
- Native bridge/symbol 変更: NativeBridge / NativeSymbols tests と、可能なら実機または対象 Simulator 上の attach smoke test
- docs/config のみ: `git diff --check`

## 7. 検証残件

- repo-local の full `xcodebuild test` baseline は未実行。
- `TransportMessageParser.parse` の detached parse は、削除/同期化前に message volume と latency を測る。
- NativeBridge / NativeSymbols は private/undocumented API を含むため、公開 docs だけで安全性を判断しない。実バイナリ/実 OS での attach smoke が必要。
- test support target の形は未決定。SwiftPM test target 間共有と Xcode workspace の見え方を確認してから決める。
- `DOM.enable` local/compatibility path と CSS compatibility enable は、実 WebKit/mcp 相当の挙動確認なしに削除しない。

## 8. 実施状況

2026-06-13 時点では調査資料の作成のみ。リファクタリング本体、ArchitectureTests 追加、test support 移動、状態機械化は未実施。

