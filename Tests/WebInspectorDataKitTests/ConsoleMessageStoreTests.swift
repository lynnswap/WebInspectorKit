import Foundation
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

private actor StoreIsolationProbe {
    func exercise() async -> (networkCount: Int, consoleEpoch: UInt64) {
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
        return (networkStore.collectionState.requestCount, consoleStore.collectionEpoch)
    }
}

@Test
func networkAndConsoleStoresFollowTheCallingActor() async {
    let values = await StoreIsolationProbe().exercise()

    #expect(values.networkCount == 1)
    #expect(values.consoleEpoch == 1)
}

@MainActor
@Test
func consoleMessageQueryPlanKeepsSupportedPredicatesOffTheModelActor() {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let descriptor = WebInspectorFetchDescriptor<ConsoleMessage>(
        predicate: #Predicate { message in
            message.level.rawValue == "warning"
        },
        sortBy: [SortDescriptor(\.text, order: .reverse)],
        fetchLimit: 100
    )

    let plan = ConsoleMessageQueryPlan(descriptor: descriptor, context: context)

    #expect(plan.requiresQuery)
    #expect(plan.requiresModelPredicate == false)
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
    await secondMutation.value

    let delta = await index.delta(
        plan: ConsoleMessageQueryPlan(
            descriptor: WebInspectorFetchDescriptor(),
            context: context
        ),
        sectionBy: nil,
        oldSnapshot: WebInspectorFetchedResultsSnapshot(),
        changedSince: 0
    )
    #expect(delta.sequence == 2)
    #expect(delta.snapshot.itemIDs == [first.id, second.id])
}

@MainActor
@Test
func consoleMessageStoreOwnsTargetOrderEpochAndClearEffects() async throws {
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
        .messageRepeatCountUpdated(count: 3, timestamp: 4),
        targetID: firstTargetID,
        modelContext: context,
        registerRuntimeObject: { _ in fatalError("Repeat updates have no Runtime parameters.") },
        isolation: MainActor.shared
    )

    let results = WebInspectorFetchedResults<ConsoleMessage>(
        fetchDescriptor: WebInspectorFetchDescriptor(),
        modelContext: context
    )
    store.register(results, modelContext: context, isolation: MainActor.shared)
    #expect(results.items.map(\.text) == ["first", "second"])
    #expect(results.items.first?.repeatCount == 3)
    #expect(store.collectionEpoch == 2)

    let effects = await store.apply(
        .messagesCleared(reason: Console.ClearReason(rawValue: "console-api")),
        targetID: firstTargetID,
        modelContext: context,
        registerRuntimeObject: { _ in fatalError("Clear events have no Runtime parameters.") },
        isolation: MainActor.shared
    )

    #expect(effects.removedMessages.map(\.text) == ["first"])
    #expect(effects.clearedAllMessages == false)
    #expect(effects.runtimeObjectGroupRelease == .target(firstTargetID))
    #expect(results.items.map(\.text) == ["second"])
    #expect(store.collectionEpoch == 3)
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
