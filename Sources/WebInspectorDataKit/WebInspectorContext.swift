import Foundation
import WebInspectorProxyKit

/// The identity-preserving model context for an inspected page.
///
/// A context owns observable DOM, Network, Console, Runtime, and CSS models.
/// It is bound to the main actor, like the models it vends.
@MainActor
public final class WebInspectorContext {
    @MainActor
    package struct DOMUndoRedoCommands {
        private weak var context: WebInspectorContext?
        private let target: WebInspectorTarget?
        private let documentGeneration: Int

        fileprivate init(context: WebInspectorContext, target: WebInspectorTarget?, documentGeneration: Int) {
            self.context = context
            self.target = target
            self.documentGeneration = documentGeneration
        }

        package func undo() async throws {
            try await undoRedoTarget().dom.undo()
        }

        package func redo() async throws {
            try await undoRedoTarget().dom.redo()
        }

        private func undoRedoTarget() throws -> WebInspectorTarget {
            guard let context else {
                throw WebInspectorProxyError.disconnected("WebInspectorDataKit context was released before DOM undo/redo.")
            }
            guard context.domDocumentGeneration == documentGeneration else {
                throw WebInspectorProxyError.disconnected("DOM undo/redo target is no longer current.")
            }
            if let target {
                return target
            }
            if let target = context.domEditHistoryTarget {
                return target
            }
            guard context.didInvalidateDOMEditHistoryTarget == false else {
                throw WebInspectorProxyError.disconnected("DOM undo/redo target is no longer current.")
            }
            return try context.currentPageOrThrow()
        }
    }

    package struct DOMDeletionPartialFailure: Error {
        package let deletedNodeCount: Int
        package let underlyingError: any Error

        package init(deletedNodeCount: Int, underlyingError: any Error) {
            self.deletedNodeCount = deletedNodeCount
            self.underlyingError = underlyingError
        }
    }

    private struct SupersededPageGeneration: Error {}

    private struct CSSMutationAuthority {
        struct StyleSheet {
            var id: CSS.StyleSheet.ID
            var revision: UInt64
            var contentRevision: UInt64?
        }

        var pageGeneration: Int
        var documentGeneration: Int
        var targetID: WebInspectorTarget.ID
        var targetRevision: UInt64
        var isCurrentPage: Bool
        var pageBindingID: String?
        var node: DOMNode?
        var styles: CSSStyles?
        var styleSheet: StyleSheet?
    }

    @MainActor
    private enum CSSStyleTextMutation {
        case setProperty(enabled: Bool)
        case setDeclarationText(String)

        func submittedDeclaration(
            in styles: CSSStyles,
            propertyID: CSSStyleProperty.ID
        ) -> CSSDeclarationIdentity? {
            switch self {
            case let .setProperty(enabled):
                styles.canSubmitSetStyleText(for: propertyID, enabled: enabled)
            case let .setDeclarationText(text):
                styles.canSubmitSetDeclarationText(for: propertyID, text: text)
            }
        }

        func intent(
            in styles: CSSStyles,
            declaration: CSSDeclarationIdentity
        ) -> CSSStyles.SetStyleTextIntent? {
            switch self {
            case let .setProperty(enabled):
                styles.setStyleTextIntent(for: declaration, enabled: enabled)
            case let .setDeclarationText(text):
                styles.setDeclarationTextIntent(for: declaration, text: text)
            }
        }
    }

    @MainActor
    private final class StyleToggleOperation {
        var task: Task<Void, Never>?

        init(task: Task<Void, Never>? = nil) {
            self.task = task
        }
    }

    @MainActor
    private final class WeakContextReference {
        private weak var context: WebInspectorContext?

        init(_ context: WebInspectorContext) {
            self.context = context
        }

        func withContext<Output>(
            _ operation: (WebInspectorContext) throws -> Output
        ) throws -> Output {
            guard let context else {
                throw CancellationError()
            }
            return try operation(context)
        }

        func withContextIfPresent(_ operation: (WebInspectorContext) -> Void) {
            guard let context else {
                return
            }
            operation(context)
        }
    }

    private struct LoadedDOMDocument {
        var node: DOM.Node
        var generation: Int
        var loadID: UInt64
        var bootstrapID: UInt64
    }

    private struct DOMBootstrap {
        var id: UInt64
        var events: [DOM.Event]
    }

    private struct DOMDocumentLoad {
        var id: UInt64
        var bootstrap: DOMBootstrap?
    }

    private struct OrderedEventWaiter {
        var sequence: UInt64
        var continuation: CheckedContinuation<Bool, Never>
    }

    /// A `DOM.setInspectModeEnabled` command that is waiting for its reply.
    private struct ElementPickerCommand {
        /// The picker document epoch the command was sent in.
        var documentEpoch: UInt64
        /// `Inspector.inspect` arrived before the reply and already ended
        /// the picker session this command belongs to.
        var wasEndedByInspect = false
    }

    private enum ElementPickerCommandOutcome {
        /// The reply was applied, or `Inspector.inspect` had already ended
        /// the picker session.
        case settled
        /// The command's document was replaced before the reply.
        /// `cleanupError` is the failure to turn inspect mode back off.
        case replacedDocument(cleanupError: (any Error)?)
        case failed(isEnabled: Bool, error: any Error)
    }

    private struct PageHighlightState {
        enum Phase {
            case sending(Task<Void, any Error>)
            case applied
        }

        let operationID: UInt64
        let pageGeneration: Int
        let documentGeneration: Int
        let nodeID: DOMNode.ID
        var phase: Phase
    }

#if DEBUG
    private struct EventPumpAppliedWaiterForTesting {
        var minimumSequence: UInt64
        var continuation: CheckedContinuation<Bool, Never>
    }
#endif

    /// The attachment state of a context.
    public enum State: Equatable, Sendable {
        /// The context is enabling domains and loading initial state.
        case attaching

        /// The context is attached and has started observing the page.
        case attached

        /// The context has been detached.
        case detached

        /// The context failed with an inspector error.
        case failed(WebInspectorProxyError)
    }

    /// A compact status value suitable for UI binding.
    public struct Status: Equatable, Sendable {
        /// The current attachment state.
        public let state: State

        /// The currently selected DOM node identity.
        public let selectedNodeID: DOMNode.ID?

        /// A Boolean value indicating whether WebKit inspect mode is enabled.
        public let isElementPickerEnabled: Bool
    }

    private(set) weak var container: WebInspectorContainer?
    private let proxy: WebInspectorProxy
    private let domainEnablement: WebInspectorDomainEnablementRegistry
    /// The current attachment state.
    public private(set) var state: State {
        didSet {
            #if DEBUG
            stateChangesForTesting.yield(())
            #endif
        }
    }

    /// The terminal teardown error, if the context failed or detached because
    /// of an inspector error.
    public private(set) var teardownError: WebInspectorProxyError? {
        didSet {
            #if DEBUG
            stateChangesForTesting.yield(())
            #endif
        }
    }

    private(set) var networkResourceTreeError: WebInspectorProxyError? {
        didSet {
            #if DEBUG
            stateChangesForTesting.yield(())
            #endif
        }
    }

    /// The current root DOM node, if a document is loaded.
    public private(set) var rootNode: DOMNode? {
        didSet {
            #if DEBUG
            stateChangesForTesting.yield(())
            #endif
        }
    }

    /// The currently selected DOM node.
    public private(set) var selectedNode: DOMNode? {
        didSet {
            #if DEBUG
            stateChangesForTesting.yield(())
            #endif
        }
    }

    /// A Boolean value indicating whether WebKit inspect mode is enabled.
    public private(set) var isElementPickerEnabled: Bool {
        didSet {
            #if DEBUG
            stateChangesForTesting.yield(())
            #endif
        }
    }

    var executionContexts: [RuntimeContext] {
        runtimeStore.executionContexts
    }

    var selectedContext: RuntimeContext? {
        runtimeStore.selectedContext
    }

    private var currentPage: WebInspectorTarget?
    private var currentPageGeneration: Int
    private var domDocumentGeneration: Int
    private var startupTask: Task<Void, Never>?
    private var currentPageRetargetTask: Task<Void, Never>?
    private var currentPageCleanupTask: Task<Void, Never>?
    private var domEditHistoryTarget: WebInspectorTarget?
    private var didInvalidateDOMEditHistoryTarget: Bool
    private var documentReloadTask: Task<Void, Never>?
    private var inspectorInspectResolutionTask: Task<Void, Never>?
    private var inspectResolutionTask: Task<Void, Never>?
    private var pageHighlightMaintenanceTask: Task<Void, Never>?
    /// The picker state the latest caller asked for, until it is applied.
    private var requestedElementPickerEnabled: Bool? {
        didSet {
            #if DEBUG
            stateChangesForTesting.yield(())
            #endif
        }
    }
    private var elementPickerCommandTask: Task<ElementPickerCommandOutcome, Never>?
    private var elementPickerCommand: ElementPickerCommand?
    /// Advances when the document the picker belongs to is replaced.
    private var elementPickerDocumentEpoch: UInt64
    private var frameDocumentLoadTasks: [WebInspectorTarget.ID: Task<Void, Never>]
    private var styleRefreshTask: Task<Void, Never>?
    private var styleRefreshGeneration: Int
    private var isStyleHydrationActive: Bool
    private var styleToggleOperations: [CSSStyleProperty.ID: StyleToggleOperation]
    let cssInspectorBaselineStore: CSSInspectorBaselineStore
    private let cssOperationGate: CSSOperationGate
    private var cssStyleSheets: CSSStyleSheetLifetimes
    private let styleTrackingLeases: CSSStyleTrackingLeases
    private var eventPumps: [WebInspectorEventPump]
    private var orderedEventSubscriptionGeneration: UInt64
    private var lastOrderedEventSequence: UInt64
    private var orderedEventWaiters: [OrderedEventWaiter]
    private var domDocumentLoad: DOMDocumentLoad?
    private var nextDOMDocumentLoadID: UInt64
    private var nextDOMBootstrapID: UInt64
#if DEBUG
    private var eventPumpAppliedSequenceForTestingStorage: UInt64
    private var eventPumpAppliedWaitersForTesting: [UInt64: EventPumpAppliedWaiterForTesting]
    private var nextEventPumpAppliedWaiterIDForTesting: UInt64
#endif
    /// The target each current-page domain lease was acquired on. CSS leases
    /// are tracked per style target in `styleTrackingLeases`.
    private var domainTrackingTargets: [WebInspectorEnabledDomain: WebInspectorTarget]
    private var nodesByID: [DOMNode.ID: DOMNode] {
        didSet {
            #if DEBUG
            stateChangesForTesting.yield(())
            #endif
        }
    }
    private var frameDocumentProjectionIndex: FrameDocumentProjectionIndex
    private var treeStates: [WeakDOMTreeState]
    private let statusRelay: WebInspectorAsyncStreamRelay<Status>
    private let networkRecorder: NetworkEventRecorder
    private var networkRequestStore: NetworkRequestStore {
        networkRecorder.requestStore
    }
    private let runtimeStore: RuntimeModelStore
    private let consoleStore: ConsoleMessageStore
    private var targetRevisionsByID: [WebInspectorTarget.ID: UInt64]
    private var pendingInspectedNodeID: DOMNode.ID?
    private var pageHighlightState: PageHighlightState?
    private var nextPageHighlightOperationID: UInt64

    /// Creates a context for a container.
    public init(_ container: WebInspectorContainer) {
        self.container = container
        proxy = container.proxy
        domainEnablement = container.domainEnablement
        state = .attaching
        teardownError = nil
        rootNode = nil
        selectedNode = nil
        domEditHistoryTarget = nil
        didInvalidateDOMEditHistoryTarget = false
        isElementPickerEnabled = false
        currentPage = nil
        currentPageGeneration = 0
        domDocumentGeneration = 0
        startupTask = nil
        currentPageRetargetTask = nil
        currentPageCleanupTask = nil
        domEditHistoryTarget = nil
        documentReloadTask = nil
        inspectorInspectResolutionTask = nil
        inspectResolutionTask = nil
        pageHighlightMaintenanceTask = nil
        requestedElementPickerEnabled = nil
        elementPickerCommandTask = nil
        elementPickerCommand = nil
        elementPickerDocumentEpoch = 0
        frameDocumentLoadTasks = [:]
        styleRefreshTask = nil
        styleRefreshGeneration = 0
        isStyleHydrationActive = false
        styleToggleOperations = [:]
        cssInspectorBaselineStore = CSSInspectorBaselineStore()
        cssOperationGate = CSSOperationGate()
        cssStyleSheets = CSSStyleSheetLifetimes()
        styleTrackingLeases = CSSStyleTrackingLeases(domainEnablement: container.domainEnablement)
        eventPumps = []
        orderedEventSubscriptionGeneration = 0
        lastOrderedEventSequence = 0
        orderedEventWaiters = []
        domDocumentLoad = nil
        nextDOMDocumentLoadID = 0
        nextDOMBootstrapID = 0
#if DEBUG
        eventPumpAppliedSequenceForTestingStorage = 0
        eventPumpAppliedWaitersForTesting = [:]
        nextEventPumpAppliedWaiterIDForTesting = 0
#endif
        domainTrackingTargets = [:]
        nodesByID = [:]
        frameDocumentProjectionIndex = FrameDocumentProjectionIndex()
        treeStates = []
        statusRelay = WebInspectorAsyncStreamRelay()
        networkRecorder = NetworkEventRecorder()
        let runtimeStore = RuntimeModelStore()
        self.runtimeStore = runtimeStore
        consoleStore = ConsoleMessageStore(runtime: runtimeStore)
        targetRevisionsByID = [:]
        pendingInspectedNodeID = nil
        pageHighlightState = nil
        nextPageHighlightOperationID = 0
        #if DEBUG
        runtimeStore.stateDidChangeForTesting = { [stateChangesForTesting] in
            stateChangesForTesting.yield(())
        }
        #endif
        WebInspectorDataKitLog.debug("context state=\(state.logDescription)")
    }

    package static func preview() -> WebInspectorContext {
        let container = WebInspectorContainer(proxy: WebInspectorProxy())
        let context = WebInspectorContext(container)
        context.state = .attached
        return context
    }

    package static func detached() -> WebInspectorContext {
        let container = WebInspectorContainer(proxy: WebInspectorProxy())
        let context = WebInspectorContext(container)
        context.state = .detached
        return context
    }

    isolated deinit {
        startupTask?.cancel()
        currentPageRetargetTask?.cancel()
        currentPageCleanupTask?.cancel()
        documentReloadTask?.cancel()
        inspectorInspectResolutionTask?.cancel()
        inspectResolutionTask?.cancel()
        pageHighlightMaintenanceTask?.cancel()
        cancelFrameDocumentLoadTasks()
        styleRefreshTask?.cancel()
        styleTrackingLeases.cancelPendingAcquisitions()
        for operation in styleToggleOperations.values {
            operation.task?.cancel()
            operation.task = nil
        }
        stopEventPumps()
        resolveEventPumpAppliedWaitersForTesting(result: false)
    }

    /// Starts observing the inspected page and rebuilding DataKit models.
    public func start() {
        let previousStartupTask = startupTask
        let previousCurrentPageCleanupTask = currentPageCleanupTask
        previousStartupTask?.cancel()
        stopEventPumps()
        currentPageRetargetTask?.cancel()
        currentPageRetargetTask = nil
        documentReloadTask?.cancel()
        documentReloadTask = nil
        cancelDOMDocumentLoad()
        inspectorInspectResolutionTask?.cancel()
        inspectorInspectResolutionTask = nil
        invalidateElementPicker()
        isElementPickerEnabled = false
        state = .attaching
        notifyStatusChanged()
        teardownError = nil
        networkRecorder.beginAttachment()
        let generation = currentPageGeneration
        let documentLoadID = beginDOMDocumentLoad()
        startupTask = Task { [weak self, previousStartupTask, previousCurrentPageCleanupTask, generation] in
            await previousStartupTask?.value
            await previousCurrentPageCleanupTask?.value
            guard Task.isCancelled == false else {
                return
            }
            guard let self else {
                return
            }
            await self.startup(
                generation: generation,
                documentLoadID: documentLoadID
            )
        }
    }

    #if DEBUG
    private let stateChangesForTesting = WebInspectorAsyncStreamRelay<Void>()

    package func stateChangeStreamForTesting() -> AsyncStream<Void> {
        stateChangesForTesting.makeStream()
    }
    #endif

    package var status: Status {
        Status(
            state: state,
            selectedNodeID: selectedNode?.id,
            isElementPickerEnabled: isElementPickerEnabled
        )
    }

    package var statusUpdates: AsyncStream<Status> {
        statusRelay.makeStream(initialElement: status)
    }

    /// Returns the registered DOM node for an identifier.
    public func node(for id: DOMNode.ID) -> DOMNode? {
        return nodesByID[id]
    }

    package func requiredNode(for id: DOMNode.ID) throws -> DOMNode {
        guard let node = nodesByID[id] else {
            throw WebInspectorProxyError.disconnected("DOMNode is not registered in this WebInspectorContext.")
        }
        return node
    }

    func registeredRequest(
        for id: NetworkRequest.ID
    ) -> NetworkRequest? {
        return networkRequestStore.registration(for: id)?.request
    }

    package func registeredRequest(
        forProxyID id: Network.Request.ID
    ) -> NetworkRequest? {
        return networkRequestStore.registration(forProxyID: id)?.request
    }

#if DEBUG
    package func domTreeRegistrationCountForTesting() -> Int {
        pruneReleasedTreeStates()
        return treeStates.count
    }
#endif

    func clearNetworkRequests() {
        networkRecorder.clearRequests()
    }

    func registeredMessage(
        for id: ConsoleMessage.ID
    ) -> ConsoleMessage? {
        return consoleStore.message(for: id)
    }

    /// Selects a DOM node and reveals it in registered tree controllers.
    ///
    /// Passing `nil` clears the selection. Passing a node that is no longer
    /// registered in this context, including a node from another context, does
    /// nothing and preserves the current selection.
    public func select(_ node: DOMNode?) {
        select(node, reveal: .selectAndScroll)
    }

    private func select(
        _ node: DOMNode?,
        reveal: DOMRevealPolicy
    ) {
        if let node, nodesByID[node.id] !== node {
            return
        }
        pendingInspectedNodeID = nil
        inspectorInspectResolutionTask?.cancel()
        inspectorInspectResolutionTask = nil
        inspectResolutionTask?.cancel()
        inspectResolutionTask = nil
        pageHighlightMaintenanceTask?.cancel()
        pageHighlightMaintenanceTask = nil
        selectedNode = node
        notifyDOMTreeSelectionChanged(node, reveal: reveal)
        notifyStatusChanged()
        refreshSelectedStyles()
    }

