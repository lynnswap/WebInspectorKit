import WebInspectorTransport

package enum DOMTree {}

package struct DOMTreeRow: Equatable, Sendable {
    package var nodeID: DOMNode.ID
    package var depth: Int
    package var nodeName: String
    package var hasVisibleChildren: Bool

    package init(
        nodeID: DOMNode.ID,
        depth: Int,
        nodeName: String,
        hasVisibleChildren: Bool
    ) {
        self.nodeID = nodeID
        self.depth = depth
        self.nodeName = nodeName
        self.hasVisibleChildren = hasVisibleChildren
    }
}

package struct DOMTreeProjectionEdges: Equatable, Sendable {
    private var childrenByParentID: [DOMNode.ID: [DOMNode.ID]]
    private var parentByChildID: [DOMNode.ID: DOMNode.ID]

    package init(
        childrenByNodeID: [DOMNode.ID: [DOMNode.ID]] = [:],
        parentByNodeID: [DOMNode.ID: DOMNode.ID] = [:]
    ) {
        self.childrenByParentID = childrenByNodeID
        self.parentByChildID = parentByNodeID
    }

    package var childrenByNodeID: [DOMNode.ID: [DOMNode.ID]] {
        childrenByParentID
    }

    package var parentByNodeID: [DOMNode.ID: DOMNode.ID] {
        parentByChildID
    }

    package mutating func setChildren(
        _ childIDs: [DOMNode.ID],
        of parentID: DOMNode.ID
    ) {
        childrenByParentID[parentID] = childIDs
        for childID in childIDs {
            parentByChildID[childID] = parentID
        }
    }

    package func children(of nodeID: DOMNode.ID) -> [DOMNode.ID] {
        childrenByParentID[nodeID] ?? []
    }

    package func parent(of nodeID: DOMNode.ID) -> DOMNode.ID? {
        parentByChildID[nodeID]
    }

    package func ancestorNodeIDs(of nodeID: DOMNode.ID) -> [DOMNode.ID] {
        var ancestors: [DOMNode.ID] = []
        var visited = Set<DOMNode.ID>()
        var current = parentByChildID[nodeID]
        while let ancestorID = current,
              visited.insert(ancestorID).inserted {
            ancestors.append(ancestorID)
            current = parentByChildID[ancestorID]
        }
        return ancestors
    }
}

package struct DOMTreeProjection: Equatable, Sendable {
    package var rows: [DOMTreeRow]
    package var rootNodeIDs: [DOMNode.ID]
    private var edges: DOMTreeProjectionEdges

    package var childrenByNodeID: [DOMNode.ID: [DOMNode.ID]] {
        edges.childrenByNodeID
    }

    package var parentByNodeID: [DOMNode.ID: DOMNode.ID] {
        edges.parentByNodeID
    }

    package init(
        rows: [DOMTreeRow] = [],
        rootNodeIDs: [DOMNode.ID] = [],
        childrenByNodeID: [DOMNode.ID: [DOMNode.ID]] = [:],
        parentByNodeID: [DOMNode.ID: DOMNode.ID] = [:]
    ) {
        self.init(
            rows: rows,
            rootNodeIDs: rootNodeIDs,
            edges: DOMTreeProjectionEdges(
                childrenByNodeID: childrenByNodeID,
                parentByNodeID: parentByNodeID
            )
        )
    }

    package init(
        rows: [DOMTreeRow],
        rootNodeIDs: [DOMNode.ID],
        edges: DOMTreeProjectionEdges
    ) {
        self.rows = rows
        self.rootNodeIDs = rootNodeIDs
        self.edges = edges
    }

    package func children(of nodeID: DOMNode.ID) -> [DOMNode.ID] {
        edges.children(of: nodeID)
    }

    package func parent(of nodeID: DOMNode.ID) -> DOMNode.ID? {
        edges.parent(of: nodeID)
    }

    package func ancestorNodeIDs(of nodeID: DOMNode.ID) -> [DOMNode.ID] {
        edges.ancestorNodeIDs(of: nodeID)
    }
}

