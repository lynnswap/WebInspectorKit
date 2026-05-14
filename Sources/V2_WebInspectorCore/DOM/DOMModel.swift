import Foundation
import Observation

@MainActor
@Observable
package final class ProtocolTarget {
    package typealias ID = ProtocolTargetIdentifier

    package let id: ID
    package var kind: ProtocolTargetKind
    package var frameID: DOMFrame.ID?
    package var parentFrameID: DOMFrame.ID?
    package var isProvisional: Bool
    package var isPaused: Bool
    package var currentDocumentID: DOMDocument.ID?

    package init(
        id: ID,
        kind: ProtocolTargetKind,
        frameID: DOMFrame.ID?,
        parentFrameID: DOMFrame.ID?,
        isProvisional: Bool,
        isPaused: Bool
    ) {
        self.id = id
        self.kind = kind
        self.frameID = frameID
        self.parentFrameID = parentFrameID
        self.isProvisional = isProvisional
        self.isPaused = isPaused
    }
}

private extension UnicodeScalar {
    var isCSSDigit: Bool {
        value >= 0x30 && value <= 0x39
    }

    var isCSSLetter: Bool {
        (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A)
    }

    var isCSSControlCharacter: Bool {
        (value >= 0x01 && value <= 0x1F) || value == 0x7F
    }

    var isCSSIdentifierCharacter: Bool {
        value >= 0x80 || isCSSLetter || isCSSDigit || value == 0x2D || value == 0x5F
    }
}

