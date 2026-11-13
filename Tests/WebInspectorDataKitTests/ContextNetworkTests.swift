import Foundation
import Observation
import ObservationBridge
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import WebInspectorTestSupport

@MainActor
@Test
func frameNavigationPrecedesFollowingNetworkRequestInSourceOrder() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)

    await emitOriginatedNetworkRequest(
        id: "before-navigation",
        loaderID: "loader-before",
        originTargetID: nil,
        timestamp: 1,
        target: target,
        backend: runtime.backend
    )
    try await waitUntil { context.network.requests.count == 1 }
    let previousVisit = try #require(context.network.requests[0].navigationVisit)

    await runtime.backend.enqueue(
        DOM.Node(id: DOM.Node.ID("network-navigation-root"), nodeType: 9, nodeName: "#document"),
        for: "DOM",
        method: "getDocument"
    )
    await runtime.backend.emit(
        .frameNavigated(WebInspectorPageFrameLifecycle(
            id: FrameID("main-frame"),
            parentID: nil,
            loaderID: "loader-after",
            name: "Main",
            url: "https://example.test/after",
            securityOrigin: "https://example.test",
            mimeType: "text/html"
        )),
        target: target
    )
    await emitOriginatedNetworkRequest(
        id: "after-navigation",
        loaderID: "loader-after",
        originTargetID: nil,
        timestamp: 2,
        target: target,
        backend: runtime.backend
    )

    try await waitUntil { context.network.requests.count == 2 }
    let currentVisit = try #require(context.network.requests[1].navigationVisit)
    #expect(currentVisit != previousVisit)
    #expect(context.state == .attached)
}

@MainActor
@Test
func startBeginsFreshNetworkAttachmentEpoch() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let staleRequestID = Network.Request.ID("stale-before-restart")

    await emitFinishedRequest(id: staleRequestID, target: target, backend: runtime.backend)
    try await waitUntil {
        context.network.requests.map(\.id) == [NetworkRequest.ID(staleRequestID)]
    }

    await enqueueDomainDisableReplies(on: runtime.backend)
    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: DOM.Node.ID("fresh-after-restart"), nodeType: 9, nodeName: "#document")
    )

    context.start()

    try await waitUntil { context.network.requests.isEmpty }
    try await waitUntil(in: context) {
        context.rootNode?.id == DOMNode.ID(DOM.Node.ID("fresh-after-restart"))
            && context.state == .attached
    }
    #expect(context.network.requests.isEmpty)
}

@MainActor
@Test
func networkNavigationVisitIdentityDoesNotRepeatAcrossRestart() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)

    await runtime.backend.emit(
        .requestWillBeSent(
            id: Network.Request.ID("before-restart"),
            request: Network.Request(
                id: Network.Request.ID("before-restart"),
                url: "https://example.test/before-restart",
                method: "GET",
                origin: Network.Request.Origin(
                    frameID: FrameID("main-frame"),
                    loaderID: "main-loader",
                    targetID: nil
                )
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    try await waitUntil { context.network.requests.count == 1 }
    let retainedVisit = try #require(context.network.requests.first?.navigationVisit)

    await enqueueDomainDisableReplies(on: runtime.backend)
    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: DOM.Node.ID("restart-identity-root"), nodeType: 9, nodeName: "#document")
    )
    context.start()
    try await waitUntil { context.network.requests.isEmpty }
    try await waitUntil(in: context) {
        context.rootNode?.id == DOMNode.ID(DOM.Node.ID("restart-identity-root"))
            && context.state == .attached
    }

    await runtime.backend.emit(
        .requestWillBeSent(
            id: Network.Request.ID("after-restart"),
            request: Network.Request(
                id: Network.Request.ID("after-restart"),
                url: "https://example.test/after-restart",
                method: "GET",
                origin: Network.Request.Origin(
                    frameID: FrameID("main-frame"),
                    loaderID: "main-loader",
                    targetID: nil
                )
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 2
        ),
        target: target
    )
    try await waitUntil { context.network.requests.count == 1 }
    let restartedVisit = try #require(context.network.requests.first?.navigationVisit)
    #expect(restartedVisit != retainedVisit)
}

@MainActor
@Test
func networkNavigationGroupsEachAtoBtoAFrameVisitSeparately() async throws {
    let targetID = ProtocolTarget.ID("page-main")
    let (_, transport, context) = try await startTransportBackedContext(
        targetID: targetID,
        documentID: "navigation-visit-root"
    )

    for (index, visit) in [
        ("loader-a", "a-first", 1.0),
        ("loader-b", "b", 2.0),
        ("loader-a", "a-return", 3.0),
    ].enumerated() {
        let (loaderID, prefix, timestamp) = visit
        await emitTransportNetworkRequest(
            id: "\(prefix)-provisional",
            frameID: "child-frame",
            loaderID: loaderID,
            timestamp: timestamp,
            targetID: targetID,
            transport: transport
        )
        try await waitUntil { context.network.requests.count == index * 2 + 1 }

        await emitTransportFrameNavigated(
            frameID: "child-frame",
            loaderID: loaderID,
            targetID: targetID,
            transport: transport
        )
        await emitTransportNetworkRequest(
            id: "\(prefix)-committed",
            frameID: "child-frame",
            loaderID: loaderID,
            timestamp: timestamp + 0.5,
            targetID: targetID,
            transport: transport
        )
        try await waitUntil { context.network.requests.count == (index + 1) * 2 }
    }

    let visits = try context.network.requests.map { request in
        try #require(request.navigationVisit)
    }
    #expect(visits.count == 6)
    #expect(Dictionary(grouping: visits, by: { $0 }).values.map(\.count).sorted() == [2, 2, 2])
    #expect(visits[0] == visits[1])
    #expect(visits[2] == visits[3])
    #expect(visits[4] == visits[5])
    #expect(visits[0] != visits[4])
}

@MainActor
@Test
func ambiguousFrameCommitDoesNotGuessBetweenPendingNetworkTargets() async throws {
    let context = WebInspectorContext.preview()

    await applyOriginatedNetworkRequest(
        id: "ambiguous-current",
        loaderID: "current-loader",
        originTargetID: "page-current",
        timestamp: 1,
        context: context
    )
    await applyOriginatedNetworkRequest(
        id: "ambiguous-first-pending",
        loaderID: "shared-pending-loader",
        originTargetID: "page-next-1",
        timestamp: 2,
        context: context
    )
    await applyOriginatedNetworkRequest(
        id: "ambiguous-second-pending",
        loaderID: "shared-pending-loader",
        originTargetID: "page-next-2",
        timestamp: 3,
        context: context
    )
    let firstPendingVisit = try #require(context.network.requests[1].navigationVisit)
    let secondPendingVisit = try #require(context.network.requests[2].navigationVisit)
    await applyOriginatedNetworkRequest(
        id: "ambiguous-unattributed-pending",
        loaderID: "shared-pending-loader",
        originTargetID: nil,
        timestamp: 4,
        context: context
    )
    let unattributedPendingVisit = try #require(context.network.requests[3].navigationVisit)

    context.apply(.frameNavigated(WebInspectorPageFrameLifecycle(
        id: FrameID("main-frame"),
        parentID: nil,
        loaderID: "shared-pending-loader",
        name: "Main",
        url: "https://example.test/next",
        securityOrigin: "https://example.test",
        mimeType: "text/html"
    )))
    await applyOriginatedNetworkRequest(
        id: "ambiguous-committed",
        loaderID: "shared-pending-loader",
        originTargetID: nil,
        timestamp: 5,
        context: context
    )

    let committedVisit = try #require(context.network.requests[4].navigationVisit)
    #expect(firstPendingVisit != secondPendingVisit)
    #expect(unattributedPendingVisit != firstPendingVisit)
    #expect(unattributedPendingVisit != secondPendingVisit)
    #expect(committedVisit == unattributedPendingVisit)
}

@MainActor
@Test
func frameCommitUsesExactPageBindingForPendingNetworkTarget() async throws {
    let context = WebInspectorContext.preview()

    await applyOriginatedNetworkRequest(
        id: "exact-current",
        loaderID: "current-loader",
        originTargetID: "page-current",
        timestamp: 1,
        context: context
    )
    await applyOriginatedNetworkRequest(
        id: "exact-first-pending",
        loaderID: "shared-pending-loader",
        originTargetID: "page-next-1",
        timestamp: 2,
        context: context
    )
    await applyOriginatedNetworkRequest(
        id: "exact-second-pending",
        loaderID: "shared-pending-loader",
        originTargetID: "page-next-2",
        timestamp: 3,
        context: context
    )
    let firstPendingVisit = try #require(context.network.requests[1].navigationVisit)
    let secondPendingVisit = try #require(context.network.requests[2].navigationVisit)

    context.apply(.frameNavigated(WebInspectorPageFrameLifecycle(
        id: FrameID("main-frame"),
        parentID: nil,
        pageBindingID: "page-next-2",
        loaderID: "shared-pending-loader",
        name: "Main",
        url: "https://example.test/next",
        securityOrigin: "https://example.test",
        mimeType: "text/html"
    )))
    await applyOriginatedNetworkRequest(
        id: "exact-committed",
        loaderID: "shared-pending-loader",
        originTargetID: "page-next-2",
        timestamp: 4,
        context: context
    )

    let committedVisit = try #require(context.network.requests[3].navigationVisit)
    #expect(firstPendingVisit != secondPendingVisit)
    #expect(committedVisit == secondPendingVisit)
}

@MainActor
@Test
func frameDetachmentRetainsNetworkHistoryAndLateTerminalEvents() async throws {
    let targetID = ProtocolTarget.ID("page-main")
    let (_, transport, context) = try await startTransportBackedContext(
        targetID: targetID,
        documentID: "detached-frame-root"
    )

    await emitTransportNetworkRequest(
        id: "detached-request",
        frameID: "child-frame",
        loaderID: "child-loader",
        timestamp: 1,
        targetID: targetID,
        transport: transport
    )
    try await waitUntil { context.network.requests.count == 1 }
    let retainedRequest = try #require(context.network.requests.first)
    let retainedVisit = try #require(retainedRequest.navigationVisit)

    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Network.responseReceived",
        params: #"{"requestId":"detached-request","frameId":"child-frame","loaderId":"child-loader","type":"Fetch","response":{"url":"https://example.test/detached-request","status":200,"statusText":"OK","headers":{},"mimeType":"text/plain","source":"network","security":{"connection":{"protocol":"TLS 1.2","cipher":"AES_128_GCM_SHA256"},"certificate":{"subject":"detached.example.test","dnsNames":["detached.example.test"]}}},"timestamp":1.5}"#
    )
    try await waitUntil {
        retainedRequest.status == 200
            && retainedRequest.security?.certificate?.subject == "detached.example.test"
    }

    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Page.frameDetached",
        params: #"{"frameId":"child-frame"}"#
    )
    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Network.loadingFinished",
        params: #"{"requestId":"detached-request","timestamp":2,"metrics":{"securityConnection":{"protocol":"TLS 1.3"}}}"#
    )
    try await waitUntil { retainedRequest.state == .finished }

    #expect(context.network.requests == [retainedRequest])
    #expect(retainedRequest.navigationVisit == retainedVisit)
    #expect(retainedRequest.security?.connection?.tlsProtocol == "TLS 1.3")
    #expect(retainedRequest.security?.connection?.cipher == "AES_128_GCM_SHA256")
    #expect(retainedRequest.security?.certificate?.subject == "detached.example.test")
    #expect(retainedRequest.security?.certificate?.dnsNames == ["detached.example.test"])

    await emitTransportNetworkRequest(
        id: "reused-detached-frame",
        frameID: "child-frame",
        loaderID: "child-loader",
        timestamp: 3,
        targetID: targetID,
        transport: transport
    )
    try await waitUntil { context.network.requests.count == 2 }
    let reusedFrameRequest = try #require(context.network.requests.last)
    #expect(reusedFrameRequest.navigationVisit != retainedVisit)
}

