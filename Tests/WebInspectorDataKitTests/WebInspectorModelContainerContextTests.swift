import Testing
@testable import WebInspectorDataKit

@MainActor
@Test
func mainContextIsStableUntilExplicitCloseAndContainerCloseIsTerminal()
    async throws
{
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.network])
    )
    let first = container.mainContext

    #expect(first === container.mainContext)
    #expect(first.container === container)

    await first.close()
    let replacement = container.mainContext
    #expect(replacement !== first)
    #expect(replacement.container === container)

    await container.close()
    let closed = container.mainContext
    #expect(closed === container.mainContext)
    await #expect(throws: WebInspectorFetchError.contextClosed) {
        _ = try await closed.fetchIdentifiers(
            WebInspectorFetchDescriptor<NetworkEntry>()
        )
    }
}

@MainActor
@Test
func modelActorMacroIssuesIndependentContainerOwnedContexts() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.network])
    )
    let first = try ContextCutoverModelActor(modelContainer: container)
    let second = try ContextCutoverModelActor(modelContainer: container)

    #expect(await first.contextIdentity() != second.contextIdentity())
    #expect(first.modelContainer === container)
    #expect(second.modelContainer === container)

    await first.closeModelContext()
    await #expect(throws: WebInspectorFetchError.contextClosed) {
        _ = try await first.fetchNetworkEntryIDs()
    }

    #expect(try await second.fetchNetworkEntryIDs().isEmpty)
    await second.closeModelContext()
    await container.close()
}

@WebInspectorModelActor
private actor ContextCutoverModelActor {
    func contextIdentity() -> ObjectIdentifier {
        ObjectIdentifier(modelContext)
    }

    func fetchNetworkEntryIDs() async throws -> [NetworkEntry.ID] {
        try await modelContext.fetchIdentifiers(
            WebInspectorFetchDescriptor<NetworkEntry>()
        )
    }
}
