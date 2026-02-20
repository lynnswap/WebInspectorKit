import Foundation
import OSLog
import WebKit

private let networkResourceObserverLogger = Logger(
    subsystem: "WebInspectorKit",
    category: "NetworkResourceLoadObserver"
)

@MainActor
final class NetworkResourceLoadObserver: NSObject {
    private struct LoadState {
        var requestID: Int
        var resourceType: Int
        var firstTimestamp: Date?
        var didSendRequest: Bool
        var didReceiveResponse: Bool
        var request: URLRequest?
        var response: URLResponse?
    }

    private enum ResourceType: Int {
        case applicationManifest = 0
        case beacon = 1
        case cspReport = 2
        case document = 3
        case image = 4
        case fetch = 5
        case font = 6
        case media = 7
        case object = 8
        case ping = 9
        case script = 10
        case stylesheet = 11
        case xmlHTTPRequest = 12
        case xslt = 13
        case other = -1
    }

    typealias EventSink = @MainActor (HTTPNetworkEvent) -> Void
    typealias SupportsResourceLoadDelegate = @MainActor (WKWebView) -> Bool
    typealias SetResourceLoadDelegate = @MainActor (WKWebView, AnyObject?) -> Bool

    private let sessionID: String
    private let includeFetchAndXHR: Bool
    private let applyEvent: EventSink
    private let supportsResourceLoadDelegate: SupportsResourceLoadDelegate
    private let setResourceLoadDelegate: SetResourceLoadDelegate
    private var statesByLoadID: [UInt64: LoadState] = [:]
    private var nextRequestID = -1
    private weak var attachedWebView: WKWebView?

    init(
        sessionID: String,
        includeFetchAndXHR: Bool = false,
        supportsResourceLoadDelegate: @escaping SupportsResourceLoadDelegate = { webView in
            WISPIRuntime.shared.canSetResourceLoadDelegate(on: webView)
        },
        setResourceLoadDelegate: @escaping SetResourceLoadDelegate = { webView, delegate in
            WISPIRuntime.shared.setResourceLoadDelegate(on: webView, delegate: delegate)
        },
        applyEvent: @escaping EventSink
    ) {
        self.sessionID = sessionID
        self.includeFetchAndXHR = includeFetchAndXHR
        self.applyEvent = applyEvent
        self.supportsResourceLoadDelegate = supportsResourceLoadDelegate
        self.setResourceLoadDelegate = setResourceLoadDelegate
        super.init()
    }

    @discardableResult
    func attach(to webView: WKWebView) -> Bool {
        if let currentWebView = attachedWebView, currentWebView !== webView {
            detach(from: currentWebView)
        }

        guard supportsResourceLoadDelegate(webView) else {
            networkResourceObserverLogger.notice(
                "native observer unavailable selector=\(WISPISymbols.setResourceLoadDelegateSelector, privacy: .public)"
            )
            return false
        }

        guard setResourceLoadDelegate(webView, self) else {
            networkResourceObserverLogger.error("native observer failed to set delegate")
            return false
        }
        attachedWebView = webView
        resetState()
        return true
    }

    func detach(from webView: WKWebView) {
        guard supportsResourceLoadDelegate(webView) else {
            resetState()
            return
        }
        _ = setResourceLoadDelegate(webView, nil)
        if attachedWebView === webView {
            attachedWebView = nil
        }
        resetState()
    }

    @objc(webView:resourceLoad:didSendRequest:)
    func webView(_ webView: WKWebView, resourceLoad: AnyObject, didSendRequest request: URLRequest) {
        handleDidSendRequest(webView: webView, resourceLoad: resourceLoad, request: request)
    }

    @objc(webView:resourceLoad:didReceiveResponse:)
    func webView(_ webView: WKWebView, resourceLoad: AnyObject, didReceiveResponse response: URLResponse) {
        handleDidReceiveResponse(webView: webView, resourceLoad: resourceLoad, response: response)
    }

    @objc(webView:resourceLoad:didCompleteWithError:response:)
    func webView(
        _ webView: WKWebView,
        resourceLoad: AnyObject,
        didCompleteWithError error: NSError?,
        response: URLResponse?
    ) {
        handleDidComplete(
            webView: webView,
            resourceLoad: resourceLoad,
            error: error,
            response: response
        )
    }

