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
            initiator: Network.Initiator(kind: "other"),
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
            initiator: Network.Initiator(kind: "other"),
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

@MainActor
@Test
func networkRequestStorePreservesInitialInitiatorAcrossRedirects() async throws {
    let context = WebInspectorModelContext.preview()
    let store = NetworkRequestStore()
    let proxyID = Network.Request.ID("redirect")
    let initialNodeID = DOM.Node.ID("17")

    await store.apply(
        .requestWillBeSent(
            id: proxyID,
            request: Network.Request(
                id: proxyID,
                url: "https://example.com/start",
                method: "GET"
            ),
            initiator: Network.Initiator(kind: "other", nodeID: initialNodeID),
            resourceType: .document,
            redirectResponse: nil,
            timestamp: 1
        ),
        modelContext: context
    )
    await store.apply(
        .requestWillBeSent(
            id: proxyID,
            request: Network.Request(
                id: proxyID,
                url: "https://example.com/final",
                method: "GET"
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
        modelContext: context
    )

    let request = try #require(store.request(forProxyID: proxyID))
    #expect(request.initiator?.nodeID == initialNodeID)
    #expect(request.redirects.count == 1)
}

@MainActor
@Test
func networkRequestStoreKeepsMemoryCacheInitiator() async throws {
    let context = WebInspectorModelContext.preview()
    let store = NetworkRequestStore()
    let proxyID = Network.Request.ID("memory-cache")
    let nodeID = DOM.Node.ID("23")

    await store.apply(
        .requestServedFromMemoryCache(
            id: proxyID,
            response: Network.Response(
                url: "https://example.com/poster.jpg",
                status: 200,
                mimeType: "image/jpeg"
            ),
            initiator: Network.Initiator(kind: "other", nodeID: nodeID),
            resourceType: .image,
            timestamp: 1
        ),
        modelContext: context
    )

    let request = try #require(store.request(forProxyID: proxyID))
    #expect(request.initiator?.nodeID == nodeID)
}
