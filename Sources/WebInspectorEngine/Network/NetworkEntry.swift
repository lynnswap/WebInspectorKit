import Foundation
import Observation

@MainActor
@Observable
public final class NetworkEntry: Identifiable, Equatable, Hashable {
    public static nonisolated func == (lhs: NetworkEntry, rhs: NetworkEntry) -> Bool { lhs.id == rhs.id }
    public nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public enum Kind: String, Sendable {
        case resource
        case webSocket
    }

    public enum Phase: String,Sendable {
        case pending
        case completed
        case failed
    }

    public struct Identity {
        public let sessionID: String
        public let requestID: Int
        public let createdAt: Date

        package init(sessionID: String, requestID: Int, createdAt: Date) {
            self.sessionID = sessionID
            self.requestID = requestID
            self.createdAt = createdAt
        }
    }

    public struct Request {
        public let url: String
        public let method: String
        public let headers: NetworkHeaders
        public let body: NetworkBody?
        public let bodyBytesSent: Int?
        public let type: String?
        public let wallTime: TimeInterval?

        package init(
            url: String,
            method: String,
            headers: NetworkHeaders,
            body: NetworkBody?,
            bodyBytesSent: Int?,
            type: String?,
            wallTime: TimeInterval?
        ) {
            self.url = url
            self.method = method
            self.headers = headers
            self.body = body
            self.bodyBytesSent = bodyBytesSent
            self.type = type
            self.wallTime = wallTime
        }
    }

    public struct Response {
        public let statusCode: Int?
        public let statusText: String
        public let mimeType: String?
        public let headers: NetworkHeaders
        public let body: NetworkBody?
        public let blockedCookies: [String]
        public let errorDescription: String?

        package init(
            statusCode: Int?,
            statusText: String,
            mimeType: String?,
            headers: NetworkHeaders,
            body: NetworkBody?,
            blockedCookies: [String],
            errorDescription: String?
        ) {
            self.statusCode = statusCode
            self.statusText = statusText
            self.mimeType = mimeType
            self.headers = headers
            self.body = body
            self.blockedCookies = blockedCookies
            self.errorDescription = errorDescription
        }
    }

    public struct Transfer {
        public let startTimestamp: TimeInterval
        public let endTimestamp: TimeInterval?
        public let duration: TimeInterval?
        public let encodedBodyLength: Int?
        public let decodedBodyLength: Int?
        public let phase: Phase

        package init(
            startTimestamp: TimeInterval,
            endTimestamp: TimeInterval?,
            duration: TimeInterval?,
            encodedBodyLength: Int?,
            decodedBodyLength: Int?,
            phase: Phase
        ) {
            self.startTimestamp = startTimestamp
            self.endTimestamp = endTimestamp
            self.duration = duration
            self.encodedBodyLength = encodedBodyLength
            self.decodedBodyLength = decodedBodyLength
            self.phase = phase
        }
    }

    package enum BodySyntaxKind: Hashable, Sendable {
        case plainText
        case json
        case html
        case xml
        case css
        case javascript
    }

    public struct WebSocket: Hashable, Sendable {
        public enum ReadyState: String, Sendable {
            case connecting
            case open
            case closed
        }

        public struct Frame: Hashable, Sendable {
            public enum Direction: String, Sendable {
                case incoming
                case outgoing
            }

            public let direction: Direction
            public let opcode: Int
            public let payload: String?
            public let payloadIsBase64: Bool
            public let payloadSize: Int?
            public let payloadTruncated: Bool
            public let timestamp: TimeInterval

            package init(
                direction: Direction,
                opcode: Int,
                payload: String?,
                payloadIsBase64: Bool,
                payloadSize: Int?,
                payloadTruncated: Bool,
                timestamp: TimeInterval
            ) {
                self.direction = direction
                self.opcode = opcode
                self.payload = payload
                self.payloadIsBase64 = payloadIsBase64
                self.payloadSize = payloadSize
                self.payloadTruncated = payloadTruncated
                self.timestamp = timestamp
            }
        }

        public internal(set) var readyState: ReadyState
        public internal(set) var frames: [Frame]
        public internal(set) var closeCode: Int?
        public internal(set) var closeReason: String?
        public internal(set) var closeWasClean: Bool?

        public init(
            readyState: ReadyState = .connecting,
            frames: [Frame] = [],
            closeCode: Int? = nil,
            closeReason: String? = nil,
            closeWasClean: Bool? = nil
        ) {
            self.readyState = readyState
            self.frames = frames
            self.closeCode = closeCode
            self.closeReason = closeReason
            self.closeWasClean = closeWasClean
        }

