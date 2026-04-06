import Foundation
import Observation

@available(*, deprecated, renamed: "DOMDocumentModel", message: "Use DOMDocumentModel.")
public typealias DOMDocumentStore = DOMDocumentModel

@MainActor
@Observable
public final class DOMDocumentModel {
    public private(set) var rootNode: DOMNodeModel?
    public private(set) var selectedNode: DOMNodeModel?
    public private(set) var errorMessage: String?

    @available(*, deprecated, renamed: "rootNode", message: "Use rootNode.")
    public var rootEntry: DOMNodeModel? {
        rootNode
    }

    @available(*, deprecated, renamed: "selectedNode", message: "Use selectedNode.")
    public var selectedEntry: DOMNodeModel? {
        selectedNode
    }

    package private(set) var documentIdentity = UUID()

    private var nodesByLocalID: [UInt64: DOMNodeModel] = [:]

    public init() {}

    package func setErrorMessage(_ message: String?) {
        guard errorMessage != message else {
            return
        }
        errorMessage = message
    }

    package func clearSelection() {
        selectedNode = nil
    }

    package func clearDocument(isFreshDocument: Bool = true) {
        if isFreshDocument {
            documentIdentity = UUID()
        }
        clearContents()
    }

    package func replaceDocument(
        with snapshot: DOMGraphSnapshot,
        isFreshDocument: Bool = true
    ) {
        if isFreshDocument {
            documentIdentity = UUID()
        }
        let previousSelectedLocalID = selectedLocalID
        let nextSelectedLocalID = snapshot.selectedLocalID ?? previousSelectedLocalID
        replaceContents(selectedLocalID: nextSelectedLocalID) {
            rootNode = buildSubtree(from: snapshot.root, parent: nil)
        }
    }

    package func applyMutationBundle(_ bundle: DOMGraphMutationBundle) {
        guard !bundle.events.isEmpty else {
            return
        }

        let previousSelectedLocalID = selectedLocalID
        for event in bundle.events {
            switch event {
            case let .childNodeInserted(parentLocalID, previousLocalID, node):
                applyChildNodeInserted(parentLocalID: parentLocalID, previousLocalID: previousLocalID, node: node)
            case let .childNodeRemoved(parentLocalID, nodeLocalID):
                applyChildNodeRemoved(parentLocalID: parentLocalID, nodeLocalID: nodeLocalID)
            case let .attributeModified(nodeLocalID, name, value, layoutFlags, isRendered):
                applyAttributeModified(
                    nodeLocalID: nodeLocalID,
                    name: name,
                    value: value,
                    layoutFlags: layoutFlags,
                    isRendered: isRendered
                )
            case let .attributeRemoved(nodeLocalID, name, layoutFlags, isRendered):
                applyAttributeRemoved(
                    nodeLocalID: nodeLocalID,
                    name: name,
                    layoutFlags: layoutFlags,
                    isRendered: isRendered
                )
            case let .characterDataModified(nodeLocalID, value, layoutFlags, isRendered):
                applyCharacterDataModified(
                    nodeLocalID: nodeLocalID,
                    value: value,
                    layoutFlags: layoutFlags,
                    isRendered: isRendered
                )
            case let .childNodeCountUpdated(nodeLocalID, childCount, layoutFlags, isRendered):
                applyChildNodeCountUpdated(
                    nodeLocalID: nodeLocalID,
                    childCount: childCount,
                    layoutFlags: layoutFlags,
                    isRendered: isRendered
                )
            case let .setChildNodes(parentLocalID, nodes):
                applySetChildNodes(parentLocalID: parentLocalID, nodes: nodes)
            case let .replaceSubtree(root):
                applyReplaceSubtree(root)
            case .documentUpdated:
                return
            }
        }

        reconcileSelectedNode()
        if selectedNode == nil, let previousSelectedLocalID {
            selectedNode = node(forLocalID: previousSelectedLocalID)
        }
    }

    package func applySelectionSnapshot(_ payload: DOMSelectionSnapshotPayload?) {
        if let previousSelectedNode = selectedNode, payload?.localID == nil {
            previousSelectedNode.clearSelectionProjectionState()
        }
        guard let payload, let localID = payload.localID else {
            selectedNode = nil
            return
        }

        let existingNode = node(forLocalID: localID)
        let node = existingNode ?? makePlaceholderNode(
            localID: localID,
            backendNodeID: payload.backendNodeID,
            synthesizeBackendNodeID: false
        )
        if let payloadBackendNodeID = payload.backendNodeID,
           node.backendNodeID != payloadBackendNodeID {
            node.backendNodeID = payloadBackendNodeID
        }
        node.preview = payload.preview
        node.path = payload.path
        if let selectorPath = payload.selectorPath {
            node.selectorPath = selectorPath
        }
        node.styleRevision = payload.styleRevision
        replaceAttributes(
            on: node,
            with: normalizeAttributes(payload.attributes, backendNodeID: node.backendNodeID)
        )
        selectedNode = node
    }

