import Foundation
import Observation
import WebViewProxyKit

@MainActor
@Observable
public final class WebViewModelContext {
    public enum State: Equatable, Sendable {
        case attaching
        case attached
        case detached
        case failed(WebViewProxyError)
    }

    public let proxy: WebViewProxy
    public private(set) var state: State
    public private(set) var teardownError: WebViewProxyError?
    public private(set) var rootNode: DOMNode?
    public private(set) var selectedNode: DOMNode?
    public private(set) var executionContexts: [RuntimeContext]
    public private(set) var selectedContext: RuntimeContext?

    @ObservationIgnored private var currentPage: WebViewTarget?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var documentReloadTask: Task<Void, Never>?
    @ObservationIgnored private var styleRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var styleRefreshGeneration: Int
    @ObservationIgnored private var eventTasks: [Task<Void, Never>]
    @ObservationIgnored private var networkTrackingTarget: WebViewTarget?
    @ObservationIgnored private var runtimeTrackingTarget: WebViewTarget?
    @ObservationIgnored private var consoleTrackingTarget: WebViewTarget?
    @ObservationIgnored private var nodesByID: [DOMNode.ID: DOMNode]
    @ObservationIgnored private var requestsByID: [NetworkRequest.ID: NetworkRequest]
    @ObservationIgnored private var orderedRequestIDs: [NetworkRequest.ID]
    @ObservationIgnored private let allNetworkRequests: WebViewFetchedResults<NetworkRequest>
    @ObservationIgnored private var consoleMessagesByID: [ConsoleMessage.ID: ConsoleMessage]
    @ObservationIgnored private var orderedConsoleMessageIDs: [ConsoleMessage.ID]
    @ObservationIgnored private var lastConsoleMessageID: ConsoleMessage.ID?
    @ObservationIgnored private var nextConsoleMessageOrdinal: Int
    @ObservationIgnored private let allConsoleMessages: WebViewFetchedResults<ConsoleMessage>
    @ObservationIgnored private var runtimeContextsByID: [RuntimeContext.ID: RuntimeContext]
    @ObservationIgnored private var orderedRuntimeContextIDs: [RuntimeContext.ID]
    @ObservationIgnored private var runtimeObjectsByID: [RuntimeObject.ID: RuntimeObject]
    @ObservationIgnored private var runtimeObjectIDsByProxyID: [Runtime.RemoteObject.ID: RuntimeObject.ID]
    @ObservationIgnored private var nextRuntimeObjectOrdinal: Int

    public init(proxy: WebViewProxy) {
        self.proxy = proxy
        state = .attaching
        teardownError = nil
        rootNode = nil
        selectedNode = nil
        executionContexts = []
        selectedContext = nil
        currentPage = nil
        startupTask = nil
        documentReloadTask = nil
        styleRefreshTask = nil
        styleRefreshGeneration = 0
        eventTasks = []
        networkTrackingTarget = nil
        runtimeTrackingTarget = nil
        consoleTrackingTarget = nil
        nodesByID = [:]
        requestsByID = [:]
        orderedRequestIDs = []
        allNetworkRequests = WebViewFetchedResults()
        consoleMessagesByID = [:]
        orderedConsoleMessageIDs = []
        lastConsoleMessageID = nil
        nextConsoleMessageOrdinal = 0
        allConsoleMessages = WebViewFetchedResults()
        runtimeContextsByID = [:]
        orderedRuntimeContextIDs = []
        runtimeObjectsByID = [:]
        runtimeObjectIDsByProxyID = [:]
        nextRuntimeObjectOrdinal = 0
    }

    deinit {
        startupTask?.cancel()
        documentReloadTask?.cancel()
        styleRefreshTask?.cancel()
        for task in eventTasks {
            task.cancel()
        }
    }

    public func start() {
        let previousStartupTask = startupTask
        previousStartupTask?.cancel()
        state = .attaching
        teardownError = nil
        startupTask = Task { [weak self, previousStartupTask] in
            await previousStartupTask?.value
            guard Task.isCancelled == false else {
                return
            }
            guard let self else {
                return
            }
            await self.startup()
        }
    }

    public func node(for id: DOMNode.ID) -> DOMNode? {
        nodesByID[id]
    }

