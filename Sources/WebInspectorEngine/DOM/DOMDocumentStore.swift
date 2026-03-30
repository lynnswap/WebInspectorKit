import Foundation
import Observation

@MainActor
@Observable
public final class DOMGraphStore {
    public private(set) var entriesByID: [DOMEntryID: DOMEntry] = [:]
    public private(set) var rootID: DOMEntryID?
    public private(set) weak var selectedEntry: DOMEntry?
    public private(set) var documentGeneration: UInt64

    public init(documentGeneration: UInt64 = 1) {
        self.documentGeneration = max(1, documentGeneration)
    }

    public func entry(for id: DOMEntryID) -> DOMEntry? {
        entriesByID[id]
    }

    public func entry(forLocalID localID: UInt64) -> DOMEntry? {
        entriesByID[makeID(localID: localID)]
    }

    public func select(_ id: DOMEntryID?) {
        guard let id else {
            selectedEntry = nil
            return
        }
        selectedEntry = entriesByID[id]
    }

    public func select(localID: UInt64?) {
        guard let localID else {
            selectedEntry = nil
            return
        }
        select(makeID(localID: localID))
    }

    public func resetForDocumentUpdate() {
        documentGeneration &+= 1
        if documentGeneration == 0 {
            documentGeneration = 1
        }

        entriesByID.removeAll(keepingCapacity: true)
        rootID = nil
        selectedEntry = nil
    }

    public func applySnapshot(_ snapshot: DOMGraphSnapshot) {
        let previousSelectedLocalID = selectedEntry?.id.localID

        entriesByID.removeAll(keepingCapacity: true)
        let root = buildSubtree(from: snapshot.root, parent: nil)
        rootID = root.id

        if let selectedLocalID = snapshot.selectedLocalID {
            selectedEntry = entry(forLocalID: selectedLocalID)
        } else if let previousSelectedLocalID {
            selectedEntry = entry(forLocalID: previousSelectedLocalID)
        } else {
            selectedEntry = nil
        }

        reconcileSelectedEntry()
    }

