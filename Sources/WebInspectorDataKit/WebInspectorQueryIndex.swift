import Foundation

/// Defines the compact record and closed-query behavior executed by a
/// ``WebInspectorQueryIndex`` actor.
package protocol WebInspectorIndexedQueryDomain: SendableMetatype {
    associatedtype ItemID: Hashable & Sendable
    associatedtype Input: Identifiable & Sendable where Input.ID == ItemID
    associatedtype Record: Identifiable & Equatable & Sendable where Record.ID == ItemID
    associatedtype Query: Equatable & Sendable

    static func makeRecord(from input: Input) -> Record

    static func matches(_ record: Record, query: Query) -> Bool

    static func ordersBefore(
        _ lhs: Record,
        _ rhs: Record,
        query: Query
    ) -> Bool

    /// Classifies whether one record mutation can change the query's visible
    /// membership, order, or section topology.
    static func mutationImpact(
        previous: Record?,
        current: Record,
        query: Query
    ) -> WebInspectorIndexedQueryMutationImpact

    /// Builds the semantic snapshot from the actor-owned unfiltered source
    /// order and the query-sorted matching subset. The domain applies any
    /// additional grouping and group/member ordering.
    static func makeSnapshot(
        allItemIDsInSourceOrder: [ItemID],
        matchingItemIDs: [ItemID],
        recordsByID: [ItemID: Record],
        query: Query
    ) -> WebInspectorFetchedResultsSnapshot<ItemID, WebInspectorFetchSectionID>
}

package enum WebInspectorIndexedQueryMutationImpact: Sendable {
    case contentOnly
    case topology
}

