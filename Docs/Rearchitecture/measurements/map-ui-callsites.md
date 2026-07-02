# map:ui-callsites

## Summary

The built-in UI's de-facto Core contract is DOM + Network only: UI targets never touch attachment.targetGraph/.runtime/.console (0 hits), while consuming 30 distinct DOMSession members (of ~129 package members, ~23%) and 7 of 30 NetworkSession members. Wiring is uniform: tab controllers pull `session.inspector` (InspectorSession) and `session.attachment` (AttachedInspection) — both package — and inject them into view controllers, which then reach domain sessions via `inspection.dom` / `inspection.network`. The consumed surface splits cleanly into (a) a generic contract any tab needs — @Observable state + revision counters + query reads + async commands + model value types (DOMNode, NetworkRequest, NetworkBody, CSS types, all `package`) — and (b) built-in-UI plumbing: since-cursor render-diff projections (changes(since:), treeRenderInvalidation(since:), requestDisplayChanges(after:)), presentation-lifecycle hooks (setSelectedNodeStyleHydrationActive, retireBackendInteractionForPresentationEnd), the InterfaceModel cache layer, and preview-only protocol-event injectors (apply*/bindProtocolChannel). Chief Demeter pain: DOMNavigationItems chains `inspector.attachment.dom.*` at 7 sites, NetworkTabController round-trips `session.interface.networkPanelModel(for: session.attachment)`, and network detail views read raw protocol payload structs 3 levels deep (`request.request.headers`, `request.metrics?.remoteAddress`). Critically, a custom WebInspectorTab today receives WebInspectorSession whose only public members are pageUserInterfaceStyle/attach/detach — external tabs cannot reach ANY domain state; built-in tabs work only via package access.

## Findings

### 1. Wiring: tab controllers obtain domain sessions via package properties session.inspector / session.attachment

WebInspectorSession holds `package let inspector: InspectorSession` and a flattening passthrough `package var attachment: AttachedInspection { inspector.attachment }`. DOMTabController injects both: `DOMSplitViewController(treeViewController: cachedTreeViewController(session:), elementViewController: ..., inspection: session.attachment, inspector: session.inspector)` and `DOMTreeViewController(inspection: session.attachment)`. NetworkTabController: `let model = session.interface.networkPanelModel(for: session.attachment)`; InterfaceModel then builds `NetworkPanelModel(network: inspection.network) { [weak inspection] id in await inspection?.network.fetchResponseBody(for: id) }` and caches it keyed by `networkPanelModel.network === inspection.network`. Domain access root is AttachedInspection: `package let dom: DOMSession / network: NetworkSession / runtime: RuntimeState / console: ConsoleSession / targetGraph: TargetGraph`.

Locations: Sources/WebInspectorUI/Containers/WebInspectorSession.swift:12; Sources/WebInspectorUI/Containers/WebInspectorSession.swift:53-55; Sources/WebInspectorUI/DOMTabController.swift:70-101; Sources/WebInspectorUI/NetworkTabController.swift:35; Sources/WebInspectorUI/Containers/WebInspectorSession.swift:207-218; Sources/WebInspectorCore/AttachedInspection.swift:322-341

### 2. De-facto contract covers only DOM + Network: runtime/console/targetGraph have zero UI consumers

rg for `targetGraph.|runtime.|console.` member accesses across all four UI targets returns nothing; `AttachedInspection.reset()` is also never called from UI. RuntimeState and ConsoleSession exist in Core (Sources/WebInspectorCoreRuntime/Runtime/RuntimeModel.swift, Sources/WebInspectorCoreConsoleNetwork/Console/ConsoleModel.swift) but the built-in UI exercises none of it — the public Core surface for Console/Runtime cannot be derived from existing consumers and must be designed fresh.

Locations: Sources/WebInspectorCore/AttachedInspection.swift:323-327

### 3. DOMSession de-facto surface: 30 distinct production members of ~129 package members (~23%)

