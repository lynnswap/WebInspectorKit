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
    case afterPseudoElement

    var countsTowardChildCount: Bool {
        switch self {
        case .regular, .contentDocument:
            return true
        case .shadowRoot, .templateContent, .beforePseudoElement, .afterPseudoElement:
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
    case structural(affectedLocalIDs: Set<UInt64>)
    case content(affectedLocalIDs: Set<UInt64>)
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
    package private(set) var rejectedStructuralMutationParentLocalIDs: Set<UInt64> = []
    @ObservationIgnored private var treeInvalidationHandlers: [UUID: @MainActor (DOMTreeInvalidation) -> Void] = [:]

    private var nodesByLocalID: [UInt64: DOMNodeModel] = [:]
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

    package func consumeRejectedStructuralMutationParentLocalIDs() -> Set<UInt64> {
        defer { rejectedStructuralMutationParentLocalIDs.removeAll(keepingCapacity: true) }
        return rejectedStructuralMutationParentLocalIDs
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

        let previousSelectedLocalID = selectedLocalID
        let previousSelectedNode = selectedNode
        var structuralLocalIDs = Set<UInt64>()
        var contentLocalIDs = Set<UInt64>()
        for event in bundle.events {
            switch event {
            case let .childNodeInserted(parentLocalID, previousLocalID, node):
                structuralLocalIDs.insert(parentLocalID)
                structuralLocalIDs.insert(node.localID)
                applyChildNodeInserted(parentLocalID: parentLocalID, previousLocalID: previousLocalID, node: node)
            case let .childNodeRemoved(parentLocalID, nodeLocalID):
                structuralLocalIDs.insert(parentLocalID)
                structuralLocalIDs.insert(nodeLocalID)
                applyChildNodeRemoved(parentLocalID: parentLocalID, nodeLocalID: nodeLocalID)
            case let .attributeModified(nodeLocalID, name, value, layoutFlags, isRendered):
                contentLocalIDs.insert(nodeLocalID)
                applyAttributeModified(
                    nodeLocalID: nodeLocalID,
                    name: name,
                    value: value,
                    layoutFlags: layoutFlags,
                    isRendered: isRendered
                )
            case let .attributeRemoved(nodeLocalID, name, layoutFlags, isRendered):
                contentLocalIDs.insert(nodeLocalID)
                applyAttributeRemoved(
                    nodeLocalID: nodeLocalID,
                    name: name,
                    layoutFlags: layoutFlags,
                    isRendered: isRendered
                )
            case let .characterDataModified(nodeLocalID, value, layoutFlags, isRendered):
                contentLocalIDs.insert(nodeLocalID)
                applyCharacterDataModified(
                    nodeLocalID: nodeLocalID,
                    value: value,
                    layoutFlags: layoutFlags,
                    isRendered: isRendered
                )
            case let .childNodeCountUpdated(nodeLocalID, childCount, layoutFlags, isRendered):
                contentLocalIDs.insert(nodeLocalID)
                applyChildNodeCountUpdated(
                    nodeLocalID: nodeLocalID,
                    childCount: childCount,
                    layoutFlags: layoutFlags,
                    isRendered: isRendered
                )
            case let .setChildNodes(parentLocalID, nodes):
                structuralLocalIDs.insert(parentLocalID)
                structuralLocalIDs.formUnion(nodes.map(\.localID))
                applySetChildNodes(parentLocalID: parentLocalID, nodes: nodes)
            case let .setDetachedRoots(nodes):
                structuralLocalIDs.formUnion(nodes.map(\.localID))
                applySetDetachedRoots(nodes)
            case let .replaceSubtree(root):
                structuralLocalIDs.insert(root.localID)
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
        treeRevision &+= 1
        if selectedNode !== previousSelectedNode
            || selectedNode.map({ contentLocalIDs.contains($0.localID) || structuralLocalIDs.contains($0.localID) }) == true {
            selectedNodeDetailRevision &+= 1
        }
        if !structuralLocalIDs.isEmpty {
            emitTreeInvalidation(.structural(affectedLocalIDs: structuralLocalIDs))
        } else if !contentLocalIDs.isEmpty {
            emitTreeInvalidation(.content(affectedLocalIDs: contentLocalIDs))
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
        if let previousSelectedNode = selectedNode, payload?.localID == nil {
            previousSelectedNode.clearSelectionProjectionState()
        }
        guard let payload, let localID = payload.localID else {
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
        node.path = payload.path
        if let selectorPath = payload.selectorPath {
            node.selectorPath = selectorPath
        }
        node.styleRevision = payload.styleRevision
        let didChangeTree = replaceAttributes(
            on: node,
            with: normalizeAttributes(payload.attributes, backendNodeID: node.backendNodeID)
        )
        selectedNode = node
        projectionRevision &+= 1
        selectionRevision &+= 1
        selectedNodeDetailRevision &+= 1
        if didChangeTree {
            treeRevision &+= 1
            emitTreeInvalidation(.content(affectedLocalIDs: [node.localID]))
        }
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
            emitTreeInvalidation(.content(affectedLocalIDs: [node.localID]))
        }
    }

    package func removeSelectedAttribute(name: String) {
        guard let node = selectedNode, contains(node) else {
            return
        }
        if removeAttributeValue(on: node, name: name) {
            selectedNodeDetailRevision &+= 1
            treeRevision &+= 1
            emitTreeInvalidation(.content(affectedLocalIDs: [node.localID]))
        }
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
        let didChange = setAttributeValue(on: node, name: name, value: value)
        if didChange {
            treeRevision &+= 1
            if selectedNode === node {
                selectedNodeDetailRevision &+= 1
            }
            emitTreeInvalidation(.content(affectedLocalIDs: [node.localID]))
        }
        return didChange
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
        let didChange = removeAttributeValue(on: node, name: name)
        if didChange {
            treeRevision &+= 1
            if selectedNode === node {
                selectedNodeDetailRevision &+= 1
            }
            emitTreeInvalidation(.content(affectedLocalIDs: [node.localID]))
        }
        return didChange
    }

    package var selectedLocalID: UInt64? {
        selectedNode?.localID
    }

    package func removeNode(id: DOMNodeModel.ID) {
        guard let node = node(id: id) else {
            return
        }
        removeSubtree(node, removeFromParent: true)
        treeRevision &+= 1
        selectedNodeDetailRevision &+= 1
        emitTreeInvalidation(.structural(affectedLocalIDs: [node.localID]))
    }
}

private extension DOMDocumentModel {
    func emitTreeInvalidation(_ invalidation: DOMTreeInvalidation) {
        for handler in treeInvalidationHandlers.values {
            handler(invalidation)
        }
    }

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
                return false
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
            pseudoType: descriptor.pseudoType,
            shadowRootType: descriptor.shadowRootType,
            attributes: normalizeAttributes(descriptor.attributes, backendNodeID: descriptor.backendNodeID),
            childCount: max(
                descriptor.childCount,
                descriptor.regularChildren.count,
                descriptor.contentDocument == nil ? 0 : 1
            ),
            childCountIsKnown: descriptor.childCountIsKnown,
            layoutFlags: descriptor.layoutFlags,
            isRendered: descriptor.isRendered
        )
        node.parent = parent
        insert(node, for: descriptor.localID)

        var regularChildren: [DOMNodeModel] = []
        regularChildren.reserveCapacity(descriptor.regularChildren.count)
        for childDescriptor in descriptor.regularChildren {
            let child = buildSubtree(from: childDescriptor, parent: node)
            regularChildren.append(child)
        }
        node.regularChildren = regularChildren
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
        if parent.afterPseudoElement === child {
            return .afterPseudoElement
        }
        return nil
    }

    func minimumLoadedChildCount(for parent: DOMNodeModel) -> Int {
        max(parent.regularChildren.count, parent.contentDocument == nil ? 0 : 1)
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
        case .afterPseudoElement:
            parent.afterPseudoElement = nil
        }
        return location
    }

    func detachChild(localID: UInt64, from parent: DOMNodeModel) -> (DOMNodeModel, DOMChildStorageLocation)? {
        if let child = parent.regularChildren.first(where: { $0.localID == localID }) {
            guard let location = detachChild(child, from: parent) else {
                return nil
            }
            return (child, location)
        }
        if let child = parent.contentDocument, child.localID == localID {
            guard let location = detachChild(child, from: parent) else {
                return nil
            }
            return (child, location)
        }
        if let child = parent.shadowRoots.first(where: { $0.localID == localID }) {
            guard let location = detachChild(child, from: parent) else {
                return nil
            }
            return (child, location)
        }
        if let child = parent.templateContent, child.localID == localID {
            guard let location = detachChild(child, from: parent) else {
                return nil
            }
            return (child, location)
        }
        if let child = parent.beforePseudoElement, child.localID == localID {
            guard let location = detachChild(child, from: parent) else {
                return nil
            }
            return (child, location)
        }
        if let child = parent.afterPseudoElement, child.localID == localID {
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
        case .afterPseudoElement:
            parent.afterPseudoElement = child
        case .none:
            parent.regularChildren.append(child)
        }
        child.parent = parent
    }

    func applyChildNodeInserted(parentLocalID: UInt64, previousLocalID: UInt64?, node descriptor: DOMGraphNodeDescriptor) {
        guard let parent = node(forLocalID: parentLocalID) else {
            flagRejectedStructuralMutation(
                parentLocalID: parentLocalID,
                reason: "childNodeInserted missing parent localID=\(parentLocalID) nodeLocalID=\(descriptor.localID)"
            )
            return
        }

        let hadLoadedChild = parent.regularChildren.contains { $0.localID == descriptor.localID }
        let previousChildCount = max(parent.childCount, parent.regularChildren.count)
        let inserted = buildSubtree(from: descriptor, parent: parent)
        parent.regularChildren.removeAll { $0.localID == descriptor.localID }

        let insertionIndex: Int
        if previousLocalID == 0 {
            insertionIndex = 0
        } else if let previousLocalID,
                  let previousNode = node(forLocalID: previousLocalID),
                  let previousIndex = parent.regularChildren.firstIndex(where: { $0 === previousNode }) {
            insertionIndex = previousIndex + 1
        } else {
            insertionIndex = parent.regularChildren.count
        }

        let boundedIndex = min(max(0, insertionIndex), parent.regularChildren.count)
        parent.regularChildren.insert(inserted, at: boundedIndex)
        if hadLoadedChild {
            parent.childCount = max(previousChildCount, parent.regularChildren.count)
        } else {
            parent.childCount = max(previousChildCount + 1, parent.regularChildren.count)
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

        if let (removed, removedLocation) = detachChild(localID: nodeLocalID, from: parent) {
            if removedLocation.countsTowardChildCount {
                parent.childCount = max(minimumLoadedChildCount(for: parent), parent.childCount - 1)
            } else {
                parent.childCount = max(parent.childCount, minimumLoadedChildCount(for: parent))
            }
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

        node.childCount = max(0, childCount, node.regularChildren.count, node.contentDocument == nil ? 0 : 1)
        node.childCountIsKnown = true
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
        parent.childCount = parent.regularChildren.count
        parent.childCountIsKnown = true
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
            let previousLocation = parent.flatMap { storageLocation(of: existing, in: $0) }
            let previousParentChildCount = parent.map { max($0.childCount, $0.regularChildren.count) }
            let isReplacingRoot = rootNode === existing
            removeSubtree(existing, removeFromParent: true, decrementParentChildCount: false)

            let replacement = buildSubtree(from: root, parent: parent)
            if let parent {
                insert(replacement, into: parent, at: previousLocation)
                if let previousParentChildCount {
                    parent.childCount = max(previousParentChildCount, parent.regularChildren.count)
                } else {
                    parent.childCount = max(parent.childCount, parent.regularChildren.count)
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
            let removedLocation = detachChild(root, from: parent)
            if decrementParentChildCount, removedLocation?.countsTowardChildCount == true {
                parent.childCount = max(minimumLoadedChildCount(for: parent), parent.childCount - 1)
            } else {
                parent.childCount = max(parent.childCount, minimumLoadedChildCount(for: parent))
            }
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

        root.regularChildren = []
        root.contentDocument = nil
        root.shadowRoots = []
        root.templateContent = nil
        root.beforePseudoElement = nil
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

    func flagRejectedStructuralMutation(parentLocalID: UInt64, reason: String) {
        rejectedStructuralMutationParentLocalIDs.insert(parentLocalID)
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
