private enum ConsoleMessageSchemaPendingChange {
    case insert(
        record: CanonicalConsoleMessageRecord,
        query: CanonicalConsoleMessageQueryProjection
    )
    case update(
        patches: [CanonicalConsoleMessagePatch],
        query: CanonicalConsoleMessageQueryProjection?,
        storage: CanonicalConsoleMessageIDStorage
    )
    case delete
}

private enum RuntimeContextSchemaPendingChange {
    case insert(
        record: CanonicalRuntimeContextRecord,
        query: CanonicalRuntimeContextQueryProjection
    )
    case delete
}

private struct RuntimeContextSchemaOwnerEffect: Sendable {}

private enum ConsoleMessageSchemaOwnerEffect: Sendable {
    case rebuildParameterGraphs(
        id: ConsoleMessage.ID,
        membership: CanonicalConsoleMessageMembership,
        seeds: [CanonicalConsoleParameterResourceSeed]
    )
    case invalidate(CanonicalConsoleRuntimeResourceInvalidation)
}

package extension WebInspectorModelSchema where Model == ConsoleMessage {
    /// Canonical Console-message record, query, and context-resource mapping.
    static var consoleMessage: Self {
        WebInspectorModelSchema(
            snapshot: consoleMessageSnapshot,
            delta: consoleMessageDelta,
            makeModel: { context, id, record in
                ConsoleMessage(
                    id: id,
                    record: record,
                    modelContext: context
                )
            },
            replaceModel: { context, model, record in
                model.replace(with: record, modelContext: context)
            },
            applyPatch: { _, model, patch in
                model.apply(patch)
            },
            invalidateModel: { _, model in
                model.invalidate()
            },
            applyOwnerEffect: { _, effect, models in
                switch effect {
                case let .rebuildParameterGraphs(id, membership, seeds):
                    models.model(for: id)?.replaceParameterGraphs(
                        membership: membership,
                        seeds: seeds
                    )
                case let .invalidate(invalidation):
                    models.forEachRegisteredModel { model in
                        model.invalidateParameterGraphs(
                            matching: invalidation
                        )
                    }
                }
            },
            resetOwnerProjection: { _, models in
                models.forEachRegisteredModel { model in
                    model.invalidateParameterGraphs()
                }
            }
        )
    }
}

package extension WebInspectorModelSchema where Model == RuntimeContext {
    /// Canonical persistent Runtime-context mapping.
    ///
    /// Runtime object groups are independent context resources owned by the
    /// Runtime command gateway, not by this persistent-model schema.
    static var runtimeContext: Self {
        WebInspectorModelSchema(
            snapshot: runtimeContextSnapshot,
            delta: runtimeContextDelta,
            makeModel: { context, id, record in
                RuntimeContext(
                    id: id,
                    record: record,
                    modelContext: context
                )
            },
            replaceModel: { context, model, record in
                model.replace(with: record, modelContext: context)
            },
            applyPatch: { _, _, patch in
                _ = patch
            },
            invalidateModel: { _, model in
                model.invalidate()
            },
            applyOwnerEffect: { _, effect, _ in
                _ = effect
            },
            resetOwnerProjection: { _, _ in }
        )
    }
}

private func consoleMessageSnapshot(
    _ snapshot: WebInspectorCanonicalModelSnapshot
) -> WebInspectorModelSchemaSnapshot<
    ConsoleMessage,
    CanonicalConsoleMessageRecord,
    ConsoleMessageSchemaOwnerEffect
> {
    guard let consoleRuntime = snapshot.consoleRuntime else {
        preconditionFailure(
            "A configured ConsoleMessage schema requires a canonical Console projection."
        )
    }
    return WebInspectorModelSchemaSnapshot(
        entries: consoleRuntime.consoleMessages.map { entry in
            WebInspectorModelSchemaSnapshotEntry(
                id: ConsoleMessage.ID(canonical: entry.record.id),
                record: entry.record,
                queryValue: consoleMessageQueryValue(entry.query),
                canonicalRank: consoleMessageCanonicalRank(entry.record.id)
            )
        },
        ownerEffects: consoleRuntime.consoleMessages.map { entry in
            .rebuildParameterGraphs(
                id: ConsoleMessage.ID(canonical: entry.record.id),
                membership: entry.record.membership,
                seeds: entry.record.parameters
            )
        }
    )
}