Measured by rg over UI targets, excluding localization-key false positives (e.g. "dom.tree.*" string keys) and preview fixtures. Observed state: selectedNodeID(10 sites), selectionRevision(5), isSelectingElement(4), currentPageRootNode(4), treeRevision(2), canReloadDocument(3), canBeginElementPicker(2), canDeleteSelectedNode(1), hasPendingSelectionRequest(1), elementStyles(3)→CSSSession.selectedNodeStyles/selectedPhase. Queries: node(for:)(13), hasUnloadedRegularChildren(2), selectorPath(2), xPath(2), visibleDOMTreeChildren(1), currentPageTargetID(1). Commands: selectNode(2), requestChildNodes(1), highlightNode(1), restoreSelectedNodeHighlightOrHide(1), toggleElementPicker(1), reloadDocument(1), deleteNodes(1), deleteSelectedNode(1), copyNodeText(1), ensureDocumentLoaded(1), requestSetCSSProperty(1). Declarations e.g. DOMModel.swift:822 `package var selectedNodeID`, :939 `package func node(for:)`, DOMSessionProtocolOperations.swift:707 `package func toggleElementPicker()`, DOMSessionAvailability.swift:4-20 canReloadDocument/canBeginElementPicker/canDeleteSelectedNode.

Locations: Sources/WebInspectorCoreDOMCSS/DOM/DOMModel.swift:822-1140; Sources/WebInspectorCoreDOMCSS/DOM/DOMSessionProtocolOperations.swift:433-925; Sources/WebInspectorCoreDOMCSS/DOM/DOMSessionAvailability.swift:4-20; Sources/WebInspectorUIDOM/Tree/DOMTreeTextView.swift:39; Sources/WebInspectorUIDOM/Tree/DOMTreeMenu.swift:14

### 4. NetworkSession de-facto surface: 7 of 30 package members; all consumption funneled through UI-side NetworkPanelModel

Production members: orderedRequestIDs (NetworkPanelModel.swift:66,86), request(for:) (:82,104,108 + NetworkPanelDisplayIndex 4 sites), requestTopologyRevision (:75,95), requestDisplayRevision (:76,96), requestDisplayChanges(after:) (NetworkPanelDisplayIndex.swift:153), reset() (NetworkPanelModel.swift:145), fetchResponseBody(for:) (via closure, WebInspectorSession.swift:214). Declarations: NetworkModel.swift:479-580. NetworkPanelModel/NetworkPanelDisplayIndex (WebInspectorUINetwork) are the filtering/search/selection projection layer — selection (selectedRequestID), searchText, and resource filters live UI-side, NOT in Core; a redesign must decide whether that projection ships as public Core-adjacent API or stays per-consumer.

Locations: Sources/WebInspectorUINetwork/NetworkPanelModel.swift:36-150; Sources/WebInspectorUINetwork/NetworkPanelDisplayIndex.swift:153; Sources/WebInspectorCoreConsoleNetwork/Network/NetworkModel.swift:479-580

### 5. InspectorSession de-facto UI surface is tiny: 5 members + init; the rest is transport-facing

UI uses: attachment (passthrough + 7 deep chains), detach() (WebInspectorSession.swift:33), retireBackendInteractionForPresentationEnd() (:86, presentation lifecycle), canReloadPage + reloadPage() (DOMNavigationItems.swift:122,128-131; declared AttachedInspection.swift:712,720), init()/init(attachment:) (WebInspectorSession.swift:26, DOMSplitViewController.swift:21). UI never touches hasActiveConnection, lastError, connect/makeTransportSession/beginAttachmentRequest/detachForAttachmentRequest/waitUntil* — those serve WebInspectorNativeTransport/WebInspectorKit, confirming a natural split between a consumer-facing session API and a transport-attachment SPI.

Locations: Sources/WebInspectorCore/AttachedInspection.swift:367-746; Sources/WebInspectorUI/Containers/WebInspectorSession.swift:26-90; Sources/WebInspectorUIDOM/DOMNavigationItems.swift:122-131

### 6. Model value types are the bulk of the de-facto contract and are all `package` — zero public declarations exist in any Core target

