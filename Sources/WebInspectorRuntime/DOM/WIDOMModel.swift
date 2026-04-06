import OSLog
import Observation
import WebKit
import WebInspectorEngine

#if canImport(UIKit)
import UIKit
#endif

private let domViewLogger = Logger(subsystem: "WebInspectorKit", category: "WIDOMInspector")
private let domDeleteUndoHistoryLimit = 128

@available(*, deprecated, renamed: "WIDOMInspector", message: "Use WIDOMInspector.")
public typealias WIDOMModel = WIDOMInspector

public typealias DOMSelectionResult = DOMPageAgent.SelectionModeResult

public enum DOMMutationResult: Sendable, Equatable {
    case applied
    case ignoredStaleContext
    case failed
}

@MainActor
@Observable
public final class WIDOMInspector {
    private final class SelectionRequest {}

    private enum DocumentReloadMode {
        case fresh
        case preservingInspectorState

        var runtimeMode: DOMDocumentReloadMode {
            switch self {
            case .fresh:
                .fresh
            case .preservingInspectorState:
                .preserveUIState
            }
        }

        var preservesDocumentScope: Bool {
            switch self {
            case .fresh:
                false
            case .preservingInspectorState:
                true
            }
        }
    }

    package let session: DOMSession
    package let transport: DOMInspectorRuntime
    public let document: DOMDocumentModel

    @available(*, deprecated, renamed: "document", message: "Use document.")
    public var documentStore: DOMDocumentModel {
        document
    }

    public private(set) var isSelectingElement = false

    @ObservationIgnored private var externalRecoverableErrorHandler: (@MainActor (String?) -> Void)?
    @ObservationIgnored private var activeSelectionRequest: SelectionRequest?
    @ObservationIgnored private var selectionInteractionTask: Task<Void, Never>?
    @ObservationIgnored private var selectionInteractionGeneration: UInt64 = 0
    @ObservationIgnored private var pendingDeleteTask: Task<Void, Never>?
    @ObservationIgnored private weak var deleteUndoManager: UndoManager?
#if canImport(UIKit)
    @ObservationIgnored private var scrollBackup: (isScrollEnabled: Bool, isPanEnabled: Bool)?
#endif

    package init(
        session: DOMSession,
        onRecoverableError: (@MainActor (String?) -> Void)? = nil
    ) {
        self.session = session
        self.document = DOMDocumentModel()
        self.transport = DOMInspectorRuntime(session: session, documentModel: self.document)
        self.externalRecoverableErrorHandler = onRecoverableError
        self.transport.onRecoverableError = { [weak self] message in
            self?.applyRecoverableError(message)
        }
    }

    isolated deinit {
        pendingDeleteTask?.cancel()
        clearDeleteUndoHistory()
#if canImport(UIKit)
        restorePageScrollingState()
#endif
    }

    public var hasPageWebView: Bool {
        session.hasPageWebView
    }

    package func setRecoverableErrorHandler(_ handler: (@MainActor (String?) -> Void)?) {
        externalRecoverableErrorHandler = handler
    }

    package func makeInspectorWebView() -> WKWebView {
        transport.makeInspectorWebView()
    }

    package func enqueueMutationBundle(_ bundle: Any, preservingInspectorState: Bool) {
        transport.enqueueMutationBundle(bundle, preservingInspectorState: preservingInspectorState)
    }

    package var pendingMutationBundleCount: Int {
        transport.pendingMutationBundleCount
    }

    public func reloadPage() async -> DOMMutationResult {
        guard session.pageWebView != nil else {
            return .failed
        }
        let expectedPageEpoch = transport.currentPageEpoch
        guard matchesCurrentPageEpoch(expectedPageEpoch) else {
            return .ignoredStaleContext
        }
        await resetInteractionState()
        guard matchesCurrentPageEpoch(expectedPageEpoch) else {
            return .ignoredStaleContext
        }
        await transport.performPageTransition { nextPageEpoch in
            self.session.preparePageEpoch(nextPageEpoch)
            self.session.prepareDocumentScopeID(self.transport.currentDocumentScopeID)
            await self.session.reloadPageAndWaitForPreparedPageEpochSync()
        }
        return .applied
    }

    package func attach(to webView: WKWebView) async {
        await resetInteractionState()
        let needsPageEpochAdvance = session.lastPageWebView != nil && session.pageWebView !== webView
        let outcome: DOMSession.AttachmentResult
        if needsPageEpochAdvance {
            outcome = await transport.performPageTransition { nextPageEpoch in
                self.session.preparePageEpoch(nextPageEpoch)
                self.session.prepareDocumentScopeID(self.transport.currentDocumentScopeID)
                await self.session.suspend()
                self.session.preparePageEpoch(nextPageEpoch)
                self.session.prepareDocumentScopeID(self.transport.currentDocumentScopeID)
                return await self.session.attach(to: webView)
            }
        } else {
            outcome = await session.attach(to: webView)
        }
        let didAdoptPageContext = if let observedPageContext = outcome.observedPageContext {
            await transport.adoptPageContextIfNeeded(
                observedPageContext,
                preserveCurrentDocumentState: outcome.shouldPreserveInspectorState || outcome.shouldReload == false
            )
        } else {
            false
        }
        if outcome.shouldReload {
            let reloadResult = await reloadDocumentImpl(
                outcome.shouldPreserveInspectorState ? .preservingInspectorState : .fresh
            )
            if didAdoptPageContext, reloadResult != .applied {
                let resyncResult = await resyncDocumentAfterContextAdoptionFailure()
                if resyncResult != .applied {
                    transport.retryDocumentReplacementAfterContextAdoption(
                        depth: session.configuration.snapshotDepth,
                        mode: outcome.shouldPreserveInspectorState ? .preserveUIState : .fresh
                    )
                }
            }
        } else if didAdoptPageContext {
            let reloadResult = await reloadDocumentImpl(
                .preservingInspectorState,
                expectedPageEpoch: transport.currentPageEpoch
            )
            if reloadResult != .applied {
                let resyncResult = await resyncDocumentAfterContextAdoptionFailure()
                if resyncResult != .applied {
                    transport.retryDocumentReplacementAfterContextAdoption(
                        depth: session.configuration.snapshotDepth,
                        mode: .preserveUIState
                    )
                }
            }
        }
    }

    package func suspend() async {
        await resetInteractionState()
        if session.hasPageWebView {
            await transport.performPageTransition(resumeBootstrap: false) { _ in
                await self.session.suspend()
            }
        } else {
            await session.suspend()
        }
    }

