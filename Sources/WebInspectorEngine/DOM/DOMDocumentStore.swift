import Foundation
import Observation
import OSLog

private let domDocumentLogger = Logger(subsystem: "WebInspectorKit", category: "DOMDocumentModel")

private enum DOMChildStorageLocation {
    case regular(Int)
    case contentDocument
    case shadowRoot(Int)
    case templateContent
    case beforePseudoElement
    case otherPseudoElement(Int)
    case afterPseudoElement

    var countsTowardChildCount: Bool {
        switch self {
        case .regular, .contentDocument:
            return true
        case .shadowRoot, .templateContent, .beforePseudoElement, .otherPseudoElement, .afterPseudoElement:
            return false
        }
    }
}

public enum DOMDocumentState: Equatable, Sendable {
    case detached
    case loading
    case ready
    case failed
}

package enum DOMTreeInvalidation: Equatable, Sendable {
    case documentReset
    case structural(affectedKeys: Set<DOMNodeKey>)
    case content(affectedKeys: Set<DOMNodeKey>)
}

@MainActor
@Observable
public final class DOMDocumentModel {
    public private(set) var documentState: DOMDocumentState = .detached
    public private(set) var rootNode: DOMNodeModel?
    public private(set) var selectedNode: DOMNodeModel?
    public private(set) var errorMessage: String?

    package private(set) var documentIdentity = UUID()
    package private(set) var projectionRevision: UInt64 = 0
    package private(set) var treeRevision: UInt64 = 0
    package private(set) var selectionRevision: UInt64 = 0
    package private(set) var selectedNodeDetailRevision: UInt64 = 0
    package private(set) var mirrorInvariantViolationReason: String?
    package private(set) var rejectedStructuralMutationParentKeys: Set<DOMNodeKey> = []
    @ObservationIgnored private var treeInvalidationHandlers: [UUID: @MainActor (DOMTreeInvalidation) -> Void] = [:]

    private var nodesByKey: [DOMNodeKey: DOMNodeModel] = [:]
    private var detachedRoots: [DOMNodeModel] = []

    public init() {}

    package func addTreeInvalidationHandler(
        _ handler: @escaping @MainActor (DOMTreeInvalidation) -> Void
    ) -> UUID {
        let id = UUID()
        treeInvalidationHandlers[id] = handler
        return id
    }

    package func removeTreeInvalidationHandler(id: UUID) {
        treeInvalidationHandlers[id] = nil
    }

    package func setErrorMessage(_ message: String?) {
        guard errorMessage != message else {
            return
        }
        errorMessage = message
    }

    package func consumeMirrorInvariantViolationReason() -> String? {
        defer { mirrorInvariantViolationReason = nil }
        return mirrorInvariantViolationReason
    }

    package func consumeRejectedStructuralMutationParentKeys() -> Set<DOMNodeKey> {
        defer { rejectedStructuralMutationParentKeys.removeAll(keepingCapacity: true) }
        return rejectedStructuralMutationParentKeys
    }

    package func clearSelection() {
        let previousSelectedNode = selectedNode
        selectedNode = nil
        projectionRevision &+= 1
        selectedNodeDetailRevision &+= 1
        guard previousSelectedNode != nil else {
            return
        }
        logSelectionDiagnostics(
            "clearSelection",
            previous: previousSelectedNode,
            next: selectedNode
        )
    }

    package func beginLoadingDocument(isFreshDocument: Bool = true) {
        let previousDocumentIdentity = documentIdentity
        let previousSelectedNode = selectedNode
        let previousRootNode = rootNode
        if isFreshDocument {
            documentIdentity = UUID()
        }
        clearContents()
        documentState = .loading
        projectionRevision &+= 1
        treeRevision &+= 1
        selectedNodeDetailRevision &+= 1
        emitTreeInvalidation(.documentReset)
        guard previousSelectedNode != nil || previousRootNode != nil else {
            return
        }
        logDocumentDiagnostics(
            "beginLoadingDocument",
            extra: "isFreshDocument=\(isFreshDocument) previousDocumentIdentity=\(compactDocumentIdentity(previousDocumentIdentity)) nextDocumentIdentity=\(compactDocumentIdentity(documentIdentity)) previousRoot=\(selectionNodeSummary(previousRootNode))"
        )
    }

    package func clearDocument(isFreshDocument: Bool = true) {
        let previousDocumentIdentity = documentIdentity
        let previousSelectedNode = selectedNode
        let previousRootNode = rootNode
        if isFreshDocument {
            documentIdentity = UUID()
        }
        clearContents()
        documentState = .detached
        projectionRevision &+= 1
        treeRevision &+= 1
        selectedNodeDetailRevision &+= 1
        emitTreeInvalidation(.documentReset)
        guard previousSelectedNode != nil || previousRootNode != nil else {
            return
        }
        logDocumentDiagnostics(
            "clearDocument",
            extra: "isFreshDocument=\(isFreshDocument) previousDocumentIdentity=\(compactDocumentIdentity(previousDocumentIdentity)) nextDocumentIdentity=\(compactDocumentIdentity(documentIdentity)) previousRoot=\(selectionNodeSummary(previousRootNode))"
        )
    }

    package func failDocumentLoad(_ message: String?) {
        clearContents()
        errorMessage = message
        documentState = .failed
        projectionRevision &+= 1
        treeRevision &+= 1
        selectedNodeDetailRevision &+= 1
        emitTreeInvalidation(.documentReset)
    }

