import Observation

package struct ConsoleMessageIdentifier: Hashable, Sendable, Comparable {
    package var targetID: ProtocolTargetIdentifier
    package var ordinal: UInt64

    package init(targetID: ProtocolTargetIdentifier, ordinal: UInt64) {
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
    package var parameters: [RuntimeRemoteObjectPayload]
    package var stackTrace: ConsoleStackTracePayload?
    package var networkRequestKey: NetworkRequestIdentifierKey?
    package var timestamp: Double?

    package init(id: ID, targetID: ProtocolTargetIdentifier, payload: ConsoleMessagePayload) {
        self.id = id
        self.source = payload.source
        self.level = payload.level
        self.text = payload.text
        self.type = payload.type
        self.url = payload.url
        self.line = payload.line
        self.column = payload.column
        self.repeatCount = max(1, payload.repeatCount ?? 1)
        self.parameters = payload.parameters
        self.stackTrace = payload.stackTrace
        self.networkRequestKey = payload.networkRequestID.map {
            NetworkRequestIdentifierKey(targetID: targetID, requestID: $0)
        }
        self.timestamp = payload.timestamp
    }

    package var targetID: ProtocolTargetIdentifier {
        id.targetID
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
    package var warningCountByTargetID: [ProtocolTargetIdentifier: Int]
    package var errorCountByTargetID: [ProtocolTargetIdentifier: Int]
    package var lastClearReasonByTargetID: [ProtocolTargetIdentifier: ConsoleClearReason]
    package var unsupportedCommandsByTargetID: [ProtocolTargetIdentifier: Set<String>]
}

@MainActor
@Observable
package final class ConsoleTargetState {
    package let targetID: ProtocolTargetIdentifier
    package private(set) var orderedMessageIDs: [ConsoleMessageIdentifier]
    private var messagesByID: [ConsoleMessageIdentifier: ConsoleMessage]
    private var lastRepeatableMessageID: ConsoleMessageIdentifier?
    package private(set) var warningCount: Int
    package private(set) var errorCount: Int
    package private(set) var lastClearReason: ConsoleClearReason?
    private var unsupportedCommands: Set<String>

    init(targetID: ProtocolTargetIdentifier) {
        self.targetID = targetID
        orderedMessageIDs = []
        messagesByID = [:]
        lastRepeatableMessageID = nil
        warningCount = 0
        errorCount = 0
        lastClearReason = nil
        unsupportedCommands = []
    }

    package var messages: [ConsoleMessage] {
        orderedMessageIDs.compactMap { messagesByID[$0] }
    }

    package func message(for id: ConsoleMessageIdentifier) -> ConsoleMessage? {
        messagesByID[id]
    }

    func append(_ payload: ConsoleMessagePayload, ordinal: UInt64) -> ConsoleMessageIdentifier {
        let id = ConsoleMessageIdentifier(targetID: targetID, ordinal: ordinal)
        let message = ConsoleMessage(id: id, targetID: targetID, payload: payload)
        orderedMessageIDs.append(id)
        messagesByID[id] = message
        if payload.type != .clear {
            lastRepeatableMessageID = id
        }
        incrementSeverity(level: message.level, repeatCount: message.repeatCount)
        return id
    }

    func updateRepeatCount(count: Int, timestamp: Double?) {
        guard let messageID = lastRepeatableMessageID,
              let message = messagesByID[messageID] else {
            return
        }
        incrementSeverity(level: message.level, repeatCount: -message.repeatCount)
        message.repeatCount = max(1, count)
        if let timestamp {
            message.timestamp = timestamp
        }
        incrementSeverity(level: message.level, repeatCount: message.repeatCount)
    }

    func clearMessages(reason: ConsoleClearReason) {
        lastClearReason = reason
        orderedMessageIDs.removeAll()
        messagesByID.removeAll()
        lastRepeatableMessageID = nil
        warningCount = 0
        errorCount = 0
    }

    func retargeted(to newTargetID: ProtocolTargetIdentifier) -> ConsoleTargetState {
        let nextState = ConsoleTargetState(targetID: newTargetID)
        nextState.lastClearReason = lastClearReason
        nextState.unsupportedCommands = unsupportedCommands
        for oldID in orderedMessageIDs {
            guard let message = messagesByID[oldID] else {
                continue
            }
            let newID = ConsoleMessageIdentifier(targetID: newTargetID, ordinal: oldID.ordinal)
            nextState.orderedMessageIDs.append(newID)
            nextState.messagesByID[newID] = ConsoleMessage(
                id: newID,
                targetID: newTargetID,
                payload: ConsoleMessagePayload(
                    source: message.source,
                    level: message.level,
                    text: message.text,
                    type: message.type,
                    url: message.url,
                    line: message.line,
                    column: message.column,
                    repeatCount: message.repeatCount,
                    parameters: message.parameters,
                    stackTrace: message.stackTrace,
                    networkRequestID: message.networkRequestKey?.requestID,
                    timestamp: message.timestamp
                )
            )
        }
        if let lastRepeatableMessageID {
            nextState.lastRepeatableMessageID = ConsoleMessageIdentifier(
                targetID: newTargetID,
                ordinal: lastRepeatableMessageID.ordinal
            )
        }
        nextState.recalculateSeverityCounts()
        return nextState
    }

    func mergeCommittedState(_ committedState: ConsoleTargetState) {
        orderedMessageIDs.append(contentsOf: committedState.orderedMessageIDs)
        orderedMessageIDs.sort()
        for (id, message) in committedState.messagesByID {
            messagesByID[id] = message
        }
        if let lastRepeatableMessageID = committedState.lastRepeatableMessageID {
            self.lastRepeatableMessageID = lastRepeatableMessageID
        }
        if let lastClearReason = committedState.lastClearReason {
            self.lastClearReason = lastClearReason
        }
        unsupportedCommands.formUnion(committedState.unsupportedCommands)
        recalculateSeverityCounts()
    }

    func markCommandUnsupported(_ method: String) {
        unsupportedCommands.insert(method)
    }

    func supportsCommand(_ method: String) -> Bool {
        unsupportedCommands.contains(method) == false
    }

    fileprivate var messageSnapshotEntries: [(ConsoleMessageIdentifier, ConsoleMessageSnapshot)] {
        messagesByID.map { id, message in
            (
                id,
                ConsoleMessageSnapshot(
                    id: message.id,
                    source: message.source,
                    level: message.level,
                    text: message.text,
                    type: message.type,
                    url: message.url,
                    line: message.line,
                    column: message.column,
                    repeatCount: message.repeatCount,
                    parameters: message.parameters,
                    stackTrace: message.stackTrace,
                    networkRequestKey: message.networkRequestKey,
                    timestamp: message.timestamp
                )
            )
        }
    }

    fileprivate var unsupportedCommandSnapshot: Set<String> {
        unsupportedCommands
    }

    private func incrementSeverity(level: ConsoleMessageLevel, repeatCount: Int) {
        switch level {
        case .warning:
            warningCount += repeatCount
        case .error:
            errorCount += repeatCount
        default:
            break
        }
    }

    private func recalculateSeverityCounts() {
        warningCount = 0
        errorCount = 0
        for message in messagesByID.values {
            incrementSeverity(level: message.level, repeatCount: message.repeatCount)
        }
    }
}

@MainActor
@Observable
package final class ConsoleSession {
    package private(set) var warningCount: Int
    package private(set) var errorCount: Int

    @ObservationIgnored private var nextMessageOrdinal: UInt64
    private var targetStatesByID: [ProtocolTargetIdentifier: ConsoleTargetState]

    package init() {
        warningCount = 0
        errorCount = 0
        nextMessageOrdinal = 0
        targetStatesByID = [:]
    }

    package func reset() {
        warningCount = 0
        errorCount = 0
        nextMessageOrdinal = 0
        targetStatesByID.removeAll()
    }

    package var messages: [ConsoleMessage] {
        orderedMessageIDs.compactMap { targetStatesByID[$0.targetID]?.message(for: $0) }
    }

    package var targetStates: [ConsoleTargetState] {
        targetStatesByID.values.sorted { $0.targetID.rawValue < $1.targetID.rawValue }
    }

    package func targetState(for targetID: ProtocolTargetIdentifier) -> ConsoleTargetState? {
        targetStatesByID[targetID]
    }

    package func message(for id: ConsoleMessageIdentifier) -> ConsoleMessage? {
        targetStatesByID[id.targetID]?.message(for: id)
    }

    package func snapshot() -> ConsoleSessionSnapshot {
        let orderedMessageIDs = orderedMessageIDs
        return ConsoleSessionSnapshot(
            orderedMessageIDs: orderedMessageIDs,
            messagesByID: Dictionary(
                uniqueKeysWithValues: targetStatesByID.values.flatMap { state in
                    state.messageSnapshotEntries
                }
            ),
            warningCount: warningCount,
            errorCount: errorCount,
            warningCountByTargetID: Dictionary(
                uniqueKeysWithValues: targetStatesByID.values
                    .filter { $0.warningCount > 0 }
                    .map { ($0.targetID, $0.warningCount) }
            ),
            errorCountByTargetID: Dictionary(
                uniqueKeysWithValues: targetStatesByID.values
                    .filter { $0.errorCount > 0 }
                    .map { ($0.targetID, $0.errorCount) }
            ),
            lastClearReasonByTargetID: Dictionary(
                uniqueKeysWithValues: targetStatesByID.values.compactMap { state in
                    state.lastClearReason.map { (state.targetID, $0) }
                }
            ),
            unsupportedCommandsByTargetID: Dictionary(
                uniqueKeysWithValues: targetStatesByID.values
                    .filter { $0.unsupportedCommandSnapshot.isEmpty == false }
                    .map { ($0.targetID, $0.unsupportedCommandSnapshot) }
            )
        )
    }

    @discardableResult
    package func applyMessageAdded(_ payload: ConsoleMessagePayload, targetID: ProtocolTargetIdentifier) -> ConsoleMessageIdentifier {
        nextMessageOrdinal &+= 1
        let state = ensureTargetState(for: targetID)
        let id = state.append(payload, ordinal: nextMessageOrdinal)
        updateAggregateSeverityCounts()
        return id
    }

    package func applyRepeatCountUpdated(count: Int, timestamp: Double?, targetID: ProtocolTargetIdentifier) {
        guard let state = targetStatesByID[targetID] else {
            return
        }
        state.updateRepeatCount(count: count, timestamp: timestamp)
        updateAggregateSeverityCounts()
    }

    package func applyMessagesCleared(reason: ConsoleClearReason, targetID: ProtocolTargetIdentifier) {
        let state = ensureTargetState(for: targetID)
        state.clearMessages(reason: reason)
        updateAggregateSeverityCounts()
    }

    package func applyTargetDestroyed(_ targetID: ProtocolTargetIdentifier) {
        targetStatesByID.removeValue(forKey: targetID)
        updateAggregateSeverityCounts()
    }

    package func applyTargetCommitted(oldTargetID: ProtocolTargetIdentifier?, newTargetID: ProtocolTargetIdentifier) {
        guard let oldTargetID,
              let oldState = targetStatesByID.removeValue(forKey: oldTargetID) else {
            return
        }
        let committedState = oldState.retargeted(to: newTargetID)
        if let newState = targetStatesByID[newTargetID] {
            newState.mergeCommittedState(committedState)
        } else {
            targetStatesByID[newTargetID] = committedState
        }
        updateAggregateSeverityCounts()
    }

    package func markCommandUnsupported(_ method: String, targetID: ProtocolTargetIdentifier) {
        let state = ensureTargetState(for: targetID)
        state.markCommandUnsupported(method)
    }

    package func supportsCommand(_ method: String, targetID: ProtocolTargetIdentifier) -> Bool {
        targetStatesByID[targetID]?.supportsCommand(method) ?? true
    }

    package func enableIntent(targetID: ProtocolTargetIdentifier) -> ConsoleCommandIntent {
        .enable(targetID: targetID)
    }

    private var orderedMessageIDs: [ConsoleMessageIdentifier] {
        targetStatesByID.values.flatMap(\.orderedMessageIDs).sorted()
    }

    private func ensureTargetState(for targetID: ProtocolTargetIdentifier) -> ConsoleTargetState {
        if let state = targetStatesByID[targetID] {
            return state
        }
        let state = ConsoleTargetState(targetID: targetID)
        targetStatesByID[targetID] = state
        return state
    }

    private func updateAggregateSeverityCounts() {
        warningCount = targetStatesByID.values.reduce(0) { $0 + $1.warningCount }
        errorCount = targetStatesByID.values.reduce(0) { $0 + $1.errorCount }
    }
}
