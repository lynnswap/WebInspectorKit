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
    package var pseudoType: String?
    package var shadowRootType: String?
    package var attributes: [DOMAttribute]
    package var childCount: Int
    package var childCountIsKnown: Bool
    package var layoutFlags: [String]
    package var isRendered: Bool
    package var regularChildren: [DOMGraphNodeDescriptor]
    private var contentDocuments: [DOMGraphNodeDescriptor]
    package var shadowRoots: [DOMGraphNodeDescriptor]
    private var templateContents: [DOMGraphNodeDescriptor]
    private var beforePseudoElements: [DOMGraphNodeDescriptor]
    private var afterPseudoElements: [DOMGraphNodeDescriptor]

    package var contentDocument: DOMGraphNodeDescriptor? {
        get {
            contentDocuments.first
        }
        set {
            contentDocuments = newValue.map { [$0] } ?? []
        }
    }

    package var templateContent: DOMGraphNodeDescriptor? {
        get {
            templateContents.first
        }
        set {
            templateContents = newValue.map { [$0] } ?? []
        }
    }

    package var beforePseudoElement: DOMGraphNodeDescriptor? {
        get {
            beforePseudoElements.first
        }
        set {
            beforePseudoElements = newValue.map { [$0] } ?? []
        }
    }

    package var afterPseudoElement: DOMGraphNodeDescriptor? {
        get {
            afterPseudoElements.first
        }
        set {
            afterPseudoElements = newValue.map { [$0] } ?? []
        }
    }

    package var children: [DOMGraphNodeDescriptor] {
        get {
            regularChildren
        }
        set {
            regularChildren = newValue
        }
    }

    package var effectiveChildren: [DOMGraphNodeDescriptor] {
        if let contentDocument {
            return [contentDocument]
        }
        return shadowRoots + regularChildren
    }

    package var visibleDOMTreeChildren: [DOMGraphNodeDescriptor] {
        var visibleChildren: [DOMGraphNodeDescriptor] = []
        if let templateContent {
            visibleChildren.append(templateContent)
        }
        if let beforePseudoElement {
            visibleChildren.append(beforePseudoElement)
        }
        visibleChildren.append(contentsOf: effectiveChildren)
        if let afterPseudoElement {
            visibleChildren.append(afterPseudoElement)
        }
        return visibleChildren
    }

    package init(
        localID: UInt64,
        backendNodeID: Int?,
        backendNodeIDIsStable: Bool? = nil,
        frameID: String? = nil,
        nodeType: DOMNodeType,
        nodeName: String,
        localName: String,
        nodeValue: String,
        pseudoType: String? = nil,
        shadowRootType: String? = nil,
        attributes: [DOMAttribute],
        childCount: Int,
        childCountIsKnown: Bool = true,
        layoutFlags: [String],
        isRendered: Bool,
        regularChildren: [DOMGraphNodeDescriptor]? = nil,
        children: [DOMGraphNodeDescriptor] = [],
        contentDocument: DOMGraphNodeDescriptor? = nil,
        shadowRoots: [DOMGraphNodeDescriptor] = [],
        templateContent: DOMGraphNodeDescriptor? = nil,
        beforePseudoElement: DOMGraphNodeDescriptor? = nil,
        afterPseudoElement: DOMGraphNodeDescriptor? = nil
    ) {
        self.localID = localID
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
        self.childCount = childCount
        self.childCountIsKnown = childCountIsKnown
        self.layoutFlags = layoutFlags
        self.isRendered = isRendered
        self.regularChildren = regularChildren ?? children
        self.contentDocuments = contentDocument.map { [$0] } ?? []
        self.shadowRoots = shadowRoots
        self.templateContents = templateContent.map { [$0] } ?? []
        self.beforePseudoElements = beforePseudoElement.map { [$0] } ?? []
        self.afterPseudoElements = afterPseudoElement.map { [$0] } ?? []
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
        pseudoType: String? = nil,
        shadowRootType: String? = nil,
        attributes: [DOMAttribute],
        childCount: Int,
        childCountIsKnown: Bool = true,
        layoutFlags: [String],
        isRendered: Bool,
        regularChildren: [DOMGraphNodeDescriptor]? = nil,
        children: [DOMGraphNodeDescriptor] = [],
        contentDocument: DOMGraphNodeDescriptor? = nil,
        shadowRoots: [DOMGraphNodeDescriptor] = [],
        templateContent: DOMGraphNodeDescriptor? = nil,
        beforePseudoElement: DOMGraphNodeDescriptor? = nil,
        afterPseudoElement: DOMGraphNodeDescriptor? = nil
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
            pseudoType: pseudoType,
            shadowRootType: shadowRootType,
            attributes: attributes,
            childCount: childCount,
            childCountIsKnown: childCountIsKnown,
            layoutFlags: layoutFlags,
            isRendered: isRendered,
            regularChildren: regularChildren,
            children: children,
            contentDocument: contentDocument,
            shadowRoots: shadowRoots,
            templateContent: templateContent,
            beforePseudoElement: beforePseudoElement,
            afterPseudoElement: afterPseudoElement
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
    case shadowRootPushed(hostLocalID: UInt64, root: DOMGraphNodeDescriptor)
    case shadowRootPopped(hostLocalID: UInt64, rootLocalID: UInt64)
    case pseudoElementAdded(parentLocalID: UInt64, node: DOMGraphNodeDescriptor)
    case pseudoElementRemoved(parentLocalID: UInt64, nodeLocalID: UInt64)
    case attributeModified(nodeLocalID: UInt64, name: String, value: String, layoutFlags: [String]?, isRendered: Bool?)
    case attributeRemoved(nodeLocalID: UInt64, name: String, layoutFlags: [String]?, isRendered: Bool?)
    case characterDataModified(nodeLocalID: UInt64, value: String, layoutFlags: [String]?, isRendered: Bool?)
    case childNodeCountUpdated(nodeLocalID: UInt64, childCount: Int, layoutFlags: [String]?, isRendered: Bool?)
    case setChildNodes(parentLocalID: UInt64, nodes: [DOMGraphNodeDescriptor])
    case setDetachedRoots(nodes: [DOMGraphNodeDescriptor])
    case replaceSubtree(root: DOMGraphNodeDescriptor)
    case documentUpdated
}
