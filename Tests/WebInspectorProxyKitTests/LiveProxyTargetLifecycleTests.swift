import Foundation
import Testing
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import WebInspectorTestSupport

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
func transportBackendDeliversCurrentPageTargetCommitLifecycleAfterRetarget() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(
        in: transport,
        targetID: ProtocolTarget.ID("page-old")
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()
    #expect(target.frameID == nil)

    let eventTask = Task<WebInspectorTargetLifecycleEvent?, Never> {
        var iterator = target.lifecycleEvents.makeAsyncIterator()
        while let event = await iterator.next() {
            if case .didCommitProvisionalTarget = event {
                return event
            }
        }
        return nil
    }

    await waitForEventSubscription(target, domain: .target)
    await installPageTarget(
        in: transport,
        targetID: ProtocolTarget.ID("page-new")
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-old","newTargetId":"page-new"}}"#
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .didCommitProvisionalTarget(commit) = event else {
        Issue.record("Expected Target.didCommitProvisionalTarget lifecycle event.")
        return
    }
    #expect(commit.oldTargetID == WebInspectorTarget.ID.currentPage)
    #expect(commit.newTarget.id == WebInspectorTarget.ID.currentPage)
    guard case .page = commit.newTarget.kind else {
        Issue.record("Expected committed target to remain a page.")
        return
    }
    #expect(commit.newTarget.frameID == nil)
    #expect(commit.newTarget.isProvisional == false)
    let cachedTarget = try await proxy.waitForCurrentPage()
    #expect(cachedTarget.frameID == nil)
    #expect(cachedTarget.isProvisional == false)
    #expect(await transport.snapshot().currentMainPageTargetID == ProtocolTarget.ID("page-new"))
}

@Test
func orderedCurrentPageFeedUsesEventTimeRoutingAcrossDelayedCommitDrain() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(
        backend: backend,
        protocolProfile: .latest,
        responseTimeout: .milliseconds(750)
    )
    let oldTargetID = ProtocolTarget.ID("page-old")
    let newTargetID = ProtocolTarget.ID("page-new")
    let frameTargetID = ProtocolTarget.ID("frame-42-7")
    await installPageTarget(in: transport, targetID: oldTargetID)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-42-7","type":"frame","isProvisional":false,"isPaused":false}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()
    let feed = await target.orderedEventFeed()

    await receiveTargetEvent(
        transport,
        targetID: oldTargetID,
        method: "DOM.attributeModified",
        params: #"{"nodeId":1,"name":"old","value":"1"}"#
    )
    await receiveTargetEvent(
        transport,
        targetID: oldTargetID,
        method: "Runtime.executionContextCreated",
        params: #"{"context":{"id":1,"name":"Old","type":"normal"}}"#
    )
    await receiveTargetEvent(
        transport,
        targetID: oldTargetID,
        method: "Network.requestWillBeSent",
        params: #"{"requestId":"old-request","frameId":"old-frame","loaderId":"old-loader","request":{"url":"https://example.test/old","method":"GET"},"initiator":{"type":"other"},"type":"Fetch","timestamp":1}"#
    )
    await receiveTargetEvent(
        transport,
        targetID: frameTargetID,
        method: "DOM.attributeModified",
        params: #"{"nodeId":2,"name":"frame","value":"1"}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-new","type":"page","isProvisional":true,"isPaused":false}}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-old","newTargetId":"page-new"}}"#
    )
    await receiveTargetEvent(
        transport,
        targetID: newTargetID,
        method: "DOM.attributeModified",
        params: #"{"nodeId":3,"name":"new","value":"1"}"#
    )
    await receiveTargetEvent(
        transport,
        targetID: newTargetID,
        method: "Runtime.executionContextCreated",
        params: #"{"context":{"id":2,"name":"New","type":"normal"}}"#
    )
    await receiveTargetEvent(
        transport,
        targetID: newTargetID,
        method: "Network.requestWillBeSent",
        params: #"{"requestId":"new-request","frameId":"new-frame","loaderId":"new-loader","request":{"url":"https://example.test/new","method":"GET"},"initiator":{"type":"other"},"type":"Fetch","timestamp":2}"#
    )

    var tokens: [String] = []
    for try await sequencedEvent in feed.events {
        guard let event = sequencedEvent.event else {
            continue
        }
        switch event {
        case let .dom(.attributeModified(id, name, _)):
            tokens.append("dom:\(name):\(id.targetScopeRawValue ?? "page")")
        case let .runtime(.executionContextCreated(context)):
            tokens.append("runtime:\(context.name):\(context.id.targetScopeRawValue ?? "page")")
        case let .network(.requestWillBeSent(id, _, _, _, _, _)):
            tokens.append("network:\(id.unscopedRawValue)")
        case .targetLifecycle(.didCommitProvisionalTarget):
            tokens.append("commit")
        default:
            continue
        }
        if tokens.count == 8 {
            break
        }
    }

    #expect(tokens == [
        "dom:old:page",
        "runtime:Old:page",
        "network:old-request",
        "dom:frame:frame-42-7",
        "commit",
        "dom:new:page",
        "runtime:New:page",
        "network:new-request",
    ])
}