    package func detach() async {
        await resetInteractionState()
        if session.hasPageWebView {
            await transport.performPageTransition(resumeBootstrap: false) { _ in
                await self.session.detach()
            }
        } else {
            await session.detach()
            transport.resetDocumentStoreForDetachment()
        }
        transport.detachInspectorWebView()
        document.setErrorMessage(nil)
    }

    package func setAutoSnapshotEnabled(_ enabled: Bool) async {
        guard session.hasPageWebView else {
            return
        }
        await session.setAutoSnapshot(enabled: enabled)
    }

    public func reloadDocument() async -> DOMMutationResult {
        await reloadDocumentImpl(.fresh)
    }

    public func reloadDocumentPreservingInspectorState() async -> DOMMutationResult {
        await reloadDocumentImpl(.preservingInspectorState)
    }

    public func updateSnapshotDepth(_ depth: Int) async {
        await updateSnapshotDepthImpl(depth)
    }

    public func cancelSelectionMode() async {
        await cancelSelectionModeImpl()
    }

    public func beginSelectionMode() async throws -> DOMSelectionResult {
        try await beginSelectionModeImpl()
    }

    package func requestSelectionModeToggle() {
        if isSelectingElement {
            cancelSelectionInteraction()
        } else {
            startSelectionInteractionIfPossible()
        }
    }

    package func copyNode(nodeID: DOMNodeModel.ID, kind: DOMSelectionCopyKind) async throws -> String {
        guard let node = document.node(id: nodeID),
              let target = nodeRequestTarget(for: node) else {
            return ""
        }
        return try await session.selectionCopyText(target: target, kind: kind)
    }

    package func copyNode(nodeId: Int, kind: DOMSelectionCopyKind) async throws -> String {
        guard let target = requestTarget(forRequestIdentifier: nodeId) else {
            return ""
        }
        return try await session.selectionCopyText(target: target, kind: kind)
    }

    package func tearDownForDeinit() {
        invalidateSelectionInteractionTask()
        activeSelectionRequest = nil
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        transport.detachInspectorWebView()
        session.tearDownForDeinit()
        document.setErrorMessage(nil)
        isSelectingElement = false
        clearDeleteUndoHistory()
#if canImport(UIKit)
        restorePageScrollingState()
#endif
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

    public func deleteSelection() async -> DOMMutationResult {
        await deleteSelection(undoManager: nil)
    }

    public func deleteSelection(undoManager: UndoManager?) async -> DOMMutationResult {
        await deleteNodeImpl(
            nodeID: document.selectedNode?.id,
            undoManager: undoManager,
            expectedContext: transport.currentMutationContext
        )
    }

    public func deleteNode(nodeID: DOMNodeModel.ID?, undoManager: UndoManager?) async -> DOMMutationResult {
        return await deleteNodeImpl(
            nodeID: nodeID,
            undoManager: undoManager,
            expectedContext: transport.currentMutationContext
        )
    }

    public func deleteNode(nodeId: Int?, undoManager: UndoManager?) async -> DOMMutationResult {
        if let resolvedNodeID = nodeId.flatMap({ documentNode(forRequestIdentifier: $0)?.id }) {
            return await deleteNodeImpl(
                nodeID: resolvedNodeID,
                undoManager: undoManager,
                expectedContext: transport.currentMutationContext
            )
        }
        guard let requestTarget = nodeId.flatMap(requestTarget(forRequestIdentifier:)) else {
            return .failed
        }
        return publicMutationResult(
            await session.removeNode(
                target: requestTarget,
                expectedPageEpoch: transport.currentPageEpoch,
                expectedDocumentScopeID: transport.currentDocumentScopeID
            )
        )
    }

    public func setAttribute(
        nodeID: DOMNodeModel.ID,
        name: String,
        value: String
    ) async -> DOMMutationResult {
        await updateAttributeValueImpl(
            nodeID: nodeID,
            name: name,
            value: value,
            expectedContext: transport.currentMutationContext
        )
    }

    public func removeAttribute(
        nodeID: DOMNodeModel.ID,
        name: String
    ) async -> DOMMutationResult {
        await removeAttributeImpl(
            nodeID: nodeID,
            name: name,
            expectedContext: transport.currentMutationContext
        )
    }

    public func updateSelectedAttribute(name: String, value: String) async -> DOMMutationResult {
        guard let nodeID = document.selectedNode?.id else {
            return .failed
        }
        return await setAttribute(nodeID: nodeID, name: name, value: value)
    }

    public func removeSelectedAttribute(name: String) async -> DOMMutationResult {
        guard let nodeID = document.selectedNode?.id else {
            return .failed
        }
        return await removeAttribute(nodeID: nodeID, name: name)
    }
}

private extension WIDOMInspector {
    private func finalizeReloadResult(_ result: DOMMutationResult) -> DOMMutationResult {
        if result != .applied {
            transport.setPendingSelectionOverride(localID: nil)
        }
        return result
    }

    private func reloadDocumentImpl(
        _ mode: DocumentReloadMode,
        expectedPageEpoch: Int? = nil,
        pinDocumentScope: Bool = true
    ) async -> DOMMutationResult {
        guard session.hasPageWebView else {
            applyRecoverableError("Web view unavailable.")
            return finalizeReloadResult(.failed)
        }

        let depth = session.configuration.snapshotDepth
        let resolvedPageEpoch = expectedPageEpoch ?? transport.currentPageEpoch
        let resolvedDocumentScopeID = pinDocumentScope ? transport.currentDocumentScopeID : nil
        if mode == .fresh {
            transport.setPendingSelectionOverride(localID: nil)
        }
        guard matchesCurrentPageEpoch(resolvedPageEpoch) else {
            return finalizeReloadResult(.ignoredStaleContext)
        }
        if let resolvedDocumentScopeID,
           transport.currentDocumentScopeID != resolvedDocumentScopeID
        {
            return finalizeReloadResult(.ignoredStaleContext)
        }
        if document.errorMessage != nil {
            applyRecoverableError(nil)
        }
        await transport.updateConfiguration(session.configuration, expectedPageEpoch: resolvedPageEpoch)
        guard matchesCurrentPageEpoch(resolvedPageEpoch) else {
            return finalizeReloadResult(.ignoredStaleContext)
        }
        if let resolvedDocumentScopeID,
           transport.currentDocumentScopeID != resolvedDocumentScopeID
        {
            return finalizeReloadResult(.ignoredStaleContext)
        }
        await transport.setPreferredDepth(depth, expectedPageEpoch: resolvedPageEpoch)
        guard matchesCurrentPageEpoch(resolvedPageEpoch) else {
            return finalizeReloadResult(.ignoredStaleContext)
        }
        if let resolvedDocumentScopeID,
           transport.currentDocumentScopeID != resolvedDocumentScopeID
        {
            return finalizeReloadResult(.ignoredStaleContext)
        }
        let didRequestDocument = await transport.requestDocument(
            depth: depth,
            mode: mode.runtimeMode,
            expectedPageEpoch: resolvedPageEpoch,
            expectedDocumentScopeID: resolvedDocumentScopeID
        )
        guard matchesCurrentPageEpoch(resolvedPageEpoch) else {
            return finalizeReloadResult(.ignoredStaleContext)
        }
        if mode.preservesDocumentScope,
           let resolvedDocumentScopeID,
           transport.currentDocumentScopeID != resolvedDocumentScopeID
        {
            return finalizeReloadResult(.ignoredStaleContext)
        }
        if didRequestDocument {
            return finalizeReloadResult(.applied)
        }
        if let resolvedDocumentScopeID,
           transport.currentDocumentScopeID != resolvedDocumentScopeID
        {
            return finalizeReloadResult(.ignoredStaleContext)
        }
        return finalizeReloadResult(.failed)
    }

