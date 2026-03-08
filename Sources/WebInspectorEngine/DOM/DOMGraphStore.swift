import Foundation
import Observation

@MainActor
@Observable
public final class DOMGraphStore {
    public private(set) var entriesByID: [DOMEntryID: DOMEntry] = [:]
    public private(set) var rootID: DOMEntryID?
    public private(set) var selectedID: DOMEntryID?
    public private(set) var documentGeneration: UInt64

    private var entriesByNodeID: [Int: DOMEntry] = [:]

    public init(documentGeneration: UInt64 = 1) {
        self.documentGeneration = max(1, documentGeneration)
    }

    public var selectedEntry: DOMEntry? {
        guard let selectedID else {
            return nil
        }
        return entriesByID[selectedID]
    }

    public func entry(for id: DOMEntryID) -> DOMEntry? {
        entriesByID[id]
    }

    public func entry(forNodeID nodeID: Int) -> DOMEntry? {
        entriesByNodeID[nodeID]
    }

    public func select(_ id: DOMEntryID?) {
        guard let id else {
            selectedID = nil
            return
        }
        selectedID = entriesByID[id] != nil ? id : nil
    }

    public func select(nodeID: Int?) {
        guard let nodeID else {
            selectedID = nil
            return
        }
        select(makeID(nodeID: nodeID))
    }

    public func resetForDocumentUpdate() {
        documentGeneration &+= 1
        if documentGeneration == 0 {
            documentGeneration = 1
        }

        entriesByID.removeAll(keepingCapacity: true)
        entriesByNodeID.removeAll(keepingCapacity: true)
        rootID = nil
        selectedID = nil
    }

    public func applySnapshot(_ snapshot: DOMGraphSnapshot) {
        let previousSelectedNodeID = selectedID?.nodeID

        entriesByID.removeAll(keepingCapacity: true)
        entriesByNodeID.removeAll(keepingCapacity: true)
        let root = buildSubtree(from: snapshot.root, parent: nil)
        rootID = root.id

        if let selectedNodeID = snapshot.selectedNodeID {
            selectedID = makeID(nodeID: selectedNodeID)
        } else if let previousSelectedNodeID {
            selectedID = makeID(nodeID: previousSelectedNodeID)
        }

        reconcileSelectedID()
    }

    public func applyMutationBundle(_ bundle: DOMGraphMutationBundle) {
        guard !bundle.events.isEmpty else {
            return
        }

        let previousSelectedID = selectedID
        for event in bundle.events {
            switch event {
            case let .childNodeInserted(parentNodeID, previousNodeID, node):
                applyChildNodeInserted(parentNodeID: parentNodeID, previousNodeID: previousNodeID, node: node)
            case let .childNodeRemoved(parentNodeID, nodeID):
                applyChildNodeRemoved(parentNodeID: parentNodeID, nodeID: nodeID)
            case let .attributeModified(nodeID, name, value, layoutFlags, isRendered):
                applyAttributeModified(
                    nodeID: nodeID,
                    name: name,
                    value: value,
                    layoutFlags: layoutFlags,
                    isRendered: isRendered
                )
            case let .attributeRemoved(nodeID, name, layoutFlags, isRendered):
                applyAttributeRemoved(
                    nodeID: nodeID,
                    name: name,
                    layoutFlags: layoutFlags,
                    isRendered: isRendered
                )
            case let .characterDataModified(nodeID, value, layoutFlags, isRendered):
                applyCharacterDataModified(
                    nodeID: nodeID,
                    value: value,
                    layoutFlags: layoutFlags,
                    isRendered: isRendered
                )
            case let .childNodeCountUpdated(nodeID, childCount, layoutFlags, isRendered):
                applyChildNodeCountUpdated(
                    nodeID: nodeID,
                    childCount: childCount,
                    layoutFlags: layoutFlags,
                    isRendered: isRendered
                )
            case let .setChildNodes(parentNodeID, nodes):
                applySetChildNodes(parentNodeID: parentNodeID, nodes: nodes)
            case let .replaceSubtree(root):
                applyReplaceSubtree(root)
            case .documentUpdated:
                resetForDocumentUpdate()
            }
        }

        reconcileSelectedID()
        if selectedID == nil,
           let previousSelectedID,
           entriesByID[previousSelectedID] != nil {
            selectedID = previousSelectedID
        }
    }