@Test
func transportBackendDeliversCurrentPageTargetDestroyedLifecycle() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport, targetID: ProtocolTarget.ID("page-main"))
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let eventTask = Task {
        var iterator = target.lifecycleEvents.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .target)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"page-main"}}"#
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .targetDestroyed(targetID) = event else {
        Issue.record("Expected Target.targetDestroyed lifecycle event.")
        return
    }
    #expect(targetID == .currentPage)
    #expect(await transport.snapshot().currentMainPageTargetID == nil)
    #expect(await proxy.currentPage == nil)

    let replacementTask = Task {
        try await proxy.waitForCurrentPage()
    }
    await installPageTarget(in: transport, targetID: ProtocolTarget.ID("page-replacement"))
    let replacement = try await throwingValue(of: replacementTask)
    #expect(replacement.id == .currentPage)
    #expect(replacement.route == .currentPage)
    #expect(await transport.snapshot().currentMainPageTargetID == ProtocolTarget.ID("page-replacement"))
}

@Test
func transportBackendDeliversProvisionalPageDestroyedBeforePageTopology() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport, targetID: ProtocolTarget.ID("page-main"))
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-provisional","type":"page","frameId":"main-frame","isProvisional":true}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let eventTask = Task {
        var iterator = target.lifecycleEvents.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .target)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"page-provisional"}}"#
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .targetDestroyed(targetID) = event else {
        Issue.record("Expected provisional Target.targetDestroyed lifecycle event.")
        return
    }
    #expect(targetID == WebInspectorTarget.ID("page-provisional"))
    #expect(await transport.snapshot().currentMainPageTargetID == ProtocolTarget.ID("page-main"))
    #expect(await proxy.currentPage != nil)
}

@Test
func transportBackendDeliversProvisionalFrameDestroyedBeforePageTopology() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport, targetID: ProtocolTarget.ID("page-main"))
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-provisional","type":"frame","frameId":"child-frame","isProvisional":true}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let eventTask = Task {
        var iterator = target.lifecycleEvents.makeAsyncIterator()
        return await iterator.next()
    }
    defer { eventTask.cancel() }

    await waitForEventSubscription(target, domain: .target)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"frame-provisional"}}"#
    )

    let event = try #require(try await value(of: eventTask, timeout: transportCommandBackendWaitTimeout))
    guard case let .targetDestroyed(targetID) = event else {
        Issue.record("Expected parentless frame provisional Target.targetDestroyed lifecycle event.")
        return
    }
    #expect(targetID == WebInspectorTarget.ID("frame-provisional"))
    #expect(await transport.snapshot().currentMainPageTargetID == ProtocolTarget.ID("page-main"))
}