private func consoleMessageDelta(
    _ transaction: WebInspectorCanonicalModelTransaction,
    _ lookup: WebInspectorModelSchemaRecordLookup<
        ConsoleMessage,
        CanonicalConsoleMessageRecord
    >
) -> WebInspectorModelSchemaDelta<
    ConsoleMessage,
    CanonicalConsoleMessageRecord,
    ConsoleMessageSchemaOwnerEffect
> {
    guard let consoleRuntime = transaction.consoleRuntime else {
        return WebInspectorModelSchemaDelta(changes: [])
    }

    var order: [ConsoleMessage.ID] = []
    var pendingByID: [ConsoleMessage.ID: ConsoleMessageSchemaPendingChange] = [:]
    for change in consoleRuntime.consoleMessageChanges {
        switch change {
        case let .insert(record, query):
            let id = ConsoleMessage.ID(canonical: record.id)
            precondition(
                pendingByID[id] == nil && lookup.record(for: id) == nil,
                "A canonical Console insertion reused a persistent identity."
            )
            order.append(id)
            pendingByID[id] = .insert(record: record, query: query)

        case let .update(storage, patch, query):
            let id = ConsoleMessage.ID(canonical: storage)
            switch pendingByID[id] {
            case nil:
                precondition(
                    lookup.record(for: id) != nil,
                    "A canonical Console update referenced a missing record."
                )
                order.append(id)
                pendingByID[id] = .update(
                    patches: [patch],
                    query: query,
                    storage: storage
                )
            case let .insert(record, insertionQuery):
                var replacement = record
                replacement.apply(patch)
                pendingByID[id] = .insert(
                    record: replacement,
                    query: query ?? insertionQuery
                )
            case let .update(patches, previousQuery, previousStorage):
                precondition(
                    previousStorage == storage,
                    "A Console patch batch changed persistent identity."
                )
                pendingByID[id] = .update(
                    patches: patches + [patch],
                    query: query ?? previousQuery,
                    storage: storage
                )
            case .delete:
                preconditionFailure(
                    "A canonical Console update followed deletion in one transaction."
                )
            }

        case let .delete(storage):
            let id = ConsoleMessage.ID(canonical: storage)
            switch pendingByID[id] {
            case nil:
                precondition(
                    lookup.record(for: id) != nil,
                    "A canonical Console deletion referenced a missing record."
                )
                order.append(id)
                pendingByID[id] = .delete
            case .insert:
                pendingByID[id] = nil
                order.removeAll { $0 == id }
            case .update:
                pendingByID[id] = .delete
            case .delete:
                preconditionFailure(
                    "A canonical Console transaction deleted one identity twice."
                )
            }
        }
    }

    let changes: [WebInspectorModelSchemaChange<
        ConsoleMessage,
        CanonicalConsoleMessageRecord
    >] = order.map { id in
        guard let pending = pendingByID[id] else {
            preconditionFailure(
                "Console schema order referenced an absent pending change."
            )
        }
        switch pending {
        case let .insert(record, query):
            return .insert(
                id: id,
                record: record,
                queryValue: consoleMessageQueryValue(query),
                canonicalRank: consoleMessageCanonicalRank(record.id)
            )
        case let .update(patches, query, storage):
            return .update(
                id: id,
                patches: WebInspectorModelRecordPatchBatch(patches),
                queryValue: query.map(consoleMessageQueryValue),
                canonicalRank: query.map { _ in
                    consoleMessageCanonicalRank(storage)
                }
            )
        case .delete:
            return .delete(id: id)
        }
    }

    return WebInspectorModelSchemaDelta(
        changes: changes,
        ownerEffects: consoleRuntime.resourceInvalidations.map(
            ConsoleMessageSchemaOwnerEffect.invalidate
        )
    )
}

private func runtimeContextSnapshot(
    _ snapshot: WebInspectorCanonicalModelSnapshot
) -> WebInspectorModelSchemaSnapshot<
    RuntimeContext,
    CanonicalRuntimeContextRecord,
    RuntimeContextSchemaOwnerEffect
