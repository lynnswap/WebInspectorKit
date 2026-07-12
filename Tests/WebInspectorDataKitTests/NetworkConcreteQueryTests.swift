import Observation
import Synchronization
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
func networkInitiatorGroupIdentityNamespacesNodesSingletonsAndTargetScopes() {
    let requestID = NetworkRequest.ID(Network.Request.ID("shared"))
    let otherRequestID = NetworkRequest.ID(Network.Request.ID("other"))
    let unscopedNodeID = DOM.Node.ID("shared")
    let targetANodeID = DOM.Node.ID("7", scopedToTargetRawValue: "target-a")
    let targetBNodeID = DOM.Node.ID("7", scopedToTargetRawValue: "target-b")
    let targetARequestID = NetworkRequest.ID(Network.Request.ID(
        "7",
        scopedToTargetRawValue: "target-a"
    ))
    let targetBRequestID = NetworkRequest.ID(Network.Request.ID(
        "7",
        scopedToTargetRawValue: "target-b"
    ))

    let singletonID = NetworkRequestGroupIdentity.sectionID(
        requestID: requestID,
        initiatorNodeIDRawValue: nil
    )
    let unscopedNodeGroupID = NetworkRequestGroupIdentity.sectionID(
        requestID: requestID,
        initiatorNodeIDRawValue: unscopedNodeID.rawValue
    )
    let sameNodeFromAnotherRequestID = NetworkRequestGroupIdentity.sectionID(
        requestID: otherRequestID,
        initiatorNodeIDRawValue: unscopedNodeID.rawValue
    )
    let targetAGroupID = NetworkRequestGroupIdentity.sectionID(
        requestID: requestID,
        initiatorNodeIDRawValue: targetANodeID.rawValue
    )
    let targetBGroupID = NetworkRequestGroupIdentity.sectionID(
        requestID: requestID,
        initiatorNodeIDRawValue: targetBNodeID.rawValue
    )
    let targetASingletonID = NetworkRequestGroupIdentity.sectionID(
        requestID: targetARequestID,
        initiatorNodeIDRawValue: nil
    )
    let targetBSingletonID = NetworkRequestGroupIdentity.sectionID(
        requestID: targetBRequestID,
        initiatorNodeIDRawValue: nil
    )

    #expect(singletonID != unscopedNodeGroupID)
    #expect(unscopedNodeGroupID == sameNodeFromAnotherRequestID)
    #expect(targetAGroupID != targetBGroupID)
    #expect(targetASingletonID != targetBSingletonID)
}