    package func replaceDocument(
        with snapshot: DOMGraphSnapshot,
        isFreshDocument: Bool = true
    ) {
        let previousSelectionAnchor = isFreshDocument ? nil : selectionAnchor(for: selectedNode)
        if isFreshDocument {
            documentIdentity = UUID()
        }
        replaceContents(
            selectedKey: snapshot.selectedKey,
            selectionAnchor: previousSelectionAnchor
        ) {
            rootNode = buildSubtree(from: snapshot.root, parent: nil)
        }
        documentState = .ready
        projectionRevision &+= 1
        treeRevision &+= 1
        selectedNodeDetailRevision &+= 1
        emitTreeInvalidation(.documentReset)
    }

    package func applyMutationBundle(_ bundle: DOMGraphMutationBundle) {
        guard !bundle.events.isEmpty else {
            return
        }

        let previousSelectedKey = selectedKey
        let previousSelectedNode = selectedNode
        var structuralKeys = Set<DOMNodeKey>()
        var contentKeys = Set<DOMNodeKey>()
        for event in bundle.events {
            switch event {
            case let .childNodeInserted(parentKey, previousSibling, node):
                structuralKeys.insert(parentKey)
                structuralKeys.insert(node.key)
                applyChildNodeInserted(parentKey: parentKey, previousSibling: previousSibling, node: node)
            case let .childNodeRemoved(parentKey, nodeKey):
                structuralKeys.insert(parentKey)
                structuralKeys.insert(nodeKey)
                applyChildNodeRemoved(parentKey: parentKey, nodeKey: nodeKey)
            case let .shadowRootPushed(hostKey, root):
                structuralKeys.insert(hostKey)
                structuralKeys.insert(root.key)
                applyShadowRootPushed(hostKey: hostKey, root: root)
            case let .shadowRootPopped(hostKey, rootKey):
                structuralKeys.insert(hostKey)
                structuralKeys.insert(rootKey)
                applyChildNodeRemoved(parentKey: hostKey, nodeKey: rootKey)
            case let .pseudoElementAdded(parentKey, node):
                structuralKeys.insert(parentKey)
                structuralKeys.insert(node.key)
                applyPseudoElementAdded(parentKey: parentKey, node: node)
            case let .pseudoElementRemoved(parentKey, nodeKey):
                structuralKeys.insert(parentKey)
                structuralKeys.insert(nodeKey)
                applyChildNodeRemoved(parentKey: parentKey, nodeKey: nodeKey)
            case let .attributeModified(nodeKey, name, value, layoutFlags, isRendered):
                contentKeys.insert(nodeKey)
                applyAttributeModified(
                    nodeKey: nodeKey,
                    name: name,
                    value: value,
                    layoutFlags: layoutFlags,
                    isRendered: isRendered
                )
            case let .attributeRemoved(nodeKey, name, layoutFlags, isRendered):
                contentKeys.insert(nodeKey)
                applyAttributeRemoved(
                    nodeKey: nodeKey,
                    name: name,
                    layoutFlags: layoutFlags,
                    isRendered: isRendered
                )
            case let .characterDataModified(nodeKey, value, layoutFlags, isRendered):
                contentKeys.insert(nodeKey)
                applyCharacterDataModified(
                    nodeKey: nodeKey,
                    value: value,
                    layoutFlags: layoutFlags,
                    isRendered: isRendered
                )
            case let .childNodeCountUpdated(nodeKey, childCount, layoutFlags, isRendered):
                contentKeys.insert(nodeKey)
                applyChildNodeCountUpdated(
                    nodeKey: nodeKey,
                    childCount: childCount,
                    layoutFlags: layoutFlags,
                    isRendered: isRendered
                )
            case let .setChildNodes(parentKey, nodes):
                structuralKeys.insert(parentKey)
                structuralKeys.formUnion(nodes.map(\.key))
                applySetChildNodes(parentKey: parentKey, nodes: nodes)
            case let .setDetachedRoots(nodes):
                structuralKeys.formUnion(nodes.map(\.key))
                applySetDetachedRoots(nodes)
            case let .attachFrameDocument(ownerKey, documentRoot):
                structuralKeys.insert(ownerKey)
                structuralKeys.insert(documentRoot.key)
                attachFrameDocument(ownerKey: ownerKey, documentRoot: documentRoot)
            case .documentUpdated:
                return
            }
        }

        reconcileSelectedNode()
        if selectedNode == nil, let previousSelectedKey {
            selectedNode = node(forKey: previousSelectedKey)
        }
        projectionRevision &+= 1
        treeRevision &+= 1
        if selectedNode !== previousSelectedNode
            || selectedNode.map({ contentKeys.contains($0.key) || structuralKeys.contains($0.key) }) == true {
            selectedNodeDetailRevision &+= 1
        }
        if !structuralKeys.isEmpty {
            emitTreeInvalidation(.structural(affectedKeys: structuralKeys))
        } else if !contentKeys.isEmpty {
            emitTreeInvalidation(.content(affectedKeys: contentKeys))
        }
        logSelectionTransitionIfNeeded(
            action: "applyMutationBundle",
            previous: previousSelectedNode,
            next: selectedNode,
            extra: "eventCount=\(bundle.events.count)"
        )
    }

