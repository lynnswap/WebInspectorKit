import OSLog
import Observation
import ObjectiveC
import WebKit
import WebInspectorEngine
import WebInspectorTransport

#if canImport(UIKit)
import UIKit
#endif

private let domViewLogger = Logger(subsystem: "WebInspectorKit", category: "WIDOMInspector")
private let domDeleteUndoHistoryLimit = 128
nonisolated(unsafe) private let pageWebViewLifetimeObserverAssociationKey = unsafe malloc(1)!

@MainActor
private final class WIPageWebViewLifetimeObserver {
    private let onDeinit: @MainActor () -> Void

    init(onDeinit: @escaping @MainActor () -> Void) {
        self.onDeinit = onDeinit
    }

    deinit {
        let onDeinit = self.onDeinit
        Task { @MainActor in
            onDeinit()
        }
    }
}

@MainActor
@Observable
public final class WIDOMInspector {
    private enum Phase: Equatable {
        case idle
        case waitingForTarget(DOMContext)
        case loadingDocument(DOMContext, targetIdentifier: String)
        case ready(DOMContext, targetIdentifier: String)

        var context: DOMContext? {
            switch self {
            case .idle:
                nil
            case let .waitingForTarget(context),
                 let .loadingDocument(context, _),
                 let .ready(context, _):
                context
            }
        }

        func matches(_ contextID: DOMContextID?) -> Bool {
            guard let contextID else {
                return false
            }
            return context?.contextID == contextID
        }

        var targetIdentifier: String? {
            switch self {
            case .idle, .waitingForTarget:
                return nil
            case let .loadingDocument(_, targetIdentifier), let .ready(_, targetIdentifier):
                return targetIdentifier
            }
        }
    }

    fileprivate struct DeleteUndoState {
        let nodeID: Int
        let nodeLocalID: UInt64?
        let contextID: DOMContextID
        let targetIdentifier: String
    }

    private struct SelectionTransaction: Equatable {
        let contextID: DOMContextID
        let generation: UInt64
    }

    private struct PendingInspectSelection: Equatable {
        let nodeID: Int
        let contextID: DOMContextID
        let selectorPath: String?
        let transaction: SelectionTransaction?
        var materializedAncestorNodeIDs: Set<DOMNodeModel.ID> = []
        var outstandingMaterializationNodeIDs: Set<DOMNodeModel.ID> = []
    }

    private struct PendingChildRequestKey: Hashable {
        let nodeID: Int
        let contextID: DOMContextID
    }

    @MainActor
    private final class PendingChildRequestRecord {
        let key: PendingChildRequestKey
        private(set) var reportsToFrontend: Bool

        private var result: Bool?
        private var waiters: [CheckedContinuation<Bool, Never>] = []
        private var timeoutTask: Task<Void, Never>?

        init(key: PendingChildRequestKey, reportsToFrontend: Bool) {
            self.key = key
            self.reportsToFrontend = reportsToFrontend
        }

        func upgradeToFrontendRequest() -> Bool {
            guard reportsToFrontend == false, result == nil else {
                return false
            }
            reportsToFrontend = true
            return true
        }

        func wait(
            timeout: Duration,
            onTimeout: @escaping @MainActor () async -> Void
        ) async -> Bool {
            if let result {
                return result
            }

            if timeoutTask == nil {
                timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await ContinuousClock().sleep(for: timeout)
                    } catch {
                        return
                    }

                    guard let self, self.result == nil else {
                        return
                    }
                    await onTimeout()
                }
            }

            return await withCheckedContinuation { continuation in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    waiters.append(continuation)
                }
            }
        }

        func finish(_ result: Bool) {
            guard self.result == nil else {
                return
            }

            self.result = result
            timeoutTask?.cancel()
            timeoutTask = nil

            let waiters = self.waiters
            self.waiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume(returning: result)
            }
        }
    }

    @ObservationIgnored package let pageBridge: DOMPageBridge
    @ObservationIgnored private let sharedTransport: WISharedInspectorTransport
    @ObservationIgnored let inspectorBridge: DOMInspectorBridge
    @ObservationIgnored private let payloadNormalizer = DOMPayloadNormalizer()

    public let document: DOMDocumentModel
    public private(set) var isSelectingElement = false
    public private(set) var hasPageWebView = false

    @ObservationIgnored private var configuration: DOMConfiguration
    @ObservationIgnored package weak var pageWebView: WKWebView?
    @ObservationIgnored private var phase: Phase = .idle
    @ObservationIgnored private var currentContext: DOMContext?
    @ObservationIgnored private var nextContextID: DOMContextID = 1
    @ObservationIgnored private var documentURL: String?
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var bootstrapGeneration: UInt64 = 0
    @ObservationIgnored private var frontendReadyContextID: DOMContextID?
    @ObservationIgnored private var autoSnapshotEnabled = false
    @ObservationIgnored private var externalRecoverableErrorHandler: (@MainActor (String?) -> Void)?
    @ObservationIgnored private var inspectModeTargetIdentifier: String?
    @ObservationIgnored private weak var deleteUndoManager: UndoManager?
    @ObservationIgnored private var pendingChildRequests: [PendingChildRequestKey: PendingChildRequestRecord] = [:]
    @ObservationIgnored private var lastSelectionDiagnosticMessage: String?
    @ObservationIgnored private var selectionGeneration: UInt64 = 0
    @ObservationIgnored private var acceptsInspectEvents = false
    @ObservationIgnored private var pendingInspectSelection: PendingInspectSelection?
    @ObservationIgnored var pointerDisconnectObserver: NSObjectProtocol?
    @ObservationIgnored private var pageWebViewAttachmentGeneration: UInt64 = 0

#if canImport(UIKit)
    @ObservationIgnored package weak var sceneActivationRequestingScene: UIScene?
#if DEBUG
    @ObservationIgnored package var selectionHitTestOverlay: UIView?
#endif
#endif

    public convenience init(
        configuration: DOMConfiguration = .init(),
        onRecoverableError: (@MainActor (String?) -> Void)? = nil
    ) {
        self.init(
            configuration: configuration,
            sharedTransport: WISharedInspectorTransport(),
            onRecoverableError: onRecoverableError
        )
    }

    package init(
        configuration: DOMConfiguration = .init(),
        sharedTransport: WISharedInspectorTransport,
        onRecoverableError: (@MainActor (String?) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.pageBridge = DOMPageBridge(configuration: configuration)
        self.sharedTransport = sharedTransport
        self.inspectorBridge = DOMInspectorBridge()
        self.document = DOMDocumentModel()
        self.externalRecoverableErrorHandler = onRecoverableError

        inspectorBridge.onMessage = { [weak self] message in
            self?.handleInspectorMessage(message)
        }
        self.sharedTransport.setEventHandler({ [weak self] envelope in
            await self?.handleTransportEvent(envelope)
        }, for: .dom)
    }

    isolated deinit {
        bootstrapTask?.cancel()
    }
    package func setRecoverableErrorHandler(_ handler: (@MainActor (String?) -> Void)?) {
        externalRecoverableErrorHandler = handler
    }

    package func makeInspectorWebView() -> WKWebView {
        frontendReadyContextID = nil
        let inspectorWebView = inspectorBridge.makeInspectorWebView(bootstrapPayload: bootstrapPayload())
#if canImport(UIKit)
        installPointerDisconnectObserverIfNeeded()
#endif
        return inspectorWebView
    }

    package func attach(to webView: WKWebView) async {
#if canImport(UIKit)
        installPointerDisconnectObserverIfNeeded()
#endif
        if pageWebView === webView, currentContext != nil {
            installPageWebViewLifetimeObserver(on: webView)
            hasPageWebView = true
            await sharedTransport.attach(client: .dom, to: webView)
            await installPageBridgeBootstrap(contextID: currentContext?.contextID ?? 0)
            return
        }

        await resetInteractionState()
        if pageWebView !== webView, pageBridge.attachedWebView != nil {
            await pageBridge.detach()
        }
        pageWebView = webView
        installPageWebViewLifetimeObserver(on: webView)
        hasPageWebView = true
        pageBridge.attach(to: webView)
        await sharedTransport.attach(client: .dom, to: webView)
        await installPageBridgeBootstrap(contextID: currentContext?.contextID ?? 0)
        let targetIdentifier = sharedTransport.currentObservedPageTargetIdentifier()
        await beginFreshContext(
            documentURL: normalizedDocumentURL(webView.url?.absoluteString),
            targetIdentifier: targetIdentifier,
            loadImmediately: targetIdentifier != nil,
            isFreshDocument: true
        )
    }

    package func suspend() async {
        await resetInteractionState()
        try? await hideHighlight()
        await sharedTransport.suspend(client: .dom)
#if canImport(UIKit)
        removePointerDisconnectObserver()
#endif
        if pageBridge.attachedWebView != nil {
            await pageBridge.detach()
        }
        pageWebView = nil
        hasPageWebView = false
        cancelBootstrap()
        clearContextState()
        updateInspectorBootstrap()
    }

    package func detach() async {
        await resetInteractionState()
        try? await hideHighlight()
        await sharedTransport.detach(client: .dom)
#if canImport(UIKit)
        removePointerDisconnectObserver()
#endif
        if pageBridge.attachedWebView != nil {
            await pageBridge.detach()
        }
        pageWebView = nil
        hasPageWebView = false
        cancelBootstrap()
        clearContextState()
        updateInspectorBootstrap()
        inspectorBridge.detachInspectorWebView()
    }

    package func setAutoSnapshotEnabled(_ enabled: Bool) async {
        autoSnapshotEnabled = enabled
    }

    public func reloadPage() async throws {
        let webView = try requirePageWebView()
        await resetInteractionState()
        await beginFreshContext(
            documentURL: normalizedDocumentURL(webView.url?.absoluteString),
            targetIdentifier: nil,
            loadImmediately: false,
            isFreshDocument: true
        )
        webView.reload()
    }

    public func reloadDocument() async throws {
        _ = try requirePageWebView()
        await resetInteractionState()
        let targetIdentifier = try requireCurrentTargetIdentifier()
        await beginFreshContext(
            documentURL: normalizedDocumentURL(pageWebView?.url?.absoluteString),
            targetIdentifier: targetIdentifier,
            loadImmediately: true,
            isFreshDocument: true
        )
    }

    public func cancelSelectionMode() async {
        guard isSelectingElement else {
            return
        }
        await cancelInspectMode(
            targetIdentifier: inspectModeTargetIdentifier ?? phase.targetIdentifier,
            invalidatePendingSelection: true,
            restoreSelectedHighlight: true
        )
    }

    public func beginSelectionMode() async throws {
        let _ = try requirePageWebView()
        applyRecoverableError(nil)
        let selectedContextID = currentContext?.contextID
        let hadSelectedNode = document.selectedNode != nil
        try? await hideHighlight()

        do {
            activatePageWindowForSelectionIfPossible()
#if canImport(UIKit)
            try await requestPageWindowActivationIfNeeded()
            try ensureNativeInspectorSelectionAvailableIfNeeded()
#endif

            let targetIdentifier = try requireCurrentTargetIdentifier()
            try await setInspectModeEnabled(true, targetIdentifier: targetIdentifier)
            beginInspectMode(targetIdentifier: targetIdentifier)
        } catch {
            if hadSelectedNode, let selectedContextID {
                await syncSelectedNodeHighlight(contextID: selectedContextID)
            }
            throw error
        }
    }

    package func requestSelectionModeToggle() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            if self.isSelectingElement {
                self.logSelectionDiagnostics("requestSelectionModeToggle cancelling inspect mode")
                await self.cancelSelectionMode()
            } else {
                self.logSelectionDiagnostics("requestSelectionModeToggle enabling inspect mode")
                do {
                    try await self.beginSelectionMode()
                    self.logSelectionDiagnostics("requestSelectionModeToggle enabled inspect mode")
                } catch {
                    self.logSelectionDiagnostics(
                        "requestSelectionModeToggle failed to enable inspect mode",
                        extra: error.localizedDescription,
                        level: .error
                    )
                }
            }
        }
    }

    package func tearDownForDeinit() {
        bootstrapTask?.cancel()
        bootstrapTask = nil
#if canImport(UIKit)
        removePointerDisconnectObserver()
#endif
        pageWebView = nil
        hasPageWebView = false
        currentContext = nil
        phase = .idle
        frontendReadyContextID = nil
        cancelPendingChildRequestRecords()
        document.setErrorMessage(nil)
        inspectorBridge.detachInspectorWebView()
        clearDeleteUndoHistory()
        Task { @MainActor [sharedTransport] in
            await sharedTransport.detach(client: .dom)
        }
    }

