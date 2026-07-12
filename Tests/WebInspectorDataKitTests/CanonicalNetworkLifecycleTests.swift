import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@Test
func canonicalNetworkRequestInsertNormalizesEveryProtocolField() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope(domBindingEpoch: 4)
    let backendID = Network.BackendResourceID(
        sourceProcessID: "process",
        resourceID: "resource"
    )
    let transaction = try #require(
        try fixture.store.reduce(
            canonicalRequestWillBeSent(
                id: "request",
                url: "https://example.test/script.js",
                method: "POST",
                headers: ["Accept": "text/javascript"],
                postData: "body",
                referrerPolicy: "strict-origin",
                integrity: "sha256-value",
                backendResourceIdentifier: backendID,
                initiatorKind: "script",
                initiatorURL: "https://example.test/index.html",
                initiatorLine: 10,
                initiatorColumn: 20,
                initiatorNodeID: "script-node",
                resourceType: .script,
                timestamp: 12.5
            ),
            scope: scope
        ))

    guard case let .insert(record, query) = transaction.requestChanges.first else {
        Issue.record("Expected a full canonical request insertion.")
        return
    }
    #expect(record.currentHop.request.url == "https://example.test/script.js")
    #expect(record.currentHop.request.method == "POST")
    #expect(
        record.currentHop.request.headers == [
            "Accept": "text/javascript"
        ])
    #expect(record.currentHop.request.postData == "body")
    #expect(record.currentHop.request.referrerPolicy == "strict-origin")
    #expect(record.currentHop.request.integrity == "sha256-value")
    #expect(record.currentHop.request.backendResourceIdentifier == CanonicalNetworkBackendResourceIdentifier(backendID))
    #expect(
        record.initialInitiator
            == CanonicalNetworkInitiator(
                Network.Initiator(
                    kind: "script",
                    url: "https://example.test/index.html",
                    line: 10,
                    column: 20,
                    nodeID: DOM.Node.ID("script-node")
                )
            ))
    #expect(record.logicalStartTimestamp == 12.5)
    #expect(record.lifecycle == .pending)
    #expect(query.resourceCategory == .script)
    #expect(query.searchableText.contains("script.js"))
    #expect(
        fixture.store.snapshot.requests == [
            CanonicalNetworkRequestSnapshotEntry(
                record: record,
                query: query
            )
        ])
    #expect(fixture.store.snapshot.entries.count == 1)
}