    package func selectNode(_ id: DOMNode.ID) throws {
        select(try requiredNode(for: id))
    }

    package func selectNode(
        _ id: DOMNode.ID?,
        reveal: DOMRevealPolicy
    ) throws {
        guard let id else {
            select(nil, reveal: reveal)
            return
        }
        select(try requiredNode(for: id), reveal: reveal)
    }

    package func requestChildren(
        for id: DOMNode.ID,
        depth: Int = 1
    ) async throws {
        try await requiredNode(for: id).requestChildren(depth: depth)
    }

    package func setDOMAttribute(
        _ name: String,
        value: String,
        on id: DOMNode.ID,
        options: WebInspectorMutationOptions
    ) async throws {
        let node = try requiredNode(for: id)
        let target = try domTarget(owning: node.id.proxyID)
        try await target.dom.setAttributeValue(node.id.proxyID, name: name, value: value)
        recordDOMEditHistoryTarget(target, options: options)
        try await Self.markDOMUndoableStateIfNeeded(on: target, options: options)
    }

    package func setDOMOuterHTML(
        _ html: String,
        of id: DOMNode.ID,
        options: WebInspectorMutationOptions
    ) async throws {
        let node = try requiredNode(for: id)
        let target = try domTarget(owning: node.id.proxyID)
        try await target.dom.setOuterHTML(node.id.proxyID, html: html)
        recordDOMEditHistoryTarget(target, options: options)
        try await Self.markDOMUndoableStateIfNeeded(on: target, options: options)
    }

    package func removeDOMNodes(
        _ nodeIDs: [DOMNode.ID],
        options: WebInspectorMutationOptions
    ) async throws -> DOMMutationResult {
        var seenNodeIDs: Set<DOMNode.ID> = []
        let uniqueNodes = try nodeIDs
            .map { try requiredNode(for: $0) }
            .filter { seenNodeIDs.insert($0.id).inserted }
        let snapshot = try currentDOMTreeSnapshot(containing: uniqueNodes)
        let sortedNodes = uniqueNodes.sorted {
            snapshot.ancestorNodeIDs(of: $0.id).count > snapshot.ancestorNodeIDs(of: $1.id).count
        }
        let deletionTargets = try validatedDeletionTargets(for: sortedNodes)
        var acceptedNodeIDs: [DOMNode.ID] = []
        for (node, target) in zip(sortedNodes, deletionTargets) {
            do {
                try await target.dom.removeNode(node.id.proxyID)
                recordDOMEditHistoryTarget(target, options: options)
                try await Self.markDOMUndoableStateIfNeeded(on: target, options: options)
                acceptedNodeIDs.append(node.id)
            } catch {
                if acceptedNodeIDs.isEmpty == false {
                    clearSelectionIfDeleted(acceptedNodeIDs, snapshot: snapshot)
                    throw DOMDeletionPartialFailure(
                        deletedNodeCount: acceptedNodeIDs.count,
                        underlyingError: error
                    )
                }
                throw error
            }
        }
        clearSelectionIfDeleted(acceptedNodeIDs, snapshot: snapshot)
        return DOMMutationResult(requestedNodeIDs: nodeIDs, acceptedNodeIDs: acceptedNodeIDs)
    }

    /// Returns copied text for a DOM node in the requested format.
    public func copyText(
        _ kind: DOMNode.CopyTextKind,
        for node: DOMNode
    ) async throws -> String {
        try registeredNode(node)
        switch kind {
        case .html:
            let page = try currentPageOrThrow()
            return try await page.dom.outerHTML(of: node.id.proxyID)
        case .selectorPath:
            return try currentDOMTreeSnapshot(containing: [node]).selectorPath(for: node.id)
        case .xPath:
            return try currentDOMTreeSnapshot(containing: [node]).xPath(for: node.id)
        }
    }

    package func copyText(
        _ kind: DOMNode.CopyTextKind,
        for id: DOMNode.ID
    ) async throws -> String {
        try await copyText(kind, for: try requiredNode(for: id))
    }

    /// Removes one DOM node from the inspected document.
    public func delete(_ node: DOMNode) async throws {
        try await delete([node])
    }

    /// Removes DOM nodes from the inspected document.
    public func delete(_ nodes: [DOMNode]) async throws {
        _ = try await deleteCountingRemovedNodes(nodes)
    }

    @discardableResult
    private func deleteCountingRemovedNodes(
        _ nodes: [DOMNode]
    ) async throws -> Int {
        var seenNodeIDs: Set<DOMNode.ID> = []
        let uniqueNodes = try nodes
            .map { try registeredNode($0) }
            .filter { seenNodeIDs.insert($0.id).inserted }
        let snapshot = try currentDOMTreeSnapshot(containing: uniqueNodes)
        let sortedNodes = uniqueNodes
            .sorted {
                snapshot.ancestorNodeIDs(of: $0.id).count > snapshot.ancestorNodeIDs(of: $1.id).count
            }
        let deletionTargets = try validatedDeletionTargets(for: sortedNodes)
        var removedNodes: [DOMNode] = []
        for (node, target) in zip(sortedNodes, deletionTargets) {
            do {
                try await target.dom.removeNode(node.id.proxyID)
                recordDOMEditHistoryTarget(target, options: .init())
                try await target.dom.markUndoableState()
                removedNodes.append(node)
            } catch {
                if removedNodes.isEmpty == false {
                    clearSelectionIfDeleted(removedNodes.map(\.id), snapshot: snapshot)
                    throw DOMDeletionPartialFailure(
                        deletedNodeCount: removedNodes.count,
                        underlyingError: error
                    )
                }
                throw error
            }
        }
        clearSelectionIfDeleted(removedNodes.map(\.id), snapshot: snapshot)
        return removedNodes.count
    }

    package func delete(nodeIDs: [DOMNode.ID]) async throws {
        _ = try await deleteCountingRemovedNodes(nodeIDs: nodeIDs)
    }

    @discardableResult
    package func deleteCountingRemovedNodes(
        nodeIDs: [DOMNode.ID]
    ) async throws -> Int {
        var seenNodeIDs: Set<DOMNode.ID> = []
        let nodes = try nodeIDs
            .filter { seenNodeIDs.insert($0).inserted }
            .map { try requiredNode(for: $0) }
        return try await deleteCountingRemovedNodes(nodes)
    }

    #if DEBUG
    package var inspectionProxyForTesting: WebInspectorProxy {
        proxy
    }

    package var currentPageForTesting: WebInspectorTarget? {
        currentPage
    }

    package func currentPageRetargetTaskForTesting() -> Task<Void, Never>? {
        return currentPageRetargetTask
    }

    package func startupTaskForTesting() -> Task<Void, Never>? {
        return startupTask
    }

    package var eventPumpAppliedSequenceForTesting: UInt64 {
        eventPumpAppliedSequenceForTestingStorage
    }

    package var orderedEventSubscriptionStateForTesting: (generation: UInt64, sequence: UInt64) {
        (orderedEventSubscriptionGeneration, lastOrderedEventSequence)
    }

    package func applyOrderedEventForTesting(
        _ event: WebInspectorProxyOrderedEvent,
        target: WebInspectorTarget,
        subscriptionGeneration: UInt64,
        beforeWatermarkUpdate: (@Sendable () async -> Void)? = nil
    ) async {
        await applyOrderedEvent(
            event,
            target: target,
            subscriptionGeneration: subscriptionGeneration,
            beforeWatermarkUpdate: beforeWatermarkUpdate
        )
    }

    package func handleOrderedEventStreamFailureForTesting(
        _ error: any Error,
        subscriptionGeneration: UInt64
    ) {
        handleOrderedEventStreamFailure(
            error,
            subscriptionGeneration: subscriptionGeneration
        )
    }

    package func waitForOrderedEventsForTesting(
        through sequence: UInt64,
        registration: ReplyPromise<Void>
    ) async -> Bool {
        await waitForOrderedEvents(
            through: sequence,
            waiterRegistered: {
                registration.fulfill(.success(()))
            }
        )
    }

    package func subscribeForTesting(
        to target: WebInspectorTarget,
        beforeValidation: @escaping @Sendable () async -> Void
    ) async {
        await subscribe(
            to: target,
            beforeValidation: beforeValidation
        )
    }

    package var requestedElementPickerEnabledForTesting: Bool? {
        requestedElementPickerEnabled
    }

    package func waitForEventPumpAppliedSequenceForTesting(
        after baselineSequence: UInt64,
        count: UInt64 = 1
    ) async -> Bool {
        let minimumSequence = baselineSequence + count
        if eventPumpAppliedSequenceForTestingStorage >= minimumSequence {
            return true
        }

        return await withCheckedContinuation { continuation in
            let waiterID = nextEventPumpAppliedWaiterIDForTesting
            nextEventPumpAppliedWaiterIDForTesting &+= 1
            eventPumpAppliedWaitersForTesting[waiterID] = EventPumpAppliedWaiterForTesting(
                minimumSequence: minimumSequence,
                continuation: continuation
            )
            if eventPumpAppliedSequenceForTestingStorage >= minimumSequence {
                resolveEventPumpAppliedWaiterForTesting(id: waiterID, result: true)
            }
        }
    }
    #endif

    /// Highlights a DOM node in the inspected page.
    public func highlight(_ node: DOMNode) async throws {
        try registeredNode(node)
        let page = try currentPageOrThrow()
        guard node.id.proxyID.targetScopeRawValue == nil else {
            try await page.dom.highlightNode(node.id.proxyID)
            return
        }

        if let state = pageHighlightState,
           state.pageGeneration == currentPageGeneration,
           state.documentGeneration == domDocumentGeneration,
           state.nodeID == node.id {
            switch state.phase {
            case let .sending(command):
                try await command.value
            case .applied:
                break
            }
            return
        }

        let pageGeneration = currentPageGeneration
        let documentGeneration = domDocumentGeneration
        let operationID = nextPageHighlightID()
        let proxyNodeID = node.id.proxyID
        let command = Task {
            try await page.dom.highlightNode(proxyNodeID)
        }
        pageHighlightState = PageHighlightState(
            operationID: operationID,
            pageGeneration: pageGeneration,
            documentGeneration: documentGeneration,
            nodeID: node.id,
            phase: .sending(command)
        )
        do {
            try await command.value
        } catch {
            if pageHighlightState?.operationID == operationID,
               pageHighlightState?.pageGeneration == pageGeneration,
               pageHighlightState?.documentGeneration == documentGeneration,
               pageHighlightState?.nodeID == node.id {
                pageHighlightState = nil
            }
            throw error
        }
        guard pageHighlightState?.operationID == operationID,
              pageHighlightState?.pageGeneration == pageGeneration,
              pageHighlightState?.documentGeneration == documentGeneration,
              pageHighlightState?.nodeID == node.id else {
            return
        }
        pageHighlightState?.phase = .applied
    }

    private func nextPageHighlightID() -> UInt64 {
        nextPageHighlightOperationID += 1
        return nextPageHighlightOperationID
    }

    package func highlightNode(for id: DOMNode.ID) async throws {
        try await highlight(try requiredNode(for: id))
    }

    /// Clears the current DOM highlight in the inspected page.
    public func hideHighlight() async throws {
        let page = try currentPageOrThrow()
        pageHighlightState = nil
        try await page.dom.hideHighlight()
    }

    package func domUndoRedoCommands() throws -> DOMUndoRedoCommands {
        return DOMUndoRedoCommands(
            context: self,
            target: domEditHistoryTarget,
            documentGeneration: domDocumentGeneration
        )
    }

    package func undoDOMChange() async throws {
        try await domUndoRedoCommands().undo()
    }

    package func redoDOMChange() async throws {
        try await domUndoRedoCommands().redo()
    }

    /// Enables or disables WebKit's element picker.
    ///
    /// The latest call wins. A call made while a command is in flight
    /// replaces the pending state, and every caller returns once the picker
    /// matches the latest request. Cancelling the calling task after the
    /// request is recorded neither cancels nor reverts it.
    public func setElementPickerEnabled(
        _ isEnabled: Bool
    ) async throws {
        try Task.checkCancellation()
        let callerDocumentEpoch = elementPickerDocumentEpoch
        // A pending request can outlive its command for a moment, until the
        // callers waiting on that command resume. Replace it as well.
        if elementPickerCommandTask == nil, requestedElementPickerEnabled == nil {
            guard isEnabled != isElementPickerEnabled else {
                return
            }
            _ = try currentPageOrThrow()
        }
        requestedElementPickerEnabled = isEnabled

        while true {
            let outcome: ElementPickerCommandOutcome
            if let elementPickerCommandTask {
                outcome = await elementPickerCommandTask.value
            } else {
                guard let requested = requestedElementPickerEnabled,
                      requested != isElementPickerEnabled else {
                    requestedElementPickerEnabled = nil
                    return
                }
                let page: WebInspectorTarget
                do {
                    page = try currentPageOrThrow()
                } catch {
                    requestedElementPickerEnabled = nil
                    throw error
                }
                // Record the command before its task is scheduled, so a
                // document replaced in between is seen as a replacement.
                let documentEpoch = elementPickerDocumentEpoch
                elementPickerCommand = ElementPickerCommand(documentEpoch: documentEpoch)
                // The task does not inherit caller cancellation: once WebKit
                // accepts a command, its reply decides the picker state.
                let task = Task<ElementPickerCommandOutcome, Never> {
                    return await self.sendElementPickerCommand(
                        requested,
                        on: page,
                        documentEpoch: documentEpoch
                    )
                }
                elementPickerCommandTask = task
                outcome = await task.value
            }

            let belongsToCurrentDocument = callerDocumentEpoch == elementPickerDocumentEpoch
            switch outcome {
            case let .failed(failedState, error) where belongsToCurrentDocument && failedState == isEnabled:
                throw error
            case let .replacedDocument(cleanupError?) where belongsToCurrentDocument == false:
                throw cleanupError
            case .settled, .failed, .replacedDocument:
                break
            }
            guard belongsToCurrentDocument else {
                throw WebInspectorProxyError.disconnected(
                    "DOM element picker operation no longer belongs to the current document."
                )
            }
        }
    }

    package func toggleElementPickerEnabled() async throws {
        let isEnabled = requestedElementPickerEnabled ?? isElementPickerEnabled
        try await setElementPickerEnabled(!isEnabled)
    }

    /// Sends the `DOM.setInspectModeEnabled` command recorded in
    /// `elementPickerCommand` and applies its reply unless the document was
    /// replaced or `Inspector.inspect` ended the picker session first.
    private func sendElementPickerCommand(
        _ isEnabled: Bool,
        on page: WebInspectorTarget,
        documentEpoch: UInt64
    ) async -> ElementPickerCommandOutcome {
        defer {
            elementPickerCommand = nil
            elementPickerCommandTask = nil
        }
        guard documentEpoch == elementPickerDocumentEpoch else {
            return .replacedDocument(cleanupError: nil)
        }
        WebInspectorDataKitLog.debug(
            "DOM picker setInspectMode start enabled=\(isEnabled) target=\(page.id.rawValue)"
        )
        let result: Result<Void, any Error>
        do {
            try await page.dom.setInspectMode(enabled: isEnabled)
            result = .success(())
        } catch {
            result = .failure(error)
        }

        guard documentEpoch == elementPickerDocumentEpoch else {
            // The document that asked for the picker was replaced while the
            // command was in flight. Leave inspect mode off.
            guard isEnabled, case .success = result else {
                return .replacedDocument(cleanupError: nil)
            }
            do {
                try await page.dom.setInspectMode(enabled: false)
                return .replacedDocument(cleanupError: nil)
            } catch {
                WebInspectorDataKitLog.debug(
                    "DOM picker disable for a replaced document failed target=\(page.id.rawValue): \(String(describing: error))"
                )
                return .replacedDocument(cleanupError: error)
            }
        }
        if elementPickerCommand?.wasEndedByInspect == true {
            return .settled
        }
        if case let .failure(error) = result {
            WebInspectorDataKitLog.debug(
                "DOM picker setInspectMode failed enabled=\(isEnabled) target=\(page.id.rawValue): \(String(describing: error))"
            )
            if requestedElementPickerEnabled == isEnabled {
                requestedElementPickerEnabled = nil
            }
            return .failed(isEnabled: isEnabled, error: error)
        }
        isElementPickerEnabled = isEnabled
        if isEnabled {
            pageHighlightState = nil
        }
        notifyStatusChanged()
        WebInspectorDataKitLog.debug(
            "DOM picker setInspectMode finished enabled=\(isEnabled) target=\(page.id.rawValue)"
        )
        return .settled
    }

    /// Drops the pending picker request because its document was replaced.
    private func invalidateElementPicker() {
        elementPickerDocumentEpoch += 1
        requestedElementPickerEnabled = nil
    }

    func reloadPage(
        ignoringCache: Bool = false
    ) async throws {
        let page = try currentPageOrThrow()
        try await page.page.reload(ignoringCache: ignoringCache)
    }

    /// Returns a CSS selector path for a DOM node.
    public func selectorPath(for node: DOMNode) throws -> String {
        try registeredNode(node)
        return try currentDOMTreeSnapshot(containing: [node]).selectorPath(for: node.id)
    }

    package func selectorPath(for id: DOMNode.ID) throws -> String {
        try selectorPath(for: try requiredNode(for: id))
    }

    /// Returns an XPath expression for a DOM node.
    public func xPath(for node: DOMNode) throws -> String {
        try registeredNode(node)
        return try currentDOMTreeSnapshot(containing: [node]).xPath(for: node.id)
    }

    package func xPath(for id: DOMNode.ID) throws -> String {
        try xPath(for: try requiredNode(for: id))
    }

    /// Creates a live DOM tree controller rooted at a node or the document root.
    ///
    /// - Throws: `WebInspectorProxyError.disconnected` when an explicit
    ///   root is no longer registered in this context or belongs to another
    ///   context.
    public func treeController(
        root requestedRoot: DOMNode? = nil
    ) async throws -> DOMTreeController {
        let root: DOMNode
        if let requestedRoot {
            guard nodesByID[requestedRoot.id] === requestedRoot else {
                throw WebInspectorProxyError.disconnected(
                    "DOMTreeController root is not registered in this WebInspectorContext."
                )
            }
            root = requestedRoot
        } else {
            guard let currentRoot = rootNode else {
                throw WebInspectorProxyError.disconnected("WebInspectorDataKit has no DOM root node.")
            }
            precondition(
                nodesByID[currentRoot.id] === currentRoot,
                "The current DOM root must remain registered in its WebInspectorContext."
            )
            root = currentRoot
        }

        let tree = DOMTreeState(rootNode: root, selectedNode: selectedNode)
        treeStates.append(WeakDOMTreeState(tree))
        pruneReleasedTreeStates()
        return DOMTreeController(tree: tree)
    }

