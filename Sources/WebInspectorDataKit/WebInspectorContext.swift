import Foundation
import WebInspectorProxyKit

/// The identity-preserving model context for an inspected page.
///
/// A context owns observable DOM, Network, Console, Runtime, and CSS models.
/// It is isolated to the actor passed at initialization; callers must use the
/// same actor when reading or mutating context-owned state.
public final class WebInspectorContext {
    package struct DOMUndoRedoCommands {
        private weak var store: DOMStateStore?
        private let target: WebInspectorTarget?
        private let fallbackTarget: WebInspectorTarget?
        private let documentEpoch: Int

        fileprivate init(
            store: DOMStateStore,
            target: WebInspectorTarget?,
            fallbackTarget: WebInspectorTarget?,
            documentEpoch: Int
        ) {
            self.store = store
            self.target = target
            self.fallbackTarget = fallbackTarget
            self.documentEpoch = documentEpoch
        }

        package func undo(isolation: isolated (any Actor) = #isolation) async throws {
            try await undoRedoTarget(isolation: isolation).dom.undo()
        }

        package func redo(isolation: isolated (any Actor) = #isolation) async throws {
            try await undoRedoTarget(isolation: isolation).dom.redo()
        }

        private func undoRedoTarget(isolation: isolated (any Actor)) throws -> WebInspectorTarget {
            guard let store else {
                throw WebInspectorProxyError.disconnected("WebInspectorDataKit context was released before DOM undo/redo.")
            }
            return try store.undoRedoTarget(
                capturedTarget: target,
                fallbackTarget: fallbackTarget,
                documentEpoch: documentEpoch,
                isolation: isolation
            )
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

    private enum RuntimeObjectOwner: Hashable {
        case client
        case console
    }

    private typealias LoadedDOMDocument = (node: DOM.Node, generation: Int)

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
    private let owner: any Actor
    private let domState: DOMStateStore
    /// The current attachment state.
    public private(set) var state: State

    /// The terminal teardown error, if the context failed or detached because
    /// of an inspector error.
    public private(set) var teardownError: WebInspectorProxyError?

    /// The current root DOM node, if a document is loaded.
    public var rootNode: DOMNode? {
        domState.rootNode
    }

    /// The currently selected DOM node.
    public var selectedNode: DOMNode? {
        domState.selectedNode
    }

    /// A Boolean value indicating whether WebKit inspect mode is enabled.
    public var isElementPickerEnabled: Bool {
        domState.isElementPickerEnabled
    }

    /// Runtime execution contexts known to the current page.
    public private(set) var executionContexts: [RuntimeContext]

    /// The selected Runtime execution context.
    public private(set) var selectedContext: RuntimeContext?

    private var currentPage: WebInspectorTarget?
    private var currentPageGeneration: Int
    private var startupTask: Task<Void, Never>?
    private var currentPageRetargetTask: Task<Void, Never>?
    private var currentPageCleanupTask: Task<Void, Never>?
    private var documentReloadTask: Task<Void, Never>?
    private var inspectedNodeHighlightTask: Task<Void, Never>?
    private var frameDocumentLoadTasks: [WebInspectorTarget.ID: Task<Void, Never>]
    private var styleRefreshTask: Task<Void, Never>?
    private var styleRefreshGeneration: Int
    private var isStyleHydrationActive: Bool
    private var styleToggleTasks: [CSSStyleProperty.ID: Task<Void, Never>]
    private var eventPumps: [WebInspectorEventPump]
#if DEBUG
    private var eventPumpAppliedSequenceForTestingStorage: UInt64
    private var eventPumpAppliedWaitersForTesting: [UInt64: EventPumpAppliedWaiterForTesting]
    private var nextEventPumpAppliedWaiterIDForTesting: UInt64
#endif
    private var inspectorTrackingTarget: WebInspectorTarget?
    private var networkTrackingTarget: WebInspectorTarget?
    private var runtimeTrackingTarget: WebInspectorTarget?
    private var consoleTrackingTarget: WebInspectorTarget?
    private let statusRelay: WebInspectorAsyncStreamRelay<Status>
    private let networkRequests: NetworkRequestStore
    private let consoleMessages: ConsoleMessageStore
    private var runtimeContextsByID: [RuntimeContext.ID: RuntimeContext]
    private var orderedRuntimeContextIDs: [RuntimeContext.ID]
    private var runtimeObjectsByID: [RuntimeObject.ID: RuntimeObject]
    private var runtimeObjectIDsByProxyID: [Runtime.RemoteObject.ID: RuntimeObject.ID]
    private var runtimeObjectOwnersByID: [RuntimeObject.ID: Set<RuntimeObjectOwner>]
    private var nextRuntimeObjectOrdinal: Int
    private var consoleObjectGroupReleaseTasks: [WebInspectorTarget.ID: Task<Void, Never>]

    /// Creates a context owned by the supplied actor.
    public init(_ container: WebInspectorContainer, isolation: isolated (any Actor)) {
        self.container = container
        proxy = container.proxy
        domainEnablement = container.domainEnablement
        owner = isolation
        domState = DOMStateStore()
        state = .attaching
        teardownError = nil
        executionContexts = []
        selectedContext = nil
        currentPage = nil
        currentPageGeneration = 0
        startupTask = nil
        currentPageRetargetTask = nil
        currentPageCleanupTask = nil
        documentReloadTask = nil
        inspectedNodeHighlightTask = nil
        frameDocumentLoadTasks = [:]
        styleRefreshTask = nil
        styleRefreshGeneration = 0
        isStyleHydrationActive = false
        styleToggleTasks = [:]
        eventPumps = []
#if DEBUG
        eventPumpAppliedSequenceForTestingStorage = 0
        eventPumpAppliedWaitersForTesting = [:]
        nextEventPumpAppliedWaiterIDForTesting = 0
#endif
        inspectorTrackingTarget = nil
        networkTrackingTarget = nil
        runtimeTrackingTarget = nil
        consoleTrackingTarget = nil
        statusRelay = WebInspectorAsyncStreamRelay()
        networkRequests = NetworkRequestStore()
        consoleMessages = ConsoleMessageStore()
        runtimeContextsByID = [:]
        orderedRuntimeContextIDs = []
        runtimeObjectsByID = [:]
        runtimeObjectIDsByProxyID = [:]
        runtimeObjectOwnersByID = [:]
        nextRuntimeObjectOrdinal = 0
        consoleObjectGroupReleaseTasks = [:]
        WebInspectorDataKitLog.debug("context state=\(state.logDescription)")
    }

    package static func preview(isolation: isolated (any Actor)) -> WebInspectorContext {
        let container = WebInspectorContainer(proxy: WebInspectorProxy())
        let context = WebInspectorContext(container, isolation: isolation)
        context.state = .attached
        return context
    }

    package static func detached(isolation: isolated (any Actor)) -> WebInspectorContext {
        let container = WebInspectorContainer(proxy: WebInspectorProxy())
        let context = WebInspectorContext(container, isolation: isolation)
        context.state = .detached
        return context
    }

    deinit {
        startupTask?.cancel()
        currentPageRetargetTask?.cancel()
        currentPageCleanupTask?.cancel()
        documentReloadTask?.cancel()
        inspectedNodeHighlightTask?.cancel()
        cancelFrameDocumentLoadTasks()
        styleRefreshTask?.cancel()
        for task in styleToggleTasks.values {
            task.cancel()
        }
        stopEventPumps()
        for task in consoleObjectGroupReleaseTasks.values {
            task.cancel()
        }
        resolveEventPumpAppliedWaitersForTesting(result: false)
    }

    /// Starts observing the inspected page and rebuilding DataKit models.
    public func start(isolation: isolated (any Actor) = #isolation) {
        requireOwner(isolation)
        let previousStartupTask = startupTask
        let previousCurrentPageCleanupTask = currentPageCleanupTask
        previousStartupTask?.cancel()
        currentPageRetargetTask?.cancel()
        currentPageRetargetTask = nil
        state = .attaching
        notifyStatusChanged()
        teardownError = nil
        resetNetworkModelsForNewAttachment(isolation: isolation)
        startupTask = Task { [weak self, previousStartupTask, previousCurrentPageCleanupTask] in
            _ = isolation
            await previousStartupTask?.value
            await previousCurrentPageCleanupTask?.value
            guard Task.isCancelled == false else {
                return
            }
            guard let self else {
                return
            }
            await self.startup(isolation: isolation)
        }
    }

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
    public func node(for id: DOMNode.ID, isolation: isolated (any Actor) = #isolation) -> DOMNode? {
        requireOwner(isolation)
        return domState.node(for: id, isolation: isolation)
    }

    package func requiredNode(for id: DOMNode.ID, isolation: isolated (any Actor) = #isolation) throws -> DOMNode {
        requireOwner(isolation)
        return try domState.requiredNode(for: id, isolation: isolation)
    }

    /// Returns the registered Network request for an identifier.
    public func registeredRequest(
        for id: NetworkRequest.ID,
        isolation: isolated (any Actor) = #isolation
    ) -> NetworkRequest? {
        requireOwner(isolation)
        return networkRequests.request(for: id, isolation: isolation)
    }

    package var networkRequestsCollectionState: NetworkRequestCollectionState {
        networkRequests.collectionState
    }

    package func registeredRequest(
        forProxyID id: Network.Request.ID,
        isolation: isolated (any Actor) = #isolation
    ) -> NetworkRequest? {
        requireOwner(isolation)
        return networkRequests.request(forProxyID: id, isolation: isolation)
    }

    /// Clears retained Network requests and emits reset transactions.
    public func clearNetworkRequests(isolation: isolated (any Actor) = #isolation) {
        requireOwner(isolation)
        networkRequests.clear(isolation: isolation)
    }

    /// Returns the registered Console message for an identifier.
    public func registeredMessage(
        for id: ConsoleMessage.ID,
        isolation: isolated (any Actor) = #isolation
    ) -> ConsoleMessage? {
        requireOwner(isolation)
        return consoleMessages.message(for: id, isolation: isolation)
    }

    /// Selects a DOM node and reveals it in registered tree controllers.
    public func select(_ node: DOMNode?, isolation: isolated (any Actor) = #isolation) {
        select(node, reveal: .selectAndScroll, isolation: isolation)
    }

    private func select(
        _ node: DOMNode?,
        reveal: DOMRevealPolicy,
        isolation: isolated (any Actor)
    ) {
        requireOwner(isolation)
        inspectedNodeHighlightTask?.cancel()
        inspectedNodeHighlightTask = nil
        let effects = domState.select(node, reveal: reveal, isolation: isolation)
        applyDOMStateEffects(effects, isolation: isolation)
    }

    package func selectNode(_ id: DOMNode.ID, isolation: isolated (any Actor) = #isolation) throws {
        select(try requiredNode(for: id, isolation: isolation), isolation: isolation)
    }

    package func selectNode(
        _ id: DOMNode.ID?,
        reveal: DOMRevealPolicy,
        isolation: isolated (any Actor) = #isolation
    ) throws {
        guard let id else {
            select(nil, reveal: reveal, isolation: isolation)
            return
        }
        select(try requiredNode(for: id, isolation: isolation), reveal: reveal, isolation: isolation)
    }

    package func requestChildren(
        for id: DOMNode.ID,
        depth: Int = 1,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        try await requiredNode(for: id, isolation: isolation).requestChildren(depth: depth, isolation: isolation)
    }

    package func setDOMAttribute(
        _ name: String,
        value: String,
        on id: DOMNode.ID,
        options: WebInspectorMutationOptions,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        requireOwner(isolation)
        let node = try requiredNode(for: id, isolation: isolation)
        let target = try domTarget(owning: node.id.proxyID)
        try await target.dom.setAttributeValue(node.id.proxyID, name: name, value: value)
        recordDOMEditHistoryTarget(target, options: options)
        try await Self.markDOMUndoableStateIfNeeded(on: target, options: options)
    }

    package func setDOMOuterHTML(
        _ html: String,
        of id: DOMNode.ID,
        options: WebInspectorMutationOptions,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        requireOwner(isolation)
        let node = try requiredNode(for: id, isolation: isolation)
        let target = try domTarget(owning: node.id.proxyID)
        try await target.dom.setOuterHTML(node.id.proxyID, html: html)
        recordDOMEditHistoryTarget(target, options: options)
        try await Self.markDOMUndoableStateIfNeeded(on: target, options: options)
    }

    package func removeDOMNodes(
        _ nodeIDs: [DOMNode.ID],
        options: WebInspectorMutationOptions,
        isolation: isolated (any Actor) = #isolation
    ) async throws -> DOMMutationResult {
        requireOwner(isolation)
        let deletion = try domState.sortedDeletionNodes(for: nodeIDs, isolation: isolation)
        let sortedNodes = deletion.nodes
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
                    applyDOMStateEffects(
                        domState.clearSelectionIfDeleted(
                            acceptedNodeIDs,
                            snapshot: deletion.snapshot,
                            isolation: isolation
                        ),
                        isolation: isolation
                    )
                    throw DOMDeletionPartialFailure(
                        deletedNodeCount: acceptedNodeIDs.count,
                        underlyingError: error
                    )
                }
                throw error
            }
        }
        applyDOMStateEffects(
            domState.clearSelectionIfDeleted(
                acceptedNodeIDs,
                snapshot: deletion.snapshot,
                isolation: isolation
            ),
            isolation: isolation
        )
        return DOMMutationResult(requestedNodeIDs: nodeIDs, acceptedNodeIDs: acceptedNodeIDs)
    }

    /// Returns copied text for a DOM node in the requested format.
    public func copyText(
        _ kind: DOMNode.CopyTextKind,
        for node: DOMNode,
        isolation: isolated (any Actor) = #isolation
    ) async throws -> String {
        requireOwner(isolation)
        try registeredNode(node)
        switch kind {
        case .html:
            let page = try currentPageOrThrow()
            return try await page.dom.outerHTML(of: node.id.proxyID)
        case .selectorPath:
            return try domState.currentTreeSnapshot(
                containing: [node],
                isolation: isolation
            ).selectorPath(for: node.id)
        case .xPath:
            return try domState.currentTreeSnapshot(
                containing: [node],
                isolation: isolation
            ).xPath(for: node.id)
        }
    }

    package func copyText(
        _ kind: DOMNode.CopyTextKind,
        for id: DOMNode.ID,
        isolation: isolated (any Actor) = #isolation
    ) async throws -> String {
        try await copyText(kind, for: try requiredNode(for: id, isolation: isolation), isolation: isolation)
    }

    /// Removes one DOM node from the inspected document.
    public func delete(_ node: DOMNode, isolation: isolated (any Actor) = #isolation) async throws {
        try await delete([node], isolation: isolation)
    }

    /// Removes DOM nodes from the inspected document.
    public func delete(_ nodes: [DOMNode], isolation: isolated (any Actor) = #isolation) async throws {
        _ = try await deleteCountingRemovedNodes(nodes, isolation: isolation)
    }

    @discardableResult
    private func deleteCountingRemovedNodes(
        _ nodes: [DOMNode],
        isolation: isolated (any Actor) = #isolation
    ) async throws -> Int {
        requireOwner(isolation)
        let deletion = try domState.sortedDeletionNodes(for: nodes, isolation: isolation)
        let sortedNodes = deletion.nodes
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
                    applyDOMStateEffects(
                        domState.clearSelectionIfDeleted(
                            removedNodes.map(\.id),
                            snapshot: deletion.snapshot,
                            isolation: isolation
                        ),
                        isolation: isolation
                    )
                    throw DOMDeletionPartialFailure(
                        deletedNodeCount: removedNodes.count,
                        underlyingError: error
                    )
                }
                throw error
            }
        }
        applyDOMStateEffects(
            domState.clearSelectionIfDeleted(
                removedNodes.map(\.id),
                snapshot: deletion.snapshot,
                isolation: isolation
            ),
            isolation: isolation
        )
        return removedNodes.count
    }

    package func delete(nodeIDs: [DOMNode.ID], isolation: isolated (any Actor) = #isolation) async throws {
        _ = try await deleteCountingRemovedNodes(nodeIDs: nodeIDs, isolation: isolation)
    }

    @discardableResult
    package func deleteCountingRemovedNodes(
        nodeIDs: [DOMNode.ID],
        isolation: isolated (any Actor) = #isolation
    ) async throws -> Int {
        var seenNodeIDs: Set<DOMNode.ID> = []
        let nodes = try nodeIDs
            .filter { seenNodeIDs.insert($0).inserted }
            .map { try domState.requiredNode(for: $0, isolation: isolation) }
        return try await deleteCountingRemovedNodes(nodes, isolation: isolation)
    }

    #if DEBUG
    package func installCurrentPageRetargetTaskForTesting(_ task: Task<Void, Never>) {
        currentPageRetargetTask = task
    }

    package func startupTaskForTesting(isolation: isolated (any Actor) = #isolation) -> Task<Void, Never>? {
        requireOwner(isolation)
        return startupTask
    }

    package var eventPumpAppliedSequenceForTesting: UInt64 {
        eventPumpAppliedSequenceForTestingStorage
    }

    package func waitForEventPumpAppliedSequenceForTesting(
        after baselineSequence: UInt64,
        count: UInt64 = 1,
        isolation: isolated (any Actor) = #isolation
    ) async -> Bool {
        requireOwner(isolation)
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
    public func highlight(_ node: DOMNode, isolation: isolated (any Actor) = #isolation) async throws {
        requireOwner(isolation)
        try registeredNode(node)
        let page = try currentPageOrThrow()
        if node.id.proxyID.targetScopeRawValue == nil {
            domState.recordPageHighlight(isolation: isolation)
        }
        try await page.dom.highlightNode(node.id.proxyID)
    }

    package func highlightNode(for id: DOMNode.ID, isolation: isolated (any Actor) = #isolation) async throws {
        try await highlight(try requiredNode(for: id, isolation: isolation), isolation: isolation)
    }

    /// Clears the current DOM highlight in the inspected page.
    public func hideHighlight(isolation: isolated (any Actor) = #isolation) async throws {
        requireOwner(isolation)
        let page = try currentPageOrThrow()
        try await page.dom.hideHighlight()
        domState.clearPageHighlight(isolation: isolation)
    }

    package func domUndoRedoCommands(isolation: isolated (any Actor) = #isolation) throws -> DOMUndoRedoCommands {
        requireOwner(isolation)
        return DOMUndoRedoCommands(
            store: domState,
            target: domState.capturedEditHistoryTarget(isolation: isolation),
            fallbackTarget: currentPage,
            documentEpoch: domState.documentEpoch
        )
    }

    package func undoDOMChange(isolation: isolated (any Actor) = #isolation) async throws {
        try await domUndoRedoCommands(isolation: isolation).undo(isolation: isolation)
    }

    package func redoDOMChange(isolation: isolated (any Actor) = #isolation) async throws {
        try await domUndoRedoCommands(isolation: isolation).redo(isolation: isolation)
    }

    /// Enables or disables WebKit's element picker.
    public func setElementPickerEnabled(
        _ isEnabled: Bool,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        requireOwner(isolation)
        let page = try currentPageOrThrow()
        WebInspectorDataKitLog.debug(
            "DOM picker setInspectMode start enabled=\(isEnabled) target=\(page.id.rawValue)"
        )
        do {
            try await page.dom.setInspectMode(enabled: isEnabled)
        } catch {
            WebInspectorDataKitLog.debug(
                "DOM picker setInspectMode failed enabled=\(isEnabled) target=\(page.id.rawValue): \(String(describing: error))"
            )
            throw error
        }
        applyDOMStateEffects(
            domState.setElementPickerEnabled(isEnabled, isolation: isolation),
            isolation: isolation
        )
        WebInspectorDataKitLog.debug(
            "DOM picker setInspectMode finished enabled=\(isEnabled) target=\(page.id.rawValue)"
        )
    }

    /// Reloads the inspected page.
    public func reloadPage(
        ignoringCache: Bool = false,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        requireOwner(isolation)
        let page = try currentPageOrThrow()
        try await page.page.reload(ignoringCache: ignoringCache)
    }

    /// Returns a CSS selector path for a DOM node.
    public func selectorPath(for node: DOMNode, isolation: isolated (any Actor) = #isolation) throws -> String {
        requireOwner(isolation)
        try registeredNode(node)
        return try domState.currentTreeSnapshot(
            containing: [node],
            isolation: isolation
        ).selectorPath(for: node.id)
    }

    package func selectorPath(for id: DOMNode.ID, isolation: isolated (any Actor) = #isolation) throws -> String {
        try selectorPath(for: try requiredNode(for: id, isolation: isolation), isolation: isolation)
    }

    /// Returns an XPath expression for a DOM node.
    public func xPath(for node: DOMNode, isolation: isolated (any Actor) = #isolation) throws -> String {
        requireOwner(isolation)
        try registeredNode(node)
        return try domState.currentTreeSnapshot(
            containing: [node],
            isolation: isolation
        ).xPath(for: node.id)
    }

    package func xPath(for id: DOMNode.ID, isolation: isolated (any Actor) = #isolation) throws -> String {
        try xPath(for: try requiredNode(for: id, isolation: isolation), isolation: isolation)
    }

    /// Creates a live DOM tree controller rooted at a node or the document root.
    public func treeController(
        root requestedRoot: DOMNode? = nil,
        isolation: isolated (any Actor) = #isolation
    ) async throws -> DOMTreeController {
        requireOwner(isolation)
        return try domState.treeController(root: requestedRoot, isolation: isolation)
    }

    package func rootTreeController(isolation: isolated (any Actor) = #isolation) -> DOMTreeController {
        requireOwner(isolation)
        return domState.rootTreeController(isolation: isolation)
    }

    /// Selects the Runtime execution context used by default evaluation calls.
    public func selectContext(_ context: RuntimeContext?, isolation: isolated (any Actor) = #isolation) {
        requireOwner(isolation)
        guard let context else {
            selectedContext = nil
            return
        }
        guard runtimeContextsByID[context.id] === context else {
            preconditionFailure("RuntimeContext is not registered in this WebInspectorContext.")
        }
        selectedContext = context
    }

    /// Evaluates JavaScript in the selected or supplied Runtime context.
    public func evaluate(
        _ expression: String,
        in context: RuntimeContext? = nil,
        isolation: isolated (any Actor) = #isolation
    ) async throws -> RuntimeEvaluation {
        requireOwner(isolation)
        if let context, runtimeContextsByID[context.id] !== context {
            let error = WebInspectorProxyError.disconnected("RuntimeContext is not registered in this WebInspectorContext.")
            throw error
        }
        guard let currentPage else {
            throw WebInspectorProxyError.disconnected("WebInspectorDataKit has no current page target.")
        }

        let executionContext = context ?? selectedContext
        let result = try await currentPage.runtime.evaluate(expression, in: executionContext?.id.proxyID)
        return RuntimeEvaluation(
            object: registerRuntimeObject(result.object, owner: .client),
            isException: result.wasThrown
        )
    }

    /// Creates observable fetched results for a supported model type.
    public func fetchedResults<Model: WebInspectorFetchableModel>(
        for descriptor: WebInspectorFetchDescriptor<Model> = .init(),
        sectionBy: WebInspectorSectionDescriptor<Model>? = nil,
        isolation: isolated (any Actor) = #isolation
    ) -> WebInspectorFetchedResults<Model> {
        requireOwner(isolation)
        requireSupportedFetchDescriptor(descriptor)
        let results = WebInspectorFetchedResults(fetchDescriptor: descriptor, sectionBy: sectionBy, modelContext: self)
        switch descriptor.kind {
        case .networkRequests:
            guard let networkResults = results as? WebInspectorFetchedResults<NetworkRequest> else {
                preconditionFailure("NetworkRequest descriptors can only fetch NetworkRequest models.")
            }
            networkRequests.register(networkResults, modelContext: self, isolation: isolation)
        case .consoleMessages:
            guard let consoleResults = results as? WebInspectorFetchedResults<ConsoleMessage> else {
                preconditionFailure("ConsoleMessage descriptors can only fetch ConsoleMessage models.")
            }
            consoleMessages.register(consoleResults, modelContext: self, isolation: isolation)
        }
        return results
    }

    /// Creates observable fetched results from a mutable fetch request.
    public func fetchedResults<Model: WebInspectorFetchableModel>(
        for request: WebInspectorFetchRequest<Model>,
        sectionBy: WebInspectorSectionDescriptor<Model>? = nil,
        isolation: isolated (any Actor) = #isolation
    ) -> WebInspectorFetchedResults<Model> {
        fetchedResults(for: request.fetchDescriptor, sectionBy: sectionBy, isolation: isolation)
    }

    /// Creates observable fetched results sectioned by a string key path.
    public func fetchedResults<Model: WebInspectorFetchableModel>(
        for descriptor: WebInspectorFetchDescriptor<Model> = .init(),
        sectionBy keyPath: KeyPath<Model, String>,
        isolation: isolated (any Actor) = #isolation
    ) -> WebInspectorFetchedResults<Model> {
        fetchedResults(
            for: descriptor,
            sectionBy: WebInspectorSectionDescriptor(keyPath),
            isolation: isolation
        )
    }

    /// Creates observable fetched results sectioned by an optional string key path.
    public func fetchedResults<Model: WebInspectorFetchableModel>(
        for descriptor: WebInspectorFetchDescriptor<Model> = .init(),
        sectionBy keyPath: KeyPath<Model, String?>,
        isolation: isolated (any Actor) = #isolation
    ) -> WebInspectorFetchedResults<Model> {
        fetchedResults(
            for: descriptor,
            sectionBy: WebInspectorSectionDescriptor(keyPath),
            isolation: isolation
        )
    }

    /// Creates observable fetched results sectioned by a raw-representable string key path.
    public func fetchedResults<
        Model: WebInspectorFetchableModel,
        Value: RawRepresentable & Hashable & Sendable
    >(
        for descriptor: WebInspectorFetchDescriptor<Model> = .init(),
        sectionBy keyPath: KeyPath<Model, Value>,
        isolation: isolated (any Actor) = #isolation
    ) -> WebInspectorFetchedResults<Model> where Value.RawValue == String {
        fetchedResults(
            for: descriptor,
            sectionBy: WebInspectorSectionDescriptor(keyPath),
            isolation: isolation
        )
    }

    /// Creates observable fetched results sectioned by an optional raw-representable string key path.
    public func fetchedResults<
        Model: WebInspectorFetchableModel,
        Value: RawRepresentable & Hashable & Sendable
    >(
        for descriptor: WebInspectorFetchDescriptor<Model> = .init(),
        sectionBy keyPath: KeyPath<Model, Value?>,
        isolation: isolated (any Actor) = #isolation
    ) -> WebInspectorFetchedResults<Model> where Value.RawValue == String {
        fetchedResults(
            for: descriptor,
            sectionBy: WebInspectorSectionDescriptor(keyPath),
            isolation: isolation
        )
    }

    func updateFetchDescriptor<Model: WebInspectorFetchableModel>(
        _ descriptor: WebInspectorFetchDescriptor<Model>,
        for results: WebInspectorFetchedResults<Model>,
        isolation: isolated (any Actor) = #isolation
    ) {
        requireOwner(isolation)
        requireSupportedFetchDescriptor(descriptor)
        guard results.modelContext === self else {
            preconditionFailure("WebInspectorFetchedResults is not registered in this WebInspectorContext.")
        }
        switch descriptor.kind {
        case .networkRequests:
            guard let networkDescriptor = descriptor as? WebInspectorFetchDescriptor<NetworkRequest>,
                  let networkResults = results as? WebInspectorFetchedResults<NetworkRequest> else {
                preconditionFailure("NetworkRequest descriptors can only update NetworkRequest fetched results.")
            }
            networkRequests.updateFetchDescriptor(
                networkDescriptor,
                for: networkResults,
                modelContext: self,
                isolation: isolation
            )
        case .consoleMessages:
            guard let consoleDescriptor = descriptor as? WebInspectorFetchDescriptor<ConsoleMessage>,
                  let consoleResults = results as? WebInspectorFetchedResults<ConsoleMessage> else {
                preconditionFailure("ConsoleMessage descriptors can only update ConsoleMessage fetched results.")
            }
            consoleMessages.updateFetchDescriptor(
                consoleDescriptor,
                for: consoleResults,
                modelContext: self,
                isolation: isolation
            )
        }
    }

    private func requireSupportedFetchDescriptor<Model: WebInspectorFetchableModel>(
        _ descriptor: WebInspectorFetchDescriptor<Model>
    ) {
        if descriptor.kind == .networkRequests || descriptor.kind == .consoleMessages {
            return
        }
        guard descriptor.requiresRecordBackedQuery == false else {
            preconditionFailure(
                "Predicate, sort, limit, and offset fetch descriptors require a record-backed DataKit query index."
            )
        }
    }

    func fetchResponseBody(
        for request: NetworkRequest,
        expectedBody: NetworkBody,
        isolation: isolated (any Actor) = #isolation
    ) async {
        requireOwner(isolation)
        guard let currentPage else {
            finishResponseBodyFetch(
                .failure(.disconnected("WebInspectorDataKit has no current page target.")),
                for: request,
                expectedBody: expectedBody,
                isolation: isolation
            )
            return
        }

        do {
            let body = try await currentPage.network.responseBody(
                for: request.proxyID,
                backendResourceIdentifier: request.backendResourceIdentifier
            )
            finishResponseBodyFetch(
                .success(body),
                for: request,
                expectedBody: expectedBody,
                isolation: isolation
            )
        } catch let error as WebInspectorProxyError {
            finishResponseBodyFetch(
                .failure(error),
                for: request,
                expectedBody: expectedBody,
                isolation: isolation
            )
        } catch {
            finishResponseBodyFetch(
                .failure(.commandFailed(
                    domain: "Network",
                    method: "getResponseBody",
                    message: String(describing: error)
                )),
                for: request,
                expectedBody: expectedBody,
                isolation: isolation
            )
        }
    }

    private func finishResponseBodyFetch(
        _ result: Result<Network.Body, WebInspectorProxyError>,
        for request: NetworkRequest,
        expectedBody: NetworkBody,
        isolation: isolated (any Actor)
    ) {
        networkRequests.finishResponseBodyFetch(
            result,
            for: request,
            expectedBody: expectedBody,
            isolation: isolation
        )
    }

    func requestChildren(
        for node: DOMNode,
        depth: Int,
        isolation: isolated (any Actor) = #isolation
    ) async {
        requireOwner(isolation)
        guard (try? domState.registeredNode(node, isolation: isolation)) != nil else {
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
        for object: RuntimeObject,
        isolation: isolated (any Actor) = #isolation
    ) async throws -> [RuntimeObject.Property] {
        requireOwner(isolation)
        try registeredRuntimeObject(object)
        guard let proxyID = object.proxyID else {
            return []
        }
        guard let currentPage else {
            throw WebInspectorProxyError.disconnected("WebInspectorDataKit has no current page target.")
        }

        let descriptors = try await currentPage.runtime.properties(of: proxyID)
        return descriptors.map { descriptor in
            let remoteValue = descriptor.value
            let childObject = remoteValue.flatMap { value in
                value.id == nil ? nil : registerRuntimeObject(value, owner: .client)
            }
            return RuntimeObject.Property(
                name: descriptor.name,
                value: remoteValue.flatMap { runtimeValueText(for: $0) },
                object: childObject
            )
        }
    }

    func collectionEntries(
        for object: RuntimeObject,
        isolation: isolated (any Actor) = #isolation
    ) async throws -> [RuntimeObject.Entry] {
        requireOwner(isolation)
        try registeredRuntimeObject(object)
        guard let proxyID = object.proxyID else {
            return []
        }
        guard let currentPage else {
            throw WebInspectorProxyError.disconnected("WebInspectorDataKit has no current page target.")
        }

        let entries = try await currentPage.runtime.collectionEntries(of: proxyID)
        return entries.map { entry in
            RuntimeObject.Entry(
                key: entry.key.map { registerRuntimeObject($0, owner: .client) },
                value: registerRuntimeObject(entry.value, owner: .client)
            )
        }
    }

    @discardableResult
    private func registeredRuntimeObject(_ object: RuntimeObject) throws -> RuntimeObject {
        guard runtimeObjectsByID[object.id] === object else {
            let error = WebInspectorProxyError.disconnected("RuntimeObject is not registered in this WebInspectorContext.")
            throw error
        }
        return object
    }

    private func registerRuntimeObject(
        _ payload: Runtime.RemoteObject,
        owner: RuntimeObjectOwner
    ) -> RuntimeObject {
        if let proxyID = payload.id,
           let id = runtimeObjectIDsByProxyID[proxyID],
           let object = runtimeObjectsByID[id] {
            object.update(from: payload)
            runtimeObjectOwnersByID[id, default: []].insert(owner)
            return object
        }

        let id: RuntimeObject.ID
        if let proxyID = payload.id {
            id = RuntimeObject.ID(remote: proxyID)
            runtimeObjectIDsByProxyID[proxyID] = id
        } else {
            id = RuntimeObject.ID(synthetic: nextRuntimeObjectOrdinal)
            nextRuntimeObjectOrdinal += 1
        }

        let object = RuntimeObject(id: id, remoteObject: payload, modelContext: self)
        runtimeObjectsByID[id] = object
        runtimeObjectOwnersByID[id] = [owner]
        return object
    }

    private func clearRuntimeObjects() {
        runtimeObjectsByID = [:]
        runtimeObjectIDsByProxyID = [:]
        runtimeObjectOwnersByID = [:]
        nextRuntimeObjectOrdinal = 0
    }

    private func clearRuntimeObjects(targetID: WebInspectorTarget.ID) {
        for (id, object) in runtimeObjectsByID.map({ ($0.key, $0.value) }) {
            guard object.proxyID?.targetScopeRawValue == targetID.rawValue else {
                continue
            }
            runtimeObjectsByID[id] = nil
            runtimeObjectOwnersByID[id] = nil
            if let proxyID = object.proxyID,
               runtimeObjectIDsByProxyID[proxyID] == id {
                runtimeObjectIDsByProxyID.removeValue(forKey: proxyID)
            }
        }
    }

    private func unregisterRuntimeObjects(owner: RuntimeObjectOwner) {
        for (id, owners) in runtimeObjectOwnersByID.map({ ($0.key, $0.value) }) {
            var remainingOwners = owners
            remainingOwners.remove(owner)
            guard remainingOwners.isEmpty else {
                runtimeObjectOwnersByID[id] = remainingOwners
                continue
            }
            runtimeObjectOwnersByID.removeValue(forKey: id)
            if let object = runtimeObjectsByID.removeValue(forKey: id),
               let proxyID = object.proxyID,
               runtimeObjectIDsByProxyID[proxyID] == id {
                runtimeObjectIDsByProxyID.removeValue(forKey: proxyID)
            }
        }
    }

    private func unregisterRuntimeObject(_ object: RuntimeObject, owner: RuntimeObjectOwner) {
        guard var owners = runtimeObjectOwnersByID[object.id] else {
            return
        }
        owners.remove(owner)
        guard owners.isEmpty else {
            runtimeObjectOwnersByID[object.id] = owners
            return
        }
        runtimeObjectOwnersByID.removeValue(forKey: object.id)
        runtimeObjectsByID[object.id] = nil
        if let proxyID = object.proxyID,
           runtimeObjectIDsByProxyID[proxyID] == object.id {
            runtimeObjectIDsByProxyID.removeValue(forKey: proxyID)
        }
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
    public func stop(isolation: isolated (any Actor) = #isolation) async {
        requireOwner(isolation)
        await detach(isolation: isolation)
    }

    func detach(isolation: isolated (any Actor) = #isolation) async {
        requireOwner(isolation)
        startupTask?.cancel()
        startupTask = nil
        currentPageRetargetTask?.cancel()
        currentPageRetargetTask = nil
        currentPageCleanupTask?.cancel()
        currentPageCleanupTask = nil
        documentReloadTask?.cancel()
        documentReloadTask = nil
        inspectedNodeHighlightTask?.cancel()
        inspectedNodeHighlightTask = nil
        cancelFrameDocumentLoadTasks()
        styleRefreshTask?.cancel()
        styleRefreshTask = nil
        styleRefreshGeneration += 1
        for task in styleToggleTasks.values {
            task.cancel()
        }
        styleToggleTasks = [:]
        stopEventPumps()
        cancelConsoleObjectGroupReleaseTasks()
        currentPage = nil
        advanceCurrentPageGeneration(isolation: isolation)
        domState.advanceDocumentEpoch(isolation: isolation)
        resetAttachmentBackedModels(isolation: isolation)
        teardownError = nil
        teardownError = await disableEnabledDomains(isolation: isolation)
        transition(to: .detached)
    }

    private func startup(isolation: isolated (any Actor)) async {
        requireOwner(isolation)
        let generation = currentPageGeneration
        if let teardownError = await disableEnabledDomainsBeforeRestart(isolation: isolation) {
            failIfTerminal(teardownError, operation: "domain disable before restart")
            if case .failed = state {
                return
            }
        }

        do {
            let target = try await proxy.waitForCurrentPage()
            currentPage = target
            subscribe(to: target, isolation: isolation)
            await waitForCurrentPageEventSubscriptions(target, isolation: isolation)
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation(isolation: isolation)
                return
            }
            guard isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            resetReplayBackedModelsBeforeEnable(isolation: isolation)
            try await enableInspectorTracking(on: target, generation: generation, isolation: isolation)
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation(isolation: isolation)
                return
            }
            guard isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            try await enableRuntimeTracking(on: target, generation: generation, isolation: isolation)
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation(isolation: isolation)
                return
            }
            guard isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            try await enableNetworkTracking(on: target, generation: generation, isolation: isolation)
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation(isolation: isolation)
                return
            }
            guard isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            var document = try await loadCurrentDOMDocument(on: target, isolation: isolation)
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation(isolation: isolation)
                return
            }
            guard isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            try await enableConsoleTracking(on: target, generation: generation, isolation: isolation)
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation(isolation: isolation)
                return
            }
            guard isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            document = try await reloadDOMDocumentIfNeeded(document, on: target, isolation: isolation)
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation(isolation: isolation)
                return
            }
            guard isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            applyDocument(
                document.node,
                expectedEpoch: document.generation,
                isolation: isolation
            )
            transition(to: .attached)
        } catch is CancellationError {
            await disableEnabledDomainsAfterCancellation(isolation: isolation)
            return
        } catch let error as WebInspectorProxyError {
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation(isolation: isolation)
                return
            }
            guard isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            await logStartupTeardownFailure(isolation: isolation)
            fail(error)
        } catch {
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation(isolation: isolation)
                return
            }
            guard isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            await logStartupTeardownFailure(isolation: isolation)
            fail(.attachFailed(String(describing: error)))
        }
    }

    private func waitForCurrentPageEventSubscriptions(
        _ target: WebInspectorTarget,
        isolation: isolated (any Actor)
    ) async {
        _ = isolation
        await target.waitForModelEventSubscriptions()
        await proxy.waitForEventSubscription(targetID: target.id, route: target.route, domain: .target)
        await proxy.waitForEventSubscription(targetID: target.id, route: target.route, domain: .page)
    }

    private func disableEnabledDomainsBeforeRestart(
        isolation: isolated (any Actor)
    ) async -> WebInspectorProxyError? {
        let error = await disableEnabledDomains(isolation: isolation)
        await discardCurrentPageDomainLeases(isolation: isolation)
        return error
    }

    private func discardCurrentPageDomainLeases(isolation: isolated (any Actor)) async {
        _ = isolation
        if let target = inspectorTrackingTarget {
            inspectorTrackingTarget = nil
            await domainEnablement.discardLease(.inspector, on: target)
        }
        if let target = runtimeTrackingTarget {
            runtimeTrackingTarget = nil
            await domainEnablement.discardLease(.runtime, on: target)
        }
        if let target = networkTrackingTarget {
            networkTrackingTarget = nil
            await domainEnablement.discardLease(.network, on: target)
        }
        if let target = consoleTrackingTarget {
            consoleTrackingTarget = nil
            await domainEnablement.discardLease(.console, on: target)
        }
    }

    private func enableInspectorTracking(
        on target: WebInspectorTarget,
        generation: Int,
        isolation: isolated (any Actor)
    ) async throws {
        _ = isolation
        try await domainEnablement.acquire(.inspector, on: target)
        guard isCurrentPageGeneration(generation, isolation: isolation) else {
            await releaseLateAcquiredDomain(.inspector, on: target, isolation: isolation)
            return
        }
        inspectorTrackingTarget = target
    }

    private func enableRuntimeTracking(
        on target: WebInspectorTarget,
        generation: Int,
        isolation: isolated (any Actor)
    ) async throws {
        _ = isolation
        try await domainEnablement.acquire(.runtime, on: target)
        guard isCurrentPageGeneration(generation, isolation: isolation) else {
            await releaseLateAcquiredDomain(.runtime, on: target, isolation: isolation)
            return
        }
        runtimeTrackingTarget = target
    }

    private func enableConsoleTracking(
        on target: WebInspectorTarget,
        generation: Int,
        isolation: isolated (any Actor)
    ) async throws {
        _ = isolation
        try await domainEnablement.acquire(.console, on: target)
        guard isCurrentPageGeneration(generation, isolation: isolation) else {
            await releaseLateAcquiredDomain(.console, on: target, isolation: isolation)
            return
        }
        consoleTrackingTarget = target
    }

    private func enableNetworkTracking(
        on target: WebInspectorTarget,
        generation: Int,
        isolation: isolated (any Actor)
    ) async throws {
        _ = isolation
        try await domainEnablement.acquire(.network, on: target)
        guard isCurrentPageGeneration(generation, isolation: isolation) else {
            await releaseLateAcquiredDomain(.network, on: target, isolation: isolation)
            return
        }
        networkTrackingTarget = target
    }

    private func releaseLateAcquiredDomain(
        _ domain: WebInspectorEnabledDomain,
        on target: WebInspectorTarget,
        isolation: isolated (any Actor)
    ) async {
        _ = isolation
        if let error = await domainEnablement.release(domain, on: target) {
            WebInspectorDataKitLog.debug(
                "domain late-acquire release failed domain=\(domain.rawValue) target=\(target.id.rawValue) error=\(String(describing: error))"
            )
        }
    }

    private func loadCurrentDOMDocument(
        on target: WebInspectorTarget,
        isolation: isolated (any Actor)
    ) async throws -> LoadedDOMDocument {
        _ = isolation
        while true {
            let generation = domState.documentEpoch
            let document = try await target.dom.getDocument()
            guard Task.isCancelled == false else {
                throw CancellationError()
            }
            guard generation == domState.documentEpoch else {
                continue
            }
            return (node: document, generation: generation)
        }
    }

    private func reloadDOMDocumentIfNeeded(
        _ document: LoadedDOMDocument,
        on target: WebInspectorTarget,
        isolation: isolated (any Actor)
    ) async throws -> LoadedDOMDocument {
        if document.generation == domState.documentEpoch {
            return document
        }
        return try await loadCurrentDOMDocument(on: target, isolation: isolation)
    }

    private func resetReplayBackedModelsBeforeEnable(
        isolation: isolated (any Actor)
    ) {
        clearExecutionContexts()
        consoleMessages.resetForReplay(modelContext: self, isolation: isolation)
    }

    private func resetNetworkModelsForNewAttachment(
        isolation: isolated (any Actor)
    ) {
        networkRequests.resetForNewAttachment(isolation: isolation)
    }

    private func resetCurrentPageLifecycleModels(isolation: isolated (any Actor)) {
        resetDOM(isolation: isolation)
        clearExecutionContexts()
        clearConsoleMessages(isolation: isolation)
    }

    private func resetAttachmentBackedModels(isolation: isolated (any Actor)) {
        resetCurrentPageLifecycleModels(isolation: isolation)
        resetNetworkModelsForNewAttachment(isolation: isolation)
    }

    private func disableEnabledDomains(
        isolation: isolated (any Actor)
    ) async -> WebInspectorProxyError? {
        let consoleError = await disableConsoleTracking(isolation: isolation)
        let runtimeError = await disableRuntimeTracking(isolation: isolation)
        let networkError = await disableNetworkTracking(isolation: isolation)
        let inspectorError = await disableInspectorTracking(isolation: isolation)
        return consoleError ?? runtimeError ?? networkError ?? inspectorError
    }

    private func disableInspectorTracking(
        isolation: isolated (any Actor)
    ) async -> WebInspectorProxyError? {
        _ = isolation
        guard let target = inspectorTrackingTarget else {
            return nil
        }
        inspectorTrackingTarget = nil
        return await domainEnablement.release(.inspector, on: target)
    }

    private func disableConsoleTracking(
        isolation: isolated (any Actor)
    ) async -> WebInspectorProxyError? {
        _ = isolation
        guard let target = consoleTrackingTarget else {
            return nil
        }
        consoleTrackingTarget = nil
        return await domainEnablement.release(.console, on: target)
    }

    private func disableRuntimeTracking(
        isolation: isolated (any Actor)
    ) async -> WebInspectorProxyError? {
        _ = isolation
        guard let target = runtimeTrackingTarget else {
            return nil
        }
        runtimeTrackingTarget = nil
        return await domainEnablement.release(.runtime, on: target)
    }

    private func disableNetworkTracking(
        isolation: isolated (any Actor)
    ) async -> WebInspectorProxyError? {
        _ = isolation
        guard let target = networkTrackingTarget else {
            return nil
        }
        networkTrackingTarget = nil
        return await domainEnablement.release(.network, on: target)
    }

    private func disableEnabledDomainsAfterCancellation(
        isolation: isolated (any Actor)
    ) async {
        if let error = await disableEnabledDomains(isolation: isolation) {
            failIfTerminal(error, operation: "domain disable after cancellation")
        }
    }

    private func disableEnabledDomainsAfterStartupFailure(
        isolation: isolated (any Actor)
    ) async -> WebInspectorProxyError? {
        await disableEnabledDomains(isolation: isolation)
    }

    /// Best-effort teardown after a startup failure: the startup error is the
    /// root cause and owns `state`; a teardown error must not mask it.
    private func logStartupTeardownFailure(isolation: isolated (any Actor)) async {
        if let teardownError = await disableEnabledDomainsAfterStartupFailure(isolation: isolation) {
            WebInspectorDataKitLog.debug("domain disable after startup failure also failed: \(String(describing: teardownError))")
        }
    }

    private func subscribe(to target: WebInspectorTarget, isolation: isolated (any Actor)) {
        stopEventPumps()

        let domPump = WebInspectorEventPump(stream: target.dom.events, isolation: isolation) { [weak self] event in
            guard let self else { return }
            self.apply(event, isolation: isolation)
            self.recordEventPumpAppliedForTesting()
        }

        let networkPump = WebInspectorEventPump(stream: target.network.events, isolation: isolation) { [weak self] event in
            guard let self else { return }
            await self.apply(event, isolation: isolation)
            self.recordEventPumpAppliedForTesting()
        }

        let cssPump = WebInspectorEventPump(stream: target.css.events, isolation: isolation) { [weak self] event in
            guard let self else { return }
            self.apply(event, isolation: isolation)
            self.recordEventPumpAppliedForTesting()
        }

        let consolePump = WebInspectorEventPump(stream: target.targetedConsoleEvents, isolation: isolation) { [weak self] event in
            guard let self else { return }
            await self.apply(event.event, targetID: event.targetID, isolation: isolation)
            self.recordEventPumpAppliedForTesting()
        }

        let runtimePump = WebInspectorEventPump(stream: target.runtime.events, isolation: isolation) { [weak self, targetID = target.id] event in
            guard let self else { return }
            self.apply(event, targetID: targetID, isolation: isolation)
            self.recordEventPumpAppliedForTesting()
        }

        let lifecyclePump = WebInspectorEventPump(stream: target.lifecycleEvents, isolation: isolation) { [weak self] event in
            guard let self else { return }
            self.apply(event, isolation: isolation)
            self.recordEventPumpAppliedForTesting()
        }

        eventPumps = [domPump, networkPump, cssPump, consolePump, runtimePump, lifecyclePump]
    }

    private func stopEventPumps() {
        for pump in eventPumps {
            pump.stop()
        }
        eventPumps = []
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

    @discardableResult
    private func registeredNode(
        _ node: DOMNode,
        isolation: isolated (any Actor) = #isolation
    ) throws -> DOMNode {
        try domState.registeredNode(node, isolation: isolation)
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

    private func recordDOMEditHistoryTarget(
        _ target: WebInspectorTarget,
        options: WebInspectorMutationOptions,
        isolation: isolated (any Actor) = #isolation
    ) {
        domState.recordEditHistoryTarget(target, options: options, isolation: isolation)
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

    private func isCurrentPageGeneration(
        _ generation: Int,
        isolation: isolated (any Actor)
    ) -> Bool {
        _ = isolation
        return currentPageGeneration == generation
    }

    @discardableResult
    private func advanceCurrentPageGeneration(isolation: isolated (any Actor)) -> Int {
        _ = isolation
        currentPageGeneration += 1
        return currentPageGeneration
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

    /// Command failures surface at their call site (thrown, or a per-model
    /// phase such as `NetworkBody.Phase.failed`); only terminal connection
    /// loss moves the whole context to `.failed`.
    private func failIfTerminal(_ error: Error, operation: String) {
        switch error {
        case let proxyError as WebInspectorProxyError:
            switch proxyError {
            case .disconnected, .unsupported, .attachFailed, .protocolViolation,
                 .transportFailure:
                fail(proxyError)
            case .closed, .pageUnavailable:
                WebInspectorDataKitLog.debug("\(operation) raced connection close")
            case .staleIdentifier, .commandFailed, .commandRejected,
                 .eventBufferOverflow, .connectionInUse, .timeout:
                WebInspectorDataKitLog.debug("\(operation) failed: \(String(describing: proxyError))")
            }
        default:
            WebInspectorDataKitLog.debug("\(operation) failed: \(String(describing: error))")
        }
    }

    private func requireOwner(_ isolation: isolated (any Actor)) {
        precondition(isolation === owner, "WebInspectorContext must be used from the actor that created it.")
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

    private func applyDOMStateEffects(
        _ effects: DOMStateStore.Effects,
        isolation: isolated (any Actor)
    ) {
        if effects.documentReset {
            documentReloadTask?.cancel()
            documentReloadTask = nil
            inspectedNodeHighlightTask?.cancel()
            inspectedNodeHighlightTask = nil
            cancelFrameDocumentLoadTasks()
        }

        if effects.selectionChanged || effects.documentReset {
            styleRefreshTask?.cancel()
            styleRefreshTask = nil
            styleRefreshGeneration += 1
        }
        effects.discardedStyleNode?.setElementStyles(nil)

        if effects.statusChanged {
            notifyStatusChanged()
        }
        if effects.selectionChanged {
            refreshSelectedStyles(isolation: isolation)
        } else if effects.selectedStylesNeedRefresh {
            markSelectedStylesNeedsRefresh(isolation: isolation)
        }

        if effects.shouldClearPageHighlight {
            clearPageHighlightForDOMReset(isolation: isolation)
        }
        for request in effects.frameDocumentLoadRequests {
            loadFrameDocumentIfNeeded(
                forFrameTargetID: request.targetID,
                reason: request.reason,
                isolation: isolation
            )
        }
        if let inspectedNode = effects.inspectedNode {
            restoreElementPickerHighlight(for: inspectedNode, isolation: isolation)
        }
        if effects.shouldReloadDocument, state != .attaching {
            reloadDocument(isolation: isolation)
        }
    }

    func reloadDocument(isolation: isolated (any Actor) = #isolation) {
        requireOwner(isolation)
        guard let currentPage else {
            skipEvent("reloadDocument ignored: no current page target")
            return
        }

        let generation = domState.documentEpoch
        documentReloadTask?.cancel()
        documentReloadTask = Task { [weak self, currentPage, generation] in
            _ = isolation
            do {
                let document = try await currentPage.dom.getDocument()
                guard Task.isCancelled == false else {
                    return
                }
                guard self?.domState.documentEpoch == generation else {
                    return
                }
                self?.applyDocument(
                    document,
                    expectedEpoch: generation,
                    reason: .documentUpdated,
                    isolation: isolation
                )
            } catch is CancellationError {
                return
            } catch {
                self?.failIfTerminal(error, operation: "DOM.getDocument")
            }
        }
    }

}

extension WebInspectorContext {
    func apply(_ event: WebInspectorTargetLifecycleEvent, isolation: isolated (any Actor) = #isolation) {
        requireOwner(isolation)
        switch event {
        case let .didCommitProvisionalTarget(commit):
            applyCurrentPageTargetCommit(commit, isolation: isolation)
        case let .frameNavigated(frame):
            applyCurrentPageFrameNavigated(frame, isolation: isolation)
        case let .targetDestroyed(targetID):
            applyCurrentPageTargetDestroyed(targetID, isolation: isolation)
        case let .frameDetached(frameID):
            applyCurrentPageFrameDetached(frameID, isolation: isolation)
        case .unknown:
            break
        }
    }

    private func applyCurrentPageTargetCommit(
        _ commit: WebInspectorTargetCommitLifecycle,
        isolation: isolated (any Actor)
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
        let refreshedTarget = target.withPageBinding(from: commit.newTarget)
        currentPage = refreshedTarget

        currentPageRetargetTask?.cancel()
        documentReloadTask?.cancel()
        documentReloadTask = nil
        let generation = advanceCurrentPageGeneration(isolation: isolation)
        domState.advanceDocumentEpoch(isolation: isolation)
        resetCurrentPageLifecycleModels(isolation: isolation)
        cancelConsoleObjectGroupReleaseTasks()
        for task in styleToggleTasks.values {
            task.cancel()
        }
        styleToggleTasks = [:]

        currentPageRetargetTask = Task { [weak self, refreshedTarget, generation] in
            _ = isolation
            await self?.retargetCurrentPage(refreshedTarget, generation: generation, isolation: isolation)
        }
    }

    private func retargetCurrentPage(
        _ target: WebInspectorTarget,
        generation: Int,
        isolation: isolated (any Actor)
    ) async {
        defer {
            if isCurrentPageGeneration(generation, isolation: isolation) {
                currentPageRetargetTask = nil
            }
        }
        await discardCurrentPageDomainLeases(isolation: isolation)

        do {
            guard Task.isCancelled == false, isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            try await enableInspectorTracking(on: target, generation: generation, isolation: isolation)
            guard Task.isCancelled == false, isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            try await enableRuntimeTracking(on: target, generation: generation, isolation: isolation)
            guard Task.isCancelled == false, isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            try await enableNetworkTracking(on: target, generation: generation, isolation: isolation)
            guard Task.isCancelled == false, isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            var document = try await loadCurrentDOMDocument(on: target, isolation: isolation)
            guard Task.isCancelled == false, isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            try await enableConsoleTracking(on: target, generation: generation, isolation: isolation)
            guard Task.isCancelled == false, isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            document = try await reloadDOMDocumentIfNeeded(document, on: target, isolation: isolation)
            guard Task.isCancelled == false, isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            applyDocument(
                document.node,
                expectedEpoch: document.generation,
                reason: .pageChanged,
                isolation: isolation
            )
            if case .attaching = state {
                transition(to: .attached)
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            failIfTerminal(error, operation: "current page retarget")
        }
    }

    private func applyCurrentPageFrameNavigated(
        _ frame: WebInspectorPageFrameLifecycle,
        isolation: isolated (any Actor)
    ) {
        guard let currentPage else {
            skipEvent("Page.frameNavigated ignored: no current page target")
            return
        }
        guard frame.parentID == nil || frame.id == currentPage.frameID else {
            applyDOMStateEffects(
                domState.detachProjectedFrameDocument(forFrameID: frame.id, isolation: isolation),
                isolation: isolation
            )
            return
        }
        domState.advanceDocumentEpoch(isolation: isolation)
        resetDOM(isolation: isolation)
        clearExecutionContexts()
        guard currentPageRetargetTask == nil,
              state != .attaching else {
            return
        }
        reloadDocument(isolation: isolation)
    }

    private func applyCurrentPageFrameDetached(
        _ frameID: FrameID,
        isolation: isolated (any Actor)
    ) {
        applyDOMStateEffects(
            domState.detachProjectedFrameDocument(forFrameID: frameID, isolation: isolation),
            isolation: isolation
        )
    }

    private func applyCurrentPageTargetDestroyed(
        _ targetID: WebInspectorTarget.ID,
        isolation: isolated (any Actor)
    ) {
        guard targetID == .currentPage else {
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
        for task in styleToggleTasks.values {
            task.cancel()
        }
        styleToggleTasks = [:]
        cancelConsoleObjectGroupReleaseTasks()
        let generation = advanceCurrentPageGeneration(isolation: isolation)
        domState.advanceDocumentEpoch(isolation: isolation)

        currentPageRetargetTask = Task { [weak self, generation] in
            _ = isolation
            await self?.retargetDestroyedCurrentPage(generation: generation, isolation: isolation)
        }
    }

    private func retargetDestroyedCurrentPage(
        generation: Int,
        isolation: isolated (any Actor)
    ) async {
        defer {
            if isCurrentPageGeneration(generation, isolation: isolation) {
                currentPageRetargetTask = nil
            }
        }
        do {
            let gracePeriod = await proxy.bootstrapGracePeriod
            var replacement = try await proxy.waitForCurrentPageReplacement(gracePeriod: gracePeriod)
            guard Task.isCancelled == false, isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            if replacement == nil {
                // The destroyed page has no successor yet (process kill without
                // an immediate reload). `.attached` promises a usable current
                // page, so stop presenting the destroyed page's state and wait
                // for the next page target to appear.
                currentPage = nil
                resetCurrentPageLifecycleModels(isolation: isolation)
                if state == .attached {
                    transition(to: .attaching)
                }
                replacement = try await proxy.waitForCurrentPageReplacement(gracePeriod: nil)
                guard Task.isCancelled == false, isCurrentPageGeneration(generation, isolation: isolation) else {
                    return
                }
            }
            guard let replacement else {
                fail(.disconnected("Current page target was destroyed without a replacement."))
                return
            }
            currentPage = replacement
            resetCurrentPageLifecycleModels(isolation: isolation)
            await retargetCurrentPage(replacement, generation: generation, isolation: isolation)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            failIfTerminal(error, operation: "current page replacement")
        }
    }
}

extension WebInspectorContext {
    func apply(_ event: DOM.Event, isolation: isolated (any Actor) = #isolation) {
        requireOwner(isolation)
        let effects = domState.apply(event, modelContext: self, isolation: isolation)
        applyDOMStateEffects(effects, isolation: isolation)
    }

    func applyDocument(
        _ node: DOM.Node,
        expectedEpoch: Int,
        reason: DOMTreeSnapshotReason = .initialDocument,
        isolation: isolated (any Actor) = #isolation
    ) {
        requireOwner(isolation)
        guard let effects = domState.applyDocument(
            node,
            expectedEpoch: expectedEpoch,
            reason: reason,
            modelContext: self,
            isolation: isolation
        ) else {
            return
        }
        applyDOMStateEffects(effects, isolation: isolation)
    }

    package func seedDOMDocument(
        _ node: DOM.Node,
        isolation: isolated (any Actor) = #isolation
    ) {
        let reason: DOMTreeSnapshotReason = rootNode == nil ? .initialDocument : .documentUpdated
        applyDocument(
            node,
            expectedEpoch: domState.documentEpoch,
            reason: reason,
            isolation: isolation
        )
    }

    package func seedElementPickerEnabled(
        _ isEnabled: Bool,
        isolation: isolated (any Actor) = #isolation
    ) {
        requireOwner(isolation)
        applyDOMStateEffects(
            domState.setElementPickerEnabled(isEnabled, isolation: isolation),
            isolation: isolation
        )
    }

    /// Seeds the selected element node's styles through the same load path
    /// the backend refresh uses. Requires a selected element node; cancels
    /// any in-flight backend refresh so it cannot clobber the seeded state.
    package func seedSelectedNodeStyles(
        matchedStyles: CSS.MatchedStyles,
        inlineStyles: CSS.InlineStyles? = nil,
        computedProperties: [CSS.ComputedProperty] = [],
        isolation: isolated (any Actor) = #isolation
    ) {
        requireOwner(isolation)
        guard let selectedNode = domState.selectedNode else {
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

    private func resetDOM(isolation: isolated (any Actor)) {
        let effects = domState.resetDocument(isolation: isolation)
        applyDOMStateEffects(effects, isolation: isolation)
    }

    private func clearPageHighlightForDOMReset(isolation: isolated (any Actor)) {
        guard let currentPage else {
            return
        }
        inspectedNodeHighlightTask = Task { [weak self, currentPage] in
            _ = isolation
            do {
                guard Task.isCancelled == false else {
                    return
                }
                guard self?.domState.shouldSendPageHighlightClearAfterReset(isolation: isolation) == true else {
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

    private func loadFrameDocumentIfNeeded(
        forFrameTargetID frameTargetID: WebInspectorTarget.ID,
        reason: String,
        isolation: isolated (any Actor)
    ) {
        guard frameDocumentLoadTasks[frameTargetID] == nil else {
            return
        }
        let epoch = domState.documentEpoch
        let target = proxy.frameTarget(id: frameTargetID)
        WebInspectorDataKitLog.debug(
            "frame document projection loading target=\(frameTargetID.rawValue) reason=\(reason)"
        )
        frameDocumentLoadTasks[frameTargetID] = Task { [weak self, target, frameTargetID, epoch] in
            _ = isolation
            do {
                let document = try await target.dom.getDocument()
                guard Task.isCancelled == false,
                      self?.domState.documentEpoch == epoch,
                      let self,
                      let effects = self.domState.applyFrameDocument(
                          document,
                          frameTargetID: frameTargetID,
                          expectedEpoch: epoch,
                          modelContext: self,
                          isolation: isolation
                      ) else {
                    return
                }
                self.applyDOMStateEffects(effects, isolation: isolation)
            } catch is CancellationError {
                return
            } catch {
                guard self?.domState.documentEpoch == epoch else {
                    return
                }
                self?.failIfTerminal(error, operation: "frame DOM.getDocument")
            }
            if self?.domState.documentEpoch == epoch {
                self?.frameDocumentLoadTasks[frameTargetID] = nil
            }
        }
    }

    private func cancelFrameDocumentLoadTasks() {
        for task in frameDocumentLoadTasks.values {
            task.cancel()
        }
        frameDocumentLoadTasks = [:]
    }

    private func restoreElementPickerHighlight(
        for node: DOMNode,
        isolation: isolated (any Actor)
    ) {
        guard let currentPage else {
            skipEvent("DOM.inspect highlight restore ignored: no current page target")
            return
        }
        let epoch = domState.documentEpoch
        let nodeID = node.id.proxyID
        guard nodeID.targetScopeRawValue == nil else {
            return
        }
        inspectedNodeHighlightTask?.cancel()
        // Web Inspector clears the picker overlay after inspect. On touch devices
        // WebInspectorKit keeps the picked node highlighted so the tap target remains visible.
        inspectedNodeHighlightTask = Task { [weak self, currentPage, epoch, nodeID] in
            _ = isolation
            do {
                guard Task.isCancelled == false,
                      self?.domState.documentEpoch == epoch else {
                    return
                }
                WebInspectorDataKitLog.debug(
                    "DOM.inspect restoring highlight nodeID=\(String(describing: nodeID))"
                )
                self?.domState.recordPageHighlight(isolation: isolation)
                try await currentPage.dom.highlightNode(nodeID)
            } catch is CancellationError {
                return
            } catch {
                self?.failIfTerminal(error, operation: "DOM.highlightNode after inspect")
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

    func apply(_ event: CSS.Event, isolation: isolated (any Actor) = #isolation) {
        requireOwner(isolation)
        switch event {
        case .styleSheetChanged,
             .styleSheetAdded,
             .styleSheetRemoved,
             .mediaQueryResultChanged:
            markSelectedStylesNeedsRefresh()
        case let .nodeLayoutFlagsChanged(id):
            markSelectedStylesNeedsRefresh(for: DOMNode.ID(id))
        case .unknown:
            break
        }
    }

    private func refreshSelectedStyles(isolation: isolated (any Actor) = #isolation) {
        styleRefreshTask?.cancel()
        styleRefreshTask = nil

        guard let selectedNode = domState.selectedNode else {
            return
        }
        guard selectedNode.nodeType == 1 else {
            selectedNode.setElementStyles(nil)
            return
        }

        let styles = selectedNode.elementStyles ?? CSSStyles(nodeID: selectedNode.id, modelContext: self)
        selectedNode.setElementStyles(styles)
        styles.markLoading()
        styleRefreshGeneration += 1
        let generation = styleRefreshGeneration
        styleRefreshTask = Task { [weak self, weak selectedNode, styles] in
            _ = isolation
            guard let self, let selectedNode else {
                return
            }
            await self.loadStyles(for: selectedNode, into: styles, generation: generation, isolation: isolation)
        }
    }

    private func loadStyles(
        for node: DOMNode,
        into styles: CSSStyles,
        generation: Int,
        isolation: isolated (any Actor) = #isolation
    ) async {
        _ = isolation
        guard isCurrentStyleRefresh(node: node, generation: generation) else {
            return
        }
        guard let currentPage else {
            styles.markUnavailable()
            return
        }

        do {
            guard let payloads = try await selectedStylePayloadsWithCSSAgentCompatibility(
                for: node,
                target: currentPage,
                generation: generation,
                isolation: isolation
            ) else { return }
            styles.load(
                matchedStyles: payloads.matchedStyles,
                inlineStyles: payloads.inlineStyles,
                computedProperties: payloads.computedProperties
            )
        } catch let error as WebInspectorProxyError {
            guard isCurrentStyleRefresh(node: node, generation: generation) else {
                return
            }
            styles.fail(error)
        } catch {
            guard isCurrentStyleRefresh(node: node, generation: generation) else {
                return
            }
            styles.fail(.commandFailed(
                domain: "CSS",
                method: "getMatchedStylesForNode/getInlineStylesForNode/getComputedStyleForNode",
                message: String(describing: error)
            ))
        }
    }

    private func selectedStylePayloadsWithCSSAgentCompatibility(
        for node: DOMNode,
        target: WebInspectorTarget,
        generation: Int,
        isolation: isolated (any Actor) = #isolation
    ) async throws -> SelectedStylePayloads? {
        _ = isolation
        do {
            return try await selectedStylePayloads(
                for: node,
                target: target,
                generation: generation,
                isolation: isolation
            )
        } catch let error as WebInspectorProxyError {
            guard shouldRetrySelectedStyleLoadAfterEnablingCSSAgent(error) else {
                throw error
            }
            guard isCurrentStyleRefresh(node: node, generation: generation) else {
                return nil
            }
            // Enable the CSS agent that rejected the style reads: for a
            // frame-owned node that is the frame target, not the semantic
            // current page the reads were retargeted away from.
            try await domTarget(owning: node.id.proxyID).css.enable()
            guard isCurrentStyleRefresh(node: node, generation: generation) else {
                return nil
            }
            return try await selectedStylePayloads(
                for: node,
                target: target,
                generation: generation,
                isolation: isolation
            )
        }
    }

    private func selectedStylePayloads(
        for node: DOMNode,
        target: WebInspectorTarget,
        generation: Int,
        isolation: isolated (any Actor) = #isolation
    ) async throws -> SelectedStylePayloads? {
        _ = isolation
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

    private func shouldRetrySelectedStyleLoadAfterEnablingCSSAgent(_ error: WebInspectorProxyError) -> Bool {
        guard case let .commandFailed(domain, method, message) = error,
              domain == "CSS",
              [
                "getMatchedStylesForNode",
                "getInlineStylesForNode",
                "getComputedStyleForNode",
              ].contains(method) else {
            return false
        }

        return message.lowercased().contains("enable")
    }

    private func isCurrentStyleRefresh(node: DOMNode, generation: Int) -> Bool {
        Task.isCancelled == false && domState.selectedNode === node && styleRefreshGeneration == generation
    }

    /// Reports whether the style pane is visible. While active, stale
    /// selected-node styles (`.needsRefresh`) re-fetch immediately; while
    /// inactive they stay stale until the next activation or selection.
    public func setStyleHydrationActive(_ active: Bool, isolation: isolated (any Actor) = #isolation) {
        requireOwner(isolation)
        guard isStyleHydrationActive != active else {
            return
        }
        isStyleHydrationActive = active
        guard active, let styles = domState.selectedNode?.elementStyles else {
            return
        }
        switch styles.phase {
        case .needsRefresh, .failed:
            refreshSelectedStyles(isolation: isolation)
        case .loading, .loaded, .unavailable:
            break
        }
    }

    package func styles(for nodeID: DOMNode.ID, isolation: isolated (any Actor) = #isolation) throws -> CSSStyles {
        requireOwner(isolation)
        let node = try domState.requiredNode(for: nodeID, isolation: isolation)
        guard node.nodeType == 1 else {
            throw WebInspectorProxyError.commandFailed(
                domain: "CSS",
                method: "getMatchedStylesForNode",
                message: "CSS styles are only available for element DOM nodes."
            )
        }
        if domState.selectedNode !== node {
            select(node, isolation: isolation)
        }
        guard let styles = node.elementStyles else {
            throw WebInspectorProxyError.disconnected("CSS styles were not created for the selected node.")
        }
        return styles
    }

    package func refreshStyles(for nodeID: DOMNode.ID, isolation: isolated (any Actor) = #isolation) throws -> CSSStyles {
        let styles = try styles(for: nodeID, isolation: isolation)
        refreshSelectedStyles(isolation: isolation)
        return styles
    }

    package func setCSSProperty(
        _ id: CSSStyleProperty.ID,
        enabled: Bool,
        options: WebInspectorMutationOptions,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        requireOwner(isolation)
        guard styleToggleTasks[id] == nil,
              let styles = domState.selectedNode?.elementStyles,
              let intent = styles.setStyleTextIntent(for: id, enabled: enabled) else {
            throw WebInspectorProxyError.commandFailed(
                domain: "CSS",
                method: "setStyleText",
                message: "CSS property is stale, already mutating, or not editable."
            )
        }

        let marker = Task<Void, Never> {}
        styleToggleTasks[id] = marker
        defer {
            marker.cancel()
            styleToggleTasks[id] = nil
        }

        let target = try cssTarget(owning: intent.styleID)
        let result = try await target.css.setStyleText(intent.styleID, text: intent.text)
        domState.recordEditHistoryTarget(target, options: options, isolation: isolation)
        try await Self.markDOMUndoableStateIfNeeded(on: target, options: options)
        styles.applySetStyleText(result: result, for: id)
        refreshSelectedStylesIfHydrationActive(isolation: isolation)
    }

    package func setCSSDeclarationText(
        _ text: String,
        for id: CSSStyleProperty.ID,
        options: WebInspectorMutationOptions,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        requireOwner(isolation)
        guard styleToggleTasks[id] == nil,
              let styles = domState.selectedNode?.elementStyles,
              let intent = styles.setDeclarationTextIntent(for: id, text: text) else {
            throw WebInspectorProxyError.commandFailed(
                domain: "CSS",
                method: "setStyleText",
                message: "CSS declaration is stale, already mutating, or not editable."
            )
        }

        let marker = Task<Void, Never> {}
        styleToggleTasks[id] = marker
        defer {
            marker.cancel()
            styleToggleTasks[id] = nil
        }

        let target = try cssTarget(owning: intent.styleID)
        let result = try await target.css.setStyleText(intent.styleID, text: intent.text)
        domState.recordEditHistoryTarget(target, options: options, isolation: isolation)
        try await Self.markDOMUndoableStateIfNeeded(on: target, options: options)
        styles.applySetStyleText(result: result, for: id)
        refreshSelectedStylesIfHydrationActive(isolation: isolation)
    }

    package func setCSSRuleSelector(
        _ selector: String,
        for id: CSSStyleRule.ID,
        options: WebInspectorMutationOptions,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        requireOwner(isolation)
        let proxyID = id.proxyID
        let target = try cssTarget(owning: proxyID)
        _ = try await target.css.setRuleSelector(proxyID, selector: selector)
        domState.recordEditHistoryTarget(target, options: options, isolation: isolation)
        try await Self.markDOMUndoableStateIfNeeded(on: target, options: options)
        refreshSelectedStylesIfHydrationActive(isolation: isolation)
    }

    package func setCSSStyleSheetText(
        _ text: String,
        for id: CSS.StyleSheet.ID,
        options: WebInspectorMutationOptions,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        requireOwner(isolation)
        let target = try cssTarget(owning: id)
        try await target.css.setStyleSheetText(id, text: text)
        domState.recordEditHistoryTarget(target, options: options, isolation: isolation)
        try await Self.markDOMUndoableStateIfNeeded(on: target, options: options)
        refreshSelectedStylesIfHydrationActive(isolation: isolation)
    }

    /// Toggles a CSS declaration on or off by rewriting its owning style
    /// text. Returns false without issuing a command when the property is
    /// not currently editable (no selected styles, stale phase, read-only
    /// section, or unrewritable style text), or when a toggle for the same
    /// property is already in flight.
    @discardableResult
    public func requestSetCSSProperty(
        _ id: CSSStyleProperty.ID,
        enabled: Bool,
        options: WebInspectorMutationOptions,
        isolation: isolated (any Actor) = #isolation
    ) -> Bool {
        requireOwner(isolation)
        guard styleToggleTasks[id] == nil,
              let styles = domState.selectedNode?.elementStyles,
              let intent = styles.setStyleTextIntent(for: id, enabled: enabled) else {
            return false
        }
        let target: WebInspectorTarget
        do {
            target = try cssTarget(owning: intent.styleID)
        } catch {
            failIfTerminal(error, operation: "CSS.setStyleText")
            return false
        }

        styleToggleTasks[id] = Task { [weak self, target, styles] in
            _ = isolation
            do {
                let result = try await target.css.setStyleText(intent.styleID, text: intent.text)
                guard let self else {
                    return
                }
                self.styleToggleTasks[id] = nil
                guard Task.isCancelled == false else {
                    return
                }
                self.domState.recordEditHistoryTarget(target, options: options, isolation: isolation)
                try await Self.markDOMUndoableStateIfNeeded(on: target, options: options)
                styles.applySetStyleText(result: result, for: id)
                self.refreshSelectedStylesIfHydrationActive(isolation: isolation)
            } catch is CancellationError {
                self?.styleToggleTasks[id] = nil
            } catch {
                guard let self else {
                    return
                }
                self.styleToggleTasks[id] = nil
                guard Task.isCancelled == false else {
                    return
                }
                self.failIfTerminal(error, operation: "CSS.setStyleText")
                self.refreshSelectedStyles(isolation: isolation)
            }
        }
        return true
    }

    private func refreshSelectedStylesIfHydrationActive(isolation: isolated (any Actor) = #isolation) {
        guard isStyleHydrationActive else {
            return
        }
        refreshSelectedStyles(isolation: isolation)
    }

    private func markSelectedStylesNeedsRefresh(
        for nodeID: DOMNode.ID,
        isolation: isolated (any Actor) = #isolation
    ) {
        guard domState.selectedNode?.id == nodeID else {
            return
        }
        markSelectedStylesNeedsRefresh(isolation: isolation)
    }

    private func markSelectedStylesNeedsRefresh(isolation: isolated (any Actor) = #isolation) {
        styleRefreshGeneration += 1
        guard let styles = domState.selectedNode?.elementStyles else {
            return
        }
        styles.markNeedsRefresh()
        refreshSelectedStylesIfHydrationActive(isolation: isolation)
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
        encodedBodyLength: Int = 0,
        isolation: isolated (any Actor) = #isolation
    ) -> NetworkRequest.ID {
        requireOwner(isolation)
        return networkRequests.seedRequest(
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
            encodedBodyLength: encodedBodyLength,
            modelContext: self,
            isolation: isolation
        )
    }

    package func seedResponseBody(
        for requestID: NetworkRequest.ID,
        body: String,
        base64Encoded: Bool = false,
        size: Int? = nil,
        isTruncated: Bool = false,
        isolation: isolated (any Actor) = #isolation
    ) {
        requireOwner(isolation)
        networkRequests.seedResponseBody(
            for: requestID,
            body: body,
            base64Encoded: base64Encoded,
            size: size,
            isTruncated: isTruncated,
            isolation: isolation
        )
    }

    package func apply(
        _ event: Network.Event,
        isolation: isolated (any Actor) = #isolation
    ) async {
        requireOwner(isolation)
        await networkRequests.apply(event, modelContext: self, isolation: isolation)
    }
}

extension WebInspectorContext {
    func apply(
        _ event: Console.Event,
        targetID: WebInspectorTarget.ID? = nil,
        isolation: isolated (any Actor) = #isolation
    ) async {
        requireOwner(isolation)
        let effects = await consoleMessages.apply(
            event,
            targetID: targetID,
            modelContext: self,
            registerRuntimeObject: { [self] payload in
                registerRuntimeObject(payload, owner: .console)
            },
            isolation: isolation
        )
        applyConsoleMessageEffects(effects)
        switch effects.runtimeObjectGroupRelease {
        case .currentPage:
            releaseConsoleRuntimeObjectGroup(isolation: isolation)
        case let .target(targetID):
            releaseConsoleRuntimeObjectGroup(targetID: targetID, isolation: isolation)
        case nil:
            break
        }
    }

    private func clearConsoleMessages(isolation: isolated (any Actor)) {
        let effects = consoleMessages.clearForLifecycle(
            modelContext: self,
            isolation: isolation
        )
        applyConsoleMessageEffects(effects)
    }

    private func applyConsoleMessageEffects(_ effects: ConsoleMessageStore.Effects) {
        if effects.clearedAllMessages {
            unregisterRuntimeObjects(owner: .console)
            return
        }
        for object in effects.runtimeObjectsToUnregister {
            unregisterRuntimeObject(object, owner: .console)
        }
    }

    private func releaseConsoleRuntimeObjectGroup(
        targetID: WebInspectorTarget.ID? = nil,
        isolation: isolated (any Actor) = #isolation
    ) {
        let target: WebInspectorTarget
        if let targetID {
            target = proxy.frameTarget(id: targetID)
        } else if let currentPage {
            target = currentPage
        } else {
            skipEvent("Console.messagesCleared arrived without a current page target")
            return
        }
        // Release tasks are tracked per target: a clear for one frame target
        // must not cancel another target's still-pending release.
        let key = targetID ?? .currentPage
        consoleObjectGroupReleaseTasks[key]?.cancel()
        consoleObjectGroupReleaseTasks[key] = Task { [weak self, target] in
            _ = isolation
            do {
                try await target.runtime.releaseObjectGroup(.console)
            } catch is CancellationError {
                return
            } catch {
                self?.failIfTerminal(error, operation: "Runtime.releaseObjectGroup")
            }
        }
    }

    private func cancelConsoleObjectGroupReleaseTasks() {
        for task in consoleObjectGroupReleaseTasks.values {
            task.cancel()
        }
        consoleObjectGroupReleaseTasks = [:]
    }
}

extension WebInspectorContext {
    func apply(
        _ event: Runtime.Event,
        targetID: WebInspectorTarget.ID? = nil,
        isolation: isolated (any Actor) = #isolation
    ) {
        requireOwner(isolation)
        switch event {
        case let .executionContextCreated(context):
            applyExecutionContextCreated(context)
        case let .executionContextDestroyed(id):
            applyExecutionContextDestroyed(id)
        case let .executionContextsCleared(eventTargetID):
            if eventTargetID == .currentPage || eventTargetID == targetID {
                clearExecutionContexts()
            } else {
                clearExecutionContexts(targetID: eventTargetID)
            }
        case .unknown:
            break
        }
    }

    private func applyExecutionContextCreated(_ payload: Runtime.ExecutionContext) {
        let id = RuntimeContext.ID(payload.id)
        if let context = runtimeContextsByID[id] {
            context.update(from: payload)
        } else {
            let context = RuntimeContext(context: payload, modelContext: self)
            runtimeContextsByID[id] = context
            orderedRuntimeContextIDs.append(id)
        }
        refreshExecutionContexts()
        if selectedContext == nil {
            selectedContext = runtimeContextsByID[id]
        }
    }

    private func applyExecutionContextDestroyed(_ proxyID: Runtime.ExecutionContext.ID) {
        let id = RuntimeContext.ID(proxyID)
        guard let removed = runtimeContextsByID.removeValue(forKey: id) else {
            skipEvent("Runtime.executionContextDestroyed referenced an untracked context")
            return
        }
        orderedRuntimeContextIDs.removeAll { $0 == id }
        if selectedContext === removed {
            selectedContext = firstRuntimeContext()
        }
        refreshExecutionContexts()
    }

    private func clearExecutionContexts() {
        runtimeContextsByID = [:]
        orderedRuntimeContextIDs = []
        executionContexts = []
        selectedContext = nil
        clearRuntimeObjects()
    }

    private func clearExecutionContexts(targetID: WebInspectorTarget.ID) {
        let removedIDs = Set(runtimeContextsByID.keys.filter { id in
            id.proxyID.targetScopeRawValue == targetID.rawValue
        })
        guard removedIDs.isEmpty == false else {
            return
        }
        runtimeContextsByID = runtimeContextsByID.filter { removedIDs.contains($0.key) == false }
        orderedRuntimeContextIDs.removeAll { removedIDs.contains($0) }
        if let selectedContext, removedIDs.contains(selectedContext.id) {
            self.selectedContext = firstRuntimeContext()
        }
        refreshExecutionContexts()
        clearRuntimeObjects(targetID: targetID)
    }

    private func refreshExecutionContexts() {
        executionContexts = orderedRuntimeContextIDs.compactMap { runtimeContextsByID[$0] }
    }

    private func firstRuntimeContext() -> RuntimeContext? {
        orderedRuntimeContextIDs.compactMap { runtimeContextsByID[$0] }.first
    }
}
