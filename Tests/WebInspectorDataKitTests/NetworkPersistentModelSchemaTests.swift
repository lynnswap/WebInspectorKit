import Foundation
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@MainActor
@Test
func networkSchemasFetchOneEntryWithOrderedRequestsAcrossDistinctContexts() async throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope(
        targetID: "page",
        agentTargetID: "network-agent",
        domBindingEpoch: 7
    )
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "segment-1",
            url: "https://example.test/segment-1.m4s",
            initiatorKind: "parser",
            initiatorNodeID: "video",
            resourceType: .media,
            timestamp: 1
        ),
        scope: scope
    )
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "segment-2",
            url: "https://example.test/segment-2.m4s",
            initiatorKind: "parser",
            initiatorNodeID: "video",
            resourceType: .media,
            timestamp: 2
        ),
        scope: scope
    )
    let snapshot = networkModelSnapshot(fixture.store.snapshot)
    let registry = networkModelSchemaRegistry()
    let firstContext = WebInspectorModelContext(
        modelSchemaRegistry: registry,
        isolation: MainActor.shared
    )
    let secondContext = WebInspectorModelContext(
        modelSchemaRegistry: registry,
        isolation: MainActor.shared
    )
    try await applyNetworkInitial(snapshot, to: firstContext)
    try await applyNetworkInitial(snapshot, to: secondContext)

    let controller = try await WebInspectorFetchedResultsController<
        NetworkEntry,
        Never
    >(
        fetchDescriptor: WebInspectorFetchDescriptor(
            sortBy: [SortDescriptor(\.startedAt)]
        ),
        modelContext: firstContext,
        isolation: MainActor.shared
    )
    #expect(controller.snapshot.itemIDs.count == 1)
    let entryID = try #require(controller.snapshot.itemIDs.first)
    let firstEntry = try #require(firstContext.model(for: entryID))
    let secondEntry = try #require(secondContext.model(for: entryID))
    #expect(firstEntry !== secondEntry)
    #expect(firstEntry.id == secondEntry.id)
    #expect(firstEntry.requestIDs.count == 2)
    #expect(firstEntry.requestIDs == secondEntry.requestIDs)
    #expect(
        firstEntry.requestIDs.map(\.proxyID) == [
            Network.Request.ID("segment-1"),
            Network.Request.ID("segment-2"),
        ])

    let firstRequests = try await firstContext.fetch(
        WebInspectorFetchDescriptor<NetworkRequest>()
    )
    let secondRequests = try await secondContext.fetch(
        WebInspectorFetchDescriptor<NetworkRequest>()
    )
    #expect(firstRequests.map(\.id) == firstEntry.requestIDs)
    #expect(secondRequests.map(\.id) == firstEntry.requestIDs)
    #expect(
        zip(firstRequests, secondRequests).allSatisfy { first, second in
            first.id == second.id && first !== second
        }
    )

    let media = NetworkRequest.ResourceCategory.media
    let queryIDs = try await firstContext.fetchIdentifiers(
        WebInspectorFetchDescriptor<NetworkRequest>(
            predicate: #Predicate { request in
                request.resourceCategory == media
            }
        )
    )
    #expect(queryIDs == firstEntry.requestIDs)
    let query = fixture.store.snapshot.requests.map(\.query)
    #expect(
        query.allSatisfy { projection in
            projection.queryValue.initiatorNodeID?.canonicalStorage != nil
        })

    await controller.close()
    await firstContext.close()
    await secondContext.close()
}