#if DEBUG
    @_spi(Monocly) public func currentDocumentURLForDiagnostics() -> String? {
        currentContext?.documentURL
    }

    @_spi(Monocly) public func currentContextIDForDiagnostics() -> DOMContextID? {
        currentContext?.contextID
    }

    @_spi(Monocly) public func currentSelectedNodePreviewForDiagnostics() -> String? {
        guard let selectedNode = document.selectedNode else {
            return nil
        }
        return selectionPreview(for: selectedNode)
    }

    @_spi(Monocly) public func currentSelectedNodeSelectorForDiagnostics() -> String? {
        document.selectedNode?.selectorPath.nilIfEmpty
    }

    @_spi(Monocly) public func visibleNodeSummariesForDiagnostics(limit: Int = 12) -> [String] {
        selectionVisibleNodeSummaries(limit: limit)
    }

    @_spi(Monocly) public func lastSelectionDiagnosticForDiagnostics() -> String? {
        lastSelectionDiagnosticMessage
    }

#if canImport(UIKit)
    @_spi(Monocly) public func nativeInspectorInteractionStateForDiagnostics() -> String? {
        nativeInspectorInteractionStateSummaryForDiagnostics()
    }
#endif
#endif

#if DEBUG
    func setSelectionModeActiveForTesting(_ active: Bool) {
        if active {
            beginInspectMode(targetIdentifier: "testing")
        } else {
            clearInspectModeState()
        }
    }
#endif

#if DEBUG
    @_spi(Monocly) public func selectNodeForTesting(cssSelector: String) async throws {
        guard !cssSelector.isEmpty else {
            logSelectionDiagnostics(
                "selectNodeForTesting rejected empty selector",
                level: .error
            )
            await clearSelectionForFailedResolution(
                contextID: currentContext?.contextID,
                errorMessage: "Failed to resolve selected element."
            )
            throw DOMOperationError.invalidSelection
        }
        guard case let .ready(context, targetIdentifier) = phase,
              let rootNode = document.rootNode else {
            logSelectionDiagnostics(
                "selectNodeForTesting rejected because inspector is not ready",
                selector: cssSelector,
                level: .error
            )
            throw DOMOperationError.contextInvalidated
        }

        logSelectionDiagnostics(
            "selectNodeForTesting started",
            selector: cssSelector,
            extra: "target=\(targetIdentifier) rootTransportNode=\((try? transportNodeID(for: rootNode)) ?? -1)"
        )

        let response = try await sendDOMCommand(
            WITransportMethod.DOM.querySelector,
            targetIdentifier: targetIdentifier,
            parameters: DOMQuerySelectorParameters(
                nodeId: try transportNodeID(for: rootNode),
                selector: cssSelector
            )
        )

        logSelectionDiagnostics(
            "selectNodeForTesting DOM.querySelector returned",
            selector: cssSelector,
            extra: "response=\(selectionLogValue(response))"
        )

        if let nodeID = intValue(response["nodeId"]),
           nodeID > 0 {
            try await applyInspectedNode(
                nodeID: nodeID,
                contextID: context.contextID,
                selectorPath: cssSelector,
                transaction: nil
            )
            return
        }

        do {
            _ = try await refreshCurrentDocumentFromTransport(
                contextID: context.contextID,
                targetIdentifier: targetIdentifier,
                depth: max(configuration.snapshotDepth, 128),
                isFreshDocument: false
            )
            logSelectionDiagnostics(
                "selectNodeForTesting refreshed current document",
                selector: cssSelector
            )
        } catch {
            logSelectionDiagnostics(
                "selectNodeForTesting refresh failed",
                selector: cssSelector,
                extra: error.localizedDescription,
                level: .error
            )
        }

        do {
            let didComplete = await requestTestingChildNodesAndWaitForCompletion(
                transportNodeID: try transportNodeID(for: rootNode),
                frontendNodeID: Int(rootNode.id.localID),
                targetIdentifier: targetIdentifier,
                contextID: context.contextID,
                depth: max(configuration.snapshotDepth, 128)
            )
            logSelectionDiagnostics(
                "selectNodeForTesting requested child nodes",
                selector: cssSelector
            )
            if !didComplete {
                logSelectionDiagnostics(
                    "selectNodeForTesting child-node request did not complete",
                    selector: cssSelector
                )
            }
        } catch {
            logSelectionDiagnostics(
                "selectNodeForTesting requestChildNodes failed",
                selector: cssSelector,
                extra: error.localizedDescription,
                level: .error
            )
        }

        if let node = resolveTestingSelectorNode(cssSelector) {
            logSelectionDiagnostics(
                "selectNodeForTesting matched fallback node",
                selector: cssSelector,
                extra: selectionNodeSummary(node)
            )
            await applySelection(
                to: node,
                selectorPath: cssSelector,
                contextID: context.contextID
            )
            applyRecoverableError(nil)
            return
        }

        logSelectionDiagnostics(
            "selectNodeForTesting failed to resolve selector",
            selector: cssSelector,
            extra: "visibleNodes=\(selectionVisibleNodeSummaries(limit: 12).joined(separator: " | "))",
            level: .error
        )
        await clearSelectionForFailedResolution(
            contextID: context.contextID,
            errorMessage: "Failed to resolve selected element."
        )
        throw DOMOperationError.invalidSelection
    }

    @_spi(Monocly) public func selectNodeForTesting(
        preview: String,
        selectorPath: String? = nil
    ) async throws {
        guard case let .ready(context, targetIdentifier) = phase,
              let rootNode = document.rootNode else {
            throw DOMOperationError.contextInvalidated
        }

        if let node = resolveTestingPreviewNode(preview) {
            await applySelection(
                to: node,
                selectorPath: selectorPath,
                contextID: context.contextID
            )
            applyRecoverableError(nil)
            return
        }

        _ = try? await refreshCurrentDocumentFromTransport(
            contextID: context.contextID,
            targetIdentifier: targetIdentifier,
            depth: max(configuration.snapshotDepth, 128),
            isFreshDocument: false
        )

        _ = await requestTestingChildNodesAndWaitForCompletion(
            transportNodeID: (try? transportNodeID(for: rootNode)) ?? Int(rootNode.id.localID),
            frontendNodeID: Int(rootNode.id.localID),
            targetIdentifier: targetIdentifier,
            contextID: context.contextID,
            depth: max(configuration.snapshotDepth, 128)
        )

        if let node = resolveTestingPreviewNode(preview) {
            await applySelection(
                to: node,
                selectorPath: selectorPath,
                contextID: context.contextID
            )
            applyRecoverableError(nil)
            return
        }

        await clearSelectionForFailedResolution(
            contextID: context.contextID,
            errorMessage: "Failed to resolve selected element."
        )
        throw DOMOperationError.invalidSelection
    }
#endif

    public func copySelectedHTML() async throws -> String {
        try await copySelectionImpl(.html)
    }

    public func copySelectedSelectorPath() async throws -> String {
        try await copySelectionImpl(.selectorPath)
    }

    public func copySelectedXPath() async throws -> String {
        try await copySelectionImpl(.xpath)
    }

    package func copyNode(nodeID: DOMNodeModel.ID, kind: DOMSelectionCopyKind) async throws -> String {
        guard let node = document.node(id: nodeID) else {
            throw DOMOperationError.invalidSelection
        }
        return try await copyText(for: node, kind: kind)
    }

    package func copyNode(nodeId: Int, kind: DOMSelectionCopyKind) async throws -> String {
        if let node = document.node(localID: UInt64(nodeId)) {
            return try await copyText(for: node, kind: kind)
        }
        if let node = document.node(stableBackendNodeID: nodeId) {
            return try await copyText(for: node, kind: kind)
        }
        throw DOMOperationError.invalidSelection
    }

    public func deleteSelection() async throws {
        try await deleteSelection(undoManager: nil)
    }

    public func deleteSelection(undoManager: UndoManager?) async throws {
        guard let nodeID = document.selectedNode?.id else {
            throw DOMOperationError.invalidSelection
        }
        try await deleteNode(nodeID: nodeID, undoManager: undoManager)
    }

    public func deleteNode(nodeID: DOMNodeModel.ID?, undoManager: UndoManager?) async throws {
        guard let nodeID,
              let node = document.node(id: nodeID) else {
            throw DOMOperationError.invalidSelection
        }
        try await deleteNode(
            nodeID: try transportNodeID(for: node),
            nodeLocalID: node.localID,
            undoManager: undoManager
        )
    }

    public func deleteNode(nodeId: Int?, undoManager: UndoManager?) async throws {
        guard let nodeId else {
            throw DOMOperationError.invalidSelection
        }
        if let node = document.node(localID: UInt64(nodeId)) {
            try await deleteNode(nodeID: node.id, undoManager: undoManager)
            return
        }
        if let node = document.node(stableBackendNodeID: nodeId) {
            try await deleteNode(nodeID: node.id, undoManager: undoManager)
            return
        }
        throw DOMOperationError.invalidSelection
    }

    public func setAttribute(
        nodeID: DOMNodeModel.ID,
        name: String,
        value: String
    ) async throws {
        guard let node = document.node(id: nodeID) else {
            throw DOMOperationError.invalidSelection
        }
        let context = try requireCurrentContext()
        let targetIdentifier = try requireCurrentTargetIdentifier()
        _ = try await sendDOMCommand(
            WITransportMethod.DOM.setAttributeValue,
            targetIdentifier: targetIdentifier,
            parameters: DOMSetAttributeValueParameters(
                nodeId: try transportNodeID(for: node),
                name: name,
                value: value
            )
        )
        _ = document.updateAttribute(
            name: name,
            value: value,
            localID: node.localID,
            backendNodeID: node.backendNodeID
        )
        applyRecoverableError(nil)
        if currentContext?.contextID != context.contextID {
            throw DOMOperationError.contextInvalidated
        }
    }

    public func removeAttribute(
        nodeID: DOMNodeModel.ID,
        name: String
    ) async throws {
        guard let node = document.node(id: nodeID) else {
            throw DOMOperationError.invalidSelection
        }
        let context = try requireCurrentContext()
        let targetIdentifier = try requireCurrentTargetIdentifier()
        _ = try await sendDOMCommand(
            WITransportMethod.DOM.removeAttribute,
            targetIdentifier: targetIdentifier,
            parameters: DOMRemoveAttributeParameters(
                nodeId: try transportNodeID(for: node),
                name: name
            )
        )
        _ = document.removeAttribute(
            name: name,
            localID: node.localID,
            backendNodeID: node.backendNodeID
        )
        applyRecoverableError(nil)
        if currentContext?.contextID != context.contextID {
            throw DOMOperationError.contextInvalidated
        }
    }

    public func updateSelectedAttribute(name: String, value: String) async throws {
        guard let nodeID = document.selectedNode?.id else {
            throw DOMOperationError.invalidSelection
        }
        try await setAttribute(nodeID: nodeID, name: name, value: value)
    }

    public func removeSelectedAttribute(name: String) async throws {
        guard let nodeID = document.selectedNode?.id else {
            throw DOMOperationError.invalidSelection
        }
        try await removeAttribute(nodeID: nodeID, name: name)
    }
}

private extension WIDOMInspector {
    func bootstrapPayload() -> [String: Any] {
        [
            "config": [
                "snapshotDepth": configuration.snapshotDepth,
                "subtreeDepth": configuration.subtreeDepth,
                "autoUpdateDebounce": configuration.autoUpdateDebounce,
            ],
            "context": [
                "contextID": currentContext?.contextID ?? 0,
            ],
        ]
    }

