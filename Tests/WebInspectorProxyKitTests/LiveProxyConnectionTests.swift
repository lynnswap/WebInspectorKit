import Foundation
import Testing
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import WebInspectorTestSupport

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
    #expect(target.frameID == nil)
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
func testRuntimeCloseFinishesActiveAndLateDomainAndOrderedStreams() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let activeDomainTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }
    let activeOrderedFeed = await target.orderedEventFeed()
    let activeOrderedTask = Task {
        var iterator = activeOrderedFeed.events.makeAsyncIterator()
        return try await iterator.next()
    }
    try await runtime.backend.waitForSubscribers(
        domain: "Network",
        target: target,
        count: 2
    )

    await runtime.proxy.close()

    #expect(try await value(of: activeDomainTask) == nil)
    #expect(try await throwingValue(of: activeOrderedTask) == nil)
    var lateDomainIterator = target.network.events.makeAsyncIterator()
    #expect(await lateDomainIterator.next() == nil)
    let lateOrderedFeed = await target.orderedEventFeed()
    var lateOrderedIterator = lateOrderedFeed.events.makeAsyncIterator()
    #expect(try await lateOrderedIterator.next() == nil)
    #expect(await runtime.backend.eventSubscriptionBookkeepingCountForTesting() == 0)
}

@Test
func testRuntimeCloseReleasesPendingCommandsAndSubscriberWaiters() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let commandGate = WebInspectorProxyKitTesting.WebInspectorTestGate()
    await runtime.backend.hold(domain: "Network", method: "enable", gate: commandGate)
    await runtime.backend.enqueue((), for: "Network", method: "enable")
    let commandTask = Task {
        try await target.network.enable()
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "Network",
        method: "enable",
        count: 1
    )
    let subscriberWaitTask = Task {
        try await runtime.backend.waitForSubscribers(
            domain: "Network",
            target: target,
            count: 1
        )
    }
    await runtime.backend.waitForEventSubscriptionWaiterForTesting()
    #expect(await runtime.backend.eventSubscriptionWaiterCountForTesting() == 1)

    await runtime.proxy.close()

    await #expect(throws: WebInspectorProxyError.closed) {
        try await commandTask.value
    }
    await #expect(throws: WebInspectorProxyError.closed) {
        try await subscriberWaitTask.value
    }
    await #expect(throws: WebInspectorProxyError.closed) {
        try await runtime.backend.waitForSubscribers(
            domain: "Network",
            target: target,
            count: 1
        )
    }
    #expect(await runtime.backend.eventSubscriptionWaiterCountForTesting() == 0)
    #expect(await runtime.backend.eventSubscriptionBookkeepingCountForTesting() == 0)
}

@Test
func subscriptionCancellationBeforeRegistrationLeavesNoBookkeeping() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: nil)
    await installPageTarget(in: transport)
    let liveBackend = LiveWebInspectorProxyBackend(transport: transport)
    let proxy = WebInspectorProxy(
        backend: liveBackend,
        closeConnection: { error in
            await transport.detach(error: error)
        }
    )
    let target = pageTarget(proxy: proxy)

    #expect(await liveBackend.exerciseCancelledSubscriptionRegistrationForTesting(
        ordered: false,
        route: target.route,
        targetID: target.id
    ))
    #expect(await liveBackend.exerciseCancelledSubscriptionRegistrationForTesting(
        ordered: true,
        route: target.route,
        targetID: target.id
    ))

    let runtime = try await WebInspectorProxyTestRuntime.start()
    let runtimeTarget = try await runtime.proxy.waitForCurrentPage()
    #expect(await runtime.backend.exerciseCancelledSubscriptionRegistrationForTesting(
        ordered: false,
        route: runtimeTarget.route,
        targetID: runtimeTarget.id
    ))
    #expect(await runtime.backend.exerciseCancelledSubscriptionRegistrationForTesting(
        ordered: true,
        route: runtimeTarget.route,
        targetID: runtimeTarget.id
    ))

    let waiterTask = Task {
        try await runtime.backend.waitForSubscribers(
            domain: "Network",
            target: runtimeTarget,
            count: 1
        )
    }
    await runtime.backend.waitForEventSubscriptionWaiterForTesting()
    #expect(await runtime.backend.eventSubscriptionWaiterCountForTesting() == 1)
    waiterTask.cancel()
    await #expect(throws: CancellationError.self) {
        try await waiterTask.value
    }
    #expect(await runtime.backend.eventSubscriptionWaiterCountForTesting() == 0)
    #expect(await runtime.backend.eventSubscriptionBookkeepingCountForTesting() == 0)
    await runtime.proxy.close()
    await proxy.close()
}

