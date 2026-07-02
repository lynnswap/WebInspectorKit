# measure:access

## Summary

Access control is package-scoped almost everywhere: across all 15 targets there are 2,376 `package` keyword occurrences in Swift versus exactly 32 public Swift declarations, all confined to WebInspectorUI (30) and WebInspectorKit (2). No `open` access modifier exists anywhere (all `open` hits are an enum case and HTML string literals). Three of the six declared library products (WebInspectorCore, WebInspectorTransport, WebInspectorNativeSymbols) export ZERO public declarations — importing them externally yields empty modules (api-design smell (a), three instances). WebInspectorUI alone is constructible but functionally inert: its only public attach(to:) is a @_disfavoredOverload that unconditionally throws; the working attach lives in WebInspectorKit's extension, making WebInspectorKit the sole end-to-end usable product. Smell (c) applies twice and is load-bearing: the @_exported block in WebInspectorCore/AttachedInspection.swift:3-6 fully re-couples the 4-way Core split (43 UI-target files import WebInspectorCore, 0 import any Core subtarget directly, while every domain type they use is defined in a subtarget), and WebInspectorKit.swift:1 re-exports WebInspectorUI so the Kit product is UI + 2 methods. Smell (b) applies weakly: no consumer-only types sit on the provider side, but one consumer-lifecycle method (retireBackendInteractionForPresentationEnd) leaks UI-presentation vocabulary into Core and CoreDOMCSS. Consequence for the design doc: the public Core/Transport surface must be designed from scratch — none of the domain state (InspectorSession, AttachedInspection, DOMSession, NetworkSession, RuntimeState, ConsoleSession, TargetGraph, TransportSession/TransportBackend) is public today, and ~78% of the package-scoped surface sits in the three Core domain targets plus Transport that the rearchitecture intends to publish.

## Findings

### 1. Only 32 public Swift declarations exist in the entire package, all in WebInspectorUI (30) and WebInspectorKit (2); every Core/Transport/UI-sub target has zero

Swift-only keyword counts: WebInspectorUI 30 public / 107 package; WebInspectorKit 2 public / 0 package; all other 13 targets 0 public. WebInspectorUI's 30 public declarations form exactly 3 types: WebInspectorSession (class:11, pageUserInterfaceStyle:17, convenience init(tabs:):25, attach(to:):58, detach():78), WebInspectorViewController (class:43, session:49, automaticallyDetachesOnDismiss:50, drawsBackground:66, init(session:):79, convenience init(tabs:):85, six UIKit overrides:94/108/114/119/128/147, attach(to:):165, detach():169), WebInspectorTab (struct:5, typealias ID:6, id:8, title:9, image:10, ==:35, hash(into:):39, init:60, init:73, .dom:87, .network:94). WebInspectorKit's 2: extension WebInspectorSession.attach(to:) and extension WebInspectorViewController.attach(to:).

Locations: Sources/WebInspectorUI/Containers/WebInspectorSession.swift:11; Sources/WebInspectorUI/Containers/WebInspectorViewController.swift:43; Sources/WebInspectorUI/Tabs/WebInspectorTab.swift:5; Sources/WebInspectorKit/WebInspectorNativeAttachment.swift:8; Sources/WebInspectorKit/WebInspectorNativeAttachment.swift:16

### 2. Smell (a) applies three times: library products WebInspectorCore, WebInspectorTransport, WebInspectorNativeSymbols pass through package-only API — external import yields an empty module

Package.swift declares .library products WebInspectorCore (lines 19-22), WebInspectorNativeSymbols (27-30), WebInspectorTransport (31-34). Swift-only public declaration count in each: 0. WebInspectorCore: 33 package keywords, 0 public; its @_exported imports (AttachedInspection.swift:3-6) re-export CoreConsoleNetwork (510 package/0 public), CoreDOMCSS (911/0), CoreRuntime (262/0), CoreSupport (33/0) — so the product surface stays empty. WebInspectorTransport: 159 package, 0 public. WebInspectorNativeSymbols: 31 package, 0 public (its 2 'public' hits are os_log privacy modifiers at NativeInspectorSymbolLog.swift:11,15). All domain state is package-scoped, e.g. 'package final class DOMSession' (CoreDOMCSS/DOM/DOMModel.swift:8), 'package final class NetworkSession' (CoreConsoleNetwork/Network/NetworkModel.swift:479), 'package final class RuntimeState' (CoreRuntime/Runtime/RuntimeModel.swift:412), 'package final class ConsoleSession' (CoreConsoleNetwork/Console/ConsoleModel.swift:307), 'package final class TargetGraph' (CoreDOMCSS/DOM/TargetGraph.swift:17), 'package final class InspectorSession' and 'package final class AttachedInspection' (WebInspectorCore/AttachedInspection.swift:367,322).