@MainActor
@Test
func memoryCacheOnlyRequestSharesFrameNavigationVisit() async throws {
    let targetID = ProtocolTarget.ID("page-main")
    let (_, transport, context) = try await startTransportBackedContext(
        targetID: targetID,
        documentID: "memory-cache-visit-root"
    )

    await emitTransportFrameNavigated(
        frameID: "child-frame",
        loaderID: "child-loader",
        targetID: targetID,
        transport: transport
    )
    await emitTransportNetworkRequest(
        id: "committed-request",
        frameID: "child-frame",
        loaderID: "child-loader",
        timestamp: 1,
        targetID: targetID,
        transport: transport
    )
    try await waitUntil { context.network.requests.count == 1 }
    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Network.requestServedFromMemoryCache",
        params: #"{"requestId":"cached-only","frameId":"child-frame","loaderId":"child-loader","documentURL":"https://example.test/","timestamp":2,"initiator":{"type":"other"},"resource":{"url":"https://example.test/cached.css","type":"Stylesheet","bodySize":1234,"response":{"url":"https://example.test/cached.css","status":200,"mimeType":"text/css","headers":{}}}}"#
    )
    try await waitUntil { context.network.requests.count == 2 }

    let committedVisit = try #require(context.network.requests[0].navigationVisit)
    let cachedVisit = try #require(context.network.requests[1].navigationVisit)
    #expect(cachedVisit == committedVisit)
}

@MainActor
@Test
func responseOnlyRequestSharesFrameNavigationVisit() async throws {
    let targetID = ProtocolTarget.ID("page-main")
    let (_, transport, context) = try await startTransportBackedContext(
        targetID: targetID,
        documentID: "response-only-visit-root"
    )

    await emitTransportFrameNavigated(
        frameID: "child-frame",
        loaderID: "child-loader",
        targetID: targetID,
        transport: transport
    )
    await emitTransportNetworkRequest(
        id: "committed-request",
        frameID: "child-frame",
        loaderID: "child-loader",
        timestamp: 1,
        targetID: targetID,
        transport: transport
    )
    try await waitUntil { context.network.requests.count == 1 }
    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Network.responseReceived",
        params: #"{"requestId":"response-only","frameId":"child-frame","loaderId":"child-loader","type":"Fetch","response":{"url":"https://example.test/response-only","status":200,"statusText":"OK","headers":{},"mimeType":"text/plain","source":"network"},"timestamp":2}"#
    )
    try await waitUntil { context.network.requests.count == 2 }

    let committedVisit = try #require(context.network.requests[0].navigationVisit)
    let responseVisit = try #require(context.network.requests[1].navigationVisit)
    #expect(responseVisit == committedVisit)
}

@MainActor
@Test
func subframeDetachmentDoesNotAdvanceTopLevelNetworkVisit() async throws {
    let targetID = ProtocolTarget.ID("page-main")
    let (_, transport, context) = try await startTransportBackedContext(
        targetID: targetID,
        documentID: "subframe-detach-top-level-root"
    )

    await emitTransportNetworkRequest(
        id: "top-level-before-detach",
        frameID: "main-frame",
        loaderID: "top-level-loader",
        timestamp: 1,
        targetID: targetID,
        transport: transport
    )
    await emitTransportNetworkRequest(
        id: "subframe-before-detach",
        frameID: "child-frame",
        loaderID: "child-loader",
        timestamp: 2,
        targetID: targetID,
        transport: transport
    )
    try await waitUntil { context.network.requests.count == 2 }
    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Page.frameDetached",
        params: #"{"frameId":"child-frame"}"#
    )
    await emitTransportNetworkRequest(
        id: "top-level-after-detach",
        frameID: "main-frame",
        loaderID: "top-level-loader",
        timestamp: 3,
        targetID: targetID,
        transport: transport
    )
    try await waitUntil { context.network.requests.count == 3 }

    let beforeDetach = try #require(context.network.requests[0].navigationVisit)
    let afterDetach = try #require(context.network.requests[2].navigationVisit)
    #expect(beforeDetach == afterDetach)
}

@MainActor
@Test
func networkEventWithoutFrameMembershipHasNoNavigationVisit() async throws {
    let targetID = ProtocolTarget.ID("page-main")
    let (_, transport, context) = try await startTransportBackedContext(
        targetID: targetID,
        documentID: "missing-frame-membership-root"
    )

    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Network.responseReceived",
        params: #"{"requestId":"missing-membership","frameId":"","loaderId":"","response":{"url":"https://example.test/missing-membership","status":200,"statusText":"OK","headers":{},"mimeType":"text/plain","source":"network"},"timestamp":1}"#
    )
    try await waitUntil { context.network.requests.count == 1 }

    #expect(context.network.requests[0].navigationVisit == nil)
}

@MainActor
@Test
func latestRootNetworkBurstIsConservedThroughDataKitInFIFOOrder() async throws {
    let eventCount = 2_305
    let targetID = ProtocolTarget.ID("page-main")
    let (_, transport, context) = try await startTransportBackedContext(
        targetID: targetID,
        documentID: "latest-root-network-burst",
        protocolProfile: .latest
    )
    let recorder = CollectionChangeRecorder(stream: context.network.requestChanges)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()

    let expectedRequestIDs = (0..<eventCount).map { index in
        "request-42.\(index + 1)"
    }
    for index in 0..<eventCount {
        let requestID = expectedRequestIDs[index]
        let timestamp = Double(index) + 0.25
        let message = """
        {"method":"Network.requestWillBeSent","params":{"requestId":"\(requestID)","frameId":"frame-42.1","loaderId":"loader-42.1","targetId":"","request":{"url":"https://example.test/resource/\(index)","method":"GET"},"initiator":{"type":"other"},"timestamp":\(timestamp),"type":"Image"}}
        """
        await transport.receiveRootMessage(message)
    }

    try await recorder.waitForChangeCount(
        eventCount,
        timeout: .seconds(30)
    )

    let requests = context.network.requests
    let actualRequestIDs = requests.map(\.id.proxyID)
    let expectedProxyIDs = expectedRequestIDs.map(Network.Request.ID.init)
    #expect(recorder.changes.count == eventCount)
    #expect(requests.count == eventCount)
    #expect(Set(actualRequestIDs).count == eventCount)
    #expect(actualRequestIDs == expectedProxyIDs)
    #expect(actualRequestIDs.allSatisfy { $0.targetScopeRawValue == nil })
    #expect(requests.map(\.url) == (0..<eventCount).map {
        "https://example.test/resource/\($0)"
    })
    #expect(requests.map(\.requestSentTimestamp) == (0..<eventCount).map {
        Double($0) + 0.25
    })
    #expect(requests.allSatisfy { request in
        context.network.request(for: request.id) === request
    })
}

@MainActor
@Test
func delayedNetworkConsumerUsesEventTimeTargetAfterFrameRetarget() async throws {
    let transport = TransportSession(backend: FakeTransportBackend(), responseTimeout: .milliseconds(750))
    await installTransportPageTarget(
        in: transport,
        targetID: ProtocolTarget.ID("page-current"),
        frameID: "main-frame"
    )
    let stream = await transport.events(for: .network)
    var iterator = stream.makeAsyncIterator()

    await transport.receiveRootMessage(
        #"{"method":"Network.responseReceived","params":{"requestId":"event-time-old","frameId":"main-frame","loaderId":"reused-loader","response":{"url":"https://example.test/old","status":200,"headers":{}},"timestamp":1}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-provisional","type":"page","frameId":"main-frame","isProvisional":true}}}"#
    )

    let protocolEvent = try #require(await iterator.next())
    let proxyEvent = try LiveProxyEventDecoder.proxyEvent(
        from: protocolEvent,
        targetID: .currentPage
    )
    guard case let .network(oldNetworkEvent) = proxyEvent else {
        Issue.record("Expected delayed Network event.")
        return
    }

    let context = WebInspectorContext.preview()
    await context.apply(oldNetworkEvent)
    let newID = Network.Request.ID("event-time-new")
    await context.apply(.requestWillBeSent(
        id: newID,
        request: Network.Request(
            id: newID,
            url: "https://example.test/new",
            method: "GET",
            origin: Network.Request.Origin(
                frameID: FrameID("main-frame"),
                loaderID: "reused-loader",
                targetID: "page-provisional"
            )
        ),
        resourceType: .document,
        redirectResponse: nil,
        timestamp: 2
    ))

    let oldVisit = try #require(context.network.requests[0].navigationVisit)
    let newVisit = try #require(context.network.requests[1].navigationVisit)
    #expect(oldVisit != newVisit)
}

@MainActor
@Test
func workerInitiatedRequestSharesOwningFrameNavigationVisit() async throws {
    let transport = TransportSession(backend: FakeTransportBackend(), responseTimeout: .milliseconds(750))
    await installTransportPageTarget(
        in: transport,
        targetID: ProtocolTarget.ID("page-main"),
        frameID: "main-frame"
    )
    let stream = await transport.events(for: .network)
    var iterator = stream.makeAsyncIterator()

    await receiveTransportTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.requestWillBeSent",
        params: #"{"requestId":"document-request","frameId":"main-frame","loaderId":"main-loader","documentURL":"https://example.test/","request":{"url":"https://example.test/","method":"GET"},"initiator":{"type":"other"},"timestamp":1}"#
    )
    await receiveTransportTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.requestWillBeSent",
        params: #"{"requestId":"worker-request","frameId":"main-frame","loaderId":"main-loader","documentURL":"https://example.test/","request":{"url":"https://example.test/worker-data","method":"GET"},"initiator":{"type":"script"},"timestamp":2,"targetId":"worker-1"}"#
    )

    let context = WebInspectorContext.preview()
    for _ in 0..<2 {
        let protocolEvent = try #require(await iterator.next())
        let proxyEvent = try LiveProxyEventDecoder.proxyEvent(
            from: protocolEvent,
            targetID: .currentPage
        )
        guard case let .network(networkEvent) = proxyEvent else {
            Issue.record("Expected Network.requestWillBeSent.")
            return
        }
        await context.apply(networkEvent)
    }

    let documentVisit = try #require(context.network.requests[0].navigationVisit)
    let workerVisit = try #require(context.network.requests[1].navigationVisit)
    #expect(workerVisit == documentVisit)
}

@MainActor
@Test
func abandonedProvisionalTargetDoesNotReuseNetworkNavigationVisit() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)

    await emitOriginatedNetworkRequest(
        id: "abandoned-provisional",
        frameID: "main-frame",
        loaderID: "reused-loader",
        originTargetID: "page-abandoned",
        timestamp: 1,
        target: target,
        backend: runtime.backend
    )
    await emitOriginatedNetworkRequest(
        id: "abandoned-child-provisional",
        frameID: "child-frame",
        loaderID: "child-reused-loader",
        originTargetID: "page-abandoned",
        timestamp: 1.5,
        target: target,
        backend: runtime.backend
    )
    try await waitUntil { context.network.requests.count == 2 }
    await runtime.backend.emit(
        .targetDestroyed(targetID: WebInspectorTarget.ID("page-abandoned")),
        target: target
    )
    await emitOriginatedNetworkRequest(
        id: "later-provisional",
        frameID: "main-frame",
        loaderID: "reused-loader",
        originTargetID: "page-abandoned",
        timestamp: 2,
        target: target,
        backend: runtime.backend
    )
    await emitOriginatedNetworkRequest(
        id: "later-child-provisional",
        frameID: "child-frame",
        loaderID: "child-reused-loader",
        originTargetID: "page-abandoned",
        timestamp: 2.5,
        target: target,
        backend: runtime.backend
    )
    try await waitUntil { context.network.requests.count == 4 }

    let abandonedVisit = try #require(context.network.requests[0].navigationVisit)
    let abandonedChildVisit = try #require(context.network.requests[1].navigationVisit)
    let laterVisit = try #require(context.network.requests[2].navigationVisit)
    let laterChildVisit = try #require(context.network.requests[3].navigationVisit)
    #expect(abandonedVisit != laterVisit)
    #expect(abandonedChildVisit != laterChildVisit)
}

@MainActor
@Test
func targetCommitBeforeFrameCommitDoesNotAdvanceNetworkVisitTwice() async throws {
    let visits = try await networkVisitsAcrossTopLevelCommit(order: .targetThenFrame)

    #expect(visits.provisional == visits.committed)
}

@MainActor
@Test
func frameCommitBeforeTargetCommitDoesNotAdvanceNetworkVisitTwice() async throws {
    let visits = try await networkVisitsAcrossTopLevelCommit(order: .frameThenTarget)

    #expect(visits.provisional == visits.committed)
}

@MainActor
@Test
func targetCommitBeforeFrameCommitPreservesUnattributedNetworkVisit() async throws {
    let visits = try await networkVisitsAcrossTopLevelCommit(
        order: .targetThenFrame,
        provisionalOriginTargetID: nil,
        currentLoaderID: "current-loader",
        provisionalLoaderID: "provisional-loader"
    )

    #expect(visits.provisional == visits.committed)
}

