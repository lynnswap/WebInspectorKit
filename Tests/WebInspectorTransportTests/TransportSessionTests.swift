import Foundation
import Testing
import WebInspectorTestSupport
@testable import WebInspectorCore
@testable import WebInspectorTransport

private let testResponseTimeout: Duration = .milliseconds(750)
private let testWaitTimeout: Duration = .milliseconds(750)

private struct TestDecodedPayload: Decodable, Equatable, Sendable {
    var value: String
}

@Test
func transportMessageParserUsesPolicyForInlineAndDetachedParsing() async throws {
    let message = #"{"id":42,"method":"Runtime.consoleAPICalled","params":{"type":"log"},"result":{"ok":true}}"#
    let inline = try await TransportMessageParser.parse(
        message,
        policy: TransportMessageParsePolicy(detachedParsingThresholdBytes: .max)
    )
    let detached = try await TransportMessageParser.parse(
        message,
        policy: TransportMessageParsePolicy(detachedParsingThresholdBytes: 0)
    )

    #expect(inline == detached)
    #expect(inline.id == 42)
    #expect(inline.method == "Runtime.consoleAPICalled")
}

@Test
func transportMessageParserUsesPolicyForInlineAndDetachedDecoding() async throws {
    let data = Data(#"{"value":"decoded"}"#.utf8)
    let inline = try await TransportMessageParser.decodeAsync(
        TestDecodedPayload.self,
        from: data,
        policy: TransportMessageParsePolicy(detachedParsingThresholdBytes: .max)
    )
    let detached = try await TransportMessageParser.decodeAsync(
        TestDecodedPayload.self,
        from: data,
        policy: TransportMessageParsePolicy(detachedParsingThresholdBytes: 0)
    )

    #expect(inline == detached)
    #expect(detached.value == "decoded")
}

@Test
func rootCommandResolvesFromRootReply() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: testResponseTimeout)

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
    let session = TransportSession(backend: backend, responseTimeout: testResponseTimeout)
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
    #expect(sent.targetIdentifier == ProtocolTarget.ID("frame-A"))
    await receiveTargetDispatch(
        session,
        targetID: .init("frame-A"),
        message: ##"{"id":\##(innerID),"result":{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document"}}}"##
    )
    let result = try await sendTask.value

    #expect(result.method == "DOM.getDocument")
    #expect(result.targetID == ProtocolTarget.ID("frame-A"))
}

@Test
func domEnableIsTransportLocalWhileCSSEnableRoutesToTargetBackend() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: testResponseTimeout)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)

    let domResult = try await session.send(
        ProtocolCommand(domain: .dom, method: "DOM.enable", routing: .target(.init("page-main")))
    )
    #expect(await backend.sentTargetMessages().isEmpty)

    let cssTask = Task {
        try await session.send(
            ProtocolCommand(domain: .css, method: "CSS.enable", routing: .octopus(pageTarget: .init("page-main")))
        )
    }
    let cssSent = try await waitForTargetMessage(backend)
    await receiveTargetDispatch(
        session,
        targetID: .init("page-main"),
        message: #"{"id":\#(try messageID(cssSent.message)),"result":{}}"#
    )
    let cssResult = try await cssTask.value

    #expect(domResult.targetID == ProtocolTarget.ID("page-main"))
    #expect(cssResult.targetID == ProtocolTarget.ID("page-main"))
    #expect(String(data: domResult.resultData, encoding: .utf8) == "{}")
    #expect(String(data: cssResult.resultData, encoding: .utf8) == "{}")
    #expect(cssSent.targetIdentifier == ProtocolTarget.ID("page-main"))
}

@Test
func pageTargetDefaultsExposeCSSCapabilityEvenWithoutDomainMetadata() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: testResponseTimeout)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"web-page","frameId":"main-frame","isProvisional":false}}}"#)

    let target = try #require(await session.snapshot().targetsByID[ProtocolTarget.ID("page-main")])
    #expect(target.kind == .page)
    #expect(target.capabilities.contains(.css))
}

@Test
func pageTargetDomainMetadataKeepsPageDefaultCSSCapability() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: testResponseTimeout)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","domains":["DOM"],"isProvisional":false}}}"#)

    let target = try #require(await session.snapshot().targetsByID[ProtocolTarget.ID("page-main")])
    #expect(target.capabilities.contains(.dom))
    #expect(target.capabilities.contains(.css))
}

@Test
func targetReplyCarriesPerDomainSequenceWatermarks() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: testResponseTimeout)
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
    let session = TransportSession(backend: backend, responseTimeout: testResponseTimeout)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-A","type":"frame","frameId":"frame-A","isProvisional":false}}}"#)

    let sendTask = Task {
        try await session.send(
            ProtocolCommand(domain: .dom, method: "DOM.getDocument", routing: .target(.init("frame-A")))
        )
    }
    let sent = try await waitForTargetMessage(backend)

    await session.receiveRootMessage(#"{"id":\#(sent.outerIdentifier),"error":{"message":"target gone"}}"#)

    await #expect(throws: TransportSession.Error.remoteError(method: "DOM.getDocument", targetID: .init("frame-A"), message: "target gone")) {
        try await sendTask.value
    }
    #expect(await session.snapshot().pendingTargetReplyKeys.isEmpty)
}

@Test
func targetDestroyFailsPendingTargetReplies() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: testResponseTimeout)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-A","type":"frame","frameId":"frame-A","isProvisional":false}}}"#)

    let sendTask = Task {
        try await session.send(
            ProtocolCommand(domain: .dom, method: "DOM.getDocument", routing: .target(.init("frame-A")))
        )
    }
    _ = try await waitForTargetMessage(backend)

    await session.receiveRootMessage(#"{"method":"Target.targetDestroyed","params":{"targetId":"frame-A"}}"#)

    await #expect(throws: TransportSession.Error.missingTarget(.init("frame-A"))) {
        try await sendTask.value
    }
    #expect(await session.snapshot().pendingTargetReplyKeys.isEmpty)
}

@Test
func remoteErrorAndTimeoutFailPendingReplies() async throws {
    let errorBackend = FakeTransportBackend()
    let errorSession = TransportSession(backend: errorBackend, responseTimeout: nil)

    let errorTask = Task {
        try await errorSession.send(
            ProtocolCommand(domain: .target, method: "Target.resume", routing: .root)
        )
    }
    let sent = try await waitForRootMessage(errorBackend)
    let id = try messageID(sent)
    await errorSession.receiveRootMessage(#"{"id":\#(id),"error":{"message":"nope"}}"#)
    await #expect(throws: TransportSession.Error.remoteError(method: "Target.resume", targetID: nil, message: "nope")) {
        try await errorTask.value
    }

    let timeoutBackend = FakeTransportBackend()
    let responseTimeout = ManualResponseTimeout()
    let timeoutSession = TransportSession(
        backend: timeoutBackend,
        responseTimeout: .milliseconds(20),
        timeoutSleep: { duration in
            try await responseTimeout.sleep(for: duration)
        }
    )
    let timeoutTask = Task {
        try await timeoutSession.send(
            ProtocolCommand(domain: .target, method: "Target.setPauseOnStart", routing: .root)
        )
    }
    _ = try await waitForRootMessage(timeoutBackend)
    await responseTimeout.waitUntilSuspended()
    await responseTimeout.fireNext()
    await #expect(throws: TransportSession.Error.replyTimeout(method: "Target.setPauseOnStart", targetID: nil)) {
        _ = try await timeoutTask.value
    }
}

@Test
func cancellationFailsPendingReplyImmediately() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: testResponseTimeout)

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
func fakeBackendTargetMessageWaiterUsesAfterAndOrdinal() async throws {
    let backend = FakeTransportBackend()

    try await backend.sendJSONString(targetCommandWrapperMessage(outerID: 1, innerID: 1, method: "DOM.getDocument"))
    try await backend.sendJSONString(targetCommandWrapperMessage(outerID: 2, innerID: 2, method: "CSS.getMatchedStylesForNode"))
    try await backend.sendJSONString(targetCommandWrapperMessage(outerID: 3, innerID: 3, method: "DOM.getDocument"))

    let secondDocumentByOrdinal = try await backend.waitForTargetMessage(method: "DOM.getDocument", ordinal: 1)
    let secondDocumentByOffset = try await backend.waitForTargetMessage(method: "DOM.getDocument", after: 1)

    #expect(try messageID(secondDocumentByOrdinal.message) == 3)
    #expect(try messageID(secondDocumentByOffset.message) == 3)
}

