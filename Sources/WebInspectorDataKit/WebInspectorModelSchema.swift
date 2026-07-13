import Synchronization

/// One complete record/query entry produced by a persistent-model schema at an
/// initial or reset boundary.
///
/// `queryValue` and `canonicalRank` are authoritative canonical inputs. The
/// schema registry never derives query semantics from `record`.
package struct WebInspectorModelSchemaSnapshotEntry<
    Model: WebInspectorPersistentModel,
    Record: WebInspectorModelRecord
>: Sendable {
    package let id: Model.ID
    package let record: Record
    package let queryValue: Model.QueryValue
    package let canonicalRank: WebInspectorFetchedResultsCanonicalRank

    package init(
        id: Model.ID,
        record: Record,
        queryValue: Model.QueryValue,
        canonicalRank: WebInspectorFetchedResultsCanonicalRank
    ) {
        precondition(
            queryValue.id == id,
            "A schema snapshot entry must use one identity for its record and query value."
        )
        self.id = id
        self.record = record
        self.queryValue = queryValue
        self.canonicalRank = canonicalRank
    }
}

/// A complete, duplicate-free projection of one model type from a canonical
/// snapshot.
package struct WebInspectorModelSchemaSnapshot<
    Model: WebInspectorPersistentModel,
    Record: WebInspectorModelRecord,
    OwnerEffect: Sendable
>: Sendable {
    package let entries: [WebInspectorModelSchemaSnapshotEntry<Model, Record>]
    package let ownerEffects: [OwnerEffect]

    package init(
        entries: [WebInspectorModelSchemaSnapshotEntry<Model, Record>],
        ownerEffects: [OwnerEffect] = []
    ) {
        precondition(
            Set(entries.map(\.id)).count == entries.count,
            "A model schema snapshot cannot repeat one identity."
        )
        precondition(
            Set(entries.map(\.canonicalRank)).count == entries.count,
            "A model schema snapshot cannot repeat one canonical rank."
        )
        self.entries = entries
        self.ownerEffects = ownerEffects
    }
}

/// One authoritative, already-coalesced record/query operation produced from
/// a canonical delta.
///
/// A query-visible update supplies both the authoritative `queryValue` and
/// `canonicalRank`. A content-only update supplies neither; neither value is
/// inferred from the patched record.
package enum WebInspectorModelSchemaChange<
    Model: WebInspectorPersistentModel,
    Record: WebInspectorModelRecord
>: Sendable {
    case insert(
        id: Model.ID,
        record: Record,
        queryValue: Model.QueryValue,
        canonicalRank: WebInspectorFetchedResultsCanonicalRank
    )
    case update(
        id: Model.ID,
        patches: WebInspectorModelRecordPatchBatch<Record>,
        queryValue: Model.QueryValue?,
        canonicalRank: WebInspectorFetchedResultsCanonicalRank?
    )
    case delete(id: Model.ID)
}

/// One model type's complete work for a canonical delta.
///
/// A schema closure must fold every canonical event for one identity into one
/// ordered, nonempty patch batch. Rejecting duplicate IDs at this boundary
/// keeps RecordGate and query operations structurally aligned without replacing
/// append-oriented record content.
package struct WebInspectorModelSchemaDelta<
    Model: WebInspectorPersistentModel,
    Record: WebInspectorModelRecord,
    OwnerEffect: Sendable
>: Sendable {
    package let changes: [WebInspectorModelSchemaChange<Model, Record>]
    package let ownerEffects: [OwnerEffect]

    package init(
        changes: [WebInspectorModelSchemaChange<Model, Record>],
        ownerEffects: [OwnerEffect] = []
    ) {
        var seenIDs: Set<Model.ID> = []
        seenIDs.reserveCapacity(changes.count)
        for change in changes {
            let id: Model.ID
            switch change {
            case let .insert(changeID, _, queryValue, _):
                id = changeID
                precondition(
                    queryValue.id == changeID,
                    "A schema insertion must use one identity for its record and query value."
                )
            case let .update(changeID, _, queryValue, canonicalRank):
                id = changeID
                precondition(
                    (queryValue == nil) == (canonicalRank == nil),
                    "A schema update must replace both query value and canonical rank, or neither."
                )
                if let queryValue {
                    precondition(
                        queryValue.id == changeID,
                        "A schema update must use one identity for its record and query value."
                    )
                }
            case let .delete(changeID):
                id = changeID
            }
            precondition(
                seenIDs.insert(id).inserted,
                "A model schema delta must coalesce repeated canonical patches for one identity."
            )
        }
        self.changes = changes
        self.ownerEffects = ownerEffects
    }
}

/// Synchronized read access to the last committed records while a schema folds
/// one canonical delta.
package struct WebInspectorModelSchemaRecordLookup<
    Model: WebInspectorPersistentModel,
    Record: WebInspectorModelRecord
>: Sendable {
    private let gate: WebInspectorModelRecordGate<Model, Record>

    fileprivate init(
        gate: WebInspectorModelRecordGate<Model, Record>
    ) {
        self.gate = gate
    }

    package func record(for id: Model.ID) -> Record? {
        gate.record(for: id)
    }
}

/// A callback-scoped view of the models already materialized by one schema
/// owner.
///
/// Owner effects use this view to update context resources attached to live
/// models without moving domain registries into ``WebInspectorModelContext``.
/// Looking up or iterating this view never claims a RecordGate identity and
/// therefore never materializes a model. The borrowing callback contract keeps
/// the view confined to the synchronous owner turn in which the effect is
/// applied.
package struct WebInspectorModelSchemaOwnerModels<
    Model: WebInspectorPersistentModel
