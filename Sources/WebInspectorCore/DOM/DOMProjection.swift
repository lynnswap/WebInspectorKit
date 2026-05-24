package struct DOMTreeRow: Equatable, Sendable {
    package var nodeID: DOMNodeIdentifier
    package var depth: Int
    package var nodeName: String
    package var isSelected: Bool
    package var hasVisibleChildren: Bool

    package init(
        nodeID: DOMNodeIdentifier,
        depth: Int,
        nodeName: String,
        isSelected: Bool,
        hasVisibleChildren: Bool
    ) {
        self.nodeID = nodeID
        self.depth = depth
        self.nodeName = nodeName
        self.isSelected = isSelected
        self.hasVisibleChildren = hasVisibleChildren
    }
}

package struct DOMTreeProjection: Equatable, Sendable {
    package var rows: [DOMTreeRow]
    package var rootNodeIDs: [DOMNodeIdentifier]
    package var childrenByNodeID: [DOMNodeIdentifier: [DOMNodeIdentifier]]
    package var parentByNodeID: [DOMNodeIdentifier: DOMNodeIdentifier]

    package init(
        rows: [DOMTreeRow] = [],
        rootNodeIDs: [DOMNodeIdentifier] = [],
        childrenByNodeID: [DOMNodeIdentifier: [DOMNodeIdentifier]] = [:],
        parentByNodeID: [DOMNodeIdentifier: DOMNodeIdentifier] = [:]
    ) {
        self.rows = rows
        self.rootNodeIDs = rootNodeIDs
        self.childrenByNodeID = childrenByNodeID
        self.parentByNodeID = parentByNodeID
    }

    package func children(of nodeID: DOMNodeIdentifier) -> [DOMNodeIdentifier] {
        childrenByNodeID[nodeID] ?? []
    }

    package func parent(of nodeID: DOMNodeIdentifier) -> DOMNodeIdentifier? {
        parentByNodeID[nodeID]
    }

    package func ancestorNodeIDs(of nodeID: DOMNodeIdentifier) -> [DOMNodeIdentifier] {
        var ancestors: [DOMNodeIdentifier] = []
        var visited = Set<DOMNodeIdentifier>()
        var current = parentByNodeID[nodeID]
        while let ancestorID = current,
              visited.insert(ancestorID).inserted {
            ancestors.append(ancestorID)
            current = parentByNodeID[ancestorID]
        }
        return ancestors
    }
}

package struct ProtocolTargetSnapshot: Equatable, Sendable {
    package var id: ProtocolTargetIdentifier
    package var kind: ProtocolTargetKind
    package var frameID: DOMFrameIdentifier?
    package var parentFrameID: DOMFrameIdentifier?
    package var capabilities: ProtocolTargetCapabilities
    package var isProvisional: Bool
    package var isPaused: Bool
    package var currentDocumentID: DOMDocumentIdentifier?
}

package struct DOMFrameSnapshot: Equatable, Sendable {
    package var id: DOMFrameIdentifier
    package var parentFrameID: DOMFrameIdentifier?
    package var childFrameIDs: Set<DOMFrameIdentifier>
    package var targetID: ProtocolTargetIdentifier?
    package var currentDocumentID: DOMDocumentIdentifier?
}

package enum DOMDocumentLifecycle: Equatable, Sendable {
    case loading
    case loaded
    case invalidated
}

package struct DOMDocumentSnapshot: Equatable, Sendable {
    package var id: DOMDocumentIdentifier
    package var targetID: ProtocolTargetIdentifier
    package var localDocumentLifetimeID: DOMDocumentLifetimeIdentifier
    package var lifecycle: DOMDocumentLifecycle
    package var rootNodeID: DOMNodeIdentifier
}

package enum FrameDocumentProjectionState: Equatable, Sendable {
    case pending
    case attached
    case ambiguous
}

package struct FrameDocumentProjectionSnapshot: Equatable, Sendable {
    package var ownerNodeID: DOMNodeIdentifier?
    package var frameTargetID: ProtocolTargetIdentifier
    package var frameDocumentID: DOMDocumentIdentifier
    package var state: FrameDocumentProjectionState
}

