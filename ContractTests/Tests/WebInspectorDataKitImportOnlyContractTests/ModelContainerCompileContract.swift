import Testing
import WebInspectorDataKit

@MainActor
@Test
func modelContainerPublicLifecycleSurfaceCompilesWithoutProxyKitImport() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [.css, .network])
    )
    let other = WebInspectorModelContainer()

    #expect(container.configuration.domains == [.dom, .css, .network])
    #expect(container == container)
    #expect(container != other)
    #expect(container.state == .detached)

    var states = container.stateUpdates.makeAsyncIterator()
    #expect(await states.next() == .detached)

    let mainContext = container.mainContext
    #expect(mainContext === container.mainContext)
    let customContext = try await container.makeContext(
        isolation: MainActor.shared
    )
    #expect(customContext != mainContext)
    await customContext.close()

    await container.detach()
    await container.close()

    #expect(container.state == .closed)
    #expect(await states.next() == .closed)
    #expect(await states.next() == nil)
}
