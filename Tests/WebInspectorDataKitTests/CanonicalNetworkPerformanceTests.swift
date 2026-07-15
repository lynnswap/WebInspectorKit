import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@Test
func canonicalNetworkLargeGroupInsertionUsesIncrementalEntryPath() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope(domBindingEpoch: 1)
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "request-0",
            url: "https://example.test/0.ts",
            initiatorNodeID: "shared-node",
            timestamp: 0
        ),
        scope: scope
    )
    #expect(fixture.store.performanceCountersForTesting.entryFullRebuildCount == 1)
    #expect(
        fixture.store.performanceCountersForTesting
            .entryFullRebuildMemberVisitCount == 1
    )
    fixture.store.resetPerformanceCountersForTesting()

    for index in 1..<1_000 {
        _ = try fixture.store.reduce(
            canonicalRequestWillBeSent(
                id: "request-\(index)",
                url: "https://example.test/\(index).ts",
                initiatorNodeID: "shared-node",
                timestamp: Double(index)
            ),
            scope: scope
        )
    }

    #expect(fixture.store.entries.count == 1)
    #expect(fixture.store.entries[0].requestIDs.count == 1_000)
    let counters = fixture.store.performanceCountersForTesting
    #expect(counters.entryFullRebuildCount == 0)
    #expect(counters.entryFullRebuildMemberVisitCount == 0)
    #expect(counters.entryQueryRebuildCount == 0)
    #expect(counters.entryIncrementalUpdateCount == 999)
}
@Test
func canonicalNetworkTransferAndFrameUpdatesDoNotScanGroupQueries() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope(domBindingEpoch: 1)
    for index in 0..<1_000 {
        _ = try fixture.store.reduce(
            canonicalRequestWillBeSent(
                id: "request-\(index)",
                url: "https://example.test/segment-\(index).ts",
                initiatorNodeID: "video",
                resourceType: .media,
                timestamp: Double(index)
            ),
            scope: scope
        )
    }
    fixture.store.resetPerformanceCountersForTesting()

    _ = try fixture.store.reduce(
        .dataReceived(
            id: Network.Request.ID("request-500"),
            dataLength: 4_096,
            encodedDataLength: 2_048,
            timestamp: 300
        ),
        scope: scope
    )
    var counters = fixture.store.performanceCountersForTesting
    #expect(counters.entryFullRebuildCount == 0)
    #expect(counters.entryFullRebuildMemberVisitCount == 0)
    #expect(counters.entryQueryRebuildCount == 0)
    #expect(counters.entryIncrementalUpdateCount == 1)
    #expect(fixture.store.entries[0].summary.decodedDataLength == 4_096)
    #expect(fixture.store.entries[0].summary.encodedDataLength == 2_048)

    let socketID = Network.Request.ID("socket")
    _ = try fixture.store.reduce(
        .webSocket(
            .created(
                id: socketID,
                url: "wss://example.test/socket"
            )),
        scope: scope
    )
    _ = try fixture.store.reduce(
        .webSocket(
            .handshakeRequest(
                id: socketID,
                request: Network.Request(
                    id: socketID,
                    url: "",
                    method: "GET"
                ),
                timestamp: 300
            )),
        scope: scope
    )
    fixture.store.resetPerformanceCountersForTesting()
    _ = try fixture.store.reduce(
        .webSocket(
            .frameReceived(
                id: socketID,
                frame: Network.WebSocketFrame(
                    opcode: 2,
                    mask: false,
                    payloadData: "AQID",
                    payloadLength: 3
                ),
                timestamp: 301
            )),
        scope: scope
    )
    counters = fixture.store.performanceCountersForTesting
    #expect(counters.entryFullRebuildCount == 0)
    #expect(counters.entryFullRebuildMemberVisitCount == 0)
    #expect(counters.entryQueryRebuildCount == 0)
    #expect(counters.entryIncrementalUpdateCount == 1)
}