    package func rootTreeController() -> DOMTreeController {
        let tree = DOMTreeState(rootNode: rootNode, selectedNode: selectedNode)
        treeStates.append(WeakDOMTreeState(tree))
        pruneReleasedTreeStates()
        return DOMTreeController(tree: tree)
    }

    func selectContext(_ context: RuntimeContext?) {
        runtimeStore.select(context)
    }

    func evaluate(
        _ expression: String,
        in context: RuntimeContext? = nil
    ) async throws -> RuntimeEvaluation {
        if let context, runtimeStore.isRegistered(context) == false {
            throw WebInspectorProxyError.disconnected("RuntimeContext is not registered in this WebInspectorContext.")
        }
        guard let currentPage else {
            throw WebInspectorProxyError.disconnected("WebInspectorDataKit has no current page target.")
        }

        let executionContext = context ?? selectedContext
        let authority: RuntimeObject.Authority
        if let executionContext {
            guard runtimeStore.isRegistered(executionContext) else {
                throw WebInspectorProxyError.disconnected("RuntimeContext is not registered in this WebInspectorContext.")
            }
            authority = RuntimeObject.Authority(
                pageGeneration: currentPageGeneration,
                targetID: executionContext.authority.targetID,
                targetRevision: executionContext.authority.targetRevision,
                context: .init(
                    id: executionContext.id,
                    identity: ObjectIdentifier(executionContext)
                ),
                frameID: executionContext.frameID
            )
        } else {
            authority = RuntimeObject.Authority(
                pageGeneration: currentPageGeneration,
                targetID: currentPage.id,
                targetRevision: runtimeStore.targetRevision(for: currentPage.id),
                context: nil,
                frameID: currentPage.frameID
            )
        }
        let result = try await currentPage.runtime.evaluate(expression, in: executionContext?.id.proxyID)
        try await validateRuntimeCommandResult(
            authority,
            returned: [result.object]
        )
        return RuntimeEvaluation(
            object: registerClientRuntimeObject(result.object, authority: authority),
            isException: result.wasThrown
        )
    }

    package var networkRequests: [NetworkRequest] {
        networkRequestStore.requests
    }

    package var networkRequestChanges: AsyncStream<WebInspectorCollectionChange<NetworkRequest>> {
        networkRequestStore.changes
    }

    package var consoleMessages: [ConsoleMessage] {
        consoleStore.messages
    }

    package var consoleMessageChanges: AsyncStream<WebInspectorCollectionChange<ConsoleMessage>> {
        consoleStore.changes
    }

    func fetchResponseBody(for request: NetworkRequest) async {
        await request.fetchResponseBody { [weak self] request in
            guard let self else {
                return .failure(NetworkBody.invalidatedResponseFetchError)
            }
            return await responseBodyResult(for: request)
        }
    }

    private func responseBodyResult(
        for request: NetworkRequest
    ) async -> Result<Network.Body, WebInspectorProxyError> {
        guard networkRequestStore.isCurrent(request) else {
            return .failure(NetworkBody.invalidatedResponseFetchError)
        }
        guard let currentPage else {
            return .failure(.disconnected("WebInspectorDataKit has no current page target."))
        }

        let contentLocation = request.resourceContentLocation
        do {
            let body: Network.Body
            switch contentLocation {
            case let .frame(frameID):
                let reply = try await currentPage.page.resourceContent(frameID: frameID, url: request.url)
                guard await waitForOrderedEvents(through: reply.receivedSequence) else {
                    return .failure(NetworkBody.invalidatedResponseFetchError)
                }
                body = reply.value
            case .unavailable:
                return .failure(NetworkBody.invalidatedResponseFetchError)
            case nil:
                body = try await currentPage.network.responseBody(
                    for: request.proxyID,
                    backendResourceIdentifier: request.backendResourceIdentifier
                )
            }
            guard networkRequestStore.isCurrent(request), request.resourceContentLocation == contentLocation else {
                return .failure(NetworkBody.invalidatedResponseFetchError)
            }
            return .success(body)
        } catch let error as WebInspectorProxyError {
            return .failure(error)
        } catch {
            return .failure(.commandFailed(
                domain: contentLocation == nil ? "Network" : "Page",
                method: contentLocation == nil ? "getResponseBody" : "getResourceContent",
                message: String(describing: error)
            ))
        }
    }

    func requestChildren(
        for node: DOMNode,
        depth: Int
    ) async {
        guard nodesByID[node.id] === node else {
            skipEvent("requestChildren ignored a DOMNode from a previous document generation")
            return
        }
        guard let currentPage else {
            skipEvent("requestChildren ignored: no current page target")
            return
        }

        do {
            try await currentPage.dom.requestChildNodes(node.id.proxyID, depth: depth)
        } catch is CancellationError {
            return
        } catch {
            failIfTerminal(error, operation: "DOM.requestChildNodes")
        }
    }

    func properties(
        for object: RuntimeObject
    ) async throws -> [RuntimeObject.Property] {
        let authority = try runtimeObjectAuthority(for: object)
        guard let proxyID = object.proxyID else {
            return []
        }
        guard let currentPage else {
            throw WebInspectorProxyError.disconnected("WebInspectorDataKit has no current page target.")
        }

        let descriptors = try await currentPage.runtime.properties(of: proxyID)
        try await validateRuntimeCommandResult(
            authority,
            object: object,
            returned: descriptors.flatMap(Self.runtimeRemoteObjects)
        )
        return descriptors.map { descriptor in
            let remoteValue = descriptor.value
            let childObject = remoteValue.flatMap { value in
                value.id == nil ? nil : registerClientRuntimeObject(value, authority: authority)
            }
            return RuntimeObject.Property(
                name: descriptor.name,
                value: remoteValue.flatMap { runtimeValueText(for: $0) },
                object: childObject
            )
        }
    }

    func collectionEntries(
        for object: RuntimeObject
    ) async throws -> [RuntimeObject.Entry] {
        let authority = try runtimeObjectAuthority(for: object)
        guard let proxyID = object.proxyID else {
            return []
        }
        guard let currentPage else {
            throw WebInspectorProxyError.disconnected("WebInspectorDataKit has no current page target.")
        }

        let entries = try await currentPage.runtime.collectionEntries(of: proxyID)
        try await validateRuntimeCommandResult(
            authority,
            object: object,
            returned: entries.flatMap(Self.runtimeRemoteObjects)
        )
        return entries.map { entry in
            RuntimeObject.Entry(
                key: entry.key.map { registerClientRuntimeObject($0, authority: authority) },
                value: registerClientRuntimeObject(entry.value, authority: authority)
            )
        }
    }

    private func runtimeObjectAuthority(for object: RuntimeObject) throws -> RuntimeObject.Authority {
        guard runtimeStore.isRegistered(object) else {
            throw WebInspectorProxyError.disconnected("RuntimeObject is not registered in this WebInspectorContext.")
        }
        let authority = object.authority
        try runtimeStore.validate(authority, object: object, pageGeneration: currentPageGeneration)
        return authority
    }

    private func registerClientRuntimeObject(
        _ payload: Runtime.RemoteObject,
        authority: RuntimeObject.Authority
    ) -> RuntimeObject {
        runtimeStore.registerObject(payload, owner: .client, authority: authority)
    }

    private func validateRuntimeCommandResult(
        _ authority: RuntimeObject.Authority,
        object: RuntimeObject? = nil,
        returned objects: [Runtime.RemoteObject]
    ) async throws {
        do {
            try runtimeStore.validate(authority, object: object, pageGeneration: currentPageGeneration)
            guard objects.allSatisfy({
                runtimeRemoteObject($0, belongsTo: authority.targetID)
            }) else {
                throw RuntimeModelStore.staleResultError
            }
        } catch {
            await releaseReturnedRuntimeObjects(
                objects,
                authority: authority
            )
            throw error
        }
    }

    private func runtimeRemoteObject(
        _ object: Runtime.RemoteObject,
        belongsTo targetID: WebInspectorTarget.ID
    ) -> Bool {
        guard let targetScopeRawValue = object.id?.targetScopeRawValue else {
            return true
        }
        return runtimeAuthorityTargetID(for: WebInspectorTarget.ID(targetScopeRawValue)) == targetID
    }

    private func releaseReturnedRuntimeObjects(
        _ objects: [Runtime.RemoteObject],
        authority: RuntimeObject.Authority
    ) async {
        guard currentPageGeneration == authority.pageGeneration,
              let page = currentPage else {
            return
        }
        let objectIDs = Set(objects.compactMap(\.id))
        for objectID in objectIDs {
            // Object groups are target-local, so each scoped ID must route its
            // own cleanup. A retired target may reject cleanup; the authority
            // error remains the command result in that case.
            try? await page.runtime.releaseObject(objectID)
        }
    }

    private static func runtimeRemoteObjects(
        in descriptor: Runtime.PropertyDescriptor
    ) -> [Runtime.RemoteObject] {
        [descriptor.value, descriptor.get, descriptor.set, descriptor.symbol].compactMap { $0 }
    }

    private static func runtimeRemoteObjects(
        in entry: Runtime.CollectionEntry
    ) -> [Runtime.RemoteObject] {
        [entry.key, entry.value].compactMap { $0 }
    }

    private func runtimeValueText(for object: Runtime.RemoteObject) -> String? {
        if let description = object.description {
            return description
        }
        guard let value = object.value else {
            return nil
        }
        switch value {
        case let .string(value):
            return value
        case let .number(value):
            return String(value)
        case let .bool(value):
            return String(value)
        case .null:
            return "null"
        case .array,
             .object:
            return nil
        }
    }

    /// Stops observing the inspected page and tears down context-owned state.
    public func stop() async {
        await detach()
    }

    func detach() async {
        startupTask?.cancel()
        startupTask = nil
        currentPageRetargetTask?.cancel()
        currentPageRetargetTask = nil
        currentPageCleanupTask?.cancel()
        currentPageCleanupTask = nil
        documentReloadTask?.cancel()
        documentReloadTask = nil
        cancelDOMDocumentLoad()
        inspectorInspectResolutionTask?.cancel()
        inspectorInspectResolutionTask = nil
        inspectResolutionTask?.cancel()
        inspectResolutionTask = nil
        pageHighlightMaintenanceTask?.cancel()
        pageHighlightMaintenanceTask = nil
        cancelFrameDocumentLoadTasks()
        styleRefreshTask?.cancel()
        styleRefreshTask = nil
        styleRefreshGeneration += 1
        cancelStyleToggleOperations()
        stopEventPumps()
        pendingInspectedNodeID = nil
        isElementPickerEnabled = false
        currentPage = nil
        advanceCurrentPageGeneration()
        advanceDOMDocumentGeneration()
        resetAttachmentBackedModels()
        teardownError = nil
        teardownError = await disableEnabledDomains()
        transition(to: .detached)
    }

    private func startup(
        generation: Int,
        documentLoadID: UInt64
    ) async {
        defer {
            finishDOMDocumentLoad(id: documentLoadID)
        }
        guard Task.isCancelled == false,
              isCurrentPageGeneration(generation),
              domDocumentLoad?.id == documentLoadID else {
            return
        }
        if let teardownError = await disableEnabledDomainsBeforeRestart() {
            failIfTerminal(teardownError, operation: "domain disable before restart")
            if case .failed = state {
                return
            }
        }
        guard Task.isCancelled == false,
              isCurrentPageGeneration(generation),
              domDocumentLoad?.id == documentLoadID else {
            return
        }

        do {
            let target = try await proxy.waitForCurrentPage()
            guard Task.isCancelled == false,
                  isCurrentPageGeneration(generation),
                  domDocumentLoad?.id == documentLoadID else {
                return
            }
            currentPage = target
            await subscribe(to: target)
            await target.waitForModelEventSubscriptions()
            try checkPageGeneration(generation)
            resetReplayBackedModelsBeforeEnable()
            for domain in [WebInspectorEnabledDomain.inspector, .page, .runtime, .network] {
                try await enableDomainTracking(domain, on: target, generation: generation)
                try checkPageGeneration(generation)
            }
            try await loadNetworkResourceTree(on: target, generation: generation)
            var document = try await loadCurrentDOMDocument(
                on: target,
                loadID: documentLoadID
            )
            try checkPageGeneration(generation)
            try await enableDomainTracking(.console, on: target, generation: generation)
            try checkPageGeneration(generation)
            document = try await reloadDOMDocumentIfNeeded(
                document,
                on: target,
                loadID: documentLoadID
            )
            try checkPageGeneration(generation)
            applyLoadedDOMDocument(document)
            transition(to: .attached)
        } catch is CancellationError {
            await disableStartupDomainsAfterCancellation(documentLoadID)
        } catch is SupersededPageGeneration {
            return
        } catch {
            guard Task.isCancelled == false else {
                await disableStartupDomainsAfterCancellation(documentLoadID)
                return
            }
            guard isCurrentPageGeneration(generation) else {
                return
            }
            await logStartupTeardownFailure()
            fail(error as? WebInspectorProxyError ?? .attachFailed(String(describing: error)))
        }
    }

    /// Throws `CancellationError` when the current task is cancelled, and
    /// `SupersededPageGeneration` when a newer page generation replaced
    /// `generation`.
    private func checkPageGeneration(_ generation: Int) throws {
        try Task.checkCancellation()
        guard isCurrentPageGeneration(generation) else {
            throw SupersededPageGeneration()
        }
    }

    private func disableStartupDomainsAfterCancellation(
        _ documentLoadID: UInt64
    ) async {
        guard domDocumentLoad?.id == documentLoadID else {
            return
        }
        if let error = await disableEnabledDomains() {
            failIfTerminal(error, operation: "domain disable after cancellation")
        }
    }

    private func disableEnabledDomainsBeforeRestart() async -> WebInspectorProxyError? {
        let error = await disableEnabledDomains()
        await discardCurrentPageDomainLeases()
        return error
    }

    private func discardCurrentPageDomainLeases() async {
        await styleTrackingLeases.discardAll()
        for domain in [WebInspectorEnabledDomain.inspector, .page, .runtime, .network, .console] {
            await discardDomainTrackingLease(domain)
        }
    }

    private func discardDomainTrackingLease(
        _ domain: WebInspectorEnabledDomain
    ) async {
        guard let target = domainTrackingTargets.removeValue(forKey: domain) else {
            return
        }
        await domainEnablement.discardLease(domain, on: target)
    }

    private func enableDomainTracking(
        _ domain: WebInspectorEnabledDomain,
        on target: WebInspectorTarget,
        generation: Int
    ) async throws {
        try await domainEnablement.acquire(domain, on: target)
        guard isCurrentPageGeneration(generation) else {
            await releaseLateAcquiredDomain(domain, on: target)
            return
        }
        domainTrackingTargets[domain] = target
    }

    private func loadNetworkResourceTree(
        on target: WebInspectorTarget,
        generation: Int
    ) async throws {
        let storeGeneration = networkRequestStore.generation
        networkResourceTreeError = nil
        while !Task.isCancelled, isCurrentPageGeneration(generation) {
            let revision = networkRecorder.resourceTreeRevision
            let reply: WebInspectorProxyCommandReply<Page.ResourceTree>
            do {
                reply = try await target.page.resourceTree()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard !Task.isCancelled, isCurrentPageGeneration(generation) else {
                    throw CancellationError()
                }
                networkResourceTreeError = error as? WebInspectorProxyError ?? .commandFailed(
                    domain: "Page", method: "getResourceTree", message: String(describing: error)
                )
                failIfTerminal(error, operation: "Page.getResourceTree")
                if case .failed = state { throw error }
                return
            }
            guard await waitForOrderedEvents(through: reply.receivedSequence),
                  !Task.isCancelled,
                  isCurrentPageGeneration(generation) else {
                throw CancellationError()
            }
            // A user clear must not be undone by an in-flight snapshot.
            guard networkRequestStore.generation == storeGeneration else { return }
            // Navigation can replace a frame while its resource snapshot is in flight.
            guard revision == networkRecorder.resourceTreeRevision else { continue }
            networkRecorder.applyResourceTree(reply.value)
            networkResourceTreeError = nil
            return
        }
        throw CancellationError()
    }

    private func releaseLateAcquiredDomain(
        _ domain: WebInspectorEnabledDomain,
        on target: WebInspectorTarget
    ) async {
        if let error = await domainEnablement.release(domain, on: target) {
            WebInspectorDataKitLog.debug(
                "domain late-acquire release failed domain=\(domain.rawValue) target=\(target.id.rawValue) error=\(String(describing: error))"
            )
        }
    }

    private func loadCurrentDOMDocument(
        on target: WebInspectorTarget,
        loadID: UInt64
    ) async throws -> LoadedDOMDocument {
        while true {
            guard Task.isCancelled == false,
                  domDocumentLoad?.id == loadID else {
                throw CancellationError()
            }
            let generation = domDocumentGeneration
            let bootstrapID = beginDOMBootstrap(loadID: loadID)
            let reply: WebInspectorProxyCommandReply<DOM.Node>
            do {
                reply = try await target.dom.getDocumentWithReplyBoundary()
            } catch {
                abandonDOMBootstrap(loadID: loadID, bootstrapID: bootstrapID)
                throw error
            }
            guard Task.isCancelled == false,
                  domDocumentLoad?.id == loadID else {
                abandonDOMBootstrap(loadID: loadID, bootstrapID: bootstrapID)
                throw CancellationError()
            }
            guard await waitForOrderedEvents(
                through: reply.receivedSequence
            ) else {
                abandonDOMBootstrap(loadID: loadID, bootstrapID: bootstrapID)
                throw CancellationError()
            }
            guard Task.isCancelled == false,
                  domDocumentLoad?.id == loadID else {
                abandonDOMBootstrap(loadID: loadID, bootstrapID: bootstrapID)
                throw CancellationError()
            }
            guard isDOMDocumentGeneration(generation) else {
                abandonDOMBootstrap(loadID: loadID, bootstrapID: bootstrapID)
                continue
            }
            return LoadedDOMDocument(
                node: reply.value,
                generation: generation,
                loadID: loadID,
                bootstrapID: bootstrapID
            )
        }
    }

    private func reloadDOMDocumentIfNeeded(
        _ document: LoadedDOMDocument,
        on target: WebInspectorTarget,
        loadID: UInt64
    ) async throws -> LoadedDOMDocument {
        precondition(document.loadID == loadID, "DOM document load authority changed within one operation.")
        if isDOMDocumentGeneration(document.generation) {
            return document
        }
        abandonDOMBootstrap(loadID: loadID, bootstrapID: document.bootstrapID)
        return try await loadCurrentDOMDocument(
            on: target,
            loadID: loadID
        )
    }

