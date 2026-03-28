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
        let controller = makeBoundSession(tabs: [.dom(), domSecondaryTab()])
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
        let controller = makeBoundSession(tabs: [customTab])
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
        let controller = makeBoundSession(tabs: [customTab])
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
        let controller = makeBoundSession(tabs: [])
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
        let controller = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        await controller.connect(to: webView)
        #expect(controller.network.session.mode == .buffering)

        await selectTab("wi_network", in: controller)
        #expect(controller.network.session.mode == .active)

        await selectTab("wi_dom", in: controller)
        #expect(controller.network.session.mode == .buffering)
    }

    @Test
    func selectedTabSwitchesDOMAutoSnapshot() async {
        let controller = makeBoundSession(tabs: [.dom(), domSecondaryTab()])
        let webView = makeTestWebView()

        await controller.connect(to: webView)
        #expect(controller.dom.session.isAutoSnapshotEnabled == true)

        await selectTab("wi_element", in: controller)
        #expect(controller.dom.session.isAutoSnapshotEnabled == true)

        await selectTab("wi_dom", in: controller)
        #expect(controller.dom.session.isAutoSnapshotEnabled == true)
    }

    @Test
    func connectNilSuspendsWithoutClearingLastPageWebView() async {
        let controller = makeBoundSession(tabs: [.dom(), .network()])
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
        let controller = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        await controller.connect(to: webView)
        #expect(controller.network.session.mode == .buffering)

        await selectTab("wi_network", in: controller)
        #expect(controller.network.session.mode == .active)

        await controller.connect(to: nil)
        #expect(controller.network.session.mode == .stopped)

        await controller.connect(to: webView)
        #expect(controller.network.session.mode == .active)
    }

    @Test
    func setTabsWhileSuspendedDoesNotReattachSessionsUntilActivated() async {
        let controller = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        await controller.connect(to: webView)
        #expect(controller.dom.session.hasPageWebView == true)
        #expect(controller.network.session.hasAttachedPageWebView == true)

        await controller.suspend()
        #expect(controller.lifecycle == .suspended)
        #expect(controller.dom.session.hasPageWebView == false)
        #expect(controller.network.session.hasAttachedPageWebView == false)

        controller.setTabs([.dom(), .network()])
        await waitForControllerState(
            controller,
            lifecycle: .suspended,
            selectedTabID: WITab.domTabID,
            hasAttachedPage: false,
            networkMode: .stopped
        )

        await controller.connect(to: webView)
        await waitForControllerState(
            controller,
            lifecycle: .active,
            selectedTabID: WITab.domTabID,
            hasAttachedPage: true,
            networkMode: .buffering
        )
    }

    @Test
    func setTabsWhileConnectedReconnectsNewlyRequiredSessions() async {
        let controller = makeBoundSession(tabs: [.dom(), domSecondaryTab()])
        let webView = makeTestWebView()

        await controller.connect(to: webView)
        #expect(controller.network.session.lastPageWebView == nil)

        controller.setTabs([.dom(), .network()])
        await waitForControllerState(
            controller,
            lifecycle: .active,
            selectedTabID: WITab.domTabID,
            hasAttachedPage: true,
            networkMode: .buffering
        )
        #expect(controller.network.session.lastPageWebView === webView)
    }

    @Test
    func setTabsWhileConnectedWithSameRequirementsKeepsDOMSelection() async {
        let controller = makeBoundSession(tabs: [.dom(), domSecondaryTab()])
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

        controller.setTabs([.dom(title: "DOM"), domSecondaryTab(title: "Elements")])
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
        let controller = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        await controller.connect(to: webView)
        #expect(controller.network.session.mode == .buffering)

        await controller.disconnect()
        await selectTab("wi_network", in: controller)

        #expect(controller.selectedTab?.id == "wi_network")
        #expect(controller.network.session.mode == .stopped)
        #expect(controller.network.session.lastPageWebView == nil)
    }

    @Test
    func publicSelectionMutationWhileConnectedReappliesRuntimeState() async {
        let controller = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        await controller.connect(to: webView)
        #expect(controller.selectedTab?.id == "wi_dom")
        #expect(controller.network.session.mode == .buffering)

        guard let networkTab = controller.tabs.first(where: { $0.identifier == WITab.networkTabID }) else {
            Issue.record("Expected network tab")
            return
        }
        controller.setSelectedTab(networkTab)

        await waitForControllerState(
            controller,
            lifecycle: .active,
            selectedTabID: WITab.networkTabID,
            hasAttachedPage: true,
            networkMode: .active
        )
    }

    @Test
    func explicitEmptyTabsMutationWhileConnectedSuspendsRuntime() async {
        let controller = WIInspectorController()
        let webView = makeTestWebView()

        await controller.connect(to: webView)
        #expect(controller.lifecycle == .active)
        #expect(controller.network.session.mode == .active)

        controller.setTabs([])

        await waitForControllerState(
            controller,
            lifecycle: .active,
            selectedTabID: nil,
            hasAttachedPage: false,
            networkMode: .stopped
        )
    }

    @Test
    func programmaticSelectionWhileConnectedUpdatesStoreAndMode() async {
        let controller = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        await controller.connect(to: webView)
        #expect(controller.selectedTab?.id == "wi_dom")

        await selectTab("wi_network", in: controller)

        #expect(controller.selectedTab?.id == "wi_network")
        #expect(controller.network.session.mode == .active)
    }

    @Test
    func repeatedTabSwitchingKeepsStoreAndNetworkModeConsistent() async {
        let controller = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        await controller.connect(to: webView)

        for iteration in 0..<20 {
            let expectedTabID = iteration.isMultiple(of: 2) ? "wi_network" : "wi_dom"
            let expectedMode: NetworkLoggingMode = expectedTabID == "wi_network" ? .active : .buffering

            await selectTab(expectedTabID, in: controller)

            #expect(controller.selectedTab?.id == expectedTabID)
            #expect(controller.network.session.mode == expectedMode)
        }
    }

    @Test
    func repeatedConnectSuspendReconnectDisconnectKeepsLifecycleConsistent() async {
        let controller = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        for _ in 0..<3 {
            await controller.connect(to: webView)
            #expect(controller.dom.session.hasPageWebView == true)
            let expectedModeOnConnect: NetworkLoggingMode = controller.selectedTab?.id == "wi_network" ? .active : .buffering
            #expect(controller.network.session.mode == expectedModeOnConnect)

            await selectTab("wi_network", in: controller)
            #expect(controller.selectedTab?.id == "wi_network")
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
        let controller = makeBoundSession(tabs: [.dom(), .network()])
        let webView = makeTestWebView()

        await controller.connect(to: webView)
        await selectTab("wi_network", in: controller)
        await waitForControllerState(
            controller,
            lifecycle: .active,
            selectedTabID: "wi_network",
            hasAttachedPage: true,
            networkMode: .active
        )

        await controller.connect(to: nil)
        await waitForControllerState(
            controller,
            lifecycle: .suspended,
            selectedTabID: "wi_network",
            hasAttachedPage: false,
            networkMode: .stopped
        )

        await controller.connect(to: webView)
        await waitForControllerState(
            controller,
            lifecycle: .active,
            selectedTabID: "wi_network",
            hasAttachedPage: true,
            networkMode: .active
        )
    }

    @Test
    func hidingLastVisibleUIHostSuspendsRuntimeUntilUIHostReturns() async {
        let controller = makeBoundSession(tabs: [.dom(), .network()], selectedTabID: "wi_network")
        let webView = makeTestWebView()

        await controller.applyHostState(pageWebView: webView, visibility: .visible)
        let uiHostID = controller.registerHost()
        controller.updateHost(
            uiHostID,
            pageWebView: webView,
            visibility: .visible,
            isAttached: true
        )
        await waitForControllerState(
            controller,
            lifecycle: .active,
            selectedTabID: "wi_network",
            hasAttachedPage: true,
            networkMode: .active
        )

        controller.updateHost(
            uiHostID,
            pageWebView: webView,
            visibility: .hidden,
            isAttached: true
        )
        await waitForControllerState(
            controller,
            lifecycle: .suspended,
            selectedTabID: "wi_network",
            hasAttachedPage: false,
            networkMode: .stopped
        )

        controller.updateHost(
            uiHostID,
            pageWebView: webView,
            visibility: .visible,
            isAttached: true
        )
        await waitForControllerState(
            controller,
            lifecycle: .active,
            selectedTabID: "wi_network",
            hasAttachedPage: true,
            networkMode: .active
        )
    }

    @Test
    func idempotentVisibleDirectReconnectStillReactivatesAfterUIHostClose() async {
        let controller = makeBoundSession(tabs: [.dom(), .network()], selectedTabID: "wi_network")
        let webView = makeTestWebView()

        await controller.applyHostState(pageWebView: webView, visibility: .visible)
        let uiHostID = controller.registerHost()
        controller.updateHost(
            uiHostID,
            pageWebView: webView,
            visibility: .visible,
            isAttached: true
        )
        await waitForControllerState(
            controller,
            lifecycle: .active,
            selectedTabID: "wi_network",
            hasAttachedPage: true,
            networkMode: .active
        )

        controller.updateHost(
            uiHostID,
            pageWebView: webView,
            visibility: .hidden,
            isAttached: true
        )
        await waitForControllerState(
            controller,
            lifecycle: .suspended,
            selectedTabID: "wi_network",
            hasAttachedPage: false,
            networkMode: .stopped
        )

        controller.unregisterHost(uiHostID)
        await controller.connect(to: webView)
        await waitForControllerState(
            controller,
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
    ) -> WIInspectorController {
        let controller = WIInspectorController()
        controller.setTabs(tabs)
        if let selectedTabID {
            let tab = controller.tabs.first(where: { $0.identifier == selectedTabID })
            controller.setSelectedTab(tab)
        }
        return controller
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

    private func selectTab(_ identifier: String, in controller: WIInspectorController) async {
        let tab = controller.tabs.first(where: { $0.identifier == identifier })
        controller.setSelectedTab(tab)

        let expectedLifecycle = controller.lifecycle
        let expectedMode: NetworkLoggingMode
        let expectedDOMAttached: Bool
        let expectedNetworkAttached: Bool
        switch expectedLifecycle {
        case .active:
            expectedDOMAttached = controller.tabs.contains {
                $0.identifier == WITab.domTabID || $0.identifier == WITab.elementTabID
            }
            expectedNetworkAttached = controller.tabs.contains { $0.identifier == WITab.networkTabID }
            expectedMode = identifier == WITab.networkTabID && expectedNetworkAttached ? .active : (
                expectedNetworkAttached ? .buffering : .stopped
            )
        case .suspended, .disconnected:
            expectedMode = .stopped
            expectedDOMAttached = false
            expectedNetworkAttached = false
        }

        for _ in 0..<80 {
            if controller.lifecycle == expectedLifecycle,
               controller.selectedTab?.id == identifier,
               controller.dom.session.hasPageWebView == expectedDOMAttached,
               controller.network.session.hasAttachedPageWebView == expectedNetworkAttached,
               controller.network.session.mode == expectedMode {
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        Issue.record("Timed out waiting for synchronized tab selection state")
    }

    private func waitForControllerState(
        _ controller: WIInspectorController,
        lifecycle: WISessionLifecycle,
        selectedTabID: String?,
        hasAttachedPage: Bool,
        networkMode: NetworkLoggingMode
    ) async {
        for _ in 0..<80 {
            if controller.lifecycle == lifecycle,
               controller.selectedTab?.id == selectedTabID,
               controller.dom.session.hasPageWebView == hasAttachedPage,
               controller.network.session.hasAttachedPageWebView == hasAttachedPage,
               controller.network.session.mode == networkMode {
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        Issue.record(
            """
            Timed out waiting for synchronized controller state \
            lifecycle=\(controller.lifecycle) \
            selectedTab=\(controller.selectedTab?.id ?? "nil") \
            domAttached=\(controller.dom.session.hasPageWebView) \
            networkAttached=\(controller.network.session.hasAttachedPageWebView) \
            networkMode=\(controller.network.session.mode)
            """
        )
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