package extension DOMTree {
    struct RowDeltaBatch: Equatable, Sendable {
        package var startRevision: UInt64
        package var revision: UInt64
        package var deltas: [RowDelta]

        package init(
            startRevision: UInt64,
            revision: UInt64,
            deltas: [RowDelta]
        ) {
            self.startRevision = startRevision
            self.revision = revision
            self.deltas = deltas
        }

        package var requiresRootReset: Bool {
            deltas.contains { delta in
                if case .rootReset = delta {
                    return true
                }
                return false
            }
        }

        package func merging(with newer: DOMTree.RowDeltaBatch) -> DOMTree.RowDeltaBatch {
            if requiresRootReset || newer.requiresRootReset {
                return DOMTree.RowDeltaBatch(
                    startRevision: min(startRevision, newer.startRevision),
                    revision: newer.revision,
                    deltas: [.rootReset(rootNodeID: newer.rootResetNodeID)]
                )
            }
            return DOMTree.RowDeltaBatch(
                startRevision: min(startRevision, newer.startRevision),
                revision: newer.revision,
                deltas: deltas + newer.deltas
            )
        }

        private var rootResetNodeID: DOMNode.ID? {
            for delta in deltas.reversed() {
                if case let .rootReset(rootNodeID) = delta {
                    return rootNodeID
                }
            }
            return nil
        }
    }

    enum RowDelta: Equatable, Sendable {
        case rootReset(rootNodeID: DOMNode.ID?)
        case childrenReplaced(parentID: DOMNode.ID, oldVisibleChildIDs: [DOMNode.ID], newVisibleChildIDs: [DOMNode.ID])
        case childInserted(parentID: DOMNode.ID, childID: DOMNode.ID, previousSiblingID: DOMNode.ID?)
        case childRemoved(parentID: DOMNode.ID?, nodeID: DOMNode.ID, removedSubtreeIDs: Set<DOMNode.ID>)
        case childCountChanged(nodeID: DOMNode.ID, oldCount: Int, newCount: Int)
        case rowContentChanged(nodeID: DOMNode.ID, reasons: Set<RowContentReason>)
    }

    enum RowContentReason: Hashable, Sendable {
        case attribute(name: String)
        case characterData
        case nodeMetadata
        case disclosure
        case projection
    }

    struct ChangeSet: Equatable, Sendable {
        package enum Kind: Equatable, Sendable {
            case root
            case structure
            case content
        }

        package var revision: UInt64
        package var startRevision: UInt64
        package var kind: Kind
        package var affectedNodeIDs: Set<DOMNode.ID>
        package var parentNodeIDs: Set<DOMNode.ID>

        package init(
            revision: UInt64,
            startRevision: UInt64? = nil,
            kind: Kind,
            affectedNodeIDs: Set<DOMNode.ID> = [],
            parentNodeIDs: Set<DOMNode.ID> = []
        ) {
            self.revision = revision
            self.startRevision = startRevision ?? revision
            self.kind = kind
            self.affectedNodeIDs = affectedNodeIDs
            self.parentNodeIDs = parentNodeIDs
        }

        package init(
            revision: UInt64,
            kind: Kind,
            affectedNodeID: DOMNode.ID? = nil,
            parentNodeID: DOMNode.ID? = nil
        ) {
            self.init(
                revision: revision,
                kind: kind,
                affectedNodeIDs: affectedNodeID.map { [$0] } ?? [],
                parentNodeIDs: parentNodeID.map { [$0] } ?? []
            )
        }

        package var affectedNodeID: DOMNode.ID? {
            affectedNodeIDs.count == 1 ? affectedNodeIDs.first : nil
        }

        package var parentNodeID: DOMNode.ID? {
            parentNodeIDs.count == 1 ? parentNodeIDs.first : nil
        }

        package var requiresFragmentReset: Bool {
            kind == .root
        }

        package var hasScopedNodes: Bool {
            !affectedNodeIDs.isEmpty || !parentNodeIDs.isEmpty
        }

        package func intersects(nodeIDs: Set<DOMNode.ID>) -> Bool {
            !affectedNodeIDs.isDisjoint(with: nodeIDs) || !parentNodeIDs.isDisjoint(with: nodeIDs)
        }

        package func merging(with newer: DOMTree.ChangeSet) -> DOMTree.ChangeSet {
            let mergedKind: Kind
            if kind == .root || newer.kind == .root {
                mergedKind = .root
            } else if kind == .structure || newer.kind == .structure {
                mergedKind = .structure
            } else {
                mergedKind = .content
            }
            return DOMTree.ChangeSet(
                revision: newer.revision,
                startRevision: min(startRevision, newer.startRevision),
                kind: mergedKind,
                affectedNodeIDs: affectedNodeIDs.union(newer.affectedNodeIDs),
                parentNodeIDs: parentNodeIDs.union(newer.parentNodeIDs)
            )
        }
    }
}

