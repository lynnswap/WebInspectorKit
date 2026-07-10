import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@MainActor
@Test
func consoleQueryProvidesClosedDefaults() {
    let query = ConsoleQuery()

    #expect(query.levels.isEmpty)
    #expect(query.sort == .insertionAscending)
    #expect(query.section == nil)
    #expect(query.offset == 0)
    #expect(query.limit == nil)
}
@Test
func consoleConcreteQueryRegistrationIncludesTheRequiredMutationSequence() async throws {
    let index = ConsoleMessageIndex()
    let secondMutation = Task {
        await index.replace(with: [], sequence: 2)
    }
    try await waitForConcreteQueryCondition {
        await index.isMutationPendingForTesting(sequence: 2)
    }

    let lifetime = WebInspectorQueryRegistrationLifetime()
    let generation = lifetime.nextGeneration()
    let registration = Task {
        try await index.register(
            id: WebInspectorQueryRegistrationID(rawValue: 11),
            generation: generation,
            query: ConsoleQuery(),
            lifetime: lifetime,
            minimumSequence: 2
        )
    }
    try await waitForConcreteQueryCondition {
        await index.isSequenceWaiterPendingForTesting(minimumSequence: 2)
    }

    _ = await index.replace(with: [], sequence: 1)
    _ = await secondMutation.value
    let projection = try await registration.value

    #expect(projection.sequence == 2)
    #expect(await index.isSequenceWaiterPendingForTesting(minimumSequence: 2) == false)
    #expect(await index.queryRegistrationCountForTesting() == 1)
}

@Test
func cancelledConsoleConcreteQueryRegistrationStopsWaitingWithoutTheMissingMutation() async throws {
    var index: ConsoleMessageIndex? = ConsoleMessageIndex()
    weak let weakIndex = index
    let lifetime = WebInspectorQueryRegistrationLifetime()
    let generation = lifetime.nextGeneration()
    let registration = Task { [index] in
        guard let index else {
            throw CancellationError()
        }
        return try await index.register(
            id: WebInspectorQueryRegistrationID(rawValue: 12),
            generation: generation,
            query: ConsoleQuery(),
            lifetime: lifetime,
            minimumSequence: 1
        )
    }
    try await waitForConcreteQueryCondition { [weak index] in
        guard let index else {
            return false
        }
        return await index.isSequenceWaiterPendingForTesting(minimumSequence: 1)
    }

    registration.cancel()

    await #expect(throws: CancellationError.self) {
        try await registration.value
    }
    if let index {
        #expect(await index.isSequenceWaiterPendingForTesting(minimumSequence: 1) == false)
        #expect(await index.queryRegistrationCountForTesting() == 0)
    }
    index = nil
    #expect(weakIndex == nil)
}

@Test
func cancelledConsoleConcreteQueryReplacementStopsWaitingWithoutTheMissingMutation() async throws {
    let index = ConsoleMessageIndex()
    _ = await index.replace(with: [], sequence: 1)
    let lifetime = WebInspectorQueryRegistrationLifetime()
    let registrationID = WebInspectorQueryRegistrationID(rawValue: 13)
    let activeGeneration = lifetime.nextGeneration()
    _ = try await index.register(
        id: registrationID,
        generation: activeGeneration,
        query: ConsoleQuery(),
        lifetime: lifetime,
        minimumSequence: 1
    )

    let cancelledGeneration = lifetime.nextGeneration()
    let replacement = Task {
        try await index.prepareReplacement(
            id: registrationID,
            generation: cancelledGeneration,
            query: ConsoleQuery(sort: .insertionDescending),
            minimumSequence: 2
        )
    }
    try await waitForConcreteQueryCondition {
        await index.isSequenceWaiterPendingForTesting(minimumSequence: 2)
    }

    replacement.cancel()

    await #expect(throws: CancellationError.self) {
        try await replacement.value
    }
    #expect(await index.isSequenceWaiterPendingForTesting(minimumSequence: 2) == false)
    #expect(await index.commitReplacement(
        id: registrationID,
        generation: cancelledGeneration
    ) == nil)
}

