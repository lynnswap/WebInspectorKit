import Foundation
import Observation
import WebInspectorProxyKit

/// Immutable snapshot of the request side of a network load.
public struct NetworkRequestSnapshot: Equatable, Sendable {
    /// The request URL.
    public let url: String

    /// The HTTP method.
    public let method: String

    /// Request headers keyed by header name.
    public let headers: [String: String]

    /// The request body text, if WebKit included it.
    public let postData: String?

    /// The referrer policy raw value, if WebKit reported one.
    public let referrerPolicy: String?

    /// The request integrity metadata, if any.
    public let integrity: String?

    /// The backend resource identity used by WebKit body lookup, if any.
    public let backendResourceIdentifier: Network.BackendResourceID?

    /// Creates a request snapshot.
    public init(
        url: String,
        method: String,
        headers: [String: String] = [:],
        postData: String? = nil,
        referrerPolicy: String? = nil,
        integrity: String? = nil,
        backendResourceIdentifier: Network.BackendResourceID? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.postData = postData
        self.referrerPolicy = referrerPolicy
        self.integrity = integrity
        self.backendResourceIdentifier = backendResourceIdentifier
    }

    init(_ request: Network.Request) {
        self.init(
            url: request.url,
            method: request.method,
            headers: request.headers,
            postData: request.postData,
            referrerPolicy: request.referrerPolicy?.rawValue,
            integrity: request.integrity,
            backendResourceIdentifier: request.backendResourceIdentifier
        )
    }
}

/// Immutable snapshot of the response side of a network load.
public struct NetworkResponseSnapshot: Equatable, Sendable {
    /// The response URL.
    public let url: String?

    /// The HTTP status code.
    public let status: Int?

    /// The HTTP status text.
    public let statusText: String?

    /// The response MIME type.
    public let mimeType: String?

    /// Response headers keyed by header name.
    public let headers: [String: String]

    /// WebKit's response source raw value.
    public let source: String?

    /// Request headers associated with the response, if reported.
    public let requestHeaders: [String: String]?

    /// The response body size reported by WebKit, if any.
    public let bodySize: Int?

    /// Creates a response snapshot.
    public init(
        url: String? = nil,
        status: Int? = nil,
        statusText: String? = nil,
        mimeType: String? = nil,
        headers: [String: String] = [:],
        source: String? = nil,
        requestHeaders: [String: String]? = nil,
        bodySize: Int? = nil
    ) {
        self.url = url
        self.status = status
        self.statusText = statusText
        self.mimeType = mimeType
        self.headers = headers
        self.source = source
        self.requestHeaders = requestHeaders
        self.bodySize = bodySize
    }

    init(_ response: Network.Response) {
        self.init(
            url: response.url,
            status: response.status,
            statusText: response.statusText,
            mimeType: response.mimeType,
            headers: response.headers,
            source: response.source?.rawValue,
            requestHeaders: response.requestHeaders,
            bodySize: response.bodySize
        )
    }
}

/// A redirect step recorded for a network request.
public struct RedirectHop: Equatable, Sendable {
    /// The request that caused the redirect.
    public let request: NetworkRequestSnapshot

    /// The redirect response.
    public let response: NetworkResponseSnapshot

    /// The protocol timestamp for the redirect.
    public let timestamp: Double

    /// The resource type associated with this completed hop.
    public let resourceType: Network.ResourceType?

    /// The timestamp when this hop's request was sent.
    public let requestSentTimestamp: Double?

    /// The timestamp when this hop's response was received.
    public let responseReceivedTimestamp: Double?

    /// The timestamp for this hop's last data event.
    public let lastDataReceivedTimestamp: Double?

    /// Decoded bytes attributed to this redirect hop.
    public let decodedDataLength: Int

    /// Encoded bytes attributed to this redirect hop.
    public let encodedDataLength: Int

    /// Creates a redirect hop.
    public init(
        request: NetworkRequestSnapshot,
        response: NetworkResponseSnapshot,
        timestamp: Double,
        resourceType: Network.ResourceType? = nil,
        requestSentTimestamp: Double? = nil,
        responseReceivedTimestamp: Double? = nil,
        lastDataReceivedTimestamp: Double? = nil,
        decodedDataLength: Int = 0,
        encodedDataLength: Int = 0
    ) {
        self.request = request
        self.response = response
        self.timestamp = timestamp
        self.resourceType = resourceType
        self.requestSentTimestamp = requestSentTimestamp
        self.responseReceivedTimestamp = responseReceivedTimestamp
        self.lastDataReceivedTimestamp = lastDataReceivedTimestamp
        self.decodedDataLength = decodedDataLength
        self.encodedDataLength = encodedDataLength
    }

    init(request: Network.Request, response: Network.Response, timestamp: Double) {
        self.init(
            request: NetworkRequestSnapshot(request),
            response: NetworkResponseSnapshot(response),
            timestamp: timestamp
        )
    }
}

/// Observable WebSocket state attached to a network request.
@Observable
public final class WebSocketState {
    /// WebSocket ready state tracked from network events.
    public enum ReadyState: Equatable, Sendable {
        /// The WebSocket is connecting.
        case connecting

        /// The WebSocket handshake completed.
        case open

        /// The WebSocket is closed.
        case closed
    }

    /// Direction or error state for a WebSocket frame row.
    public enum FrameDirection: Equatable, Sendable {
        /// A frame sent by the inspected page.
        case sent

        /// A frame received by the inspected page.
        case received

        /// A WebSocket error row.
        case error(String)
    }

    /// One WebSocket frame or error row.
    public struct Frame: Equatable, Sendable {
        /// Direction or error state for the row.
        public let direction: FrameDirection

        /// The WebSocket opcode.
        public let opcode: Int?

        /// A Boolean value indicating whether the frame was masked.
        public let mask: Bool?

