import Observation

package struct RuntimeExecutionContext: Equatable, Sendable {
    package var id: ExecutionContextID
    package var targetID: ProtocolTargetIdentifier
    package var runtimeAgentTargetID: ProtocolTargetIdentifier
    package var type: RuntimeExecutionContextType
    package var name: String
    package var frameID: DOMFrameIdentifier?

    package init(
        id: ExecutionContextID,
        targetID: ProtocolTargetIdentifier,
        runtimeAgentTargetID: ProtocolTargetIdentifier? = nil,
        type: RuntimeExecutionContextType = .normal,
        name: String = "",
        frameID: DOMFrameIdentifier? = nil
    ) {
        self.id = id
        self.targetID = targetID
        self.runtimeAgentTargetID = runtimeAgentTargetID ?? targetID
        self.type = type
        self.name = name
        self.frameID = frameID
    }
}

package struct RuntimeRemoteObjectRecord: Equatable, Sendable {
    package var payload: RuntimeRemoteObjectPayload
    package var objectGroup: RuntimeObjectGroup?
    package var executionContextID: ExecutionContextID?

    package init(
        payload: RuntimeRemoteObjectPayload,
        objectGroup: RuntimeObjectGroup? = nil,
        executionContextID: ExecutionContextID? = nil
    ) {
        self.payload = payload
        self.objectGroup = objectGroup
        self.executionContextID = executionContextID
    }
}

package struct RuntimeSessionSnapshot: Equatable, Sendable {
    package var executionContextsByID: [ExecutionContextID: RuntimeExecutionContext]
    package var selectedContextID: ExecutionContextID?
    package var normalContextIDByTargetID: [ProtocolTargetIdentifier: ExecutionContextID]
    package var remoteObjectsByID: [RuntimeRemoteObjectIdentifierKey: RuntimeRemoteObjectRecord]
    package var objectGroupRuntimeAgentTargetsByGroup: [RuntimeObjectGroup: Set<ProtocolTargetIdentifier>]
    package var unsupportedCommandsByTargetID: [ProtocolTargetIdentifier: Set<String>]
}