        mutating func appendFrame(_ frame: Frame) {
            frames.append(frame)
        }

        mutating func applyClose(code: Int?, reason: String?, wasClean: Bool?) {
            readyState = .closed
            if let code {
                closeCode = code
            }
            if let reason {
                closeReason = reason
            }
            if let wasClean {
                closeWasClean = wasClean
            }
        }
    }

    public struct Snapshot {
        public let sessionID: String
        public let requestID: Int
        public let request: Request
        public let response: Response
        public let transfer: Transfer

        package init(
            sessionID: String,
            requestID: Int,
            request: Request,
            response: Response,
            transfer: Transfer
        ) {
            self.sessionID = sessionID
            self.requestID = requestID
            self.request = request
            self.response = response
            self.transfer = transfer
        }
    }

    public enum Update {
        public struct RequestStarted {
            public let requestID: Int
            public let request: Request
            public let timestamp: TimeInterval

            package init(requestID: Int, request: Request, timestamp: TimeInterval) {
                self.requestID = requestID
                self.request = request
                self.timestamp = timestamp
            }
        }

        public struct ResponseReceived {
            public let requestID: Int
            public let response: Response
            public let requestType: String?
            public let timestamp: TimeInterval

            package init(requestID: Int, response: Response, requestType: String?, timestamp: TimeInterval) {
                self.requestID = requestID
                self.response = response
                self.requestType = requestType
                self.timestamp = timestamp
            }
        }

        public struct Completed {
            public let requestID: Int
            public let response: Response
            public let requestType: String?
            public let timestamp: TimeInterval
            public let encodedBodyLength: Int?
            public let decodedBodyLength: Int?

            package init(
                requestID: Int,
                response: Response,
                requestType: String?,
                timestamp: TimeInterval,
                encodedBodyLength: Int?,
                decodedBodyLength: Int?
            ) {
                self.requestID = requestID
                self.response = response
                self.requestType = requestType
                self.timestamp = timestamp
                self.encodedBodyLength = encodedBodyLength
                self.decodedBodyLength = decodedBodyLength
            }
        }

        public struct Failed {
            public let requestID: Int
            public let response: Response
            public let requestType: String?
            public let timestamp: TimeInterval

            package init(requestID: Int, response: Response, requestType: String?, timestamp: TimeInterval) {
                self.requestID = requestID
                self.response = response
                self.requestType = requestType
                self.timestamp = timestamp
            }
        }

        public struct ResourceTimingSnapshot {
            public let requestID: Int
            public let request: Request
            public let response: Response
            public let startTimestamp: TimeInterval
            public let endTimestamp: TimeInterval?
            public let encodedBodyLength: Int?
            public let decodedBodyLength: Int?

            package init(
                requestID: Int,
                request: Request,
                response: Response,
                startTimestamp: TimeInterval,
                endTimestamp: TimeInterval?,
                encodedBodyLength: Int?,
                decodedBodyLength: Int?
            ) {
                self.requestID = requestID
                self.request = request
                self.response = response
                self.startTimestamp = startTimestamp
                self.endTimestamp = endTimestamp
                self.encodedBodyLength = encodedBodyLength
                self.decodedBodyLength = decodedBodyLength
            }
        }

        public struct WebSocketOpened {
            public let requestID: Int
            public let url: String
            public let timestamp: TimeInterval
            public let wallTime: TimeInterval?

            package init(requestID: Int, url: String, timestamp: TimeInterval, wallTime: TimeInterval?) {
                self.requestID = requestID
                self.url = url
                self.timestamp = timestamp
                self.wallTime = wallTime
            }
        }

        public struct WebSocketHandshake {
            public let requestID: Int
            public let requestHeaders: NetworkHeaders?
            public let statusCode: Int?
            public let statusText: String?

            package init(requestID: Int, requestHeaders: NetworkHeaders?, statusCode: Int?, statusText: String?) {
                self.requestID = requestID
                self.requestHeaders = requestHeaders
                self.statusCode = statusCode
                self.statusText = statusText
            }
        }

        public struct WebSocketFrameAdded {
            public let requestID: Int
            public let frame: WebSocket.Frame

            package init(requestID: Int, frame: WebSocket.Frame) {
                self.requestID = requestID
                self.frame = frame
            }
        }

