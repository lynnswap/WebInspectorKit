@MainActor
package struct DOMTreeProjectionBuilder {
    package typealias NodeProvider = @MainActor (DOMNode.ID) -> DOMNode?
    package typealias FrameDocumentRootResolver = @MainActor (DOMNode.ID) -> DOMNode.ID?

    private let rootDocument: DOMDocument
    private let nodeProvider: NodeProvider
    private let frameDocumentRootResolver: FrameDocumentRootResolver

    package init(
        rootDocument: DOMDocument,
        nodeProvider: @escaping NodeProvider,
        frameDocumentRootResolver: @escaping FrameDocumentRootResolver
    ) {
        self.rootDocument = rootDocument
        self.nodeProvider = nodeProvider
        self.frameDocumentRootResolver = frameDocumentRootResolver
    }

    package func build() -> DOMTreeProjection {
        var rows: [DOMTreeRow] = []
        var childrenByNodeID: [DOMNode.ID: [DOMNode.ID]] = [:]
        var parentByNodeID: [DOMNode.ID: DOMNode.ID] = [:]
        var visited = Set<DOMNode.ID>()

        append(
            rootDocument.rootNodeID,
            depth: 0,
            rows: &rows,
            childrenByNodeID: &childrenByNodeID,
            parentByNodeID: &parentByNodeID,
            visited: &visited
        )

        return DOMTreeProjection(
            rows: rows,
            rootNodeIDs: [rootDocument.rootNodeID],
            childrenByNodeID: childrenByNodeID,
            parentByNodeID: parentByNodeID
        )
    }

    package static func visibleChildIDs(
        of node: DOMNode,
        frameDocumentRootResolver: FrameDocumentRootResolver
    ) -> [DOMNode.ID] {
        var children: [DOMNode.ID] = []
        if let templateContentID = node.templateContentID {
            children.append(templateContentID)
        }
        if let beforePseudoElementID = node.beforePseudoElementID {
            children.append(beforePseudoElementID)
        }
        children.append(contentsOf: node.otherPseudoElementIDs)
        children.append(contentsOf: effectiveChildIDs(of: node, frameDocumentRootResolver: frameDocumentRootResolver))
        if let afterPseudoElementID = node.afterPseudoElementID {
            children.append(afterPseudoElementID)
        }
        return children
    }

    private static func effectiveChildIDs(
        of node: DOMNode,
        frameDocumentRootResolver: FrameDocumentRootResolver
    ) -> [DOMNode.ID] {
        if node.isFrameOwner,
           let rootNodeID = frameDocumentRootResolver(node.id) {
            return [rootNodeID]
        }
        if let contentDocumentID = node.contentDocumentID {
            return [contentDocumentID]
        }
        return node.shadowRootIDs + node.regularChildren.loadedChildren
    }

    private func append(
        _ nodeID: DOMNode.ID,
        depth: Int,
        rows: inout [DOMTreeRow],
        childrenByNodeID: inout [DOMNode.ID: [DOMNode.ID]],
        parentByNodeID: inout [DOMNode.ID: DOMNode.ID],
        visited: inout Set<DOMNode.ID>
    ) {
        guard visited.insert(nodeID).inserted,
              let node = nodeProvider(nodeID) else {
            return
        }
        let visibleChildren = Self.visibleChildIDs(
            of: node,
            frameDocumentRootResolver: frameDocumentRootResolver
        )
        childrenByNodeID[nodeID] = visibleChildren
        rows.append(
            DOMTreeRow(
                nodeID: nodeID,
                depth: depth,
                nodeName: node.nodeName,
                hasVisibleChildren: !visibleChildren.isEmpty || node.regularChildren.knownCount > 0
            )
        )
        for childID in visibleChildren {
            parentByNodeID[childID] = nodeID
            append(
                childID,
                depth: depth + 1,
                rows: &rows,
                childrenByNodeID: &childrenByNodeID,
                parentByNodeID: &parentByNodeID,
                visited: &visited
            )
        }
    }
}
