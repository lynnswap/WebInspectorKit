import WebInspectorCoreDOMCSS
import WebInspectorCoreRuntime
import WebInspectorCoreSupport
import WebInspectorTransport

extension ConsoleSession {
    @MainActor
    struct MessageStore {
        private(set) var orderedMessageIDs: [ConsoleMessage.ID] = []
        private(set) var warningCount = 0
        private(set) var errorCount = 0
        private var messagesByID: [ConsoleMessage.ID: ConsoleMessage] = [:]
        private var lastRepeatableMessageID: ConsoleMessage.ID?

        var messages: [ConsoleMessage] {
            orderedMessageIDs.compactMap { messagesByID[$0] }
        }

        var messageSnapshotEntries: [(ConsoleMessage.ID, ConsoleMessage.Snapshot)] {
            messagesByID.map { id, message in
                (
                    id,
                    ConsoleMessage.Snapshot(
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

        func message(for id: ConsoleMessage.ID) -> ConsoleMessage? {
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

        func retargeted(to newTargetID: ProtocolTarget.ID) -> ConsoleSession.MessageStore {
            var retargetedStore = ConsoleSession.MessageStore()
            for oldID in orderedMessageIDs {
                guard let message = messagesByID[oldID] else {
                    continue
                }
                let newID = ConsoleMessage.ID(targetID: newTargetID, ordinal: oldID.ordinal)
                retargetedStore.orderedMessageIDs.append(newID)
                retargetedStore.messagesByID[newID] = ConsoleMessage(
                    id: newID,
                    targetID: newTargetID,
                    payload: ConsoleMessage.Payload(
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
                retargetedStore.lastRepeatableMessageID = ConsoleMessage.ID(
                    targetID: newTargetID,
                    ordinal: lastRepeatableMessageID.ordinal
                )
            }
            retargetedStore.recalculateSeverityCounts()
            return retargetedStore
        }

        mutating func mergeCommittedStore(_ committedStore: ConsoleSession.MessageStore) {
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

        private mutating func incrementSeverity(level: ConsoleMessage.Level, repeatCount: Int) {
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
}
