import Observation
import WebInspectorTransport

@MainActor
@Observable
package final class RuntimeExecutionContext {
    package let id: ExecutionContextID
    package var targetID: ProtocolTarget.ID
    package var runtimeAgentTargetID: ProtocolTarget.ID
    package var type: RuntimeExecutionContextType
    package var name: String
    package var frameID: DOMFrame.ID?

    package init(
        id: ExecutionContextID,
        targetID: ProtocolTarget.ID,
        runtimeAgentTargetID: ProtocolTarget.ID? = nil,
        type: RuntimeExecutionContextType = .normal,
        name: String = "",
        frameID: DOMFrame.ID? = nil
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
    package let remoteObjectKey: RuntimeRemoteObjectIdentifierKey?
    package var payload: RuntimeRemoteObjectPayload
    package var objectGroup: RuntimeObjectGroup?
    package var executionContextKey: RuntimeExecutionContextKey?

    package init(
        remoteObjectKey: RuntimeRemoteObjectIdentifierKey? = nil,
        payload: RuntimeRemoteObjectPayload,
        objectGroup: RuntimeObjectGroup? = nil,
        executionContextKey: RuntimeExecutionContextKey? = nil
    ) {
        self.remoteObjectKey = remoteObjectKey
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

package struct RuntimeStateSnapshot: Equatable, Sendable {
    package var executionContextsByKey: [RuntimeExecutionContextKey: RuntimeExecutionContextRecord]
    package var selectedContextKey: RuntimeExecutionContextKey?
    package var normalContextKeyByTargetID: [ProtocolTarget.ID: RuntimeExecutionContextKey]
    package var remoteObjectsByID: [RuntimeRemoteObjectIdentifierKey: RuntimeRemoteObjectRecord]
    package var objectGroupRuntimeAgentTargetsByGroup: [RuntimeObjectGroup: Set<ProtocolTarget.ID>]
    package var unsupportedCommandsByTargetID: [ProtocolTarget.ID: Set<String>]

    package func executionContext(
        runtimeAgentTargetID: ProtocolTarget.ID,
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
    package let targetID: ProtocolTarget.ID
    package var frameID: DOMFrame.ID?
    package var normalContextKey: RuntimeExecutionContextKey?

    package init(
        targetID: ProtocolTarget.ID,
        frameID: DOMFrame.ID? = nil,
        normalContextKey: RuntimeExecutionContextKey? = nil
    ) {
        self.targetID = targetID
        self.frameID = frameID
        self.normalContextKey = normalContextKey
    }
}

@MainActor
@Observable
package final class RuntimeAgentState {
    package let targetID: ProtocolTarget.ID
    package private(set) var executionContextsByID: [ExecutionContextID: RuntimeExecutionContext]
    private var remoteObjectsByID: [RuntimeRemoteObjectIdentifier: RuntimeRemoteObject]
    private var unsupportedCommands: Set<String>

    init(targetID: ProtocolTarget.ID) {
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
            ($0.remoteObjectKey?.objectID.rawValue ?? "") < ($1.remoteObjectKey?.objectID.rawValue ?? "")
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
            uniqueKeysWithValues: remoteObjectsByID.map { objectID, remoteObject in
                (
                    RuntimeRemoteObjectIdentifierKey(runtimeAgentTargetID: targetID, objectID: objectID),
                    remoteObject.snapshotRecord
                )
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

    @discardableResult
    func registerRemoteObject(
        _ object: RuntimeRemoteObjectPayload,
        objectGroup: RuntimeObjectGroup?,
        executionContextID: ExecutionContextID?
    ) -> RuntimeRemoteObject {
        let executionContextKey = executionContextID.map {
            RuntimeExecutionContextKey(runtimeAgentTargetID: targetID, contextID: $0)
        }
        guard let objectID = object.objectID else {
            return RuntimeRemoteObject(
                payload: object,
                objectGroup: objectGroup,
                executionContextKey: executionContextKey
            )
        }
        let objectKey = RuntimeRemoteObjectIdentifierKey(runtimeAgentTargetID: targetID, objectID: objectID)
        if let remoteObject = remoteObjectsByID[objectID] {
            remoteObject.payload = object
            remoteObject.objectGroup = objectGroup
            remoteObject.executionContextKey = executionContextKey
            return remoteObject
        } else {
            let remoteObject = RuntimeRemoteObject(
                remoteObjectKey: objectKey,
                payload: object,
                objectGroup: objectGroup,
                executionContextKey: executionContextKey
            )
            remoteObjectsByID[objectID] = remoteObject
            return remoteObject
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

private struct RuntimeTargetSlot {
    // Target projection and runtime-agent state share the target id namespace but keep independent lifetimes.
    var targetState: RuntimeTargetState?
    var agentState: RuntimeAgentState?

    var isEmpty: Bool {
        targetState == nil && agentState == nil
    }
}

@MainActor
private struct RuntimeTargetRegistry {
    private var slotsByTargetID: [ProtocolTarget.ID: RuntimeTargetSlot] = [:]

    var targetStates: [RuntimeTargetState] {
        slotsByTargetID.values.compactMap(\.targetState).sorted { $0.targetID.rawValue < $1.targetID.rawValue }
    }

    var runtimeAgentStates: [RuntimeAgentState] {
        slotsByTargetID.values.compactMap(\.agentState).sorted { $0.targetID.rawValue < $1.targetID.rawValue }
    }

    var targetIDs: [ProtocolTarget.ID] {
        Array(slotsByTargetID.keys)
    }

    mutating func removeAll() {
        slotsByTargetID.removeAll()
    }

    func targetState(for targetID: ProtocolTarget.ID) -> RuntimeTargetState? {
        slotsByTargetID[targetID]?.targetState
    }

    func runtimeAgentState(for targetID: ProtocolTarget.ID) -> RuntimeAgentState? {
        slotsByTargetID[targetID]?.agentState
    }

    mutating func ensureTargetState(for targetID: ProtocolTarget.ID) -> RuntimeTargetState {
        if let state = targetState(for: targetID) {
            return state
        }
        let state = RuntimeTargetState(targetID: targetID)
        var slot = slotsByTargetID[targetID] ?? RuntimeTargetSlot()
        slot.targetState = state
        slotsByTargetID[targetID] = slot
        return state
    }

    mutating func ensureRuntimeAgentState(for targetID: ProtocolTarget.ID) -> RuntimeAgentState {
        if let state = runtimeAgentState(for: targetID) {
            return state
        }
        let state = RuntimeAgentState(targetID: targetID)
        var slot = slotsByTargetID[targetID] ?? RuntimeTargetSlot()
        slot.agentState = state
        slotsByTargetID[targetID] = slot
        return state
    }

    @discardableResult
    mutating func removeTargetState(for targetID: ProtocolTarget.ID) -> RuntimeTargetState? {
        guard var slot = slotsByTargetID[targetID],
              let state = slot.targetState else {
            return nil
        }
        slot.targetState = nil
        storeSlot(slot, for: targetID)
        return state
    }

    @discardableResult
    mutating func removeRuntimeAgentState(for targetID: ProtocolTarget.ID) -> RuntimeAgentState? {
        guard var slot = slotsByTargetID[targetID],
              let state = slot.agentState else {
            return nil
        }
        slot.agentState = nil
        storeSlot(slot, for: targetID)
        return state
    }

    private mutating func storeSlot(_ slot: RuntimeTargetSlot, for targetID: ProtocolTarget.ID) {
        if slot.isEmpty {
            slotsByTargetID.removeValue(forKey: targetID)
        } else {
            slotsByTargetID[targetID] = slot
        }
    }
}

@MainActor
@Observable
package final class RuntimeState {
    package private(set) var selectedContextKey: RuntimeExecutionContextKey?

    private var targetRegistry: RuntimeTargetRegistry
    @ObservationIgnored private var selectedContextIsExplicit: Bool
    @ObservationIgnored private var commandChannel: ProtocolCommandChannel?
    @ObservationIgnored private let protocolCommands: RuntimeProtocolCommands
    @ObservationIgnored private var recordError: ((InspectorSession.Error?) -> Void)?

    package init() {
        selectedContextKey = nil
        targetRegistry = RuntimeTargetRegistry()
        selectedContextIsExplicit = false
        commandChannel = nil
        protocolCommands = RuntimeProtocolCommands()
        recordError = nil
    }

    package func reset() {
        selectedContextKey = nil
        targetRegistry.removeAll()
        selectedContextIsExplicit = false
    }

    package func bindProtocolChannel(
        _ commandChannel: ProtocolCommandChannel,
        recordError: @escaping (InspectorSession.Error?) -> Void
    ) {
        self.commandChannel = commandChannel
        self.recordError = recordError
    }

    package func unbindProtocolChannel() {
        commandChannel = nil
        recordError = nil
    }

    @discardableResult
    package func perform(_ intent: RuntimeCommandIntent) async throws -> ProtocolCommand.Result {
        try await perform(intent, requiresActiveConnection: true)
    }

    @discardableResult
    private func perform(
        _ intent: RuntimeCommandIntent,
        requiresActiveConnection: Bool
    ) async throws -> ProtocolCommand.Result {
        let commandChannel = try requireCommandChannel(requiresActiveConnection: requiresActiveConnection)
        let command = try protocolCommands.command(for: intent)
        let result: ProtocolCommand.Result
        do {
            result = try await commandChannel.send(command)
        } catch {
            markCommandUnsupportedIfNeeded(command.method, targetID: intent.routingTargetID, error: error)
            throw error
        }

        switch intent {
        case let .evaluate(request):
            let payload = try protocolCommands.evaluationResult(from: result)
            applyEvaluationResult(
                payload,
                request: request,
                runtimeAgentTargetID: result.targetID
            )
        case let .releaseObject(key):
            releaseObject(key)
        case let .releaseObjectGroup(runtimeAgentTargetID, objectGroup):
            releaseObjectGroup(objectGroup, runtimeAgentTargetID: runtimeAgentTargetID)
        default:
            break
        }
        return result
    }

    package func enable(targetID: ProtocolTarget.ID) async throws {
        _ = try await perform(.enable(targetID: targetID))
    }

    package func enableDuringBootstrap(targetID: ProtocolTarget.ID) async throws {
        _ = try await perform(.enable(targetID: targetID), requiresActiveConnection: false)
    }

    package func snapshot() -> RuntimeStateSnapshot {
        let remoteObjectsByID = remoteObjectsByID
        return RuntimeStateSnapshot(
            executionContextsByKey: executionContextRecordsByKey,
            selectedContextKey: selectedContextKey,
            normalContextKeyByTargetID: normalContextKeyByTargetID,
            remoteObjectsByID: remoteObjectsByID,
            objectGroupRuntimeAgentTargetsByGroup: Self.objectGroupRuntimeAgentTargets(from: remoteObjectsByID),
            unsupportedCommandsByTargetID: unsupportedCommandsByTargetID
        )
    }

    package func executionContext(for key: RuntimeExecutionContextKey) -> RuntimeExecutionContext? {
        runtimeAgentState(for: key.runtimeAgentTargetID)?.executionContext(contextID: key.contextID)
    }

    package var targetStates: [RuntimeTargetState] {
        targetRegistry.targetStates
    }

    package var runtimeAgentStates: [RuntimeAgentState] {
        targetRegistry.runtimeAgentStates
    }

    package func targetState(for targetID: ProtocolTarget.ID) -> RuntimeTargetState? {
        targetRegistry.targetState(for: targetID)
    }

    package func runtimeAgentState(for targetID: ProtocolTarget.ID) -> RuntimeAgentState? {
        targetRegistry.runtimeAgentState(for: targetID)
    }

    package func selectedContext(targetID: ProtocolTarget.ID? = nil) -> RuntimeExecutionContext? {
        guard let selectedContextKey,
              let context = executionContext(for: selectedContextKey) else {
            return nil
        }
        if let targetID {
            return context.targetID == targetID ? context : nil
        }
        return context
    }

    package func defaultContext(targetID: ProtocolTarget.ID) -> RuntimeExecutionContext? {
        guard let contextKey = targetState(for: targetID)?.normalContextKey else {
            return nil
        }
        return executionContext(for: contextKey)
    }

    package func applyExecutionContextCreated(_ payload: RuntimeExecutionContextPayload, targetID: ProtocolTarget.ID) {
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
                selectedContextIsExplicit = false
            }
        }
        let agentState = ensureRuntimeAgentState(for: record.runtimeAgentTargetID)
        agentState.recordExecutionContext(record)
        if record.type == .normal {
            let targetState = ensureTargetState(for: record.targetID)
            let previousDefaultContextKey = targetState.normalContextKey
            if shouldUseAsDefaultNormalContext(record, replacing: previousDefaultContextKey)
                || previousDefaultContextKey.map(oldContextKeys.contains) == true {
                targetState.normalContextKey = record.key
                if selectedContextKey == nil
                    || (selectedContextIsExplicit == false && selectedContextKey == previousDefaultContextKey) {
                    selectedContextKey = record.key
                    selectedContextIsExplicit = false
                }
            }
        }
        if record.type == .normal,
           selectedContextKey == nil {
            selectedContextKey = record.key
            selectedContextIsExplicit = false
        }
    }

    package func applyExecutionContextDestroyed(_ contextKey: RuntimeExecutionContextKey) {
        guard let context = removeExecutionContext(contextKey, releaseRemoteObjects: true) else {
            return
        }
        if targetState(for: context.targetID)?.normalContextKey == contextKey {
            targetState(for: context.targetID)?.normalContextKey = nil
        }
        if selectedContextKey == contextKey {
            selectedContextKey = nil
            selectedContextIsExplicit = false
        }
    }

    package func applyExecutionContextsCleared(runtimeAgentTargetID: ProtocolTarget.ID) {
        guard let agentState = runtimeAgentState(for: runtimeAgentTargetID) else {
            return
        }
        let removedContexts = Array(agentState.executionContextsByID.values)
        let removedContextKeys = Set(removedContexts.map(\.key))
        let removedTargetIDs = Set(removedContexts.map(\.targetID))
        agentState.clearExecutionContexts()
        agentState.clearRemoteObjects()
        for targetID in removedTargetIDs {
            if let normalContextKey = targetState(for: targetID)?.normalContextKey,
               removedContextKeys.contains(normalContextKey) {
                targetState(for: targetID)?.normalContextKey = nil
            }
        }
        if let selectedContextKey,
           removedContextKeys.contains(selectedContextKey) {
            self.selectedContextKey = nil
            selectedContextIsExplicit = false
        }
    }

    package func selectExecutionContext(_ contextKey: RuntimeExecutionContextKey?) {
        guard let contextKey else {
            selectedContextKey = nil
            selectedContextIsExplicit = false
            return
        }
        guard executionContext(for: contextKey) != nil else {
            return
        }
        selectedContextKey = contextKey
        selectedContextIsExplicit = true
    }

    package func applyTargetDestroyed(_ targetID: ProtocolTarget.ID) {
        var removedContexts: [RuntimeExecutionContext] = []
        if let removedAgent = removeRuntimeAgentState(for: targetID) {
            removedContexts.append(contentsOf: removedAgent.executionContextsByID.values)
        }
        for agentID in targetRegistry.targetIDs {
            guard let agentState = runtimeAgentState(for: agentID) else {
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
        }
        let removedContextKeys = Set(removedContexts.map(\.key))
        let removedTargetIDs = Set(removedContexts.map(\.targetID))
        for removedTargetID in removedTargetIDs {
            if let normalContextKey = targetState(for: removedTargetID)?.normalContextKey,
               removedContextKeys.contains(normalContextKey) {
                targetState(for: removedTargetID)?.normalContextKey = nil
            }
        }
        removeTargetState(for: targetID)
        if let selectedContextKey,
           removedContextKeys.contains(selectedContextKey) {
            self.selectedContextKey = nil
            selectedContextIsExplicit = false
        }
    }

    package func applyTargetCreated(_ record: ProtocolTarget.Record) {
        let targetState = ensureTargetState(for: record.id)
        targetState.frameID = record.frameID
        promotePreferredNormalContextIfNeeded(for: targetState)
    }

    package func applyTargetCommitted(oldTargetID: ProtocolTarget.ID?, newTargetID: ProtocolTarget.ID) {
        if let oldTargetID {
            let movedContextKeys = retargetExecutionContexts(from: oldTargetID, to: newTargetID)
            for targetState in targetStates {
                guard let normalContextKey = targetState.normalContextKey,
                      let movedKey = movedContextKeys[normalContextKey] else {
                    continue
                }
                targetState.normalContextKey = movedKey
            }
            if let oldTargetState = removeTargetState(for: oldTargetID) {
                let newTargetState = ensureTargetState(for: newTargetID)
                if newTargetState.frameID == nil {
                    newTargetState.frameID = oldTargetState.frameID
                }
                if newTargetState.normalContextKey == nil,
                   let normalContextKey = oldTargetState.normalContextKey {
                    newTargetState.normalContextKey = movedContextKeys[normalContextKey] ?? normalContextKey
                }
            }
            if let selectedContextKey,
               let movedKey = movedContextKeys[selectedContextKey] {
                self.selectedContextKey = movedKey
            }
            if let oldAgentState = removeRuntimeAgentState(for: oldTargetID),
               oldAgentState.unsupportedCommandSnapshot.isEmpty == false {
                let newAgentState = ensureRuntimeAgentState(for: newTargetID)
                newAgentState.mergeUnsupportedCommands(oldAgentState.unsupportedCommandSnapshot)
            }
        }
    }

    @discardableResult
    package func registerRemoteObject(
        _ object: RuntimeRemoteObjectPayload,
        runtimeAgentTargetID: ProtocolTarget.ID,
        objectGroup: RuntimeObjectGroup? = nil,
        executionContextID: ExecutionContextID? = nil
    ) -> RuntimeRemoteObject {
        let agentState = ensureRuntimeAgentState(for: runtimeAgentTargetID)
        let remoteObject = agentState.registerRemoteObject(
            object,
            objectGroup: objectGroup,
            executionContextID: executionContextID
        )
        return remoteObject
    }

    package func applyEvaluationResult(
        _ result: RuntimeEvaluationResultPayload,
        request: RuntimeEvaluationRequest,
        runtimeAgentTargetID: ProtocolTarget.ID? = nil
    ) {
        registerRemoteObject(
            result.result,
            runtimeAgentTargetID: runtimeAgentTargetID ?? request.runtimeAgentTargetID,
            objectGroup: request.objectGroup,
            executionContextID: request.contextID
        )
    }

    package func releaseObject(_ key: RuntimeRemoteObjectIdentifierKey) {
        guard let agentState = runtimeAgentState(for: key.runtimeAgentTargetID) else {
            return
        }
        agentState.releaseRemoteObject(key.objectID)
    }

    package func releaseObjectGroup(_ objectGroup: RuntimeObjectGroup, runtimeAgentTargetID: ProtocolTarget.ID) {
        guard let agentState = runtimeAgentState(for: runtimeAgentTargetID) else {
            return
        }
        agentState.releaseRemoteObjects(objectGroup: objectGroup)
    }

    package func markCommandUnsupported(_ method: String, targetID: ProtocolTarget.ID) {
        let agentState = ensureRuntimeAgentState(for: targetID)
        agentState.markCommandUnsupported(method)
    }

    package func supportsCommand(_ method: String, targetID: ProtocolTarget.ID) -> Bool {
        runtimeAgentState(for: targetID)?.supportsCommand(method) ?? true
    }

    private var executionContextsByKey: [RuntimeExecutionContextKey: RuntimeExecutionContext] {
        Dictionary(
            uniqueKeysWithValues: runtimeAgentStates.flatMap { state in
                state.executionContextsByKey.map { ($0.key, $0.value) }
            }
        )
    }

    private var executionContextRecordsByKey: [RuntimeExecutionContextKey: RuntimeExecutionContextRecord] {
        Dictionary(
            uniqueKeysWithValues: runtimeAgentStates.flatMap { state in
                state.executionContextRecordsByKey.map { ($0.key, $0.value) }
            }
        )
    }

    private var normalContextKeyByTargetID: [ProtocolTarget.ID: RuntimeExecutionContextKey] {
        Dictionary(
            uniqueKeysWithValues: targetStates.compactMap { state in
                state.normalContextKey.map { (state.targetID, $0) }
            }
        )
    }

    private var remoteObjectsByID: [RuntimeRemoteObjectIdentifierKey: RuntimeRemoteObjectRecord] {
        Dictionary(
            uniqueKeysWithValues: runtimeAgentStates.flatMap { state in
                state.remoteObjectsByKey.map { ($0.key, $0.value) }
            }
        )
    }

    private var unsupportedCommandsByTargetID: [ProtocolTarget.ID: Set<String>] {
        Dictionary(
            uniqueKeysWithValues: runtimeAgentStates
                .filter { $0.unsupportedCommandSnapshot.isEmpty == false }
                .map { ($0.targetID, $0.unsupportedCommandSnapshot) }
        )
    }

    private func ensureTargetState(for targetID: ProtocolTarget.ID) -> RuntimeTargetState {
        targetRegistry.ensureTargetState(for: targetID)
    }

    private func ensureRuntimeAgentState(for targetID: ProtocolTarget.ID) -> RuntimeAgentState {
        targetRegistry.ensureRuntimeAgentState(for: targetID)
    }

    @discardableResult
    private func removeTargetState(for targetID: ProtocolTarget.ID) -> RuntimeTargetState? {
        targetRegistry.removeTargetState(for: targetID)
    }

    @discardableResult
    private func removeRuntimeAgentState(for targetID: ProtocolTarget.ID) -> RuntimeAgentState? {
        targetRegistry.removeRuntimeAgentState(for: targetID)
    }

    private func shouldUseAsDefaultNormalContext(
        _ record: RuntimeExecutionContextRecord,
        replacing currentKey: RuntimeExecutionContextKey?
    ) -> Bool {
        guard let currentKey else {
            return true
        }
        guard let currentContext = executionContext(for: currentKey) else {
            return true
        }
        guard let targetFrameID = targetState(for: record.targetID)?.frameID else {
            return false
        }
        guard currentContext.frameID != targetFrameID else {
            return false
        }
        return record.frameID == targetFrameID
    }

    private func promotePreferredNormalContextIfNeeded(for targetState: RuntimeTargetState) {
        guard let targetFrameID = targetState.frameID else {
            return
        }
        let currentDefaultContextKey = targetState.normalContextKey
        if let currentDefaultContextKey,
           executionContext(for: currentDefaultContextKey)?.frameID == targetFrameID {
            return
        }

        guard let preferredContext = executionContextsByKey.values
            .filter({
                $0.type == .normal
                    && $0.targetID == targetState.targetID
                    && $0.frameID == targetFrameID
            })
            .sorted(by: {
                RuntimeExecutionContextRecord.stableOrder($0.snapshotRecord, $1.snapshotRecord)
            })
            .first else {
            return
        }

        targetState.normalContextKey = preferredContext.key
        if selectedContextKey == nil
            || (selectedContextIsExplicit == false && selectedContextKey == currentDefaultContextKey) {
            selectedContextKey = preferredContext.key
            selectedContextIsExplicit = false
        }
    }

    @discardableResult
    private func removeExecutionContext(
        _ contextKey: RuntimeExecutionContextKey,
        releaseRemoteObjects: Bool
    ) -> RuntimeExecutionContext? {
        guard let agentState = runtimeAgentState(for: contextKey.runtimeAgentTargetID),
              let context = agentState.removeExecutionContext(contextID: contextKey.contextID) else {
            return nil
        }
        if releaseRemoteObjects {
            agentState.releaseRemoteObjects(executionContextKey: contextKey)
        }
        return context
    }

    private func retargetExecutionContexts(
        from oldTargetID: ProtocolTarget.ID,
        to newTargetID: ProtocolTarget.ID
    ) -> [RuntimeExecutionContextKey: RuntimeExecutionContextKey] {
        var movedContextKeys: [RuntimeExecutionContextKey: RuntimeExecutionContextKey] = [:]
        let currentContexts = runtimeAgentStates.flatMap { state in
            state.executionContexts.map { (runtimeAgentTargetID: state.targetID, context: $0) }
        }

        for entry in currentContexts {
            guard let sourceAgentState = runtimeAgentState(for: entry.runtimeAgentTargetID),
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
            movedContextKeys[oldKey] = nextKey

            if let destinationAgentState = runtimeAgentState(for: nextRuntimeAgentTargetID),
               destinationAgentState.executionContext(contextID: entry.context.id) != nil {
                continue
            }

            entry.context.targetID = nextTargetID
            entry.context.runtimeAgentTargetID = nextRuntimeAgentTargetID
            let destinationAgentState = ensureRuntimeAgentState(for: nextRuntimeAgentTargetID)
            destinationAgentState.insertExecutionContext(entry.context)
        }

        return movedContextKeys
    }

    private static func objectGroupRuntimeAgentTargets(
        from remoteObjectsByID: [RuntimeRemoteObjectIdentifierKey: RuntimeRemoteObjectRecord]
    ) -> [RuntimeObjectGroup: Set<ProtocolTarget.ID>] {
        var targetsByGroup: [RuntimeObjectGroup: Set<ProtocolTarget.ID>] = [:]
        for (key, record) in remoteObjectsByID {
            if let objectGroup = record.objectGroup {
                targetsByGroup[objectGroup, default: []].insert(key.runtimeAgentTargetID)
            }
        }
        return targetsByGroup
    }

    private func normalContextKeysToReplace(with record: RuntimeExecutionContextRecord) -> Set<RuntimeExecutionContextKey> {
        guard let agentState = runtimeAgentState(for: record.runtimeAgentTargetID) else {
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

    package func enableIntent(targetID: ProtocolTarget.ID) -> RuntimeCommandIntent {
        .enable(targetID: targetID)
    }

    package func evaluateIntent(
        expression: String,
        targetID: ProtocolTarget.ID,
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
        targetID: ProtocolTarget.ID,
        contextKey: RuntimeExecutionContextKey?
    ) -> RuntimeExecutionContext? {
        if let contextKey {
            return executionContextsByKey[contextKey]
        }
        return selectedContext(targetID: targetID) ?? defaultContext(targetID: targetID)
    }

    private func markCommandUnsupportedIfNeeded(
        _ method: String,
        targetID: ProtocolTarget.ID,
        error: any Error
    ) {
        guard isUnsupportedProtocolCommandError(method, error: error) else {
            return
        }
        markCommandUnsupported(method, targetID: targetID)
    }

    private func requireCommandChannel(requiresActiveConnection: Bool = true) throws -> ProtocolCommandChannel {
        guard let commandChannel else {
            throw InspectorSession.Error("Inspector session is not attached.")
        }
        if requiresActiveConnection {
            try commandChannel.requireAttached()
        }
        return commandChannel
    }
}
