import Testing
import WebInspectorDataKit

@Test
func modelContainerPublicLifecycleSurfaceCompilesWithoutProxyKitImport() async {
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

    await container.detach()
    await container.close()

    #expect(container.state == .closed)
    #expect(await states.next() == .closed)
    #expect(await states.next() == nil)
}
