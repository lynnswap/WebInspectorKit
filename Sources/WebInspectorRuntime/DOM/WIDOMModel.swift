import OSLog
import Observation
import WebKit
import WebInspectorModel
import WebInspectorEngine

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private let domViewLogger = Logger(subsystem: "WebInspectorKit", category: "WIDOMModel")
private let domDeleteUndoHistoryLimit = 128

@MainActor
@Observable
public final class WIDOMModel {
    public let session: DOMSession
    public let selection: DOMSelection
    private let frontendStore: DOMFrontendStore

    public private(set) var errorMessage: String?
    public private(set) var isSelectingElement = false

    @ObservationIgnored var commandSink: ((WIDOMCommand) -> Void)?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var pendingDeleteTask: Task<Void, Never>?
    @ObservationIgnored private var pendingDeleteGeneration: UInt64 = 0
    @ObservationIgnored private weak var deleteUndoManager: UndoManager?
#if canImport(UIKit)
    @ObservationIgnored private var scrollBackup: (isScrollEnabled: Bool, isPanEnabled: Bool)?
#endif

    package init(
        session: DOMSession,
        onRecoverableError: (@MainActor (String) -> Void)? = nil
    ) {
        self.session = session
        self.selection = session.selection
        self.frontendStore = DOMFrontendStore(session: session)
        self.frontendStore.onRecoverableError = onRecoverableError
    }

    isolated deinit {
        selectionTask?.cancel()
        pendingDeleteTask?.cancel()
        clearDeleteUndoHistory()
#if canImport(UIKit)
        restorePageScrollingState()
#endif
    }

    public var hasPageWebView: Bool {
        session.hasPageWebView
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

#if canImport(AppKit)
    package func setDOMContextMenuProvider(_ provider: ((Int?) -> NSMenu?)?) {
        frontendStore.setDOMContextMenuProvider(provider)
    }
#endif

    func attach(to webView: WKWebView) {
        resetInteractionState()
        if let previousPageWebView = session.lastPageWebView, previousPageWebView !== webView {
            frontendStore.clearPendingMutationBundles()
        }
        let outcome = session.attach(to: webView)
        if outcome.shouldReload {
            Task {
                await self.reloadInspectorImpl(preserveState: outcome.preserveState)
            }
        }
    }

    func suspend() {
        resetInteractionState()
        session.suspend()
    }

    func detach() {
        resetInteractionState()
        session.detach()
        frontendStore.detachInspectorWebView()
        errorMessage = nil
    }

    public func reloadInspector(preserveState: Bool = false) async {
        if dispatch(.reloadInspector(preserveState: preserveState)) {
            return
        }
        await reloadInspectorImpl(preserveState: preserveState)
    }

    public func updateSnapshotDepth(_ depth: Int) {
        if dispatch(.setSnapshotDepth(depth)) {
            return
        }
        updateSnapshotDepthImpl(depth)
    }

    public func toggleSelectionMode() {
        if dispatch(.toggleSelectionMode) {
            return
        }
        toggleSelectionModeImpl()
    }

    public func cancelSelectionMode() {
        if dispatch(.cancelSelectionMode) {
            return
        }
        cancelSelectionModeImpl()
    }

    public func copySelection(_ kind: DOMSelectionCopyKind) {
        if dispatch(.copySelection(kind)) {
            return
        }
        copySelectionImpl(kind)
    }

    public func deleteSelectedNode() {
        deleteSelectedNode(undoManager: nil)
    }

    public func deleteSelectedNode(undoManager: UndoManager?) {
        if dispatch(.deleteSelectedNode(undoManager: undoManager)) {
            return
        }
        deleteNodeImpl(nodeId: selection.nodeId, undoManager: undoManager)
    }

    public func deleteNode(nodeId: Int?, undoManager: UndoManager?) {
        if dispatch(.deleteNode(nodeId: nodeId, undoManager: undoManager)) {
            return
        }
        deleteNodeImpl(nodeId: nodeId, undoManager: undoManager)
    }

    public func updateAttributeValue(name: String, value: String) {
        if dispatch(.updateAttributeValue(name: name, value: value)) {
            return
        }
        updateAttributeValueImpl(name: name, value: value)
    }

    public func removeAttribute(name: String) {
        if dispatch(.removeAttribute(name: name)) {
            return
        }
        removeAttributeImpl(name: name)
    }

    func execute(_ command: WIDOMCommand) async {
        switch command {
        case let .reloadInspector(preserveState):
            await reloadInspectorImpl(preserveState: preserveState)
        case let .setSnapshotDepth(depth):
            updateSnapshotDepthImpl(depth)
        case .toggleSelectionMode:
            toggleSelectionModeImpl()
        case .cancelSelectionMode:
            cancelSelectionModeImpl()
        case let .copySelection(kind):
            copySelectionImpl(kind)
        case let .deleteSelectedNode(undoManager):
            deleteNodeImpl(nodeId: selection.nodeId, undoManager: undoManager)
        case let .deleteNode(nodeId, undoManager):
            deleteNodeImpl(nodeId: nodeId, undoManager: undoManager)
        case let .updateAttributeValue(name, value):
            updateAttributeValueImpl(name: name, value: value)
        case let .removeAttribute(name):
            removeAttributeImpl(name: name)
        }
    }
}

private extension WIDOMModel {
    func dispatch(_ command: WIDOMCommand) -> Bool {
        guard let commandSink else {
            return false
        }
        commandSink(command)
        return true
    }

