package let webInspectorConsoleMessageSchema = WebInspectorModelSchema<
    ConsoleMessage,
    CanonicalConsoleMessageRecord
>(
    featureID: .consoleRuntime,
    makeModel: { context, id, record in
        ConsoleMessage(id: id, record: record, modelContext: context)
    },
    updateModel: { context, model, record in
        model.replace(with: record, modelContext: context)
    },
    invalidateModel: { _, model in
        model.invalidate()
    }
)

package let webInspectorRuntimeContextSchema = WebInspectorModelSchema<
    RuntimeContext,
    CanonicalRuntimeContextRecord
>(
    featureID: .consoleRuntime,
    makeModel: { context, id, record in
        RuntimeContext(id: id, record: record, modelContext: context)
    },
    updateModel: { context, model, record in
        model.replace(with: record, modelContext: context)
    },
    invalidateModel: { _, model in
        model.invalidate()
    }
)

package func webInspectorConsoleRuntimeSnapshotMutations(
    _ snapshot: CanonicalConsoleRuntimeSnapshot
) -> (
    contexts: [WebInspectorModelMutation<RuntimeContext>],
    messages: [WebInspectorModelMutation<ConsoleMessage>]
) {
    (
        contexts: snapshot.runtimeContexts.map { entry in
            webInspectorRuntimeContextSchema.upsert(
                record: entry.record,
                queryValue: runtimeContextQueryValue(entry.query),
                canonicalRank: WebInspectorModelCanonicalRank(
                    rawValue: entry.record.insertionOrdinal
                )
            )
        },
        messages: snapshot.consoleMessages.map { entry in
            webInspectorConsoleMessageSchema.upsert(
                record: entry.record,
                queryValue: consoleMessageQueryValue(entry.query),
                canonicalRank: consoleMessageCanonicalRank(entry.record.id)
            )
        }
    )
}

package func webInspectorConsoleRuntimeMutations(
    _ transaction: CanonicalConsoleRuntimeTransaction,
    staged store: CanonicalConsoleRuntimeStore
) -> (
    contexts: [WebInspectorModelMutation<RuntimeContext>],
    messages: [WebInspectorModelMutation<ConsoleMessage>]
) {
    var contextOrder: [CanonicalRuntimeContextIDStorage] = []
    var contextIDs: Set<CanonicalRuntimeContextIDStorage> = []
    for change in transaction.runtimeContextChanges {
        let id: CanonicalRuntimeContextIDStorage = switch change {
        case let .insert(record, _): record.id
        case let .delete(id): id
        }
        if contextIDs.insert(id).inserted { contextOrder.append(id) }
    }
    let contexts = contextOrder.map { id in
        guard let record = store.runtimeContext(for: id) else {
            return webInspectorRuntimeContextSchema.delete(
                id: RuntimeContext.ID(canonical: id)
            )
        }
        return webInspectorRuntimeContextSchema.upsert(
            record: record,
            queryValue: runtimeContextQueryValue(record.queryProjection),
            canonicalRank: WebInspectorModelCanonicalRank(
                rawValue: record.insertionOrdinal
            )
        )
    }

    var messageOrder: [CanonicalConsoleMessageIDStorage] = []
    var messageIDs: Set<CanonicalConsoleMessageIDStorage> = []
    for change in transaction.consoleMessageChanges {
        let id: CanonicalConsoleMessageIDStorage = switch change {
        case let .insert(record, _): record.id
        case let .update(id, _, _), let .delete(id): id
        }
        if messageIDs.insert(id).inserted { messageOrder.append(id) }
    }
    let messages = messageOrder.map { id in
        guard let record = store.consoleMessage(for: id) else {
            return webInspectorConsoleMessageSchema.delete(
                id: ConsoleMessage.ID(canonical: id)
            )
        }
        return webInspectorConsoleMessageSchema.upsert(
            record: record,
            queryValue: consoleMessageQueryValue(record.queryProjection),
            canonicalRank: consoleMessageCanonicalRank(id)
        )
    }
    return (contexts, messages)
}

private func consoleMessageQueryValue(
    _ query: CanonicalConsoleMessageQueryProjection
) -> ConsoleMessage.QueryValue {
    ConsoleMessage.QueryValue(
        id: ConsoleMessage.ID(canonical: query.id),
        insertionIndex: Int(clamping: query.insertionOrdinal),
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
        frameID: query.frameID.map(WebInspectorFrameID.init),
        kind: query.kind
    )
}

private func consoleMessageCanonicalRank(
    _ id: CanonicalConsoleMessageIDStorage
) -> WebInspectorModelCanonicalRank {
    WebInspectorModelCanonicalRank(rawValue: id.ordinal)
}