    public func registeredRequest(for id: NetworkRequest.ID) -> NetworkRequest? {
        requestsByID[id]
    }

    public func registeredMessage(for id: ConsoleMessage.ID) -> ConsoleMessage? {
        consoleMessagesByID[id]
    }

    public func select(_ node: DOMNode?) {
        selectedNode = node
        refreshSelectedStyles()
    }

    public func selectContext(_ context: RuntimeContext?) {
        guard let context else {
            selectedContext = nil
            return
        }
        guard runtimeContextsByID[context.id] === context else {
            preconditionFailure("RuntimeContext is not registered in this WebViewModelContext.")
        }
        selectedContext = context
    }

    public func evaluate(
        _ expression: String,
        in context: RuntimeContext? = nil
    ) async throws -> RuntimeEvaluation {
        if let context, runtimeContextsByID[context.id] !== context {
            let error = WebViewProxyError.disconnected("RuntimeContext is not registered in this WebViewModelContext.")
            throw error
        }
        guard let currentPage else {
            throw WebViewProxyError.disconnected("WebViewDataKit has no current page target.")
        }

        let executionContext = context ?? selectedContext
        let result = try await currentPage.runtime.evaluate(expression, in: executionContext?.id.proxyID)
        return RuntimeEvaluation(
            object: registerRuntimeObject(result.object),
            isException: result.wasThrown
        )
    }

    public func fetchedResults<Model: WebViewFetchableModel>(
        for descriptor: WebViewFetchDescriptor<Model>
    ) -> WebViewFetchedResults<Model> {
        switch descriptor.kind {
        case .allRequests:
            guard let results = allNetworkRequests as? WebViewFetchedResults<Model> else {
                preconditionFailure("The .allRequests descriptor can only fetch NetworkRequest models.")
            }
            return results
        case .allConsoleMessages:
            guard let results = allConsoleMessages as? WebViewFetchedResults<Model> else {
                preconditionFailure("The .allConsoleMessages descriptor can only fetch ConsoleMessage models.")
            }
            return results
        }
    }

    public func fetchedResultsController<Model: WebViewFetchableModel>(
        for descriptor: WebViewFetchDescriptor<Model>
    ) -> WebViewFetchedResultsController<Model> {
        WebViewFetchedResultsController(fetchedResults: fetchedResults(for: descriptor))
    }

    package func fetchResponseBody(for request: NetworkRequest) async {
        guard let currentPage else {
            request.finishResponseBodyFetch(
                result: .failure(.disconnected("WebViewDataKit has no current page target."))
            )
            return
        }

        do {
            let body = try await currentPage.network.responseBody(for: request.proxyID)
            request.finishResponseBodyFetch(result: .success(body))
        } catch let error as WebViewProxyError {
            request.finishResponseBodyFetch(result: .failure(error))
        } catch {
            request.finishResponseBodyFetch(result: .failure(.commandFailed(
                domain: "Network",
                method: "getResponseBody",
                message: String(describing: error)
            )))
        }
    }

    package func requestChildren(for node: DOMNode, depth: Int) async {
        guard nodesByID[node.id] === node else {
            fail(.disconnected("DOMNode is not registered in this WebViewModelContext."))
            return
        }
        guard let currentPage else {
            fail(.disconnected("WebViewDataKit has no current page target."))
            return
        }

        do {
            try await currentPage.dom.requestChildNodes(node.id.proxyID, depth: depth)
        } catch let error as WebViewProxyError {
            fail(error)
        } catch {
            fail(.commandFailed(
                domain: "DOM",
                method: "requestChildNodes",
                message: String(describing: error)
            ))
        }
    }

    package func properties(for object: RuntimeObject) async throws -> [RuntimeObject.Property] {
        try registeredRuntimeObject(object)
        guard let proxyID = object.proxyID else {
            return []
        }
        guard let currentPage else {
            throw WebViewProxyError.disconnected("WebViewDataKit has no current page target.")
        }

        let descriptors = try await currentPage.runtime.properties(of: proxyID)
        return descriptors.map { descriptor in
            let remoteValue = descriptor.value
            let childObject = remoteValue.flatMap { value in
                value.id == nil ? nil : registerRuntimeObject(value)
            }
            return RuntimeObject.Property(
                name: descriptor.name,
                value: remoteValue.flatMap { runtimeValueText(for: $0) },
                object: childObject
            )
        }
    }

