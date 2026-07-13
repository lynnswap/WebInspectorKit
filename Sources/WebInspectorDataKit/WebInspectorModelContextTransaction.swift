import Synchronization

/// Record and fetched-results source work for one persistent-model type at one
/// canonical revision.
package struct WebInspectorModelSourceBatch<
    Model: WebInspectorPersistentModel,
    Record: WebInspectorModelRecord
>: Sendable {
    /// The authoritative record work represented by this source batch.
    package enum Records: Sendable {
        case reset([Model.ID: Record])
        case changes([WebInspectorModelRecordChange<Model, Record>])
    }

    package let recordGate: WebInspectorModelRecordGate<Model, Record>
    package let canonicalRevision: UInt64
    package let records: Records
    package let fetchedResults: WebInspectorFetchedResultsSourceBatch<Model>

    package init(
        recordGate: WebInspectorModelRecordGate<Model, Record>,
        canonicalRevision: UInt64,
        records: Records,
        fetchedResults: WebInspectorFetchedResultsSourceBatch<Model>
    ) {
        precondition(
            fetchedResults.canonicalRevision == canonicalRevision,
            "Record and fetched-results work must carry one canonical revision."
        )
        switch records {
        case .reset:
            precondition(
                fetchedResults.isAuthoritativeReset,
                "An authoritative record reset requires one fetched-results reset."
            )
        case .changes:
            precondition(
                fetchedResults.containsReset == false,
                "A contiguous record delta cannot carry a fetched-results reset."
            )
        }
        Self.validateOperationAlignment(
            records: records,
            fetchedResults: fetchedResults
        )

        self.recordGate = recordGate
        self.canonicalRevision = canonicalRevision
        self.records = records
        self.fetchedResults = fetchedResults
    }

    private static func validateOperationAlignment(
        records: Records,
        fetchedResults: WebInspectorFetchedResultsSourceBatch<Model>
    ) {
        switch records {
        case let .reset(recordValues):
            guard case let .reset(queryValues) = fetchedResults.changes[0] else {
                preconditionFailure(
                    "An authoritative model-source reset lost its fetched-results reset."
                )
            }
            let queryIDs = Set(queryValues.map(\.value.id))
            precondition(
                queryIDs.count == queryValues.count,
                "A fetched-results reset cannot contain duplicate model identities."
            )
            precondition(
                Set(recordValues.keys) == queryIDs,
                "Record and fetched-results resets must contain the same model identities."
            )

        case let .changes(recordChanges):
            var recordOperations: [Model.ID: _WebInspectorModelSourceOperation] = [:]
            recordOperations.reserveCapacity(recordChanges.count)
            for change in recordChanges {
                let operation: _WebInspectorModelSourceOperation
                let id: Model.ID
                switch change {
                case let .insert(changeID, _):
                    id = changeID
                    operation = .insert
                case let .update(changeID, _):
                    id = changeID
                    operation = .update
                case let .delete(changeID):
                    id = changeID
                    operation = .delete
                }
                precondition(
                    recordOperations.updateValue(operation, forKey: id) == nil,
                    "A model-source record delta cannot repeat one identity."
                )
            }

            var queryOperations: [Model.ID: _WebInspectorModelSourceOperation] = [:]
            queryOperations.reserveCapacity(fetchedResults.changes.count)
            for change in fetchedResults.changes {
                let operation: _WebInspectorModelSourceOperation
                let id: Model.ID
                switch change {
                case let .insert(record):
                    id = record.value.id
                    operation = .insert
                case let .update(record):
                    id = record.value.id
                    operation = .update
                case let .contentOnly(changeID):
                    id = changeID
                    operation = .update
                case let .delete(changeID):
                    id = changeID
                    operation = .delete
                case .reset:
                    preconditionFailure(
                        "A contiguous model-source delta cannot contain a reset."
                    )
                }
                precondition(
                    queryOperations.updateValue(operation, forKey: id) == nil,
                    "A fetched-results source delta cannot repeat one identity."
                )
            }
            precondition(
                recordOperations == queryOperations,
                "Record and fetched-results deltas must carry matching identity operations."
            )
        }
    }
}

