import OSLog
import Observation
import ObservationBridge
import WebKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private let domViewLogger = Logger(subsystem: "WebInspectorKit", category: "WIDOMStore")
private let domDeleteUndoHistoryLimit = 128
private let domGraphObservationThrottle = ObservationThrottle(
    interval: .milliseconds(80),
    mode: .latest
)

@MainActor
public struct WIDOMTreeRow: Identifiable, Hashable, Sendable {
    public let id: DOMEntryID
    public let depth: Int
    public let canExpand: Bool
    public let isExpanded: Bool
    public let isLoadingChildren: Bool

    init(
        id: DOMEntryID,
        depth: Int,
        canExpand: Bool,
        isExpanded: Bool,
        isLoadingChildren: Bool
    ) {
        self.id = id
        self.depth = depth
        self.canExpand = canExpand
        self.isExpanded = isExpanded
        self.isLoadingChildren = isLoadingChildren
    }
}

@MainActor
@Observable
public final class WIDOMStore {
    package enum DeleteMutationEvent: Sendable, Equatable {
        case removed(nodeId: Int)
        case restored(nodeId: Int)
        case redone(nodeId: Int)
    }

    private struct StyleRefreshKey: Hashable {
        let entryID: DOMEntryID
        let nodeID: Int
        let sourceRevision: Int
    }

    private struct FrontendSelectionRecoveryKey: Hashable {
        let nodeID: Int
    }

    package let session: WIDOMRuntime

    public private(set) var errorMessage: String?
    public private(set) var isSelectingElement = false
    public private(set) var expandedEntryIDs: Set<DOMEntryID> = []
    public private(set) var loadingChildEntryIDs: Set<DOMEntryID> = []
    public private(set) var graphProjectionRevision: UInt64 = 0

    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var pendingDeleteTask: Task<Void, Never>?
    @ObservationIgnored private var pendingDeleteGeneration: UInt64 = 0
    @ObservationIgnored private weak var deleteUndoManager: UndoManager?
    @ObservationIgnored private var graphObservationHandles: Set<ObservationHandle> = []
    @ObservationIgnored private var styleRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var styleRefreshInFlightKey: StyleRefreshKey?
    @ObservationIgnored private var styleRefreshCompletedKey: StyleRefreshKey?
    @ObservationIgnored private var recoverableErrorHandler: (@MainActor (String) -> Void)?
    @ObservationIgnored private var suppressNextSelectedIDRefresh = false
    @ObservationIgnored private var frontendSelectionRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var frontendSelectionRecoveryKey: FrontendSelectionRecoveryKey?
    @ObservationIgnored private let frontendBridge: (any WIDOMFrontendBridge)?
    @ObservationIgnored private var uiBridge: (any WIDOMUIBridge)?
    package var onDeleteMutationForTesting: (@MainActor (DeleteMutationEvent) -> Void)?

    package init(
        session: WIDOMRuntime,
        frontendBridge: (any WIDOMFrontendBridge)? = nil,
        onRecoverableError: (@MainActor (String) -> Void)? = nil
    ) {
        self.session = session
        self.frontendBridge = frontendBridge
        recoverableErrorHandler = onRecoverableError
        frontendBridge?.delegate = self
        session.eventSink = frontendBridge
        startObservingGraphStore()
    }

    isolated deinit {
        if isSelectingElement || selectionTask != nil {
            finishSelectionUIIfNeeded()
        }
        selectionTask?.cancel()
        pendingDeleteTask?.cancel()
        styleRefreshTask?.cancel()
        frontendSelectionRecoveryTask?.cancel()
        clearDeleteUndoHistory()
    }

    public var hasPageWebView: Bool {
        session.hasPageWebView
    }

    public var selectedEntry: DOMEntry? {
        _ = graphProjectionRevision
        return session.graphStore.selectedEntry
    }

    public var backendSupport: WIBackendSupport {
        session.backendSupport
    }

    public var treeRows: [WIDOMTreeRow] {
        _ = graphProjectionRevision
        return buildTreeRows()
    }

    package func setRecoverableErrorHandler(_ handler: (@MainActor (String) -> Void)?) {
        recoverableErrorHandler = handler
    }

    package func setUIBridge(_ bridge: (any WIDOMUIBridge)?) {
        uiBridge = bridge
    }