    func updateInspectorBootstrap() {
        inspectorBridge.updateBootstrap(bootstrapPayload())
    }

    func requirePageWebView() throws -> WKWebView {
        guard let pageWebView else {
            applyRecoverableError("Web view unavailable.")
            throw DOMOperationError.pageUnavailable
        }
        return pageWebView
    }

    func requireCurrentContext() throws -> DOMContext {
        guard let currentContext else {
            throw DOMOperationError.contextInvalidated
        }
        return currentContext
    }

    func requireCurrentTargetIdentifier() throws -> String {
        guard let targetIdentifier = phase.targetIdentifier ?? sharedTransport.currentPageTargetIdentifier() else {
            throw DOMOperationError.contextInvalidated
        }
        return targetIdentifier
    }

    func transportNodeID(for node: DOMNodeModel) throws -> Int {
        if let backendNodeID = node.backendNodeID {
            return backendNodeID
        }
        guard node.localID <= UInt64(Int.max) else {
            throw DOMOperationError.invalidSelection
        }
        return Int(node.localID)
    }

    func transportNodeID(forFrontendNodeID nodeID: Int) throws -> Int {
        if let node = document.node(localID: UInt64(nodeID)) {
            return try transportNodeID(for: node)
        }
        if let node = document.node(backendNodeID: nodeID) {
            return try transportNodeID(for: node)
        }
        return nodeID
    }

    func cancelBootstrap() {
        bootstrapTask?.cancel()
        bootstrapTask = nil
        bootstrapGeneration &+= 1
    }

    func clearContextState() {
        currentContext = nil
        phase = .idle
        documentURL = nil
        frontendReadyContextID = nil
        inspectModeTargetIdentifier = nil
        acceptsInspectEvents = false
        pendingInspectSelection = nil
        isSelectingElement = false
        selectionGeneration &+= 1
        cancelPendingChildRequestRecords()
        payloadNormalizer.resetForDocumentUpdate()
        document.clearDocument(isFreshDocument: true)
    }

    func installPageBridgeBootstrap(contextID: DOMContextID) async {
        guard let pageWebView else {
            return
        }
        await pageBridge.installOrUpdateBootstrap(
            on: pageWebView,
            contextID: contextID,
            configuration: configuration,
            autoSnapshotEnabled: false
        )
    }

    func beginFreshContext(
        documentURL: String?,
        targetIdentifier: String?,
        loadImmediately: Bool,
        isFreshDocument: Bool
    ) async {
        if isSelectingElement,
           let activeTargetIdentifier = inspectModeTargetIdentifier ?? phase.targetIdentifier {
            await cancelInspectMode(
                targetIdentifier: activeTargetIdentifier,
                invalidatePendingSelection: true
            )
        }
        if document.selectedNode != nil {
            try? await hideHighlight()
        }
        await failPendingChildRequests()
        cancelBootstrap()
        payloadNormalizer.resetForDocumentUpdate()
        frontendReadyContextID = nil

        let context = DOMContext(
            contextID: nextContextID,
            documentURL: documentURL
        )
        nextContextID &+= 1
        currentContext = context
        self.documentURL = documentURL
        document.clearDocument(isFreshDocument: isFreshDocument)
        applyRecoverableError(nil)
        await installPageBridgeBootstrap(contextID: context.contextID)
        updateInspectorBootstrap()
        logBootstrapDiagnostics(
            "beginFreshContext context=\(context.contextID) target=\(targetIdentifier ?? "nil") loadImmediately=\(loadImmediately) url=\(documentURL ?? "nil")"
        )

        guard loadImmediately, let targetIdentifier else {
            phase = .waitingForTarget(context)
            logBootstrapDiagnostics("phase waitingForTarget context=\(context.contextID)")
            return
        }

        startLoadingDocument(
            for: context,
            targetIdentifier: targetIdentifier,
            depth: configuration.snapshotDepth,
            isFreshDocument: isFreshDocument
        )
    }

