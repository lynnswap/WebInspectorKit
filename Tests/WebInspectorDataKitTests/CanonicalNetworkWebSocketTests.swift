import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@Test
func canonicalNetworkWebSocketRetainsCreationMembershipThroughHandshake() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let creationScope = fixture.scope(
        targetID: "initial-frame",
        agentTargetID: "page-agent",
        navigationEpoch: 2,
        domBindingEpoch: 3
    )
    let handshakeScope = fixture.scope(
        targetID: "later-frame",
        agentTargetID: "page-agent",
        navigationEpoch: 8,
        domBindingEpoch: 9
    )
    let rawID = Network.Request.ID("socket-membership")

    _ = try fixture.store.reduce(
        .webSocket(
            .created(
                id: rawID,
                url: "wss://example.test/socket"
            )),
        scope: creationScope
    )
    _ = try fixture.store.reduce(
        .webSocket(
            .handshakeRequest(
                id: rawID,
                request: Network.Request(
                    id: rawID,
                    url: "wss://example.test/socket",
                    method: "GET"
                ),
                timestamp: 1
            )),
        scope: handshakeScope
    )

    let request = try #require(fixture.store.requests.first)
    #expect(
        request.membership.semanticTargetID
            == WebInspectorTarget.ID("initial-frame")
    )
    #expect(
        request.membership.agentTargetID
            == WebInspectorTarget.ID("page-agent")
    )
    #expect(request.membership.navigationEpoch?.rawValue == 2)
    #expect(request.membership.domBindingEpoch?.rawValue == 3)
}
@Test
func canonicalNetworkWebSocketUsesAppendPatchesAndPreservesChronology() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope()
    let rawID = Network.Request.ID("socket")
    _ = try fixture.store.reduce(
        .webSocket(
            .created(
                id: rawID,
                url: "wss://example.test/socket"
            )),
        scope: scope
    )
    #expect(fixture.store.requests.isEmpty)
    #expect(fixture.store.entries.isEmpty)
    let reservedID = try #require(
        fixture.store.requestID(forRawRequestID: rawID, scope: scope)
    )
    #expect(fixture.store.request(for: reservedID) == nil)
    let conflictingScope = fixture.scope(
        targetID: "worker",
        agentTargetID: "other-agent"
    )
    #expect(
        fixture.store.requestID(
            forRawRequestID: rawID,
            scope: conflictingScope
        ) == nil
    )
    _ = try fixture.store.reduce(
        .webSocket(
            .handshakeRequest(
                id: rawID,
                request: Network.Request(
                    id: rawID,
                    url: "",
                    method: "GET",
                    headers: ["Upgrade": "websocket"]
                ),
                timestamp: 1
            )),
        scope: scope
    )
    #expect(fixture.store.requests[0].logicalStartTimestamp == 1)
    _ = try fixture.store.reduce(
        .webSocket(
            .handshakeResponse(
                id: rawID,
                response: Network.Response(
                    status: 101,
                    statusText: "Switching Protocols",
                    headers: ["Upgrade": "websocket"]
                ),
                timestamp: 2
            )),
        scope: scope
    )
    #expect(fixture.store.requests[0].currentHop.request.url == "wss://example.test/socket")
    #expect(fixture.store.requests[0].webSocket?.readyState == .open)

    let beforeFrame = fixture.store.requests[0]
    let frame = Network.WebSocketFrame(
        opcode: 1,
        mask: true,
        payloadData: "hello",
        payloadLength: 5
    )
    let frameTransaction = try #require(
        try fixture.store.reduce(
            .webSocket(
                .frameSent(
                    id: rawID,
                    frame: frame,
                    timestamp: 3
                )),
            scope: scope
        ))
    guard
        case let .update(_, framePatch, frameQuery) =
            frameTransaction.requestChanges.first,
        case let .webSocketContentAppended(content, transfer) = framePatch
    else {
        Issue.record("Expected one WebSocket append patch.")
        return
    }
    #expect(frameQuery == nil)
    #expect(
        content
            == .frame(
                direction: .sent,
                opcode: 1,
                mask: true,
                payloadData: "hello",
                payloadLength: 5,
                timestamp: 3
            ))
    #expect(transfer.decodedDataLength == 5)
    var projected = beforeFrame
    projected.apply(framePatch)
    #expect(projected == fixture.store.requests[0])

    let errorTransaction = try #require(
        try fixture.store.reduce(
            .webSocket(
                .error(
                    id: rawID,
                    message: "protocol error",
                    timestamp: 4
                )),
            scope: scope
        ))
    guard
        case let .update(_, errorPatch, errorQuery) =
            errorTransaction.requestChanges.first,
        case let .webSocketContentAppended(errorContent, _) =
            errorPatch
    else {
        Issue.record("Expected one WebSocket error append patch.")
        return
    }
    #expect(errorQuery == nil)
    #expect(
        errorContent
            == .error(
                message: "protocol error",
                timestamp: 4
            ))
    #expect(
        fixture.store.requests[0].webSocket?.contents == [
            content,
            errorContent,
        ])

    _ = try fixture.store.reduce(
        .webSocket(.closed(id: rawID, timestamp: 5)),
        scope: scope
    )
    #expect(fixture.store.requests[0].lifecycle == .finished)
    #expect(fixture.store.requests[0].webSocket?.readyState == .closed)
    #expect(fixture.store.requests[0].webSocket?.closedTimestamp == 5)
}

