import Observation
import Testing
@testable import WebInspectorDataKit

@Test
func heterogeneousModelSourceTransactionCommitsEveryRecordGateBeforePublication()
    async throws
{
    let primaryGate = TransactionPrimaryRecordGate()
    let secondaryGate = TransactionSecondaryRecordGate()
    let core = WebInspectorModelContextCore()
    let owner = TransactionTestOwner(
        primaryGate: primaryGate,
        secondaryGate: secondaryGate
    )

    let initial = try await core.applySourceBatches([
        primaryResetBatch(
            gate: primaryGate,
            revision: 0,
            records: [(1, 10, 1)]
        ),
        secondaryResetBatch(
            gate: secondaryGate,
            revision: 0,
            records: [(10, 100, 1)]
        ),
    ])
    #expect(await owner.commit(initial))
    #expect(await owner.claimPrimary(1))
    #expect(await owner.claimSecondary(10))

    let primaryQuery = try await core.register(TransactionPrimaryModel.self)
    let secondaryQuery = try await core.register(TransactionSecondaryModel.self)
    let commit = try await core.applySourceBatches([
        primaryChangesBatch(
            gate: primaryGate,
            revision: 1,
            records: [.update(id: .init(1), record: .init(value: 11))],
            query: [.update(primaryQueryRecord(id: 1, value: 11, rank: 1))]
        ),
        secondaryChangesBatch(
            gate: secondaryGate,
            revision: 1,
            records: [.update(id: .init(10), record: .init(value: 101))],
            query: [.update(secondaryQueryRecord(id: 10, value: 101, rank: 1))]
        ),
    ])

    #expect(primaryGate.revision == 0)
    #expect(secondaryGate.revision == 0)
    #expect(commit.isPublishedForTesting == false)
    #expect(await owner.commit(commit))
    #expect(primaryGate.revision == 1)
    #expect(secondaryGate.revision == 1)
    #expect(
        await owner.state()
            == .init(primary: [.init(1): 11], secondary: [.init(10): 101])
    )
    #expect(try await primaryQuery.state().snapshot.itemIDs == [.init(1)])
    #expect(try await secondaryQuery.state().snapshot.itemIDs == [.init(10)])
}

@Test
func recordPreparationFailureDiscardsEveryPreparedGateBeforeQueryStaging()
    async throws
{
    let primaryGate = TransactionPrimaryRecordGate()
    let secondaryGate = TransactionSecondaryRecordGate()
    let core = WebInspectorModelContextCore()
    let initial = try await core.applySourceBatches([
        primaryResetBatch(
            gate: primaryGate,
            revision: 0,
            records: [(1, 10, 1)]
        ),
        secondaryResetBatch(
            gate: secondaryGate,
            revision: 0,
            records: [(10, 100, 1)]
        ),
    ])
    #expect(publishConsumingEmptyOwnerMutations(initial))
    let primaryQuery = try await core.register(TransactionPrimaryModel.self)
    let secondaryQuery = try await core.register(TransactionSecondaryModel.self)

    await #expect(throws: WebInspectorModelRecordGateError.invalidUpdate) {
        _ = try await core.applySourceBatches([
            primaryChangesBatch(
                gate: primaryGate,
                revision: 1,
                records: [.update(id: .init(1), record: .init(value: 11))],
                query: [.update(primaryQueryRecord(id: 1, value: 11, rank: 1))]
            ),
            secondaryChangesBatch(
                gate: secondaryGate,
                revision: 1,
                records: [.update(id: .init(99), record: .init(value: 999))],
                query: [.update(secondaryQueryRecord(id: 99, value: 999, rank: 99))]
            ),
        ])
    }

    #expect(primaryGate.revision == 0)
    #expect(primaryGate.record(for: .init(1)) == .init(value: 10))
    #expect(secondaryGate.revision == 0)
    #expect(try await primaryQuery.state().snapshot.itemIDs == [.init(1)])
    #expect(try await secondaryQuery.state().snapshot.itemIDs == [.init(10)])

    let corrected = try await core.applySourceBatches([
        primaryChangesBatch(
            gate: primaryGate,
            revision: 1,
            records: [.update(id: .init(1), record: .init(value: 11))],
            query: [.update(primaryQueryRecord(id: 1, value: 11, rank: 1))]
        ),
        secondaryChangesBatch(
            gate: secondaryGate,
            revision: 1,
            records: [.update(id: .init(10), record: .init(value: 101))],
            query: [.update(secondaryQueryRecord(id: 10, value: 101, rank: 1))]
        ),
    ])
    #expect(publishConsumingEmptyOwnerMutations(corrected))
    #expect(primaryGate.record(for: .init(1)) == .init(value: 11))
    #expect(secondaryGate.record(for: .init(10)) == .init(value: 101))
}