    private func beginDOMDocumentLoad() -> UInt64 {
        precondition(domDocumentLoad == nil, "Only one DOM document load may be active.")
        let id = nextDOMDocumentLoadID
        nextDOMDocumentLoadID += 1
        domDocumentLoad = DOMDocumentLoad(id: id, bootstrap: nil)
        return id
    }

    private func cancelDOMDocumentLoad() {
        domDocumentLoad = nil
    }

    private func finishDOMDocumentLoad(id: UInt64) {
        guard domDocumentLoad?.id == id else {
            return
        }
        domDocumentLoad = nil
    }

    private func beginDOMBootstrap(loadID: UInt64) -> UInt64 {
        guard var load = domDocumentLoad else {
            preconditionFailure("DOM bootstrap requires an active document load.")
        }
        precondition(load.id == loadID, "DOM bootstrap must belong to the active document load.")
        precondition(load.bootstrap == nil, "DOM document load already owns a bootstrap.")
        let id = nextDOMBootstrapID
        nextDOMBootstrapID += 1
        load.bootstrap = DOMBootstrap(id: id, events: [])
        domDocumentLoad = load
        return id
    }

    private func abandonDOMBootstrap(loadID: UInt64, bootstrapID: UInt64) {
        guard domDocumentLoad?.id == loadID,
              domDocumentLoad?.bootstrap?.id == bootstrapID else {
            return
        }
        domDocumentLoad?.bootstrap = nil
    }

    private func bufferDOMEventDuringDocumentLoad(_ event: DOM.Event) -> Bool {
        guard var load = domDocumentLoad,
              var bootstrap = load.bootstrap else {
            return false
        }
        bootstrap.events.append(event)
        load.bootstrap = bootstrap
        domDocumentLoad = load
        return true
    }

    private func applyLoadedDOMDocument(
        _ document: LoadedDOMDocument,
        reason: DOMTreeSnapshotReason = .initialDocument
    ) {
        guard let load = domDocumentLoad,
              let bootstrap = load.bootstrap else {
            preconditionFailure("Loaded DOM document requires an active bootstrap.")
        }
        precondition(
            load.id == document.loadID,
            "Loaded DOM document must own the active document load."
        )
        precondition(
            bootstrap.id == document.bootstrapID,
            "Loaded DOM document must own the active bootstrap."
        )
        domDocumentLoad = nil
        applyDocument(document.node, reason: reason)
        for event in bootstrap.events {
            apply(event)
        }
    }

    private func resetReplayBackedModelsBeforeEnable() {
        runtimeStore.clearExecutionContexts(page: currentPage)
        consoleStore.resetBeforeReplay()
    }

    private func resetCurrentPageLifecycleModels() {
        resetDOM()
        runtimeStore.clearExecutionContexts(page: currentPage)
        consoleStore.clear()
    }

    private func resetAttachmentBackedModels() {
        resetCurrentPageLifecycleModels()
        networkRecorder.beginAttachment()
    }

    private func disableEnabledDomains() async -> WebInspectorProxyError? {
        let consoleError = await disableDomainTracking(.console)
        let styleError = await styleTrackingLeases.releaseAll()
        var firstError = consoleError ?? styleError
        for domain in [WebInspectorEnabledDomain.runtime, .network, .page, .inspector] {
            let error = await disableDomainTracking(domain)
            firstError = firstError ?? error
        }
        return firstError
    }

    private func disableDomainTracking(
        _ domain: WebInspectorEnabledDomain
    ) async -> WebInspectorProxyError? {
        guard let target = domainTrackingTargets.removeValue(forKey: domain) else {
            return nil
        }
        return await domainEnablement.release(domain, on: target)
    }

    /// Best-effort teardown after a startup failure: the startup error is the
    /// root cause and owns `state`; a teardown error must not mask it.
    private func logStartupTeardownFailure() async {
        if let teardownError = await disableEnabledDomains() {
            WebInspectorDataKitLog.debug("domain disable after startup failure also failed: \(String(describing: teardownError))")
        }
    }

    private func subscribe(
        to target: WebInspectorTarget,
        beforeValidation: (@Sendable () async -> Void)? = nil
    ) async {
        stopEventPumps()
        let subscriptionGeneration = orderedEventSubscriptionGeneration
        let feed = await target.orderedEventFeed()
        let pump = WebInspectorEventPump(
            stream: feed.events,
            apply: { [weak self, target] sequencedEvent in
                guard let self else { return }
                await self.applyOrderedEvent(
                    sequencedEvent,
                    target: target,
                    subscriptionGeneration: subscriptionGeneration,
                    beforeWatermarkUpdate: nil
                )
            },
            onFailure: { [weak self] error in
                guard let self else { return }
                self.handleOrderedEventStreamFailure(
                    error,
                    subscriptionGeneration: subscriptionGeneration
                )
            }
        )
        if let beforeValidation {
            await beforeValidation()
        }
        guard subscriptionGeneration == orderedEventSubscriptionGeneration else {
            pump.stop()
            return
        }
        precondition(
            feed.initialSequence >= lastOrderedEventSequence,
            "Ordered event feed moved backwards."
        )
        lastOrderedEventSequence = feed.initialSequence
        eventPumps = [pump]
    }

    private func handleOrderedEventStreamFailure(
        _ error: any Error,
        subscriptionGeneration: UInt64
    ) {
        guard subscriptionGeneration == orderedEventSubscriptionGeneration else {
            return
        }
        stopEventPumps()
        startupTask?.cancel()
        currentPageRetargetTask?.cancel()
        currentPageCleanupTask?.cancel()
        documentReloadTask?.cancel()
        cancelDOMDocumentLoad()

        if let proxyError = error as? WebInspectorProxyError {
            fail(proxyError)
        } else {
            fail(.disconnected("Ordered event stream failed: \(error)"))
        }
    }

    private func stopEventPumps() {
        orderedEventSubscriptionGeneration += 1
        for pump in eventPumps {
            pump.stop()
        }
        eventPumps = []
        domDocumentLoad?.bootstrap = nil
        resolveOrderedEventWaiters(reachedBoundary: false)
    }

    private func applyOrderedEvent(
        _ sequencedEvent: WebInspectorProxyOrderedEvent,
        target: WebInspectorTarget,
        subscriptionGeneration: UInt64,
        beforeWatermarkUpdate: (@Sendable () async -> Void)?
    ) async {
        guard subscriptionGeneration == orderedEventSubscriptionGeneration else {
            return
        }
        precondition(
            sequencedEvent.sequence > lastOrderedEventSequence,
            "Ordered event sequence must increase monotonically."
        )
        if let event = sequencedEvent.event {
            switch event {
            case let .targetLifecycle(value):
                apply(value)
            case let .dom(value):
                if case .documentUpdated = value {
                    apply(value)
                } else if bufferDOMEventDuringDocumentLoad(value) == false {
                    apply(value)
                }
            case let .css(value):
                apply(value)
            case let .network(value):
                apply(value)
            case let .console(value):
                apply(value.event, targetID: value.targetID)
            case let .runtime(value):
                apply(value, targetID: target.id)
            case let .inspector(value):
                resolveInspectorInspectEvent(value, on: target)
            }
            recordEventPumpAppliedForTesting()
        }
        if let beforeWatermarkUpdate {
            await beforeWatermarkUpdate()
        }
        guard subscriptionGeneration == orderedEventSubscriptionGeneration else {
            return
        }
        lastOrderedEventSequence = sequencedEvent.sequence
        resolveReachedOrderedEventWaiters()
    }

    private func resolveInspectorInspectEvent(
        _ event: Inspector.Event,
        on target: WebInspectorTarget
    ) {
        inspectorInspectResolutionTask?.cancel()
        let pageGeneration = currentPageGeneration
        let documentGeneration = domDocumentGeneration
        inspectorInspectResolutionTask = Task { [weak self, target] in
            guard let event = await target.resolveDOMInspectEvent(event) else {
                return
            }
            guard Task.isCancelled == false, let self else {
                return
            }
            guard self.isCurrentPageGeneration(pageGeneration),
                  self.isDOMDocumentGeneration(documentGeneration) else {
                return
            }
            self.apply(event)
        }
    }

    private func waitForOrderedEvents(
        through sequence: UInt64,
        waiterRegistered: (@Sendable () -> Void)? = nil
    ) async -> Bool {
        guard lastOrderedEventSequence < sequence else {
            return true
        }
        return await withCheckedContinuation { continuation in
            orderedEventWaiters.append(OrderedEventWaiter(
                sequence: sequence,
                continuation: continuation
            ))
            waiterRegistered?()
        }
    }

    private func resolveReachedOrderedEventWaiters() {
        var pending: [OrderedEventWaiter] = []
        for waiter in orderedEventWaiters {
            if waiter.sequence <= lastOrderedEventSequence {
                waiter.continuation.resume(returning: true)
            } else {
                pending.append(waiter)
            }
        }
        orderedEventWaiters = pending
    }

    private func resolveOrderedEventWaiters(reachedBoundary: Bool) {
        let waiters = orderedEventWaiters
        orderedEventWaiters = []
        for waiter in waiters {
            waiter.continuation.resume(returning: reachedBoundary)
        }
    }

    private func recordEventPumpAppliedForTesting() {
        #if DEBUG
        eventPumpAppliedSequenceForTestingStorage &+= 1
        let completedWaiterIDs = eventPumpAppliedWaitersForTesting.compactMap { id, waiter in
            eventPumpAppliedSequenceForTestingStorage >= waiter.minimumSequence ? id : nil
        }
        for waiterID in completedWaiterIDs {
            resolveEventPumpAppliedWaiterForTesting(id: waiterID, result: true)
        }
        #endif
    }

    private func resolveEventPumpAppliedWaitersForTesting(result: Bool) {
        #if DEBUG
        let waiterIDs = Array(eventPumpAppliedWaitersForTesting.keys)
        for waiterID in waiterIDs {
            resolveEventPumpAppliedWaiterForTesting(id: waiterID, result: result)
        }
        #endif
    }

    private func resolveEventPumpAppliedWaiterForTesting(id: UInt64, result: Bool) {
        #if DEBUG
        guard let waiter = eventPumpAppliedWaitersForTesting.removeValue(forKey: id) else {
            return
        }
        waiter.continuation.resume(returning: result)
        #endif
    }

    private func notifyDOMTreeSnapshot(
        reason: DOMTreeSnapshotReason
    ) {
        pruneReleasedTreeStates()
        for reference in treeStates {
            reference.tree?.applySnapshot(rootNode: rootNode, selectedNode: selectedNode, reason: reason)
        }
    }

    private func notifyDOMTreeChildrenReplaced(parent: DOMNode) {
        pruneReleasedTreeStates()
        for reference in treeStates {
            reference.tree?.applyChildrenReplaced(parent: parent)
        }
    }

    private func notifyDOMTreeChildInserted(
        parent: DOMNode,
        node: DOMNode,
        previousSiblingID: DOMNode.ID?
    ) {
        pruneReleasedTreeStates()
        for reference in treeStates {
            reference.tree?.applyChildInserted(parent: parent, node: node, previousSiblingID: previousSiblingID)
        }
    }

    private func notifyDOMTreeChildRemoved(
        parent: DOMNode,
        nodeID: DOMNode.ID
    ) {
        pruneReleasedTreeStates()
        for reference in treeStates {
            reference.tree?.applyChildRemoved(parent: parent, nodeID: nodeID)
        }
    }

    private func notifyDOMTreeChildCountChanged(node: DOMNode) {
        pruneReleasedTreeStates()
        for reference in treeStates {
            reference.tree?.applyChildCountChanged(node: node)
        }
    }

    private func notifyDOMTreeNodeChanged(_ node: DOMNode) {
        pruneReleasedTreeStates()
        for reference in treeStates {
            reference.tree?.applyNodeChanged(node)
        }
    }

    private func notifyDOMTreeSelectionChanged(
        _ node: DOMNode?,
        reveal: DOMRevealPolicy = .selectAndScroll
    ) {
        pruneReleasedTreeStates()
        for reference in treeStates {
            reference.tree?.applySelectionChanged(nodeID: node?.id, reveal: reveal)
        }
    }

    private func clearSelectionIfDeleted(
        _ deletedRootIDs: [DOMNode.ID],
        snapshot: DOMTreeSnapshot
    ) {
        guard let selectedNode else {
            return
        }
        let deletedRootIDs = Set(deletedRootIDs)
        guard deletedRootIDs.contains(selectedNode.id)
            || snapshot.ancestorNodeIDs(of: selectedNode.id).contains(where: deletedRootIDs.contains)
        else {
            return
        }

        styleRefreshTask?.cancel()
        styleRefreshTask = nil
        styleRefreshGeneration += 1
        selectedNode.setElementStyles(nil)
        self.selectedNode = nil
        notifyDOMTreeSelectionChanged(nil)
        notifyStatusChanged()
    }

    @discardableResult
    private func registeredNode(_ node: DOMNode) throws -> DOMNode {
        guard nodesByID[node.id] === node else {
            throw WebInspectorProxyError.disconnected("DOMNode is not registered in this WebInspectorContext.")
        }
        return node
    }

    private func currentPageOrThrow() throws -> WebInspectorTarget {
        guard let currentPage else {
            throw WebInspectorProxyError.disconnected("WebInspectorDataKit has no current page target.")
        }
        return currentPage
    }

    private func domTarget(owning id: DOM.Node.ID) throws -> WebInspectorTarget {
        if let scopedTargetRawValue = id.targetScopeRawValue {
            return proxy.frameTarget(id: WebInspectorTarget.ID(scopedTargetRawValue))
        }
        return try currentPageOrThrow()
    }

    private func cssTarget(owning id: CSS.Style.ID) throws -> WebInspectorTarget {
        if let scopedTargetRawValue = id.targetScopeRawValue {
            return proxy.frameTarget(id: WebInspectorTarget.ID(scopedTargetRawValue))
        }
        return try currentPageOrThrow()
    }

    private func cssTarget(owning id: CSS.Rule.ID) throws -> WebInspectorTarget {
        if let scopedTargetRawValue = id.targetScopeRawValue {
            return proxy.frameTarget(id: WebInspectorTarget.ID(scopedTargetRawValue))
        }
        return try currentPageOrThrow()
    }

    private func cssTarget(owning id: CSS.StyleSheet.ID) throws -> WebInspectorTarget {
        if let scopedTargetRawValue = id.targetScopeRawValue {
            return proxy.frameTarget(id: WebInspectorTarget.ID(scopedTargetRawValue))
        }
        return try currentPageOrThrow()
    }

    private static func markDOMUndoableStateIfNeeded(
        on target: WebInspectorTarget,
        options: WebInspectorMutationOptions
    ) async throws {
        switch options.undo {
        case .automatic:
            try await target.dom.markUndoableState()
        case .disabled:
            break
        }
    }

    private func recordDOMEditHistoryTarget(_ target: WebInspectorTarget, options: WebInspectorMutationOptions) {
        guard options.undo == .automatic else {
            return
        }
        domEditHistoryTarget = target
        didInvalidateDOMEditHistoryTarget = false
    }

    private func validatedDeletionTargets(for nodes: [DOMNode]) throws -> [WebInspectorTarget] {
        var deletionTargets: [WebInspectorTarget] = []
        var firstTargetID: WebInspectorTarget.ID?
        for node in nodes {
            let target = try domTarget(owning: node.id.proxyID)
            if let firstTargetID, firstTargetID != target.id {
                throw WebInspectorProxyError.commandFailed(
                    domain: "DOM",
                    method: "removeNode",
                    message: "Deleting nodes from multiple DOM targets in one mutation is not supported."
                )
            }
            firstTargetID = target.id
            deletionTargets.append(target)
        }
        return deletionTargets
    }

    private func currentDOMTreeSnapshot() -> DOMTreeSnapshot {
        DOMTreeSnapshot.make(revision: 0, rootNode: rootNode, selectedNode: selectedNode)
    }

    private func currentDOMTreeSnapshot(containing nodes: [DOMNode]) throws -> DOMTreeSnapshot {
        let snapshot = currentDOMTreeSnapshot()
        for node in nodes where snapshot.node(for: node.id) == nil {
            throw WebInspectorProxyError.disconnected("DOMNode is not in the current DOM tree.")
        }
        return snapshot
    }

    private func isNodeAttachedToCurrentDOMTree(_ node: DOMNode) -> Bool {
        guard let rootNode else {
            return false
        }
        var visitedNodeIDs = Set<DOMNode.ID>()
        return subtree(rootNode, contains: node.id, visitedNodeIDs: &visitedNodeIDs)
    }

    private func subtree(
        _ root: DOMNode,
        contains nodeID: DOMNode.ID,
        visitedNodeIDs: inout Set<DOMNode.ID>
    ) -> Bool {
        guard visitedNodeIDs.insert(root.id).inserted else {
            return false
        }
        if root.id == nodeID {
            return true
        }
        for associatedRoot in root.associatedSubtreeRoots() {
            if subtree(associatedRoot, contains: nodeID, visitedNodeIDs: &visitedNodeIDs) {
                return true
            }
        }
        guard case let .loaded(children) = root.children else {
            return false
        }
        for child in children {
            if subtree(child, contains: nodeID, visitedNodeIDs: &visitedNodeIDs) {
                return true
            }
        }
        return false
    }

    private func isCurrentPageGeneration(
        _ generation: Int
    ) -> Bool {
        return currentPageGeneration == generation
    }

    private func isDOMDocumentGeneration(
        _ generation: Int
    ) -> Bool {
        return domDocumentGeneration == generation
    }

    private func targetRevision(for targetID: WebInspectorTarget.ID) -> UInt64 {
        targetRevisionsByID[targetID] ?? 0
    }

    private func advanceTargetRevision(for targetID: WebInspectorTarget.ID) {
        targetRevisionsByID[targetID, default: 0] += 1
    }

    private func runtimeAuthorityTargetID(for targetID: WebInspectorTarget.ID) -> WebInspectorTarget.ID {
        RuntimeModelStore.authorityTargetID(for: targetID, page: currentPage)
    }

    @discardableResult
    private func advanceCurrentPageGeneration() -> Int {
        currentPageGeneration += 1
        return currentPageGeneration
    }

    @discardableResult
    private func advanceDOMDocumentGeneration() -> Int {
        domDocumentLoad?.bootstrap = nil
        domDocumentGeneration += 1
        return domDocumentGeneration
    }

    private func pruneReleasedTreeStates() {
        treeStates.removeAll { $0.tree == nil }
    }

    private func fail(_ error: WebInspectorProxyError) {
        switch state {
        case .failed, .detached:
            return
        case .attaching, .attached:
            transition(to: .failed(error))
        }
    }

