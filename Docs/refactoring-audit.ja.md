# WebInspectorKit リファクタリング監査

## 1. 前提

- 調査日: 2026-06-13
- 対象: `/Users/kn/Dev/WebInspectorKit`
- ブランチ: `refactor/structural-cleanup`
- 作業内容: behavior-preserving な構造整理を段階実施中。各段階で局所テストを通し、フェーズ単位で commit。
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

- repo-local の full `xcodebuild test` baseline は実行済み:
  `xcodebuild test -workspace WebInspectorKit.xcworkspace -scheme WebInspectorKit -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'`
  (2026-06-13、`b9b29aa4` 時点 green)。
- `TransportMessageParser.parse` の detached parse は、削除/同期化前に message volume と latency を測る。
- NativeBridge / NativeSymbols は private/undocumented API を含むため、公開 docs だけで安全性を判断しない。実バイナリ/実 OS での attach smoke が必要。
- `DOM.enable` local/compatibility path と CSS compatibility enable は、実 WebKit/mcp 相当の挙動確認なしに削除しない。
- `InspectorSessionTests.awaitValueAfterActorTurns` は 48 箇所残る。event pump sequence / domain-specific signal で待てる cluster は削減済みで、残りは CSS refresh reply、document reload task、picker selection completion など command task 完了待ちと密接な箇所が多い。
- `DOMModel.swift` は state/component ファイル分割後も private helper が多く、snapshot / frame projection / selector path の owner split は未完。可視性を広げる前に owner 境界を再確認する。
- `DOMSessionProtocolOperations.swift` は controller 導入済みで、availability は `DOMSessionAvailability.swift` に分離済み。ただし document request / picker / style hydration / delete-undo の file-level split は未完。現状は `perform` / `reloadDocument` / `removeElementStyles` / `clearDeleteUndoHistory` など private helper をまたぐため、可視性拡大なしに切れる範囲を優先する。
- `DOMTreeTextView` は markup、下位型、補助 state を分離済みだが、rendered rows builder、selection controller、testing/performance extension の分離は未完。testing extension は private member に広く触るため、別ファイル化には可視性拡大が必要。
- 挙動判断ではこの資料だけで足りない場合に `/Users/kn/Dev/WebKit` を参照する。今回確認した範囲では、WebKit の `DOMManager.inspectModeEnabled` は `DOM.setInspectModeEnabled` 成功 callback 後に state を更新し、`inspectElement` で inspect mode state を false に戻す。CSS 側は `CSSObserver` が `styleSheetAdded` / `styleSheetRemoved` / `styleSheetChanged` を `CSSManager` に渡し、`CSSManager` は `styleSheetId` を単一 map の identity として扱う。`CSSManager.stylesForNode` は node id から `DOMNodeStyles` を単一 owner として返し、`DOMNodeStyles` 自身が `_pendingRefreshTask` / `_needsRefresh` を持って refresh 状態を表現する。Runtime 側は `Frame` が `ExecutionContextList` を所有し、normal page execution context は frame の projection として扱われる。WebKit の `DOMManager` は `_idToDOMNode` を単一 node index として持ち、`DOMNode` constructor / child insert / unbind がこの index を更新する。`TreeOutline` は複数選択の selected items / last selected / shift anchor を `SelectionController` に委譲し、child list と `child.parent` を同じ append/insert/remove 操作で更新する。`DOMTreeElement.updateChildren` は可視 child の移動/作成を一箇所で担い、`DOMTreeOutline` は DOM node と tree element の橋渡しに集中する。Network 側は `NetworkManager` が `requestIdentifier -> Resource` map で protocol identity を持ち、`ResourceCollection` が URL/type index を collection owner として同期する。`ResourceTimelineDataGridNode` は row refresh scheduling と cached cell content の owner で、table owner は collection/filter/detail selection を扱う。WebKit の `TargetManager.didCommitProvisionalTarget` は old target destroy、new target の provisional flag clear、`target.connection.dispatchProvisionalMessages()`、TargetManager event dispatch の順で進める。UIProcess 側も `didCommitProvisionalTarget` protocol event を送る前に new target を non-provisional にする。WebInspectorKit の frame/provisional target routing と runtime-agent routing は Transport/Core 固有の補償なので、既存 exact tests が固定する raw protocol event ordering を保つ範囲で内部表現を型に畳んでよい。
- DOM current page owner 化では、WebKit の `TargetManager._checkAndHandlePageTargetTransition` と `DOMManager._initializeFrameTarget` / `_spliceFrameDocumentIntoPageTree` を確認した。WebKit も page target transition と frame document splice を別 owner で扱っているため、WebInspectorKit でも current page target/main frame の選択状態は `DOMCurrentPage`、semantic frame/document graph は `TargetGraph` / frame document projection に分離したままにする。
- DOM selection owner 化では、WebKit の `DOMManager.inspectElement`、`DOMManager.setInspectedNode`、`DOMTreeOutline.selectDOMNode` を確認した。WebKit は解決済み node を inspected/selected state に反映し、未解決・古い callback で現在の選択を進めない。WebInspectorKit では request/response に明示 `SelectionRequestIdentifier` があるため、古い requestNode 応答は現在の pending request を壊さず stale として返す。