@Test
func transactionRecordGatePreservesClaimBeforeAndApplyBeforeRaces() async throws {
    let gate = TransactionPrimaryRecordGate()
    let core = WebInspectorModelContextCore()
    let initial = try await core.applySourceBatch(
        primaryTypedResetBatch(
            gate: gate,
            revision: 0,
            records: [
                (1, 10, 1),
                (2, 20, 2),
            ]
        )
    )
    #expect(publishConsumingEmptyOwnerMutations(initial))

    let commit = try await core.applySourceBatch(
        primaryTypedChangesBatch(
            gate: gate,
            revision: 1,
            records: [
                .update(id: .init(1), record: .init(value: 11)),
                .update(id: .init(2), record: .init(value: 21)),
            ],
            query: [
                .update(primaryQueryRecord(id: 1, value: 11, rank: 1)),
                .update(primaryQueryRecord(id: 2, value: 21, rank: 2)),
            ]
        )
    )

    #expect(gate.claim(.init(1)) == .init(value: 10))
    var mutations:
        [WebInspectorModelRecordOwnerMutation<
            TransactionPrimaryModel,
            TransactionPrimaryRecord
        >] = []
    var ownerBatchCount = 0
    let didPublish = commit.publish { ownerBatches in
        ownerBatchCount = ownerBatches.count
        mutations = ownerBatches[0].consume(
            as: TransactionPrimaryModel.self,
            recordType: TransactionPrimaryRecord.self
        ) { $0 }
    }
    #expect(didPublish)
    #expect(ownerBatchCount == 1)
    #expect(
        mutations
            == [.update(id: .init(1), record: .init(value: 11))]
    )
    #expect(gate.claim(.init(2)) == .init(value: 21))
}

@Test
func queryDeliveryObservesCommittedRecordsAndConsumedOwnerMutations() async throws {
    let primaryGate = TransactionPrimaryRecordGate()
    let secondaryGate = TransactionSecondaryRecordGate()
    let core = WebInspectorModelContextCore()
    let owner = TransactionTestOwner(
        primaryGate: primaryGate,
        secondaryGate: secondaryGate
    )
    let initial = try await core.applySourceBatches([
        primaryResetBatch(
            gate: primaryGate,
            revision: 0,
            records: [(1, 10, 1)]
        ),
        secondaryResetBatch(
            gate: secondaryGate,
            revision: 0,
            records: [(10, 100, 1)]
        ),
    ])
    #expect(await owner.commit(initial))
    #expect(await owner.claimPrimary(1))
    #expect(await owner.claimSecondary(10))

    let registration = try await core.register(TransactionPrimaryModel.self)
    let sequence = try await registration.updates()
    let delivery = Task {
        var iterator = sequence.makeAsyncIterator()
        _ = try await iterator.next()
        let update = try await iterator.next()
        return (update, await owner.state())
    }
    while try await core.waitingSubscriberCountForTesting(for: registration) == 0 {
        await Task.yield()
    }

    let commit = try await core.applySourceBatches([
        primaryChangesBatch(
            gate: primaryGate,
            revision: 1,
            records: [.update(id: .init(1), record: .init(value: 11))],
            query: [.update(primaryQueryRecord(id: 1, value: 11, rank: 1))]
        ),
        secondaryChangesBatch(
            gate: secondaryGate,
            revision: 1,
            records: [.update(id: .init(10), record: .init(value: 101))],
            query: [.update(secondaryQueryRecord(id: 10, value: 101, rank: 1))]
        ),
    ])
    #expect(commit.isPublishedForTesting == false)
    #expect(primaryGate.record(for: .init(1)) == .init(value: 10))
    #expect(secondaryGate.record(for: .init(10)) == .init(value: 100))

    #expect(await owner.commit(commit))
    let (update, deliveredOwnerState) = try await delivery.value
    guard case let .changes(_, _, _, _, updatedItemIDs) = update else {
        Issue.record("Expected a staged fetched-results change.")
        return
    }
    #expect(updatedItemIDs == [.init(1)])
    #expect(
        deliveredOwnerState
            == .init(primary: [.init(1): 11], secondary: [.init(10): 101])
    )
    #expect(primaryGate.record(for: .init(1)) == .init(value: 11))
    #expect(secondaryGate.record(for: .init(10)) == .init(value: 101))
}

