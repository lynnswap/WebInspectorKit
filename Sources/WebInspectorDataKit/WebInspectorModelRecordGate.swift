import Synchronization

/// A context-core value record with one authoritative mechanical patch
/// operation shared by record lookup and materialized model projection.
package protocol WebInspectorModelRecord: Sendable {
    associatedtype Patch: Sendable

    mutating func apply(_ patch: Patch)
}

/// A nonempty ordered patch sequence for one persistent identity.
package struct WebInspectorModelRecordPatchBatch<
    Record: WebInspectorModelRecord
>: Sendable {
    package let patches: [Record.Patch]

    package init(_ patches: [Record.Patch]) {
        precondition(
            patches.isEmpty == false,
            "A model-record update must carry at least one authoritative patch."
        )
        self.patches = patches
    }
}

extension WebInspectorModelRecordPatchBatch: Equatable
where Record.Patch: Equatable {}

/// One authoritative change to a persistent model's value record.
package enum WebInspectorModelRecordChange<
    Model: WebInspectorPersistentModel,
    Record: WebInspectorModelRecord
>: Sendable {
    case insert(id: Model.ID, record: Record)
    case update(
        id: Model.ID,
        patches: WebInspectorModelRecordPatchBatch<Record>
    )
    case delete(id: Model.ID)
}

extension WebInspectorModelRecordChange: Equatable
where Record: Equatable, Record.Patch: Equatable {}

/// One mutation that the context owner must apply to an already materialized model.
package enum WebInspectorModelRecordOwnerMutation<
    Model: WebInspectorPersistentModel,
    Record: WebInspectorModelRecord
>: Sendable {
    case replace(id: Model.ID, record: Record)
    case applyPatches(
        id: Model.ID,
        patches: WebInspectorModelRecordPatchBatch<Record>
    )
    case invalidate(id: Model.ID)
}

extension WebInspectorModelRecordOwnerMutation: Equatable
where Record: Equatable, Record.Patch: Equatable {}

/// A rejected model-record transaction or lifecycle operation.
package enum WebInspectorModelRecordGateError: Error, Equatable, Sendable {
    case closed
    case commitOutstanding
    case commitResolved
    case initialRevisionRequiresReset
    case staleRevision(current: UInt64, proposed: UInt64)
    case noncontiguousRevision(expected: UInt64, proposed: UInt64)
    case invalidInsert
    case invalidUpdate
    case invalidDelete
    case duplicateChange
}

private final class _WebInspectorModelRecordGateCommitIdentity: Sendable {}

private enum _WebInspectorModelRecordGatePreparedPayload<
    Model: WebInspectorPersistentModel,
    Record: WebInspectorModelRecord
>: Sendable {
    case reset(records: [Model.ID: Record])
    case changes([WebInspectorModelRecordChange<Model, Record>])
}

/// A Sendable, one-shot installation of one prepared model-record revision.
///
/// Preparing a commit does not change record lookup. The context owner applies
/// it only after it is ready to patch the materialized model instances returned
/// by ``apply()``, and consumes those mutations before leaving the same
/// synchronous owner turn. A failed context transaction must call ``discard()``.
package final class WebInspectorModelRecordGateCommit<
    Model: WebInspectorPersistentModel,
    Record: WebInspectorModelRecord
>: Sendable {
    package let revision: UInt64

    private let gate: WebInspectorModelRecordGate<Model, Record>
    private let identity: _WebInspectorModelRecordGateCommitIdentity
    private let payload: _WebInspectorModelRecordGatePreparedPayload<Model, Record>

    fileprivate init(
        gate: WebInspectorModelRecordGate<Model, Record>,
        identity: _WebInspectorModelRecordGateCommitIdentity,
        revision: UInt64,
        payload: _WebInspectorModelRecordGatePreparedPayload<Model, Record>
    ) {
        self.gate = gate
        self.identity = identity
        self.revision = revision
        self.payload = payload
    }

    /// Atomically installs this revision and returns mutations for models that
    /// had been claimed before the installation won the record-gate race.
    package func apply() throws -> [WebInspectorModelRecordOwnerMutation<Model, Record>] {
        try gate.apply(
            identity: identity,
            revision: revision,
            payload: payload
        )
    }

    /// Abandons this prepared revision without changing committed record state.
    package func discard() throws {
        try gate.discard(identity: identity)
    }
}

