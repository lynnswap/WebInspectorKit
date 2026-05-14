import Foundation
import Testing
import WebKit
@testable import V2_WebInspectorCore
@testable import V2_WebInspectorRuntime
@testable import V2_WebInspectorTransport

@Test
func connectBootstrapsMainPageDocumentInOrder() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)

    try await connect(session, transport: transport, backend: backend)

    let methods = await targetMessageMethods(backend)
    #expect(methods == [
        "Inspector.enable",
        "Inspector.initialized",
        "Runtime.enable",
        "DOM.getDocument",
        "Network.enable",
    ])
    #expect(await session.attachmentState == .attached(targetID: .pageMain))
    #expect(await session.dom.snapshot().currentPage?.mainTargetID == ProtocolTargetIdentifier.pageMain)
    #expect(await session.dom.snapshot().documentsByID.count == 1)
}

@Test
func domainPumpsApplyNetworkEventsToNetworkSession() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Network.requestWillBeSent","params":{"requestId":"request-1","frameId":"main-frame","request":{"url":"https://example.com/app.js"},"timestamp":1}}"#
    )
    let request = try await waitUntil {
        await session.network.requestSnapshot(for: .init(targetID: .pageMain, requestID: .init("request-1")))
    }

    #expect(request.id.targetID == ProtocolTargetIdentifier.pageMain)
    #expect(request.request.url == "https://example.com/app.js")
}

@Test
func networkLazyFetchReturnsCommandResultFromPageTarget() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let sentCount = await backend.sentTargetMessages().count
    let performTask = Task {
        try await session.perform(
            .getResponseBody(
                requestKey: .init(targetID: .frameAd, requestID: .init("request-1")),
                backendResourceIdentifier: nil
            )
        )
    }
    let sent = try await waitForTargetMessage(backend, method: "Network.getResponseBody", after: sentCount)

    #expect(sent.targetIdentifier == ProtocolTargetIdentifier.pageMain)
    #expect(String(data: Data(sent.message.utf8), encoding: .utf8)?.contains(#""requestId":"request-1""#) == true)

    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: #"{"body":"hello","base64Encoded":false}"#
    )
    let result = try await performTask.value

    #expect(result.method == "Network.getResponseBody")
    #expect(result.targetID == ProtocolTargetIdentifier.pageMain)
    #expect(String(data: result.resultData, encoding: .utf8)?.contains(#""body":"hello""#) == true)
}

@Test
func networkResponseBodyFetchAppliesResultToCoreRequest() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Network.requestWillBeSent","params":{"requestId":"request-2","frameId":"main-frame","request":{"url":"https://example.com/api.json"},"timestamp":1}}"#
    )
    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Network.responseReceived","params":{"requestId":"request-2","timestamp":2,"type":"XHR","response":{"url":"https://example.com/api.json","status":200,"mimeType":"application/json","headers":{"content-type":"application/json"}}}}"#
    )
    let request = try await waitUntil {
        await session.network.request(for: .init(targetID: .pageMain, requestID: .init("request-2")))
    }
    let body = try await #require(request.responseBody)
    #expect(await body.fetchState == .available)

    let sentCount = await backend.sentTargetMessages().count
    let fetchTask = Task {
        await session.fetchResponseBody(for: request.id)
    }
    let sent = try await waitForTargetMessage(backend, method: "Network.getResponseBody", after: sentCount)
    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: #"{"body":"{\"ok\":true}","base64Encoded":false}"#
    )
    await fetchTask.value

    #expect(await body.fetchState == .loaded)
    #expect(await body.textRepresentation?.contains("\n") == true)
    #expect(await body.textRepresentation?.contains(#""ok""#) == true)
}

@Test
func frameDocumentRefreshUpdatesOnlyFrameDocument() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let pageDocumentID = try #require(await session.dom.snapshot().currentPageDocumentID)

    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#
    )
    _ = try await waitUntil {
        await session.dom.snapshot().targetsByID[.frameAd]
    }

    let sentCount = await backend.sentTargetMessages().count
    let performTask = Task {
        try await session.perform(.getDocument(targetID: .frameAd))
    }
    let sent = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: sentCount)
    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: ##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","children":[{"nodeId":2,"nodeType":1,"nodeName":"HTML","localName":"html"}]}}"##
    )
    try await performTask.value

    let snapshot = await session.dom.snapshot()
    #expect(snapshot.currentPageDocumentID == pageDocumentID)
    #expect(snapshot.targetsByID[.frameAd]?.currentDocumentID != nil)
    #expect(snapshot.targetsByID[.frameAd]?.currentDocumentID != pageDocumentID)
}

