import Foundation
import Observation

@MainActor
@Observable
public final class NetworkStore {
    public init() {}

    public private(set) var isRecording = true
    public private(set) var entries: [NetworkEntry] = []
    package private(set) var entriesGeneration: UInt64 = 0
    @ObservationIgnored private var sessionBuckets: [String: SessionBucket] = [:]
    @ObservationIgnored private var maxEntriesStorage: Int?
    @ObservationIgnored private var entriesGenerationBatchDepth = 0
    @ObservationIgnored private var hasPendingEntriesGenerationBump = false

    var maxEntries: Int? {
        get {
            maxEntriesStorage
        }
        set {
            let resolved = newValue.flatMap { $0 > 0 ? $0 : nil }
            maxEntriesStorage = resolved
            pruneIfNeeded(adding: 0)
        }
    }

    package func apply(
        _ update: NetworkEntry.Update,
        sessionID: String
    ) {
        guard isRecording else {
            return
        }

        performEntriesGenerationBatch {
            let existingEntry = entry(forRequestID: update.requestID, sessionID: sessionID)
            switch update {
            case .requestStarted, .resourceTimingSnapshot:
                if let existingEntry {
                    apply(update, toTrackedEntry: existingEntry)
                } else {
                    appendEntry(NetworkEntry(sessionID: sessionID, update: update))
                }
            case .webSocketOpened:
                guard existingEntry == nil else {
                    return
                }
                appendEntry(NetworkEntry(sessionID: sessionID, update: update))
            case .responseReceived,
                 .completed,
                 .failed,
                 .webSocketHandshake,
                 .webSocketFrameAdded,
                 .webSocketClosed:
                guard let existingEntry else {
                    return
                }
                apply(update, toTrackedEntry: existingEntry)
            }
        }
    }

    package func apply(
        _ payload: NetworkWire.PageHook.Event,
        sessionID: String
    ) {
        guard let update = NetworkEntry.Update(payload: payload) else {
            return
        }
        apply(update, sessionID: sessionID)
    }

    package func applyResourceTimingBatch(_ batch: NetworkWire.PageHook.Batch) {
        guard isRecording else {
            return
        }

        performEntriesGenerationBatch {
            for payload in batch.events where payload.kindValue == .resourceTiming {
                apply(payload, sessionID: batch.sessionID)
            }
        }
    }

    func applyNetworkBatch(_ batch: NetworkWire.PageHook.Batch) {
        guard isRecording else {
            return
        }

        performEntriesGenerationBatch {
            for payload in batch.events {
                apply(payload, sessionID: batch.sessionID)
            }
        }
    }

    @discardableResult
    package func applySnapshots(_ snapshots: [NetworkEntry.Snapshot]) -> [NetworkEntry] {
        guard isRecording, !snapshots.isEmpty else {
            return []
        }

        var insertedEntries: [NetworkEntry] = []
        insertedEntries.reserveCapacity(snapshots.count)

        performEntriesGenerationBatch {
            for snapshot in snapshots {
                let entry = NetworkEntry(snapshot: snapshot)
                appendEntry(entry)
                insertedEntries.append(entry)
            }
        }

        return insertedEntries.filter(entryIsTracked)
    }

    @discardableResult
    package func moveEntrySession(
        requestID: Int,
        from previousSessionID: String,
        to sessionID: String,
        previousRequestTargetIdentifier: String? = nil,
        requestTargetIdentifier: String? = nil,
        previousResponseTargetIdentifier: String? = nil,
        responseTargetIdentifier: String? = nil
    ) -> NetworkEntry? {
        let targetsChanged = previousRequestTargetIdentifier != requestTargetIdentifier
            || previousResponseTargetIdentifier != responseTargetIdentifier
        guard previousSessionID != sessionID || targetsChanged else {
            return entry(forRequestID: requestID, sessionID: sessionID)
        }
        guard let entry = entry(forRequestID: requestID, sessionID: previousSessionID) else {
            return nil
        }
        entry.rebindDeferredBodyTargets(
            previousRequestTargetIdentifier: previousRequestTargetIdentifier,
            requestTargetIdentifier: requestTargetIdentifier,
            previousResponseTargetIdentifier: previousResponseTargetIdentifier,
            responseTargetIdentifier: responseTargetIdentifier
        )
        if previousSessionID == sessionID {
            return entry
        }
        let previousBucketKey = sessionKey(for: previousSessionID)
        sessionBuckets[previousBucketKey]?.remove(requestID: requestID)
        entry.moveSession(to: sessionID)
        bucket(for: sessionID).set(entry, requestID: requestID)
        return entry
    }

