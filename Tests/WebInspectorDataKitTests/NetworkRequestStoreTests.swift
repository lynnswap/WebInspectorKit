import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@MainActor
@Test
func networkRequestStoreOwnsIdentityOrderAndClearEpoch() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = NetworkRequestStore()
    let firstProxyID = Network.Request.ID("first")
    let secondProxyID = Network.Request.ID("second")

    await store.apply(
        .requestWillBeSent(
            id: firstProxyID,
            request: Network.Request(id: firstProxyID, url: "https://example.com/first", method: "GET"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        modelContext: context,
        isolation: MainActor.shared
    )
    let registeredFirst = store.request(forProxyID: firstProxyID, isolation: MainActor.shared)
    let first = try #require(registeredFirst)

    await store.apply(
        .responseReceived(
            id: firstProxyID,
            response: Network.Response(url: "https://example.com/first", status: 200),
            resourceType: .fetch,
            timestamp: 2
        ),
        modelContext: context,
        isolation: MainActor.shared
    )
    await store.apply(
        .requestWillBeSent(
            id: secondProxyID,
            request: Network.Request(id: secondProxyID, url: "https://example.com/second", method: "POST"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 3
        ),
        modelContext: context,
        isolation: MainActor.shared
    )

    let updatedFirst = store.request(forProxyID: firstProxyID, isolation: MainActor.shared)
    #expect(updatedFirst === first)
    #expect(first.statusCode == 200)
    #expect(store.collectionState.requestCount == 2)

    store.clear(isolation: MainActor.shared)

    let clearedFirst = store.request(forProxyID: firstProxyID, isolation: MainActor.shared)
    let clearedSecond = store.request(forProxyID: secondProxyID, isolation: MainActor.shared)
    #expect(clearedFirst == nil)
    #expect(clearedSecond == nil)
    #expect(store.collectionState.requestCount == 0)
    #expect(store.collectionState.topologyRevision == 3)
}

@MainActor
@Test
func networkRequestStorePropertyMutationAtTenThousandRecordsUsesOneCompactProjection() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = NetworkRequestStore()
    let recordCount = 10_000

    for ordinal in 0..<recordCount {
        let id = Network.Request.ID("request-\(ordinal)")
        await store.apply(
            .requestWillBeSent(
                id: id,
                request: Network.Request(
                    id: id,
                    url: "https://example.com/\(ordinal)",
                    method: "GET"
                ),
                resourceType: .fetch,
                redirectResponse: nil,
                timestamp: Double(ordinal)
            ),
            modelContext: context,
            isolation: MainActor.shared
        )
    }

    let insertCounters = store.performanceCountersForTesting
    #expect(insertCounters.incrementalRecordProjectionCount == recordCount)
    #expect(insertCounters.fullRecordProjectionCount == 0)
    #expect(insertCounters.fullModelProjectionCount == 0)
    #expect(insertCounters.resultIdentityLookupCount == 0)

    let results = WebInspectorFetchedResults<NetworkRequest>(
        fetchDescriptor: WebInspectorFetchDescriptor(),
        modelContext: context
    )
    store.register(results, modelContext: context, isolation: MainActor.shared)
    #expect(results.items.count == recordCount)
    store.resetPerformanceCountersForTesting(isolation: MainActor.shared)

    let lastID = Network.Request.ID("request-\(recordCount - 1)")
    await store.apply(
        .dataReceived(
            id: lastID,
            dataLength: 1,
            encodedDataLength: 1,
            timestamp: Double(recordCount)
        ),
        modelContext: context,
        isolation: MainActor.shared
    )

    let counters = store.performanceCountersForTesting
    #expect(counters.incrementalRecordProjectionCount == 1)
    #expect(counters.fullRecordProjectionCount == 0)
    #expect(counters.fullModelProjectionCount == 0)
    #expect(counters.resultIdentityLookupCount == 0)
    #expect(results.items.count == recordCount)
    #expect(results.items.last?.encodedDataLength == 1)
}
