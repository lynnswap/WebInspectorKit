import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@MainActor
@Test
func networkQueryNormalizesSearchAndProvidesClosedDefaults() {
    var query = NetworkQuery(search: "  app.js\n")

    #expect(query.search == "app.js")
    #expect(query.resourceCategories.isEmpty)
    #expect(query.methods.isEmpty)
    #expect(query.sort == .requestTimeDescending)
    #expect(query.section == nil)
    #expect(query.offset == 0)
    #expect(query.limit == nil)

    query.search = " \n\t "
    #expect(query.search == nil)
}

@MainActor
@Test
func networkConcreteQueryUsesInsertionOrderToBreakEqualRequestTimes() async throws {
    let context = WebInspectorModelContext.preview()
    var first = makeIndexedNetworkRecord(
        id: "tie-first",
        url: "https://example.com/first",
        method: "GET",
        timestamp: 1,
        context: context
    )
    var second = makeIndexedNetworkRecord(
        id: "tie-second",
        url: "https://example.com/second",
        method: "GET",
        timestamp: 1,
        context: context
    )
    first.input.orderIndex = 0
    second.input.orderIndex = 1
    let index = NetworkRequestIndex()
    _ = await index.replace(with: [first.input, second.input], sequence: 1)
    let lifetime = WebInspectorQueryRegistrationLifetime()
    let registrationID = WebInspectorQueryRegistrationID(rawValue: 0)
    let ascendingGeneration = lifetime.nextGeneration()
    let ascending = try await index.register(
        id: registrationID,
        generation: ascendingGeneration,
        query: NetworkQuery(sort: .requestTimeAscending),
        lifetime: lifetime,
        minimumSequence: 1
    )
    #expect(ascending.snapshot.itemIDs == [first.id, second.id])

    let descendingGeneration = lifetime.nextGeneration()
    _ = try await index.prepareReplacement(
        id: registrationID,
        generation: descendingGeneration,
        query: NetworkQuery(sort: .requestTimeDescending),
        minimumSequence: 1
    )
    let descending = try #require(await index.commitReplacement(
        id: registrationID,
        generation: descendingGeneration
    ))
    #expect(descending.snapshot.itemIDs == [second.id, first.id])
}

@MainActor
@Test
func networkConcreteQueryRegistrationIncludesMutationAppliedWhileWaitingForInitialState() async throws {
    let context = WebInspectorModelContext.preview()
    let first = makeIndexedNetworkRecord(
        id: "initial-first",
        url: "https://example.com/first",
        method: "GET",
        timestamp: 1,
        context: context
    )
    let second = makeIndexedNetworkRecord(
        id: "initial-second",
        url: "https://example.com/second",
        method: "POST",
        timestamp: 2,
        context: context
    )
    let index = NetworkRequestIndex()
    let secondMutation = Task {
        await index.upsert(second.input, sequence: 2)
    }
    try await waitForConcreteQueryCondition {
        await index.isMutationPendingForTesting(sequence: 2)
    }

    let lifetime = WebInspectorQueryRegistrationLifetime()
    let generation = lifetime.nextGeneration()
    let registrationID = WebInspectorQueryRegistrationID(rawValue: 1)
    let registration = Task {
        try await index.register(
            id: registrationID,
            generation: generation,
            query: NetworkQuery(sort: .requestTimeAscending),
            lifetime: lifetime,
            minimumSequence: 2
        )
    }
    try await waitForConcreteQueryCondition {
        await index.isSequenceWaiterPendingForTesting(minimumSequence: 2)
    }

    _ = await index.upsert(first.input, sequence: 1)
    _ = await secondMutation.value
    let projection = try await registration.value

    #expect(projection.sequence == 2)
    #expect(projection.snapshot.itemIDs == [first.id, second.id])
    #expect(await index.queryRegistrationCountForTesting() == 1)
}