        public struct WebSocketClosed {
            public let requestID: Int
            public let timestamp: TimeInterval
            public let statusCode: Int?
            public let statusText: String?
            public let closeCode: Int?
            public let closeReason: String?
            public let closeWasClean: Bool?
            public let errorDescription: String?
            public let failed: Bool

            package init(
                requestID: Int,
                timestamp: TimeInterval,
                statusCode: Int?,
                statusText: String?,
                closeCode: Int?,
                closeReason: String?,
                closeWasClean: Bool?,
                errorDescription: String?,
                failed: Bool
            ) {
                self.requestID = requestID
                self.timestamp = timestamp
                self.statusCode = statusCode
                self.statusText = statusText
                self.closeCode = closeCode
                self.closeReason = closeReason
                self.closeWasClean = closeWasClean
                self.errorDescription = errorDescription
                self.failed = failed
            }
        }

        case requestStarted(RequestStarted)
        case responseReceived(ResponseReceived)
        case completed(Completed)
        case failed(Failed)
        case resourceTimingSnapshot(ResourceTimingSnapshot)
        case webSocketOpened(WebSocketOpened)
        case webSocketHandshake(WebSocketHandshake)
        case webSocketFrameAdded(WebSocketFrameAdded)
        case webSocketClosed(WebSocketClosed)

        public var requestID: Int {
            switch self {
            case .requestStarted(let value): value.requestID
            case .responseReceived(let value): value.requestID
            case .completed(let value): value.requestID
            case .failed(let value): value.requestID
            case .resourceTimingSnapshot(let value): value.requestID
            case .webSocketOpened(let value): value.requestID
            case .webSocketHandshake(let value): value.requestID
            case .webSocketFrameAdded(let value): value.requestID
            case .webSocketClosed(let value): value.requestID
            }
        }

        public var kind: Kind {
            switch self {
            case .webSocketOpened, .webSocketHandshake, .webSocketFrameAdded, .webSocketClosed:
                .webSocket
            default:
                .resource
            }
        }
    }

    nonisolated public let id: UUID

    public private(set) var sessionID: String
    nonisolated public let requestID: Int
    nonisolated public let createdAt: Date

    public internal(set) var url: String
    public internal(set) var method: String
    public internal(set) var statusCode: Int?
    public internal(set) var statusText: String
    public internal(set) var mimeType: String?
    public internal(set) var fileTypeLabel: String
    public internal(set) var resourceFilter: NetworkResourceFilter
    public internal(set) var requestHeaders: NetworkHeaders
    public internal(set) var responseHeaders: NetworkHeaders
    public internal(set) var startTimestamp: TimeInterval
    public internal(set) var endTimestamp: TimeInterval?
    public internal(set) var duration: TimeInterval?
    public internal(set) var encodedBodyLength: Int?
    public internal(set) var decodedBodyLength: Int?
    public internal(set) var errorDescription: String?
    public internal(set) var requestType: String?
    public internal(set) var requestBodyBytesSent: Int?
    public internal(set) var wallTime: TimeInterval?
    public internal(set) var phase: Phase
    public internal(set) var requestBody: NetworkBody?
    public internal(set) var responseBody: NetworkBody?
    public internal(set) var webSocket: WebSocket?

    public var kind: Kind {
        webSocket == nil ? .resource : .webSocket
    }

    public var identity: Identity {
        Identity(sessionID: sessionID, requestID: requestID, createdAt: createdAt)
    }

    public var request: Request {
        Request(
            url: url,
            method: method,
            headers: requestHeaders,
            body: requestBody,
            bodyBytesSent: requestBodyBytesSent,
            type: requestType,
            wallTime: wallTime
        )
    }

    public var response: Response {
        Response(
            statusCode: statusCode,
            statusText: statusText,
            mimeType: mimeType,
            headers: responseHeaders,
            body: responseBody,
            blockedCookies: [],
            errorDescription: errorDescription
        )
    }

    public var transfer: Transfer {
        Transfer(
            startTimestamp: startTimestamp,
            endTimestamp: endTimestamp,
            duration: duration,
            encodedBodyLength: encodedBodyLength,
            decodedBodyLength: decodedBodyLength,
            phase: phase
        )
    }