>: ~Copyable {
    private let modelBody: (Model.ID) -> Model?
    private let forEachBody: (@escaping (Model) -> Void) -> Void

    fileprivate init(
        model: @escaping (Model.ID) -> Model?,
        forEach: @escaping (@escaping (Model) -> Void) -> Void
    ) {
        modelBody = model
        forEachBody = forEach
    }

    /// Returns a model only when this owner has already materialized it.
    package borrowing func model(for id: Model.ID) -> Model? {
        modelBody(id)
    }

    /// Visits the owner's currently materialized models without copying the
    /// registry or claiming any unmaterialized identity.
    package borrowing func forEachRegisteredModel(
        _ body: (Model) -> Void
    ) {
        withoutActuallyEscaping(body) { body in
            forEachBody(body)
        }
    }
}

private final class _WebInspectorModelSchemaDefinitionIdentity: Sendable {}

private struct _WebInspectorModelSchemaDefinition: Sendable {
    let identity: _WebInspectorModelSchemaDefinitionIdentity
    let modelTypeID: ObjectIdentifier
    let makeBoxes: @Sendable () -> _WebInspectorModelSchemaBoxPair
}

/// Stateless mapping and materialization policy for one persistent model type.
///
/// `Record` and `OwnerEffect` are implementation details inferred by this
/// initializer. Every call to a registry factory creates a fresh RecordGate and
/// owner identity graph while reusing these immutable mapping closures.
/// Snapshot effects rebuild canonical non-record projections such as DOM
/// topology. `resetOwnerProjection` must clear every transient topology and
/// context resource owned by this schema; reset/rebase/close call it before any
/// replacement snapshot effects or materialized-model mutations. Initial state
/// applies snapshot effects without first resetting an empty owner projection.
package struct WebInspectorModelSchema<
    Model: WebInspectorPersistentModel
>: Sendable {
    fileprivate let definition: _WebInspectorModelSchemaDefinition

    package init<
        Record: WebInspectorModelRecord,
        OwnerEffect: Sendable
    >(
        snapshot:
            @escaping @Sendable (
                WebInspectorCanonicalModelSnapshot
            ) -> WebInspectorModelSchemaSnapshot<Model, Record, OwnerEffect>,
        delta:
            @escaping @Sendable (
                WebInspectorCanonicalModelTransaction,
                WebInspectorModelSchemaRecordLookup<Model, Record>
            ) -> WebInspectorModelSchemaDelta<Model, Record, OwnerEffect>,
        makeModel:
            @escaping @Sendable (
                WebInspectorModelContext,
                Model.ID,
                Record
            ) -> Model,
        replaceModel:
            @escaping @Sendable (
                WebInspectorModelContext,
                Model,
                Record
            ) -> Void,
        applyPatch:
            @escaping @Sendable (
                WebInspectorModelContext,
                Model,
                Record.Patch
            ) -> Void,
        invalidateModel:
            @escaping @Sendable (
                WebInspectorModelContext,
                Model
            ) -> Void,
        applyOwnerEffect:
            @escaping @Sendable (
                WebInspectorModelContext,
                OwnerEffect,
                borrowing WebInspectorModelSchemaOwnerModels<Model>
            ) -> Void,
        resetOwnerProjection:
            @escaping @Sendable (
                WebInspectorModelContext,
                borrowing WebInspectorModelSchemaOwnerModels<Model>
            ) -> Void
    ) {
        let identity = _WebInspectorModelSchemaDefinitionIdentity()
        definition = _WebInspectorModelSchemaDefinition(
            identity: identity,
            modelTypeID: ObjectIdentifier(Model.self),
            makeBoxes: {
                let gate = WebInspectorModelRecordGate<Model, Record>()
                let core = _WebInspectorAnyModelSchemaCoreBox(
                    schemaIdentity: identity,
                    gate: gate,
                    snapshot: snapshot,
                    delta: delta
                )
                let owner = _WebInspectorAnyModelSchemaOwnerBox(
                    schemaIdentity: identity,
                    gate: gate,
                    makeModel: makeModel,
                    replaceModel: replaceModel,
                    applyPatch: applyPatch,
                    invalidateModel: invalidateModel,
                    applyOwnerEffect: applyOwnerEffect,
                    resetOwnerProjection: resetOwnerProjection
                )
                return _WebInspectorModelSchemaBoxPair(
                    core: core,
                    owner: owner
                )
            }
        )
    }
}

/// One type-erased persistent-model schema registration.
package struct WebInspectorModelSchemaRegistration: Sendable {
    fileprivate let definition: _WebInspectorModelSchemaDefinition

    package init<Model: WebInspectorPersistentModel>(
        _ schema: WebInspectorModelSchema<Model>
    ) {
        definition = schema.definition
    }
}

/// Immutable, heterogeneous persistent-model schema configuration.
package struct WebInspectorModelSchemaRegistry: Sendable {
    private let definitions: [_WebInspectorModelSchemaDefinition]

    package var configuredModelTypeIDs: Set<ObjectIdentifier> {
        Set(definitions.map(\.modelTypeID))
    }

    package var configuredModelTypeIDsInOrder: [ObjectIdentifier] {
        definitions.map(\.modelTypeID)
    }

    package init(
        _ registrations: [WebInspectorModelSchemaRegistration]
    ) {
        let definitions = registrations.map(\.definition)
        precondition(
            Set(definitions.map(\.modelTypeID)).count == definitions.count,
            "A model schema registry cannot configure one model type more than once."
        )
        self.definitions = definitions
    }

    /// Creates one fresh record/query core and caller-confined identity graph.
    package func makeContext() -> WebInspectorModelSchemaContext {
        let contextIdentity = _WebInspectorModelSchemaContextIdentity()
        let pairs = definitions.map { $0.makeBoxes() }
        precondition(
            pairs.map(\.core.modelTypeID) == definitions.map(\.modelTypeID),
            "A schema factory changed its configured model order or type."
        )
        precondition(
            pairs.map(\.owner.modelTypeID) == definitions.map(\.modelTypeID),
            "A schema owner factory changed its configured model order or type."
        )
        return WebInspectorModelSchemaContext(
            core: WebInspectorModelSchemaContextCore(
                contextIdentity: contextIdentity,
                boxes: pairs.map(\.core)
            ),
            owner: WebInspectorModelSchemaOwnerRegistry(
                contextIdentity: contextIdentity,
                boxes: pairs.map(\.owner)
            )
        )
    }

    /// Creates and binds one context-local schema graph for test and package
    /// owners that already exist.
    package func makeContext(
        owner: WebInspectorModelContext
    ) -> WebInspectorModelSchemaContext {
        let context = makeContext()
        context.owner.bind(to: owner)
        return context
    }
}