@MainActor
@Test
func networkInitiatorGroupsFilterByAnyMemberAndWindowGroupsInFirstMemberOrder() async throws {
    let context = WebInspectorModelContext.preview()
    let aFirst = makeIndexedNetworkRecord(
        id: "group-a-first",
        url: "https://example.com/group-a/first",
        method: "GET",
        timestamp: 1,
        initiatorNodeIDRawValue: "node-a",
        context: context
    )
    let aLaterMatch = makeIndexedNetworkRecord(
        id: "group-a-later",
        url: "https://example.com/group-a/needle",
        method: "GET",
        timestamp: 5,
        initiatorNodeIDRawValue: "node-a",
        context: context
    )
    let bFirst = makeIndexedNetworkRecord(
        id: "group-b-first",
        url: "https://example.com/group-b/first",
        method: "POST",
        timestamp: 2,
        initiatorNodeIDRawValue: "node-b",
        context: context
    )
    let bLater = makeIndexedNetworkRecord(
        id: "group-b-later",
        url: "https://example.com/group-b/later",
        method: "POST",
        timestamp: 3,
        initiatorNodeIDRawValue: "node-b",
        context: context
    )
    let singleton = makeIndexedNetworkRecord(
        id: "group-singleton",
        url: "https://example.com/singleton",
        method: "GET",
        timestamp: 4,
        context: context
    )
    let groupAID = aFirst.input.groupID
    let groupBID = bFirst.input.groupID
    let singletonGroupID = singleton.input.groupID
    let index = NetworkRequestIndex()
    _ = await index.replace(
        with: [
            aLaterMatch.input,
            bLater.input,
            singleton.input,
            aFirst.input,
            bFirst.input,
        ],
        sequence: 1
    )
    let lifetime = WebInspectorQueryRegistrationLifetime()
    let registrationID = WebInspectorQueryRegistrationID(rawValue: 20)

    let ascendingGeneration = lifetime.nextGeneration()
    let ascending = try await index.register(
        id: registrationID,
        generation: ascendingGeneration,
        query: NetworkQuery(
            sort: .requestTimeAscending,
            section: .initiatorNode
        ),
        lifetime: lifetime,
        minimumSequence: 1
    )
    #expect(ascending.state.snapshot.sectionIDs == [groupAID, groupBID, singletonGroupID])
    #expect(ascending.state.snapshot.sections[0].itemIDs == [aFirst.id, aLaterMatch.id])
    #expect(ascending.state.snapshot.sections[1].itemIDs == [bFirst.id, bLater.id])

    let filteredGeneration = lifetime.nextGeneration()
    _ = try await index.prepareReplacement(
        id: registrationID,
        generation: filteredGeneration,
        query: NetworkQuery(
            search: "needle",
            sort: .requestTimeAscending,
            section: .initiatorNode
        ),
        minimumSequence: 1
    )
    let filtered = try #require(await index.commitReplacement(
        id: registrationID,
        generation: filteredGeneration
    ))
    #expect(filtered.state.snapshot.sectionIDs == [groupAID])
    #expect(filtered.state.snapshot.itemIDs == [aFirst.id, aLaterMatch.id])

    let windowedGeneration = lifetime.nextGeneration()
    _ = try await index.prepareReplacement(
        id: registrationID,
        generation: windowedGeneration,
        query: NetworkQuery(
            sort: .requestTimeDescending,
            section: .initiatorNode,
            offset: 1,
            limit: 1
        ),
        minimumSequence: 1
    )
    let windowed = try #require(await index.commitReplacement(
        id: registrationID,
        generation: windowedGeneration
    ))
    #expect(windowed.state.snapshot.sectionIDs == [groupBID])
    #expect(windowed.state.snapshot.itemIDs == [bFirst.id, bLater.id])
}

@MainActor
@Test
func networkInitiatorSameGroupInsertionKeepsSectionAndBuildsItemTransaction() async throws {
    let context = WebInspectorModelContext.preview()
    let first = makeIndexedNetworkRecord(
        id: "same-group-first",
        url: "https://example.com/first",
        method: "GET",
        timestamp: 1,
        initiatorNodeIDRawValue: "same-node",
        context: context
    )
    let second = makeIndexedNetworkRecord(
        id: "same-group-second",
        url: "https://example.com/second",
        method: "GET",
        timestamp: 2,
        initiatorNodeIDRawValue: "same-node",
        context: context
    )
    let index = NetworkRequestIndex()
    _ = await index.replace(with: [first.input], sequence: 1)
    let lifetime = WebInspectorQueryRegistrationLifetime()
    let generation = lifetime.nextGeneration()
    let registrationID = WebInspectorQueryRegistrationID(rawValue: 21)
    let initial = try await index.register(
        id: registrationID,
        generation: generation,
        query: NetworkQuery(
            sort: .requestTimeAscending,
            section: .initiatorNode
        ),
        lifetime: lifetime,
        minimumSequence: 1
    )
    await index.acknowledge(
        id: registrationID,
        generation: generation,
        state: initial.state
    )

    let deliveries = await index.upsert(second.input, sequence: 2)
    let publication = try #require(deliveries.first?.publication)
    guard case let .transaction(base, transaction) = publication.change else {
        Issue.record("Expected a same-group insertion transaction.")
        return
    }

    #expect(base == initial.state.cursor)
    #expect(transaction.isReset == false)
    #expect(transaction.sectionChanges.isEmpty)
    #expect(transaction.oldSnapshot.sectionIDs == [first.input.groupID])
    #expect(transaction.newSnapshot.sectionIDs == [first.input.groupID])
    #expect(transaction.newSnapshot.itemIDs == [first.id, second.id])
    #expect(transaction.itemChanges.contains { change in
        guard case let .insert(itemID, indexPath) = change else {
            return false
        }
        return itemID == second.id
            && indexPath == WebInspectorFetchedResultsIndexPath(section: 0, item: 1)
    })
}

