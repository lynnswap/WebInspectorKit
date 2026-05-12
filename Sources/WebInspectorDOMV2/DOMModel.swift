import Observation

@MainActor
@Observable
package final class ProtocolTarget {
    package typealias ID = ProtocolTargetIdentifier

    package let id: ID
    package var kind: ProtocolTargetKind
    package var frameID: DOMFrame.ID?
    package var parentFrameID: DOMFrame.ID?
    package var currentDocumentID: DOMDocument.ID?

    package init(
        id: ID,
        kind: ProtocolTargetKind,
        frameID: DOMFrame.ID?,
        parentFrameID: DOMFrame.ID?
    ) {
        self.id = id
        self.kind = kind
        self.frameID = frameID
        self.parentFrameID = parentFrameID
    }
}

@MainActor
@Observable
package final class DOMPage {
    package typealias ID = ProtocolTarget.ID

    package let id: ID
    package let mainTargetID: ProtocolTarget.ID
    package let mainFrameID: DOMFrame.ID
    package var navigationGeneration: UInt64

    package init(id: ID, mainTargetID: ProtocolTarget.ID, mainFrameID: DOMFrame.ID) {
        self.id = id
        self.mainTargetID = mainTargetID
        self.mainFrameID = mainFrameID
        self.navigationGeneration = 0
    }
}

@MainActor
@Observable
package final class DOMFrame {
    package typealias ID = DOMFrameIdentifier

    package let id: ID
    package var parentFrameID: ID?
    package var childFrameIDs: Set<ID>
    package var ownerNodeID: DOMNode.ID?
    package var targetID: ProtocolTarget.ID?
    package var currentDocumentID: DOMDocument.ID?

    package init(id: ID, parentFrameID: ID? = nil) {
        self.id = id
        self.parentFrameID = parentFrameID
        self.childFrameIDs = []
    }
}

@MainActor
@Observable
package final class DOMDocument {
    package typealias ID = DOMDocumentIdentifier

    package let id: ID
    package let targetID: ProtocolTarget.ID
    package let generation: DOMDocumentGeneration
    package let rootNodeID: DOMNode.ID

    package init(id: ID, targetID: ProtocolTarget.ID, generation: DOMDocumentGeneration, rootNodeID: DOMNode.ID) {
        self.id = id
        self.targetID = targetID
        self.generation = generation
        self.rootNodeID = rootNodeID
    }
}

package enum DOMRegularChildState {
    case unrequested(count: Int)
    case loaded([DOMNode.ID])

    package var knownCount: Int {
        switch self {
        case let .unrequested(count):
            max(0, count)
        case let .loaded(children):
            children.count
        }
    }

    package var loadedChildren: [DOMNode.ID] {
        switch self {
        case .unrequested:
            []
        case let .loaded(children):
            children
        }
    }
}

@MainActor
@Observable
package final class DOMNode {
    package typealias ID = DOMNodeIdentifier

    package let id: ID
    package let protocolNodeID: DOMProtocolNodeID
    package var nodeType: DOMNodeType
    package var nodeName: String
    package var localName: String
    package var nodeValue: String
    package var frameID: DOMFrame.ID?
    package var attributes: [DOMAttribute]
    package var parentID: ID?
    package var previousSiblingID: ID?
    package var nextSiblingID: ID?
    package var regularChildren: DOMRegularChildState
    package var contentDocumentID: ID?
    package var shadowRootIDs: [ID]
    package var templateContentID: ID?
    package var beforePseudoElementID: ID?
    package var otherPseudoElementIDs: [ID]
    package var afterPseudoElementID: ID?
    package var pseudoType: String?
    package var shadowRootType: String?

    package init(id: ID, payload: DOMNodePayload, parentID: ID?) {
        self.id = id
        self.protocolNodeID = payload.nodeID
        self.nodeType = payload.nodeType
        self.nodeName = payload.nodeName
        self.localName = payload.localName
        self.nodeValue = payload.nodeValue
        self.frameID = payload.frameID
        self.attributes = payload.attributes
        self.parentID = parentID
        self.previousSiblingID = nil
        self.nextSiblingID = nil
        self.regularChildren = .unrequested(count: 0)
        self.contentDocumentID = nil
        self.shadowRootIDs = []
        self.templateContentID = nil
        self.beforePseudoElementID = nil
        self.otherPseudoElementIDs = []
        self.afterPseudoElementID = nil
        self.pseudoType = payload.pseudoType
        self.shadowRootType = payload.shadowRootType
    }

    package var isFrameOwner: Bool {
        let lowercasedName = nodeName.lowercased()
        return lowercasedName == "iframe" || lowercasedName == "frame"
    }

    package var protocolEffectiveChildren: [ID] {
        if let contentDocumentID {
            return [contentDocumentID]
        }
        return shadowRootIDs + regularChildren.loadedChildren
    }

    package var protocolOwnedChildren: [ID] {
        var children = regularChildren.loadedChildren
        if let contentDocumentID {
            children.append(contentDocumentID)
        }
        children.append(contentsOf: shadowRootIDs)
        if let templateContentID {
            children.append(templateContentID)
        }
        if let beforePseudoElementID {
            children.append(beforePseudoElementID)
        }
        children.append(contentsOf: otherPseudoElementIDs)
        if let afterPseudoElementID {
            children.append(afterPseudoElementID)
        }
        return children
    }
}

