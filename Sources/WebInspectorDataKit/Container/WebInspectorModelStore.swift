import Foundation
import Synchronization

package struct _WebInspectorStoredModelRecord<
    Model: WebInspectorPersistentModel,
    Record: Sendable
>: Sendable {
    package let record: Record
    package let queryValue: Model.QueryValue
    package let canonicalRank: WebInspectorModelCanonicalRank
}

package protocol _WebInspectorAnyModelStoreTable: Sendable {
    var modelTypeID: ObjectIdentifier { get }
    var schemaIdentity: ObjectIdentifier { get }
    var featureID: WebInspectorFeatureID { get }
    func makeSnapshot() -> any _WebInspectorAnyModelSnapshot
}

package final class _WebInspectorModelStoreTable<
    Model: WebInspectorPersistentModel,
    Record: Sendable
>: _WebInspectorAnyModelStoreTable, @unchecked Sendable {
    package let definition: _WebInspectorModelSchemaDefinition<Model, Record>
    package let records: [Model.ID: _WebInspectorStoredModelRecord<Model, Record>]
    package let canonicalRankOwners: [WebInspectorModelCanonicalRank: Model.ID]

    package init(
        definition: _WebInspectorModelSchemaDefinition<Model, Record>,
        records: [Model.ID: _WebInspectorStoredModelRecord<Model, Record>],
        canonicalRankOwners: [WebInspectorModelCanonicalRank: Model.ID]
    ) {
        self.definition = definition
        self.records = records
        self.canonicalRankOwners = canonicalRankOwners
    }

    package var modelTypeID: ObjectIdentifier {
        ObjectIdentifier(Model.self)
    }

    package var schemaIdentity: ObjectIdentifier {
        ObjectIdentifier(definition.identity)
    }

    package var featureID: WebInspectorFeatureID {
        definition.featureID
    }

    package func makeSnapshot() -> any _WebInspectorAnyModelSnapshot {
        _WebInspectorModelSnapshot(
            definition: definition,
            records: records
        )
    }
}

package protocol _WebInspectorAnyModelMutationBatch: Sendable {
    var modelTypeID: ObjectIdentifier { get }
    var schemaIdentity: ObjectIdentifier { get }
    var featureID: WebInspectorFeatureID { get }
    func applying(
        to table: (any _WebInspectorAnyModelStoreTable)?
    ) throws -> any _WebInspectorAnyModelStoreTable
    func prepare(
        to lifecycle: WebInspectorModelContextLifecycle
    ) async -> any _WebInspectorPreparedContextApply
}

package final class _WebInspectorModelMutationBatch<
    Model: WebInspectorPersistentModel,
    Record: Sendable
>: _WebInspectorAnyModelMutationBatch, @unchecked Sendable {
    package let definition: _WebInspectorModelSchemaDefinition<Model, Record>
    package let operations: [_WebInspectorTypedModelMutationOperation<Model, Record>]

    package init(
        definition: _WebInspectorModelSchemaDefinition<Model, Record>,
        operations: [_WebInspectorTypedModelMutationOperation<Model, Record>]
    ) {
        self.definition = definition
        self.operations = operations
    }

    package var modelTypeID: ObjectIdentifier {
        ObjectIdentifier(Model.self)
    }

    package var schemaIdentity: ObjectIdentifier {
        ObjectIdentifier(definition.identity)
    }

    package var featureID: WebInspectorFeatureID {
        definition.featureID
    }

    package func applying(
        to table: (any _WebInspectorAnyModelStoreTable)?
    ) throws -> any _WebInspectorAnyModelStoreTable {
        let typedTable: _WebInspectorModelStoreTable<Model, Record>
        if let table {
            guard
                let existing = table
                    as? _WebInspectorModelStoreTable<
                        Model,
                        Record
                    >,
                existing.definition === definition
            else {
                throw WebInspectorModelStoreError.conflictingSchema(
                    String(reflecting: Model.self)
                )
            }
            typedTable = existing
        } else {
            typedTable = _WebInspectorModelStoreTable(
                definition: definition,
                records: [:],
                canonicalRankOwners: [:]
            )
        }

        var records = typedTable.records
        var canonicalRankOwners = typedTable.canonicalRankOwners
        let affectedIDs = Set(operations.map(\.id))
        for id in affectedIDs {
            if let previous = typedTable.records[id] {
                canonicalRankOwners[previous.canonicalRank] = nil
            }
        }
        for operation in operations {
            switch operation {
            case let .upsert(record, queryValue, canonicalRank):
                records[queryValue.id] = _WebInspectorStoredModelRecord(
                    record: record,
                    queryValue: queryValue,
                    canonicalRank: canonicalRank
                )
            case let .updateContent(id, record):
                guard let existing = records[id] else {
                    throw WebInspectorModelStoreError.missingRecord(
                        String(reflecting: id)
                    )
                }
                records[id] = _WebInspectorStoredModelRecord(
                    record: record,
                    queryValue: existing.queryValue,
                    canonicalRank: existing.canonicalRank
                )
            case let .delete(id):
                records[id] = nil
            }
        }
        for id in affectedIDs {
            guard let record = records[id] else { continue }
            if canonicalRankOwners[record.canonicalRank] != nil {
                throw WebInspectorModelStoreError.duplicateCanonicalRank(
                    String(reflecting: Model.self)
                )
            }
            canonicalRankOwners[record.canonicalRank] = id
        }

        return _WebInspectorModelStoreTable(
            definition: definition,
            records: records,
            canonicalRankOwners: canonicalRankOwners
        )
    }

    package func prepare(
        to lifecycle: WebInspectorModelContextLifecycle
    ) async -> any _WebInspectorPreparedContextApply {
        await lifecycle.prepareMutationBatch(
            definition: definition,
            operations: operations
        )
    }
}

