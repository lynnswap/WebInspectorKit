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
        matchedStyles: [DOMMatchedStyleRule]? = nil,
        isLoadingMatchedStyles: Bool? = nil,
        needsMatchedStylesRefresh: Bool? = nil,
        matchedStylesTruncated: Bool? = nil,
        blockedStylesheetCount: Int? = nil,
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
        if let matchedStyles {
            style.setMatchedForCompatibility(
                rules: matchedStyles.map(\.styleRule),
                isTruncated: matchedStylesTruncated ?? false,
                blockedStylesheetCount: blockedStylesheetCount ?? 0
            )
        } else if matchedStylesTruncated != nil || blockedStylesheetCount != nil {
            style.setMatchedForCompatibility(
                rules: style.matched.allRules,
                isTruncated: matchedStylesTruncated ?? style.matched.isTruncated,
                blockedStylesheetCount: blockedStylesheetCount ?? style.matched.blockedStylesheetCount
            )
        }
        if let isLoadingMatchedStyles {
            style.setLoadStateForCompatibility(isLoading: isLoadingMatchedStyles)
        }
        if let needsMatchedStylesRefresh {
            style.setNeedsRefreshForCompatibility(needsMatchedStylesRefresh)
        }
    }

    public nonisolated static func == (lhs: DOMEntry, rhs: DOMEntry) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    @available(*, deprecated, message: "Use style.sourceRevision instead.")
    public var styleRevision: Int {
        get {
            style.sourceRevision
        }
        set {
            style.recordSourceRevision(newValue)
        }
    }

    @available(*, deprecated, message: "Use style.matched.allRules instead.")
    public var matchedStyles: [DOMMatchedStyleRule] {
        get {
            style.matched.allRules.map(DOMMatchedStyleRule.init)
        }
        set {
            style.setMatchedForCompatibility(
                rules: newValue.map(\.styleRule),
                isTruncated: style.matched.isTruncated,
                blockedStylesheetCount: style.matched.blockedStylesheetCount
            )
        }
    }

    @available(*, deprecated, message: "Use style.isLoading instead.")
    public var isLoadingMatchedStyles: Bool {
        get {
            style.isLoading
        }
        set {
            style.setLoadStateForCompatibility(isLoading: newValue)
        }
    }

    @available(*, deprecated, message: "Use style.needsRefresh instead.")
    public var needsMatchedStylesRefresh: Bool {
        get {
            style.needsRefresh
        }
        set {
            style.setNeedsRefreshForCompatibility(newValue)
        }
    }

    @available(*, deprecated, message: "Use style.matched.isTruncated instead.")
    public var matchedStylesTruncated: Bool {
        get {
            style.matched.isTruncated
        }
        set {
            style.setMatchedForCompatibility(
                rules: style.matched.allRules,
                isTruncated: newValue,
                blockedStylesheetCount: style.matched.blockedStylesheetCount
            )
        }
    }

    @available(*, deprecated, message: "Use style.matched.blockedStylesheetCount instead.")
    public var blockedStylesheetCount: Int {
        get {
            style.matched.blockedStylesheetCount
        }
        set {
            style.setMatchedForCompatibility(
                rules: style.matched.allRules,
                isTruncated: style.matched.isTruncated,
                blockedStylesheetCount: newValue
            )
        }
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