@Test
func requestNodeWaitsForPathPushBeforeSelectingNode() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":7,"frameId":"main-frame"}}}"#
    )
    _ = try await waitUntil {
        await session.dom.snapshot().executionContextsByID[ExecutionContextID(7)]
    }
    let intent = await session.dom.resolveInspectSelection(
        remoteObject: .init(objectID: "selected-object", injectedScriptID: .init(7))
    )
    guard case let .success(commandIntent) = intent else {
        Issue.record("Expected DOM.requestNode intent")
        return
    }

    let sentCount = await backend.sentTargetMessages().count
    let performTask = Task {
        try await session.perform(commandIntent)
    }
    let sent = try await waitForTargetMessage(backend, method: "DOM.requestNode", after: sentCount)
    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":2,"nodes":[{"nodeId":3,"nodeType":1,"nodeName":"DIV","localName":"div","attributes":["id","selected"]}]}}"#
    )
    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: #"{"nodeId":3}"#
    )
    try await performTask.value

    let selectedNode = try #require(await session.dom.selectedNode)
    let nodeName = await selectedNode.nodeName
    let attributes = await selectedNode.attributes
    #expect(nodeName == "DIV")
    #expect(attributes == [DOMAttribute(name: "id", value: "selected")])
}

@Test
func requestNodeFailureDoesNotMutateDOMTree() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(
        configuration: .init(responseTimeout: .seconds(1), bootstrapTimeout: .seconds(1), eventApplicationTimeout: .milliseconds(1))
    )
    try await connect(session, transport: transport, backend: backend)
    let snapshotBeforeSelection = await session.dom.snapshot()

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":7,"frameId":"main-frame"}}}"#
    )
    _ = try await waitUntil {
        await session.dom.snapshot().executionContextsByID[ExecutionContextID(7)]
    }
    let intent = await session.dom.resolveInspectSelection(
        remoteObject: .init(objectID: "missing-object", injectedScriptID: .init(7))
    )
    guard case let .success(commandIntent) = intent else {
        Issue.record("Expected DOM.requestNode intent")
        return
    }

    let sentCount = await backend.sentTargetMessages().count
    let performTask = Task {
        try await session.perform(commandIntent)
    }
    let sent = try await waitForTargetMessage(backend, method: "DOM.requestNode", after: sentCount)
    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: #"{"nodeId":999}"#
    )
    try await performTask.value

    let snapshot = await session.dom.snapshot()
    #expect(snapshot.documentsByID.keys == snapshotBeforeSelection.documentsByID.keys)
    #expect(snapshot.nodesByID.keys == snapshotBeforeSelection.nodesByID.keys)
    #expect(snapshot.selection.selectedNodeID == nil)
    #expect(snapshot.selection.failure == .unresolvedNode(.init(targetID: .pageMain, nodeID: .init(999))))
}

@Test
func detachCancelsPumpsAndClearsModelState() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await session.detach()

    #expect(await backend.isDetached())
    #expect(await session.attachmentState == .detached)
    #expect(await session.dom.snapshot().currentPage == nil)
    #expect(await session.network.snapshot().orderedRequestIDs.isEmpty)
}

@Test
func detachDuringConnectKeepsSessionDetached() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)

    let connectTask = Task {
        try await session.connect(transport: transport)
    }
    _ = try await waitUntil {
        await session.attachmentState == .connecting ? true : nil
    }

    await session.detach()

    await #expect(throws: TransportError.transportClosed) {
        try await connectTask.value
    }
    #expect(await session.attachmentState == .detached)
    #expect(await session.lastError == nil)
    #expect(await backend.isDetached())
}

@Test
func bootstrapFailureClearsSeededModelState() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(20))
    let session = await V2_InspectorSession(
        configuration: .init(
            responseTimeout: .milliseconds(20),
            bootstrapTimeout: .seconds(1),
            eventApplicationTimeout: .milliseconds(25)
        )
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#
    )

    await #expect(throws: TransportError.replyTimeout(method: "Inspector.enable", targetID: .pageMain)) {
        try await session.connect(transport: transport)
    }

    #expect(await session.dom.snapshot().currentPage == nil)
    #expect(await session.network.snapshot().orderedRequestIDs.isEmpty)
    guard case .failed = await session.attachmentState else {
        Issue.record("Expected failed attachment state")
        return
    }
}

@Test
func performIsRejectedUntilBootstrapAttaches() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#
    )

    let connectTask = Task {
        try await session.connect(transport: transport)
    }
    _ = try await waitUntil {
        await session.attachmentState == .connecting ? true : nil
    }

    await #expect(throws: V2_InspectorSessionError("Inspector session is not attached.")) {
        try await session.perform(.getDocument(targetID: .pageMain))
    }

    try await completeBootstrap(transport: transport, backend: backend)
    try await connectTask.value
    #expect(await session.attachmentState == .attached(targetID: .pageMain))
}

