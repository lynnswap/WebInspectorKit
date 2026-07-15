import Testing
@testable import WebInspectorDataKit
import WebInspectorDataKitTesting
import WebInspectorProxyKit

@MainActor
@Test
func dataKitTestingStartsWithProductionContextsAndFeatureGateways()
    async throws
{
    let replay = WebInspectorDataKitTestRuntime.NetworkRequest(
        id: "initial-request",
        url: "https://example.test/initial",
        status: 201,
        body: Network.Body(data: "ready body")
    )
    let runtime = try await WebInspectorDataKitTestRuntime.start(
        scenario: .init(
            configuration: .init(enabledFeatures: [.dom, .network]),
            document: .init(children: [
                .element(id: "button", name: "button")
            ]),
            networkReplay: [replay]
        )
    )
    let context = runtime.container.mainContext

    #expect(runtime.container.state.isAttached)
    let domResults = WebInspectorFetchedResultsController<DOMNode>(
        modelContext: context
    )
    try await domResults.performFetch()
    #expect(domResults.snapshot?.itemIDs.count == 2)
    #expect(domResults.fetchedObjects?.contains { $0.nodeName == "#document" } == true)

    let entryResults = WebInspectorFetchedResultsController<NetworkEntry>(
        modelContext: context
    )
    try await entryResults.performFetch()
    let entry = try #require(entryResults.fetchedObjects?.first)
    let request = try #require(context.model(for: entry.primaryRequestID))
    #expect(request.statusCode == 201)
    #expect(request.state == .finished)

    let body = try await runtime.container.network.responseBody(for: request.id)
    #expect(body.data == "ready body")
    #expect(!body.base64Encoded)
    #expect((await runtime.counterSnapshot()).completedCommandCount > 0)

    await entryResults.close()
    await domResults.close()
    await runtime.close()
    #expect(runtime.container.state == .closed)
    #expect(await runtime.lifecycleState == .closed)
}

@MainActor
@Test
func dataKitTestingReplacementSeparatesFeatureAndConsumerBoundaries()
    async throws
{
    let runtime = try await WebInspectorDataKitTestRuntime.start(
        scenario: .init(
            configuration: .init(
                enabledFeatures: [.dom, .network, .consoleRuntime]
            ),
            document: .init(
                id: "shared-document",
                children: [
                    .element(id: "shared-node", name: "main")
                ]),
            networkReplay: [
                .init(
                    id: "shared-request",
                    url: "https://example.test/initial"
                )
            ]
        )
    )
    let context = runtime.container.mainContext
    let domResults = WebInspectorFetchedResultsController<DOMNode>(
        modelContext: context
    )
    let networkResults = WebInspectorFetchedResultsController<NetworkRequest>(
        modelContext: context
    )
    try await domResults.performFetch()
    try await networkResults.performFetch()
    var domUpdates = domResults.updates.makeAsyncIterator()
    var networkUpdates = networkResults.updates.makeAsyncIterator()
    guard case .initial = await domUpdates.next() else {
        preconditionFailure("A fetched DOM query must publish its initial state.")
    }
    guard case .initial = await networkUpdates.next() else {
        preconditionFailure("A fetched Network query must publish its initial state.")
    }

    let oldNode = try #require(
        domResults.fetchedObjects?.first { $0.localName == "main" }
    )
    let oldRequest = try #require(networkResults.fetchedObjects?.first)
    let baseline = try await runtime.boundarySnapshot()

    let replacement = try await runtime.replacePage(
        with: .init(
            id: "shared-document",
            children: [
                .element(id: "shared-node", name: "article")
            ]),
        networkReplay: [
            .init(
                id: "shared-request",
                url: "https://example.test/replacement"
            )
        ]
    )

    for featureID in [
        WebInspectorFeatureID.dom,
        .network,
        .consoleRuntime,
    ] {
        let oldGeneration = try #require(
            baseline.readyGeneration(for: featureID)
        )
        let newGeneration = try #require(
            replacement.readyGeneration(for: featureID)
        )
        #expect(newGeneration > oldGeneration)
    }

    while domResults.fetchedObjects?.contains(where: {
        $0.localName == "article"
    }) != true {
        guard await domUpdates.next() != nil else {
            preconditionFailure("The DOM query closed before applying the replacement.")
        }
    }
    while networkResults.fetchedObjects?.contains(where: {
        $0.url == "https://example.test/replacement"
    }) != true {
        guard await networkUpdates.next() != nil else {
            preconditionFailure("The Network query closed before applying the replacement.")
        }
    }

    let newNode = try #require(
        domResults.fetchedObjects?.first { $0.localName == "article" }
    )
    let newRequest = try #require(networkResults.fetchedObjects?.first)
    #expect(newNode.id != oldNode.id)
    #expect(newRequest.id != oldRequest.id)
    #expect(context.registeredModel(for: oldNode.id) == nil)
    #expect(context.registeredModel(for: oldRequest.id) == nil)

    await networkResults.close()
    await domResults.close()
    await runtime.close()
}