    private func resyncDocumentAfterContextLoss() async -> DOMMutationResult {
        guard session.hasPageWebView else {
            return .failed
        }
        do {
            let payload = try await session.captureSnapshotPayload(
                maxDepth: session.configuration.snapshotDepth,
                initialModeOwnership: .consumePendingInitialMode
            )
            transport.handleDOMBundle(
                .init(
                    objectEnvelope: [
                        "version": 1,
                        "kind": "snapshot",
                        "reason": "documentUpdated",
                        "snapshotMode": "preserve-ui-state",
                        "snapshot": payload,
                    ],
                    pageEpoch: transport.currentPageEpoch,
                    documentScopeID: transport.currentDocumentScopeID
                )
            )
            applyRecoverableError(nil)
            return .applied
        } catch {
            applyRecoverableError(error.localizedDescription)
            return .failed
        }
    }

    private func resyncDocumentAfterContextAdoptionFailure() async -> DOMMutationResult {
        guard session.hasPageWebView else {
            return .failed
        }
        do {
            let payload = try await session.captureSnapshotPayload(
                maxDepth: session.configuration.snapshotDepth,
                initialModeOwnership: .consumePendingInitialMode
            )
            let didApplyReplacement = await transport.applyReplacementDOMBundleAfterContextAdoption(
                .init(
                    objectEnvelope: [
                        "version": 1,
                        "kind": "snapshot",
                        "reason": "documentUpdated",
                        "snapshotMode": "fresh",
                        "snapshot": payload,
                    ],
                    pageEpoch: transport.currentPageEpoch,
                    documentScopeID: transport.currentDocumentScopeID
                )
            )
            guard didApplyReplacement else {
                return .failed
            }
            applyRecoverableError(nil)
            return .applied
        } catch {
            applyRecoverableError(error.localizedDescription)
            return .failed
        }
    }

    func updateSnapshotDepthImpl(_ depth: Int) async {
        let clamped = max(1, depth)
        var configuration = session.configuration
        configuration.snapshotDepth = clamped
        await session.updateConfiguration(configuration)
        await transport.updateConfiguration(configuration)
        await transport.setPreferredDepth(clamped)
    }

    func cancelSelectionModeImpl() async {
        guard isSelectingElement else {
            return
        }
        invalidateSelectionInteractionTask()
        clearSelectionRequestState()
        await session.cancelSelectionMode()
    }

    func copySelectionImpl(_ kind: DOMSelectionCopyKind) async throws -> String {
        guard let selectedNode = document.selectedNode,
              let target = nodeRequestTarget(for: selectedNode) else {
            return ""
        }
        return try await session.selectionCopyText(target: target, kind: kind)
    }

    private func deleteNodeImpl(
        target: DOMRequestNodeTarget?,
        nodeLocalID: UInt64? = nil,
        undoManager: UndoManager?,
        expectedContext: DOMInspectorRuntime.MutationContext
    ) async -> DOMMutationResult {
        guard let target, let nodeId = target.jsIdentifier else {
            return .failed
        }
        guard transport.matchesCurrentMutationContext(expectedContext) else {
            return .ignoredStaleContext
        }
        return await enqueueDelete(
            target: target,
            nodeId: nodeId,
            nodeLocalID: nodeLocalID,
            undoManager: undoManager,
            expectedContext: expectedContext
        )
    }

    private func deleteNodeImpl(
        nodeID: DOMNodeModel.ID?,
        undoManager: UndoManager?,
        expectedContext: DOMInspectorRuntime.MutationContext
    ) async -> DOMMutationResult {
        guard let nodeID else {
            return .failed
        }
        guard transport.matchesCurrentMutationContext(expectedContext) else {
            return .ignoredStaleContext
        }
        guard let node = document.node(id: nodeID) else {
            return .ignoredStaleContext
        }
        return await deleteNodeImpl(
            target: nodeRequestTarget(for: node),
            nodeLocalID: node.localID,
            undoManager: undoManager,
            expectedContext: expectedContext
        )
    }

    private func updateAttributeValueImpl(
        nodeID: DOMNodeModel.ID,
        name: String,
        value: String,
        expectedContext: DOMInspectorRuntime.MutationContext
    ) async -> DOMMutationResult {
        guard transport.matchesCurrentMutationContext(expectedContext) else {
            return .ignoredStaleContext
        }
        guard let node = document.node(id: nodeID) else {
            return .ignoredStaleContext
        }
        guard let requestTarget = nodeRequestTarget(for: node) else {
            return .failed
        }

        let didSyncMutationContext = await transport.syncMutationContextToPageIfNeeded(expectedContext)
        guard didSyncMutationContext || session.hasPageWebView == false else {
            return .ignoredStaleContext
        }
        guard transport.matchesCurrentMutationContext(expectedContext) else {
            return .ignoredStaleContext
        }

        let didUpdateAttribute = await session.setAttribute(
            target: requestTarget,
            name: name,
            value: value,
            expectedPageEpoch: expectedContext.pageEpoch,
            expectedDocumentScopeID: expectedContext.documentScopeID
        )
        switch didUpdateAttribute {
        case .applied:
            if transport.matchesCurrentMutationContext(expectedContext) {
                _ = document.updateAttribute(
                    name: name,
                    value: value,
                    localID: node.localID,
                    backendNodeID: node.backendNodeID
                )
            } else if session.hasPageWebView {
                let reloadResult = await reloadDocumentPreservingInspectorState()
                if reloadResult == .ignoredStaleContext {
                    _ = await resyncDocumentAfterContextLoss()
                }
            }
            return .applied
        case .ignoredStaleContext:
            return .ignoredStaleContext
        case .failed:
            return .failed
        }
    }

