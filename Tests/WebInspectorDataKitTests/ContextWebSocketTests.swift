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
func webSocketCreatedCreatesRequestWithConnectingState() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("websocket-created")

    await runtime.backend.emit(
        .webSocket(.created(id: requestID, url: "wss://example.com/socket")),
        target: target
    )

    try await waitUntil { context.network.requests.count == 1 }
    let request = try #require(context.network.requests.first)
    #expect(request.url == "wss://example.com/socket")
    #expect(request.method == "GET")
    #expect(request.resourceType == .webSocket)
    #expect(request.state == .pending)
    #expect(request.requestSentTimestamp == nil)
    #expect(request.webSocket?.readyState == .connecting)
    #expect(request.hasResponse == false)
    #expect(request.hasResponseBody == false)
    #expect(context.registeredRequest(for: request.id) === request)
}

@MainActor
@Test
func webSocketCreatedPreservesExistingNetworkLifecycleMetadata() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("websocket-created-after-request")
    let responseSecurity = Network.Security(
        connection: Network.Security.Connection(tlsProtocol: "TLS 1.3")
    )

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "wss://example.com/socket",
                method: "GET",
                headers: ["Upgrade": "websocket"]
            ),
            resourceType: .webSocket,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    await runtime.backend.emit(
        .responseReceived(
            id: requestID,
            response: Network.Response(
                status: 101,
                statusText: "Switching Protocols",
                headers: ["Upgrade": "websocket"],
                requestHeaders: ["Upgrade": "websocket"]
            ).reporting(security: responseSecurity),
            resourceType: .webSocket,
            timestamp: 2
        ),
        target: target
    )
    await runtime.backend.emit(
        .dataReceived(id: requestID, dataLength: 7, encodedDataLength: 3, timestamp: 3),
        target: target
    )

    try await waitUntil { context.network.requests.first?.decodedDataLength == 7 }
    let request = try #require(context.network.requests.first)
    let webSocket = try #require(request.webSocket)

    await runtime.backend.emit(
        .webSocket(.created(id: requestID, url: "wss://example.com/socket?created")),
        target: target
    )
    try await waitUntil { request.url == "wss://example.com/socket?created" }
    #expect(request.security == responseSecurity)
    await runtime.backend.emit(
        .webSocket(.handshakeRequest(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "",
                method: "GET",
                headers: ["Upgrade": "websocket"]
            ),
            timestamp: nil
        )),
        target: target
    )
    try await waitUntil { request.state == .pending && request.security == nil }
    await runtime.backend.emit(
        .webSocket(.handshakeResponse(
            id: requestID,
            response: Network.Response(
                status: 101,
                statusText: "Switching Protocols",
                headers: ["Upgrade": "websocket"],
                requestHeaders: ["Upgrade": "websocket"]
            ),
            timestamp: nil
        )),
        target: target
    )
    try await waitUntil {
        request.webSocket?.handshakeResponse?.status == 101 && request.state == .responded
    }

    let currentWebSocket = try #require(request.webSocket)
    #expect(currentWebSocket === webSocket)
    #expect(currentWebSocket.readyState == .connecting)
    #expect(request.url == "wss://example.com/socket?created")
    #expect(request.method == "GET")
    #expect(request.requestHeaders["Upgrade"] == "websocket")
    #expect(currentWebSocket.handshakeRequest?.url == "wss://example.com/socket?created")
    #expect(request.status == 101)
    #expect(request.responseHeaders["Upgrade"] == "websocket")
    #expect(request.requestSentTimestamp == 1)
    #expect(request.responseReceivedTimestamp == 2)
    #expect(request.lastDataReceivedTimestamp == 3)
    #expect(request.finishedOrFailedTimestamp == nil)
    #expect(request.decodedDataLength == 7)
    #expect(request.encodedDataLength == 3)
    #expect(request.state == .responded)
}

