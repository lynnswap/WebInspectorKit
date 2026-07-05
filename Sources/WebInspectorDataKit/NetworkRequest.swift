import Foundation
import Observation
import WebInspectorProxyKit

public struct NetworkRequestSnapshot: Equatable, Sendable {
    public let url: String
    public let method: String
    public let headers: [String: String]
    public let postData: String?
    public let referrerPolicy: String?
    public let integrity: String?

    public init(
        url: String,
        method: String,
        headers: [String: String] = [:],
        postData: String? = nil,
        referrerPolicy: String? = nil,
        integrity: String? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.postData = postData
        self.referrerPolicy = referrerPolicy
        self.integrity = integrity
    }

    init(_ request: Network.Request) {
        self.init(
            url: request.url,
            method: request.method,
            headers: request.headers,
            postData: request.postData,
            referrerPolicy: request.referrerPolicy?.rawValue,
            integrity: request.integrity
        )
    }
}

public struct NetworkResponseSnapshot: Equatable, Sendable {
    public let url: String?
    public let status: Int?
    public let statusText: String?
    public let mimeType: String?
    public let headers: [String: String]
    public let source: String?
    public let requestHeaders: [String: String]?

    public init(
        url: String? = nil,
        status: Int? = nil,
        statusText: String? = nil,
        mimeType: String? = nil,
        headers: [String: String] = [:],
        source: String? = nil,
        requestHeaders: [String: String]? = nil
    ) {
        self.url = url
        self.status = status
        self.statusText = statusText
        self.mimeType = mimeType
        self.headers = headers
        self.source = source
        self.requestHeaders = requestHeaders
    }

    init(_ response: Network.Response) {
        self.init(
            url: response.url,
            status: response.status,
            statusText: response.statusText,
            mimeType: response.mimeType,
            headers: response.headers,
            source: response.source?.rawValue,
            requestHeaders: response.requestHeaders
        )
    }
}

public struct RedirectHop: Equatable, Sendable {
    public let request: NetworkRequestSnapshot
    public let response: NetworkResponseSnapshot
    public let timestamp: Double

    public init(
        request: NetworkRequestSnapshot,
        response: NetworkResponseSnapshot,
        timestamp: Double
    ) {
        self.request = request
        self.response = response
        self.timestamp = timestamp
    }

    init(request: Network.Request, response: Network.Response, timestamp: Double) {
        self.init(
            request: NetworkRequestSnapshot(request),
            response: NetworkResponseSnapshot(response),
            timestamp: timestamp
        )
    }
}

@Observable
public final class WebSocketState {
    public enum ReadyState: Equatable, Sendable {
        case connecting
        case open
        case closed
    }

    public enum FrameDirection: Equatable, Sendable {
        case sent
        case received
        case error(String)
    }

    public struct Frame: Equatable, Sendable {
        public let direction: FrameDirection
        public let opcode: Int?
        public let mask: Bool?
        public let payloadData: String?
        public let payloadLength: Int?
        public let errorMessage: String?
        public let timestamp: Double

        public init(
            direction: FrameDirection,
            opcode: Int? = nil,
            mask: Bool? = nil,
            payloadData: String? = nil,
            payloadLength: Int? = nil,
            errorMessage: String? = nil,
            timestamp: Double
        ) {
            self.direction = direction
            self.opcode = opcode
            self.mask = mask
            self.payloadData = payloadData
            self.payloadLength = payloadLength
            self.errorMessage = errorMessage
            self.timestamp = timestamp
        }
    }

    public private(set) var readyState: ReadyState
    public private(set) var handshakeRequest: NetworkRequestSnapshot?
    public private(set) var handshakeResponse: NetworkResponseSnapshot?
    public private(set) var frames: [Frame]

    init(readyState: ReadyState = .connecting) {
        self.readyState = readyState
        handshakeRequest = nil
        handshakeResponse = nil
        frames = []
    }

    func markConnecting() {
        readyState = .connecting
    }

    func markOpen() {
        readyState = .open
    }

    func markClosed() {
        readyState = .closed
    }

