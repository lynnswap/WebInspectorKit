import Foundation
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

private actor StoreIsolationProbe {
    func exercise() async -> (networkCount: Int, consoleItemCount: Int) {
        let context = WebInspectorContext.preview(isolation: self)
        let networkStore = NetworkRequestStore()
        let networkID = Network.Request.ID("custom-actor-request")
        await networkStore.apply(
            .requestWillBeSent(
                id: networkID,
                request: Network.Request(
                    id: networkID,
                    url: "https://example.com/custom-actor",
                    method: "GET"
                ),
                resourceType: .fetch,
                redirectResponse: nil,
                timestamp: 1
            ),
            modelContext: context,
            isolation: self
        )

        let consoleStore = ConsoleMessageStore()
        let consoleResults = WebInspectorFetchedResults<ConsoleMessage>(
            fetchDescriptor: WebInspectorFetchDescriptor(),
            modelContext: context
        )
        consoleStore.register(consoleResults, modelContext: context, isolation: self)
        _ = await consoleStore.apply(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "log"),
                text: "custom actor"
            )),
            targetID: nil,
            modelContext: context,
            registerRuntimeObject: { _ in fatalError("The fixture has no Runtime parameters.") },
            isolation: self
        )
        return (networkStore.collectionState.requestCount, consoleResults.items.count)
    }
}

@Test
func networkAndConsoleStoresFollowTheCallingActor() async {
    let values = await StoreIsolationProbe().exercise()

    #expect(values.networkCount == 1)
    #expect(values.consoleItemCount == 1)
}

@MainActor
@Test
func consoleMessageQueryPlanKeepsSupportedPredicatesOffTheModelActor() {
    let descriptor = WebInspectorFetchDescriptor<ConsoleMessage>(
        predicate: #Predicate { message in
            message.level.rawValue == "warning"
        },
        sortBy: [SortDescriptor(\.text, order: .reverse)],
        fetchLimit: 100
    )

    let plan = ConsoleMessageQueryPlan(descriptor: descriptor)

    #expect(plan.requiresQuery)
    #expect(plan.requiresModelPredicate == false)
    #expect(plan.requiresModelQuery == false)
}

@MainActor
@Test
func consoleMessageSortPlanningPreservesStandardAndCustomComparators() async {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = ConsoleMessageStore()
    let customDescriptor = WebInspectorFetchDescriptor<ConsoleMessage>(
        sortBy: [SortDescriptor(\.text, comparator: .lexical)]
    )
    let customPlan = ConsoleMessageQueryPlan(descriptor: customDescriptor)
    #expect(customPlan.requiresModelQuery)
    #expect(customPlan.sortComparators.isEmpty)
    #expect(customPlan.modelSortDescriptors?.count == 1)
    let standardDescriptor = WebInspectorFetchDescriptor<ConsoleMessage>(
        sortBy: [SortDescriptor(\.text)]
    )
    let standardPlan = ConsoleMessageQueryPlan(descriptor: standardDescriptor)
    #expect(standardPlan.requiresModelQuery == false)
    #expect(standardPlan.sortComparators.count == 1)
    #expect(standardPlan.modelSortDescriptors == nil)

    let customResults = WebInspectorFetchedResults<ConsoleMessage>(
        fetchDescriptor: customDescriptor,
        modelContext: context
    )
    let standardResults = WebInspectorFetchedResults<ConsoleMessage>(
        fetchDescriptor: standardDescriptor,
        modelContext: context
    )
    store.register(customResults, modelContext: context, isolation: MainActor.shared)
    store.register(standardResults, modelContext: context, isolation: MainActor.shared)
    for text in ["item2", "item10"] {
        _ = await store.apply(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "log"),
                text: text
            )),
            targetID: nil,
            modelContext: context,
            registerRuntimeObject: { _ in fatalError("The fixture has no Runtime parameters.") },
            isolation: MainActor.shared
        )
    }

    #expect(customResults.items.map(\.text) == ["item10", "item2"])
    #expect(standardResults.items.map(\.text) == ["item2", "item10"])
}