@Test
func abortResolvesPreparedRecordsAndUnblocksConcurrentClose() async throws {
    let gate = TransactionPrimaryRecordGate()
    let core = WebInspectorModelContextCore()
    let initial = try await core.applySourceBatch(
        primaryTypedResetBatch(
            gate: gate,
            revision: 0,
            records: [(1, 10, 1)]
        )
    )
    #expect(publishConsumingEmptyOwnerMutations(initial))

    let commit = try await core.applySourceBatch(
        primaryTypedChangesBatch(
            gate: gate,
            revision: 1,
            records: [.update(id: .init(1), record: .init(value: 11))],
            query: [.update(primaryQueryRecord(id: 1, value: 11, rank: 1))]
        )
    )
    let close = Task {
        await core.close()
    }
    while await core.isClosingForTesting() == false {
        await Task.yield()
    }

    #expect(
        await commit.abort(throwing: TransactionTestFailure.ownerUnavailable)
            == .aborted
    )
    await close.value
    #expect(commit.isAbortedForTesting)
    #expect(gate.revision == 0)
    #expect(gate.record(for: .init(1)) == .init(value: 10))
    #expect(await core.queryEngineCountForTesting() == 0)

    let replacement = try gate.prepareChanges(
        at: 1,
        changes: [.update(id: .init(1), record: .init(value: 11))]
    )
    try replacement.discard()
}

@Test
func ownerPublicationAndAbortRaceHasOnlyAtomicTerminalOutcomes() async throws {
    let primaryGate = TransactionPrimaryRecordGate()
    let owner = TransactionTestOwner(
        primaryGate: primaryGate,
        secondaryGate: TransactionSecondaryRecordGate()
    )
    let core = WebInspectorModelContextCore()
    let initial = try await core.applySourceBatch(
        primaryTypedResetBatch(
            gate: primaryGate,
            revision: 0,
            records: [(1, 10, 1)]
        )
    )
    #expect(await owner.commit(initial))
    #expect(await owner.claimPrimary(1))
    let registration = try await core.register(TransactionPrimaryModel.self)

    let commit = try await core.applySourceBatch(
        primaryTypedChangesBatch(
            gate: primaryGate,
            revision: 1,
            records: [
                .update(id: .init(1), record: .init(value: 11)),
                .insert(id: .init(2), record: .init(value: 20)),
            ],
            query: [
                .update(primaryQueryRecord(id: 1, value: 11, rank: 1)),
                .insert(primaryQueryRecord(id: 2, value: 20, rank: 2)),
            ]
        )
    )

    async let didPublish = owner.commit(commit)
    async let resolution = commit.abort(
        throwing: TransactionTestFailure.ownerUnavailable
    )
    let outcome = await (didPublish, resolution)

    if outcome.0 {
        #expect(outcome.1 == .published)
        #expect(primaryGate.revision == 1)
        #expect(primaryGate.record(for: .init(1)) == .init(value: 11))
        #expect(primaryGate.record(for: .init(2)) == .init(value: 20))
        #expect(
            await owner.state()
                == .init(primary: [.init(1): 11], secondary: [:])
        )
        #expect(
            try await registration.state().snapshot.itemIDs
                == [.init(1), .init(2)]
        )
    } else {
        #expect(outcome.1 == .aborted)
        #expect(primaryGate.revision == 0)
        #expect(primaryGate.record(for: .init(1)) == .init(value: 10))
        #expect(primaryGate.record(for: .init(2)) == nil)
        #expect(
            await owner.state()
                == .init(primary: [.init(1): 10], secondary: [:])
        )
        await #expect(throws: WebInspectorFetchedResultsQueryError.closedRegistration) {
            _ = try await registration.state()
        }
    }
}

