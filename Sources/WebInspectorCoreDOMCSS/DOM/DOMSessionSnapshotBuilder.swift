import WebInspectorCoreRuntime
import WebInspectorCoreSupport
import WebInspectorTransport

@MainActor
struct DOMSessionSnapshotBuilder {
    var currentPageTargetID: ProtocolTarget.ID?
    var mainFrameID: DOMFrame.ID?
    var targetSnapshots: [ProtocolTarget.ID: DOMTarget.Snapshot]
    var targetStateSnapshots: [ProtocolTarget.ID: DOMTargetState.Snapshot]
    var frameSnapshots: [DOMFrame.ID: DOMFrame.Snapshot]
    var documents: [DOMDocument]
    var frameDocumentProjections: [ProtocolTarget.ID: FrameDocumentProjection.Snapshot]
    var transactions: [DOMTransaction]
    var currentNodeIDByKey: [DOMNode.CurrentKey: DOMNode.ID]
    var executionContextsByKey: [RuntimeContext.Key: RuntimeContext.Record]
    var selection: DOMSelection

    func build() -> DOMSession.Snapshot {
        let documentsByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        let nodesByID = Dictionary(uniqueKeysWithValues: documents.flatMap { document in
            document.nodesByID.map { ($0.key, $0.value) }
        })
        return DOMSession.Snapshot(
            currentPageTargetID: currentPageTargetID,
            mainFrameID: mainFrameID,
            targetsByID: targetSnapshots,
            targetStatesByID: targetStateSnapshots,
            framesByID: frameSnapshots,
            documentsByID: documentsByID.mapValues(documentSnapshot),
            nodesByID: nodesByID.mapValues(nodeSnapshot),
            frameDocumentProjections: frameDocumentProjections,
            transactions: transactions.map(transactionSnapshot),
            currentNodeIDByKey: currentNodeIDByKey,
            executionContextsByKey: executionContextsByKey,
            selection: selectionSnapshot(selection)
        )
    }

    private func documentSnapshot(_ document: DOMDocument) -> DOMDocument.Snapshot {
        DOMDocument.Snapshot(
            id: document.id,
            targetID: document.targetID,
            localDocumentLifetimeID: document.localDocumentLifetimeID,
            lifecycle: document.lifecycle,
            rootNodeID: document.rootNodeID
        )
    }

    private func nodeSnapshot(_ node: DOMNode) -> DOMNode.Snapshot {
        DOMNode.Snapshot(
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
            regularChildren: regularChildrenSnapshot(node.regularChildren),
            contentDocumentID: node.contentDocumentID,
            shadowRootIDs: node.shadowRootIDs,
            templateContentID: node.templateContentID,
            beforePseudoElementID: node.beforePseudoElementID,
            otherPseudoElementIDs: node.otherPseudoElementIDs,
            afterPseudoElementID: node.afterPseudoElementID,
            pseudoType: node.pseudoType,
            shadowRootType: node.shadowRootType
        )
    }

    private func transactionSnapshot(_ transaction: DOMTransaction) -> DOMTransaction.Snapshot {
        DOMTransaction.Snapshot(
            id: transaction.id,
            targetID: transaction.targetID,
            documentID: transaction.documentID,
            kind: transaction.kind,
            issuedSequence: transaction.issuedSequence,
            requestedProtocolNodeID: transaction.requestedProtocolNodeID
        )
    }

    private func selectionSnapshot(_ selection: DOMSelection) -> DOMSelection.Snapshot {
        DOMSelection.Snapshot(
            selectedNodeID: selection.selectedNodeID,
            pendingRequest: selection.pendingRequest.map {
                DOMSelection.Request.Snapshot(id: $0.id, targetID: $0.targetID, documentID: $0.documentID)
            },
            failure: selection.failure
        )
    }

    private func regularChildrenSnapshot(_ regularChildren: DOMNode.ChildrenState) -> DOMNode.ChildrenSnapshot {
        switch regularChildren {
        case let .unrequested(count):
            return .unrequested(count: count)
        case let .loaded(children):
            return .loaded(children)
        }
    }
}