@Test
func fakeBackendTargetMessageWaiterResumesFutureOrdinalMatch() async throws {
    let backend = FakeTransportBackend()
    let waitTask = Task {
        try await backend.waitForTargetMessage(method: "DOM.getDocument", ordinal: 1)
    }
    await backend.waitUntilTargetMessageWaiterRegistered(method: "DOM.getDocument", ordinal: 1)

    try await backend.sendJSONString(targetCommandWrapperMessage(outerID: 1, innerID: 1, method: "DOM.getDocument"))
    try await backend.sendJSONString(targetCommandWrapperMessage(outerID: 2, innerID: 2, method: "CSS.getMatchedStylesForNode"))
    try await backend.sendJSONString(targetCommandWrapperMessage(outerID: 3, innerID: 3, method: "DOM.getDocument"))

    let message = try await waitTask.value
    #expect(try messageID(message.message) == 3)
}

@Test
func fakeBackendTargetMessageWaiterCancellationDoesNotResumeWithLaterMessage() async throws {
    let backend = FakeTransportBackend()
    let waitTask = Task {
        try await backend.waitForTargetMessage(method: "DOM.getDocument")
    }
    await backend.waitUntilTargetMessageWaiterRegistered(method: "DOM.getDocument")

    waitTask.cancel()
    try await backend.sendJSONString(targetCommandWrapperMessage(outerID: 1, innerID: 1, method: "DOM.getDocument"))

    do {
        _ = try await waitTask.value
        Issue.record("Expected cancellation")
    } catch is CancellationError {
    } catch {
        Issue.record("Expected CancellationError, got \(error)")
    }

    let message = try await backend.waitForTargetMessage(method: "DOM.getDocument")
    #expect(try messageID(message.message) == 1)
}

@Test
func detachFailsPendingRepliesAndClosesStreams() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: testResponseTimeout)
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

    await #expect(throws: TransportSession.Error.transportClosed) {
        try await sendTask.value
    }
    let event = await streamTask.value
    #expect(event == nil)
    #expect(await backend.isDetached())
}

@Test
func waitForCurrentMainPageTargetFailsAfterDetach() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: testResponseTimeout)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)

    let target = try await session.waitForCurrentMainPageTarget()
    #expect(target.targetID == ProtocolTarget.ID("page-main"))

    await session.detach()

    await #expect(throws: TransportSession.Error.transportClosed) {
        try await session.waitForCurrentMainPageTarget()
    }
}

@Test
func receiveRootMessageAfterDetachDoesNotMutateSnapshot() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: testResponseTimeout)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    let snapshotBeforeDetach = await session.snapshot()

    await session.detach()
    let sequenceAfterDetach = await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"late-page","type":"page","frameId":"late-frame","isProvisional":false}}}"#)

    #expect(sequenceAfterDetach == 1)
    #expect(await session.snapshot() == snapshotBeforeDetach)
}

@Test
func waitForCurrentMainPageTargetTimeoutUsesInjectedSleep() async throws {
    let backend = FakeTransportBackend()
    let timeout = ManualResponseTimeout()
    let session = TransportSession(
        backend: backend,
        responseTimeout: testResponseTimeout,
        timeoutSleep: { duration in
            try await timeout.sleep(for: duration)
        }
    )

    let waitTask = Task {
        try await session.waitForCurrentMainPageTarget(timeout: .milliseconds(20))
    }
    await timeout.waitUntilSuspended()
    await timeout.fireNext()

    await #expect(throws: TransportSession.Error.missingMainPageTarget) {
        try await waitTask.value
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

    #expect(snapshot.currentMainPageTargetID == ProtocolTarget.ID("page-main"))
    #expect(snapshot.targetsByID[ProtocolTarget.ID("worker-1")] == nil)
    #expect(snapshot.targetsByID[ProtocolTarget.ID("frame-committed")]?.kind == .frame)
    #expect(snapshot.targetsByID[ProtocolTarget.ID("frame-committed")]?.isProvisional == false)
    #expect(snapshot.frameTargetIDsByFrameID[ProtocolFrame.ID("ad-frame")] == ProtocolTarget.ID("frame-committed"))
}

@Test
func pageTargetWithParentFrameIsClassifiedAsFrame() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"iframe-page","type":"page","frameId":"child-frame","parentFrameId":"main-frame","isProvisional":false}}}"#)
    let snapshot = await session.snapshot()

    #expect(snapshot.targetsByID[ProtocolTarget.ID("iframe-page")]?.kind == .frame)
    #expect(snapshot.currentMainPageTargetID == nil)
    #expect(snapshot.frameTargetIDsByFrameID[ProtocolFrame.ID("child-frame")] == ProtocolTarget.ID("iframe-page"))
}

@Test
func pageTargetWithKnownNonMainFrameIsClassifiedAsFrame() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"iframe-page","type":"page","frameId":"child-frame","isProvisional":false}}}"#)
    let snapshot = await session.snapshot()

    #expect(snapshot.currentMainPageTargetID == ProtocolTarget.ID("page-main"))
    #expect(snapshot.targetsByID[ProtocolTarget.ID("iframe-page")]?.kind == .frame)
    #expect(snapshot.frameTargetIDsByFrameID[ProtocolFrame.ID("child-frame")] == ProtocolTarget.ID("iframe-page"))
}

@Test
func pageTargetWithoutFrameIDCanCommitAsCurrentPage() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-old","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-new","type":"page","isProvisional":true}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-old","newTargetId":"page-new"}}"#)
    let snapshot = await session.snapshot()

    #expect(snapshot.currentMainPageTargetID == ProtocolTarget.ID("page-new"))
    #expect(snapshot.targetsByID[ProtocolTarget.ID("page-new")]?.kind == .page)
    #expect(snapshot.targetsByID[ProtocolTarget.ID("page-new")]?.isProvisional == false)
}

@Test
func targetCommitMergesFrameMetadataAndClearsOldFrameMapping() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-provisional","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":true}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-committed","type":"frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"frame-provisional","newTargetId":"frame-committed"}}"#)
    let snapshot = await session.snapshot()

    #expect(snapshot.targetsByID[ProtocolTarget.ID("frame-committed")]?.frameID == ProtocolFrame.ID("ad-frame"))
    #expect(snapshot.targetsByID[ProtocolTarget.ID("frame-committed")]?.parentFrameID == ProtocolFrame.ID("main-frame"))
    #expect(snapshot.frameTargetIDsByFrameID[ProtocolFrame.ID("ad-frame")] == ProtocolTarget.ID("frame-committed"))
    #expect(snapshot.targetsByID[ProtocolTarget.ID("frame-provisional")] == nil)
}

@Test
func subframeCommitDoesNotConsumeCurrentMainPageTarget() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-committed","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":true}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"frame-committed"}}"#)
    let snapshot = await session.snapshot()

    #expect(snapshot.currentMainPageTargetID == ProtocolTarget.ID("page-main"))
    #expect(snapshot.targetsByID[ProtocolTarget.ID("page-main")] != nil)
    #expect(snapshot.targetsByID[ProtocolTarget.ID("frame-committed")]?.isProvisional == false)
    #expect(snapshot.frameTargetIDsByFrameID[ProtocolFrame.ID("ad-frame")] == ProtocolTarget.ID("frame-committed"))
}

@Test
func targetCommitRetargetsPendingRepliesToCommittedTarget() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: testResponseTimeout)
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

    #expect(result.targetID == ProtocolTarget.ID("frame-committed"))
    #expect(await session.snapshot().pendingTargetReplyKeys.isEmpty)
}

@Test
func provisionalTargetReplyIsBufferedUntilCommit() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: testResponseTimeout)
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
    #expect(await session.snapshot().pendingTargetReplyKeys == [
        TransportSession.ReplyKey(targetID: .init("frame-provisional"), commandID: innerID),
    ])

    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"frame-provisional","newTargetId":"frame-committed"}}"#)
    let result = try await sendTask.value

    #expect(result.targetID == ProtocolTarget.ID("frame-committed"))
    #expect(await session.snapshot().pendingTargetReplyKeys.isEmpty)
}

@Test
func bufferedProvisionalTargetReplySurvivesResponseTimeoutBeforeCommit() async throws {
    let backend = FakeTransportBackend()
    let responseTimeout = ManualResponseTimeout()
    let session = TransportSession(
        backend: backend,
        responseTimeout: .milliseconds(20),
        timeoutSleep: { duration in
            try await responseTimeout.sleep(for: duration)
        },
        responseTimeoutDidFire: {
            await responseTimeout.recordHandledTimeout()
        }
    )
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
    await responseTimeout.waitUntilSuspended()
    await responseTimeout.fireNext()
    await responseTimeout.waitUntilHandledTimeout()

    #expect(await session.snapshot().pendingTargetReplyKeys == [
        TransportSession.ReplyKey(targetID: .init("frame-provisional"), commandID: innerID),
    ])

    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"frame-provisional","newTargetId":"frame-committed"}}"#)
    let result = try await sendTask.value

    #expect(result.targetID == ProtocolTarget.ID("frame-committed"))
    #expect(await session.snapshot().pendingTargetReplyKeys.isEmpty)
}

