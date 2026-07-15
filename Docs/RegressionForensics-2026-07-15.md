# 退行フォレンジクス分析: 2026-07-09 → 2026-07-15

- **分析日**: 2026-07-15
- **対象範囲**: `04e3eb9b`(branch `codex/ci-test-determinism` tip, 2026-07-09。以下 **W0**)〜 `78d28310`(branch `codex/network-grouped-entries` HEAD, 2026-07-15)
- **契機**: オーナー報告「W0 の頃と比べて全然色々動いていない。開発プロセスの問題か、設計の前提の問題か」
- **方法**: 5 視点(fix 連鎖 / 設計前提 / 機能パリティ / 検証ゲート / 所有権ドリフト)の並列フォレンジクス。全所見に独立の反証検証を実施し、**24 件確認・1 件反証棄却**。数値・SHA は git 一次証拠で裏取り済み。反証検証で判明した誤りは本文に修正反映済み。

## 結論

**発端は設計の前提の問題(PR #230 の所有権配置と過剰なクエリ抽象)、それを 198 commit 規模の混乱へ拡大させたのは開発プロセスの問題。** 設計欠陥自体は merge 当日に露呈していた。異常なのはその後で、①実 consumer story での検証なしに self-validated として merge し、②回帰基準線となるテストを実装 refactor と同一 commit で削除し、③CI gate を通らない branch に 198 commit を蓄積したため、「欠陥の露呈 → 次の再設計」のループが 8 日間で 4 周した。設計の揺れを検出・停止させる装置の欠如が根本原因であり、これを直さない限り第 4 世代でも同じ経過をたどる。

## 期間の構図: 8 日で 4 世代

| 日付 | 出来事 |
|---|---|
| 07-07 | PR #219 merge(再設計 #2: 二層 SDK, `docs/rearchitecture-sdk-surface`) |
| 07-09 | PR #229 merge(`codex/ci-test-determinism`)= **W0、オーナー認識の「動いていた」基準点** |
| 07-11 | PR #230 merge(再設計 #3: ownership/model API 再設計, +41,896/−21,205)= 現 `main` |
| 07-13 | branch 内で再々設計: `80a81b17`(approve)→ **78 分後** `338c2450`(破壊的 context migration) |
| 07-15 | 再々々設計: `255830c4`(approve)→ **142 分後** `1736a8ab` / `ceb30a00`(one-pass model cutover) |

- W0..HEAD: **281 commit / 6 日**(+61,395/−39,275)。うち fix 110 本(39%)、破壊的 `!` commit 18 本(07-10 に 12 本)。
- main..HEAD(R2): **198 commit**(+55,803/−54,374)。push 済みだが **PR 未作成のため CI は一度も未発火**。
- 各世代の中核前提の寿命: per-domain store **2.25 日**、ModelContext core **3.8 日**、transport 層への model feed 集約 **5 日**、feature recovery 状態機械 **約 30 時間**、fetched-results クエリ層 **4 日**。
- churn 上位 2 ファイル(TransportSession.swift 37 commits / 削除時 7,639 行、WebInspectorModelContext.swift 33 commits)は**どちらも期間内に丸ごと削除**。付随テスト(ConnectionModelFeedTests.swift 7,223 行)も同時破棄。
- HEAD で `swift test` は全 220 件 pass(2026-07-15 実行確認)。ただし後述のとおり、これは W0 同等挙動の保証にならない。

## 「動いていない」の直接原因候補(重要度順)

1. **skip-unknown ドクトリンの部分反転(最有力仮説・実機未確定)**。W0 の「未登録エンティティ参照イベントは skip + debug ログ」(2026-07-03 に実機の恒久 `.failed` バグ修正として確立)に対し、HEAD の canonical DOM reducer は未知ノード参照を throw し、`WebInspectorDOM.swift` が `connectionFailure` へ昇格、`78d28310` により feature 失敗 = attachment 失敗(retry API も削除)。反転は Architecture.md に文書化された設計判断であり、attach 途中参加レースは exact-order 意味論で構造的に排除されている。ただし**プロトコルモデル外の WebKit 正規ノイズ(evicted subtree 等)が実機で起きた場合、W0 では「イベント 1 個 skip」だったものが「attachment 全体 teardown・リトライなし」になる**。爆発半径の拡大が体感の「全部死ぬ」と整合する。実機ログでの発火確認は未実施。
2. **退行の検出装置の消滅**。W0 挙動を固定していた統合テスト群(WebInspectorDataKitTests.swift 7,466 行・約 119 本、TransportSessionTests.swift 50 本超、WebInspectorProxyKitBackendTests.swift 16 本)が、named cutover ではなく**実装 refactor と同一 commit で**ほぼ無代替に削除された(`ceb30a00` でテスト −14,562 行、`338c2450` で −9,915 行)。現テストは新実装の写像であり、回帰の基準線ではない。
3. **CI の射程外化**。ci.yml は W0 から byte 同一で健在(trigger: `push: main` / `pull_request`)だが、R2 は PR 未作成のため 07-11 以降 CI run ゼロ。PR を開けば 3 matrix + ContractTests は即座に機能する。
4. **確認済みの機能退行**: DOM undo/redo / markUndoableState の frame routing が `ceb30a00` で page target 固定送信になり、W0〜R1 まで維持されていた「frame 編集の undo は owning frame target へ」の経路と対応テスト 3 本が消失(意図的縮小か regression か、doc/commit に言及なし)。
5. **(副次)統合断絶の可能性**: `WebInspectorSession.init(tabs:)` 廃止(tab 構成は package-internal 化)、最低 OS の iOS 18.4 / macOS 15.4 引き上げ(R1 で発生)。無引数 init + `attach(to:)` の最小統合はソース互換が保たれている。

## 設計の前提の問題

- **PR #230 の中核配置が実装に耐えなかった**。「semantic な model feed / bootstrap / command authority を transport 層(ProxyKit)が所有する」前提(07-10 `a0fdeffa`/`1454437c`/`c05c060e`)は 4〜5 日で全面撤回され、所有層は W0 と同じ DataKit 側へ **A→B→A 回帰**(実装は復元ではなく feature actor 型の別設計)。HEAD の Architecture.md 自身が旧 TransportSession を「7,639 行で FIFO・reply routing・targets・event scopes・bootstrap・capabilities・epochs・picker leases・replay・terminal policy を所有」する god-actor と総括している。
- **クエリ抽象(owner lease / admission claim / dual publication)は merge 当日に破綻**。R1 doc は「467 tests, zero failures = validated」と宣言していたが、doc 自身が「second consumers are contract tests(第二の production consumer は存在しない)」と認めるとおり、**新規 consumer story での設計負荷検証が gate に含まれていなかった**。merge 同日の network initiator grouping(`a6bb5131` — 現ブランチ名の機能)着手直後に generic query index 導入 → perf 修正連発 → 4 日後 `1736a8ab` で query core 全置換。現 Architecture.md は「Sectioning, ResultsObserver, owner leases, admission claims, and dual publication paths are removed」と過剰さを明文で認めている。
- **owner が構造で確定していない**。teardown 責務は Proxy → TransportSession(07-10 `df3f7535`)→ ConnectionCore(07-15 `ceb30a00`)と移動し、同日に DataKit 側 `WebInspectorModelContainerConnectionOwner` も「Sole owner of one physical ProxyKit connection」を名乗る層違いの二重 sole-owner 宣言が発生。最終形の排他は `WebInspectorProxyOwnership.shared.claim` という **global singleton の実行時調停**頼み。model の top-level owner も container→context→container の A→B→A(3 日)+ 3 度目のコア差し替えで、同一 datakit surface へ BREAKING CHANGE **5 回**(`eb69e9e6`/`7890478b`/`338c2450`/`27321854`/`1736a8ab`)。
- **エラー処理方針の順序逆転**。feature recovery 状態機械は fix commit(`765692a1`, 07-14)として design gate を通らず導入され、5 commit の修正・安定化の末、**約 30 時間後**に `78d28310` が WebKit upstream(InspectorBackendDispatcher.cpp 等)を根拠に BREAKING で撤去。upstream 検証が実装の後に来ている。
- **収束の証拠がない**。第 4 世代移行(07-15 07:44)後の**約 11 時間**に lifecycle/teardown/ownership 系 fix が 14 本以上。churn の座標は世代交代のたびに後継ファイル(ConnectionCore.swift 等)へ引き継がれており、HEAD 直前 `3a4d83fa`(18:58)まで続いた。

## 開発プロセスの問題

- **設計 gate の形骸化**: 自己承認 → 78 分/142 分後に big-bang 破壊的移行を実行。8 日間で設計文書 4 世代(Rearchitecture 文書群 → WebInspectorKitsArchitecture.md 2,383 行 → WebInspectorModelArchitecture.md 1,955 行 → Architecture.md 3,261 行)、`255830c4` は前 2 世代計 4,338 行を一括削除。**HEAD の Architecture.md は「Status: Proposed design gate」のまま**破壊的実装 4 本が先行している。
- **契約の未収束(fix の fix が分単位)**: picker highlight 機構が導入 **14 分後**に全削除(`f712f1e4` 18:32 → `17468d1c` 18:46, −64 行)。response body revision へ 26 分間に 3 連 fix(`a874c82e`→`55482d60`→`73da80d7`)。重要な特徴: 各 commit にテストは付いている。**「テストを書かない」のではなく、テストが検証している契約そのものが数十分単位で改訂されている** — 設計判断が gate ではなく fix ストリームの中で決定・撤回されている。
- **テストの役割の倒錯**: source 変更 commit 全体では 81%(127/156)がテスト同時変更だが、fix commit に限ると 76 本中 66 本がテスト変更を伴わない。テストは新実装の構築に随伴して書き換わる一方、修正の回帰固定には使われていない。
- **fix 資産の破棄構造**: preserve/restore/keep 系 fix 28 本を含む修正コストの相当部分(当該期間 fix 76 本中 20 本が削除予定ファイル群)が、数日後に丸ごと削除される中間形態へ投入され蒸発した。
- **記録の欠如(恒常的)**: R2 の 198 commit 中 114(58%)は本文なし、検証手順・テスト結果への言及は全期間で 0 件。これは R2 固有ではなく repo 全体の慣行だが、この規模の再設計では検証実態を復元不能にした。
- **発見経路の CI 外依存**: MonoclyTests は存在するが CI gate に含まれず、embedding lifecycle の破壊(`0b8b49c7`, `c15c3465` のクラスタ)は local テスト実行または手動操作でしか検出されない。

## 反証棄却された仮説(記録として)

- 「PR #230 は owner map 未実装・contract gate fail のまま merge された」— **棄却**。`ConnectionCore` は merge 前日 `df3f7535` で導入済みで merge 時点の TransportSession.swift 内に実在し、owner map 記載の型は全て `864bebb0` の Sources に存在した。07-15 の ConnectionCore.swift 分離は R1 doc の「Owner map after migration」の計画実行である(ただし実行当日に teardown 直列化 fix が必要になった点は上記のとおり)。

## 推奨アクション(優先順)

1. **実機/Monocly で症状ログを取得**し、「missingNode → connectionFailure → attachment teardown」経路の発火を観測して直接原因候補 1 を確定させる。発火が確認されたら、プロトコルモデル外イベントの扱い(teardown か skip+ログか)を owner 判断として文書化する。
2. **PR を作成して CI を回す**。装置は健在で、開くだけで従来の gate が機能する。
3. **W0 の削除テスト群から挙動パリティのチェックリストを復元**する(`git show 04e3eb9b:Tests/...` で全量参照可能)。特に: destroy 後の attaching 回帰と自動復帰、unmaterialized ノード参照の skip、picker highlight restore の transport-backed 検証、frame undo routing。
4. **gate 運用の変更**: 承認と実行の分離(最低でも実 consumer story での soak を gate 条件化)、破壊的 cutover では旧挙動テストを「移植してから」削除する規律。
5. **第 4 世代の確定**: Architecture.md を「Proposed」から確定させ、`WebInspectorProxyOwnership.shared.claim`(runtime 調停)を型/構造の排他に置き換える。lifecycle/ownership 系 fix の収束をもって世代を固定し、次の再設計は収束後にのみ開始する。

## 付録: 確認済み所見一覧(反証検証通過 24 件、修正反映済み)

| # | 分類 | 重大度 | 所見(要旨) | 主要証拠 |
|---|---|---|---|---|
| 1 | process | 高 | 契約の選択そのものが数十分単位で改訂される fix-of-fix(テストは毎 commit 存在) | `f712f1e4`→`17468d1c`(14 分), `a874c82e`→`73da80d7`(26 分) |
| 2 | 複合 | 高 | churn 上位 2 ファイル(70 commits 分の fix 投資)+テスト資産が期間内に丸ごと削除 | `ceb30a00`, `1736a8ab` |
| 3 | design | 高 | 収束前に次の再設計を開始する入れ子構造。承認→即日 cutover ×2、`!` commit 18 本 | `80a81b17`→`338c2450`, `255830c4`→`1736a8ab` |
| 4 | design | 中 | recovery 機構が導入約 30h で BREAKING 撤去。upstream 検証が実装の後 | `765692a1`→`78d28310` |
| 5 | process | 中 | preserve/restore 系 fix 28 本。並行ブランチの機械的一括統合を committer date が示す | `63ba3bc0`/`2e06919a`(9 秒差) |
| 6 | design | 高 | R1 の per-domain store / ModelContext への domain・transport 集約は 2.25〜3.8 日で破棄(caller-confined context の骨格のみ縮小存続) | `338c2450`, `1736a8ab` |
| 7 | design | 高 | クエリ抽象が merge 当日の initiator grouping で破綻。gate に新規 consumer story 検証なし | `a6bb5131`, `e79c54b3`, `1736a8ab` |
| 8 | process | 高 | 自己承認 gate、doc 4 世代、HEAD doc は「Proposed」のまま実装先行 | `255830c4`(前 2 世代 4,338 行削除) |
| 9 | 複合 | 中 | エラー方針の反転 2 回(W0 内 fail-fast→skip、R2 内 recovery 追加→撤去) | `4d7d1143`, `765692a1`, `78d28310` |
| 10 | 複合 | 中 | 第 4 世代移行後 11h も lifecycle 系 fix 14 本+。churn 座標が後継ファイルへ移転 | `f712f1e4`(ConnectionCore +168) |
| 11 | process | 高 | W0 挙動固定テストが実装 refactor と同一 commit でほぼ無代替削除。green ≠ W0 パリティ | `ceb30a00`(テスト −14,562), `338c2450`(−9,915) |
| 12 | design | 高 | skip-unknown の部分反転。モデル外 WebKit ノイズで skip → attachment 全 teardown に拡大(実機未観測) | reducer throw 経路, `78d28310` |
| 13 | design | 高 | 最終 2 commit で回復手段を段階削除。W0 比で steady-state の許容度が狭まった可能性(attach 時挙動は W0 同等) | `19380c76`, `78d28310` |
| 14 | 複合 | 中 | frame highlight 無視は W0 から継承(退行ではない)。**undo/redo の frame routing 消失は実在**(意図の証拠なし) | `ceb30a00`, 削除テスト 3 本 |
| 15 | 複合 | 中 | public API 非互換は `tabs:` 使用者と iOS 18.4 未満環境に限定。最小統合はソース互換 | Package.swift, WebInspectorSession.swift |
| 16 | process | 高 | R2 の 198 commit に CI run ゼロ(PR 未作成)。ci.yml 自体は W0 と同一で健在 | gh run list, ci.yml diff 空 |
| 17 | process | 高 | 回帰基準線の消滅は R1 の書き換え+R2 の refactor 随伴削除の 2 段階。669b2697 の大型削除は R2 内部 churn | `669b2697`, `ceb30a00`, `338c2450` |
| 18 | process | 中 | commit 本文に検証記録 0 件(58% は本文なし)。ただし repo 恒常の慣行で R2 固有ではない | git log 全数調査 |
| 19 | 複合 | 中 | MonoclyTests は CI gate 外。Monocly 起点の発見が立証できるのは lifecycle クラスタ 2 commit | `0b8b49c7`, `c15c3465` |
| 20 | 複合 | 高 | fix 76 本は 17 scope に分散するが破られた invariant の種類(lifecycle/ownership)は同一クラスに収束。fix の 66/76 はテスト変更なし | scope 集計 |
| 21 | design | 高 | teardown owner が 5〜6 日で 2 回移動+層違いの二重 sole-owner 宣言。排他は global singleton の runtime claim | `df3f7535`, `ceb30a00`, `807c9472` |
| 22 | design | 高 | model top-level owner の A→B→A(3 日)+3 度目のコア差し替え。同一 surface へ BREAKING ×5 | `eb69e9e6`〜`1736a8ab` |
| 23 | design | 高 | 「transport が semantic を所有」前提の全面撤回と DataKit 層への回帰(主要因。ただし全 fix の単一原因ではない) | `a0fdeffa`→`ceb30a00` |
| 24 | process | 高 | recovery 機構が gate を通らず fix として導入され、fix ストリーム内で日内決定・撤回 | `765692a1`→`78d28310`(30h) |