package typealias DOMTreeRenderInvalidation = DOMTree.ChangeSet

package struct DOMVisibleChildrenProjection: Equatable, Sendable {
    package var children: [DOMNode.ID]
    package var hasUnloadedChildren: Bool
    package var hasRenderableChildren: Bool

    package init(
        children: [DOMNode.ID] = [],
        hasUnloadedChildren: Bool = false,
        hasRenderableChildren: Bool = false
    ) {
        self.children = children
        self.hasUnloadedChildren = hasUnloadedChildren
        self.hasRenderableChildren = hasRenderableChildren
    }
}

package struct DOMTreeRenderNodeSnapshot: Equatable, Sendable, Identifiable {
    package var id: DOMNode.ID
    package var protocolNodeID: DOMNode.ProtocolID
    package var nodeType: DOMNode.Kind
    package var nodeName: String
    package var localName: String
    package var nodeValue: String
    package var attributes: [DOMNode.Attribute]
    package var parentID: DOMNode.ID?
    package var regularChildren: DOMNode.ChildrenSnapshot
    package var contentDocumentID: DOMNode.ID?
    package var shadowRootIDs: [DOMNode.ID]
    package var templateContentID: DOMNode.ID?
    package var beforePseudoElementID: DOMNode.ID?
    package var otherPseudoElementIDs: [DOMNode.ID]
    package var afterPseudoElementID: DOMNode.ID?
    package var pseudoType: String?
    package var shadowRootType: String?

    package init(
        id: DOMNode.ID,
        protocolNodeID: DOMNode.ProtocolID,
        nodeType: DOMNode.Kind,
        nodeName: String,
        localName: String,
        nodeValue: String,
        attributes: [DOMNode.Attribute],
        parentID: DOMNode.ID?,
        regularChildren: DOMNode.ChildrenSnapshot,
        contentDocumentID: DOMNode.ID?,
        shadowRootIDs: [DOMNode.ID],
        templateContentID: DOMNode.ID?,
        beforePseudoElementID: DOMNode.ID?,
        otherPseudoElementIDs: [DOMNode.ID],
        afterPseudoElementID: DOMNode.ID?,
        pseudoType: String?,
        shadowRootType: String?
    ) {
        self.id = id
        self.protocolNodeID = protocolNodeID
        self.nodeType = nodeType
        self.nodeName = nodeName
        self.localName = localName
        self.nodeValue = nodeValue
        self.attributes = attributes
        self.parentID = parentID
        self.regularChildren = regularChildren
        self.contentDocumentID = contentDocumentID
        self.shadowRootIDs = shadowRootIDs
        self.templateContentID = templateContentID
        self.beforePseudoElementID = beforePseudoElementID
        self.otherPseudoElementIDs = otherPseudoElementIDs
        self.afterPseudoElementID = afterPseudoElementID
        self.pseudoType = pseudoType
        self.shadowRootType = shadowRootType
    }

    package var regularChildKnownCount: Int {
        regularChildren.knownCount
    }

    package var hasUnloadedRegularChildren: Bool {
        if case let .unrequested(count) = regularChildren {
            return count > 0
        }
        return false
    }

    package var isFrameOwner: Bool {
        let lowercasedName = nodeName.lowercased()
        return lowercasedName == "iframe" || lowercasedName == "frame"
    }

    package var displayName: String {
        if !localName.isEmpty {
            return localName
        }
        if !nodeName.isEmpty {
            return nodeName
        }
        return nodeValue.isEmpty ? nodeName : nodeValue
    }
}