    private func removeAttributeImpl(
        nodeID: DOMNodeModel.ID,
        name: String,
        expectedContext: DOMInspectorRuntime.MutationContext
    ) async -> DOMMutationResult {
        guard transport.matchesCurrentMutationContext(expectedContext) else {
            return .ignoredStaleContext
        }
        guard let node = document.node(id: nodeID) else {
            return .ignoredStaleContext
        }
        guard let requestTarget = nodeRequestTarget(for: node) else {
            return .failed
        }

        let didSyncMutationContext = await transport.syncMutationContextToPageIfNeeded(expectedContext)
        guard didSyncMutationContext || session.hasPageWebView == false else {
            return .ignoredStaleContext
        }
        guard transport.matchesCurrentMutationContext(expectedContext) else {
            return .ignoredStaleContext
        }

        let didRemoveAttribute = await session.removeAttribute(
            target: requestTarget,
            name: name,
            expectedPageEpoch: expectedContext.pageEpoch,
            expectedDocumentScopeID: expectedContext.documentScopeID
        )
        switch didRemoveAttribute {
        case .applied:
            if transport.matchesCurrentMutationContext(expectedContext) {
                _ = document.removeAttribute(
                    name: name,
                    localID: node.localID,
                    backendNodeID: node.backendNodeID
                )
            } else if session.hasPageWebView {
                let reloadResult = await reloadDocumentPreservingInspectorState()
                if reloadResult == .ignoredStaleContext {
                    _ = await resyncDocumentAfterContextLoss()
                }
            }
            return .applied
        case .ignoredStaleContext:
            return .ignoredStaleContext
        case .failed:
            return .failed
        }
    }

    func beginSelectionModeImpl() async throws -> DOMSelectionResult {
        guard session.hasPageWebView else {
            throw WebInspectorCoreError.scriptUnavailable
        }
        if isSelectingElement {
            await cancelSelectionModeImpl()
        }
        return try await beginSelectionRequestAndPerform()
    }

    func resetInteractionState() async {
        await cancelSelectionModeImpl()
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        clearDeleteUndoHistory()
#if canImport(UIKit)
        restorePageScrollingState()
#endif
    }

    private func enqueueDelete(
        target: DOMRequestNodeTarget,
        nodeId: Int,
        nodeLocalID: UInt64? = nil,
        undoManager: UndoManager?,
        expectedContext: DOMInspectorRuntime.MutationContext
    ) async -> DOMMutationResult {
        let previousTask = pendingDeleteTask
        var mutationResult: DOMMutationResult = .failed
        let task = Task { [weak self] in
            guard let self else {
                return
            }
            if let previousTask {
                await previousTask.value
            }
            guard !Task.isCancelled else {
                return
            }
            guard self.transport.matchesCurrentMutationContext(expectedContext) else {
                mutationResult = .ignoredStaleContext
                return
            }
            let didSyncMutationContext = await self.transport.syncMutationContextToPageIfNeeded(expectedContext)
            guard didSyncMutationContext || self.session.hasPageWebView == false else {
                mutationResult = .ignoredStaleContext
                return
            }
            guard self.transport.matchesCurrentMutationContext(expectedContext) else {
                mutationResult = .ignoredStaleContext
                return
            }

            guard let undoManager else {
                mutationResult = self.publicMutationResult(
                    await self.session.removeNode(
                        target: target,
                        expectedPageEpoch: expectedContext.pageEpoch,
                        expectedDocumentScopeID: expectedContext.documentScopeID
                    )
                )
                if mutationResult == .applied {
                    await self.applyDeletedNodeMutationResult(
                        nodeId: nodeId,
                        nodeLocalID: nodeLocalID,
                        expectedContext: expectedContext
                    )
                }
                return
            }

            self.rememberDeleteUndoManager(undoManager)
            let restoreSelectionPayload = self.selectionRestorePayload(
                for: nodeId,
                nodeLocalID: nodeLocalID
            )
            let removeWithUndoResult = await self.session.removeNodeWithUndo(
                nodeId: nodeId,
                expectedPageEpoch: expectedContext.pageEpoch,
                expectedDocumentScopeID: expectedContext.documentScopeID
            )
            switch removeWithUndoResult {
            case let .applied(undoToken):
                let matchesCurrentContext = self.transport.matchesCurrentMutationContext(expectedContext)
                if !matchesCurrentContext {
                    self.clearDeleteUndoHistory(using: undoManager)
                }
                await self.applyDeletedNodeMutationResult(
                    nodeId: nodeId,
                    nodeLocalID: nodeLocalID,
                    expectedContext: expectedContext
                )
                if matchesCurrentContext {
                    self.registerUndoDelete(
                        undoToken: undoToken,
                        nodeId: nodeId,
                        context: expectedContext,
                        undoManager: undoManager,
                        restoreSelectionPayload: restoreSelectionPayload
                    )
                    mutationResult = .applied
                } else {
                    mutationResult = .ignoredStaleContext
                }
            case .ignoredStaleContext:
                self.clearDeleteUndoHistory(using: undoManager)
                mutationResult = .ignoredStaleContext
            case .failed:
                mutationResult = self.publicMutationResult(
                    await self.session.removeNode(
                        target: target,
                        expectedPageEpoch: expectedContext.pageEpoch,
                        expectedDocumentScopeID: expectedContext.documentScopeID
                    )
                )
                if mutationResult == .applied {
                    await self.applyDeletedNodeMutationResult(
                        nodeId: nodeId,
                        nodeLocalID: nodeLocalID,
                        expectedContext: expectedContext
                    )
                } else {
                    self.clearDeleteUndoHistory(using: undoManager)
                }
            }
        }
        pendingDeleteTask = task
        await task.value
        return mutationResult
    }

    func matchesCurrentPageEpoch(_ expectedPageEpoch: Int?) -> Bool {
        guard let expectedPageEpoch else {
            return true
        }
        return transport.currentPageEpoch == expectedPageEpoch
    }

    private func publicMutationResult<Payload>(_ result: DOMMutationExecutionResult<Payload>) -> DOMMutationResult {
        switch result {
        case .applied:
            return .applied
        case .ignoredStaleContext:
            return .ignoredStaleContext
        case .failed:
            return .failed
        }
    }

