import Foundation
import Testing
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import WebInspectorTestSupport

@Test
func transportBackendDecodesNetworkResponseEventForTargetRoute() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: LiveWebInspectorProxyBackend(transport: transport)))

    let eventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .network)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.responseReceived",
        params: #"{"requestId":"request-1","frameId":"main-frame","loaderId":"main-loader","type":"Document","response":{"url":"https://example.test/","status":200,"statusText":"OK","mimeType":"text/html","headers":{"content-type":"text/html"},"source":"network","security":{"connection":{"protocol":"TLS 1.3","cipher":"","futureConnectionField":true},"certificate":{"subject":"","validFrom":1700000000.125,"validUntil":1800000000,"dnsNames":["www.example.test","example.test"],"ipAddresses":[],"futureCertificateField":"ignored"},"futureSecurityField":42}},"timestamp":12.5}"#
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
    #expect(response.security?.connection?.tlsProtocol == "TLS 1.3")
    #expect(response.security?.connection?.cipher == "")
    #expect(response.security?.certificate?.subject == "")
    #expect(response.security?.certificate?.validFrom == Date(timeIntervalSince1970: 1_700_000_000.125))
    #expect(response.security?.certificate?.validUntil == Date(timeIntervalSince1970: 1_800_000_000))
    #expect(response.security?.certificate?.dnsNames == ["www.example.test", "example.test"])
    #expect(response.security?.certificate?.ipAddresses == [])
    #expect(
        response.origin == Network.Request.Origin(
            frameID: FrameID("main-frame"),
            loaderID: "main-loader",
            targetID: "page-main"
        )
    )
    #expect(resourceType == .document)
    #expect(timestamp == 12.5)

    let copiedResponse = response.reporting(security: Network.Security())
    #expect(copiedResponse.url == response.url)
    #expect(copiedResponse.status == response.status)
    #expect(copiedResponse.statusText == response.statusText)
    #expect(copiedResponse.mimeType == response.mimeType)
    #expect(copiedResponse.headers == response.headers)
    #expect(copiedResponse.source == response.source)
    #expect(copiedResponse.requestHeaders == response.requestHeaders)
    #expect(copiedResponse.bodySize == response.bodySize)
    #expect(copiedResponse.origin == response.origin)
    #expect(copiedResponse.security == Network.Security())
}

@Test
func transportBackendDecodesNetworkResponseEventWithoutType() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: LiveWebInspectorProxyBackend(transport: transport)))

    let eventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .network)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.responseReceived",
        params: #"{"requestId":"request-1","frameId":"main-frame","loaderId":"main-loader","response":{"url":"https://example.test/","status":200,"statusText":"OK","mimeType":"text/html","headers":{"content-type":"text/html"},"source":"network"},"timestamp":12.5}"#
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .responseReceived(id, response, resourceType, timestamp) = event else {
        Issue.record("Expected Network.responseReceived.")
        return
    }
    #expect(id == Network.Request.ID("request-1"))
    #expect(response.url == "https://example.test/")
    #expect(response.security == nil)
    #expect(resourceType == nil)
    #expect(timestamp == 12.5)
}

@Test
func transportBackendPreservesPresentEmptyNetworkSecurity() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: LiveWebInspectorProxyBackend(transport: transport)))

    let eventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        var events: [Network.Event] = []
        for _ in 0..<3 {
            guard let event = await iterator.next() else {
                break
            }
            events.append(event)
        }
        return events
    }

    await waitForEventSubscription(target, domain: .network)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.responseReceived",
        params: #"{"requestId":"request-empty-security","frameId":"main-frame","loaderId":"main-loader","response":{"url":"https://example.test/","status":200,"headers":{},"security":{}},"timestamp":12.5}"#
    )
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.responseReceived",
        params: #"{"requestId":"request-empty-nested-security","frameId":"main-frame","loaderId":"main-loader","response":{"url":"https://example.test/","status":200,"headers":{},"security":{"connection":{},"certificate":{}}},"timestamp":13}"#
    )
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.loadingFinished",
        params: #"{"requestId":"request-empty-security","timestamp":14,"metrics":{"securityConnection":{}}}"#
    )

    let events = try await value(of: eventTask)
    #expect(events.count == 3)
    guard events.count == 3 else {
        return
    }
    guard case let .responseReceived(_, response, _, _) = events[0] else {
        Issue.record("Expected Network.responseReceived.")
        return
    }
    let security = try #require(response.security)
    #expect(security.connection == nil)
    #expect(security.certificate == nil)

    guard case let .responseReceived(_, nestedResponse, _, _) = events[1] else {
        Issue.record("Expected a second Network.responseReceived.")
        return
    }
    let nestedSecurity = try #require(nestedResponse.security)
    let emptyConnection = try #require(nestedSecurity.connection)
    let emptyCertificate = try #require(nestedSecurity.certificate)
    #expect(emptyConnection.tlsProtocol == nil)
    #expect(emptyConnection.cipher == nil)
    #expect(emptyCertificate.subject == nil)
    #expect(emptyCertificate.validFrom == nil)
    #expect(emptyCertificate.validUntil == nil)
    #expect(emptyCertificate.dnsNames == nil)
    #expect(emptyCertificate.ipAddresses == nil)

    guard case let .loadingFinished(_, _, _, metrics) = events[2] else {
        Issue.record("Expected Network.loadingFinished.")
        return
    }
    let emptyMetricsConnection = try #require(metrics?.securityConnection)
    #expect(emptyMetricsConnection.tlsProtocol == nil)
    #expect(emptyMetricsConnection.cipher == nil)
}

