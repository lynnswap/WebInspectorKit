import Foundation

package struct DOMGraphNodeDescriptor: Sendable {
    package var localID: UInt64
    package var backendNodeID: Int?
    package var backendNodeIDIsStable: Bool
    package var frameID: String?
    package var nodeType: DOMNodeType
    package var nodeName: String
    package var localName: String
    package var nodeValue: String
    package var attributes: [DOMAttribute]
    package var childCount: Int
    package var childCountIsKnown: Bool
    package var layoutFlags: [String]
    package var isRendered: Bool
    package var children: [DOMGraphNodeDescriptor]

    package init(
        localID: UInt64,
        backendNodeID: Int?,
        backendNodeIDIsStable: Bool? = nil,
        frameID: String? = nil,
        nodeType: DOMNodeType,
        nodeName: String,
        localName: String,
        nodeValue: String,
        attributes: [DOMAttribute],
        childCount: Int,
        childCountIsKnown: Bool = true,
        layoutFlags: [String],
        isRendered: Bool,
        children: [DOMGraphNodeDescriptor]
    ) {
        self.localID = localID
        self.backendNodeID = backendNodeID
        self.backendNodeIDIsStable = backendNodeIDIsStable ?? (backendNodeID != nil)
        self.frameID = frameID
        self.nodeType = nodeType
        self.nodeName = nodeName
        self.localName = localName
        self.nodeValue = nodeValue
        self.attributes = attributes
        self.childCount = childCount
        self.childCountIsKnown = childCountIsKnown
        self.layoutFlags = layoutFlags
        self.isRendered = isRendered
        self.children = children
    }

    package init(
        localID: UInt64,
        backendNodeID: Int?,
        backendNodeIDIsStable: Bool? = nil,
        frameID: String? = nil,
        nodeType: Int,
        nodeName: String,
        localName: String,
        nodeValue: String,
        attributes: [DOMAttribute],
        childCount: Int,
        childCountIsKnown: Bool = true,
        layoutFlags: [String],
        isRendered: Bool,
        children: [DOMGraphNodeDescriptor]
    ) {
        self.init(
            localID: localID,
            backendNodeID: backendNodeID,
            backendNodeIDIsStable: backendNodeIDIsStable,
            frameID: frameID,
            nodeType: DOMNodeType(protocolValue: nodeType),
            nodeName: nodeName,
            localName: localName,
            nodeValue: nodeValue,
            attributes: attributes,
            childCount: childCount,
            childCountIsKnown: childCountIsKnown,
            layoutFlags: layoutFlags,
            isRendered: isRendered,
            children: children
        )
    }
}

package struct DOMGraphSnapshot: Sendable {
    package var root: DOMGraphNodeDescriptor
    package var selectedLocalID: UInt64?

    package init(root: DOMGraphNodeDescriptor, selectedLocalID: UInt64? = nil) {
        self.root = root
        self.selectedLocalID = selectedLocalID
    }
}

package struct DOMSelectionSnapshotPayload: Sendable {
    package var localID: UInt64?
    package var backendNodeID: Int?
    package var backendNodeIDIsStable: Bool
    package var attributes: [DOMAttribute]
    package var path: [String]
    package var selectorPath: String?
    package var styleRevision: Int

    package init(
        localID: UInt64?,
        backendNodeID: Int? = nil,
        backendNodeIDIsStable: Bool? = nil,
        attributes: [DOMAttribute],
        path: [String],
        selectorPath: String?,
        styleRevision: Int
    ) {
        self.localID = localID
        self.backendNodeID = backendNodeID
        self.backendNodeIDIsStable = backendNodeIDIsStable ?? (backendNodeID != nil)
        self.attributes = attributes
        self.path = path
        self.selectorPath = selectorPath
        self.styleRevision = styleRevision
    }
}

package struct DOMSelectorPathPayload: Sendable {
    package var localID: UInt64?
    package var selectorPath: String

    package init(localID: UInt64?, selectorPath: String) {
        self.localID = localID
        self.selectorPath = selectorPath
    }
}

package struct DOMGraphMutationBundle: Sendable {
    package var events: [DOMGraphMutationEvent]

    package init(events: [DOMGraphMutationEvent]) {
        self.events = events
    }
}

package enum DOMGraphMutationEvent: Sendable {
    case childNodeInserted(parentLocalID: UInt64, previousLocalID: UInt64?, node: DOMGraphNodeDescriptor)
    case childNodeRemoved(parentLocalID: UInt64, nodeLocalID: UInt64)
    case attributeModified(nodeLocalID: UInt64, name: String, value: String, layoutFlags: [String]?, isRendered: Bool?)
    case attributeRemoved(nodeLocalID: UInt64, name: String, layoutFlags: [String]?, isRendered: Bool?)
    case characterDataModified(nodeLocalID: UInt64, value: String, layoutFlags: [String]?, isRendered: Bool?)
    case childNodeCountUpdated(nodeLocalID: UInt64, childCount: Int, layoutFlags: [String]?, isRendered: Bool?)
    case setChildNodes(parentLocalID: UInt64, nodes: [DOMGraphNodeDescriptor])
    case setDetachedRoots(nodes: [DOMGraphNodeDescriptor])
    case replaceSubtree(root: DOMGraphNodeDescriptor)
    case documentUpdated
}
