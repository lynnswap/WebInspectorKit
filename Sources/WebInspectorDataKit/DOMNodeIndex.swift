import Foundation
import WebInspectorProxyKit

/// The DOM nodes of one attachment by identifier, and the frame documents
/// that are shown under the nodes that own their frames.
///
/// The index turns protocol payloads into ``DOMNode`` models, keeping the
/// model of a node that it already knows, and forgets the subtrees that a
/// payload no longer contains.
@MainActor
final class DOMNodeIndex {
    private var nodesByID: [DOMNode.ID: DOMNode] = [:]
    private var frameDocuments = FrameDocumentProjectionIndex()

    /// Called with the identifiers that a removed subtree took out of the
    /// index, in the same step.
    var didRemoveNodes: ((Set<DOMNode.ID>) -> Void)?
    #if DEBUG
    var didChangeForTesting: (() -> Void)?
    #endif

    subscript(id: DOMNode.ID) -> DOMNode? {
        nodesByID[id]
    }

    var nodes: Dictionary<DOMNode.ID, DOMNode>.Values {
        nodesByID.values
    }

    func removeAll() {
        nodesByID = [:]
        frameDocuments.removeAll()
        didChange()
    }

    /// Returns the model of a payload and the identifiers that the payload
    /// contains.
    func materialize(_ payload: DOM.Node) -> (node: DOMNode, payloadIDs: Set<DOMNode.ID>) {
        var payloadIDs = Set<DOMNode.ID>()
        collectMaterializedPayloadIDs(payload, into: &payloadIDs)
        let node = model(for: payload, preserving: payloadIDs)
        didChange()
        return (node, payloadIDs)
    }

    /// Returns the models of sibling payloads and the identifiers that the
    /// payloads contain.
    func materialize(_ payloads: [DOM.Node]) -> (nodes: [DOMNode], payloadIDs: Set<DOMNode.ID>) {
        var payloadIDs = Set<DOMNode.ID>()
        for payload in payloads {
            collectMaterializedPayloadIDs(payload, into: &payloadIDs)
        }
        let nodes = payloads.map { model(for: $0, preserving: payloadIDs) }
        didChange()
        return (nodes, payloadIDs)
    }

    /// Removes a subtree from the index, except the nodes in `preservedIDs`
    /// that a new payload has just materialized.
    func removeSubtree(
        _ root: DOMNode,
        preserving preservedIDs: Set<DOMNode.ID> = []
    ) {
        var removedIDs = Set<DOMNode.ID>()
        collectSubtreeIDs(root, into: &removedIDs)
        removedIDs.subtract(preservedIDs)
        frameDocuments.removeProjections(containing: removedIDs)
        for id in removedIDs {
            nodesByID[id] = nil
        }
        didChange()
        didRemoveNodes?(removedIDs)
    }

    // MARK: Frame documents

    /// The root of the document that is indexed for a frame target.
    func frameDocumentRoot(for frameTargetID: WebInspectorTarget.ID) -> DOMNode? {
        frameDocuments.frameDocumentRootID(for: frameTargetID).flatMap { nodesByID[$0] }
    }

    /// Indexes the document of a frame target, replacing the one it had, and
    /// returns its root.
    func setFrameDocument(
        _ document: DOM.Node,
        for frameTargetID: WebInspectorTarget.ID
    ) -> DOMNode {
        let scopedDocument = Self.scopedFrameDocument(document, to: frameTargetID)
        var payloadIDs = Set<DOMNode.ID>()
        collectMaterializedPayloadIDs(scopedDocument, into: &payloadIDs)
        let previousRootID = frameDocuments.setFrameDocumentRootID(
            DOMNode.ID(scopedDocument.id),
            for: frameTargetID
        )
        let frameRoot = model(for: scopedDocument, preserving: payloadIDs)
        if let previousRootID,
           previousRootID != frameRoot.id,
           let previousRoot = nodesByID[previousRootID] {
            removeSubtree(previousRoot, preserving: payloadIDs)
        }
        didChange()
        return frameRoot
    }

    /// Shows the document of a frame target under the node that owns the
    /// frame, and returns that owner.
    func attachFrameDocumentRoot(
        _ frameRoot: DOMNode,
        frameTargetID: WebInspectorTarget.ID
    ) -> DOMNode? {
        guard let owner = frameOwner(forFrameDocumentRoot: frameRoot, frameTargetID: frameTargetID) else {
            frameDocuments.detach(frameTargetID: frameTargetID)
            return nil
        }
        frameDocuments.attach(frameTargetID: frameTargetID, to: owner.id)
        owner.setContentDocument(frameRoot)
        return owner
    }