private enum _WebInspectorModelSourceOperation: Equatable {
    case insert
    case update
    case delete
}

/// Type-erased source work for one model type in a heterogeneous context
/// transaction.
///
/// The erased value captures only a synchronized record gate and Sendable
/// source values. Model-specific query engines remain actor-confined to
/// ``WebInspectorModelContextCore``.
package struct AnyWebInspectorModelSourceBatch: Sendable {
    struct SourceIdentity: Equatable, Sendable {
        let recordGate: ObjectIdentifier
        let recordType: ObjectIdentifier
        let patchType: ObjectIdentifier
    }

    let canonicalRevision: UInt64
    let modelTypeID: ObjectIdentifier
    let sourceIdentity: SourceIdentity
    let queryBatch: WebInspectorModelContextQueryBatch
    private let prepareBody: @Sendable () throws -> _WebInspectorAnyPreparedModelRecordCommit

    package init<
        Model: WebInspectorPersistentModel,
        Record: WebInspectorModelRecord
    >(
        _ batch: WebInspectorModelSourceBatch<Model, Record>
    ) {
        canonicalRevision = batch.canonicalRevision
        modelTypeID = ObjectIdentifier(Model.self)
        sourceIdentity = SourceIdentity(
            recordGate: ObjectIdentifier(batch.recordGate),
            recordType: ObjectIdentifier(Record.self),
            patchType: ObjectIdentifier(Record.Patch.self)
        )
        queryBatch = WebInspectorModelContextQueryBatch(batch.fetchedResults)
        prepareBody = {
            let commit: WebInspectorModelRecordGateCommit<Model, Record>
            switch batch.records {
            case let .reset(records):
                commit = try batch.recordGate.prepareReset(
                    at: batch.canonicalRevision,
                    records: records
                )
            case let .changes(changes):
                commit = try batch.recordGate.prepareChanges(
                    at: batch.canonicalRevision,
                    changes: changes
                )
            }
            return _WebInspectorAnyPreparedModelRecordCommit(commit)
        }
    }

    func prepare()
        throws -> _WebInspectorAnyPreparedModelRecordCommit
    {
        try prepareBody()
    }
}

/// Type-erased owner work produced after one record gate installs a revision.
///
/// A context owner dispatches on ``modelTypeID`` and opens the batch with the
/// matching model and record types. The consuming closure runs synchronously on
/// that caller's isolation and is never captured by the context core.
package struct WebInspectorModelRecordOwnerMutationBatch: Sendable {
    package let modelTypeID: ObjectIdentifier

    private let recordTypeID: ObjectIdentifier
    private let payload: any Sendable
    let consumption = _WebInspectorModelRecordOwnerMutationConsumption()

    package init<
        Model: WebInspectorPersistentModel,
        Record: WebInspectorModelRecord
    >(
        _ mutations: [WebInspectorModelRecordOwnerMutation<Model, Record>]
    ) {
        modelTypeID = ObjectIdentifier(Model.self)
        recordTypeID = ObjectIdentifier(Record.self)
        payload = mutations
    }

    package func consume<
        Model: WebInspectorPersistentModel,
        Record: WebInspectorModelRecord,
        Output
    >(
        as model: Model.Type,
        recordType: Record.Type,
        _ body: ([WebInspectorModelRecordOwnerMutation<Model, Record>]) -> Output
    ) -> Output {
        precondition(
            modelTypeID == ObjectIdentifier(model)
                && recordTypeID == ObjectIdentifier(recordType),
            "A model-record owner mutation batch was opened with the wrong types."
        )
        guard
            let mutations =
                payload
                as? [WebInspectorModelRecordOwnerMutation<Model, Record>]
        else {
            preconditionFailure(
                "A model-record owner mutation payload lost its concrete types."
            )
        }
        return consumption.consume {
            body(mutations)
        }
    }
}

