import Foundation

struct TransportTargetRegistry: Sendable {
    private(set) var targetsByID: [ProtocolTarget.ID: ProtocolTarget.Record] = [:]
    private(set) var frameTargetIDsByFrameID: [ProtocolFrame.ID: ProtocolTarget.ID] = [:]
    private(set) var currentMainPageTargetID: ProtocolTarget.ID?

    var currentMainFrameID: ProtocolFrame.ID? {
        currentMainPageTargetID.flatMap { targetsByID[$0]?.frameID }
    }

    func target(for targetID: ProtocolTarget.ID) -> ProtocolTarget.Record? {
        targetsByID[targetID]
    }

    func containsTarget(_ targetID: ProtocolTarget.ID) -> Bool {
        targetsByID[targetID] != nil
    }

    func targetID(forFrameID frameID: ProtocolFrame.ID) -> ProtocolTarget.ID? {
        frameTargetIDsByFrameID[frameID]
    }

    func targetKind(
        protocolType: String,
        frameID: ProtocolFrame.ID?,
        parentFrameID: ProtocolFrame.ID?,
        isProvisional: Bool?
    ) -> ProtocolTarget.Kind {
        let protocolKind = ProtocolTarget.Kind(protocolType: protocolType)
        guard protocolKind == .page else {
            return protocolKind
        }
        if parentFrameID != nil {
            return .frame
        }
        if let currentMainFrameID,
           let frameID,
           frameID != currentMainFrameID {
            return .frame
        }
        if currentMainFrameID == nil,
           isProvisional == true {
            return .frame
        }
        return .page
    }

    func resolvedTargetIDForRuntimeContext(
        deliveredTargetID: ProtocolTarget.ID,
        frameID: ProtocolFrame.ID?
    ) -> ProtocolTarget.ID {
        guard let frameID,
              let existingTargetID = frameTargetIDsByFrameID[frameID],
              targetsByID[existingTargetID]?.kind == .frame,
              targetsByID[deliveredTargetID]?.kind != .frame else {
            return deliveredTargetID
        }
        return existingTargetID
    }

    mutating func recordRuntimeContext(
        deliveredTargetID: ProtocolTarget.ID,
        frameID: ProtocolFrame.ID?
    ) -> ProtocolTarget.ID {
        let resolvedTargetID = resolvedTargetIDForRuntimeContext(
            deliveredTargetID: deliveredTargetID,
            frameID: frameID
        )
        if let frameID {
            frameTargetIDsByFrameID[frameID] = resolvedTargetID
        }
        return resolvedTargetID
    }

    mutating func recordTargetCreated(_ record: ProtocolTarget.Record) -> TransportFrameTargetResolution? {
        targetsByID[record.id] = record
        let resolvedFrameTarget = committedFrameTargetResolution(for: record)
        if let frameID = record.frameID {
            frameTargetIDsByFrameID[frameID] = record.id
        }
        if currentMainPageTargetID == nil,
           record.kind == .page,
           record.parentFrameID == nil,
           !record.isProvisional {
            currentMainPageTargetID = record.id
        }
        return resolvedFrameTarget
    }

    mutating func removeTarget(_ targetID: ProtocolTarget.ID) {
        targetsByID.removeValue(forKey: targetID)
        frameTargetIDsByFrameID = frameTargetIDsByFrameID.filter { $0.value != targetID }
        if currentMainPageTargetID == targetID {
            currentMainPageTargetID = nil
        }
    }

    mutating func commitTarget(
        oldTargetID: ProtocolTarget.ID?,
        newTargetID: ProtocolTarget.ID
    ) -> TransportTargetCommitMutation {
        let committedOldTargetID = oldTargetID ?? inferredOldTargetIDForOldlessCommit(newTargetID: newTargetID)

        if let oldTargetID = committedOldTargetID,
           oldTargetID == currentMainPageTargetID,
           let existingNewRecord = targetsByID[newTargetID],
           !existingNewRecord.isTopLevelPage {
            var committedSubframeRecord = existingNewRecord
            committedSubframeRecord.isProvisional = false
            targetsByID[newTargetID] = committedSubframeRecord
            if let frameID = committedSubframeRecord.frameID {
                frameTargetIDsByFrameID[frameID] = newTargetID
            }
            return TransportTargetCommitMutation(
                committedOldTargetID: committedOldTargetID,
                shouldRetargetExternalState: false,
                resolvedFrameTarget: committedFrameTargetResolution(for: committedSubframeRecord)
            )
        }

        let oldRecord = committedOldTargetID.flatMap { targetsByID.removeValue(forKey: $0) }
        guard oldRecord != nil || targetsByID[newTargetID] != nil else {
            return TransportTargetCommitMutation(
                committedOldTargetID: committedOldTargetID,
                shouldRetargetExternalState: false,
                resolvedFrameTarget: nil
            )
        }

        var newRecord = targetsByID[newTargetID] ?? oldRecord!
        newRecord.id = newTargetID
        newRecord.frameID = newRecord.frameID ?? oldRecord?.frameID
        newRecord.parentFrameID = newRecord.parentFrameID ?? oldRecord?.parentFrameID
        newRecord.isProvisional = false
        targetsByID[newTargetID] = newRecord

        if let oldTargetID = committedOldTargetID {
            frameTargetIDsByFrameID = frameTargetIDsByFrameID.filter { $0.value != oldTargetID }
        }

        if let frameID = newRecord.frameID {
            frameTargetIDsByFrameID[frameID] = newTargetID
        }
        if let oldTargetID = committedOldTargetID,
           currentMainPageTargetID == oldTargetID,
           newRecord.isTopLevelPage {
            currentMainPageTargetID = newTargetID
        }
        if currentMainPageTargetID == nil,
           newRecord.kind == .page,
           newRecord.parentFrameID == nil {
            currentMainPageTargetID = newTargetID
        }

        return TransportTargetCommitMutation(
            committedOldTargetID: committedOldTargetID,
            shouldRetargetExternalState: committedOldTargetID != nil,
            resolvedFrameTarget: committedFrameTargetResolution(for: newRecord)
        )
    }

    private func inferredOldTargetIDForOldlessCommit(
        newTargetID: ProtocolTarget.ID
    ) -> ProtocolTarget.ID? {
        if let newRecord = targetsByID[newTargetID],
           newRecord.isProvisional,
           newRecord.isTopLevelPage,
           let currentMainPageTargetID,
           currentMainPageTargetID != newTargetID {
            return currentMainPageTargetID
        }

        guard targetsByID[newTargetID] == nil else {
            return nil
        }

        let provisionalTargetIDs = targetsByID
            .filter { $0.value.isProvisional }
            .map(\.key)
        return provisionalTargetIDs.count == 1 ? provisionalTargetIDs[0] : nil
    }

    private func committedFrameTargetResolution(
        for record: ProtocolTarget.Record
    ) -> TransportFrameTargetResolution? {
        guard let frameID = record.frameID,
              !record.isProvisional else {
            return nil
        }
        return TransportFrameTargetResolution(frameID: frameID, targetID: record.id)
    }
}

private extension ProtocolTarget.Record {
    var isTopLevelPage: Bool {
        kind == .page && parentFrameID == nil
    }
}

struct TransportFrameTargetResolution: Sendable {
    var frameID: ProtocolFrame.ID
    var targetID: ProtocolTarget.ID
}

struct TransportTargetCommitMutation: Sendable {
    var committedOldTargetID: ProtocolTarget.ID?
    var shouldRetargetExternalState: Bool
    var resolvedFrameTarget: TransportFrameTargetResolution?
}