@Test
func transportBackendLeavesUnknownConcurrentRootNetworkOriginUnattributed() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(
        in: transport,
        targetID: ProtocolTarget.ID("page-current"),
        frameID: "main-frame"
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-provisional","type":"page","frameId":"main-frame","isProvisional":true}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let eventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .network)
    await transport.receiveRootMessage(
        #"{"method":"Network.responseReceived","params":{"requestId":"provisional-response","frameId":"main-frame","loaderId":"provisional-loader","response":{"url":"https://example.test/provisional","status":200,"headers":{}},"timestamp":1}}"#
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .responseReceived(_, response, _, _) = event else {
        Issue.record("Expected Network.responseReceived.")
        return
    }
    #expect(response.origin?.targetID == nil)
}

@Test
func transportDoesNotGuessRootNetworkOriginAcrossSameLoaderPageTargets() async throws {
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
        #"{"method":"Page.frameNavigated","params":{"frame":{"id":"main-frame","loaderId":"shared-loader"}}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-provisional","type":"page","frameId":"main-frame","isProvisional":true}}}"#
    )
    let stream = await transport.events(for: .network)
    var iterator = stream.makeAsyncIterator()

    await transport.receiveRootMessage(
        #"{"method":"Network.requestWillBeSent","params":{"requestId":"current-exact","frameId":"main-frame","loaderId":"shared-loader","targetId":"page-current"}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Network.requestWillBeSent","params":{"requestId":"provisional-exact","frameId":"main-frame","loaderId":"shared-loader","targetId":"page-provisional"}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Network.requestWillBeSent","params":{"requestId":"ambiguous-request","frameId":"main-frame","loaderId":"shared-loader","targetId":""}}"#
    )

    let current = try #require(await iterator.next())
    let provisional = try #require(await iterator.next())
    let ambiguous = try #require(await iterator.next())
    #expect(current.networkOriginTargetID == ProtocolTarget.ID("page-current"))
    #expect(provisional.networkOriginTargetID == ProtocolTarget.ID("page-provisional"))
    #expect(ambiguous.networkOriginTargetID == nil)
}

@Test
func transportUsesUniqueFrameLoaderOriginDespiteCompetingFrameTargets() async throws {
    let transport = TransportSession(
        backend: FakeTransportBackend(),
        protocolProfile: .latest,
        responseTimeout: .milliseconds(750)
    )
    await installPageTarget(in: transport)
    await installMainPageFrame(in: transport)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-1-7","type":"frame","isProvisional":false,"isPaused":false}}}"#
    )
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Page.frameNavigated",
        params: #"{"frame":{"id":"frame-7.1","loaderId":"page-loader"}}"#
    )
    let stream = await transport.events(for: .network)
    var iterator = stream.makeAsyncIterator()

    await transport.receiveRootMessage(
        #"{"method":"Network.requestWillBeSent","params":{"requestId":"page-request","frameId":"frame-7.1","loaderId":"page-loader","targetId":""}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Network.requestWillBeSent","params":{"requestId":"unrecorded-request","frameId":"frame-7.1","loaderId":"unrecorded-loader","targetId":""}}"#
    )

    let recorded = try #require(await iterator.next())
    let unrecorded = try #require(await iterator.next())
    #expect(recorded.networkOriginTargetID == ProtocolTarget.ID("page-main"))
    #expect(unrecorded.networkOriginTargetID == nil)
}

@Test
func transportUsesNonemptyRootNetworkTargetIDAsExactPageOrigin() async throws {
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
    let stream = await transport.events(for: .network)
    var iterator = stream.makeAsyncIterator()

    await transport.receiveRootMessage(
        #"{"method":"Network.requestWillBeSent","params":{"requestId":"current-seed","frameId":"main-frame","loaderId":"shared-loader","targetId":"page-current"}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Network.requestWillBeSent","params":{"requestId":"provisional-request","frameId":"main-frame","loaderId":"shared-loader","targetId":"page-provisional"}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Network.responseReceived","params":{"requestId":"provisional-request","frameId":"main-frame","loaderId":"shared-loader"}}"#
    )

    let current = try #require(await iterator.next())
    let provisional = try #require(await iterator.next())
    let followUp = try #require(await iterator.next())
    #expect(current.networkOriginTargetID == ProtocolTarget.ID("page-current"))
    #expect(provisional.networkOriginTargetID == ProtocolTarget.ID("page-provisional"))
    #expect(followUp.networkOriginTargetID == ProtocolTarget.ID("page-provisional"))
}