    /// Inbound events may reference entities this context has not materialized:
    /// WebKit only reports what it has bound for this frontend, but binding can
    /// predate domain tracking (attach mid-flight) or outlive this context's
    /// index (evicted subtrees). Skipping is the protocol-correct response;
    /// `state = .failed` is reserved for terminal connection loss.
    private func skipEvent(_ reason: String) {
        WebInspectorDataKitLog.debug("event skipped: \(reason)")
    }

    private func ignoreExpectedDOMMaterializationGap() {
        // WebKit can emit events for bound, evicted, or detached subtrees that
        // are outside this context's connected-tree index. These events can be
        // per-node and high-frequency, so logging them destroys the signal from
        // actual lifecycle and contract violations.
    }

    /// Command failures surface at their call site (thrown, or a per-model
    /// phase such as `NetworkBody.Phase.failed`); only terminal connection
    /// loss moves the whole context to `.failed`.
    private func failIfTerminal(_ error: Error, operation: String) {
        switch error {
        case let proxyError as WebInspectorProxyError:
            switch proxyError {
            case .disconnected, .unsupported, .attachFailed:
                fail(proxyError)
            case .closed:
                WebInspectorDataKitLog.debug("\(operation) raced connection close")
            case .commandFailed, .timeout:
                WebInspectorDataKitLog.debug("\(operation) failed: \(String(describing: proxyError))")
            }
        default:
            WebInspectorDataKitLog.debug("\(operation) failed: \(String(describing: error))")
        }
    }

    private func transition(to newState: State) {
        state = newState
        notifyStatusChanged()
        WebInspectorDataKitLog.debug("context state=\(newState.logDescription)")
    }

    private func notifyStatusChanged() {
        guard statusRelay.hasContinuations else {
            return
        }
        statusRelay.yield(status)
    }

    func reloadDocument() {
        guard let currentPage else {
            skipEvent("reloadDocument ignored: no current page target")
            return
        }

        precondition(domDocumentLoad == nil, "A DOM document load owner must absorb reload invalidations.")
        documentReloadTask?.cancel()
        let documentLoadID = beginDOMDocumentLoad()
        documentReloadTask = Task { [weak self, currentPage] in
            guard let self else {
                return
            }
            defer {
                self.finishDOMDocumentLoad(id: documentLoadID)
            }
            do {
                let document = try await self.loadCurrentDOMDocument(
                    on: currentPage,
                    loadID: documentLoadID
                )
                self.applyLoadedDOMDocument(
                    document,
                    reason: .documentUpdated
                )
            } catch is CancellationError {
                return
            } catch {
                self.failIfTerminal(error, operation: "DOM.getDocument")
            }
        }
    }

}

extension WebInspectorContext {
    func apply(_ event: WebInspectorTargetLifecycleEvent) {
        switch event {
        case let .didCommitProvisionalTarget(commit):
            applyCurrentPageTargetCommit(commit)
        case let .frameNavigated(frame):
            networkRecorder.frameNavigated(frame)
            applyCurrentPageFrameNavigated(frame)
        case let .targetDestroyed(targetID):
            networkRecorder.targetDestroyed(targetID)
            applyCurrentPageTargetDestroyed(targetID)
        case let .frameDetached(frameID):
            networkRecorder.frameDetached(frameID)
            applyCurrentPageFrameDetached(frameID)
        case .unknown:
            break
        }
    }

    private func applyCurrentPageTargetCommit(
        _ commit: WebInspectorTargetCommitLifecycle
    ) {
        guard commit.newTarget.id == .currentPage else {
            skipEvent("Target.didCommitProvisionalTarget ignored for non-current-page target")
            return
        }
        guard case .page = commit.newTarget.kind,
              commit.newTarget.isProvisional == false else {
            skipEvent("Target.didCommitProvisionalTarget ignored for non-top-level current page target")
            return
        }
        guard let target = currentPage else {
            fail(.disconnected("Current page target committed while WebInspectorDataKit had no current page."))
            return
        }
        networkRecorder.targetCommitted(commit)
        let refreshedTarget = target.withPageBinding(from: commit.newTarget)
        let retainsProtocolAgent = target.pageBindingID == refreshedTarget.pageBindingID
            && hasRequiredCurrentPageDomainLeases(for: target)
        currentPage = refreshedTarget

        currentPageRetargetTask?.cancel()
        documentReloadTask?.cancel()
        documentReloadTask = nil
        cancelDOMDocumentLoad()
        let generation = advanceCurrentPageGeneration()
        advanceDOMDocumentGeneration()
        resetCurrentPageLifecycleModels()
        let documentLoadID = beginDOMDocumentLoad()

        currentPageRetargetTask = Task { [weak self, refreshedTarget, generation] in
            await self?.retargetCurrentPage(
                refreshedTarget,
                generation: generation,
                documentLoadID: documentLoadID,
                retainDomainLeases: retainsProtocolAgent,
                committedFrom: target
            )
        }
    }

    private func hasRequiredCurrentPageDomainLeases(for target: WebInspectorTarget) -> Bool {
        [WebInspectorEnabledDomain.inspector, .page, .runtime, .network, .console].allSatisfy { domain in
            guard let trackingTarget = domainTrackingTargets[domain] else {
                return false
            }
            return trackingTarget.pageBindingID == target.pageBindingID
        }
    }

    private func retargetCurrentPage(
        _ target: WebInspectorTarget,
        generation: Int,
        documentLoadID: UInt64,
        retainDomainLeases: Bool = false,
        committedFrom previousTarget: WebInspectorTarget? = nil
    ) async {
        defer {
            finishDOMDocumentLoad(id: documentLoadID)
            if isCurrentPageGeneration(generation) {
                currentPageRetargetTask = nil
            }
        }
        let enablesPageDomain: Bool
        if retainDomainLeases {
            enablesPageDomain = false
        } else if previousTarget != nil {
            let retainedPageLease = await prepareDomainLeasesForCommittedTarget(
                to: target,
                generation: generation
            )
            guard Task.isCancelled == false,
                  isCurrentPageGeneration(generation) else {
                return
            }
            enablesPageDomain = retainedPageLease == false
        } else {
            await discardCurrentPageDomainLeases()
            enablesPageDomain = true
        }

        do {
            try checkPageGeneration(generation)
            if retainDomainLeases == false {
                let domains: [WebInspectorEnabledDomain] = enablesPageDomain
                    ? [.inspector, .page, .runtime, .network]
                    : [.inspector, .runtime, .network]
                for domain in domains {
                    try await enableDomainTracking(domain, on: target, generation: generation)
                    try checkPageGeneration(generation)
                }
            }
            try await loadNetworkResourceTree(on: target, generation: generation)
            var document = try await loadCurrentDOMDocument(
                on: target,
                loadID: documentLoadID
            )
            try checkPageGeneration(generation)
            if retainDomainLeases == false {
                try await enableDomainTracking(.console, on: target, generation: generation)
                try checkPageGeneration(generation)
            }
            document = try await reloadDOMDocumentIfNeeded(
                document,
                on: target,
                loadID: documentLoadID
            )
            try checkPageGeneration(generation)
            applyLoadedDOMDocument(document, reason: .pageChanged)
            if case .attaching = state {
                transition(to: .attached)
            }
        } catch is CancellationError {
            return
        } catch is SupersededPageGeneration {
            return
        } catch {
            guard isCurrentPageGeneration(generation) else {
                return
            }
            let retargetError = error as? WebInspectorProxyError
                ?? .attachFailed(String(describing: error))
            if let teardownError = await disableEnabledDomains() {
                WebInspectorDataKitLog.debug(
                    "domain disable after retarget failure also failed: \(String(describing: teardownError))"
                )
            }
            fail(retargetError)
        }
    }

    private func prepareDomainLeasesForCommittedTarget(
        to committedTarget: WebInspectorTarget,
        generation: Int
    ) async -> Bool {
        await styleTrackingLeases.discardAll()
        guard Task.isCancelled == false,
              isCurrentPageGeneration(generation) else {
            return false
        }
        for domain in [WebInspectorEnabledDomain.inspector, .runtime, .network, .console] {
            await discardDomainTrackingLease(domain)
        }

        guard domainTrackingTargets[.page] != nil else {
            return false
        }
        domainTrackingTargets[.page] = committedTarget
        return true
    }

    private func applyCurrentPageFrameNavigated(
        _ frame: WebInspectorPageFrameLifecycle
    ) {
        guard let currentPage else {
            skipEvent("Page.frameNavigated ignored: no current page target")
            return
        }
        guard frame.parentID == nil || frame.id == currentPage.frameID else {
            cssStyleSheets.invalidate(frameID: frame.id)
            detachProjectedFrameDocument(forFrameID: frame.id)
            runtimeStore.clearExecutionContexts(frameID: frame.id, page: currentPage)
            return
        }
        advanceDOMDocumentGeneration()
        resetDOM()
        runtimeStore.clearExecutionContexts(page: currentPage)
        guard domDocumentLoad == nil else {
            return
        }
        reloadDocument()
    }

    private func applyCurrentPageFrameDetached(
        _ frameID: FrameID
    ) {
        cssStyleSheets.invalidate(frameID: frameID)
        detachProjectedFrameDocument(forFrameID: frameID)
        runtimeStore.clearExecutionContexts(frameID: frameID, page: currentPage)
    }

    private func applyCurrentPageTargetDestroyed(
        _ targetID: WebInspectorTarget.ID
    ) {
        let authorityTargetID = runtimeAuthorityTargetID(for: targetID)
        advanceTargetRevision(for: authorityTargetID)
        if authorityTargetID == currentPage?.id {
            cssInspectorBaselineStore.reset()
        } else {
            cssInspectorBaselineStore.reset(targetID: authorityTargetID)
        }
        if authorityTargetID == currentPage?.id {
            cssStyleSheets.invalidateAll()
        } else {
            cssStyleSheets.invalidate(targetID: authorityTargetID)
        }
        runtimeStore.clearExecutionContexts(targetID: authorityTargetID)
        guard targetID == .currentPage else {
            styleTrackingLeases.discard(forDestroyedTargetID: targetID)
            return
        }
        guard currentPage != nil else {
            skipEvent("Target.targetDestroyed ignored: no current page target")
            return
        }

        // A current-page Target.targetDestroyed is a physical route loss during
        // retarget, not a clean SDK close signal. Real close is owned by the
        // proxy connection close path.
        startupTask?.cancel()
        startupTask = nil
        currentPageRetargetTask?.cancel()
        currentPageCleanupTask?.cancel()
        currentPageCleanupTask = nil
        documentReloadTask?.cancel()
        documentReloadTask = nil
        cancelDOMDocumentLoad()
        cancelStyleToggleOperations()
        invalidateElementPicker()
        isElementPickerEnabled = false
        notifyStatusChanged()
        let generation = advanceCurrentPageGeneration()
        advanceDOMDocumentGeneration()
        let documentLoadID = beginDOMDocumentLoad()

        currentPageRetargetTask = Task { [weak self, generation] in
            await self?.retargetDestroyedCurrentPage(
                generation: generation,
                documentLoadID: documentLoadID
            )
        }
    }

    private func retargetDestroyedCurrentPage(
        generation: Int,
        documentLoadID: UInt64
    ) async {
        defer {
            finishDOMDocumentLoad(id: documentLoadID)
            if isCurrentPageGeneration(generation) {
                currentPageRetargetTask = nil
            }
        }
        do {
            let gracePeriod = await proxy.bootstrapGracePeriod
            var replacement = try await proxy.waitForCurrentPageReplacement(gracePeriod: gracePeriod)
            guard Task.isCancelled == false, isCurrentPageGeneration(generation) else {
                return
            }
            if replacement == nil {
                // The destroyed page has no successor yet (process kill without
                // an immediate reload). `.attached` promises a usable current
                // page, so stop presenting the destroyed page's state and wait
                // for the next page target to appear.
                currentPage = nil
                resetCurrentPageLifecycleModels()
                if state == .attached {
                    transition(to: .attaching)
                }
                replacement = try await proxy.waitForCurrentPageReplacement(gracePeriod: nil)
                guard Task.isCancelled == false, isCurrentPageGeneration(generation) else {
                    return
                }
            }
            guard let replacement else {
                fail(.disconnected("Current page target was destroyed without a replacement."))
                return
            }
            currentPage = replacement
            resetCurrentPageLifecycleModels()
            await retargetCurrentPage(
                replacement,
                generation: generation,
                documentLoadID: documentLoadID
            )
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentPageGeneration(generation) else {
                return
            }
            failIfTerminal(error, operation: "current page replacement")
        }
    }
}

extension WebInspectorContext {
    func apply(_ event: DOM.Event) {
        switch event {
        case .documentUpdated:
            advanceDOMDocumentGeneration()
            resetDOM()
            guard domDocumentLoad == nil else {
                return
            }
            reloadDocument()
        case let .setChildNodes(parent, nodes):
            applySetChildNodes(parent: parent, nodes: nodes)
        case let .childNodeInserted(parent, previous, node):
            applyChildNodeInserted(parent: parent, previous: previous, node: node)
        case let .childNodeRemoved(parent, node):
            applyChildNodeRemoved(parent: parent, node: node)
        case let .childNodeCountUpdated(id, count):
            guard let node = nodesByID[DOMNode.ID(id)] else {
                let nodeID = DOMNode.ID(id)
                loadFrameDocumentIfNeeded(forNodeID: nodeID, reason: "DOM.childNodeCountUpdated")
                ignoreExpectedDOMMaterializationGap()
                return
            }
            node.updateChildNodeCount(count)
            notifyDOMTreeChildCountChanged(node: node)
        case let .attributeModified(id, name, value):
            guard let node = nodesByID[DOMNode.ID(id)] else {
                let nodeID = DOMNode.ID(id)
                loadFrameDocumentIfNeeded(forNodeID: nodeID, reason: "DOM.attributeModified")
                ignoreExpectedDOMMaterializationGap()
                return
            }
            node.setAttribute(name: name, value: value)
            markSelectedStylesNeedsRefresh(for: DOMNode.ID(id))
            notifyDOMTreeNodeChanged(node)
        case let .attributeRemoved(id, name):
            guard let node = nodesByID[DOMNode.ID(id)] else {
                let nodeID = DOMNode.ID(id)
                loadFrameDocumentIfNeeded(forNodeID: nodeID, reason: "DOM.attributeRemoved")
                ignoreExpectedDOMMaterializationGap()
                return
            }
            node.removeAttribute(name: name)
            markSelectedStylesNeedsRefresh(for: DOMNode.ID(id))
            notifyDOMTreeNodeChanged(node)
        case let .inlineStyleInvalidated(ids):
            if ids.isEmpty {
                markSelectedStylesNeedsRefresh()
            } else {
                for id in ids {
                    markSelectedStylesNeedsRefresh(for: DOMNode.ID(id))
                }
            }
        case let .characterDataModified(id, value):
            guard let node = nodesByID[DOMNode.ID(id)] else {
                let nodeID = DOMNode.ID(id)
                loadFrameDocumentIfNeeded(forNodeID: nodeID, reason: "DOM.characterDataModified")
                ignoreExpectedDOMMaterializationGap()
                return
            }
            node.setNodeValue(value)
            markSelectedStylesNeedsRefresh(for: DOMNode.ID(id))
            notifyDOMTreeNodeChanged(node)
        case let .inspect(id):
            if let command = elementPickerCommand {
                guard command.documentEpoch == elementPickerDocumentEpoch else {
                    skipEvent("DOM.inspect ignored for a picker command from a replaced document")
                    return
                }
                elementPickerCommand?.wasEndedByInspect = true
            }
            requestedElementPickerEnabled = nil
            isElementPickerEnabled = false
            pageHighlightState = nil
            notifyStatusChanged()
            let inspectedNodeID = DOMNode.ID(id)
            guard let node = nodesByID[inspectedNodeID] else {
                loadFrameDocumentIfNeeded(forNodeID: inspectedNodeID, reason: "DOM.inspect")
                WebInspectorDataKitLog.debug(
                    "DOM.inspect pending nodeID=\(String(describing: inspectedNodeID)) materialized=false root=\(String(describing: rootNode?.id))"
                )
                pendingInspectedNodeID = inspectedNodeID
                resolvePendingInspectedNode(requestSubtreeIfNeeded: true)
                return
            }
            guard isNodeAttachedToCurrentDOMTree(node) else {
                loadFrameDocumentIfNeeded(forNodeID: inspectedNodeID, reason: "DOM.inspect")
                pendingInspectedNodeID = inspectedNodeID
                resolvePendingInspectedNode(requestSubtreeIfNeeded: true)
                return
            }
            WebInspectorDataKitLog.debug(
                "DOM.inspect selecting nodeID=\(String(describing: inspectedNodeID)) materialized=true"
            )
            pendingInspectedNodeID = nil
            inspectResolutionTask?.cancel()
            inspectResolutionTask = nil
            selectInspectedNode(node)
        case .detachedRoot:
            // Deferred by design: detached roots need a registry and selection
            // policy outside the single connected tree (05-two-layer-sdk-design
            // §detached roots). A pending inspect has its own lifecycle log.
            ignoreExpectedDOMMaterializationGap()
        case let .shadowRootPushed(host, root):
            applyShadowRootPushed(host: host, root: root)
        case let .shadowRootPopped(host, root):
            applyShadowRootPopped(host: host, root: root)
        case let .pseudoElementAdded(parent, element):
            applyPseudoElementAdded(parent: parent, element: element)
        case let .pseudoElementRemoved(parent, element):
            applyPseudoElementRemoved(parent: parent, element: element)
        case .willDestroyDOMNode,
             .unknown:
            break
        }
    }

    func applyDocument(
        _ node: DOM.Node,
        reason: DOMTreeSnapshotReason = .initialDocument
    ) {
        var materializedPayloadIDs = Set<DOMNode.ID>()
        collectMaterializedPayloadIDs(node, into: &materializedPayloadIDs)
        rootNode = model(for: node, preserving: materializedPayloadIDs)
        notifyDOMTreeSnapshot(reason: reason)
        resolvePendingInspectedNode(requestSubtreeIfNeeded: true)
    }

    package func seedDOMDocument(_ node: DOM.Node) {
        applyDocument(
            node,
            reason: rootNode == nil ? .initialDocument : .documentUpdated
        )
    }

    package func seedElementPickerEnabled(_ isEnabled: Bool) {
        requestedElementPickerEnabled = nil
        isElementPickerEnabled = isEnabled
        notifyStatusChanged()
    }