@Test
func oldlessTargetCommitInfersSoleProvisionalTarget() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: testResponseTimeout)
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

    #expect(result.targetID == ProtocolTarget.ID("frame-committed"))
    #expect(snapshot.targetsByID[ProtocolTarget.ID("frame-provisional")] == nil)
    #expect(snapshot.targetsByID[ProtocolTarget.ID("frame-committed")]?.frameID == ProtocolFrame.ID("ad-frame"))
    #expect(snapshot.frameTargetIDsByFrameID[ProtocolFrame.ID("ad-frame")] == ProtocolTarget.ID("frame-committed"))
}

@Test
func provisionalTargetMessagesAreDispatchedAfterCommitTargetEvent() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: testResponseTimeout)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-next","type":"page","frameId":"main-frame","isProvisional":true}}}"#)

    let targetStream = await session.events(for: .target)
    let domStream = await session.events(for: .dom)
    let targetEvents = ProtocolEventRecorder(stream: targetStream)
    let domEvents = ProtocolEventRecorder(stream: domStream)

    await receiveTargetDispatch(
        session,
        targetID: .init("page-next"),
        message: #"{"method":"DOM.childNodeCountUpdated","params":{"nodeId":3,"childNodeCount":0}}"#
    )
    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"page-next"}}"#)

    let targetEvent = try await targetEvents.event()
    let domEvent = try await domEvents.event()

    #expect(targetEvent.method == "Target.didCommitProvisionalTarget")
    #expect(domEvent.method == "DOM.childNodeCountUpdated")
    #expect(domEvent.targetID == ProtocolTarget.ID("page-next"))
    #expect(domEvent.sequence > targetEvent.sequence)
    #expect(domEvent.receivedSequence(for: .target) == targetEvent.sequence)
}

@Test
func oldProvisionalTargetMessagesAreDispatchedAfterCommitTargetEvent() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: testResponseTimeout)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-provisional","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":true}}}"#)

    let targetStream = await session.events(for: .target)
    let domStream = await session.events(for: .dom)
    let targetEvents = ProtocolEventRecorder(stream: targetStream)
    let domEvents = ProtocolEventRecorder(stream: domStream)

    await receiveTargetDispatch(
        session,
        targetID: .init("frame-provisional"),
        message: #"{"method":"DOM.childNodeCountUpdated","params":{"nodeId":3,"childNodeCount":1}}"#
    )
    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"frame-provisional","newTargetId":"frame-committed"}}"#)

    let targetEvent = try await targetEvents.event()
    let domEvent = try await domEvents.event()

    #expect(targetEvent.method == "Target.didCommitProvisionalTarget")
    #expect(domEvent.method == "DOM.childNodeCountUpdated")
    #expect(domEvent.targetID == ProtocolTarget.ID("frame-committed"))
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

    await #expect(throws: TransportSession.Error.replyTimeout(method: "DOM.getDocument", targetID: .init("frame-provisional"))) {
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

    #expect(snapshot.targetsByID[ProtocolTarget.ID("frame-existing")]?.kind == .frame)
    #expect(snapshot.targetsByID[ProtocolTarget.ID("frame-existing")]?.frameID == ProtocolFrame.ID("ad-frame"))
    #expect(snapshot.targetsByID[ProtocolTarget.ID("missing-target")] == nil)
}

@Test
func rootScopedRuntimeDOMAndConsoleEventsResolveToCurrentPageTarget() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)
    let runtimeStream = await session.events(for: .runtime)
    let domStream = await session.events(for: .dom)
    let consoleStream = await session.events(for: .console)
    let runtimeEvents = ProtocolEventRecorder(stream: runtimeStream)
    let domEvents = ProtocolEventRecorder(stream: domStream)
    let consoleEvents = ProtocolEventRecorder(stream: consoleStream)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Runtime.executionContextCreated","params":{"context":{"id":11,"frameId":"main-frame"}}}"#)
    await session.receiveRootMessage(#"{"method":"DOM.childNodeCountUpdated","params":{"nodeId":1,"childNodeCount":2}}"#)
    await session.receiveRootMessage(#"{"method":"Console.messageAdded","params":{"message":{"text":"hello"}}}"#)
    let snapshot = await session.snapshot()

    #expect(snapshot.executionContextsByKey[contextKey("page-main", 11)]?.targetID == ProtocolTarget.ID("page-main"))
    let runtimeEvent = try await runtimeEvents.event()
    let domEvent = try await domEvents.event()
    let consoleEvent = try await consoleEvents.event()
    #expect(runtimeEvent.targetID == ProtocolTarget.ID("page-main"))
    #expect(domEvent.targetID == ProtocolTarget.ID("page-main"))
    #expect(consoleEvent.targetID == ProtocolTarget.ID("page-main"))
}

@Test
func rootScopedDocumentUpdatedRemainsTargetless() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)
    let domStream = await session.events(for: .dom)
    let domEvents = ProtocolEventRecorder(stream: domStream)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"DOM.documentUpdated","params":{}}"#)

    let event = try await domEvents.event()
    #expect(event.targetID == nil)
}

@Test
func rootScopedInspectorEventsRemainTargetless() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)
    let inspectorStream = await session.events(for: .inspector)
    let inspectorEvents = ProtocolEventRecorder(stream: inspectorStream)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Inspector.inspect","params":{"object":{"type":"object","subtype":"node","objectId":"node-1"}}}"#)

    let event = try await inspectorEvents.event()
    #expect(event.targetID == nil)
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

    #expect(snapshot.executionContextsByKey[contextKey("frame-A", 7)]?.targetID == ProtocolTarget.ID("frame-A"))
    #expect(await session.targetID(forFrameID: .init("frame-A")) == ProtocolTarget.ID("frame-A"))
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

    #expect(snapshot.executionContextsByKey[contextKey("page-main", 7)]?.targetID == ProtocolTarget.ID("frame-A"))
    #expect(await session.targetID(forFrameID: .init("frame-A")) == ProtocolTarget.ID("frame-A"))
}

@Test
func rootScopedRuntimeClearRemovesRetargetedContextsFromPageRuntimeAgent() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-A","type":"frame","frameId":"frame-A","parentFrameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Runtime.executionContextCreated","params":{"context":{"id":7,"frameId":"frame-A"}}}"#)
    await receiveTargetDispatch(
        session,
        targetID: .init("frame-A"),
        message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":8,"frameId":"frame-A"}}}"#
    )

    let beforeClear = await session.snapshot()
    #expect(beforeClear.executionContextsByKey[contextKey("page-main", 7)]?.targetID == ProtocolTarget.ID("frame-A"))
    #expect(beforeClear.executionContextsByKey[contextKey("page-main", 7)]?.runtimeAgentTargetID == ProtocolTarget.ID("page-main"))
    #expect(beforeClear.executionContextsByKey[contextKey("frame-A", 8)]?.runtimeAgentTargetID == ProtocolTarget.ID("frame-A"))

    await session.receiveRootMessage(#"{"method":"Runtime.executionContextsCleared","params":{}}"#)
    let afterClear = await session.snapshot()

    #expect(afterClear.executionContextsByKey[contextKey("page-main", 7)] == nil)
    #expect(afterClear.executionContextsByKey[contextKey("frame-A", 8)]?.targetID == ProtocolTarget.ID("frame-A"))
}

@Test
func runtimeExecutionContextRegistryScopesDuplicateIDsByRuntimeAgentTarget() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-A","type":"frame","frameId":"frame-A","parentFrameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Runtime.executionContextCreated","params":{"context":{"id":7,"frameId":"frame-A"}}}"#)
    await receiveTargetDispatch(
        session,
        targetID: .init("frame-A"),
        message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":7,"frameId":"frame-A"}}}"#
    )

    let snapshot = await session.snapshot()
    #expect(snapshot.executionContextsByKey[contextKey("page-main", 7)]?.targetID == ProtocolTarget.ID("frame-A"))
    #expect(snapshot.executionContextsByKey[contextKey("frame-A", 7)]?.targetID == ProtocolTarget.ID("frame-A"))

    await receiveTargetDispatch(
        session,
        targetID: .init("frame-A"),
        message: #"{"method":"Runtime.executionContextDestroyed","params":{"executionContextId":7}}"#
    )
    let afterFrameDestroy = await session.snapshot()
    #expect(afterFrameDestroy.executionContextsByKey[contextKey("page-main", 7)]?.targetID == ProtocolTarget.ID("frame-A"))
    #expect(afterFrameDestroy.executionContextsByKey[contextKey("frame-A", 7)] == nil)

    await session.receiveRootMessage(#"{"method":"Runtime.executionContextsCleared","params":{}}"#)
    #expect(await session.snapshot().executionContextsByKey[contextKey("page-main", 7)] == nil)
}

@Test
func runtimeExecutionContextRegistryPreservesCommittedContextWhenIDsCollide() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-old","type":"page","frameId":"old-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-new","type":"page","isProvisional":false}}}"#)
    await receiveTargetDispatch(
        session,
        targetID: .init("page-old"),
        message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":7,"type":"normal","name":"old","frameId":"old-frame"}}}"#
    )
    await receiveTargetDispatch(
        session,
        targetID: .init("page-new"),
        message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":7,"type":"normal","name":"new"}}}"#
    )

    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-old","newTargetId":"page-new"}}"#)
    let snapshot = await session.snapshot()

    #expect(snapshot.executionContextsByKey[contextKey("page-old", 7)] == nil)
    #expect(snapshot.executionContextsByKey[contextKey("page-new", 7)]?.name == "new")
}

