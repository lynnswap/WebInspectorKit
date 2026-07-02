# measure:deps

## Summary

Actual imports match the declared Package.swift graph almost everywhere, with 3 notable gaps: (1) WebInspectorKit imports WebInspectorCore without declaring it (works only via same-package transitive visibility); (2) ObservationBridge is declared on all 5 Core-side targets but imported by ZERO of them (only UI targets and tests use it); (3) WebInspectorUI declares WebInspectorTransport but never imports it. Layering Core->Transport->Bridge is clean downward (Transport imports only Foundation; NativeBridge only system headers), but WebInspectorNativeTransport depends upward on WebInspectorCore — the entire native attach orchestration is a package extension on Core's InspectorSession. Tests are overwhelmingly @testable-based (134 @testable statements across 5 test targets; only WebInspectorNativeBridgeTests exercises a public surface), which is forced by the fact that the whole domain layer is package-scoped. The umbrella wires NativeTransport into the UI session via overload shadowing: WebInspectorUI ships a @_disfavoredOverload attach(to:) stub that throws, and WebInspectorKit's public extension with the identical signature wins resolution and injects the native attach through the package-scoped attachPresentation hook.

## Findings

### 1. (a) Undeclared import: WebInspectorKit imports WebInspectorCore

Sources/WebInspectorKit/WebInspectorNativeAttachment.swift:3 'import WebInspectorCore', but the WebInspectorKit target declares only WebInspectorNativeTransport and WebInspectorUI (Package.swift:202-209). The import is load-bearing: it makes InspectorSession visible so the package extension attach(to:) from NativeTransport can be called. Compiles only because SwiftPM does not enforce cross-target import declarations within one package. Also undeclared in test targets: 'import ObservationBridge' in Tests/WebInspectorCoreTests/InspectorSessionTests.swift:2 and 5 files in Tests/WebInspectorUITests (e.g. UITestObservationWaits.swift:2) — neither test target declares the ObservationBridge product (Package.swift:210-223, 276-291).

Locations: Sources/WebInspectorKit/WebInspectorNativeAttachment.swift:3; Package.swift:202; Tests/WebInspectorCoreTests/InspectorSessionTests.swift:2; Tests/WebInspectorUITests/UITestObservationWaits.swift:2

### 2. (b) Declared deps never imported: ObservationBridge on all 5 Core targets, Transport on WebInspectorUI

rg 'ObservationBridge' over Sources/WebInspectorCore{,Support,Runtime,DOMCSS,ConsoleNetwork} returns zero matches, yet ObservationBridge is declared for WebInspectorCore (Package.swift:71), WebInspectorCoreRuntime (:88), WebInspectorCoreDOMCSS (:98), WebInspectorCoreConsoleNetwork (:109). (CoreSupport correctly omits it.) Core targets use plain 'import Observation' + @Observable instead. WebInspectorUI declares WebInspectorTransport (Package.swift:190) but rg 'WebInspectorTransport' over Sources/WebInspectorUI has zero matches. Test-side: WebInspectorUITests declares SyntaxEditorUI (Package.swift:287) but never imports it. Actual ObservationBridge consumers: UIDOM (6 imports), UINetwork (4), UISyntaxBody (1), UI (2), Tests (6). Implication for the rearchitecture: a public Core surface has no ObservationBridge dependency to carry — the declared edges are dead weight and can be dropped.

Locations: Package.swift:71; Package.swift:88; Package.swift:98; Package.swift:109; Package.swift:190; Package.swift:287

### 3. (c) Layering: Transport and Bridge are clean downward; the upward edge is NativeTransport -> Core (declared, structural)

WebInspectorTransport imports only Foundation (10 files, nothing else). WebInspectorNativeBridge (ObjC++) imports only system headers (WebKit, mach, malloc, objc/runtime, ptrauth — Sources/WebInspectorNativeBridge/WebInspectorNativeBridge.mm:1-15). No undeclared backward import exists. However, WebInspectorNativeTransport depends on WebInspectorCore (declared at Package.swift:138) and implements the whole native attach flow as 'package extension InspectorSession { func attach(to webView: WKWebView) }' (Sources/WebInspectorNativeTransport/InspectorSession+NativeAttachment.swift:5-58), calling package-scoped Core session hooks (beginAttachmentRequest, connectAttachment, makeTransportSession — Sources/WebInspectorCore/AttachedInspection.swift:488-525). So the concrete transport is not 'below' Core: it orchestrates Core. For a public Transport surface, this attach orchestration either moves into Core behind a protocol or stays Core-coupled.

Locations: Sources/WebInspectorNativeTransport/InspectorSession+NativeAttachment.swift:5; Package.swift:138; Sources/WebInspectorNativeBridge/WebInspectorNativeBridge.mm:1; Sources/WebInspectorCore/AttachedInspection.swift:488

