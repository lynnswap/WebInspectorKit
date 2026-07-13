import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@Test
func modelSchemaInventoryFiltersDomainsInCanonicalModelOrder() {
    expectInventory([], contains: [])
    expectInventory([.dom], contains: [DOMNode.self])
    expectInventory([.css], contains: [DOMNode.self])
    expectInventory(
        [.network],
        contains: [NetworkRequest.self, NetworkEntry.self]
    )
    expectInventory([.console], contains: [ConsoleMessage.self])
    expectInventory([.runtime], contains: [RuntimeContext.self])
    expectInventory(
        [.console, .runtime],
        contains: [ConsoleMessage.self, RuntimeContext.self]
    )
    expectInventory(
        [.dom, .css, .network, .console, .runtime],
        contains: [
            DOMNode.self,
            NetworkRequest.self,
            NetworkEntry.self,
            ConsoleMessage.self,
            RuntimeContext.self,
        ]
    )
}

@MainActor
@Test
func productionNetworkContainerProvidesGenericQueriesToEveryContext() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [.network])
    )
    let mainContext = container.mainContext
    let customContext = try await container.makeContext(
        isolation: MainActor.shared
    )
    try await mainContext.waitUntilReady()

    let mainRequests = try await mainContext.fetch(
        WebInspectorFetchDescriptor<NetworkRequest>()
    )
    let customRequests = try await customContext.fetch(
        WebInspectorFetchDescriptor<NetworkRequest>()
    )
    #expect(mainRequests.isEmpty)
    #expect(customRequests.isEmpty)

    let mainEntries = try await WebInspectorFetchedResultsController<
        NetworkEntry,
        Never
    >(
        modelContext: mainContext,
        isolation: MainActor.shared
    )
    let customEntries = try await WebInspectorFetchedResultsController<
        NetworkEntry,
        Never
    >(
        modelContext: customContext,
        isolation: MainActor.shared
    )
    #expect(mainEntries.snapshot.itemIDs.isEmpty)
    #expect(customEntries.snapshot.itemIDs.isEmpty)

    await mainEntries.close()
    await customEntries.close()
    await customContext.close()
    await container.close()
}

private func expectInventory(
    _ domains: Set<ModelDomain>,
    contains modelTypes: [any WebInspectorPersistentModel.Type],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let registry = WebInspectorModelSchemaInventory.registry(
        configuredDomains: domains
    )
    #expect(
        registry.configuredModelTypeIDsInOrder
            == modelTypes.map(ObjectIdentifier.init),
        sourceLocation: sourceLocation
    )
}