@MainActor
@Test
func dataKitTestingRawDOMInputCompletesThroughConsumerOwnedQueries()
    async throws
{
    let runtime = try await WebInspectorDataKitTestRuntime.start(
        scenario: .init(
            configuration: .init(enabledFeatures: [.dom]),
            document: .init(children: [
                .element(id: "body", name: "body")
            ])
        )
    )
    let context = runtime.container.mainContext
    let results = WebInspectorFetchedResultsController<DOMNode>(
        modelContext: context
    )
    try await results.performFetch()
    var updates = results.updates.makeAsyncIterator()
    guard case .initial = await updates.next() else {
        preconditionFailure("A fetched DOM query must publish its initial state.")
    }
    let body = try #require(
        results.fetchedObjects?.first { $0.localName == "body" }
    )

    try await runtime.emitDOMAttributeModified(
        nodeID: "body",
        name: "data-state",
        value: "ready"
    )
    _ = try #require(await updates.next())
    #expect(body.attributes["data-state"] == "ready")
    #expect(context.model(for: body.id) === body)

    try await runtime.emitDOMChildNodeInserted(
        parentID: "body",
        node: .element(id: "inserted", name: "strong")
    )
    _ = try #require(await updates.next())
    let inserted = try #require(
        results.fetchedObjects?.first { $0.localName == "strong" }
    )

    try await runtime.emitDOMChildNodeRemoved(
        parentID: "body",
        nodeID: "inserted"
    )
    _ = try #require(await updates.next())
    #expect(context.registeredModel(for: inserted.id) == nil)

    await results.close()
    await runtime.close()
}

@MainActor
@Test
func dataKitTestingSupportsContainerIssuedModelActors() async throws {
    let runtime = try await WebInspectorDataKitTestRuntime.start(
        scenario: .init(
            configuration: .init(enabledFeatures: [.network]),
            networkReplay: [
                .init(
                    id: "shared-request",
                    url: "https://example.test/shared"
                )
            ]
        )
    )
    let context = runtime.container.mainContext
    let mainResults = WebInspectorFetchedResultsController<NetworkEntry>(
        modelContext: context
    )
    try await mainResults.performFetch()
    let mainEntry = try #require(mainResults.fetchedObjects?.first)

    let worker = try ProductTestModelActor(modelContainer: runtime.container)
    let workerSnapshot = try await worker.networkEntries()
    #expect(workerSnapshot.ids == [mainEntry.id])
    #expect(workerSnapshot.objectIdentities != [ObjectIdentifier(mainEntry)])

    await worker.closeModelContext()
    await mainResults.close()
    await runtime.close()
}

