import Foundation
import Observation

enum NetworkEventKind: String {
    case start
    case response
    case finish
    case resourceTiming
    case fail
}

struct NetworkEvent {
    let kind: NetworkEventKind
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
    let errorDescription: String?
    let requestType: String?

    init?(dictionary: [String: Any]) {
        guard
            let type = dictionary["type"] as? String,
            let kind = NetworkEventKind(rawValue: type),
            let requestID = Self.normalizedRequestIdentifier(from: dictionary["requestId"])
        else {
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
        if let error = dictionary["error"] as? String, !error.isEmpty {
            self.errorDescription = error
        } else {
            self.errorDescription = nil
        }
        self.requestType = dictionary["requestType"] as? String
    }

    private static func normalizedRequestIdentifier(from value: Any?) -> Int? {
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

struct NetworkEventBatch {
    let sessionID: String
    let events: [NetworkEvent]

    init?(dictionary: [String: Any]) {
        guard let sessionID = dictionary["session"] as? String, !sessionID.isEmpty else {
            assertionFailure("NetworkEventBatch requires session ID")
            return nil
        }
        let eventsArray = dictionary["events"] as? [[String: Any]] ?? []
        let parsed = eventsArray.compactMap(NetworkEvent.init(dictionary:))
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
    public internal(set) var errorDescription: String?
    public internal(set) var requestType: String?
    public internal(set) var wallTime: TimeInterval?
    public internal(set) var phase: Phase
    
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
        self.errorDescription = nil
        self.requestType = nil
        self.phase = .pending
    }

    convenience init(startPayload payload: NetworkEvent) {
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
    }

    func applyResponsePayload(_ payload: NetworkEvent) {
        statusCode = payload.statusCode
        statusText = payload.statusText ?? ""
        mimeType = payload.mimeType
        if !payload.responseHeaders.isEmpty {
            responseHeaders = payload.responseHeaders
        }
        if let requestType = payload.requestType {
            self.requestType = requestType
        }
        phase = .pending
    }

    func applyCompletionPayload(_ payload: NetworkEvent, failed: Bool) {
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
        if let endTime = payload.endTimeSeconds {
            endTimestamp = endTime
            duration = max(0, endTime - startTimestamp)
        }
        if let requestType = payload.requestType {
            self.requestType = requestType
        }
        errorDescription = payload.errorDescription
        phase = failed ? .failed : .completed
        if failed && statusCode == nil {
            statusCode = 0
        }
    }
}

@MainActor
@Observable public final class WINetworkStore {
    public private(set) var isRecording = true
    public private(set) var entries: [WINetworkEntry] = []
    @ObservationIgnored private var sessionBuckets: [String: SessionBucket] = [:]
    @ObservationIgnored private var indexByEntryID: [UUID: Int] = [:]

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

    func applyEvent(_ event: NetworkEvent) {
        switch event.kind {
        case .start:
            handleStart(event)
        case .response:
            handleResponse(event)
        case .finish:
            handleFinish(event, failed: false)
        case .resourceTiming:
            handleResourceTiming(event)
        case .fail:
            handleFinish(event, failed: true)
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

    private func handleStart(_ event: NetworkEvent) {
        let requestID = event.requestID
        let bucket = bucket(for: event.sessionID)
        if bucket.entry(for: requestID) != nil {
            return
        }
        appendEntry(WINetworkEntry(startPayload: event), requestID: requestID, in: bucket)
    }

    private func handleResponse(_ event: NetworkEvent) {
        let requestID = event.requestID
        guard let entry = entry(forRequestID: requestID, sessionID: event.sessionID) else { return }
        entry.applyResponsePayload(event)
    }

    private func handleFinish(_ event: NetworkEvent, failed: Bool) {
        let requestID = event.requestID
        guard let entry = entry(forRequestID: requestID, sessionID: event.sessionID) else { return }
        entry.applyCompletionPayload(event, failed: failed)
    }

    private func handleResourceTiming(_ event: NetworkEvent) {
        let requestID = event.requestID
        let bucket = bucket(for: event.sessionID)
        if bucket.entry(for: requestID) != nil {
            return
        }
        let entry = WINetworkEntry(startPayload: event)
        appendEntry(entry, requestID: requestID, in: bucket)
        entry.applyCompletionPayload(event, failed: false)
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