    private func nodeRequestTarget(for node: DOMNodeModel) -> DOMRequestNodeTarget? {
        if liveDocumentContains(node) {
            return .local(node.localID)
        }
        if let backendNodeID = preferredBackendNodeID(forDetachedRequestTarget: node) {
            return .backend(backendNodeID)
        }
        return .local(node.localID)
    }

    private func requestTarget(forRequestIdentifier nodeId: Int) -> DOMRequestNodeTarget? {
        guard let node = documentNode(forRequestIdentifier: nodeId) else {
            return nil
        }
        return nodeRequestTarget(for: node)
    }

    private func documentNode(forRequestIdentifier nodeId: Int) -> DOMNodeModel? {
        if nodeId >= 0, let node = document.node(localID: UInt64(nodeId)) {
            return node
        }
        return document.node(backendNodeID: nodeId)
    }

    private func preferredBackendNodeID(forDetachedRequestTarget node: DOMNodeModel) -> Int? {
        guard let backendNodeID = node.backendNodeID,
              backendNodeID > 0
        else {
            return nil
        }
        return backendNodeID
    }

    private func liveDocumentContains(_ node: DOMNodeModel) -> Bool {
        if document.rootNode === node {
            return true
        }
        var current = node.parent
        while let currentNode = current {
            if document.rootNode === currentNode {
                return true
            }
            current = currentNode.parent
        }
        return false
    }

    private func registerUndoDelete(
        undoToken: Int,
        nodeId: Int,
        context: DOMInspectorRuntime.MutationContext,
        undoManager: UndoManager,
        restoreSelectionPayload: DOMSelectionSnapshotPayload?
    ) {
        rememberDeleteUndoManager(undoManager)
        undoManager.registerUndo(withTarget: self) { target in
            target.performUndoDelete(
                undoToken: undoToken,
                nodeId: nodeId,
                context: context,
                undoManager: undoManager,
                restoreSelectionPayload: restoreSelectionPayload
            )
        }
        undoManager.setActionName("Delete Node")
    }

    private func performUndoDelete(
        undoToken: Int,
        nodeId: Int,
        context: DOMInspectorRuntime.MutationContext,
        undoManager: UndoManager,
        restoreSelectionPayload: DOMSelectionSnapshotPayload?
    ) {
        guard transport.matchesCurrentMutationContext(context) else {
            clearDeleteUndoHistory(using: undoManager)
            return
        }
        registerRedoDelete(
            undoToken: undoToken,
            nodeId: nodeId,
            context: context,
            undoManager: undoManager,
            restoreSelectionPayload: restoreSelectionPayload
        )
        Task.immediateIfAvailable { [weak self] in
            guard let self else {
                return
            }
            guard self.transport.matchesCurrentMutationContext(context) else {
                self.clearDeleteUndoHistory(using: undoManager)
                return
            }
            let didSyncMutationContext = await self.transport.syncMutationContextToPageIfNeeded(context)
            guard didSyncMutationContext || self.session.hasPageWebView == false else {
                self.clearDeleteUndoHistory(using: undoManager)
                return
            }
            guard self.transport.matchesCurrentMutationContext(context) else {
                self.clearDeleteUndoHistory(using: undoManager)
                return
            }
            let restored = await self.session.undoRemoveNode(
                undoToken: undoToken,
                expectedPageEpoch: context.pageEpoch,
                expectedDocumentScopeID: context.documentScopeID
            )
            guard case .applied = restored else {
                self.clearDeleteUndoHistory(using: undoManager)
                return
            }
            let matchesCurrentContext = self.transport.matchesCurrentMutationContext(context)
            if !matchesCurrentContext {
                self.clearDeleteUndoHistory(using: undoManager)
            }
            if matchesCurrentContext, let restoreSelectionPayload {
                self.document.applySelectionSnapshot(restoreSelectionPayload)
            }
            let restoreSelectionLocalID = restoreSelectionPayload?.localID
            if matchesCurrentContext {
                self.transport.setPendingSelectionOverride(localID: restoreSelectionLocalID)
            }
            let reloadResult: DOMMutationResult
            if matchesCurrentContext {
                reloadResult = await self.resyncDocumentAfterContextLoss()
            } else {
                reloadResult = await self.resyncDocumentAfterContextLoss()
            }
            if matchesCurrentContext, reloadResult == .applied {
                self.reconcileSelectionAfterUndoRestore(restoreSelectionPayload)
            }
            if matchesCurrentContext, reloadResult != .applied {
                self.transport.setPendingSelectionOverride(localID: nil)
            }
        }
    }

    private func registerRedoDelete(
        undoToken: Int,
        nodeId: Int,
        context: DOMInspectorRuntime.MutationContext,
        undoManager: UndoManager,
        restoreSelectionPayload: DOMSelectionSnapshotPayload?
    ) {
        rememberDeleteUndoManager(undoManager)
        undoManager.registerUndo(withTarget: self) { target in
            target.performRedoDelete(
                undoToken: undoToken,
                nodeId: nodeId,
                context: context,
                undoManager: undoManager,
                restoreSelectionPayload: restoreSelectionPayload
            )
        }
        undoManager.setActionName("Delete Node")
    }

    private func performRedoDelete(
        undoToken: Int,
        nodeId: Int,
        context: DOMInspectorRuntime.MutationContext,
        undoManager: UndoManager,
        restoreSelectionPayload: DOMSelectionSnapshotPayload?
    ) {
        guard transport.matchesCurrentMutationContext(context) else {
            clearDeleteUndoHistory(using: undoManager)
            return
        }
        registerUndoDelete(
            undoToken: undoToken,
            nodeId: nodeId,
            context: context,
            undoManager: undoManager,
            restoreSelectionPayload: restoreSelectionPayload
        )
        Task.immediateIfAvailable { [weak self] in
            guard let self else {
                return
            }
            guard self.transport.matchesCurrentMutationContext(context) else {
                self.clearDeleteUndoHistory(using: undoManager)
                return
            }
            let didSyncMutationContext = await self.transport.syncMutationContextToPageIfNeeded(context)
            guard didSyncMutationContext || self.session.hasPageWebView == false else {
                self.clearDeleteUndoHistory(using: undoManager)
                return
            }
            guard self.transport.matchesCurrentMutationContext(context) else {
                self.clearDeleteUndoHistory(using: undoManager)
                return
            }
            let removed = await self.session.redoRemoveNode(
                undoToken: undoToken,
                nodeId: nodeId,
                expectedPageEpoch: context.pageEpoch,
                expectedDocumentScopeID: context.documentScopeID
            )
            guard case .applied = removed else {
                self.clearDeleteUndoHistory(using: undoManager)
                return
            }
            self.transport.setPendingSelectionOverride(localID: nil)
            let matchesCurrentContext = self.transport.matchesCurrentMutationContext(context)
            if !matchesCurrentContext {
                self.clearDeleteUndoHistory(using: undoManager)
                let reloadResult = await self.reloadDocumentImpl(
                    .fresh,
                    expectedPageEpoch: self.transport.currentPageEpoch,
                    pinDocumentScope: false
                )
                if reloadResult != .applied {
                    _ = await self.resyncDocumentAfterContextLoss()
                }
                return
            }
            await self.applyDeletedNodeMutationResult(
                nodeId: nodeId,
                nodeLocalID: nodeId >= 0 ? UInt64(nodeId) : nil,
                expectedContext: context
            )
        }
    }

