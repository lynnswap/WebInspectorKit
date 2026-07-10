import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@MainActor
@Test
func networkRequestStoreOwnsIdentityOrderAndClearEpoch() async throws {
    let context = WebInspectorModelContext.preview()
    let store = NetworkRequestStore()
    let firstProxyID = Network.Request.ID("first")
    let secondProxyID = Network.Request.ID("second")

    await store.apply(
        .requestWillBeSent(
            id: firstProxyID,
            request: Network.Request(
                id: firstProxyID,
                url: "https://example.com/first",
                method: "GET"
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        modelContext: context
    )
    let first = try #require(store.request(forProxyID: firstProxyID))

    await store.apply(
        .responseReceived(
            id: firstProxyID,
            response: Network.Response(
                url: "https://example.com/first",
                status: 200
            ),
            resourceType: .fetch,
            timestamp: 2
        ),
        modelContext: context
    )
    await store.apply(
        .requestWillBeSent(
            id: secondProxyID,
            request: Network.Request(
                id: secondProxyID,
                url: "https://example.com/second",
                method: "POST"
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 3
        ),
        modelContext: context
    )

    #expect(store.request(forProxyID: firstProxyID) === first)
    #expect(first.statusCode == 200)
    #expect(store.collectionState.requestCount == 2)

    await store.clear()

    #expect(store.request(forProxyID: firstProxyID) == nil)
    #expect(store.request(forProxyID: secondProxyID) == nil)
    #expect(store.collectionState.requestCount == 0)
    #expect(store.collectionState.topologyRevision == 3)
}