@MainActor
@Test
func frameCommitBeforeTargetCommitPreservesUnattributedNetworkVisit() async throws {
    let visits = try await networkVisitsAcrossTopLevelCommit(
        order: .frameThenTarget,
        provisionalOriginTargetID: nil,
        currentLoaderID: "current-loader",
        provisionalLoaderID: "provisional-loader"
    )

    #expect(visits.provisional == visits.committed)
}

@MainActor
@Test
func ambiguousFrameCommitPreservesCandidatesUntilExactTargetCommit() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)

    await emitOriginatedNetworkRequest(
        id: "candidate-current",
        loaderID: "current-loader",
        originTargetID: "page-current",
        timestamp: 1,
        target: target,
        backend: runtime.backend
    )
    await emitOriginatedNetworkRequest(
        id: "candidate-a",
        loaderID: "shared-loader",
        originTargetID: "page-next-1",
        timestamp: 2,
        target: target,
        backend: runtime.backend
    )
    await emitOriginatedNetworkRequest(
        id: "candidate-b",
        loaderID: "shared-loader",
        originTargetID: "page-next-2",
        timestamp: 3,
        target: target,
        backend: runtime.backend
    )
    try await waitUntil { context.network.requests.count == 3 }
    let candidateAVisit = try #require(context.network.requests[1].navigationVisit)
    let candidateBVisit = try #require(context.network.requests[2].navigationVisit)

    try await emitTopLevelFrameCommit(
        target: target,
        context: context,
        backend: runtime.backend,
        documentID: "ambiguous-frame-root",
        loaderID: "shared-loader"
    )
    try await emitTopLevelTargetCommit(
        target: target,
        context: context,
        backend: runtime.backend,
        documentID: "exact-target-root",
        pageBindingID: "page-next-2"
    )
    await emitOriginatedNetworkRequest(
        id: "candidate-b-committed",
        loaderID: "shared-loader",
        originTargetID: "page-next-2",
        timestamp: 4,
        target: target,
        backend: runtime.backend
    )
    try await waitUntil { context.network.requests.count == 4 }

    let committedVisit = try #require(context.network.requests[3].navigationVisit)
    #expect(candidateAVisit != candidateBVisit)
    #expect(committedVisit == candidateBVisit)
}

@MainActor
@Test
func networkTargetCommitCommitsPendingNavigationVisit() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)

    await emitOriginatedNetworkRequest(
        id: "a-first",
        loaderID: "loader-a",
        originTargetID: "page-a",
        timestamp: 1,
        target: target,
        backend: runtime.backend
    )
    await emitOriginatedNetworkRequest(
        id: "b-provisional",
        loaderID: "loader-b",
        originTargetID: "page-b",
        timestamp: 2,
        target: target,
        backend: runtime.backend
    )
    await emitOriginatedNetworkRequest(
        id: "a-during-b-provisional",
        loaderID: "loader-a",
        originTargetID: "page-a",
        timestamp: 2.5,
        target: target,
        backend: runtime.backend
    )
    try await waitUntil { context.network.requests.count == 3 }

    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: DOM.Node.ID("page-b-root"), nodeType: 9, nodeName: "#document")
    )
    await runtime.backend.emit(
        .didCommitProvisionalTarget(WebInspectorTargetCommitLifecycle(
            oldTargetID: .currentPage,
            newTarget: WebInspectorLifecycleTarget(
                id: .currentPage,
                kind: .page,
                frameID: FrameID("main-frame"),
                isProvisional: false,
                pageBindingID: "page-b"
            )
        )),
        target: target
    )
    try await waitUntil(in: context) {
        context.rootNode?.id == DOMNode.ID(DOM.Node.ID("page-b-root"))
            && context.state == .attached
    }
    await emitOriginatedNetworkRequest(
        id: "b-committed",
        loaderID: "loader-b",
        originTargetID: "page-b",
        timestamp: 3,
        target: target,
        backend: runtime.backend
    )
    await emitOriginatedNetworkRequest(
        id: "a-return-provisional",
        loaderID: "loader-a",
        originTargetID: "page-a-return",
        timestamp: 4,
        target: target,
        backend: runtime.backend
    )
    try await waitUntil { context.network.requests.count == 5 }

    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: DOM.Node.ID("page-a-return-root"), nodeType: 9, nodeName: "#document")
    )
    await runtime.backend.emit(
        .didCommitProvisionalTarget(WebInspectorTargetCommitLifecycle(
            oldTargetID: .currentPage,
            newTarget: WebInspectorLifecycleTarget(
                id: .currentPage,
                kind: .page,
                frameID: FrameID("main-frame"),
                isProvisional: false,
                pageBindingID: "page-a-return"
            )
        )),
        target: target
    )
    try await waitUntil(in: context) {
        context.rootNode?.id == DOMNode.ID(DOM.Node.ID("page-a-return-root"))
            && context.state == .attached
    }
    await emitOriginatedNetworkRequest(
        id: "a-return-committed",
        loaderID: "loader-a",
        originTargetID: "page-a-return",
        timestamp: 5,
        target: target,
        backend: runtime.backend
    )
    try await waitUntil { context.network.requests.count == 6 }

    let visits = try context.network.requests.map { try #require($0.navigationVisit) }
    #expect(visits[0] == visits[2])
    #expect(visits[1] == visits[3])
    #expect(visits[4] == visits[5])
    #expect(visits[0] != visits[4])
}

@MainActor
@Test
func clearNetworkRequestsPublishesResetAndIgnoresClearedEvents() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let recorder = CollectionChangeRecorder(stream: context.network.requestChanges)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()

    let firstRequestID = Network.Request.ID("clear-first-request")
    let firstModelID = NetworkRequest.ID(firstRequestID)
    await runtime.backend.emit(
        .requestWillBeSent(
            id: firstRequestID,
            request: Network.Request(id: firstRequestID, url: "https://example.com/first", method: "GET"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    try await recorder.waitForChangeCount(1)

    let secondRequestID = Network.Request.ID("clear-second-request")
    let secondModelID = NetworkRequest.ID(secondRequestID)
    await runtime.backend.emit(
        .requestWillBeSent(
            id: secondRequestID,
            request: Network.Request(id: secondRequestID, url: "https://example.com/second", method: "GET"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 2
        ),
        target: target
    )
    try await recorder.waitForChangeCount(2)
    #expect(context.network.requests.map(\.id) == [firstModelID, secondModelID])

    context.network.clearRequests()

    try await recorder.waitForChangeCount(3)
    #expect(recorder.changes.last == .removedAll)
    #expect(context.network.requests.isEmpty)
    #expect(context.network.request(for: firstModelID) == nil)
    #expect(context.network.request(for: secondModelID) == nil)

    let clearedEventBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(
        .responseReceived(
            id: firstRequestID,
            response: Network.Response(status: 200),
            resourceType: .fetch,
            timestamp: 3
        ),
        target: target
    )
    await runtime.backend.emit(
        .dataReceived(id: firstRequestID, dataLength: 7, encodedDataLength: 4, timestamp: 4),
        target: target
    )
    await runtime.backend.emit(
        .loadingFinished(id: secondRequestID, timestamp: 5, sourceMapURL: nil, metrics: nil),
        target: target
    )
    await runtime.backend.emit(
        .webSocket(.closed(id: secondRequestID, timestamp: 6)),
        target: target
    )
    let didProcessClearedEvents = await context.waitForEventPumpAppliedSequenceForTesting(
        after: clearedEventBaseline,
        count: 4
    )
    #expect(didProcessClearedEvents)
    #expect(context.state == .attached)
    #expect(context.network.requests.isEmpty)
    #expect(recorder.changes.count == 3)

    let redirectedEventBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(
        .requestWillBeSent(
            id: firstRequestID,
            request: Network.Request(
                id: firstRequestID,
                url: "https://example.com/redirected",
                method: "GET"
            ),
            resourceType: .fetch,
            redirectResponse: Network.Response(url: "https://example.com/first", status: 302),
            timestamp: 7
        ),
        target: target
    )
    let didProcessRedirectedEvent = await context.waitForEventPumpAppliedSequenceForTesting(
        after: redirectedEventBaseline
    )
    #expect(didProcessRedirectedEvent)
    #expect(context.network.requests.isEmpty)
    #expect(recorder.changes.count == 3)
    #expect(context.network.request(for: firstModelID) == nil)

    await runtime.backend.emit(
        .requestWillBeSent(
            id: firstRequestID,
            request: Network.Request(
                id: firstRequestID,
                url: "https://example.com/reused",
                method: "GET"
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 8
        ),
        target: target
    )

    try await recorder.waitForChangeCount(4)
    let reusedRequest = try #require(context.network.requests.first)
    #expect(reusedRequest.id == firstModelID)
    #expect(reusedRequest.url == "https://example.com/reused")
    #expect(context.network.request(for: firstModelID) === reusedRequest)
}

@MainActor
@Test
func clearNetworkRequestsPreservesRetainedSecurityWithoutLeakingIntoReusedID() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("clear-security-request")
    let initialSecurity = Network.Security(
        connection: Network.Security.Connection(tlsProtocol: "TLS 1.2")
    )

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "https://example.com/before-clear",
                method: "GET"
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    await runtime.backend.emit(
        .responseReceived(
            id: requestID,
            response: Network.Response(status: 200).reporting(security: initialSecurity),
            resourceType: .fetch,
            timestamp: 2
        ),
        target: target
    )
    try await waitUntil { context.network.requests.first?.security == initialSecurity }
    let retainedRequest = try #require(context.network.requests.first)

    context.network.clearRequests()
    #expect(context.network.requests.isEmpty)
    #expect(retainedRequest.security == initialSecurity)

    let lateEventBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(
        .loadingFinished(
            id: requestID,
            timestamp: 3,
            sourceMapURL: nil,
            metrics: Network.Metrics().reporting(
                securityConnection: Network.Security.Connection(tlsProtocol: "TLS 1.3")
            )
        ),
        target: target
    )
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: lateEventBaseline))
    #expect(context.network.requests.isEmpty)
    #expect(retainedRequest.security == initialSecurity)

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "https://example.com/after-clear",
                method: "GET"
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 4
        ),
        target: target
    )
    try await waitUntil { context.network.requests.count == 1 }
    let reusedRequest = try #require(context.network.requests.first)
    #expect(reusedRequest !== retainedRequest)
    #expect(reusedRequest.security == nil)
    #expect(retainedRequest.security == initialSecurity)
}

@MainActor
@Test
func networkEventsPopulateAllRequestsInOrder() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("request-1")
    let certificate = Network.Security.Certificate(
        subject: "example.com",
        validFrom: Date(timeIntervalSince1970: 1_700_000_000),
        validUntil: Date(timeIntervalSince1970: 1_800_000_000),
        dnsNames: ["example.com"],
        ipAddresses: []
    )

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "https://example.com/data.json",
                method: "GET",
                headers: ["Accept": "application/json"]
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    await runtime.backend.emit(
        .responseReceived(
            id: requestID,
            response: Network.Response(
                url: "https://cdn.example.com/data.json",
                status: 200,
                statusText: "OK",
                mimeType: "application/json",
                headers: ["Content-Type": "application/json"],
                source: Network.Source(rawValue: "network")
            ).reporting(
                security: Network.Security(
                    connection: Network.Security.Connection(
                        tlsProtocol: "TLS 1.2",
                        cipher: "AES_128_GCM_SHA256"
                    ),
                    certificate: certificate
                )
            ),
            resourceType: .fetch,
            timestamp: 2
        ),
        target: target
    )
    await runtime.backend.emit(
        .dataReceived(id: requestID, dataLength: 12, encodedDataLength: 5, timestamp: 3),
        target: target
    )
    await runtime.backend.emit(
        .loadingFinished(
            id: requestID,
            timestamp: 4,
            sourceMapURL: nil,
            metrics: Network.Metrics().reporting(
                securityConnection: Network.Security.Connection(tlsProtocol: "TLS 1.3")
            )
        ),
        target: target
    )

    try await waitUntil {
        context.network.requests.count == 1 && context.network.requests.first?.state == .finished
    }
    let request = try #require(context.network.requests.first)
    #expect(request.url == "https://example.com/data.json")
    #expect(request.method == "GET")
    #expect(request.resourceType == .fetch)
    #expect(request.status == 200)
    #expect(request.statusText == "OK")
    #expect(request.responseURL == "https://cdn.example.com/data.json")
    #expect(request.mimeType == "application/json")
    #expect(request.responseSource == "network")
    #expect(request.hasResponse)
    #expect(request.hasResponseBody)
    #expect(request.requestHeaders["Accept"] == "application/json")
    #expect(request.responseHeaders["Content-Type"] == "application/json")
    #expect(request.requestSentTimestamp == 1)
    #expect(request.responseReceivedTimestamp == 2)
    #expect(request.lastDataReceivedTimestamp == 3)
    #expect(request.finishedOrFailedTimestamp == 4)
    #expect(request.decodedDataLength == 12)
    #expect(request.encodedDataLength == 5)
    #expect(request.security?.connection?.tlsProtocol == "TLS 1.3")
    #expect(request.security?.connection?.cipher == "AES_128_GCM_SHA256")
    #expect(request.security?.certificate == certificate)
    #expect(context.network.request(for: request.id) === request)
}