    package func makeFrontendWebView() -> WKWebView {
        let inspectorWebView = frontendBridge?.makeFrontendWebView() ?? WKWebView(frame: .zero)
        if session.hasPageWebView, session.graphStore.rootID != nil {
            syncFrontendTreeIfNeeded(preserveState: session.graphStore.rootID != nil)
        }
        return inspectorWebView
    }

#if canImport(AppKit)
    package func setDOMContextMenuProvider(_ provider: ((Int?) -> NSMenu?)?) {
        withFrontendBridge { frontendBridge in
            frontendBridge.setDOMContextMenuProvider(provider)
        }
    }
#endif

    func withFrontendBridge(_ body: (any WIDOMFrontendBridge) -> Void) {
        guard let frontendBridge else {
            return
        }
        body(frontendBridge)
    }

    package func entry(for id: DOMEntryID) -> DOMEntry? {
        _ = graphProjectionRevision
        return session.graphStore.entry(for: id)
    }

    package func isExpanded(_ id: DOMEntryID) -> Bool {
        expandedEntryIDs.contains(id)
    }

    package func isLoadingChildren(for id: DOMEntryID) -> Bool {
        loadingChildEntryIDs.contains(id)
    }

    package func setExpandedEntryIDsForTesting(_ ids: Set<DOMEntryID>) {
        expandedEntryIDs = ids
    }

    package func selectEntry(_ id: DOMEntryID?) {
        let previousSelectedID = session.graphStore.selectedID
        session.graphStore.select(id)
        let resolvedSelectedID = session.graphStore.selectedID
        suppressNextSelectedIDRefresh = previousSelectedID != resolvedSelectedID
        invalidateGraphProjection()
        scheduleStyleRefreshIfNeeded(force: true)
        if let entryID = resolvedSelectedID,
           let entry = session.graphStore.entry(for: entryID) {
            Task {
                await self.session.highlight(nodeId: entry.id.nodeID)
            }
        } else {
            Task {
                await self.session.hideHighlight()
            }
        }
    }

    package func toggleExpansion(of id: DOMEntryID) {
        guard let entry = session.graphStore.entry(for: id) else {
            return
        }

        if expandedEntryIDs.contains(id) {
            expandedEntryIDs.remove(id)
            return
        }

        expandedEntryIDs.insert(id)
        guard needsChildFetch(for: entry) else {
            return
        }

        loadingChildEntryIDs.insert(id)
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                self.loadingChildEntryIDs.remove(id)
            }

            do {
                _ = try await self.session.requestChildNodes(parentNodeId: entry.id.nodeID)
            } catch is CancellationError {
                return
            } catch {
                self.publishRecoverableError(error.localizedDescription)
            }
        }
    }

    package func displayName(for entry: DOMEntry) -> String {
        if entry.nodeType == 9 {
            return "#document"
        }
        if entry.nodeType == 3 {
            return "#text"
        }
        let name = entry.localName.isEmpty ? entry.nodeName.lowercased() : entry.localName
        return name.isEmpty ? entry.nodeName : name
    }

    package func secondaryText(for entry: DOMEntry) -> String? {
        if entry.nodeType == 3 {
            let text = entry.nodeValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        if !entry.preview.isEmpty {
            return entry.preview
        }

        let renderedAttributes = entry.attributes
            .prefix(2)
            .map { "\($0.name)=\"\($0.value)\"" }
            .joined(separator: " ")
        return renderedAttributes.isEmpty ? nil : renderedAttributes
    }

    package func attach(to webView: WKWebView) {
        resetInteractionState()
        if let previousPageWebView = session.lastPageWebView, previousPageWebView !== webView {
            clearTreeState()
        }
        let outcome = session.attach(to: webView)
        if outcome.shouldReload {
            Task {
                await self.reloadInspectorImpl(preserveState: outcome.preserveState)
            }
        } else {
            syncFrontendTreeIfNeeded(preserveState: true)
        }
    }

    package func suspend() {
        resetInteractionState()
        session.suspend()
    }

    package func detach() {
        resetInteractionState()
        session.detach()
        frontendBridge?.detachFrontendWebView()
        clearTreeState()
        errorMessage = nil
    }

    package func setAutoSnapshotEnabled(_ enabled: Bool) {
        guard session.hasPageWebView else {
            return
        }
        session.setAutoSnapshot(enabled: enabled)
        if enabled, session.graphStore.rootID == nil {
            Task {
                await self.reloadInspectorImpl(preserveState: false)
            }
        }
    }

    public func reloadFrontend(preserveState: Bool = false) async {
        await reloadInspectorImpl(preserveState: preserveState, minimumDepth: nil)
    }

    public func updateSnapshotDepth(_ depth: Int) {
        updateSnapshotDepthImpl(depth)
    }

    public func toggleSelectionMode() {
        toggleSelectionModeImpl()
    }

    public func cancelSelectionMode() {
        cancelSelectionModeImpl()
    }

    public func copySelection(_ kind: DOMSelectionCopyKind) {
        copySelectionImpl(kind)
    }

    public func deleteSelectedNode() {
        deleteSelectedNode(undoManager: nil)
    }

    public func deleteSelectedNode(undoManager: UndoManager?) {
        deleteNodeImpl(nodeId: selectedEntry?.id.nodeID, undoManager: undoManager)
    }

    public func deleteNode(nodeId: Int?, undoManager: UndoManager?) {
        deleteNodeImpl(nodeId: nodeId, undoManager: undoManager)
    }

    public func updateAttributeValue(name: String, value: String) {
        updateAttributeValueImpl(name: name, value: value)
    }

    public func removeAttribute(name: String) {
        removeAttributeImpl(name: name)
    }
}

