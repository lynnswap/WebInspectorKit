# map:consumers

## Summary

The first-consumer story confirms the package is UI-shell-only at its public boundary. The WebInspectorKit umbrella is a 1-line `@_exported import WebInspectorUI` plus one file that grafts the real `attach(to:)` onto the two UI types via package-scoped `attachPresentation`; without the umbrella, `WebInspectorSession.attach` is a `@_disfavoredOverload` that unconditionally throws. Monocly (the only real consumer) uses exactly 6 public symbols — WebInspectorSession(init/attach/detach/pageUserInterfaceStyle) and WebInspectorViewController(init(session:)/automaticallyDetachesOnDismiss/drawsBackground) — and never touches DOM/Network/Console/Runtime state, never passes custom tabs. No test target acts as a public-API contract test for the Swift surface: every Swift test target uses @testable (163 total @testable imports across 5 targets); the only @testable-free target (WebInspectorNativeBridgeTests) tests C `...ForTesting` scenario functions, not the consumer API. The README's custom-tab closure receives a `WebInspectorSession` whose entire usable public surface inside the closure is `pageUserInterfaceStyle` + `detach()` — zero domain access, so a real Console tab is unbuildable outside the package today. MIGRATION.md shows consumers just migrated 0.1.5→0.2.0 through exactly this spot (SwiftUI WITab → UIKit WebInspectorTab, attach rename, removal of all model APIs) and explicitly promises DOM/Network models stay internal 'until an app-facing API is explicitly published' — the rearchitecture is that publication.

## Findings

### 1. Umbrella target = re-export + attach graft (2 files, 24 lines total)

WebInspectorKit.swift is exactly one line: `@_exported import WebInspectorUI`. WebInspectorNativeAttachment.swift adds `extension WebInspectorSession { public func attach(to webView: WKWebView) async throws { try await attachPresentation(to: webView) { inspector, webView in try await inspector.attach(to: webView) } } }` and the identical extension on WebInspectorViewController. It works only because (a) `attachPresentation` is package-scoped on WebInspectorSession (Sources/WebInspectorUI/Containers/WebInspectorSession.swift:64) and `inspector: InspectorSession` is package-scoped (line 12), and (b) `InspectorSession.attach(to: WKWebView)` is a package extension in WebInspectorNativeTransport (Sources/WebInspectorNativeTransport/InspectorSession+NativeAttachment.swift:5-7). So the public 'real attach' exists only inside the package boundary; no external module could replicate it. Note the trap this creates: WebInspectorUI itself declares `@_disfavoredOverload public func attach(to:)` that unconditionally throws AttachmentUnavailableError("Native WKWebView attachment is provided by WebInspectorKit.") (WebInspectorSession.swift:57-62, 113-117) — a consumer importing only the WebInspectorUI product gets a compiling attach that always fails at runtime.

Locations: Sources/WebInspectorKit/WebInspectorKit.swift:1; Sources/WebInspectorKit/WebInspectorNativeAttachment.swift:7-21; Sources/WebInspectorUI/Containers/WebInspectorSession.swift:12; Sources/WebInspectorUI/Containers/WebInspectorSession.swift:57-76; Sources/WebInspectorUI/Containers/WebInspectorSession.swift:113-117; Sources/WebInspectorUI/Containers/WebInspectorViewController.swift:157-161; Sources/WebInspectorNativeTransport/InspectorSession+NativeAttachment.swift:5-12

### 2. Monocly consumes exactly 6 public symbols; zero domain access, zero custom tabs