@Test
func liveSubscriptionWaitersReleaseOnCancellationAndExplicitClose() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: nil)
    await installPageTarget(in: transport)
    let liveBackend = LiveWebInspectorProxyBackend(transport: transport)
    let proxy = WebInspectorProxy(
        backend: liveBackend,
        closeConnection: { error in
            await transport.detach(error: error)
        }
    )
    let target = pageTarget(proxy: proxy)

    let cancelledWaiter = Task {
        await liveBackend.waitForEventSubscriptions(
            route: target.route,
            targetID: target.id,
            domain: .network,
            minimumCount: 1
        )
    }
    await liveBackend.waitForEventSubscriptionWaiterForTesting()
    #expect(await liveBackend.eventSubscriptionWaiterCountForTesting() == 1)
    cancelledWaiter.cancel()
    await cancelledWaiter.value
    #expect(await liveBackend.eventSubscriptionWaiterCountForTesting() == 0)

    let terminalWaiter = Task {
        await liveBackend.waitForEventSubscriptions(
            route: target.route,
            targetID: target.id,
            domain: .network,
            minimumCount: 1
        )
    }
    await liveBackend.waitForEventSubscriptionWaiterForTesting()
    #expect(await liveBackend.eventSubscriptionWaiterCountForTesting() == 1)

    await proxy.close()

    await terminalWaiter.value
    #expect(await liveBackend.eventSubscriptionWaiterCountForTesting() == 0)
    #expect(await liveBackend.eventSubscriptionBookkeepingCountForTesting() == 0)
    #expect(await backend.isDetached())
}

@Test(arguments: [
    (
        #"{"id":0,"result":"INSPECTED_SECRET"}"#,
        0,
        "Failed to decode root envelope: Invalid protocol field: result."
    ),
    (
        #"{"method":"Network.loadingFinished","params":"INSPECTED_SECRET"}"#,
        1,
        "Failed to decode target envelope: Invalid protocol field: params."
    ),
    (
        #"{"id":0,"result":"INSPECTED_SECRET"}"#,
        2,
        "Failed to decode target envelope: Invalid protocol field: result."
    ),
])
func malformedTransportEnvelopeTerminatesEveryConsumer(
    message: String,
    wrapperDepth: Int,
    expectedFailure: String
) async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend)
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let events = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }
    await waitForEventSubscription(target, domain: .network)
    let feed = await target.orderedEventFeed()
    let orderedEvents = Task {
        var iterator = feed.events.makeAsyncIterator()
        return try await iterator.next()
    }
    await target.waitForModelEventSubscriptions()

    let closeWait = Task { try await proxy.waitUntilClosed() }
    await proxy.waitForCloseWaiterForTesting()
    let reload = Task { try await target.page.reload() }
    _ = try await waitForTargetMessage(backend, method: "Page.reload")
    let enable = Task { try await target.network.enable() }
    _ = try await waitForTargetMessage(backend, method: "Network.enable")

    var input = message
    for _ in 0..<wrapperDepth {
        let data = try JSONSerialization.data(withJSONObject: [
            "method": "Target.dispatchMessageFromTarget",
            "params": ["targetId": "page-main", "message": input],
        ])
        input = String(decoding: data, as: UTF8.self)
    }
    await transport.receiveRootMessage(input)

    let failure = try #require(await disconnectedMessage(from: closeWait))
    #expect(failure == expectedFailure)
    #expect(await disconnectedMessage(from: reload) == failure)
    #expect(await disconnectedMessage(from: enable) == failure)
    #expect(await disconnectedMessage(from: orderedEvents) == failure)
    #expect(try await value(of: events) == nil)
    #expect(await disconnectedMessage(from: Task { try await target.network.enable() }) == failure)
    #expect(await disconnectedMessage(from: Task { try await proxy.waitForCurrentPage() }) == failure)
    let lateFeed = await target.orderedEventFeed()
    #expect(await disconnectedMessage(from: Task {
        var iterator = lateFeed.events.makeAsyncIterator()
        return try await iterator.next()
    }) == failure)
    let snapshot = await transport.snapshot()
    #expect(snapshot.pendingRootReplyIDs.isEmpty)
    #expect(snapshot.pendingTargetReplyKeys.isEmpty)
    #expect(await backend.isDetached())
    #expect(await proxy.currentPage == nil)
}