    package func applySelectorPath(_ payload: DOMSelectorPathPayload) {
        guard
            let localID = payload.localID,
            let node = node(forLocalID: localID),
            selectedNode === node
        else {
            return
        }

        if node.selectorPath != payload.selectorPath {
            node.selectorPath = payload.selectorPath
        }
    }

    package func applySelectorPath(_ selectorPath: String, for node: DOMNodeModel) {
        guard selectedNode === node, contains(node) else {
            return
        }
        if node.selectorPath != selectorPath {
            node.selectorPath = selectorPath
        }
    }

    package func updateSelectedAttribute(name: String, value: String) {
        guard let node = selectedNode, contains(node) else {
            return
        }
        _ = setAttributeValue(on: node, name: name, value: value)
    }

    package func removeSelectedAttribute(name: String) {
        guard let node = selectedNode, contains(node) else {
            return
        }
        _ = removeAttributeValue(on: node, name: name)
    }

    package func containsEntry(localID: UInt64, backendNodeID: Int?) -> Bool {
        guard let node = node(forLocalID: localID) else {
            return false
        }
        return backendNodeID == nil || node.backendNodeID == backendNodeID
    }

    package func node(id: DOMNodeModel.ID) -> DOMNodeModel? {
        guard id.documentIdentity == documentIdentity else {
            return nil
        }
        return node(forLocalID: id.localID)
    }

    package func node(backendNodeID: Int) -> DOMNodeModel? {
        nodesByLocalID.values.first(where: { $0.backendNodeID == backendNodeID })
    }

    package func node(localID: UInt64) -> DOMNodeModel? {
        node(forLocalID: localID)
    }

    package func contains(_ node: DOMNodeModel) -> Bool {
        nodesByLocalID[node.localID] === node
    }

    package func attributeValue(
        name: String,
        localID: UInt64,
        backendNodeID: Int?
    ) -> String? {
        guard let node = node(forLocalID: localID) else {
            return nil
        }
        guard backendNodeID == nil || node.backendNodeID == backendNodeID else {
            return nil
        }
        return node.attributes.first(where: { $0.name == name })?.value
    }

    @discardableResult
    package func updateAttribute(
        name: String,
        value: String,
        localID: UInt64,
        backendNodeID: Int?
    ) -> Bool {
        guard let node = node(forLocalID: localID) else {
            return false
        }
        guard backendNodeID == nil || node.backendNodeID == backendNodeID else {
            return false
        }
        return setAttributeValue(on: node, name: name, value: value)
    }

    @discardableResult
    package func removeAttribute(
        name: String,
        localID: UInt64,
        backendNodeID: Int?
    ) -> Bool {
        guard let node = node(forLocalID: localID) else {
            return false
        }
        guard backendNodeID == nil || node.backendNodeID == backendNodeID else {
            return false
        }
        return removeAttributeValue(on: node, name: name)
    }

    package var selectedLocalID: UInt64? {
        selectedNode?.localID
    }

    package func removeNode(id: DOMNodeModel.ID) {
        guard let node = node(id: id) else {
            return
        }
        removeSubtree(node, removeFromParent: true)
    }
}

private extension DOMDocumentModel {
    func replaceContents(
        selectedLocalID: UInt64?,
        build: () -> Void
    ) {
        clearContents()
        build()
        if let selectedLocalID {
            selectedNode = node(forLocalID: selectedLocalID)
        }
        reconcileSelectedNode()
    }

    func clearContents() {
        nodesByLocalID.removeAll(keepingCapacity: true)
        rootNode = nil
        selectedNode = nil
        errorMessage = nil
    }

    func node(forLocalID localID: UInt64) -> DOMNodeModel? {
        nodesByLocalID[localID]
    }

    func insert(_ node: DOMNodeModel, for localID: UInt64) {
        nodesByLocalID[localID] = node
    }

    func removeNode(_ node: DOMNodeModel) {
        guard nodesByLocalID[node.localID] === node else {
            return
        }
        nodesByLocalID.removeValue(forKey: node.localID)
    }

