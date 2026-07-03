import Foundation
import WebInspectorProxyKit

public final class WebInspectorContext {
    private enum RuntimeObjectOwner: Hashable {
        case client
        case console
    }

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
    private var startupTask: Task<Void, Never>?
    private var documentReloadTask: Task<Void, Never>?
    private var inspectResolutionTask: Task<Void, Never>?
    private var styleRefreshTask: Task<Void, Never>?
    private var styleRefreshGeneration: Int
    private var isStyleHydrationActive: Bool
    private var styleToggleTasks: [CSS.Property.ID: Task<Void, Never>]
    private var eventPumps: [WebInspectorEventPump]
    private var networkTrackingTarget: WebInspectorTarget?
    private var runtimeTrackingTarget: WebInspectorTarget?
    private var consoleTrackingTarget: WebInspectorTarget?
    private var nodesByID: [DOMNode.ID: DOMNode]
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
        startupTask = nil
        documentReloadTask = nil
        inspectResolutionTask = nil
        styleRefreshTask = nil
        styleRefreshGeneration = 0
        isStyleHydrationActive = false
        styleToggleTasks = [:]
        eventPumps = []
        networkTrackingTarget = nil
        runtimeTrackingTarget = nil
        consoleTrackingTarget = nil
        nodesByID = [:]
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
        documentReloadTask?.cancel()
        inspectResolutionTask?.cancel()
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
        previousStartupTask?.cancel()
        state = .attaching
        notifyStatusChanged()
        teardownError = nil
        startupTask = Task { [weak self, previousStartupTask] in
            _ = isolation
            await previousStartupTask?.value
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
        requireOwner(isolation)
        if let node, nodesByID[node.id] !== node {
            preconditionFailure("DOMNode is not registered in this WebInspectorContext.")
        }
        pendingInspectedNodeID = nil
        inspectResolutionTask?.cancel()
        inspectResolutionTask = nil
        selectedNode = node
        notifyDOMTreeSelectionChanged(node, isolation: isolation)
        notifyStatusChanged()
        refreshSelectedStyles(isolation: isolation)
    }

    package func selectNode(_ id: DOMNode.ID, isolation: isolated (any Actor) = #isolation) throws {
        select(try requiredNode(for: id, isolation: isolation), isolation: isolation)
    }

    package func requestChildren(
        for id: DOMNode.ID,
        depth: Int = 1,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        try await requiredNode(for: id, isolation: isolation).requestChildren(depth: depth, isolation: isolation)
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
        for node in sortedNodes {
            try await page.dom.removeNode(node.id.proxyID)
        }
        clearSelectionIfDeleted(sortedNodes.map(\.id), snapshot: snapshot, isolation: isolation)
    }

    package func delete(nodeIDs: [DOMNode.ID], isolation: isolated (any Actor) = #isolation) async throws {
        var seenNodeIDs: Set<DOMNode.ID> = []
        let nodes = try nodeIDs
            .filter { seenNodeIDs.insert($0).inserted }
            .map { try requiredNode(for: $0, isolation: isolation) }
        try await delete(nodes, isolation: isolation)
    }

    public func highlight(_ node: DOMNode, isolation: isolated (any Actor) = #isolation) async throws {
        requireOwner(isolation)
        try registeredNode(node)
        let page = try currentPageOrThrow()
        try await page.dom.highlightNode(node.id.proxyID)
    }

    package func highlightNode(for id: DOMNode.ID, isolation: isolated (any Actor) = #isolation) async throws {
        try await highlight(try requiredNode(for: id, isolation: isolation), isolation: isolation)
    }

    public func hideHighlight(isolation: isolated (any Actor) = #isolation) async throws {
        requireOwner(isolation)
        let page = try currentPageOrThrow()
        try await page.dom.hideHighlight()
    }

