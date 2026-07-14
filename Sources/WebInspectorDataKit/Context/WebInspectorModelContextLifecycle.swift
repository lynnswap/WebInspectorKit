import Dispatch
import Foundation
import Synchronization

package class _WebInspectorAnyContextModelTable {
    package var modelTypeID: ObjectIdentifier {
        fatalError("abstract context model table")
    }

    package func invalidateAll(in context: WebInspectorModelContext) {
        fatalError("abstract context model table")
    }
}

package final class _WebInspectorContextModelTable<
    Model: WebInspectorPersistentModel,
    Record: Sendable
>: _WebInspectorAnyContextModelTable {
    package let definition: _WebInspectorModelSchemaDefinition<Model, Record>
    package var records: [Model.ID: _WebInspectorStoredModelRecord<Model, Record>]
    package var models: [Model.ID: Model] = [:]

    package init(
        definition: _WebInspectorModelSchemaDefinition<Model, Record>,
        records: [Model.ID: _WebInspectorStoredModelRecord<Model, Record>]
    ) {
        self.definition = definition
        self.records = records
    }

    package override var modelTypeID: ObjectIdentifier {
        ObjectIdentifier(Model.self)
    }

    package override func invalidateAll(
        in context: WebInspectorModelContext
    ) {
        for model in models.values {
            definition.invalidateModel(context, model)
        }
        models.removeAll(keepingCapacity: false)
        records.removeAll(keepingCapacity: false)
    }
}

package class _WebInspectorPreparedContextApply: @unchecked Sendable {
    package func apply(to lifecycle: WebInspectorModelContextLifecycle) {
        fatalError("abstract prepared context apply")
    }
}

private final class _WebInspectorPreparedMutationApply<
    Model: WebInspectorPersistentModel,
    Record: Sendable
>: _WebInspectorPreparedContextApply, @unchecked Sendable {
    let definition: _WebInspectorModelSchemaDefinition<Model, Record>
    let operations: [_WebInspectorTypedModelMutationOperation<Model, Record>]
    let deliveries: [_WebInspectorQueryDelivery<Model>]

    init(
        definition: _WebInspectorModelSchemaDefinition<Model, Record>,
        operations: [_WebInspectorTypedModelMutationOperation<Model, Record>],
        deliveries: [_WebInspectorQueryDelivery<Model>]
    ) {
        self.definition = definition
        self.operations = operations
        self.deliveries = deliveries
    }

    override func apply(to lifecycle: WebInspectorModelContextLifecycle) {
        lifecycle.applyMutationBatchSynchronously(
            definition: definition,
            operations: operations
        )
        for delivery in deliveries {
            lifecycle.applyQueryDelivery(delivery)
        }
    }
}

private final class _WebInspectorPreparedSnapshotApply<
    Model: WebInspectorPersistentModel,
    Record: Sendable
>: _WebInspectorPreparedContextApply, @unchecked Sendable {
    let definition: _WebInspectorModelSchemaDefinition<Model, Record>
    let records: [Model.ID: _WebInspectorStoredModelRecord<Model, Record>]
    let deliveries: [_WebInspectorQueryDelivery<Model>]

    init(
        definition: _WebInspectorModelSchemaDefinition<Model, Record>,
        records: [Model.ID: _WebInspectorStoredModelRecord<Model, Record>],
        deliveries: [_WebInspectorQueryDelivery<Model>]
    ) {
        self.definition = definition
        self.records = records
        self.deliveries = deliveries
    }

    override func apply(to lifecycle: WebInspectorModelContextLifecycle) {
        lifecycle.applySnapshotSynchronously(
            definition: definition,
            records: records
        )
        for delivery in deliveries {
            lifecycle.applyQueryDelivery(delivery)
        }
    }
}

package enum WebInspectorModelContextExecutor: @unchecked Sendable {
    case mainActor
    case serialQueue(DispatchSerialQueue)
}