@Test
func transportFailureClosesProxyWithoutEventSubscribers() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend)
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)

    await transport.receiveRootMessage("{")

    #expect(await disconnectedMessage(from: Task { try await proxy.waitUntilClosed() })
        == "Failed to decode root envelope: Invalid JSON.")
    #expect(await backend.isDetached())
}

@Test
func malformedEnvelopeFailsPendingRootCommand() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend)
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let pending = Task {
        try await transport.send(ProtocolCommand(domain: .target, method: "Target.setPauseOnStart", routing: .root))
    }
    _ = try await backend.waitForMessage()

    await transport.receiveRootMessage("{")

    let failure = try #require(await transport.terminalFailure)
    await #expect(throws: failure) { try await pending.value }
    #expect(await disconnectedMessage(from: Task { try await proxy.waitUntilClosed() })
        == "Failed to decode root envelope: Invalid JSON.")
    #expect(await transport.snapshot().pendingRootReplyIDs.isEmpty)
}

@Test
func transportFailureBeforeProxyInitializationKeepsItsCauseAndCleansUp() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend)
    await transport.receiveRootMessage("{")

    await #expect(throws: WebInspectorProxyError.disconnected("Failed to decode root envelope: Invalid JSON.")) {
        _ = try await WebInspectorProxy(transport: transport)
    }
    #expect(await backend.isDetached())
}

@Test(arguments: [false, true])
func nativeInvalidationFailsRootAndTargetRepliesAndEverySubscriber(rootSend: Bool) async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend)
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()
    let pendingRoot = Task {
        try await transport.send(ProtocolCommand(domain: .target, method: "Target.setPauseOnStart", routing: .root))
    }
    _ = try await backend.waitForMessage()
    let pendingTarget = Task { try await target.page.reload() }
    _ = try await backend.waitForTargetMessage(method: "Page.reload")
    let events = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }
    await waitForEventSubscription(target, domain: .network)
    let feed = await target.orderedEventFeed()
    let orderedEvents = Task {
        var iterator = feed.events.makeAsyncIterator()
        return try await iterator.next()
    }
    await target.waitForModelEventSubscriptions()

    let failure = TransportSession.Error.nativeAttachmentInvalidated("The native target is unavailable.")
    await backend.setSendError(failure)
    await #expect(throws: failure) {
        try await transport.send(ProtocolCommand(
            domain: rootSend ? .target : .network,
            method: rootSend ? "Target.setPauseOnStart" : "Network.enable",
            routing: rootSend ? .root : .target(ProtocolTarget.ID("page-main"))
        ))
    }

    let message = try #require(await disconnectedMessage(from: Task { try await proxy.waitUntilClosed() }))
    #expect(message == "Native inspector attachment invalidated: The native target is unavailable.")
    await #expect(throws: failure) { try await pendingRoot.value }
    #expect(await disconnectedMessage(from: pendingTarget) == message)
    #expect(await disconnectedMessage(from: orderedEvents) == message)
    #expect(try await value(of: events) == nil)
    #expect(await disconnectedMessage(from: Task { try await target.network.enable() }) == message)
    let snapshot = await transport.snapshot()
    #expect(snapshot.pendingRootReplyIDs.isEmpty)
    #expect(snapshot.pendingTargetReplyKeys.isEmpty)
    #expect(await proxy.currentPage == nil)
    #expect(await backend.isDetached())
}