    package func applySelectionSnapshot(_ payload: DOMSelectionSnapshotPayload?) {
        let previousSelectedNode = selectedNode
        if let previousSelectedNode = selectedNode, payload?.key == nil {
            previousSelectedNode.clearSelectionProjectionState()
        }
        guard let payload, let key = payload.key else {
            selectedNode = nil
            projectionRevision &+= 1
            selectionRevision &+= 1
            selectedNodeDetailRevision &+= 1
            logSelectionTransitionIfNeeded(
                action: "applySelectionSnapshot",
                previous: previousSelectedNode,
                next: selectedNode,
                extra: "payload=nil"
            )
            return
        }

        guard let node = resolveAttachedSelectionNode(key: key) else {
            logSelectionDiagnostics(
                "applySelectionSnapshot ignored unknown or detached selection",
                previous: previousSelectedNode,
                next: previousSelectedNode,
                extra: "payloadKey=\(keySummary(key)) selector=\(payload.selectorPath ?? "nil")"
            )
            return
        }
        node.path = payload.path
        if let selectorPath = payload.selectorPath {
            node.selectorPath = selectorPath
        }
        node.styleRevision = payload.styleRevision
        let didChangeTree = replaceAttributes(
            on: node,
            with: normalizeAttributes(payload.attributes, nodeID: node.nodeID)
        )
        selectedNode = node
        projectionRevision &+= 1
        selectionRevision &+= 1
        selectedNodeDetailRevision &+= 1
        if didChangeTree {
            treeRevision &+= 1
            emitTreeInvalidation(.content(affectedKeys: [node.key]))
        }
        logSelectionTransitionIfNeeded(
            action: "applySelectionSnapshot",
            previous: previousSelectedNode,
            next: selectedNode,
            extra: "payloadKey=\(keySummary(key)) selector=\(payload.selectorPath ?? "nil")"
        )
    }

    package func applySelectorPath(_ payload: DOMSelectorPathPayload) {
        guard
            let key = payload.key,
            let node = node(forKey: key),
            selectedNode === node
        else {
            return
        }

        if node.selectorPath != payload.selectorPath {
            node.selectorPath = payload.selectorPath
            selectedNodeDetailRevision &+= 1
        }
    }

    package func applySelectorPath(_ selectorPath: String, for node: DOMNodeModel) {
        guard selectedNode === node, contains(node) else {
            return
        }
        if node.selectorPath != selectorPath {
            node.selectorPath = selectorPath
            selectedNodeDetailRevision &+= 1
        }
    }

    package func updateSelectedAttribute(name: String, value: String) {
        guard let node = selectedNode, contains(node) else {
            return
        }
        if setAttributeValue(on: node, name: name, value: value) {
            selectedNodeDetailRevision &+= 1
            treeRevision &+= 1
            emitTreeInvalidation(.content(affectedKeys: [node.key]))
        }
    }

    package func removeSelectedAttribute(name: String) {
        guard let node = selectedNode, contains(node) else {
            return
        }
        if removeAttributeValue(on: node, name: name) {
            selectedNodeDetailRevision &+= 1
            treeRevision &+= 1
            emitTreeInvalidation(.content(affectedKeys: [node.key]))
        }
    }

    package func containsEntry(key: DOMNodeKey) -> Bool {
        node(forKey: key) != nil
    }

    package func node(id: DOMNodeModel.ID) -> DOMNodeModel? {
        guard id.documentIdentity == documentIdentity else {
            return nil
        }
        return node(forKey: DOMNodeKey(targetIdentifier: id.targetIdentifier, nodeID: id.nodeID))
    }

    package func node(key: DOMNodeKey) -> DOMNodeModel? {
        node(forKey: key)
    }

    package func node(targetIdentifier: String, nodeID: Int) -> DOMNodeModel? {
        node(forKey: DOMNodeKey(targetIdentifier: targetIdentifier, nodeID: nodeID))
    }

    package func topLevelRoots() -> [DOMNodeModel] {
        rootNode.map { [$0] } ?? []
    }

    package func detachedRootsForDiagnostics() -> [DOMNodeModel] {
        detachedRoots
    }

    package func contains(_ node: DOMNodeModel) -> Bool {
        nodesByKey[node.key] === node
    }

    package func attributeValue(
        name: String,
        key: DOMNodeKey
    ) -> String? {
        guard let node = node(forKey: key) else {
            return nil
        }
        return node.attributes.first(where: { $0.name == name })?.value
    }

    @discardableResult
    package func updateAttribute(
        name: String,
        value: String,
        key: DOMNodeKey
    ) -> Bool {
        guard let node = node(forKey: key) else {
            return false
        }
        let didChange = setAttributeValue(on: node, name: name, value: value)
        if didChange {
            treeRevision &+= 1
            if selectedNode === node {
                selectedNodeDetailRevision &+= 1
            }
            emitTreeInvalidation(.content(affectedKeys: [node.key]))
        }
        return didChange
    }

    @discardableResult
    package func removeAttribute(
        name: String,
        key: DOMNodeKey
    ) -> Bool {
        guard let node = node(forKey: key) else {
            return false
        }
        let didChange = removeAttributeValue(on: node, name: name)
        if didChange {
            treeRevision &+= 1
            if selectedNode === node {
                selectedNodeDetailRevision &+= 1
            }
            emitTreeInvalidation(.content(affectedKeys: [node.key]))
        }
        return didChange
    }

    package var selectedKey: DOMNodeKey? {
        selectedNode?.key
    }

    package func removeNode(id: DOMNodeModel.ID) {
        guard let node = node(id: id) else {
            return
        }
        removeSubtree(node, removeFromParent: true)
        treeRevision &+= 1
        selectedNodeDetailRevision &+= 1
        emitTreeInvalidation(.structural(affectedKeys: [node.key]))
    }
}

