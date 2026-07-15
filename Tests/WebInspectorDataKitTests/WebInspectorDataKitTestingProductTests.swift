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
func dataKitTestingReportsBootstrapFailureAsConnectionFailure() async throws {
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
        Issue.record("An injected Network bootstrap failure started a runtime.")
    } catch let WebInspectorDataKitTestRuntime.RuntimeError.connectionFailed(failure) {
        guard case let .native(description) = failure else {
            Issue.record("Expected a native feature failure, got \(failure).")
            return
        }
        #expect(description.message.contains("injected Network startup failure"))
    } catch {
        Issue.record("Expected RuntimeError.connectionFailed, got \(error).")
    }
}

@MainActor
@Test
func dataKitTestingFailsConnectionOnMalformedNetworkLifecycle() async throws {
    let request = WebInspectorDataKitTestRuntime.NetworkRequest(
        id: "malformed-lifecycle",
        url: "https://example.test/malformed-lifecycle"
    )
    let runtime = try await WebInspectorDataKitTestRuntime.start(
        scenario: .init(
            configuration: .init(enabledFeatures: [.dom, .network]),
            networkReplay: [request]
        )
    )
    var containerStates = runtime.container.stateUpdates.makeAsyncIterator()
    guard case .attached = await containerStates.next() else {
        preconditionFailure("The test runtime must initially be attached.")
    }

    try await runtime.emitNetworkLoadingFinished(request)
    var failure: WebInspectorConnectionFailure?
    while let state = await containerStates.next() {
        switch state {
        case let .failed(_, currentFailure):
            failure = currentFailure
        case .detached, .attaching, .attached, .detaching, .closing, .closed:
            continue
        }
        break
    }

    guard case let .native(description) = try #require(failure) else {
        Issue.record("Expected a native Network protocol failure.")
        await runtime.close()
        return
    }
    #expect(description.code.contains("network.protocol"))
    #expect(runtime.container.dom.state == .disabled)
    #expect(runtime.container.network.state == .disabled)

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
