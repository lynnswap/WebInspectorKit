import Foundation

package enum HTTPNetworkEventKind: String, Decodable {
    case requestWillBeSent
    case responseReceived
    case loadingFinished
    case loadingFailed
    case resourceTiming
}

package enum WSNetworkEventKind: String {
    case created = "wsCreated"
    case handshakeRequest = "wsHandshakeRequest"
    case handshake = "wsHandshake"
    case frame = "wsFrame"
    case closed = "wsClosed"
    case frameError = "wsFrameError"
}

package protocol NetworkEventProtocol {
    var sessionID: String { get }
    var requestID: Int { get }
    var startTimeSeconds: TimeInterval { get }
    var endTimeSeconds: TimeInterval? { get }
    var wallTimeSeconds: TimeInterval? { get }
}

package struct NetworkTimePayload: Decodable {
    let monotonicMs: Double
    let wallMs: Double

    package init(monotonicMs: Double, wallMs: Double) {
        self.monotonicMs = monotonicMs
        self.wallMs = wallMs
    }
}

package struct NetworkErrorPayload: Decodable {
    let domain: String
    let code: String?
    let message: String
    let isCanceled: Bool?
    let isTimeout: Bool?

    package init(domain: String, code: String?, message: String, isCanceled: Bool?, isTimeout: Bool?) {
        self.domain = domain
        self.code = code
        self.message = message
        self.isCanceled = isCanceled
        self.isTimeout = isTimeout
    }
}

package struct NetworkEventPayload: Decodable {
    let kind: String
    let requestId: Int
    let time: NetworkTimePayload?
    let startTime: NetworkTimePayload?
    let endTime: NetworkTimePayload?
    let url: String?
    let method: String?
    let status: Int?
    let statusText: String?
    let mimeType: String?
    let headers: [String: String]?
    let initiator: String?
    let body: NetworkBodyPayload?
    let bodySize: Int?
    let encodedBodyLength: Int?
    let decodedBodySize: Int?
    let error: NetworkErrorPayload?

    package init(
        kind: String,
        requestId: Int,
        time: NetworkTimePayload?,
        startTime: NetworkTimePayload?,
        endTime: NetworkTimePayload?,
        url: String?,
        method: String?,
        status: Int?,
        statusText: String?,
        mimeType: String?,
        headers: [String: String]?,
        initiator: String?,
        body: NetworkBodyPayload?,
        bodySize: Int?,
        encodedBodyLength: Int?,
        decodedBodySize: Int?,
        error: NetworkErrorPayload?
    ) {
        self.kind = kind
        self.requestId = requestId
        self.time = time
        self.startTime = startTime
        self.endTime = endTime
        self.url = url
        self.method = method
        self.status = status
        self.statusText = statusText
        self.mimeType = mimeType
        self.headers = headers
        self.initiator = initiator
        self.body = body
        self.bodySize = bodySize
        self.encodedBodyLength = encodedBodyLength
        self.decodedBodySize = decodedBodySize
        self.error = error
    }
}

private extension NetworkTimePayload {
    init?(dictionary: NSDictionary) {
        guard let monotonicMs = networkDouble(from: dictionary["monotonicMs"]) else {
            return nil
        }
        guard let wallMs = networkDouble(from: dictionary["wallMs"]) else {
            return nil
        }
        self.init(monotonicMs: monotonicMs, wallMs: wallMs)
    }
}

private extension NetworkErrorPayload {
    init?(dictionary: NSDictionary) {
        guard let domain = dictionary["domain"] as? String else {
            return nil
        }
        guard let message = dictionary["message"] as? String else {
            return nil
        }
        self.init(
            domain: domain,
            code: dictionary["code"] as? String,
            message: message,
            isCanceled: dictionary["isCanceled"] as? Bool,
            isTimeout: dictionary["isTimeout"] as? Bool
        )
    }
}

