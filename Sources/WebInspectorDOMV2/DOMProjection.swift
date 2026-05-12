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

    package init(rows: [DOMTreeRow]) {
        self.rows = rows
    }
}

package struct DOMElementDetailSnapshot: Equatable, Sendable {
    package var nodeID: DOMNodeIdentifier
    package var nodeName: String
    package var attributes: [DOMAttribute]

    package init(nodeID: DOMNodeIdentifier, nodeName: String, attributes: [DOMAttribute]) {
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.attributes = attributes
    }
}

package struct ProtocolTargetSnapshot: Equatable, Sendable {
    package var id: ProtocolTargetIdentifier
    package var kind: ProtocolTargetKind
    package var frameID: DOMFrameIdentifier?
    package var parentFrameID: DOMFrameIdentifier?
    package var currentDocumentID: DOMDocumentIdentifier?
}

package struct DOMPageSnapshot: Equatable, Sendable {
    package var id: ProtocolTargetIdentifier
    package var mainTargetID: ProtocolTargetIdentifier
    package var mainFrameID: DOMFrameIdentifier
    package var navigationGeneration: UInt64
}

package struct DOMFrameSnapshot: Equatable, Sendable {
    package var id: DOMFrameIdentifier
    package var parentFrameID: DOMFrameIdentifier?
    package var childFrameIDs: Set<DOMFrameIdentifier>
    package var ownerNodeID: DOMNodeIdentifier?
    package var targetID: ProtocolTargetIdentifier?
    package var currentDocumentID: DOMDocumentIdentifier?
}

package struct DOMDocumentSnapshot: Equatable, Sendable {
    package var id: DOMDocumentIdentifier
    package var targetID: ProtocolTargetIdentifier
    package var generation: DOMDocumentGeneration
    package var rootNodeID: DOMNodeIdentifier
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
    package var frameID: DOMFrameIdentifier?
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

package struct DOMSelectionSnapshot: Equatable, Sendable {
    package var selectedNodeID: DOMNodeIdentifier?
    package var pendingRequest: SelectionRequestSnapshot?
    package var failure: SelectionResolutionFailure?
}

package struct DOMSessionSnapshot: Equatable, Sendable {
    package var currentPage: DOMPageSnapshot?
    package var targetsByID: [ProtocolTargetIdentifier: ProtocolTargetSnapshot]
    package var framesByID: [DOMFrameIdentifier: DOMFrameSnapshot]
    package var documentsByID: [DOMDocumentIdentifier: DOMDocumentSnapshot]
    package var nodesByID: [DOMNodeIdentifier: DOMNodeSnapshot]
    package var currentNodeIDByKey: [DOMNodeCurrentKey: DOMNodeIdentifier]
    package var selection: DOMSelectionSnapshot
}
