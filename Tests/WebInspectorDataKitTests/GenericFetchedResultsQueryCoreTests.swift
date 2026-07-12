import Foundation
import Observation
import Testing
@testable import WebInspectorDataKit

@Test
func genericQueryUsesCanonicalRankForEmptySortAndStableTies() async throws {
    let core = GenericQueryCore(records: [
        queryRecord(id: 30, score: 1, rank: 30),
        queryRecord(id: 10, score: 1, rank: 10),
        queryRecord(id: 20, score: 1, rank: 20),
    ])

    let canonical = try await core.register()
    #expect(try await canonical.state().snapshot.itemIDs == [.init(10), .init(20), .init(30)])
    #expect(try await canonical.state().snapshot.sections.isEmpty)

    let sorted = try await core.register(
        fetchDescriptor: .init(
            sortBy: [SortDescriptor(\.score)]
        ))
    #expect(try await sorted.state().snapshot.itemIDs == [.init(10), .init(20), .init(30)])
}

@Test
func queryVisibleStablePositionUpdatePublishesOnlyTheUpdatedIdentity() async throws {
    let core = GenericQueryCore(records: [
        queryRecord(id: 1, score: 1, optionalScore: 1, rank: 1),
        queryRecord(id: 2, score: 2, optionalScore: 1, rank: 2),
    ])
    let registration = try await core.register(
        fetchDescriptor: .init(
            sortBy: [SortDescriptor(\.score)]
        ))
    var iterator = try await registration.updates().makeAsyncIterator()
    _ = try await iterator.next()
    try await core.resetPerformanceCountersForTesting(for: registration)

    await core.apply(
        .update(
            queryRecord(
                id: 2,
                score: 2,
                optionalScore: 99,
                rank: 2
            )))
    guard
        case let .changes(_, _, sectionChanges, itemChanges, updatedIDs) =
            try await iterator.next()
    else {
        Issue.record("Expected one stable-position update.")
        return
    }
    #expect(sectionChanges.isEmpty)
    #expect(itemChanges.isEmpty)
    #expect(updatedIDs == [.init(2)])
    let counters = try await core.performanceCountersForTesting(for: registration)
    #expect(counters.singleRecordEvaluationCount == 1)
    #expect(counters.snapshotBuildCount == 0)
    #expect(counters.differenceBuildCount == 0)
}

@Test
func genericFlatQueryPublishesInsertDeleteMoveAndUpdatedIdentityDeltas() async throws {
    let core = GenericQueryCore(records: [
        queryRecord(id: 1, score: 10, rank: 1),
        queryRecord(id: 2, score: 20, rank: 2),
        queryRecord(id: 3, score: 30, rank: 3),
    ])
    let registration = try await core.register(
        fetchDescriptor: .init(
            sortBy: [SortDescriptor(\.score)]
        ))
    var iterator = try await registration.updates().makeAsyncIterator()
    #expect(
        try await iterator.next()
            == .initial(
                revision: 0,
                snapshot: .init(itemIDs: [.init(1), .init(2), .init(3)])
            ))

    await core.apply(.contentOnly(.init(2)))
    guard
        case let .changes(from, to, sectionChanges, itemChanges, updatedIDs) =
            try await iterator.next()
    else {
        Issue.record("Expected a content-only fetched-results change.")
        return
    }
    #expect(from == 0)
    #expect(to == 1)
    #expect(sectionChanges.isEmpty)
    #expect(itemChanges.isEmpty)
    #expect(updatedIDs == [.init(2)])

    await core.apply(.update(queryRecord(id: 3, score: 5, rank: 3)))
    guard
        case let .changes(_, moveRevision, _, moveChanges, movedUpdates) =
            try await iterator.next()
    else {
        Issue.record("Expected a fetched-results move.")
        return
    }
    #expect(moveRevision == 2)
    #expect(
        moveChanges == [
            .move(
                itemID: .init(3),
                from: .init(section: 0, item: 2),
                to: .init(section: 0, item: 0)
            )
        ])
    #expect(movedUpdates == [.init(3)])

    await core.apply(.insert(queryRecord(id: 4, score: 15, rank: 4)))
    guard
        case let .changes(_, insertRevision, _, insertChanges, _) =
            try await iterator.next()
    else {
        Issue.record("Expected a fetched-results insertion.")
        return
    }
    #expect(insertRevision == 3)
    #expect(
        insertChanges == [
            .insert(
                itemID: .init(4),
                indexPath: .init(section: 0, item: 2)
            )
        ])

    await core.apply(.delete(.init(1)))
    guard
        case let .changes(_, deleteRevision, _, deleteChanges, _) =
            try await iterator.next()
    else {
        Issue.record("Expected a fetched-results deletion.")
        return
    }
    #expect(deleteRevision == 4)
    #expect(
        deleteChanges == [
            .delete(
                itemID: .init(1),
                indexPath: .init(section: 0, item: 1)
            )
        ])
    #expect(
        try await registration.state().snapshot.itemIDs
            == [.init(3), .init(4), .init(2)]
    )
}

