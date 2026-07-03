import Foundation
import Testing
import WebInspectorProxyKit
import WebInspectorTestSupport
import WebInspectorTransport

private let transportCommandBackendWaitTimeout: Duration = .milliseconds(750)

@Test
func transportCommandBackendDispatchesPageReloadThroughTargetRoute() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: WebInspectorTransportBackend(transport: transport)))

    let reloadTask = Task {
        try await target.page.reload()
    }

    let sent = try await waitForTargetMessage(backend, method: "Page.reload")
    #expect(sent.targetIdentifier == ProtocolTarget.ID("page-main"))
    #expect(try messageMethod(sent.message) == "Page.reload")
    #expect(try messageParameters(sent.message)["ignoreCache"] as? Bool == false)

    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: "{}"
    )
    try await reloadTask.value
}

@Test
func transportCommandBackendDecodesDOMRequestNodeResult() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: WebInspectorTransportBackend(transport: transport)))

    let requestNodeTask = Task {
        try await target.dom.requestNode(forRemoteObject: Runtime.RemoteObject.ID("remote-node"))
    }

    let sent = try await waitForTargetMessage(backend, method: "DOM.requestNode")
    #expect(sent.targetIdentifier == ProtocolTarget.ID("page-main"))
    #expect(try messageMethod(sent.message) == "DOM.requestNode")
    #expect(try messageParameters(sent.message)["objectId"] as? String == "remote-node")

    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: #"{"nodeId":"protocol-node"}"#
    )

    #expect(try await requestNodeTask.value == DOM.Node.ID("protocol-node"))
}

@Test
func transportCommandBackendDecodesDOMDocumentResult() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: WebInspectorTransportBackend(transport: transport)))

    let documentTask = Task {
        try await target.dom.getDocument()
    }

    let sent = try await waitForTargetMessage(backend, method: "DOM.getDocument")
    #expect(sent.targetIdentifier == ProtocolTarget.ID("page-main"))
    #expect(try messageMethod(sent.message) == "DOM.getDocument")
    #expect(try messageParameters(sent.message).isEmpty)

    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: ##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","localName":"","nodeValue":"","frameId":"main-frame","documentURL":"https://example.test/","baseURL":"https://example.test/","childNodeCount":1,"children":[{"nodeId":2,"nodeType":1,"nodeName":"HTML","localName":"html","nodeValue":"","attributes":["lang","en"],"childNodeCount":0}]}}"##
    )

    let document = try await documentTask.value
    #expect(document.id == DOM.Node.ID("1"))
    #expect(document.frameID == FrameID("main-frame"))
    #expect(document.documentURL == "https://example.test/")
    #expect(document.baseURL == "https://example.test/")
    #expect(document.childNodeCount == 1)
    let child = try #require(document.children?.first)
    #expect(child.id == DOM.Node.ID("2"))
    #expect(child.attributes["lang"] == "en")
}

@Test
func transportBackedProxyMaterializesCurrentPageFromTransportRegistry() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    let proxyTask = Task {
        try await WebInspectorProxy(transport: transport)
    }

    await installPageTarget(in: transport)

    let proxy = try await throwingValue(of: proxyTask)
    let target = try await proxy.waitForCurrentPage()
    #expect(target.id == .currentPage)
    guard case .page = target.kind else {
        Issue.record("Expected current page target.")
        return
    }
    #expect(target.frameID == FrameID("main-frame"))
    #expect(target.route == .currentPage)
}

@Test
func transportBackedProxyCloseDetachesTransportAndFinishesEventStreams() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let eventTask = Task {
        var iterator = target.dom.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .dom)
    await proxy.close()

    #expect(await backend.isDetached())
    #expect(try await value(of: eventTask) == nil)
}

