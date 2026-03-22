import Testing
import WebKit
@testable import WebInspectorUI
@testable import WebInspectorEngine
@testable import WebInspectorRuntime

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

@MainActor
struct ControllerActivationTests {
    @Test
    func connectWithNoNetworkTabsDoesNotAttachNetworkSession() async {
        let (controller, _) = makeBoundSession(tabs: [.dom(), domSecondaryTab()])
        let webView = makeTestWebView()

        await controller.connect(to: webView)

        #expect(controller.dom.session.lastPageWebView === webView)
        #expect(controller.network.session.lastPageWebView == nil)
        #expect(controller.network.session.mode == .stopped)
    }

    @Test
    func customTabWithoutBuiltInIdentifiersDoesNotAttachNetworkSession() async {
        let customTab = WITab(
            id: "custom_network",
            title: "Custom Network",
            systemImage: "network"
        )
        let (controller, _) = makeBoundSession(tabs: [customTab])
        let webView = makeTestWebView()

        await controller.connect(to: webView)

        #expect(controller.network.session.lastPageWebView == nil)
        #expect(controller.network.session.mode == .stopped)
    }

    @Test
    func customTabWithoutBuiltInIdentifiersDoesNotAttachDOMSession() async {
        let customTab = WITab(
            id: "custom_dom",
            title: "Custom DOM",
            systemImage: "doc"
        )
        let (controller, _) = makeBoundSession(tabs: [customTab])
        let webView = makeTestWebView()

        await controller.connect(to: webView)

        #expect(controller.dom.session.lastPageWebView == nil)
        #expect(controller.network.session.lastPageWebView == nil)
        #expect(controller.network.session.mode == .stopped)
    }

    @Test
    func connectWithoutPanelDefaultsNetworkSessionToActiveLogging() async {
        let controller = WIInspectorController()
        let webView = makeTestWebView()

        await controller.connect(to: webView)

        #expect(controller.network.session.lastPageWebView === webView)
        #expect(controller.network.session.mode == .active)
    }

    @Test
    func connectWithExplicitEmptyTabsDoesNotAttachInspectorSessions() async {
        let (controller, _) = makeBoundSession(tabs: [])
        let webView = makeTestWebView()

        await controller.connect(to: webView)

        #expect(controller.dom.session.hasPageWebView == false)
        #expect(controller.dom.session.lastPageWebView == nil)
        #expect(controller.network.session.hasAttachedPageWebView == false)
        #expect(controller.network.session.lastPageWebView == nil)
        #expect(controller.network.session.mode == .stopped)
    }

    @Test
    func selectedTabSwitchesNetworkModeBetweenBufferingAndActive() async {
        let (controller, store) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        await controller.connect(to: webView)
        #expect(controller.network.session.mode == .buffering)

        await selectTab("wi_network", in: controller, store: store)
        #expect(controller.network.session.mode == .active)

        await selectTab("wi_dom", in: controller, store: store)
        #expect(controller.network.session.mode == .buffering)
    }

    @Test
    func selectedTabSwitchesDOMAutoSnapshot() async {
        let (controller, store) = makeBoundSession(tabs: [.dom(), domSecondaryTab()])
        let webView = makeTestWebView()

        await controller.connect(to: webView)
        #expect(controller.dom.session.isAutoSnapshotEnabled == true)

        await selectTab("wi_element", in: controller, store: store)
        #expect(controller.dom.session.isAutoSnapshotEnabled == true)

        await selectTab("wi_dom", in: controller, store: store)
        #expect(controller.dom.session.isAutoSnapshotEnabled == true)
    }

    @Test
    func connectNilSuspendsWithoutClearingLastPageWebView() async {
        let (controller, _) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        await controller.connect(to: webView)
        #expect(controller.dom.session.hasPageWebView == true)
        #expect(controller.dom.session.lastPageWebView === webView)
        #expect(controller.network.session.lastPageWebView === webView)

        await controller.connect(to: nil)
        #expect(controller.dom.session.hasPageWebView == false)
        #expect(controller.dom.session.lastPageWebView === webView)
        #expect(controller.network.session.lastPageWebView === webView)
        #expect(controller.network.session.mode == .stopped)
    }

