import Observation
import WebInspectorTransport

package struct ConsoleMessageIdentifier: Hashable, Sendable, Comparable {
    package var targetID: ProtocolTarget.ID
    package var ordinal: UInt64

    package init(targetID: ProtocolTarget.ID, ordinal: UInt64) {
        self.targetID = targetID
        self.ordinal = ordinal
    }

    package static func < (lhs: ConsoleMessageIdentifier, rhs: ConsoleMessageIdentifier) -> Bool {
        if lhs.ordinal == rhs.ordinal {
            return lhs.targetID.rawValue < rhs.targetID.rawValue
        }
        return lhs.ordinal < rhs.ordinal
    }
}

@MainActor
@Observable
package final class ConsoleMessage {
    package typealias ID = ConsoleMessageIdentifier

    package let id: ID
    package var source: ConsoleMessageSource
    package var level: ConsoleMessageLevel
    package var text: String
    package var type: ConsoleMessageType?
    package var url: String?
    package var line: Int?
    package var column: Int?
    package var repeatCount: Int
    package var parameters: [RuntimeRemoteObject]
    package var stackTrace: ConsoleStackTracePayload?
    package var networkRequestKey: NetworkRequestIdentifierKey?
    package var timestamp: Double?

    package init(
        id: ID,
        targetID: ProtocolTarget.ID,
        payload: ConsoleMessagePayload,
        parameters: [RuntimeRemoteObject]? = nil
    ) {
        self.id = id
        self.source = payload.source
        self.level = payload.level
        self.text = payload.text
        self.type = payload.type
        self.url = payload.url
        self.line = payload.line
        self.column = payload.column
        self.repeatCount = max(1, payload.repeatCount ?? 1)
        self.parameters = parameters ?? Self.parameterObjects(from: payload.parameters, targetID: targetID)
        self.stackTrace = payload.stackTrace
        self.networkRequestKey = payload.networkRequestID.map {
            NetworkRequestIdentifierKey(targetID: targetID, requestID: $0)
        }
        self.timestamp = payload.timestamp
    }

    package var targetID: ProtocolTarget.ID {
        id.targetID
    }

    private static func parameterObjects(
        from payloads: [RuntimeRemoteObjectPayload],
        targetID: ProtocolTarget.ID
    ) -> [RuntimeRemoteObject] {
        payloads.map { payload in
            RuntimeRemoteObject(
                remoteObjectKey: payload.identifierKey(runtimeAgentTargetID: targetID),
                payload: payload,
                objectGroup: .console
            )
        }
    }
}

package struct ConsoleMessageSnapshot: Equatable, Sendable {
    package var id: ConsoleMessageIdentifier
    package var source: ConsoleMessageSource
    package var level: ConsoleMessageLevel
    package var text: String
    package var type: ConsoleMessageType?
    package var url: String?
    package var line: Int?
    package var column: Int?
    package var repeatCount: Int
    package var parameters: [RuntimeRemoteObjectPayload]
    package var stackTrace: ConsoleStackTracePayload?
    package var networkRequestKey: NetworkRequestIdentifierKey?
    package var timestamp: Double?
}

package struct ConsoleSessionSnapshot: Equatable, Sendable {
    package var orderedMessageIDs: [ConsoleMessageIdentifier]
    package var messagesByID: [ConsoleMessageIdentifier: ConsoleMessageSnapshot]
    package var warningCount: Int
    package var errorCount: Int
    package var warningCountByTargetID: [ProtocolTarget.ID: Int]
    package var errorCountByTargetID: [ProtocolTarget.ID: Int]
    package var lastClearReasonByTargetID: [ProtocolTarget.ID: ConsoleClearReason]
    package var unsupportedCommandsByTargetID: [ProtocolTarget.ID: Set<String>]
}

