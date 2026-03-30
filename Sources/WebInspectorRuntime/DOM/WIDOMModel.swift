import OSLog
import Observation
import WebKit
import WebInspectorEngine

#if canImport(UIKit)
import UIKit
#endif

private let domViewLogger = Logger(subsystem: "WebInspectorKit", category: "WIDOMModel")
private let domDeleteUndoHistoryLimit = 128

public typealias DOMSelectionResult = DOMPageAgent.SelectionModeResult

@MainActor
@Observable
public final class WIDOMModel {
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
    }

    let session: DOMSession
    let frontendStore: DOMInspectorRuntime
    public private(set) var documentStore: DOMDocumentStore
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
        self.documentStore = DOMDocumentStore()
        self.frontendStore = DOMInspectorRuntime(session: session)
        self.externalRecoverableErrorHandler = onRecoverableError
        self.frontendStore.onRecoverableError = { [weak self] message in
            self?.applyRecoverableError(message)
        }
        self.frontendStore.bindDocumentStore(self.documentStore) { [weak self] store in
            self?.documentStore = store
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
        frontendStore.makeInspectorWebView()
    }

    package func enqueueMutationBundle(_ bundle: Any, preservingInspectorState: Bool) {
        frontendStore.enqueueMutationBundle(bundle, preservingInspectorState: preservingInspectorState)
    }

    package func requestReloadPage() {
        guard session.pageWebView != nil else {
            return
        }
        let expectedPageEpoch = frontendStore.currentPageEpoch
        Task.immediateIfAvailable { [weak self] in
            guard let self else {
                return
            }
            guard self.matchesCurrentPageEpoch(expectedPageEpoch) else {
                return
            }
            await self.resetInteractionState()
            guard self.matchesCurrentPageEpoch(expectedPageEpoch) else {
                return
            }
            await self.frontendStore.performPageTransition { nextPageEpoch in
                self.session.preparePageEpoch(nextPageEpoch)
                await self.session.reloadPageAndWaitForPreparedPageEpochSync()
            }
        }
    }

    package var pendingMutationBundleCount: Int {
        frontendStore.pendingMutationBundleCount
    }

    func attach(to webView: WKWebView) async {
        await resetInteractionState()
        let needsPageEpochAdvance = session.lastPageWebView != nil && session.pageWebView !== webView
        let outcome: DOMSession.AttachmentResult
        if needsPageEpochAdvance {
            outcome = await frontendStore.performPageTransition { nextPageEpoch in
                self.session.preparePageEpoch(nextPageEpoch)
                await self.session.suspend()
                self.session.preparePageEpoch(nextPageEpoch)
                return await self.session.attach(to: webView)
            }
        } else {
            session.preparePageEpoch(frontendStore.currentPageEpoch)
            outcome = await session.attach(to: webView)
        }
        if outcome.shouldReload {
            await reloadDocumentImpl(
                outcome.shouldPreserveInspectorState ? .preservingInspectorState : .fresh
            )
        }
    }

    func suspend() async {
        await resetInteractionState()
        if session.hasPageWebView {
            await frontendStore.performPageTransition(resumeBootstrap: false) { _ in
                await self.session.suspend()
            }
        } else {
            await session.suspend()
        }
    }

    func detach() async {
        await resetInteractionState()
        if session.hasPageWebView {
            await frontendStore.performPageTransition(resumeBootstrap: false) { _ in
                await self.session.detach()
            }
        } else {
            await session.detach()
            frontendStore.resetDocumentStoreForDetachment()
        }
        frontendStore.detachInspectorWebView()
        documentStore.setErrorMessage(nil)
    }

    func setAutoSnapshotEnabled(_ enabled: Bool) async {
        guard session.hasPageWebView else {
            return
        }
        await session.setAutoSnapshot(enabled: enabled)
    }

    public func reloadDocument() async {
        await reloadDocumentImpl(.fresh)
    }

    public func reloadDocumentPreservingInspectorState() async {
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

    package func requestReloadDocument() {
        let expectedPageEpoch = frontendStore.currentPageEpoch
        Task.immediateIfAvailable { [weak self] in
            guard let self else {
                return
            }
            await self.reloadDocumentImpl(.fresh, expectedPageEpoch: expectedPageEpoch)
        }
    }

    package func requestReloadDocumentPreservingInspectorState() {
        let expectedPageEpoch = frontendStore.currentPageEpoch
        Task.immediateIfAvailable { [weak self] in
            guard let self else {
                return
            }
            await self.reloadDocumentImpl(.preservingInspectorState, expectedPageEpoch: expectedPageEpoch)
        }
    }

    package func requestDeleteSelection(undoManager: UndoManager?) {
        requestDeleteNode(nodeId: selectedEntry?.backendNodeID, undoManager: undoManager)
    }

    package func requestDeleteNode(nodeId: Int?, undoManager: UndoManager?) {
        let expectedPageEpoch = frontendStore.currentPageEpoch
        Task.immediateIfAvailable { [weak self] in
            guard let self else {
                return
            }
            await self.deleteNodeImpl(
                nodeId: nodeId,
                undoManager: undoManager,
                expectedPageEpoch: expectedPageEpoch
            )
        }
    }

    package func copyNode(nodeId: Int, kind: DOMSelectionCopyKind) async throws -> String {
        try await session.selectionCopyText(nodeId: nodeId, kind: kind)
    }

    package func requestUpdateAttributeValue(name: String, value: String) {
        let expectedPageEpoch = frontendStore.currentPageEpoch
        let nodeId = selectedEntry?.backendNodeID
        Task.immediateIfAvailable { [weak self] in
            guard let self else {
                return
            }
            await self.updateAttributeValueImpl(
                nodeId: nodeId,
                name: name,
                value: value,
                expectedPageEpoch: expectedPageEpoch
            )
        }
    }

    package func requestRemoveAttribute(name: String) {
        let expectedPageEpoch = frontendStore.currentPageEpoch
        let nodeId = selectedEntry?.backendNodeID
        Task.immediateIfAvailable { [weak self] in
            guard let self else {
                return
            }
            await self.removeAttributeImpl(
                nodeId: nodeId,
                name: name,
                expectedPageEpoch: expectedPageEpoch
            )
        }
    }

    func tearDownForDeinit() {
        invalidateSelectionInteractionTask()
        activeSelectionRequest = nil
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        frontendStore.detachInspectorWebView()
        session.tearDownForDeinit()
        documentStore.setErrorMessage(nil)
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

    public func deleteSelection() async {
        await deleteSelection(undoManager: nil)
    }

    public func deleteSelection(undoManager: UndoManager?) async {
        await deleteNodeImpl(
            nodeId: selectedEntry?.backendNodeID,
            undoManager: undoManager
        )
    }

    package func deleteNode(nodeId: Int?, undoManager: UndoManager?) async {
        await deleteNodeImpl(nodeId: nodeId, undoManager: undoManager)
    }

    public func updateSelectedAttribute(name: String, value: String) async {
        await updateAttributeValueImpl(
            nodeId: selectedEntry?.backendNodeID,
            name: name,
            value: value
        )
    }

    public func removeSelectedAttribute(name: String) async {
        await removeAttributeImpl(
            nodeId: selectedEntry?.backendNodeID,
            name: name
        )
    }
}

private extension WIDOMModel {
    var selectedEntry: DOMEntry? {
        documentStore.selectedEntry
    }

    private func reloadDocumentImpl(
        _ mode: DocumentReloadMode,
        expectedPageEpoch: Int? = nil
    ) async {
        guard session.hasPageWebView else {
            applyRecoverableError("Web view unavailable.")
            return
        }

        let depth = session.configuration.snapshotDepth
        let resolvedPageEpoch = expectedPageEpoch ?? frontendStore.currentPageEpoch
        guard matchesCurrentPageEpoch(resolvedPageEpoch) else {
            return
        }
        if documentStore.errorMessage != nil {
            applyRecoverableError(nil)
        }
        await frontendStore.updateConfiguration(session.configuration, expectedPageEpoch: resolvedPageEpoch)
        await frontendStore.setPreferredDepth(depth, expectedPageEpoch: resolvedPageEpoch)
        await frontendStore.requestDocument(
            depth: depth,
            mode: mode.runtimeMode,
            expectedPageEpoch: resolvedPageEpoch
        )
    }

    func updateSnapshotDepthImpl(_ depth: Int) async {
        let clamped = max(1, depth)
        var configuration = session.configuration
        configuration.snapshotDepth = clamped
        await session.updateConfiguration(configuration)
        await frontendStore.updateConfiguration(configuration)
        await frontendStore.setPreferredDepth(clamped)
    }

    func cancelSelectionModeImpl() async {
        guard isSelectingElement else { return }
        invalidateSelectionInteractionTask()
        clearSelectionRequestState()
        await session.cancelSelectionMode()
    }

    func copySelectionImpl(_ kind: DOMSelectionCopyKind) async throws -> String {
        guard let nodeId = selectedEntry?.backendNodeID else {
            return ""
        }
        return try await session.selectionCopyText(nodeId: nodeId, kind: kind)
    }

    func deleteNodeImpl(
        nodeId: Int?,
        undoManager: UndoManager?,
        expectedPageEpoch: Int? = nil
    ) async {
        guard let nodeId else { return }
        guard matchesCurrentPageEpoch(expectedPageEpoch) else {
            return
        }
        await enqueueDelete(nodeId: nodeId, undoManager: undoManager, expectedPageEpoch: expectedPageEpoch)
    }

    func updateAttributeValueImpl(
        nodeId: Int?,
        name: String,
        value: String,
        expectedPageEpoch: Int? = nil
    ) async {
        guard matchesCurrentPageEpoch(expectedPageEpoch),
              let nodeId,
              selectedEntry?.backendNodeID == nodeId
        else { return }
        documentStore.updateSelectedAttribute(name: name, value: value)
        await session.setAttribute(nodeId: nodeId, name: name, value: value)
    }

    func removeAttributeImpl(
        nodeId: Int?,
        name: String,
        expectedPageEpoch: Int? = nil
    ) async {
        guard matchesCurrentPageEpoch(expectedPageEpoch),
              let nodeId,
              selectedEntry?.backendNodeID == nodeId
        else { return }
        documentStore.removeSelectedAttribute(name: name)
        await session.removeAttribute(nodeId: nodeId, name: name)
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

    func enqueueDelete(
        nodeId: Int,
        undoManager: UndoManager?,
        expectedPageEpoch: Int?
    ) async {
        let previousTask = pendingDeleteTask
        let task = Task { [weak self] in
            guard let self else { return }
            if let previousTask {
                await previousTask.value
            }
            guard !Task.isCancelled else { return }
            guard self.matchesCurrentPageEpoch(expectedPageEpoch) else { return }

            guard let undoManager else {
                await session.removeNode(nodeId: nodeId)
                return
            }
            rememberDeleteUndoManager(undoManager)
            guard let undoToken = await session.removeNodeWithUndo(nodeId: nodeId) else {
                await session.removeNode(nodeId: nodeId)
                return
            }
            registerUndoDelete(
                undoToken: undoToken,
                nodeId: nodeId,
                undoManager: undoManager
            )
        }
        pendingDeleteTask = task
        await task.value
    }

    func matchesCurrentPageEpoch(_ expectedPageEpoch: Int?) -> Bool {
        guard let expectedPageEpoch else {
            return true
        }
        return frontendStore.currentPageEpoch == expectedPageEpoch
    }

    func copyToPasteboard(_ text: String) {
        copyToSystemPasteboard(text)
    }

    func registerUndoDelete(undoToken: Int, nodeId: Int, undoManager: UndoManager) {
        rememberDeleteUndoManager(undoManager)
        undoManager.registerUndo(withTarget: self) { target in
            target.performUndoDelete(
                undoToken: undoToken,
                nodeId: nodeId,
                undoManager: undoManager
            )
        }
        undoManager.setActionName("Delete Node")
    }

    func performUndoDelete(undoToken: Int, nodeId: Int, undoManager: UndoManager) {
        registerRedoDelete(
            undoToken: undoToken,
            nodeId: nodeId,
            undoManager: undoManager
        )
        Task.immediateIfAvailable { [weak self] in
            guard let self else { return }
            let restored = await session.undoRemoveNode(undoToken: undoToken)
            guard restored else {
                clearDeleteUndoHistory(using: undoManager)
                return
            }
            if let localID = UInt64(exactly: nodeId) {
                documentStore.applySelectionSnapshot(
                    .init(
                        localID: localID,
                        preview: "",
                        attributes: [],
                        path: [],
                        selectorPath: "",
                        styleRevision: 0
                    )
                )
            }
            await reloadDocumentPreservingInspectorState()
        }
    }

    func registerRedoDelete(undoToken: Int, nodeId: Int, undoManager: UndoManager) {
        rememberDeleteUndoManager(undoManager)
        undoManager.registerUndo(withTarget: self) { target in
            target.performRedoDelete(
                undoToken: undoToken,
                nodeId: nodeId,
                undoManager: undoManager
            )
        }
        undoManager.setActionName("Delete Node")
    }

    func performRedoDelete(undoToken: Int, nodeId: Int, undoManager: UndoManager) {
        registerUndoDelete(
            undoToken: undoToken,
            nodeId: nodeId,
            undoManager: undoManager
        )
        Task.immediateIfAvailable { [weak self] in
            guard let self else { return }
            let removed = await session.redoRemoveNode(undoToken: undoToken, nodeId: nodeId)
            guard removed else {
                clearDeleteUndoHistory(using: undoManager)
                return
            }
            if selectedEntry?.backendNodeID == nodeId {
                documentStore.clearSelection()
            }
        }
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

        let requestedDepth = max(session.configuration.snapshotDepth, result.requiredDepth + 1)
        await updateSnapshotDepthImpl(requestedDepth)
        try Task.checkCancellation()
        try ensureSelectionRequestIsCurrent(request)
        await reloadDocumentImpl(.preservingInspectorState)
        return result
    }

    func applyRecoverableError(_ message: String?) {
        documentStore.setErrorMessage(message)
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
        guard let scrollView = session.pageWebView?.scrollView else { return }
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