@Test
func runtimeExecutionContextRegistryPreservesContextMetadata() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Runtime.executionContextCreated","params":{"context":{"id":9,"type":"internal","name":"Isolated World","frameId":"main-frame"}}}"#)
    let snapshot = await session.snapshot()
    let record = try #require(snapshot.executionContextsByKey[contextKey("page-main", 9)])

    #expect(record.targetID == ProtocolTarget.ID("page-main"))
    #expect(record.type == .internal)
    #expect(record.name == "Isolated World")
    #expect(record.frameID == ProtocolFrame.ID("main-frame"))
}

@Test
func runtimeExecutionContextRegistryAppliesTeardownEvents() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Runtime.executionContextCreated","params":{"context":{"id":9,"type":"normal","frameId":"main-frame"}}}"#)
    await session.receiveRootMessage(#"{"method":"Runtime.executionContextDestroyed","params":{"executionContextId":9}}"#)
    #expect(await session.snapshot().executionContextsByKey[contextKey("page-main", 9)] == nil)

    await session.receiveRootMessage(#"{"method":"Runtime.executionContextCreated","params":{"context":{"id":10,"type":"normal","frameId":"main-frame"}}}"#)
    await session.receiveRootMessage(#"{"method":"Runtime.executionContextsCleared","params":{}}"#)
    #expect(await session.snapshot().executionContextsByKey[contextKey("page-main", 10)] == nil)
}

@Test
func domainStreamsReceiveIndependentTargetEventsInOrder() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)
    let domStream = await session.events(for: .dom)
    let cssStream = await session.events(for: .css)
    let consoleStream = await session.events(for: .console)
    let networkStream = await session.events(for: .network)

    let domEvents = ProtocolEventRecorder(stream: domStream)
    let cssEvents = ProtocolEventRecorder(stream: cssStream)
    let consoleEvents = ProtocolEventRecorder(stream: consoleStream)
    let networkEvents = ProtocolEventRecorder(stream: networkStream)

    await receiveTargetDispatch(session, targetID: .init("frame-A"), message: #"{"method":"DOM.setChildNodes","params":{"parentId":1,"nodes":[]}}"#)
    await receiveTargetDispatch(session, targetID: .init("frame-A"), message: #"{"method":"CSS.styleSheetChanged","params":{"styleSheetId":"s1"}}"#)
    await receiveTargetDispatch(session, targetID: .init("frame-A"), message: #"{"method":"Console.messageAdded","params":{"message":{"text":"hello"}}}"#)
    await receiveTargetDispatch(session, targetID: .init("page-main"), message: #"{"method":"Network.requestWillBeSent","params":{"requestId":"r1","request":{"url":"https://example.com"},"timestamp":1}}"#)

    let domEvent = try await domEvents.event()
    let cssEvent = try await cssEvents.event()
    let consoleEvent = try await consoleEvents.event()
    let networkEvent = try await networkEvents.event()
    #expect(domEvent.method == "DOM.setChildNodes")
    #expect(cssEvent.method == "CSS.styleSheetChanged")
    #expect(consoleEvent.method == "Console.messageAdded")
    #expect(networkEvent.method == "Network.requestWillBeSent")
}

@Test
func rootCSSStyleSheetEventsResolveFrameTargetFromFrameIDAndStyleSheetOwnership() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)
    let cssStream = await session.events(for: .css)
    let cssEvents = ProtocolEventRecorder(stream: cssStream)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-A","type":"frame","frameId":"frame-A","parentFrameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"CSS.styleSheetAdded","params":{"header":{"styleSheetId":"sheet-frame","frameId":"frame-A"}}}"#)
    await session.receiveRootMessage(#"{"method":"CSS.styleSheetChanged","params":{"styleSheetId":"sheet-frame"}}"#)
    await session.receiveRootMessage(#"{"method":"CSS.styleSheetRemoved","params":{"styleSheetId":"sheet-frame"}}"#)
    await session.receiveRootMessage(#"{"method":"CSS.styleSheetChanged","params":{"styleSheetId":"sheet-frame"}}"#)

    let events = try await cssEvents.events(prefix: 4)
    #expect(events.map(\.method) == ["CSS.styleSheetAdded", "CSS.styleSheetChanged", "CSS.styleSheetRemoved", "CSS.styleSheetChanged"])
    #expect(events.map(\.targetID) == [
        ProtocolTarget.ID("frame-A"),
        ProtocolTarget.ID("frame-A"),
        ProtocolTarget.ID("frame-A"),
        nil,
    ])
}

@Test
func rootCSSStyleSheetAddedBeforeFrameTargetDoesNotPinSheetToPage() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)
    let cssStream = await session.events(for: .css)
    let cssEvents = ProtocolEventRecorder(stream: cssStream)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"CSS.styleSheetAdded","params":{"header":{"styleSheetId":"sheet-late-frame","frameId":"late-frame"}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-late","type":"frame","frameId":"late-frame","parentFrameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"CSS.styleSheetChanged","params":{"styleSheetId":"sheet-late-frame"}}"#)

    let events = try await cssEvents.events(prefix: 3)
    #expect(events.map(\.method) == ["CSS.styleSheetAdded", "CSS.styleSheetAdded", "CSS.styleSheetChanged"])
    #expect(events.map(\.targetID) == [
        nil,
        ProtocolTarget.ID("frame-late"),
        ProtocolTarget.ID("frame-late"),
    ])
}

@Test
func rootCSSStyleSheetAddedBeforeProvisionalFrameTargetReplaysAfterCommit() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)
    let cssStream = await session.events(for: .css)
    let cssEvents = ProtocolEventRecorder(stream: cssStream)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"CSS.styleSheetAdded","params":{"header":{"styleSheetId":"sheet-provisional-frame","frameId":"ad-frame"}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-provisional","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":true}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"frame-provisional","newTargetId":"frame-committed"}}"#)

    let events = try await cssEvents.events(prefix: 2)
    #expect(events.map(\.method) == ["CSS.styleSheetAdded", "CSS.styleSheetAdded"])
    #expect(events.map(\.targetID) == [
        nil,
        ProtocolTarget.ID("frame-committed"),
    ])
}

