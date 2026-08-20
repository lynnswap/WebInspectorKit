import Observation
import Synchronization
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

private actor NetworkRequestIndexClientGate {
    enum Operation: Hashable, Sendable {
        case replace
        case upsert
        case deltas
    }

    private var heldCounts: [Operation: Int] = [:]
    private var suspendedCounts: [Operation: Int] = [:]
    private var suspensionWaiters: [Operation: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaiters: [Operation: [CheckedContinuation<Void, Never>]] = [:]

    func holdNext(_ operation: Operation) {
        heldCounts[operation, default: 0] += 1
    }

    func waitUntilSuspended(_ operation: Operation) async {
        if suspendedCounts[operation, default: 0] > 0 {
            return
        }
        await withCheckedContinuation { continuation in
            suspensionWaiters[operation, default: []].append(continuation)
        }
    }

    func release(_ operation: Operation) {
        let waiters = releaseWaiters.removeValue(forKey: operation) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func suspendIfNeeded(_ operation: Operation) async {
        guard heldCounts[operation, default: 0] > 0 else {
            return
        }
        heldCounts[operation, default: 1] -= 1
        suspendedCounts[operation, default: 0] += 1
        let waiters = suspensionWaiters.removeValue(forKey: operation) ?? []
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseWaiters[operation, default: []].append(continuation)
        }
        suspendedCounts[operation, default: 1] -= 1
    }
}

private func gatedIndexClient(
    gate: NetworkRequestIndexClientGate
) -> NetworkRequestIndexClient {
    let live = NetworkRequestIndexClient.live()
    return NetworkRequestIndexClient(
        replace: { inputs, sequence in
            await gate.suspendIfNeeded(.replace)
            await live.replace(with: inputs, sequence: sequence)
        },
        upsert: { input, sequence in
            await gate.suspendIfNeeded(.upsert)
            await live.upsert(input, sequence: sequence)
        },
        deltas: { inputs, sequence in
            await gate.suspendIfNeeded(.deltas)
            return await live.deltas(for: inputs, sequence: sequence)
        },
        fullProjectionRecordVisitCount: {
            await live.fullProjectionRecordVisitCount()
        }
    )
}

@MainActor
private func makeStoreRequest(
    id: String,
    method: String = "GET",
    context: WebInspectorContext,
    timestamp: Double = 1
) -> NetworkRequest {
    let proxyID = Network.Request.ID(id)
    return NetworkRequest(
        request: Network.Request(
            id: proxyID,
            url: "https://example.test/\(id)",
            method: method
        ),
        initiator: nil,
        resourceType: .fetch,
        timestamp: timestamp,
        modelContext: context
    )
}

@MainActor
private func insertStoreRequestSynchronously(
    _ id: String,
    method: String = "GET",
    store: NetworkRequestStore,
    context: WebInspectorContext,
    timestamp: Double = 1
) throws -> NetworkRequestStore.Registration {
    let modelID = NetworkRequest.ID(Network.Request.ID(id))
    let resolution = try #require(
        store.resolveSynchronously(
            id: modelID,
            admission: .requestWillBeSent(hasRedirectResponse: false),
            create: {
                makeStoreRequest(
                    id: id,
                    method: method,
                    context: context,
                    timestamp: timestamp
                )
            }
        ))
    guard case let .inserted(registration) = resolution else {
        Issue.record("Expected a new Network request registration.")
        throw NetworkRequestStoreTestFailure()
    }
    return registration
}

@MainActor
private func insertStoreRequest(
    _ id: String,
    method: String = "GET",
    store: NetworkRequestStore,
    context: WebInspectorContext,
    timestamp: Double = 1
) async throws -> NetworkRequestStore.Registration {
    let modelID = NetworkRequest.ID(Network.Request.ID(id))
    let resolution = try #require(
        await store.resolve(
            id: modelID,
            admission: .requestWillBeSent(hasRedirectResponse: false),
            create: {
                makeStoreRequest(
                    id: id,
                    method: method,
                    context: context,
                    timestamp: timestamp
                )
            },
            isolation: MainActor.shared
        ))
    guard case let .inserted(registration) = resolution else {
        Issue.record("Expected a new Network request registration.")
        throw NetworkRequestStoreTestFailure()
    }
    return registration
}