@Test
func canonicalNetworkResponseReplacesOnlyItsOrderedMemberSearchText() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope(domBindingEpoch: 1)
    for index in 0..<1_000 {
        _ = try fixture.store.reduce(
            canonicalRequestWillBeSent(
                id: "request-\(index)",
                url: "https://example.test/segment-\(index).ts",
                initiatorNodeID: "video",
                resourceType: .media,
                timestamp: Double(index)
            ),
            scope: scope
        )
    }
    let before = try #require(fixture.store.snapshot.entries.first)
    fixture.store.resetPerformanceCountersForTesting()

    let transaction = try #require(
        try fixture.store.reduce(
            .responseReceived(
                id: Network.Request.ID("request-500"),
                response: Network.Response(
                    url: "https://cdn.example.test/segment-500.ts",
                    status: 206,
                    statusText: "Partial Content",
                    mimeType: "video/mp2t"
                ),
                resourceType: .media,
                timestamp: 300
            ),
            scope: scope
        ))

    let after = try #require(fixture.store.snapshot.entries.first)
    #expect(after.record.requestIDs == before.record.requestIDs)
    #expect(after.query.searchTexts.count == before.query.searchTexts.count)
    for index in after.query.searchTexts.indices {
        if index == 500 {
            #expect(after.query.searchTexts[index] != before.query.searchTexts[index])
            #expect(after.query.searchTexts[index].contains("206"))
            #expect(
                after.query.searchTexts[index].contains(
                    "cdn.example.test"
                ))
        } else {
            #expect(after.query.searchTexts[index] == before.query.searchTexts[index])
        }
    }
    guard
        case let .update(_, _, entryQuery) =
            transaction.entryChanges.first
    else {
        Issue.record("Expected an incremental entry update.")
        return
    }
    #expect(entryQuery == after.query)
    let counters = fixture.store.performanceCountersForTesting
    #expect(counters.entryFullRebuildCount == 0)
    #expect(counters.entryFullRebuildMemberVisitCount == 0)
    #expect(counters.entryQueryRebuildCount == 0)
    #expect(counters.entryIncrementalUpdateCount == 1)
}

@Test
func canonicalNetworkEntryMemberQueryProjectionsUpdateAtTheirStableIndex() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope(domBindingEpoch: 1)
    for (id, method, timestamp) in [
        ("first", "GET", 1.0),
        ("second", "POST", 2.0),
        ("third", "PATCH", 3.0),
    ] {
        _ = try fixture.store.reduce(
            canonicalRequestWillBeSent(
                id: id,
                url: "https://example.test/\(id).json",
                method: method,
                initiatorNodeID: "shared-node",
                resourceType: .fetch,
                timestamp: timestamp
            ),
            scope: scope
        )
    }
    let initial = try #require(fixture.store.snapshot.entries.first)
    #expect(initial.query.methods == ["GET", "POST", "PATCH"])
    #expect(initial.query.resourceCategories == [.xhrFetch])
    fixture.store.resetPerformanceCountersForTesting()

    let responseTransaction = try #require(
        try fixture.store.reduce(
            .responseReceived(
                id: Network.Request.ID("second"),
                response: Network.Response(
                    url: "https://example.test/second.png",
                    status: 404,
                    statusText: "Not Found",
                    mimeType: "image/png"
                ),
                resourceType: .image,
                timestamp: 4
            ),
            scope: scope
        ))
    let responded = try #require(fixture.store.snapshot.entries.first)
    #expect(responded.query.methods == initial.query.methods)
    #expect(responded.query.resourceCategories == [.xhrFetch, .image])
    #expect(responded.query.searchTexts[0] == initial.query.searchTexts[0])
    #expect(responded.query.searchTexts[1].contains("404"))
    #expect(responded.query.searchTexts[1].contains("image/png"))
    #expect(responded.query.searchTexts[2] == initial.query.searchTexts[2])
    #expect(responded.record.summary.statusSeverity == .warning)
    guard
        case let .update(_, _, responseQuery) =
            responseTransaction.entryChanges.first
    else {
        Issue.record("Expected the response to update its canonical entry.")
        return
    }
    #expect(responseQuery == responded.query)

    let redirectTransaction = try #require(
        try fixture.store.reduce(
            canonicalRequestWillBeSent(
                id: "second",
                url: "https://example.test/second.html",
                method: "DELETE",
                initiatorNodeID: "ignored-after-insertion",
                resourceType: .document,
                redirectResponse: Network.Response(
                    url: "https://example.test/second.png",
                    status: 404,
                    statusText: "Not Found",
                    mimeType: "image/png"
                ),
                timestamp: 5
            ),
            scope: scope
        ))
    let redirected = try #require(fixture.store.snapshot.entries.first)
    #expect(redirected.record.id == initial.record.id)
    #expect(redirected.record.requestIDs == initial.record.requestIDs)
    #expect(redirected.query.methods == ["GET", "DELETE", "PATCH"])
    #expect(redirected.query.resourceCategories == [.xhrFetch, .document])
    #expect(redirected.query.searchTexts[0] == initial.query.searchTexts[0])
    #expect(redirected.query.searchTexts[1].contains("DELETE"))
    #expect(redirected.query.searchTexts[1].contains("second.html"))
    #expect(redirected.query.searchTexts[2] == initial.query.searchTexts[2])
    #expect(redirected.record.summary.statusSeverity == .neutral)
    guard
        case let .update(_, _, redirectQuery) =
            redirectTransaction.entryChanges.first
    else {
        Issue.record("Expected the redirect to update its canonical entry.")
        return
    }
    #expect(redirectQuery == redirected.query)

    let counters = fixture.store.performanceCountersForTesting
    #expect(counters.entryFullRebuildCount == 0)
    #expect(counters.entryFullRebuildMemberVisitCount == 0)
    #expect(counters.entryQueryRebuildCount == 0)
    #expect(counters.entryIncrementalUpdateCount == 2)
}

