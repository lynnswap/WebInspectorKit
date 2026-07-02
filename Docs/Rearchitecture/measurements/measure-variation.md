# measure:variation

## Summary

Five variation axes leak across Sources/, in descending severity: (1) the protocol-method axis — 137 raw "Domain.method" string literals (76 distinct, 35 repeated) with zero shared constants, and Target lifecycle events re-interpreted at 4 different layers; (2) the attachment-lifecycle axis — the "is the session attached" precondition is re-expressed 14 times across 4 targets with the identical error string duplicated 10 times, despite ProtocolCommandChannel.requireAttached() existing as the designed owner; (3) the async-staleness axis — 9 independent hand-rolled generation/epoch counters; (4) the tab-kind axis — builtIn-vs-custom and the .domElement child-item special case escape the designed BuiltInCatalog absorption point into 5 files (18 mentions), with two separate catalog instances; (5) the platform axis — handled by amputation, not abstraction: 54 of 65 UI-target files (and all 3 public types) are whole-file `#if canImport(UIKit)` gated, so on native macOS the package builds but exports an empty public surface. In-file platform branches are rare; the dominant in-file conditional is `#if DEBUG` (110 occurrences in 37 files) interleaving test instrumentation with production logic. `as?` casts to concrete types are a non-issue (36 total, none repeated ≥3 except UIKit config casts). Domain event dispatch itself has a well-designed absorption point (ProtocolDomainEventDispatcherRegistry, single registration site) — the leakage is everything that bypasses it.

## Findings

### 1. Protocol method-string axis: 137 raw literals, 76 distinct, 35 duplicated, no constants anywhere

rg -o '"(DOM|Network|Runtime|Console|CSS|Target|Page|Inspector)\.[A-Za-z]+"' Sources --type swift => 137 literals / 76 distinct / 35 appearing >=2x. Top repeats: Target.didCommitProvisionalTarget x8 (4 files), CSS.styleSheetAdded x6, Target.targetDestroyed x5, Runtime.executionContextCreated x5, CSS.styleSheetRemoved x5, Target.targetCreated x4. rg -n 'static let.*"(DOM|Network|...)\.' Sources => 0 hits (no method-name constants exist). Method->domain mapping IS centralized once: ProtocolDomain(method:) splits on '.' prefix.

Locations: Sources/WebInspectorTransport/TransportTypes.swift:16; Sources/WebInspectorTransport/TransportSession.swift:466; Sources/WebInspectorCoreDOMCSS/Target/TargetProtocolDispatching.swift:70

### 2. Target lifecycle events interpreted at 4 separate layers by re-matching the same strings

"Target.didCommitProvisionalTarget" matched at: TransportSession.swift:478,623,640 (registry mutation + provisional message replay); TargetProtocolDispatching.swift:84,99 (Core dispatcher); DOMSessionProtocolOperations.swift:1468 (element-picker interruption, plus its own private TargetProtocolEventDispatcher() at line 1083); AttachedInspection.swift:845,858 (post-dispatch bootstrap/runtime-console re-enable, checking event.method AFTER the registry already dispatched it). Same pattern for Target.targetDestroyed (TransportSession.swift:472,638; TargetProtocolDispatching.swift:80,114; DOMSessionProtocolOperations.swift:1458). The semantics of a target commit (retarget replies, retarget stylesheets, retarget runtime contexts, clear picker, re-bootstrap DOM) have no single owner — each layer re-derives its slice from the raw method string.

Locations: Sources/WebInspectorTransport/TransportSession.swift:466-497; Sources/WebInspectorCoreDOMCSS/Target/TargetProtocolDispatching.swift:70-115; Sources/WebInspectorCoreDOMCSS/DOM/DOMSessionProtocolOperations.swift:1449-1482; Sources/WebInspectorCore/AttachedInspection.swift:845-872

### 3. Attachment precondition re-expressed 14 times across 4 targets; identical error string duplicated 10 times

