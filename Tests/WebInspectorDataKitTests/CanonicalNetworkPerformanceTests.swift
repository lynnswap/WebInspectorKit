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
    #expect(counters.entryQueryRebuildCount == 0)
    #expect(counters.entryIncrementalUpdateCount == 999)
}

@Test
func canonicalNetworkTransferAndFrameUpdatesDoNotScanGroupQueries() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope(domBindingEpoch: 1)
    for index in 0..<256 {
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
            id: Network.Request.ID("request-128"),
            dataLength: 4_096,
            encodedDataLength: 2_048,
            timestamp: 300
        ),
        scope: scope
    )
    var counters = fixture.store.performanceCountersForTesting
    #expect(counters.entryFullRebuildCount == 0)
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
    #expect(counters.entryQueryRebuildCount == 0)
    #expect(counters.entryIncrementalUpdateCount == 1)
}

@Test
func canonicalNetworkResponseReplacesOnlyItsOrderedMemberSearchText() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope(domBindingEpoch: 1)
    for index in 0..<256 {
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
                id: Network.Request.ID("request-128"),
                response: Network.Response(
                    url: "https://cdn.example.test/segment-128.ts",
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
        if index == 128 {
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
    #expect(counters.entryQueryRebuildCount == 0)
    #expect(counters.entryIncrementalUpdateCount == 1)
}
