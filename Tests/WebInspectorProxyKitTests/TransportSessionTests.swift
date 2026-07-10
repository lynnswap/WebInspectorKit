import Foundation
import Testing
import WebInspectorTestSupport
@testable import WebInspectorProxyKit

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
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":2,"nodes":[{"nodeId":3,"nodeType":1,"nodeName":"DIV","localName":"div","nodeValue":""}]}}"#
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
func targetCommandCancellationFailsPendingReplyWithoutTimeout() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: nil)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)

    let sendTask = Task {
        try await session.send(
            ProtocolCommand(domain: .css, method: "CSS.getMatchedStylesForNode", routing: .target(.init("page-main")))
        )
    }
    let sent = try await waitForTargetMessage(backend)
    let innerID = try messageID(sent.message)
    #expect(await session.snapshot().pendingTargetReplyKeys == [
        TransportSession.ReplyKey(targetID: .init("page-main"), commandID: innerID),
    ])

    sendTask.cancel()

    do {
        _ = try await waitForBackendValue(timeout: testWaitTimeout) {
            try await sendTask.value
        }
        Issue.record("Expected cancellation")
    } catch is CancellationError {
    } catch {
        Issue.record("Expected CancellationError, got \(error)")
    }
    #expect(await session.snapshot().pendingTargetReplyKeys.isEmpty)
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
func eventStreamsRequestedAfterDetachFinishImmediately() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: testResponseTimeout)

    await session.detach()

    let domainStream = await session.events(for: .dom)
    let orderedStream = await session.orderedEvents()

    #expect(try await nextEvent(from: domainStream) == nil)
    #expect(try await nextEvent(from: orderedStream) == nil)
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
func provisionalPageTargetWithKnownNonMainFrameIsClassifiedAsFrame() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-existing","type":"frame","frameId":"child-frame","parentFrameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"iframe-page-provisional","type":"page","frameId":"child-frame","isProvisional":true}}}"#)
    let snapshot = await session.snapshot()

    #expect(snapshot.currentMainPageTargetID == ProtocolTarget.ID("page-main"))
    #expect(snapshot.targetsByID[ProtocolTarget.ID("iframe-page-provisional")]?.kind == .frame)
}

@Test
func provisionalPageCommitWithNonMainFrameDoesNotRetargetCurrentPage() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"iframe-page-provisional","type":"page","frameId":"child-frame","isProvisional":true}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"missing-old-frame","newTargetId":"iframe-page-provisional"}}"#)
    let snapshot = await session.snapshot()

    #expect(snapshot.currentMainPageTargetID == ProtocolTarget.ID("page-main"))
    #expect(snapshot.targetsByID[ProtocolTarget.ID("page-main")] != nil)
    #expect(snapshot.targetsByID[ProtocolTarget.ID("iframe-page-provisional")]?.isProvisional == false)
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
func provisionalPageTargetWithChangedFrameIDCommitsAsCurrentPage() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-old","type":"page","frameId":"old-main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-new","type":"page","frameId":"new-main-frame","isProvisional":true}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-old","newTargetId":"page-new"}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetDestroyed","params":{"targetId":"page-old"}}"#)
    let snapshot = await session.snapshot()

    #expect(snapshot.currentMainPageTargetID == ProtocolTarget.ID("page-new"))
    #expect(snapshot.targetsByID[ProtocolTarget.ID("page-new")]?.kind == .page)
    #expect(snapshot.targetsByID[ProtocolTarget.ID("page-new")]?.frameID == ProtocolFrame.ID("new-main-frame"))
    #expect(snapshot.targetsByID[ProtocolTarget.ID("page-new")]?.isProvisional == false)
    #expect(snapshot.targetsByID[ProtocolTarget.ID("page-old")] == nil)
    #expect(snapshot.frameTargetIDsByFrameID[ProtocolFrame.ID("old-main-frame")] == nil)
    #expect(snapshot.frameTargetIDsByFrameID[ProtocolFrame.ID("new-main-frame")] == ProtocolTarget.ID("page-new"))
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
func targetCommitFailsPendingRepliesForOldBindingAsStale() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: testResponseTimeout)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-next","type":"page","frameId":"main-frame","isProvisional":true}}}"#)

    let sendTask = Task {
        try await session.send(
            ProtocolCommand(domain: .dom, method: "DOM.getDocument", routing: .target(.init("page-main")))
        )
    }
    _ = try await waitForTargetMessage(backend)

    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"page-next"}}"#)

    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        try await sendTask.value
    }
    #expect(await session.snapshot().pendingTargetReplyKeys.isEmpty)
}

