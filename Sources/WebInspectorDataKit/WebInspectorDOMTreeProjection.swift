import WebInspectorProxyKit

package enum WebInspectorDOMTreeChildren: Equatable, Sendable {
    case unrequested(count: Int)
    case loaded([DOMNode.ID])
}

/// One immutable row in the context-local render tree. It contains canonical
/// topology and display values only; selection and reveal state belong to the
/// UI owner.
package struct WebInspectorDOMTreeRow: Equatable, Identifiable, Sendable {
    package let id: DOMNode.ID
    package let parentID: DOMNode.ID?
    package let nodeName: String
    package let localName: String
    package let nodeValue: String
    package let nodeType: Int
    package let frameID: FrameID?
    package let documentURL: String?
    package let baseURL: String?
    package let attributes: [String: String]
    package let attributeList: [DOMNode.Attribute]
    package let children: WebInspectorDOMTreeChildren
    package let contentDocumentID: DOMNode.ID?
    package let shadowRootIDs: [DOMNode.ID]
    package let templateContentID: DOMNode.ID?
    package let beforePseudoElementID: DOMNode.ID?
    package let otherPseudoElementIDs: [DOMNode.ID]
    package let afterPseudoElementID: DOMNode.ID?
    package let pseudoType: DOM.PseudoType?
    package let shadowRootType: DOM.ShadowRootType?
}

package struct WebInspectorDOMTreeSnapshot: Equatable, Sendable {
    package let primaryRootID: DOMNode.ID?
    package let rowsByID: [DOMNode.ID: WebInspectorDOMTreeRow]

    package init(
        primaryRootID: DOMNode.ID?,
        rowsByID: [DOMNode.ID: WebInspectorDOMTreeRow]
    ) {
        precondition(
            primaryRootID.map { rowsByID[$0] != nil } ?? rowsByID.isEmpty,
            "A context DOM tree must contain its primary root and cannot contain rows without one."
        )
        self.primaryRootID = primaryRootID
        self.rowsByID = rowsByID
    }
}

package struct WebInspectorDOMTreePrimaryRootChange: Equatable, Sendable {
    package let rootID: DOMNode.ID?
}

package struct WebInspectorDOMTreeDelta: Equatable, Sendable {
    package let primaryRootChange: WebInspectorDOMTreePrimaryRootChange?
    /// Complete row replacements keyed semantically by `id`; array order is
    /// not tree render order.
    package let upsertedRows: [WebInspectorDOMTreeRow]
    package let deletedRowIDs: Set<DOMNode.ID>

    package var isEmpty: Bool {
        primaryRootChange == nil
            && upsertedRows.isEmpty
            && deletedRowIDs.isEmpty
    }
}

package enum WebInspectorDOMTreePublicationChange: Equatable, Sendable {
    case reset(WebInspectorDOMTreeSnapshot)
    case delta(WebInspectorDOMTreeDelta)
}

package typealias WebInspectorDOMTreeUpdateSequence =
    WebInspectorRevisionedSnapshotSequence<
        WebInspectorDOMTreeSnapshot,
        WebInspectorDOMTreePublicationChange,
        Never
    >