private extension NetworkEventPayload {
    init?(dictionary: NSDictionary) {
        guard let kind = dictionary["kind"] as? String else {
            return nil
        }
        guard let requestId = networkInt(from: dictionary["requestId"]) else {
            return nil
        }
        let time = (dictionary["time"] as? NSDictionary).flatMap(NetworkTimePayload.init(dictionary:))
        let startTime = (dictionary["startTime"] as? NSDictionary).flatMap(NetworkTimePayload.init(dictionary:))
        let endTime = (dictionary["endTime"] as? NSDictionary).flatMap(NetworkTimePayload.init(dictionary:))

        let headers = dictionary["headers"] as? [String: String]
            ?? (dictionary["headers"] as? NSDictionary).map { rawHeaders in
                var mapped: [String: String] = [:]
                for (key, value) in rawHeaders {
                    mapped[String(describing: key)] = String(describing: value)
                }
                return mapped
            }

        let bodyPayload: NetworkBodyPayload?
        if let body = dictionary["body"] as? NSDictionary {
            bodyPayload = NetworkBodyPayload(dictionary: body)
        } else {
            bodyPayload = nil
        }

        let errorPayload = (dictionary["error"] as? NSDictionary).flatMap(NetworkErrorPayload.init(dictionary:))

        self.init(
            kind: kind,
            requestId: requestId,
            time: time,
            startTime: startTime,
            endTime: endTime,
            url: dictionary["url"] as? String,
            method: dictionary["method"] as? String,
            status: networkInt(from: dictionary["status"]),
            statusText: dictionary["statusText"] as? String,
            mimeType: dictionary["mimeType"] as? String,
            headers: headers,
            initiator: dictionary["initiator"] as? String,
            body: bodyPayload,
            bodySize: networkInt(from: dictionary["bodySize"]),
            encodedBodyLength: networkInt(from: dictionary["encodedBodyLength"]),
            decodedBodySize: networkInt(from: dictionary["decodedBodySize"]),
            error: errorPayload
        )
    }
}

private func networkDouble(from value: Any?) -> Double? {
    if let value = value as? Double {
        return value
    }
    if let value = value as? NSNumber {
        return value.doubleValue
    }
    if let value = value as? String {
        return Double(value)
    }
    return nil
}

private func networkInt(from value: Any?) -> Int? {
    if value is Bool {
        return nil
    }
    if let value = value as? NSNumber {
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return nil
        }
        return networkIntegralInt(from: value.doubleValue)
    }
    if let value = value as? Int {
        return value
    }
    if let value = value as? String {
        return Int(value)
    }
    if let value = value as? Double {
        return networkIntegralInt(from: value)
    }
    return nil
}

private func networkIntegralInt(from value: Double) -> Int? {
    guard value.isFinite else {
        return nil
    }
    let truncated = value.rounded(.towardZero)
    guard truncated == value else {
        return nil
    }
    guard truncated >= Double(Int.min), truncated <= Double(Int.max) else {
        return nil
    }
    return Int(truncated)
}

