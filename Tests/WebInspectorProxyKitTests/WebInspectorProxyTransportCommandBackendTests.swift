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
    let target = pageTarget(proxy: WebInspectorProxy(backend: WebInspectorTransportCommandBackend(transport: transport)))

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
    let target = pageTarget(proxy: WebInspectorProxy(backend: WebInspectorTransportCommandBackend(transport: transport)))

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
    let target = pageTarget(proxy: WebInspectorProxy(backend: WebInspectorTransportCommandBackend(transport: transport)))

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

private func installPageTarget(in transport: TransportSession) async {
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#
    )
}

private func waitForTargetMessage(
    _ backend: FakeTransportBackend,
    method: String
) async throws -> SentTargetMessage {
    try await withThrowingTaskGroup(of: SentTargetMessage.self) { group in
        defer {
            group.cancelAll()
        }

        group.addTask {
            try await backend.waitForTargetMessage(method: method)
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
