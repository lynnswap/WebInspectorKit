# measure:platform

## Summary

Platform gating in WebInspectorKit is remarkably disciplined: 72 of 155 Swift files carry platform `#if` gates (75 gate occurrences total), and 70 of those 72 are whole-file gates — only 2 files have mid-file platform branches, and only one of those (NetworkStatusSeverity.swift) mixes platform-neutral domain code with UIKit code in a single file. The gating splits cleanly into two regimes: the UI stack gates on `canImport(UIKit)` (57 occurrences) and the NativeSymbols stack gates on `os(iOS) || os(macOS)` (15 occurrences); the five Core targets, Transport, and NativeTransport have ZERO platform gates and zero UIKit/AppKit imports. The whole package builds successfully for macOS (measured: `swift build` on macOS host, Build complete in 48.53s), but a macOS consumer gets nothing usable from Swift: WebInspectorUI and WebInspectorKit compile to publicly-empty modules (proven by a compile probe: `WebInspectorSession` unresolvable on macOS), and Core/Transport/NativeSymbols contain zero `public` Swift declarations on any platform — the only public macOS-usable API today is the raw ObjC `WebInspectorNativeBridge` class. The README claim 'AppKit support is planned to be rebuilt separately' understates how ready the lower layers already are: the entire non-UI stack (Core×5, Transport, NativeTransport, NativeSymbols, NativeBridge) is UIKit-free and macOS-functional — NativeBridge even has 4 deliberate TARGET_OS_OSX code paths with comments saying 'WebInspectorKit drives its own frontend on macOS'. The blocker for an AppKit UI is not platform gating but access control (`package` scoping), which is exactly what the public Core/Transport surface rearchitecture would fix.

## Findings

### 1. 72 gated files; 70 fully gated, only 2 mid-file platform branches