    public func applyMutationBundle(_ bundle: DOMGraphMutationBundle) {
        guard !bundle.events.isEmpty else {
            return
        }

        let previousSelectedID = selectedEntry?.id
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
                resetForDocumentUpdate()
            }
        }

        reconcileSelectedEntry()
        if selectedEntry == nil,
           let previousSelectedID,
           let previousSelectedEntry = entriesByID[previousSelectedID] {
            selectedEntry = previousSelectedEntry
        }
    }

    public func applySelectionSnapshot(_ payload: DOMSelectionSnapshotPayload?) {
        let previousSelectedID = selectedEntry?.id
        guard let payload, let localID = payload.localID else {
            if let previousSelectedID, let previousSelected = entriesByID[previousSelectedID] {
                previousSelected.clearMatchedStyles()
                entriesByID[previousSelectedID] = previousSelected
            }
            selectedEntry = nil
            return
        }

        let entryID = makeID(localID: localID)
        let entry = entriesByID[entryID] ?? makePlaceholderEntry(localID: localID)
        entry.preview = payload.preview
        entry.path = payload.path
        entry.selectorPath = payload.selectorPath
        entry.styleRevision = payload.styleRevision
        entry.attributes = normalizeAttributes(payload.attributes, backendNodeID: entry.backendNodeID)

        entriesByID[entryID] = entry
        selectedEntry = entry
    }

    public func applySelectorPath(_ payload: DOMSelectorPathPayload) {
        guard let localID = payload.localID else {
            return
        }

        let entryID = makeID(localID: localID)
        guard selectedEntry?.id == entryID, let entry = entriesByID[entryID] else {
            return
        }

        if entry.selectorPath != payload.selectorPath {
            entry.selectorPath = payload.selectorPath
            entriesByID[entryID] = entry
        }
    }

    public func beginMatchedStylesLoading(for localID: UInt64) {
        let entryID = makeID(localID: localID)
        guard selectedEntry?.id == entryID, let entry = entriesByID[entryID] else {
            return
        }

        entry.isLoadingMatchedStyles = true
        entry.matchedStyles = []
        entry.matchedStylesTruncated = false
        entry.blockedStylesheetCount = 0
        entriesByID[entryID] = entry
    }

    public func applyMatchedStyles(_ payload: DOMMatchedStylesPayload, for localID: UInt64) {
        let entryID = makeID(localID: localID)
        guard selectedEntry?.id == entryID, let entry = entriesByID[entryID] else {
            return
        }

        if let backendNodeID = entry.backendNodeID, backendNodeID != payload.nodeId {
            return
        }

        entry.matchedStyles = payload.rules
        entry.matchedStylesTruncated = payload.truncated
        entry.blockedStylesheetCount = payload.blockedStylesheetCount
        entry.isLoadingMatchedStyles = false
        entriesByID[entryID] = entry
    }

    public func clearMatchedStyles(for localID: UInt64?) {
        let resolvedID: DOMEntryID?
        if let localID {
            resolvedID = makeID(localID: localID)
        } else {
            resolvedID = selectedEntry?.id
        }

        guard let resolvedID, let entry = entriesByID[resolvedID] else {
            return
        }

        entry.clearMatchedStyles()
        entriesByID[resolvedID] = entry
    }

    public func updateSelectedAttribute(name: String, value: String) {
        guard let selectedEntryID = selectedEntry?.id, let entry = entriesByID[selectedEntryID] else {
            return
        }

        if let index = entry.attributes.firstIndex(where: { $0.name == name }) {
            entry.attributes[index].value = value
        } else {
            entry.attributes.append(
                DOMAttribute(nodeId: entry.backendNodeID, name: name, value: value)
            )
        }

        entriesByID[selectedEntryID] = entry
    }

    public func removeSelectedAttribute(name: String) {
        guard let selectedEntryID = selectedEntry?.id, let entry = entriesByID[selectedEntryID] else {
            return
        }

        entry.attributes.removeAll { $0.name == name }
        entriesByID[selectedEntryID] = entry
    }
}

