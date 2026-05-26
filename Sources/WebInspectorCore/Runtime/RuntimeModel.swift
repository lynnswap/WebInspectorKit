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

    package var key: RuntimeExecutionContextKey {
        RuntimeExecutionContextKey(runtimeAgentTargetID: runtimeAgentTargetID, contextID: id)
    }
}

package struct RuntimeRemoteObjectRecord: Equatable, Sendable {
    package var payload: RuntimeRemoteObjectPayload
    package var objectGroup: RuntimeObjectGroup?
    package var executionContextKey: RuntimeExecutionContextKey?

    package init(
        payload: RuntimeRemoteObjectPayload,
        objectGroup: RuntimeObjectGroup? = nil,
        executionContextKey: RuntimeExecutionContextKey? = nil
    ) {
        self.payload = payload
        self.objectGroup = objectGroup
        self.executionContextKey = executionContextKey
    }
}

package struct RuntimeSessionSnapshot: Equatable, Sendable {
    package var executionContextsByKey: [RuntimeExecutionContextKey: RuntimeExecutionContext]
    package var selectedContextKey: RuntimeExecutionContextKey?
    package var normalContextKeyByTargetID: [ProtocolTargetIdentifier: RuntimeExecutionContextKey]
    package var remoteObjectsByID: [RuntimeRemoteObjectIdentifierKey: RuntimeRemoteObjectRecord]
    package var objectGroupRuntimeAgentTargetsByGroup: [RuntimeObjectGroup: Set<ProtocolTargetIdentifier>]
    package var unsupportedCommandsByTargetID: [ProtocolTargetIdentifier: Set<String>]

    package func executionContext(
        runtimeAgentTargetID: ProtocolTargetIdentifier,
        contextID: ExecutionContextID
    ) -> RuntimeExecutionContext? {
        executionContextsByKey[
            RuntimeExecutionContextKey(runtimeAgentTargetID: runtimeAgentTargetID, contextID: contextID)
        ]
    }

    package func uniqueExecutionContext(contextID: ExecutionContextID) -> RuntimeExecutionContext? {
        let matches = executionContextsByKey.values.filter { $0.id == contextID }
        return matches.count == 1 ? matches[0] : nil
    }
}

