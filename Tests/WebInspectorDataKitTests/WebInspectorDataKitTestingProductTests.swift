import Testing
@testable import WebInspectorDataKit
import WebInspectorDataKitTesting
import WebInspectorProxyKit

@MainActor
@Test
func dataKitTestingStartsContainerReadyWithCanonicalNetworkEntryAndBodyGateway()
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
            configuration: .init(domains: [.dom, .network]),
            document: .init(children: [
                .element(id: "button", name: "button")
            ]),
            networkReplay: [replay]
        ),
        isolation: MainActor.shared
    )

    #expect(runtime.container.state == .attached)
    let domResults = try await WebInspectorFetchedResultsController<DOMNode, Never>(
        modelContext: runtime.model
    )
    #expect(domResults.snapshot.itemIDs.count == 2)
    #expect(domResults.snapshot.itemIDs.contains { id in
        runtime.model.model(for: id)?.nodeName == "#document"
    })

    let entryResults = try await WebInspectorFetchedResultsController<NetworkEntry, Never>(
        modelContext: runtime.model
    )
    let entryID = try #require(entryResults.snapshot.itemIDs.first)
    let entry = try #require(runtime.model.model(for: entryID))
    let request = try #require(runtime.model.model(for: entry.primaryRequestID))
    #expect(request.statusCode == 201)
    #expect(request.state == .finished)

    let body = try await runtime.model.responseBody(for: request)
    #expect(body.text == "ready body")

    await entryResults.close()
    await domResults.close()
    await runtime.close()
    #expect(runtime.container.state == .closed)
    #expect(runtime.model.state == .closed)
}

@MainActor
@Test
func dataKitTestingScopesReusedRawIDsToTheSynchronizedReplacementPage() async throws {
    let runtime = try await WebInspectorDataKitTestRuntime.start(
        scenario: .init(
            configuration: .init(domains: [.dom, .network]),
            document: .init(id: "shared-document", children: [
                .element(id: "shared-node", name: "main")
            ])
        ),
        isolation: MainActor.shared
    )
    let domResults = try await WebInspectorFetchedResultsController<DOMNode, Never>(
        modelContext: runtime.model
    )
    let oldID = try #require(domResults.snapshot.itemIDs.first { id in
        runtime.model.model(for: id)?.localName == "main"
    })
    _ = try #require(runtime.model.model(for: oldID))

    try await runtime.replacePage(
        with: .init(id: "shared-document", children: [
            .element(id: "shared-node", name: "article")
        ]),
        networkReplay: [
            .init(id: "replacement-request", url: "https://example.test/new")
        ]
    )

    #expect(runtime.container.state == .attached)
    let newNode = try #require(domResults.snapshot.itemIDs.compactMap { id in
        runtime.model.model(for: id)
    }.first { $0.localName == "article" })
    #expect(newNode.localName == "article")
    #expect(newNode.id != oldID)
    #expect(runtime.model.registeredModel(for: oldID) == nil)

    let networkResults = try await WebInspectorFetchedResultsController<NetworkRequest, Never>(
        modelContext: runtime.model
    )
    let requestID = try #require(networkResults.snapshot.itemIDs.first)
    #expect(runtime.model.model(for: requestID)?.state == .finished)

    await networkResults.close()
    await domResults.close()
    await runtime.close()
}

@MainActor
@Test
func dataKitTestingVendsContextLocalIdentityFromOneContainer() async throws {
    let runtime = try await WebInspectorDataKitTestRuntime.start(
        scenario: .init(
            configuration: .init(domains: [.network]),
            networkReplay: [
                .init(id: "shared-request", url: "https://example.test/shared")
            ]
        ),
        isolation: MainActor.shared
    )
    let secondContext = try await runtime.container.makeContext(
        isolation: MainActor.shared
    )
    let firstResults = try await WebInspectorFetchedResultsController<NetworkEntry, Never>(
        modelContext: runtime.model
    )
    let secondResults = try await WebInspectorFetchedResultsController<NetworkEntry, Never>(
        modelContext: secondContext
    )
    let firstID = try #require(firstResults.snapshot.itemIDs.first)
    let secondID = try #require(secondResults.snapshot.itemIDs.first)
    let firstEntry = try #require(runtime.model.model(for: firstID))
    let secondEntry = try #require(secondContext.model(for: secondID))

    #expect(firstID == secondID)
    #expect(firstEntry !== secondEntry)

    try await runtime.replacePage(
        with: .init(),
        networkReplay: [
            .init(
                id: "shared-request",
                url: "https://example.test/replacement"
            )
        ]
    )
    let replacementFirstID = try #require(
        firstResults.snapshot.itemIDs.first
    )
    let replacementSecondID = try #require(
        secondResults.snapshot.itemIDs.first
    )
    let replacementFirstEntry = try #require(
        runtime.model.model(for: replacementFirstID)
    )
    let replacementSecondEntry = try #require(
        secondContext.model(for: replacementSecondID)
    )
    #expect(replacementFirstID == replacementSecondID)
    #expect(replacementFirstID != firstID)
    #expect(replacementFirstEntry !== replacementSecondEntry)
    #expect(runtime.model.registeredModel(for: firstID) == nil)
    #expect(secondContext.registeredModel(for: secondID) == nil)

    await secondResults.close()
    await firstResults.close()
    await secondContext.close()
    await runtime.close()
}

@MainActor
@Test
func dataKitTestingWaitsForAnEmptyNetworkReplacementRevision() async throws {
    let runtime = try await WebInspectorDataKitTestRuntime.start(
        scenario: .init(
            configuration: .init(domains: [.network])
        ),
        isolation: MainActor.shared
    )
    let baselineRevision = await runtime.container.core.currentRevision

    try await runtime.replacePage(with: .init())

    let replacementRevision = await runtime.container.core.currentRevision
    #expect(replacementRevision > baselineRevision)
    #expect(
        runtime.model.appliedContainerRevisionForTesting
            == replacementRevision
    )
    await runtime.close()
}

@MainActor
@Test
func dataKitTestingWaitsForConsoleAndRuntimeReplacementRevisions()
    async throws
{
    let runtime = try await WebInspectorDataKitTestRuntime.start(
        scenario: .init(
            configuration: .init(domains: [.console, .runtime])
        ),
        isolation: MainActor.shared
    )
    let baselineRevision = await runtime.container.core.currentRevision

    try await runtime.replacePage(with: .init())

    let replacementRevision = await runtime.container.core.currentRevision
    #expect(replacementRevision > baselineRevision)
    #expect(
        runtime.model.appliedContainerRevisionForTesting
            == replacementRevision
    )
    await runtime.close()
}

@MainActor
@Test
func dataKitTestingInjectsAttachmentFailureWithoutLeakingRuntimeOwnership() async {
    do {
        _ = try await WebInspectorDataKitTestRuntime.start(
            scenario: .init(
                configuration: .init(domains: [.network]),
                attachFailure: .init(
                    domain: .network,
                    message: "injected Network startup failure"
                )
            ),
            isolation: MainActor.shared
        )
        Issue.record("Expected the injected DataKit attachment failure.")
    } catch let failure as WebInspectorModelContainer.Failure {
        guard case let .bootstrap(domain, message) = failure else {
            Issue.record("Expected a bootstrap failure, got \(failure).")
            return
        }
        #expect(domain == .network)
        #expect(message.contains("injected Network startup failure"))
    } catch {
        Issue.record("Expected a DataKit model failure, got \(error).")
    }
}
