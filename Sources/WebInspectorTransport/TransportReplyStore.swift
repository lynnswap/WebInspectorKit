import Foundation

struct TransportPendingReply: Sendable {
    var domain: ProtocolDomain
    var method: String
    var targetID: ProtocolTargetIdentifier?
    var promise: ReplyPromise<ProtocolCommandResult>
    var hasBufferedProvisionalResponse: Bool
}

private struct TargetReplyRecord: Sendable {
    var pending: TransportPendingReply
    var rootWrapperID: UInt64?
}

enum TransportPendingKey: Sendable {
    case root(UInt64)
    case target(TargetReplyKey)
}

struct TransportReplyStore: Sendable {
    private var rootReplies: [UInt64: TransportPendingReply] = [:]
    private var targetReplies: [TargetReplyKey: TargetReplyRecord] = [:]

    var pendingRootReplyIDs: [UInt64] {
        rootReplies.keys.sorted()
    }

    var pendingTargetReplyKeys: [TargetReplyKey] {
        targetReplies.keys.sorted()
    }

    var pendingReplies: [TransportPendingReply] {
        Array(rootReplies.values) + targetReplies.values.map(\.pending)
    }

    mutating func insertRootReply(_ pending: TransportPendingReply, commandID: UInt64) {
        rootReplies[commandID] = pending
    }

    mutating func insertTargetReply(
        _ pending: TransportPendingReply,
        key: TargetReplyKey,
        rootWrapperID: UInt64
    ) {
        targetReplies[key] = TargetReplyRecord(pending: pending, rootWrapperID: rootWrapperID)
    }

    mutating func removeRootReply(commandID: UInt64) -> TransportPendingReply? {
        rootReplies.removeValue(forKey: commandID)
    }

    mutating func takeTargetReplyKey(forRootWrapperID rootWrapperID: UInt64) -> TargetReplyKey? {
        guard let key = targetReplies.first(where: { $0.value.rootWrapperID == rootWrapperID })?.key else {
            return nil
        }
        targetReplies[key]?.rootWrapperID = nil
        return key
    }

    mutating func removeTargetReply(for key: TargetReplyKey) -> TransportPendingReply? {
        targetReplies.removeValue(forKey: key)?.pending
    }

    mutating func removePendingReply(_ key: TransportPendingKey) {
        switch key {
        case let .root(commandID):
            rootReplies.removeValue(forKey: commandID)
        case let .target(targetReplyKey):
            _ = removeTargetReply(for: targetReplyKey)
        }
    }

    mutating func removeTargetReplies(for targetID: ProtocolTargetIdentifier) -> [TransportPendingReply] {
        targetReplies.keys
            .filter { $0.targetID == targetID }
            .compactMap { removeTargetReply(for: $0) }
    }

    mutating func removeTargetReplyForTimeout(_ key: TargetReplyKey) -> TransportPendingReply? {
        if let record = targetReplies[key] {
            guard !record.pending.hasBufferedProvisionalResponse else {
                return nil
            }
            return removeTargetReply(for: key)
        }

        guard let retargetedKey = targetReplies.keys.first(where: { $0.commandID == key.commandID }) else {
            return nil
        }
        guard targetReplies[retargetedKey]?.pending.hasBufferedProvisionalResponse != true else {
            return nil
        }
        return removeTargetReply(for: retargetedKey)
    }

    mutating func markTargetReplyAsBufferedIfNeeded(commandID: UInt64, targetID: ProtocolTargetIdentifier) {
        let key = TargetReplyKey(targetID: targetID, commandID: commandID)
        guard var record = targetReplies[key] else {
            return
        }
        record.pending.hasBufferedProvisionalResponse = true
        targetReplies[key] = record
    }

    mutating func removeRetargetedReply(commandID: UInt64) -> TransportPendingReply? {
        guard let key = targetReplies.keys.first(where: { $0.commandID == commandID }) else {
            return nil
        }
        return removeTargetReply(for: key)
    }

    mutating func retargetPendingReplies(
        from oldTargetID: ProtocolTargetIdentifier,
        to newTargetID: ProtocolTargetIdentifier
    ) {
        let oldKeys = targetReplies.keys.filter { $0.targetID == oldTargetID }
        for oldKey in oldKeys {
            guard var record = targetReplies.removeValue(forKey: oldKey) else {
                continue
            }
            let newKey = TargetReplyKey(targetID: newTargetID, commandID: oldKey.commandID)
            record.pending.targetID = newTargetID
            targetReplies[newKey] = record
        }
    }

    mutating func removeAll() {
        rootReplies.removeAll()
        targetReplies.removeAll()
    }
}