private extension DOMDocumentModel {
    struct SelectionAnchor {
        let routeFromRoot: [Int]
        let targetIdentifier: String
        let nodeType: DOMNodeType
        let nodeName: String
        let localName: String
        let pseudoType: String?
        let shadowRootType: String?
        let idAttribute: String?
        let path: [String]
        let selectorPath: String
        let styleRevision: Int
    }

    func emitTreeInvalidation(_ invalidation: DOMTreeInvalidation) {
        for handler in treeInvalidationHandlers.values {
            handler(invalidation)
        }
    }

    func replaceContents(
        selectedKey: DOMNodeKey?,
        selectionAnchor: SelectionAnchor?,
        build: () -> Void
    ) {
        clearContents()
        build()
        if let selectedKey {
            selectedNode = node(forKey: selectedKey)
        }
        if selectedNode == nil, let selectionAnchor {
            selectedNode = resolveSelectionAnchor(selectionAnchor)
        }
        reconcileSelectedNode()
    }

    func selectionAnchor(for node: DOMNodeModel?) -> SelectionAnchor? {
        guard let node,
              let routeFromRoot = visibleRouteFromRoot(to: node) else {
            return nil
        }
        return SelectionAnchor(
            routeFromRoot: routeFromRoot,
            targetIdentifier: node.targetIdentifier,
            nodeType: node.nodeType,
            nodeName: node.nodeName,
            localName: node.localName,
            pseudoType: node.pseudoType,
            shadowRootType: node.shadowRootType,
            idAttribute: attributeValue("id", on: node),
            path: node.path,
            selectorPath: node.selectorPath,
            styleRevision: node.styleRevision
        )
    }

    func visibleRouteFromRoot(to node: DOMNodeModel) -> [Int]? {
        var route: [Int] = []
        var current = node
        while let parent = current.parent {
            guard let index = parent.visibleDOMTreeChildren.firstIndex(where: { $0 === current }) else {
                return nil
            }
            route.append(index)
            current = parent
        }
        guard current === rootNode else {
            return nil
        }
        return route.reversed()
    }

    func resolveSelectionAnchor(_ anchor: SelectionAnchor) -> DOMNodeModel? {
        if let node = resolveSelectionAnchorByRoute(anchor) {
            return node
        }
        guard anchor.idAttribute?.isEmpty == false else {
            return nil
        }
        return firstNodeMatchingAnchor(anchor, in: rootNode)
    }

    func resolveSelectionAnchorByRoute(_ anchor: SelectionAnchor) -> DOMNodeModel? {
        guard var current = rootNode else {
            return nil
        }
        for index in anchor.routeFromRoot {
            let children = current.visibleDOMTreeChildren
            guard children.indices.contains(index) else {
                return nil
            }
            current = children[index]
        }
        guard selectionAnchor(anchor, matches: current) else {
            return nil
        }
        applySelectionProjection(from: anchor, to: current)
        return current
    }

    func firstNodeMatchingAnchor(_ anchor: SelectionAnchor, in node: DOMNodeModel?) -> DOMNodeModel? {
        guard let node else {
            return nil
        }
        if selectionAnchor(anchor, matches: node) {
            applySelectionProjection(from: anchor, to: node)
            return node
        }
        for child in node.visibleDOMTreeChildren {
            if let match = firstNodeMatchingAnchor(anchor, in: child) {
                return match
            }
        }
        return nil
    }

    func selectionAnchor(_ anchor: SelectionAnchor, matches node: DOMNodeModel) -> Bool {
        guard node.targetIdentifier == anchor.targetIdentifier,
              node.nodeType == anchor.nodeType,
              node.nodeName == anchor.nodeName,
              node.localName == anchor.localName,
              node.pseudoType == anchor.pseudoType,
              node.shadowRootType == anchor.shadowRootType else {
            return false
        }
        if let idAttribute = anchor.idAttribute {
            return attributeValue("id", on: node) == idAttribute
        }
        return true
    }

    func applySelectionProjection(from anchor: SelectionAnchor, to node: DOMNodeModel) {
        node.path = anchor.path
        node.selectorPath = anchor.selectorPath
        node.styleRevision = anchor.styleRevision
    }

    func attributeValue(_ name: String, on node: DOMNodeModel) -> String? {
        node.attributes.first(where: { $0.name == name })?.value
    }

    func clearContents() {
        nodesByKey.removeAll(keepingCapacity: true)
        rootNode = nil
        detachedRoots.removeAll(keepingCapacity: true)
        selectedNode = nil
        errorMessage = nil
        mirrorInvariantViolationReason = nil
        rejectedStructuralMutationParentKeys.removeAll(keepingCapacity: true)
    }

    func node(forKey key: DOMNodeKey) -> DOMNodeModel? {
        nodesByKey[key]
    }

    func insert(_ node: DOMNodeModel) {
        nodesByKey[node.key] = node
    }

    func removeNode(_ node: DOMNodeModel) {
        guard nodesByKey[node.key] === node else {
            return
        }
        nodesByKey.removeValue(forKey: node.key)
    }

    func normalizeAttributes(_ attributes: [DOMAttribute], nodeID: Int?) -> [DOMAttribute] {
        attributes.map {
            DOMAttribute(
                nodeId: $0.nodeId ?? nodeID,
                name: $0.name,
                value: $0.value
            )
        }
    }

    @discardableResult
    func setAttributeValue(
        on node: DOMNodeModel,
        name: String,
        value: String
    ) -> Bool {
        if let index = node.attributes.firstIndex(where: { $0.name == name }) {
            guard node.attributes[index].value != value else {
                return false
            }
            node.attributes[index].value = value
            return true
        }
        node.attributes.append(DOMAttribute(nodeId: node.nodeID, name: name, value: value))
        return true
    }

