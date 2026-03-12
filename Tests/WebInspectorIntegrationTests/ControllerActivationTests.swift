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

        #expect(controller.dom.session.lastPageWebView === webView)
        #expect(controller.network.session.lastPageWebView == nil)
        #expect(controller.network.session.mode == .stopped)
    }

    @Test
    func customTabWithoutBuiltInIdentifiersDoesNotAttachNetworkSession() {
        let customTab = WIInspectorTab(
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
        let customTab = WIInspectorTab(
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
        let controller = WIInspectorController()
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

        store.configurePanels([WIInspectorTab.dom().configuration, WIInspectorTab.network().configuration])
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

        store.configurePanels([WIInspectorTab.dom().configuration, WIInspectorTab.network().configuration])
        #expect(controller.network.session.lastPageWebView === webView)
    }

    @Test
    func setTabsWhileConnectedWithSameRequirementsKeepsDOMSelection() {
        let (controller, store) = makeBoundSession(tabs: [.dom(), domSecondaryTab()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        controller.dom.session.graphStore.applySnapshot(
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
        controller.dom.session.graphStore.applySelectionSnapshot(
            .init(
                nodeID: 42,
                preview: "<div id='selected'>",
                attributes: [],
                path: [],
                selectorPath: "#selected",
                styleRevision: 0
            )
        )

        store.configurePanels([WIInspectorTab.dom(title: "DOM").configuration, domSecondaryTab(title: "Elements").configuration])

        #expect(controller.dom.selectedEntry?.id.nodeID == 42)
        #expect(controller.dom.selectedEntry?.preview == "<div id='selected'>")
    }

    @Test
    func disconnectKeepsNetworkStoppedForControllerOnlyUsage() {
        let controller = WIInspectorController()
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

        #expect(store.selectedPanelConfiguration?.identifier == "wi_network")
        #expect(controller.network.session.mode == .stopped)
        #expect(controller.network.session.lastPageWebView == nil)
    }

    @Test
    func programmaticSelectionWhileConnectedUpdatesStoreAndMode() {
        let (controller, store) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(store.selectedPanelConfiguration?.identifier == "wi_dom")

        selectTab("wi_network", in: store)

        #expect(store.selectedPanelConfiguration?.identifier == "wi_network")
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

            #expect(store.selectedPanelConfiguration?.identifier == expectedTabID)
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
            let expectedModeOnConnect: NetworkLoggingMode = store.selectedPanelConfiguration?.identifier == "wi_network" ? .active : .buffering
            #expect(controller.network.session.mode == expectedModeOnConnect)

            selectTab("wi_network", in: store)
            #expect(store.selectedPanelConfiguration?.identifier == "wi_network")
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
        #expect(controller.lifecycle == .active)
        #expect(store.selectedPanelConfiguration?.identifier == "wi_network")
        #expect(controller.dom.session.hasPageWebView == true)
        #expect(controller.network.session.hasAttachedPageWebView == true)
        #expect(controller.network.session.mode == .active)

        controller.connect(to: nil)
        #expect(controller.lifecycle == .suspended)
        #expect(store.selectedPanelConfiguration?.identifier == "wi_network")
        #expect(controller.dom.session.hasPageWebView == false)
        #expect(controller.network.session.hasAttachedPageWebView == false)
        #expect(controller.network.session.mode == .stopped)

        controller.connect(to: webView)
        #expect(controller.lifecycle == .active)
        #expect(store.selectedPanelConfiguration?.identifier == "wi_network")
        #expect(controller.dom.session.hasPageWebView == true)
        #expect(controller.network.session.hasAttachedPageWebView == true)
        #expect(controller.network.session.mode == .active)
    }

    private func makeBoundSession(
        tabs: [WIInspectorTab],
        selectedTabID: String? = nil
    ) -> (WIInspectorController, WIInspectorController) {
        let controller = WIInspectorController()
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

    private func domSecondaryTab(title: String = "Element") -> WIInspectorTab {
        WIInspectorTab(
            id: "wi_element",
            title: title,
            systemImage: "info.circle",
            role: .inspector
        )
    }

    private func selectTab(_ identifier: String, in store: WIInspectorController) {
        let panel = store.panelConfigurations.first(where: { $0.identifier == identifier })
            ?? WIInspectorPanelConfiguration(kind: .custom(identifier))
        store.setSelectedPanelFromUI(panel)
    }

}