Locations: Package.swift:19-42; Sources/WebInspectorCore/AttachedInspection.swift:322; Sources/WebInspectorCore/AttachedInspection.swift:367; Sources/WebInspectorCoreDOMCSS/DOM/DOMModel.swift:8; Sources/WebInspectorCoreConsoleNetwork/Network/NetworkModel.swift:479; Sources/WebInspectorCoreRuntime/Runtime/RuntimeModel.swift:412

### 3. Smell (c) applies and is load-bearing: @_exported in WebInspectorCore erases the 4-way Core split at every consumer — 43 UI files import WebInspectorCore, 0 import any subtarget

Sources/WebInspectorCore/AttachedInspection.swift:3-6 contains '@_exported import WebInspectorCoreConsoleNetwork / CoreDOMCSS / CoreRuntime / CoreSupport'. Measured: rg '^import WebInspectorCore(Support|Runtime|DOMCSS|ConsoleNetwork)' across WebInspectorUI, UIDOM, UINetwork, UISyntaxBody, WebInspectorKit, NativeTransport returns 0 hits, while 'import WebInspectorCore' appears in 43 files of the four UI targets — yet the types those files consume (DOMSession, NetworkSession, RuntimeState, ConsoleSession, TargetGraph, CSSSession) are all defined in the subtargets. The target split therefore has no import-boundary enforcement; it is one module surface in practice. Second instance: Sources/WebInspectorKit/WebInspectorKit.swift:1 is a single line '@_exported import WebInspectorUI', making the WebInspectorKit product identical to WebInspectorUI plus 2 extension methods.

Locations: Sources/WebInspectorCore/AttachedInspection.swift:3-6; Sources/WebInspectorKit/WebInspectorKit.swift:1

### 4. WebInspectorUI product alone is functionally inert: its only public attach(to:) is a @_disfavoredOverload that unconditionally throws; the working attach is supplied by WebInspectorKit via overload shadowing

Sources/WebInspectorUI/Containers/WebInspectorSession.swift:57-62: '@_disfavoredOverload public func attach(to webView: WKWebView) async throws { try await attachPresentation(to: webView) { _, _ in throw AttachmentUnavailableError() } }' with AttachmentUnavailableError.description = "Native WKWebView attachment is provided by WebInspectorKit." (lines 113-117). Same pattern on WebInspectorViewController (WebInspectorViewController.swift:164-167). WebInspectorKit's non-disfavored extensions (WebInspectorNativeAttachment.swift:7-21) route through package-scoped attachPresentation + WebInspectorNativeTransport's inspector.attach(to:). So an external consumer importing ONLY WebInspectorUI can construct the session/VC and call detach(), but every attach throws at runtime — product usability depends on which module you import, resolved silently by overload ranking rather than by API shape.

Locations: Sources/WebInspectorUI/Containers/WebInspectorSession.swift:57-62; Sources/WebInspectorUI/Containers/WebInspectorSession.swift:113-117; Sources/WebInspectorUI/Containers/WebInspectorViewController.swift:164-167; Sources/WebInspectorKit/WebInspectorNativeAttachment.swift:7-21

### 5. WebInspectorNativeBridge is the only non-UI product with a real public surface (ObjC header), but it is unusable standalone: its required input has no public producer