@MainActor
@Test
func networkInitiatorQueryPreservesRedirectSearchAfterActorSideDerivation() async throws {
    let context = WebInspectorModelContext.preview()
    let store = NetworkRequestStore()
    let proxyID = Network.Request.ID("redirect-search")
    let nodeID = DOM.Node.ID("redirect-node")
    await store.apply(
        .requestWillBeSent(
            id: proxyID,
            request: Network.Request(
                id: proxyID,
                url: "https://redirect-origin.example/old-path",
                method: "GET"
            ),
            initiator: Network.Initiator(kind: "other", nodeID: nodeID),
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
                url: "https://final.example/new-path",
                method: "GET"
            ),
            initiator: Network.Initiator(kind: "other", nodeID: DOM.Node.ID("ignored-node")),
            resourceType: .document,
            redirectResponse: Network.Response(
                url: "https://redirect-origin.example/old-path",
                status: 302,
                statusText: "Found",
                mimeType: "text/html"
            ),
            timestamp: 2
        ),
        modelContext: context
    )

    let results = try await store.results(
        matching: NetworkQuery(
            search: "redirect-origin.example",
            section: .initiatorNode
        ),
        modelContext: context
    )
    let request = try #require(store.request(forProxyID: proxyID))

    #expect(results.items == [request])
    #expect(results.sections.count == 1)
    #expect(results.sections[0].items == [request])
    #expect(results.sections[0].id == NetworkRequestGroupIdentity.sectionID(
        requestID: request.id,
        initiatorNodeIDRawValue: nodeID.rawValue
    ))
}

@MainActor
@Test
func networkActorDerivesResourceCategoryFromRawResponseFields() async throws {
    let context = WebInspectorModelContext.preview()
    let store = NetworkRequestStore()
    let proxyID = Network.Request.ID("header-category")
    await store.apply(
        .requestWillBeSent(
            id: proxyID,
            request: Network.Request(
                id: proxyID,
                url: "https://example.com/resource-without-extension",
                method: "GET"
            ),
            initiator: Network.Initiator(kind: "other"),
            resourceType: nil,
            redirectResponse: nil,
            timestamp: 1
        ),
        modelContext: context
    )
    await store.apply(
        .responseReceived(
            id: proxyID,
            response: Network.Response(
                url: "https://example.com/resource-without-extension",
                status: 200,
                headers: ["Content-Type": "image/png; charset=binary"]
            ),
            resourceType: nil,
            timestamp: 2
        ),
        modelContext: context
    )

    let results = try await store.results(
        matching: NetworkQuery(
            resourceCategories: [.image],
            section: .initiatorNode
        ),
        modelContext: context
    )
    let request = try #require(store.request(forProxyID: proxyID))

    #expect(results.items == [request])
    #expect(results.sections.count == 1)
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
    #expect(ascending.state.snapshot.itemIDs == [first.id, second.id])

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
    #expect(descending.state.snapshot.itemIDs == [second.id, first.id])
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
    let publication = try await registration.value

    #expect(publication.state.cursor.sequence == 2)
    #expect(publication.state.snapshot.itemIDs == [first.id, second.id])
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
    #expect(prepared.state.snapshot.itemIDs.isEmpty)

    let deliveries = await index.upsert(second.input, sequence: 2)
    let candidateDelivery = try #require(deliveries.first {
        $0.generation == replacementGeneration
    })
    #expect(candidateDelivery.publication.state.snapshot.itemIDs == [second.id])
    #expect(candidateDelivery.publication.reconfigureItemIDs.isEmpty)
    guard case .reset = candidateDelivery.publication.change else {
        Issue.record("Expected an unacknowledged candidate to publish a reset.")
        return
    }

    let committed = try #require(await index.commitReplacement(
        id: registrationID,
        generation: replacementGeneration
    ))
    #expect(committed.state.cursor.sequence == 2)
    #expect(committed.state.snapshot.itemIDs == [second.id])
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
    #expect(deliveries.first?.publication.state.snapshot.itemIDs == [first.id, second.id])
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
    #expect(newest.state.snapshot.itemIDs.isEmpty)

    let deliveries = await index.upsert(second.input, sequence: 2)
    #expect(deliveries.map(\.generation) == [newestGeneration])
    #expect(deliveries.first?.publication.state.snapshot.itemIDs == [second.id])
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
        publication: NetworkRequestIndex.QueryPublication(
            state: NetworkRequestIndex.QueryState(
                cursor: WebInspectorIndexedQueryCursor(sourceEpoch: 1, sequence: 1),
                snapshot: WebInspectorFetchedResultsSnapshot(itemIDs: [first.id])
            ),
            change: .reset,
            reconfigureItemIDs: []
        ),
        lookup: { models[$0] }
    )
    #expect(results.query == initialQuery)
    #expect(results[id: first.id] === firstModel)
    #expect(results[section: .defaultSection]?.items.first === firstModel)

    let resetApplied = results.applyNetworkQueryPublication(
        NetworkRequestIndex.QueryPublication(
            state: NetworkRequestIndex.QueryState(
                cursor: WebInspectorIndexedQueryCursor(sourceEpoch: 2, sequence: 2),
                snapshot: WebInspectorFetchedResultsSnapshot()
            ),
            change: .reset,
            reconfigureItemIDs: []
        ),
        query: initialQuery,
        generation: 1,
        isReplacement: false,
        lookup: { models[$0] }
    )
    let revisionAfterReset = results.revision
    let staleNewGenerationApplied = results.applyNetworkQueryPublication(
        NetworkRequestIndex.QueryPublication(
            state: NetworkRequestIndex.QueryState(
                cursor: WebInspectorIndexedQueryCursor(sourceEpoch: 1, sequence: 3),
                snapshot: WebInspectorFetchedResultsSnapshot(itemIDs: [second.id])
            ),
            change: .reset,
            reconfigureItemIDs: [second.id]
        ),
        query: NetworkQuery(methods: ["GET"]),
        generation: 2,
        isReplacement: true,
        lookup: { models[$0] }
    )

    #expect(resetApplied != nil)
    #expect(staleNewGenerationApplied == nil)
    #expect(results.items.isEmpty)
    #expect(results.snapshot.itemIDs.isEmpty)
    #expect(results.query == initialQuery)
    #expect(results.revision == revisionAfterReset)
    #expect(results[id: first.id] == nil)
    #expect(results[section: .defaultSection] == nil)
}

