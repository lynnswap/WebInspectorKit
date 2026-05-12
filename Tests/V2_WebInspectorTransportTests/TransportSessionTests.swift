import Foundation
import Testing
@testable import V2_WebInspectorCore
@testable import V2_WebInspectorTransport

@Test
func rootCommandResolvesFromRootReply() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: .seconds(1))

    let sendTask = Task {
        try await session.send(
            ProtocolCommand(domain: .target, method: "Target.setPauseOnStart", routing: .root)
        )
    }
    let sent = try await waitForRootMessage(backend)
    let id = try messageID(sent)

    await session.receiveRootMessage(#"{"id":\#(id),"result":{"ok":true}}"#)
    let result = try await sendTask.value

    #expect(result.method == "Target.setPauseOnStart")
    #expect(result.targetID == nil)
    #expect(String(data: result.resultData, encoding: .utf8)?.contains(#""ok":true"#) == true)
}

@Test
func targetCommandUsesNestedReplyKey() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: .seconds(1))
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-A","type":"frame","frameId":"frame-A","isProvisional":false}}}"#)

    let sendTask = Task {
        try await session.send(
            ProtocolCommand(domain: .dom, method: "DOM.getDocument", routing: .target(.init("frame-A")))
        )
    }
    let sent = try await waitForTargetMessage(backend)
    let innerID = try messageID(sent.message)

    #expect(sent.targetIdentifier == ProtocolTargetIdentifier("frame-A"))
    await session.receiveTargetMessage(##"{"id":\##(innerID),"result":{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document"}}}"##, targetID: .init("frame-A"))
    let result = try await sendTask.value

    #expect(result.method == "DOM.getDocument")
    #expect(result.targetID == ProtocolTargetIdentifier("frame-A"))
}

@Test
func targetCommandWrapperErrorFailsPendingReplyImmediately() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: .seconds(1))
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-A","type":"frame","frameId":"frame-A","isProvisional":false}}}"#)

    let sendTask = Task {
        try await session.send(
            ProtocolCommand(domain: .dom, method: "DOM.getDocument", routing: .target(.init("frame-A")))
        )
    }
    let sent = try await waitForTargetMessage(backend)

    await session.receiveRootMessage(#"{"id":\#(sent.outerIdentifier),"error":{"message":"target gone"}}"#)

    await #expect(throws: TransportError.remoteError(method: "DOM.getDocument", targetID: .init("frame-A"), message: "target gone")) {
        try await sendTask.value
    }
    #expect(await session.snapshot().pendingTargetReplyKeys.isEmpty)
}

@Test
func targetDestroyFailsPendingTargetReplies() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: .seconds(1))
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-A","type":"frame","frameId":"frame-A","isProvisional":false}}}"#)

    let sendTask = Task {
        try await session.send(
            ProtocolCommand(domain: .dom, method: "DOM.getDocument", routing: .target(.init("frame-A")))
        )
    }
    _ = try await waitForTargetMessage(backend)

    await session.receiveRootMessage(#"{"method":"Target.targetDestroyed","params":{"targetId":"frame-A"}}"#)

    await #expect(throws: TransportError.missingTarget(.init("frame-A"))) {
        try await sendTask.value
    }
    #expect(await session.snapshot().pendingTargetReplyKeys.isEmpty)
}

@Test
func remoteErrorAndTimeoutFailPendingReplies() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: .milliseconds(20))

    let errorTask = Task {
        try await session.send(
            ProtocolCommand(domain: .target, method: "Target.resume", routing: .root)
        )
    }
    let sent = try await waitForRootMessage(backend)
    let id = try messageID(sent)
    await session.receiveRootMessage(#"{"id":\#(id),"error":{"message":"nope"}}"#)
    await #expect(throws: TransportError.remoteError(method: "Target.resume", targetID: nil, message: "nope")) {
        try await errorTask.value
    }

    await #expect(throws: TransportError.replyTimeout(method: "Target.setPauseOnStart", targetID: nil)) {
        _ = try await session.send(
            ProtocolCommand(domain: .target, method: "Target.setPauseOnStart", routing: .root)
        )
    }
}

@Test
func cancellationFailsPendingReplyImmediately() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: .seconds(1))

    let sendTask = Task {
        try await session.send(
            ProtocolCommand(domain: .target, method: "Target.setPauseOnStart", routing: .root)
        )
    }
    _ = try await waitForRootMessage(backend)

    sendTask.cancel()

    do {
        _ = try await sendTask.value
        Issue.record("Expected cancellation")
    } catch is CancellationError {
    } catch {
        Issue.record("Expected CancellationError, got \(error)")
    }
    #expect(await session.snapshot().pendingRootReplyIDs.isEmpty)
}

@Test
func detachFailsPendingRepliesAndClosesStreams() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let stream = await session.events(for: .dom)
    let streamTask = Task {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
    let sendTask = Task {
        try await session.send(
            ProtocolCommand(domain: .target, method: "Target.setPauseOnStart", routing: .root)
        )
    }
    _ = try await waitForRootMessage(backend)

    await session.detach()

    await #expect(throws: TransportError.transportClosed) {
        try await sendTask.value
    }
    let event = await streamTask.value
    #expect(event == nil)
    #expect(await backend.isDetached())
}

