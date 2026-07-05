import Foundation
import WebInspectorProxyKit

public final class WebInspectorContext {
    package struct DOMUndoRedoCommands {
        private weak var context: WebInspectorContext?
        private let target: WebInspectorTarget
        private let documentGeneration: Int

        fileprivate init(context: WebInspectorContext, target: WebInspectorTarget, documentGeneration: Int) {
            self.context = context
            self.target = target
            self.documentGeneration = documentGeneration
        }

        package func undo(isolation: isolated (any Actor) = #isolation) async throws {
            try validateCurrentPage(isolation: isolation)
            try await target.dom.undo()
        }

        package func redo(isolation: isolated (any Actor) = #isolation) async throws {
            try validateCurrentPage(isolation: isolation)
            try await target.dom.redo()
        }

        private func validateCurrentPage(isolation: isolated (any Actor)) throws {
            guard let context else {
                throw WebInspectorProxyError.disconnected("WebInspectorDataKit context was released before DOM undo/redo.")
            }
            context.requireOwner(isolation)
            guard context.domDocumentGeneration == documentGeneration else {
                throw WebInspectorProxyError.disconnected("DOM undo/redo target is no longer current.")
            }
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

    public enum State: Equatable, Sendable {
        case attaching
        case attached
        case detached
        case failed(WebInspectorProxyError)
    }

    public struct Status: Equatable, Sendable {
        public let state: State
        public let selectedNodeID: DOMNode.ID?
        public let isElementPickerEnabled: Bool
    }

    private(set) weak var container: WebInspectorContainer?
    private let proxy: WebInspectorProxy
    private let domainEnablement: WebInspectorDomainEnablementRegistry
    private let owner: any Actor
    public private(set) var state: State
    public private(set) var teardownError: WebInspectorProxyError?
    public private(set) var rootNode: DOMNode?
    public private(set) var selectedNode: DOMNode?
    public private(set) var isElementPickerEnabled: Bool
    public private(set) var executionContexts: [RuntimeContext]
    public private(set) var selectedContext: RuntimeContext?

    private var currentPage: WebInspectorTarget?
    private var currentPageGeneration: Int
    private var domDocumentGeneration: Int
    private var startupTask: Task<Void, Never>?
    private var currentPageRetargetTask: Task<Void, Never>?
    private var currentPageCleanupTask: Task<Void, Never>?
    private var documentReloadTask: Task<Void, Never>?
    private var inspectResolutionTask: Task<Void, Never>?
    private var inspectedNodeHighlightTask: Task<Void, Never>?
    private var frameDocumentLoadTasks: [WebInspectorTarget.ID: Task<Void, Never>]
    private var styleRefreshTask: Task<Void, Never>?
    private var styleRefreshGeneration: Int
    private var isStyleHydrationActive: Bool
    private var styleToggleTasks: [CSS.Property.ID: Task<Void, Never>]
    private var eventPumps: [WebInspectorEventPump]
    private var inspectorTrackingTarget: WebInspectorTarget?
    private var networkTrackingTarget: WebInspectorTarget?
    private var runtimeTrackingTarget: WebInspectorTarget?
    private var consoleTrackingTarget: WebInspectorTarget?
    private var nodesByID: [DOMNode.ID: DOMNode]
    private var frameDocumentProjectionIndex: FrameDocumentProjectionIndex
    private var treeStates: [WeakDOMTreeState]
    private let statusRelay: WebInspectorAsyncStreamRelay<Status>
    private var requestsByID: [NetworkRequest.ID: NetworkRequest]
    private var orderedRequestIDs: [NetworkRequest.ID]
    private var clearedNetworkRequestIDs: Set<NetworkRequest.ID>
    private var networkFetchedResults: [WeakWebInspectorFetchedResults<NetworkRequest>]
    private var consoleMessagesByID: [ConsoleMessage.ID: ConsoleMessage]
    private var orderedConsoleMessageIDs: [ConsoleMessage.ID]
    private var lastConsoleMessageID: ConsoleMessage.ID?
    private var nextConsoleMessageOrdinal: Int
    private var consoleFetchedResults: [WeakWebInspectorFetchedResults<ConsoleMessage>]
    private var runtimeContextsByID: [RuntimeContext.ID: RuntimeContext]
    private var orderedRuntimeContextIDs: [RuntimeContext.ID]
    private var runtimeObjectsByID: [RuntimeObject.ID: RuntimeObject]
    private var runtimeObjectIDsByProxyID: [Runtime.RemoteObject.ID: RuntimeObject.ID]
    private var runtimeObjectOwnersByID: [RuntimeObject.ID: Set<RuntimeObjectOwner>]
    private var nextRuntimeObjectOrdinal: Int
    private var pendingInspectedNodeID: DOMNode.ID?
    private var consoleObjectGroupReleaseTask: Task<Void, Never>?
    private var pageHighlightDocumentGeneration: Int?

    public init(_ container: WebInspectorContainer, isolation: isolated (any Actor)) {
        self.container = container
        proxy = container.proxy
        domainEnablement = container.domainEnablement
        owner = isolation
        state = .attaching
        teardownError = nil
        rootNode = nil
        selectedNode = nil
        isElementPickerEnabled = false
        executionContexts = []
        selectedContext = nil
        currentPage = nil
        currentPageGeneration = 0
        domDocumentGeneration = 0
        startupTask = nil
        currentPageRetargetTask = nil
        currentPageCleanupTask = nil
        documentReloadTask = nil
        inspectResolutionTask = nil
        inspectedNodeHighlightTask = nil
        frameDocumentLoadTasks = [:]
        styleRefreshTask = nil
        styleRefreshGeneration = 0
        isStyleHydrationActive = false
        styleToggleTasks = [:]
        eventPumps = []
        inspectorTrackingTarget = nil
        networkTrackingTarget = nil
        runtimeTrackingTarget = nil
        consoleTrackingTarget = nil
        nodesByID = [:]
        frameDocumentProjectionIndex = FrameDocumentProjectionIndex()
        treeStates = []
        statusRelay = WebInspectorAsyncStreamRelay()
        requestsByID = [:]
        orderedRequestIDs = []
        clearedNetworkRequestIDs = []
        networkFetchedResults = []
        consoleMessagesByID = [:]
        orderedConsoleMessageIDs = []
        lastConsoleMessageID = nil
        nextConsoleMessageOrdinal = 0
        consoleFetchedResults = []
        runtimeContextsByID = [:]
        orderedRuntimeContextIDs = []
        runtimeObjectsByID = [:]
        runtimeObjectIDsByProxyID = [:]
        runtimeObjectOwnersByID = [:]
        nextRuntimeObjectOrdinal = 0
        pendingInspectedNodeID = nil
        consoleObjectGroupReleaseTask = nil
        pageHighlightDocumentGeneration = nil
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
        inspectResolutionTask?.cancel()
        inspectedNodeHighlightTask?.cancel()
        cancelFrameDocumentLoadTasks()
        styleRefreshTask?.cancel()
        for task in styleToggleTasks.values {
            task.cancel()
        }
        stopEventPumps()
        consoleObjectGroupReleaseTask?.cancel()
    }

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

    public func node(for id: DOMNode.ID, isolation: isolated (any Actor) = #isolation) -> DOMNode? {
        requireOwner(isolation)
        return nodesByID[id]
    }

    package func requiredNode(for id: DOMNode.ID, isolation: isolated (any Actor) = #isolation) throws -> DOMNode {
        requireOwner(isolation)
        guard let node = nodesByID[id] else {
            throw WebInspectorProxyError.disconnected("DOMNode is not registered in this WebInspectorContext.")
        }
        return node
    }

    public func registeredRequest(
        for id: NetworkRequest.ID,
        isolation: isolated (any Actor) = #isolation
    ) -> NetworkRequest? {
        requireOwner(isolation)
        return requestsByID[id]
    }

    package func registeredRequest(
        forProxyID id: Network.Request.ID,
        isolation: isolated (any Actor) = #isolation
    ) -> NetworkRequest? {
        requireOwner(isolation)
        return requestsByID[NetworkRequest.ID(id)]
    }

    public func clearNetworkRequests(isolation: isolated (any Actor) = #isolation) {
        requireOwner(isolation)
        clearNetworkRequests()
    }

    public func registeredMessage(
        for id: ConsoleMessage.ID,
        isolation: isolated (any Actor) = #isolation
    ) -> ConsoleMessage? {
        requireOwner(isolation)
        return consoleMessagesByID[id]
    }

    public func select(_ node: DOMNode?, isolation: isolated (any Actor) = #isolation) {
        select(node, reveal: .selectAndScroll, isolation: isolation)
    }

    private func select(
        _ node: DOMNode?,
        reveal: DOMRevealPolicy,
        isolation: isolated (any Actor)
    ) {
        requireOwner(isolation)
        if let node, nodesByID[node.id] !== node {
            preconditionFailure("DOMNode is not registered in this WebInspectorContext.")
        }
        pendingInspectedNodeID = nil
        inspectResolutionTask?.cancel()
        inspectResolutionTask = nil
        inspectedNodeHighlightTask?.cancel()
        inspectedNodeHighlightTask = nil
        selectedNode = node
        notifyDOMTreeSelectionChanged(node, reveal: reveal, isolation: isolation)
        notifyStatusChanged()
        refreshSelectedStyles(isolation: isolation)
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
        let page = try currentPageOrThrow()
        try await page.dom.setAttributeValue(node.id.proxyID, name: name, value: value)
        try await Self.markDOMUndoableStateIfNeeded(on: page, options: options)
    }

    package func setDOMOuterHTML(
        _ html: String,
        of id: DOMNode.ID,
        options: WebInspectorMutationOptions,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        requireOwner(isolation)
        let node = try requiredNode(for: id, isolation: isolation)
        let page = try currentPageOrThrow()
        try await page.dom.setOuterHTML(node.id.proxyID, html: html)
        try await Self.markDOMUndoableStateIfNeeded(on: page, options: options)
    }

    package func removeDOMNodes(
        _ nodeIDs: [DOMNode.ID],
        options: WebInspectorMutationOptions,
        isolation: isolated (any Actor) = #isolation
    ) async throws -> DOMMutationResult {
        requireOwner(isolation)
        let page = try currentPageOrThrow()
        var seenNodeIDs: Set<DOMNode.ID> = []
        let uniqueNodes = try nodeIDs
            .map { try requiredNode(for: $0, isolation: isolation) }
            .filter { seenNodeIDs.insert($0.id).inserted }
        let snapshot = try currentDOMTreeSnapshot(containing: uniqueNodes)
        let sortedNodes = uniqueNodes.sorted {
            snapshot.ancestorNodeIDs(of: $0.id).count > snapshot.ancestorNodeIDs(of: $1.id).count
        }
        var acceptedNodeIDs: [DOMNode.ID] = []
        for node in sortedNodes {
            do {
                try await page.dom.removeNode(node.id.proxyID)
                try await Self.markDOMUndoableStateIfNeeded(on: page, options: options)
                acceptedNodeIDs.append(node.id)
            } catch {
                if acceptedNodeIDs.isEmpty == false {
                    clearSelectionIfDeleted(acceptedNodeIDs, snapshot: snapshot, isolation: isolation)
                    throw DOMDeletionPartialFailure(
                        deletedNodeCount: acceptedNodeIDs.count,
                        underlyingError: error
                    )
                }
                throw error
            }
        }
        clearSelectionIfDeleted(acceptedNodeIDs, snapshot: snapshot, isolation: isolation)
        return DOMMutationResult(requestedNodeIDs: nodeIDs, acceptedNodeIDs: acceptedNodeIDs)
    }

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
            return try currentDOMTreeSnapshot(containing: [node]).selectorPath(for: node.id)
        case .xPath:
            return try currentDOMTreeSnapshot(containing: [node]).xPath(for: node.id)
        }
    }

