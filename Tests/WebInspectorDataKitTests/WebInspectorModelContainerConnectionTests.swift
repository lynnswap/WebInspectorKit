import Testing
@testable import WebInspectorDataKit

@MainActor
@Test
func modelContainerPublishesLatestOwnedLifecycleState() async throws {
    try await withDataKitTestRuntime { runtime in
        let container = WebInspectorModelContainer(
            configuration: .init(enabledFeatures: [])
        )
        var states = container.stateUpdates.makeAsyncIterator()

        #expect(await states.next() == .detached)
        try await container.attach(owning: runtime.proxy)

        guard case let .attached(generation) = await states.next() else {
            Issue.record("Expected the latest attached state.")
            await container.close()
            return
        }
        #expect(
            container.state
                == .attached(generation: generation)
        )

        await container.detach()
        #expect(await states.next() == .detached)
        #expect(container.state == .detached)

        await container.close()
        #expect(await states.next() == .closed)
        #expect(await states.next() == nil)

        var lateStates = container.stateUpdates.makeAsyncIterator()
        #expect(await lateStates.next() == .closed)
        #expect(await lateStates.next() == nil)
    }
}