    public func setElementPickerEnabled(
        _ isEnabled: Bool,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        requireOwner(isolation)
        let page = try currentPageOrThrow()
        try await page.dom.setInspectMode(enabled: isEnabled)
        isElementPickerEnabled = isEnabled
        notifyStatusChanged()
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
        let results = WebInspectorFetchedResults(fetchDescriptor: descriptor, sectionBy: sectionBy)
        switch descriptor.kind {
        case .networkRequests:
            guard let networkResults = results as? WebInspectorFetchedResults<NetworkRequest> else {
                preconditionFailure("NetworkRequest descriptors can only fetch NetworkRequest models.")
            }
            networkResults.setItems(currentNetworkRequests())
            networkFetchedResults.append(WeakWebInspectorFetchedResults(networkResults))
        case .consoleMessages:
            guard let consoleResults = results as? WebInspectorFetchedResults<ConsoleMessage> else {
                preconditionFailure("ConsoleMessage descriptors can only fetch ConsoleMessage models.")
            }
            consoleResults.setItems(currentConsoleMessages())
            consoleFetchedResults.append(WeakWebInspectorFetchedResults(consoleResults))
        }
        return results
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
        documentReloadTask?.cancel()
        documentReloadTask = nil
        inspectResolutionTask?.cancel()
        inspectResolutionTask = nil
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
        teardownError = nil
        teardownError = await disableEnabledDomains(isolation: isolation)
        transition(to: .detached)
    }

    private func startup(isolation: isolated (any Actor)) async {
        requireOwner(isolation)
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
            await target.waitForModelEventSubscriptions()
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation(isolation: isolation)
                return
            }
            resetReplayBackedModelsBeforeEnable()
            try await enableRuntimeTracking(on: target, isolation: isolation)
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation(isolation: isolation)
                return
            }
            try await enableNetworkTracking(on: target, isolation: isolation)
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation(isolation: isolation)
                return
            }
            let document = try await target.dom.getDocument()
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation(isolation: isolation)
                return
            }
            try await enableConsoleTracking(on: target, isolation: isolation)
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation(isolation: isolation)
                return
            }
            applyDocument(document, isolation: isolation)
            transition(to: .attached)
        } catch is CancellationError {
            await disableEnabledDomainsAfterCancellation(isolation: isolation)
            return
        } catch let error as WebInspectorProxyError {
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation(isolation: isolation)
                return
            }
            await logStartupTeardownFailure(isolation: isolation)
            fail(error)
        } catch {
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation(isolation: isolation)
                return
            }
            await logStartupTeardownFailure(isolation: isolation)
            fail(.attachFailed(String(describing: error)))
        }
    }

    private func disableEnabledDomainsBeforeRestart(
        isolation: isolated (any Actor)
    ) async -> WebInspectorProxyError? {
        await disableEnabledDomains(isolation: isolation)
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

    private func resetReplayBackedModelsBeforeEnable() {
        clearExecutionContexts()
        consoleMessagesByID = [:]
        orderedConsoleMessageIDs = []
        lastConsoleMessageID = nil
        refreshAllConsoleMessages()
    }

    private func disableEnabledDomains(
        isolation: isolated (any Actor)
    ) async -> WebInspectorProxyError? {
        let consoleError = await disableConsoleTracking(isolation: isolation)
        let runtimeError = await disableRuntimeTracking(isolation: isolation)
        let networkError = await disableNetworkTracking(isolation: isolation)
        return consoleError ?? runtimeError ?? networkError
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

        eventPumps = [domPump, networkPump, cssPump, consolePump, runtimePump]
    }

    private func stopEventPumps() {
        for pump in eventPumps {
            pump.stop()
        }
        eventPumps = []
    }

    private func notifyDOMTreeControllers(
        changes: [DOMTreeTransaction.Change],
        isolation: isolated (any Actor)
    ) {
        _ = isolation
        pruneReleasedTreeStates()
        for reference in treeStates {
            reference.tree?.apply(changes: changes, rootNode: rootNode, selectedNode: selectedNode)
        }
    }

    private func notifyDOMTreeSelectionChanged(
        _ node: DOMNode?,
        isolation: isolated (any Actor)
    ) {
        notifyDOMTreeControllers(changes: [.selectionChanged(nodeID: node?.id)], isolation: isolation)
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

        documentReloadTask?.cancel()
        documentReloadTask = Task { [weak self, currentPage] in
            _ = isolation
            do {
                let document = try await currentPage.dom.getDocument()
                guard Task.isCancelled == false else {
                    return
                }
                self?.applyDocument(document, isolation: isolation)
            } catch is CancellationError {
                return
            } catch {
                self?.failIfTerminal(error, operation: "DOM.getDocument")
            }
        }
    }

    private func requestInspectionSubtree(
        from rootNode: DOMNode,
        isolation: isolated (any Actor) = #isolation
    ) {
        guard let currentPage else {
            skipEvent("requestInspectionSubtree ignored: no current page target")
            return
        }

        inspectResolutionTask?.cancel()
        inspectResolutionTask = Task { [weak self, currentPage, rootID = rootNode.id.proxyID] in
            _ = isolation
            do {
                try await currentPage.dom.requestChildNodes(rootID, depth: -1)
            } catch is CancellationError {
                return
            } catch {
                self?.failIfTerminal(error, operation: "DOM.requestChildNodes")
            }
        }
    }
}

