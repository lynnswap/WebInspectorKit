import Foundation
import Testing
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import WebInspectorTestSupport

@Test
func transportBackendDoesNotDeliverFrameDocumentUpdatedToCurrentPageDOMRoute() async throws {
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
    #expect(target.route == .currentPage)

    let eventTask = Task {
        var iterator = target.dom.events.makeAsyncIterator()
        return await iterator.next()
    }
    defer { eventTask.cancel() }

    await waitForEventSubscription(target, domain: .dom)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("frame-42-7"),
        method: "DOM.documentUpdated",
        params: "{}"
    )

    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "DOM.inspect",
        params: #"{"nodeId":42}"#
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .inspect(nodeID) = event else {
        Issue.record("Expected the later page inspection, not the frame document update.")
        return
    }
    #expect(nodeID == DOM.Node.ID("42"))
}

@Test
func orderedCurrentPageFeedTreatsFrameDocumentUpdatedAsWatermarkOnly() async throws {
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
    let feed = await target.orderedEventFeed()

    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("frame-42-7"),
        method: "DOM.documentUpdated",
        params: "{}"
    )
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "DOM.attributeModified",
        params: #"{"nodeId":1,"name":"page","value":"1"}"#
    )

    var iterator = feed.events.makeAsyncIterator()
    let frameWatermark = try #require(try await iterator.next())
    #expect(frameWatermark.event == nil)
    let pageEvent = try #require(try await iterator.next())
    guard case let .dom(.attributeModified(_, name, value)) = pageEvent.event else {
        Issue.record("Expected the following main-page DOM event.")
        return
    }
    #expect(name == "page")
    #expect(value == "1")
}

@Test
func orderedCurrentPageFeedTreatsProvisionalRootRuntimeEventAsWatermarkOnly() async throws {
    let transport = TransportSession(
        backend: FakeTransportBackend(),
        protocolProfile: .latest,
        responseTimeout: .milliseconds(750)
    )
    await installPageTarget(in: transport)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-42-8","type":"frame","isProvisional":true,"isPaused":false}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()
    let feed = await target.orderedEventFeed()

    await transport.receiveRootMessage(
        #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":8,"name":"Provisional","type":"normal","frameId":"frame-8.42"}}}"#
    )

    var iterator = feed.events.makeAsyncIterator()
    let watermark = try #require(try await iterator.next())
    #expect(watermark.event == nil)
}

@Test
func transportBackendFiltersEventsByRoute() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-target","type":"frame","frameId":"frame-1","isProvisional":false}}}"#
    )
    let proxy = WebInspectorProxy(backend: LiveWebInspectorProxyBackend(transport: transport))
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
        params: #"{"requestId":"frame-request","timestamp":4,"sourceMapURL":"frame.js.map","metrics":{"protocol":"h2","remoteAddress":"203.0.113.10:443","requestHeaders":{"Cookie":"session=abc"},"responseBodyBytesReceived":128,"responseBodyDecodedSize":256,"securityConnection":{"protocol":"TLS 1.3","cipher":"AES_128_GCM_SHA256","futureConnectionField":true},"futureField":true}}"#
    )
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.loadingFinished",
        params: #"{"requestId":"page-request","timestamp":5}"#
    )

    let pageEvent = try #require(try await value(of: pageEventTask))
    guard case let .loadingFinished(pageRequestID, _, _, _) = pageEvent else {
        Issue.record("Expected page route to receive Network.loadingFinished.")
        return
    }
    #expect(pageRequestID == Network.Request.ID("page-request"))

    let frameEvent = try #require(try await value(of: frameEventTask))
    guard case let .loadingFinished(id, timestamp, sourceMapURL, metrics) = frameEvent else {
        Issue.record("Expected frame route to receive Network.loadingFinished.")
        return
    }
    #expect(id == Network.Request.ID("frame-request"))
    #expect(timestamp == 4)
    #expect(sourceMapURL == "frame.js.map")
    #expect(metrics?.networkProtocol == "h2")
    #expect(metrics?.remoteAddress == "203.0.113.10:443")
    #expect(metrics?.requestHeaders == ["Cookie": "session=abc"])
    #expect(metrics?.encodedDataLength == 128)
    #expect(metrics?.decodedBodyLength == 256)
    #expect(metrics?.securityConnection?.tlsProtocol == "TLS 1.3")
    #expect(metrics?.securityConnection?.cipher == "AES_128_GCM_SHA256")
}

@Test
func transportBackendKeepsPeerSubscriberActiveWhenOneStreamTerminates() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxyBackend = LiveWebInspectorProxyBackend(transport: transport)
    let page = pageTarget(proxy: WebInspectorProxy(backend: proxyBackend))
    let probe = EventDeliveryProbe()

    let firstSubscriber = Task {
        var iterator = page.network.events.makeAsyncIterator()
        if await iterator.next() != nil {
            await probe.recordFirst()
        }
    }
    let secondSubscriber = Task {
        var iterator = page.network.events.makeAsyncIterator()
        while await iterator.next() != nil {
            await probe.recordSecond()
        }
    }

    // Barrier on both subscribers being registered before the first event is
    // published; a generous bound keeps subscriber-task startup contention
    // (CI) from turning into an execution-time-allowance kill.
    try await value(
        of: Task {
            await proxyBackend.waitForEventSubscriptions(
                route: page.route,
                targetID: page.id,
                domain: .network,
                minimumCount: 2
            )
        },
        timeout: .seconds(10)
    )
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.loadingFinished",
        params: #"{"requestId":"first","timestamp":1}"#
    )

    try await value(of: Task { await probe.waitForFirstCount(1) }, timeout: transportCommandBackendWaitTimeout)
    try await value(of: Task { await probe.waitForSecondCount(1) }, timeout: transportCommandBackendWaitTimeout)
    try await value(of: firstSubscriber, timeout: transportCommandBackendWaitTimeout)

    try await value(
        of: Task { await waitForEventSubscription(page, domain: .network) },
        timeout: transportCommandBackendWaitTimeout
    )

    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.loadingFinished",
        params: #"{"requestId":"second","timestamp":2}"#
    )
    try await value(of: Task { await probe.waitForSecondCount(2) }, timeout: transportCommandBackendWaitTimeout)

    secondSubscriber.cancel()
}

@Test
func transportBackendRuntimeClearedUsesSemanticTargetID() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = WebInspectorProxy(backend: LiveWebInspectorProxyBackend(transport: transport))
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

private actor EventDeliveryProbe {
    private var firstCount = 0
    private var secondCount = 0
    private var firstWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var secondWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func recordFirst() {
        firstCount += 1
        resumeSatisfiedWaiters()
    }

    func recordSecond() {
        secondCount += 1
        resumeSatisfiedWaiters()
    }

    func waitForFirstCount(_ count: Int) async {
        guard firstCount < count else {
            return
        }
        await withCheckedContinuation { continuation in
            firstWaiters.append((count, continuation))
        }
    }

    func waitForSecondCount(_ count: Int) async {
        guard secondCount < count else {
            return
        }
        await withCheckedContinuation { continuation in
            secondWaiters.append((count, continuation))
        }
    }

    private func resumeSatisfiedWaiters() {
        let readyFirstWaiters = firstWaiters.filter { firstCount >= $0.count }
        firstWaiters.removeAll { firstCount >= $0.count }
        let readySecondWaiters = secondWaiters.filter { secondCount >= $0.count }
        secondWaiters.removeAll { secondCount >= $0.count }
        for waiter in readyFirstWaiters + readySecondWaiters {
            waiter.continuation.resume()
        }
    }
}