@MainActor
@Test
func unmaterializedNetworkPatchUpdatesQueryWithoutOwnerModelWork() async throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope()
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "request",
            url: "https://example.test/request",
            resourceType: .fetch,
            timestamp: 1
        ),
        scope: scope
    )
    let context = WebInspectorModelContext(
        modelSchemaRegistry: networkModelSchemaRegistry(),
        isolation: MainActor.shared
    )
    try await applyNetworkInitial(
        networkModelSnapshot(fixture.store.snapshot),
        to: context
    )
    let requestID = NetworkRequest.ID(
        canonical: fixture.store.requests[0].id
    )
    #expect(context.registeredModel(for: requestID) == nil)

    let optionalTransaction = try fixture.store.reduce(
        .responseReceived(
            id: Network.Request.ID("request"),
            response: Network.Response(
                url: "https://example.test/request",
                status: 404,
                mimeType: "application/json"
            ),
            resourceType: .fetch,
            timestamp: 2
        ),
        scope: scope
    )
    let transaction = try #require(optionalTransaction)
    try await applyNetworkChanges(transaction, revision: 1, to: context)

    #expect(context.registeredModel(for: requestID) == nil)
    let matching = try await context.fetchIdentifiers(
        WebInspectorFetchDescriptor<NetworkRequest>(
            predicate: #Predicate { request in
                request.statusCode == 404
            }
        )
    )
    #expect(matching == [requestID])
    #expect(context.registeredModel(for: requestID) == nil)
    let request = try #require(context.model(for: requestID))
    #expect(request.status == 404)
    #expect(request.responseBody.canonicalResponseRevision == 1)
    await context.close()
}

@MainActor
@Test
func networkRequestPatchesPreserveIdentityAndInvalidateBodyByRevisionAndDelete() async throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope()
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "redirect",
            url: "https://example.test/start",
            resourceType: .document,
            timestamp: 1
        ),
        scope: scope
    )
    let context = WebInspectorModelContext(
        modelSchemaRegistry: networkModelSchemaRegistry(),
        isolation: MainActor.shared
    )
    try await applyNetworkInitial(
        networkModelSnapshot(fixture.store.snapshot),
        to: context
    )
    let id = NetworkRequest.ID(canonical: fixture.store.requests[0].id)
    let request = try #require(context.model(for: id))
    let body = request.responseBody
    body.load(Network.Body(data: "old"))
    #expect(body.phase == .loaded)

    let optionalRedirect = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "redirect",
            url: "https://example.test/final",
            resourceType: .document,
            redirectResponse: Network.Response(
                url: "https://example.test/start",
                status: 301,
                statusText: "Moved",
                mimeType: "text/html",
                headers: ["Location": "https://example.test/final"]
            ),
            timestamp: 2
        ),
        scope: scope
    )
    let redirect = try #require(optionalRedirect)
    try await applyNetworkChanges(redirect, revision: 1, to: context)
    #expect(context.registeredModel(for: id) === request)
    #expect(request.redirects.count == 1)
    #expect(request.redirects[0].response.status == 301)
    #expect(request.url == "https://example.test/final")
    #expect(request.responseBody === body)
    #expect(body.canonicalResponseRevision == 1)
    #expect(body.phase == .available)
    #expect(body.full == nil)

    let optionalResponse = try fixture.store.reduce(
        .responseReceived(
            id: Network.Request.ID("redirect"),
            response: Network.Response(
                url: "https://example.test/final",
                status: 200,
                mimeType: "video/mp4"
            ),
            resourceType: .media,
            timestamp: 3
        ),
        scope: scope
    )
    let response = try #require(optionalResponse)
    try await applyNetworkChanges(response, revision: 2, to: context)
    #expect(request.responseBody === body)
    #expect(body.canonicalResponseRevision == 2)
    #expect(request.mimeType == "video/mp4")
    #expect(request.resourceCategory == .media)

    let deletion = fixture.store.clear()
    try await applyNetworkChanges(deletion, revision: 3, to: context)
    #expect(context.registeredModel(for: id) == nil)
    #expect(request.modelContext == nil)
    #expect(body.phase == .failed(.model(.staleModel)))
    await #expect(throws: WebInspectorModelError.staleModel) {
        _ = try await body.load(isolation: MainActor.shared)
    }
    await context.close()
}