@MainActor
@Observable
package final class ConsoleTargetState {
    package let targetID: ProtocolTarget.ID
    private var messageStore: ConsoleMessageStore
    package private(set) var lastClearReason: ConsoleClearReason?
    private var unsupportedCommands: Set<String>

    init(targetID: ProtocolTarget.ID) {
        self.targetID = targetID
        messageStore = ConsoleMessageStore()
        lastClearReason = nil
        unsupportedCommands = []
    }

    package var warningCount: Int {
        messageStore.warningCount
    }

    package var errorCount: Int {
        messageStore.errorCount
    }

    package var orderedMessageIDs: [ConsoleMessageIdentifier] {
        messageStore.orderedMessageIDs
    }

    package var messages: [ConsoleMessage] {
        messageStore.messages
    }

    package func message(for id: ConsoleMessageIdentifier) -> ConsoleMessage? {
        messageStore.message(for: id)
    }

    func append(
        _ payload: ConsoleMessagePayload,
        ordinal: UInt64,
        parameters: [RuntimeRemoteObject]? = nil
    ) -> ConsoleMessageIdentifier {
        let id = ConsoleMessageIdentifier(targetID: targetID, ordinal: ordinal)
        let message = ConsoleMessage(id: id, targetID: targetID, payload: payload, parameters: parameters)
        messageStore.append(message, canRepeat: payload.type != .clear)
        return id
    }

    func updateRepeatCount(count: Int, timestamp: Double?) {
        messageStore.updateLastRepeatCount(count: count, timestamp: timestamp)
    }

    func clearMessages(reason: ConsoleClearReason) {
        lastClearReason = reason
        messageStore.removeAll()
    }

    func retargeted(to newTargetID: ProtocolTarget.ID) -> ConsoleTargetState {
        let nextState = ConsoleTargetState(targetID: newTargetID)
        nextState.lastClearReason = lastClearReason
        nextState.unsupportedCommands = unsupportedCommands
        nextState.messageStore = messageStore.retargeted(to: newTargetID)
        return nextState
    }

    func mergeCommittedState(_ committedState: ConsoleTargetState) {
        messageStore.mergeCommittedStore(committedState.messageStore)
        if let lastClearReason = committedState.lastClearReason {
            self.lastClearReason = lastClearReason
        }
        unsupportedCommands.formUnion(committedState.unsupportedCommands)
    }

    func markCommandUnsupported(_ method: String) {
        unsupportedCommands.insert(method)
    }

    func supportsCommand(_ method: String) -> Bool {
        unsupportedCommands.contains(method) == false
    }

    fileprivate var messageSnapshotEntries: [(ConsoleMessageIdentifier, ConsoleMessageSnapshot)] {
        messageStore.messageSnapshotEntries
    }

    fileprivate var unsupportedCommandSnapshot: Set<String> {
        unsupportedCommands
    }
}

@MainActor
private struct ConsoleTargetRegistry {
    private var statesByID: [ProtocolTarget.ID: ConsoleTargetState] = [:]

    var targetStates: [ConsoleTargetState] {
        statesByID.values.sorted { $0.targetID.rawValue < $1.targetID.rawValue }
    }

    var orderedMessageIDs: [ConsoleMessageIdentifier] {
        statesByID.values.flatMap(\.orderedMessageIDs).sorted()
    }

    var messages: [ConsoleMessage] {
        orderedMessageIDs.compactMap { message(for: $0) }
    }

    var warningCount: Int {
        statesByID.values.reduce(0) { $0 + $1.warningCount }
    }

    var errorCount: Int {
        statesByID.values.reduce(0) { $0 + $1.errorCount }
    }

    mutating func removeAll() {
        statesByID.removeAll()
    }

    func targetState(for targetID: ProtocolTarget.ID) -> ConsoleTargetState? {
        statesByID[targetID]
    }

    func message(for id: ConsoleMessageIdentifier) -> ConsoleMessage? {
        statesByID[id.targetID]?.message(for: id)
    }

