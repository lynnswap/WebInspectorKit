# Phase 1 Findings — Measured Current State

Numbered findings list. Every design element in the active design document
([05-two-layer-sdk-design.md](05-two-layer-sdk-design.md); 03 is archived for
history) must trace back to one of these findings or to a scope-contract
outcome. Raw measurement reports with full evidence tables live in
[measurements/](measurements/).

Baseline date: 2026-07-02, commit `45c6d880`.

## A. Product / public-surface reality

- **F-01 — 32 public declarations in the whole package, forming 3 types, all
  in WebInspectorUI (+2 extension methods in WebInspectorKit).** Effective
  Swift access totals: 2,376 `package` keywords vs 32 public declarations
  (74:1), 0 `open`. The 3 types: `WebInspectorSession`,
  `WebInspectorViewController`, `WebInspectorTab`. Complete inventory:
  [measurements/measure-access.md](measurements/measure-access.md).
- **F-02 — 3 of 6 library products are empty modules externally.**
  `WebInspectorCore`, `WebInspectorTransport`, `WebInspectorNativeSymbols`
  export zero public declarations (api-design smell (a) ×3). `WebInspectorUI`
  is constructible but cannot attach (F-04). Only `WebInspectorKit` is
  end-to-end usable. Product usability matrix in measure-access.md Extra.
- **F-03 — `@_exported import` re-couples both designed splits (smell (c),
  load-bearing).** `Sources/WebInspectorCore/AttachedInspection.swift:3-6`
  re-exports the 4 Core sub-targets; measured: 43 UI-target files
  `import WebInspectorCore`, 0 files import any sub-target directly, while
  every consumed type is defined in a sub-target — the 4-way split has no
  import-boundary meaning. `Sources/WebInspectorKit/WebInspectorKit.swift:1`
  re-exports WebInspectorUI, so the Kit product ≡ UI + 2 methods.
- **F-04 — attach is provided by the "import-selects-variation" antipattern.**
  WebInspectorUI ships `@_disfavoredOverload public func attach(to:)` that
  unconditionally throws
  (`WebInspectorSession.swift:57-62`, `WebInspectorViewController.swift:164-167`);
  WebInspectorKit shadows it with a working overload
  (`WebInspectorNativeAttachment.swift:7-21`) through the package-scoped
  `attachPresentation` hook. Which module you import silently decides whether
  attach works at runtime.
- **F-05 — custom tabs cannot reach any domain state (blocks scope outcome 1).**
  `WebInspectorTab` factories receive `WebInspectorSession` whose public
  surface is `pageUserInterfaceStyle` / `attach` / `detach` only; `inspector`
  and `attachment` are package
  (`WebInspectorSession.swift:12,53`). The README Console-tab example
  (README.md:61-76) is unimplementable as advertised — confirmed in
  [measurements/map-consumers.md](measurements/map-consumers.md).
- **F-06 — NativeBridge's public C surface is unusable standalone.**
  `WebInspectorNativeBridge.h` requires six resolved symbol addresses whose
  only producer (`WebInspectorNativeSymbols`) has zero public declarations.
- **F-07 — MIGRATION.md pre-announces this publication.** Docs/MIGRATION.md:105-112:
  DOM/Network surfaces are "internal until an app-facing API is explicitly
  published"; 0.1.5 consumers previously had model access and lost it in 0.2.0.
  `attach(to:)`/`detach()`/`WebInspectorTab(id:title:systemImage:makeViewController:)`
  were just stabilized in 0.2.0 — do not re-break those shapes without cause.

## B. Dependency directions / Package.swift hygiene

- **F-08 — undeclared load-bearing import:** WebInspectorKit imports
  WebInspectorCore (`WebInspectorNativeAttachment.swift:3`) without declaring
  it (Package.swift:202-209). Tests import ObservationBridge without product
  declarations (WebInspectorCoreTests, WebInspectorUITests).
- **F-09 — dead declared dependencies:** ObservationBridge declared on 4 Core
  targets, imported by none of them (Core uses plain `import Observation`);
  WebInspectorTransport declared on WebInspectorUI, never imported;
  SyntaxEditorUI declared on WebInspectorUITests, never imported.
- **F-10 — the native attach flow orchestrates Core from above.** The entire
  attach path is a package extension on `InspectorSession` in
  WebInspectorNativeTransport
  (`InspectorSession+NativeAttachment.swift:5-58`) calling package staging
  hooks on Core (`beginAttachmentRequest` / `makeTransportSession` /
  `connectAttachment`, AttachedInspection.swift:488-527). The concrete
  transport is not "below" Core; it drives it, and the only public entry
  hard-codes this chain via F-04.
- **F-11 — layering below Core is clean.** WebInspectorTransport imports only
  Foundation (16 Swift files, 2,407 lines); NativeBridge imports only system
  headers; no backward imports anywhere.

