import Testing
import WebInspectorDataKit

@MainActor
@Test
func modelContainerPublicLifecycleSurfaceCompilesWithoutProxyKitImport() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.dom, .network])
    )
    let other = WebInspectorModelContainer()

    #expect(container.configuration.enabledFeatures == [.dom, .network])
    #expect(container == container)
    #expect(container != other)
    #expect(container.state == .detached)
    #expect(container.dom.state == .disabled)
    #expect(container.network.state == .disabled)

    var states = container.stateUpdates.makeAsyncIterator()
    #expect(await states.next() == .detached)

    let mainContext = container.mainContext
    #expect(mainContext === container.mainContext)
    let worker = try ContractModelActor(modelContainer: container)
    #expect(worker.modelContainer === container)
    await worker.closeModelContext()

    await container.close()

    #expect(container.state == .closed)
    #expect(await states.next() == .closed)
    #expect(await states.next() == nil)
}

@WebInspectorModelActor
private actor ContractModelActor {
    func fetchNetworkRequestIDs() async throws -> [NetworkRequest.ID] {
        try await modelContext.fetchIdentifiers(
            WebInspectorFetchDescriptor<NetworkRequest>()
        )
    }
}