extension WebInspectorContext {
    func apply(_ event: DOM.Event, isolation: isolated (any Actor) = #isolation) {
        requireOwner(isolation)
        switch event {
        case .documentUpdated:
            resetDOM(isolation: isolation)
            reloadDocument(isolation: isolation)
        case let .setChildNodes(parent, nodes):
            applySetChildNodes(parent: parent, nodes: nodes, isolation: isolation)
        case let .childNodeInserted(parent, previous, node):
            applyChildNodeInserted(parent: parent, previous: previous, node: node, isolation: isolation)
        case let .childNodeRemoved(parent, node):
            applyChildNodeRemoved(parent: parent, node: node, isolation: isolation)
        case let .childNodeCountUpdated(id, count):
            guard let node = nodesByID[DOMNode.ID(id)] else {
                skipEvent("DOM.childNodeCountUpdated referenced an unmaterialized node")
                return
            }
            node.updateChildNodeCount(count)
            notifyDOMTreeControllers(changes: [.childCountChanged(nodeID: DOMNode.ID(id))], isolation: isolation)
        case let .attributeModified(id, name, value):
            guard let node = nodesByID[DOMNode.ID(id)] else {
                skipEvent("DOM.attributeModified referenced an unmaterialized node")
                return
            }
            node.setAttribute(name: name, value: value)
            markSelectedStylesNeedsRefresh(for: DOMNode.ID(id))
            notifyDOMTreeControllers(changes: [.nodeChanged(nodeID: DOMNode.ID(id))], isolation: isolation)
        case let .attributeRemoved(id, name):
            guard let node = nodesByID[DOMNode.ID(id)] else {
                skipEvent("DOM.attributeRemoved referenced an unmaterialized node")
                return
            }
            node.removeAttribute(name: name)
            markSelectedStylesNeedsRefresh(for: DOMNode.ID(id))
            notifyDOMTreeControllers(changes: [.nodeChanged(nodeID: DOMNode.ID(id))], isolation: isolation)
        case let .characterDataModified(id, value):
            guard let node = nodesByID[DOMNode.ID(id)] else {
                skipEvent("DOM.characterDataModified referenced an unmaterialized node")
                return
            }
            node.setNodeValue(value)
            markSelectedStylesNeedsRefresh(for: DOMNode.ID(id))
            notifyDOMTreeControllers(changes: [.nodeChanged(nodeID: DOMNode.ID(id))], isolation: isolation)
        case let .inspect(id):
            isElementPickerEnabled = false
            notifyStatusChanged()
            let inspectedNodeID = DOMNode.ID(id)
            guard let node = nodesByID[inspectedNodeID] else {
                pendingInspectedNodeID = inspectedNodeID
                resolvePendingInspectedNode(requestSubtreeIfNeeded: true, isolation: isolation)
                return
            }
            pendingInspectedNodeID = nil
            inspectResolutionTask?.cancel()
            inspectResolutionTask = nil
            select(node, isolation: isolation)
        case .detachedRoot,
             .shadowRootPushed,
             .shadowRootPopped,
             .pseudoElementAdded,
             .pseudoElementRemoved,
             .unknown:
            break
        }
    }