    func startLoadingDocument(
        for context: DOMContext,
        targetIdentifier: String,
        depth: Int,
        isFreshDocument: Bool
    ) {
        cancelBootstrap()
        phase = .loadingDocument(context, targetIdentifier: targetIdentifier)
        logBootstrapDiagnostics(
            "startLoadingDocument context=\(context.contextID) target=\(targetIdentifier) depth=\(depth)"
        )
        let generation = bootstrapGeneration
        bootstrapTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.bootstrapGeneration == generation {
                    self.bootstrapTask = nil
                }
            }
            do {
                try await self?.refreshCurrentDocumentFromTransport(
                    contextID: context.contextID,
                    targetIdentifier: targetIdentifier,
                    depth: depth,
                    isFreshDocument: isFreshDocument
                )
            } catch {
                guard let self, self.currentContext?.contextID == context.contextID else {
                    return
                }
                self.phase = .waitingForTarget(context)
                self.applyRecoverableError(self.errorMessage(from: error))
            }
        }
    }

    func refreshCurrentDocumentFromTransport(
        contextID: DOMContextID,
        targetIdentifier: String,
        depth: Int,
        isFreshDocument: Bool
    ) async throws {
        guard let activeContext = currentContext,
              activeContext.contextID == contextID else {
            throw DOMOperationError.contextInvalidated
        }
        phase = .loadingDocument(activeContext, targetIdentifier: targetIdentifier)
        logBootstrapDiagnostics(
            "refreshCurrentDocumentFromTransport begin context=\(contextID) target=\(targetIdentifier)"
        )
        let responseObject = try await loadDocumentResponseObject(
            targetIdentifier: targetIdentifier
        )

        guard let currentContext,
              currentContext.contextID == contextID else {
            throw DOMOperationError.contextInvalidated
        }

        guard let delta = payloadNormalizer.normalizeBackendResponse(
            method: WITransportMethod.DOM.getDocument,
            responseObject: ["result": responseObject],
            resetDocument: isFreshDocument
        ),
        case let .snapshot(snapshot, _) = delta else {
            throw DOMOperationError.scriptFailure("document normalization failed")
        }

        document.replaceDocument(with: snapshot, isFreshDocument: isFreshDocument)
        let resolvedURL = normalizedDocumentURL(pageWebView?.url?.absoluteString)
            ?? normalizedDocumentURL((responseObject["root"] as? [String: Any])?["documentURL"] as? String)
            ?? currentContext.documentURL
        let resolvedContext = DOMContext(contextID: contextID, documentURL: resolvedURL)
        self.currentContext = resolvedContext
        self.documentURL = resolvedURL
        phase = .ready(resolvedContext, targetIdentifier: targetIdentifier)
        applyRecoverableError(nil)
        logBootstrapDiagnostics(
            "refreshCurrentDocumentFromTransport ready context=\(contextID) target=\(targetIdentifier) root=\(snapshot.root.nodeName)"
        )

        await hydrateInitiallyExpandedNodes(
            contextID: contextID,
            targetIdentifier: targetIdentifier,
            depth: depth
        )

        if frontendReadyContextID == contextID {
            if let rootNode = document.rootNode {
                await inspectorBridge.applyFullSnapshot(
                    ["root": nodePayloadDictionary(from: rootNode)],
                    contextID: contextID
                )
            } else {
                await inspectorBridge.applyFullSnapshot(responseObject, contextID: contextID)
            }
        }
    }

    func loadDocumentResponseObject(
        targetIdentifier: String
    ) async throws -> [String: Any] {
        logBootstrapDiagnostics("loadDocumentResponseObject target=\(targetIdentifier) inspector.enable")
        _ = try await sendDOMCommand(
            WITransportMethod.Inspector.enable,
            targetIdentifier: targetIdentifier
        )
        logBootstrapDiagnostics("loadDocumentResponseObject target=\(targetIdentifier) inspector.initialized")
        _ = try await sendDOMCommand(
            WITransportMethod.Inspector.initialized,
            targetIdentifier: targetIdentifier
        )
        logBootstrapDiagnostics("loadDocumentResponseObject target=\(targetIdentifier) dom.enable")
        _ = try await sendDOMCommand(
            WITransportMethod.DOM.enable,
            targetIdentifier: targetIdentifier
        )
        logBootstrapDiagnostics("loadDocumentResponseObject target=\(targetIdentifier) dom.getDocument")
        return try await sendDOMCommand(
            WITransportMethod.DOM.getDocument,
            targetIdentifier: targetIdentifier
        )
    }

    func hydrateInitiallyExpandedNodes(
        contextID: DOMContextID,
        targetIdentifier: String,
        depth: Int
    ) async {
        guard currentContext?.contextID == contextID else {
            return
        }

        var requestedNodeIDs = Set<DOMNodeModel.ID>()

        while currentContext?.contextID == contextID {
            let candidates = initiallyExpandedIncompleteNodes().filter {
                requestedNodeIDs.insert($0.id).inserted
            }
            guard !candidates.isEmpty else {
                return
            }

            var requestedAnyChildren = false
            for node in candidates {
                guard let transportNodeID = try? transportNodeID(for: node) else {
                    continue
                }
                do {
                    _ = try await sendDOMCommand(
                        WITransportMethod.DOM.requestChildNodes,
                        targetIdentifier: targetIdentifier,
                        parameters: DOMRequestChildNodesParameters(
                            nodeId: transportNodeID,
                            depth: max(1, depth)
                        )
                    )
                    requestedAnyChildren = true
                } catch {
                    continue
                }
            }

            if requestedAnyChildren {
                await awaitTransportMessagesToDrain()
                for _ in 0..<8 {
                    guard currentContext?.contextID == contextID else {
                        return
                    }
                    let hasUnrequestedCandidates = initiallyExpandedIncompleteNodes().contains {
                        requestedNodeIDs.contains($0.id) == false
                    }
                    if hasUnrequestedCandidates {
                        break
                    }
                    await Task.yield()
                }
            }
        }
    }

    func initiallyExpandedIncompleteNodes() -> [DOMNodeModel] {
        var nodes: [DOMNodeModel] = []

        func visit(_ node: DOMNodeModel?, depth: Int) {
            guard let node else {
                return
            }
            guard shouldHydrateInitiallyExpandedNode(node, depth: depth) else {
                return
            }
            if node.childCount > node.children.count {
                nodes.append(node)
            }
            for child in node.children {
                visit(child, depth: depth + 1)
            }
        }

        visit(document.rootNode, depth: 0)
        return nodes
    }

    func shouldHydrateInitiallyExpandedNode(_ node: DOMNodeModel, depth: Int) -> Bool {
        guard node.nodeType != 10 else {
            return false
        }
        let name = (node.localName.isEmpty ? node.nodeName : node.localName).lowercased()
        if name == "head" {
            return false
        }
        return depth <= 2
    }

    func handleInspectorMessage(_ message: DOMInspectorBridge.IncomingMessage) {
        switch message {
        case let .ready(contextID):
            guard phase.matches(contextID) else {
                return
            }
            let wasFrontendReadyForContext = frontendReadyContextID == contextID
            frontendReadyContextID = contextID
            if case let .ready(context, targetIdentifier) = phase,
               wasFrontendReadyForContext == false {
                startLoadingDocument(
                    for: context,
                    targetIdentifier: targetIdentifier,
                    depth: configuration.snapshotDepth,
                    isFreshDocument: false
                )
                return
            }
            if case let .waitingForTarget(context) = phase,
               wasFrontendReadyForContext == false,
               let targetIdentifier = sharedTransport.currentObservedPageTargetIdentifier()
                    ?? sharedTransport.currentPageTargetIdentifier() {
                startLoadingDocument(
                    for: context,
                    targetIdentifier: targetIdentifier,
                    depth: configuration.snapshotDepth,
                    isFreshDocument: true
                )
            }
        case let .requestChildren(nodeID, depth, contextID):
            guard phase.matches(contextID) else {
                return
            }
            Task { @MainActor [weak self] in
                await self?.performChildRequest(nodeID: nodeID, depth: depth, contextID: contextID)
            }
        case let .highlight(nodeID, _, contextID):
            guard phase.matches(contextID) else {
                return
            }
            Task { @MainActor [weak self] in
                try? await self?.highlightNode(nodeID)
            }
        case let .hideHighlight(contextID):
            guard phase.matches(contextID) else {
                return
            }
            Task { @MainActor [weak self] in
                try? await self?.hideHighlight()
            }
        case let .domSelection(payload, contextID):
            guard phase.matches(contextID) else {
                return
            }
            handleInspectorSelection(payload)
        case let .log(message):
            domViewLogger.debug("inspector log: \(message, privacy: .public)")
        }
    }

    func handleTransportEvent(_ envelope: WITransportEventEnvelope) async {
        switch envelope.method {
        case "Target.targetCreated":
            let observedTargetIdentifier = sharedTransport.currentObservedPageTargetIdentifier()
            switch phase {
            case let .waitingForTarget(context):
                guard let targetIdentifier = observedTargetIdentifier
                    ?? sharedTransport.currentPageTargetIdentifier()
                    ?? envelope.targetIdentifier
                else {
                    return
                }
                startLoadingDocument(
                    for: context,
                    targetIdentifier: targetIdentifier,
                    depth: configuration.snapshotDepth,
                    isFreshDocument: true
                )
            case let .loadingDocument(context, activeTargetIdentifier):
                let targetIdentifier: String
                if let observedTargetIdentifier {
                    targetIdentifier = observedTargetIdentifier
                } else if envelope.targetIdentifier == activeTargetIdentifier {
                    targetIdentifier = activeTargetIdentifier
                } else {
                    return
                }
                startLoadingDocument(
                    for: context,
                    targetIdentifier: targetIdentifier,
                    depth: configuration.snapshotDepth,
                    isFreshDocument: true
                )
            default:
                return
            }
        case "Target.didCommitProvisionalTarget":
            let targetIdentifier = envelope.targetIdentifier ?? sharedTransport.currentObservedPageTargetIdentifier()
            await beginFreshContext(
                documentURL: normalizedDocumentURL(pageWebView?.url?.absoluteString),
                targetIdentifier: targetIdentifier,
                loadImmediately: targetIdentifier != nil,
                isFreshDocument: true
            )
        case "Target.targetDestroyed":
            guard envelope.targetIdentifier == phase.targetIdentifier else {
                return
            }
            let replacementTargetIdentifier = sharedTransport.currentObservedPageTargetIdentifier()
                ?? sharedTransport.currentPageTargetIdentifier()
            await beginFreshContext(
                documentURL: normalizedDocumentURL(pageWebView?.url?.absoluteString),
                targetIdentifier: replacementTargetIdentifier,
                loadImmediately: replacementTargetIdentifier != nil,
                isFreshDocument: true
            )
        default:
            await handleDOMEventEnvelope(envelope)
        }
    }

    func handleDOMEventEnvelope(_ envelope: WITransportEventEnvelope) async {
        let isDOMEvent = envelope.method.hasPrefix("DOM.")
        let isInspectorInspectEvent = envelope.method == "Inspector.inspect"
        guard isDOMEvent || isInspectorInspectEvent else {
            return
        }
        guard case let .ready(context, targetIdentifier) = phase,
              envelope.targetIdentifier == nil || envelope.targetIdentifier == targetIdentifier else {
            return
        }

        if envelope.method == "DOM.inspect" {
            guard acceptsInspectEvents,
                  let object = try? JSONSerialization.jsonObject(with: envelope.paramsData) as? [String: Any],
                  let nodeID = intValue(object["nodeId"]) else {
                return
            }
            await handleInspectEvent(
                nodeID: nodeID,
                contextID: context.contextID,
                targetIdentifier: targetIdentifier
            )
            return
        }

        if envelope.method == "Inspector.inspect" {
            guard acceptsInspectEvents,
                  let object = try? JSONSerialization.jsonObject(with: envelope.paramsData) as? [String: Any],
                  let remoteObject = object["object"] as? [String: Any],
                  let objectID = stringValue(remoteObject["objectId"]) else {
                return
            }
            await handleInspectorInspectEvent(
                objectID: objectID,
                contextID: context.contextID,
                targetIdentifier: targetIdentifier
            )
            return
        }

        let payload = mutationBundlePayload(from: envelope, contextID: context.contextID)
        guard let delta = payloadNormalizer.normalizeBundlePayload(payload) else {
            return
        }

        switch delta {
        case let .mutations(bundle):
            if bundle.events.contains(where: { if case .documentUpdated = $0 { true } else { false } }) {
                await beginFreshContext(
                    documentURL: normalizedDocumentURL(pageWebView?.url?.absoluteString),
                    targetIdentifier: targetIdentifier,
                    loadImmediately: true,
                    isFreshDocument: true
                )
                return
            }
            document.applyMutationBundle(bundle)
            if frontendReadyContextID == context.contextID {
                await inspectorBridge.applyMutationBundles(payload, contextID: context.contextID)
            }
            await applyPendingInspectSelectionIfPossible()
            await finishPendingChildRequests(from: bundle, contextID: context.contextID)
            await finishPendingInspectMaterialization(from: bundle, contextID: context.contextID)
        case let .replaceSubtree(root):
            let bundle = DOMGraphMutationBundle(events: [.replaceSubtree(root: root)])
            document.applyMutationBundle(bundle)
            await applyPendingInspectSelectionIfPossible()
            await finishPendingChildRequests(from: bundle, contextID: context.contextID)
            await finishPendingInspectMaterialization(from: bundle, contextID: context.contextID)
        case let .selection(selection):
            document.applySelectionSnapshot(selection)
            await inspectorBridge.applySelectionPayload(
                selectionPayloadDictionary(from: selection),
                contextID: context.contextID
            )
        case let .selectorPath(selectorPath):
            document.applySelectorPath(selectorPath)
        case let .snapshot(snapshot, resetDocument):
            document.replaceDocument(with: snapshot, isFreshDocument: resetDocument)
            if frontendReadyContextID == context.contextID {
                await inspectorBridge.applyFullSnapshot(payload, contextID: context.contextID)
            }
            await applyPendingInspectSelectionIfPossible()
        }
    }

    func mutationBundlePayload(
        from envelope: WITransportEventEnvelope,
        contextID: DOMContextID
    ) -> [String: Any] {
        let params: [String: Any]
        if let object = try? JSONSerialization.jsonObject(with: envelope.paramsData) as? [String: Any] {
            params = object
        } else {
            params = [:]
        }
        return [
            "version": 1,
            "kind": "mutation",
            "contextID": contextID,
            "events": [[
                "method": envelope.method,
                "params": params,
            ]],
        ]
    }

    func finishPendingChildRequests(
        from bundle: DOMGraphMutationBundle,
        contextID: DOMContextID
    ) async {
        let completedNodeIDs = completedChildRequestNodeIDs(from: bundle)

        for nodeID in completedNodeIDs {
            await completePendingChildRequest(
                nodeID: nodeID,
                contextID: contextID,
                success: true
            )
        }
    }

    private func completedChildRequestNodeIDs(from bundle: DOMGraphMutationBundle) -> [Int] {
        bundle.events.compactMap { event in
            switch event {
            case let .setChildNodes(parentLocalID, _):
                return Int(parentLocalID)
            case let .replaceSubtree(root):
                return Int(root.localID)
            default:
                return nil
            }
        }
    }

    func performChildRequest(nodeID: Int, depth: Int, contextID: DOMContextID) async {
        guard let registration = registerPendingChildRequest(
            nodeID: nodeID,
            contextID: contextID,
            reportsToFrontend: true
        ) else {
            return
        }

        do {
            if registration.shouldSendRequest {
                let targetIdentifier = try requireCurrentTargetIdentifier()
                let transportNodeID = try transportNodeID(forFrontendNodeID: nodeID)
                _ = try await sendDOMCommand(
                    WITransportMethod.DOM.requestChildNodes,
                    targetIdentifier: targetIdentifier,
                    parameters: DOMRequestChildNodesParameters(
                        nodeId: transportNodeID,
                        depth: max(1, depth)
                    )
                )
            }

            _ = await waitForPendingChildRequestCompletion(
                registration.record,
                nodeID: nodeID,
                contextID: contextID
            )
        } catch {
            await completePendingChildRequest(
                nodeID: nodeID,
                contextID: contextID,
                success: false
            )
        }
    }

    private func registerPendingChildRequest(
        nodeID: Int,
        contextID: DOMContextID,
        reportsToFrontend: Bool
    ) -> (record: PendingChildRequestRecord, shouldSendRequest: Bool)? {
        let key = PendingChildRequestKey(nodeID: nodeID, contextID: contextID)
        if let existing = pendingChildRequests[key] {
            if reportsToFrontend, existing.upgradeToFrontendRequest() == false {
                return nil
            }
            return (existing, false)
        }

        let record = PendingChildRequestRecord(key: key, reportsToFrontend: reportsToFrontend)
        pendingChildRequests[key] = record
        return (record, true)
    }

    private func waitForPendingChildRequestCompletion(
        _ record: PendingChildRequestRecord,
        nodeID: Int,
        contextID: DOMContextID
    ) async -> Bool {
        let timeout = await sharedTransport.attachedSession()?.responseTimeout ?? .seconds(15)
        return await record.wait(timeout: timeout) { [weak self] in
            guard let self else {
                return
            }
            await self.completePendingChildRequest(
                nodeID: nodeID,
                contextID: contextID,
                success: false
            )
        }
    }

    private func completePendingChildRequest(
        nodeID: Int,
        contextID: DOMContextID,
        success: Bool
    ) async {
        let key = PendingChildRequestKey(nodeID: nodeID, contextID: contextID)
        guard let record = pendingChildRequests.removeValue(forKey: key) else {
            return
        }

        let shouldNotifyFrontend = record.reportsToFrontend
        record.finish(success)

        guard shouldNotifyFrontend else {
            return
        }

        if success, let node = document.node(localID: UInt64(nodeID)) {
            await inspectorBridge.applySubtreePayload(
                nodePayloadDictionary(from: node),
                contextID: contextID
            )
        }

        await inspectorBridge.finishChildNodeRequest(
            nodeID: nodeID,
            success: success,
            contextID: contextID
        )
    }

    private func failPendingChildRequests(contextID: DOMContextID? = nil) async {
        let keysToFail = pendingChildRequests.keys.filter {
            contextID == nil || $0.contextID == contextID
        }
        guard !keysToFail.isEmpty else {
            return
        }

        let failedRecords = keysToFail.compactMap { key in
            pendingChildRequests.removeValue(forKey: key).map { (key, $0) }
        }

        for (key, record) in failedRecords {
            let shouldNotifyFrontend = record.reportsToFrontend
            record.finish(false)
            if shouldNotifyFrontend {
                await inspectorBridge.finishChildNodeRequest(
                    nodeID: key.nodeID,
                    success: false,
                    contextID: key.contextID
                )
            }
        }
    }

    private func cancelPendingChildRequestRecords() {
        let records = Array(pendingChildRequests.values)
        pendingChildRequests.removeAll(keepingCapacity: true)
        for record in records {
            record.finish(false)
        }
    }

    func highlightNode(_ nodeID: Int) async throws {
        let targetIdentifier = try requireCurrentTargetIdentifier()
        _ = try await sendDOMCommand(
            WITransportMethod.DOM.highlightNode,
            targetIdentifier: targetIdentifier,
            parameters: DOMHighlightNodeParameters(nodeId: try transportNodeID(forFrontendNodeID: nodeID))
        )
    }

    func hideHighlight() async throws {
        let targetIdentifier = try requireCurrentTargetIdentifier()
        _ = try await sendDOMCommand(
            WITransportMethod.DOM.hideHighlight,
            targetIdentifier: targetIdentifier
        )
    }

    func handleInspectorSelection(_ payload: Any) {
        if case let .selection(selection) = payloadNormalizer.normalizeSelectionPayload(payload) {
            document.applySelectionSnapshot(selection)
            Task { @MainActor [weak self] in
                guard let self, let contextID = self.currentContext?.contextID else {
                    return
                }
                await self.syncSelectedNodeHighlight(contextID: contextID)
            }
        }
    }

    func deleteNode(
        nodeID: Int,
        nodeLocalID: UInt64?,
        undoManager: UndoManager?
    ) async throws {
        let context = try requireCurrentContext()
        let targetIdentifier = try requireCurrentTargetIdentifier()
        _ = try await sendDOMCommand(
            WITransportMethod.DOM.removeNode,
            targetIdentifier: targetIdentifier,
            parameters: DOMNodeIdentifierParameters(nodeId: nodeID)
        )
        applyDeletedNode(nodeID: nodeID, nodeLocalID: nodeLocalID)
        applyRecoverableError(nil)

        if let undoManager {
            rememberDeleteUndoManager(undoManager)
            registerUndoDelete(
                .init(
                    nodeID: nodeID,
                    nodeLocalID: nodeLocalID,
                    contextID: context.contextID,
                    targetIdentifier: targetIdentifier
                ),
                undoManager: undoManager
            )
        }
    }

    func applyDeletedNode(nodeID: Int, nodeLocalID: UInt64?) {
        if let nodeLocalID,
           let node = document.node(localID: nodeLocalID) {
            document.removeNode(id: node.id)
            return
        }
        if let node = document.node(localID: UInt64(nodeID)) {
            document.removeNode(id: node.id)
            return
        }
        if let node = document.node(backendNodeID: nodeID) {
            document.removeNode(id: node.id)
        }
    }

    func registerUndoDelete(_ state: DeleteUndoState, undoManager: UndoManager) {
        rememberDeleteUndoManager(undoManager)
        undoManager.registerUndo(withTarget: self) { target in
            Task { @MainActor in
                try? await target.performUndoDelete(state, undoManager: undoManager)
            }
        }
        undoManager.setActionName("Delete Node")
    }

    func performUndoDelete(_ state: DeleteUndoState, undoManager: UndoManager) async throws {
        guard currentContext?.contextID == state.contextID else {
            clearDeleteUndoHistory(using: undoManager)
            throw DOMOperationError.contextInvalidated
        }
        _ = try await sendDOMCommand(
            WITransportMethod.DOM.undo,
            targetIdentifier: state.targetIdentifier
        )
        try await refreshCurrentDocumentFromTransport(
            contextID: state.contextID,
            targetIdentifier: state.targetIdentifier,
            depth: configuration.snapshotDepth,
            isFreshDocument: false
        )
        registerRedoDelete(state, undoManager: undoManager)
        applyRecoverableError(nil)
    }

    func registerRedoDelete(_ state: DeleteUndoState, undoManager: UndoManager) {
        rememberDeleteUndoManager(undoManager)
        undoManager.registerUndo(withTarget: self) { target in
            Task { @MainActor in
                try? await target.performRedoDelete(state, undoManager: undoManager)
            }
        }
        undoManager.setActionName("Delete Node")
    }

    func performRedoDelete(_ state: DeleteUndoState, undoManager: UndoManager) async throws {
        guard currentContext?.contextID == state.contextID else {
            clearDeleteUndoHistory(using: undoManager)
            throw DOMOperationError.contextInvalidated
        }
        _ = try await sendDOMCommand(
            WITransportMethod.DOM.redo,
            targetIdentifier: state.targetIdentifier
        )
        try await refreshCurrentDocumentFromTransport(
            contextID: state.contextID,
            targetIdentifier: state.targetIdentifier,
            depth: configuration.snapshotDepth,
            isFreshDocument: false
        )
        registerUndoDelete(state, undoManager: undoManager)
        applyRecoverableError(nil)
    }

    func rememberDeleteUndoManager(_ undoManager: UndoManager) {
        if undoManager.levelsOfUndo == 0 || undoManager.levelsOfUndo > domDeleteUndoHistoryLimit {
            undoManager.levelsOfUndo = domDeleteUndoHistoryLimit
        }
        deleteUndoManager = undoManager
    }

    func clearDeleteUndoHistory(using undoManager: UndoManager? = nil) {
        let manager = undoManager ?? deleteUndoManager
        manager?.removeAllActions(withTarget: self)
        if let manager, manager === deleteUndoManager {
            deleteUndoManager = nil
        }
    }

    func beginInspectMode(targetIdentifier: String) {
        selectionGeneration &+= 1
        pendingInspectSelection = nil
        inspectModeTargetIdentifier = targetIdentifier
        acceptsInspectEvents = true
        isSelectingElement = true
    }

    func clearInspectModeState(
        invalidatePendingSelection: Bool = false,
        markSelectionInactive: Bool = true,
        deactivateInspectEvents: Bool = true
    ) {
        inspectModeTargetIdentifier = nil
        if deactivateInspectEvents {
            acceptsInspectEvents = false
        }
        if markSelectionInactive {
            isSelectingElement = false
        }
        if invalidatePendingSelection {
            pendingInspectSelection = nil
            selectionGeneration &+= 1
        }
    }

    private func cancelInspectMode(
        targetIdentifier: String?,
        invalidatePendingSelection: Bool = false,
        restoreSelectedHighlight: Bool = false
    ) async {
        clearInspectModeState(
            invalidatePendingSelection: invalidatePendingSelection,
            markSelectionInactive: false,
            deactivateInspectEvents: true
        )

        if let targetIdentifier {
            do {
                _ = try await sendDOMCommand(
                    WITransportMethod.DOM.setInspectModeEnabled,
                    targetIdentifier: targetIdentifier,
                    parameters: DOMSetInspectModeEnabledParameters.disabled
                )
            } catch {
                logSelectionDiagnostics(
                    "finishInspectMode failed to disable inspect mode",
                    extra: error.localizedDescription,
                    level: .error
                )
            }
        }

#if canImport(UIKit)
        await awaitInspectModeInactive()
        isSelectingElement = false
#else
        isSelectingElement = false
#endif

        if restoreSelectedHighlight,
           let contextID = currentContext?.contextID,
           document.selectedNode != nil {
            await syncSelectedNodeHighlight(contextID: contextID)
        }
    }

    private func completeInspectModeAfterBackendSelection(
        invalidatePendingSelection: Bool = false
    ) async {
        let activeTargetIdentifier = inspectModeTargetIdentifier ?? phase.targetIdentifier
        clearInspectModeState(
            invalidatePendingSelection: invalidatePendingSelection,
            markSelectionInactive: false,
            deactivateInspectEvents: false
        )

        if let activeTargetIdentifier {
            do {
                try await setInspectModeEnabled(false, targetIdentifier: activeTargetIdentifier)
            } catch {
                logSelectionDiagnostics(
                    "completeInspectModeAfterBackendSelection failed to disable inspect mode",
                    extra: error.localizedDescription,
                    level: .error
                )
            }
        }

#if canImport(UIKit)
        await awaitInspectModeInactive()
        isSelectingElement = false
#else
        isSelectingElement = false
#endif
    }

    func setInspectModeEnabled(
        _ enabled: Bool,
        targetIdentifier: String
    ) async throws {
        if enabled {
            _ = try await sendDOMCommand(
                WITransportMethod.DOM.setInspectModeEnabled,
                targetIdentifier: targetIdentifier,
                parameters: DOMSetInspectModeEnabledParameters.enabled
            )
#if canImport(UIKit)
            setNativeInspectorNodeSearchEnabled(true)
#endif
        } else {
            _ = try await sendDOMCommand(
                WITransportMethod.DOM.setInspectModeEnabled,
                targetIdentifier: targetIdentifier,
                parameters: DOMSetInspectModeEnabledParameters.disabled
            )
        }
    }

    func handleInspectEvent(
        nodeID: Int,
        contextID: DOMContextID,
        targetIdentifier: String
    ) async {
        guard currentContext?.contextID == contextID else {
            return
        }
        logSelectionDiagnostics(
            "handleInspectEvent received transport inspect",
            extra: "nodeID=\(nodeID) contextID=\(contextID) generation=\(selectionGeneration)"
        )
        await completeInspectModeAfterBackendSelection()
        guard let transaction = selectionTransaction(for: contextID) else {
            return
        }
        await commitInspectedNodeIfPossible(
            nodeID: nodeID,
            contextID: contextID,
            selectorPath: nil,
            targetIdentifier: targetIdentifier,
            transaction: transaction
        )
    }

    private func handleInspectorInspectEvent(
        objectID: String,
        contextID: DOMContextID,
        targetIdentifier: String
    ) async {
        guard currentContext?.contextID == contextID else {
            return
        }

        await completeInspectModeAfterBackendSelection()
        guard let transaction = selectionTransaction(for: contextID) else {
            return
        }

        do {
            let nodeID = try await transportNodeID(
                forRemoteObjectID: objectID,
                targetIdentifier: targetIdentifier
            )
            await commitInspectedNodeIfPossible(
                nodeID: nodeID,
                contextID: contextID,
                selectorPath: nil,
                targetIdentifier: targetIdentifier,
                transaction: transaction
            )
        } catch {
            logSelectionDiagnostics(
                "Inspector.inspect failed to resolve node",
                extra: error.localizedDescription,
                level: .error
            )
            await clearSelectionForFailedResolution(
                contextID: contextID,
                transaction: transaction,
                errorMessage: "Failed to resolve selected element."
            )
        }
    }

    private func commitInspectedNodeIfPossible(
        nodeID: Int,
        contextID: DOMContextID,
        selectorPath: String?,
        targetIdentifier: String,
        transaction: SelectionTransaction?
    ) async {
        guard currentContext?.contextID == contextID,
              selectionTransactionIsCurrent(transaction) else {
            return
        }

        if let node = resolvedInspectedNodeFromCurrentDocument(nodeID: nodeID) {
            await applySelection(
                to: node,
                selectorPath: selectorPath,
                contextID: contextID
            )
            finishInspectSelectionResolution()
            applyRecoverableError(nil)
            return
        }

        _ = await materializePendingInspectSelection(
            nodeID: nodeID,
            selectorPath: selectorPath,
            contextID: contextID,
            targetIdentifier: targetIdentifier,
            transaction: transaction
        )

        if document.selectedNode != nil {
            await syncSelectedNodeHighlight(contextID: contextID)
            applyRecoverableError(nil)
        }
    }

    private func finishInspectSelectionResolution() {
        pendingInspectSelection = nil
        acceptsInspectEvents = false
    }

    private func upsertPendingInspectSelection(
        nodeID: Int,
        contextID: DOMContextID,
        selectorPath: String?,
        transaction: SelectionTransaction?
    ) -> PendingInspectSelection {
        let existing = pendingInspectSelection
        let shouldPreserveRequestState = existing?.contextID == contextID && existing?.transaction == transaction
        let pendingSelection = PendingInspectSelection(
            nodeID: nodeID,
            contextID: contextID,
            selectorPath: selectorPath,
            transaction: transaction,
            materializedAncestorNodeIDs: shouldPreserveRequestState ? existing?.materializedAncestorNodeIDs ?? [] : [],
            outstandingMaterializationNodeIDs: shouldPreserveRequestState ? existing?.outstandingMaterializationNodeIDs ?? [] : []
        )
        pendingInspectSelection = pendingSelection
        return pendingSelection
    }