    package func collectionEntries(for object: RuntimeObject) async throws -> [RuntimeObject.Entry] {
        try registeredRuntimeObject(object)
        guard let proxyID = object.proxyID else {
            return []
        }
        guard let currentPage else {
            throw WebViewProxyError.disconnected("WebViewDataKit has no current page target.")
        }

        let entries = try await currentPage.runtime.collectionEntries(of: proxyID)
        return entries.map { entry in
            RuntimeObject.Entry(
                key: entry.key.map(registerRuntimeObject),
                value: registerRuntimeObject(entry.value)
            )
        }
    }

    @discardableResult
    private func registeredRuntimeObject(_ object: RuntimeObject) throws -> RuntimeObject {
        guard runtimeObjectsByID[object.id] === object else {
            let error = WebViewProxyError.disconnected("RuntimeObject is not registered in this WebViewModelContext.")
            throw error
        }
        return object
    }

    private func registerRuntimeObject(_ payload: Runtime.RemoteObject) -> RuntimeObject {
        if let proxyID = payload.id,
           let id = runtimeObjectIDsByProxyID[proxyID],
           let object = runtimeObjectsByID[id] {
            object.update(from: payload)
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
        return object
    }

    private func clearRuntimeObjects() {
        runtimeObjectsByID = [:]
        runtimeObjectIDsByProxyID = [:]
        nextRuntimeObjectOrdinal = 0
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

    package func detach() async {
        startupTask?.cancel()
        startupTask = nil
        documentReloadTask?.cancel()
        documentReloadTask = nil
        styleRefreshTask?.cancel()
        styleRefreshTask = nil
        styleRefreshGeneration += 1
        for task in eventTasks {
            task.cancel()
        }
        eventTasks = []
        currentPage = nil
        teardownError = nil
        teardownError = await disableEnabledDomains()
        state = .detached
    }

    private func startup() async {
        if let teardownError = await disableEnabledDomainsBeforeRestart() {
            fail(teardownError)
            return
        }

        do {
            let target = try await proxy.waitForCurrentPage()
            currentPage = target
            subscribe(to: target)
            await target.waitForModelEventSubscriptions()
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation()
                return
            }
            resetReplayBackedModelsBeforeEnable()
            try await enableRuntimeTracking(on: target)
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation()
                return
            }
            try await enableNetworkTracking(on: target)
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation()
                return
            }
            let document = try await target.dom.getDocument()
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation()
                return
            }
            try await enableConsoleTracking(on: target)
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation()
                return
            }
            applyDocument(document)
            state = .attached
        } catch is CancellationError {
            await disableEnabledDomainsAfterCancellation()
            return
        } catch let error as WebViewProxyError {
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation()
                return
            }
            fail(await disableEnabledDomainsAfterStartupFailure() ?? error)
        } catch {
            guard Task.isCancelled == false else {
                await disableEnabledDomainsAfterCancellation()
                return
            }
            fail(await disableEnabledDomainsAfterStartupFailure() ?? .attachFailed(String(describing: error)))
        }
    }

    private func disableEnabledDomainsBeforeRestart() async -> WebViewProxyError? {
        await disableEnabledDomains()
    }

    private func enableRuntimeTracking(on target: WebViewTarget) async throws {
        try await target.runtime.enable()
        runtimeTrackingTarget = target
    }

    private func enableConsoleTracking(on target: WebViewTarget) async throws {
        try await target.console.enable()
        consoleTrackingTarget = target
    }

    private func enableNetworkTracking(on target: WebViewTarget) async throws {
        try await target.network.enable()
        networkTrackingTarget = target
    }

    private func resetReplayBackedModelsBeforeEnable() {
        clearExecutionContexts()
        consoleMessagesByID = [:]
        orderedConsoleMessageIDs = []
        lastConsoleMessageID = nil
        refreshAllConsoleMessages()
    }

    private func disableEnabledDomains() async -> WebViewProxyError? {
        let consoleError = await disableConsoleTracking()
        let runtimeError = await disableRuntimeTracking()
        let networkError = await disableNetworkTracking()
        return consoleError ?? runtimeError ?? networkError
    }

    private func disableConsoleTracking() async -> WebViewProxyError? {
        guard let target = consoleTrackingTarget else {
            return nil
        }
        consoleTrackingTarget = nil
        do {
            try await target.console.disable()
            return nil
        } catch WebViewProxyError.closed {
            return nil
        } catch WebViewProxyError.disconnected(_) {
            return nil
        } catch let error as WebViewProxyError {
            return error
        } catch {
            return .commandFailed(
                domain: "Console",
                method: "disable",
                message: String(describing: error)
            )
        }
    }

    private func disableRuntimeTracking() async -> WebViewProxyError? {
        guard let target = runtimeTrackingTarget else {
            return nil
        }
        runtimeTrackingTarget = nil
        do {
            try await target.runtime.disable()
            return nil
        } catch WebViewProxyError.closed {
            return nil
        } catch WebViewProxyError.disconnected(_) {
            return nil
        } catch let error as WebViewProxyError {
            return error
        } catch {
            return .commandFailed(
                domain: "Runtime",
                method: "disable",
                message: String(describing: error)
            )
        }
    }

    private func disableNetworkTracking() async -> WebViewProxyError? {
        guard let target = networkTrackingTarget else {
            return nil
        }
        networkTrackingTarget = nil
        do {
            try await target.network.disable()
            return nil
        } catch WebViewProxyError.closed {
            return nil
        } catch WebViewProxyError.disconnected(_) {
            return nil
        } catch let error as WebViewProxyError {
            return error
        } catch {
            return .commandFailed(
                domain: "Network",
                method: "disable",
                message: String(describing: error)
            )
        }
    }

    private func disableEnabledDomainsAfterCancellation() async {
        if let error = await disableEnabledDomains() {
            fail(error)
        }
    }

    private func disableEnabledDomainsAfterStartupFailure() async -> WebViewProxyError? {
        await disableEnabledDomains()
    }

    private func subscribe(to target: WebViewTarget) {
        for task in eventTasks {
            task.cancel()
        }
        eventTasks = [
            Task { [weak self] in
                for await event in target.dom.events {
                    self?.apply(event)
                }
            },
            Task { [weak self] in
                for await event in target.network.events {
                    self?.apply(event)
                }
            },
            Task { [weak self] in
                for await event in target.css.events {
                    self?.apply(event)
                }
            },
            Task { [weak self] in
                for await event in target.console.events {
                    self?.apply(event)
                }
            },
            Task { [weak self, targetID = target.id] in
                for await event in target.runtime.events {
                    self?.apply(event, targetID: targetID)
                }
            }
        ]
    }

    private func fail(_ error: WebViewProxyError) {
        state = .failed(error)
    }

    package func reloadDocument() {
        guard let currentPage else {
            fail(.disconnected("WebViewDataKit has no current page target."))
            return
        }

        documentReloadTask?.cancel()
        documentReloadTask = Task { [weak self, currentPage] in
            do {
                let document = try await currentPage.dom.getDocument()
                guard Task.isCancelled == false else {
                    return
                }
                self?.applyDocument(document)
            } catch is CancellationError {
                return
            } catch let error as WebViewProxyError {
                self?.fail(error)
            } catch {
                self?.fail(.commandFailed(
                    domain: "DOM",
                    method: "getDocument",
                    message: String(describing: error)
                ))
            }
        }
    }
}

