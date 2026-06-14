import Observation
import WebInspectorTransport

package struct FrameDocumentProjection: Equatable, Sendable {
    package var ownerNodeID: DOMNode.ID?
    package var frameTargetID: ProtocolTarget.ID
    package var frameDocumentID: DOMDocument.ID
    package var state: FrameDocumentProjection.State

    package init(
        ownerNodeID: DOMNode.ID?,
        frameTargetID: ProtocolTarget.ID,
        frameDocumentID: DOMDocument.ID,
        state: FrameDocumentProjection.State
    ) {
        self.ownerNodeID = ownerNodeID
        self.frameTargetID = frameTargetID
        self.frameDocumentID = frameDocumentID
        self.state = state
    }
}

@MainActor
@Observable
package final class FrameDocumentProjectionIndex {
    private var projectionsByFrameTargetID: [ProtocolTarget.ID: FrameDocumentProjection]

    package init() {
        projectionsByFrameTargetID = [:]
    }

    package var values: Dictionary<ProtocolTarget.ID, FrameDocumentProjection>.Values {
        projectionsByFrameTargetID.values
    }

    package var frameTargetIDs: Dictionary<ProtocolTarget.ID, FrameDocumentProjection>.Keys {
        projectionsByFrameTargetID.keys
    }

    package subscript(frameTargetID: ProtocolTarget.ID) -> FrameDocumentProjection? {
        projectionsByFrameTargetID[frameTargetID]
    }

    package func removeAll() {
        projectionsByFrameTargetID.removeAll()
    }

    @discardableResult
    package func removeValue(forKey frameTargetID: ProtocolTarget.ID) -> FrameDocumentProjection? {
        projectionsByFrameTargetID.removeValue(forKey: frameTargetID)
    }

    @discardableResult
    package func moveProjection(
        from oldTargetID: ProtocolTarget.ID,
        to newTargetID: ProtocolTarget.ID
    ) -> FrameDocumentProjection? {
        guard var projection = projectionsByFrameTargetID.removeValue(forKey: oldTargetID) else {
            return nil
        }
        projection.frameTargetID = newTargetID
        projectionsByFrameTargetID[newTargetID] = projection
        return projection
    }

    @discardableResult
    package func setFrameDocument(
        frameTargetID: ProtocolTarget.ID,
        frameDocumentID: DOMDocument.ID
    ) -> FrameDocumentProjection {
        var projection = projectionsByFrameTargetID[frameTargetID] ?? FrameDocumentProjection(
            ownerNodeID: nil,
            frameTargetID: frameTargetID,
            frameDocumentID: frameDocumentID,
            state: .pending
        )
        projection.frameTargetID = frameTargetID
        projection.frameDocumentID = frameDocumentID
        projection.ownerNodeID = nil
        projection.state = .pending
        projectionsByFrameTargetID[frameTargetID] = projection
        return projection
    }

    package func attach(frameTargetID: ProtocolTarget.ID, to ownerNodeID: DOMNode.ID) {
        guard var projection = projectionsByFrameTargetID[frameTargetID] else {
            return
        }
        projection.ownerNodeID = ownerNodeID
        projection.state = .attached
        projectionsByFrameTargetID[frameTargetID] = projection
    }

    package func detach(
        frameTargetID: ProtocolTarget.ID,
        state: FrameDocumentProjection.State = .pending
    ) {
        guard var projection = projectionsByFrameTargetID[frameTargetID] else {
            return
        }
        projection.ownerNodeID = nil
        projection.state = state
        projectionsByFrameTargetID[frameTargetID] = projection
    }

    package func projectedFrameDocumentRootID(
        forOwnerNodeID ownerNodeID: DOMNode.ID,
        documentProvider: (DOMDocument.ID) -> DOMDocument?
    ) -> DOMNode.ID? {
        for projection in projectionsByFrameTargetID.values
            where projection.ownerNodeID == ownerNodeID && projection.state == .attached {
            guard let document = documentProvider(projection.frameDocumentID) else {
                continue
            }
            return document.rootNodeID
        }
        return nil
    }

    package func ownerKeys(
        inSubtree rootID: DOMNode.ID,
        nodeProvider: (DOMNode.ID) -> DOMNode?
    ) -> [ProtocolTarget.ID: DOMNode.CurrentKey] {
        var keys: [ProtocolTarget.ID: DOMNode.CurrentKey] = [:]
        var stack = [rootID]
        while let nodeID = stack.popLast() {
            guard let node = nodeProvider(nodeID) else {
                continue
            }
            for projection in projectionsByFrameTargetID.values where projection.ownerNodeID == nodeID {
                keys[projection.frameTargetID] = DOMNode.CurrentKey(
                    targetID: nodeID.documentID.targetID,
                    nodeID: node.protocolNodeID
                )
            }
            stack.append(contentsOf: node.protocolOwnedChildren)
        }
        return keys
    }

    package func snapshots() -> [ProtocolTarget.ID: FrameDocumentProjection.Snapshot] {
        projectionsByFrameTargetID.mapValues { projection in
            FrameDocumentProjection.Snapshot(
                ownerNodeID: projection.ownerNodeID,
                frameTargetID: projection.frameTargetID,
                frameDocumentID: projection.frameDocumentID,
                state: projection.state
            )
        }
    }
}
