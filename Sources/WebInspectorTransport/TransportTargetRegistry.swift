import Foundation

struct TransportTargetRegistry: Sendable {
    private(set) var targetsByID: [ProtocolTargetIdentifier: ProtocolTargetRecord] = [:]
    private(set) var frameTargetIDsByFrameID: [DOMFrameIdentifier: ProtocolTargetIdentifier] = [:]
    private(set) var currentMainPageTargetID: ProtocolTargetIdentifier?

    var currentMainFrameID: DOMFrameIdentifier? {
        currentMainPageTargetID.flatMap { targetsByID[$0]?.frameID }
    }

    func target(for targetID: ProtocolTargetIdentifier) -> ProtocolTargetRecord? {
        targetsByID[targetID]
    }

    func containsTarget(_ targetID: ProtocolTargetIdentifier) -> Bool {
        targetsByID[targetID] != nil
    }

    func targetID(forFrameID frameID: DOMFrameIdentifier) -> ProtocolTargetIdentifier? {
        frameTargetIDsByFrameID[frameID]
    }

    func targetKind(
        protocolType: String,
        frameID: DOMFrameIdentifier?,
        parentFrameID: DOMFrameIdentifier?,
        isProvisional: Bool?
    ) -> ProtocolTargetKind {
        let protocolKind = ProtocolTargetKind(protocolType: protocolType)
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
        deliveredTargetID: ProtocolTargetIdentifier,
        frameID: DOMFrameIdentifier?
    ) -> ProtocolTargetIdentifier {
        guard let frameID,
              let existingTargetID = frameTargetIDsByFrameID[frameID],
              targetsByID[existingTargetID]?.kind == .frame,
              targetsByID[deliveredTargetID]?.kind != .frame else {
            return deliveredTargetID
        }
        return existingTargetID
    }

    mutating func recordRuntimeContext(
        deliveredTargetID: ProtocolTargetIdentifier,
        frameID: DOMFrameIdentifier?
    ) -> ProtocolTargetIdentifier {
        let resolvedTargetID = resolvedTargetIDForRuntimeContext(
            deliveredTargetID: deliveredTargetID,
            frameID: frameID
        )
        if let frameID {
            frameTargetIDsByFrameID[frameID] = resolvedTargetID
        }
        return resolvedTargetID
    }

    mutating func recordTargetCreated(_ record: ProtocolTargetRecord) -> TransportFrameTargetResolution? {
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

    mutating func removeTarget(_ targetID: ProtocolTargetIdentifier) {
        targetsByID.removeValue(forKey: targetID)
        frameTargetIDsByFrameID = frameTargetIDsByFrameID.filter { $0.value != targetID }
        if currentMainPageTargetID == targetID {
            currentMainPageTargetID = nil
        }
    }

    mutating func commitTarget(
        oldTargetID: ProtocolTargetIdentifier?,
        newTargetID: ProtocolTargetIdentifier
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
        newTargetID: ProtocolTargetIdentifier
    ) -> ProtocolTargetIdentifier? {
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
        for record: ProtocolTargetRecord
    ) -> TransportFrameTargetResolution? {
        guard let frameID = record.frameID,
              !record.isProvisional else {
            return nil
        }
        return TransportFrameTargetResolution(frameID: frameID, targetID: record.id)
    }
}

private extension ProtocolTargetRecord {
    var isTopLevelPage: Bool {
        kind == .page && parentFrameID == nil
    }
}

struct TransportFrameTargetResolution: Sendable {
    var frameID: DOMFrameIdentifier
    var targetID: ProtocolTargetIdentifier
}

struct TransportTargetCommitMutation: Sendable {
    var committedOldTargetID: ProtocolTargetIdentifier?
    var shouldRetargetExternalState: Bool
    var resolvedFrameTarget: TransportFrameTargetResolution?
}