@Test
func emptyDeltaAdvancesEveryConfiguredRecordSourceRevision() async throws {
    let primaryGate = TransactionPrimaryRecordGate()
    let secondaryGate = TransactionSecondaryRecordGate()
    let core = WebInspectorModelContextCore()
    let initial = try await core.applySourceBatches([
        primaryResetBatch(gate: primaryGate, revision: 5, records: []),
        secondaryResetBatch(gate: secondaryGate, revision: 5, records: []),
    ])
    #expect(publishConsumingEmptyOwnerMutations(initial))

    for revision in 6...7 {
        let commit = try await core.applySourceBatches([
            primaryChangesBatch(
                gate: primaryGate,
                revision: UInt64(revision),
                records: [],
                query: []
            ),
            secondaryChangesBatch(
                gate: secondaryGate,
                revision: UInt64(revision),
                records: [],
                query: []
            ),
        ])
        var mutationBatchCount = 0
        var everyMutationBatchWasEmpty = false
        let didPublish = commit.publish { mutations in
            mutationBatchCount = mutations.count
            everyMutationBatchWasEmpty = mutations.allSatisfy { batch in
                consumeEmptyOwnerMutationBatch(batch)
            }
        }
        #expect(didPublish)
        #expect(mutationBatchCount == 2)
        #expect(everyMutationBatchWasEmpty)
    }

    #expect(primaryGate.revision == 7)
    #expect(secondaryGate.revision == 7)
}

@Test
func authoritativeResetBridgesCanonicalRevisionGapForEveryModelSource() async throws {
    let primaryGate = TransactionPrimaryRecordGate()
    let secondaryGate = TransactionSecondaryRecordGate()
    let core = WebInspectorModelContextCore()
    let initial = try await core.applySourceBatches([
        primaryResetBatch(gate: primaryGate, revision: 1, records: []),
        secondaryResetBatch(gate: secondaryGate, revision: 1, records: []),
    ])
    #expect(publishConsumingEmptyOwnerMutations(initial))

    let reset = try await core.applySourceBatches([
        primaryResetBatch(
            gate: primaryGate,
            revision: 10,
            records: [(1, 10, 1)]
        ),
        secondaryResetBatch(
            gate: secondaryGate,
            revision: 10,
            records: [(10, 100, 1)]
        ),
    ])
    #expect(publishConsumingEmptyOwnerMutations(reset))
    #expect(primaryGate.revision == 10)
    #expect(secondaryGate.revision == 10)

    let contiguous = try await core.applySourceBatches([
        primaryChangesBatch(
            gate: primaryGate,
            revision: 11,
            records: [],
            query: []
        ),
        secondaryChangesBatch(
            gate: secondaryGate,
            revision: 11,
            records: [],
            query: []
        ),
    ])
    #expect(publishConsumingEmptyOwnerMutations(contiguous))
}

@Test
func modelContextTransactionRunsFromANonMainActorOwner() async throws {
    let owner = NonMainTransactionOwner()
    #expect(try await owner.runTransaction())
}