@Test
func genericQueryAppliesOffsetAndLimitBeforePublishingDeltas() async throws {
    let core = GenericQueryCore(
        records: (1...5).map {
            queryRecord(id: $0, score: $0 * 10, rank: UInt64($0))
        })
    var descriptor = WebInspectorFetchDescriptor<GenericQueryModel>(
        sortBy: [SortDescriptor(\.score)]
    )
    descriptor.fetchOffset = 1
    descriptor.fetchLimit = 2
    let registration = try await core.register(fetchDescriptor: descriptor)
    var iterator = try await registration.updates().makeAsyncIterator()
    #expect(
        try await iterator.next()
            == .initial(
                revision: 0,
                snapshot: .init(itemIDs: [.init(2), .init(3)])
            ))

    try await core.resetPerformanceCountersForTesting(for: registration)
    await core.apply(.contentOnly(.init(5)))
    #expect(try await registration.state().revision == 0)
    let invisibleCounters = try await core.performanceCountersForTesting(
        for: registration
    )
    #expect(invisibleCounters.contentOnlyVisitCount == 1)
    #expect(invisibleCounters.snapshotBuildCount == 0)
    #expect(invisibleCounters.publicationCount == 0)

    await core.apply(.insert(queryRecord(id: 6, score: 5, rank: 6)))
    guard case let .changes(_, _, _, itemChanges, _) = try await iterator.next() else {
        Issue.record("Expected the window to shift.")
        return
    }
    #expect(
        itemChanges == [
            .delete(
                itemID: .init(3),
                indexPath: .init(section: 0, item: 1)
            ),
            .insert(
                itemID: .init(1),
                indexPath: .init(section: 0, item: 0)
            ),
        ])
    #expect(try await registration.state().snapshot.itemIDs == [.init(1), .init(2)])

    descriptor.fetchLimit = 0
    let emptyCandidate = try await registration.prepareReplacement(descriptor)
    let emptyState = try await registration.commitReplacement(emptyCandidate)
    #expect(emptyState.snapshot.itemIDs.isEmpty)
}

@Test
func sourceResetPublishesACompleteDeltaInsteadOfAnUnconditionalReset() async throws {
    let core = GenericQueryCore(records: [
        queryRecord(id: 1, score: 1, rank: 1),
        queryRecord(id: 2, score: 2, rank: 2),
    ])
    let registration = try await core.register()
    var iterator = try await registration.updates().makeAsyncIterator()
    _ = try await iterator.next()

    await core.apply(
        .reset([
            queryRecord(id: 2, score: 20, rank: 2),
            queryRecord(id: 3, score: 3, rank: 3),
        ]))
    guard
        case let .changes(from, to, _, itemChanges, updatedIDs) =
            try await iterator.next()
    else {
        Issue.record("A contiguous source reset must remain a delta.")
        return
    }
    #expect(from == 0)
    #expect(to == 1)
    #expect(
        itemChanges == [
            .delete(
                itemID: .init(1),
                indexPath: .init(section: 0, item: 0)
            ),
            .insert(
                itemID: .init(3),
                indexPath: .init(section: 0, item: 1)
            ),
        ])
    #expect(updatedIDs == [.init(2)])
    #expect(try await registration.state().snapshot.itemIDs == [.init(2), .init(3)])
}