@MainActor
@Test
func attachInspectabilityPreparationRestoresOriginalValue() throws {
    guard #available(iOS 16.4, macOS 13.3, *) else {
        return
    }
    let webView = WKWebView(frame: .zero)
    let initialValue = webView.isInspectable
    webView.isInspectable = false

    let originalValue = V2_InspectorSession.prepareInspectability(for: webView)

    #expect(originalValue == false)
    #expect(webView.isInspectable == true)

    V2_InspectorSession.restoreInspectabilityIfNeeded(on: webView, originalValue: originalValue)

    #expect(webView.isInspectable == false)
    webView.isInspectable = initialValue
}

@MainActor
@Test
func eventPumpTimeoutRemovesWaiter() async {
    let pump = V2_DomainEventPump()

    await pump.waitUntilApplied(10, timeout: .milliseconds(1))

    #expect(pump.pendingWaiterCount == 0)
}

private func connect(
    _ session: V2_InspectorSession,
    transport: TransportSession,
    backend: FakeTransportBackend
) async throws {
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#
    )
    let connectTask = Task {
        try await session.connect(transport: transport)
    }
    do {
        try await completeBootstrap(transport: transport, backend: backend)
    } catch {
        do {
            try await connectTask.value
        } catch {
            throw error
        }
        throw error
    }
    try await connectTask.value
}

private func completeBootstrap(
    transport: TransportSession,
    backend: FakeTransportBackend
) async throws {
    var sentCount = 0
    for method in ["Inspector.enable", "Inspector.initialized", "Runtime.enable"] {
        let sent = try await waitForTargetMessage(backend, method: method, after: sentCount)
        sentCount = await backend.sentTargetMessages().count
        await receiveTargetReply(
            transport,
            targetID: sent.targetIdentifier,
            messageID: try messageID(sent.message),
            result: "{}"
        )
    }

    let documentMessage = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: sentCount)
    sentCount = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: documentMessage.targetIdentifier,
        messageID: try messageID(documentMessage.message),
        result: mainDocumentResult
    )

    let networkMessage = try await waitForTargetMessage(backend, method: "Network.enable", after: sentCount)
    await receiveTargetReply(
        transport,
        targetID: networkMessage.targetIdentifier,
        messageID: try messageID(networkMessage.message),
        result: "{}"
    )
}

private let mainDocumentResult = ##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","children":[{"nodeId":2,"nodeType":1,"nodeName":"HTML","localName":"html","children":[]}]}}"##

private func targetMessageMethods(_ backend: FakeTransportBackend) async -> [String?] {
    await backend.sentTargetMessages().map { try? messageMethod($0.message) }
}

private func waitForTargetMessage(
    _ backend: FakeTransportBackend,
    method: String,
    after count: Int = 0
) async throws -> SentTargetMessage {
    try await waitUntil {
        let messages = await backend.sentTargetMessages()
        return messages.dropFirst(count).first { (try? messageMethod($0.message)) == method }
    }
}

private func waitUntil<Value: Sendable>(_ body: @escaping @Sendable () async -> Value?) async throws -> Value {
    let deadline = ContinuousClock.now + .seconds(1)
    while ContinuousClock.now < deadline {
        if let value = await body() {
            return value
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw TransportError.replyTimeout(method: "test wait", targetID: nil)
}

private func receiveTargetDispatch(
    _ transport: TransportSession,
    targetID: ProtocolTargetIdentifier,
    message: String
) async {
    await transport.receiveRootMessage(targetDispatchMessage(targetID: targetID, message: message))
}

private func receiveTargetReply(
    _ transport: TransportSession,
    targetID: ProtocolTargetIdentifier,
    messageID: UInt64,
    result: String
) async {
    await receiveTargetDispatch(
        transport,
        targetID: targetID,
        message: #"{"id":\#(messageID),"result":\#(result)}"#
    )
}

private func targetDispatchMessage(
    targetID: ProtocolTargetIdentifier,
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
        .replacingOccurrences(of: "\n", with: #"\n"#)
        .replacingOccurrences(of: "\r", with: #"\r"#)
}

private func messageID(_ message: String) throws -> UInt64 {
    let data = try #require(message.data(using: .utf8))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    if let number = object["id"] as? NSNumber {
        return number.uint64Value
    }
    if let string = object["id"] as? String,
       let id = UInt64(string) {
        return id
    }
    throw TransportError.malformedMessage
}

private func messageMethod(_ message: String) throws -> String? {
    let data = try #require(message.data(using: .utf8))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return object["method"] as? String
}

private extension ProtocolTargetIdentifier {
    static let pageMain = ProtocolTargetIdentifier("page-main")
    static let frameAd = ProtocolTargetIdentifier("frame-ad")
}

private extension V2_InspectorSessionConfiguration {
    static let test = V2_InspectorSessionConfiguration(
        responseTimeout: .seconds(1),
        bootstrapTimeout: .seconds(1),
        eventApplicationTimeout: .milliseconds(25)
    )
}

private extension DOMSessionSnapshot {
    var currentPageDocumentID: DOMDocumentIdentifier? {
        guard let currentPage else {
            return nil
        }
        return targetsByID[currentPage.mainTargetID]?.currentDocumentID
    }
}