    @discardableResult
    public func applySelectionSnapshot(_ payload: DOMSelectionSnapshotPayload?) -> Bool {
        let previousSelectedID = selectedID
        guard let payload, let nodeID = payload.nodeID else {
            clearMatchedStyles(for: previousSelectedID)
            selectedID = nil
            return false
        }

        guard let entry = entry(forNodeID: nodeID) else {
            clearMatchedStyles(for: previousSelectedID)
            selectedID = nil
            return false
        }

        let entryID = entry.id
        entry.preview = payload.preview
        entry.path = payload.path
        entry.selectorPath = payload.selectorPath
        entry.styleRevision = payload.styleRevision
        entry.attributes = normalizeAttributes(payload.attributes, nodeID: entry.id.nodeID)

        entriesByID[entryID] = entry
        entriesByNodeID[nodeID] = entry
        selectedID = entryID
        return true
    }

    public func applySelectorPath(_ payload: DOMSelectorPathPayload) {
        guard let nodeID = payload.nodeID else {
            return
        }

        let entryID = makeID(nodeID: nodeID)
        guard selectedID == entryID, let entry = entriesByID[entryID] else {
            return
        }

        if entry.selectorPath != payload.selectorPath {
            entry.selectorPath = payload.selectorPath
            entriesByID[entryID] = entry
            entriesByNodeID[nodeID] = entry
        }
    }

    public func beginMatchedStylesLoading(for nodeID: Int) {
        let entryID = makeID(nodeID: nodeID)
        guard selectedID == entryID, let entry = entriesByID[entryID] else {
            return
        }

        entry.isLoadingMatchedStyles = true
        entry.needsMatchedStylesRefresh = false
        entry.matchedStyles = []
        entry.matchedStylesTruncated = false
        entry.blockedStylesheetCount = 0
        entriesByID[entryID] = entry
        entriesByNodeID[nodeID] = entry
    }

    public func applyMatchedStyles(_ payload: DOMMatchedStylesPayload, for nodeID: Int) {
        let entryID = makeID(nodeID: nodeID)
        guard selectedID == entryID, let entry = entriesByID[entryID] else {
            return
        }
        guard entry.id.nodeID == payload.nodeId else {
            return
        }

        entry.matchedStyles = payload.rules
        entry.matchedStylesTruncated = payload.truncated
        entry.blockedStylesheetCount = payload.blockedStylesheetCount
        entry.isLoadingMatchedStyles = false
        entry.needsMatchedStylesRefresh = false
        entriesByID[entryID] = entry
        entriesByNodeID[nodeID] = entry
    }

    public func clearMatchedStyles(for nodeID: Int?) {
        let resolvedID: DOMEntryID?
        if let nodeID {
            resolvedID = makeID(nodeID: nodeID)
        } else {
            resolvedID = selectedID
        }

        clearMatchedStyles(for: resolvedID)
    }

    public func invalidateMatchedStyles(for nodeID: Int?) {
        let resolvedID: DOMEntryID?
        if let nodeID {
            resolvedID = makeID(nodeID: nodeID)
        } else {
            resolvedID = selectedID
        }

        clearMatchedStyles(for: resolvedID, requiresRefresh: true)
    }

    public func updateSelectedAttribute(name: String, value: String) {
        guard let selectedID, let entry = entriesByID[selectedID] else {
            return
        }

        if let index = entry.attributes.firstIndex(where: { $0.name == name }) {
            entry.attributes[index].value = value
        } else {
            entry.attributes.append(
                DOMAttribute(nodeId: entry.id.nodeID, name: name, value: value)
            )
        }

        entriesByID[selectedID] = entry
        entriesByNodeID[entry.id.nodeID] = entry
    }

    public func removeSelectedAttribute(name: String) {
        guard let selectedID, let entry = entriesByID[selectedID] else {
            return
        }

        entry.attributes.removeAll { $0.name == name }
        entriesByID[selectedID] = entry
        entriesByNodeID[entry.id.nodeID] = entry
    }
}

private extension DOMGraphStore {
    func clearMatchedStyles(for entryID: DOMEntryID?, requiresRefresh: Bool = false) {
        guard let entryID, let entry = entriesByID[entryID] else {
            return
        }

        entry.clearMatchedStyles(requiresRefresh: requiresRefresh)
        entriesByID[entryID] = entry
        entriesByNodeID[entry.id.nodeID] = entry
    }

    func makeID(nodeID: Int) -> DOMEntryID {
        DOMEntryID(documentGeneration: documentGeneration, nodeID: nodeID)
    }