@Test
func genericSectionedQueryUsesFirstOccurrenceOrderAndPublishesSectionChanges() async throws {
    let core = GenericQueryCore(records: [
        queryRecord(id: 1, score: 1, group: "B", rank: 1),
        queryRecord(id: 2, score: 2, group: "B", rank: 2),
        queryRecord(id: 3, score: 3, group: "A", rank: 3),
    ])
    let sectionExpression: Expression<GenericQueryValue, String> = #Expression {
        $0.group
    }
    let registration = try await core.register(
        fetchDescriptor: .init(sortBy: [SortDescriptor(\.score)]),
        sectionBy: sectionExpression
    )
    var iterator = try await registration.updates().makeAsyncIterator()
    guard case let .initial(_, snapshot) = try await iterator.next() else {
        Issue.record("Expected sectioned initial state.")
        return
    }
    #expect(snapshot.sectionNames == ["B", "A"])
    #expect(snapshot.sections.map(\.itemIDs) == [[.init(1), .init(2)], [.init(3)]])

    await core.apply(
        .update(
            queryRecord(
                id: 3,
                score: 0,
                group: "A",
                rank: 3
            )))
    guard
        case let .changes(_, _, sectionChanges, itemChanges, updatedIDs) =
            try await iterator.next()
    else {
        Issue.record("Expected a section-order change.")
        return
    }
    #expect(
        sectionChanges == [.move(sectionName: "A", from: 1, to: 0)]
            || sectionChanges == [.move(sectionName: "B", from: 0, to: 1)]
    )
    #expect(
        itemChanges.contains(
            .move(
                itemID: .init(3),
                from: .init(section: 1, item: 0),
                to: .init(section: 0, item: 0)
            ))
    )
    #expect(updatedIDs == [.init(3)])

    await core.apply(.delete(.init(3)))
    guard case let .changes(_, _, deletedSections, _, _) = try await iterator.next() else {
        Issue.record("Expected a section deletion.")
        return
    }
    #expect(deletedSections == [.delete(sectionName: "A", index: 0)])

    await core.apply(
        .insert(
            queryRecord(
                id: 4,
                score: 4,
                group: "C",
                rank: 4
            )))
    guard case let .changes(_, _, insertedSections, _, _) = try await iterator.next() else {
        Issue.record("Expected a section insertion.")
        return
    }
    #expect(insertedSections == [.insert(sectionName: "C", index: 1)])
}

@Test
func predicateFailureTerminatesOnlyItsRegistration() async throws {
    let core = GenericQueryCore(records: [
        queryRecord(id: 1, score: 1, optionalScore: 1, rank: 1)
    ])
    let failing = try await core.register(
        fetchDescriptor: .init(
            predicate: #Predicate { $0.optionalScore! > 0 }
        ))
    let sibling = try await core.register()
    var failingIterator = try await failing.updates().makeAsyncIterator()
    var siblingIterator = try await sibling.updates().makeAsyncIterator()
    _ = try await failingIterator.next()
    _ = try await siblingIterator.next()

    await core.apply(
        .update(
            queryRecord(
                id: 1,
                score: 1,
                optionalScore: nil,
                rank: 1
            )))

    await #expect(throws: PredicateError.self) {
        _ = try await failingIterator.next()
    }
    guard
        case let .changes(_, _, _, siblingChanges, updatedIDs) =
            try await siblingIterator.next()
    else {
        Issue.record("Expected the sibling registration to remain active.")
        return
    }
    #expect(siblingChanges.isEmpty)
    #expect(updatedIDs == [.init(1)])
    #expect(await core.registrationCountForTesting() == 1)
}

@Test
func predicateFailureRejectsInitialRegistrationWithoutInstallingIt() async throws {
    let core = GenericQueryCore(records: [
        queryRecord(id: 1, score: 1, optionalScore: nil, rank: 1)
    ])

    await #expect(throws: PredicateError.self) {
        _ = try await core.register(
            fetchDescriptor: .init(
                predicate: #Predicate { $0.optionalScore! > 0 }
            ))
    }
    #expect(await core.registrationCountForTesting() == 0)
}

