import Foundation

struct TransportPendingReply: Sendable {
    var domain: ProtocolDomain
    var method: String
    var targetID: ProtocolTargetIdentifier?
    var promise: ReplyPromise<ProtocolCommandResult>
    var hasBufferedProvisionalResponse: Bool
}

enum TransportPendingKey: Sendable {
    case root(UInt64)
    case target(TargetReplyKey)
}

struct TransportReplyStore: Sendable {
    private var rootReplies: [UInt64: TransportPendingReply] = [:]
    private var targetReplies: [TargetReplyKey: TransportPendingReply] = [:]
    private var targetReplyKeysByRootWrapperID: [UInt64: TargetReplyKey] = [:]

    var pendingRootReplyIDs: [UInt64] {
        rootReplies.keys.sorted()
    }

    var pendingTargetReplyKeys: [TargetReplyKey] {
        targetReplies.keys.sorted()
    }

    var pendingReplies: [TransportPendingReply] {
        Array(rootReplies.values) + Array(targetReplies.values)
    }

    mutating func insertRootReply(_ pending: TransportPendingReply, commandID: UInt64) {
        rootReplies[commandID] = pending
    }

    mutating func insertTargetReply(
        _ pending: TransportPendingReply,
        key: TargetReplyKey,
        rootWrapperID: UInt64
    ) {
        targetReplies[key] = pending
        targetReplyKeysByRootWrapperID[rootWrapperID] = key
    }

    mutating func removeRootReply(commandID: UInt64) -> TransportPendingReply? {
        rootReplies.removeValue(forKey: commandID)
    }

    mutating func takeTargetReplyKey(forRootWrapperID rootWrapperID: UInt64) -> TargetReplyKey? {
        targetReplyKeysByRootWrapperID.removeValue(forKey: rootWrapperID)
    }

    mutating func removeTargetReply(for key: TargetReplyKey) -> TransportPendingReply? {
        let pending = targetReplies.removeValue(forKey: key)
        if let wrapperID = targetReplyKeysByRootWrapperID.first(where: { $0.value == key })?.key {
            targetReplyKeysByRootWrapperID.removeValue(forKey: wrapperID)
        }
        return pending
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
        if let pending = targetReplies[key] {
            guard !pending.hasBufferedProvisionalResponse else {
                return nil
            }
            return removeTargetReply(for: key)
        }

        guard let retargetedKey = targetReplies.keys.first(where: { $0.commandID == key.commandID }) else {
            return nil
        }
        guard targetReplies[retargetedKey]?.hasBufferedProvisionalResponse != true else {
            return nil
        }
        return removeTargetReply(for: retargetedKey)
    }

    mutating func markTargetReplyAsBufferedIfNeeded(commandID: UInt64, targetID: ProtocolTargetIdentifier) {
        let key = TargetReplyKey(targetID: targetID, commandID: commandID)
        guard var pending = targetReplies[key] else {
            return
        }
        pending.hasBufferedProvisionalResponse = true
        targetReplies[key] = pending
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
            guard var pending = targetReplies.removeValue(forKey: oldKey) else {
                continue
            }
            let newKey = TargetReplyKey(targetID: newTargetID, commandID: oldKey.commandID)
            pending.targetID = newTargetID
            targetReplies[newKey] = pending
            if let wrapperID = targetReplyKeysByRootWrapperID.first(where: { $0.value == oldKey })?.key {
                targetReplyKeysByRootWrapperID[wrapperID] = newKey
            }
        }
    }

    mutating func removeAll() {
        rootReplies.removeAll()
        targetReplies.removeAll()
        targetReplyKeysByRootWrapperID.removeAll()
    }
}