    init(
        sessionID: String,
        requestID: Int,
        url: String,
        method: String,
        requestHeaders: NetworkHeaders,
        startTimestamp: TimeInterval,
        wallTime: TimeInterval?
    ) {
        self.id = UUID()
        self.sessionID = sessionID
        self.requestID = requestID
        self.createdAt = Date()

        self.url = url
        self.method = method
        self.requestHeaders = requestHeaders
        self.responseHeaders = NetworkHeaders()
        self.startTimestamp = startTimestamp
        self.wallTime = wallTime
        self.statusCode = nil
        self.statusText = ""
        self.mimeType = nil
        self.fileTypeLabel = "-"
        self.resourceFilter = .other
        self.endTimestamp = nil
        self.duration = nil
        self.encodedBodyLength = nil
        self.decodedBodyLength = nil
        self.errorDescription = nil
        self.requestType = nil
        self.requestBodyBytesSent = nil
        self.phase = .pending
        self.requestBody = nil
        self.responseBody = nil
        self.webSocket = nil
        refreshFileTypeLabel()
    }

    convenience init(snapshot: Snapshot) {
        self.init(
            sessionID: snapshot.sessionID,
            requestID: snapshot.requestID,
            url: snapshot.request.url,
            method: snapshot.request.method,
            requestHeaders: snapshot.request.headers,
            startTimestamp: snapshot.transfer.startTimestamp,
            wallTime: snapshot.request.wallTime
        )
        responseHeaders = snapshot.response.headers
        statusCode = snapshot.response.statusCode
        statusText = snapshot.response.statusText
        mimeType = snapshot.response.mimeType
        encodedBodyLength = snapshot.transfer.encodedBodyLength
        decodedBodyLength = snapshot.transfer.decodedBodyLength ?? snapshot.response.body?.size
        errorDescription = snapshot.response.errorDescription
        requestType = snapshot.request.type
        requestBodyBytesSent = snapshot.request.bodyBytesSent ?? snapshot.request.body?.size
        requestBody = snapshot.request.body
        requestBody?.role = .request
        responseBody = snapshot.response.body
        responseBody?.role = .response
        phase = snapshot.transfer.phase
        endTimestamp = snapshot.transfer.endTimestamp
        duration = snapshot.transfer.duration
        refreshFileTypeLabel()
    }

    convenience init(sessionID: String, update: Update) {
        switch update {
        case .requestStarted(let value):
            self.init(
                sessionID: sessionID,
                requestID: value.requestID,
                url: value.request.url,
                method: value.request.method,
                requestHeaders: value.request.headers,
                startTimestamp: value.timestamp,
                wallTime: value.request.wallTime,
                requestType: value.request.type,
                requestBody: value.request.body,
                requestBodyBytesSent: value.request.bodyBytesSent
            )
        case .resourceTimingSnapshot(let value):
            self.init(
                sessionID: sessionID,
                requestID: value.requestID,
                url: value.request.url,
                method: value.request.method.isEmpty ? "GET" : value.request.method,
                requestHeaders: value.request.headers,
                startTimestamp: value.startTimestamp,
                wallTime: value.request.wallTime,
                requestType: value.request.type,
                requestBody: value.request.body,
                requestBodyBytesSent: value.request.bodyBytesSent
            )
            apply(update)
        case .webSocketOpened(let value):
            self.init(
                sessionID: sessionID,
                requestID: value.requestID,
                url: value.url,
                method: "GET",
                requestHeaders: NetworkHeaders(),
                startTimestamp: value.timestamp,
                wallTime: value.wallTime,
                requestType: "websocket",
                requestBody: nil,
                requestBodyBytesSent: nil
            )
            webSocket = WebSocket()
            refreshFileTypeLabel()
        case .responseReceived, .completed, .failed, .webSocketHandshake, .webSocketFrameAdded, .webSocketClosed:
            self.init(
                sessionID: sessionID,
                requestID: update.requestID,
                url: "",
                method: "UNKNOWN",
                requestHeaders: NetworkHeaders(),
                startTimestamp: 0,
                wallTime: nil,
                requestType: nil,
                requestBody: nil,
                requestBodyBytesSent: nil
            )
            apply(update)
        }
    }

    convenience init(
        sessionID: String,
        requestID: Int,
        url: String,
        method: String,
        requestHeaders: NetworkHeaders,
        startTimestamp: TimeInterval,
        wallTime: TimeInterval?,
        requestType: String?,
        requestBody: NetworkBody?,
        requestBodyBytesSent: Int?
    ) {
        self.init(
            sessionID: sessionID,
            requestID: requestID,
            url: url,
            method: method,
            requestHeaders: requestHeaders,
            startTimestamp: startTimestamp,
            wallTime: wallTime
        )
        self.requestType = requestType
        self.requestBody = requestBody
        self.requestBody?.role = .request
        self.requestBodyBytesSent = requestBodyBytesSent ?? requestBody?.size
        refreshFileTypeLabel()
    }