@MainActor
@Test
func responseReceivedWithoutRequestWillBeSentCreatesRequest() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("response-first-request")
    let responseSecurity = Network.Security(
        connection: Network.Security.Connection(tlsProtocol: "TLS 1.3")
    )

    await runtime.backend.emit(
        .responseReceived(
            id: requestID,
            response: Network.Response(
                url: "https://example.com/late.css",
                status: 200,
                statusText: "OK",
                mimeType: "text/css",
                headers: ["Content-Type": "text/css"],
                source: Network.Source(rawValue: "network"),
                requestHeaders: ["Accept": "text/css"]
            ).reporting(security: responseSecurity),
            resourceType: .stylesheet,
            timestamp: 2
        ),
        target: target
    )
    await runtime.backend.emit(
        .dataReceived(id: requestID, dataLength: 9, encodedDataLength: 4, timestamp: 3),
        target: target
    )
    await runtime.backend.emit(
        .loadingFinished(id: requestID, timestamp: 4, sourceMapURL: nil, metrics: nil),
        target: target
    )

    try await waitUntil {
        context.network.requests.first?.state == .finished
    }
    let request = try #require(context.network.requests.first)
    #expect(request.id == NetworkRequest.ID(requestID))
    #expect(request.url == "https://example.com/late.css")
    #expect(request.method == "GET")
    #expect(request.resourceType == .stylesheet)
    #expect(request.status == 200)
    #expect(request.mimeType == "text/css")
    #expect(request.requestSentTimestamp == 2)
    #expect(request.responseReceivedTimestamp == 2)
    #expect(request.lastDataReceivedTimestamp == 3)
    #expect(request.finishedOrFailedTimestamp == 4)
    #expect(request.requestHeaders["Accept"] == "text/css")
    #expect(request.responseHeaders["Content-Type"] == "text/css")
    #expect(request.security == responseSecurity)
    #expect(request.decodedDataLength == 9)
    #expect(request.encodedDataLength == 4)
}

@MainActor
@Test
func responseReceivedWithoutResourceTypePreservesRequestResourceType() async throws {
    let context = WebInspectorContext.preview()
    let requestID = Network.Request.ID("response-type-preserved-request")
    let modelID = NetworkRequest.ID(requestID)

    await context.apply(.requestWillBeSent(
        id: requestID,
        request: Network.Request(id: requestID, url: "https://example.com/image.png", method: "GET"),
        resourceType: .image,
        redirectResponse: nil,
        timestamp: 1
    ))
    await context.apply(.responseReceived(
        id: requestID,
        response: Network.Response(
            url: "https://example.com/image.png",
            status: 200,
            statusText: "OK",
            mimeType: "image/png"
        ),
        resourceType: nil,
        timestamp: 2
    ))

    let request = try #require(context.network.request(for: modelID))
    #expect(request.resourceType == .image)
    #expect(request.responseReceivedTimestamp == 2)
}

@MainActor
@Test
func loadingFinishedStoresTerminalMetadataAndOverridesDataTotals() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("request-with-terminal-metadata")

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(id: requestID, url: "https://example.com/app.js", method: "GET"),
            resourceType: .script,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    await runtime.backend.emit(
        .dataReceived(id: requestID, dataLength: 5, encodedDataLength: 2, timestamp: 2),
        target: target
    )
    await runtime.backend.emit(
        .loadingFinished(
            id: requestID,
            timestamp: 3,
            sourceMapURL: "app.js.map",
            metrics: Network.Metrics(
                networkProtocol: "h3",
                remoteAddress: "203.0.113.20:443",
                encodedDataLength: 9,
                decodedBodyLength: 12
            )
        ),
        target: target
    )

    try await waitUntil {
        context.network.requests.first?.state == .finished
    }
    let request = try #require(context.network.requests.first)
    #expect(request.sourceMapURL == "app.js.map")
    #expect(request.metrics?.networkProtocol == "h3")
    #expect(request.metrics?.remoteAddress == "203.0.113.20:443")
    #expect(request.metrics?.encodedDataLength == 9)
    #expect(request.metrics?.decodedBodyLength == 12)
    #expect(request.lastDataReceivedTimestamp == 2)
    #expect(request.finishedOrFailedTimestamp == 3)
    #expect(request.decodedDataLength == 12)
    #expect(request.encodedDataLength == 9)
}

@MainActor
@Test
func loadingFinishedClampsNegativeMetricTotals() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("request-with-negative-terminal-metrics")

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(id: requestID, url: "https://example.com/negative", method: "GET"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    await runtime.backend.emit(
        .dataReceived(id: requestID, dataLength: 5, encodedDataLength: 4, timestamp: 2),
        target: target
    )
    await runtime.backend.emit(
        .loadingFinished(
            id: requestID,
            timestamp: 3,
            sourceMapURL: nil,
            metrics: Network.Metrics(encodedDataLength: -8, decodedBodyLength: -13)
        ),
        target: target
    )

    try await waitUntil {
        context.network.requests.first?.state == .finished
    }
    let request = try #require(context.network.requests.first)
    #expect(request.metrics?.encodedDataLength == -8)
    #expect(request.metrics?.decodedBodyLength == -13)
    #expect(request.decodedDataLength == 0)
    #expect(request.encodedDataLength == 0)
}

@MainActor
@Test
func loadingFinishedWithoutSecurityConnectionPreservesResponseSecurity() throws {
    let context = WebInspectorContext.preview()
    let requestID = Network.Request.ID("security-without-completion-connection")
    let security = Network.Security(
        connection: Network.Security.Connection(
            tlsProtocol: "TLS 1.3",
            cipher: "AES_128_GCM_SHA256"
        ),
        certificate: Network.Security.Certificate(subject: "example.com")
    )
    let request = NetworkRequest(
        request: Network.Request(
            id: requestID,
            url: "https://example.com/security",
            method: "GET"
        ),
        initiator: nil,
        resourceType: .fetch,
        timestamp: 1
    )

    request.applyResponse(
        Network.Response(status: 200).reporting(security: security),
        resourceType: .fetch,
        timestamp: 2
    )
    request.finish(timestamp: 3, sourceMapURL: nil, metrics: Network.Metrics())

    #expect(request.security == security)

    let emptyCompletionRequestID = Network.Request.ID("empty-completion-security-connection")
    let emptyCompletionRequest = NetworkRequest(
        request: Network.Request(
            id: emptyCompletionRequestID,
            url: "https://example.com/empty-completion-security",
            method: "GET"
        ),
        initiator: nil,
        resourceType: .fetch,
        timestamp: 4
    )
    emptyCompletionRequest.finish(
        timestamp: 5,
        sourceMapURL: nil,
        metrics: Network.Metrics().reporting(
            securityConnection: Network.Security.Connection()
        )
    )
    let emptyCompletionSecurity = try #require(emptyCompletionRequest.security)
    let emptyConnection = try #require(emptyCompletionSecurity.connection)
    #expect(emptyConnection.tlsProtocol == nil)
    #expect(emptyConnection.cipher == nil)
    #expect(emptyCompletionSecurity.certificate == nil)
}

@MainActor
@Test(arguments: [
    "https://example.com/security-not-reported",
    "http://example.com/security-not-reported",
])
func networkSecurityDoesNotInferTransportStateFromURLScheme(_ url: String) throws {
    let context = WebInspectorContext.preview()
    let requestID = Network.Request.ID(url)
    let request = NetworkRequest(
        request: Network.Request(id: requestID, url: url, method: "GET"),
        initiator: nil,
        resourceType: .fetch,
        timestamp: 1
    )

    #expect(request.security == nil)
    request.applyResponse(
        Network.Response(url: url, status: 200),
        resourceType: .fetch,
        timestamp: 2
    )
    request.finish(timestamp: 3, sourceMapURL: nil, metrics: Network.Metrics())
    #expect(request.security == nil)
}

@MainActor
@Test
func multipartContinuationPreservesFinishedLifecycleAcrossLaterParts() throws {
    let context = WebInspectorContext.preview()
    let requestID = Network.Request.ID("multipart-continuation")
    let request = NetworkRequest(
        request: Network.Request(
            id: requestID,
            url: "https://example.com/camera",
            method: "GET"
        ),
        initiator: nil,
        resourceType: .image,
        timestamp: 1
    )
    let responseBody = request.responseBody
    let firstSecurity = Network.Security(
        connection: Network.Security.Connection(tlsProtocol: "TLS 1.3")
    )

    request.applyResponse(
        Network.Response(
            url: "https://example.com/camera",
            status: 200,
            mimeType: "MULTIPART/X-MIXED-REPLACE"
        ).reporting(security: firstSecurity),
        resourceType: .image,
        timestamp: 2
    )
    request.finish(timestamp: 3, sourceMapURL: nil, metrics: nil)
    responseBody.load(Network.Body(data: "first part", base64Encoded: false))
    #expect(request.security == firstSecurity)

    request.applyResponse(
        Network.Response(
            url: "https://example.com/camera",
            status: 200,
            mimeType: "image/jpeg",
            headers: ["X-Part": "2"]
        ),
        resourceType: .image,
        timestamp: 4
    )

    #expect(request.responseBody === responseBody)
    #expect(request.state == .finished)
    #expect(request.finishedOrFailedTimestamp == 3)
    #expect(request.responseReceivedTimestamp == 4)
    #expect(request.mimeType == "image/jpeg")
    #expect(request.responseHeaders["X-Part"] == "2")
    #expect(request.security == nil)
    #expect(responseBody.phase == .available)
    #expect(responseBody.full == nil)
    #expect(request.canFetchResponseBody)

    request.applyDataReceived(dataLength: 12, encodedDataLength: 10, timestamp: 5)

    #expect(request.state == .finished)
    #expect(request.finishedOrFailedTimestamp == 3)
    #expect(request.lastDataReceivedTimestamp == 5)
    #expect(request.decodedDataLength == 12)
    #expect(request.encodedDataLength == 10)
}

@MainActor
@Test
func repeatedRequestWillBeSentClearsStaleResponseFields() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("redirected-request")
    let redirectSecurity = Network.Security(
        connection: Network.Security.Connection(tlsProtocol: "TLS 1.3"),
        certificate: Network.Security.Certificate(subject: "redirect.example.com")
    )

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(id: requestID, url: "https://example.com/redirect", method: "GET"),
            resourceType: .document,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    await runtime.backend.emit(
        .responseReceived(
            id: requestID,
            response: Network.Response(
                url: "https://example.com/redirect",
                status: 302,
                statusText: "Found",
                mimeType: "text/html",
                headers: ["Location": "https://example.com/final"],
                source: Network.Source(rawValue: "network")
            ).reporting(security: redirectSecurity),
            resourceType: .document,
            timestamp: 2
        ),
        target: target
    )

    try await waitUntil {
        context.network.requests.first?.status == 302
    }

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(id: requestID, url: "https://example.com/final", method: "GET"),
            resourceType: .document,
            redirectResponse: Network.Response(status: 302).reporting(security: redirectSecurity),
            timestamp: 3
        ),
        target: target
    )

    let request = try #require(context.network.requests.first)
    try await waitUntil {
        request.url == "https://example.com/final" && request.state == .pending
    }
    #expect(request.status == nil)
    #expect(request.statusText == nil)
    #expect(request.responseURL == nil)
    #expect(request.mimeType == nil)
    #expect(request.responseSource == nil)
    #expect(request.responseHeaders.isEmpty)
    #expect(request.security == nil)
    #expect(request.requestSentTimestamp == 3)
    #expect(request.responseReceivedTimestamp == nil)
    #expect(request.lastDataReceivedTimestamp == nil)
    #expect(request.finishedOrFailedTimestamp == nil)
    #expect(request.decodedDataLength == 0)
    #expect(request.encodedDataLength == 0)
    #expect(request.responseBody.phase == .available)
    #expect(request.responseBody.text == nil)
    #expect(request.redirects.count == 1)
    #expect(request.redirects.first?.request.url == "https://example.com/redirect")
    #expect(request.redirects.first?.response.status == 302)
    #expect(request.redirects.first?.response.security == redirectSecurity)
    #expect(request.redirects.first?.timestamp == 3)
}