@Test
func transportBackedCurrentPageRouteFollowsCommittedMainPageTarget() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport, targetID: ProtocolTarget.ID("page-old"))
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let firstReloadTask = Task {
        try await target.page.reload()
    }
    let firstSent = try await waitForTargetMessage(backend, method: "Page.reload")
    #expect(firstSent.targetIdentifier == ProtocolTarget.ID("page-old"))
    await receiveTargetReply(
        transport,
        targetID: firstSent.targetIdentifier,
        messageID: try messageID(firstSent.message),
        result: "{}"
    )
    try await firstReloadTask.value

    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-new","type":"page","isProvisional":true}}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-old","newTargetId":"page-new"}}"#
    )

    let secondReloadTask = Task {
        try await target.page.reload()
    }
    let secondSent = try await waitForTargetMessage(backend, method: "Page.reload", after: 1)
    #expect(secondSent.targetIdentifier == ProtocolTarget.ID("page-new"))
    await receiveTargetReply(
        transport,
        targetID: secondSent.targetIdentifier,
        messageID: try messageID(secondSent.message),
        result: "{}"
    )
    try await secondReloadTask.value
}

@Test
func transportBackendDecodesRootScopedDOMDocumentUpdatedForCurrentPage() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: WebInspectorTransportBackend(transport: transport)))

    let eventTask = Task {
        var iterator = target.dom.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .dom)
    await transport.receiveRootMessage(#"{"method":"DOM.documentUpdated","params":{}}"#)

    let event = try #require(try await value(of: eventTask))
    guard case .documentUpdated = event else {
        Issue.record("Expected DOM.documentUpdated.")
        return
    }
}

@Test
func transportBackendDecodesNetworkResponseEventForTargetRoute() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: WebInspectorTransportBackend(transport: transport)))

    let eventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .network)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.responseReceived",
        params: #"{"requestId":"request-1","type":"Document","response":{"url":"https://example.test/","status":200,"statusText":"OK","mimeType":"text/html","headers":{"content-type":"text/html"},"source":"network"},"timestamp":12.5}"#
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .responseReceived(id, response, resourceType, timestamp) = event else {
        Issue.record("Expected Network.responseReceived.")
        return
    }
    #expect(id == Network.Request.ID("request-1"))
    #expect(response.url == "https://example.test/")
    #expect(response.status == 200)
    #expect(response.headers["content-type"] == "text/html")
    #expect(response.source == Network.Source(rawValue: "network"))
    #expect(resourceType == .document)
    #expect(timestamp == 12.5)
}

@Test
func transportBackendFiltersEventsByRoute() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-target","type":"frame","frameId":"frame-1","isProvisional":false}}}"#
    )
    let proxy = WebInspectorProxy(backend: WebInspectorTransportBackend(transport: transport))
    let page = pageTarget(proxy: proxy)
    let frame = WebInspectorTarget(
        id: WebInspectorTarget.ID("frame-target"),
        kind: .frame,
        frameID: FrameID("frame-1"),
        isProvisional: false,
        proxy: proxy,
        route: RoutingTargetID("frame-target")
    )

    let pageEventTask = Task {
        var iterator = page.network.events.makeAsyncIterator()
        return await iterator.next()
    }
    let frameEventTask = Task {
        var iterator = frame.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(page, domain: .network)
    await waitForEventSubscription(frame, domain: .network)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("frame-target"),
        method: "Network.loadingFinished",
        params: #"{"requestId":"frame-request","timestamp":4,"sourceMapURL":"frame.js.map","metrics":{"responseBodyBytesReceived":128,"responseBodyDecodedSize":256}}"#
    )

    let frameEvent = try #require(try await value(of: frameEventTask))
    guard case let .loadingFinished(id, timestamp, sourceMapURL, metrics) = frameEvent else {
        Issue.record("Expected frame route to receive Network.loadingFinished.")
        return
    }
    #expect(id == Network.Request.ID("frame-request"))
    #expect(timestamp == 4)
    #expect(sourceMapURL == "frame.js.map")
    #expect(metrics?.encodedDataLength == 128)
    #expect(metrics?.decodedBodyLength == 256)

    pageEventTask.cancel()
}

@Test
func transportBackendRuntimeClearedUsesSemanticTargetID() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = WebInspectorProxy(backend: WebInspectorTransportBackend(transport: transport))
    let retargeted = WebInspectorTarget(
        id: WebInspectorTarget.ID("semantic-page"),
        kind: .page,
        frameID: FrameID("main-frame"),
        isProvisional: false,
        proxy: proxy,
        route: RoutingTargetID("page-main")
    )

    let eventTask = Task {
        var iterator = retargeted.runtime.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(retargeted, domain: .runtime)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Runtime.executionContextsCleared",
        params: "{}"
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .executionContextsCleared(target) = event else {
        Issue.record("Expected Runtime.executionContextsCleared.")
        return
    }
    #expect(target == WebInspectorTarget.ID("semantic-page"))
}