    @discardableResult
    func removeAttributeValue(
        on node: DOMNodeModel,
        name: String
    ) -> Bool {
        guard node.attributes.contains(where: { $0.name == name }) else {
            return false
        }
        node.attributes.removeAll { $0.name == name }
        return true
    }

    @discardableResult
    func replaceAttributes(
        on node: DOMNodeModel,
        with newAttributes: [DOMAttribute]
    ) -> Bool {
        guard node.attributes != newAttributes else {
            return false
        }
        node.attributes = newAttributes
        return true
    }

    @discardableResult
    func buildSubtree(from descriptor: DOMGraphNodeDescriptor, parent: DOMNodeModel?) -> DOMNodeModel {
        if let existing = node(forKey: descriptor.key) {
            removeSubtree(existing, removeFromParent: true)
        }

        let regularChildState: DOMRegularChildState = descriptor.regularChildrenAreLoaded
            ? .loaded([])
            : .unrequested(count: descriptor.regularChildCount)
        let node = DOMNodeModel(
            id: .init(
                documentIdentity: documentIdentity,
                targetIdentifier: descriptor.targetIdentifier,
                nodeID: descriptor.nodeID
            ),
            frameID: descriptor.frameID,
            nodeType: descriptor.nodeType,
            nodeName: descriptor.nodeName,
            localName: descriptor.localName,
            nodeValue: descriptor.nodeValue,
            pseudoType: descriptor.pseudoType,
            shadowRootType: descriptor.shadowRootType,
            attributes: normalizeAttributes(descriptor.attributes, nodeID: descriptor.nodeID),
            regularChildState: regularChildState,
            layoutFlags: descriptor.layoutFlags,
            isRendered: descriptor.isRendered
        )
        node.parent = parent
        insert(node)

        var regularChildren: [DOMNodeModel] = []
        regularChildren.reserveCapacity(descriptor.regularChildren.count)
        for childDescriptor in descriptor.regularChildren {
            let child = buildSubtree(from: childDescriptor, parent: node)
            regularChildren.append(child)
        }
        if descriptor.regularChildrenAreLoaded {
            node.regularChildren = regularChildren
        }
        node.contentDocument = descriptor.contentDocument.map {
            buildSubtree(from: $0, parent: node)
        }
        node.shadowRoots = descriptor.shadowRoots.map {
            buildSubtree(from: $0, parent: node)
        }
        node.templateContent = descriptor.templateContent.map {
            buildSubtree(from: $0, parent: node)
        }
        node.beforePseudoElement = descriptor.beforePseudoElement.map {
            buildSubtree(from: $0, parent: node)
        }
        node.otherPseudoElements = descriptor.otherPseudoElements.map {
            buildSubtree(from: $0, parent: node)
        }
        node.afterPseudoElement = descriptor.afterPseudoElement.map {
            buildSubtree(from: $0, parent: node)
        }
        relinkChildren(of: node)

        return node
    }

    func relinkChildren(of parent: DOMNodeModel) {
        let children = parent.children
        for (index, child) in children.enumerated() {
            child.parent = parent
            child.previousSibling = index > 0 ? children[index - 1] : nil
            child.nextSibling = index + 1 < children.count ? children[index + 1] : nil
        }
    }

    func storageLocation(of child: DOMNodeModel, in parent: DOMNodeModel) -> DOMChildStorageLocation? {
        if let index = parent.regularChildren.firstIndex(where: { $0 === child }) {
            return .regular(index)
        }
        if parent.contentDocument === child {
            return .contentDocument
        }
        if let index = parent.shadowRoots.firstIndex(where: { $0 === child }) {
            return .shadowRoot(index)
        }
        if parent.templateContent === child {
            return .templateContent
        }
        if parent.beforePseudoElement === child {
            return .beforePseudoElement
        }
        if let index = parent.otherPseudoElements.firstIndex(where: { $0 === child }) {
            return .otherPseudoElement(index)
        }
        if parent.afterPseudoElement === child {
            return .afterPseudoElement
        }
        return nil
    }

    @discardableResult
    func detachChild(_ child: DOMNodeModel, from parent: DOMNodeModel) -> DOMChildStorageLocation? {
        guard let location = storageLocation(of: child, in: parent) else {
            return nil
        }
        switch location {
        case let .regular(index):
            parent.regularChildren.remove(at: index)
        case .contentDocument:
            parent.contentDocument = nil
        case let .shadowRoot(index):
            parent.shadowRoots.remove(at: index)
        case .templateContent:
            parent.templateContent = nil
        case .beforePseudoElement:
            parent.beforePseudoElement = nil
        case let .otherPseudoElement(index):
            parent.otherPseudoElements.remove(at: index)
        case .afterPseudoElement:
            parent.afterPseudoElement = nil
        }
        return location
    }

    func detachChild(key: DOMNodeKey, from parent: DOMNodeModel) -> (DOMNodeModel, DOMChildStorageLocation)? {
        if let child = parent.regularChildren.first(where: { $0.key == key }) {
            guard let location = detachChild(child, from: parent) else {
                return nil
            }
            return (child, location)
        }
        if let child = parent.contentDocument, child.key == key {
            guard let location = detachChild(child, from: parent) else {
                return nil
            }
            return (child, location)
        }
        if let child = parent.shadowRoots.first(where: { $0.key == key }) {
            guard let location = detachChild(child, from: parent) else {
                return nil
            }
            return (child, location)
        }
        if let child = parent.templateContent, child.key == key {
            guard let location = detachChild(child, from: parent) else {
                return nil
            }
            return (child, location)
        }
        if let child = parent.beforePseudoElement, child.key == key {
            guard let location = detachChild(child, from: parent) else {
                return nil
            }
            return (child, location)
        }
        if let child = parent.otherPseudoElements.first(where: { $0.key == key }) {
            guard let location = detachChild(child, from: parent) else {
                return nil
            }
            return (child, location)
        }
        if let child = parent.afterPseudoElement, child.key == key {
            guard let location = detachChild(child, from: parent) else {
                return nil
            }
            return (child, location)
        }
        return nil
    }

