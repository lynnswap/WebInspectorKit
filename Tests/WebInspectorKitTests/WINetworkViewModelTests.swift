import Testing
import WebKit
@testable import WebInspectorKit

@MainActor
struct WINetworkViewModelTests {
    @Test
    func exposesSharedStoreInstance() {
        let viewModel = WINetworkViewModel()
        #expect(viewModel.store === viewModel.session.store)
    }

    @Test
    func togglesRecordingFlag() {
        let viewModel = WINetworkViewModel()
        #expect(viewModel.store.isRecording == true)

        viewModel.setRecording(false)
        #expect(viewModel.store.isRecording == false)

        viewModel.setRecording(true)
        #expect(viewModel.store.isRecording == true)
    }

    @Test
    func clearNetworkLogsResetsStoreState() throws {
        let viewModel = WINetworkViewModel()
        let store = viewModel.store

        let payload = try #require(
            HTTPNetworkEvent(dictionary: [
                "type": "start",
                "requestId": 1,
                "url": "https://example.com",
                "method": "GET"
            ])
        )
        store.applyEvent(payload)

        #expect(store.entries.count == 1)

        viewModel.clearNetworkLogs()

        #expect(store.entries.isEmpty)
    }

    @Test
    func detachClearsLastWebViewReference() {
        let viewModel = WINetworkViewModel()
        let webView = makeTestWebView()

        viewModel.attach(to: webView)
        #expect(viewModel.session.lastPageWebView === webView)

        viewModel.detach()
        #expect(viewModel.session.lastPageWebView == nil)
    }

    @Test
    func appliesNetworkLifecycleEvents() throws {
        let viewModel = WINetworkViewModel()
        let store = viewModel.store

        let startEvent = try #require(
            HTTPNetworkEvent(dictionary: [
                "type": "start",
                "requestId": 2,
                "url": "https://example.com/api",
                "method": "POST",
                "requestHeaders": ["accept": "application/json"],
                "startTime": 1_000.0,
                "wallTime": 1_700_000_000_000.0
            ])
        )
        let responseEvent = try #require(
            HTTPNetworkEvent(dictionary: [
                "type": "response",
                "requestId": 2,
                "status": 201,
                "statusText": "Created",
                "mimeType": "application/json",
                "responseHeaders": ["content-type": "application/json"]
            ])
        )
        let finishEvent = try #require(
            HTTPNetworkEvent(dictionary: [
                "type": "finish",
                "requestId": 2,
                "endTime": 1_400.0,
                "encodedBodyLength": 512
            ])
        )

        store.applyEvent(startEvent)
        store.applyEvent(responseEvent)
        store.applyEvent(finishEvent)

        let entry = try #require(store.entry(forRequestID: 2, sessionID: nil))
        #expect(entry.method == "POST")
        #expect(entry.url == "https://example.com/api")
        #expect(entry.statusCode == 201)
        #expect(entry.statusText == "Created")
        #expect(entry.mimeType == "application/json")
        #expect(entry.requestHeaders["accept"] == "application/json")
        #expect(entry.responseHeaders["content-type"] == "application/json")
        #expect(entry.phase == .completed)
        #expect(entry.encodedBodyLength == 512)
        #expect(entry.startTimestamp == 1.0)
        #expect(entry.endTimestamp == 1.4)
        if let duration = entry.duration {
            #expect(abs(duration - 0.4) < 0.0001)
        } else {
            Issue.record("Expected duration to be calculated")
        }
    }

    private func makeTestWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(frame: .zero, configuration: configuration)
    }
}
