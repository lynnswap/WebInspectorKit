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

    private func selectTab(_ identifier: String, in controller: WIInspectorController) {
        let tab = controller.tabs.first(where: { $0.identifier == identifier })
        controller.setSelectedTab(tab)
    }
}