@Test(arguments: [false, true])
func nativeInvalidationAndExplicitCloseKeepOneTerminalReason(explicitCloseFirst: Bool) async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend)
    await installPageTarget(in: transport)
    let gate = CloseConnectionGate()
    let proxy = try await WebInspectorProxy(transport: transport, closeConnection: { error in
        await gate.waitUntilReleased()
        await transport.detach(error: error)
    })
    let target = try await proxy.waitForCurrentPage()
    let pending = Task { try await target.page.reload() }
    _ = try await backend.waitForTargetMessage(method: "Page.reload")
    let close: Task<Void, Never>?
    if explicitCloseFirst {
        close = Task { await proxy.close() }
        await gate.waitUntilStarted()
    } else {
        close = nil
    }
    let failure = TransportSession.Error.nativeAttachmentInvalidated("native target disappeared")
    await backend.setSendError(failure)
    let expected = explicitCloseFirst ? TransportSession.Error.transportClosed : failure
    let command = ProtocolCommand(domain: .network, method: "Network.enable", routing: .target(ProtocolTarget.ID("page-main")))
    await #expect(throws: expected) { try await transport.send(command) }
    await gate.waitUntilStarted()
    #expect(await backend.isDetached() == false)
    await backend.setSendError(WebInspectorProxyError.commandFailed(domain: "Network", method: "enable", message: "later failure"))
    await #expect(throws: expected) { try await transport.send(command) }

    await gate.release()
    await close?.value
    await proxy.close()
    if explicitCloseFirst {
        try await proxy.waitUntilClosed()
        await #expect(throws: WebInspectorProxyError.closed) { try await pending.value }
    } else {
        let message = await disconnectedMessage(from: Task { try await proxy.waitUntilClosed() })
        #expect(message == "Native inspector attachment invalidated: native target disappeared")
        #expect(await disconnectedMessage(from: pending) == message)
    }
    #expect(await gate.invocationCount() == 1)
    #expect(await backend.isDetached())
}

@Test
func ordinarySendErrorDoesNotInvalidatePeerCommandsOrConnection() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend)
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()
    let pending = Task { try await target.page.reload() }
    let sent = try await backend.waitForTargetMessage(method: "Page.reload")
    let error = WebInspectorProxyError.commandFailed(domain: "Network", method: "enable", message: "send rejected")
    await backend.setSendError(error)
    await #expect(throws: error) { try await target.network.enable() }
    await backend.setSendError(nil)
    try await transport.requireOpen()
    #expect(await backend.isDetached() == false)
    #expect(await proxy.canReload)
    await receiveTargetReply(transport, targetID: ProtocolTarget.ID("page-main"), messageID: try messageID(sent.message), result: "{}")
    try await pending.value
    await proxy.close()
    try await proxy.waitUntilClosed()
}

@Test
func malformedKnownDomainEventTerminatesProxyAndPendingCommand() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: nil)
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let eventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }
    await waitForEventSubscription(target, domain: .network)

    let closeWaitTask = Task {
        try await proxy.waitUntilClosed()
    }
    await proxy.waitForCloseWaiterForTesting()

    let reloadTask = Task {
        try await target.page.reload()
    }
    _ = try await waitForTargetMessage(backend, method: "Page.reload")

    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.loadingFinished",
        params: "{}"
    )

    #expect(try await value(of: eventTask) == nil)
    let closeMessage = await disconnectedMessage(from: closeWaitTask)
    let reloadMessage = await disconnectedMessage(from: reloadTask)
    let subsequentCommandMessage = await disconnectedMessage(from: Task {
        try await target.network.enable()
    })
    #expect(closeMessage?.contains("Network.loadingFinished") == true)
    #expect(reloadMessage == closeMessage)
    #expect(subsequentCommandMessage == closeMessage)
    #expect(await backend.isDetached())
    #expect(await proxy.canReload == false)
    #expect(await proxy.currentPage == nil)
}