## C. Variation-axis leakage

Full tables and re-measure commands:
[measurements/measure-variation.md](measurements/measure-variation.md).

- **F-12 — protocol method strings: 137 raw literals, 76 distinct, 35
  duplicated, zero constants.** Worst: `Target.didCommitProvisionalTarget` ×8
  across 4 files.
- **F-13 — Target lifecycle events are re-interpreted at 4 layers** by
  re-matching the same strings (TransportSession, TargetProtocolDispatching,
  DOMSessionProtocolOperations's private second dispatcher at :1083,
  AttachedInspection post-dispatch checks at :845-872). Commit semantics have
  no single owner.
- **F-14 — attachment precondition re-expressed 14×; error string duplicated
  10×.** The designed owner `ProtocolCommandChannel.requireAttached()`
  (ProtocolCommandChannel.swift:40-44) has only 5 call sites; 9+ sites
  hand-roll the same guard/throw.
- **F-15 — DOM intent→method-name mapping exists twice** (DOMProtocolDispatching.swift:12-83
  vs teardownCommandMethodName switch, DOMSessionProtocolOperations.swift:371-394);
  adding a DOM command requires editing both.
- **F-16 — 9 hand-rolled generation/staleness counters** across 5 targets
  (same UInt64+equality shape, no shared primitive).
- **F-17 — tab-kind axis leaks:** builtIn/custom predicate at 8 sites, the
  `.domElement` special case escapes into 5 files (18 mentions), two separate
  `BuiltInCatalog` instances each constructing its own tab controllers
  (TabModels.swift:116, BuiltInTabControllers.swift:74).
- **F-18 — preview scaffolding re-implements the wire protocol in a UI
  target** (DOMElementViewController+Preview.swift string-matches
  `CSS.setStyleText` etc.) — a 4th place that breaks when a method string
  changes.
- **F-19 — 110 `#if DEBUG` blocks in 37 files** thread `*ForTesting` state
  through production paths (worst: DOMTreeTextView 15, DOMElementViewController 11).
- **F-20 — contrast, the in-repo precedent:** domain event dispatch has a
  designed absorption point (`ProtocolDomainEventDispatcherRegistry`, single
  registration site AttachedInspection.swift:476-484). The leaking axes above
  should converge to this pattern.

## D. Platform axis

Full table: [measurements/measure-platform.md](measurements/measure-platform.md).

- **F-21 — macOS gets a publicly empty package (measured, not inferred).**
  `swift build` succeeds on macOS (446/446), but a compile probe shows
  `WebInspectorSession` is unresolvable: all 3 public types and both working
  attach extensions sit inside whole-file `#if canImport(UIKit)` gates.
