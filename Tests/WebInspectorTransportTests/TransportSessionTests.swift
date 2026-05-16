import Foundation
import Testing
@testable import WebInspectorCore
@testable import WebInspectorTransport

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
    let rawWrapper = try #require(await backend.sentMessages().last)

    #expect(try messageMethod(rawWrapper) == "Target.sendMessageToTarget")
    #expect(sent.targetIdentifier == ProtocolTargetIdentifier("frame-A"))
    await receiveTargetDispatch(
        session,
        targetID: .init("frame-A"),
        message: ##"{"id":\##(innerID),"result":{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document"}}}"##
    )
    let result = try await sendTask.value

    #expect(result.method == "DOM.getDocument")
    #expect(result.targetID == ProtocolTargetIdentifier("frame-A"))
}

@Test
func targetScopedCompatibilityCommandsResolveWithoutBackendSend() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: .seconds(1))
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)

    let domResult = try await session.send(
        ProtocolCommand(domain: .dom, method: "DOM.enable", routing: .target(.init("page-main")))
    )
    let cssResult = try await session.send(
        ProtocolCommand(domain: .css, method: "CSS.enable", routing: .octopus(pageTarget: .init("page-main")))
    )

    #expect(domResult.targetID == ProtocolTargetIdentifier("page-main"))
    #expect(cssResult.targetID == ProtocolTargetIdentifier("page-main"))
    #expect(String(data: domResult.resultData, encoding: .utf8) == "{}")
    #expect(String(data: cssResult.resultData, encoding: .utf8) == "{}")
    #expect(await backend.sentMessages().isEmpty)
}

@Test
func targetReplyCarriesPerDomainSequenceWatermarks() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: .seconds(1))
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)

    let sendTask = Task {
        try await session.send(
            ProtocolCommand(domain: .dom, method: "DOM.requestNode", routing: .target(.init("page-main")))
        )
    }
    let sent = try await waitForTargetMessage(backend)
    let innerID = try messageID(sent.message)

    await receiveTargetDispatch(
        session,
        targetID: .init("page-main"),
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":2,"nodes":[{"nodeId":3,"nodeType":1,"nodeName":"DIV"}]}}"#
    )
    await receiveTargetDispatch(
        session,
        targetID: .init("page-main"),
        message: #"{"method":"Network.requestWillBeSent","params":{"requestId":"request-1","request":{"url":"https://example.com/"},"timestamp":1}}"#
    )
    await receiveTargetDispatch(
        session,
        targetID: .init("page-main"),
        message: #"{"id":\#(innerID),"result":{"nodeId":3}}"#
    )
    let result = try await sendTask.value

    #expect(result.receivedSequence > result.receivedSequence(for: .dom))
    #expect(result.receivedSequence(for: .network) == result.receivedSequence)
    #expect(result.receivedSequence(for: .dom) > 0)
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
func waitForCurrentMainPageTargetFailsAfterDetach() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: .seconds(1))
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)

    let target = try await session.waitForCurrentMainPageTarget()
    #expect(target.targetID == ProtocolTargetIdentifier("page-main"))

    await session.detach()

    await #expect(throws: TransportError.transportClosed) {
        try await session.waitForCurrentMainPageTarget()
    }
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
    await receiveTargetDispatch(
        session,
        targetID: .init("frame-committed"),
        message: ##"{"id":\##(innerID),"result":{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document"}}}"##
    )
    let result = try await sendTask.value

    #expect(result.targetID == ProtocolTargetIdentifier("frame-committed"))
    #expect(await session.snapshot().pendingTargetReplyKeys.isEmpty)
}

@Test
func provisionalTargetReplyResolvesBeforeBufferedEvents() async throws {
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

    await receiveTargetDispatch(
        session,
        targetID: .init("frame-provisional"),
        message: ##"{"id":\##(innerID),"result":{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document"}}}"##
    )
    let result = try await sendTask.value

    #expect(result.targetID == ProtocolTargetIdentifier("frame-provisional"))
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
    await receiveTargetDispatch(
        session,
        targetID: .init("frame-committed"),
        message: ##"{"id":\##(innerID),"result":{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document"}}}"##
    )
    let result = try await sendTask.value
    let snapshot = await session.snapshot()

    #expect(result.targetID == ProtocolTargetIdentifier("frame-committed"))
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("frame-provisional")] == nil)
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("frame-committed")]?.frameID == DOMFrameIdentifier("ad-frame"))
    #expect(snapshot.frameTargetIDsByFrameID[DOMFrameIdentifier("ad-frame")] == ProtocolTargetIdentifier("frame-committed"))
}