@Test
func transportBackendDoesNotDeliverWorkerTargetDestroyedLifecycleToCurrentPage() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend)
    await installPageTarget(in: transport, targetID: ProtocolTarget.ID("page-main"))
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"service-worker","type":"service-worker","isProvisional":false}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()
    let eventTask = Task {
        var iterator = target.lifecycleEvents.makeAsyncIterator()
        return (await iterator.next(), await iterator.next())
    }
    defer { eventTask.cancel() }

    await waitForEventSubscription(target, domain: .target)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"service-worker"}}"#
    )
    // The replacement creation is distinguishable from any destruction and
    // follows both destroy messages on the same FIFO feed.
    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"page-main"}}"#
    )
    await installPageTarget(in: transport, targetID: ProtocolTarget.ID("page-replacement"))
    let (first, second) = try await value(of: eventTask)
    guard case .targetDestroyed(.currentPage) = try #require(first),
          case let .unknown(replacement) = try #require(second) else {
        Issue.record("Expected only page destruction followed by replacement creation.")
        return
    }
    #expect(replacement.domain == "Target")
    #expect(replacement.method == "targetCreated")
    await proxy.close()
}

@Test
func transportBackedWaitForCurrentPageRefreshesDestroyedTargetWithoutLifecycleSubscription() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport, targetID: ProtocolTarget.ID("page-old"))
    let proxy = try await WebInspectorProxy(transport: transport)

    let cachedTarget = try await proxy.waitForCurrentPage()
    #expect(cachedTarget.frameID == nil)

    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"page-old"}}"#
    )

    let replacementTask = Task {
        try await proxy.waitForCurrentPage()
    }
    await installPageTarget(in: transport, targetID: ProtocolTarget.ID("page-new"))

    let replacement = try await throwingValue(of: replacementTask)
    #expect(replacement.id == .currentPage)
    #expect(replacement.route == .currentPage)
    #expect(replacement.frameID == nil)
    #expect(await proxy.currentPage?.frameID == nil)
}

@Test
func transportBackendDeliversCurrentPagePageFrameLifecycle() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport, targetID: ProtocolTarget.ID("page-main"))
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let eventTask = Task {
        var iterator = target.lifecycleEvents.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        return [first, second].compactMap { $0 }
    }

    await waitForEventSubscription(target, domain: .page)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Page.frameNavigated",
        params: #"{"frame":{"id":"main-frame","loaderId":"loader-1","name":"Main","url":"https://example.test/","securityOrigin":"https://example.test","mimeType":"text/html"}}"#
    )
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Page.frameDetached",
        params: #"{"frameId":"child-frame"}"#
    )

    let events = try await value(of: eventTask)
    #expect(events.count == 2)
    guard case let .frameNavigated(frame) = events[0] else {
        Issue.record("Expected Page.frameNavigated lifecycle event.")
        return
    }
    #expect(frame.id == FrameID("main-frame"))
    #expect(frame.parentID == nil)
    #expect(frame.pageBindingID == "page-main")
    #expect(frame.loaderID == "loader-1")
    #expect(frame.name == "Main")
    #expect(frame.url == "https://example.test/")
    #expect(frame.securityOrigin == "https://example.test")
    #expect(frame.mimeType == "text/html")

    guard case let .frameDetached(frameID) = events[1] else {
        Issue.record("Expected Page.frameDetached lifecycle event.")
        return
    }
    #expect(frameID == FrameID("child-frame"))
}

@Test
func transportBackendBindsRootSubframeNavigationToExactFrameTarget() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(
        backend: backend,
        protocolProfile: .latest,
        responseTimeout: .milliseconds(750)
    )
    await installPageTarget(in: transport, targetID: ProtocolTarget.ID("page-main"))
    await installMainPageFrame(in: transport)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-42-7","type":"frame","isProvisional":false,"isPaused":false}}}"#
    )
    await installFrame(
        ProtocolFrame.ID("frame-7.42"),
        parentFrameID: ProtocolFrame.ID("frame-7.1"),
        in: transport
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let eventTask = Task {
        var iterator = target.lifecycleEvents.makeAsyncIterator()
        return await iterator.next()
    }
    await waitForEventSubscription(target, domain: .page)
    await transport.receiveRootMessage(
        #"{"method":"Page.frameNavigated","params":{"frame":{"id":"frame-7.42","parentId":"frame-7.1","loaderId":"child-loader","name":"","url":"https://example.test/frame","securityOrigin":"https://example.test","mimeType":"text/html"}}}"#
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .frameNavigated(frame) = event else {
        Issue.record("Expected Page.frameNavigated lifecycle event.")
        return
    }
    #expect(frame.id == FrameID("frame-7.42"))
    #expect(frame.pageBindingID == "frame-42-7")
}

@Test
func transportBackendBindsReleasedRootSubframeNavigationToPageAgent() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport, targetID: ProtocolTarget.ID("page-main"))
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let eventTask = Task {
        var iterator = target.lifecycleEvents.makeAsyncIterator()
        return await iterator.next()
    }
    await waitForEventSubscription(target, domain: .page)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Page.frameNavigated",
        params: #"{"frame":{"id":"child-frame","parentId":"main-frame","loaderId":"child-loader","name":"","url":"https://example.test/frame","securityOrigin":"https://example.test","mimeType":"text/html"}}"#
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .frameNavigated(frame) = event else {
        Issue.record("Expected Page.frameNavigated lifecycle event.")
        return
    }
    #expect(frame.pageBindingID == "page-main")
}

