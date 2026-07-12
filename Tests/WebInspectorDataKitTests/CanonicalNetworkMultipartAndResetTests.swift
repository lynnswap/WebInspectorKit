import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@Test
func canonicalNetworkMultipartContinuesAfterFirstFinishWithoutReopening() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope()
    let rawID = Network.Request.ID("multipart")
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "multipart",
            url: "https://example.test/camera",
            resourceType: .image,
            timestamp: 1
        ),
        scope: scope
    )
    _ = try fixture.store.reduce(
        .responseReceived(
            id: rawID,
            response: Network.Response(
                url: "https://example.test/camera",
                status: 200,
                mimeType: "MULTIPART/X-MIXED-REPLACE"
            ),
            resourceType: .image,
            timestamp: 2
        ),
        scope: scope
    )
    _ = try fixture.store.reduce(
        .loadingFinished(
            id: rawID,
            timestamp: 3,
            sourceMapURL: nil,
            metrics: nil
        ),
        scope: scope
    )
    let firstPart = fixture.store.requests[0]
    #expect(firstPart.lifecycle == .finished)
    #expect(firstPart.allowsMultipartContinuation)
    let firstLease = try #require(
        fixture.store.responseBodyLease(for: firstPart.id)
    )

    _ = try fixture.store.reduce(
        .responseReceived(
            id: rawID,
            response: Network.Response(
                url: "https://example.test/camera",
                status: 200,
                mimeType: "image/jpeg",
                headers: ["X-Part": "2"]
            ),
            resourceType: .image,
            timestamp: 4
        ),
        scope: scope
    )
    let secondPart = fixture.store.requests[0]
    #expect(secondPart.lifecycle == .finished)
    #expect(secondPart.allowsMultipartContinuation)
    #expect(secondPart.currentHop.response?.mimeType == "image/jpeg")
    #expect(secondPart.responseBodyRevision == firstPart.responseBodyRevision + 1)
    #expect(!fixture.store.isCurrent(firstLease))

    let dataTransaction = try #require(
        try fixture.store.reduce(
            .dataReceived(
                id: rawID,
                dataLength: 12,
                encodedDataLength: 10,
                timestamp: 5
            ),
            scope: scope
        ))
    #expect(fixture.store.requests[0].lifecycle == .finished)
    guard
        case let .update(_, _, query) =
            dataTransaction.requestChanges.first
    else {
        Issue.record("Expected an authoritative multipart transfer patch.")
        return
    }
    #expect(query == nil)

    let beforeDuplicateTerminal = fixture.store
    #expect(throws: CanonicalNetworkProtocolViolation.self) {
        try fixture.store.reduce(
            .loadingFinished(
                id: rawID,
                timestamp: 6,
                sourceMapURL: nil,
                metrics: nil
            ),
            scope: scope
        )
    }
    #expect(fixture.store == beforeDuplicateTerminal)
}

@Test
func canonicalNetworkMultipartRecognitionIsExactExceptForASCIICase() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope()
    let rawID = Network.Request.ID("parameterized")
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "parameterized",
            url: "https://example.test/camera",
            timestamp: 1
        ),
        scope: scope
    )
    _ = try fixture.store.reduce(
        .responseReceived(
            id: rawID,
            response: Network.Response(
                url: "https://example.test/camera",
                mimeType: "multipart/x-mixed-replace; boundary=frame"
            ),
            resourceType: .image,
            timestamp: 2
        ),
        scope: scope
    )
    _ = try fixture.store.reduce(
        .loadingFinished(
            id: rawID,
            timestamp: 3,
            sourceMapURL: nil,
            metrics: nil
        ),
        scope: scope
    )
    #expect(!fixture.store.requests[0].allowsMultipartContinuation)

    let terminal = fixture.store
    #expect(throws: CanonicalNetworkProtocolViolation.self) {
        try fixture.store.reduce(
            .responseReceived(
                id: rawID,
                response: Network.Response(
                    url: "https://example.test/camera",
                    mimeType: "image/jpeg"
                ),
                resourceType: .image,
                timestamp: 4
            ),
            scope: scope
        )
    }
    #expect(fixture.store == terminal)
}