@MainActor
@Test
func consoleConcreteQueryFiltersSortsSectionsAndWindowsCompactRecords() async throws {
    let context = WebInspectorModelContext.preview()
    let warning = makeIndexedConsoleMessage(
        id: 0,
        level: "warning",
        text: "warning",
        context: context
    )
    let log = makeIndexedConsoleMessage(
        id: 1,
        level: "log",
        text: "log",
        context: context
    )
    let error = makeIndexedConsoleMessage(
        id: 2,
        level: "error",
        text: "error",
        context: context
    )
    let index = ConsoleMessageIndex()
    _ = await index.replace(
        with: [warning.input, log.input, error.input],
        sequence: 1
    )
    let lifetime = WebInspectorQueryRegistrationLifetime()
    let generation = lifetime.nextGeneration()
    let registrationID = WebInspectorQueryRegistrationID(rawValue: 10)
    let projection = try await index.register(
        id: registrationID,
        generation: generation,
        query: ConsoleQuery(
            levels: [
                Console.Level(rawValue: "warning"),
                Console.Level(rawValue: "error"),
            ],
            sort: .insertionDescending,
            section: .level,
            limit: 1
        ),
        lifetime: lifetime,
        minimumSequence: 1
    )

    #expect(projection.snapshot.itemIDs == [error.id])
    #expect(projection.snapshot.sections.map(\.id.rawValue) == ["error"])

    let sameIDWithNewSection = makeIndexedConsoleMessage(
        id: 2,
        level: "warning",
        text: "updated error",
        context: context
    )
    let deliveries = await index.upsert(sameIDWithNewSection.input, sequence: 2)
    let updated = try #require(deliveries.first)
    #expect(updated.projection.snapshot.itemIDs == [error.id])
    #expect(updated.projection.snapshot.sections.map(\.id.rawValue) == ["warning"])
    #expect(updated.projection.reconfigureItemIDs == [error.id])
}

@MainActor
@Test
func consoleConcreteQueryPublishesUpdatesPartialDeletionAndReplacementAtomically() async throws {
    let context = WebInspectorModelContext.preview()
    let store = ConsoleMessageStore()
    let warningTarget = WebInspectorTarget.ID("concrete-warning-target")
    let logTarget = WebInspectorTarget.ID("concrete-log-target")
    let errorTarget = WebInspectorTarget.ID("concrete-error-target")
    await addConsoleMessage(
        level: "warning",
        text: "warning",
        targetID: warningTarget,
        store: store,
        context: context
    )
    await addConsoleMessage(
        level: "log",
        text: "log",
        targetID: logTarget,
        store: store,
        context: context
    )
    await addConsoleMessage(
        level: "error",
        text: "error",
        targetID: errorTarget,
        store: store,
        context: context
    )

    let warningID = ConsoleMessage.ID(0)
    let logID = ConsoleMessage.ID(1)
    let errorID = ConsoleMessage.ID(2)
    let registeredWarning = store.message(for: warningID)
    let warningIdentity = try #require(registeredWarning)
    let results = try await store.results(
        matching: ConsoleQuery(
            levels: [
                Console.Level(rawValue: "warning"),
                Console.Level(rawValue: "error"),
            ],
            sort: .insertionDescending,
            section: .level,
            limit: 2
        ),
        modelContext: context,
    )
    #expect(results.items.map(\.id) == [errorID, warningID])
    #expect(results.sections.map(\.id.rawValue) == ["error", "warning"])
    #expect(results.items.last === warningIdentity)
    var updates = results.updates().makeAsyncIterator()
    guard case .initial? = await updates.next() else {
        Issue.record("Expected an initial concrete Console query state.")
        return
    }

    _ = await store.apply(
        .messageRepeatCountUpdated(count: 4, timestamp: 4),
        targetID: warningTarget,
        modelContext: context,
        registerRuntimeObject: { _ in fatalError("Repeat updates have no Runtime parameters.") },
    )
    #expect(results.items.last === warningIdentity)
    #expect(results.items.last?.repeatCount == 4)
    guard case let .transaction(_, repeatUpdate, repeatReconfigure)? = await updates.next() else {
        Issue.record("Expected the concrete Console repeat transaction.")
        return
    }
    #expect(repeatUpdate.newSnapshot == results.snapshot)
    #expect(repeatReconfigure == [warningID])

    _ = await store.apply(
        .messagesCleared(reason: Console.ClearReason(rawValue: "console-api")),
        targetID: warningTarget,
        modelContext: context,
        registerRuntimeObject: { _ in fatalError("Clear events have no Runtime parameters.") },
    )
    #expect(results.items.map(\.id) == [errorID])
    guard case let .transaction(_, clear, _)? = await updates.next() else {
        Issue.record("Expected the concrete Console clear transaction.")
        return
    }
    #expect(clear.isReset)

    try await store.update(
        ConsoleQuery(
            levels: [Console.Level(rawValue: "log")],
            sort: .insertionAscending,
            offset: 0,
            limit: 1
        ),
        for: results,
    )
    #expect(results.items.map(\.id) == [logID])
    #expect(results.sections.map(\.id) == [.defaultSection])
}

