import Foundation
import Observation

public struct DOMEntryID: Hashable, Codable, Sendable {
    public var documentGeneration: UInt64
    public var localID: UInt64

    public init(documentGeneration: UInt64, localID: UInt64) {
        self.documentGeneration = documentGeneration
        self.localID = localID
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
    public var backendNodeID: Int?
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
    public var styleRevision: Int
    public var preview: String
    public var path: [String]
    public var selectorPath: String
    public var matchedStyles: [DOMMatchedStyleRule]
    public var isLoadingMatchedStyles: Bool
    public var matchedStylesTruncated: Bool
    public var blockedStylesheetCount: Int

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
        backendNodeID: Int? = nil,
        nodeType: Int,
        nodeName: String,
        localName: String,
        nodeValue: String,
        attributes: [DOMAttribute],
        children: [DOMEntry] = [],
        childCount: Int,
        layoutFlags: [String] = [],
        isRendered: Bool = true,
        styleRevision: Int = 0,
        preview: String = "",
        path: [String] = [],
        selectorPath: String = "",
        matchedStyles: [DOMMatchedStyleRule] = [],
        isLoadingMatchedStyles: Bool = false,
        matchedStylesTruncated: Bool = false,
        blockedStylesheetCount: Int = 0
    ) {
        self.id = id
        self.backendNodeID = backendNodeID
        self.nodeType = nodeType
        self.nodeName = nodeName
        self.localName = localName
        self.nodeValue = nodeValue
        self.attributes = attributes
        self.children = children
        self.childCount = childCount
        self.layoutFlags = layoutFlags
        self.isRendered = isRendered
        self.styleRevision = styleRevision
        self.preview = preview
        self.path = path
        self.selectorPath = selectorPath
        self.matchedStyles = matchedStyles
        self.isLoadingMatchedStyles = isLoadingMatchedStyles
        self.matchedStylesTruncated = matchedStylesTruncated
        self.blockedStylesheetCount = blockedStylesheetCount
    }

    public nonisolated static func == (lhs: DOMEntry, rhs: DOMEntry) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    func clearMatchedStyles() {
        matchedStyles = []
        matchedStylesTruncated = false
        blockedStylesheetCount = 0
        isLoadingMatchedStyles = false
    }
}

public struct DOMGraphNodeDescriptor: Sendable {
    public var localID: UInt64
    public var backendNodeID: Int?
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

public struct DOMGraphSnapshot: Sendable {
    public var root: DOMGraphNodeDescriptor
    public var selectedLocalID: UInt64?

    public init(root: DOMGraphNodeDescriptor, selectedLocalID: UInt64? = nil) {
        self.root = root
        self.selectedLocalID = selectedLocalID
    }
}

public struct DOMSelectionSnapshotPayload: Sendable {
    public var localID: UInt64?
    public var preview: String
    public var attributes: [DOMAttribute]
    public var path: [String]
    public var selectorPath: String
    public var styleRevision: Int

    public init(
        localID: UInt64?,
        preview: String,
        attributes: [DOMAttribute],
        path: [String],
        selectorPath: String,
        styleRevision: Int
    ) {
        self.localID = localID
        self.preview = preview
        self.attributes = attributes
        self.path = path
        self.selectorPath = selectorPath
        self.styleRevision = styleRevision
    }
}

public struct DOMSelectorPathPayload: Sendable {
    public var localID: UInt64?
    public var selectorPath: String

    public init(localID: UInt64?, selectorPath: String) {
        self.localID = localID
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
