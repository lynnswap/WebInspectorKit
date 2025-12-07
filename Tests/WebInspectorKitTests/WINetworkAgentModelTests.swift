import Testing
import WebKit
@testable import WebInspectorKit

@MainActor
struct WINetworkAgentModelTests {
    @Test
    func setRecordingUpdatesStoreFlag() {
        let agent = WINetworkAgentModel()

        #expect(agent.store.isRecording == true)
        agent.setRecording(false)
        #expect(agent.store.isRecording == false)
        agent.setRecording(true)
        #expect(agent.store.isRecording == true)
    }

    @Test
    func clearNetworkLogsResetsEntriesAndSelection() throws {
        let agent = WINetworkAgentModel()
        let store = agent.store

        let payload = try #require(
            WINetworkEventPayload(dictionary: [
                "type": "start",
                "requestId": 1,
                "url": "https://example.com",
                "method": "GET"
            ])
        )
        store.applyEvent(payload)
        #expect(store.entries.isEmpty == false)

        agent.clearNetworkLogs()

        #expect(store.entries.isEmpty)
    }

    @Test
    func didClearPageWebViewResetsStore() throws {
        let agent = WINetworkAgentModel()
        let store = agent.store
        let payload = try #require(
            WINetworkEventPayload(dictionary: [
                "type": "start",
                "requestId": 2,
                "url": "https://example.com",
                "method": "GET"
            ])
        )
        store.applyEvent(payload)
        #expect(store.entries.count == 1)

        agent.didClearPageWebView()

        #expect(store.entries.isEmpty)
    }

    @Test
    func attachRegistersHandlersAndInstallsScripts() async {
        let agent = WINetworkAgentModel()
        let (webView, controller) = makeTestWebView()

        agent.attachPageWebView(webView)
        await waitForScripts(on: controller, atLeast: 2)

        let addedHandlerNames = controller.addedHandlers.map(\.name)
        #expect(addedHandlerNames.contains("webInspectorNetworkUpdate"))
        #expect(addedHandlerNames.contains("webInspectorNetworkBatchUpdate"))
        #expect(addedHandlerNames.contains("webInspectorNetworkReset"))
        #expect(controller.userScripts.count == 2)
        #expect(controller.userScripts.contains { $0.source.contains("webInspectorNetwork") })
    }

    @Test
    func detachRemovesHandlersAndClearsWebView() async {
        let agent = WINetworkAgentModel()
        let (webView, controller) = makeTestWebView()

        agent.attachPageWebView(webView)
        await waitForScripts(on: controller, atLeast: 2)
        agent.detachPageWebView(disableNetworkLogging: true)

        let removedHandlerNames = controller.removedHandlers.map(\.name)
        #expect(removedHandlerNames.contains("webInspectorNetworkUpdate"))
        #expect(removedHandlerNames.contains("webInspectorNetworkBatchUpdate"))
        #expect(removedHandlerNames.contains("webInspectorNetworkReset"))
        #expect(agent.webView == nil)
    }

    @Test
    func attachInstallsNetworkAgentIntoPage() async throws {
        let agent = WINetworkAgentModel()
        let (webView, controller) = makeTestWebView()

        agent.attachPageWebView(webView)
        await waitForScripts(on: controller, atLeast: 2)
        await loadHTML("<html><body><p>hello</p></body></html>", in: webView)

        let raw = try await webView.evaluateJavaScript(
            "(() => Boolean(window.webInspectorNetwork && window.webInspectorNetwork.__installed))();",
            in: nil,
            contentWorld: .page
        )
        let installed = (raw as? Bool) ?? (raw as? NSNumber)?.boolValue ?? false
        #expect(installed == true)
    }

    @Test
    func applyNetworkPayloadHandlesBatchedResourceTiming() throws {
        let agent = WINetworkAgentModel()
        let start: Double = 1_200
        let end: Double = 2_200
        let payloads: [[String: Any]] = [[
            "type": "resourceTiming",
            "session": "session-1",
            "requestId": 99,
            "url": "https://example.com/image.png",
            "method": "GET",
            "startTime": start,
            "endTime": end,
            "encodedBodyLength": 512,
            "requestType": "img"
        ]]

        let batchPayload: [String: Any] = [
            "session": "session-1",
            "events": payloads
        ]
        let batch = try #require(WINetworkBatchEventPayload(dictionary: batchPayload))
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