extension WebViewModelContext {
    package func apply(_ event: DOM.Event) {
        switch event {
        case .documentUpdated:
            resetDOM()
            reloadDocument()
        case let .setChildNodes(parent, nodes):
            applySetChildNodes(parent: parent, nodes: nodes)
        case let .childNodeInserted(parent, previous, node):
            applyChildNodeInserted(parent: parent, previous: previous, node: node)
        case let .childNodeRemoved(parent, node):
            applyChildNodeRemoved(parent: parent, node: node)
        case let .childNodeCountUpdated(id, count):
            guard let node = nodesByID[DOMNode.ID(id)] else {
                fail(.disconnected("DOM.childNodeCountUpdated referenced an unknown node."))
                return
            }
            node.updateChildNodeCount(count)
        case let .attributeModified(id, name, value):
            guard let node = nodesByID[DOMNode.ID(id)] else {
                fail(.disconnected("DOM.attributeModified referenced an unknown node."))
                return
            }
            node.setAttribute(name: name, value: value)
            markSelectedStylesNeedsRefresh(for: DOMNode.ID(id))
        case let .attributeRemoved(id, name):
            guard let node = nodesByID[DOMNode.ID(id)] else {
                fail(.disconnected("DOM.attributeRemoved referenced an unknown node."))
                return
            }
            node.removeAttribute(name: name)
            markSelectedStylesNeedsRefresh(for: DOMNode.ID(id))
        case let .characterDataModified(id, value):
            guard let node = nodesByID[DOMNode.ID(id)] else {
                fail(.disconnected("DOM.characterDataModified referenced an unknown node."))
                return
            }
            node.setNodeValue(value)
            markSelectedStylesNeedsRefresh(for: DOMNode.ID(id))
        case .detachedRoot,
             .shadowRootPushed,
             .shadowRootPopped,
             .pseudoElementAdded,
             .pseudoElementRemoved,
             .inspect,
             .unknown:
            break
        }
    }