@Test
func malformedKnownOrderedEventPropagatesTerminalFailure() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: nil)
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()
    let feed = await target.orderedEventFeed()

    let eventTask = Task {
        var iterator = feed.events.makeAsyncIterator()
        return try await iterator.next()
    }
    await target.waitForModelEventSubscriptions()

    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.loadingFinished",
        params: "{}"
    )

    let eventMessage = await disconnectedMessage(from: eventTask)
    let replayedCloseMessage = await disconnectedMessage(from: Task {
        try await proxy.waitUntilClosed()
    })
    #expect(eventMessage?.contains("Network.loadingFinished") == true)
    #expect(replayedCloseMessage == eventMessage)
    #expect(await backend.isDetached())
}

@Test
func malformedKnownDOMEventTerminatesFilteredDomainRouteWithoutDelivering() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: nil)
    await installPageTarget(in: transport)
    let liveBackend = LiveWebInspectorProxyBackend(transport: transport)
    let proxy = WebInspectorProxy(
        backend: liveBackend,
        closeConnection: { error in
            await transport.detach(error: error)
        }
    )
    let filteredTarget = WebInspectorTarget(
        id: WebInspectorTarget.ID("filtered-frame"),
        kind: .frame,
        frameID: FrameID("filtered-frame"),
        isProvisional: false,
        proxy: proxy,
        route: RoutingTargetID("filtered-frame")
    )
    let eventTask = Task {
        var iterator = filteredTarget.dom.events.makeAsyncIterator()
        return await iterator.next()
    }
    await liveBackend.waitForEventSubscriptions(
        route: filteredTarget.route,
        targetID: filteredTarget.id,
        domain: .dom,
        minimumCount: 1
    )

    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "DOM.setChildNodes",
        params: "{}"
    )

    #expect(try await value(of: eventTask) == nil)
    let closeMessage = await disconnectedMessage(from: Task {
        try await proxy.waitUntilClosed()
    })
    #expect(closeMessage?.contains("DOM.setChildNodes") == true)
    #expect(await backend.isDetached())
}

@Test
func malformedKnownEventTerminatesFilteredOrderedRouteWithoutWatermark() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: nil)
    await installPageTarget(in: transport)
    let liveBackend = LiveWebInspectorProxyBackend(transport: transport)
    let proxy = WebInspectorProxy(
        backend: liveBackend,
        closeConnection: { error in
            await transport.detach(error: error)
        }
    )
    let filteredTarget = WebInspectorTarget(
        id: WebInspectorTarget.ID("filtered-frame"),
        kind: .frame,
        frameID: FrameID("filtered-frame"),
        isProvisional: false,
        proxy: proxy,
        route: RoutingTargetID("filtered-frame")
    )
    let feed = await filteredTarget.orderedEventFeed()
    let eventTask = Task {
        var iterator = feed.events.makeAsyncIterator()
        return try await iterator.next()
    }
    await liveBackend.waitForEventSubscriptions(
        route: filteredTarget.route,
        targetID: filteredTarget.id,
        domain: .ordered,
        minimumCount: 1
    )

    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.loadingFinished",
        params: "{}"
    )

    let closeMessage = await disconnectedMessage(from: eventTask)
    #expect(closeMessage?.contains("Network.loadingFinished") == true)
    let completedCloseMessage = await disconnectedMessage(from: Task {
        try await proxy.waitUntilClosed()
    })
    #expect(completedCloseMessage == closeMessage)
    #expect(await backend.isDetached())
}