private final class _WebInspectorModelSchemaContextIdentity: Sendable {}

/// One registry-created pair. `core` is safe to hand to the detached context
/// core; `owner` remains confined to the actor that requested the pair.
package struct WebInspectorModelSchemaContext {
    package let core: WebInspectorModelSchemaContextCore
    package let owner: WebInspectorModelSchemaOwnerRegistry
}

@available(
    *,
    unavailable,
    message: "model schema contexts contain a caller-confined owner registry"
)
extension WebInspectorModelSchemaContext: Sendable {}

private struct _WebInspectorModelSchemaBoxPair {
    let core: _WebInspectorAnyModelSchemaCoreBox
    let owner: _WebInspectorAnyModelSchemaOwnerBox
}

private enum _WebInspectorModelSchemaEffectOperation<Effect: Sendable>: Sendable {
    case resetOwnerProjection
    case apply(Effect)
}

/// Type-erased, revision-local transient owner-projection work for one schema.
package struct WebInspectorModelSchemaOwnerEffectBatch: Sendable {
    package let modelTypeID: ObjectIdentifier
    fileprivate let schemaIdentity: ObjectIdentifier
    fileprivate let effectTypeID: ObjectIdentifier
    fileprivate let payload: any Sendable

    fileprivate init<
        Model: WebInspectorPersistentModel,
        Effect: Sendable
    >(
        schemaIdentity: _WebInspectorModelSchemaDefinitionIdentity,
        model: Model.Type,
        operations: [_WebInspectorModelSchemaEffectOperation<Effect>]
    ) {
        modelTypeID = ObjectIdentifier(model)
        self.schemaIdentity = ObjectIdentifier(schemaIdentity)
        effectTypeID = ObjectIdentifier(Effect.self)
        payload = operations
    }
}

private struct _WebInspectorAnyModelSchemaCoreBox: Sendable {
    let schemaIdentity: ObjectIdentifier
    let modelTypeID: ObjectIdentifier

    private let initialBody:
        @Sendable (
            UInt64,
            WebInspectorCanonicalModelSnapshot
        ) -> _WebInspectorModelSchemaCoreWork
    private let resetBody:
        @Sendable (
            UInt64,
            WebInspectorCanonicalModelSnapshot
        ) -> _WebInspectorModelSchemaCoreWork
    private let deltaBody:
        @Sendable (
            UInt64,
            WebInspectorCanonicalModelTransaction
        ) -> _WebInspectorModelSchemaCoreWork
    private let closeBody: @Sendable () -> _WebInspectorModelSchemaCloseWork

    init<
        Model: WebInspectorPersistentModel,
        Record: WebInspectorModelRecord,
        OwnerEffect: Sendable
    >(
        schemaIdentity: _WebInspectorModelSchemaDefinitionIdentity,
        gate: WebInspectorModelRecordGate<Model, Record>,
        snapshot:
            @escaping @Sendable (
                WebInspectorCanonicalModelSnapshot
            ) -> WebInspectorModelSchemaSnapshot<Model, Record, OwnerEffect>,
        delta:
            @escaping @Sendable (
                WebInspectorCanonicalModelTransaction,
                WebInspectorModelSchemaRecordLookup<Model, Record>
            ) -> WebInspectorModelSchemaDelta<Model, Record, OwnerEffect>
    ) {
        self.schemaIdentity = ObjectIdentifier(schemaIdentity)
        modelTypeID = ObjectIdentifier(Model.self)

        initialBody = { revision, canonicalSnapshot in
            let projection = snapshot(canonicalSnapshot)
            return Self.makeResetWork(
                schemaIdentity: schemaIdentity,
                gate: gate,
                revision: revision,
                projection: projection,
                effects: projection.ownerEffects.map { .apply($0) }
            )
        }
        resetBody = { revision, canonicalSnapshot in
            let projection = snapshot(canonicalSnapshot)
            let effects: [_WebInspectorModelSchemaEffectOperation<OwnerEffect>] =
                [
                    .resetOwnerProjection
                ] + projection.ownerEffects.map { .apply($0) }
            return Self.makeResetWork(
                schemaIdentity: schemaIdentity,
                gate: gate,
                revision: revision,
                projection: projection,
                effects: effects
            )
        }
        deltaBody = { revision, canonicalTransaction in
            let projection = delta(
                canonicalTransaction,
                WebInspectorModelSchemaRecordLookup(gate: gate)
            )
            return Self.makeDeltaWork(
                schemaIdentity: schemaIdentity,
                gate: gate,
                revision: revision,
                projection: projection
            )
        }
        closeBody = {
            let effects: [_WebInspectorModelSchemaEffectOperation<OwnerEffect>] = [
                .resetOwnerProjection
            ]
            return _WebInspectorModelSchemaCloseWork(
                effects: WebInspectorModelSchemaOwnerEffectBatch(
                    schemaIdentity: schemaIdentity,
                    model: Model.self,
                    operations: effects
                ),
                mutations: WebInspectorModelRecordOwnerMutationBatch(
                    gate.close()
                )
            )
        }
    }

    func initial(
        at revision: UInt64,
        snapshot: WebInspectorCanonicalModelSnapshot
    ) -> _WebInspectorModelSchemaCoreWork {
        initialBody(revision, snapshot)
    }

