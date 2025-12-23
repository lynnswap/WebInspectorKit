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

        viewModel.setRecording(.stopped)
        #expect(viewModel.store.isRecording == false)

        viewModel.setRecording(.active)
        #expect(viewModel.store.isRecording == true)

        viewModel.setRecording(.buffering)
        #expect(viewModel.store.isRecording == true)
    }

    @Test
    func clearNetworkLogsResetsStoreState() throws {
        let viewModel = WINetworkViewModel()
        let store = viewModel.store

        let payload = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 1,
            "url": "https://example.com",
            "method": "GET",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_000.0, wallMs: 1_700_000_000_000.0)
        ])
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

        let startEvent = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 2,
            "url": "https://example.com/api",
            "method": "POST",
            "headers": ["accept": "application/json"],
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_000.0, wallMs: 1_700_000_000_000.0)
        ])
        let responseEvent = try NetworkTestHelpers.decodeEvent([
            "kind": "responseReceived",
            "requestId": 2,
            "status": 201,
            "statusText": "Created",
            "mimeType": "application/json",
            "headers": ["content-type": "application/json"],
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_200.0, wallMs: 1_700_000_000_200.0)
        ])
        let finishEvent = try NetworkTestHelpers.decodeEvent([
            "kind": "loadingFinished",
            "requestId": 2,
            "encodedBodyLength": 512,
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_400.0, wallMs: 1_700_000_000_400.0)
        ])

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