    private func applyDeletedNodeMutationResult(
        nodeId: Int,
        nodeLocalID: UInt64? = nil,
        expectedContext: DOMInspectorRuntime.MutationContext
    ) async {
        if transport.matchesCurrentMutationContext(expectedContext) {
            if let nodeLocalID,
               let node = document.node(localID: nodeLocalID) {
                document.removeNode(id: node.id)
            } else if let node = document.node(backendNodeID: nodeId) {
                document.removeNode(id: node.id)
            }
        } else if session.hasPageWebView {
            _ = await resyncDocumentAfterContextLoss()
        }
    }

    private func selectionRestorePayload(
        for nodeId: Int,
        nodeLocalID: UInt64? = nil
    ) -> DOMSelectionSnapshotPayload? {
        guard let selectedNode = document.selectedNode else {
            return nil
        }
        if let nodeLocalID {
            guard selectedNode.localID == nodeLocalID else {
                return nil
            }
        } else if selectedNode.backendNodeID != nodeId {
            return nil
        }
        return .init(
            localID: selectedNode.localID,
            backendNodeID: selectedNode.backendNodeID,
            preview: selectedNode.preview,
            attributes: selectedNode.attributes,
            path: selectedNode.path,
            selectorPath: selectedNode.selectorPath,
            styleRevision: selectedNode.styleRevision
        )
    }

    private func reconcileSelectionAfterUndoRestore(_ payload: DOMSelectionSnapshotPayload?) {
        guard let payload else {
            return
        }

        let resolvedNode: DOMNodeModel?
        if let backendNodeID = payload.backendNodeID {
            resolvedNode = document.node(backendNodeID: backendNodeID)
        } else if let localID = payload.localID {
            resolvedNode = document.node(localID: localID)
        } else {
            resolvedNode = nil
        }

        guard let resolvedNode else {
            return
        }

        document.applySelectionSnapshot(
            .init(
                localID: resolvedNode.localID,
                backendNodeID: resolvedNode.backendNodeID ?? payload.backendNodeID,
                preview: payload.preview,
                attributes: resolvedNode.attributes,
                path: payload.path,
                selectorPath: payload.selectorPath,
                styleRevision: payload.styleRevision
            )
        )
        transport.setPendingSelectionOverride(localID: resolvedNode.localID)
    }

    func rememberDeleteUndoManager(_ undoManager: UndoManager) {
        if undoManager.levelsOfUndo == 0 || undoManager.levelsOfUndo > domDeleteUndoHistoryLimit {
            undoManager.levelsOfUndo = domDeleteUndoHistoryLimit
        }
        deleteUndoManager = undoManager
    }

    private func beginSelectionRequest(_ request: SelectionRequest) {
        activeSelectionRequest = request
#if canImport(UIKit)
        disablePageScrollingForSelection()
#endif
        isSelectingElement = true
    }

    private func clearSelectionRequestState() {
        activeSelectionRequest = nil
        isSelectingElement = false
#if canImport(UIKit)
        restorePageScrollingState()
#endif
    }

    private func finishSelectionRequest(_ request: SelectionRequest) {
        guard activeSelectionRequest === request else {
            return
        }
        clearSelectionRequestState()
    }

    private func ensureSelectionRequestIsCurrent(_ request: SelectionRequest) throws {
        guard activeSelectionRequest === request else {
            throw CancellationError()
        }
    }

    private func invalidateSelectionInteractionTask() {
        selectionInteractionGeneration &+= 1
        selectionInteractionTask?.cancel()
        selectionInteractionTask = nil
    }

    private func startSelectionInteractionIfPossible() {
        guard session.hasPageWebView else {
            return
        }

        invalidateSelectionInteractionTask()
        let request = startSelectionRequest()
        let generation = selectionInteractionGeneration
        selectionInteractionTask = Task.immediateIfAvailable { [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.selectionInteractionGeneration == generation {
                    self.selectionInteractionTask = nil
                }
            }
            _ = try? await self.performSelectionRequest(request)
        }
    }

    private func cancelSelectionInteraction() {
        guard isSelectingElement else {
            return
        }

        invalidateSelectionInteractionTask()
        clearSelectionRequestState()
        Task.immediateIfAvailable { [weak self] in
            guard let self else {
                return
            }
            await self.session.cancelSelectionMode()
        }
    }

    private func beginSelectionRequestAndPerform() async throws -> DOMSelectionResult {
        let request = startSelectionRequest()
        return try await performSelectionRequest(request)
    }

    private func startSelectionRequest() -> SelectionRequest {
        let request = SelectionRequest()
        beginSelectionRequest(request)
        return request
    }

    private func performSelectionRequest(_ request: SelectionRequest) async throws -> DOMSelectionResult {
        await session.hideHighlight()
        applyRecoverableError(nil)
        defer {
            finishSelectionRequest(request)
        }
        activatePageWindowForSelectionIfPossible()
#if canImport(UIKit)
        await waitForPageWindowActivationIfNeeded()
#endif
        let result: DOMSelectionResult
        do {
            result = try await session.beginSelectionMode()
        } catch is CancellationError {
            if activeSelectionRequest === request {
                await session.cancelSelectionMode()
            }
            throw CancellationError()
        } catch {
            domViewLogger.error("selection mode failed: \(error.localizedDescription, privacy: .public)")
            applyRecoverableError(error.localizedDescription)
            throw error
        }
        try Task.checkCancellation()
        try ensureSelectionRequestIsCurrent(request)
        guard !result.cancelled else {
            return result
        }

        let expectedContext = transport.currentMutationContext
        guard transport.matchesCurrentMutationContext(expectedContext) else {
            return result
        }

        guard let selectedNode = await resolveSelectionNode(
            result,
            expectedContext: expectedContext
        ) else {
            applyRecoverableError("Failed to resolve selected element.")
            return result
        }
        let projectedSelectedNode = refreshSelectionNodeMetadata(
            selectedNode,
            from: result
        )

        applyRecoverableError(nil)
        await applySelection(
            projectedSelectedNode,
            expectedContext: expectedContext
        )
        return result
    }

