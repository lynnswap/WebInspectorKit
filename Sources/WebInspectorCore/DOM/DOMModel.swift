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
    package var capabilities: ProtocolTargetCapabilities
    package var isProvisional: Bool
    package var isPaused: Bool

    package init(
        id: ID,
        kind: ProtocolTargetKind,
        frameID: DOMFrame.ID?,
        parentFrameID: DOMFrame.ID?,
        capabilities: ProtocolTargetCapabilities,
        isProvisional: Bool,
        isPaused: Bool
    ) {
        self.id = id
        self.kind = kind
        self.frameID = frameID
        self.parentFrameID = parentFrameID
        self.capabilities = capabilities
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
package final class DOMTargetState {
    package let targetID: ProtocolTarget.ID
    package var currentDocument: DOMDocumentState?
    package var nextDocumentLifetimeID: UInt64

    package init(targetID: ProtocolTarget.ID) {
        self.targetID = targetID
        currentDocument = nil
        nextDocumentLifetimeID = 0
    }

    package func nextDocumentID() -> DOMDocument.ID {
        nextDocumentLifetimeID &+= 1
        return DOMDocument.ID(
            targetID: targetID,
            localDocumentLifetimeID: DOMDocumentLifetimeIdentifier(nextDocumentLifetimeID)
        )
    }
}

@MainActor
@Observable
package final class DOMFrame {
    package typealias ID = DOMFrameIdentifier

    package let id: ID
    package var parentFrameID: ID?
    package var childFrameIDs: Set<ID>
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
package final class DOMDocumentState {
    package typealias ID = DOMDocumentIdentifier

    package let id: ID
    package let targetID: ProtocolTarget.ID
    package let localDocumentLifetimeID: DOMDocumentLifetimeIdentifier
    package var lifecycle: DOMDocumentLifecycle
    package let rootNodeID: DOMNode.ID
    package var nodesByID: [DOMNode.ID: DOMNode]
    package var currentNodeIDByProtocolNodeID: [DOMProtocolNodeID: DOMNode.ID]
    package var transactions: [DOMTransaction.ID: DOMTransaction]
    package var nextTransactionID: UInt64

    package init(
        id: ID,
        targetID: ProtocolTarget.ID,
        lifecycle: DOMDocumentLifecycle,
        rootNodeID: DOMNode.ID,
        nodesByID: [DOMNode.ID: DOMNode],
        currentNodeIDByProtocolNodeID: [DOMProtocolNodeID: DOMNode.ID]
    ) {
        self.id = id
        self.targetID = targetID
        self.localDocumentLifetimeID = id.localDocumentLifetimeID
        self.lifecycle = lifecycle
        self.rootNodeID = rootNodeID
        self.nodesByID = nodesByID
        self.currentNodeIDByProtocolNodeID = currentNodeIDByProtocolNodeID
        transactions = [:]
        nextTransactionID = 0
    }

    package func nextTransactionIdentifier() -> DOMTransaction.ID {
        nextTransactionID &+= 1
        return DOMTransaction.ID(nextTransactionID)
    }

    @discardableResult
    package func startTransaction(kind: DOMTransactionKind, issuedSequence: UInt64) -> DOMTransaction.ID {
        let transactionID = nextTransactionIdentifier()
        transactions[transactionID] = DOMTransaction(
            id: transactionID,
            targetID: targetID,
            documentID: id,
            kind: kind,
            issuedSequence: issuedSequence,
            requestedProtocolNodeID: nil,
            pathFragmentsByParentRawNodeID: [:]
        )
        return transactionID
    }

    package func removeTransaction(_ transactionID: DOMTransaction.ID) {
        transactions.removeValue(forKey: transactionID)
    }

    package func removeChildNodesTransactions(parentRawNodeID: DOMProtocolNodeID) {
        removeTransactions { transaction in
            transaction.kind == .requestChildNodes(parentRawNodeID: parentRawNodeID)
        }
    }

    package func removeOwnerHydrationTransactions() {
        removeTransactions { transaction in
            if case .ownerHydration = transaction.kind {
                return true
            }
            return false
        }
    }

    package func hasActiveOwnerHydrationTransaction() -> Bool {
        transactions.values.contains { transaction in
            if case .ownerHydration = transaction.kind {
                return true
            }
            return false
        }
    }

    package func storePendingPathFragments(
        parentRawNodeID: DOMProtocolNodeID,
        payloads: [DOMNodePayload]
    ) {
        for transactionID in Array(transactions.keys) {
            guard var transaction = transactions[transactionID] else {
                continue
            }
            switch transaction.kind {
            case .requestNode:
                transaction.pathFragmentsByParentRawNodeID[parentRawNodeID] = payloads
            case let .requestChildNodes(transactionParentRawNodeID) where transactionParentRawNodeID == parentRawNodeID:
                transaction.pathFragmentsByParentRawNodeID[parentRawNodeID] = payloads
            case .requestChildNodes:
                continue
            case .ownerHydration:
                continue
            }
            transactions[transactionID] = transaction
        }
    }

    package func recordRequestedProtocolNodeID(
        _ nodeID: DOMProtocolNodeID,
        for transactionID: DOMTransaction.ID
    ) -> Bool {
        guard var transaction = transactions[transactionID],
              transaction.documentID == id else {
            return false
        }
        transaction.requestedProtocolNodeID = nodeID
        transactions[transactionID] = transaction
        return true
    }

    private func removeTransactions(where shouldRemove: (DOMTransaction) -> Bool) {
        for transactionID in Array(transactions.keys) {
            guard let transaction = transactions[transactionID],
                  shouldRemove(transaction) else {
                continue
            }
            transactions.removeValue(forKey: transactionID)
        }
    }
}

package typealias DOMDocument = DOMDocumentState

@MainActor
@Observable
package final class FrameDocumentProjection {
    package var ownerNodeID: DOMNode.ID?
    package var frameTargetID: ProtocolTarget.ID
    package var frameDocumentID: DOMDocument.ID
    package var state: FrameDocumentProjectionState

    package init(
        ownerNodeID: DOMNode.ID?,
        frameTargetID: ProtocolTarget.ID,
        frameDocumentID: DOMDocument.ID,
        state: FrameDocumentProjectionState
    ) {
        self.ownerNodeID = ownerNodeID
        self.frameTargetID = frameTargetID
        self.frameDocumentID = frameDocumentID
        self.state = state
    }
}

package struct DOMTransaction {
    package typealias ID = DOMTransactionIdentifier

    package var id: ID
    package var targetID: ProtocolTarget.ID
    package var documentID: DOMDocument.ID
    package var kind: DOMTransactionKind
    package var issuedSequence: UInt64
    package var requestedProtocolNodeID: DOMProtocolNodeID?
    package var pathFragmentsByParentRawNodeID: [DOMProtocolNodeID: [DOMNodePayload]]
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
    package var ownerFrameID: DOMFrame.ID?
    package var documentURL: String?
    package var baseURL: String?
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
        self.ownerFrameID = payload.ownerFrameID
        self.documentURL = payload.documentURL
        self.baseURL = payload.baseURL
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
    package var transactionID: DOMTransaction.ID?
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
    package private(set) var currentPageTargetID: ProtocolTarget.ID?
    package private(set) var mainFrameID: DOMFrame.ID?
    package private(set) var treeRevision: UInt64
    package private(set) var selectionRevision: UInt64

    private var targetsByID: [ProtocolTarget.ID: ProtocolTarget]
    private var targetStatesByID: [ProtocolTarget.ID: DOMTargetState]
    private var framesByID: [DOMFrame.ID: DOMFrame]
    private var frameDocumentProjections: [ProtocolTarget.ID: FrameDocumentProjection]
    private var selection: DOMSelection
    private var executionContextsByID: [ExecutionContextID: ExecutionContextRecord]
    private var nextSelectionRequestRawID: UInt64

    package init() {
        currentPageTargetID = nil
        mainFrameID = nil
        treeRevision = 0
        selectionRevision = 0
        targetsByID = [:]
        targetStatesByID = [:]
        framesByID = [:]
        frameDocumentProjections = [:]
        selection = DOMSelection()
        executionContextsByID = [:]
        nextSelectionRequestRawID = 0
    }

    private func targetBelongsToCurrentPage(_ targetID: ProtocolTarget.ID) -> Bool {
        guard targetsByID[targetID] != nil else {
            return false
        }
        guard currentPageTargetID != targetID else {
            return true
        }
        guard let frameID = targetsByID[targetID]?.frameID else {
            return false
        }

        var currentFrameID: DOMFrame.ID? = frameID
        var visitedFrameIDs = Set<DOMFrame.ID>()
        while let candidateFrameID = currentFrameID,
              visitedFrameIDs.insert(candidateFrameID).inserted {
            if candidateFrameID == mainFrameID {
                return true
            }
            currentFrameID = framesByID[candidateFrameID]?.parentFrameID
        }
        return false
    }

    private func state(for targetID: ProtocolTarget.ID) -> DOMTargetState {
        let state = targetStatesByID[targetID] ?? DOMTargetState(targetID: targetID)
        targetStatesByID[targetID] = state
        return state
    }

    private func currentState(for targetID: ProtocolTarget.ID) -> DOMTargetState? {
        guard targetBelongsToCurrentPage(targetID) || currentPageTargetID == nil else {
            return nil
        }
        return targetStatesByID[targetID]
    }

    private func currentDocument(for documentID: DOMDocument.ID) -> DOMDocument? {
        guard let document = targetStatesByID[documentID.targetID]?.currentDocument,
              document.id == documentID,
              document.lifecycle == .loaded else {
            return nil
        }
        return document
    }

    private func document(for nodeID: DOMNode.ID) -> DOMDocument? {
        currentDocument(for: nodeID.documentID)
    }

    private func attachFrameTarget(_ target: ProtocolTarget) {
        guard let frameID = target.frameID else {
            return
        }
        let frame = frameWithID(frameID, parentFrameID: target.parentFrameID)
        frame.targetID = target.id
        _ = state(for: target.id)
    }

    private func attachKnownFrameTargets() {
        var attachedTargetIDs = Set<ProtocolTarget.ID>()
        var didAttach = true
        while didAttach {
            didAttach = false
            for target in targetsByID.values where target.kind == .frame && attachedTargetIDs.contains(target.id) == false {
                guard let parentFrameID = target.parentFrameID,
                      parentFrameID == mainFrameID || framesByID[parentFrameID] != nil else {
                    continue
                }
                attachFrameTarget(target)
                attachedTargetIDs.insert(target.id)
                didAttach = true
            }
        }
    }

    package func reset() {
        currentPageTargetID = nil
        mainFrameID = nil
        treeRevision = 0
        selectionRevision = 0
        targetsByID.removeAll()
        targetStatesByID.removeAll()
        framesByID.removeAll()
        frameDocumentProjections.removeAll()
        selection = DOMSelection()
        executionContextsByID.removeAll()
        nextSelectionRequestRawID = 0
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
            capabilities: record.capabilities,
            isProvisional: record.isProvisional,
            isPaused: record.isPaused
        )
        target.kind = record.kind
        target.frameID = record.frameID
        target.parentFrameID = record.parentFrameID
        target.capabilities = record.capabilities
        target.isProvisional = record.isProvisional
        target.isPaused = record.isPaused
        targetsByID[record.id] = target
        _ = state(for: record.id)

        if record.kind == .frame {
            attachFrameTarget(target)
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

        let resolvedMainFrameID = target.frameID ?? DOMFrame.ID("main:\(targetID.rawValue)")
        if let currentPageTargetID, currentPageTargetID != targetID {
            selection = DOMSelection()
            selectionRevision &+= 1
        }
        currentPageTargetID = targetID
        mainFrameID = resolvedMainFrameID
        _ = state(for: targetID)
        let mainFrame = frameWithID(resolvedMainFrameID, parentFrameID: nil)
        mainFrame.targetID = targetID
        target.frameID = resolvedMainFrameID
        attachKnownFrameTargets()
        treeRevision &+= 1
    }

    package func applyTargetCommitted(targetID: ProtocolTarget.ID) {
        guard let target = targetsByID[targetID] else {
            return
        }

        target.isProvisional = false
        if target.kind == .frame {
            attachFrameTarget(target)
        }
    }

    package func applyTargetCommitted(oldTargetID: ProtocolTarget.ID, newTargetID: ProtocolTarget.ID) {
        guard oldTargetID != newTargetID else {
            applyTargetCommitted(targetID: newTargetID)
            return
        }

        if currentPageTargetID == oldTargetID,
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
            capabilities: oldTarget.capabilities,
            isProvisional: false,
            isPaused: oldTarget.isPaused
        )
        committedTarget.kind = existingNewTarget?.kind ?? oldTarget.kind
        committedTarget.frameID = frameID
        committedTarget.parentFrameID = parentFrameID
        committedTarget.capabilities = existingNewTarget?.capabilities ?? oldTarget.capabilities
        committedTarget.isProvisional = false
        committedTarget.isPaused = existingNewTarget?.isPaused ?? oldTarget.isPaused
        targetsByID[newTargetID] = committedTarget

        if let oldState = targetStatesByID.removeValue(forKey: oldTargetID) {
            oldState.currentDocument?.transactions.removeAll()
            let newState = state(for: newTargetID)
            if let oldDocument = oldState.currentDocument {
                oldDocument.lifecycle = .invalidated
                clearCurrentDocumentReference(oldDocument.id, target: oldTarget)
                newState.currentDocument = nil
            }
        }

        if let frameID {
            let frame = frameWithID(frameID, parentFrameID: parentFrameID)
            if frame.targetID == oldTargetID || frame.targetID == nil {
                frame.targetID = newTargetID
            }
        }

        if let projection = frameDocumentProjections.removeValue(forKey: oldTargetID) {
            projection.frameTargetID = newTargetID
            frameDocumentProjections[newTargetID] = projection
            updateFrameDocumentProjectionState(projection)
        }

        for (contextID, record) in executionContextsByID where record.targetID == oldTargetID {
            executionContextsByID[contextID] = ExecutionContextRecord(
                id: record.id,
                targetID: newTargetID,
                frameID: record.frameID
            )
        }

        if currentPageTargetID == oldTargetID {
            currentPageTargetID = newTargetID
            if let mainFrameID {
                frameWithID(mainFrameID, parentFrameID: nil).targetID = newTargetID
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
        if let documentID = targetStatesByID[targetID]?.currentDocument?.id {
            removeDocument(documentID)
        }
        frameDocumentProjections.removeValue(forKey: targetID)
        if let frameID = target.frameID,
           framesByID[frameID]?.targetID == targetID {
            framesByID[frameID]?.targetID = nil
            framesByID[frameID]?.currentDocumentID = nil
        }
        if currentPageTargetID == targetID {
            currentPageTargetID = nil
            mainFrameID = nil
            selection = DOMSelection()
        }
        targetStatesByID.removeValue(forKey: targetID)
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
        let targetState = state(for: targetID)
        removeDocuments(for: targetID)

        let documentID = targetState.nextDocumentID()
        var nodesByID: [DOMNode.ID: DOMNode] = [:]
        var currentNodeIDByProtocolNodeID: [DOMProtocolNodeID: DOMNode.ID] = [:]
        let rootNodeID = buildSubtree(
            root,
            documentID: documentID,
            parentID: nil,
            nodesByID: &nodesByID,
            currentNodeIDByProtocolNodeID: &currentNodeIDByProtocolNodeID
        )
        let document = DOMDocument(
            id: documentID,
            targetID: targetID,
            lifecycle: .loaded,
            rootNodeID: rootNodeID,
            nodesByID: nodesByID,
            currentNodeIDByProtocolNodeID: currentNodeIDByProtocolNodeID
        )
        targetState.currentDocument = document

        if let frameID = target.frameID {
            framesByID[frameID]?.currentDocumentID = documentID
        }
        if currentPageTargetID == targetID,
           let mainFrameID {
            framesByID[mainFrameID]?.currentDocumentID = documentID
        }
        if target.kind == .frame {
            setFrameDocumentProjection(frameTargetID: targetID, frameDocumentID: documentID)
        }
        updateAllFrameDocumentProjectionStates()

        reconcileSelection()
        treeRevision &+= 1
        return rootNodeID
    }

    package func invalidateDocument(targetID: ProtocolTarget.ID) {
        guard let target = targetsByID[targetID],
              let targetState = targetStatesByID[targetID],
              let document = targetState.currentDocument else {
            return
        }
        let documentID = document.id
        document.lifecycle = .invalidated
        document.transactions.removeAll()
        if let frameID = target.frameID,
           framesByID[frameID]?.currentDocumentID == documentID {
            framesByID[frameID]?.currentDocumentID = nil
        }
        if currentPageTargetID == targetID,
           let mainFrameID {
            framesByID[mainFrameID]?.currentDocumentID = nil
        }
        if let projection = frameDocumentProjections[targetID],
           projection.frameDocumentID == documentID {
            projection.ownerNodeID = nil
            projection.state = .pending
        }
        reconcileSelection()
        treeRevision &+= 1
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
        guard let document = targetStatesByID[targetID]?.currentDocument,
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
        guard let document = targetStatesByID[targetID]?.currentDocument,
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
        let affectsVisibleTree = nodeIsConnectedToDocumentTree(nodeID, in: document)
        if parent.isFrameOwner,
           projectedFrameDocumentRootID(for: parent.id) != nil {
            document.removeChildNodesTransactions(parentRawNodeID: parent.protocolNodeID)
            return
        }
        var replacementOwnerKeys: [ProtocolTarget.ID: DOMNodeCurrentKey] = [:]
        for childID in parent.regularChildren.loadedChildren {
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
            updateAllFrameDocumentProjectionStates()
            reconcileSelection()
            treeRevision &+= 1
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
        let affectsVisibleTree = nodeIsConnectedToDocumentTree(parentID, in: document)
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
            reattachFrameDocumentProjections(using: replacementOwnerKeys)
            updateAllFrameDocumentProjectionStates()
            reconcileSelection()
            treeRevision &+= 1
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
        let affectsVisibleTree = nodeIsConnectedToDocumentTree(nodeID, in: document)
        removeNodeSubtree(nodeID, detachFromParent: true)
        if affectsVisibleTree {
            updateAllFrameDocumentProjectionStates()
            reconcileSelection()
            treeRevision &+= 1
        }
    }

    package func applyChildNodeCountUpdated(_ nodeID: DOMNode.ID, count: Int) {
        guard let document = currentDocument(for: nodeID.documentID),
              let node = document.nodesByID[nodeID],
              canApplyDOMEvent(to: nodeID) else {
            return
        }
        if case .unrequested = node.regularChildren {
            node.regularChildren = .unrequested(count: max(0, count))
            if nodeIsConnectedToDocumentTree(nodeID, in: document) {
                treeRevision &+= 1
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
        if node.isFrameOwner,
           name.caseInsensitiveCompare("src") == .orderedSame {
            updateAllFrameDocumentProjectionStates()
        }
        if nodeIsConnectedToDocumentTree(nodeID, in: document) {
            treeRevision &+= 1
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
        if node.isFrameOwner,
           name.caseInsensitiveCompare("src") == .orderedSame {
            updateAllFrameDocumentProjectionStates()
        }
        if nodeIsConnectedToDocumentTree(nodeID, in: document) {
            treeRevision &+= 1
        }
    }

    package func currentDocumentID(for targetID: ProtocolTarget.ID) -> DOMDocument.ID? {
        guard let document = targetStatesByID[targetID]?.currentDocument,
              document.lifecycle == .loaded else {
            return nil
        }
        return document.id
    }

    package func targetCapabilities(for targetID: ProtocolTarget.ID) -> ProtocolTargetCapabilities {
        targetsByID[targetID]?.capabilities ?? []
    }

    package func targetKind(for targetID: ProtocolTarget.ID) -> ProtocolTargetKind? {
        targetsByID[targetID]?.kind
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

    package var currentPageRootNode: DOMNode? {
        guard let targetID = currentPageTargetID,
              let document = targetStatesByID[targetID]?.currentDocument,
              document.lifecycle == .loaded
        else {
            return nil
        }
        return document.nodesByID[document.rootNodeID]
    }

    package func node(for id: DOMNode.ID) -> DOMNode? {
        currentDocument(for: id.documentID)?.nodesByID[id]
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
        if let pendingTransactionID = selection.pendingRequest?.transactionID {
            removeTransaction(pendingTransactionID, targetID: selection.pendingRequest?.targetID)
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
        guard let document = targetStatesByID[targetID]?.currentDocument,
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
        guard let (frameTargetID, _) = frameDocumentProjections
            .sorted(by: { $0.key.rawValue < $1.key.rawValue })
            .first(where: { $0.value.state == .pending }) else {
            return nil
        }
        guard let ownerDocument = ownerDocument(forFrameTargetID: frameTargetID),
              let node = ownerHydrationNode(in: ownerDocument) else {
            return nil
        }
        return ownerHydrationIntent(
            frameTargetID: frameTargetID,
            document: ownerDocument,
            node: node,
            issuedSequence: issuedSequence
        )
    }

    package func clearOwnerHydrationTransactions(targetID: ProtocolTarget.ID) {
        targetStatesByID[targetID]?.currentDocument?.removeOwnerHydrationTransactions()
    }

    package func actionIdentity(
        for nodeID: DOMNode.ID,
        commandTargetID: ProtocolTarget.ID? = nil
    ) -> DOMActionIdentity? {
        guard let node = node(for: nodeID),
              let resolvedCommandTargetID = commandTargetID ?? currentPageTargetID,
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
        objectID: String,
        issuedSequence: UInt64 = 0
    ) -> Result<DOMCommandIntent, SelectionResolutionFailure> {
        guard objectID.isEmpty == false else {
            return failSelection(.missingObjectID)
        }
        guard let document = targetStatesByID[targetID]?.currentDocument,
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
        selection.pendingRequest = DOMSelectionRequest(
            id: requestID,
            targetID: targetID,
            documentID: document.id,
            transactionID: transactionID
        )
        selection.failure = nil
        return .success(.requestNode(selectionRequestID: requestID, targetID: targetID, objectID: objectID))
    }

    package func applyRequestNodeResult(
        selectionRequestID: SelectionRequestIdentifier,
        targetID: ProtocolTarget.ID,
        nodeID: DOMProtocolNodeID
    ) -> DOMRequestNodeResolution {
        guard let document = targetStatesByID[targetID]?.currentDocument,
              document.lifecycle == .loaded else {
            return failSelection(.missingCurrentDocument(targetID), clearSelected: false)
        }
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
        selection.failure = nil
        return .pending(key)
    }

    package func treeProjection(rootTargetID: ProtocolTarget.ID) -> DOMTreeProjection {
        var rows: [DOMTreeRow] = []
        var visited = Set<DOMNode.ID>()
        if let document = targetStatesByID[rootTargetID]?.currentDocument,
           document.lifecycle == .loaded {
            appendProjectionRows(document.rootNodeID, depth: 0, visited: &visited, rows: &rows)
        }
        return DOMTreeProjection(rows: rows)
    }

    package func snapshot() -> DOMSessionSnapshot {
        let documents = targetStatesByID.values.compactMap(\.currentDocument)
        let documentsByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        let nodesByID = Dictionary(uniqueKeysWithValues: documents.flatMap { document in
            document.nodesByID.map { ($0.key, $0.value) }
        })
        let currentNodeIDByKey = Dictionary(uniqueKeysWithValues: targetStatesByID.values.compactMap { state -> [(DOMNodeCurrentKey, DOMNode.ID)]? in
            guard let document = state.currentDocument else {
                return nil
            }
            guard document.lifecycle == .loaded else {
                return []
            }
            return document.currentNodeIDByProtocolNodeID.map {
                (DOMNodeCurrentKey(targetID: state.targetID, nodeID: $0.key), $0.value)
            }
        }.flatMap { $0 })
        let transactions = documents.flatMap { document in
            document.transactions.values
        }
        return DOMSessionSnapshot(
            currentPageTargetID: currentPageTargetID,
            mainFrameID: mainFrameID,
            treeRevision: treeRevision,
            selectionRevision: selectionRevision,
            targetsByID: targetsByID.mapValues {
                ProtocolTargetSnapshot(
                    id: $0.id,
                    kind: $0.kind,
                    frameID: $0.frameID,
                    parentFrameID: $0.parentFrameID,
                    capabilities: $0.capabilities,
                    isProvisional: $0.isProvisional,
                    isPaused: $0.isPaused,
                    currentDocumentID: currentDocumentID(for: $0.id)
                )
            },
            targetStatesByID: targetStatesByID.mapValues { state in
                DOMTargetStateSnapshot(
                    targetID: state.targetID,
                    currentDocumentID: currentDocumentID(for: state.targetID),
                    transactionIDs: state.currentDocument.map { Array($0.transactions.keys) } ?? []
                )
            },
            framesByID: framesByID.mapValues {
                DOMFrameSnapshot(
                    id: $0.id,
                    parentFrameID: $0.parentFrameID,
                    childFrameIDs: $0.childFrameIDs,
                    targetID: $0.targetID,
                    currentDocumentID: $0.currentDocumentID
                )
            },
            documentsByID: documentsByID.mapValues {
                DOMDocumentSnapshot(
                    id: $0.id,
                    targetID: $0.targetID,
                    localDocumentLifetimeID: $0.localDocumentLifetimeID,
                    lifecycle: $0.lifecycle,
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
                    ownerFrameID: node.ownerFrameID,
                    documentURL: node.documentURL,
                    baseURL: node.baseURL,
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
            frameDocumentProjections: frameDocumentProjections.mapValues {
                FrameDocumentProjectionSnapshot(
                    ownerNodeID: $0.ownerNodeID,
                    frameTargetID: $0.frameTargetID,
                    frameDocumentID: $0.frameDocumentID,
                    state: $0.state
                )
            },
            transactions: transactions.map {
                DOMTransactionSnapshot(
                    id: $0.id,
                    targetID: $0.targetID,
                    documentID: $0.documentID,
                    kind: $0.kind,
                    issuedSequence: $0.issuedSequence,
                    requestedProtocolNodeID: $0.requestedProtocolNodeID
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

    private func buildSubtree(
        _ payload: DOMNodePayload,
        documentID: DOMDocument.ID,
        parentID: DOMNode.ID?,
        nodesByID: inout [DOMNode.ID: DOMNode],
        currentNodeIDByProtocolNodeID: inout [DOMProtocolNodeID: DOMNode.ID]
    ) -> DOMNode.ID {
        let nodeID = DOMNode.ID(documentID: documentID, nodeID: payload.nodeID)
        let node = DOMNode(id: nodeID, payload: payload, parentID: parentID)
        nodesByID[nodeID] = node
        currentNodeIDByProtocolNodeID[payload.nodeID] = nodeID

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
                        nodesByID: &nodesByID,
                        currentNodeIDByProtocolNodeID: &currentNodeIDByProtocolNodeID
                    )
                }
            )
        }

        node.contentDocumentID = payload.contentDocument.first.map {
            buildSubtree($0, documentID: documentID, parentID: nodeID, nodesByID: &nodesByID, currentNodeIDByProtocolNodeID: &currentNodeIDByProtocolNodeID)
        }
        node.shadowRootIDs = payload.shadowRoots.map {
            buildSubtree($0, documentID: documentID, parentID: nodeID, nodesByID: &nodesByID, currentNodeIDByProtocolNodeID: &currentNodeIDByProtocolNodeID)
        }
        node.templateContentID = payload.templateContent.first.map {
            buildSubtree($0, documentID: documentID, parentID: nodeID, nodesByID: &nodesByID, currentNodeIDByProtocolNodeID: &currentNodeIDByProtocolNodeID)
        }
        node.beforePseudoElementID = payload.beforePseudoElement.first.map {
            buildSubtree($0, documentID: documentID, parentID: nodeID, nodesByID: &nodesByID, currentNodeIDByProtocolNodeID: &currentNodeIDByProtocolNodeID)
        }
        node.otherPseudoElementIDs = payload.otherPseudoElements.map {
            buildSubtree($0, documentID: documentID, parentID: nodeID, nodesByID: &nodesByID, currentNodeIDByProtocolNodeID: &currentNodeIDByProtocolNodeID)
        }
        node.afterPseudoElementID = payload.afterPseudoElement.first.map {
            buildSubtree($0, documentID: documentID, parentID: nodeID, nodesByID: &nodesByID, currentNodeIDByProtocolNodeID: &currentNodeIDByProtocolNodeID)
        }

        relinkProtocolEffectiveChildren(of: node, nodesByID: nodesByID)
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
        var nodesByID = document.nodesByID
        var currentNodeIDByProtocolNodeID = document.currentNodeIDByProtocolNodeID
        let nodeID = buildSubtree(
            payload,
            documentID: document.id,
            parentID: parentID,
            nodesByID: &nodesByID,
            currentNodeIDByProtocolNodeID: &currentNodeIDByProtocolNodeID
        )
        document.nodesByID = nodesByID
        document.currentNodeIDByProtocolNodeID = currentNodeIDByProtocolNodeID
        return nodeID
    }

    private func removeDocuments(for targetID: ProtocolTarget.ID) {
        guard let documentID = targetStatesByID[targetID]?.currentDocument?.id else {
            return
        }
        removeDocument(documentID)
    }

    private func removeDocument(_ documentID: DOMDocument.ID) {
        guard let targetState = targetStatesByID[documentID.targetID],
              let document = targetState.currentDocument,
              document.id == documentID else {
            return
        }
        document.lifecycle = .invalidated
        targetState.currentDocument = nil
        document.transactions.removeAll()
        if let target = targetsByID[document.targetID] {
            clearCurrentDocumentReference(documentID, target: target)
        }
        if selection.selectedNodeID?.documentID == documentID {
            selection.selectedNodeID = nil
            selection.failure = nil
            selectionRevision &+= 1
        }
    }

    private func clearCurrentDocumentReference(_ documentID: DOMDocument.ID, target: ProtocolTarget) {
        if let frameID = target.frameID,
           framesByID[frameID]?.currentDocumentID == documentID {
            framesByID[frameID]?.currentDocumentID = nil
        }
        if currentPageTargetID == target.id,
           let mainFrameID,
           framesByID[mainFrameID]?.currentDocumentID == documentID {
            framesByID[mainFrameID]?.currentDocumentID = nil
        }
    }

    @discardableResult
    private func registerTransaction(
        targetID: ProtocolTarget.ID,
        document: DOMDocument,
        kind: DOMTransactionKind,
        issuedSequence: UInt64
    ) -> DOMTransaction.ID? {
        guard let targetState = targetStatesByID[targetID],
              targetState.currentDocument === document else {
            return nil
        }
        return document.startTransaction(kind: kind, issuedSequence: issuedSequence)
    }

    private func removeTransaction(_ transactionID: DOMTransaction.ID, targetID: ProtocolTarget.ID?) {
        if let targetID {
            targetStatesByID[targetID]?.currentDocument?.removeTransaction(transactionID)
            return
        }
        for state in targetStatesByID.values {
            state.currentDocument?.removeTransaction(transactionID)
        }
    }

    private func hasActiveOwnerHydrationTransaction(
        targetID: ProtocolTarget.ID,
        documentID: DOMDocument.ID
    ) -> Bool {
        guard let document = targetStatesByID[targetID]?.currentDocument,
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

    private func ownerHydrationNode(in document: DOMDocument) -> DOMNode? {
        let roots = [bodyElement(in: document), documentElement(in: document), document.nodesByID[document.rootNodeID]]
            .compactMap { $0 }
        var pending = roots
        var visited = Set<DOMNode.ID>()
        while pending.isEmpty == false {
            let node = pending.removeFirst()
            guard visited.insert(node.id).inserted else {
                continue
            }
            if hasUnloadedRegularChildren(node) {
                return node
            }
            pending.append(
                contentsOf: node.regularChildren.loadedChildren.compactMap { document.nodesByID[$0] }
            )
        }
        return nil
    }

    private func documentElement(in document: DOMDocument) -> DOMNode? {
        guard let root = document.nodesByID[document.rootNodeID] else {
            return nil
        }
        return root.regularChildren.loadedChildren
            .compactMap { document.nodesByID[$0] }
            .first { node in
                node.nodeType == .element && normalizedElementName(node) == "html"
            }
    }

    private func bodyElement(in document: DOMDocument) -> DOMNode? {
        guard let html = documentElement(in: document) else {
            return nil
        }
        return html.regularChildren.loadedChildren
            .compactMap { document.nodesByID[$0] }
            .first { node in
                node.nodeType == .element && normalizedElementName(node) == "body"
            }
    }

    private func normalizedElementName(_ node: DOMNode) -> String {
        (node.localName.isEmpty ? node.nodeName : node.localName).lowercased()
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
            let replacementOwnerKeys = parent.regularChildren.loadedChildren
                .reduce(into: [ProtocolTarget.ID: DOMNodeCurrentKey]()) { partialResult, childID in
                    partialResult.merge(projectedFrameOwnerKeys(inSubtree: childID)) { current, _ in current }
                }
            for childID in parent.regularChildren.loadedChildren {
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
        guard let document = targetStatesByID[nodeID.documentID.targetID]?.currentDocument,
              document.id == nodeID.documentID,
              document.lifecycle == .loaded else {
            return false
        }
        return document.nodesByID[nodeID] != nil
    }

    private func nodeIsConnectedToDocumentTree(_ nodeID: DOMNode.ID, in document: DOMDocument) -> Bool {
        var currentNodeID: DOMNode.ID? = nodeID
        var visitedNodeIDs = Set<DOMNode.ID>()
        while let candidateID = currentNodeID,
              visitedNodeIDs.insert(candidateID).inserted {
            if candidateID == document.rootNodeID {
                return true
            }
            currentNodeID = document.nodesByID[candidateID]?.parentID
        }
        return false
    }

    private func payloadContainsConnectedDocumentNode(_ payload: DOMNodePayload, in document: DOMDocument) -> Bool {
        if let existingNodeID = document.currentNodeIDByProtocolNodeID[payload.nodeID],
           nodeIsConnectedToDocumentTree(existingNodeID, in: document) {
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
        guard let document = targetStatesByID[nodeID.documentID.targetID]?.currentDocument,
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
        for projection in frameDocumentProjections.values where projection.ownerNodeID == nodeID {
            projection.ownerNodeID = nil
            projection.state = .pending
        }
        if document.currentNodeIDByProtocolNodeID[node.protocolNodeID] == nodeID {
            document.currentNodeIDByProtocolNodeID.removeValue(forKey: node.protocolNodeID)
        }
        document.nodesByID.removeValue(forKey: nodeID)
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
        var keys: [ProtocolTarget.ID: DOMNodeCurrentKey] = [:]
        var stack = [rootID]
        while let nodeID = stack.popLast() {
            guard let node = node(for: nodeID) else {
                continue
            }
            for projection in frameDocumentProjections.values where projection.ownerNodeID == nodeID {
                keys[projection.frameTargetID] = DOMNodeCurrentKey(
                    targetID: nodeID.documentID.targetID,
                    nodeID: node.protocolNodeID
                )
            }
            stack.append(contentsOf: node.protocolOwnedChildren)
        }
        return keys
    }

    private func reattachFrameDocumentProjections(using ownerKeys: [ProtocolTarget.ID: DOMNodeCurrentKey]) {
        for (frameTargetID, ownerKey) in ownerKeys {
            guard let projection = frameDocumentProjections[frameTargetID],
                  let ownerNodeID = targetStatesByID[ownerKey.targetID]?.currentDocument?.currentNodeIDByProtocolNodeID[ownerKey.nodeID],
                  let ownerNode = node(for: ownerNodeID),
                  ownerNode.isFrameOwner,
                  canApplyDOMEvent(to: ownerNodeID) else {
                continue
            }
            projection.ownerNodeID = ownerNodeID
            projection.state = .attached
        }
    }

    private func setFrameDocumentProjection(frameTargetID: ProtocolTarget.ID, frameDocumentID: DOMDocument.ID) {
        let projection = frameDocumentProjections[frameTargetID] ?? FrameDocumentProjection(
            ownerNodeID: nil,
            frameTargetID: frameTargetID,
            frameDocumentID: frameDocumentID,
            state: .pending
        )
        projection.frameTargetID = frameTargetID
        projection.frameDocumentID = frameDocumentID
        projection.ownerNodeID = nil
        projection.state = .pending
        frameDocumentProjections[frameTargetID] = projection
    }

    private func updateAllFrameDocumentProjectionStates() {
        for projection in frameDocumentProjections.values {
            updateFrameDocumentProjectionState(projection)
        }
    }

    private func updateFrameDocumentProjectionState(_ projection: FrameDocumentProjection) {
        guard let document = currentDocument(for: projection.frameDocumentID),
              let frameRoot = document.nodesByID[document.rootNodeID] else {
            projection.ownerNodeID = nil
            projection.state = .pending
            return
        }

        if let ownerNodeID = projection.ownerNodeID,
           frameDocumentProjection(projection, canRemainAttachedTo: ownerNodeID, frameRoot: frameRoot) {
            projection.state = .attached
            return
        }

        projection.ownerNodeID = nil
        let candidates = ownerCandidates(forFrameDocumentRoot: frameRoot)
        switch candidates.count {
        case 0:
            projection.ownerNodeID = nil
            projection.state = .pending
        case 1:
            projection.ownerNodeID = candidates[0]
            projection.state = .attached
        default:
            projection.ownerNodeID = nil
            projection.state = .ambiguous
        }
    }

    private func frameDocumentProjection(
        _ projection: FrameDocumentProjection,
        canRemainAttachedTo ownerNodeID: DOMNode.ID,
        frameRoot: DOMNode
    ) -> Bool {
        guard let document = currentDocument(for: ownerNodeID.documentID),
              let ownerNode = document.nodesByID[ownerNodeID] else {
            return false
        }
        let frameTargetID = frameRoot.id.documentID.targetID
        return ownerNode.isFrameOwner
            && ownerDocument(forFrameTargetID: frameTargetID)?.id == document.id
            && nodeIsConnectedToDocumentTree(ownerNodeID, in: document)
            && frameOwner(ownerNode, matchesFrameTargetID: frameTargetID, frameDocumentURL: frameRoot.documentURL)
            && frameDocumentProjections.values.allSatisfy {
                $0 === projection || $0.ownerNodeID != ownerNodeID || $0.state != .attached
            }
    }

    private func ownerCandidates(forFrameDocumentRoot frameRoot: DOMNode) -> [DOMNode.ID] {
        let frameTargetID = frameRoot.id.documentID.targetID
        guard let ownerDocument = ownerDocument(forFrameTargetID: frameTargetID) else {
            return []
        }

        let attachableCandidates = ownerCandidateNodes(in: ownerDocument)
            .filter { projectionCanAttach(to: $0.node, in: $0.document) }
        if let frameID = targetsByID[frameTargetID]?.frameID {
            let frameIDMatches = attachableCandidates
                .filter { $0.node.ownerFrameID == frameID }
            if frameIDMatches.isEmpty == false {
                return frameIDMatches
                    .map { $0.node.id }
                    .sorted(by: sortNodeIDs)
            }
        }

        guard let frameDocumentURL = frameRoot.documentURL,
              frameDocumentURL.isEmpty == false else {
            return []
        }
        return attachableCandidates
            .filter { frameOwner($0.node, matchesFrameDocumentURL: frameDocumentURL) }
            .map { $0.node.id }
            .sorted(by: sortNodeIDs)
    }

    private func ownerCandidateNodes(in document: DOMDocument) -> [(document: DOMDocument, node: DOMNode)] {
        document.nodesByID.values.map { (document, $0) }
    }

    private func ownerDocument(forFrameTargetID frameTargetID: ProtocolTarget.ID) -> DOMDocument? {
        guard let target = targetsByID[frameTargetID] else {
            return nil
        }

        if let parentFrameID = target.parentFrameID {
            guard let parentDocumentID = framesByID[parentFrameID]?.currentDocumentID else {
                return nil
            }
            return currentDocument(for: parentDocumentID)
        }
        guard let pageTargetID = currentPageTargetID,
              let pageDocument = targetStatesByID[pageTargetID]?.currentDocument,
              pageDocument.lifecycle == .loaded else {
            return nil
        }
        return pageDocument
    }

    private func projectionCanAttach(to candidate: DOMNode, in document: DOMDocument) -> Bool {
        candidate.isFrameOwner
            && frameOwnerIsAlreadyAttached(candidate.id) == false
            && nodeIsConnectedToDocumentTree(candidate.id, in: document)
    }

    private func frameOwnerIsAlreadyAttached(_ nodeID: DOMNode.ID) -> Bool {
        frameDocumentProjections.values.contains {
            $0.ownerNodeID == nodeID && $0.state == .attached
        }
    }

    private func sortNodeIDs(_ lhs: DOMNode.ID, _ rhs: DOMNode.ID) -> Bool {
        if lhs.documentID.targetID.rawValue != rhs.documentID.targetID.rawValue {
            return lhs.documentID.targetID.rawValue < rhs.documentID.targetID.rawValue
        }
        if lhs.documentID.localDocumentLifetimeID != rhs.documentID.localDocumentLifetimeID {
            return lhs.documentID.localDocumentLifetimeID < rhs.documentID.localDocumentLifetimeID
        }
        return lhs.nodeID.rawValue < rhs.nodeID.rawValue
    }

    private func frameOwner(_ owner: DOMNode, matchesFrameDocumentURL frameDocumentURL: String) -> Bool {
        guard let source = explicitFrameSource(for: owner) else {
            return frameDocumentURLIsDefaultBlank(frameDocumentURL)
        }
        if source == frameDocumentURL {
            return true
        }
        guard let resolvedSource = resolvedURL(source, relativeTo: documentURL(for: owner)),
              let resolvedFrameDocumentURL = resolvedURL(frameDocumentURL, relativeTo: nil) else {
            return false
        }
        return resolvedSource == resolvedFrameDocumentURL
    }

    private func frameOwner(
        _ owner: DOMNode,
        matchesFrameTargetID frameTargetID: ProtocolTarget.ID,
        frameDocumentURL: String?
    ) -> Bool {
        if let frameID = targetsByID[frameTargetID]?.frameID,
           owner.ownerFrameID == frameID {
            return true
        }
        guard let frameDocumentURL,
              frameDocumentURL.isEmpty == false else {
            return false
        }
        return frameOwner(owner, matchesFrameDocumentURL: frameDocumentURL)
    }

    private func explicitFrameSource(for owner: DOMNode) -> String? {
        guard let source = attribute(named: "src", in: owner),
              source.isEmpty == false else {
            return nil
        }
        return source
    }

    private func frameDocumentURLIsDefaultBlank(_ url: String) -> Bool {
        url == "about:blank" || resolvedURL(url, relativeTo: nil) == "about:blank"
    }

    private func attribute(named name: String, in node: DOMNode) -> String? {
        node.attributes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func documentURL(for node: DOMNode) -> String? {
        guard let document = currentDocument(for: node.id.documentID),
              let root = document.nodesByID[document.rootNodeID] else {
            return nil
        }
        return root.baseURL ?? root.documentURL
    }

    private func resolvedURL(_ string: String, relativeTo base: String?) -> String? {
        if let base,
           let baseURL = URL(string: base),
           let url = URL(string: string, relativeTo: baseURL) {
            return url.absoluteURL.absoluteString
        }
        return URL(string: string)?.absoluteURL.absoluteString
    }

    private func projectedFrameDocumentRootID(for ownerNodeID: DOMNode.ID) -> DOMNode.ID? {
        for projection in frameDocumentProjections.values where projection.ownerNodeID == ownerNodeID && projection.state == .attached {
            guard let document = currentDocument(for: projection.frameDocumentID) else {
                continue
            }
            return document.rootNodeID
        }
        return nil
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
           let rootNodeID = projectedFrameDocumentRootID(for: node.id) {
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
              let node = node(for: nodeID) else {
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
        guard let parentID = node.parentID else {
            return nil
        }
        return self.node(for: parentID)
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

        let siblings = parent.regularChildren.loadedChildren.compactMap { self.node(for: $0) }
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
        return parent.regularChildren.loadedChildren.compactMap { self.node(for: $0) }.filter(nodeIsElementLike)
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
              node(for: selectedNodeID) == nil else {
            return
        }
        selection.selectedNodeID = nil
        selection.failure = nil
        selectionRevision &+= 1
    }

    private func completePendingSelection(
        _ selectedNodeID: DOMNode.ID,
        pendingRequest: DOMSelectionRequest
    ) {
        if let transactionID = pendingRequest.transactionID {
            removeTransaction(transactionID, targetID: pendingRequest.targetID)
        }
        selection.selectedNodeID = selectedNodeID
        selection.pendingRequest = nil
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
        if let pendingTransactionID = selection.pendingRequest?.transactionID {
            removeTransaction(pendingTransactionID, targetID: selection.pendingRequest?.targetID)
        }
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
        if let pendingTransactionID = selection.pendingRequest?.transactionID {
            removeTransaction(pendingTransactionID, targetID: selection.pendingRequest?.targetID)
        }
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
    ) -> DOMRequestNodeResolution {
        let previousSelectedNodeID = selection.selectedNodeID
        let previousHadPendingRequest = selection.pendingRequest != nil
        let previousFailure = selection.failure
        if let pendingTransactionID = selection.pendingRequest?.transactionID {
            removeTransaction(pendingTransactionID, targetID: selection.pendingRequest?.targetID)
        }
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
        return .failed(failure)
    }
}