@MainActor
@Observable
package final class RuntimeSession {
    package private(set) var selectedContextID: ExecutionContextID?

    private var executionContextsByID: [ExecutionContextID: RuntimeExecutionContext]
    private var normalContextIDByTargetID: [ProtocolTargetIdentifier: ExecutionContextID]
    private var remoteObjectsByID: [RuntimeRemoteObjectIdentifierKey: RuntimeRemoteObjectRecord]
    private var objectGroupRuntimeAgentTargetsByGroup: [RuntimeObjectGroup: Set<ProtocolTargetIdentifier>]
    private var unsupportedCommandsByTargetID: [ProtocolTargetIdentifier: Set<String>]

    package init() {
        selectedContextID = nil
        executionContextsByID = [:]
        normalContextIDByTargetID = [:]
        remoteObjectsByID = [:]
        objectGroupRuntimeAgentTargetsByGroup = [:]
        unsupportedCommandsByTargetID = [:]
    }

    package func reset() {
        selectedContextID = nil
        executionContextsByID.removeAll()
        normalContextIDByTargetID.removeAll()
        remoteObjectsByID.removeAll()
        objectGroupRuntimeAgentTargetsByGroup.removeAll()
        unsupportedCommandsByTargetID.removeAll()
    }

    package func snapshot() -> RuntimeSessionSnapshot {
        RuntimeSessionSnapshot(
            executionContextsByID: executionContextsByID,
            selectedContextID: selectedContextID,
            normalContextIDByTargetID: normalContextIDByTargetID,
            remoteObjectsByID: remoteObjectsByID,
            objectGroupRuntimeAgentTargetsByGroup: objectGroupRuntimeAgentTargetsByGroup,
            unsupportedCommandsByTargetID: unsupportedCommandsByTargetID
        )
    }

    package func executionContext(for contextID: ExecutionContextID) -> RuntimeExecutionContext? {
        executionContextsByID[contextID]
    }

    package func selectedContext(targetID: ProtocolTargetIdentifier? = nil) -> RuntimeExecutionContext? {
        guard let selectedContextID,
              let context = executionContextsByID[selectedContextID] else {
            return nil
        }
        if let targetID {
            return context.targetID == targetID ? context : nil
        }
        return context
    }

    package func defaultContext(targetID: ProtocolTargetIdentifier) -> RuntimeExecutionContext? {
        guard let contextID = normalContextIDByTargetID[targetID] else {
            return nil
        }
        return executionContextsByID[contextID]
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

    package func applyExecutionContextCreated(_ context: RuntimeExecutionContext) {
        if context.type == .normal,
           let oldContextID = normalContextIDToReplace(with: context),
           oldContextID != context.id {
            executionContextsByID.removeValue(forKey: oldContextID)
            if selectedContextID == oldContextID {
                selectedContextID = nil
            }
        }
        executionContextsByID[context.id] = context
        if context.type == .normal {
            normalContextIDByTargetID[context.targetID] = context.id
        }
        if context.type == .normal,
           selectedContextID == nil {
            selectedContextID = context.id
        }
    }

    package func applyExecutionContextDestroyed(_ contextID: ExecutionContextID) {
        guard let context = executionContextsByID.removeValue(forKey: contextID) else {
            return
        }
        if normalContextIDByTargetID[context.targetID] == contextID {
            normalContextIDByTargetID.removeValue(forKey: context.targetID)
        }
        if selectedContextID == contextID {
            selectedContextID = nil
        }
        releaseRemoteObjects(executionContextID: context.id)
    }

    package func applyExecutionContextsCleared(runtimeAgentTargetID: ProtocolTargetIdentifier) {
        let removedContextIDs = Set(
            executionContextsByID.values
                .filter { $0.runtimeAgentTargetID == runtimeAgentTargetID }
                .map(\.id)
        )
        let removedTargetIDs = Set(removedContextIDs.compactMap { executionContextsByID[$0]?.targetID })
        executionContextsByID = executionContextsByID.filter { $0.value.runtimeAgentTargetID != runtimeAgentTargetID }
        for targetID in removedTargetIDs {
            if let normalContextID = normalContextIDByTargetID[targetID],
               removedContextIDs.contains(normalContextID) {
                normalContextIDByTargetID.removeValue(forKey: targetID)
            }
        }
        if let selectedContextID,
           removedContextIDs.contains(selectedContextID) {
            self.selectedContextID = nil
        }
        releaseRemoteObjects(runtimeAgentTargetID: runtimeAgentTargetID)
    }

    package func selectExecutionContext(_ contextID: ExecutionContextID?) {
        guard let contextID else {
            selectedContextID = nil
            return
        }
        guard executionContextsByID[contextID] != nil else {
            return
        }
        selectedContextID = contextID
    }

    package func applyTargetDestroyed(_ targetID: ProtocolTargetIdentifier) {
        let removedContextIDs = Set(
            executionContextsByID.values
                .filter { $0.targetID == targetID || $0.runtimeAgentTargetID == targetID }
                .map(\.id)
        )
        let removedTargetIDs = Set(removedContextIDs.compactMap { executionContextsByID[$0]?.targetID })
        executionContextsByID = executionContextsByID.filter {
            $0.value.targetID != targetID && $0.value.runtimeAgentTargetID != targetID
        }
        for removedTargetID in removedTargetIDs {
            if let normalContextID = normalContextIDByTargetID[removedTargetID],
               removedContextIDs.contains(normalContextID) {
                normalContextIDByTargetID.removeValue(forKey: removedTargetID)
            }
        }
        releaseRemoteObjects(runtimeAgentTargetID: targetID)
        for contextID in removedContextIDs {
            releaseRemoteObjects(executionContextID: contextID)
        }
        unsupportedCommandsByTargetID.removeValue(forKey: targetID)
        if let selectedContextID,
           removedContextIDs.contains(selectedContextID) {
            self.selectedContextID = nil
        }
    }

    package func applyTargetCommitted(oldTargetID: ProtocolTargetIdentifier?, newTargetID: ProtocolTargetIdentifier) {
        if let oldTargetID {
            for (contextID, context) in executionContextsByID where context.targetID == oldTargetID {
                executionContextsByID[contextID]?.targetID = newTargetID
            }
            for (contextID, context) in executionContextsByID where context.runtimeAgentTargetID == oldTargetID {
                executionContextsByID[contextID]?.runtimeAgentTargetID = newTargetID
            }
            if let normalContextID = normalContextIDByTargetID.removeValue(forKey: oldTargetID) {
                normalContextIDByTargetID[newTargetID] = normalContextID
            }
            var movedObjects: [RuntimeRemoteObjectIdentifierKey: RuntimeRemoteObjectRecord] = [:]
            for (key, record) in remoteObjectsByID where key.runtimeAgentTargetID == oldTargetID {
                let newKey = RuntimeRemoteObjectIdentifierKey(
                    runtimeAgentTargetID: newTargetID,
                    objectID: key.objectID
                )
                movedObjects[newKey] = record
                remoteObjectsByID.removeValue(forKey: key)
            }
            remoteObjectsByID.merge(movedObjects) { _, new in new }
            for group in objectGroupRuntimeAgentTargetsByGroup.keys {
                if objectGroupRuntimeAgentTargetsByGroup[group]?.remove(oldTargetID) != nil {
                    objectGroupRuntimeAgentTargetsByGroup[group]?.insert(newTargetID)
                }
            }
            if let unsupported = unsupportedCommandsByTargetID.removeValue(forKey: oldTargetID) {
                unsupportedCommandsByTargetID[newTargetID, default: []].formUnion(unsupported)
            }
        }
    }

    package func registerRemoteObject(
        _ object: RuntimeRemoteObjectPayload,
        runtimeAgentTargetID: ProtocolTargetIdentifier,
        objectGroup: RuntimeObjectGroup? = nil,
        executionContextID: ExecutionContextID? = nil
    ) {
        if let key = object.identifierKey(runtimeAgentTargetID: runtimeAgentTargetID) {
            let previousGroup = remoteObjectsByID[key]?.objectGroup
            remoteObjectsByID[key] = RuntimeRemoteObjectRecord(
                payload: object,
                objectGroup: objectGroup,
                executionContextID: executionContextID
            )
            if let objectGroup {
                objectGroupRuntimeAgentTargetsByGroup[objectGroup, default: []].insert(runtimeAgentTargetID)
            }
            if let previousGroup,
               previousGroup != objectGroup {
                removeObjectGroupTargetIfEmpty(previousGroup, runtimeAgentTargetID: runtimeAgentTargetID)
            }
        }
    }

    package func applyEvaluationResult(_ result: RuntimeEvaluationResultPayload, request: RuntimeEvaluationRequest) {
        registerRemoteObject(
            result.result,
            runtimeAgentTargetID: request.runtimeAgentTargetID,
            objectGroup: request.objectGroup,
            executionContextID: request.contextID
        )
    }

    package func releaseObject(_ key: RuntimeRemoteObjectIdentifierKey) {
        releaseRemoteObjects { candidateKey, _ in
            candidateKey == key
        }
    }

    package func releaseObjectGroup(_ objectGroup: RuntimeObjectGroup, runtimeAgentTargetID: ProtocolTargetIdentifier) {
        releaseRemoteObjects { key, record in
            key.runtimeAgentTargetID == runtimeAgentTargetID && record.objectGroup == objectGroup
        }
    }

    package func markCommandUnsupported(_ method: String, targetID: ProtocolTargetIdentifier) {
        unsupportedCommandsByTargetID[targetID, default: []].insert(method)
    }

    package func supportsCommand(_ method: String, targetID: ProtocolTargetIdentifier) -> Bool {
        unsupportedCommandsByTargetID[targetID]?.contains(method) != true
    }

    private func releaseRemoteObjects(runtimeAgentTargetID: ProtocolTargetIdentifier) {
        releaseRemoteObjects { key, _ in
            key.runtimeAgentTargetID == runtimeAgentTargetID
        }
    }

    private func releaseRemoteObjects(executionContextID: ExecutionContextID) {
        releaseRemoteObjects { _, record in
            record.executionContextID == executionContextID
        }
    }

    private func releaseRemoteObjects(
        matching shouldRelease: (RuntimeRemoteObjectIdentifierKey, RuntimeRemoteObjectRecord) -> Bool
    ) {
        var releasedKeys: [RuntimeRemoteObjectIdentifierKey] = []
        var affectedTargetsByGroup: [RuntimeObjectGroup: Set<ProtocolTargetIdentifier>] = [:]
        for (key, record) in remoteObjectsByID where shouldRelease(key, record) {
            releasedKeys.append(key)
            if let objectGroup = record.objectGroup {
                affectedTargetsByGroup[objectGroup, default: []].insert(key.runtimeAgentTargetID)
            }
        }
        for key in releasedKeys {
            remoteObjectsByID.removeValue(forKey: key)
        }
        for (objectGroup, runtimeAgentTargetIDs) in affectedTargetsByGroup {
            for runtimeAgentTargetID in runtimeAgentTargetIDs {
                removeObjectGroupTargetIfEmpty(objectGroup, runtimeAgentTargetID: runtimeAgentTargetID)
            }
        }
    }

    private func removeObjectGroupTargetIfEmpty(
        _ objectGroup: RuntimeObjectGroup,
        runtimeAgentTargetID: ProtocolTargetIdentifier
    ) {
        let hasRemainingObject = remoteObjectsByID.contains { key, record in
            key.runtimeAgentTargetID == runtimeAgentTargetID && record.objectGroup == objectGroup
        }
        guard hasRemainingObject == false else {
            return
        }
        objectGroupRuntimeAgentTargetsByGroup[objectGroup]?.remove(runtimeAgentTargetID)
        if objectGroupRuntimeAgentTargetsByGroup[objectGroup]?.isEmpty == true {
            objectGroupRuntimeAgentTargetsByGroup.removeValue(forKey: objectGroup)
        }
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
        objectGroup: RuntimeObjectGroup? = .console
    ) -> RuntimeCommandIntent {
        let context = evaluationContext(targetID: targetID, contextID: contextID)
        return .evaluate(
            RuntimeEvaluationRequest(
                runtimeAgentTargetID: context?.runtimeAgentTargetID ?? targetID,
                expression: expression,
                objectGroup: objectGroup,
                includeCommandLineAPI: true,
                doNotPauseOnExceptionsAndMuteConsole: false,
                contextID: contextID ?? context?.id,
                returnByValue: false,
                generatePreview: true,
                saveResult: true,
                emulateUserGesture: true
            )
        )
    }

    private func evaluationContext(
        targetID: ProtocolTargetIdentifier,
        contextID: ExecutionContextID?
    ) -> RuntimeExecutionContext? {
        if let contextID {
            return executionContextsByID[contextID]
        }
        return selectedContext(targetID: targetID) ?? defaultContext(targetID: targetID)
    }
}
