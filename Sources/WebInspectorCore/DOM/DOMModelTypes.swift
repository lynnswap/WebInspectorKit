import Observation
import WebInspectorTransport

@MainActor
@Observable
package final class DOMTarget: Identifiable {
    package let id: ProtocolTarget.ID
    package var kind: ProtocolTarget.Kind
    package var frameID: DOMFrame.ID?
    package var parentFrameID: DOMFrame.ID?
    package var capabilities: ProtocolTarget.Capabilities
    package var isProvisional: Bool
    package var isPaused: Bool

    package init(
        id: ProtocolTarget.ID,
        kind: ProtocolTarget.Kind,
        frameID: DOMFrame.ID?,
        parentFrameID: DOMFrame.ID?,
        capabilities: ProtocolTarget.Capabilities,
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
    package var currentDocument: DOMDocument?

    package init(targetID: ProtocolTarget.ID) {
        self.targetID = targetID
        currentDocument = nil
    }
}

@MainActor
@Observable
package final class DOMFrame: Identifiable {
    package typealias ID = ProtocolFrame.ID

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

package extension DOMDocument {
    @MainActor
    final class NodeStore {
        private var nodesByIdentifier: [DOMNode.ID: DOMNode]
        private var currentNodeIDByRawNodeID: [DOMNode.ProtocolID: DOMNode.ID]

        package init(
            nodesByID: [DOMNode.ID: DOMNode] = [:],
            currentNodeIDByProtocolNodeID: [DOMNode.ProtocolID: DOMNode.ID] = [:]
        ) {
            self.nodesByIdentifier = nodesByID
            self.currentNodeIDByRawNodeID = currentNodeIDByProtocolNodeID
        }

        package var nodesByID: [DOMNode.ID: DOMNode] {
            nodesByIdentifier
        }

        package var currentNodeIDByProtocolNodeID: [DOMNode.ProtocolID: DOMNode.ID] {
            currentNodeIDByRawNodeID
        }

        package func node(for nodeID: DOMNode.ID) -> DOMNode? {
            nodesByIdentifier[nodeID]
        }

        package func currentNodeID(for rawNodeID: DOMNode.ProtocolID) -> DOMNode.ID? {
            currentNodeIDByRawNodeID[rawNodeID]
        }

        package func store(_ node: DOMNode, rawNodeID: DOMNode.ProtocolID) {
            nodesByIdentifier[node.id] = node
            currentNodeIDByRawNodeID[rawNodeID] = node.id
        }

        package func removeNode(_ nodeID: DOMNode.ID, ifCurrentFor rawNodeID: DOMNode.ProtocolID) {
            if currentNodeIDByRawNodeID[rawNodeID] == nodeID {
                currentNodeIDByRawNodeID.removeValue(forKey: rawNodeID)
            }
            nodesByIdentifier.removeValue(forKey: nodeID)
        }
    }

    typealias NodeIndex = NodeStore
}

@MainActor
@Observable
package final class DOMDocument: Identifiable {
    package let id: ID
    package let targetID: ProtocolTarget.ID
    package let localDocumentLifetimeID: DOMDocument.LifetimeID
    package var lifecycle: DOMDocument.Lifecycle
    package let rootNodeID: DOMNode.ID
    private var nodeStore: DOMDocument.NodeStore
    package var transactions: [DOMTransaction.ID: DOMTransaction]
    package var nextTransactionRawID: UInt64

    package init(
        id: ID,
        targetID: ProtocolTarget.ID,
        lifecycle: DOMDocument.Lifecycle,
        rootNodeID: DOMNode.ID,
        nodesByID: [DOMNode.ID: DOMNode],
        currentNodeIDByProtocolNodeID: [DOMNode.ProtocolID: DOMNode.ID]
    ) {
        self.id = id
        self.targetID = targetID
        self.localDocumentLifetimeID = id.localDocumentLifetimeID
        self.lifecycle = lifecycle
        self.rootNodeID = rootNodeID
        nodeStore = DOMDocument.NodeStore(
            nodesByID: nodesByID,
            currentNodeIDByProtocolNodeID: currentNodeIDByProtocolNodeID
        )
        transactions = [:]
        nextTransactionRawID = 0
    }

    package var nodesByID: [DOMNode.ID: DOMNode] {
        nodeStore.nodesByID
    }

    package var currentNodeIDByProtocolNodeID: [DOMNode.ProtocolID: DOMNode.ID] {
        nodeStore.currentNodeIDByProtocolNodeID
    }

    package var nodeStoreForMutation: DOMDocument.NodeStore {
        nodeStore
    }

    package var nodeIndexSnapshot: DOMDocument.NodeIndex {
        nodeStore
    }

    package func node(for nodeID: DOMNode.ID) -> DOMNode? {
        nodeStore.node(for: nodeID)
    }

    package func currentNodeID(for rawNodeID: DOMNode.ProtocolID) -> DOMNode.ID? {
        nodeStore.currentNodeID(for: rawNodeID)
    }

    package func containsConnectedNode(_ nodeID: DOMNode.ID) -> Bool {
        guard nodeID.documentID == id else {
            return false
        }

        var currentNodeID: DOMNode.ID? = nodeID
        var visitedNodeIDs = Set<DOMNode.ID>()
        while let candidateID = currentNodeID,
              visitedNodeIDs.insert(candidateID).inserted {
            if candidateID == rootNodeID {
                return true
            }
            currentNodeID = nodeStore.node(for: candidateID)?.parentID
        }
        return false
    }

    package func removeNode(_ nodeID: DOMNode.ID, ifCurrentFor rawNodeID: DOMNode.ProtocolID) {
        nodeStore.removeNode(nodeID, ifCurrentFor: rawNodeID)
    }

    package func nextTransactionID() -> DOMTransaction.ID {
        nextTransactionRawID &+= 1
        return DOMTransaction.ID(nextTransactionRawID)
    }

    @discardableResult
    package func startTransaction(kind: DOMTransaction.Kind, issuedSequence: UInt64) -> DOMTransaction.ID {
        let transactionID = nextTransactionID()
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

    package func removeChildNodesTransactions(parentRawNodeID: DOMNode.ProtocolID) {
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
        parentRawNodeID: DOMNode.ProtocolID,
        payloads: [DOMNode.Payload]
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
        _ nodeID: DOMNode.ProtocolID,
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

package struct DOMTransaction {
    package var id: ID
    package var targetID: ProtocolTarget.ID
    package var documentID: DOMDocument.ID
    package var kind: DOMTransaction.Kind
    package var issuedSequence: UInt64
    package var requestedProtocolNodeID: DOMNode.ProtocolID?
    package var pathFragmentsByParentRawNodeID: [DOMNode.ProtocolID: [DOMNode.Payload]]
}

package extension DOMNode {
    enum ChildrenState {
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
}

@MainActor
@Observable
package final class DOMNode: Identifiable {
    package let id: ID
    package let protocolNodeID: DOMNode.ProtocolID
    package var nodeType: DOMNode.Kind {
        didSet { refreshDOMTreeRenderSnapshot() }
    }
    package var nodeName: String {
        didSet { refreshDOMTreeRenderSnapshot() }
    }
    package var localName: String {
        didSet { refreshDOMTreeRenderSnapshot() }
    }
    package var nodeValue: String {
        didSet { refreshDOMTreeRenderSnapshot() }
    }
    package var ownerFrameID: DOMFrame.ID?
    package var documentURL: String?
    package var baseURL: String?
    package var attributes: [DOMNode.Attribute] {
        didSet { refreshDOMTreeRenderSnapshot() }
    }
    package var parentID: ID? {
        didSet { refreshDOMTreeRenderSnapshot() }
    }
    package var previousSiblingID: ID?
    package var nextSiblingID: ID?
    package var regularChildren: DOMNode.ChildrenState {
        didSet { refreshDOMTreeRenderSnapshot() }
    }
    package var contentDocumentID: ID? {
        didSet { refreshDOMTreeRenderSnapshot() }
    }
    package var shadowRootIDs: [ID] {
        didSet { refreshDOMTreeRenderSnapshot() }
    }
    package var templateContentID: ID? {
        didSet { refreshDOMTreeRenderSnapshot() }
    }
    package var beforePseudoElementID: ID? {
        didSet { refreshDOMTreeRenderSnapshot() }
    }
    package var otherPseudoElementIDs: [ID] {
        didSet { refreshDOMTreeRenderSnapshot() }
    }
    package var afterPseudoElementID: ID? {
        didSet { refreshDOMTreeRenderSnapshot() }
    }
    package var pseudoType: String? {
        didSet { refreshDOMTreeRenderSnapshot() }
    }
    package var shadowRootType: String? {
        didSet { refreshDOMTreeRenderSnapshot() }
    }
    @ObservationIgnored package private(set) var domTreeRenderSnapshot: DOMTreeRenderNodeSnapshot
    @ObservationIgnored private var renderSnapshotBatchDepth = 0
    @ObservationIgnored private var needsRenderSnapshotRefresh = false

    package init(id: ID, payload: DOMNode.Payload, parentID: ID?) {
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
        self.domTreeRenderSnapshot = DOMTreeRenderNodeSnapshot(
            id: id,
            protocolNodeID: payload.nodeID,
            nodeType: payload.nodeType,
            nodeName: payload.nodeName,
            localName: payload.localName,
            nodeValue: payload.nodeValue,
            attributes: payload.attributes,
            parentID: parentID,
            regularChildren: .unrequested(count: 0),
            contentDocumentID: nil,
            shadowRootIDs: [],
            templateContentID: nil,
            beforePseudoElementID: nil,
            otherPseudoElementIDs: [],
            afterPseudoElementID: nil,
            pseudoType: payload.pseudoType,
            shadowRootType: payload.shadowRootType
        )
    }

    package func update(from payload: DOMNode.Payload, parentID: ID?) {
        updateDOMTreeRenderSnapshotBatch {
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
    }

    package func setProtocolRelationship(
        parentID: ID?,
        previousSiblingID: ID?,
        nextSiblingID: ID?
    ) {
        updateDOMTreeRenderSnapshotBatch {
            self.parentID = parentID
            self.previousSiblingID = previousSiblingID
            self.nextSiblingID = nextSiblingID
        }
    }

    package func updateDOMTreeRenderSnapshotBatch(_ update: () -> Void) {
        renderSnapshotBatchDepth += 1
        update()
        renderSnapshotBatchDepth -= 1
        guard renderSnapshotBatchDepth == 0, needsRenderSnapshotRefresh else {
            return
        }
        needsRenderSnapshotRefresh = false
        refreshDOMTreeRenderSnapshotNow()
    }

    private func refreshDOMTreeRenderSnapshot() {
        guard renderSnapshotBatchDepth == 0 else {
            needsRenderSnapshotRefresh = true
            return
        }
        refreshDOMTreeRenderSnapshotNow()
    }

    private func refreshDOMTreeRenderSnapshotNow() {
        domTreeRenderSnapshot = DOMTreeRenderNodeSnapshot(
            id: id,
            protocolNodeID: protocolNodeID,
            nodeType: nodeType,
            nodeName: nodeName,
            localName: localName,
            nodeValue: nodeValue,
            attributes: attributes,
            parentID: parentID,
            regularChildren: regularChildren.snapshot,
            contentDocumentID: contentDocumentID,
            shadowRootIDs: shadowRootIDs,
            templateContentID: templateContentID,
            beforePseudoElementID: beforePseudoElementID,
            otherPseudoElementIDs: otherPseudoElementIDs,
            afterPseudoElementID: afterPseudoElementID,
            pseudoType: pseudoType,
            shadowRootType: shadowRootType
        )
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

private extension DOMNode.ChildrenState {
    var snapshot: DOMNode.ChildrenSnapshot {
        switch self {
        case let .unrequested(count):
            return .unrequested(count: count)
        case let .loaded(children):
            return .loaded(children)
        }
    }
}

package extension DOMSelection {
    enum ResolutionPhase: Equatable, Sendable {
        case idle
        case pending(DOMSelection.Request)
        case failed(DOMSelection.Failure)

        package var pendingRequest: DOMSelection.Request? {
            guard case let .pending(request) = self else {
                return nil
            }
            return request
        }

        package var failure: DOMSelection.Failure? {
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

    struct State: Equatable, Sendable {
        package var selectedNodeID: DOMNode.ID?
        package var resolution: DOMSelection.ResolutionPhase

        package init(
            selectedNodeID: DOMNode.ID? = nil,
            resolution: DOMSelection.ResolutionPhase = .idle
        ) {
            self.selectedNodeID = selectedNodeID
            self.resolution = resolution
        }

        package var pendingRequest: DOMSelection.Request? {
            resolution.pendingRequest
        }

        package var failure: DOMSelection.Failure? {
            resolution.failure
        }
    }
}

@MainActor
@Observable
package final class DOMSelection {
    private var state: DOMSelection.State

    package init(state: DOMSelection.State = DOMSelection.State()) {
        self.state = state
    }

    package var selectedNodeID: DOMNode.ID? {
        state.selectedNodeID
    }

    package var pendingRequest: DOMSelection.Request? {
        state.pendingRequest
    }

    package var failure: DOMSelection.Failure? {
        state.failure
    }

    package func hasStateChange(selecting nodeID: DOMNode.ID?) -> Bool {
        state.selectedNodeID != nodeID || !state.resolution.isIdle
    }

    @discardableResult
    package func select(_ nodeID: DOMNode.ID?) -> DOMSelection.Request? {
        let cancelledRequest = state.pendingRequest
        state.selectedNodeID = nodeID
        state.resolution = .idle
        return cancelledRequest
    }

    @discardableResult
    package func beginRequest(_ request: DOMSelection.Request) -> DOMSelection.Request? {
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
        pendingRequest: DOMSelection.Request
    ) -> DOMSelection.Request? {
        guard state.pendingRequest == pendingRequest else {
            return nil
        }
        state.selectedNodeID = selectedNodeID
        state.resolution = .idle
        return pendingRequest
    }

    @discardableResult
    package func fail(
        _ failure: DOMSelection.Failure,
        clearSelected: Bool = true
    ) -> DOMSelection.Request? {
        let cancelledRequest = state.pendingRequest
        if clearSelected {
            state.selectedNodeID = nil
        }
        state.resolution = .failed(failure)
        return cancelledRequest
    }

    package func rejectStaleRequest(_ failure: DOMSelection.Failure) {
        guard state.pendingRequest == nil else {
            return
        }
        state.resolution = .failed(failure)
    }
}