@MainActor
@Test
func webSocketLifecycleStoresHandshakeFramesErrorAndClosedState() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("websocket-lifecycle")
    let handshakeSecurity = Network.Security(
        connection: Network.Security.Connection(tlsProtocol: "TLS 1.3"),
        certificate: Network.Security.Certificate(subject: "example.com")
    )

    await runtime.backend.emit(
        .webSocket(.created(id: requestID, url: "wss://example.com/socket")),
        target: target
    )
    try await waitUntil { context.network.requests.count == 1 }
    let request = try #require(context.network.requests.first)

    await runtime.backend.emit(
        .webSocket(.handshakeRequest(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "wss://example.com/socket",
                method: "GET",
                headers: ["Upgrade": "websocket"]
            ),
            timestamp: 1
        )),
        target: target
    )
    try await waitUntil {
        request.webSocket?.handshakeRequest?.headers["Upgrade"] == "websocket"
    }
    #expect(request.requestHeaders["Upgrade"] == "websocket")
    #expect(request.requestSentTimestamp == 1)
    #expect(request.webSocket?.readyState == .connecting)
    #expect(request.state == .pending)

    await runtime.backend.emit(
        .webSocket(.handshakeResponse(
            id: requestID,
            response: Network.Response(
                status: 101,
                statusText: "Switching Protocols",
                headers: ["Upgrade": "websocket"],
                requestHeaders: ["Upgrade": "websocket"]
            ).reporting(security: handshakeSecurity),
            timestamp: 2
        )),
        target: target
    )
    try await waitUntil {
        request.webSocket?.handshakeResponse?.status == 101 && request.state == .responded
    }
    #expect(request.webSocket?.handshakeResponse?.status == 101)
    #expect(request.webSocket?.handshakeResponse?.security == handshakeSecurity)
    #expect(request.security == handshakeSecurity)
    #expect(request.status == 101)
    #expect(request.responseHeaders["Upgrade"] == "websocket")
    #expect(request.requestHeaders["Upgrade"] == "websocket")
    #expect(request.responseReceivedTimestamp == 2)
    #expect(request.hasResponse)
    #expect(request.hasResponseBody == false)
    #expect(request.webSocket?.readyState == .connecting)

    await runtime.backend.emit(
        .webSocket(.frameSent(
            id: requestID,
            frame: Network.WebSocketFrame(opcode: 1, mask: true, payloadData: "hello", payloadLength: 5),
            timestamp: 3
        )),
        target: target
    )
    await runtime.backend.emit(
        .webSocket(.frameReceived(
            id: requestID,
            frame: Network.WebSocketFrame(opcode: 1, mask: false, payloadData: "world", payloadLength: 5),
            timestamp: 4
        )),
        target: target
    )
    await runtime.backend.emit(
        .webSocket(.error(id: requestID, message: "boom", timestamp: 5)),
        target: target
    )
    try await waitUntil { request.webSocket?.frames.count == 3 }
    let webSocket = try #require(request.webSocket)
    #expect(webSocket.frames.map(\.direction) == [.sent, .received, .error("boom")])
    #expect(webSocket.frames[0].opcode == 1)
    #expect(webSocket.frames[0].mask == true)
    #expect(webSocket.frames[0].payloadData == "hello")
    #expect(webSocket.frames[0].payloadLength == 5)
    #expect(webSocket.frames[1].payloadData == "world")
    #expect(webSocket.frames[2].errorMessage == "boom")
    #expect(webSocket.frames.map(\.timestamp) == [3, 4, 5])
    #expect(webSocket.timelineEntries.map(\.kind) == [
        .handshakeResponse(WebSocketTimelineHandshakeResponse(
            statusCode: 101,
            statusText: "Switching Protocols"
        )),
        .connectionEstablished,
        .frame(WebSocketTimelineFrame(
            direction: .sent,
            kind: .text,
            payload: .text("hello"),
            payloadLength: 5,
            isMasked: true
        )),
        .frame(WebSocketTimelineFrame(
            direction: .received,
            kind: .text,
            payload: .text("world"),
            payloadLength: 5,
            isMasked: false
        )),
        .error("boom"),
    ])
    #expect(webSocket.timelineEntries[1].timestamp == 2)
    #expect(webSocket.readyState == .closed)
    #expect(request.decodedDataLength == 10)
    #expect(request.lastDataReceivedTimestamp == 5)

    await runtime.backend.emit(
        .webSocket(.closed(id: requestID, timestamp: 6)),
        target: target
    )
    try await waitUntil {
        request.webSocket?.readyState == .closed && request.state == .finished
    }
    #expect(request.finishedOrFailedTimestamp == 6)
}