    package func copyText(
        _ kind: DOMNode.CopyTextKind,
        for id: DOMNode.ID,
        isolation: isolated (any Actor) = #isolation
    ) async throws -> String {
        try await copyText(kind, for: try requiredNode(for: id, isolation: isolation), isolation: isolation)
    }

    public func delete(_ node: DOMNode, isolation: isolated (any Actor) = #isolation) async throws {
        try await delete([node], isolation: isolation)
    }

    public func delete(_ nodes: [DOMNode], isolation: isolated (any Actor) = #isolation) async throws {
        _ = try await deleteCountingRemovedNodes(nodes, isolation: isolation)
    }

    @discardableResult
    private func deleteCountingRemovedNodes(
        _ nodes: [DOMNode],
        isolation: isolated (any Actor) = #isolation
    ) async throws -> Int {
        requireOwner(isolation)
        let page = try currentPageOrThrow()
        var seenNodeIDs: Set<DOMNode.ID> = []
        let uniqueNodes = try nodes
            .map { try registeredNode($0) }
            .filter { seenNodeIDs.insert($0.id).inserted }
        let snapshot = try currentDOMTreeSnapshot(containing: uniqueNodes)
        let sortedNodes = uniqueNodes
            .sorted {
                snapshot.ancestorNodeIDs(of: $0.id).count > snapshot.ancestorNodeIDs(of: $1.id).count
            }
        var removedNodes: [DOMNode] = []
        for node in sortedNodes {
            do {
                try await page.dom.removeNode(node.id.proxyID)
                try await page.dom.markUndoableState()
                removedNodes.append(node)
            } catch {
                if removedNodes.isEmpty == false {
                    clearSelectionIfDeleted(removedNodes.map(\.id), snapshot: snapshot, isolation: isolation)
                    throw DOMDeletionPartialFailure(
                        deletedNodeCount: removedNodes.count,
                        underlyingError: error
                    )
                }
                throw error
            }
        }
        clearSelectionIfDeleted(removedNodes.map(\.id), snapshot: snapshot, isolation: isolation)
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
            .map { try requiredNode(for: $0, isolation: isolation) }
        return try await deleteCountingRemovedNodes(nodes, isolation: isolation)
    }

    #if DEBUG
    package func installCurrentPageRetargetTaskForTesting(_ task: Task<Void, Never>) {
        currentPageRetargetTask = task
    }
    #endif

    public func highlight(_ node: DOMNode, isolation: isolated (any Actor) = #isolation) async throws {
        requireOwner(isolation)
        try registeredNode(node)
        let page = try currentPageOrThrow()
        if node.id.proxyID.targetScopeRawValue == nil {
            recordPageHighlight(documentGeneration: domDocumentGeneration, isolation: isolation)
        }
        try await page.dom.highlightNode(node.id.proxyID)
    }

    package func highlightNode(for id: DOMNode.ID, isolation: isolated (any Actor) = #isolation) async throws {
        try await highlight(try requiredNode(for: id, isolation: isolation), isolation: isolation)
    }

    public func hideHighlight(isolation: isolated (any Actor) = #isolation) async throws {
        requireOwner(isolation)
        let page = try currentPageOrThrow()
        try await page.dom.hideHighlight()
        pageHighlightDocumentGeneration = nil
    }

    package func domUndoRedoCommands(isolation: isolated (any Actor) = #isolation) throws -> DOMUndoRedoCommands {
        requireOwner(isolation)
        return DOMUndoRedoCommands(
            context: self,
            target: try currentPageOrThrow(),
            documentGeneration: domDocumentGeneration
        )
    }

    package func undoDOMChange(isolation: isolated (any Actor) = #isolation) async throws {
        try await domUndoRedoCommands(isolation: isolation).undo(isolation: isolation)
    }