/// Caller-confined context state and the sole consumer of its operation queue.
/// The unchecked Sendable conformance is limited to scheduling this object on
/// the executor fixed at issuance; observable state is touched only by drain.
package final class WebInspectorModelContextLifecycle: @unchecked Sendable {
    package let ingress: WebInspectorModelContextIngress
    package let queryIndex = WebInspectorContextQueryIndex()

    private let executor: WebInspectorModelContextExecutor
    private let store: WebInspectorModelStore
    private let closeState = Mutex<WebInspectorModelContextCloseReason?>(nil)
    private let closeReply = WebInspectorContextReply<Void>()
    private let didClose: @Sendable (UUID) -> Void

    fileprivate weak var context: WebInspectorModelContext?
    private var modelTables: [ObjectIdentifier: _WebInspectorAnyContextModelTable] = [:]
    private var endpoints: [WebInspectorQueryRegistrationID: _WebInspectorAnyFetchedResultsEndpoint] = [:]
    private var featureStates: [WebInspectorFeatureID: WebInspectorFeatureState] = [:]
    private var appliedRevision: WebInspectorStoreRevision?

    package init(
        executor: WebInspectorModelContextExecutor,
        store: WebInspectorModelStore,
        didClose: @escaping @Sendable (UUID) -> Void
    ) {
        self.executor = executor
        self.store = store
        self.didClose = didClose
        ingress = WebInspectorModelContextIngress()
        ingress.bind(to: self)
    }

    package func bind(to context: WebInspectorModelContext) {
        self.context = context
    }

    package var closedFetchError: WebInspectorFetchError {
        closeState.withLock { $0?.fetchError ?? .contextClosed }
    }

    package var isOpen: Bool {
        closeState.withLock { $0 == nil }
    }

    package func activate() {
        ingress.activate()
    }

    package func scheduleDrain() {
        switch executor {
        case .mainActor:
            Task { @MainActor [weak self] in
                await self?.drain()
            }
        case let .serialQueue(queue):
            Task(executorPreference: queue) { [weak self] in
                await self?.drain()
            }
        }
    }

    package nonisolated(nonsending) func drain() async {
        while let operation = ingress.dequeue() {
            await operation.process(on: self)
        }
    }

    package func process(
        commit: WebInspectorModelStoreCommit
    ) async {
        if let appliedRevision {
            guard commit.revision > appliedRevision else { return }
            guard commit.revision.rawValue == appliedRevision.rawValue + 1 else {
                await process(rebase: await store.snapshot(), isInitial: false)
                return
            }
        }

        var prepared: [_WebInspectorPreparedContextApply] = []
        prepared.reserveCapacity(commit.batches.count)
        for batch in commit.batches {
            prepared.append(await batch.prepare(to: self))
        }

        var featureDeliveries: [_WebInspectorAnyQueryDelivery] = []
        for (featureID, state) in commit.featureStates {
            featureDeliveries.append(
                contentsOf: await queryIndex.updateFeatureState(
                    state,
                    for: featureID,
                    forceReset: false
                )
            )
        }

        for apply in prepared {
            apply.apply(to: self)
        }
        for delivery in featureDeliveries {
            delivery.apply(to: self)
        }
        featureStates.merge(commit.featureStates) { _, new in new }
        appliedRevision = commit.revision
    }

    package func process(
        rebase: WebInspectorModelStoreRebase,
        isInitial: Bool
    ) async {
        if let appliedRevision, rebase.revision < appliedRevision { return }

        var prepared: [_WebInspectorPreparedContextApply] = []
        prepared.reserveCapacity(rebase.snapshots.count)
        for snapshot in rebase.snapshots {
            prepared.append(
                await snapshot.prepare(
                    to: self,
                    featureStates: rebase.featureStates,
                    forceReset: !isInitial
                )
            )
        }

        for apply in prepared {
            apply.apply(to: self)
        }
        featureStates = rebase.featureStates
        appliedRevision = rebase.revision
    }

    package func prepareMutationBatch<
        Model: WebInspectorPersistentModel,
        Record: Sendable
    >(
        definition: _WebInspectorModelSchemaDefinition<Model, Record>,
        operations: [_WebInspectorTypedModelMutationOperation<Model, Record>]
    ) async -> _WebInspectorPreparedContextApply {
        let queryMutations = operations.map { operation in
            switch operation {
            case let .upsert(_, queryValue, canonicalRank):
                _WebInspectorQueryMutation<Model>.upsert(
                    _WebInspectorQueryRecord(
                        queryValue: queryValue,
                        canonicalRank: canonicalRank
                    )
                )
            case let .updateContent(id, _):
                _WebInspectorQueryMutation<Model>.updateContent(id)
            case let .delete(id):
                _WebInspectorQueryMutation<Model>.delete(id)
            }
        }
        let deliveries = await queryIndex.apply(queryMutations)
        return _WebInspectorPreparedMutationApply(
            definition: definition,
            operations: operations,
            deliveries: deliveries
        )
    }

    package func prepareSnapshot<
        Model: WebInspectorPersistentModel,
        Record: Sendable
    >(
        definition: _WebInspectorModelSchemaDefinition<Model, Record>,
        records: [Model.ID: _WebInspectorStoredModelRecord<Model, Record>],
        featureState: WebInspectorFeatureState,
        forceReset: Bool
    ) async -> _WebInspectorPreparedContextApply {
        let queryRecords = records.values.map {
            _WebInspectorQueryRecord<Model>(
                queryValue: $0.queryValue,
                canonicalRank: $0.canonicalRank
            )
        }
        let deliveries = await queryIndex.replaceSource(
            for: Model.self,
            featureID: definition.featureID,
            featureState: featureState,
            records: queryRecords,
            forceReset: forceReset
        )
        return _WebInspectorPreparedSnapshotApply(
            definition: definition,
            records: records,
            deliveries: deliveries
        )
    }

    package func applyMutationBatchSynchronously<
        Model: WebInspectorPersistentModel,
        Record: Sendable
    >(
        definition: _WebInspectorModelSchemaDefinition<Model, Record>,
        operations: [_WebInspectorTypedModelMutationOperation<Model, Record>]
    ) {
        guard let context else { return }
        let table = typedTable(definition: definition)
        for operation in operations {
            switch operation {
            case let .upsert(record, queryValue, canonicalRank):
                let id = queryValue.id
                table.records[id] = _WebInspectorStoredModelRecord(
                    record: record,
                    queryValue: queryValue,
                    canonicalRank: canonicalRank
                )
                if let model = table.models[id] {
                    definition.updateModel(context, model, record)
                }
            case let .updateContent(id, record):
                guard let existing = table.records[id] else { continue }
                table.records[id] = _WebInspectorStoredModelRecord(
                    record: record,
                    queryValue: existing.queryValue,
                    canonicalRank: existing.canonicalRank
                )
                if let model = table.models[id] {
                    definition.updateModel(context, model, record)
                }
            case let .delete(id):
                table.records[id] = nil
                if let model = table.models.removeValue(forKey: id) {
                    definition.invalidateModel(context, model)
                }
            }
        }
    }

    package func applySnapshotSynchronously<
        Model: WebInspectorPersistentModel,
        Record: Sendable
    >(
        definition: _WebInspectorModelSchemaDefinition<Model, Record>,
        records: [Model.ID: _WebInspectorStoredModelRecord<Model, Record>]
    ) {
        guard let context else { return }
        let table = typedTable(definition: definition)
        for (id, model) in table.models where records[id] == nil {
            definition.invalidateModel(context, model)
            table.models[id] = nil
        }
        table.records = records
        for (id, model) in table.models {
            if let record = records[id]?.record {
                definition.updateModel(context, model, record)
            }
        }
    }

    package func applyQueryDelivery<Model>(
        _ delivery: _WebInspectorQueryDelivery<Model>
    ) where Model: WebInspectorPersistentModel {
        guard
            let endpoint = endpoints[delivery.registrationID]
                as? _WebInspectorFetchedResultsEndpoint<Model>
        else {
            return
        }
        endpoint.apply(delivery, lifecycle: self)
    }

    package func materialize<Model>(
        _ itemIDs: [Model.ID],
        as model: Model.Type
    ) -> [Model] where Model: WebInspectorPersistentModel {
        itemIDs.compactMap { materialize($0) }
    }

    package func queryValues<Model>(
        _ itemIDs: [Model.ID],
        as model: Model.Type
    ) -> [Model.QueryValue]
    where Model: WebInspectorPersistentModel {
        guard
            let table = modelTables[ObjectIdentifier(model)]
                as? any _WebInspectorContextModelLookup<Model>
        else {
            return []
        }
        return itemIDs.compactMap { table.queryValue(for: $0) }
    }

    package func materialize<ID>(
        _ id: ID
    ) -> ID.Model? where ID: WebInspectorPersistentIdentifier {
        guard
            let table = modelTables[ObjectIdentifier(ID.Model.self)]
                as? _WebInspectorContextModelTableForModel<ID.Model>
        else {
            return materializeThroughDynamicTable(id)
        }
        return table.materializeAny(id, lifecycle: self)
    }

    package func registeredModel<ID>(
        _ id: ID
    ) -> ID.Model? where ID: WebInspectorPersistentIdentifier {
        (modelTables[ObjectIdentifier(ID.Model.self)]
            as? any _WebInspectorContextModelLookup<ID.Model>)?
            .registeredModel(for: id)
    }

    package func requestFetchIdentifiers<Model>(
        descriptor: WebInspectorFetchDescriptor<Model>,
        reply: WebInspectorContextReply<[Model.ID]>
    ) -> Bool where Model: WebInspectorPersistentModel {
        ingress.enqueueControl(
            _WebInspectorContextControlOperation { lifecycle in
                guard reply.isPending else { return }
                let result = await lifecycle.queryIndex.fetch(
                    descriptor: descriptor
                )
                switch result {
                case let .success(itemIDs): reply.succeed(itemIDs)
                case let .failure(error): reply.fail(error)
                }
            }
        )
    }

    package func requestPerformFetch<Model>(
        endpoint: _WebInspectorFetchedResultsEndpoint<Model>,
        descriptor: WebInspectorFetchDescriptor<Model>,
        reply: WebInspectorContextReply<Void>
    ) -> Bool where Model: WebInspectorPersistentModel {
        ingress.enqueueControl(
            _WebInspectorContextControlOperation { lifecycle in
                guard reply.isPending else { return }
                endpoint.markOperationBegan(using: descriptor)
                let isNew = lifecycle.endpoints[endpoint.id] == nil
                lifecycle.endpoints[endpoint.id] = endpoint
                let attempt =
                    isNew
                    ? await lifecycle.queryIndex.register(
                        endpoint.id,
                        descriptor: descriptor
                    )
                    : await lifecycle.queryIndex.refetch(
                        endpoint.id,
                        descriptor: descriptor
                    )
                guard reply.isPending else { return }
                lifecycle.applyAttempt(
                    attempt,
                    endpoint: endpoint
                )
            }
        )
    }

    package func requestRefetch<Model>(
        endpoint: _WebInspectorFetchedResultsEndpoint<Model>,
        descriptor: WebInspectorFetchDescriptor<Model>,
        reply: WebInspectorContextReply<Void>
    ) -> Bool where Model: WebInspectorPersistentModel {
        ingress.enqueueControl(
            _WebInspectorContextControlOperation { lifecycle in
                guard reply.isPending else { return }
                endpoint.markOperationBegan(using: descriptor)
                guard lifecycle.endpoints[endpoint.id] != nil else {
                    lifecycle.endpoints[endpoint.id] = endpoint
                    let attempt = await lifecycle.queryIndex.register(
                        endpoint.id,
                        descriptor: descriptor
                    )
                    guard reply.isPending else { return }
                    lifecycle.applyAttempt(attempt, endpoint: endpoint)
                    return
                }
                let attempt = await lifecycle.queryIndex.refetch(
                    endpoint.id,
                    descriptor: descriptor
                )
                guard reply.isPending else { return }
                lifecycle.applyAttempt(attempt, endpoint: endpoint)
            }
        )
    }

    package func requestClose<Model>(
        endpoint: _WebInspectorFetchedResultsEndpoint<Model>,
        reply: WebInspectorContextReply<Void>
    ) -> Bool where Model: WebInspectorPersistentModel {
        ingress.enqueueControl(
            _WebInspectorContextControlOperation { lifecycle in
                lifecycle.endpoints[endpoint.id] = nil
                await lifecycle.queryIndex.remove(
                    endpoint.id,
                    model: Model.self
                )
                endpoint.close(reason: .contextClosed)
                reply.succeed(())
            }
        )
    }

    package func synchronouslyInvalidateRegistration<Model>(
        _ endpoint: _WebInspectorFetchedResultsEndpoint<Model>
    ) where Model: WebInspectorPersistentModel {
        guard endpoints.removeValue(forKey: endpoint.id) != nil else { return }
        endpoint.close(reason: .contextClosed)
        Task { [queryIndex] in
            await queryIndex.remove(endpoint.id, model: Model.self)
        }
    }

    package func beginClose(
        reason: WebInspectorModelContextCloseReason
    ) -> WebInspectorContextReply<Void> {
        let shouldBegin = closeState.withLock { state -> Bool in
            guard state == nil else { return false }
            state = reason
            return true
        }
        if shouldBegin {
            ingress.enqueueClose(reason: reason)
        }
        return closeReply
    }

    package func processClose(
        reason: WebInspectorModelContextCloseReason
    ) async {
        await queryIndex.removeAllRegistrations()
        for endpoint in endpoints.values {
            endpoint.close(reason: reason)
        }
        endpoints.removeAll(keepingCapacity: false)

        if let context {
            for table in modelTables.values {
                table.invalidateAll(in: context)
            }
        }
        modelTables.removeAll(keepingCapacity: false)
        ingress.finishClose()
        didClose(ingress.registrationID)
        closeReply.succeed(())
    }

    package func synchronouslyInvalidateDormantIssuance() {
        guard ingress.synchronouslyInvalidateDormantIssuance() else { return }
        closeState.withLock { state in
            if state == nil { state = .contextClosed }
        }
        didClose(ingress.registrationID)
        closeReply.succeed(())
    }

    private func applyAttempt<Model>(
        _ attempt: _WebInspectorQueryAttempt<Model>,
        endpoint: _WebInspectorFetchedResultsEndpoint<Model>
    ) where Model: WebInspectorPersistentModel {
        switch attempt {
        case .pending:
            break
        case let .success(itemIDs, disposition):
            endpoint.accept(
                itemIDs: itemIDs,
                disposition: disposition,
                lifecycle: self
            )
        case let .failure(error):
            endpoint.acceptFailure(error)
        }
    }

    private func typedTable<
        Model: WebInspectorPersistentModel,
        Record: Sendable
    >(
        definition: _WebInspectorModelSchemaDefinition<Model, Record>
    ) -> _WebInspectorContextModelTable<Model, Record> {
        let modelTypeID = ObjectIdentifier(Model.self)
        if let table = modelTables[modelTypeID]
            as? _WebInspectorContextModelTable<Model, Record>
        {
            return table
        }
        let table = _WebInspectorContextModelTable(
            definition: definition,
            records: [:]
        )
        modelTables[modelTypeID] = table
        return table
    }

    private func materializeThroughDynamicTable<ID>(
        _ id: ID
    ) -> ID.Model? where ID: WebInspectorPersistentIdentifier {
        guard
            let table = modelTables[ObjectIdentifier(ID.Model.self)]
                as? any _WebInspectorContextModelLookup<ID.Model>
        else {
            return nil
        }
        return table.materializeAny(id, lifecycle: self)
    }
}

