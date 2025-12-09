import Foundation
import Observation

enum HTTPNetworkEventKind: String {
    case start
    case response
    case responseExtra
    case finish
    case resourceTiming
    case fail
}

enum WSNetworkEventKind: String {
    case created = "wsCreated"
    case handshakeRequest = "wsHandshakeRequest"
    case handshake = "wsHandshake"
    case frame = "wsFrame"
    case closed = "wsClosed"
    case frameError = "wsFrameError"
}

protocol NetworkEventProtocol {
    var sessionID: String { get }
    var requestID: Int { get }
    var startTimeSeconds: TimeInterval { get }
    var endTimeSeconds: TimeInterval? { get }
    var wallTimeSeconds: TimeInterval? { get }
}

@Observable
public final class WINetworkBody {
    public enum Kind: String, Sendable {
        case text
        case form
        case binary
        case other
    }

    public enum FetchError: Equatable, Sendable {
        case unavailable
        case decodeFailed
        case unknown
    }

    public enum FetchState: Equatable {
        case inline
        case fetching
        case full
        case failed(FetchError)
    }

    public enum Role:CaseIterable {
        case request
        case response
    }

    public struct FormEntry: Sendable {
        public let name: String
        public let value: String
        public let isFile: Bool
        public let fileName: String?

        init(name: String, value: String, isFile: Bool, fileName: String?) {
            self.name = name
            self.value = value
            self.isFile = isFile
            self.fileName = fileName
        }

        init?(dictionary: [String: Any]) {
            let name = dictionary["name"] as? String ?? ""
            let value = dictionary["value"] as? String ?? ""
            if name.isEmpty && value.isEmpty {
                return nil
            }
            let isFile = dictionary["isFile"] as? Bool ?? false
            let fileName = dictionary["fileName"] as? String
            self.init(name: name, value: value, isFile: isFile, fileName: fileName)
        }
    }

    public var kind: Kind
    public var preview: String?
    public var full: String?
    public var size: Int?
    public var isBase64Encoded: Bool
    public var isTruncated: Bool
    public var summary: String?
    public var formEntries: [FormEntry]
    public var fetchState: FetchState
    public var role: Role

    public init(
        kind: Kind = .text,
        preview: String?,
        full: String? = nil,
        size: Int? = nil,
        isBase64Encoded: Bool = false,
        isTruncated: Bool = false,
        summary: String? = nil,
        formEntries: [FormEntry] = [],
        fetchState: FetchState? = nil,
        role: Role = .response
    ) {
        let resolvedFull = full ?? (isTruncated ? nil : preview)
        let resolvedSize = size ?? (resolvedFull?.count ?? preview?.count)
        self.kind = kind
        self.preview = preview
        self.full = resolvedFull
        self.size = resolvedSize
        self.isBase64Encoded = isBase64Encoded
        self.isTruncated = isTruncated
        self.summary = summary
        self.formEntries = formEntries
        self.role = role
        if let fetchState {
            self.fetchState = fetchState
        } else if isTruncated && resolvedFull == nil {
            self.fetchState = .inline
        } else {
            self.fetchState = .full
        }
    }

    convenience init?(dictionary: [String: Any]) {
        let rawKind = (dictionary["kind"] as? String)?.lowercased() ?? ""
        let kind = Kind(rawValue: rawKind) ?? .other
        let preview = dictionary["body"] as? String
            ?? dictionary["preview"] as? String
            ?? dictionary["inlineBody"] as? String
        let storedBody = dictionary["storageBody"] as? String
            ?? dictionary["fullBody"] as? String
        let base64 = dictionary["base64Encoded"] as? Bool
            ?? dictionary["base64encoded"] as? Bool
            ?? false
        let truncated = dictionary["truncated"] as? Bool ?? false
        let rawSize = dictionary["size"]
        let size = rawSize as? Int ?? (rawSize as? NSNumber)?.intValue
        let summary = dictionary["summary"] as? String
        let formEntries = (dictionary["formEntries"] as? [[String: Any]] ?? [])
            .compactMap(FormEntry.init(dictionary:))

        self.init(
            kind: kind,
            preview: preview,
            full: storedBody,
            size: size,
            isBase64Encoded: base64,
            isTruncated: truncated,
            summary: summary,
            formEntries: formEntries
        )
    }

