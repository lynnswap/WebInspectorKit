import Testing
import WebKit
import ObservationBridge
@testable import WebInspectorUI
@testable import WebInspectorEngine
@testable import WebInspectorRuntime

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
        #expect(controller.dom.hasPageWebView == false)
    }

    @Test
    func visibleUIHostKeepsLifecycleActiveWhenDirectHostBecomesHidden() async {
        let controller = WIInspectorController()
        let uiHostID = controller.registerHost(preferredRole: .primary)
        let webView = makeTestWebView()
        _ = controller.dom.inspectorWebViewForPresentation()

        controller.setTabs([.dom(), .network()])
        await controller.applyHostState(pageWebView: webView, visibility: .visible)

        controller.updateHost(
            uiHostID,
            pageWebView: webView,
            visibility: .visible,
            isAttached: true
        )
        await controller.waitForRuntimeApplyForTesting()
        #expect(controller.lifecycle == .active)

        let initialRuntimeReady = await waitForDOMRuntimeReady(controller.dom)
        #expect(initialRuntimeReady)
        seedSelectedDocument(into: controller.dom)
        let initialDocumentIdentity = controller.dom.document.documentIdentity
        let initialSelectedNodeID = controller.dom.document.selectedNode?.id
        controller.dom.resetFreshContextDiagnosticsForTesting()

        await controller.applyHostState(pageWebView: webView, visibility: .hidden)
        await controller.waitForRuntimeApplyForTesting()

        #expect(controller.lifecycle == .active)
        #expect(controller.dom.hasPageWebView)
        #expect(controller.dom.document.documentIdentity == initialDocumentIdentity)
        #expect(controller.dom.document.selectedNode?.id == initialSelectedNodeID)
        #expect(controller.dom.freshContextDiagnosticsForTesting.isEmpty)
    }

    @Test
    func hidingOrRemovingLastUIHostAllowsLifecycleToSuspendThenDisconnect() async {
        let controller = WIInspectorController()
        let uiHostID = controller.registerHost(preferredRole: .primary)
        let webView = makeTestWebView()

        controller.setTabs([.dom(), .network()])
        await controller.applyHostState(pageWebView: webView, visibility: .visible)
        controller.updateHost(
            uiHostID,
            pageWebView: webView,
            visibility: .visible,
            isAttached: true
        )
        await controller.waitForRuntimeApplyForTesting()

        await controller.applyHostState(pageWebView: webView, visibility: .hidden)
        controller.updateHost(
            uiHostID,
            pageWebView: webView,
            visibility: .hidden,
            isAttached: true
        )
        await controller.waitForRuntimeApplyForTesting()
        #expect(controller.lifecycle == .suspended)

        controller.unregisterHost(uiHostID)
        await controller.waitForRuntimeApplyForTesting()
        #expect(controller.lifecycle == .suspended)

        await controller.applyHostState(pageWebView: nil, visibility: .finalizing)
        #expect(controller.lifecycle == .disconnected)
    }

    @Test
    func preparedHiddenHostKeepsDocumentIdentityAndSelectionForSameWebViewHandoff() async {
        let controller = WIInspectorController()
        let uiHostID = controller.registerHost(preferredRole: .primary)
        let webView = makeTestWebView()
        _ = controller.dom.inspectorWebViewForPresentation()

        controller.setTabs([.dom(), .network()])
        await controller.applyHostState(pageWebView: webView, visibility: .visible)
        let initialRuntimeReady = await waitForDOMRuntimeReady(controller.dom)
        #expect(initialRuntimeReady)
        seedSelectedDocument(into: controller.dom)
        let initialDocumentIdentity = controller.dom.document.documentIdentity
        let initialSelectedNodeID = controller.dom.document.selectedNode?.id
        controller.dom.resetFreshContextDiagnosticsForTesting()
        controller.prepareHiddenHostForSameWebViewHandoff(uiHostID)
        controller.updateHost(
            uiHostID,
            pageWebView: webView,
            visibility: .hidden,
            isAttached: true
        )

        await controller.applyHostState(pageWebView: webView, visibility: .hidden)
        await controller.waitForRuntimeApplyForTesting()

        #expect(controller.lifecycle == .active)
        #expect(controller.dom.document.documentIdentity == initialDocumentIdentity)
        #expect(controller.dom.document.selectedNode?.id == initialSelectedNodeID)
        #expect(controller.dom.freshContextDiagnosticsForTesting.isEmpty)

        controller.updateHost(
            uiHostID,
            pageWebView: webView,
            visibility: .visible,
            isAttached: true
        )
        await controller.waitForRuntimeApplyForTesting()

        #expect(controller.lifecycle == .active)
        #expect(controller.dom.document.documentIdentity == initialDocumentIdentity)
        #expect(controller.dom.document.selectedNode?.id == initialSelectedNodeID)
        #expect(controller.dom.freshContextDiagnosticsForTesting.isEmpty)
    }

    @Test
    func preparedHiddenHostDoesNotRetargetDifferentWebViewUntilVisible() async {
        let controller = WIInspectorController()
        let uiHostID = controller.registerHost(preferredRole: .primary)
        let currentWebView = makeTestWebView()
        let replacementWebView = makeTestWebView()

        controller.setTabs([.dom(), .network()])
        await controller.applyHostState(pageWebView: currentWebView, visibility: .visible)
        seedSelectedDocument(into: controller.dom)
        controller.dom.resetFreshContextDiagnosticsForTesting()
        controller.prepareHiddenHostForSameWebViewHandoff(uiHostID)
        controller.updateHost(
            uiHostID,
            pageWebView: replacementWebView,
            visibility: .hidden,
            isAttached: true
        )

        await controller.applyHostState(pageWebView: currentWebView, visibility: .hidden)
        await controller.waitForRuntimeApplyForTesting()

        #expect(controller.lifecycle == .suspended)
        #expect(controller.testPrimaryHostPageWebViewIdentity == ObjectIdentifier(replacementWebView))

        controller.updateHost(
            uiHostID,
            pageWebView: replacementWebView,
            visibility: .visible,
            isAttached: true
        )
        await controller.waitForRuntimeApplyForTesting()

        #expect(controller.lifecycle == .active)
        #expect(controller.testPrimaryHostPageWebViewIdentity == ObjectIdentifier(replacementWebView))
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

    private func makeTestWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func waitForDOMRuntimeReady(_ inspector: WIDOMInspector) async -> Bool {
        for _ in 0..<300 {
            if inspector.testCurrentContextID != nil,
               inspector.testIsPageReadyForSelection,
               inspector.document.rootNode != nil {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    private func seedSelectedDocument(into inspector: WIDOMInspector) {
        let selectedLocalID: UInt64 = 42
        let attributes = [DOMAttribute(nodeId: Int(selectedLocalID), name: "id", value: "selected")]

        inspector.document.replaceDocument(
            with: .init(
                root: DOMGraphNodeDescriptor(
                    localID: 1,
                    backendNodeID: 1,
                    nodeType: 1,
                    nodeName: "HTML",
                    localName: "html",
                    nodeValue: "",
                    attributes: [],
                    childCount: 1,
                    layoutFlags: [],
                    isRendered: true,
                    children: [
                        DOMGraphNodeDescriptor(
                            localID: selectedLocalID,
                            backendNodeID: Int(selectedLocalID),
                            nodeType: 1,
                            nodeName: "DIV",
                            localName: "div",
                            nodeValue: "",
                            attributes: attributes,
                            childCount: 0,
                            layoutFlags: [],
                            isRendered: true,
                            children: []
                        )
                    ]
                )
            )
        )
        inspector.document.applySelectionSnapshot(
            .init(
                localID: selectedLocalID,
                attributes: attributes,
                path: ["html", "body", "div"],
                selectorPath: "#selected",
                styleRevision: 0
            )
        )
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