@Test
func canonicalNetworkWebSocketLiveDuplicatesFailAndReplayIsIdempotent() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope()
    let rawID = Network.Request.ID("socket")
    let created = Network.Event.webSocket(
        .created(
            id: rawID,
            url: "wss://example.test/socket"
        ))
    _ = try fixture.store.reduce(created, scope: scope)

    let active = fixture.store
    #expect(throws: CanonicalNetworkProtocolViolation.self) {
        try fixture.store.reduce(created, scope: scope, origin: .live)
    }
    #expect(fixture.store == active)
    #expect(
        try fixture.store.reduce(
            created,
            scope: scope,
            origin: .enableReplay
        ) == nil)

    let beforeConflict = fixture.store
    #expect(throws: CanonicalNetworkProtocolViolation.self) {
        try fixture.store.reduce(
            .webSocket(
                .created(
                    id: rawID,
                    url: "wss://example.test/other"
                )),
            scope: scope,
            origin: .enableReplay
        )
    }
    #expect(fixture.store == beforeConflict)
}

@Test
func canonicalNetworkWebSocketReplayFillsMissingResponseWithoutReplacingFrames() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope()
    let rawID = Network.Request.ID("socket")
    _ = try fixture.store.reduce(
        .webSocket(
            .created(
                id: rawID,
                url: "wss://example.test/socket"
            )),
        scope: scope
    )
    _ = try fixture.store.reduce(
        .webSocket(
            .handshakeRequest(
                id: rawID,
                request: Network.Request(
                    id: rawID,
                    url: "",
                    method: "GET",
                    headers: ["Upgrade": "websocket"]
                ),
                timestamp: 1
            )),
        scope: scope
    )
    _ = try fixture.store.reduce(
        .webSocket(
            .frameReceived(
                id: rawID,
                frame: Network.WebSocketFrame(
                    opcode: 2,
                    mask: false,
                    payloadData: "AQID",
                    payloadLength: 3
                ),
                timestamp: 2
            )),
        scope: scope
    )
    _ = try fixture.store.reduce(
        .webSocket(.closed(id: rawID, timestamp: 3)),
        scope: scope
    )
    let closed = fixture.store.requests[0]
    let originalContents = closed.webSocket?.contents
    #expect(closed.logicalStartTimestamp == 1)
    #expect(closed.currentHop.requestSentTimestamp == 1)
    #expect(closed.currentHop.responseReceivedTimestamp == nil)

    let replayRequest = Network.Request(
        id: rawID,
        url: "",
        method: "GET",
        headers: ["Upgrade": "websocket"]
    )
    #expect(
        try fixture.store.reduce(
            .webSocket(
                .created(
                    id: rawID,
                    url: "wss://example.test/socket"
                )),
            scope: scope,
            origin: .enableReplay
        ) == nil)
    #expect(
        try fixture.store.reduce(
            .webSocket(
                .handshakeRequest(
                    id: rawID,
                    request: replayRequest,
                    timestamp: 100
                )),
            scope: scope,
            origin: .enableReplay
        ) == nil)
    let replayResponse = Network.Response(
        status: 101,
        statusText: "Switching Protocols",
        headers: ["Upgrade": "websocket"]
    )
    _ = try fixture.store.reduce(
        .webSocket(
            .handshakeResponse(
                id: rawID,
                response: replayResponse,
                timestamp: 101
            )),
        scope: scope,
        origin: .enableReplay
    )
    let filled = fixture.store.requests[0]
    #expect(filled.webSocket?.handshakeRequest?.request.url == "wss://example.test/socket")
    #expect(filled.webSocket?.handshakeResponse?.response.status == 101)
    #expect(filled.webSocket?.contents == originalContents)
    #expect(filled.lifecycle == .finished)
    #expect(filled.webSocket?.readyState == .closed)
    #expect(filled.webSocket?.closedTimestamp == 3)
    #expect(filled.logicalStartTimestamp == 1)
    #expect(filled.currentHop.requestSentTimestamp == 1)
    #expect(filled.currentHop.responseReceivedTimestamp == nil)

    let afterFill = fixture.store
    #expect(
        try fixture.store.reduce(
            .webSocket(
                .handshakeRequest(
                    id: rawID,
                    request: replayRequest,
                    timestamp: 200
                )),
            scope: scope,
            origin: .enableReplay
        ) == nil)
    #expect(
        try fixture.store.reduce(
            .webSocket(
                .handshakeResponse(
                    id: rawID,
                    response: replayResponse,
                    timestamp: 201
                )),
            scope: scope,
            origin: .enableReplay
        ) == nil)
    #expect(
        try fixture.store.reduce(
            .webSocket(.closed(id: rawID, timestamp: 202)),
            scope: scope,
            origin: .enableReplay
        ) == nil)
    #expect(fixture.store == afterFill)

    #expect(throws: CanonicalNetworkProtocolViolation.self) {
        try fixture.store.reduce(
            .webSocket(
                .handshakeRequest(
                    id: rawID,
                    request: replayRequest,
                    timestamp: 300
                )),
            scope: scope,
            origin: .live
        )
    }
    #expect(fixture.store == afterFill)
}

