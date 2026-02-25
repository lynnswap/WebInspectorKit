import Testing
@testable import WebInspectorKitCore

@MainActor
struct WIRuntimeActorTests {
    @Test
    func lifecycleTransitionsKeepOrdering() async {
        let domSession = DOMSession()
        let networkSession = NetworkSession()
        let runtime = WIRuntimeActor(
            domRuntime: WIDOMRuntimeActor(session: domSession),
            networkRuntime: WINetworkRuntimeActor(session: networkSession)
        )

        await runtime.dispatch(
            .configureTabs([
                WITabRuntimeDescriptor(id: "wi_dom", requires: [.dom], activation: .init(domLiveUpdates: true)),
                WITabRuntimeDescriptor(id: "wi_network", requires: [.network], activation: .init(networkLiveLogging: true))
            ])
        )
        await runtime.dispatch(.selectTab("wi_network"))
        await runtime.dispatch(.connected)

        var state = await runtime.currentState()
        #expect(state.lifecycle == .active)
        #expect(state.selectedTabID == "wi_network")

        await runtime.dispatch(.suspended)
        state = await runtime.currentState()
        #expect(state.lifecycle == .suspended)
        #expect(state.selectedTabID == "wi_network")

        await runtime.dispatch(.disconnected)
        state = await runtime.currentState()
        #expect(state.lifecycle == .disconnected)
        #expect(state.selectedTabID == nil)
    }

    @Test
    func configureTabsNormalizesInvalidSelection() async {
        let runtime = WIRuntimeActor(
            domRuntime: WIDOMRuntimeActor(session: DOMSession()),
            networkRuntime: WINetworkRuntimeActor(session: NetworkSession())
        )

        await runtime.dispatch(
            .configureTabs([
                WITabRuntimeDescriptor(id: "a"),
                WITabRuntimeDescriptor(id: "b")
            ])
        )
        await runtime.dispatch(.selectTab("missing"))

        let state = await runtime.currentState()
        #expect(state.selectedTabID == "a")
    }
}