    func insert(
        _ child: DOMNodeModel,
        into parent: DOMNodeModel,
        at location: DOMChildStorageLocation?
    ) {
        switch location {
        case let .regular(index):
            parent.regularChildren.insert(child, at: min(max(0, index), parent.regularChildren.count))
        case .contentDocument:
            parent.contentDocument = child
        case let .shadowRoot(index):
            parent.shadowRoots.insert(child, at: min(max(0, index), parent.shadowRoots.count))
        case .templateContent:
            parent.templateContent = child
        case .beforePseudoElement:
            parent.beforePseudoElement = child
        case let .otherPseudoElement(index):
            parent.otherPseudoElements.insert(child, at: min(max(0, index), parent.otherPseudoElements.count))
        case .afterPseudoElement:
            parent.afterPseudoElement = child
        case .none:
            parent.regularChildren.append(child)
        }
        child.parent = parent
    }

    func removeExistingNodeBeforeSpecialInsert(key: DOMNodeKey) {
        guard let existing = node(forKey: key) else {
            return
        }
        removeSubtree(existing, removeFromParent: true, decrementParentChildCount: false)
    }

    func applyShadowRootPushed(hostKey: DOMNodeKey, root descriptor: DOMGraphNodeDescriptor) {
        guard let host = node(forKey: hostKey) else {
            flagRejectedStructuralMutation(
                parentKey: hostKey,
                reason: "shadowRootPushed missing host key=\(keySummary(hostKey)) rootKey=\(keySummary(descriptor.key))"
            )
            return
        }

        removeExistingNodeBeforeSpecialInsert(key: descriptor.key)
        let root = buildSubtree(from: descriptor, parent: host)
        host.shadowRoots.removeAll { $0.key == descriptor.key }
        host.shadowRoots.append(root)
        relinkChildren(of: host)
    }

    func applyPseudoElementAdded(parentKey: DOMNodeKey, node descriptor: DOMGraphNodeDescriptor) {
        guard let parent = node(forKey: parentKey) else {
            flagRejectedStructuralMutation(
                parentKey: parentKey,
                reason: "pseudoElementAdded missing parent key=\(keySummary(parentKey)) nodeKey=\(keySummary(descriptor.key))"
            )
            return
        }

        removeExistingNodeBeforeSpecialInsert(key: descriptor.key)
        let inserted = buildSubtree(from: descriptor, parent: parent)
        switch descriptor.pseudoType {
        case "before":
            if let existing = parent.beforePseudoElement {
                removeSubtree(existing, removeFromParent: false)
            }
            parent.beforePseudoElement = inserted
        case "after":
            if let existing = parent.afterPseudoElement {
                removeSubtree(existing, removeFromParent: false)
            }
            parent.afterPseudoElement = inserted
        default:
            if let existing = parent.otherPseudoElements.first(where: { $0.pseudoType == descriptor.pseudoType }) {
                removeSubtree(existing, removeFromParent: true)
            }
            parent.otherPseudoElements.removeAll { $0.key == descriptor.key }
            parent.otherPseudoElements.append(inserted)
        }
        relinkChildren(of: parent)
    }

    func applyChildNodeInserted(parentKey: DOMNodeKey, previousSibling: DOMGraphPreviousSibling, node descriptor: DOMGraphNodeDescriptor) {
        guard let parent = node(forKey: parentKey) else {
            flagRejectedStructuralMutation(
                parentKey: parentKey,
                reason: "childNodeInserted missing parent key=\(keySummary(parentKey)) nodeKey=\(keySummary(descriptor.key))"
            )
            return
        }

        if case let .unrequested(count) = parent.regularChildState {
            if let existing = node(forKey: descriptor.key) {
                removeSubtree(existing, removeFromParent: true)
            }
            parent.regularChildState = .unrequested(count: max(0, count) + 1)
            relinkChildren(of: parent)
            return
        }

        let inserted = buildSubtree(from: descriptor, parent: parent)
        parent.regularChildren.removeAll { $0.key == descriptor.key }

        let insertionIndex: Int
        switch previousSibling {
        case .firstChild:
            insertionIndex = 0
        case .missing:
            insertionIndex = parent.regularChildren.count
        case let .node(previousKey):
            if let previousNode = node(forKey: previousKey),
               let previousIndex = parent.regularChildren.firstIndex(where: { $0 === previousNode }) {
                insertionIndex = previousIndex + 1
            } else {
                insertionIndex = parent.regularChildren.count
            }
        }

        let boundedIndex = min(max(0, insertionIndex), parent.regularChildren.count)
        parent.regularChildren.insert(inserted, at: boundedIndex)
        relinkChildren(of: parent)
    }