#if DEBUG
@_spi(PreviewSupport)
public extension WIDOMStore {
    func wiAttachPreviewPageWebView(_ webView: WKWebView) {
        attach(to: webView)
    }
}
#endif

extension WIDOMStore: WIDOMFrontendBridgeDelegate {
    package func domFrontendDidReceiveRecoverableError(_ message: String) {
        publishRecoverableError(message)
    }

    package func domFrontendDidMissSelectionSnapshot(_ payload: DOMSelectionSnapshotPayload) {
        recoverSelectionFromFrontendSnapshot(payload: payload)
    }

    package func domFrontendDidClearSelection() {
        cancelFrontendSelectionRecovery()
    }
}

private extension WIDOMStore {
    func startObservingGraphStore() {
        let graphStore = session.graphStore

        graphStore.observe(
            \.selectedID,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            guard let self else {
                return
            }
            if let recoveryKey = self.frontendSelectionRecoveryKey,
               let selectedID = graphStore.selectedID,
               recoveryKey.nodeID != selectedID.nodeID {
                self.cancelFrontendSelectionRecovery()
            }
            if self.suppressNextSelectedIDRefresh {
                self.suppressNextSelectedIDRefresh = false
                self.invalidateGraphProjection()
                return
            }
            self.scheduleStyleRefreshIfNeeded(force: true)
            self.invalidateGraphProjection()
        }
        .store(in: &graphObservationHandles)

        graphStore.observe(
            \.entriesByID,
            options: [.rateLimit(.throttle(domGraphObservationThrottle))]
        ) { [weak self] _ in
            self?.pruneTreeState()
            self?.scheduleStyleRefreshIfNeeded(force: false)
            self?.invalidateGraphProjection()
        }
        .store(in: &graphObservationHandles)

        graphStore.observe(
            \.rootID,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.pruneTreeState()
            self?.seedInitialExpansionStateIfNeeded()
            self?.invalidateGraphProjection()
        }
        .store(in: &graphObservationHandles)
    }

    func invalidateGraphProjection() {
        graphProjectionRevision &+= 1
        if graphProjectionRevision == 0 {
            graphProjectionRevision = 1
        }
    }

    func reloadInspectorImpl(preserveState: Bool) async {
        await reloadInspectorImpl(preserveState: preserveState, minimumDepth: nil)
    }

    func updateSnapshotDepthImpl(_ depth: Int) {
        let clamped = max(1, depth)
        var configuration = session.configuration
        configuration.snapshotDepth = clamped
        session.updateConfiguration(configuration)
        frontendBridge?.updateConfiguration(configuration)
        frontendBridge?.setPreferredDepth(clamped)
    }