rg -l '^#if (canImport|os)' Sources | wc -l => 72. Nesting-aware classification (script tracking #if/#endif depth, first/last significant line): 70 files have the entire file inside one platform #if with no top-level #else; 0 files use a whole-file #if/#else platform split; 2 files have mid-file branches. Total platform-gate occurrences: 75 = 57x '#if canImport(UIKit)' + 15x '#if os(iOS) || os(macOS)' + 1x '#if os(iOS)' (NativeInspectorSymbolResolverCore.swift:40) + 1x '#if canImport(UIKit) && DEBUG' (DOMTreeTextViewPerformanceCounters.swift:2) + 1x '#if !os(iOS) && !os(macOS)' (NativeInspectorSymbolResolver.swift:108).

Locations: Sources/WebInspectorNativeSymbols/NativeInspectorSymbolResolverCore.swift:40; Sources/WebInspectorUIDOM/Tree/DOMTreeTextViewPerformanceCounters.swift:2

### 2. Mid-file-branch file 1 (the real smell): NetworkStatusSeverity.swift mixes platform-neutral domain enum with UIKit color mapping

Lines 8-16 define platform-neutral `package enum StatusSeverity` (extension of NetworkRequest.Display); line 18 opens `#if canImport(UIKit)` for `var color: UIColor` (systemGreen/systemYellow/...). The severity enum is domain state living in a UI target — for a public Core surface, StatusSeverity belongs with NetworkRequest.Display in CoreConsoleNetwork, with per-toolkit color mapping in each UI layer.

Locations: Sources/WebInspectorUINetwork/NetworkStatusSeverity.swift:4; Sources/WebInspectorUINetwork/NetworkStatusSeverity.swift:18

### 3. Mid-file-branch file 2 (benign): NativeInspectorSymbolResolver.swift is two sequential whole-blocks, not interleaved code

Line 3 `#if os(iOS) || os(macOS)` wraps the real `package enum NativeInspectorSymbolResolver`; line 108 `#if !os(iOS) && !os(macOS)` wraps a duplicate stub enum returning failureReason "WebInspectorTransport is only available on iOS and macOS." / failureKind "unsupported". Given Package.swift declares only .iOS(.v18)/.macOS(.v15), the stub branch is dead code for declared platforms (reachable only when building for undeclared platforms such as tvOS/watchOS/visionOS).

Locations: Sources/WebInspectorNativeSymbols/NativeInspectorSymbolResolver.swift:3; Sources/WebInspectorNativeSymbols/NativeInspectorSymbolResolver.swift:108; Package.swift:15

### 4. The whole package builds for macOS, but every Swift product is publicly empty there — measured, not inferred

`swift build` on macOS host (arm64-apple-macosx): 'Build complete! (48.53s)', all 446 steps including WebInspectorUI, WebInspectorKit, WebInspectorNativeTransport. Probe compile against the macOS-built modules: `import WebInspectorUI; let _ = WebInspectorSession.self` => "error: cannot find 'WebInspectorSession' in scope", while a bare `import WebInspectorUI/WebInspectorKit/WebInspectorCore/WebInspectorTransport` file typechecks (exit=0). Cause: all 12 WebInspectorUI Swift files are fully inside `#if canImport(UIKit)` (false on non-Catalyst macOS); WebInspectorKit is just `@_exported import WebInspectorUI` (WebInspectorKit.swift:1) plus WebInspectorNativeAttachment.swift whose public `attach(to:)` extensions are gated `#if canImport(UIKit)` (line 1). So the 3 public types AND the public attach entry points all vanish on macOS.

Locations: Sources/WebInspectorKit/WebInspectorKit.swift:1; Sources/WebInspectorKit/WebInspectorNativeAttachment.swift:1; Sources/WebInspectorUI/Containers/WebInspectorSession.swift:1

### 5. WebInspectorCore/Transport/NativeSymbols compile on macOS but expose zero public Swift declarations on ANY platform

rg for `public ` declarations across Sources/WebInspectorCore*, WebInspectorTransport, WebInspectorNativeTransport, WebInspectorNativeSymbols returns no matches (exit=1) — every declaration is `package`-scoped (e.g. `package extension InspectorSession` in AttachedInspection.swift, `package enum NativeInspectorSymbolResolver`). WebInspectorCore's only Swift file is AttachedInspection.swift, which `@_exported import`s the 4 Core subtargets — all package-scoped too. A macOS (or iOS) consumer of the WebInspectorCore/WebInspectorTransport library products can import the modules and reach nothing.

Locations: Sources/WebInspectorCore/AttachedInspection.swift:1; Sources/WebInspectorNativeSymbols/NativeInspectorSymbols.swift:1

### 6. WebInspectorNativeBridge is the ONLY public macOS-functional API today, and it was deliberately engineered for macOS

Package.swift:120 `.linkedFramework("AppKit", .when(platforms: [.macOS]))` (defensive — no AppKit import exists in the sources; the .mm imports only WebKit/malloc/mach/os.log/objc-runtime/ptrauth). WebInspectorNativeBridge.mm has 4 TARGET_OS_OSX branches with intentional macOS semantics: line ~668 `return ConnectionType::Remote;` with comment "WebInspectorKit drives its own frontend on macOS and does not create WebKit's local inspector UI"; line ~694 skips invoking `-connect` ("Transport-only attach should not create the local Web Inspector frontend on macOS... destabilizes sandboxed hosts"); line ~484 tolerates a missing inspector object on macOS. Its ObjC public header exposes WebInspectorNativeBridge (initWithWebView:, attachWithResolvedSymbols:error:, sendJSONString:error:, detach) — usable from macOS today, but only at the raw JSON-string protocol level with caller-supplied symbol addresses.

Locations: Package.swift:120; Sources/WebInspectorNativeBridge/WebInspectorNativeBridge.mm:668; Sources/WebInspectorNativeBridge/WebInspectorNativeBridge.mm:694; Sources/WebInspectorNativeBridge/WebInspectorNativeBridge.mm:484; Sources/WebInspectorNativeBridge/include/WebInspectorNativeBridge.h:28

### 7. README AppKit claim vs reality: the AppKit-ready layer already exists; the missing piece is public access, not platform work

README.md:24 "AppKit support is planned to be rebuilt separately." Reality: `rg -l 'import UIKit' Sources/WebInspectorCore* Sources/WebInspectorTransport Sources/WebInspectorNative*` => zero hits. UIKit-free, macOS-compiling targets: WebInspectorCore, CoreSupport, CoreRuntime, CoreDOMCSS, CoreConsoleNetwork (0 platform gates in all 5), WebInspectorTransport (0 gates), WebInspectorNativeTransport (0 gates; imports WebKit which exists on macOS), WebInspectorNativeSymbols (gated os(iOS)||os(macOS) — macOS included), WebInspectorNativeBridge (macOS branches implemented), plus WebInspectorUIBase's ungated localization accessor (its one gated file NetworkContainerSupport.swift is UIKit-only). An AppKit UI could consume all of this as-is EXCEPT that everything is `package`-scoped, so it would have to live inside this package — or the Core/Transport surface must go public, which is the rearchitecture goal. UIKit-bound targets: UIDOM (24/25 files), UINetwork (17/24 + UIKit-importing rest), UISyntaxBody (2/2), UI (12/12), and the iOS-only dependencies UIHostingMenu (Package.swift:160,171) and SyntaxEditorUI (Package.swift:182).

Locations: README.md:24; Package.swift:160; Package.swift:182; Sources/WebInspectorUIBase/NetworkContainerSupport.swift:1; Sources/WebInspectorUIBase/WebInspectorUILocalization.swift:1

### 8. Gate-condition split is a clean two-regime pattern that maps directly onto the future module boundary

UI stack uses `canImport(UIKit)` exclusively (57/75 occurrences) — meaning macOS exclusion is a side effect of toolkit availability, and Mac Catalyst would compile the UIKit UI. Non-UI native stack uses `os(iOS) || os(macOS)` (15/75) — explicitly macOS-inclusive. No file needed cross-regime gating except NetworkStatusSeverity.swift. For the design doc: the existing gate discipline means extracting a public, platform-neutral Core/Transport surface requires moving essentially zero platform-conditional code — only re-scoping access levels and relocating one enum (StatusSeverity).

Locations: Sources/WebInspectorUINetwork/NetworkStatusSeverity.swift:18

## Extra

Per-target platform-gate table (Swift files only; 'gated files' = files containing a top-of-line `#if canImport(...)`/`#if os(...)`; 'occ' = occurrences of that pattern; classification from nesting-aware script):

| Target                        | .swift files | gated files | gate occ | fully gated | mid-file | gate condition used                  | imports UIKit? | compiles macOS | macOS-functional |
|-------------------------------|-------------:|------------:|---------:|------------:|---------:|--------------------------------------|----------------|----------------|------------------|
| WebInspectorCore              | 1            | 0           | 0        | 0           | 0        | (none)                               | no             | yes            | yes (package-only API) |
| WebInspectorCoreSupport       | 7            | 0           | 0        | 0           | 0        | (none)                               | no             | yes            | yes (package-only) |
| WebInspectorCoreRuntime       | 3            | 0           | 0        | 0           | 0        | (none)                               | no             | yes            | yes (package-only) |
| WebInspectorCoreDOMCSS        | 24           | 0           | 0        | 0           | 0        | (none)                               | no             | yes            | yes (package-only) |
| WebInspectorCoreConsoleNetwork| 9            | 0           | 0        | 0           | 0        | (none)                               | no             | yes            | yes (package-only) |
| WebInspectorNativeBridge      | 0 (ObjC++: 1 .mm, 2 .h) | –  | –        | –           | –        | TARGET_OS_OSX x4 in .mm              | no             | yes (+AppKit link, Package.swift:120) | yes — ONLY public API on macOS |
| WebInspectorNativeSymbols     | 16           | 15          | 16       | 15 (1 w/ nested gate) | 1 | os(iOS) \|\| os(macOS); 1x os(iOS); 1x !os(iOS)&&!os(macOS) | no | yes | yes (package-only) |
| WebInspectorTransport         | 16           | 0           | 0        | 0           | 0        | (none)                               | no             | yes            | yes (package-only) |
| WebInspectorNativeTransport   | 3            | 0           | 0        | 0           | 0        | (none; imports WebKit)               | no             | yes            | yes (package-only) |
| WebInspectorUIBase            | 2            | 1           | 1        | 1           | 0        | canImport(UIKit)                     | gated only     | yes            | localization bundle only |
| WebInspectorUIDOM             | 25           | 24          | 24       | 24          | 0        | canImport(UIKit) (1x +DEBUG)         | yes (gated)    | yes (empty)    | no (module empty) |
| WebInspectorUINetwork         | 24           | 17          | 18       | 16          | 1        | canImport(UIKit)                     | yes (gated)    | yes (~empty)   | no (only ungated StatusSeverity enum + MainActorDelayScheduler-adjacent pieces, all package-scoped) |
| WebInspectorUISyntaxBody      | 2            | 2           | 2        | 2           | 0        | canImport(UIKit)                     | yes (gated)    | yes (empty)    | no |
| WebInspectorUI                | 12           | 12          | 12       | 12          | 0        | canImport(UIKit)                     | yes (gated)    | yes (EMPTY — proven by probe) | no |
| WebInspectorKit               | 2            | 1           | 1        | 1           | 0        | canImport(UIKit)                     | via re-export  | yes (publicly empty) | no |
| TOTAL                         | 146 (+3 ObjC)| 72          | 74 (+1 non-top-of-line = 75) | 70 | 2 | 57x canImport(UIKit), 15x os(iOS)\|\|os(macOS), 3x one-offs | — | all | — |

Note on earlier raw counts: `rg --files Sources/<T>` includes non-source files (WebInspectorCore/README.md + 5 Docs files, WebInspectorUI/Docs/*.md, UIBase Localizable.xcstrings); the table above counts .swift only.

Mid-file-branch files (explicit list):
1. Sources/WebInspectorUINetwork/NetworkStatusSeverity.swift — gates at lines 4 (import UIKit) and 18 (UIColor mapping); platform-neutral StatusSeverity enum at lines 8-16 shares the file with UIKit presentation code.
2. Sources/WebInspectorNativeSymbols/NativeInspectorSymbolResolver.swift — gates at lines 3 (os(iOS)||os(macOS), real impl) and 108 (!os(iOS)&&!os(macOS), 'unsupported' stub duplicate of the enum; dead for declared platforms).

macOS build evidence: `swift build --scratch-path <scratch>/.build` on arm64-apple-macosx => 'Build complete! (48.53s)', 446/446 steps. Probe 1: `import WebInspectorUI; let _ = WebInspectorSession.self` => error: cannot find 'WebInspectorSession' in scope. Probe 2: bare imports of WebInspectorUI/WebInspectorKit/WebInspectorCore/WebInspectorTransport => typechecks, exit 0.

Public-API evidence: rg '^\\s*(@...)?public ' over Sources/WebInspectorCore* WebInspectorTransport WebInspectorNativeTransport WebInspectorNativeSymbols => no matches (exit 1). rg -l 'import UIKit' over the same set => no matches (exit 1). NativeTransport is not even a library product (Package.swift products list: Core, NativeBridge, NativeSymbols, Transport, UI, Kit) — it is reachable only through WebInspectorKit.

iOS-only external deps (compile-out on macOS): UIHostingMenu condition .when(platforms:[.iOS]) at Package.swift:160 and :171; SyntaxEditorUI at :182 and :287 (test target).
