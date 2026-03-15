import Foundation
import Observation

@MainActor
@Observable
public final class NetworkEntry: Identifiable, Equatable, Hashable {
    public static nonisolated func == (lhs: NetworkEntry, rhs: NetworkEntry) -> Bool { lhs.id == rhs.id }
    public nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public enum Phase: String,Sendable {
        case pending
        case completed
        case failed
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
    public internal(set) var webSocket: NetworkWebSocketInfo?

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

    convenience init(startPayload payload: HTTPNetworkEvent) {
        let fallbackMethod = payload.kind == .resourceTiming ? "GET" : "UNKNOWN"
        let method = (payload.method?.isEmpty == false ? payload.method : nil) ?? fallbackMethod
        let url = payload.url ?? ""
        self.init(
            sessionID: payload.sessionID,
            requestID: payload.requestID,
            url: url,
            method: method,
            requestHeaders: payload.requestHeaders,
            startTimestamp: payload.startTimeSeconds,
            wallTime: payload.wallTimeSeconds
        )
        requestType = payload.requestType
        requestBody = payload.requestBody
        requestBody?.role = .request
        requestBodyBytesSent = payload.requestBodyBytesSent ?? payload.requestBody?.size
        refreshFileTypeLabel()
    }

    convenience init(seed: NetworkEntrySeed) {
        self.init(
            sessionID: seed.sessionID,
            requestID: seed.requestID,
            url: seed.url,
            method: seed.method,
            requestHeaders: seed.requestHeaders,
            startTimestamp: seed.startTimestamp,
            wallTime: seed.wallTime
        )
        responseHeaders = seed.responseHeaders
        statusCode = seed.statusCode
        statusText = seed.statusText
        mimeType = seed.mimeType
        encodedBodyLength = seed.encodedBodyLength
        decodedBodyLength = seed.decodedBodyLength ?? seed.responseBody?.size
        errorDescription = seed.errorDescription
        requestType = seed.requestType
        requestBodyBytesSent = seed.requestBodyBytesSent ?? seed.requestBody?.size
        requestBody = seed.requestBody
        requestBody?.role = .request
        responseBody = seed.responseBody
        responseBody?.role = .response
        phase = seed.phase
        switch seed.phase {
        case .pending:
            endTimestamp = nil
            duration = nil
        case .completed, .failed:
            endTimestamp = seed.startTimestamp
            duration = 0
        }
        refreshFileTypeLabel()
    }

    func applyStartPayload(_ payload: HTTPNetworkEvent) {
        if let url = payload.url {
            self.url = url
        }
        if let method = payload.method, !method.isEmpty {
            self.method = method
        }
        if !payload.requestHeaders.isEmpty {
            requestHeaders = payload.requestHeaders
        }
        if let requestType = payload.requestType {
            self.requestType = requestType
        }
        if let requestBody = payload.requestBody {
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
        if let requestBodyBytesSent = payload.requestBodyBytesSent ?? payload.requestBody?.size {
            self.requestBodyBytesSent = requestBodyBytesSent
        }
        if let wallTime = payload.wallTimeSeconds {
            self.wallTime = wallTime
        }
        if startTimestamp > payload.startTimeSeconds {
            startTimestamp = payload.startTimeSeconds
        }
        phase = .pending
        refreshFileTypeLabel()
    }

    func applyResponsePayload(_ payload: HTTPNetworkEvent) {
        if startTimestamp > payload.startTimeSeconds {
            startTimestamp = payload.startTimeSeconds
        }
        statusCode = payload.statusCode
        statusText = payload.statusText ?? ""
        mimeType = payload.mimeType
        if !payload.responseHeaders.isEmpty {
            responseHeaders = payload.responseHeaders
        }
        if !payload.blockedCookies.isEmpty {
            responseHeaders.append(
                NetworkHeaderField(
                    name: "blocked-cookies",
                    value: payload.blockedCookies.joined(separator: ",")
                )
            )
        }
        if let requestType = payload.requestType {
            self.requestType = requestType
        }
        refreshFileTypeLabel()
        phase = .pending
    }

    func applyCompletionPayload(_ payload: HTTPNetworkEvent, failed: Bool) {
        if let statusCode = payload.statusCode {
            self.statusCode = statusCode
        }
        if let statusText = payload.statusText {
            self.statusText = statusText
        }
        if let mimeType = payload.mimeType {
            self.mimeType = mimeType
        }
        if let encodedBodyLength = payload.encodedBodyLength {
            self.encodedBodyLength = encodedBodyLength
        }
        if let decodedBodySize = payload.decodedBodySize {
            self.decodedBodyLength = decodedBodySize
        } else if let responseBody {
            self.decodedBodyLength = responseBody.size
        }
        if let endTime = payload.endTimeSeconds {
            if startTimestamp > endTime {
                startTimestamp = endTime
            }
            endTimestamp = endTime
            duration = max(0, endTime - startTimestamp)
        }
        if let requestType = payload.requestType {
            self.requestType = requestType
        }
        if let responseBody = payload.responseBody {
            self.responseBody = responseBody
            self.responseBody?.role = .response
        } else if failed {
            responseBody = nil
        }
        errorDescription = payload.errorDescription
        refreshFileTypeLabel()
        phase = failed ? .failed : .completed
        if failed && statusCode == nil {
            statusCode = 0
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

    // NOTE: When re-enabling WebSocket capture, ensure this does not mark the entry as completed
    // for every frame. Keep the phase pending until close/error to reflect the live connection state.
    func appendWebSocketFrame(_ payload: WSNetworkEvent) {
        let direction = payload.frameDirection ?? .incoming
        let opcode = payload.frameOpcode ?? 1
        let size = payload.framePayloadSize
        let frame = NetworkWebSocketFrame(
            direction: direction,
            opcode: opcode,
            payload: payload.framePayload,
            payloadIsBase64: payload.framePayloadIsBase64,
            payloadSize: size,
            payloadTruncated: payload.framePayloadTruncated,
            timestamp: payload.endTimeSeconds ?? payload.startTimeSeconds
        )
        let info = webSocket ?? NetworkWebSocketInfo()
        info.appendFrame(frame)
        webSocket = info
        phase = .completed
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

    fileprivate static func normalizedMimeType(_ mimeType: String?) -> String {
        guard let mimeType, mimeType.isEmpty == false else { return "" }
        let trimmed = mimeType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first ?? ""
        return trimmed.lowercased()
    }

    fileprivate static func normalizedPathExtension(_ url: String) -> String {
        guard let pathExtension = URL(string: url)?.pathExtension,
              pathExtension.isEmpty == false else {
            return ""
        }
        return pathExtension.lowercased()
    }
}

public struct NetworkWebSocketFrame: Hashable, Sendable {
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
}

@Observable
public final class NetworkWebSocketInfo: Identifiable, Equatable, Hashable {
    public static nonisolated func == (lhs: NetworkWebSocketInfo, rhs: NetworkWebSocketInfo) -> Bool { lhs.id == rhs.id }
    public nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }

    nonisolated public let id: UUID

    public internal(set) var frames: [NetworkWebSocketFrame]
    public internal(set) var closeCode: Int?
    public internal(set) var closeReason: String?
    public internal(set) var closeWasClean: Bool?

    public init(
        frames: [NetworkWebSocketFrame] = [],
        closeCode: Int? = nil,
        closeReason: String? = nil,
        closeWasClean: Bool? = nil
    ) {
        self.id = UUID()
        self.frames = frames
        self.closeCode = closeCode
        self.closeReason = closeReason
        self.closeWasClean = closeWasClean
    }

    func appendFrame(_ frame: NetworkWebSocketFrame) {
        frames.append(frame)
    }

    func applyClose(code: Int?, reason: String?, wasClean: Bool?) {
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