Sources/WebInspectorNativeBridge/include/WebInspectorNativeBridge.h exposes the WebInspectorNativeBridge NSObject class (initWithWebView: designated initializer, attachWithResolvedSymbols:error:, sendJSONString:error:, detach, messageHandler/fatalFailureHandler properties), the WebInspectorNativeResolvedSymbols struct (six raw uint64_t addresses: connectFrontend, disconnectFrontend, stringFromUTF8, stringImplToNSString, destroyStringImpl, backendDispatcherDispatch), and two FOUNDATION_EXPORT *ForTesting discovery functions. The only producer of those six addresses is WebInspectorNativeSymbols (MachOKit-based), which has 0 public declarations — so an external consumer of the WebInspectorNativeBridge product cannot construct a valid WebInspectorNativeResolvedSymbols without reimplementing symbol resolution. The 6 'public' keyword hits inside the target are C++ access specifiers and an os_log %{public}@ format (WebInspectorNativeABI.h:14,36,139; WebInspectorNativeBridge.mm:513,514,679), not Swift access control.

Locations: Sources/WebInspectorNativeBridge/include/WebInspectorNativeBridge.h; Sources/WebInspectorNativeBridge/WebInspectorNativeABI.h:14; Sources/WebInspectorNativeSymbols/NativeInspectorSymbolLog.swift:11

### 6. Smell (b) applies weakly: no consumer-only TYPES on the provider side, but one consumer-lifecycle method leaks UI-presentation vocabulary into Core and CoreDOMCSS

InspectorSession.retireBackendInteractionForPresentationEnd() (Sources/WebInspectorCore/AttachedInspection.swift:648-653) and DOMSession.retireBackendInteractionForPresentationEnd() (Sources/WebInspectorCoreDOMCSS/DOM/DOMSessionProtocolOperations.swift:64) exist solely to serve the UI's root-presentation dismissal path (called from WebInspectorSession.retireRootPresentation(detach:), Sources/WebInspectorUI/Containers/WebInspectorSession.swift:83-90). 'PresentationEnd' is consumer (UIKit presentation) vocabulary owned by Core. Counter-check that keeps (b) narrow: NetworkPanelModel — the UI-facing projection over Core's NetworkSession — correctly lives on the consumer side (Sources/WebInspectorUINetwork/NetworkPanelModel.swift:33), so domain models themselves are not polluted with consumer types.

Locations: Sources/WebInspectorCore/AttachedInspection.swift:648; Sources/WebInspectorCoreDOMCSS/DOM/DOMSessionProtocolOperations.swift:64; Sources/WebInspectorUI/Containers/WebInspectorSession.swift:83-90; Sources/WebInspectorUINetwork/NetworkPanelModel.swift:33

### 7. Package-scope mass is concentrated exactly where the rearchitecture wants a public surface: CoreDOMCSS + CoreConsoleNetwork + CoreRuntime + Transport hold 1,842 of 2,376 package keywords (77.5%)

Swift-only package keyword counts: CoreDOMCSS 911 (38.3%), CoreConsoleNetwork 510 (21.5%), CoreRuntime 262 (11.0%), UINetwork 180, Transport 159 (6.7%), WebInspectorUI 107, UIDOM 98, WebInspectorCore 33, CoreSupport 33, NativeSymbols 31, UIBase 23, NativeTransport 17, UISyntaxBody 12. Total 2,376 package keywords vs 32 public declarations — a 74:1 ratio. Designing the public Core/Transport surface is therefore a from-scratch API design exercise, not a visibility promotion: today zero domain state, zero transport abstraction (TransportSession, TransportBackend, TransportReceiver, ProtocolCommand/ProtocolEvent are all package), and zero session lifecycle API is public.

Locations: Sources/WebInspectorCoreDOMCSS; Sources/WebInspectorCoreConsoleNetwork; Sources/WebInspectorCoreRuntime; Sources/WebInspectorTransport

## Extra

Per-target access-keyword table — raw output of `rg -o '\b(public|package|open)\b' Sources/<Target> --no-filename | sort | uniq -c` (all files in target dir), verbatim:

== WebInspectorCore ==
  36 package
== WebInspectorCoreSupport ==
  33 package
   2 public
== WebInspectorCoreRuntime ==
 262 package
== WebInspectorCoreDOMCSS ==
 911 package
== WebInspectorCoreConsoleNetwork ==
   2 open
 510 package
== WebInspectorNativeBridge ==
   6 public
== WebInspectorNativeSymbols ==
  31 package
   2 public
== WebInspectorTransport ==
 159 package
== WebInspectorNativeTransport ==
  17 package