All Monocly usage: (1) session creation — `let resolvedInspectorSession = inspectorSession ?? WebInspectorSession()` (Monocly/Monocly/Controllers/BrowserRootViewController+UIKit.swift:35), always default tabs, never `init(tabs:)` with custom content; (2) attach/detach — default closures in BrowserInspectorSessionAttachmentLifecycle.swift:79-84: `attachAction: { inspectorSession, webView in try await inspectorSession.attach(to: webView) }, detachAction: { inspectorSession in await inspectorSession.detach() }`, driven by a 300-line app-side state machine (phases detached/attached/attaching/detaching/finalizing…) that Monocly had to write itself because the package exposes no attachment-state observability; (3) presentation — `WebInspectorViewController(session: inspectorSession)` at BrowserInspectorCoordinator.swift:83 (sheet) and BrowserInspectorWindowHostingController+UIKit.swift:53 (separate window), both setting `automaticallyDetachesOnDismiss = false` and (sheet path, iOS 26+) `drawsBackground = false`; (4) the ONLY domain-adjacent read anywhere: `inspectorSession.pageUserInterfaceStyle` observed via withPortableContinuousObservation to tint the sheet (BrowserInspectorCoordinator.swift:274). rg over Monocly/Monocly finds no WebInspectorTab construction and no other WebInspector API — Monocly never reaches DOM/Network/Console/Runtime state because it cannot.

Locations: Monocly/Monocly/Controllers/BrowserRootViewController+UIKit.swift:35-43; Monocly/Monocly/Controllers/BrowserInspectorSessionAttachmentLifecycle.swift:8-9; Monocly/Monocly/Controllers/BrowserInspectorSessionAttachmentLifecycle.swift:76-90; Monocly/Monocly/Presentation/BrowserInspectorCoordinator.swift:83-90; Monocly/Monocly/Presentation/BrowserInspectorCoordinator.swift:262-276; Monocly/Monocly/Controllers/BrowserInspectorWindowHostingController+UIKit.swift:53-54; Monocly/Monocly/Models/BrowserLaunchConfiguration.swift:2

### 3. No public-API contract test exists; 163 @testable imports across 5 Swift test targets

Per-target @testable tally (rg -o '@testable import \w+' | uniq -c): WebInspectorCoreTests = 50 (10 files x @testable Core+CoreSupport+CoreRuntime+CoreDOMCSS+CoreConsoleNetwork); WebInspectorUITests = 75 (7-8 files x @testable Core x5 + UI/UIBase/UIDOM/UINetwork/UISyntaxBody x8); WebInspectorTransportTests = 7; WebInspectorNativeSymbolsTests = 1; WebInspectorNativeTransportTests = 1. Total 163. The single @testable-free target, WebInspectorNativeBridgeTests (plain `import WebInspectorNativeBridge`), exercises C scenario hooks like WebInspectorNativeRunControllerDiscoveryScenarioForTesting — it validates the ObjC discovery heuristics, not the Swift consumer surface. There is NO test target that imports WebInspectorKit, WebInspectorUI, or WebInspectorCore as a plain (non-@testable) product, i.e. nothing in CI compiles the way Monocly or the README compiles. Consequence for the design doc: the current public surface (including the disfavored-overload throw trap) has zero automated coverage from the consumer's side of the boundary.

Locations: Tests/WebInspectorCoreTests; Tests/WebInspectorUITests; Tests/WebInspectorTransportTests; Tests/WebInspectorNativeBridgeTests/WebInspectorNativeBridgeTests.swift:1-6; Package.swift:210-288

### 4. README custom Console tab: the `session` the closure receives can do nothing domain-related — confirmed

README.md:64-76 advertises `WebInspectorTab(id: "app_console", title: "Console", systemImage: "terminal") { session in ConsoleViewController(inspectorSession: session) }`. The closure type is `@MainActor (_ session: WebInspectorSession) -> UIViewController` (Sources/WebInspectorUI/Tabs/WebInspectorTab.swift:64,77). WebInspectorSession's complete public member list (WebInspectorSession.swift): `init(tabs:)` (:25), `pageUserInterfaceStyle: UIUserInterfaceStyle` (:17), `attach(to:)` (:58, disfavored/real via umbrella), `detach()` (:78). Everything domain-shaped is package-scoped: `inspector: InspectorSession` (:12), `interface: InterfaceModel` (:13), `attachment: AttachedInspection` (:53). So inside the closure a consumer can read a UIUserInterfaceStyle enum, re-attach to some WKWebView it already owns, or detach — and nothing else. A 'Console' tab cannot read console messages, evaluate JS, or see any Runtime/Console/Network/DOM state; the README example is unimplementable as advertised. Crisp statement for the doc: the custom-tab extension point injects a session whose public surface is presentation-lifecycle only; 100% of domain state (ConsoleModel, NetworkModel, DOMModel, RuntimeModel behind AttachedInspection) is package-gated one access level away.