    /// Seeds the selected element node's styles through the same load path
    /// the backend refresh uses. Requires a selected element node; cancels
    /// any in-flight backend refresh so it cannot clobber the seeded state.
    package func seedSelectedNodeStyles(
        matchedStyles: CSS.MatchedStyles,
        inlineStyles: CSS.InlineStyles? = nil,
        computedProperties: [CSS.ComputedProperty] = []
    ) {
        guard let selectedNode else {
            preconditionFailure("seedSelectedNodeStyles requires a selected node.")
        }
        guard selectedNode.nodeType == 1 else {
            preconditionFailure("seedSelectedNodeStyles requires a selected element node.")
        }
        styleRefreshTask?.cancel()
        styleRefreshTask = nil
        styleRefreshGeneration += 1
        let styles = selectedNode.elementStyles ?? CSSStyles(nodeID: selectedNode.id, modelContext: self)
        selectedNode.setElementStyles(styles)
        styles.load(
            matchedStyles: matchedStyles,
            inlineStyles: inlineStyles ?? CSS.InlineStyles(),
            computedProperties: computedProperties
        )
    }

    private func resetDOM() {
        invalidateElementPicker()
        cancelStyleToggleOperations()
        cssInspectorBaselineStore.reset()
        cssStyleSheets.removeAll()
        inspectorInspectResolutionTask?.cancel()
        inspectorInspectResolutionTask = nil
        inspectResolutionTask?.cancel()
        inspectResolutionTask = nil
        styleRefreshTask?.cancel()
        styleRefreshTask = nil
        styleRefreshGeneration += 1
        pageHighlightMaintenanceTask?.cancel()
        pageHighlightMaintenanceTask = nil
        clearPageHighlightForDOMReset()
        cancelFrameDocumentLoadTasks()
        rootNode = nil
        selectedNode = nil
        if domEditHistoryTarget != nil {
            didInvalidateDOMEditHistoryTarget = true
        }
        domEditHistoryTarget = nil
        isElementPickerEnabled = false
        pendingInspectedNodeID = nil
        nodesByID = [:]
        frameDocumentProjectionIndex.removeAll()
        notifyDOMTreeSnapshot(reason: .reset)
        notifyStatusChanged()
    }

    private func clearPageHighlightForDOMReset() {
        guard pageHighlightState != nil else {
            return
        }
        pageHighlightState = nil
        guard let currentPage else {
            return
        }
        pageHighlightMaintenanceTask = Task { [weak self, currentPage] in
            do {
                guard Task.isCancelled == false else {
                    return
                }
                guard self?.shouldSendPageHighlightClearAfterDOMReset() == true else {
                    return
                }
                WebInspectorDataKitLog.debug("DOM reset clearing page highlight")
                try await currentPage.dom.hideHighlight()
            } catch is CancellationError {
                return
            } catch {
                self?.failIfTerminal(error, operation: "DOM.hideHighlight after DOM reset")
            }
        }
    }

    private func shouldSendPageHighlightClearAfterDOMReset() -> Bool {
        return pageHighlightState == nil
    }

    private func applySetChildNodes(
        parent: DOM.Node.ID,
        nodes: [DOM.Node]
    ) {
        guard let parentNode = nodesByID[DOMNode.ID(parent)] else {
            let parentID = DOMNode.ID(parent)
            loadFrameDocumentIfNeeded(forNodeID: parentID, reason: "DOM.setChildNodes")
            ignoreExpectedDOMMaterializationGap()
            return
        }
        let previousChildren: [DOMNode]
        if case let .loaded(children) = parentNode.children {
            previousChildren = children
        } else {
            previousChildren = []
        }
        var newSubtreeIDs = Set<DOMNode.ID>()
        for node in nodes {
            collectMaterializedPayloadIDs(node, into: &newSubtreeIDs)
        }
        let newChildren = nodes.map { model(for: $0, preserving: newSubtreeIDs) }
        let newChildIDs = Set(newChildren.map(\.id))
        for previousChild in previousChildren where newChildIDs.contains(previousChild.id) == false {
            removeSubtreeFromIndex(previousChild, preserving: newSubtreeIDs)
        }
        parentNode.setChildren(newChildren)
        notifyDOMTreeChildrenReplaced(parent: parentNode)
        resolvePendingInspectedNode(requestSubtreeIfNeeded: false)
    }

    private func applyChildNodeInserted(
        parent: DOM.Node.ID,
        previous: DOM.Node.ID?,
        node: DOM.Node
    ) {
        guard let parentNode = nodesByID[DOMNode.ID(parent)] else {
            let parentID = DOMNode.ID(parent)
            loadFrameDocumentIfNeeded(forNodeID: parentID, reason: "DOM.childNodeInserted")
            ignoreExpectedDOMMaterializationGap()
            return
        }

        var children: [DOMNode]
        switch parentNode.children {
        case let .unrequested(count) where count > 0:
            parentNode.updateChildNodeCount(parentNode.childNodeCount + 1)
            notifyDOMTreeChildCountChanged(node: parentNode)
            return
        case .unrequested:
            children = []
        case let .loaded(loadedChildren):
            children = loadedChildren
        }
        var materializedPayloadIDs = Set<DOMNode.ID>()
        collectMaterializedPayloadIDs(node, into: &materializedPayloadIDs)
        let inserted = model(for: node, preserving: materializedPayloadIDs)
        if let previous, let index = children.firstIndex(where: { $0.id == DOMNode.ID(previous) }) {
            children.insert(inserted, at: children.index(after: index))
        } else {
            children.insert(inserted, at: 0)
        }
        parentNode.setChildren(children)
        notifyDOMTreeChildInserted(
            parent: parentNode,
            node: inserted,
            previousSiblingID: previous.map(DOMNode.ID.init)
        )
        resolvePendingInspectedNode(requestSubtreeIfNeeded: false)
    }

    private func applyChildNodeRemoved(
        parent: DOM.Node.ID,
        node: DOM.Node.ID
    ) {
        guard let parentNode = nodesByID[DOMNode.ID(parent)] else {
            let parentID = DOMNode.ID(parent)
            loadFrameDocumentIfNeeded(forNodeID: parentID, reason: "DOM.childNodeRemoved")
            ignoreExpectedDOMMaterializationGap()
            return
        }

        let removedID = DOMNode.ID(node)
        guard let removedNode = nodesByID[removedID] else {
            loadFrameDocumentIfNeeded(forNodeID: removedID, reason: "DOM.childNodeRemoved")
            ignoreExpectedDOMMaterializationGap()
            return
        }
        removeSubtreeFromIndex(removedNode)

        guard case let .loaded(children) = parentNode.children else {
            parentNode.updateChildNodeCount(max(0, parentNode.childNodeCount - 1))
            notifyDOMTreeChildCountChanged(node: parentNode)
            return
        }
        parentNode.setChildren(children.filter { $0.id != removedID })
        notifyDOMTreeChildRemoved(parent: parentNode, nodeID: removedID)
    }

    private func applyShadowRootPushed(
        host: DOM.Node.ID,
        root payload: DOM.Node
    ) {
        guard let hostNode = nodesByID[DOMNode.ID(host)] else {
            let hostID = DOMNode.ID(host)
            loadFrameDocumentIfNeeded(forNodeID: hostID, reason: "DOM.shadowRootPushed")
            ignoreExpectedDOMMaterializationGap()
            return
        }

        var materializedPayloadIDs = Set<DOMNode.ID>()
        collectMaterializedPayloadIDs(payload, into: &materializedPayloadIDs)
        let rootNode = model(for: payload, preserving: materializedPayloadIDs)
        hostNode.appendShadowRoot(rootNode)
        notifyDOMTreeChildrenReplaced(parent: hostNode)
        resolvePendingInspectedNode(requestSubtreeIfNeeded: false)
    }

    private func applyShadowRootPopped(
        host: DOM.Node.ID,
        root: DOM.Node.ID
    ) {
        guard let hostNode = nodesByID[DOMNode.ID(host)] else {
            let hostID = DOMNode.ID(host)
            loadFrameDocumentIfNeeded(forNodeID: hostID, reason: "DOM.shadowRootPopped")
            ignoreExpectedDOMMaterializationGap()
            return
        }

        let rootID = DOMNode.ID(root)
        guard let removedRoot = hostNode.removeShadowRoot(id: rootID) ?? nodesByID[rootID] else {
            ignoreExpectedDOMMaterializationGap()
            return
        }
        removeSubtreeFromIndex(removedRoot)
        notifyDOMTreeChildrenReplaced(parent: hostNode)
    }

    private func applyPseudoElementAdded(
        parent: DOM.Node.ID,
        element payload: DOM.Node
    ) {
        guard let parentNode = nodesByID[DOMNode.ID(parent)] else {
            let parentID = DOMNode.ID(parent)
            loadFrameDocumentIfNeeded(forNodeID: parentID, reason: "DOM.pseudoElementAdded")
            ignoreExpectedDOMMaterializationGap()
            return
        }

        var materializedPayloadIDs = Set<DOMNode.ID>()
        collectMaterializedPayloadIDs(payload, into: &materializedPayloadIDs)
        let pseudoElement = model(for: payload, preserving: materializedPayloadIDs)
        if let replacedElement = parentNode.setPseudoElement(pseudoElement) {
            removeSubtreeFromIndex(replacedElement, preserving: materializedPayloadIDs)
        }
        notifyDOMTreeChildrenReplaced(parent: parentNode)
        resolvePendingInspectedNode(requestSubtreeIfNeeded: false)
    }

    private func applyPseudoElementRemoved(
        parent: DOM.Node.ID,
        element: DOM.Node.ID
    ) {
        guard let parentNode = nodesByID[DOMNode.ID(parent)] else {
            let parentID = DOMNode.ID(parent)
            loadFrameDocumentIfNeeded(forNodeID: parentID, reason: "DOM.pseudoElementRemoved")
            ignoreExpectedDOMMaterializationGap()
            return
        }

        let elementID = DOMNode.ID(element)
        guard let removedElement = parentNode.removePseudoElement(id: elementID) ?? nodesByID[elementID] else {
            ignoreExpectedDOMMaterializationGap()
            return
        }
        removeSubtreeFromIndex(removedElement)
        notifyDOMTreeChildrenReplaced(parent: parentNode)
    }

    @discardableResult
    private func removeSubtreeFromIndex(
        _ root: DOMNode,
        preserving preservedIDs: Set<DOMNode.ID> = []
    ) -> Bool {
        var removedIDs = Set<DOMNode.ID>()
        collectSubtreeIDs(root, into: &removedIDs)
        removedIDs.subtract(preservedIDs)
        frameDocumentProjectionIndex.removeProjections(containing: removedIDs)
        for id in removedIDs {
            nodesByID[id] = nil
        }
        if let selectedNode, removedIDs.contains(selectedNode.id) {
            styleRefreshTask?.cancel()
            styleRefreshTask = nil
            styleRefreshGeneration += 1
            self.selectedNode = nil
            notifyDOMTreeSelectionChanged(nil)
            notifyStatusChanged()
            return true
        }
        return false
    }

    private func collectSubtreeIDs(_ node: DOMNode, into ids: inout Set<DOMNode.ID>) {
        ids.insert(node.id)
        for associatedRoot in node.associatedSubtreeRoots() {
            collectSubtreeIDs(associatedRoot, into: &ids)
        }
        guard case let .loaded(children) = node.children else {
            return
        }
        for child in children {
            collectSubtreeIDs(child, into: &ids)
        }
    }

    private func collectMaterializedPayloadIDs(_ node: DOM.Node, into ids: inout Set<DOMNode.ID>) {
        ids.insert(DOMNode.ID(node.id))
        for associatedNode in associatedPayloadNodes(for: node) {
            collectMaterializedPayloadIDs(associatedNode, into: &ids)
        }
        for child in node.children ?? [] {
            collectMaterializedPayloadIDs(child, into: &ids)
        }
    }

    private func model(
        for payload: DOM.Node,
        preserving materializedPayloadIDs: Set<DOMNode.ID>
    ) -> DOMNode {
        let id = DOMNode.ID(payload.id)
        let node: DOMNode
        let previousChildren: [DOMNode]
        let previousAssociatedRoots: [DOMNode]
        if let existing = nodesByID[id] {
            if case let .loaded(children) = existing.children {
                previousChildren = children
            } else {
                previousChildren = []
            }
            previousAssociatedRoots = existing.associatedSubtreeRoots()
            existing.update(from: payload)
            existing.setModelContext(self)
            node = existing
        } else {
            previousChildren = []
            previousAssociatedRoots = []
            node = DOMNode(node: payload, modelContext: self)
            nodesByID[id] = node
        }

        let payloadContentDocument = payload.contentDocument.map {
            model(for: $0, preserving: materializedPayloadIDs)
        }
        let shadowRoots = payload.shadowRoots.map {
            model(for: $0, preserving: materializedPayloadIDs)
        }
        let templateContent = payload.templateContent.map {
            model(for: $0, preserving: materializedPayloadIDs)
        }
        let beforePseudoElement = payload.beforePseudoElement.map {
            model(for: $0, preserving: materializedPayloadIDs)
        }
        let otherPseudoElements = payload.otherPseudoElements.map {
            model(for: $0, preserving: materializedPayloadIDs)
        }
        let afterPseudoElement = payload.afterPseudoElement.map {
            model(for: $0, preserving: materializedPayloadIDs)
        }
        let contentDocument = projectedFrameDocument(for: node, payloadContentDocument: payloadContentDocument)
        node.setAssociatedNodes(
            contentDocument: contentDocument,
            shadowRoots: shadowRoots,
            templateContent: templateContent,
            beforePseudoElement: beforePseudoElement,
            otherPseudoElements: otherPseudoElements,
            afterPseudoElement: afterPseudoElement
        )
        let associatedIDs = Set(node.associatedSubtreeRoots().map(\.id))
        for previousRoot in previousAssociatedRoots where associatedIDs.contains(previousRoot.id) == false {
            removeSubtreeFromIndex(previousRoot, preserving: materializedPayloadIDs)
        }

        if let children = payload.children {
            let newChildren = children.map { model(for: $0, preserving: materializedPayloadIDs) }
            let newChildIDs = Set(newChildren.map(\.id))
            for previousChild in previousChildren where newChildIDs.contains(previousChild.id) == false {
                removeSubtreeFromIndex(previousChild, preserving: materializedPayloadIDs)
            }
            node.setChildren(newChildren)
        } else if payload.childNodeCount == 0 && previousChildren.isEmpty == false {
            for previousChild in previousChildren {
                removeSubtreeFromIndex(previousChild, preserving: materializedPayloadIDs)
            }
            node.setChildrenUnrequested(count: payload.childNodeCount)
        } else {
            node.updateChildNodeCount(payload.childNodeCount)
        }
        return node
    }

    private func associatedPayloadNodes(for node: DOM.Node) -> [DOM.Node] {
        [node.contentDocument]
            .compactMap { $0 }
            + node.shadowRoots
            + [node.templateContent, node.beforePseudoElement]
            .compactMap { $0 }
            + node.otherPseudoElements
            + [node.afterPseudoElement]
            .compactMap { $0 }
    }

    private func projectedFrameDocument(
        for owner: DOMNode,
        payloadContentDocument: DOMNode?
    ) -> DOMNode? {
        guard owner.isFrameOwner else {
            return payloadContentDocument
        }

        if let attachedRootID = frameDocumentProjectionIndex.projectedFrameDocumentRootID(forOwnerNodeID: owner.id) {
            guard let attachedRoot = nodesByID[attachedRootID],
                  frameOwner(owner, matchesFrameDocumentRoot: attachedRoot) else {
                frameDocumentProjectionIndex.detachProjection(attachedTo: owner.id)
                return payloadContentDocument
            }
            return attachedRoot
        }

        guard let frameTargetID = frameTargetIDForFrameDocument(matching: owner),
              let rootID = frameDocumentProjectionIndex.frameDocumentRootID(for: frameTargetID),
              let root = nodesByID[rootID] else {
            return payloadContentDocument
        }
        frameDocumentProjectionIndex.attach(frameTargetID: frameTargetID, to: owner.id)
        return root
    }

    private func frameTargetIDForFrameDocument(matching owner: DOMNode) -> WebInspectorTarget.ID? {
        let matches = frameDocumentProjectionIndex.frameTargetIDs.filter { frameTargetID in
            guard frameDocumentProjectionIndex.ownerNodeID(for: frameTargetID) == nil,
                  let rootID = frameDocumentProjectionIndex.frameDocumentRootID(for: frameTargetID),
                  let root = nodesByID[rootID] else {
                return false
            }
            return frameOwner(owner, matchesFrameDocumentRoot: root)
        }
        guard matches.count <= 1 else {
            WebInspectorDataKitLog.debug(
                "frame document projection ambiguous owner=\(String(describing: owner.id))"
            )
            return nil
        }
        return matches.first
    }

    private func frameOwner(_ owner: DOMNode, matchesFrameDocumentRoot root: DOMNode) -> Bool {
        guard owner.isFrameOwner,
              let ownerFrameID = owner.frameID,
              let rootFrameID = root.frameID else {
            return false
        }
        return ownerFrameID == rootFrameID
    }

    private func loadFrameDocumentIfNeeded(
        forNodeID nodeID: DOMNode.ID,
        reason: String
    ) {
        guard let frameTargetID = frameTargetID(for: nodeID) else {
            return
        }
        if let rootID = frameDocumentProjectionIndex.frameDocumentRootID(for: frameTargetID),
           let root = nodesByID[rootID] {
            if let owner = attachProjectedFrameDocumentRoot(root, frameTargetID: frameTargetID) {
                notifyDOMTreeChildrenReplaced(parent: owner)
            }
            return
        }
        loadFrameDocumentIfNeeded(forFrameTargetID: frameTargetID, reason: reason)
    }

    private func loadFrameDocumentIfNeeded(
        forFrameTargetID frameTargetID: WebInspectorTarget.ID,
        reason: String
    ) {
        guard frameDocumentLoadTasks[frameTargetID] == nil else {
            return
        }
        let generation = domDocumentGeneration
        let target = proxy.frameTarget(id: frameTargetID)
        WebInspectorDataKitLog.debug(
            "frame document projection loading target=\(frameTargetID.rawValue) reason=\(reason)"
        )
        frameDocumentLoadTasks[frameTargetID] = Task { [weak self, target, frameTargetID, generation] in
            do {
                let document = try await target.dom.getDocument()
                guard Task.isCancelled == false,
                      self?.isDOMDocumentGeneration(generation) == true else {
                    return
                }
                self?.applyFrameDocument(document, frameTargetID: frameTargetID)
            } catch is CancellationError {
                return
            } catch {
                guard self?.isDOMDocumentGeneration(generation) == true else {
                    return
                }
                self?.failIfTerminal(error, operation: "frame DOM.getDocument")
            }
            if self?.isDOMDocumentGeneration(generation) == true {
                self?.frameDocumentLoadTasks[frameTargetID] = nil
            }
        }
    }