    func applyChildNodeRemoved(parentKey: DOMNodeKey, nodeKey: DOMNodeKey) {
        guard let parent = node(forKey: parentKey) else {
            flagRejectedStructuralMutation(
                parentKey: parentKey,
                reason: "childNodeRemoved missing parent key=\(keySummary(parentKey)) nodeKey=\(keySummary(nodeKey))"
            )
            return
        }

        if let (removed, _) = detachChild(key: nodeKey, from: parent) {
            relinkChildren(of: parent)
            removeSubtree(removed, removeFromParent: false)
            return
        }

        if case let .unrequested(count) = parent.regularChildState {
            parent.regularChildState = .unrequested(count: max(0, count - 1))
            relinkChildren(of: parent)
            return
        }

        if let node = node(forKey: nodeKey) {
            removeSubtree(node, removeFromParent: true)
        }
    }

    func applyAttributeModified(
        nodeKey: DOMNodeKey,
        name: String,
        value: String,
        layoutFlags: [String]?,
        isRendered: Bool?
    ) {
        guard let node = node(forKey: nodeKey) else {
            return
        }

        _ = setAttributeValue(on: node, name: name, value: value)
        applyLayout(into: node, layoutFlags: layoutFlags, isRendered: isRendered)
    }

    func applyAttributeRemoved(
        nodeKey: DOMNodeKey,
        name: String,
        layoutFlags: [String]?,
        isRendered: Bool?
    ) {
        guard let node = node(forKey: nodeKey) else {
            return
        }

        _ = removeAttributeValue(on: node, name: name)
        applyLayout(into: node, layoutFlags: layoutFlags, isRendered: isRendered)
    }

    func applyCharacterDataModified(
        nodeKey: DOMNodeKey,
        value: String,
        layoutFlags: [String]?,
        isRendered: Bool?
    ) {
        guard let node = node(forKey: nodeKey) else {
            return
        }

        node.nodeValue = value
        applyLayout(into: node, layoutFlags: layoutFlags, isRendered: isRendered)
    }

    func applyChildNodeCountUpdated(
        nodeKey: DOMNodeKey,
        childCount: Int,
        layoutFlags: [String]?,
        isRendered: Bool?
    ) {
        guard let node = node(forKey: nodeKey) else {
            return
        }

        if case .unrequested = node.regularChildState {
            node.regularChildState = .unrequested(count: childCount)
        }
        applyLayout(into: node, layoutFlags: layoutFlags, isRendered: isRendered)
    }

    func applySetChildNodes(parentKey: DOMNodeKey, nodes: [DOMGraphNodeDescriptor]) {
        guard let parent = node(forKey: parentKey) else {
            flagRejectedStructuralMutation(
                parentKey: parentKey,
                reason: "setChildNodes missing parent key=\(keySummary(parentKey)) childCount=\(nodes.count)"
            )
            return
        }

        // Match WebInspectorUI.DOMNode._setChildrenPayload: iframe/frame owners that already
        // materialized a contentDocument ignore subsequent setChildNodes payloads on the owner.
        if preservesEmbeddedContentDocumentChildren(parent) {
            return
        }

        let previousChildren = parent.regularChildren
        var nextChildren: [DOMNodeModel] = []
        nextChildren.reserveCapacity(nodes.count)

        for node in nodes {
            nextChildren.append(buildSubtree(from: node, parent: parent))
        }

        let retainedObjectIDs = Set(nextChildren.map(ObjectIdentifier.init))
        for previous in previousChildren where !retainedObjectIDs.contains(ObjectIdentifier(previous)) {
            removeSubtree(previous, removeFromParent: false)
        }

        parent.regularChildren = nextChildren
        relinkChildren(of: parent)
    }

    func applySetDetachedRoots(_ nodes: [DOMGraphNodeDescriptor]) {
        for descriptor in nodes {
            if let existingRoot = detachedRoots.first(where: { $0.key == descriptor.key }) {
                removeSubtree(existingRoot, removeFromParent: false)
            }
            detachedRoots.append(buildSubtree(from: descriptor, parent: nil))
        }
    }

    func attachFrameDocument(ownerKey: DOMNodeKey, documentRoot descriptor: DOMGraphNodeDescriptor) {
        guard let owner = node(forKey: ownerKey) else {
            flagRejectedStructuralMutation(
                parentKey: ownerKey,
                reason: "attachFrameDocument missing owner key=\(keySummary(ownerKey)) rootKey=\(keySummary(descriptor.key))"
            )
            return
        }
        if let previousDocument = owner.contentDocument {
            removeSubtree(previousDocument, removeFromParent: false)
        }
        removeExistingNodeBeforeSpecialInsert(key: descriptor.key)
        owner.contentDocument = buildSubtree(from: descriptor, parent: owner)
        relinkChildren(of: owner)
    }

    func applyLayout(into node: DOMNodeModel, layoutFlags: [String]?, isRendered: Bool?) {
        if let layoutFlags {
            node.layoutFlags = layoutFlags
        }
        if let isRendered {
            node.isRendered = isRendered
        }
    }

    func removeSubtree(_ root: DOMNodeModel, removeFromParent: Bool, decrementParentChildCount: Bool = true) {
        if removeFromParent, let parent = root.parent {
            _ = detachChild(root, from: parent)
            relinkChildren(of: parent)
        }

        for child in root.ownedChildren {
            removeSubtree(child, removeFromParent: false)
        }

        if selectedNode === root {
            logSelectionDiagnostics(
                "removeSubtree cleared selected root",
                previous: selectedNode,
                next: nil
            )
            selectedNode = nil
            projectionRevision &+= 1
            selectedNodeDetailRevision &+= 1
        }
        if rootNode === root {
            rootNode = nil
        }
        detachedRoots.removeAll { $0 === root }

        root.regularChildState = .loaded([])
        root.contentDocument = nil
        root.shadowRoots = []
        root.templateContent = nil
        root.beforePseudoElement = nil
        root.otherPseudoElements = []
        root.afterPseudoElement = nil
        root.parent = nil
        root.previousSibling = nil
        root.nextSibling = nil
        removeNode(root)
    }