#if os(macOS)
    @Test
    func queryOnlySourceModeRejectsLaterModelSourceTransactions() async {
        await #expect(processExitsWith: .failure) {
            let core = WebInspectorModelContextCore()
            let queryCommit = try await core.applyBatch(
                WebInspectorFetchedResultsSourceBatch<TransactionPrimaryModel>(
                    canonicalRevision: 0,
                    changes: [
                        .reset([primaryQueryRecord(id: 1, value: 10, rank: 1)])
                    ]
                )
            )
            _ = queryCommit.publish()
            _ = try await core.applySourceBatch(
                primaryTypedResetBatch(
                    gate: TransactionPrimaryRecordGate(),
                    revision: 1,
                    records: [(1, 10, 1)]
                )
            )
        }
    }

    @Test
    func modelSourceModeRejectsLaterQueryOnlyTransactions() async {
        await #expect(processExitsWith: .failure) {
            let gate = TransactionPrimaryRecordGate()
            let core = WebInspectorModelContextCore()
            let commit = try await core.applySourceBatch(
                primaryTypedResetBatch(
                    gate: gate,
                    revision: 0,
                    records: [(1, 10, 1)]
                )
            )
            _ = publishConsumingEmptyOwnerMutations(commit)
            _ = try await core.applyBatch(
                WebInspectorFetchedResultsSourceBatch<TransactionPrimaryModel>(
                    canonicalRevision: 1,
                    changes: [.contentOnly(.init(1))]
                )
            )
        }
    }

    @Test
    func configuredModelSourcesRejectLaterBatchReordering() async {
        await #expect(processExitsWith: .failure) {
            let primaryGate = TransactionPrimaryRecordGate()
            let secondaryGate = TransactionSecondaryRecordGate()
            let core = WebInspectorModelContextCore()
            let initial = try await core.applySourceBatches([
                primaryResetBatch(gate: primaryGate, revision: 0, records: []),
                secondaryResetBatch(gate: secondaryGate, revision: 0, records: []),
            ])
            _ = publishConsumingEmptyOwnerMutations(initial)
            _ = try await core.applySourceBatches([
                secondaryChangesBatch(
                    gate: secondaryGate,
                    revision: 1,
                    records: [],
                    query: []
                ),
                primaryChangesBatch(
                    gate: primaryGate,
                    revision: 1,
                    records: [],
                    query: []
                ),
            ])
        }
    }

    @Test
    func modelSourceResetRejectsMismatchedRecordAndQueryIdentities() async {
        await #expect(processExitsWith: .failure) {
            _ = WebInspectorModelSourceBatch<
                TransactionPrimaryModel,
                TransactionPrimaryRecord
            >(
                recordGate: TransactionPrimaryRecordGate(),
                canonicalRevision: 0,
                records: .reset([.init(1): .init(value: 10)]),
                fetchedResults: WebInspectorFetchedResultsSourceBatch(
                    canonicalRevision: 0,
                    changes: [
                        .reset([primaryQueryRecord(id: 2, value: 20, rank: 2)])
                    ]
                )
            )
        }
    }

    @Test
    func modelSourceDeltaRejectsMismatchedRecordAndQueryOperations() async {
        await #expect(processExitsWith: .failure) {
            _ = WebInspectorModelSourceBatch<
                TransactionPrimaryModel,
                TransactionPrimaryRecord
            >(
                recordGate: TransactionPrimaryRecordGate(),
                canonicalRevision: 1,
                records: .changes([
                    .update(id: .init(1), record: .init(value: 11))
                ]),
                fetchedResults: WebInspectorFetchedResultsSourceBatch(
                    canonicalRevision: 1,
                    changes: [.delete(.init(1))]
                )
            )
        }
    }
#endif

private typealias TransactionPrimaryRecordGate = WebInspectorModelRecordGate<
    TransactionPrimaryModel,
    TransactionPrimaryRecord
>
private typealias TransactionSecondaryRecordGate = WebInspectorModelRecordGate<
    TransactionSecondaryModel,
    TransactionSecondaryRecord
>

private struct TransactionPrimaryID: WebInspectorPersistentIdentifier {
    typealias Model = TransactionPrimaryModel
    let rawValue: Int

    init(_ rawValue: Int) {
        self.rawValue = rawValue
    }
}

private struct TransactionPrimaryQueryValue: Identifiable, Sendable {
    let id: TransactionPrimaryID
    let value: Int
}

@Observable
private final class TransactionPrimaryModel: WebInspectorPersistentModel {
    typealias ID = TransactionPrimaryID
    typealias QueryValue = TransactionPrimaryQueryValue

    nonisolated let id: TransactionPrimaryID

    init(id: TransactionPrimaryID) {
        self.id = id
    }
}

private struct TransactionPrimaryRecord: Equatable, Sendable {
    let value: Int
}

private struct TransactionSecondaryID: WebInspectorPersistentIdentifier {
    typealias Model = TransactionSecondaryModel
    let rawValue: Int

    init(_ rawValue: Int) {
        self.rawValue = rawValue
    }
}

private struct TransactionSecondaryQueryValue: Identifiable, Sendable {
    let id: TransactionSecondaryID
    let value: Int
}

@Observable
private final class TransactionSecondaryModel: WebInspectorPersistentModel {
    typealias ID = TransactionSecondaryID
    typealias QueryValue = TransactionSecondaryQueryValue

    nonisolated let id: TransactionSecondaryID

    init(id: TransactionSecondaryID) {
        self.id = id
    }
}

private struct TransactionSecondaryRecord: Equatable, Sendable {
    let value: Int
}