package struct DOMTreeRenderSnapshot: Equatable, Sendable {
    package var treeRevision: UInt64
    package var rootNodeID: DOMNode.ID?
    package var nodesByID: [DOMNode.ID: DOMTreeRenderNodeSnapshot]
    package var projectedFrameDocumentRootIDByOwnerNodeID: [DOMNode.ID: DOMNode.ID]
    package var invalidation: DOMTreeRenderInvalidation

    package init(
        treeRevision: UInt64,
        rootNodeID: DOMNode.ID?,
        nodesByID: [DOMNode.ID: DOMTreeRenderNodeSnapshot],
        projectedFrameDocumentRootIDByOwnerNodeID: [DOMNode.ID: DOMNode.ID],
        invalidation: DOMTreeRenderInvalidation
    ) {
        self.treeRevision = treeRevision
        self.rootNodeID = rootNodeID
        self.nodesByID = nodesByID
        self.projectedFrameDocumentRootIDByOwnerNodeID = projectedFrameDocumentRootIDByOwnerNodeID
        self.invalidation = invalidation
    }

    package func node(for nodeID: DOMNode.ID) -> DOMTreeRenderNodeSnapshot? {
        nodesByID[nodeID]
    }

    package func isTemplateContent(_ nodeID: DOMNode.ID) -> Bool {
        guard let parentID = nodesByID[nodeID]?.parentID,
              let parent = nodesByID[parentID] else {
            return false
        }
        return parent.templateContentID == nodeID
    }

    package func displayRootIDs() -> [DOMNode.ID] {
        guard let rootNodeID,
              let rootNode = nodesByID[rootNodeID] else {
            return []
        }
        if rootNode.nodeType == .document {
            return visibleChildrenProjection(of: rootNodeID).children
        }
        return [rootNodeID]
    }

    package func visibleChildrenProjection(of nodeID: DOMNode.ID) -> DOMVisibleChildrenProjection {
        guard let node = nodesByID[nodeID] else {
            return DOMVisibleChildrenProjection()
        }

        var children: [DOMNode.ID] = []
        if let templateContentID = node.templateContentID {
            children.append(templateContentID)
        }
        if let beforePseudoElementID = node.beforePseudoElementID {
            children.append(beforePseudoElementID)
        }
        children.append(contentsOf: node.otherPseudoElementIDs)
        children.append(contentsOf: effectiveChildIDs(of: node))
        if let afterPseudoElementID = node.afterPseudoElementID {
            children.append(afterPseudoElementID)
        }

        return DOMVisibleChildrenProjection(
            children: children,
            hasUnloadedChildren: node.hasUnloadedRegularChildren,
            hasRenderableChildren: !children.isEmpty || node.regularChildKnownCount > 0
        )
    }

    private func effectiveChildIDs(of node: DOMTreeRenderNodeSnapshot) -> [DOMNode.ID] {
        if node.isFrameOwner,
           let projectedRootID = projectedFrameDocumentRootIDByOwnerNodeID[node.id] {
            return [projectedRootID]
        }
        if let contentDocumentID = node.contentDocumentID {
            return [contentDocumentID]
        }
        return node.shadowRootIDs + node.regularChildren.loadedChildren
    }
}

package extension DOMTarget {
    struct Snapshot: Equatable, Sendable, Identifiable {
        package var id: ProtocolTarget.ID
        package var kind: ProtocolTarget.Kind
        package var frameID: DOMFrame.ID?
        package var parentFrameID: DOMFrame.ID?
        package var capabilities: ProtocolTarget.Capabilities
        package var isProvisional: Bool
        package var isPaused: Bool
        package var currentDocumentID: DOMDocument.ID?
    }
}

package extension DOMTarget.Snapshot {
    var record: ProtocolTarget.Record {
        ProtocolTarget.Record(
            id: id,
            kind: kind,
            frameID: frameID,
            parentFrameID: parentFrameID,
            capabilities: capabilities,
            isProvisional: isProvisional,
            isPaused: isPaused
        )
    }
}

package extension DOMFrame {
    struct Snapshot: Equatable, Sendable, Identifiable {
        package var id: DOMFrame.ID
        package var parentFrameID: DOMFrame.ID?
        package var childFrameIDs: Set<DOMFrame.ID>
        package var targetID: ProtocolTarget.ID?
        package var currentDocumentID: DOMDocument.ID?
    }
}

package extension DOMDocument {
    enum Lifecycle: Equatable, Sendable {
        case loading
        case loaded
        case invalidated
    }

    struct Snapshot: Equatable, Sendable, Identifiable {
        package var id: DOMDocument.ID
        package var targetID: ProtocolTarget.ID
        package var localDocumentLifetimeID: DOMDocument.LifetimeID
        package var lifecycle: DOMDocument.Lifecycle
        package var rootNodeID: DOMNode.ID
    }
}

package extension FrameDocumentProjection {
    enum State: Equatable, Sendable {
        case pending
        case attached
        case ambiguous
    }

    struct Snapshot: Equatable, Sendable {
        package var ownerNodeID: DOMNode.ID?
        package var frameTargetID: ProtocolTarget.ID
        package var frameDocumentID: DOMDocument.ID
        package var state: State
    }
}