    package func applyDocument(_ node: DOM.Node) {
        rootNode = model(for: node)
    }

    private func resetDOM() {
        styleRefreshTask?.cancel()
        styleRefreshTask = nil
        styleRefreshGeneration += 1
        rootNode = nil
        selectedNode = nil
        nodesByID = [:]
    }

    private func applySetChildNodes(parent: DOM.Node.ID, nodes: [DOM.Node]) {
        guard let parentNode = nodesByID[DOMNode.ID(parent)] else {
            fail(.disconnected("DOM.setChildNodes referenced an unknown parent node."))
            return
        }
        parentNode.setChildren(nodes.map { model(for: $0) })
    }

    private func applyChildNodeInserted(parent: DOM.Node.ID, previous: DOM.Node.ID?, node: DOM.Node) {
        guard let parentNode = nodesByID[DOMNode.ID(parent)] else {
            fail(.disconnected("DOM.childNodeInserted referenced an unknown parent node."))
            return
        }

        guard case var .loaded(children) = parentNode.children else {
            parentNode.updateChildNodeCount(parentNode.childNodeCount + 1)
            return
        }
        let inserted = model(for: node)
        if let previous, let index = children.firstIndex(where: { $0.id == DOMNode.ID(previous) }) {
            children.insert(inserted, at: children.index(after: index))
        } else {
            children.insert(inserted, at: 0)
        }
        parentNode.setChildren(children)
    }

    private func applyChildNodeRemoved(parent: DOM.Node.ID, node: DOM.Node.ID) {
        guard let parentNode = nodesByID[DOMNode.ID(parent)] else {
            fail(.disconnected("DOM.childNodeRemoved referenced an unknown parent node."))
            return
        }

        let removedID = DOMNode.ID(node)
        guard let removedNode = nodesByID[removedID] else {
            fail(.disconnected("DOM.childNodeRemoved referenced an unknown child node."))
            return
        }
        removeSubtreeFromIndex(removedNode)

        guard case let .loaded(children) = parentNode.children else {
            parentNode.updateChildNodeCount(max(0, parentNode.childNodeCount - 1))
            return
        }
        parentNode.setChildren(children.filter { $0.id != removedID })
    }

    private func removeSubtreeFromIndex(_ root: DOMNode) {
        var removedIDs = Set<DOMNode.ID>()
        collectSubtreeIDs(root, into: &removedIDs)
        for id in removedIDs {
            nodesByID[id] = nil
        }
        if let selectedNode, removedIDs.contains(selectedNode.id) {
            styleRefreshTask?.cancel()
            styleRefreshTask = nil
            styleRefreshGeneration += 1
            self.selectedNode = nil
        }
    }

    private func collectSubtreeIDs(_ node: DOMNode, into ids: inout Set<DOMNode.ID>) {
        ids.insert(node.id)
        guard case let .loaded(children) = node.children else {
            return
        }
        for child in children {
            collectSubtreeIDs(child, into: &ids)
        }
    }

