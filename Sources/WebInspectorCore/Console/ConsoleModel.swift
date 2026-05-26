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
package final class ConsoleSession {
    package private(set) var warningCount: Int
    package private(set) var errorCount: Int

    @ObservationIgnored private var nextMessageOrdinal: UInt64
    @ObservationIgnored private var orderedMessageIDs: [ConsoleMessageIdentifier]
    @ObservationIgnored private var messagesByID: [ConsoleMessageIdentifier: ConsoleMessage]
    @ObservationIgnored private var lastRepeatableMessageIDByTargetID: [ProtocolTargetIdentifier: ConsoleMessageIdentifier]
    @ObservationIgnored private var warningCountByTargetID: [ProtocolTargetIdentifier: Int]
    @ObservationIgnored private var errorCountByTargetID: [ProtocolTargetIdentifier: Int]
    @ObservationIgnored private var lastClearReasonByTargetID: [ProtocolTargetIdentifier: ConsoleClearReason]
    @ObservationIgnored private var unsupportedCommandsByTargetID: [ProtocolTargetIdentifier: Set<String>]

    package init() {
        warningCount = 0
        errorCount = 0
        nextMessageOrdinal = 0
        orderedMessageIDs = []
        messagesByID = [:]
        lastRepeatableMessageIDByTargetID = [:]
        warningCountByTargetID = [:]
        errorCountByTargetID = [:]
        lastClearReasonByTargetID = [:]
        unsupportedCommandsByTargetID = [:]
    }

    package func reset() {
        warningCount = 0
        errorCount = 0
        nextMessageOrdinal = 0
        orderedMessageIDs.removeAll()
        messagesByID.removeAll()
        lastRepeatableMessageIDByTargetID.removeAll()
        warningCountByTargetID.removeAll()
        errorCountByTargetID.removeAll()
        lastClearReasonByTargetID.removeAll()
        unsupportedCommandsByTargetID.removeAll()
    }

    package var messages: [ConsoleMessage] {
        orderedMessageIDs.compactMap { messagesByID[$0] }
    }

    package func message(for id: ConsoleMessageIdentifier) -> ConsoleMessage? {
        messagesByID[id]
    }

    package func snapshot() -> ConsoleSessionSnapshot {
        ConsoleSessionSnapshot(
            orderedMessageIDs: orderedMessageIDs,
            messagesByID: messagesByID.mapValues { message in
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
            },
            warningCount: warningCount,
            errorCount: errorCount,
            warningCountByTargetID: warningCountByTargetID,
            errorCountByTargetID: errorCountByTargetID,
            lastClearReasonByTargetID: lastClearReasonByTargetID,
            unsupportedCommandsByTargetID: unsupportedCommandsByTargetID
        )
    }

    @discardableResult
    package func applyMessageAdded(_ payload: ConsoleMessagePayload, targetID: ProtocolTargetIdentifier) -> ConsoleMessageIdentifier {
        nextMessageOrdinal &+= 1
        let id = ConsoleMessageIdentifier(targetID: targetID, ordinal: nextMessageOrdinal)
        let message = ConsoleMessage(id: id, targetID: targetID, payload: payload)
        orderedMessageIDs.append(id)
        messagesByID[id] = message
        if payload.type != .clear {
            lastRepeatableMessageIDByTargetID[targetID] = id
        }
        recalculateSeverityCounts()
        return id
    }

    package func applyRepeatCountUpdated(count: Int, timestamp: Double?, targetID: ProtocolTargetIdentifier) {
        guard let messageID = lastRepeatableMessageIDByTargetID[targetID],
              let message = messagesByID[messageID] else {
            return
        }
        message.repeatCount = max(1, count)
        if let timestamp {
            message.timestamp = timestamp
        }
        recalculateSeverityCounts()
    }

    package func applyMessagesCleared(reason: ConsoleClearReason, targetID: ProtocolTargetIdentifier) {
        lastClearReasonByTargetID[targetID] = reason
        let removedIDs = Set(orderedMessageIDs.filter { $0.targetID == targetID })
        orderedMessageIDs.removeAll { removedIDs.contains($0) }
        for id in removedIDs {
            messagesByID.removeValue(forKey: id)
        }
        lastRepeatableMessageIDByTargetID.removeValue(forKey: targetID)
        recalculateSeverityCounts()
    }

    package func applyTargetDestroyed(_ targetID: ProtocolTargetIdentifier) {
        let removedIDs = Set(orderedMessageIDs.filter { $0.targetID == targetID })
        orderedMessageIDs.removeAll { removedIDs.contains($0) }
        for id in removedIDs {
            messagesByID.removeValue(forKey: id)
        }
        lastRepeatableMessageIDByTargetID.removeValue(forKey: targetID)
        warningCountByTargetID.removeValue(forKey: targetID)
        errorCountByTargetID.removeValue(forKey: targetID)
        lastClearReasonByTargetID.removeValue(forKey: targetID)
        unsupportedCommandsByTargetID.removeValue(forKey: targetID)
        recalculateSeverityCounts()
    }

    package func applyTargetCommitted(oldTargetID: ProtocolTargetIdentifier?, newTargetID: ProtocolTargetIdentifier) {
        guard let oldTargetID else {
            return
        }
        var movedIDs: [ConsoleMessageIdentifier: ConsoleMessageIdentifier] = [:]
        for id in orderedMessageIDs where id.targetID == oldTargetID {
            movedIDs[id] = ConsoleMessageIdentifier(targetID: newTargetID, ordinal: id.ordinal)
        }
        guard movedIDs.isEmpty == false else {
            if let reason = lastClearReasonByTargetID.removeValue(forKey: oldTargetID) {
                lastClearReasonByTargetID[newTargetID] = reason
            }
            if let unsupported = unsupportedCommandsByTargetID.removeValue(forKey: oldTargetID) {
                unsupportedCommandsByTargetID[newTargetID, default: []].formUnion(unsupported)
            }
            return
        }
        orderedMessageIDs = orderedMessageIDs.map { movedIDs[$0] ?? $0 }
        for (oldID, newID) in movedIDs {
            if let oldMessage = messagesByID.removeValue(forKey: oldID) {
                messagesByID[newID] = ConsoleMessage(
                    id: newID,
                    targetID: newTargetID,
                    payload: ConsoleMessagePayload(
                        source: oldMessage.source,
                        level: oldMessage.level,
                        text: oldMessage.text,
                        type: oldMessage.type,
                        url: oldMessage.url,
                        line: oldMessage.line,
                        column: oldMessage.column,
                        repeatCount: oldMessage.repeatCount,
                        parameters: oldMessage.parameters,
                        stackTrace: oldMessage.stackTrace,
                        networkRequestID: oldMessage.networkRequestKey?.requestID,
                        timestamp: oldMessage.timestamp
                    )
                )
            }
        }
        if let oldLastID = lastRepeatableMessageIDByTargetID.removeValue(forKey: oldTargetID) {
            lastRepeatableMessageIDByTargetID[newTargetID] = movedIDs[oldLastID] ?? oldLastID
        }
        if let reason = lastClearReasonByTargetID.removeValue(forKey: oldTargetID) {
            lastClearReasonByTargetID[newTargetID] = reason
        }
        if let unsupported = unsupportedCommandsByTargetID.removeValue(forKey: oldTargetID) {
            unsupportedCommandsByTargetID[newTargetID, default: []].formUnion(unsupported)
        }
        recalculateSeverityCounts()
    }

    package func markCommandUnsupported(_ method: String, targetID: ProtocolTargetIdentifier) {
        unsupportedCommandsByTargetID[targetID, default: []].insert(method)
    }

    package func supportsCommand(_ method: String, targetID: ProtocolTargetIdentifier) -> Bool {
        unsupportedCommandsByTargetID[targetID]?.contains(method) != true
    }

    package func enableIntent(targetID: ProtocolTargetIdentifier) -> ConsoleCommandIntent {
        .enable(targetID: targetID)
    }

    private func recalculateSeverityCounts() {
        var nextWarningCount = 0
        var nextErrorCount = 0
        var nextWarningCountByTargetID: [ProtocolTargetIdentifier: Int] = [:]
        var nextErrorCountByTargetID: [ProtocolTargetIdentifier: Int] = [:]

        for message in messagesByID.values {
            switch message.level {
            case .warning:
                nextWarningCount += message.repeatCount
                nextWarningCountByTargetID[message.targetID, default: 0] += message.repeatCount
            case .error:
                nextErrorCount += message.repeatCount
                nextErrorCountByTargetID[message.targetID, default: 0] += message.repeatCount
            default:
                break
            }
        }

        warningCount = nextWarningCount
        errorCount = nextErrorCount
        warningCountByTargetID = nextWarningCountByTargetID
        errorCountByTargetID = nextErrorCountByTargetID
    }
}