@Test
func cancelledNetworkConcreteQueryRegistrationStopsWaitingWithoutTheMissingMutation() async throws {
    var index: NetworkRequestIndex? = NetworkRequestIndex()
    weak let weakIndex = index
    let lifetime = WebInspectorQueryRegistrationLifetime()
    let generation = lifetime.nextGeneration()
    let registration = Task { [index] in
        guard let index else {
            throw CancellationError()
        }
        return try await index.register(
            id: WebInspectorQueryRegistrationID(rawValue: 11),
            generation: generation,
            query: NetworkQuery(),
            lifetime: lifetime,
            minimumSequence: 1
        )
    }
    try await waitForConcreteQueryCondition { [weak index] in
        guard let index else {
            return false
        }
        return await index.isSequenceWaiterPendingForTesting(minimumSequence: 1)
    }

    registration.cancel()

    await #expect(throws: CancellationError.self) {
        try await registration.value
    }
    if let index {
        #expect(await index.isSequenceWaiterPendingForTesting(minimumSequence: 1) == false)
        #expect(await index.queryRegistrationCountForTesting() == 0)
    }
    index = nil
    #expect(weakIndex == nil)
}

@MainActor
@Test
func networkConcreteQueryReplacementAbsorbsMutationBetweenPrepareAndCommit() async throws {
    let context = WebInspectorModelContext.preview()
    let first = makeIndexedNetworkRecord(
        id: "replacement-first",
        url: "https://example.com/first",
        method: "GET",
        timestamp: 1,
        context: context
    )
    let second = makeIndexedNetworkRecord(
        id: "replacement-second",
        url: "https://example.com/second",
        method: "POST",
        timestamp: 2,
        context: context
    )
    let index = NetworkRequestIndex()
    _ = await index.replace(with: [first.input], sequence: 1)
    let lifetime = WebInspectorQueryRegistrationLifetime()
    let registrationID = WebInspectorQueryRegistrationID(rawValue: 2)
    let initialGeneration = lifetime.nextGeneration()
    _ = try await index.register(
        id: registrationID,
        generation: initialGeneration,
        query: NetworkQuery(sort: .requestTimeAscending),
        lifetime: lifetime,
        minimumSequence: 1
    )

    let replacementGeneration = lifetime.nextGeneration()
    let replacementQuery = NetworkQuery(
        methods: ["POST"],
        sort: .requestTimeAscending
    )
    let prepared = try await index.prepareReplacement(
        id: registrationID,
        generation: replacementGeneration,
        query: replacementQuery,
        minimumSequence: 1
    )
    #expect(prepared.snapshot.itemIDs.isEmpty)

    let deliveries = await index.upsert(second.input, sequence: 2)
    let candidateDelivery = try #require(deliveries.first {
        $0.generation == replacementGeneration
    })
    #expect(candidateDelivery.projection.snapshot.itemIDs == [second.id])
    #expect(candidateDelivery.projection.reconfigureItemIDs == [second.id])

    let committed = try #require(await index.commitReplacement(
        id: registrationID,
        generation: replacementGeneration
    ))
    #expect(committed.sequence == 2)
    #expect(committed.snapshot.itemIDs == [second.id])
}

@MainActor
@Test
func cancelledNetworkConcreteQueryReplacementLeavesTheActiveGenerationWhole() async throws {
    let context = WebInspectorModelContext.preview()
    let first = makeIndexedNetworkRecord(
        id: "cancel-first",
        url: "https://example.com/first",
        method: "GET",
        timestamp: 1,
        context: context
    )
    let second = makeIndexedNetworkRecord(
        id: "cancel-second",
        url: "https://example.com/second",
        method: "POST",
        timestamp: 2,
        context: context
    )
    let index = NetworkRequestIndex()
    _ = await index.replace(with: [first.input], sequence: 1)
    let lifetime = WebInspectorQueryRegistrationLifetime()
    let registrationID = WebInspectorQueryRegistrationID(rawValue: 3)
    let activeGeneration = lifetime.nextGeneration()
    _ = try await index.register(
        id: registrationID,
        generation: activeGeneration,
        query: NetworkQuery(sort: .requestTimeAscending),
        lifetime: lifetime,
        minimumSequence: 1
    )

    let cancelledGeneration = lifetime.nextGeneration()
    let replacement = Task {
        try await index.prepareReplacement(
            id: registrationID,
            generation: cancelledGeneration,
            query: NetworkQuery(methods: ["POST"]),
            minimumSequence: 2
        )
    }
    try await waitForConcreteQueryCondition {
        await index.isSequenceWaiterPendingForTesting(minimumSequence: 2)
    }
    replacement.cancel()

    await #expect(throws: CancellationError.self) {
        try await replacement.value
    }
    #expect(await index.isSequenceWaiterPendingForTesting(minimumSequence: 2) == false)
    #expect(await index.commitReplacement(
        id: registrationID,
        generation: cancelledGeneration
    ) == nil)

    let deliveries = await index.upsert(second.input, sequence: 2)
    #expect(deliveries.map(\.generation) == [activeGeneration])
    #expect(deliveries.first?.projection.snapshot.itemIDs == [first.id, second.id])
}