    func reset(
        at revision: UInt64,
        snapshot: WebInspectorCanonicalModelSnapshot
    ) -> _WebInspectorModelSchemaCoreWork {
        resetBody(revision, snapshot)
    }

    func delta(
        at revision: UInt64,
        transaction: WebInspectorCanonicalModelTransaction
    ) -> _WebInspectorModelSchemaCoreWork {
        deltaBody(revision, transaction)
    }

    func close() -> _WebInspectorModelSchemaCloseWork {
        closeBody()
    }

    private static func makeResetWork<
        Model: WebInspectorPersistentModel,
        Record: WebInspectorModelRecord,
        OwnerEffect: Sendable
    >(
        schemaIdentity: _WebInspectorModelSchemaDefinitionIdentity,
        gate: WebInspectorModelRecordGate<Model, Record>,
        revision: UInt64,
        projection: WebInspectorModelSchemaSnapshot<Model, Record, OwnerEffect>,
        effects: [_WebInspectorModelSchemaEffectOperation<OwnerEffect>]
    ) -> _WebInspectorModelSchemaCoreWork {
        var records: [Model.ID: Record] = [:]
        records.reserveCapacity(projection.entries.count)
        var queryRecords: [WebInspectorFetchedResultsSourceRecord<Model>] = []
        queryRecords.reserveCapacity(projection.entries.count)
        for entry in projection.entries {
            precondition(
                records.updateValue(entry.record, forKey: entry.id) == nil,
                "A validated schema snapshot repeated one identity."
            )
            queryRecords.append(
                WebInspectorFetchedResultsSourceRecord(
                    value: entry.queryValue,
                    canonicalRank: entry.canonicalRank
                )
            )
        }
        return _WebInspectorModelSchemaCoreWork(
            source: AnyWebInspectorModelSourceBatch(
                WebInspectorModelSourceBatch(
                    recordGate: gate,
                    canonicalRevision: revision,
                    records: .reset(records),
                    fetchedResults: WebInspectorFetchedResultsSourceBatch(
                        canonicalRevision: revision,
                        changes: [.reset(queryRecords)]
                    )
                )
            ),
            effects: WebInspectorModelSchemaOwnerEffectBatch(
                schemaIdentity: schemaIdentity,
                model: Model.self,
                operations: effects
            )
        )
    }

    private static func makeDeltaWork<
        Model: WebInspectorPersistentModel,
        Record: WebInspectorModelRecord,
        OwnerEffect: Sendable
    >(
        schemaIdentity: _WebInspectorModelSchemaDefinitionIdentity,
        gate: WebInspectorModelRecordGate<Model, Record>,
        revision: UInt64,
        projection: WebInspectorModelSchemaDelta<Model, Record, OwnerEffect>
    ) -> _WebInspectorModelSchemaCoreWork {
        var recordChanges: [WebInspectorModelRecordChange<Model, Record>] = []
        recordChanges.reserveCapacity(projection.changes.count)
        var queryChanges: [WebInspectorFetchedResultsSourceChange<Model>] = []
        queryChanges.reserveCapacity(projection.changes.count)

        for change in projection.changes {
            switch change {
            case let .insert(id, record, queryValue, canonicalRank):
                recordChanges.append(.insert(id: id, record: record))
                queryChanges.append(
                    .insert(
                        WebInspectorFetchedResultsSourceRecord(
                            value: queryValue,
                            canonicalRank: canonicalRank
                        )
                    )
                )
            case let .update(id, patches, queryValue, canonicalRank):
                recordChanges.append(.update(id: id, patches: patches))
                if let queryValue, let canonicalRank {
                    queryChanges.append(
                        .update(
                            WebInspectorFetchedResultsSourceRecord(
                                value: queryValue,
                                canonicalRank: canonicalRank
                            )
                        )
                    )
                } else {
                    queryChanges.append(.contentOnly(id))
                }
            case let .delete(id):
                recordChanges.append(.delete(id: id))
                queryChanges.append(.delete(id))
            }
        }

        return _WebInspectorModelSchemaCoreWork(
            source: AnyWebInspectorModelSourceBatch(
                WebInspectorModelSourceBatch(
                    recordGate: gate,
                    canonicalRevision: revision,
                    records: .changes(recordChanges),
                    fetchedResults: WebInspectorFetchedResultsSourceBatch(
                        canonicalRevision: revision,
                        changes: queryChanges
                    )
                )
            ),
            effects: WebInspectorModelSchemaOwnerEffectBatch(
                schemaIdentity: schemaIdentity,
                model: Model.self,
                operations: projection.ownerEffects.map {
                    .apply($0)
                }
            )
        )
    }
}

private struct _WebInspectorModelSchemaCoreWork: Sendable {
    let source: AnyWebInspectorModelSourceBatch
    let effects: WebInspectorModelSchemaOwnerEffectBatch
}

private struct _WebInspectorModelSchemaCloseWork: Sendable {
    let effects: WebInspectorModelSchemaOwnerEffectBatch
    let mutations: WebInspectorModelRecordOwnerMutationBatch
}