    mutating func ensureTargetState(for targetID: ProtocolTarget.ID) -> ConsoleTargetState {
        if let state = statesByID[targetID] {
            return state
        }
        let state = ConsoleTargetState(targetID: targetID)
        statesByID[targetID] = state
        return state
    }

    mutating func removeTargetState(for targetID: ProtocolTarget.ID) {
        statesByID.removeValue(forKey: targetID)
    }

    mutating func retarget(oldTargetID: ProtocolTarget.ID, newTargetID: ProtocolTarget.ID) {
        guard let oldState = statesByID.removeValue(forKey: oldTargetID) else {
            return
        }
        let committedState = oldState.retargeted(to: newTargetID)
        if let newState = statesByID[newTargetID] {
            newState.mergeCommittedState(committedState)
        } else {
            statesByID[newTargetID] = committedState
        }
    }

    func warningCountByTargetID() -> [ProtocolTarget.ID: Int] {
        Dictionary(
            uniqueKeysWithValues: statesByID.values
                .filter { $0.warningCount > 0 }
                .map { ($0.targetID, $0.warningCount) }
        )
    }

    func errorCountByTargetID() -> [ProtocolTarget.ID: Int] {
        Dictionary(
            uniqueKeysWithValues: statesByID.values
                .filter { $0.errorCount > 0 }
                .map { ($0.targetID, $0.errorCount) }
        )
    }

    func messageSnapshotEntries() -> [(ConsoleMessageIdentifier, ConsoleMessageSnapshot)] {
        statesByID.values.flatMap { state in
            state.messageSnapshotEntries
        }
    }

    func lastClearReasonByTargetID() -> [ProtocolTarget.ID: ConsoleClearReason] {
        Dictionary(
            uniqueKeysWithValues: statesByID.values.compactMap { state in
                state.lastClearReason.map { (state.targetID, $0) }
            }
        )
    }

    func unsupportedCommandsByTargetID() -> [ProtocolTarget.ID: Set<String>] {
        Dictionary(
            uniqueKeysWithValues: statesByID.values
                .filter { $0.unsupportedCommandSnapshot.isEmpty == false }
                .map { ($0.targetID, $0.unsupportedCommandSnapshot) }
        )
    }
}

