import Testing
import WebKit
import ObservationBridge
import WebInspectorKit
import WebInspectorTestSupport
@testable import WebInspectorCore
@testable import WebInspectorCore
@testable import WebInspectorCore
@testable import WebInspectorCore
@testable import WebInspectorUI
@testable import WebInspectorTransport

@MainActor
@Suite(.serialized, .webKitIsolated)
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
        let controller = WISessionController()
        controller.configurePanels([WITab.dom().configuration, WITab.network().configuration])
        selectTab("wi_network", in: controller)
        let webView = makeTestWebView()

        controller.connect(to: webView)

        #expect(controller.lifecycle == .active)
        #expect(controller.selectedPanelConfiguration?.identifier == "wi_network")

        controller.connect(to: nil)
        #expect(controller.lifecycle == .suspended)
        #expect(controller.selectedPanelConfiguration?.identifier == "wi_network")

        controller.disconnect()
        #expect(controller.lifecycle == .disconnected)
        #expect(controller.selectedPanelConfiguration?.identifier == "wi_network")
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

        let controller = WISessionController()
        controller.configurePanels([])
        selectTab("missing", in: controller)
        controller.configurePanels([customA.configuration, customB.configuration])

        #expect(controller.selectedPanelConfiguration?.identifier == "a")
    }

    @Test
    func setTabsRebuildKeepsSelectedTabNormalized() {
        let originalA = WITab(id: "a", title: "A", systemImage: "a.circle")
        let originalB = WITab(id: "b", title: "B", systemImage: "b.circle")
        let replacementA = WITab(id: "a", title: "A", systemImage: "a.circle")
        let replacementC = WITab(id: "c", title: "C", systemImage: "c.circle")

        let controller = WISessionController()
        controller.configurePanels([originalA.configuration, originalB.configuration])
        controller.setSelectedPanelFromUI(originalB.configuration)
        #expect(controller.selectedPanelConfiguration?.identifier == "b")

        controller.configurePanels([replacementA.configuration, replacementC.configuration])

        #expect(controller.selectedPanelConfiguration?.identifier == "a")

        controller.configurePanels([])
        #expect(controller.selectedPanelConfiguration == nil)
    }

    @Test
    func selectedPanelObservationEmitsOnSelectionChange() async {
        let controller = WISessionController()
        controller.configurePanels([WITab.dom().configuration, WITab.network().configuration])
        let expectedNetworkID = WITab.networkTabID
        let recorder = ObservationRecorder<String?>()
        recorder.record { didChange in
            controller.observeTask([\.selectedPanelConfiguration]) {
                didChange(controller.selectedPanelConfiguration?.identifier)
            }
        }

        let networkPanel = controller.panelConfigurations.first { $0.identifier == WITab.networkTabID }
        controller.setSelectedPanelFromUI(networkPanel)
        let observedValue = await recorder.next(where: { $0 == expectedNetworkID })
        #expect(observedValue == expectedNetworkID)
    }

    private func makeTestWebView() -> WKWebView {
        makeIsolatedTestWebView()
    }

