import Observation
import WebInspectorTransport

@MainActor
@Observable
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
        if let state = targetStatesByID[targetID] {
            return state
        }
        let state = DOMTargetState(targetID: targetID)
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