@MainActor
@Test
func webSocketTimelinePreservesArrivalOrderStableIDsAndExactFrameSemantics() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("websocket-timeline")

    await runtime.backend.emit(
        .webSocket(.created(id: requestID, url: "wss://example.com/timeline")),
        target: target
    )
    try await waitUntil { context.network.requests.count == 1 }
    let request = try #require(context.network.requests.first)

    await runtime.backend.emit(
        .webSocket(.handshakeRequest(
            id: requestID,
            request: Network.Request(id: requestID, url: "", method: "GET"),
            timestamp: nil
        )),
        target: target
    )
    await runtime.backend.emit(
        .webSocket(.handshakeResponse(
            id: requestID,
            response: Network.Response(status: 101),
            timestamp: nil
        )),
        target: target
    )
    await runtime.backend.emit(
        .webSocket(.frameSent(
            id: requestID,
            frame: Network.WebSocketFrame(
                opcode: 1,
                mask: false,
                payloadData: "hello",
                payloadLength: 5
            ),
            timestamp: 7
        )),
        target: target
    )
    await runtime.backend.emit(
        .webSocket(.frameReceived(
            id: requestID,
            frame: Network.WebSocketFrame(
                opcode: 2,
                mask: true,
                payloadData: "AQID",
                payloadLength: 3
            ),
            timestamp: 7
        )),
        target: target
    )
    await runtime.backend.emit(
        .webSocket(.error(id: requestID, message: "boom", timestamp: 2)),
        target: target
    )
    await runtime.backend.emit(
        .webSocket(.closed(id: requestID, timestamp: 1)),
        target: target
    )
    await runtime.backend.emit(
        .webSocket(.frameReceived(
            id: requestID,
            frame: Network.WebSocketFrame(
                opcode: 8,
                mask: false,
                payloadData: "A+g=",
                payloadLength: 2
            ),
            timestamp: 0.5
        )),
        target: target
    )
    await runtime.backend.emit(
        .webSocket(.frameSent(
            id: requestID,
            frame: Network.WebSocketFrame(
                opcode: 42,
                mask: true,
                payloadData: "CQ==",
                payloadLength: 1
            ),
            timestamp: 9
        )),
        target: target
    )

    try await waitUntil { request.webSocket?.timelineEntries.count == 8 }
    let webSocket = try #require(request.webSocket)
    let expected = [
        WebSocketTimelineEntry(
            id: .init(lifecycleRevision: 0, chronologySequence: 2),
            timestamp: nil,
            kind: .handshakeResponse(WebSocketTimelineHandshakeResponse(
                statusCode: 101,
                statusText: nil
            ))
        ),
        WebSocketTimelineEntry(
            id: .init(
                lifecycleRevision: 0,
                chronologySequence: 3,
                ordinalWithinEvent: 0
            ),
            timestamp: 7,
            kind: .connectionEstablished
        ),
        WebSocketTimelineEntry(
            id: .init(
                lifecycleRevision: 0,
                chronologySequence: 3,
                ordinalWithinEvent: 1
            ),
            timestamp: 7,
            kind: .frame(WebSocketTimelineFrame(
                direction: .sent,
                kind: .text,
                payload: .text("hello"),
                payloadLength: 5,
                isMasked: false
            ))
        ),
        WebSocketTimelineEntry(
            id: .init(
                lifecycleRevision: 0,
                chronologySequence: 4,
                ordinalWithinEvent: 1
            ),
            timestamp: 7,
            kind: .frame(WebSocketTimelineFrame(
                direction: .received,
                kind: .binary,
                payload: .base64Encoded("AQID"),
                payloadLength: 3,
                isMasked: true
            ))
        ),
        WebSocketTimelineEntry(
            id: .init(lifecycleRevision: 0, chronologySequence: 5),
            timestamp: 2,
            kind: .error("boom")
        ),
        WebSocketTimelineEntry(
            id: .init(lifecycleRevision: 0, chronologySequence: 6),
            timestamp: 1,
            kind: .connectionClosed
        ),
        WebSocketTimelineEntry(
            id: .init(
                lifecycleRevision: 0,
                chronologySequence: 7,
                ordinalWithinEvent: 1
            ),
            timestamp: 0.5,
            kind: .frame(WebSocketTimelineFrame(
                direction: .received,
                kind: .close,
                payload: .base64Encoded("A+g="),
                payloadLength: 2,
                isMasked: false
            ))
        ),
        WebSocketTimelineEntry(
            id: .init(
                lifecycleRevision: 0,
                chronologySequence: 8,
                ordinalWithinEvent: 1
            ),
            timestamp: 9,
            kind: .frame(WebSocketTimelineFrame(
                direction: .sent,
                kind: .unknown(42),
                payload: .base64Encoded("CQ=="),
                payloadLength: 1,
                isMasked: true
            ))
        ),
    ]
    #expect(webSocket.timelineEntries == expected)
    #expect(webSocket.timelineEntry(for: expected[0].id) == expected[0])
    #expect(webSocket.timelineEntry(for: expected[4].id) == expected[4])
    #expect(webSocket.timelineEntry(for: expected[7].id) == expected[7])
    #expect(webSocket.timelineEntry(for: .init(lifecycleRevision: 0, chronologySequence: 1)) == nil)
    #expect(webSocket.timelineEntry(for: .init(lifecycleRevision: 0, chronologySequence: 99)) == nil)
    #expect(webSocket.readyState == .closed)
    #expect(request.finishedOrFailedTimestamp == 1)
    #expect(webSocket.frames.map(\.opcode) == [1, 2, nil, 8, 42])
}

@MainActor
@Test
func webSocketFirstCloseAndHandshakeAreTerminalAndDuplicateEventsDoNotNotify() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("websocket-terminal")

    await runtime.backend.emit(
        .webSocket(.created(id: requestID, url: "wss://example.com/terminal")),
        target: target
    )
    try await waitUntil { context.network.requests.count == 1 }
    let request = try #require(context.network.requests.first)
    await runtime.backend.emit(
        .webSocket(.handshakeResponse(
            id: requestID,
            response: Network.Response(status: 101, statusText: "First"),
            timestamp: 2
        )),
        target: target
    )
    await runtime.backend.emit(
        .webSocket(.closed(id: requestID, timestamp: 3)),
        target: target
    )
    try await waitUntil { request.webSocket?.readyState == .closed }

    let changesAfterClose = context.network.requestChanges
    let eventSequence = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(
        .webSocket(.closed(id: requestID, timestamp: 99)),
        target: target
    )
    await runtime.backend.emit(
        .webSocket(.handshakeRequest(
            id: requestID,
            request: Network.Request(id: requestID, url: "", method: "POST"),
            timestamp: 100
        )),
        target: target
    )
    await runtime.backend.emit(
        .webSocket(.handshakeResponse(
            id: requestID,
            response: Network.Response(status: 299, statusText: "Late"),
            timestamp: 101
        )),
        target: target
    )
    let processed = await context.waitForEventPumpAppliedSequenceForTesting(
        after: eventSequence,
        count: 3
    )
    #expect(processed)

    let webSocket = try #require(request.webSocket)
    #expect(webSocket.readyState == .closed)
    #expect(webSocket.handshakeResponse?.status == 101)
    #expect(webSocket.handshakeResponse?.statusText == "First")
    #expect(webSocket.handshakeRequest == nil)
    #expect(webSocket.timelineEntries.count == 2)
    #expect(webSocket.timelineEntries.map(\.kind) == [
        .handshakeResponse(WebSocketTimelineHandshakeResponse(
            statusCode: 101,
            statusText: "First"
        )),
        .connectionClosed,
    ])
    guard case let .handshakeResponse(handshakeResponse) = webSocket.timelineEntries[0].kind else {
        Issue.record("Expected switching-protocols handshake response evidence.")
        return
    }
    #expect(handshakeResponse.disposition == .switchingProtocols(
        statusText: "First"
    ))
    #expect(request.finishedOrFailedTimestamp == 3)
    #expect(request.responseReceivedTimestamp == 2)
    #expect(await changesBeforeClearingRequests(in: context, changesAfterClose).isEmpty)
}