@MainActor
@Test
func networkRequestPreservesInitialInitiatorAcrossRedirects() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("initiator-redirect")
    let initialNodeID = DOM.Node.ID("17")

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "https://example.com/start",
                method: "GET",
                origin: Network.Request.Origin(
                    frameID: FrameID("main-frame"),
                    loaderID: "initial-loader",
                    targetID: "page-initial"
                )
            ),
            initiator: Network.Initiator(kind: "other", nodeID: initialNodeID),
            resourceType: .document,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    try await waitUntil { context.network.requests.count == 1 }
    let initialVisit = try #require(context.network.requests.first?.navigationVisit)
    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "https://example.com/final",
                method: "GET",
                origin: Network.Request.Origin(
                    frameID: FrameID("main-frame"),
                    loaderID: "redirect-loader",
                    targetID: "page-redirect"
                )
            ),
            initiator: Network.Initiator(kind: "other", nodeID: DOM.Node.ID("99")),
            resourceType: .document,
            redirectResponse: Network.Response(
                url: "https://example.com/start",
                status: 302,
                statusText: "Found"
            ),
            timestamp: 2
        ),
        target: target
    )

    try await waitUntil { context.network.requests.first?.redirects.count == 1 }
    let request = try #require(context.network.requests.first)
    #expect(request.initiator?.nodeID == initialNodeID)
    #expect(request.navigationVisit == initialVisit)
}

@MainActor
@Test
func completedRequestDoesNotTreatLaterRequestWillBeSentAsRedirect() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("reused-request")

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(id: requestID, url: "https://example.com/first", method: "GET"),
            initiator: Network.Initiator(kind: "other", nodeID: DOM.Node.ID("41")),
            resourceType: .document,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    await runtime.backend.emit(
        .loadingFinished(
            id: requestID,
            timestamp: 2,
            sourceMapURL: "first.map",
            metrics: Network.Metrics(
                encodedDataLength: 20,
                decodedBodyLength: 40
            ).reporting(
                securityConnection: Network.Security.Connection(tlsProtocol: "TLS 1.3")
            )
        ),
        target: target
    )

    try await waitUntil { context.network.requests.first?.state == .finished }
    let request = try #require(context.network.requests.first)
    #expect(request.lifecycleRevision == 0)
    #expect(request.security?.connection?.tlsProtocol == "TLS 1.3")

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(id: requestID, url: "https://example.com/second", method: "GET"),
            initiator: Network.Initiator(kind: "other", nodeID: DOM.Node.ID("42")),
            resourceType: .document,
            redirectResponse: Network.Response(status: 302),
            timestamp: 3
        ),
        target: target
    )

    try await waitUntil {
        request.url == "https://example.com/second" && request.state == .pending
    }
    #expect(context.network.requests.first === request)
    #expect(request.redirects.isEmpty)
    #expect(request.requestSentTimestamp == 3)
    #expect(request.finishedOrFailedTimestamp == nil)
    #expect(request.sourceMapURL == nil)
    #expect(request.metrics == nil)
    #expect(request.security == nil)
    #expect(request.initiator?.nodeID == DOM.Node.ID("42"))
    #expect(request.lifecycleRevision == 1)
}

@MainActor
@Test
func loadingFailedStoresFailureTimestampAndClampsDataLength() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("failed-request")

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(id: requestID, url: "https://example.com/fail", method: "GET"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    await runtime.backend.emit(
        .dataReceived(id: requestID, dataLength: -10, encodedDataLength: -20, timestamp: 2),
        target: target
    )
    await runtime.backend.emit(
        .loadingFailed(id: requestID, errorText: "cancelled", canceled: true, timestamp: 3),
        target: target
    )

    try await waitUntil { context.network.requests.first?.state == .failed(errorText: "cancelled", canceled: true) }
    let request = try #require(context.network.requests.first)
    #expect(request.requestSentTimestamp == 1)
    #expect(request.lastDataReceivedTimestamp == 2)
    #expect(request.finishedOrFailedTimestamp == 3)
    #expect(request.decodedDataLength == 0)
    #expect(request.encodedDataLength == 0)
}

@MainActor
@Test
func memoryCacheEventCreatesFinishedCachedRequestFromResponse() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("cached-request")
    let security = Network.Security(
        connection: Network.Security.Connection(tlsProtocol: "TLS 1.3"),
        certificate: Network.Security.Certificate(subject: "example.com")
    )

    await runtime.backend.emit(
        .requestServedFromMemoryCache(
            id: requestID,
            response: Network.Response(
                url: "https://example.com/cached.css",
                status: 200,
                statusText: "OK",
                mimeType: "text/css",
                headers: ["Content-Type": "text/css"],
                source: Network.Source(rawValue: "network"),
                requestHeaders: ["Accept": "text/css"],
                bodySize: 2048
            ).reporting(security: security),
            initiator: Network.Initiator(kind: "other", nodeID: DOM.Node.ID("23")),
            resourceType: .stylesheet,
            timestamp: 5
        ),
        target: target
    )

    try await waitUntil {
        context.network.requests.count == 1 && context.network.requests.first?.state == .finished
    }
    let request = try #require(context.network.requests.first)
    #expect(request.url == "https://example.com/cached.css")
    #expect(request.method == "GET")
    #expect(request.resourceType == .stylesheet)
    #expect(request.status == 200)
    #expect(request.statusText == "OK")
    #expect(request.responseURL == "https://example.com/cached.css")
    #expect(request.mimeType == "text/css")
    #expect(request.responseSource == "memory-cache")
    #expect(request.requestHeaders["Accept"] == "text/css")
    #expect(request.responseHeaders["Content-Type"] == "text/css")
    #expect(request.requestSentTimestamp == 5)
    #expect(request.responseReceivedTimestamp == 5)
    #expect(request.lastDataReceivedTimestamp == nil)
    #expect(request.finishedOrFailedTimestamp == 5)
    #expect(request.decodedDataLength == 2048)
    #expect(request.encodedDataLength == 2048)
    #expect(request.security == security)
    #expect(request.responseBody.phase == .available)
    #expect(request.initiator?.nodeID == DOM.Node.ID("23"))
    #expect(context.network.request(for: request.id) === request)
}

@MainActor
@Test
func memoryCacheSecurityReplacesExistingResponseSummary() throws {
    let context = WebInspectorContext.preview()
    let requestID = Network.Request.ID("memory-cache-security-replacement")
    let request = NetworkRequest(
        request: Network.Request(
            id: requestID,
            url: "https://example.com/cached.css",
            method: "GET"
        ),
        initiator: nil,
        resourceType: .stylesheet,
        timestamp: 1
    )
    request.applyResponse(
        Network.Response(
            status: 200
        ).reporting(
            security: Network.Security(
                connection: Network.Security.Connection(tlsProtocol: "TLS 1.2")
            )
        ),
        resourceType: .stylesheet,
        timestamp: 2
    )
    let cachedSecurity = Network.Security(
        certificate: Network.Security.Certificate(subject: "cached.example.com")
    )

    request.applyMemoryCache(
        response: Network.Response(
            url: "https://example.com/cached.css",
            status: 200
        ).reporting(security: cachedSecurity),
        initiator: Network.Initiator(kind: "other"),
        resourceType: .stylesheet,
        timestamp: 3
    )
    #expect(request.security == cachedSecurity)

    request.applyMemoryCache(
        response: Network.Response(
            url: "https://example.com/cached.css",
            status: 200
        ),
        initiator: Network.Initiator(kind: "other"),
        resourceType: .stylesheet,
        timestamp: 4
    )
    #expect(request.security == nil)
}

@MainActor
@Test
func memoryCacheEventWithoutURLForNewRequestIsSkipped() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)

    await runtime.backend.emit(
        .requestServedFromMemoryCache(
            id: Network.Request.ID("cached-request-without-url"),
            response: Network.Response(status: 200),
            resourceType: nil,
            timestamp: 5
        ),
        target: target
    )
    await runtime.backend.emit(
        .requestServedFromMemoryCache(
            id: Network.Request.ID("cached-request-with-url"),
            response: Network.Response(url: "https://example.com/cached.css", status: 200),
            resourceType: nil,
            timestamp: 6
        ),
        target: target
    )

    try await waitUntil { context.network.requests.count == 1 }
    #expect(context.network.requests.first?.url == "https://example.com/cached.css")
    #expect(context.state == .attached)
}

@MainActor
@Test
func requestPostDataCreatesNetworkBodyWithFormRepresentation() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("form-request")

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "https://example.com/form",
                method: "POST",
                headers: ["Content-Type": " application/x-www-form-urlencoded; charset=utf-8"],
                postData: "name=Jane+Doe&city=Tokyo%20East"
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )

    try await waitUntil { context.network.requests.count == 1 }
    let request = try #require(context.network.requests.first)
    let body = try #require(request.requestBody)
    #expect(body.role == .request)
    #expect(body.kind == .form)
    #expect(body.phase == .loaded)
    #expect(body.full == "name=Jane+Doe&city=Tokyo%20East")
    #expect(body.text == "name=Jane+Doe&city=Tokyo%20East")
    #expect(body.size == "name=Jane+Doe&city=Tokyo%20East".utf8.count)
    #expect(body.isBase64Encoded == false)
    #expect(body.isTruncated == false)
    #expect(body.sourceSyntaxKind == .plainText)
    #expect(body.textRepresentation == "name=Jane Doe\ncity=Tokyo East")
    #expect(body.textRepresentationSyntaxKind == .plainText)
    #expect(request.canFetchResponseBody == false)
}

@MainActor
@Test
func responseRequestHeadersRefreshRequestBodyHints() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("form-request-hints")

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "https://example.com/form",
                method: "POST",
                postData: "name=Jane+Doe&city=Tokyo%20East"
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )

    try await waitUntil { context.network.requests.count == 1 }
    let request = try #require(context.network.requests.first)
    let body = try #require(request.requestBody)
    #expect(body.kind == .text)
    #expect(body.textRepresentation == "name=Jane+Doe&city=Tokyo%20East")

    await runtime.backend.emit(
        .responseReceived(
            id: requestID,
            response: Network.Response(
                status: 200,
                headers: ["Content-Type": "text/plain"],
                requestHeaders: ["Content-Type": "application/x-www-form-urlencoded"]
            ),
            resourceType: .fetch,
            timestamp: 2
        ),
        target: target
    )

    try await waitUntil { body.kind == .form }
    #expect(request.requestBody === body)
    #expect(request.requestHeaders["Content-Type"] == "application/x-www-form-urlencoded")
    #expect(body.textRepresentation == "name=Jane Doe\ncity=Tokyo East")
    #expect(body.textRepresentationSyntaxKind == .plainText)
}

@MainActor
@Test
func responseMetadataAndRedirectPreserveResponseBodyIdentity() throws {
    let context = WebInspectorContext.preview()
    let requestID = Network.Request.ID("stable-response-body")
    let request = NetworkRequest(
        request: Network.Request(
            id: requestID,
            url: "https://example.com/start.txt",
            method: "GET"
        ),
        initiator: nil,
        resourceType: .fetch,
        timestamp: 1
    )
    let body = request.responseBody

    request.applyResponse(
        Network.Response(
            url: "https://example.com/start.txt",
            status: 200,
            mimeType: "text/plain"
        ),
        resourceType: .fetch,
        timestamp: 2
    )
    body.load(Network.Body(data: "first payload", base64Encoded: false))

    request.applyResponse(
        Network.Response(
            url: "https://example.com/video.mp4",
            status: 206,
            mimeType: "video/mp4"
        ),
        resourceType: .media,
        timestamp: 3
    )

    #expect(request.responseBody === body)
    #expect(body.phase == .available)
    #expect(body.full == nil)
    #expect(body.size == nil)
    #expect(body.kind == .binary)

    body.load(Network.Body(data: "second payload", base64Encoded: false))
    request.applyRedirect(
        to: Network.Request(
            id: requestID,
            url: "https://example.com/final.json",
            method: "GET"
        ),
        redirectResponse: Network.Response(
            url: "https://example.com/video.mp4",
            status: 302,
            mimeType: "video/mp4"
        ),
        timestamp: 4,
        resourceType: .fetch
    )

    #expect(request.responseBody === body)
    #expect(body.phase == .available)
    #expect(body.full == nil)
    #expect(body.size == nil)
    #expect(body.kind == .text)
    #expect(body.sourceSyntaxKind == .json)
}