> {
    guard let consoleRuntime = snapshot.consoleRuntime else {
        preconditionFailure(
            "A configured RuntimeContext schema requires a canonical Runtime projection."
        )
    }
    return WebInspectorModelSchemaSnapshot(
        entries: consoleRuntime.runtimeContexts.map { entry in
            WebInspectorModelSchemaSnapshotEntry(
                id: RuntimeContext.ID(canonical: entry.record.id),
                record: entry.record,
                queryValue: runtimeContextQueryValue(entry.query),
                canonicalRank: WebInspectorFetchedResultsCanonicalRank(
                    rawValue: entry.record.insertionOrdinal
                )
            )
        }
    )
}

private func runtimeContextDelta(
    _ transaction: WebInspectorCanonicalModelTransaction,
    _ lookup: WebInspectorModelSchemaRecordLookup<
        RuntimeContext,
        CanonicalRuntimeContextRecord
    >
) -> WebInspectorModelSchemaDelta<
    RuntimeContext,
    CanonicalRuntimeContextRecord,
    RuntimeContextSchemaOwnerEffect
> {
    guard let consoleRuntime = transaction.consoleRuntime else {
        return WebInspectorModelSchemaDelta(changes: [])
    }

    var order: [RuntimeContext.ID] = []
    var pendingByID: [RuntimeContext.ID: RuntimeContextSchemaPendingChange] = [:]
    for change in consoleRuntime.runtimeContextChanges {
        switch change {
        case let .insert(record, query):
            let id = RuntimeContext.ID(canonical: record.id)
            precondition(
                pendingByID[id] == nil && lookup.record(for: id) == nil,
                "A canonical Runtime insertion reused a persistent identity."
            )
            order.append(id)
            pendingByID[id] = .insert(record: record, query: query)
        case let .delete(storage):
            let id = RuntimeContext.ID(canonical: storage)
            switch pendingByID[id] {
            case nil:
                precondition(
                    lookup.record(for: id) != nil,
                    "A canonical Runtime deletion referenced a missing record."
                )
                order.append(id)
                pendingByID[id] = .delete
            case .insert:
                pendingByID[id] = nil
                order.removeAll { $0 == id }
            case .delete:
                preconditionFailure(
                    "A canonical Runtime transaction deleted one identity twice."
                )
            }
        }
    }

    let changes: [WebInspectorModelSchemaChange<
        RuntimeContext,
        CanonicalRuntimeContextRecord
    >] = order.map { id in
        guard let pending = pendingByID[id] else {
            preconditionFailure(
                "Runtime schema order referenced an absent pending change."
            )
        }
        switch pending {
        case let .insert(record, query):
            return .insert(
                id: id,
                record: record,
                queryValue: runtimeContextQueryValue(query),
                canonicalRank: WebInspectorFetchedResultsCanonicalRank(
                    rawValue: record.insertionOrdinal
                )
            )
        case .delete:
            return .delete(id: id)
        }
    }
    return WebInspectorModelSchemaDelta(changes: changes)
}

private func consoleMessageQueryValue(
    _ query: CanonicalConsoleMessageQueryProjection
) -> ConsoleMessage.QueryValue {
    precondition(
        query.insertionOrdinal <= UInt64(Int.max),
        "Console insertion index cannot be represented by the public query value."
    )
    return ConsoleMessage.QueryValue(
        id: ConsoleMessage.ID(canonical: query.id),
        insertionIndex: Int(query.insertionOrdinal),
        source: query.source,
        level: query.level,
        kind: query.kind,
        text: query.text,
        url: query.url,
        line: query.line,
        column: query.column,
        repeatCount: query.repeatCount,
        timestamp: query.timestamp
    )
}

private func runtimeContextQueryValue(
    _ query: CanonicalRuntimeContextQueryProjection
) -> RuntimeContext.QueryValue {
    RuntimeContext.QueryValue(
        id: RuntimeContext.ID(canonical: query.id),
        name: query.name,
        frameID: query.frameID,
        kind: query.kind
    )
}

private func consoleMessageCanonicalRank(
    _ id: CanonicalConsoleMessageIDStorage
) -> WebInspectorFetchedResultsCanonicalRank {
    WebInspectorFetchedResultsCanonicalRank(rawValue: id.ordinal)
}