    @Test
    func reconnectAfterSuspendRestoresModeForSelectedTab() async {
        let (controller, store) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        await controller.connect(to: webView)
        #expect(controller.network.session.mode == .buffering)

        await selectTab("wi_network", in: controller, store: store)
        #expect(controller.network.session.mode == .active)

        await controller.connect(to: nil)
        #expect(controller.network.session.mode == .stopped)

        await controller.connect(to: webView)
        #expect(controller.network.session.mode == .active)
    }

    @Test
    func setTabsWhileSuspendedDoesNotReattachSessionsUntilActivated() async {
        let (controller, store) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        await controller.connect(to: webView)
        #expect(controller.dom.session.hasPageWebView == true)
        #expect(controller.network.session.hasAttachedPageWebView == true)

        await controller.suspend()
        #expect(controller.lifecycle == .suspended)
        #expect(controller.dom.session.hasPageWebView == false)
        #expect(controller.network.session.hasAttachedPageWebView == false)

        store.setTabs([.dom(), .network()])
        await controller.reapplyCurrentHostState()
        #expect(controller.lifecycle == .suspended)
        #expect(controller.dom.session.hasPageWebView == false)
        #expect(controller.network.session.hasAttachedPageWebView == false)

        await controller.activateFromUIIfPossible()
        #expect(controller.lifecycle == .active)
        #expect(controller.dom.session.hasPageWebView == true)
        #expect(controller.network.session.hasAttachedPageWebView == true)
    }

    @Test
    func setTabsWhileConnectedReconnectsNewlyRequiredSessions() async {
        let (controller, store) = makeBoundSession(tabs: [.dom(), domSecondaryTab()])
        let webView = makeTestWebView()

        await controller.connect(to: webView)
        #expect(controller.network.session.lastPageWebView == nil)

        store.setTabs([.dom(), .network()])
        await controller.reapplyCurrentHostState()
        #expect(controller.network.session.lastPageWebView === webView)
    }

    @Test
    func setTabsWhileConnectedWithSameRequirementsKeepsDOMSelection() async {
        let (controller, store) = makeBoundSession(tabs: [.dom(), domSecondaryTab()])
        let webView = makeTestWebView()

        await controller.connect(to: webView)
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
        await controller.reapplyCurrentHostState()

        #expect(controller.dom.selectedEntry?.id.localID == 42)
        #expect(controller.dom.selectedEntry?.preview == "<div id='selected'>")
    }

    @Test
    func disconnectKeepsNetworkStoppedForControllerOnlyUsage() async {
        let controller = WIInspectorController()
        let webView = makeTestWebView()

        await controller.connect(to: webView)
        #expect(controller.network.session.mode == .active)

        await controller.disconnect()

        #expect(controller.network.session.mode == .stopped)
        #expect(controller.network.session.lastPageWebView == nil)
    }

    @Test
    func programmaticSelectionAfterDisconnectKeepsSessionsStopped() async {
        let (controller, store) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        await controller.connect(to: webView)
        #expect(controller.network.session.mode == .buffering)

        await controller.disconnect()
        await selectTab("wi_network", in: controller, store: store)

        #expect(store.selectedTab?.id == "wi_network")
        #expect(controller.network.session.mode == .stopped)
        #expect(controller.network.session.lastPageWebView == nil)
    }

    @Test
    func programmaticSelectionWhileConnectedUpdatesStoreAndMode() async {
        let (controller, store) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        await controller.connect(to: webView)
        #expect(store.selectedTab?.id == "wi_dom")

        await selectTab("wi_network", in: controller, store: store)

        #expect(store.selectedTab?.id == "wi_network")
        #expect(controller.network.session.mode == .active)
    }

    @Test
    func repeatedTabSwitchingKeepsStoreAndNetworkModeConsistent() async {
        let (controller, store) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        await controller.connect(to: webView)

        for iteration in 0..<20 {
            let expectedTabID = iteration.isMultiple(of: 2) ? "wi_network" : "wi_dom"
            let expectedMode: NetworkLoggingMode = expectedTabID == "wi_network" ? .active : .buffering

            await selectTab(expectedTabID, in: controller, store: store)

            #expect(store.selectedTab?.id == expectedTabID)
            #expect(controller.network.session.mode == expectedMode)
        }
    }