    private func model(for payload: DOM.Node) -> DOMNode {
        let id = DOMNode.ID(payload.id)
        let node: DOMNode
        if let existing = nodesByID[id] {
            existing.update(from: payload)
            existing.modelContext = self
            node = existing
        } else {
            node = DOMNode(node: payload, modelContext: self)
            nodesByID[id] = node
        }

        if let children = payload.children {
            node.setChildren(children.map { model(for: $0) })
        }
        return node
    }
}

extension WebViewModelContext {
    package func apply(_ event: CSS.Event) {
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

        let styles = selectedNode.elementStyles ?? CSSStyles(nodeID: selectedNode.id)
        selectedNode.setElementStyles(styles)
        styles.markLoading()
        styleRefreshGeneration += 1
        let generation = styleRefreshGeneration
        styleRefreshTask = Task { @MainActor [weak self, weak selectedNode, styles] in
            guard let self, let selectedNode else {
                return
            }
            await self.loadStyles(for: selectedNode, into: styles, generation: generation)
        }
    }

    private func loadStyles(for node: DOMNode, into styles: CSSStyles, generation: Int) async {
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
            let computedProperties = try await currentPage.css.computedStyle(for: node.id.proxyID)
            guard isCurrentStyleRefresh(node: node, generation: generation) else {
                return
            }
            styles.load(matchedStyles: matchedStyles, computedProperties: computedProperties)
        } catch let error as WebViewProxyError {
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
                method: "getMatchedStylesForNode/getComputedStyleForNode",
                message: String(describing: error)
            ))
        }
    }

    private func isCurrentStyleRefresh(node: DOMNode, generation: Int) -> Bool {
        Task.isCancelled == false && selectedNode === node && styleRefreshGeneration == generation
    }

    private func markSelectedStylesNeedsRefresh(for nodeID: DOMNode.ID) {
        guard selectedNode?.id == nodeID else {
            return
        }
        markSelectedStylesNeedsRefresh()
    }

    private func markSelectedStylesNeedsRefresh() {
        styleRefreshGeneration += 1
        selectedNode?.elementStyles?.markNeedsRefresh()
    }
}

extension WebViewModelContext {
    package func apply(_ event: Network.Event) {
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
            guard let request = requestsByID[NetworkRequest.ID(id)] else {
                fail(.disconnected("Network.responseReceived referenced an unknown request."))
                return
            }
            request.applyResponse(response, resourceType: resourceType, timestamp: timestamp)
        case let .dataReceived(id, dataLength, timestamp):
            guard let request = requestsByID[NetworkRequest.ID(id)] else {
                fail(.disconnected("Network.dataReceived referenced an unknown request."))
                return
            }
            request.applyDataReceived(dataLength: dataLength, timestamp: timestamp)
        case let .loadingFinished(id, timestamp):
            guard let request = requestsByID[NetworkRequest.ID(id)] else {
                fail(.disconnected("Network.loadingFinished referenced an unknown request."))
                return
            }
            request.finish(timestamp: timestamp)
        case let .loadingFailed(id, errorText, canceled, timestamp):
            guard let request = requestsByID[NetworkRequest.ID(id)] else {
                fail(.disconnected("Network.loadingFailed referenced an unknown request."))
                return
            }
            request.fail(errorText: errorText, canceled: canceled, timestamp: timestamp)
        case let .webSocket(event):
            apply(event)
        case .requestServedFromMemoryCache,
             .unknown:
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
        let request: NetworkRequest
        if let existing = requestsByID[id] {
            request = existing
            if let redirectResponse, existing.isActive {
                request.applyRedirect(
                    to: payload,
                    redirectResponse: redirectResponse,
                    timestamp: timestamp,
                    resourceType: resourceType
                )
            } else if existing.isActive == false {
                request.applyRequestWillBeSent(request: payload, resourceType: resourceType, timestamp: timestamp)
            }
        } else {
            request = NetworkRequest(request: payload, resourceType: resourceType, timestamp: timestamp, modelContext: self)
            requestsByID[id] = request
            orderedRequestIDs.append(id)
        }
        refreshAllRequests()
    }