/// Sendable per-context schema projection. It owns no semantic record mirror;
/// committed records live only in the RecordGates shared with its owner boxes.
package final class WebInspectorModelSchemaContextCore: Sendable {
    private let contextIdentity: _WebInspectorModelSchemaContextIdentity
    private let boxes: [_WebInspectorAnyModelSchemaCoreBox]
    private let transactions = _WebInspectorModelSchemaTransactionTracker()

    fileprivate init(
        contextIdentity: _WebInspectorModelSchemaContextIdentity,
        boxes: [_WebInspectorAnyModelSchemaCoreBox]
    ) {
        self.contextIdentity = contextIdentity
        self.boxes = boxes
    }

    package func initial(
        at revision: UInt64,
        snapshot: WebInspectorCanonicalModelSnapshot
    ) -> WebInspectorModelSchemaTransaction {
        transactions.claimInitial()
        return makeTransaction(
            revision: revision,
            work: boxes.map { $0.initial(at: revision, snapshot: snapshot) }
        )
    }

    package func reset(
        at revision: UInt64,
        snapshot: WebInspectorCanonicalModelSnapshot
    ) -> WebInspectorModelSchemaTransaction {
        transactions.claimRevision()
        return makeTransaction(
            revision: revision,
            work: boxes.map { $0.reset(at: revision, snapshot: snapshot) }
        )
    }

    package func changes(
        at revision: UInt64,
        transaction: WebInspectorCanonicalModelTransaction
    ) -> WebInspectorModelSchemaTransaction {
        transactions.claimRevision()
        if let resetSnapshot = transaction.resetSnapshot {
            // Reset is authoritative for both persistent records and every
            // non-record owner projection. `resetOwnerProjection` must clear
            // all transient topology/resources, so domain delta effects that
            // coexist with this snapshot are intentionally subsumed rather
            // than applied to the replacement projection.
            return makeTransaction(
                revision: revision,
                work: boxes.map {
                    $0.reset(at: revision, snapshot: resetSnapshot)
                }
            )
        }
        return makeTransaction(
            revision: revision,
            work: boxes.map {
                $0.delta(at: revision, transaction: transaction)
            }
        )
    }

    package func close() -> WebInspectorModelSchemaClose {
        transactions.close()
        let work = boxes.map { $0.close() }
        return WebInspectorModelSchemaClose(
            contextIdentity: contextIdentity,
            effects: work.map(\.effects),
            mutations: work.map(\.mutations)
        )
    }

    private func makeTransaction(
        revision: UInt64,
        work: [_WebInspectorModelSchemaCoreWork]
    ) -> WebInspectorModelSchemaTransaction {
        precondition(
            work.map(\.source.modelTypeID) == boxes.map(\.modelTypeID),
            "Schema source work changed its configured model order or type."
        )
        return WebInspectorModelSchemaTransaction(
            contextIdentity: contextIdentity,
            canonicalRevision: revision,
            sources: work.map(\.source),
            effects: work.map(\.effects),
            transactions: transactions
        )
    }

}

/// Revision-local schema work before it is staged in the context query actor.
package struct WebInspectorModelSchemaTransaction: Sendable {
    private let contextIdentity: _WebInspectorModelSchemaContextIdentity
    package let canonicalRevision: UInt64
    private let sources: [AnyWebInspectorModelSourceBatch]
    private let effects: [WebInspectorModelSchemaOwnerEffectBatch]
    private let stageGate: _WebInspectorModelSchemaTransactionStageGate
    private let transactions: _WebInspectorModelSchemaTransactionTracker

    fileprivate init(
        contextIdentity: _WebInspectorModelSchemaContextIdentity,
        canonicalRevision: UInt64,
        sources: [AnyWebInspectorModelSourceBatch],
        effects: [WebInspectorModelSchemaOwnerEffectBatch],
        transactions: _WebInspectorModelSchemaTransactionTracker
    ) {
        self.contextIdentity = contextIdentity
        self.canonicalRevision = canonicalRevision
        self.sources = sources
        self.effects = effects
        stageGate = _WebInspectorModelSchemaTransactionStageGate()
        self.transactions = transactions
    }

    package func stage(
        on contextCore: WebInspectorModelContextCore
    ) async throws -> WebInspectorModelSchemaTransactionCommit {
        stageGate.claim()
        let combined: WebInspectorModelContextTransactionCommit
        do {
            combined = try await contextCore.applySourceBatches(
                at: canonicalRevision,
                sources
            )
        } catch {
            transactions.failOutstandingTransaction()
            throw error
        }
        precondition(
            combined.canonicalRevision == canonicalRevision,
            "A staged schema transaction changed canonical revision."
        )
        return WebInspectorModelSchemaTransactionCommit(
            contextIdentity: contextIdentity,
            combined: combined,
            effects: effects,
            transactions: transactions
        )
    }
}

private final class _WebInspectorModelSchemaTransactionTracker: Sendable {
    private enum Phase: Equatable, Sendable {
        case awaitingInitial
        case initialOutstanding
        case active
        case revisionOutstanding
        case failed
        case closed
    }

    private let phase = Mutex(Phase.awaitingInitial)

    func claimInitial() {
        phase.withLock { phase in
            guard phase == .awaitingInitial else {
                preconditionFailure(
                    "A model schema context core can prepare initial source work only once and before later revisions."
                )
            }
            phase = .initialOutstanding
        }
    }

    func claimRevision() {
        phase.withLock { phase in
            guard phase == .active else {
                preconditionFailure(
                    "A model schema context core requires one published initial revision and no outstanding transaction before preparing later source work."
                )
            }
            phase = .revisionOutstanding
        }
    }

    func publishOutstandingTransaction() {
        phase.withLock { phase in
            switch phase {
            case .initialOutstanding, .revisionOutstanding:
                phase = .active
            case .awaitingInitial, .active, .failed, .closed:
                preconditionFailure(
                    "A model schema transaction published outside its outstanding lifecycle phase."
                )
            }
        }
    }

    func failOutstandingTransaction() {
        phase.withLock { phase in
            switch phase {
            case .initialOutstanding, .revisionOutstanding:
                phase = .failed
            case .awaitingInitial, .active, .failed, .closed:
                preconditionFailure(
                    "A model schema transaction failed outside its outstanding lifecycle phase."
                )
            }
        }
    }

    func close() {
        phase.withLock { phase in
            switch phase {
            case .awaitingInitial, .active, .failed:
                phase = .closed
            case .initialOutstanding, .revisionOutstanding:
                preconditionFailure(
                    "A model schema context core can close only after its outstanding transaction resolves."
                )
            case .closed:
                preconditionFailure(
                    "A model schema context core can close only once."
                )
            }
        }
    }
}

