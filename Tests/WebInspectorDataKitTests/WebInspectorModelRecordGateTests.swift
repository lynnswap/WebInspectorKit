import Observation
import Testing
@testable import WebInspectorDataKit

@Test
func modelRecordLookupDoesNotClaimMissingOrExistingRecords() throws {
    let gate = TestRecordGate()
    let initial = try gate.prepareReset(
        at: 4,
        records: [.init(1): .init(value: 10)]
    )

    #expect(gate.record(for: .init(1)) == nil)
    #expect(gate.claim(.init(1)) == nil)
    #expect(try initial.apply().isEmpty)
    #expect(gate.record(for: .init(1)) == .init(value: 10))

    let update = try gate.prepareChanges(
        at: 5,
        changes: [.update(id: .init(1), record: .init(value: 11))]
    )
    #expect(try update.apply().isEmpty)
    #expect(gate.record(for: .init(1)) == .init(value: 11))

    let missingClaim = gate.claim(.init(2))
    #expect(missingClaim == nil)
    let insertion = try gate.prepareChanges(
        at: 6,
        changes: [.insert(id: .init(2), record: .init(value: 20))]
    )
    #expect(gate.record(for: .init(2)) == nil)
    #expect(gate.claim(.init(2)) == nil)
    #expect(try insertion.apply().isEmpty)
    #expect(gate.claim(.init(2)) == .init(value: 20))
}

@Test
func modelRecordClaimBeforeApplyReturnsFinalOwnerMutation() throws {
    let gate = try initializedRecordGate(
        revision: 10,
        records: [.init(1): .init(value: 10)]
    )
    let commit = try gate.prepareChanges(
        at: 11,
        changes: [.update(id: .init(1), record: .init(value: 99))]
    )

    #expect(gate.record(for: .init(1)) == .init(value: 10))
    #expect(gate.claim(.init(1)) == .init(value: 10))
    #expect(
        try commit.apply()
            == [.update(id: .init(1), record: .init(value: 99))]
    )
    #expect(gate.record(for: .init(1)) == .init(value: 99))
}

@Test
func modelRecordApplyBeforeClaimExposesOnlyTheFinalRecord() throws {
    let gate = try initializedRecordGate(
        revision: 10,
        records: [.init(1): .init(value: 10)]
    )
    let commit = try gate.prepareChanges(
        at: 11,
        changes: [.update(id: .init(1), record: .init(value: 99))]
    )

    #expect(try commit.apply().isEmpty)
    #expect(gate.claim(.init(1)) == .init(value: 99))

    let next = try gate.prepareChanges(
        at: 12,
        changes: [.update(id: .init(1), record: .init(value: 100))]
    )
    #expect(
        try next.apply()
            == [.update(id: .init(1), record: .init(value: 100))]
    )
}

@Test
func modelRecordDeleteInvalidatesOnlyAClaimedIdentity() throws {
    let gate = try initializedRecordGate(
        revision: 1,
        records: [
            .init(1): .init(value: 10),
            .init(2): .init(value: 20),
        ]
    )
    #expect(gate.claim(.init(1)) != nil)

    let commit = try gate.prepareChanges(
        at: 2,
        changes: [
            .delete(id: .init(1)),
            .delete(id: .init(2)),
        ]
    )
    #expect(try commit.apply() == [.invalidate(id: .init(1))])
    #expect(gate.record(for: .init(1)) == nil)
    #expect(gate.record(for: .init(2)) == nil)
}