    func applyRequestStart(
        url: String?,
        method: String?,
        requestHeaders: NetworkHeaders,
        requestType: String?,
        requestBody: NetworkBody?,
        requestBodyBytesSent: Int?,
        startTimestamp: TimeInterval,
        wallTime: TimeInterval?
    ) {
        if let url {
            self.url = url
        }
        if let method, !method.isEmpty {
            self.method = method
        }
        if !requestHeaders.isEmpty {
            self.requestHeaders = requestHeaders
        }
        if let requestType {
            self.requestType = requestType
        }
        if let requestBody {
            if let existingRequestBody = self.requestBody,
               existingRequestBody.hasDeferredContent,
               requestBody.hasDeferredContent {
                existingRequestBody.role = .request
                existingRequestBody.adoptDeferredNetworkRequestTarget(from: requestBody)
            } else {
                self.requestBody = requestBody
                self.requestBody?.role = .request
            }
        }
        if let requestBodyBytesSent = requestBodyBytesSent ?? requestBody?.size {
            self.requestBodyBytesSent = requestBodyBytesSent
        }
        if let wallTime {
            self.wallTime = wallTime
        }
        if self.startTimestamp > startTimestamp {
            self.startTimestamp = startTimestamp
        }
        phase = .pending
        refreshFileTypeLabel()
    }

    func applyResponse(
        statusCode: Int?,
        statusText: String?,
        mimeType: String?,
        responseHeaders: NetworkHeaders,
        requestType: String?,
        timestamp: TimeInterval,
        blockedCookies: [String] = []
    ) {
        if startTimestamp > timestamp {
            startTimestamp = timestamp
        }
        self.statusCode = statusCode
        self.statusText = statusText ?? ""
        self.mimeType = mimeType
        if !responseHeaders.isEmpty {
            self.responseHeaders = responseHeaders
        }
        if !blockedCookies.isEmpty {
            self.responseHeaders.append(
                NetworkHeaderField(
                    name: "blocked-cookies",
                    value: blockedCookies.joined(separator: ",")
                )
            )
        }
        if let requestType {
            self.requestType = requestType
        }
        refreshFileTypeLabel()
        phase = .pending
    }

    func applyCompletion(
        statusCode: Int?,
        statusText: String?,
        mimeType: String?,
        encodedBodyLength: Int?,
        decodedBodySize: Int?,
        errorDescription: String?,
        requestType: String?,
        responseBody: NetworkBody?,
        timestamp: TimeInterval,
        failed: Bool
    ) {
        if startTimestamp > timestamp {
            startTimestamp = timestamp
        }
        if let statusCode {
            self.statusCode = statusCode
        }
        if let statusText {
            self.statusText = statusText
        }
        if let mimeType {
            self.mimeType = mimeType
        }
        if let encodedBodyLength {
            self.encodedBodyLength = encodedBodyLength
        }
        if let decodedBodySize {
            self.decodedBodyLength = decodedBodySize
        } else if let responseBody {
            self.decodedBodyLength = responseBody.size
        }
        endTimestamp = timestamp
        duration = max(0, timestamp - startTimestamp)
        if let requestType {
            self.requestType = requestType
        }
        if let responseBody {
            self.responseBody = responseBody
            self.responseBody?.role = .response
        } else if failed {
            self.responseBody = nil
        }
        self.errorDescription = errorDescription
        refreshFileTypeLabel()
        phase = failed ? .failed : .completed
        if failed && self.statusCode == nil {
            self.statusCode = 0
        }
    }

