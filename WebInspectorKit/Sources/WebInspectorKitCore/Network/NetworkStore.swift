import Foundation
import Observation

@MainActor
@Observable
public final class NetworkStore {
    public private(set) var isRecording = true
    public private(set) var entries: [NetworkEntry] = []
    @ObservationIgnored private var sessionBuckets: [String: SessionBucket] = [:]
    @ObservationIgnored private var indexByEntryID: [UUID: Int] = [:]
    @ObservationIgnored private var maxEntriesStorage: Int?

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

    func applyEvent(_ event: HTTPNetworkEvent) {
        applyHTTPEvent(event)
    }

    func applyEvent(_ event: WSNetworkEvent) {
        applyWSEvent(event)
    }

    func applyNetworkBatch(_ batch: NetworkEventBatch) {
        guard isRecording else { return }
        guard !batch.events.isEmpty else { return }

        var pendingResourceTimingEvents: [HTTPNetworkEvent] = []
        pendingResourceTimingEvents.reserveCapacity(batch.events.count)

        func flushPendingResourceTimingEvents() {
            guard !pendingResourceTimingEvents.isEmpty else { return }
            let resourceTimingBatch = NetworkEventBatch(
                version: batch.version,
                sessionID: batch.sessionID,
                seq: batch.seq,
                events: pendingResourceTimingEvents,
                dropped: nil
            )
            applyBatchedInsertions(resourceTimingBatch)
            pendingResourceTimingEvents.removeAll(keepingCapacity: true)
        }

        for event in batch.events {
            if event.kind == .resourceTiming {
                pendingResourceTimingEvents.append(event)
                continue
            }
            flushPendingResourceTimingEvents()
            applyHTTPEvent(event)
        }

        flushPendingResourceTimingEvents()
    }

    func applyBatchedInsertions(_ batch: NetworkEventBatch) {
        guard isRecording else { return }

        let events = batch.events
        guard !events.isEmpty else { return }

        let existingBucket = bucket(for: batch.sessionID)
        var staged: [(requestID: Int, entry: NetworkEntry)] = []
        var seenRequestIDs = Set<Int>()

        for event in events {
            guard event.kind == .resourceTiming else { continue }
            let requestID = event.requestID
            // Prevent duplicates within the same batch.
            if seenRequestIDs.contains(requestID) {
                continue
            }
            // Skip if an entry already exists from a non-batch path.
            if existingBucket.entry(for: requestID) != nil {
                continue
            }

            let entry = NetworkEntry(startPayload: event)
            entry.applyCompletionPayload(event, failed: false)
            staged.append((requestID, entry))
            seenRequestIDs.insert(requestID)
        }

        if staged.isEmpty {
            return
        }

        if let maxEntries = maxEntriesStorage, maxEntries > 0 {
            let totalAfterAppend = entries.count + staged.count
            let excess = totalAfterAppend - maxEntries
            if excess > 0 {
                if excess < entries.count {
                    entries.removeFirst(excess)
                    rebuildIndexAndBuckets()
                } else {
                    let existingCount = entries.count
                    reset()
                    let dropFromStaged = excess - existingCount
                    if dropFromStaged > 0 {
                        staged.removeFirst(min(dropFromStaged, staged.count))
                    }
                }
            }
        }

        let bucket = bucket(for: batch.sessionID)
        let startIndex = entries.count
        entries.append(contentsOf: staged.map(\.entry))

        for (offset, stagedEntry) in staged.enumerated() {
            let newIndex = startIndex + offset
            bucket.set(stagedEntry.entry, requestID: stagedEntry.requestID)
            indexByEntryID[stagedEntry.entry.id] = newIndex
        }
    }

    func applyHTTPEvent(_ event: HTTPNetworkEvent) {
        guard isRecording else { return }

        switch event.kind {
        case .requestWillBeSent:
            handleStart(event)
        case .responseReceived:
            handleResponse(event)
        case .loadingFinished:
            handleFinish(event, failed: false)
        case .resourceTiming:
            handleResourceTiming(event)
        case .loadingFailed:
            handleFinish(event, failed: true)
        }
    }

    func applyWSEvent(_ event: WSNetworkEvent) {
        guard isRecording else { return }

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

    public func entry(forRequestID requestID: Int, sessionID: String?) -> NetworkEntry? {
        let bucketKey = sessionKey(for: sessionID)
        guard let bucket = sessionBuckets[bucketKey],
              let entry = bucket.entry(for: requestID) else {
            return nil
        }
        return entry
    }

    public func entry(forEntryID id: UUID?) -> NetworkEntry? {
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
        appendEntry(NetworkEntry(startPayload: event))
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
        let entry = NetworkEntry(startPayload: event)
        appendEntry(entry)
        entry.applyCompletionPayload(event, failed: false)
    }

    private func handleWebSocketCreated(_ event: WSNetworkEvent) {
        let bucket = bucket(for: event.sessionID)
        if bucket.entry(for: event.requestID) != nil {
            return
        }
        let entry = NetworkEntry(
            sessionID: event.sessionID,
            requestID: event.requestID,
            url: event.url ?? "",
            method: "GET",
            requestHeaders: NetworkHeaders(),
            startTimestamp: event.startTimeSeconds,
            wallTime: event.wallTimeSeconds
        )
        entry.requestType = "websocket"
        entry.webSocket = NetworkWebSocketInfo()
        entry.refreshFileTypeLabel()
        appendEntry(entry)
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
        let info = entry.webSocket ?? NetworkWebSocketInfo()
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

    private func appendEntry(_ entry: NetworkEntry) {
        pruneIfNeeded(adding: 1)
        entries.append(entry)
        let newIndex = entries.count - 1
        let bucket = bucket(for: entry.sessionID)
        bucket.set(entry, requestID: entry.requestID)
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

    private func pruneIfNeeded(adding additionalCount: Int) {
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
    }

    private func rebuildIndexAndBuckets() {
        sessionBuckets.removeAll()
        indexByEntryID.removeAll()

        for (index, entry) in entries.enumerated() {
            indexByEntryID[entry.id] = index
            bucket(for: entry.sessionID).set(entry, requestID: entry.requestID)
        }
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
}