@Test
func modelRecordResetUpdatesSurvivorsAndInvalidatesRemovedClaims() throws {
    let gate = try initializedRecordGate(
        revision: 7,
        records: [
            .init(1): .init(value: 10),
            .init(2): .init(value: 20),
        ]
    )
    #expect(gate.claim(.init(1)) != nil)
    #expect(gate.claim(.init(2)) != nil)

    let reset = try gate.prepareReset(
        at: 20,
        records: [
            .init(1): .init(value: 11),
            .init(3): .init(value: 30),
        ]
    )
    let mutations = try reset.apply()
    #expect(mutations.count == 2)
    #expect(mutations.contains(.update(id: .init(1), record: .init(value: 11))))
    #expect(mutations.contains(.invalidate(id: .init(2))))
    #expect(gate.record(for: .init(2)) == nil)
    #expect(gate.record(for: .init(3)) == .init(value: 30))

    let survivorUpdate = try gate.prepareChanges(
        at: 21,
        changes: [.update(id: .init(1), record: .init(value: 12))]
    )
    #expect(
        try survivorUpdate.apply()
            == [.update(id: .init(1), record: .init(value: 12))]
    )
    let removedReinsert = try gate.prepareChanges(
        at: 22,
        changes: [.insert(id: .init(2), record: .init(value: 200))]
    )
    #expect(try removedReinsert.apply().isEmpty)
}

@Test
func modelRecordDiscardLeavesStateAndRevisionUnchanged() throws {
    let gate = try initializedRecordGate(
        revision: 10,
        records: [.init(1): .init(value: 10)]
    )
    let discarded = try gate.prepareChanges(
        at: 11,
        changes: [.update(id: .init(1), record: .init(value: 11))]
    )
    try discarded.discard()

    #expect(gate.revision == 10)
    #expect(gate.record(for: .init(1)) == .init(value: 10))
    #expect(throws: WebInspectorModelRecordGateError.commitResolved) {
        _ = try discarded.apply()
    }
    #expect(throws: WebInspectorModelRecordGateError.commitResolved) {
        try discarded.discard()
    }

    let replacement = try gate.prepareChanges(
        at: 11,
        changes: [.update(id: .init(1), record: .init(value: 11))]
    )
    #expect(try replacement.apply().isEmpty)
    #expect(gate.revision == 11)
    #expect(gate.record(for: .init(1)) == .init(value: 11))
    #expect(throws: WebInspectorModelRecordGateError.commitResolved) {
        _ = try replacement.apply()
    }
}

@Test
func modelRecordGateRejectsInvalidRevisionPreparation() throws {
    let gate = TestRecordGate()
    #expect(throws: WebInspectorModelRecordGateError.initialRevisionRequiresReset) {
        _ = try gate.prepareChanges(at: 1, changes: [])
    }

    _ = try gate.prepareReset(at: 10, records: [:]).apply()
    #expect(
        throws: WebInspectorModelRecordGateError.staleRevision(
            current: 10,
            proposed: 10
        )
    ) {
        _ = try gate.prepareReset(at: 10, records: [:])
    }
    #expect(
        throws: WebInspectorModelRecordGateError.noncontiguousRevision(
            expected: 11,
            proposed: 12
        )
    ) {
        _ = try gate.prepareChanges(at: 12, changes: [])
    }

    let gapReset = try gate.prepareReset(at: 30, records: [:])
    #expect(throws: WebInspectorModelRecordGateError.commitOutstanding) {
        _ = try gate.prepareChanges(at: 11, changes: [])
    }
    _ = try gapReset.apply()
    #expect(gate.revision == 30)
    _ = try gate.prepareChanges(at: 31, changes: []).apply()
    #expect(gate.revision == 31)
}

@Test
func modelRecordGateRejectsInvalidAuthoritativeChanges() throws {
    let gate = try initializedRecordGate(
        revision: 1,
        records: [.init(1): .init(value: 10)]
    )
    #expect(throws: WebInspectorModelRecordGateError.invalidInsert) {
        _ = try gate.prepareChanges(
            at: 2,
            changes: [.insert(id: .init(1), record: .init(value: 11))]
        )
    }
    #expect(throws: WebInspectorModelRecordGateError.invalidUpdate) {
        _ = try gate.prepareChanges(
            at: 2,
            changes: [.update(id: .init(2), record: .init(value: 20))]
        )
    }
    #expect(throws: WebInspectorModelRecordGateError.invalidDelete) {
        _ = try gate.prepareChanges(
            at: 2,
            changes: [.delete(id: .init(2))]
        )
    }
    #expect(throws: WebInspectorModelRecordGateError.duplicateChange) {
        _ = try gate.prepareChanges(
            at: 2,
            changes: [
                .update(id: .init(1), record: .init(value: 11)),
                .delete(id: .init(1)),
            ]
        )
    }
    #expect(gate.revision == 1)
    #expect(gate.record(for: .init(1)) == .init(value: 10))
}

