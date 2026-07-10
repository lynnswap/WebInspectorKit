import WebInspectorProxyKit

/// Owns Runtime execution-context identity, selection, remote-object identity,
/// and local object membership.
///
/// `WebInspectorContext` remains the attachment and transport coordinator. It
/// validates command inputs through this store, performs protocol I/O, and
/// returns replies for post-suspension validation and materialization. The
/// store never retains an actor token or starts a task.
package final class RuntimeStateStore {
    package struct EvaluationBinding {
        package let executionContextID: Runtime.ExecutionContext.ID?

        fileprivate let executionContext: RuntimeContext?
        fileprivate let defaultExecutionGeneration: UInt64
    }

    package struct ObjectBinding {
        package let remoteID: Runtime.RemoteObject.ID

        fileprivate let object: RuntimeObject
    }

    private enum ObjectOwner: Hashable {
        case client
        case console
    }

    private struct ObjectRecord {
        let object: RuntimeObject
        var owners: Set<ObjectOwner>
    }

    private var contextsByID: [RuntimeContext.ID: RuntimeContext]
    private var orderedContextIDs: [RuntimeContext.ID]
    private var selectedContextID: RuntimeContext.ID?
    private var objectsByID: [RuntimeObject.ID: ObjectRecord]
    private var nextSyntheticObjectOrdinal: Int
    private var defaultExecutionGeneration: UInt64

    package init() {
        contextsByID = [:]
        orderedContextIDs = []
        selectedContextID = nil
        objectsByID = [:]
        nextSyntheticObjectOrdinal = 0
        defaultExecutionGeneration = 0
    }

    package var executionContexts: [RuntimeContext] {
        orderedContextIDs.map { id in
            guard let context = contextsByID[id] else {
                preconditionFailure("RuntimeStateStore context order referenced an unregistered identity.")
            }
            return context
        }
    }

    package var selectedContext: RuntimeContext? {
        guard let selectedContextID else {
            return nil
        }
        guard let context = contextsByID[selectedContextID] else {
            preconditionFailure("RuntimeStateStore selection referenced an unregistered identity.")
        }
        return context
    }

    package func select(
        _ context: RuntimeContext?,
        isolation: isolated (any Actor) = #isolation
    ) {
        _ = isolation
        guard let context else {
            selectedContextID = nil
            return
        }
        guard contextsByID[context.id] === context else {
            preconditionFailure("RuntimeContext is not registered in this WebInspectorContext.")
        }
        selectedContextID = context.id
    }

    package func evaluationBinding(
        for context: RuntimeContext?,
        isolation: isolated (any Actor) = #isolation
    ) throws -> EvaluationBinding {
        _ = isolation
        let executionContext: RuntimeContext?
        if let context {
            try requireRegisteredContext(context)
            executionContext = context
        } else {
            executionContext = selectedContext
        }
        return EvaluationBinding(
            executionContextID: executionContext?.id.proxyID,
            executionContext: executionContext,
            defaultExecutionGeneration: defaultExecutionGeneration
        )
    }

    package func finishEvaluation(
        _ result: Runtime.EvaluationResult,
        binding: EvaluationBinding,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor) = #isolation
    ) throws -> RuntimeEvaluation {
        _ = isolation
        if let executionContext = binding.executionContext {
            try requireRegisteredContext(executionContext)
        } else if binding.defaultExecutionGeneration != defaultExecutionGeneration {
            throw WebInspectorProxyError.disconnected(
                "Runtime evaluation target is no longer current in this WebInspectorContext."
            )
        }
        return RuntimeEvaluation(
            object: register(result.object, owner: .client, modelContext: modelContext),
            isException: result.wasThrown
        )
    }

    package func objectBinding(
        for object: RuntimeObject,
        isolation: isolated (any Actor) = #isolation
    ) throws -> ObjectBinding? {
        _ = isolation
        let object = try requireRegisteredObject(object)
        return object.proxyID.map { ObjectBinding(remoteID: $0, object: object) }
    }

    package func finishProperties(
        _ descriptors: [Runtime.PropertyDescriptor],
        binding: ObjectBinding,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor) = #isolation
    ) throws -> [RuntimeObject.Property] {
        _ = isolation
        try requireRegisteredObject(binding.object)
        return descriptors.map { descriptor in
            let remoteValue = descriptor.value
            let childObject = remoteValue.flatMap { value in
                value.id == nil ? nil : register(value, owner: .client, modelContext: modelContext)
            }
            return RuntimeObject.Property(
                name: descriptor.name,
                value: remoteValue.flatMap(Self.valueText),
                object: childObject
            )
        }
    }

    package func finishCollectionEntries(
        _ entries: [Runtime.CollectionEntry],
        binding: ObjectBinding,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor) = #isolation
    ) throws -> [RuntimeObject.Entry] {
        _ = isolation
        try requireRegisteredObject(binding.object)
        return entries.map { entry in
            RuntimeObject.Entry(
                key: entry.key.map { register($0, owner: .client, modelContext: modelContext) },
                value: register(entry.value, owner: .client, modelContext: modelContext)
            )
        }
    }

    package func registerConsoleParameter(
        _ payload: Runtime.RemoteObject,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor) = #isolation
    ) -> RuntimeObject {
        _ = isolation
        return register(payload, owner: .console, modelContext: modelContext)
    }

    package func removeConsoleOwnership(
        from objects: [RuntimeObject],
        isolation: isolated (any Actor) = #isolation
    ) {
        _ = isolation
        for object in objects {
            guard var record = objectsByID[object.id], record.object === object else {
                continue
            }
            record.owners.remove(.console)
            if record.owners.isEmpty {
                objectsByID.removeValue(forKey: object.id)
            } else {
                objectsByID[object.id] = record
            }
        }
    }

    package func removeAllConsoleOwnership(
        isolation: isolated (any Actor) = #isolation
    ) {
        _ = isolation
        for (id, var record) in objectsByID.map({ ($0.key, $0.value) }) {
            record.owners.remove(.console)
            if record.owners.isEmpty {
                objectsByID.removeValue(forKey: id)
            } else {
                objectsByID[id] = record
            }
        }
    }

    package func apply(
        _ event: Runtime.Event,
        sourceTargetID: WebInspectorTarget.ID?,
        isolation: isolated (any Actor) = #isolation
    ) {
        _ = isolation
        switch event {
        case let .executionContextCreated(context):
            applyExecutionContextCreated(context)
        case let .executionContextDestroyed(id):
            applyExecutionContextDestroyed(id)
        case let .executionContextsCleared(eventTargetID):
            if eventTargetID == .currentPage || eventTargetID == sourceTargetID {
                reset(isolation: isolation)
            } else {
                clear(targetID: eventTargetID)
            }
        case .unknown:
            break
        }
    }

    package func reset(isolation: isolated (any Actor) = #isolation) {
        _ = isolation
        contextsByID = [:]
        orderedContextIDs = []
        selectedContextID = nil
        objectsByID = [:]
        advanceDefaultExecutionGeneration()
    }

    private func applyExecutionContextCreated(_ payload: Runtime.ExecutionContext) {
        let id = RuntimeContext.ID(payload.id)
        if let context = contextsByID[id] {
            context.update(from: payload)
        } else {
            contextsByID[id] = RuntimeContext(context: payload)
            orderedContextIDs.append(id)
        }
        if selectedContextID == nil {
            selectedContextID = id
        }
    }

    private func applyExecutionContextDestroyed(_ proxyID: Runtime.ExecutionContext.ID) {
        let id = RuntimeContext.ID(proxyID)
        guard contextsByID.removeValue(forKey: id) != nil else {
            skipEvent("Runtime.executionContextDestroyed referenced an untracked context")
            return
        }
        orderedContextIDs.removeAll { $0 == id }
        if selectedContextID == id {
            selectedContextID = orderedContextIDs.first
        }
    }

    private func clear(targetID: WebInspectorTarget.ID) {
        let removedContextIDs = Set(contextsByID.keys.filter { id in
            id.proxyID.targetScopeRawValue == targetID.rawValue
        })
        for id in removedContextIDs {
            contextsByID.removeValue(forKey: id)
        }
        orderedContextIDs.removeAll { removedContextIDs.contains($0) }
        if let selectedContextID, removedContextIDs.contains(selectedContextID) {
            self.selectedContextID = orderedContextIDs.first
        }

        let removedObjectIDs = objectsByID.compactMap { id, record in
            record.object.proxyID?.targetScopeRawValue == targetID.rawValue ? id : nil
        }
        for id in removedObjectIDs {
            objectsByID.removeValue(forKey: id)
        }
    }

    private func register(
        _ payload: Runtime.RemoteObject,
        owner: ObjectOwner,
        modelContext: WebInspectorContext
    ) -> RuntimeObject {
        let id: RuntimeObject.ID
        if let proxyID = payload.id {
            id = RuntimeObject.ID(remote: proxyID)
        } else {
            precondition(
                nextSyntheticObjectOrdinal < Int.max,
                "RuntimeObject synthetic identity ordinal overflowed."
            )
            id = RuntimeObject.ID(synthetic: nextSyntheticObjectOrdinal)
            nextSyntheticObjectOrdinal += 1
        }

        if var record = objectsByID[id] {
            record.object.update(from: payload)
            record.owners.insert(owner)
            objectsByID[id] = record
            return record.object
        }

        let object = RuntimeObject(id: id, remoteObject: payload, modelContext: modelContext)
        objectsByID[id] = ObjectRecord(object: object, owners: [owner])
        return object
    }

    @discardableResult
    private func requireRegisteredContext(_ context: RuntimeContext) throws -> RuntimeContext {
        guard contextsByID[context.id] === context else {
            throw WebInspectorProxyError.disconnected(
                "RuntimeContext is not registered in this WebInspectorContext."
            )
        }
        return context
    }

    @discardableResult
    private func requireRegisteredObject(_ object: RuntimeObject) throws -> RuntimeObject {
        guard objectsByID[object.id]?.object === object else {
            throw WebInspectorProxyError.disconnected(
                "RuntimeObject is not registered in this WebInspectorContext."
            )
        }
        return object
    }

    private func advanceDefaultExecutionGeneration() {
        precondition(
            defaultExecutionGeneration < UInt64.max,
            "Runtime default execution generation overflowed."
        )
        defaultExecutionGeneration += 1
    }

    private static func valueText(for object: Runtime.RemoteObject) -> String? {
        if let description = object.description {
            return description
        }
        guard let value = object.value else {
            return nil
        }
        switch value {
        case let .string(value):
            return value
        case let .number(value):
            return String(value)
        case let .bool(value):
            return String(value)
        case .null:
            return "null"
        case .array,
             .object:
            return nil
        }
    }

    private func skipEvent(_ reason: String) {
        WebInspectorDataKitLog.debug("event skipped: \(reason)")
    }
}