    @objc(webView:resourceLoad:didPerformHTTPRedirection:newRequest:)
    func webView(
        _ webView: WKWebView,
        resourceLoad: AnyObject,
        didPerformHTTPRedirection response: URLResponse,
        newRequest request: URLRequest
    ) {
        handleDidPerformHTTPRedirection(
            webView: webView,
            resourceLoad: resourceLoad,
            response: response,
            request: request
        )
    }
}

@MainActor
extension NetworkResourceLoadObserver {
    func handleDidSendRequest(webView: WKWebView, resourceLoad: AnyObject, request: URLRequest) {
        guard let loadID = resourceLoadID(from: resourceLoad) else { return }
        let resourceType = resourceTypeValue(from: resourceLoad)
        if shouldIgnore(resourceType: resourceType) {
            statesByLoadID.removeValue(forKey: loadID)
            return
        }

        var state = currentState(for: loadID, resourceLoad: resourceLoad, resourceType: resourceType)
        state.request = request
        if !state.didSendRequest {
            emitStart(for: state, resourceLoad: resourceLoad, timestamp: state.firstTimestamp)
            state.didSendRequest = true
        }
        statesByLoadID[loadID] = state
    }

    func handleDidReceiveResponse(webView: WKWebView, resourceLoad: AnyObject, response: URLResponse) {
        guard let loadID = resourceLoadID(from: resourceLoad) else { return }
        let resourceType = resourceTypeValue(from: resourceLoad)
        if shouldIgnore(resourceType: resourceType) {
            return
        }

        var state = currentState(for: loadID, resourceLoad: resourceLoad, resourceType: resourceType)
        state.response = response
        if !state.didSendRequest {
            emitStart(for: state, resourceLoad: resourceLoad, timestamp: state.firstTimestamp)
            state.didSendRequest = true
        }
        emitResponse(for: state, response: response, timestamp: eventTimestamp(from: resourceLoad) ?? Date())
        state.didReceiveResponse = true
        statesByLoadID[loadID] = state
    }

    func handleDidComplete(
        webView: WKWebView,
        resourceLoad: AnyObject,
        error: NSError?,
        response: URLResponse?
    ) {
        guard let loadID = resourceLoadID(from: resourceLoad) else { return }
        let resourceType = resourceTypeValue(from: resourceLoad)
        if shouldIgnore(resourceType: resourceType) {
            statesByLoadID.removeValue(forKey: loadID)
            return
        }

        var state = currentState(for: loadID, resourceLoad: resourceLoad, resourceType: resourceType)
        if let response {
            state.response = response
        }
        if !state.didSendRequest {
            emitStart(for: state, resourceLoad: resourceLoad, timestamp: state.firstTimestamp)
            state.didSendRequest = true
        }

        let completionTimestamp = eventTimestamp(from: resourceLoad) ?? Date()
        if let error {
            emitFailure(for: state, error: error, timestamp: completionTimestamp)
        } else {
            emitFinish(for: state, response: state.response, timestamp: completionTimestamp)
        }
        statesByLoadID.removeValue(forKey: loadID)
    }

    func handleDidPerformHTTPRedirection(
        webView: WKWebView,
        resourceLoad: AnyObject,
        response: URLResponse,
        request: URLRequest
    ) {
        guard let loadID = resourceLoadID(from: resourceLoad) else { return }
        let resourceType = resourceTypeValue(from: resourceLoad)
        if shouldIgnore(resourceType: resourceType) {
            return
        }

        var state = currentState(for: loadID, resourceLoad: resourceLoad, resourceType: resourceType)
        if !state.didSendRequest {
            emitStart(for: state, resourceLoad: resourceLoad, timestamp: state.firstTimestamp)
            state.didSendRequest = true
        }
        state.response = response
        state.request = request
        emitResponse(for: state, response: response, timestamp: eventTimestamp(from: resourceLoad) ?? Date())
        state.didReceiveResponse = true
        statesByLoadID[loadID] = state
    }
}

@MainActor
private extension NetworkResourceLoadObserver {
    private func resetState() {
        statesByLoadID.removeAll()
        nextRequestID = -1
    }

    private func currentState(for loadID: UInt64, resourceLoad: AnyObject, resourceType: Int) -> LoadState {
        if let existing = statesByLoadID[loadID] {
            return existing
        }
        let state = LoadState(
            requestID: allocateRequestID(),
            resourceType: resourceType,
            firstTimestamp: eventTimestamp(from: resourceLoad),
            didSendRequest: false,
            didReceiveResponse: false,
            request: fallbackRequest(from: resourceLoad),
            response: nil
        )
        statesByLoadID[loadID] = state
        return state
    }