@MainActor
@Test
func overlappingNetworkConcreteQueryReplacementsCommitOnlyTheNewestGeneration() async throws {
    let context = WebInspectorModelContext.preview()
    let first = makeIndexedNetworkRecord(
        id: "overlap-first",
        url: "https://example.com/first",
        method: "GET",
        timestamp: 1,
        context: context
    )
    let second = makeIndexedNetworkRecord(
        id: "overlap-second",
        url: "https://example.com/second",
        method: "POST",
        timestamp: 2,
        context: context
    )
    let index = NetworkRequestIndex()
    _ = await index.replace(with: [first.input], sequence: 1)
    let lifetime = WebInspectorQueryRegistrationLifetime()
    let registrationID = WebInspectorQueryRegistrationID(rawValue: 4)
    let initialGeneration = lifetime.nextGeneration()
    _ = try await index.register(
        id: registrationID,
        generation: initialGeneration,
        query: NetworkQuery(),
        lifetime: lifetime,
        minimumSequence: 1
    )

    let supersededGeneration = lifetime.nextGeneration()
    _ = try await index.prepareReplacement(
        id: registrationID,
        generation: supersededGeneration,
        query: NetworkQuery(methods: ["GET"]),
        minimumSequence: 1
    )
    let newestGeneration = lifetime.nextGeneration()
    _ = try await index.prepareReplacement(
        id: registrationID,
        generation: newestGeneration,
        query: NetworkQuery(methods: ["POST"]),
        minimumSequence: 1
    )

    #expect(await index.commitReplacement(
        id: registrationID,
        generation: supersededGeneration
    ) == nil)
    let newest = try #require(await index.commitReplacement(
        id: registrationID,
        generation: newestGeneration
    ))
    #expect(newest.snapshot.itemIDs.isEmpty)

    let deliveries = await index.upsert(second.input, sequence: 2)
    #expect(deliveries.map(\.generation) == [newestGeneration])
    #expect(deliveries.first?.projection.snapshot.itemIDs == [second.id])
}

@MainActor
@Test
func concreteFetchedResultsNeverRegressTheirSourceEpoch() throws {
    let context = WebInspectorModelContext.preview()
    let first = makeIndexedNetworkRecord(
        id: "epoch-first",
        url: "https://example.com/first",
        method: "GET",
        timestamp: 1,
        context: context
    )
    let second = makeIndexedNetworkRecord(
        id: "epoch-second",
        url: "https://example.com/second",
        method: "GET",
        timestamp: 2,
        context: context
    )
    guard let firstModel = try context.networkRequest(id: first.id),
          let secondModel = try context.networkRequest(id: second.id) else {
        Issue.record("Expected source-epoch fixtures to remain registered.")
        return
    }
    let models = [first.id: firstModel, second.id: secondModel]
    let results = WebInspectorFetchedResults<NetworkRequest>(modelContext: context)
    let initialQuery = NetworkQuery(sort: .requestTimeAscending)
    results.installInitialNetworkQuery(
        initialQuery,
        generation: 1,
        projection: NetworkRequestIndex.QueryProjection(
            sourceEpoch: 1,
            sequence: 1,
            snapshot: WebInspectorFetchedResultsSnapshot(itemIDs: [first.id]),
            reconfigureItemIDs: []
        ),
        lookup: { models[$0] }
    )
    #expect(results.query == initialQuery)
    #expect(results[id: first.id] === firstModel)
    #expect(results[section: .defaultSection]?.items.first === firstModel)

    let resetApplied = results.applyNetworkQueryProjection(
        NetworkRequestIndex.QueryProjection(
            sourceEpoch: 2,
            sequence: 2,
            snapshot: WebInspectorFetchedResultsSnapshot(),
            reconfigureItemIDs: []
        ),
        query: initialQuery,
        generation: 1,
        isReplacement: false,
        lookup: { models[$0] }
    )
    let revisionAfterReset = results.revision
    let staleNewGenerationApplied = results.applyNetworkQueryProjection(
        NetworkRequestIndex.QueryProjection(
            sourceEpoch: 1,
            sequence: 3,
            snapshot: WebInspectorFetchedResultsSnapshot(itemIDs: [second.id]),
            reconfigureItemIDs: [second.id]
        ),
        query: NetworkQuery(methods: ["GET"]),
        generation: 2,
        isReplacement: true,
        lookup: { models[$0] }
    )

    #expect(resetApplied)
    #expect(staleNewGenerationApplied == false)
    #expect(results.items.isEmpty)
    #expect(results.snapshot.itemIDs.isEmpty)
    #expect(results.query == initialQuery)
    #expect(results.revision == revisionAfterReset)
    #expect(results[id: first.id] == nil)
    #expect(results[section: .defaultSection] == nil)
}