enum StaleResponseBodyFetchCompletion: Sendable {
    case success
    case failure
}

@MainActor
@Test(arguments: [
    StaleResponseBodyFetchCompletion.success,
    StaleResponseBodyFetchCompletion.failure,
])
func staleResponseBodyFetchCompletionCannotMutateNewerRevision(
    completion: StaleResponseBodyFetchCompletion
) async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("stale-body-\(completion)")
    let gate = WebInspectorTestGate()

    await emitFinishedRequest(id: requestID, target: target, backend: runtime.backend)
    try await waitUntil(in: context) {
        context.network.request(for: NetworkRequest.ID(requestID))?.state == .finished
    }
    let request = try #require(context.network.request(for: NetworkRequest.ID(requestID)))
    let body = request.responseBody
    await runtime.backend.hold(domain: "Network", method: "getResponseBody", gate: gate)

    let fetchTask = Task {
        await context.network.fetchResponseBody(for: request)
    }
    _ = try await runtime.backend.waitForRecordedCommandsForTesting(domain: "Network", method: "getResponseBody", count: 1)

    await runtime.backend.emit(
        .responseReceived(
            id: requestID,
            response: Network.Response(
                url: "https://example.com/replacement.mp4",
                status: 206,
                mimeType: "video/mp4"
            ),
            resourceType: .media,
            timestamp: 4
        ),
        target: target
    )
    try await waitUntil {
        request.responseBody.phase == .available && request.responseBody.kind == .binary
    }

    switch completion {
    case .success:
        await runtime.backend.enqueue(
            Network.Body(data: "obsolete", base64Encoded: false),
            for: "Network",
            method: "getResponseBody"
        )
    case .failure:
        await runtime.backend.enqueueFailure(
            WebInspectorProxyError.commandFailed(
                domain: "Network",
                method: "getResponseBody",
                message: "obsolete failure"
            ),
            for: "Network",
            method: "getResponseBody"
        )
    }
    await gate.open()
    await fetchTask.value

    #expect(request.responseBody === body)
    #expect(body.phase == .available)
    #expect(body.full == nil)
    #expect(body.size == nil)
    #expect(body.kind == .binary)
}

@MainActor
@Test
func responseBodyPublishesHintsAndFetchLifecycle() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("json-response-body")

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "https://example.com/api/data.json",
                method: "GET"
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    await runtime.backend.emit(
        .responseReceived(
            id: requestID,
            response: Network.Response(status: 200),
            resourceType: .fetch,
            timestamp: 2
        ),
        target: target
    )

    try await waitUntil { context.network.requests.first?.state == .responded }
    let request = try #require(context.network.requests.first)
    let body = request.responseBody
    #expect(body.role == .response)
    #expect(body.kind == .text)
    #expect(body.phase == .available)
    #expect(body.full == nil)
    #expect(body.sourceSyntaxKind == .json)
    #expect(body.textRepresentation == nil)
    #expect(body.textRepresentationSyntaxKind == .json)
    #expect(request.canFetchResponseBody == false)

    await runtime.backend.emit(
        .loadingFinished(id: requestID, timestamp: 3, sourceMapURL: nil, metrics: nil),
        target: target
    )
    try await waitUntil { request.canFetchResponseBody }

    await runtime.backend.enqueue(
        Network.Body(data: #"{"ok":true}"#, base64Encoded: false),
        for: "Network",
        method: "getResponseBody"
    )

    await context.network.fetchResponseBody(for: request)
    #expect(body.phase == .loaded)
    #expect(body.full == #"{"ok":true}"#)
    #expect(body.text == #"{"ok":true}"#)
    #expect(body.size == #"{"ok":true}"#.utf8.count)
    #expect(body.isBase64Encoded == false)
    #expect(body.isTruncated == false)
    #expect(body.textRepresentation == #"{"ok":true}"#)
    #expect(body.textRepresentationSyntaxKind == .json)
    #expect(request.canFetchResponseBody == false)

    let commandsBeforeSecondFetch = await runtime.backend.recordedCommands()
    await context.network.fetchResponseBody(for: request)
    let commandsAfterSecondFetch = await runtime.backend.recordedCommands()
    #expect(commandsAfterSecondFetch == commandsBeforeSecondFetch)
}

@MainActor
@Test
func fetchResponseBodyStoresLoadedAndFailedPhases() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let loadedID = Network.Request.ID("loaded-request")
    let failedID = Network.Request.ID("failed-request")

    await emitFinishedRequest(id: loadedID, target: target, backend: runtime.backend)
    await emitFinishedRequest(id: failedID, target: target, backend: runtime.backend)

    try await waitUntil {
        context.network.requests.count == 2 && context.network.requests.allSatisfy { $0.state == .finished }
    }
    let loadedRequest = try #require(context.network.requests.first { $0.id == NetworkRequest.ID(loadedID) })
    let failedRequest = try #require(context.network.requests.first { $0.id == NetworkRequest.ID(failedID) })

    await runtime.backend.enqueue(
        Network.Body(data: "hello", base64Encoded: false),
        for: "Network",
        method: "getResponseBody"
    )

    await context.network.fetchResponseBody(for: loadedRequest)
    #expect(loadedRequest.responseBody.phase == .loaded)
    #expect(loadedRequest.responseBody.text == "hello")
    #expect(loadedRequest.responseBody.isBase64Encoded == false)

    await context.network.fetchResponseBody(for: failedRequest)
    guard case let .failed(error) = failedRequest.responseBody.phase else {
        Issue.record("Expected failed response body phase.")
        return
    }
    guard case .commandFailed(domain: "Network", method: "getResponseBody", message: _) = error else {
        Issue.record("Expected Network.getResponseBody command failure.")
        return
    }

    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "Network", method: "getResponseBody")))
}

@MainActor
@Test
func concurrentResponseBodyCallersShareCompletionAcrossCallerCancellation() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("coalesced-body-request")
    let gate = WebInspectorTestGate()

    await emitFinishedRequest(id: requestID, target: target, backend: runtime.backend)
    try await waitUntil(in: context) {
        context.network.request(for: NetworkRequest.ID(requestID))?.state == .finished
    }
    let request = try #require(context.network.request(for: NetworkRequest.ID(requestID)))
    let body = request.responseBody
    await runtime.backend.hold(domain: "Network", method: "getResponseBody", gate: gate)
    await runtime.backend.enqueue(
        Network.Body(data: "shared", base64Encoded: false),
        for: "Network",
        method: "getResponseBody"
    )

    let first = Task { @MainActor in
        await context.network.fetchResponseBody(for: request)
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "Network",
        method: "getResponseBody",
        count: 1
    )
    let second = Task { @MainActor in
        await context.network.fetchResponseBody(for: request)
    }
    try await waitForResponseBodyWaiters(in: body, count: 2)

    first.cancel()
    await first.value
    try #require(body.responseFetchWaiterCountForTesting == 1)
    #expect(body.phase == .fetching)
    #expect(await runtime.backend.recordedCommands().filter {
        $0 == RecordedCommand(domain: "Network", method: "getResponseBody")
    }.count == 1)

    await gate.open()
    await second.value

    #expect(body.phase == .loaded)
    #expect(body.text == "shared")
    #expect(request.responseBody === body)
    #expect(body.responseFetchWaiterCountForTesting == 0)
}

@MainActor
@Test
func responseReplacementResolvesEveryJoinedResponseBodyWaiter() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("replaced-coalesced-body")
    let gate = WebInspectorTestGate()

    await emitFinishedRequest(id: requestID, target: target, backend: runtime.backend)
    try await waitUntil(in: context) {
        context.network.request(for: NetworkRequest.ID(requestID))?.state == .finished
    }
    let request = try #require(context.network.request(for: NetworkRequest.ID(requestID)))
    let body = request.responseBody
    await runtime.backend.hold(domain: "Network", method: "getResponseBody", gate: gate)
    await runtime.backend.enqueue(
        Network.Body(data: "obsolete", base64Encoded: false),
        for: "Network",
        method: "getResponseBody"
    )
    let firstProbe = ResponseBodyFetchCompletionProbe()
    let secondProbe = ResponseBodyFetchCompletionProbe()
    let first = Task { @MainActor in
        await context.network.fetchResponseBody(for: request)
        firstProbe.finish()
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "Network",
        method: "getResponseBody",
        count: 1
    )
    let second = Task { @MainActor in
        await context.network.fetchResponseBody(for: request)
        secondProbe.finish()
    }
    try await waitForResponseBodyWaiters(in: body, count: 2)

    await runtime.backend.emit(
        .responseReceived(
            id: requestID,
            response: Network.Response(
                url: "https://example.com/replaced-body",
                status: 200,
                mimeType: "multipart/x-mixed-replace"
            ),
            resourceType: .fetch,
            timestamp: 4
        ),
        target: target
    )
    try await waitUntil {
        body.phase == .available
    }

    do {
        try await waitUntil {
            firstProbe.isFinished && secondProbe.isFinished
        }
    } catch {
        await gate.open()
        await first.value
        await second.value
        throw error
    }

    #expect(request.responseBody === body)
    #expect(body.phase == .available)
    #expect(body.full == nil)
    #expect(body.responseFetchWaiterCountForTesting == 0)
    await gate.open()
    await first.value
    await second.value
}

@MainActor
@Test
func clearingNetworkResolvesEveryJoinedResponseBodyWaiter() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("cleared-coalesced-body")
    let gate = WebInspectorTestGate()

    await emitFinishedRequest(id: requestID, target: target, backend: runtime.backend)
    try await waitUntil(in: context) {
        context.network.request(for: NetworkRequest.ID(requestID))?.state == .finished
    }
    let request = try #require(context.network.request(for: NetworkRequest.ID(requestID)))
    let body = request.responseBody
    await runtime.backend.hold(domain: "Network", method: "getResponseBody", gate: gate)
    await runtime.backend.enqueue(
        Network.Body(data: "obsolete", base64Encoded: false),
        for: "Network",
        method: "getResponseBody"
    )
    let firstProbe = ResponseBodyFetchCompletionProbe()
    let secondProbe = ResponseBodyFetchCompletionProbe()
    let first = Task { @MainActor in
        await context.network.fetchResponseBody(for: request)
        firstProbe.finish()
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "Network",
        method: "getResponseBody",
        count: 1
    )
    let second = Task { @MainActor in
        await context.network.fetchResponseBody(for: request)
        secondProbe.finish()
    }
    try await waitForResponseBodyWaiters(in: body, count: 2)

    context.network.clearRequests()
    #expect(context.network.request(for: NetworkRequest.ID(requestID)) == nil)

    do {
        try await waitUntil {
            firstProbe.isFinished && secondProbe.isFinished
        }
    } catch {
        await gate.open()
        await first.value
        await second.value
        throw error
    }

    #expect(
        body.phase
            == NetworkBody.Phase.failed(NetworkBody.invalidatedResponseFetchError)
    )
    #expect(body.text == nil)
    #expect(request.responseBody === body)
    #expect(body.responseFetchWaiterCountForTesting == 0)
    await gate.open()
    await first.value
    await second.value
}

