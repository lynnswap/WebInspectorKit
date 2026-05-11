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

public struct DOMNodeKey: Hashable, Sendable {
    public let targetIdentifier: String
    public let nodeID: Int

    public init(targetIdentifier: String, nodeID: Int) {
        self.targetIdentifier = targetIdentifier
        self.nodeID = nodeID
    }
}

package enum DOMRegularChildState {
    case unrequested(count: Int)
    case loaded([DOMNodeModel])

    package var loadedChildren: [DOMNodeModel] {
        get {
            switch self {
            case .unrequested:
                return []
            case let .loaded(children):
                return children
            }
        }
        set {
            self = .loaded(newValue)
        }
    }

    package var knownCount: Int {
        switch self {
        case let .unrequested(count):
            return max(0, count)
        case let .loaded(children):
            return children.count
        }
    }

    package var hasUnrequestedChildren: Bool {
        switch self {
        case let .unrequested(count):
            return count > 0
        case .loaded:
            return false
        }
    }
}

@MainActor
@Observable
public final class DOMNodeModel: Equatable, Hashable, Identifiable {
    public struct ID: Hashable, Sendable {
        public let documentIdentity: UUID
        public let targetIdentifier: String
        public let nodeID: Int

        public init(documentIdentity: UUID, targetIdentifier: String, nodeID: Int) {
            self.documentIdentity = documentIdentity
            self.targetIdentifier = targetIdentifier
            self.nodeID = nodeID
        }
    }

    public let id: ID
    public var frameID: String?
    public var nodeType: DOMNodeType
    public var nodeName: String
    public var localName: String
    public var nodeValue: String
    public var attributes: [DOMAttribute]

    public weak var parent: DOMNodeModel?
    public weak var previousSibling: DOMNodeModel?
    public weak var nextSibling: DOMNodeModel?
    package var regularChildState: DOMRegularChildState
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

    public var key: DOMNodeKey {
        DOMNodeKey(targetIdentifier: id.targetIdentifier, nodeID: id.nodeID)
    }

    public var targetIdentifier: String {
        id.targetIdentifier
    }

    public var nodeID: Int {
        id.nodeID
    }

    package var regularChildren: [DOMNodeModel] {
        get {
            regularChildState.loadedChildren
        }
        set {
            regularChildState.loadedChildren = newValue
        }
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
        contentDocument == nil && regularChildState.hasUnrequestedChildren
    }

    package var regularChildCount: Int {
        regularChildState.knownCount
    }

    public var hasVisibleDOMTreeChildren: Bool {
        templateContent != nil
            || beforePseudoElement != nil
            || contentDocument != nil
            || !shadowRoots.isEmpty
            || regularChildState.knownCount > 0
            || afterPseudoElement != nil
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

    public var layoutFlags: [String]
    public var isRendered: Bool
    public var styleRevision: Int
    public var preview: String
    public var path: [String]
    public var selectorPath: String

    package init(
        id: ID,
        frameID: String? = nil,
        nodeType: DOMNodeType,
        nodeName: String,
        localName: String,
        nodeValue: String,
        pseudoType: String? = nil,
        shadowRootType: String? = nil,
        attributes: [DOMAttribute],
        regularChildState: DOMRegularChildState? = nil,
        regularChildren: [DOMNodeModel]? = nil,
        children: [DOMNodeModel] = [],
        contentDocument: DOMNodeModel? = nil,
        shadowRoots: [DOMNodeModel] = [],
        templateContent: DOMNodeModel? = nil,
        beforePseudoElement: DOMNodeModel? = nil,
        afterPseudoElement: DOMNodeModel? = nil,
        layoutFlags: [String] = [],
        isRendered: Bool = true,
        styleRevision: Int = 0,
        preview: String = "",
        path: [String] = [],
        selectorPath: String = ""
    ) {
        self.id = id
        self.frameID = frameID
        self.nodeType = nodeType
        self.nodeName = nodeName
        self.localName = localName
        self.nodeValue = nodeValue
        self.pseudoType = pseudoType
        self.shadowRootType = shadowRootType
        self.attributes = attributes
        if let regularChildState {
            self.regularChildState = regularChildState
        } else if let regularChildren {
            self.regularChildState = .loaded(regularChildren)
        } else {
            self.regularChildState = .loaded(children)
        }
        self.contentDocument = contentDocument
        self.shadowRoots = shadowRoots
        self.templateContent = templateContent
        self.beforePseudoElement = beforePseudoElement
        self.afterPseudoElement = afterPseudoElement
        self.layoutFlags = layoutFlags
        self.isRendered = isRendered
        self.styleRevision = styleRevision
        self.preview = preview
        self.path = path
        self.selectorPath = selectorPath
    }

    package convenience init(
        id: ID,
        frameID: String? = nil,
        nodeType: Int,
        nodeName: String,
        localName: String,
        nodeValue: String,
        pseudoType: String? = nil,
        shadowRootType: String? = nil,
        attributes: [DOMAttribute],
        regularChildState: DOMRegularChildState? = nil,
        regularChildren: [DOMNodeModel]? = nil,
        children: [DOMNodeModel] = [],
        contentDocument: DOMNodeModel? = nil,
        shadowRoots: [DOMNodeModel] = [],
        templateContent: DOMNodeModel? = nil,
        beforePseudoElement: DOMNodeModel? = nil,
        afterPseudoElement: DOMNodeModel? = nil,
        layoutFlags: [String] = [],
        isRendered: Bool = true,
        styleRevision: Int = 0,
        preview: String = "",
        path: [String] = [],
        selectorPath: String = ""
    ) {
        self.init(
            id: id,
            frameID: frameID,
            nodeType: DOMNodeType(protocolValue: nodeType),
            nodeName: nodeName,
            localName: localName,
            nodeValue: nodeValue,
            pseudoType: pseudoType,
            shadowRootType: shadowRootType,
            attributes: attributes,
            regularChildState: regularChildState,
            regularChildren: regularChildren,
            children: children,
            contentDocument: contentDocument,
            shadowRoots: shadowRoots,
            templateContent: templateContent,
            beforePseudoElement: beforePseudoElement,
            afterPseudoElement: afterPseudoElement,
            layoutFlags: layoutFlags,
            isRendered: isRendered,
            styleRevision: styleRevision,
            preview: preview,
            path: path,
            selectorPath: selectorPath
        )
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
