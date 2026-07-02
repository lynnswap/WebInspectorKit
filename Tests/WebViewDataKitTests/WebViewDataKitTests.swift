import Testing
import WebViewDataKit
import WebViewProxyKit
import WebViewProxyKitTesting

@MainActor
@Test
func domEventsPopulateRootAndPreserveChildIdentity() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let documentID = DOM.Node.ID("document")
    let childID = DOM.Node.ID("child")
    let grandchildID = DOM.Node.ID("grandchild")

    await runtime.backend.enqueue(
        DOM.Node(id: documentID, nodeType: 9, nodeName: "#document", childNodeCount: 1),
        for: "DOM",
        method: "getDocument"
    )

    let container = WebViewModelContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await runtime.backend.waitForSubscribers(domain: "DOM", target: target, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "Network", target: target, count: 1)
    try await waitUntil { context.rootNode != nil }

    await runtime.backend.emit(
        .setChildNodes(parent: documentID, nodes: [
            DOM.Node(
                id: childID,
                nodeType: 1,
                nodeName: "DIV",
                localName: "div",
                attributes: ["class": "before"],
                childNodeCount: 0
            )
        ]),
        target: target
    )
    let child = try await waitForChild(in: context)
    #expect(context.node(for: child.id) === child)

    await runtime.backend.emit(
        .attributeModified(childID, name: "class", value: "after"),
        target: target
    )
    try await waitUntil { child.attributes["class"] == "after" }
    #expect(context.node(for: child.id) === child)

    await runtime.backend.emit(
        .childNodeCountUpdated(childID, count: 2),
        target: target
    )
    try await waitUntil { child.childNodeCount == 2 }
    #expect(context.node(for: child.id) === child)

    await runtime.backend.emit(
        .setChildNodes(parent: childID, nodes: [
            DOM.Node(id: grandchildID, nodeType: 3, nodeName: "#text", nodeValue: "hello")
        ]),
        target: target
    )
    try await waitUntil {
        guard case let .loaded(children) = child.children else {
            return false
        }
        return children.first?.id == DOMNode.ID(grandchildID)
    }
    guard case let .loaded(grandchildren) = child.children else {
        Issue.record("Expected loaded child subtree.")
        return
    }
    let grandchild = try #require(grandchildren.first)
    context.select(grandchild)

    await runtime.backend.emit(
        .childNodeRemoved(parent: documentID, node: childID),
        target: target
    )
    try await waitUntil {
        guard let root = context.rootNode, case let .loaded(children) = root.children else {
            return false
        }
        return children.isEmpty
    }
    #expect(context.node(for: child.id) == nil)
    #expect(context.node(for: grandchild.id) == nil)
    #expect(context.selectedNode == nil)
}

@MainActor
@Test
func documentUpdatedReloadsRootDocument() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let replacementID = DOM.Node.ID("replacement-document")

    await runtime.backend.enqueue(
        DOM.Node(id: replacementID, nodeType: 9, nodeName: "#document"),
        for: "DOM",
        method: "getDocument"
    )

    await runtime.backend.emit(.documentUpdated, target: target)

    try await waitUntil {
        context.rootNode?.id == DOMNode.ID(replacementID)
    }
}

@MainActor
@Test
func childInsertIntoUnrequestedParentDoesNotMarkChildrenLoaded() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let insertedID = DOM.Node.ID("inserted-child")

    await runtime.backend.emit(
        .childNodeInserted(
            parent: document.id.proxyID,
            previous: nil,
            node: DOM.Node(
                id: insertedID,
                nodeType: 1,
                nodeName: "DIV",
                localName: "div"
            )
        ),
        target: target
    )

    try await waitUntil {
        document.childNodeCount == 1
    }
    guard case let .unrequested(count) = document.children else {
        Issue.record("Expected parent children to stay unrequested.")
        return
    }
    #expect(count == 1)
    #expect(context.node(for: DOMNode.ID(insertedID)) == nil)
}

@MainActor
@Test
func removingLoadedChildPurgesDescendantsFromIdentityMap() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let documentID = DOM.Node.ID("document")
    let childID = DOM.Node.ID("child")
    let grandchildID = DOM.Node.ID("grandchild")

    await runtime.backend.enqueue(
        DOM.Node(id: documentID, nodeType: 9, nodeName: "#document"),
        for: "DOM",
        method: "getDocument"
    )

    let container = WebViewModelContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await runtime.backend.waitForSubscribers(domain: "DOM", target: target, count: 1)
    try await waitUntil { context.rootNode != nil }

    await runtime.backend.emit(
        .setChildNodes(parent: documentID, nodes: [
            DOM.Node(
                id: childID,
                nodeType: 1,
                nodeName: "SECTION",
                localName: "section",
                childNodeCount: 1,
                children: [
                    DOM.Node(
                        id: grandchildID,
                        nodeType: 1,
                        nodeName: "SPAN",
                        localName: "span"
                    )
                ]
            )
        ]),
        target: target
    )

    try await waitUntil {
        context.node(for: DOMNode.ID(grandchildID)) != nil
    }

    await runtime.backend.emit(
        .childNodeRemoved(parent: documentID, node: childID),
        target: target
    )

    try await waitUntil {
        context.node(for: DOMNode.ID(childID)) == nil
            && context.node(for: DOMNode.ID(grandchildID)) == nil
    }
}