@MainActor
@Test
func networkConcreteQueryPublishesSameIdentityMoveSectionsWindowAndClear() async throws {
    let context = WebInspectorModelContext.preview()
    let store = NetworkRequestStore()
    let firstProxyID = Network.Request.ID("store-first")
    let secondProxyID = Network.Request.ID("store-second")
    await addNetworkRequest(
        firstProxyID,
        url: "https://example.com/first.js",
        method: "GET",
        timestamp: 1,
        store: store,
        context: context
    )
    await finishNetworkRequest(firstProxyID, timestamp: 1.5, store: store, context: context)
    await addNetworkRequest(
        secondProxyID,
        url: "https://example.com/second.js",
        method: "POST",
        timestamp: 2,
        store: store,
        context: context
    )
    await finishNetworkRequest(secondProxyID, timestamp: 2.5, store: store, context: context)

    let initialQuery = NetworkQuery(
        sort: .requestTimeAscending,
        section: .method,
        limit: 2
    )
    let results = try await store.results(
        matching: initialQuery,
        modelContext: context,
    )
    let firstID = NetworkRequest.ID(firstProxyID)
    let secondID = NetworkRequest.ID(secondProxyID)
    let registeredFirst = store.request(
        forProxyID: firstProxyID,
    )
    let firstIdentity = try #require(registeredFirst)
    #expect(results.items.map(\.id) == [firstID, secondID])
    #expect(results.sections.map(\.id.rawValue) == ["GET", "POST"])
    #expect(results.query == initialQuery)
    #expect(results[id: firstID] === firstIdentity)
    #expect(results[section: "GET"]?.items == [firstIdentity])
    var updates = results.updates().makeAsyncIterator()
    guard case .initial? = await updates.next() else {
        Issue.record("Expected an initial concrete Network query state.")
        return
    }

    await addNetworkRequest(
        firstProxyID,
        url: "https://example.com/first.js",
        method: "PUT",
        timestamp: 3,
        store: store,
        context: context
    )
    #expect(results.items.map(\.id) == [secondID, firstID])
    #expect(results.sections.map(\.id.rawValue) == ["POST", "PUT"])
    #expect(results.items.last === firstIdentity)
    guard case let .transaction(_, move, reconfigure)? = await updates.next() else {
        Issue.record("Expected the same-ID Network query move transaction.")
        return
    }
    #expect(move.newSnapshot == results.snapshot)
    #expect(reconfigure == [firstID])

    let replacementQuery = NetworkQuery(
        sort: .requestTimeAscending,
        section: .method,
        offset: 1,
        limit: 1
    )
    let revisionBeforeReplacement = results.revision
    try await store.update(
        replacementQuery,
        for: results,
    )
    #expect(results.items.map(\.id) == [firstID])
    #expect(results.sections.map(\.id.rawValue) == ["PUT"])
    #expect(results.query == replacementQuery)
    #expect(results.revision == revisionBeforeReplacement + 1)
    #expect(results[id: firstID] === firstIdentity)
    #expect(results[id: secondID] == nil)
    #expect(results[section: "PUT"]?.items == [firstIdentity])
    #expect(results[section: "POST"] == nil)

    await store.clear()
    #expect(results.items.isEmpty)
    #expect(results.sections.isEmpty)
    #expect(results.snapshot.itemIDs.isEmpty)
    #expect(results.query == replacementQuery)
    #expect(results[id: firstID] == nil)
    #expect(results[section: "PUT"] == nil)
}