    private func applyFrameDocument(
        _ document: DOM.Node,
        frameTargetID: WebInspectorTarget.ID
    ) {
        let scopedDocument = scopedFrameDocument(document, to: frameTargetID)
        var materializedPayloadIDs = Set<DOMNode.ID>()
        collectMaterializedPayloadIDs(scopedDocument, into: &materializedPayloadIDs)
        let previousRootID = frameDocumentProjectionIndex.setFrameDocumentRootID(
            DOMNode.ID(scopedDocument.id),
            for: frameTargetID
        )
        let frameRoot = model(for: scopedDocument, preserving: materializedPayloadIDs)
        if let previousRootID,
           previousRootID != frameRoot.id,
           let previousRoot = nodesByID[previousRootID] {
            removeSubtreeFromIndex(previousRoot, preserving: materializedPayloadIDs)
        }

        if let owner = attachProjectedFrameDocumentRoot(frameRoot, frameTargetID: frameTargetID) {
            notifyDOMTreeChildrenReplaced(parent: owner)
        }
        resolvePendingInspectedNode(requestSubtreeIfNeeded: true)
    }

    private func attachProjectedFrameDocumentRoot(
        _ frameRoot: DOMNode,
        frameTargetID: WebInspectorTarget.ID
    ) -> DOMNode? {
        guard let owner = frameOwner(forFrameDocumentRoot: frameRoot, frameTargetID: frameTargetID) else {
            frameDocumentProjectionIndex.detach(frameTargetID: frameTargetID)
            return nil
        }
        frameDocumentProjectionIndex.attach(frameTargetID: frameTargetID, to: owner.id)
        owner.setContentDocument(frameRoot)
        return owner
    }

    private func frameOwner(
        forFrameDocumentRoot frameRoot: DOMNode,
        frameTargetID: WebInspectorTarget.ID
    ) -> DOMNode? {
        if let ownerID = frameDocumentProjectionIndex.ownerNodeID(for: frameTargetID),
           let owner = nodesByID[ownerID],
           frameOwner(owner, matchesFrameDocumentRoot: frameRoot) {
            return owner
        }
        let candidates = nodesByID.values.filter { node in
            guard frameOwner(node, matchesFrameDocumentRoot: frameRoot) else {
                return false
            }
            guard let attachedRootID = frameDocumentProjectionIndex.projectedFrameDocumentRootID(forOwnerNodeID: node.id) else {
                return true
            }
            return attachedRootID == frameRoot.id
        }
        guard candidates.count <= 1 else {
            WebInspectorDataKitLog.debug(
                "frame document projection ambiguous frameID=\(String(describing: frameRoot.frameID))"
            )
            return nil
        }
        return candidates.first
    }

    private func detachProjectedFrameDocument(
        forFrameID frameID: FrameID
    ) {
        let owners = nodesByID.values.filter { $0.isFrameOwner && $0.frameID == frameID }
        for owner in owners {
            guard let rootID = frameDocumentProjectionIndex.projectedFrameDocumentRootID(forOwnerNodeID: owner.id) else {
                continue
            }
            let root = nodesByID[rootID]
            frameDocumentProjectionIndex.detachProjection(attachedTo: owner.id)
            owner.setContentDocument(nil)
            if let root {
                removeSubtreeFromIndex(root)
            }
            notifyDOMTreeChildrenReplaced(parent: owner)
        }
    }

    private func frameTargetID(for nodeID: DOMNode.ID) -> WebInspectorTarget.ID? {
        nodeID.proxyID.targetScopeRawValue.map(WebInspectorTarget.ID.init)
    }

    private func scopedFrameDocument(_ node: DOM.Node, to frameTargetID: WebInspectorTarget.ID) -> DOM.Node {
        DOM.Node(
            id: scopedNodeID(node.id, to: frameTargetID),
            nodeType: node.nodeType,
            nodeName: node.nodeName,
            localName: node.localName,
            nodeValue: node.nodeValue,
            frameID: node.frameID,
            documentURL: node.documentURL,
            baseURL: node.baseURL,
            attributes: node.attributes,
            attributeList: node.attributeList,
            childNodeCount: node.childNodeCount,
            children: node.children?.map { scopedFrameDocument($0, to: frameTargetID) },
            contentDocument: node.contentDocument.map { scopedFrameDocument($0, to: frameTargetID) },
            shadowRoots: node.shadowRoots.map { scopedFrameDocument($0, to: frameTargetID) },
            templateContent: node.templateContent.map { scopedFrameDocument($0, to: frameTargetID) },
            beforePseudoElement: node.beforePseudoElement.map { scopedFrameDocument($0, to: frameTargetID) },
            otherPseudoElements: node.otherPseudoElements.map { scopedFrameDocument($0, to: frameTargetID) },
            afterPseudoElement: node.afterPseudoElement.map { scopedFrameDocument($0, to: frameTargetID) },
            pseudoType: node.pseudoType,
            shadowRootType: node.shadowRootType
        )
    }

    private func scopedNodeID(_ id: DOM.Node.ID, to frameTargetID: WebInspectorTarget.ID) -> DOM.Node.ID {
        guard id.targetScopeRawValue == nil else {
            return id
        }
        return DOM.Node.ID(id.rawValue, scopedToTargetRawValue: frameTargetID.rawValue)
    }

    private func cancelFrameDocumentLoadTasks() {
        for task in frameDocumentLoadTasks.values {
            task.cancel()
        }
        frameDocumentLoadTasks = [:]
    }

    private func resolvePendingInspectedNode(
        requestSubtreeIfNeeded: Bool
    ) {
        guard let pendingInspectedNodeID else {
            return
        }
        guard let inspectedNode = nodesByID[pendingInspectedNodeID] else {
            if requestSubtreeIfNeeded {
                requestMaterializationForPendingInspectedNode(pendingInspectedNodeID)
            }
            return
        }
        guard isNodeAttachedToCurrentDOMTree(inspectedNode) else {
            if requestSubtreeIfNeeded {
                requestMaterializationForPendingInspectedNode(pendingInspectedNodeID)
            }
            return
        }
        WebInspectorDataKitLog.debug(
            "DOM.inspect resolved pending nodeID=\(String(describing: pendingInspectedNodeID))"
        )
        self.pendingInspectedNodeID = nil
        inspectResolutionTask?.cancel()
        inspectResolutionTask = nil
        selectInspectedNode(inspectedNode)
    }

    private func requestMaterializationForPendingInspectedNode(
        _ nodeID: DOMNode.ID
    ) {
        if let frameTargetID = frameTargetID(for: nodeID) {
            if let rootID = frameDocumentProjectionIndex.frameDocumentRootID(for: frameTargetID),
               let frameRoot = nodesByID[rootID] {
                WebInspectorDataKitLog.debug(
                    "DOM.inspect unresolved nodeID=\(String(describing: nodeID)); reattaching frame document root"
                )
                if let owner = attachProjectedFrameDocumentRoot(frameRoot, frameTargetID: frameTargetID) {
                    notifyDOMTreeChildrenReplaced(parent: owner)
                }
            } else {
                loadFrameDocumentIfNeeded(forFrameTargetID: frameTargetID, reason: "DOM.inspect")
            }
            return
        }
        WebInspectorDataKitLog.debug(
            "DOM.inspect unresolved nodeID=\(String(describing: nodeID)); waiting for DOM.requestNode path materialization"
        )
    }

    private func selectInspectedNode(_ node: DOMNode) {
        WebInspectorDataKitLog.debug("DOM.inspect selecting resolved nodeID=\(String(describing: node.id))")
        select(node)
        let pageGeneration = currentPageGeneration
        let documentGeneration = domDocumentGeneration
        let nodeID = node.id
        pageHighlightMaintenanceTask = Task { [weak self] in
            guard Task.isCancelled == false,
                  let self,
                  self.isCurrentPageGeneration(pageGeneration),
                  self.isDOMDocumentGeneration(documentGeneration),
                  self.selectedNode?.id == nodeID,
                  let selectedNode = self.nodesByID[nodeID] else {
                return
            }
            do {
                try await self.highlight(selectedNode)
            } catch is CancellationError {
                return
            } catch {
                self.failIfTerminal(error, operation: "DOM.highlightNode after DOM.inspect")
            }
        }
    }
}

extension WebInspectorContext {
    private struct SelectedStylePayloads {
        var matchedStyles: CSS.MatchedStyles
        var inlineStyles: CSS.InlineStyles
        var computedProperties: [CSS.ComputedProperty]
    }

    func apply(_ event: CSS.Event) {
        switch event {
        case let .styleSheetChanged(id):
            cssStyleSheets.advanceContentRevision(id)
            markSelectedStylesNeedsRefresh()
        case .mediaQueryResultChanged:
            markSelectedStylesNeedsRefresh()
        case let .styleSheetAdded(header):
            cssStyleSheets.record(header)
            markSelectedStylesNeedsRefresh()
        case let .styleSheetRemoved(id):
            cssStyleSheets.invalidate(id)
            markSelectedStylesNeedsRefresh()
        case let .nodeLayoutFlagsChanged(id):
            markSelectedStylesNeedsRefresh(for: DOMNode.ID(id))
        case .unknown:
            break
        }
    }

    private func refreshSelectedStyles() {
        styleRefreshTask?.cancel()
        styleRefreshTask = nil

        guard let selectedNode else {
            return
        }
        guard selectedNode.nodeType == 1 else {
            selectedNode.setElementStyles(nil)
            return
        }

        let styles = selectedNode.elementStyles ?? CSSStyles(nodeID: selectedNode.id, modelContext: self)
        selectedNode.setElementStyles(styles)
        styleRefreshGeneration += 1
        let generation = styleRefreshGeneration
        styles.markLoading(generation: generation)
        styleRefreshTask = Task { [weak self, weak selectedNode, styles] in
            guard let self, let selectedNode else {
                return
            }
            await self.loadStyles(for: selectedNode, into: styles, generation: generation)
        }
    }

    private func loadStyles(
        for node: DOMNode,
        into styles: CSSStyles,
        generation: Int
    ) async {
        guard isCurrentStyleRefresh(node: node, generation: generation) else {
            styles.cancelLoading(generation: generation)
            return
        }
        guard currentPage != nil else {
            styles.markUnavailable(generation: generation)
            return
        }

        do {
            let target = try domTarget(owning: node.id.proxyID)
            try await withExclusiveCSSOperation(on: target) {
                guard isCurrentStyleRefresh(node: node, generation: generation) else {
                    styles.cancelLoading(generation: generation)
                    return
                }
                guard try await styleTrackingLeases.ensure(on: target) else {
                    styles.markUnavailable(generation: generation)
                    return
                }
                guard isCurrentStyleRefresh(node: node, generation: generation) else {
                    styles.cancelLoading(generation: generation)
                    return
                }
                guard let payloads = try await selectedStylePayloads(
                    for: node,
                    target: target,
                    generation: generation
                ) else {
                    styles.cancelLoading(generation: generation)
                    return
                }
                styles.load(
                    matchedStyles: payloads.matchedStyles,
                    inlineStyles: payloads.inlineStyles,
                    computedProperties: payloads.computedProperties,
                    generation: generation
                )
            }
        } catch is CancellationError {
            styles.cancelLoading(generation: generation)
        } catch let error as WebInspectorProxyError {
            styles.fail(error, generation: generation)
        } catch {
            styles.fail(.commandFailed(
                domain: "CSS",
                method: "getMatchedStylesForNode/getInlineStylesForNode/getComputedStyleForNode",
                message: String(describing: error)
            ), generation: generation)
        }
    }

    #if DEBUG
    package func waitForQueuedCSSOperationCountForTesting(
        _ count: Int,
        for target: WebInspectorTarget
    ) async throws {
        try await cssOperationGate.waitForQueuedOperationCount(count, for: target.id)
    }
    #endif

    private func withExclusiveCSSOperation<Output>(
        on target: WebInspectorTarget,
        _ operation: () async throws -> Output
    ) async throws -> Output {
        try await cssOperationGate.acquire(targetID: target.id)
        do {
            try Task.checkCancellation()
            let output = try await operation()
            await cssOperationGate.release(targetID: target.id)
            return output
        } catch {
            await cssOperationGate.release(targetID: target.id)
            throw error
        }
    }

    private func selectedStylePayloads(
        for node: DOMNode,
        target: WebInspectorTarget,
        generation: Int
    ) async throws -> SelectedStylePayloads? {
        let matchedStyles = try await target.css.matchedStyles(for: node.id.proxyID)
        guard isCurrentStyleRefresh(node: node, generation: generation) else {
            return nil
        }
        let inlineStyles = try await target.css.inlineStyles(for: node.id.proxyID)
        guard isCurrentStyleRefresh(node: node, generation: generation) else {
            return nil
        }
        let computedProperties = try await target.css.computedStyle(for: node.id.proxyID)
        guard isCurrentStyleRefresh(node: node, generation: generation) else {
            return nil
        }
        return SelectedStylePayloads(
            matchedStyles: matchedStyles,
            inlineStyles: inlineStyles,
            computedProperties: computedProperties
        )
    }

    private func isCurrentStyleRefresh(node: DOMNode, generation: Int) -> Bool {
        Task.isCancelled == false && selectedNode === node && styleRefreshGeneration == generation
    }

    /// Reports whether the style pane is visible. While active, stale
    /// selected-node styles (`.needsRefresh`) re-fetch immediately; while
    /// inactive they stay stale until the next activation or selection.
    public func setStyleHydrationActive(_ active: Bool) {
        guard isStyleHydrationActive != active else {
            return
        }
        isStyleHydrationActive = active
        guard active, let styles = selectedNode?.elementStyles else {
            return
        }
        switch styles.phase {
        case .needsRefresh, .failed:
            refreshSelectedStyles()
        case .loading, .loaded, .unavailable:
            break
        }
    }

    package func styles(for nodeID: DOMNode.ID) throws -> CSSStyles {
        let node = try requiredNode(for: nodeID)
        guard node.nodeType == 1 else {
            throw WebInspectorProxyError.commandFailed(
                domain: "CSS",
                method: "getMatchedStylesForNode",
                message: "CSS styles are only available for element DOM nodes."
            )
        }
        if selectedNode !== node {
            select(node)
        }
        guard let styles = node.elementStyles else {
            throw WebInspectorProxyError.disconnected("CSS styles were not created for the selected node.")
        }
        return styles
    }

    package func refreshStyles(for nodeID: DOMNode.ID) throws -> CSSStyles {
        let styles = try styles(for: nodeID)
        refreshSelectedStyles()
        return styles
    }

    package func setCSSProperty(
        _ id: CSSStyleProperty.ID,
        enabled: Bool,
        options: WebInspectorMutationOptions
    ) async throws {
        let mutation = CSSStyleTextMutation.setProperty(enabled: enabled)
        guard styleToggleOperations[id] == nil,
              let node = selectedNode,
              let styles = node.elementStyles,
              let submittedDeclaration = mutation.submittedDeclaration(
                  in: styles,
                  propertyID: id
              ) else {
            throw WebInspectorProxyError.commandFailed(
                domain: "CSS",
                method: "setStyleText",
                message: "CSS property is stale, already mutating, or not editable."
            )
        }

        let target = try cssTarget(owning: submittedDeclaration.styleID)
        let submissionAuthority = cssMutationAuthority(
            target: target,
            styleSheetID: submittedDeclaration.styleID.owningStyleSheetID,
            node: node,
            styles: styles
        )
        let operation = beginStyleToggleOperation(for: id)
        defer {
            finishStyleToggleOperation(for: id, operation: operation)
        }
        try await performCSSStyleTextMutation(
            mutation,
            propertyID: id,
            submittedDeclaration: submittedDeclaration,
            node: node,
            styles: styles,
            target: target,
            submissionAuthority: submissionAuthority,
            operation: operation,
            options: options
        )
    }

    package func setCSSDeclarationText(
        _ text: String,
        for id: CSSStyleProperty.ID,
        options: WebInspectorMutationOptions
    ) async throws {
        let mutation = CSSStyleTextMutation.setDeclarationText(text)
        guard styleToggleOperations[id] == nil,
              let node = selectedNode,
              let styles = node.elementStyles,
              let submittedDeclaration = mutation.submittedDeclaration(
                  in: styles,
                  propertyID: id
              ) else {
            throw WebInspectorProxyError.commandFailed(
                domain: "CSS",
                method: "setStyleText",
                message: "CSS declaration is stale, already mutating, or not editable."
            )
        }

        let target = try cssTarget(owning: submittedDeclaration.styleID)
        let submissionAuthority = cssMutationAuthority(
            target: target,
            styleSheetID: submittedDeclaration.styleID.owningStyleSheetID,
            node: node,
            styles: styles
        )
        let operation = beginStyleToggleOperation(for: id)
        defer {
            finishStyleToggleOperation(for: id, operation: operation)
        }
        try await performCSSStyleTextMutation(
            mutation,
            propertyID: id,
            submittedDeclaration: submittedDeclaration,
            node: node,
            styles: styles,
            target: target,
            submissionAuthority: submissionAuthority,
            operation: operation,
            options: options
        )
    }

    package func setCSSRuleSelector(
        _ selector: String,
        for id: CSSStyleRule.ID,
        options: WebInspectorMutationOptions
    ) async throws {
        let proxyID = id.proxyID
        let target = try cssTarget(owning: proxyID)
        let submissionAuthority = cssMutationAuthority(
            target: target,
            styleSheetID: proxyID.owningStyleSheetID,
            tracksStyleSheetContentRevision: true
        )
        try await withExclusiveCSSOperation(on: target) {
            try validateCSSMutationAuthority(submissionAuthority)
            let commandAuthority = cssMutationAuthority(
                target: target,
                styleSheetID: proxyID.owningStyleSheetID
            )
            _ = try await target.css.setRuleSelector(proxyID, selector: selector)
            try validateCSSMutationAuthority(commandAuthority)
            try await Self.markDOMUndoableStateIfNeeded(on: target, options: options)
            try validateCSSMutationAuthority(commandAuthority)
            recordDOMEditHistoryTarget(target, options: options)
        }
        refreshSelectedStylesIfHydrationActive()
    }

