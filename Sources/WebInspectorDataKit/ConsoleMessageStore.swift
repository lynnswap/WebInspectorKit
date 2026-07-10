import WebInspectorProxyKit

/// Owns Console message identity, order, query projection, and publication.
///
/// Runtime-object membership and protocol commands remain in
/// `WebInspectorContext`; clear operations return explicit effects for that
/// owner to apply. The store never retains an actor token or starts a task.
package final class ConsoleMessageStore {
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

    package enum RuntimeObjectGroupRelease: Equatable {
        case currentPage
        case target(WebInspectorTarget.ID)
    }

    package struct Effects {
        package var runtimeObjectsToUnregister: [RuntimeObject] = []
        package var clearedAllMessages = false
        package var runtimeObjectGroupRelease: RuntimeObjectGroupRelease?
    }

    package struct QueryIndexReset: Sendable {
        fileprivate var inputs: [ConsoleMessageRecordInput]
        fileprivate var sequence: UInt64
        fileprivate var sourceEpoch: UInt64
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
        fetchedResults = []
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

    package func results(
        matching query: ConsoleQuery,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor) = #isolation
    ) async throws -> WebInspectorFetchedResults<ConsoleMessage> {
        await syncQueryIndexIfNeeded(isolation: isolation)
        let id = allocateConcreteQueryRegistrationID(isolation: isolation)
        let lifetime = WebInspectorQueryRegistrationLifetime()
        let results = WebInspectorFetchedResults<ConsoleMessage>(
            fetchDescriptor: WebInspectorFetchDescriptor(),
            modelContext: modelContext
        )
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
            lookup: { id in self.messageForResult(id, isolation: isolation) }
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

    package func update(
        _ query: ConsoleQuery,
        for results: WebInspectorFetchedResults<ConsoleMessage>,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        guard let id = results.concreteQueryRegistrationID else {
            preconditionFailure("Console fetched results are not registered in this store.")
        }
        await syncQueryIndexIfNeeded(isolation: isolation)
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
            lookup: { id in self.messageForResult(id, isolation: isolation) }
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
            return await clear(targetID: targetID, modelContext: modelContext, isolation: isolation)
        case .unknown:
            return Effects()
        }
    }

    package func resetForReplay(
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor) = #isolation
    ) async {
        _ = removeMessages(targetID: nil, isolation: isolation)
        refreshAllResults(modelContext: modelContext, isolation: isolation)
        let reset = prepareEmptyQueryIndexReset(isolation: isolation)
        await finishQueryIndexReset(reset, isolation: isolation)
    }

    package func prepareClearForLifecycle(
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor) = #isolation
    ) -> (effects: Effects, queryIndexReset: QueryIndexReset) {
        _ = removeMessages(targetID: nil, isolation: isolation)
        refreshAllResults(modelContext: modelContext, isolation: isolation)
        let reset = prepareEmptyQueryIndexReset(isolation: isolation)
        return (
            Effects(clearedAllMessages: true),
            reset
        )
    }

    package func finishQueryIndexReset(
        _ reset: QueryIndexReset,
        isolation: isolated (any Actor) = #isolation
    ) async {
        let deliveries = await queryIndex.replace(
            with: reset.inputs,
            sequence: reset.sequence,
            sourceEpoch: reset.sourceEpoch
        )
        await applyConcreteDeliveries(deliveries, isolation: isolation)
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
    ) async -> Effects {
        let removedMessages = removeMessages(targetID: targetID, isolation: isolation)
        let runtimeObjectsToUnregister = targetID == nil
            ? []
            : unreferencedRuntimeObjects(
                from: removedMessages,
                isolation: isolation
            )
        refreshAllResults(modelContext: modelContext, isolation: isolation)
        let reset = targetID == nil
            ? prepareEmptyQueryIndexReset(isolation: isolation)
            : prepareQueryIndexReset(isolation: isolation)
        await finishQueryIndexReset(reset, isolation: isolation)
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

    private func prepareQueryIndexReset(
        isolation: isolated (any Actor)
    ) -> QueryIndexReset {
        precondition(
            querySourceEpoch < UInt64.max,
            "Console query source epoch overflowed."
        )
        querySourceEpoch += 1
        queryIndexNeedsRebuild = false
        let sequence = nextQueryIndexSequence(isolation: isolation)
        let inputs = currentRecordInputs(isolation: isolation)
        return QueryIndexReset(
            inputs: inputs,
            sequence: sequence,
            sourceEpoch: querySourceEpoch
        )
    }

    private func prepareEmptyQueryIndexReset(
        isolation: isolated (any Actor)
    ) -> QueryIndexReset {
        let reset = prepareQueryIndexReset(isolation: isolation)
        publishEmptyConcreteQueryResults(for: reset, isolation: isolation)
        return reset
    }

    private func publishEmptyConcreteQueryResults(
        for reset: QueryIndexReset,
        isolation: isolated (any Actor)
    ) {
        precondition(
            reset.inputs.isEmpty,
            "Only a full Console lifecycle reset can publish an immediate empty query state."
        )
        pruneConcreteQueryRegistrations(isolation: isolation)
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

    private func syncQueryIndexIfNeeded(isolation: isolated (any Actor)) async {
        guard queryIndexNeedsRebuild else {
            return
        }
        queryIndexNeedsRebuild = false
        let sequence = nextQueryIndexSequence(isolation: isolation)
        let inputs = currentRecordInputs(isolation: isolation)
        let deliveries = await queryIndex.replace(
            with: inputs,
            sequence: sequence,
            sourceEpoch: querySourceEpoch
        )
        await applyConcreteDeliveries(deliveries, isolation: isolation)
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
        let deliveries = await queryIndex.upsert(input, sequence: sequence)
        await applyConcreteDeliveries(deliveries, isolation: isolation)
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
        let deliveries = await queryIndex.upsert(input, sequence: sequence)
        await applyConcreteDeliveries(deliveries, isolation: isolation)
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
        guard fetchedResults.isEmpty == false else {
            return
        }
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

    private func allocateConcreteQueryRegistrationID(
        isolation: isolated (any Actor)
    ) -> WebInspectorQueryRegistrationID {
        _ = isolation
        precondition(
            nextConcreteQueryRegistrationID < UInt64.max,
            "Console concrete query registration identity overflowed."
        )
        let id = WebInspectorQueryRegistrationID(rawValue: nextConcreteQueryRegistrationID)
        nextConcreteQueryRegistrationID += 1
        return id
    }

    private func applyConcreteDeliveries(
        _ deliveries: [ConsoleMessageIndex.QueryDelivery],
        isolation: isolated (any Actor)
    ) async {
        pruneConcreteQueryRegistrations(isolation: isolation)
        var acknowledgements: [(
            id: WebInspectorQueryRegistrationID,
            generation: UInt64,
            sourceEpoch: UInt64,
            sequence: UInt64
        )] = []
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
                    lookup: { id in self.messageForResult(id, isolation: isolation) }
                )
                if applied {
                    acknowledgements.append((
                        id,
                        delivery.generation,
                        delivery.projection.sourceEpoch,
                        delivery.projection.sequence
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
        for acknowledgement in acknowledgements {
            await queryIndex.acknowledge(
                id: acknowledgement.id,
                generation: acknowledgement.generation,
                sourceEpoch: acknowledgement.sourceEpoch,
                sequence: acknowledgement.sequence
            )
        }
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

    private func pruneConcreteQueryRegistrations(isolation: isolated (any Actor)) {
        _ = isolation
        concreteQueryRegistrations = concreteQueryRegistrations.filter { _, registration in
            registration.results.value != nil
        }
    }

#if DEBUG
    package func concreteQueryRegistrationCountForTesting(
        isolation: isolated (any Actor) = #isolation
    ) async -> Int {
        _ = isolation
        return await queryIndex.queryRegistrationCountForTesting()
    }
#endif

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
