import Testing
import WebKit
import WebInspectorKit
@testable import WebInspectorUI
@testable import WebInspectorCore
@testable import WebInspectorCore
@testable import WebInspectorCore
@testable import WebInspectorCore

@MainActor
@Suite(.serialized, .webKitIsolated)
struct ControllerActivationTests {
    @Test
    func connectWithNoNetworkTabsDoesNotAttachNetworkSession() {
        let (controller, _) = makeBoundSession(tabs: [.dom(), domSecondaryTab()])
        let webView = makeTestWebView()

        controller.connect(to: webView)

        #expect(controller.domStore.session.lastPageWebView === webView)
        #expect(controller.networkStore.session.lastPageWebView == nil)
        #expect(controller.networkStore.session.mode == .stopped)
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

        #expect(controller.networkStore.session.lastPageWebView == nil)
        #expect(controller.networkStore.session.mode == .stopped)
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

        #expect(controller.domStore.session.lastPageWebView == nil)
        #expect(controller.networkStore.session.lastPageWebView == nil)
        #expect(controller.networkStore.session.mode == .stopped)
    }

    @Test
    func connectWithoutPanelDefaultsNetworkSessionToActiveLogging() {
        let controller = WISessionController()
        let webView = makeTestWebView()

        controller.connect(to: webView)

        #expect(controller.networkStore.session.lastPageWebView === webView)
        #expect(controller.networkStore.session.mode == .active)
    }

    @Test
    func selectedTabSwitchesNetworkModeBetweenBufferingAndActive() {
        let (controller, store) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(controller.networkStore.session.mode == .buffering)

        selectTab("wi_network", in: store)
        #expect(controller.networkStore.session.mode == .active)

        selectTab("wi_dom", in: store)
        #expect(controller.networkStore.session.mode == .buffering)
    }