@MainActor
@Test
func consoleMessageIndexDrainsMutationsInSequenceOrder() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let first = ConsoleMessage(
        id: ConsoleMessage.ID(0),
        message: Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "log"),
            text: "first"
        ),
        parameters: [],
        targetID: nil,
        modelContext: context
    )
    let second = ConsoleMessage(
        id: ConsoleMessage.ID(1),
        message: Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "log"),
            text: "second"
        ),
        parameters: [],
        targetID: nil,
        modelContext: context
    )
    let index = ConsoleMessageIndex()

    let secondMutation = Task {
        await index.upsert(
            ConsoleMessageRecordInput(message: second, orderIndex: 1),
            sequence: 2
        )
    }
    for _ in 0..<1_000 {
        if await index.isMutationPendingForTesting(sequence: 2) {
            break
        }
        await Task.yield()
    }
    let secondMutationIsPending = await index.isMutationPendingForTesting(sequence: 2)
    #expect(secondMutationIsPending)
    await index.upsert(
        ConsoleMessageRecordInput(message: first, orderIndex: 0),
        sequence: 1
    )
    _ = await secondMutation.value

    let delta = await index.delta(
        plan: ConsoleMessageQueryPlan(descriptor: WebInspectorFetchDescriptor()),
        sectionBy: nil,
        oldSnapshot: WebInspectorFetchedResultsSnapshot(),
        changedSince: 0
    )
    #expect(delta.sequence == 2)
    #expect(delta.snapshot.itemIDs == [first.id, second.id])
}

@MainActor
@Test
func consoleMessageStoreOwnsTargetOrderAndClearEffects() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = ConsoleMessageStore()
    let firstTargetID = WebInspectorTarget.ID("first-target")
    let secondTargetID = WebInspectorTarget.ID("second-target")

    _ = await store.apply(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "log"),
            text: "first"
        )),
        targetID: firstTargetID,
        modelContext: context,
        registerRuntimeObject: { _ in fatalError("The fixture has no Runtime parameters.") },
        isolation: MainActor.shared
    )
    _ = await store.apply(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "javascript"),
            level: Console.Level(rawValue: "warning"),
            text: "second"
        )),
        targetID: secondTargetID,
        modelContext: context,
        registerRuntimeObject: { _ in fatalError("The fixture has no Runtime parameters.") },
        isolation: MainActor.shared
    )
    _ = await store.apply(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "log"),
            text: "page"
        )),
        targetID: nil,
        modelContext: context,
        registerRuntimeObject: { _ in fatalError("The fixture has no Runtime parameters.") },
        isolation: MainActor.shared
    )
    _ = await store.apply(
        .messageRepeatCountUpdated(count: 3, timestamp: 4),
        targetID: firstTargetID,
        modelContext: context,
        registerRuntimeObject: { _ in fatalError("Repeat updates have no Runtime parameters.") },
        isolation: MainActor.shared
    )
    _ = await store.apply(
        .messageRepeatCountUpdated(count: 9, timestamp: 5),
        targetID: WebInspectorTarget.ID("unknown-target"),
        modelContext: context,
        registerRuntimeObject: { _ in fatalError("Repeat updates have no Runtime parameters.") },
        isolation: MainActor.shared
    )
    _ = await store.apply(
        .messageRepeatCountUpdated(count: 4, timestamp: 6),
        targetID: nil,
        modelContext: context,
        registerRuntimeObject: { _ in fatalError("Repeat updates have no Runtime parameters.") },
        isolation: MainActor.shared
    )

    let results = WebInspectorFetchedResults<ConsoleMessage>(
        fetchDescriptor: WebInspectorFetchDescriptor(),
        modelContext: context
    )
    store.register(results, modelContext: context, isolation: MainActor.shared)
    #expect(results.items.map(\.text) == ["first", "second", "page"])
    #expect(results.items.map(\.repeatCount) == [3, 1, 4])
    let firstMessageID = try #require(results.items.first?.id)

    let effects = await store.apply(
        .messagesCleared(reason: Console.ClearReason(rawValue: "console-api")),
        targetID: firstTargetID,
        modelContext: context,
        registerRuntimeObject: { _ in fatalError("Clear events have no Runtime parameters.") },
        isolation: MainActor.shared
    )

    #expect(effects.clearedAllMessages == false)
    #expect(results.items.map(\.text) == ["second", "page"])
    let clearedMessage = store.message(for: firstMessageID, isolation: MainActor.shared)
    #expect(clearedMessage == nil)
}

