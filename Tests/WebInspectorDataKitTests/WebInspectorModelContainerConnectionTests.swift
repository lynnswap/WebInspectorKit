import Testing
@testable import WebInspectorDataKit

@MainActor
@Test
func modelContainerPublishesOwnedAttachDetachAndCloseLifecycle() async throws {
    try await withDataKitTestRuntime { runtime in
        let container = WebInspectorModelContainer(
            configuration: .init(enabledFeatures: [])
        )
        var states = container.stateUpdates.makeAsyncIterator()

        #expect(await states.next() == .detached)
        try await container.attach(owning: runtime.proxy)

        guard case let .attaching(generation) = await states.next() else {
            Issue.record("Expected an attaching state.")
            await container.close()
            return
        }
        #expect(
            await states.next()
                == .attached(generation: generation)
        )
        #expect(
            container.state
                == .attached(generation: generation)
        )

        await container.detach()
        #expect(
            await states.next()
                == .detaching(generation: generation)
        )
        #expect(await states.next() == .detached)
        #expect(container.state == .detached)

        await container.close()
        #expect(await states.next() == .closing)
        #expect(await states.next() == .closed)
        #expect(await states.next() == nil)

        var lateStates = container.stateUpdates.makeAsyncIterator()
        #expect(await lateStates.next() == .closed)
        #expect(await lateStates.next() == nil)
    }
}
