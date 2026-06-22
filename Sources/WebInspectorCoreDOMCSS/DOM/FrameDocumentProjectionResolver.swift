import WebInspectorCoreRuntime
import WebInspectorCoreSupport
import Foundation
import WebInspectorTransport

package enum FrameDocumentProjectionResolution: Equatable, Sendable {
    case attach(ownerNodeID: DOMNode.ID)
    case detach(state: FrameDocumentProjection.State)
}

/// Resolves which frame-owner node should project a frame-target document; index mutation stays in `DOMSession`.
@MainActor
package struct FrameDocumentProjectionResolver {
    private let currentPageTargetID: ProtocolTarget.ID?
    private let targetGraph: TargetGraph
    private let documentStore: DOMDocumentStore
    private let projectionIndex: FrameDocumentProjectionIndex

    package init(
        currentPageTargetID: ProtocolTarget.ID?,
        targetGraph: TargetGraph,
        documentStore: DOMDocumentStore,
        projectionIndex: FrameDocumentProjectionIndex
    ) {
        self.currentPageTargetID = currentPageTargetID
        self.targetGraph = targetGraph
        self.documentStore = documentStore
        self.projectionIndex = projectionIndex
    }

    package func resolve(_ projection: FrameDocumentProjection) -> FrameDocumentProjectionResolution {
        guard let document = documentStore.currentDocument(for: projection.frameDocumentID),
              let frameRoot = document.node(for: document.rootNodeID) else {
            return .detach(state: .pending)
        }

        if let ownerNodeID = projection.ownerNodeID,
           projectionCanRemainAttached(projection, to: ownerNodeID, frameRoot: frameRoot) {
            return .attach(ownerNodeID: ownerNodeID)
        }

        let candidates = ownerCandidates(forFrameDocumentRoot: frameRoot)
        switch candidates.count {
        case 0:
            return .detach(state: .pending)
        case 1:
            return .attach(ownerNodeID: candidates[0])
        default:
            return .detach(state: .ambiguous)
        }
    }

    private func projectionCanRemainAttached(
        _ projection: FrameDocumentProjection,
        to ownerNodeID: DOMNode.ID,
        frameRoot: DOMNode
    ) -> Bool {
        guard let document = documentStore.currentDocument(for: ownerNodeID.documentID),
              let ownerNode = document.node(for: ownerNodeID) else {
            return false
        }
        let frameTargetID = frameRoot.id.documentID.targetID
        return ownerNode.isFrameOwner
            && ownerDocument(forFrameTargetID: frameTargetID)?.id == document.id
            && document.containsConnectedNode(ownerNodeID)
            && frameOwner(ownerNode, matchesFrameTargetID: frameTargetID, frameDocumentURL: frameRoot.documentURL)
            && projectionIndex.values.allSatisfy {
                $0.frameTargetID == projection.frameTargetID || $0.ownerNodeID != ownerNodeID || $0.state != .attached
            }
    }

    private func ownerCandidates(forFrameDocumentRoot frameRoot: DOMNode) -> [DOMNode.ID] {
        let frameTargetID = frameRoot.id.documentID.targetID
        guard let ownerDocument = ownerDocument(forFrameTargetID: frameTargetID) else {
            return []
        }

        let attachableCandidates = ownerDocument.nodesByID.values
            .filter { projectionCanAttach(to: $0, in: ownerDocument) }
        if let frameID = targetGraph.targetFrameID(for: frameTargetID) {
            let frameIDMatches = attachableCandidates
                .filter { $0.ownerFrameID == frameID }
            if frameIDMatches.isEmpty == false {
                return frameIDMatches
                    .map(\.id)
                    .sorted(by: sortNodeIDs)
            }
        }

        guard let frameDocumentURL = frameRoot.documentURL,
              frameDocumentURL.isEmpty == false else {
            return []
        }
        return attachableCandidates
            .filter { frameOwner($0, matchesFrameDocumentURL: frameDocumentURL) }
            .map(\.id)
            .sorted(by: sortNodeIDs)
    }

    package func ownerDocument(forFrameTargetID frameTargetID: ProtocolTarget.ID) -> DOMDocument? {
        guard targetGraph.containsTarget(frameTargetID) else {
            return nil
        }

        if let parentFrameID = targetGraph.targetParentFrameID(for: frameTargetID) {
            guard let parentDocumentID = targetGraph.frameCurrentDocumentID(parentFrameID) else {
                return nil
            }
            return documentStore.currentDocument(for: parentDocumentID)
        }
        guard let pageTargetID = currentPageTargetID,
              let pageDocument = documentStore.currentDocument(forTargetID: pageTargetID),
              pageDocument.lifecycle == .loaded else {
            return nil
        }
        return pageDocument
    }

    private func projectionCanAttach(to candidate: DOMNode, in document: DOMDocument) -> Bool {
        candidate.isFrameOwner
            && frameOwnerIsAlreadyAttached(candidate.id) == false
            && document.containsConnectedNode(candidate.id)
    }

    private func frameOwnerIsAlreadyAttached(_ nodeID: DOMNode.ID) -> Bool {
        projectionIndex.values.contains {
            $0.ownerNodeID == nodeID && $0.state == .attached
        }
    }

    private func sortNodeIDs(_ lhs: DOMNode.ID, _ rhs: DOMNode.ID) -> Bool {
        if lhs.documentID.targetID.rawValue != rhs.documentID.targetID.rawValue {
            return lhs.documentID.targetID.rawValue < rhs.documentID.targetID.rawValue
        }
        if lhs.documentID.localDocumentLifetimeID != rhs.documentID.localDocumentLifetimeID {
            return lhs.documentID.localDocumentLifetimeID < rhs.documentID.localDocumentLifetimeID
        }
        return lhs.nodeID.rawValue < rhs.nodeID.rawValue
    }

    private func frameOwner(_ owner: DOMNode, matchesFrameDocumentURL frameDocumentURL: String) -> Bool {
        guard let source = explicitFrameSource(for: owner) else {
            return frameDocumentURLIsDefaultBlank(frameDocumentURL)
        }
        if source == frameDocumentURL {
            return true
        }
        guard let resolvedSource = resolvedURL(source, relativeTo: documentURL(for: owner)),
              let resolvedFrameDocumentURL = resolvedURL(frameDocumentURL, relativeTo: nil) else {
            return false
        }
        return resolvedSource == resolvedFrameDocumentURL
    }

    private func frameOwner(
        _ owner: DOMNode,
        matchesFrameTargetID frameTargetID: ProtocolTarget.ID,
        frameDocumentURL: String?
    ) -> Bool {
        if let frameID = targetGraph.targetFrameID(for: frameTargetID),
           owner.ownerFrameID == frameID {
            return true
        }
        guard let frameDocumentURL,
              frameDocumentURL.isEmpty == false else {
            return false
        }
        return frameOwner(owner, matchesFrameDocumentURL: frameDocumentURL)
    }

    private func explicitFrameSource(for owner: DOMNode) -> String? {
        guard let source = attribute(named: "src", in: owner),
              source.isEmpty == false else {
            return nil
        }
        return source
    }

    private func frameDocumentURLIsDefaultBlank(_ url: String) -> Bool {
        url == "about:blank" || resolvedURL(url, relativeTo: nil) == "about:blank"
    }

    private func attribute(named name: String, in node: DOMNode) -> String? {
        node.attributes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func documentURL(for node: DOMNode) -> String? {
        guard let document = documentStore.currentDocument(for: node.id.documentID),
              let root = document.node(for: document.rootNodeID) else {
            return nil
        }
        return root.baseURL ?? root.documentURL
    }

    private func resolvedURL(_ string: String, relativeTo base: String?) -> String? {
        if let base,
           let baseURL = URL(string: base),
           let url = URL(string: string, relativeTo: baseURL) {
            return url.absoluteURL.absoluteString
        }
        return URL(string: string)?.absoluteURL.absoluteString
    }
}