private struct NetworkRequestStoreTestFailure: Error {}

@MainActor
@Test
func everyNetworkInsertionSourceSharesStoreOrderAndDefaultProjection() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = context.networkRequestsCollectionState
    let firstResults = context.network.fetchedResults()
    let secondResults = context.network.fetchedResults()
    let filteredResults = context.network.fetchedResults(
        for: NetworkRequestQuery(filter: .method(equals: "GET"))
    )
    let sectionedResults = context.network.fetchedResults(
        for: NetworkRequestQuery(sectionBy: .method)
    )
    var firstTransactions = WebInspectorFetchedResultsController(
        fetchedResults: firstResults
    ).transactions.makeAsyncIterator()
    var secondTransactions = WebInspectorFetchedResultsController(
        fetchedResults: secondResults
    ).transactions.makeAsyncIterator()
    let observationChanged = Mutex(false)
    withObservationTracking {
        _ = store.hasRequests
    } onChange: {
        observationChanged.withLock { $0 = true }
    }

    let requestID = Network.Request.ID("store-request")
    await context.apply(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "https://example.test/request",
                method: "GET"
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ))
    let responseID = Network.Request.ID("store-response")
    await context.apply(
        .responseReceived(
            id: responseID,
            response: Network.Response(
                url: "https://example.test/response",
                status: 200
            ),
            resourceType: .fetch,
            timestamp: 2
        ))
    let cacheID = Network.Request.ID("store-cache")
    await context.apply(
        .requestServedFromMemoryCache(
            id: cacheID,
            response: Network.Response(
                url: "https://example.test/cache",
                status: 200
            ),
            resourceType: .fetch,
            timestamp: 3
        ))
    let socketID = Network.Request.ID("store-socket")
    await context.apply(
        .webSocket(
            .created(
                id: socketID,
                url: "wss://example.test/socket"
            )))
    let seedID = context.seedNetworkRequest(
        requestID: "store-seed",
        url: "https://example.test/seed",
        method: "POST",
        resourceTypeRawValue: "Fetch",
        responseMIMEType: "application/json",
        responseStatus: 200,
        responseStatusText: "OK",
        timestamp: 4
    )

    let expectedIDs =
        [requestID, responseID, cacheID, socketID].map(NetworkRequest.ID.init)
        + [seedID]
    var firstDelivered: [WebInspectorFetchedResultsTransaction<NetworkRequest>] = []
    var secondDelivered: [WebInspectorFetchedResultsTransaction<NetworkRequest>] = []
    for _ in expectedIDs {
        firstDelivered.append(try #require(await firstTransactions.next()))
        secondDelivered.append(try #require(await secondTransactions.next()))
    }

    #expect(store.requestCount == expectedIDs.count)
    #expect(store.hasRequests)
    #expect(observationChanged.withLock { $0 })
    #expect(firstResults.items.map(\.id) == expectedIDs)
    #expect(secondResults.items.map(\.id) == expectedIDs)
    #expect(filteredResults.items.map(\.id) == Array(expectedIDs.dropLast()))
    #expect(sectionedResults.sections.map(\.id.rawValue) == ["GET", "POST"])
    #expect(firstDelivered.map { $0.itemChanges.count } == [1, 1, 1, 1, 1])
    #expect(secondDelivered.map { $0.itemChanges.count } == [1, 1, 1, 1, 1])
    #expect(firstDelivered[0].newSnapshot.itemIDs == [expectedIDs[0]])
    #expect(firstDelivered.last?.newSnapshot.itemIDs == expectedIDs)
}

@MainActor
@Test
func overlappingIndexCommitsBatchPendingUpdatesPerRegisteredResult() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let gate = NetworkRequestIndexClientGate()
    let client = gatedIndexClient(gate: gate)
    let store = NetworkRequestStore(indexFactory: { client })
    let first = try insertStoreRequestSynchronously(
        "overlap-a",
        store: store,
        context: context
    )
    let firstResults = store.makeFetchedResults(
        query: NetworkRequestQuery(filter: .all([])),
        modelContext: context
    )
    var firstTransactions = WebInspectorFetchedResultsController(
        fetchedResults: firstResults
    ).transactions.makeAsyncIterator()

    await gate.holdNext(.deltas)
    first.request.applyDataReceived(dataLength: 1, encodedDataLength: 1, timestamp: 2)
    let firstCommit = Task { @MainActor in
        await store.commitUpdate(first, isolation: MainActor.shared)
    }
    await gate.waitUntilSuspended(.deltas)

    let laterResults = store.makeFetchedResults(
        query: NetworkRequestQuery(filter: .all([])),
        modelContext: context
    )
    var laterTransactions = WebInspectorFetchedResultsController(
        fetchedResults: laterResults
    ).transactions.makeAsyncIterator()
    let second = try await insertStoreRequest(
        "overlap-b",
        store: store,
        context: context,
        timestamp: 3
    )

    let firstWinning = try #require(await firstTransactions.next())
    #expect(
        firstWinning.itemChanges == [
            .insert(
                itemID: second.request.id,
                indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 1)
            ),
            .update(
                itemID: first.request.id,
                indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)
            ),
        ])
    let laterWinning = try #require(await laterTransactions.next())
    #expect(
        laterWinning.itemChanges == [
            .insert(
                itemID: second.request.id,
                indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 1)
            )
        ])

    await gate.release(.deltas)
    await firstCommit.value
    let third = try await insertStoreRequest(
        "overlap-c",
        store: store,
        context: context,
        timestamp: 4
    )
    #expect(
        try #require(await firstTransactions.next()).itemChanges == [
            .insert(
                itemID: third.request.id,
                indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 2)
            )
        ])
    #expect(
        try #require(await laterTransactions.next()).itemChanges == [
            .insert(
                itemID: third.request.id,
                indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 2)
            )
        ])
}