    private func frameOwner(
        forFrameDocumentRoot frameRoot: DOMNode,
        frameTargetID: WebInspectorTarget.ID
    ) -> DOMNode? {
        if let ownerID = frameDocuments.ownerNodeID(for: frameTargetID),
           let owner = nodesByID[ownerID],
           frameOwner(owner, matchesFrameDocumentRoot: frameRoot) {
            return owner
        }
        let candidates = nodesByID.values.filter { node in
            guard frameOwner(node, matchesFrameDocumentRoot: frameRoot) else {
                return false
            }
            guard let attachedRootID = frameDocuments.projectedFrameDocumentRootID(forOwnerNodeID: node.id) else {
                return true
            }
            return attachedRootID == frameRoot.id
        }
        guard candidates.count <= 1 else {
            WebInspectorDataKitLog.debug(
                "frame document projection ambiguous frameID=\(String(describing: frameRoot.frameID))"
            )
            return nil
        }
        return candidates.first
    }

    /// Removes the documents projected into the owners of a frame, calling
    /// `didDetach` for each owner after its document is gone.
    func detachFrameDocuments(
        forFrameID frameID: FrameID,
        didDetach: (DOMNode) -> Void
    ) {
        let owners = nodesByID.values.filter { $0.isFrameOwner && $0.frameID == frameID }
        for owner in owners {
            guard let rootID = frameDocuments.projectedFrameDocumentRootID(forOwnerNodeID: owner.id) else {
                continue
            }
            let root = nodesByID[rootID]
            frameDocuments.detachProjection(attachedTo: owner.id)
            owner.setContentDocument(nil)
            if let root {
                removeSubtree(root)
            }
            didDetach(owner)
        }
    }

    /// The frame target that scopes a node identifier, if it has one.
    static func frameTargetID(for nodeID: DOMNode.ID) -> WebInspectorTarget.ID? {
        nodeID.proxyID.targetScopeRawValue.map(WebInspectorTarget.ID.init)
    }

    private static func scopedFrameDocument(_ node: DOM.Node, to frameTargetID: WebInspectorTarget.ID) -> DOM.Node {
        DOM.Node(
            id: scopedNodeID(node.id, to: frameTargetID),
            nodeType: node.nodeType,
            nodeName: node.nodeName,
            localName: node.localName,
            nodeValue: node.nodeValue,
            frameID: node.frameID,
            documentURL: node.documentURL,
            baseURL: node.baseURL,
            attributes: node.attributes,
            attributeList: node.attributeList,
            childNodeCount: node.childNodeCount,
            children: node.children?.map { scopedFrameDocument($0, to: frameTargetID) },
            contentDocument: node.contentDocument.map { scopedFrameDocument($0, to: frameTargetID) },
            shadowRoots: node.shadowRoots.map { scopedFrameDocument($0, to: frameTargetID) },
            templateContent: node.templateContent.map { scopedFrameDocument($0, to: frameTargetID) },
            beforePseudoElement: node.beforePseudoElement.map { scopedFrameDocument($0, to: frameTargetID) },
            otherPseudoElements: node.otherPseudoElements.map { scopedFrameDocument($0, to: frameTargetID) },
            afterPseudoElement: node.afterPseudoElement.map { scopedFrameDocument($0, to: frameTargetID) },
            pseudoType: node.pseudoType,
            shadowRootType: node.shadowRootType
        )
    }

    private static func scopedNodeID(_ id: DOM.Node.ID, to frameTargetID: WebInspectorTarget.ID) -> DOM.Node.ID {
        guard id.targetScopeRawValue == nil else {
            return id
        }
        return DOM.Node.ID(id.rawValue, scopedToTargetRawValue: frameTargetID.rawValue)
    }

    // MARK: Models

    private func collectSubtreeIDs(_ node: DOMNode, into ids: inout Set<DOMNode.ID>) {
        ids.insert(node.id)
        for associatedRoot in node.associatedSubtreeRoots() {
            collectSubtreeIDs(associatedRoot, into: &ids)
        }
        guard case let .loaded(children) = node.children else {
            return
        }
        for child in children {
            collectSubtreeIDs(child, into: &ids)
        }
    }

    private func collectMaterializedPayloadIDs(_ node: DOM.Node, into ids: inout Set<DOMNode.ID>) {
        ids.insert(DOMNode.ID(node.id))
        for associatedNode in associatedPayloadNodes(for: node) {
            collectMaterializedPayloadIDs(associatedNode, into: &ids)
        }
        for child in node.children ?? [] {
            collectMaterializedPayloadIDs(child, into: &ids)
        }
    }