@Test
func targetLifecycleUpdatesSnapshotWithoutPrefixGuessing() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"worker-1","type":"service-worker","isPaused":true}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-provisional","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":true}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"frame-provisional","newTargetId":"frame-committed"}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetDestroyed","params":{"targetId":"worker-1"}}"#)
    let snapshot = await session.snapshot()

    #expect(snapshot.currentMainPageTargetID == ProtocolTargetIdentifier("page-main"))
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("worker-1")] == nil)
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("frame-committed")]?.kind == .frame)
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("frame-committed")]?.isProvisional == false)
    #expect(snapshot.frameTargetIDsByFrameID[DOMFrameIdentifier("ad-frame")] == ProtocolTargetIdentifier("frame-committed"))
}

@Test
func pageTargetWithParentFrameIsClassifiedAsFrame() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"iframe-page","type":"page","frameId":"child-frame","parentFrameId":"main-frame","isProvisional":false}}}"#)
    let snapshot = await session.snapshot()

    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("iframe-page")]?.kind == .frame)
    #expect(snapshot.currentMainPageTargetID == nil)
    #expect(snapshot.frameTargetIDsByFrameID[DOMFrameIdentifier("child-frame")] == ProtocolTargetIdentifier("iframe-page"))
}

@Test
func pageTargetWithKnownNonMainFrameIsClassifiedAsFrame() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"iframe-page","type":"page","frameId":"child-frame","isProvisional":false}}}"#)
    let snapshot = await session.snapshot()

    #expect(snapshot.currentMainPageTargetID == ProtocolTargetIdentifier("page-main"))
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("iframe-page")]?.kind == .frame)
    #expect(snapshot.frameTargetIDsByFrameID[DOMFrameIdentifier("child-frame")] == ProtocolTargetIdentifier("iframe-page"))
}

@Test
func pageTargetWithoutFrameIDCanCommitAsCurrentPage() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-old","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-new","type":"page","isProvisional":true}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-old","newTargetId":"page-new"}}"#)
    let snapshot = await session.snapshot()

    #expect(snapshot.currentMainPageTargetID == ProtocolTargetIdentifier("page-new"))
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("page-new")]?.kind == .page)
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("page-new")]?.isProvisional == false)
}

@Test
func targetCommitMergesFrameMetadataAndClearsOldFrameMapping() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-provisional","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":true}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-committed","type":"frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"frame-provisional","newTargetId":"frame-committed"}}"#)
    let snapshot = await session.snapshot()

    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("frame-committed")]?.frameID == DOMFrameIdentifier("ad-frame"))
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("frame-committed")]?.parentFrameID == DOMFrameIdentifier("main-frame"))
    #expect(snapshot.frameTargetIDsByFrameID[DOMFrameIdentifier("ad-frame")] == ProtocolTargetIdentifier("frame-committed"))
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("frame-provisional")] == nil)
}

@Test
func subframeCommitDoesNotConsumeCurrentMainPageTarget() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-committed","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":true}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"frame-committed"}}"#)
    let snapshot = await session.snapshot()

    #expect(snapshot.currentMainPageTargetID == ProtocolTargetIdentifier("page-main"))
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("page-main")] != nil)
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("frame-committed")]?.isProvisional == false)
    #expect(snapshot.frameTargetIDsByFrameID[DOMFrameIdentifier("ad-frame")] == ProtocolTargetIdentifier("frame-committed"))
}

@Test
func targetCommitRetargetsPendingRepliesToCommittedTarget() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: .seconds(1))
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-provisional","type":"frame","frameId":"ad-frame","isProvisional":true}}}"#)

    let sendTask = Task {
        try await session.send(
            ProtocolCommand(domain: .dom, method: "DOM.getDocument", routing: .target(.init("frame-provisional")))
        )
    }
    let sent = try await waitForTargetMessage(backend)
    let innerID = try messageID(sent.message)

    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"frame-provisional","newTargetId":"frame-committed"}}"#)
    await session.receiveTargetMessage(##"{"id":\##(innerID),"result":{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document"}}}"##, targetID: .init("frame-committed"))
    let result = try await sendTask.value

    #expect(result.targetID == ProtocolTargetIdentifier("frame-committed"))
    #expect(await session.snapshot().pendingTargetReplyKeys.isEmpty)
}

@Test
func oldlessTargetCommitInfersSoleProvisionalTarget() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: .seconds(1))
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-provisional","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":true}}}"#)

    let sendTask = Task {
        try await session.send(
            ProtocolCommand(domain: .dom, method: "DOM.getDocument", routing: .target(.init("frame-provisional")))
        )
    }
    let sent = try await waitForTargetMessage(backend)
    let innerID = try messageID(sent.message)

    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"newTargetId":"frame-committed"}}"#)
    await session.receiveTargetMessage(##"{"id":\##(innerID),"result":{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document"}}}"##, targetID: .init("frame-committed"))
    let result = try await sendTask.value
    let snapshot = await session.snapshot()

    #expect(result.targetID == ProtocolTargetIdentifier("frame-committed"))
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("frame-provisional")] == nil)
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("frame-committed")]?.frameID == DOMFrameIdentifier("ad-frame"))
    #expect(snapshot.frameTargetIDsByFrameID[DOMFrameIdentifier("ad-frame")] == ProtocolTargetIdentifier("frame-committed"))
}