    static func decode(from value: Any?) -> WINetworkBody? {
        if let dictionary = value as? [String: Any] {
            return WINetworkBody(dictionary: dictionary)
        }
        if let string = value as? String {
            return WINetworkBody(
                kind: .text,
                preview: string,
                full: string,
                size: string.count,
                isBase64Encoded: false,
                isTruncated: false
            )
        }
        return nil
    }

    public var displayText: String? {
        full ?? preview ?? summary
    }

    public var isFetching: Bool {
        if case .fetching = fetchState {
            return true
        }
        return false
    }

    public func markFetching() {
        fetchState = .fetching
    }

    public func markFailed(_ error: FetchError) {
        fetchState = .failed(error)
    }

    public func applyFullBody(_ fullBody: String, isBase64Encoded: Bool, size: Int?) {
        full = fullBody
        preview = preview ?? fullBody
        self.isBase64Encoded = isBase64Encoded
        isTruncated = false
        self.size = size ?? fullBody.count
        fetchState = .full
    }
}

struct HTTPNetworkEvent: NetworkEventProtocol {
    let kind: HTTPNetworkEventKind
    let sessionID: String
    let requestID: Int
    let url: String?
    let method: String?
    let statusCode: Int?
    let statusText: String?
    let mimeType: String?
    let requestHeaders: WINetworkHeaders
    let responseHeaders: WINetworkHeaders
    let startTimeSeconds: TimeInterval
    let endTimeSeconds: TimeInterval?
    let wallTimeSeconds: TimeInterval?
    let encodedBodyLength: Int?
    let decodedBodySize: Int?
    let errorDescription: String?
    let requestType: String?
    let requestBody: WINetworkBody?
    let requestBodyBytesSent: Int?
    let responseBody: WINetworkBody?
    let blockedCookies: [String]

    init?(dictionary: [String: Any]) {
        guard let type = dictionary["type"] as? String,
              let kind = HTTPNetworkEventKind(rawValue: type) else {
            return nil
        }
        self.init(kind: kind, dictionary: dictionary)
    }