/// Synchronized immutable-record lookup and materialization admission for one
/// persistent model type in one model context.
///
/// The gate owns records and the set of identities already materialized by its
/// context. It contains no model objects or global-actor annotation. Its context
/// owner must complete `claim` followed by registry insertion, and commit
/// application followed by owner-mutation consumption, in synchronous owner
/// turns with no suspension between each pair. The mutex then determines whether
/// the owner receives a mutation or the later claim receives the final record.
package final class WebInspectorModelRecordGate<
    Model: WebInspectorPersistentModel,
    Record: WebInspectorModelRecord
>: Sendable {
    private struct OutstandingCommit: Sendable {
        let identity: _WebInspectorModelRecordGateCommitIdentity
        let revision: UInt64
    }

    private struct State: Sendable {
        var records: [Model.ID: Record] = [:]
        var claimedIDs: Set<Model.ID> = []
        var committedRevision: UInt64?
        var outstandingCommit: OutstandingCommit?
        var isClosed = false
    }

    private let state = Mutex(State())

    package init() {}

    /// The currently installed canonical revision, or `nil` before the initial reset.
    package var revision: UInt64? {
        state.withLock(\.committedRevision)
    }

    /// Returns the current record without marking its identity as materialized.
    package func record(for id: Model.ID) -> Record? {
        state.withLock { state in
            guard state.isClosed == false else {
                return nil
            }
            return state.records[id]
        }
    }

    /// Returns the current record and atomically marks an existing identity as
    /// materialized. A missing or closed identity is never claimed. The context
    /// owner inserts the corresponding model into its registry before leaving
    /// this synchronous owner turn.
    package func claim(_ id: Model.ID) -> Record? {
        state.withLock { state in
            guard state.isClosed == false,
                let record = state.records[id]
            else {
                return nil
            }
            state.claimedIDs.insert(id)
            return record
        }
    }

    /// Prepares an authoritative replacement snapshot. An initial reset may
    /// start at any revision; a later reset may bridge a revision gap.
    package func prepareReset(
        at revision: UInt64,
        records: [Model.ID: Record]
    ) throws -> WebInspectorModelRecordGateCommit<Model, Record> {
        try state.withLock { state in
            try ensureCanPrepare(state)
            if let current = state.committedRevision,
                revision <= current
            {
                throw WebInspectorModelRecordGateError.staleRevision(
                    current: current,
                    proposed: revision
                )
            }

            let identity = _WebInspectorModelRecordGateCommitIdentity()
            state.outstandingCommit = OutstandingCommit(
                identity: identity,
                revision: revision
            )
            return WebInspectorModelRecordGateCommit(
                gate: self,
                identity: identity,
                revision: revision,
                payload: .reset(records: records)
            )
        }
    }

    /// Prepares one contiguous authoritative delta from the committed revision.
    package func prepareChanges(
        at revision: UInt64,
        changes: [WebInspectorModelRecordChange<Model, Record>]
    ) throws -> WebInspectorModelRecordGateCommit<Model, Record> {
        try state.withLock { state in
            try ensureCanPrepare(state)
            guard let current = state.committedRevision else {
                throw WebInspectorModelRecordGateError.initialRevisionRequiresReset
            }
            guard revision > current else {
                throw WebInspectorModelRecordGateError.staleRevision(
                    current: current,
                    proposed: revision
                )
            }
            let expected = current + 1
            guard revision == expected else {
                throw WebInspectorModelRecordGateError.noncontiguousRevision(
                    expected: expected,
                    proposed: revision
                )
            }

            var seenIDs: Set<Model.ID> = []
            seenIDs.reserveCapacity(changes.count)
            for change in changes {
                let id: Model.ID
                switch change {
                case let .insert(changeID, _):
                    id = changeID
                case let .update(changeID, _):
                    id = changeID
                case let .delete(changeID):
                    id = changeID
                }
                guard seenIDs.insert(id).inserted else {
                    throw WebInspectorModelRecordGateError.duplicateChange
                }
                switch change {
                case let .insert(changeID, _):
                    guard state.records[changeID] == nil else {
                        throw WebInspectorModelRecordGateError.invalidInsert
                    }
                case let .update(changeID, _):
                    guard state.records[changeID] != nil else {
                        throw WebInspectorModelRecordGateError.invalidUpdate
                    }
                case let .delete(changeID):
                    guard state.records[changeID] != nil else {
                        throw WebInspectorModelRecordGateError.invalidDelete
                    }
                }
            }

            let identity = _WebInspectorModelRecordGateCommitIdentity()
            state.outstandingCommit = OutstandingCommit(
                identity: identity,
                revision: revision
            )
            return WebInspectorModelRecordGateCommit(
                gate: self,
                identity: identity,
                revision: revision,
                payload: .changes(changes)
            )
        }
    }

    /// Terminates lookup, resolves any prepared commit, and returns invalidation
    /// work for every model currently claimed by the context owner.
    package func close() -> [WebInspectorModelRecordOwnerMutation<Model, Record>] {
        state.withLock { state in
            guard state.isClosed == false else {
                return []
            }
            state.isClosed = true
            state.outstandingCommit = nil
            let mutations = state.claimedIDs.map {
                WebInspectorModelRecordOwnerMutation<Model, Record>.invalidate(id: $0)
            }
            state.records.removeAll(keepingCapacity: false)
            state.claimedIDs.removeAll(keepingCapacity: false)
            return mutations
        }
    }

    fileprivate func apply(
        identity: _WebInspectorModelRecordGateCommitIdentity,
        revision: UInt64,
        payload: _WebInspectorModelRecordGatePreparedPayload<Model, Record>
    ) throws -> [WebInspectorModelRecordOwnerMutation<Model, Record>] {
        try state.withLock { state in
            guard let outstandingCommit = state.outstandingCommit,
                outstandingCommit.identity === identity
            else {
                throw WebInspectorModelRecordGateError.commitResolved
            }
            precondition(
                outstandingCommit.revision == revision,
                "A model-record commit changed revision after preparation."
            )

            let mutations: [WebInspectorModelRecordOwnerMutation<Model, Record>]
            switch payload {
            case let .reset(records):
                mutations = state.claimedIDs.map { id in
                    if let record = records[id] {
                        return .replace(id: id, record: record)
                    }
                    return .invalidate(id: id)
                }
                state.claimedIDs = Set(
                    state.claimedIDs.lazy.filter { records[$0] != nil }
                )
                state.records = records

            case let .changes(changes):
                var deltaMutations: [WebInspectorModelRecordOwnerMutation<Model, Record>] = []
                deltaMutations.reserveCapacity(changes.count)
                for change in changes {
                    switch change {
                    case let .insert(id, record):
                        let previous = state.records.updateValue(record, forKey: id)
                        precondition(
                            previous == nil,
                            "A prepared model-record insertion became invalid before apply."
                        )

                    case let .update(id, patches):
                        guard var record = state.records[id] else {
                            preconditionFailure(
                                "A prepared model-record update became invalid before apply."
                            )
                        }
                        for patch in patches.patches {
                            record.apply(patch)
                        }
                        state.records[id] = record
                        if state.claimedIDs.contains(id) {
                            deltaMutations.append(
                                .applyPatches(id: id, patches: patches)
                            )
                        }

                    case let .delete(id):
                        let removed = state.records.removeValue(forKey: id)
                        precondition(
                            removed != nil,
                            "A prepared model-record deletion became invalid before apply."
                        )
                        if state.claimedIDs.remove(id) != nil {
                            deltaMutations.append(.invalidate(id: id))
                        }
                    }
                }
                mutations = deltaMutations
            }

            state.committedRevision = revision
            state.outstandingCommit = nil
            return mutations
        }
    }

    fileprivate func discard(
        identity: _WebInspectorModelRecordGateCommitIdentity
    ) throws {
        try state.withLock { state in
            guard let outstandingCommit = state.outstandingCommit,
                outstandingCommit.identity === identity
            else {
                throw WebInspectorModelRecordGateError.commitResolved
            }
            state.outstandingCommit = nil
        }
    }

    private func ensureCanPrepare(_ state: borrowing State) throws {
        guard state.isClosed == false else {
            throw WebInspectorModelRecordGateError.closed
        }
        guard state.outstandingCommit == nil else {
            throw WebInspectorModelRecordGateError.commitOutstanding
        }
    }
}