    package func redoDOMChange(isolation: isolated (any Actor) = #isolation) async throws {
        try await domUndoRedoCommands(isolation: isolation).redo(isolation: isolation)
    }

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
        isElementPickerEnabled = isEnabled
        notifyStatusChanged()
        WebInspectorDataKitLog.debug(
            "DOM picker setInspectMode finished enabled=\(isEnabled) target=\(page.id.rawValue)"
        )
    }

    public func reloadPage(
        ignoringCache: Bool = false,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        requireOwner(isolation)
        let page = try currentPageOrThrow()
        try await page.page.reload(ignoringCache: ignoringCache)
    }

    public func selectorPath(for node: DOMNode, isolation: isolated (any Actor) = #isolation) throws -> String {
        requireOwner(isolation)
        try registeredNode(node)
        return try currentDOMTreeSnapshot(containing: [node]).selectorPath(for: node.id)
    }

    package func selectorPath(for id: DOMNode.ID, isolation: isolated (any Actor) = #isolation) throws -> String {
        try selectorPath(for: try requiredNode(for: id, isolation: isolation), isolation: isolation)
    }

    public func xPath(for node: DOMNode, isolation: isolated (any Actor) = #isolation) throws -> String {
        requireOwner(isolation)
        try registeredNode(node)
        return try currentDOMTreeSnapshot(containing: [node]).xPath(for: node.id)
    }

    package func xPath(for id: DOMNode.ID, isolation: isolated (any Actor) = #isolation) throws -> String {
        try xPath(for: try requiredNode(for: id, isolation: isolation), isolation: isolation)
    }

    public func treeController(
        root requestedRoot: DOMNode? = nil,
        isolation: isolated (any Actor) = #isolation
    ) async throws -> DOMTreeController {
        requireOwner(isolation)
        guard let root = requestedRoot ?? rootNode else {
            throw WebInspectorProxyError.disconnected("WebInspectorDataKit has no DOM root node.")
        }
        guard nodesByID[root.id] === root else {
            preconditionFailure("DOMTreeController root is not registered in this WebInspectorContext.")
        }

        let tree = DOMTreeState(rootNode: root, selectedNode: selectedNode)
        treeStates.append(WeakDOMTreeState(tree))
        pruneReleasedTreeStates()
        return DOMTreeController(tree: tree)
    }

    package func rootTreeController(isolation: isolated (any Actor) = #isolation) -> DOMTreeController {
        requireOwner(isolation)
        let tree = DOMTreeState(rootNode: rootNode, selectedNode: selectedNode)
        treeStates.append(WeakDOMTreeState(tree))
        pruneReleasedTreeStates()
        return DOMTreeController(tree: tree)
    }

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
            let plan = NetworkRequestQueryPlan(descriptor: networkResults.fetchDescriptor, context: self)
            networkResults.setNetworkItems(
                currentNetworkRequests(),
                plan: plan,
                lookup: { id in self.requestsByID[id] }
            )
            networkFetchedResults.append(WeakWebInspectorFetchedResults(networkResults))
        case .consoleMessages:
            guard let consoleResults = results as? WebInspectorFetchedResults<ConsoleMessage> else {
                preconditionFailure("ConsoleMessage descriptors can only fetch ConsoleMessage models.")
            }
            consoleResults.setItems(consoleMessages(for: consoleResults.fetchDescriptor))
            consoleFetchedResults.append(WeakWebInspectorFetchedResults(consoleResults))
        }
        return results
    }

    public func fetchedResults<Model: WebInspectorFetchableModel>(
        for request: WebInspectorFetchRequest<Model>,
        sectionBy: WebInspectorSectionDescriptor<Model>? = nil,
        isolation: isolated (any Actor) = #isolation
    ) -> WebInspectorFetchedResults<Model> {
        fetchedResults(for: request.fetchDescriptor, sectionBy: sectionBy, isolation: isolation)
    }

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

    public func fetchedResultsController<Model: WebInspectorFetchableModel>(
        for descriptor: WebInspectorFetchDescriptor<Model> = .init(),
        sectionBy: WebInspectorSectionDescriptor<Model>? = nil,
        isolation: isolated (any Actor) = #isolation
    ) -> WebInspectorFetchedResultsController<Model> {
        requireOwner(isolation)
        return WebInspectorFetchedResultsController(
            fetchedResults: fetchedResults(for: descriptor, sectionBy: sectionBy, isolation: isolation)
        )
    }

    public func fetchedResultsController<Model: WebInspectorFetchableModel>(
        for request: WebInspectorFetchRequest<Model>,
        sectionBy: WebInspectorSectionDescriptor<Model>? = nil,
        isolation: isolated (any Actor) = #isolation
    ) -> WebInspectorFetchedResultsController<Model> {
        WebInspectorFetchedResultsController(
            fetchedResults: fetchedResults(for: request, sectionBy: sectionBy, isolation: isolation)
        )
    }

    public func fetchedResultsController<Model: WebInspectorFetchableModel>(
        for descriptor: WebInspectorFetchDescriptor<Model> = .init(),
        sectionBy keyPath: KeyPath<Model, String>,
        isolation: isolated (any Actor) = #isolation
    ) -> WebInspectorFetchedResultsController<Model> {
        WebInspectorFetchedResultsController(
            fetchedResults: fetchedResults(for: descriptor, sectionBy: keyPath, isolation: isolation)
        )
    }

    public func fetchedResultsController<Model: WebInspectorFetchableModel>(
        for descriptor: WebInspectorFetchDescriptor<Model> = .init(),
        sectionBy keyPath: KeyPath<Model, String?>,
        isolation: isolated (any Actor) = #isolation
    ) -> WebInspectorFetchedResultsController<Model> {
        WebInspectorFetchedResultsController(
            fetchedResults: fetchedResults(for: descriptor, sectionBy: keyPath, isolation: isolation)
        )
    }

    public func fetchedResultsController<
        Model: WebInspectorFetchableModel,
        Value: RawRepresentable & Hashable & Sendable
    >(
        for descriptor: WebInspectorFetchDescriptor<Model> = .init(),
        sectionBy keyPath: KeyPath<Model, Value>,
        isolation: isolated (any Actor) = #isolation
    ) -> WebInspectorFetchedResultsController<Model> where Value.RawValue == String {
        WebInspectorFetchedResultsController(
            fetchedResults: fetchedResults(for: descriptor, sectionBy: keyPath, isolation: isolation)
        )
    }

    public func fetchedResultsController<
        Model: WebInspectorFetchableModel,
        Value: RawRepresentable & Hashable & Sendable
    >(
        for descriptor: WebInspectorFetchDescriptor<Model> = .init(),
        sectionBy keyPath: KeyPath<Model, Value?>,
        isolation: isolated (any Actor) = #isolation
    ) -> WebInspectorFetchedResultsController<Model> where Value.RawValue == String {
        WebInspectorFetchedResultsController(
            fetchedResults: fetchedResults(for: descriptor, sectionBy: keyPath, isolation: isolation)
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
            let plan = NetworkRequestQueryPlan(descriptor: networkDescriptor, context: self)
            networkResults.applyNetworkFetchDescriptor(
                networkDescriptor,
                plan: plan,
                requests: currentNetworkRequests(),
                lookup: { id in self.requestsByID[id] }
            )
        case .consoleMessages:
            guard let consoleDescriptor = descriptor as? WebInspectorFetchDescriptor<ConsoleMessage>,
                  let consoleResults = results as? WebInspectorFetchedResults<ConsoleMessage> else {
                preconditionFailure("ConsoleMessage descriptors can only update ConsoleMessage fetched results.")
            }
            consoleResults.applyFetchDescriptor(consoleDescriptor, items: consoleMessages(for: consoleDescriptor))
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
        isolation: isolated (any Actor) = #isolation
    ) async {
        requireOwner(isolation)
        guard let currentPage else {
            request.finishResponseBodyFetch(
                result: .failure(.disconnected("WebInspectorDataKit has no current page target."))
            )
            return
        }

        do {
            let body = try await currentPage.network.responseBody(for: request.proxyID)
            request.finishResponseBodyFetch(result: .success(body))
        } catch let error as WebInspectorProxyError {
            request.finishResponseBodyFetch(result: .failure(error))
        } catch {
            request.finishResponseBodyFetch(result: .failure(.commandFailed(
                domain: "Network",
                method: "getResponseBody",
                message: String(describing: error)
            )))
        }
    }

    func requestChildren(
        for node: DOMNode,
        depth: Int,
        isolation: isolated (any Actor) = #isolation
    ) async {
        requireOwner(isolation)
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
        inspectResolutionTask?.cancel()
        inspectResolutionTask = nil
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
        consoleObjectGroupReleaseTask?.cancel()
        consoleObjectGroupReleaseTask = nil
        pendingInspectedNodeID = nil
        isElementPickerEnabled = false
        currentPage = nil
        advanceCurrentPageGeneration(isolation: isolation)
        advanceDOMDocumentGeneration(isolation: isolation)
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
            resetReplayBackedModelsBeforeEnable()
            try await enableInspectorTracking(on: target, isolation: isolation)
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation(isolation: isolation)
                return
            }
            guard isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            try await enableRuntimeTracking(on: target, isolation: isolation)
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation(isolation: isolation)
                return
            }
            guard isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            try await enableNetworkTracking(on: target, isolation: isolation)
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
            try await enableConsoleTracking(on: target, isolation: isolation)
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
            applyDocument(document.node, isolation: isolation)
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
        isolation: isolated (any Actor)
    ) async throws {
        _ = isolation
        try await domainEnablement.acquire(.inspector, on: target)
        inspectorTrackingTarget = target
    }

    private func enableRuntimeTracking(
        on target: WebInspectorTarget,
        isolation: isolated (any Actor)
    ) async throws {
        _ = isolation
        try await domainEnablement.acquire(.runtime, on: target)
        runtimeTrackingTarget = target
    }

    private func enableConsoleTracking(
        on target: WebInspectorTarget,
        isolation: isolated (any Actor)
    ) async throws {
        _ = isolation
        try await domainEnablement.acquire(.console, on: target)
        consoleTrackingTarget = target
    }

    private func enableNetworkTracking(
        on target: WebInspectorTarget,
        isolation: isolated (any Actor)
    ) async throws {
        _ = isolation
        try await domainEnablement.acquire(.network, on: target)
        networkTrackingTarget = target
    }

    private func loadCurrentDOMDocument(
        on target: WebInspectorTarget,
        isolation: isolated (any Actor)
    ) async throws -> LoadedDOMDocument {
        _ = isolation
        while true {
            let generation = domDocumentGeneration
            let document = try await target.dom.getDocument()
            guard Task.isCancelled == false else {
                throw CancellationError()
            }
            guard isDOMDocumentGeneration(generation, isolation: isolation) else {
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
        if isDOMDocumentGeneration(document.generation, isolation: isolation) {
            return document
        }
        return try await loadCurrentDOMDocument(on: target, isolation: isolation)
    }

    private func resetReplayBackedModelsBeforeEnable() {
        clearExecutionContexts()
        consoleMessagesByID = [:]
        orderedConsoleMessageIDs = []
        lastConsoleMessageID = nil
        refreshAllConsoleMessages()
    }

    private func resetCurrentPageLifecycleModels(isolation: isolated (any Actor)) {
        resetDOM(isolation: isolation)
        clearExecutionContexts()
        clearConsoleMessages()
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
            self?.apply(event, isolation: isolation)
        }

        let networkPump = WebInspectorEventPump(stream: target.network.events, isolation: isolation) { [weak self] event in
            self?.apply(event, isolation: isolation)
        }

        let cssPump = WebInspectorEventPump(stream: target.css.events, isolation: isolation) { [weak self] event in
            self?.apply(event, isolation: isolation)
        }

        let consolePump = WebInspectorEventPump(stream: target.console.events, isolation: isolation) { [weak self] event in
            self?.apply(event, isolation: isolation)
        }

        let runtimePump = WebInspectorEventPump(stream: target.runtime.events, isolation: isolation) { [weak self, targetID = target.id] event in
            self?.apply(event, targetID: targetID, isolation: isolation)
        }

        let lifecyclePump = WebInspectorEventPump(stream: target.lifecycleEvents, isolation: isolation) { [weak self] event in
            self?.apply(event, isolation: isolation)
        }

        eventPumps = [domPump, networkPump, cssPump, consolePump, runtimePump, lifecyclePump]
    }

    private func stopEventPumps() {
        for pump in eventPumps {
            pump.stop()
        }
        eventPumps = []
    }

    private func notifyDOMTreeSnapshot(
        reason: DOMTreeSnapshotReason,
        isolation: isolated (any Actor)
    ) {
        _ = isolation
        pruneReleasedTreeStates()
        for reference in treeStates {
            reference.tree?.applySnapshot(rootNode: rootNode, selectedNode: selectedNode, reason: reason)
        }
    }

    private func notifyDOMTreeChildrenReplaced(parent: DOMNode, isolation: isolated (any Actor)) {
        _ = isolation
        pruneReleasedTreeStates()
        for reference in treeStates {
            reference.tree?.applyChildrenReplaced(parent: parent)
        }
    }

    private func notifyDOMTreeChildInserted(
        parent: DOMNode,
        node: DOMNode,
        previousSiblingID: DOMNode.ID?,
        isolation: isolated (any Actor)
    ) {
        _ = isolation
        pruneReleasedTreeStates()
        for reference in treeStates {
            reference.tree?.applyChildInserted(parent: parent, node: node, previousSiblingID: previousSiblingID)
        }
    }

    private func notifyDOMTreeChildRemoved(
        parent: DOMNode,
        nodeID: DOMNode.ID,
        isolation: isolated (any Actor)
    ) {
        _ = isolation
        pruneReleasedTreeStates()
        for reference in treeStates {
            reference.tree?.applyChildRemoved(parent: parent, nodeID: nodeID)
        }
    }

    private func notifyDOMTreeChildCountChanged(node: DOMNode, isolation: isolated (any Actor)) {
        _ = isolation
        pruneReleasedTreeStates()
        for reference in treeStates {
            reference.tree?.applyChildCountChanged(node: node)
        }
    }

    private func notifyDOMTreeNodeChanged(_ node: DOMNode, isolation: isolated (any Actor)) {
        _ = isolation
        pruneReleasedTreeStates()
        for reference in treeStates {
            reference.tree?.applyNodeChanged(node)
        }
    }

    private func notifyDOMTreeSelectionChanged(
        _ node: DOMNode?,
        reveal: DOMRevealPolicy = .selectAndScroll,
        isolation: isolated (any Actor)
    ) {
        _ = isolation
        pruneReleasedTreeStates()
        for reference in treeStates {
            reference.tree?.applySelectionChanged(nodeID: node?.id, reveal: reveal)
        }
    }

    private func clearSelectionIfDeleted(
        _ deletedRootIDs: [DOMNode.ID],
        snapshot: DOMTreeSnapshot,
        isolation: isolated (any Actor)
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
        notifyDOMTreeSelectionChanged(nil, isolation: isolation)
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

    private static func markDOMUndoableStateIfNeeded(
        on page: WebInspectorTarget,
        options: WebInspectorMutationOptions
    ) async throws {
        switch options.undo {
        case .automatic:
            try await page.dom.markUndoableState()
        case .disabled:
            break
        }
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
        _ generation: Int,
        isolation: isolated (any Actor)
    ) -> Bool {
        _ = isolation
        return currentPageGeneration == generation
    }

    private func isDOMDocumentGeneration(
        _ generation: Int,
        isolation: isolated (any Actor)
    ) -> Bool {
        _ = isolation
        return domDocumentGeneration == generation
    }

    @discardableResult
    private func advanceCurrentPageGeneration(isolation: isolated (any Actor)) -> Int {
        _ = isolation
        currentPageGeneration += 1
        return currentPageGeneration
    }

    @discardableResult
    private func advanceDOMDocumentGeneration(isolation: isolated (any Actor)) -> Int {
        _ = isolation
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

    private func logDescription(_ id: DOMNode.ID) -> String {
        logDescription(id.proxyID)
    }

    private func logDescription(_ id: DOM.Node.ID) -> String {
        "\(id.unscopedRawValue)@\(id.targetScopeRawValue ?? "current-page")"
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

    func reloadDocument(isolation: isolated (any Actor) = #isolation) {
        requireOwner(isolation)
        guard let currentPage else {
            skipEvent("reloadDocument ignored: no current page target")
            return
        }

        let generation = domDocumentGeneration
        documentReloadTask?.cancel()
        documentReloadTask = Task { [weak self, currentPage, generation] in
            _ = isolation
            do {
                let document = try await currentPage.dom.getDocument()
                guard Task.isCancelled == false else {
                    return
                }
                guard self?.isDOMDocumentGeneration(generation, isolation: isolation) == true else {
                    return
                }
                self?.applyDocument(document, reason: .documentUpdated, isolation: isolation)
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

        currentPageRetargetTask?.cancel()
        documentReloadTask?.cancel()
        documentReloadTask = nil
        let generation = advanceCurrentPageGeneration(isolation: isolation)
        advanceDOMDocumentGeneration(isolation: isolation)
        resetCurrentPageLifecycleModels(isolation: isolation)
        consoleObjectGroupReleaseTask?.cancel()
        consoleObjectGroupReleaseTask = nil
        for task in styleToggleTasks.values {
            task.cancel()
        }
        styleToggleTasks = [:]

        currentPageRetargetTask = Task { [weak self, target, generation] in
            _ = isolation
            await self?.retargetCurrentPage(target, generation: generation, isolation: isolation)
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
            try await enableInspectorTracking(on: target, isolation: isolation)
            guard Task.isCancelled == false, isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            try await enableRuntimeTracking(on: target, isolation: isolation)
            guard Task.isCancelled == false, isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            try await enableNetworkTracking(on: target, isolation: isolation)
            guard Task.isCancelled == false, isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            var document = try await loadCurrentDOMDocument(on: target, isolation: isolation)
            guard Task.isCancelled == false, isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            try await enableConsoleTracking(on: target, isolation: isolation)
            guard Task.isCancelled == false, isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            document = try await reloadDOMDocumentIfNeeded(document, on: target, isolation: isolation)
            guard Task.isCancelled == false, isCurrentPageGeneration(generation, isolation: isolation) else {
                return
            }
            applyDocument(document.node, reason: .pageChanged, isolation: isolation)
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
            detachProjectedFrameDocument(forFrameID: frame.id, isolation: isolation)
            return
        }
        advanceDOMDocumentGeneration(isolation: isolation)
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
        detachProjectedFrameDocument(forFrameID: frameID, isolation: isolation)
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
        consoleObjectGroupReleaseTask?.cancel()
        consoleObjectGroupReleaseTask = nil
        let generation = advanceCurrentPageGeneration(isolation: isolation)
        advanceDOMDocumentGeneration(isolation: isolation)

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
            let replacement = try await proxy.waitForCurrentPage()
            guard Task.isCancelled == false, isCurrentPageGeneration(generation, isolation: isolation) else {
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
        switch event {
        case .documentUpdated:
            advanceDOMDocumentGeneration(isolation: isolation)
            resetDOM(isolation: isolation)
            guard state != .attaching else {
                return
            }
            reloadDocument(isolation: isolation)
        case let .setChildNodes(parent, nodes):
            applySetChildNodes(parent: parent, nodes: nodes, isolation: isolation)
        case let .childNodeInserted(parent, previous, node):
            applyChildNodeInserted(parent: parent, previous: previous, node: node, isolation: isolation)
        case let .childNodeRemoved(parent, node):
            applyChildNodeRemoved(parent: parent, node: node, isolation: isolation)
        case let .childNodeCountUpdated(id, count):
            guard let node = nodesByID[DOMNode.ID(id)] else {
                let nodeID = DOMNode.ID(id)
                loadFrameDocumentIfNeeded(forNodeID: nodeID, reason: "DOM.childNodeCountUpdated", isolation: isolation)
                skipEvent("DOM.childNodeCountUpdated referenced unmaterialized node id=\(logDescription(nodeID))")
                return
            }
            node.updateChildNodeCount(count)
            notifyDOMTreeChildCountChanged(node: node, isolation: isolation)
        case let .attributeModified(id, name, value):
            guard let node = nodesByID[DOMNode.ID(id)] else {
                let nodeID = DOMNode.ID(id)
                loadFrameDocumentIfNeeded(forNodeID: nodeID, reason: "DOM.attributeModified", isolation: isolation)
                skipEvent("DOM.attributeModified referenced unmaterialized node id=\(logDescription(nodeID))")
                return
            }
            node.setAttribute(name: name, value: value)
            markSelectedStylesNeedsRefresh(for: DOMNode.ID(id))
            notifyDOMTreeNodeChanged(node, isolation: isolation)
        case let .attributeRemoved(id, name):
            guard let node = nodesByID[DOMNode.ID(id)] else {
                let nodeID = DOMNode.ID(id)
                loadFrameDocumentIfNeeded(forNodeID: nodeID, reason: "DOM.attributeRemoved", isolation: isolation)
                skipEvent("DOM.attributeRemoved referenced unmaterialized node id=\(logDescription(nodeID))")
                return
            }
            node.removeAttribute(name: name)
            markSelectedStylesNeedsRefresh(for: DOMNode.ID(id))
            notifyDOMTreeNodeChanged(node, isolation: isolation)
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
                loadFrameDocumentIfNeeded(forNodeID: nodeID, reason: "DOM.characterDataModified", isolation: isolation)
                skipEvent("DOM.characterDataModified referenced unmaterialized node id=\(logDescription(nodeID))")
                return
            }
            node.setNodeValue(value)
            markSelectedStylesNeedsRefresh(for: DOMNode.ID(id))
            notifyDOMTreeNodeChanged(node, isolation: isolation)
        case let .inspect(id):
            isElementPickerEnabled = false
            notifyStatusChanged()
            let inspectedNodeID = DOMNode.ID(id)
            guard let node = nodesByID[inspectedNodeID] else {
                loadFrameDocumentIfNeeded(forNodeID: inspectedNodeID, reason: "DOM.inspect", isolation: isolation)
                WebInspectorDataKitLog.debug(
                    "DOM.inspect pending nodeID=\(String(describing: inspectedNodeID)) materialized=false root=\(String(describing: rootNode?.id))"
                )
                pendingInspectedNodeID = inspectedNodeID
                resolvePendingInspectedNode(requestSubtreeIfNeeded: true, isolation: isolation)
                return
            }
            guard isNodeAttachedToCurrentDOMTree(node) else {
                loadFrameDocumentIfNeeded(forNodeID: inspectedNodeID, reason: "DOM.inspect", isolation: isolation)
                pendingInspectedNodeID = inspectedNodeID
                resolvePendingInspectedNode(requestSubtreeIfNeeded: true, isolation: isolation)
                return
            }
            WebInspectorDataKitLog.debug(
                "DOM.inspect selecting nodeID=\(String(describing: inspectedNodeID)) materialized=true"
            )
            pendingInspectedNodeID = nil
            inspectResolutionTask?.cancel()
            inspectResolutionTask = nil
            selectInspectedNode(node, isolation: isolation)
        case .detachedRoot,
             .shadowRootPushed,
             .shadowRootPopped,
             .pseudoElementAdded,
             .pseudoElementRemoved,
             .willDestroyDOMNode,
             .unknown:
            break
        }
    }

    func applyDocument(
        _ node: DOM.Node,
        reason: DOMTreeSnapshotReason = .initialDocument,
        isolation: isolated (any Actor) = #isolation
    ) {
        requireOwner(isolation)
        var materializedPayloadIDs = Set<DOMNode.ID>()
        collectMaterializedPayloadIDs(node, into: &materializedPayloadIDs)
        rootNode = model(for: node, preserving: materializedPayloadIDs)
        notifyDOMTreeSnapshot(reason: reason, isolation: isolation)
        resolvePendingInspectedNode(requestSubtreeIfNeeded: true, isolation: isolation)
    }

    package func seedDOMDocument(_ node: DOM.Node, isolation: isolated (any Actor) = #isolation) {
        applyDocument(
            node,
            reason: rootNode == nil ? .initialDocument : .documentUpdated,
            isolation: isolation
        )
    }

    package func seedElementPickerEnabled(_ isEnabled: Bool, isolation: isolated (any Actor) = #isolation) {
        requireOwner(isolation)
        isElementPickerEnabled = isEnabled
        notifyStatusChanged()
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

    private func resetDOM(isolation: isolated (any Actor)) {
        inspectResolutionTask?.cancel()
        inspectResolutionTask = nil
        styleRefreshTask?.cancel()
        styleRefreshTask = nil
        styleRefreshGeneration += 1
        inspectedNodeHighlightTask?.cancel()
        inspectedNodeHighlightTask = nil
        clearPageHighlightForDOMReset(isolation: isolation)
        cancelFrameDocumentLoadTasks()
        rootNode = nil
        selectedNode = nil
        isElementPickerEnabled = false
        pendingInspectedNodeID = nil
        nodesByID = [:]
        frameDocumentProjectionIndex.removeAll()
        notifyDOMTreeSnapshot(reason: .reset, isolation: isolation)
        notifyStatusChanged()
    }

    private func recordPageHighlight(
        documentGeneration: Int,
        isolation: isolated (any Actor)
    ) {
        _ = isolation
        pageHighlightDocumentGeneration = documentGeneration
    }

    private func clearPageHighlightForDOMReset(isolation: isolated (any Actor)) {
        guard let currentPage else {
            return
        }
        guard pageHighlightDocumentGeneration != nil else {
            return
        }
        pageHighlightDocumentGeneration = nil
        inspectedNodeHighlightTask = Task { [weak self, currentPage] in
            _ = isolation
            do {
                guard Task.isCancelled == false else {
                    return
                }
                guard self?.shouldSendPageHighlightClearAfterDOMReset(isolation: isolation) == true else {
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

    private func shouldSendPageHighlightClearAfterDOMReset(
        isolation: isolated (any Actor)
    ) -> Bool {
        _ = isolation
        return pageHighlightDocumentGeneration == nil
    }

    private func applySetChildNodes(
        parent: DOM.Node.ID,
        nodes: [DOM.Node],
        isolation: isolated (any Actor) = #isolation
    ) {
        guard let parentNode = nodesByID[DOMNode.ID(parent)] else {
            let parentID = DOMNode.ID(parent)
            loadFrameDocumentIfNeeded(forNodeID: parentID, reason: "DOM.setChildNodes", isolation: isolation)
            skipEvent("DOM.setChildNodes referenced unmaterialized parent id=\(logDescription(parentID))")
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
        notifyDOMTreeChildrenReplaced(parent: parentNode, isolation: isolation)
        resolvePendingInspectedNode(requestSubtreeIfNeeded: false, isolation: isolation)
    }

    private func applyChildNodeInserted(
        parent: DOM.Node.ID,
        previous: DOM.Node.ID?,
        node: DOM.Node,
        isolation: isolated (any Actor) = #isolation
    ) {
        guard let parentNode = nodesByID[DOMNode.ID(parent)] else {
            let parentID = DOMNode.ID(parent)
            loadFrameDocumentIfNeeded(forNodeID: parentID, reason: "DOM.childNodeInserted", isolation: isolation)
            skipEvent("DOM.childNodeInserted referenced unmaterialized parent id=\(logDescription(parentID))")
            return
        }

        guard case var .loaded(children) = parentNode.children else {
            parentNode.updateChildNodeCount(parentNode.childNodeCount + 1)
            notifyDOMTreeChildCountChanged(node: parentNode, isolation: isolation)
            return
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
            previousSiblingID: previous.map(DOMNode.ID.init),
            isolation: isolation
        )
        resolvePendingInspectedNode(requestSubtreeIfNeeded: false, isolation: isolation)
    }

    private func applyChildNodeRemoved(
        parent: DOM.Node.ID,
        node: DOM.Node.ID,
        isolation: isolated (any Actor)
    ) {
        guard let parentNode = nodesByID[DOMNode.ID(parent)] else {
            let parentID = DOMNode.ID(parent)
            loadFrameDocumentIfNeeded(forNodeID: parentID, reason: "DOM.childNodeRemoved", isolation: isolation)
            skipEvent("DOM.childNodeRemoved referenced unmaterialized parent id=\(logDescription(parentID))")
            return
        }

        let removedID = DOMNode.ID(node)
        guard let removedNode = nodesByID[removedID] else {
            loadFrameDocumentIfNeeded(forNodeID: removedID, reason: "DOM.childNodeRemoved", isolation: isolation)
            skipEvent("DOM.childNodeRemoved referenced unmaterialized child id=\(logDescription(removedID))")
            return
        }
        let selectedNodeWasRemoved = removeSubtreeFromIndex(removedNode)

        guard case let .loaded(children) = parentNode.children else {
            parentNode.updateChildNodeCount(max(0, parentNode.childNodeCount - 1))
            notifyDOMTreeChildCountChanged(node: parentNode, isolation: isolation)
            if selectedNodeWasRemoved {
                notifyDOMTreeSelectionChanged(nil, isolation: isolation)
                notifyStatusChanged()
            }
            return
        }
        parentNode.setChildren(children.filter { $0.id != removedID })
        notifyDOMTreeChildRemoved(parent: parentNode, nodeID: removedID, isolation: isolation)
        if selectedNodeWasRemoved {
            notifyDOMTreeSelectionChanged(nil, isolation: isolation)
            notifyStatusChanged()
        }
    }

    @discardableResult
    private func removeSubtreeFromIndex(_ root: DOMNode, preserving preservedIDs: Set<DOMNode.ID> = []) -> Bool {
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

    private func model(for payload: DOM.Node, preserving materializedPayloadIDs: Set<DOMNode.ID>) -> DOMNode {
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

        let payloadContentDocument = payload.contentDocument.map { model(for: $0, preserving: materializedPayloadIDs) }
        let shadowRoots = payload.shadowRoots.map { model(for: $0, preserving: materializedPayloadIDs) }
        let templateContent = payload.templateContent.map { model(for: $0, preserving: materializedPayloadIDs) }
        let beforePseudoElement = payload.beforePseudoElement.map { model(for: $0, preserving: materializedPayloadIDs) }
        let otherPseudoElements = payload.otherPseudoElements.map { model(for: $0, preserving: materializedPayloadIDs) }
        let afterPseudoElement = payload.afterPseudoElement.map { model(for: $0, preserving: materializedPayloadIDs) }
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
        reason: String,
        isolation: isolated (any Actor)
    ) {
        guard let frameTargetID = frameTargetID(for: nodeID) else {
            return
        }
        if let rootID = frameDocumentProjectionIndex.frameDocumentRootID(for: frameTargetID),
           let root = nodesByID[rootID] {
            if let owner = attachProjectedFrameDocumentRoot(root, frameTargetID: frameTargetID) {
                notifyDOMTreeChildrenReplaced(parent: owner, isolation: isolation)
            }
            return
        }
        loadFrameDocumentIfNeeded(forFrameTargetID: frameTargetID, reason: reason, isolation: isolation)
    }

    private func loadFrameDocumentIfNeeded(
        forFrameTargetID frameTargetID: WebInspectorTarget.ID,
        reason: String,
        isolation: isolated (any Actor)
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
            _ = isolation
            do {
                let document = try await target.dom.getDocument()
                guard Task.isCancelled == false,
                      self?.isDOMDocumentGeneration(generation, isolation: isolation) == true else {
                    return
                }
                self?.applyFrameDocument(document, frameTargetID: frameTargetID, isolation: isolation)
            } catch is CancellationError {
                return
            } catch {
                guard self?.isDOMDocumentGeneration(generation, isolation: isolation) == true else {
                    return
                }
                self?.failIfTerminal(error, operation: "frame DOM.getDocument")
            }
            if self?.isDOMDocumentGeneration(generation, isolation: isolation) == true {
                self?.frameDocumentLoadTasks[frameTargetID] = nil
            }
        }
    }

    private func applyFrameDocument(
        _ document: DOM.Node,
        frameTargetID: WebInspectorTarget.ID,
        isolation: isolated (any Actor)
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
            notifyDOMTreeChildrenReplaced(parent: owner, isolation: isolation)
        }
        resolvePendingInspectedNode(requestSubtreeIfNeeded: true, isolation: isolation)
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
        forFrameID frameID: FrameID,
        isolation: isolated (any Actor)
    ) {
        let owners = nodesByID.values.filter { $0.isFrameOwner && $0.frameID == frameID }
        for owner in owners {
            guard let rootID = frameDocumentProjectionIndex.projectedFrameDocumentRootID(forOwnerNodeID: owner.id) else {
                continue
            }
            let root = nodesByID[rootID]
            frameDocumentProjectionIndex.detachProjection(attachedTo: owner.id)
            owner.setContentDocument(nil)
            let selectedNodeWasRemoved = root.map { removeSubtreeFromIndex($0) } ?? false
            notifyDOMTreeChildrenReplaced(parent: owner, isolation: isolation)
            if selectedNodeWasRemoved {
                notifyStatusChanged()
            }
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
        requestSubtreeIfNeeded: Bool,
        isolation: isolated (any Actor) = #isolation
    ) {
        guard let pendingInspectedNodeID else {
            return
        }
        guard let inspectedNode = nodesByID[pendingInspectedNodeID] else {
            if requestSubtreeIfNeeded {
                requestMaterializationForPendingInspectedNode(pendingInspectedNodeID, isolation: isolation)
            }
            return
        }
        guard isNodeAttachedToCurrentDOMTree(inspectedNode) else {
            if requestSubtreeIfNeeded {
                requestMaterializationForPendingInspectedNode(pendingInspectedNodeID, isolation: isolation)
            }
            return
        }
        WebInspectorDataKitLog.debug(
            "DOM.inspect resolved pending nodeID=\(String(describing: pendingInspectedNodeID))"
        )
        self.pendingInspectedNodeID = nil
        inspectResolutionTask?.cancel()
        inspectResolutionTask = nil
        selectInspectedNode(inspectedNode, isolation: isolation)
    }

    private func requestMaterializationForPendingInspectedNode(
        _ nodeID: DOMNode.ID,
        isolation: isolated (any Actor)
    ) {
        if let frameTargetID = frameTargetID(for: nodeID) {
            if let rootID = frameDocumentProjectionIndex.frameDocumentRootID(for: frameTargetID),
               let frameRoot = nodesByID[rootID] {
                WebInspectorDataKitLog.debug(
                    "DOM.inspect unresolved nodeID=\(String(describing: nodeID)); reattaching frame document root"
                )
                if let owner = attachProjectedFrameDocumentRoot(frameRoot, frameTargetID: frameTargetID) {
                    notifyDOMTreeChildrenReplaced(parent: owner, isolation: isolation)
                }
            } else {
                loadFrameDocumentIfNeeded(forFrameTargetID: frameTargetID, reason: "DOM.inspect", isolation: isolation)
            }
            return
        }
        WebInspectorDataKitLog.debug(
            "DOM.inspect unresolved nodeID=\(String(describing: nodeID)); waiting for DOM.requestNode path materialization"
        )
    }

    private func selectInspectedNode(_ node: DOMNode, isolation: isolated (any Actor)) {
        WebInspectorDataKitLog.debug("DOM.inspect selecting resolved nodeID=\(String(describing: node.id))")
        select(node, isolation: isolation)
        restoreElementPickerHighlight(for: node, isolation: isolation)
    }

    private func restoreElementPickerHighlight(for node: DOMNode, isolation: isolated (any Actor)) {
        guard let currentPage else {
            skipEvent("DOM.inspect highlight restore ignored: no current page target")
            return
        }
        let generation = domDocumentGeneration
        let nodeID = node.id.proxyID
        guard nodeID.targetScopeRawValue == nil else {
            return
        }
        inspectedNodeHighlightTask?.cancel()
        // Web Inspector clears the picker overlay after inspect. On touch devices
        // WebInspectorKit keeps the picked node highlighted so the tap target remains visible.
        inspectedNodeHighlightTask = Task { [weak self, currentPage, generation, nodeID] in
            _ = isolation
            do {
                guard Task.isCancelled == false,
                      self?.isDOMDocumentGeneration(generation, isolation: isolation) == true else {
                    return
                }
                WebInspectorDataKitLog.debug(
                    "DOM.inspect restoring highlight nodeID=\(String(describing: nodeID))"
                )
                self?.recordPageHighlight(documentGeneration: generation, isolation: isolation)
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

        guard let selectedNode else {
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
            try await target.css.enable()
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
        Task.isCancelled == false && selectedNode === node && styleRefreshGeneration == generation
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
        guard active, let styles = selectedNode?.elementStyles else {
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
        let node = try requiredNode(for: nodeID, isolation: isolation)
        guard node.nodeType == 1 else {
            throw WebInspectorProxyError.commandFailed(
                domain: "CSS",
                method: "getMatchedStylesForNode",
                message: "CSS styles are only available for element DOM nodes."
            )
        }
        if selectedNode !== node {
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
        _ id: CSS.Property.ID,
        enabled: Bool,
        options: WebInspectorMutationOptions,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        requireOwner(isolation)
        guard let currentPage,
              styleToggleTasks[id] == nil,
              let styles = selectedNode?.elementStyles,
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

        let result = try await currentPage.css.setStyleText(intent.styleID, text: intent.text)
        styles.applySetStyleText(result: result, for: id)
        refreshSelectedStylesIfHydrationActive(isolation: isolation)
        _ = options
    }

    package func setCSSRuleSelector(
        _ selector: String,
        for id: CSS.Rule.ID,
        options: WebInspectorMutationOptions,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        requireOwner(isolation)
        let page = try currentPageOrThrow()
        _ = try await page.css.setRuleSelector(id, selector: selector)
        refreshSelectedStylesIfHydrationActive(isolation: isolation)
        _ = options
    }

    package func setCSSStyleSheetText(
        _ text: String,
        for id: CSS.StyleSheet.ID,
        options: WebInspectorMutationOptions,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        requireOwner(isolation)
        let page = try currentPageOrThrow()
        try await page.css.setStyleSheetText(id, text: text)
        refreshSelectedStylesIfHydrationActive(isolation: isolation)
        _ = options
    }

    /// Toggles a CSS declaration on or off by rewriting its owning style
    /// text. Returns false without issuing a command when the property is
    /// not currently editable (no selected styles, stale phase, read-only
    /// section, or unrewritable style text), or when a toggle for the same
    /// property is already in flight.
    @discardableResult
    public func requestSetCSSProperty(
        _ id: CSS.Property.ID,
        enabled: Bool,
        isolation: isolated (any Actor) = #isolation
    ) -> Bool {
        requireOwner(isolation)
        guard let currentPage,
              styleToggleTasks[id] == nil,
              let styles = selectedNode?.elementStyles,
              let intent = styles.setStyleTextIntent(for: id, enabled: enabled) else {
            return false
        }

        styleToggleTasks[id] = Task { [weak self, currentPage, styles] in
            _ = isolation
            do {
                let result = try await currentPage.css.setStyleText(intent.styleID, text: intent.text)
                guard let self else {
                    return
                }
                self.styleToggleTasks[id] = nil
                guard Task.isCancelled == false else {
                    return
                }
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
        guard selectedNode?.id == nodeID else {
            return
        }
        markSelectedStylesNeedsRefresh(isolation: isolation)
    }

    private func markSelectedStylesNeedsRefresh(isolation: isolated (any Actor) = #isolation) {
        styleRefreshGeneration += 1
        guard let styles = selectedNode?.elementStyles else {
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
        let requestID = Network.Request.ID(rawRequestID)
        let resourceType = resourceTypeRawValue.map(Network.ResourceType.init(rawValue:))
        apply(
            .requestWillBeSent(
                id: requestID,
                request: Network.Request(
                    id: requestID,
                    url: url,
                    method: method,
                    headers: requestHeaders,
                    postData: postData
                ),
                resourceType: resourceType,
                redirectResponse: nil,
                timestamp: timestamp
            ),
            isolation: isolation
        )
        apply(
            .responseReceived(
                id: requestID,
                response: Network.Response(
                    url: url,
                    status: responseStatus,
                    statusText: responseStatusText,
                    mimeType: responseMIMEType,
                    headers: responseHeaders,
                    source: Network.Source(rawValue: "network"),
                    requestHeaders: requestHeaders
                ),
                resourceType: resourceType ?? .other,
                timestamp: timestamp + 0.1
            ),
            isolation: isolation
        )
        apply(
            .dataReceived(
                id: requestID,
                dataLength: encodedBodyLength,
                encodedDataLength: encodedBodyLength,
                timestamp: timestamp + 0.11
            ),
            isolation: isolation
        )
        apply(
            .loadingFinished(
                id: requestID,
                timestamp: timestamp + 0.2,
                sourceMapURL: nil,
                metrics: Network.Metrics(
                    encodedDataLength: encodedBodyLength,
                    decodedBodyLength: encodedBodyLength
                )
            ),
            isolation: isolation
        )
        guard let request = networkRequest(for: requestID, method: "seedNetworkRequest") else {
            preconditionFailure("Seeded NetworkRequest disappeared during preview seeding.")
        }
        if let responseBody {
            request.responseBody.load(Network.Body(data: responseBody, base64Encoded: false))
        }
        return request.id
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
        guard let request = requestsByID[requestID] else {
            preconditionFailure("Cannot seed a response body for an unregistered NetworkRequest.")
        }
        request.responseBody.load(NetworkBody.Payload(
            body: body,
            base64Encoded: base64Encoded,
            size: size,
            isTruncated: isTruncated
        ))
    }

    package func apply(_ event: Network.Event, isolation: isolated (any Actor) = #isolation) {
        requireOwner(isolation)
        switch event {
        case let .requestWillBeSent(id, request, resourceType, redirectResponse, timestamp):
            applyRequestWillBeSent(
                id: id,
                request: request,
                resourceType: resourceType,
                redirectResponse: redirectResponse,
                timestamp: timestamp
            )
        case let .responseReceived(id, response, resourceType, timestamp):
            applyResponseReceived(id: id, response: response, resourceType: resourceType, timestamp: timestamp)
        case let .dataReceived(id, dataLength, encodedDataLength, timestamp):
            guard let request = networkRequest(for: id, method: "dataReceived") else {
                return
            }
            request.applyDataReceived(
                dataLength: dataLength,
                encodedDataLength: encodedDataLength,
                timestamp: timestamp
            )
        case let .loadingFinished(id, timestamp, sourceMapURL, metrics):
            guard let request = networkRequest(for: id, method: "loadingFinished") else {
                return
            }
            request.finish(timestamp: timestamp, sourceMapURL: sourceMapURL, metrics: metrics)
        case let .loadingFailed(id, errorText, canceled, timestamp):
            guard let request = networkRequest(for: id, method: "loadingFailed") else {
                return
            }
            request.fail(errorText: errorText, canceled: canceled, timestamp: timestamp)
        case let .webSocket(event):
            apply(event)
        case let .requestServedFromMemoryCache(id, response, timestamp):
            applyRequestServedFromMemoryCache(id: id, response: response, timestamp: timestamp)
        case .unknown:
            break
        }
    }

    private func applyRequestWillBeSent(
        id proxyID: Network.Request.ID,
        request payload: Network.Request,
        resourceType: Network.ResourceType?,
        redirectResponse: Network.Response?,
        timestamp: Double
    ) {
        let id = NetworkRequest.ID(proxyID)
        clearedNetworkRequestIDs.remove(id)
        let request: NetworkRequest
        var inserted = false
        var topologyMayHaveChanged = false
        if let existing = requestsByID[id] {
            request = existing
            if let redirectResponse, existing.isActive {
                request.applyRedirect(
                    to: payload,
                    redirectResponse: redirectResponse,
                    timestamp: timestamp,
                    resourceType: resourceType
                )
                topologyMayHaveChanged = true
            } else if existing.isActive == false {
                request.applyRequestWillBeSent(request: payload, resourceType: resourceType, timestamp: timestamp)
                topologyMayHaveChanged = true
            }
        } else {
            request = NetworkRequest(request: payload, resourceType: resourceType, timestamp: timestamp, modelContext: self)
            requestsByID[id] = request
            orderedRequestIDs.append(id)
            inserted = true
        }
        if inserted {
            notifyNetworkRequestInserted(request)
        } else if topologyMayHaveChanged {
            notifyNetworkRequestTopologyMayHaveChanged(request)
        }
    }

    private func applyRequestServedFromMemoryCache(
        id proxyID: Network.Request.ID,
        response: Network.Response,
        timestamp: Double
    ) {
        let id = NetworkRequest.ID(proxyID)
        guard clearedNetworkRequestIDs.contains(id) == false else {
            return
        }
        let request: NetworkRequest
        if let existing = requestsByID[id] {
            request = existing
        } else {
            guard let url = response.url else {
                skipEvent("Network.requestServedFromMemoryCache omitted response URL for a new request")
                return
            }
            let payload = Network.Request(
                id: proxyID,
                url: url,
                method: "GET",
                headers: response.requestHeaders ?? [:]
            )
            request = NetworkRequest(request: payload, resourceType: nil, timestamp: timestamp, modelContext: self)
            requestsByID[id] = request
            orderedRequestIDs.append(id)
            request.applyMemoryCache(response: response, timestamp: timestamp)
            notifyNetworkRequestInserted(request)
            return
        }
        request.applyMemoryCache(response: response, timestamp: timestamp)
        notifyNetworkRequestTopologyMayHaveChanged(request)
    }

    private func applyResponseReceived(
        id proxyID: Network.Request.ID,
        response: Network.Response,
        resourceType: Network.ResourceType,
        timestamp: Double
    ) {
        let id = NetworkRequest.ID(proxyID)
        guard clearedNetworkRequestIDs.contains(id) == false else {
            return
        }
        let request: NetworkRequest
        var inserted = false
        if let existing = requestsByID[id] {
            request = existing
        } else {
            guard let url = response.url else {
                skipEvent("Network.responseReceived omitted response URL for an untracked request")
                return
            }
            // WebKit's frontend creates a resource here when inspection starts
            // after Network.requestWillBeSent. The response event has no method,
            // so keep the same GET default WebKit uses when serializing such a
            // resource later.
            let payload = Network.Request(
                id: proxyID,
                url: url,
                method: "GET",
                headers: response.requestHeaders ?? [:]
            )
            request = NetworkRequest(request: payload, resourceType: resourceType, timestamp: timestamp, modelContext: self)
            requestsByID[id] = request
            orderedRequestIDs.append(id)
            inserted = true
        }
        request.applyResponse(response, resourceType: resourceType, timestamp: timestamp)
        if inserted {
            notifyNetworkRequestInserted(request)
        } else {
            notifyNetworkRequestTopologyMayHaveChanged(request)
        }
    }

    private func apply(_ event: Network.WebSocketEvent) {
        switch event {
        case let .created(id, url):
            applyWebSocketCreated(id: id, url: url)
        case let .handshakeRequest(id, request, timestamp):
            guard let networkRequest = networkRequest(for: id, method: "webSocketWillSendHandshakeRequest") else {
                return
            }
            networkRequest.applyWebSocketHandshakeRequest(request, timestamp: timestamp)
        case let .handshakeResponse(id, response, timestamp):
            guard let networkRequest = networkRequest(for: id, method: "webSocketHandshakeResponseReceived") else {
                return
            }
            networkRequest.applyWebSocketHandshakeResponse(response, timestamp: timestamp)
        case let .frameSent(id, frame, timestamp):
            guard let networkRequest = networkRequest(for: id, method: "webSocketFrameSent") else {
                return
            }
            networkRequest.appendWebSocketFrame(frame, direction: .sent, timestamp: timestamp)
        case let .frameReceived(id, frame, timestamp):
            guard let networkRequest = networkRequest(for: id, method: "webSocketFrameReceived") else {
                return
            }
            networkRequest.appendWebSocketFrame(frame, direction: .received, timestamp: timestamp)
        case let .error(id, message, timestamp):
            guard let networkRequest = networkRequest(for: id, method: "webSocketFrameError") else {
                return
            }
            networkRequest.appendWebSocketError(message, timestamp: timestamp)
        case let .closed(id, timestamp):
            guard let networkRequest = networkRequest(for: id, method: "webSocketClosed") else {
                return
            }
            networkRequest.closeWebSocket(timestamp: timestamp)
        case .other:
            break
        }
    }

    private func applyWebSocketCreated(id proxyID: Network.Request.ID, url: String) {
        let id = NetworkRequest.ID(proxyID)
        clearedNetworkRequestIDs.remove(id)
        let request: NetworkRequest
        var inserted = false
        if let existing = requestsByID[id] {
            request = existing
        } else {
            let payload = Network.Request(id: proxyID, url: url, method: "GET")
            request = NetworkRequest(request: payload, resourceType: .webSocket, timestamp: nil, modelContext: self)
            requestsByID[id] = request
            orderedRequestIDs.append(id)
            inserted = true
        }
        request.applyWebSocketCreated(url: url)
        if inserted {
            notifyNetworkRequestInserted(request)
        } else {
            notifyNetworkRequestTopologyMayHaveChanged(request)
        }
    }

    private func networkRequest(
        for proxyID: Network.Request.ID,
        method: String
    ) -> NetworkRequest? {
        let id = NetworkRequest.ID(proxyID)
        guard let request = requestsByID[id] else {
            if clearedNetworkRequestIDs.contains(id) == false {
                skipEvent("Network.\(method) referenced an untracked request")
            }
            return nil
        }
        return request
    }

    private func clearNetworkRequests() {
        clearedNetworkRequestIDs.formUnion(requestsByID.keys)
        requestsByID = [:]
        orderedRequestIDs = []
        resetNetworkFetchedResults()
    }

    private func currentNetworkRequests() -> [NetworkRequest] {
        orderedRequestIDs.compactMap { requestsByID[$0] }
    }

    private func notifyNetworkRequestInserted(_ request: NetworkRequest) {
        networkFetchedResults.removeAll { $0.value == nil }
        for registration in networkFetchedResults {
            registration.value?.insertNetworkRequest(
                request,
                lookup: { id in self.requestsByID[id] }
            )
        }
    }

    private func notifyNetworkRequestTopologyMayHaveChanged(_ request: NetworkRequest) {
        networkFetchedResults.removeAll { $0.value == nil }
        for registration in networkFetchedResults {
            registration.value?.refreshNetworkRequestAfterMutation(
                request,
                lookup: { id in self.requestsByID[id] }
            )
        }
    }

    private func resetNetworkFetchedResults() {
        networkFetchedResults.removeAll { $0.value == nil }
        for registration in networkFetchedResults {
            registration.value?.resetItems([])
        }
    }
}

extension WebInspectorContext {
    func apply(_ event: Console.Event, isolation: isolated (any Actor) = #isolation) {
        requireOwner(isolation)
        switch event {
        case let .messageAdded(message):
            applyMessageAdded(message)
        case let .messageRepeatCountUpdated(count, timestamp):
            guard let lastConsoleMessageID,
                  let message = consoleMessagesByID[lastConsoleMessageID] else {
                skipEvent("Console.messageRepeatCountUpdated arrived before any tracked message")
                return
            }
            message.updateRepeatCount(count, timestamp: timestamp)
            refreshAllConsoleMessages(updatedItemIDs: [message.id])
        case .messagesCleared:
            clearConsoleMessages()
            releaseConsoleRuntimeObjectGroup(isolation: isolation)
        case .unknown:
            break
        }
    }

    private func clearConsoleMessages() {
        consoleMessagesByID = [:]
        orderedConsoleMessageIDs = []
        lastConsoleMessageID = nil
        unregisterRuntimeObjects(owner: .console)
        refreshAllConsoleMessages()
    }

    private func releaseConsoleRuntimeObjectGroup(isolation: isolated (any Actor) = #isolation) {
        consoleObjectGroupReleaseTask?.cancel()
        guard let currentPage else {
            skipEvent("Console.messagesCleared arrived without a current page target")
            return
        }
        consoleObjectGroupReleaseTask = Task { [weak self, currentPage] in
            _ = isolation
            do {
                try await currentPage.runtime.releaseObjectGroup(.console)
            } catch is CancellationError {
                return
            } catch {
                self?.failIfTerminal(error, operation: "Runtime.releaseObjectGroup")
            }
        }
    }

    private func applyMessageAdded(_ payload: Console.Message) {
        let id = ConsoleMessage.ID(nextConsoleMessageOrdinal)
        nextConsoleMessageOrdinal += 1
        let parameters = payload.parameters.map { registerRuntimeObject($0, owner: .console) }
        let message = ConsoleMessage(id: id, message: payload, parameters: parameters, modelContext: self)
        consoleMessagesByID[id] = message
        orderedConsoleMessageIDs.append(id)
        lastConsoleMessageID = id
        refreshAllConsoleMessages()
    }

    private func currentConsoleMessages() -> [ConsoleMessage] {
        orderedConsoleMessageIDs.compactMap { consoleMessagesByID[$0] }
    }

    private func consoleMessages(for descriptor: WebInspectorFetchDescriptor<ConsoleMessage>) -> [ConsoleMessage] {
        var items = currentConsoleMessages()
        if let predicate = descriptor.predicate {
            items = items.filter { message in
                do {
                    return try predicate.evaluate(message)
                } catch {
                    preconditionFailure("ConsoleMessage predicate evaluation failed: \(error)")
                }
            }
        }
        if descriptor.sortBy.isEmpty == false {
            items.sort { lhs, rhs in
                for sortDescriptor in descriptor.sortBy {
                    switch sortDescriptor.compare(lhs, rhs) {
                    case .orderedAscending:
                        return true
                    case .orderedDescending:
                        return false
                    case .orderedSame:
                        continue
                    }
                }
                return lhs.id < rhs.id
            }
        }
        let lowerBound = min(descriptor.fetchOffset, items.count)
        let upperBound: Int
        if let fetchLimit = descriptor.fetchLimit {
            upperBound = min(lowerBound + fetchLimit, items.count)
        } else {
            upperBound = items.count
        }
        return Array(items[lowerBound..<upperBound])
    }

    private func refreshAllConsoleMessages(updatedItemIDs: Set<ConsoleMessage.ID> = []) {
        consoleFetchedResults.removeAll { $0.value == nil }
        for registration in consoleFetchedResults {
            guard let results = registration.value else {
                continue
            }
            results.setItems(consoleMessages(for: results.fetchDescriptor), updatedItemIDs: updatedItemIDs)
        }
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
            if let targetID, eventTargetID != targetID {
                skipEvent("Runtime.executionContextsCleared referenced a mismatched target")
                return
            }
            clearExecutionContexts()
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

    private func refreshExecutionContexts() {
        executionContexts = orderedRuntimeContextIDs.compactMap { runtimeContextsByID[$0] }
    }

    private func firstRuntimeContext() -> RuntimeContext? {
        orderedRuntimeContextIDs.compactMap { runtimeContextsByID[$0] }.first
    }
}