@MainActor
@Test
func networkActorTransactionsKeepTheLastAcknowledgedBaselineAcrossTwoUnacknowledgedUpdates() async throws {
    let context = WebInspectorModelContext.preview()
    let first = makeIndexedNetworkRecord(
        id: "ack-baseline-first",
        url: "https://example.com/first",
        method: "GET",
        timestamp: 1,
        context: context
    )
    let second = makeIndexedNetworkRecord(
        id: "ack-baseline-second",
        url: "https://example.com/second",
        method: "GET",
        timestamp: 2,
        context: context
    )
    let index = NetworkRequestIndex()
    _ = await index.replace(with: [first.input, second.input], sequence: 1)
    let lifetime = WebInspectorQueryRegistrationLifetime()
    let registrationID = WebInspectorQueryRegistrationID(rawValue: 20)
    let generation = lifetime.nextGeneration()
    let initial = try await index.register(
        id: registrationID,
        generation: generation,
        query: NetworkQuery(sort: .requestTimeAscending),
        lifetime: lifetime,
        minimumSequence: 1
    )
    await index.acknowledge(
        id: registrationID,
        generation: generation,
        state: initial.state
    )

    let secondSequenceDelivery = try #require(
        await index.upsert(first.input, sequence: 2).first
    )
    guard case let .transaction(secondBase, secondTransaction) =
        secondSequenceDelivery.publication.change else {
        Issue.record("Expected sequence 2 to publish an acknowledged transaction.")
        return
    }
    #expect(secondBase == initial.state.cursor)
    #expect(secondTransaction.oldSnapshot == initial.state.snapshot)

    let thirdSequenceDelivery = try #require(
        await index.upsert(second.input, sequence: 3).first
    )
    guard case let .transaction(thirdBase, thirdTransaction) =
        thirdSequenceDelivery.publication.change else {
        Issue.record("Expected sequence 3 to publish from the unchanged ACK baseline.")
        return
    }
    #expect(thirdBase == initial.state.cursor)
    #expect(thirdTransaction.oldSnapshot == initial.state.snapshot)
    #expect(thirdSequenceDelivery.publication.reconfigureItemIDs == [first.id, second.id])

    await index.acknowledge(
        id: registrationID,
        generation: generation,
        state: thirdSequenceDelivery.publication.state
    )
    await index.acknowledge(
        id: registrationID,
        generation: generation,
        state: initial.state
    )
    await index.acknowledge(
        id: registrationID,
        generation: generation,
        state: NetworkRequestIndex.QueryState(
            cursor: WebInspectorIndexedQueryCursor(sourceEpoch: 0, sequence: 99),
            snapshot: thirdSequenceDelivery.publication.state.snapshot
        )
    )

    let fourthSequenceDelivery = try #require(
        await index.upsert(first.input, sequence: 4).first
    )
    guard case let .transaction(fourthBase, fourthTransaction) =
        fourthSequenceDelivery.publication.change else {
        Issue.record("Expected stale and ahead ACKs to leave the latest applied baseline intact.")
        return
    }
    #expect(fourthBase == thirdSequenceDelivery.publication.state.cursor)
    #expect(fourthTransaction.oldSnapshot == thirdSequenceDelivery.publication.state.snapshot)
    #expect(fourthSequenceDelivery.publication.reconfigureItemIDs == [first.id])
}

