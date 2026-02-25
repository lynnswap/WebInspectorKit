import Testing
import WebKit
@testable import WebInspectorKit
@testable import WebInspectorKitCore

@MainActor
struct ControllerActivationTests {
    @Test
    func connectWithNoNetworkTabsDoesNotAttachNetworkSession() {
        let controller = WISessionController()
        controller.configureTabs([.dom(), domSecondaryTab()])
        let webView = makeTestWebView()

        controller.connect(to: webView)

        #expect(controller.dom.session.lastPageWebView === webView)
        #expect(controller.network.session.lastPageWebView == nil)
        #expect(controller.network.session.mode == .stopped)
    }

    @Test
    func connectWithoutPanelDefaultsNetworkSessionToActiveLogging() {
        let controller = WISessionController()
        let webView = makeTestWebView()

        controller.connect(to: webView)

        #expect(controller.network.session.lastPageWebView === webView)
        #expect(controller.network.session.mode == .active)
    }

    @Test
    func selectedTabSwitchesNetworkModeBetweenBufferingAndActive() {
        let controller = WISessionController()
        controller.configureTabs([.dom(), .network()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(controller.network.session.mode == .buffering)

        controller.selectedTabID = "wi_network"
        #expect(controller.network.session.mode == .active)

        controller.selectedTabID = "wi_dom"
        #expect(controller.network.session.mode == .buffering)
    }

    @Test
    func selectedTabSwitchesDOMAutoSnapshot() {
        let controller = WISessionController()
        controller.configureTabs([.dom(), domSecondaryTab()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(controller.dom.session.isAutoSnapshotEnabled == true)

        controller.selectedTabID = "wi_element"
        #expect(controller.dom.session.isAutoSnapshotEnabled == false)

        controller.selectedTabID = "wi_dom"
        #expect(controller.dom.session.isAutoSnapshotEnabled == true)
    }

    @Test
    func connectNilSuspendsWithoutClearingLastPageWebView() {
        let controller = WISessionController()
        controller.configureTabs([.dom(), .network()])
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
        let controller = WISessionController()
        controller.configureTabs([.dom(), .network()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(controller.network.session.mode == .buffering)

        controller.selectedTabID = "wi_network"
        #expect(controller.network.session.mode == .active)

        controller.connect(to: nil)
        #expect(controller.network.session.mode == .stopped)

        controller.connect(to: webView)
        #expect(controller.network.session.mode == .active)
    }

    @Test
    func configureTabsWhileConnectedReconnectsNewlyRequiredSessions() {
        let controller = WISessionController()
        controller.configureTabs([.dom(), domSecondaryTab()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(controller.network.session.lastPageWebView == nil)

        controller.configureTabs([.dom(), .network()])
        #expect(controller.network.session.lastPageWebView === webView)
    }

    @Test
    func configureTabsWhileConnectedWithSameRequirementsKeepsDOMSelection() {
        let controller = WISessionController()
        controller.configureTabs([.dom(), domSecondaryTab()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        controller.dom.selection.nodeId = 42
        controller.dom.selection.preview = "<div id='selected'>"

        controller.configureTabs([.dom(title: "DOM"), domSecondaryTab(title: "Elements")])

        #expect(controller.dom.selection.nodeId == 42)
        #expect(controller.dom.selection.preview == "<div id='selected'>")
    }

    @Test
    func disconnectKeepsNetworkStoppedForControllerOnlyUsage() {
        let controller = WISessionController()
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(controller.network.session.mode == .active)

        controller.disconnect()

        #expect(controller.selectedTabID == nil)
        #expect(controller.network.session.mode == .stopped)
        #expect(controller.network.session.lastPageWebView == nil)
    }

    @Test
    func nativeSelectionSyncAfterDisconnectKeepsSessionsStopped() {
        let controller = WISessionController()
        controller.configureTabs([.dom(), .network()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(controller.network.session.mode == .buffering)

        controller.disconnect()
        controller.synchronizeSelectedTabFromNativeUI("wi_network")

        #expect(controller.selectedTabID == nil)
        #expect(controller.network.session.mode == .stopped)
        #expect(controller.network.session.lastPageWebView == nil)
    }

    @Test
    func nativeSelectionSyncWhileConnectedUpdatesSelectedTab() {
        let controller = WISessionController()
        controller.configureTabs([.dom(), .network()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(controller.selectedTabID == "wi_dom")

        controller.synchronizeSelectedTabFromNativeUI("wi_network")

        #expect(controller.selectedTabID == "wi_network")
        #expect(controller.network.session.mode == .active)
    }

    @Test
    func repeatedTabSwitchingKeepsSelectedTabAndNetworkModeConsistent() {
        let controller = WISessionController()
        controller.configureTabs([.dom(), .network()])
        let webView = makeTestWebView()

        controller.connect(to: webView)

        for iteration in 0..<20 {
            let expectedTabID = iteration.isMultiple(of: 2) ? "wi_network" : "wi_dom"
            let expectedMode: NetworkLoggingMode = expectedTabID == "wi_network" ? .active : .buffering

            controller.selectedTabID = expectedTabID

            #expect(controller.selectedTabID == expectedTabID)
            #expect(controller.network.session.mode == expectedMode)
        }
    }

    @Test
    func repeatedConnectSuspendReconnectDisconnectKeepsLifecycleConsistent() {
        let controller = WISessionController()
        controller.configureTabs([.dom(), .network()])
        let webView = makeTestWebView()

        for _ in 0..<3 {
            controller.connect(to: webView)
            #expect(controller.dom.session.hasPageWebView == true)
            let expectedModeOnConnect: NetworkLoggingMode = controller.selectedTabID == "wi_network" ? .active : .buffering
            #expect(controller.network.session.mode == expectedModeOnConnect)

            controller.synchronizeSelectedTabFromNativeUI("wi_network")
            #expect(controller.selectedTabID == "wi_network")
            #expect(controller.network.session.mode == .active)

            controller.connect(to: nil)
            #expect(controller.dom.session.hasPageWebView == false)
            #expect(controller.network.session.mode == .stopped)

            controller.connect(to: webView)
            #expect(controller.dom.session.hasPageWebView == true)
            #expect(controller.network.session.mode == .active)
        }

        controller.disconnect()
        #expect(controller.selectedTabID == nil)
        #expect(controller.network.session.mode == .stopped)
        #expect(controller.network.session.lastPageWebView == nil)
    }

    @Test
    func suspendAndReconnectSynchronizeStoreStateWithoutDroppingSelection() async {
        let controller = WISessionController()
        controller.configureTabs([.dom(), .network()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        controller.selectedTabID = "wi_network"
        await waitForStoreState(
            controller.store,
            lifecycle: .active,
            selectedTabID: "wi_network",
            hasAttachedPage: true,
            networkMode: .active
        )

        controller.connect(to: nil)
        await waitForStoreState(
            controller.store,
            lifecycle: .suspended,
            selectedTabID: "wi_network",
            hasAttachedPage: false,
            networkMode: .stopped
        )

        controller.connect(to: webView)
        await waitForStoreState(
            controller.store,
            lifecycle: .active,
            selectedTabID: "wi_network",
            hasAttachedPage: true,
            networkMode: .active
        )
    }

    private func makeTestWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func domSecondaryTab(title: String = "Element") -> WITabDescriptor {
        WITabDescriptor(
            id: "wi_element",
            title: title,
            systemImage: "info.circle",
            role: .inspector,
            requires: [.dom]
        ) { context in
            #if canImport(UIKit)
            let root = DOMTreeTabViewController(inspector: context.domInspector)
            let navigationController = UINavigationController(rootViewController: root)
            wiApplyClearNavigationBarStyle(to: navigationController)
            return navigationController
            #elseif canImport(AppKit)
            return ElementDetailsTabViewController(inspector: context.domInspector)
            #endif
        }
    }

    private func waitForStoreState(
        _ store: WISessionStore,
        lifecycle: WISessionLifecycle,
        selectedTabID: String?,
        hasAttachedPage: Bool,
        networkMode: NetworkLoggingMode
    ) async {
        for _ in 0..<80 {
            let state = store.viewState
            if state.lifecycle == lifecycle,
               state.selectedTabID == selectedTabID,
               state.dom.hasAttachedPage == hasAttachedPage,
               state.network.hasAttachedPage == hasAttachedPage,
               state.network.mode == networkMode {
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        Issue.record("Timed out waiting for synchronized store state")
    }
}