@MainActor
@Test
func fetchResponseBodyRejectsLateCompletionAfterNetworkClear() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("cleared-body-request")
    let gate = WebInspectorTestGate()

    await emitFinishedRequest(id: requestID, target: target, backend: runtime.backend)
    try await waitUntil(in: context) {
        context.network.request(for: NetworkRequest.ID(requestID))?.state == .finished
    }
    let request = try #require(context.network.request(for: NetworkRequest.ID(requestID)))
    let body = request.responseBody
    await runtime.backend.hold(domain: "Network", method: "getResponseBody", gate: gate)

    let fetchTask = Task {
        await context.network.fetchResponseBody(for: request)
    }
    _ = try await runtime.backend.waitForRecordedCommandsForTesting(domain: "Network", method: "getResponseBody", count: 1)

    context.network.clearRequests()
    #expect(context.network.request(for: NetworkRequest.ID(requestID)) == nil)
    await runtime.backend.enqueue(
        Network.Body(data: "stale-body", base64Encoded: false),
        for: "Network",
        method: "getResponseBody"
    )
    await gate.open()
    await fetchTask.value

    #expect(
        body.phase
            == NetworkBody.Phase.failed(NetworkBody.invalidatedResponseFetchError)
    )
    #expect(body.text == nil)
    #expect(request.responseBody === body)
}

@MainActor
@Test
func networkRequestHeadersUseWholeSnapshotPrecedence() async throws {
    let context = WebInspectorContext.preview()
    let requestID = Network.Request.ID("cookie-header-precedence")

    await context.apply(.requestWillBeSent(
        id: requestID,
        request: Network.Request(
            id: requestID,
            url: "https://example.test/cookies",
            method: "POST",
            headers: [
                "Cookie": "request=1",
                "Content-Type": "text/plain",
            ],
            postData: "body"
        ),
        resourceType: .fetch,
        redirectResponse: nil,
        timestamp: 1
    ))
    let request = try #require(context.registeredRequest(forProxyID: requestID))
    #expect(request.requestHeaderSource == .requestWillBeSent)
    #expect(request.requestHeaders["Cookie"] == "request=1")

    await context.apply(.responseReceived(
        id: requestID,
        response: Network.Response(
            status: 200,
            requestHeaders: [:]
        ),
        resourceType: .fetch,
        timestamp: 2
    ))
    #expect(request.requestHeaderSource == .response)
    #expect(request.requestHeaders == [:])
    #expect(request.cookieSections.request == .empty)

    await context.apply(.responseReceived(
        id: requestID,
        response: Network.Response(
            status: 200,
            requestHeaders: [
                "Cookie": "response=2",
                "Content-Type": "application/json",
            ]
        ),
        resourceType: .fetch,
        timestamp: 3
    ))
    #expect(request.requestHeaders["Cookie"] == "response=2")
    #expect(request.requestBody?.sourceSyntaxKind == .json)

    await context.apply(.loadingFinished(
        id: requestID,
        timestamp: 4,
        sourceMapURL: nil,
        metrics: Network.Metrics()
    ))
    #expect(request.requestHeaderSource == .response)
    #expect(request.requestHeaders["Cookie"] == "response=2")

    await context.apply(.loadingFinished(
        id: requestID,
        timestamp: 5,
        sourceMapURL: nil,
        metrics: Network.Metrics()
            .reporting(
                securityConnection: Network.Security.Connection(tlsProtocol: "TLS 1.3")
            )
            .reporting(requestHeaders: [:])
    ))
    #expect(request.requestHeaderSource == .metrics)
    #expect(request.requestHeaders == [:])
    #expect(request.security?.connection?.tlsProtocol == "TLS 1.3")

    await context.apply(.responseReceived(
        id: requestID,
        response: Network.Response(
            status: 200,
            requestHeaders: ["Cookie": "late-response=3"]
        ),
        resourceType: .fetch,
        timestamp: 6
    ))
    #expect(request.requestHeaderSource == .metrics)
    #expect(request.requestHeaders == [:])
}

@MainActor
@Test
func networkRequestHeaderSourceResetsForReusedAndRedirectedLifecycles() async throws {
    let context = WebInspectorContext.preview()
    let requestID = Network.Request.ID("cookie-header-reset")

    await context.apply(.requestWillBeSent(
        id: requestID,
        request: Network.Request(
            id: requestID,
            url: "https://example.test/first",
            method: "GET",
            headers: ["Cookie": "first=1"]
        ),
        resourceType: .document,
        redirectResponse: nil,
        timestamp: 1
    ))
    await context.apply(.loadingFinished(
        id: requestID,
        timestamp: 2,
        sourceMapURL: nil,
        metrics: Network.Metrics().reporting(requestHeaders: ["Cookie": "final=2"])
    ))
    let request = try #require(context.registeredRequest(forProxyID: requestID))
    #expect(request.requestHeaderSource == .metrics)

    await context.apply(.requestWillBeSent(
        id: requestID,
        request: Network.Request(
            id: requestID,
            url: "https://example.test/reused",
            method: "GET",
            headers: ["Cookie": "reused=3"]
        ),
        resourceType: .document,
        redirectResponse: Network.Response(status: 302),
        timestamp: 3
    ))
    #expect(request.requestHeaderSource == .requestWillBeSent)
    #expect(request.requestHeaders["Cookie"] == "reused=3")
    #expect(request.redirects.isEmpty)

    await context.apply(.responseReceived(
        id: requestID,
        response: Network.Response(
            status: 302,
            requestHeaders: ["Cookie": "refined=4"]
        ),
        resourceType: .document,
        timestamp: 4
    ))
    await context.apply(.requestWillBeSent(
        id: requestID,
        request: Network.Request(
            id: requestID,
            url: "https://example.test/redirected",
            method: "GET",
            headers: ["Cookie": "redirected=5"]
        ),
        resourceType: .document,
        redirectResponse: Network.Response(status: 302),
        timestamp: 5
    ))
    #expect(request.requestHeaderSource == .requestWillBeSent)
    #expect(request.requestHeaders["Cookie"] == "redirected=5")
    #expect(request.redirects.count == 1)
}

@MainActor
@Test
func networkCookieRequestAvailabilityFollowsCaptureBoundary() async throws {
    let context = WebInspectorContext.preview()

    let responseFirstID = Network.Request.ID("cookie-response-first")
    await context.apply(.responseReceived(
        id: responseFirstID,
        response: Network.Response(
            url: "https://example.test/response-first",
            status: 200
        ),
        resourceType: .fetch,
        timestamp: 1
    ))
    let responseFirst = try #require(context.registeredRequest(forProxyID: responseFirstID))
    #expect(responseFirst.requestHeaderSource == .unavailable)
    #expect(responseFirst.cookieSections.request == .unavailable(.notCaptured))

    let cachedID = Network.Request.ID("cookie-memory-cache")
    await context.apply(.requestServedFromMemoryCache(
        id: cachedID,
        response: Network.Response(
            url: "https://example.test/cached",
            status: 200,
            requestHeaders: ["Cookie": "cached=1"]
        ),
        resourceType: .fetch,
        timestamp: 2
    ))
    let cached = try #require(context.registeredRequest(forProxyID: cachedID))
    #expect(cached.responseSource == "memory-cache")
    #expect(cached.cookieSections.request == .unavailable(.servedFromMemoryCache))

    let webSocketID = Network.Request.ID("cookie-websocket")
    await context.apply(.webSocket(.created(
        id: webSocketID,
        url: "wss://example.test/socket"
    )))
    let webSocket = try #require(context.registeredRequest(forProxyID: webSocketID))
    #expect(webSocket.requestHeaderSource == .unavailable)
    #expect(webSocket.cookieSections.request == .unavailable(.notCaptured))

    await context.apply(.webSocket(.handshakeRequest(
        id: webSocketID,
        request: Network.Request(
            id: webSocketID,
            url: "wss://example.test/socket",
            method: "GET",
            headers: ["Cookie": "socket=2"]
        ),
        timestamp: 3
    )))
    #expect(webSocket.requestHeaderSource == .requestWillBeSent)
    guard case let .values(report) = webSocket.cookieSections.request else {
        Issue.record("Expected WebSocket handshake request cookies.")
        return
    }
    #expect(report.cookies.map(\.name) == ["socket"])
    #expect(report.cookies.map(\.value) == ["2"])
}

@MainActor
@Test
func networkResponseCookieSectionDistinguishesLoadingNoResponseEmptyAndValues() async throws {
    let context = WebInspectorContext.preview()
    let requestID = Network.Request.ID("cookie-response-states")

    await context.apply(.requestWillBeSent(
        id: requestID,
        request: Network.Request(
            id: requestID,
            url: "https://example.test/states",
            method: "GET"
        ),
        resourceType: .fetch,
        redirectResponse: nil,
        timestamp: 1
    ))
    let request = try #require(context.registeredRequest(forProxyID: requestID))
    #expect(request.cookieSections.response == .loading)

    await context.apply(.loadingFailed(
        id: requestID,
        errorText: "failed",
        canceled: false,
        timestamp: 2
    ))
    #expect(request.cookieSections.response == .noResponse)

    await context.apply(.requestWillBeSent(
        id: requestID,
        request: Network.Request(
            id: requestID,
            url: "https://example.test/empty",
            method: "GET"
        ),
        resourceType: .fetch,
        redirectResponse: nil,
        timestamp: 3
    ))
    await context.apply(.responseReceived(
        id: requestID,
        response: Network.Response(status: 200),
        resourceType: .fetch,
        timestamp: 4
    ))
    #expect(request.cookieSections.response == .empty)

    await context.apply(.responseReceived(
        id: requestID,
        response: Network.Response(
            status: 200,
            headers: ["Set-Cookie": "session=abc; HttpOnly"]
        ),
        resourceType: .fetch,
        timestamp: 5
    ))
    guard case let .values(report) = request.cookieSections.response else {
        Issue.record("Expected response cookies.")
        return
    }
    #expect(report.cookies.map(\.name) == ["session"])
    #expect(report.cookies.first?.isHTTPOnly == true)
}

@MainActor
@Test
func resourceTreeRestoresLoadedResourcesAndFetchesTheirContent() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    await runtime.backend.enqueue(try loadedResourceTree(), for: "Page", method: "getResourceTree")
    let (_, context) = try await startContext(runtime: runtime)
    let requests = context.network.requests
    #expect(context.network.resourceTreeError == nil)
    #expect(requests.map(\.url) == [
        "https://example.test/", "https://example.test/child", "https://example.test/child.js",
        "https://example.test/loaded.css", "https://example.test/broken.png"
    ])
    let stylesheet = try #require(requests.first { $0.resourceType == .stylesheet })
    #expect(stylesheet.state == .finished)
    #expect(stylesheet.status == nil)
    #expect(stylesheet.requestSentTimestamp == nil)
    #expect(stylesheet.finishedOrFailedTimestamp == nil)
    #expect(stylesheet.requestHeaderSource == .unavailable)
    #expect(stylesheet.sourceMapURL == "https://example.test/loaded.css.map")
    #expect(requests.last?.state == .failed(errorText: "", canceled: true))
    await runtime.backend.enqueue(Network.Body(data: "body { color: red; }", base64Encoded: false), for: "Page", method: "getResourceContent")
    await context.network.fetchResponseBody(for: stylesheet)
    #expect(stylesheet.responseBody.phase == .loaded)
    let command = try #require(await runtime.backend.recordedCommands().last)
    #expect(command.method == "getResourceContent")
    let payload = try #require(command.payload.cast(as: Page.ResourceContentPayload.self))
    #expect(payload.frameID == FrameID("main-frame"))
    #expect(payload.url == stylesheet.url)
}

@MainActor
@Test
func resourceTreeResponseKeepsIdentityAndDoesNotMergeLaterRequestsForSameURL() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    await runtime.backend.enqueue(try loadedResourceTree(), for: "Page", method: "getResourceTree")
    let (target, context) = try await startContext(runtime: runtime)
    let original = try #require(context.network.requests.first { $0.resourceType == .stylesheet })
    let id = Network.Request.ID("late-response")
    let response = Network.Response(url: original.url, status: 200, mimeType: "text/css", security: nil, origin: .init(
        frameID: FrameID("main-frame"), loaderID: "main-loader", targetID: nil
    ))
    await runtime.backend.emit(.responseReceived(id: id, response: response, resourceType: .stylesheet, timestamp: 2), target: target)
    await runtime.backend.emit(.loadingFinished(id: id, timestamp: 3, sourceMapURL: nil, metrics: nil), target: target)
    try await waitUntil { original.finishedOrFailedTimestamp == 3 }
    #expect(context.network.requests.count == 5)
    #expect(context.registeredRequest(forProxyID: id) === original)
    #expect(original.status == 200)
    #expect(original.resourceContentFrameID == nil)
    await runtime.backend.enqueue(Network.Body(data: "live", base64Encoded: false), for: "Network", method: "getResponseBody")
    await context.network.fetchResponseBody(for: original)
    let bodyCommand = try #require(await runtime.backend.recordedCommands().last)
    #expect(bodyCommand.payload.cast(as: Network.GetResponseBodyPayload.self)?.id == id)
    await runtime.backend.emit(.requestWillBeSent(
        id: Network.Request.ID("next-request"),
        request: Network.Request(id: Network.Request.ID("next-request"), url: original.url, method: "GET", origin: response.origin),
        initiator: .init(kind: "other"), resourceType: .stylesheet, redirectResponse: nil, timestamp: 4
    ), target: target)
    try await waitUntil { context.network.requests.count == 6 }
    #expect(context.network.requests.filter { $0.url == original.url }.count == 2)
    context.network.clearRequests()
    await context.apply(.responseReceived(id: id, response: response, resourceType: .stylesheet, timestamp: 5))
    #expect(context.network.requests.isEmpty)
}