    private func allocateRequestID() -> Int {
        let current = nextRequestID
        nextRequestID -= 1
        return current
    }

    private func shouldIgnore(resourceType: Int) -> Bool {
        guard !includeFetchAndXHR else {
            return false
        }
        return resourceType == ResourceType.fetch.rawValue || resourceType == ResourceType.xmlHTTPRequest.rawValue
    }

    private func emitStart(for state: LoadState, resourceLoad: AnyObject, timestamp: Date?) {
        let request = state.request ?? fallbackRequest(from: resourceLoad)
        let url = request?.url?.absoluteString ?? originalURL(from: resourceLoad)?.absoluteString ?? ""
        let method = (request?.httpMethod ?? originalHTTPMethod(from: resourceLoad) ?? "GET").uppercased()
        let headers = request?.allHTTPHeaderFields ?? [:]

        guard let event = makeEvent(
            kind: .requestWillBeSent,
            requestID: state.requestID,
            timestamp: timestamp ?? eventTimestamp(from: resourceLoad),
            url: url,
            method: method,
            statusCode: nil,
            statusText: nil,
            mimeType: nil,
            headers: headers,
            initiator: initiator(for: state.resourceType),
            encodedBodyLength: nil,
            error: nil
        ) else {
            return
        }
        applyEvent(event)
    }

    private func emitResponse(for state: LoadState, response: URLResponse, timestamp: Date?) {
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode
        let statusText = statusCode.map(HTTPURLResponse.localizedString(forStatusCode:))
        let mimeType = response.mimeType
        let headers = headerDictionary(from: httpResponse?.allHeaderFields ?? [:])

        guard let event = makeEvent(
            kind: .responseReceived,
            requestID: state.requestID,
            timestamp: timestamp,
            url: nil,
            method: nil,
            statusCode: statusCode,
            statusText: statusText,
            mimeType: mimeType,
            headers: headers,
            initiator: initiator(for: state.resourceType),
            encodedBodyLength: nil,
            error: nil
        ) else {
            return
        }
        applyEvent(event)
    }

    private func emitFinish(for state: LoadState, response: URLResponse?, timestamp: Date?) {
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode
        let statusText = statusCode.map(HTTPURLResponse.localizedString(forStatusCode:))
        let mimeType = response?.mimeType

        let encodedBodyLength: Int?
        if let expectedLength = response?.expectedContentLength,
           expectedLength > 0,
           expectedLength <= Int64(Int.max) {
            encodedBodyLength = Int(expectedLength)
        } else {
            encodedBodyLength = nil
        }

        guard let event = makeEvent(
            kind: .loadingFinished,
            requestID: state.requestID,
            timestamp: timestamp,
            url: nil,
            method: nil,
            statusCode: statusCode,
            statusText: statusText,
            mimeType: mimeType,
            headers: [:],
            initiator: initiator(for: state.resourceType),
            encodedBodyLength: encodedBodyLength,
            error: nil
        ) else {
            return
        }
        applyEvent(event)
    }

    private func emitFailure(for state: LoadState, error: NSError, timestamp: Date?) {
        guard let event = makeEvent(
            kind: .loadingFailed,
            requestID: state.requestID,
            timestamp: timestamp,
            url: nil,
            method: nil,
            statusCode: nil,
            statusText: nil,
            mimeType: nil,
            headers: [:],
            initiator: initiator(for: state.resourceType),
            encodedBodyLength: nil,
            error: error
        ) else {
            return
        }
        applyEvent(event)
    }

    private func makeEvent(
        kind: HTTPNetworkEventKind,
        requestID: Int,
        timestamp: Date?,
        url: String?,
        method: String?,
        statusCode: Int?,
        statusText: String?,
        mimeType: String?,
        headers: [String: String],
        initiator: String,
        encodedBodyLength: Int?,
        error: NSError?
    ) -> HTTPNetworkEvent? {
        let payload = NetworkEventPayload(
            kind: kind.rawValue,
            requestId: requestID,
            time: makeTimePayload(from: timestamp),
            startTime: nil,
            endTime: nil,
            url: url,
            method: method,
            status: statusCode,
            statusText: statusText,
            mimeType: mimeType,
            headers: headers,
            initiator: initiator,
            body: nil,
            bodySize: nil,
            encodedBodyLength: encodedBodyLength,
            decodedBodySize: nil,
            error: error.map(makeErrorPayload(from:))
        )
        return HTTPNetworkEvent(payload: payload, sessionID: sessionID)
    }

