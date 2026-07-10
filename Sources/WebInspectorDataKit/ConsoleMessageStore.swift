import WebInspectorProxyKit

/// Owns Console message identity, order, query projection, and publication.
///
/// Runtime-object membership and protocol commands remain in
/// `WebInspectorContext`; clear operations return explicit effects for that
/// owner to apply. The store never retains an actor token or starts a task.
package final class ConsoleMessageStore {
    package enum RuntimeObjectGroupRelease: Equatable {
        case currentPage
        case target(WebInspectorTarget.ID)
    }

    package struct Effects {
        package var runtimeObjectsToUnregister: [RuntimeObject] = []
        package var clearedAllMessages = false
        package var runtimeObjectGroupRelease: RuntimeObjectGroupRelease?
    }

#if DEBUG
    package struct PerformanceCounters: Equatable {
        package var fullModelProjectionCount = 0
        package var fullRecordProjectionCount = 0
        package var incrementalRecordProjectionCount = 0
        package var resultIdentityLookupCount = 0
    }
#endif

    private var messagesByID: [ConsoleMessage.ID: ConsoleMessage]
    private var orderedMessageIDs: [ConsoleMessage.ID]
    private var orderIndicesByID: [ConsoleMessage.ID: Int]
    private var lastMessageID: ConsoleMessage.ID?
    private var lastMessageIDByTargetID: [WebInspectorTarget.ID: ConsoleMessage.ID]
    private var nextMessageOrdinal: Int
    private let queryIndex: ConsoleMessageIndex
    private var queryIndexSequence: UInt64
    private var queryIndexNeedsRebuild: Bool
    private var fetchedResults: [WeakWebInspectorFetchedResults<ConsoleMessage>]
#if DEBUG
    private var performanceCounters: PerformanceCounters
#endif

    package init() {
        messagesByID = [:]
        orderedMessageIDs = []
        orderIndicesByID = [:]
        lastMessageID = nil
        lastMessageIDByTargetID = [:]
        nextMessageOrdinal = 0
        queryIndex = ConsoleMessageIndex()
        queryIndexSequence = 0
        queryIndexNeedsRebuild = false
        fetchedResults = []
#if DEBUG
        performanceCounters = PerformanceCounters()
#endif
    }

#if DEBUG
    package var performanceCountersForTesting: PerformanceCounters {
        performanceCounters
    }

    package func resetPerformanceCountersForTesting(
        isolation: isolated (any Actor) = #isolation
    ) {
        _ = isolation
        performanceCounters = PerformanceCounters()
    }
#endif

    package func message(
        for id: ConsoleMessage.ID,
        isolation: isolated (any Actor) = #isolation
    ) -> ConsoleMessage? {
        _ = isolation
        return messagesByID[id]
    }

    package func register(
        _ results: WebInspectorFetchedResults<ConsoleMessage>,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor) = #isolation
    ) {
        let plan = ConsoleMessageQueryPlan(descriptor: results.fetchDescriptor)
        results.setConsoleItems(
            currentMessages(isolation: isolation),
            plan: plan,
            indexSequence: queryIndexSequence,
            lookup: { id in self.messagesByID[id] }
        )
        fetchedResults.append(WeakWebInspectorFetchedResults(results))
    }

    package func updateFetchDescriptor(
        _ descriptor: WebInspectorFetchDescriptor<ConsoleMessage>,
        for results: WebInspectorFetchedResults<ConsoleMessage>,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor) = #isolation
    ) {
        let plan = ConsoleMessageQueryPlan(descriptor: descriptor)
        results.applyConsoleFetchDescriptor(
            descriptor,
            plan: plan,
            messages: currentMessages(isolation: isolation),
            indexSequence: queryIndexSequence,
            lookup: { id in self.messagesByID[id] }
        )
    }

    package func apply(
        _ event: Console.Event,
        targetID: WebInspectorTarget.ID?,
        modelContext: WebInspectorContext,
        registerRuntimeObject: (Runtime.RemoteObject) -> RuntimeObject,
        isolation: isolated (any Actor) = #isolation
    ) async -> Effects {
        switch event {
        case let .messageAdded(payload):
            let parameters = payload.parameters.map(registerRuntimeObject)
            await insertMessage(
                payload,
                parameters: parameters,
                targetID: targetID,
                modelContext: modelContext,
                isolation: isolation
            )
            return Effects()
        case let .messageRepeatCountUpdated(count, timestamp):
            await updateRepeatCount(
                count,
                timestamp: timestamp,
                targetID: targetID,
                modelContext: modelContext,
                isolation: isolation
            )
            return Effects()
        case .messagesCleared:
            return clear(targetID: targetID, modelContext: modelContext, isolation: isolation)
        case .unknown:
            return Effects()
        }
    }

    package func resetForReplay(
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor) = #isolation
    ) {
        _ = removeMessages(targetID: nil, isolation: isolation)
        refreshAllResults(modelContext: modelContext, isolation: isolation)
    }

    package func clearForLifecycle(
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor) = #isolation
    ) -> Effects {
        _ = removeMessages(targetID: nil, isolation: isolation)
        refreshAllResults(modelContext: modelContext, isolation: isolation)
        return Effects(
            clearedAllMessages: true
        )
    }

    private func insertMessage(
        _ payload: Console.Message,
        parameters: [RuntimeObject],
        targetID: WebInspectorTarget.ID?,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor)
    ) async {
        precondition(nextMessageOrdinal < Int.max, "ConsoleMessage identity ordinal overflowed.")
        let id = ConsoleMessage.ID(nextMessageOrdinal)
        nextMessageOrdinal += 1
        let message = ConsoleMessage(
            id: id,
            message: payload,
            parameters: parameters,
            targetID: targetID,
            modelContext: modelContext
        )
        messagesByID[id] = message
        orderIndicesByID[id] = orderedMessageIDs.count
        orderedMessageIDs.append(id)
        lastMessageID = id
        if let targetID {
            lastMessageIDByTargetID[targetID] = id
        }
        await notifyMessageInserted(message, modelContext: modelContext, isolation: isolation)
    }

    private func updateRepeatCount(
        _ count: Int,
        timestamp: Double?,
        targetID: WebInspectorTarget.ID?,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor)
    ) async {
        let candidateID: ConsoleMessage.ID?
        if let targetID {
            candidateID = lastMessageIDByTargetID[targetID]
        } else {
            candidateID = lastMessageID
        }
        guard let candidateID,
              let message = messagesByID[candidateID] else {
            skipEvent("Console.messageRepeatCountUpdated arrived before any tracked message")
            return
        }
        message.updateRepeatCount(count, timestamp: timestamp)
        await notifyMessageMutated(message, modelContext: modelContext, isolation: isolation)
    }

    private func clear(
        targetID: WebInspectorTarget.ID?,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor)
    ) -> Effects {
        let removedMessages = removeMessages(targetID: targetID, isolation: isolation)
        let runtimeObjectsToUnregister = targetID == nil
            ? []
            : unreferencedRuntimeObjects(
                from: removedMessages,
                isolation: isolation
            )
        refreshAllResults(modelContext: modelContext, isolation: isolation)
        return Effects(
            runtimeObjectsToUnregister: runtimeObjectsToUnregister,
            clearedAllMessages: targetID == nil,
            runtimeObjectGroupRelease: targetID.map(RuntimeObjectGroupRelease.target) ?? .currentPage
        )
    }

    @discardableResult
    private func removeMessages(
        targetID: WebInspectorTarget.ID?,
        isolation: isolated (any Actor)
    ) -> [ConsoleMessage] {
        _ = isolation
        queryIndexNeedsRebuild = true
        guard let targetID else {
            let removedMessages = Array(messagesByID.values)
            messagesByID = [:]
            orderedMessageIDs = []
            orderIndicesByID = [:]
            lastMessageID = nil
            lastMessageIDByTargetID = [:]
            return removedMessages
        }

        let removedMessages = messagesByID.values.filter { $0.targetID == targetID }
        guard removedMessages.isEmpty == false else {
            lastMessageIDByTargetID[targetID] = nil
            return []
        }
        let removedIDs = Set(removedMessages.map(\.id))
        for id in removedIDs {
            messagesByID[id] = nil
            orderIndicesByID[id] = nil
        }
        orderedMessageIDs.removeAll { removedIDs.contains($0) }
        rebuildOrderIndices(isolation: isolation)
        if let lastMessageID, removedIDs.contains(lastMessageID) {
            self.lastMessageID = orderedMessageIDs.last
        }
        lastMessageIDByTargetID[targetID] = orderedMessageIDs.last { id in
            messagesByID[id]?.targetID == targetID
        }
        return removedMessages
    }

    private func unreferencedRuntimeObjects(
        from removedMessages: [ConsoleMessage],
        isolation: isolated (any Actor)
    ) -> [RuntimeObject] {
        _ = isolation
        let removedObjectsByID = Dictionary(
            removedMessages.flatMap(\.parameters).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard removedObjectsByID.isEmpty == false else {
            return []
        }
        let remainingObjectIDs = Set(messagesByID.values.flatMap(\.parameters).map(\.id))
        return removedObjectsByID.compactMap { id, object in
            remainingObjectIDs.contains(id) ? nil : object
        }
    }

    private func rebuildOrderIndices(isolation: isolated (any Actor)) {
        _ = isolation
        orderIndicesByID = Dictionary(
            uniqueKeysWithValues: orderedMessageIDs.enumerated().map { index, id in
                (id, index)
            }
        )
    }

    private func currentMessages(isolation: isolated (any Actor)) -> [ConsoleMessage] {
        _ = isolation
#if DEBUG
        performanceCounters.fullModelProjectionCount += orderedMessageIDs.count
#endif
        return orderedMessageIDs.compactMap { messagesByID[$0] }
    }

    private func currentRecordInputs(
        isolation: isolated (any Actor)
    ) -> [ConsoleMessageRecordInput] {
        _ = isolation
#if DEBUG
        performanceCounters.fullRecordProjectionCount += orderedMessageIDs.count
#endif
        return orderedMessageIDs.enumerated().compactMap { index, id in
            messagesByID[id].map { ConsoleMessageRecordInput(message: $0, orderIndex: index) }
        }
    }

    private func recordInput(
        for message: ConsoleMessage,
        isolation: isolated (any Actor)
    ) -> ConsoleMessageRecordInput {
        _ = isolation
#if DEBUG
        performanceCounters.incrementalRecordProjectionCount += 1
#endif
        let orderIndex = orderIndicesByID[message.id] ?? orderedMessageIDs.count
        return ConsoleMessageRecordInput(message: message, orderIndex: orderIndex)
    }

    private func isCurrent(
        _ message: ConsoleMessage,
        isolation: isolated (any Actor)
    ) -> Bool {
        _ = isolation
        return messagesByID[message.id] === message
    }

    private func nextQueryIndexSequence(isolation: isolated (any Actor)) -> UInt64 {
        _ = isolation
        precondition(
            queryIndexSequence < UInt64.max,
            "ConsoleMessageIndex mutation sequence overflowed."
        )
        queryIndexSequence += 1
        return queryIndexSequence
    }

    private func syncQueryIndexIfNeeded(isolation: isolated (any Actor)) async {
        guard queryIndexNeedsRebuild else {
            return
        }
        queryIndexNeedsRebuild = false
        let sequence = nextQueryIndexSequence(isolation: isolation)
        let inputs = currentRecordInputs(isolation: isolation)
        await queryIndex.replace(with: inputs, sequence: sequence)
    }

    private func notifyMessageInserted(
        _ message: ConsoleMessage,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor)
    ) async {
        await syncQueryIndexIfNeeded(isolation: isolation)
        guard isCurrent(message, isolation: isolation) else {
            return
        }
        let sequence = nextQueryIndexSequence(isolation: isolation)
        let input = recordInput(for: message, isolation: isolation)
        await queryIndex.upsert(input, sequence: sequence)
        guard isCurrent(message, isolation: isolation) else {
            return
        }
        await applyResultDeltas(
            for: message,
            inserted: true,
            modelContext: modelContext,
            isolation: isolation
        )
    }

    private func notifyMessageMutated(
        _ message: ConsoleMessage,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor)
    ) async {
        await syncQueryIndexIfNeeded(isolation: isolation)
        guard isCurrent(message, isolation: isolation) else {
            return
        }
        let sequence = nextQueryIndexSequence(isolation: isolation)
        let input = recordInput(for: message, isolation: isolation)
        await queryIndex.upsert(input, sequence: sequence)
        guard isCurrent(message, isolation: isolation) else {
            return
        }
        await applyResultDeltas(
            for: message,
            inserted: false,
            modelContext: modelContext,
            isolation: isolation
        )
    }

    private func applyResultDeltas(
        for message: ConsoleMessage,
        inserted: Bool,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor)
    ) async {
        pruneFetchedResults(isolation: isolation)
        for registration in fetchedResults {
            guard let results = registration.value else {
                continue
            }
            let plan = results.currentConsoleQueryPlan()
            if plan.requiresModelQuery {
                if inserted {
                    results.insertConsoleMessage(
                        message,
                        lookup: { id in self.messagesByID[id] }
                    )
                } else {
                    results.refreshConsoleMessageAfterMutation(
                        message,
                        lookup: { id in self.messagesByID[id] }
                    )
                }
                continue
            }
            let oldSnapshot = results.consoleSnapshotForDelta
            let resultTopologyRevision = results.topologyRevision
            let resultIndexSequence = results.consoleIndexSequenceForDelta
            let indexSequence = queryIndexSequence
            let delta = await queryIndex.delta(
                plan: plan,
                sectionBy: results.sectionBy,
                oldSnapshot: oldSnapshot,
                changedSince: resultIndexSequence
            )
            guard queryIndexSequence == indexSequence,
                  results.topologyRevision == resultTopologyRevision,
                  results.consoleSnapshotForDelta == oldSnapshot else {
                continue
            }
            results.applyConsoleDelta(
                delta,
                lookup: { id in self.messageForResult(id, isolation: isolation) }
            )
        }
    }

    private func refreshAllResults(
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor)
    ) {
        pruneFetchedResults(isolation: isolation)
        let messages = currentMessages(isolation: isolation)
        for registration in fetchedResults {
            guard let results = registration.value else {
                continue
            }
            let plan = ConsoleMessageQueryPlan(descriptor: results.fetchDescriptor)
            results.setConsoleItems(
                messages,
                plan: plan,
                indexSequence: queryIndexSequence,
                lookup: { id in self.messagesByID[id] }
            )
        }
    }

    private func messageForResult(
        _ id: ConsoleMessage.ID,
        isolation: isolated (any Actor)
    ) -> ConsoleMessage? {
        _ = isolation
#if DEBUG
        performanceCounters.resultIdentityLookupCount += 1
#endif
        return messagesByID[id]
    }

    private func pruneFetchedResults(isolation: isolated (any Actor)) {
        _ = isolation
        fetchedResults.removeAll { $0.value == nil }
    }

    private func skipEvent(_ reason: String) {
        WebInspectorDataKitLog.debug("event skipped: \(reason)")
    }
}