    func flagMirrorInvariantViolation(_ reason: String) {
        guard mirrorInvariantViolationReason == nil else {
            return
        }
        mirrorInvariantViolationReason = reason
    }

    func flagRejectedStructuralMutation(parentKey: DOMNodeKey, reason: String) {
        rejectedStructuralMutationParentKeys.insert(parentKey)
    }

    func reconcileSelectedNode() {
        guard let currentSelection = selectedNode else {
            return
        }
        guard let resolvedNode = nodesByKey[currentSelection.key] else {
            logSelectionDiagnostics(
                "reconcileSelectedNode dropped missing selection",
                previous: currentSelection,
                next: nil
            )
            selectedNode = nil
            projectionRevision &+= 1
            selectedNodeDetailRevision &+= 1
            return
        }
        guard isNodeAttachedToPrimaryTree(resolvedNode) else {
            logSelectionDiagnostics(
                "reconcileSelectedNode dropped detached selection",
                previous: currentSelection,
                next: nil
            )
            selectedNode = nil
            projectionRevision &+= 1
            selectedNodeDetailRevision &+= 1
            return
        }
        if resolvedNode !== currentSelection {
            logSelectionDiagnostics(
                "reconcileSelectedNode rebound selection",
                previous: currentSelection,
                next: resolvedNode
            )
            selectedNode = resolvedNode
            projectionRevision &+= 1
            selectedNodeDetailRevision &+= 1
        }
    }
}

private extension DOMDocumentModel {
    func logSelectionTransitionIfNeeded(
        action: String,
        previous: DOMNodeModel?,
        next: DOMNodeModel?,
        extra: String? = nil
    ) {
        guard selectionNodeSummary(previous) != selectionNodeSummary(next) else {
            return
        }
        logSelectionDiagnostics(action, previous: previous, next: next, extra: extra)
    }

    func logSelectionDiagnostics(
        _ action: String,
        previous: DOMNodeModel?,
        next: DOMNodeModel?,
        extra: String? = nil
    ) {
        let extraPart = extra.map { " \($0)" } ?? ""
        let previousSummary = self.selectionNodeSummary(previous)
        let nextSummary = self.selectionNodeSummary(next)
        let identitySummary = self.compactDocumentIdentity(self.documentIdentity)
        domDocumentLogger.notice(
            "\(action, privacy: .public) previous=\(previousSummary, privacy: .public) next=\(nextSummary, privacy: .public)\(extraPart, privacy: .public) documentIdentity=\(identitySummary, privacy: .public)"
        )
    }

    func logDocumentDiagnostics(_ action: String, extra: String) {
        domDocumentLogger.notice(
            "\(action, privacy: .public) \(extra, privacy: .public)"
        )
    }

    func selectionNodeSummary(_ node: DOMNodeModel?) -> String {
        guard let node else {
            return "nil"
        }
        let nodeName = node.localName.isEmpty ? node.nodeName : node.localName
        return "\(nodeName)#key=\(keySummary(node.key))#children=\(node.children.count)/\(node.regularChildCount)#selector=\(node.selectorPath)"
    }

    func keySummary(_ key: DOMNodeKey) -> String {
        "\(key.targetIdentifier):\(key.nodeID)"
    }

    func compactDocumentIdentity(_ documentIdentity: UUID) -> String {
        String(documentIdentity.uuidString.prefix(8))
    }

    func topmostAncestor(of node: DOMNodeModel) -> DOMNodeModel {
        var topmostAncestor = node
        while let parent = topmostAncestor.parent {
            topmostAncestor = parent
        }
        return topmostAncestor
    }

    func isNodeAttachedToPrimaryTree(_ node: DOMNodeModel) -> Bool {
        topmostAncestor(of: node) === rootNode
    }

    func resolveAttachedSelectionNode(
        key: DOMNodeKey
    ) -> DOMNodeModel? {
        if let node = node(forKey: key), isNodeAttachedToPrimaryTree(node) {
            return node
        }
        return nil
    }

    func preservesEmbeddedContentDocumentChildren(_ node: DOMNodeModel) -> Bool {
        guard isFrameOwnerNode(node) else {
            return false
        }
        return node.contentDocument != nil
    }

    func isDocumentNode(_ node: DOMNodeModel) -> Bool {
        inferredNodeType(for: node) == .document
    }

    func isFrameOwnerNode(_ node: DOMNodeModel) -> Bool {
        guard inferredNodeType(for: node) == .element else {
            return false
        }
        let nodeName = (node.localName.isEmpty ? node.nodeName : node.localName).lowercased()
        return nodeName == "iframe" || nodeName == "frame"
    }

    func inferredNodeType(for node: DOMNodeModel) -> DOMNodeType {
        if node.nodeType != .unknown {
            return node.nodeType
        }

        switch (node.localName.isEmpty ? node.nodeName : node.localName).lowercased() {
        case "#document":
            return .document
        case "!doctype", "#doctype":
            return .documentType
        case "#text":
            return .text
        case "#comment":
            return .comment
        case "#cdata-section":
            return .cdataSection
        case "#document-fragment", "#shadow-root":
            return .documentFragment
        case let name where !name.isEmpty && !name.hasPrefix("#"):
            return .element
        default:
            return .unknown
        }
    }
}