    func apply(_ update: Update) {
        switch update {
        case .requestStarted(let value):
            applyRequestStart(
                url: value.request.url,
                method: value.request.method,
                requestHeaders: value.request.headers,
                requestType: value.request.type,
                requestBody: value.request.body,
                requestBodyBytesSent: value.request.bodyBytesSent,
                startTimestamp: value.timestamp,
                wallTime: value.request.wallTime
            )
        case .responseReceived(let value):
            applyResponse(
                statusCode: value.response.statusCode,
                statusText: value.response.statusText,
                mimeType: value.response.mimeType,
                responseHeaders: value.response.headers,
                requestType: value.requestType,
                timestamp: value.timestamp,
                blockedCookies: value.response.blockedCookies
            )
        case .completed(let value):
            applyCompletion(
                statusCode: value.response.statusCode,
                statusText: value.response.statusText,
                mimeType: value.response.mimeType,
                encodedBodyLength: value.encodedBodyLength,
                decodedBodySize: value.decodedBodyLength,
                errorDescription: value.response.errorDescription,
                requestType: value.requestType,
                responseBody: value.response.body,
                timestamp: value.timestamp,
                failed: false
            )
        case .failed(let value):
            applyCompletion(
                statusCode: value.response.statusCode,
                statusText: value.response.statusText,
                mimeType: value.response.mimeType,
                encodedBodyLength: nil,
                decodedBodySize: nil,
                errorDescription: value.response.errorDescription,
                requestType: value.requestType,
                responseBody: value.response.body,
                timestamp: value.timestamp,
                failed: true
            )
        case .resourceTimingSnapshot(let value):
            applyRequestStart(
                url: value.request.url.isEmpty ? nil : value.request.url,
                method: value.request.method.isEmpty ? nil : value.request.method,
                requestHeaders: value.request.headers,
                requestType: value.request.type,
                requestBody: value.request.body,
                requestBodyBytesSent: value.request.bodyBytesSent,
                startTimestamp: value.startTimestamp,
                wallTime: value.request.wallTime
            )
            applyResponse(
                statusCode: value.response.statusCode,
                statusText: value.response.statusText,
                mimeType: value.response.mimeType,
                responseHeaders: value.response.headers,
                requestType: value.request.type,
                timestamp: value.startTimestamp,
                blockedCookies: value.response.blockedCookies
            )
            applyCompletion(
                statusCode: value.response.statusCode,
                statusText: value.response.statusText,
                mimeType: value.response.mimeType,
                encodedBodyLength: value.encodedBodyLength,
                decodedBodySize: value.decodedBodyLength,
                errorDescription: value.response.errorDescription,
                requestType: value.request.type,
                responseBody: value.response.body,
                timestamp: value.endTimestamp ?? value.startTimestamp,
                failed: false
            )
        case .webSocketOpened(let value):
            requestType = "websocket"
            if startTimestamp > value.timestamp {
                startTimestamp = value.timestamp
            }
            if let wallTime = value.wallTime {
                self.wallTime = wallTime
            }
            if url.isEmpty {
                url = value.url
            }
            method = "GET"
            webSocket = webSocket ?? WebSocket()
            phase = .pending
            refreshFileTypeLabel()
        case .webSocketHandshake(let value):
            if let requestHeaders = value.requestHeaders {
                applyWebSocketHandshakeRequest(headers: requestHeaders)
            }
            if value.statusCode != nil || value.statusText != nil {
                applyWebSocketHandshakeResponse(
                    statusCode: value.statusCode,
                    statusText: value.statusText
                )
            }
        case .webSocketFrameAdded(let value):
            appendWebSocketFrame(frame: value.frame)
        case .webSocketClosed(let value):
            applyWebSocketCompletion(
                statusCode: value.statusCode,
                statusText: value.statusText,
                closeCode: value.closeCode,
                closeReason: value.closeReason,
                closeWasClean: value.closeWasClean,
                errorDescription: value.errorDescription,
                timestamp: value.timestamp,
                failed: value.failed
            )
        }
    }

    public func applyFetchedBodySizeMetadata(from body: NetworkBody) {
        guard let resolvedSize = body.size ?? body.full?.count ?? body.preview?.count else {
            return
        }

        switch body.role {
        case .request:
            requestBodyBytesSent = resolvedSize
        case .response:
            decodedBodyLength = resolvedSize
        }
    }

    package func applyFetchedBody(_ fetched: NetworkBody, to target: NetworkBody) {
        if let fullText = fetched.full ?? fetched.preview, !fullText.isEmpty {
            target.applyFullBody(
                fullText,
                isBase64Encoded: fetched.isBase64Encoded,
                isTruncated: fetched.isTruncated,
                size: fetched.size ?? fullText.count
            )
        }

        target.summary = fetched.summary ?? target.summary
        target.formEntries = fetched.formEntries
        target.kind = fetched.kind
        target.isTruncated = fetched.isTruncated
        target.isBase64Encoded = fetched.isBase64Encoded
        target.fetchState = .full
        if let size = target.size ?? target.full?.count ?? target.preview?.count {
            target.size = size
        }
        applyFetchedBodySizeMetadata(from: target)
    }