@MainActor
@Test
func queryResetDropsSupersededPendingContentUpdates() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let gate = NetworkRequestIndexClientGate()
    let client = gatedIndexClient(gate: gate)
    let store = NetworkRequestStore(indexFactory: { client })
    let first = try insertStoreRequestSynchronously("query-reset-a", store: store, context: context)
    let second = try insertStoreRequestSynchronously(
        "query-reset-b",
        store: store,
        context: context,
        timestamp: 2
    )
    let results = store.makeFetchedResults(
        query: NetworkRequestQuery(filter: .all([])),
        modelContext: context
    )
    var transactions = WebInspectorFetchedResultsController(
        fetchedResults: results
    ).transactions.makeAsyncIterator()

    await gate.holdNext(.deltas)
    first.request.applyDataReceived(dataLength: 1, encodedDataLength: 1, timestamp: 3)
    let firstCommit = Task { @MainActor in
        await store.commitUpdate(first, isolation: MainActor.shared)
    }
    await gate.waitUntilSuspended(.deltas)

    store.updateQuery(
        NetworkRequestQuery(filter: .all([]), fetchLimit: .max),
        for: results
    )
    let reset = try #require(await transactions.next())
    #expect(reset.isReset)

    second.request.applyDataReceived(dataLength: 2, encodedDataLength: 2, timestamp: 4)
    await store.commitUpdate(second, isolation: MainActor.shared)
    #expect(
        try #require(await transactions.next()).itemChanges == [
            .update(
                itemID: second.request.id,
                indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 1)
            )
        ])

    await gate.release(.deltas)
    await firstCommit.value
}

@MainActor
@Test
func synchronousSeedSupersedesBlockedIndexedContentWithOneReset() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let gate = NetworkRequestIndexClientGate()
    let client = gatedIndexClient(gate: gate)
    let store = NetworkRequestStore(indexFactory: { client })
    let first = try insertStoreRequestSynchronously("sync-seed-a", store: store, context: context)
    let results = store.makeFetchedResults(
        query: NetworkRequestQuery(filter: .all([])),
        modelContext: context
    )
    var transactions = WebInspectorFetchedResultsController(
        fetchedResults: results
    ).transactions.makeAsyncIterator()

    await gate.holdNext(.deltas)
    first.request.applyDataReceived(dataLength: 1, encodedDataLength: 1, timestamp: 2)
    let blockedCommit = Task { @MainActor in
        await store.commitUpdate(first, isolation: MainActor.shared)
    }
    await gate.waitUntilSuspended(.deltas)

    let second = try insertStoreRequestSynchronously(
        "sync-seed-b",
        store: store,
        context: context,
        timestamp: 3
    )
    let reset = try #require(await transactions.next())
    #expect(reset.isReset)
    #expect(reset.newSnapshot.itemIDs == [first.request.id, second.request.id])

    await gate.release(.deltas)
    await blockedCommit.value
    let third = try await insertStoreRequest(
        "sync-seed-c",
        store: store,
        context: context,
        timestamp: 4
    )
    #expect(
        try #require(await transactions.next()).itemChanges == [
            .insert(
                itemID: third.request.id,
                indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 2)
            )
        ])
}