@Test
func provisionalTargetMessagesAreDispatchedAfterCommitTargetEvent() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: .seconds(1))

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-next","type":"page","frameId":"main-frame","isProvisional":true}}}"#)

    let targetStream = await session.events(for: .target)
    let domStream = await session.events(for: .dom)
    let targetTask = firstEvent(from: targetStream)
    let domTask = firstEvent(from: domStream)

    await receiveTargetDispatch(
        session,
        targetID: .init("page-next"),
        message: #"{"method":"DOM.childNodeCountUpdated","params":{"nodeId":3,"childNodeCount":0}}"#
    )
    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"page-next"}}"#)

    let targetEvent = try #require(await targetTask.value)
    let domEvent = try #require(await domTask.value)

    #expect(targetEvent.method == "Target.didCommitProvisionalTarget")
    #expect(domEvent.method == "DOM.childNodeCountUpdated")
    #expect(domEvent.targetID == ProtocolTargetIdentifier("page-next"))
    #expect(domEvent.sequence > targetEvent.sequence)
    #expect(domEvent.receivedSequence(for: .target) == targetEvent.sequence)
}

@Test
func oldProvisionalTargetMessagesAreDispatchedAfterCommitTargetEvent() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: .seconds(1))

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-provisional","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":true}}}"#)

    let targetStream = await session.events(for: .target)
    let domStream = await session.events(for: .dom)
    let targetTask = firstEvent(from: targetStream)
    let domTask = firstEvent(from: domStream)

    await receiveTargetDispatch(
        session,
        targetID: .init("frame-provisional"),
        message: #"{"method":"DOM.childNodeCountUpdated","params":{"nodeId":3,"childNodeCount":1}}"#
    )
    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"frame-provisional","newTargetId":"frame-committed"}}"#)

    let targetEvent = try #require(await targetTask.value)
    let domEvent = try #require(await domTask.value)

    #expect(targetEvent.method == "Target.didCommitProvisionalTarget")
    #expect(domEvent.method == "DOM.childNodeCountUpdated")
    #expect(domEvent.targetID == ProtocolTargetIdentifier("frame-committed"))
    #expect(domEvent.sequence > targetEvent.sequence)
    #expect(domEvent.receivedSequence(for: .target) == targetEvent.sequence)
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
func rootScopedRuntimeAndDOMMutationEventsResolveToCurrentPageTarget() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)
    let runtimeStream = await session.events(for: .runtime)
    let domStream = await session.events(for: .dom)
    let runtimeTask = firstEvent(from: runtimeStream)
    let domTask = firstEvent(from: domStream)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Runtime.executionContextCreated","params":{"context":{"id":11,"frameId":"main-frame"}}}"#)
    await session.receiveRootMessage(#"{"method":"DOM.childNodeCountUpdated","params":{"nodeId":1,"childNodeCount":2}}"#)
    let snapshot = await session.snapshot()

    #expect(snapshot.executionContextsByID[ExecutionContextID(11)]?.targetID == ProtocolTargetIdentifier("page-main"))
    #expect(await runtimeTask.value?.targetID == ProtocolTargetIdentifier("page-main"))
    #expect(await domTask.value?.targetID == ProtocolTargetIdentifier("page-main"))
}