    package func moveSession(to sessionID: String) {
        self.sessionID = sessionID
    }

    package func rebindDeferredBodyTargets(
        previousRequestTargetIdentifier: String?,
        requestTargetIdentifier: String?,
        previousResponseTargetIdentifier: String?,
        responseTargetIdentifier: String?
    ) {
        requestBody?.rebindDeferredTarget(
            from: previousRequestTargetIdentifier,
            to: requestTargetIdentifier
        )
        responseBody?.rebindDeferredTarget(
            from: previousResponseTargetIdentifier,
            to: responseTargetIdentifier
        )
    }

    func refreshFileTypeLabel() {
        fileTypeLabel = Self.makeFileTypeLabel(
            mimeType: mimeType,
            url: url,
            requestType: requestType
        )
        resourceFilter = Self.makeResourceFilter(
            mimeType: mimeType,
            url: url,
            requestType: requestType
        )
    }

    private static func makeFileTypeLabel(
        mimeType: String?,
        url: String,
        requestType: String?
    ) -> String {
        if let mimeType, !mimeType.isEmpty {
            let trimmed = mimeType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first ?? ""
            if let subtype = trimmed.split(separator: "/").last, !subtype.isEmpty {
                return subtype.lowercased()
            }
        }
        if let pathExtension = URL(string: url)?.pathExtension, !pathExtension.isEmpty {
            return pathExtension.lowercased()
        }
        if let requestType, !requestType.isEmpty {
            return requestType
        }
        return "-"
    }

    private static func makeResourceFilter(
        mimeType: String?,
        url: String,
        requestType: String?
    ) -> NetworkResourceFilter {
        let normalizedRequestType = requestType?.lowercased() ?? ""
        let normalizedMimeType = normalizedMimeType(mimeType)
        let pathExtension = normalizedPathExtension(url)

        if xhrRequestTypes.contains(normalizedRequestType) {
            return .xhrFetch
        }
        if documentRequestTypes.contains(normalizedRequestType)
            || documentMimeTypes.contains(normalizedMimeType)
            || documentExtensions.contains(pathExtension) {
            return .document
        }
        if stylesheetRequestTypes.contains(normalizedRequestType)
            || normalizedMimeType == "text/css"
            || pathExtension == "css" {
            return .stylesheet
        }
        if scriptRequestTypes.contains(normalizedRequestType)
            || scriptMimeTokens.contains(where: { normalizedMimeType.contains($0) })
            || scriptExtensions.contains(pathExtension) {
            return .script
        }
        if fontRequestTypes.contains(normalizedRequestType)
            || fontMimePrefixes.contains(where: { normalizedMimeType.hasPrefix($0) })
            || fontExtensions.contains(pathExtension) {
            return .font
        }
        if imageRequestTypes.contains(normalizedRequestType)
            || normalizedMimeType.hasPrefix("image/")
            || imageExtensions.contains(pathExtension) {
            return .image
        }
        return .other
    }

    package func bodyContentType(for role: NetworkBody.Role) -> String? {
        switch role {
        case .request:
            requestHeaders["content-type"]
        case .response:
            responseHeaders["content-type"] ?? mimeType
        }
    }

    package func isURLEncodedFormBody(for role: NetworkBody.Role) -> Bool {
        Self.isURLEncodedFormContentType(bodyContentType(for: role))
    }

    package func bodySyntaxKind(for role: NetworkBody.Role) -> BodySyntaxKind {
        Self.bodySyntaxKind(
            contentType: bodyContentType(for: role),
            url: url
        )
    }

    package static func bodySyntaxKind(
        contentType: String?,
        url: String
    ) -> BodySyntaxKind {
        let normalizedContentType = normalizedMimeType(contentType)
        let pathExtension = normalizedPathExtension(url)

        if isJSONContentType(normalizedContentType) || pathExtension == "json" {
            return .json
        }
        if documentMimeTypes.contains(normalizedContentType)
            || documentExtensions.contains(pathExtension) {
            return .html
        }
        if isXMLContentType(normalizedContentType) || pathExtension == "xml" {
            return .xml
        }
        if normalizedContentType == "text/css" || pathExtension == "css" {
            return .css
        }
        if scriptMimeTokens.contains(where: { normalizedContentType.contains($0) })
            || scriptExtensions.contains(pathExtension) {
            return .javascript
        }
        return .plainText
    }