@MainActor
@Test
func networkEventsPopulateAllRequestsInOrder() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("request-1")

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "https://example.com/data.json",
                method: "GET",
                headers: ["Accept": "application/json"]
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    await runtime.backend.emit(
        .responseReceived(
            id: requestID,
            response: Network.Response(
                status: 200,
                mimeType: "application/json",
                headers: ["Content-Type": "application/json"]
            ),
            resourceType: .fetch,
            timestamp: 2
        ),
        target: target
    )
    await runtime.backend.emit(
        .dataReceived(id: requestID, dataLength: 12, timestamp: 3),
        target: target
    )
    await runtime.backend.emit(
        .loadingFinished(id: requestID, timestamp: 4),
        target: target
    )

    let results: WebViewFetchedResults<NetworkRequest> = context.fetchedResults(for: .allRequests)
    try await waitUntil {
        results.items.count == 1 && results.items.first?.state == .finished
    }
    let request = try #require(results.items.first)
    #expect(request.url == "https://example.com/data.json")
    #expect(request.method == "GET")
    #expect(request.resourceType == .fetch)
    #expect(request.status == 200)
    #expect(request.mimeType == "application/json")
    #expect(request.requestHeaders["Accept"] == "application/json")
    #expect(request.responseHeaders["Content-Type"] == "application/json")
}

@MainActor
@Test
func repeatedRequestWillBeSentClearsStaleResponseFields() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("redirected-request")

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(id: requestID, url: "https://example.com/redirect", method: "GET"),
            resourceType: .document,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    await runtime.backend.emit(
        .responseReceived(
            id: requestID,
            response: Network.Response(
                status: 302,
                mimeType: "text/html",
                headers: ["Location": "https://example.com/final"]
            ),
            resourceType: .document,
            timestamp: 2
        ),
        target: target
    )

    let results: WebViewFetchedResults<NetworkRequest> = context.fetchedResults(for: .allRequests)
    try await waitUntil {
        results.items.first?.status == 302
    }

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(id: requestID, url: "https://example.com/final", method: "GET"),
            resourceType: .document,
            redirectResponse: Network.Response(status: 302),
            timestamp: 3
        ),
        target: target
    )

    let request = try #require(results.items.first)
    try await waitUntil {
        request.url == "https://example.com/final" && request.state == .pending
    }
    #expect(request.status == nil)
    #expect(request.mimeType == nil)
    #expect(request.responseHeaders.isEmpty)
    #expect(request.responseBody.phase == .available)
    #expect(request.responseBody.text == nil)
}

@MainActor
@Test
func fetchResponseBodyStoresLoadedAndFailedPhases() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let loadedID = Network.Request.ID("loaded-request")
    let failedID = Network.Request.ID("failed-request")

    await emitFinishedRequest(id: loadedID, target: target, backend: runtime.backend)
    await emitFinishedRequest(id: failedID, target: target, backend: runtime.backend)

    let results: WebViewFetchedResults<NetworkRequest> = context.fetchedResults(for: .allRequests)
    try await waitUntil { results.items.count == 2 }
    let loadedRequest = try #require(results.items.first { $0.id == NetworkRequest.ID(loadedID) })
    let failedRequest = try #require(results.items.first { $0.id == NetworkRequest.ID(failedID) })

    await runtime.backend.enqueue(
        Network.Body(data: "hello", base64Encoded: false),
        for: "Network",
        method: "getResponseBody"
    )

    await loadedRequest.fetchResponseBody()
    #expect(loadedRequest.responseBody.phase == .loaded)
    #expect(loadedRequest.responseBody.text == "hello")
    #expect(loadedRequest.responseBody.isBase64Encoded == false)

    await failedRequest.fetchResponseBody()
    guard case let .failed(error) = failedRequest.responseBody.phase else {
        Issue.record("Expected failed response body phase.")
        return
    }
    guard case .commandFailed(domain: "Network", method: "getResponseBody", message: _) = error else {
        Issue.record("Expected Network.getResponseBody command failure.")
        return
    }

    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "Network", method: "getResponseBody")))
}

@MainActor
private func startContext(
    runtime: WebViewProxyTestRuntime
) async throws -> (WebViewTarget, WebViewModelContext) {
    let target = try await runtime.proxy.waitForCurrentPage()
    await runtime.backend.enqueue(
        DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document"),
        for: "DOM",
        method: "getDocument"
    )

    let container = WebViewModelContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await runtime.backend.waitForSubscribers(domain: "DOM", target: target, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "Network", target: target, count: 1)
    try await waitUntil { context.state == .attached }
    return (target, context)
}

private func emitFinishedRequest(
    id: Network.Request.ID,
    target: WebViewTarget,
    backend: WebViewTestBackend
) async {
    await backend.emit(
        .requestWillBeSent(
            id: id,
            request: Network.Request(id: id, url: "https://example.com/\(id)", method: "GET"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    await backend.emit(
        .responseReceived(
            id: id,
            response: Network.Response(status: 200, mimeType: "text/plain"),
            resourceType: .fetch,
            timestamp: 2
        ),
        target: target
    )
    await backend.emit(.loadingFinished(id: id, timestamp: 3), target: target)
}

@MainActor
private func waitForChild(in context: WebViewModelContext) async throws -> DOMNode {
    try await waitUntil {
        guard let root = context.rootNode else {
            return false
        }
        guard case let .loaded(children) = root.children else {
            return false
        }
        return children.isEmpty == false
    }

    let root = try #require(context.rootNode)
    guard case let .loaded(children) = root.children else {
        Issue.record("Expected loaded root children.")
        throw TestFailure()
    }
    return try #require(children.first)
}

private struct TestFailure: Error {}
private struct TimedOut: Error {}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor @Sendable () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while condition() == false {
        if clock.now >= deadline {
            throw TimedOut()
        }
        await Task.yield()
    }
}
