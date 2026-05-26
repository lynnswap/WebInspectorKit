import Observation

package struct RuntimeExecutionContext: Equatable, Sendable {
    package var id: ExecutionContextID
    package var targetID: ProtocolTargetIdentifier
    package var type: RuntimeExecutionContextType
    package var name: String
    package var frameID: DOMFrameIdentifier?

    package init(
        id: ExecutionContextID,
        targetID: ProtocolTargetIdentifier,
        type: RuntimeExecutionContextType = .normal,
        name: String = "",
        frameID: DOMFrameIdentifier? = nil
    ) {
        self.id = id
        self.targetID = targetID
        self.type = type
        self.name = name
        self.frameID = frameID
    }
}

package struct RuntimeSessionSnapshot: Equatable, Sendable {
    package var executionContextsByID: [ExecutionContextID: RuntimeExecutionContext]
    package var activeContextID: ExecutionContextID?
    package var normalContextIDByTargetID: [ProtocolTargetIdentifier: ExecutionContextID]
    package var remoteObjectsByID: [RuntimeRemoteObjectIdentifierKey: RuntimeRemoteObjectPayload]
    package var objectGroupByRemoteObjectID: [RuntimeRemoteObjectIdentifierKey: RuntimeObjectGroup]
    package var objectGroupTargetsByGroup: [RuntimeObjectGroup: Set<ProtocolTargetIdentifier>]
    package var unsupportedCommandsByTargetID: [ProtocolTargetIdentifier: Set<String>]
}