    func normalizeAttributes(_ attributes: [DOMAttribute], nodeID: Int) -> [DOMAttribute] {
        attributes.map {
            DOMAttribute(
                nodeId: $0.nodeId ?? nodeID,
                name: $0.name,
                value: $0.value
            )
        }
    }

    @discardableResult
    func buildSubtree(from descriptor: DOMGraphNodeDescriptor, parent: DOMEntry?) -> DOMEntry {
        let entryID = makeID(nodeID: descriptor.nodeID)
        if let existing = entriesByID[entryID] {
            removeSubtree(existing, removeFromParent: true)
        }

        let entry = DOMEntry(
            id: entryID,
            nodeType: descriptor.nodeType,
            nodeName: descriptor.nodeName,
            localName: descriptor.localName,
            nodeValue: descriptor.nodeValue,
            attributes: normalizeAttributes(descriptor.attributes, nodeID: descriptor.nodeID),
            childCount: max(descriptor.childCount, descriptor.children.count),
            layoutFlags: descriptor.layoutFlags,
            isRendered: descriptor.isRendered
        )
        entry.parent = parent
        entriesByID[entryID] = entry
        entriesByNodeID[descriptor.nodeID] = entry

        var children: [DOMEntry] = []
        children.reserveCapacity(descriptor.children.count)
        for childDescriptor in descriptor.children {
            let child = buildSubtree(from: childDescriptor, parent: entry)
            children.append(child)
        }
        entry.children = children
        relinkChildren(of: entry)

        return entry
    }

    func relinkChildren(of parent: DOMEntry) {
        for (index, child) in parent.children.enumerated() {
            child.parent = parent
            child.previousSibling = index > 0 ? parent.children[index - 1] : nil
            child.nextSibling = index + 1 < parent.children.count ? parent.children[index + 1] : nil
        }
    }

    func applyChildNodeInserted(parentNodeID: Int, previousNodeID: Int?, node: DOMGraphNodeDescriptor) {
        guard let parent = entry(forNodeID: parentNodeID) else {
            return
        }

        let inserted = buildSubtree(from: node, parent: parent)
        let wasLoadedChild = parent.children.contains { $0.id == inserted.id }
        let previousChildCount = max(parent.childCount, parent.children.count)
        parent.children.removeAll { $0.id == inserted.id }

        let insertionIndex: Int
        if previousNodeID == 0 {
            insertionIndex = 0
        } else if let previousNodeID,
                  let previousEntry = entry(forNodeID: previousNodeID),
                  let previousIndex = parent.children.firstIndex(where: { $0.id == previousEntry.id }) {
            insertionIndex = previousIndex + 1
        } else {
            insertionIndex = parent.children.count
        }

        let boundedIndex = min(max(0, insertionIndex), parent.children.count)
        parent.children.insert(inserted, at: boundedIndex)
        if wasLoadedChild {
            parent.childCount = max(previousChildCount, parent.children.count)
        } else {
            parent.childCount = max(previousChildCount + 1, parent.children.count)
        }
        relinkChildren(of: parent)
        entriesByID[parent.id] = parent
        entriesByNodeID[parent.id.nodeID] = parent
    }

    func applyChildNodeRemoved(parentNodeID: Int, nodeID: Int) {
        guard let parent = entry(forNodeID: parentNodeID) else {
            return
        }

        let removedEntryID = makeID(nodeID: nodeID)
        if let index = parent.children.firstIndex(where: { $0.id == removedEntryID }) {
            let removed = parent.children.remove(at: index)
            parent.childCount = max(parent.children.count, parent.childCount - 1)
            relinkChildren(of: parent)
            entriesByID[parent.id] = parent
            entriesByNodeID[parent.id.nodeID] = parent
            removeSubtree(removed, removeFromParent: false)
            return
        }

        if let entry = entriesByID[removedEntryID] {
            removeSubtree(entry, removeFromParent: true)
        }
    }

    func applyAttributeModified(
        nodeID: Int,
        name: String,
        value: String,
        layoutFlags: [String]?,
        isRendered: Bool?
    ) {
        guard let entry = entry(forNodeID: nodeID) else {
            return
        }

        if let index = entry.attributes.firstIndex(where: { $0.name == name }) {
            entry.attributes[index].value = value
        } else {
            entry.attributes.append(DOMAttribute(nodeId: entry.id.nodeID, name: name, value: value))
        }

        applyLayout(into: entry, layoutFlags: layoutFlags, isRendered: isRendered)
        entriesByID[entry.id] = entry
        entriesByNodeID[nodeID] = entry
    }