@MainActor
@Test
func consoleMessageTransactionsPreserveInsertMoveAndUpdateSemantics() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = ConsoleMessageStore()
    let firstTargetID = WebInspectorTarget.ID("sorted-first-target")
    let secondTargetID = WebInspectorTarget.ID("sorted-second-target")
    let results = WebInspectorFetchedResults<ConsoleMessage>(
        fetchDescriptor: WebInspectorFetchDescriptor(
            sortBy: [SortDescriptor(\.repeatCount, order: .reverse)]
        ),
        modelContext: context
    )
    store.register(results, modelContext: context, isolation: MainActor.shared)
    var updates = results.updates().makeAsyncIterator()
    guard case .initial? = await updates.next() else {
        Issue.record("Expected the initial Console fetched-results snapshot.")
        return
    }

    _ = await store.apply(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "log"),
            text: "first",
            repeatCount: 1
        )),
        targetID: firstTargetID,
        modelContext: context,
        registerRuntimeObject: { _ in fatalError("The fixture has no Runtime parameters.") },
        isolation: MainActor.shared
    )
    let firstID = try #require(results.items.first?.id)
    guard case let .transaction(_, firstInsert, firstReconfigure)? = await updates.next() else {
        Issue.record("Expected the first Console insertion transaction.")
        return
    }
    #expect(firstInsert.itemChanges == [
        .insert(
            itemID: firstID,
            indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)
        ),
    ])
    #expect(firstReconfigure.isEmpty)

    _ = await store.apply(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "log"),
            text: "second",
            repeatCount: 2
        )),
        targetID: secondTargetID,
        modelContext: context,
        registerRuntimeObject: { _ in fatalError("The fixture has no Runtime parameters.") },
        isolation: MainActor.shared
    )
    let secondID = try #require(results.items.first?.id)
    guard case let .transaction(_, frontInsert, frontReconfigure)? = await updates.next() else {
        Issue.record("Expected the front insertion transaction.")
        return
    }
    #expect(results.items.map(\.id) == [secondID, firstID])
    #expect(frontInsert.itemChanges == [
        .insert(
            itemID: secondID,
            indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)
        ),
    ])
    #expect(frontReconfigure.isEmpty)

    _ = await store.apply(
        .messageRepeatCountUpdated(count: 3, timestamp: 3),
        targetID: firstTargetID,
        modelContext: context,
        registerRuntimeObject: { _ in fatalError("Repeat updates have no Runtime parameters.") },
        isolation: MainActor.shared
    )
    guard case let .transaction(_, move, moveReconfigure)? = await updates.next() else {
        Issue.record("Expected the Console sort-move transaction.")
        return
    }
    #expect(results.items.map(\.id) == [firstID, secondID])
    #expect(move.itemChanges == [
        .move(
            itemID: firstID,
            from: WebInspectorFetchedResultsIndexPath(section: 0, item: 1),
            to: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)
        ),
    ])
    #expect(moveReconfigure == [firstID])

    _ = await store.apply(
        .messageRepeatCountUpdated(count: 4, timestamp: 4),
        targetID: firstTargetID,
        modelContext: context,
        registerRuntimeObject: { _ in fatalError("Repeat updates have no Runtime parameters.") },
        isolation: MainActor.shared
    )
    guard case let .transaction(_, update, updateReconfigure)? = await updates.next() else {
        Issue.record("Expected the in-place Console update transaction.")
        return
    }
    #expect(update.itemChanges == [
        .update(
            itemID: firstID,
            indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)
        ),
    ])
    #expect(updateReconfigure == [firstID])
}

