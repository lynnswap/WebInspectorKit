import Foundation

extension TransportSession {
    struct PendingReply: Sendable {
        var domain: ProtocolDomain
        var method: String
        var targetID: ProtocolTarget.ID?
        var promise: ReplyPromise<ProtocolCommand.Result>
        var hasBufferedProvisionalResponse: Bool
    }

    enum PendingKey: Sendable {
        case root(UInt64)
        case target(ReplyKey)
    }
}

struct TransportReplyStore: Sendable {
    private struct TargetReplyRecord: Sendable {
        var pending: TransportSession.PendingReply
        var rootWrapperID: UInt64?
    }

    private var rootReplies: [UInt64: TransportSession.PendingReply] = [:]
    private var targetReplies: [TransportSession.ReplyKey: TargetReplyRecord] = [:]
    private var targetReplyKeysByRootWrapperID: [UInt64: TransportSession.ReplyKey] = [:]
    private var targetReplyKeysByCommandID: [UInt64: TransportSession.ReplyKey] = [:]

    var pendingRootReplyIDs: [UInt64] {
        rootReplies.keys.sorted()
    }

    var pendingTargetReplyKeys: [TransportSession.ReplyKey] {
        targetReplies.keys.sorted()
    }

    var pendingReplies: [TransportSession.PendingReply] {
        Array(rootReplies.values) + targetReplies.values.map(\.pending)
    }

    mutating func insertRootReply(_ pending: TransportSession.PendingReply, commandID: UInt64) {
        rootReplies[commandID] = pending
    }

    mutating func insertTargetReply(
        _ pending: TransportSession.PendingReply,
        key: TransportSession.ReplyKey,
        rootWrapperID: UInt64
    ) {
        if let existingKey = targetReplyKeysByCommandID[key.commandID] {
            _ = removeTargetReply(for: existingKey)
        }
        if let existingKey = targetReplyKeysByRootWrapperID[rootWrapperID] {
            _ = removeTargetReply(for: existingKey)
        }
        if let existingRecord = targetReplies.removeValue(forKey: key) {
            removeIndexes(for: key, record: existingRecord)
        }

        let record = TargetReplyRecord(pending: pending, rootWrapperID: rootWrapperID)
        targetReplies[key] = record
        insertIndexes(for: key, record: record)
    }

    mutating func removeRootReply(commandID: UInt64) -> TransportSession.PendingReply? {
        rootReplies.removeValue(forKey: commandID)
    }

    mutating func takeTargetReplyKey(forRootWrapperID rootWrapperID: UInt64) -> TransportSession.ReplyKey? {
        guard let key = targetReplyKeysByRootWrapperID.removeValue(forKey: rootWrapperID),
              targetReplies[key]?.rootWrapperID == rootWrapperID else {
            return nil
        }
        targetReplies[key]?.rootWrapperID = nil
        return key
    }

    mutating func removeTargetReply(for key: TransportSession.ReplyKey) -> TransportSession.PendingReply? {
        guard let record = targetReplies.removeValue(forKey: key) else {
            return nil
        }
        removeIndexes(for: key, record: record)
        return record.pending
    }

    mutating func removePendingReply(_ key: TransportSession.PendingKey) {
        switch key {
        case let .root(commandID):
            rootReplies.removeValue(forKey: commandID)
        case let .target(targetReplyKey):
            _ = removeTargetReply(for: targetReplyKey)
        }
    }

    mutating func removeTargetReplies(for targetID: ProtocolTarget.ID) -> [TransportSession.PendingReply] {
        targetReplies.keys
            .filter { $0.targetID == targetID }
            .compactMap { removeTargetReply(for: $0) }
    }

    mutating func removeTargetReplyForTimeout(_ key: TransportSession.ReplyKey) -> TransportSession.PendingReply? {
        if let record = targetReplies[key] {
            guard !record.pending.hasBufferedProvisionalResponse else {
                return nil
            }
            return removeTargetReply(for: key)
        }

        guard let retargetedKey = targetReplyKeysByCommandID[key.commandID] else {
            return nil
        }
        guard targetReplies[retargetedKey]?.pending.hasBufferedProvisionalResponse != true else {
            return nil
        }
        return removeTargetReply(for: retargetedKey)
    }

    mutating func markTargetReplyAsBufferedIfNeeded(commandID: UInt64, targetID: ProtocolTarget.ID) {
        let key = TransportSession.ReplyKey(targetID: targetID, commandID: commandID)
        guard var record = targetReplies[key] else {
            return
        }
        record.pending.hasBufferedProvisionalResponse = true
        targetReplies[key] = record
    }

    mutating func removeRetargetedReply(commandID: UInt64) -> TransportSession.PendingReply? {
        guard let key = targetReplyKeysByCommandID[commandID] else {
            return nil
        }
        return removeTargetReply(for: key)
    }

    mutating func retargetPendingReplies(
        from oldTargetID: ProtocolTarget.ID,
        to newTargetID: ProtocolTarget.ID
    ) {
        let oldKeys = targetReplies.keys.filter { $0.targetID == oldTargetID }
        for oldKey in oldKeys {
            guard var record = targetReplies.removeValue(forKey: oldKey) else {
                continue
            }
            removeIndexes(for: oldKey, record: record)
            let newKey = TransportSession.ReplyKey(targetID: newTargetID, commandID: oldKey.commandID)
            if let existingRecord = targetReplies.removeValue(forKey: newKey) {
                removeIndexes(for: newKey, record: existingRecord)
            }
            record.pending.targetID = newTargetID
            targetReplies[newKey] = record
            insertIndexes(for: newKey, record: record)
        }
    }

    mutating func removeAll() {
        rootReplies.removeAll()
        targetReplies.removeAll()
        targetReplyKeysByRootWrapperID.removeAll()
        targetReplyKeysByCommandID.removeAll()
    }

    private mutating func insertIndexes(for key: TransportSession.ReplyKey, record: TargetReplyRecord) {
        if let rootWrapperID = record.rootWrapperID {
            targetReplyKeysByRootWrapperID[rootWrapperID] = key
        }
        targetReplyKeysByCommandID[key.commandID] = key
    }

    private mutating func removeIndexes(for key: TransportSession.ReplyKey, record: TargetReplyRecord) {
        if let rootWrapperID = record.rootWrapperID,
           targetReplyKeysByRootWrapperID[rootWrapperID] == key {
            targetReplyKeysByRootWrapperID.removeValue(forKey: rootWrapperID)
        }
        if targetReplyKeysByCommandID[key.commandID] == key {
            targetReplyKeysByCommandID.removeValue(forKey: key.commandID)
        }
    }
}