final class _WebInspectorModelRecordOwnerMutationConsumption: Sendable {
    private enum State: Sendable {
        case available
        case consuming
        case consumed
    }

    private let state = Mutex(State.available)

    var isConsumed: Bool {
        state.withLock { state in
            state == .consumed
        }
    }

    func consume<Output>(_ body: () -> Output) -> Output {
        state.withLock { state in
            guard state == .available else {
                preconditionFailure(
                    "A model-record owner mutation batch can be consumed only once."
                )
            }
            state = .consuming
        }
        let output = body()
        state.withLock { state in
            precondition(
                state == .consuming,
                "A model-record owner mutation batch lost its consumption phase."
            )
            state = .consumed
        }
        return output
    }
}

struct _WebInspectorAnyPreparedModelRecordCommit: Sendable {
    private let applyBody: @Sendable () throws -> WebInspectorModelRecordOwnerMutationBatch
    private let discardBody: @Sendable () throws -> Void

    init<
        Model: WebInspectorPersistentModel,
        Record: WebInspectorModelRecord
    >(
        _ commit: WebInspectorModelRecordGateCommit<Model, Record>
    ) {
        applyBody = {
            try WebInspectorModelRecordOwnerMutationBatch(commit.apply())
        }
        discardBody = {
            try commit.discard()
        }
    }

    func apply() throws -> WebInspectorModelRecordOwnerMutationBatch {
        try applyBody()
    }

    func discard() throws {
        try discardBody()
    }
}

package enum WebInspectorModelContextTransactionCommitResolution:
    Equatable,
    Sendable
{
    case published
    case aborted
}