    private func makeErrorPayload(from error: NSError) -> NetworkErrorPayload {
        let canceled = error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
        let timeout = error.domain == NSURLErrorDomain && error.code == NSURLErrorTimedOut
        return NetworkErrorPayload(
            domain: "native",
            code: String(error.code),
            message: error.localizedDescription,
            isCanceled: canceled ? true : nil,
            isTimeout: timeout ? true : nil
        )
    }

    private func makeTimePayload(from timestamp: Date?) -> NetworkTimePayload {
        let resolvedTimestamp = timestamp ?? Date()
        let wallMs = resolvedTimestamp.timeIntervalSince1970 * 1000.0
        let nowWallMs = Date().timeIntervalSince1970 * 1000.0
        let nowMonotonicMs = ProcessInfo.processInfo.systemUptime * 1000.0
        let candidateMonotonicMs = nowMonotonicMs - (nowWallMs - wallMs)
        let monotonicMs = candidateMonotonicMs.isFinite ? candidateMonotonicMs : nowMonotonicMs
        return NetworkTimePayload(monotonicMs: monotonicMs, wallMs: wallMs)
    }

    private func headerDictionary(from rawHeaders: [AnyHashable: Any]) -> [String: String] {
        var headers: [String: String] = [:]
        headers.reserveCapacity(rawHeaders.count)
        for (key, value) in rawHeaders {
            headers[String(describing: key)] = String(describing: value)
        }
        return headers
    }

    private func initiator(for resourceType: Int) -> String {
        switch ResourceType(rawValue: resourceType) {
        case .document:
            return "document"
        case .image:
            return "img"
        case .script:
            return "script"
        case .stylesheet:
            return "style"
        case .font:
            return "font"
        case .media:
            return "media"
        case .object:
            return "object"
        case .ping:
            return "ping"
        case .applicationManifest:
            return "manifest"
        case .beacon:
            return "beacon"
        default:
            return "resource"
        }
    }

    private func resourceLoadID(from resourceLoad: AnyObject) -> UInt64? {
        guard let object = resourceLoad as? NSObject else {
            return nil
        }
        if let number = object.value(forKey: "resourceLoadID") as? NSNumber {
            return number.uint64Value
        }
        if let value = object.value(forKey: "resourceLoadID") as? UInt64 {
            return value
        }
        return nil
    }

    private func resourceTypeValue(from resourceLoad: AnyObject) -> Int {
        guard let object = resourceLoad as? NSObject else {
            return ResourceType.other.rawValue
        }
        if let number = object.value(forKey: "resourceType") as? NSNumber {
            return number.intValue
        }
        if let value = object.value(forKey: "resourceType") as? Int {
            return value
        }
        return ResourceType.other.rawValue
    }

    private func eventTimestamp(from resourceLoad: AnyObject) -> Date? {
        guard let object = resourceLoad as? NSObject else {
            return nil
        }
        if let date = object.value(forKey: "eventTimestamp") as? Date {
            return date
        }
        if let date = object.value(forKey: "eventTimestamp") as? NSDate {
            return date as Date
        }
        return nil
    }

    private func originalURL(from resourceLoad: AnyObject) -> URL? {
        guard let object = resourceLoad as? NSObject else {
            return nil
        }
        if let url = object.value(forKey: "originalURL") as? URL {
            return url
        }
        if let url = object.value(forKey: "originalURL") as? NSURL {
            return url as URL
        }
        return nil
    }

    private func originalHTTPMethod(from resourceLoad: AnyObject) -> String? {
        guard let object = resourceLoad as? NSObject else {
            return nil
        }
        if let method = object.value(forKey: "originalHTTPMethod") as? String {
            return method
        }
        if let method = object.value(forKey: "originalHTTPMethod") as? NSString {
            return method as String
        }
        return nil
    }

    private func fallbackRequest(from resourceLoad: AnyObject) -> URLRequest? {
        guard let url = originalURL(from: resourceLoad) else {
            return nil
        }
        var request = URLRequest(url: url)
        let method = (originalHTTPMethod(from: resourceLoad) ?? "GET").uppercased()
        request.httpMethod = method
        return request
    }
}