@MainActor
@Observable
package final class RuntimeSession {
    package private(set) var selectedContextKey: RuntimeExecutionContextKey?

    private var executionContextsByKey: [RuntimeExecutionContextKey: RuntimeExecutionContext]
    private var normalContextKeyByTargetID: [ProtocolTargetIdentifier: RuntimeExecutionContextKey]
    private var remoteObjectsByID: [RuntimeRemoteObjectIdentifierKey: RuntimeRemoteObjectRecord]
    private var unsupportedCommandsByTargetID: [ProtocolTargetIdentifier: Set<String>]

    package init() {
        selectedContextKey = nil
        executionContextsByKey = [:]
        normalContextKeyByTargetID = [:]
        remoteObjectsByID = [:]
        unsupportedCommandsByTargetID = [:]
    }

    package func reset() {
        selectedContextKey = nil
        executionContextsByKey.removeAll()
        normalContextKeyByTargetID.removeAll()
        remoteObjectsByID.removeAll()
        unsupportedCommandsByTargetID.removeAll()
    }

    package func snapshot() -> RuntimeSessionSnapshot {
        RuntimeSessionSnapshot(
            executionContextsByKey: executionContextsByKey,
            selectedContextKey: selectedContextKey,
            normalContextKeyByTargetID: normalContextKeyByTargetID,
            remoteObjectsByID: remoteObjectsByID,
            objectGroupRuntimeAgentTargetsByGroup: Self.objectGroupRuntimeAgentTargets(from: remoteObjectsByID),
            unsupportedCommandsByTargetID: unsupportedCommandsByTargetID
        )
    }

    package func executionContext(for key: RuntimeExecutionContextKey) -> RuntimeExecutionContext? {
        executionContextsByKey[key]
    }

    package func selectedContext(targetID: ProtocolTargetIdentifier? = nil) -> RuntimeExecutionContext? {
        guard let selectedContextKey,
              let context = executionContextsByKey[selectedContextKey] else {
            return nil
        }
        if let targetID {
            return context.targetID == targetID ? context : nil
        }
        return context
    }

    package func defaultContext(targetID: ProtocolTargetIdentifier) -> RuntimeExecutionContext? {
        guard let contextKey = normalContextKeyByTargetID[targetID] else {
            return nil
        }
        return executionContextsByKey[contextKey]
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
        let oldContextKeys = context.type == .normal ? normalContextKeysToReplace(with: context) : []
        if oldContextKeys.isEmpty == false {
            for oldContextKey in oldContextKeys {
                releaseRemoteObjects(executionContextKey: oldContextKey)
                executionContextsByKey.removeValue(forKey: oldContextKey)
            }
            if let selectedContextKey,
               oldContextKeys.contains(selectedContextKey) {
                self.selectedContextKey = nil
            }
        }
        executionContextsByKey[context.key] = context
        if context.type == .normal {
            if let defaultContextKey = normalContextKeyByTargetID[context.targetID] {
                if oldContextKeys.contains(defaultContextKey) {
                    normalContextKeyByTargetID[context.targetID] = context.key
                }
            } else {
                normalContextKeyByTargetID[context.targetID] = context.key
            }
        }
        if context.type == .normal,
           selectedContextKey == nil {
            selectedContextKey = context.key
        }
    }

    package func applyExecutionContextDestroyed(_ contextKey: RuntimeExecutionContextKey) {
        guard let context = executionContextsByKey.removeValue(forKey: contextKey) else {
            return
        }
        if normalContextKeyByTargetID[context.targetID] == contextKey {
            normalContextKeyByTargetID.removeValue(forKey: context.targetID)
        }
        if selectedContextKey == contextKey {
            selectedContextKey = nil
        }
        releaseRemoteObjects(executionContextKey: contextKey)
    }

    package func applyExecutionContextsCleared(runtimeAgentTargetID: ProtocolTargetIdentifier) {
        let removedContextKeys = Set(
            executionContextsByKey
                .filter { $0.key.runtimeAgentTargetID == runtimeAgentTargetID }
                .map(\.key)
        )
        let removedTargetIDs = Set(removedContextKeys.compactMap { executionContextsByKey[$0]?.targetID })
        executionContextsByKey = executionContextsByKey.filter { $0.key.runtimeAgentTargetID != runtimeAgentTargetID }
        for targetID in removedTargetIDs {
            if let normalContextKey = normalContextKeyByTargetID[targetID],
               removedContextKeys.contains(normalContextKey) {
                normalContextKeyByTargetID.removeValue(forKey: targetID)
            }
        }
        if let selectedContextKey,
           removedContextKeys.contains(selectedContextKey) {
            self.selectedContextKey = nil
        }
        releaseRemoteObjects(runtimeAgentTargetID: runtimeAgentTargetID)
    }

    package func selectExecutionContext(_ contextKey: RuntimeExecutionContextKey?) {
        guard let contextKey else {
            selectedContextKey = nil
            return
        }
        guard executionContextsByKey[contextKey] != nil else {
            return
        }
        selectedContextKey = contextKey
    }

    package func applyTargetDestroyed(_ targetID: ProtocolTargetIdentifier) {
        let removedContextKeys = Set(
            executionContextsByKey
                .filter { $0.value.targetID == targetID || $0.value.runtimeAgentTargetID == targetID }
                .map(\.key)
        )
        let removedTargetIDs = Set(removedContextKeys.compactMap { executionContextsByKey[$0]?.targetID })
        executionContextsByKey = executionContextsByKey.filter {
            $0.value.targetID != targetID && $0.value.runtimeAgentTargetID != targetID
        }
        for removedTargetID in removedTargetIDs {
            if let normalContextKey = normalContextKeyByTargetID[removedTargetID],
               removedContextKeys.contains(normalContextKey) {
                normalContextKeyByTargetID.removeValue(forKey: removedTargetID)
            }
        }
        releaseRemoteObjects(runtimeAgentTargetID: targetID)
        for contextKey in removedContextKeys {
            releaseRemoteObjects(executionContextKey: contextKey)
        }
        unsupportedCommandsByTargetID.removeValue(forKey: targetID)
        if let selectedContextKey,
           removedContextKeys.contains(selectedContextKey) {
            self.selectedContextKey = nil
        }
    }

    package func applyTargetCommitted(oldTargetID: ProtocolTargetIdentifier?, newTargetID: ProtocolTargetIdentifier) {
        if let oldTargetID {
            var movedKeys: [RuntimeExecutionContextKey: RuntimeExecutionContextKey] = [:]
            for (contextKey, context) in Array(executionContextsByKey) {
                var movedContext = context
                if movedContext.targetID == oldTargetID {
                    movedContext.targetID = newTargetID
                }
                if movedContext.runtimeAgentTargetID == oldTargetID {
                    movedContext.runtimeAgentTargetID = newTargetID
                }
                guard movedContext != context else {
                    continue
                }
                executionContextsByKey.removeValue(forKey: contextKey)
                executionContextsByKey[movedContext.key] = movedContext
                movedKeys[contextKey] = movedContext.key
            }
            for (targetID, contextKey) in Array(normalContextKeyByTargetID) {
                if let movedKey = movedKeys[contextKey] {
                    normalContextKeyByTargetID[targetID] = movedKey
                }
            }
            if let normalContextKey = normalContextKeyByTargetID.removeValue(forKey: oldTargetID) {
                normalContextKeyByTargetID[newTargetID] = movedKeys[normalContextKey] ?? normalContextKey
            }
            if let selectedContextKey,
               let movedKey = movedKeys[selectedContextKey] {
                self.selectedContextKey = movedKey
            }
            releaseRemoteObjects(runtimeAgentTargetID: oldTargetID)
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
            remoteObjectsByID[key] = RuntimeRemoteObjectRecord(
                payload: object,
                objectGroup: objectGroup,
                executionContextKey: executionContextID.map {
                    RuntimeExecutionContextKey(runtimeAgentTargetID: runtimeAgentTargetID, contextID: $0)
                }
            )
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

    private func releaseRemoteObjects(executionContextKey: RuntimeExecutionContextKey) {
        releaseRemoteObjects { _, record in
            record.executionContextKey == executionContextKey
        }
    }

    private func releaseRemoteObjects(
        matching shouldRelease: (RuntimeRemoteObjectIdentifierKey, RuntimeRemoteObjectRecord) -> Bool
    ) {
        var releasedKeys: [RuntimeRemoteObjectIdentifierKey] = []
        for (key, record) in remoteObjectsByID where shouldRelease(key, record) {
            releasedKeys.append(key)
        }
        for key in releasedKeys {
            remoteObjectsByID.removeValue(forKey: key)
        }
    }

    private static func objectGroupRuntimeAgentTargets(
        from remoteObjectsByID: [RuntimeRemoteObjectIdentifierKey: RuntimeRemoteObjectRecord]
    ) -> [RuntimeObjectGroup: Set<ProtocolTargetIdentifier>] {
        var targetsByGroup: [RuntimeObjectGroup: Set<ProtocolTargetIdentifier>] = [:]
        for (key, record) in remoteObjectsByID {
            if let objectGroup = record.objectGroup {
                targetsByGroup[objectGroup, default: []].insert(key.runtimeAgentTargetID)
            }
        }
        return targetsByGroup
    }

    private func normalContextKeysToReplace(with context: RuntimeExecutionContext) -> Set<RuntimeExecutionContextKey> {
        Set(
            executionContextsByKey.values
                .filter {
                    $0.type == .normal
                        && $0.targetID == context.targetID
                        && $0.runtimeAgentTargetID == context.runtimeAgentTargetID
                        && $0.frameID == context.frameID
                        && $0.name == context.name
                        && $0.key != context.key
                }
                .map(\.key)
        )
    }

    package func enableIntent(targetID: ProtocolTargetIdentifier) -> RuntimeCommandIntent {
        .enable(targetID: targetID)
    }

    package func evaluateIntent(
        expression: String,
        targetID: ProtocolTargetIdentifier,
        contextKey: RuntimeExecutionContextKey? = nil,
        objectGroup: RuntimeObjectGroup? = .console
    ) -> RuntimeCommandIntent {
        let context = evaluationContext(targetID: targetID, contextKey: contextKey)
        return .evaluate(
            RuntimeEvaluationRequest(
                runtimeAgentTargetID: context?.runtimeAgentTargetID ?? targetID,
                expression: expression,
                objectGroup: objectGroup,
                includeCommandLineAPI: true,
                doNotPauseOnExceptionsAndMuteConsole: false,
                contextID: context?.id,
                returnByValue: false,
                generatePreview: true,
                saveResult: true,
                emulateUserGesture: true
            )
        )
    }

    private func evaluationContext(
        targetID: ProtocolTargetIdentifier,
        contextKey: RuntimeExecutionContextKey?
    ) -> RuntimeExecutionContext? {
        if let contextKey {
            return executionContextsByKey[contextKey]
        }
        return selectedContext(targetID: targetID) ?? defaultContext(targetID: targetID)
    }
}
