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
    #expect(store.collectionState.topologyRevision == 1)
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
    #expect(store.collectionState.sourceEpoch == 1)
    store.validateLiveGroupLookupForTesting()
}

@MainActor
@Test
func networkRequestStoreMaintainsSameGroupMembersAndRegroupsReusedIdentity() async throws {
    let context = WebInspectorModelContext.preview()
    let store = NetworkRequestStore()
    let sharedNodeID = DOM.Node.ID("shared-node")
    let firstProxyID = Network.Request.ID("group-first")
    let secondProxyID = Network.Request.ID("group-second")

    await store.apply(
        .requestWillBeSent(
            id: firstProxyID,
            request: Network.Request(
                id: firstProxyID,
                url: "https://example.com/first",
                method: "GET"
            ),
            initiator: Network.Initiator(kind: "other", nodeID: sharedNodeID),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        modelContext: context
    )
    await store.apply(
        .responseReceived(
            id: firstProxyID,
            response: Network.Response(
                url: "https://example.com/first",
                status: 200,
                mimeType: "application/json"
            ),
            resourceType: .fetch,
            timestamp: 1.25
        ),
        modelContext: context
    )
    #expect(store.collectionState.topologyRevision == 1)

    await store.apply(
        .requestWillBeSent(
            id: secondProxyID,
            request: Network.Request(
                id: secondProxyID,
                url: "https://example.com/second",
                method: "GET"
            ),
            initiator: Network.Initiator(kind: "other", nodeID: sharedNodeID),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 2
        ),
        modelContext: context
    )

    let first = try #require(store.request(forProxyID: firstProxyID))
    let second = try #require(store.request(forProxyID: secondProxyID))
    let sharedGroupID = try #require(store.groupID(containing: first.id))
    #expect(store.groupID(containing: second.id) == sharedGroupID)
    #expect(store.requestIDs(inGroup: sharedGroupID) == [first.id, second.id])
    #expect(store.requestGroup(id: sharedGroupID)?.items == [first, second])
    #expect(store.collectionState.topologyRevision == 2)
    store.validateLiveGroupLookupForTesting()
    let filteredOutResults = try await store.results(
        matching: NetworkQuery(
            search: "not-present-in-either-member",
            section: .initiatorNode
        ),
        modelContext: context
    )
    #expect(filteredOutResults.items.isEmpty)
    #expect(store.requestIDs(inGroup: sharedGroupID) == [first.id, second.id])

    await store.apply(
        .loadingFinished(
            id: firstProxyID,
            timestamp: 2.5,
            sourceMapURL: nil,
            metrics: nil
        ),
        modelContext: context
    )
    let results = try await store.results(
        matching: NetworkQuery(
            sort: .requestTimeAscending,
            section: .initiatorNode
        ),
        modelContext: context
    )
    #expect(results.snapshot.sectionIDs == [sharedGroupID])
    #expect(results.snapshot.itemIDs == [first.id, second.id])
    var updates = results.updates().makeAsyncIterator()
    guard case .initial? = await updates.next() else {
        Issue.record("Expected grouped Store results to publish an initial state.")
        return
    }
    let topologyBeforeRegroup = store.collectionState.topologyRevision
    let replacementNodeID = DOM.Node.ID("replacement-node")
    await store.apply(
        .requestWillBeSent(
            id: firstProxyID,
            request: Network.Request(
                id: firstProxyID,
                url: "https://example.com/reused",
                method: "POST"
            ),
            initiator: Network.Initiator(kind: "other", nodeID: replacementNodeID),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 3
        ),
        modelContext: context
    )

    let replacementGroupID = try #require(store.groupID(containing: first.id))
    #expect(replacementGroupID != sharedGroupID)
    #expect(store.requestIDs(inGroup: sharedGroupID) == [second.id])
    #expect(store.requestIDs(inGroup: replacementGroupID) == [first.id])
    #expect(store.request(forProxyID: firstProxyID) === first)
    #expect(store.collectionState.requestCount == 2)
    #expect(store.collectionState.topologyRevision == topologyBeforeRegroup + 1)
    #expect(results.snapshot.sectionIDs == [sharedGroupID, replacementGroupID])
    #expect(results.snapshot.itemIDs == [second.id, first.id])
    guard case let .transaction(_, regroupTransaction, _)? = await updates.next() else {
        Issue.record("Expected reused request regrouping to publish a transaction.")
        return
    }
    #expect(regroupTransaction.isReset == false)
    #expect(regroupTransaction.oldSnapshot.sectionIDs == [sharedGroupID])
    #expect(regroupTransaction.newSnapshot.sectionIDs == [sharedGroupID, replacementGroupID])
    store.validateLiveGroupLookupForTesting()

    let sourceEpochBeforeClear = store.collectionState.sourceEpoch
    let topologyBeforeClear = store.collectionState.topologyRevision
    await store.clear()
    #expect(store.groupID(containing: first.id) == nil)
    #expect(store.requestIDs(inGroup: sharedGroupID) == nil)
    #expect(store.requestIDs(inGroup: replacementGroupID) == nil)
    #expect(store.collectionState.sourceEpoch == sourceEpochBeforeClear + 1)
    #expect(store.collectionState.topologyRevision == topologyBeforeClear + 1)
    store.validateLiveGroupLookupForTesting()

    let emptyEpoch = store.collectionState.sourceEpoch
    let emptyTopology = store.collectionState.topologyRevision
    await store.clear()
    #expect(store.collectionState.sourceEpoch == emptyEpoch + 1)
    #expect(store.collectionState.topologyRevision == emptyTopology + 1)
}

@MainActor
@Test
func networkRequestStoreUsesSharedChronologyForOutOfOrderInsertAndSameGroupReuse() async throws {
    let context = WebInspectorModelContext.preview()
    let store = NetworkRequestStore()
    let nodeID = DOM.Node.ID("ordered-node")
    let laterProxyID = Network.Request.ID("ordered-later")
    let earlierProxyID = Network.Request.ID("ordered-earlier")

    await store.apply(
        .requestWillBeSent(
            id: laterProxyID,
            request: Network.Request(
                id: laterProxyID,
                url: "https://example.com/later",
                method: "GET"
            ),
            initiator: Network.Initiator(kind: "other", nodeID: nodeID),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 3
        ),
        modelContext: context
    )
    await store.apply(
        .requestWillBeSent(
            id: earlierProxyID,
            request: Network.Request(
                id: earlierProxyID,
                url: "https://example.com/earlier",
                method: "GET"
            ),
            initiator: Network.Initiator(kind: "other", nodeID: nodeID),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        modelContext: context
    )

    let later = try #require(store.request(forProxyID: laterProxyID))
    let earlier = try #require(store.request(forProxyID: earlierProxyID))
    let groupID = try #require(store.groupID(containing: later.id))
    #expect(store.requestIDs(inGroup: groupID) == [earlier.id, later.id])
    let topologyBeforeReuse = store.collectionState.topologyRevision

    await store.apply(
        .loadingFinished(
            id: earlierProxyID,
            timestamp: 1.5,
            sourceMapURL: nil,
            metrics: nil
        ),
        modelContext: context
    )
    await store.apply(
        .requestWillBeSent(
            id: earlierProxyID,
            request: Network.Request(
                id: earlierProxyID,
                url: "https://example.com/reused-later",
                method: "GET"
            ),
            initiator: Network.Initiator(kind: "other", nodeID: nodeID),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 4
        ),
        modelContext: context
    )

    #expect(store.request(forProxyID: earlierProxyID) === earlier)
    #expect(store.requestIDs(inGroup: groupID) == [later.id, earlier.id])
    #expect(store.collectionState.topologyRevision == topologyBeforeReuse + 1)
    store.validateLiveGroupLookupForTesting()
}

@MainActor
@Test
func networkRequestStoreProductionIndexWorkUpdatesLiveGroupLookup() async throws {
    let context = WebInspectorModelContext.preview()
    let store = NetworkRequestStore()
    let proxyID = Network.Request.ID("prepared-group")
    let nodeID = DOM.Node.ID("prepared-node")
    let work = try #require(store.prepareModelEvent(
        .requestWillBeSent(
            id: proxyID,
            request: Network.Request(
                id: proxyID,
                url: "https://example.com/prepared",
                method: "GET"
            ),
            initiator: Network.Initiator(kind: "other", nodeID: nodeID),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        modelContext: context
    ))
    let result = await work.run()
    let acknowledgement = store.commit(result)
    await acknowledgement?.run()

    let request = try #require(store.request(forProxyID: proxyID))
    let groupID = try #require(store.groupID(containing: request.id))
    #expect(store.requestIDs(inGroup: groupID) == [request.id])
    #expect(store.requestGroup(id: groupID)?.items == [request])
    store.validateLiveGroupLookupForTesting()
}

@MainActor
@Test
func networkModelContextForwardsUnfilteredRequestGroupLookup() throws {
    let context = WebInspectorModelContext.preview()
    let nodeID = DOM.Node.ID("context-node")
    let requestID = context.seedNetworkRequest(
        requestID: "context-group",
        url: "https://example.com/context",
        resourceTypeRawValue: "Fetch",
        responseMIMEType: "application/json",
        responseStatus: 200,
        responseStatusText: "OK",
        initiator: Network.Initiator(kind: "other", nodeID: nodeID),
        timestamp: 1
    )
    let request = try #require(try context.networkRequest(id: requestID))
    let groupID = try #require(context.networkRequestGroupID(containing: requestID))

    #expect(context.networkRequestIDs(inGroup: groupID) == [requestID])
    #expect(context.networkRequestGroup(id: groupID)?.items == [request])
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
