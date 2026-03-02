import Testing
import WebKit
import ObservationsCompat
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
    func lifecycleTransitionsKeepSelectionOrdering() {
        let controller = WIModel()
        controller.setTabs([.dom(), .network()])
        selectTab("wi_network", in: controller)
        let webView = makeTestWebView()

        controller.connect(to: webView)

        #expect(controller.lifecycle == .active)
        #expect(controller.selectedTab?.id == "wi_network")

        controller.connect(to: nil)
        #expect(controller.lifecycle == .suspended)
        #expect(controller.selectedTab?.id == "wi_network")

        controller.disconnect()
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

        let controller = WIModel()
        controller.setTabs([])
        selectTab("missing", in: controller)
        controller.setTabs([customA, customB])

        #expect(controller.selectedTab?.id == "a")
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

        let controller = WIModel()
        controller.setTabs([.dom(), .network()])

        let recorder = Recorder()
        let handle = controller.observeTask([\.selectedTab]) {
            await recorder.append(controller.selectedTab?.identifier)
        }
        defer { handle.cancel() }

        let networkTab = controller.tabs.first { $0.identifier == WITab.networkTabID }
        controller.setSelectedTabFromUI(networkTab)

        for _ in 0..<50 {
            let values = await recorder.snapshot()
            if values.contains(WITab.networkTabID) {
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        Issue.record("selectedTab observation did not emit network selection")
    }

    private func makeTestWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func selectTab(_ identifier: String, in controller: WIModel) {
        let tab = controller.tabs.first(where: { $0.identifier == identifier })
        controller.setSelectedTabFromUI(tab)
    }
}