@Test
func modelRecordGateCloseInvalidatesClaimsAndResolvesPreparedCommit() throws {
    let gate = try initializedRecordGate(
        revision: 1,
        records: [
            .init(1): .init(value: 10),
            .init(2): .init(value: 20),
        ]
    )
    #expect(gate.claim(.init(1)) != nil)
    #expect(gate.claim(.init(2)) != nil)
    let prepared = try gate.prepareChanges(
        at: 2,
        changes: [.update(id: .init(1), record: .init(value: 11))]
    )

    let invalidations = gate.close()
    #expect(invalidations.count == 2)
    #expect(invalidations.contains(.invalidate(id: .init(1))))
    #expect(invalidations.contains(.invalidate(id: .init(2))))
    #expect(gate.record(for: .init(1)) == nil)
    #expect(gate.claim(.init(2)) == nil)
    #expect(gate.close().isEmpty)
    #expect(throws: WebInspectorModelRecordGateError.commitResolved) {
        _ = try prepared.apply()
    }
    #expect(throws: WebInspectorModelRecordGateError.commitResolved) {
        try prepared.discard()
    }
    #expect(throws: WebInspectorModelRecordGateError.closed) {
        _ = try gate.prepareReset(at: 3, records: [:])
    }
}

@Test
func modelRecordCommitApplyAndDiscardRaceResolvesExactlyOnce() async throws {
    let gate = try initializedRecordGate(
        revision: 1,
        records: [.init(1): .init(value: 10)]
    )
    let commit = try gate.prepareChanges(
        at: 2,
        changes: [.update(id: .init(1), record: .init(value: 20))]
    )

    async let applySucceeded = attemptApply(commit)
    async let discardSucceeded = attemptDiscard(commit)
    let outcomes = await (applySucceeded, discardSucceeded)
    let successCount = [outcomes.0, outcomes.1].count(where: { $0 })
    #expect(successCount == 1)
    if outcomes.0 {
        #expect(gate.revision == 2)
        #expect(gate.record(for: .init(1)) == .init(value: 20))
    } else {
        #expect(gate.revision == 1)
        #expect(gate.record(for: .init(1)) == .init(value: 10))
    }
}

private typealias TestRecordGate = WebInspectorModelRecordGate<RecordGateTestModel, TestRecord>
private typealias TestRecordCommit = WebInspectorModelRecordGateCommit<
    RecordGateTestModel,
    TestRecord
>

private struct RecordGateTestID: WebInspectorPersistentIdentifier {
    typealias Model = RecordGateTestModel
    let rawValue: Int

    init(_ rawValue: Int) {
        self.rawValue = rawValue
    }
}

private struct RecordGateTestQueryValue: Identifiable, Sendable {
    let id: RecordGateTestID
}

@Observable
private final class RecordGateTestModel: WebInspectorPersistentModel {
    typealias ID = RecordGateTestID
    typealias QueryValue = RecordGateTestQueryValue

    nonisolated let id: RecordGateTestID

    init(id: RecordGateTestID) {
        self.id = id
    }
}

private struct TestRecord: Equatable, Sendable {
    let value: Int
}

private func initializedRecordGate(
    revision: UInt64,
    records: [RecordGateTestID: TestRecord]
) throws -> TestRecordGate {
    let gate = TestRecordGate()
    _ = try gate.prepareReset(at: revision, records: records).apply()
    return gate
}

private func attemptApply(_ commit: TestRecordCommit) async -> Bool {
    do {
        _ = try commit.apply()
        return true
    } catch WebInspectorModelRecordGateError.commitResolved {
        return false
    } catch {
        Issue.record("Unexpected apply error: \(error)")
        return false
    }
}

private func attemptDiscard(_ commit: TestRecordCommit) async -> Bool {
    do {
        try commit.discard()
        return true
    } catch WebInspectorModelRecordGateError.commitResolved {
        return false
    } catch {
        Issue.record("Unexpected discard error: \(error)")
        return false
    }
}