rg -c 'public ' over WebInspectorCore/CoreSupport/CoreRuntime/CoreDOMCSS/CoreConsoleNetwork returns no matches. Reference counts in UI targets: NetworkRequest 182, DOMNode 131, CSSStyle 45, NetworkBody 43, CSSProperty 36, NetworkSession 22, DOMSession 21, InspectorSession 15, AttachedInspection 14, CSSRule 12, DOMTree 10, CSSNodeStyles 7. Fields read: DOMNode.{id, localName, nodeName, nodeValue, nodeType, pseudoType, shadowRootType, attributes, parentID, regularChildKnownCount, isTemplateContent}; NetworkRequest.{id, url, method, resourceType, requestBody, responseBody, canFetchResponseBody} plus nested payloads; NetworkBody.{phase, role, full, isBase64Encoded, textRepresentation, textRepresentationSyntaxKind, SyntaxKind, FetchError}; CSSNodeStyles.{sections, phase}, CSSProperty.{name, value, priority, isEnabled, isOverridden, isEditable, isModifiedByInspector, status, text, id}. Import density: 19/25 WebInspectorUIDOM files, 20/24 WebInspectorUINetwork files, 1/2 UISyntaxBody, 3/12 WebInspectorUI import WebInspectorCore.

Locations: Sources/WebInspectorCoreDOMCSS/DOM/DOMModelTypes.swift:370; Sources/WebInspectorCoreConsoleNetwork/Network/NetworkModel.swift:58; Sources/WebInspectorCoreConsoleNetwork/Network/NetworkBody.swift:74; Sources/WebInspectorCoreDOMCSS/CSS/CSSModel.swift:24-610

### 7. Any-tab members vs built-in-UI plumbing: since-cursor diff projections and lifecycle hooks are plumbing, not contract

Generic (any tab needs): observable state + revision counters (selectedNodeID/selectionRevision/treeRevision; requestTopologyRevision/requestDisplayRevision), queries (node(for:), request(for:), orderedRequestIDs, selectorPath/xPath), async commands (selectNode, requestChildNodes, highlightNode, toggleElementPicker, deleteNodes, copyNodeText, reloadDocument/reloadPage, fetchResponseBody, requestSetCSSProperty), model types. Built-in plumbing: DOMSession.changes(since:) (DOMModel.swift:192), treeRenderInvalidation(since:) (:211), domTreeRenderSnapshot() (:907), currentDOMTreeRenderRootNodeID (:897), treeProjection(rootTargetID:) (:1229) — all feed DOMTreeTextView's TextKit diff pipeline; NetworkSession.requestDisplayChanges(after:) feeds NetworkPanelDisplayIndex's cache; setSelectedNodeStyleHydrationActive (DOMSessionProtocolOperations.swift:913) gates style hydration on view appearance (DOMElementViewController.swift:68,72); InspectorSession.retireBackendInteractionForPresentationEnd; InterfaceModel entirely (tab projection + content cache + NetworkPanelModel cache). Preview/test-only backdoors used by UI fixtures: DOMSession.applyTargetCreated/bindProtocolChannel (DOMPreviewFixtures.swift:10, DOMElementViewController+Preview.swift:22,78), NetworkSession.applyRequestWillBeSent/applyResponseReceived/applyDataReceived/applyLoadingFinished (NetworkPreviewFixtures.swift:169-208) — external consumers building previews/tests will need an equivalent sanctioned fixture path.

Locations: Sources/WebInspectorCoreDOMCSS/DOM/DOMModel.swift:192-211; Sources/WebInspectorCoreDOMCSS/DOM/DOMModel.swift:897-1229; Sources/WebInspectorUINetwork/NetworkPreviewFixtures.swift:169-208; Sources/WebInspectorUIDOM/Element/DOMElementViewController.swift:66-74

### 8. Law-of-Demeter pain point 1: DOMNavigationItems chains inspector.attachment.dom.* at 7 sites for both reads and commands

