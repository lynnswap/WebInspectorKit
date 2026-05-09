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
