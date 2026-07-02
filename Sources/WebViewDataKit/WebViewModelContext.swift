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
    public private(set) var rootNode: DOMNode?
    public private(set) var selectedNode: DOMNode?

    @ObservationIgnored private var currentPage: WebViewTarget?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var documentReloadTask: Task<Void, Never>?
    @ObservationIgnored private var eventTasks: [Task<Void, Never>]
    @ObservationIgnored private var nodesByID: [DOMNode.ID: DOMNode]
    @ObservationIgnored private var requestsByID: [NetworkRequest.ID: NetworkRequest]
    @ObservationIgnored private var orderedRequestIDs: [NetworkRequest.ID]
    @ObservationIgnored private let allNetworkRequests: WebViewFetchedResults<NetworkRequest>

    public init(proxy: WebViewProxy) {
        self.proxy = proxy
        state = .attaching
        rootNode = nil
        selectedNode = nil
        currentPage = nil
        startupTask = nil
        documentReloadTask = nil
        eventTasks = []
        nodesByID = [:]
        requestsByID = [:]
        orderedRequestIDs = []
        allNetworkRequests = WebViewFetchedResults()
    }

    deinit {
        startupTask?.cancel()
        documentReloadTask?.cancel()
        for task in eventTasks {
            task.cancel()
        }
    }

    public func start() {
        startupTask?.cancel()
        state = .attaching
        startupTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.startup()
        }
    }

    public func node(for id: DOMNode.ID) -> DOMNode? {
        nodesByID[id]
    }

    public func select(_ node: DOMNode?) {
        selectedNode = node
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

    package func detach() {
        startupTask?.cancel()
        startupTask = nil
        documentReloadTask?.cancel()
        documentReloadTask = nil
        for task in eventTasks {
            task.cancel()
        }
        eventTasks = []
        currentPage = nil
        state = .detached
    }

    private func startup() async {
        do {
            let target = try await proxy.waitForCurrentPage()
            currentPage = target
            subscribe(to: target)
            let document = try await target.dom.getDocument()
            applyDocument(document)
            state = .attached
        } catch let error as WebViewProxyError {
            fail(error)
        } catch {
            fail(.attachFailed(String(describing: error)))
        }
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
        case let .attributeRemoved(id, name):
            guard let node = nodesByID[DOMNode.ID(id)] else {
                fail(.disconnected("DOM.attributeRemoved referenced an unknown node."))
                return
            }
            node.removeAttribute(name: name)
        case let .characterDataModified(id, value):
            guard let node = nodesByID[DOMNode.ID(id)] else {
                fail(.disconnected("DOM.characterDataModified referenced an unknown node."))
                return
            }
            node.setNodeValue(value)
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
            node = existing
        } else {
            node = DOMNode(node: payload)
            nodesByID[id] = node
        }

        if let children = payload.children {
            node.setChildren(children.map { model(for: $0) })
        }
        return node
    }
}

extension WebViewModelContext {
    package func apply(_ event: Network.Event) {
        switch event {
        case let .requestWillBeSent(id, request, resourceType, _, _):
            applyRequestWillBeSent(id: id, request: request, resourceType: resourceType)
        case let .responseReceived(id, response, resourceType, _):
            guard let request = requestsByID[NetworkRequest.ID(id)] else {
                fail(.disconnected("Network.responseReceived referenced an unknown request."))
                return
            }
            request.applyResponse(response, resourceType: resourceType)
        case let .dataReceived(id, dataLength, _):
            guard let request = requestsByID[NetworkRequest.ID(id)] else {
                fail(.disconnected("Network.dataReceived referenced an unknown request."))
                return
            }
            request.applyDataReceived(dataLength: dataLength)
        case let .loadingFinished(id, _):
            guard let request = requestsByID[NetworkRequest.ID(id)] else {
                fail(.disconnected("Network.loadingFinished referenced an unknown request."))
                return
            }
            request.finish()
        case let .loadingFailed(id, errorText, canceled, _):
            guard let request = requestsByID[NetworkRequest.ID(id)] else {
                fail(.disconnected("Network.loadingFailed referenced an unknown request."))
                return
            }
            request.fail(errorText: errorText, canceled: canceled)
        case .requestServedFromMemoryCache,
             .webSocket,
             .unknown:
            break
        }
    }

    private func applyRequestWillBeSent(
        id proxyID: Network.Request.ID,
        request payload: Network.Request,
        resourceType: Network.ResourceType?
    ) {
        let id = NetworkRequest.ID(proxyID)
        let request: NetworkRequest
        if let existing = requestsByID[id] {
            request = existing
            request.applyRequestWillBeSent(request: payload, resourceType: resourceType)
        } else {
            request = NetworkRequest(request: payload, resourceType: resourceType, modelContext: self)
            requestsByID[id] = request
            orderedRequestIDs.append(id)
        }
        refreshAllRequests()
    }

    private func refreshAllRequests() {
        allNetworkRequests.setItems(orderedRequestIDs.compactMap { requestsByID[$0] })
    }
}