package struct HTTPNetworkEvent: NetworkEventProtocol {
    let kind: HTTPNetworkEventKind
    package let sessionID: String
    package let requestID: Int
    let url: String?
    let method: String?
    let statusCode: Int?
    let statusText: String?
    let mimeType: String?
    let requestHeaders: NetworkHeaders
    let responseHeaders: NetworkHeaders
    package let startTimeSeconds: TimeInterval
    package let endTimeSeconds: TimeInterval?
    package let wallTimeSeconds: TimeInterval?
    let encodedBodyLength: Int?
    let decodedBodySize: Int?
    let errorDescription: String?
    let requestType: String?
    let requestBody: NetworkBody?
    let requestBodyBytesSent: Int?
    let responseBody: NetworkBody?
    let blockedCookies: [String]

    package init?(payload: NetworkEventPayload, sessionID: String) {
        guard let kind = HTTPNetworkEventKind(rawValue: payload.kind) else {
            return nil
        }
        self.kind = kind
        self.sessionID = sessionID
        self.requestID = payload.requestId

        self.url = payload.url
        if let method = payload.method {
            self.method = method.uppercased()
        } else {
            self.method = nil
        }
        self.statusCode = payload.status
        self.statusText = payload.statusText
        self.mimeType = payload.mimeType
        self.requestType = payload.initiator

        let headers = NetworkHeaders(dictionary: payload.headers ?? [:])
        switch kind {
        case .requestWillBeSent:
            self.requestHeaders = headers
            self.responseHeaders = NetworkHeaders()
        case .responseReceived:
            self.requestHeaders = NetworkHeaders()
            self.responseHeaders = headers
        case .loadingFinished, .loadingFailed, .resourceTiming:
            self.requestHeaders = NetworkHeaders()
            self.responseHeaders = NetworkHeaders()
        }

        if let body = payload.body {
            let deferredTargetIdentifier = sessionID == "page" || sessionID.isEmpty ? nil : sessionID
            switch kind {
            case .requestWillBeSent:
                self.requestBody = NetworkBody.from(payload: body, role: .request)
                self.requestBody?.defaultDeferredNetworkRequestTarget(deferredTargetIdentifier)
                self.responseBody = nil
            case .loadingFinished:
                self.requestBody = nil
                self.responseBody = NetworkBody.from(payload: body, role: .response)
                self.responseBody?.defaultDeferredNetworkRequestTarget(deferredTargetIdentifier)
            default:
                self.requestBody = nil
                self.responseBody = nil
            }
        } else {
            self.requestBody = nil
            self.responseBody = nil
        }

        self.blockedCookies = []

        let nowSeconds = Date().timeIntervalSince1970
        switch kind {
        case .resourceTiming:
            if let start = payload.startTime {
                self.startTimeSeconds = start.monotonicMs / 1000.0
                self.wallTimeSeconds = start.wallMs / 1000.0
            } else {
                self.startTimeSeconds = nowSeconds
                self.wallTimeSeconds = nil
            }
            if let end = payload.endTime {
                self.endTimeSeconds = end.monotonicMs / 1000.0
            } else {
                self.endTimeSeconds = nil
            }
        case .loadingFinished, .loadingFailed:
            if let time = payload.time {
                self.startTimeSeconds = time.monotonicMs / 1000.0
                self.endTimeSeconds = time.monotonicMs / 1000.0
                self.wallTimeSeconds = time.wallMs / 1000.0
            } else {
                self.startTimeSeconds = nowSeconds
                self.endTimeSeconds = nil
                self.wallTimeSeconds = nil
            }
        case .requestWillBeSent, .responseReceived:
            if let time = payload.time {
                self.startTimeSeconds = time.monotonicMs / 1000.0
                self.wallTimeSeconds = time.wallMs / 1000.0
            } else {
                self.startTimeSeconds = nowSeconds
                self.wallTimeSeconds = nil
            }
            self.endTimeSeconds = nil
        }

        self.encodedBodyLength = payload.encodedBodyLength
        if let decoded = payload.decodedBodySize {
            self.decodedBodySize = decoded
        } else {
            self.decodedBodySize = self.responseBody?.size
        }
        if let error = payload.error?.message, !error.isEmpty {
            self.errorDescription = error
        } else {
            self.errorDescription = nil
        }

        if let bytesSent = payload.bodySize {
            self.requestBodyBytesSent = bytesSent
        } else if let requestBody {
            self.requestBodyBytesSent = requestBody.size
        } else {
            self.requestBodyBytesSent = nil
        }
    }

    static func normalizedRequestIdentifier(from value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let int = Int(trimmed) {
                return int
            }
        }
        return nil
    }
}

extension HTTPNetworkEvent {
    package init(
        kind: HTTPNetworkEventKind,
        sessionID: String,
        requestID: Int,
        url: String?,
        method: String?,
        statusCode: Int?,
        statusText: String?,
        mimeType: String?,
        requestHeaders: NetworkHeaders,
        responseHeaders: NetworkHeaders,
        startTimeSeconds: TimeInterval,
        endTimeSeconds: TimeInterval?,
        wallTimeSeconds: TimeInterval?,
        encodedBodyLength: Int?,
        decodedBodySize: Int?,
        errorDescription: String?,
        requestType: String?,
        requestBody: NetworkBody?,
        requestBodyBytesSent: Int?,
        responseBody: NetworkBody?,
        blockedCookies: [String]
    ) {
        self.kind = kind
        self.sessionID = sessionID
        self.requestID = requestID
        self.url = url
        self.method = method
        self.statusCode = statusCode
        self.statusText = statusText
        self.mimeType = mimeType
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.startTimeSeconds = startTimeSeconds
        self.endTimeSeconds = endTimeSeconds
        self.wallTimeSeconds = wallTimeSeconds
        self.encodedBodyLength = encodedBodyLength
        self.decodedBodySize = decodedBodySize
        self.errorDescription = errorDescription
        self.requestType = requestType
        self.requestBody = requestBody
        self.requestBodyBytesSent = requestBodyBytesSent
        self.responseBody = responseBody
        self.blockedCookies = blockedCookies
    }
}