package protocol _WebInspectorAnyModelSnapshot: Sendable {
    var modelTypeID: ObjectIdentifier { get }
    func prepare(
        to lifecycle: WebInspectorModelContextLifecycle,
        featureStates: [WebInspectorFeatureID: WebInspectorFeatureState]
    ) async -> any _WebInspectorPreparedContextApply
}

package final class _WebInspectorModelSnapshot<
    Model: WebInspectorPersistentModel,
    Record: Sendable
>: _WebInspectorAnyModelSnapshot, @unchecked Sendable {
    package let definition: _WebInspectorModelSchemaDefinition<Model, Record>
    package let records: [Model.ID: _WebInspectorStoredModelRecord<Model, Record>]

    package init(
        definition: _WebInspectorModelSchemaDefinition<Model, Record>,
        records: [Model.ID: _WebInspectorStoredModelRecord<Model, Record>]
    ) {
        self.definition = definition
        self.records = records
    }

    package var modelTypeID: ObjectIdentifier {
        ObjectIdentifier(Model.self)
    }

    package func prepare(
        to lifecycle: WebInspectorModelContextLifecycle,
        featureStates: [WebInspectorFeatureID: WebInspectorFeatureState]
    ) async -> any _WebInspectorPreparedContextApply {
        await lifecycle.prepareSnapshot(
            definition: definition,
            records: records,
            featureState: featureStates[definition.featureID] ?? .disabled
        )
    }
}

package struct WebInspectorModelStoreCommit: Sendable {
    package let revision: WebInspectorStoreRevision
    package let batches: [any _WebInspectorAnyModelMutationBatch]
    package let featureStates: [WebInspectorFeatureID: WebInspectorFeatureState]
}

package struct WebInspectorModelStoreRebase: Sendable {
    package let revision: WebInspectorStoreRevision
    package let snapshots: [any _WebInspectorAnyModelSnapshot]
    package let featureStates: [WebInspectorFeatureID: WebInspectorFeatureState]
}

/// A typed metadata channel colocated with canonical model commits.
/// Semantic features define the value; the generic store only owns atomic
/// revision ordering and type-safe lookup.
package struct WebInspectorModelStoreMetadataKey<Value: Sendable>:
    Hashable,
    Sendable
{
    fileprivate let rawValue: UUID

    package init() {
        rawValue = UUID()
    }
}

private final class _WebInspectorWeakModelContextIngress: @unchecked Sendable {
    weak var value: WebInspectorModelContextIngress?

    init(_ value: WebInspectorModelContextIngress) {
        self.value = value
    }
}

