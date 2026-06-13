import Foundation

struct ResolvedStyleSheetAddedEvent: Sendable {
    var targetID: ProtocolTargetIdentifier
    var paramsData: Data
}

struct TransportStyleSheetRouting: Sendable {
    private var targetIDsByStyleSheetID: [String: ProtocolTargetIdentifier] = [:]
    private var unresolvedFrameIDsByStyleSheetID: [String: DOMFrameIdentifier] = [:]
    private var unresolvedAddedParamsDataByStyleSheetID: [String: Data] = [:]
    private var pendingResolvedAddedEvents: [ResolvedStyleSheetAddedEvent] = []

    func targetID(for styleSheetID: String) -> ProtocolTargetIdentifier? {
        targetIDsByStyleSheetID[styleSheetID]
    }

    func hasUnresolvedStyleSheet(_ styleSheetID: String) -> Bool {
        unresolvedFrameIDsByStyleSheetID[styleSheetID] != nil
    }

    mutating func recordAdded(
        styleSheetID: String,
        frameID: DOMFrameIdentifier?,
        paramsData: Data,
        resolvedTargetID: ProtocolTargetIdentifier?
    ) {
        if let frameID, resolvedTargetID == nil {
            targetIDsByStyleSheetID.removeValue(forKey: styleSheetID)
            unresolvedFrameIDsByStyleSheetID[styleSheetID] = frameID
            unresolvedAddedParamsDataByStyleSheetID[styleSheetID] = paramsData
            return
        }

        guard let resolvedTargetID else {
            return
        }
        targetIDsByStyleSheetID[styleSheetID] = resolvedTargetID
        unresolvedFrameIDsByStyleSheetID.removeValue(forKey: styleSheetID)
        unresolvedAddedParamsDataByStyleSheetID.removeValue(forKey: styleSheetID)
    }

    mutating func remove(styleSheetID: String) {
        targetIDsByStyleSheetID.removeValue(forKey: styleSheetID)
        unresolvedFrameIDsByStyleSheetID.removeValue(forKey: styleSheetID)
        unresolvedAddedParamsDataByStyleSheetID.removeValue(forKey: styleSheetID)
    }

    mutating func removeTarget(_ targetID: ProtocolTargetIdentifier) {
        targetIDsByStyleSheetID = targetIDsByStyleSheetID.filter { $0.value != targetID }
    }

    mutating func retarget(from oldTargetID: ProtocolTargetIdentifier, to newTargetID: ProtocolTargetIdentifier) {
        for (styleSheetID, targetID) in targetIDsByStyleSheetID where targetID == oldTargetID {
            targetIDsByStyleSheetID[styleSheetID] = newTargetID
        }
    }

    mutating func resolvePending(frameID: DOMFrameIdentifier, targetID: ProtocolTargetIdentifier) {
        let styleSheetIDs = unresolvedFrameIDsByStyleSheetID
            .filter { $0.value == frameID }
            .map(\.key)
        for styleSheetID in styleSheetIDs {
            targetIDsByStyleSheetID[styleSheetID] = targetID
            unresolvedFrameIDsByStyleSheetID.removeValue(forKey: styleSheetID)
            if let paramsData = unresolvedAddedParamsDataByStyleSheetID.removeValue(forKey: styleSheetID) {
                pendingResolvedAddedEvents.append(
                    ResolvedStyleSheetAddedEvent(
                        targetID: targetID,
                        paramsData: paramsData
                    )
                )
            }
        }
    }

    mutating func takePendingResolvedAddedEvents() -> [ResolvedStyleSheetAddedEvent] {
        let events = pendingResolvedAddedEvents
        pendingResolvedAddedEvents.removeAll(keepingCapacity: true)
        return events
    }
}