@Test
func orderedStreamReceivesTargetEventsAcrossDomainsInTransportOrder() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)
    let stream = await session.orderedEvents()
    let events = ProtocolEventRecorder(stream: stream)

    await receiveTargetDispatch(session, targetID: .init("page-main"), message: #"{"method":"DOM.documentUpdated","params":{}}"#)
    await receiveTargetDispatch(session, targetID: .init("page-main"), message: #"{"method":"Network.requestWillBeSent","params":{"requestId":"r1","request":{"url":"https://example.com"},"timestamp":1}}"#)
    await receiveTargetDispatch(session, targetID: .init("page-main"), message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":7}}}"#)
    await receiveTargetDispatch(session, targetID: .init("page-main"), message: #"{"method":"DOM.childNodeCountUpdated","params":{"nodeId":3,"childNodeCount":2}}"#)

    let recordedEvents = try await events.events(prefix: 4)
    #expect(recordedEvents.map(\.method) == [
        "DOM.documentUpdated",
        "Network.requestWillBeSent",
        "Runtime.executionContextCreated",
        "DOM.childNodeCountUpdated",
    ])
    #expect(recordedEvents.map(\.sequence) == [1, 2, 3, 4])
}

@Test
func networkProtocolDispatchingKeepsEnvelopeTargetAndPayloadTargetSeparate() async throws {
    let network = await NetworkSession()
    let event = ProtocolEvent(
        sequence: 1,
        domain: .network,
        method: "Network.requestWillBeSent",
        targetID: .init("page-proxy"),
        paramsData: Data(
            #"{"requestId":"request-1","frameId":"ad-frame","loaderId":"loader","documentURL":"https://page.example","request":{"url":"https://ads.example/ad.js"},"targetId":"frame-ad","backendResourceIdentifier":{"sourceProcessID":"web-content-2","resourceID":"resource-1"},"timestamp":1}"#.utf8
        )
    )

    try await NetworkProtocolEventDispatcher(session: network).dispatch(event)
    let key = NetworkRequest.ID(targetID: .init("page-proxy"), requestID: .init("request-1"))
    let snapshot = try #require(await network.requestSnapshot(for: key))

    #expect(snapshot.originatingTargetID == ProtocolTarget.ID("frame-ad"))
    #expect(snapshot.backendResourceIdentifier == NetworkRequest.BackendResourceID(sourceProcessID: "web-content-2", resourceID: "resource-1"))
}

@Test
func networkProtocolDispatchingBuildsRedirectChainFromRepeatedRequestWillBeSent() async throws {
    let network = await NetworkSession()
    let targetID = ProtocolTarget.ID("page-proxy")
    let first = ProtocolEvent(
        sequence: 1,
        domain: .network,
        method: "Network.requestWillBeSent",
        targetID: targetID,
        paramsData: Data(
            #"{"requestId":"request-redirect","request":{"url":"http://example.com"},"timestamp":1}"#.utf8
        )
    )
    let redirect = ProtocolEvent(
        sequence: 2,
        domain: .network,
        method: "Network.requestWillBeSent",
        targetID: targetID,
        paramsData: Data(
            #"{"requestId":"request-redirect","request":{"url":"https://example.com"},"redirectResponse":{"status":302},"timestamp":2}"#.utf8
        )
    )

    try await NetworkProtocolEventDispatcher(session: network).dispatch(first)
    try await NetworkProtocolEventDispatcher(session: network).dispatch(redirect)
    let key = NetworkRequest.ID(targetID: targetID, requestID: .init("request-redirect"))
    let snapshot = try #require(await network.requestSnapshot(for: key))

    #expect(snapshot.request.url == "https://example.com")
    #expect(snapshot.redirects.first?.id == NetworkRequest.RedirectHop.ID(requestKey: key, redirectIndex: 0))
    #expect(snapshot.redirects.first?.response.url == "http://example.com")
}

@Test
func networkProtocolDispatchingPreservesInitiatorAndLoadingFinishedMetrics() async throws {
    let network = await NetworkSession()
    let targetID = ProtocolTarget.ID("page-proxy")
    let requestID = NetworkRequest.ProtocolID("request-metrics")

    try await NetworkProtocolEventDispatcher(session: network).dispatch(
        ProtocolEvent(
            sequence: 1,
            domain: .network,
            method: "Network.requestWillBeSent",
            targetID: targetID,
            paramsData: Data(
                ##"{"requestId":"request-metrics","request":{"url":"https://example.com/app.js"},"timestamp":1,"initiator":{"type":"parser","url":"https://example.com","lineNumber":12,"nodeId":42,"stackTrace":{"callFrames":[{"functionName":"load","url":"https://example.com/app.js","scriptId":"7","lineNumber":3,"columnNumber":9}]}}}"##.utf8
            )
        )
    )
    try await NetworkProtocolEventDispatcher(session: network).dispatch(
        ProtocolEvent(
            sequence: 2,
            domain: .network,
            method: "Network.responseReceived",
            targetID: targetID,
            paramsData: Data(
                ##"{"requestId":"request-metrics","response":{"status":200,"headers":{"Content-Type":"text/javascript"}},"timestamp":1.5}"##.utf8
            )
        )
    )
    try await NetworkProtocolEventDispatcher(session: network).dispatch(
        ProtocolEvent(
            sequence: 3,
            domain: .network,
            method: "Network.loadingFinished",
            targetID: targetID,
            paramsData: Data(
                ##"{"requestId":"request-metrics","timestamp":2,"sourceMapURL":"app.js.map","metrics":{"protocol":"h2","priority":"high","connectionIdentifier":"connection-1","remoteAddress":"203.0.113.10","requestHeaders":{"User-Agent":"WebInspector"},"requestHeaderBytesSent":64,"responseHeaderBytesReceived":128,"responseBodyBytesReceived":300,"responseBodyDecodedSize":512,"securityConnection":{"protocol":"TLS 1.3","cipher":"TLS_AES_128_GCM_SHA256"},"isProxyConnection":false}}"##.utf8
            )
        )
    )
    let key = NetworkRequest.ID(targetID: targetID, requestID: requestID)
    let snapshot = try #require(await network.requestSnapshot(for: key))

    #expect(snapshot.initiator?.type == .parser)
    #expect(snapshot.initiator?.nodeID == DOMNode.ProtocolID(42))
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
func networkProtocolDispatchingHandlesWebSocketLifecycleEvents() async throws {
    let network = await NetworkSession()
    let targetID = ProtocolTarget.ID("page-proxy")
    let requestID = NetworkRequest.ProtocolID("ws.1")

    for event in [
        ProtocolEvent(sequence: 1, domain: .network, method: "Network.webSocketCreated", targetID: targetID, paramsData: Data(#"{"requestId":"ws.1","url":"wss://example.com/socket"}"#.utf8)),
        ProtocolEvent(sequence: 2, domain: .network, method: "Network.webSocketWillSendHandshakeRequest", targetID: targetID, paramsData: Data(#"{"requestId":"ws.1","timestamp":1,"request":{"headers":{"Upgrade":"websocket"}}}"#.utf8)),
        ProtocolEvent(sequence: 3, domain: .network, method: "Network.webSocketHandshakeResponseReceived", targetID: targetID, paramsData: Data(#"{"requestId":"ws.1","timestamp":2,"response":{"status":101,"statusText":"Switching Protocols","headers":{"Upgrade":"websocket"}}}"#.utf8)),
        ProtocolEvent(sequence: 4, domain: .network, method: "Network.webSocketFrameSent", targetID: targetID, paramsData: Data(#"{"requestId":"ws.1","timestamp":3,"response":{"opcode":1,"mask":true,"payloadData":"hello","payloadLength":5}}"#.utf8)),
        ProtocolEvent(sequence: 5, domain: .network, method: "Network.webSocketFrameReceived", targetID: targetID, paramsData: Data(#"{"requestId":"ws.1","timestamp":4,"response":{"opcode":1,"mask":false,"payloadData":"world","payloadLength":5}}"#.utf8)),
        ProtocolEvent(sequence: 6, domain: .network, method: "Network.webSocketFrameError", targetID: targetID, paramsData: Data(#"{"requestId":"ws.1","timestamp":4.5,"errorMessage":"bad frame"}"#.utf8)),
        ProtocolEvent(sequence: 7, domain: .network, method: "Network.webSocketClosed", targetID: targetID, paramsData: Data(#"{"requestId":"ws.1","timestamp":5}"#.utf8)),
    ] {
        try await NetworkProtocolEventDispatcher(session: network).dispatch(event)
    }
    let key = NetworkRequest.ID(targetID: targetID, requestID: requestID)
    let snapshot = try #require(await network.requestSnapshot(for: key))

    #expect(snapshot.webSocketHandshakeRequest?.headers["Upgrade"] == "websocket")
    #expect(snapshot.webSocketHandshakeResponse?.status == 101)
    #expect(snapshot.webSocketFrames.count == 3)
    #expect(snapshot.webSocketFrames[2].direction == .error("bad frame"))
    #expect(snapshot.webSocketReadyState == .closed)
    #expect(snapshot.state == .finished)
}

@Test
func domProtocolDispatchingCompletesInspectSelectionThroughRequestNodeResult() async throws {
    let dom = await DOMSession()
    try await TargetProtocolEventDispatcher().dispatch(
        ProtocolEvent(
            sequence: 1,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("frame-A"),
            paramsData: Data(#"{"targetInfo":{"targetId":"frame-A","type":"frame","frameId":"frame-A","isProvisional":false}}"#.utf8)
        ),
        to: dom
    )
    try await DOMProtocolCommands().applyGetDocumentResult(
        ProtocolCommand.Result(
            domain: .dom,
            method: "DOM.getDocument",
            targetID: .init("frame-A"),
            resultData: Data(##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","children":[{"nodeId":2,"nodeType":1,"nodeName":"DIV","localName":"div"}]}}"##.utf8)
        ),
        to: dom
    )
    try await RuntimeProtocolEventDispatcher(handlers: [dom]).dispatch(
        ProtocolEvent(
            sequence: 2,
            domain: .runtime,
            method: "Runtime.executionContextCreated",
            targetID: .init("frame-A"),
            paramsData: Data(#"{"context":{"id":9,"frameId":"frame-A"}}"#.utf8)
        )
    )
    let intent = await dom.beginInspectSelectionRequest(targetID: .init("frame-A"), objectID: "node-object")
    guard case let .success(.requestNode(selectionRequestID, targetID, _)) = intent else {
        Issue.record("Expected DOM.requestNode intent")
        return
    }

    let result = try await DOMProtocolCommands().applyRequestNodeResult(
        ProtocolCommand.Result(
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

    #expect(selectedNodeID.nodeID == DOMNode.ProtocolID(2))
    let selectedNodeName = await dom.selectedNode?.nodeName
    #expect(selectedNodeName == "DIV")
}

@Test
func domProtocolDispatchingFrameDocumentRefreshOnlyUpdatesFrameTargetDocument() async throws {
    let dom = await DOMSession()
    try await TargetProtocolEventDispatcher().dispatch(
        ProtocolEvent(
            sequence: 1,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("page-main"),
            paramsData: Data(#"{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}"#.utf8)
        ),
        to: dom
    )
    try await TargetProtocolEventDispatcher().dispatch(
        ProtocolEvent(
            sequence: 2,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("frame-ad"),
            paramsData: Data(#"{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}"#.utf8)
        ),
        to: dom
    )
    try await DOMProtocolCommands().applyGetDocumentResult(
        ProtocolCommand.Result(
            domain: .dom,
            method: "DOM.getDocument",
            targetID: .init("page-main"),
            resultData: Data(##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","children":[{"nodeId":2,"nodeType":1,"nodeName":"IFRAME","localName":"iframe","frameId":"ad-frame"}]}}"##.utf8)
        ),
        to: dom
    )
    let firstFrameRoot = try #require(
        await DOMProtocolCommands().applyGetDocumentResult(
            ProtocolCommand.Result(
                domain: .dom,
                method: "DOM.getDocument",
                targetID: .init("frame-ad"),
                resultData: Data(##"{"root":{"nodeId":10,"nodeType":9,"nodeName":"#document","children":[{"nodeId":11,"nodeType":1,"nodeName":"HTML","localName":"html"}]}}"##.utf8)
            ),
            to: dom
        )
    )
    let before = await dom.snapshot()
    let pageDocumentID = try #require(before.targetsByID[ProtocolTarget.ID("page-main")]?.currentDocumentID)
    let frameDocumentID = try #require(before.targetsByID[ProtocolTarget.ID("frame-ad")]?.currentDocumentID)

    let secondFrameRoot = try #require(
        await DOMProtocolCommands().applyGetDocumentResult(
            ProtocolCommand.Result(
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
    #expect(after.targetsByID[ProtocolTarget.ID("page-main")]?.currentDocumentID == pageDocumentID)
    #expect(after.targetsByID[ProtocolTarget.ID("frame-ad")]?.currentDocumentID != frameDocumentID)
    #expect(after.nodesByID[firstFrameRoot]?.nodeName == nil)
}

@Test
func domProtocolDispatchingAmbiguousTargetCommitDoesNotOverwriteExistingTargetMetadata() async throws {
    let dom = await DOMSession()
    try await TargetProtocolEventDispatcher().dispatch(
        ProtocolEvent(
            sequence: 1,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("frame-ad"),
            paramsData: Data(#"{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}"#.utf8)
        ),
        to: dom
    )

    try await TargetProtocolEventDispatcher().dispatch(
        ProtocolEvent(
            sequence: 2,
            domain: .target,
            method: "Target.didCommitProvisionalTarget",
            targetID: .init("frame-ad"),
            paramsData: Data(#"{"newTargetId":"frame-ad"}"#.utf8)
        ),
        to: dom
    )
    let snapshot = await dom.snapshot()

    #expect(snapshot.targetsByID[ProtocolTarget.ID("frame-ad")]?.kind == .frame)
    #expect(snapshot.targetsByID[ProtocolTarget.ID("frame-ad")]?.frameID == ProtocolFrame.ID("ad-frame"))
    #expect(snapshot.currentPageTargetID == nil)
}

@Test
func domProtocolDispatchingPageTargetWithParentFrameIsClassifiedAsFrame() async throws {
    let dom = await DOMSession()
    try await TargetProtocolEventDispatcher().dispatch(
        ProtocolEvent(
            sequence: 1,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("iframe-page"),
            paramsData: Data(#"{"targetInfo":{"targetId":"iframe-page","type":"page","frameId":"child-frame","parentFrameId":"main-frame","isProvisional":false}}"#.utf8)
        ),
        to: dom
    )
    let snapshot = await dom.snapshot()

    #expect(snapshot.targetsByID[ProtocolTarget.ID("iframe-page")]?.kind == .frame)
    #expect(snapshot.currentPageTargetID == nil)
    #expect(snapshot.framesByID[ProtocolFrame.ID("child-frame")]?.targetID == ProtocolTarget.ID("iframe-page"))
}

@Test
func domProtocolDispatchingPageTargetWithKnownNonMainFrameIsClassifiedAsFrame() async throws {
    let dom = await DOMSession()
    try await TargetProtocolEventDispatcher().dispatch(
        ProtocolEvent(
            sequence: 1,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("page-main"),
            paramsData: Data(#"{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}"#.utf8)
        ),
        to: dom
    )
    try await TargetProtocolEventDispatcher().dispatch(
        ProtocolEvent(
            sequence: 2,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("iframe-page"),
            paramsData: Data(#"{"targetInfo":{"targetId":"iframe-page","type":"page","frameId":"child-frame","isProvisional":false}}"#.utf8)
        ),
        to: dom
    )
    let snapshot = await dom.snapshot()

    #expect(snapshot.currentPageTargetID == ProtocolTarget.ID("page-main"))
    #expect(snapshot.targetsByID[ProtocolTarget.ID("iframe-page")]?.kind == .frame)
    #expect(snapshot.framesByID[ProtocolFrame.ID("child-frame")]?.targetID == ProtocolTarget.ID("iframe-page"))
}

@Test
func domProtocolDispatchingPageTargetWithoutFrameIDCanCommitAsCurrentPage() async throws {
    let dom = await DOMSession()
    try await TargetProtocolEventDispatcher().dispatch(
        ProtocolEvent(
            sequence: 1,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("page-old"),
            paramsData: Data(#"{"targetInfo":{"targetId":"page-old","type":"page","frameId":"main-frame","isProvisional":false}}"#.utf8)
        ),
        to: dom
    )
    try await TargetProtocolEventDispatcher().dispatch(
        ProtocolEvent(
            sequence: 2,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("page-new"),
            paramsData: Data(#"{"targetInfo":{"targetId":"page-new","type":"page","isProvisional":true}}"#.utf8)
        ),
        to: dom
    )
    try await TargetProtocolEventDispatcher().dispatch(
        ProtocolEvent(
            sequence: 3,
            domain: .target,
            method: "Target.didCommitProvisionalTarget",
            targetID: .init("page-new"),
            paramsData: Data(#"{"oldTargetId":"page-old","newTargetId":"page-new"}"#.utf8)
        ),
        to: dom
    )
    let snapshot = await dom.snapshot()

    #expect(snapshot.currentPageTargetID == ProtocolTarget.ID("page-new"))
    #expect(snapshot.targetsByID[ProtocolTarget.ID("page-new")]?.kind == .page)
    #expect(snapshot.targetsByID[ProtocolTarget.ID("page-new")]?.isProvisional == false)
}

@Test
func domProtocolDispatchingCommittedTopLevelProvisionalPageBecomesCurrentPage() async throws {
    let dom = await DOMSession()
    try await TargetProtocolEventDispatcher().dispatch(
        ProtocolEvent(
            sequence: 1,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("page-old"),
            paramsData: Data(#"{"targetInfo":{"targetId":"page-old","type":"page","frameId":"main-frame","isProvisional":false}}"#.utf8)
        ),
        to: dom
    )

    try await TargetProtocolEventDispatcher().dispatch(
        ProtocolEvent(
            sequence: 2,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("page-main"),
            paramsData: Data(#"{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":true}}"#.utf8)
        ),
        to: dom
    )
    #expect(await dom.snapshot().currentPageTargetID == ProtocolTarget.ID("page-old"))

    try await TargetProtocolEventDispatcher().dispatch(
        ProtocolEvent(
            sequence: 3,
            domain: .target,
            method: "Target.didCommitProvisionalTarget",
            targetID: .init("page-main"),
            paramsData: Data(#"{"oldTargetId":"page-old","newTargetId":"page-main"}"#.utf8)
        ),
        to: dom
    )
    let snapshot = await dom.snapshot()

    #expect(snapshot.currentPageTargetID == ProtocolTarget.ID("page-main"))
    #expect(snapshot.mainFrameID == ProtocolFrame.ID("main-frame"))
}

@Test
func domProtocolDispatchingOldlessCommittedProvisionalPageWithoutMainContextStaysFrameScoped() async throws {
    let dom = await DOMSession()
    try await TargetProtocolEventDispatcher().dispatch(
        ProtocolEvent(
            sequence: 1,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("page-main"),
            paramsData: Data(#"{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":true}}"#.utf8)
        ),
        to: dom
    )
    #expect(await dom.snapshot().currentPageTargetID == nil)

    try await TargetProtocolEventDispatcher().dispatch(
        ProtocolEvent(
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
    #expect(snapshot.targetsByID[ProtocolTarget.ID("page-main")]?.kind == .frame)
    #expect(snapshot.targetsByID[ProtocolTarget.ID("page-main")]?.isProvisional == false)
}

@Test
func domProtocolDispatchingOldlessCommitInfersSoleProvisionalFrameTarget() async throws {
    let dom = await DOMSession()
    try await TargetProtocolEventDispatcher().dispatch(
        ProtocolEvent(
            sequence: 1,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("page-provisional"),
            paramsData: Data(#"{"targetInfo":{"targetId":"page-provisional","type":"page","frameId":"main-frame","isProvisional":true}}"#.utf8)
        ),
        to: dom
    )

    try await TargetProtocolEventDispatcher().dispatch(
        ProtocolEvent(
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
    #expect(snapshot.targetsByID[ProtocolTarget.ID("page-provisional")] == nil)
    #expect(snapshot.targetsByID[ProtocolTarget.ID("page-main")]?.kind == .frame)
    #expect(snapshot.targetsByID[ProtocolTarget.ID("page-main")]?.frameID == ProtocolFrame.ID("main-frame"))
    #expect(snapshot.targetsByID[ProtocolTarget.ID("page-main")]?.isProvisional == false)
}

@Test
func domProtocolDispatchingCommittedSecondaryPageDoesNotReplaceCurrentPage() async throws {
    let dom = await DOMSession()
    try await TargetProtocolEventDispatcher().dispatch(
        ProtocolEvent(
            sequence: 1,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("page-main"),
            paramsData: Data(#"{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}"#.utf8)
        ),
        to: dom
    )
    try await TargetProtocolEventDispatcher().dispatch(
        ProtocolEvent(
            sequence: 2,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("page-popup-provisional"),
            paramsData: Data(#"{"targetInfo":{"targetId":"page-popup-provisional","type":"page","frameId":"popup-frame","isProvisional":true}}"#.utf8)
        ),
        to: dom
    )

    try await TargetProtocolEventDispatcher().dispatch(
        ProtocolEvent(
            sequence: 3,
            domain: .target,
            method: "Target.didCommitProvisionalTarget",
            targetID: .init("page-popup"),
            paramsData: Data(#"{"oldTargetId":"page-popup-provisional","newTargetId":"page-popup"}"#.utf8)
        ),
        to: dom
    )
    let snapshot = await dom.snapshot()

    #expect(snapshot.currentPageTargetID == ProtocolTarget.ID("page-main"))
    #expect(snapshot.targetsByID[ProtocolTarget.ID("page-popup")]?.frameID == ProtocolFrame.ID("popup-frame"))
}

@Test
func domProtocolDispatchingSubframeCommitDoesNotConsumeCurrentMainPage() async throws {
    let dom = await DOMSession()
    try await TargetProtocolEventDispatcher().dispatch(
        ProtocolEvent(
            sequence: 1,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("page-main"),
            paramsData: Data(#"{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}"#.utf8)
        ),
        to: dom
    )
    try await TargetProtocolEventDispatcher().dispatch(
        ProtocolEvent(
            sequence: 2,
            domain: .target,
            method: "Target.targetCreated",
            targetID: .init("frame-committed"),
            paramsData: Data(#"{"targetInfo":{"targetId":"frame-committed","type":"frame","frameId":"child-frame","parentFrameId":"main-frame","isProvisional":true}}"#.utf8)
        ),
        to: dom
    )

    try await TargetProtocolEventDispatcher().dispatch(
        ProtocolEvent(
            sequence: 3,
            domain: .target,
            method: "Target.didCommitProvisionalTarget",
            targetID: .init("frame-committed"),
            paramsData: Data(#"{"oldTargetId":"page-main","newTargetId":"frame-committed"}"#.utf8)
        ),
        to: dom
    )
    let snapshot = await dom.snapshot()

    #expect(snapshot.currentPageTargetID == ProtocolTarget.ID("page-main"))
    #expect(snapshot.targetsByID[ProtocolTarget.ID("page-main")]?.kind == .page)
    #expect(snapshot.targetsByID[ProtocolTarget.ID("frame-committed")]?.isProvisional == false)
}

@Test
func networkCommandIntentRoutesThroughRequestTarget() throws {
    let requestKey = NetworkRequest.ID(
        targetID: .init("frame-ad"),
        requestID: .init("request-1")
    )
    let bodyCommand = try NetworkProtocolCommands().command(
        for: .getResponseBody(requestKey: requestKey, backendResourceIdentifier: nil)
    )
    let certificateCommand = try NetworkProtocolCommands().command(
        for: .getSerializedCertificate(requestKey: requestKey, backendResourceIdentifier: nil)
    )

    #expect(bodyCommand.method == "Network.getResponseBody")
    #expect(bodyCommand.routing == .target(.init("frame-ad")))
    #expect(certificateCommand.method == "Network.getSerializedCertificate")
    #expect(certificateCommand.routing == .target(.init("frame-ad")))
    #expect(String(data: bodyCommand.parametersData, encoding: .utf8)?.contains(#""requestId":"request-1""#) == true)
}

@Test
func domHighlightCommandUsesNonRevealingVisibleHighlightConfig() throws {
    let command = try DOMProtocolCommands().command(
        for: .highlightNode(
            target: .init(
                nodeID: DOMNode.ID(
                    documentID: DOMDocument.ID(targetID: .init("page-A"), localDocumentLifetimeID: .init(1)),
                    nodeID: .init(42)
                ),
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
    let targetID = ProtocolTarget.ID("page-A")

    let enablePicker = try DOMProtocolCommands().command(
        for: .setInspectModeEnabled(targetID: targetID, enabled: true)
    )
    let enableParameters = try jsonObject(from: enablePicker.parametersData)
    #expect(enablePicker.method == "DOM.setInspectModeEnabled")
    #expect(enablePicker.routing == .target(targetID))
    #expect(enableParameters["enabled"] as? Bool == true)
    #expect(hasVisibleHighlightConfig(enableParameters["highlightConfig"] as? [String: Any]) == true)

    let disablePicker = try DOMProtocolCommands().command(
        for: .setInspectModeEnabled(targetID: targetID, enabled: false)
    )
    let disableParameters = try jsonObject(from: disablePicker.parametersData)
    #expect(disablePicker.method == "DOM.setInspectModeEnabled")
    #expect(disableParameters["enabled"] as? Bool == false)
    #expect(disableParameters["highlightConfig"] == nil)

    let identity = DOMAction.Target(
        nodeID: DOMNode.ID(
            documentID: DOMDocument.ID(targetID: targetID, localDocumentLifetimeID: .init(1)),
            nodeID: .init(42)
        ),
        documentTargetID: targetID,
        rawNodeID: .init(42),
        commandTargetID: targetID,
        commandNodeID: .protocolNode(.init(42))
    )

    let outerHTML = try DOMProtocolCommands().command(for: .getOuterHTML(target: identity))
    #expect(outerHTML.method == "DOM.getOuterHTML")
    #expect(integerValue(try jsonObject(from: outerHTML.parametersData)["nodeId"]) == 42)

    let removeNode = try DOMProtocolCommands().command(for: .removeNode(target: identity))
    #expect(removeNode.method == "DOM.removeNode")
    #expect(integerValue(try jsonObject(from: removeNode.parametersData)["nodeId"]) == 42)

    #expect(try DOMProtocolCommands().command(for: .undo(targetID: targetID)).method == "DOM.undo")
    #expect(try DOMProtocolCommands().command(for: .redo(targetID: targetID)).method == "DOM.redo")
}

@Test
func domActionCommandsEncodeScopedCommandNodeIDs() throws {
    let identity = DOMAction.Target(
        nodeID: DOMNode.ID(
            documentID: DOMDocument.ID(targetID: .init("frame-A"), localDocumentLifetimeID: .init(1)),
            nodeID: .init(42)
        ),
        documentTargetID: .init("frame-A"),
        rawNodeID: .init(42),
        commandTargetID: .init("page-main"),
        commandNodeID: .scoped(targetID: .init("frame-A"), nodeID: .init(42))
    )

    let outerHTML = try DOMProtocolCommands().command(for: .getOuterHTML(target: identity))
    let outerHTMLParameters = try jsonObject(from: outerHTML.parametersData)
    #expect(outerHTML.routing == .target(.init("page-main")))
    #expect(outerHTMLParameters["nodeId"] as? String == "frame-A:42")

    let removeNode = try DOMProtocolCommands().command(for: .removeNode(target: identity))
    let removeNodeParameters = try jsonObject(from: removeNode.parametersData)
    #expect(removeNode.routing == .target(.init("page-main")))
    #expect(removeNodeParameters["nodeId"] as? String == "frame-A:42")
}

@Test
func domProtocolDispatchingDecodesOuterHTMLResultAndInspectEvents() throws {
    let html = try DOMProtocolCommands().outerHTML(
        from: ProtocolCommand.Result(
            domain: .dom,
            method: "DOM.getOuterHTML",
            targetID: .init("page-A"),
            resultData: Data(#"{"outerHTML":"<main></main>"}"#.utf8)
        )
    )
    #expect(html == "<main></main>")

    let domInspect = try DOMProtocolCommands().inspectEvent(
        from: ProtocolEvent(
            sequence: 1,
            domain: .dom,
            method: "DOM.inspect",
            targetID: .init("page-A"),
            paramsData: Data(#"{"nodeId":42}"#.utf8)
        )
    )
    #expect(domInspect == .protocolNode(targetID: .init("page-A"), nodeID: .init(42)))

    let inspectorInspect = try DOMProtocolCommands().inspectEvent(
        from: ProtocolEvent(
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

    let targetScopedInspectorInspect = try DOMProtocolCommands().inspectEvent(
        from: ProtocolEvent(
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

private final class ProtocolEventRecorder: Sendable {
    private let storage = ProtocolEventRecorderStorage()
    private let task: Task<Void, Never>

    init(stream: AsyncStream<ProtocolEvent>) {
        let storage = self.storage
        task = Task {
            for await event in stream {
                await storage.record(event)
            }
            await storage.finish()
        }
    }

    deinit {
        task.cancel()
    }

    func event(at index: Int = 0, timeout: Duration = testWaitTimeout) async throws -> ProtocolEvent {
        try await storage.event(at: index, timeout: timeout)
    }

    func events(prefix count: Int, timeout: Duration = testWaitTimeout) async throws -> [ProtocolEvent] {
        try await storage.events(prefix: count, timeout: timeout)
    }
}

private actor ProtocolEventRecorderStorage {
    private struct CountWaiter: Sendable {
        var count: Int
        var continuation: CheckedContinuation<Bool, Never>
        var timeoutTask: Task<Void, Never>?
    }

    private var events: [ProtocolEvent] = []
    private var waiters: [UInt64: CountWaiter] = [:]
    private var nextWaiterID: UInt64 = 0
    private var isFinished = false

    func record(_ event: ProtocolEvent) {
        events.append(event)
        resumeReadyWaiters()
    }

    func finish() {
        isFinished = true
        resumeReadyWaiters()
    }

    func event(at index: Int, timeout: Duration) async throws -> ProtocolEvent {
        guard await waitUntilCount(index + 1, timeout: timeout) else {
            throw TransportSession.Error.replyTimeout(method: "test event", targetID: nil)
        }
        return events[index]
    }

    func events(prefix count: Int, timeout: Duration) async throws -> [ProtocolEvent] {
        guard await waitUntilCount(count, timeout: timeout) else {
            throw TransportSession.Error.replyTimeout(method: "test events", targetID: nil)
        }
        return Array(events.prefix(count))
    }

    private func waitUntilCount(_ count: Int, timeout: Duration) async -> Bool {
        if events.count >= count {
            return true
        }
        if isFinished {
            return false
        }

        nextWaiterID &+= 1
        let waiterID = nextWaiterID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                registerWaiter(
                    id: waiterID,
                    count: count,
                    timeout: timeout,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID)
            }
        }
    }

    private func registerWaiter(
        id: UInt64,
        count: Int,
        timeout: Duration,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        if events.count >= count {
            continuation.resume(returning: true)
            return
        }
        if isFinished {
            continuation.resume(returning: false)
            return
        }

        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            timeoutWaiter(id)
        }
        waiters[id] = CountWaiter(
            count: count,
            continuation: continuation,
            timeoutTask: timeoutTask
        )
    }

    private func resumeReadyWaiters() {
        let readyWaiterIDs = waiters.compactMap { id, waiter in
            events.count >= waiter.count || isFinished ? id : nil
        }
        for waiterID in readyWaiterIDs {
            guard let waiter = waiters[waiterID] else {
                continue
            }
            resolveWaiter(waiterID, returning: events.count >= waiter.count)
        }
    }

    private func timeoutWaiter(_ id: UInt64) {
        resolveWaiter(id, returning: false)
    }

    private func cancelWaiter(_ id: UInt64) {
        resolveWaiter(id, returning: false)
    }

    private func resolveWaiter(_ id: UInt64, returning value: Bool) {
        guard let waiter = waiters.removeValue(forKey: id) else {
            return
        }
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(returning: value)
    }
}

private func waitForRootMessage(_ backend: FakeTransportBackend, timeout: Duration = testWaitTimeout) async throws -> String {
    try await waitForBackendValue(timeout: timeout) {
        try await backend.waitForMessage()
    }
}

private func waitForTargetMessage(_ backend: FakeTransportBackend, timeout: Duration = testWaitTimeout) async throws -> SentTargetMessage {
    try await waitForBackendValue(timeout: timeout) {
        try await backend.waitForTargetMessage()
    }
}

private func waitForBackendValue<Value: Sendable>(
    timeout: Duration,
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        defer {
            group.cancelAll()
        }

        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TransportSession.Error.replyTimeout(method: "test wait", targetID: nil)
        }

        guard let value = try await group.next() else {
            throw TransportSession.Error.replyTimeout(method: "test wait", targetID: nil)
        }
        return value
    }
}

private actor ManualResponseTimeout {
    private var nextSleepID: UInt64 = 0
    private var continuations: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var nextSuspensionID: UInt64 = 0
    private var suspensionContinuations: [UInt64: SuspensionContinuation] = [:]
    private var handledTimeoutCount: Int = 0
    private var handledTimeoutContinuation: CheckedContinuation<Void, Never>?

    private struct SuspensionContinuation {
        var minimumSleeps: Int
        var continuation: CheckedContinuation<Void, Never>
    }

    func sleep(for _: Duration) async throws {
        nextSleepID &+= 1
        let sleepID = nextSleepID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[sleepID] = continuation
                let suspensionContinuations = popReadySuspensionContinuations()
                for suspensionContinuation in suspensionContinuations {
                    suspensionContinuation.resume()
                }
            }
        } onCancel: {
            Task {
                await self.cancel(sleepID)
            }
        }
    }

    func fireNext() {
        guard let sleepID = continuations.keys.sorted().first,
              let continuation = continuations.removeValue(forKey: sleepID) else {
            return
        }
        continuation.resume()
    }

    func waitUntilSuspended(by minimumSleeps: Int = 1) async {
        precondition(minimumSleeps > 0, "minimumSleeps must be positive")
        guard continuations.count < minimumSleeps else {
            return
        }

        nextSuspensionID &+= 1
        let suspensionID = nextSuspensionID
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if continuations.count >= minimumSleeps {
                    continuation.resume()
                } else {
                    suspensionContinuations[suspensionID] = SuspensionContinuation(
                        minimumSleeps: minimumSleeps,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelSuspension(suspensionID)
            }
        }
    }

    func recordHandledTimeout() {
        handledTimeoutCount += 1
        handledTimeoutContinuation?.resume()
        handledTimeoutContinuation = nil
    }

    func waitUntilHandledTimeout() async {
        guard handledTimeoutCount == 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            if handledTimeoutCount > 0 {
                continuation.resume()
            } else {
                handledTimeoutContinuation = continuation
            }
        }
    }

    private func cancel(_ sleepID: UInt64) {
        guard let continuation = continuations.removeValue(forKey: sleepID) else {
            return
        }
        continuation.resume(throwing: CancellationError())
    }

    private func cancelSuspension(_ suspensionID: UInt64) {
        guard let continuation = suspensionContinuations.removeValue(forKey: suspensionID)?.continuation else {
            return
        }
        continuation.resume()
    }

    private func popReadySuspensionContinuations() -> [CheckedContinuation<Void, Never>] {
        let readySuspensionIDs = suspensionContinuations.compactMap { suspensionID, suspensionContinuation in
            continuations.count >= suspensionContinuation.minimumSleeps ? suspensionID : nil
        }
        return readySuspensionIDs.compactMap { suspensionID in
            suspensionContinuations.removeValue(forKey: suspensionID)?.continuation
        }
    }
}

private func receiveTargetDispatch(
    _ session: TransportSession,
    targetID: ProtocolTarget.ID,
    message: String
) async {
    await session.receiveRootMessage(targetDispatchMessage(targetID: targetID, message: message))
}

private func targetDispatchMessage(
    targetID: ProtocolTarget.ID,
    message: String
) -> String {
    let escapedTargetID = jsonEscapedString(targetID.rawValue)
    let escapedMessage = jsonEscapedString(message)
    return #"{"method":"Target.dispatchMessageFromTarget","params":{"targetId":"\#(escapedTargetID)","message":"\#(escapedMessage)"}}"#
}

private func targetCommandWrapperMessage(
    outerID: UInt64,
    targetID: ProtocolTarget.ID = .init("page-main"),
    innerID: UInt64,
    method: String
) -> String {
    let escapedTargetID = jsonEscapedString(targetID.rawValue)
    let escapedMessage = jsonEscapedString(#"{"id":\#(innerID),"method":"\#(method)"}"#)
    return #"{"id":\#(outerID),"method":"Target.sendMessageToTarget","params":{"targetId":"\#(escapedTargetID)","message":"\#(escapedMessage)"}}"#
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
    throw TransportSession.Error.malformedMessage
}

private func messageMethod(_ message: String) throws -> String? {
    let data = try #require(message.data(using: .utf8))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return object["method"] as? String
}

private func jsonObject(from data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func contextKey(_ runtimeAgentTargetID: String, _ contextID: Int) -> RuntimeContext.Key {
    RuntimeContext.Key(
        runtimeAgentTargetID: ProtocolTarget.ID(runtimeAgentTargetID),
        contextID: RuntimeContext.ID(contextID)
    )
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
