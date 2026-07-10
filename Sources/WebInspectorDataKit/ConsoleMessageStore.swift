import WebInspectorProxyKit

/// Owns Console message identity, order, query projection, and publication.
///
/// Runtime-object membership remains in `WebInspectorModelContext`; clear
/// operations return explicit ownership effects for that owner to apply. The
/// store never retains an actor token or starts a task.
package final class ConsoleMessageStore {
    package struct IndexWork: Sendable {
        fileprivate enum Action: Sendable {
            case replace(
                inputs: [ConsoleMessageRecordInput],
                sequence: UInt64,
                sourceEpoch: UInt64
            )
            case upsert(input: ConsoleMessageRecordInput, sequence: UInt64)
        }

        fileprivate let index: ConsoleMessageIndex
        fileprivate let actions: [Action]

        package nonisolated(nonsending) func run() async -> IndexResult {
            var deliveries: [ConsoleMessageIndex.QueryDelivery] = []
            for action in actions {
                switch action {
                case let .replace(inputs, sequence, sourceEpoch):
                    deliveries += await index.replace(
                        with: inputs,
                        sequence: sequence,
                        sourceEpoch: sourceEpoch
                    )
                case let .upsert(input, sequence):
                    deliveries += await index.upsert(input, sequence: sequence)
                }
            }
            return IndexResult(deliveries: deliveries)
        }
    }

    package struct IndexResult: Sendable {
        fileprivate let deliveries: [ConsoleMessageIndex.QueryDelivery]
    }

    package struct IndexAcknowledgementWork: Sendable {
        fileprivate struct Entry: Sendable {
            let id: WebInspectorQueryRegistrationID
            let generation: UInt64
            let sourceEpoch: UInt64
            let sequence: UInt64
        }

        fileprivate let index: ConsoleMessageIndex
        fileprivate let entries: [Entry]

        package nonisolated(nonsending) func run() async {
            for entry in entries {
                await index.acknowledge(
                    id: entry.id,
                    generation: entry.generation,
                    sourceEpoch: entry.sourceEpoch,
                    sequence: entry.sequence
                )
            }
        }
    }

    private enum ConcreteQueryBufferDestination {
        case candidate
        case committing
    }

    private struct PendingConcreteQuery {
        var generation: UInt64
        var query: ConsoleQuery
        var projection: ConsoleMessageIndex.QueryProjection?
    }

    private struct ConcreteQueryRegistration {
        var results: WeakWebInspectorFetchedResults<ConsoleMessage>
        var activeGeneration: UInt64
        var activeQuery: ConsoleQuery
        var candidate: PendingConcreteQuery?
        var committing: [UInt64: PendingConcreteQuery]
    }

    package struct Effects {
        package var runtimeObjectsToUnregister: [RuntimeObject] = []
        package var clearedAllMessages = false
    }

    package struct QueryIndexReset: Sendable {
        fileprivate var inputs: [ConsoleMessageRecordInput]
        fileprivate var sequence: UInt64
        fileprivate var sourceEpoch: UInt64
    }

    package struct PreparedModelEvent {
        package let effects: Effects
        package let indexWork: IndexWork?
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
    private var querySourceEpoch: UInt64
    private var nextConcreteQueryRegistrationID: UInt64
    private var initializingConcreteQueries: [
        WebInspectorQueryRegistrationID: PendingConcreteQuery
    ]
    private var concreteQueryRegistrations: [
        WebInspectorQueryRegistrationID: ConcreteQueryRegistration
    ]
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
        querySourceEpoch = 0
        nextConcreteQueryRegistrationID = 0
        initializingConcreteQueries = [:]
        concreteQueryRegistrations = [:]
#if DEBUG
        performanceCounters = PerformanceCounters()
#endif
    }

#if DEBUG
    package var performanceCountersForTesting: PerformanceCounters {
        performanceCounters
    }

    package func resetPerformanceCountersForTesting() {
        performanceCounters = PerformanceCounters()
    }
#endif

    package func message(for id: ConsoleMessage.ID) -> ConsoleMessage? {
        messagesByID[id]
    }

    package nonisolated(nonsending) func results(
        matching query: ConsoleQuery,
        modelContext: WebInspectorModelContext
    ) async throws -> WebInspectorFetchedResults<ConsoleMessage> {
        await syncQueryIndexIfNeeded()
        let id = allocateConcreteQueryRegistrationID()
        let lifetime = WebInspectorQueryRegistrationLifetime()
        let results = WebInspectorFetchedResults<ConsoleMessage>(modelContext: modelContext)
        results.installQueryRegistration(id: id, lifetime: lifetime)
        let generation = results.nextConcreteQueryGeneration()
        initializingConcreteQueries[id] = PendingConcreteQuery(
            generation: generation,
            query: query,
            projection: nil
        )

        let initialProjection: ConsoleMessageIndex.QueryProjection
        do {
            initialProjection = try await queryIndex.register(
                id: id,
                generation: generation,
                query: query,
                lifetime: lifetime,
                minimumSequence: queryIndexSequence
            )
        } catch {
            initializingConcreteQueries[id] = nil
            throw error
        }

        guard var initialization = initializingConcreteQueries.removeValue(forKey: id),
              initialization.generation == generation else {
            preconditionFailure("Console query initialization lost its owner state after index commit.")
        }
        initialization.projection = coalesce(
            initialization.projection,
            with: initialProjection
        )
        let installedProjection = initialization.projection ?? initialProjection
        guard installedProjection.sourceEpoch == querySourceEpoch else {
            throw CancellationError()
        }
        results.installInitialConsoleQuery(
            query,
            generation: generation,
            projection: installedProjection,
            lookup: { id in self.messageForResult(id) }
        )
        concreteQueryRegistrations[id] = ConcreteQueryRegistration(
            results: WeakWebInspectorFetchedResults(results),
            activeGeneration: generation,
            activeQuery: query,
            candidate: nil,
            committing: [:]
        )
        await queryIndex.acknowledge(
            id: id,
            generation: generation,
            sourceEpoch: installedProjection.sourceEpoch,
            sequence: installedProjection.sequence
        )
        return results
    }

    package nonisolated(nonsending) func update(
        _ query: ConsoleQuery,
        for results: WebInspectorFetchedResults<ConsoleMessage>
    ) async throws {
        guard let id = results.concreteQueryRegistrationID else {
            preconditionFailure("Console fetched results are not registered in this store.")
        }
        await syncQueryIndexIfNeeded()
        guard var registration = concreteQueryRegistrations[id],
              registration.results.value === results else {
            preconditionFailure("Console fetched results are not registered in this store.")
        }
        let generation = results.nextConcreteQueryGeneration()
        registration.candidate = PendingConcreteQuery(
            generation: generation,
            query: query,
            projection: nil
        )
        concreteQueryRegistrations[id] = registration

        do {
            let prepared = try await queryIndex.prepareReplacement(
                id: id,
                generation: generation,
                query: query,
                minimumSequence: queryIndexSequence
            )
            buffer(
                prepared,
                for: id,
                generation: generation,
                query: query,
                destination: .candidate
            )
            guard results.isCurrentConcreteQueryGeneration(generation) else {
                throw CancellationError()
            }
            try Task.checkCancellation()
        } catch {
            await queryIndex.discardCandidates(id: id, through: generation)
            clearCandidate(id: id, generation: generation)
            throw error
        }

        guard var beforeCommit = concreteQueryRegistrations[id],
              let candidate = beforeCommit.candidate,
              candidate.generation == generation,
              candidate.projection?.sourceEpoch == querySourceEpoch else {
            await queryIndex.discardCandidates(id: id, through: generation)
            clearCandidate(id: id, generation: generation)
            throw CancellationError()
        }
        beforeCommit.committing[generation] = candidate
        beforeCommit.candidate = nil
        concreteQueryRegistrations[id] = beforeCommit

        guard let committed = await queryIndex.commitReplacement(
            id: id,
            generation: generation
        ) else {
            clearCommitting(id: id, generation: generation)
            throw CancellationError()
        }

        guard var afterCommit = concreteQueryRegistrations[id],
              var pendingPublication = afterCommit.committing.removeValue(forKey: generation) else {
            preconditionFailure("Console query replacement lost committed publication state.")
        }
        pendingPublication.projection = coalesce(
            pendingPublication.projection,
            with: committed
        )
        let publication = pendingPublication.projection ?? committed
        let applied = results.applyConsoleQueryProjection(
            publication,
            query: query,
            generation: generation,
            isReplacement: true,
            lookup: { id in self.messageForResult(id) }
        )
        if generation > afterCommit.activeGeneration {
            afterCommit.activeGeneration = generation
            afterCommit.activeQuery = query
        }
        concreteQueryRegistrations[id] = afterCommit
        if applied {
            await queryIndex.acknowledge(
                id: id,
                generation: generation,
                sourceEpoch: publication.sourceEpoch,
                sequence: publication.sequence
            )
        }
    }

    package func indexWork(for reset: QueryIndexReset) -> IndexWork {
        IndexWork(
            index: queryIndex,
            actions: [
                .replace(
                    inputs: reset.inputs,
                    sequence: reset.sequence,
                    sourceEpoch: reset.sourceEpoch
                )
            ]
        )
    }

    package func prepareModelEvent(
        _ event: Console.Event,
        targetID: WebInspectorTarget.ID?,
        modelContext: WebInspectorModelContext,
        registerRuntimeObject: (Runtime.RemoteObject) -> RuntimeObject
    ) -> PreparedModelEvent {
        switch event {
        case let .messageAdded(payload):
            precondition(nextMessageOrdinal < Int.max, "ConsoleMessage identity ordinal overflowed.")
            let id = ConsoleMessage.ID(nextMessageOrdinal)
            nextMessageOrdinal += 1
            let message = ConsoleMessage(
                id: id,
                message: payload,
                parameters: payload.parameters.map(registerRuntimeObject),
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
            return PreparedModelEvent(
                effects: Effects(),
                indexWork: upsertWork(for: message)
            )
        case let .messageRepeatCountUpdated(count, timestamp):
            let candidateID = targetID.flatMap { lastMessageIDByTargetID[$0] } ?? lastMessageID
            guard let candidateID, let message = messagesByID[candidateID] else {
                skipEvent("Console.messageRepeatCountUpdated arrived before any tracked message")
                return PreparedModelEvent(effects: Effects(), indexWork: nil)
            }
            message.updateRepeatCount(count, timestamp: timestamp)
            return PreparedModelEvent(
                effects: Effects(),
                indexWork: upsertWork(for: message)
            )
        case .messagesCleared:
            let removedMessages = removeMessages(targetID: targetID)
            let objects = targetID == nil
                ? []
                : unreferencedRuntimeObjects(from: removedMessages)
            let reset = targetID == nil
                ? prepareEmptyQueryIndexReset()
                : prepareQueryIndexReset()
            return PreparedModelEvent(
                effects: Effects(
                    runtimeObjectsToUnregister: objects,
                    clearedAllMessages: targetID == nil
                ),
                indexWork: indexWork(for: reset)
            )
        case .unknown:
            return PreparedModelEvent(effects: Effects(), indexWork: nil)
        }
    }

    package func commit(_ result: IndexResult) -> IndexAcknowledgementWork? {
        let entries = applyConcreteDeliveriesSynchronously(result.deliveries)
        guard !entries.isEmpty else {
            return nil
        }
        return IndexAcknowledgementWork(index: queryIndex, entries: entries)
    }

    private func upsertWork(for message: ConsoleMessage) -> IndexWork {
        var actions: [IndexWork.Action] = []
        if queryIndexNeedsRebuild {
            queryIndexNeedsRebuild = false
            actions.append(.replace(
                inputs: currentRecordInputs(),
                sequence: nextQueryIndexSequence(),
                sourceEpoch: querySourceEpoch
            ))
        }
        actions.append(.upsert(
            input: recordInput(for: message),
            sequence: nextQueryIndexSequence()
        ))
        return IndexWork(index: queryIndex, actions: actions)
    }

    package nonisolated(nonsending) func apply(
        _ event: Console.Event,
        targetID: WebInspectorTarget.ID?,
        modelContext: WebInspectorModelContext,
        registerRuntimeObject: (Runtime.RemoteObject) -> RuntimeObject
    ) async -> Effects {
        switch event {
        case let .messageAdded(payload):
            let parameters = payload.parameters.map(registerRuntimeObject)
            await insertMessage(
                payload,
                parameters: parameters,
                targetID: targetID,
                modelContext: modelContext
            )
            return Effects()
        case let .messageRepeatCountUpdated(count, timestamp):
            await updateRepeatCount(
                count,
                timestamp: timestamp,
                targetID: targetID,
                modelContext: modelContext
            )
            return Effects()
        case .messagesCleared:
            return await clear(targetID: targetID, modelContext: modelContext)
        case .unknown:
            return Effects()
        }
    }

    package nonisolated(nonsending) func resetForReplay(modelContext: WebInspectorModelContext) async {
        _ = removeMessages(targetID: nil)
        let reset = prepareEmptyQueryIndexReset()
        await finishQueryIndexReset(reset)
    }

    package func prepareClearForLifecycle(
        modelContext: WebInspectorModelContext
    ) -> (effects: Effects, queryIndexReset: QueryIndexReset) {
        _ = removeMessages(targetID: nil)
        let reset = prepareEmptyQueryIndexReset()
        return (
            Effects(clearedAllMessages: true),
            reset
        )
    }

    package nonisolated(nonsending) func finishQueryIndexReset(_ reset: QueryIndexReset) async {
        let deliveries = await queryIndex.replace(
            with: reset.inputs,
            sequence: reset.sequence,
            sourceEpoch: reset.sourceEpoch
        )
        await applyConcreteDeliveries(deliveries)
    }

    private nonisolated(nonsending) func insertMessage(
        _ payload: Console.Message,
        parameters: [RuntimeObject],
        targetID: WebInspectorTarget.ID?,
        modelContext: WebInspectorModelContext
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
        await notifyMessageInserted(message, modelContext: modelContext)
    }

    private nonisolated(nonsending) func updateRepeatCount(
        _ count: Int,
        timestamp: Double?,
        targetID: WebInspectorTarget.ID?,
        modelContext: WebInspectorModelContext
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
        await notifyMessageMutated(message, modelContext: modelContext)
    }

    private nonisolated(nonsending) func clear(
        targetID: WebInspectorTarget.ID?,
        modelContext: WebInspectorModelContext
    ) async -> Effects {
        let removedMessages = removeMessages(targetID: targetID)
        let runtimeObjectsToUnregister = targetID == nil
            ? []
            : unreferencedRuntimeObjects(from: removedMessages)
        let reset = targetID == nil
            ? prepareEmptyQueryIndexReset()
            : prepareQueryIndexReset()
        await finishQueryIndexReset(reset)
        return Effects(
            runtimeObjectsToUnregister: runtimeObjectsToUnregister,
            clearedAllMessages: targetID == nil
        )
    }

    @discardableResult
    private func removeMessages(targetID: WebInspectorTarget.ID?) -> [ConsoleMessage] {
        queryIndexNeedsRebuild = false
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
        rebuildOrderIndices()
        if let lastMessageID, removedIDs.contains(lastMessageID) {
            self.lastMessageID = orderedMessageIDs.last
        }
        lastMessageIDByTargetID[targetID] = orderedMessageIDs.last { id in
            messagesByID[id]?.targetID == targetID
        }
        return removedMessages
    }

    private func unreferencedRuntimeObjects(
        from removedMessages: [ConsoleMessage]
    ) -> [RuntimeObject] {
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

    private func rebuildOrderIndices() {
        orderIndicesByID = Dictionary(
            uniqueKeysWithValues: orderedMessageIDs.enumerated().map { index, id in
                (id, index)
            }
        )
    }

    private func currentRecordInputs() -> [ConsoleMessageRecordInput] {
#if DEBUG
        performanceCounters.fullRecordProjectionCount += orderedMessageIDs.count
#endif
        return orderedMessageIDs.enumerated().compactMap { index, id in
            messagesByID[id].map { ConsoleMessageRecordInput(message: $0, orderIndex: index) }
        }
    }

    private func recordInput(for message: ConsoleMessage) -> ConsoleMessageRecordInput {
#if DEBUG
        performanceCounters.incrementalRecordProjectionCount += 1
#endif
        let orderIndex = orderIndicesByID[message.id] ?? orderedMessageIDs.count
        return ConsoleMessageRecordInput(message: message, orderIndex: orderIndex)
    }

    private func isCurrent(_ message: ConsoleMessage) -> Bool {
        return messagesByID[message.id] === message
    }

    private func nextQueryIndexSequence() -> UInt64 {
        precondition(
            queryIndexSequence < UInt64.max,
            "ConsoleMessageIndex mutation sequence overflowed."
        )
        queryIndexSequence += 1
        return queryIndexSequence
    }

    private func prepareQueryIndexReset() -> QueryIndexReset {
        precondition(
            querySourceEpoch < UInt64.max,
            "Console query source epoch overflowed."
        )
        querySourceEpoch += 1
        queryIndexNeedsRebuild = false
        let sequence = nextQueryIndexSequence()
        let inputs = currentRecordInputs()
        return QueryIndexReset(
            inputs: inputs,
            sequence: sequence,
            sourceEpoch: querySourceEpoch
        )
    }

    private func prepareEmptyQueryIndexReset() -> QueryIndexReset {
        let reset = prepareQueryIndexReset()
        publishEmptyConcreteQueryResults(for: reset)
        return reset
    }

    private func publishEmptyConcreteQueryResults(for reset: QueryIndexReset) {
        precondition(
            reset.inputs.isEmpty,
            "Only a full Console lifecycle reset can publish an immediate empty query state."
        )
        pruneConcreteQueryRegistrations()
        let projection = ConsoleMessageIndex.QueryProjection(
            sourceEpoch: reset.sourceEpoch,
            sequence: reset.sequence,
            snapshot: WebInspectorFetchedResultsSnapshot(),
            reconfigureItemIDs: []
        )
        for registration in concreteQueryRegistrations.values {
            registration.results.value?.applyConsoleQueryProjection(
                projection,
                query: registration.activeQuery,
                generation: registration.activeGeneration,
                isReplacement: false,
                lookup: { _ in
                    preconditionFailure("An empty Console reset cannot resolve a model identity.")
                }
            )
        }
    }

    private nonisolated(nonsending) func syncQueryIndexIfNeeded() async {
        guard queryIndexNeedsRebuild else {
            return
        }
        queryIndexNeedsRebuild = false
        let sequence = nextQueryIndexSequence()
        let inputs = currentRecordInputs()
        let deliveries = await queryIndex.replace(
            with: inputs,
            sequence: sequence,
            sourceEpoch: querySourceEpoch
        )
        await applyConcreteDeliveries(deliveries)
    }

    private nonisolated(nonsending) func notifyMessageInserted(
        _ message: ConsoleMessage,
        modelContext: WebInspectorModelContext
    ) async {
        await syncQueryIndexIfNeeded()
        guard isCurrent(message) else {
            return
        }
        let sequence = nextQueryIndexSequence()
        let input = recordInput(for: message)
        let deliveries = await queryIndex.upsert(input, sequence: sequence)
        await applyConcreteDeliveries(deliveries)
        guard isCurrent(message) else {
            return
        }
    }

    private nonisolated(nonsending) func notifyMessageMutated(
        _ message: ConsoleMessage,
        modelContext: WebInspectorModelContext
    ) async {
        await syncQueryIndexIfNeeded()
        guard isCurrent(message) else {
            return
        }
        let sequence = nextQueryIndexSequence()
        let input = recordInput(for: message)
        let deliveries = await queryIndex.upsert(input, sequence: sequence)
        await applyConcreteDeliveries(deliveries)
        guard isCurrent(message) else {
            return
        }
    }

    private func allocateConcreteQueryRegistrationID() -> WebInspectorQueryRegistrationID {
        precondition(
            nextConcreteQueryRegistrationID < UInt64.max,
            "Console concrete query registration identity overflowed."
        )
        let id = WebInspectorQueryRegistrationID(rawValue: nextConcreteQueryRegistrationID)
        nextConcreteQueryRegistrationID += 1
        return id
    }

    private nonisolated(nonsending) func applyConcreteDeliveries(_ deliveries: [ConsoleMessageIndex.QueryDelivery]) async {
        let acknowledgements = applyConcreteDeliveriesSynchronously(deliveries)
        await IndexAcknowledgementWork(
            index: queryIndex,
            entries: acknowledgements
        ).run()
    }

    private func applyConcreteDeliveriesSynchronously(
        _ deliveries: [ConsoleMessageIndex.QueryDelivery]
    ) -> [IndexAcknowledgementWork.Entry] {
        pruneConcreteQueryRegistrations()
        var acknowledgements: [IndexAcknowledgementWork.Entry] = []
        for delivery in deliveries {
            guard delivery.projection.sourceEpoch == querySourceEpoch else {
                continue
            }
            let id = delivery.registrationID
            if var initialization = initializingConcreteQueries[id],
               initialization.generation == delivery.generation {
                initialization.projection = coalesce(
                    initialization.projection,
                    with: delivery.projection
                )
                initializingConcreteQueries[id] = initialization
                continue
            }
            guard var registration = concreteQueryRegistrations[id] else {
                continue
            }
            if delivery.generation == registration.activeGeneration {
                guard let results = registration.results.value else {
                    concreteQueryRegistrations[id] = nil
                    continue
                }
                let applied = results.applyConsoleQueryProjection(
                    delivery.projection,
                    query: registration.activeQuery,
                    generation: delivery.generation,
                    isReplacement: false,
                    lookup: { id in self.messageForResult(id) }
                )
                if applied {
                    acknowledgements.append(IndexAcknowledgementWork.Entry(
                        id: id,
                        generation: delivery.generation,
                        sourceEpoch: delivery.projection.sourceEpoch,
                        sequence: delivery.projection.sequence
                    ))
                }
            } else if var candidate = registration.candidate,
                      candidate.generation == delivery.generation {
                candidate.projection = coalesce(candidate.projection, with: delivery.projection)
                registration.candidate = candidate
            } else if var committing = registration.committing[delivery.generation] {
                committing.projection = coalesce(
                    committing.projection,
                    with: delivery.projection
                )
                registration.committing[delivery.generation] = committing
            }
            concreteQueryRegistrations[id] = registration
        }
        return acknowledgements
    }

    private func buffer(
        _ projection: ConsoleMessageIndex.QueryProjection,
        for id: WebInspectorQueryRegistrationID,
        generation: UInt64,
        query: ConsoleQuery,
        destination: ConcreteQueryBufferDestination
    ) {
        guard var registration = concreteQueryRegistrations[id] else {
            return
        }
        switch destination {
        case .candidate:
            guard var candidate = registration.candidate,
                  candidate.generation == generation,
                  candidate.query == query else {
                return
            }
            candidate.projection = coalesce(candidate.projection, with: projection)
            registration.candidate = candidate
        case .committing:
            guard var committing = registration.committing[generation],
                  committing.query == query else {
                return
            }
            committing.projection = coalesce(committing.projection, with: projection)
            registration.committing[generation] = committing
        }
        concreteQueryRegistrations[id] = registration
    }

    private func clearCandidate(
        id: WebInspectorQueryRegistrationID,
        generation: UInt64
    ) {
        guard var registration = concreteQueryRegistrations[id],
              registration.candidate?.generation == generation else {
            return
        }
        registration.candidate = nil
        concreteQueryRegistrations[id] = registration
    }

    private func clearCommitting(
        id: WebInspectorQueryRegistrationID,
        generation: UInt64
    ) {
        guard var registration = concreteQueryRegistrations[id] else {
            return
        }
        registration.committing[generation] = nil
        concreteQueryRegistrations[id] = registration
    }

    private func coalesce(
        _ current: ConsoleMessageIndex.QueryProjection?,
        with incoming: ConsoleMessageIndex.QueryProjection
    ) -> ConsoleMessageIndex.QueryProjection {
        guard let current else {
            return incoming
        }
        let incomingIsNewer = incoming.sourceEpoch > current.sourceEpoch
            || (incoming.sourceEpoch == current.sourceEpoch && incoming.sequence > current.sequence)
        let newest = incomingIsNewer ? incoming : current
        let reconfigureItemIDs = current.reconfigureItemIDs
            .union(incoming.reconfigureItemIDs)
            .intersection(newest.snapshot.itemIDs)
        return ConsoleMessageIndex.QueryProjection(
            sourceEpoch: newest.sourceEpoch,
            sequence: newest.sequence,
            snapshot: newest.snapshot,
            reconfigureItemIDs: reconfigureItemIDs
        )
    }

    private func pruneConcreteQueryRegistrations() {
        concreteQueryRegistrations = concreteQueryRegistrations.filter { _, registration in
            registration.results.value != nil
        }
    }

#if DEBUG
    package nonisolated(nonsending) func concreteQueryRegistrationCountForTesting() async -> Int {
        return await queryIndex.queryRegistrationCountForTesting()
    }
#endif

    private func messageForResult(_ id: ConsoleMessage.ID) -> ConsoleMessage? {
#if DEBUG
        performanceCounters.resultIdentityLookupCount += 1
#endif
        return messagesByID[id]
    }

    private func skipEvent(_ reason: String) {
        WebInspectorDataKitLog.debug("event skipped: \(reason)")
    }
}