private final class _WebInspectorModelSchemaTransactionStageGate: Sendable {
    private let wasClaimed = Mutex(false)

    func claim() {
        let didClaim = wasClaimed.withLock { wasClaimed in
            guard wasClaimed == false else {
                return false
            }
            wasClaimed = true
            return true
        }
        precondition(
            didClaim,
            "A model schema transaction can be staged only once."
        )
    }
}

/// One owner-mediated schema commit. It stores only the existing combined
/// record/query commit plus immutable effects for this revision.
package final class WebInspectorModelSchemaTransactionCommit: Sendable {
    package let canonicalRevision: UInt64
    private let contextIdentity: _WebInspectorModelSchemaContextIdentity
    private let combined: WebInspectorModelContextTransactionCommit
    private let effects: [WebInspectorModelSchemaOwnerEffectBatch]
    private let transactions: _WebInspectorModelSchemaTransactionTracker
    private let didResolve = Mutex(false)

    fileprivate init(
        contextIdentity: _WebInspectorModelSchemaContextIdentity,
        combined: WebInspectorModelContextTransactionCommit,
        effects: [WebInspectorModelSchemaOwnerEffectBatch],
        transactions: _WebInspectorModelSchemaTransactionTracker
    ) {
        self.contextIdentity = contextIdentity
        self.combined = combined
        canonicalRevision = combined.canonicalRevision
        self.effects = effects
        self.transactions = transactions
    }

    /// Installs all RecordGates, then applies every owner-projection effect, every
    /// materialized-model mutation, and finally the staged query publication in
    /// one synchronous caller-owner turn.
    @discardableResult
    package func publish(
        on registry: WebInspectorModelSchemaOwnerRegistry,
        owner: WebInspectorModelContext
    ) -> Bool {
        registry.requireContextIdentity(contextIdentity)
        registry.requireOwnerIdentity(owner)
        let didPublish = combined.publish { mutations, controllerMutations in
            registry.apply(effects: effects, owner: owner)
            registry.apply(mutations: mutations, owner: owner)
            owner.applyFetchedResultsControllerOwnerMutations(
                controllerMutations
            )
        }
        if didPublish {
            finishTransactionIfNeeded(.published)
        }
        return didPublish
    }

    package func abort(
        throwing error: any Error
    ) async -> WebInspectorModelContextTransactionCommitResolution {
        let resolution = await combined.abort(throwing: error)
        finishTransactionIfNeeded(resolution)
        return resolution
    }

    private func finishTransactionIfNeeded(
        _ resolution: WebInspectorModelContextTransactionCommitResolution
    ) {
        let isFirstResolution = didResolve.withLock { didResolve in
            guard didResolve == false else {
                return false
            }
            didResolve = true
            return true
        }
        if isFirstResolution {
            switch resolution {
            case .published:
                transactions.publishOutstandingTransaction()
            case .aborted:
                transactions.failOutstandingTransaction()
            }
        }
    }
}

/// Terminal RecordGate work. Transient owner projection reset is applied for
/// every schema before any materialized model is invalidated.
package final class WebInspectorModelSchemaClose: Sendable {
    private enum State: Sendable {
        case pending
        case applied
    }

    private let contextIdentity: _WebInspectorModelSchemaContextIdentity
    private let effects: [WebInspectorModelSchemaOwnerEffectBatch]
    private let mutations: [WebInspectorModelRecordOwnerMutationBatch]
    private let state = Mutex(State.pending)

    fileprivate init(
        contextIdentity: _WebInspectorModelSchemaContextIdentity,
        effects: [WebInspectorModelSchemaOwnerEffectBatch],
        mutations: [WebInspectorModelRecordOwnerMutationBatch]
    ) {
        self.contextIdentity = contextIdentity
        self.effects = effects
        self.mutations = mutations
    }

    package func apply(
        on registry: WebInspectorModelSchemaOwnerRegistry,
        owner: WebInspectorModelContext
    ) {
        registry.requireContextIdentity(contextIdentity)
        registry.requireOwnerIdentity(owner)
        state.withLock { state in
            precondition(
                state == .pending,
                "Model schema close work can be applied only once."
            )
            state = .applied
        }
        registry.apply(effects: effects, owner: owner)
        registry.apply(mutations: mutations, owner: owner)
    }
}

private final class _WebInspectorTypedModelSchemaOwnerBox<
    Model: WebInspectorPersistentModel,
    Record: WebInspectorModelRecord,
    OwnerEffect: Sendable