## 8. 実施状況

2026-06-13 時点の実施済み:

- `Tests/WebInspectorArchitectureTests` を追加し、import boundary、UI raw JSON parse 禁止、production test fake 禁止、`@_exported import` 制約、unsafe concurrency allowlist を固定。
- `FakeTransportBackend` / `SentTargetMessage` を `WebInspectorTestSupport` target に移し、production `WebInspectorTransport` から test support を除去。
- `TransportSession` actor は維持しつつ、reply store / target registry / stylesheet routing / inbound queue / runtime context registry を helper に分割。
- `InspectorSession` の connection state を `InspectorConnectionPhase` に置換し、`connection` / `pendingConnection` を phase から導出。
- DOM 側は `DOMSessionControllers.swift`、`DOMModelTypes.swift`、`TargetGraph.swift`、`DOMDocumentStore.swift`、`FrameDocumentProjectionIndex.swift`、`DOMTreeProjectionBuilder.swift` へ段階分割。
- UI 側は `DOMTreeMarkup.swift`、`DOMTreeTextViewTypes.swift`、`DOMTreeTextFragmentViews.swift` を分離し、DOM tree expansion / observed content state も types 側へ移動。`DOMTreeFindCoordinator` は detached task へ `UITextSearchAggregator` を渡さない構造へ変更。
- `BrowserSessionRestoreTests` の 100ms sleep を selected web view install signal に置換。
- `InspectorSessionTests` の domain pump / DOM event / style invalidation / runtime context cluster は `waitUntilProtocolEventApplied` / `receiveAndApply...` helper に寄せ、actor-turn polling を 79 から 48 箇所まで削減。
- `DOMSessionAvailability.swift` を追加し、DOM action availability の owner を protocol operation 実行本体から分離。
- `DOMSessionElementPickerController` は `activeSession + acceptsInspectEvents` から `.idle / .enabling / .accepting` phase に置換し、inspect-mode enable 応答前の inspect event 無視と stale session 拒否を controller の状態遷移として表現。
- `TransportStyleSheetRouting` は `styleSheetID` ごとの resolved target / unresolved frame / replay payload を三つの辞書で同期する構造から、単一 `Route` enum 辞書に置換。frame target 解決時の replay は hidden queue ではなく `ResolvedStyleSheetAddedEvent` effect として `TransportSession` に返し、event emission ordering は actor 本体が維持。
- `DOMDocumentStore` は `targetStatesByID` と `lastDocumentLifetimeIDByTargetID` の同一 `targetID` 二辞書を単一 `TargetSlot` 辞書に置換。`reset` は document state だけを落とし、session 内 document lifetime counter は維持する不変条件を slot が持つ。
- `TransportReplyStore` は target reply 本体と root wrapper id -> target reply key の別辞書 index を、`TargetReplyRecord(rootWrapperID, pending)` に置換。wrapper ACK、target reply remove、target commit retarget の逆引き同期をなくし、reply resolution ordering は `TransportSession` に残した。
- `CSSSession` は `stylesByNodeID` と `activeRefreshSequenceByNodeID` の同一 node identity 二辞書を廃止し、`CSSNodeStyles` が `RefreshPhase.idle / refreshing(sequence:)` を所有する形に置換。style state と stale refresh token 判定を node styles owner に集約し、WebKit の `DOMNodeStyles` owner 境界と揃えた。
- `RuntimeState` は `targetStatesByID` と `runtimeAgentStatesByID` の同一 target id 二辞書を、`RuntimeTargetSlot(targetState, agentState)` の単一辞書へ置換。target projection と runtime-agent state は意味が違うため統合せず、slot が独立寿命と空 slot 掃除を所有する。
- `DOMTreeTextView` は row 配列と `rowIndexByNodeID` の別管理を `DOMTreeRenderedRows` に集約。visible node set、node id -> row index、row lookup/range lookup を rendered rows owner が持ち、TextKit/scroll view 側は owner query だけを使う。
- `DOMTreeTextView` の複数選択 state (`selectedNodeIDs` / last node / shift anchor / shift range) を `DOMTreeSelectionController` に集約。WebKit の `SelectionController` 境界に合わせ、TextKit view は gesture/key/menu 起点と装飾更新だけを担当する。
- `NetworkListViewController` の `requestIDs` と projection map の別管理を `NetworkListSnapshotRows` に畳み、表示済み/適用中 projection 比較を `NetworkListSnapshotState` に移した。diffable snapshot の apply/reconfigure 判定は view controller の UIKit boundary に残し、同一 row identity の同期だけを owner 化。
- `DOMTreeProjection` の children map と parent map を `DOMTreeProjectionEdges` に集約。projection の既存 query/互換 getter は残しつつ、builder は visible child edge を単一 owner に追加するだけにした。WebKit の `TreeOutline` が child list と parent pointer を同じ操作で更新する境界に合わせた。
- `DOMDocumentState` の `nodesByID` と `currentNodeIDByProtocolNodeID` の直接書き換えを `DOMDocumentNodeIndex` に集約。snapshot/API 互換 getter は残し、subtree build / remove が node storage と protocol raw id index を同じ owner 経由で更新する形にした。WebKit の `DOMManager._idToDOMNode` に相当するが、WebInspectorKit は multi-target/document lifetime を持つため document 単位の index としている。
- `NetworkSession` の `requestsByID` と `orderedRequestIDs` の直接同期を `NetworkRequestStore` に集約。request lifecycle mutation は `NetworkRequest` / `NetworkSession` に残し、store は target-scoped request identity と表示順の不変条件だけを所有する。WebKit の `NetworkManager._resourceRequestIdentifierMap` と `ResourceCollection` の index owner 境界に合わせた。
- `TransportSession` の provisional target message buffer を `TransportProvisionalTargetMessageStore` に集約。commit 前 target message の append、destroy 時 remove、commit retarget、commit 後 take を単一 owner が担い、emit と buffered message dispatch の順序制御は `TransportSession` actor に残した。WebKit の `TargetManager` は commit 時に `dispatchProvisionalMessages()` を明示順序で drain するため、WebInspectorKit でも既存 raw event ordering を保ったまま buffer 再配送は並列化せず actor 本体で逐次実行する。
- `TransportTargetRegistry` の `targetsByID` / `frameTargetIDsByFrameID` / `currentMainPageTargetID` を `private(set)` 化し、target create / destroy / commit / runtime frame projection の mutation を registry method に集約。reply retarget、stylesheet replay、runtime context retarget、buffer retarget は副作用 owner が別なので `TransportTargetCommitMutation` / `TransportFrameTargetResolution` として `TransportSession` に返し、actor 本体が既存順序で実行する。
- `DOMSession` の `currentPageTargetID` と `mainFrameID` の直接保持を `DOMCurrentPage` に集約。page promotion / provisional commit retarget / target destroy clear を同じ owner の mutation にし、`TargetGraph` は引き続き semantic target/frame/document projection を所有する。WebKit の page target transition owner と frame document splice owner が分かれている構造に合わせ、snapshot 互換 getter は維持した。
- `DOMSelection` は `selectedNodeID` / `pendingRequest` / `failure` の三つの独立 optional から、`selectedNodeID + DOMSelectionResolutionPhase.idle/pending/failed` を持つ `DOMSelectionState` に置換。選択更新、request 開始、成功、失敗、stale selected node cleanup を selection owner の mutation に集約し、pending request 置換時は古い request transaction を破棄する。古い requestNode 応答は current pending を消さず stale として返すテストを追加した。

