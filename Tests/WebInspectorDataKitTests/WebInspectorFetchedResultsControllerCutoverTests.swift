import Foundation
import Observation
import Synchronization
import Testing
@testable import WebInspectorDataKit

private enum FetchedResultsSnapshotHashProbe {
    static let count = Mutex(0)

    static func reset() {
        count.withLock { $0 = 0 }
    }

    static func recordHash() {
        count.withLock { $0 += 1 }
    }

    static var value: Int {
        count.withLock { $0 }
    }
}

private struct FetchedResultsSnapshotCountingID: Hashable, Sendable {
    let rawValue: Int

    func hash(into hasher: inout Hasher) {
        FetchedResultsSnapshotHashProbe.recordHash()
        hasher.combine(rawValue)
    }
}

@Observable
private final class CutoverQueryModel: WebInspectorPersistentModel {
    struct ID: WebInspectorPersistentIdentifier {
        typealias Model = CutoverQueryModel
        let rawValue: Int
    }

    struct QueryValue: Identifiable, Sendable {
        let id: ID
        let score: Int
    }

    let id: ID
    private(set) var score: Int

    init(id: ID, score: Int) {
        self.id = id
        self.score = score
    }

    func replace(score: Int) {
        self.score = score
    }
}

private struct CutoverQueryRecord: Sendable {
    let score: Int
}

private let cutoverQuerySchema = WebInspectorModelSchema<
    CutoverQueryModel,
    CutoverQueryRecord
>(
    featureID: .network,
    makeModel: { _, id, record in
        CutoverQueryModel(id: id, score: record.score)
    },
    updateModel: { _, model, record in
        model.replace(score: record.score)
    },
    invalidateModel: { _, _ in }
)

@Test
func fetchedResultsSnapshotDoesNotBuildADuplicateMembershipIndex() {
    let itemIDs = (0..<512).map(FetchedResultsSnapshotCountingID.init)
    FetchedResultsSnapshotHashProbe.reset()

    let snapshot = WebInspectorFetchedResultsSnapshot(itemIDs: itemIDs)

    #expect(snapshot.itemIDs == itemIDs)
    #expect(FetchedResultsSnapshotHashProbe.value == 0)
}

@Test
func unfilteredFullRangeContentBurstDoesNotRebuildMembership() async throws {
    let itemCount = 2_305
    let index = WebInspectorContextQueryIndex()
    let initialRecords = (0..<itemCount).map { rawValue in
        _WebInspectorQueryRecord<CutoverQueryModel>(
            queryValue: .init(
                id: .init(rawValue: rawValue),
                score: rawValue
            ),
            canonicalRank: .init(rawValue: UInt64(rawValue))
        )
    }
    let ready = WebInspectorFeatureState.ready(
        generation: .init(rawValue: 1),
        revision: .init(rawValue: 1)
    )
    let sourceDeliveries = await index.replaceSource(
        for: CutoverQueryModel.self,
        featureID: .network,
        featureState: ready,
        records: initialRecords
    )
    #expect(sourceDeliveries.isEmpty)

    let registrationID = WebInspectorQueryRegistrationID()
    let attempt = await index.register(
        registrationID,
        descriptor: WebInspectorFetchDescriptor<CutoverQueryModel>()
    )
    guard case let .success(initialItemIDs, .initial) = attempt else {
        Issue.record("Expected the full-range query to publish its initial result.")
        return
    }
    #expect(initialItemIDs.map(\.rawValue) == Array(0..<itemCount))
    await index.resetPerformanceCountersForTesting()

    let mutations = (0..<itemCount).map { rawValue in
        _WebInspectorQueryMutation<CutoverQueryModel>.upsert(
            _WebInspectorQueryRecord(
                queryValue: .init(
                    id: .init(rawValue: rawValue),
                    score: rawValue + itemCount
                ),
                canonicalRank: .init(rawValue: UInt64(rawValue))
            )
        )
    }
    let deliveries = await index.apply(mutations)

    let counters = await index.performanceCountersForTesting
    #expect(counters.fullRangeMembershipRebuildCount == 0)
    #expect(counters.fullRangeMembershipRebuildMemberVisitCount == 0)
    #expect(deliveries.count == 1)
    let delivery = try #require(deliveries.first)
    guard case let .changes(itemIDs, difference) = delivery.kind else {
        Issue.record("Expected one atomic content-only change.")
        return
    }
    #expect(itemIDs == initialItemIDs)
    #expect(difference.itemChanges.isEmpty)
    #expect(difference.updatedItemIDs.count == itemCount)

    await index.resetPerformanceCountersForTesting()
    var sequentialDeliveryCount = 0
    for rawValue in 0..<itemCount {
        let mutation = _WebInspectorQueryMutation<CutoverQueryModel>.upsert(
            _WebInspectorQueryRecord(
                queryValue: .init(
                    id: .init(rawValue: rawValue),
                    score: rawValue + itemCount * 2
                ),
                canonicalRank: .init(rawValue: UInt64(rawValue))
            )
        )
        sequentialDeliveryCount += await index.apply([mutation]).count
    }
    let sequentialCounters = await index.performanceCountersForTesting
    #expect(sequentialDeliveryCount == itemCount)
    #expect(sequentialCounters.fullRangeMembershipRebuildCount == 0)
    #expect(
        sequentialCounters.fullRangeMembershipRebuildMemberVisitCount == 0
    )
}