#if canImport(UIKit)
    func handlePointerInspectSelectionImpl(at point: CGPoint) async {
        guard isSelectingElement else {
            return
        }
        guard let contextID = phase.context?.contextID,
              let targetIdentifier = inspectModeTargetIdentifier ?? phase.targetIdentifier else {
            return
        }

        logSelectionDiagnostics(
            "pointer inspect received tap",
            extra: "point=\(point)"
        )

        var didFinishInspectMode = false
        var currentTransaction: SelectionTransaction?
        do {
            let objectID = try await nodeObjectIDAtViewportPoint(point, targetIdentifier: targetIdentifier)
            logSelectionDiagnostics(
                "pointer inspect resolved remote object",
                extra: "point=\(point) objectID=\(objectID)"
            )
            await cancelInspectMode(targetIdentifier: targetIdentifier)
            didFinishInspectMode = true
            guard let transaction = selectionTransaction(for: contextID) else {
                return
            }
            currentTransaction = transaction
            let response = try await sendDOMCommand(
                WITransportMethod.DOM.requestNode,
                targetIdentifier: targetIdentifier,
                parameters: DOMRequestNodeParameters(objectId: objectID)
            )
            await awaitTransportMessagesToDrain()
            guard let nodeID = intValue(response["nodeId"]) else {
                logSelectionDiagnostics(
                    "pointer inspect DOM.requestNode returned no node",
                    extra: selectionLogValue(response),
                    level: .error
                )
                await clearSelectionForFailedResolution(
                    contextID: contextID,
                    transaction: transaction,
                    errorMessage: "Failed to resolve selected element."
                )
                return
            }
            logSelectionDiagnostics(
                "pointer inspect resolved transport node",
                extra: "nodeID=\(nodeID)"
            )

            try await applyInspectedNode(
                nodeID: nodeID,
                contextID: contextID,
                selectorPath: nil,
                transaction: transaction
            )
        } catch {
            if didFinishInspectMode == false {
                await cancelInspectMode(
                    targetIdentifier: targetIdentifier,
                    restoreSelectedHighlight: true
                )
            }
            logSelectionDiagnostics(
                "pointer inspect failed",
                extra: "\(error)",
                level: .error
            )
            await clearSelectionForFailedResolution(
                contextID: contextID,
                transaction: currentTransaction,
                errorMessage: "Failed to resolve selected element."
            )
        }
    }

    private func nodeObjectIDAtViewportPoint(
        _ point: CGPoint,
        targetIdentifier: String
    ) async throws -> String {
        let expression = """
        (() => {
            const x = \(point.x);
            const y = \(point.y);
            const viewport = window.visualViewport;
            const scale = viewport && viewport.scale ? viewport.scale : 1;
            const offsetLeft = viewport ? viewport.offsetLeft : 0;
            const offsetTop = viewport ? viewport.offsetTop : 0;
            const candidates = [
                [x, y],
                [x / scale + offsetLeft, y / scale + offsetTop],
                [x * scale + offsetLeft, y * scale + offsetTop],
                [Math.min(window.innerWidth - 1, Math.max(0, x)), Math.min(window.innerHeight - 1, Math.max(0, y))],
            ];
            let node = null;
            for (const [candidateX, candidateY] of candidates) {
                node = document.elementFromPoint(candidateX, candidateY);
                if (node)
                    break;
            }
            while (node && node.nodeType !== Node.ELEMENT_NODE)
                node = node.parentElement;
            return node;
        })()
        """
        let response = try await sendDOMCommand(
            WITransportMethod.Runtime.evaluate,
            targetIdentifier: targetIdentifier,
            parameters: RuntimeEvaluateParameters(
                expression: expression,
                objectGroup: "webinspectorkit-node-search",
                includeCommandLineAPI: false,
                doNotPauseOnExceptionsAndMuteConsole: true,
                returnByValue: false,
                generatePreview: false,
                emulateUserGesture: true
            )
        )
        guard let remoteObject = response["result"] as? [String: Any],
              let objectID = stringValue(remoteObject["objectId"]) else {
            logSelectionDiagnostics(
                "pointer inspect Runtime.evaluate returned no object",
                extra: selectionLogValue(response),
                level: .error
            )
            throw DOMOperationError.invalidSelection
        }
        return objectID
    }