@MainActor
@Test
func resetDuringBlockedInsertionRejectsTheStaleResolutionAndIndex() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let gate = NetworkRequestIndexClientGate()
    let firstClient = gatedIndexClient(gate: gate)
    let clients = Mutex([firstClient, NetworkRequestIndexClient.live()])
    let store = NetworkRequestStore(indexFactory: {
        clients.withLock { clients in
            clients.removeFirst()
        }
    })
    let results = store.makeFetchedResults(
        query: NetworkRequestQuery(filter: .all([])),
        modelContext: context
    )
    var transactions = WebInspectorFetchedResultsController(
        fetchedResults: results
    ).transactions.makeAsyncIterator()

    await gate.holdNext(.upsert)
    let modelID = NetworkRequest.ID(Network.Request.ID("blocked-reset"))
    let insertion = Task { @MainActor in
        let resolution = await store.resolve(
            id: modelID,
            admission: .requestWillBeSent(hasRedirectResponse: false),
            create: {
                makeStoreRequest(id: "blocked-reset", context: context)
            },
            isolation: MainActor.shared
        )
        return resolution == nil
    }
    await gate.waitUntilSuspended(.upsert)
    #expect(store.requestCount == 1)
    store.reset(for: .userClear)
    let reset = try #require(await transactions.next())
    #expect(reset.isReset)
    #expect(reset.newSnapshot.itemIDs.isEmpty)

    await gate.release(.upsert)
    #expect(await insertion.value)
    #expect(store.requestCount == 0)
    #expect(store.isTombstoned(modelID))
    #expect(store.registration(for: modelID) == nil)
}

@MainActor
@Test
func userClearAndAttachmentResetApplyDistinctSameIDAdmissionPolicies() throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = NetworkRequestStore()
    let first = try insertStoreRequestSynchronously(
        "reset-policy",
        store: store,
        context: context
    )
    let modelID = first.request.id

    store.reset(for: .userClear)
    #expect(store.isCurrent(first) == false)
    #expect(store.isTombstoned(modelID))
    #expect(
        store.resolveSynchronously(
            id: modelID,
            admission: .ordinary,
            create: {
                makeStoreRequest(id: "reset-policy", context: context, timestamp: 2)
            }
        ) == nil)
    #expect(
        store.resolveSynchronously(
            id: modelID,
            admission: .requestWillBeSent(hasRedirectResponse: true),
            create: {
                makeStoreRequest(id: "reset-policy", context: context, timestamp: 3)
            }
        ) == nil)
    let reopened = try #require(
        store.resolveSynchronously(
            id: modelID,
            admission: .requestWillBeSent(hasRedirectResponse: false),
            create: {
                makeStoreRequest(id: "reset-policy", context: context, timestamp: 4)
            }
        ))
    let reopenedRegistration = reopened.registration
    #expect(reopenedRegistration.request !== first.request)
    #expect(reopenedRegistration.orderIndex == 0)

    store.reset(for: .userClear)
    let webSocketReopened = try #require(
        store.resolveSynchronously(
            id: modelID,
            admission: .webSocketCreated,
            create: {
                makeStoreRequest(id: "reset-policy", context: context, timestamp: 5)
            }
        ))
    #expect(webSocketReopened.registration.orderIndex == 0)

    store.reset(for: .userClear)
    store.reset(for: .newAttachment)
    let attachmentResponse = try #require(
        store.resolveSynchronously(
            id: modelID,
            admission: .ordinary,
            create: {
                makeStoreRequest(id: "reset-policy", context: context, timestamp: 6)
            }
        ))
    #expect(attachmentResponse.registration.orderIndex == 0)
    #expect(store.isTombstoned(modelID) == false)
}