@Test
func unfilteredFullRangeRankChangeStillReordersCanonically() async throws {
    let index = WebInspectorContextQueryIndex()
    let initialRecords = (0..<3).map { rawValue in
        _WebInspectorQueryRecord<CutoverQueryModel>(
            queryValue: .init(
                id: .init(rawValue: rawValue),
                score: rawValue
            ),
            canonicalRank: .init(rawValue: UInt64(rawValue))
        )
    }
    _ = await index.replaceSource(
        for: CutoverQueryModel.self,
        featureID: .network,
        featureState: .ready(
            generation: .init(rawValue: 1),
            revision: .init(rawValue: 1)
        ),
        records: initialRecords
    )
    let registrationID = WebInspectorQueryRegistrationID()
    guard case .success = await index.register(
        registrationID,
        descriptor: WebInspectorFetchDescriptor<CutoverQueryModel>()
    ) else {
        Issue.record("Expected the full-range query to publish its initial result.")
        return
    }
    await index.resetPerformanceCountersForTesting()

    let mutations: [_WebInspectorQueryMutation<CutoverQueryModel>] = [
        .upsert(
            _WebInspectorQueryRecord(
                queryValue: .init(id: .init(rawValue: 0), score: 100),
                canonicalRank: .init(rawValue: 3)
            )
        )
    ]
    let deliveries = await index.apply(mutations)

    let counters = await index.performanceCountersForTesting
    #expect(counters.fullRangeMembershipRebuildCount == 1)
    #expect(counters.fullRangeMembershipRebuildMemberVisitCount == 3)
    #expect(deliveries.count == 1)
    let delivery = try #require(deliveries.first)
    guard case let .changes(itemIDs, difference) = delivery.kind else {
        Issue.record("Expected one canonical-order change.")
        return
    }
    #expect(itemIDs.map(\.rawValue) == [1, 2, 0])
    #expect(difference.itemChanges.count == 1)
    #expect(difference.updatedItemIDs.map(\.rawValue) == [0])
}

