import Observation
import WebInspectorTransport

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

@MainActor
@Observable
package final class DOMTargetState {
    package let targetID: ProtocolTarget.ID
    package var currentDocument: DOMDocumentState?

    package init(targetID: ProtocolTarget.ID) {
        self.targetID = targetID
        currentDocument = nil
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

package struct DOMCurrentPage: Equatable, Sendable {
    package private(set) var targetID: ProtocolTarget.ID?
    package private(set) var mainFrameID: DOMFrame.ID?

    package init(targetID: ProtocolTarget.ID? = nil, mainFrameID: DOMFrame.ID? = nil) {
        self.targetID = targetID
        self.mainFrameID = mainFrameID
    }

    package var isEmpty: Bool {
        targetID == nil
    }

    package func isCurrentTarget(_ targetID: ProtocolTarget.ID) -> Bool {
        self.targetID == targetID
    }

    @discardableResult
    package mutating func promote(targetID: ProtocolTarget.ID, mainFrameID: DOMFrame.ID) -> Bool {
        let didReplaceExistingPage = self.targetID != nil && self.targetID != targetID
        self.targetID = targetID
        self.mainFrameID = mainFrameID
        return didReplaceExistingPage
    }

    @discardableResult
    package mutating func retarget(from oldTargetID: ProtocolTarget.ID, to newTargetID: ProtocolTarget.ID) -> Bool {
        guard targetID == oldTargetID else {
            return false
        }
        targetID = newTargetID
        return true
    }

    @discardableResult
    package mutating func clear(ifTarget targetID: ProtocolTarget.ID) -> Bool {
        guard self.targetID == targetID else {
            return false
        }
        clear()
        return true
    }

    package mutating func clear() {
        targetID = nil
        mainFrameID = nil
    }
}

@MainActor
package struct DOMDocumentNodeIndex {
    private var nodesByIdentifier: [DOMNode.ID: DOMNode]
    private var currentNodeIDByRawNodeID: [DOMProtocolNodeID: DOMNode.ID]

    package init(
        nodesByID: [DOMNode.ID: DOMNode] = [:],
        currentNodeIDByProtocolNodeID: [DOMProtocolNodeID: DOMNode.ID] = [:]
    ) {
        self.nodesByIdentifier = nodesByID
        self.currentNodeIDByRawNodeID = currentNodeIDByProtocolNodeID
    }

    package var nodesByID: [DOMNode.ID: DOMNode] {
        nodesByIdentifier
    }

    package var currentNodeIDByProtocolNodeID: [DOMProtocolNodeID: DOMNode.ID] {
        currentNodeIDByRawNodeID
    }

    package func node(for nodeID: DOMNode.ID) -> DOMNode? {
        nodesByIdentifier[nodeID]
    }

    package func currentNodeID(for rawNodeID: DOMProtocolNodeID) -> DOMNode.ID? {
        currentNodeIDByRawNodeID[rawNodeID]
    }

    package mutating func store(_ node: DOMNode, rawNodeID: DOMProtocolNodeID) {
        nodesByIdentifier[node.id] = node
        currentNodeIDByRawNodeID[rawNodeID] = node.id
    }

    package mutating func removeNode(_ nodeID: DOMNode.ID, ifCurrentFor rawNodeID: DOMProtocolNodeID) {
        if currentNodeIDByRawNodeID[rawNodeID] == nodeID {
            currentNodeIDByRawNodeID.removeValue(forKey: rawNodeID)
        }
        nodesByIdentifier.removeValue(forKey: nodeID)
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
    private var nodeIndex: DOMDocumentNodeIndex
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
        nodeIndex = DOMDocumentNodeIndex(
            nodesByID: nodesByID,
            currentNodeIDByProtocolNodeID: currentNodeIDByProtocolNodeID
        )
        transactions = [:]
        nextTransactionID = 0
    }

    package var nodesByID: [DOMNode.ID: DOMNode] {
        nodeIndex.nodesByID
    }

    package var currentNodeIDByProtocolNodeID: [DOMProtocolNodeID: DOMNode.ID] {
        nodeIndex.currentNodeIDByProtocolNodeID
    }

    package var nodeIndexSnapshot: DOMDocumentNodeIndex {
        nodeIndex
    }

    package func replaceNodeIndex(_ newIndex: DOMDocumentNodeIndex) {
        nodeIndex = newIndex
    }

    package func node(for nodeID: DOMNode.ID) -> DOMNode? {
        nodeIndex.node(for: nodeID)
    }

    package func currentNodeID(for rawNodeID: DOMProtocolNodeID) -> DOMNode.ID? {
        nodeIndex.currentNodeID(for: rawNodeID)
    }

    package func removeNode(_ nodeID: DOMNode.ID, ifCurrentFor rawNodeID: DOMProtocolNodeID) {
        nodeIndex.removeNode(nodeID, ifCurrentFor: rawNodeID)
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

    package func update(from payload: DOMNodePayload, parentID: ID?) {
        nodeType = payload.nodeType
        nodeName = payload.nodeName
        localName = payload.localName
        nodeValue = payload.nodeValue
        ownerFrameID = payload.ownerFrameID
        documentURL = payload.documentURL
        baseURL = payload.baseURL
        attributes = payload.attributes
        self.parentID = parentID
        pseudoType = payload.pseudoType
        shadowRootType = payload.shadowRootType
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

package struct DOMSelectionRequest: Equatable, Sendable {
    package var id: SelectionRequestIdentifier
    package var targetID: ProtocolTarget.ID
    package var documentID: DOMDocument.ID
    package var transactionID: DOMTransaction.ID?
}

package enum DOMSelectionResolutionPhase: Equatable, Sendable {
    case idle
    case pending(DOMSelectionRequest)
    case failed(SelectionResolutionFailure)

    package var pendingRequest: DOMSelectionRequest? {
        guard case let .pending(request) = self else {
            return nil
        }
        return request
    }

    package var failure: SelectionResolutionFailure? {
        guard case let .failed(failure) = self else {
            return nil
        }
        return failure
    }

    package var isIdle: Bool {
        if case .idle = self {
            return true
        }
        return false
    }
}

package struct DOMSelectionState: Equatable, Sendable {
    package var selectedNodeID: DOMNode.ID?
    package var resolution: DOMSelectionResolutionPhase

    package init(
        selectedNodeID: DOMNode.ID? = nil,
        resolution: DOMSelectionResolutionPhase = .idle
    ) {
        self.selectedNodeID = selectedNodeID
        self.resolution = resolution
    }

    package var pendingRequest: DOMSelectionRequest? {
        resolution.pendingRequest
    }

    package var failure: SelectionResolutionFailure? {
        resolution.failure
    }
}

@MainActor
@Observable
package final class DOMSelection {
    private var state: DOMSelectionState

    package init(state: DOMSelectionState = DOMSelectionState()) {
        self.state = state
    }

    package var selectedNodeID: DOMNode.ID? {
        state.selectedNodeID
    }

    package var pendingRequest: DOMSelectionRequest? {
        state.pendingRequest
    }

    package var failure: SelectionResolutionFailure? {
        state.failure
    }

    package func hasStateChange(selecting nodeID: DOMNode.ID?) -> Bool {
        state.selectedNodeID != nodeID || !state.resolution.isIdle
    }

    @discardableResult
    package func select(_ nodeID: DOMNode.ID?) -> DOMSelectionRequest? {
        let cancelledRequest = state.pendingRequest
        state.selectedNodeID = nodeID
        state.resolution = .idle
        return cancelledRequest
    }

    @discardableResult
    package func beginRequest(_ request: DOMSelectionRequest) -> DOMSelectionRequest? {
        let cancelledRequest = state.pendingRequest
        state.resolution = .pending(request)
        return cancelledRequest
    }

    package func clearFailure() {
        guard case .failed = state.resolution else {
            return
        }
        state.resolution = .idle
    }

    @discardableResult
    package func clearSelected(ifDocument documentID: DOMDocument.ID) -> Bool {
        guard state.selectedNodeID?.documentID == documentID else {
            return false
        }
        state.selectedNodeID = nil
        clearFailure()
        return true
    }

    @discardableResult
    package func clearSelectedIfStale(nodeExists: (DOMNode.ID) -> Bool) -> Bool {
        guard let selectedNodeID = state.selectedNodeID,
              nodeExists(selectedNodeID) == false else {
            return false
        }
        state.selectedNodeID = nil
        clearFailure()
        return true
    }

    @discardableResult
    package func complete(
        _ selectedNodeID: DOMNode.ID,
        pendingRequest: DOMSelectionRequest
    ) -> DOMSelectionRequest? {
        guard state.pendingRequest == pendingRequest else {
            return nil
        }
        state.selectedNodeID = selectedNodeID
        state.resolution = .idle
        return pendingRequest
    }

    @discardableResult
    package func fail(
        _ failure: SelectionResolutionFailure,
        clearSelected: Bool = true
    ) -> DOMSelectionRequest? {
        let cancelledRequest = state.pendingRequest
        if clearSelected {
            state.selectedNodeID = nil
        }
        state.resolution = .failed(failure)
        return cancelledRequest
    }

    package func rejectStaleRequest(_ failure: SelectionResolutionFailure) {
        guard state.pendingRequest == nil else {
            return
        }
        state.resolution = .failed(failure)
    }
}
