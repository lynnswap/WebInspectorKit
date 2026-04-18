import OSLog
import Observation
import WebKit
import WebInspectorEngine

#if canImport(UIKit)
import UIKit
#endif

private let domViewLogger = Logger(subsystem: "WebInspectorKit", category: "WIDOMInspector")
private let domDeleteUndoHistoryLimit = 128

@MainActor
@Observable
public final class WIDOMInspector {
    private enum Phase: Equatable {
        case idle
        case bootstrapping(DOMContext)
        case ready(DOMContext)

        var context: DOMContext? {
            switch self {
            case .idle:
                nil
            case let .bootstrapping(context), let .ready(context):
                context
            }
        }

        func matches(_ contextID: DOMContextID?) -> Bool {
            guard let contextID else {
                return false
            }
            return context?.contextID == contextID
        }
    }

    fileprivate final class SelectionRequest {}

    fileprivate struct DeleteUndoState {
        let undoToken: Int
        let nodeID: Int
        let nodeLocalID: UInt64?
        let contextID: DOMContextID
        let restoreSelection: DOMSelectionSnapshotPayload?
    }

    @ObservationIgnored package let pageBridge: DOMPageBridge
    @ObservationIgnored let inspectorBridge: DOMInspectorBridge
    @ObservationIgnored private let payloadNormalizer = DOMPayloadNormalizer()

    public let document: DOMDocumentModel
    public private(set) var isSelectingElement = false

    @ObservationIgnored private var configuration: DOMConfiguration
    @ObservationIgnored package weak var pageWebView: WKWebView?
    @ObservationIgnored private var phase: Phase = .idle
    @ObservationIgnored private var currentContext: DOMContext?
    @ObservationIgnored private var nextContextID: DOMContextID = 1
    @ObservationIgnored private var documentURL: String?
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var navigationObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var autoSnapshotEnabled = false
    @ObservationIgnored private var externalRecoverableErrorHandler: (@MainActor (String?) -> Void)?
    @ObservationIgnored private var activeSelectionRequest: SelectionRequest?
    @ObservationIgnored private var selectionInteractionTask: Task<Void, Never>?
    @ObservationIgnored private var selectionInteractionGeneration: UInt64 = 0
    @ObservationIgnored private var pendingDeleteTask: Task<Void, Never>?
    @ObservationIgnored private weak var deleteUndoManager: UndoManager?
    @ObservationIgnored private var pendingChildRequests: Set<Int> = []

#if canImport(UIKit)
    @ObservationIgnored package var scrollBackup: (isScrollEnabled: Bool, isPanEnabled: Bool)?
    @ObservationIgnored package weak var sceneActivationRequestingScene: UIScene?
#endif

