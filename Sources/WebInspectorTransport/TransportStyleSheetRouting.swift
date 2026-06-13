import Foundation

struct ResolvedStyleSheetAddedEvent: Sendable {
    var targetID: ProtocolTargetIdentifier
    var paramsData: Data
}

struct TransportStyleSheetRouting: Sendable {
    private enum Route: Sendable {
        case resolved(ProtocolTargetIdentifier)
        case unresolved(frameID: DOMFrameIdentifier, addedParamsData: Data)

        var targetID: ProtocolTargetIdentifier? {
            guard case let .resolved(targetID) = self else {
                return nil
            }
            return targetID
        }

        var unresolvedFrameID: DOMFrameIdentifier? {
            guard case let .unresolved(frameID, _) = self else {
                return nil
            }
            return frameID
        }

        var unresolvedAddedParamsData: Data? {
            guard case let .unresolved(_, paramsData) = self else {
                return nil
            }
            return paramsData
        }
    }

    private var routesByStyleSheetID: [String: Route] = [:]

    func targetID(for styleSheetID: String) -> ProtocolTargetIdentifier? {
        routesByStyleSheetID[styleSheetID]?.targetID
    }

    func hasUnresolvedStyleSheet(_ styleSheetID: String) -> Bool {
        routesByStyleSheetID[styleSheetID]?.unresolvedFrameID != nil
    }

    mutating func recordAdded(
        styleSheetID: String,
        frameID: DOMFrameIdentifier?,
        paramsData: Data,
        resolvedTargetID: ProtocolTargetIdentifier?
    ) {
        if let frameID, resolvedTargetID == nil {
            routesByStyleSheetID[styleSheetID] = .unresolved(frameID: frameID, addedParamsData: paramsData)
            return
        }

        guard let resolvedTargetID else {
            return
        }
        routesByStyleSheetID[styleSheetID] = .resolved(resolvedTargetID)
    }

    mutating func remove(styleSheetID: String) {
        routesByStyleSheetID.removeValue(forKey: styleSheetID)
    }

    mutating func removeTarget(_ targetID: ProtocolTargetIdentifier) {
        routesByStyleSheetID = routesByStyleSheetID.filter {
            $0.value.targetID != targetID
        }
    }

    mutating func retarget(from oldTargetID: ProtocolTargetIdentifier, to newTargetID: ProtocolTargetIdentifier) {
        for (styleSheetID, route) in routesByStyleSheetID where route.targetID == oldTargetID {
            routesByStyleSheetID[styleSheetID] = .resolved(newTargetID)
        }
    }

    mutating func resolvePending(
        frameID: DOMFrameIdentifier,
        targetID: ProtocolTargetIdentifier
    ) -> [ResolvedStyleSheetAddedEvent] {
        let styleSheetIDs = routesByStyleSheetID
            .filter { $0.value.unresolvedFrameID == frameID }
            .map(\.key)
        var events: [ResolvedStyleSheetAddedEvent] = []
        for styleSheetID in styleSheetIDs {
            guard let paramsData = routesByStyleSheetID[styleSheetID]?.unresolvedAddedParamsData else {
                continue
            }
            routesByStyleSheetID[styleSheetID] = .resolved(targetID)
            events.append(
                ResolvedStyleSheetAddedEvent(
                    targetID: targetID,
                    paramsData: paramsData
                )
            )
        }
        return events
    }
}
