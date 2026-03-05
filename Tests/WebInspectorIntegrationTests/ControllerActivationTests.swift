import Testing
import WebKit
@testable import WebInspectorUI
@testable import WebInspectorEngine
@testable import WebInspectorRuntime

@MainActor
struct ControllerActivationTests {
    @Test
    func connectWithNoNetworkTabsDoesNotAttachNetworkSession() {
        let (controller, _) = makeBoundSession(tabs: [.dom(), domSecondaryTab()])
        let webView = makeTestWebView()

        controller.connect(to: webView)

        #expect(controller.dom.session.lastPageWebView === webView)
        #expect(controller.network.session.lastPageWebView == nil)
        #expect(controller.network.session.mode == .stopped)
    }

    @Test
    func customTabWithoutBuiltInIdentifiersDoesNotAttachNetworkSession() {
        let customTab = WITab(
            id: "custom_network",
            title: "Custom Network",
            systemImage: "network"
        )
        let (controller, _) = makeBoundSession(tabs: [customTab])
        let webView = makeTestWebView()

        controller.connect(to: webView)

        #expect(controller.network.session.lastPageWebView == nil)
        #expect(controller.network.session.mode == .stopped)
    }

    @Test
    func customTabWithoutBuiltInIdentifiersDoesNotAttachDOMSession() {
        let customTab = WITab(
            id: "custom_dom",
            title: "Custom DOM",
            systemImage: "doc"
        )
        let (controller, _) = makeBoundSession(tabs: [customTab])
        let webView = makeTestWebView()

        controller.connect(to: webView)

        #expect(controller.dom.session.lastPageWebView == nil)
        #expect(controller.network.session.lastPageWebView == nil)
        #expect(controller.network.session.mode == .stopped)
    }

    @Test
    func connectWithoutPanelDefaultsNetworkSessionToActiveLogging() {
        let controller = WIModel()
        let webView = makeTestWebView()

        controller.connect(to: webView)

        #expect(controller.network.session.lastPageWebView === webView)
        #expect(controller.network.session.mode == .active)
    }

    @Test
    func selectedTabSwitchesNetworkModeBetweenBufferingAndActive() {
        let (controller, store) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(controller.network.session.mode == .buffering)

        selectTab("wi_network", in: store)
        #expect(controller.network.session.mode == .active)

        selectTab("wi_dom", in: store)
        #expect(controller.network.session.mode == .buffering)
    }

