import Foundation
import Observation

public struct DOMEntryID: Hashable, Codable, Sendable {
    public var documentGeneration: UInt64
    public var nodeID: Int

    public init(documentGeneration: UInt64, nodeID: Int) {
        self.documentGeneration = documentGeneration
        self.nodeID = nodeID
    }
}

public struct DOMAttribute: Hashable, Identifiable, Sendable {
    public var id: String {
        if let nodeId {
            return "\(nodeId)#\(name)"
        }
        return "nil#\(name)"
    }

    public var nodeId: Int?
    public var name: String
    public var value: String

    public init(nodeId: Int? = nil, name: String, value: String) {
        self.nodeId = nodeId
        self.name = name
        self.value = value
    }
}

@MainActor
@Observable
public final class DOMEntry: Identifiable, Equatable, Hashable {
    public nonisolated let id: DOMEntryID
    public var nodeType: Int
    public var nodeName: String
    public var localName: String
    public var nodeValue: String
    public var attributes: [DOMAttribute]

    public weak var parent: DOMEntry?
    public weak var previousSibling: DOMEntry?
    public weak var nextSibling: DOMEntry?
    public var children: [DOMEntry]

    public var childCount: Int
    public var layoutFlags: [String]
    public var isRendered: Bool
    public var preview: String
    public var path: [String]
    public var selectorPath: String
    public let style: DOMStyleState

    public var parentID: DOMEntryID? {
        parent?.id
    }

    public var previousSiblingID: DOMEntryID? {
        previousSibling?.id
    }

    public var nextSiblingID: DOMEntryID? {
        nextSibling?.id
    }

    public var firstChildID: DOMEntryID? {
        children.first?.id
    }

    public var lastChildID: DOMEntryID? {
        children.last?.id
    }

    public init(
        id: DOMEntryID,
        nodeType: Int,
        nodeName: String,
        localName: String,
        nodeValue: String,
        attributes: [DOMAttribute],
        children: [DOMEntry] = [],
        childCount: Int,
        layoutFlags: [String] = [],
        isRendered: Bool = true,
        preview: String = "",
        path: [String] = [],
        selectorPath: String = "",
        styleRevision: Int? = nil,
        style: DOMStyleState = DOMStyleState()
    ) {
        self.id = id
        self.nodeType = nodeType
        self.nodeName = nodeName
        self.localName = localName
        self.nodeValue = nodeValue
        self.attributes = attributes
        self.children = children
        self.childCount = childCount
        self.layoutFlags = layoutFlags
        self.isRendered = isRendered
        self.preview = preview
        self.path = path
        self.selectorPath = selectorPath
        self.style = style

        if let styleRevision {
            style.recordSourceRevision(styleRevision)
        }
    }

    public nonisolated static func == (lhs: DOMEntry, rhs: DOMEntry) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

}

public struct DOMGraphNodeDescriptor: Sendable {
    public var nodeID: Int
    public var nodeType: Int
    public var nodeName: String
    public var localName: String
    public var nodeValue: String
    public var attributes: [DOMAttribute]
    public var childCount: Int
    public var layoutFlags: [String]
    public var isRendered: Bool
    public var children: [DOMGraphNodeDescriptor]

    public init(
        nodeID: Int,
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
        self.nodeID = nodeID
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

public struct DOMGraphSnapshot: Sendable {
    public var root: DOMGraphNodeDescriptor
    public var selectedNodeID: Int?

    public init(root: DOMGraphNodeDescriptor, selectedNodeID: Int? = nil) {
        self.root = root
        self.selectedNodeID = selectedNodeID
    }
}

public struct DOMSelectionSnapshotPayload: Sendable {
    public var nodeID: Int?
    public var preview: String
    public var attributes: [DOMAttribute]
    public var path: [String]
    public var selectorPath: String
    public var styleRevision: Int

    public init(
        nodeID: Int?,
        preview: String,
        attributes: [DOMAttribute],
        path: [String],
        selectorPath: String,
        styleRevision: Int
    ) {
        self.nodeID = nodeID
        self.preview = preview
        self.attributes = attributes
        self.path = path
        self.selectorPath = selectorPath
        self.styleRevision = styleRevision
    }
}

public struct DOMSelectorPathPayload: Sendable {
    public var nodeID: Int?
    public var selectorPath: String

    public init(nodeID: Int?, selectorPath: String) {
        self.nodeID = nodeID
        self.selectorPath = selectorPath
    }
}

public struct DOMGraphMutationBundle: Sendable {
    public var events: [DOMGraphMutationEvent]

    public init(events: [DOMGraphMutationEvent]) {
        self.events = events
    }
}

public enum DOMGraphMutationEvent: Sendable {
    case childNodeInserted(parentNodeID: Int, previousNodeID: Int?, node: DOMGraphNodeDescriptor)
    case childNodeRemoved(parentNodeID: Int, nodeID: Int)
    case attributeModified(nodeID: Int, name: String, value: String, layoutFlags: [String]?, isRendered: Bool?)
    case attributeRemoved(nodeID: Int, name: String, layoutFlags: [String]?, isRendered: Bool?)
    case characterDataModified(nodeID: Int, value: String, layoutFlags: [String]?, isRendered: Bool?)
    case childNodeCountUpdated(nodeID: Int, childCount: Int, layoutFlags: [String]?, isRendered: Bool?)
    case setChildNodes(parentNodeID: Int, nodes: [DOMGraphNodeDescriptor])
    case replaceSubtree(root: DOMGraphNodeDescriptor)
    case documentUpdated
}