Locations: README.md:61-76; Sources/WebInspectorUI/Tabs/WebInspectorTab.swift:20; Sources/WebInspectorUI/Tabs/WebInspectorTab.swift:60-83; Sources/WebInspectorUI/Containers/WebInspectorSession.swift:12-17; Sources/WebInspectorUI/Containers/WebInspectorSession.swift:25; Sources/WebInspectorUI/Containers/WebInspectorSession.swift:53-62; Sources/WebInspectorUI/Containers/WebInspectorSession.swift:78-81

### 5. MIGRATION.md (v0.1.5 -> v0.2.0): consumers just migrated through this exact seam; the doc explicitly defers a public model API

Docs/MIGRATION.md documents what consumers already absorbed: removal of SwiftUI `WebInspectorView`/`WebInspectorModel`/`WebInspectorConfiguration` in favor of WebInspectorViewController/WebInspectorSession (:17-46); rename `attach(webView:)` -> `attach(to:)`, sync `detach()` -> async (:44-46); `suspend()` removed with no replacement (:45); snapshot-depth/subtree-depth/DOM-debounce config removed — 'the native DOM runtime owns those policies' (:66-68); SwiftUI `WITab` builders -> UIKit `WebInspectorTab(id:title:systemImage:makeViewController:)` (:70-103); and section 5 (:105-112) states verbatim: 'DOM and Network command/model surfaces should be treated as internal until an app-facing API is explicitly published.' Design-doc implications: (a) the custom-tab initializer shape and `attach(to:)`/`detach()` names were just stabilized in 0.2.0 — re-breaking them needs strong justification; (b) publishing Core domain state is the pre-announced, expected next step, not a reversal; (c) 0.1.5 consumers previously HAD model/page-agent access and lost it, so the second-app/custom-tab demand is a regression being restored, and the old removed surface (WebInspectorModel, WITab content closures over models) is a known-bad shape to avoid repeating.

Locations: Docs/MIGRATION.md:17-46; Docs/MIGRATION.md:66-68; Docs/MIGRATION.md:70-103; Docs/MIGRATION.md:105-112; README.md:78-88

## Extra

Per-test-target @testable import counts (rg -o --no-filename '@testable import \w+' Tests/<target> | sort | uniq -c):

== WebInspectorCoreTests (10 files)
  10 @testable import WebInspectorCore
  10 @testable import WebInspectorCoreConsoleNetwork
  10 @testable import WebInspectorCoreDOMCSS
  10 @testable import WebInspectorCoreRuntime
  10 @testable import WebInspectorCoreSupport
== WebInspectorNativeBridgeTests
  (none — plain `import WebInspectorNativeBridge`; tests C ...ForTesting scenario functions)
== WebInspectorNativeSymbolsTests
   1 @testable import WebInspectorNativeSymbols
== WebInspectorNativeTransportTests
   1 @testable import WebInspectorNativeTransport
== WebInspectorTransportTests
   1 @testable import WebInspectorCore
   1 @testable import WebInspectorCoreConsoleNetwork
   1 @testable import WebInspectorCoreDOMCSS
   1 @testable import WebInspectorCoreRuntime
   1 @testable import WebInspectorCoreSupport
   2 @testable import WebInspectorTransport
