import Testing
import WebKit
@testable import WebInspectorKit
@testable import WebInspectorKitCore

@MainActor
struct ControllerActivationTests {
    @Test
    func connectWithNoNetworkTabsDoesNotAttachNetworkSession() {
        let controller = WISessionController()
        controller.configureTabs([.dom(), .element()])
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
        controller.configureTabs([.dom(), .element()])
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
        controller.configureTabs([.dom(), .element()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        #expect(controller.network.session.lastPageWebView == nil)

        controller.configureTabs([.dom(), .network()])
        #expect(controller.network.session.lastPageWebView === webView)
    }

    @Test
    func configureTabsWhileConnectedWithSameRequirementsKeepsDOMSelection() {
        let controller = WISessionController()
        controller.configureTabs([.dom(), .element()])
        let webView = makeTestWebView()

        controller.connect(to: webView)
        controller.dom.selection.nodeId = 42
        controller.dom.selection.preview = "<div id='selected'>"

        controller.configureTabs([.dom(title: "DOM"), .element(title: "Elements")])

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

    private func makeTestWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(frame: .zero, configuration: configuration)
    }
}