@Test
func canonicalNetworkEntrySeverityAggregateRespectsEntryOwnershipBoundaries() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let targetA = fixture.scope(targetID: "target-a")
    let targetB = fixture.scope(targetID: "target-b")

    for (scope, id, status) in [
        (targetA, "failed-cache", 503),
        (targetB, "successful-cache", 204),
    ] {
        _ = try fixture.store.reduce(
            .requestServedFromMemoryCache(
                id: Network.Request.ID(id),
                response: Network.Response(
                    url: "https://example.test/\(id)",
                    status: status,
                    mimeType: "application/json",
                    bodySize: 12
                ),
                initiator: Network.Initiator(kind: "other"),
                resourceType: .fetch,
                timestamp: Double(status)
            ),
            scope: scope
        )
    }
    #expect(
        fixture.store.entries.first {
            $0.summary.url.hasSuffix("failed-cache")
        }?.summary.statusSeverity == .error
    )
    #expect(
        fixture.store.entries.first {
            $0.summary.url.hasSuffix("successful-cache")
        }?.summary.statusSeverity == .success
    )
    #expect(fixture.store.performanceCountersForTesting.entryFullRebuildCount == 2)
    #expect(
        fixture.store.performanceCountersForTesting
            .entryFullRebuildMemberVisitCount == 2
    )

    _ = try fixture.store.targetWasLost(WebInspectorTarget.ID("target-a"))
    let survivingEntry = try #require(fixture.store.entries.first)
    #expect(fixture.store.entries.count == 1)
    #expect(survivingEntry.summary.url.hasSuffix("successful-cache"))
    #expect(survivingEntry.summary.statusSeverity == .success)

    let nextPage = WebInspectorPageGeneration(rawValue: 2)
    _ = try fixture.store.reset(
        attachmentGeneration: fixture.attachmentGeneration,
        pageGeneration: nextPage
    )
    #expect(fixture.store.entries.isEmpty)
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "fresh",
            url: "https://example.test/fresh",
            timestamp: 1
        ),
        scope: fixture.scope(
            targetID: "target-b",
            pageGeneration: nextPage
        )
    )
    let freshEntry = try #require(fixture.store.entries.first)
    #expect(freshEntry.summary.statusSeverity == .neutral)
    #expect(fixture.store.performanceCountersForTesting.entryFullRebuildCount == 3)
    #expect(
        fixture.store.performanceCountersForTesting
            .entryFullRebuildMemberVisitCount == 3
    )
}