package struct WSNetworkEvent: NetworkEventProtocol {
    let kind: WSNetworkEventKind
    package let sessionID: String
    package let requestID: Int
    let url: String?
    package let startTimeSeconds: TimeInterval
    package let endTimeSeconds: TimeInterval?
    package let wallTimeSeconds: TimeInterval?
    let framePayload: String?
    let framePayloadIsBase64: Bool
    let framePayloadSize: Int?
    let frameDirection: NetworkWebSocketFrame.Direction?
    let frameOpcode: Int?
    let framePayloadTruncated: Bool
    let statusCode: Int?
    let statusText: String?
    let closeCode: Int?
    let closeReason: String?
    let errorDescription: String?
    let requestHeaders: NetworkHeaders
    let closeWasClean: Bool?

    package init(
        kind: WSNetworkEventKind,
        sessionID: String,
        requestID: Int,
        url: String?,
        startTimeSeconds: TimeInterval,
        endTimeSeconds: TimeInterval?,
        wallTimeSeconds: TimeInterval?,
        framePayload: String?,
        framePayloadIsBase64: Bool,
        framePayloadSize: Int?,
        frameDirection: NetworkWebSocketFrame.Direction?,
        frameOpcode: Int?,
        framePayloadTruncated: Bool,
        statusCode: Int?,
        statusText: String?,
        closeCode: Int?,
        closeReason: String?,
        errorDescription: String?,
        requestHeaders: NetworkHeaders,
        closeWasClean: Bool?
    ) {
        self.kind = kind
        self.sessionID = sessionID
        self.requestID = requestID
        self.url = url
        self.startTimeSeconds = startTimeSeconds
        self.endTimeSeconds = endTimeSeconds
        self.wallTimeSeconds = wallTimeSeconds
        self.framePayload = framePayload
        self.framePayloadIsBase64 = framePayloadIsBase64
        self.framePayloadSize = framePayloadSize
        self.frameDirection = frameDirection
        self.frameOpcode = frameOpcode
        self.framePayloadTruncated = framePayloadTruncated
        self.statusCode = statusCode
        self.statusText = statusText
        self.closeCode = closeCode
        self.closeReason = closeReason
        self.errorDescription = errorDescription
        self.requestHeaders = requestHeaders
        self.closeWasClean = closeWasClean
    }

    init?(dictionary: NSDictionary) {
        guard let type = dictionary["type"] as? String,
              let kind = WSNetworkEventKind(rawValue: type) else {
            return nil
        }
        self.init(kind: kind, dictionary: dictionary)
    }

    init?(kind: WSNetworkEventKind, dictionary: NSDictionary) {
        guard let requestID = HTTPNetworkEvent.normalizedRequestIdentifier(from: dictionary["requestId"]) else {
            return nil
        }
        self.kind = kind
        self.sessionID = dictionary["session"] as? String ?? ""
        self.requestID = requestID
        self.url = dictionary["url"] as? String
        if let start = dictionary["startTime"] as? Double {
            self.startTimeSeconds = start / 1000.0
        } else if let end = dictionary["endTime"] as? Double {
            self.startTimeSeconds = end / 1000.0
        } else {
            self.startTimeSeconds = Date().timeIntervalSince1970
        }
        if let end = dictionary["endTime"] as? Double {
            self.endTimeSeconds = end / 1000.0
        } else {
            self.endTimeSeconds = nil
        }
        if let wallTime = dictionary["wallTime"] as? Double {
            self.wallTimeSeconds = wallTime / 1000.0
        } else {
            self.wallTimeSeconds = nil
        }
        self.requestHeaders = NetworkHeaders(dictionary: dictionary["requestHeaders"] as? [String: String] ?? [:])
        self.framePayload = dictionary["framePayload"] as? String
        self.framePayloadIsBase64 = dictionary["framePayloadBase64"] as? Bool ?? false
        self.framePayloadSize = dictionary["framePayloadSize"] as? Int
        self.framePayloadTruncated = dictionary["framePayloadTruncated"] as? Bool ?? false
        if let rawDirection = dictionary["frameDirection"] as? String {
            self.frameDirection = NetworkWebSocketFrame.Direction(rawValue: rawDirection)
        } else {
            self.frameDirection = nil
        }
        self.frameOpcode = dictionary["frameOpcode"] as? Int
        self.statusCode = dictionary["status"] as? Int
        self.statusText = dictionary["statusText"] as? String
        self.closeCode = dictionary["closeCode"] as? Int
        self.closeReason = dictionary["closeReason"] as? String
        if let wasClean = dictionary["closeWasClean"] as? Bool {
            self.closeWasClean = wasClean
        } else {
            self.closeWasClean = nil
        }
        if let error = dictionary["error"] as? String, !error.isEmpty {
            self.errorDescription = error
        } else {
            self.errorDescription = nil
        }
    }
}