@Test
func rootScopedDocumentUpdatedRemainsTargetless() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)
    let domStream = await session.events(for: .dom)
    let domTask = firstEvent(from: domStream)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"DOM.documentUpdated","params":{}}"#)

    #expect(await domTask.value?.targetID == nil)
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

    await receiveTargetDispatch(
        session,
        targetID: .init("frame-A"),
        message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":7,"frameId":"frame-A"}}}"#
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
    await receiveTargetDispatch(
        session,
        targetID: .init("page-main"),
        message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":7,"frameId":"frame-A"}}}"#
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

    await receiveTargetDispatch(session, targetID: .init("frame-A"), message: #"{"method":"DOM.setChildNodes","params":{"parentId":1,"nodes":[]}}"#)
    await receiveTargetDispatch(session, targetID: .init("frame-A"), message: #"{"method":"CSS.styleSheetChanged","params":{"styleSheetId":"s1"}}"#)
    await receiveTargetDispatch(session, targetID: .init("frame-A"), message: #"{"method":"Console.messageAdded","params":{"message":{"text":"hello"}}}"#)
    await receiveTargetDispatch(session, targetID: .init("page-main"), message: #"{"method":"Network.requestWillBeSent","params":{"requestId":"r1","request":{"url":"https://example.com"},"timestamp":1}}"#)

    #expect(await domTask.value?.method == "DOM.setChildNodes")
    #expect(await cssTask.value?.method == "CSS.styleSheetChanged")
    #expect(await consoleTask.value?.method == "Console.messageAdded")
    #expect(await networkTask.value?.method == "Network.requestWillBeSent")
}

@Test
func orderedStreamReceivesTargetEventsAcrossDomainsInTransportOrder() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)
    let stream = await session.orderedEvents()
    let eventsTask = firstEvents(4, from: stream)

    await receiveTargetDispatch(session, targetID: .init("page-main"), message: #"{"method":"DOM.documentUpdated","params":{}}"#)
    await receiveTargetDispatch(session, targetID: .init("page-main"), message: #"{"method":"Network.requestWillBeSent","params":{"requestId":"r1","request":{"url":"https://example.com"},"timestamp":1}}"#)
    await receiveTargetDispatch(session, targetID: .init("page-main"), message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":7}}}"#)
    await receiveTargetDispatch(session, targetID: .init("page-main"), message: #"{"method":"DOM.childNodeCountUpdated","params":{"nodeId":3,"childNodeCount":2}}"#)

    let events = await eventsTask.value
    #expect(events.map(\.method) == [
        "DOM.documentUpdated",
        "Network.requestWillBeSent",
        "Runtime.executionContextCreated",
        "DOM.childNodeCountUpdated",
    ])
    #expect(events.map(\.sequence) == [1, 2, 3, 4])
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
                ##"{"requestId":"request-metrics","timestamp":2,"sourceMapURL":"app.js.map","metrics":{"protocol":"h2","priority":"high","connectionIdentifier":"connection-1","remoteAddress":"203.0.113.10","requestHeaders":{"User-Agent":"WebInspector"},"requestHeaderBytesSent":64,"responseHeaderBytesReceived":128,"responseBodyBytesReceived":300,"responseBodyDecodedSize":512,"securityConnection":{"protocol":"TLS 1.3","cipher":"TLS_AES_128_GCM_SHA256"},"isProxyConnection":false}}"##.utf8
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
    let intent = await dom.beginInspectSelectionRequest(targetID: .init("frame-A"), objectID: "node-object")
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
    guard case let .resolved(selectedNodeID) = result else {
        Issue.record("Expected selected node")
        return
    }

    #expect(selectedNodeID.nodeID == DOMProtocolNodeID(2))
    let selectedNodeName = await dom.selectedNode?.nodeName
    #expect(selectedNodeName == "DIV")
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
    #expect(snapshot.currentPageTargetID == nil)
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
    #expect(snapshot.currentPageTargetID == nil)
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

    #expect(snapshot.currentPageTargetID == ProtocolTargetIdentifier("page-main"))
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

    #expect(snapshot.currentPageTargetID == ProtocolTargetIdentifier("page-new"))
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
    #expect(await dom.snapshot().currentPageTargetID == ProtocolTargetIdentifier("page-old"))

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

    #expect(snapshot.currentPageTargetID == ProtocolTargetIdentifier("page-main"))
    #expect(snapshot.mainFrameID == DOMFrameIdentifier("main-frame"))
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
    #expect(await dom.snapshot().currentPageTargetID == nil)

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

    #expect(snapshot.currentPageTargetID == nil)
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

    #expect(snapshot.currentPageTargetID == nil)
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

    #expect(snapshot.currentPageTargetID == ProtocolTargetIdentifier("page-main"))
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

    #expect(snapshot.currentPageTargetID == ProtocolTargetIdentifier("page-main"))
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("page-main")]?.kind == .page)
    #expect(snapshot.targetsByID[ProtocolTargetIdentifier("frame-committed")]?.isProvisional == false)
}

@Test
func networkCommandIntentRoutesThroughCurrentPageOctopusTarget() throws {
    let requestKey = NetworkRequestIdentifierKey(
        targetID: .init("frame-ad"),
        requestID: .init("request-1")
    )
    let bodyCommand = try NetworkTransportAdapter.command(
        for: .getResponseBody(requestKey: requestKey, backendResourceIdentifier: nil)
    )
    let certificateCommand = try NetworkTransportAdapter.command(
        for: .getSerializedCertificate(requestKey: requestKey, backendResourceIdentifier: nil)
    )

    #expect(bodyCommand.method == "Network.getResponseBody")
    #expect(bodyCommand.routing == .octopus(pageTarget: nil))
    #expect(certificateCommand.method == "Network.getSerializedCertificate")
    #expect(certificateCommand.routing == .octopus(pageTarget: nil))
    #expect(String(data: bodyCommand.parametersData, encoding: .utf8)?.contains(#""requestId":"request-1""#) == true)
}

@Test
func domHighlightCommandUsesNonRevealingVisibleHighlightConfig() throws {
    let command = try DOMTransportAdapter.command(
        for: .highlightNode(
            identity: .init(
                documentTargetID: .init("page-A"),
                rawNodeID: .init(42),
                commandTargetID: .init("page-A"),
                commandNodeID: .protocolNode(.init(42))
            )
        )
    )
    let parameters = try jsonObject(from: command.parametersData)

    #expect(command.method == "DOM.highlightNode")
    #expect(command.routing == .target(.init("page-A")))
    #expect(integerValue(parameters["nodeId"]) == 42)
    #expect(parameters["reveal"] as? Bool == false)
    #expect(hasVisibleHighlightConfig(parameters["highlightConfig"] as? [String: Any]) == true)
}

@Test
func domNavigationActionCommandsUseExpectedProtocolPayloads() throws {
    let targetID = ProtocolTargetIdentifier("page-A")

    let enablePicker = try DOMTransportAdapter.command(
        for: .setInspectModeEnabled(targetID: targetID, enabled: true)
    )
    let enableParameters = try jsonObject(from: enablePicker.parametersData)
    #expect(enablePicker.method == "DOM.setInspectModeEnabled")
    #expect(enablePicker.routing == .target(targetID))
    #expect(enableParameters["enabled"] as? Bool == true)
    #expect(hasVisibleHighlightConfig(enableParameters["highlightConfig"] as? [String: Any]) == true)

    let disablePicker = try DOMTransportAdapter.command(
        for: .setInspectModeEnabled(targetID: targetID, enabled: false)
    )
    let disableParameters = try jsonObject(from: disablePicker.parametersData)
    #expect(disablePicker.method == "DOM.setInspectModeEnabled")
    #expect(disableParameters["enabled"] as? Bool == false)
    #expect(disableParameters["highlightConfig"] == nil)

    let identity = DOMActionIdentity(
        documentTargetID: targetID,
        rawNodeID: .init(42),
        commandTargetID: targetID,
        commandNodeID: .protocolNode(.init(42))
    )

    let outerHTML = try DOMTransportAdapter.command(for: .getOuterHTML(identity: identity))
    #expect(outerHTML.method == "DOM.getOuterHTML")
    #expect(integerValue(try jsonObject(from: outerHTML.parametersData)["nodeId"]) == 42)

    let removeNode = try DOMTransportAdapter.command(for: .removeNode(identity: identity))
    #expect(removeNode.method == "DOM.removeNode")
    #expect(integerValue(try jsonObject(from: removeNode.parametersData)["nodeId"]) == 42)

    #expect(try DOMTransportAdapter.command(for: .undo(targetID: targetID)).method == "DOM.undo")
    #expect(try DOMTransportAdapter.command(for: .redo(targetID: targetID)).method == "DOM.redo")
}

@Test
func domActionCommandsEncodeScopedCommandNodeIDs() throws {
    let identity = DOMActionIdentity(
        documentTargetID: .init("frame-A"),
        rawNodeID: .init(42),
        commandTargetID: .init("page-main"),
        commandNodeID: .scoped(targetID: .init("frame-A"), nodeID: .init(42))
    )

    let outerHTML = try DOMTransportAdapter.command(for: .getOuterHTML(identity: identity))
    let outerHTMLParameters = try jsonObject(from: outerHTML.parametersData)
    #expect(outerHTML.routing == .target(.init("page-main")))
    #expect(outerHTMLParameters["nodeId"] as? String == "frame-A:42")

    let removeNode = try DOMTransportAdapter.command(for: .removeNode(identity: identity))
    let removeNodeParameters = try jsonObject(from: removeNode.parametersData)
    #expect(removeNode.routing == .target(.init("page-main")))
    #expect(removeNodeParameters["nodeId"] as? String == "frame-A:42")
}

@Test
func domAdapterDecodesOuterHTMLResultAndInspectEvents() throws {
    let html = try DOMTransportAdapter.outerHTML(
        from: ProtocolCommandResult(
            domain: .dom,
            method: "DOM.getOuterHTML",
            targetID: .init("page-A"),
            resultData: Data(#"{"outerHTML":"<main></main>"}"#.utf8)
        )
    )
    #expect(html == "<main></main>")

    let domInspect = try DOMTransportAdapter.inspectEvent(
        from: ProtocolEventEnvelope(
            sequence: 1,
            domain: .dom,
            method: "DOM.inspect",
            targetID: .init("page-A"),
            paramsData: Data(#"{"nodeId":42}"#.utf8)
        )
    )
    #expect(domInspect == .protocolNode(targetID: .init("page-A"), nodeID: .init(42)))

    let inspectorInspect = try DOMTransportAdapter.inspectEvent(
        from: ProtocolEventEnvelope(
            sequence: 2,
            domain: .inspector,
            method: "Inspector.inspect",
            targetID: nil,
            paramsData: Data(#"{"object":{"objectId":"{\"injectedScriptId\":7,\"id\":99}"},"hints":{}}"#.utf8)
        )
    )
    #expect(inspectorInspect == .remoteObject(
        targetID: nil,
        remoteObject: .init(objectID: #"{"injectedScriptId":7,"id":99}"#, injectedScriptID: .init(7))
    ))

    let targetScopedInspectorInspect = try DOMTransportAdapter.inspectEvent(
        from: ProtocolEventEnvelope(
            sequence: 3,
            domain: .inspector,
            method: "Inspector.inspect",
            targetID: .init("frame-A"),
            paramsData: Data(#"{"object":{"objectId":"opaque-object"},"hints":{}}"#.utf8)
        )
    )
    #expect(targetScopedInspectorInspect == .remoteObject(
        targetID: .init("frame-A"),
        remoteObject: .init(objectID: "opaque-object", injectedScriptID: nil)
    ))
}

private func firstEvent(
    from stream: AsyncStream<ProtocolEventEnvelope>,
    timeout: Duration = .seconds(1)
) -> Task<ProtocolEventEnvelope?, Never> {
    Task {
        await withTaskGroup(of: ProtocolEventEnvelope?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}

private func firstEvents(
    _ count: Int,
    from stream: AsyncStream<ProtocolEventEnvelope>,
    timeout: Duration = .seconds(1)
) -> Task<[ProtocolEventEnvelope], Never> {
    Task {
        await withTaskGroup(of: [ProtocolEventEnvelope].self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                var events: [ProtocolEventEnvelope] = []
                while events.count < count {
                    guard let event = await iterator.next() else {
                        break
                    }
                    events.append(event)
                }
                return events
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return []
            }

            let result = await group.next() ?? []
            group.cancelAll()
            return result
        }
    }
}

private func waitForRootMessage(_ backend: FakeTransportBackend) async throws -> String {
    try await waitUntil {
        await backend.sentMessages().last
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

private func receiveTargetDispatch(
    _ session: TransportSession,
    targetID: ProtocolTargetIdentifier,
    message: String
) async {
    await session.receiveRootMessage(targetDispatchMessage(targetID: targetID, message: message))
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

private func jsonObject(from data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func integerValue(_ value: Any?) -> Int? {
    if let value = value as? Int {
        return value
    }
    if let value = value as? NSNumber,
       CFGetTypeID(value) != CFBooleanGetTypeID() {
        return value.intValue
    }
    return nil
}

private func doubleValue(_ value: Any?) -> Double? {
    if let value = value as? Double {
        return value
    }
    if let value = value as? Int {
        return Double(value)
    }
    if let value = value as? NSNumber,
       CFGetTypeID(value) != CFBooleanGetTypeID() {
        return value.doubleValue
    }
    return nil
}

private func hasVisibleHighlightConfig(_ config: [String: Any]?) -> Bool {
    guard let config else {
        return false
    }
    return ["contentColor", "paddingColor", "borderColor", "marginColor"].allSatisfy { key in
        guard let color = config[key] as? [String: Any] else {
            return false
        }
        return doubleValue(color["a"]).map { $0 > 0 } == true
    }
}