@Test
func retargetedPendingReplyStillTimesOutAfterCommit() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: .milliseconds(20))
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-provisional","type":"frame","frameId":"ad-frame","isProvisional":true}}}"#)

    let sendTask = Task {
        try await session.send(
            ProtocolCommand(domain: .dom, method: "DOM.getDocument", routing: .target(.init("frame-provisional")))
        )
    }
    _ = try await waitForTargetMessage(backend)

    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"frame-provisional","newTargetId":"frame-committed"}}"#)

    await #expect(throws: TransportError.replyTimeout(method: "DOM.getDocument", targetID: .init("frame-provisional"))) {
        try await sendTask.value
    }
    #expect(await session.snapshot().pendingTargetReplyKeys.isEmpty)
}

@Test
func ambiguousTargetCommitPreservesExistingMetadataAndDoesNotInventTarget() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-existing","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"newTargetId":"frame-existing"}}"#)
    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"newTargetId":"missing-target"}}"#)
    let snapshot = await session.snapshot()

    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("frame-existing")]?.kind == .frame)
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("frame-existing")]?.frameID == DOMFrameIdentifier("ad-frame"))
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("missing-target")] == nil)
}

@Test
func rootScopedRuntimeAndDOMEventsResolveToCurrentPageTarget() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)
    let runtimeStream = await session.events(for: .runtime)
    let domStream = await session.events(for: .dom)
    let runtimeTask = firstEvent(from: runtimeStream)
    let domTask = firstEvent(from: domStream)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Runtime.executionContextCreated","params":{"context":{"id":11,"frameId":"main-frame"}}}"#)
    await session.receiveRootMessage(#"{"method":"DOM.documentUpdated","params":{}}"#)
    let snapshot = await session.snapshot()

    #expect(snapshot.executionContextsByID[ExecutionContextID(11)]?.targetID == ProtocolTargetIdentifier("page-main"))
    #expect(await runtimeTask.value?.targetID == ProtocolTargetIdentifier("page-main"))
    #expect(await domTask.value?.targetID == ProtocolTargetIdentifier("page-main"))
}

@Test
func rootScopedInspectorEventsRemainTargetless() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)
    let inspectorStream = await session.events(for: .inspector)
    let inspectorTask = firstEvent(from: inspectorStream)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Inspector.inspect","params":{"object":{"type":"object","subtype":"node","objectId":"node-1"}}}"#)

    #expect(await inspectorTask.value?.targetID == nil)
}

@Test
func runtimeExecutionContextMapsToDeliveringTarget() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-A","type":"frame","frameId":"frame-A","isProvisional":false}}}"#)

    await session.receiveTargetMessage(
        #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":7,"frameId":"frame-A"}}}"#,
        targetID: .init("frame-A")
    )
    let snapshot = await session.snapshot()

    #expect(snapshot.executionContextsByID[ExecutionContextID(7)]?.targetID == ProtocolTargetIdentifier("frame-A"))
    #expect(await session.targetIdentifier(forFrameID: .init("frame-A")) == ProtocolTargetIdentifier("frame-A"))
}

@Test
func runtimeContextOnPagePreservesExistingFrameTargetRoute() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-A","type":"frame","frameId":"frame-A","parentFrameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveTargetMessage(
        #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":7,"frameId":"frame-A"}}}"#,
        targetID: .init("page-main")
    )
    let snapshot = await session.snapshot()

    #expect(snapshot.executionContextsByID[ExecutionContextID(7)]?.targetID == ProtocolTargetIdentifier("frame-A"))
    #expect(await session.targetIdentifier(forFrameID: .init("frame-A")) == ProtocolTargetIdentifier("frame-A"))
}