@MainActor
@Test
func canonicalWebSocketPatchesUpdateOneMaterializedRequestInPlace() async throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope()
    let rawID = Network.Request.ID("socket")
    #expect(
        try fixture.store.reduce(
            .webSocket(.created(id: rawID, url: "wss://example.test/socket")),
            scope: scope
        ) == nil)
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
        scope: scope
    )
    let context = WebInspectorModelContext(
        modelSchemaRegistry: networkModelSchemaRegistry(),
        isolation: MainActor.shared
    )
    try await applyNetworkInitial(
        networkModelSnapshot(fixture.store.snapshot),
        to: context
    )
    let id = NetworkRequest.ID(canonical: fixture.store.requests[0].id)
    let request = try #require(context.model(for: id))
    let socket = try #require(request.webSocket)
    #expect(socket.creationURL == "wss://example.test/socket")
    #expect(socket.readyState == .connecting)

    let optionalHandshake = try fixture.store.reduce(
        .webSocket(
            .handshakeResponse(
                id: rawID,
                response: Network.Response(status: 101, statusText: "Switching"),
                timestamp: 2
            )),
        scope: scope
    )
    let handshake = try #require(optionalHandshake)
    try await applyNetworkChanges(handshake, revision: 1, to: context)
    #expect(request.webSocket === socket)
    #expect(socket.readyState == .open)
    #expect(socket.handshakeResponse?.status == 101)
    #expect(socket.handshakeResponseTimestamp == 2)

    let optionalFrame = try fixture.store.reduce(
        .webSocket(
            .frameReceived(
                id: rawID,
                frame: Network.WebSocketFrame(
                    opcode: 1,
                    mask: false,
                    payloadData: "hello",
                    payloadLength: 5
                ),
                timestamp: 3
            )),
        scope: scope
    )
    let frame = try #require(optionalFrame)
    try await applyNetworkChanges(frame, revision: 2, to: context)
    #expect(request.webSocket === socket)
    #expect(socket.frames.count == 1)
    #expect(socket.frames[0].payloadData == "hello")
    #expect(request.decodedDataLength == 5)

    let optionalClosed = try fixture.store.reduce(
        .webSocket(.closed(id: rawID, timestamp: 4)),
        scope: scope
    )
    let closed = try #require(optionalClosed)
    try await applyNetworkChanges(closed, revision: 3, to: context)
    #expect(request.webSocket === socket)
    #expect(socket.readyState == .closed)
    #expect(socket.closedTimestamp == 4)
    #expect(request.state == .finished)
    await context.close()
}

private func networkModelSchemaRegistry() -> WebInspectorModelSchemaRegistry {
    WebInspectorModelSchemaRegistry(WebInspectorNetworkModelSchemas.registrations)
}

private func networkModelSnapshot(
    _ network: CanonicalNetworkSnapshot
) -> WebInspectorCanonicalModelSnapshot {
    WebInspectorCanonicalModelSnapshot(
        binding: nil,
        network: network,
        DOM: nil,
        CSS: nil,
        consoleRuntime: nil
    )
}

@MainActor
private func applyNetworkInitial(
    _ snapshot: WebInspectorCanonicalModelSnapshot,
    to context: WebInspectorModelContext
) async throws {
    let transaction = context.modelSchemaContextCore.initial(
        at: 0,
        snapshot: snapshot
    )
    let commit = try await transaction.stage(
        on: context.fetchedResultsQueryCore
    )
    #expect(context.publish(commit))
}

@MainActor
private func applyNetworkChanges(
    _ network: CanonicalNetworkTransaction,
    revision: UInt64,
    to context: WebInspectorModelContext
) async throws {
    var canonical = WebInspectorCanonicalModelTransaction()
    canonical.network = network
    let transaction = context.modelSchemaContextCore.changes(
        at: revision,
        transaction: canonical
    )
    let commit = try await transaction.stage(
        on: context.fetchedResultsQueryCore
    )
    #expect(context.publish(commit))
}