    @Test
    func selectedTabSwitchesDOMAutoSnapshot() {
        let (controller, store) = makeBoundSession(tabs: [.dom(), domSecondaryTab()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(controller.dom.session.isAutoSnapshotEnabled == true)

        selectTab("wi_element", in: store)
        #expect(controller.dom.session.isAutoSnapshotEnabled == false)

        selectTab("wi_dom", in: store)
        #expect(controller.dom.session.isAutoSnapshotEnabled == true)
    }

    @Test
    func connectNilSuspendsWithoutClearingLastPageWebView() {
        let (controller, _) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(controller.dom.session.hasPageWebView == true)
        #expect(controller.dom.session.lastPageWebView === webView)
        #expect(controller.network.session.lastPageWebView === webView)

        controller.connect(to: nil)
        #expect(controller.dom.session.hasPageWebView == false)
        #expect(controller.dom.session.lastPageWebView === webView)
        #expect(controller.network.session.lastPageWebView === webView)
        #expect(controller.network.session.mode == .stopped)
    }

    @Test
    func reconnectAfterSuspendRestoresModeForSelectedTab() {
        let (controller, store) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(controller.network.session.mode == .buffering)

        selectTab("wi_network", in: store)
        #expect(controller.network.session.mode == .active)

        controller.connect(to: nil)
        #expect(controller.network.session.mode == .stopped)

        controller.connect(to: webView)
        #expect(controller.network.session.mode == .active)
    }

    @Test
    func setTabsWhileSuspendedDoesNotReattachSessionsUntilActivated() {
        let (controller, store) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(controller.dom.session.hasPageWebView == true)
        #expect(controller.network.session.hasAttachedPageWebView == true)

        controller.suspend()
        #expect(controller.lifecycle == .suspended)
        #expect(controller.dom.session.hasPageWebView == false)
        #expect(controller.network.session.hasAttachedPageWebView == false)

        store.setTabs([.dom(), .network()])
        #expect(controller.lifecycle == .suspended)
        #expect(controller.dom.session.hasPageWebView == false)
        #expect(controller.network.session.hasAttachedPageWebView == false)

        controller.activateFromUIIfPossible()
        #expect(controller.lifecycle == .active)
        #expect(controller.dom.session.hasPageWebView == true)
        #expect(controller.network.session.hasAttachedPageWebView == true)
    }

    @Test
    func setTabsWhileConnectedReconnectsNewlyRequiredSessions() {
        let (controller, store) = makeBoundSession(tabs: [.dom(), domSecondaryTab()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(controller.network.session.lastPageWebView == nil)

        store.setTabs([.dom(), .network()])
        #expect(controller.network.session.lastPageWebView === webView)
    }

    @Test
    func setTabsWhileConnectedWithSameRequirementsKeepsDOMSelection() {
        let (controller, store) = makeBoundSession(tabs: [.dom(), domSecondaryTab()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        controller.dom.session.graphStore.applySelectionSnapshot(
            .init(
                localID: 42,
                preview: "<div id='selected'>",
                attributes: [],
                path: [],
                selectorPath: "#selected",
                styleRevision: 0
            )
        )

        store.setTabs([.dom(title: "DOM"), domSecondaryTab(title: "Elements")])

        #expect(controller.dom.selectedEntry?.id.localID == 42)
        #expect(controller.dom.selectedEntry?.preview == "<div id='selected'>")
    }

    @Test
    func disconnectKeepsNetworkStoppedForControllerOnlyUsage() {
        let controller = WIModel()
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(controller.network.session.mode == .active)

        controller.disconnect()

        #expect(controller.network.session.mode == .stopped)
        #expect(controller.network.session.lastPageWebView == nil)
    }

    @Test
    func programmaticSelectionAfterDisconnectKeepsSessionsStopped() {
        let (controller, store) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(controller.network.session.mode == .buffering)

        controller.disconnect()
        selectTab("wi_network", in: store)

        #expect(store.selectedTab?.id == "wi_network")
        #expect(controller.network.session.mode == .stopped)
        #expect(controller.network.session.lastPageWebView == nil)
    }

    @Test
    func programmaticSelectionWhileConnectedUpdatesStoreAndMode() {
        let (controller, store) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(store.selectedTab?.id == "wi_dom")

        selectTab("wi_network", in: store)

        #expect(store.selectedTab?.id == "wi_network")
        #expect(controller.network.session.mode == .active)
    }

    @Test
    func repeatedTabSwitchingKeepsStoreAndNetworkModeConsistent() {
        let (controller, store) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        controller.connect(to: webView)

        for iteration in 0..<20 {
            let expectedTabID = iteration.isMultiple(of: 2) ? "wi_network" : "wi_dom"
            let expectedMode: NetworkLoggingMode = expectedTabID == "wi_network" ? .active : .buffering

            selectTab(expectedTabID, in: store)

            #expect(store.selectedTab?.id == expectedTabID)
            #expect(controller.network.session.mode == expectedMode)
        }
    }

    @Test
    func repeatedConnectSuspendReconnectDisconnectKeepsLifecycleConsistent() {
        let (controller, store) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        for _ in 0..<3 {
            controller.connect(to: webView)
            #expect(controller.dom.session.hasPageWebView == true)
            let expectedModeOnConnect: NetworkLoggingMode = store.selectedTab?.id == "wi_network" ? .active : .buffering
            #expect(controller.network.session.mode == expectedModeOnConnect)

            selectTab("wi_network", in: store)
            #expect(store.selectedTab?.id == "wi_network")
            #expect(controller.network.session.mode == .active)

            controller.connect(to: nil)
            #expect(controller.dom.session.hasPageWebView == false)
            #expect(controller.network.session.mode == .stopped)

            controller.connect(to: webView)
            #expect(controller.dom.session.hasPageWebView == true)
            #expect(controller.network.session.mode == .active)
        }

        controller.disconnect()
        #expect(controller.network.session.mode == .stopped)
        #expect(controller.network.session.lastPageWebView == nil)
    }

    @Test
    func suspendAndReconnectSynchronizeStoreStateWithoutDroppingSelection() async {
        let (controller, store) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        selectTab("wi_network", in: store)
        await waitForControllerState(
            controller,
            store: store,
            lifecycle: .active,
            selectedTabID: "wi_network",
            hasAttachedPage: true,
            networkMode: .active
        )

        controller.connect(to: nil)
        await waitForControllerState(
            controller,
            store: store,
            lifecycle: .suspended,
            selectedTabID: "wi_network",
            hasAttachedPage: false,
            networkMode: .stopped
        )

        controller.connect(to: webView)
        await waitForControllerState(
            controller,
            store: store,
            lifecycle: .active,
            selectedTabID: "wi_network",
            hasAttachedPage: true,
            networkMode: .active
        )
    }

    private func makeBoundSession(
        tabs: [WITab],
        selectedTabID: String? = nil
    ) -> (WIModel, WIModel) {
        let controller = WIModel()
        controller.setTabs(tabs)
        if let selectedTabID {
            selectTab(selectedTabID, in: controller)
        }
        return (controller, controller)
    }

    private func makeTestWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func domSecondaryTab(title: String = "Element") -> WITab {
        WITab(
            id: "wi_element",
            title: title,
            systemImage: "info.circle",
            role: .inspector
        )
    }

    private func selectTab(_ identifier: String, in store: WIModel) {
        let tab = store.tabs.first(where: { $0.identifier == identifier })
        store.setSelectedTabFromUI(tab)
    }

    private func waitForControllerState(
        _ controller: WIModel,
        store: WIModel,
        lifecycle: WISessionLifecycle,
        selectedTabID: String?,
        hasAttachedPage: Bool,
        networkMode: NetworkLoggingMode
    ) async {
        for _ in 0..<80 {
            if controller.lifecycle == lifecycle,
               store.selectedTab?.id == selectedTabID,
               controller.dom.session.hasPageWebView == hasAttachedPage,
               controller.network.session.hasAttachedPageWebView == hasAttachedPage,
               controller.network.session.mode == networkMode {
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        Issue.record("Timed out waiting for synchronized controller state")
    }
}