    public init(
        configuration: DOMConfiguration = .init(),
        onRecoverableError: (@MainActor (String?) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.pageBridge = DOMPageBridge(configuration: configuration)
        self.inspectorBridge = DOMInspectorBridge()
        self.document = DOMDocumentModel()
        self.externalRecoverableErrorHandler = onRecoverableError

        pageBridge.onEvent = { [weak self] event in
            self?.handlePageEvent(event)
        }
        inspectorBridge.onMessage = { [weak self] message in
            self?.handleInspectorMessage(message)
        }
    }

    isolated deinit {
        bootstrapTask?.cancel()
        selectionInteractionTask?.cancel()
        pendingDeleteTask?.cancel()
    }

    public var hasPageWebView: Bool {
        pageWebView != nil
    }

    package func setRecoverableErrorHandler(_ handler: (@MainActor (String?) -> Void)?) {
        externalRecoverableErrorHandler = handler
    }

    package func makeInspectorWebView() -> WKWebView {
        inspectorBridge.makeInspectorWebView(bootstrapPayload: bootstrapPayload())
    }

    package func attach(to webView: WKWebView) async {
        if pageWebView === webView, currentContext != nil {
            return
        }

        await resetInteractionState()
        if pageWebView !== webView {
            await detachCurrentPageIfNeeded()
        }
        pageWebView = webView
        observeNavigation(on: webView)
        await beginFreshBootstrap(on: webView, documentURL: normalizedDocumentURL(webView.url?.absoluteString))
    }

    package func suspend() async {
        await resetInteractionState()
        await detachCurrentPageIfNeeded()
        pageWebView = nil
        navigationObservations.removeAll()
        cancelBootstrap()
        clearContextState()
        updateInspectorBootstrap()
    }

    package func detach() async {
        await suspend()
        inspectorBridge.detachInspectorWebView()
    }

    package func setAutoSnapshotEnabled(_ enabled: Bool) async {
        autoSnapshotEnabled = enabled
        guard let pageWebView, let currentContext else {
            return
        }
        await pageBridge.installOrUpdateBootstrap(
            on: pageWebView,
            contextID: currentContext.contextID,
            configuration: configuration,
            autoSnapshotEnabled: enabled
        )
    }

    public func reloadPage() async throws {
        let webView = try requirePageWebView()
        await resetInteractionState()
        await beginFreshBootstrap(on: webView, documentURL: normalizedDocumentURL(webView.url?.absoluteString))
        webView.reload()
    }

    public func reloadDocument() async throws {
        let webView = try requirePageWebView()
        await resetInteractionState()
        await beginFreshBootstrap(on: webView, documentURL: normalizedDocumentURL(webView.url?.absoluteString))
    }

    public func cancelSelectionMode() async {
        guard isSelectingElement else {
            return
        }
        invalidateSelectionInteractionTask()
        clearSelectionRequestState()
        await pageBridge.cancelSelectionMode()
    }

    public func beginSelectionMode() async throws -> DOMSelectionResult {
        let webView = try requirePageWebView()
        _ = webView
        let request = SelectionRequest()
        beginSelectionRequest(request)
        return try await performSelectionRequest(request)
    }

    private func performSelectionRequest(_ request: SelectionRequest) async throws -> DOMSelectionResult {
        await pageBridge.hideHighlight()
        applyRecoverableError(nil)
        defer { finishSelectionRequest(request) }

        activatePageWindowForSelectionIfPossible()
#if canImport(UIKit)
        await waitForPageWindowActivationIfNeeded()
#endif

        let selection = try await pageBridge.beginSelectionMode()
        if selection.cancelled {
            return selection
        }
        let context = try requireCurrentContext()
        try await applyPageSelection(selection, contextID: context.contextID)
        return selection
    }

    package func requestSelectionModeToggle() {
        if isSelectingElement {
            invalidateSelectionInteractionTask()
            clearSelectionRequestState()
            Task { @MainActor [weak self] in
                await self?.pageBridge.cancelSelectionMode()
            }
            return
        }
        invalidateSelectionInteractionTask()
        let generation = selectionInteractionGeneration
        let request = SelectionRequest()
        beginSelectionRequest(request)
        selectionInteractionTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.selectionInteractionGeneration == generation {
                    self.selectionInteractionTask = nil
                }
            }
            _ = try? await self?.performSelectionRequest(request)
        }
    }

    package func tearDownForDeinit() {
        bootstrapTask?.cancel()
        bootstrapTask = nil
        selectionInteractionTask?.cancel()
        selectionInteractionTask = nil
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        navigationObservations.removeAll()
        pageWebView = nil
        currentContext = nil
        phase = .idle
        pendingChildRequests.removeAll(keepingCapacity: true)
        document.setErrorMessage(nil)
        inspectorBridge.detachInspectorWebView()
        clearDeleteUndoHistory()
    }

    @_spi(Monocly) public func currentDocumentURLForDiagnostics() -> String? {
        currentContext?.documentURL
    }

    @_spi(Monocly) public func currentContextIDForDiagnostics() -> DOMContextID? {
        currentContext?.contextID
    }

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
        guard let node = document.node(id: nodeID),
              let target = requestTarget(for: node)
        else {
            throw DOMOperationError.invalidSelection
        }
        return try await pageBridge.selectionCopyText(target: target, kind: kind)
    }

    package func copyNode(nodeId: Int, kind: DOMSelectionCopyKind) async throws -> String {
        if let node = document.node(stableBackendNodeID: nodeId),
           let target = requestTarget(for: node) {
            return try await pageBridge.selectionCopyText(target: target, kind: kind)
        }
        return try await pageBridge.selectionCopyText(target: .backend(nodeId), kind: kind)
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
              let node = document.node(id: nodeID),
              let target = requestTarget(for: node)
        else {
            throw DOMOperationError.invalidSelection
        }
        let backendNodeID = stableBackendNodeID(for: node)
        try await deleteNode(
            target: target,
            nodeID: backendNodeID ?? Int(node.localID),
            nodeLocalID: node.localID,
            undoManager: undoManager
        )
    }

    public func deleteNode(nodeId: Int?, undoManager: UndoManager?) async throws {
        guard let nodeId else {
            throw DOMOperationError.invalidSelection
        }
        if let node = document.node(stableBackendNodeID: nodeId) {
            try await deleteNode(nodeID: node.id, undoManager: undoManager)
            return
        }
        try await deleteNode(
            target: .backend(nodeId),
            nodeID: nodeId,
            nodeLocalID: nil,
            undoManager: undoManager
        )
    }

    public func setAttribute(
        nodeID: DOMNodeModel.ID,
        name: String,
        value: String
    ) async throws {
        guard let node = document.node(id: nodeID),
              let target = requestTarget(for: node)
        else {
            throw DOMOperationError.invalidSelection
        }
        let context = try requireCurrentContext()
        let result = await pageBridge.setAttribute(
            target: target,
            name: name,
            value: value,
            expectedContextID: context.contextID
        )
        switch result {
        case .applied:
            _ = document.updateAttribute(
                name: name,
                value: value,
                localID: node.localID,
                backendNodeID: node.backendNodeID
            )
            applyRecoverableError(nil)
        case .contextInvalidated:
            throw DOMOperationError.contextInvalidated
        case let .failed(message):
            throw DOMOperationError.scriptFailure(message)
        }
    }

    public func removeAttribute(
        nodeID: DOMNodeModel.ID,
        name: String
    ) async throws {
        guard let node = document.node(id: nodeID),
              let target = requestTarget(for: node)
        else {
            throw DOMOperationError.invalidSelection
        }
        let context = try requireCurrentContext()
        let result = await pageBridge.removeAttribute(
            target: target,
            name: name,
            expectedContextID: context.contextID
        )
        switch result {
        case .applied:
            _ = document.removeAttribute(
                name: name,
                localID: node.localID,
                backendNodeID: node.backendNodeID
            )
            applyRecoverableError(nil)
        case .contextInvalidated:
            throw DOMOperationError.contextInvalidated
        case let .failed(message):
            throw DOMOperationError.scriptFailure(message)
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

    func beginFreshBootstrap(on webView: WKWebView, documentURL: String?) async {
        cancelBootstrap()
        pendingChildRequests.removeAll(keepingCapacity: true)
        payloadNormalizer.resetForDocumentUpdate()

        let context = DOMContext(
            contextID: nextContextID,
            documentURL: documentURL
        )
        nextContextID &+= 1
        currentContext = context
        self.documentURL = documentURL
        phase = .bootstrapping(context)
        document.clearDocument(isFreshDocument: true)
        applyRecoverableError(nil)

        await pageBridge.installOrUpdateBootstrap(
            on: webView,
            contextID: context.contextID,
            configuration: configuration,
            autoSnapshotEnabled: autoSnapshotEnabled
        )
        updateInspectorBootstrap()
    }

    func cancelBootstrap() {
        bootstrapTask?.cancel()
        bootstrapTask = nil
    }

    func clearContextState() {
        currentContext = nil
        phase = .idle
        documentURL = nil
        pendingChildRequests.removeAll(keepingCapacity: true)
        payloadNormalizer.resetForDocumentUpdate()
        document.clearDocument(isFreshDocument: true)
    }

    func detachCurrentPageIfNeeded() async {
        navigationObservations.removeAll()
        guard pageBridge.attachedWebView != nil else {
            return
        }
        await pageBridge.detach()
    }

    func observeNavigation(on webView: WKWebView) {
        navigationObservations.removeAll()
        let urlObservation = webView.observe(\.url, options: [.new]) { [weak self, weak webView] _, _ in
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView, self.pageWebView === webView else {
                    return
                }
                guard webView.isLoading == false else {
                    return
                }
                await self.handlePossibleNavigation(on: webView)
            }
        }
        let loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self, weak webView] _, _ in
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView, self.pageWebView === webView else {
                    return
                }
                guard webView.isLoading == false else {
                    return
                }
                await self.handlePossibleNavigation(on: webView)
            }
        }
        navigationObservations = [urlObservation, loadingObservation]
    }

    func handlePossibleNavigation(on webView: WKWebView) async {
        let nextURL = normalizedDocumentURL(webView.url?.absoluteString)
        guard nextURL != documentURL else {
            return
        }
        await beginFreshBootstrap(on: webView, documentURL: nextURL)
    }

    func handleInspectorMessage(_ message: DOMInspectorBridge.IncomingMessage) {
        switch message {
        case let .ready(contextID):
            guard phase.matches(contextID) else {
                return
            }
            guard case let .bootstrapping(context) = phase else {
                return
            }
            cancelBootstrap()
            bootstrapTask = Task { @MainActor [weak self] in
                await self?.performBootstrap(for: context)
            }
        case let .requestChildren(nodeID, depth, contextID):
            guard phase.matches(contextID) else {
                return
            }
            Task { @MainActor [weak self] in
                await self?.performChildRequest(nodeID: nodeID, depth: depth, contextID: contextID)
            }
        case let .highlight(nodeID, reveal, contextID):
            guard phase.matches(contextID) else {
                return
            }
            Task { @MainActor [weak self] in
                await self?.pageBridge.highlight(nodeId: nodeID, reveal: reveal)
            }
        case let .hideHighlight(contextID):
            guard phase.matches(contextID) else {
                return
            }
            Task { @MainActor [weak self] in
                await self?.pageBridge.hideHighlight()
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

    func performBootstrap(for context: DOMContext) async {
        guard currentContext?.contextID == context.contextID else {
            return
        }
        do {
        try await refreshCurrentDocumentFromPage(
                contextID: context.contextID,
                isFreshDocument: true
            )
            guard currentContext?.contextID == context.contextID else {
                return
            }
            phase = .ready(context)
        } catch {
            guard currentContext?.contextID == context.contextID else {
                return
            }
            applyRecoverableError(errorMessage(from: error))
        }
    }

    func refreshCurrentDocumentFromPage(
        contextID: DOMContextID,
        isFreshDocument: Bool,
        selectionRestore: DOMSelectionSnapshotPayload? = nil
    ) async throws {
        guard let pageWebView, currentContext?.contextID == contextID else {
            throw DOMOperationError.contextInvalidated
        }
        let rawPayload = try await pageBridge.captureSnapshotEnvelope(
            maxDepth: configuration.snapshotDepth,
            selectionRestorePath: nil,
            selectionRestoreLocalID: selectionRestore?.localID,
            selectionRestoreBackendNodeID: selectionRestore?.backendNodeID
        )
        guard currentContext?.contextID == contextID else {
            throw DOMOperationError.contextInvalidated
        }
        guard let snapshot = payloadNormalizer.normalizeSnapshot(rawPayload) else {
            throw DOMOperationError.scriptFailure("snapshot normalization failed")
        }
        document.replaceDocument(with: snapshot, isFreshDocument: isFreshDocument)
        await inspectorBridge.applyFullSnapshot(rawPayload, contextID: contextID)
        let resolvedURL = normalizedDocumentURL(pageWebView.url?.absoluteString)
        documentURL = resolvedURL
        currentContext = DOMContext(contextID: contextID, documentURL: resolvedURL)
        applyRecoverableError(nil)
    }

    func performChildRequest(nodeID: Int, depth: Int, contextID: DOMContextID) async {
        guard pendingChildRequests.insert(nodeID).inserted else {
            return
        }
        defer { pendingChildRequests.remove(nodeID) }
        do {
            let payload = try await pageBridge.captureSubtreeEnvelope(
                target: .local(UInt64(nodeID)),
                maxDepth: depth
            )
            guard currentContext?.contextID == contextID else {
                return
            }
            if let delta = payloadNormalizer.normalizeBackendResponse(
                method: "DOM.requestChildNodes",
                responseObject: ["result": payload],
                resetDocument: false
            ),
               case let .replaceSubtree(root) = delta {
                document.applyMutationBundle(.init(events: [.replaceSubtree(root: root)]))
            }
            await inspectorBridge.applySubtreePayload(payload, contextID: contextID)
            await inspectorBridge.finishChildNodeRequest(nodeID: nodeID, success: true, contextID: contextID)
        } catch {
            await inspectorBridge.finishChildNodeRequest(nodeID: nodeID, success: false, contextID: contextID)
        }
    }

    func handlePageEvent(_ event: DOMPageEvent) {
        guard currentContext?.contextID == eventContextID(event) else {
            return
        }
        guard case let .ready(context) = phase else {
            return
        }
        let payload = rawPayload(from: event)
        guard let delta = payloadNormalizer.normalizeBundlePayload(payload) else {
            return
        }
        switch delta {
        case let .snapshot(snapshot, resetDocument):
            document.replaceDocument(with: snapshot, isFreshDocument: resetDocument)
            Task { @MainActor [weak self] in
                await self?.inspectorBridge.applyFullSnapshot(payload, contextID: context.contextID)
            }
        case let .mutations(bundle):
            if bundle.events.contains(where: { if case .documentUpdated = $0 { true } else { false } }) {
                Task { @MainActor [weak self] in
                    try? await self?.refreshCurrentDocumentFromPage(
                        contextID: context.contextID,
                        isFreshDocument: false
                    )
                }
                return
            }
            document.applyMutationBundle(bundle)
            Task { @MainActor [weak self] in
                await self?.inspectorBridge.applyMutationBundles(payload, contextID: context.contextID)
            }
        case let .replaceSubtree(root):
            document.applyMutationBundle(.init(events: [.replaceSubtree(root: root)]))
            Task { @MainActor [weak self] in
                await self?.inspectorBridge.applySubtreePayload(payload, contextID: context.contextID)
            }
        case let .selection(selection):
            document.applySelectionSnapshot(selection)
            let payload = selectionPayloadDictionary(from: selection)
            Task { @MainActor [weak self] in
                await self?.inspectorBridge.applySelectionPayload(payload, contextID: context.contextID)
            }
        case let .selectorPath(selectorPath):
            document.applySelectorPath(selectorPath)
        }
    }

    func handleInspectorSelection(_ payload: Any) {
        if case let .selection(selection) = payloadNormalizer.normalizeSelectionPayload(payload) {
            document.applySelectionSnapshot(selection)
        }
    }

    func applyPageSelection(
        _ selection: DOMSelectionResult,
        contextID: DOMContextID
    ) async throws {
        if let selectionRestore = selectionRestorePayload(from: selection) {
            try await refreshCurrentDocumentFromPage(
                contextID: contextID,
                isFreshDocument: false,
                selectionRestore: selectionRestore
            )
            return
        }

        guard let node = await resolveSelectionNode(from: selection, contextID: contextID) else {
            applyRecoverableError("Failed to resolve selected element.")
            return
        }

        let payload = selectionPayload(for: node, selectionResult: selection)
        document.applySelectionSnapshot(payload)
        await inspectorBridge.applySelectionPayload(
            selectionPayloadDictionary(from: payload),
            contextID: contextID
        )
    }

    func eventContextID(_ event: DOMPageEvent) -> DOMContextID {
        switch event {
        case let .snapshot(_, contextID), let .mutations(_, contextID):
            return contextID
        }
    }

    func rawPayload(from event: DOMPageEvent) -> Any {
        switch event {
        case let .snapshot(payload, _), let .mutations(payload, _):
            return payload.rawValue
        }
    }

    func resetInteractionState() async {
        await cancelSelectionMode()
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        clearDeleteUndoHistory()
#if canImport(UIKit)
        restorePageScrollingState()
#endif
    }

    func requestTarget(for node: DOMNodeModel) -> DOMRequestNodeTarget? {
        if let backendNodeID = stableBackendNodeID(for: node) {
            return .backend(backendNodeID)
        }
        return .local(node.localID)
    }

    func stableBackendNodeID(for node: DOMNodeModel) -> Int? {
        guard let backendNodeID = node.backendNodeID,
              node.backendNodeIDIsStable,
              backendNodeID > 0 else {
            return nil
        }
        return backendNodeID
    }

    func deleteNode(
        target: DOMRequestNodeTarget,
        nodeID: Int,
        nodeLocalID: UInt64?,
        undoManager: UndoManager?
    ) async throws {
        let context = try requireCurrentContext()
        if let undoManager {
            rememberDeleteUndoManager(undoManager)
            let restoreSelection = selectionRestorePayload(for: nodeID, nodeLocalID: nodeLocalID)
            let result = await pageBridge.removeNodeWithUndo(
                target: target,
                expectedContextID: context.contextID
            )
            switch result {
            case let .applied(undoToken):
                applyDeletedNode(nodeID: nodeID, nodeLocalID: nodeLocalID)
                registerUndoDelete(
                    .init(
                        undoToken: undoToken,
                        nodeID: nodeID,
                        nodeLocalID: nodeLocalID,
                        contextID: context.contextID,
                        restoreSelection: restoreSelection
                    ),
                    undoManager: undoManager
                )
                applyRecoverableError(nil)
            case .contextInvalidated:
                throw DOMOperationError.contextInvalidated
            case let .failed(message):
                throw DOMOperationError.scriptFailure(message)
            }
            return
        }

        let result = await pageBridge.removeNode(
            target: target,
            expectedContextID: context.contextID
        )
        switch result {
        case .applied:
            applyDeletedNode(nodeID: nodeID, nodeLocalID: nodeLocalID)
            applyRecoverableError(nil)
        case .contextInvalidated:
            throw DOMOperationError.contextInvalidated
        case let .failed(message):
            throw DOMOperationError.scriptFailure(message)
        }
    }

    func applyDeletedNode(nodeID: Int, nodeLocalID: UInt64?) {
        if let nodeLocalID,
           let node = document.node(localID: nodeLocalID) {
            document.removeNode(id: node.id)
            return
        }
        if let node = document.node(backendNodeID: nodeID) {
            document.removeNode(id: node.id)
        }
    }

    func selectionRestorePayload(
        for nodeID: Int,
        nodeLocalID: UInt64?
    ) -> DOMSelectionSnapshotPayload? {
        guard let selectedNode = document.selectedNode else {
            return nil
        }
        if let nodeLocalID {
            guard selectedNode.localID == nodeLocalID else {
                return nil
            }
        } else if selectedNode.backendNodeID != nodeID {
            return nil
        }
        return .init(
            localID: selectedNode.localID,
            backendNodeID: selectedNode.backendNodeID,
            backendNodeIDIsStable: selectedNode.backendNodeIDIsStable,
            preview: selectedNode.preview,
            attributes: selectedNode.attributes,
            path: selectedNode.path,
            selectorPath: selectedNode.selectorPath,
            styleRevision: selectedNode.styleRevision
        )
    }

    func selectionRestorePayload(from selection: DOMSelectionResult) -> DOMSelectionSnapshotPayload? {
        let backendNodeID: Int? = {
            guard selection.selectedBackendNodeIdIsStable != false,
                  let backendNodeID = selection.selectedBackendNodeId,
                  backendNodeID <= UInt64(Int.max) else {
                return nil
            }
            return Int(backendNodeID)
        }()

        guard selection.selectedLocalId != nil || backendNodeID != nil else {
            return nil
        }

        return .init(
            localID: selection.selectedLocalId,
            backendNodeID: backendNodeID,
            backendNodeIDIsStable: backendNodeID != nil,
            preview: "",
            attributes: [],
            path: [],
            selectorPath: nil,
            styleRevision: 0
        )
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
        let result = await pageBridge.undoRemoveNode(
            undoToken: state.undoToken,
            expectedContextID: state.contextID
        )
        switch result {
        case .applied:
            try await refreshCurrentDocumentFromPage(
                contextID: state.contextID,
                isFreshDocument: false,
                selectionRestore: state.restoreSelection
            )
            registerRedoDelete(state, undoManager: undoManager)
            applyRecoverableError(nil)
        case .contextInvalidated:
            clearDeleteUndoHistory(using: undoManager)
            throw DOMOperationError.contextInvalidated
        case let .failed(message):
            clearDeleteUndoHistory(using: undoManager)
            throw DOMOperationError.scriptFailure(message)
        }
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
        let result = await pageBridge.redoRemoveNode(
            undoToken: state.undoToken,
            expectedContextID: state.contextID
        )
        switch result {
        case .applied:
            try await refreshCurrentDocumentFromPage(
                contextID: state.contextID,
                isFreshDocument: false
            )
            registerUndoDelete(state, undoManager: undoManager)
            applyRecoverableError(nil)
        case .contextInvalidated:
            clearDeleteUndoHistory(using: undoManager)
            throw DOMOperationError.contextInvalidated
        case let .failed(message):
            clearDeleteUndoHistory(using: undoManager)
            throw DOMOperationError.scriptFailure(message)
        }
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

    func beginSelectionRequest(_ request: SelectionRequest) {
        activeSelectionRequest = request
#if canImport(UIKit)
        disablePageScrollingForSelection()
#endif
        isSelectingElement = true
    }

    func clearSelectionRequestState() {
        activeSelectionRequest = nil
        isSelectingElement = false
#if canImport(UIKit)
        restorePageScrollingState()
#endif
    }

    func finishSelectionRequest(_ request: SelectionRequest) {
        guard activeSelectionRequest === request else {
            return
        }
        clearSelectionRequestState()
    }

    func invalidateSelectionInteractionTask() {
        selectionInteractionGeneration &+= 1
        selectionInteractionTask?.cancel()
        selectionInteractionTask = nil
    }

    func resolveSelectionNode(
        from selection: DOMSelectionResult,
        contextID: DOMContextID
    ) async -> DOMNodeModel? {
        if let selectedLocalId = selection.selectedLocalId,
           let node = document.node(localID: selectedLocalId) {
            return node
        }

        if selection.selectedBackendNodeIdIsStable != false,
           let backendNodeID = selection.selectedBackendNodeId,
           backendNodeID <= UInt64(Int.max),
           let node = document.node(stableBackendNodeID: Int(backendNodeID)) {
            return node
        }

        let fallbackDepth = max(configuration.subtreeDepth, selection.requiredDepth)
        let targets = materializationTargets(for: selection)
        for target in targets {
            guard currentContext?.contextID == contextID else {
                return nil
            }
            guard let payload = try? await pageBridge.captureSubtreeEnvelope(target: target, maxDepth: fallbackDepth) else {
                continue
            }
            if let delta = payloadNormalizer.normalizeBackendResponse(
                method: "DOM.requestChildNodes",
                responseObject: ["result": payload],
                resetDocument: false
            ),
               case let .replaceSubtree(root) = delta {
                document.applyMutationBundle(.init(events: [.replaceSubtree(root: root)]))
            }
            if let selectedLocalId = selection.selectedLocalId,
               let node = document.node(localID: selectedLocalId) {
                return node
            }
            if selection.selectedBackendNodeIdIsStable != false,
               let backendNodeID = selection.selectedBackendNodeId,
               backendNodeID <= UInt64(Int.max),
               let node = document.node(stableBackendNodeID: Int(backendNodeID)) {
                return node
            }
        }

        if let placeholder = applySelectionPlaceholder(from: selection) {
            return placeholder
        }
        if let path = selection.selectedPath,
           let node = node(at: path, from: document.rootNode) {
            return node
        }
        return document.rootNode
    }

    func materializationTargets(for selection: DOMSelectionResult) -> [DOMRequestNodeTarget] {
        var targets: [DOMRequestNodeTarget] = []
        if let selectedLocalId = selection.selectedLocalId {
            targets.append(.local(selectedLocalId))
        }
        if selection.selectedBackendNodeIdIsStable != false,
           let backendNodeID = selection.selectedBackendNodeId,
           backendNodeID <= UInt64(Int.max) {
            targets.append(.backend(Int(backendNodeID)))
        }
        for localID in selection.ancestorLocalIds ?? [] {
            targets.append(.local(localID))
        }
        for backendNodeID in selection.ancestorBackendNodeIds ?? [] where backendNodeID <= UInt64(Int.max) {
            targets.append(.backend(Int(backendNodeID)))
        }
        if let rootLocalID = document.rootNode?.localID {
            targets.append(.local(rootLocalID))
        }
        var seen: Set<DOMRequestNodeTarget> = []
        return targets.filter { seen.insert($0).inserted }
    }

    func applySelectionPlaceholder(from selection: DOMSelectionResult) -> DOMNodeModel? {
        guard let localID = selection.selectedLocalId else {
            return nil
        }
        let backendNodeID: Int? = {
            guard selection.selectedBackendNodeIdIsStable != false,
                  let backendNodeID = selection.selectedBackendNodeId,
                  backendNodeID <= UInt64(Int.max)
            else {
                return nil
            }
            return Int(backendNodeID)
        }()
        let attributes = (selection.selectedAttributes ?? []).map {
            DOMAttribute(nodeId: backendNodeID, name: $0.name, value: $0.value)
        }
        document.applySelectionSnapshot(
            .init(
                localID: localID,
                backendNodeID: backendNodeID,
                preview: selection.selectedPreview ?? "",
                attributes: attributes,
                path: selectionPathLabels(for: selection.selectedPath),
                selectorPath: selection.selectedSelectorPath,
                styleRevision: 0
            )
        )
        return document.selectedNode
    }

    func selectionPayload(
        for node: DOMNodeModel,
        selectionResult: DOMSelectionResult
    ) -> DOMSelectionSnapshotPayload {
        let attributes = (selectionResult.selectedAttributes ?? []).map {
            DOMAttribute(nodeId: node.backendNodeID, name: $0.name, value: $0.value)
        }
        return .init(
            localID: node.localID,
            backendNodeID: node.backendNodeID,
            backendNodeIDIsStable: node.backendNodeIDIsStable,
            preview: selectionResult.selectedPreview ?? node.preview,
            attributes: attributes.isEmpty ? node.attributes : attributes,
            path: selectionPathLabels(for: selectionResult.selectedPath, fallbackNode: node),
            selectorPath: selectionResult.selectedSelectorPath ?? (node.selectorPath.isEmpty ? nil : node.selectorPath),
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

    func selectionPathLabels(for path: [Int]?, fallbackNode: DOMNodeModel? = nil) -> [String] {
        if let path, let node = node(at: path, from: document.rootNode) {
            return selectionPathLabels(for: node)
        }
        if let fallbackNode {
            return selectionPathLabels(for: fallbackNode)
        }
        return []
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
        guard let selectedNode = document.selectedNode,
              let target = requestTarget(for: selectedNode) else {
            throw DOMOperationError.invalidSelection
        }
        return try await pageBridge.selectionCopyText(target: target, kind: kind)
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

#if DEBUG
extension WIDOMInspector {
    package var testCurrentContextID: DOMContextID? {
        currentContext?.contextID
    }

    package func testWaitForBootstrap() async {
        await bootstrapTask?.value
    }
}
#endif