@Test
func targetCommitFailsDirectCommandsForOldMainAndFrameBinding() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: testResponseTimeout)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-child","type":"frame","frameId":"child-frame","parentFrameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-next","type":"page","frameId":"main-frame","isProvisional":true}}}"#)

    let mainTask = Task {
        try await session.send(ProtocolCommand(
            domain: .page,
            method: "Page.reload",
            routing: .target(.init("page-main"))
        ))
    }
    let frameTask = Task {
        try await session.send(ProtocolCommand(
            domain: .page,
            method: "Page.reload",
            routing: .target(.init("frame-child"))
        ))
    }
    _ = try await backend.waitForTargetMessage(method: "Page.reload", ordinal: 0)
    _ = try await backend.waitForTargetMessage(method: "Page.reload", ordinal: 1)

    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"page-next"}}"#)

    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        try await mainTask.value
    }
    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        try await frameTask.value
    }
    #expect(await session.snapshot().pendingTargetReplyKeys.isEmpty)
    await session.close()
}

@Test
func documentUpdatedFailsDirectDOMAndCSSButPreservesNetworkCommand() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: testResponseTimeout)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)

    let domTask = Task {
        try await session.send(ProtocolCommand(
            domain: .dom,
            method: "DOM.querySelector",
            routing: .target(.init("page-main"))
        ))
    }
    let cssTask = Task {
        try await session.send(ProtocolCommand(
            domain: .css,
            method: "CSS.getMatchedStylesForNode",
            routing: .target(.init("page-main"))
        ))
    }
    let networkTask = Task {
        try await session.send(ProtocolCommand(
            domain: .network,
            method: "Network.getResponseBody",
            routing: .target(.init("page-main"))
        ))
    }
    let dom = try await backend.waitForTargetMessage(method: "DOM.querySelector")
    let css = try await backend.waitForTargetMessage(method: "CSS.getMatchedStylesForNode")
    let network = try await backend.waitForTargetMessage(method: "Network.getResponseBody")

    await receiveTargetDispatch(
        session,
        targetID: .init("page-main"),
        message: #"{"method":"DOM.documentUpdated","params":{}}"#
    )
    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        try await domTask.value
    }
    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        try await cssTask.value
    }
    await receiveTargetDispatch(
        session,
        targetID: dom.targetIdentifier,
        message: #"{"id":\#(try messageID(dom.message)),"result":{}}"#
    )
    await receiveTargetDispatch(
        session,
        targetID: css.targetIdentifier,
        message: #"{"id":\#(try messageID(css.message)),"result":{}}"#
    )
    await receiveTargetDispatch(
        session,
        targetID: network.targetIdentifier,
        message: #"{"id":\#(try messageID(network.message)),"result":{}}"#
    )
    _ = try await networkTask.value
    #expect(await session.snapshot().pendingTargetReplyKeys.isEmpty)
    await session.close()
}

@Test
func provisionalTargetReplyIsBufferedUntilCommit() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, responseTimeout: testResponseTimeout)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-next","type":"page","frameId":"main-frame","isProvisional":true}}}"#)

    let sendTask = Task {
        try await session.send(
            ProtocolCommand(domain: .dom, method: "DOM.getDocument", routing: .target(.init("page-next")))
        )
    }
    let sent = try await waitForTargetMessage(backend)
    let innerID = try messageID(sent.message)

    await receiveTargetDispatch(
        session,
        targetID: .init("page-next"),
        message: ##"{"id":\##(innerID),"result":{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document"}}}"##
    )
    #expect(await session.snapshot().pendingTargetReplyKeys == [
        TransportSession.ReplyKey(targetID: .init("page-next"), commandID: innerID),
    ])

    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"page-next"}}"#)
    let result = try await sendTask.value

    #expect(result.targetID == ProtocolTarget.ID("page-next"))
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
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-next","type":"page","frameId":"main-frame","isProvisional":true}}}"#)

    let sendTask = Task {
        try await session.send(
            ProtocolCommand(domain: .dom, method: "DOM.getDocument", routing: .target(.init("page-next")))
        )
    }
    let sent = try await waitForTargetMessage(backend)
    let innerID = try messageID(sent.message)

    await receiveTargetDispatch(
        session,
        targetID: .init("page-next"),
        message: ##"{"id":\##(innerID),"result":{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document"}}}"##
    )
    await responseTimeout.waitUntilSuspended()
    await responseTimeout.fireNext()
    await responseTimeout.waitUntilHandledTimeout()

    #expect(await session.snapshot().pendingTargetReplyKeys == [
        TransportSession.ReplyKey(targetID: .init("page-next"), commandID: innerID),
    ])

    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"page-next"}}"#)
    let result = try await sendTask.value

    #expect(result.targetID == ProtocolTarget.ID("page-next"))
    #expect(await session.snapshot().pendingTargetReplyKeys.isEmpty)
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
func oldBindingPendingReplyFailsAsStaleAtCommitBeforeTimeout() async throws {
    let backend = FakeTransportBackend()
    let responseTimeout = ManualResponseTimeout()
    let session = TransportSession(
        backend: backend,
        responseTimeout: .milliseconds(20),
        timeoutSleep: { duration in
            try await responseTimeout.sleep(for: duration)
        }
    )
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-next","type":"page","frameId":"main-frame","isProvisional":true}}}"#)

    let sendTask = Task {
        try await session.send(
            ProtocolCommand(domain: .dom, method: "DOM.getDocument", routing: .target(.init("page-main")))
        )
    }
    _ = try await waitForTargetMessage(backend)
    await responseTimeout.waitUntilSuspended()

    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"page-next"}}"#)

    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        try await sendTask.value
    }
    #expect(await session.snapshot().pendingTargetReplyKeys.isEmpty)
}

