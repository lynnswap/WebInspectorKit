import WebInspectorCoreRuntime
import WebInspectorCoreSupport
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
        var edges = DOMTreeProjectionEdges()
        var visited = Set<DOMNode.ID>()

        append(
            rootDocument.rootNodeID,
            depth: 0,
            rows: &rows,
            edges: &edges,
            visited: &visited
        )

        return DOMTreeProjection(
            rows: rows,
            rootNodeIDs: [rootDocument.rootNodeID],
            edges: edges
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
        edges: inout DOMTreeProjectionEdges,
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
        edges.setChildren(visibleChildren, of: nodeID)
        rows.append(
            DOMTreeRow(
                nodeID: nodeID,
                depth: depth,
                nodeName: node.nodeName,
                hasVisibleChildren: !visibleChildren.isEmpty || node.regularChildren.knownCount > 0
            )
        )
        for childID in visibleChildren {
            append(
                childID,
                depth: depth + 1,
                rows: &rows,
                edges: &edges,
                visited: &visited
            )
        }
    }
}
