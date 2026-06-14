import WebInspectorTransport

@MainActor
struct ConsoleMessageStore {
    private(set) var orderedMessageIDs: [ConsoleMessageIdentifier] = []
    private(set) var warningCount = 0
    private(set) var errorCount = 0
    private var messagesByID: [ConsoleMessageIdentifier: ConsoleMessage] = [:]
    private var lastRepeatableMessageID: ConsoleMessageIdentifier?

    var messages: [ConsoleMessage] {
        orderedMessageIDs.compactMap { messagesByID[$0] }
    }

    var messageSnapshotEntries: [(ConsoleMessageIdentifier, ConsoleMessageSnapshot)] {
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
                    parameters: message.parameters.map(\.payload),
                    stackTrace: message.stackTrace,
                    networkRequestKey: message.networkRequestKey,
                    timestamp: message.timestamp
                )
            )
        }
    }

    private var lastRepeatableMessage: ConsoleMessage? {
        guard let lastRepeatableMessageID else {
            return nil
        }
        return messagesByID[lastRepeatableMessageID]
    }

    func message(for id: ConsoleMessageIdentifier) -> ConsoleMessage? {
        messagesByID[id]
    }

    mutating func append(_ message: ConsoleMessage, canRepeat: Bool) {
        orderedMessageIDs.append(message.id)
        messagesByID[message.id] = message
        if canRepeat {
            lastRepeatableMessageID = message.id
        }
        incrementSeverity(level: message.level, repeatCount: message.repeatCount)
    }

    mutating func updateLastRepeatCount(count: Int, timestamp: Double?) {
        guard let message = lastRepeatableMessage else {
            return
        }
        incrementSeverity(level: message.level, repeatCount: -message.repeatCount)
        message.repeatCount = max(1, count)
        if let timestamp {
            message.timestamp = timestamp
        }
        incrementSeverity(level: message.level, repeatCount: message.repeatCount)
    }

    mutating func removeAll() {
        orderedMessageIDs.removeAll()
        messagesByID.removeAll()
        lastRepeatableMessageID = nil
        warningCount = 0
        errorCount = 0
    }

    func retargeted(to newTargetID: ProtocolTarget.ID) -> ConsoleMessageStore {
        var retargetedStore = ConsoleMessageStore()
        for oldID in orderedMessageIDs {
            guard let message = messagesByID[oldID] else {
                continue
            }
            let newID = ConsoleMessageIdentifier(targetID: newTargetID, ordinal: oldID.ordinal)
            retargetedStore.orderedMessageIDs.append(newID)
            retargetedStore.messagesByID[newID] = ConsoleMessage(
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
                    parameters: message.parameters.map(\.payload),
                    stackTrace: message.stackTrace,
                    networkRequestID: message.networkRequestKey?.requestID,
                    timestamp: message.timestamp
                ),
                parameters: message.parameters.map(Self.displayOnlyParameter)
            )
        }
        if let lastRepeatableMessageID {
            retargetedStore.lastRepeatableMessageID = ConsoleMessageIdentifier(
                targetID: newTargetID,
                ordinal: lastRepeatableMessageID.ordinal
            )
        }
        retargetedStore.recalculateSeverityCounts()
        return retargetedStore
    }

    mutating func mergeCommittedStore(_ committedStore: ConsoleMessageStore) {
        orderedMessageIDs.append(contentsOf: committedStore.orderedMessageIDs)
        orderedMessageIDs.sort()
        for (id, message) in committedStore.messagesByID {
            messagesByID[id] = message
        }
        if let committedLastRepeatableMessageID = committedStore.lastRepeatableMessageID {
            if let currentLastRepeatableMessageID = lastRepeatableMessageID {
                lastRepeatableMessageID = max(currentLastRepeatableMessageID, committedLastRepeatableMessageID)
            } else {
                lastRepeatableMessageID = committedLastRepeatableMessageID
            }
        }
        recalculateSeverityCounts()
    }

    private static func displayOnlyParameter(_ parameter: RuntimeRemoteObject) -> RuntimeRemoteObject {
        RuntimeRemoteObject(
            payload: parameter.payload,
            objectGroup: parameter.objectGroup,
            executionContextKey: parameter.executionContextKey
        )
    }

    private mutating func incrementSeverity(level: ConsoleMessageLevel, repeatCount: Int) {
        switch level {
        case .warning:
            warningCount += repeatCount
        case .error:
            errorCount += repeatCount
        default:
            break
        }
    }

    private mutating func recalculateSeverityCounts() {
        warningCount = 0
        errorCount = 0
        for message in messagesByID.values {
            incrementSeverity(level: message.level, repeatCount: message.repeatCount)
        }
    }
}
