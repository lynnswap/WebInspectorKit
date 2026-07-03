import Foundation
import Observation
import WebViewProxyKit

public protocol WebViewFetchableModel: AnyObject {}

public struct RedirectHop: Sendable {
    public let request: Network.Request
    public let response: Network.Response
    public let timestamp: Double

    public init(request: Network.Request, response: Network.Response, timestamp: Double) {
        self.request = request
        self.response = response
        self.timestamp = timestamp
    }
}

@MainActor
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
    public private(set) var handshakeRequest: Network.Request?
    public private(set) var handshakeResponse: Network.Response?
    public private(set) var frames: [Frame]

    package init(readyState: ReadyState = .connecting) {
        self.readyState = readyState
        handshakeRequest = nil
        handshakeResponse = nil
        frames = []
    }

    package func markConnecting() {
        readyState = .connecting
    }

    package func markOpen() {
        readyState = .open
    }

    package func markClosed() {
        readyState = .closed
    }

    package func applyHandshakeRequest(_ request: Network.Request) {
        handshakeRequest = request
        readyState = .connecting
    }

    package func applyHandshakeResponse(_ response: Network.Response) {
        handshakeResponse = response
        readyState = .open
    }

    package func appendFrame(
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

    package func appendError(_ message: String, timestamp: Double) {
        frames.append(Frame(
            direction: .error(message),
            errorMessage: message,
            timestamp: timestamp
        ))
    }
}

@MainActor
@Observable
public final class NetworkBody {
    public enum Phase: Equatable, Sendable {
        case available
        case fetching
        case loaded
        case failed(WebViewProxyError)
    }

    public private(set) var phase: Phase
    public private(set) var text: String?
    public private(set) var isBase64Encoded: Bool

    package init(phase: Phase = .available, text: String? = nil, isBase64Encoded: Bool = false) {
        self.phase = phase
        self.text = text
        self.isBase64Encoded = isBase64Encoded
    }

    package func markFetching() {
        phase = .fetching
    }

    package func load(_ body: Network.Body) {
        text = body.data
        isBase64Encoded = body.base64Encoded
        phase = .loaded
    }

    package func fail(_ error: WebViewProxyError) {
        phase = .failed(error)
    }
}

@MainActor
@Observable
public final class NetworkRequest: Identifiable, WebViewFetchableModel {
    public struct ID: Hashable, Sendable {
        package let proxyID: Network.Request.ID

        package init(_ proxyID: Network.Request.ID) {
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

    @ObservationIgnored package weak var modelContext: WebViewModelContext?
    @ObservationIgnored private var currentRequest: Network.Request

    package var proxyID: Network.Request.ID {
        id.proxyID
    }

    package var isActive: Bool {
        switch state {
        case .pending,
             .responded:
            return true
        case .finished,
             .failed:
            return false
        }
    }

    package init(
        request: Network.Request,
        resourceType: Network.ResourceType?,
        timestamp: Double?,
        modelContext: WebViewModelContext
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

    public func fetchResponseBody() async {
        responseBody.markFetching()
        guard let modelContext else {
            responseBody.fail(.disconnected("NetworkRequest is not registered in a WebViewModelContext."))
            return
        }
        await modelContext.fetchResponseBody(for: self)
    }

    package func applyRequestWillBeSent(
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

    package func applyRedirect(
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

    package func applyResponse(
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

    package func applyDataReceived(dataLength: Int, encodedDataLength: Int, timestamp: Double) {
        decodedDataLength += max(0, dataLength)
        self.encodedDataLength += max(0, encodedDataLength)
        lastDataReceivedTimestamp = timestamp
        if state == .pending {
            state = .responded
        }
    }

    package func finish(timestamp: Double, sourceMapURL: String?, metrics: Network.Metrics?) {
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

    package func fail(errorText: String, canceled: Bool, timestamp: Double) {
        finishedOrFailedTimestamp = timestamp
        state = .failed(errorText: errorText, canceled: canceled)
    }

    package func applyMemoryCache(response: Network.Response, timestamp: Double) {
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

    package func finishResponseBodyFetch(result: Result<Network.Body, WebViewProxyError>) {
        switch result {
        case let .success(body):
            responseBody.load(body)
        case let .failure(error):
            responseBody.fail(error)
        }
    }

    package func applyWebSocketCreated(url: String) {
        self.url = url
        resourceType = .webSocket
        _ = ensureWebSocketState()
    }

    package func applyWebSocketHandshakeRequest(_ request: Network.Request, timestamp: Double?) {
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

    package func applyWebSocketHandshakeResponse(_ response: Network.Response, timestamp: Double?) {
        applyResponse(response, resourceType: .webSocket, timestamp: timestamp)
        ensureWebSocketState().applyHandshakeResponse(response)
    }

    package func appendWebSocketFrame(
        _ frame: Network.WebSocketFrame,
        direction: WebSocketState.FrameDirection,
        timestamp: Double
    ) {
        decodedDataLength += max(0, frame.payloadLength)
        lastDataReceivedTimestamp = timestamp
        ensureWebSocketState().appendFrame(frame, direction: direction, timestamp: timestamp)
    }

    package func appendWebSocketError(_ message: String, timestamp: Double) {
        lastDataReceivedTimestamp = timestamp
        ensureWebSocketState().appendError(message, timestamp: timestamp)
    }

    package func closeWebSocket(timestamp: Double) {
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