@MainActor
@Test
func indexUsesRegistrationOrderAndBatchesShiftedStableUpdates() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = NetworkRequestStore()
    let first = try insertStoreRequestSynchronously("index-order-a", store: store, context: context)
    let second = try insertStoreRequestSynchronously(
        "index-order-b",
        store: store,
        context: context,
        timestamp: 2
    )
    let third = try insertStoreRequestSynchronously(
        "index-order-c",
        store: store,
        context: context,
        timestamp: 3
    )
    let inputs = [first, second, third].map(NetworkRequestRecordInput.init)
    let index = NetworkRequestIndex()
    await index.upsert(inputs[2], sequence: 1)
    await index.upsert(inputs[0], sequence: 2)
    await index.upsert(inputs[1], sequence: 3)
    let orderDelta = try #require(
        await index.delta(
            plan: NetworkRequestQueryPlan(query: NetworkRequestQuery(filter: .all([]))),
            sectionBy: nil,
            oldSnapshot: WebInspectorFetchedResultsSnapshot(),
            changedID: nil
        ))
    #expect(orderDelta.snapshot.itemIDs == [first.request.id, second.request.id, third.request.id])

    var firstInput = inputs[0]
    var secondInput = inputs[1]
    firstInput.statusCode = 500
    secondInput.statusCode = 500
    let transitionIndex = NetworkRequestIndex()
    await transitionIndex.replace(with: [firstInput, secondInput], sequence: 1)
    firstInput.statusCode = 200
    secondInput.statusText = "Updated"
    await transitionIndex.upsert(firstInput, sequence: 2)
    await transitionIndex.upsert(secondInput, sequence: 3)
    let transitionInputs = [
        NetworkResultProjectionInput(
            plan: NetworkRequestQueryPlan(
                query: NetworkRequestQuery(filter: .statusCode(atLeast: 400))
            ),
            sectionBy: nil,
            oldSnapshot: WebInspectorFetchedResultsSnapshot(
                itemIDs: [first.request.id, second.request.id]
            ),
            changedIDs: [first.request.id, second.request.id]
        )
    ]
    let transitionBatch = try #require(
        await transitionIndex.deltas(for: transitionInputs, sequence: 3)
    )
    let possibleTransition = try #require(transitionBatch.first)
    let transition = try #require(possibleTransition)
    #expect(
        transition.transaction.itemChanges == [
            .delete(
                itemID: first.request.id,
                indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)
            ),
            .update(
                itemID: second.request.id,
                indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)
            ),
        ])
}

@MainActor
@Test
func defaultStoreProjectionKeepsTenThousandChangesOffTheQueryIndex() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = NetworkRequestStore()
    let results = store.makeFetchedResults(query: NetworkRequestQuery(), modelContext: context)
    let observationChanged = Mutex(false)
    withObservationTracking {
        _ = store.hasRequests
    } onChange: {
        observationChanged.withLock { $0 = true }
    }

    for index in 0..<10_000 {
        _ = try insertStoreRequestSynchronously(
            "ten-thousand-\(index)",
            store: store,
            context: context,
            timestamp: Double(index)
        )
    }
    for index in [0, 5_000, 9_999] {
        let registration = store.registrations[index]
        registration.request.applyDataReceived(
            dataLength: index + 1,
            encodedDataLength: index + 1,
            timestamp: Double(10_000 + index)
        )
        store.commitUpdateSynchronously(registration)
    }

    #expect(store.requestCount == 10_000)
    #expect(observationChanged.withLock { $0 })
    #expect(results.items.count == 10_000)
    #expect(results.sections.count == 1)
    #expect(results.sections[0].items.count == 10_000)
    #expect(results.items[0].decodedDataLength == 1)
    #expect(results.items[5_000].decodedDataLength == 5_001)
    #expect(results.items[9_999].decodedDataLength == 10_000)
    #expect(results.networkFullMembershipVisitCountForTesting == 0)
    #expect(await store.fullProjectionRecordVisitCount(isolation: MainActor.shared) == 0)
}
