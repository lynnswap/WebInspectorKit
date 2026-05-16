import Foundation

package struct DOMTargetCommit: Equatable, Sendable {
    package var oldFrameID: DOMFrame.ID?
}

package struct DOMTargetRemoval: Equatable, Sendable {
    package var frameID: DOMFrame.ID?
}

@MainActor
package final class DOMTargetGraph {
    private var targetsByID: [ProtocolTarget.ID: ProtocolTarget]
    private var framesByID: [DOMFrame.ID: DOMFrame]
    private var executionContextsByID: [ExecutionContextID: ExecutionContextRecord]

    package init() {
        targetsByID = [:]
        framesByID = [:]
        executionContextsByID = [:]
    }

    package func reset() {
        targetsByID.removeAll()
        framesByID.removeAll()
        executionContextsByID.removeAll()
    }

    package func containsTarget(_ targetID: ProtocolTarget.ID) -> Bool {
        targetsByID[targetID] != nil
    }

    private func target(for targetID: ProtocolTarget.ID) -> ProtocolTarget? {
        targetsByID[targetID]
    }

    package func targetKind(for targetID: ProtocolTarget.ID) -> ProtocolTargetKind? {
        targetsByID[targetID]?.kind
    }

    package func targetCapabilities(for targetID: ProtocolTarget.ID) -> ProtocolTargetCapabilities {
        targetsByID[targetID]?.capabilities ?? []
    }

    package func targetFrameID(for targetID: ProtocolTarget.ID) -> DOMFrame.ID? {
        targetsByID[targetID]?.frameID
    }

    package func targetParentFrameID(for targetID: ProtocolTarget.ID) -> DOMFrame.ID? {
        targetsByID[targetID]?.parentFrameID
    }

    package func isTopLevelPageTarget(_ targetID: ProtocolTarget.ID) -> Bool {
        guard let target = targetsByID[targetID] else {
            return false
        }
        return target.kind == .page && target.parentFrameID == nil
    }

    package func upsertTarget(from record: ProtocolTargetRecord) {
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
    }

    package func removeTarget(_ targetID: ProtocolTarget.ID) -> DOMTargetRemoval? {
        guard let target = targetsByID.removeValue(forKey: targetID) else {
            return nil
        }
        return DOMTargetRemoval(frameID: target.frameID)
    }

    @discardableResult
    package func markTargetCommitted(_ targetID: ProtocolTarget.ID) -> Bool {
        guard let target = targetsByID[targetID] else {
            return false
        }
        target.isProvisional = false
        if target.kind == .frame {
            attachFrameTarget(target)
        }
        return true
    }

    package func commitTarget(oldTargetID: ProtocolTarget.ID, newTargetID: ProtocolTarget.ID) -> DOMTargetCommit? {
        guard let oldTarget = targetsByID.removeValue(forKey: oldTargetID) else {
            return nil
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
        if let frameID {
            retargetFrame(frameID, from: oldTargetID, to: newTargetID)
        }
        return DOMTargetCommit(oldFrameID: oldTarget.frameID)
    }

    package func targetBelongsToCurrentPage(
        _ targetID: ProtocolTarget.ID,
        currentPageTargetID: ProtocolTarget.ID?,
        mainFrameID: DOMFrame.ID?
    ) -> Bool {
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

    package func hasFrame(_ frameID: DOMFrame.ID) -> Bool {
        framesByID[frameID] != nil
    }

    package func frameCurrentDocumentID(_ frameID: DOMFrame.ID) -> DOMDocument.ID? {
        framesByID[frameID]?.currentDocumentID
    }

    package func setFrameCurrentDocumentID(_ documentID: DOMDocument.ID?, for frameID: DOMFrame.ID) {
        framesByID[frameID]?.currentDocumentID = documentID
    }

    package func clearFrameCurrentDocumentID(_ frameID: DOMFrame.ID, matching documentID: DOMDocument.ID) {
        if framesByID[frameID]?.currentDocumentID == documentID {
            framesByID[frameID]?.currentDocumentID = nil
        }
    }

    package func setFrameTargetID(_ targetID: ProtocolTarget.ID?, for frameID: DOMFrame.ID) {
        framesByID[frameID]?.targetID = targetID
    }

    package func frameTargetID(_ frameID: DOMFrame.ID) -> ProtocolTarget.ID? {
        framesByID[frameID]?.targetID
    }

    package func assignMainFrame(_ frameID: DOMFrame.ID, to targetID: ProtocolTarget.ID) {
        let frame = frameWithID(frameID, parentFrameID: nil)
        frame.targetID = targetID
        targetsByID[targetID]?.frameID = frameID
    }

    package func attachFrameTarget(_ targetID: ProtocolTarget.ID) {
        guard let target = targetsByID[targetID] else {
            return
        }
        attachFrameTarget(target)
    }

    private func attachFrameTarget(_ target: ProtocolTarget) {
        guard let frameID = target.frameID else {
            return
        }
        let frame = frameWithID(frameID, parentFrameID: target.parentFrameID)
        frame.targetID = target.id
    }

    package func attachKnownFrameTargets(mainFrameID: DOMFrame.ID?) {
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

    private func retargetFrame(_ frameID: DOMFrame.ID, from oldTargetID: ProtocolTarget.ID, to newTargetID: ProtocolTarget.ID) {
        let frame = frameWithID(frameID, parentFrameID: target(for: newTargetID)?.parentFrameID)
        if frame.targetID == oldTargetID || frame.targetID == nil {
            frame.targetID = newTargetID
        }
    }

    package func clearCurrentDocumentReference(
        _ documentID: DOMDocument.ID,
        targetFrameID: DOMFrame.ID?,
        targetID: ProtocolTarget.ID,
        currentPageTargetID: ProtocolTarget.ID?,
        mainFrameID: DOMFrame.ID?
    ) {
        if let frameID = targetFrameID,
           framesByID[frameID]?.currentDocumentID == documentID {
            framesByID[frameID]?.currentDocumentID = nil
        }
        if currentPageTargetID == targetID,
           let mainFrameID,
           framesByID[mainFrameID]?.currentDocumentID == documentID {
            framesByID[mainFrameID]?.currentDocumentID = nil
        }
    }

    package func removeExecutionContexts(targetID: ProtocolTarget.ID) {
        executionContextsByID = executionContextsByID.filter { $0.value.targetID != targetID }
    }

    package func retargetExecutionContexts(from oldTargetID: ProtocolTarget.ID, to newTargetID: ProtocolTarget.ID) {
        for (contextID, record) in executionContextsByID where record.targetID == oldTargetID {
            executionContextsByID[contextID] = ExecutionContextRecord(
                id: record.id,
                targetID: newTargetID,
                frameID: record.frameID
            )
        }
    }

    package func recordExecutionContext(_ record: ExecutionContextRecord) {
        executionContextsByID[record.id] = record
    }

    package func targetSnapshots(
        currentDocumentID: (ProtocolTarget.ID) -> DOMDocument.ID?
    ) -> [ProtocolTarget.ID: ProtocolTargetSnapshot] {
        targetsByID.mapValues {
            ProtocolTargetSnapshot(
                id: $0.id,
                kind: $0.kind,
                frameID: $0.frameID,
                parentFrameID: $0.parentFrameID,
                capabilities: $0.capabilities,
                isProvisional: $0.isProvisional,
                isPaused: $0.isPaused,
                currentDocumentID: currentDocumentID($0.id)
            )
        }
    }

    package func frameSnapshots() -> [DOMFrame.ID: DOMFrameSnapshot] {
        framesByID.mapValues {
            DOMFrameSnapshot(
                id: $0.id,
                parentFrameID: $0.parentFrameID,
                childFrameIDs: $0.childFrameIDs,
                targetID: $0.targetID,
                currentDocumentID: $0.currentDocumentID
            )
        }
    }

    package func executionContextSnapshots() -> [ExecutionContextID: ExecutionContextRecord] {
        executionContextsByID
    }
}

@MainActor
package final class DOMDocumentStore {
    private var targetStatesByID: [ProtocolTarget.ID: DOMTargetState]
    private var lastDocumentLifetimeIDByTargetID: [ProtocolTarget.ID: UInt64]

    package init() {
        targetStatesByID = [:]
        lastDocumentLifetimeIDByTargetID = [:]
    }

    package func reset() {
        // Document identifiers are scoped to the DOMSession lifetime; reset only drops current document state.
        targetStatesByID.removeAll()
    }

    package func nextDocumentID(for targetID: ProtocolTarget.ID) -> DOMDocument.ID {
        let nextDocumentLifetimeID = (lastDocumentLifetimeIDByTargetID[targetID] ?? 0) + 1
        lastDocumentLifetimeIDByTargetID[targetID] = nextDocumentLifetimeID
        return DOMDocument.ID(
            targetID: targetID,
            localDocumentLifetimeID: DOMDocumentLifetimeIdentifier(nextDocumentLifetimeID)
        )
    }

    package func state(for targetID: ProtocolTarget.ID) -> DOMTargetState {
        let state = targetStatesByID[targetID] ?? DOMTargetState(targetID: targetID)
        targetStatesByID[targetID] = state
        return state
    }

    package func stateIfPresent(for targetID: ProtocolTarget.ID) -> DOMTargetState? {
        targetStatesByID[targetID]
    }

    @discardableResult
    package func removeState(for targetID: ProtocolTarget.ID) -> DOMTargetState? {
        targetStatesByID.removeValue(forKey: targetID)
    }

    package func currentDocument(forTargetID targetID: ProtocolTarget.ID) -> DOMDocument? {
        targetStatesByID[targetID]?.currentDocument
    }

    package func currentLoadedDocumentID(for targetID: ProtocolTarget.ID) -> DOMDocument.ID? {
        guard let document = targetStatesByID[targetID]?.currentDocument,
              document.lifecycle == .loaded else {
            return nil
        }
        return document.id
    }

    package func currentDocument(for documentID: DOMDocument.ID) -> DOMDocument? {
        guard let document = targetStatesByID[documentID.targetID]?.currentDocument,
              document.id == documentID,
              document.lifecycle == .loaded else {
            return nil
        }
        return document
    }

    package func node(for nodeID: DOMNode.ID) -> DOMNode? {
        currentDocument(for: nodeID.documentID)?.nodesByID[nodeID]
    }

    package var currentDocuments: [DOMDocument] {
        targetStatesByID.values.compactMap(\.currentDocument)
    }

    package func currentNodeIDsByKey() -> [DOMNodeCurrentKey: DOMNode.ID] {
        Dictionary(uniqueKeysWithValues: targetStatesByID.values.compactMap { state -> [(DOMNodeCurrentKey, DOMNode.ID)]? in
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
    }

    package func transactions() -> [DOMTransaction] {
        currentDocuments.flatMap { document in
            document.transactions.values
        }
    }

    package func currentNodeID(targetID: ProtocolTarget.ID, rawNodeID: DOMProtocolNodeID) -> DOMNode.ID? {
        targetStatesByID[targetID]?.currentDocument?.currentNodeIDByProtocolNodeID[rawNodeID]
    }

    package func removeTransaction(_ transactionID: DOMTransaction.ID, targetID: ProtocolTarget.ID?) {
        if let targetID {
            targetStatesByID[targetID]?.currentDocument?.removeTransaction(transactionID)
            return
        }
        for state in targetStatesByID.values {
            state.currentDocument?.removeTransaction(transactionID)
        }
    }

    package func clearOwnerHydrationTransactions(targetID: ProtocolTarget.ID) {
        targetStatesByID[targetID]?.currentDocument?.removeOwnerHydrationTransactions()
    }

    package func targetStateSnapshots(
        currentDocumentID: (ProtocolTarget.ID) -> DOMDocument.ID?
    ) -> [ProtocolTarget.ID: DOMTargetStateSnapshot] {
        targetStatesByID.mapValues { state in
            DOMTargetStateSnapshot(
                targetID: state.targetID,
                currentDocumentID: currentDocumentID(state.targetID),
                transactionIDs: state.currentDocument.map { Array($0.transactions.keys) } ?? []
            )
        }
    }
}

package struct FrameDocumentProjection: Equatable, Sendable {
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

@MainActor
package struct FrameDocumentProjectionIndex {
    private var projectionsByFrameTargetID: [ProtocolTarget.ID: FrameDocumentProjection]

    package init() {
        projectionsByFrameTargetID = [:]
    }

    package var values: Dictionary<ProtocolTarget.ID, FrameDocumentProjection>.Values {
        projectionsByFrameTargetID.values
    }

    package var frameTargetIDs: Dictionary<ProtocolTarget.ID, FrameDocumentProjection>.Keys {
        projectionsByFrameTargetID.keys
    }

    package subscript(frameTargetID: ProtocolTarget.ID) -> FrameDocumentProjection? {
        projectionsByFrameTargetID[frameTargetID]
    }

    package mutating func removeAll() {
        projectionsByFrameTargetID.removeAll()
    }

    @discardableResult
    package mutating func removeValue(forKey frameTargetID: ProtocolTarget.ID) -> FrameDocumentProjection? {
        projectionsByFrameTargetID.removeValue(forKey: frameTargetID)
    }

    @discardableResult
    package mutating func moveProjection(
        from oldTargetID: ProtocolTarget.ID,
        to newTargetID: ProtocolTarget.ID
    ) -> FrameDocumentProjection? {
        guard var projection = projectionsByFrameTargetID.removeValue(forKey: oldTargetID) else {
            return nil
        }
        projection.frameTargetID = newTargetID
        projectionsByFrameTargetID[newTargetID] = projection
        return projection
    }

    @discardableResult
    package mutating func setFrameDocument(
        frameTargetID: ProtocolTarget.ID,
        frameDocumentID: DOMDocument.ID
    ) -> FrameDocumentProjection {
        var projection = projectionsByFrameTargetID[frameTargetID] ?? FrameDocumentProjection(
            ownerNodeID: nil,
            frameTargetID: frameTargetID,
            frameDocumentID: frameDocumentID,
            state: .pending
        )
        projection.frameTargetID = frameTargetID
        projection.frameDocumentID = frameDocumentID
        projection.ownerNodeID = nil
        projection.state = .pending
        projectionsByFrameTargetID[frameTargetID] = projection
        return projection
    }

    package mutating func attach(frameTargetID: ProtocolTarget.ID, to ownerNodeID: DOMNode.ID) {
        guard var projection = projectionsByFrameTargetID[frameTargetID] else {
            return
        }
        projection.ownerNodeID = ownerNodeID
        projection.state = .attached
        projectionsByFrameTargetID[frameTargetID] = projection
    }

    package mutating func detach(
        frameTargetID: ProtocolTarget.ID,
        state: FrameDocumentProjectionState = .pending
    ) {
        guard var projection = projectionsByFrameTargetID[frameTargetID] else {
            return
        }
        projection.ownerNodeID = nil
        projection.state = state
        projectionsByFrameTargetID[frameTargetID] = projection
    }

    package func projectedFrameDocumentRootID(
        forOwnerNodeID ownerNodeID: DOMNode.ID,
        documentProvider: (DOMDocument.ID) -> DOMDocument?
    ) -> DOMNode.ID? {
        for projection in projectionsByFrameTargetID.values
            where projection.ownerNodeID == ownerNodeID && projection.state == .attached {
            guard let document = documentProvider(projection.frameDocumentID) else {
                continue
            }
            return document.rootNodeID
        }
        return nil
    }

    package func ownerKeys(
        inSubtree rootID: DOMNode.ID,
        nodeProvider: (DOMNode.ID) -> DOMNode?
    ) -> [ProtocolTarget.ID: DOMNodeCurrentKey] {
        var keys: [ProtocolTarget.ID: DOMNodeCurrentKey] = [:]
        var stack = [rootID]
        while let nodeID = stack.popLast() {
            guard let node = nodeProvider(nodeID) else {
                continue
            }
            for projection in projectionsByFrameTargetID.values where projection.ownerNodeID == nodeID {
                keys[projection.frameTargetID] = DOMNodeCurrentKey(
                    targetID: nodeID.documentID.targetID,
                    nodeID: node.protocolNodeID
                )
            }
            stack.append(contentsOf: node.protocolOwnedChildren)
        }
        return keys
    }

    package func snapshots() -> [ProtocolTarget.ID: FrameDocumentProjectionSnapshot] {
        projectionsByFrameTargetID.mapValues { projection in
            FrameDocumentProjectionSnapshot(
                ownerNodeID: projection.ownerNodeID,
                frameTargetID: projection.frameTargetID,
                frameDocumentID: projection.frameDocumentID,
                state: projection.state
            )
        }
    }
}

@MainActor
package struct DOMTreeProjectionBuilder {
    package typealias NodeProvider = @MainActor (DOMNode.ID) -> DOMNode?
    package typealias FrameDocumentRootResolver = @MainActor (DOMNode.ID) -> DOMNode.ID?

    private let rootDocument: DOMDocument
    private let selectedNodeID: DOMNode.ID?
    private let nodeProvider: NodeProvider
    private let frameDocumentRootResolver: FrameDocumentRootResolver

    package init(
        rootDocument: DOMDocument,
        selectedNodeID: DOMNode.ID?,
        nodeProvider: @escaping NodeProvider,
        frameDocumentRootResolver: @escaping FrameDocumentRootResolver
    ) {
        self.rootDocument = rootDocument
        self.selectedNodeID = selectedNodeID
        self.nodeProvider = nodeProvider
        self.frameDocumentRootResolver = frameDocumentRootResolver
    }

    package func build() -> DOMTreeProjection {
        var rows: [DOMTreeRow] = []
        var childrenByNodeID: [DOMNode.ID: [DOMNode.ID]] = [:]
        var parentByNodeID: [DOMNode.ID: DOMNode.ID] = [:]
        var visited = Set<DOMNode.ID>()

        append(
            rootDocument.rootNodeID,
            depth: 0,
            rows: &rows,
            childrenByNodeID: &childrenByNodeID,
            parentByNodeID: &parentByNodeID,
            visited: &visited
        )

        return DOMTreeProjection(
            rows: rows,
            rootNodeIDs: [rootDocument.rootNodeID],
            childrenByNodeID: childrenByNodeID,
            parentByNodeID: parentByNodeID
        )
    }

    package static func visibleChildIDs(
        of node: DOMNode,
        frameDocumentRootResolver: FrameDocumentRootResolver
    ) -> [DOMNode.ID] {
        var children: [DOMNode.ID] = []
        if let templateContentID = node.templateContentID {
            children.append(templateContentID)
        }
        if let beforePseudoElementID = node.beforePseudoElementID {
            children.append(beforePseudoElementID)
        }
        children.append(contentsOf: node.otherPseudoElementIDs)
        children.append(contentsOf: effectiveChildIDs(of: node, frameDocumentRootResolver: frameDocumentRootResolver))
        if let afterPseudoElementID = node.afterPseudoElementID {
            children.append(afterPseudoElementID)
        }
        return children
    }

    private static func effectiveChildIDs(
        of node: DOMNode,
        frameDocumentRootResolver: FrameDocumentRootResolver
    ) -> [DOMNode.ID] {
        if node.isFrameOwner,
           let rootNodeID = frameDocumentRootResolver(node.id) {
            return [rootNodeID]
        }
        if let contentDocumentID = node.contentDocumentID {
            return [contentDocumentID]
        }
        return node.shadowRootIDs + node.regularChildren.loadedChildren
    }

    private func append(
        _ nodeID: DOMNode.ID,
        depth: Int,
        rows: inout [DOMTreeRow],
        childrenByNodeID: inout [DOMNode.ID: [DOMNode.ID]],
        parentByNodeID: inout [DOMNode.ID: DOMNode.ID],
        visited: inout Set<DOMNode.ID>
    ) {
        guard visited.insert(nodeID).inserted,
              let node = nodeProvider(nodeID) else {
            return
        }
        let visibleChildren = Self.visibleChildIDs(
            of: node,
            frameDocumentRootResolver: frameDocumentRootResolver
        )
        childrenByNodeID[nodeID] = visibleChildren
        rows.append(
            DOMTreeRow(
                nodeID: nodeID,
                depth: depth,
                nodeName: node.nodeName,
                isSelected: selectedNodeID == nodeID,
                hasVisibleChildren: !visibleChildren.isEmpty || node.regularChildren.knownCount > 0
            )
        )
        for childID in visibleChildren {
            parentByNodeID[childID] = nodeID
            append(
                childID,
                depth: depth + 1,
                rows: &rows,
                childrenByNodeID: &childrenByNodeID,
                parentByNodeID: &parentByNodeID,
                visited: &visited
            )
        }
    }
}