    package func containsEntry(requestID: Int, sessionID: String?) -> Bool {
        entry(forRequestID: requestID, sessionID: sessionID) != nil
    }

    package func entry(requestID: Int, sessionID: String?) -> NetworkEntry? {
        entry(forRequestID: requestID, sessionID: sessionID)
    }

    package func updateEntrySession(
        _ entry: NetworkEntry,
        to sessionID: String,
        previousRequestTargetIdentifier: String? = nil,
        requestTargetIdentifier: String? = nil,
        previousResponseTargetIdentifier: String? = nil,
        responseTargetIdentifier: String? = nil
    ) {
        let previousSessionID = entry.sessionID
        let targetsChanged = previousRequestTargetIdentifier != requestTargetIdentifier
            || previousResponseTargetIdentifier != responseTargetIdentifier
        guard previousSessionID != sessionID || targetsChanged else {
            return
        }
        entry.rebindDeferredBodyTargets(
            previousRequestTargetIdentifier: previousRequestTargetIdentifier,
            requestTargetIdentifier: requestTargetIdentifier,
            previousResponseTargetIdentifier: previousResponseTargetIdentifier,
            responseTargetIdentifier: responseTargetIdentifier
        )
        if previousSessionID == sessionID {
            return
        }
        let previousBucketKey = sessionKey(for: previousSessionID)
        sessionBuckets[previousBucketKey]?.remove(requestID: entry.requestID)
        entry.moveSession(to: sessionID)
        bucket(for: sessionID).set(entry, requestID: entry.requestID)
    }

    package func updateEntrySession(
        requestID: Int,
        from previousSessionID: String,
        to sessionID: String,
        previousRequestTargetIdentifier: String? = nil,
        requestTargetIdentifier: String? = nil,
        previousResponseTargetIdentifier: String? = nil,
        responseTargetIdentifier: String? = nil
    ) {
        guard let entry = entry(forRequestID: requestID, sessionID: previousSessionID) else {
            return
        }
        updateEntrySession(
            entry,
            to: sessionID,
            previousRequestTargetIdentifier: previousRequestTargetIdentifier,
            requestTargetIdentifier: requestTargetIdentifier,
            previousResponseTargetIdentifier: previousResponseTargetIdentifier,
            responseTargetIdentifier: responseTargetIdentifier
        )
    }

    package func reset() {
        guard entries.isEmpty == false else {
            return
        }
        sessionBuckets.removeAll()
        entries.removeAll()
        markEntriesGenerationDirty()
    }

    package func clear() {
        reset()
    }

    package func setRecording(_ enabled: Bool) {
        isRecording = enabled
    }

    public func entry(forRequestID requestID: Int, sessionID: String?) -> NetworkEntry? {
        let bucketKey = sessionKey(for: sessionID)
        guard let bucket = sessionBuckets[bucketKey],
              let entry = bucket.entry(for: requestID) else {
            return nil
        }
        return entry
    }
}

private extension NetworkStore {
    func appendEntry(_ entry: NetworkEntry) {
        pruneIfNeeded(adding: 1)
        entries.append(entry)
        bucket(for: entry.sessionID).set(entry, requestID: entry.requestID)
        markEntriesGenerationDirty()
    }

    func entryIsTracked(_ entry: NetworkEntry) -> Bool {
        let key = sessionKey(for: entry.sessionID)
        guard let bucket = sessionBuckets[key],
              bucket.entry(for: entry.requestID) === entry else {
            return false
        }
        return entries.contains { $0 === entry }
    }