== WebInspectorUIBase ==
  23 package
== WebInspectorUIDOM ==
   2 open
  98 package
== WebInspectorUINetwork ==
 180 package
== WebInspectorUISyntaxBody ==
  12 package
== WebInspectorUI ==
 107 package
  31 public
== WebInspectorKit ==
   2 public

Swift-only re-run (`-g '*.swift'`) differences and false-positive classification:
- WebInspectorCore: 36 -> 33 package (3 hits are prose in Sources/WebInspectorCore/Docs/ConsoleTransportResearch.md:487,488,513)
- WebInspectorUI: 31 -> 30 public (1 hit is prose in Sources/WebInspectorUI/Docs/ViewControllerStructure.md:15)
- WebInspectorNativeBridge: 6 -> 0 public (C++ 'public:' access specifiers at WebInspectorNativeABI.h:14,36,139 and WebInspectorNativeBridge.mm:513,514; os_log '%{public}@' at WebInspectorNativeBridge.mm:679)
- WebInspectorCoreSupport 2 public = os_log 'privacy: .public' (InspectorRuntimeLog.swift:10,14) — NOT access control
- WebInspectorNativeSymbols 2 public = os_log 'privacy: .public' (NativeInspectorSymbolLog.swift:11,15) — NOT access control
- WebInspectorCoreConsoleNetwork 2 open = enum 'case open' (NetworkModel.swift:31) and '.open' assignment (NetworkModel.swift:896) — NOT access control
- WebInspectorUIDOM 2 open = HTML attribute string literals (DOMTreeMarkup.swift:132,268) — NOT access control

Effective Swift access-control totals: package 2,376 | public declarations 32 | open 0.

Complete public declaration inventory (all 32):
WebInspectorUI (30):
  Sources/WebInspectorUI/Containers/WebInspectorSession.swift:11  public final class WebInspectorSession
  Sources/WebInspectorUI/Containers/WebInspectorSession.swift:17  public private(set) var pageUserInterfaceStyle: UIUserInterfaceStyle
  Sources/WebInspectorUI/Containers/WebInspectorSession.swift:25  public convenience init(tabs: [WebInspectorTab] = [.dom, .network])
  Sources/WebInspectorUI/Containers/WebInspectorSession.swift:58  public func attach(to webView: WKWebView) async throws  [@_disfavoredOverload; always throws AttachmentUnavailableError]
  Sources/WebInspectorUI/Containers/WebInspectorSession.swift:78  public func detach() async
  Sources/WebInspectorUI/Containers/WebInspectorViewController.swift:43  public final class WebInspectorViewController: UIViewController
  Sources/WebInspectorUI/Containers/WebInspectorViewController.swift:49  public let session: WebInspectorSession
  Sources/WebInspectorUI/Containers/WebInspectorViewController.swift:50  public var automaticallyDetachesOnDismiss = true
  Sources/WebInspectorUI/Containers/WebInspectorViewController.swift:66  public var drawsBackground: Bool
  Sources/WebInspectorUI/Containers/WebInspectorViewController.swift:79  public init(session: WebInspectorSession = WebInspectorSession())
  Sources/WebInspectorUI/Containers/WebInspectorViewController.swift:85  public convenience init(tabs: [WebInspectorTab])
  Sources/WebInspectorUI/Containers/WebInspectorViewController.swift:94  public override func viewDidLoad()
  Sources/WebInspectorUI/Containers/WebInspectorViewController.swift:108 public override func viewWillAppear(_:)
  Sources/WebInspectorUI/Containers/WebInspectorViewController.swift:114 public override func viewDidAppear(_:)
  Sources/WebInspectorUI/Containers/WebInspectorViewController.swift:119 public override func viewDidDisappear(_:)
  Sources/WebInspectorUI/Containers/WebInspectorViewController.swift:128 public override func dismiss(animated:completion:)
  Sources/WebInspectorUI/Containers/WebInspectorViewController.swift:147 public override func didMove(toParent:)
  Sources/WebInspectorUI/Containers/WebInspectorViewController.swift:165 public func attach(to webView: WKWebView) async throws  [@_disfavoredOverload]
  Sources/WebInspectorUI/Containers/WebInspectorViewController.swift:169 public func detach() async
  Sources/WebInspectorUI/Tabs/WebInspectorTab.swift:5   public struct WebInspectorTab: Equatable, Hashable, Identifiable
  Sources/WebInspectorUI/Tabs/WebInspectorTab.swift:6   public typealias ID = String
  Sources/WebInspectorUI/Tabs/WebInspectorTab.swift:8   public let id: ID
  Sources/WebInspectorUI/Tabs/WebInspectorTab.swift:9   public let title: String
  Sources/WebInspectorUI/Tabs/WebInspectorTab.swift:10  public let image: UIImage?
  Sources/WebInspectorUI/Tabs/WebInspectorTab.swift:35  public static nonisolated func ==
  Sources/WebInspectorUI/Tabs/WebInspectorTab.swift:39  public nonisolated func hash(into:)
  Sources/WebInspectorUI/Tabs/WebInspectorTab.swift:60  public init(...)  [custom tab]
  Sources/WebInspectorUI/Tabs/WebInspectorTab.swift:73  public init(...)  [custom tab]
  Sources/WebInspectorUI/Tabs/WebInspectorTab.swift:87  public static let dom
  Sources/WebInspectorUI/Tabs/WebInspectorTab.swift:94  public static let network
