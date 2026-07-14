import Foundation

/// The stable final ordering key assigned by a semantic feature.
package struct WebInspectorModelCanonicalRank:
    RawRepresentable,
    Hashable,
    Comparable,
    Sendable
{
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    package static func < (
        lhs: WebInspectorModelCanonicalRank,
        rhs: WebInspectorModelCanonicalRank
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

package final class _WebInspectorModelSchemaIdentity: Sendable {}

package final class _WebInspectorModelSchemaDefinition<
    Model: WebInspectorPersistentModel,
    Record: Sendable
>: @unchecked Sendable {
    package let identity = _WebInspectorModelSchemaIdentity()
    package let featureID: WebInspectorFeatureID
    package let makeModel: @Sendable (WebInspectorModelContext, Model.ID, Record) -> Model
    package let updateModel: @Sendable (WebInspectorModelContext, Model, Record) -> Void
    package let invalidateModel: @Sendable (WebInspectorModelContext, Model) -> Void

    package init(
        featureID: WebInspectorFeatureID,
        makeModel:
            @escaping @Sendable (
                WebInspectorModelContext,
                Model.ID,
                Record
            ) -> Model,
        updateModel:
            @escaping @Sendable (
                WebInspectorModelContext,
                Model,
                Record
            ) -> Void,
        invalidateModel:
            @escaping @Sendable (
                WebInspectorModelContext,
                Model
            ) -> Void
    ) {
        self.featureID = featureID
        self.makeModel = makeModel
        self.updateModel = updateModel
        self.invalidateModel = invalidateModel
    }
}

/// The typed mapping between one immutable canonical record and one
/// context-confined observable model.
///
/// Features retain this value and use its mutation factories. That keeps the
/// record type, query value, persistent identifier, and materializer in one
/// compiler-checked value instead of parallel type-erased arrays.
package struct WebInspectorModelSchema<
    Model: WebInspectorPersistentModel,
    Record: Sendable
>: Sendable {
    package let definition: _WebInspectorModelSchemaDefinition<Model, Record>

    package init(
        featureID: WebInspectorFeatureID,
        makeModel:
            @escaping @Sendable (
                WebInspectorModelContext,
                Model.ID,
                Record
            ) -> Model,
        updateModel:
            @escaping @Sendable (
                WebInspectorModelContext,
                Model,
                Record
            ) -> Void,
        invalidateModel:
            @escaping @Sendable (
                WebInspectorModelContext,
                Model
            ) -> Void
    ) {
        definition = _WebInspectorModelSchemaDefinition(
            featureID: featureID,
            makeModel: makeModel,
            updateModel: updateModel,
            invalidateModel: invalidateModel
        )
    }

    /// Inserts or replaces one immutable record and its query projection.
    package func upsert(
        record: Record,
        queryValue: Model.QueryValue,
        canonicalRank: WebInspectorModelCanonicalRank
    ) -> WebInspectorModelMutation<Model> {
        WebInspectorModelMutation(
            box: _WebInspectorTypedModelMutation(
                definition: definition,
                operation: .upsert(
                    record: record,
                    queryValue: queryValue,
                    canonicalRank: canonicalRank
                )
            )
        )
    }

    /// Replaces model content without changing query-visible fields or rank.
    package func updateContent(
        id: Model.ID,
        record: Record
    ) -> WebInspectorModelMutation<Model> {
        WebInspectorModelMutation(
            box: _WebInspectorTypedModelMutation(
                definition: definition,
                operation: .updateContent(id: id, record: record)
            )
        )
    }

    /// Deletes one persistent identity.
    package func delete(
        id: Model.ID
    ) -> WebInspectorModelMutation<Model> {
        WebInspectorModelMutation(
            box: _WebInspectorTypedModelMutation(
                definition: definition,
                operation: .delete(id: id)
            )
        )
    }

    package var erased: WebInspectorAnyModelSchema {
        WebInspectorAnyModelSchema(
            box: _WebInspectorTypedModelSchema(definition: definition)
        )
    }
}

package enum _WebInspectorTypedModelMutationOperation<
    Model: WebInspectorPersistentModel,
    Record: Sendable
>: Sendable {
    case upsert(
        record: Record,
        queryValue: Model.QueryValue,
        canonicalRank: WebInspectorModelCanonicalRank
    )
    case updateContent(id: Model.ID, record: Record)
    case delete(id: Model.ID)

    package var id: Model.ID {
        switch self {
        case let .upsert(_, queryValue, _):
            queryValue.id
        case let .updateContent(id, _), let .delete(id):
            id
        }
    }
}

package class _WebInspectorAnyModelSchema: @unchecked Sendable {
    package var modelTypeID: ObjectIdentifier {
        fatalError("abstract schema")
    }

    package var schemaIdentity: ObjectIdentifier {
        fatalError("abstract schema")
    }

    package var featureID: WebInspectorFeatureID {
        fatalError("abstract schema")
    }

    package func makeEmptyStoreTable() -> _WebInspectorAnyModelStoreTable {
        fatalError("abstract schema")
    }
}

package final class _WebInspectorTypedModelSchema<
    Model: WebInspectorPersistentModel,
    Record: Sendable
>: _WebInspectorAnyModelSchema, @unchecked Sendable {
    package let definition: _WebInspectorModelSchemaDefinition<Model, Record>

    package init(
        definition: _WebInspectorModelSchemaDefinition<Model, Record>
    ) {
        self.definition = definition
    }

    package override var modelTypeID: ObjectIdentifier {
        ObjectIdentifier(Model.self)
    }

    package override var schemaIdentity: ObjectIdentifier {
        ObjectIdentifier(definition.identity)
    }

    package override var featureID: WebInspectorFeatureID {
        definition.featureID
    }

    package override func makeEmptyStoreTable()
        -> _WebInspectorAnyModelStoreTable
    {
        _WebInspectorModelStoreTable(
            definition: definition,
            records: [:]
        )
    }
}

/// A model schema erased only at the heterogeneous container boundary.
package struct WebInspectorAnyModelSchema: Sendable {
    package let box: _WebInspectorAnyModelSchema

    package init(box: _WebInspectorAnyModelSchema) {
        self.box = box
    }
}

package class _WebInspectorAnyModelMutation: @unchecked Sendable {
    package var modelTypeID: ObjectIdentifier {
        fatalError("abstract mutation")
    }

    package var schemaIdentity: ObjectIdentifier {
        fatalError("abstract mutation")
    }

    package var featureID: WebInspectorFeatureID {
        fatalError("abstract mutation")
    }

    package func makeBatch(
        from mutations: [_WebInspectorAnyModelMutation]
    ) throws -> _WebInspectorAnyModelMutationBatch {
        fatalError("abstract mutation")
    }
}

package final class _WebInspectorTypedModelMutation<
    Model: WebInspectorPersistentModel,
    Record: Sendable
>: _WebInspectorAnyModelMutation, @unchecked Sendable {
    package let definition: _WebInspectorModelSchemaDefinition<Model, Record>
    package let operation: _WebInspectorTypedModelMutationOperation<Model, Record>

    package init(
        definition: _WebInspectorModelSchemaDefinition<Model, Record>,
        operation: _WebInspectorTypedModelMutationOperation<Model, Record>
    ) {
        self.definition = definition
        self.operation = operation
    }

    package override var modelTypeID: ObjectIdentifier {
        ObjectIdentifier(Model.self)
    }

    package override var schemaIdentity: ObjectIdentifier {
        ObjectIdentifier(definition.identity)
    }

    package override var featureID: WebInspectorFeatureID {
        definition.featureID
    }

    package override func makeBatch(
        from mutations: [_WebInspectorAnyModelMutation]
    ) throws -> _WebInspectorAnyModelMutationBatch {
        var operations: [_WebInspectorTypedModelMutationOperation<Model, Record>] = []
        operations.reserveCapacity(mutations.count)
        for mutation in mutations {
            guard
                let mutation = mutation
                    as? _WebInspectorTypedModelMutation<
                        Model,
                        Record
                    >,
                mutation.definition === definition
            else {
                throw WebInspectorModelStoreError.conflictingSchema(
                    String(reflecting: Model.self)
                )
            }
            operations.append(mutation.operation)
        }
        return _WebInspectorModelMutationBatch(
            definition: definition,
            operations: operations
        )
    }
}

/// One type-safe mutation in a feature transaction.
package struct WebInspectorModelMutation<
    Model: WebInspectorPersistentModel
>: Sendable {
    package let box: _WebInspectorAnyModelMutation

    package init(box: _WebInspectorAnyModelMutation) {
        self.box = box
    }
}

/// One atomic feature commit containing a single ordered mutation collection.
package struct WebInspectorModelTransaction: Sendable {
    package private(set) var mutations: [_WebInspectorAnyModelMutation]
    package private(set) var featureStates: [WebInspectorFeatureID: WebInspectorFeatureState]

    package init() {
        mutations = []
        featureStates = [:]
    }

    package mutating func append<Model>(
        _ mutation: WebInspectorModelMutation<Model>
    ) where Model: WebInspectorPersistentModel {
        mutations.append(mutation.box)
    }

    package mutating func append<Model>(
        contentsOf newMutations: some Sequence<WebInspectorModelMutation<Model>>
    ) where Model: WebInspectorPersistentModel {
        mutations.append(contentsOf: newMutations.map(\.box))
    }

    package mutating func setFeatureState(
        _ state: WebInspectorFeatureState,
        for featureID: WebInspectorFeatureID
    ) {
        featureStates[featureID] = state
    }

    package var isEmpty: Bool {
        mutations.isEmpty && featureStates.isEmpty
    }

    package func makeBatches() throws
        -> [_WebInspectorAnyModelMutationBatch]
    {
        var order: [ObjectIdentifier] = []
        var grouped: [ObjectIdentifier: [_WebInspectorAnyModelMutation]] = [:]
        for mutation in mutations {
            if grouped[mutation.modelTypeID] == nil {
                order.append(mutation.modelTypeID)
            }
            grouped[mutation.modelTypeID, default: []].append(mutation)
        }
        return try order.map { modelTypeID in
            let mutations = grouped[modelTypeID] ?? []
            guard let first = mutations.first else {
                throw WebInspectorModelStoreError.invalidTransaction
            }
            return try first.makeBatch(from: mutations)
        }
    }
}

/// Store-side validation failures are programmer-visible but recoverable at
/// the feature boundary; they never terminate another feature or context.
package enum WebInspectorModelStoreError: Error, Equatable, Sendable {
    case duplicateModelSchema(String)
    case conflictingSchema(String)
    case unknownModelSchema(String)
    case missingRecord(String)
    case duplicateCanonicalRank(String)
    case invalidTransaction
    case closed
}