package struct DOMSelectionRequest {
    package var id: SelectionRequestIdentifier
    package var targetID: ProtocolTarget.ID
    package var documentID: DOMDocument.ID
}

package struct DOMSelection {
    package var selectedNodeID: DOMNode.ID?
    package var pendingRequest: DOMSelectionRequest?
    package var failure: SelectionResolutionFailure?

    package init() {
        selectedNodeID = nil
        pendingRequest = nil
        failure = nil
    }
}

@MainActor
@Observable
package final class DOMSession {
    package private(set) var currentPage: DOMPage?

    private var targetsByID: [ProtocolTarget.ID: ProtocolTarget]
    private var framesByID: [DOMFrame.ID: DOMFrame]
    private var targetIDByExecutionContextID: [ExecutionContextID: ProtocolTarget.ID]
    private var documentsByID: [DOMDocument.ID: DOMDocument]
    private var nodesByID: [DOMNode.ID: DOMNode]
    private var currentNodeIDByKey: [DOMNodeCurrentKey: DOMNode.ID]
    private var nextGenerationByTargetID: [ProtocolTarget.ID: UInt64]
    private var nextSelectionRequestRawID: UInt64
    private var selection: DOMSelection

    package init() {
        targetsByID = [:]
        framesByID = [:]
        targetIDByExecutionContextID = [:]
        documentsByID = [:]
        nodesByID = [:]
        currentNodeIDByKey = [:]
        nextGenerationByTargetID = [:]
        nextSelectionRequestRawID = 0
        selection = DOMSelection()
    }

    package func applyTargetCreated(
        _ record: ProtocolTargetRecord,
        makeCurrentMainPage: Bool = false
    ) {
        let target = targetsByID[record.id] ?? ProtocolTarget(
            id: record.id,
            kind: record.kind,
            frameID: record.frameID,
            parentFrameID: record.parentFrameID
        )
        target.kind = record.kind
        target.frameID = record.frameID
        target.parentFrameID = record.parentFrameID
        targetsByID[record.id] = target

        if let frameID = record.frameID {
            let frame = frameWithID(frameID, parentFrameID: record.parentFrameID)
            frame.targetID = record.id
            target.frameID = frameID
        }

        guard record.kind == .page || makeCurrentMainPage else {
            return
        }

        let mainFrameID = record.frameID ?? DOMFrame.ID("main:\(record.id.rawValue)")
        let mainFrame = frameWithID(mainFrameID, parentFrameID: nil)
        mainFrame.targetID = record.id
        target.frameID = mainFrameID
        currentPage = DOMPage(id: record.id, mainTargetID: record.id, mainFrameID: mainFrameID)
    }

    package func applyTargetDestroyed(_ targetID: ProtocolTarget.ID) {
        guard let target = targetsByID.removeValue(forKey: targetID) else {
            return
        }
        targetIDByExecutionContextID = targetIDByExecutionContextID.filter { $0.value != targetID }
        if let documentID = target.currentDocumentID {
            removeDocument(documentID)
        }
        if let frameID = target.frameID, framesByID[frameID]?.targetID == targetID {
            framesByID[frameID]?.targetID = nil
            framesByID[frameID]?.currentDocumentID = nil
        }
        if currentPage?.mainTargetID == targetID {
            currentPage = nil
        }
        reconcileSelection()
    }

    package func applyExecutionContextCreated(_ id: ExecutionContextID, targetID: ProtocolTarget.ID) {
        guard targetsByID[targetID] != nil else {
            return
        }
        targetIDByExecutionContextID[id] = targetID
    }

    @discardableResult
    package func replaceDocumentRoot(_ root: DOMNodePayload, targetID: ProtocolTarget.ID) -> DOMNode.ID {
        guard let target = targetsByID[targetID] else {
            preconditionFailure("replaceDocumentRoot requires a known ProtocolTarget")
        }
        if let currentDocumentID = target.currentDocumentID {
            removeDocument(currentDocumentID)
        }

        let generation = nextGeneration(for: targetID)
        let documentID = DOMDocument.ID(targetID: targetID, generation: generation)
        let rootNodeID = buildSubtree(root, documentID: documentID, parentID: nil)
        let document = DOMDocument(id: documentID, targetID: targetID, generation: generation, rootNodeID: rootNodeID)
        documentsByID[documentID] = document
        target.currentDocumentID = documentID

        if let frameID = target.frameID {
            framesByID[frameID]?.currentDocumentID = documentID
        }
        if currentPage?.mainTargetID == targetID {
            currentPage?.navigationGeneration &+= 1
            framesByID[currentPage!.mainFrameID]?.currentDocumentID = documentID
        }

        reconcileSelection()
        return rootNodeID
    }

    package func applySetChildNodes(parent nodeID: DOMNode.ID, children payloads: [DOMNodePayload]) {
        guard let parent = nodesByID[nodeID] else {
            return
        }
        for childID in parent.regularChildren.loadedChildren {
            removeNodeSubtree(childID, detachFromParent: false)
        }
        parent.regularChildren = .loaded(
            payloads.map {
                buildSubtree($0, documentID: nodeID.documentID, parentID: nodeID)
            }
        )
        relinkProtocolEffectiveChildren(of: parent)
        reconcileSelection()
    }

    @discardableResult
    package func applyChildInserted(
        parent parentID: DOMNode.ID,
        previousSibling previousSiblingID: DOMNode.ID?,
        child payload: DOMNodePayload
    ) -> DOMNode.ID? {
        guard let parent = nodesByID[parentID] else {
            return nil
        }
        let childID = buildSubtree(payload, documentID: parentID.documentID, parentID: parentID)
        var children = parent.regularChildren.loadedChildren.filter { $0 != childID }
        if let previousSiblingID,
           let previousIndex = children.firstIndex(of: previousSiblingID) {
            children.insert(childID, at: children.index(after: previousIndex))
        } else {
            children.insert(childID, at: 0)
        }
        parent.regularChildren = .loaded(children)
        relinkProtocolEffectiveChildren(of: parent)
        reconcileSelection()
        return childID
    }

    package func applyNodeRemoved(_ nodeID: DOMNode.ID) {
        removeNodeSubtree(nodeID, detachFromParent: true)
        reconcileSelection()
    }

    package func resolveInspectSelection(
        remoteObject: RemoteObject
    ) -> Result<DOMCommandIntent, SelectionResolutionFailure> {
        guard remoteObject.objectID.isEmpty == false else {
            return failSelection(.missingObjectID)
        }
        guard let executionContextID = remoteObject.injectedScriptID else {
            return failSelection(.missingInjectedScriptID)
        }
        guard let targetID = targetIDByExecutionContextID[executionContextID] else {
            return failSelection(.unknownExecutionContext(executionContextID))
        }
        guard let documentID = targetsByID[targetID]?.currentDocumentID else {
            return failSelection(.missingCurrentDocument(targetID))
        }

        nextSelectionRequestRawID &+= 1
        let requestID = SelectionRequestIdentifier(nextSelectionRequestRawID)
        selection.pendingRequest = DOMSelectionRequest(id: requestID, targetID: targetID, documentID: documentID)
        selection.failure = nil
        return .success(.requestNode(selectionRequestID: requestID, targetID: targetID, objectID: remoteObject.objectID))
    }

    package func applyRequestNodeResult(
        selectionRequestID: SelectionRequestIdentifier,
        targetID: ProtocolTarget.ID,
        nodeID: DOMProtocolNodeID
    ) -> Result<DOMNode.ID, SelectionResolutionFailure> {
        guard let pendingRequest = selection.pendingRequest,
              pendingRequest.id == selectionRequestID else {
            return failSelection(
                .staleSelectionRequest(expected: selection.pendingRequest?.id, received: selectionRequestID),
                clearSelected: false
            )
        }
        guard pendingRequest.targetID == targetID else {
            return failSelection(.targetMismatch(expected: pendingRequest.targetID, received: targetID))
        }
        let currentDocumentID = targetsByID[targetID]?.currentDocumentID
        guard currentDocumentID == pendingRequest.documentID else {
            return failSelection(
                .staleDocument(expected: pendingRequest.documentID, actual: currentDocumentID),
                clearSelected: false
            )
        }

        let key = DOMNodeCurrentKey(targetID: targetID, nodeID: nodeID)
        guard let selectedNodeID = currentNodeIDByKey[key],
              selectedNodeID.documentID == pendingRequest.documentID else {
            return failSelection(.unresolvedNode(key))
        }

        selection.selectedNodeID = selectedNodeID
        selection.pendingRequest = nil
        selection.failure = nil
        return .success(selectedNodeID)
    }

    package func treeProjection(rootTargetID: ProtocolTarget.ID) -> DOMTreeProjection {
        var rows: [DOMTreeRow] = []
        var visited = Set<DOMNode.ID>()
        if let documentID = targetsByID[rootTargetID]?.currentDocumentID,
           let rootNodeID = documentsByID[documentID]?.rootNodeID {
            appendProjectionRows(rootNodeID, depth: 0, visited: &visited, rows: &rows)
        }
        return DOMTreeProjection(rows: rows)
    }

    package func elementDetailSnapshot() -> DOMElementDetailSnapshot? {
        guard let selectedNodeID = selection.selectedNodeID,
              let node = nodesByID[selectedNodeID] else {
            return nil
        }
        return DOMElementDetailSnapshot(
            nodeID: selectedNodeID,
            nodeName: node.nodeName,
            attributes: node.attributes
        )
    }

    package func snapshot() -> DOMSessionSnapshot {
        DOMSessionSnapshot(
            currentPage: currentPage.map {
                DOMPageSnapshot(
                    id: $0.id,
                    mainTargetID: $0.mainTargetID,
                    mainFrameID: $0.mainFrameID,
                    navigationGeneration: $0.navigationGeneration
                )
            },
            targetsByID: targetsByID.mapValues {
                ProtocolTargetSnapshot(
                    id: $0.id,
                    kind: $0.kind,
                    frameID: $0.frameID,
                    parentFrameID: $0.parentFrameID,
                    currentDocumentID: $0.currentDocumentID
                )
            },
            framesByID: framesByID.mapValues {
                DOMFrameSnapshot(
                    id: $0.id,
                    parentFrameID: $0.parentFrameID,
                    childFrameIDs: $0.childFrameIDs,
                    ownerNodeID: $0.ownerNodeID,
                    targetID: $0.targetID,
                    currentDocumentID: $0.currentDocumentID
                )
            },
            documentsByID: documentsByID.mapValues {
                DOMDocumentSnapshot(
                    id: $0.id,
                    targetID: $0.targetID,
                    generation: $0.generation,
                    rootNodeID: $0.rootNodeID
                )
            },
            nodesByID: nodesByID.mapValues { node in
                DOMNodeSnapshot(
                    id: node.id,
                    protocolNodeID: node.protocolNodeID,
                    nodeType: node.nodeType,
                    nodeName: node.nodeName,
                    localName: node.localName,
                    nodeValue: node.nodeValue,
                    frameID: node.frameID,
                    attributes: node.attributes,
                    parentID: node.parentID,
                    previousSiblingID: node.previousSiblingID,
                    nextSiblingID: node.nextSiblingID,
                    regularChildren: snapshotRegularChildren(node.regularChildren),
                    contentDocumentID: node.contentDocumentID,
                    shadowRootIDs: node.shadowRootIDs,
                    templateContentID: node.templateContentID,
                    beforePseudoElementID: node.beforePseudoElementID,
                    otherPseudoElementIDs: node.otherPseudoElementIDs,
                    afterPseudoElementID: node.afterPseudoElementID,
                    pseudoType: node.pseudoType,
                    shadowRootType: node.shadowRootType
                )
            },
            currentNodeIDByKey: currentNodeIDByKey,
            selection: DOMSelectionSnapshot(
                selectedNodeID: selection.selectedNodeID,
                pendingRequest: selection.pendingRequest.map {
                    SelectionRequestSnapshot(id: $0.id, targetID: $0.targetID, documentID: $0.documentID)
                },
                failure: selection.failure
            )
        )
    }

    private func frameWithID(_ frameID: DOMFrame.ID, parentFrameID: DOMFrame.ID?) -> DOMFrame {
        let frame = framesByID[frameID] ?? DOMFrame(id: frameID, parentFrameID: parentFrameID)
        frame.parentFrameID = parentFrameID
        framesByID[frameID] = frame
        if let parentFrameID {
            let parent = frameWithID(parentFrameID, parentFrameID: nil)
            parent.childFrameIDs.insert(frameID)
        }
        return frame
    }

    private func nextGeneration(for targetID: ProtocolTarget.ID) -> DOMDocumentGeneration {
        let next = (nextGenerationByTargetID[targetID] ?? 0) + 1
        nextGenerationByTargetID[targetID] = next
        return DOMDocumentGeneration(next)
    }

    private func buildSubtree(
        _ payload: DOMNodePayload,
        documentID: DOMDocument.ID,
        parentID: DOMNode.ID?
    ) -> DOMNode.ID {
        let nodeID = DOMNode.ID(documentID: documentID, nodeID: payload.nodeID)
        let currentKey = DOMNodeCurrentKey(targetID: documentID.targetID, nodeID: payload.nodeID)
        if let existingNodeID = currentNodeIDByKey[currentKey], existingNodeID != nodeID {
            removeNodeSubtree(existingNodeID, detachFromParent: true)
        }

        let node = DOMNode(id: nodeID, payload: payload, parentID: parentID)
        nodesByID[nodeID] = node
        currentNodeIDByKey[currentKey] = nodeID

        switch payload.regularChildren {
        case let .unrequested(count):
            node.regularChildren = .unrequested(count: count)
        case let .loaded(children):
            node.regularChildren = .loaded(
                children.map {
                    buildSubtree($0, documentID: documentID, parentID: nodeID)
                }
            )
        }

        node.contentDocumentID = payload.contentDocument.first.map {
            buildSubtree($0, documentID: documentID, parentID: nodeID)
        }
        node.shadowRootIDs = payload.shadowRoots.map {
            buildSubtree($0, documentID: documentID, parentID: nodeID)
        }
        node.templateContentID = payload.templateContent.first.map {
            buildSubtree($0, documentID: documentID, parentID: nodeID)
        }
        node.beforePseudoElementID = payload.beforePseudoElement.first.map {
            buildSubtree($0, documentID: documentID, parentID: nodeID)
        }
        node.otherPseudoElementIDs = payload.otherPseudoElements.map {
            buildSubtree($0, documentID: documentID, parentID: nodeID)
        }
        node.afterPseudoElementID = payload.afterPseudoElement.first.map {
            buildSubtree($0, documentID: documentID, parentID: nodeID)
        }

        if node.isFrameOwner, let frameID = node.frameID {
            let frame = frameWithID(frameID, parentFrameID: nil)
            frame.ownerNodeID = nodeID
        }

        relinkProtocolEffectiveChildren(of: node)
        return nodeID
    }

    private func removeDocument(_ documentID: DOMDocument.ID) {
        guard let document = documentsByID.removeValue(forKey: documentID) else {
            return
        }
        removeNodeSubtree(document.rootNodeID, detachFromParent: false)
    }

    private func removeNodeSubtree(_ nodeID: DOMNode.ID, detachFromParent: Bool) {
        guard let node = nodesByID[nodeID] else {
            return
        }
        if detachFromParent {
            detachNode(nodeID, from: node.parentID)
        }
        for childID in node.protocolOwnedChildren {
            removeNodeSubtree(childID, detachFromParent: false)
        }
        if node.isFrameOwner,
           let frameID = node.frameID,
           framesByID[frameID]?.ownerNodeID == nodeID {
            framesByID[frameID]?.ownerNodeID = nil
        }
        let currentKey = DOMNodeCurrentKey(targetID: nodeID.documentID.targetID, nodeID: node.protocolNodeID)
        if currentNodeIDByKey[currentKey] == nodeID {
            currentNodeIDByKey.removeValue(forKey: currentKey)
        }
        nodesByID.removeValue(forKey: nodeID)
    }

    private func detachNode(_ nodeID: DOMNode.ID, from parentID: DOMNode.ID?) {
        guard let parentID, let parent = nodesByID[parentID] else {
            return
        }
        parent.regularChildren = .loaded(parent.regularChildren.loadedChildren.filter { $0 != nodeID })
        if parent.contentDocumentID == nodeID {
            parent.contentDocumentID = nil
        }
        parent.shadowRootIDs.removeAll { $0 == nodeID }
        if parent.templateContentID == nodeID {
            parent.templateContentID = nil
        }
        if parent.beforePseudoElementID == nodeID {
            parent.beforePseudoElementID = nil
        }
        parent.otherPseudoElementIDs.removeAll { $0 == nodeID }
        if parent.afterPseudoElementID == nodeID {
            parent.afterPseudoElementID = nil
        }
        relinkProtocolEffectiveChildren(of: parent)
    }

    private func relinkProtocolEffectiveChildren(of parent: DOMNode) {
        let children = parent.protocolEffectiveChildren
        for (index, childID) in children.enumerated() {
            guard let child = nodesByID[childID] else {
                continue
            }
            child.parentID = parent.id
            child.previousSiblingID = index > 0 ? children[index - 1] : nil
            child.nextSiblingID = index + 1 < children.count ? children[index + 1] : nil
        }
    }

    private func projectedVisibleChildren(of node: DOMNode) -> [DOMNode.ID] {
        var children: [DOMNode.ID] = []
        if let templateContentID = node.templateContentID {
            children.append(templateContentID)
        }
        if let beforePseudoElementID = node.beforePseudoElementID {
            children.append(beforePseudoElementID)
        }
        children.append(contentsOf: node.otherPseudoElementIDs)
        children.append(contentsOf: projectedEffectiveChildren(of: node))
        if let afterPseudoElementID = node.afterPseudoElementID {
            children.append(afterPseudoElementID)
        }
        return children
    }

    private func projectedEffectiveChildren(of node: DOMNode) -> [DOMNode.ID] {
        if node.isFrameOwner,
           let frameID = node.frameID,
           let documentID = framesByID[frameID]?.currentDocumentID,
           let rootNodeID = documentsByID[documentID]?.rootNodeID {
            return [rootNodeID]
        }
        if let contentDocumentID = node.contentDocumentID {
            return [contentDocumentID]
        }
        return node.shadowRootIDs + node.regularChildren.loadedChildren
    }

    private func appendProjectionRows(
        _ nodeID: DOMNode.ID,
        depth: Int,
        visited: inout Set<DOMNode.ID>,
        rows: inout [DOMTreeRow]
    ) {
        guard visited.insert(nodeID).inserted,
              let node = nodesByID[nodeID] else {
            return
        }
        let visibleChildren = projectedVisibleChildren(of: node)
        rows.append(
            DOMTreeRow(
                nodeID: nodeID,
                depth: depth,
                nodeName: node.nodeName,
                isSelected: selection.selectedNodeID == nodeID,
                hasVisibleChildren: !visibleChildren.isEmpty || node.regularChildren.knownCount > 0
            )
        )
        for childID in visibleChildren {
            appendProjectionRows(childID, depth: depth + 1, visited: &visited, rows: &rows)
        }
    }

    private func snapshotRegularChildren(_ regularChildren: DOMRegularChildState) -> DOMRegularChildrenSnapshot {
        switch regularChildren {
        case let .unrequested(count):
            return .unrequested(count: count)
        case let .loaded(children):
            return .loaded(children)
        }
    }

    private func reconcileSelection() {
        guard let selectedNodeID = selection.selectedNodeID,
              nodesByID[selectedNodeID] == nil else {
            return
        }
        selection.selectedNodeID = nil
        selection.failure = nil
    }

    private func failSelection(
        _ failure: SelectionResolutionFailure,
        clearSelected: Bool = true
    ) -> Result<DOMCommandIntent, SelectionResolutionFailure> {
        if clearSelected {
            selection.selectedNodeID = nil
        }
        selection.pendingRequest = nil
        selection.failure = failure
        return .failure(failure)
    }

    private func failSelection(
        _ failure: SelectionResolutionFailure,
        clearSelected: Bool = true
    ) -> Result<DOMNode.ID, SelectionResolutionFailure> {
        if clearSelected {
            selection.selectedNodeID = nil
        }
        selection.pendingRequest = nil
        selection.failure = failure
        return .failure(failure)
    }
}