    func reloadInspectorImpl(preserveState: Bool, minimumDepth: Int?) async {
        guard session.hasPageWebView else {
            publishRecoverableError("Web view unavailable.")
            return
        }

        do {
            let requestedDepth = requestedDocumentDepth(
                preserveState: preserveState,
                minimumDepth: minimumDepth
            )
            try await session.reloadDocument(
                preserveState: preserveState,
                requestedDepth: requestedDepth
            )
            errorMessage = nil
            if preserveState == false {
                seedInitialExpansionState(resetExisting: true)
            } else {
                seedInitialExpansionStateIfNeeded()
                expandSelectedEntryAncestorsIfNeeded()
            }
            syncFrontendTreeIfNeeded(
                preserveState: preserveState,
                depth: requestedDepth
            )
            scheduleStyleRefreshIfNeeded(force: true)
        } catch is CancellationError {
            return
        } catch {
            publishRecoverableError(error.localizedDescription)
        }
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
        finishSelectionUIIfNeeded()
        Task {
            await session.cancelSelectionMode()
        }
        isSelectingElement = false
    }

    func copySelectionImpl(_ kind: DOMSelectionCopyKind) {
        guard let nodeId = selectedEntry?.id.nodeID else { return }
        Task {
            do {
                let text = try await session.selectionCopyText(nodeId: nodeId, kind: kind)
                guard !text.isEmpty else { return }
                copyTextToPasteboard(text)
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
        guard let nodeId = selectedEntry?.id.nodeID else { return }
        session.graphStore.updateSelectedAttribute(name: name, value: value)
        session.graphStore.invalidateStyle(for: nil, reason: .domMutation)
        scheduleStyleRefreshIfNeeded(force: true)
        Task {
            await session.setAttribute(nodeId: nodeId, name: name, value: value)
        }
    }

    func removeAttributeImpl(name: String) {
        guard let nodeId = selectedEntry?.id.nodeID else { return }
        session.graphStore.removeSelectedAttribute(name: name)
        session.graphStore.invalidateStyle(for: nil, reason: .domMutation)
        scheduleStyleRefreshIfNeeded(force: true)
        Task {
            await session.removeAttribute(nodeId: nodeId, name: name)
        }
    }

    func startSelectionMode() {
        guard session.hasPageWebView else { return }
        prepareSelectionUIIfNeeded()
        isSelectingElement = true
        Task { await session.hideHighlight() }
        selectionTask?.cancel()
        selectionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isSelectingElement = false
                self.selectionTask = nil
                self.finishSelectionUIIfNeeded()
            }
            do {
                let result = try await self.session.beginSelectionMode()
                guard !result.cancelled else { return }
                if Task.isCancelled { return }
                let requiredDepth = max(
                    self.session.configuration.selectionRecoveryDepth,
                    result.requiredDepth + 1
                )
                let persistedDepth = max(
                    self.session.configuration.snapshotDepth,
                    requiredDepth
                )
                self.updateSnapshotDepthImpl(persistedDepth)
                await self.reloadInspectorImpl(
                    preserveState: true,
                    minimumDepth: persistedDepth
                )
            } catch is CancellationError {
                await self.session.cancelSelectionMode()
            } catch {
                domViewLogger.error("selection mode failed: \(error.localizedDescription, privacy: .public)")
                self.publishRecoverableError(error.localizedDescription)
            }
        }
    }

    func resetInteractionState() {
        cancelSelectionModeImpl()
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        clearDeleteUndoHistory()
    }

    func clearTreeState() {
        expandedEntryIDs.removeAll(keepingCapacity: false)
        loadingChildEntryIDs.removeAll(keepingCapacity: false)
        styleRefreshTask?.cancel()
        styleRefreshTask = nil
        styleRefreshInFlightKey = nil
        styleRefreshCompletedKey = nil
        cancelFrontendSelectionRecovery()
    }

    func enqueueDelete(nodeId: Int, undoManager: UndoManager?) {
        enqueueDeleteMutation { [weak self] in
            guard let self else { return }
            guard let undoManager else {
                await self.session.removeNode(nodeId: nodeId)
                self.onDeleteMutationForTesting?(.removed(nodeId: nodeId))
                return
            }
            self.rememberDeleteUndoManager(undoManager)
            guard let undoToken = await self.session.removeNodeWithUndo(nodeId: nodeId) else {
                await self.session.removeNode(nodeId: nodeId)
                self.onDeleteMutationForTesting?(.removed(nodeId: nodeId))
                return
            }
            self.registerUndoDelete(
                undoToken: undoToken,
                nodeId: nodeId,
                undoManager: undoManager
            )
            self.onDeleteMutationForTesting?(.removed(nodeId: nodeId))
        }
    }

