import Foundation
import Testing
import WebInspectorDataKit
import WebInspectorDataKitTesting

@MainActor
@Test
func modelActorQueriesDataKitRuntimeFromConsumerPackage() async throws {
    let runtime = try await WebInspectorDataKitTestRuntime.start(
        scenario: .init(
            configuration: .init(enabledFeatures: [.network]),
            networkReplay: [
                .init(
                    id: "actor-contract-request",
                    url: "https://example.test/model-actor"
                )
            ]
        )
    )
    let consumer = try ContractDataKitActor(modelContainer: runtime.container)

    let snapshot = try await consumer.networkEntries()
    #expect(snapshot.urls == ["https://example.test/model-actor"])
    #expect(snapshot.itemIDs.count == 1)

    await consumer.closeModelContext()
    await runtime.close()
}

private struct ContractNetworkSnapshot: Sendable {
    let itemIDs: [NetworkEntry.ID]
    let urls: [String]
}

@WebInspectorModelActor
private actor ContractDataKitActor {
    func networkEntries() async throws -> ContractNetworkSnapshot {
        let controller = WebInspectorFetchedResultsController<NetworkEntry>(
            fetchDescriptor: .init(
                sortBy: [SortDescriptor(\.insertionOrdinal)]
            ),
            modelContext: modelContext
        )
        try await controller.performFetch()
        let models = controller.fetchedObjects ?? []
        let snapshot = ContractNetworkSnapshot(
            itemIDs: controller.snapshot?.itemIDs ?? [],
            urls: models.map(\.url)
        )
        await controller.close()
        return snapshot
    }
}
