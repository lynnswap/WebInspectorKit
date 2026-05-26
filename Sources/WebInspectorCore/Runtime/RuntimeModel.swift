import Observation

package struct RuntimeExecutionContextRecord: Equatable, Sendable {
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

@MainActor
@Observable
package final class RuntimeExecutionContext {
    package let id: ExecutionContextID
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

    package convenience init(record: RuntimeExecutionContextRecord) {
        self.init(
            id: record.id,
            targetID: record.targetID,
            runtimeAgentTargetID: record.runtimeAgentTargetID,
            type: record.type,
            name: record.name,
            frameID: record.frameID
        )
    }

    package var key: RuntimeExecutionContextKey {
        RuntimeExecutionContextKey(runtimeAgentTargetID: runtimeAgentTargetID, contextID: id)
    }

    package var snapshotRecord: RuntimeExecutionContextRecord {
        RuntimeExecutionContextRecord(
            id: id,
            targetID: targetID,
            runtimeAgentTargetID: runtimeAgentTargetID,
            type: type,
            name: name,
            frameID: frameID
        )
    }

    func update(from record: RuntimeExecutionContextRecord) {
        targetID = record.targetID
        runtimeAgentTargetID = record.runtimeAgentTargetID
        type = record.type
        name = record.name
        frameID = record.frameID
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

@MainActor
@Observable
package final class RuntimeRemoteObject {
    package let id: RuntimeRemoteObjectIdentifierKey
    package var payload: RuntimeRemoteObjectPayload
    package var objectGroup: RuntimeObjectGroup?
    package var executionContextKey: RuntimeExecutionContextKey?

    package init(
        id: RuntimeRemoteObjectIdentifierKey,
        payload: RuntimeRemoteObjectPayload,
        objectGroup: RuntimeObjectGroup? = nil,
        executionContextKey: RuntimeExecutionContextKey? = nil
    ) {
        self.id = id
        self.payload = payload
        self.objectGroup = objectGroup
        self.executionContextKey = executionContextKey
    }

    package var snapshotRecord: RuntimeRemoteObjectRecord {
        RuntimeRemoteObjectRecord(
            payload: payload,
            objectGroup: objectGroup,
            executionContextKey: executionContextKey
        )
    }
}

package struct RuntimeSessionSnapshot: Equatable, Sendable {
    package var executionContextsByKey: [RuntimeExecutionContextKey: RuntimeExecutionContextRecord]
    package var selectedContextKey: RuntimeExecutionContextKey?
    package var normalContextKeyByTargetID: [ProtocolTargetIdentifier: RuntimeExecutionContextKey]
    package var remoteObjectsByID: [RuntimeRemoteObjectIdentifierKey: RuntimeRemoteObjectRecord]
    package var objectGroupRuntimeAgentTargetsByGroup: [RuntimeObjectGroup: Set<ProtocolTargetIdentifier>]
    package var unsupportedCommandsByTargetID: [ProtocolTargetIdentifier: Set<String>]

    package func executionContext(
        runtimeAgentTargetID: ProtocolTargetIdentifier,
        contextID: ExecutionContextID
    ) -> RuntimeExecutionContextRecord? {
        executionContextsByKey[
            RuntimeExecutionContextKey(runtimeAgentTargetID: runtimeAgentTargetID, contextID: contextID)
        ]
    }

    package func uniqueExecutionContext(contextID: ExecutionContextID) -> RuntimeExecutionContextRecord? {
        let matches = executionContextsByKey.values.filter { $0.id == contextID }
        return matches.count == 1 ? matches[0] : nil
    }
}

@MainActor
@Observable
package final class RuntimeTargetState {
    package let targetID: ProtocolTargetIdentifier
    package var normalContextKey: RuntimeExecutionContextKey?

    package init(targetID: ProtocolTargetIdentifier, normalContextKey: RuntimeExecutionContextKey? = nil) {
        self.targetID = targetID
        self.normalContextKey = normalContextKey
    }
}

@MainActor
@Observable
package final class RuntimeAgentState {
    package let targetID: ProtocolTargetIdentifier
    package private(set) var executionContextsByID: [ExecutionContextID: RuntimeExecutionContext]
    private var remoteObjectsByID: [RuntimeRemoteObjectIdentifier: RuntimeRemoteObject]
    private var unsupportedCommands: Set<String>

    init(targetID: ProtocolTargetIdentifier) {
        self.targetID = targetID
        executionContextsByID = [:]
        remoteObjectsByID = [:]
        unsupportedCommands = []
    }

    package var executionContexts: [RuntimeExecutionContext] {
        executionContextsByID.values.sorted {
            if $0.id == $1.id {
                return $0.targetID.rawValue < $1.targetID.rawValue
            }
            return $0.id.rawValue < $1.id.rawValue
        }
    }

    package var remoteObjects: [RuntimeRemoteObject] {
        remoteObjectsByID.values.sorted {
            $0.id.objectID.rawValue < $1.id.objectID.rawValue
        }
    }

    package var remoteObjectRecords: [RuntimeRemoteObjectIdentifierKey: RuntimeRemoteObjectRecord] {
        remoteObjectsByKey
    }

    var executionContextsByKey: [RuntimeExecutionContextKey: RuntimeExecutionContext] {
        Dictionary(uniqueKeysWithValues: executionContextsByID.values.map { ($0.key, $0) })
    }

    var executionContextRecordsByKey: [RuntimeExecutionContextKey: RuntimeExecutionContextRecord] {
        Dictionary(uniqueKeysWithValues: executionContextsByID.values.map { ($0.key, $0.snapshotRecord) })
    }

    var remoteObjectsByKey: [RuntimeRemoteObjectIdentifierKey: RuntimeRemoteObjectRecord] {
        Dictionary(
            uniqueKeysWithValues: remoteObjectsByID.map { _, remoteObject in
                (remoteObject.id, remoteObject.snapshotRecord)
            }
        )
    }

    func executionContext(contextID: ExecutionContextID) -> RuntimeExecutionContext? {
        executionContextsByID[contextID]
    }

    func recordExecutionContext(_ record: RuntimeExecutionContextRecord) {
        if let context = executionContextsByID[record.id] {
            context.update(from: record)
        } else {
            executionContextsByID[record.id] = RuntimeExecutionContext(record: record)
        }
    }

    func insertExecutionContext(_ context: RuntimeExecutionContext) {
        executionContextsByID[context.id] = context
    }

    func removeExecutionContext(contextID: ExecutionContextID) -> RuntimeExecutionContext? {
        executionContextsByID.removeValue(forKey: contextID)
    }

    func registerRemoteObject(
        _ object: RuntimeRemoteObjectPayload,
        objectGroup: RuntimeObjectGroup?,
        executionContextID: ExecutionContextID?
    ) {
        guard let objectID = object.objectID else {
            return
        }
        let objectKey = RuntimeRemoteObjectIdentifierKey(runtimeAgentTargetID: targetID, objectID: objectID)
        let executionContextKey = executionContextID.map {
            RuntimeExecutionContextKey(runtimeAgentTargetID: targetID, contextID: $0)
        }
        if let remoteObject = remoteObjectsByID[objectID] {
            remoteObject.payload = object
            remoteObject.objectGroup = objectGroup
            remoteObject.executionContextKey = executionContextKey
        } else {
            remoteObjectsByID[objectID] = RuntimeRemoteObject(
                id: objectKey,
                payload: object,
                objectGroup: objectGroup,
                executionContextKey: executionContextKey
            )
        }
    }

    func releaseRemoteObjects(executionContextKey: RuntimeExecutionContextKey) {
        releaseRemoteObjects { _, record in
            record.executionContextKey == executionContextKey
        }
    }

    func releaseRemoteObjects(objectGroup: RuntimeObjectGroup) {
        releaseRemoteObjects { _, record in
            record.objectGroup == objectGroup
        }
    }

    func releaseRemoteObject(_ objectID: RuntimeRemoteObjectIdentifier) {
        remoteObjectsByID.removeValue(forKey: objectID)
    }

    func clearExecutionContexts() {
        executionContextsByID.removeAll()
    }

    func clearRemoteObjects() {
        remoteObjectsByID.removeAll()
    }

    func markCommandUnsupported(_ method: String) {
        unsupportedCommands.insert(method)
    }

    func mergeUnsupportedCommands(_ methods: Set<String>) {
        unsupportedCommands.formUnion(methods)
    }

    func supportsCommand(_ method: String) -> Bool {
        unsupportedCommands.contains(method) == false
    }

    fileprivate var unsupportedCommandSnapshot: Set<String> {
        unsupportedCommands
    }

    private func releaseRemoteObjects(
        matching shouldRelease: (RuntimeRemoteObjectIdentifier, RuntimeRemoteObjectRecord) -> Bool
    ) {
        let releasedObjectIDs = remoteObjectsByID
            .filter { shouldRelease($0.key, $0.value.snapshotRecord) }
            .map(\.key)
        for objectID in releasedObjectIDs {
            remoteObjectsByID.removeValue(forKey: objectID)
        }
    }
}

@MainActor
@Observable
package final class RuntimeSession {
    package private(set) var selectedContextKey: RuntimeExecutionContextKey?

    private var targetStatesByID: [ProtocolTargetIdentifier: RuntimeTargetState]
    private var runtimeAgentStatesByID: [ProtocolTargetIdentifier: RuntimeAgentState]

    package init() {
        selectedContextKey = nil
        targetStatesByID = [:]
        runtimeAgentStatesByID = [:]
    }

    package func reset() {
        selectedContextKey = nil
        targetStatesByID.removeAll()
        runtimeAgentStatesByID.removeAll()
    }

    package func snapshot() -> RuntimeSessionSnapshot {
        let remoteObjectsByID = remoteObjectsByID
        return RuntimeSessionSnapshot(
            executionContextsByKey: executionContextRecordsByKey,
            selectedContextKey: selectedContextKey,
            normalContextKeyByTargetID: normalContextKeyByTargetID,
            remoteObjectsByID: remoteObjectsByID,
            objectGroupRuntimeAgentTargetsByGroup: Self.objectGroupRuntimeAgentTargets(from: remoteObjectsByID),
            unsupportedCommandsByTargetID: unsupportedCommandsByTargetID
        )
    }

    package func executionContext(for key: RuntimeExecutionContextKey) -> RuntimeExecutionContext? {
        runtimeAgentStatesByID[key.runtimeAgentTargetID]?.executionContext(contextID: key.contextID)
    }

    package var targetStates: [RuntimeTargetState] {
        targetStatesByID.values.sorted { $0.targetID.rawValue < $1.targetID.rawValue }
    }

    package var runtimeAgentStates: [RuntimeAgentState] {
        runtimeAgentStatesByID.values.sorted { $0.targetID.rawValue < $1.targetID.rawValue }
    }

    package func targetState(for targetID: ProtocolTargetIdentifier) -> RuntimeTargetState? {
        targetStatesByID[targetID]
    }

    package func runtimeAgentState(for targetID: ProtocolTargetIdentifier) -> RuntimeAgentState? {
        runtimeAgentStatesByID[targetID]
    }

    package func selectedContext(targetID: ProtocolTargetIdentifier? = nil) -> RuntimeExecutionContext? {
        guard let selectedContextKey,
              let context = executionContext(for: selectedContextKey) else {
            return nil
        }
        if let targetID {
            return context.targetID == targetID ? context : nil
        }
        return context
    }

    package func defaultContext(targetID: ProtocolTargetIdentifier) -> RuntimeExecutionContext? {
        guard let contextKey = targetStatesByID[targetID]?.normalContextKey else {
            return nil
        }
        return executionContext(for: contextKey)
    }

    package func applyExecutionContextCreated(_ payload: RuntimeExecutionContextPayload, targetID: ProtocolTargetIdentifier) {
        let type = payload.type ?? .normal
        let record = RuntimeExecutionContextRecord(
            id: payload.id,
            targetID: targetID,
            type: type,
            name: payload.name ?? "",
            frameID: payload.frameID
        )
        applyExecutionContextCreated(record)
    }

    package func applyExecutionContextCreated(_ record: RuntimeExecutionContextRecord) {
        let oldContextKeys = record.type == .normal ? normalContextKeysToReplace(with: record) : []
        if oldContextKeys.isEmpty == false {
            for oldContextKey in oldContextKeys {
                removeExecutionContext(oldContextKey, releaseRemoteObjects: true)
            }
            if let selectedContextKey,
               oldContextKeys.contains(selectedContextKey) {
                self.selectedContextKey = nil
            }
        }
        let agentState = ensureRuntimeAgentState(for: record.runtimeAgentTargetID)
        agentState.recordExecutionContext(record)
        storeRuntimeAgentState(agentState)
        if record.type == .normal {
            let targetState = ensureTargetState(for: record.targetID)
            if let defaultContextKey = targetState.normalContextKey {
                if oldContextKeys.contains(defaultContextKey) {
                    targetState.normalContextKey = record.key
                }
            } else {
                targetState.normalContextKey = record.key
            }
        }
        if record.type == .normal,
           selectedContextKey == nil {
            selectedContextKey = record.key
        }
    }

    package func applyExecutionContextDestroyed(_ contextKey: RuntimeExecutionContextKey) {
        guard let context = removeExecutionContext(contextKey, releaseRemoteObjects: true) else {
            return
        }
        if targetStatesByID[context.targetID]?.normalContextKey == contextKey {
            targetStatesByID[context.targetID]?.normalContextKey = nil
        }
        if selectedContextKey == contextKey {
            selectedContextKey = nil
        }
    }

    package func applyExecutionContextsCleared(runtimeAgentTargetID: ProtocolTargetIdentifier) {
        guard let agentState = runtimeAgentStatesByID[runtimeAgentTargetID] else {
            return
        }
        let removedContexts = Array(agentState.executionContextsByID.values)
        let removedContextKeys = Set(removedContexts.map(\.key))
        let removedTargetIDs = Set(removedContexts.map(\.targetID))
        agentState.clearExecutionContexts()
        agentState.clearRemoteObjects()
        storeRuntimeAgentState(agentState)
        for targetID in removedTargetIDs {
            if let normalContextKey = targetStatesByID[targetID]?.normalContextKey,
               removedContextKeys.contains(normalContextKey) {
                targetStatesByID[targetID]?.normalContextKey = nil
            }
        }
        if let selectedContextKey,
           removedContextKeys.contains(selectedContextKey) {
            self.selectedContextKey = nil
        }
    }

    package func selectExecutionContext(_ contextKey: RuntimeExecutionContextKey?) {
        guard let contextKey else {
            selectedContextKey = nil
            return
        }
        guard executionContext(for: contextKey) != nil else {
            return
        }
        selectedContextKey = contextKey
    }

    package func applyTargetDestroyed(_ targetID: ProtocolTargetIdentifier) {
        var removedContexts: [RuntimeExecutionContext] = []
        if let removedAgent = runtimeAgentStatesByID.removeValue(forKey: targetID) {
            removedContexts.append(contentsOf: removedAgent.executionContextsByID.values)
        }
        for agentID in Array(runtimeAgentStatesByID.keys) {
            guard let agentState = runtimeAgentStatesByID[agentID] else {
                continue
            }
            let contextIDs = agentState.executionContextsByID.values
                .filter { $0.targetID == targetID }
                .map(\.id)
            guard contextIDs.isEmpty == false else {
                continue
            }
            for contextID in contextIDs {
                if let context = agentState.removeExecutionContext(contextID: contextID) {
                    removedContexts.append(context)
                    agentState.releaseRemoteObjects(executionContextKey: context.key)
                }
            }
            storeRuntimeAgentState(agentState)
        }
        let removedContextKeys = Set(removedContexts.map(\.key))
        let removedTargetIDs = Set(removedContexts.map(\.targetID))
        for removedTargetID in removedTargetIDs {
            if let normalContextKey = targetStatesByID[removedTargetID]?.normalContextKey,
               removedContextKeys.contains(normalContextKey) {
                targetStatesByID[removedTargetID]?.normalContextKey = nil
            }
        }
        targetStatesByID.removeValue(forKey: targetID)
        if let selectedContextKey,
           removedContextKeys.contains(selectedContextKey) {
            self.selectedContextKey = nil
        }
    }

    package func applyTargetCommitted(oldTargetID: ProtocolTargetIdentifier?, newTargetID: ProtocolTargetIdentifier) {
        if let oldTargetID {
            let movedContextKeys = retargetExecutionContexts(from: oldTargetID, to: newTargetID)
            for targetState in targetStatesByID.values {
                guard let normalContextKey = targetState.normalContextKey,
                      let movedKey = movedContextKeys[normalContextKey] else {
                    continue
                }
                targetState.normalContextKey = movedKey
            }
            if let oldTargetState = targetStatesByID.removeValue(forKey: oldTargetID) {
                let newTargetState = ensureTargetState(for: newTargetID)
                if newTargetState.normalContextKey == nil,
                   let normalContextKey = oldTargetState.normalContextKey {
                    newTargetState.normalContextKey = movedContextKeys[normalContextKey] ?? normalContextKey
                }
            }
            if let selectedContextKey,
               let movedKey = movedContextKeys[selectedContextKey] {
                self.selectedContextKey = movedKey
            }
            if let oldAgentState = runtimeAgentStatesByID.removeValue(forKey: oldTargetID),
               oldAgentState.unsupportedCommandSnapshot.isEmpty == false {
                let newAgentState = ensureRuntimeAgentState(for: newTargetID)
                newAgentState.mergeUnsupportedCommands(oldAgentState.unsupportedCommandSnapshot)
                storeRuntimeAgentState(newAgentState)
            }
        }
    }

    package func registerRemoteObject(
        _ object: RuntimeRemoteObjectPayload,
        runtimeAgentTargetID: ProtocolTargetIdentifier,
        objectGroup: RuntimeObjectGroup? = nil,
        executionContextID: ExecutionContextID? = nil
    ) {
        let agentState = ensureRuntimeAgentState(for: runtimeAgentTargetID)
        agentState.registerRemoteObject(
            object,
            objectGroup: objectGroup,
            executionContextID: executionContextID
        )
        storeRuntimeAgentState(agentState)
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
        guard let agentState = runtimeAgentStatesByID[key.runtimeAgentTargetID] else {
            return
        }
        agentState.releaseRemoteObject(key.objectID)
        storeRuntimeAgentState(agentState)
    }

    package func releaseObjectGroup(_ objectGroup: RuntimeObjectGroup, runtimeAgentTargetID: ProtocolTargetIdentifier) {
        guard let agentState = runtimeAgentStatesByID[runtimeAgentTargetID] else {
            return
        }
        agentState.releaseRemoteObjects(objectGroup: objectGroup)
        storeRuntimeAgentState(agentState)
    }

    package func markCommandUnsupported(_ method: String, targetID: ProtocolTargetIdentifier) {
        let agentState = ensureRuntimeAgentState(for: targetID)
        agentState.markCommandUnsupported(method)
        storeRuntimeAgentState(agentState)
    }

    package func supportsCommand(_ method: String, targetID: ProtocolTargetIdentifier) -> Bool {
        runtimeAgentStatesByID[targetID]?.supportsCommand(method) ?? true
    }

    private var executionContextsByKey: [RuntimeExecutionContextKey: RuntimeExecutionContext] {
        Dictionary(
            uniqueKeysWithValues: runtimeAgentStatesByID.values.flatMap { state in
                state.executionContextsByKey.map { ($0.key, $0.value) }
            }
        )
    }

    private var executionContextRecordsByKey: [RuntimeExecutionContextKey: RuntimeExecutionContextRecord] {
        Dictionary(
            uniqueKeysWithValues: runtimeAgentStatesByID.values.flatMap { state in
                state.executionContextRecordsByKey.map { ($0.key, $0.value) }
            }
        )
    }

    private var normalContextKeyByTargetID: [ProtocolTargetIdentifier: RuntimeExecutionContextKey] {
        Dictionary(
            uniqueKeysWithValues: targetStatesByID.values.compactMap { state in
                state.normalContextKey.map { (state.targetID, $0) }
            }
        )
    }

    private var remoteObjectsByID: [RuntimeRemoteObjectIdentifierKey: RuntimeRemoteObjectRecord] {
        Dictionary(
            uniqueKeysWithValues: runtimeAgentStatesByID.values.flatMap { state in
                state.remoteObjectsByKey.map { ($0.key, $0.value) }
            }
        )
    }

    private var unsupportedCommandsByTargetID: [ProtocolTargetIdentifier: Set<String>] {
        Dictionary(
            uniqueKeysWithValues: runtimeAgentStatesByID.values
                .filter { $0.unsupportedCommandSnapshot.isEmpty == false }
                .map { ($0.targetID, $0.unsupportedCommandSnapshot) }
        )
    }

    private func ensureTargetState(for targetID: ProtocolTargetIdentifier) -> RuntimeTargetState {
        if let state = targetStatesByID[targetID] {
            return state
        }
        let state = RuntimeTargetState(targetID: targetID)
        targetStatesByID[targetID] = state
        return state
    }

    private func ensureRuntimeAgentState(for targetID: ProtocolTargetIdentifier) -> RuntimeAgentState {
        if let state = runtimeAgentStatesByID[targetID] {
            return state
        }
        let state = RuntimeAgentState(targetID: targetID)
        runtimeAgentStatesByID[targetID] = state
        return state
    }

    private func storeRuntimeAgentState(_ state: RuntimeAgentState) {
        runtimeAgentStatesByID[state.targetID] = state
    }

    @discardableResult
    private func removeExecutionContext(
        _ contextKey: RuntimeExecutionContextKey,
        releaseRemoteObjects: Bool
    ) -> RuntimeExecutionContext? {
        guard let agentState = runtimeAgentStatesByID[contextKey.runtimeAgentTargetID],
              let context = agentState.removeExecutionContext(contextID: contextKey.contextID) else {
            return nil
        }
        if releaseRemoteObjects {
            agentState.releaseRemoteObjects(executionContextKey: contextKey)
        }
        storeRuntimeAgentState(agentState)
        return context
    }

    private func retargetExecutionContexts(
        from oldTargetID: ProtocolTargetIdentifier,
        to newTargetID: ProtocolTargetIdentifier
    ) -> [RuntimeExecutionContextKey: RuntimeExecutionContextKey] {
        var movedContextKeys: [RuntimeExecutionContextKey: RuntimeExecutionContextKey] = [:]
        let currentContexts = runtimeAgentStatesByID.values.flatMap { state in
            state.executionContexts.map { (runtimeAgentTargetID: state.targetID, context: $0) }
        }

        for entry in currentContexts {
            guard let sourceAgentState = runtimeAgentStatesByID[entry.runtimeAgentTargetID],
                  sourceAgentState.executionContext(contextID: entry.context.id) === entry.context else {
                continue
            }

            let oldKey = entry.context.key
            var nextTargetID = entry.context.targetID
            var nextRuntimeAgentTargetID = entry.context.runtimeAgentTargetID
            if nextTargetID == oldTargetID {
                nextTargetID = newTargetID
            }
            if nextRuntimeAgentTargetID == oldTargetID {
                nextRuntimeAgentTargetID = newTargetID
            }
            guard nextTargetID != entry.context.targetID
                    || nextRuntimeAgentTargetID != entry.context.runtimeAgentTargetID else {
                continue
            }

            let nextKey = RuntimeExecutionContextKey(
                runtimeAgentTargetID: nextRuntimeAgentTargetID,
                contextID: entry.context.id
            )
            guard sourceAgentState.removeExecutionContext(contextID: entry.context.id) != nil else {
                continue
            }
            storeRuntimeAgentState(sourceAgentState)
            movedContextKeys[oldKey] = nextKey

            if let destinationAgentState = runtimeAgentStatesByID[nextRuntimeAgentTargetID],
               destinationAgentState.executionContext(contextID: entry.context.id) != nil {
                continue
            }

            entry.context.targetID = nextTargetID
            entry.context.runtimeAgentTargetID = nextRuntimeAgentTargetID
            let destinationAgentState = ensureRuntimeAgentState(for: nextRuntimeAgentTargetID)
            destinationAgentState.insertExecutionContext(entry.context)
            storeRuntimeAgentState(destinationAgentState)
        }

        return movedContextKeys
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

    private func normalContextKeysToReplace(with record: RuntimeExecutionContextRecord) -> Set<RuntimeExecutionContextKey> {
        guard let agentState = runtimeAgentStatesByID[record.runtimeAgentTargetID] else {
            return []
        }
        let replacementKeys = agentState.executionContextsByID.values
            .filter {
                $0.type == .normal
                    && $0.targetID == record.targetID
                    && $0.runtimeAgentTargetID == record.runtimeAgentTargetID
                    && $0.frameID == record.frameID
                    && $0.name == record.name
                    && $0.key != record.key
            }
            .map(\.key)
        return Set(replacementKeys)
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