@MainActor
@Test
func dataKitTestingPreservesRequestBodyIdentityAcrossEnrichment()
    async throws
{
    let runtime = try await WebInspectorDataKitTestRuntime.start(
        scenario: .init(
            configuration: .init(enabledFeatures: [.network])
        )
    )
    let context = runtime.container.mainContext
    let results = WebInspectorFetchedResultsController<NetworkRequest>(
        modelContext: context
    )
    try await results.performFetch()
    var updates = results.updates.makeAsyncIterator()
    guard case .initial = await updates.next() else {
        preconditionFailure("A fetched Network query must publish its initial state.")
    }
    let request = WebInspectorDataKitTestRuntime.NetworkRequest(
        id: "staged-request",
        url: "https://example.test/form",
        method: "POST",
        responseRequestHeaders: [
            "content-type": "application/x-www-form-urlencoded"
        ],
        postData: "name=Jane+Doe"
    )

    try await runtime.emitNetworkRequestWillBeSent(request)
    _ = try #require(await updates.next())
    let model = try #require(results.fetchedObjects?.first)
    let body = try #require(model.requestBody)
    #expect(body.kind == .text)

    try await runtime.emitNetworkResponseReceived(request)
    _ = try #require(await updates.next())
    #expect(model.requestBody === body)
    #expect(body.kind == .form)
    #expect(body.text == "name=Jane+Doe")
    #expect(
        model.requestHeaders["content-type"]
            == "application/x-www-form-urlencoded"
    )

    try await runtime.emitNetworkLoadingFinished(request)
    _ = try #require(await updates.next())
    #expect(model.state == .finished)

    await results.close()
    await runtime.close()
}

@MainActor
@Test
func dataKitTestingCountsReplacementBoundaryAndClosesDeterministically()
    async throws
{
    let runtime = try await WebInspectorDataKitTestRuntime.start(
        scenario: .init(
            configuration: .init(enabledFeatures: [.network])
        )
    )
    let context = runtime.container.mainContext
    let results = WebInspectorFetchedResultsController<NetworkRequest>(
        modelContext: context
    )
    try await results.performFetch()
    var updates = results.updates.makeAsyncIterator()
    guard case .initial = await updates.next() else {
        preconditionFailure("A fetched Network query must publish its initial state.")
    }
    let baseline = try await runtime.boundarySnapshot()

    let replacement = try await runtime.replacePage(with: .init())
    let oldGeneration = try #require(
        baseline.readyGeneration(for: .network)
    )
    let newGeneration = try #require(
        replacement.readyGeneration(for: .network)
    )
    #expect(newGeneration > oldGeneration)
    #expect(
        replacement.counters.acceptedRawInputCount
            == baseline.counters.acceptedRawInputCount + 2
    )
    #expect(
        replacement.counters.pageReplacementCount
            == baseline.counters.pageReplacementCount + 1
    )
    _ = try #require(await updates.next())

    await results.close()
    await runtime.close()
    await runtime.close()
    #expect(await runtime.lifecycleState == .closed)
    do {
        try await runtime.emitNetworkRequest(
            .init(id: "after-close", url: "https://example.test/closed")
        )
        Issue.record("A closed testing runtime accepted raw input.")
    } catch let error as WebInspectorDataKitTestRuntime.RuntimeError {
        #expect(error == .closed)
    } catch {
        Issue.record("Expected RuntimeError.closed, got \(error).")
    }
}

@MainActor
@Test
func dataKitTestingEscalatesRequiredNetworkBootstrapFailure() async {
    do {
        _ = try await WebInspectorDataKitTestRuntime.start(
            scenario: .init(
                configuration: .init(enabledFeatures: [.network]),
                attachFailure: .init(
                    domain: .network,
                    message: "injected Network startup failure"
                )
            )
        )
        Issue.record("A required Network bootstrap failure did not fail the connection.")
    } catch let WebInspectorDataKitTestRuntime.RuntimeError.connectionFailed(failure) {
        guard case let .requiredFeature(featureID, .bootstrap(description)) = failure else {
            Issue.record("Expected a required-feature bootstrap failure, got \(failure).")
            return
        }
        #expect(featureID == .network)
        #expect(description.message.contains("injected Network startup failure"))
    } catch {
        Issue.record("Expected a connection failure, got \(error).")
    }
}