private protocol _WebInspectorContextModelLookup<Model>: AnyObject
where Model: WebInspectorPersistentModel {
    associatedtype Model
    func registeredModel<ID>(for id: ID) -> Model?
    where ID: WebInspectorPersistentIdentifier, ID.Model == Model
    func materializeAny<ID>(
        _ id: ID,
        lifecycle: WebInspectorModelContextLifecycle
    ) -> Model?
    where ID: WebInspectorPersistentIdentifier, ID.Model == Model
    func queryValue<ID>(for id: ID) -> Model.QueryValue?
    where ID: WebInspectorPersistentIdentifier, ID.Model == Model
}

private typealias _WebInspectorContextModelTableForModel<Model> =
    any _WebInspectorContextModelLookup<Model>

extension _WebInspectorContextModelTable: _WebInspectorContextModelLookup {
    fileprivate func registeredModel<ID>(for id: ID) -> Model?
    where ID: WebInspectorPersistentIdentifier, ID.Model == Model {
        models[id]
    }

    fileprivate func materializeAny<ID>(
        _ id: ID,
        lifecycle: WebInspectorModelContextLifecycle
    ) -> Model?
    where ID: WebInspectorPersistentIdentifier, ID.Model == Model {
        materialize(id, lifecycle: lifecycle)
    }

    fileprivate func queryValue<ID>(for id: ID) -> Model.QueryValue?
    where ID: WebInspectorPersistentIdentifier, ID.Model == Model {
        records[id]?.queryValue
    }

    fileprivate func materialize(
        _ id: Model.ID,
        lifecycle: WebInspectorModelContextLifecycle
    ) -> Model? {
        if let model = models[id] { return model }
        guard
            let context = lifecycle.context,
            let record = records[id]?.record
        else {
            return nil
        }
        let model = definition.makeModel(context, id, record)
        models[id] = model
        return model
    }
}