@Test
func descriptorCandidatesPublishOnlyAfterCurrentAtomicCommit() async throws {
    let core = GenericQueryCore(
        records: (1...3).map {
            queryRecord(id: $0, score: $0, rank: UInt64($0))
        })
    let registration = try await core.register()
    var iterator = try await registration.updates().makeAsyncIterator()
    _ = try await iterator.next()

    let one = 1
    let first = try await registration.prepareReplacement(
        .init(
            predicate: #Predicate { $0.score > one }
        ))
    let two = 2
    let second = try await registration.prepareReplacement(
        .init(
            predicate: #Predicate { $0.score > two }
        ))

    await #expect(throws: WebInspectorFetchedResultsQueryCoreError.staleCandidate) {
        _ = try await registration.commitReplacement(first)
    }
    #expect(try await registration.state().revision == 0)
    await registration.discardReplacement(second)
    #expect(try await registration.state().snapshot.itemIDs.count == 3)

    let committed = try await registration.prepareReplacement(
        .init(
            predicate: #Predicate { $0.score > one }
        ))
    let state = try await registration.commitReplacement(committed)
    #expect(state.revision == 1)
    #expect(state.snapshot.itemIDs == [.init(2), .init(3)])
    guard case let .changes(from, to, _, itemChanges, _) = try await iterator.next() else {
        Issue.record("Expected one committed descriptor delta.")
        return
    }
    #expect(from == 0)
    #expect(to == 1)
    #expect(itemChanges.count == 1)

    let cancellationGate = AsyncStream<Void>.makeStream()
    let cancelled = Task {
        var gateIterator = cancellationGate.stream.makeAsyncIterator()
        _ = await gateIterator.next()
        return try await registration.prepareReplacement(.init())
    }
    cancelled.cancel()
    cancellationGate.continuation.finish()
    await #expect(throws: CancellationError.self) {
        _ = try await cancelled.value
    }
    #expect(await core.registrationCountForTesting() == 1)
    #expect(try await registration.state().revision == 1)
}

@Test
func descriptorCandidateTracksSourceMutationsUntilAtomicCommit() async throws {
    let core = GenericQueryCore(records: [
        queryRecord(id: 1, score: 1, rank: 1),
        queryRecord(id: 2, score: 2, rank: 2),
    ])
    let registration = try await core.register()
    var iterator = try await registration.updates().makeAsyncIterator()
    _ = try await iterator.next()

    let minimumScore = 1
    let candidate = try await registration.prepareReplacement(
        .init(
            predicate: #Predicate { $0.score > minimumScore }
        ))

    await core.apply(.insert(queryRecord(id: 3, score: 3, rank: 3)))
    guard
        case let .changes(_, sourceRevision, _, sourceChanges, _) =
            try await iterator.next()
    else {
        Issue.record("Expected the active query to publish the source insertion.")
        return
    }
    #expect(sourceRevision == 1)
    #expect(
        sourceChanges == [
            .insert(
                itemID: .init(3),
                indexPath: .init(section: 0, item: 2)
            )
        ])

    let committed = try await registration.commitReplacement(candidate)
    #expect(committed.revision == 2)
    #expect(committed.snapshot.itemIDs == [.init(2), .init(3)])
    guard
        case let .changes(_, commitRevision, _, commitChanges, _) =
            try await iterator.next()
    else {
        Issue.record("Expected one candidate commit delta.")
        return
    }
    #expect(commitRevision == 2)
    #expect(
        commitChanges == [
            .delete(
                itemID: .init(1),
                indexPath: .init(section: 0, item: 0)
            )
        ])
}

@Test
func capacityOneSubscribersRebaseOnlyWhenAResetIsConsumed() async throws {
    let core = GenericQueryCore(records: [
        queryRecord(id: 1, score: 1, rank: 1)
    ])
    let registration = try await core.register()
    let pendingSequence = try await registration.updates()

    await core.apply(.contentOnly(.init(1)))
    await core.apply(.contentOnly(.init(1)))
    var counters = try await core.performanceCountersForTesting(for: registration)
    #expect(counters.rebaseSnapshotCount == 0)

    var pendingIterator = pendingSequence.makeAsyncIterator()
    guard case let .initial(revision, snapshot) = try await pendingIterator.next() else {
        Issue.record("Expected an owner-atomic initial rebase.")
        return
    }
    #expect(revision == 2)
    #expect(snapshot.itemIDs == [.init(1)])
    counters = try await core.performanceCountersForTesting(for: registration)
    #expect(counters.rebaseSnapshotCount == 1)

    let waitingSequence = try await registration.updates()
    let waiting = Task {
        var iterator = waitingSequence.makeAsyncIterator()
        let initial = try await iterator.next()
        let change = try await iterator.next()
        return (initial, change)
    }
    while try await core.waitingSubscriberCountForTesting(for: registration) == 0 {
        await Task.yield()
    }
    await core.apply(.contentOnly(.init(1)))
    let waitingValues = try await waiting.value
    #expect(
        waitingValues.0
            == .initial(revision: 2, snapshot: .init(itemIDs: [.init(1)]))
    )
    guard case let .changes(from, to, _, _, _) = waitingValues.1 else {
        Issue.record("Expected one contiguous change for a waiting subscriber.")
        return
    }
    #expect(from == 2)
    #expect(to == 3)

    let slowSequence = try await registration.updates()
    var slowIterator = slowSequence.makeAsyncIterator()
    #expect(
        try await slowIterator.next()
            == .initial(revision: 3, snapshot: .init(itemIDs: [.init(1)]))
    )
    await core.apply(.contentOnly(.init(1)))
    await core.apply(.contentOnly(.init(1)))
    await core.apply(.contentOnly(.init(1)))
    counters = try await core.performanceCountersForTesting(for: registration)
    #expect(counters.rebaseSnapshotCount == 1)
    guard case let .reset(resetRevision, resetSnapshot) = try await slowIterator.next() else {
        Issue.record("Expected exactly one latest reset for the slow subscriber.")
        return
    }
    #expect(resetRevision == 6)
    #expect(resetSnapshot.itemIDs == [.init(1)])
    counters = try await core.performanceCountersForTesting(for: registration)
    #expect(counters.rebaseSnapshotCount == 2)
}