#endif

    private func transportNodeID(
        forRemoteObjectID objectID: String,
        targetIdentifier: String
    ) async throws -> Int {
        let response = try await sendDOMCommand(
            WITransportMethod.DOM.requestNode,
            targetIdentifier: targetIdentifier,
            parameters: DOMRequestNodeParameters(objectId: objectID)
        )
        guard let nodeID = intValue(response["nodeId"]) else {
            throw DOMOperationError.invalidSelection
        }
        return nodeID
    }

    private func applyInspectedNode(
        nodeID: Int,
        contextID: DOMContextID,
        selectorPath: String?,
        transaction: SelectionTransaction?
    ) async throws {
        guard currentContext?.contextID == contextID,
              selectionTransactionIsCurrent(transaction) else {
            return
        }

        if let node = resolvedInspectedNodeFromCurrentDocument(nodeID: nodeID) {
            logSelectionDiagnostics(
                "applyInspectedNode resolved transport node",
                selector: selectorPath,
                extra: selectionNodeSummary(node)
            )
            await applySelection(
                to: node,
                selectorPath: selectorPath,
                contextID: contextID
            )
            applyRecoverableError(nil)
            return
        }

        if let targetIdentifier = phase.targetIdentifier ?? sharedTransport.currentPageTargetIdentifier() {
            let requestedNodes = await materializePendingInspectSelection(
                nodeID: nodeID,
                selectorPath: selectorPath,
                contextID: contextID,
                targetIdentifier: targetIdentifier,
                transaction: transaction
            )
            if requestedNodes > 0 {
                return
            }
        }

        guard selectionTransactionIsCurrent(transaction) else {
            return
        }

        logSelectionDiagnostics(
            "applyInspectedNode could not resolve transport node",
            selector: selectorPath,
            extra: "nodeID=\(nodeID) contextID=\(contextID) generation=\(transaction.map { String($0.generation) } ?? "nil")",
            level: .error
        )
        if pendingInspectSelection?.nodeID == nodeID,
           pendingInspectSelection?.contextID == contextID {
            pendingInspectSelection = nil
        }
        await clearSelectionForFailedResolution(
            contextID: contextID,
            transaction: transaction,
            errorMessage: "Failed to resolve selected element."
        )
        throw DOMOperationError.invalidSelection
    }

    @discardableResult
    private func materializePendingInspectSelection(
        nodeID: Int,
        selectorPath: String?,
        contextID: DOMContextID,
        targetIdentifier: String,
        transaction: SelectionTransaction?
    ) async -> Int {
        guard currentContext?.contextID == contextID,
              selectionTransactionIsCurrent(transaction) else {
            return 0
        }

        var pendingInspectSelection = upsertPendingInspectSelection(
            nodeID: nodeID,
            contextID: contextID,
            selectorPath: selectorPath,
            transaction: transaction
        )

        let candidates = selectionMaterializationCandidates()
        if candidates.isEmpty {
            return 0
        }

        let unresolvedCandidates = candidates.filter {
            pendingInspectSelection.materializedAncestorNodeIDs.contains($0.id) == false
        }
        if unresolvedCandidates.isEmpty {
            self.pendingInspectSelection = pendingInspectSelection
            return pendingInspectSelection.outstandingMaterializationNodeIDs.count
        }

        let unresolvedCandidateIDs = Set(unresolvedCandidates.map(\.id))
        pendingInspectSelection.materializedAncestorNodeIDs.formUnion(unresolvedCandidateIDs)
        pendingInspectSelection.outstandingMaterializationNodeIDs.formUnion(unresolvedCandidateIDs)
        self.pendingInspectSelection = pendingInspectSelection

        var requestedNodes = 0
        for candidate in unresolvedCandidates {
            guard currentContext?.contextID == contextID,
                  selectionTransactionIsCurrent(transaction) else {
                return pendingInspectSelection.outstandingMaterializationNodeIDs.count
            }
            guard let transportNodeID = try? transportNodeID(for: candidate) else {
                pendingInspectSelection.materializedAncestorNodeIDs.remove(candidate.id)
                pendingInspectSelection.outstandingMaterializationNodeIDs.remove(candidate.id)
                self.pendingInspectSelection = pendingInspectSelection
                continue
            }
            do {
                _ = try await sendDOMCommand(
                    WITransportMethod.DOM.requestChildNodes,
                    targetIdentifier: targetIdentifier,
                    parameters: DOMRequestChildNodesParameters(
                        nodeId: transportNodeID,
                        depth: max(configuration.snapshotDepth, 128)
                    )
                )
                requestedNodes += 1
            } catch {
                pendingInspectSelection.materializedAncestorNodeIDs.remove(candidate.id)
                pendingInspectSelection.outstandingMaterializationNodeIDs.remove(candidate.id)
                self.pendingInspectSelection = pendingInspectSelection
                logSelectionDiagnostics(
                    "materializePendingInspectSelection requestChildNodes failed",
                    extra: "nodeID=\(transportNodeID) error=\(error.localizedDescription)",
                    level: .error
                )
            }
        }
        self.pendingInspectSelection = pendingInspectSelection
        return pendingInspectSelection.outstandingMaterializationNodeIDs.count
    }

    private func selectionMaterializationCandidates() -> [DOMNodeModel] {
        guard let root = document.rootNode else {
            return []
        }

        var queue: [DOMNodeModel] = [root]
        var incompleteCandidates: [DOMNodeModel] = []

        while !queue.isEmpty {
            let node = queue.removeFirst()
            if node !== root,
               node.childCount > node.children.count {
                incompleteCandidates.append(node)
            }
            queue.append(contentsOf: node.children)
        }

        if incompleteCandidates.isEmpty == false {
            return incompleteCandidates
        }

        if let bodyNode = firstNode(in: root, where: {
            ($0.localName.isEmpty ? $0.nodeName.lowercased() : $0.localName.lowercased()) == "body"
        }) {
            return [bodyNode]
        }

        if let htmlNode = firstNode(in: root, where: {
            ($0.localName.isEmpty ? $0.nodeName.lowercased() : $0.localName.lowercased()) == "html"
        }) {
            return [htmlNode]
        }

        if let firstStructuredChild = root.children.first(where: {
            let name = ($0.localName.isEmpty ? $0.nodeName : $0.localName).lowercased()
            return !name.isEmpty && !name.hasPrefix("#")
        }) {
            return [firstStructuredChild]
        }

        return [root]
    }

    func applySelection(
        to node: DOMNodeModel,
        selectorPath: String?,
        contextID: DOMContextID,
        preferredSubtreeRootNodeIDs: Set<DOMNodeModel.ID> = []
    ) async {
        if let subtreeRoot = selectionSubtreeRoot(
            for: node,
            preferredNodeIDs: preferredSubtreeRootNodeIDs
        ) {
            await inspectorBridge.applySubtreePayload(
                nodePayloadDictionary(from: subtreeRoot),
                contextID: contextID
            )
        }
        var payload = selectionPayload(for: node)
        if let selectorPath, !selectorPath.isEmpty {
            payload.selectorPath = selectorPath
        }
        document.applySelectionSnapshot(payload)
        await inspectorBridge.applySelectionPayload(
            selectionPayloadDictionary(from: payload),
            contextID: contextID
        )
        await syncSelectedNodeHighlight(contextID: contextID)
        logSelectionDiagnostics(
            "applySelection updated document and frontend",
            selector: selectorPath,
            extra: selectionNodeSummary(node)
        )
    }

    func applyPendingInspectSelectionIfPossible() async {
        guard let pendingInspectSelection else {
            return
        }
        guard currentContext?.contextID == pendingInspectSelection.contextID,
              selectionTransactionIsCurrent(pendingInspectSelection.transaction) else {
            self.pendingInspectSelection = nil
            return
        }
        guard let node = resolvedInspectedNodeFromCurrentDocument(nodeID: pendingInspectSelection.nodeID) else {
            return
        }

        self.pendingInspectSelection = nil
        logSelectionDiagnostics(
            "applyPendingInspectSelectionIfPossible resolved transport node",
            selector: pendingInspectSelection.selectorPath,
            extra: selectionNodeSummary(node)
        )
        await applySelection(
            to: node,
            selectorPath: pendingInspectSelection.selectorPath,
            contextID: pendingInspectSelection.contextID,
            preferredSubtreeRootNodeIDs: pendingInspectSelection.materializedAncestorNodeIDs
        )
        finishInspectSelectionResolution()
        applyRecoverableError(nil)
    }

    private func finishPendingInspectMaterialization(
        from bundle: DOMGraphMutationBundle,
        contextID: DOMContextID
    ) async {
        guard var pendingInspectSelection else {
            return
        }
        guard pendingInspectSelection.contextID == contextID,
              selectionTransactionIsCurrent(pendingInspectSelection.transaction) else {
            self.pendingInspectSelection = nil
            return
        }

        let completedNodeIDs = Set(
            completedChildRequestNodeIDs(from: bundle).map {
                DOMNodeModel.ID(documentIdentity: document.documentIdentity, localID: UInt64($0))
            }
        )
        let relevantCompletedNodeIDs = completedNodeIDs.intersection(
            pendingInspectSelection.outstandingMaterializationNodeIDs
        )
        guard relevantCompletedNodeIDs.isEmpty == false else {
            return
        }

        pendingInspectSelection.outstandingMaterializationNodeIDs.subtract(relevantCompletedNodeIDs)
        self.pendingInspectSelection = pendingInspectSelection
        guard pendingInspectSelection.outstandingMaterializationNodeIDs.isEmpty else {
            return
        }
        guard resolvedInspectedNodeFromCurrentDocument(nodeID: pendingInspectSelection.nodeID) == nil else {
            return
        }

        if let targetIdentifier = phase.targetIdentifier ?? sharedTransport.currentPageTargetIdentifier() {
            let requestedNodes = await materializePendingInspectSelection(
                nodeID: pendingInspectSelection.nodeID,
                selectorPath: pendingInspectSelection.selectorPath,
                contextID: pendingInspectSelection.contextID,
                targetIdentifier: targetIdentifier,
                transaction: pendingInspectSelection.transaction
            )
            if requestedNodes > 0 {
                return
            }
        }

        self.pendingInspectSelection = nil
        await clearSelectionForFailedResolution(
            contextID: contextID,
            transaction: pendingInspectSelection.transaction,
            errorMessage: "Failed to resolve selected element."
        )
    }

    private func selectionSubtreeRoot(
        for node: DOMNodeModel,
        preferredNodeIDs: Set<DOMNodeModel.ID> = []
    ) -> DOMNodeModel? {
        if !preferredNodeIDs.isEmpty {
            var preferredCurrent: DOMNodeModel? = node
            while let candidate = preferredCurrent {
                if preferredNodeIDs.contains(candidate.id) {
                    return candidate
                }
                if candidate.parent?.nodeType == 9 {
                    break
                }
                preferredCurrent = candidate.parent
            }
        }

        var current: DOMNodeModel? = node
        var topmostRenderable: DOMNodeModel? = node

        while let parent = current?.parent {
            if parent.nodeType == 9 {
                break
            }
            topmostRenderable = parent
            current = parent
        }

        return topmostRenderable
    }

    private func clearSelectionForFailedResolution(
        contextID: DOMContextID?,
        transaction: SelectionTransaction? = nil,
        errorMessage: String
    ) async {
        guard selectionTransactionIsCurrent(transaction) else {
            logSelectionDiagnostics(
                "clearSelectionForFailedResolution ignored stale transaction",
                extra: "contextID=\(contextID.map(String.init) ?? "nil") generation=\(transaction.map { String($0.generation) } ?? "nil")"
            )
            return
        }
        logSelectionDiagnostics(
            "clearSelectionForFailedResolution",
            extra: "contextID=\(contextID.map(String.init) ?? "nil") generation=\(transaction.map { String($0.generation) } ?? "nil") error=\(errorMessage)",
            level: .error
        )
        if transaction != nil {
            pendingInspectSelection = nil
            acceptsInspectEvents = false
        }
        document.clearSelection()
        try? await hideHighlight()
        if let contextID {
            await inspectorBridge.applySelectionPayload(
                selectionPayloadDictionary(from: nil),
                contextID: contextID
            )
        }
        applyRecoverableError(errorMessage)
    }