@Test
func transportResolvesEmptyRootNetworkTargetIDFromExactFrameTopology() async throws {
    let transport = TransportSession(
        backend: FakeTransportBackend(),
        protocolProfile: .latest,
        responseTimeout: .milliseconds(750)
    )
    await installPageTarget(in: transport)
    await installMainPageFrame(in: transport)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-42-7","type":"frame","isProvisional":false,"isPaused":false}}}"#
    )
    await installFrame(
        ProtocolFrame.ID("frame-7.42"),
        parentFrameID: ProtocolFrame.ID("frame-7.1"),
        in: transport
    )
    let stream = await transport.events(for: .network)
    var iterator = stream.makeAsyncIterator()

    await transport.receiveRootMessage(
        #"{"method":"Network.requestWillBeSent","params":{"requestId":"frame-request","frameId":"frame-7.42","loaderId":"child-loader","targetId":""}}"#
    )

    let event = try #require(await iterator.next())
    #expect(event.networkOriginTargetID == ProtocolTarget.ID("frame-42-7"))
}

@Test
func transportResolvesRootWorkerTargetIDToOwningFrameLoader() async throws {
    let transport = TransportSession(
        backend: FakeTransportBackend(),
        responseTimeout: .milliseconds(750)
    )
    await installPageTarget(
        in: transport,
        targetID: ProtocolTarget.ID("page-main"),
        frameID: "main-frame"
    )
    await transport.receiveRootMessage(
        #"{"method":"Page.frameNavigated","params":{"frame":{"id":"main-frame","loaderId":"main-loader"}}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"worker-1","type":"worker","frameId":"main-frame","isProvisional":false}}}"#
    )
    let stream = await transport.events(for: .network)
    var iterator = stream.makeAsyncIterator()

    await transport.receiveRootMessage(
        #"{"method":"Network.requestWillBeSent","params":{"requestId":"worker-request","frameId":"main-frame","loaderId":"main-loader","targetId":"worker-1"}}"#
    )

    let event = try #require(await iterator.next())
    #expect(event.networkOriginTargetID == ProtocolTarget.ID("page-main"))
}

@Test
func transportRemovesDestroyedTargetFromFrameLoaderOrigins() async throws {
    let transport = TransportSession(
        backend: FakeTransportBackend(),
        responseTimeout: .milliseconds(750)
    )
    await installPageTarget(in: transport)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-target","type":"frame","isProvisional":false}}}"#
    )
    let stream = await transport.events(for: .network)
    var iterator = stream.makeAsyncIterator()

    await transport.receiveRootMessage(
        #"{"method":"Network.requestWillBeSent","params":{"requestId":"frame-request","frameId":"child-frame","loaderId":"child-loader","targetId":"frame-target"}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Network.responseReceived","params":{"requestId":"before-destroy","frameId":"child-frame","loaderId":"child-loader"}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"frame-target"}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-target","type":"frame","isProvisional":false}}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Network.requestWillBeSent","params":{"requestId":"recreated-request","frameId":"other-frame","loaderId":"other-loader","targetId":"frame-target"}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Network.responseReceived","params":{"requestId":"late-response","frameId":"child-frame","loaderId":"child-loader"}}"#
    )

    _ = try #require(await iterator.next())
    let beforeDestroy = try #require(await iterator.next())
    let recreated = try #require(await iterator.next())
    let lateResponse = try #require(await iterator.next())
    #expect(beforeDestroy.networkOriginTargetID == ProtocolTarget.ID("frame-target"))
    #expect(recreated.networkOriginTargetID == ProtocolTarget.ID("frame-target"))
    #expect(lateResponse.networkOriginTargetID == nil)
}

