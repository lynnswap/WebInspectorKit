import Foundation
import Observation

@MainActor
@Observable
public final class DOMDocumentStore {
    public private(set) var rootEntry: DOMEntry?
    public private(set) weak var selectedEntry: DOMEntry?
    public private(set) var errorMessage: String?

    private var entriesByLocalID: [UInt64: DOMEntry] = [:]
    private var localIDsByObjectID: [ObjectIdentifier: UInt64] = [:]

    public init() {}

    package func setErrorMessage(_ message: String?) {
        errorMessage = message
    }

    package func clearSelection() {
        selectedEntry = nil
    }

    package func clearDocument() {
        replaceContents(selectedLocalID: nil) {}
    }

    package func replaceDocument(with snapshot: DOMGraphSnapshot) {
        let previousSelectedLocalID = selectedLocalID
        let nextSelectedLocalID = snapshot.selectedLocalID ?? previousSelectedLocalID
        replaceContents(selectedLocalID: nextSelectedLocalID) {
            rootEntry = buildSubtree(from: snapshot.root, parent: nil)
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

        reconcileSelectedEntry()
        if selectedEntry == nil, let previousSelectedLocalID {
            selectedEntry = entry(forLocalID: previousSelectedLocalID)
        }
    }

    package func applySelectionSnapshot(_ payload: DOMSelectionSnapshotPayload?) {
        if let previousSelectedEntry = selectedEntry, payload?.localID == nil {
            previousSelectedEntry.clearMatchedStyles()
        }

        guard let payload, let localID = payload.localID else {
            selectedEntry = nil
            return
        }

        let entry = entry(forLocalID: localID) ?? makePlaceholderEntry(localID: localID)
        entry.preview = payload.preview
        entry.path = payload.path
        if let selectorPath = payload.selectorPath {
            entry.selectorPath = selectorPath
        }
        entry.styleRevision = payload.styleRevision
        entry.attributes = normalizeAttributes(payload.attributes, backendNodeID: entry.backendNodeID)
        selectedEntry = entry
    }

    package func applySelectorPath(_ payload: DOMSelectorPathPayload) {
        guard
            let localID = payload.localID,
            let entry = entry(forLocalID: localID),
            selectedEntry === entry
        else {
            return
        }

        if entry.selectorPath != payload.selectorPath {
            entry.selectorPath = payload.selectorPath
        }
    }

    package func applySelectorPath(_ selectorPath: String, for entry: DOMEntry) {
        guard selectedEntry === entry, contains(entry) else {
            return
        }
        if entry.selectorPath != selectorPath {
            entry.selectorPath = selectorPath
        }
    }

    package func beginMatchedStylesLoading(for entry: DOMEntry) {
        guard selectedEntry === entry, contains(entry) else {
            return
        }

        entry.isLoadingMatchedStyles = true
        entry.matchedStyles = []
        entry.matchedStylesTruncated = false
        entry.blockedStylesheetCount = 0
    }

    package func applyMatchedStyles(_ payload: DOMMatchedStylesPayload, for entry: DOMEntry) {
        guard selectedEntry === entry, contains(entry) else {
            return
        }

        if let backendNodeID = entry.backendNodeID, backendNodeID != payload.nodeId {
            return
        }

        entry.matchedStyles = payload.rules
        entry.matchedStylesTruncated = payload.truncated
        entry.blockedStylesheetCount = payload.blockedStylesheetCount
        entry.isLoadingMatchedStyles = false
    }

    package func clearMatchedStyles(for entry: DOMEntry? = nil) {
        let resolvedEntry = entry ?? selectedEntry
        guard let resolvedEntry, contains(resolvedEntry) else {
            return
        }
        resolvedEntry.clearMatchedStyles()
    }

    package func updateSelectedAttribute(name: String, value: String) {
        guard let entry = selectedEntry, contains(entry) else {
            return
        }

        if let index = entry.attributes.firstIndex(where: { $0.name == name }) {
            entry.attributes[index].value = value
        } else {
            entry.attributes.append(
                DOMAttribute(nodeId: entry.backendNodeID, name: name, value: value)
            )
        }
    }

    package func removeSelectedAttribute(name: String) {
        guard let entry = selectedEntry, contains(entry) else {
            return
        }
        entry.attributes.removeAll { $0.name == name }
    }
}

private extension DOMDocumentStore {
    var selectedLocalID: UInt64? {
        guard let selectedEntry else {
            return nil
        }
        return localID(for: selectedEntry)
    }

