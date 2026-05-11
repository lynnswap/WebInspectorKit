import Foundation
import Observation

@available(*, deprecated, renamed: "DOMNodeModel", message: "Use DOMNodeModel.")
public typealias DOMEntry = DOMNodeModel

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
public final class DOMNodeModel: Equatable, Hashable, Identifiable {
    public struct ID: Hashable, Sendable {
        public let documentIdentity: UUID
        public let localID: UInt64

        public init(documentIdentity: UUID, localID: UInt64) {
            self.documentIdentity = documentIdentity
            self.localID = localID
        }
    }

    public let id: ID
    package var backendNodeID: Int?
    package var backendNodeIDIsStable: Bool
    public var frameID: String?
    public var nodeType: DOMNodeType
    public var nodeName: String
    public var localName: String
    public var nodeValue: String
    public var attributes: [DOMAttribute]

    public weak var parent: DOMNodeModel?
    public weak var previousSibling: DOMNodeModel?
    public weak var nextSibling: DOMNodeModel?
    package var regularChildren: [DOMNodeModel]
    public var contentDocument: DOMNodeModel?
    public var shadowRoots: [DOMNodeModel]
    public var templateContent: DOMNodeModel?
    public var beforePseudoElement: DOMNodeModel?
    public var afterPseudoElement: DOMNodeModel?
    public var pseudoType: String?
    public var shadowRootType: String?

    public var children: [DOMNodeModel] {
        if let contentDocument {
            return [contentDocument]
        }
        return shadowRoots + regularChildren
    }

    package var visibleDOMTreeChildren: [DOMNodeModel] {
        var visibleChildren: [DOMNodeModel] = []
        if let templateContent {
            visibleChildren.append(templateContent)
        }
        if let beforePseudoElement {
            visibleChildren.append(beforePseudoElement)
        }
        visibleChildren.append(contentsOf: children)
        if let afterPseudoElement {
            visibleChildren.append(afterPseudoElement)
        }
        return visibleChildren
    }

    package var hasUnloadedRegularChildren: Bool {
        contentDocument == nil && childCount > regularChildren.count
    }

    package var ownedChildren: [DOMNodeModel] {
        var ownedChildren = regularChildren
        if let contentDocument {
            ownedChildren.append(contentDocument)
        }
        ownedChildren.append(contentsOf: shadowRoots)
        if let templateContent {
            ownedChildren.append(templateContent)
        }
        if let beforePseudoElement {
            ownedChildren.append(beforePseudoElement)
        }
        if let afterPseudoElement {
            ownedChildren.append(afterPseudoElement)
        }
        return ownedChildren
    }

    public var childCount: Int
    package var childCountIsKnown: Bool
    public var layoutFlags: [String]
    public var isRendered: Bool
    public var styleRevision: Int
    public var preview: String
    public var path: [String]
    public var selectorPath: String

    package init(
        id: ID,
        backendNodeID: Int? = nil,
        backendNodeIDIsStable: Bool? = nil,
        frameID: String? = nil,
        nodeType: DOMNodeType,
        nodeName: String,
        localName: String,
        nodeValue: String,
        pseudoType: String? = nil,
        shadowRootType: String? = nil,
        attributes: [DOMAttribute],
        regularChildren: [DOMNodeModel]? = nil,
        children: [DOMNodeModel] = [],
        contentDocument: DOMNodeModel? = nil,
        shadowRoots: [DOMNodeModel] = [],
        templateContent: DOMNodeModel? = nil,
        beforePseudoElement: DOMNodeModel? = nil,
        afterPseudoElement: DOMNodeModel? = nil,
        childCount: Int,
        childCountIsKnown: Bool = true,
        layoutFlags: [String] = [],
        isRendered: Bool = true,
        styleRevision: Int = 0,
        preview: String = "",
        path: [String] = [],
        selectorPath: String = ""
    ) {
        self.id = id
        self.backendNodeID = backendNodeID
        self.backendNodeIDIsStable = backendNodeIDIsStable ?? (backendNodeID != nil)
        self.frameID = frameID
        self.nodeType = nodeType
        self.nodeName = nodeName
        self.localName = localName
        self.nodeValue = nodeValue
        self.pseudoType = pseudoType
        self.shadowRootType = shadowRootType
        self.attributes = attributes
        self.regularChildren = regularChildren ?? children
        self.contentDocument = contentDocument
        self.shadowRoots = shadowRoots
        self.templateContent = templateContent
        self.beforePseudoElement = beforePseudoElement
        self.afterPseudoElement = afterPseudoElement
        self.childCount = childCount
        self.childCountIsKnown = childCountIsKnown
        self.layoutFlags = layoutFlags
        self.isRendered = isRendered
        self.styleRevision = styleRevision
        self.preview = preview
        self.path = path
        self.selectorPath = selectorPath
    }

    package convenience init(
        id: ID,
        backendNodeID: Int? = nil,
        backendNodeIDIsStable: Bool? = nil,
        frameID: String? = nil,
        nodeType: Int,
        nodeName: String,
        localName: String,
        nodeValue: String,
        pseudoType: String? = nil,
        shadowRootType: String? = nil,
        attributes: [DOMAttribute],
        regularChildren: [DOMNodeModel]? = nil,
        children: [DOMNodeModel] = [],
        contentDocument: DOMNodeModel? = nil,
        shadowRoots: [DOMNodeModel] = [],
        templateContent: DOMNodeModel? = nil,
        beforePseudoElement: DOMNodeModel? = nil,
        afterPseudoElement: DOMNodeModel? = nil,
        childCount: Int,
        childCountIsKnown: Bool = true,
        layoutFlags: [String] = [],
        isRendered: Bool = true,
        styleRevision: Int = 0,
        preview: String = "",
        path: [String] = [],
        selectorPath: String = ""
    ) {
        self.init(
            id: id,
            backendNodeID: backendNodeID,
            backendNodeIDIsStable: backendNodeIDIsStable,
            frameID: frameID,
            nodeType: DOMNodeType(protocolValue: nodeType),
            nodeName: nodeName,
            localName: localName,
            nodeValue: nodeValue,
            pseudoType: pseudoType,
            shadowRootType: shadowRootType,
            attributes: attributes,
            regularChildren: regularChildren,
            children: children,
            contentDocument: contentDocument,
            shadowRoots: shadowRoots,
            templateContent: templateContent,
            beforePseudoElement: beforePseudoElement,
            afterPseudoElement: afterPseudoElement,
            childCount: childCount,
            childCountIsKnown: childCountIsKnown,
            layoutFlags: layoutFlags,
            isRendered: isRendered,
            styleRevision: styleRevision,
            preview: preview,
            path: path,
            selectorPath: selectorPath
        )
    }

    public var localID: UInt64 {
        id.localID
    }

    public nonisolated static func == (lhs: DOMNodeModel, rhs: DOMNodeModel) -> Bool {
        lhs === rhs
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    package func clearSelectionProjectionState() {
        path = []
        selectorPath = ""
        styleRevision = 0
    }
}