#if DEBUG
    func resolveTestingSelectorNode(_ cssSelector: String) -> DOMNodeModel? {
        let selector = cssSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selector.isEmpty else {
            return nil
        }

        // Test fixtures only need a deterministic subset.
        if selector.contains(where: \.isWhitespace) || selector.contains(">") {
            return nil
        }

        return firstNode(in: document.rootNode) { node in
            if selector.hasPrefix("#") {
                let idSelector = String(selector.dropFirst())
                return node.attributes.contains {
                    $0.name == "id" && $0.value == idSelector
                }
            }

            if selector.hasPrefix(".") {
                let classSelector = String(selector.dropFirst())
                return node.attributes.contains {
                    $0.name == "class"
                        && $0.value.split(separator: " ").contains(Substring(classSelector))
                }
            }

            let normalizedSelector = selector.lowercased()
            let nodeName = node.localName.isEmpty ? node.nodeName.lowercased() : node.localName.lowercased()
            if nodeName == normalizedSelector {
                return true
            }

            let preview = selectionPreview(for: node)
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                .lowercased()
            return preview == normalizedSelector
        }
    }

    func resolveTestingPreviewNode(_ preview: String) -> DOMNodeModel? {
        let normalizedPreview = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPreview.isEmpty else {
            return nil
        }
        return firstNode(in: document.rootNode) { node in
            selectionPreview(for: node) == normalizedPreview
        }
    }

    private func requestTestingChildNodesAndWaitForCompletion(
        transportNodeID: Int,
        frontendNodeID: Int,
        targetIdentifier: String,
        contextID: DOMContextID,
        depth: Int
    ) async -> Bool {
        guard let registration = registerPendingChildRequest(
            nodeID: frontendNodeID,
            contextID: contextID,
            reportsToFrontend: false
        ) else {
            return false
        }

        if registration.shouldSendRequest {
            do {
                _ = try await sendDOMCommand(
                    WITransportMethod.DOM.requestChildNodes,
                    targetIdentifier: targetIdentifier,
                    parameters: DOMRequestChildNodesParameters(
                        nodeId: transportNodeID,
                        depth: max(1, depth)
                    )
                )
            } catch {
                await completePendingChildRequest(
                    nodeID: frontendNodeID,
                    contextID: contextID,
                    success: false
                )
                return false
            }
        }

        return await waitForPendingChildRequestCompletion(
            registration.record,
            nodeID: frontendNodeID,
            contextID: contextID
        )
    }
