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
    public enum Phase: Equatable, Sendable {
        case available
        case fetching
        case loaded
        case failed(WebInspectorProxyError)
    }

    public private(set) var phase: Phase
    public private(set) var text: String?
    public private(set) var isBase64Encoded: Bool

    init(phase: Phase = .available, text: String? = nil, isBase64Encoded: Bool = false) {
        self.phase = phase
        self.text = text
        self.isBase64Encoded = isBase64Encoded
    }

    func markFetching() {
        phase = .fetching
    }

    func load(_ body: Network.Body) {
        text = body.data
        isBase64Encoded = body.base64Encoded
        phase = .loaded
    }

    func fail(_ error: WebInspectorProxyError) {
        phase = .failed(error)
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

    public let id: ID
    public private(set) var url: String
    public private(set) var method: String
    public private(set) var resourceType: Network.ResourceType?
    public private(set) var state: State
    public private(set) var status: Int?
    public private(set) var mimeType: String?
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
        mimeType = nil
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
        responseBody = NetworkBody()
        self.modelContext = modelContext
        currentRequest = request
    }

    public func fetchResponseBody(isolation: isolated (any Actor) = #isolation) async {
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
        mimeType = nil
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
        mimeType = nil
        sourceMapURL = nil
        responseHeaders = [:]
        requestSentTimestamp = timestamp
        responseReceivedTimestamp = nil
        lastDataReceivedTimestamp = nil
        finishedOrFailedTimestamp = nil
        decodedDataLength = 0
        encodedDataLength = 0
        metrics = nil
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
        mimeType = response.mimeType
        responseHeaders = response.headers
        if let requestHeaders = response.requestHeaders {
            self.requestHeaders = requestHeaders
        }
        if let timestamp {
            responseReceivedTimestamp = timestamp
        }
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
        mimeType = response.mimeType
        sourceMapURL = nil
        responseHeaders = response.headers
        if let requestHeaders = response.requestHeaders {
            self.requestHeaders = requestHeaders
        }
        currentRequest = Network.Request(id: proxyID, url: url, method: method, headers: requestHeaders)
        requestSentTimestamp = timestamp
        responseReceivedTimestamp = timestamp
        lastDataReceivedTimestamp = nil
        finishedOrFailedTimestamp = timestamp
        decodedDataLength = 0
        encodedDataLength = 0
        metrics = nil
        redirects = []
        responseBody = NetworkBody()
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
}