private actor TransactionTestOwner {
    struct State: Equatable, Sendable {
        var primary: [TransactionPrimaryID: Int] = [:]
        var secondary: [TransactionSecondaryID: Int] = [:]
    }

    private let primaryGate: TransactionPrimaryRecordGate
    private let secondaryGate: TransactionSecondaryRecordGate
    private var current = State()

    init(
        primaryGate: TransactionPrimaryRecordGate,
        secondaryGate: TransactionSecondaryRecordGate
    ) {
        self.primaryGate = primaryGate
        self.secondaryGate = secondaryGate
    }

    func claimPrimary(_ rawID: Int) -> Bool {
        let id = TransactionPrimaryID(rawID)
        guard let record = primaryGate.claim(id) else {
            return false
        }
        current.primary[id] = record.value
        return true
    }

    func claimSecondary(_ rawID: Int) -> Bool {
        let id = TransactionSecondaryID(rawID)
        guard let record = secondaryGate.claim(id) else {
            return false
        }
        current.secondary[id] = record.value
        return true
    }

    func commit(_ commit: WebInspectorModelContextTransactionCommit) -> Bool {
        commit.publish { batches in
            for batch in batches {
                if batch.modelTypeID == ObjectIdentifier(TransactionPrimaryModel.self) {
                    batch.consume(
                        as: TransactionPrimaryModel.self,
                        recordType: TransactionPrimaryRecord.self
                    ) { mutations in
                        for mutation in mutations {
                            switch mutation {
                            case let .update(id, record):
                                current.primary[id] = record.value
                            case let .invalidate(id):
                                current.primary[id] = nil
                            }
                        }
                    }
                } else if batch.modelTypeID
                    == ObjectIdentifier(TransactionSecondaryModel.self)
                {
                    batch.consume(
                        as: TransactionSecondaryModel.self,
                        recordType: TransactionSecondaryRecord.self
                    ) { mutations in
                        for mutation in mutations {
                            switch mutation {
                            case let .update(id, record):
                                current.secondary[id] = record.value
                            case let .invalidate(id):
                                current.secondary[id] = nil
                            }
                        }
                    }
                } else {
                    Issue.record("Received owner mutations for an unknown model type.")
                }
            }
        }
    }

    func state() -> State {
        current
    }
}

private actor NonMainTransactionOwner {
    func runTransaction() async throws -> Bool {
        let gate = TransactionPrimaryRecordGate()
        let core = WebInspectorModelContextCore()
        let commit = try await core.applySourceBatch(
            primaryTypedResetBatch(
                gate: gate,
                revision: 42,
                records: [(1, 10, 1)]
            )
        )
        var ownerMutationCount = -1
        let published = commit.publish { batches in
            ownerMutationCount = batches[0].consume(
                as: TransactionPrimaryModel.self,
                recordType: TransactionPrimaryRecord.self,
                \.count
            )
        }
        return ownerMutationCount == 0 && published && gate.revision == 42
    }
}

private enum TransactionTestFailure: Error {
    case ownerUnavailable
}

private func publishConsumingEmptyOwnerMutations(
    _ commit: WebInspectorModelContextTransactionCommit
) -> Bool {
    commit.publish { batches in
        precondition(
            batches.allSatisfy(consumeEmptyOwnerMutationBatch),
            "A test expected no materialized owner mutations."
        )
    }
}

private func consumeEmptyOwnerMutationBatch(
    _ batch: WebInspectorModelRecordOwnerMutationBatch
) -> Bool {
    if batch.modelTypeID == ObjectIdentifier(TransactionPrimaryModel.self) {
        return batch.consume(
            as: TransactionPrimaryModel.self,
            recordType: TransactionPrimaryRecord.self,
            \.isEmpty
        )
    }
    if batch.modelTypeID == ObjectIdentifier(TransactionSecondaryModel.self) {
        return batch.consume(
            as: TransactionSecondaryModel.self,
            recordType: TransactionSecondaryRecord.self,
            \.isEmpty
        )
    }
    preconditionFailure("Received owner mutations for an unknown test model type.")
}

private func primaryResetBatch(
    gate: TransactionPrimaryRecordGate,
    revision: UInt64,
    records: [(id: Int, value: Int, rank: UInt64)]
) -> AnyWebInspectorModelSourceBatch {
    AnyWebInspectorModelSourceBatch(
        primaryTypedResetBatch(
            gate: gate,
            revision: revision,
            records: records
        )
    )
}