/// One owner-mediated commit for a canonical model-context transaction.
///
/// Record gates are installed first. The context owner consumes the returned
/// mutations synchronously, then publishes fetched-results work before leaving
/// that same owner turn. Abort discards every still-prepared record commit and
/// terminates the staged query transaction.
package final class WebInspectorModelContextTransactionCommit: Sendable {
    private enum State: Sendable {
        case pending(
            [_WebInspectorAnyPreparedModelRecordCommit],
            WebInspectorModelContextQueryCommit
        )
        case aborting(WebInspectorModelContextQueryCommit)
        case resolved(WebInspectorModelContextTransactionCommitResolution)
    }

    package let canonicalRevision: UInt64
    private let state: Mutex<State>

    init(
        canonicalRevision: UInt64,
        recordCommits: [_WebInspectorAnyPreparedModelRecordCommit],
        queryCommit: WebInspectorModelContextQueryCommit
    ) {
        self.canonicalRevision = canonicalRevision
        state = Mutex(.pending(recordCommits, queryCommit))
    }

    /// Atomically installs records, synchronously lets the context owner consume
    /// every resulting mutation batch, and then publishes query changes.
    ///
    /// The closure is nonescaping and nonthrowing because owner mutation is a
    /// total schema operation. The transaction lock spans the complete phase, so
    /// an abort can win only before any record gate is installed. The closure
    /// must consume each batch exactly once and must not reenter this commit.
    @discardableResult
    package func publish(
        applyingOwnerMutations body: (
            [WebInspectorModelRecordOwnerMutationBatch],
            [WebInspectorFetchedResultsControllerOwnerMutationBatch]
        ) -> Void
    ) -> Bool {
        publish(
            applyingOwnerMutations: body,
            finalizingOwnerTransaction: {}
        )
    }

    /// Finalizes a schema-owned projection only after materialized model
    /// mutations and every fetched-results publication for this revision.
    @discardableResult
    package func publish(
        applyingOwnerMutations body: (
            [WebInspectorModelRecordOwnerMutationBatch],
            [WebInspectorFetchedResultsControllerOwnerMutationBatch]
        ) -> Void,
        finalizingOwnerTransaction finalize: () -> Void
    ) -> Bool {
        state.withLock { state in
            switch state {
            case let .pending(recordCommits, queryCommit):
                let mutations = recordCommits.map { commit in
                    do {
                        return try commit.apply()
                    } catch {
                        preconditionFailure(
                            "A prepared model-record commit became invalid during its exclusive owner phase: \(error)"
                        )
                    }
                }
                precondition(
                    queryCommit.publish(
                        applyingControllerOwnerMutations: { controllerMutations in
                            body(mutations, controllerMutations)
                            precondition(
                                mutations.allSatisfy { $0.consumption.isConsumed },
                                "Every model-record owner mutation batch must be consumed before query publication."
                            )
                        },
                        finalizingOwnerTransaction: finalize
                    ),
                    "A query abort cannot interleave with the exclusive owner publication phase."
                )
                state = .resolved(.published)
                return true

            case .aborting, .resolved(.aborted):
                return false

            case .resolved(.published):
                preconditionFailure(
                    "A model-context transaction can be published only once."
                )
            }
        }
    }

    /// Publishes a transaction whose registrations are all package raw queries.
    @discardableResult
    package func publish(
        applyingOwnerMutations body:
            ([WebInspectorModelRecordOwnerMutationBatch]) -> Void
    ) -> Bool {
        publish { recordMutations, controllerMutations in
            precondition(
                controllerMutations.isEmpty,
                "A controller-mode transaction requires fetched-results owner routing."
            )
            body(recordMutations)
        }
    }

    /// Resolves every record commit and terminates query work that has not won
    /// publication.
    package func abort(
        throwing error: any Error
    ) async -> WebInspectorModelContextTransactionCommitResolution {
        let queryCommit = state.withLock { state -> WebInspectorModelContextQueryCommit? in
            switch state {
            case let .pending(recordCommits, queryCommit):
                for recordCommit in recordCommits {
                    do {
                        try recordCommit.discard()
                    } catch {
                        preconditionFailure(
                            "A prepared model-record commit became invalid before discard: \(error)"
                        )
                    }
                }
                state = .aborting(queryCommit)
                return queryCommit

            case let .aborting(queryCommit):
                return queryCommit

            case .resolved:
                return nil
            }
        }

        guard let queryCommit else {
            return state.withLock { state in
                guard case let .resolved(resolution) = state else {
                    preconditionFailure(
                        "A resolved model-context transaction lost its resolution."
                    )
                }
                return resolution
            }
        }

        let queryResolution = await queryCommit.abort(throwing: error)
        let resolution: WebInspectorModelContextTransactionCommitResolution =
            switch queryResolution {
            case .published: .published
            case .aborted: .aborted
            }
        finish(resolution)
        return resolution
    }

    package var isPublishedForTesting: Bool {
        state.withLock { state in
            if case .resolved(.published) = state {
                return true
            }
            return false
        }
    }

    package var isAbortedForTesting: Bool {
        state.withLock { state in
            if case .resolved(.aborted) = state {
                return true
            }
            return false
        }
    }

    private func finish(
        _ resolution: WebInspectorModelContextTransactionCommitResolution
    ) {
        state.withLock { state in
            switch state {
            case .aborting:
                state = .resolved(resolution)
            case let .resolved(existing):
                precondition(
                    existing == resolution,
                    "A model-context transaction resolved inconsistently."
                )
            case .pending:
                preconditionFailure(
                    "A model-context transaction resolved before entering a terminal phase."
                )
            }
        }
    }
}

private extension WebInspectorFetchedResultsSourceBatch {
    var containsReset: Bool {
        changes.contains { change in
            if case .reset = change {
                return true
            }
            return false
        }
    }

    var isAuthoritativeReset: Bool {
        guard changes.count == 1, let change = changes.first else {
            return false
        }
        if case .reset = change {
            return true
        }
        return false
    }
}