/// Synchronous context-registration gate paired with the actor-owned store.
/// It mirrors only immutable rebases/commits, allowing context issuance to be
/// fully linearized before a synchronous ModelActor initializer returns.
package final class WebInspectorModelStoreIngressRegistry: @unchecked Sendable {
    private struct State {
        var latestRebase: WebInspectorModelStoreRebase
        var ingresses: [UUID: _WebInspectorWeakModelContextIngress] = [:]
        var isClosed = false
    }

    private let state: Mutex<State>

    package init(initialRebase: WebInspectorModelStoreRebase) {
        state = Mutex(State(latestRebase: initialRebase))
    }

    package func register(_ ingress: WebInspectorModelContextIngress) {
        state.withLock { state in
            guard !state.isClosed, ingress.acceptsSource else { return }
            // Publish the initial rebase before making the ingress visible to
            // commit publication. This lock is the source-order linearization
            // point for context issuance.
            ingress.enqueueInitial(state.latestRebase)
            state.ingresses[ingress.registrationID] =
                _WebInspectorWeakModelContextIngress(ingress)
        }
    }

    package func unregister(_ registrationID: UUID) {
        state.withLock { $0.ingresses[registrationID] = nil }
    }

    package func publish(
        _ commit: WebInspectorModelStoreCommit,
        latestRebase: WebInspectorModelStoreRebase
    ) {
        let ingresses = state.withLock { state -> [WebInspectorModelContextIngress] in
            guard !state.isClosed else { return [] }
            state.latestRebase = latestRebase
            var deadIDs: [UUID] = []
            let values: [WebInspectorModelContextIngress] =
                state.ingresses.compactMap { entry in
                    let (registrationID, weakIngress) = entry
                    guard let ingress = weakIngress.value else {
                        deadIDs.append(registrationID)
                        return nil
                    }
                    return ingress
                }
            for id in deadIDs { state.ingresses[id] = nil }
            return values
        }
        for ingress in ingresses {
            ingress.enqueueSource(commit: commit, latestRebase: latestRebase)
        }
    }

    package func close() {
        let ingresses = state.withLock { state -> [WebInspectorModelContextIngress] in
            guard !state.isClosed else { return [] }
            state.isClosed = true
            defer { state.ingresses.removeAll(keepingCapacity: false) }
            return state.ingresses.values.compactMap(\.value)
        }
        for ingress in ingresses {
            ingress.beginClose(reason: .containerClosed)
        }
    }
}

/// A duplicate-free, immutable schema set assembled before contexts are
/// issued. Validation happens once at composition rather than during a store
/// commit or model lookup.
package struct WebInspectorModelSchemaRegistry: Sendable {
    package let schemas: [WebInspectorAnyModelSchema]

    package init(_ schemas: [WebInspectorAnyModelSchema]) throws {
        var seen: Set<ObjectIdentifier> = []
        for schema in schemas {
            guard seen.insert(schema.box.modelTypeID).inserted else {
                throw WebInspectorModelStoreError.duplicateModelSchema(
                    String(describing: schema.box.modelTypeID)
                )
            }
        }
        self.schemas = schemas
    }

    package static let empty = WebInspectorModelSchemaRegistry(schemas: [])

    /// Builds the framework-owned catalog whose model types are checked by
    /// the built-in schema inventory test. Dynamic composition uses the
    /// throwing initializer above.
    package static func builtIn(
        _ staticallyReviewedSchemas: [WebInspectorAnyModelSchema]
    ) -> Self {
        Self(schemas: staticallyReviewedSchemas)
    }

    private init(schemas: [WebInspectorAnyModelSchema]) {
        self.schemas = schemas
    }
}