`let dom = inspector.attachment.dom` (:53, :157); `attributes: (inspector.canReloadPage || inspector.attachment.dom.canReloadDocument)` (:122); `try? await inspector.attachment.dom.reloadDocument()` (:131); `inspector.attachment.dom.canDeleteSelectedNode` (:141); `try? await inspector?.attachment.dom.deleteSelectedNode(undoManager:)` (:144); `await inspector?.attachment.dom.toggleElementPicker()` (:152). The reload action even branches across two layers to pick page-level vs document-level reload — a decision the session layer should own.

Locations: Sources/WebInspectorUIDOM/DOMNavigationItems.swift:53; Sources/WebInspectorUIDOM/DOMNavigationItems.swift:122-131; Sources/WebInspectorUIDOM/DOMNavigationItems.swift:141-144; Sources/WebInspectorUIDOM/DOMNavigationItems.swift:152-157

### 9. Law-of-Demeter pain point 2: hand-rolled command closures and UI-side session fabrication

DOMTreeViewController.init wraps five DOMSession commands in `[weak inspection] { await inspection?.dom.requestChildNodes(...) }`-style closures to feed DOMTreeTextView (DOMTreeViewController.swift:22-47) — a manual command facade re-derived per call site. NetworkTabController round-trips the session's own state through itself: `session.interface.networkPanelModel(for: session.attachment)` (NetworkTabController.swift:35), and the presentation-layer InterfaceModel then holds a Core NetworkSession reference + fetch closure (WebInspectorSession.swift:207-218). Worst inversion: `DOMSplitViewController.init(inspection:)` fabricates `InspectorSession(attachment: inspection)` UI-side (DOMSplitViewController.swift:20-28) purely so DOMNavigationItems gets an InspectorSession — the UI constructs the Core owner object around its own child (production path passes the real one; this init is exercised by Tests/WebInspectorUITests/DOMContainerTests.swift:1136). Also: network detail UI reads raw protocol payload structs 3 hops deep — `request.request.url/method/headers`, `request.response?.status/statusText/mimeType`, `request.metrics?.remoteAddress` (NetworkHeadersTextView.swift:298) — so publishing NetworkRequest as-is drags Payload/Response/Metrics protocol types into the public surface.

Locations: Sources/WebInspectorUIDOM/Tree/DOMTreeViewController.swift:22-47; Sources/WebInspectorUI/NetworkTabController.swift:35; Sources/WebInspectorUI/Containers/WebInspectorSession.swift:207-218; Sources/WebInspectorUIDOM/DOMSplitViewController.swift:20-28; Sources/WebInspectorUINetwork/Detail/NetworkHeadersTextView.swift:298

### 10. Blocking gap for the rearchitecture goal: custom WebInspectorTab factories receive a session they cannot inspect

WebInspectorTab custom-content factory signature is `public init(id:title:image:makeViewController: @escaping @MainActor (_ session: WebInspectorSession) -> UIViewController)` (WebInspectorTab.swift:60-70), but WebInspectorSession's public members are only pageUserInterfaceStyle, init(tabs:), attach(to:), detach() — `inspector` and `attachment` are package. An external custom tab today can render a view controller but observe zero DOM/Network/Console/Runtime state; built-in DOM/Network tabs function only because they share package access. The observation contract a public surface must carry, as practiced by 13 UI files: ObservationBridge `withPortableContinuousObservation` over @Observable Core state (e.g. DOMNavigationItems.swift:52-58, DOMTreeViewController.swift:103-117, DOMElementViewController.swift:185-196) combined with monotonic revisions (treeRevision, selectionRevision, requestTopologyRevision, requestDisplayRevision) and since-cursor pull-diffs.

Locations: Sources/WebInspectorUI/Tabs/WebInspectorTab.swift:60-70; Sources/WebInspectorUI/Containers/WebInspectorSession.swift:11-17; Sources/WebInspectorUIDOM/Tree/DOMTreeViewController.swift:103-117; Sources/WebInspectorUIDOM/Element/DOMElementViewController.swift:185-196

## Extra