@Test
func canonicalNetworkRedirectPreservesLogicalStartAndInvalidatesBodyLease() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope(domBindingEpoch: 1)
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "redirect",
            url: "https://example.test/start",
            method: "POST",
            initiatorKind: "parser",
            initiatorNodeID: "node",
            resourceType: .document,
            timestamp: 1
        ),
        scope: scope
    )
    let rawID = Network.Request.ID("redirect")
    let responseTransaction = try #require(
        try fixture.store.reduce(
            .responseReceived(
                id: rawID,
                response: Network.Response(
                    url: "https://example.test/start",
                    status: 301,
                    statusText: "Moved",
                    mimeType: "text/html",
                    headers: ["Location": "https://example.test/final"],
                    source: Network.Source(rawValue: "network"),
                    requestHeaders: ["X-Rewritten": "true"],
                    bodySize: 3
                ),
                resourceType: .document,
                timestamp: 2
            ),
            scope: scope
        ))
    guard
        case let .update(_, responsePatch, responseQuery) =
            responseTransaction.requestChanges.first
    else {
        Issue.record("Expected a response patch.")
        return
    }
    #expect(responseQuery?.statusCode == 301)
    let afterResponse = fixture.store.requests[0]
    var projectedResponse = CanonicalNetworkRequestRecord(
        id: afterResponse.id,
        insertionOrdinal: afterResponse.insertionOrdinal,
        membership: afterResponse.membership,
        initialInitiator: afterResponse.initialInitiator,
        logicalStartTimestamp: afterResponse.logicalStartTimestamp,
        currentHop: CanonicalNetworkCurrentHop(
            request: CanonicalNetworkRequestPayload(
                rawID: rawID,
                url: "https://example.test/start",
                method: "POST"
            ),
            resourceType: Network.ResourceType.document.rawValue,
            requestSentTimestamp: 1
        )
    )
    // The authoritative patch supplies all replacement response fields; a
    // context does not re-run response semantics.
    projectedResponse.apply(responsePatch)
    #expect(projectedResponse.currentHop.response == afterResponse.currentHop.response)
    #expect(afterResponse.currentHop.request.headers == ["X-Rewritten": "true"])
    let lease = try #require(fixture.store.responseBodyLease(for: afterResponse.id))

    let dataTransaction = try #require(
        try fixture.store.reduce(
            .dataReceived(
                id: rawID,
                dataLength: 7,
                encodedDataLength: 5,
                timestamp: 2.5
            ),
            scope: scope
        ))
    guard
        case let .update(_, _, dataQuery) =
            dataTransaction.requestChanges.first,
        case let .update(_, _, entryQuery) = dataTransaction.entryChanges.first
    else {
        Issue.record("Expected request and entry transfer patches.")
        return
    }
    #expect(dataQuery == nil)
    #expect(entryQuery == nil)

    let redirectEvent = canonicalRequestWillBeSent(
        id: "redirect",
        url: "https://example.test/final",
        method: "GET",
        initiatorKind: "other",
        initiatorNodeID: "different-node",
        resourceType: .document,
        redirectResponse: Network.Response(
            url: "https://example.test/start",
            status: 301,
            statusText: "Moved",
            mimeType: "text/html",
            headers: ["Location": "https://example.test/final"]
        ),
        timestamp: 3
    )
    _ = try fixture.store.reduce(redirectEvent, scope: scope)
    let redirected = fixture.store.requests[0]
    #expect(redirected.redirects.count == 1)
    #expect(redirected.redirects[0].decodedDataLength == 7)
    #expect(redirected.redirects[0].encodedDataLength == 5)
    #expect(redirected.currentHop.request.url == "https://example.test/final")
    #expect(redirected.currentHop.request.method == "GET")
    #expect(redirected.logicalStartTimestamp == 1)
    #expect(redirected.initialInitiator?.kind == "parser")
    #expect(redirected.lifecycle == .pending)
    #expect(!fixture.store.isCurrent(lease))

    _ = try fixture.store.reduce(
        .responseReceived(
            id: rawID,
            response: Network.Response(
                url: "https://example.test/final",
                status: 200,
                mimeType: "application/json"
            ),
            resourceType: .fetch,
            timestamp: 4
        ),
        scope: scope
    )
    _ = try fixture.store.reduce(
        .loadingFinished(
            id: rawID,
            timestamp: 5,
            sourceMapURL: "https://example.test/final.map",
            metrics: Network.Metrics(
                timestamp: 5,
                networkProtocol: "h2",
                remoteAddress: "127.0.0.1:443",
                encodedDataLength: 11,
                decodedBodyLength: 13
            )
        ),
        scope: scope
    )
    let finished = fixture.store.requests[0]
    #expect(finished.lifecycle == .finished)
    #expect(finished.currentHop.sourceMapURL == "https://example.test/final.map")
    #expect(
        finished.currentHop.metrics
            == CanonicalNetworkMetrics(
                Network.Metrics(
                    timestamp: 5,
                    networkProtocol: "h2",
                    remoteAddress: "127.0.0.1:443",
                    encodedDataLength: 11,
                    decodedBodyLength: 13
                )
            ))
    #expect(finished.currentHop.transfer.encodedDataLength == 11)
    #expect(finished.currentHop.transfer.decodedDataLength == 13)
}

@Test
func canonicalNetworkAttachRacesAreNoOpsAndResponseFirstSynthesizesGET() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope()
    let missing = Network.Request.ID("missing")
    let before = fixture.store

    #expect(
        try fixture.store.reduce(
            .responseReceived(
                id: missing,
                response: Network.Response(bodySize: -1),
                resourceType: nil,
                timestamp: 1
            ),
            scope: scope
        ) == nil)
    #expect(
        try fixture.store.reduce(
            .dataReceived(
                id: missing,
                dataLength: -1,
                encodedDataLength: -1,
                timestamp: 1
            ),
            scope: scope
        ) == nil)
    #expect(
        try fixture.store.reduce(
            .loadingFinished(
                id: missing,
                timestamp: 1,
                sourceMapURL: nil,
                metrics: Network.Metrics(encodedDataLength: -1)
            ),
            scope: scope
        ) == nil)
    #expect(fixture.store == before)

    let responseFirstID = Network.Request.ID("response-first")
    _ = try fixture.store.reduce(
        .responseReceived(
            id: responseFirstID,
            response: Network.Response(
                url: "https://example.test/response-first",
                status: 206,
                mimeType: "video/mp4",
                requestHeaders: ["Range": "bytes=0-"]
            ),
            resourceType: .media,
            timestamp: 2
        ),
        scope: scope
    )
    let responseFirst = try #require(
        fixture.store.requests.first(where: {
            $0.id.rawRequestID == responseFirstID
        })
    )
    #expect(responseFirst.currentHop.request.method == "GET")
    #expect(
        responseFirst.currentHop.request.headers == [
            "Range": "bytes=0-"
        ])
    #expect(responseFirst.lifecycle == .responded)
    #expect(responseFirst.responseBodyRevision == 1)
}

@Test
func canonicalNetworkDataTreatsWebKitMinusOneEncodedLengthAsUnknown() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope()
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "unknown-encoded",
            url: "https://example.test/data",
            timestamp: 1
        ),
        scope: scope
    )
    _ = try fixture.store.reduce(
        .dataReceived(
            id: Network.Request.ID("unknown-encoded"),
            dataLength: 10,
            encodedDataLength: -1,
            timestamp: 2
        ),
        scope: scope
    )
    #expect(
        fixture.store.requests[0].currentHop.transfer
            .decodedDataLength == 10)
    #expect(
        fixture.store.requests[0].currentHop.transfer
            .encodedDataLength == 0)
}