@MainActor
@Test
func webSocketRejectedHandshakePreservesResponseWithoutOpeningAndOrdersTerminalEvidence() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("websocket-rejected-handshake")

    await runtime.backend.emit(
        .webSocket(.created(id: requestID, url: "wss://example.com/rejected")),
        target: target
    )
    try await waitUntil { context.network.requests.count == 1 }
    let request = try #require(context.network.requests.first)
    await runtime.backend.emit(
        .webSocket(.handshakeResponse(
            id: requestID,
            response: Network.Response(
                url: "wss://example.com/rejected",
                status: 403,
                statusText: "Forbidden",
                headers: ["content-type": "text/plain"]
            ),
            timestamp: 2
        )),
        target: target
    )
    try await waitUntil { request.webSocket?.timelineEntries.count == 1 }

    let webSocket = try #require(request.webSocket)
    #expect(webSocket.readyState == .connecting)
    #expect(webSocket.handshakeResponse?.status == 403)
    #expect(webSocket.handshakeResponse?.statusText == "Forbidden")
    #expect(request.status == 403)
    #expect(request.statusText == "Forbidden")
    #expect(request.state == .responded)
    #expect(webSocket.timelineEntries.map(\.kind) == [
        .handshakeResponse(WebSocketTimelineHandshakeResponse(
            statusCode: 403,
            statusText: "Forbidden"
        ))
    ])
    guard case let .handshakeResponse(handshakeResponse) = webSocket.timelineEntries[0].kind else {
        Issue.record("Expected rejected handshake response evidence.")
        return
    }
    #expect(handshakeResponse.disposition == .rejected(
        statusCode: 403,
        statusText: "Forbidden"
    ))
    #expect(webSocket.frames.isEmpty)

    let changesAfterRejection = context.network.requestChanges
    let eventSequence = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(
        .webSocket(.handshakeResponse(
            id: requestID,
            response: Network.Response(status: 101, statusText: "Late Success"),
            timestamp: 2.5
        )),
        target: target
    )
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: eventSequence))
    #expect(webSocket.handshakeResponse?.status == 403)
    #expect(webSocket.timelineEntries.count == 1)

    await runtime.backend.emit(
        .webSocket(.error(id: requestID, message: "upgrade failed", timestamp: 3)),
        target: target
    )
    await runtime.backend.emit(
        .webSocket(.closed(id: requestID, timestamp: 4)),
        target: target
    )
    try await waitUntil { webSocket.timelineEntries.count == 3 }
    #expect(webSocket.timelineEntries.map(\.kind) == [
        .handshakeResponse(WebSocketTimelineHandshakeResponse(
            statusCode: 403,
            statusText: "Forbidden"
        )),
        .error("upgrade failed"),
        .connectionClosed,
    ])
    #expect(webSocket.readyState == .closed)
    #expect(request.finishedOrFailedTimestamp == 4)
    #expect(webSocket.frames.map(\.direction) == [.error("upgrade failed")])
    // The late handshake response published nothing; the error and the close each did.
    #expect(await changesBeforeClearingRequests(in: context, changesAfterRejection) == [
        .updated([request.id]),
        .updated([request.id]),
    ])
}

@MainActor
@Test
func webSocketHandshakeWithoutStatusIsUnreportedWithoutInventingMetadata() throws {
    let webSocket = WebSocketState()

    #expect(webSocket.applyHandshakeResponse(
        Network.Response(status: nil, statusText: nil),
        timestamp: nil,
        lifecycleRevision: 7,
        chronologySequence: 9
    ))
    #expect(webSocket.readyState == .connecting)
    #expect(webSocket.handshakeResponse?.status == nil)
    #expect(webSocket.handshakeResponse?.statusText == nil)
    #expect(webSocket.timelineEntries == [WebSocketTimelineEntry(
        id: .init(lifecycleRevision: 7, chronologySequence: 9),
        timestamp: nil,
        kind: .handshakeResponse(WebSocketTimelineHandshakeResponse(
            statusCode: nil,
            statusText: nil
        ))
    )])
    guard case let .handshakeResponse(handshakeResponse) = webSocket.timelineEntries[0].kind else {
        Issue.record("Expected unreported handshake response evidence.")
        return
    }
    #expect(handshakeResponse.disposition == .unreported(statusText: nil))
    #expect(webSocket.frames.isEmpty)
}

