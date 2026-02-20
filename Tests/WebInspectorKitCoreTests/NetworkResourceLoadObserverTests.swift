import Foundation
import Testing
import WebKit
@testable import WebInspectorKitCore

@MainActor
struct NetworkResourceLoadObserverTests {
    @Test
    func dropsFetchAndXHRResourceTypesFromNativeObserver() {
        let webView = makeWebView()
        var events: [HTTPNetworkEvent] = []
        let observer = NetworkResourceLoadObserver(sessionID: "native-session") { event in
            events.append(event)
        }

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

        #expect(events.isEmpty)
    }

    @Test
    func convertsNonXHRNativeCallbacksToHTTPNetworkEvents() throws {
        let webView = makeWebView()
        var events: [HTTPNetworkEvent] = []
        let observer = NetworkResourceLoadObserver(sessionID: "native-session") { event in
            events.append(event)
        }

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

        #expect(events.count == 3)
        #expect(events[0].kind == .requestWillBeSent)
        #expect(events[1].kind == .responseReceived)
        #expect(events[2].kind == .loadingFinished)
        #expect(events[0].requestID < 0)
        #expect(events[0].requestID == events[1].requestID)
        #expect(events[1].requestID == events[2].requestID)
        #expect(events[0].sessionID == "native-session")
        #expect(events[0].requestType == "script")
        #expect(events[0].url == "https://example.com/app.js")
        #expect(events[1].statusCode == 200)
        #expect(events[2].statusCode == 200)
    }

    @Test
    func synthesizesStartEventWhenCompleteArrivesBeforeSend() {
        let webView = makeWebView()
        var events: [HTTPNetworkEvent] = []
        let observer = NetworkResourceLoadObserver(sessionID: "native-session") { event in
            events.append(event)
        }

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

        #expect(events.count == 2)
        #expect(events[0].kind == .requestWillBeSent)
        #expect(events[1].kind == .loadingFinished)
        #expect(events[0].requestID == events[1].requestID)
        #expect(events[0].requestType == "img")
    }

    @Test
    func attachReturnsFalseWhenSelectorIsUnavailable() {
        let webView = makeWebView()
        let observer = NetworkResourceLoadObserver(
            sessionID: "native-session",
            setResourceLoadDelegateSelectorName: "_not_a_real_selector:"
        ) { _ in
        }

        let attached = observer.attach(to: webView)

        #expect(attached == false)
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
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