    func enqueueDeleteMutation(_ operation: @escaping @MainActor () async -> Void) {
        let previousTask = pendingDeleteTask
        pendingDeleteGeneration &+= 1
        let generation = pendingDeleteGeneration
        pendingDeleteTask = Task { @MainActor [weak self] in
            if let previousTask {
                await previousTask.value
            }
            guard let self else { return }
            guard !Task.isCancelled else { return }
            defer {
                if self.pendingDeleteGeneration == generation {
                    self.pendingDeleteTask = nil
                }
            }
            await operation()
        }
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
            let restored = await self.session.undoRemoveNode(undoToken: undoToken)
            guard restored else {
                self.clearDeleteUndoHistory(using: undoManager)
                return
            }
            self.onDeleteMutationForTesting?(.restored(nodeId: nodeId))
            self.session.rememberPendingSelection(nodeId: nodeId)
            if self.requiresReloadAfterDeleteUndoRedo {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.reloadInspectorImpl(preserveState: true)
                }
            }
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
            let removed = await self.session.redoRemoveNode(undoToken: undoToken, nodeId: nodeId)
            guard removed else {
                self.clearDeleteUndoHistory(using: undoManager)
                return
            }
            self.onDeleteMutationForTesting?(.redone(nodeId: nodeId))
            if self.selectedEntry?.id.nodeID == nodeId {
                self.session.graphStore.select((nil as DOMEntryID?))
                self.session.rememberPendingSelection(nodeId: nil)
            }
            if self.requiresReloadAfterDeleteUndoRedo {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.reloadInspectorImpl(preserveState: true)
                }
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

    func buildTreeRows() -> [WIDOMTreeRow] {
        guard
            let rootID = session.graphStore.rootID,
            let rootEntry = session.graphStore.entry(for: rootID)
        else {
            return []
        }

        var rows: [WIDOMTreeRow] = []
        if rootEntry.nodeType == 9 {
            if needsChildFetch(for: rootEntry) {
                appendTreeRows(from: rootEntry, depth: 0, into: &rows)
            } else {
                for child in rootEntry.children {
                    appendTreeRows(from: child, depth: 0, into: &rows)
                }
            }
        } else {
            appendTreeRows(from: rootEntry, depth: 0, into: &rows)
        }
        return rows
    }

    var requiresReloadAfterDeleteUndoRedo: Bool {
        switch session.backendSupport.backendKind {
        case .legacy, .unsupported:
            true
        case .nativeInspectorIOS, .nativeInspectorMacOS, .privateCore, .privateFull:
            false
        }
    }

    func appendTreeRows(from entry: DOMEntry, depth: Int, into rows: inout [WIDOMTreeRow]) {
        let canExpand = entry.childCount > 0
        let isExpanded = expandedEntryIDs.contains(entry.id)
        rows.append(
            WIDOMTreeRow(
                id: entry.id,
                depth: depth,
                canExpand: canExpand,
                isExpanded: isExpanded,
                isLoadingChildren: loadingChildEntryIDs.contains(entry.id)
            )
        )

        guard isExpanded else {
            return
        }

        for child in entry.children {
            appendTreeRows(from: child, depth: depth + 1, into: &rows)
        }
    }

    func needsChildFetch(for entry: DOMEntry) -> Bool {
        guard entry.childCount > 0 else {
            return false
        }
        return entry.children.count < entry.childCount
    }

    func seedInitialExpansionStateIfNeeded() {
        guard expandedEntryIDs.isEmpty else {
            pruneTreeState()
            expandSelectedEntryAncestorsIfNeeded()
            return
        }
        seedInitialExpansionState(resetExisting: false)
    }

    func seedInitialExpansionState(resetExisting: Bool) {
        if resetExisting {
            expandedEntryIDs.removeAll(keepingCapacity: true)
        }

        guard
            let rootID = session.graphStore.rootID,
            let rootEntry = session.graphStore.entry(for: rootID)
        else {
            return
        }

        var nextExpanded = expandedEntryIDs
        bootstrapExpansionPath(from: rootEntry, depthRemaining: 3, into: &nextExpanded)
        if let selectedEntry = session.graphStore.selectedEntry {
            insertAncestorPath(of: selectedEntry, into: &nextExpanded)
        }
        expandedEntryIDs = nextExpanded
        pruneTreeState()
    }