    package static func isURLEncodedFormContentType(_ contentType: String?) -> Bool {
        normalizedMimeType(contentType) == "application/x-www-form-urlencoded"
    }

    func applyWebSocketHandshakeRequest(headers: NetworkHeaders) {
        if !headers.isEmpty {
            requestHeaders = headers
        }
        webSocket = webSocket ?? WebSocket()
        phase = .pending
    }

    func applyWebSocketHandshakeResponse(statusCode: Int?, statusText: String?) {
        if let statusCode {
            self.statusCode = statusCode
        }
        if let statusText {
            self.statusText = statusText
        }
        if webSocket == nil {
            webSocket = WebSocket()
        }
        webSocket?.readyState = .open
        phase = .pending
    }

    // NOTE: When re-enabling WebSocket capture, ensure this does not mark the entry as completed
    // for every frame. Keep the phase pending until close/error to reflect the live connection state.
    func appendWebSocketFrame(frame: WebSocket.Frame) {
        if webSocket == nil {
            webSocket = WebSocket(readyState: .open)
        }
        webSocket?.appendFrame(frame)
        phase = .pending
    }

    func applyWebSocketCompletion(
        statusCode: Int?,
        statusText: String?,
        closeCode: Int?,
        closeReason: String?,
        closeWasClean: Bool?,
        errorDescription: String?,
        timestamp: TimeInterval,
        failed: Bool
    ) {
        if let statusCode, self.statusCode == nil {
            self.statusCode = statusCode
        }
        if let statusText, self.statusText.isEmpty {
            self.statusText = statusText
        }
        if webSocket == nil {
            webSocket = WebSocket()
        }
        webSocket?.applyClose(
            code: closeCode,
            reason: closeReason,
            wasClean: closeWasClean
        )
        endTimestamp = timestamp
        duration = max(0, timestamp - startTimestamp)
        if let errorDescription {
            self.errorDescription = errorDescription
        }
        phase = failed ? .failed : .completed
        if failed && self.statusCode == nil {
            self.statusCode = 0
        }
    }
}

extension NetworkEntry {
    fileprivate static let xhrRequestTypes: Set<String> = ["fetch", "xhr", "xmlhttprequest"]
    fileprivate static let documentRequestTypes: Set<String> = ["document", "frame", "iframe"]
    fileprivate static let stylesheetRequestTypes: Set<String> = ["style", "css", "stylesheet", "link"]
    fileprivate static let scriptRequestTypes: Set<String> = ["script"]
    fileprivate static let fontRequestTypes: Set<String> = ["font"]
    fileprivate static let imageRequestTypes: Set<String> = ["img", "image"]
    fileprivate static let documentMimeTypes: Set<String> = ["text/html", "application/xhtml+xml"]
    fileprivate static let scriptMimeTokens: Set<String> = ["javascript", "ecmascript"]
    fileprivate static let fontMimePrefixes: Set<String> = [
        "font/",
        "application/font",
        "application/x-font",
        "application/vnd.ms-fontobject"
    ]
    fileprivate static let scriptExtensions: Set<String> = ["js", "mjs", "cjs"]
    fileprivate static let documentExtensions: Set<String> = ["html", "htm", "xhtml"]
    fileprivate static let imageExtensions: Set<String> = [
        "png",
        "jpg",
        "jpeg",
        "gif",
        "svg",
        "webp",
        "avif",
        "bmp",
        "tiff",
        "ico"
    ]
    fileprivate static let fontExtensions: Set<String> = ["woff", "woff2", "ttf", "otf", "eot"]

    fileprivate static func isJSONContentType(_ contentType: String) -> Bool {
        contentType == "application/json" || contentType.hasSuffix("+json")
    }

    fileprivate static func isXMLContentType(_ contentType: String) -> Bool {
        contentType == "application/xml" || contentType == "text/xml" || contentType.hasSuffix("+xml")
    }

    fileprivate static func normalizedMimeType(_ mimeType: String?) -> String {
        guard let mimeType, mimeType.isEmpty == false else { return "" }
        let trimmed = mimeType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first ?? ""
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    fileprivate static func normalizedPathExtension(_ url: String) -> String {
        guard let pathExtension = URL(string: url)?.pathExtension,
              pathExtension.isEmpty == false else {
            return ""
        }
        return pathExtension.lowercased()
    }
}

public typealias NetworkWebSocketFrame = NetworkEntry.WebSocket.Frame
public typealias NetworkWebSocketInfo = NetworkEntry.WebSocket