    func applyHandshakeRequest(_ request: Network.Request) {
        handshakeRequest = NetworkRequestSnapshot(request)
        readyState = .connecting
    }

    func applyHandshakeResponse(_ response: Network.Response) {
        handshakeResponse = NetworkResponseSnapshot(response)
        readyState = .open
    }

    func appendFrame(
        _ frame: Network.WebSocketFrame,
        direction: FrameDirection,
        timestamp: Double
    ) {
        frames.append(Frame(
            direction: direction,
            opcode: frame.opcode,
            mask: frame.mask,
            payloadData: frame.payloadData,
            payloadLength: frame.payloadLength,
            timestamp: timestamp
        ))
    }

    func appendError(_ message: String, timestamp: Double) {
        frames.append(Frame(
            direction: .error(message),
            errorMessage: message,
            timestamp: timestamp
        ))
    }
}

@Observable
public final class NetworkBody {
    public enum Role: CaseIterable, Hashable, Sendable {
        case request
        case response
    }

    public enum Kind: Hashable, Sendable {
        case text
        case form
        case binary
    }

    public enum SyntaxKind: Hashable, Sendable {
        case plainText
        case json
        case html
        case xml
        case css
        case javascript
    }

    public enum Phase: Equatable, Sendable {
        case available
        case fetching
        case loaded
        case failed(WebInspectorProxyError)
    }

    struct Payload: Equatable, Sendable {
        var body: String
        var base64Encoded: Bool
        var size: Int?
        var isTruncated: Bool

        init(
            body: String,
            base64Encoded: Bool,
            size: Int? = nil,
            isTruncated: Bool = false
        ) {
            self.body = body
            self.base64Encoded = base64Encoded
            self.size = size
            self.isTruncated = isTruncated
        }
    }

    public let role: Role
    public private(set) var kind: Kind {
        didSet {
            invalidateTextRepresentation()
        }
    }
    public private(set) var phase: Phase
    public private(set) var full: String? {
        didSet {
            text = full
            invalidateTextRepresentation()
        }
    }
    public private(set) var text: String?
    public private(set) var size: Int?
    public private(set) var isBase64Encoded: Bool
    public private(set) var isTruncated: Bool
    public private(set) var sourceSyntaxKind: SyntaxKind {
        didSet {
            invalidateTextRepresentation()
        }
    }
    public private(set) var textRepresentation: String?
    public private(set) var textRepresentationSyntaxKind: SyntaxKind
    @ObservationIgnored private var isBatchingTextRepresentationInvalidation: Bool
    @ObservationIgnored private var needsTextRepresentationInvalidation: Bool

    package init(
        role: Role = .response,
        kind: Kind = .text,
        full: String? = nil,
        size: Int? = nil,
        isBase64Encoded: Bool = false,
        isTruncated: Bool = false,
        sourceSyntaxKind: SyntaxKind = .plainText,
        phase: Phase? = nil
    ) {
        self.role = role
        self.kind = kind
        self.phase = phase ?? (full == nil ? .available : .loaded)
        self.full = full
        text = full
        self.size = size ?? full?.utf8.count
        self.isBase64Encoded = isBase64Encoded
        self.isTruncated = isTruncated
        self.sourceSyntaxKind = sourceSyntaxKind
        textRepresentation = nil
        textRepresentationSyntaxKind = .plainText
        isBatchingTextRepresentationInvalidation = false
        needsTextRepresentationInvalidation = false
        refreshTextRepresentation()
    }

    var needsFetch: Bool {
        switch phase {
        case .available:
            full == nil
        case .fetching, .loaded, .failed:
            false
        }
    }

    func updateHints(kind: Kind, sourceSyntaxKind: SyntaxKind) {
        withTextRepresentationInvalidationBatch {
            self.kind = kind
            self.sourceSyntaxKind = sourceSyntaxKind
        }
    }

    func markFetching() {
        phase = .fetching
    }

    func load(_ body: Network.Body) {
        load(Payload(body: body.data, base64Encoded: body.base64Encoded))
    }