    private func model(
        for payload: DOM.Node,
        preserving materializedPayloadIDs: Set<DOMNode.ID>
    ) -> DOMNode {
        let id = DOMNode.ID(payload.id)
        let node: DOMNode
        let previousChildren: [DOMNode]
        let previousAssociatedRoots: [DOMNode]
        if let existing = nodesByID[id] {
            if case let .loaded(children) = existing.children {
                previousChildren = children
            } else {
                previousChildren = []
            }
            previousAssociatedRoots = existing.associatedSubtreeRoots()
            existing.update(from: payload)
            node = existing
        } else {
            previousChildren = []
            previousAssociatedRoots = []
            node = DOMNode(node: payload)
            nodesByID[id] = node
        }

        let payloadContentDocument = payload.contentDocument.map {
            model(for: $0, preserving: materializedPayloadIDs)
        }
        let shadowRoots = payload.shadowRoots.map {
            model(for: $0, preserving: materializedPayloadIDs)
        }
        let templateContent = payload.templateContent.map {
            model(for: $0, preserving: materializedPayloadIDs)
        }
        let beforePseudoElement = payload.beforePseudoElement.map {
            model(for: $0, preserving: materializedPayloadIDs)
        }
        let otherPseudoElements = payload.otherPseudoElements.map {
            model(for: $0, preserving: materializedPayloadIDs)
        }
        let afterPseudoElement = payload.afterPseudoElement.map {
            model(for: $0, preserving: materializedPayloadIDs)
        }
        let contentDocument = projectedFrameDocument(for: node, payloadContentDocument: payloadContentDocument)
        node.setAssociatedNodes(
            contentDocument: contentDocument,
            shadowRoots: shadowRoots,
            templateContent: templateContent,
            beforePseudoElement: beforePseudoElement,
            otherPseudoElements: otherPseudoElements,
            afterPseudoElement: afterPseudoElement
        )
        let associatedIDs = Set(node.associatedSubtreeRoots().map(\.id))
        for previousRoot in previousAssociatedRoots where associatedIDs.contains(previousRoot.id) == false {
            removeSubtree(previousRoot, preserving: materializedPayloadIDs)
        }

        if let children = payload.children {
            let newChildren = children.map { model(for: $0, preserving: materializedPayloadIDs) }
            let newChildIDs = Set(newChildren.map(\.id))
            for previousChild in previousChildren where newChildIDs.contains(previousChild.id) == false {
                removeSubtree(previousChild, preserving: materializedPayloadIDs)
            }
            node.setChildren(newChildren)
        } else if payload.childNodeCount == 0 && previousChildren.isEmpty == false {
            for previousChild in previousChildren {
                removeSubtree(previousChild, preserving: materializedPayloadIDs)
            }
            node.setChildrenUnrequested(count: payload.childNodeCount)
        } else {
            node.updateChildNodeCount(payload.childNodeCount)
        }
        return node
    }

    private func associatedPayloadNodes(for node: DOM.Node) -> [DOM.Node] {
        [node.contentDocument]
            .compactMap { $0 }
            + node.shadowRoots
            + [node.templateContent, node.beforePseudoElement]
            .compactMap { $0 }
            + node.otherPseudoElements
            + [node.afterPseudoElement]
            .compactMap { $0 }
    }

    private func projectedFrameDocument(
        for owner: DOMNode,
        payloadContentDocument: DOMNode?
    ) -> DOMNode? {
        guard owner.isFrameOwner else {
            return payloadContentDocument
        }

        if let attachedRootID = frameDocuments.projectedFrameDocumentRootID(forOwnerNodeID: owner.id) {
            guard let attachedRoot = nodesByID[attachedRootID],
                  frameOwner(owner, matchesFrameDocumentRoot: attachedRoot) else {
                frameDocuments.detachProjection(attachedTo: owner.id)
                return payloadContentDocument
            }
            return attachedRoot
        }

        guard let frameTargetID = frameTargetIDForFrameDocument(matching: owner),
              let rootID = frameDocuments.frameDocumentRootID(for: frameTargetID),
              let root = nodesByID[rootID] else {
            return payloadContentDocument
        }
        frameDocuments.attach(frameTargetID: frameTargetID, to: owner.id)
        return root
    }

    private func frameTargetIDForFrameDocument(matching owner: DOMNode) -> WebInspectorTarget.ID? {
        let matches = frameDocuments.frameTargetIDs.filter { frameTargetID in
            guard frameDocuments.ownerNodeID(for: frameTargetID) == nil,
                  let rootID = frameDocuments.frameDocumentRootID(for: frameTargetID),
                  let root = nodesByID[rootID] else {
                return false
            }
            return frameOwner(owner, matchesFrameDocumentRoot: root)
        }
        guard matches.count <= 1 else {
            WebInspectorDataKitLog.debug(
                "frame document projection ambiguous owner=\(String(describing: owner.id))"
            )
            return nil
        }
        return matches.first
    }

    private func frameOwner(_ owner: DOMNode, matchesFrameDocumentRoot root: DOMNode) -> Bool {
        guard owner.isFrameOwner,
              let ownerFrameID = owner.frameID,
              let rootFrameID = root.frameID else {
            return false
        }
        return ownerFrameID == rootFrameID
    }

    private func didChange() {
        #if DEBUG
        didChangeForTesting?()
        #endif
    }
}