@MainActor
@Test
func consoleMessageReverseSortPreservesInsertionOrderForEqualKeys() async {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = ConsoleMessageStore()
    let results = WebInspectorFetchedResults<ConsoleMessage>(
        fetchDescriptor: WebInspectorFetchDescriptor(
            sortBy: [SortDescriptor(\.level.rawValue, order: .reverse)],
            fetchLimit: 1
        ),
        modelContext: context
    )
    store.register(results, modelContext: context, isolation: MainActor.shared)

    for text in ["first", "second"] {
        _ = await store.apply(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "log"),
                text: text
            )),
            targetID: nil,
            modelContext: context,
            registerRuntimeObject: { _ in fatalError("The fixture has no Runtime parameters.") },
            isolation: MainActor.shared
        )
    }

    #expect(results.items.map(\.text) == ["first"])
}

@MainActor
@Test
func consoleMessageTransactionsPreserveSectionInsertionAndDeletion() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = ConsoleMessageStore()
    let warningTargetID = WebInspectorTarget.ID("section-warning-target")
    let errorTargetID = WebInspectorTarget.ID("section-error-target")
    let results = WebInspectorFetchedResults<ConsoleMessage>(
        fetchDescriptor: WebInspectorFetchDescriptor(),
        sectionBy: WebInspectorSectionDescriptor(\.level),
        modelContext: context
    )
    store.register(results, modelContext: context, isolation: MainActor.shared)
    var updates = results.updates().makeAsyncIterator()
    guard case .initial? = await updates.next() else {
        Issue.record("Expected the initial sectioned Console snapshot.")
        return
    }

    _ = await store.apply(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "warning"),
            text: "warning"
        )),
        targetID: warningTargetID,
        modelContext: context,
        registerRuntimeObject: { _ in fatalError("The fixture has no Runtime parameters.") },
        isolation: MainActor.shared
    )
    let warningID = try #require(results.items.first?.id)
    guard case let .transaction(_, warningInsert, _)? = await updates.next() else {
        Issue.record("Expected the warning-section insertion transaction.")
        return
    }
    #expect(warningInsert.sectionChanges == [
        .insert(sectionID: WebInspectorFetchSectionID(rawValue: "warning"), index: 0),
    ])
    #expect(warningInsert.itemChanges == [
        .insert(
            itemID: warningID,
            indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)
        ),
    ])

    _ = await store.apply(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "javascript"),
            level: Console.Level(rawValue: "error"),
            text: "error"
        )),
        targetID: errorTargetID,
        modelContext: context,
        registerRuntimeObject: { _ in fatalError("The fixture has no Runtime parameters.") },
        isolation: MainActor.shared
    )
    let errorID = try #require(results.items.last?.id)
    guard case let .transaction(_, errorInsert, _)? = await updates.next() else {
        Issue.record("Expected the error-section insertion transaction.")
        return
    }
    #expect(errorInsert.sectionChanges == [
        .insert(sectionID: WebInspectorFetchSectionID(rawValue: "error"), index: 1),
    ])
    #expect(errorInsert.itemChanges == [
        .insert(
            itemID: errorID,
            indexPath: WebInspectorFetchedResultsIndexPath(section: 1, item: 0)
        ),
    ])

    _ = await store.apply(
        .messagesCleared(reason: Console.ClearReason(rawValue: "console-api")),
        targetID: warningTargetID,
        modelContext: context,
        registerRuntimeObject: { _ in fatalError("Clear events have no Runtime parameters.") },
        isolation: MainActor.shared
    )
    guard case let .transaction(_, warningDelete, _)? = await updates.next() else {
        Issue.record("Expected the warning-section deletion transaction.")
        return
    }
    #expect(results.items.map(\.id) == [errorID])
    #expect(warningDelete.sectionChanges == [
        .delete(sectionID: WebInspectorFetchSectionID(rawValue: "warning"), index: 0),
    ])
    #expect(warningDelete.itemChanges == [
        .delete(
            itemID: warningID,
            indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)
        ),
    ])
}