    func reloadInspectorImpl(preserveState: Bool) async {
        guard session.hasPageWebView else {
            errorMessage = "Web view unavailable."
            return
        }
        if errorMessage != nil {
            errorMessage = nil
        }

        let depth = session.configuration.snapshotDepth
        frontendStore.updateConfiguration(session.configuration)
        frontendStore.setPreferredDepth(depth)
        frontendStore.requestDocument(depth: depth, preserveState: preserveState)
    }

    func updateSnapshotDepthImpl(_ depth: Int) {
        let clamped = max(1, depth)
        var configuration = session.configuration
        configuration.snapshotDepth = clamped
        session.updateConfiguration(configuration)
        frontendStore.updateConfiguration(configuration)
        frontendStore.setPreferredDepth(clamped)
    }

    func toggleSelectionModeImpl() {
        if isSelectingElement {
            cancelSelectionModeImpl()
        } else {
            startSelectionMode()
        }
    }

    func cancelSelectionModeImpl() {
        guard isSelectingElement || selectionTask != nil else { return }
        selectionTask?.cancel()
        selectionTask = nil
#if canImport(UIKit)
        restorePageScrollingState()
#endif
        Task {
            await session.cancelSelectionMode()
        }
        isSelectingElement = false
    }

    func copySelectionImpl(_ kind: DOMSelectionCopyKind) {
        guard let nodeId = selection.nodeId else { return }
        Task {
            do {
                let text = try await session.selectionCopyText(nodeId: nodeId, kind: kind)
                guard !text.isEmpty else { return }
                copyToPasteboard(text)
            } catch {
                domViewLogger.error("copy \(kind.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func deleteNodeImpl(nodeId: Int?, undoManager: UndoManager?) {
        guard let nodeId else { return }
        enqueueDelete(nodeId: nodeId, undoManager: undoManager)
    }

    func updateAttributeValueImpl(name: String, value: String) {
        guard let nodeId = selection.nodeId else { return }
        selection.updateAttributeValue(nodeId: nodeId, name: name, value: value)
        Task {
            await session.setAttribute(nodeId: nodeId, name: name, value: value)
        }
    }

    func removeAttributeImpl(name: String) {
        guard let nodeId = selection.nodeId else { return }
        selection.removeAttribute(nodeId: nodeId, name: name)
        Task {
            await session.removeAttribute(nodeId: nodeId, name: name)
        }
    }

    func startSelectionMode() {
        guard session.hasPageWebView else { return }
#if canImport(UIKit)
        disablePageScrollingForSelection()
#endif
        isSelectingElement = true
        Task { await session.hideHighlight() }
        selectionTask?.cancel()
        selectionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isSelectingElement = false
                self.selectionTask = nil
#if canImport(UIKit)
                self.restorePageScrollingState()
#endif
            }
            do {
                let result = try await self.session.beginSelectionMode()
                guard !result.cancelled else { return }
                if Task.isCancelled { return }
                let requestedDepth = max(self.session.configuration.snapshotDepth, result.requiredDepth + 1)
                self.updateSnapshotDepthImpl(requestedDepth)
                await self.reloadInspectorImpl(preserveState: true)
            } catch is CancellationError {
                await self.session.cancelSelectionMode()
            } catch {
                domViewLogger.error("selection mode failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
            }
        }
    }

    func resetInteractionState() {
        cancelSelectionModeImpl()
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        clearDeleteUndoHistory()
#if canImport(UIKit)
        restorePageScrollingState()
#endif
    }

    func enqueueDelete(nodeId: Int, undoManager: UndoManager?) {
        let previousTask = pendingDeleteTask
        pendingDeleteGeneration &+= 1
        let generation = pendingDeleteGeneration
        pendingDeleteTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let previousTask {
                await previousTask.value
            }
            guard !Task.isCancelled else { return }
            defer {
                if pendingDeleteGeneration == generation {
                    pendingDeleteTask = nil
                }
            }

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
    }

    func copyToPasteboard(_ text: String) {
#if canImport(UIKit)
        UIPasteboard.general.string = text
#elseif canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
#endif
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            let restored = await session.undoRemoveNode(undoToken: undoToken)
            guard restored else {
                clearDeleteUndoHistory(using: undoManager)
                return
            }
            selection.clear()
            selection.nodeId = nodeId
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            let removed = await session.redoRemoveNode(undoToken: undoToken, nodeId: nodeId)
            guard removed else {
                clearDeleteUndoHistory(using: undoManager)
                return
            }
            if selection.nodeId == nodeId {
                selection.clear()
            }
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

#if canImport(UIKit)
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