    func applyAttributeRemoved(
        nodeID: Int,
        name: String,
        layoutFlags: [String]?,
        isRendered: Bool?
    ) {
        guard let entry = entry(forNodeID: nodeID) else {
            return
        }

        entry.attributes.removeAll { $0.name == name }
        applyLayout(into: entry, layoutFlags: layoutFlags, isRendered: isRendered)
        entriesByID[entry.id] = entry
        entriesByNodeID[nodeID] = entry
    }

    func applyCharacterDataModified(
        nodeID: Int,
        value: String,
        layoutFlags: [String]?,
        isRendered: Bool?
    ) {
        guard let entry = entry(forNodeID: nodeID) else {
            return
        }

        entry.nodeValue = value
        applyLayout(into: entry, layoutFlags: layoutFlags, isRendered: isRendered)
        entriesByID[entry.id] = entry
        entriesByNodeID[nodeID] = entry
    }

    func applyChildNodeCountUpdated(
        nodeID: Int,
        childCount: Int,
        layoutFlags: [String]?,
        isRendered: Bool?
    ) {
        guard let entry = entry(forNodeID: nodeID) else {
            return
        }

        entry.childCount = max(0, childCount)
        applyLayout(into: entry, layoutFlags: layoutFlags, isRendered: isRendered)
        entriesByID[entry.id] = entry
        entriesByNodeID[nodeID] = entry
    }

    func applySetChildNodes(parentNodeID: Int, nodes: [DOMGraphNodeDescriptor]) {
        guard let parent = entry(forNodeID: parentNodeID) else {
            return
        }

        let previousChildren = parent.children
        var nextChildren: [DOMEntry] = []
        nextChildren.reserveCapacity(nodes.count)

        for node in nodes {
            nextChildren.append(buildSubtree(from: node, parent: parent))
        }

        let retainedIDs = Set(nextChildren.map(\.id))
        for previous in previousChildren where !retainedIDs.contains(previous.id) {
            removeSubtree(previous, removeFromParent: false)
        }

        parent.children = nextChildren
        parent.childCount = max(parent.childCount, nextChildren.count)
        relinkChildren(of: parent)
        entriesByID[parent.id] = parent
        entriesByNodeID[parent.id.nodeID] = parent
    }

    func applyReplaceSubtree(_ root: DOMGraphNodeDescriptor) {
        let rootID = makeID(nodeID: root.nodeID)

        if let existing = entriesByID[rootID] {
            let parent = existing.parent
            let previousIndex = parent?.children.firstIndex(where: { $0.id == existing.id })
            let previousParentChildCount = parent.map { max($0.childCount, $0.children.count) }
            let isReplacingRoot = self.rootID == existing.id
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
                entriesByID[parent.id] = parent
                entriesByNodeID[parent.id.nodeID] = parent
            } else if isReplacingRoot {
                self.rootID = replacement.id
            }
            return
        }

        // requestChildNodes may return after the target disappeared; ignore stale subtree updates.
    }

    func applyLayout(into entry: DOMEntry, layoutFlags: [String]?, isRendered: Bool?) {
        if let layoutFlags {
            entry.layoutFlags = layoutFlags
        }
        if let isRendered {
            entry.isRendered = isRendered
        }
    }

    func removeSubtree(_ root: DOMEntry, removeFromParent: Bool, decrementParentChildCount: Bool = true) {
        if removeFromParent, let parent = root.parent {
            let previousLoadedChildCount = parent.children.count
            parent.children.removeAll { $0.id == root.id }
            let removedLoadedChild = parent.children.count < previousLoadedChildCount
            if decrementParentChildCount, removedLoadedChild {
                parent.childCount = max(parent.children.count, parent.childCount - 1)
            } else {
                parent.childCount = max(parent.childCount, parent.children.count)
            }
            relinkChildren(of: parent)
            entriesByID[parent.id] = parent
            entriesByNodeID[parent.id.nodeID] = parent
        }

        for child in root.children {
            removeSubtree(child, removeFromParent: false)
        }

        if selectedID == root.id {
            selectedID = nil
        }
        if self.rootID == root.id {
            self.rootID = nil
        }

        root.children = []
        root.parent = nil
        root.previousSibling = nil
        root.nextSibling = nil
        entriesByID.removeValue(forKey: root.id)
        entriesByNodeID.removeValue(forKey: root.id.nodeID)
    }

    func reconcileSelectedID() {
        guard let selectedID, entriesByID[selectedID] == nil else {
            return
        }
        self.selectedID = nil
    }
}