#if canImport(AppKit)
    @Test
    func macOSNativeLoadingStateRebindsDOMWhileKeepingNetworkAttached() async {
        await withWebKitTestIsolation {
            let clock = TestClock()
            let domDriver = RebindDOMPageDriver()
            let networkDriver = RebindNetworkPageDriver()
            let controller = WISessionController(
                domSession: WIDOMRuntime(
                    configuration: .init(),
                    graphStore: DOMGraphStore(),
                    backend: domDriver
                ),
                networkSession: WINetworkRuntime(
                    configuration: .init(),
                    backend: networkDriver
                ),
                rebindClock: clock
            )
            let webView = makeTestWebView()

            controller.configurePanels([WITab.dom().configuration, WITab.network().configuration])
            controller.connect(to: webView)

            await loadHTML("<html><body><p>initial</p></body></html>", in: webView)
            await clock.sleep(untilSuspendedBy: 1)
            clock.advance(by: .milliseconds(20))
            await domDriver.resumeCounter.wait(untilAtLeast: 1)

            let domPrepareBaseline = domDriver.prepareForNavigationReconnectCallCount
            let domResumeBaseline = domDriver.resumeAfterNavigationReconnectCallCount
            let domReloadBaseline = domDriver.reloadDocumentCallCount
            let networkPrepareBaseline = networkDriver.prepareForNavigationReconnectCallCount
            let networkResumeBaseline = networkDriver.resumeAfterNavigationReconnectCallCount

            await loadHTML("<html><body><p>follow-up</p></body></html>", in: webView)
            await clock.sleep(untilSuspendedBy: 1)
            clock.advance(by: .milliseconds(20))
            await domDriver.resumeCounter.wait(untilAtLeast: domResumeBaseline + 1)

            #expect(domDriver.prepareForNavigationReconnectCallCount == domPrepareBaseline + 1)
            #expect(domDriver.resumeAfterNavigationReconnectCallCount >= domResumeBaseline + 1)
            #expect(domDriver.reloadDocumentCallCount >= domReloadBaseline + 1)
            #expect(networkDriver.prepareForNavigationReconnectCallCount == networkPrepareBaseline)
            #expect(networkDriver.resumeAfterNavigationReconnectCallCount == networkResumeBaseline)
            #expect(networkDriver.webView === webView)
        }
    }

    private func loadHTML(_ html: String, in webView: WKWebView) async {
        let delegate = NavigationDelegate()
        webView.navigationDelegate = delegate

        await withCheckedContinuation { continuation in
            delegate.continuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        }
    }
#endif

    private func selectTab(_ identifier: String, in controller: WISessionController) {
        let panel = controller.panelConfigurations.first(where: { $0.identifier == identifier })
            ?? WIPanelConfiguration(kind: .custom(identifier))
        controller.setSelectedPanelFromUI(panel)
    }
}

#if canImport(AppKit)
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
private final class RebindDOMPageDriver: WIDOMBackend {
    weak var eventSink: (any WIDOMProtocolEventSink)?
    private(set) weak var webView: WKWebView?
    let support = WIBackendSupport(
        availability: .supported,
        backendKind: .nativeInspectorMacOS,
        capabilities: [.domDomain, .pageTargetRouting]
    )

    private(set) var prepareForNavigationReconnectCallCount = 0
    private(set) var resumeAfterNavigationReconnectCallCount = 0
    private(set) var reloadDocumentCallCount = 0
    let prepareCounter = AsyncCounter()
    let resumeCounter = AsyncCounter()
    let reloadCounter = AsyncCounter()

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
        await reloadCounter.increment()
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

    func prepareForNavigationReconnect() {
        prepareForNavigationReconnectCallCount += 1
        Task {
            await prepareCounter.increment()
        }
    }

    func resumeAfterNavigationReconnect() {
        resumeAfterNavigationReconnectCallCount += 1
        Task {
            await resumeCounter.increment()
        }
    }
}

@MainActor
private final class RebindNetworkPageDriver: WINetworkBackend {
    private(set) weak var webView: WKWebView?
    let store = NetworkStore()
    let support = WIBackendSupport(
        availability: .supported,
        backendKind: .nativeInspectorMacOS,
        capabilities: [.networkDomain, .pageTargetRouting]
    )

    private(set) var prepareForNavigationReconnectCallCount = 0
    private(set) var resumeAfterNavigationReconnectCallCount = 0
    let prepareCounter = AsyncCounter()
    let resumeCounter = AsyncCounter()

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

    func fetchBodyResult(ref: String?, handle: AnyObject?, role: NetworkBody.Role) async -> WINetworkBodyFetchResult {
        _ = ref
        _ = handle
        _ = role
        return .bodyUnavailable
    }

    func prepareForNavigationReconnect() {
        prepareForNavigationReconnectCallCount += 1
        Task {
            await prepareCounter.increment()
        }
    }

    func resumeAfterNavigationReconnect() {
        resumeAfterNavigationReconnectCallCount += 1
        Task {
            await resumeCounter.increment()
        }
    }
}
#endif