@MainActor
@Test
func networkQueryIndexBuildsContentTransactionsWithoutRebuildingTheSnapshot() async throws {
    let context = WebInspectorModelContext.preview()
    let record = makeIndexedNetworkRecord(
        id: "content-only",
        url: "https://example.com/content-only",
        method: "GET",
        timestamp: 1,
        initiatorNodeIDRawValue: "content-group",
        context: context
    )
    let index = NetworkRequestIndex()
    _ = await index.replace(with: [record.input], sequence: 1)
    let lifetime = WebInspectorQueryRegistrationLifetime()
    let registrationID = WebInspectorQueryRegistrationID(rawValue: 24)
    let generation = lifetime.nextGeneration()
    let initial = try await index.register(
        id: registrationID,
        generation: generation,
        query: NetworkQuery(
            sort: .requestTimeDescending,
            section: .initiatorNode
        ),
        lifetime: lifetime,
        minimumSequence: 1
    )
    await index.acknowledge(
        id: registrationID,
        generation: generation,
        state: initial.state
    )
    await index.resetPerformanceCountersForTesting()

    var lastDelivery: NetworkRequestIndex.QueryDelivery?
    for sequence in 2...101 {
        lastDelivery = await index.upsert(record.input, sequence: UInt64(sequence)).first
    }

    let counters = await index.performanceCountersForTesting()
    #expect(counters.snapshotBuildCount == 0)
    #expect(counters.fullTransactionBuildCount == 0)
    #expect(counters.contentTransactionBuildCount == 100)

    let publication = try #require(lastDelivery?.publication)
    #expect(publication.state.snapshot == initial.state.snapshot)
    #expect(publication.reconfigureItemIDs == [record.id])
    guard case let .transaction(base, transaction) = publication.change else {
        Issue.record("Expected a content-only transaction.")
        return
    }
    #expect(base == initial.state.cursor)
    #expect(transaction.sectionChanges.isEmpty)
    #expect(transaction.itemChanges == [
        .update(
            itemID: record.id,
            indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)
        ),
    ])
}