    func load(_ payload: Payload) {
        withTextRepresentationInvalidationBatch {
            full = payload.body
            isBase64Encoded = payload.base64Encoded
            isTruncated = payload.isTruncated
        }
        size = payload.size ?? payload.body.utf8.count
        phase = .loaded
    }

    func fail(_ error: WebInspectorProxyError) {
        phase = .failed(error)
    }

    static func makeRequestBody(for request: Network.Request) -> NetworkBody? {
        guard let postData = request.postData else {
            return nil
        }
        let hints = bodyHints(
            mimeType: nil,
            headers: request.headers,
            url: request.url,
            role: .request
        )
        return NetworkBody(
            role: .request,
            kind: hints.kind,
            full: postData,
            size: postData.utf8.count,
            sourceSyntaxKind: hints.syntaxKind,
            phase: .loaded
        )
    }

    static func makeResponseBody(for response: Network.Response, fallbackURL: String = "") -> NetworkBody {
        let hints = bodyHints(
            mimeType: response.mimeType,
            headers: response.headers,
            url: response.url ?? fallbackURL,
            role: .response
        )
        return NetworkBody(
            role: .response,
            kind: hints.kind,
            sourceSyntaxKind: hints.syntaxKind,
            phase: .available
        )
    }

    static func bodyHints(
        mimeType: String?,
        headers: [String: String],
        url: String,
        role: Role
    ) -> (kind: Kind, syntaxKind: SyntaxKind) {
        let contentType = (mimeType ?? headerValue(named: "content-type", in: headers) ?? "")
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""

        if role == .request && contentType == "application/x-www-form-urlencoded" {
            return (.form, .plainText)
        }
        if contentType.contains("json") {
            return (.text, .json)
        }
        if contentType == "text/html" || contentType == "application/xhtml+xml" {
            return (.text, .html)
        }
        if contentType == "text/xml" || contentType == "application/xml" || contentType.hasSuffix("+xml") {
            return (.text, .xml)
        }
        if contentType == "text/css" {
            return (.text, .css)
        }
        if contentType == "text/javascript" || contentType == "application/javascript" || contentType == "application/ecmascript" {
            return (.text, .javascript)
        }
        if contentType.hasPrefix("text/") || contentType.isEmpty {
            return (.text, syntaxKind(forPathExtensionIn: url))
        }
        return (.binary, .plainText)
    }