package struct NetworkEventBatch: Decodable {
    package let version: Int
    package let sessionID: String
    package let seq: Int
    package let events: [HTTPNetworkEvent]
    package let dropped: Int?

    private enum CodingKeys: String, CodingKey {
        case version
        case schemaVersion
        case sessionId
        case seq
        case events
        case dropped
    }

    package init(version: Int, sessionID: String, seq: Int, events: [HTTPNetworkEvent], dropped: Int?) {
        self.version = version
        self.sessionID = sessionID
        self.seq = seq
        self.events = events
        self.dropped = dropped
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        let legacyVersion = try container.decodeIfPresent(Int.self, forKey: .version)
        version = schemaVersion ?? legacyVersion ?? 1
        let decodedSessionID = try container.decode(String.self, forKey: .sessionId)
        seq = try container.decodeIfPresent(Int.self, forKey: .seq) ?? 0
        dropped = try container.decodeIfPresent(Int.self, forKey: .dropped)
        let payloads = try container.decode([NetworkEventPayload].self, forKey: .events)
        let mapped = payloads.compactMap { HTTPNetworkEvent(payload: $0, sessionID: decodedSessionID) }
        if mapped.isEmpty {
            throw DecodingError.dataCorruptedError(forKey: .events, in: container, debugDescription: "No valid network events")
        }
        events = mapped
        sessionID = decodedSessionID
    }

    package static func decode(from payload: Any?) -> NetworkEventBatch? {
        if let data = payload as? Data {
            return decode(fromData: data)
        }
        if let jsonString = payload as? String,
           let data = jsonString.data(using: .utf8) {
            return decode(fromData: data)
        }
        if let dictionary = payload as? NSDictionary {
            return decode(fromDictionary: dictionary)
        }
        return nil
    }

    private static func decode(fromData data: Data) -> NetworkEventBatch? {
        if let batch = try? JSONDecoder().decode(NetworkEventBatch.self, from: data) {
            return batch
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? NSDictionary else {
            return nil
        }
        return decode(fromDictionary: dictionary)
    }

    private static func decode(fromDictionary dictionary: NSDictionary) -> NetworkEventBatch? {
        if let data = try? JSONSerialization.data(withJSONObject: dictionary),
           let batch = try? JSONDecoder().decode(NetworkEventBatch.self, from: data) {
            return batch
        }
        let version = dictionary["schemaVersion"] as? Int ?? dictionary["version"] as? Int ?? 1
        let sessionID = dictionary["sessionId"] as? String ?? ""
        let seq = dictionary["seq"] as? Int ?? 0
        let dropped = dictionary["dropped"] as? Int
        let rawEvents = dictionary["events"] as? NSArray ?? []
        var events: [HTTPNetworkEvent] = []
        events.reserveCapacity(rawEvents.count)
        for rawEvent in rawEvents {
            guard let payload = decodeEventPayload(from: rawEvent) else {
                continue
            }
            guard let event = HTTPNetworkEvent(payload: payload, sessionID: sessionID) else {
                continue
            }
            events.append(event)
        }
        if events.isEmpty {
            return nil
        }
        return NetworkEventBatch(
            version: version,
            sessionID: sessionID,
            seq: seq,
            events: events,
            dropped: dropped
        )
    }

    private static func decodeEventPayload(from rawEvent: Any) -> NetworkEventPayload? {
        if let payload = rawEvent as? NetworkEventPayload {
            return payload
        }
        if let dictionary = rawEvent as? NSDictionary {
            if let payload = NetworkEventPayload(dictionary: dictionary) {
                return payload
            }
            if let data = try? JSONSerialization.data(withJSONObject: dictionary) {
                return try? JSONDecoder().decode(NetworkEventPayload.self, from: data)
            }
        }
        if let jsonString = rawEvent as? String,
           let data = jsonString.data(using: .utf8) {
            return try? JSONDecoder().decode(NetworkEventPayload.self, from: data)
        }
        if let data = rawEvent as? Data {
            return try? JSONDecoder().decode(NetworkEventPayload.self, from: data)
        }
        return nil
    }
}
