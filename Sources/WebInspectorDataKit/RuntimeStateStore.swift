import WebInspectorProxyKit

/// Owns Runtime execution-context identity, selection, remote-object identity,
/// and local object membership.
///
/// `WebInspectorModelContext` remains the attachment and transport coordinator. It
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
        case group(RuntimeObjectGroup.ID)
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
    private var nextGroupOrdinal: UInt64
    private var activeGroupIDs: Set<RuntimeObjectGroup.ID>

    package init() {
        contextsByID = [:]
        orderedContextIDs = []
        selectedContextID = nil
        objectsByID = [:]
        nextSyntheticObjectOrdinal = 0
        defaultExecutionGeneration = 0
        nextGroupOrdinal = 0
        activeGroupIDs = []
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
        _ context: RuntimeContext?
    ) {
        guard let context else {
            selectedContextID = nil
            return
        }
        guard contextsByID[context.id] === context else {
            preconditionFailure("RuntimeContext is not registered in this WebInspectorModelContext.")
        }
        selectedContextID = context.id
    }

    package func evaluationBinding(
        for context: RuntimeContext?
    ) throws -> EvaluationBinding {
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
        groupID: RuntimeObjectGroup.ID
    ) throws -> RuntimeEvaluation {
        try requireActiveGroup(groupID)
        if let executionContext = binding.executionContext {
            try requireRegisteredContext(executionContext)
        } else if binding.defaultExecutionGeneration != defaultExecutionGeneration {
            throw WebInspectorProxyError.disconnected(
                "Runtime evaluation target is no longer current in this WebInspectorModelContext."
            )
        }
        return RuntimeEvaluation(
            object: register(result.object, owner: .group(groupID)),
            isException: result.wasThrown
        )
    }

    package func objectBinding(
        for object: RuntimeObject,
        groupID: RuntimeObjectGroup.ID
    ) throws -> ObjectBinding? {
        try requireActiveGroup(groupID)
        let object = try requireRegisteredObject(object, owner: .group(groupID))
        return object.proxyID.map { ObjectBinding(remoteID: $0, object: object) }
    }

    package func finishProperties(
        _ descriptors: [Runtime.PropertyDescriptor],
        binding: ObjectBinding,
        groupID: RuntimeObjectGroup.ID
    ) throws -> [RuntimeObject.Property] {
        try requireActiveGroup(groupID)
        try requireRegisteredObject(binding.object, owner: .group(groupID))
        return descriptors.map { descriptor in
            let remoteValue = descriptor.value
            let childObject = remoteValue.flatMap { value in
                value.id == nil ? nil : register(value, owner: .group(groupID))
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
        groupID: RuntimeObjectGroup.ID
    ) throws -> [RuntimeObject.Entry] {
        try requireActiveGroup(groupID)
        try requireRegisteredObject(binding.object, owner: .group(groupID))
        return entries.map { entry in
            RuntimeObject.Entry(
                key: entry.key.map { register($0, owner: .group(groupID)) },
                value: register(entry.value, owner: .group(groupID))
            )
        }
    }

    package func registerConsoleParameter(
        _ payload: Runtime.RemoteObject
    ) -> RuntimeObject {
        return register(payload, owner: .console)
    }

    package func removeConsoleOwnership(
        from objects: [RuntimeObject]
    ) {
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
    ) {
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
        isCurrentPageTarget: Bool
    ) {
        switch event {
        case let .executionContextCreated(context):
            applyExecutionContextCreated(context)
        case let .executionContextDestroyed(id):
            applyExecutionContextDestroyed(id)
        case .executionContextsCleared:
            if isCurrentPageTarget {
                reset()
            } else if let sourceTargetID {
                clear(targetID: sourceTargetID)
            }
        case .unknown:
            break
        }
    }

    package func reset() {
        contextsByID = [:]
        orderedContextIDs = []
        selectedContextID = nil
        objectsByID = [:]
        activeGroupIDs = []
        advanceDefaultExecutionGeneration()
    }

    package func createGroupID() -> RuntimeObjectGroup.ID {
        precondition(nextGroupOrdinal < UInt64.max, "Runtime object-group identity overflowed.")
        let id = RuntimeObjectGroup.ID(rawValue: nextGroupOrdinal)
        nextGroupOrdinal += 1
        precondition(activeGroupIDs.insert(id).inserted)
        return id
    }

    package func isActiveGroup(_ id: RuntimeObjectGroup.ID) -> Bool {
        activeGroupIDs.contains(id)
    }

    package func invalidateGroup(_ id: RuntimeObjectGroup.ID) {
        guard activeGroupIDs.remove(id) != nil else {
            return
        }
        for (objectID, var record) in objectsByID.map({ ($0.key, $0.value) }) {
            record.owners.remove(.group(id))
            if record.owners.isEmpty {
                objectsByID.removeValue(forKey: objectID)
            } else {
                objectsByID[objectID] = record
            }
        }
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
        owner: ObjectOwner
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

        let object = RuntimeObject(id: id, remoteObject: payload)
        objectsByID[id] = ObjectRecord(object: object, owners: [owner])
        return object
    }

    @discardableResult
    private func requireRegisteredContext(_ context: RuntimeContext) throws -> RuntimeContext {
        guard contextsByID[context.id] === context else {
            throw WebInspectorProxyError.disconnected(
                "RuntimeContext is not registered in this WebInspectorModelContext."
            )
        }
        return context
    }

    @discardableResult
    private func requireRegisteredObject(
        _ object: RuntimeObject,
        owner: ObjectOwner? = nil
    ) throws -> RuntimeObject {
        guard let record = objectsByID[object.id],
              record.object === object,
              owner.map({ record.owners.contains($0) }) ?? true else {
            throw WebInspectorProxyError.disconnected(
                "RuntimeObject is not registered in this WebInspectorModelContext."
            )
        }
        return object
    }

    private func requireActiveGroup(_ id: RuntimeObjectGroup.ID) throws {
        guard activeGroupIDs.contains(id) else {
            throw WebInspectorModelError.staleModel
        }
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