    func bucket(for sessionID: String?) -> SessionBucket {
        let key = sessionKey(for: sessionID)
        if let existing = sessionBuckets[key] {
            return existing
        }
        let bucket = SessionBucket()
        sessionBuckets[key] = bucket
        return bucket
    }

    func sessionKey(for sessionID: String?) -> String {
        guard let sessionID, !sessionID.isEmpty else {
            return "__default_session__"
        }
        return sessionID
    }

    func pruneIfNeeded(adding additionalCount: Int) {
        guard let maxEntries = maxEntriesStorage, maxEntries > 0 else {
            return
        }
        let totalAfterAppend = entries.count + additionalCount
        let excess = totalAfterAppend - maxEntries
        guard excess > 0 else {
            return
        }
        if excess >= entries.count {
            reset()
            return
        }
        entries.removeFirst(excess)
        rebuildIndexAndBuckets()
        markEntriesGenerationDirty()
    }

    func rebuildIndexAndBuckets() {
        sessionBuckets.removeAll()

        for entry in entries {
            bucket(for: entry.sessionID).set(entry, requestID: entry.requestID)
        }
    }

    func performEntriesGenerationBatch(_ operation: () -> Void) {
        entriesGenerationBatchDepth += 1
        defer {
            entriesGenerationBatchDepth -= 1
            flushEntriesGenerationIfNeeded()
        }
        operation()
    }

    func markEntriesGenerationDirty() {
        hasPendingEntriesGenerationBump = true
        flushEntriesGenerationIfNeeded()
    }

    func apply(
        _ update: NetworkEntry.Update,
        toTrackedEntry entry: NetworkEntry
    ) {
        entry.apply(update)
        if updateRequiresListInvalidation(update) {
            markEntriesGenerationDirty()
        }
    }

    func updateRequiresListInvalidation(_ update: NetworkEntry.Update) -> Bool {
        switch update {
        case .requestStarted,
             .responseReceived,
             .completed,
             .failed,
             .resourceTimingSnapshot,
             .webSocketHandshake,
             .webSocketClosed:
            return true
        case .webSocketFrameAdded:
            return false
        case .webSocketOpened:
            assertionFailure("Unexpected tracked-entry update: webSocketOpened")
            return false
        }
    }

    func flushEntriesGenerationIfNeeded() {
        guard entriesGenerationBatchDepth == 0, hasPendingEntriesGenerationBump else {
            return
        }
        hasPendingEntriesGenerationBump = false
        entriesGeneration &+= 1
    }
}