@Test
func transportLeavesRootMainFrameNavigationUnboundWhilePageTargetsCompete() async throws {
    let transport = TransportSession(
        backend: FakeTransportBackend(),
        responseTimeout: .milliseconds(750)
    )
    await installPageTarget(
        in: transport,
        targetID: ProtocolTarget.ID("page-current"),
        frameID: "main-frame"
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-provisional","type":"page","frameId":"main-frame","isProvisional":true}}}"#
    )
    let stream = await transport.events(for: .page)
    var iterator = stream.makeAsyncIterator()

    await transport.receiveRootMessage(
        #"{"method":"Page.frameNavigated","params":{"frame":{"id":"main-frame","loaderId":"provisional-loader"}}}"#
    )

    let event = try #require(await iterator.next())
    #expect(event.pageBindingTargetID == nil)
}

@Test
func transportBackendDeliversLatestFrameDetachUsingEventTimeAncestry() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(
        backend: backend,
        protocolProfile: .latest,
        responseTimeout: .milliseconds(750)
    )
    await installPageTarget(in: transport)
    await installMainPageFrame(in: transport)
    await installFrame(
        ProtocolFrame.ID("frame-7.20"),
        parentFrameID: ProtocolFrame.ID("frame-7.1"),
        in: transport
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-42-7","type":"frame","isProvisional":false,"isPaused":false}}}"#
    )
    await installFrame(
        ProtocolFrame.ID("frame-7.42"),
        parentFrameID: ProtocolFrame.ID("frame-7.20"),
        in: transport
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()
    let eventTask = Task {
        var iterator = target.lifecycleEvents.makeAsyncIterator()
        return await iterator.next()
    }
    await waitForEventSubscription(target, domain: .page)

    await transport.receiveRootMessage(
        #"{"method":"Page.frameDetached","params":{"frameId":"frame-7.42"}}"#
    )

    guard case let .frameDetached(frameID)? = try await value(of: eventTask) else {
        Issue.record("Expected latest frame detach to retain event-time current-page membership.")
        return
    }
    #expect(frameID == FrameID("frame-7.42"))
}

@Test
func transportBackendDeliversLatestRootFrameNavigationToCurrentPage() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(
        backend: backend,
        protocolProfile: .latest,
        responseTimeout: .milliseconds(750)
    )
    await installPageTarget(in: transport)
    await installMainPageFrame(in: transport)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-42-7","type":"frame","isProvisional":false,"isPaused":false}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()
    let eventTask = Task {
        var iterator = target.lifecycleEvents.makeAsyncIterator()
        return await iterator.next()
    }
    await waitForEventSubscription(target, domain: .page)

    await transport.receiveRootMessage(
        #"{"method":"Page.frameNavigated","params":{"frame":{"id":"frame-7.42","parentId":"frame-7.1","loaderId":"child-loader","name":"Child","url":"https://frame.example.test/","securityOrigin":"https://frame.example.test","mimeType":"text/html"}}}"#
    )

    guard case let .frameNavigated(frame)? = try await value(of: eventTask) else {
        Issue.record("Expected latest root frame navigation on the current-page route.")
        return
    }
    #expect(frame.id == FrameID("frame-7.42"))
    #expect(frame.parentID == FrameID("frame-7.1"))
    #expect(frame.pageBindingID == "frame-42-7")
}