    func applyDocument(_ node: DOM.Node, isolation: isolated (any Actor) = #isolation) {
        requireOwner(isolation)
        var materializedPayloadIDs = Set<DOMNode.ID>()
        collectMaterializedPayloadIDs(node, into: &materializedPayloadIDs)
        rootNode = model(for: node, preserving: materializedPayloadIDs)
        notifyDOMTreeControllers(changes: [.rootChanged(rootNodeID: rootNode?.id)], isolation: isolation)
        resolvePendingInspectedNode(requestSubtreeIfNeeded: true, isolation: isolation)
    }

    package func seedDOMDocument(_ node: DOM.Node, isolation: isolated (any Actor) = #isolation) {
        applyDocument(node, isolation: isolation)
    }

    package func seedElementPickerEnabled(_ isEnabled: Bool, isolation: isolated (any Actor) = #isolation) {
        requireOwner(isolation)
        isElementPickerEnabled = isEnabled
        notifyStatusChanged()
    }

    private func resetDOM(isolation: isolated (any Actor)) {
        inspectResolutionTask?.cancel()
        inspectResolutionTask = nil
        styleRefreshTask?.cancel()
        styleRefreshTask = nil
        styleRefreshGeneration += 1
        rootNode = nil
        selectedNode = nil
        isElementPickerEnabled = false
        pendingInspectedNodeID = nil
        nodesByID = [:]
        notifyDOMTreeControllers(changes: [.rootChanged(rootNodeID: nil)], isolation: isolation)
        notifyStatusChanged()
    }

