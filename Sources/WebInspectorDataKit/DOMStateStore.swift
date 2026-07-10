import WebInspectorProxyKit

/// Owns the semantic DOM graph and every mutation that can change it.
///
/// `WebInspectorModelContext` remains the attachment and I/O coordinator. It gives
/// this store protocol payloads and applies the explicit effects returned by
/// the store. The store itself never starts transport work.
package final class DOMStateStore {
    package struct FrameDocumentLoadRequest: Equatable {
        package let targetID: WebInspectorTarget.ID
        package let reason: String
    }

    package struct Effects {
        package var statusChanged = false
        package var selectionChanged = false
        package var selectedStylesNeedRefresh = false
        package var documentReset = false
        package var shouldReloadDocument = false
        package var shouldClearPageHighlight = false
        package var inspectedNode: DOMNode?
        package var discardedStyleNode: DOMNode?
        package var frameDocumentLoadRequests: [FrameDocumentLoadRequest] = []

        package mutating func merge(_ other: Effects) {
            statusChanged = statusChanged || other.statusChanged
            selectionChanged = selectionChanged || other.selectionChanged
            selectedStylesNeedRefresh = selectedStylesNeedRefresh || other.selectedStylesNeedRefresh
            documentReset = documentReset || other.documentReset
            shouldReloadDocument = shouldReloadDocument || other.shouldReloadDocument
            shouldClearPageHighlight = shouldClearPageHighlight || other.shouldClearPageHighlight
            if let inspectedNode = other.inspectedNode {
                self.inspectedNode = inspectedNode
            }
            if let discardedStyleNode = other.discardedStyleNode {
                self.discardedStyleNode = discardedStyleNode
            }
            frameDocumentLoadRequests.append(contentsOf: other.frameDocumentLoadRequests)
        }
    }

    package private(set) var rootNode: DOMNode?
    package private(set) var selectedNode: DOMNode?
    package private(set) var isElementPickerEnabled: Bool
    package private(set) var documentEpoch: Int
    package private(set) var selectionRevision: UInt64

    private var nodesByID: [DOMNode.ID: DOMNode]
    private var frameDocumentProjectionIndex: FrameDocumentProjectionIndex
    private var treeStates: [WeakDOMTreeState]
    private var pendingInspectedNodeID: DOMNode.ID?
    private var pageHighlightDocumentEpoch: Int?
    private var editHistoryTarget: WebInspectorTarget?
    private var didInvalidateEditHistoryTarget: Bool

    package init() {
        rootNode = nil
        selectedNode = nil
        isElementPickerEnabled = false
        documentEpoch = 0
        selectionRevision = 0
        nodesByID = [:]
        frameDocumentProjectionIndex = FrameDocumentProjectionIndex()
        treeStates = []
        pendingInspectedNodeID = nil
        pageHighlightDocumentEpoch = nil
        editHistoryTarget = nil
        didInvalidateEditHistoryTarget = false
    }

    package func node(
        for id: DOMNode.ID
    ) -> DOMNode? {
        return nodesByID[id]
    }

    package func requiredNode(
        for id: DOMNode.ID
    ) throws -> DOMNode {
        guard let node = nodesByID[id] else {
            throw WebInspectorProxyError.disconnected("DOMNode is not registered in this WebInspectorModelContext.")
        }
        return node
    }

    @discardableResult
    package func registeredNode(
        _ node: DOMNode
    ) throws -> DOMNode {
        guard nodesByID[node.id] === node else {
            throw WebInspectorProxyError.disconnected("DOMNode is not registered in this WebInspectorModelContext.")
        }
        return node
    }

    package func styles(
        containing propertyID: CSSStyleProperty.ID
    ) -> CSSStyles? {
        nodesByID.values.lazy.compactMap(\.elementStyles).first {
            $0.contains(propertyID: propertyID)
        }
    }

    package func styles(
        containing ruleID: CSSStyleRule.ID
    ) -> CSSStyles? {
        nodesByID.values.lazy.compactMap(\.elementStyles).first {
            $0.contains(ruleID: ruleID)
        }
    }

    package func markAllStylesNeedsRefresh() {
        for styles in nodesByID.values.compactMap(\.elementStyles) {
            styles.markNeedsRefresh()
        }
    }

    package func select(
        _ node: DOMNode?,
        reveal: DOMRevealPolicy
    ) -> Effects {
        if let node, nodesByID[node.id] !== node {
            preconditionFailure("DOMNode is not registered in this WebInspectorModelContext.")
        }
        advanceSelectionRevision()
        pendingInspectedNodeID = nil
        selectedNode = node
        notifyDOMTreeSelectionChanged(node, reveal: reveal)
        return Effects(statusChanged: true, selectionChanged: true)
    }

    package func treeController(
        root requestedRoot: DOMNode?
    ) throws -> DOMTreeController {
        guard let root = requestedRoot ?? rootNode else {
            throw WebInspectorProxyError.disconnected("WebInspectorDataKit has no DOM root node.")
        }
        guard nodesByID[root.id] === root else {
            preconditionFailure("DOMTreeController root is not registered in this WebInspectorModelContext.")
        }

        let tree = DOMTreeState(rootNode: root, selectedNode: selectedNode)
        treeStates.append(WeakDOMTreeState(tree))
        pruneReleasedTreeStates()
        return DOMTreeController(tree: tree)
    }

    package func rootTreeController(
    ) -> DOMTreeController {
        let tree = DOMTreeState(rootNode: rootNode, selectedNode: selectedNode)
        treeStates.append(WeakDOMTreeState(tree))
        pruneReleasedTreeStates()
        return DOMTreeController(tree: tree)
    }

    package func currentTreeSnapshot(
    ) -> DOMTreeSnapshot {
        return DOMTreeSnapshot.make(revision: 0, rootNode: rootNode, selectedNode: selectedNode)
    }

    package func currentTreeSnapshot(
        containing nodes: [DOMNode]
    ) throws -> DOMTreeSnapshot {
        let snapshot = currentTreeSnapshot()
        for node in nodes where snapshot.node(for: node.id) == nil {
            throw WebInspectorProxyError.disconnected("DOMNode is not in the current DOM tree.")
        }
        return snapshot
    }

    package func sortedDeletionNodes(
        for nodeIDs: [DOMNode.ID]
    ) throws -> (nodes: [DOMNode], snapshot: DOMTreeSnapshot) {
        var seenNodeIDs: Set<DOMNode.ID> = []
        let nodes = try nodeIDs
            .map { try requiredNode(for: $0) }
            .filter { seenNodeIDs.insert($0.id).inserted }
        let snapshot = try currentTreeSnapshot(containing: nodes)
        let sortedNodes = nodes.sorted {
            snapshot.ancestorNodeIDs(of: $0.id).count > snapshot.ancestorNodeIDs(of: $1.id).count
        }
        return (sortedNodes, snapshot)
    }

    package func sortedDeletionNodes(
        for nodes: [DOMNode]
    ) throws -> (nodes: [DOMNode], snapshot: DOMTreeSnapshot) {
        var seenNodeIDs: Set<DOMNode.ID> = []
        let registeredNodes = try nodes
            .map { try registeredNode($0) }
            .filter { seenNodeIDs.insert($0.id).inserted }
        let snapshot = try currentTreeSnapshot(containing: registeredNodes)
        let sortedNodes = registeredNodes.sorted {
            snapshot.ancestorNodeIDs(of: $0.id).count > snapshot.ancestorNodeIDs(of: $1.id).count
        }
        return (sortedNodes, snapshot)
    }

    package func clearSelectionIfDeleted(
        _ deletedRootIDs: [DOMNode.ID],
        snapshot: DOMTreeSnapshot
    ) -> Effects {
        guard let selectedNode else {
            return Effects()
        }
        let deletedRootIDs = Set(deletedRootIDs)
        guard deletedRootIDs.contains(selectedNode.id)
            || snapshot.ancestorNodeIDs(of: selectedNode.id).contains(where: deletedRootIDs.contains)
        else {
            return Effects()
        }

        self.selectedNode = nil
        notifyDOMTreeSelectionChanged(nil)
        return Effects(
            statusChanged: true,
            selectionChanged: true,
            discardedStyleNode: selectedNode
        )
    }

    package func setElementPickerEnabled(
        _ enabled: Bool
    ) -> Effects {
        isElementPickerEnabled = enabled
        return Effects(statusChanged: true)
    }

    package func recordPageHighlight(
    ) {
        pageHighlightDocumentEpoch = documentEpoch
    }

    package func clearPageHighlight(
    ) {
        pageHighlightDocumentEpoch = nil
    }

    package func shouldSendPageHighlightClearAfterReset(
    ) -> Bool {
        return pageHighlightDocumentEpoch == nil
    }

    package func recordEditHistoryTarget(
        _ target: WebInspectorTarget,
        options: DOMMutationPolicy
    ) {
        guard options.undo == .automatic else {
            return
        }
        editHistoryTarget = target
        didInvalidateEditHistoryTarget = false
    }

    package func undoRedoTarget(
        capturedTarget: WebInspectorTarget?,
        fallbackTarget: WebInspectorTarget?,
        documentEpoch capturedDocumentEpoch: Int
    ) throws -> WebInspectorTarget {
        guard documentEpoch == capturedDocumentEpoch else {
            throw WebInspectorProxyError.disconnected("DOM undo/redo target is no longer current.")
        }
        if let capturedTarget {
            return capturedTarget
        }
        if let editHistoryTarget {
            return editHistoryTarget
        }
        guard didInvalidateEditHistoryTarget == false,
              let fallbackTarget else {
            throw WebInspectorProxyError.disconnected("DOM undo/redo target is no longer current.")
        }
        return fallbackTarget
    }

    package func capturedEditHistoryTarget(
    ) -> WebInspectorTarget? {
        return editHistoryTarget
    }

    @discardableResult
    package func advanceDocumentEpoch(
    ) -> Int {
        documentEpoch += 1
        return documentEpoch
    }

    package func resetDocument(
    ) -> Effects {
        advanceSelectionRevision()
        let shouldClearPageHighlight = pageHighlightDocumentEpoch != nil
        rootNode = nil
        selectedNode = nil
        if editHistoryTarget != nil {
            didInvalidateEditHistoryTarget = true
        }
        editHistoryTarget = nil
        isElementPickerEnabled = false
        pendingInspectedNodeID = nil
        nodesByID = [:]
        frameDocumentProjectionIndex.removeAll()
        pageHighlightDocumentEpoch = nil
        notifyDOMTreeSnapshot(reason: .reset)
        return Effects(
            statusChanged: true,
            selectionChanged: true,
            documentReset: true,
            shouldClearPageHighlight: shouldClearPageHighlight
        )
    }

    package func apply(
        _ event: DOM.Event,
        modelContext: WebInspectorModelContext
    ) -> Effects {
        var effects = Effects()
        switch event {
        case .documentUpdated:
            advanceDocumentEpoch()
            effects.merge(resetDocument())
            effects.shouldReloadDocument = true
        case let .setChildNodes(parent, nodes):
            effects.merge(applySetChildNodes(
                parent: parent,
                nodes: nodes,
                modelContext: modelContext
            ))
        case let .childNodeInserted(parent, previous, node):
            effects.merge(applyChildNodeInserted(
                parent: parent,
                previous: previous,
                node: node,
                modelContext: modelContext
            ))
        case let .childNodeRemoved(parent, node):
            effects.merge(applyChildNodeRemoved(parent: parent, node: node))
        case let .childNodeCountUpdated(id, count):
            guard let node = nodesByID[DOMNode.ID(id)] else {
                requestFrameDocumentIfNeeded(
                    forNodeID: DOMNode.ID(id),
                    reason: "DOM.childNodeCountUpdated",
                    effects: &effects
                )
                skipEvent("DOM.childNodeCountUpdated referenced unmaterialized node id=\(logDescription(id))")
                return effects
            }
            node.updateChildNodeCount(count)
            notifyDOMTreeChildCountChanged(node: node)
        case let .attributeModified(id, name, value):
            guard let node = nodesByID[DOMNode.ID(id)] else {
                requestFrameDocumentIfNeeded(
                    forNodeID: DOMNode.ID(id),
                    reason: "DOM.attributeModified",
                    effects: &effects
                )
                skipEvent("DOM.attributeModified referenced unmaterialized node id=\(logDescription(id))")
                return effects
            }
            node.setAttribute(name: name, value: value)
            effects.selectedStylesNeedRefresh = selectedNode?.id == node.id
            notifyDOMTreeNodeChanged(node)
        case let .attributeRemoved(id, name):
            guard let node = nodesByID[DOMNode.ID(id)] else {
                requestFrameDocumentIfNeeded(
                    forNodeID: DOMNode.ID(id),
                    reason: "DOM.attributeRemoved",
                    effects: &effects
                )
                skipEvent("DOM.attributeRemoved referenced unmaterialized node id=\(logDescription(id))")
                return effects
            }
            node.removeAttribute(name: name)
            effects.selectedStylesNeedRefresh = selectedNode?.id == node.id
            notifyDOMTreeNodeChanged(node)
        case let .inlineStyleInvalidated(ids):
            effects.selectedStylesNeedRefresh = ids.isEmpty
                || ids.contains(where: { selectedNode?.id == DOMNode.ID($0) })
        case let .characterDataModified(id, value):
            guard let node = nodesByID[DOMNode.ID(id)] else {
                requestFrameDocumentIfNeeded(
                    forNodeID: DOMNode.ID(id),
                    reason: "DOM.characterDataModified",
                    effects: &effects
                )
                skipEvent("DOM.characterDataModified referenced unmaterialized node id=\(logDescription(id))")
                return effects
            }
            node.setNodeValue(value)
            effects.selectedStylesNeedRefresh = selectedNode?.id == node.id
            notifyDOMTreeNodeChanged(node)
        case let .inspect(id):
            isElementPickerEnabled = false
            effects.statusChanged = true
            let inspectedNodeID = DOMNode.ID(id)
            guard let node = nodesByID[inspectedNodeID], isNodeAttachedToCurrentTree(node) else {
                advanceSelectionRevision()
                requestFrameDocumentIfNeeded(
                    forNodeID: inspectedNodeID,
                    reason: "DOM.inspect",
                    effects: &effects
                )
                pendingInspectedNodeID = inspectedNodeID
                effects.merge(resolvePendingInspectedNode(
                    requestSubtreeIfNeeded: true
                ))
                return effects
            }
            pendingInspectedNodeID = nil
            effects.merge(select(node, reveal: .selectAndScroll))
            effects.inspectedNode = node
        case .detachedRoot:
            skipEvent("DOM.setChildNodes detached root deferred; subtree not indexed")
        case let .shadowRootPushed(host, root):
            effects.merge(applyShadowRootPushed(
                host: host,
                root: root,
                modelContext: modelContext
            ))
        case let .shadowRootPopped(host, root):
            effects.merge(applyShadowRootPopped(host: host, root: root))
        case let .pseudoElementAdded(parent, element):
            effects.merge(applyPseudoElementAdded(
                parent: parent,
                element: element,
                modelContext: modelContext
            ))
        case let .pseudoElementRemoved(parent, element):
            effects.merge(applyPseudoElementRemoved(parent: parent, element: element))
        case .willDestroyDOMNode,
             .unknown:
            break
        }
        return effects
    }

    private func advanceSelectionRevision() {
        precondition(
            selectionRevision < UInt64.max,
            "DOM selection revision exhausted UInt64."
        )
        selectionRevision += 1
    }

    @discardableResult
    package func applyDocument(
        _ payload: DOM.Node,
        expectedEpoch: Int,
        reason: DOMTreeSnapshotReason,
        modelContext: WebInspectorModelContext
    ) -> Effects? {
        guard expectedEpoch == documentEpoch else {
            return nil
        }
        var effects = Effects()
        var materializedPayloadIDs = Set<DOMNode.ID>()
        collectMaterializedPayloadIDs(payload, into: &materializedPayloadIDs)
        rootNode = model(
            for: payload,
            preserving: materializedPayloadIDs,
            modelContext: modelContext,
            effects: &effects
        )
        notifyDOMTreeSnapshot(reason: reason)
        effects.merge(resolvePendingInspectedNode(
            requestSubtreeIfNeeded: true
        ))
        return effects
    }

    @discardableResult
    package func applyFrameDocument(
        _ document: DOM.Node,
        frameTargetID: WebInspectorTarget.ID,
        expectedEpoch: Int,
        modelContext: WebInspectorModelContext
    ) -> Effects? {
        guard expectedEpoch == documentEpoch else {
            return nil
        }
        var effects = Effects()
        let scopedDocument = scopedFrameDocument(document, to: frameTargetID)
        var materializedPayloadIDs = Set<DOMNode.ID>()
        collectMaterializedPayloadIDs(scopedDocument, into: &materializedPayloadIDs)
        let previousRootID = frameDocumentProjectionIndex.setFrameDocumentRootID(
            DOMNode.ID(scopedDocument.id),
            for: frameTargetID
        )
        let frameRoot = model(
            for: scopedDocument,
            preserving: materializedPayloadIDs,
            modelContext: modelContext,
            effects: &effects
        )
        if let previousRootID,
           previousRootID != frameRoot.id,
           let previousRoot = nodesByID[previousRootID] {
            removeSubtreeFromIndex(previousRoot, preserving: materializedPayloadIDs, effects: &effects)
        }

        if let owner = attachProjectedFrameDocumentRoot(frameRoot, frameTargetID: frameTargetID) {
            notifyDOMTreeChildrenReplaced(parent: owner)
        }
        effects.merge(resolvePendingInspectedNode(
            requestSubtreeIfNeeded: true
        ))
        return effects
    }

    package func detachProjectedFrameDocument(
        forFrameID frameID: FrameID
    ) -> Effects {
        var effects = Effects()
        let owners = nodesByID.values.filter { $0.isFrameOwner && $0.frameID == frameID }
        for owner in owners {
            guard let rootID = frameDocumentProjectionIndex.projectedFrameDocumentRootID(forOwnerNodeID: owner.id) else {
                continue
            }
            let root = nodesByID[rootID]
            frameDocumentProjectionIndex.detachProjection(attachedTo: owner.id)
            owner.setContentDocument(nil)
            if let root {
                removeSubtreeFromIndex(root, effects: &effects)
            }
            notifyDOMTreeChildrenReplaced(parent: owner)
        }
        return effects
    }

    private func applySetChildNodes(
        parent: DOM.Node.ID,
        nodes: [DOM.Node],
        modelContext: WebInspectorModelContext
    ) -> Effects {
        var effects = Effects()
        guard let parentNode = nodesByID[DOMNode.ID(parent)] else {
            requestFrameDocumentIfNeeded(forNodeID: DOMNode.ID(parent), reason: "DOM.setChildNodes", effects: &effects)
            skipEvent("DOM.setChildNodes referenced unmaterialized parent id=\(logDescription(parent))")
            return effects
        }
        let previousChildren: [DOMNode]
        if case let .loaded(children) = parentNode.children {
            previousChildren = children
        } else {
            previousChildren = []
        }
        var newSubtreeIDs = Set<DOMNode.ID>()
        for node in nodes {
            collectMaterializedPayloadIDs(node, into: &newSubtreeIDs)
        }
        let newChildren = nodes.map {
            model(
                for: $0,
                preserving: newSubtreeIDs,
                modelContext: modelContext,
                effects: &effects
            )
        }
        let newChildIDs = Set(newChildren.map(\.id))
        for previousChild in previousChildren where newChildIDs.contains(previousChild.id) == false {
            removeSubtreeFromIndex(previousChild, preserving: newSubtreeIDs, effects: &effects)
        }
        parentNode.setChildren(newChildren)
        notifyDOMTreeChildrenReplaced(parent: parentNode)
        effects.merge(resolvePendingInspectedNode(
            requestSubtreeIfNeeded: false
        ))
        return effects
    }

    private func applyChildNodeInserted(
        parent: DOM.Node.ID,
        previous: DOM.Node.ID?,
        node: DOM.Node,
        modelContext: WebInspectorModelContext
    ) -> Effects {
        var effects = Effects()
        guard let parentNode = nodesByID[DOMNode.ID(parent)] else {
            requestFrameDocumentIfNeeded(forNodeID: DOMNode.ID(parent), reason: "DOM.childNodeInserted", effects: &effects)
            skipEvent("DOM.childNodeInserted referenced unmaterialized parent id=\(logDescription(parent))")
            return effects
        }

        guard case var .loaded(children) = parentNode.children else {
            parentNode.updateChildNodeCount(parentNode.childNodeCount + 1)
            notifyDOMTreeChildCountChanged(node: parentNode)
            return effects
        }
        var materializedPayloadIDs = Set<DOMNode.ID>()
        collectMaterializedPayloadIDs(node, into: &materializedPayloadIDs)
        let inserted = model(
            for: node,
            preserving: materializedPayloadIDs,
            modelContext: modelContext,
            effects: &effects
        )
        if let previous, let index = children.firstIndex(where: { $0.id == DOMNode.ID(previous) }) {
            children.insert(inserted, at: children.index(after: index))
        } else {
            children.insert(inserted, at: 0)
        }
        parentNode.setChildren(children)
        notifyDOMTreeChildInserted(
            parent: parentNode,
            node: inserted,
            previousSiblingID: previous.map(DOMNode.ID.init)
        )
        effects.merge(resolvePendingInspectedNode(
            requestSubtreeIfNeeded: false
        ))
        return effects
    }

    private func applyChildNodeRemoved(parent: DOM.Node.ID, node: DOM.Node.ID) -> Effects {
        var effects = Effects()
        guard let parentNode = nodesByID[DOMNode.ID(parent)] else {
            requestFrameDocumentIfNeeded(forNodeID: DOMNode.ID(parent), reason: "DOM.childNodeRemoved", effects: &effects)
            skipEvent("DOM.childNodeRemoved referenced unmaterialized parent id=\(logDescription(parent))")
            return effects
        }

        let removedID = DOMNode.ID(node)
        guard let removedNode = nodesByID[removedID] else {
            requestFrameDocumentIfNeeded(forNodeID: removedID, reason: "DOM.childNodeRemoved", effects: &effects)
            skipEvent("DOM.childNodeRemoved referenced unmaterialized child id=\(logDescription(node))")
            return effects
        }
        removeSubtreeFromIndex(removedNode, effects: &effects)

        guard case let .loaded(children) = parentNode.children else {
            parentNode.updateChildNodeCount(max(0, parentNode.childNodeCount - 1))
            notifyDOMTreeChildCountChanged(node: parentNode)
            return effects
        }
        parentNode.setChildren(children.filter { $0.id != removedID })
        notifyDOMTreeChildRemoved(parent: parentNode, nodeID: removedID)
        return effects
    }

    private func applyShadowRootPushed(
        host: DOM.Node.ID,
        root payload: DOM.Node,
        modelContext: WebInspectorModelContext
    ) -> Effects {
        var effects = Effects()
        guard let hostNode = nodesByID[DOMNode.ID(host)] else {
            requestFrameDocumentIfNeeded(forNodeID: DOMNode.ID(host), reason: "DOM.shadowRootPushed", effects: &effects)
            skipEvent("DOM.shadowRootPushed referenced unmaterialized host id=\(logDescription(host))")
            return effects
        }

        var materializedPayloadIDs = Set<DOMNode.ID>()
        collectMaterializedPayloadIDs(payload, into: &materializedPayloadIDs)
        let rootNode = model(
            for: payload,
            preserving: materializedPayloadIDs,
            modelContext: modelContext,
            effects: &effects
        )
        hostNode.appendShadowRoot(rootNode)
        notifyDOMTreeChildrenReplaced(parent: hostNode)
        effects.merge(resolvePendingInspectedNode(
            requestSubtreeIfNeeded: false
        ))
        return effects
    }

    private func applyShadowRootPopped(host: DOM.Node.ID, root: DOM.Node.ID) -> Effects {
        var effects = Effects()
        guard let hostNode = nodesByID[DOMNode.ID(host)] else {
            requestFrameDocumentIfNeeded(forNodeID: DOMNode.ID(host), reason: "DOM.shadowRootPopped", effects: &effects)
            skipEvent("DOM.shadowRootPopped referenced unmaterialized host id=\(logDescription(host))")
            return effects
        }

        let rootID = DOMNode.ID(root)
        guard let removedRoot = hostNode.removeShadowRoot(id: rootID) ?? nodesByID[rootID] else {
            skipEvent("DOM.shadowRootPopped referenced unmaterialized root id=\(logDescription(root))")
            return effects
        }
        removeSubtreeFromIndex(removedRoot, effects: &effects)
        notifyDOMTreeChildrenReplaced(parent: hostNode)
        return effects
    }

    private func applyPseudoElementAdded(
        parent: DOM.Node.ID,
        element payload: DOM.Node,
        modelContext: WebInspectorModelContext
    ) -> Effects {
        var effects = Effects()
        guard let parentNode = nodesByID[DOMNode.ID(parent)] else {
            requestFrameDocumentIfNeeded(forNodeID: DOMNode.ID(parent), reason: "DOM.pseudoElementAdded", effects: &effects)
            skipEvent("DOM.pseudoElementAdded referenced unmaterialized parent id=\(logDescription(parent))")
            return effects
        }

        var materializedPayloadIDs = Set<DOMNode.ID>()
        collectMaterializedPayloadIDs(payload, into: &materializedPayloadIDs)
        let pseudoElement = model(
            for: payload,
            preserving: materializedPayloadIDs,
            modelContext: modelContext,
            effects: &effects
        )
        if let replacedElement = parentNode.setPseudoElement(pseudoElement) {
            removeSubtreeFromIndex(replacedElement, preserving: materializedPayloadIDs, effects: &effects)
        }
        notifyDOMTreeChildrenReplaced(parent: parentNode)
        effects.merge(resolvePendingInspectedNode(
            requestSubtreeIfNeeded: false
        ))
        return effects
    }

    private func applyPseudoElementRemoved(parent: DOM.Node.ID, element: DOM.Node.ID) -> Effects {
        var effects = Effects()
        guard let parentNode = nodesByID[DOMNode.ID(parent)] else {
            requestFrameDocumentIfNeeded(forNodeID: DOMNode.ID(parent), reason: "DOM.pseudoElementRemoved", effects: &effects)
            skipEvent("DOM.pseudoElementRemoved referenced unmaterialized parent id=\(logDescription(parent))")
            return effects
        }

        let elementID = DOMNode.ID(element)
        guard let removedElement = parentNode.removePseudoElement(id: elementID) ?? nodesByID[elementID] else {
            skipEvent("DOM.pseudoElementRemoved referenced unmaterialized pseudo element id=\(logDescription(element))")
            return effects
        }
        removeSubtreeFromIndex(removedElement, effects: &effects)
        notifyDOMTreeChildrenReplaced(parent: parentNode)
        return effects
    }

    @discardableResult
    private func removeSubtreeFromIndex(
        _ root: DOMNode,
        preserving preservedIDs: Set<DOMNode.ID> = [],
        effects: inout Effects
    ) -> Bool {
        var removedIDs = Set<DOMNode.ID>()
        collectSubtreeIDs(root, into: &removedIDs)
        removedIDs.subtract(preservedIDs)
        frameDocumentProjectionIndex.removeProjections(containing: removedIDs)
        for id in removedIDs {
            nodesByID[id] = nil
        }
        if let selectedNode, removedIDs.contains(selectedNode.id) {
            self.selectedNode = nil
            notifyDOMTreeSelectionChanged(nil)
            effects.statusChanged = true
            effects.selectionChanged = true
            return true
        }
        return false
    }

    private func collectSubtreeIDs(_ node: DOMNode, into ids: inout Set<DOMNode.ID>) {
        guard ids.insert(node.id).inserted else {
            return
        }
        for associatedRoot in node.associatedSubtreeRoots() {
            collectSubtreeIDs(associatedRoot, into: &ids)
        }
        guard case let .loaded(children) = node.children else {
            return
        }
        for child in children {
            collectSubtreeIDs(child, into: &ids)
        }
    }

    private func collectMaterializedPayloadIDs(_ node: DOM.Node, into ids: inout Set<DOMNode.ID>) {
        guard ids.insert(DOMNode.ID(node.id)).inserted else {
            return
        }
        for associatedNode in associatedPayloadNodes(for: node) {
            collectMaterializedPayloadIDs(associatedNode, into: &ids)
        }
        for child in node.children ?? [] {
            collectMaterializedPayloadIDs(child, into: &ids)
        }
    }

    private func model(
        for payload: DOM.Node,
        preserving materializedPayloadIDs: Set<DOMNode.ID>,
        modelContext: WebInspectorModelContext,
        effects: inout Effects
    ) -> DOMNode {
        let id = DOMNode.ID(payload.id)
        let node: DOMNode
        let previousChildren: [DOMNode]
        let previousAssociatedRoots: [DOMNode]
        if let existing = nodesByID[id] {
            if case let .loaded(children) = existing.children {
                previousChildren = children
            } else {
                previousChildren = []
            }
            previousAssociatedRoots = existing.associatedSubtreeRoots()
            existing.update(from: payload)
            node = existing
        } else {
            previousChildren = []
            previousAssociatedRoots = []
            node = DOMNode(node: payload)
            nodesByID[id] = node
        }

        let payloadContentDocument = payload.contentDocument.map {
            model(
                for: $0,
                preserving: materializedPayloadIDs,
                modelContext: modelContext,
                effects: &effects
            )
        }
        let shadowRoots = payload.shadowRoots.map {
            model(
                for: $0,
                preserving: materializedPayloadIDs,
                modelContext: modelContext,
                effects: &effects
            )
        }
        let templateContent = payload.templateContent.map {
            model(
                for: $0,
                preserving: materializedPayloadIDs,
                modelContext: modelContext,
                effects: &effects
            )
        }
        let beforePseudoElement = payload.beforePseudoElement.map {
            model(
                for: $0,
                preserving: materializedPayloadIDs,
                modelContext: modelContext,
                effects: &effects
            )
        }
        let otherPseudoElements = payload.otherPseudoElements.map {
            model(
                for: $0,
                preserving: materializedPayloadIDs,
                modelContext: modelContext,
                effects: &effects
            )
        }
        let afterPseudoElement = payload.afterPseudoElement.map {
            model(
                for: $0,
                preserving: materializedPayloadIDs,
                modelContext: modelContext,
                effects: &effects
            )
        }
        let contentDocument = projectedFrameDocument(for: node, payloadContentDocument: payloadContentDocument)
        node.setAssociatedNodes(
            contentDocument: contentDocument,
            shadowRoots: shadowRoots,
            templateContent: templateContent,
            beforePseudoElement: beforePseudoElement,
            otherPseudoElements: otherPseudoElements,
            afterPseudoElement: afterPseudoElement
        )
        let associatedIDs = Set(node.associatedSubtreeRoots().map(\.id))
        for previousRoot in previousAssociatedRoots where associatedIDs.contains(previousRoot.id) == false {
            removeSubtreeFromIndex(previousRoot, preserving: materializedPayloadIDs, effects: &effects)
        }

        if let children = payload.children {
            let newChildren = children.map {
                model(
                    for: $0,
                    preserving: materializedPayloadIDs,
                    modelContext: modelContext,
                    effects: &effects
                )
            }
            let newChildIDs = Set(newChildren.map(\.id))
            for previousChild in previousChildren where newChildIDs.contains(previousChild.id) == false {
                removeSubtreeFromIndex(previousChild, preserving: materializedPayloadIDs, effects: &effects)
            }
            node.setChildren(newChildren)
        } else if payload.childNodeCount == 0 && previousChildren.isEmpty == false {
            for previousChild in previousChildren {
                removeSubtreeFromIndex(previousChild, preserving: materializedPayloadIDs, effects: &effects)
            }
            node.setChildrenUnrequested(count: payload.childNodeCount)
        } else {
            node.updateChildNodeCount(payload.childNodeCount)
        }
        return node
    }

    private func associatedPayloadNodes(for node: DOM.Node) -> [DOM.Node] {
        [node.contentDocument]
            .compactMap { $0 }
            + node.shadowRoots
            + [node.templateContent, node.beforePseudoElement]
            .compactMap { $0 }
            + node.otherPseudoElements
            + [node.afterPseudoElement]
            .compactMap { $0 }
    }

    private func projectedFrameDocument(
        for owner: DOMNode,
        payloadContentDocument: DOMNode?
    ) -> DOMNode? {
        guard owner.isFrameOwner else {
            return payloadContentDocument
        }

        if let attachedRootID = frameDocumentProjectionIndex.projectedFrameDocumentRootID(forOwnerNodeID: owner.id) {
            guard let attachedRoot = nodesByID[attachedRootID],
                  frameOwner(owner, matchesFrameDocumentRoot: attachedRoot) else {
                frameDocumentProjectionIndex.detachProjection(attachedTo: owner.id)
                return payloadContentDocument
            }
            return attachedRoot
        }

        guard let frameTargetID = frameTargetIDForFrameDocument(matching: owner),
              let rootID = frameDocumentProjectionIndex.frameDocumentRootID(for: frameTargetID),
              let root = nodesByID[rootID] else {
            return payloadContentDocument
        }
        frameDocumentProjectionIndex.attach(frameTargetID: frameTargetID, to: owner.id)
        return root
    }

    private func frameTargetIDForFrameDocument(matching owner: DOMNode) -> WebInspectorTarget.ID? {
        let matches = frameDocumentProjectionIndex.frameTargetIDs.filter { frameTargetID in
            guard frameDocumentProjectionIndex.ownerNodeID(for: frameTargetID) == nil,
                  let rootID = frameDocumentProjectionIndex.frameDocumentRootID(for: frameTargetID),
                  let root = nodesByID[rootID] else {
                return false
            }
            return frameOwner(owner, matchesFrameDocumentRoot: root)
        }
        guard matches.count <= 1 else {
            WebInspectorDataKitLog.debug(
                "frame document projection ambiguous owner=\(String(describing: owner.id))"
            )
            return nil
        }
        return matches.first
    }

    private func frameOwner(_ owner: DOMNode, matchesFrameDocumentRoot root: DOMNode) -> Bool {
        guard owner.isFrameOwner,
              let ownerFrameID = owner.frameID,
              let rootFrameID = root.frameID else {
            return false
        }
        return ownerFrameID == rootFrameID
    }

    private func requestFrameDocumentIfNeeded(
        forNodeID nodeID: DOMNode.ID,
        reason: String,
        effects: inout Effects
    ) {
        guard let frameTargetID = frameTargetID(for: nodeID) else {
            return
        }
        if let rootID = frameDocumentProjectionIndex.frameDocumentRootID(for: frameTargetID),
           let root = nodesByID[rootID] {
            if let owner = attachProjectedFrameDocumentRoot(root, frameTargetID: frameTargetID) {
                notifyDOMTreeChildrenReplaced(parent: owner)
            }
            return
        }
        if effects.frameDocumentLoadRequests.contains(where: { $0.targetID == frameTargetID }) == false {
            effects.frameDocumentLoadRequests.append(FrameDocumentLoadRequest(
                targetID: frameTargetID,
                reason: reason
            ))
        }
    }

    private func attachProjectedFrameDocumentRoot(
        _ frameRoot: DOMNode,
        frameTargetID: WebInspectorTarget.ID
    ) -> DOMNode? {
        guard let owner = frameOwner(forFrameDocumentRoot: frameRoot, frameTargetID: frameTargetID) else {
            frameDocumentProjectionIndex.detach(frameTargetID: frameTargetID)
            return nil
        }
        frameDocumentProjectionIndex.attach(frameTargetID: frameTargetID, to: owner.id)
        owner.setContentDocument(frameRoot)
        return owner
    }

    private func frameOwner(
        forFrameDocumentRoot frameRoot: DOMNode,
        frameTargetID: WebInspectorTarget.ID
    ) -> DOMNode? {
        if let ownerID = frameDocumentProjectionIndex.ownerNodeID(for: frameTargetID),
           let owner = nodesByID[ownerID],
           frameOwner(owner, matchesFrameDocumentRoot: frameRoot) {
            return owner
        }
        let candidates = nodesByID.values.filter { node in
            guard frameOwner(node, matchesFrameDocumentRoot: frameRoot) else {
                return false
            }
            guard let attachedRootID = frameDocumentProjectionIndex.projectedFrameDocumentRootID(forOwnerNodeID: node.id) else {
                return true
            }
            return attachedRootID == frameRoot.id
        }
        guard candidates.count <= 1 else {
            WebInspectorDataKitLog.debug(
                "frame document projection ambiguous frameID=\(String(describing: frameRoot.frameID))"
            )
            return nil
        }
        return candidates.first
    }

    private func frameTargetID(for nodeID: DOMNode.ID) -> WebInspectorTarget.ID? {
        nodeID.proxyID.targetScopeRawValue.map(WebInspectorTarget.ID.init)
    }

    private func scopedFrameDocument(_ node: DOM.Node, to frameTargetID: WebInspectorTarget.ID) -> DOM.Node {
        DOM.Node(
            id: scopedNodeID(node.id, to: frameTargetID),
            nodeType: node.nodeType,
            nodeName: node.nodeName,
            localName: node.localName,
            nodeValue: node.nodeValue,
            frameID: node.frameID,
            documentURL: node.documentURL,
            baseURL: node.baseURL,
            attributes: node.attributes,
            attributeList: node.attributeList,
            childNodeCount: node.childNodeCount,
            children: node.children?.map { scopedFrameDocument($0, to: frameTargetID) },
            contentDocument: node.contentDocument.map { scopedFrameDocument($0, to: frameTargetID) },
            shadowRoots: node.shadowRoots.map { scopedFrameDocument($0, to: frameTargetID) },
            templateContent: node.templateContent.map { scopedFrameDocument($0, to: frameTargetID) },
            beforePseudoElement: node.beforePseudoElement.map { scopedFrameDocument($0, to: frameTargetID) },
            otherPseudoElements: node.otherPseudoElements.map { scopedFrameDocument($0, to: frameTargetID) },
            afterPseudoElement: node.afterPseudoElement.map { scopedFrameDocument($0, to: frameTargetID) },
            pseudoType: node.pseudoType,
            shadowRootType: node.shadowRootType
        )
    }

    private func scopedNodeID(_ id: DOM.Node.ID, to frameTargetID: WebInspectorTarget.ID) -> DOM.Node.ID {
        guard id.targetScopeRawValue == nil else {
            return id
        }
        return DOM.Node.ID(id.rawValue, scopedToTargetRawValue: frameTargetID.rawValue)
    }

    private func resolvePendingInspectedNode(
        requestSubtreeIfNeeded: Bool
    ) -> Effects {
        var effects = Effects()
        guard let pendingInspectedNodeID else {
            return effects
        }
        guard let inspectedNode = nodesByID[pendingInspectedNodeID],
              isNodeAttachedToCurrentTree(inspectedNode) else {
            if requestSubtreeIfNeeded {
                requestFrameDocumentIfNeeded(
                    forNodeID: pendingInspectedNodeID,
                    reason: "DOM.inspect",
                    effects: &effects
                )
            }
            return effects
        }
        WebInspectorDataKitLog.debug(
            "DOM.inspect resolved pending nodeID=\(String(describing: pendingInspectedNodeID))"
        )
        self.pendingInspectedNodeID = nil
        effects.merge(select(inspectedNode, reveal: .selectAndScroll))
        effects.inspectedNode = inspectedNode
        return effects
    }

    private func isNodeAttachedToCurrentTree(_ node: DOMNode) -> Bool {
        guard let rootNode else {
            return false
        }
        var visitedNodeIDs = Set<DOMNode.ID>()
        return subtree(rootNode, contains: node.id, visitedNodeIDs: &visitedNodeIDs)
    }

    private func subtree(
        _ root: DOMNode,
        contains nodeID: DOMNode.ID,
        visitedNodeIDs: inout Set<DOMNode.ID>
    ) -> Bool {
        guard visitedNodeIDs.insert(root.id).inserted else {
            return false
        }
        if root.id == nodeID {
            return true
        }
        for associatedRoot in root.associatedSubtreeRoots() {
            if subtree(associatedRoot, contains: nodeID, visitedNodeIDs: &visitedNodeIDs) {
                return true
            }
        }
        guard case let .loaded(children) = root.children else {
            return false
        }
        for child in children {
            if subtree(child, contains: nodeID, visitedNodeIDs: &visitedNodeIDs) {
                return true
            }
        }
        return false
    }

    private func notifyDOMTreeSnapshot(reason: DOMTreeSnapshotReason) {
        pruneReleasedTreeStates()
        for reference in treeStates {
            reference.tree?.applySnapshot(rootNode: rootNode, selectedNode: selectedNode, reason: reason)
        }
    }

    private func notifyDOMTreeChildrenReplaced(parent: DOMNode) {
        pruneReleasedTreeStates()
        for reference in treeStates {
            reference.tree?.applyChildrenReplaced(parent: parent)
        }
    }

    private func notifyDOMTreeChildInserted(
        parent: DOMNode,
        node: DOMNode,
        previousSiblingID: DOMNode.ID?
    ) {
        pruneReleasedTreeStates()
        for reference in treeStates {
            reference.tree?.applyChildInserted(
                parent: parent,
                node: node,
                previousSiblingID: previousSiblingID
            )
        }
    }

    private func notifyDOMTreeChildRemoved(parent: DOMNode, nodeID: DOMNode.ID) {
        pruneReleasedTreeStates()
        for reference in treeStates {
            reference.tree?.applyChildRemoved(parent: parent, nodeID: nodeID)
        }
    }

    private func notifyDOMTreeChildCountChanged(node: DOMNode) {
        pruneReleasedTreeStates()
        for reference in treeStates {
            reference.tree?.applyChildCountChanged(node: node)
        }
    }

    private func notifyDOMTreeNodeChanged(_ node: DOMNode) {
        pruneReleasedTreeStates()
        for reference in treeStates {
            reference.tree?.applyNodeChanged(node)
        }
    }

    private func notifyDOMTreeSelectionChanged(
        _ node: DOMNode?,
        reveal: DOMRevealPolicy = .selectAndScroll
    ) {
        pruneReleasedTreeStates()
        for reference in treeStates {
            reference.tree?.applySelectionChanged(nodeID: node?.id, reveal: reveal)
        }
    }

    private func pruneReleasedTreeStates() {
        treeStates.removeAll { $0.tree == nil }
    }

    private func skipEvent(_ reason: String) {
        WebInspectorDataKitLog.debug("event skipped: \(reason)")
    }

    private func logDescription(_ id: DOM.Node.ID) -> String {
        "\(id.unscopedRawValue)@\(id.targetScopeRawValue ?? "current-page")"
    }

}
