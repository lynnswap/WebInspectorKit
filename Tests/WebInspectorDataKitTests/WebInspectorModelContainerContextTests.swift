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
    await #expect(throws: WebInspectorFetchError.containerClosed) {
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
    #expect(await first.isModelContextOpen())
    #expect(await second.isModelContextOpen())

    await first.closeModelContext()
    #expect(await first.isModelContextOpen() == false)
    #expect(await second.isModelContextOpen())

    await second.closeModelContext()
    #expect(await second.isModelContextOpen() == false)
    await container.close()
}

@WebInspectorModelActor
private actor ContextCutoverModelActor {
    func contextIdentity() -> ObjectIdentifier {
        ObjectIdentifier(modelContext)
    }

    func isModelContextOpen() -> Bool {
        modelContext.lifecycle.isOpen
    }
}