rg -n 'guard commandChannel != nil|guard let commandChannel' Sources --type swift => 14 sites in 5 files (DOMSessionProtocolOperations x9, ConsoleModel:481, NetworkModel:994, RuntimeModel:1020, CSSStyleRefreshCoordinator:218). rg -n --fixed-strings '"Inspector session is not attached."' Sources => 10 sites in 5 files across CoreSupport/CoreRuntime/CoreDOMCSS/CoreConsoleNetwork. The designed owner exists — ProtocolCommandChannel.requireAttached() (ProtocolCommandChannel.swift:40-44) — but only 5 call sites use it (rg 'requireAttached' => ConsoleModel:485, NetworkModel:997, CSSStyleRefreshCoordinator:221, DOMSessionProtocolOperations:1575, RuntimeModel:1024); the other sites hand-roll 'guard commandChannel != nil else { throw InspectorError("Inspector session is not attached.") }' e.g. DOMSessionProtocolOperations.swift:800-802,810-812,835-837,1581-1583. Two competing forms of the same invariant. (Contrast: the connection state machine itself is well-owned by InspectorConnectionPhase, AttachedInspection.swift:266-312, and isAttached is injected once into ProtocolCommandChannel at AttachedInspection.swift:1029-1033.)

Locations: Sources/WebInspectorCoreSupport/ProtocolCommandChannel.swift:40; Sources/WebInspectorCoreDOMCSS/DOM/DOMSessionProtocolOperations.swift:800; Sources/WebInspectorCoreDOMCSS/DOM/DOMSessionProtocolOperations.swift:835; Sources/WebInspectorCoreRuntime/Runtime/RuntimeModel.swift:1020; Sources/WebInspectorCoreConsoleNetwork/Console/ConsoleModel.swift:481; Sources/WebInspectorCoreConsoleNetwork/Network/NetworkModel.swift:994; Sources/WebInspectorCoreDOMCSS/CSS/CSSStyleRefreshCoordinator.swift:217-223

### 4. Async-staleness axis: 9 independent hand-rolled generation/epoch counters across Core and UI

rg -n 'var .*[gG]eneration.*(UInt64|Int)|[gG]eneration \+= 1|&\+= 1' Sources --type swift. Distinct implementations of the same 'am I still current' predicate: AttachedInspection.attachRequestGeneration (AttachedInspection.swift:379,630,635); DOMSessionControllers has TWO in one file (nextGeneration:27/120 and operation-queue generation:635/666 with isCurrent(_:UInt64) at 674); TransportReceiver.generation (TransportReceiver.swift:10,66); WebInspectorPageUserInterfaceStyleObserver.generation (140, isCurrent at 144); DOMTreeRenderedRowsBuilder.generation (20,78); NetworkMediaPreviewCoordinator.generation (195,216); NetworkTextPreviewCoordinator.generation (88,133); DOMElementViewController.styleRenderGeneration (370); NetworkBodyViewController.revision (668). Same shape (UInt64 counter + equality check after await) reinvented in 5 different targets with no shared primitive.

Locations: Sources/WebInspectorCore/AttachedInspection.swift:379; Sources/WebInspectorCoreDOMCSS/DOM/DOMSessionControllers.swift:635-674; Sources/WebInspectorCoreSupport/TransportReceiver.swift:10; Sources/WebInspectorUI/Containers/WebInspectorPageUserInterfaceStyleObserver.swift:140-144; Sources/WebInspectorUIDOM/Tree/DOMTreeRenderedRowsBuilder.swift:20; Sources/WebInspectorUINetwork/Detail/NetworkMediaPreviewCoordinator.swift:195; Sources/WebInspectorUINetwork/Detail/NetworkTextPreviewCoordinator.swift:88

### 5. Tab-kind axis: builtIn/custom predicate at 8 sites and the .domElement special case escapes the BuiltInCatalog absorption point into 5 files