        /// The frame payload as text or base64.
        public let payloadData: String?

        /// The payload length in bytes.
        public let payloadLength: Int?

        /// The error message for error rows.
        public let errorMessage: String?

        /// The protocol timestamp for the frame or error.
        public let timestamp: Double

        /// Creates a WebSocket frame row.
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

    /// The current WebSocket ready state.
    public private(set) var readyState: ReadyState

    /// The URL carried by the WebSocket creation event.
    public private(set) var creationURL: String?

    /// The handshake request snapshot.
    public private(set) var handshakeRequest: NetworkRequestSnapshot?

    /// The handshake response snapshot.
    public private(set) var handshakeResponse: NetworkResponseSnapshot?

    /// The timestamp associated with the handshake request.
    public private(set) var handshakeRequestTimestamp: Double?

    /// The timestamp associated with the handshake response.
    public private(set) var handshakeResponseTimestamp: Double?

    /// Frames and errors observed for the WebSocket.
    public private(set) var frames: [Frame]

    /// The timestamp associated with the close event.
    public private(set) var closedTimestamp: Double?

    init(
        readyState: ReadyState = .connecting,
        creationURL: String? = nil
    ) {
        self.readyState = readyState
        self.creationURL = creationURL
        handshakeRequest = nil
        handshakeResponse = nil
        handshakeRequestTimestamp = nil
        handshakeResponseTimestamp = nil
        frames = []
        closedTimestamp = nil
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

    func updateCreationURL(_ url: String) {
        creationURL = url
    }

    func applyHandshakeRequest(_ request: Network.Request) {
        handshakeRequest = NetworkRequestSnapshot(request)
        handshakeRequestTimestamp = nil
        readyState = .connecting
    }

    func applyHandshakeRequest(
        _ request: Network.Request,
        timestamp: Double?
    ) {
        applyHandshakeRequest(request)
        handshakeRequestTimestamp = timestamp
    }

    func applyHandshakeResponse(_ response: Network.Response) {
        handshakeResponse = NetworkResponseSnapshot(response)
        handshakeResponseTimestamp = nil
        readyState = .open
    }

    func applyHandshakeResponse(
        _ response: Network.Response,
        timestamp: Double?
    ) {
        applyHandshakeResponse(response)
        handshakeResponseTimestamp = timestamp
    }

    func markClosed(timestamp: Double) {
        markClosed()
        closedTimestamp = timestamp
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

    package convenience init(_ record: CanonicalNetworkWebSocketRecord) {
        self.init()
        replace(with: record)
    }

    package func replace(with record: CanonicalNetworkWebSocketRecord) {
        creationURL = record.creationURL
        readyState = Self.readyState(record.readyState)
        handshakeRequest = record.handshakeRequest.map {
            NetworkRequestSnapshot($0.request.proxyValue)
        }
        handshakeRequestTimestamp = record.handshakeRequest?.timestamp
        handshakeResponse = record.handshakeResponse.map {
            NetworkResponseSnapshot($0.response.proxyValue)
        }
        handshakeResponseTimestamp = record.handshakeResponse?.timestamp
        frames = record.contents.map(Self.frame)
        closedTimestamp = record.closedTimestamp
    }

    package func append(_ content: CanonicalNetworkWebSocketContent) {
        frames.append(Self.frame(content))
    }

    package func setReadyState(
        _ readyState: CanonicalNetworkWebSocketReadyState
    ) {
        self.readyState = Self.readyState(readyState)
    }

    private static func readyState(
        _ state: CanonicalNetworkWebSocketReadyState
    ) -> ReadyState {
        switch state {
        case .connecting:
            .connecting
        case .open:
            .open
        case .closed:
            .closed
        }
    }

    private static func frame(
        _ content: CanonicalNetworkWebSocketContent
    ) -> Frame {
        switch content {
        case let .frame(
            direction,
            opcode,
            mask,
            payloadData,
            payloadLength,
            timestamp
        ):
            return Frame(
                direction: direction == .sent ? .sent : .received,
                opcode: opcode,
                mask: mask,
                payloadData: payloadData,
                payloadLength: payloadLength,
                timestamp: timestamp
            )
        case let .error(message, timestamp):
            return Frame(
                direction: .error(message),
                errorMessage: message,
                timestamp: timestamp
            )
        }
    }
}

/// Observable request or response body state for a network request.
@Observable
public final class NetworkBody {
    final class ResponseFetchIdentity {}

    struct ResponseFetchLease {
        fileprivate let identity: ResponseFetchIdentity
        fileprivate let revision: UInt64
        let completion: ReplyPromise<Network.Body>
    }

    enum ResponseFetchAcquisition {
        case loaded
        case failed(Failure)
        case owner(ResponseFetchLease)
        case waiter(ResponseFetchLease)
    }

    private struct ResponseFetch {
        let lease: ResponseFetchLease
        var task: Task<Void, Never>?
    }

    /// The body side represented by the model.
    public enum Role: CaseIterable, Hashable, Sendable {
        /// A request body.
        case request

        /// A response body.
        case response
    }

    /// Display classification for body content.
    public enum Kind: Hashable, Sendable {
        /// Text-like body content.
        case text

        /// URL-encoded form body content.
        case form

        /// Binary body content.
        case binary
    }

    /// The terminal reason that made a response body unavailable.
    public enum Failure: Error, Equatable, Sendable {
        /// WebKit reported that the resource load failed or was cancelled.
        case loadingFailed(errorText: String, canceled: Bool)

        /// The semantic model rejected the response-body operation.
        case model(WebInspectorModelError)

        /// The model context entered a terminal attachment failure.
        case context(WebInspectorModelContext.Failure)

        /// The model context was already closed.
        case transition(WebInspectorModelContext.TransitionError)

        /// The inspector protocol or transport failed the response-body command.
        case proxy(WebInspectorProxyError)
    }

    /// Syntax hint for text body rendering.
    public enum SyntaxKind: Hashable, Sendable {
        /// Plain text content.
        case plainText

        /// JSON content.
        case json

        /// HTML content.
        case html

        /// XML content.
        case xml

        /// CSS content.
        case css

        /// JavaScript content.
        case javascript
    }

    /// Loading phase for a body.
    public enum Phase: Equatable, Sendable {
        /// The body is available to fetch but has not been loaded.
        case available

        /// The body is currently being fetched.
        case fetching

        /// The body has been loaded.
        case loaded

        /// Loading the body failed.
        case failed(Failure)
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

    /// The body side represented by the model.
    public let role: Role

    /// The display classification for the body content.
    public private(set) var kind: Kind {
        didSet {
            invalidateTextRepresentation()
        }
    }
    /// The current body loading phase.
    public private(set) var phase: Phase

    /// The full raw body payload, if loaded.
    public private(set) var full: String? {
        didSet {
            text = full
            invalidateTextRepresentation()
        }
    }
    /// The raw body text when available.
    public private(set) var text: String?

    /// The body size in bytes, if known.
    public private(set) var size: Int?

    /// A Boolean value indicating whether ``full`` is base64 encoded.
    public private(set) var isBase64Encoded: Bool

    /// A Boolean value indicating whether the body payload was truncated.
    public private(set) var isTruncated: Bool

    /// The syntax hint inferred from headers, MIME type, or URL.
    public private(set) var sourceSyntaxKind: SyntaxKind {
        didSet {
            invalidateTextRepresentation()
        }
    }
    /// Decoded and formatted text suitable for display.
    public private(set) var textRepresentation: String?

    /// Syntax hint for ``textRepresentation``.
    public private(set) var textRepresentationSyntaxKind: SyntaxKind
    @ObservationIgnored private var isBatchingTextRepresentationInvalidation: Bool
    @ObservationIgnored private var needsTextRepresentationInvalidation: Bool
    @ObservationIgnored private var responseRevision: UInt64
    @ObservationIgnored private var responseFetch: ResponseFetch?
    @ObservationIgnored private weak var canonicalModelContext:
        WebInspectorModelContext?
    @ObservationIgnored private var canonicalRequestID: NetworkRequest.ID?
    @ObservationIgnored private var hasCanonicalResponseMetadata: Bool

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
        responseRevision = 0
        responseFetch = nil
        canonicalModelContext = nil
        canonicalRequestID = nil
        hasCanonicalResponseMetadata = false
        refreshTextRepresentation()
    }

    deinit {
        responseFetch?.lease.completion.fulfill(
            .failure(WebInspectorProxyError.staleIdentifier)
        )
        responseFetch?.task?.cancel()
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

    func acquireResponseFetch() -> ResponseFetchAcquisition {
        switch phase {
        case .loaded:
            return .loaded
        case let .failed(error):
            return .failed(error)
        case .fetching:
            guard let responseFetch else {
                preconditionFailure("A fetching NetworkBody has no response-fetch owner.")
            }
            return .waiter(responseFetch.lease)
        case .available:
            precondition(
                responseFetch == nil,
                "An available NetworkBody cannot already own a response fetch."
            )
            let lease = ResponseFetchLease(
                identity: ResponseFetchIdentity(),
                revision: responseRevision,
                completion: ReplyPromise<Network.Body>()
            )
            responseFetch = ResponseFetch(lease: lease, task: nil)
            phase = .fetching
            return .owner(lease)
        }
    }

    func installResponseFetchTask(
        _ task: Task<Void, Never>,
        for lease: ResponseFetchLease
    ) {
        guard var responseFetch,
              responseFetch.lease.identity === lease.identity else {
            task.cancel()
            return
        }
        precondition(
            responseFetch.task == nil,
            "A NetworkBody response fetch can install only one task."
        )
        responseFetch.task = task
        self.responseFetch = responseFetch
    }

    func finishResponseFetch(
        _ result: Result<Network.Body, WebInspectorProxyError>,
        for lease: ResponseFetchLease
    ) {
        guard let responseFetch,
              responseFetch.lease.identity === lease.identity else {
            return
        }
        self.responseFetch = nil
        switch result {
        case let .success(body):
            load(body)
            lease.completion.fulfill(.success(body))
        case let .failure(error):
            fail(.proxy(error))
            lease.completion.fulfill(.failure(error))
        }
    }

    func isCurrentResponseFetch(_ lease: ResponseFetchLease) -> Bool {
        lease.revision == responseRevision
    }

    func invalidateResponseFetch(
        with error: WebInspectorProxyError = .staleIdentifier
    ) {
        guard let responseFetch else {
            return
        }
        self.responseFetch = nil
        fail(.proxy(error))
        responseFetch.lease.completion.fulfill(.failure(error))
        responseFetch.task?.cancel()
    }

    func failResponseFetch(
        _ failure: Failure,
        completionError: (any Error)? = nil
    ) {
        let responseFetch = self.responseFetch
        self.responseFetch = nil
        fail(failure)
        responseFetch?.lease.completion.fulfill(
            .failure(completionError ?? failure)
        )
        responseFetch?.task?.cancel()
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

    func fail(_ failure: Failure) {
        phase = .failed(failure)
    }

    func resetForResponse(
        _ response: Network.Response? = nil,
        fallbackURL: String = ""
    ) {
        precondition(
            role == .response,
            "Only a response NetworkBody can adopt response metadata."
        )
        precondition(
            responseRevision < UInt64.max,
            "A NetworkBody exhausted its response revision space."
        )
        responseRevision += 1
        resetPayloadForResponse(response, fallbackURL: fallbackURL)
    }

    package func bindCanonicalOwner(
        _ modelContext: WebInspectorModelContext,
        requestID: NetworkRequest.ID
    ) {
        precondition(
            role == .response,
            "Only a response NetworkBody can bind canonical command ownership."
        )
        precondition(
            requestID.canonicalStorage != nil,
            "A canonical response body requires a canonical request identity."
        )
        canonicalModelContext = modelContext
        canonicalRequestID = requestID
    }

    package func synchronizeCanonicalResponse(
        revision: UInt64,
        response: Network.Response?,
        fallbackURL: String
    ) {
        precondition(
            role == .response,
            "Only a response NetworkBody can adopt canonical response metadata."
        )
        precondition(
            revision >= responseRevision,
            "A NetworkBody cannot move its canonical response revision backward."
        )
        guard !hasCanonicalResponseMetadata || revision != responseRevision else {
            return
        }
        responseRevision = revision
        hasCanonicalResponseMetadata = true
        resetPayloadForResponse(response, fallbackURL: fallbackURL)
    }

    package func invalidateCanonicalOwner() {
        canonicalModelContext = nil
        canonicalRequestID = nil
        failResponseFetch(
            .model(.staleModel),
            completionError: WebInspectorModelError.staleModel
        )
    }

    package var canonicalResponseRevision: UInt64 {
        responseRevision
    }

    package var boundCanonicalRequestID: NetworkRequest.ID? {
        canonicalRequestID
    }

    /// Loads this response body through its model container's canonical
    /// Network command authority.
    @discardableResult
    public func load(
        isolation: isolated (any Actor) = #isolation
    ) async throws -> NetworkBody {
        _ = isolation
        guard let modelContext = canonicalModelContext,
            canonicalRequestID != nil
        else {
            throw WebInspectorModelError.staleModel
        }
        return try await modelContext.loadCanonicalResponseBody(
            self,
            isolation: isolation
        )
    }

    private func resetPayloadForResponse(
        _ response: Network.Response?,
        fallbackURL: String
    ) {
        let hints = Self.bodyHints(
            mimeType: response?.mimeType,
            headers: response?.headers ?? [:],
            url: response?.url ?? fallbackURL,
            role: .response
        )
        let responseFetch = self.responseFetch
        self.responseFetch = nil
        responseFetch?.lease.completion.fulfill(
            .failure(WebInspectorProxyError.staleIdentifier)
        )
        responseFetch?.task?.cancel()

        withTextRepresentationInvalidationBatch {
            kind = hints.kind
            full = nil
            isBase64Encoded = false
            isTruncated = false
            sourceSyntaxKind = hints.syntaxKind
        }
        size = nil
        phase = .available
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

/// Observable model for one network request.
@Observable
public final class NetworkRequest: WebInspectorPersistentModel {
    /// Stable identity for a network request within a context.
    public struct ID: WebInspectorPersistentIdentifier {
        /// The persistent model identified by this value.
        public typealias Model = NetworkRequest

        package enum Storage: Hashable, Sendable {
            case legacyRaw(Network.Request.ID)
            case canonical(CanonicalNetworkRequestIDStorage)
        }

        package let storage: Storage

        init(_ proxyID: Network.Request.ID) {
            storage = .legacyRaw(proxyID)
        }

        package init(canonical storage: CanonicalNetworkRequestIDStorage) {
            self.storage = .canonical(storage)
        }

        package var canonicalStorage: CanonicalNetworkRequestIDStorage? {
            guard case let .canonical(storage) = storage else {
                return nil
            }
            return storage
        }

        package var proxyID: Network.Request.ID {
            switch storage {
            case let .legacyRaw(proxyID):
                proxyID
            case let .canonical(storage):
                storage.rawRequestID
            }
        }
    }

    /// Immutable Network fields available to typed fetch descriptors.
    public struct QueryValue: Identifiable, Sendable {
        /// The request identity.
        public let id: ID

        /// The request's stable insertion position in its source generation.
        public let insertionIndex: Int

        /// The request URL.
        public let url: String

        /// The HTTP method.
        public let method: String

        /// The resource type reported by WebKit.
        public let resourceType: Network.ResourceType?

        /// The response MIME type.
        public let mimeType: String?

        /// The coarse resource category used by Network filtering.
        public let resourceCategory: ResourceCategory

        /// The normalized text used by Network filtering.
        public let searchableText: String

        /// The HTTP status code.
        public let statusCode: Int?

        /// The timestamp when the request was sent.
        public let requestSentTimestamp: Double?

        /// The initiating DOM node, if WebKit reported one.
        public let initiatorNodeID: DOMNode.ID?

        package init(
            id: ID,
            insertionIndex: Int,
            url: String,
            method: String,
            resourceType: Network.ResourceType?,
            mimeType: String?,
            resourceCategory: ResourceCategory,
            searchableText: String,
            statusCode: Int?,
            requestSentTimestamp: Double?,
            initiatorNodeID: DOMNode.ID?
        ) {
            self.id = id
            self.insertionIndex = insertionIndex
            self.url = url
            self.method = method
            self.resourceType = resourceType
            self.mimeType = mimeType
            self.resourceCategory = resourceCategory
            self.searchableText = searchableText
            self.statusCode = statusCode
            self.requestSentTimestamp = requestSentTimestamp
            self.initiatorNodeID = initiatorNodeID
        }
    }

    /// Lifecycle state for a network request.
    public enum State: Equatable, Sendable {
        /// The request was sent and no response has been received.
        case pending

        /// A response has been received and loading is still active.
        case responded

        /// Loading finished successfully.
        case finished

        /// Loading failed or was cancelled.
        case failed(errorText: String, canceled: Bool)
    }

    /// Coarse resource category for filtering and display.
    public enum ResourceCategory: String, Codable, CaseIterable, Sendable, Hashable {
        /// Document navigation resource.
        case document

        /// Stylesheet resource.
        case stylesheet

        /// Script resource.
        case script

        /// Image resource.
        case image

        /// Font resource.
        case font

        /// XHR or Fetch resource.
        case xhrFetch

        /// Media resource.
        case media

        /// WebSocket resource.
        case webSocket

        /// A resource that does not fit another category.
        case other
    }

    /// The stable request identity.
    public let id: ID

    /// The request URL.
    public private(set) var url: String

    /// The HTTP method.
    public private(set) var method: String

    /// The resource type reported by WebKit.
    public private(set) var resourceType: Network.ResourceType?

    /// Information about what initiated the first request in this redirect chain.
    ///
    /// Redirects preserve the original initiator because WebKit treats the
    /// complete redirect chain as one logical resource.
    public private(set) var initiator: Network.Initiator?

    /// The current request lifecycle state.
    public private(set) var state: State

    /// The HTTP status code.
    public private(set) var status: Int?

    /// The HTTP status text.
    public private(set) var statusText: String?

    /// The final response URL.
    public private(set) var responseURL: String?

    /// The response MIME type.
    public private(set) var mimeType: String?

    /// WebKit's response source raw value.
    public private(set) var responseSource: String?

    /// The source map URL reported when loading finished.
    public private(set) var sourceMapURL: String?

    /// Request headers keyed by header name.
    public private(set) var requestHeaders: [String: String]

    /// Response headers keyed by header name.
    public private(set) var responseHeaders: [String: String]

    /// Timestamp when the request was sent.
    public private(set) var requestSentTimestamp: Double?

    /// Timestamp when this redirect chain or WebSocket request began.
    public private(set) var logicalStartTimestamp: Double?

    /// Timestamp when the response was received.
    public private(set) var responseReceivedTimestamp: Double?

    /// Timestamp for the most recent data event.
    public private(set) var lastDataReceivedTimestamp: Double?

    /// Timestamp when loading finished or failed.
    public private(set) var finishedOrFailedTimestamp: Double?

    /// Total decoded data length reported so far.
    public private(set) var decodedDataLength: Int

    /// Total encoded data length reported so far.
    public private(set) var encodedDataLength: Int

    /// Final transfer metrics, if WebKit reported them.
    public private(set) var metrics: Network.Metrics?

    /// Redirect hops that led to the current request.
    public private(set) var redirects: [RedirectHop]

    /// WebSocket state when the request is a WebSocket.
    public private(set) var webSocket: WebSocketState?

    /// Request body state, if the request has a body.
    public private(set) var requestBody: NetworkBody?

    /// Response body state. Its identity is stable for this request model.
    public let responseBody: NetworkBody

    /// Whether WebKit permits later multipart response continuation events.
    public private(set) var allowsMultipartContinuation: Bool

    /// Whether WebKit served the current response from its memory cache.
    public private(set) var wasServedFromMemoryCache: Bool

    @ObservationIgnored weak var modelContext: WebInspectorModelContext?
    @ObservationIgnored private var currentRequest: Network.Request

    var proxyID: Network.Request.ID {
        id.proxyID
    }

    var backendResourceIdentifier: Network.BackendResourceID? {
        currentRequest.backendResourceIdentifier
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
        initiator: Network.Initiator?,
        resourceType: Network.ResourceType?,
        timestamp: Double?,
        modelContext: WebInspectorModelContext
    ) {
        id = ID(request.id)
        url = request.url
        method = request.method
        self.initiator = initiator
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
        logicalStartTimestamp = timestamp
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
        allowsMultipartContinuation = false
        wasServedFromMemoryCache = false
        self.modelContext = modelContext
        currentRequest = request
    }

    /// A Boolean value indicating whether the response body can be fetched now.
    public var canFetchResponseBody: Bool {
        guard state == .finished, hasResponseBody else {
            return false
        }
        return responseBody.needsFetch
    }

    /// A Boolean value indicating whether any response metadata has been received.
    public var hasResponse: Bool {
        responseReceivedTimestamp != nil
            || status != nil
            || statusText != nil
            || responseURL != nil
            || mimeType != nil
            || responseHeaders.isEmpty == false
            || responseSource != nil
    }

    /// A Boolean value indicating whether the request can have a response body.
    public var hasResponseBody: Bool {
        hasResponse && resourceType != .webSocket
    }

    /// The coarse category inferred for filtering and display.
    public var resourceCategory: ResourceCategory {
        Self.resourceCategory(
            resourceType: resourceType,
            mimeType: Self.effectiveMIMEType(mimeType: mimeType, headers: responseHeaders),
            url: responseURL ?? url,
            hasResponse: hasResponse
        )
    }

    /// Text used by Network list filtering.
    public var searchableText: String {
        let currentFields: [String?] = [
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
        ]
        let redirectFields: [String?] = redirects.flatMap { redirect in
            [
                redirect.request.url,
                Self.urlSearchText(redirect.request.url),
                redirect.request.method,
                redirect.response.url,
                redirect.response.url.map(Self.urlSearchText),
                redirect.response.status.map(String.init),
                redirect.response.statusText,
                redirect.response.mimeType,
            ]
        }
        return Self.uniqueNonEmpty(currentFields + redirectFields)
        .joined(separator: "\n")
    }

    /// The HTTP status code, exposed as a stable fetch key path.
    public var statusCode: Int? {
        status
    }

    func applyRequestWillBeSent(
        request: Network.Request,
        initiator: Network.Initiator?,
        resourceType: Network.ResourceType?,
        timestamp: Double
    ) {
        currentRequest = request
        url = request.url
        method = request.method
        self.initiator = initiator
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
        logicalStartTimestamp = timestamp
        responseReceivedTimestamp = nil
        lastDataReceivedTimestamp = nil
        finishedOrFailedTimestamp = nil
        decodedDataLength = 0
        encodedDataLength = 0
        metrics = nil
        redirects = []
        webSocket = resourceType == .webSocket ? WebSocketState() : nil
        requestBody = NetworkBody.makeRequestBody(for: request)
        responseBody.resetForResponse(fallbackURL: currentRequest.url)
        allowsMultipartContinuation = false
        wasServedFromMemoryCache = false
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
        responseBody.resetForResponse(fallbackURL: currentRequest.url)
        allowsMultipartContinuation = false
        wasServedFromMemoryCache = false
        state = .pending
    }

    func applyResponse(
        _ response: Network.Response,
        resourceType: Network.ResourceType?,
        timestamp: Double?
    ) {
        let resolvedResourceType = resourceType ?? self.resourceType
        self.resourceType = resolvedResourceType
        if resolvedResourceType == .webSocket {
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
        responseBody.resetForResponse(response, fallbackURL: currentRequest.url)
        wasServedFromMemoryCache = false
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
        responseBody.failResponseFetch(
            .loadingFailed(errorText: errorText, canceled: canceled)
        )
    }

    func applyMemoryCache(response: Network.Response, resourceType: Network.ResourceType?, timestamp: Double) {
        if let url = response.url {
            self.url = url
        }
        // The cached-resource payload carries the protocol-authoritative type;
        // keep any previously decoded type when the event omits it.
        if let resourceType {
            self.resourceType = resourceType
        }
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
        logicalStartTimestamp = timestamp
        responseReceivedTimestamp = timestamp
        lastDataReceivedTimestamp = nil
        finishedOrFailedTimestamp = timestamp
        let bodySize = response.bodySize.map { max(0, $0) } ?? 0
        decodedDataLength = bodySize
        encodedDataLength = bodySize
        metrics = nil
        redirects = []
        requestBody = NetworkBody.makeRequestBody(for: currentRequest)
        responseBody.resetForResponse(response, fallbackURL: currentRequest.url)
        allowsMultipartContinuation = false
        wasServedFromMemoryCache = true
        state = .finished
    }

    func invalidateResponseBodyFetch() {
        responseBody.invalidateResponseFetch()
    }

    func applyWebSocketCreated(url: String) {
        self.url = url
        currentRequest = requestWithURL(url)
        resourceType = .webSocket
        ensureWebSocketState().updateCreationURL(url)
    }

    func applyWebSocketHandshakeRequest(_ request: Network.Request, timestamp: Double?) {
        let request = requestPreservingCurrentURLIfNeeded(request)
        currentRequest = request
        url = request.url
        method = request.method
        resourceType = .webSocket
        requestHeaders = request.headers
        requestBody = NetworkBody.makeRequestBody(for: request)
        responseBody.resetForResponse(fallbackURL: currentRequest.url)
        status = nil
        statusText = nil
        responseURL = nil
        mimeType = nil
        responseSource = nil
        if let timestamp {
            requestSentTimestamp = timestamp
            logicalStartTimestamp = logicalStartTimestamp ?? timestamp
        }
        state = .pending
        ensureWebSocketState().applyHandshakeRequest(
            request,
            timestamp: timestamp
        )
    }

    func applyWebSocketHandshakeResponse(_ response: Network.Response, timestamp: Double?) {
        applyResponse(response, resourceType: .webSocket, timestamp: timestamp)
        ensureWebSocketState().applyHandshakeResponse(
            response,
            timestamp: timestamp
        )
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
        ensureWebSocketState().markClosed(timestamp: timestamp)
        finishedOrFailedTimestamp = timestamp
        state = .finished
    }

    package init(
        canonical record: CanonicalNetworkRequestRecord,
        modelContext: WebInspectorModelContext
    ) {
        let hop = record.currentHop
        let response = hop.response?.proxyValue
        let request = hop.request.proxyValue(
            overridingHeaders: response?.requestHeaders
        )
        id = ID(canonical: record.id)
        url = request.url
        method = request.method
        initiator = record.initialInitiator?.proxyValue
        resourceType = hop.resourceType.map(Network.ResourceType.init(rawValue:))
        state = Self.state(record.lifecycle)
        status = response?.status
        statusText = response?.statusText
        responseURL = response?.url
        mimeType = response?.mimeType
        responseSource = response?.source?.rawValue
        sourceMapURL = hop.sourceMapURL
        requestHeaders = request.headers
        responseHeaders = response?.headers ?? [:]
        requestSentTimestamp = hop.requestSentTimestamp
        logicalStartTimestamp = record.logicalStartTimestamp
        responseReceivedTimestamp = hop.responseReceivedTimestamp
        lastDataReceivedTimestamp = hop.transfer.lastDataReceivedTimestamp
        finishedOrFailedTimestamp = hop.terminalTimestamp
        decodedDataLength = hop.transfer.decodedDataLength
        encodedDataLength = hop.transfer.encodedDataLength
        metrics = hop.metrics?.proxyValue
        redirects = record.redirects.map(\.publicValue)
        webSocket = record.webSocket.map(WebSocketState.init)
        requestBody = NetworkBody.makeRequestBody(for: request)
        responseBody = NetworkBody()
        allowsMultipartContinuation = record.allowsMultipartContinuation
        wasServedFromMemoryCache = hop.servedFromMemoryCache
        self.modelContext = modelContext
        currentRequest = request

        responseBody.bindCanonicalOwner(modelContext, requestID: id)
        responseBody.synchronizeCanonicalResponse(
            revision: record.responseBodyRevision,
            response: response,
            fallbackURL: request.url
        )
        applyCanonicalTerminalBodyState(record.lifecycle)
    }

    package func replaceCanonicalRecord(
        _ record: CanonicalNetworkRequestRecord,
        modelContext: WebInspectorModelContext
    ) {
        precondition(
            id == ID(canonical: record.id),
            "A NetworkRequest cannot adopt another canonical identity."
        )
        self.modelContext = modelContext
        redirects = record.redirects.map(\.publicValue)
        initiator = record.initialInitiator?.proxyValue
        logicalStartTimestamp = record.logicalStartTimestamp
        webSocket = record.webSocket.map(WebSocketState.init)
        allowsMultipartContinuation = record.allowsMultipartContinuation
        applyCanonicalCurrentHop(record.currentHop)
        responseBody.bindCanonicalOwner(modelContext, requestID: id)
        responseBody.synchronizeCanonicalResponse(
            revision: record.responseBodyRevision,
            response: record.currentHop.response?.proxyValue,
            fallbackURL: record.currentHop.request.url
        )
        state = Self.state(record.lifecycle)
        applyCanonicalTerminalBodyState(record.lifecycle)
    }

    package func applyCanonicalPatch(
        _ patch: CanonicalNetworkRequestPatch
    ) {
        precondition(
            id.canonicalStorage != nil,
            "Canonical Network patches cannot target a legacy request identity."
        )
        switch patch {
        case let .redirect(
            appendedHop,
            currentHop,
            lifecycle,
            allowsMultipartContinuation,
            responseBodyRevision
        ):
            redirects.append(appendedHop.publicValue)
            applyCanonicalCurrentHop(currentHop)
            self.allowsMultipartContinuation = allowsMultipartContinuation
            responseBody.synchronizeCanonicalResponse(
                revision: responseBodyRevision,
                response: currentHop.response?.proxyValue,
                fallbackURL: currentHop.request.url
            )
            state = Self.state(lifecycle)
            applyCanonicalTerminalBodyState(lifecycle)

        case let .response(
            currentHop,
            lifecycle,
            allowsMultipartContinuation,
            responseBodyRevision
        ):
            applyCanonicalCurrentHop(currentHop)
            self.allowsMultipartContinuation = allowsMultipartContinuation
            responseBody.synchronizeCanonicalResponse(
                revision: responseBodyRevision,
                response: currentHop.response?.proxyValue,
                fallbackURL: currentHop.request.url
            )
            state = Self.state(lifecycle)
            applyCanonicalTerminalBodyState(lifecycle)

        case let .transfer(transfer, lifecycle):
            applyCanonicalTransfer(transfer)
            state = Self.state(lifecycle)
            applyCanonicalTerminalBodyState(lifecycle)

        case let .terminal(currentHop, lifecycle):
            applyCanonicalCurrentHop(currentHop)
            state = Self.state(lifecycle)
            applyCanonicalTerminalBodyState(lifecycle)

        case let .webSocketHandshakeResponse(
            handshake,
            response,
            responseReceivedTimestamp,
            readyState,
            lifecycle,
            responseBodyRevision
        ):
            let response = response.proxyValue
            resourceType = .webSocket
            status = response.status
            statusText = response.statusText
            responseURL = response.url
            mimeType = response.mimeType
            responseSource = response.source?.rawValue
            responseHeaders = response.headers
            if let headers = response.requestHeaders {
                requestHeaders = headers
                currentRequest = currentRequest.replacingHeaders(headers)
                requestBody = NetworkBody.makeRequestBody(for: currentRequest)
            }
            self.responseReceivedTimestamp = responseReceivedTimestamp
            let webSocket = ensureWebSocketState()
            webSocket.applyHandshakeResponse(
                handshake.response.proxyValue,
                timestamp: handshake.timestamp
            )
            webSocket.setReadyState(readyState)
            responseBody.synchronizeCanonicalResponse(
                revision: responseBodyRevision,
                response: response,
                fallbackURL: currentRequest.url
            )
            state = Self.state(lifecycle)
            applyCanonicalTerminalBodyState(lifecycle)

        case let .webSocketContentAppended(content, transfer):
            ensureWebSocketState().append(content)
            applyCanonicalTransfer(transfer)

        case let .webSocketClosed(timestamp, lifecycle):
            ensureWebSocketState().markClosed(timestamp: timestamp)
            finishedOrFailedTimestamp = timestamp
            state = Self.state(lifecycle)
            applyCanonicalTerminalBodyState(lifecycle)
        }
    }

    package func invalidateCanonicalRecord() {
        modelContext = nil
        responseBody.invalidateCanonicalOwner()
    }

    private func applyCanonicalCurrentHop(
        _ hop: CanonicalNetworkCurrentHop
    ) {
        let response = hop.response?.proxyValue
        let request = hop.request.proxyValue(
            overridingHeaders: response?.requestHeaders
        )
        currentRequest = request
        url = request.url
        method = request.method
        resourceType = hop.resourceType.map(Network.ResourceType.init(rawValue:))
        status = response?.status
        statusText = response?.statusText
        responseURL = response?.url
        mimeType = response?.mimeType
        responseSource = response?.source?.rawValue
        sourceMapURL = hop.sourceMapURL
        requestHeaders = request.headers
        responseHeaders = response?.headers ?? [:]
        requestSentTimestamp = hop.requestSentTimestamp
        responseReceivedTimestamp = hop.responseReceivedTimestamp
        applyCanonicalTransfer(hop.transfer)
        finishedOrFailedTimestamp = hop.terminalTimestamp
        metrics = hop.metrics?.proxyValue
        requestBody = NetworkBody.makeRequestBody(for: request)
        wasServedFromMemoryCache = hop.servedFromMemoryCache
        if resourceType != .webSocket {
            webSocket = nil
        }
    }

    private func applyCanonicalTransfer(
        _ transfer: CanonicalNetworkTransfer
    ) {
        decodedDataLength = transfer.decodedDataLength
        encodedDataLength = transfer.encodedDataLength
        lastDataReceivedTimestamp = transfer.lastDataReceivedTimestamp
    }

    private func applyCanonicalTerminalBodyState(
        _ lifecycle: CanonicalNetworkLifecycle
    ) {
        guard case let .failed(errorText, canceled) = lifecycle else {
            return
        }
        responseBody.failResponseFetch(
            .loadingFailed(errorText: errorText, canceled: canceled)
        )
    }

    private static func state(
        _ lifecycle: CanonicalNetworkLifecycle
    ) -> State {
        switch lifecycle {
        case .pending:
            .pending
        case .responded:
            .responded
        case .finished:
            .finished
        case let .failed(errorText, canceled):
            .failed(errorText: errorText, canceled: canceled)
        }
    }

    private func requestPreservingCurrentURLIfNeeded(_ request: Network.Request) -> Network.Request {
        guard request.url.isEmpty, currentRequest.url.isEmpty == false else {
            return request
        }
        return Network.Request(
            id: request.id,
            url: currentRequest.url,
            method: request.method,
            headers: request.headers,
            postData: request.postData,
            referrerPolicy: request.referrerPolicy,
            integrity: request.integrity,
            backendResourceIdentifier: request.backendResourceIdentifier
        )
    }

    private func requestWithURL(_ url: String) -> Network.Request {
        Network.Request(
            id: currentRequest.id,
            url: url,
            method: currentRequest.method,
            headers: currentRequest.headers,
            postData: currentRequest.postData,
            referrerPolicy: currentRequest.referrerPolicy,
            integrity: currentRequest.integrity,
            backendResourceIdentifier: currentRequest.backendResourceIdentifier
        )
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
            integrity: currentRequest.integrity,
            backendResourceIdentifier: currentRequest.backendResourceIdentifier
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

    package static func resourceCategory(
        resourceType: Network.ResourceType?,
        mimeType: String?,
        url: String,
        hasResponse: Bool
    ) -> ResourceCategory {
        let resourceTypeRawValue = resourceType?.rawValue.lowercased()
        let normalizedMIMEType = normalizedMIMEType(mimeType)
        let pathExtension = pathExtension(in: url)

        if hasResponse {
            if isPreviewableImage(mimeType: normalizedMIMEType, pathExtension: "") {
                return .image
            }
            if isPreviewableMedia(mimeType: normalizedMIMEType, pathExtension: "") {
                return .media
            }
        }

        switch resourceTypeRawValue {
        case "document":
            return .document
        case "stylesheet":
            return .stylesheet
        case "script":
            return .script
        case "font":
            return .font
        case "websocket":
            return .webSocket
        default:
            break
        }

        if hasResponse || resourceTypeRawValue == nil {
            if isPreviewableImage(mimeType: normalizedMIMEType, pathExtension: pathExtension) {
                return .image
            }
            if isPreviewableMedia(mimeType: normalizedMIMEType, pathExtension: pathExtension) {
                return .media
            }
        }
        switch resourceTypeRawValue {
        case "image":
            return .image
        case "media":
            return .media
        case "xhr", "fetch", "ping", "beacon", "eventsource":
            return .xhrFetch
        default:
            break
        }

        if normalizedMIMEType == "text/css" || pathExtension == "css" {
            return .stylesheet
        }
        if normalizedMIMEType.contains("javascript") || ["js", "mjs", "cjs"].contains(pathExtension) {
            return .script
        }
        if normalizedMIMEType.hasPrefix("image/"), normalizedMIMEType != "image/svg+xml" {
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

    package static func effectiveMIMEType(mimeType: String?, headers: [String: String]) -> String? {
        if let mimeType, mimeType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return mimeType
        }
        guard let contentType = headers.first(where: { key, _ in
            key.caseInsensitiveCompare("content-type") == .orderedSame
        })?.value else {
            return nil
        }
        return contentType
    }

    private static func normalizedMIMEType(_ mimeType: String?) -> String {
        mimeType?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static func isPreviewableImage(mimeType: String, pathExtension: String) -> Bool {
        knownPreviewableImageMIMETypes.contains(mimeType)
            || knownPreviewableImagePathExtensions.contains(pathExtension)
    }

    private static func isPreviewableMedia(mimeType: String, pathExtension: String) -> Bool {
        isHLSMIMEType(mimeType)
            || knownPreviewableMediaMIMETypes.contains(mimeType)
            || pathExtension == "m3u8"
            || knownPreviewableMediaPathExtensions.contains(pathExtension)
    }

    private static func isHLSMIMEType(_ mimeType: String) -> Bool {
        switch mimeType {
        case "application/vnd.apple.mpegurl", "application/x-mpegurl", "application/mpegurl",
             "audio/mpegurl", "audio/x-mpegurl":
            true
        default:
            false
        }
    }

    package static func urlSearchText(_ rawURL: String) -> String {
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

    package static func pathExtension(in rawURL: String) -> String {
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

    private static let knownPreviewableImageMIMETypes: Set<String> = [
        "image/apng",
        "image/avif",
        "image/bmp",
        "image/gif",
        "image/heic",
        "image/heif",
        "image/jpeg",
        "image/jpg",
        "image/pjpeg",
        "image/png",
        "image/tiff",
        "image/webp",
        "image/x-png",
    ]

    private static let knownPreviewableMediaMIMETypes: Set<String> = [
        "audio/aac",
        "audio/aiff",
        "audio/mp3",
        "audio/mp4",
        "audio/mpeg",
        "audio/wav",
        "audio/x-aiff",
        "audio/x-m4a",
        "audio/x-wav",
        "video/mp4",
        "video/quicktime",
        "video/x-m4v",
    ]

    private static let knownPreviewableImagePathExtensions: Set<String> = [
        "apng",
        "avif",
        "bmp",
        "gif",
        "heic",
        "heif",
        "jpg",
        "jpeg",
        "png",
        "tif",
        "tiff",
        "webp",
    ]

    private static let knownPreviewableMediaPathExtensions: Set<String> = [
        "aac",
        "aif",
        "aiff",
        "caf",
        "m4a",
        "m4v",
        "mov",
        "mp3",
        "mp4",
        "wav",
    ]

    package static func uniqueNonEmpty(_ values: [String?]) -> [String] {
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
