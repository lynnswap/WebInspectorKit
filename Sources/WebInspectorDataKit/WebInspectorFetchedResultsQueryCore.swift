import Foundation

package struct WebInspectorFetchedResultsCanonicalRank:
    RawRepresentable,
    Comparable,
    Hashable,
    Sendable
{
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    package static func < (
        lhs: WebInspectorFetchedResultsCanonicalRank,
        rhs: WebInspectorFetchedResultsCanonicalRank
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

package struct WebInspectorFetchedResultsSourceRecord<
    Model: WebInspectorPersistentModel
>: Sendable {
    package let value: Model.QueryValue
    package let canonicalRank: WebInspectorFetchedResultsCanonicalRank

    package init(
        value: Model.QueryValue,
        canonicalRank: WebInspectorFetchedResultsCanonicalRank
    ) {
        self.value = value
        self.canonicalRank = canonicalRank
    }
}

package enum WebInspectorFetchedResultsSourceChange<
    Model: WebInspectorPersistentModel
>: Sendable {
    case insert(WebInspectorFetchedResultsSourceRecord<Model>)
    case update(WebInspectorFetchedResultsSourceRecord<Model>)
    case contentOnly(Model.ID)
    case delete(Model.ID)
    case reset([WebInspectorFetchedResultsSourceRecord<Model>])
}

package struct WebInspectorFetchedResultsQueryRegistrationID: Hashable, Sendable {
    fileprivate let rawValue: UInt64
}

package struct WebInspectorFetchedResultsQueryCandidateID: Hashable, Sendable {
    fileprivate let registrationID: WebInspectorFetchedResultsQueryRegistrationID
    fileprivate let generation: UInt64
}

package struct WebInspectorFetchedResultsQueryState<
    ItemID: Hashable & Sendable,
    SectionName: Hashable & Sendable
>: Hashable, Sendable {
    package let revision: UInt64
    package let snapshot: WebInspectorFetchedResultsSnapshot<ItemID, SectionName>
}

package enum WebInspectorFetchedResultsQueryCoreError: Error, Equatable, Sendable {
    case closedRegistration
    case staleCandidate
}

package struct WebInspectorFetchedResultsQueryPerformanceCounters:
    Equatable,
    Sendable
{
    package var fullEvaluationCount = 0
    package var fullEvaluationRecordCount = 0
    package var singleRecordEvaluationCount = 0
    package var contentOnlyVisitCount = 0
    package var snapshotBuildCount = 0
    package var differenceBuildCount = 0
    package var publicationCount = 0
    package var rebaseSnapshotCount = 0
    package var snapshotMaterializedItemCount = 0
    package var canonicalFlatAppendCount = 0
    package var canonicalFlatDeleteCount = 0
    package var canonicalFlatStableUpdateCount = 0
}

package struct WebInspectorFetchedResultsSourcePerformanceCounters:
    Equatable,
    Sendable
{
    package var canonicalRankLookupCount = 0
    package var canonicalAppendCount = 0
    package var canonicalBinarySearchInsertionCount = 0
}

package struct WebInspectorFetchedResultsQueryRegistration<
    Model: WebInspectorPersistentModel,
    SectionName: Hashable & Sendable
>: Sendable {
    package let id: WebInspectorFetchedResultsQueryRegistrationID
    private let owner: WebInspectorFetchedResultsQueryCore<Model>

    fileprivate init(
        id: WebInspectorFetchedResultsQueryRegistrationID,
        owner: WebInspectorFetchedResultsQueryCore<Model>
    ) {
        self.id = id
        self.owner = owner
    }

    package func state() async throws -> WebInspectorFetchedResultsQueryState<
        Model.ID,
        SectionName
    > {
        try await owner.state(for: id, sectionName: SectionName.self)
    }

    package func updates() async throws -> WebInspectorFetchedResultsUpdateSequence<
        Model.ID,
        SectionName
    > {
        try await owner.subscribe(to: id, sectionName: SectionName.self)
    }

    package func prepareReplacement(
        _ descriptor: WebInspectorFetchDescriptor<Model>
    ) async throws -> WebInspectorFetchedResultsQueryCandidateID {
        try await owner.prepareReplacement(
            descriptor,
            for: id,
            sectionName: SectionName.self
        )
    }

    package func commitReplacement(
        _ candidateID: WebInspectorFetchedResultsQueryCandidateID
    ) async throws -> WebInspectorFetchedResultsQueryState<Model.ID, SectionName> {
        try await owner.commitReplacement(
            candidateID,
            for: id,
            sectionName: SectionName.self
        )
    }

    package func discardReplacement(
        _ candidateID: WebInspectorFetchedResultsQueryCandidateID
    ) async {
        await owner.discardReplacement(
            candidateID,
            for: id,
            sectionName: SectionName.self
        )
    }

    package func close() async {
        await owner.close(id, sectionName: SectionName.self)
    }
}

package actor WebInspectorFetchedResultsQueryCore<
    Model: WebInspectorPersistentModel
> {
    private typealias SourceRecord = WebInspectorFetchedResultsSourceRecord<Model>
    private typealias Entry = _WebInspectorFetchedResultsAnyRegistrationEntry<Model>

    private var recordsByID: [Model.ID: SourceRecord]
    private var canonicalItemIDs: [Model.ID]
    private var itemIDByCanonicalRank: [WebInspectorFetchedResultsCanonicalRank: Model.ID]
    private var registrations: [WebInspectorFetchedResultsQueryRegistrationID: Entry] = [:]
    private var nextRegistrationID: UInt64 = 0
    private var sourcePerformanceCounters =
        WebInspectorFetchedResultsSourcePerformanceCounters()
    private var isClosed = false

    package init(
        records: [WebInspectorFetchedResultsSourceRecord<Model>] = []
    ) {
        let source = Self.validatedSource(records)
        recordsByID = source.recordsByID
        canonicalItemIDs = source.canonicalItemIDs
        itemIDByCanonicalRank = source.itemIDByCanonicalRank
    }

    package func register(
        fetchDescriptor: WebInspectorFetchDescriptor<Model> = .init()
    ) throws -> WebInspectorFetchedResultsQueryRegistration<Model, Never> {
        try ensureOpen()
        let box = try _WebInspectorFetchedResultsFlatRegistrationBox<Model>(
            descriptor: fetchDescriptor,
            recordsByID: recordsByID,
            canonicalItemIDs: canonicalItemIDs
        )
        return install(box)
    }

    package func register<SectionName: Hashable & Sendable>(
        fetchDescriptor: WebInspectorFetchDescriptor<Model> = .init(),
        sectionBy: Expression<Model.QueryValue, SectionName>
    ) throws -> WebInspectorFetchedResultsQueryRegistration<Model, SectionName> {
        try ensureOpen()
        let box = try _WebInspectorFetchedResultsSectionedRegistrationBox<Model, SectionName>(
            descriptor: fetchDescriptor,
            sectionBy: sectionBy,
            recordsByID: recordsByID,
            canonicalItemIDs: canonicalItemIDs
        )
        return install(box)
    }

    package func apply(_ change: WebInspectorFetchedResultsSourceChange<Model>) {
        guard isClosed == false else {
            return
        }
        let mutation = applyToSource(change)
        var failedRegistrationIDs: [WebInspectorFetchedResultsQueryRegistrationID] = []
        failedRegistrationIDs.reserveCapacity(registrations.count)
        for (id, entry) in registrations {
            do {
                try entry.apply(mutation, recordsByID, canonicalItemIDs)
            } catch {
                entry.finish(error)
                failedRegistrationIDs.append(id)
            }
        }
        for id in failedRegistrationIDs {
            registrations.removeValue(forKey: id)
        }
    }

    package func close() {
        guard isClosed == false else {
            return
        }
        isClosed = true
        let entries = registrations.values
        registrations.removeAll(keepingCapacity: false)
        for entry in entries {
            entry.finish(nil)
        }
        recordsByID.removeAll(keepingCapacity: false)
        canonicalItemIDs.removeAll(keepingCapacity: false)
        itemIDByCanonicalRank.removeAll(keepingCapacity: false)
    }

    package func registrationCountForTesting() -> Int {
        registrations.count
    }

    package func sourcePerformanceCountersForTesting()
        -> WebInspectorFetchedResultsSourcePerformanceCounters
    {
        sourcePerformanceCounters
    }

    package func resetSourcePerformanceCountersForTesting() {
        sourcePerformanceCounters = .init()
    }

    package func performanceCountersForTesting<SectionName: Hashable & Sendable>(
        for registration: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>
    ) throws -> WebInspectorFetchedResultsQueryPerformanceCounters {
        try box(for: registration.id, sectionName: SectionName.self).performanceCounters
    }

    package func resetPerformanceCountersForTesting<SectionName: Hashable & Sendable>(
        for registration: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>
    ) throws {
        try box(for: registration.id, sectionName: SectionName.self).performanceCounters = .init()
    }

    package func activeSubscriberCountForTesting<SectionName: Hashable & Sendable>(
        for registration: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>
    ) throws -> Int {
        try box(for: registration.id, sectionName: SectionName.self)
            .publication.activeSubscriberCount
    }

    package func waitingSubscriberCountForTesting<SectionName: Hashable & Sendable>(
        for registration: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>
    ) throws -> Int {
        try box(for: registration.id, sectionName: SectionName.self)
            .publication.waitingSubscriberCountForTesting
    }

    fileprivate func state<SectionName: Hashable & Sendable>(
        for id: WebInspectorFetchedResultsQueryRegistrationID,
        sectionName: SectionName.Type
    ) throws -> WebInspectorFetchedResultsQueryState<Model.ID, SectionName> {
        try box(for: id, sectionName: sectionName).state()
    }

    fileprivate func subscribe<SectionName: Hashable & Sendable>(
        to id: WebInspectorFetchedResultsQueryRegistrationID,
        sectionName: SectionName.Type
    ) throws -> WebInspectorFetchedResultsUpdateSequence<Model.ID, SectionName> {
        let box = try box(for: id, sectionName: sectionName)
        let base = box.publication.subscribe(
            revision: box.revision,
            snapshot: box.currentSnapshot()
        )
        return WebInspectorFetchedResultsUpdateSequence(
            base: base,
            rebase: { [self] token in
                try await rebase(token, for: id, sectionName: sectionName)
            }
        )
    }

    fileprivate func prepareReplacement<SectionName: Hashable & Sendable>(
        _ descriptor: WebInspectorFetchDescriptor<Model>,
        for id: WebInspectorFetchedResultsQueryRegistrationID,
        sectionName: SectionName.Type
    ) throws -> WebInspectorFetchedResultsQueryCandidateID {
        let box = try box(for: id, sectionName: sectionName)
        do {
            return try box.prepareReplacement(
                descriptor,
                recordsByID: recordsByID,
                canonicalItemIDs: canonicalItemIDs,
                registrationID: id
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            terminateRegistration(id, with: error)
            throw error
        }
    }

    fileprivate func commitReplacement<SectionName: Hashable & Sendable>(
        _ candidateID: WebInspectorFetchedResultsQueryCandidateID,
        for id: WebInspectorFetchedResultsQueryRegistrationID,
        sectionName: SectionName.Type
    ) throws -> WebInspectorFetchedResultsQueryState<Model.ID, SectionName> {
        guard candidateID.registrationID == id else {
            throw WebInspectorFetchedResultsQueryCoreError.staleCandidate
        }
        return try box(for: id, sectionName: sectionName)
            .commitReplacement(candidateID)
    }

    fileprivate func discardReplacement<SectionName: Hashable & Sendable>(
        _ candidateID: WebInspectorFetchedResultsQueryCandidateID,
        for id: WebInspectorFetchedResultsQueryRegistrationID,
        sectionName: SectionName.Type
    ) {
        guard candidateID.registrationID == id,
            let box = try? box(for: id, sectionName: sectionName)
        else {
            return
        }
        box.discardReplacement(candidateID)
    }

    fileprivate func close<SectionName: Hashable & Sendable>(
        _ id: WebInspectorFetchedResultsQueryRegistrationID,
        sectionName: SectionName.Type
    ) {
        guard let entry = registrations[id],
            entry.box is _WebInspectorFetchedResultsRegistrationBox<Model, SectionName>
        else {
            return
        }
        registrations.removeValue(forKey: id)?.finish(nil)
    }

    private func rebase<SectionName: Hashable & Sendable>(
        _ token: WebInspectorRevisionedSnapshotRebaseToken,
        for id: WebInspectorFetchedResultsQueryRegistrationID,
        sectionName: SectionName.Type
    ) throws -> WebInspectorRevisionedSnapshotRebase<
        WebInspectorFetchedResultsSnapshot<Model.ID, SectionName>
    > {
        let box = try box(for: id, sectionName: sectionName)
        let rebase = try box.publication.rebase(
            token,
            revision: box.revision,
            snapshot: box.currentSnapshot()
        )
        box.performanceCounters.rebaseSnapshotCount += 1
        return rebase
    }

    private func install<SectionName: Hashable & Sendable>(
        _ box: _WebInspectorFetchedResultsRegistrationBox<Model, SectionName>
    ) -> WebInspectorFetchedResultsQueryRegistration<Model, SectionName> {
        precondition(
            nextRegistrationID < UInt64.max,
            "Fetched-results registration identity overflowed."
        )
        nextRegistrationID += 1
        let id = WebInspectorFetchedResultsQueryRegistrationID(
            rawValue: nextRegistrationID
        )
        registrations[id] = Entry(box)
        return WebInspectorFetchedResultsQueryRegistration(id: id, owner: self)
    }

    private func box<SectionName: Hashable & Sendable>(
        for id: WebInspectorFetchedResultsQueryRegistrationID,
        sectionName: SectionName.Type
    ) throws -> _WebInspectorFetchedResultsRegistrationBox<Model, SectionName> {
        guard
            let box = registrations[id]?.box
                as? _WebInspectorFetchedResultsRegistrationBox<Model, SectionName>
        else {
            throw WebInspectorFetchedResultsQueryCoreError.closedRegistration
        }
        return box
    }

    private func terminateRegistration(
        _ id: WebInspectorFetchedResultsQueryRegistrationID,
        with error: any Error
    ) {
        registrations.removeValue(forKey: id)?.finish(error)
    }

    private func ensureOpen() throws {
        if isClosed {
            throw WebInspectorFetchedResultsQueryCoreError.closedRegistration
        }
    }

    private func applyToSource(
        _ change: WebInspectorFetchedResultsSourceChange<Model>
    ) -> _WebInspectorFetchedResultsSourceMutation<Model> {
        switch change {
        case let .insert(record):
            let id = record.value.id
            precondition(
                recordsByID[id] == nil,
                "Fetched-results source cannot insert an existing identity."
            )
            sourcePerformanceCounters.canonicalRankLookupCount += 1
            precondition(
                itemIDByCanonicalRank[record.canonicalRank] == nil,
                "Fetched-results canonical ranks must be unique."
            )
            recordsByID[id] = record
            itemIDByCanonicalRank[record.canonicalRank] = id
            let appendedToCanonicalOrder: Bool
            if let lastID = canonicalItemIDs.last {
                guard let lastRecord = recordsByID[lastID] else {
                    preconditionFailure(
                        "Fetched-results canonical order referenced an unknown identity."
                    )
                }
                if lastRecord.canonicalRank < record.canonicalRank {
                    appendedToCanonicalOrder = true
                    sourcePerformanceCounters.canonicalAppendCount += 1
                    canonicalItemIDs.append(id)
                } else {
                    appendedToCanonicalOrder = false
                    sourcePerformanceCounters.canonicalBinarySearchInsertionCount += 1
                    let index = canonicalInsertionIndex(for: record.canonicalRank)
                    canonicalItemIDs.insert(id, at: index)
                }
            } else {
                appendedToCanonicalOrder = true
                sourcePerformanceCounters.canonicalAppendCount += 1
                canonicalItemIDs.append(id)
            }
            return .insert(id, appendedToCanonicalOrder: appendedToCanonicalOrder)

        case let .update(record):
            let id = record.value.id
            guard let previous = recordsByID[id] else {
                preconditionFailure(
                    "Fetched-results source cannot update an unknown identity."
                )
            }
            precondition(
                previous.canonicalRank == record.canonicalRank,
                "Fetched-results canonical rank must remain stable for an identity."
            )
            recordsByID[id] = record
            return .update(id)

        case let .contentOnly(id):
            precondition(
                recordsByID[id] != nil,
                "Fetched-results source cannot update content for an unknown identity."
            )
            return .contentOnly(id)

        case let .delete(id):
            guard let previous = recordsByID[id] else {
                preconditionFailure(
                    "Fetched-results source cannot delete an unknown identity."
                )
            }
            let index = canonicalInsertionIndex(for: previous.canonicalRank)
            precondition(
                index < canonicalItemIDs.count && canonicalItemIDs[index] == id,
                "Fetched-results canonical order lost an identity."
            )
            canonicalItemIDs.remove(at: index)
            recordsByID.removeValue(forKey: id)
            precondition(
                itemIDByCanonicalRank.removeValue(forKey: previous.canonicalRank)
                    == id,
                "Fetched-results canonical rank index lost an identity."
            )
            return .delete(id)

        case let .reset(records):
            let replacement = Self.validatedSource(records)
            for (id, previous) in recordsByID {
                if let current = replacement.recordsByID[id] {
                    precondition(
                        previous.canonicalRank == current.canonicalRank,
                        "Fetched-results reset changed a surviving identity's canonical rank."
                    )
                }
            }
            recordsByID = replacement.recordsByID
            canonicalItemIDs = replacement.canonicalItemIDs
            itemIDByCanonicalRank = replacement.itemIDByCanonicalRank
            return .reset
        }
    }

    private func canonicalInsertionIndex(
        for rank: WebInspectorFetchedResultsCanonicalRank
    ) -> Int {
        var lowerBound = 0
        var upperBound = canonicalItemIDs.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            guard let midpointRecord = recordsByID[canonicalItemIDs[midpoint]] else {
                preconditionFailure(
                    "Fetched-results canonical order referenced an unknown identity."
                )
            }
            if midpointRecord.canonicalRank < rank {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return lowerBound
    }

    private static func validatedSource(
        _ records: [SourceRecord]
    ) -> (
        recordsByID: [Model.ID: SourceRecord],
        canonicalItemIDs: [Model.ID],
        itemIDByCanonicalRank: [WebInspectorFetchedResultsCanonicalRank: Model.ID]
    ) {
        var recordsByID: [Model.ID: SourceRecord] = [:]
        recordsByID.reserveCapacity(records.count)
        var itemIDByCanonicalRank: [WebInspectorFetchedResultsCanonicalRank: Model.ID] = [:]
        itemIDByCanonicalRank.reserveCapacity(records.count)
        for record in records {
            precondition(
                recordsByID.updateValue(record, forKey: record.value.id) == nil,
                "Fetched-results source identities must be unique."
            )
            precondition(
                itemIDByCanonicalRank.updateValue(
                    record.value.id,
                    forKey: record.canonicalRank
                ) == nil,
                "Fetched-results canonical ranks must be unique."
            )
        }
        let canonicalItemIDs = records.sorted {
            $0.canonicalRank < $1.canonicalRank
        }.map(\.value.id)
        return (
            recordsByID,
            canonicalItemIDs,
            itemIDByCanonicalRank
        )
    }
}

private enum _WebInspectorFetchedResultsSectionToken<
    SectionName: Hashable & Sendable
>: Hashable, Sendable {
    case flat
    case named(SectionName)
}

private enum _WebInspectorFetchedResultsSourceMutation<
    Model: WebInspectorPersistentModel
> {
    case insert(Model.ID, appendedToCanonicalOrder: Bool)
    case update(Model.ID)
    case contentOnly(Model.ID)
    case delete(Model.ID)
    case reset
}

private struct _WebInspectorFetchedResultsEvaluation<
    Model: WebInspectorPersistentModel,
    SectionName: Hashable & Sendable
> {
    var matchingItemIDs: [Model.ID]
    var sectionTokensByID: [Model.ID: _WebInspectorFetchedResultsSectionToken<SectionName>]
    var visibleItemIDs: Set<Model.ID>
    var snapshot: WebInspectorFetchedResultsSnapshot<Model.ID, SectionName>?
}

private struct _WebInspectorFetchedResultsCandidate<
    Model: WebInspectorPersistentModel,
    SectionName: Hashable & Sendable
> {
    let id: WebInspectorFetchedResultsQueryCandidateID
    let descriptor: WebInspectorFetchDescriptor<Model>
    var evaluation: _WebInspectorFetchedResultsEvaluation<Model, SectionName>
}

private class _WebInspectorFetchedResultsRegistrationBox<
    Model: WebInspectorPersistentModel,
    SectionName: Hashable & Sendable
> {
    typealias SourceRecord = WebInspectorFetchedResultsSourceRecord<Model>
    typealias Snapshot = WebInspectorFetchedResultsSnapshot<Model.ID, SectionName>
    typealias Changes = WebInspectorFetchedResultsChanges<Model.ID, SectionName>
    typealias Evaluation = _WebInspectorFetchedResultsEvaluation<Model, SectionName>

    var descriptor: WebInspectorFetchDescriptor<Model>
    var active: Evaluation
    var candidate: _WebInspectorFetchedResultsCandidate<Model, SectionName>?
    var revision: UInt64 = 0
    var nextCandidateGeneration: UInt64 = 0
    var performanceCounters: WebInspectorFetchedResultsQueryPerformanceCounters
    let publication = WebInspectorRevisionedSnapshotPublication<
        Snapshot,
        Changes,
        any Error
    >()

    init(
        descriptor: WebInspectorFetchDescriptor<Model>,
        initial: Evaluation,
        performanceCounters: WebInspectorFetchedResultsQueryPerformanceCounters
    ) {
        self.descriptor = descriptor
        active = initial
        self.performanceCounters = performanceCounters
    }

    func state() -> WebInspectorFetchedResultsQueryState<Model.ID, SectionName> {
        WebInspectorFetchedResultsQueryState(
            revision: revision,
            snapshot: currentSnapshot()
        )
    }

    func sectionToken(
        for value: Model.QueryValue
    ) throws -> _WebInspectorFetchedResultsSectionToken<SectionName> {
        preconditionFailure("Fetched-results section evaluator is abstract.")
    }

    func makeSnapshot(
        visibleItemIDs: [Model.ID],
        sectionTokensByID: [Model.ID: _WebInspectorFetchedResultsSectionToken<SectionName>]
    ) -> Snapshot {
        preconditionFailure("Fetched-results snapshot evaluator is abstract.")
    }

    var supportsCanonicalFlatFastPath: Bool {
        false
    }

    func currentSnapshot() -> Snapshot {
        currentSnapshot(for: &active, descriptor: descriptor)
    }

    func currentSnapshot(
        for evaluation: inout Evaluation,
        descriptor: WebInspectorFetchDescriptor<Model>
    ) -> Snapshot {
        if let snapshot = evaluation.snapshot {
            return snapshot
        }
        let visibleItemIDs = window(
            evaluation.matchingItemIDs,
            descriptor: descriptor
        )
        let snapshot = materializeSnapshot(
            visibleItemIDs: visibleItemIDs,
            sectionTokensByID: evaluation.sectionTokensByID,
            counters: &performanceCounters
        )
        evaluation.snapshot = snapshot
        return snapshot
    }

    func apply(
        _ mutation: _WebInspectorFetchedResultsSourceMutation<Model>,
        recordsByID: [Model.ID: SourceRecord],
        canonicalItemIDs: [Model.ID]
    ) throws {
        let changes = try apply(
            mutation,
            to: &active,
            descriptor: descriptor,
            recordsByID: recordsByID,
            canonicalItemIDs: canonicalItemIDs
        )
        publish(changes)

        if var candidate {
            _ = try apply(
                mutation,
                to: &candidate.evaluation,
                descriptor: candidate.descriptor,
                recordsByID: recordsByID,
                canonicalItemIDs: canonicalItemIDs
            )
            self.candidate = candidate
        }
    }

    func prepareReplacement(
        _ descriptor: WebInspectorFetchDescriptor<Model>,
        recordsByID: [Model.ID: SourceRecord],
        canonicalItemIDs: [Model.ID],
        registrationID: WebInspectorFetchedResultsQueryRegistrationID
    ) throws -> WebInspectorFetchedResultsQueryCandidateID {
        try Task.checkCancellation()
        var counters = performanceCounters
        let evaluation = try evaluateAll(
            descriptor: descriptor,
            recordsByID: recordsByID,
            canonicalItemIDs: canonicalItemIDs,
            counters: &counters
        )
        try Task.checkCancellation()
        precondition(
            nextCandidateGeneration < UInt64.max,
            "Fetched-results candidate generation overflowed."
        )
        nextCandidateGeneration += 1
        let candidateID = WebInspectorFetchedResultsQueryCandidateID(
            registrationID: registrationID,
            generation: nextCandidateGeneration
        )
        candidate = _WebInspectorFetchedResultsCandidate(
            id: candidateID,
            descriptor: descriptor,
            evaluation: evaluation
        )
        performanceCounters = counters
        return candidateID
    }

    func commitReplacement(
        _ candidateID: WebInspectorFetchedResultsQueryCandidateID
    ) throws -> WebInspectorFetchedResultsQueryState<Model.ID, SectionName> {
        guard var candidate, candidate.id == candidateID else {
            throw WebInspectorFetchedResultsQueryCoreError.staleCandidate
        }
        let previousSnapshot = currentSnapshot()
        let nextSnapshot = currentSnapshot(
            for: &candidate.evaluation,
            descriptor: candidate.descriptor
        )
        descriptor = candidate.descriptor
        active = candidate.evaluation
        self.candidate = nil
        let changes = difference(
            from: previousSnapshot,
            to: nextSnapshot,
            updatedItemIDs: []
        )
        publish(changes)
        return state()
    }

    func discardReplacement(
        _ candidateID: WebInspectorFetchedResultsQueryCandidateID
    ) {
        guard candidate?.id == candidateID else {
            return
        }
        candidate = nil
    }

    func finish(_ error: (any Error)?) {
        if let error {
            publication.finish(throwing: error)
        } else {
            publication.finish()
        }
        candidate = nil
    }

    fileprivate func evaluateAll(
        descriptor: WebInspectorFetchDescriptor<Model>,
        recordsByID: [Model.ID: SourceRecord],
        canonicalItemIDs: [Model.ID],
        counters: inout WebInspectorFetchedResultsQueryPerformanceCounters
    ) throws -> Evaluation {
        counters.fullEvaluationCount += 1
        counters.fullEvaluationRecordCount += canonicalItemIDs.count

        var matchingItemIDs: [Model.ID] = []
        matchingItemIDs.reserveCapacity(canonicalItemIDs.count)
        for id in canonicalItemIDs {
            try Task.checkCancellation()
            guard let record = recordsByID[id] else {
                preconditionFailure(
                    "Fetched-results canonical order referenced an unknown record."
                )
            }
            if try matches(record.value, descriptor: descriptor) {
                matchingItemIDs.append(id)
            }
        }
        if descriptor.sortBy.isEmpty == false {
            matchingItemIDs.sort { lhsID, rhsID in
                ordersBefore(
                    lhsID,
                    rhsID,
                    descriptor: descriptor,
                    recordsByID: recordsByID
                )
            }
        }

        var sectionTokensByID: [Model.ID: _WebInspectorFetchedResultsSectionToken<SectionName>] = [:]
        sectionTokensByID.reserveCapacity(matchingItemIDs.count)
        for id in matchingItemIDs {
            try Task.checkCancellation()
            guard let record = recordsByID[id] else {
                preconditionFailure(
                    "Fetched-results matching order referenced an unknown record."
                )
            }
            sectionTokensByID[id] = try sectionToken(for: record.value)
        }

        let visibleItemIDs = window(
            matchingItemIDs,
            descriptor: descriptor
        )
        let snapshot = materializeSnapshot(
            visibleItemIDs: visibleItemIDs,
            sectionTokensByID: sectionTokensByID,
            counters: &counters
        )
        return Evaluation(
            matchingItemIDs: matchingItemIDs,
            sectionTokensByID: sectionTokensByID,
            visibleItemIDs: Set(visibleItemIDs),
            snapshot: snapshot
        )
    }

    private func apply(
        _ mutation: _WebInspectorFetchedResultsSourceMutation<Model>,
        to evaluation: inout Evaluation,
        descriptor: WebInspectorFetchDescriptor<Model>,
        recordsByID: [Model.ID: SourceRecord],
        canonicalItemIDs: [Model.ID]
    ) throws -> Changes {
        if let changes = try applyCanonicalFlatFastPath(
            mutation,
            to: &evaluation,
            descriptor: descriptor,
            recordsByID: recordsByID
        ) {
            return changes
        }

        switch mutation {
        case let .contentOnly(id):
            performanceCounters.contentOnlyVisitCount += 1
            guard evaluation.visibleItemIDs.contains(id) else {
                return Changes()
            }
            return Changes(updatedItemIDs: [id])

        case .reset:
            let previousSnapshot = currentSnapshot(
                for: &evaluation,
                descriptor: descriptor
            )
            evaluation = try evaluateAll(
                descriptor: descriptor,
                recordsByID: recordsByID,
                canonicalItemIDs: canonicalItemIDs,
                counters: &performanceCounters
            )
            let currentSnapshot = currentSnapshot(
                for: &evaluation,
                descriptor: descriptor
            )
            let updatedItemIDs = Set(previousSnapshot.itemIDs)
                .intersection(currentSnapshot.itemIDs)
            return difference(
                from: previousSnapshot,
                to: currentSnapshot,
                updatedItemIDs: updatedItemIDs
            )

        case let .insert(id, _), let .update(id), let .delete(id):
            performanceCounters.singleRecordEvaluationCount += 1
            let previousSnapshot = currentSnapshot(
                for: &evaluation,
                descriptor: descriptor
            )
            let previousVisibleItemIDs = evaluation.visibleItemIDs
            let previousSectionToken = evaluation.sectionTokensByID[id]
            evaluation.matchingItemIDs.removeAll { $0 == id }
            evaluation.sectionTokensByID.removeValue(forKey: id)

            let isUpdate: Bool
            switch mutation {
            case .update:
                isUpdate = true
            case .insert, .delete:
                isUpdate = false
            case .contentOnly, .reset:
                preconditionFailure("Handled before single-record evaluation.")
            }

            if case .delete = mutation {
                // Deletion only removes the prior match.
            } else {
                guard let record = recordsByID[id] else {
                    preconditionFailure(
                        "Fetched-results mutation referenced an unknown record."
                    )
                }
                if try matches(record.value, descriptor: descriptor) {
                    let index = matchingInsertionIndex(
                        for: id,
                        in: evaluation.matchingItemIDs,
                        descriptor: descriptor,
                        recordsByID: recordsByID
                    )
                    evaluation.matchingItemIDs.insert(id, at: index)
                    evaluation.sectionTokensByID[id] = try sectionToken(
                        for: record.value
                    )
                }
            }

            let visibleItemIDs = window(
                evaluation.matchingItemIDs,
                descriptor: descriptor
            )
            let changedVisibleSectionIsStable =
                previousVisibleItemIDs.contains(id) == false
                || previousSectionToken == evaluation.sectionTokensByID[id]
            if visibleItemIDs == previousSnapshot.itemIDs,
                changedVisibleSectionIsStable
            {
                let updatedItemIDs: Set<Model.ID> =
                    if isUpdate,
                        previousVisibleItemIDs.contains(id)
                    {
                        [id]
                    } else {
                        []
                    }
                return Changes(updatedItemIDs: updatedItemIDs)
            }

            evaluation.snapshot = materializeSnapshot(
                visibleItemIDs: visibleItemIDs,
                sectionTokensByID: evaluation.sectionTokensByID,
                counters: &performanceCounters
            )
            let visibleItemIDSet = Set(visibleItemIDs)
            evaluation.visibleItemIDs = visibleItemIDSet
            let updatedItemIDs: Set<Model.ID> =
                if isUpdate,
                    visibleItemIDSet.contains(id)
                {
                    [id]
                } else {
                    []
                }
            return difference(
                from: previousSnapshot,
                to: evaluation.snapshot!,
                updatedItemIDs: updatedItemIDs
            )
        }
    }

    private func applyCanonicalFlatFastPath(
        _ mutation: _WebInspectorFetchedResultsSourceMutation<Model>,
        to evaluation: inout Evaluation,
        descriptor: WebInspectorFetchDescriptor<Model>,
        recordsByID: [Model.ID: SourceRecord]
    ) throws -> Changes? {
        guard supportsCanonicalFlatFastPath,
            descriptor.predicate == nil,
            descriptor.sortBy.isEmpty,
            descriptor.fetchOffset == 0,
            descriptor.fetchLimit == nil
        else {
            return nil
        }

        switch mutation {
        case let .insert(id, appendedToCanonicalOrder):
            guard appendedToCanonicalOrder else {
                return nil
            }
            guard let record = recordsByID[id] else {
                preconditionFailure(
                    "Fetched-results append referenced an unknown record."
                )
            }
            precondition(
                evaluation.visibleItemIDs.insert(id).inserted,
                "Fetched-results append duplicated a visible identity."
            )
            let index = evaluation.matchingItemIDs.count
            evaluation.matchingItemIDs.append(id)
            evaluation.sectionTokensByID[id] = try sectionToken(for: record.value)
            evaluation.snapshot = nil
            performanceCounters.singleRecordEvaluationCount += 1
            performanceCounters.canonicalFlatAppendCount += 1
            return Changes(
                itemChanges: [
                    .insert(
                        itemID: id,
                        indexPath: .init(section: 0, item: index)
                    )
                ])

        case let .update(id):
            precondition(
                evaluation.visibleItemIDs.contains(id),
                "An unfiltered fetched-results update lost a visible identity."
            )
            performanceCounters.singleRecordEvaluationCount += 1
            performanceCounters.canonicalFlatStableUpdateCount += 1
            return Changes(updatedItemIDs: [id])

        case let .delete(id):
            guard let index = evaluation.matchingItemIDs.firstIndex(of: id) else {
                preconditionFailure(
                    "An unfiltered fetched-results deletion lost a visible identity."
                )
            }
            evaluation.matchingItemIDs.remove(at: index)
            evaluation.sectionTokensByID.removeValue(forKey: id)
            precondition(
                evaluation.visibleItemIDs.remove(id) != nil,
                "An unfiltered fetched-results deletion lost a visible identity."
            )
            evaluation.snapshot = nil
            performanceCounters.singleRecordEvaluationCount += 1
            performanceCounters.canonicalFlatDeleteCount += 1
            return Changes(
                itemChanges: [
                    .delete(
                        itemID: id,
                        indexPath: .init(section: 0, item: index)
                    )
                ])

        case .contentOnly, .reset:
            return nil
        }
    }

    private func materializeSnapshot(
        visibleItemIDs: [Model.ID],
        sectionTokensByID: [Model.ID: _WebInspectorFetchedResultsSectionToken<SectionName>],
        counters: inout WebInspectorFetchedResultsQueryPerformanceCounters
    ) -> Snapshot {
        counters.snapshotBuildCount += 1
        counters.snapshotMaterializedItemCount += visibleItemIDs.count
        return makeSnapshot(
            visibleItemIDs: visibleItemIDs,
            sectionTokensByID: sectionTokensByID
        )
    }

    private func matches(
        _ value: Model.QueryValue,
        descriptor: WebInspectorFetchDescriptor<Model>
    ) throws -> Bool {
        guard let predicate = descriptor.predicate else {
            return true
        }
        return try predicate.evaluate(value)
    }

    private func ordersBefore(
        _ lhsID: Model.ID,
        _ rhsID: Model.ID,
        descriptor: WebInspectorFetchDescriptor<Model>,
        recordsByID: [Model.ID: SourceRecord]
    ) -> Bool {
        guard let lhs = recordsByID[lhsID], let rhs = recordsByID[rhsID] else {
            preconditionFailure(
                "Fetched-results sort referenced an unknown record."
            )
        }
        for sortDescriptor in descriptor.sortBy {
            switch sortDescriptor.compare(lhs.value, rhs.value) {
            case .orderedAscending:
                return true
            case .orderedDescending:
                return false
            case .orderedSame:
                continue
            }
        }
        return lhs.canonicalRank < rhs.canonicalRank
    }

    private func matchingInsertionIndex(
        for id: Model.ID,
        in matchingItemIDs: [Model.ID],
        descriptor: WebInspectorFetchDescriptor<Model>,
        recordsByID: [Model.ID: SourceRecord]
    ) -> Int {
        var lowerBound = 0
        var upperBound = matchingItemIDs.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            if ordersBefore(
                matchingItemIDs[midpoint],
                id,
                descriptor: descriptor,
                recordsByID: recordsByID
            ) {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return lowerBound
    }

    private func window(
        _ matchingItemIDs: [Model.ID],
        descriptor: WebInspectorFetchDescriptor<Model>
    ) -> [Model.ID] {
        let lowerBound = min(descriptor.fetchOffset, matchingItemIDs.count)
        let remainingCount = matchingItemIDs.count - lowerBound
        let visibleCount =
            descriptor.fetchLimit.map {
                min($0, remainingCount)
            } ?? remainingCount
        var visibleItemIDs: [Model.ID] = []
        visibleItemIDs.reserveCapacity(visibleCount)
        for index in lowerBound..<(lowerBound + visibleCount) {
            visibleItemIDs.append(matchingItemIDs[index])
        }
        return visibleItemIDs
    }

    private func difference(
        from oldSnapshot: Snapshot,
        to newSnapshot: Snapshot,
        updatedItemIDs: Set<Model.ID>
    ) -> Changes {
        performanceCounters.differenceBuildCount += 1
        return _webInspectorFetchedResultsDifference(
            from: oldSnapshot,
            to: newSnapshot,
            updatedItemIDs: updatedItemIDs
        )
    }

    private func publish(_ changes: Changes) {
        guard changes.isEmpty == false else {
            return
        }
        precondition(
            revision < UInt64.max,
            "Fetched-results publication revision overflowed."
        )
        let nextRevision = revision + 1
        publication.publish(
            from: revision,
            to: nextRevision,
            changes: changes
        )
        revision = nextRevision
        performanceCounters.publicationCount += 1
    }
}

private final class _WebInspectorFetchedResultsFlatRegistrationBox<
    Model: WebInspectorPersistentModel
>: _WebInspectorFetchedResultsRegistrationBox<Model, Never> {
    typealias SourceRecord = WebInspectorFetchedResultsSourceRecord<Model>

    override var supportsCanonicalFlatFastPath: Bool {
        true
    }

    init(
        descriptor: WebInspectorFetchDescriptor<Model>,
        recordsByID: [Model.ID: SourceRecord],
        canonicalItemIDs: [Model.ID]
    ) throws {
        let placeholder = WebInspectorFetchedResultsSnapshot<Model.ID, Never>()
        super.init(
            descriptor: descriptor,
            initial: .init(
                matchingItemIDs: [],
                sectionTokensByID: [:],
                visibleItemIDs: [],
                snapshot: placeholder
            ),
            performanceCounters: .init()
        )
        var counters = WebInspectorFetchedResultsQueryPerformanceCounters()
        active = try evaluateAll(
            descriptor: descriptor,
            recordsByID: recordsByID,
            canonicalItemIDs: canonicalItemIDs,
            counters: &counters
        )
        performanceCounters = counters
    }

    override func sectionToken(
        for value: Model.QueryValue
    ) -> _WebInspectorFetchedResultsSectionToken<Never> {
        .flat
    }

    override func makeSnapshot(
        visibleItemIDs: [Model.ID],
        sectionTokensByID: [Model.ID: _WebInspectorFetchedResultsSectionToken<Never>]
    ) -> WebInspectorFetchedResultsSnapshot<Model.ID, Never> {
        for id in visibleItemIDs {
            guard case .flat = sectionTokensByID[id] else {
                preconditionFailure(
                    "An unsectioned fetched-results evaluator produced a named section."
                )
            }
        }
        return WebInspectorFetchedResultsSnapshot(itemIDs: visibleItemIDs)
    }

}

private final class _WebInspectorFetchedResultsSectionedRegistrationBox<
    Model: WebInspectorPersistentModel,
    SectionName: Hashable & Sendable
>: _WebInspectorFetchedResultsRegistrationBox<Model, SectionName> {
    typealias SourceRecord = WebInspectorFetchedResultsSourceRecord<Model>

    private let expression: Expression<Model.QueryValue, SectionName>

    init(
        descriptor: WebInspectorFetchDescriptor<Model>,
        sectionBy expression: Expression<Model.QueryValue, SectionName>,
        recordsByID: [Model.ID: SourceRecord],
        canonicalItemIDs: [Model.ID]
    ) throws {
        self.expression = expression
        let placeholder = WebInspectorFetchedResultsSnapshot<Model.ID, SectionName>(
            sections: []
        )
        super.init(
            descriptor: descriptor,
            initial: .init(
                matchingItemIDs: [],
                sectionTokensByID: [:],
                visibleItemIDs: [],
                snapshot: placeholder
            ),
            performanceCounters: .init()
        )
        var counters = WebInspectorFetchedResultsQueryPerformanceCounters()
        active = try evaluateAll(
            descriptor: descriptor,
            recordsByID: recordsByID,
            canonicalItemIDs: canonicalItemIDs,
            counters: &counters
        )
        performanceCounters = counters
    }

    override func sectionToken(
        for value: Model.QueryValue
    ) throws -> _WebInspectorFetchedResultsSectionToken<SectionName> {
        .named(try expression.evaluate(value))
    }

    override func makeSnapshot(
        visibleItemIDs: [Model.ID],
        sectionTokensByID: [Model.ID: _WebInspectorFetchedResultsSectionToken<SectionName>]
    ) -> WebInspectorFetchedResultsSnapshot<Model.ID, SectionName> {
        _webInspectorSectionedSnapshot(
            visibleItemIDs: visibleItemIDs,
            sectionTokensByID: sectionTokensByID
        )
    }
}

private struct _WebInspectorFetchedResultsAnyRegistrationEntry<
    Model: WebInspectorPersistentModel
> {
    let box: AnyObject
    let apply:
        (
            _WebInspectorFetchedResultsSourceMutation<Model>,
            [Model.ID: WebInspectorFetchedResultsSourceRecord<Model>],
            [Model.ID]
        ) throws -> Void
    let finish: ((any Error)?) -> Void

    init<SectionName: Hashable & Sendable>(
        _ box: _WebInspectorFetchedResultsRegistrationBox<Model, SectionName>
    ) {
        self.box = box
        apply = { mutation, recordsByID, canonicalItemIDs in
            try box.apply(
                mutation,
                recordsByID: recordsByID,
                canonicalItemIDs: canonicalItemIDs
            )
        }
        finish = { error in
            box.finish(error)
        }
    }
}

private func _webInspectorSectionedSnapshot<
    ItemID: Hashable & Sendable,
    SectionName: Hashable & Sendable
>(
    visibleItemIDs: [ItemID],
    sectionTokensByID: [ItemID: _WebInspectorFetchedResultsSectionToken<SectionName>]
) -> WebInspectorFetchedResultsSnapshot<ItemID, SectionName> {
    var sectionIndexesByName: [SectionName: Int] = [:]
    var names: [SectionName] = []
    var itemIDsBySection: [[ItemID]] = []
    for id in visibleItemIDs {
        guard case let .named(name)? = sectionTokensByID[id] else {
            preconditionFailure(
                "A sectioned fetched-results evaluator lost an item's section name."
            )
        }
        let sectionIndex: Int
        if let existingIndex = sectionIndexesByName[name] {
            sectionIndex = existingIndex
        } else {
            sectionIndex = names.count
            sectionIndexesByName[name] = sectionIndex
            names.append(name)
            itemIDsBySection.append([])
        }
        itemIDsBySection[sectionIndex].append(id)
    }
    return WebInspectorFetchedResultsSnapshot(
        sections: names.enumerated().map {
            index,
            name in
            .init(name: name, itemIDs: itemIDsBySection[index])
        })
}

private struct _WebInspectorFetchedResultsItemPosition<
    SectionName: Hashable & Sendable
> {
    let indexPath: WebInspectorFetchedResultsIndexPath
    let section: _WebInspectorFetchedResultsSectionToken<SectionName>
}

private func _webInspectorFetchedResultsDifference<
    ItemID: Hashable & Sendable,
    SectionName: Hashable & Sendable
>(
    from oldSnapshot: WebInspectorFetchedResultsSnapshot<ItemID, SectionName>,
    to newSnapshot: WebInspectorFetchedResultsSnapshot<ItemID, SectionName>,
    updatedItemIDs: Set<ItemID>
) -> WebInspectorFetchedResultsChanges<ItemID, SectionName> {
    let oldSectionNames = oldSnapshot.sectionNames
    let newSectionNames = newSnapshot.sectionNames
    let sectionDifference =
        newSectionNames
        .difference(from: oldSectionNames)
        .inferringMoves()
    var sectionDeletes: [WebInspectorFetchedResultsSectionChange<SectionName>] = []
    var sectionInserts: [WebInspectorFetchedResultsSectionChange<SectionName>] = []
    var sectionMoves: [WebInspectorFetchedResultsSectionChange<SectionName>] = []
    for change in sectionDifference {
        switch change {
        case let .remove(offset, name, associatedWith):
            if associatedWith == nil {
                sectionDeletes.append(.delete(sectionName: name, index: offset))
            }
        case let .insert(offset, name, associatedWith):
            if let oldOffset = associatedWith {
                sectionMoves.append(
                    .move(sectionName: name, from: oldOffset, to: offset)
                )
            } else {
                sectionInserts.append(.insert(sectionName: name, index: offset))
            }
        }
    }
    sectionDeletes.sort { lhs, rhs in
        _webInspectorSectionChangeIndex(lhs) > _webInspectorSectionChangeIndex(rhs)
    }
    sectionInserts.sort { lhs, rhs in
        _webInspectorSectionChangeIndex(lhs) < _webInspectorSectionChangeIndex(rhs)
    }
    sectionMoves.sort { lhs, rhs in
        _webInspectorSectionChangeDestination(lhs)
            < _webInspectorSectionChangeDestination(rhs)
    }

    let oldPositions = _webInspectorFetchedResultsPositions(oldSnapshot)
    let newPositions = _webInspectorFetchedResultsPositions(newSnapshot)
    let itemDifference = newSnapshot.itemIDs
        .difference(from: oldSnapshot.itemIDs)
        .inferringMoves()
    var itemDeletes: [WebInspectorFetchedResultsItemChange<ItemID>] = []
    var itemInserts: [WebInspectorFetchedResultsItemChange<ItemID>] = []
    var itemMoves: [WebInspectorFetchedResultsItemChange<ItemID>] = []
    var movedItemIDs: Set<ItemID> = []
    for change in itemDifference {
        switch change {
        case let .remove(_, id, associatedWith):
            if associatedWith == nil, let position = oldPositions[id] {
                itemDeletes.append(
                    .delete(itemID: id, indexPath: position.indexPath)
                )
            }
        case let .insert(_, id, associatedWith):
            guard let newPosition = newPositions[id] else {
                preconditionFailure(
                    "Fetched-results difference lost an inserted item position."
                )
            }
            if associatedWith != nil {
                guard let oldPosition = oldPositions[id] else {
                    preconditionFailure(
                        "Fetched-results difference lost a moved item position."
                    )
                }
                movedItemIDs.insert(id)
                itemMoves.append(
                    .move(
                        itemID: id,
                        from: oldPosition.indexPath,
                        to: newPosition.indexPath
                    )
                )
            } else {
                itemInserts.append(
                    .insert(itemID: id, indexPath: newPosition.indexPath)
                )
            }
        }
    }

    for id in newSnapshot.itemIDs where movedItemIDs.contains(id) == false {
        guard let oldPosition = oldPositions[id],
            let newPosition = newPositions[id],
            oldPosition.section != newPosition.section
        else {
            continue
        }
        movedItemIDs.insert(id)
        itemMoves.append(
            .move(
                itemID: id,
                from: oldPosition.indexPath,
                to: newPosition.indexPath
            )
        )
    }

    itemDeletes.sort { lhs, rhs in
        _webInspectorItemChangeSource(lhs) > _webInspectorItemChangeSource(rhs)
    }
    itemInserts.sort { lhs, rhs in
        _webInspectorItemChangeDestination(lhs)
            < _webInspectorItemChangeDestination(rhs)
    }
    itemMoves.sort { lhs, rhs in
        _webInspectorItemChangeDestination(lhs)
            < _webInspectorItemChangeDestination(rhs)
    }

    return WebInspectorFetchedResultsChanges(
        sectionChanges: sectionDeletes + sectionInserts + sectionMoves,
        itemChanges: itemDeletes + itemInserts + itemMoves,
        updatedItemIDs: updatedItemIDs.intersection(newSnapshot.itemIDs)
    )
}

private func _webInspectorFetchedResultsPositions<
    ItemID: Hashable & Sendable,
    SectionName: Hashable & Sendable
>(
    _ snapshot: WebInspectorFetchedResultsSnapshot<ItemID, SectionName>
) -> [ItemID: _WebInspectorFetchedResultsItemPosition<SectionName>] {
    var positions: [ItemID: _WebInspectorFetchedResultsItemPosition<SectionName>] = [:]
    positions.reserveCapacity(snapshot.itemIDs.count)
    if snapshot.sections.isEmpty {
        for (itemIndex, id) in snapshot.itemIDs.enumerated() {
            positions[id] = _WebInspectorFetchedResultsItemPosition(
                indexPath: .init(section: 0, item: itemIndex),
                section: .flat
            )
        }
        return positions
    }
    for (sectionIndex, section) in snapshot.sections.enumerated() {
        for (itemIndex, id) in section.itemIDs.enumerated() {
            positions[id] = _WebInspectorFetchedResultsItemPosition(
                indexPath: .init(section: sectionIndex, item: itemIndex),
                section: .named(section.name)
            )
        }
    }
    return positions
}

private func _webInspectorSectionChangeIndex<SectionName>(
    _ change: WebInspectorFetchedResultsSectionChange<SectionName>
) -> Int where SectionName: Hashable & Sendable {
    switch change {
    case let .insert(_, index), let .delete(_, index), let .update(_, index):
        index
    case let .move(_, from, _):
        from
    }
}

private func _webInspectorSectionChangeDestination<SectionName>(
    _ change: WebInspectorFetchedResultsSectionChange<SectionName>
) -> Int where SectionName: Hashable & Sendable {
    switch change {
    case let .insert(_, index), let .delete(_, index), let .update(_, index):
        index
    case let .move(_, _, to):
        to
    }
}

private func _webInspectorItemChangeSource<ItemID>(
    _ change: WebInspectorFetchedResultsItemChange<ItemID>
) -> WebInspectorFetchedResultsIndexPath where ItemID: Hashable & Sendable {
    switch change {
    case let .insert(_, indexPath),
        let .delete(_, indexPath),
        let .update(_, indexPath):
        indexPath
    case let .move(_, from, _):
        from
    }
}

private func _webInspectorItemChangeDestination<ItemID>(
    _ change: WebInspectorFetchedResultsItemChange<ItemID>
) -> WebInspectorFetchedResultsIndexPath where ItemID: Hashable & Sendable {
    switch change {
    case let .insert(_, indexPath),
        let .delete(_, indexPath),
        let .update(_, indexPath):
        indexPath
    case let .move(_, _, to):
        to
    }
}