@MainActor
@Test
func webSocketSwitchingProtocolsResponseFollowedByErrorNeverClaimsEstablished() throws {
    let webSocket = WebSocketState()

    #expect(webSocket.applyHandshakeResponse(
        Network.Response(status: 101, statusText: "Switching Protocols"),
        timestamp: 1,
        lifecycleRevision: 2,
        chronologySequence: 5
    ))
    #expect(webSocket.readyState == .connecting)
    webSocket.appendError(
        "Invalid Sec-WebSocket-Accept",
        timestamp: 2,
        lifecycleRevision: 2,
        chronologySequence: 6
    )
    #expect(webSocket.readyState == .closed)
    #expect(webSocket.close(
        timestamp: 3,
        lifecycleRevision: 2,
        chronologySequence: 7
    ))
    #expect(webSocket.close(
        timestamp: 4,
        lifecycleRevision: 2,
        chronologySequence: 8
    ) == false)
    #expect(webSocket.timelineEntries.map(\.kind) == [
        .handshakeResponse(WebSocketTimelineHandshakeResponse(
            statusCode: 101,
            statusText: "Switching Protocols"
        )),
        .error("Invalid Sec-WebSocket-Accept"),
        .connectionClosed,
    ])
    guard case let .handshakeResponse(handshakeResponse) = webSocket.timelineEntries[0].kind else {
        Issue.record("Expected switching-protocols handshake response evidence.")
        return
    }
    #expect(handshakeResponse.disposition == .switchingProtocols(
        statusText: "Switching Protocols"
    ))
    #expect(webSocket.timelineEntries.contains { entry in
        if case .connectionEstablished = entry.kind {
            return true
        }
        return false
    } == false)
    #expect(webSocket.frames.map(\.direction) == [
        .error("Invalid Sec-WebSocket-Accept")
    ])
}

@MainActor
@Test
func activeDuplicateWebSocketCreatedPreservesStateIdentityAndTimeline() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("websocket-active-created")

    await runtime.backend.emit(
        .webSocket(.created(id: requestID, url: "wss://example.com/initial")),
        target: target
    )
    try await waitUntil { context.network.requests.count == 1 }
    let request = try #require(context.network.requests.first)
    await runtime.backend.emit(
        .webSocket(.handshakeResponse(
            id: requestID,
            response: Network.Response(status: 101),
            timestamp: 1
        )),
        target: target
    )
    await runtime.backend.emit(
        .webSocket(.frameReceived(
            id: requestID,
            frame: Network.WebSocketFrame(opcode: 9, mask: false, payloadData: "", payloadLength: 0),
            timestamp: 2
        )),
        target: target
    )
    try await waitUntil { request.webSocket?.timelineEntries.count == 3 }
    let originalState = try #require(request.webSocket)
    let originalTimeline = originalState.timelineEntries

    await runtime.backend.emit(
        .webSocket(.created(id: requestID, url: "wss://example.com/enriched")),
        target: target
    )
    try await waitUntil { request.url == "wss://example.com/enriched" }

    #expect(request.webSocket === originalState)
    #expect(request.webSocket?.readyState == .open)
    #expect(request.webSocket?.timelineEntries == originalTimeline)
    #expect(request.lifecycleRevision == 0)
    #expect(request.state == .responded)
}

@MainActor
@Test(arguments: [0, 1, 2, 8, 9, 10, 42])
func webSocketTimelineMapsEveryOpcodeWithoutTreatingNonTextAsText(opcode: Int) throws {
    let webSocket = WebSocketState()
    webSocket.appendFrame(
        Network.WebSocketFrame(
            opcode: opcode,
            mask: true,
            payloadData: opcode == 1 ? "text" : "AQID",
            payloadLength: 3
        ),
        direction: .sent,
        timestamp: 1,
        lifecycleRevision: 4,
        chronologySequence: 9
    )

    if opcode == 8 {
        #expect(webSocket.timelineEntries.count == 1)
        #expect(webSocket.readyState == .connecting)
    } else {
        #expect(webSocket.timelineEntries.count == 2)
        #expect(webSocket.timelineEntries[0].kind == .connectionEstablished)
        #expect(webSocket.timelineEntries[0].id.ordinalWithinEvent == 0)
        #expect(webSocket.readyState == .open)
    }
    let entry = try #require(webSocket.timelineEntries.last)
    #expect(entry.id.ordinalWithinEvent == 1)
    guard case let .frame(frame) = entry.kind else {
        Issue.record("Expected a WebSocket frame timeline entry.")
        return
    }
    let expectedKind: WebSocketTimelineFrame.Kind = switch opcode {
    case 0: .continuation
    case 1: .text
    case 2: .binary
    case 8: .close
    case 9: .ping
    case 10: .pong
    default: .unknown(opcode)
    }
    #expect(entry.id == .init(
        lifecycleRevision: 4,
        chronologySequence: 9,
        ordinalWithinEvent: 1
    ))
    #expect(frame.kind == expectedKind)
    #expect(frame.payload == (opcode == 1 ? .text("text") : .base64Encoded("AQID")))
    #expect(frame.payloadLength == 3)
    #expect(frame.isMasked)
}