/// Owns compact records and acknowledged query publications away from the
/// model-context actor.
package actor WebInspectorQueryIndex<Domain: WebInspectorIndexedQueryDomain> {
    package typealias QueryState = WebInspectorIndexedQueryState<Domain.ItemID>
    package typealias QueryPublication = WebInspectorIndexedQueryPublication<Domain.ItemID>
    package typealias QueryDelivery = WebInspectorIndexedQueryDelivery<Domain.ItemID>

    private enum Mutation {
        case replace([Domain.Input], sourceEpoch: UInt64?)
        case upsert(Domain.Input)
    }

    private struct PendingMutation {
        var mutation: Mutation
        var continuation: CheckedContinuation<[QueryDelivery], Never>
    }

    private struct SequenceWaiter {
        var minimumSequence: UInt64
        var continuation: CheckedContinuation<Void, any Error>
    }

    private final class WeakLifetime {
        weak var value: WebInspectorQueryRegistrationLifetime?

        init(_ value: WebInspectorQueryRegistrationLifetime) {
            self.value = value
        }
    }

    private struct QueryVersion {
        var generation: UInt64
        var query: Domain.Query
        var matchingIDs: [Domain.ItemID]
        var latestState: QueryState
        var acknowledgedState: QueryState?
        var visiblePositionsByID: [Domain.ItemID: WebInspectorFetchedResultsIndexPath]
        var pendingUpdatedItemIDs: Set<Domain.ItemID>
    }

    private struct RecordMutation {
        var previous: Domain.Record?
        var current: Domain.Record
    }

    private struct QueryRegistration {
        var lifetime: WeakLifetime
        var active: QueryVersion
        var candidate: QueryVersion?
    }

    private var recordsByID: [Domain.ItemID: Domain.Record] = [:]
    private var orderedIDs: [Domain.ItemID] = []
    private var lastUpdatedSequenceByID: [Domain.ItemID: UInt64] = [:]
    private var lastAppliedSequence: UInt64 = 0
    private var sourceEpoch: UInt64 = 0
    private var pendingMutationsBySequence: [UInt64: PendingMutation] = [:]
    private var sequenceWaiters: [UInt64: SequenceWaiter] = [:]
    private var nextSequenceWaiterID: UInt64 = 0
    private var queryRegistrations: [WebInspectorQueryRegistrationID: QueryRegistration] = [:]

#if DEBUG
    package struct PerformanceCounters: Equatable, Sendable {
        package var snapshotBuildCount = 0
        package var fullTransactionBuildCount = 0
        package var contentTransactionBuildCount = 0
    }

    private var performanceCounters = PerformanceCounters()
#endif

    package init() {}

    @discardableResult
    package func replace(
        with inputs: [Domain.Input],
        sequence: UInt64,
        sourceEpoch: UInt64? = nil
    ) async -> [QueryDelivery] {
        await enqueue(.replace(inputs, sourceEpoch: sourceEpoch), sequence: sequence)
    }

    @discardableResult
    package func upsert(
        _ input: Domain.Input,
        sequence: UInt64
    ) async -> [QueryDelivery] {
        await enqueue(.upsert(input), sequence: sequence)
    }

    private func enqueue(_ mutation: Mutation, sequence: UInt64) async -> [QueryDelivery] {
        precondition(
            sequence > lastAppliedSequence,
            "WebInspectorQueryIndex received an already-applied mutation sequence."
        )
        precondition(
            pendingMutationsBySequence[sequence] == nil,
            "WebInspectorQueryIndex received a duplicate mutation sequence."
        )
        return await withCheckedContinuation { continuation in
            pendingMutationsBySequence[sequence] = PendingMutation(
                mutation: mutation,
                continuation: continuation
            )
            drainContiguousMutations()
        }
    }

    private func drainContiguousMutations() {
        while lastAppliedSequence < UInt64.max {
            let sequence = lastAppliedSequence + 1
            guard let pending = pendingMutationsBySequence.removeValue(forKey: sequence) else {
                resumeSequenceWaiters()
                return
            }
            let deliveries = apply(pending.mutation, sequence: sequence)
            lastAppliedSequence = sequence
            pending.continuation.resume(returning: deliveries)
        }
        precondition(
            pendingMutationsBySequence.isEmpty,
            "WebInspectorQueryIndex mutation sequence overflowed."
        )
        resumeSequenceWaiters()
    }

    private func apply(_ mutation: Mutation, sequence: UInt64) -> [QueryDelivery] {
        switch mutation {
        case let .replace(inputs, replacementSourceEpoch):
            if let replacementSourceEpoch {
                precondition(
                    replacementSourceEpoch >= sourceEpoch,
                    "WebInspectorQueryIndex source epochs must not move backwards."
                )
                sourceEpoch = replacementSourceEpoch
            }
            recordsByID = [:]
            recordsByID.reserveCapacity(inputs.count)
            orderedIDs = []
            orderedIDs.reserveCapacity(inputs.count)
            lastUpdatedSequenceByID = [:]
            lastUpdatedSequenceByID.reserveCapacity(inputs.count)
            for input in inputs {
                _ = upsertRecord(input, sequence: sequence)
            }
            return updateAllQueryRegistrations(sequence: sequence, rebuilding: true)
        case let .upsert(input):
            let mutation = upsertRecord(input, sequence: sequence)
            return updateAllQueryRegistrations(
                sequence: sequence,
                rebuilding: false,
                mutation: mutation
            )
        }
    }

    private func upsertRecord(_ input: Domain.Input, sequence: UInt64) -> RecordMutation {
        let record = Domain.makeRecord(from: input)
        precondition(
            record.id == input.id,
            "WebInspectorQueryIndex domain changed a record identity while projecting input."
        )
        let previous = recordsByID[record.id]
        recordsByID[record.id] = record
        lastUpdatedSequenceByID[record.id] = sequence
        if previous == nil {
            orderedIDs.append(record.id)
        }
        return RecordMutation(previous: previous, current: record)
    }

    package func register(
        id: WebInspectorQueryRegistrationID,
        generation: UInt64,
        query: Domain.Query,
        lifetime: WebInspectorQueryRegistrationLifetime,
        minimumSequence: UInt64
    ) async throws -> QueryPublication {
        try await waitUntilApplied(minimumSequence)
        try Task.checkCancellation()
        pruneQueryRegistrations()
        guard lifetime.isCurrent(generation: generation) else {
            throw CancellationError()
        }
        precondition(
            queryRegistrations[id] == nil,
            "WebInspectorQueryIndex received a duplicate query registration ID."
        )
        let version = makeQueryVersion(generation: generation, query: query)
        try Task.checkCancellation()
        guard lifetime.isCurrent(generation: generation) else {
            throw CancellationError()
        }
        queryRegistrations[id] = QueryRegistration(
            lifetime: WeakLifetime(lifetime),
            active: version,
            candidate: nil
        )
        return publication(for: version)
    }

    package func prepareReplacement(
        id: WebInspectorQueryRegistrationID,
        generation: UInt64,
        query: Domain.Query,
        minimumSequence: UInt64
    ) async throws -> QueryPublication {
        try await waitUntilApplied(minimumSequence)
        try Task.checkCancellation()
        pruneQueryRegistrations()
        guard var registration = queryRegistrations[id],
              registration.lifetime.value?.isCurrent(generation: generation) == true,
              generation > registration.active.generation,
              generation > (registration.candidate?.generation ?? 0) else {
            throw CancellationError()
        }
        let candidate = makeQueryVersion(generation: generation, query: query)
        try Task.checkCancellation()
        guard registration.lifetime.value?.isCurrent(generation: generation) == true else {
            throw CancellationError()
        }
        registration.candidate = candidate
        queryRegistrations[id] = registration
        return publication(for: candidate)
    }

    package func commitReplacement(
        id: WebInspectorQueryRegistrationID,
        generation: UInt64
    ) -> QueryPublication? {
        pruneQueryRegistrations()
        guard var registration = queryRegistrations[id],
              registration.lifetime.value?.isCurrent(generation: generation) == true,
              let candidate = registration.candidate,
              candidate.generation == generation else {
            return nil
        }
        registration.active = candidate
        registration.candidate = nil
        queryRegistrations[id] = registration
        return publication(for: candidate)
    }

    package func discardCandidate(
        id: WebInspectorQueryRegistrationID,
        generation: UInt64
    ) {
        pruneQueryRegistrations()
        guard var registration = queryRegistrations[id],
              registration.candidate?.generation == generation else {
            return
        }
        registration.candidate = nil
        queryRegistrations[id] = registration
    }

    package func discardCandidates(
        id: WebInspectorQueryRegistrationID,
        through generation: UInt64
    ) {
        pruneQueryRegistrations()
        guard var registration = queryRegistrations[id],
              let candidate = registration.candidate,
              candidate.generation <= generation else {
            return
        }
        registration.candidate = nil
        queryRegistrations[id] = registration
    }

    package func acknowledge(
        id: WebInspectorQueryRegistrationID,
        generation: UInt64,
        state: QueryState
    ) {
        pruneQueryRegistrations()
        guard var registration = queryRegistrations[id],
              registration.active.generation == generation,
              self.sourceEpoch == state.cursor.sourceEpoch,
              state.cursor.sequence <= registration.active.latestState.cursor.sequence else {
            return
        }
        if let acknowledgedState = registration.active.acknowledgedState {
            guard state.cursor.sequence >= acknowledgedState.cursor.sequence else {
                return
            }
            if state.cursor == acknowledgedState.cursor {
                precondition(
                    state.snapshot == acknowledgedState.snapshot,
                    "WebInspectorQueryIndex received conflicting snapshots for one acknowledged cursor."
                )
                return
            }
        }
        if state.cursor == registration.active.latestState.cursor {
            precondition(
                state.snapshot == registration.active.latestState.snapshot,
                "WebInspectorQueryIndex received an acknowledgement that changed its latest snapshot."
            )
        }
        registration.active.acknowledgedState = state
        registration.active.pendingUpdatedItemIDs = registration.active.pendingUpdatedItemIDs.filter { id in
            lastUpdatedSequenceByID[id, default: 0] > state.cursor.sequence
        }
        queryRegistrations[id] = registration
    }

    private func waitUntilApplied(_ minimumSequence: UInt64) async throws {
        try Task.checkCancellation()
        guard lastAppliedSequence < minimumSequence else {
            return
        }
        precondition(
            nextSequenceWaiterID < UInt64.max,
            "WebInspectorQueryIndex sequence waiter identity overflowed."
        )
        let waiterID = nextSequenceWaiterID
        nextSequenceWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sequenceWaiters[waiterID] = SequenceWaiter(
                    minimumSequence: minimumSequence,
                    continuation: continuation
                )
                if Task.isCancelled {
                    cancelSequenceWaiter(id: waiterID)
                } else {
                    resumeSequenceWaiters()
                }
            }
        } onCancel: {
            Task {
                await self.cancelSequenceWaiter(id: waiterID)
            }
        }
    }

    private func cancelSequenceWaiter(id: UInt64) {
        sequenceWaiters.removeValue(forKey: id)?.continuation.resume(
            throwing: CancellationError()
        )
    }

    private func resumeSequenceWaiters() {
        let readyIDs = sequenceWaiters.compactMap { id, waiter in
            waiter.minimumSequence <= lastAppliedSequence ? id : nil
        }
        for id in readyIDs {
            sequenceWaiters.removeValue(forKey: id)?.continuation.resume(returning: ())
        }
    }

    private func updateAllQueryRegistrations(
        sequence: UInt64,
        rebuilding: Bool,
        mutation: RecordMutation? = nil
    ) -> [QueryDelivery] {
        pruneQueryRegistrations()
        var deliveries: [QueryDelivery] = []
        deliveries.reserveCapacity(queryRegistrations.count * 2)
        for id in Array(queryRegistrations.keys) {
            guard var registration = queryRegistrations[id] else {
                continue
            }
            update(
                &registration.active,
                sequence: sequence,
                rebuilding: rebuilding,
                mutation: mutation
            )
            deliveries.append(QueryDelivery(
                registrationID: id,
                generation: registration.active.generation,
                publication: publication(for: registration.active)
            ))
            if var candidate = registration.candidate {
                update(
                    &candidate,
                    sequence: sequence,
                    rebuilding: rebuilding,
                    mutation: mutation
                )
                registration.candidate = candidate
                deliveries.append(QueryDelivery(
                    registrationID: id,
                    generation: candidate.generation,
                    publication: publication(for: candidate)
                ))
            }
            queryRegistrations[id] = registration
        }
        return deliveries
    }

    private func update(
        _ version: inout QueryVersion,
        sequence: UInt64,
        rebuilding: Bool,
        mutation: RecordMutation?
    ) {
        let previousSourceEpoch = version.latestState.cursor.sourceEpoch
        var snapshot = version.latestState.snapshot
        if rebuilding {
            version.matchingIDs = matchingIDs(for: version.query)
            snapshot = makeSnapshot(matchingIDs: version.matchingIDs, query: version.query)
            version.visiblePositionsByID = visiblePositions(in: snapshot)
            version.pendingUpdatedItemIDs.formUnion(version.visiblePositionsByID.keys)
        } else if let mutation {
            version.pendingUpdatedItemIDs.insert(mutation.current.id)
            if Domain.mutationImpact(
                previous: mutation.previous,
                current: mutation.current,
                query: version.query
            ) == .topology {
                let changedID = mutation.current.id
                version.matchingIDs.removeAll { $0 == changedID }
                if Domain.matches(mutation.current, query: version.query) {
                    insert(changedID, into: &version.matchingIDs, query: version.query)
                }
                snapshot = makeSnapshot(matchingIDs: version.matchingIDs, query: version.query)
                version.visiblePositionsByID = visiblePositions(in: snapshot)
            }
        }
        version.latestState = QueryState(
            cursor: WebInspectorIndexedQueryCursor(
                sourceEpoch: sourceEpoch,
                sequence: sequence
            ),
            snapshot: snapshot
        )
        if previousSourceEpoch != sourceEpoch {
            version.acknowledgedState = nil
            version.pendingUpdatedItemIDs = []
        }
    }

    private func makeQueryVersion(
        generation: UInt64,
        query: Domain.Query
    ) -> QueryVersion {
        let matchingIDs = matchingIDs(for: query)
        let snapshot = makeSnapshot(matchingIDs: matchingIDs, query: query)
        return QueryVersion(
            generation: generation,
            query: query,
            matchingIDs: matchingIDs,
            latestState: QueryState(
                cursor: WebInspectorIndexedQueryCursor(
                    sourceEpoch: sourceEpoch,
                    sequence: lastAppliedSequence
                ),
                snapshot: snapshot
            ),
            acknowledgedState: nil,
            visiblePositionsByID: visiblePositions(in: snapshot),
            pendingUpdatedItemIDs: []
        )
    }

    private func publication(for version: QueryVersion) -> QueryPublication {
        guard let acknowledgedState = version.acknowledgedState else {
            return QueryPublication(
                state: version.latestState,
                change: .reset,
                reconfigureItemIDs: []
            )
        }
        precondition(
            acknowledgedState.cursor.sourceEpoch == version.latestState.cursor.sourceEpoch,
            "WebInspectorQueryIndex retained an acknowledgement across a source epoch."
        )
        precondition(
            acknowledgedState.cursor.sequence <= version.latestState.cursor.sequence,
            "WebInspectorQueryIndex retained an acknowledgement ahead of its latest state."
        )
        let reconfigureItemIDs = Set(version.pendingUpdatedItemIDs.filter { id in
            version.visiblePositionsByID[id] != nil
        })
        let transaction: WebInspectorFetchedResultsTransaction<Domain.ItemID>
        if acknowledgedState.snapshot == version.latestState.snapshot {
            let updates = reconfigureItemIDs.compactMap { id -> (
                id: Domain.ItemID,
                indexPath: WebInspectorFetchedResultsIndexPath
            )? in
                guard let indexPath = version.visiblePositionsByID[id] else {
                    return nil
                }
                return (id, indexPath)
            }.sorted { lhs, rhs in
                lhs.indexPath < rhs.indexPath
            }.map { update in
                WebInspectorFetchedResultsItemChange.update(
                    itemID: update.id,
                    indexPath: update.indexPath
                )
            }
            transaction = WebInspectorFetchedResultsTransaction(
                oldSnapshot: version.latestState.snapshot,
                newSnapshot: version.latestState.snapshot,
                itemChanges: updates
            )
#if DEBUG
            performanceCounters.contentTransactionBuildCount += 1
#endif
        } else {
            transaction = WebInspectorFetchedResultsTransaction(
                oldSnapshot: acknowledgedState.snapshot,
                newSnapshot: version.latestState.snapshot,
                updatedItemIDs: reconfigureItemIDs
            )
#if DEBUG
            performanceCounters.fullTransactionBuildCount += 1
#endif
        }
        return QueryPublication(
            state: version.latestState,
            change: .transaction(
                base: acknowledgedState.cursor,
                transaction: transaction
            ),
            reconfigureItemIDs: reconfigureItemIDs
        )
    }

    private func pruneQueryRegistrations() {
        queryRegistrations = queryRegistrations.filter { _, registration in
            registration.lifetime.value != nil
        }
    }