@MainActor
@Observable
package final class ConsoleSession {
    package private(set) var warningCount: Int
    package private(set) var errorCount: Int

    @ObservationIgnored private var nextMessageOrdinal: UInt64
    @ObservationIgnored private var commandChannel: ProtocolCommandChannel?
    @ObservationIgnored private let protocolCommands: ConsoleProtocolCommands
    @ObservationIgnored private var recordError: ((InspectorSession.Error?) -> Void)?
    private var targetRegistry: ConsoleTargetRegistry

    package init() {
        warningCount = 0
        errorCount = 0
        nextMessageOrdinal = 0
        commandChannel = nil
        protocolCommands = ConsoleProtocolCommands()
        recordError = nil
        targetRegistry = ConsoleTargetRegistry()
    }

    package func reset() {
        warningCount = 0
        errorCount = 0
        nextMessageOrdinal = 0
        targetRegistry.removeAll()
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
    package func perform(_ intent: ConsoleCommandIntent) async throws -> ProtocolCommand.Result {
        try await perform(intent, requiresActiveConnection: true)
    }

    @discardableResult
    private func perform(
        _ intent: ConsoleCommandIntent,
        requiresActiveConnection: Bool
    ) async throws -> ProtocolCommand.Result {
        let commandChannel = try requireCommandChannel(requiresActiveConnection: requiresActiveConnection)
        let command = try protocolCommands.command(for: intent)
        do {
            return try await commandChannel.send(command)
        } catch {
            markCommandUnsupportedIfNeeded(command.method, targetID: intent.targetID, error: error)
            throw error
        }
    }

    package func enable(targetID: ProtocolTarget.ID) async throws {
        _ = try await perform(.enable(targetID: targetID))
    }

    package func enableDuringBootstrap(targetID: ProtocolTarget.ID) async throws {
        _ = try await perform(.enable(targetID: targetID), requiresActiveConnection: false)
    }

    package var messages: [ConsoleMessage] {
        targetRegistry.messages
    }

    package var targetStates: [ConsoleTargetState] {
        targetRegistry.targetStates
    }

    package func targetState(for targetID: ProtocolTarget.ID) -> ConsoleTargetState? {
        targetRegistry.targetState(for: targetID)
    }

    package func message(for id: ConsoleMessageIdentifier) -> ConsoleMessage? {
        targetRegistry.message(for: id)
    }

    package func snapshot() -> ConsoleSessionSnapshot {
        let orderedMessageIDs = orderedMessageIDs
        return ConsoleSessionSnapshot(
            orderedMessageIDs: orderedMessageIDs,
            messagesByID: Dictionary(
                uniqueKeysWithValues: targetRegistry.messageSnapshotEntries()
            ),
            warningCount: warningCount,
            errorCount: errorCount,
            warningCountByTargetID: targetRegistry.warningCountByTargetID(),
            errorCountByTargetID: targetRegistry.errorCountByTargetID(),
            lastClearReasonByTargetID: targetRegistry.lastClearReasonByTargetID(),
            unsupportedCommandsByTargetID: targetRegistry.unsupportedCommandsByTargetID()
        )
    }

    @discardableResult
    package func applyMessageAdded(
        _ payload: ConsoleMessagePayload,
        targetID: ProtocolTarget.ID,
        parameters: [RuntimeRemoteObject]? = nil
    ) -> ConsoleMessageIdentifier {
        nextMessageOrdinal &+= 1
        let state = targetRegistry.ensureTargetState(for: targetID)
        let id = state.append(payload, ordinal: nextMessageOrdinal, parameters: parameters)
        updateAggregateSeverityCounts()
        return id
    }

    package func applyRepeatCountUpdated(count: Int, timestamp: Double?, targetID: ProtocolTarget.ID) {
        guard let state = targetRegistry.targetState(for: targetID) else {
            return
        }
        state.updateRepeatCount(count: count, timestamp: timestamp)
        updateAggregateSeverityCounts()
    }

    package func applyMessagesCleared(reason: ConsoleClearReason, targetID: ProtocolTarget.ID) {
        let state = targetRegistry.ensureTargetState(for: targetID)
        state.clearMessages(reason: reason)
        updateAggregateSeverityCounts()
    }

    package func applyTargetDestroyed(_ targetID: ProtocolTarget.ID) {
        targetRegistry.removeTargetState(for: targetID)
        updateAggregateSeverityCounts()
    }

    package func applyTargetCommitted(oldTargetID: ProtocolTarget.ID?, newTargetID: ProtocolTarget.ID) {
        guard let oldTargetID else {
            return
        }
        targetRegistry.retarget(oldTargetID: oldTargetID, newTargetID: newTargetID)
        updateAggregateSeverityCounts()
    }

    package func markCommandUnsupported(_ method: String, targetID: ProtocolTarget.ID) {
        let state = targetRegistry.ensureTargetState(for: targetID)
        state.markCommandUnsupported(method)
    }

    package func supportsCommand(_ method: String, targetID: ProtocolTarget.ID) -> Bool {
        targetRegistry.targetState(for: targetID)?.supportsCommand(method) ?? true
    }

    package func enableIntent(targetID: ProtocolTarget.ID) -> ConsoleCommandIntent {
        .enable(targetID: targetID)
    }

    private var orderedMessageIDs: [ConsoleMessageIdentifier] {
        targetRegistry.orderedMessageIDs
    }

    private func updateAggregateSeverityCounts() {
        warningCount = targetRegistry.warningCount
        errorCount = targetRegistry.errorCount
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
