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
            .configurePanes([
                WIPaneRuntimeDescriptor(id: "wi_dom", requires: [.dom], activation: .init(domLiveUpdates: true)),
                WIPaneRuntimeDescriptor(id: "wi_network", requires: [.network], activation: .init(networkLiveLogging: true))
            ])
        )
        await runtime.dispatch(.selectPane("wi_network"))
        await runtime.dispatch(.connected)

        var state = await runtime.currentState()
        #expect(state.lifecycle == .active)
        #expect(state.selectedPaneID == "wi_network")

        await runtime.dispatch(.suspended)
        state = await runtime.currentState()
        #expect(state.lifecycle == .suspended)
        #expect(state.selectedPaneID == "wi_network")

        await runtime.dispatch(.disconnected)
        state = await runtime.currentState()
        #expect(state.lifecycle == .disconnected)
        #expect(state.selectedPaneID == nil)
    }

    @Test
    func configurePanesNormalizesInvalidSelection() async {
        let runtime = WIRuntimeActor(
            domRuntime: WIDOMRuntimeActor(session: DOMSession()),
            networkRuntime: WINetworkRuntimeActor(session: NetworkSession())
        )

        await runtime.dispatch(
            .configurePanes([
                WIPaneRuntimeDescriptor(id: "a"),
                WIPaneRuntimeDescriptor(id: "b")
            ])
        )
        await runtime.dispatch(.selectPane("missing"))

        let state = await runtime.currentState()
        #expect(state.selectedPaneID == "a")
    }
}
