import Foundation
import Observation
import OSLog

private let domDocumentLogger = Logger(subsystem: "WebInspectorKit", category: "DOMDocumentModel")

@MainActor
@Observable
public final class DOMDocumentModel {
    public private(set) var rootNode: DOMNodeModel?
    public private(set) var selectedNode: DOMNodeModel?
    public private(set) var errorMessage: String?

    package private(set) var documentIdentity = UUID()
    package private(set) var projectionRevision: UInt64 = 0
    package private(set) var mirrorInvariantViolationReason: String?
    package private(set) var rejectedStructuralMutationParentLocalIDs: Set<UInt64> = []

    private var nodesByLocalID: [UInt64: DOMNodeModel] = [:]
    private var detachedRoots: [DOMNodeModel] = []

    public init() {}

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

    package func consumeRejectedStructuralMutationParentLocalIDs() -> Set<UInt64> {
        defer { rejectedStructuralMutationParentLocalIDs.removeAll(keepingCapacity: true) }
        return rejectedStructuralMutationParentLocalIDs
    }

    package func clearSelection() {
        let previousSelectedNode = selectedNode
        selectedNode = nil
        projectionRevision &+= 1
        guard previousSelectedNode != nil else {
            return
        }
        logSelectionDiagnostics(
            "clearSelection",
            previous: previousSelectedNode,
            next: selectedNode
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
        projectionRevision &+= 1
        guard previousSelectedNode != nil || previousRootNode != nil else {
            return
        }
        logDocumentDiagnostics(
            "clearDocument",
            extra: "isFreshDocument=\(isFreshDocument) previousDocumentIdentity=\(compactDocumentIdentity(previousDocumentIdentity)) nextDocumentIdentity=\(compactDocumentIdentity(documentIdentity)) previousRoot=\(selectionNodeSummary(previousRootNode))"
        )
    }

    package func replaceDocument(
        with snapshot: DOMGraphSnapshot,
        isFreshDocument: Bool = true
    ) {
        if isFreshDocument {
            documentIdentity = UUID()
        }
        let previousSelectedLocalID = selectedLocalID
        let previousSelectedStableBackendNodeID = stableBackendNodeID(for: selectedNode)
        let nextSelectedLocalID = snapshot.selectedLocalID ?? previousSelectedLocalID
        replaceContents(
            selectedLocalID: nextSelectedLocalID,
            selectedStableBackendNodeID: previousSelectedStableBackendNodeID
        ) {
            rootNode = buildSubtree(from: snapshot.root, parent: nil)
        }
        projectionRevision &+= 1
    }

    package func applyMutationBundle(_ bundle: DOMGraphMutationBundle) {
        guard !bundle.events.isEmpty else {
            return
        }

        let previousSelectedLocalID = selectedLocalID
        let previousSelectedNode = selectedNode
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
            case let .setDetachedRoots(nodes):
                applySetDetachedRoots(nodes)
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
        if selectedNode == nil,
           let stableBackendNodeID = stableBackendNodeID(for: previousSelectedNode) {
            selectedNode = node(stableBackendNodeID: stableBackendNodeID)
        }
        projectionRevision &+= 1
        logSelectionTransitionIfNeeded(
            action: "applyMutationBundle",
            previous: previousSelectedNode,
            next: selectedNode,
            extra: "eventCount=\(bundle.events.count)"
        )
    }

    package func applySelectionSnapshot(_ payload: DOMSelectionSnapshotPayload?) {
        let previousSelectedNode = selectedNode
        if let previousSelectedNode = selectedNode, payload?.localID == nil {
            previousSelectedNode.clearSelectionProjectionState()
        }
        guard let payload, let localID = payload.localID else {
            selectedNode = nil
            projectionRevision &+= 1
            logSelectionTransitionIfNeeded(
                action: "applySelectionSnapshot",
                previous: previousSelectedNode,
                next: selectedNode,
                extra: "payload=nil"
            )
            return
        }

        guard let node = resolveAttachedSelectionNode(
            localID: localID,
            backendNodeID: payload.backendNodeID,
            backendNodeIDIsStable: payload.backendNodeIDIsStable
        ) else {
            logSelectionDiagnostics(
                "applySelectionSnapshot ignored unknown or detached selection",
                previous: previousSelectedNode,
                next: previousSelectedNode,
                extra: "payloadLocalID=\(localID) backendNodeID=\(payload.backendNodeID.map(String.init) ?? "nil") selector=\(payload.selectorPath ?? "nil")"
            )
            return
        }
        if let payloadBackendNodeID = payload.backendNodeID,
           node.backendNodeID != payloadBackendNodeID {
            node.backendNodeID = payloadBackendNodeID
        }
        if let payloadBackendNodeID = payload.backendNodeID,
           node.backendNodeIDIsStable != payload.backendNodeIDIsStable,
           node.backendNodeID == payloadBackendNodeID {
            node.backendNodeIDIsStable = payload.backendNodeIDIsStable
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
        projectionRevision &+= 1
        logSelectionTransitionIfNeeded(
            action: "applySelectionSnapshot",
            previous: previousSelectedNode,
            next: selectedNode,
            extra: "payloadLocalID=\(localID) backendNodeID=\(payload.backendNodeID.map(String.init) ?? "nil") selector=\(payload.selectorPath ?? "nil")"
        )
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

    package func node(stableBackendNodeID: Int) -> DOMNodeModel? {
        nodesByLocalID.values.first {
            $0.backendNodeIDIsStable && $0.backendNodeID == stableBackendNodeID
        }
    }

    package func node(localID: UInt64) -> DOMNodeModel? {
        node(forLocalID: localID)
    }

    package func topLevelRoots() -> [DOMNodeModel] {
        rootNode.map { [$0] } ?? []
    }

    package func detachedRootsForDiagnostics() -> [DOMNodeModel] {
        detachedRoots
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
        selectedStableBackendNodeID: Int? = nil,
        build: () -> Void
    ) {
        clearContents()
        build()
        if let selectedLocalID {
            selectedNode = node(forLocalID: selectedLocalID)
        }
        if selectedNode == nil,
           let selectedStableBackendNodeID {
            selectedNode = node(stableBackendNodeID: selectedStableBackendNodeID)
        }
        reconcileSelectedNode()
    }

    func clearContents() {
        nodesByLocalID.removeAll(keepingCapacity: true)
        rootNode = nil
        detachedRoots.removeAll(keepingCapacity: true)
        selectedNode = nil
        errorMessage = nil
        mirrorInvariantViolationReason = nil
        rejectedStructuralMutationParentLocalIDs.removeAll(keepingCapacity: true)
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

    @discardableResult
    func buildSubtree(from descriptor: DOMGraphNodeDescriptor, parent: DOMNodeModel?) -> DOMNodeModel {
        if let existing = node(forLocalID: descriptor.localID) {
            removeSubtree(existing, removeFromParent: true)
        }

        let node = DOMNodeModel(
            id: .init(documentIdentity: documentIdentity, localID: descriptor.localID),
            backendNodeID: descriptor.backendNodeID,
            backendNodeIDIsStable: descriptor.backendNodeIDIsStable,
            frameID: descriptor.frameID,
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
            flagRejectedStructuralMutation(
                parentLocalID: parentLocalID,
                reason: "childNodeInserted missing parent localID=\(parentLocalID) nodeLocalID=\(descriptor.localID)"
            )
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
            flagRejectedStructuralMutation(
                parentLocalID: parentLocalID,
                reason: "childNodeRemoved missing parent localID=\(parentLocalID) nodeLocalID=\(nodeLocalID)"
            )
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
        guard let parent = node(forLocalID: parentLocalID) else {
            flagRejectedStructuralMutation(
                parentLocalID: parentLocalID,
                reason: "setChildNodes missing parent localID=\(parentLocalID) childCount=\(nodes.count)"
            )
            return
        }

        // Match WebInspectorUI.DOMNode._setChildrenPayload: iframe/frame owners that already
        // materialized a contentDocument ignore subsequent setChildNodes payloads on the owner.
        if preservesEmbeddedContentDocumentChildren(parent) {
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

    func applySetDetachedRoots(_ nodes: [DOMGraphNodeDescriptor]) {
        for descriptor in nodes {
            if let existingRoot = detachedRoots.first(where: { $0.localID == descriptor.localID }) {
                removeSubtree(existingRoot, removeFromParent: false)
            }
            detachedRoots.append(buildSubtree(from: descriptor, parent: nil))
        }
    }

    func applyReplaceSubtree(_ root: DOMGraphNodeDescriptor) {
        if rootNode == nil {
            rootNode = buildSubtree(from: root, parent: nil)
            return
        }

        let existingNode = node(forLocalID: root.localID)
            ?? (root.backendNodeIDIsStable
                    ? root.backendNodeID.flatMap {
                        node(stableBackendNodeID: $0)
                    }
                    : nil)
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
            } else {
                detachedRoots.append(replacement)
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
            logSelectionDiagnostics(
                "removeSubtree cleared selected root",
                previous: selectedNode,
                next: nil
            )
            selectedNode = nil
            projectionRevision &+= 1
        }
        if rootNode === root {
            rootNode = nil
        }
        detachedRoots.removeAll { $0 === root }

        root.children = []
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

    func flagRejectedStructuralMutation(parentLocalID: UInt64, reason: String) {
        rejectedStructuralMutationParentLocalIDs.insert(parentLocalID)
        _ = reason
    }

    func reconcileSelectedNode() {
        guard let currentSelection = selectedNode else {
            return
        }
        guard let resolvedNode = nodesByLocalID[currentSelection.localID] else {
            logSelectionDiagnostics(
                "reconcileSelectedNode dropped missing selection",
                previous: currentSelection,
                next: nil
            )
            selectedNode = nil
            projectionRevision &+= 1
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
        return "\(nodeName)#local=\(node.localID)#backend=\(node.backendNodeID.map(String.init) ?? "nil")#children=\(node.children.count)/\(node.childCount)#selector=\(node.selectorPath)"
    }

    func compactDocumentIdentity(_ documentIdentity: UUID) -> String {
        String(documentIdentity.uuidString.prefix(8))
    }

    func stableBackendNodeID(for node: DOMNodeModel?) -> Int? {
        guard let node,
              node.backendNodeIDIsStable,
              let backendNodeID = node.backendNodeID else {
            return nil
        }
        return backendNodeID
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
        localID: UInt64,
        backendNodeID: Int?,
        backendNodeIDIsStable: Bool
    ) -> DOMNodeModel? {
        if let node = node(forLocalID: localID), isNodeAttachedToPrimaryTree(node) {
            return node
        }
        guard let backendNodeID else {
            return nil
        }
        if backendNodeIDIsStable,
           let node = node(stableBackendNodeID: backendNodeID),
           isNodeAttachedToPrimaryTree(node) {
            return node
        }
        if let node = node(backendNodeID: backendNodeID),
           isNodeAttachedToPrimaryTree(node) {
            return node
        }
        return nil
    }

    func preservesEmbeddedContentDocumentChildren(_ node: DOMNodeModel) -> Bool {
        guard isFrameOwnerNode(node) else {
            return false
        }
        return node.children.contains(where: isDocumentNode)
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