    func bootstrapExpansionPath(
        from entry: DOMEntry,
        depthRemaining: Int,
        into expanded: inout Set<DOMEntryID>
    ) {
        guard depthRemaining > 0 else {
            return
        }

        if entry.childCount > 0 {
            expanded.insert(entry.id)
        }

        let preferredChildren = entry.children.filter { child in
            child.nodeType == 9 || child.nodeType == 1
        }

        if preferredChildren.count == 1, let onlyChild = preferredChildren.first {
            bootstrapExpansionPath(from: onlyChild, depthRemaining: depthRemaining - 1, into: &expanded)
            return
        }

        for child in preferredChildren.prefix(2) {
            bootstrapExpansionPath(from: child, depthRemaining: depthRemaining - 1, into: &expanded)
        }
    }

    func pruneTreeState() {
        let knownIDs = Set(session.graphStore.entriesByID.keys)
        expandedEntryIDs = expandedEntryIDs.intersection(knownIDs)
        loadingChildEntryIDs = loadingChildEntryIDs.intersection(knownIDs)
    }

    func expandSelectedEntryAncestorsIfNeeded() {
        guard let selectedEntry = session.graphStore.selectedEntry else {
            pruneTreeState()
            return
        }

        var nextExpanded = expandedEntryIDs
        insertAncestorPath(of: selectedEntry, into: &nextExpanded)
        expandedEntryIDs = nextExpanded
        pruneTreeState()
    }

    func insertAncestorPath(of entry: DOMEntry, into expanded: inout Set<DOMEntryID>) {
        var current: DOMEntry? = entry
        while let resolved = current {
            if resolved.childCount > 0 {
                expanded.insert(resolved.id)
            }
            current = resolved.parent
        }
    }

    func requestedDocumentDepth(
        preserveState: Bool,
        minimumDepth: Int? = nil
    ) -> Int {
        let baseDepth = preserveState
            ? session.configuration.fullReloadDepth
            : session.configuration.rootBootstrapDepth
        return max(baseDepth, minimumDepth ?? 0)
    }

    func syncFrontendTreeIfNeeded(preserveState: Bool, depth: Int? = nil) {
        guard frontendBridge?.hasFrontendWebView == true, session.graphStore.rootID != nil else {
            return
        }
        frontendBridge?.updateConfiguration(session.configuration)
        frontendBridge?.setPreferredDepth(session.configuration.rootBootstrapDepth)
        frontendBridge?.requestDocument(
            depth: depth ?? requestedDocumentDepth(preserveState: preserveState),
            preserveState: preserveState
        )
    }

