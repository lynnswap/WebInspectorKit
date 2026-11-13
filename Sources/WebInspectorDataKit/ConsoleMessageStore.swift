import Foundation
import WebInspectorProxyKit

/// Console messages and their fetched-results registrations for one
/// `WebInspectorContext`.
///
/// Message parameters are remote objects registered in `RuntimeModelStore`
/// with the `.console` owner. Calls must come from the context's actor.
final class ConsoleMessageStore {
    private let runtime: RuntimeModelStore
    private var messagesByID: [ConsoleMessage.ID: ConsoleMessage] = [:]
    private var orderedMessageIDs: [ConsoleMessage.ID] = []
    private var lastMessageID: ConsoleMessage.ID?
    private var lastMessageIDByTargetID: [WebInspectorTarget.ID: ConsoleMessage.ID] = [:]
    private var nextMessageOrdinal = 0
    private var fetchedResults: [WeakWebInspectorFetchedResults<ConsoleMessage>] = []

    init(runtime: RuntimeModelStore) {
        self.runtime = runtime
    }

    func message(for id: ConsoleMessage.ID) -> ConsoleMessage? {
        messagesByID[id]
    }

    // MARK: - Events

    func apply(
        _ event: Console.Event,
        targetID: WebInspectorTarget.ID?,
        page: WebInspectorTarget?,
        pageGeneration: Int,
        modelContext: WebInspectorContext
    ) {
        switch event {
        case let .messageAdded(message):
            applyMessageAdded(
                message,
                targetID: targetID,
                page: page,
                pageGeneration: pageGeneration,
                modelContext: modelContext
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
            publishMessages(updatedItemIDs: [message.id])
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
            publishMessages()
            return
        }
        let removedMessages = messagesByID.values.filter { $0.targetID == targetID }
        guard removedMessages.isEmpty == false else {
            lastMessageIDByTargetID[targetID] = nil
            publishMessages()
            return
        }
        let removedIDs = Set(removedMessages.map(\.id))
        for id in removedIDs {
            messagesByID[id] = nil
        }
        orderedMessageIDs.removeAll { removedIDs.contains($0) }
        if let lastMessageID, removedIDs.contains(lastMessageID) {
            self.lastMessageID = orderedMessageIDs.last
        }
        lastMessageIDByTargetID[targetID] = orderedMessageIDs.last { id in
            messagesByID[id]?.targetID == targetID
        }
        unregisterUnreferencedParameters(of: removedMessages)
        publishMessages()
    }

    /// Removes every message before WebKit replays the Console log. The
    /// caller has already cleared the Runtime store, so no remote object is
    /// left to unregister.
    func resetBeforeReplay() {
        removeAllMessages()
        publishMessages()
    }

    private func applyMessageAdded(
        _ payload: Console.Message,
        targetID: WebInspectorTarget.ID?,
        page: WebInspectorTarget?,
        pageGeneration: Int,
        modelContext: WebInspectorContext
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
                authority: authority,
                modelContext: modelContext
            )
        }
        let message = ConsoleMessage(
            id: id,
            message: payload,
            parameters: parameters,
            targetID: targetID,
            modelContext: modelContext
        )
        messagesByID[id] = message
        orderedMessageIDs.append(id)
        lastMessageID = id
        if let targetID {
            lastMessageIDByTargetID[targetID] = id
        }
        publishMessages()
    }

    private func removeAllMessages() {
        messagesByID = [:]
        orderedMessageIDs = []
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

    // MARK: - Fetched results

    func makeFetchedResults(
        for query: ConsoleMessageQuery,
        modelContext: WebInspectorContext
    ) -> WebInspectorFetchedResults<ConsoleMessage> {
        let results = WebInspectorFetchedResults<ConsoleMessage>(
            query: query,
            modelContext: modelContext
        )
        results.setItems(messages(for: query))
        fetchedResults.append(WeakWebInspectorFetchedResults(results))
        return results
    }

    func updateQuery(
        _ query: ConsoleMessageQuery,
        for results: WebInspectorFetchedResults<ConsoleMessage>
    ) {
        results.applyConsoleQuery(query, items: messages(for: query))
    }

    func invalidateFetchedResultsRegistrations() {
        let registeredResults = fetchedResults.compactMap(\.value)
        fetchedResults.removeAll()
        for results in registeredResults {
            results.invalidateRegistration()
        }
    }

    private func messages(for query: ConsoleMessageQuery) -> [ConsoleMessage] {
        var items = orderedMessageIDs.compactMap { messagesByID[$0] }
        if let filter = query.filter {
            items = items.filter(filter.matches)
        }
        if query.sortBy.isEmpty == false {
            items.sort { lhs, rhs in
                for sort in query.sortBy {
                    switch sort.compare(lhs, rhs) {
                    case .orderedAscending:
                        return true
                    case .orderedDescending:
                        return false
                    case .orderedSame:
                        continue
                    }
                }
                return lhs.id < rhs.id
            }
        }
        let lowerBound = min(query.fetchOffsetAsInt, items.count)
        let remainingCount = items.count - lowerBound
        let visibleCount = min(query.fetchLimitAsInt ?? remainingCount, remainingCount)
        let upperBound = lowerBound + visibleCount
        return Array(items[lowerBound..<upperBound])
    }

    private func publishMessages(updatedItemIDs: Set<ConsoleMessage.ID> = []) {
        fetchedResults.removeAll { $0.value == nil }
        for registration in fetchedResults {
            guard let results = registration.value else {
                continue
            }
            results.setItems(messages(for: results.consoleQuery), updatedItemIDs: updatedItemIDs)
        }
    }
}