> {
    private let gate: WebInspectorModelRecordGate<Model, Record>
    private let makeModel:
        @Sendable (
            WebInspectorModelContext,
            Model.ID,
            Record
        ) -> Model
    private let replaceModel:
        @Sendable (
            WebInspectorModelContext,
            Model,
            Record
        ) -> Void
    private let applyPatch:
        @Sendable (
            WebInspectorModelContext,
            Model,
            Record.Patch
        ) -> Void
    private let invalidateModel:
        @Sendable (
            WebInspectorModelContext,
            Model
        ) -> Void
    private let applyOwnerEffect:
        @Sendable (
            WebInspectorModelContext,
            OwnerEffect,
            borrowing WebInspectorModelSchemaOwnerModels<Model>
        ) -> Void
    private let resetOwnerProjection:
        @Sendable (
            WebInspectorModelContext,
            borrowing WebInspectorModelSchemaOwnerModels<Model>
        ) -> Void
    private var models: [Model.ID: Model] = [:]

    init(
        gate: WebInspectorModelRecordGate<Model, Record>,
        makeModel:
            @escaping @Sendable (
                WebInspectorModelContext,
                Model.ID,
                Record
            ) -> Model,
        replaceModel:
            @escaping @Sendable (
                WebInspectorModelContext,
                Model,
                Record
            ) -> Void,
        applyPatch:
            @escaping @Sendable (
                WebInspectorModelContext,
                Model,
                Record.Patch
            ) -> Void,
        invalidateModel:
            @escaping @Sendable (
                WebInspectorModelContext,
                Model
            ) -> Void,
        applyOwnerEffect:
            @escaping @Sendable (
                WebInspectorModelContext,
                OwnerEffect,
                borrowing WebInspectorModelSchemaOwnerModels<Model>
            ) -> Void,
        resetOwnerProjection:
            @escaping @Sendable (
                WebInspectorModelContext,
                borrowing WebInspectorModelSchemaOwnerModels<Model>
            ) -> Void
    ) {
        self.gate = gate
        self.makeModel = makeModel
        self.replaceModel = replaceModel
        self.applyPatch = applyPatch
        self.invalidateModel = invalidateModel
        self.applyOwnerEffect = applyOwnerEffect
        self.resetOwnerProjection = resetOwnerProjection
    }

    func registeredModel(for id: Model.ID) -> Model? {
        models[id]
    }

    func model(
        for id: Model.ID,
        owner: WebInspectorModelContext
    ) -> Model? {
        if let model = models[id] {
            return model
        }
        guard let record = gate.claim(id) else {
            return nil
        }
        let model = makeModel(owner, id, record)
        precondition(
            model.id == id,
            "A schema materializer returned a model with the wrong persistent identity."
        )
        precondition(
            models.updateValue(model, forKey: id) == nil,
            "A schema materialized one persistent identity more than once."
        )
        return model
    }

    func apply(
        _ operations: [_WebInspectorModelSchemaEffectOperation<OwnerEffect>],
        owner: WebInspectorModelContext
    ) {
        let ownerModels = WebInspectorModelSchemaOwnerModels<Model>(
            model: { [self] id in models[id] },
            forEach: { [self] body in
                for model in models.values {
                    body(model)
                }
            }
        )
        for operation in operations {
            switch operation {
            case .resetOwnerProjection:
                resetOwnerProjection(owner, ownerModels)
            case let .apply(effect):
                applyOwnerEffect(owner, effect, ownerModels)
            }
        }
    }

    func apply(
        _ mutations: [WebInspectorModelRecordOwnerMutation<Model, Record>],
        owner: WebInspectorModelContext
    ) {
        for mutation in mutations {
            switch mutation {
            case let .replace(id, record):
                guard let model = models[id] else {
                    preconditionFailure(
                        "RecordGate produced a replacement for an unregistered model identity."
                    )
                }
                replaceModel(owner, model, record)
            case let .applyPatches(id, patches):
                guard let model = models[id] else {
                    preconditionFailure(
                        "RecordGate produced patches for an unregistered model identity."
                    )
                }
                for patch in patches.patches {
                    applyPatch(owner, model, patch)
                }
            case let .invalidate(id):
                guard let model = models.removeValue(forKey: id) else {
                    preconditionFailure(
                        "RecordGate produced invalidation for an unregistered model identity."
                    )
                }
                invalidateModel(owner, model)
            }
        }
    }
}

private final class _WebInspectorAnyModelSchemaOwnerBox {
    let schemaIdentity: ObjectIdentifier
    let modelTypeID: ObjectIdentifier
    private let registeredModelBody: (Any) -> AnyObject?
    private let modelBody: (Any, WebInspectorModelContext) -> AnyObject?
    private let applyEffectsBody: (WebInspectorModelSchemaOwnerEffectBatch, WebInspectorModelContext) -> Void
    private let applyMutationsBody: (WebInspectorModelRecordOwnerMutationBatch, WebInspectorModelContext) -> Void

    init<
        Model: WebInspectorPersistentModel,
        Record: WebInspectorModelRecord,
        OwnerEffect: Sendable
    >(
        schemaIdentity: _WebInspectorModelSchemaDefinitionIdentity,
        gate: WebInspectorModelRecordGate<Model, Record>,
        makeModel:
            @escaping @Sendable (
                WebInspectorModelContext,
                Model.ID,
                Record
            ) -> Model,
        replaceModel:
            @escaping @Sendable (
                WebInspectorModelContext,
                Model,
                Record
            ) -> Void,
        applyPatch:
            @escaping @Sendable (
                WebInspectorModelContext,
                Model,
                Record.Patch
            ) -> Void,
        invalidateModel:
            @escaping @Sendable (
                WebInspectorModelContext,
                Model
            ) -> Void,
        applyOwnerEffect:
            @escaping @Sendable (
                WebInspectorModelContext,
                OwnerEffect,
                borrowing WebInspectorModelSchemaOwnerModels<Model>
            ) -> Void,
        resetOwnerProjection:
            @escaping @Sendable (
                WebInspectorModelContext,
                borrowing WebInspectorModelSchemaOwnerModels<Model>
            ) -> Void
    ) {
        let box = _WebInspectorTypedModelSchemaOwnerBox(
            gate: gate,
            makeModel: makeModel,
            replaceModel: replaceModel,
            applyPatch: applyPatch,
            invalidateModel: invalidateModel,
            applyOwnerEffect: applyOwnerEffect,
            resetOwnerProjection: resetOwnerProjection
        )
        self.schemaIdentity = ObjectIdentifier(schemaIdentity)
        modelTypeID = ObjectIdentifier(Model.self)
        registeredModelBody = { rawID in
            guard let id = rawID as? Model.ID else {
                preconditionFailure(
                    "A schema owner registry received the wrong persistent ID type."
                )
            }
            return box.registeredModel(for: id)
        }
        modelBody = { rawID, owner in
            guard let id = rawID as? Model.ID else {
                preconditionFailure(
                    "A schema owner registry received the wrong persistent ID type."
                )
            }
            return box.model(for: id, owner: owner)
        }
        applyEffectsBody = { batch, owner in
            precondition(
                batch.schemaIdentity == ObjectIdentifier(schemaIdentity)
                    && batch.modelTypeID == ObjectIdentifier(Model.self)
                    && batch.effectTypeID == ObjectIdentifier(OwnerEffect.self),
                "A schema owner-effect batch was opened with the wrong schema types."
            )
            guard
                let operations = batch.payload
                    as? [_WebInspectorModelSchemaEffectOperation<OwnerEffect>]
            else {
                preconditionFailure(
                    "A schema owner-effect payload lost its concrete types."
                )
            }
            box.apply(operations, owner: owner)
        }
        applyMutationsBody = { batch, owner in
            batch.consume(
                as: Model.self,
                recordType: Record.self
            ) { mutations in
                box.apply(mutations, owner: owner)
            }
        }
    }