package enum DOMRegularChildrenSnapshot: Equatable, Sendable {
    case unrequested(count: Int)
    case loaded([DOMNodeIdentifier])

    package var knownCount: Int {
        switch self {
        case let .unrequested(count):
            max(0, count)
        case let .loaded(children):
            children.count
        }
    }

    package var loadedChildren: [DOMNodeIdentifier] {
        switch self {
        case .unrequested:
            []
        case let .loaded(children):
            children
        }
    }
}

package struct DOMNodeSnapshot: Equatable, Sendable {
    package var id: DOMNodeIdentifier
    package var protocolNodeID: DOMProtocolNodeID
    package var nodeType: DOMNodeType
    package var nodeName: String
    package var localName: String
    package var nodeValue: String
    package var ownerFrameID: DOMFrameIdentifier?
    package var documentURL: String?
    package var baseURL: String?
    package var attributes: [DOMAttribute]
    package var parentID: DOMNodeIdentifier?
    package var previousSiblingID: DOMNodeIdentifier?
    package var nextSiblingID: DOMNodeIdentifier?
    package var regularChildren: DOMRegularChildrenSnapshot
    package var contentDocumentID: DOMNodeIdentifier?
    package var shadowRootIDs: [DOMNodeIdentifier]
    package var templateContentID: DOMNodeIdentifier?
    package var beforePseudoElementID: DOMNodeIdentifier?
    package var otherPseudoElementIDs: [DOMNodeIdentifier]
    package var afterPseudoElementID: DOMNodeIdentifier?
    package var pseudoType: String?
    package var shadowRootType: String?

    package var regularChildIDs: [DOMNodeIdentifier] {
        regularChildren.loadedChildren
    }
}

package struct SelectionRequestSnapshot: Equatable, Sendable {
    package var id: SelectionRequestIdentifier
    package var targetID: ProtocolTargetIdentifier
    package var documentID: DOMDocumentIdentifier
}

package struct DOMTargetStateSnapshot: Equatable, Sendable {
    package var targetID: ProtocolTargetIdentifier
    package var currentDocumentID: DOMDocumentIdentifier?
    package var transactionIDs: [DOMTransactionIdentifier]
}

package struct DOMTransactionSnapshot: Equatable, Sendable {
    package var id: DOMTransactionIdentifier
    package var targetID: ProtocolTargetIdentifier
    package var documentID: DOMDocumentIdentifier
    package var kind: DOMTransactionKind
    package var issuedSequence: UInt64
    package var requestedProtocolNodeID: DOMProtocolNodeID?
}

package struct DOMSelectionSnapshot: Equatable, Sendable {
    package var selectedNodeID: DOMNodeIdentifier?
    package var pendingRequest: SelectionRequestSnapshot?
    package var failure: SelectionResolutionFailure?
}

package struct DOMSessionSnapshot: Equatable, Sendable {
    package var currentPageTargetID: ProtocolTargetIdentifier?
    package var mainFrameID: DOMFrameIdentifier?
    package var treeRevision: UInt64
    package var selectionRevision: UInt64
    package var targetsByID: [ProtocolTargetIdentifier: ProtocolTargetSnapshot]
    package var targetStatesByID: [ProtocolTargetIdentifier: DOMTargetStateSnapshot]
    package var framesByID: [DOMFrameIdentifier: DOMFrameSnapshot]
    package var documentsByID: [DOMDocumentIdentifier: DOMDocumentSnapshot]
    package var nodesByID: [DOMNodeIdentifier: DOMNodeSnapshot]
    package var frameDocumentProjections: [ProtocolTargetIdentifier: FrameDocumentProjectionSnapshot]
    package var transactions: [DOMTransactionSnapshot]
    package var currentNodeIDByKey: [DOMNodeCurrentKey: DOMNodeIdentifier]
    package var executionContextsByID: [ExecutionContextID: ExecutionContextRecord]
    package var selection: DOMSelectionSnapshot
}

package extension DOMSessionSnapshot {
    var currentPageDocumentID: DOMDocumentIdentifier? {
        guard let currentPageTargetID else {
            return nil
        }
        return targetStatesByID[currentPageTargetID]?.currentDocumentID
            ?? targetsByID[currentPageTargetID]?.currentDocumentID
    }
}