@MainActor
@Test
func webSocketTimelineEntryLookupCoversLargeOrderedHistory() throws {
    let webSocket = WebSocketState()
    for index in 0..<4_096 {
        webSocket.appendFrame(
            Network.WebSocketFrame(
                opcode: 2,
                mask: false,
                payloadData: "AA==",
                payloadLength: 1
            ),
            direction: .received,
            timestamp: Double(index),
            lifecycleRevision: 12,
            chronologySequence: UInt64(index + 1)
        )
    }

    let entries = webSocket.timelineEntries
    #expect(entries.count == 4_097)
    for index in [0, entries.count / 2, entries.count - 1] {
        #expect(webSocket.timelineEntry(for: entries[index].id) == entries[index])
    }
    #expect(webSocket.timelineEntry(for: .init(
        lifecycleRevision: 12,
        chronologySequence: 2_048,
        ordinalWithinEvent: 0
    )) == nil)
    #expect(webSocket.timelineEntry(for: .init(
        lifecycleRevision: 12,
        chronologySequence: 5_000
    )) == nil)
    #expect(webSocket.timelineEntry(for: .init(
        lifecycleRevision: 13,
        chronologySequence: 1
    )) == nil)
}

@MainActor
@Test
func webSocketCloseFrameAloneDoesNotConfirmEstablishedConnection() throws {
    let webSocket = WebSocketState()
    #expect(webSocket.applyHandshakeResponse(
        Network.Response(status: 101, statusText: "Switching Protocols"),
        timestamp: 1,
        lifecycleRevision: 6,
        chronologySequence: 10
    ))

    webSocket.appendFrame(
        Network.WebSocketFrame(
            opcode: 8,
            mask: false,
            payloadData: "A+g=",
            payloadLength: 2
        ),
        direction: .received,
        timestamp: 2,
        lifecycleRevision: 6,
        chronologySequence: 11
    )

    #expect(webSocket.readyState == .connecting)
    #expect(webSocket.timelineEntries.map(\.kind) == [
        .handshakeResponse(WebSocketTimelineHandshakeResponse(
            statusCode: 101,
            statusText: "Switching Protocols"
        )),
        .frame(WebSocketTimelineFrame(
            direction: .received,
            kind: .close,
            payload: .base64Encoded("A+g="),
            payloadLength: 2,
            isMasked: false
        )),
    ])
    #expect(webSocket.timelineEntries[1].id == .init(
        lifecycleRevision: 6,
        chronologySequence: 11,
        ordinalWithinEvent: 1
    ))
    #expect(webSocket.timelineEntries.contains { entry in
        if case .connectionEstablished = entry.kind {
            return true
        }
        return false
    } == false)
    #expect(webSocket.frames.map(\.opcode) == [8])
}

@MainActor
@Test
func terminalWebSocketCreatedRestartsSameRequestThroughCommonLifecycleReset() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("websocket-restarted")

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "wss://example.com/start",
                method: "POST",
                headers: ["X-Initial": "1"],
                postData: "old body"
            ),
            resourceType: .webSocket,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    try await waitUntil { context.network.requests.count == 1 }
    let request = try #require(context.network.requests.first)
    let responseBody = request.responseBody
    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "wss://example.com/redirected",
                method: "POST",
                headers: ["X-Redirected": "1"],
                postData: "redirect body"
            ),
            resourceType: .webSocket,
            redirectResponse: Network.Response(status: 302),
            timestamp: 2
        ),
        target: target
    )
    await runtime.backend.emit(
        .webSocket(.handshakeRequest(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "",
                method: "GET",
                headers: ["Upgrade": "websocket"],
                postData: "handshake body"
            ),
            timestamp: 3
        )),
        target: target
    )
    await runtime.backend.emit(
        .webSocket(.handshakeResponse(
            id: requestID,
            response: Network.Response(
                status: 101,
                headers: ["Upgrade": "websocket"],
                requestHeaders: ["Upgrade": "websocket"]
            ),
            timestamp: 4
        )),
        target: target
    )
    await runtime.backend.emit(
        .webSocket(.frameSent(
            id: requestID,
            frame: Network.WebSocketFrame(opcode: 1, mask: true, payloadData: "old", payloadLength: 3),
            timestamp: 5
        )),
        target: target
    )
    await runtime.backend.emit(
        .loadingFinished(
            id: requestID,
            timestamp: 6,
            sourceMapURL: "old.map",
            metrics: Network.Metrics(encodedDataLength: 8, decodedBodyLength: 13)
                .reporting(requestHeaders: ["X-Metrics": "1"])
        ),
        target: target
    )
    await runtime.backend.emit(
        .webSocket(.closed(id: requestID, timestamp: 7)),
        target: target
    )
    try await waitUntil { request.webSocket?.readyState == .closed }
    let previousState = try #require(request.webSocket)
    #expect(request.redirects.count == 1)
    #expect(request.metrics != nil)
    #expect(request.requestBody != nil)

    await runtime.backend.emit(
        .webSocket(.created(id: requestID, url: "wss://example.com/restarted")),
        target: target
    )
    try await waitUntil {
        request.lifecycleRevision == 1 && request.webSocket?.readyState == .connecting
    }

    #expect(context.network.requests.first === request)
    #expect(request.webSocket !== previousState)
    #expect(request.webSocket?.timelineEntries.isEmpty == true)
    #expect(request.url == "wss://example.com/restarted")
    #expect(request.method == "GET")
    #expect(request.resourceType == .webSocket)
    #expect(request.state == .pending)
    #expect(request.logicalStartTimestamp == nil)
    #expect(request.chronologySequence == 7)
    #expect(request.requestSentTimestamp == nil)
    #expect(request.responseReceivedTimestamp == nil)
    #expect(request.lastDataReceivedTimestamp == nil)
    #expect(request.finishedOrFailedTimestamp == nil)
    #expect(request.status == nil)
    #expect(request.statusText == nil)
    #expect(request.responseURL == nil)
    #expect(request.mimeType == nil)
    #expect(request.responseSource == nil)
    #expect(request.sourceMapURL == nil)
    #expect(request.requestHeaders.isEmpty)
    #expect(request.requestHeaderSource == .unavailable)
    #expect(request.responseHeaders.isEmpty)
    #expect(request.requestBody == nil)
    #expect(request.responseBody === responseBody)
    #expect(request.responseBody.phase == .available)
    #expect(request.metrics == nil)
    #expect(request.redirects.isEmpty)
    #expect(request.decodedDataLength == 0)
    #expect(request.encodedDataLength == 0)
    #expect(request.hasResponse == false)
}