/// The sole canonical owner of immutable model records and source revision.
/// It never decodes protocol events or owns observable model references.
package actor WebInspectorModelStore {
    private struct PreparedCommit {
        let nextTables: [ObjectIdentifier: any _WebInspectorAnyModelStoreTable]
        let nextFeatureStates: [WebInspectorFeatureID: WebInspectorFeatureState]
        let commit: WebInspectorModelStoreCommit
    }

    private var tables: [ObjectIdentifier: any _WebInspectorAnyModelStoreTable]
    private var featureStates: [WebInspectorFeatureID: WebInspectorFeatureState]
    private var revision = WebInspectorStoreRevision(rawValue: 0)
    nonisolated package let ingressRegistry: WebInspectorModelStoreIngressRegistry
    private var metadata: [UUID: any Sendable] = [:]
    private var isClosed = false

    package init(
        schemaRegistry: WebInspectorModelSchemaRegistry,
        enabledFeatures: Set<WebInspectorFeatureID>
    ) {
        var tables: [ObjectIdentifier: any _WebInspectorAnyModelStoreTable] = [:]
        for schema in schemaRegistry.schemas {
            let modelTypeID = schema.box.modelTypeID
            tables[modelTypeID] = schema.box.makeEmptyStoreTable()
        }
        self.tables = tables
        featureStates = Dictionary(
            uniqueKeysWithValues: enabledFeatures.map { ($0, .disabled) }
        )
        ingressRegistry = WebInspectorModelStoreIngressRegistry(
            initialRebase: WebInspectorModelStoreRebase(
                revision: WebInspectorStoreRevision(rawValue: 0),
                snapshots: tables.values.map { $0.makeSnapshot() },
                featureStates: featureStates
            )
        )
    }

    nonisolated package func registerSynchronously(
        _ ingress: WebInspectorModelContextIngress
    ) {
        ingressRegistry.register(ingress)
    }

    nonisolated package func unregisterSynchronously(
        _ registrationID: UUID
    ) {
        ingressRegistry.unregister(registrationID)
    }

    @discardableResult
    package func commit(
        _ transaction: WebInspectorModelTransaction
    ) throws -> WebInspectorStoreRevision {
        guard !isClosed else {
            throw WebInspectorModelStoreError.closed
        }
        guard !transaction.isEmpty else { return revision }
        let prepared = try prepare(transaction)
        apply(prepared)
        return prepared.commit.revision
    }

    package func commit<Value: Sendable, Output: Sendable>(
        _ transaction: WebInspectorModelTransaction,
        updating key: WebInspectorModelStoreMetadataKey<Value>,
        initialValue: Value,
        _ update:
            @Sendable (inout Value, WebInspectorStoreRevision) throws -> Output
    ) throws -> (revision: WebInspectorStoreRevision, output: Output) {
        guard !isClosed else {
            throw WebInspectorModelStoreError.closed
        }
        let prepared = try prepare(transaction, permitsEmpty: true)
        var value = metadata[key.rawValue] as? Value ?? initialValue
        let output = try update(&value, prepared.commit.revision)
        metadata[key.rawValue] = value
        apply(prepared)
        return (prepared.commit.revision, output)
    }

    /// Builds a domain transaction after the store-owned metadata value has
    /// issued the identity needed by that transaction, then activates both in
    /// one revision. The builder works on a copy: if reduction or validation
    /// throws, neither metadata nor model records change.
    package func commit<Value: Sendable, Output: Sendable>(
        updating key: WebInspectorModelStoreMetadataKey<Value>,
        initialValue: Value,
        _ build:
            @Sendable (
                inout Value,
                WebInspectorStoreRevision
            ) throws -> (WebInspectorModelTransaction, Output)
    ) throws -> (revision: WebInspectorStoreRevision, output: Output) {
        guard !isClosed else {
            throw WebInspectorModelStoreError.closed
        }
        var value = metadata[key.rawValue] as? Value ?? initialValue
        let proposedRevision = WebInspectorStoreRevision(
            rawValue: revision.rawValue + 1
        )
        let (transaction, output) = try build(&value, proposedRevision)
        let prepared = try prepare(transaction, permitsEmpty: true)
        metadata[key.rawValue] = value
        apply(prepared)
        return (prepared.commit.revision, output)
    }

    package func metadataValue<Value: Sendable>(
        for key: WebInspectorModelStoreMetadataKey<Value>,
        default defaultValue: Value
    ) -> Value {
        metadata[key.rawValue] as? Value ?? defaultValue
    }

    package func currentFeatureState(
        for featureID: WebInspectorFeatureID
    ) -> WebInspectorFeatureState {
        featureStates[featureID] ?? .disabled
    }

    package func snapshot() -> WebInspectorModelStoreRebase {
        makeRebase()
    }

    package func close() {
        guard !isClosed else { return }
        isClosed = true
        ingressRegistry.close()
    }

    private func publish(_ commit: WebInspectorModelStoreCommit) {
        let rebase = makeRebase()
        ingressRegistry.publish(commit, latestRebase: rebase)
    }

    private func prepare(
        _ transaction: WebInspectorModelTransaction,
        permitsEmpty: Bool = false
    ) throws -> PreparedCommit {
        guard permitsEmpty || !transaction.isEmpty else {
            throw WebInspectorModelStoreError.invalidTransaction
        }
        let batches = try transaction.makeBatches()
        var nextTables = tables
        for batch in batches {
            guard let table = nextTables[batch.modelTypeID] else {
                throw WebInspectorModelStoreError.unknownModelSchema(
                    String(describing: batch.modelTypeID)
                )
            }
            guard table.schemaIdentity == batch.schemaIdentity else {
                throw WebInspectorModelStoreError.conflictingSchema(
                    String(describing: batch.modelTypeID)
                )
            }
            nextTables[batch.modelTypeID] = try batch.applying(to: table)
        }

        let nextRevision = WebInspectorStoreRevision(
            rawValue: revision.rawValue + 1
        )
        var nextFeatureStates = featureStates
        for (featureID, state) in transaction.featureStates {
            nextFeatureStates[featureID] = normalized(
                state,
                revision: nextRevision
            )
        }
        for featureID in Set(batches.map(\.featureID)) {
            guard
                case let .ready(generation, _) = nextFeatureStates[featureID]
            else {
                continue
            }
            nextFeatureStates[featureID] = .ready(
                generation: generation,
                revision: nextRevision
            )
        }

        return PreparedCommit(
            nextTables: nextTables,
            nextFeatureStates: nextFeatureStates,
            commit: WebInspectorModelStoreCommit(
                revision: nextRevision,
                batches: batches,
                featureStates: transaction.featureStates.mapValues {
                    normalized($0, revision: nextRevision)
                }
            )
        )
    }

    private func apply(_ prepared: PreparedCommit) {
        tables = prepared.nextTables
        featureStates = prepared.nextFeatureStates
        revision = prepared.commit.revision
        publish(prepared.commit)
    }

    private func makeRebase() -> WebInspectorModelStoreRebase {
        WebInspectorModelStoreRebase(
            revision: revision,
            snapshots: tables.values
                .sorted {
                    String(describing: $0.modelTypeID)
                        < String(describing: $1.modelTypeID)
                }
                .map { $0.makeSnapshot() },
            featureStates: featureStates
        )
    }

    private func normalized(
        _ state: WebInspectorFeatureState,
        revision: WebInspectorStoreRevision
    ) -> WebInspectorFeatureState {
        guard case let .ready(generation, _) = state else { return state }
        return .ready(generation: generation, revision: revision)
    }
}