#endif

    func logSelectionDiagnostics(
        _ message: String,
        selector: String? = nil,
        extra: String? = nil,
        level: OSLogType = .default
    ) {
        let selectorPart = selector.map { " selector=\($0)" } ?? ""
        let extraPart = extra.map { " \($0)" } ?? ""
        let summary = selectionRuntimeSummary()
        let composed = "\(message)\(selectorPart)\(extraPart) \(summary)"
        lastSelectionDiagnosticMessage = composed
        switch level {
        case .error, .fault:
            domViewLogger.error("\(composed, privacy: .public)")
        case .debug:
            domViewLogger.debug("\(composed, privacy: .public)")
        default:
            domViewLogger.notice("\(composed, privacy: .public)")
        }
    }

    func selectionRuntimeSummary() -> String {
        let phaseDescription: String
        switch phase {
        case .idle:
            phaseDescription = "idle"
        case let .waitingForTarget(context):
            phaseDescription = "waitingForTarget(\(context.contextID))"
        case let .loadingDocument(context, targetIdentifier):
            phaseDescription = "loadingDocument(\(context.contextID),target=\(targetIdentifier))"
        case let .ready(context, targetIdentifier):
            phaseDescription = "ready(\(context.contextID),target=\(targetIdentifier))"
        }

        return "phase=\(phaseDescription) documentURL=\(currentContext?.documentURL ?? "nil") root=\(selectionNodeSummary(document.rootNode)) selected=\(selectionNodeSummary(document.selectedNode))"
    }

    func logBootstrapDiagnostics(_ message: String) {
        domViewLogger.debug("[WebInspectorDOM] \(message, privacy: .public)")
    }

    func selectionNodeSummary(_ node: DOMNodeModel?) -> String {
        guard let node else {
            return "nil"
        }
        let nodeName = node.localName.isEmpty ? node.nodeName : node.localName
        return "\(nodeName)#local=\(node.localID)#backend=\(node.backendNodeID.map(String.init) ?? "nil")#children=\(node.children.count)/\(node.childCount)#selector=\(node.selectorPath.nilIfEmpty ?? "nil")"
    }

    func selectionVisibleNodeSummaries(limit: Int) -> [String] {
        var collected: [String] = []
        func visit(_ node: DOMNodeModel?) {
            guard let node, collected.count < limit else {
                return
            }
            collected.append(selectionNodeSummary(node))
            for child in node.children {
                visit(child)
                if collected.count >= limit {
                    return
                }
            }
        }
        visit(document.rootNode)
        return collected
    }

    func selectionLogValue(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: value)
    }

    func firstNode(
        in root: DOMNodeModel?,
        where predicate: (DOMNodeModel) -> Bool
    ) -> DOMNodeModel? {
        guard let root else {
            return nil
        }
        if predicate(root) {
            return root
        }
        for child in root.children {
            if let match = firstNode(in: child, where: predicate) {
                return match
            }
        }
        return nil
    }

    func resolvedInspectedNodeFromCurrentDocument(nodeID: Int) -> DOMNodeModel? {
        if let node = document.node(localID: UInt64(nodeID)) {
            return node
        }
        return document.node(backendNodeID: nodeID)
    }

    private func selectionTransaction(for contextID: DOMContextID) -> SelectionTransaction? {
        guard currentContext?.contextID == contextID else {
            return nil
        }
        return SelectionTransaction(contextID: contextID, generation: selectionGeneration)
    }

    private func selectionTransactionIsCurrent(_ transaction: SelectionTransaction?) -> Bool {
        guard let transaction else {
            return true
        }
        return currentContext?.contextID == transaction.contextID
            && selectionGeneration == transaction.generation
    }

    func selectionPayload(for node: DOMNodeModel) -> DOMSelectionSnapshotPayload {
        .init(
            localID: node.localID,
            backendNodeID: node.backendNodeID,
            backendNodeIDIsStable: node.backendNodeIDIsStable,
            preview: selectionPreview(for: node),
            attributes: node.attributes,
            path: selectionPathLabels(for: node),
            selectorPath: node.selectorPath.nilIfEmpty,
            styleRevision: node.styleRevision
        )
    }

    func selectionPayloadDictionary(from payload: DOMSelectionSnapshotPayload?) -> [String: Any] {
        guard let payload else {
            return ["id": NSNull()]
        }
        return [
            "id": Int(payload.localID ?? 0),
            "backendNodeId": payload.backendNodeID as Any,
            "backendNodeIdIsStable": payload.backendNodeIDIsStable,
            "preview": payload.preview,
            "attributes": payload.attributes.map { ["name": $0.name, "value": $0.value] },
            "path": payload.path,
            "selectorPath": payload.selectorPath as Any,
            "styleRevision": payload.styleRevision,
        ]
    }

    func selectionPathLabels(for node: DOMNodeModel) -> [String] {
        var labels: [String] = []
        var current: DOMNodeModel? = node
        var guardCount = 0
        while let currentNode = current, guardCount < 200 {
            labels.insert(selectionPreview(for: currentNode), at: 0)
            current = currentNode.parent
            guardCount += 1
        }
        return labels
    }

    func selectionPreview(for node: DOMNodeModel) -> String {
        if !node.preview.isEmpty {
            return node.preview
        }
        if node.nodeType == 3 {
            return node.nodeValue
        }
        return "<\(node.localName.isEmpty ? node.nodeName.lowercased() : node.localName)>"
    }

    func node(at path: [Int], from root: DOMNodeModel?) -> DOMNodeModel? {
        var current = root
        for index in path {
            guard let node = current,
                  index >= 0,
                  index < node.children.count else {
                return nil
            }
            current = node.children[index]
        }
        return current
    }

    func copySelectionImpl(_ kind: DOMSelectionCopyKind) async throws -> String {
        guard let selectedNode = document.selectedNode else {
            throw DOMOperationError.invalidSelection
        }
        return try await copyText(for: selectedNode, kind: kind)
    }

    func copyText(
        for node: DOMNodeModel,
        kind: DOMSelectionCopyKind
    ) async throws -> String {
        switch kind {
        case .html:
            let response = try await sendDOMCommand(
                WITransportMethod.DOM.getOuterHTML,
                targetIdentifier: try requireCurrentTargetIdentifier(),
                parameters: DOMNodeIdentifierParameters(nodeId: try transportNodeID(for: node))
            )
            return stringValue(response["outerHTML"]) ?? ""
        case .selectorPath, .xpath:
            guard let target = copyTextTarget(for: node) else {
                throw DOMOperationError.invalidSelection
            }
            return try await pageBridge.selectionCopyText(target: target, kind: kind)
        }
    }

    func copyTextTarget(for node: DOMNodeModel) -> DOMRequestNodeTarget? {
        if let backendNodeID = stableBackendNodeID(for: node) {
            return .backend(backendNodeID)
        }
        if let selectorPath = node.selectorPath.nilIfEmpty {
            return .selector(selectorPath)
        }
        return nil
    }

    func stableBackendNodeID(for node: DOMNodeModel) -> Int? {
        guard let backendNodeID = node.backendNodeID,
              node.backendNodeIDIsStable,
              backendNodeID > 0 else {
            return nil
        }
        return backendNodeID
    }

    func nodePayloadDictionary(from node: DOMNodeModel) -> [String: Any] {
        [
            "id": Int(node.localID),
            "nodeId": Int(node.localID),
            "backendNodeId": node.backendNodeID as Any,
            "backendNodeIdIsStable": node.backendNodeIDIsStable,
            "nodeType": node.nodeType,
            "nodeName": node.nodeName,
            "localName": node.localName,
            "nodeValue": node.nodeValue,
            "attributes": node.attributes.flatMap { [$0.name, $0.value] },
            "childNodeCount": node.childCount,
            "childCount": node.childCount,
            "layoutFlags": node.layoutFlags,
            "isRendered": node.isRendered,
            "children": node.children.map(nodePayloadDictionary(from:)),
        ]
    }

    func sendDOMCommand(
        _ method: String,
        targetIdentifier: String,
        parametersData: Data? = nil
    ) async throws -> [String: Any] {
        guard let session = await sharedTransport.attachedSession() else {
            throw DOMOperationError.contextInvalidated
        }
        do {
            let data = try await session.sendPageData(
                method: method,
                targetIdentifier: targetIdentifier,
                parametersData: parametersData
            )
            guard !data.isEmpty else {
                return [:]
            }
            let object = try JSONSerialization.jsonObject(with: data)
            return object as? [String: Any] ?? [:]
        } catch let error as WITransportError {
            throw mapTransportError(error)
        } catch {
            throw DOMOperationError.scriptFailure(error.localizedDescription)
        }
    }

    func sendDOMCommand<Parameters: Encodable>(
        _ method: String,
        targetIdentifier: String,
        parameters: Parameters
    ) async throws -> [String: Any] {
        let data = try JSONEncoder().encode(parameters)
        return try await sendDOMCommand(
            method,
            targetIdentifier: targetIdentifier,
            parametersData: data
        )
    }

    func awaitTransportMessagesToDrain() async {
        guard let session = await sharedTransport.attachedSession() else {
            return
        }
        await session.waitForPendingMessages()
        await session.waitForPostActivePageEventsToDrain()
    }

    func syncSelectedNodeHighlight(contextID: DOMContextID) async {
        guard currentContext?.contextID == contextID,
              let targetIdentifier = phase.targetIdentifier ?? sharedTransport.currentPageTargetIdentifier() else {
            return
        }

        guard let selectedNode = document.selectedNode else {
            try? await hideHighlight()
            return
        }

        do {
            _ = try await sendDOMCommand(
                WITransportMethod.DOM.highlightNode,
                targetIdentifier: targetIdentifier,
                parameters: DOMHighlightNodeParameters(nodeId: try transportNodeID(for: selectedNode))
            )
        } catch {
            logSelectionDiagnostics(
                "syncSelectedNodeHighlight failed",
                extra: error.localizedDescription,
                level: .error
            )
        }
    }

    func mapTransportError(_ error: WITransportError) -> DOMOperationError {
        switch error {
        case .notAttached, .pageTargetUnavailable:
            return .contextInvalidated
        case .transportClosed:
            return .pageUnavailable
        case let .remoteError(_, _, message):
            return .scriptFailure(message)
        case let .requestTimedOut(_, method):
            return .scriptFailure("\(method) timed out.")
        case let .invalidResponse(reason):
            return .scriptFailure(reason)
        case let .invalidCommandEncoding(reason):
            return .scriptFailure(reason)
        case let .unsupported(reason), let .attachFailed(reason):
            return .scriptFailure(reason)
        case .alreadyAttached:
            return .contextInvalidated
        }
    }

    func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    func resetInteractionState() async {
        await cancelSelectionMode()
        await failPendingChildRequests()
        clearDeleteUndoHistory()
    }

    func applyRecoverableError(_ message: String?) {
        document.setErrorMessage(message)
        externalRecoverableErrorHandler?(message)
    }

    func errorMessage(from error: any Error) -> String? {
        if let error = error as? DOMOperationError {
            switch error {
            case .pageUnavailable:
                return "Web view unavailable."
            case .contextInvalidated:
                return "Document context changed."
            case .invalidSelection:
                return "Selection is no longer valid."
            case let .scriptFailure(message):
                return message
            }
        }
        return error.localizedDescription
    }

    private func installPageWebViewLifetimeObserver(on webView: WKWebView) {
        pageWebViewAttachmentGeneration &+= 1
        let expectedGeneration = pageWebViewAttachmentGeneration
        let observer = WIPageWebViewLifetimeObserver { [weak self] in
            guard let self else {
                return
            }
            self.handleAttachedPageWebViewReleased(expectedGeneration: expectedGeneration)
        }
        unsafe objc_setAssociatedObject(
            webView,
            pageWebViewLifetimeObserverAssociationKey,
            observer,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private func handleAttachedPageWebViewReleased(expectedGeneration: UInt64) {
        guard pageWebViewAttachmentGeneration == expectedGeneration,
              pageWebView == nil else {
            return
        }
        hasPageWebView = false
    }
}

#if canImport(UIKit)
extension WIDOMInspector {
    package func handlePointerInspectSelection(at point: CGPoint) async {
        await handlePointerInspectSelectionImpl(at: point)
    }
}
#endif

private struct DOMSetInspectModeEnabledParameters: Encodable {
    struct RGBAColor: Encodable {
        let r: Int
        let g: Int
        let b: Int
        let a: Double
    }

    struct HighlightConfig: Encodable {
        let showInfo: Bool
        let contentColor = RGBAColor(r: 111, g: 168, b: 220, a: 0.66)
        let paddingColor = RGBAColor(r: 147, g: 196, b: 125, a: 0.66)
        let borderColor = RGBAColor(r: 255, g: 229, b: 153, a: 0.66)
        let marginColor = RGBAColor(r: 246, g: 178, b: 107, a: 0.66)
    }

    let enabled: Bool
    let highlightConfig: HighlightConfig?

    static let enabled = DOMSetInspectModeEnabledParameters(
        enabled: true,
        highlightConfig: .init(showInfo: false)
    )

    static let disabled = DOMSetInspectModeEnabledParameters(
        enabled: false,
        highlightConfig: nil
    )
}

private struct DOMRequestChildNodesParameters: Encodable {
    let nodeId: Int
    let depth: Int
}

private struct DOMRequestNodeParameters: Encodable {
    let objectId: String
}

private struct DOMQuerySelectorParameters: Encodable {
    let nodeId: Int
    let selector: String
}

private struct RuntimeEvaluateParameters: Encodable {
    let expression: String
    let objectGroup: String?
    let includeCommandLineAPI: Bool?
    let doNotPauseOnExceptionsAndMuteConsole: Bool?
    let returnByValue: Bool?
    let generatePreview: Bool?
    let emulateUserGesture: Bool?
}

private struct DOMNodeIdentifierParameters: Encodable {
    let nodeId: Int
}

private struct DOMSetAttributeValueParameters: Encodable {
    let nodeId: Int
    let name: String
    let value: String
}

private struct DOMRemoveAttributeParameters: Encodable {
    let nodeId: Int
    let name: String
}

private struct DOMHighlightNodeParameters: Encodable {
    struct HighlightConfig: Encodable {
        let showInfo = false
    }

    let nodeId: Int
    let highlightConfig = HighlightConfig()
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private func normalizedDocumentURL(_ documentURL: String?) -> String? {
    guard let documentURL, !documentURL.isEmpty else {
        return nil
    }
    guard var components = URLComponents(string: documentURL) else {
        return documentURL
    }
    components.fragment = nil
    return components.string ?? documentURL
}

extension WIDOMInspector {
    func restoreInspectorHighlightAfterPointerDisconnect() async {
        if let contextID = currentContext?.contextID,
           document.selectedNode != nil {
            await syncSelectedNodeHighlight(contextID: contextID)
        } else {
            try? await hideHighlight()
        }
    }
}

#if DEBUG
extension WIDOMInspector {
    package var testCurrentContextID: DOMContextID? {
        currentContext?.contextID
    }

    package var testCurrentDocumentURL: String? {
        currentContext?.documentURL
    }

    package var testIsReady: Bool {
        if case .ready = phase {
            return true
        }
        return false
    }

    package func testHandleTransportEvent(_ envelope: WITransportEventEnvelope) async {
        await handleTransportEvent(envelope)
    }

    func testHandleInspectorMessage(_ message: DOMInspectorBridge.IncomingMessage) {
        handleInspectorMessage(message)
    }

    package func testHandleReadyMessage(contextID: DOMContextID) {
        handleInspectorMessage(.ready(contextID: contextID))
    }

    package func testWaitForBootstrap() async {
        await bootstrapTask?.value
    }

    package func testSetLoadingPhase(targetIdentifier: String) {
        guard let currentContext else {
            return
        }
        phase = .loadingDocument(currentContext, targetIdentifier: targetIdentifier)
    }

    package func testBeginFreshContext(
        documentURL: String?,
        targetIdentifier: String?,
        loadImmediately: Bool,
        isFreshDocument: Bool
    ) async {
        await beginFreshContext(
            documentURL: documentURL,
            targetIdentifier: targetIdentifier,
            loadImmediately: loadImmediately,
            isFreshDocument: isFreshDocument
        )
    }

    package func testSetPendingInspectSelection(
        nodeID: Int,
        contextID: DOMContextID,
        outstandingLocalIDs: [UInt64]
    ) {
        let trackedIDs = Set(
            outstandingLocalIDs.map {
                DOMNodeModel.ID(documentIdentity: document.documentIdentity, localID: $0)
            }
        )
        pendingInspectSelection = PendingInspectSelection(
            nodeID: nodeID,
            contextID: contextID,
            selectorPath: nil,
            transaction: selectionTransaction(for: contextID),
            materializedAncestorNodeIDs: trackedIDs,
            outstandingMaterializationNodeIDs: trackedIDs
        )
    }

    package var testPendingInspectOutstandingLocalIDs: [UInt64] {
        guard let pendingInspectSelection else {
            return []
        }
        return pendingInspectSelection.outstandingMaterializationNodeIDs
            .map(\.localID)
            .sorted()
    }

    package var testHasPendingInspectSelection: Bool {
        pendingInspectSelection != nil
    }

    package var testPendingChildRequestNodeIDs: [Int] {
        pendingChildRequests.keys
            .map(\.nodeID)
            .sorted()
    }

    package func testFinishPendingInspectMaterialization(
        parentLocalID: UInt64,
        contextID: DOMContextID
    ) async {
        await finishPendingInspectMaterialization(
            from: DOMGraphMutationBundle(
                events: [
                    .setChildNodes(parentLocalID: parentLocalID, nodes: [])
                ]
            ),
            contextID: contextID
        )
    }
}
#endif