@MainActor
@Test
func fetchedResultsPerformsInitialThenAppliesOneAtomicDelta() async throws {
    let registry = try WebInspectorModelSchemaRegistry([
        cutoverQuerySchema.erased
    ])
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.network]),
        schemaRegistry: registry
    )
    let context = container.mainContext

    var initialTransaction = WebInspectorModelTransaction()
    initialTransaction.append(
        cutoverQuerySchema.upsert(
            record: CutoverQueryRecord(score: 20),
            queryValue: .init(id: .init(rawValue: 2), score: 20),
            canonicalRank: .init(rawValue: 2)
        )
    )
    initialTransaction.append(
        cutoverQuerySchema.upsert(
            record: CutoverQueryRecord(score: 10),
            queryValue: .init(id: .init(rawValue: 1), score: 10),
            canonicalRank: .init(rawValue: 1)
        )
    )
    initialTransaction.setFeatureState(
        .ready(
            generation: .init(rawValue: 1),
            revision: .init(rawValue: 0)
        ),
        for: .network
    )
    _ = try await container.modelStoreSink.commit(initialTransaction)

    let controller = WebInspectorFetchedResultsController<CutoverQueryModel>(
        fetchDescriptor: WebInspectorFetchDescriptor(
            sortBy: [SortDescriptor(\.score)]
        ),
        modelContext: context
    )
    try await controller.performFetch()

    #expect(controller.snapshot?.itemIDs.map(\.rawValue) == [1, 2])
    #expect(controller.fetchedObjects?.map(\.score) == [10, 20])
    #expect(controller.fetchedQueryValues?.map(\.score) == [10, 20])
    #expect(
        controller.fetchedQueryValue(for: .init(rawValue: 1))?.score == 10
    )
    #expect(controller.contains(.init(rawValue: 1)))
    #expect(controller.contains(.init(rawValue: 3)) == false)
    let firstModel = try #require(controller.fetchedObjects?.first)

    var updates = controller.updates.makeAsyncIterator()
    guard case .initial = await updates.next() else {
        Issue.record("A late subscriber must start with the accepted initial state.")
        return
    }

    var updateTransaction = WebInspectorModelTransaction()
    updateTransaction.append(
        cutoverQuerySchema.upsert(
            record: CutoverQueryRecord(score: 30),
            queryValue: .init(id: .init(rawValue: 1), score: 30),
            canonicalRank: .init(rawValue: 1)
        )
    )
    _ = try await container.modelStoreSink.commit(updateTransaction)

    guard
        case let .changes(from, to, itemChanges, updatedItemIDs) =
            await updates.next()
    else {
        Issue.record("Expected one incremental fetched-results change.")
        return
    }
    #expect(to.rawValue == from.rawValue + 1)
    #expect(updatedItemIDs.map(\.rawValue) == [1])
    #expect(itemChanges.count == 1)
    #expect(controller.snapshot?.itemIDs.map(\.rawValue) == [2, 1])
    #expect(controller.fetchedQueryValues?.map(\.score) == [20, 30])
    #expect(
        controller.fetchedQueryValue(for: .init(rawValue: 1))?.score == 30
    )
    #expect(controller.fetchedObjects?.last === firstModel)

    var rankSwapTransaction = WebInspectorModelTransaction()
    rankSwapTransaction.append(
        cutoverQuerySchema.upsert(
            record: CutoverQueryRecord(score: 30),
            queryValue: .init(id: .init(rawValue: 1), score: 30),
            canonicalRank: .init(rawValue: 2)
        )
    )
    rankSwapTransaction.append(
        cutoverQuerySchema.upsert(
            record: CutoverQueryRecord(score: 20),
            queryValue: .init(id: .init(rawValue: 2), score: 20),
            canonicalRank: .init(rawValue: 1)
        )
    )
    _ = try await container.modelStoreSink.commit(rankSwapTransaction)

    guard
        case let .changes(_, _, rankChanges, rankUpdatedItemIDs) =
            await updates.next()
    else {
        Issue.record("Expected one atomic update for the rank swap.")
        return
    }
    #expect(rankChanges.isEmpty)
    #expect(Set(rankUpdatedItemIDs.map(\.rawValue)) == Set([1, 2]))
    #expect(controller.fetchedObjects?.last === firstModel)

    var deletionTransaction = WebInspectorModelTransaction()
    deletionTransaction.append(
        cutoverQuerySchema.delete(id: .init(rawValue: 2))
    )
    _ = try await container.modelStoreSink.commit(deletionTransaction)

    guard case .changes = await updates.next() else {
        Issue.record("Expected one fetched-results deletion.")
        return
    }
    #expect(controller.contains(.init(rawValue: 1)))
    #expect(controller.contains(.init(rawValue: 2)) == false)
    #expect(controller.snapshot?.itemIDs.map(\.rawValue) == [1])

    await controller.close()
    #expect(await updates.next() == nil)
    await controller.close()
    await #expect(throws: WebInspectorFetchError.contextClosed) {
        try await controller.performFetch()
    }
    await context.close()
    await container.close()
}

@Test
func cancellingOneSharedReplyWaiterDoesNotResolveTheOperation() async throws {
    let reply = WebInspectorContextReply<Int>()
    let cancelledWaiter = Task { try await reply.value() }
    cancelledWaiter.cancel()
    let secondWaiter = Task { try await reply.value() }

    #expect(reply.isPending)
    reply.succeed(42)

    #expect(try await cancelledWaiter.value == 42)
    #expect(try await secondWaiter.value == 42)
}

@Test
func slowFetchedResultsSubscriberReceivesLatestReset() async {
    let publisher = _WebInspectorFetchedResultsUpdatePublisher<Int>()
    var iterator = publisher.sequence().makeAsyncIterator()

    publisher.publish(
        .initial(revision: .init(rawValue: 1), snapshot: .init(itemIDs: [1])),
        revision: .init(rawValue: 1),
        snapshot: .init(itemIDs: [1])
    )
    publisher.publish(
        .changes(
            fromRevision: .init(rawValue: 1),
            toRevision: .init(rawValue: 2),
            itemChanges: [.insert(itemID: 2, at: 1)],
            updatedItemIDs: []
        ),
        revision: .init(rawValue: 2),
        snapshot: .init(itemIDs: [1, 2])
    )
    publisher.publish(
        .changes(
            fromRevision: .init(rawValue: 2),
            toRevision: .init(rawValue: 3),
            itemChanges: [.insert(itemID: 3, at: 2)],
            updatedItemIDs: []
        ),
        revision: .init(rawValue: 3),
        snapshot: .init(itemIDs: [1, 2, 3])
    )

    guard case let .reset(revision, snapshot) = await iterator.next() else {
        Issue.record("Overflow must collapse to one latest reset.")
        return
    }
    #expect(revision.rawValue == 3)
    #expect(snapshot.itemIDs == [1, 2, 3])
    publisher.finish()
    let terminal = await iterator.next()
    #expect(terminal == nil)
}