@Test
func canonicalNetworkWebSocketPayloadMismatchIsIgnoredUnlessTracked() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope()
    let eventID = Network.Request.ID("event")
    let payloadID = Network.Request.ID("payload")
    let mismatched = Network.Event.webSocket(
        .handshakeRequest(
            id: eventID,
            request: Network.Request(
                id: payloadID,
                url: "wss://example.test/socket",
                method: "GET"
            ),
            timestamp: 1
        ))
    #expect(try fixture.store.reduce(mismatched, scope: scope) == nil)

    _ = try fixture.store.reduce(
        .webSocket(
            .created(
                id: eventID,
                url: "wss://example.test/socket"
            )),
        scope: scope
    )
    let tracked = fixture.store
    #expect(throws: CanonicalNetworkProtocolViolation.self) {
        try fixture.store.reduce(mismatched, scope: scope)
    }
    #expect(fixture.store == tracked)
}

@Test
func canonicalNetworkGenericEventsCannotCreateWebSocketState() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope()
    let rawID = Network.Request.ID("generic")
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "generic",
            url: "wss://example.test/socket",
            resourceType: .fetch,
            timestamp: 1
        ),
        scope: scope
    )
    _ = try fixture.store.reduce(
        .responseReceived(
            id: rawID,
            response: Network.Response(
                url: "wss://example.test/socket",
                status: 101
            ),
            resourceType: .webSocket,
            timestamp: 2
        ),
        scope: scope
    )
    let genericRecord = try #require(fixture.store.requests.first)
    #expect(genericRecord.webSocket == nil)

    let beforeHandshake = fixture.store
    #expect(
        throws: CanonicalNetworkProtocolViolation.missingWebSocket(
            event: "Network.webSocketWillSendHandshakeRequest",
            id: genericRecord.id
        )
    ) {
        try fixture.store.reduce(
            .webSocket(
                .handshakeRequest(
                    id: rawID,
                    request: Network.Request(
                        id: rawID,
                        url: "wss://example.test/socket",
                        method: "GET"
                    ),
                    timestamp: 3
                )),
            scope: scope
        )
    }
    #expect(fixture.store == beforeHandshake)
}
