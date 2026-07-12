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

package final class _WebInspectorModelContextIdentity: Hashable, Sendable {
    package static func == (
        lhs: _WebInspectorModelContextIdentity,
        rhs: _WebInspectorModelContextIdentity
    ) -> Bool {
        lhs === rhs
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

package struct WebInspectorFetchedResultsQueryRegistrationToken<
    Model: WebInspectorPersistentModel,
    SectionName: Hashable & Sendable
>: Hashable, Sendable {
    fileprivate let contextIdentity: _WebInspectorModelContextIdentity
    package let publicationIdentity: ObjectIdentifier
    fileprivate let rawValue: UInt64
}

package struct WebInspectorFetchedResultsQueryCandidateToken<
    Model: WebInspectorPersistentModel,
    SectionName: Hashable & Sendable
>: Hashable, Sendable {
    fileprivate let registrationToken: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>
    fileprivate let generation: UInt64
}

package struct WebInspectorFetchedResultsSourceBatch<
    Model: WebInspectorPersistentModel
>: Sendable {
    package let canonicalRevision: UInt64
    package let changes: [WebInspectorFetchedResultsSourceChange<Model>]

    package init(
        canonicalRevision: UInt64,
        changes: [WebInspectorFetchedResultsSourceChange<Model>]
    ) {
        self.canonicalRevision = canonicalRevision
        self.changes = changes
    }
}

package struct WebInspectorFetchedResultsQueryState<
    ItemID: Hashable & Sendable,
    SectionName: Hashable & Sendable
>: Hashable, Sendable {
    package let revision: UInt64
    package let snapshot: WebInspectorFetchedResultsSnapshot<ItemID, SectionName>
}

package enum WebInspectorFetchedResultsQueryError: Error, Equatable, Sendable {
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
    package typealias Snapshot =
        WebInspectorFetchedResultsSnapshot<Model.ID, SectionName>
    package typealias Changes =
        WebInspectorFetchedResultsChanges<Model.ID, SectionName>
    package typealias Publication =
        WebInspectorRevisionedSnapshotPublication<Snapshot, Changes, any Error>

    private let contextCore: WebInspectorModelContextCore
    let token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>
    let publication: Publication

    init(
        contextCore: WebInspectorModelContextCore,
        token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>,
        publication: Publication
    ) {
        self.contextCore = contextCore
        self.token = token
        self.publication = publication
    }

    package func state() async throws -> WebInspectorFetchedResultsQueryState<
        Model.ID,
        SectionName
    > {
        try await contextCore.queryState(
            for: token,
            publication: publication
        )
    }

    package func updates() async throws -> WebInspectorFetchedResultsUpdateSequence<
        Model.ID,
        SectionName
    > {
        let base = try await contextCore.subscribe(
            to: token,
            publication: publication
        )
        return WebInspectorFetchedResultsUpdateSequence(
            base: base,
            rebase: { [contextCore, token, publication] rebaseToken in
                try await contextCore.rebase(
                    rebaseToken,
                    for: token,
                    publication: publication
                )
            }
        )
    }

    package func prepareReplacement(
        _ descriptor: WebInspectorFetchDescriptor<Model>
    ) async throws -> WebInspectorFetchedResultsQueryCandidateToken<Model, SectionName> {
        try await contextCore.prepareReplacement(
            descriptor,
            for: token,
            publication: publication
        )
    }

    package func commitReplacement(
        _ candidateToken: WebInspectorFetchedResultsQueryCandidateToken<Model, SectionName>
    ) async throws -> WebInspectorFetchedResultsQueryState<Model.ID, SectionName> {
        try await contextCore.commitReplacement(
            candidateToken,
            for: token,
            publication: publication
        )
    }

    package func discardReplacement(
        _ candidateToken: WebInspectorFetchedResultsQueryCandidateToken<Model, SectionName>
    ) async {
        await contextCore.discardReplacement(
            candidateToken,
            for: token,
            publication: publication
        )
    }

    package func close() async {
        await contextCore.closeQuery(
            token,
            publication: publication
        )
    }
}

protocol _WebInspectorAnyQueryEngine: AnyObject {
    var registrationCount: Int { get }
    func close(
        throwing error: (any Error)?
    ) -> _WebInspectorModelContextStagedQueryWork
}

enum _WebInspectorFetchedResultsDeliveryMode {
    case raw
    case controller(
        ownerID: WebInspectorFetchedResultsControllerOwnerID,
        lease: WebInspectorFetchedResultsControllerRegistrationLease
    )
}

struct _WebInspectorModelContextStagedQueryWork: Sendable {
    var controllerOwnerBatches: [WebInspectorFetchedResultsControllerOwnerMutationBatch] = []
    var controllerPublications: [_WebInspectorModelContextPendingQueryPublication] = []
    var rawPublications: [_WebInspectorModelContextPendingQueryPublication] = []

    mutating func append(
        _ delivery: _WebInspectorModelContextStagedQueryDelivery?
    ) {
        guard let delivery else {
            return
        }
        if let ownerBatch = delivery.ownerBatch {
            controllerOwnerBatches.append(ownerBatch)
        }
        guard let publication = delivery.publication else {
            return
        }
        switch delivery.mode {
        case .raw:
            rawPublications.append(publication)
        case .controller:
            controllerPublications.append(publication)
        }
    }

    mutating func append(
        contentsOf other: _WebInspectorModelContextStagedQueryWork
    ) {
        controllerOwnerBatches.append(contentsOf: other.controllerOwnerBatches)
        controllerPublications.append(contentsOf: other.controllerPublications)
        rawPublications.append(contentsOf: other.rawPublications)
    }
}

struct _WebInspectorModelContextStagedQueryDelivery {
    let mode: _WebInspectorFetchedResultsDeliveryMode
    let ownerBatch: WebInspectorFetchedResultsControllerOwnerMutationBatch?
    let publication: _WebInspectorModelContextPendingQueryPublication?
}

/// One type-erased query publication prepared by a context-core transaction.
///
/// The closure captures only synchronized publication state and Sendable
/// payload values. Query engines and registration boxes remain isolated to
/// `WebInspectorModelContextCore`.
struct _WebInspectorModelContextPendingQueryPublication: Sendable {
    private enum Admission: Sendable {
        case unconditional
        case whileActive(WebInspectorFetchedResultsControllerRegistrationLease)
    }

    private let admission: Admission
    private let publishBody: @Sendable () -> Void
    private let abortBody: @Sendable (any Error) -> Void

    init(
        whileActive lease: WebInspectorFetchedResultsControllerRegistrationLease? = nil,
        publish: @escaping @Sendable () -> Void,
        abort: @escaping @Sendable (any Error) -> Void
    ) {
        admission = lease.map(Admission.whileActive) ?? .unconditional
        publishBody = publish
        abortBody = abort
    }

    func publish() {
        if case let .whileActive(lease) = admission,
            lease.isActive == false
        {
            return
        }
        publishBody()
    }

    func abort(throwing error: any Error) {
        abortBody(error)
    }
}

final class _WebInspectorFetchedResultsQueryEngine<
    Model: WebInspectorPersistentModel
>: _WebInspectorAnyQueryEngine {
    private typealias SourceRecord = WebInspectorFetchedResultsSourceRecord<Model>
    private typealias Entry = _WebInspectorFetchedResultsAnyRegistrationEntry<Model>

    private var recordsByID: [Model.ID: SourceRecord]
    private var canonicalItemIDs: [Model.ID]
    private var itemIDByCanonicalRank: [WebInspectorFetchedResultsCanonicalRank: Model.ID]
    private let contextIdentity: _WebInspectorModelContextIdentity
    private var registrations: [UInt64: Entry] = [:]
    private var nextRegistrationID: UInt64 = 0
    var sourcePerformanceCounters =
        WebInspectorFetchedResultsSourcePerformanceCounters()
    private var lastCanonicalRevision: UInt64?
    private var isClosed = false

    init(
        contextIdentity: _WebInspectorModelContextIdentity,
        records: [WebInspectorFetchedResultsSourceRecord<Model>] = []
    ) {
        self.contextIdentity = contextIdentity
        let source = Self.validatedSource(records)
        recordsByID = source.recordsByID
        canonicalItemIDs = source.canonicalItemIDs
        itemIDByCanonicalRank = source.itemIDByCanonicalRank
    }

    func register(
        fetchDescriptor: WebInspectorFetchDescriptor<Model>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, Never>.Publication
    ) throws -> WebInspectorFetchedResultsQueryRegistrationToken<Model, Never> {
        try ensureOpen()
        let box = try _WebInspectorFetchedResultsFlatRegistrationBox<Model>(
            descriptor: fetchDescriptor,
            recordsByID: recordsByID,
            canonicalItemIDs: canonicalItemIDs,
            publication: publication,
            deliveryMode: .raw
        )
        return install(box)
    }

    func register<SectionName: Hashable & Sendable>(
        fetchDescriptor: WebInspectorFetchDescriptor<Model>,
        sectionBy: Expression<Model.QueryValue, SectionName>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication
    ) throws -> WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName> {
        try ensureOpen()
        let box = try _WebInspectorFetchedResultsSectionedRegistrationBox<Model, SectionName>(
            descriptor: fetchDescriptor,
            sectionBy: sectionBy,
            recordsByID: recordsByID,
            canonicalItemIDs: canonicalItemIDs,
            publication: publication,
            deliveryMode: .raw
        )
        return install(box)
    }

    func registerController(
        fetchDescriptor: WebInspectorFetchDescriptor<Model>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, Never>.Publication,
        ownerID: WebInspectorFetchedResultsControllerOwnerID,
        lease: WebInspectorFetchedResultsControllerRegistrationLease
    ) throws -> WebInspectorFetchedResultsQueryRegistrationToken<Model, Never> {
        try ensureOpen()
        let box = try _WebInspectorFetchedResultsFlatRegistrationBox<Model>(
            descriptor: fetchDescriptor,
            recordsByID: recordsByID,
            canonicalItemIDs: canonicalItemIDs,
            publication: publication,
            deliveryMode: .controller(ownerID: ownerID, lease: lease)
        )
        return install(box)
    }

    func registerController<SectionName: Hashable & Sendable>(
        fetchDescriptor: WebInspectorFetchDescriptor<Model>,
        sectionBy: Expression<Model.QueryValue, SectionName>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication,
        ownerID: WebInspectorFetchedResultsControllerOwnerID,
        lease: WebInspectorFetchedResultsControllerRegistrationLease
    ) throws -> WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName> {
        try ensureOpen()
        let box = try _WebInspectorFetchedResultsSectionedRegistrationBox<Model, SectionName>(
            descriptor: fetchDescriptor,
            sectionBy: sectionBy,
            recordsByID: recordsByID,
            canonicalItemIDs: canonicalItemIDs,
            publication: publication,
            deliveryMode: .controller(ownerID: ownerID, lease: lease)
        )
        return install(box)
    }

    func fetchIdentifiers(
        fetchDescriptor: WebInspectorFetchDescriptor<Model>
    ) throws -> [Model.ID] {
        try ensureOpen()
        let publication = WebInspectorFetchedResultsQueryRegistration<
            Model,
            Never
        >.Publication()
        let box = try _WebInspectorFetchedResultsFlatRegistrationBox<Model>(
            descriptor: fetchDescriptor,
            recordsByID: recordsByID,
            canonicalItemIDs: canonicalItemIDs,
            publication: publication,
            deliveryMode: .raw
        )
        return box.state().snapshot.itemIDs
    }

    func applyBatch(
        _ batch: WebInspectorFetchedResultsSourceBatch<Model>
    ) -> _WebInspectorModelContextStagedQueryWork {
        guard isClosed == false else {
            return _WebInspectorModelContextStagedQueryWork()
        }
        if let lastCanonicalRevision {
            precondition(
                lastCanonicalRevision < batch.canonicalRevision,
                "A context query engine can apply a canonical revision only once."
            )
        }

        var stagedWork = _WebInspectorModelContextStagedQueryWork()
        let cancelledControllerIDs = registrations.compactMap { id, entry in
            entry.controllerLeaseIsCancelled() ? id : nil
        }
        for id in cancelledControllerIDs {
            guard let entry = registrations.removeValue(forKey: id) else {
                preconditionFailure(
                    "A cancelled fetched-results controller registration disappeared before pruning."
                )
            }
            stagedWork.append(entry.stagedFinish(nil))
        }
        let registrationIDs = Array(registrations.keys)
        let onlyContentChanges =
            batch.changes.count > 1
            && batch.changes.allSatisfy(\.isContentOnly)
        for id in registrationIDs {
            registrations[id]?.beginBatch(
                batch.changes.count,
                onlyContentChanges
            )
        }

        for change in batch.changes {
            let mutation = applyToSource(change)
            for id in registrationIDs {
                guard let entry = registrations[id] else {
                    continue
                }
                do {
                    try entry.applyStaged(
                        mutation,
                        recordsByID,
                        canonicalItemIDs
                    )
                } catch {
                    registrations.removeValue(forKey: id)
                    stagedWork.append(entry.stagedFinish(error))
                }
            }
        }
        for id in registrationIDs {
            stagedWork.append(registrations[id]?.finishBatch())
        }
        lastCanonicalRevision = batch.canonicalRevision
        return stagedWork
    }

    var registrationCount: Int {
        registrations.count
    }

    func close(
        throwing error: (any Error)?
    ) -> _WebInspectorModelContextStagedQueryWork {
        guard isClosed == false else {
            return _WebInspectorModelContextStagedQueryWork()
        }
        isClosed = true
        let entries = registrations.values
        registrations.removeAll(keepingCapacity: false)
        recordsByID.removeAll(keepingCapacity: false)
        canonicalItemIDs.removeAll(keepingCapacity: false)
        itemIDByCanonicalRank.removeAll(keepingCapacity: false)
        var stagedWork = _WebInspectorModelContextStagedQueryWork()
        for entry in entries {
            stagedWork.append(entry.stagedFinish(error))
        }
        return stagedWork
    }

    func performanceCounters<SectionName: Hashable & Sendable>(
        for token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication
    ) throws -> WebInspectorFetchedResultsQueryPerformanceCounters {
        try box(for: token, publication: publication).performanceCounters
    }

    func resetPerformanceCounters<SectionName: Hashable & Sendable>(
        for token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication
    ) throws {
        try box(for: token, publication: publication).performanceCounters = .init()
    }

    func activeSubscriberCount<SectionName: Hashable & Sendable>(
        for token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication
    ) throws -> Int {
        try box(for: token, publication: publication)
            .publication.activeSubscriberCount
    }

    func waitingSubscriberCount<SectionName: Hashable & Sendable>(
        for token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication
    ) throws -> Int {
        try box(for: token, publication: publication)
            .publication.waitingSubscriberCountForTesting
    }

    func state<SectionName: Hashable & Sendable>(
        for token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication
    ) throws -> WebInspectorFetchedResultsQueryState<Model.ID, SectionName> {
        try box(for: token, publication: publication).state()
    }

    func subscribe<SectionName: Hashable & Sendable>(
        to token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication
    ) throws -> WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication.UpdateSequence {
        let box = try box(for: token, publication: publication)
        return publication.subscribe(
            revision: box.revision,
            snapshot: box.currentSnapshot()
        )
    }

    func prepareReplacement<SectionName: Hashable & Sendable>(
        _ descriptor: WebInspectorFetchDescriptor<Model>,
        for token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication
    ) throws -> WebInspectorFetchedResultsQueryCandidateToken<Model, SectionName> {
        let box = try box(for: token, publication: publication)
        do {
            return try box.prepareReplacement(
                descriptor,
                recordsByID: recordsByID,
                canonicalItemIDs: canonicalItemIDs,
                registrationToken: token
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            terminateRegistration(token.rawValue, with: error)
                .publication?
                .publish()
            throw error
        }
    }

    func commitReplacement<SectionName: Hashable & Sendable>(
        _ candidateToken: WebInspectorFetchedResultsQueryCandidateToken<Model, SectionName>,
        for token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication
    ) throws -> (
        WebInspectorFetchedResultsQueryState<Model.ID, SectionName>,
        _WebInspectorModelContextStagedQueryDelivery?
    ) {
        guard candidateToken.registrationToken == token else {
            throw WebInspectorFetchedResultsQueryError.staleCandidate
        }
        return try box(for: token, publication: publication)
            .commitReplacement(candidateToken)
    }

    func discardReplacement<SectionName: Hashable & Sendable>(
        _ candidateToken: WebInspectorFetchedResultsQueryCandidateToken<Model, SectionName>,
        for token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication
    ) {
        guard candidateToken.registrationToken == token,
            let box = try? box(for: token, publication: publication)
        else {
            return
        }
        box.discardReplacement(candidateToken)
    }

    func close<SectionName: Hashable & Sendable>(
        _ token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication
    ) -> _WebInspectorModelContextStagedQueryDelivery? {
        guard (try? box(for: token, publication: publication)) != nil else {
            return nil
        }
        return registrations.removeValue(forKey: token.rawValue)?.stagedFinish(nil)
    }

    func rebase<SectionName: Hashable & Sendable>(
        _ rebaseToken: WebInspectorRevisionedSnapshotRebaseToken,
        for token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication
    ) throws -> WebInspectorRevisionedSnapshotRebase<
        WebInspectorFetchedResultsSnapshot<Model.ID, SectionName>
    > {
        let box = try box(for: token, publication: publication)
        let rebase = try publication.rebase(
            rebaseToken,
            revision: box.revision,
            snapshot: box.currentSnapshot()
        )
        box.performanceCounters.rebaseSnapshotCount += 1
        return rebase
    }

    private func install<SectionName: Hashable & Sendable>(
        _ box: _WebInspectorFetchedResultsRegistrationBox<Model, SectionName>
    ) -> WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName> {
        precondition(
            nextRegistrationID < UInt64.max,
            "Fetched-results registration identity overflowed."
        )
        nextRegistrationID += 1
        let token = WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>(
            contextIdentity: contextIdentity,
            publicationIdentity: ObjectIdentifier(box.publication),
            rawValue: nextRegistrationID
        )
        registrations[token.rawValue] = Entry(box)
        return token
    }

    fileprivate func box<SectionName: Hashable & Sendable>(
        for token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication
    ) throws -> _WebInspectorFetchedResultsRegistrationBox<Model, SectionName> {
        guard
            token.contextIdentity === contextIdentity,
            token.publicationIdentity == ObjectIdentifier(publication),
            let box = registrations[token.rawValue]?.box
                as? _WebInspectorFetchedResultsRegistrationBox<Model, SectionName>,
            box.publication === publication
        else {
            throw WebInspectorFetchedResultsQueryError.closedRegistration
        }
        return box
    }

    private func terminateRegistration(
        _ id: UInt64,
        with error: any Error
    ) -> _WebInspectorModelContextStagedQueryDelivery {
        guard let entry = registrations.removeValue(forKey: id) else {
            preconditionFailure("A failing query registration disappeared before termination.")
        }
        return entry.stagedFinish(error)
    }

    private func ensureOpen() throws {
        if isClosed {
            throw WebInspectorFetchedResultsQueryError.closedRegistration
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

private extension WebInspectorFetchedResultsSourceChange {
    var isContentOnly: Bool {
        if case .contentOnly = self {
            return true
        }
        return false
    }
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
    let token: WebInspectorFetchedResultsQueryCandidateToken<Model, SectionName>
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
    typealias Publication = WebInspectorFetchedResultsQueryRegistration<
        Model,
        SectionName
    >.Publication

    private enum PendingBatch {
        case single(Changes?)
        case contentOnly(Set<Model.ID>)
        case snapshot(
            Snapshot,
            updatedItemIDs: Set<Model.ID>,
            containsReset: Bool
        )
    }

    private struct MutationImpact {
        var updatedItemIDs: Set<Model.ID> = []
        var containsReset = false
    }

    var descriptor: WebInspectorFetchDescriptor<Model>
    var active: Evaluation
    var candidate: _WebInspectorFetchedResultsCandidate<Model, SectionName>?
    var revision: UInt64 = 0
    var nextCandidateGeneration: UInt64 = 0
    var performanceCounters: WebInspectorFetchedResultsQueryPerformanceCounters
    let publication: Publication
    let deliveryMode: _WebInspectorFetchedResultsDeliveryMode
    private var pendingBatch: PendingBatch?

    init(
        descriptor: WebInspectorFetchDescriptor<Model>,
        initial: Evaluation,
        performanceCounters: WebInspectorFetchedResultsQueryPerformanceCounters,
        publication: Publication,
        deliveryMode: _WebInspectorFetchedResultsDeliveryMode
    ) {
        self.descriptor = descriptor
        active = initial
        self.performanceCounters = performanceCounters
        self.publication = publication
        self.deliveryMode = deliveryMode
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

    func beginBatch(
        changeCount: Int,
        onlyContentChanges: Bool
    ) {
        precondition(
            pendingBatch == nil,
            "A fetched-results registration cannot overlap source batches."
        )
        if changeCount <= 1 {
            pendingBatch = .single(nil)
        } else if onlyContentChanges {
            pendingBatch = .contentOnly([])
        } else {
            pendingBatch = .snapshot(
                currentSnapshot(),
                updatedItemIDs: [],
                containsReset: false
            )
        }
    }

    func applyStaged(
        _ mutation: _WebInspectorFetchedResultsSourceMutation<Model>,
        recordsByID: [Model.ID: SourceRecord],
        canonicalItemIDs: [Model.ID]
    ) throws {
        guard let pendingBatch else {
            preconditionFailure("A fetched-results mutation requires an active source batch.")
        }
        switch pendingBatch {
        case let .single(previous):
            precondition(
                previous == nil,
                "A single-change fetched-results batch received multiple mutations."
            )
            let changes = try apply(
                mutation,
                to: &active,
                descriptor: descriptor,
                recordsByID: recordsByID,
                canonicalItemIDs: canonicalItemIDs
            )
            self.pendingBatch = .single(changes)
        case let .contentOnly(updatedItemIDs):
            let changes = try apply(
                mutation,
                to: &active,
                descriptor: descriptor,
                recordsByID: recordsByID,
                canonicalItemIDs: canonicalItemIDs
            )
            self.pendingBatch = .contentOnly(
                updatedItemIDs.union(changes.updatedItemIDs)
            )
        case let .snapshot(snapshot, updatedItemIDs, containsReset):
            let impact = try applyWithoutDifference(
                mutation,
                to: &active,
                descriptor: descriptor,
                recordsByID: recordsByID,
                canonicalItemIDs: canonicalItemIDs
            )
            self.pendingBatch = .snapshot(
                snapshot,
                updatedItemIDs: updatedItemIDs.union(impact.updatedItemIDs),
                containsReset: containsReset || impact.containsReset
            )
        }

        if var candidate {
            _ = try applyWithoutDifference(
                mutation,
                to: &candidate.evaluation,
                descriptor: candidate.descriptor,
                recordsByID: recordsByID,
                canonicalItemIDs: canonicalItemIDs
            )
            self.candidate = candidate
        }
    }

    func finishBatch() -> _WebInspectorModelContextStagedQueryDelivery? {
        guard let pendingBatch else {
            preconditionFailure("A fetched-results source batch was finished twice.")
        }
        self.pendingBatch = nil

        let changes: Changes
        switch pendingBatch {
        case let .single(stagedChanges):
            changes = stagedChanges ?? Changes()
        case let .contentOnly(updatedItemIDs):
            changes = Changes(
                updatedItemIDs: updatedItemIDs.intersection(active.visibleItemIDs)
            )
        case let .snapshot(previousSnapshot, updatedItemIDs, containsReset):
            let currentSnapshot = currentSnapshot()
            let resetUpdatedItemIDs: Set<Model.ID> =
                if containsReset {
                    Set(previousSnapshot.itemIDs)
                } else {
                    []
                }
            changes = difference(
                from: previousSnapshot,
                to: currentSnapshot,
                updatedItemIDs:
                    updatedItemIDs
                    .union(resetUpdatedItemIDs)
                    .intersection(previousSnapshot.itemIDs)
                    .intersection(currentSnapshot.itemIDs)
            )
        }
        return stage(changes)
    }

    func prepareReplacement(
        _ descriptor: WebInspectorFetchDescriptor<Model>,
        recordsByID: [Model.ID: SourceRecord],
        canonicalItemIDs: [Model.ID],
        registrationToken: WebInspectorFetchedResultsQueryRegistrationToken<
            Model,
            SectionName
        >
    ) throws -> WebInspectorFetchedResultsQueryCandidateToken<Model, SectionName> {
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
        let candidateToken = WebInspectorFetchedResultsQueryCandidateToken(
            registrationToken: registrationToken,
            generation: nextCandidateGeneration
        )
        candidate = _WebInspectorFetchedResultsCandidate(
            token: candidateToken,
            descriptor: descriptor,
            evaluation: evaluation
        )
        performanceCounters = counters
        return candidateToken
    }

    func commitReplacement(
        _ candidateToken: WebInspectorFetchedResultsQueryCandidateToken<Model, SectionName>
    ) throws -> (
        WebInspectorFetchedResultsQueryState<Model.ID, SectionName>,
        _WebInspectorModelContextStagedQueryDelivery?
    ) {
        guard var candidate, candidate.token == candidateToken else {
            throw WebInspectorFetchedResultsQueryError.staleCandidate
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
        let stagedDelivery = stage(
            changes,
            forceControllerOwnerMutation: true
        )
        return (state(), stagedDelivery)
    }

    func discardReplacement(
        _ candidateToken: WebInspectorFetchedResultsQueryCandidateToken<Model, SectionName>
    ) {
        guard candidate?.token == candidateToken else {
            return
        }
        candidate = nil
    }

    func stagedFinish(_ error: (any Error)?) -> _WebInspectorModelContextStagedQueryDelivery {
        candidate = nil
        pendingBatch = nil
        let publication = _WebInspectorModelContextPendingQueryPublication(
            publish: { [publication] in
                if let error {
                    publication.finish(throwing: error)
                } else {
                    publication.finish()
                }
            },
            abort: { [publication] error in
                publication.finish(throwing: error)
            }
        )
        return _WebInspectorModelContextStagedQueryDelivery(
            mode: deliveryMode,
            ownerBatch: nil,
            publication: publication
        )
    }

    fileprivate func evaluateAll(
        descriptor: WebInspectorFetchDescriptor<Model>,
        recordsByID: [Model.ID: SourceRecord],
        canonicalItemIDs: [Model.ID],
        counters: inout WebInspectorFetchedResultsQueryPerformanceCounters,
        materializesSnapshot: Bool = true
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
        let snapshot: Snapshot? =
            if materializesSnapshot {
                materializeSnapshot(
                    visibleItemIDs: visibleItemIDs,
                    sectionTokensByID: sectionTokensByID,
                    counters: &counters
                )
            } else {
                nil
            }
        return Evaluation(
            matchingItemIDs: matchingItemIDs,
            sectionTokensByID: sectionTokensByID,
            visibleItemIDs: Set(visibleItemIDs),
            snapshot: snapshot
        )
    }

    private func applyWithoutDifference(
        _ mutation: _WebInspectorFetchedResultsSourceMutation<Model>,
        to evaluation: inout Evaluation,
        descriptor: WebInspectorFetchDescriptor<Model>,
        recordsByID: [Model.ID: SourceRecord],
        canonicalItemIDs: [Model.ID]
    ) throws -> MutationImpact {
        if let changes = try applyCanonicalFlatFastPath(
            mutation,
            to: &evaluation,
            descriptor: descriptor,
            recordsByID: recordsByID
        ) {
            return MutationImpact(updatedItemIDs: changes.updatedItemIDs)
        }

        switch mutation {
        case let .contentOnly(id):
            performanceCounters.contentOnlyVisitCount += 1
            return MutationImpact(updatedItemIDs: [id])

        case .reset:
            evaluation = try evaluateAll(
                descriptor: descriptor,
                recordsByID: recordsByID,
                canonicalItemIDs: canonicalItemIDs,
                counters: &performanceCounters,
                materializesSnapshot: false
            )
            return MutationImpact(containsReset: true)

        case let .insert(id, _), let .update(id), let .delete(id):
            performanceCounters.singleRecordEvaluationCount += 1
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
            evaluation.visibleItemIDs = Set(visibleItemIDs)
            evaluation.snapshot = nil
            return MutationImpact(
                updatedItemIDs: isUpdate ? [id] : []
            )
        }
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

    private func stage(
        _ changes: Changes,
        forceControllerOwnerMutation: Bool = false
    ) -> _WebInspectorModelContextStagedQueryDelivery? {
        guard changes.isEmpty == false else {
            guard forceControllerOwnerMutation,
                case let .controller(ownerID, lease) = deliveryMode
            else {
                return nil
            }
            return _WebInspectorModelContextStagedQueryDelivery(
                mode: deliveryMode,
                ownerBatch: WebInspectorFetchedResultsControllerOwnerMutationBatch(
                    ownerID: ownerID,
                    lease: lease,
                    backing: WebInspectorFetchedResultsControllerBacking(
                        fetchDescriptor: descriptor,
                        revision: revision,
                        snapshot: currentSnapshot()
                    )
                ),
                publication: nil
            )
        }
        precondition(
            revision < UInt64.max,
            "Fetched-results publication revision overflowed."
        )
        let nextRevision = revision + 1
        let previousRevision = revision
        revision = nextRevision
        performanceCounters.publicationCount += 1
        let lease: WebInspectorFetchedResultsControllerRegistrationLease?
        let ownerBatch: WebInspectorFetchedResultsControllerOwnerMutationBatch?
        switch deliveryMode {
        case .raw:
            lease = nil
            ownerBatch = nil
        case let .controller(ownerID, controllerLease):
            lease = controllerLease
            ownerBatch = WebInspectorFetchedResultsControllerOwnerMutationBatch(
                ownerID: ownerID,
                lease: controllerLease,
                backing: WebInspectorFetchedResultsControllerBacking(
                    fetchDescriptor: descriptor,
                    revision: revision,
                    snapshot: currentSnapshot()
                )
            )
        }
        return _WebInspectorModelContextStagedQueryDelivery(
            mode: deliveryMode,
            ownerBatch: ownerBatch,
            publication: _WebInspectorModelContextPendingQueryPublication(
                whileActive: lease,
                publish: { [publication] in
                    publication.publish(
                        from: previousRevision,
                        to: nextRevision,
                        changes: changes
                    )
                },
                abort: { [publication] error in
                    publication.finish(throwing: error)
                }
            )
        )
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
        canonicalItemIDs: [Model.ID],
        publication: Publication,
        deliveryMode: _WebInspectorFetchedResultsDeliveryMode
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
            performanceCounters: .init(),
            publication: publication,
            deliveryMode: deliveryMode
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
        canonicalItemIDs: [Model.ID],
        publication: Publication,
        deliveryMode: _WebInspectorFetchedResultsDeliveryMode
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
            performanceCounters: .init(),
            publication: publication,
            deliveryMode: deliveryMode
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
    let beginBatch: (Int, Bool) -> Void
    let applyStaged:
        (
            _WebInspectorFetchedResultsSourceMutation<Model>,
            [Model.ID: WebInspectorFetchedResultsSourceRecord<Model>],
            [Model.ID]
        ) throws -> Void
    let finishBatch: () -> _WebInspectorModelContextStagedQueryDelivery?
    let stagedFinish: ((any Error)?) -> _WebInspectorModelContextStagedQueryDelivery
    let controllerLeaseIsCancelled: () -> Bool

    init<SectionName: Hashable & Sendable>(
        _ box: _WebInspectorFetchedResultsRegistrationBox<Model, SectionName>
    ) {
        self.box = box
        beginBatch = { changeCount, onlyContentChanges in
            box.beginBatch(
                changeCount: changeCount,
                onlyContentChanges: onlyContentChanges
            )
        }
        applyStaged = { mutation, recordsByID, canonicalItemIDs in
            try box.applyStaged(
                mutation,
                recordsByID: recordsByID,
                canonicalItemIDs: canonicalItemIDs
            )
        }
        finishBatch = {
            box.finishBatch()
        }
        stagedFinish = { error in
            box.stagedFinish(error)
        }
        controllerLeaseIsCancelled = {
            if case let .controller(_, lease) = box.deliveryMode {
                return lease.isCancelled
            }
            return false
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