@MainActor
@Test
func networkQueryMutationImpactIsEvaluatedPerRegisteredQuery() async throws {
    let context = WebInspectorModelContext.preview()
    let record = makeIndexedNetworkRecord(
        id: "query-impact",
        url: "https://example.com/query-impact",
        method: "GET",
        timestamp: 1,
        context: context
    )
    let index = NetworkRequestIndex()
    _ = await index.replace(with: [record.input], sequence: 1)

    let allLifetime = WebInspectorQueryRegistrationLifetime()
    let allGeneration = allLifetime.nextGeneration()
    let allRegistrationID = WebInspectorQueryRegistrationID(rawValue: 25)
    let allInitial = try await index.register(
        id: allRegistrationID,
        generation: allGeneration,
        query: NetworkQuery(section: .initiatorNode),
        lifetime: allLifetime,
        minimumSequence: 1
    )
    await index.acknowledge(
        id: allRegistrationID,
        generation: allGeneration,
        state: allInitial.state
    )

    let mediaLifetime = WebInspectorQueryRegistrationLifetime()
    let mediaGeneration = mediaLifetime.nextGeneration()
    let mediaRegistrationID = WebInspectorQueryRegistrationID(rawValue: 26)
    let mediaInitial = try await index.register(
        id: mediaRegistrationID,
        generation: mediaGeneration,
        query: NetworkQuery(
            resourceCategories: [.media],
            section: .initiatorNode
        ),
        lifetime: mediaLifetime,
        minimumSequence: 1
    )
    await index.acknowledge(
        id: mediaRegistrationID,
        generation: mediaGeneration,
        state: mediaInitial.state
    )
    await index.resetPerformanceCountersForTesting()

    var mediaInput = record.input
    mediaInput.resourceTypeRawValue = "Media"
    mediaInput.mimeType = "video/mp4"
    mediaInput.responseHeaders = ["content-type": "video/mp4"]
    let deliveries = await index.upsert(mediaInput, sequence: 2)

    let counters = await index.performanceCountersForTesting()
    #expect(counters.snapshotBuildCount == 1)
    #expect(counters.fullTransactionBuildCount == 1)
    #expect(counters.contentTransactionBuildCount == 1)
    let allDelivery = try #require(deliveries.first { $0.registrationID == allRegistrationID })
    #expect(allDelivery.publication.state.snapshot == allInitial.state.snapshot)
    let mediaDelivery = try #require(deliveries.first { $0.registrationID == mediaRegistrationID })
    #expect(mediaDelivery.publication.state.snapshot.itemIDs == [record.id])
}

@MainActor
@Test
func networkSourceEpochReplacementPublishesResetUntilItsStateIsAcknowledged() async throws {
    let context = WebInspectorModelContext.preview()
    let record = makeIndexedNetworkRecord(
        id: "source-reset",
        url: "https://example.com/reset",
        method: "GET",
        timestamp: 1,
        context: context
    )
    let index = NetworkRequestIndex()
    _ = await index.replace(with: [record.input], sequence: 1, sourceEpoch: 0)
    let lifetime = WebInspectorQueryRegistrationLifetime()
    let registrationID = WebInspectorQueryRegistrationID(rawValue: 21)
    let generation = lifetime.nextGeneration()
    let initial = try await index.register(
        id: registrationID,
        generation: generation,
        query: NetworkQuery(),
        lifetime: lifetime,
        minimumSequence: 1
    )
    await index.acknowledge(
        id: registrationID,
        generation: generation,
        state: initial.state
    )

    let resetDelivery = try #require(
        await index.replace(
            with: [record.input],
            sequence: 2,
            sourceEpoch: 1
        ).first
    )
    guard case .reset = resetDelivery.publication.change else {
        Issue.record("Expected a source epoch replacement to discard the old ACK baseline.")
        return
    }
    #expect(resetDelivery.publication.state.cursor.sourceEpoch == 1)

    await index.acknowledge(
        id: registrationID,
        generation: generation,
        state: resetDelivery.publication.state
    )
    let incrementalDelivery = try #require(
        await index.upsert(record.input, sequence: 3).first
    )
    guard case let .transaction(base, _) = incrementalDelivery.publication.change else {
        Issue.record("Expected the acknowledged replacement to restore incremental transactions.")
        return
    }
    #expect(base == resetDelivery.publication.state.cursor)
}

