import Foundation

extension TransportSession {
    struct PendingReply: Sendable {
        enum Purpose: Equatable, Sendable {
            case client
            case capability(
                key: ConnectionCapabilityKey,
                generation: WebInspectorPage.Generation,
                operationID: UInt64
            )
        }

        let purpose: Purpose
        let domain: ProtocolDomain
        let method: String
        let targetID: ProtocolTarget.ID?
        let promise: ReplyPromise<ProtocolCommand.Result>
        var hasBufferedProvisionalResponse: Bool

        private init(
            purpose: Purpose,
            domain: ProtocolDomain,
            method: String,
            targetID: ProtocolTarget.ID?,
            promise: ReplyPromise<ProtocolCommand.Result>
        ) {
            self.purpose = purpose
            self.domain = domain
            self.method = method
            self.targetID = targetID
            self.promise = promise
            hasBufferedProvisionalResponse = false
        }

        static func client(
            domain: ProtocolDomain,
            method: String,
            targetID: ProtocolTarget.ID?,
            promise: ReplyPromise<ProtocolCommand.Result>
        ) -> PendingReply {
            PendingReply(
                purpose: .client,
                domain: domain,
                method: method,
                targetID: targetID,
                promise: promise
            )
        }

        static func capability(
            domain: ProtocolDomain,
            method: String,
            targetID: ProtocolTarget.ID,
            promise: ReplyPromise<ProtocolCommand.Result>,
            key: ConnectionCapabilityKey,
            generation: WebInspectorPage.Generation,
            operationID: UInt64
        ) -> PendingReply {
            PendingReply(
                purpose: .capability(
                    key: key,
                    generation: generation,
                    operationID: operationID
                ),
                domain: domain,
                method: method,
                targetID: targetID,
                promise: promise
            )
        }
    }

    enum PendingKey: Hashable, Sendable {
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
        Array(pendingReplyRecords.values)
    }

    var pendingReplyRecords: [TransportSession.PendingKey: TransportSession.PendingReply] {
        var records = Dictionary(uniqueKeysWithValues: rootReplies.map { commandID, pending in
            (TransportSession.PendingKey.root(commandID), pending)
        })
        for (key, record) in targetReplies {
            let pendingKey = TransportSession.PendingKey.target(key)
            precondition(records[pendingKey] == nil, "A pending reply has duplicate routing ownership.")
            records[pendingKey] = record.pending
        }
        return records
    }

    var pendingReplyPurposes: [TransportSession.PendingKey: TransportSession.PendingReply.Purpose] {
        pendingReplyRecords.mapValues(\.purpose)
    }

    mutating func insertRootReply(_ pending: TransportSession.PendingReply, commandID: UInt64) {
        precondition(rootReplies[commandID] == nil, "A root command identifier already owns a pending reply.")
        rootReplies[commandID] = pending
    }

    mutating func insertTargetReply(
        _ pending: TransportSession.PendingReply,
        key: TransportSession.ReplyKey,
        rootWrapperID: UInt64
    ) {
        precondition(targetReplies[key] == nil, "A target reply key already owns a pending reply.")
        precondition(
            targetReplyKeysByCommandID[key.commandID] == nil,
            "A target command identifier already owns a pending reply."
        )
        precondition(
            targetReplyKeysByRootWrapperID[rootWrapperID] == nil,
            "A target wrapper identifier already owns a pending reply."
        )

        let record = TargetReplyRecord(pending: pending, rootWrapperID: rootWrapperID)
        targetReplies[key] = record
        insertIndexes(for: key, record: record)
    }

    mutating func removeRootReply(commandID: UInt64) -> TransportSession.PendingReply? {
        rootReplies.removeValue(forKey: commandID)
    }

    mutating func takeTargetReplyKey(forRootWrapperID rootWrapperID: UInt64) -> TransportSession.ReplyKey? {
        guard let key = targetReplyKeysByRootWrapperID.removeValue(forKey: rootWrapperID) else {
            return nil
        }
        precondition(
            targetReplies[key]?.rootWrapperID == rootWrapperID,
            "A target wrapper index does not match its pending reply owner."
        )
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

    @discardableResult
    mutating func removePendingReply(
        _ key: TransportSession.PendingKey
    ) -> TransportSession.PendingReply? {
        switch key {
        case let .root(commandID):
            rootReplies.removeValue(forKey: commandID)
        case let .target(targetReplyKey):
            removeTargetReply(for: targetReplyKey)
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

    mutating func removeAll() {
        rootReplies.removeAll()
        targetReplies.removeAll()
        targetReplyKeysByRootWrapperID.removeAll()
        targetReplyKeysByCommandID.removeAll()
    }

    private mutating func insertIndexes(for key: TransportSession.ReplyKey, record: TargetReplyRecord) {
        if let rootWrapperID = record.rootWrapperID {
            precondition(
                targetReplyKeysByRootWrapperID[rootWrapperID] == nil,
                "A target wrapper index already has an owner."
            )
            targetReplyKeysByRootWrapperID[rootWrapperID] = key
        }
        precondition(
            targetReplyKeysByCommandID[key.commandID] == nil,
            "A target command index already has an owner."
        )
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