/// Narrow Sendable commit capability handed to feature actors.
package struct WebInspectorModelStoreSink: Sendable {
    private let store: WebInspectorModelStore

    package init(store: WebInspectorModelStore) {
        self.store = store
    }

    @discardableResult
    package func commit(
        _ transaction: WebInspectorModelTransaction
    ) async throws -> WebInspectorStoreRevision {
        try await store.commit(transaction)
    }

    package func commit<Value: Sendable, Output: Sendable>(
        _ transaction: WebInspectorModelTransaction,
        updating key: WebInspectorModelStoreMetadataKey<Value>,
        initialValue: Value,
        _ update:
            @escaping @Sendable (
                inout Value,
                WebInspectorStoreRevision
            ) throws -> Output
    ) async throws -> (
        revision: WebInspectorStoreRevision,
        output: Output
    ) {
        try await store.commit(
            transaction,
            updating: key,
            initialValue: initialValue,
            update
        )
    }

    package func commit<Value: Sendable, Output: Sendable>(
        updating key: WebInspectorModelStoreMetadataKey<Value>,
        initialValue: Value,
        _ build:
            @escaping @Sendable (
                inout Value,
                WebInspectorStoreRevision
            ) throws -> (WebInspectorModelTransaction, Output)
    ) async throws -> (
        revision: WebInspectorStoreRevision,
        output: Output
    ) {
        try await store.commit(
            updating: key,
            initialValue: initialValue,
            build
        )
    }

    package func metadataValue<Value: Sendable>(
        for key: WebInspectorModelStoreMetadataKey<Value>,
        default defaultValue: Value
    ) async -> Value {
        await store.metadataValue(for: key, default: defaultValue)
    }
}