@Test
func transportKeepsRootNetworkOwnersAcrossCurrentAndProvisionalInterleaving() async throws {
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
        #"{"method":"Page.frameNavigated","params":{"frame":{"id":"main-frame","loaderId":"current-loader"}}}"#
    )
    let stream = await transport.events(for: .network)
    var iterator = stream.makeAsyncIterator()

    await transport.receiveRootMessage(
        #"{"method":"Network.responseReceived","params":{"requestId":"current-request","frameId":"main-frame","loaderId":"current-loader"}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-provisional","type":"page","frameId":"main-frame","isProvisional":true}}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Network.responseReceived","params":{"requestId":"provisional-request","frameId":"main-frame","loaderId":"provisional-loader"}}"#
    )

    let currentBeforeCommit = try #require(await iterator.next())
    let unknownBeforeCommit = try #require(await iterator.next())
    #expect(currentBeforeCommit.networkOriginTargetID == ProtocolTarget.ID("page-current"))
    #expect(unknownBeforeCommit.networkOriginTargetID == nil)

    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-current","newTargetId":"page-provisional"}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Page.frameNavigated","params":{"frame":{"id":"main-frame","loaderId":"provisional-loader"}}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Network.responseReceived","params":{"requestId":"current-request","frameId":"main-frame","loaderId":"current-loader"}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Network.responseReceived","params":{"requestId":"provisional-request","frameId":"main-frame","loaderId":"provisional-loader"}}"#
    )

    let currentAfterCommit = try #require(await iterator.next())
    let provisionalAfterCommit = try #require(await iterator.next())
    #expect(currentAfterCommit.networkOriginTargetID == ProtocolTarget.ID("page-current"))
    #expect(provisionalAfterCommit.networkOriginTargetID == ProtocolTarget.ID("page-provisional"))
}

@Test
func transportResetsRootNetworkOwnerWhenRequestIDIsReused() async throws {
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
        #"{"method":"Page.frameNavigated","params":{"frame":{"id":"main-frame","loaderId":"current-loader"}}}"#
    )
    let stream = await transport.events(for: .network)
    var iterator = stream.makeAsyncIterator()

    await transport.receiveRootMessage(
        #"{"method":"Network.requestWillBeSent","params":{"requestId":"reused-request","frameId":"main-frame","loaderId":"current-loader"}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Network.loadingFinished","params":{"requestId":"reused-request"}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-provisional","type":"page","frameId":"main-frame","isProvisional":true}}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Network.requestWillBeSent","params":{"requestId":"reused-request","frameId":"main-frame","loaderId":"provisional-loader"}}"#
    )

    let firstLifecycle = try #require(await iterator.next())
    _ = try #require(await iterator.next())
    let reusedLifecycle = try #require(await iterator.next())
    #expect(firstLifecycle.networkOriginTargetID == ProtocolTarget.ID("page-current"))
    #expect(reusedLifecycle.networkOriginTargetID == nil)
}

@Test
func transportResolvesWorkerWrappedNetworkEventToOwningFrame() async throws {
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
        #"{"method":"Page.frameNavigated","params":{"frame":{"id":"main-frame","loaderId":"current-loader"}}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"worker-1","type":"worker","frameId":"main-frame","isProvisional":false}}}"#
    )
    let stream = await transport.events(for: .network)
    var iterator = stream.makeAsyncIterator()

    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("worker-1"),
        method: "Network.requestWillBeSent",
        params: #"{"requestId":"shared-request-id","frameId":"main-frame","loaderId":"current-loader"}"#
    )

    let workerEvent = try #require(await iterator.next())
    #expect(workerEvent.networkOriginTargetID == ProtocolTarget.ID("page-current"))

    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-provisional","type":"page","frameId":"main-frame","isProvisional":true}}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Network.responseReceived","params":{"requestId":"shared-request-id","frameId":"main-frame","loaderId":"provisional-loader"}}"#
    )

    let rootEvent = try #require(await iterator.next())
    #expect(rootEvent.networkOriginTargetID == nil)
}

@Test
func transportBackendUsesTargetWrappedNetworkEventSourceAfterFrameMappingChanges() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(
        in: transport,
        targetID: ProtocolTarget.ID("page-current"),
        frameID: "main-frame"
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-provisional","type":"page","frameId":"main-frame","isProvisional":true}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let eventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .network)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-current"),
        method: "Network.responseReceived",
        params: #"{"requestId":"current-response","frameId":"main-frame","loaderId":"current-loader","response":{"url":"https://example.test/current","status":200,"headers":{}},"timestamp":1}"#
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .responseReceived(_, response, _, _) = event else {
        Issue.record("Expected Network.responseReceived.")
        return
    }
    #expect(response.origin?.targetID == "page-current")
}