private extension DOMGraphStore {
    func makeID(localID: UInt64) -> DOMEntryID {
        DOMEntryID(documentGeneration: documentGeneration, localID: localID)
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

    func makePlaceholderEntry(localID: UInt64) -> DOMEntry {
        let entryID = makeID(localID: localID)
        let backendNodeID: Int?
        if localID <= UInt64(Int.max) {
            backendNodeID = Int(localID)
        } else {
            backendNodeID = nil
        }

        return DOMEntry(
            id: entryID,
            backendNodeID: backendNodeID,
            nodeType: 1,
            nodeName: "",
            localName: "",
            nodeValue: "",
            attributes: [],
            childCount: 0
        )
    }

    @discardableResult
    func buildSubtree(from descriptor: DOMGraphNodeDescriptor, parent: DOMEntry?) -> DOMEntry {
        let entryID = makeID(localID: descriptor.localID)
        if let existing = entriesByID[entryID] {
            removeSubtree(existing, removeFromParent: true)
        }

        let entry = DOMEntry(
            id: entryID,
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
        entry.parent = parent
        entriesByID[entryID] = entry

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

    func applyChildNodeInserted(parentLocalID: UInt64, previousLocalID: UInt64?, node: DOMGraphNodeDescriptor) {
        guard let parent = entry(forLocalID: parentLocalID) else {
            return
        }

        let inserted = buildSubtree(from: node, parent: parent)
        let wasLoadedChild = parent.children.contains { $0.id == inserted.id }
        let previousChildCount = max(parent.childCount, parent.children.count)
        parent.children.removeAll { $0.id == inserted.id }

        let insertionIndex: Int
        if previousLocalID == 0 {
            insertionIndex = 0
        } else if let previousLocalID, let previousEntry = entry(forLocalID: previousLocalID),
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
    }

    func applyChildNodeRemoved(parentLocalID: UInt64, nodeLocalID: UInt64) {
        guard let parent = entry(forLocalID: parentLocalID) else {
            return
        }

        let nodeID = makeID(localID: nodeLocalID)
        if let index = parent.children.firstIndex(where: { $0.id == nodeID }) {
            let removed = parent.children.remove(at: index)
            parent.childCount = max(parent.children.count, parent.childCount - 1)
            relinkChildren(of: parent)
            entriesByID[parent.id] = parent
            removeSubtree(removed, removeFromParent: false)
            return
        }

        if let entry = entriesByID[nodeID] {
            removeSubtree(entry, removeFromParent: true)
        }
    }

    func applyAttributeModified(
        nodeLocalID: UInt64,
        name: String,
        value: String,
        layoutFlags: [String]?,
        isRendered: Bool?
    ) {
        guard let entry = entry(forLocalID: nodeLocalID) else {
            return
        }

        if let index = entry.attributes.firstIndex(where: { $0.name == name }) {
            entry.attributes[index].value = value
        } else {
            entry.attributes.append(DOMAttribute(nodeId: entry.backendNodeID, name: name, value: value))
        }

        applyLayout(into: entry, layoutFlags: layoutFlags, isRendered: isRendered)
        entriesByID[entry.id] = entry
    }

    func applyAttributeRemoved(
        nodeLocalID: UInt64,
        name: String,
        layoutFlags: [String]?,
        isRendered: Bool?
    ) {
        guard let entry = entry(forLocalID: nodeLocalID) else {
            return
        }

        entry.attributes.removeAll { $0.name == name }
        applyLayout(into: entry, layoutFlags: layoutFlags, isRendered: isRendered)
        entriesByID[entry.id] = entry
    }

    func applyCharacterDataModified(
        nodeLocalID: UInt64,
        value: String,
        layoutFlags: [String]?,
        isRendered: Bool?
    ) {
        guard let entry = entry(forLocalID: nodeLocalID) else {
            return
        }

        entry.nodeValue = value
        applyLayout(into: entry, layoutFlags: layoutFlags, isRendered: isRendered)
        entriesByID[entry.id] = entry
    }

    func applyChildNodeCountUpdated(
        nodeLocalID: UInt64,
        childCount: Int,
        layoutFlags: [String]?,
        isRendered: Bool?
    ) {
        guard let entry = entry(forLocalID: nodeLocalID) else {
            return
        }

        entry.childCount = max(0, childCount)
        applyLayout(into: entry, layoutFlags: layoutFlags, isRendered: isRendered)
        entriesByID[entry.id] = entry
    }

    func applySetChildNodes(parentLocalID: UInt64, nodes: [DOMGraphNodeDescriptor]) {
        guard let parent = entry(forLocalID: parentLocalID) else {
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
    }

    func applyReplaceSubtree(_ root: DOMGraphNodeDescriptor) {
        let rootID = makeID(localID: root.localID)

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
            } else if isReplacingRoot {
                self.rootID = replacement.id
            }
            return
        }

        // requestChildNodes may return after the target disappeared; ignore stale subtree updates.
        return
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
        }

        for child in root.children {
            removeSubtree(child, removeFromParent: false)
        }

        if selectedEntry?.id == root.id {
            selectedEntry = nil
        }
        if self.rootID == root.id {
            self.rootID = nil
        }

        root.children = []
        root.parent = nil
        root.previousSibling = nil
        root.nextSibling = nil
        entriesByID.removeValue(forKey: root.id)
    }

    func reconcileSelectedEntry() {
        guard let currentSelection = selectedEntry else {
            return
        }
        guard let resolvedEntry = entriesByID[currentSelection.id] else {
            selectedEntry = nil
            return
        }
        if resolvedEntry !== currentSelection {
            selectedEntry = resolvedEntry
        }
    }
}