- **F-22 — the AppKit-ready layer already exists; the blocker is access
  control, not platform work.** All 5 Core targets, Transport, NativeTransport:
  zero platform gates, zero UIKit imports, macOS-functional. NativeBridge has
  4 deliberate `TARGET_OS_OSX` code paths ("WebInspectorKit drives its own
  frontend on macOS"). Gate discipline is clean: 70 of 72 gated files are
  whole-file gates.
- **F-23 — one real mid-file platform smell:** `NetworkStatusSeverity.swift`
  keeps the platform-neutral `StatusSeverity` domain enum in a UI target next
  to its UIColor mapping (lines 4-16 vs 18+).

## E. God types / state ownership

Baseline table (stored props, decl spans, extensions):
[measurements/measure-god-types.md](measurements/measure-god-types.md).

- **F-24 — naming: there are no `*Model` types.** `*Model.swift` files contain
  `DOMSession` / `NetworkSession` / `ConsoleSession` / `CSSSession` /
  `RuntimeState`. Each domain class is simultaneously observable state store,
  command dispatcher, and protocol event sink.
- **F-25 — DOMSession is the dominant god type:** 26 stored properties
  (22 release + 4 DEBUG), 1,876-line declaration, 6 extensions across 6 files
  incl. the 1,768-line DOMSessionProtocolOperations.swift. It also owns
  CSSSession (`elementStyles`).
- **F-26 — the bind/unbindProtocolChannel triplet
  (`commandChannel`/`protocolCommands`/`recordError`) is copy-pasted across 6
  owners**, fanned out manually by InspectorSession.bindProtocolChannel
  (AttachedInspection.swift:1020-1056). Strongest owner-less-invariant signal;
  re-measurement anchor.
- **F-27 — AttachedInspection is a thin 5-let aggregate (42 lines, no logic)**
  — the natural seed of a public domain-state surface. Domain sessions are
  created once and never replaced across attach/detach cycles (reset+rebind),
  so external consumers could hold long-lived observable references.
- **F-28 — InspectorSession's UI-facing surface is tiny (5 members)**;
  everything else it owns is transport-staging for NativeTransport. A natural
  public-session / transport-SPI split already exists in usage. One
  consumer-vocabulary leak into Core: `retireBackendInteractionForPresentationEnd`
  (smell (b), AttachedInspection.swift:648, DOMSessionProtocolOperations.swift:64).
- **F-39 — InspectorSession is the actual lifecycle god type in
  AttachedInspection.swift** (712-line body, 8 stored props: connect/detach
  generations, connection phase, pumps, bootstrap, dispatcher registry,
  channel fan-out — measure-god-types.md item 4). Its UI-facing surface is
  tiny (F-28), but the type concentrates lifecycle orchestration; any design
  that makes it the public flagship must keep it a facade and must not
  accrete the migrated attach orchestration into its body.
- **F-29 — protocol payloads are the observable state.**
  `NetworkRequest.request/response/metrics/initiator` hold raw
  `*.Payload` structs; `RuntimeRemoteObject.payload` is the raw protocol
  shape; `perform(intent:)` returns the raw envelope
  `ProtocolCommand.Result{resultData: Data}`; `apply*` event mutators (18
  Network / 19 DOM / 8 Runtime / 5 Console) share the same types as the read
  surface. Cross-domain type references exist (Initiator.Payload →
  ConsoleMessage.StackTracePayload + DOMNode.ProtocolID), which entangles the
  Core sub-targets at the type level.
- **F-30 — ID types compose transport identity.** NetworkRequest.ID,
  ConsoleMessage.ID, DOMNode.ID, RuntimeContext.Key all embed
  `ProtocolTarget.ID` (a WebInspectorTransport type); RuntimeContext types
  live in the Transport target despite being domain vocabulary. Full ID table
  in [measurements/map-domain-surfaces.md](measurements/map-domain-surfaces.md).

## F. Consumers and tests

- **F-31 — de-facto consumer contract is DOM+Network only.** Built-in UI uses
  30 of ~129 DOMSession package members and 7 of 30 NetworkSession members;
  `.runtime` / `.console` / `.targetGraph` have zero UI consumers — the
  Console/Runtime public surface cannot be derived from existing consumers
  and must be designed fresh. Member-by-member lists:
  [measurements/map-ui-callsites.md](measurements/map-ui-callsites.md).
- **F-32 — the consumed surface splits cleanly into contract vs plumbing.**
  Contract: observable state + revision counters + queries + async commands +
  model value types. Plumbing (built-in-UI-only): since-cursor render diffs
  (`changes(since:)`, `rowDeltas`, `domTreeRenderSnapshot`,
  `requestDisplayChanges(after:)`), presentation-lifecycle hooks,
  InterfaceModel caches, preview-only `apply*` injection.
- **F-33 — Demeter pain at the session boundary:** `inspector.attachment.dom.*`
  chains at 7 sites (DOMNavigationItems); NetworkTabController round-trips
  `session.interface.networkPanelModel(for: session.attachment)`;
  DOMSplitViewController fabricates `InspectorSession(attachment:)` UI-side;
  network detail reads payloads 3 hops deep (`request.request.headers`).
- **F-34 — Monocly (only real consumer) uses exactly 6 public symbols** and
  had to write a ~300-line attachment state machine because the package
  exposes no attachment-state observability
  (BrowserInspectorSessionAttachmentLifecycle.swift). It never uses custom
  tabs; `init(tabs:)` is consumed by no one (README-only).
- **F-35 — no public-API contract test exists.** 134 `@testable` imports
  across 5 Swift test targets (re-verified; measurements/map-consumers.md's
  "163" is an arithmetic slip — its own per-target tally 50+75+7+1+1 sums to
  134, matching measure-deps.md); zero tests import any product plainly the
  way Monocly or the README does. Nothing in CI compiles from the consumer's
  side of the boundary. (Counter-asset: `FakeTransportBackend` +
  `InspectorSession.connect(transport:)` prove the domain stack runs without
  the native bridge — Tests/WebInspectorTestSupport/FakeTransportBackend.swift:16.)

## G. Transport seam

Full analysis: [measurements/map-transport-stack.md](measurements/map-transport-stack.md).

- **F-36 — transport is a real, exercised variation axis at package scope.**
  `package protocol TransportBackend` (2 methods) has 3 conformers (1
  production, 2 test); InspectorSession depends on the concrete
  TransportSession actor via `connect(transport:)`.
- **F-37 — the backend seam is half a duplex channel.** TransportBackend
  covers outbound only; inbound is wired by convention
  (messageHandler closure → TransportReceiver (lives in CoreSupport, not
  Transport) → receiveRootMessage) at the sole composition root. A second
  backend author must copy this undocumented wiring.
- **F-38 — TransportSession bakes WebKit-inspector semantics** (provisional
  target buffering, styleSheet routing, `DOM.enable` synthesized reply,
  per-domain event sequences) — protocol-level, not native-bridge-specific;
  fine for any WebKit-protocol endpoint, not CDP-generic.
