import Foundation

package struct DOMGraphNodeDescriptor: Sendable {
    package var localID: UInt64
    package var backendNodeID: Int?
    package var nodeType: Int
    package var nodeName: String
    package var localName: String
    package var nodeValue: String
    package var attributes: [DOMAttribute]
    package var childCount: Int
    package var layoutFlags: [String]
    package var isRendered: Bool
    package var children: [DOMGraphNodeDescriptor]

    package init(
        localID: UInt64,
        backendNodeID: Int?,
        nodeType: Int,
        nodeName: String,
        localName: String,
        nodeValue: String,
        attributes: [DOMAttribute],
        childCount: Int,
        layoutFlags: [String],
        isRendered: Bool,
        children: [DOMGraphNodeDescriptor]
    ) {
        self.localID = localID
        self.backendNodeID = backendNodeID
        self.nodeType = nodeType
        self.nodeName = nodeName
        self.localName = localName
        self.nodeValue = nodeValue
        self.attributes = attributes
        self.childCount = childCount
        self.layoutFlags = layoutFlags
        self.isRendered = isRendered
        self.children = children
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

package enum DOMRequestNodeTarget: Sendable, Equatable, Hashable {
    case local(UInt64)
    case backend(Int)

    package var jsArgument: NSDictionary? {
        switch self {
        case let .local(localID):
            guard localID <= UInt64(Int.max) else {
                return nil
            }
            return NSDictionary(dictionary: [
                "kind": "local",
                "value": NSNumber(value: Int(localID)),
            ])
        case let .backend(backendNodeID):
            return NSDictionary(dictionary: [
                "kind": "backend",
                "value": NSNumber(value: backendNodeID),
            ])
        }
    }

    package var jsIdentifier: Int? {
        switch self {
        case let .local(localID):
            guard localID <= UInt64(Int.max) else {
                return nil
            }
            return Int(localID)
        case let .backend(backendNodeID):
            return backendNodeID
        }
    }

    package var localID: UInt64? {
        switch self {
        case let .local(localID):
            return localID
        case .backend:
            return nil
        }
    }

    package var backendNodeID: Int? {
        switch self {
        case .local:
            return nil
        case let .backend(backendNodeID):
            return backendNodeID
        }
    }
}

package struct DOMSelectionSnapshotPayload: Sendable {
    package var localID: UInt64?
    package var backendNodeID: Int?
    package var preview: String
    package var attributes: [DOMAttribute]
    package var path: [String]
    package var selectorPath: String?
    package var styleRevision: Int

    package init(
        localID: UInt64?,
        backendNodeID: Int? = nil,
        preview: String,
        attributes: [DOMAttribute],
        path: [String],
        selectorPath: String?,
        styleRevision: Int
    ) {
        self.localID = localID
        self.backendNodeID = backendNodeID
        self.preview = preview
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
    case replaceSubtree(root: DOMGraphNodeDescriptor)
    case documentUpdated
}