private extension NetworkEntry.Update {
    init?(payload: NetworkWire.PageHook.Event) {
        guard let kind = payload.kindValue else {
            return nil
        }

        switch kind {
        case .requestWillBeSent:
            self = .requestStarted(
                .init(
                    requestID: payload.requestId,
                    request: NetworkEntry.Request(
                        url: payload.url ?? "",
                        method: payload.normalizedMethod ?? "UNKNOWN",
                        headers: NetworkHeaders(dictionary: payload.headers ?? [:]),
                        body: payload.requestBody,
                        bodyBytesSent: payload.requestBodyBytesSent,
                        type: payload.initiator,
                        wallTime: payload.wallTimeSeconds
                    ),
                    timestamp: payload.timeSeconds
                )
            )
        case .responseReceived:
            self = .responseReceived(
                .init(
                    requestID: payload.requestId,
                    response: NetworkEntry.Response(
                        statusCode: payload.status,
                        statusText: payload.statusText ?? "",
                        mimeType: payload.mimeType,
                        headers: NetworkHeaders(dictionary: payload.headers ?? [:]),
                        body: nil,
                        blockedCookies: [],
                        errorDescription: nil
                    ),
                    requestType: payload.initiator,
                    timestamp: payload.timeSeconds
                )
            )
        case .loadingFinished:
            self = .completed(
                .init(
                    requestID: payload.requestId,
                    response: NetworkEntry.Response(
                        statusCode: payload.status,
                        statusText: payload.statusText ?? "",
                        mimeType: payload.mimeType,
                        headers: NetworkHeaders(),
                        body: payload.responseBody,
                        blockedCookies: [],
                        errorDescription: nil
                    ),
                    requestType: payload.initiator,
                    timestamp: payload.timeSeconds,
                    encodedBodyLength: payload.encodedBodyLength,
                    decodedBodyLength: payload.resolvedDecodedBodySize
                )
            )
        case .loadingFailed:
            self = .failed(
                .init(
                    requestID: payload.requestId,
                    response: NetworkEntry.Response(
                        statusCode: payload.status,
                        statusText: payload.statusText ?? "",
                        mimeType: payload.mimeType,
                        headers: NetworkHeaders(),
                        body: nil,
                        blockedCookies: [],
                        errorDescription: payload.error?.message ?? ""
                    ),
                    requestType: payload.initiator,
                    timestamp: payload.timeSeconds
                )
            )
        case .resourceTiming:
            self = .resourceTimingSnapshot(
                .init(
                    requestID: payload.requestId,
                    request: NetworkEntry.Request(
                        url: payload.url ?? "",
                        method: payload.normalizedMethod ?? "GET",
                        headers: NetworkHeaders(),
                        body: nil,
                        bodyBytesSent: nil,
                        type: payload.initiator,
                        wallTime: payload.resourceTimingWallTimeSeconds
                    ),
                    response: NetworkEntry.Response(
                        statusCode: payload.status,
                        statusText: payload.statusText ?? "",
                        mimeType: payload.mimeType,
                        headers: NetworkHeaders(dictionary: payload.headers ?? [:]),
                        body: payload.responseBody,
                        blockedCookies: [],
                        errorDescription: nil
                    ),
                    startTimestamp: payload.resourceTimingStartSeconds,
                    endTimestamp: payload.resourceTimingEndSeconds,
                    encodedBodyLength: payload.encodedBodyLength,
                    decodedBodyLength: payload.resolvedDecodedBodySize
                )
            )
        }
    }
}

private extension NetworkWire.PageHook.Event {
    var timeSeconds: TimeInterval {
        let nowSeconds = Date().timeIntervalSince1970
        return time.map { $0.monotonicMs / 1000.0 }
            ?? startTime.map { $0.monotonicMs / 1000.0 }
            ?? endTime.map { $0.monotonicMs / 1000.0 }
            ?? nowSeconds
    }

    var wallTimeSeconds: TimeInterval? {
        time.map { $0.wallMs / 1000.0 } ?? startTime.map { $0.wallMs / 1000.0 }
    }

    var resourceTimingStartSeconds: TimeInterval {
        startTime.map { $0.monotonicMs / 1000.0 } ?? timeSeconds
    }

    var resourceTimingEndSeconds: TimeInterval? {
        endTime.map { $0.monotonicMs / 1000.0 }
    }

    var resourceTimingWallTimeSeconds: TimeInterval? {
        startTime.map { $0.wallMs / 1000.0 } ?? wallTimeSeconds
    }

    var requestBody: NetworkBody? {
        guard let body else {
            return nil
        }
        return NetworkBody.from(payload: body, role: .request)
    }

    var responseBody: NetworkBody? {
        guard let body else {
            return nil
        }
        return NetworkBody.from(payload: body, role: .response)
    }

    var requestBodyBytesSent: Int? {
        if let bodySize {
            return bodySize
        }
        return requestBody?.size
    }

    var resolvedDecodedBodySize: Int? {
        if let decodedBodySize {
            return decodedBodySize
        }
        return responseBody?.size
    }
}

private final class SessionBucket {
    private struct WeakEntry {
        weak var value: NetworkEntry?
    }

    private var entriesByRequestID: [Int: WeakEntry] = [:]

    func entry(for requestID: Int) -> NetworkEntry? {
        entriesByRequestID[requestID]?.value
    }

    func set(_ entry: NetworkEntry, requestID: Int) {
        entriesByRequestID[requestID] = WeakEntry(value: entry)
    }

    func remove(requestID: Int) {
        entriesByRequestID.removeValue(forKey: requestID)
    }
}