== DOMSession members used by UI (production; distinct=30; sites in parens, rg-measured, localization keys and preview fixtures excluded) ==
state: selectedNodeID(10) selectionRevision(5) isSelectingElement(4) currentPageRootNode(4) canReloadDocument(3) elementStyles(3) treeRevision(2) canBeginElementPicker(2) canDeleteSelectedNode(1) hasPendingSelectionRequest(1)
query: node(for:)(13) hasUnloadedRegularChildren(2) selectorPath(2) xPath(2) visibleDOMTreeChildren(1) currentPageTargetID(1)
command: selectNode(2) requestChildNodes(1) highlightNode(1) restoreSelectedNodeHighlightOrHide(1) toggleElementPicker(1) reloadDocument(1) deleteNodes(1) deleteSelectedNode(1) copyNodeText(1) ensureDocumentLoaded(1) requestSetCSSProperty(1)
render plumbing: treeRenderInvalidation(since:)(6) changes(since:)(3) currentDOMTreeRenderRootNodeID(3) domTreeRenderSnapshot()(1) treeProjection(rootTargetID:)(1)
lifecycle plumbing: setSelectedNodeStyleHydrationActive(3)
preview-only: applyTargetCreated, bindProtocolChannel, selectedCSSNodeStylesID

== NetworkSession members used (production; distinct=7 of 30 package members) ==
orderedRequestIDs(2) request(for:)(8) requestTopologyRevision(2) requestDisplayRevision(2) requestDisplayChanges(after:)(1, plumbing) reset()(1) fetchResponseBody(for:)(1)
preview-only: applyRequestWillBeSent applyResponseReceived applyDataReceived applyLoadingFinished

== InspectorSession members used by UI ==
attachment, detach(), retireBackendInteractionForPresentationEnd() [plumbing], canReloadPage, reloadPage(), init(), init(attachment:)
NOT used by UI: hasActiveConnection, lastError, connect/makeTransportSession/beginAttachmentRequest/detachForAttachmentRequest/connectAttachment/recordAttachmentError/waitUntilProtocolEventApplied/waitUntilRuntimeConsoleEnableFinished (transport-facing, consumed by WebInspectorNativeTransport/WebInspectorKit)

== AttachedInspection members used by UI ==
.dom .network (+ inits in previews). NOT used: .targetGraph .runtime .console .reset()

== Core type reference counts across the 4 UI targets (word-boundary rg) ==
182 NetworkRequest / 131 DOMNode / 45 CSSStyle / 43 NetworkBody / 36 CSSProperty / 22 NetworkSession / 21 DOMSession / 15 InspectorSession / 14 AttachedInspection / 12 CSSRule / 10 DOMTree / 7 CSSNodeStyles / 5 DOMFrame / 2 DOMTreeRenderSnapshot / 2 DOMPageHighlightOwner / 2 DOMDocument / 2 CSSComputedStyleProperty / 1 ProtocolCommandChannel / 1 DOMTreeRenderNodeSnapshot / 1 CSSStyleSheet

== Files importing WebInspectorCore ==
WebInspectorUIDOM 19/25, WebInspectorUINetwork 20/24, WebInspectorUISyntaxBody 1/2, WebInspectorUI 3/12

== Package-member totals (script-measured, top-level var/func in class+extensions) ==
DOMSession ~129, NetworkSession 30. Zero `public` declarations exist anywhere in the five Core targets.

== Nested payload reads (would drag protocol payload types public) ==
request.request.url(4) request.request.method(2) request.request.headers(2); response.statusText(6) response.status(4) response.url/mimeType/headers(1 each); request.metrics?.remoteAddress (NetworkHeadersTextView.swift:298)

== UI-side display extensions on Core types (WebInspectorUINetwork/NetworkRequest+Display.swift) ==
displayName, statusLabel, fileTypeLabel, statusSeverity, matchesDisplaySearchText, displayResourceFilter, displayProjection, duration, durationText, sizeText — presentation projections layered onto NetworkRequest via `package extension`; a public split must decide their home (Core public helpers vs UI-only).