@Test
func registeredCanonicalFlatQueryPublishesTenThousandAppendsWithoutSnapshots()
    async throws
{
    let core = GenericQueryCore()
    let registration = try await core.register()
    var iterator = try await registration.updates().makeAsyncIterator()
    guard case let .initial(_, retainedInitialSnapshot) = try await iterator.next() else {
        Issue.record("Expected the initial flat snapshot.")
        return
    }
    try await core.resetPerformanceCountersForTesting(for: registration)
    await core.resetSourcePerformanceCountersForTesting()

    for id in 0..<10_000 {
        await core.apply(
            .insert(
                queryRecord(
                    id: id,
                    score: id,
                    rank: UInt64(id)
                )))
    }

    var queryCounters = try await core.performanceCountersForTesting(
        for: registration
    )
    #expect(queryCounters.snapshotBuildCount == 0)
    #expect(queryCounters.differenceBuildCount == 0)
    #expect(queryCounters.snapshotMaterializedItemCount == 0)
    #expect(queryCounters.rebaseSnapshotCount == 0)
    #expect(queryCounters.publicationCount == 10_000)
    #expect(queryCounters.canonicalFlatAppendCount == 10_000)
    #expect(retainedInitialSnapshot.itemIDs.isEmpty)

    let sourceCounters = await core.sourcePerformanceCountersForTesting()
    #expect(sourceCounters.canonicalRankLookupCount == 10_000)
    #expect(sourceCounters.canonicalAppendCount == 10_000)
    #expect(sourceCounters.canonicalBinarySearchInsertionCount == 0)

    let materializedState = try await registration.state()
    #expect(materializedState.snapshot.itemIDs.count == 10_000)
    queryCounters = try await core.performanceCountersForTesting(
        for: registration
    )
    #expect(queryCounters.snapshotBuildCount == 1)
    #expect(queryCounters.snapshotMaterializedItemCount == 10_000)

    try await core.resetPerformanceCountersForTesting(for: registration)
    await core.apply(
        .insert(
            queryRecord(
                id: 10_000,
                score: 10_000,
                rank: 10_000
            )))
    queryCounters = try await core.performanceCountersForTesting(
        for: registration
    )
    #expect(queryCounters.snapshotBuildCount == 0)
    #expect(queryCounters.differenceBuildCount == 0)
    #expect(queryCounters.snapshotMaterializedItemCount == 0)
    #expect(queryCounters.publicationCount == 1)
    #expect(queryCounters.canonicalFlatAppendCount == 1)
    #expect(materializedState.snapshot.itemIDs.count == 10_000)

    try await core.resetPerformanceCountersForTesting(for: registration)
    await core.apply(
        .update(
            queryRecord(
                id: 5_000,
                score: 50_000,
                rank: 5_000
            )))
    await core.apply(.delete(.init(5_000)))
    queryCounters = try await core.performanceCountersForTesting(
        for: registration
    )
    #expect(queryCounters.snapshotBuildCount == 0)
    #expect(queryCounters.differenceBuildCount == 0)
    #expect(queryCounters.snapshotMaterializedItemCount == 0)
    #expect(queryCounters.publicationCount == 2)
    #expect(queryCounters.canonicalFlatStableUpdateCount == 1)
    #expect(queryCounters.canonicalFlatDeleteCount == 1)
}