    private func applySetChildNodes(
        parent: DOM.Node.ID,
        nodes: [DOM.Node],
        isolation: isolated (any Actor) = #isolation
    ) {
        guard let parentNode = nodesByID[DOMNode.ID(parent)] else {
            skipEvent("DOM.setChildNodes referenced an unmaterialized parent node")
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
        notifyDOMTreeControllers(changes: [.childrenReplaced(parentID: parentNode.id)], isolation: isolation)
        resolvePendingInspectedNode(requestSubtreeIfNeeded: false, isolation: isolation)
    }

    private func applyChildNodeInserted(
        parent: DOM.Node.ID,
        previous: DOM.Node.ID?,
        node: DOM.Node,
        isolation: isolated (any Actor) = #isolation
    ) {
        guard let parentNode = nodesByID[DOMNode.ID(parent)] else {
            skipEvent("DOM.childNodeInserted referenced an unmaterialized parent node")
            return
        }

        guard case var .loaded(children) = parentNode.children else {
            parentNode.updateChildNodeCount(parentNode.childNodeCount + 1)
            notifyDOMTreeControllers(changes: [.childCountChanged(nodeID: parentNode.id)], isolation: isolation)
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
        notifyDOMTreeControllers(changes: [.childInserted(parentID: parentNode.id)], isolation: isolation)
        resolvePendingInspectedNode(requestSubtreeIfNeeded: false, isolation: isolation)
    }

    private func applyChildNodeRemoved(
        parent: DOM.Node.ID,
        node: DOM.Node.ID,
        isolation: isolated (any Actor)
    ) {
        guard let parentNode = nodesByID[DOMNode.ID(parent)] else {
            skipEvent("DOM.childNodeRemoved referenced an unmaterialized parent node")
            return
        }

        let removedID = DOMNode.ID(node)
        guard let removedNode = nodesByID[removedID] else {
            skipEvent("DOM.childNodeRemoved referenced an unmaterialized child node")
            return
        }
        let selectedNodeWasRemoved = removeSubtreeFromIndex(removedNode)

        guard case let .loaded(children) = parentNode.children else {
            parentNode.updateChildNodeCount(max(0, parentNode.childNodeCount - 1))
            notifyDOMTreeControllers(changes: [.childCountChanged(nodeID: parentNode.id)], isolation: isolation)
            if selectedNodeWasRemoved {
                notifyStatusChanged()
            }
            return
        }
        parentNode.setChildren(children.filter { $0.id != removedID })
        notifyDOMTreeControllers(changes: [.childRemoved(parentID: parentNode.id)], isolation: isolation)
        if selectedNodeWasRemoved {
            notifyStatusChanged()
        }
    }

    @discardableResult
    private func removeSubtreeFromIndex(_ root: DOMNode, preserving preservedIDs: Set<DOMNode.ID> = []) -> Bool {
        var removedIDs = Set<DOMNode.ID>()
        collectSubtreeIDs(root, into: &removedIDs)
        removedIDs.subtract(preservedIDs)
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

        let contentDocument = payload.contentDocument.map { model(for: $0, preserving: materializedPayloadIDs) }
        let shadowRoots = payload.shadowRoots.map { model(for: $0, preserving: materializedPayloadIDs) }
        let templateContent = payload.templateContent.map { model(for: $0, preserving: materializedPayloadIDs) }
        let beforePseudoElement = payload.beforePseudoElement.map { model(for: $0, preserving: materializedPayloadIDs) }
        let otherPseudoElements = payload.otherPseudoElements.map { model(for: $0, preserving: materializedPayloadIDs) }
        let afterPseudoElement = payload.afterPseudoElement.map { model(for: $0, preserving: materializedPayloadIDs) }
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

    private func resolvePendingInspectedNode(
        requestSubtreeIfNeeded: Bool,
        isolation: isolated (any Actor) = #isolation
    ) {
        guard let pendingInspectedNodeID else {
            return
        }
        guard let inspectedNode = nodesByID[pendingInspectedNodeID] else {
            if requestSubtreeIfNeeded, let rootNode {
                requestInspectionSubtree(from: rootNode, isolation: isolation)
            }
            return
        }
        self.pendingInspectedNodeID = nil
        inspectResolutionTask?.cancel()
        inspectResolutionTask = nil
        select(inspectedNode, isolation: isolation)
    }
}

extension WebInspectorContext {
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
            let matchedStyles = try await currentPage.css.matchedStyles(for: node.id.proxyID)
            guard isCurrentStyleRefresh(node: node, generation: generation) else {
                return
            }
            let inlineStyles = try await currentPage.css.inlineStyles(for: node.id.proxyID)
            guard isCurrentStyleRefresh(node: node, generation: generation) else {
                return
            }
            let computedProperties = try await currentPage.css.computedStyle(for: node.id.proxyID)
            guard isCurrentStyleRefresh(node: node, generation: generation) else {
                return
            }
            styles.load(
                matchedStyles: matchedStyles,
                inlineStyles: inlineStyles,
                computedProperties: computedProperties
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
            refreshAllRequests(updatedItemIDs: [request.id])
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
        refreshAllRequests(updatedItemIDs: [requestID])
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
            guard let request = networkRequest(for: id, method: "responseReceived") else {
                return
            }
            request.applyResponse(response, resourceType: resourceType, timestamp: timestamp)
            refreshAllRequests(updatedItemIDs: [request.id])
        case let .dataReceived(id, dataLength, encodedDataLength, timestamp):
            guard let request = networkRequest(for: id, method: "dataReceived") else {
                return
            }
            request.applyDataReceived(
                dataLength: dataLength,
                encodedDataLength: encodedDataLength,
                timestamp: timestamp
            )
            refreshAllRequests(updatedItemIDs: [request.id])
        case let .loadingFinished(id, timestamp, sourceMapURL, metrics):
            guard let request = networkRequest(for: id, method: "loadingFinished") else {
                return
            }
            request.finish(timestamp: timestamp, sourceMapURL: sourceMapURL, metrics: metrics)
            refreshAllRequests(updatedItemIDs: [request.id])
        case let .loadingFailed(id, errorText, canceled, timestamp):
            guard let request = networkRequest(for: id, method: "loadingFailed") else {
                return
            }
            request.fail(errorText: errorText, canceled: canceled, timestamp: timestamp)
            refreshAllRequests(updatedItemIDs: [request.id])
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
        var updatedItemIDs = Set<NetworkRequest.ID>()
        if let existing = requestsByID[id] {
            request = existing
            if let redirectResponse, existing.isActive {
                request.applyRedirect(
                    to: payload,
                    redirectResponse: redirectResponse,
                    timestamp: timestamp,
                    resourceType: resourceType
                )
                updatedItemIDs.insert(id)
            } else if existing.isActive == false {
                request.applyRequestWillBeSent(request: payload, resourceType: resourceType, timestamp: timestamp)
                updatedItemIDs.insert(id)
            }
        } else {
            request = NetworkRequest(request: payload, resourceType: resourceType, timestamp: timestamp, modelContext: self)
            requestsByID[id] = request
            orderedRequestIDs.append(id)
        }
        refreshAllRequests(updatedItemIDs: updatedItemIDs)
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
        }
        request.applyMemoryCache(response: response, timestamp: timestamp)
        refreshAllRequests(updatedItemIDs: [id])
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
            refreshAllRequests(updatedItemIDs: [networkRequest.id])
        case let .handshakeResponse(id, response, timestamp):
            guard let networkRequest = networkRequest(for: id, method: "webSocketHandshakeResponseReceived") else {
                return
            }
            networkRequest.applyWebSocketHandshakeResponse(response, timestamp: timestamp)
            refreshAllRequests(updatedItemIDs: [networkRequest.id])
        case let .frameSent(id, frame, timestamp):
            guard let networkRequest = networkRequest(for: id, method: "webSocketFrameSent") else {
                return
            }
            networkRequest.appendWebSocketFrame(frame, direction: .sent, timestamp: timestamp)
            refreshAllRequests(updatedItemIDs: [networkRequest.id])
        case let .frameReceived(id, frame, timestamp):
            guard let networkRequest = networkRequest(for: id, method: "webSocketFrameReceived") else {
                return
            }
            networkRequest.appendWebSocketFrame(frame, direction: .received, timestamp: timestamp)
            refreshAllRequests(updatedItemIDs: [networkRequest.id])
        case let .error(id, message, timestamp):
            guard let networkRequest = networkRequest(for: id, method: "webSocketFrameError") else {
                return
            }
            networkRequest.appendWebSocketError(message, timestamp: timestamp)
            refreshAllRequests(updatedItemIDs: [networkRequest.id])
        case let .closed(id, timestamp):
            guard let networkRequest = networkRequest(for: id, method: "webSocketClosed") else {
                return
            }
            networkRequest.closeWebSocket(timestamp: timestamp)
            refreshAllRequests(updatedItemIDs: [networkRequest.id])
        case .other:
            break
        }
    }

    private func applyWebSocketCreated(id proxyID: Network.Request.ID, url: String) {
        let id = NetworkRequest.ID(proxyID)
        clearedNetworkRequestIDs.remove(id)
        let request: NetworkRequest
        if let existing = requestsByID[id] {
            request = existing
        } else {
            let payload = Network.Request(id: proxyID, url: url, method: "GET")
            request = NetworkRequest(request: payload, resourceType: .webSocket, timestamp: nil, modelContext: self)
            requestsByID[id] = request
            orderedRequestIDs.append(id)
        }
        request.applyWebSocketCreated(url: url)
        refreshAllRequests(updatedItemIDs: [id])
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
        refreshAllRequests()
    }

    private func currentNetworkRequests() -> [NetworkRequest] {
        orderedRequestIDs.compactMap { requestsByID[$0] }
    }

    private func refreshAllRequests(updatedItemIDs: Set<NetworkRequest.ID> = []) {
        networkFetchedResults.removeAll { $0.value == nil }
        let items = currentNetworkRequests()
        for registration in networkFetchedResults {
            registration.value?.setItems(items, updatedItemIDs: updatedItemIDs)
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

    private func refreshAllConsoleMessages(updatedItemIDs: Set<ConsoleMessage.ID> = []) {
        consoleFetchedResults.removeAll { $0.value == nil }
        let items = currentConsoleMessages()
        for registration in consoleFetchedResults {
            registration.value?.setItems(items, updatedItemIDs: updatedItemIDs)
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
