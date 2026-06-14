import WebInspectorTransport

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

package extension DOMTarget {
    struct Snapshot: Equatable, Sendable {
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
    struct Snapshot: Equatable, Sendable {
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

    struct Snapshot: Equatable, Sendable {
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

    struct Snapshot: Equatable, Sendable {
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
    struct Snapshot: Equatable, Sendable {
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
    struct Snapshot: Equatable, Sendable {
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
        package var executionContextsByKey: [RuntimeExecutionContextKey: RuntimeExecutionContextRecord]
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
        contextID: ExecutionContextID
    ) -> RuntimeExecutionContextRecord? {
        executionContextsByKey[
            RuntimeExecutionContextKey(runtimeAgentTargetID: runtimeAgentTargetID, contextID: contextID)
        ]
    }

    func uniqueExecutionContext(contextID: ExecutionContextID) -> RuntimeExecutionContextRecord? {
        let matches = executionContextsByKey.values.filter { $0.id == contextID }
        return matches.count == 1 ? matches[0] : nil
    }
}