@MainActor
@Test(arguments: [false, true])
func webSocketCreatedRestartsLifecycleClosedByErrorWithoutClosedEvent(
    hasHandshakeResponse: Bool
) async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("websocket-error-restarted-\(hasHandshakeResponse)")

    await runtime.backend.emit(
        .webSocket(.created(id: requestID, url: "wss://example.com/first")),
        target: target
    )
    try await waitUntil { context.network.requests.count == 1 }
    let request = try #require(context.network.requests.first)
    if hasHandshakeResponse {
        await runtime.backend.emit(
            .webSocket(.handshakeResponse(
                id: requestID,
                response: Network.Response(status: 101, statusText: "Switching Protocols"),
                timestamp: 0.5
            )),
            target: target
        )
        try await waitUntil { request.state == .responded }
    }
    let stateBeforeError = request.state
    await runtime.backend.emit(
        .webSocket(.error(id: requestID, message: "upgrade failed", timestamp: 1)),
        target: target
    )
    try await waitUntil { request.webSocket?.readyState == .closed }
    let previousState = try #require(request.webSocket)
    #expect(stateBeforeError == (hasHandshakeResponse ? .responded : .pending))
    #expect(request.state == stateBeforeError)
    #expect(previousState.frames.map(\.direction) == [.error("upgrade failed")])

    await runtime.backend.emit(
        .webSocket(.created(id: requestID, url: "wss://example.com/restarted")),
        target: target
    )
    try await waitUntil {
        request.lifecycleRevision == 1 && request.webSocket?.readyState == .connecting
    }

    #expect(context.network.requests.first === request)
    #expect(request.webSocket !== previousState)
    #expect(request.webSocket?.timelineEntries.isEmpty == true)
    #expect(request.webSocket?.frames.isEmpty == true)
    #expect(request.url == "wss://example.com/restarted")
    #expect(request.state == .pending)

    await runtime.backend.emit(
        .webSocket(.handshakeRequest(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "wss://example.com/restarted",
                method: "GET",
                headers: ["Upgrade": "websocket"]
            ),
            timestamp: 2
        )),
        target: target
    )
    try await waitUntil {
        request.webSocket?.handshakeRequest?.headers["Upgrade"] == "websocket"
    }
}

@MainActor
@Test
func legacyWebSocketFramesProjectionPublishesTimelineChangesThroughObservation() async throws {
    let context = WebInspectorContext.preview()
    let requestID = Network.Request.ID("websocket-legacy-observation")
    let request = NetworkRequest(
        request: Network.Request(id: requestID, url: "wss://example.com/legacy", method: "GET"),
        initiator: nil,
        resourceType: .webSocket,
        timestamp: nil,
        modelContext: context
    )
    let webSocket = try #require(request.webSocket)
    let observation = SynchronousObservationProbe()
    withObservationTracking {
        _ = webSocket.frames
    } onChange: {
        observation.markChanged()
    }

    request.appendWebSocketFrame(
        Network.WebSocketFrame(opcode: 1, mask: true, payloadData: "legacy", payloadLength: 6),
        direction: .received,
        timestamp: 4,
        chronologySequence: 1
    )
    try #require(observation.hasChanged)

    #expect(webSocket.frames == [
        WebSocketState.Frame(
            direction: .received,
            opcode: 1,
            mask: true,
            payloadData: "legacy",
            payloadLength: 6,
            timestamp: 4
        )
    ])
}

