import Testing
@testable import WebInspectorDataKit
import WebInspectorDataKitTesting
import WebInspectorProxyKit

@MainActor
@Test
func networkFacadeLoadsBodiesAndClearsCanonicalResults() async throws {
    let runtime = try await WebInspectorDataKitTestRuntime.start(
        scenario: .init(
            configuration: .init(enabledFeatures: [.network]),
            networkReplay: [
                .init(
                    id: "request",
                    url: "https://example.test/resource",
                    body: Network.Body(data: "response")
                )
            ]
        )
    )
    let context = runtime.container.mainContext
    let results = WebInspectorFetchedResultsController<NetworkRequest>(
        modelContext: context
    )

    do {
        try await results.performFetch()
        var updates = results.updates.makeAsyncIterator()
        guard case .initial = await updates.next() else {
            Issue.record("Expected the accepted initial Network result.")
            await results.close()
            await runtime.close()
            return
        }
        let request = try #require(results.fetchedObjects?.first)
        let body = try await runtime.container.network.responseBody(
            for: request.id
        )
        #expect(body.data == "response")

        try await runtime.container.network.clear()
        _ = try #require(await updates.next())
        #expect(results.fetchedObjects?.isEmpty == true)
        #expect(context.registeredModel(for: request.id) == nil)

        await results.close()
        await runtime.close()
    } catch {
        await results.close()
        await runtime.close()
        throw error
    }
}

@MainActor
@Test
func replacedNetworkIdentityIsRejectedAtTheFeatureFacade() async throws {
    let runtime = try await WebInspectorDataKitTestRuntime.start(
        scenario: .init(
            configuration: .init(enabledFeatures: [.network]),
            networkReplay: [
                .init(
                    id: "request",
                    url: "https://example.test/old",
                    body: Network.Body(data: "old")
                )
            ]
        )
    )
    let results = WebInspectorFetchedResultsController<NetworkRequest>(
        modelContext: runtime.container.mainContext
    )

    do {
        try await results.performFetch()
        let oldID = try #require(results.fetchedObjects?.first?.id)
        var updates = results.updates.makeAsyncIterator()
        guard case .initial = await updates.next() else {
            Issue.record("Expected the accepted initial Network result.")
            await results.close()
            await runtime.close()
            return
        }

        _ = try await runtime.replacePage(
            with: .init(),
            networkReplay: [
                .init(
                    id: "request",
                    url: "https://example.test/new",
                    body: Network.Body(data: "new")
                )
            ]
        )
        _ = try #require(await updates.next())

        await #expect(throws: WebInspectorCommandError.staleIdentifier) {
            _ = try await runtime.container.network.responseBody(for: oldID)
        }

        await results.close()
        await runtime.close()
    } catch {
        await results.close()
        await runtime.close()
        throw error
    }
}
