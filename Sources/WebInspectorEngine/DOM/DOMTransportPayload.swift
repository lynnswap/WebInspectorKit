import Foundation

package struct DOMGraphNodeDescriptor: Sendable {
    package var key: DOMNodeKey
    package var frameID: String?
    package var nodeType: DOMNodeType
    package var nodeName: String
    package var localName: String
    package var nodeValue: String
    package var pseudoType: String?
    package var shadowRootType: String?
    package var attributes: [DOMAttribute]
    package var regularChildCount: Int
    package var regularChildrenAreLoaded: Bool
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

    package var targetIdentifier: String {
        key.targetIdentifier
    }

    package var nodeID: Int {
        key.nodeID
    }

    package init(
        targetIdentifier: String,
        nodeID: Int,
        frameID: String? = nil,
        nodeType: DOMNodeType,
        nodeName: String,
        localName: String,
        nodeValue: String,
        pseudoType: String? = nil,
        shadowRootType: String? = nil,
        attributes: [DOMAttribute],
        regularChildCount: Int,
        regularChildrenAreLoaded: Bool = false,
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
        self.key = DOMNodeKey(targetIdentifier: targetIdentifier, nodeID: nodeID)
        self.frameID = frameID
        self.nodeType = nodeType
        self.nodeName = nodeName
        self.localName = localName
        self.nodeValue = nodeValue
        self.pseudoType = pseudoType
        self.shadowRootType = shadowRootType
        self.attributes = attributes
        self.regularChildCount = max(0, regularChildCount)
        self.regularChildrenAreLoaded = regularChildrenAreLoaded || regularChildren != nil || !children.isEmpty
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
        targetIdentifier: String,
        nodeID: Int,
        frameID: String? = nil,
        nodeType: Int,
        nodeName: String,
        localName: String,
        nodeValue: String,
        pseudoType: String? = nil,
        shadowRootType: String? = nil,
        attributes: [DOMAttribute],
        regularChildCount: Int,
        regularChildrenAreLoaded: Bool = false,
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
            targetIdentifier: targetIdentifier,
            nodeID: nodeID,
            frameID: frameID,
            nodeType: DOMNodeType(protocolValue: nodeType),
            nodeName: nodeName,
            localName: localName,
            nodeValue: nodeValue,
            pseudoType: pseudoType,
            shadowRootType: shadowRootType,
            attributes: attributes,
            regularChildCount: regularChildCount,
            regularChildrenAreLoaded: regularChildrenAreLoaded,
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
    package var selectedKey: DOMNodeKey?

    package init(root: DOMGraphNodeDescriptor, selectedKey: DOMNodeKey? = nil) {
        self.root = root
        self.selectedKey = selectedKey
    }
}

package struct DOMSelectionSnapshotPayload: Sendable {
    package var key: DOMNodeKey?
    package var attributes: [DOMAttribute]
    package var path: [String]
    package var selectorPath: String?
    package var styleRevision: Int

    package init(
        key: DOMNodeKey?,
        attributes: [DOMAttribute],
        path: [String],
        selectorPath: String?,
        styleRevision: Int
    ) {
        self.key = key
        self.attributes = attributes
        self.path = path
        self.selectorPath = selectorPath
        self.styleRevision = styleRevision
    }
}

package struct DOMSelectorPathPayload: Sendable {
    package var key: DOMNodeKey?
    package var selectorPath: String

    package init(key: DOMNodeKey?, selectorPath: String) {
        self.key = key
        self.selectorPath = selectorPath
    }
}

package struct DOMGraphMutationBundle: Sendable {
    package var events: [DOMGraphMutationEvent]

    package init(events: [DOMGraphMutationEvent]) {
        self.events = events
    }
}

package enum DOMGraphPreviousSibling: Sendable, Equatable {
    case missing
    case firstChild
    case node(DOMNodeKey)
}

package enum DOMGraphMutationEvent: Sendable {
    case childNodeInserted(parentKey: DOMNodeKey, previousSibling: DOMGraphPreviousSibling, node: DOMGraphNodeDescriptor)
    case childNodeRemoved(parentKey: DOMNodeKey, nodeKey: DOMNodeKey)
    case shadowRootPushed(hostKey: DOMNodeKey, root: DOMGraphNodeDescriptor)
    case shadowRootPopped(hostKey: DOMNodeKey, rootKey: DOMNodeKey)
    case pseudoElementAdded(parentKey: DOMNodeKey, node: DOMGraphNodeDescriptor)
    case pseudoElementRemoved(parentKey: DOMNodeKey, nodeKey: DOMNodeKey)
    case attributeModified(nodeKey: DOMNodeKey, name: String, value: String, layoutFlags: [String]?, isRendered: Bool?)
    case attributeRemoved(nodeKey: DOMNodeKey, name: String, layoutFlags: [String]?, isRendered: Bool?)
    case characterDataModified(nodeKey: DOMNodeKey, value: String, layoutFlags: [String]?, isRendered: Bool?)
    case childNodeCountUpdated(nodeKey: DOMNodeKey, childCount: Int, layoutFlags: [String]?, isRendered: Bool?)
    case setChildNodes(parentKey: DOMNodeKey, nodes: [DOMGraphNodeDescriptor])
    case setDetachedRoots(nodes: [DOMGraphNodeDescriptor])
    case attachFrameDocument(ownerKey: DOMNodeKey, documentRoot: DOMGraphNodeDescriptor)
    case documentUpdated
}