@MainActor
@Test
func networkConcreteQueryProjectsTenThousandRecordsOffTheOwnerActor() async throws {
    let context = WebInspectorModelContext.preview()
    let store = NetworkRequestStore()
    let recordCount = 10_000
    for ordinal in 0..<recordCount {
        await addNetworkRequest(
            Network.Request.ID("concrete-performance-\(ordinal)"),
            url: "https://example.com/\(ordinal)",
            method: ordinal.isMultiple(of: 2) ? "GET" : "POST",
            timestamp: Double(ordinal),
            store: store,
            context: context
        )
    }
    store.resetPerformanceCountersForTesting()

    let results = try await store.results(
        matching: NetworkQuery(
            methods: ["GET"],
            sort: .requestTimeDescending,
            limit: 25
        ),
        modelContext: context,
    )
    #expect(results.items.count == 25)
    var counters = store.performanceCountersForTesting
    #expect(counters.fullModelProjectionCount == 0)
    #expect(counters.fullRecordProjectionCount == 0)
    #expect(counters.resultIdentityLookupCount == 25)

    let newestID = Network.Request.ID("concrete-performance-newest")
    await addNetworkRequest(
        newestID,
        url: "https://example.com/newest",
        method: "GET",
        timestamp: Double(recordCount),
        store: store,
        context: context
    )
    #expect(results.items.first?.id == NetworkRequest.ID(newestID))
    counters = store.performanceCountersForTesting
    #expect(counters.fullModelProjectionCount == 0)
    #expect(counters.fullRecordProjectionCount == 0)
    #expect(counters.incrementalRecordProjectionCount == 1)
    #expect(counters.resultIdentityLookupCount == 26)

    try await store.update(
        NetworkQuery(
            methods: ["POST"],
            sort: .requestTimeAscending,
            offset: 10,
            limit: 10
        ),
        for: results,
    )
    counters = store.performanceCountersForTesting
    #expect(results.items.count == 10)
    #expect(counters.fullModelProjectionCount == 0)
    #expect(counters.fullRecordProjectionCount == 0)
}

@MainActor
@Test
func droppingNetworkConcreteResultsReleasesItsIndexRegistration() async throws {
    let context = WebInspectorModelContext.preview()
    let store = NetworkRequestStore()
    var results: WebInspectorFetchedResults<NetworkRequest>? = try await store.results(
        matching: NetworkQuery(),
        modelContext: context,
    )
    weak let weakResults = results

    let registrationCount = await store.concreteQueryRegistrationCountForTesting(
    )
    #expect(registrationCount == 1)
    results = nil
    #expect(weakResults == nil)
    let prunedRegistrationCount = await store.concreteQueryRegistrationCountForTesting(
    )
    #expect(prunedRegistrationCount == 0)
}

@MainActor
private func makeIndexedNetworkRecord(
    id: String,
    url: String,
    method: String,
    timestamp: Double,
    context: WebInspectorModelContext
) -> (id: NetworkRequest.ID, input: NetworkRequestRecordInput) {
    let modelID = context.seedNetworkRequest(
        requestID: id,
        url: url,
        method: method,
        resourceTypeRawValue: "Fetch",
        responseMIMEType: "application/json",
        responseStatus: 200,
        responseStatusText: "OK",
        timestamp: timestamp,
    )
    guard let request = try! context.networkRequest(id: modelID) else {
        preconditionFailure("The indexed Network fixture was not registered.")
    }
    return (modelID, NetworkRequestRecordInput(request: request, orderIndex: Int(timestamp)))
}

@MainActor
private func addNetworkRequest(
    _ id: Network.Request.ID,
    url: String,
    method: String,
    timestamp: Double,
    store: NetworkRequestStore,
    context: WebInspectorModelContext
) async {
    await store.apply(
        .requestWillBeSent(
            id: id,
            request: Network.Request(id: id, url: url, method: method),
            initiator: Network.Initiator(kind: "other"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: timestamp
        ),
        modelContext: context,
    )
}

@MainActor
private func finishNetworkRequest(
    _ id: Network.Request.ID,
    timestamp: Double,
    store: NetworkRequestStore,
    context: WebInspectorModelContext
) async {
    await store.apply(
        .loadingFinished(
            id: id,
            timestamp: timestamp,
            sourceMapURL: nil,
            metrics: nil
        ),
        modelContext: context,
    )
}

func waitForConcreteQueryCondition(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while await condition() == false {
        if clock.now >= deadline {
            throw ConcreteQueryTimedOut()
        }
        await Task.yield()
    }
}

private struct ConcreteQueryTimedOut: Error {}