@Test
func transportBackendRoutesProcessQualifiedRequestThroughLatestRootAgent() async throws {
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
    await installFrame(
        ProtocolFrame.ID("frame-7.42"),
        parentFrameID: ProtocolFrame.ID("frame-7.1"),
        in: transport
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()
    #expect(target.route == .currentPage)

    let eventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        let requestWillBeSent = await iterator.next()
        let responseReceived = await iterator.next()
        return [requestWillBeSent, responseReceived].compactMap { $0 }
    }

    await waitForEventSubscription(target, domain: .network)
    await transport.receiveRootMessage(
        #"{"method":"Network.requestWillBeSent","params":{"requestId":"request-7.99","frameId":"frame-7.42","loaderId":"loader-7.42","targetId":"","request":{"url":"https://frame.example.test/","method":"GET"},"initiator":{"type":"other","nodeId":7},"timestamp":7.5,"type":"Document"}}"#
    )

    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-42-8","type":"frame","isProvisional":true,"isPaused":false}}}"#
    )
    await installFrame(
        ProtocolFrame.ID("frame-8.42"),
        parentFrameID: ProtocolFrame.ID("frame-7.1"),
        in: transport
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"frame-42-7","newTargetId":"frame-42-8"}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"frame-42-7"}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Network.responseReceived","params":{"requestId":"request-7.99","frameId":"frame-7.42","loaderId":"loader-7.42","type":"Document","response":{"url":"https://frame.example.test/","status":200,"statusText":"OK","mimeType":"text/html","headers":{},"source":"network"},"timestamp":8}}"#
    )

    let events = try await value(of: eventTask)
    #expect(events.count == 2)
    guard case let .requestWillBeSent(id, request, initiator, resourceType, _, timestamp) = events[0] else {
        Issue.record("Expected current-page route to receive frame Network.requestWillBeSent.")
        return
    }
    #expect(id == Network.Request.ID("request-7.99"))
    #expect(request.id == id)
    #expect(request.url == "https://frame.example.test/")
    #expect(request.method == "GET")
    #expect(initiator.nodeID == DOM.Node.ID("7"))
    #expect(resourceType == .document)
    #expect(timestamp == 7.5)
    guard case let .responseReceived(responseID, _, _, _) = events[1] else {
        Issue.record("Expected responseReceived after the frame target commit.")
        return
    }
    #expect(responseID == id)

    let bodyTask = Task {
        try await target.network.responseBody(for: id)
    }
    let rootMessage = try await throwingValue(of: Task {
        try await backend.waitForMessage()
    })
    #expect(try messageMethod(rootMessage) == "Network.getResponseBody")
    #expect(try messageParameters(rootMessage)["requestId"] as? String == "request-7.99")
    #expect(await backend.sentTargetMessages().isEmpty)
    await transport.receiveRootMessage(
        #"{"id":\#(try messageID(rootMessage)),"result":{"body":"frame body","base64Encoded":false}}"#
    )
    #expect(try await bodyTask.value.data == "frame body")
}

@Test
func transportBackendTreatsUnboundNetworkInitiatorNodeAsMissing() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let eventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .network)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.requestWillBeSent",
        params: #"{"requestId":"zero-node","frameId":"main-frame","loaderId":"main-loader","request":{"url":"https://example.test/","method":"GET"},"initiator":{"type":"other","nodeId":0},"timestamp":1}"#
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .requestWillBeSent(_, _, initiator, _, _, _) = event else {
        Issue.record("Expected Network.requestWillBeSent.")
        return
    }
    #expect(initiator.nodeID == nil)
}

@Test
func transportBackendDropsNonPageDestroyAfterPageDestroyed() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend)
    await installPageTarget(in: transport, targetID: ProtocolTarget.ID("page-main"))
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-target","type":"frame","frameId":"child-frame","parentFrameId":"main-frame","isProvisional":false}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()
    let eventsTask = Task {
        var iterator = target.lifecycleEvents.makeAsyncIterator()
        return (await iterator.next(), await iterator.next())
    }
    defer { eventsTask.cancel() }
    await waitForEventSubscription(target, domain: .target)

    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"page-main"}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"frame-target"}}"#
    )
    await installPageTarget(in: transport, targetID: ProtocolTarget.ID("page-replacement"))

    let (first, second) = try await value(of: eventsTask)
    guard case .targetDestroyed(.currentPage) = try #require(first) else {
        Issue.record("Expected the inspected page's destruction.")
        return
    }
    guard case let .unknown(event) = try #require(second) else {
        Issue.record("Expected the replacement creation after the inspected page's destruction.")
        return
    }
    #expect(event.domain == "Target")
    #expect(event.method == "targetCreated")
    await proxy.close()
}

@Test
func transportBackendDecodesMemoryCacheResourceType() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let eventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .network)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.requestServedFromMemoryCache",
        params: #"{"requestId":"cached-1","frameId":"main-frame","loaderId":"main-loader","documentURL":"https://example.test/","timestamp":3,"initiator":{"type":"other"},"resource":{"url":"https://example.test/app.css","type":"Stylesheet","bodySize":1234,"response":{"url":"https://example.test/app.css","status":200,"mimeType":"text/css","headers":{}}}}"#
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .requestServedFromMemoryCache(id, response, _, resourceType, timestamp) = event else {
        Issue.record("Expected Network.requestServedFromMemoryCache event.")
        return
    }
    #expect(id == Network.Request.ID("cached-1"))
    #expect(response.url == "https://example.test/app.css")
    #expect(response.bodySize == 1234)
    #expect(
        response.origin == Network.Request.Origin(
            frameID: FrameID("main-frame"),
            loaderID: "main-loader",
            targetID: "page-main"
        )
    )
    #expect(resourceType == .stylesheet)
    #expect(timestamp == 3)
}