@Test
func canonicalNetworkClassifiesEstablishedMediaExtensionsBeforeResponse() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope()
    for pathExtension in ["aif", "aiff", "caf", "m4v", "wav"] {
        let transaction = try #require(
            try fixture.store.reduce(
                canonicalRequestWillBeSent(
                    id: pathExtension,
                    url: "https://example.test/media.\(pathExtension)",
                    resourceType: nil,
                    timestamp: 1
                ),
                scope: scope
            ))
        guard case let .insert(_, query) = transaction.requestChanges.first else {
            Issue.record("Expected a canonical request insertion.")
            return
        }
        #expect(query.resourceCategory == .media)
    }
}

@Test
func canonicalNetworkMemoryCacheRequiresFreshURLBearingIdentity() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope()
    let rawID = Network.Request.ID("cache")

    #expect(
        try fixture.store.reduce(
            .requestServedFromMemoryCache(
                id: rawID,
                response: Network.Response(bodySize: -1),
                initiator: Network.Initiator(kind: "other"),
                resourceType: .image,
                timestamp: 1
            ),
            scope: scope
        ) == nil)
    let transaction = try #require(
        try fixture.store.reduce(
            .requestServedFromMemoryCache(
                id: rawID,
                response: Network.Response(
                    url: "https://example.test/image.png",
                    status: 200,
                    mimeType: "image/png",
                    headers: ["Content-Type": "image/png"],
                    source: Network.Source(rawValue: "memory-cache"),
                    requestHeaders: ["Accept": "image/png"],
                    bodySize: 42
                ),
                initiator: Network.Initiator(
                    kind: "parser",
                    nodeID: DOM.Node.ID("image")
                ),
                resourceType: .image,
                timestamp: 2
            ),
            scope: scope
        ))
    guard case let .insert(record, query) = transaction.requestChanges.first else {
        Issue.record("Expected a memory-cache insertion.")
        return
    }
    #expect(record.lifecycle == .finished)
    #expect(record.currentHop.servedFromMemoryCache)
    #expect(record.currentHop.transfer.decodedDataLength == 42)
    #expect(record.currentHop.transfer.encodedDataLength == 42)
    #expect(record.currentHop.response?.source == "memory-cache")
    #expect(record.responseBodyRevision == 1)
    #expect(query.resourceCategory == .image)

    let beforeReuse = fixture.store
    #expect(throws: CanonicalNetworkProtocolViolation.self) {
        try fixture.store.reduce(
            .requestServedFromMemoryCache(
                id: rawID,
                response: Network.Response(
                    url: "https://example.test/image.png"
                ),
                initiator: Network.Initiator(kind: "other"),
                resourceType: .image,
                timestamp: 3
            ),
            scope: scope
        )
    }
    #expect(fixture.store == beforeReuse)

    _ = fixture.store.clear()
    let beforeTombstoneReuse = fixture.store
    #expect(throws: CanonicalNetworkProtocolViolation.self) {
        try fixture.store.reduce(
            .requestServedFromMemoryCache(
                id: rawID,
                response: Network.Response(
                    url: "https://example.test/image.png"
                ),
                initiator: Network.Initiator(kind: "other"),
                resourceType: .image,
                timestamp: 4
            ),
            scope: scope
        )
    }
    #expect(fixture.store == beforeTombstoneReuse)
}

@Test
func canonicalNetworkProtocolViolationsHaveStrongExceptionGuarantee() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope()
    let eventID = Network.Request.ID("event")
    let payloadID = Network.Request.ID("payload")
    let mismatch = Network.Event.requestWillBeSent(
        id: eventID,
        request: Network.Request(
            id: payloadID,
            url: "https://example.test/",
            method: "GET"
        ),
        initiator: Network.Initiator(kind: "other"),
        resourceType: .fetch,
        redirectResponse: nil,
        timestamp: 1
    )
    let empty = fixture.store
    #expect(throws: CanonicalNetworkProtocolViolation.self) {
        try fixture.store.reduce(mismatch, scope: scope)
    }
    #expect(fixture.store == empty)

    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "tracked",
            url: "https://example.test/tracked",
            timestamp: 2
        ),
        scope: scope
    )
    let active = fixture.store
    #expect(throws: CanonicalNetworkProtocolViolation.self) {
        try fixture.store.reduce(
            canonicalRequestWillBeSent(
                id: "tracked",
                url: "https://example.test/reused",
                timestamp: 3
            ),
            scope: scope
        )
    }
    #expect(fixture.store == active)
    #expect(throws: CanonicalNetworkProtocolViolation.self) {
        try fixture.store.reduce(
            .dataReceived(
                id: Network.Request.ID("tracked"),
                dataLength: -1,
                encodedDataLength: 0,
                timestamp: 3
            ),
            scope: scope
        )
    }
    #expect(fixture.store == active)
}