    func recoverSelectionFromFrontendSnapshot(payload: DOMSelectionSnapshotPayload) {
        guard let nodeID = payload.nodeID, session.hasPageWebView else {
            return
        }

        let recoveryKey = FrontendSelectionRecoveryKey(
            nodeID: nodeID
        )
        if frontendSelectionRecoveryKey == recoveryKey {
            return
        }

        frontendSelectionRecoveryTask?.cancel()
        frontendSelectionRecoveryTask = nil
        frontendSelectionRecoveryKey = recoveryKey

        let minimumDepth = max(
            session.configuration.selectionRecoveryDepth,
            payload.path.count + 1
        )
        session.rememberPendingSelection(nodeId: nodeID)
        frontendSelectionRecoveryTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            await self.reloadInspectorImpl(
                preserveState: true,
                minimumDepth: minimumDepth
            )

            guard !Task.isCancelled, self.frontendSelectionRecoveryKey == recoveryKey else {
                return
            }
            defer {
                if self.frontendSelectionRecoveryKey == recoveryKey {
                    self.clearFrontendSelectionRecoveryState(clearPendingSelection: true)
                }
            }

            let didRestoreSelection = self.session.graphStore.mergeRecoveredSelectionSnapshot(payload)
            guard didRestoreSelection,
                  self.session.graphStore.selectedEntry?.id.nodeID == nodeID else {
                self.publishRecoverableError("Failed to resolve selected DOM node.")
                return
            }
        }
    }

    func cancelFrontendSelectionRecovery() {
        frontendSelectionRecoveryTask?.cancel()
        clearFrontendSelectionRecoveryState(clearPendingSelection: true)
    }

    func clearFrontendSelectionRecoveryState(clearPendingSelection: Bool) {
        frontendSelectionRecoveryTask = nil
        frontendSelectionRecoveryKey = nil
        if clearPendingSelection {
            session.rememberPendingSelection(nodeId: nil)
        }
    }

    func scheduleStyleRefreshIfNeeded(force: Bool) {
        guard let selectedEntry else {
            styleRefreshTask?.cancel()
            styleRefreshTask = nil
            styleRefreshInFlightKey = nil
            styleRefreshCompletedKey = nil
            return
        }

        let refreshKey = StyleRefreshKey(
            entryID: selectedEntry.id,
            nodeID: selectedEntry.id.nodeID,
            sourceRevision: selectedEntry.style.sourceRevision
        )

        if styleRefreshInFlightKey == refreshKey {
            return
        }
        if force == false,
           selectedEntry.style.loadState != .idle,
           styleRefreshCompletedKey == refreshKey,
           selectedEntry.style.needsRefresh == false {
            return
        }

        styleRefreshTask?.cancel()
        styleRefreshInFlightKey = refreshKey
        styleRefreshCompletedKey = nil
        session.graphStore.beginStyleLoading(for: selectedEntry.id.nodeID)
        styleRefreshTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                let payload = try await self.session.styles(
                    nodeId: refreshKey.nodeID,
                    maxMatchedRules: 0
                )
                guard !Task.isCancelled else {
                    if self.styleRefreshInFlightKey == refreshKey {
                        self.styleRefreshInFlightKey = nil
                    }
                    return
                }
                guard self.session.graphStore.selectedID == refreshKey.entryID else {
                    if self.styleRefreshInFlightKey == refreshKey {
                        self.styleRefreshInFlightKey = nil
                    }
                    return
                }
                self.styleRefreshCompletedKey = refreshKey
                if self.styleRefreshInFlightKey == refreshKey {
                    self.styleRefreshInFlightKey = nil
                }
                self.session.graphStore.applyStyle(payload, for: refreshKey.entryID.nodeID)
            } catch is CancellationError {
                if self.styleRefreshInFlightKey == refreshKey {
                    self.styleRefreshInFlightKey = nil
                }
                return
            } catch {
                guard !Task.isCancelled else {
                    if self.styleRefreshInFlightKey == refreshKey {
                        self.styleRefreshInFlightKey = nil
                    }
                    return
                }
                guard self.session.graphStore.selectedID == refreshKey.entryID else {
                    if self.styleRefreshInFlightKey == refreshKey {
                        self.styleRefreshInFlightKey = nil
                    }
                    return
                }
                self.styleRefreshCompletedKey = refreshKey
                if self.styleRefreshInFlightKey == refreshKey {
                    self.styleRefreshInFlightKey = nil
                }
                self.session.graphStore.failStyle(
                    for: refreshKey.entryID.nodeID,
                    message: error.localizedDescription
                )
                self.publishRecoverableError(error.localizedDescription)
            }
        }
    }

    func publishRecoverableError(_ message: String) {
        errorMessage = message
        recoverableErrorHandler?(message)
    }
}

private extension WIDOMStore {
    func prepareSelectionUIIfNeeded() {
        if let uiBridge {
            uiBridge.prepareForSelection(using: session)
            return
        }
#if canImport(UIKit)
        session.pageWebView?.scrollView.isScrollEnabled = false
        session.pageWebView?.scrollView.panGestureRecognizer.isEnabled = false
#elseif canImport(AppKit)
        if let pageWebView = session.pageWebView ?? session.lastPageWebView,
           let pageWindow = unsafe pageWebView.window {
            if NSApp.isActive == false {
                NSApp.activate(ignoringOtherApps: true)
            }
            pageWindow.makeKeyAndOrderFront(nil)
            if pageWindow.firstResponder !== pageWebView {
                pageWindow.makeFirstResponder(pageWebView)
            }
        }
#endif
    }

    func finishSelectionUIIfNeeded() {
        if let uiBridge {
            uiBridge.finishSelection(using: session)
            return
        }
#if canImport(UIKit)
        session.pageWebView?.scrollView.isScrollEnabled = true
        session.pageWebView?.scrollView.panGestureRecognizer.isEnabled = true
#endif
    }

    func copyTextToPasteboard(_ text: String) {
        if let uiBridge {
            uiBridge.copyToPasteboard(text)
            return
        }
#if canImport(UIKit)
        UIPasteboard.general.string = text
#elseif canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
#else
        _ = text
#endif
    }
}