@Test
func transportBackendKeepsBackendResourceIdentifierOnScopedFrameRequests() async throws {
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
    await installFrame(
        ProtocolFrame.ID("frame-7.42"),
        parentFrameID: ProtocolFrame.ID("frame-7.1"),
        in: transport
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let eventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .network)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("frame-42-7"),
        method: "Network.requestWillBeSent",
        params: #"{"requestId":"frame-cached","frameId":"child-frame","loaderId":"child-loader","request":{"url":"https://frame.example.test/cached","method":"GET"},"initiator":{"type":"other"},"timestamp":1,"type":"Image","backendResourceIdentifier":{"sourceProcessID":"9","resourceID":"42"}}"#
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .requestWillBeSent(id, request, _, _, _, _) = event else {
        Issue.record("Expected projected frame Network.requestWillBeSent.")
        return
    }
    #expect(id.targetScopeRawValue == "frame-42-7")
    #expect(request.backendResourceIdentifier == Network.BackendResourceID(
        sourceProcessID: "9",
        resourceID: "42"
    ))
}

@Test
func transportBackendRoutesFrameOwnedRequestNodeThroughFrameDOMAgent() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(
        backend: backend,
        protocolProfile: .latest,
        responseTimeout: .milliseconds(750)
    )
    await installPageTarget(in: transport)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-42-7","type":"frame","isProvisional":false,"isPaused":false}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let requestNodeTask = Task {
        try await target.dom.requestNode(
            forRemoteObject: Runtime.RemoteObject.ID("frame-object", scopedToTargetRawValue: "frame-42-7")
        )
    }
    let requestNode = try await waitForTargetMessage(backend, method: "DOM.requestNode")
    #expect(requestNode.targetIdentifier == ProtocolTarget.ID("frame-42-7"))
    #expect(try messageParameters(requestNode.message)["objectId"] as? String == "frame-object")
    await receiveTargetReply(
        transport,
        targetID: requestNode.targetIdentifier,
        messageID: try messageID(requestNode.message),
        result: #"{"nodeId":"frame-node"}"#
    )
    let nodeID = try await requestNodeTask.value
    #expect(nodeID == DOM.Node.ID("frame-node", scopedToTargetRawValue: "frame-42-7"))
    #expect(nodeID.targetScopeRawValue == "frame-42-7")
}

@Test
func transportBackendForwardsBackendResourceIdentifierToResponseBodyCommand() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let eventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .network)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.requestWillBeSent",
        params: #"{"requestId":"cached-request","frameId":"main-frame","loaderId":"main-loader","request":{"url":"https://example.test/cached","method":"GET"},"initiator":{"type":"other"},"timestamp":1,"type":"Image","backendResourceIdentifier":{"sourceProcessID":"77","resourceID":"1234"}}"#
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .requestWillBeSent(id, request, _, _, _, _) = event else {
        Issue.record("Expected Network.requestWillBeSent for the current page.")
        return
    }
    #expect(request.backendResourceIdentifier == Network.BackendResourceID(
        sourceProcessID: "77",
        resourceID: "1234"
    ))

    let bodyTask = Task {
        try await target.network.responseBody(
            for: id,
            backendResourceIdentifier: request.backendResourceIdentifier
        )
    }
    let bodyCommand = try await waitForTargetMessage(backend, method: "Network.getResponseBody")
    let parameters = try messageParameters(bodyCommand.message)
    #expect(parameters["requestId"] as? String == "cached-request")
    let identifier = try #require(parameters["backendResourceIdentifier"] as? [String: Any])
    #expect(identifier["sourceProcessID"] as? String == "77")
    #expect(identifier["resourceID"] as? String == "1234")
    await receiveTargetReply(
        transport,
        targetID: bodyCommand.targetIdentifier,
        messageID: try messageID(bodyCommand.message),
        result: #"{"body":"cached body","base64Encoded":false}"#
    )
    let body = try await bodyTask.value
    #expect(body.data == "cached body")
}

@Test
func transportBackendAssociatesFrameTargetCreatedAfterPageTopology() async throws {
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
    await installFrame(
        ProtocolFrame.ID("frame-7.42"),
        parentFrameID: ProtocolFrame.ID("frame-7.20"),
        in: transport
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-42-7","type":"frame","isProvisional":false,"isPaused":false}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()
    #expect(target.route == .currentPage)

    let eventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .network)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("frame-42-7"),
        method: "Network.requestWillBeSent",
        params: #"{"requestId":"frame-request","frameId":"child-frame","loaderId":"child-loader","request":{"url":"https://frame.example.test/","method":"GET"},"initiator":{"type":"other"},"timestamp":7.5,"type":"Document"}"#
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .requestWillBeSent(id, request, _, resourceType, _, timestamp) = event else {
        Issue.record("Expected current-page route to receive the navigated frame event.")
        return
    }
    #expect(id == Network.Request.ID("frame-request", scopedToTargetRawValue: "frame-42-7"))
    #expect(request.id == id)
    #expect(request.url == "https://frame.example.test/")
    #expect(request.method == "GET")
    #expect(resourceType == .document)
    #expect(timestamp == 7.5)
}