private extension ProtocolTarget {
    var isTopLevelPage: Bool {
        kind == .page && parentFrameID == nil
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

    package init(
        id: ID,
        mainTargetID: ProtocolTarget.ID,
        mainFrameID: DOMFrame.ID,
        navigationGeneration: UInt64 = 0
    ) {
        self.id = id
        self.mainTargetID = mainTargetID
        self.mainFrameID = mainFrameID
        self.navigationGeneration = navigationGeneration
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
    package private(set) var treeRevision: UInt64
    package private(set) var selectionRevision: UInt64

    private var targetsByID: [ProtocolTarget.ID: ProtocolTarget]
    private var framesByID: [DOMFrame.ID: DOMFrame]
    private var executionContextsByID: [ExecutionContextID: ExecutionContextRecord]
    private var documentsByID: [DOMDocument.ID: DOMDocument]
    private var nodesByID: [DOMNode.ID: DOMNode]
    private var currentNodeIDByKey: [DOMNodeCurrentKey: DOMNode.ID]
    private var nextGenerationByTargetID: [ProtocolTarget.ID: UInt64]
    private var nextSelectionRequestRawID: UInt64
    private var selection: DOMSelection

    package init() {
        targetsByID = [:]
        framesByID = [:]
        executionContextsByID = [:]
        documentsByID = [:]
        nodesByID = [:]
        currentNodeIDByKey = [:]
        nextGenerationByTargetID = [:]
        nextSelectionRequestRawID = 0
        selection = DOMSelection()
        treeRevision = 0
        selectionRevision = 0
    }

    package func reset() {
        currentPage = nil
        targetsByID.removeAll()
        framesByID.removeAll()
        executionContextsByID.removeAll()
        documentsByID.removeAll()
        nodesByID.removeAll()
        currentNodeIDByKey.removeAll()
        nextGenerationByTargetID.removeAll()
        nextSelectionRequestRawID = 0
        selection = DOMSelection()
        treeRevision &+= 1
        selectionRevision &+= 1
    }

    package func applyTargetCreated(
        _ record: ProtocolTargetRecord,
        makeCurrentMainPage: Bool = false
    ) {
        let target = targetsByID[record.id] ?? ProtocolTarget(
            id: record.id,
            kind: record.kind,
            frameID: record.frameID,
            parentFrameID: record.parentFrameID,
            isProvisional: record.isProvisional,
            isPaused: record.isPaused
        )
        target.kind = record.kind
        target.frameID = record.frameID
        target.parentFrameID = record.parentFrameID
        target.isProvisional = record.isProvisional
        target.isPaused = record.isPaused
        targetsByID[record.id] = target

        if let frameID = record.frameID {
            let frame = frameWithID(frameID, parentFrameID: record.parentFrameID)
            frame.targetID = record.id
            target.frameID = frameID
        }

        guard makeCurrentMainPage, record.kind == .page else {
            return
        }

        promoteTargetToCurrentPage(record.id)
    }

    package func promoteTargetToCurrentPage(_ targetID: ProtocolTarget.ID) {
        guard let target = targetsByID[targetID],
              target.kind == .page,
              target.parentFrameID == nil else {
            return
        }

        let mainFrameID = target.frameID ?? DOMFrame.ID("main:\(targetID.rawValue)")
        let mainFrame = frameWithID(mainFrameID, parentFrameID: nil)
        mainFrame.targetID = targetID
        target.frameID = mainFrameID
        currentPage = DOMPage(id: targetID, mainTargetID: targetID, mainFrameID: mainFrameID)
        treeRevision &+= 1
    }

    package func applyTargetCommitted(targetID: ProtocolTarget.ID) {
        guard let target = targetsByID[targetID] else {
            return
        }

        target.isProvisional = false
        if let frameID = target.frameID {
            let frame = frameWithID(frameID, parentFrameID: target.parentFrameID)
            frame.targetID = targetID
        }
    }

    package func applyTargetCommitted(oldTargetID: ProtocolTarget.ID, newTargetID: ProtocolTarget.ID) {
        guard oldTargetID != newTargetID else {
            applyTargetCommitted(targetID: newTargetID)
            return
        }

        if currentPage?.mainTargetID == oldTargetID,
           let existingNewTarget = targetsByID[newTargetID],
           !existingNewTarget.isTopLevelPage {
            applyTargetCommitted(targetID: newTargetID)
            return
        }

        guard let oldTarget = targetsByID.removeValue(forKey: oldTargetID) else {
            return
        }

        let existingNewTarget = targetsByID[newTargetID]
        let frameID = existingNewTarget?.frameID ?? oldTarget.frameID
        let parentFrameID = existingNewTarget?.parentFrameID ?? oldTarget.parentFrameID
        let committedTarget = existingNewTarget ?? ProtocolTarget(
            id: newTargetID,
            kind: oldTarget.kind,
            frameID: frameID,
            parentFrameID: parentFrameID,
            isProvisional: false,
            isPaused: oldTarget.isPaused
        )
        committedTarget.kind = existingNewTarget?.kind ?? oldTarget.kind
        committedTarget.frameID = frameID
        committedTarget.parentFrameID = parentFrameID
        committedTarget.isProvisional = false
        committedTarget.isPaused = existingNewTarget?.isPaused ?? oldTarget.isPaused
        targetsByID[newTargetID] = committedTarget

        if let oldDocumentID = oldTarget.currentDocumentID {
            removeDocument(oldDocumentID)
            if committedTarget.currentDocumentID == oldDocumentID {
                committedTarget.currentDocumentID = nil
            }
        }

        if let frameID {
            let frame = frameWithID(frameID, parentFrameID: parentFrameID)
            if frame.targetID == oldTargetID || frame.targetID == nil {
                frame.targetID = newTargetID
            }
            if frame.currentDocumentID == oldTarget.currentDocumentID {
                frame.currentDocumentID = committedTarget.currentDocumentID
            }
        }

        for (contextID, record) in executionContextsByID where record.targetID == oldTargetID {
            executionContextsByID[contextID] = ExecutionContextRecord(
                id: record.id,
                targetID: newTargetID,
                frameID: record.frameID
            )
        }

        if let previousPage = currentPage, previousPage.mainTargetID == oldTargetID {
            currentPage = DOMPage(
                id: newTargetID,
                mainTargetID: newTargetID,
                mainFrameID: previousPage.mainFrameID,
                navigationGeneration: previousPage.navigationGeneration
            )
            if framesByID[previousPage.mainFrameID]?.targetID == oldTargetID {
                framesByID[previousPage.mainFrameID]?.targetID = newTargetID
            }
        }

        reconcileSelection()
        treeRevision &+= 1
    }

    package func applyTargetDestroyed(_ targetID: ProtocolTarget.ID) {
        guard let target = targetsByID.removeValue(forKey: targetID) else {
            return
        }
        executionContextsByID = executionContextsByID.filter { $0.value.targetID != targetID }
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
        treeRevision &+= 1
    }

    package func applyExecutionContextCreated(_ record: ExecutionContextRecord) {
        guard targetsByID[record.targetID] != nil else {
            return
        }
        executionContextsByID[record.id] = record
    }

    package func applyExecutionContextCreated(
        _ id: ExecutionContextID,
        targetID: ProtocolTarget.ID,
        frameID: DOMFrame.ID? = nil
    ) {
        applyExecutionContextCreated(.init(id: id, targetID: targetID, frameID: frameID))
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
        treeRevision &+= 1
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
        treeRevision &+= 1
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
        treeRevision &+= 1
        return childID
    }

    package func applyNodeRemoved(_ nodeID: DOMNode.ID) {
        removeNodeSubtree(nodeID, detachFromParent: true)
        reconcileSelection()
        treeRevision &+= 1
    }

    package var currentPageTargetID: ProtocolTarget.ID? {
        currentPage?.mainTargetID
    }

    package func currentDocumentID(for targetID: ProtocolTarget.ID) -> DOMDocument.ID? {
        targetsByID[targetID]?.currentDocumentID
    }

    package var selectedNodeID: DOMNode.ID? {
        selection.selectedNodeID
    }

    package var selectedNode: DOMNode? {
        selection.selectedNodeID.flatMap { nodesByID[$0] }
    }

    package var currentPageRootNode: DOMNode? {
        guard let targetID = currentPage?.mainTargetID,
              let documentID = targetsByID[targetID]?.currentDocumentID,
              let rootNodeID = documentsByID[documentID]?.rootNodeID
        else {
            return nil
        }
        return nodesByID[rootNodeID]
    }

    package func node(for id: DOMNode.ID) -> DOMNode? {
        nodesByID[id]
    }

    package func visibleDOMTreeChildren(of node: DOMNode) -> [DOMNode] {
        projectedVisibleChildren(of: node).compactMap { nodesByID[$0] }
    }

    package func hasVisibleDOMTreeChildren(_ node: DOMNode) -> Bool {
        !projectedVisibleChildren(of: node).isEmpty || node.regularChildren.knownCount > 0
    }

    package func hasUnloadedRegularChildren(_ node: DOMNode) -> Bool {
        guard case let .unrequested(count) = node.regularChildren else {
            return false
        }
        return count > 0
    }

    package func isTemplateContent(_ node: DOMNode) -> Bool {
        guard let parentID = node.parentID,
              let parent = nodesByID[parentID] else {
            return false
        }
        return parent.templateContentID == node.id
    }

    package func selectNode(_ nodeID: DOMNode.ID?) {
        if let nodeID, nodesByID[nodeID] == nil {
            return
        }
        let hasSelectionStateChange = selection.selectedNodeID != nodeID
            || selection.pendingRequest != nil
            || selection.failure != nil
        guard hasSelectionStateChange else {
            return
        }
        selection.selectedNodeID = nodeID
        selection.pendingRequest = nil
        selection.failure = nil
        selectionRevision &+= 1
    }

    @discardableResult
    package func selectProtocolNode(
        targetID: ProtocolTarget.ID,
        nodeID: DOMProtocolNodeID
    ) -> Result<DOMNode.ID, SelectionResolutionFailure> {
        let key = DOMNodeCurrentKey(targetID: targetID, nodeID: nodeID)
        guard let resolvedNodeID = currentNodeIDByKey[key] else {
            return failSelection(.unresolvedNode(key), clearSelected: false)
        }
        selectNode(resolvedNodeID)
        return .success(resolvedNodeID)
    }

    package func requestChildNodesIntent(for nodeID: DOMNode.ID, depth: Int = 3) -> DOMCommandIntent? {
        guard let node = nodesByID[nodeID],
              hasUnloadedRegularChildren(node) else {
            return nil
        }
        return .requestChildNodes(
            targetID: nodeID.documentID.targetID,
            nodeID: node.protocolNodeID,
            depth: max(1, depth)
        )
    }

    package func actionIdentity(
        for nodeID: DOMNode.ID,
        commandTargetID: ProtocolTarget.ID? = nil
    ) -> DOMActionIdentity? {
        guard let node = nodesByID[nodeID],
              let resolvedCommandTargetID = commandTargetID ?? currentPage?.mainTargetID,
              targetsByID[resolvedCommandTargetID] != nil else {
            return nil
        }

        let documentTargetID = nodeID.documentID.targetID
        let commandNodeID: DOMCommandNodeID = if documentTargetID == resolvedCommandTargetID {
            .protocolNode(node.protocolNodeID)
        } else {
            .scoped(targetID: documentTargetID, nodeID: node.protocolNodeID)
        }

        return DOMActionIdentity(
            documentTargetID: documentTargetID,
            rawNodeID: node.protocolNodeID,
            commandTargetID: resolvedCommandTargetID,
            commandNodeID: commandNodeID
        )
    }

    package func highlightNodeIntent(
        for nodeID: DOMNode.ID,
        commandTargetID: ProtocolTarget.ID? = nil
    ) -> DOMCommandIntent? {
        let resolvedCommandTargetID = commandTargetID ?? nodeID.documentID.targetID
        guard let identity = actionIdentity(for: nodeID, commandTargetID: resolvedCommandTargetID) else {
            return nil
        }
        return .highlightNode(identity: identity)
    }

    package func hideHighlightIntent(targetID: ProtocolTarget.ID? = nil) -> DOMCommandIntent? {
        guard let targetID = targetID ?? currentPage?.mainTargetID else {
            return nil
        }
        return .hideHighlight(targetID: targetID)
    }

    package func setInspectModeEnabledIntent(
        targetID: ProtocolTarget.ID? = nil,
        enabled: Bool
    ) -> DOMCommandIntent? {
        guard let targetID = targetID ?? currentPage?.mainTargetID,
              targetsByID[targetID] != nil else {
            return nil
        }
        return .setInspectModeEnabled(targetID: targetID, enabled: enabled)
    }

    package func outerHTMLIntent(
        for nodeID: DOMNode.ID,
        commandTargetID: ProtocolTarget.ID? = nil
    ) -> DOMCommandIntent? {
        guard let identity = actionIdentity(for: nodeID, commandTargetID: commandTargetID) else {
            return nil
        }
        return .getOuterHTML(identity: identity)
    }

    package func removeNodeIntent(
        for nodeID: DOMNode.ID,
        commandTargetID: ProtocolTarget.ID? = nil
    ) -> DOMCommandIntent? {
        guard let identity = actionIdentity(for: nodeID, commandTargetID: commandTargetID) else {
            return nil
        }
        return .removeNode(identity: identity)
    }

    package func selectedNodeCopyText(_ kind: DOMNodeCopyTextKind) -> String? {
        guard let selectedNode else {
            return nil
        }
        switch kind {
        case .html:
            return nil
        case .selectorPath:
            return selectorPath(for: selectedNode)
        case .xPath:
            return xPath(for: selectedNode)
        }
    }

    package func selectorPath(for node: DOMNode) -> String {
        guard nodeIsElementLike(node) else {
            return ""
        }

        var components: [String] = []
        var current: DOMNode? = node
        while let candidate = current {
            guard let component = selectorPathComponent(for: candidate) else {
                break
            }
            components.append(component.value)
            if component.done {
                break
            }
            current = selectorTraversalParent(for: candidate)
        }

        return components.reversed().joined(separator: " > ")
    }

    package func xPath(for node: DOMNode) -> String {
        if node.nodeType == .document {
            return "/"
        }

        var components: [String] = []
        var current: DOMNode? = node
        while let candidate = current {
            if candidate.nodeType == .document {
                current = parent(of: candidate)
                continue
            }
            guard let component = xPathComponent(for: candidate) else {
                break
            }
            components.append(component)
            current = parent(of: candidate)
        }

        guard !components.isEmpty else {
            return ""
        }
        return "/" + components.reversed().joined(separator: "/")
    }

    package func beginInspectSelectionRequest(
        targetID: ProtocolTarget.ID,
        objectID: String
    ) -> Result<DOMCommandIntent, SelectionResolutionFailure> {
        guard objectID.isEmpty == false else {
            return failSelection(.missingObjectID)
        }
        guard let documentID = targetsByID[targetID]?.currentDocumentID else {
            return failSelection(.missingCurrentDocument(targetID))
        }

        nextSelectionRequestRawID &+= 1
        let requestID = SelectionRequestIdentifier(nextSelectionRequestRawID)
        selection.pendingRequest = DOMSelectionRequest(id: requestID, targetID: targetID, documentID: documentID)
        selection.failure = nil
        return .success(.requestNode(selectionRequestID: requestID, targetID: targetID, objectID: objectID))
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
        selectionRevision &+= 1
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
                    isProvisional: $0.isProvisional,
                    isPaused: $0.isPaused,
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
            executionContextsByID: executionContextsByID,
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

    private func parent(of node: DOMNode) -> DOMNode? {
        node.parentID.flatMap { nodesByID[$0] }
    }

    private func selectorTraversalParent(for node: DOMNode) -> DOMNode? {
        guard let parent = parent(of: node) else {
            return nil
        }
        if parent.nodeType == .document {
            return self.parent(of: parent)
        }
        return parent
    }

    private func selectorPathComponent(for node: DOMNode) -> (value: String, done: Bool)? {
        guard nodeIsElementLike(node) else {
            return nil
        }

        let nodeName = selectorNodeName(for: node)
        guard !nodeName.isEmpty else {
            return nil
        }

        let parent = selectorTraversalParent(for: node)
        if parent == nil || (["html", "body", "head"].contains(nodeName) && !nodeIsInsideEmbeddedDocument(node)) {
            return (nodeName, true)
        }

        if let idValue = attributeValue(named: "id", on: node),
           !idValue.isEmpty {
            return ("#\(escapedCSSIdentifier(idValue))", !nodeIsInsideEmbeddedDocument(node))
        }

        let siblings = selectorSiblingElements(for: node)
        var uniqueClasses = Set(classNames(for: node))
        var hasUniqueTagName = true
        var nthChildIndex = 0
        var elementIndex = 0

        for sibling in siblings {
            elementIndex += 1
            if sibling.id == node.id {
                nthChildIndex = elementIndex
                continue
            }
            if selectorNodeName(for: sibling) == nodeName {
                hasUniqueTagName = false
            }
            for className in classNames(for: sibling) {
                uniqueClasses.remove(className)
            }
        }

        var selector = nodeName
        if nodeName == "input",
           let typeValue = attributeValue(named: "type", on: node),
           !typeValue.isEmpty,
           uniqueClasses.isEmpty {
            selector += "[type=\"\(escapedCSSAttributeValue(typeValue))\"]"
        }

        if !hasUniqueTagName {
            if !uniqueClasses.isEmpty {
                selector += "." + uniqueClasses.sorted().map(escapedCSSIdentifier).joined(separator: ".")
            } else if nthChildIndex > 0 {
                selector += ":nth-child(\(nthChildIndex))"
            }
        }

        return (selector, false)
    }

    private func xPathComponent(for node: DOMNode) -> String? {
        func elementComponent() -> String? {
            let nodeName = selectorNodeName(for: node)
            guard !nodeName.isEmpty else {
                return nil
            }
            let index = xPathIndex(for: node)
            return index > 0 ? "\(nodeName)[\(index)]" : nodeName
        }

        switch node.nodeType {
        case .element:
            return elementComponent()
        case .attribute:
            return "@\(node.nodeName)"
        case .text, .cdataSection:
            let index = xPathIndex(for: node)
            return index > 0 ? "text()[\(index)]" : "text()"
        case .comment:
            let index = xPathIndex(for: node)
            return index > 0 ? "comment()[\(index)]" : "comment()"
        case .processingInstruction:
            let index = xPathIndex(for: node)
            return index > 0 ? "processing-instruction()[\(index)]" : "processing-instruction()"
        default:
            return nil
        }
    }

    private func xPathIndex(for node: DOMNode) -> Int {
        guard let parent = parent(of: node) else {
            return 0
        }

        let siblings = parent.regularChildren.loadedChildren.compactMap { nodesByID[$0] }
        guard siblings.count > 1 else {
            return 0
        }

        var foundIndex = -1
        var counter = 1
        var unique = true

        for sibling in siblings where xPathNodesAreSimilar(node, sibling) {
            if sibling.id == node.id {
                foundIndex = counter
                if !unique {
                    return foundIndex
                }
            } else {
                unique = false
                if foundIndex != -1 {
                    return foundIndex
                }
            }
            counter += 1
        }

        if unique {
            return 0
        }
        return foundIndex > 0 ? foundIndex : 0
    }

    private func xPathNodesAreSimilar(_ lhs: DOMNode, _ rhs: DOMNode) -> Bool {
        if lhs.id == rhs.id {
            return true
        }
        if nodeIsElementLike(lhs), nodeIsElementLike(rhs) {
            return selectorNodeName(for: lhs) == selectorNodeName(for: rhs)
        }
        if lhs.nodeType == .cdataSection {
            return rhs.nodeType == .text
        }
        if rhs.nodeType == .cdataSection {
            return lhs.nodeType == .text
        }
        return lhs.nodeType == rhs.nodeType
    }

    private func selectorSiblingElements(for node: DOMNode) -> [DOMNode] {
        guard let parent = parent(of: node) else {
            return [node]
        }
        return parent.regularChildren.loadedChildren.compactMap { nodesByID[$0] }.filter(nodeIsElementLike)
    }

    private func selectorNodeName(for node: DOMNode) -> String {
        let rawName = node.localName.isEmpty ? node.nodeName : node.localName
        return rawName.lowercased()
    }

    private func nodeIsElementLike(_ node: DOMNode) -> Bool {
        guard node.nodeType == .element else {
            return false
        }
        let nodeName = selectorNodeName(for: node)
        return !nodeName.isEmpty && !nodeName.hasPrefix("#")
    }

    private func classNames(for node: DOMNode) -> [String] {
        guard let classValue = attributeValue(named: "class", on: node) else {
            return []
        }
        return classValue
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func attributeValue(named name: String, on node: DOMNode) -> String? {
        node.attributes.first(where: { $0.name == name })?.value
    }

    private func nodeIsInsideEmbeddedDocument(_ node: DOMNode) -> Bool {
        var current = parent(of: node)
        while let currentNode = current {
            if currentNode.nodeType == .document, parent(of: currentNode) != nil {
                return true
            }
            current = parent(of: currentNode)
        }
        return false
    }

    private func escapedCSSIdentifier(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        var escaped = ""
        for (index, scalar) in scalars.enumerated() {
            let isFirstScalar = index == 0
            let followsLeadingHyphen = index == 1 && scalars.first?.value == 0x2D
            if scalar.value == 0 {
                escaped.append("\u{FFFD}")
            } else if scalar.isCSSControlCharacter
                || (isFirstScalar && scalar.isCSSDigit)
                || (followsLeadingHyphen && scalar.isCSSDigit) {
                escaped.append("\\")
                escaped.append(String(scalar.value, radix: 16, uppercase: true))
                escaped.append(" ")
            } else if isFirstScalar && scalar.value == 0x2D && scalars.count == 1 {
                escaped.append(#"\-"#)
            } else if scalar.isCSSIdentifierCharacter {
                escaped.unicodeScalars.append(scalar)
            } else {
                escaped.append("\\")
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    private func escapedCSSAttributeValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func reconcileSelection() {
        guard let selectedNodeID = selection.selectedNodeID,
              nodesByID[selectedNodeID] == nil else {
            return
        }
        selection.selectedNodeID = nil
        selection.failure = nil
        selectionRevision &+= 1
    }

    private func failSelection(
        _ failure: SelectionResolutionFailure,
        clearSelected: Bool = true
    ) -> Result<DOMCommandIntent, SelectionResolutionFailure> {
        let previousSelectedNodeID = selection.selectedNodeID
        let previousHadPendingRequest = selection.pendingRequest != nil
        let previousFailure = selection.failure
        if clearSelected {
            selection.selectedNodeID = nil
        }
        selection.pendingRequest = nil
        selection.failure = failure
        if (clearSelected && previousSelectedNodeID != nil)
            || previousHadPendingRequest
            || previousFailure != failure {
            selectionRevision &+= 1
        }
        return .failure(failure)
    }

    private func failSelection(
        _ failure: SelectionResolutionFailure,
        clearSelected: Bool = true
    ) -> Result<DOMNode.ID, SelectionResolutionFailure> {
        let previousSelectedNodeID = selection.selectedNodeID
        let previousHadPendingRequest = selection.pendingRequest != nil
        let previousFailure = selection.failure
        if clearSelected {
            selection.selectedNodeID = nil
        }
        selection.pendingRequest = nil
        selection.failure = failure
        if (clearSelected && previousSelectedNodeID != nil)
            || previousHadPendingRequest
            || previousFailure != failure {
            selectionRevision &+= 1
        }
        return .failure(failure)
    }
}