    private func resolveSelectionNode(
        _ result: DOMSelectionResult,
        expectedContext: DOMInspectorRuntime.MutationContext
    ) async -> DOMNodeModel? {
        if let selectedLocalNode = selectedLocalNode(from: result),
           node(selectedLocalNode, matches: result) {
            return selectedLocalNode
        }

        let selectedBackendNodeID = selectedBackendNodeID(from: result)
        if let selectedBackendNodeID,
           let existingNode = document.node(backendNodeID: selectedBackendNodeID) {
            return existingNode
        }

        if let materializedNode = await materializeSelectionNode(
            selectedBackendNodeID: selectedBackendNodeID,
            ancestorBackendNodeIDs: result.ancestorBackendNodeIds ?? [],
            selectedLocalID: result.selectedLocalId,
            ancestorLocalIDs: result.ancestorLocalIds ?? [],
            fallbackDepth: result.requiredDepth,
            expectedContext: expectedContext
        ) {
            return materializedNode
        }

        if let selectedLocalNode = selectedLocalNode(from: result),
           node(selectedLocalNode, matches: result) {
            return selectedLocalNode
        }

        if let selectedPath = result.selectedPath,
           let pathNode = documentNode(at: selectedPath, from: document.rootNode) {
            return pathNode
        }

        if let placeholderNode = applySelectionPlaceholderIfPossible(from: result) {
            return placeholderNode
        }

        return nil
    }

    private func selectedBackendNodeID(from result: DOMSelectionResult) -> Int? {
        guard let selectedBackendNodeId = result.selectedBackendNodeId,
              selectedBackendNodeId <= UInt64(Int.max)
        else {
            return nil
        }
        if result.selectedBackendNodeIdIsStable == false {
            return nil
        }
        return Int(selectedBackendNodeId)
    }

    private func selectedLocalNode(from result: DOMSelectionResult) -> DOMNodeModel? {
        guard let selectedLocalID = result.selectedLocalId else {
            return nil
        }
        return document.node(localID: selectedLocalID)
    }

    private func applySelectionPlaceholderIfPossible(
        from result: DOMSelectionResult
    ) -> DOMNodeModel? {
        guard let localID = result.selectedLocalId else {
            return nil
        }

        let backendNodeID = selectedBackendNodeID(from: result)
        let attributes = (result.selectedAttributes ?? []).map { attribute in
            DOMAttribute(
                nodeId: backendNodeID,
                name: attribute.name,
                value: attribute.value
            )
        }
        let preview = result.selectedPreview ?? ""
        let selectorPath = result.selectedSelectorPath
        let path = selectionPathLabels(for: result.selectedPath)
        document.applySelectionSnapshot(
            .init(
                localID: localID,
                backendNodeID: backendNodeID,
                preview: preview,
                attributes: attributes,
                path: path,
                selectorPath: selectorPath,
                styleRevision: 0
            )
        )
        return document.selectedNode
    }

    private func refreshSelectionNodeMetadata(
        _ node: DOMNodeModel,
        from result: DOMSelectionResult
    ) -> DOMNodeModel {
        let preview = result.selectedPreview ?? selectionPreview(for: node)
        let backendNodeID = node.backendNodeID
        let path = selectionPathLabels(for: result.selectedPath)
        let selectionAttributes = result.selectedAttributes?.map { attribute in
            DOMAttribute(
                nodeId: backendNodeID,
                name: attribute.name,
                value: attribute.value
            )
        }
        let payload = DOMSelectionSnapshotPayload(
            localID: node.localID,
            backendNodeID: backendNodeID,
            preview: preview,
            attributes: selectionAttributes ?? node.attributes,
            path: path.isEmpty ? selectionPathLabels(for: node) : path,
            selectorPath: result.selectedSelectorPath,
            styleRevision: node.styleRevision
        )
        document.applySelectionSnapshot(payload)
        return document.selectedNode ?? node
    }

    private func node(
        _ node: DOMNodeModel,
        matches result: DOMSelectionResult
    ) -> Bool {
        if let expectedBackendNodeID = selectedBackendNodeID(from: result),
           node.backendNodeID != expectedBackendNodeID {
            return false
        }
        let selectedAttributes = result.selectedAttributes ?? []
        guard !selectedAttributes.isEmpty else {
            return true
        }
        for attribute in selectedAttributes {
            guard node.attributes.contains(where: {
                $0.name == attribute.name && $0.value == attribute.value
            }) else {
                return false
            }
        }
        return true
    }

    private func materializeSelectionNode(
        selectedBackendNodeID: Int?,
        ancestorBackendNodeIDs: [UInt64],
        selectedLocalID: UInt64?,
        ancestorLocalIDs: [UInt64],
        fallbackDepth: Int,
        expectedContext: DOMInspectorRuntime.MutationContext
    ) async -> DOMNodeModel? {
        guard transport.matchesCurrentMutationContext(expectedContext) else {
            return nil
        }

        let normalizedAncestorLocalIDs = ancestorLocalIDs.compactMap { ancestorLocalID -> Int? in
            guard ancestorLocalID <= UInt64(Int.max) else {
                return nil
            }
            return Int(ancestorLocalID)
        }
        let normalizedSelectedLocalID: Int? = {
            guard let selectedLocalID, selectedLocalID <= UInt64(Int.max) else {
                return nil
            }
            return Int(selectedLocalID)
        }()

        var fetchCandidates: [(target: DOMRequestNodeTarget, depth: Int)] = []
        for (index, ancestorLocalID) in normalizedAncestorLocalIDs.enumerated().reversed() {
            guard document.node(localID: UInt64(ancestorLocalID)) != nil else {
                continue
            }
            fetchCandidates.append((
                target: .local(UInt64(ancestorLocalID)),
                depth: max(1, normalizedAncestorLocalIDs.count - index)
            ))
            break
        }

        if let selectedBackendNodeID {
            fetchCandidates.append((
                target: .backend(selectedBackendNodeID),
                depth: max(1, fallbackDepth)
            ))
        }

        for ancestorBackendNodeID in ancestorBackendNodeIDs.reversed() {
            guard ancestorBackendNodeID <= UInt64(Int.max) else {
                continue
            }
            fetchCandidates.append((
                target: .backend(Int(ancestorBackendNodeID)),
                depth: max(1, fallbackDepth)
            ))
        }

        if let fallbackLocalID = normalizedAncestorLocalIDs.first ?? normalizedSelectedLocalID {
            fetchCandidates.append((
                target: .local(UInt64(fallbackLocalID)),
                depth: max(1, fallbackDepth)
            ))
        } else if let rootLocalID = document.rootNode?.localID, rootLocalID <= UInt64(Int.max) {
            fetchCandidates.append((
                target: .local(rootLocalID),
                depth: max(1, fallbackDepth)
            ))
        }

        var attemptedTargets = Set<DOMRequestNodeTarget>()
        for candidate in fetchCandidates {
            guard attemptedTargets.insert(candidate.target).inserted else {
                continue
            }
            let didMaterialize = await transport.materializeSubtree(
                target: candidate.target,
                depth: candidate.depth,
                expectedContext: expectedContext
            )
            guard didMaterialize,
                  transport.matchesCurrentMutationContext(expectedContext)
            else {
                continue
            }
            if let normalizedSelectedLocalID,
               let materializedNode = document.node(localID: UInt64(normalizedSelectedLocalID)) {
                return materializedNode
            }
            if let selectedBackendNodeID,
               let materializedNode = document.node(backendNodeID: selectedBackendNodeID) {
                return materializedNode
            }
        }

        return nil
    }