    private func apply(_ event: Network.WebSocketEvent) {
        switch event {
        case let .created(id, url):
            applyWebSocketCreated(id: id, url: url)
        case let .handshakeRequest(id, request, timestamp):
            guard let networkRequest = networkRequest(forWebSocketEvent: id, method: "webSocketWillSendHandshakeRequest") else {
                return
            }
            networkRequest.applyWebSocketHandshakeRequest(request, timestamp: timestamp)
        case let .handshakeResponse(id, response, timestamp):
            guard let networkRequest = networkRequest(forWebSocketEvent: id, method: "webSocketHandshakeResponseReceived") else {
                return
            }
            networkRequest.applyWebSocketHandshakeResponse(response, timestamp: timestamp)
        case let .frameSent(id, frame, timestamp):
            guard let networkRequest = networkRequest(forWebSocketEvent: id, method: "webSocketFrameSent") else {
                return
            }
            networkRequest.appendWebSocketFrame(frame, direction: .sent, timestamp: timestamp)
        case let .frameReceived(id, frame, timestamp):
            guard let networkRequest = networkRequest(forWebSocketEvent: id, method: "webSocketFrameReceived") else {
                return
            }
            networkRequest.appendWebSocketFrame(frame, direction: .received, timestamp: timestamp)
        case let .error(id, message, timestamp):
            guard let networkRequest = networkRequest(forWebSocketEvent: id, method: "webSocketFrameError") else {
                return
            }
            networkRequest.appendWebSocketError(message, timestamp: timestamp)
        case let .closed(id, timestamp):
            guard let networkRequest = networkRequest(forWebSocketEvent: id, method: "webSocketClosed") else {
                return
            }
            networkRequest.closeWebSocket(timestamp: timestamp)
        case .other:
            break
        }
    }

    private func applyWebSocketCreated(id proxyID: Network.Request.ID, url: String) {
        let id = NetworkRequest.ID(proxyID)
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
        refreshAllRequests()
    }

    private func networkRequest(
        forWebSocketEvent proxyID: Network.Request.ID,
        method: String
    ) -> NetworkRequest? {
        guard let request = requestsByID[NetworkRequest.ID(proxyID)] else {
            fail(.disconnected("Network.\(method) referenced an unknown request."))
            return nil
        }
        return request
    }

    private func refreshAllRequests() {
        allNetworkRequests.setItems(orderedRequestIDs.compactMap { requestsByID[$0] })
    }
}

extension WebViewModelContext {
    package func apply(_ event: Console.Event) {
        switch event {
        case let .messageAdded(message):
            applyMessageAdded(message)
        case let .messageRepeatCountUpdated(count, timestamp):
            guard let lastConsoleMessageID,
                  let message = consoleMessagesByID[lastConsoleMessageID] else {
                fail(.disconnected("Console.messageRepeatCountUpdated referenced no current message."))
                return
            }
            message.updateRepeatCount(count, timestamp: timestamp)
        case .messagesCleared:
            consoleMessagesByID = [:]
            orderedConsoleMessageIDs = []
            lastConsoleMessageID = nil
            refreshAllConsoleMessages()
        case .unknown:
            break
        }
    }

    private func applyMessageAdded(_ payload: Console.Message) {
        let id = ConsoleMessage.ID(nextConsoleMessageOrdinal)
        nextConsoleMessageOrdinal += 1
        let parameters = payload.parameters.map(registerRuntimeObject)
        let message = ConsoleMessage(id: id, message: payload, parameters: parameters)
        consoleMessagesByID[id] = message
        orderedConsoleMessageIDs.append(id)
        lastConsoleMessageID = id
        refreshAllConsoleMessages()
    }

    private func refreshAllConsoleMessages() {
        allConsoleMessages.setItems(orderedConsoleMessageIDs.compactMap { consoleMessagesByID[$0] })
    }
}

extension WebViewModelContext {
    package func apply(_ event: Runtime.Event, targetID: WebViewTarget.ID? = nil) {
        switch event {
        case let .executionContextCreated(context):
            applyExecutionContextCreated(context)
        case let .executionContextDestroyed(id):
            applyExecutionContextDestroyed(id)
        case let .executionContextsCleared(eventTargetID):
            if let targetID, eventTargetID != targetID {
                fail(.disconnected("Runtime.executionContextsCleared referenced a mismatched target."))
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
            let context = RuntimeContext(context: payload)
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
            fail(.disconnected("Runtime.executionContextDestroyed referenced an unknown context."))
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