@Test
func ambiguousTargetCommitPreservesExistingMetadataAndDoesNotInventTarget() async throws {
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend)

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-existing","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#)
    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"missing-old","newTargetId":"frame-existing"}}"#)
    await session.receiveRootMessage(#"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"another-missing-old","newTargetId":"missing-target"}}"#)
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
    await session.receiveRootMessage(#"{"method":"Console.messageAdded","params":{"message":{"source":"javascript","level":"log","text":"hello"}}}"#)
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
    await receiveTargetDispatch(session, targetID: .init("frame-A"), message: #"{"method":"Console.messageAdded","params":{"message":{"source":"javascript","level":"log","text":"hello"}}}"#)
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
    await session.receiveRootMessage(#"{"method":"CSS.styleSheetAdded","params":{"header":{"styleSheetId":"sheet-frame","frameId":"frame-A","origin":"author"}}}"#)
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
    await session.receiveRootMessage(#"{"method":"CSS.styleSheetAdded","params":{"header":{"styleSheetId":"sheet-late-frame","frameId":"late-frame","origin":"author"}}}"#)
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
    await session.receiveRootMessage(#"{"method":"CSS.styleSheetAdded","params":{"header":{"styleSheetId":"sheet-provisional-frame","frameId":"ad-frame","origin":"author"}}}"#)
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
func nativeFatalCallbackOwnsTerminalCauseAndFailsPendingWork() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    let receiver = TransportReceiver()
    receiver.setCore(core)

    let sendTask = Task {
        try await core.send(
            ProtocolCommand(domain: .target, method: "Target.setPauseOnStart", routing: .root)
        )
    }
    _ = try await waitForRootMessage(backend)

    let closeWaitTask = Task {
        try await core.waitUntilClosed()
    }
    await core.waitForCloseWaiterForTesting()

    receiver.fail("native callback failed")

    await #expect(throws: TransportSession.Error.transportFailure("native callback failed")) {
        _ = try await sendTask.value
    }
    await #expect(throws: WebInspectorProxyError.disconnected("native callback failed")) {
        try await closeWaitTask.value
    }
    #expect(await core.terminalCause == .fatal("native callback failed"))
    #expect(await backend.isDetached())
    #expect(await core.snapshot().pendingRootReplyIDs.isEmpty)
}

@Test
func connectionCoreCloseIsIdempotentAndFinishesStreamsOnce() async throws {
    let backend = CountingTransportBackend()
    let core = ConnectionCore(backend: backend)
    let stream = await core.events(for: .network)
    let nextEventTask = Task {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }

    async let firstClose: Void = core.close()
    async let secondClose: Void = core.close()
    _ = await (firstClose, secondClose)

    #expect(await backend.detachCount == 1)
    #expect(await nextEventTask.value == nil)
    try await core.waitUntilClosed()
}

@Test
func receiverDoesNotKeepExplicitlyClosedConnectionCoreAlive() async {
    let backend = FakeTransportBackend()
    let receiver = TransportReceiver()
    weak var weakCore: ConnectionCore?

    do {
        let core = ConnectionCore(backend: backend)
        weakCore = core
        receiver.setCore(core)
        await core.close()
    }

    #expect(weakCore == nil)
}

@Test
func receiverDoesNotKeepDroppedConnectionCoreAlive() {
    let backend = FakeTransportBackend()
    let receiver = TransportReceiver()
    weak var weakCore: ConnectionCore?

    do {
        let core = ConnectionCore(backend: backend)
        weakCore = core
        receiver.setCore(core)
    }

    #expect(weakCore == nil)
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

private actor CountingTransportBackend: TransportBackend {
    private(set) var detachCount = 0

    func sendJSONString(_ message: String) async throws {
        _ = message
    }

    func detach() async {
        detachCount += 1
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

private func nextEvent(
    from stream: AsyncStream<ProtocolEvent>,
    timeout: Duration = testWaitTimeout
) async throws -> ProtocolEvent? {
    try await waitForBackendValue(timeout: timeout) {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
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
