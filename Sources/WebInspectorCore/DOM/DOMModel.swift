import Observation
import WebInspectorTransport

@MainActor
@Observable
package final class DOMSession {
    package private(set) var elementStyles: CSSSession
    package var isSelectingElement: Bool
    package private(set) var treeRevision: UInt64
    package private(set) var selectionRevision: UInt64
    package private(set) var observedSelectedNodeID: DOMNode.ID?

    private let targetGraph: TargetGraph
    private var currentPage: DOMCurrentPage
    private var documentStore: DOMDocumentStore
    private var frameDocumentProjectionCoordinator: FrameDocumentProjectionCoordinator
    private var selection: DOMSelection
    private var nextSelectionRequestRawID: UInt64
    @ObservationIgnored var commandChannel: ProtocolCommandChannel?
    @ObservationIgnored let protocolCommands: DOMProtocolCommands
    @ObservationIgnored var recordError: ((InspectorSessionError?) -> Void)?
    @ObservationIgnored let highlightController: DOMSessionHighlightController
    @ObservationIgnored let elementPicker: DOMSessionElementPickerController
    @ObservationIgnored let documentRequests: DOMSessionDocumentRequestController
    @ObservationIgnored let styleHydration: DOMSessionElementStyleHydrationController
    @ObservationIgnored let deleteUndoController: DOMSessionDeleteUndoController

    package init(
        targetGraph: TargetGraph = TargetGraph(),
        elementStyles: CSSSession = CSSSession()
    ) {
        self.elementStyles = elementStyles
        isSelectingElement = false
        treeRevision = 0
        selectionRevision = 0
        observedSelectedNodeID = nil
        self.targetGraph = targetGraph
        currentPage = DOMCurrentPage()
        documentStore = DOMDocumentStore()
        frameDocumentProjectionCoordinator = FrameDocumentProjectionCoordinator()
        selection = DOMSelection()
        nextSelectionRequestRawID = 0
        commandChannel = nil
        protocolCommands = DOMProtocolCommands()
        recordError = nil
        highlightController = DOMSessionHighlightController()
        elementPicker = DOMSessionElementPickerController()
        documentRequests = DOMSessionDocumentRequestController()
        styleHydration = DOMSessionElementStyleHydrationController()
        deleteUndoController = DOMSessionDeleteUndoController()
    }

    package var currentPageTargetID: ProtocolTarget.ID? {
        currentPage.targetID
    }

    package var mainFrameID: DOMFrame.ID? {
        currentPage.mainFrameID
    }

    private func targetBelongsToCurrentPage(_ targetID: ProtocolTarget.ID) -> Bool {
        targetGraph.targetBelongsToCurrentPage(
            targetID,
            currentPageTargetID: currentPage.targetID,
            mainFrameID: currentPage.mainFrameID
        )
    }

    private func state(for targetID: ProtocolTarget.ID) -> DOMTargetState {
        documentStore.state(for: targetID)
    }

    private func currentState(for targetID: ProtocolTarget.ID) -> DOMTargetState? {
        guard targetBelongsToCurrentPage(targetID) || currentPage.isEmpty else {
            return nil
        }
        return documentStore.stateIfPresent(for: targetID)
    }

    private func currentDocument(for documentID: DOMDocument.ID) -> DOMDocument? {
        documentStore.currentDocument(for: documentID)
    }

    private func document(for nodeID: DOMNode.ID) -> DOMDocument? {
        currentDocument(for: nodeID.documentID)
    }

    private func attachKnownFrameTargets() {
        targetGraph.attachKnownFrameTargets(mainFrameID: currentPage.mainFrameID)
    }

    private func recordTreeMutation() {
        treeRevision &+= 1
    }

    private func recordSelectionMutation() {
        observedSelectedNodeID = selection.selectedNodeID
        selectionRevision &+= 1
    }

    package func reset() {
        currentPage.clear()
        targetGraph.reset()
        documentStore.reset()
        frameDocumentProjectionCoordinator.removeAll()
        selection = DOMSelection()
        elementStyles.reset()
        nextSelectionRequestRawID = 0
        isSelectingElement = false
        recordTreeMutation()
        recordSelectionMutation()
    }

    package func applyTargetCreated(
        _ record: ProtocolTargetRecord,
        makeCurrentMainPage: Bool = false
    ) {
        targetGraph.upsertTarget(from: record)
        _ = state(for: record.id)

        if record.kind == .frame {
            targetGraph.attachFrameTarget(record.id)
        }
        recordTreeMutation()

        guard makeCurrentMainPage, record.kind == .page else {
            return
        }

        promoteTargetToCurrentPage(record.id)
    }

    package func promoteTargetToCurrentPage(_ targetID: ProtocolTarget.ID) {
        guard targetGraph.isTopLevelPageTarget(targetID) else {
            return
        }

        let resolvedMainFrameID = targetGraph.targetFrameID(for: targetID) ?? DOMFrame.ID("main:\(targetID.rawValue)")
        if currentPage.promote(targetID: targetID, mainFrameID: resolvedMainFrameID) {
            selection = DOMSelection()
            recordSelectionMutation()
        }
        _ = state(for: targetID)
        targetGraph.assignMainFrame(resolvedMainFrameID, to: targetID)
        attachKnownFrameTargets()
        recordTreeMutation()
    }

    package func applyTargetCommitted(targetID: ProtocolTarget.ID) {
        if targetGraph.markTargetCommitted(targetID) {
            recordTreeMutation()
        }
    }

    package func applyTargetCommitted(oldTargetID: ProtocolTarget.ID, newTargetID: ProtocolTarget.ID) {
        guard oldTargetID != newTargetID else {
            applyTargetCommitted(targetID: newTargetID)
            return
        }

        if currentPage.isCurrentTarget(oldTargetID),
           targetGraph.containsTarget(newTargetID),
           !targetGraph.isTopLevelPageTarget(newTargetID) {
            applyTargetCommitted(targetID: newTargetID)
            return
        }

        guard let commit = targetGraph.commitTarget(oldTargetID: oldTargetID, newTargetID: newTargetID) else {
            return
        }

        if let oldState = documentStore.removeState(for: oldTargetID) {
            oldState.currentDocument?.transactions.removeAll()
            let newState = state(for: newTargetID)
            if let oldDocument = oldState.currentDocument {
                oldDocument.lifecycle = .invalidated
                clearCurrentDocumentReference(
                    oldDocument.id,
                    targetID: oldTargetID,
                    targetFrameID: commit.oldFrameID
                )
                newState.currentDocument = nil
            }
        }

        frameDocumentProjectionCoordinator.moveProjection(
            from: oldTargetID,
            to: newTargetID,
            currentPageTargetID: currentPageTargetID,
            targetGraph: targetGraph,
            documentStore: documentStore
        )

        targetGraph.retargetExecutionContexts(from: oldTargetID, to: newTargetID)

        if currentPage.retarget(from: oldTargetID, to: newTargetID) {
            if let mainFrameID = currentPage.mainFrameID {
                targetGraph.setFrameTargetID(newTargetID, for: mainFrameID)
            }
        }

        recordTreeMutation()
        reconcileSelection()
    }

    package func applyTargetDestroyed(_ targetID: ProtocolTarget.ID) {
        guard let removal = targetGraph.removeTarget(targetID) else {
            return
        }
        targetGraph.removeExecutionContexts(targetID: targetID)
        targetGraph.removeExecutionContexts(runtimeAgentTargetID: targetID)
        if let documentID = documentStore.currentDocument(forTargetID: targetID)?.id {
            removeDocument(documentID)
        }
        frameDocumentProjectionCoordinator.removeProjection(for: targetID)
        if let frameID = removal.frameID,
           targetGraph.frameTargetID(frameID) == targetID {
            targetGraph.setFrameTargetID(nil, for: frameID)
            targetGraph.setFrameCurrentDocumentID(nil, for: frameID)
        }
        if currentPage.clear(ifTarget: targetID) {
            selection = DOMSelection()
            recordSelectionMutation()
        }
        documentStore.removeState(for: targetID)
        recordTreeMutation()
        reconcileSelection()
    }

    package func applyExecutionContextCreated(_ context: RuntimeExecutionContextRecord) {
        guard targetGraph.containsTarget(context.targetID) else {
            return
        }
        targetGraph.recordExecutionContext(context)
    }

    package func applyExecutionContextDestroyed(_ contextKey: RuntimeExecutionContextKey) {
        targetGraph.removeExecutionContext(contextKey)
    }

    package func applyExecutionContextsCleared(runtimeAgentTargetID: ProtocolTarget.ID) {
        targetGraph.removeExecutionContexts(runtimeAgentTargetID: runtimeAgentTargetID)
    }

    package func applyExecutionContextCreated(
        _ id: ExecutionContextID,
        targetID: ProtocolTarget.ID,
        frameID: DOMFrame.ID? = nil
    ) {
        applyExecutionContextCreated(RuntimeExecutionContextRecord(id: id, targetID: targetID, frameID: frameID))
    }

    @discardableResult
    package func replaceDocumentRoot(_ root: DOMNodePayload, targetID: ProtocolTarget.ID) -> DOMNode.ID {
        guard targetGraph.containsTarget(targetID) else {
            preconditionFailure("replaceDocumentRoot requires a known ProtocolTarget")
        }
        let targetState = state(for: targetID)
        removeDocuments(for: targetID)

        let documentID = documentStore.nextDocumentID(for: targetID)
        var nodeIndex = DOMDocumentNodeIndex()
        let rootNodeID = buildSubtree(
            root,
            documentID: documentID,
            parentID: nil,
            nodeIndex: &nodeIndex
        )
        let document = DOMDocument(
            id: documentID,
            targetID: targetID,
            lifecycle: .loaded,
            rootNodeID: rootNodeID,
            nodesByID: nodeIndex.nodesByID,
            currentNodeIDByProtocolNodeID: nodeIndex.currentNodeIDByProtocolNodeID
        )
        targetState.currentDocument = document

        if let frameID = targetGraph.targetFrameID(for: targetID) {
            targetGraph.setFrameCurrentDocumentID(documentID, for: frameID)
        }
        if currentPage.isCurrentTarget(targetID),
           let mainFrameID = currentPage.mainFrameID {
            targetGraph.setFrameCurrentDocumentID(documentID, for: mainFrameID)
        }
        if targetGraph.targetKind(for: targetID) == .frame {
            setFrameDocumentProjection(frameTargetID: targetID, frameDocumentID: documentID)
        }
        updateAllFrameDocumentProjectionStates()

        recordTreeMutation()
        reconcileSelection()
        return rootNodeID
    }

    package func invalidateDocument(targetID: ProtocolTarget.ID) {
        guard let targetState = documentStore.stateIfPresent(for: targetID),
              let document = targetState.currentDocument else {
            return
        }
        let documentID = document.id
        document.lifecycle = .invalidated
        document.transactions.removeAll()
        if let frameID = targetGraph.targetFrameID(for: targetID),
           targetGraph.frameCurrentDocumentID(frameID) == documentID {
            targetGraph.setFrameCurrentDocumentID(nil, for: frameID)
        }
        if currentPage.isCurrentTarget(targetID),
           let mainFrameID = currentPage.mainFrameID {
            targetGraph.clearFrameCurrentDocumentID(mainFrameID, matching: documentID)
        }
        frameDocumentProjectionCoordinator.detachProjectionIfDocumentMatches(
            frameTargetID: targetID,
            documentID: documentID
        )
        recordTreeMutation()
        reconcileSelection()
    }

    package func applySetChildNodes(parent nodeID: DOMNode.ID, children payloads: [DOMNodePayload]) {
        applySetChildNodes(parent: nodeID, children: payloads, eventSequence: .max)
    }

    package func applySetChildNodes(
        targetID: ProtocolTarget.ID,
        parentRawNodeID: DOMProtocolNodeID,
        children payloads: [DOMNodePayload],
        eventSequence: UInt64
    ) {
        guard let document = documentStore.currentDocument(forTargetID: targetID),
              document.lifecycle == .loaded else {
            return
        }
        if let parentID = document.currentNodeIDByProtocolNodeID[parentRawNodeID] {
            applySetChildNodes(parent: parentID, children: payloads, eventSequence: eventSequence)
            return
        }
        document.storePendingPathFragments(parentRawNodeID: parentRawNodeID, payloads: payloads)
    }

    package func applyDetachedRoot(
        targetID: ProtocolTarget.ID,
        payload: DOMNodePayload,
        eventSequence _: UInt64
    ) {
        guard let document = documentStore.currentDocument(forTargetID: targetID),
              document.lifecycle == .loaded else {
            return
        }
        guard !payloadContainsConnectedDocumentNode(payload, in: document) else {
            return
        }
        let nodeID = DOMNode.ID(documentID: document.id, nodeID: payload.nodeID)
        if document.nodesByID[nodeID] != nil {
            removeNodeSubtree(nodeID, detachFromParent: true)
        }
        buildSubtree(payload, document: document, parentID: nil)
        recordTreeMutation()
        completePendingSelectionIfPossible(in: document)
    }

    package func applySetChildNodes(parent nodeID: DOMNode.ID, children payloads: [DOMNodePayload], eventSequence: UInt64) {
        guard let document = currentDocument(for: nodeID.documentID),
              let parent = document.nodesByID[nodeID] else {
            return
        }
        guard canApplyDOMEvent(to: nodeID) else {
            return
        }
        let affectsVisibleTree = document.containsConnectedNode(nodeID)
        if parent.isFrameOwner,
           projectedFrameDocumentRootID(for: parent.id) != nil {
            document.removeChildNodesTransactions(parentRawNodeID: parent.protocolNodeID)
            return
        }
        let incomingRawNodeIDs = Set(payloads.map(\.nodeID))
        let childIDsToRemove = parent.regularChildren.loadedChildren.filter { childID in
            guard let child = document.nodesByID[childID] else {
                return true
            }
            return incomingRawNodeIDs.contains(child.protocolNodeID) == false
        }
        var replacementOwnerKeys: [ProtocolTarget.ID: DOMNodeCurrentKey] = [:]
        for childID in childIDsToRemove {
            replacementOwnerKeys.merge(projectedFrameOwnerKeys(inSubtree: childID)) { current, _ in current }
            removeNodeSubtree(childID, detachFromParent: false)
        }
        parent.regularChildren = .loaded(
            payloads.map {
                buildSubtree($0, document: document, parentID: nodeID)
            }
        )
        relinkProtocolEffectiveChildren(of: parent)
        reattachFrameDocumentProjections(using: replacementOwnerKeys)
        document.removeChildNodesTransactions(parentRawNodeID: parent.protocolNodeID)
        document.removeOwnerHydrationTransactions()
        splicePendingTransactionFragments(parentRawNodeID: parent.protocolNodeID, into: document)
        if affectsVisibleTree {
            recordTreeMutation()
            updateAllFrameDocumentProjectionStates()
            reconcileSelection()
        } else {
            completePendingSelectionIfPossible(in: document)
        }
    }

    @discardableResult
    package func applyChildInserted(
        parent parentID: DOMNode.ID,
        previousSibling previousSiblingID: DOMNode.ID?,
        child payload: DOMNodePayload
    ) -> DOMNode.ID? {
        guard let document = currentDocument(for: parentID.documentID),
              let parent = document.nodesByID[parentID] else {
            return nil
        }
        guard canApplyDOMEvent(to: parentID) else {
            return nil
        }
        let affectsVisibleTree = document.containsConnectedNode(parentID)
        let replacementOwnerKeys = document.currentNodeIDByProtocolNodeID[payload.nodeID]
            .map { projectedFrameOwnerKeys(inSubtree: $0) } ?? [:]
        let childID = buildSubtree(payload, document: document, parentID: parentID)
        var children = parent.regularChildren.loadedChildren.filter { $0 != childID }
        if let previousSiblingID,
           let previousIndex = children.firstIndex(of: previousSiblingID) {
            children.insert(childID, at: children.index(after: previousIndex))
        } else {
            children.insert(childID, at: 0)
        }
        parent.regularChildren = .loaded(children)
        relinkProtocolEffectiveChildren(of: parent)
        if affectsVisibleTree {
            recordTreeMutation()
            reattachFrameDocumentProjections(using: replacementOwnerKeys)
            updateAllFrameDocumentProjectionStates()
            reconcileSelection()
        } else {
            completePendingSelectionIfPossible(in: document)
        }
        return childID
    }

    package func applyNodeRemoved(_ nodeID: DOMNode.ID) {
        guard let document = currentDocument(for: nodeID.documentID),
              canApplyDOMEvent(to: nodeID) else {
            return
        }
        let affectsVisibleTree = document.containsConnectedNode(nodeID)
        removeNodeSubtree(nodeID, detachFromParent: true)
        if affectsVisibleTree {
            recordTreeMutation()
            updateAllFrameDocumentProjectionStates()
            reconcileSelection()
        }
    }

    package func applyChildNodeCountUpdated(_ nodeID: DOMNode.ID, count: Int) {
        guard let document = currentDocument(for: nodeID.documentID),
              let node = document.nodesByID[nodeID],
              canApplyDOMEvent(to: nodeID) else {
            return
        }
        if case .unrequested = node.regularChildren {
            let nextCount = max(0, count)
            guard node.regularChildren.knownCount != nextCount else {
                return
            }
            node.regularChildren = .unrequested(count: nextCount)
            if document.containsConnectedNode(nodeID) {
                recordTreeMutation()
            }
        }
    }

    package func applyAttributeModified(_ nodeID: DOMNode.ID, name: String, value: String) {
        guard let document = currentDocument(for: nodeID.documentID),
              let node = document.nodesByID[nodeID],
              canApplyDOMEvent(to: nodeID) else {
            return
        }
        if let index = node.attributes.firstIndex(where: { $0.name == name }) {
            guard node.attributes[index].value != value else {
                return
            }
            node.attributes[index].value = value
        } else {
            node.attributes.append(.init(name: name, value: value))
        }
        recordTreeMutation()
        if node.isFrameOwner,
           name.caseInsensitiveCompare("src") == .orderedSame {
            updateAllFrameDocumentProjectionStates()
        }
    }

    package func applyAttributeRemoved(_ nodeID: DOMNode.ID, name: String) {
        guard let document = currentDocument(for: nodeID.documentID),
              let node = document.nodesByID[nodeID],
              canApplyDOMEvent(to: nodeID),
              let index = node.attributes.firstIndex(where: { $0.name == name }) else {
            return
        }
        node.attributes.remove(at: index)
        recordTreeMutation()
        if node.isFrameOwner,
           name.caseInsensitiveCompare("src") == .orderedSame {
            updateAllFrameDocumentProjectionStates()
        }
    }

    package func currentDocumentID(for targetID: ProtocolTarget.ID) -> DOMDocument.ID? {
        documentStore.currentLoadedDocumentID(for: targetID)
    }

    package func targetCapabilities(for targetID: ProtocolTarget.ID) -> ProtocolTargetCapabilities {
        targetGraph.targetCapabilities(for: targetID)
    }

    package func targetKind(for targetID: ProtocolTarget.ID) -> ProtocolTargetKind? {
        targetGraph.targetKind(for: targetID)
    }

    package func getDocumentIntent(targetID: ProtocolTarget.ID) -> DOMCommandIntent? {
        guard targetCapabilities(for: targetID).contains(.dom) else {
            return nil
        }
        return .getDocument(targetID: targetID)
    }

    package var selectedNodeID: DOMNode.ID? {
        selection.selectedNodeID
    }

    package var selectedNode: DOMNode? {
        guard let selectedNodeID = selection.selectedNodeID else {
            return nil
        }
        return node(for: selectedNodeID)
    }

    package func node(_ nodeID: DOMNode.ID, isSameOrDescendantOf ancestorID: DOMNode.ID) -> Bool {
        guard nodeID.documentID == ancestorID.documentID else {
            return false
        }

        var currentID: DOMNode.ID? = nodeID
        while let candidateID = currentID {
            if candidateID == ancestorID {
                return true
            }
            currentID = node(for: candidateID)?.parentID
        }
        return false
    }

    package func selectedCSSNodeStyleIdentity() -> Result<CSSNodeStyleIdentity, CSSNodeStylesUnavailableReason> {
        guard let selectedNodeID = selection.selectedNodeID else {
            return .failure(.noSelection)
        }
        return cssNodeStyleIdentity(for: selectedNodeID)
    }

    package var selectedNodeStyles: CSSNodeStyles? {
        elementStyles.selectedNodeStyles
    }

    package func cssNodeStyleIdentity(
        for nodeID: DOMNode.ID
    ) -> Result<CSSNodeStyleIdentity, CSSNodeStylesUnavailableReason> {
        guard let node = node(for: nodeID) else {
            return .failure(.staleNode(nodeID))
        }
        guard node.nodeType == .element else {
            return .failure(.nonElementNode(node.nodeType))
        }
        let targetID = nodeID.documentID.targetID
        let capabilities = targetCapabilities(for: targetID)
        guard capabilities.contains(.css) else {
            return .failure(.cssUnavailableForTarget(targetID))
        }
        return .success(
            CSSNodeStyleIdentity(
                nodeID: nodeID,
                targetID: targetID,
                documentID: nodeID.documentID,
                protocolNodeID: node.protocolNodeID,
                targetCapabilities: capabilities
            )
        )
    }

    package var currentPageRootNode: DOMNode? {
        guard let targetID = currentPageTargetID,
              let document = documentStore.currentDocument(forTargetID: targetID),
              document.lifecycle == .loaded
        else {
            return nil
        }
        return document.nodesByID[document.rootNodeID]
    }

    package func node(for id: DOMNode.ID) -> DOMNode? {
        documentStore.node(for: id)
    }

    package func visibleDOMTreeChildren(of node: DOMNode) -> [DOMNode] {
        guard currentDocument(for: node.id.documentID) != nil else {
            return []
        }
        return projectedVisibleChildren(of: node).compactMap { self.node(for: $0) }
    }

    package func hasVisibleDOMTreeChildren(_ node: DOMNode) -> Bool {
        guard currentDocument(for: node.id.documentID) != nil else {
            return node.regularChildren.knownCount > 0
        }
        return !projectedVisibleChildren(of: node).isEmpty || node.regularChildren.knownCount > 0
    }

    package func hasUnloadedRegularChildren(_ node: DOMNode) -> Bool {
        guard case let .unrequested(count) = node.regularChildren else {
            return false
        }
        return count > 0
    }

    package func isTemplateContent(_ node: DOMNode) -> Bool {
        guard let parentID = node.parentID,
              let parent = self.node(for: parentID) else {
            return false
        }
        return parent.templateContentID == node.id
    }

    package func selectNode(_ nodeID: DOMNode.ID?) {
        if let nodeID {
            guard node(for: nodeID) != nil else {
                return
            }
        }
        guard selection.hasStateChange(selecting: nodeID) else {
            return
        }
        cancelSelectionTransaction(for: selection.select(nodeID))
        recordSelectionMutation()
        syncSelectedElementStyles()
    }

    @discardableResult
    package func selectProtocolNode(
        targetID: ProtocolTarget.ID,
        nodeID: DOMProtocolNodeID
    ) -> Result<DOMNode.ID, SelectionResolutionFailure> {
        guard let document = documentStore.currentDocument(forTargetID: targetID),
              document.lifecycle == .loaded else {
            return failSelection(.missingCurrentDocument(targetID), clearSelected: false)
        }
        let key = DOMNodeCurrentKey(targetID: targetID, nodeID: nodeID)
        guard let resolvedNodeID = document.currentNodeIDByProtocolNodeID[nodeID] else {
            return failSelection(.unresolvedNode(key), clearSelected: false)
        }
        selectNode(resolvedNodeID)
        return .success(resolvedNodeID)
    }

    package func requestChildNodesIntent(for nodeID: DOMNode.ID, depth: Int = 3, issuedSequence: UInt64 = 0) -> DOMCommandIntent? {
        guard let document = currentDocument(for: nodeID.documentID),
              let node = document.nodesByID[nodeID],
              hasUnloadedRegularChildren(node),
              canApplyDOMEvent(to: nodeID) else {
            return nil
        }
        registerTransaction(
            targetID: nodeID.documentID.targetID,
            document: document,
            kind: .requestChildNodes(parentRawNodeID: node.protocolNodeID),
            issuedSequence: issuedSequence
        )
        return .requestChildNodes(
            targetID: nodeID.documentID.targetID,
            nodeID: node.protocolNodeID,
            depth: max(1, depth)
        )
    }

    package func pendingFrameOwnerHydrationIntent(issuedSequence: UInt64 = 0) -> DOMCommandIntent? {
        guard let candidate = frameDocumentProjectionCoordinator.ownerHydrationCandidate(
            currentPageTargetID: currentPageTargetID,
            targetGraph: targetGraph,
            documentStore: documentStore
        ) else {
            return nil
        }
        return ownerHydrationIntent(
            frameTargetID: candidate.frameTargetID,
            document: candidate.document,
            node: candidate.node,
            issuedSequence: issuedSequence
        )
    }

    package func clearOwnerHydrationTransactions(targetID: ProtocolTarget.ID) {
        documentStore.clearOwnerHydrationTransactions(targetID: targetID)
    }

    package func actionIdentity(
        for nodeID: DOMNode.ID,
        commandTargetID: ProtocolTarget.ID? = nil
    ) -> DOMActionIdentity? {
        guard let node = node(for: nodeID),
              let resolvedCommandTargetID = commandTargetID ?? currentPageTargetID,
              targetGraph.containsTarget(resolvedCommandTargetID) else {
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
        guard let targetID = targetID ?? currentPageTargetID else {
            return nil
        }
        return .hideHighlight(targetID: targetID)
    }

    package func setInspectModeEnabledIntent(
        targetID: ProtocolTarget.ID? = nil,
        enabled: Bool
    ) -> DOMCommandIntent? {
        guard let targetID = targetID ?? currentPageTargetID,
              targetGraph.containsTarget(targetID) else {
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
        DOMPathBuilder(nodeProvider: { [weak self] nodeID in
            self?.node(for: nodeID)
        }).selectorPath(for: node)
    }

    package func xPath(for node: DOMNode) -> String {
        DOMPathBuilder(nodeProvider: { [weak self] nodeID in
            self?.node(for: nodeID)
        }).xPath(for: node)
    }

    package func beginInspectSelectionRequest(
        targetID: ProtocolTarget.ID,
        objectID: String,
        issuedSequence: UInt64 = 0
    ) -> Result<DOMCommandIntent, SelectionResolutionFailure> {
        guard objectID.isEmpty == false else {
            return failSelection(.missingObjectID)
        }
        guard let document = documentStore.currentDocument(forTargetID: targetID),
              document.lifecycle == .loaded,
              document.nodesByID[document.rootNodeID] != nil else {
            return failSelection(.missingCurrentDocument(targetID))
        }

        nextSelectionRequestRawID &+= 1
        let requestID = SelectionRequestIdentifier(nextSelectionRequestRawID)
        let transactionID = registerTransaction(
            targetID: targetID,
            document: document,
            kind: .requestNode(selectionRequestID: requestID, objectID: objectID),
            issuedSequence: issuedSequence
        )
        cancelSelectionTransaction(for: selection.beginRequest(DOMSelectionRequest(
            id: requestID,
            targetID: targetID,
            documentID: document.id,
            transactionID: transactionID
        )))
        return .success(.requestNode(selectionRequestID: requestID, targetID: targetID, objectID: objectID))
    }

    package func applyRequestNodeResult(
        selectionRequestID: SelectionRequestIdentifier,
        targetID: ProtocolTarget.ID,
        nodeID: DOMProtocolNodeID
    ) -> DOMRequestNodeResolution {
        guard let document = documentStore.currentDocument(forTargetID: targetID),
              document.lifecycle == .loaded else {
            return failSelection(.missingCurrentDocument(targetID), clearSelected: false)
        }
        guard let pendingRequest = selection.pendingRequest else {
            return failSelection(
                .staleSelectionRequest(expected: nil, received: selectionRequestID),
                clearSelected: false
            )
        }
        guard pendingRequest.id == selectionRequestID else {
            let failure = SelectionResolutionFailure.staleSelectionRequest(
                expected: pendingRequest.id,
                received: selectionRequestID
            )
            selection.rejectStaleRequest(failure)
            return .failed(failure)
        }
        guard pendingRequest.targetID == targetID else {
            return failSelection(.targetMismatch(expected: pendingRequest.targetID, received: targetID))
        }
        let currentDocumentID = document.id
        guard currentDocumentID == pendingRequest.documentID else {
            return failSelection(
                .staleDocument(expected: pendingRequest.documentID, actual: currentDocumentID),
                clearSelected: false
            )
        }
        let key = DOMNodeCurrentKey(targetID: targetID, nodeID: nodeID)
        materializePendingRequestNodePath(
            document: document,
            nodeID: nodeID
        )
        if let selectedNodeID = document.currentNodeIDByProtocolNodeID[nodeID],
           selectedNodeID.documentID == pendingRequest.documentID {
            completePendingSelection(selectedNodeID, pendingRequest: pendingRequest)
            return .resolved(selectedNodeID)
        }

        guard let transactionID = pendingRequest.transactionID,
              document.recordRequestedProtocolNodeID(nodeID, for: transactionID) else {
            return failSelection(.unresolvedNode(key))
        }
        selection.clearFailure()
        return .pending(key)
    }

    package func treeProjection(rootTargetID: ProtocolTarget.ID) -> DOMTreeProjection {
        guard let document = documentStore.currentDocument(forTargetID: rootTargetID),
              document.lifecycle == .loaded else {
            return DOMTreeProjection()
        }
        return DOMTreeProjectionBuilder(
            rootDocument: document,
            nodeProvider: { [weak self] nodeID in
                self?.node(for: nodeID)
            },
            frameDocumentRootResolver: { [weak self] ownerNodeID in
                self?.projectedFrameDocumentRootID(for: ownerNodeID)
            }
        )
        .build()
    }

    package func snapshot() -> DOMSessionSnapshot {
        DOMSessionSnapshotBuilder(
            currentPageTargetID: currentPageTargetID,
            mainFrameID: mainFrameID,
            targetSnapshots: targetGraph.targetSnapshots(currentDocumentID: currentDocumentID(for:)),
            targetStateSnapshots: documentStore.targetStateSnapshots(currentDocumentID: currentDocumentID(for:)),
            frameSnapshots: targetGraph.frameSnapshots(),
            documents: documentStore.currentDocuments,
            frameDocumentProjections: frameDocumentProjectionCoordinator.snapshots(),
            transactions: documentStore.transactions(),
            currentNodeIDByKey: documentStore.currentNodeIDsByKey(),
            executionContextsByKey: targetGraph.executionContextSnapshots(),
            selection: selection
        ).build()
    }

    private func buildSubtree(
        _ payload: DOMNodePayload,
        documentID: DOMDocument.ID,
        parentID: DOMNode.ID?,
        nodeIndex: inout DOMDocumentNodeIndex
    ) -> DOMNode.ID {
        let nodeID = DOMNode.ID(documentID: documentID, nodeID: payload.nodeID)
        let node: DOMNode
        if let existingNode = nodeIndex.node(for: nodeID) {
            node = existingNode
            node.update(from: payload, parentID: parentID)
        } else {
            node = DOMNode(id: nodeID, payload: payload, parentID: parentID)
        }
        nodeIndex.store(node, rawNodeID: payload.nodeID)

        switch payload.regularChildren {
        case let .unrequested(count):
            node.regularChildren = .unrequested(count: count)
        case let .loaded(children):
            node.regularChildren = .loaded(
                children.map {
                    buildSubtree(
                        $0,
                        documentID: documentID,
                        parentID: nodeID,
                        nodeIndex: &nodeIndex
                    )
                }
            )
        }

        node.contentDocumentID = payload.contentDocument.first.map {
            buildSubtree($0, documentID: documentID, parentID: nodeID, nodeIndex: &nodeIndex)
        }
        node.shadowRootIDs = payload.shadowRoots.map {
            buildSubtree($0, documentID: documentID, parentID: nodeID, nodeIndex: &nodeIndex)
        }
        node.templateContentID = payload.templateContent.first.map {
            buildSubtree($0, documentID: documentID, parentID: nodeID, nodeIndex: &nodeIndex)
        }
        node.beforePseudoElementID = payload.beforePseudoElement.first.map {
            buildSubtree($0, documentID: documentID, parentID: nodeID, nodeIndex: &nodeIndex)
        }
        node.otherPseudoElementIDs = payload.otherPseudoElements.map {
            buildSubtree($0, documentID: documentID, parentID: nodeID, nodeIndex: &nodeIndex)
        }
        node.afterPseudoElementID = payload.afterPseudoElement.first.map {
            buildSubtree($0, documentID: documentID, parentID: nodeID, nodeIndex: &nodeIndex)
        }

        relinkProtocolEffectiveChildren(of: node, nodesByID: nodeIndex.nodesByID)
        return nodeID
    }

    @discardableResult
    private func buildSubtree(
        _ payload: DOMNodePayload,
        document: DOMDocument,
        parentID: DOMNode.ID?
    ) -> DOMNode.ID {
        if let existingNodeID = document.currentNodeIDByProtocolNodeID[payload.nodeID],
           existingNodeID != DOMNode.ID(documentID: document.id, nodeID: payload.nodeID) {
            removeNodeSubtree(existingNodeID, detachFromParent: true)
        }
        pruneOmittedOwnedChildren(fromExistingSubtreeMatching: payload, in: document)
        let oldNodeIDs = Set(document.nodesByID.keys)
        let oldCurrentNodeIDByProtocolNodeID = document.currentNodeIDByProtocolNodeID
        var nodeIndex = document.nodeIndexSnapshot
        let nodeID = buildSubtree(
            payload,
            documentID: document.id,
            parentID: parentID,
            nodeIndex: &nodeIndex
        )
        if Set(nodeIndex.nodesByID.keys) != oldNodeIDs
            || nodeIndex.currentNodeIDByProtocolNodeID != oldCurrentNodeIDByProtocolNodeID {
            document.replaceNodeIndex(nodeIndex)
        }
        return nodeID
    }

    private func pruneOmittedOwnedChildren(fromExistingSubtreeMatching payload: DOMNodePayload, in document: DOMDocument) {
        let nodeID = DOMNode.ID(documentID: document.id, nodeID: payload.nodeID)
        guard let node = document.nodesByID[nodeID] else {
            return
        }
        let payloadChildren = payloadOwnedChildren(payload)
        let retainedChildIDs = Set(payloadChildren.map { DOMNode.ID(documentID: document.id, nodeID: $0.nodeID) })
        for childID in node.protocolOwnedChildren where retainedChildIDs.contains(childID) == false {
            removeNodeSubtree(childID, detachFromParent: false)
        }
        for childPayload in payloadChildren {
            pruneOmittedOwnedChildren(fromExistingSubtreeMatching: childPayload, in: document)
        }
    }

    private func removeDocuments(for targetID: ProtocolTarget.ID) {
        guard let documentID = documentStore.currentDocument(forTargetID: targetID)?.id else {
            return
        }
        removeDocument(documentID)
    }

    private func removeDocument(_ documentID: DOMDocument.ID) {
        guard let targetState = documentStore.stateIfPresent(for: documentID.targetID),
              let document = targetState.currentDocument,
              document.id == documentID else {
            return
        }
        document.lifecycle = .invalidated
        targetState.currentDocument = nil
        document.transactions.removeAll()
        clearCurrentDocumentReference(documentID, targetID: document.targetID)
        updateAllFrameDocumentProjectionStates()
        if selection.clearSelected(ifDocument: documentID) {
            recordSelectionMutation()
            syncSelectedElementStyles()
        }
    }

    private func clearCurrentDocumentReference(_ documentID: DOMDocument.ID, targetID: ProtocolTarget.ID) {
        clearCurrentDocumentReference(
            documentID,
            targetID: targetID,
            targetFrameID: targetGraph.targetFrameID(for: targetID)
        )
    }

    private func clearCurrentDocumentReference(
        _ documentID: DOMDocument.ID,
        targetID: ProtocolTarget.ID,
        targetFrameID: DOMFrame.ID?
    ) {
        targetGraph.clearCurrentDocumentReference(
            documentID,
            targetFrameID: targetFrameID,
            targetID: targetID,
            currentPageTargetID: currentPageTargetID,
            mainFrameID: mainFrameID
        )
    }

    @discardableResult
    private func registerTransaction(
        targetID: ProtocolTarget.ID,
        document: DOMDocument,
        kind: DOMTransactionKind,
        issuedSequence: UInt64
    ) -> DOMTransaction.ID? {
        guard let targetState = documentStore.stateIfPresent(for: targetID),
              targetState.currentDocument === document else {
            return nil
        }
        return document.startTransaction(kind: kind, issuedSequence: issuedSequence)
    }

    private func removeTransaction(_ transactionID: DOMTransaction.ID, targetID: ProtocolTarget.ID?) {
        documentStore.removeTransaction(transactionID, targetID: targetID)
    }

    private func cancelSelectionTransaction(for request: DOMSelectionRequest?) {
        guard let request,
              let transactionID = request.transactionID else {
            return
        }
        removeTransaction(transactionID, targetID: request.targetID)
    }

    private func hasActiveOwnerHydrationTransaction(
        targetID: ProtocolTarget.ID,
        documentID: DOMDocument.ID
    ) -> Bool {
        guard let document = documentStore.currentDocument(forTargetID: targetID),
              document.id == documentID else {
            return false
        }
        return document.hasActiveOwnerHydrationTransaction()
    }

    private func ownerHydrationIntent(
        frameTargetID: ProtocolTarget.ID,
        document: DOMDocument,
        node: DOMNode,
        issuedSequence: UInt64
    ) -> DOMCommandIntent? {
        guard hasUnloadedRegularChildren(node),
              !hasActiveOwnerHydrationTransaction(targetID: document.targetID, documentID: document.id) else {
            return nil
        }
        registerTransaction(
            targetID: document.targetID,
            document: document,
            kind: .ownerHydration(frameTargetID: frameTargetID),
            issuedSequence: issuedSequence
        )
        return .requestChildNodes(
            targetID: document.targetID,
            nodeID: node.protocolNodeID,
            depth: 1
        )
    }

    private func splicePendingTransactionFragments(parentRawNodeID: DOMProtocolNodeID, into document: DOMDocument) {
        var visitedParentRawNodeIDs = Set<DOMProtocolNodeID>()
        splicePendingTransactionFragments(
            parentRawNodeID: parentRawNodeID,
            into: document,
            visitedParentRawNodeIDs: &visitedParentRawNodeIDs
        )
        completePendingSelectionIfPossible(in: document)
    }

    private func splicePendingTransactionFragments(
        parentRawNodeID: DOMProtocolNodeID,
        into document: DOMDocument,
        visitedParentRawNodeIDs: inout Set<DOMProtocolNodeID>
    ) {
        guard visitedParentRawNodeIDs.insert(parentRawNodeID).inserted else {
            return
        }
        for transactionID in Array(document.transactions.keys) {
            guard var transaction = document.transactions[transactionID],
                  let fragments = transaction.pathFragmentsByParentRawNodeID.removeValue(forKey: parentRawNodeID),
                  let parentID = document.currentNodeIDByProtocolNodeID[parentRawNodeID],
                  let parent = document.nodesByID[parentID] else {
                continue
            }
            let incomingRawNodeIDs = Set(fragments.map(\.nodeID))
            let childIDsToRemove = parent.regularChildren.loadedChildren.filter { childID in
                guard let child = document.nodesByID[childID] else {
                    return true
                }
                return incomingRawNodeIDs.contains(child.protocolNodeID) == false
            }
            let replacementOwnerKeys = childIDsToRemove
                .reduce(into: [ProtocolTarget.ID: DOMNodeCurrentKey]()) { partialResult, childID in
                    partialResult.merge(projectedFrameOwnerKeys(inSubtree: childID)) { current, _ in current }
                }
            for childID in childIDsToRemove {
                removeNodeSubtree(childID, detachFromParent: false)
            }
            parent.regularChildren = .loaded(fragments.map {
                buildSubtree($0, document: document, parentID: parentID)
            })
            relinkProtocolEffectiveChildren(of: parent)
            reattachFrameDocumentProjections(using: replacementOwnerKeys)
            document.transactions[transactionID] = transaction
            for childID in parent.regularChildren.loadedChildren {
                guard let child = document.nodesByID[childID] else {
                    continue
                }
                splicePendingTransactionFragments(
                    parentRawNodeID: child.protocolNodeID,
                    into: document,
                    visitedParentRawNodeIDs: &visitedParentRawNodeIDs
                )
            }
        }
    }

    private func materializePendingRequestNodePath(
        document: DOMDocument,
        nodeID: DOMProtocolNodeID
    ) {
        for transaction in document.transactions.values {
            guard case .requestNode = transaction.kind,
                  let anchorRawNodeID = knownAncestorRawNodeID(
                    for: nodeID,
                    in: transaction,
                    document: document
                  ) else {
                continue
            }
            splicePendingTransactionFragments(parentRawNodeID: anchorRawNodeID, into: document)
            if document.currentNodeIDByProtocolNodeID[nodeID] != nil {
                return
            }
        }
    }

    private func completePendingSelectionIfPossible(in document: DOMDocument) {
        guard let pendingRequest = selection.pendingRequest,
              pendingRequest.targetID == document.targetID,
              pendingRequest.documentID == document.id,
              let transactionID = pendingRequest.transactionID,
              let transaction = document.transactions[transactionID],
              let requestedProtocolNodeID = transaction.requestedProtocolNodeID else {
            return
        }

        guard let selectedNodeID = document.currentNodeIDByProtocolNodeID[requestedProtocolNodeID],
              selectedNodeID.documentID == document.id else {
            return
        }
        completePendingSelection(selectedNodeID, pendingRequest: pendingRequest)
    }

    private func knownAncestorRawNodeID(
        for nodeID: DOMProtocolNodeID,
        in transaction: DOMTransaction,
        document: DOMDocument
    ) -> DOMProtocolNodeID? {
        if document.currentNodeIDByProtocolNodeID[nodeID] != nil {
            return nodeID
        }

        let parentRawNodeIDByChildRawNodeID = parentRawNodeIDByChildRawNodeID(
            in: transaction.pathFragmentsByParentRawNodeID
        )
        var currentRawNodeID = nodeID
        var visitedRawNodeIDs = Set<DOMProtocolNodeID>()
        while visitedRawNodeIDs.insert(currentRawNodeID).inserted,
              let parentRawNodeID = parentRawNodeIDByChildRawNodeID[currentRawNodeID] {
            if document.currentNodeIDByProtocolNodeID[parentRawNodeID] != nil {
                return parentRawNodeID
            }
            currentRawNodeID = parentRawNodeID
        }
        return nil
    }

    private func parentRawNodeIDByChildRawNodeID(
        in fragmentsByParentRawNodeID: [DOMProtocolNodeID: [DOMNodePayload]]
    ) -> [DOMProtocolNodeID: DOMProtocolNodeID] {
        var parentRawNodeIDByChildRawNodeID: [DOMProtocolNodeID: DOMProtocolNodeID] = [:]
        for (parentRawNodeID, fragments) in fragmentsByParentRawNodeID {
            for fragment in fragments {
                appendParentRawNodeIDs(
                    fragment,
                    parentRawNodeID: parentRawNodeID,
                    to: &parentRawNodeIDByChildRawNodeID
                )
            }
        }
        return parentRawNodeIDByChildRawNodeID
    }

    private func appendParentRawNodeIDs(
        _ payload: DOMNodePayload,
        parentRawNodeID: DOMProtocolNodeID,
        to parentRawNodeIDByChildRawNodeID: inout [DOMProtocolNodeID: DOMProtocolNodeID]
    ) {
        parentRawNodeIDByChildRawNodeID[payload.nodeID] = parentRawNodeID
        let regularChildren: [DOMNodePayload]
        switch payload.regularChildren {
        case let .loaded(children):
            regularChildren = children
        case .unrequested:
            regularChildren = []
        }
        for child in regularChildren {
            appendParentRawNodeIDs(
                child,
                parentRawNodeID: payload.nodeID,
                to: &parentRawNodeIDByChildRawNodeID
            )
        }
        for child in payload.contentDocument
            + payload.shadowRoots
            + payload.templateContent
            + payload.beforePseudoElement
            + payload.otherPseudoElements
            + payload.afterPseudoElement {
            appendParentRawNodeIDs(
                child,
                parentRawNodeID: payload.nodeID,
                to: &parentRawNodeIDByChildRawNodeID
            )
        }
    }

    private func canApplyDOMEvent(to nodeID: DOMNode.ID) -> Bool {
        guard let document = documentStore.currentDocument(forTargetID: nodeID.documentID.targetID),
              document.id == nodeID.documentID,
              document.lifecycle == .loaded else {
            return false
        }
        return document.nodesByID[nodeID] != nil
    }

    private func payloadContainsConnectedDocumentNode(_ payload: DOMNodePayload, in document: DOMDocument) -> Bool {
        if let existingNodeID = document.currentNodeIDByProtocolNodeID[payload.nodeID],
           document.containsConnectedNode(existingNodeID) {
            return true
        }
        for child in payloadOwnedChildren(payload) {
            if payloadContainsConnectedDocumentNode(child, in: document) {
                return true
            }
        }
        return false
    }

    private func payloadOwnedChildren(_ payload: DOMNodePayload) -> [DOMNodePayload] {
        var children: [DOMNodePayload] = []
        if case let .loaded(regularChildren) = payload.regularChildren {
            children.append(contentsOf: regularChildren)
        }
        children.append(contentsOf: payload.contentDocument)
        children.append(contentsOf: payload.shadowRoots)
        children.append(contentsOf: payload.templateContent)
        children.append(contentsOf: payload.beforePseudoElement)
        children.append(contentsOf: payload.otherPseudoElements)
        children.append(contentsOf: payload.afterPseudoElement)
        return children
    }

    private func removeNodeSubtree(_ nodeID: DOMNode.ID, detachFromParent: Bool) {
        guard let document = documentStore.currentDocument(forTargetID: nodeID.documentID.targetID),
              document.id == nodeID.documentID,
              let node = document.nodesByID[nodeID] else {
            return
        }
        if detachFromParent {
            detachNode(nodeID, from: node.parentID)
        }
        for childID in node.protocolOwnedChildren {
            removeNodeSubtree(childID, detachFromParent: false)
        }
        frameDocumentProjectionCoordinator.detachProjections(attachedTo: nodeID)
        document.removeNode(nodeID, ifCurrentFor: node.protocolNodeID)
    }

    private func detachNode(_ nodeID: DOMNode.ID, from parentID: DOMNode.ID?) {
        guard let parentID, let parent = node(for: parentID) else {
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
            guard let child = node(for: childID) else {
                continue
            }
            child.parentID = parent.id
            child.previousSiblingID = index > 0 ? children[index - 1] : nil
            child.nextSiblingID = index + 1 < children.count ? children[index + 1] : nil
        }
    }

    private func relinkProtocolEffectiveChildren(of parent: DOMNode, nodesByID: [DOMNode.ID: DOMNode]) {
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

    private func projectedFrameOwnerKeys(inSubtree rootID: DOMNode.ID) -> [ProtocolTarget.ID: DOMNodeCurrentKey] {
        frameDocumentProjectionCoordinator.projectedFrameOwnerKeys(inSubtree: rootID) { [weak self] nodeID in
            self?.node(for: nodeID)
        }
    }

    private func reattachFrameDocumentProjections(using ownerKeys: [ProtocolTarget.ID: DOMNodeCurrentKey]) {
        frameDocumentProjectionCoordinator.reattachProjections(
            using: ownerKeys,
            documentStore: documentStore,
            nodeProvider: { [weak self] nodeID in
                self?.node(for: nodeID)
            },
            canApplyDOMEvent: { [weak self] nodeID in
                self?.canApplyDOMEvent(to: nodeID) == true
            }
        )
    }

    private func setFrameDocumentProjection(frameTargetID: ProtocolTarget.ID, frameDocumentID: DOMDocument.ID) {
        frameDocumentProjectionCoordinator.setFrameDocument(
            frameTargetID: frameTargetID,
            frameDocumentID: frameDocumentID
        )
    }

    private func updateAllFrameDocumentProjectionStates() {
        frameDocumentProjectionCoordinator.updateAllProjectionStates(
            currentPageTargetID: currentPageTargetID,
            targetGraph: targetGraph,
            documentStore: documentStore
        )
    }

    private func projectedFrameDocumentRootID(for ownerNodeID: DOMNode.ID) -> DOMNode.ID? {
        frameDocumentProjectionCoordinator.projectedFrameDocumentRootID(
            forOwnerNodeID: ownerNodeID,
            documentStore: documentStore
        )
    }

    private func projectedVisibleChildren(of node: DOMNode) -> [DOMNode.ID] {
        DOMTreeProjectionBuilder.visibleChildIDs(of: node) { [weak self] ownerNodeID in
            self?.projectedFrameDocumentRootID(for: ownerNodeID)
        }
    }

    private func reconcileSelection() {
        let didClearSelection = selection.clearSelectedIfStale(nodeExists: { nodeID in
            node(for: nodeID) != nil
        })
        if didClearSelection {
            recordSelectionMutation()
        }
        syncSelectedElementStyles()
    }

    private func completePendingSelection(
        _ selectedNodeID: DOMNode.ID,
        pendingRequest: DOMSelectionRequest
    ) {
        let completedRequest = selection.complete(selectedNodeID, pendingRequest: pendingRequest)
        cancelSelectionTransaction(for: completedRequest)
        if completedRequest != nil {
            recordSelectionMutation()
        }
        syncSelectedElementStyles()
    }

    private func failSelection(
        _ failure: SelectionResolutionFailure,
        clearSelected: Bool = true
    ) -> Result<DOMCommandIntent, SelectionResolutionFailure> {
        recordSelectionFailure(failure, clearSelected: clearSelected)
        syncSelectedElementStyles()
        return .failure(failure)
    }

    private func failSelection(
        _ failure: SelectionResolutionFailure,
        clearSelected: Bool = true
    ) -> Result<DOMNode.ID, SelectionResolutionFailure> {
        recordSelectionFailure(failure, clearSelected: clearSelected)
        syncSelectedElementStyles()
        return .failure(failure)
    }

    private func failSelection(
        _ failure: SelectionResolutionFailure,
        clearSelected: Bool = true
    ) -> DOMRequestNodeResolution {
        recordSelectionFailure(failure, clearSelected: clearSelected)
        syncSelectedElementStyles()
        return .failed(failure)
    }

    private func recordSelectionFailure(
        _ failure: SelectionResolutionFailure,
        clearSelected: Bool
    ) {
        let previousSelectedNodeID = selection.selectedNodeID
        cancelSelectionTransaction(for: selection.fail(failure, clearSelected: clearSelected))
        if selection.selectedNodeID != previousSelectedNodeID {
            recordSelectionMutation()
        }
    }

    package func syncSelectedElementStyles() {
        switch selectedCSSNodeStyleIdentity() {
        case let .success(identity):
            elementStyles.selectNodeStyles(identity: identity)
        case let .failure(reason):
            elementStyles.markSelectedNodeUnavailable(reason)
        }
        reconcileSelectedNodeStyleHydrationIfNeeded()
    }
}