    init?(kind: HTTPNetworkEventKind, dictionary: [String: Any]) {
        guard let requestID = Self.normalizedRequestIdentifier(from: dictionary["requestId"]) else {
            return nil
        }
        self.kind = kind
        self.sessionID = dictionary["session"] as? String ?? ""
        self.requestID = requestID

        self.url = dictionary["url"] as? String
        if let method = dictionary["method"] as? String {
            self.method = method.uppercased()
        } else {
            self.method = nil
        }
        self.statusCode = dictionary["status"] as? Int
        self.statusText = dictionary["statusText"] as? String
        self.mimeType = dictionary["mimeType"] as? String
        self.requestHeaders = WINetworkHeaders(dictionary: dictionary["requestHeaders"] as? [String: String] ?? [:])
        self.responseHeaders = WINetworkHeaders(dictionary: dictionary["responseHeaders"] as? [String: String] ?? [:])
        self.requestBody = WINetworkBody.decode(from: dictionary["requestBody"])
        self.responseBody = WINetworkBody.decode(from: dictionary["responseBody"])
        self.blockedCookies = dictionary["blockedCookies"] as? [String] ?? []

        if let start = dictionary["startTime"] as? Double {
            self.startTimeSeconds = start / 1000.0
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
        self.encodedBodyLength = dictionary["encodedBodyLength"] as? Int
        self.decodedBodySize = dictionary["decodedBodySize"] as? Int ?? self.responseBody?.size
        if let error = dictionary["error"] as? String, !error.isEmpty {
            self.errorDescription = error
        } else {
            self.errorDescription = nil
        }
        self.requestType = dictionary["requestType"] as? String
        let rawBytesSent = dictionary["requestBodyBytesSent"]
        if let bytesSent = rawBytesSent as? Int ?? (rawBytesSent as? NSNumber)?.intValue {
            self.requestBodyBytesSent = bytesSent
        } else if let requestBody {
            self.requestBodyBytesSent = requestBody.size
        } else {
            let rawRequestBodySize = dictionary["requestBodySize"]
            self.requestBodyBytesSent = rawRequestBodySize as? Int ?? (rawRequestBodySize as? NSNumber)?.intValue
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

struct WSNetworkEvent: NetworkEventProtocol {
    let kind: WSNetworkEventKind
    let sessionID: String
    let requestID: Int
    let url: String?
    let startTimeSeconds: TimeInterval
    let endTimeSeconds: TimeInterval?
    let wallTimeSeconds: TimeInterval?
    let framePayload: String?
    let framePayloadIsBase64: Bool
    let framePayloadSize: Int?
    let frameDirection: WINetworkWebSocketFrame.Direction?
    let frameOpcode: Int?
    let framePayloadTruncated: Bool
    let statusCode: Int?
    let statusText: String?
    let closeCode: Int?
    let closeReason: String?
    let errorDescription: String?
    let requestHeaders: WINetworkHeaders
    let closeWasClean: Bool?

    init?(dictionary: [String: Any]) {
        guard let type = dictionary["type"] as? String,
              let kind = WSNetworkEventKind(rawValue: type) else {
            return nil
        }
        self.init(kind: kind, dictionary: dictionary)
    }

    init?(kind: WSNetworkEventKind, dictionary: [String: Any]) {
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
        self.requestHeaders = WINetworkHeaders(dictionary: dictionary["requestHeaders"] as? [String: String] ?? [:])
        self.framePayload = dictionary["framePayload"] as? String
        self.framePayloadIsBase64 = dictionary["framePayloadBase64"] as? Bool ?? false
        self.framePayloadSize = dictionary["framePayloadSize"] as? Int
        self.framePayloadTruncated = dictionary["framePayloadTruncated"] as? Bool ?? false
        if let rawDirection = dictionary["frameDirection"] as? String {
            self.frameDirection = WINetworkWebSocketFrame.Direction(rawValue: rawDirection)
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

struct NetworkEventBatch {
    let sessionID: String
    let events: [HTTPNetworkEvent]

    init?(dictionary: [String: Any]) {
        guard let sessionID = dictionary["session"] as? String, !sessionID.isEmpty else {
            assertionFailure("NetworkEventBatch requires session ID")
            return nil
        }
        let eventsArray = dictionary["events"] as? [[String: Any]] ?? []
        let parsed = eventsArray.compactMap { item -> HTTPNetworkEvent? in
            guard let type = item["type"] as? String,
                  let kind = HTTPNetworkEventKind(rawValue: type) else { return nil }
            return HTTPNetworkEvent(kind: kind, dictionary: item)
        }
        guard !parsed.isEmpty else { return nil }
        self.events = parsed
        self.sessionID = sessionID
    }
}

@Observable
public class WINetworkEntry: Identifiable, Equatable, Hashable {
    
    // Equatable / Hashable
    public static nonisolated func == (lhs: WINetworkEntry, rhs: WINetworkEntry) -> Bool { lhs.id == rhs.id }
    public nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
    
    public enum Phase: String {
        case pending
        case completed
        case failed
    }
    
    nonisolated public let id: UUID
    
    public let sessionID: String
    public let requestID: Int
    public let createdAt: Date
    
    
    public internal(set) var url: String
    public internal(set) var method: String
    public internal(set) var statusCode: Int?
    public internal(set) var statusText: String
    public internal(set) var mimeType: String?
    public internal(set) var requestHeaders: WINetworkHeaders
    public internal(set) var responseHeaders: WINetworkHeaders
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
    public internal(set) var requestBody: WINetworkBody?
    public internal(set) var responseBody: WINetworkBody?
    public internal(set) var webSocket: WINetworkWebSocketInfo?
    
    init(
        sessionID: String,
        requestID: Int,
        url: String,
        method: String,
        requestHeaders: WINetworkHeaders,
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
        self.responseHeaders = WINetworkHeaders()
        self.startTimestamp = startTimestamp
        self.wallTime = wallTime
        self.statusCode = nil
        self.statusText = ""
        self.mimeType = nil
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
    }

    convenience init(startPayload payload: HTTPNetworkEvent) {
        let method = payload.method ?? "GET"
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
    }

    func applyResponsePayload(_ payload: HTTPNetworkEvent) {
        statusCode = payload.statusCode
        statusText = payload.statusText ?? ""
        mimeType = payload.mimeType
        if !payload.responseHeaders.isEmpty {
            responseHeaders = payload.responseHeaders
        }
        if !payload.blockedCookies.isEmpty {
            responseHeaders.append(
                WINetworkHeaderField(
                    name: "blocked-cookies",
                    value: payload.blockedCookies.joined(separator: ",")
                )
            )
        }
        if let requestType = payload.requestType {
            self.requestType = requestType
        }
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
            endTimestamp = endTime
            duration = max(0, endTime - startTimestamp)
        }
        if let requestType = payload.requestType {
            self.requestType = requestType
        }
        if let responseBody = payload.responseBody {
            self.responseBody = responseBody
            self.responseBody?.role = .response
        }
        errorDescription = payload.errorDescription
        phase = failed ? .failed : .completed
        if failed && statusCode == nil {
            statusCode = 0
        }
    }

    func appendWebSocketFrame(_ payload: WSNetworkEvent) {
        let direction = payload.frameDirection ?? .incoming
        let opcode = payload.frameOpcode ?? 1
        let size = payload.framePayloadSize
        let frame = WINetworkWebSocketFrame(
            direction: direction,
            opcode: opcode,
            payload: payload.framePayload,
            payloadIsBase64: payload.framePayloadIsBase64,
            payloadSize: size,
            payloadTruncated: payload.framePayloadTruncated,
            timestamp: payload.endTimeSeconds ?? payload.startTimeSeconds
        )
        let info = webSocket ?? WINetworkWebSocketInfo()
        info.appendFrame(frame)
        webSocket = info
        phase = .completed
    }
}

public struct WINetworkWebSocketFrame: Hashable, Sendable {
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
public final class WINetworkWebSocketInfo: Identifiable, Equatable, Hashable{
    
    // Equatable / Hashable
    public static nonisolated func == (lhs: WINetworkWebSocketInfo, rhs: WINetworkWebSocketInfo) -> Bool { lhs.id == rhs.id }
    public nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
    
    nonisolated public let id: UUID
    
    public internal(set) var frames: [WINetworkWebSocketFrame]
    public internal(set) var closeCode: Int?
    public internal(set) var closeReason: String?
    public internal(set) var closeWasClean: Bool?

    public init(
        frames: [WINetworkWebSocketFrame] = [],
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

    func appendFrame(_ frame: WINetworkWebSocketFrame) {
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

@MainActor
@Observable public final class WINetworkStore {
    public private(set) var isRecording = true
    public private(set) var entries: [WINetworkEntry] = []
    @ObservationIgnored private var sessionBuckets: [String: SessionBucket] = [:]
    @ObservationIgnored private var indexByEntryID: [UUID: Int] = [:]

    func applyEvent(_ event: HTTPNetworkEvent) {
        applyHTTPEvent(event)
    }

    func applyEvent(_ event: WSNetworkEvent) {
        applyWSEvent(event)
    }

    func applyBatchedInsertions(_ batch: NetworkEventBatch) {
        let events = batch.events
        guard !events.isEmpty else { return }

        let bucket = bucket(for: batch.sessionID)
        var staged: [(requestID: Int, entry: WINetworkEntry)] = []
        var seenRequestIDs = Set<Int>()

        for event in events {
            guard event.kind == .resourceTiming else { continue }
            let requestID = event.requestID
            // Prevent duplicates within the same batch.
            if seenRequestIDs.contains(requestID) {
                continue
            }
            // Skip if an entry already exists from a non-batch path.
            if bucket.entry(for: requestID) != nil {
                continue
            }

            let entry = WINetworkEntry(startPayload: event)
            entry.applyCompletionPayload(event, failed: false)
            staged.append((requestID, entry))
            seenRequestIDs.insert(requestID)
        }

        if staged.isEmpty {
            return
        }

        let startIndex = entries.count
        entries.append(contentsOf: staged.map(\.entry))

        for (offset, stagedEntry) in staged.enumerated() {
            let newIndex = startIndex + offset
            bucket.set(stagedEntry.entry, requestID: stagedEntry.requestID)
            indexByEntryID[stagedEntry.entry.id] = newIndex
        }
    }

    func applyHTTPEvent(_ event: HTTPNetworkEvent) {
        switch event.kind {
        case .start:
            handleStart(event)
        case .response:
            handleResponse(event)
        case .responseExtra:
            handleResponse(event)
        case .finish:
            handleFinish(event, failed: false)
        case .resourceTiming:
            handleResourceTiming(event)
        case .fail:
            handleFinish(event, failed: true)
        }
    }

    func applyWSEvent(_ event: WSNetworkEvent) {
        switch event.kind {
        case .created:
            handleWebSocketCreated(event)
        case .handshake:
            handleWebSocketHandshake(event)
        case .handshakeRequest:
            handleWebSocketHandshakeRequest(event)
        case .frame:
            handleWebSocketFrame(event)
        case .closed:
            handleWebSocketCompletion(event, failed: false)
        case .frameError:
            handleWebSocketCompletion(event, failed: true)
        }
    }

    func reset() {
        sessionBuckets.removeAll()
        entries.removeAll()
        indexByEntryID.removeAll()
    }

    func clear() {
        reset()
    }

    func setRecording(_ enabled: Bool) {
        isRecording = enabled
    }

    public func entry(forRequestID requestID: Int, sessionID: String?) -> WINetworkEntry? {
        let bucketKey = sessionKey(for: sessionID)
        guard let bucket = sessionBuckets[bucketKey],
              let entry = bucket.entry(for: requestID) else {
            return nil
        }
        return entry
    }

    public func entry(forEntryID id: UUID?) -> WINetworkEntry? {
        guard let id,
              let index = indexByEntryID[id],
              entries.indices.contains(index) else {
            return nil
        }
        return entries[index]
    }

    private func handleStart(_ event: HTTPNetworkEvent) {
        let requestID = event.requestID
        let bucket = bucket(for: event.sessionID)
        if bucket.entry(for: requestID) != nil {
            return
        }
        appendEntry(WINetworkEntry(startPayload: event), requestID: requestID, in: bucket)
    }

    private func handleResponse(_ event: HTTPNetworkEvent) {
        let requestID = event.requestID
        guard let entry = entry(forRequestID: requestID, sessionID: event.sessionID) else { return }
        entry.applyResponsePayload(event)
    }

    private func handleFinish(_ event: HTTPNetworkEvent, failed: Bool) {
        let requestID = event.requestID
        guard let entry = entry(forRequestID: requestID, sessionID: event.sessionID) else { return }
        entry.applyCompletionPayload(event, failed: failed)
    }

    private func handleResourceTiming(_ event: HTTPNetworkEvent) {
        let requestID = event.requestID
        let bucket = bucket(for: event.sessionID)
        if bucket.entry(for: requestID) != nil {
            return
        }
        let entry = WINetworkEntry(startPayload: event)
        appendEntry(entry, requestID: requestID, in: bucket)
        entry.applyCompletionPayload(event, failed: false)
    }

    private func handleWebSocketCreated(_ event: WSNetworkEvent) {
        let bucket = bucket(for: event.sessionID)
        if bucket.entry(for: event.requestID) != nil {
            return
        }
        let entry = WINetworkEntry(
            sessionID: event.sessionID,
            requestID: event.requestID,
            url: event.url ?? "",
            method: "GET",
            requestHeaders: WINetworkHeaders(),
            startTimestamp: event.startTimeSeconds,
            wallTime: event.wallTimeSeconds
        )
        entry.requestType = "websocket"
        entry.webSocket = WINetworkWebSocketInfo()
        appendEntry(entry, requestID: event.requestID, in: bucket)
    }

    private func handleWebSocketHandshakeRequest(_ event: WSNetworkEvent) {
        guard let entry = entry(forRequestID: event.requestID, sessionID: event.sessionID) else {
            return
        }
        if !event.requestHeaders.isEmpty {
            entry.requestHeaders = event.requestHeaders
        }
        entry.phase = .pending
    }

    private func handleWebSocketHandshake(_ event: WSNetworkEvent) {
        guard let entry = entry(forRequestID: event.requestID, sessionID: event.sessionID) else {
            return
        }
        if let status = event.statusCode {
            entry.statusCode = status
        }
        if let statusText = event.statusText {
            entry.statusText = statusText
        }
        entry.phase = .pending
    }

    private func handleWebSocketFrame(_ event: WSNetworkEvent) {
        guard let entry = entry(forRequestID: event.requestID, sessionID: event.sessionID) else {
            return
        }
        entry.appendWebSocketFrame(event)
    }

    private func handleWebSocketCompletion(_ event: WSNetworkEvent, failed: Bool) {
        guard let entry = entry(forRequestID: event.requestID, sessionID: event.sessionID) else {
            return
        }
        if let status = event.statusCode, entry.statusCode == nil {
            entry.statusCode = status
        }
        if let statusText = event.statusText, entry.statusText.isEmpty {
            entry.statusText = statusText
        }
        let info = entry.webSocket ?? WINetworkWebSocketInfo()
        info.applyClose(
            code: event.closeCode,
            reason: event.closeReason,
            wasClean: event.closeWasClean
        )
        entry.webSocket = info
        if let end = event.endTimeSeconds {
            entry.endTimestamp = end
            entry.duration = max(0, end - entry.startTimestamp)
        }
        if let errorDescription = event.errorDescription {
            entry.errorDescription = errorDescription
        }
        entry.phase = failed ? .failed : .completed
        if failed && entry.statusCode == nil {
            entry.statusCode = 0
        }
    }

    private func appendEntry(_ entry: WINetworkEntry, requestID: Int, in bucket: SessionBucket) {
        entries.append(entry)
        let newIndex = entries.count - 1
        bucket.set(entry, requestID: requestID)
        indexByEntryID[entry.id] = newIndex
    }

    private func bucket(for sessionID: String?) -> SessionBucket {
        let key = sessionKey(for: sessionID)
        if let existing = sessionBuckets[key] {
            return existing
        }
        let bucket = SessionBucket()
        sessionBuckets[key] = bucket
        return bucket
    }

    private func sessionKey(for sessionID: String?) -> String {
        guard let sessionID, !sessionID.isEmpty else {
            return "__default_session__"
        }
        return sessionID
    }
}

private final class SessionBucket {
    private struct WeakEntry {
        weak var value: WINetworkEntry?
    }

    private var entriesByRequestID: [Int: WeakEntry] = [:]

    func entry(for requestID: Int) -> WINetworkEntry? {
        entriesByRequestID[requestID]?.value
    }

    func set(_ entry: WINetworkEntry, requestID: Int) {
        entriesByRequestID[requestID] = WeakEntry(value: entry)
    }
}
