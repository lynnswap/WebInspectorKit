import WebInspectorCoreRuntime
import WebInspectorCoreSupport
import Observation
import WebInspectorTransport

package struct FrameDocumentOwnerHydrationCandidate {
    package var frameTargetID: ProtocolTarget.ID
    package var document: DOMDocument
    package var node: DOMNode
}

/// Owns frame-target document projection state.
///
/// WebKit keeps frame-target documents separate from the page DOM and projects them
/// under iframe owner nodes for display. This coordinator mirrors that ownership:
/// `DOMSession` owns documents and target metadata, while this type owns the
/// pending/attached/ambiguous projection relation between them.
@MainActor
@Observable
package final class FrameDocumentProjectionCoordinator {
    private let index: FrameDocumentProjectionIndex

    package init(index: FrameDocumentProjectionIndex = FrameDocumentProjectionIndex()) {
        self.index = index
    }

    package func removeAll() {
        index.removeAll()
    }

    @discardableResult
    package func removeProjection(for frameTargetID: ProtocolTarget.ID) -> FrameDocumentProjection? {
        index.removeValue(forKey: frameTargetID)
    }

    package func detachProjectionIfDocumentMatches(
        frameTargetID: ProtocolTarget.ID,
        documentID: DOMDocument.ID
    ) {
        guard let projection = index[frameTargetID],
              projection.frameDocumentID == documentID else {
            return
        }
        index.detach(frameTargetID: frameTargetID)
    }

    @discardableResult
    package func moveProjection(
        from oldTargetID: ProtocolTarget.ID,
        to newTargetID: ProtocolTarget.ID,
        currentPageTargetID: ProtocolTarget.ID?,
        targetGraph: TargetGraph,
        documentStore: DOMDocumentStore
    ) -> Bool {
        guard index.moveProjection(from: oldTargetID, to: newTargetID) != nil else {
            return false
        }
        updateProjectionState(
            frameTargetID: newTargetID,
            currentPageTargetID: currentPageTargetID,
            targetGraph: targetGraph,
            documentStore: documentStore
        )
        return true
    }

    package func setFrameDocument(
        frameTargetID: ProtocolTarget.ID,
        frameDocumentID: DOMDocument.ID
    ) {
        index.setFrameDocument(frameTargetID: frameTargetID, frameDocumentID: frameDocumentID)
    }

    package func updateAllProjectionStates(
        currentPageTargetID: ProtocolTarget.ID?,
        targetGraph: TargetGraph,
        documentStore: DOMDocumentStore
    ) {
        for frameTargetID in Array(index.frameTargetIDs) {
            updateProjectionState(
                frameTargetID: frameTargetID,
                currentPageTargetID: currentPageTargetID,
                targetGraph: targetGraph,
                documentStore: documentStore
            )
        }
    }

    package func updateProjectionState(
        frameTargetID: ProtocolTarget.ID,
        currentPageTargetID: ProtocolTarget.ID?,
        targetGraph: TargetGraph,
        documentStore: DOMDocumentStore
    ) {
        guard let projection = index[frameTargetID] else {
            return
        }

        switch resolver(
            currentPageTargetID: currentPageTargetID,
            targetGraph: targetGraph,
            documentStore: documentStore
        )
        .resolve(projection) {
        case let .attach(ownerNodeID):
            index.attach(frameTargetID: frameTargetID, to: ownerNodeID)
        case let .detach(state):
            index.detach(frameTargetID: frameTargetID, state: state)
        }
    }

    package func ownerHydrationCandidate(
        currentPageTargetID: ProtocolTarget.ID?,
        targetGraph: TargetGraph,
        documentStore: DOMDocumentStore
    ) -> FrameDocumentOwnerHydrationCandidate? {
        guard let pendingProjection = index.values
            .sorted(by: { $0.frameTargetID.rawValue < $1.frameTargetID.rawValue })
            .first(where: { $0.state == .pending }) else {
            return nil
        }
        let frameTargetID = pendingProjection.frameTargetID
        guard let ownerDocument = resolver(
            currentPageTargetID: currentPageTargetID,
            targetGraph: targetGraph,
            documentStore: documentStore
        )
        .ownerDocument(forFrameTargetID: frameTargetID),
            let node = ownerHydrationNode(in: ownerDocument) else {
            return nil
        }
        return FrameDocumentOwnerHydrationCandidate(
            frameTargetID: frameTargetID,
            document: ownerDocument,
            node: node
        )
    }

    package func projectedFrameOwnerKeys(
        inSubtree rootID: DOMNode.ID,
        nodeProvider: (DOMNode.ID) -> DOMNode?
    ) -> [ProtocolTarget.ID: DOMNode.CurrentKey] {
        index.ownerKeys(inSubtree: rootID, nodeProvider: nodeProvider)
    }

    package func reattachProjections(
        using ownerKeys: [ProtocolTarget.ID: DOMNode.CurrentKey],
        documentStore: DOMDocumentStore,
        nodeProvider: (DOMNode.ID) -> DOMNode?,
        canApplyDOMEvent: (DOMNode.ID) -> Bool
    ) {
        for (frameTargetID, ownerKey) in ownerKeys {
            guard index[frameTargetID] != nil,
                  let ownerNodeID = documentStore.currentNodeID(targetID: ownerKey.targetID, rawNodeID: ownerKey.nodeID),
                  let ownerNode = nodeProvider(ownerNodeID),
                  ownerNode.isFrameOwner,
                  canApplyDOMEvent(ownerNodeID) else {
                continue
            }
            index.attach(frameTargetID: frameTargetID, to: ownerNodeID)
        }
    }

    package func detachProjections(attachedTo ownerNodeID: DOMNode.ID) {
        for projection in index.values where projection.ownerNodeID == ownerNodeID {
            index.detach(frameTargetID: projection.frameTargetID)
        }
    }

    package func projectedFrameDocumentRootID(
        forOwnerNodeID ownerNodeID: DOMNode.ID,
        documentStore: DOMDocumentStore
    ) -> DOMNode.ID? {
        index.projectedFrameDocumentRootID(forOwnerNodeID: ownerNodeID) { documentID in
            documentStore.currentDocument(for: documentID)
        }
    }

    package func snapshots() -> [ProtocolTarget.ID: FrameDocumentProjection.Snapshot] {
        index.snapshots()
    }

    private func resolver(
        currentPageTargetID: ProtocolTarget.ID?,
        targetGraph: TargetGraph,
        documentStore: DOMDocumentStore
    ) -> FrameDocumentProjectionResolver {
        FrameDocumentProjectionResolver(
            currentPageTargetID: currentPageTargetID,
            targetGraph: targetGraph,
            documentStore: documentStore,
            projectionIndex: index
        )
    }

    private func ownerHydrationNode(in document: DOMDocument) -> DOMNode? {
        let roots = [bodyElement(in: document), documentElement(in: document), document.nodesByID[document.rootNodeID]]
            .compactMap { $0 }
        var pending = roots
        var visited = Set<DOMNode.ID>()
        while pending.isEmpty == false {
            let node = pending.removeFirst()
            guard visited.insert(node.id).inserted else {
                continue
            }
            if hasUnloadedRegularChildren(node) {
                return node
            }
            pending.append(
                contentsOf: node.regularChildren.loadedChildren.compactMap { document.nodesByID[$0] }
            )
        }
        return nil
    }

    private func hasUnloadedRegularChildren(_ node: DOMNode) -> Bool {
        guard case let .unrequested(count) = node.regularChildren else {
            return false
        }
        return count > 0
    }

    private func documentElement(in document: DOMDocument) -> DOMNode? {
        guard let root = document.nodesByID[document.rootNodeID] else {
            return nil
        }
        return root.regularChildren.loadedChildren
            .compactMap { document.nodesByID[$0] }
            .first { node in
                node.nodeType == .element && normalizedElementName(node) == "html"
            }
    }

    private func bodyElement(in document: DOMDocument) -> DOMNode? {
        guard let html = documentElement(in: document) else {
            return nil
        }
        return html.regularChildren.loadedChildren
            .compactMap { document.nodesByID[$0] }
            .first { node in
                node.nodeType == .element && normalizedElementName(node) == "body"
            }
    }

    private func normalizedElementName(_ node: DOMNode) -> String {
        (node.localName.isEmpty ? node.nodeName : node.localName).lowercased()
    }
}