    private func applySelection(
        _ node: DOMNodeModel,
        expectedContext: DOMInspectorRuntime.MutationContext
    ) async {
        guard transport.matchesCurrentMutationContext(expectedContext) else {
            return
        }

        let selectionPayload = selectionPayloadDictionary(for: node)
        transport.handleDOMSelectionMessage(selectionPayload)
        guard transport.matchesCurrentMutationContext(expectedContext) else {
            return
        }

        _ = await transport.dispatchSelectionToFrontend(
            payload: selectionPayload,
            expectedContext: expectedContext
        )
    }

    private func selectionSnapshotPayload(for node: DOMNodeModel) -> DOMSelectionSnapshotPayload {
        .init(
            localID: node.localID,
            backendNodeID: node.backendNodeID,
            preview: selectionPreview(for: node),
            attributes: node.attributes,
            path: selectionPathLabels(for: node),
            selectorPath: node.selectorPath,
            styleRevision: node.styleRevision
        )
    }

    private func selectionPayloadDictionary(for node: DOMNodeModel) -> [String: Any] {
        let selectedNodePath = selectionNodePath(for: node)
        return [
            "id": node.localID,
            "selectedLocalId": node.localID,
            "backendNodeId": node.backendNodeID as Any,
            "preview": selectionPreview(for: node),
            "attributes": node.attributes.map {
                [
                    "nodeId": $0.nodeId as Any,
                    "name": $0.name,
                    "value": $0.value,
                ]
            },
            "path": selectionPathLabels(for: node),
            "selectedNodePath": selectedNodePath as Any,
            "selectorPath": node.selectorPath,
            "styleRevision": node.styleRevision,
        ]
    }

    private func selectionPreview(for node: DOMNodeModel) -> String {
        if !node.preview.isEmpty {
            return node.preview
        }

        if node.nodeType == 3 {
            return node.nodeValue
        }

        let resolvedLocalName = node.localName.isEmpty ? node.nodeName.lowercased() : node.localName
        let serializedAttributes = node.attributes.prefix(2).map { attribute in
            "\(attribute.name)=\"\(attribute.value)\""
        }.joined(separator: " ")
        if serializedAttributes.isEmpty {
            return "<\(resolvedLocalName)>"
        }
        return "<\(resolvedLocalName) \(serializedAttributes)>"
    }

    private func selectionPathLabels(for node: DOMNodeModel) -> [String] {
        if !node.path.isEmpty {
            return node.path
        }

        var labels: [String] = []
        var currentNode: DOMNodeModel? = node
        while let current = currentNode {
            labels.insert(selectionPreview(for: current), at: 0)
            currentNode = current.parent
        }
        return labels
    }

    private func selectionNodePath(for node: DOMNodeModel) -> [Int]? {
        var indices: [Int] = []
        var currentNode: DOMNodeModel? = node
        while let current = currentNode, let parent = current.parent {
            guard let childIndex = parent.children.firstIndex(where: { $0 === current }) else {
                return nil
            }
            indices.insert(childIndex, at: 0)
            currentNode = parent
        }
        guard currentNode === document.rootNode else {
            return nil
        }
        return indices
    }

    private func selectionPathLabels(for path: [Int]?) -> [String] {
        guard let path,
              let rootNode = document.rootNode
        else {
            return []
        }
        var labels: [String] = [selectionPreview(for: rootNode)]
        var current = rootNode
        for index in path {
            guard index >= 0, index < current.children.count else {
                break
            }
            current = current.children[index]
            labels.append(selectionPreview(for: current))
        }
        return labels
    }

    private func documentNode(at path: [Int], from root: DOMNodeModel?) -> DOMNodeModel? {
        guard let root else {
            return nil
        }
        var current = root
        for index in path {
            guard index >= 0, index < current.children.count else {
                return nil
            }
            current = current.children[index]
        }
        return current
    }

    func applyRecoverableError(_ message: String?) {
        document.setErrorMessage(message)
        externalRecoverableErrorHandler?(message)
    }

    func clearDeleteUndoHistory(using undoManager: UndoManager? = nil) {
        let manager = undoManager ?? deleteUndoManager
        manager?.removeAllActions(withTarget: self)
        if let manager, manager === deleteUndoManager {
            deleteUndoManager = nil
        }
    }

#if canImport(UIKit)
    func copyToSystemPasteboard(_ text: String) {
        UIPasteboard.general.string = text
    }

    func disablePageScrollingForSelection() {
        guard let scrollView = session.pageWebView?.scrollView else {
            return
        }
        if scrollBackup == nil {
            scrollBackup = (scrollView.isScrollEnabled, scrollView.panGestureRecognizer.isEnabled)
        }
        scrollView.isScrollEnabled = false
        scrollView.panGestureRecognizer.isEnabled = false
    }

    func restorePageScrollingState() {
        guard let scrollView = session.pageWebView?.scrollView else {
            scrollBackup = nil
            return
        }
        if let backup = scrollBackup {
            scrollView.isScrollEnabled = backup.isScrollEnabled
            scrollView.panGestureRecognizer.isEnabled = backup.isPanEnabled
        }
        scrollBackup = nil
    }
#endif
}

#if DEBUG
extension WIDOMInspector {
    func testSelectionRestorePayload(for nodeId: Int) -> DOMSelectionSnapshotPayload? {
        selectionRestorePayload(for: nodeId)
    }
}
#endif