    @Test
    func repeatedConnectSuspendReconnectDisconnectKeepsLifecycleConsistent() async {
        let (controller, store) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        for _ in 0..<3 {
            await controller.connect(to: webView)
            #expect(controller.dom.session.hasPageWebView == true)
            let expectedModeOnConnect: NetworkLoggingMode = store.selectedTab?.id == "wi_network" ? .active : .buffering
            #expect(controller.network.session.mode == expectedModeOnConnect)

            await selectTab("wi_network", in: controller, store: store)
            #expect(store.selectedTab?.id == "wi_network")
            #expect(controller.network.session.mode == .active)

            await controller.connect(to: nil)
            #expect(controller.dom.session.hasPageWebView == false)
            #expect(controller.network.session.mode == .stopped)

            await controller.connect(to: webView)
            #expect(controller.dom.session.hasPageWebView == true)
            #expect(controller.network.session.mode == .active)
        }

        await controller.disconnect()
        #expect(controller.network.session.mode == .stopped)
        #expect(controller.network.session.lastPageWebView == nil)
    }

    @Test
    func suspendAndReconnectSynchronizeStoreStateWithoutDroppingSelection() async {
        let (controller, store) = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        await controller.connect(to: webView)
        await selectTab("wi_network", in: controller, store: store)
        await waitForControllerState(
            controller,
            store: store,
            lifecycle: .active,
            selectedTabID: "wi_network",
            hasAttachedPage: true,
            networkMode: .active
        )

        await controller.connect(to: nil)
        await waitForControllerState(
            controller,
            store: store,
            lifecycle: .suspended,
            selectedTabID: "wi_network",
            hasAttachedPage: false,
            networkMode: .stopped
        )

        await controller.connect(to: webView)
        await waitForControllerState(
            controller,
            store: store,
            lifecycle: .active,
            selectedTabID: "wi_network",
            hasAttachedPage: true,
            networkMode: .active
        )
    }

#if canImport(UIKit)
    @Test
    func pageWindowActivationMakesPageWindowKeyWithinSameScene() async throws {
        let controller = WIInspectorController()
        let webView = makeTestWebView()
        let pageWindow = makeUIKitWindow(containing: webView)
        defer {
            tearDownUIKitWindow(pageWindow)
        }

        await controller.connect(to: webView)
        pageWindow.makeKeyAndVisible()
        pageWindow.resetRecordedCalls()

        let attachedWindow = try #require(webView.window)
        #expect(attachedWindow === pageWindow)

        controller.dom.activatePageWindowForSelectionIfPossible()

        #expect(pageWindow.makeKeyCallCount == 1)
    }

    @Test
    func pageSceneActivationRequestsExistingSessionWhenSceneIsNotForegroundActive() async throws {
        let controller = WIInspectorController()
        let webView = makeTestWebView()
        let pageWindow = makeUIKitWindow(containing: webView)
        defer {
            tearDownUIKitWindow(pageWindow)
        }

        await controller.connect(to: webView)
        pageWindow.makeKeyAndVisible()

        let requester = RecordingSceneActivationRequester()
        let target = FakeSceneActivationTarget(activationState: .background)
        requester.error = TestSceneActivationError()
        let previousRequester = WIDOMUIKitSceneActivationEnvironment.requester
        let previousSceneProvider = WIDOMUIKitSceneActivationEnvironment.sceneProvider
        defer {
            WIDOMUIKitSceneActivationEnvironment.requester = previousRequester
            WIDOMUIKitSceneActivationEnvironment.sceneProvider = previousSceneProvider
        }
        WIDOMUIKitSceneActivationEnvironment.requester = requester
        WIDOMUIKitSceneActivationEnvironment.sceneProvider = { _ in target }

        controller.dom.activatePageWindowForSelectionIfPossible()

        let requestedTarget = try #require(requester.requestedTargets.first)
        #expect(requester.requestedTargets.count == 1)
        #expect(requestedTarget === target)
    }

    @Test
    func pageWindowActivationWithoutAttachedWindowIsNoOp() async {
        let controller = WIInspectorController()
        let webView = makeTestWebView()

        await controller.connect(to: webView)
        controller.dom.activatePageWindowForSelectionIfPossible()

        #expect(webView.window == nil)
    }
#endif

#if canImport(AppKit)
    @Test
    func pageWindowActivationMakesPageWindowKeyOnMacOS() async {
        let controller = WIInspectorController()
        let webView = makeTestWebView()
        let pageWindow = makeAppKitWindow(containing: webView)
        defer {
            tearDownAppKitWindow(pageWindow)
        }

        await controller.connect(to: webView)
        pageWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        pageWindow.resetRecordedCalls()

        controller.dom.activatePageWindowForSelectionIfPossible()

        #expect(pageWindow.makeKeyAndOrderFrontCallCount == 1)
    }
#endif