WebInspectorKit (2):
  Sources/WebInspectorKit/WebInspectorNativeAttachment.swift:8   extension WebInspectorSession { public func attach(to:) }  [working, via WebInspectorNativeTransport]
  Sources/WebInspectorKit/WebInspectorNativeAttachment.swift:16  extension WebInspectorViewController { public func attach(to:) }
All other targets: none.

Product usability matrix (external consumer importing ONLY that product):
  WebInspectorCore        (Package.swift:19-22) -> NO usable API. 0 public decls in target and in all @_exported subtargets.
  WebInspectorNativeBridge(Package.swift:23-26) -> Syntactically yes (ObjC header: WebInspectorNativeBridge class, WebInspectorNativeResolvedSymbols struct, 2 *ForTesting functions); practically no — attachWithResolvedSymbols: needs 6 symbol addresses whose only producer (WebInspectorNativeSymbols) is package-only.
  WebInspectorNativeSymbols(Package.swift:27-30)-> NO usable API (0 public decls).
  WebInspectorTransport   (Package.swift:31-34) -> NO usable API (0 public decls; TransportSession/TransportBackend/ProtocolCommand all package).
  WebInspectorUI          (Package.swift:35-38) -> PARTIAL: 3 types constructible, detach() works, but every public attach(to:) unconditionally throws AttachmentUnavailableError. Cannot inspect anything.
  WebInspectorKit         (Package.swift:39-42) -> YES: the only end-to-end usable product (= @_exported WebInspectorUI + 2 working attach overloads).

Smell verdicts per given rules:
  (a) APPLIES x3 (WebInspectorCore, WebInspectorTransport, WebInspectorNativeSymbols products are package-only pass-throughs; NativeBridge borderline 4th).
  (b) APPLIES weakly: no consumer-only types on provider side; one consumer-lifecycle method retireBackendInteractionForPresentationEnd on Core (AttachedInspection.swift:648) and CoreDOMCSS (DOMSessionProtocolOperations.swift:64) exists solely for WebInspectorUI's root-presentation teardown (WebInspectorUI/Containers/WebInspectorSession.swift:83-90).
  (c) APPLIES x2, load-bearing: WebInspectorCore/AttachedInspection.swift:3-6 re-exports all 4 Core subtargets — measured: 43 files in the 4 UI targets 'import WebInspectorCore', 0 files import any Core subtarget directly, while consumed types are defined in subtargets (DOMSession CoreDOMCSS/DOM/DOMModel.swift:8; NetworkSession CoreConsoleNetwork/Network/NetworkModel.swift:479; RuntimeState CoreRuntime/Runtime/RuntimeModel.swift:412; ConsoleSession CoreConsoleNetwork/Console/ConsoleModel.swift:307; TargetGraph CoreDOMCSS/DOM/TargetGraph.swift:17; CSSSession CoreDOMCSS/CSS/CSSModel.swift:610). WebInspectorKit/WebInspectorKit.swift:1 re-exports WebInspectorUI, held together with the @_disfavoredOverload attach pair.