    private static func headerValue(named name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func syntaxKind(forPathExtensionIn url: String) -> SyntaxKind {
        switch URL(string: url)?.pathExtension.lowercased() {
        case "json":
            .json
        case "html", "htm":
            .html
        case "xml", "svg":
            .xml
        case "css":
            .css
        case "js", "mjs", "cjs":
            .javascript
        default:
            .plainText
        }
    }

    private func withTextRepresentationInvalidationBatch(_ updates: () -> Void) {
        isBatchingTextRepresentationInvalidation = true
        updates()
        isBatchingTextRepresentationInvalidation = false

        if needsTextRepresentationInvalidation {
            needsTextRepresentationInvalidation = false
            refreshTextRepresentation()
        }
    }

    private func invalidateTextRepresentation() {
        guard isBatchingTextRepresentationInvalidation == false else {
            needsTextRepresentationInvalidation = true
            return
        }
        refreshTextRepresentation()
    }

    private func refreshTextRepresentation() {
        let contentText = decodedContentText()
        let formText = kind == .form ? formattedURLEncodedFormText(from: contentText) : nil
        let displayText = formText ?? (kind == .binary ? nil : contentText)
        let syntaxKind: SyntaxKind = if kind == .binary || kind == .form {
            .plainText
        } else {
            sourceSyntaxKind
        }

        if textRepresentation != displayText {
            textRepresentation = displayText
        }
        if textRepresentationSyntaxKind != syntaxKind {
            textRepresentationSyntaxKind = syntaxKind
        }
    }

    private func decodedContentText() -> String? {
        guard let full else {
            return nil
        }
        guard kind != .binary else {
            return isBase64Encoded ? nil : full
        }
        guard isBase64Encoded else {
            return full
        }
        guard let data = Data(base64Encoded: full) else {
            return nil
        }
        if let decoded = String(data: data, encoding: .utf8) {
            return decoded
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func formattedURLEncodedFormText(from text: String?) -> String? {
        guard let text, text.isEmpty == false, text.contains("=") else {
            return nil
        }

        var lines: [String] = []
        for pair in text.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.isEmpty == false else {
                continue
            }
            guard let name = decodeFormComponent(String(parts[0])) else {
                return nil
            }
            let value: String
            if parts.count > 1 {
                guard let decodedValue = decodeFormComponent(String(parts[1])) else {
                    return nil
                }
                value = decodedValue
            } else {
                value = ""
            }
            lines.append("\(name)=\(value)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func decodeFormComponent(_ component: String) -> String? {
        component
            .replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding
    }
}

@Observable
public final class NetworkRequest: WebInspectorFetchableModel {
    public struct ID: Hashable, Sendable {
        let proxyID: Network.Request.ID

        init(_ proxyID: Network.Request.ID) {
            self.proxyID = proxyID
        }
    }

    public enum State: Equatable, Sendable {
        case pending
        case responded
        case finished
        case failed(errorText: String, canceled: Bool)
    }

    public enum ResourceCategory: String, Codable, CaseIterable, Sendable, Hashable {
        case document
        case stylesheet
        case script
        case image
        case font
        case xhrFetch
        case media
        case webSocket
        case other
    }

    public let id: ID
    public private(set) var url: String
    public private(set) var method: String
    public private(set) var resourceType: Network.ResourceType?
    public private(set) var state: State
    public private(set) var status: Int?
    public private(set) var statusText: String?
    public private(set) var responseURL: String?
    public private(set) var mimeType: String?
    public private(set) var responseSource: String?
    public private(set) var sourceMapURL: String?
    public private(set) var requestHeaders: [String: String]
    public private(set) var responseHeaders: [String: String]
    public private(set) var requestSentTimestamp: Double?
    public private(set) var responseReceivedTimestamp: Double?
    public private(set) var lastDataReceivedTimestamp: Double?
    public private(set) var finishedOrFailedTimestamp: Double?
    public private(set) var decodedDataLength: Int
    public private(set) var encodedDataLength: Int
    public private(set) var metrics: Network.Metrics?
    public private(set) var redirects: [RedirectHop]
    public private(set) var webSocket: WebSocketState?
    public private(set) var requestBody: NetworkBody?
    public private(set) var responseBody: NetworkBody

    @ObservationIgnored weak var modelContext: WebInspectorContext?
    @ObservationIgnored private var currentRequest: Network.Request

    var proxyID: Network.Request.ID {
        id.proxyID
    }

    var isActive: Bool {
        switch state {
        case .pending,
             .responded:
            return true
        case .finished,
             .failed:
            return false
        }
    }

    init(
        request: Network.Request,
        resourceType: Network.ResourceType?,
        timestamp: Double?,
        modelContext: WebInspectorContext
    ) {
        id = ID(request.id)
        url = request.url
        method = request.method
        self.resourceType = resourceType
        state = .pending
        status = nil
        statusText = nil
        responseURL = nil
        mimeType = nil
        responseSource = nil
        sourceMapURL = nil
        requestHeaders = request.headers
        responseHeaders = [:]
        requestSentTimestamp = timestamp
        responseReceivedTimestamp = nil
        lastDataReceivedTimestamp = nil
        finishedOrFailedTimestamp = nil
        decodedDataLength = 0
        encodedDataLength = 0
        metrics = nil
        redirects = []
        webSocket = resourceType == .webSocket ? WebSocketState() : nil
        requestBody = NetworkBody.makeRequestBody(for: request)
        responseBody = NetworkBody()
        self.modelContext = modelContext
        currentRequest = request
    }

    public var canFetchResponseBody: Bool {
        guard state == .finished else {
            return false
        }
        return responseBody.needsFetch
    }

    public var hasResponse: Bool {
        responseReceivedTimestamp != nil
            || status != nil
            || statusText != nil
            || responseURL != nil
            || mimeType != nil
            || responseHeaders.isEmpty == false
            || responseSource != nil
    }

    public var hasResponseBody: Bool {
        hasResponse && resourceType != .webSocket
    }

    public var resourceCategory: ResourceCategory {
        Self.resourceCategory(resourceType: resourceType, mimeType: mimeType, url: responseURL ?? url)
    }

    public var searchableText: String {
        Self.uniqueNonEmpty([
            url,
            responseURL,
            Self.urlSearchText(url),
            responseURL.map(Self.urlSearchText),
            method,
            status.map(String.init),
            statusText,
            mimeType,
            resourceType?.rawValue,
            resourceCategory.rawValue,
        ])
        .joined(separator: "\n")
    }

    public var statusCode: Int? {
        status
    }

    public func fetchResponseBody(isolation: isolated (any Actor) = #isolation) async {
        guard canFetchResponseBody else {
            return
        }
        responseBody.markFetching()
        guard let modelContext else {
            responseBody.fail(.disconnected("NetworkRequest is not registered in a WebInspectorContext."))
            return
        }
        await modelContext.fetchResponseBody(for: self, isolation: isolation)
    }

    func applyRequestWillBeSent(
        request: Network.Request,
        resourceType: Network.ResourceType?,
        timestamp: Double
    ) {
        currentRequest = request
        url = request.url
        method = request.method
        self.resourceType = resourceType
        requestHeaders = request.headers
        status = nil
        statusText = nil
        responseURL = nil
        mimeType = nil
        responseSource = nil
        sourceMapURL = nil
        responseHeaders = [:]
        requestSentTimestamp = timestamp
        responseReceivedTimestamp = nil
        lastDataReceivedTimestamp = nil
        finishedOrFailedTimestamp = nil
        decodedDataLength = 0
        encodedDataLength = 0
        metrics = nil
        redirects = []
        webSocket = resourceType == .webSocket ? WebSocketState() : nil
        requestBody = NetworkBody.makeRequestBody(for: request)
        responseBody = NetworkBody()
        state = .pending
    }

    func applyRedirect(
        to request: Network.Request,
        redirectResponse: Network.Response,
        timestamp: Double,
        resourceType: Network.ResourceType?
    ) {
        redirects.append(RedirectHop(
            request: currentRequest,
            response: redirectResponse,
            timestamp: timestamp
        ))
        currentRequest = request
        url = request.url
        method = request.method
        let resolvedResourceType = resourceType ?? self.resourceType
        self.resourceType = resolvedResourceType
        webSocket = resolvedResourceType == .webSocket ? webSocket ?? WebSocketState() : nil
        requestHeaders = request.headers
        status = nil
        statusText = nil
        responseURL = nil
        mimeType = nil
        responseSource = nil
        sourceMapURL = nil
        responseHeaders = [:]
        requestSentTimestamp = timestamp
        responseReceivedTimestamp = nil
        lastDataReceivedTimestamp = nil
        finishedOrFailedTimestamp = nil
        decodedDataLength = 0
        encodedDataLength = 0
        metrics = nil
        requestBody = NetworkBody.makeRequestBody(for: request)
        responseBody = NetworkBody()
        state = .pending
    }

    func applyResponse(
        _ response: Network.Response,
        resourceType: Network.ResourceType,
        timestamp: Double?
    ) {
        self.resourceType = resourceType
        if resourceType == .webSocket {
            _ = ensureWebSocketState()
        } else {
            webSocket = nil
        }
        status = response.status
        statusText = response.statusText
        responseURL = response.url
        mimeType = response.mimeType
        responseSource = response.source?.rawValue
        responseHeaders = response.headers
        if let requestHeaders = response.requestHeaders {
            self.requestHeaders = requestHeaders
            currentRequest = requestWithHeaders(requestHeaders)
            refreshRequestBodyHints()
        }
        if let timestamp {
            responseReceivedTimestamp = timestamp
        }
        responseBody = NetworkBody.makeResponseBody(for: response, fallbackURL: currentRequest.url)
        state = .responded
    }

    func applyDataReceived(dataLength: Int, encodedDataLength: Int, timestamp: Double) {
        decodedDataLength += max(0, dataLength)
        self.encodedDataLength += max(0, encodedDataLength)
        lastDataReceivedTimestamp = timestamp
        if state == .pending {
            state = .responded
        }
    }

    func finish(timestamp: Double, sourceMapURL: String?, metrics: Network.Metrics?) {
        self.sourceMapURL = sourceMapURL
        self.metrics = metrics
        if let encodedDataLength = metrics?.encodedDataLength {
            self.encodedDataLength = max(0, encodedDataLength)
        }
        if let decodedBodyLength = metrics?.decodedBodyLength {
            decodedDataLength = max(0, decodedBodyLength)
        }
        finishedOrFailedTimestamp = timestamp
        state = .finished
    }

    func fail(errorText: String, canceled: Bool, timestamp: Double) {
        finishedOrFailedTimestamp = timestamp
        state = .failed(errorText: errorText, canceled: canceled)
    }

    func applyMemoryCache(response: Network.Response, timestamp: Double) {
        if let url = response.url {
            self.url = url
        }
        resourceType = nil
        webSocket = nil
        status = response.status
        statusText = response.statusText
        responseURL = response.url
        mimeType = response.mimeType
        responseSource = response.source?.rawValue
        sourceMapURL = nil
        responseHeaders = response.headers
        if let requestHeaders = response.requestHeaders {
            self.requestHeaders = requestHeaders
        }
        currentRequest = requestWithHeaders(requestHeaders)
        requestSentTimestamp = timestamp
        responseReceivedTimestamp = timestamp
        lastDataReceivedTimestamp = nil
        finishedOrFailedTimestamp = timestamp
        decodedDataLength = 0
        encodedDataLength = 0
        metrics = nil
        redirects = []
        requestBody = NetworkBody.makeRequestBody(for: currentRequest)
        responseBody = NetworkBody.makeResponseBody(for: response, fallbackURL: currentRequest.url)
        state = .finished
    }

    func finishResponseBodyFetch(result: Result<Network.Body, WebInspectorProxyError>) {
        switch result {
        case let .success(body):
            responseBody.load(body)
        case let .failure(error):
            responseBody.fail(error)
        }
    }

    func applyWebSocketCreated(url: String) {
        self.url = url
        resourceType = .webSocket
        _ = ensureWebSocketState()
    }

    func applyWebSocketHandshakeRequest(_ request: Network.Request, timestamp: Double?) {
        currentRequest = request
        url = request.url
        method = request.method
        resourceType = .webSocket
        requestHeaders = request.headers
        requestBody = NetworkBody.makeRequestBody(for: request)
        responseBody = NetworkBody()
        status = nil
        statusText = nil
        responseURL = nil
        mimeType = nil
        responseSource = nil
        if let timestamp {
            requestSentTimestamp = timestamp
        }
        state = .pending
        ensureWebSocketState().applyHandshakeRequest(request)
    }

    func applyWebSocketHandshakeResponse(_ response: Network.Response, timestamp: Double?) {
        applyResponse(response, resourceType: .webSocket, timestamp: timestamp)
        ensureWebSocketState().applyHandshakeResponse(response)
    }

    func appendWebSocketFrame(
        _ frame: Network.WebSocketFrame,
        direction: WebSocketState.FrameDirection,
        timestamp: Double
    ) {
        decodedDataLength += max(0, frame.payloadLength)
        lastDataReceivedTimestamp = timestamp
        ensureWebSocketState().appendFrame(frame, direction: direction, timestamp: timestamp)
    }

    func appendWebSocketError(_ message: String, timestamp: Double) {
        lastDataReceivedTimestamp = timestamp
        ensureWebSocketState().appendError(message, timestamp: timestamp)
    }

    func closeWebSocket(timestamp: Double) {
        ensureWebSocketState().markClosed()
        finishedOrFailedTimestamp = timestamp
        state = .finished
    }

    private func ensureWebSocketState() -> WebSocketState {
        if let webSocket {
            return webSocket
        }
        let webSocket = WebSocketState()
        self.webSocket = webSocket
        return webSocket
    }

    private func requestWithHeaders(_ headers: [String: String]) -> Network.Request {
        Network.Request(
            id: currentRequest.id,
            url: currentRequest.url,
            method: currentRequest.method,
            headers: headers,
            postData: currentRequest.postData,
            referrerPolicy: currentRequest.referrerPolicy,
            integrity: currentRequest.integrity
        )
    }

    private func refreshRequestBodyHints() {
        guard let requestBody else {
            self.requestBody = NetworkBody.makeRequestBody(for: currentRequest)
            return
        }
        let hints = NetworkBody.bodyHints(
            mimeType: nil,
            headers: currentRequest.headers,
            url: currentRequest.url,
            role: .request
        )
        requestBody.updateHints(kind: hints.kind, sourceSyntaxKind: hints.syntaxKind)
    }

    private static func resourceCategory(
        resourceType: Network.ResourceType?,
        mimeType: String?,
        url: String
    ) -> ResourceCategory {
        if let resourceType {
            switch resourceType.rawValue.lowercased() {
            case "document":
                return .document
            case "stylesheet":
                return .stylesheet
            case "script":
                return .script
            case "image":
                return .image
            case "font":
                return .font
            case "xhr", "fetch", "ping", "beacon", "eventsource":
                return .xhrFetch
            case "media":
                return .media
            case "websocket":
                return .webSocket
            default:
                break
            }
        }

        let normalizedMIMEType = normalizedMIMEType(mimeType)
        let pathExtension = pathExtension(in: url)
        if normalizedMIMEType == "text/css" || pathExtension == "css" {
            return .stylesheet
        }
        if normalizedMIMEType.contains("javascript") || ["js", "mjs", "cjs"].contains(pathExtension) {
            return .script
        }
        if normalizedMIMEType.hasPrefix("image/") {
            return .image
        }
        if normalizedMIMEType.hasPrefix("font/") || ["woff", "woff2", "ttf", "otf"].contains(pathExtension) {
            return .font
        }
        if normalizedMIMEType.hasPrefix("audio/")
            || normalizedMIMEType.hasPrefix("video/")
            || ["mp3", "mp4", "m4a", "mov", "webm", "m3u8"].contains(pathExtension) {
            return .media
        }
        if normalizedMIMEType.contains("html") {
            return .document
        }
        return .other
    }

    private static func normalizedMIMEType(_ mimeType: String?) -> String {
        mimeType?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static func urlSearchText(_ rawURL: String) -> String {
        guard rawURL.range(of: "data:", options: [.anchored, .caseInsensitive]) == nil,
              let components = URLComponents(string: rawURL, encodingInvalidCharacters: false)
                ?? URLComponents(string: rawURL, encodingInvalidCharacters: true) else {
            return rawURL
        }
        return uniqueNonEmpty([
            components.host,
            components.percentEncodedPath.removingPercentEncoding,
            pathExtension(in: rawURL),
        ])
        .joined(separator: "\n")
    }

    private static func pathExtension(in rawURL: String) -> String {
        guard rawURL.range(of: "data:", options: [.anchored, .caseInsensitive]) == nil else {
            return ""
        }
        if let components = URLComponents(string: rawURL, encodingInvalidCharacters: false)
            ?? URLComponents(string: rawURL, encodingInvalidCharacters: true) {
            let path = components.percentEncodedPath.removingPercentEncoding ?? components.percentEncodedPath
            return URL(fileURLWithPath: path).pathExtension.lowercased()
        }
        return URL(fileURLWithPath: rawURL).pathExtension.lowercased()
    }

    private static func uniqueNonEmpty(_ values: [String?]) -> [String] {
        var seen = Set<String>()
        var results: [String] = []
        for value in values {
            guard let value else {
                continue
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false, seen.insert(trimmed).inserted else {
                continue
            }
            results.append(trimmed)
        }
        return results
    }
}