@Test
func domainSubscribersFinishBeforeGatedDetachAndFailureReasonWinsLaterClose() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: nil)
    await installPageTarget(in: transport)
    let liveBackend = LiveWebInspectorProxyBackend(transport: transport)
    let closeGate = CloseConnectionGate()
    let proxy = WebInspectorProxy(
        backend: liveBackend,
        closeConnection: { error in
            await closeGate.waitUntilReleased()
            await transport.detach(error: error)
        }
    )
    let currentPage = WebInspectorTarget(
        id: .currentPage,
        kind: .page,
        frameID: nil,
        isProvisional: false,
        proxy: proxy,
        route: .currentPage
    )
    let filteredTarget = WebInspectorTarget(
        id: WebInspectorTarget.ID("filtered-frame"),
        kind: .frame,
        frameID: FrameID("filtered-frame"),
        isProvisional: false,
        proxy: proxy,
        route: RoutingTargetID("filtered-frame")
    )
    let currentTask = Task {
        var iterator = currentPage.network.events.makeAsyncIterator()
        return await iterator.next()
    }
    let filteredTask = Task {
        var iterator = filteredTarget.network.events.makeAsyncIterator()
        return await iterator.next()
    }
    await liveBackend.waitForEventSubscriptions(
        route: currentPage.route,
        targetID: currentPage.id,
        domain: .network,
        minimumCount: 1
    )
    await liveBackend.waitForEventSubscriptions(
        route: filteredTarget.route,
        targetID: filteredTarget.id,
        domain: .network,
        minimumCount: 1
    )
    let pendingCommandTask = Task {
        try await currentPage.page.reload()
    }
    _ = try await waitForTargetMessage(backend, method: "Page.reload")

    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.loadingFinished",
        params: "{}"
    )
    await closeGate.waitUntilStarted()

    #expect(try await value(of: currentTask) == nil)
    #expect(try await value(of: filteredTask) == nil)
    let lateTask = Task {
        var iterator = filteredTarget.network.events.makeAsyncIterator()
        return await iterator.next()
    }
    #expect(try await value(of: lateTask) == nil)
    #expect(await backend.isDetached() == false)

    let explicitCloseTask = Task {
        await proxy.close()
    }
    await closeGate.release()
    await explicitCloseTask.value
    let closeMessage = await disconnectedMessage(from: Task {
        try await proxy.waitUntilClosed()
    })
    let commandMessage = await disconnectedMessage(from: pendingCommandTask)
    #expect(closeMessage?.contains("Network.loadingFinished") == true)
    #expect(commandMessage == closeMessage)
    #expect(await closeGate.invocationCount() == 1)
    #expect(await backend.isDetached())
}

@Test
func malformedKnownEventPropagatesFailureToEveryOrderedSubscriber() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: nil)
    await installPageTarget(in: transport)
    let liveBackend = LiveWebInspectorProxyBackend(transport: transport)
    let closeGate = CloseConnectionGate()
    let proxy = WebInspectorProxy(
        backend: liveBackend,
        closeConnection: { error in
            await closeGate.waitUntilReleased()
            await transport.detach(error: error)
        }
    )
    let target = WebInspectorTarget(
        id: .currentPage,
        kind: .page,
        frameID: nil,
        isProvisional: false,
        proxy: proxy,
        route: .currentPage
    )
    let firstFeed = await target.orderedEventFeed()
    let secondFeed = await target.orderedEventFeed()

    let firstTask = Task {
        var iterator = firstFeed.events.makeAsyncIterator()
        return try await iterator.next()
    }
    let secondTask = Task {
        var iterator = secondFeed.events.makeAsyncIterator()
        return try await iterator.next()
    }
    await liveBackend.waitForEventSubscriptions(
        route: .currentPage,
        targetID: .currentPage,
        domain: .ordered,
        minimumCount: 2
    )

    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.loadingFinished",
        params: "{}"
    )

    let firstMessage = await disconnectedMessage(from: firstTask)
    let secondMessage = await disconnectedMessage(from: secondTask)
    #expect(firstMessage?.contains("Network.loadingFinished") == true)
    #expect(secondMessage == firstMessage)
    await closeGate.waitUntilStarted()
    #expect(await closeGate.invocationCount() == 1)
    #expect(await backend.isDetached() == false)
    await closeGate.release()
    let closeMessage = await disconnectedMessage(from: Task {
        try await proxy.waitUntilClosed()
    })
    #expect(closeMessage == firstMessage)
    #expect(await backend.isDetached())
}