package final class WebInspectorDOMTreeProjectionState {
    private typealias Publication = WebInspectorRevisionedSnapshotPublication<
        WebInspectorDOMTreeSnapshot,
        WebInspectorDOMTreePublicationChange,
        Never
    >

    private enum Pending {
        case initial(WebInspectorDOMTreeSnapshot)
        case reset(WebInspectorDOMTreeSnapshot)
        case delta(WebInspectorDOMTreeDelta)
    }

    private var revision: UInt64 = 0
    private var snapshot = WebInspectorDOMTreeSnapshot(
        primaryRootID: nil,
        rowsByID: [:]
    )
    private var pending: Pending?
    private var resetWasPrepared = false
    private var isEstablished = false
    private var isClosed = false
    private let publication = Publication()

    package func subscribe() -> WebInspectorDOMTreeUpdateSequence {
        precondition(!isClosed, "A closed DOM tree projection cannot be observed.")
        precondition(
            isEstablished && pending == nil,
            "A DOM tree projection can be observed only after its initial schema transaction."
        )
        return publication.subscribe(revision: revision, snapshot: snapshot)
    }

    package var currentSnapshot: WebInspectorDOMTreeSnapshot {
        precondition(
            isEstablished && pending == nil,
            "A DOM tree snapshot is available only after its initial schema transaction."
        )
        return snapshot
    }

    package func rebase(
        _ token: WebInspectorRevisionedSnapshotRebaseToken
    ) throws -> WebInspectorRevisionedSnapshotRebase<WebInspectorDOMTreeSnapshot> {
        try publication.rebase(
            token,
            revision: revision,
            snapshot: snapshot
        )
    }

    package func prepareReset() {
        precondition(!isClosed)
        precondition(pending == nil)
        resetWasPrepared = isEstablished
    }

    package func stage(snapshot: WebInspectorDOMTreeSnapshot) {
        precondition(!isClosed)
        precondition(pending == nil)
        pending =
            resetWasPrepared
            ? .reset(snapshot)
            : .initial(snapshot)
    }

    package func stage(delta: WebInspectorDOMTreeDelta) {
        precondition(!isClosed)
        precondition(isEstablished)
        precondition(pending == nil)
        guard !delta.isEmpty else {
            return
        }
        pending = .delta(delta)
    }

    package func finalize(
        registeredModel: (DOMNode.ID) -> DOMNode?
    ) {
        guard let pending else {
            resetWasPrepared = false
            return
        }
        self.pending = nil
        resetWasPrepared = false
        switch pending {
        case let .initial(snapshot):
            precondition(!isEstablished)
            self.snapshot = snapshot
            isEstablished = true

        case let .reset(snapshot):
            precondition(isEstablished)
            verifyMaterializedModels(
                snapshot.rowsByID.values,
                registeredModel: registeredModel
            )
            publish(.reset(snapshot), replacingWith: snapshot)

        case let .delta(delta):
            precondition(isEstablished)
            verifyMaterializedModels(
                delta.upsertedRows,
                registeredModel: registeredModel
            )
            publish(.delta(delta), replacingWith: applying(delta))
        }
    }

    package func close() {
        guard !isClosed else {
            return
        }
        isClosed = true
        pending = nil
        publication.finish()
    }

    private func publish(
        _ change: WebInspectorDOMTreePublicationChange,
        replacingWith snapshot: WebInspectorDOMTreeSnapshot
    ) {
        precondition(revision < UInt64.max)
        let previousRevision = revision
        revision += 1
        self.snapshot = snapshot
        publication.publish(
            from: previousRevision,
            to: revision,
            changes: change
        )
    }

    private func applying(
        _ delta: WebInspectorDOMTreeDelta
    ) -> WebInspectorDOMTreeSnapshot {
        var rowsByID = snapshot.rowsByID
        for id in delta.deletedRowIDs {
            rowsByID.removeValue(forKey: id)
        }
        for row in delta.upsertedRows {
            rowsByID[row.id] = row
        }
        let primaryRootID =
            delta.primaryRootChange?.rootID
            ?? snapshot.primaryRootID
        return WebInspectorDOMTreeSnapshot(
            primaryRootID: primaryRootID,
            rowsByID: rowsByID
        )
    }

    private func verifyMaterializedModels<Rows: Sequence>(
        _ rows: Rows,
        registeredModel: (DOMNode.ID) -> DOMNode?
    ) where Rows.Element == WebInspectorDOMTreeRow {
        for row in rows {
            guard let model = registeredModel(row.id) else {
                continue
            }
            precondition(
                model.nodeName == row.nodeName
                    && model.localName == row.localName
                    && model.nodeValue == row.nodeValue
                    && model.nodeType == row.nodeType
                    && model.frameID == row.frameID
                    && model.documentURL == row.documentURL
                    && model.baseURL == row.baseURL
                    && model.attributes == row.attributes
                    && model.childNodeCount == row.children.count,
                "A DOM tree publication must follow its materialized DOMNode mutation."
            )
        }
    }
}

private extension WebInspectorDOMTreeChildren {
    var count: Int {
        switch self {
        case let .unrequested(count):
            count
        case let .loaded(ids):
            ids.count
        }
    }
}

package extension WebInspectorModelContext {
    func domTreeUpdates() -> WebInspectorDOMTreeUpdateSequence {
        preconditionOwnerIsolation()
        return requiredDOMTreeProjectionState().subscribe()
    }

    var domTreeSnapshot: WebInspectorDOMTreeSnapshot {
        preconditionOwnerIsolation()
        return requiredDOMTreeProjectionState().currentSnapshot
    }

    func rebaseDOMTree(
        _ token: WebInspectorRevisionedSnapshotRebaseToken
    ) throws -> WebInspectorRevisionedSnapshotRebase<WebInspectorDOMTreeSnapshot> {
        preconditionOwnerIsolation()
        return try requiredDOMTreeProjectionState().rebase(token)
    }

    private func requiredDOMTreeProjectionState()
        -> WebInspectorDOMTreeProjectionState
    {
        guard
            let state = modelSchemaOwnerResource(
                for: DOMNode.self,
                as: WebInspectorDOMTreeProjectionState.self
            )
        else {
            preconditionFailure(
                "DOM tree projection requires the canonical DOMNode schema."
            )
        }
        return state
    }
}