rg -nF 'builtIn == nil' => 3 (WebInspectorSession.swift:242,257; TabModels.swift:170); rg -nF 'builtIn != nil' => 2 (WebInspectorSession.swift:252,266); guard-let form at BuiltInTabControllers.swift:54; switch over BuiltIn at BuiltInTabControllers.swift:61-67 (the designed table, only .dom/.network). Leakage: 'catalog.controller(for: WebInspectorTab.BuiltIn.dom)' hard-coded 3x for the .domElement display item (BuiltInTabControllers.swift:109,158; TabModels.swift:178) even though .domElement(parent:) carries a parent tab ID that these lookups ignore; 'domElement' mentioned 18x in 5 WebInspectorUI files (rg -c 'domElement' Sources/WebInspectorUI => 18); domElementID/customTabID ID-scheme mapping re-derived in WebInspectorSession.selectedTab (238-247), isValidItemID (250-263), displayItem(for:) (265-270), and TabModels.resolvedSelection (144-147). Also two independent BuiltInCatalog instances exist (DisplayProjection at TabModels.swift:116, ContentFactory static at BuiltInTabControllers.swift:74), each constructing its own DOMTabController/NetworkTabController.

Locations: Sources/WebInspectorUI/Containers/WebInspectorSession.swift:238-270; Sources/WebInspectorUI/Tabs/TabModels.swift:144-178; Sources/WebInspectorUI/Tabs/BuiltInTabControllers.swift:53-67; Sources/WebInspectorUI/Tabs/BuiltInTabControllers.swift:108-121; Sources/WebInspectorUI/Tabs/WebInspectorTab.swift:28-33

### 6. Platform axis handled by whole-file amputation: 54/65 UI files and all 3 public types are canImport(UIKit)-gated; macOS gets an empty public surface