@MainActor
@Test
func legacyWebSocketFramesProjectionObservesOnlyIncomingFrameAndErrorEntries() throws {
    let webSocket = WebSocketState()
    let firstFrame = WebSocketState.Frame(
        direction: .received,
        opcode: 1,
        mask: false,
        payloadData: "hello",
        payloadLength: 5,
        timestamp: 2
    )
    let error = WebSocketState.Frame(
        direction: .error("boom"),
        errorMessage: "boom",
        timestamp: 3
    )

    let firstFrameObservation = SynchronousObservationProbe()
    withObservationTracking {
        _ = webSocket.frames
    } onChange: {
        firstFrameObservation.markChanged()
    }
    #expect(webSocket.applyHandshakeResponse(
        Network.Response(status: 101, statusText: "Switching Protocols"),
        timestamp: 1,
        lifecycleRevision: 4,
        chronologySequence: 1
    ))
    #expect(firstFrameObservation.hasChanged == false)
    #expect(webSocket.frames.isEmpty)

    webSocket.appendFrame(
        Network.WebSocketFrame(
            opcode: 1,
            mask: false,
            payloadData: "hello",
            payloadLength: 5
        ),
        direction: .received,
        timestamp: 2,
        lifecycleRevision: 4,
        chronologySequence: 2
    )
    #expect(firstFrameObservation.hasChanged)
    #expect(webSocket.timelineEntries.map(\.kind) == [
        .handshakeResponse(WebSocketTimelineHandshakeResponse(
            statusCode: 101,
            statusText: "Switching Protocols"
        )),
        .connectionEstablished,
        .frame(WebSocketTimelineFrame(
            direction: .received,
            kind: .text,
            payload: .text("hello"),
            payloadLength: 5,
            isMasked: false
        )),
    ])
    #expect(webSocket.frames == [firstFrame])

    let errorObservation = SynchronousObservationProbe()
    withObservationTracking {
        _ = webSocket.frames
    } onChange: {
        errorObservation.markChanged()
    }
    webSocket.appendError(
        "boom",
        timestamp: 3,
        lifecycleRevision: 4,
        chronologySequence: 3
    )
    #expect(errorObservation.hasChanged)
    #expect(webSocket.frames == [firstFrame, error])

    let closeObservation = SynchronousObservationProbe()
    withObservationTracking {
        _ = webSocket.frames
    } onChange: {
        closeObservation.markChanged()
    }
    #expect(webSocket.close(
        timestamp: 4,
        lifecycleRevision: 4,
        chronologySequence: 4
    ))
    #expect(closeObservation.hasChanged == false)
    #expect(webSocket.frames == [firstFrame, error])
}

@MainActor
@Test
func closedWebSocketCannotFetchResponseBodyOrSendProtocolCommand() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("websocket-no-response-body")

    await runtime.backend.emit(
        .webSocket(.created(id: requestID, url: "wss://example.com/no-body")),
        target: target
    )
    try await waitUntil { context.network.requests.count == 1 }
    let request = try #require(context.network.requests.first)
    await runtime.backend.emit(
        .webSocket(.handshakeResponse(
            id: requestID,
            response: Network.Response(status: 101),
            timestamp: 1
        )),
        target: target
    )
    await runtime.backend.emit(
        .webSocket(.closed(id: requestID, timestamp: 2)),
        target: target
    )
    try await waitUntil { request.state == .finished }

    #expect(request.hasResponse)
    #expect(request.hasResponseBody == false)
    #expect(request.canFetchResponseBody == false)
    let commandsBeforeFetch = await runtime.backend.recordedCommands()
    await request.fetchResponseBody()
    let commandsAfterFetch = await runtime.backend.recordedCommands()
    #expect(commandsAfterFetch == commandsBeforeFetch)
    #expect(commandsAfterFetch.filter {
        $0 == RecordedCommand(domain: "Network", method: "getResponseBody")
    }.isEmpty)
    #expect(request.responseBody.phase == .available)
}

@MainActor
@Test
func webSocketEventForUnknownRequestIsSkipped() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("missing-websocket")

    await runtime.backend.emit(
        .webSocket(.handshakeResponse(
            id: requestID,
            response: Network.Response(status: 101),
            timestamp: 1
        )),
        target: target
    )
    await runtime.backend.emit(
        .webSocket(.created(id: requestID, url: "wss://example.com/socket")),
        target: target
    )

    try await waitUntil { context.network.requests.count == 1 }
    #expect(context.network.requests.first?.webSocket?.readyState == .connecting)
    #expect(context.network.requests.first?.webSocket?.handshakeResponse == nil)
    #expect(context.state == .attached)
}

@MainActor
@Test
func webSocketOtherEventDoesNotMutateRequests() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)

    let baseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(
        .webSocket(.other(RawEvent(domain: "Network", method: "webSocketFutureEvent"))),
        target: target
    )
    let didProcessOtherEvent = await context.waitForEventPumpAppliedSequenceForTesting(after: baseline)
    #expect(didProcessOtherEvent)

    #expect(context.network.requests.isEmpty)
    #expect(context.state == .attached)
}