#if DEBUG
    package func performanceCountersForTesting() -> PerformanceCounters {
        performanceCounters
    }

    package func resetPerformanceCountersForTesting() {
        performanceCounters = PerformanceCounters()
    }

    package func isMutationPendingForTesting(sequence: UInt64) -> Bool {
        pendingMutationsBySequence[sequence] != nil
    }

    package func isSequenceWaiterPendingForTesting(minimumSequence: UInt64) -> Bool {
        sequenceWaiters.values.contains { $0.minimumSequence == minimumSequence }
    }

    package func queryRegistrationCountForTesting() -> Int {
        pruneQueryRegistrations()
        return queryRegistrations.count
    }
#endif

    private func makeSnapshot(
        matchingIDs: [Domain.ItemID],
        query: Domain.Query
    ) -> WebInspectorFetchedResultsSnapshot<Domain.ItemID, WebInspectorFetchSectionID> {
#if DEBUG
        performanceCounters.snapshotBuildCount += 1
#endif
        return Domain.makeSnapshot(
            allItemIDsInSourceOrder: orderedIDs,
            matchingItemIDs: matchingIDs,
            recordsByID: recordsByID,
            query: query
        )
    }

    private func visiblePositions(
        in snapshot: WebInspectorFetchedResultsSnapshot<Domain.ItemID, WebInspectorFetchSectionID>
    ) -> [Domain.ItemID: WebInspectorFetchedResultsIndexPath] {
        var positions: [Domain.ItemID: WebInspectorFetchedResultsIndexPath] = [:]
        positions.reserveCapacity(snapshot.itemIDs.count)
        for (sectionIndex, section) in snapshot.sections.enumerated() {
            for (itemIndex, itemID) in section.itemIDs.enumerated() {
                positions[itemID] = WebInspectorFetchedResultsIndexPath(
                    section: sectionIndex,
                    item: itemIndex
                )
            }
        }
        return positions
    }

    private func matchingIDs(for query: Domain.Query) -> [Domain.ItemID] {
        var ids = orderedIDs.map { id in
            guard let record = recordsByID[id] else {
                preconditionFailure("WebInspectorQueryIndex lost a record while matching a query.")
            }
            return Domain.matches(record, query: query) ? id : nil
        }.compactMap { $0 }
        ids.sort { lhsID, rhsID in
            guard let lhs = recordsByID[lhsID], let rhs = recordsByID[rhsID] else {
                preconditionFailure("WebInspectorQueryIndex lost a matching record while sorting a query.")
            }
            return Domain.ordersBefore(lhs, rhs, query: query)
        }
        return ids
    }

    private func insert(
        _ id: Domain.ItemID,
        into ids: inout [Domain.ItemID],
        query: Domain.Query
    ) {
        guard let record = recordsByID[id] else {
            preconditionFailure("WebInspectorQueryIndex lost a matching record during insertion.")
        }
        var lowerBound = 0
        var upperBound = ids.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            guard let midpointRecord = recordsByID[ids[midpoint]] else {
                preconditionFailure("WebInspectorQueryIndex lost a matching record during insertion.")
            }
            if Domain.ordersBefore(midpointRecord, record, query: query) {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        ids.insert(id, at: lowerBound)
    }
}