    func registeredModel<Model: WebInspectorPersistentModel>(
        for id: Model.ID
    ) -> Model? {
        guard let model = registeredModelBody(id) else {
            return nil
        }
        guard let typedModel = model as? Model else {
            preconditionFailure(
                "A schema owner registry returned the wrong persistent model type."
            )
        }
        return typedModel
    }

    func model<Model: WebInspectorPersistentModel>(
        for id: Model.ID,
        owner: WebInspectorModelContext
    ) -> Model? {
        guard let model = modelBody(id, owner) else {
            return nil
        }
        guard let typedModel = model as? Model else {
            preconditionFailure(
                "A schema owner registry materialized the wrong persistent model type."
            )
        }
        return typedModel
    }

    func apply(
        effects: WebInspectorModelSchemaOwnerEffectBatch,
        owner: WebInspectorModelContext
    ) {
        applyEffectsBody(effects, owner)
    }

    func apply(
        mutations: WebInspectorModelRecordOwnerMutationBatch,
        owner: WebInspectorModelContext
    ) {
        applyMutationsBody(mutations, owner)
    }
}

/// Caller-confined context-local identity graph. This owner stores only the
/// materialized model dictionaries contained by its typed boxes.
package final class WebInspectorModelSchemaOwnerRegistry {
    private let contextIdentity: _WebInspectorModelSchemaContextIdentity
    private weak var contextOwner: WebInspectorModelContext?
    private var hasBoundContextOwner = false
    private let boxes: [_WebInspectorAnyModelSchemaOwnerBox]
    private let boxByModelTypeID: [ObjectIdentifier: _WebInspectorAnyModelSchemaOwnerBox]

    fileprivate init(
        contextIdentity: _WebInspectorModelSchemaContextIdentity,
        boxes: [_WebInspectorAnyModelSchemaOwnerBox]
    ) {
        self.contextIdentity = contextIdentity
        self.boxes = boxes
        boxByModelTypeID = Dictionary(
            uniqueKeysWithValues: boxes.map { ($0.modelTypeID, $0) }
        )
    }

    /// Establishes the caller-confined owner after the Context has initialized
    /// all of its stored state.
    package func bind(to owner: WebInspectorModelContext) {
        precondition(
            hasBoundContextOwner == false,
            "A schema owner registry can bind to one WebInspectorModelContext only once."
        )
        hasBoundContextOwner = true
        contextOwner = owner
    }

    /// Returns only an already materialized model. This operation never claims
    /// a RecordGate identity or constructs a model.
    package func registeredModel<Model: WebInspectorPersistentModel>(
        for id: Model.ID,
        owner: WebInspectorModelContext
    ) -> Model? {
        requireOwnerIdentity(owner)
        guard let box = boxByModelTypeID[ObjectIdentifier(Model.self)] else {
            return nil
        }
        let model: Model? = box.registeredModel(for: id)
        return model
    }

    /// Resolves one current record and materializes its context-local model at
    /// most once in this synchronous owner turn.
    package func model<Model: WebInspectorPersistentModel>(
        for id: Model.ID,
        owner: WebInspectorModelContext
    ) -> Model? {
        requireOwnerIdentity(owner)
        guard let box = boxByModelTypeID[ObjectIdentifier(Model.self)] else {
            return nil
        }
        let model: Model? = box.model(for: id, owner: owner)
        return model
    }

    fileprivate func requireContextIdentity(
        _ expected: _WebInspectorModelSchemaContextIdentity
    ) {
        precondition(
            contextIdentity === expected,
            "Schema work cannot be applied to a different model context."
        )
    }

    fileprivate func requireOwnerIdentity(
        _ owner: WebInspectorModelContext
    ) {
        precondition(
            contextOwner === owner,
            "A schema owner registry cannot be used with a different WebInspectorModelContext."
        )
    }

    fileprivate func apply(
        effects: [WebInspectorModelSchemaOwnerEffectBatch],
        owner: WebInspectorModelContext
    ) {
        precondition(
            effects.count == boxes.count,
            "Every schema transaction must carry one ordered owner-effect batch per schema."
        )
        for (box, effects) in zip(boxes, effects) {
            precondition(
                box.modelTypeID == effects.modelTypeID
                    && box.schemaIdentity == effects.schemaIdentity,
                "Schema owner-effect order or type did not match its owner registry."
            )
            box.apply(effects: effects, owner: owner)
        }
    }

    fileprivate func apply(
        mutations: [WebInspectorModelRecordOwnerMutationBatch],
        owner: WebInspectorModelContext
    ) {
        precondition(
            mutations.count == boxes.count,
            "Every schema transaction must carry one ordered model-mutation batch per schema."
        )
        for (box, mutations) in zip(boxes, mutations) {
            precondition(
                box.modelTypeID == mutations.modelTypeID,
                "Schema model-mutation order or type did not match its owner registry."
            )
            box.apply(mutations: mutations, owner: owner)
        }
    }
}

@available(
    *,
    unavailable,
    message: "model schema owner registries are confined to their context owner"
)
extension WebInspectorModelSchemaOwnerRegistry: Sendable {}