@Test
func transportBackendTreatsLatestRootNetworkTargetAsProcessMetadata() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(
        backend: backend,
        protocolProfile: .latest,
        responseTimeout: .milliseconds(750)
    )
    await installPageTarget(in: transport)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-other","type":"page","isProvisional":false,"isPaused":false}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()
    #expect(target.route == .currentPage)

    let eventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .network)
    await transport.receiveRootMessage(
        #"{"method":"Network.requestWillBeSent","params":{"requestId":"request-8.1","frameId":"frame-8.1","loaderId":"loader-8.1","targetId":"page-other","request":{"url":"https://other-page.example.test/","method":"GET"},"initiator":{"type":"other"},"timestamp":8.5,"type":"Document"}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Network.requestWillBeSent","params":{"requestId":"request-7.1","frameId":"frame-7.1","loaderId":"loader-7.1","targetId":"page-main","request":{"url":"https://current-page.example.test/","method":"GET"},"initiator":{"type":"other"},"timestamp":9,"type":"Document"}}"#
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .requestWillBeSent(id, request, _, _, _, _) = event else {
        Issue.record("Expected inspected-page Network.requestWillBeSent.")
        return
    }
    #expect(id == Network.Request.ID("request-8.1"))
    #expect(id.targetScopeRawValue == nil)
    #expect(request.url == "https://other-page.example.test/")
}

@Test
func transportBackendDeliversLatestRootNetworkWithoutFrameTopology() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(
        backend: backend,
        protocolProfile: .latest,
        responseTimeout: .milliseconds(750)
    )
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let eventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .network)
    await transport.receiveRootMessage(
        #"{"method":"Network.requestWillBeSent","params":{"requestId":"request-404.1","frameId":"frame-404.1","loaderId":"loader-404.1","targetId":"","request":{"url":"https://unresolved.example.test/","method":"GET"},"initiator":{"type":"other"},"timestamp":9.5,"type":"Document"}}"#
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .requestWillBeSent(id, request, _, _, _, _) = event else {
        Issue.record("Expected topology-independent Network.requestWillBeSent.")
        return
    }
    #expect(id == Network.Request.ID("request-404.1"))
    #expect(id.targetScopeRawValue == nil)
    #expect(request.url == "https://unresolved.example.test/")
}

@Test
func transportBackendPreservesLargeLatestRootNetworkBurstInFIFOOrder() async throws {
    let eventCount = 2_305
    let backend = FakeTransportBackend()
    let transport = TransportSession(
        backend: backend,
        protocolProfile: .latest,
        responseTimeout: .milliseconds(750)
    )
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let eventTask = Task { () -> [Network.Request.ID] in
        var requestIDs: [Network.Request.ID] = []
        requestIDs.reserveCapacity(eventCount)
        for await event in target.network.events {
            guard case let .requestWillBeSent(id, _, _, _, _, _) = event else {
                continue
            }
            requestIDs.append(id)
            if requestIDs.count == eventCount {
                break
            }
        }
        return requestIDs
    }

    await waitForEventSubscription(target, domain: .network)
    for index in 0..<eventCount {
        let requestID = "request-\(index + 1).\(index + 100)"
        let message = """
        {"method":"Network.requestWillBeSent","params":{"requestId":"\(requestID)","frameId":"frame-\(index).1","loaderId":"loader-\(index)","targetId":"","request":{"url":"https://example.test/\(index)","method":"GET"},"initiator":{"type":"other"},"timestamp":\(index),"type":"Image"}}
        """
        await transport.receiveRootMessage(
            message
        )
    }

    let requestIDs = try await value(of: eventTask, timeout: .seconds(10))
    #expect(requestIDs.count == eventCount)
    #expect(requestIDs == (0..<eventCount).map {
        Network.Request.ID("request-\($0 + 1).\($0 + 100)")
    })
    #expect(requestIDs.allSatisfy { $0.targetScopeRawValue == nil })
}

