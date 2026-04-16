import Testing
import WebKit
import ObservationBridge
@testable import WebInspectorUI
@testable import WebInspectorEngine
@_spi(Monocly) @testable import WebInspectorRuntime

@MainActor
struct WISessionStateTests {
    @Test
    func tabUserInfoKeepsAssignedValue() {
        let tab = WITab(
            id: "custom",
            title: "Custom",
            systemImage: "circle",
            userInfo: ["key": "value"]
        )

        let initial = tab.userInfo as? [String: String]
        #expect(initial?["key"] == "value")

        tab.userInfo = 123
        #expect((tab.userInfo as? Int) == 123)
    }

    @Test
    func tabEqualityUsesIdentity() {
        let first = WITab.dom()
        let sameReference = first
        let second = WITab.dom()

        #expect(first == sameReference)
        #expect(first != second)
    }

    @Test
    func lifecycleTransitionsKeepSelectionOrdering() async {
        let controller = WIInspectorController()
        controller.setTabs([.dom(), .network()])
        selectTab("wi_network", in: controller)
        let webView = makeTestWebView()

        await controller.applyHostState(pageWebView: webView, visibility: .visible)

        #expect(controller.lifecycle == .active)
        #expect(controller.selectedTab?.id == "wi_network")

        await controller.applyHostState(pageWebView: webView, visibility: .hidden)
        #expect(controller.lifecycle == .suspended)
        #expect(controller.selectedTab?.id == "wi_network")

        await controller.finalize()
        #expect(controller.lifecycle == .disconnected)
        #expect(controller.selectedTab?.id == "wi_network")
    }

    @Test
    func rapidHostUpdatesKeepLifecycleAtLatestTargetUntilFinalCommit() async {
        let controller = WIInspectorController()
        let hostID = controller.registerHost(preferredRole: .primary)
        let webView = makeTestWebView()

        controller.updateHost(
            hostID,
            pageWebView: webView,
            visibility: .visible,
            isAttached: true
        )
        await controller.waitForRuntimeApplyForTesting()
        #expect(controller.lifecycle == .active)

        let suspendedCommitGate = CommitGate()
        let activeCommitGate = CommitGate()
        controller.testRuntimeLifecycleCommitHook = { lifecycle in
            switch lifecycle {
            case .suspended:
                await suspendedCommitGate.pause()
            case .active:
                await activeCommitGate.pause()
            case .disconnected:
                break
            }
        }

        controller.updateHost(
            hostID,
            pageWebView: webView,
            visibility: .hidden,
            isAttached: true
        )
        await suspendedCommitGate.waitUntilEntered()

        controller.updateHost(
            hostID,
            pageWebView: webView,
            visibility: .visible,
            isAttached: true
        )

        await suspendedCommitGate.resume()
        await activeCommitGate.waitUntilEntered()

        #expect(controller.lifecycle == .suspended)

        await activeCommitGate.resume()
        await controller.waitForRuntimeApplyForTesting()

        #expect(controller.lifecycle == .active)
    }

    @Test
    func supersededActiveApplyStillDetachesOnFinalizingPass() async {
        let controller = WIInspectorController()
        let webView = makeTestWebView()

        let activeCommitGate = CommitGate()
        controller.testRuntimeLifecycleCommitHook = { lifecycle in
            if lifecycle == .active {
                await activeCommitGate.pause()
            }
        }

        let activateTask = Task {
            await controller.applyHostState(pageWebView: webView, visibility: .visible)
        }
        await activeCommitGate.waitUntilEntered()

        let finalizeTask = Task {
            await controller.applyHostState(pageWebView: nil, visibility: .finalizing)
        }

        await activeCommitGate.resume()
        await activateTask.value
        await finalizeTask.value

        #expect(controller.lifecycle == .disconnected)
        #expect(controller.dom.session.pageWebView == nil)
    }

    @Test
    func rapidSelectedTabChangesResolveToLatestRuntimeMode() async {
        let controller = WIInspectorController()
        let hostID = controller.registerHost(preferredRole: .primary)
        let webView = makeTestWebView()

        controller.setTabs([.dom(), .network()])
        controller.updateHost(
            hostID,
            pageWebView: webView,
            visibility: .visible,
            isAttached: true
        )
        await controller.waitForRuntimeApplyForTesting()

        guard
            let domTab = controller.tabs.first(where: { $0.identifier == WITab.domTabID }),
            let networkTab = controller.tabs.first(where: { $0.identifier == WITab.networkTabID })
        else {
            Issue.record("Expected DOM and Network tabs")
            return
        }

        controller.setSelectedTab(networkTab)
        controller.setSelectedTab(domTab)
        await controller.waitForRuntimeApplyForTesting()

        #expect(controller.selectedTab === domTab)
        #expect(controller.network.session.mode == .buffering)
    }

