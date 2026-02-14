import Testing
import WebKit
@testable import WebInspectorKitCore

@MainActor
struct NetworkPageAgentTests {
    @Test
    func setRecordingUpdatesStoreFlag() {
        let agent = NetworkPageAgent()

        #expect(agent.store.isRecording == true)
        agent.setMode(.stopped)
        #expect(agent.store.isRecording == false)
        agent.setMode(.active)
        #expect(agent.store.isRecording == true)
    }

    @Test
    func setModeStoppedClearsExistingEntriesImmediately() throws {
        let agent = NetworkPageAgent()
        let start = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 12,
            "url": "https://example.com/live",
            "method": "GET",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_100.0, wallMs: 1_700_000_000_100.0)
        ])
        agent.store.applyEvent(start)
        #expect(agent.store.entries.count == 1)

        agent.setMode(.stopped)

        #expect(agent.store.entries.isEmpty)
        #expect(agent.store.isRecording == false)
    }

    @Test
    func setModeBufferingKeepsExistingEntriesAndRecordingEnabled() throws {
        let agent = NetworkPageAgent()
        let start = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 13,
            "url": "https://example.com/buffer",
            "method": "GET",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_120.0, wallMs: 1_700_000_000_120.0)
        ])
        agent.store.applyEvent(start)
        #expect(agent.store.entries.count == 1)

        agent.setMode(.buffering)

        #expect(agent.store.entries.count == 1)
        #expect(agent.store.isRecording == true)
    }

    @Test
    func modeTransitionsPreserveBatchApplicationBoundaries() throws {
        let agent = NetworkPageAgent()
        let firstBatch = try NetworkTestHelpers.decodeBatch([
            "version": 1,
            "sessionId": "mode-session",
            "seq": 1,
            "events": [[
                "kind": "resourceTiming",
                "requestId": 30,
                "url": "https://example.com/first",
                "startTime": NetworkTestHelpers.timePayload(monotonicMs: 2_000.0, wallMs: 1_700_000_001_000.0),
                "endTime": NetworkTestHelpers.timePayload(monotonicMs: 2_010.0, wallMs: 1_700_000_001_010.0)
            ]]
        ])

        agent.setMode(.buffering)
        agent.store.applyNetworkBatch(firstBatch)
        #expect(agent.store.entry(forRequestID: 30, sessionID: "mode-session") != nil)

        let secondBatch = try NetworkTestHelpers.decodeBatch([
            "version": 1,
            "sessionId": "mode-session",
            "seq": 2,
            "events": [[
                "kind": "resourceTiming",
                "requestId": 31,
                "url": "https://example.com/second",
                "startTime": NetworkTestHelpers.timePayload(monotonicMs: 2_020.0, wallMs: 1_700_000_001_020.0),
                "endTime": NetworkTestHelpers.timePayload(monotonicMs: 2_030.0, wallMs: 1_700_000_001_030.0)
            ]]
        ])
        agent.setMode(.active)
        agent.store.applyNetworkBatch(secondBatch)
        #expect(agent.store.entry(forRequestID: 31, sessionID: "mode-session") != nil)

        let beforeStoppedCount = agent.store.entries.count
        agent.setMode(.stopped)
        let thirdBatch = try NetworkTestHelpers.decodeBatch([
            "version": 1,
            "sessionId": "mode-session",
            "seq": 3,
            "events": [[
                "kind": "resourceTiming",
                "requestId": 32,
                "url": "https://example.com/stopped",
                "startTime": NetworkTestHelpers.timePayload(monotonicMs: 2_040.0, wallMs: 1_700_000_001_040.0),
                "endTime": NetworkTestHelpers.timePayload(monotonicMs: 2_050.0, wallMs: 1_700_000_001_050.0)
            ]]
        ])
        agent.store.applyNetworkBatch(thirdBatch)

        #expect(beforeStoppedCount > 0)
        #expect(agent.store.entries.count == 0)
        #expect(agent.store.entry(forRequestID: 32, sessionID: "mode-session") == nil)
    }

    @Test
    func clearNetworkLogsResetsEntriesAndSelection() throws {
        let agent = NetworkPageAgent()
        let store = agent.store

        let payload = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 1,
            "url": "https://example.com",
            "method": "GET",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_000.0, wallMs: 1_700_000_000_000.0)
        ])
        store.applyEvent(payload)
        #expect(store.entries.isEmpty == false)

        agent.clearNetworkLogs()

        #expect(store.entries.isEmpty)
    }

    @Test
    func didClearPageWebViewResetsStore() throws {
        let agent = NetworkPageAgent()
        let store = agent.store
        let payload = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 2,
            "url": "https://example.com",
            "method": "GET",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_000.0, wallMs: 1_700_000_000_000.0)
        ])
        store.applyEvent(payload)
        #expect(store.entries.count == 1)

        agent.didClearPageWebView()

        #expect(store.entries.isEmpty)
    }

    @Test
    func attachRegistersHandlersAndInstallsScripts() async {
        let agent = NetworkPageAgent()
        let (webView, controller) = makeTestWebView()

        agent.attachPageWebView(webView)
        await waitForScripts(on: controller, atLeast: 2)

        let addedHandlerNames = controller.addedHandlers.map(\.name)
        #expect(addedHandlerNames.contains("webInspectorNetworkEvents"))
        #expect(addedHandlerNames.contains("webInspectorNetworkReset"))
        #expect(controller.userScripts.count == 2)
        #expect(controller.userScripts.contains { $0.source.contains("webInspectorNetworkAgent") })
    }

    @Test
    func detachRemovesHandlersAndClearsWebView() async {
        let agent = NetworkPageAgent()
        let (webView, controller) = makeTestWebView()

        agent.attachPageWebView(webView)
        await waitForScripts(on: controller, atLeast: 2)
        let removedBefore = controller.removedHandlers.count
        agent.detachPageWebView(preparing: .stopped)

        let removedHandlerNames = controller.removedHandlers.map(\.name)
        #expect(controller.removedHandlers.count > removedBefore)
        #expect(removedHandlerNames.contains("webInspectorNetworkEvents"))
        #expect(removedHandlerNames.contains("webInspectorNetworkReset"))
        #expect(agent.webView == nil)
    }

    @Test
    func attachInstallsNetworkAgentIntoPage() async throws {
        let agent = NetworkPageAgent()
        let (webView, controller) = makeTestWebView()

        agent.attachPageWebView(webView)
        await waitForScripts(on: controller, atLeast: 2)
        await loadHTML("<html><body><p>hello</p></body></html>", in: webView)

        let raw = try await webView.evaluateJavaScript(
            "(() => Boolean(window.webInspectorNetworkAgent && window.webInspectorNetworkAgent.__installed))();",
            in: nil,
            contentWorld: .page
        )
        let installed = (raw as? Bool) ?? (raw as? NSNumber)?.boolValue ?? false
        #expect(installed == true)
    }

    @Test
    func applyNetworkPayloadHandlesBatchedResourceTiming() throws {
        let agent = NetworkPageAgent()
        let start: Double = 1_200
        let end: Double = 2_200
        let payloads: [[String: Any]] = [[
            "kind": "resourceTiming",
            "requestId": 99,
            "url": "https://example.com/image.png",
            "method": "GET",
            "startTime": NetworkTestHelpers.timePayload(monotonicMs: start, wallMs: 1_700_000_000_000.0),
            "endTime": NetworkTestHelpers.timePayload(monotonicMs: end, wallMs: 1_700_000_001_000.0),
            "encodedBodyLength": 512,
            "initiator": "img"
        ]]

        let batchPayload: [String: Any] = [
            "version": 1,
            "sessionId": "session-1",
            "seq": 1,
            "events": payloads
        ]
        let batch = try NetworkTestHelpers.decodeBatch(batchPayload)
        agent.store.applyBatchedInsertions(batch)

        let entry = try #require(agent.store.entry(forRequestID: 99, sessionID: "session-1"))
        #expect(entry.phase == .completed)
        let expectedDuration = (end - start) / 1000.0
        let duration = try #require(entry.duration)
        #expect(abs(duration - expectedDuration) < 0.0001)
        #expect(entry.encodedBodyLength == 512)
        #expect(entry.requestType == "img")
    }

    private func makeTestWebView() -> (WKWebView, RecordingUserContentController) {
        let controller = RecordingUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        return (webView, controller)
    }

    private func waitForScripts(on controller: RecordingUserContentController, atLeast count: Int) async {
        for _ in 0..<50 {
            if controller.userScripts.count >= count {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func loadHTML(_ html: String, in webView: WKWebView) async {
        let navigationDelegate = NavigationDelegate()
        webView.navigationDelegate = navigationDelegate

        await withCheckedContinuation { continuation in
            navigationDelegate.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
}

private final class RecordingUserContentController: WKUserContentController {
    private(set) var addedHandlers: [(name: String, world: WKContentWorld)] = []
    private(set) var removedHandlers: [(name: String, world: WKContentWorld)] = []

    override func add(_ scriptMessageHandler: WKScriptMessageHandler, contentWorld: WKContentWorld, name: String) {
        addedHandlers.append((name, contentWorld))
        super.add(scriptMessageHandler, contentWorld: contentWorld, name: name)
    }

    override func removeScriptMessageHandler(forName name: String, contentWorld: WKContentWorld) {
        removedHandlers.append((name, contentWorld))
        super.removeScriptMessageHandler(forName: name, contentWorld: contentWorld)
    }
}

private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Never>?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume()
        continuation = nil
    }
}