58 occurrences of '#if canImport(UIKit)' in 57 files (rg -c). Per target (files gated at line 1 / total): WebInspectorUI 12/12, WebInspectorUIBase 1/2, WebInspectorUIDOM 23/25, WebInspectorUINetwork 16/24, WebInspectorUISyntaxBody 2/2. All three public types sit inside these gates (WebInspectorTab.swift:1, WebInspectorSession.swift:1, WebInspectorViewController.swift:1), so with declared platform macOS 15 the package compiles on macOS but exports nothing — the future-AppKit axis is currently absorbed by deleting the API per platform. In-file platform branches are rare and localized: NetworkStatusSeverity.swift:4,18 (two gates in one shared file — UIColor extension split from the platform-neutral enum) and NativeInspectorSymbolResolverCore.swift:40-49 (#if os(iOS)/#else inside an os(iOS)||os(macOS) file). Counter-signal for extraction: 7 WebInspectorUINetwork files are already platform-neutral (NetworkPanelModel.swift, NetworkPanelDisplayIndex.swift, NetworkRequest+Display.swift, NetworkResourceFilter.swift, NetworkDisplayURLSummary.swift, NetworkMediaPreviewSupport.swift, NetworkPreviewFixtures.swift).

Locations: Sources/WebInspectorUI/Tabs/WebInspectorTab.swift:1; Sources/WebInspectorUI/Containers/WebInspectorSession.swift:1; Sources/WebInspectorUINetwork/NetworkStatusSeverity.swift:4-35; Sources/WebInspectorNativeSymbols/NativeInspectorSymbolResolverCore.swift:40-49

### 7. Build-config axis: 110 '#if DEBUG' blocks in 37 files interleave *ForTesting instrumentation with production logic

rg -c --fixed-strings '#if DEBUG' Sources --type swift => 110 occurrences / 37 files. Worst files: DOMTreeTextView.swift 15 blocks, DOMElementViewController.swift 11, NetworkDetailViewController.swift 11, DOMTreeRenderedRowsBuilder.swift 10, NetworkBodyViewController.swift 8. These are not whole-file preview gates: e.g. DOMElementViewController.applySnapshotUpdate (lines ~235-280) contains 7 #if DEBUG blocks threading lastSnapshotApplyModeForTesting/styleSnapshotApplyCountForTesting/finishStyleRenderForTesting through every branch of the production apply path, including an #else that changes which 'shouldAnimateSnapshot' expression compiles. Test observability has no owner, so every observation point is an inline conditional in shipped code.

Locations: Sources/WebInspectorUIDOM/Element/DOMElementViewController.swift:235-280; Sources/WebInspectorUIDOM/Tree/DOMTreeTextView.swift:101; Sources/WebInspectorUINetwork/Detail/NetworkDetailViewController.swift:11

### 8. DOM command intent->method-name mapping exists twice

DOMProtocolDispatching.swift:12-83 builds ProtocolCommand with method strings per intent ("DOM.getDocument", "DOM.requestChildNodes", ... "DOM.redo"); DOMSessionProtocolOperations.swift:371-394 re-declares the identical 10-entry switch DOMCommand.Intent -> string in teardownCommandMethodName(for:). Accounts for 10 of the 'x2' duplicated literals (DOM.getDocument, DOM.requestChildNodes, DOM.requestNode, DOM.highlightNode, DOM.hideHighlight, DOM.setInspectModeEnabled, DOM.getOuterHTML, DOM.removeNode, DOM.undo, DOM.redo). Adding a DOM command requires editing both switches.

Locations: Sources/WebInspectorCoreDOMCSS/DOM/DOMProtocolDispatching.swift:12-83; Sources/WebInspectorCoreDOMCSS/DOM/DOMSessionProtocolOperations.swift:371-394

### 9. Remote-error semantics parsed from message strings at 2 sites; transport errors synthesized by 3 non-transport layers

isUnsupportedProtocolCommandError (ProtocolCommandErrors.swift:3-29) matches 8 lowercase substrings ('unknown command', 'not implemented', ...) to classify remoteError; CSSStyleRefreshCoordinator.shouldRetryAfterEnablingCSSAgent (CSSStyleRefreshCoordinator.swift:206-215) independently pattern-matches remoteError message ('enable'/'enabled') + method.hasPrefix("CSS."). TransportSession.Error.transportClosed is thrown outside Transport at ProtocolCommandChannel.swift:49,59, AttachedInspection.swift:1067, and NativeInspectorBackend.swift:41 — Core layers impersonate transport failures because there is no Core-level 'session ended' error. as?-cast axis otherwise minor: 36 casts total in all of Sources; only as? TransportSession.Error (x2: CSSStyleRefreshCoordinator.swift:40, DOMSessionProtocolOperations.swift:242, plus 'case let error as' at 1415) touches cross-module concrete types.

Locations: Sources/WebInspectorCoreSupport/ProtocolCommandErrors.swift:3-29; Sources/WebInspectorCoreDOMCSS/CSS/CSSStyleRefreshCoordinator.swift:206-215; Sources/WebInspectorCoreSupport/ProtocolCommandChannel.swift:49; Sources/WebInspectorNativeTransport/NativeInspectorBackend.swift:41

### 10. Contrast — the one designed absorption point: domain event dispatch registry with a single registration site

ProtocolDomainEventDispatcherRegistry (ProtocolDomain+Dispatching.swift:11-33) keys dispatchers by ProtocolDomain; all 7 domain dispatchers register at exactly one site (AttachedInspection.swift:476-484: Target, Runtime, Console, DOM, Inspector, CSS, Network). Per-domain method switches live in one *ProtocolDispatching.swift file each. This is the pattern the leaking axes above should converge to; the design doc can cite it as the in-repo precedent. Remaining wart inside it: DOMSessionProtocolOperations.swift:1083 constructs a second private TargetProtocolEventDispatcher() outside the registry, and TransportSession's own event switches (targetIDForRootEvent, TransportSession.swift:634-661) duplicate the routing decision with 4 scattered '?? targetRegistry.currentMainPageTargetID' fallbacks (lines 644,646,656,698).

Locations: Sources/WebInspectorCoreSupport/ProtocolDomain+Dispatching.swift:11-33; Sources/WebInspectorCore/AttachedInspection.swift:474-485; Sources/WebInspectorCoreDOMCSS/DOM/DOMSessionProtocolOperations.swift:1083; Sources/WebInspectorTransport/TransportSession.swift:634-661

### 11. Preview scaffolding re-implements the wire protocol by string-matching in a UI target

DOMElementViewController+Preview.swift fakes a backend by matching raw command strings: case "CSS.setStyleText" (250), "CSS.getMatchedStylesForNode" (257), "CSS.getInlineStylesForNode" (259), "CSS.getComputedStyleForNode" (261), envelope.method == "Target.sendMessageToTarget" (321), and a hand-written Target.targetCreated JSON fixture (172). Protocol semantics duplicated into WebInspectorUIDOM solely for previews — a fourth place (after Transport, Core dispatchers, AttachedInspection) that breaks when a method string changes.

Locations: Sources/WebInspectorUIDOM/Element/DOMElementViewController+Preview.swift:172; Sources/WebInspectorUIDOM/Element/DOMElementViewController+Preview.swift:250-261; Sources/WebInspectorUIDOM/Element/DOMElementViewController+Preview.swift:321

## Extra

Re-measurement commands (run from repo root /Users/kn/Dev/WebInspectorKit):

# 1. Tab-kind predicate
rg -n --fixed-strings 'builtIn == nil' Sources        # 3 hits
rg -n --fixed-strings 'builtIn != nil' Sources        # 2 hits
rg -c 'domElement' Sources/WebInspectorUI             # 18 total in 5 files
rg -n 'controller\(for: WebInspectorTab\.BuiltIn\.dom\)' Sources   # 3 hits

# 2. Method-string literals
rg -o '"(DOM|Network|Runtime|Console|CSS|Target|Page|Inspector)\.[A-Za-z]+"' Sources --type swift | awk -F'"' '{print $2}' | sort | uniq -c | sort -rn
# => 137 literals, 76 distinct, 35 with count>=2
rg -n 'switch (event\.method|method)\b' Sources       # 13 switch sites (9 in *ProtocolDispatching.swift/DOMSessionProtocolOperations, 4 in TransportSession)
rg -n 'event\.method == |method == "' Sources         # 12 equality guards + 2 preview/fixture

# 3. Lifecycle predicates
rg -n 'guard commandChannel != nil|guard let commandChannel' Sources   # 14
rg -n --fixed-strings '"Inspector session is not attached."' Sources   # 10
rg -n 'requireAttached' Sources                        # 1 def + 5 call sites
rg -n 'var .*[gG]eneration.*(UInt64|Int)|[gG]eneration \+= 1|&\+= 1' Sources  # generation counters

# 4. Casts
rg -n ' as\? ([A-Z][A-Za-z]+)' Sources -o -r '$1' | awk -F: '{print $NF}' | sort | uniq -c | sort -rn   # 36 total, max 3 per type

# 5. Platform / build-config axis
rg -c --fixed-strings '#if canImport(UIKit)' Sources --type swift   # 58 in 57 files
rg -c --fixed-strings '#if DEBUG' Sources --type swift              # 110 in 37 files

Duplicated method-string table (count / string / files):
8  Target.didCommitProvisionalTarget  — TransportSession(3), TargetProtocolDispatching(2), AttachedInspection(2), DOMSessionProtocolOperations(1)
6  CSS.styleSheetAdded                — TransportSession(5), CSSProtocolDispatching(1)
5  Target.targetDestroyed             — TransportSession(2), TargetProtocolDispatching(2), DOMSessionProtocolOperations(1)
5  Runtime.executionContextCreated    — TransportSession(4), RuntimeProtocolDispatching(1)
5  CSS.styleSheetRemoved              — TransportSession(4), CSSProtocolDispatching(1)
4  Target.targetCreated               — TransportSession(2), TargetProtocolDispatching(1), Preview fixture(1)
3  Runtime.enable / Console.enable    — command factory + AttachedInspection supportsCommand probe + isUnsupportedProtocolCommandError check
2x each: 10 DOM command methods (DOMProtocolDispatching factory vs teardownCommandMethodName), 4 CSS commands (CSSProtocolDispatching factory vs DOMElementViewController+Preview fake backend)

UI-target platform gating (files gated at line 1 with #if canImport(UIKit) / total files):
WebInspectorUI 12/12, WebInspectorUIBase 1/2, WebInspectorUIDOM 23/25, WebInspectorUINetwork 16/24, WebInspectorUISyntaxBody 2/2.
Platform-neutral WebInspectorUINetwork files (candidate shared display-model layer): NetworkPanelModel.swift, NetworkPanelDisplayIndex.swift, NetworkRequest+Display.swift, NetworkResourceFilter.swift, NetworkDisplayURLSummary.swift, NetworkMediaPreviewSupport.swift, NetworkPreviewFixtures.swift.