private func pageTarget(proxy: WebInspectorProxy) -> WebInspectorTarget {
    WebInspectorTarget(
        id: WebInspectorTarget.ID("page-main"),
        kind: .page,
        frameID: FrameID("main-frame"),
        isProvisional: false,
        proxy: proxy,
        route: RoutingTargetID("page-main")
    )
}

private func installPageTarget(
    in transport: TransportSession,
    targetID: ProtocolTarget.ID = ProtocolTarget.ID("page-main")
) async {
    let targetID = jsonEscapedString(targetID.rawValue)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"\#(targetID)","type":"page","frameId":"main-frame","isProvisional":false}}}"#
    )
}

private func waitForEventSubscription(
    _ target: WebInspectorTarget,
    domain: WebInspectorProxyEventDomain
) async {
    await target.proxy.waitForEventSubscription(targetID: target.id, route: target.route, domain: domain)
}

private func receiveTargetEvent(
    _ transport: TransportSession,
    targetID: ProtocolTarget.ID,
    method: String,
    params: String
) async {
    await transport.receiveRootMessage(targetDispatchMessage(
        targetID: targetID,
        message: #"{"method":"\#(method)","params":\#(params)}"#
    ))
}

private func waitForTargetMessage(
    _ backend: FakeTransportBackend,
    method: String,
    after count: Int = 0
) async throws -> SentTargetMessage {
    try await withThrowingTaskGroup(of: SentTargetMessage.self) { group in
        defer {
            group.cancelAll()
        }

        group.addTask {
            try await backend.waitForTargetMessage(method: method, after: count)
        }
        group.addTask {
            try await Task.sleep(for: transportCommandBackendWaitTimeout)
            throw WebInspectorProxyError.timeout(domain: "test", method: method)
        }

        guard let message = try await group.next() else {
            throw WebInspectorProxyError.timeout(domain: "test", method: method)
        }
        return message
    }
}

private func receiveTargetReply(
    _ transport: TransportSession,
    targetID: ProtocolTarget.ID,
    messageID: UInt64,
    result: String
) async {
    await transport.receiveRootMessage(targetDispatchMessage(
        targetID: targetID,
        message: #"{"id":\#(messageID),"result":\#(result)}"#
    ))
}

private func targetDispatchMessage(
    targetID: ProtocolTarget.ID,
    message: String
) -> String {
    let escapedTargetID = jsonEscapedString(targetID.rawValue)
    let escapedMessage = jsonEscapedString(message)
    return #"{"method":"Target.dispatchMessageFromTarget","params":{"targetId":"\#(escapedTargetID)","message":"\#(escapedMessage)"}}"#
}

private func jsonEscapedString(_ string: String) -> String {
    string
        .replacingOccurrences(of: #"\"#, with: #"\\"#)
        .replacingOccurrences(of: #"""#, with: #"\""#)
}

private func messageID(_ message: String) throws -> UInt64 {
    let object = try messageObject(message)
    if let number = object["id"] as? NSNumber {
        return number.uint64Value
    }
    if let string = object["id"] as? String,
       let id = UInt64(string) {
        return id
    }
    throw TransportSession.Error.malformedMessage
}

private func messageMethod(_ message: String) throws -> String? {
    try messageObject(message)["method"] as? String
}

private func messageParameters(_ message: String) throws -> [String: Any] {
    try messageObject(message)["params"] as? [String: Any] ?? [:]
}

private func messageObject(_ message: String) throws -> [String: Any] {
    let data = try #require(message.data(using: .utf8))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private struct TimedOut: Error {}

private func value<T: Sendable>(
    of task: Task<T, Never>,
    timeout: Duration = .seconds(1)
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            await task.value
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimedOut()
        }
        guard let value = try await group.next() else {
            throw TimedOut()
        }
        group.cancelAll()
        return value
    }
}

private func throwingValue<T: Sendable>(
    of task: Task<T, any Error>,
    timeout: Duration = .seconds(1)
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await task.value
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimedOut()
        }
        guard let value = try await group.next() else {
            throw TimedOut()
        }
        group.cancelAll()
        return value
    }
}