    @Test
    func selectedTabSwitchesDOMAutoSnapshot() {
        let (controller, store) = makeBoundSession(tabs: [.dom(), domSecondaryTab()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(controller.domStore.session.isAutoSnapshotEnabled == true)

        selectTab("wi_element", in: store)
        #expect(controller.domStore.session.isAutoSnapshotEnabled == false)

        selectTab("wi_dom", in: store)
        #expect(controller.domStore.session.isAutoSnapshotEnabled == true)
    }

    @Test
    func connectNilSuspendsWithoutClearingLastPageWebView() {
        let (controller, _) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(controller.domStore.session.hasPageWebView == true)
        #expect(controller.domStore.session.lastPageWebView === webView)
        #expect(controller.networkStore.session.lastPageWebView === webView)

        controller.connect(to: nil)
        #expect(controller.domStore.session.hasPageWebView == false)
        #expect(controller.domStore.session.lastPageWebView === webView)
        #expect(controller.networkStore.session.lastPageWebView === webView)
        #expect(controller.networkStore.session.mode == .stopped)
    }

    @Test
    func reconnectAfterSuspendRestoresModeForSelectedTab() {
        let (controller, store) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(controller.networkStore.session.mode == .buffering)

        selectTab("wi_network", in: store)
        #expect(controller.networkStore.session.mode == .active)

        controller.connect(to: nil)
        #expect(controller.networkStore.session.mode == .stopped)

        controller.connect(to: webView)
        #expect(controller.networkStore.session.mode == .active)
    }

    @Test
    func setTabsWhileSuspendedDoesNotReattachSessionsUntilActivated() {
        let (controller, store) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(controller.domStore.session.hasPageWebView == true)
        #expect(controller.networkStore.session.hasAttachedPageWebView == true)

        controller.suspend()
        #expect(controller.lifecycle == .suspended)
        #expect(controller.domStore.session.hasPageWebView == false)
        #expect(controller.networkStore.session.hasAttachedPageWebView == false)

        store.configurePanels([WITab.dom().configuration, WITab.network().configuration])
        #expect(controller.lifecycle == .suspended)
        #expect(controller.domStore.session.hasPageWebView == false)
        #expect(controller.networkStore.session.hasAttachedPageWebView == false)

        controller.activateFromUIIfPossible()
        #expect(controller.lifecycle == .active)
        #expect(controller.domStore.session.hasPageWebView == true)
        #expect(controller.networkStore.session.hasAttachedPageWebView == true)
    }

    @Test
    func setTabsWhileConnectedReconnectsNewlyRequiredSessions() {
        let (controller, store) = makeBoundSession(tabs: [.dom(), domSecondaryTab()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(controller.networkStore.session.lastPageWebView == nil)

        store.configurePanels([WITab.dom().configuration, WITab.network().configuration])
        #expect(controller.networkStore.session.lastPageWebView === webView)
    }

    @Test
    func setTabsWhileConnectedWithSameRequirementsKeepsDOMSelection() {
        let (controller, store) = makeBoundSession(tabs: [.dom(), domSecondaryTab()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        controller.domStore.session.graphStore.applySnapshot(
            .init(
                root: DOMGraphNodeDescriptor(
                    nodeID: 42,
                    nodeType: 1,
                    nodeName: "DIV",
                    localName: "div",
                    nodeValue: "",
                    attributes: [],
                    childCount: 0,
                    layoutFlags: [],
                    isRendered: true,
                    children: []
                )
            )
        )
        controller.domStore.session.graphStore.applySelectionSnapshot(
            .init(
                nodeID: 42,
                preview: "<div id='selected'>",
                attributes: [],
                path: [],
                selectorPath: "#selected",
                styleRevision: 0
            )
        )

        store.configurePanels([WITab.dom(title: "DOM").configuration, domSecondaryTab(title: "Elements").configuration])

        #expect(controller.domStore.selectedEntry?.id.nodeID == 42)
        #expect(controller.domStore.selectedEntry?.preview == "<div id='selected'>")
    }

    @Test
    func disconnectKeepsNetworkStoppedForControllerOnlyUsage() {
        let controller = WISessionController()
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(controller.networkStore.session.mode == .active)

        controller.disconnect()

        #expect(controller.networkStore.session.mode == .stopped)
        #expect(controller.networkStore.session.lastPageWebView == nil)
    }

    @Test
    func programmaticSelectionAfterDisconnectKeepsSessionsStopped() {
        let (controller, store) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(controller.networkStore.session.mode == .buffering)

        controller.disconnect()
        selectTab("wi_network", in: store)

        #expect(store.selectedPanelConfiguration?.identifier == "wi_network")
        #expect(controller.networkStore.session.mode == .stopped)
        #expect(controller.networkStore.session.lastPageWebView == nil)
    }

    @Test
    func programmaticSelectionWhileConnectedUpdatesStoreAndMode() {
        let (controller, store) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(store.selectedPanelConfiguration?.identifier == "wi_dom")

        selectTab("wi_network", in: store)

        #expect(store.selectedPanelConfiguration?.identifier == "wi_network")
        #expect(controller.networkStore.session.mode == .active)
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

            #expect(store.selectedPanelConfiguration?.identifier == expectedTabID)
            #expect(controller.networkStore.session.mode == expectedMode)
        }
    }

    @Test
    func repeatedConnectSuspendReconnectDisconnectKeepsLifecycleConsistent() {
        let (controller, store) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        for _ in 0..<3 {
            controller.connect(to: webView)
            #expect(controller.domStore.session.hasPageWebView == true)
            let expectedModeOnConnect: NetworkLoggingMode = store.selectedPanelConfiguration?.identifier == "wi_network" ? .active : .buffering
            #expect(controller.networkStore.session.mode == expectedModeOnConnect)

            selectTab("wi_network", in: store)
            #expect(store.selectedPanelConfiguration?.identifier == "wi_network")
            #expect(controller.networkStore.session.mode == .active)

            controller.connect(to: nil)
            #expect(controller.domStore.session.hasPageWebView == false)
            #expect(controller.networkStore.session.mode == .stopped)

            controller.connect(to: webView)
            #expect(controller.domStore.session.hasPageWebView == true)
            #expect(controller.networkStore.session.mode == .active)
        }

        controller.disconnect()
        #expect(controller.networkStore.session.mode == .stopped)
        #expect(controller.networkStore.session.lastPageWebView == nil)
    }

    @Test
    func suspendAndReconnectSynchronizeStoreStateWithoutDroppingSelection() async {
        let (controller, store) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        selectTab("wi_network", in: store)
        #expect(controller.lifecycle == .active)
        #expect(store.selectedPanelConfiguration?.identifier == "wi_network")
        #expect(controller.domStore.session.hasPageWebView == true)
        #expect(controller.networkStore.session.hasAttachedPageWebView == true)
        #expect(controller.networkStore.session.mode == .active)

        controller.connect(to: nil)
        #expect(controller.lifecycle == .suspended)
        #expect(store.selectedPanelConfiguration?.identifier == "wi_network")
        #expect(controller.domStore.session.hasPageWebView == false)
        #expect(controller.networkStore.session.hasAttachedPageWebView == false)
        #expect(controller.networkStore.session.mode == .stopped)

        controller.connect(to: webView)
        #expect(controller.lifecycle == .active)
        #expect(store.selectedPanelConfiguration?.identifier == "wi_network")
        #expect(controller.domStore.session.hasPageWebView == true)
        #expect(controller.networkStore.session.hasAttachedPageWebView == true)
        #expect(controller.networkStore.session.mode == .active)
    }

    private func makeBoundSession(
        tabs: [WITab],
        selectedTabID: String? = nil
    ) -> (WISessionController, WISessionController) {
        let controller = WISessionController()
        controller.configurePanels(tabs.map(\.configuration))
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
            role: .builtIn
        )
    }

    private func selectTab(_ identifier: String, in store: WISessionController) {
        let panel = store.panelConfigurations.first(where: { $0.identifier == identifier })
            ?? WIPanelConfiguration(kind: .custom(identifier))
        store.setSelectedPanelFromUI(panel)
    }

}