@MainActor
@Test
func fetchedResultsBaseMismatchRecoversWithResetAndCursorOnlyAdvanceDoesNotInvalidateObservation() async throws {
    let context = WebInspectorModelContext.preview()
    let first = makeIndexedNetworkRecord(
        id: "owner-cursor-first",
        url: "https://example.com/first",
        method: "GET",
        timestamp: 1,
        context: context
    )
    let second = makeIndexedNetworkRecord(
        id: "owner-cursor-second",
        url: "https://example.com/second",
        method: "GET",
        timestamp: 2,
        context: context
    )
    let firstModel = try #require(try context.networkRequest(id: first.id))
    let secondModel = try #require(try context.networkRequest(id: second.id))
    let models = [first.id: firstModel, second.id: secondModel]
    let results = WebInspectorFetchedResults<NetworkRequest>(modelContext: context)
    let firstCursor = WebInspectorIndexedQueryCursor(sourceEpoch: 1, sequence: 1)
    let firstSnapshot: WebInspectorFetchedResultsSnapshot<NetworkRequest.ID, WebInspectorFetchSectionID> =
        WebInspectorFetchedResultsSnapshot(itemIDs: [first.id])
    _ = results.installInitialNetworkQuery(
        NetworkQuery(),
        generation: 1,
        publication: NetworkRequestIndex.QueryPublication(
            state: NetworkRequestIndex.QueryState(
                cursor: firstCursor,
                snapshot: firstSnapshot
            ),
            change: .reset,
            reconfigureItemIDs: []
        ),
        lookup: { models[$0] }
    )
    var updates = results.updates().makeAsyncIterator()
    guard case .initial? = await updates.next() else {
        Issue.record("Expected the owner cursor fixture's initial state.")
        return
    }

    let observationInvalidations = Mutex(0)
    withObservationTracking {
        _ = results.items
        _ = results.snapshot
        _ = results.revision
    } onChange: {
        observationInvalidations.withLock { $0 += 1 }
    }

    let secondCursor = WebInspectorIndexedQueryCursor(sourceEpoch: 1, sequence: 2)
    let cursorOnlyState = NetworkRequestIndex.QueryState(
        cursor: secondCursor,
        snapshot: firstSnapshot
    )
    let cursorOnlyAppliedState = results.applyNetworkQueryPublication(
        NetworkRequestIndex.QueryPublication(
            state: cursorOnlyState,
            change: .transaction(
                base: firstCursor,
                transaction: WebInspectorFetchedResultsTransaction(
                    oldSnapshot: firstSnapshot,
                    newSnapshot: firstSnapshot
                )
            ),
            reconfigureItemIDs: []
        ),
        query: NetworkQuery(),
        generation: 1,
        isReplacement: false,
        lookup: { models[$0] }
    )
    #expect(cursorOnlyAppliedState == cursorOnlyState)
    #expect(results.revision == 0)
    #expect(observationInvalidations.withLock { $0 } == 0)

    let duplicateAppliedState = results.applyNetworkQueryPublication(
        NetworkRequestIndex.QueryPublication(
            state: cursorOnlyState,
            change: .reset,
            reconfigureItemIDs: []
        ),
        query: NetworkQuery(),
        generation: 1,
        isReplacement: false,
        lookup: { models[$0] }
    )
    #expect(duplicateAppliedState == cursorOnlyState)
    #expect(results.revision == 0)

    let thirdCursor = WebInspectorIndexedQueryCursor(sourceEpoch: 1, sequence: 3)
    let thirdSnapshot: WebInspectorFetchedResultsSnapshot<NetworkRequest.ID, WebInspectorFetchSectionID> =
        WebInspectorFetchedResultsSnapshot(itemIDs: [first.id, second.id])
    _ = results.applyNetworkQueryPublication(
        NetworkRequestIndex.QueryPublication(
            state: NetworkRequestIndex.QueryState(
                cursor: thirdCursor,
                snapshot: thirdSnapshot
            ),
            change: .transaction(
                base: secondCursor,
                transaction: WebInspectorFetchedResultsTransaction(
                    oldSnapshot: firstSnapshot,
                    newSnapshot: thirdSnapshot
                )
            ),
            reconfigureItemIDs: []
        ),
        query: NetworkQuery(),
        generation: 1,
        isReplacement: false,
        lookup: { models[$0] }
    )
    guard case let .transaction(thirdRevision, thirdTransaction, _)? = await updates.next() else {
        Issue.record("Expected the cursor-authorized topology transaction.")
        return
    }
    #expect(thirdRevision == 1)
    #expect(thirdTransaction.isReset == false)
    #expect(observationInvalidations.withLock { $0 } == 1)

    let fifthCursor = WebInspectorIndexedQueryCursor(sourceEpoch: 1, sequence: 5)
    let fifthSnapshot: WebInspectorFetchedResultsSnapshot<NetworkRequest.ID, WebInspectorFetchSectionID> =
        WebInspectorFetchedResultsSnapshot(itemIDs: [second.id])
    let recoveredState = results.applyNetworkQueryPublication(
        NetworkRequestIndex.QueryPublication(
            state: NetworkRequestIndex.QueryState(
                cursor: fifthCursor,
                snapshot: fifthSnapshot
            ),
            change: .transaction(
                base: WebInspectorIndexedQueryCursor(sourceEpoch: 1, sequence: 4),
                transaction: WebInspectorFetchedResultsTransaction(
                    oldSnapshot: firstSnapshot,
                    newSnapshot: fifthSnapshot
                )
            ),
            reconfigureItemIDs: []
        ),
        query: NetworkQuery(),
        generation: 1,
        isReplacement: false,
        lookup: { models[$0] }
    )
    guard case let .transaction(fifthRevision, recoveryTransaction, _)? = await updates.next() else {
        Issue.record("Expected one reset publication for a cursor base mismatch.")
        return
    }
    #expect(recoveredState?.cursor == fifthCursor)
    #expect(fifthRevision == 2)
    #expect(recoveryTransaction.isReset)
    #expect(recoveryTransaction.oldSnapshot == thirdSnapshot)
    #expect(recoveryTransaction.newSnapshot == fifthSnapshot)
    #expect(recoveryTransaction.sectionChanges.isEmpty)
    #expect(recoveryTransaction.itemChanges.isEmpty)

    let staleAppliedState = results.applyNetworkQueryPublication(
        NetworkRequestIndex.QueryPublication(
            state: NetworkRequestIndex.QueryState(
                cursor: WebInspectorIndexedQueryCursor(sourceEpoch: 1, sequence: 4),
                snapshot: firstSnapshot
            ),
            change: .reset,
            reconfigureItemIDs: []
        ),
        query: NetworkQuery(),
        generation: 1,
        isReplacement: false,
        lookup: { models[$0] }
    )
    #expect(staleAppliedState?.cursor == fifthCursor)
    #expect(results.revision == 2)
}