@Test
func malformedKnownEventPropagatesFailureToFilteredOrderedRoute() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: nil)
    await installPageTarget(in: transport)
    let liveBackend = LiveWebInspectorProxyBackend(transport: transport)
    let proxy = WebInspectorProxy(
        backend: liveBackend,
        closeConnection: { error in
            await transport.detach(error: error)
        }
    )
    let currentPage = WebInspectorTarget(
        id: .currentPage,
        kind: .page,
        frameID: nil,
        isProvisional: false,
        proxy: proxy,
        route: .currentPage
    )
    let frameID = WebInspectorTarget.ID("frame-route")
    let frameRoute = RoutingTargetID("frame-route")
    let frame = WebInspectorTarget(
        id: frameID,
        kind: .frame,
        frameID: nil,
        isProvisional: false,
        proxy: proxy,
        route: frameRoute
    )
    let pageFeed = await currentPage.orderedEventFeed()
    let frameFeed = await frame.orderedEventFeed()

    let pageTask = Task {
        var iterator = pageFeed.events.makeAsyncIterator()
        return try await iterator.next()
    }
    let frameTask = Task {
        for try await _ in frameFeed.events {}
    }
    await liveBackend.waitForEventSubscriptions(
        route: .currentPage,
        targetID: .currentPage,
        domain: .ordered,
        minimumCount: 1
    )
    await liveBackend.waitForEventSubscriptions(
        route: frameRoute,
        targetID: frameID,
        domain: .ordered,
        minimumCount: 1
    )

    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.loadingFinished",
        params: "{}"
    )

    let pageMessage = await disconnectedMessage(from: pageTask)
    let frameMessage = await disconnectedMessage(from: frameTask)
    #expect(pageMessage?.contains("Network.loadingFinished") == true)
    #expect(frameMessage == pageMessage)
    let closeMessage = await disconnectedMessage(from: Task {
        try await proxy.waitUntilClosed()
    })
    #expect(closeMessage == pageMessage)
    #expect(await backend.isDetached())
}

@Test
func explicitCloseReasonWinsConcurrentDecodeFailure() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: nil)
    await installPageTarget(in: transport)
    let closeGate = CloseConnectionGate()
    let proxy = try await WebInspectorProxy(transport: transport, closeConnection: { error in
        await closeGate.waitUntilReleased()
        await transport.detach(error: error)
    })
    let target = try await proxy.waitForCurrentPage()
    let orderedFeed = await target.orderedEventFeed()

    let eventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }
    let orderedEventTask = Task {
        var iterator = orderedFeed.events.makeAsyncIterator()
        return try await iterator.next()
    }
    await waitForEventSubscription(target, domain: .network)
    await target.waitForModelEventSubscriptions()

    let closeTask = Task {
        await proxy.close()
    }
    await closeGate.waitUntilStarted()

    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.loadingFinished",
        params: "{}"
    )
    #expect(try await value(of: eventTask) == nil)
    #expect(try await throwingValue(of: orderedEventTask) == nil)

    await closeGate.release()
    await closeTask.value
    try await proxy.waitUntilClosed()
    #expect(await backend.isDetached())
}

@Test
func closeWaiterCancellationIsIndependentFromDecodeFailure() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: nil)
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()
    let eventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }
    await waitForEventSubscription(target, domain: .network)
    let cancelledWaiter = Task {
        try await proxy.waitUntilClosed()
    }
    let terminalWaiter = Task {
        try await proxy.waitUntilClosed()
    }
    await proxy.waitForCloseWaiterForTesting(minimumCount: 2)

    cancelledWaiter.cancel()
    await #expect(throws: CancellationError.self) {
        try await cancelledWaiter.value
    }
    #expect(await proxy.closeWaiterCountForTesting == 1)

    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.loadingFinished",
        params: "{}"
    )

    #expect(try await value(of: eventTask) == nil)
    let terminalMessage = await disconnectedMessage(from: terminalWaiter)
    #expect(terminalMessage?.contains("Network.loadingFinished") == true)
    #expect(await proxy.closeWaiterCountForTesting == 0)
    #expect(await backend.isDetached())
}

