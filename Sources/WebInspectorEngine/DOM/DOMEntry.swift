import Foundation
import Observation

public struct DOMAttribute: Hashable, Identifiable, Sendable {
    public var id: String {
        name
    }

    package var nodeId: Int?
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.nodeId = nil
        self.name = name
        self.value = value
    }

    package init(nodeId: Int? = nil, name: String, value: String) {
        self.nodeId = nodeId
        self.name = name
        self.value = value
    }
}

@MainActor
@Observable
public final class DOMEntry: Equatable, Hashable {
    package var backendNodeID: Int?
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

    package init(
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
        lhs === rhs
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    func clearMatchedStyles() {
        matchedStyles = []
        matchedStylesTruncated = false
        blockedStylesheetCount = 0
        isLoadingMatchedStyles = false
    }
}

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

package struct DOMSelectionSnapshotPayload: Sendable {
    package var localID: UInt64?
    package var preview: String
    package var attributes: [DOMAttribute]
    package var path: [String]
    package var selectorPath: String?
    package var styleRevision: Int

    package init(
        localID: UInt64?,
        preview: String,
        attributes: [DOMAttribute],
        path: [String],
        selectorPath: String?,
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
