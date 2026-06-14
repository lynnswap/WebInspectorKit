import Observation
import WebInspectorTransport

@MainActor
@Observable
package final class DOMDocumentStore {
    private struct TargetSlot {
        var state: DOMTargetState?
        var lastDocumentLifetimeID: UInt64 = 0

        var isEmpty: Bool {
            state == nil && lastDocumentLifetimeID == 0
        }

        mutating func nextDocumentID(for targetID: ProtocolTarget.ID) -> DOMDocument.ID {
            lastDocumentLifetimeID += 1
            return DOMDocument.ID(
                targetID: targetID,
                localDocumentLifetimeID: DOMDocument.LifetimeID(lastDocumentLifetimeID)
            )
        }

        @MainActor
        mutating func state(for targetID: ProtocolTarget.ID) -> DOMTargetState {
            if let state {
                return state
            }
            let state = DOMTargetState(targetID: targetID)
            self.state = state
            return state
        }
    }

    private var slotsByTargetID: [ProtocolTarget.ID: TargetSlot]

    package init() {
        slotsByTargetID = [:]
    }

    package func reset() {
        // Document identifiers are scoped to the DOMSession lifetime; reset only drops current document state.
        slotsByTargetID = slotsByTargetID.compactMapValues { slot in
            var slot = slot
            slot.state = nil
            return slot.isEmpty ? nil : slot
        }
    }

    package func nextDocumentID(for targetID: ProtocolTarget.ID) -> DOMDocument.ID {
        var slot = slotsByTargetID[targetID] ?? TargetSlot()
        let documentID = slot.nextDocumentID(for: targetID)
        slotsByTargetID[targetID] = slot
        return documentID
    }

    package func state(for targetID: ProtocolTarget.ID) -> DOMTargetState {
        var slot = slotsByTargetID[targetID] ?? TargetSlot()
        let state = slot.state(for: targetID)
        slotsByTargetID[targetID] = slot
        return state
    }

    package func stateIfPresent(for targetID: ProtocolTarget.ID) -> DOMTargetState? {
        slotsByTargetID[targetID]?.state
    }

    @discardableResult
    package func removeState(for targetID: ProtocolTarget.ID) -> DOMTargetState? {
        guard var slot = slotsByTargetID[targetID] else {
            return nil
        }
        let state = slot.state
        slot.state = nil
        store(slot, for: targetID)
        return state
    }

    package func currentDocument(forTargetID targetID: ProtocolTarget.ID) -> DOMDocument? {
        slotsByTargetID[targetID]?.state?.currentDocument
    }

    package func currentLoadedDocumentID(for targetID: ProtocolTarget.ID) -> DOMDocument.ID? {
        guard let document = slotsByTargetID[targetID]?.state?.currentDocument,
              document.lifecycle == .loaded else {
            return nil
        }
        return document.id
    }

    package func currentDocument(for documentID: DOMDocument.ID) -> DOMDocument? {
        guard let document = slotsByTargetID[documentID.targetID]?.state?.currentDocument,
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
        slotsByTargetID.values.compactMap { $0.state?.currentDocument }
    }

    package func currentNodeIDsByKey() -> [DOMNode.CurrentKey: DOMNode.ID] {
        let states = slotsByTargetID.values.compactMap(\.state)
        return Dictionary(uniqueKeysWithValues: states.compactMap { state -> [(DOMNode.CurrentKey, DOMNode.ID)]? in
            guard let document = state.currentDocument else {
                return nil
            }
            guard document.lifecycle == .loaded else {
                return []
            }
            return document.currentNodeIDByProtocolNodeID.map {
                (DOMNode.CurrentKey(targetID: state.targetID, nodeID: $0.key), $0.value)
            }
        }.flatMap { $0 })
    }

    package func transactions() -> [DOMTransaction] {
        currentDocuments.flatMap { document in
            document.transactions.values
        }
    }

    package func currentNodeID(targetID: ProtocolTarget.ID, rawNodeID: DOMNode.ProtocolID) -> DOMNode.ID? {
        slotsByTargetID[targetID]?.state?.currentDocument?.currentNodeIDByProtocolNodeID[rawNodeID]
    }

    package func removeTransaction(_ transactionID: DOMTransaction.ID, targetID: ProtocolTarget.ID?) {
        if let targetID {
            slotsByTargetID[targetID]?.state?.currentDocument?.removeTransaction(transactionID)
            return
        }
        for state in slotsByTargetID.values.compactMap(\.state) {
            state.currentDocument?.removeTransaction(transactionID)
        }
    }

    package func clearOwnerHydrationTransactions(targetID: ProtocolTarget.ID) {
        slotsByTargetID[targetID]?.state?.currentDocument?.removeOwnerHydrationTransactions()
    }

    package func targetStateSnapshots(
        currentDocumentID: (ProtocolTarget.ID) -> DOMDocument.ID?
    ) -> [ProtocolTarget.ID: DOMTargetState.Snapshot] {
        Dictionary(uniqueKeysWithValues: slotsByTargetID.compactMap { targetID, slot in
            guard let state = slot.state else {
                return nil
            }
            return (
                targetID,
                DOMTargetState.Snapshot(
                    targetID: state.targetID,
                    currentDocumentID: currentDocumentID(state.targetID),
                    transactionIDs: state.currentDocument.map { Array($0.transactions.keys) } ?? []
                )
            )
        })
    }

    private func store(_ slot: TargetSlot, for targetID: ProtocolTarget.ID) {
        if slot.isEmpty {
            slotsByTargetID.removeValue(forKey: targetID)
        } else {
            slotsByTargetID[targetID] = slot
        }
    }
}
