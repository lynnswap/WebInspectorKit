import WebInspectorCoreRuntime
import WebInspectorCoreSupport
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
    private var frameTargetIDByOwnerNodeID: [DOMNode.ID: ProtocolTarget.ID]

    package init() {
        projectionsByFrameTargetID = [:]
        frameTargetIDByOwnerNodeID = [:]
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
        frameTargetIDByOwnerNodeID.removeAll()
    }

    @discardableResult
    package func removeValue(forKey frameTargetID: ProtocolTarget.ID) -> FrameDocumentProjection? {
        guard let projection = projectionsByFrameTargetID.removeValue(forKey: frameTargetID) else {
            return nil
        }
        removeAttachedOwnerIndex(for: projection)
        return projection
    }

    @discardableResult
    package func moveProjection(
        from oldTargetID: ProtocolTarget.ID,
        to newTargetID: ProtocolTarget.ID
    ) -> FrameDocumentProjection? {
        guard var projection = projectionsByFrameTargetID.removeValue(forKey: oldTargetID) else {
            return nil
        }
        removeAttachedOwnerIndex(for: projection)
        if let replacedProjection = projectionsByFrameTargetID.removeValue(forKey: newTargetID) {
            removeAttachedOwnerIndex(for: replacedProjection)
        }
        projection.frameTargetID = newTargetID
        projectionsByFrameTargetID[newTargetID] = projection
        insertAttachedOwnerIndex(for: projection)
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
        removeAttachedOwnerIndex(for: projection)
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
        removeAttachedOwnerIndex(for: projection)
        projection.ownerNodeID = ownerNodeID
        projection.state = .attached
        projectionsByFrameTargetID[frameTargetID] = projection
        insertAttachedOwnerIndex(for: projection)
    }

    package func detach(
        frameTargetID: ProtocolTarget.ID,
        state: FrameDocumentProjection.State = .pending
    ) {
        guard var projection = projectionsByFrameTargetID[frameTargetID] else {
            return
        }
        removeAttachedOwnerIndex(for: projection)
        projection.ownerNodeID = nil
        projection.state = state
        projectionsByFrameTargetID[frameTargetID] = projection
    }

    package func projectedFrameDocumentRootID(
        forOwnerNodeID ownerNodeID: DOMNode.ID,
        documentProvider: (DOMDocument.ID) -> DOMDocument?
    ) -> DOMNode.ID? {
        guard let frameTargetID = frameTargetIDByOwnerNodeID[ownerNodeID],
              let projection = projectionsByFrameTargetID[frameTargetID],
              projection.ownerNodeID == ownerNodeID,
              projection.state == .attached,
              let document = documentProvider(projection.frameDocumentID) else {
            return nil
        }
        return document.rootNodeID
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

    private func removeAttachedOwnerIndex(for projection: FrameDocumentProjection) {
        guard projection.state == .attached,
              let ownerNodeID = projection.ownerNodeID,
              frameTargetIDByOwnerNodeID[ownerNodeID] == projection.frameTargetID else {
            return
        }
        frameTargetIDByOwnerNodeID.removeValue(forKey: ownerNodeID)
    }

    private func insertAttachedOwnerIndex(for projection: FrameDocumentProjection) {
        guard projection.state == .attached,
              let ownerNodeID = projection.ownerNodeID else {
            return
        }
        frameTargetIDByOwnerNodeID[ownerNodeID] = projection.frameTargetID
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