@Test
func transportBackendDecodesWebSocketHandshakeEventsForTargetRoute() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(
        backend: backend,
        protocolProfile: .latest,
        responseTimeout: .milliseconds(750)
    )
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: LiveWebInspectorProxyBackend(transport: transport)))

    let requestEventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .network)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.webSocketWillSendHandshakeRequest",
        params: #"{"requestId":"ws-1","timestamp":1.25,"request":{"headers":{"Upgrade":"websocket","Sec-WebSocket-Key":"abc"}}}"#
    )

    let requestEvent = try #require(try await value(of: requestEventTask))
    guard case let .webSocket(.handshakeRequest(id, request, timestamp)) = requestEvent else {
        Issue.record("Expected Network.webSocketWillSendHandshakeRequest.")
        return
    }
    #expect(id == Network.Request.ID("ws-1"))
    #expect(request.id == Network.Request.ID("ws-1"))
    #expect(request.method == "GET")
    #expect(request.headers["Upgrade"] == "websocket")
    #expect(request.headers["Sec-WebSocket-Key"] == "abc")
    #expect(timestamp == 1.25)

    let responseEventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .network)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.webSocketHandshakeResponseReceived",
        params: #"{"requestId":"ws-1","timestamp":2.5,"response":{"status":101,"statusText":"Switching Protocols","headers":{"Upgrade":"websocket"}}}"#
    )

    let responseEvent = try #require(try await value(of: responseEventTask))
    guard case let .webSocket(.handshakeResponse(responseID, response, responseTimestamp)) = responseEvent else {
        Issue.record("Expected Network.webSocketHandshakeResponseReceived.")
        return
    }
    #expect(responseID == Network.Request.ID("ws-1"))
    #expect(response.status == 101)
    #expect(response.statusText == "Switching Protocols")
    #expect(response.headers["Upgrade"] == "websocket")
    #expect(responseTimestamp == 2.5)
}

@Test
func transportBackendPreservesEveryWebSocketOpcodeDirectionMaskAndPayloadMetadata() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(
        backend: backend,
        protocolProfile: .latest,
        responseTimeout: .milliseconds(750)
    )
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: LiveWebInspectorProxyBackend(transport: transport)))
    let cases: [(method: String, opcode: Int, mask: Bool, payload: String, length: Int)] = [
        ("Network.webSocketFrameSent", 0, false, "AA==", 1),
        ("Network.webSocketFrameSent", 1, true, "sent text", 9),
        ("Network.webSocketFrameReceived", 1, false, "received text", 13),
        ("Network.webSocketFrameReceived", 2, true, "AQID", 3),
        ("Network.webSocketFrameSent", 8, false, "A+g=", 2),
        ("Network.webSocketFrameReceived", 9, false, "", 0),
        ("Network.webSocketFrameSent", 10, true, "BA==", 1),
        ("Network.webSocketFrameReceived", 42, true, "BQY=", 2),
    ]

    let eventsTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        var events: [Network.WebSocketEvent] = []
        while events.count < cases.count, let event = await iterator.next() {
            guard case let .webSocket(webSocketEvent) = event else {
                continue
            }
            events.append(webSocketEvent)
        }
        return events
    }

    await waitForEventSubscription(target, domain: .network)
    for (index, testCase) in cases.enumerated() {
        await receiveTargetEvent(
            transport,
            targetID: ProtocolTarget.ID("page-main"),
            method: testCase.method,
            params: """
            {"requestId":"ws-opcodes","timestamp":\(Double(index) + 0.5),"response":{"opcode":\(testCase.opcode),"mask":\(testCase.mask),"payloadData":"\(testCase.payload)","payloadLength":\(testCase.length)}}
            """
        )
    }

    let events = try await value(of: eventsTask)
    #expect(events.count == cases.count)
    for (index, pair) in zip(cases.indices, zip(cases, events)) {
        let (testCase, event) = pair
        let id: Network.Request.ID
        let frame: Network.WebSocketFrame
        let timestamp: Double
        switch event {
        case let .frameSent(eventID, eventFrame, eventTimestamp):
            #expect(testCase.method == "Network.webSocketFrameSent")
            id = eventID
            frame = eventFrame
            timestamp = eventTimestamp
        case let .frameReceived(eventID, eventFrame, eventTimestamp):
            #expect(testCase.method == "Network.webSocketFrameReceived")
            id = eventID
            frame = eventFrame
            timestamp = eventTimestamp
        default:
            Issue.record("Expected a WebSocket frame event.")
            continue
        }
        #expect(id == Network.Request.ID("ws-opcodes"))
        #expect(frame.opcode == testCase.opcode)
        #expect(frame.mask == testCase.mask)
        #expect(frame.payloadData == testCase.payload)
        #expect(frame.payloadLength == testCase.length)
        #expect(timestamp == Double(index) + 0.5)
    }
}

@Test
func transportBackendPreservesPresentEmptyMetricsRequestHeaders() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: LiveWebInspectorProxyBackend(transport: transport)))

    let eventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .network)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.loadingFinished",
        params: #"{"requestId":"empty-request-headers","timestamp":4,"metrics":{"requestHeaders":{}}}"#
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .loadingFinished(_, _, _, metrics) = event else {
        Issue.record("Expected Network.loadingFinished.")
        return
    }
    #expect(metrics?.requestHeaders == [:])
}