== WebInspectorUITests
   7 @testable import WebInspectorCore
   7 @testable import WebInspectorCoreConsoleNetwork
   7 @testable import WebInspectorCoreDOMCSS
   7 @testable import WebInspectorCoreRuntime
   7 @testable import WebInspectorCoreSupport
   8 @testable import WebInspectorUI
   8 @testable import WebInspectorUIBase
   8 @testable import WebInspectorUIDOM
   8 @testable import WebInspectorUINetwork
   8 @testable import WebInspectorUISyntaxBody
Total @testable imports: 163. Non-test-target dirs under Tests/: WebInspectorTestSupport (FakeTransportBackend over WebInspectorTransport), WebInspectorNativeSymbolFixtures.

Umbrella attach graft, quoted in full (Sources/WebInspectorKit/WebInspectorNativeAttachment.swift):
```swift
#if canImport(UIKit)
import WebKit
import WebInspectorCore
import WebInspectorNativeTransport
import WebInspectorUI

extension WebInspectorSession {
    public func attach(to webView: WKWebView) async throws {
        try await attachPresentation(to: webView) { inspector, webView in
            try await inspector.attach(to: webView)
        }
    }
}

extension WebInspectorViewController {
    public func attach(to webView: WKWebView) async throws {
        try await attachPresentation(to: webView) { inspector, webView in
            try await inspector.attach(to: webView)
        }
    }
}
#endif
```

UI-target throwing decoy it shadows (Sources/WebInspectorUI/Containers/WebInspectorSession.swift:57-62):
```swift
@_disfavoredOverload
public func attach(to webView: WKWebView) async throws {
    try await attachPresentation(to: webView) { _, _ in
        throw AttachmentUnavailableError()   // "Native WKWebView attachment is provided by WebInspectorKit."
    }
}
```

Monocly integration core, quoted (Monocly/Monocly/Controllers/BrowserInspectorSessionAttachmentLifecycle.swift:76-90):
```swift
init(
    browserWindow: BrowserWindow,
    inspectorSession: WebInspectorSession,
    attachAction: @escaping AttachAction = { inspectorSession, webView in
        try await inspectorSession.attach(to: webView)
    },
    detachAction: @escaping DetachAction = { inspectorSession in
        await inspectorSession.detach()
    }
) { ... }
```
Session creation (Monocly/Monocly/Controllers/BrowserRootViewController+UIKit.swift:35): `let resolvedInspectorSession = inspectorSession ?? WebInspectorSession()`
Sheet presentation (Monocly/Monocly/Presentation/BrowserInspectorCoordinator.swift:83-90):
```swift
let sheetController = WebInspectorViewController(session: inspectorSession)
sheetController.automaticallyDetachesOnDismiss = false
if #available(iOS 26.0, *) { sheetController.drawsBackground = false }
sheetController.modalPresentationStyle = .pageSheet
```
Style observation, the ONLY domain-adjacent public read in Monocly (BrowserInspectorCoordinator.swift:274): `self?.applySheetUserInterfaceStyle(inspectorSession.pageUserInterfaceStyle, to: sheet)`

Complete list of package-consuming Monocly files (import WebInspectorKit): BrowserInspectorWindowRegistry.swift, BrowserInspectorCoordinator.swift, BrowserInspectorWindowHostingController+UIKit.swift, BrowserInspectorSessionAttachmentLifecycle.swift, BrowserRootViewController+UIKit.swift, BrowserPageViewController+UIKit.swift, BrowserLaunchConfiguration.swift (7 files; the rest pass WebInspectorSession/WebInspectorViewController around as opaque handles).

WebInspectorViewController public members consumed vs available (Sources/WebInspectorUI/Containers/WebInspectorViewController.swift): available = session(:49), automaticallyDetachesOnDismiss(:50), drawsBackground(:66), init(session:)(:79), init(tabs:)(:85), attach(to:)(:165, decoy), detach()(:169) + UIViewController overrides; Monocly uses init(session:), automaticallyDetachesOnDismiss, drawsBackground. init(tabs:) and the tabs-customization path are consumed by no one (README-only).