@Test
func sequentialSourceInsertionsUseConstantTimeRankValidationAndAppendFastPath()
    async throws
{
    let core = GenericQueryCore()

    for id in 0..<10_000 {
        await core.apply(
            .insert(
                queryRecord(
                    id: id,
                    score: id,
                    rank: UInt64(id * 2)
                )))
    }

    var counters = await core.sourcePerformanceCountersForTesting()
    #expect(counters.canonicalRankLookupCount == 10_000)
    #expect(counters.canonicalAppendCount == 10_000)
    #expect(counters.canonicalBinarySearchInsertionCount == 0)

    await core.apply(
        .insert(
            queryRecord(
                id: 10_000,
                score: 10_000,
                rank: 1
            )))
    counters = await core.sourcePerformanceCountersForTesting()
    #expect(counters.canonicalRankLookupCount == 10_001)
    #expect(counters.canonicalAppendCount == 10_000)
    #expect(counters.canonicalBinarySearchInsertionCount == 1)

    let registration = try await core.register()
    let state = try await registration.state()
    #expect(Array(state.snapshot.itemIDs.prefix(3)) == [.init(0), .init(10_000), .init(1)])
}

@Test
func tenThousandRecordFilteringAndDiffingStayInTheGenericActorCore() async throws {
    let records = (0..<10_000).map {
        queryRecord(
            id: $0,
            score: 10_000 - $0,
            group: String($0 % 10),
            rank: UInt64($0)
        )
    }
    let core = await Task.detached {
        GenericQueryCore(records: records)
    }.value
    let registration = try await core.register(
        fetchDescriptor: .init(
            sortBy: [SortDescriptor(\.score)]
        ))
    try await core.resetPerformanceCountersForTesting(for: registration)

    await Task.detached {
        await core.apply(.contentOnly(.init(5_000)))
    }.value
    var counters = try await core.performanceCountersForTesting(for: registration)
    #expect(counters.contentOnlyVisitCount == 1)
    #expect(counters.fullEvaluationRecordCount == 0)
    #expect(counters.snapshotBuildCount == 0)
    #expect(counters.publicationCount == 1)

    try await core.resetPerformanceCountersForTesting(for: registration)
    await Task.detached {
        await core.apply(
            .update(
                queryRecord(
                    id: 5_000,
                    score: 5_000,
                    group: "0",
                    rank: 5_000
                )))
    }.value
    counters = try await core.performanceCountersForTesting(for: registration)
    #expect(counters.singleRecordEvaluationCount == 1)
    #expect(counters.fullEvaluationRecordCount == 0)
    #expect(counters.snapshotBuildCount == 0)
    #expect(counters.publicationCount == 1)

    try await core.resetPerformanceCountersForTesting(for: registration)
    await Task.detached {
        await core.apply(.reset(Array(records.reversed())))
    }.value
    counters = try await core.performanceCountersForTesting(for: registration)
    #expect(counters.fullEvaluationCount == 1)
    #expect(counters.fullEvaluationRecordCount == 10_000)
    #expect(counters.snapshotBuildCount == 1)
    #expect(counters.differenceBuildCount == 1)
}

private typealias GenericQueryCore = WebInspectorFetchedResultsQueryCore<GenericQueryModel>

private struct GenericQueryID: WebInspectorPersistentIdentifier {
    typealias Model = GenericQueryModel
    let rawValue: Int

    init(_ rawValue: Int) {
        self.rawValue = rawValue
    }
}

private struct GenericQueryValue: Identifiable, Sendable {
    let id: GenericQueryID
    let score: Int
    let optionalScore: Int?
    let group: String
}

@Observable
private final class GenericQueryModel: WebInspectorPersistentModel {
    typealias ID = GenericQueryID
    typealias QueryValue = GenericQueryValue

    nonisolated let id: GenericQueryID

    init(id: GenericQueryID) {
        self.id = id
    }
}

private func queryRecord(
    id: Int,
    score: Int,
    optionalScore: Int? = 1,
    group: String = "default",
    rank: UInt64
) -> WebInspectorFetchedResultsSourceRecord<GenericQueryModel> {
    WebInspectorFetchedResultsSourceRecord(
        value: GenericQueryValue(
            id: GenericQueryID(id),
            score: score,
            optionalScore: optionalScore,
            group: group
        ),
        canonicalRank: WebInspectorFetchedResultsCanonicalRank(rawValue: rank)
    )
}