@Test
func domainStreamsReceiveIndependentTargetEventsInOrder() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)
    let domStream = await session.events(for: .dom)
    let cssStream = await session.events(for: .css)
    let consoleStream = await session.events(for: .console)
    let networkStream = await session.events(for: .network)

    let domTask = firstEvent(from: domStream)
    let cssTask = firstEvent(from: cssStream)
    let consoleTask = firstEvent(from: consoleStream)
    let networkTask = firstEvent(from: networkStream)

    await session.receiveTargetMessage(#"{"method":"DOM.setChildNodes","params":{"parentId":1,"nodes":[]}}"#, targetID: .init("frame-A"))
    await session.receiveTargetMessage(#"{"method":"CSS.styleSheetChanged","params":{"styleSheetId":"s1"}}"#, targetID: .init("frame-A"))
    await session.receiveTargetMessage(#"{"method":"Console.messageAdded","params":{"message":{"text":"hello"}}}"#, targetID: .init("frame-A"))
    await session.receiveTargetMessage(#"{"method":"Network.requestWillBeSent","params":{"requestId":"r1","request":{"url":"https://example.com"},"timestamp":1}}"#, targetID: .init("page-main"))

    #expect(await domTask.value?.method == "DOM.setChildNodes")
    #expect(await cssTask.value?.method == "CSS.styleSheetChanged")
    #expect(await consoleTask.value?.method == "Console.messageAdded")
    #expect(await networkTask.value?.method == "Network.requestWillBeSent")
}

@Test
func networkAdapterKeepsEnvelopeTargetAndPayloadTargetSeparate() async throws {
    let network = await NetworkSession()
    let event = ProtocolEventEnvelope(
        sequence: 1,
        domain: .network,
        method: "Network.requestWillBeSent",
        targetID: .init("page-proxy"),
        paramsData: Data(
            #"{"requestId":"request-1","frameId":"ad-frame","loaderId":"loader","documentURL":"https://page.example","request":{"url":"https://ads.example/ad.js"},"targetId":"frame-ad","backendResourceIdentifier":{"sourceProcessID":"web-content-2","resourceID":"resource-1"},"timestamp":1}"#.utf8
        )
    )

    try await NetworkTransportAdapter.applyNetworkEvent(event, to: network)
    let key = NetworkRequestIdentifierKey(targetID: .init("page-proxy"), requestID: .init("request-1"))
    let snapshot = try #require(await network.requestSnapshot(for: key))

    #expect(snapshot.originatingTargetID == ProtocolTargetIdentifier("frame-ad"))
    #expect(snapshot.backendResourceIdentifier == NetworkBackendResourceIdentifier(sourceProcessID: "web-content-2", resourceID: "resource-1"))
}

@Test
func networkAdapterBuildsRedirectChainFromRepeatedRequestWillBeSent() async throws {
    let network = await NetworkSession()
    let targetID = ProtocolTargetIdentifier("page-proxy")
    let first = ProtocolEventEnvelope(
        sequence: 1,
        domain: .network,
        method: "Network.requestWillBeSent",
        targetID: targetID,
        paramsData: Data(
            #"{"requestId":"request-redirect","request":{"url":"http://example.com"},"timestamp":1}"#.utf8
        )
    )
    let redirect = ProtocolEventEnvelope(
        sequence: 2,
        domain: .network,
        method: "Network.requestWillBeSent",
        targetID: targetID,
        paramsData: Data(
            #"{"requestId":"request-redirect","request":{"url":"https://example.com"},"redirectResponse":{"status":302},"timestamp":2}"#.utf8
        )
    )

    try await NetworkTransportAdapter.applyNetworkEvent(first, to: network)
    try await NetworkTransportAdapter.applyNetworkEvent(redirect, to: network)
    let key = NetworkRequestIdentifierKey(targetID: targetID, requestID: .init("request-redirect"))
    let snapshot = try #require(await network.requestSnapshot(for: key))

    #expect(snapshot.request.url == "https://example.com")
    #expect(snapshot.redirects.first?.id == NetworkRedirectHopIdentifier(requestKey: key, redirectIndex: 0))
    #expect(snapshot.redirects.first?.response.url == "http://example.com")
}

@Test
func networkAdapterPreservesInitiatorAndLoadingFinishedMetrics() async throws {
    let network = await NetworkSession()
    let targetID = ProtocolTargetIdentifier("page-proxy")
    let requestID = NetworkRequestIdentifier("request-metrics")

    try await NetworkTransportAdapter.applyNetworkEvent(
        ProtocolEventEnvelope(
            sequence: 1,
            domain: .network,
            method: "Network.requestWillBeSent",
            targetID: targetID,
            paramsData: Data(
                ##"{"requestId":"request-metrics","request":{"url":"https://example.com/app.js"},"timestamp":1,"initiator":{"type":"parser","url":"https://example.com","lineNumber":12,"nodeId":42,"stackTrace":{"callFrames":[{"functionName":"load","url":"https://example.com/app.js","scriptId":"7","lineNumber":3,"columnNumber":9}]}}}"##.utf8
            )
        ),
        to: network
    )
    try await NetworkTransportAdapter.applyNetworkEvent(
        ProtocolEventEnvelope(
            sequence: 2,
            domain: .network,
            method: "Network.responseReceived",
            targetID: targetID,
            paramsData: Data(
                ##"{"requestId":"request-metrics","response":{"status":200,"headers":{"Content-Type":"text/javascript"}},"timestamp":1.5}"##.utf8
            )
        ),
        to: network
    )
    try await NetworkTransportAdapter.applyNetworkEvent(
        ProtocolEventEnvelope(
            sequence: 3,
            domain: .network,
            method: "Network.loadingFinished",
            targetID: targetID,
            paramsData: Data(
                ##"{"requestId":"request-metrics","timestamp":2,"sourceMapURL":"app.js.map","metrics":{"protocol":"h2","priority":"high","connectionIdentifier":"connection-1","remoteAddress":"203.0.113.10","requestHeaders":{"User-Agent":"V2"},"requestHeaderBytesSent":64,"responseHeaderBytesReceived":128,"responseBodyBytesReceived":300,"responseBodyDecodedSize":512,"securityConnection":{"protocol":"TLS 1.3","cipher":"TLS_AES_128_GCM_SHA256"},"isProxyConnection":false}}"##.utf8
            )
        ),
        to: network
    )
    let key = NetworkRequestIdentifierKey(targetID: targetID, requestID: requestID)
    let snapshot = try #require(await network.requestSnapshot(for: key))

    #expect(snapshot.initiator?.type == .parser)
    #expect(snapshot.initiator?.nodeID == DOMProtocolNodeID(42))
    #expect(snapshot.initiator?.stackTrace?.callFrames.first?.functionName == "load")
    #expect(snapshot.response?.url == "https://example.com/app.js")
    #expect(snapshot.sourceMapURL == "app.js.map")
    #expect(snapshot.metrics?.networkProtocol == "h2")
    #expect(snapshot.metrics?.responseHeaderBytesReceived == 128)
    #expect(snapshot.metrics?.securityConnection?.protocolName == "TLS 1.3")
    #expect(snapshot.encodedDataLength == 300)
    #expect(snapshot.decodedDataLength == 512)
    #expect(snapshot.response?.security?.connection?.protocolName == "TLS 1.3")
}

@Test
func networkAdapterHandlesWebSocketLifecycleEvents() async throws {
    let network = await NetworkSession()
    let targetID = ProtocolTargetIdentifier("page-proxy")
    let requestID = NetworkRequestIdentifier("ws.1")

    for event in [
        ProtocolEventEnvelope(sequence: 1, domain: .network, method: "Network.webSocketCreated", targetID: targetID, paramsData: Data(#"{"requestId":"ws.1","url":"wss://example.com/socket"}"#.utf8)),
        ProtocolEventEnvelope(sequence: 2, domain: .network, method: "Network.webSocketWillSendHandshakeRequest", targetID: targetID, paramsData: Data(#"{"requestId":"ws.1","timestamp":1,"request":{"headers":{"Upgrade":"websocket"}}}"#.utf8)),
        ProtocolEventEnvelope(sequence: 3, domain: .network, method: "Network.webSocketHandshakeResponseReceived", targetID: targetID, paramsData: Data(#"{"requestId":"ws.1","timestamp":2,"response":{"status":101,"statusText":"Switching Protocols","headers":{"Upgrade":"websocket"}}}"#.utf8)),
        ProtocolEventEnvelope(sequence: 4, domain: .network, method: "Network.webSocketFrameSent", targetID: targetID, paramsData: Data(#"{"requestId":"ws.1","timestamp":3,"response":{"opcode":1,"mask":true,"payloadData":"hello","payloadLength":5}}"#.utf8)),
        ProtocolEventEnvelope(sequence: 5, domain: .network, method: "Network.webSocketFrameReceived", targetID: targetID, paramsData: Data(#"{"requestId":"ws.1","timestamp":4,"response":{"opcode":1,"mask":false,"payloadData":"world","payloadLength":5}}"#.utf8)),
        ProtocolEventEnvelope(sequence: 6, domain: .network, method: "Network.webSocketFrameError", targetID: targetID, paramsData: Data(#"{"requestId":"ws.1","timestamp":4.5,"errorMessage":"bad frame"}"#.utf8)),
        ProtocolEventEnvelope(sequence: 7, domain: .network, method: "Network.webSocketClosed", targetID: targetID, paramsData: Data(#"{"requestId":"ws.1","timestamp":5}"#.utf8)),
    ] {
        try await NetworkTransportAdapter.applyNetworkEvent(event, to: network)
    }
    let key = NetworkRequestIdentifierKey(targetID: targetID, requestID: requestID)
    let snapshot = try #require(await network.requestSnapshot(for: key))

    #expect(snapshot.webSocketHandshakeRequest?.headers["Upgrade"] == "websocket")
    #expect(snapshot.webSocketHandshakeResponse?.status == 101)
    #expect(snapshot.webSocketFrames.count == 3)
    #expect(snapshot.webSocketFrames[2].direction == .error("bad frame"))
    #expect(snapshot.webSocketReadyState == .closed)
    #expect(snapshot.state == .finished)
}

@Test
func domAdapterCompletesInspectSelectionThroughRequestNodeResult() async throws {
    let dom = await DOMSession()
    try await DOMTransportAdapter.applyTargetEvent(
        ProtocolEventEnvelope(
            sequence: 1,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("frame-A"),
            paramsData: Data(#"{"targetInfo":{"targetId":"frame-A","type":"frame","frameId":"frame-A","isProvisional":false}}"#.utf8)
        ),
        to: dom
    )
    try await DOMTransportAdapter.applyGetDocumentResult(
        ProtocolCommandResult(
            domain: .dom,
            method: "DOM.getDocument",
            targetID: .init("frame-A"),
            resultData: Data(##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","children":[{"nodeId":2,"nodeType":1,"nodeName":"DIV","localName":"div"}]}}"##.utf8)
        ),
        to: dom
    )
    try await DOMTransportAdapter.applyRuntimeEvent(
        ProtocolEventEnvelope(
            sequence: 2,
            domain: .runtime,
            method: "Runtime.executionContextCreated",
            targetID: .init("frame-A"),
            paramsData: Data(#"{"context":{"id":9,"frameId":"frame-A"}}"#.utf8)
        ),
        to: dom
    )
    let intent = await dom.resolveInspectSelection(remoteObject: .init(objectID: "node-object", injectedScriptID: .init(9)))
    guard case let .success(.requestNode(selectionRequestID, targetID, _)) = intent else {
        Issue.record("Expected DOM.requestNode intent")
        return
    }

    let result = try await DOMTransportAdapter.applyRequestNodeResult(
        ProtocolCommandResult(
            domain: .dom,
            method: "DOM.requestNode",
            targetID: targetID,
            resultData: Data(#"{"nodeId":2}"#.utf8)
        ),
        selectionRequestID: selectionRequestID,
        to: dom
    )
    guard case let .success(selectedNodeID) = result else {
        Issue.record("Expected selected node")
        return
    }

    #expect(selectedNodeID.nodeID == DOMProtocolNodeID(2))
    #expect(await dom.elementDetailSnapshot()?.nodeName == "DIV")
}

@Test
func domAdapterFrameDocumentRefreshOnlyUpdatesFrameTargetDocument() async throws {
    let dom = await DOMSession()
    try await DOMTransportAdapter.applyTargetEvent(
        ProtocolEventEnvelope(
            sequence: 1,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("page-main"),
            paramsData: Data(#"{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}"#.utf8)
        ),
        to: dom
    )
    try await DOMTransportAdapter.applyTargetEvent(
        ProtocolEventEnvelope(
            sequence: 2,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("frame-ad"),
            paramsData: Data(#"{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}"#.utf8)
        ),
        to: dom
    )
    try await DOMTransportAdapter.applyGetDocumentResult(
        ProtocolCommandResult(
            domain: .dom,
            method: "DOM.getDocument",
            targetID: .init("page-main"),
            resultData: Data(##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","children":[{"nodeId":2,"nodeType":1,"nodeName":"IFRAME","localName":"iframe","frameId":"ad-frame"}]}}"##.utf8)
        ),
        to: dom
    )
    let firstFrameRoot = try #require(
        await DOMTransportAdapter.applyGetDocumentResult(
        ProtocolCommandResult(
            domain: .dom,
            method: "DOM.getDocument",
            targetID: .init("frame-ad"),
            resultData: Data(##"{"root":{"nodeId":10,"nodeType":9,"nodeName":"#document","children":[{"nodeId":11,"nodeType":1,"nodeName":"HTML","localName":"html"}]}}"##.utf8)
        ),
        to: dom
        )
    )
    let before = await dom.snapshot()
    let pageDocumentID = try #require(before.targetsByID[ProtocolTargetIdentifier("page-main")]?.currentDocumentID)
    let frameDocumentID = try #require(before.targetsByID[ProtocolTargetIdentifier("frame-ad")]?.currentDocumentID)

    let secondFrameRoot = try #require(
        await DOMTransportAdapter.applyGetDocumentResult(
        ProtocolCommandResult(
            domain: .dom,
            method: "DOM.getDocument",
            targetID: .init("frame-ad"),
            resultData: Data(##"{"root":{"nodeId":20,"nodeType":9,"nodeName":"#document","children":[{"nodeId":21,"nodeType":1,"nodeName":"HTML","localName":"html"}]}}"##.utf8)
        ),
        to: dom
        )
    )
    let after = await dom.snapshot()

    #expect(firstFrameRoot != secondFrameRoot)
    #expect(after.targetsByID[ProtocolTargetIdentifier("page-main")]?.currentDocumentID == pageDocumentID)
    #expect(after.targetsByID[ProtocolTargetIdentifier("frame-ad")]?.currentDocumentID != frameDocumentID)
    #expect(after.nodesByID[firstFrameRoot]?.nodeName == nil)
}

@Test
func domAdapterAmbiguousTargetCommitDoesNotOverwriteExistingTargetMetadata() async throws {
    let dom = await DOMSession()
    try await DOMTransportAdapter.applyTargetEvent(
        ProtocolEventEnvelope(
            sequence: 1,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("frame-ad"),
            paramsData: Data(#"{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}"#.utf8)
        ),
        to: dom
    )

    try await DOMTransportAdapter.applyTargetEvent(
        ProtocolEventEnvelope(
            sequence: 2,
            domain: .target,
            method: "Target.didCommitProvisionalTarget",
            targetID: .init("frame-ad"),
            paramsData: Data(#"{"newTargetId":"frame-ad"}"#.utf8)
        ),
        to: dom
    )
    let snapshot = await dom.snapshot()

    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("frame-ad")]?.kind == .frame)
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("frame-ad")]?.frameID == DOMFrameIdentifier("ad-frame"))
    #expect(snapshot.currentPage == nil)
}

@Test
func domAdapterPageTargetWithParentFrameIsClassifiedAsFrame() async throws {
    let dom = await DOMSession()
    try await DOMTransportAdapter.applyTargetEvent(
        ProtocolEventEnvelope(
            sequence: 1,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("iframe-page"),
            paramsData: Data(#"{"targetInfo":{"targetId":"iframe-page","type":"page","frameId":"child-frame","parentFrameId":"main-frame","isProvisional":false}}"#.utf8)
        ),
        to: dom
    )
    let snapshot = await dom.snapshot()

    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("iframe-page")]?.kind == .frame)
    #expect(snapshot.currentPage == nil)
    #expect(snapshot.framesByID[DOMFrameIdentifier("child-frame")]?.targetID == ProtocolTargetIdentifier("iframe-page"))
}

@Test
func domAdapterPageTargetWithKnownNonMainFrameIsClassifiedAsFrame() async throws {
    let dom = await DOMSession()
    try await DOMTransportAdapter.applyTargetEvent(
        ProtocolEventEnvelope(
            sequence: 1,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("page-main"),
            paramsData: Data(#"{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}"#.utf8)
        ),
        to: dom
    )
    try await DOMTransportAdapter.applyTargetEvent(
        ProtocolEventEnvelope(
            sequence: 2,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("iframe-page"),
            paramsData: Data(#"{"targetInfo":{"targetId":"iframe-page","type":"page","frameId":"child-frame","isProvisional":false}}"#.utf8)
        ),
        to: dom
    )
    let snapshot = await dom.snapshot()

    #expect(snapshot.currentPage?.mainTargetID == ProtocolTargetIdentifier("page-main"))
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("iframe-page")]?.kind == .frame)
    #expect(snapshot.framesByID[DOMFrameIdentifier("child-frame")]?.targetID == ProtocolTargetIdentifier("iframe-page"))
}

@Test
func domAdapterPageTargetWithoutFrameIDCanCommitAsCurrentPage() async throws {
    let dom = await DOMSession()
    try await DOMTransportAdapter.applyTargetEvent(
        ProtocolEventEnvelope(
            sequence: 1,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("page-old"),
            paramsData: Data(#"{"targetInfo":{"targetId":"page-old","type":"page","frameId":"main-frame","isProvisional":false}}"#.utf8)
        ),
        to: dom
    )
    try await DOMTransportAdapter.applyTargetEvent(
        ProtocolEventEnvelope(
            sequence: 2,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("page-new"),
            paramsData: Data(#"{"targetInfo":{"targetId":"page-new","type":"page","isProvisional":true}}"#.utf8)
        ),
        to: dom
    )
    try await DOMTransportAdapter.applyTargetEvent(
        ProtocolEventEnvelope(
            sequence: 3,
            domain: .target,
            method: "Target.didCommitProvisionalTarget",
            targetID: .init("page-new"),
            paramsData: Data(#"{"oldTargetId":"page-old","newTargetId":"page-new"}"#.utf8)
        ),
        to: dom
    )
    let snapshot = await dom.snapshot()

    #expect(snapshot.currentPage?.mainTargetID == ProtocolTargetIdentifier("page-new"))
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("page-new")]?.kind == .page)
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("page-new")]?.isProvisional == false)
}

@Test
func domAdapterCommittedTopLevelProvisionalPageBecomesCurrentPage() async throws {
    let dom = await DOMSession()
    try await DOMTransportAdapter.applyTargetEvent(
        ProtocolEventEnvelope(
            sequence: 1,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("page-old"),
            paramsData: Data(#"{"targetInfo":{"targetId":"page-old","type":"page","frameId":"main-frame","isProvisional":false}}"#.utf8)
        ),
        to: dom
    )

    try await DOMTransportAdapter.applyTargetEvent(
        ProtocolEventEnvelope(
            sequence: 2,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("page-main"),
            paramsData: Data(#"{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":true}}"#.utf8)
        ),
        to: dom
    )
    #expect(await dom.snapshot().currentPage?.mainTargetID == ProtocolTargetIdentifier("page-old"))

    try await DOMTransportAdapter.applyTargetEvent(
        ProtocolEventEnvelope(
            sequence: 3,
            domain: .target,
            method: "Target.didCommitProvisionalTarget",
            targetID: .init("page-main"),
            paramsData: Data(#"{"oldTargetId":"page-old","newTargetId":"page-main"}"#.utf8)
        ),
        to: dom
    )
    let snapshot = await dom.snapshot()

    #expect(snapshot.currentPage?.mainTargetID == ProtocolTargetIdentifier("page-main"))
    #expect(snapshot.currentPage?.mainFrameID == DOMFrameIdentifier("main-frame"))
}

@Test
func domAdapterOldlessCommittedProvisionalPageWithoutMainContextStaysFrameScoped() async throws {
    let dom = await DOMSession()
    try await DOMTransportAdapter.applyTargetEvent(
        ProtocolEventEnvelope(
            sequence: 1,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("page-main"),
            paramsData: Data(#"{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":true}}"#.utf8)
        ),
        to: dom
    )
    #expect(await dom.snapshot().currentPage == nil)

    try await DOMTransportAdapter.applyTargetEvent(
        ProtocolEventEnvelope(
            sequence: 2,
            domain: .target,
            method: "Target.didCommitProvisionalTarget",
            targetID: .init("page-main"),
            paramsData: Data(#"{"newTargetId":"page-main"}"#.utf8)
        ),
        to: dom
    )
    let snapshot = await dom.snapshot()

    #expect(snapshot.currentPage == nil)
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("page-main")]?.kind == .frame)
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("page-main")]?.isProvisional == false)
}

@Test
func domAdapterOldlessCommitInfersSoleProvisionalFrameTarget() async throws {
    let dom = await DOMSession()
    try await DOMTransportAdapter.applyTargetEvent(
        ProtocolEventEnvelope(
            sequence: 1,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("page-provisional"),
            paramsData: Data(#"{"targetInfo":{"targetId":"page-provisional","type":"page","frameId":"main-frame","isProvisional":true}}"#.utf8)
        ),
        to: dom
    )

    try await DOMTransportAdapter.applyTargetEvent(
        ProtocolEventEnvelope(
            sequence: 2,
            domain: .target,
            method: "Target.didCommitProvisionalTarget",
            targetID: .init("page-main"),
            paramsData: Data(#"{"newTargetId":"page-main"}"#.utf8)
        ),
        to: dom
    )
    let snapshot = await dom.snapshot()

    #expect(snapshot.currentPage == nil)
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("page-provisional")] == nil)
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("page-main")]?.kind == .frame)
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("page-main")]?.frameID == DOMFrameIdentifier("main-frame"))
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("page-main")]?.isProvisional == false)
}

@Test
func domAdapterCommittedSecondaryPageDoesNotReplaceCurrentPage() async throws {
    let dom = await DOMSession()
    try await DOMTransportAdapter.applyTargetEvent(
        ProtocolEventEnvelope(
            sequence: 1,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("page-main"),
            paramsData: Data(#"{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}"#.utf8)
        ),
        to: dom
    )
    try await DOMTransportAdapter.applyTargetEvent(
        ProtocolEventEnvelope(
            sequence: 2,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("page-popup-provisional"),
            paramsData: Data(#"{"targetInfo":{"targetId":"page-popup-provisional","type":"page","frameId":"popup-frame","isProvisional":true}}"#.utf8)
        ),
        to: dom
    )

    try await DOMTransportAdapter.applyTargetEvent(
        ProtocolEventEnvelope(
            sequence: 3,
            domain: .target,
            method: "Target.didCommitProvisionalTarget",
            targetID: .init("page-popup"),
            paramsData: Data(#"{"oldTargetId":"page-popup-provisional","newTargetId":"page-popup"}"#.utf8)
        ),
        to: dom
    )
    let snapshot = await dom.snapshot()

    #expect(snapshot.currentPage?.mainTargetID == ProtocolTargetIdentifier("page-main"))
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("page-popup")]?.frameID == DOMFrameIdentifier("popup-frame"))
}

@Test
func domAdapterSubframeCommitDoesNotConsumeCurrentMainPage() async throws {
    let dom = await DOMSession()
    try await DOMTransportAdapter.applyTargetEvent(
        ProtocolEventEnvelope(
            sequence: 1,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("page-main"),
            paramsData: Data(#"{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}"#.utf8)
        ),
        to: dom
    )
    try await DOMTransportAdapter.applyTargetEvent(
        ProtocolEventEnvelope(
            sequence: 2,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("frame-committed"),
            paramsData: Data(#"{"targetInfo":{"targetId":"frame-committed","type":"frame","frameId":"child-frame","parentFrameId":"main-frame","isProvisional":true}}"#.utf8)
        ),
        to: dom
    )

    try await DOMTransportAdapter.applyTargetEvent(
        ProtocolEventEnvelope(
            sequence: 3,
            domain: .target,
            method: "Target.didCommitProvisionalTarget",
            targetID: .init("frame-committed"),
            paramsData: Data(#"{"oldTargetId":"page-main","newTargetId":"frame-committed"}"#.utf8)
        ),
        to: dom
    )
    let snapshot = await dom.snapshot()

    #expect(snapshot.currentPage?.mainTargetID == ProtocolTargetIdentifier("page-main"))
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("page-main")]?.kind == .page)
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("frame-committed")]?.isProvisional == false)
}

@Test
func networkCommandIntentRoutesThroughOctopusPageTarget() throws {
    let requestKey = NetworkRequestIdentifierKey(
        targetID: .init("page-proxy"),
        requestID: .init("request-1")
    )
    let command = try NetworkTransportAdapter.command(
        for: .getResponseBody(requestKey: requestKey, backendResourceIdentifier: nil)
    )

    #expect(command.method == "Network.getResponseBody")
    #expect(command.routing == .octopus(pageTarget: .init("page-proxy")))
    #expect(String(data: command.parametersData, encoding: .utf8)?.contains(#""requestId":"request-1""#) == true)
}

private func firstEvent(from stream: AsyncStream<ProtocolEventEnvelope>) -> Task<ProtocolEventEnvelope?, Never> {
    Task {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
}

private func waitForRootMessage(_ backend: FakeTransportBackend) async throws -> String {
    try await waitUntil {
        await backend.sentRootMessages().last
    }
}

private func waitForTargetMessage(_ backend: FakeTransportBackend) async throws -> SentTargetMessage {
    try await waitUntil {
        await backend.sentTargetMessages().last
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
