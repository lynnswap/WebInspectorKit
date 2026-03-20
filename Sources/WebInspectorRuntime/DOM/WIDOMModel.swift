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

    public let session: DOMSession
    private let frontendStore: DOMFrontendStore

    public private(set) var errorMessage: String?
    public private(set) var isSelectingElement = false

    @ObservationIgnored private var activeSelectionRequest: SelectionRequest?
    @ObservationIgnored private var pendingDeleteTask: Task<Void, Never>?
    @ObservationIgnored private weak var deleteUndoManager: UndoManager?
#if canImport(UIKit)
    @ObservationIgnored private var scrollBackup: (isScrollEnabled: Bool, isPanEnabled: Bool)?
#endif

    package init(
        session: DOMSession,
        onRecoverableError: (@MainActor (String) -> Void)? = nil
    ) {
        self.session = session
        self.frontendStore = DOMFrontendStore(session: session)
        self.frontendStore.onRecoverableError = onRecoverableError
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

    public var selectedEntry: DOMEntry? {
        session.graphStore.selectedEntry
    }

    package func setRecoverableErrorHandler(_ handler: (@MainActor (String) -> Void)?) {
        frontendStore.onRecoverableError = handler
    }

    package func makeInspectorWebView() -> WKWebView {
        frontendStore.makeInspectorWebView()
    }

    package func enqueueMutationBundle(_ bundle: Any, preserveState: Bool) {
        frontendStore.enqueueMutationBundle(bundle, preserveState: preserveState)
    }

    package var pendingMutationBundleCount: Int {
        frontendStore.pendingMutationBundleCount
    }

    func withFrontendStore(_ body: (DOMFrontendStore) -> Void) {
        body(frontendStore)
    }

    func attach(to webView: WKWebView) async {
        await resetInteractionState()
        if let previousPageWebView = session.lastPageWebView, previousPageWebView !== webView {
            frontendStore.clearPendingMutationBundles()
        }
        let outcome = await session.attach(to: webView)
        if outcome.shouldReload {
            await reloadInspectorImpl(preserveState: outcome.preserveState)
        }
    }

    func suspend() async {
        await resetInteractionState()
        await session.suspend()
    }

    func detach() async {
        await resetInteractionState()
        await session.detach()
        frontendStore.detachInspectorWebView()
        errorMessage = nil
    }

    func setAutoSnapshotEnabled(_ enabled: Bool) async {
        guard session.hasPageWebView else {
            return
        }
        await session.setAutoSnapshot(enabled: enabled)
    }

    public func reloadInspector(preserveState: Bool = false) async {
        await reloadInspectorImpl(preserveState: preserveState)
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

    func tearDownForDeinit() {
        activeSelectionRequest = nil
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        frontendStore.detachInspectorWebView()
        session.tearDownForDeinit()
        errorMessage = nil
        isSelectingElement = false
        clearDeleteUndoHistory()
#if canImport(UIKit)
        restorePageScrollingState()
#endif
    }

    public func copySelection(_ kind: DOMSelectionCopyKind) async throws -> String {
        try await copySelectionImpl(kind)
    }

    public func deleteSelectedNode() async {
        await deleteSelectedNode(undoManager: nil)
    }

    public func deleteSelectedNode(undoManager: UndoManager?) async {
        await deleteNodeImpl(nodeId: selectedEntry?.backendNodeID, undoManager: undoManager)
    }

    public func deleteNode(nodeId: Int?, undoManager: UndoManager?) async {
        await deleteNodeImpl(nodeId: nodeId, undoManager: undoManager)
    }

    public func updateAttributeValue(name: String, value: String) async {
        await updateAttributeValueImpl(name: name, value: value)
    }

    public func removeAttribute(name: String) async {
        await removeAttributeImpl(name: name)
    }
}

private extension WIDOMModel {
    func reloadInspectorImpl(preserveState: Bool) async {
        guard session.hasPageWebView else {
            errorMessage = "Web view unavailable."
            return
        }
        if errorMessage != nil {
            errorMessage = nil
        }

        let depth = session.configuration.snapshotDepth
        await frontendStore.updateConfiguration(session.configuration)
        await frontendStore.setPreferredDepth(depth)
        await frontendStore.requestDocument(depth: depth, preserveState: preserveState)
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
        activeSelectionRequest = nil
        isSelectingElement = false
#if canImport(UIKit)
        restorePageScrollingState()
#endif
        await session.cancelSelectionMode()
    }

    func copySelectionImpl(_ kind: DOMSelectionCopyKind) async throws -> String {
        guard let nodeId = selectedEntry?.backendNodeID else {
            return ""
        }
        return try await session.selectionCopyText(nodeId: nodeId, kind: kind)
    }

    func deleteNodeImpl(nodeId: Int?, undoManager: UndoManager?) async {
        guard let nodeId else { return }
        await enqueueDelete(nodeId: nodeId, undoManager: undoManager)
    }

    func updateAttributeValueImpl(name: String, value: String) async {
        guard let nodeId = selectedEntry?.backendNodeID else { return }
        session.graphStore.updateSelectedAttribute(name: name, value: value)
        await session.setAttribute(nodeId: nodeId, name: name, value: value)
    }

    func removeAttributeImpl(name: String) async {
        guard let nodeId = selectedEntry?.backendNodeID else { return }
        session.graphStore.removeSelectedAttribute(name: name)
        await session.removeAttribute(nodeId: nodeId, name: name)
    }

    func beginSelectionModeImpl() async throws -> DOMSelectionResult {
        guard session.hasPageWebView else {
            throw WebInspectorCoreError.scriptUnavailable
        }
        if isSelectingElement {
            await cancelSelectionModeImpl()
        }
        let request = SelectionRequest()
        beginSelectionRequest(request)
        await session.hideHighlight()
        errorMessage = nil
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
            errorMessage = error.localizedDescription
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
        await reloadInspectorImpl(preserveState: true)
        return result
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

    func enqueueDelete(nodeId: Int, undoManager: UndoManager?) async {
        let previousTask = pendingDeleteTask
        let task = Task { [weak self] in
            guard let self else { return }
            if let previousTask {
                await previousTask.value
            }
            guard !Task.isCancelled else { return }

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
                session.graphStore.applySelectionSnapshot(
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
            await reloadInspector(preserveState: true)
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
                session.graphStore.select((nil as DOMEntryID?))
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

    private func finishSelectionRequest(_ request: SelectionRequest) {
        guard activeSelectionRequest === request else {
            return
        }
        activeSelectionRequest = nil
        isSelectingElement = false
#if canImport(UIKit)
        restorePageScrollingState()
#endif
    }

    private func ensureSelectionRequestIsCurrent(_ request: SelectionRequest) throws {
        guard activeSelectionRequest === request else {
            throw CancellationError()
        }
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