@MainActor
@Test
func dataKitTestingEscalatesExhaustedRequiredNetworkRecovery() async throws {
    let request = WebInspectorDataKitTestRuntime.NetworkRequest(
        id: "recovery-exhaustion",
        url: "https://example.test/recovery-exhaustion"
    )
    let runtime = try await WebInspectorDataKitTestRuntime.start(
        scenario: .init(
            configuration: .init(enabledFeatures: [.dom, .network]),
            networkReplay: [request]
        )
    )
    var networkStates = runtime.container.network.stateUpdates.makeAsyncIterator()
    guard case let .ready(_, initialRevision) = await networkStates.next() else {
        preconditionFailure("A started Network feature must initially be ready.")
    }

    try await runtime.emitNetworkLoadingFinished(request)
    var observedRecoveredRevision = false
    recovery: while let state = await networkStates.next() {
        switch state {
        case let .ready(_, revision) where revision > initialRevision:
            observedRecoveredRevision = true
            break recovery
        case let .unavailable(_, error):
            Issue.record("Required Network published feature-local failure: \(error).")
            break recovery
        case .disabled:
            Issue.record("The connection ended during the first recovery attempt.")
            break recovery
        case .synchronizing, .ready, .recovering:
            continue
        }
    }
    #expect(observedRecoveredRevision)

    var terminalNetworkStates = runtime.container.network.stateUpdates
        .makeAsyncIterator()
    guard case .ready = await terminalNetworkStates.next() else {
        preconditionFailure("The first Network recovery must restore readiness.")
    }
    var containerStates = runtime.container.stateUpdates.makeAsyncIterator()
    guard case .attached = await containerStates.next() else {
        preconditionFailure("The recovered container must remain attached.")
    }

    try await runtime.emitNetworkLoadingFinished(request)
    terminal: while let state = await terminalNetworkStates.next() {
        switch state {
        case let .unavailable(_, error):
            Issue.record("Required Network published feature-local failure: \(error).")
            break terminal
        case .disabled:
            break terminal
        case .synchronizing, .ready, .recovering:
            continue
        }
    }

    var observedFailure: WebInspectorConnectionFailure?
    containerFailure: while let state = await containerStates.next() {
        switch state {
        case let .failed(_, failure):
            observedFailure = failure
            break containerFailure
        case .detached, .attaching, .attached, .detaching:
            continue
        case .closing, .closed:
            preconditionFailure("The runtime closed without publishing the Network failure.")
        }
    }
    let failure = try #require(observedFailure)
    guard case let .requiredFeature(
        featureID,
        .recoveryBudgetExhausted(description)
    ) = failure else {
        Issue.record("Expected exhausted required-Network recovery, got \(failure).")
        await runtime.close()
        return
    }
    #expect(featureID == .network)
    #expect(description.code == "network.recovery.exhausted")
    #expect(runtime.container.network.state == .disabled)
    #expect(runtime.container.dom.state == .disabled)

    await runtime.close()
}

private struct ProductTestActorSnapshot: Sendable {
    let ids: [NetworkEntry.ID]
    let objectIdentities: [ObjectIdentifier]
}

@WebInspectorModelActor
private actor ProductTestModelActor {
    func networkEntries() async throws -> ProductTestActorSnapshot {
        let results = WebInspectorFetchedResultsController<NetworkEntry>(
            modelContext: modelContext
        )
        try await results.performFetch()
        let models = results.fetchedObjects ?? []
        let snapshot = ProductTestActorSnapshot(
            ids: models.map(\.id),
            objectIdentities: models.map(ObjectIdentifier.init)
        )
        await results.close()
        return snapshot
    }
}

private extension WebInspectorDataKitTestRuntime.BoundarySnapshot {
    func readyGeneration(
        for featureID: WebInspectorFeatureID
    ) -> WebInspectorPageGeneration? {
        guard case let .ready(generation, _) = featureState(for: featureID) else {
            return nil
        }
        return generation
    }
}

private extension WebInspectorModelContainer.State {
    var isAttached: Bool {
        if case .attached = self {
            true
        } else {
            false
        }
    }
}
