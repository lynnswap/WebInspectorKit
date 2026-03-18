import Foundation
import Testing
import WebKit
@testable import WebInspectorEngine

@MainActor
struct NetworkResourceLoadObserverTests {
    @Test
    func dropsFetchAndXHRResourceTypesFromNativeObserver() {
        let webView = makeWebView()
        let store = NetworkStore()
        let observer = NetworkResourceLoadObserver(sessionID: "native-session", store: store)

        let fetchInfo = FakeResourceLoadInfo(
            loadID: 1,
            resourceType: 5,
            url: URL(string: "https://example.com/fetch")!,
            method: "GET"
        )
        let request = URLRequest(url: URL(string: "https://example.com/fetch")!)
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/fetch")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/json"]
        )!

        observer.handleDidSendRequest(webView: webView, resourceLoad: fetchInfo, request: request)
        observer.handleDidReceiveResponse(webView: webView, resourceLoad: fetchInfo, response: response)
        observer.handleDidComplete(webView: webView, resourceLoad: fetchInfo, error: nil, response: response)

        let xhrInfo = FakeResourceLoadInfo(
            loadID: 2,
            resourceType: 12,
            url: URL(string: "https://example.com/xhr")!,
            method: "POST"
        )
        let xhrRequest = URLRequest(url: URL(string: "https://example.com/xhr")!)
        observer.handleDidSendRequest(webView: webView, resourceLoad: xhrInfo, request: xhrRequest)
        observer.handleDidComplete(webView: webView, resourceLoad: xhrInfo, error: nil, response: nil)

        #expect(store.entries.isEmpty)
    }

    @Test
    func convertsNonXHRNativeCallbacksToStoreUpdates() throws {
        let webView = makeWebView()
        let store = NetworkStore()
        let observer = NetworkResourceLoadObserver(sessionID: "native-session", store: store)

        let info = FakeResourceLoadInfo(
            loadID: 10,
            resourceType: 10,
            url: URL(string: "https://example.com/app.js")!,
            method: "GET"
        )
        var request = URLRequest(url: URL(string: "https://example.com/app.js")!)
        request.httpMethod = "GET"
        request.setValue("application/javascript", forHTTPHeaderField: "accept")

        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/app.js")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/javascript"]
        )!

        observer.handleDidSendRequest(webView: webView, resourceLoad: info, request: request)
        observer.handleDidReceiveResponse(webView: webView, resourceLoad: info, response: response)
        observer.handleDidComplete(webView: webView, resourceLoad: info, error: nil, response: response)

        #expect(store.entries.count == 1)
        let entry = try #require(store.entries.first)
        #expect(entry.requestID < 0)
        #expect(entry.sessionID == "native-session")
        #expect(entry.requestType == "script")
        #expect(entry.url == "https://example.com/app.js")
        #expect(entry.statusCode == 200)
        #expect(entry.phase == .completed)
    }

    @Test
    func synthesizesStartEventWhenCompleteArrivesBeforeSend() {
        let webView = makeWebView()
        let store = NetworkStore()
        let observer = NetworkResourceLoadObserver(sessionID: "native-session", store: store)

        let info = FakeResourceLoadInfo(
            loadID: 20,
            resourceType: 4,
            url: URL(string: "https://example.com/image.png")!,
            method: "GET"
        )
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/image.png")!,
            statusCode: 304,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "image/png"]
        )!

        observer.handleDidComplete(webView: webView, resourceLoad: info, error: nil, response: response)

        #expect(store.entries.count == 1)
        let entry = store.entries.first
        #expect(entry?.phase == .completed)
        #expect(entry?.requestID ?? 0 < 0)
        #expect(entry?.requestType == "img")
    }

    @Test
    func attachReturnsFalseWhenSelectorIsUnavailable() {
        let webView = makeWebView()
        let observer = NetworkResourceLoadObserver(
            sessionID: "native-session",
            store: NetworkStore(),
            supportsResourceLoadDelegate: { _ in false }
        )

        let attached = observer.attach(to: webView)

        #expect(attached == false)
    }

    @Test
    func skipsCallbacksWhenEventEmissionIsDisabled() {
        let webView = makeWebView()
        let store = NetworkStore()
        let observer = NetworkResourceLoadObserver(
            sessionID: "native-session",
            store: store,
            isEventEmissionEnabled: { false }
        )

        let info = FakeResourceLoadInfo(
            loadID: 100,
            resourceType: 10,
            url: URL(string: "https://example.com/app.js")!,
            method: "GET"
        )
        var request = URLRequest(url: URL(string: "https://example.com/app.js")!)
        request.httpMethod = "GET"
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/app.js")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/javascript"]
        )!

        observer.handleDidSendRequest(webView: webView, resourceLoad: info, request: request)
        observer.handleDidReceiveResponse(webView: webView, resourceLoad: info, response: response)
        observer.handleDidComplete(webView: webView, resourceLoad: info, error: nil, response: response)

        #expect(store.entries.isEmpty)
    }

    @Test
    func keepsInFlightCallbacksUntilCompletionAfterEmissionIsDisabled() {
        let webView = makeWebView()
        let store = NetworkStore()
        let emissionState = EmissionState(enabled: true)
        let observer = NetworkResourceLoadObserver(
            sessionID: "native-session",
            store: store,
            isEventEmissionEnabled: { emissionState.enabled }
        )

        let info = FakeResourceLoadInfo(
            loadID: 101,
            resourceType: 10,
            url: URL(string: "https://example.com/inflight.js")!,
            method: "GET"
        )
        var request = URLRequest(url: URL(string: "https://example.com/inflight.js")!)
        request.httpMethod = "GET"
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/inflight.js")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/javascript"]
        )!

        observer.handleDidSendRequest(webView: webView, resourceLoad: info, request: request)
        emissionState.enabled = false
        observer.handleDidComplete(webView: webView, resourceLoad: info, error: nil, response: response)

        #expect(store.entries.count == 1)
        #expect(store.entries.first?.phase == .completed)

        let nextInfo = FakeResourceLoadInfo(
            loadID: 102,
            resourceType: 10,
            url: URL(string: "https://example.com/new.js")!,
            method: "GET"
        )
        observer.handleDidSendRequest(webView: webView, resourceLoad: nextInfo, request: request)
        observer.handleDidComplete(webView: webView, resourceLoad: nextInfo, error: nil, response: response)
        #expect(store.entries.count == 1)
    }

    @Test
    func ignoresFollowUpsForLoadsStartedWhileEmissionWasDisabledAfterReenable() {
        let webView = makeWebView()
        let store = NetworkStore()
        let emissionState = EmissionState(enabled: false)
        let observer = NetworkResourceLoadObserver(
            sessionID: "native-session",
            store: store,
            isEventEmissionEnabled: { emissionState.enabled }
        )

        let info = FakeResourceLoadInfo(
            loadID: 103,
            resourceType: 10,
            url: URL(string: "https://example.com/suppressed.js")!,
            method: "GET"
        )
        var request = URLRequest(url: URL(string: "https://example.com/suppressed.js")!)
        request.httpMethod = "GET"
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/suppressed.js")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/javascript"]
        )!

        observer.handleDidSendRequest(webView: webView, resourceLoad: info, request: request)
        emissionState.enabled = true
        observer.handleDidReceiveResponse(webView: webView, resourceLoad: info, response: response)
        observer.handleDidComplete(webView: webView, resourceLoad: info, error: nil, response: response)

        #expect(store.entries.isEmpty)
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }
}

@MainActor
private final class EmissionState {
    var enabled: Bool

    init(enabled: Bool) {
        self.enabled = enabled
    }
}

@objcMembers
private final class FakeResourceLoadInfo: NSObject {
    let resourceLoadID: NSNumber
    let resourceType: NSNumber
    let eventTimestamp: NSDate
    let originalURL: NSURL
    let originalHTTPMethod: NSString

    init(loadID: UInt64, resourceType: Int, url: URL, method: String, timestamp: Date = Date()) {
        self.resourceLoadID = NSNumber(value: loadID)
        self.resourceType = NSNumber(value: resourceType)
        self.eventTimestamp = timestamp as NSDate
        self.originalURL = url as NSURL
        self.originalHTTPMethod = method as NSString
    }
}