@MainActor
@Test
func resourceTreeMergesEventsReceivedWhileSnapshotIsInFlight() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    await enqueueStartupReplies(on: runtime.backend)
    await runtime.backend.enqueue(try loadedResourceTree(), for: "Page", method: "getResourceTree")
    let gate = WebInspectorTestGate()
    await runtime.backend.hold(domain: "Page", method: "getResourceTree", gate: gate)
    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    _ = await runtime.backend.waitForRecordedCommands(domain: "Page", method: "getResourceTree", count: 1)
    let id = Network.Request.ID("during-bootstrap")
    await runtime.backend.emit(.requestWillBeSent(
        id: id,
        request: Network.Request(id: id, url: "https://example.test/loaded.css", method: "POST", origin: .init(
            frameID: FrameID("main-frame"), loaderID: "main-loader", targetID: nil
        )),
        initiator: .init(kind: "script"), resourceType: .stylesheet, redirectResponse: nil, timestamp: 1
    ), target: target)
    await gate.open()
    try await waitUntil(in: context) { context.state == .attached }
    let requests = context.network.requests
    #expect(requests.count == 5)
    let live = try #require(context.registeredRequest(forProxyID: id))
    #expect(live.method == "POST")
    #expect(live.state == .pending)
    #expect(requests.filter { $0.url == live.url }.count == 1)
}

@MainActor
@Test
func resourceTreeDoesNotUndoUserClearWhileLookupIsInFlight() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    await enqueueStartupReplies(on: runtime.backend)
    await runtime.backend.enqueue(try loadedResourceTree(), for: "Page", method: "getResourceTree")
    let gate = WebInspectorTestGate()
    await runtime.backend.hold(domain: "Page", method: "getResourceTree", gate: gate)
    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    _ = await runtime.backend.waitForRecordedCommands(domain: "Page", method: "getResourceTree", count: 1)
    context.network.clearRequests()
    await gate.open()
    try await waitUntil(in: context) { context.state == .attached }
    #expect(context.network.requests.isEmpty)
}

@MainActor
@Test
func resourceTreeFailurePreservesLiveNetworkCollectionAndReportsError() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let failure = WebInspectorProxyError.commandFailed(domain: "Page", method: "getResourceTree", message: "Unavailable")
    await runtime.backend.enqueueFailure(failure, for: "Page", method: "getResourceTree")
    let (_, context) = try await startContext(runtime: runtime)
    #expect(context.network.resourceTreeError == failure)
    #expect(context.state == .attached)
    let id = Network.Request.ID("after-tree-failure")
    await context.apply(.requestWillBeSent(id: id,
        request: Network.Request(id: id, url: "https://example.test/live", method: "GET"),
        initiator: .init(kind: "other"), resourceType: .fetch, redirectResponse: nil, timestamp: 1))
    #expect(context.network.requests.count == 1)
}

@MainActor
@Test
func resourceTreeRefetchesWhenChildFrameDetachesDuringLookup() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    await enqueueStartupReplies(on: runtime.backend)
    await runtime.backend.enqueue(try loadedResourceTree(), for: "Page", method: "getResourceTree")
    let replacement = try JSONDecoder().decode(Page.ResourceTree.self, from: Data(#"{"frame":{"id":"main-frame","loaderId":"main-loader","url":"https://example.test/new","mimeType":"text/html"},"resources":[]}"#.utf8))
    await runtime.backend.enqueue(replacement, for: "Page", method: "getResourceTree")
    let gate = WebInspectorTestGate()
    await runtime.backend.hold(domain: "Page", method: "getResourceTree", gate: gate)
    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    _ = await runtime.backend.waitForRecordedCommands(domain: "Page", method: "getResourceTree", count: 1)
    await runtime.backend.emit(.frameDetached(frameID: FrameID("child-frame")), target: target)
    await gate.open()
    try await waitUntil(in: context) { context.state == .attached }
    #expect(context.network.requests.map(\.url) == ["https://example.test/new"])
    #expect(await runtime.backend.recordedCommands().filter { $0.method == "getResourceTree" }.count == 2)
}

@MainActor
@Test
func resourceTreeContentExpiresOnlyForDetachedFrameAndRetainsLoadedBodies() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    await runtime.backend.enqueue(try loadedResourceTree(), for: "Page", method: "getResourceTree")
    let (_, context) = try await startContext(runtime: runtime)
    let requests = context.network.requests
    let childScript = try #require(requests.first { $0.url.hasSuffix("child.js") })
    let childDocument = try #require(requests.first { $0.url.hasSuffix("/child") })
    let stylesheet = try #require(requests.first { $0.resourceType == .stylesheet })
    await runtime.backend.enqueue(Network.Body(data: "loaded child", base64Encoded: false), for: "Page", method: "getResourceContent")
    await context.network.fetchResponseBody(for: childDocument)
    context.apply(.frameDetached(frameID: FrameID("child-frame")))
    let commandCount = await runtime.backend.recordedCommands().count
    await context.network.fetchResponseBody(for: childScript)
    #expect(await runtime.backend.recordedCommands().count == commandCount)
    #expect(childScript.canFetchResponseBody == false)
    #expect(childDocument.responseBody.phase == .loaded)
    #expect(stylesheet.canFetchResponseBody)
}

@MainActor
@Test
func clearingResourceTreeDoesNotResurrectUnknownResponseButAllowsNewRequests() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    await runtime.backend.enqueue(try loadedResourceTree(), for: "Page", method: "getResourceTree")
    let (_, context) = try await startContext(runtime: runtime)
    context.network.clearRequests()
    let response = Network.Response(url: "https://example.test/loaded.css", status: 200, security: nil,
        origin: .init(frameID: FrameID("main-frame"), loaderID: "main-loader", targetID: nil))
    await context.apply(.responseReceived(id: Network.Request.ID("old"), response: response, resourceType: .stylesheet, timestamp: 1))
    #expect(context.network.requests.isEmpty)
    let newID = Network.Request.ID("new")
    await context.apply(.requestWillBeSent(id: newID,
        request: Network.Request(id: newID, url: "https://example.test/loaded.css", method: "GET", origin: response.origin),
        initiator: .init(kind: "other"), resourceType: .stylesheet, redirectResponse: nil, timestamp: 2))
    await context.apply(.responseReceived(id: newID, response: response, resourceType: .stylesheet, timestamp: 3))
    #expect(context.network.requests.count == 1)
    #expect(context.registeredRequest(forProxyID: newID)?.status == 200)
}

@MainActor
@Test
func resourceTreeBackForwardVisitDoesNotDeduplicateAgainstHistoricalRequests() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    await runtime.backend.enqueue(try loadedResourceTree(), for: "Page", method: "getResourceTree")
    let (_, context) = try await startContext(runtime: runtime)
    let original = try #require(context.network.requests.first { $0.resourceType == .stylesheet })
    let originalID = Network.Request.ID("first-visit")
    await context.apply(.responseReceived(id: originalID,
        response: Network.Response(url: original.url, status: 200, security: nil,
            origin: .init(frameID: FrameID("main-frame"), loaderID: "main-loader", targetID: nil)),
        resourceType: .stylesheet, timestamp: 1))
    await context.apply(.loadingFinished(id: originalID, timestamp: 2, sourceMapURL: nil, metrics: nil))

    func navigate(tree: Page.ResourceTree, rootID: String) async throws {
        await enqueueStartupReplies(on: runtime.backend, document: DOM.Node(id: DOM.Node.ID(rootID), nodeType: 9, nodeName: "#document"))
        await runtime.backend.enqueue(tree, for: "Page", method: "getResourceTree")
        context.apply(.didCommitProvisionalTarget(.init(oldTargetID: .currentPage,
            newTarget: .init(id: .currentPage, kind: .page, frameID: FrameID("main-frame"), isProvisional: false, pageBindingID: rootID))))
        context.apply(.frameNavigated(.init(id: FrameID("main-frame"), parentID: nil, pageBindingID: rootID,
            loaderID: tree.frame.loaderId, name: nil, url: tree.frame.url, securityOrigin: nil, mimeType: "text/html")))
        try await waitUntil(in: context) { context.rootNode?.id == DOMNode.ID(DOM.Node.ID(rootID)) }
        #expect(context.network.resourceTreeError == nil)
    }
    let otherPage = try JSONDecoder().decode(Page.ResourceTree.self, from: Data(#"{"frame":{"id":"main-frame","loaderId":"other-loader","url":"https://example.test/other","mimeType":"text/html"},"resources":[]}"#.utf8))
    try await navigate(tree: otherPage, rootID: "other-root")
    try await navigate(tree: loadedResourceTree(), rootID: "returned-root")
    let stylesheets = context.network.requests.filter { $0.url == original.url }
    #expect(stylesheets.count == 2)
    let restored = try #require(stylesheets.last)
    #expect(restored !== original)
    #expect(restored.navigationVisit != original.navigationVisit)
    #expect(restored.canFetchResponseBody)
    await runtime.backend.enqueue(Network.Body(data: "returned body", base64Encoded: false), for: "Page", method: "getResourceContent")
    await context.network.fetchResponseBody(for: restored)
    #expect(restored.responseBody.phase == .loaded)
}

@MainActor
@Test
func laterRequestCannotReplaceUnfetchedResourceTreeContent() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    await runtime.backend.enqueue(try loadedResourceTree(), for: "Page", method: "getResourceTree")
    let (_, context) = try await startContext(runtime: runtime)
    let original = try #require(context.network.requests.first { $0.resourceType == .stylesheet })
    let id = Network.Request.ID("replacement")
    await context.apply(.requestWillBeSent(id: id,
        request: Network.Request(id: id, url: original.url, method: "GET", origin: original.origin),
        initiator: .init(kind: "other"), resourceType: .stylesheet, redirectResponse: nil, timestamp: 1))
    let commandCount = await runtime.backend.recordedCommands().count
    await context.network.fetchResponseBody(for: original)
    #expect(await runtime.backend.recordedCommands().count == commandCount)
    #expect(!original.canFetchResponseBody)
    #expect(context.registeredRequest(forProxyID: id) !== original)
    // The original load may still receive its own response after the replacement starts.
    let originalID = Network.Request.ID("original-response")
    await context.apply(.responseReceived(id: originalID,
        response: Network.Response(url: original.url, status: 200, security: nil, origin: original.origin),
        resourceType: .stylesheet, timestamp: 2))
    #expect(context.registeredRequest(forProxyID: originalID) === original)
    #expect(original.resourceContentLocation == nil)
}

@MainActor
@Test
func resourceTreeContentReplyCannotOutliveFrameDetachment() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    await runtime.backend.enqueue(try loadedResourceTree(), for: "Page", method: "getResourceTree")
    let (target, context) = try await startContext(runtime: runtime)
    let request = try #require(context.network.requests.first { $0.url.hasSuffix("child.js") })
    let gate = WebInspectorTestGate()
    await runtime.backend.hold(domain: "Page", method: "getResourceContent", gate: gate)
    await runtime.backend.enqueue(Network.Body(data: "replacement document", base64Encoded: false), for: "Page", method: "getResourceContent")
    let task = Task { await context.network.fetchResponseBody(for: request) }
    _ = await runtime.backend.waitForRecordedCommands(domain: "Page", method: "getResourceContent", count: 1)
    await runtime.backend.emit(.frameDetached(frameID: FrameID("child-frame")), target: target)
    await gate.open()
    await task.value
    #expect(request.responseBody.phase == .failed(NetworkBody.invalidatedResponseFetchError))
}