最新の局所検証:

- `swift test --filter WebInspectorTransportTests -Xswiftc -strict-concurrency=minimal` (2026-06-13、TransportTargetRegistry mutation owner 化後 green)
- `swift test --filter CSSModelTests -Xswiftc -strict-concurrency=minimal` (2026-06-13、CSS refresh phase owner 化後 green)
- `swift test --filter RuntimeModelTests -Xswiftc -strict-concurrency=minimal` (2026-06-13、Runtime target slot 化後 green)
- `swift test --filter NetworkModelTests -Xswiftc -strict-concurrency=minimal` (2026-06-13、Network request store owner 化後 green)
- `swift test --filter WebInspectorCoreTests -Xswiftc -strict-concurrency=minimal` (2026-06-13、Network request store owner 化後 green)
- `swift test --filter DOMModelTests -Xswiftc -strict-concurrency=minimal` (2026-06-13、DOM document node index owner 化後 green)
- `swift test --filter DOMModelTests -Xswiftc -strict-concurrency=minimal` (2026-06-13、DOM current page owner 化後 green)
- `swift test --filter WebInspectorCoreTests -Xswiftc -strict-concurrency=minimal` (2026-06-13、DOM current page owner 化後 green)
- `swift test --filter DOMModelTests -Xswiftc -strict-concurrency=minimal` (2026-06-13、DOM selection resolution phase owner 化後 green)
- `swift test --filter WebInspectorCoreTests -Xswiftc -strict-concurrency=minimal` (2026-06-13、DOM selection resolution phase owner 化後 green)
- `swift test --filter WebInspectorUITests -Xswiftc -strict-concurrency=minimal` (2026-06-13、Network list snapshot state owner 化後 green)
- `swift test --filter WebInspectorArchitectureTests` (2026-06-13、element picker / stylesheet route 変更後 green)
- `swift test -Xswiftc -strict-concurrency=minimal` (2026-06-13、TransportTargetRegistry mutation owner 化後 green)
- `xcodebuild test -workspace WebInspectorKit.xcworkspace -scheme WebInspectorKit -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'` (2026-06-13、TransportTargetRegistry mutation owner 化後 green)
- `swift test -Xswiftc -strict-concurrency=minimal` (2026-06-13、DOM current page owner 化後 green)
- `xcodebuild test -workspace WebInspectorKit.xcworkspace -scheme WebInspectorKit -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'` (2026-06-13、DOM current page owner 化後 green)
- `swift test -Xswiftc -strict-concurrency=minimal` (2026-06-13、DOM selection resolution phase owner 化後 green)
- `xcodebuild test -workspace WebInspectorKit.xcworkspace -scheme WebInspectorKit -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'` (2026-06-13、DOM selection resolution phase owner 化後 green)