package extension DOMNode {
    enum ChildrenSnapshot: Equatable, Sendable {
        case unrequested(count: Int)
        case loaded([DOMNode.ID])

        package var knownCount: Int {
            switch self {
            case let .unrequested(count):
                max(0, count)
            case let .loaded(children):
                children.count
            }
        }

        package var loadedChildren: [DOMNode.ID] {
            switch self {
            case .unrequested:
                []
            case let .loaded(children):
                children
            }
        }
    }

    struct Snapshot: Equatable, Sendable, Identifiable {
        package var id: DOMNode.ID
        package var protocolNodeID: DOMNode.ProtocolID
        package var nodeType: DOMNode.Kind
        package var nodeName: String
        package var localName: String
        package var nodeValue: String
        package var ownerFrameID: DOMFrame.ID?
        package var documentURL: String?
        package var baseURL: String?
        package var attributes: [DOMNode.Attribute]
        package var parentID: DOMNode.ID?
        package var previousSiblingID: DOMNode.ID?
        package var nextSiblingID: DOMNode.ID?
        package var regularChildren: DOMNode.ChildrenSnapshot
        package var contentDocumentID: DOMNode.ID?
        package var shadowRootIDs: [DOMNode.ID]
        package var templateContentID: DOMNode.ID?
        package var beforePseudoElementID: DOMNode.ID?
        package var otherPseudoElementIDs: [DOMNode.ID]
        package var afterPseudoElementID: DOMNode.ID?
        package var pseudoType: String?
        package var shadowRootType: String?

        package var regularChildIDs: [DOMNode.ID] {
            regularChildren.loadedChildren
        }
    }
}

package extension DOMSelection.Request {
    struct Snapshot: Equatable, Sendable, Identifiable {
        package var id: DOMSelection.Request.ID
        package var targetID: ProtocolTarget.ID
        package var documentID: DOMDocument.ID
    }
}

package extension DOMTargetState {
    struct Snapshot: Equatable, Sendable {
        package var targetID: ProtocolTarget.ID
        package var currentDocumentID: DOMDocument.ID?
        package var transactionIDs: [DOMTransaction.ID]
    }
}

package extension DOMTransaction {
    struct Snapshot: Equatable, Sendable, Identifiable {
        package var id: DOMTransaction.ID
        package var targetID: ProtocolTarget.ID
        package var documentID: DOMDocument.ID
        package var kind: DOMTransaction.Kind
        package var issuedSequence: UInt64
        package var requestedProtocolNodeID: DOMNode.ProtocolID?
    }
}

package extension DOMSelection {
    struct Snapshot: Equatable, Sendable {
        package var selectedNodeID: DOMNode.ID?
        package var pendingRequest: DOMSelection.Request.Snapshot?
        package var failure: DOMSelection.Failure?
    }
}

package extension DOMSession {
    struct Snapshot: Equatable, Sendable {
        package var currentPageTargetID: ProtocolTarget.ID?
        package var mainFrameID: DOMFrame.ID?
        package var targetsByID: [ProtocolTarget.ID: DOMTarget.Snapshot]
        package var targetStatesByID: [ProtocolTarget.ID: DOMTargetState.Snapshot]
        package var framesByID: [DOMFrame.ID: DOMFrame.Snapshot]
        package var documentsByID: [DOMDocument.ID: DOMDocument.Snapshot]
        package var nodesByID: [DOMNode.ID: DOMNode.Snapshot]
        package var frameDocumentProjections: [ProtocolTarget.ID: FrameDocumentProjection.Snapshot]
        package var transactions: [DOMTransaction.Snapshot]
        package var currentNodeIDByKey: [DOMNode.CurrentKey: DOMNode.ID]
        package var executionContextsByKey: [RuntimeContext.Key: RuntimeContext.Record]
        package var selection: DOMSelection.Snapshot
    }
}

package extension DOMSession.Snapshot {
    var currentPageDocumentID: DOMDocument.ID? {
        guard let currentPageTargetID else {
            return nil
        }
        return targetStatesByID[currentPageTargetID]?.currentDocumentID
            ?? targetsByID[currentPageTargetID]?.currentDocumentID
    }

    func executionContext(
        runtimeAgentTargetID: ProtocolTarget.ID,
        contextID: RuntimeContext.ID
    ) -> RuntimeContext.Record? {
        executionContextsByKey[
            RuntimeContext.Key(runtimeAgentTargetID: runtimeAgentTargetID, contextID: contextID)
        ]
    }

    func uniqueExecutionContext(contextID: RuntimeContext.ID) -> RuntimeContext.Record? {
        let matches = executionContextsByKey.values.filter { $0.id == contextID }
        return matches.count == 1 ? matches[0] : nil
    }
}