### 4. @_exported imports: 5 total — WebInspectorCore re-exports its 4 subtargets; WebInspectorKit re-exports WebInspectorUI

Sources/WebInspectorCore/AttachedInspection.swift:3-6 '@_exported import WebInspectorCoreConsoleNetwork / CoreDOMCSS / CoreRuntime / CoreSupport' — so 'import WebInspectorCore' is already an umbrella over the 4 domain modules (all symbols there are package-scoped today, so the re-export currently only matters within the package). Sources/WebInspectorKit/WebInspectorKit.swift:1 '@_exported import WebInspectorUI' — the entire content of the WebInspectorKit umbrella module besides the attach extensions. No @_exported in Tests.

Locations: Sources/WebInspectorCore/AttachedInspection.swift:3; Sources/WebInspectorKit/WebInspectorKit.swift:1

### 5. @testable: 134 statements; every Core/Transport/UI test target is @testable-based; only NativeBridgeTests uses the public surface

Per test target (statements / distinct modules @testable'd): WebInspectorCoreTests 50 / 5 (Core + 4 subtargets, 10 files x 5 each); WebInspectorUITests 75 / 10 (5 Core + 5 UI modules); WebInspectorTransportTests 7 / 6; WebInspectorNativeSymbolsTests 1 / 1; WebInspectorNativeTransportTests 1 / 1; WebInspectorNativeBridgeTests 0 (plain 'import WebInspectorNativeBridge', Tests/WebInspectorNativeBridgeTests/WebInspectorNativeBridgeTests.swift:4). Since tests live in the same package, 'package' symbols are reachable with a plain import — @testable is needed only for internal members, so tests bind to internals, not to any would-be public API. Zero tests exercise the current 3-type public surface. Note also Tests/WebInspectorTestSupport (regular .target under Tests/, Package.swift:238-245): FakeTransportBackend depends only on WebInspectorTransport — an existing seam proving the domain models are testable against a Transport-only fake.

Locations: Tests/WebInspectorNativeBridgeTests/WebInspectorNativeBridgeTests.swift:4; Tests/WebInspectorTestSupport/FakeTransportBackend.swift:2; Package.swift:238

### 6. Umbrella wiring: overload shadowing via @_disfavoredOverload stub in UI + public extension in Kit, through package-scoped attachPresentation hook

Mechanism chain: (1) WebInspectorUI defines a throwing stub '@_disfavoredOverload public func attach(to webView: WKWebView)' that throws AttachmentUnavailableError("Native WKWebView attachment is provided by WebInspectorKit.") (Sources/WebInspectorUI/Containers/WebInspectorSession.swift:57-62, 113-117; VC counterpart at WebInspectorViewController.swift:164-167). (2) WebInspectorKit adds 'extension WebInspectorSession { public func attach(to:) }' with the identical signature but NOT disfavored (Sources/WebInspectorKit/WebInspectorNativeAttachment.swift:7-13, VC at :15-21) — when the consumer imports WebInspectorKit (which @_exports WebInspectorUI), overload resolution picks the Kit version. (3) The Kit version calls the package-scoped hook 'attachPresentation(to:perform:)' (WebInspectorSession.swift:64-76; WebInspectorViewController.swift:157-161 forwards to session), passing closure '{ inspector, webView in try await inspector.attach(to: webView) }' where 'inspector' is the package-scoped InspectorSession (WebInspectorSession.swift:12) and 'attach' is the package extension from WebInspectorNativeTransport (InspectorSession+NativeAttachment.swift:5-58). attachPresentation owns the UI-side lifecycle (page UI-style observer start/stop) around the injected transport attach. Consequence: WebInspectorUI alone cannot attach to a WKWebView at runtime — the dependency injection point is cross-module overload shadowing plus package access, both of which break at a real package boundary.

Locations: Sources/WebInspectorKit/WebInspectorNativeAttachment.swift:7; Sources/WebInspectorUI/Containers/WebInspectorSession.swift:57; Sources/WebInspectorUI/Containers/WebInspectorSession.swift:64; Sources/WebInspectorUI/Containers/WebInspectorViewController.swift:157; Sources/WebInspectorNativeTransport/InspectorSession+NativeAttachment.swift:5

## Extra

Actual import table (rg '^(@attr )?(access )?import ' Sources/<Target> -N --no-filename | sort | uniq -c; sorted desc):

=== WebInspectorCore ===
   1 import WebInspectorTransport
   1 import Observation
   1 import Foundation
   1 @_exported import WebInspectorCoreSupport
   1 @_exported import WebInspectorCoreRuntime
   1 @_exported import WebInspectorCoreDOMCSS
   1 @_exported import WebInspectorCoreConsoleNetwork
=== WebInspectorCoreSupport ===
   5 import WebInspectorTransport
   1 import Synchronization
   1 import OSLog
=== WebInspectorCoreRuntime ===
   3 import WebInspectorTransport
   3 import WebInspectorCoreSupport
   2 import Foundation
   1 import Observation
=== WebInspectorCoreDOMCSS ===
  24 import WebInspectorCoreSupport
  24 import WebInspectorCoreRuntime
  19 import WebInspectorTransport
  14 import Foundation
   7 import Observation
   1 import Synchronization
=== WebInspectorCoreConsoleNetwork ===
   9 import WebInspectorTransport
   9 import WebInspectorCoreSupport
   9 import WebInspectorCoreRuntime
   9 import WebInspectorCoreDOMCSS
   3 import Observation
   3 import Foundation
=== WebInspectorNativeBridge ===
   (no Swift imports; ObjC++: #import <WebKit/WebKit.h>, <malloc/malloc.h>, <mach/mach.h>, <os/log.h>, <objc/runtime.h>, <ptrauth.h>, C++ <atomic>/<vector>/<memory>/<algorithm>/<span>)
=== WebInspectorNativeSymbols ===
  12 import Foundation
  10 import MachOKit
  10 import MachO
   2 import Darwin
   1 import OSLog
=== WebInspectorTransport ===
  10 import Foundation
=== WebInspectorNativeTransport ===
   3 import WebKit
   3 import WebInspectorTransport
   2 import WebInspectorNativeBridge
   1 import WebInspectorNativeSymbols
   1 import WebInspectorCore
   1 import Foundation
=== WebInspectorUIBase ===
   1 import UIKit
   1 import Foundation
=== WebInspectorUIDOM ===
  25 import WebInspectorUIBase
  19 import WebInspectorCore
  19 import UIKit
   6 import ObservationBridge
   3 import Observation
   3 import Foundation
   2 import WebInspectorTransport
   1 import UIHostingMenu
   1 import SwiftUI
=== WebInspectorUINetwork ===
  23 import WebInspectorUIBase
  20 import WebInspectorCore
  11 import UIKit
   9 import Foundation
   4 import ObservationBridge
   2 import SwiftUI
   1 import WebInspectorTransport
   1 import UniformTypeIdentifiers
   1 import UIHostingMenu
   1 import Observation
   1 import ImageIO
   1 import AVFoundation
=== WebInspectorUISyntaxBody ===
   2 import WebInspectorUINetwork
   2 import WebInspectorUIBase
   1 import WebInspectorCore
   1 import UIKit
   1 import SyntaxEditorUI
   1 import ObservationBridge
   1 import Observation
   1 import AVKit
=== WebInspectorUI ===
  12 import UIKit
   9 import WebInspectorUIBase
   3 import WebKit
   3 import WebInspectorUINetwork
   3 import WebInspectorCore
   2 import WebInspectorUIDOM
   2 import ObservationBridge
   1 import WebInspectorUISyntaxBody
   1 import Synchronization
   1 import Observation
=== WebInspectorKit ===
   1 import WebKit
   1 import WebInspectorUI
   1 import WebInspectorNativeTransport
   1 import WebInspectorCore          <- NOT declared in Package.swift:202-209
   1 @_exported import WebInspectorUI

Declared-vs-actual deltas:
(a) undeclared imports: WebInspectorKit -> WebInspectorCore (WebInspectorNativeAttachment.swift:3); tests: ObservationBridge in WebInspectorCoreTests (1 file) and WebInspectorUITests (5 files) without product declaration.
(b) declared but never imported: ObservationBridge in WebInspectorCore/CoreRuntime/CoreDOMCSS/CoreConsoleNetwork (Package.swift:71,88,98,109); WebInspectorTransport in WebInspectorUI (Package.swift:190); SyntaxEditorUI in WebInspectorUITests (Package.swift:287).
(c) layering: no backward imports (Transport: Foundation-only; NativeBridge: system-only). Upward-but-declared edge: WebInspectorNativeTransport -> WebInspectorCore (Package.swift:138), realized as package extension on InspectorSession (InspectorSession+NativeAttachment.swift:5-58).

Plain (non-@testable) package-module imports in Tests: 18x WebInspectorTransport, 4x WebInspectorTestSupport, 1x WebInspectorNativeBridge, 1x WebInspectorNativeSymbolFixtures, 6x ObservationBridge (external).
@testable per test target: WebInspectorCoreTests 50 (5 modules x 10 files); WebInspectorUITests 75 (10 modules); WebInspectorTransportTests 7 (6 modules); WebInspectorNativeSymbolsTests 1; WebInspectorNativeTransportTests 1; WebInspectorNativeBridgeTests 0. Total 134.