@MainActor
@Test
func consoleMessageTransactionPublishesMembershipChangeFromDeletedSection() {
    let firstID = ConsoleMessage.ID(0)
    let secondID = ConsoleMessage.ID(1)
    let warningSection = WebInspectorFetchSectionID(rawValue: "warning")
    let errorSection = WebInspectorFetchSectionID(rawValue: "error")
    let oldSnapshot = WebInspectorFetchedResultsSnapshot(sections: [
        WebInspectorFetchedResultsSnapshot.Section(
            id: warningSection,
            title: "warning",
            itemIDs: [firstID]
        ),
        WebInspectorFetchedResultsSnapshot.Section(
            id: errorSection,
            title: "error",
            itemIDs: [secondID]
        ),
    ])
    let newSnapshot = WebInspectorFetchedResultsSnapshot(sections: [
        WebInspectorFetchedResultsSnapshot.Section(
            id: warningSection,
            title: "warning",
            itemIDs: [firstID, secondID]
        ),
    ])

    let transaction = WebInspectorFetchedResultsTransaction<ConsoleMessage.ID>(
        oldSnapshot: oldSnapshot,
        newSnapshot: newSnapshot
    )

    #expect(transaction.sectionChanges == [
        .delete(sectionID: errorSection, index: 1),
    ])
    #expect(transaction.itemChanges == [
        .insert(
            itemID: secondID,
            indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 1)
        ),
    ])
}

@MainActor
@Test
func consoleMessageStoreTenThousandLiveInsertsAndMutationUseCompactProjections() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = ConsoleMessageStore()
    let recordCount = 10_000

    for ordinal in 0..<recordCount {
        _ = await store.apply(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: ordinal.isMultiple(of: 2) ? "log" : "warning"),
                text: "message-\(ordinal)",
                timestamp: Double(ordinal)
            )),
            targetID: nil,
            modelContext: context,
            registerRuntimeObject: { _ in fatalError("The fixture has no Runtime parameters.") },
            isolation: MainActor.shared
        )
    }

    let insertCounters = store.performanceCountersForTesting
    #expect(insertCounters.incrementalRecordProjectionCount == recordCount)
    #expect(insertCounters.fullRecordProjectionCount == 0)
    #expect(insertCounters.fullModelProjectionCount == 0)
    #expect(insertCounters.resultIdentityLookupCount == 0)

    let results = WebInspectorFetchedResults<ConsoleMessage>(
        fetchDescriptor: WebInspectorFetchDescriptor(),
        modelContext: context
    )
    store.register(results, modelContext: context, isolation: MainActor.shared)
    #expect(results.items.count == recordCount)
    store.resetPerformanceCountersForTesting(isolation: MainActor.shared)

    _ = await store.apply(
        .messageRepeatCountUpdated(count: 7, timestamp: Double(recordCount)),
        targetID: nil,
        modelContext: context,
        registerRuntimeObject: { _ in fatalError("Repeat updates have no Runtime parameters.") },
        isolation: MainActor.shared
    )

    let mutationCounters = store.performanceCountersForTesting
    #expect(mutationCounters.incrementalRecordProjectionCount == 1)
    #expect(mutationCounters.fullRecordProjectionCount == 0)
    #expect(mutationCounters.fullModelProjectionCount == 0)
    #expect(mutationCounters.resultIdentityLookupCount == 0)
    #expect(results.items.count == recordCount)
    #expect(results.items.last?.repeatCount == 7)
}