@MainActor
@Test
func consoleConcreteQueryProjectsTenThousandRecordsOffTheOwnerActor() async throws {
    let context = WebInspectorModelContext.preview()
    let store = ConsoleMessageStore()
    let recordCount = 10_000
    for ordinal in 0..<recordCount {
        await addConsoleMessage(
            level: ordinal.isMultiple(of: 2) ? "log" : "warning",
            text: "concrete-message-\(ordinal)",
            targetID: nil,
            store: store,
            context: context
        )
    }
    store.resetPerformanceCountersForTesting()

    let results = try await store.results(
        matching: ConsoleQuery(
            levels: [Console.Level(rawValue: "warning")],
            sort: .insertionDescending,
            limit: 20
        ),
        modelContext: context,
    )
    #expect(results.items.count == 20)
    var counters = store.performanceCountersForTesting
    #expect(counters.fullModelProjectionCount == 0)
    #expect(counters.fullRecordProjectionCount == 0)
    #expect(counters.resultIdentityLookupCount == 20)

    await addConsoleMessage(
        level: "warning",
        text: "concrete-message-newest",
        targetID: nil,
        store: store,
        context: context
    )
    #expect(results.items.first?.text == "concrete-message-newest")
    counters = store.performanceCountersForTesting
    #expect(counters.fullModelProjectionCount == 0)
    #expect(counters.fullRecordProjectionCount == 0)
    #expect(counters.incrementalRecordProjectionCount == 1)
    #expect(counters.resultIdentityLookupCount == 21)

    try await store.update(
        ConsoleQuery(
            levels: [Console.Level(rawValue: "log")],
            sort: .insertionAscending,
            offset: 10,
            limit: 10
        ),
        for: results,
    )
    counters = store.performanceCountersForTesting
    #expect(results.items.count == 10)
    #expect(counters.fullModelProjectionCount == 0)
    #expect(counters.fullRecordProjectionCount == 0)
}

@MainActor
@Test
func droppingConsoleConcreteResultsReleasesItsIndexRegistration() async throws {
    let context = WebInspectorModelContext.preview()
    let store = ConsoleMessageStore()
    var results: WebInspectorFetchedResults<ConsoleMessage>? = try await store.results(
        matching: ConsoleQuery(),
        modelContext: context,
    )
    weak let weakResults = results

    let registrationCount = await store.concreteQueryRegistrationCountForTesting(
    )
    #expect(registrationCount == 1)
    results = nil
    #expect(weakResults == nil)
    let prunedRegistrationCount = await store.concreteQueryRegistrationCountForTesting(
    )
    #expect(prunedRegistrationCount == 0)
}

@MainActor
private func makeIndexedConsoleMessage(
    id: Int,
    level: String,
    text: String,
    context: WebInspectorModelContext
) -> (id: ConsoleMessage.ID, input: ConsoleMessageRecordInput) {
    let modelID = ConsoleMessage.ID(id)
    let message = ConsoleMessage(
        id: modelID,
        message: Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: level),
            text: text
        ),
        parameters: [],
        targetID: nil,
        modelContext: context
    )
    return (modelID, ConsoleMessageRecordInput(message: message, orderIndex: id))
}

@MainActor
private func addConsoleMessage(
    level: String,
    text: String,
    targetID: WebInspectorTarget.ID?,
    store: ConsoleMessageStore,
    context: WebInspectorModelContext
) async {
    _ = await store.apply(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: level),
            text: text
        )),
        targetID: targetID,
        modelContext: context,
        registerRuntimeObject: { _ in fatalError("The fixture has no Runtime parameters.") },
    )
}