    func normalizeAttributes(_ attributes: [DOMAttribute], backendNodeID: Int?) -> [DOMAttribute] {
        attributes.map {
            DOMAttribute(
                nodeId: $0.nodeId ?? backendNodeID,
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
                return true
            }
            node.attributes[index].value = value
            return true
        }
        node.attributes.append(DOMAttribute(nodeId: node.backendNodeID, name: name, value: value))
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

    func replaceAttributes(
        on node: DOMNodeModel,
        with newAttributes: [DOMAttribute]
    ) {
        guard node.attributes != newAttributes else {
            return
        }
        node.attributes = newAttributes
    }

    func makePlaceholderNode(
        localID: UInt64,
        backendNodeID: Int? = nil,
        synthesizeBackendNodeID: Bool = true
    ) -> DOMNodeModel {
        let resolvedBackendNodeID: Int?
        if let backendNodeID {
            resolvedBackendNodeID = backendNodeID
        } else if synthesizeBackendNodeID, localID <= UInt64(Int.max) {
            resolvedBackendNodeID = Int(localID)
        } else {
            resolvedBackendNodeID = nil
        }
        let node = DOMNodeModel(
            id: .init(documentIdentity: documentIdentity, localID: localID),
            backendNodeID: resolvedBackendNodeID,
            nodeType: 1,
            nodeName: "",
            localName: "",
            nodeValue: "",
            attributes: [],
            childCount: 0
        )
        insert(node, for: localID)
        return node
    }

    @discardableResult
    func buildSubtree(from descriptor: DOMGraphNodeDescriptor, parent: DOMNodeModel?) -> DOMNodeModel {
        if let existing = node(forLocalID: descriptor.localID) {
            removeSubtree(existing, removeFromParent: true)
        }

        let node = DOMNodeModel(
            id: .init(documentIdentity: documentIdentity, localID: descriptor.localID),
            backendNodeID: descriptor.backendNodeID,
            nodeType: descriptor.nodeType,
            nodeName: descriptor.nodeName,
            localName: descriptor.localName,
            nodeValue: descriptor.nodeValue,
            attributes: normalizeAttributes(descriptor.attributes, backendNodeID: descriptor.backendNodeID),
            childCount: max(descriptor.childCount, descriptor.children.count),
            layoutFlags: descriptor.layoutFlags,
            isRendered: descriptor.isRendered
        )
        node.parent = parent
        insert(node, for: descriptor.localID)

        var children: [DOMNodeModel] = []
        children.reserveCapacity(descriptor.children.count)
        for childDescriptor in descriptor.children {
            let child = buildSubtree(from: childDescriptor, parent: node)
            children.append(child)
        }
        node.children = children
        relinkChildren(of: node)

        return node
    }

    func relinkChildren(of parent: DOMNodeModel) {
        for (index, child) in parent.children.enumerated() {
            child.parent = parent
            child.previousSibling = index > 0 ? parent.children[index - 1] : nil
            child.nextSibling = index + 1 < parent.children.count ? parent.children[index + 1] : nil
        }
    }

    func applyChildNodeInserted(parentLocalID: UInt64, previousLocalID: UInt64?, node descriptor: DOMGraphNodeDescriptor) {
        guard let parent = node(forLocalID: parentLocalID) else {
            return
        }

        let hadLoadedChild = parent.children.contains { $0.localID == descriptor.localID }
        let previousChildCount = max(parent.childCount, parent.children.count)
        let inserted = buildSubtree(from: descriptor, parent: parent)
        parent.children.removeAll { $0.localID == descriptor.localID }

        let insertionIndex: Int
        if previousLocalID == 0 {
            insertionIndex = 0
        } else if let previousLocalID,
                  let previousNode = node(forLocalID: previousLocalID),
                  let previousIndex = parent.children.firstIndex(where: { $0 === previousNode }) {
            insertionIndex = previousIndex + 1
        } else {
            insertionIndex = parent.children.count
        }

        let boundedIndex = min(max(0, insertionIndex), parent.children.count)
        parent.children.insert(inserted, at: boundedIndex)
        if hadLoadedChild {
            parent.childCount = max(previousChildCount, parent.children.count)
        } else {
            parent.childCount = max(previousChildCount + 1, parent.children.count)
        }
        relinkChildren(of: parent)
    }

    func applyChildNodeRemoved(parentLocalID: UInt64, nodeLocalID: UInt64) {
        guard let parent = node(forLocalID: parentLocalID) else {
            return
        }

        if let index = parent.children.firstIndex(where: { $0.localID == nodeLocalID }) {
            let removed = parent.children.remove(at: index)
            parent.childCount = max(parent.children.count, parent.childCount - 1)
            relinkChildren(of: parent)
            removeSubtree(removed, removeFromParent: false)
            return
        }

        if let node = node(forLocalID: nodeLocalID) {
            removeSubtree(node, removeFromParent: true)
        }
    }

    func applyAttributeModified(
        nodeLocalID: UInt64,
        name: String,
        value: String,
        layoutFlags: [String]?,
        isRendered: Bool?
    ) {
        guard let node = node(forLocalID: nodeLocalID) else {
            return
        }

        _ = setAttributeValue(on: node, name: name, value: value)
        applyLayout(into: node, layoutFlags: layoutFlags, isRendered: isRendered)
    }

    func applyAttributeRemoved(
        nodeLocalID: UInt64,
        name: String,
        layoutFlags: [String]?,
        isRendered: Bool?
    ) {
        guard let node = node(forLocalID: nodeLocalID) else {
            return
        }

        _ = removeAttributeValue(on: node, name: name)
        applyLayout(into: node, layoutFlags: layoutFlags, isRendered: isRendered)
    }

    func applyCharacterDataModified(
        nodeLocalID: UInt64,
        value: String,
        layoutFlags: [String]?,
        isRendered: Bool?
    ) {
        guard let node = node(forLocalID: nodeLocalID) else {
            return
        }

        node.nodeValue = value
        applyLayout(into: node, layoutFlags: layoutFlags, isRendered: isRendered)
    }

    func applyChildNodeCountUpdated(
        nodeLocalID: UInt64,
        childCount: Int,
        layoutFlags: [String]?,
        isRendered: Bool?
    ) {
        guard let node = node(forLocalID: nodeLocalID) else {
            return
        }

        node.childCount = max(0, childCount)
        applyLayout(into: node, layoutFlags: layoutFlags, isRendered: isRendered)
    }

    func applySetChildNodes(parentLocalID: UInt64, nodes: [DOMGraphNodeDescriptor]) {
        let parent: DOMNodeModel
        if let existingParent = node(forLocalID: parentLocalID) {
            parent = existingParent
        } else if rootNode == nil {
            let placeholderRoot = makePlaceholderNode(localID: parentLocalID)
            rootNode = placeholderRoot
            parent = placeholderRoot
        } else {
            return
        }

        let previousChildren = parent.children
        var nextChildren: [DOMNodeModel] = []
        nextChildren.reserveCapacity(nodes.count)

        for node in nodes {
            nextChildren.append(buildSubtree(from: node, parent: parent))
        }

        let retainedObjectIDs = Set(nextChildren.map(ObjectIdentifier.init))
        for previous in previousChildren where !retainedObjectIDs.contains(ObjectIdentifier(previous)) {
            removeSubtree(previous, removeFromParent: false)
        }

        parent.children = nextChildren
        parent.childCount = max(parent.childCount, nextChildren.count)
        relinkChildren(of: parent)
    }

    func applyReplaceSubtree(_ root: DOMGraphNodeDescriptor) {
        if rootNode == nil {
            rootNode = buildSubtree(from: root, parent: nil)
            return
        }

        let existingNode = node(forLocalID: root.localID)
            ?? root.backendNodeID.flatMap { node(backendNodeID: $0) }
        if let existing = existingNode {
            let parent = existing.parent
            let previousIndex = parent?.children.firstIndex(where: { $0 === existing })
            let previousParentChildCount = parent.map { max($0.childCount, $0.children.count) }
            let isReplacingRoot = rootNode === existing
            removeSubtree(existing, removeFromParent: true, decrementParentChildCount: false)

            let replacement = buildSubtree(from: root, parent: parent)
            if let parent {
                let insertionIndex = min(previousIndex ?? parent.children.count, parent.children.count)
                parent.children.insert(replacement, at: insertionIndex)
                if let previousParentChildCount {
                    parent.childCount = max(previousParentChildCount, parent.children.count)
                } else {
                    parent.childCount = max(parent.childCount, parent.children.count)
                }
                relinkChildren(of: parent)
            } else if isReplacingRoot {
                rootNode = replacement
            }
        }
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
            let previousLoadedChildCount = parent.children.count
            parent.children.removeAll { $0 === root }
            let removedLoadedChild = parent.children.count < previousLoadedChildCount
            if decrementParentChildCount, removedLoadedChild {
                parent.childCount = max(parent.children.count, parent.childCount - 1)
            } else {
                parent.childCount = max(parent.childCount, parent.children.count)
            }
            relinkChildren(of: parent)
        }

        for child in root.children {
            removeSubtree(child, removeFromParent: false)
        }

        if selectedNode === root {
            selectedNode = nil
        }
        if rootNode === root {
            rootNode = nil
        }

        root.children = []
        root.parent = nil
        root.previousSibling = nil
        root.nextSibling = nil
        removeNode(root)
    }

    func reconcileSelectedNode() {
        guard let currentSelection = selectedNode else {
            return
        }
        guard let resolvedNode = nodesByLocalID[currentSelection.localID] else {
            selectedNode = nil
            return
        }
        if resolvedNode !== currentSelection {
            selectedNode = resolvedNode
        }
    }
}