    @Test
    func setTabsNormalizesInvalidSelectionToFirstTab() {
        let customA = WITab(
            id: "a",
            title: "A",
            systemImage: "a.circle"
        )
        let customB = WITab(
            id: "b",
            title: "B",
            systemImage: "b.circle"
        )

        let controller = WIInspectorController()
        controller.setTabs([])
        selectTab("missing", in: controller)
        controller.setTabs([customA, customB])

        #expect(controller.selectedTab?.id == "a")
    }

    @Test
    func setTabsRebuildKeepsSelectedTabNormalized() {
        let originalA = WITab(id: "a", title: "A", systemImage: "a.circle")
        let originalB = WITab(id: "b", title: "B", systemImage: "b.circle")
        let replacementA = WITab(id: "a", title: "A", systemImage: "a.circle")
        let replacementC = WITab(id: "c", title: "C", systemImage: "c.circle")

        let controller = WIInspectorController()
        controller.setTabs([originalA, originalB])
        controller.setSelectedTab(originalB)
        #expect(controller.selectedTab?.id == "b")

        controller.setTabs([replacementA, replacementC])

        #expect(controller.selectedTab?.id == "a")

        controller.setTabs([])
        #expect(controller.selectedTab == nil)
    }

    @Test
    func selectedTabObservationEmitsOnSelectionChange() async {
        actor Recorder {
            var values: [String?] = []
            func append(_ value: String?) {
                values.append(value)
            }
            func snapshot() -> [String?] {
                values
            }
        }

        let controller = WIInspectorController()
        controller.setTabs([.dom(), .network()])

        let recorder = Recorder()
        var observationHandles = Set<ObservationHandle>()
        controller.observeTask([\.selectedTab]) {
            await recorder.append(controller.selectedTab?.identifier)
        }
        .store(in: &observationHandles)

        let networkTab = controller.tabs.first { $0.identifier == WITab.networkTabID }
        controller.setSelectedTab(networkTab)

        for _ in 0..<50 {
            let values = await recorder.snapshot()
            if values.contains(WITab.networkTabID) {
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        Issue.record("selectedTab observation did not emit network selection")
    }

    @Test
    func compactElementSelectionPersistsAcrossTabReapplicationWhenDOMTabExists() {
        let controller = WIInspectorController()
        controller.setTabs([.dom(), .network()])

        let syntheticElementTab = WITab(
            id: WITab.elementTabID,
            title: "Element",
            systemImage: "info.circle"
        )
        controller.setSelectedTab(syntheticElementTab)
        #expect(controller.selectedTab?.identifier == WITab.elementTabID)
        #expect(controller.tabs.map(\.identifier) == [WITab.domTabID, WITab.networkTabID])

        controller.setTabs([.dom(), .network()])

        #expect(controller.selectedTab?.identifier == WITab.elementTabID)
        #expect(controller.tabs.map(\.identifier) == [WITab.domTabID, WITab.networkTabID])
    }

    @Test
    func consoleHelperUsesInspectorRoleAndIdentifier() {
        let consoleTab = WITab.console()

        #expect(consoleTab.identifier == WITab.consoleTabID)
        #expect(consoleTab.role == .inspector)
    }

    @Test
    func consoleAttachesWhenConfiguredEvenIfAnotherTabIsSelected() async throws {
        let controller = WIInspectorController()
        controller.setTabs([.network(), .console()])
        let networkTab = try #require(controller.tabs.first(where: { $0.identifier == WITab.networkTabID }))
        controller.setSelectedTab(networkTab)
        let webView = makeTestWebView()

        await controller.applyHostState(pageWebView: webView, visibility: .visible)

        #expect(controller.selectedTab?.identifier == WITab.networkTabID)
        #expect(controller.console.isAttachedToPage)
    }

    @Test
    func emptyTabsDoNotActivateConsoleByDefault() async {
        let controller = WIInspectorController()
        controller.setTabs([])
        let webView = makeTestWebView()

        await controller.applyHostState(pageWebView: webView, visibility: .visible)

        #expect(controller.console.isAttachedToPage == false)
    }

    @Test
    func tearDownForDeinitDetachesConsole() async {
        let controller = WIInspectorController()
        controller.setTabs([.console()])
        let webView = makeTestWebView()

        await controller.applyHostState(pageWebView: webView, visibility: .visible)
        #expect(controller.console.isAttachedToPage)

        controller.tearDownForDeinit()

        #expect(controller.console.isAttachedToPage == false)
        #expect(controller.console.session.hasAttachedPageWebView == false)
    }

    private func makeTestWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func selectTab(_ identifier: String, in controller: WIInspectorController) {
        let tab = controller.tabs.first(where: { $0.identifier == identifier })
        controller.setSelectedTab(tab)
    }
}

private actor CommitGate {
    private var didEnter = false
    private var enterContinuations: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        didEnter = true
        let continuations = enterContinuations
        enterContinuations.removeAll()
        continuations.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard didEnter == false else {
            return
        }
        await withCheckedContinuation { continuation in
            enterContinuations.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}
