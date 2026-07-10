import Foundation

package struct NetworkResultSetDelta: Sendable {
    package var sequence: UInt64
    package var snapshot: WebInspectorFetchedResultsSnapshot<NetworkRequest.ID>
    package var transaction: WebInspectorFetchedResultsTransaction<NetworkRequest.ID>
    package var reconfigureItemIDs: Set<NetworkRequest.ID>
}

package actor NetworkRequestIndex {
    package typealias QueryProjection = WebInspectorIndexedQueryProjection<NetworkRequest.ID>
    package typealias QueryDelivery = WebInspectorIndexedQueryDelivery<NetworkRequest.ID>

    private enum Mutation {
        case replace([NetworkRequestRecordInput], sourceEpoch: UInt64?)
        case upsert(NetworkRequestRecordInput)
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
        var query: NetworkQuery
        var matchingIDs: [NetworkRequest.ID]
        var snapshot: WebInspectorFetchedResultsSnapshot<NetworkRequest.ID>
        var sequence: UInt64
        var acknowledgedSequence: UInt64
    }

    private struct QueryRegistration {
        var lifetime: WeakLifetime
        var active: QueryVersion
        var candidate: QueryVersion?
    }

    private var recordsByID: [NetworkRequest.ID: NetworkRequestRecord] = [:]
    private var orderedIDs: [NetworkRequest.ID] = []
    private var lastUpdatedSequenceByID: [NetworkRequest.ID: UInt64] = [:]
    private var lastAppliedSequence: UInt64 = 0
    private var sourceEpoch: UInt64 = 0
    private var pendingMutationsBySequence: [UInt64: PendingMutation] = [:]
    private var sequenceWaiters: [UInt64: SequenceWaiter] = [:]
    private var nextSequenceWaiterID: UInt64 = 0
    private var queryRegistrations: [WebInspectorQueryRegistrationID: QueryRegistration] = [:]

    package init() {}

    @discardableResult
    package func replace(
        with inputs: [NetworkRequestRecordInput],
        sequence: UInt64,
        sourceEpoch: UInt64? = nil
    ) async -> [QueryDelivery] {
        await enqueue(.replace(inputs, sourceEpoch: sourceEpoch), sequence: sequence)
    }

    @discardableResult
    package func upsert(
        _ input: NetworkRequestRecordInput,
        sequence: UInt64
    ) async -> [QueryDelivery] {
        await enqueue(.upsert(input), sequence: sequence)
    }

    private func enqueue(_ mutation: Mutation, sequence: UInt64) async -> [QueryDelivery] {
        precondition(
            sequence > lastAppliedSequence,
            "NetworkRequestIndex received an already-applied mutation sequence."
        )
        precondition(
            pendingMutationsBySequence[sequence] == nil,
            "NetworkRequestIndex received a duplicate mutation sequence."
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
            "NetworkRequestIndex mutation sequence overflowed."
        )
        resumeSequenceWaiters()
    }

    private func apply(_ mutation: Mutation, sequence: UInt64) -> [QueryDelivery] {
        switch mutation {
        case let .replace(inputs, replacementSourceEpoch):
            if let replacementSourceEpoch {
                precondition(
                    replacementSourceEpoch >= sourceEpoch,
                    "NetworkRequestIndex source epochs must not move backwards."
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
                upsertRecord(input, sequence: sequence)
            }
            return updateAllQueryRegistrations(sequence: sequence, rebuilding: true)
        case let .upsert(input):
            upsertRecord(input, sequence: sequence)
            return updateAllQueryRegistrations(
                sequence: sequence,
                rebuilding: false,
                changedID: input.id
            )
        }
    }

    private func upsertRecord(_ input: NetworkRequestRecordInput, sequence: UInt64) {
        let isNewRecord = recordsByID[input.id] == nil
        let record = NetworkRequestRecord(input: input)
        recordsByID[record.id] = record
        lastUpdatedSequenceByID[record.id] = sequence
        if isNewRecord {
            orderedIDs.append(record.id)
        }
    }

    package func register(
        id: WebInspectorQueryRegistrationID,
        generation: UInt64,
        query: NetworkQuery,
        lifetime: WebInspectorQueryRegistrationLifetime,
        minimumSequence: UInt64
    ) async throws -> QueryProjection {
        try await waitUntilApplied(minimumSequence)
        try Task.checkCancellation()
        pruneQueryRegistrations()
        guard lifetime.isCurrent(generation: generation) else {
            throw CancellationError()
        }
        precondition(
            queryRegistrations[id] == nil,
            "NetworkRequestIndex received a duplicate query registration ID."
        )
        let version = makeQueryVersion(
            generation: generation,
            query: query,
            acknowledgedSequence: lastAppliedSequence
        )
        try Task.checkCancellation()
        guard lifetime.isCurrent(generation: generation) else {
            throw CancellationError()
        }
        queryRegistrations[id] = QueryRegistration(
            lifetime: WeakLifetime(lifetime),
            active: version,
            candidate: nil
        )
        return projection(for: version)
    }

    package func prepareReplacement(
        id: WebInspectorQueryRegistrationID,
        generation: UInt64,
        query: NetworkQuery,
        minimumSequence: UInt64
    ) async throws -> QueryProjection {
        try await waitUntilApplied(minimumSequence)
        try Task.checkCancellation()
        pruneQueryRegistrations()
        guard var registration = queryRegistrations[id],
              registration.lifetime.value?.isCurrent(generation: generation) == true,
              generation > registration.active.generation,
              generation > (registration.candidate?.generation ?? 0) else {
            throw CancellationError()
        }
        let candidate = makeQueryVersion(
            generation: generation,
            query: query,
            acknowledgedSequence: lastAppliedSequence
        )
        try Task.checkCancellation()
        guard registration.lifetime.value?.isCurrent(generation: generation) == true else {
            throw CancellationError()
        }
        registration.candidate = candidate
        queryRegistrations[id] = registration
        return projection(for: candidate)
    }

    package func commitReplacement(
        id: WebInspectorQueryRegistrationID,
        generation: UInt64
    ) -> QueryProjection? {
        pruneQueryRegistrations()
        guard var registration = queryRegistrations[id],
              registration.lifetime.value?.isCurrent(generation: generation) == true,
              var candidate = registration.candidate,
              candidate.generation == generation else {
            return nil
        }
        candidate.acknowledgedSequence = candidate.sequence
        registration.active = candidate
        registration.candidate = nil
        queryRegistrations[id] = registration
        return projection(for: candidate)
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
        sourceEpoch: UInt64,
        sequence: UInt64
    ) {
        pruneQueryRegistrations()
        guard var registration = queryRegistrations[id],
              registration.active.generation == generation,
              self.sourceEpoch == sourceEpoch else {
            return
        }
        registration.active.acknowledgedSequence = max(
            registration.active.acknowledgedSequence,
            sequence
        )
        queryRegistrations[id] = registration
    }

    private func waitUntilApplied(_ minimumSequence: UInt64) async throws {
        try Task.checkCancellation()
        guard lastAppliedSequence < minimumSequence else {
            return
        }
        precondition(
            nextSequenceWaiterID < UInt64.max,
            "NetworkRequestIndex sequence waiter identity overflowed."
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
        changedID: NetworkRequest.ID? = nil
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
                changedID: changedID
            )
            deliveries.append(QueryDelivery(
                registrationID: id,
                generation: registration.active.generation,
                projection: projection(for: registration.active)
            ))
            if var candidate = registration.candidate {
                update(
                    &candidate,
                    sequence: sequence,
                    rebuilding: rebuilding,
                    changedID: changedID
                )
                registration.candidate = candidate
                deliveries.append(QueryDelivery(
                    registrationID: id,
                    generation: candidate.generation,
                    projection: projection(for: candidate)
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
        changedID: NetworkRequest.ID?
    ) {
        if rebuilding {
            version.matchingIDs = matchingIDs(for: version.query)
        } else if let changedID {
            version.matchingIDs.removeAll { $0 == changedID }
            if let record = recordsByID[changedID], matches(record, query: version.query) {
                insert(changedID, into: &version.matchingIDs, query: version.query)
            }
        }
        version.snapshot = snapshot(matchingIDs: version.matchingIDs, query: version.query)
        version.sequence = sequence
    }

    private func makeQueryVersion(
        generation: UInt64,
        query: NetworkQuery,
        acknowledgedSequence: UInt64
    ) -> QueryVersion {
        let matchingIDs = matchingIDs(for: query)
        return QueryVersion(
            generation: generation,
            query: query,
            matchingIDs: matchingIDs,
            snapshot: snapshot(matchingIDs: matchingIDs, query: query),
            sequence: lastAppliedSequence,
            acknowledgedSequence: acknowledgedSequence
        )
    }

    private func projection(for version: QueryVersion) -> QueryProjection {
        let reconfigureItemIDs = Set(version.snapshot.itemIDs.filter { id in
            lastUpdatedSequenceByID[id, default: 0] > version.acknowledgedSequence
        })
        return QueryProjection(
            sourceEpoch: sourceEpoch,
            sequence: version.sequence,
            snapshot: version.snapshot,
            reconfigureItemIDs: reconfigureItemIDs
        )
    }

    private func pruneQueryRegistrations() {
        queryRegistrations = queryRegistrations.filter { _, registration in
            registration.lifetime.value != nil
        }
    }

#if DEBUG
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

    private func matchingIDs(for query: NetworkQuery) -> [NetworkRequest.ID] {
        var ids = orderedIDs.filter { id in
            recordsByID[id].map { matches($0, query: query) } ?? false
        }
        ids.sort { lhsID, rhsID in
            guard let lhs = recordsByID[lhsID], let rhs = recordsByID[rhsID] else {
                preconditionFailure("NetworkRequestIndex lost a matching record while sorting a query.")
            }
            return ordersBefore(lhs, rhs, query: query)
        }
        return ids
    }

    private func matches(_ record: NetworkRequestRecord, query: NetworkQuery) -> Bool {
        if let search = query.search,
           record.searchableText.localizedStandardContains(search) == false {
            return false
        }
        if query.resourceCategories.isEmpty == false,
           query.resourceCategories.contains(record.resourceCategory) == false {
            return false
        }
        if query.methods.isEmpty == false,
           query.methods.contains(record.method) == false {
            return false
        }
        return true
    }

    private func insert(
        _ id: NetworkRequest.ID,
        into ids: inout [NetworkRequest.ID],
        query: NetworkQuery
    ) {
        guard let record = recordsByID[id] else {
            return
        }
        var lowerBound = 0
        var upperBound = ids.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            guard let midpointRecord = recordsByID[ids[midpoint]] else {
                preconditionFailure("NetworkRequestIndex lost a matching record during insertion.")
            }
            if ordersBefore(midpointRecord, record, query: query) {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        ids.insert(id, at: lowerBound)
    }

    private func ordersBefore(
        _ lhs: NetworkRequestRecord,
        _ rhs: NetworkRequestRecord,
        query: NetworkQuery
    ) -> Bool {
        let timestampOrder = compareOptional(lhs.requestSentTimestamp, rhs.requestSentTimestamp)
        switch (query.sort, timestampOrder) {
        case (.requestTimeAscending, .orderedAscending),
             (.requestTimeDescending, .orderedDescending):
            return true
        case (.requestTimeAscending, .orderedDescending),
             (.requestTimeDescending, .orderedAscending):
            return false
        case (_, .orderedSame):
            switch query.sort {
            case .requestTimeAscending:
                return lhs.orderIndex < rhs.orderIndex
            case .requestTimeDescending:
                return lhs.orderIndex > rhs.orderIndex
            }
        }
    }

    private func compareOptional<Value: Comparable>(
        _ lhs: Value?,
        _ rhs: Value?
    ) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil):
            return .orderedSame
        case (nil, _):
            return .orderedAscending
        case (_, nil):
            return .orderedDescending
        case let (lhs?, rhs?):
            if lhs < rhs {
                return .orderedAscending
            }
            if lhs > rhs {
                return .orderedDescending
            }
            return .orderedSame
        }
    }

    private func snapshot(
        matchingIDs: [NetworkRequest.ID],
        query: NetworkQuery
    ) -> WebInspectorFetchedResultsSnapshot<NetworkRequest.ID> {
        let lowerBound = min(query.offset, matchingIDs.count)
        let upperBound: Int
        if let limit = query.limit {
            upperBound = min(lowerBound + limit, matchingIDs.count)
        } else {
            upperBound = matchingIDs.count
        }
        let visibleIDs = Array(matchingIDs[lowerBound..<upperBound])
        guard visibleIDs.isEmpty == false else {
            return WebInspectorFetchedResultsSnapshot()
        }
        guard query.section == .method else {
            return WebInspectorFetchedResultsSnapshot(itemIDs: visibleIDs)
        }
        var sections: [(id: WebInspectorFetchSectionID, itemIDs: [NetworkRequest.ID])] = []
        for id in visibleIDs {
            guard let method = recordsByID[id]?.method else {
                preconditionFailure("NetworkRequestIndex lost a visible record while sectioning a query.")
            }
            let sectionID = WebInspectorFetchSectionID(rawValue: method)
            if let index = sections.firstIndex(where: { $0.id == sectionID }) {
                sections[index].itemIDs.append(id)
            } else {
                sections.append((sectionID, [id]))
            }
        }
        return WebInspectorFetchedResultsSnapshot(sections: sections.map { section in
            WebInspectorFetchedResultsSnapshot.Section(
                id: section.id,
                title: section.id.rawValue,
                itemIDs: section.itemIDs
            )
        })
    }

    // Legacy generic-descriptor projection retained only until the final query
    // migration commit removes the generic surface.
    package func delta(
        plan: NetworkRequestQueryPlan,
        sectionBy: WebInspectorSectionDescriptor<NetworkRequest>?,
        oldSnapshot: WebInspectorFetchedResultsSnapshot<NetworkRequest.ID>,
        changedSince sequence: UInt64
    ) -> NetworkResultSetDelta {
        precondition(plan.requiresModelPredicate == false)
        let indexSequence = lastAppliedSequence
        let newSnapshot = legacySnapshot(plan: plan, sectionBy: sectionBy)
        let oldItemIDs = Set(oldSnapshot.itemIDs)
        let updatedItemIDs = Set(newSnapshot.itemIDs.filter { id in
            oldItemIDs.contains(id) && lastUpdatedSequenceByID[id, default: 0] > sequence
        })
        let transaction = WebInspectorFetchedResultsTransaction(
            oldSnapshot: oldSnapshot,
            newSnapshot: newSnapshot,
            updatedItemIDs: updatedItemIDs
        )
        return NetworkResultSetDelta(
            sequence: indexSequence,
            snapshot: newSnapshot,
            transaction: transaction,
            reconfigureItemIDs: updatedItemIDs
        )
    }

    private func legacySnapshot(
        plan: NetworkRequestQueryPlan,
        sectionBy: WebInspectorSectionDescriptor<NetworkRequest>?
    ) -> WebInspectorFetchedResultsSnapshot<NetworkRequest.ID> {
        let matchingRecords = legacyVisibleRecords(plan: plan)
        guard matchingRecords.isEmpty == false else {
            return WebInspectorFetchedResultsSnapshot()
        }
        guard let sectionBy else {
            return WebInspectorFetchedResultsSnapshot(itemIDs: matchingRecords.map(\.id))
        }
        var sections: [(
            id: WebInspectorFetchSectionID,
            title: String?,
            itemIDs: [NetworkRequest.ID]
        )] = []
        for record in matchingRecords {
            let identity = legacySectionIdentity(for: record, sectionBy: sectionBy)
            if let index = sections.firstIndex(where: { $0.id == identity.id }) {
                sections[index].itemIDs.append(record.id)
            } else {
                sections.append((identity.id, identity.title, [record.id]))
            }
        }
        return WebInspectorFetchedResultsSnapshot(sections: sections.map { section in
            WebInspectorFetchedResultsSnapshot.Section(
                id: section.id,
                title: section.title,
                itemIDs: section.itemIDs
            )
        })
    }

    private func legacyVisibleRecords(plan: NetworkRequestQueryPlan) -> [NetworkRequestRecord] {
        var records = orderedIDs.compactMap { recordsByID[$0] }.filter {
            plan.matches(record: $0) == true
        }
        if plan.sortComparators.isEmpty == false {
            records.sort { plan.ordersBefore($0, $1) }
        }
        let lowerBound = min(plan.fetchOffset, records.count)
        let upperBound = plan.fetchLimit.map { min(lowerBound + $0, records.count) } ?? records.count
        return Array(records[lowerBound..<upperBound])
    }

    private func legacySectionIdentity(
        for record: NetworkRequestRecord,
        sectionBy: WebInspectorSectionDescriptor<NetworkRequest>
    ) -> (id: WebInspectorFetchSectionID, title: String?) {
        let value: String?
        switch sectionBy.key {
        case .networkMethod:
            value = record.method
        case .networkResourceType:
            value = record.resourceTypeRawValue
        case .networkResourceCategory:
            value = record.resourceCategory.rawValue
        case .networkMIMEType:
            value = record.mimeType
        case .consoleSource, .consoleLevel, .consoleKind, .consoleURL:
            preconditionFailure("Console section descriptors cannot be applied to NetworkRequest results.")
        }
        let title = value ?? ""
        return (WebInspectorFetchSectionID(rawValue: title), title)
    }
}