@MainActor
@Test
func networkSynchronousClearAcknowledgesItsActorStateBeforeTheNextMutation() async throws {
    let context = WebInspectorModelContext.preview()
    let store = NetworkRequestStore()
    await addNetworkRequest(
        Network.Request.ID("clear-before"),
        url: "https://example.com/before",
        method: "GET",
        timestamp: 1,
        store: store,
        context: context
    )
    let results = try await store.results(
        matching: NetworkQuery(sort: .requestTimeAscending),
        modelContext: context
    )
    var updates = results.updates().makeAsyncIterator()
    guard case .initial? = await updates.next() else {
        Issue.record("Expected the synchronous clear fixture's initial state.")
        return
    }

    await store.clear()
    guard case let .transaction(_, clearTransaction, _)? = await updates.next() else {
        Issue.record("Expected the synchronous clear reset.")
        return
    }
    #expect(clearTransaction.isReset)

    let afterID = Network.Request.ID("clear-after")
    await addNetworkRequest(
        afterID,
        url: "https://example.com/after",
        method: "GET",
        timestamp: 2,
        store: store,
        context: context
    )
    guard case let .transaction(_, incrementalTransaction, _)? = await updates.next() else {
        Issue.record("Expected an incremental publication after the clear ACK.")
        return
    }
    #expect(incrementalTransaction.isReset == false)
    #expect(incrementalTransaction.oldSnapshot.itemIDs.isEmpty)
    #expect(incrementalTransaction.newSnapshot.itemIDs == [NetworkRequest.ID(afterID)])
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
            methods: ["GET"],
            sort: .requestTimeDescending,
            section: .initiatorNode,
            limit: 25
        ),
        for: results
    )
    counters = store.performanceCountersForTesting
    #expect(results.items.count == 25)
    #expect(results.sections.count == 25)
    #expect(counters.fullModelProjectionCount == 0)
    #expect(counters.fullRecordProjectionCount == 0)
    #expect(counters.resultIdentityLookupCount == 26)

    try await store.update(
        NetworkQuery(
            methods: ["POST"],
            sort: .requestTimeAscending,
            section: .initiatorNode,
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
    initiatorNodeIDRawValue: String? = nil,
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
    var input = NetworkRequestRecordInput(request: request, orderIndex: Int(timestamp))
    input.initiatorNodeIDRawValue = initiatorNodeIDRawValue
    return (modelID, input)
}

@MainActor
private func addNetworkRequest(
    _ id: Network.Request.ID,
    url: String,
    method: String,
    initiatorNodeID: DOM.Node.ID? = nil,
    timestamp: Double,
    store: NetworkRequestStore,
    context: WebInspectorModelContext
) async {
    await store.apply(
        .requestWillBeSent(
            id: id,
            request: Network.Request(id: id, url: url, method: method),
            initiator: Network.Initiator(kind: "other", nodeID: initiatorNodeID),
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