private func primaryTypedResetBatch(
    gate: TransactionPrimaryRecordGate,
    revision: UInt64,
    records: [(id: Int, value: Int, rank: UInt64)]
) -> WebInspectorModelSourceBatch<TransactionPrimaryModel, TransactionPrimaryRecord> {
    WebInspectorModelSourceBatch(
        recordGate: gate,
        canonicalRevision: revision,
        records: .reset(
            Dictionary(
                uniqueKeysWithValues: records.map {
                    (TransactionPrimaryID($0.id), TransactionPrimaryRecord(value: $0.value))
                }
            )
        ),
        fetchedResults: WebInspectorFetchedResultsSourceBatch(
            canonicalRevision: revision,
            changes: [
                .reset(
                    records.map {
                        primaryQueryRecord(
                            id: $0.id,
                            value: $0.value,
                            rank: $0.rank
                        )
                    }
                )
            ]
        )
    )
}

private func primaryChangesBatch(
    gate: TransactionPrimaryRecordGate,
    revision: UInt64,
    records: [WebInspectorModelRecordChange<TransactionPrimaryModel, TransactionPrimaryRecord>],
    query: [WebInspectorFetchedResultsSourceChange<TransactionPrimaryModel>]
) -> AnyWebInspectorModelSourceBatch {
    AnyWebInspectorModelSourceBatch(
        primaryTypedChangesBatch(
            gate: gate,
            revision: revision,
            records: records,
            query: query
        )
    )
}

private func primaryTypedChangesBatch(
    gate: TransactionPrimaryRecordGate,
    revision: UInt64,
    records: [WebInspectorModelRecordChange<TransactionPrimaryModel, TransactionPrimaryRecord>],
    query: [WebInspectorFetchedResultsSourceChange<TransactionPrimaryModel>]
) -> WebInspectorModelSourceBatch<TransactionPrimaryModel, TransactionPrimaryRecord> {
    WebInspectorModelSourceBatch(
        recordGate: gate,
        canonicalRevision: revision,
        records: .changes(records),
        fetchedResults: WebInspectorFetchedResultsSourceBatch(
            canonicalRevision: revision,
            changes: query
        )
    )
}

private func secondaryResetBatch(
    gate: TransactionSecondaryRecordGate,
    revision: UInt64,
    records: [(id: Int, value: Int, rank: UInt64)]
) -> AnyWebInspectorModelSourceBatch {
    AnyWebInspectorModelSourceBatch(
        WebInspectorModelSourceBatch(
            recordGate: gate,
            canonicalRevision: revision,
            records: .reset(
                Dictionary(
                    uniqueKeysWithValues: records.map {
                        (
                            TransactionSecondaryID($0.id),
                            TransactionSecondaryRecord(value: $0.value)
                        )
                    }
                )
            ),
            fetchedResults: WebInspectorFetchedResultsSourceBatch(
                canonicalRevision: revision,
                changes: [
                    .reset(
                        records.map {
                            secondaryQueryRecord(
                                id: $0.id,
                                value: $0.value,
                                rank: $0.rank
                            )
                        }
                    )
                ]
            )
        )
    )
}

private func secondaryChangesBatch(
    gate: TransactionSecondaryRecordGate,
    revision: UInt64,
    records: [WebInspectorModelRecordChange<
        TransactionSecondaryModel,
        TransactionSecondaryRecord
    >],
    query: [WebInspectorFetchedResultsSourceChange<TransactionSecondaryModel>]
) -> AnyWebInspectorModelSourceBatch {
    AnyWebInspectorModelSourceBatch(
        WebInspectorModelSourceBatch(
            recordGate: gate,
            canonicalRevision: revision,
            records: .changes(records),
            fetchedResults: WebInspectorFetchedResultsSourceBatch(
                canonicalRevision: revision,
                changes: query
            )
        )
    )
}

private func primaryQueryRecord(
    id: Int,
    value: Int,
    rank: UInt64
) -> WebInspectorFetchedResultsSourceRecord<TransactionPrimaryModel> {
    WebInspectorFetchedResultsSourceRecord(
        value: TransactionPrimaryQueryValue(
            id: TransactionPrimaryID(id),
            value: value
        ),
        canonicalRank: .init(rawValue: rank)
    )
}

private func secondaryQueryRecord(
    id: Int,
    value: Int,
    rank: UInt64
) -> WebInspectorFetchedResultsSourceRecord<TransactionSecondaryModel> {
    WebInspectorFetchedResultsSourceRecord(
        value: TransactionSecondaryQueryValue(
            id: TransactionSecondaryID(id),
            value: value
        ),
        canonicalRank: .init(rawValue: rank)
    )
}