@Test
func transportBackedProxyWaitUntilClosedSuspendsUntilClose() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)

    let waitTask = Task {
        try await proxy.waitUntilClosed()
    }

    await proxy.waitForCloseWaiterForTesting()
    #expect(await backend.isDetached() == false)

    await proxy.close()

    try await waitTask.value
    #expect(await backend.isDetached())
}

@Test
func proxyWithoutBackendFailsCommandsAndEndsEventStreams() async throws {
    let proxy = WebInspectorProxy()
    let target = await proxy.installTargetForTesting()

    await #expect(throws: WebInspectorProxyError.self) {
        try await target.dom.getDocument()
    }
    for await event in target.dom.events {
        Issue.record("Unexpected event from a proxy without a backend: \(event)")
    }
}

@Test
func proxyWaitUntilClosedReturnsImmediatelyAfterClose() async throws {
    let proxy = WebInspectorProxy()

    await proxy.close()

    let waitTask = Task {
        try await proxy.waitUntilClosed()
    }
    try await throwingValue(of: waitTask, timeout: .milliseconds(100))
}

@Test
func proxyWaitUntilClosedWaitsForInFlightCloseConnection() async throws {
    let closeGate = CloseConnectionGate()
    let proxy = WebInspectorProxy(closeConnection: { _ in
        await closeGate.waitUntilReleased()
    })

    let closeTask = Task {
        await proxy.close()
    }
    await closeGate.waitUntilStarted()

    let waitCompletion = CompletionProbe()
    let waitTask = Task {
        try await proxy.waitUntilClosed()
        await waitCompletion.finish()
    }
    await proxy.waitForCloseWaiterForTesting()
    #expect(await waitCompletion.isFinished() == false)

    await closeGate.release()
    try await waitTask.value
    await closeTask.value
    #expect(await waitCompletion.isFinished())
}

@Test
func proxyWaitUntilClosedCancellationRemovesWaiter() async throws {
    let proxy = WebInspectorProxy()

    let waitTask = Task {
        try await proxy.waitUntilClosed()
    }
    await proxy.waitForCloseWaiterForTesting()

    waitTask.cancel()

    do {
        try await waitTask.value
        Issue.record("Expected waitUntilClosed cancellation to throw.")
    } catch is CancellationError {
        // Expected: cancellation is the waiter's failure path while the proxy remains open.
    } catch {
        Issue.record("Expected CancellationError, got \(error).")
    }

    await proxy.close()
    try await proxy.waitUntilClosed()
}

@Test
func transportBackedProxyDoesNotRefreshCurrentPageWhileClosing() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let closeGate = CloseConnectionGate()
    let proxy = try await WebInspectorProxy(transport: transport, closeConnection: { _ in
        await closeGate.waitUntilReleased()
    })

    _ = try await proxy.waitForCurrentPage()
    let closeTask = Task {
        await proxy.close()
    }
    await closeGate.waitUntilStarted()

    do {
        _ = try await proxy.waitForCurrentPage()
        Issue.record("Expected waitForCurrentPage to fail after close started.")
    } catch WebInspectorProxyError.closed {
        // Expected: closing proxies must not refresh and republish current-page targets.
    } catch {
        Issue.record("Expected WebInspectorProxyError.closed, got \(error).")
    }
    #expect(await proxy.currentPage?.id == nil)

    await closeGate.release()
    await closeTask.value
    #expect(await proxy.currentPage?.id == nil)
}

private actor CloseConnectionGate {
    private var startCount = 0
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilReleased() async {
        startCount += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard released == false else {
            return
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard startCount == 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func invocationCount() -> Int {
        startCount
    }
}

private actor CompletionProbe {
    private var finished = false

    func finish() {
        finished = true
    }

    func isFinished() -> Bool {
        finished
    }
}

private func disconnectedMessage<Value: Sendable>(
    from task: Task<Value, any Error>
) async -> String? {
    do {
        _ = try await task.value
        Issue.record("Expected a disconnected terminal error.")
        return nil
    } catch let WebInspectorProxyError.disconnected(message) {
        return message
    } catch {
        Issue.record("Expected WebInspectorProxyError.disconnected, got \(error).")
        return nil
    }
}
