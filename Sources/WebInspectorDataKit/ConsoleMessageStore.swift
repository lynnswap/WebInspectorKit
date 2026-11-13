import Foundation
import Observation
import WebInspectorProxyKit

/// The Console messages of one `WebInspectorContext`, in arrival order.
///
/// Message parameters are remote objects registered in `RuntimeModelStore`
/// with the `.console` owner.
@Observable
@MainActor
final class ConsoleMessageStore {
    /// The messages in arrival order.
    private(set) var messages: [ConsoleMessage] = []

    @ObservationIgnored private let runtime: RuntimeModelStore
    @ObservationIgnored private var messagesByID: [ConsoleMessage.ID: ConsoleMessage] = [:]
    @ObservationIgnored private var lastMessageID: ConsoleMessage.ID?
    @ObservationIgnored private var lastMessageIDByTargetID: [WebInspectorTarget.ID: ConsoleMessage.ID] = [:]
    @ObservationIgnored private var nextMessageOrdinal = 0
    @ObservationIgnored private let changeRelay = WebInspectorAsyncStreamRelay<WebInspectorCollectionChange<ConsoleMessage>>()

    init(runtime: RuntimeModelStore) {
        self.runtime = runtime
    }

    func message(for id: ConsoleMessage.ID) -> ConsoleMessage? {
        messagesByID[id]
    }

    /// The changes to `messages`, starting from the moment of the call.
    var changes: AsyncStream<WebInspectorCollectionChange<ConsoleMessage>> {
        changeRelay.makeStream()
    }

    // MARK: - Events

    func apply(
        _ event: Console.Event,
        targetID: WebInspectorTarget.ID?,
        page: WebInspectorTarget?,
        pageGeneration: Int
    ) {
        switch event {
        case let .messageAdded(message):
            applyMessageAdded(
                message,
                targetID: targetID,
                page: page,
                pageGeneration: pageGeneration
            )
        case let .messageRepeatCountUpdated(count, timestamp):
            let repeatedMessageID: ConsoleMessage.ID?
            if let targetID {
                repeatedMessageID = lastMessageIDByTargetID[targetID]
            } else {
                repeatedMessageID = lastMessageID
            }
            guard let repeatedMessageID,
                  let message = messagesByID[repeatedMessageID] else {
                WebInspectorDataKitLog.debug(
                    "event skipped: Console.messageRepeatCountUpdated arrived before any tracked message"
                )
                return
            }
            message.updateRepeatCount(count, timestamp: timestamp)
            changeRelay.yield(.updated([message]))
        case .messagesCleared:
            // WebKit releases its "console" Runtime object group before
            // emitting this event. DataKit owns only the local registrations.
            clear(targetID: targetID)
        case .unknown:
            break
        }
    }

    /// Removes the messages of `targetID`, or every message when it is nil,
    /// together with the remote objects only those messages referenced.
    func clear(targetID: WebInspectorTarget.ID? = nil) {
        guard let targetID else {
            removeAllMessages()
            runtime.unregisterObjects(owner: .console)
            changeRelay.yield(.removedAll)
            return
        }
        let removedMessages = messages.filter { $0.targetID == targetID }
        guard removedMessages.isEmpty == false else {
            lastMessageIDByTargetID[targetID] = nil
            return
        }
        let removedIDs = Set(removedMessages.map(\.id))
        for id in removedIDs {
            messagesByID[id] = nil
        }
        messages.removeAll { removedIDs.contains($0.id) }
        if let lastMessageID, removedIDs.contains(lastMessageID) {
            self.lastMessageID = messages.last?.id
        }
        lastMessageIDByTargetID[targetID] = nil
        unregisterUnreferencedParameters(of: removedMessages)
        changeRelay.yield(.removed(removedMessages))
    }

    /// Removes every message before WebKit replays the Console log. The
    /// caller has already cleared the Runtime store, so no remote object is
    /// left to unregister.
    func resetBeforeReplay() {
        removeAllMessages()
        changeRelay.yield(.removedAll)
    }

    private func applyMessageAdded(
        _ payload: Console.Message,
        targetID: WebInspectorTarget.ID?,
        page: WebInspectorTarget?,
        pageGeneration: Int
    ) {
        let id = ConsoleMessage.ID(nextMessageOrdinal)
        nextMessageOrdinal += 1
        let parameters = payload.parameters.map { parameter in
            let wireTargetID = parameter.id?.targetScopeRawValue.map(WebInspectorTarget.ID.init)
                ?? targetID
                ?? .currentPage
            let authority = runtime.contextlessAuthority(
                forWireTargetID: wireTargetID,
                page: page,
                pageGeneration: pageGeneration
            )
            return runtime.registerObject(
                parameter,
                owner: .console,
                authority: authority
            )
        }
        let message = ConsoleMessage(
            id: id,
            message: payload,
            parameters: parameters,
            targetID: targetID
        )
        messagesByID[id] = message
        messages.append(message)
        lastMessageID = id
        if let targetID {
            lastMessageIDByTargetID[targetID] = id
        }
        changeRelay.yield(.inserted([message]))
    }

    private func removeAllMessages() {
        messagesByID = [:]
        messages = []
        lastMessageID = nil
        lastMessageIDByTargetID = [:]
    }

    private func unregisterUnreferencedParameters(of removedMessages: [ConsoleMessage]) {
        let removedObjectIDs = Set(removedMessages.flatMap(\.parameters).map(\.id))
        guard removedObjectIDs.isEmpty == false else {
            return
        }
        let remainingObjectIDs = Set(messagesByID.values.flatMap(\.parameters).map(\.id))
        for objectID in removedObjectIDs.subtracting(remainingObjectIDs) {
            guard let object = runtime.object(for: objectID) else {
                continue
            }
            runtime.unregisterObject(object, owner: .console)
        }
    }
}