@MainActor
@Observable
package final class RuntimeSession {
    package private(set) var activeContextID: ExecutionContextID?

    @ObservationIgnored private var executionContextsByID: [ExecutionContextID: RuntimeExecutionContext]
    @ObservationIgnored private var normalContextIDByTargetID: [ProtocolTargetIdentifier: ExecutionContextID]
    @ObservationIgnored private var remoteObjectsByID: [RuntimeRemoteObjectIdentifierKey: RuntimeRemoteObjectPayload]
    @ObservationIgnored private var objectGroupByRemoteObjectID: [RuntimeRemoteObjectIdentifierKey: RuntimeObjectGroup]
    @ObservationIgnored private var objectGroupTargetsByGroup: [RuntimeObjectGroup: Set<ProtocolTargetIdentifier>]
    @ObservationIgnored private var unsupportedCommandsByTargetID: [ProtocolTargetIdentifier: Set<String>]

    package init() {
        activeContextID = nil
        executionContextsByID = [:]
        normalContextIDByTargetID = [:]
        remoteObjectsByID = [:]
        objectGroupByRemoteObjectID = [:]
        objectGroupTargetsByGroup = [:]
        unsupportedCommandsByTargetID = [:]
    }

    package func reset() {
        activeContextID = nil
        executionContextsByID.removeAll()
        normalContextIDByTargetID.removeAll()
        remoteObjectsByID.removeAll()
        objectGroupByRemoteObjectID.removeAll()
        objectGroupTargetsByGroup.removeAll()
        unsupportedCommandsByTargetID.removeAll()
    }

    package func snapshot() -> RuntimeSessionSnapshot {
        RuntimeSessionSnapshot(
            executionContextsByID: executionContextsByID,
            activeContextID: activeContextID,
            normalContextIDByTargetID: normalContextIDByTargetID,
            remoteObjectsByID: remoteObjectsByID,
            objectGroupByRemoteObjectID: objectGroupByRemoteObjectID,
            objectGroupTargetsByGroup: objectGroupTargetsByGroup,
            unsupportedCommandsByTargetID: unsupportedCommandsByTargetID
        )
    }

    package func executionContext(for contextID: ExecutionContextID) -> RuntimeExecutionContext? {
        executionContextsByID[contextID]
    }

    package func activeContext(targetID: ProtocolTargetIdentifier? = nil) -> RuntimeExecutionContext? {
        if let targetID {
            if let contextID = normalContextIDByTargetID[targetID] {
                return executionContextsByID[contextID]
            }
            guard let activeContextID,
                  let context = executionContextsByID[activeContextID],
                  context.targetID == targetID else {
                return nil
            }
            return context
        }
        guard let activeContextID else {
            return nil
        }
        return executionContextsByID[activeContextID]
    }

    package func applyExecutionContextCreated(_ payload: RuntimeExecutionContextPayload, targetID: ProtocolTargetIdentifier) {
        let type = payload.type ?? .normal
        let context = RuntimeExecutionContext(
            id: payload.id,
            targetID: targetID,
            type: type,
            name: payload.name ?? "",
            frameID: payload.frameID
        )
        applyExecutionContextCreated(context)
    }

    package func applyExecutionContextCreated(_ record: ExecutionContextRecord) {
        applyExecutionContextCreated(
            RuntimeExecutionContext(
                id: record.id,
                targetID: record.targetID,
                type: record.type,
                name: record.name,
                frameID: record.frameID
            )
        )
    }

    package func applyExecutionContextCreated(_ context: RuntimeExecutionContext) {
        if context.type == .normal,
           let oldContextID = normalContextIDToReplace(with: context),
           oldContextID != context.id {
            executionContextsByID.removeValue(forKey: oldContextID)
            if activeContextID == oldContextID {
                activeContextID = nil
            }
        }
        executionContextsByID[context.id] = context
        if context.type == .normal {
            normalContextIDByTargetID[context.targetID] = context.id
        }
        if context.type == .normal {
            activeContextID = context.id
        }
    }

    package func selectExecutionContext(_ contextID: ExecutionContextID?) {
        guard let contextID else {
            activeContextID = nil
            return
        }
        guard executionContextsByID[contextID] != nil else {
            return
        }
        activeContextID = contextID
    }

    package func applyTargetDestroyed(_ targetID: ProtocolTargetIdentifier) {
        executionContextsByID = executionContextsByID.filter { $0.value.targetID != targetID }
        normalContextIDByTargetID.removeValue(forKey: targetID)
        remoteObjectsByID = remoteObjectsByID.filter { $0.key.targetID != targetID }
        objectGroupByRemoteObjectID = objectGroupByRemoteObjectID.filter { $0.key.targetID != targetID }
        for group in Array(objectGroupTargetsByGroup.keys) {
            objectGroupTargetsByGroup[group]?.remove(targetID)
            if objectGroupTargetsByGroup[group]?.isEmpty == true {
                objectGroupTargetsByGroup.removeValue(forKey: group)
            }
        }
        unsupportedCommandsByTargetID.removeValue(forKey: targetID)
        if let activeContextID,
           executionContextsByID[activeContextID] == nil {
            self.activeContextID = normalContextIDByTargetID.values.sorted(by: { $0.rawValue < $1.rawValue }).first
        }
    }

    package func applyTargetCommitted(oldTargetID: ProtocolTargetIdentifier?, newTargetID: ProtocolTargetIdentifier) {
        if let oldTargetID {
            for (contextID, context) in executionContextsByID where context.targetID == oldTargetID {
                executionContextsByID[contextID]?.targetID = newTargetID
            }
            if let normalContextID = normalContextIDByTargetID.removeValue(forKey: oldTargetID) {
                normalContextIDByTargetID[newTargetID] = normalContextID
            }
            var movedObjects: [RuntimeRemoteObjectIdentifierKey: RuntimeRemoteObjectPayload] = [:]
            var movedObjectGroups: [RuntimeRemoteObjectIdentifierKey: RuntimeObjectGroup] = [:]
            for (key, object) in remoteObjectsByID where key.targetID == oldTargetID {
                let newKey = RuntimeRemoteObjectIdentifierKey(targetID: newTargetID, objectID: key.objectID)
                movedObjects[newKey] = object
                remoteObjectsByID.removeValue(forKey: key)
                if let group = objectGroupByRemoteObjectID.removeValue(forKey: key) {
                    movedObjectGroups[newKey] = group
                }
            }
            remoteObjectsByID.merge(movedObjects) { _, new in new }
            objectGroupByRemoteObjectID.merge(movedObjectGroups) { _, new in new }
            for group in objectGroupTargetsByGroup.keys {
                if objectGroupTargetsByGroup[group]?.remove(oldTargetID) != nil {
                    objectGroupTargetsByGroup[group]?.insert(newTargetID)
                }
            }
            if let unsupported = unsupportedCommandsByTargetID.removeValue(forKey: oldTargetID) {
                unsupportedCommandsByTargetID[newTargetID, default: []].formUnion(unsupported)
            }
        }
    }

    package func registerRemoteObject(
        _ object: RuntimeRemoteObjectPayload,
        targetID: ProtocolTargetIdentifier,
        objectGroup: RuntimeObjectGroup? = nil
    ) {
        if let key = object.identifierKey(targetID: targetID) {
            remoteObjectsByID[key] = object
            if let objectGroup {
                objectGroupByRemoteObjectID[key] = objectGroup
            } else {
                objectGroupByRemoteObjectID.removeValue(forKey: key)
            }
        }
        if let objectGroup {
            objectGroupTargetsByGroup[objectGroup, default: []].insert(targetID)
        }
    }

    package func applyEvaluationResult(_ result: RuntimeEvaluationResultPayload, request: RuntimeEvaluationRequest) {
        registerRemoteObject(result.result, targetID: request.targetID, objectGroup: request.objectGroup)
    }

    package func releaseObject(_ key: RuntimeRemoteObjectIdentifierKey) {
        remoteObjectsByID.removeValue(forKey: key)
        objectGroupByRemoteObjectID.removeValue(forKey: key)
    }

    package func releaseObjectGroup(_ objectGroup: RuntimeObjectGroup, targetID: ProtocolTargetIdentifier) {
        let releasedKeys = objectGroupByRemoteObjectID.compactMap { key, group in
            key.targetID == targetID && group == objectGroup ? key : nil
        }
        for key in releasedKeys {
            remoteObjectsByID.removeValue(forKey: key)
            objectGroupByRemoteObjectID.removeValue(forKey: key)
        }
        objectGroupTargetsByGroup[objectGroup]?.remove(targetID)
        if objectGroupTargetsByGroup[objectGroup]?.isEmpty == true {
            objectGroupTargetsByGroup.removeValue(forKey: objectGroup)
        }
    }

    package func markCommandUnsupported(_ method: String, targetID: ProtocolTargetIdentifier) {
        unsupportedCommandsByTargetID[targetID, default: []].insert(method)
    }

    package func supportsCommand(_ method: String, targetID: ProtocolTargetIdentifier) -> Bool {
        unsupportedCommandsByTargetID[targetID]?.contains(method) != true
    }

    private func normalContextIDToReplace(with context: RuntimeExecutionContext) -> ExecutionContextID? {
        executionContextsByID.values
            .filter {
                $0.type == .normal
                    && $0.targetID == context.targetID
                    && $0.frameID == context.frameID
                    && $0.name == context.name
                    && $0.id != context.id
            }
            .map(\.id)
            .min { $0.rawValue < $1.rawValue }
    }

    package func enableIntent(targetID: ProtocolTargetIdentifier) -> RuntimeCommandIntent {
        .enable(targetID: targetID)
    }

    package func evaluateIntent(
        expression: String,
        targetID: ProtocolTargetIdentifier,
        contextID: ExecutionContextID? = nil,
        objectGroup: RuntimeObjectGroup? = RuntimeObjectGroup("console")
    ) -> RuntimeCommandIntent {
        .evaluate(
            RuntimeEvaluationRequest(
                targetID: targetID,
                expression: expression,
                objectGroup: objectGroup,
                includeCommandLineAPI: true,
                doNotPauseOnExceptionsAndMuteConsole: false,
                contextID: contextID ?? activeContext(targetID: targetID)?.id,
                returnByValue: false,
                generatePreview: true,
                saveResult: true,
                emulateUserGesture: true
            )
        )
    }
}