    private func makeBoundSession(
        tabs: [WITab],
        selectedTabID: String? = nil
    ) -> (WIInspectorController, WIModel) {
        let store = WIModel()
        let controller = WIInspectorController(model: store)
        store.setTabs(tabs)
        if let selectedTabID {
            let tab = store.tabs.first(where: { $0.identifier == selectedTabID })
            store.setSelectedTabFromUI(tab)
        }
        return (controller, store)
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

    private func selectTab(_ identifier: String, in controller: WIInspectorController, store: WIModel) async {
        let tab = store.tabs.first(where: { $0.identifier == identifier })
        store.setSelectedTabFromUI(tab)
        await controller.reapplyCurrentHostState()
    }

    private func waitForControllerState(
        _ controller: WIInspectorController,
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

#if canImport(UIKit)
    private func makeUIKitWindow(containing webView: WKWebView? = nil) -> RecordingUIKitWindow {
        let viewController = UIViewController()
        viewController.loadViewIfNeeded()
        if let webView {
            webView.translatesAutoresizingMaskIntoConstraints = false
            viewController.view.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: viewController.view.topAnchor),
                webView.leadingAnchor.constraint(equalTo: viewController.view.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: viewController.view.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: viewController.view.bottomAnchor)
            ])
        }

        let window = RecordingUIKitWindow(frame: UIScreen.main.bounds)
        window.frame = UIScreen.main.bounds
        window.rootViewController = viewController
        return window
    }

    private func tearDownUIKitWindow(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    @MainActor
    private final class RecordingSceneActivationRequester: WIDOMUIKitSceneActivationRequesting {
        private(set) var requestedTargets: [any WIDOMUIKitSceneActivationTarget] = []
        var error: (any Error)?

        func requestActivation(
            of target: any WIDOMUIKitSceneActivationTarget,
            errorHandler: ((any Error) -> Void)?
        ) {
            requestedTargets.append(target)
            if let error {
                errorHandler?(error)
            }
        }
    }

    private struct TestSceneActivationError: Error {}

    @MainActor
    private final class FakeSceneActivationTarget: WIDOMUIKitSceneActivationTarget {
        let activationState: UIScene.ActivationState
        let sceneSession: UISceneSession? = nil

        init(activationState: UIScene.ActivationState) {
            self.activationState = activationState
        }
    }

    private final class RecordingUIKitWindow: UIWindow {
        private(set) var makeKeyCallCount = 0

        override func makeKey() {
            makeKeyCallCount += 1
            super.makeKey()
        }

        func resetRecordedCalls() {
            makeKeyCallCount = 0
        }
    }
#endif

#if canImport(AppKit)
    private func makeAppKitWindow(containing webView: WKWebView? = nil) -> RecordingAppKitWindow {
        let viewController = NSViewController()
        viewController.view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        if let webView {
            webView.translatesAutoresizingMaskIntoConstraints = false
            viewController.view.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: viewController.view.topAnchor),
                webView.leadingAnchor.constraint(equalTo: viewController.view.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: viewController.view.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: viewController.view.bottomAnchor)
            ])
        }

        let window = RecordingAppKitWindow(contentViewController: viewController)
        window.setContentSize(NSSize(width: 800, height: 600))
        window.styleMask = [.titled, .closable, .resizable]
        return window
    }

    private func tearDownAppKitWindow(_ window: NSWindow) {
        window.orderOut(nil)
        window.close()
    }

    private final class RecordingAppKitWindow: NSWindow {
        private(set) var makeKeyAndOrderFrontCallCount = 0

        override func makeKeyAndOrderFront(_ sender: Any?) {
            makeKeyAndOrderFrontCallCount += 1
            super.makeKeyAndOrderFront(sender)
        }

        func resetRecordedCalls() {
            makeKeyAndOrderFrontCallCount = 0
        }
    }
#endif
}
