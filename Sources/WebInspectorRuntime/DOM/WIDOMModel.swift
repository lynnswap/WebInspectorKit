import OSLog
import Observation
import ObservationBridge
import WebKit
import WebInspectorEngine
import WebInspectorTransport

#if canImport(UIKit)
import UIKit
#endif

private let domViewLogger = Logger(subsystem: "WebInspectorKit", category: "WIDOMModel")
private let domDeleteUndoHistoryLimit = 128
private let domGraphObservationDebounce = ObservationDebounce(
    interval: .milliseconds(80),
    mode: .immediateFirst
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
public final class WIDOMModel {
    private struct MatchedStylesRefreshKey: Hashable {
        let entryID: DOMEntryID
        let nodeID: Int
        let styleRevision: Int
    }

    public let session: DOMSession

    public private(set) var errorMessage: String?
    public private(set) var isSelectingElement = false
    public private(set) var expandedEntryIDs: Set<DOMEntryID> = []
    public private(set) var loadingChildEntryIDs: Set<DOMEntryID> = []

    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var pendingDeleteTask: Task<Void, Never>?
    @ObservationIgnored private var pendingDeleteGeneration: UInt64 = 0
    @ObservationIgnored private weak var deleteUndoManager: UndoManager?
    @ObservationIgnored private var graphObservationHandles: Set<ObservationHandle> = []
    @ObservationIgnored private var matchedStylesRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var matchedStylesInFlightKey: MatchedStylesRefreshKey?
    @ObservationIgnored private var matchedStylesCompletedKey: MatchedStylesRefreshKey?
    @ObservationIgnored private var recoverableErrorHandler: (@MainActor (String) -> Void)?
    @ObservationIgnored private let frontendStore: DOMFrontendStore
#if canImport(UIKit)
    @ObservationIgnored private var scrollBackup: (isScrollEnabled: Bool, isPanEnabled: Bool)?
#endif

    package init(
        session: DOMSession,
        onRecoverableError: (@MainActor (String) -> Void)? = nil
    ) {
        self.session = session
        frontendStore = DOMFrontendStore(session: session)
        recoverableErrorHandler = onRecoverableError
        frontendStore.onRecoverableError = onRecoverableError
        startObservingGraphStore()
    }

    isolated deinit {
        selectionTask?.cancel()
        pendingDeleteTask?.cancel()
        matchedStylesRefreshTask?.cancel()
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

    public var transportSupportSnapshot: WITransportSupportSnapshot? {
        session.transportSupportSnapshot
    }

    public var treeRows: [WIDOMTreeRow] {
        buildTreeRows()
    }

    package func setRecoverableErrorHandler(_ handler: (@MainActor (String) -> Void)?) {
        recoverableErrorHandler = handler
        frontendStore.onRecoverableError = handler
    }

    package func makeInspectorWebView() -> WKWebView {
        let inspectorWebView = frontendStore.makeInspectorWebView()
        if session.hasPageWebView {
            syncFrontendTreeIfNeeded(preserveState: session.graphStore.rootID != nil)
        }
        return inspectorWebView
    }

    func withFrontendStore(_ body: (DOMFrontendStore) -> Void) {
        body(frontendStore)
    }

    package func entry(for id: DOMEntryID) -> DOMEntry? {
        session.graphStore.entry(for: id)
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
        session.graphStore.select(id)
        if let entryID = id,
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

    func attach(to webView: WKWebView) {
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

    func suspend() {
        resetInteractionState()
        session.suspend()
    }

    func detach() {
        resetInteractionState()
        session.detach()
        frontendStore.detachInspectorWebView()
        clearTreeState()
        errorMessage = nil
    }

    func setAutoSnapshotEnabled(_ enabled: Bool) {
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

    public func reloadInspector(preserveState: Bool = false) async {
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

private extension WIDOMModel {
    func startObservingGraphStore() {
        let graphStore = session.graphStore

        graphStore.observe(
            \.selectedID,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleMatchedStylesRefreshIfNeeded(force: true)
        }
        .store(in: &graphObservationHandles)

        graphStore.observe(
            \.entriesByID,
            options: [.debounce(domGraphObservationDebounce)]
        ) { [weak self] _ in
            self?.pruneTreeState()
            self?.scheduleMatchedStylesRefreshIfNeeded(force: false)
        }
        .store(in: &graphObservationHandles)

        graphStore.observe(
            \.rootID,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.pruneTreeState()
            self?.seedInitialExpansionStateIfNeeded()
        }
        .store(in: &graphObservationHandles)
    }

    func reloadInspectorImpl(preserveState: Bool) async {
        await reloadInspectorImpl(preserveState: preserveState, minimumDepth: nil)
    }

    func updateSnapshotDepthImpl(_ depth: Int) {
        let clamped = max(1, depth)
        var configuration = session.configuration
        configuration.snapshotDepth = clamped
        session.updateConfiguration(configuration)
        frontendStore.updateConfiguration(configuration)
        frontendStore.setPreferredDepth(clamped)
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
            scheduleMatchedStylesRefreshIfNeeded(force: true)
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
#if canImport(UIKit)
        restorePageScrollingState()
#endif
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
        guard let nodeId = selectedEntry?.id.nodeID else { return }
        session.graphStore.updateSelectedAttribute(name: name, value: value)
        session.graphStore.invalidateMatchedStyles(for: nil)
        scheduleMatchedStylesRefreshIfNeeded(force: true)
        Task {
            await session.setAttribute(nodeId: nodeId, name: name, value: value)
        }
    }

    func removeAttributeImpl(name: String) {
        guard let nodeId = selectedEntry?.id.nodeID else { return }
        session.graphStore.removeSelectedAttribute(name: name)
        session.graphStore.invalidateMatchedStyles(for: nil)
        scheduleMatchedStylesRefreshIfNeeded(force: true)
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
#if canImport(UIKit)
        restorePageScrollingState()
#endif
    }

    func clearTreeState() {
        expandedEntryIDs.removeAll(keepingCapacity: false)
        loadingChildEntryIDs.removeAll(keepingCapacity: false)
        matchedStylesRefreshTask?.cancel()
        matchedStylesRefreshTask = nil
        matchedStylesInFlightKey = nil
        matchedStylesCompletedKey = nil
    }

    func enqueueDelete(nodeId: Int, undoManager: UndoManager?) {
        enqueueDeleteMutation { [weak self] in
            guard let self else { return }
            guard let undoManager else {
                await self.session.removeNode(nodeId: nodeId)
                return
            }
            self.rememberDeleteUndoManager(undoManager)
            guard let undoToken = await self.session.removeNodeWithUndo(nodeId: nodeId) else {
                await self.session.removeNode(nodeId: nodeId)
                return
            }
            self.registerUndoDelete(
                undoToken: undoToken,
                nodeId: nodeId,
                undoManager: undoManager
            )
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            let restored = await self.session.undoRemoveNode(undoToken: undoToken)
            guard restored else {
                self.clearDeleteUndoHistory(using: undoManager)
                return
            }
            self.session.rememberPendingSelection(nodeId: nodeId)
            if self.session.transportSupportSnapshot?.isSupported == false {
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
            if self.selectedEntry?.id.nodeID == nodeId {
                self.session.graphStore.select((nil as DOMEntryID?))
                self.session.rememberPendingSelection(nodeId: nil)
            }
            if self.session.transportSupportSnapshot?.isSupported == false {
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
        guard frontendStore.hasInspectorWebView else {
            return
        }
        frontendStore.updateConfiguration(session.configuration)
        frontendStore.setPreferredDepth(session.configuration.rootBootstrapDepth)
        frontendStore.requestDocument(
            depth: depth ?? requestedDocumentDepth(preserveState: preserveState),
            preserveState: preserveState
        )
    }

    func scheduleMatchedStylesRefreshIfNeeded(force: Bool) {
        guard let selectedEntry else {
            matchedStylesRefreshTask?.cancel()
            matchedStylesRefreshTask = nil
            matchedStylesInFlightKey = nil
            matchedStylesCompletedKey = nil
            return
        }

        let refreshKey = MatchedStylesRefreshKey(
            entryID: selectedEntry.id,
            nodeID: selectedEntry.id.nodeID,
            styleRevision: selectedEntry.styleRevision
        )

        if matchedStylesInFlightKey == refreshKey {
            return
        }
        if matchedStylesCompletedKey == refreshKey,
           force == false,
           selectedEntry.needsMatchedStylesRefresh == false {
            return
        }

        matchedStylesRefreshTask?.cancel()
        matchedStylesInFlightKey = refreshKey
        matchedStylesCompletedKey = nil
        session.graphStore.beginMatchedStylesLoading(for: selectedEntry.id.nodeID)
        matchedStylesRefreshTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                let payload = try await self.session.matchedStyles(nodeId: refreshKey.nodeID, maxRules: 0)
                guard !Task.isCancelled else {
                    if self.matchedStylesInFlightKey == refreshKey {
                        self.matchedStylesInFlightKey = nil
                    }
                    return
                }
                guard self.session.graphStore.selectedID == refreshKey.entryID else {
                    if self.matchedStylesInFlightKey == refreshKey {
                        self.matchedStylesInFlightKey = nil
                    }
                    return
                }
                self.matchedStylesCompletedKey = refreshKey
                if self.matchedStylesInFlightKey == refreshKey {
                    self.matchedStylesInFlightKey = nil
                }
                self.session.graphStore.applyMatchedStyles(payload, for: refreshKey.entryID.nodeID)
            } catch is CancellationError {
                if self.matchedStylesInFlightKey == refreshKey {
                    self.matchedStylesInFlightKey = nil
                }
                return
            } catch {
                guard !Task.isCancelled else {
                    if self.matchedStylesInFlightKey == refreshKey {
                        self.matchedStylesInFlightKey = nil
                    }
                    return
                }
                guard self.session.graphStore.selectedID == refreshKey.entryID else {
                    if self.matchedStylesInFlightKey == refreshKey {
                        self.matchedStylesInFlightKey = nil
                    }
                    return
                }
                self.matchedStylesCompletedKey = refreshKey
                if self.matchedStylesInFlightKey == refreshKey {
                    self.matchedStylesInFlightKey = nil
                }
                self.session.graphStore.clearMatchedStyles(for: refreshKey.entryID.nodeID)
                self.publishRecoverableError(error.localizedDescription)
            }
        }
    }

    func publishRecoverableError(_ message: String) {
        errorMessage = message
        recoverableErrorHandler?(message)
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
