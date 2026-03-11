import Testing
import WebKit
import ObservationBridge
@testable import WebInspectorUI
@testable import WebInspectorEngine
@testable import WebInspectorRuntime
@testable import WebInspectorTransport

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
    func setTabsRebuildKeepsSelectedTabNormalized() {
        let originalA = WITab(id: "a", title: "A", systemImage: "a.circle")
        let originalB = WITab(id: "b", title: "B", systemImage: "b.circle")
        let replacementA = WITab(id: "a", title: "A", systemImage: "a.circle")
        let replacementC = WITab(id: "c", title: "C", systemImage: "c.circle")

        let controller = WIModel()
        controller.setTabs([originalA, originalB])
        controller.setSelectedTabFromUI(originalB)
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

        let controller = WIModel()
        controller.setTabs([.dom(), .network()])

        let recorder = Recorder()
        var observationHandles = Set<ObservationHandle>()
        controller.observeTask([\.selectedTab]) {
            await recorder.append(controller.selectedTab?.identifier)
        }
        .store(in: &observationHandles)

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

    @Test
    func macOSNativeLoadingStateTriggersTransportRebindHooks() async {
        let transportSnapshot = WITransportSupportSnapshot(
            availability: .supported,
            backendKind: .macOSNativeInspector,
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain],
            failureReason: nil
        )
        let domDriver = RebindDOMPageDriver()
        let networkDriver = RebindNetworkPageDriver()
        let controller = WIModel(
            domSession: DOMSession(
                configuration: .init(),
                graphStore: DOMGraphStore(),
                pageAgent: domDriver,
                transportSupportSnapshot: transportSnapshot
            ),
            networkSession: NetworkSession(
                configuration: .init(),
                pageAgent: networkDriver,
                bodyFetcher: networkDriver,
                transportSupportSnapshot: transportSnapshot
            )
        )
        let webView = makeTestWebView()

        controller.setTabs([.dom(), .network()])
        controller.connect(to: webView)

        await loadHTML("<html><body><p>initial</p></body></html>", in: webView)
        let initialRebindCompleted = await waitUntil {
            domDriver.resumeAfterTransportRebindCallCount >= domDriver.prepareForTransportRebindCallCount
                && networkDriver.resumeAfterTransportRebindCallCount >= networkDriver.prepareForTransportRebindCallCount
        }
        #expect(initialRebindCompleted)

        let domPrepareBaseline = domDriver.prepareForTransportRebindCallCount
        let domResumeBaseline = domDriver.resumeAfterTransportRebindCallCount
        let domReloadBaseline = domDriver.reloadDocumentCallCount
        let networkPrepareBaseline = networkDriver.prepareForTransportRebindCallCount
        let networkResumeBaseline = networkDriver.resumeAfterTransportRebindCallCount

        await loadHTML("<html><body><p>follow-up</p></body></html>", in: webView)

        let rebindTriggered = await waitUntil {
            domDriver.prepareForTransportRebindCallCount == domPrepareBaseline + 1
                && domDriver.resumeAfterTransportRebindCallCount >= domResumeBaseline + 1
                && domDriver.reloadDocumentCallCount >= domReloadBaseline + 1
                && networkDriver.prepareForTransportRebindCallCount == networkPrepareBaseline + 1
                && networkDriver.resumeAfterTransportRebindCallCount >= networkResumeBaseline + 1
        }

        #expect(rebindTriggered)
    }

    private func makeTestWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func loadHTML(_ html: String, in webView: WKWebView) async {
        let delegate = NavigationDelegate()
        webView.navigationDelegate = delegate

        await withCheckedContinuation { continuation in
            delegate.continuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        }
    }

    private func waitUntil(
        maxTicks: Int = 200,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<maxTicks {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func selectTab(_ identifier: String, in controller: WIModel) {
        let tab = controller.tabs.first(where: { $0.identifier == identifier })
        controller.setSelectedTabFromUI(tab)
    }
}

@MainActor
private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Never>?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        _ = webView
        _ = navigation
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        _ = webView
        _ = navigation
        _ = error
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        _ = webView
        _ = navigation
        _ = error
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class RebindDOMPageDriver: DOMPageDriving, DOMTransportRebindDriving {
    weak var eventSink: (any DOMProtocolEventSink)?
    private(set) weak var webView: WKWebView?

    private(set) var prepareForTransportRebindCallCount = 0
    private(set) var resumeAfterTransportRebindCallCount = 0
    private(set) var reloadDocumentCallCount = 0

    func updateConfiguration(_ configuration: DOMConfiguration) {
        _ = configuration
    }

    func attachPageWebView(_ newWebView: WKWebView?) {
        webView = newWebView
    }

    func detachPageWebView() {
        webView = nil
    }

    func setAutoSnapshot(enabled: Bool) async {
        _ = enabled
    }

    func reloadDocument(preserveState: Bool, requestedDepth: Int?) async throws {
        _ = preserveState
        _ = requestedDepth
        reloadDocumentCallCount += 1
    }

    func requestChildNodes(parentNodeId: Int) async throws -> [DOMGraphNodeDescriptor] {
        _ = parentNodeId
        return []
    }

    func captureSnapshot(maxDepth: Int) async throws -> String {
        _ = maxDepth
        return "{}"
    }

    func captureSubtree(nodeId: Int, maxDepth: Int) async throws -> String {
        _ = nodeId
        _ = maxDepth
        return "{}"
    }

    func styles(nodeId: Int, maxMatchedRules: Int) async throws -> DOMNodeStylePayload {
        _ = nodeId
        _ = maxMatchedRules
        return DOMNodeStylePayload(nodeId: 0, matched: .empty, computed: .empty)
    }

    func captureSnapshotEnvelope(maxDepth: Int) async throws -> Any {
        _ = maxDepth
        return [:] as [String: Any]
    }

    func captureSubtreeEnvelope(nodeId: Int, maxDepth: Int) async throws -> Any {
        _ = nodeId
        _ = maxDepth
        return [:] as [String: Any]
    }

    func beginSelectionMode() async throws -> DOMSelectionModeResult {
        .init(cancelled: true, requiredDepth: 0)
    }

    func cancelSelectionMode() async {
    }

    func highlight(nodeId: Int) async {
        _ = nodeId
    }

    func hideHighlight() async {
    }

    func rememberPendingSelection(nodeId: Int?) {
        _ = nodeId
    }

    func removeNode(nodeId: Int) async {
        _ = nodeId
    }

    func removeNodeWithUndo(nodeId: Int) async -> Int? {
        _ = nodeId
        return nil
    }

    func undoRemoveNode(undoToken: Int) async -> Bool {
        _ = undoToken
        return false
    }

    func redoRemoveNode(undoToken: Int, nodeId: Int?) async -> Bool {
        _ = undoToken
        _ = nodeId
        return false
    }

    func setAttribute(nodeId: Int, name: String, value: String) async {
        _ = nodeId
        _ = name
        _ = value
    }

    func removeAttribute(nodeId: Int, name: String) async {
        _ = nodeId
        _ = name
    }

    func selectionCopyText(nodeId: Int, kind: DOMSelectionCopyKind) async throws -> String {
        _ = nodeId
        _ = kind
        return ""
    }

    func prepareForTransportRebind() {
        prepareForTransportRebindCallCount += 1
    }

    func resumeAfterTransportRebind() {
        resumeAfterTransportRebindCallCount += 1
    }
}

@MainActor
private final class RebindNetworkPageDriver: NetworkPageDriving, NetworkTransportRebindDriving {
    private(set) weak var webView: WKWebView?
    let store = NetworkStore()

    private(set) var prepareForTransportRebindCallCount = 0
    private(set) var resumeAfterTransportRebindCallCount = 0

    func setMode(_ mode: NetworkLoggingMode) {
        _ = mode
    }

    func attachPageWebView(_ newWebView: WKWebView?) {
        webView = newWebView
    }

    func detachPageWebView(preparing modeBeforeDetach: NetworkLoggingMode?) {
        _ = modeBeforeDetach
        webView = nil
    }

    func clearNetworkLogs() {
    }

    func fetchBodyResult(ref: String?, handle: AnyObject?, role: NetworkBody.Role) async -> NetworkBodyFetchResult {
        _ = ref
        _ = handle
        _ = role
        return .bodyUnavailable
    }

    func prepareForTransportRebind() {
        prepareForTransportRebindCallCount += 1
    }

    func resumeAfterTransportRebind() {
        resumeAfterTransportRebindCallCount += 1
    }
}