    func replaceContents(
        selectedLocalID: UInt64?,
        build: () -> Void
    ) {
        entriesByLocalID.removeAll(keepingCapacity: true)
        localIDsByObjectID.removeAll(keepingCapacity: true)
        rootEntry = nil
        selectedEntry = nil
        errorMessage = nil
        build()
        if let selectedLocalID {
            selectedEntry = entry(forLocalID: selectedLocalID)
        }
        reconcileSelectedEntry()
    }

    private func localID(for entry: DOMEntry) -> UInt64? {
        localIDsByObjectID[ObjectIdentifier(entry)]
    }

    func entry(forLocalID localID: UInt64) -> DOMEntry? {
        entriesByLocalID[localID]
    }

    func contains(_ entry: DOMEntry) -> Bool {
        guard let localID = localID(for: entry) else {
            return false
        }
        return entriesByLocalID[localID] === entry
    }

    private func insert(_ entry: DOMEntry, for localID: UInt64) {
        entriesByLocalID[localID] = entry
        localIDsByObjectID[ObjectIdentifier(entry)] = localID
    }

    func removeEntry(_ entry: DOMEntry) {
        let objectID = ObjectIdentifier(entry)
        if let localID = localIDsByObjectID.removeValue(forKey: objectID) {
            entriesByLocalID.removeValue(forKey: localID)
        }
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
        let backendNodeID: Int?
        if localID <= UInt64(Int.max) {
            backendNodeID = Int(localID)
        } else {
            backendNodeID = nil
        }

        let entry = DOMEntry(
            backendNodeID: backendNodeID,
            nodeType: 1,
            nodeName: "",
            localName: "",
            nodeValue: "",
            attributes: [],
            childCount: 0
        )
        insert(entry, for: localID)
        return entry
    }

    @discardableResult
    func buildSubtree(from descriptor: DOMGraphNodeDescriptor, parent: DOMEntry?) -> DOMEntry {
        if let existing = entry(forLocalID: descriptor.localID) {
            removeSubtree(existing, removeFromParent: true)
        }

        let entry = DOMEntry(
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
        insert(entry, for: descriptor.localID)

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

        let hadLoadedChild = parent.children.contains { localID(for: $0) == node.localID }
        let previousChildCount = max(parent.childCount, parent.children.count)
        let inserted = buildSubtree(from: node, parent: parent)
        parent.children.removeAll { localID(for: $0) == node.localID }

        let insertionIndex: Int
        if previousLocalID == 0 {
            insertionIndex = 0
        } else if let previousLocalID,
                  let previousEntry = entry(forLocalID: previousLocalID),
                  let previousIndex = parent.children.firstIndex(where: { $0 === previousEntry }) {
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
        guard let parent = entry(forLocalID: parentLocalID) else {
            return
        }

        if let index = parent.children.firstIndex(where: { localID(for: $0) == nodeLocalID }) {
            let removed = parent.children.remove(at: index)
            parent.childCount = max(parent.children.count, parent.childCount - 1)
            relinkChildren(of: parent)
            removeSubtree(removed, removeFromParent: false)
            return
        }

        if let entry = entry(forLocalID: nodeLocalID) {
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
    }

    func applySetChildNodes(parentLocalID: UInt64, nodes: [DOMGraphNodeDescriptor]) {
        let parent: DOMEntry
        if let existingParent = entry(forLocalID: parentLocalID) {
            parent = existingParent
        } else if rootEntry == nil {
            let placeholderRoot = makePlaceholderEntry(localID: parentLocalID)
            rootEntry = placeholderRoot
            parent = placeholderRoot
        } else {
            return
        }

        let previousChildren = parent.children
        var nextChildren: [DOMEntry] = []
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
        if rootEntry == nil {
            rootEntry = buildSubtree(from: root, parent: nil)
            return
        }

        if let existing = entry(forLocalID: root.localID) {
            let parent = existing.parent
            let previousIndex = parent?.children.firstIndex(where: { $0 === existing })
            let previousParentChildCount = parent.map { max($0.childCount, $0.children.count) }
            let isReplacingRoot = rootEntry === existing
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
                rootEntry = replacement
            }
            return
        }

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

        if selectedEntry === root {
            selectedEntry = nil
        }
        if rootEntry === root {
            rootEntry = nil
        }

        root.children = []
        root.parent = nil
        root.previousSibling = nil
        root.nextSibling = nil
        removeEntry(root)
    }

    func reconcileSelectedEntry() {
        guard let currentSelection = selectedEntry else {
            return
        }
        guard let localID = localID(for: currentSelection), let resolvedEntry = entriesByLocalID[localID] else {
            selectedEntry = nil
            return
        }
        if resolvedEntry !== currentSelection {
            selectedEntry = resolvedEntry
        }
    }
}
