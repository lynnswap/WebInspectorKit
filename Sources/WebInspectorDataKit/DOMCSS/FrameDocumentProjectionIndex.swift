import WebInspectorProxyKit

struct FrameDocumentProjectionIndex {
    private var frameDocumentRootIDByTargetID: [WebInspectorTarget.ID: DOMNode.ID]
    private var ownerIDByTargetID: [WebInspectorTarget.ID: DOMNode.ID]
    private var targetIDByOwnerID: [DOMNode.ID: WebInspectorTarget.ID]

    init() {
        frameDocumentRootIDByTargetID = [:]
        ownerIDByTargetID = [:]
        targetIDByOwnerID = [:]
    }

    var frameTargetIDs: [WebInspectorTarget.ID] {
        Array(frameDocumentRootIDByTargetID.keys)
    }

    func frameDocumentRootID(for frameTargetID: WebInspectorTarget.ID) -> DOMNode.ID? {
        frameDocumentRootIDByTargetID[frameTargetID]
    }

    func projectedFrameDocumentRootID(forOwnerNodeID ownerNodeID: DOMNode.ID) -> DOMNode.ID? {
        guard let frameTargetID = targetIDByOwnerID[ownerNodeID] else {
            return nil
        }
        return frameDocumentRootIDByTargetID[frameTargetID]
    }

    func ownerNodeID(for frameTargetID: WebInspectorTarget.ID) -> DOMNode.ID? {
        ownerIDByTargetID[frameTargetID]
    }

    @discardableResult
    mutating func setFrameDocumentRootID(
        _ rootID: DOMNode.ID,
        for frameTargetID: WebInspectorTarget.ID
    ) -> DOMNode.ID? {
        let previousRootID = frameDocumentRootIDByTargetID.updateValue(rootID, forKey: frameTargetID)
        return previousRootID == rootID ? nil : previousRootID
    }

    @discardableResult
    mutating func attach(frameTargetID: WebInspectorTarget.ID, to ownerNodeID: DOMNode.ID) -> Bool {
        let wasAttached = ownerIDByTargetID[frameTargetID] == ownerNodeID
            && targetIDByOwnerID[ownerNodeID] == frameTargetID
        if let previousOwnerID = ownerIDByTargetID[frameTargetID],
           previousOwnerID != ownerNodeID {
            targetIDByOwnerID[previousOwnerID] = nil
        }
        if let previousFrameTargetID = targetIDByOwnerID[ownerNodeID],
           previousFrameTargetID != frameTargetID {
            ownerIDByTargetID[previousFrameTargetID] = nil
        }
        ownerIDByTargetID[frameTargetID] = ownerNodeID
        targetIDByOwnerID[ownerNodeID] = frameTargetID
        return wasAttached == false
    }

    @discardableResult
    mutating func detach(frameTargetID: WebInspectorTarget.ID) -> DOMNode.ID? {
        guard let ownerNodeID = ownerIDByTargetID.removeValue(forKey: frameTargetID) else {
            return nil
        }
        if targetIDByOwnerID[ownerNodeID] == frameTargetID {
            targetIDByOwnerID[ownerNodeID] = nil
        }
        return ownerNodeID
    }

    mutating func detachProjection(attachedTo ownerNodeID: DOMNode.ID) {
        guard let frameTargetID = targetIDByOwnerID.removeValue(forKey: ownerNodeID) else {
            return
        }
        ownerIDByTargetID[frameTargetID] = nil
    }

    mutating func removeFrameDocument(for frameTargetID: WebInspectorTarget.ID) {
        frameDocumentRootIDByTargetID[frameTargetID] = nil
        detach(frameTargetID: frameTargetID)
    }

    mutating func removeAll() {
        frameDocumentRootIDByTargetID = [:]
        ownerIDByTargetID = [:]
        targetIDByOwnerID = [:]
    }

    mutating func removeProjections(containing nodeIDs: Set<DOMNode.ID>) {
        for frameTargetID in frameTargetIDs {
            let rootID = frameDocumentRootIDByTargetID[frameTargetID]
            let ownerID = ownerIDByTargetID[frameTargetID]
            guard rootID.map(nodeIDs.contains) == true
                || ownerID.map(nodeIDs.contains) == true
            else {
                continue
            }
            removeFrameDocument(for: frameTargetID)
        }
    }
}