    package func setCSSStyleSheetText(
        _ text: String,
        for id: CSS.StyleSheet.ID,
        options: WebInspectorMutationOptions
    ) async throws {
        let target = try cssTarget(owning: id)
        let submissionAuthority = cssMutationAuthority(target: target, styleSheetID: id)
        try await withExclusiveCSSOperation(on: target) {
            try validateCSSMutationAuthority(submissionAuthority)
            let commandAuthority = cssMutationAuthority(target: target, styleSheetID: id)
            try await target.css.setStyleSheetText(id, text: text)
            try validateCSSMutationAuthority(commandAuthority)
            cssStyleSheets.advanceContentRevision(id)
            markSelectedStylesNeedsRefresh()
            try await Self.markDOMUndoableStateIfNeeded(on: target, options: options)
            try validateCSSMutationAuthority(commandAuthority)
            recordDOMEditHistoryTarget(target, options: options)
        }
    }

    /// Toggles a CSS declaration on or off by rewriting its owning style
    /// text. Returns false without queuing a command when the property is not
    /// editable in the last materialized styles, or when a toggle for the same
    /// property is already in flight. A pending or stale refresh is completed
    /// before the command text is rebuilt from current declarations.
    @discardableResult
    public func requestSetCSSProperty(
        _ id: CSSStyleProperty.ID,
        enabled: Bool,
        options: WebInspectorMutationOptions
    ) -> Bool {
        let mutation = CSSStyleTextMutation.setProperty(enabled: enabled)
        guard styleToggleOperations[id] == nil,
              let node = selectedNode,
              let styles = node.elementStyles,
              let submittedDeclaration = mutation.submittedDeclaration(
                  in: styles,
                  propertyID: id
              ) else {
            return false
        }
        let target: WebInspectorTarget
        do {
            target = try cssTarget(owning: submittedDeclaration.styleID)
        } catch {
            failIfTerminal(error, operation: "CSS.setStyleText")
            return false
        }
        let submissionAuthority = cssMutationAuthority(
            target: target,
            styleSheetID: submittedDeclaration.styleID.owningStyleSheetID,
            node: node,
            styles: styles
        )
        let operation = beginStyleToggleOperation(for: id)
        let weakContext = WeakContextReference(self)
        let operationGate = cssOperationGate

        let task = Task { [target, styles, submissionAuthority, operation, weakContext, operationGate] in
            do {
                try Task.checkCancellation()
                try await Self.performRequestedCSSStyleTextMutation(
                    mutation,
                    propertyID: id,
                    submittedDeclaration: submittedDeclaration,
                    node: node,
                    styles: styles,
                    target: target,
                    submissionAuthority: submissionAuthority,
                    operation: operation,
                    options: options,
                    context: weakContext,
                    operationGate: operationGate
                )
                weakContext.withContextIfPresent {
                    $0.finishStyleToggleOperation(for: id, operation: operation)
                }
            } catch is CancellationError {
                weakContext.withContextIfPresent {
                    $0.finishStyleToggleOperation(for: id, operation: operation)
                }
            } catch let error as WebInspectorProxyError where error == Self.staleCSSMutationError {
                weakContext.withContextIfPresent {
                    $0.finishStyleToggleOperation(for: id, operation: operation)
                }
            } catch {
                weakContext.withContextIfPresent { context in
                    let isCurrent = context.isCurrentStyleToggleOperation(
                        for: id,
                        operation: operation
                    )
                    context.finishStyleToggleOperation(for: id, operation: operation)
                    guard isCurrent, Task.isCancelled == false else {
                        return
                    }
                    context.failIfTerminal(error, operation: "CSS.setStyleText")
                    context.refreshSelectedStyles()
                }
            }
        }
        if styleToggleOperations[id] === operation {
            operation.task = task
        } else {
            task.cancel()
        }
        return true
    }

    private static func performRequestedCSSStyleTextMutation(
        _ mutation: CSSStyleTextMutation,
        propertyID: CSSStyleProperty.ID,
        submittedDeclaration: CSSDeclarationIdentity,
        node: DOMNode,
        styles: CSSStyles,
        target: WebInspectorTarget,
        submissionAuthority: CSSMutationAuthority,
        operation: StyleToggleOperation,
        options: WebInspectorMutationOptions,
        context: WeakContextReference,
        operationGate: CSSOperationGate
    ) async throws {
        try await operationGate.acquire(targetID: target.id)
        do {
            try await refreshRequestedCSSStylesForMutationIfNeeded(
                node: node,
                styles: styles,
                target: target,
                submissionAuthority: submissionAuthority,
                propertyID: propertyID,
                operation: operation,
                context: context
            )
            let (intent, commandAuthority) = try context.withContext { context in
                try context.validateCSSMutationAuthority(submissionAuthority)
                try context.validateStyleToggleOperation(propertyID, operation: operation)
                guard let intent = mutation.intent(
                    in: styles,
                    declaration: submittedDeclaration
                ),
                      try context.cssTarget(owning: intent.styleID).id == target.id else {
                    throw WebInspectorProxyError.commandFailed(
                        domain: "CSS",
                        method: "setStyleText",
                        message: "CSS declaration changed before the queued mutation could run."
                    )
                }
                return (
                    intent,
                    context.cssMutationAuthority(
                        target: target,
                        styleSheetID: intent.styleID.owningStyleSheetID,
                        node: node,
                        styles: styles
                    )
                )
            }

            let result = try await target.css.setStyleText(intent.styleID, text: intent.text)
            try context.withContext { context in
                try context.validateCSSMutationAuthority(commandAuthority)
                try context.validateStyleToggleOperation(propertyID, operation: operation)
            }
            try await markDOMUndoableStateIfNeeded(on: target, options: options)
            try context.withContext { context in
                try context.validateCSSMutationAuthority(commandAuthority)
                try context.validateStyleToggleOperation(propertyID, operation: operation)
                context.recordDOMEditHistoryTarget(target, options: options)
                styles.applySetStyleText(result: result, for: propertyID)
                context.refreshSelectedStylesIfHydrationActive()
            }
            await operationGate.release(targetID: target.id)
        } catch {
            await operationGate.release(targetID: target.id)
            throw error
        }
    }

    private static func refreshRequestedCSSStylesForMutationIfNeeded(
        node: DOMNode,
        styles: CSSStyles,
        target: WebInspectorTarget,
        submissionAuthority: CSSMutationAuthority,
        propertyID: CSSStyleProperty.ID,
        operation: StyleToggleOperation,
        context: WeakContextReference
    ) async throws {
        let generation = try context.withContext { context in
            try context.validateCSSMutationAuthority(submissionAuthority)
            try context.validateStyleToggleOperation(propertyID, operation: operation)
            return try context.beginCSSStylesRefreshForMutationIfNeeded(styles)
        }
        guard let generation else {
            return
        }

        // Submission requires a previously materialized editable declaration,
        // which proves this target already owns an active style-tracking lease.
        // Reacquiring here would create a second lease owner for the same pane.
        do {
            let matchedStyles = try await target.css.matchedStyles(for: node.id.proxyID)
            try context.withContext {
                try $0.validateRequestedCSSStyleRefresh(
                    node: node,
                    generation: generation,
                    submissionAuthority: submissionAuthority,
                    propertyID: propertyID,
                    operation: operation
                )
            }
            let inlineStyles = try await target.css.inlineStyles(for: node.id.proxyID)
            try context.withContext {
                try $0.validateRequestedCSSStyleRefresh(
                    node: node,
                    generation: generation,
                    submissionAuthority: submissionAuthority,
                    propertyID: propertyID,
                    operation: operation
                )
            }
            let computedProperties = try await target.css.computedStyle(for: node.id.proxyID)
            try context.withContext { context in
                try context.validateRequestedCSSStyleRefresh(
                    node: node,
                    generation: generation,
                    submissionAuthority: submissionAuthority,
                    propertyID: propertyID,
                    operation: operation
                )
                styles.load(
                    matchedStyles: matchedStyles,
                    inlineStyles: inlineStyles,
                    computedProperties: computedProperties,
                    generation: generation
                )
            }
        } catch is CancellationError {
            styles.cancelLoading(generation: generation)
            throw CancellationError()
        } catch let error as WebInspectorProxyError {
            if error == staleCSSMutationError {
                styles.cancelLoading(generation: generation)
            } else {
                styles.fail(error, generation: generation)
            }
            throw error
        } catch {
            let proxyError = WebInspectorProxyError.commandFailed(
                domain: "CSS",
                method: "getMatchedStylesForNode/getInlineStylesForNode/getComputedStyleForNode",
                message: String(describing: error)
            )
            styles.fail(proxyError, generation: generation)
            throw proxyError
        }
    }

    private func performCSSStyleTextMutation(
        _ mutation: CSSStyleTextMutation,
        propertyID: CSSStyleProperty.ID,
        submittedDeclaration: CSSDeclarationIdentity,
        node: DOMNode,
        styles: CSSStyles,
        target: WebInspectorTarget,
        submissionAuthority: CSSMutationAuthority,
        operation: StyleToggleOperation,
        options: WebInspectorMutationOptions
    ) async throws {
        try await withExclusiveCSSOperation(on: target) {
            try validateCSSMutationAuthority(submissionAuthority)
            try validateStyleToggleOperation(propertyID, operation: operation)
            try await refreshCSSStylesForMutationIfNeeded(
                node: node,
                styles: styles,
                target: target
            )
            try validateCSSMutationAuthority(submissionAuthority)
            try validateStyleToggleOperation(propertyID, operation: operation)
            guard let intent = mutation.intent(
                in: styles,
                declaration: submittedDeclaration
            ),
                  try cssTarget(owning: intent.styleID).id == target.id else {
                throw WebInspectorProxyError.commandFailed(
                    domain: "CSS",
                    method: "setStyleText",
                    message: "CSS declaration changed before the queued mutation could run."
                )
            }
            let commandAuthority = cssMutationAuthority(
                target: target,
                styleSheetID: intent.styleID.owningStyleSheetID,
                node: node,
                styles: styles
            )
            let result = try await target.css.setStyleText(intent.styleID, text: intent.text)
            try validateCSSMutationAuthority(commandAuthority)
            try validateStyleToggleOperation(propertyID, operation: operation)
            try await Self.markDOMUndoableStateIfNeeded(on: target, options: options)
            try validateCSSMutationAuthority(commandAuthority)
            try validateStyleToggleOperation(propertyID, operation: operation)
            recordDOMEditHistoryTarget(target, options: options)
            styles.applySetStyleText(result: result, for: propertyID)
        }
        refreshSelectedStylesIfHydrationActive()
    }

    private func refreshCSSStylesForMutationIfNeeded(
        node: DOMNode,
        styles: CSSStyles,
        target: WebInspectorTarget
    ) async throws {
        guard let generation = try beginCSSStylesRefreshForMutationIfNeeded(styles) else {
            return
        }

        do {
            guard try await styleTrackingLeases.ensure(on: target) else {
                styles.markUnavailable(generation: generation)
                throw WebInspectorProxyError.commandFailed(
                    domain: "CSS",
                    method: "setStyleText",
                    message: "CSS tracking is unavailable for the selected target."
                )
            }
            guard let payloads = try await selectedStylePayloads(
                for: node,
                target: target,
                generation: generation
            ) else {
                styles.cancelLoading(generation: generation)
                throw Self.staleCSSMutationError
            }
            styles.load(
                matchedStyles: payloads.matchedStyles,
                inlineStyles: payloads.inlineStyles,
                computedProperties: payloads.computedProperties,
                generation: generation
            )
        } catch is CancellationError {
            styles.cancelLoading(generation: generation)
            throw CancellationError()
        } catch let error as WebInspectorProxyError {
            if error != Self.staleCSSMutationError {
                styles.fail(error, generation: generation)
            }
            throw error
        } catch {
            let proxyError = WebInspectorProxyError.commandFailed(
                domain: "CSS",
                method: "getMatchedStylesForNode/getInlineStylesForNode/getComputedStyleForNode",
                message: String(describing: error)
            )
            styles.fail(proxyError, generation: generation)
            throw proxyError
        }
    }

    private func beginCSSStylesRefreshForMutationIfNeeded(
        _ styles: CSSStyles
    ) throws -> Int? {
        switch styles.phase {
        case .loaded:
            return nil
        case .loading, .needsRefresh:
            break
        case .unavailable, .failed:
            throw WebInspectorProxyError.commandFailed(
                domain: "CSS",
                method: "setStyleText",
                message: "Current CSS declarations are unavailable."
            )
        }

        styleRefreshTask?.cancel()
        styleRefreshTask = nil
        styleRefreshGeneration += 1
        let generation = styleRefreshGeneration
        styles.markLoading(generation: generation)
        return generation
    }

    private func validateRequestedCSSStyleRefresh(
        node: DOMNode,
        generation: Int,
        submissionAuthority: CSSMutationAuthority,
        propertyID: CSSStyleProperty.ID,
        operation: StyleToggleOperation
    ) throws {
        try validateCSSMutationAuthority(submissionAuthority)
        try validateStyleToggleOperation(propertyID, operation: operation)
        guard isCurrentStyleRefresh(node: node, generation: generation) else {
            throw Self.staleCSSMutationError
        }
    }

    private static var staleCSSMutationError: WebInspectorProxyError {
        .disconnected("CSS mutation no longer belongs to the current document.")
    }

    private func cssMutationAuthority(
        target: WebInspectorTarget,
        styleSheetID: CSS.StyleSheet.ID?,
        tracksStyleSheetContentRevision: Bool = false,
        node: DOMNode? = nil,
        styles: CSSStyles? = nil
    ) -> CSSMutationAuthority {
        CSSMutationAuthority(
            pageGeneration: currentPageGeneration,
            documentGeneration: domDocumentGeneration,
            targetID: target.id,
            targetRevision: targetRevision(for: target.id),
            isCurrentPage: target.id == currentPage?.id,
            pageBindingID: target.pageBindingID,
            node: node,
            styles: styles,
            styleSheet: styleSheetID.map { id in
                CSSMutationAuthority.StyleSheet(
                    id: id,
                    revision: cssStyleSheets.revision(of: id),
                    contentRevision: tracksStyleSheetContentRevision
                        ? cssStyleSheets.contentRevision(of: id)
                        : nil
                )
            }
        )
    }

    private func validateCSSMutationAuthority(_ authority: CSSMutationAuthority) throws {
        try Task.checkCancellation()
        guard authority.pageGeneration == currentPageGeneration,
              authority.documentGeneration == domDocumentGeneration,
              authority.targetRevision == targetRevision(for: authority.targetID) else {
            throw Self.staleCSSMutationError
        }
        if let styleSheet = authority.styleSheet,
           styleSheet.revision != cssStyleSheets.revision(of: styleSheet.id) {
            throw Self.staleCSSMutationError
        }
        if let styleSheet = authority.styleSheet,
           let contentRevision = styleSheet.contentRevision,
           contentRevision != cssStyleSheets.contentRevision(of: styleSheet.id) {
            throw Self.staleCSSMutationError
        }
        if authority.isCurrentPage {
            guard currentPage?.id == authority.targetID,
                  currentPage?.pageBindingID == authority.pageBindingID else {
                throw Self.staleCSSMutationError
            }
        }
        if let node = authority.node,
           let styles = authority.styles {
            guard nodesByID[node.id] === node,
                  selectedNode === node,
                  node.elementStyles === styles else {
                throw Self.staleCSSMutationError
            }
        }
    }

    private func beginStyleToggleOperation(for id: CSSStyleProperty.ID) -> StyleToggleOperation {
        let operation = StyleToggleOperation()
        styleToggleOperations[id] = operation
        return operation
    }

    private func isCurrentStyleToggleOperation(
        for id: CSSStyleProperty.ID,
        operation: StyleToggleOperation
    ) -> Bool {
        styleToggleOperations[id] === operation
    }

    private func validateStyleToggleOperation(
        _ id: CSSStyleProperty.ID,
        operation: StyleToggleOperation
    ) throws {
        guard isCurrentStyleToggleOperation(for: id, operation: operation) else {
            throw Self.staleCSSMutationError
        }
    }

    private func finishStyleToggleOperation(
        for id: CSSStyleProperty.ID,
        operation: StyleToggleOperation
    ) {
        guard styleToggleOperations[id] === operation else {
            return
        }
        operation.task = nil
        styleToggleOperations[id] = nil
    }

    private func cancelStyleToggleOperations() {
        for operation in styleToggleOperations.values {
            operation.task?.cancel()
            operation.task = nil
        }
        styleToggleOperations = [:]
    }

    private func refreshSelectedStylesIfHydrationActive() {
        guard isStyleHydrationActive else {
            return
        }
        refreshSelectedStyles()
    }

    private func markSelectedStylesNeedsRefresh(
        for nodeID: DOMNode.ID
    ) {
        guard selectedNode?.id == nodeID else {
            return
        }
        markSelectedStylesNeedsRefresh()
    }

    private func markSelectedStylesNeedsRefresh() {
        styleRefreshGeneration += 1
        guard let styles = selectedNode?.elementStyles else {
            return
        }
        styles.markNeedsRefresh()
        refreshSelectedStylesIfHydrationActive()
    }
}

extension WebInspectorContext {
    func apply(
        _ event: Console.Event,
        targetID: WebInspectorTarget.ID? = nil
    ) {
        consoleStore.apply(
            event,
            targetID: targetID,
            page: currentPage,
            pageGeneration: currentPageGeneration
        )
    }

    func apply(
        _ event: Runtime.Event,
        targetID: WebInspectorTarget.ID? = nil
    ) {
        runtimeStore.apply(event, targetID: targetID, page: currentPage)
    }
}

extension WebInspectorContext {
    @discardableResult
    package func seedNetworkRequest(
        requestID rawRequestID: String,
        url: String,
        method: String = "GET",
        resourceTypeRawValue: String?,
        requestHeaders: [String: String] = [:],
        postData: String? = nil,
        responseMIMEType: String,
        responseStatus: Int,
        responseStatusText: String,
        responseHeaders: [String: String] = [:],
        responseBody: String? = nil,
        timestamp: Double,
        encodedBodyLength: Int = 0
    ) -> NetworkRequest.ID {
        return networkRecorder.seedNetworkRequest(
            requestID: rawRequestID,
            url: url,
            method: method,
            resourceTypeRawValue: resourceTypeRawValue,
            requestHeaders: requestHeaders,
            postData: postData,
            responseMIMEType: responseMIMEType,
            responseStatus: responseStatus,
            responseStatusText: responseStatusText,
            responseHeaders: responseHeaders,
            responseBody: responseBody,
            timestamp: timestamp,
            encodedBodyLength: encodedBodyLength
        )
    }

    package func seedResponseBody(
        for requestID: NetworkRequest.ID,
        body: String,
        base64Encoded: Bool = false,
        size: Int? = nil,
        isTruncated: Bool = false
    ) {
        networkRecorder.seedResponseBody(
            for: requestID,
            body: body,
            base64Encoded: base64Encoded,
            size: size,
            isTruncated: isTruncated
        )
    }

    package func apply(_ event: Network.Event) {
        networkRecorder.apply(event)
    }
}