@Test
func canonicalNetworkClearTombstonesLateEventsUntilGenerationReset() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope(domBindingEpoch: 1)
    let requestID = Network.Request.ID("request")
    let socketID = Network.Request.ID("socket")
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "request",
            url: "https://example.test/request",
            initiatorNodeID: "node",
            timestamp: 1
        ),
        scope: scope
    )
    _ = try fixture.store.reduce(
        .responseReceived(
            id: requestID,
            response: Network.Response(
                url: "https://example.test/request",
                status: 200
            ),
            resourceType: .fetch,
            timestamp: 2
        ),
        scope: scope
    )
    let requestLease = try #require(
        fixture.store.responseBodyLease(for: fixture.store.requests[0].id)
    )
    _ = try fixture.store.reduce(
        .webSocket(
            .created(
                id: socketID,
                url: "wss://example.test/socket"
            )),
        scope: scope
    )
    let oldMaxEntryOrdinal = try #require(
        fixture.store.entries.map(\.id.ordinal).max()
    )

    let clear = fixture.store.clear()
    #expect(clear.requestChanges.count == 1)
    #expect(clear.entryChanges.count == 1)
    #expect(fixture.store.requests.isEmpty)
    #expect(fixture.store.entries.isEmpty)
    #expect(fixture.store.tombstonedRequestIDs.count == 2)
    #expect(!fixture.store.isCurrent(requestLease))

    let cleared = fixture.store
    #expect(
        try fixture.store.reduce(
            .responseReceived(
                id: requestID,
                response: Network.Response(
                    url: "https://example.test/request",
                    bodySize: -1
                ),
                resourceType: .fetch,
                timestamp: 3
            ),
            scope: scope
        ) == nil)
    #expect(
        try fixture.store.reduce(
            .dataReceived(
                id: requestID,
                dataLength: -1,
                encodedDataLength: -1,
                timestamp: 3
            ),
            scope: scope
        ) == nil)
    #expect(
        try fixture.store.reduce(
            .loadingFinished(
                id: requestID,
                timestamp: 3,
                sourceMapURL: nil,
                metrics: Network.Metrics(encodedDataLength: -1)
            ),
            scope: scope
        ) == nil)
    #expect(
        try fixture.store.reduce(
            .loadingFailed(
                id: requestID,
                errorText: "late",
                canceled: false,
                timestamp: 3
            ),
            scope: scope
        ) == nil)
    #expect(
        try fixture.store.reduce(
            .webSocket(
                .frameReceived(
                    id: socketID,
                    frame: Network.WebSocketFrame(
                        opcode: 1,
                        mask: false,
                        payloadData: "late",
                        payloadLength: -1
                    ),
                    timestamp: 3
                )),
            scope: scope
        ) == nil)
    #expect(
        try fixture.store.reduce(
            .webSocket(
                .handshakeRequest(
                    id: socketID,
                    request: Network.Request(
                        id: Network.Request.ID("mismatched"),
                        url: "wss://example.test/socket",
                        method: "GET"
                    ),
                    timestamp: 3
                )),
            scope: scope
        ) == nil)
    #expect(
        try fixture.store.reduce(
            .webSocket(
                .handshakeResponse(
                    id: socketID,
                    response: Network.Response(bodySize: -1),
                    timestamp: 3
                )),
            scope: scope
        ) == nil)
    #expect(
        try fixture.store.reduce(
            .webSocket(
                .error(
                    id: socketID,
                    message: "late",
                    timestamp: 3
                )),
            scope: scope
        ) == nil)
    #expect(
        try fixture.store.reduce(
            .webSocket(.closed(id: socketID, timestamp: 3)),
            scope: scope
        ) == nil)
    #expect(fixture.store == cleared)

    #expect(throws: CanonicalNetworkProtocolViolation.self) {
        try fixture.store.reduce(
            canonicalRequestWillBeSent(
                id: "request",
                url: "https://example.test/reuse",
                timestamp: 4
            ),
            scope: fixture.scope(
                navigationEpoch: 2,
                domBindingEpoch: 1
            )
        )
    }
    #expect(throws: CanonicalNetworkProtocolViolation.self) {
        try fixture.store.reduce(
            .webSocket(
                .created(
                    id: socketID,
                    url: "wss://example.test/socket"
                )),
            scope: scope
        )
    }
    #expect(
        try fixture.store.targetWasLost(
            WebInspectorTarget.ID("unrelated")
        ) == nil)
    #expect(fixture.store.tombstonedRequestIDs.count == 2)

    _ = try fixture.store.reset(
        attachmentGeneration: .init(rawValue: 1),
        pageGeneration: .init(rawValue: 2)
    )
    #expect(fixture.store.tombstonedRequestIDs.isEmpty)
    let nextScope = fixture.scope(
        domBindingEpoch: 1,
        pageGeneration: .init(rawValue: 2)
    )
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "request",
            url: "https://example.test/new-generation",
            timestamp: 5
        ),
        scope: nextScope
    )
    #expect(fixture.store.entries[0].id.ordinal > oldMaxEntryOrdinal)
    #expect(fixture.store.requests[0].id.pageGeneration == .init(rawValue: 2))
}

@Test
func canonicalNetworkTargetLossInvalidatesBodyAuthority() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope(targetID: "frame")
    let rawID = Network.Request.ID("body")
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "body",
            url: "https://example.test/body",
            timestamp: 1
        ),
        scope: scope
    )
    _ = try fixture.store.reduce(
        .responseReceived(
            id: rawID,
            response: Network.Response(
                url: "https://example.test/body",
                status: 200
            ),
            resourceType: .fetch,
            timestamp: 2
        ),
        scope: scope
    )
    let lease = try #require(
        fixture.store.responseBodyLease(for: fixture.store.requests[0].id)
    )
    _ = try fixture.store.targetWasLost(WebInspectorTarget.ID("frame"))
    #expect(!fixture.store.isCurrent(lease))
}
