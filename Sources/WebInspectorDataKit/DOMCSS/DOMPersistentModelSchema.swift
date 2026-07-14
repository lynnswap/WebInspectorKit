import WebInspectorProxyKit

/// Context-local topology retained with one immutable canonical DOM record.
package struct WebInspectorDOMModelTopology: Equatable, Sendable {
    package let parentID: WebInspectorDOMNodeIdentityStorage?
    package let ancestorIDs: [WebInspectorDOMNodeIdentityStorage]
    package let documentRootID: WebInspectorDOMNodeIdentityStorage?
    package let children: WebInspectorCanonicalDOMChildren
    package let contentDocumentID: WebInspectorDOMNodeIdentityStorage?
    package let shadowRootIDs: [WebInspectorDOMNodeIdentityStorage]
    package let templateContentID: WebInspectorDOMNodeIdentityStorage?
    package let beforePseudoElementID: WebInspectorDOMNodeIdentityStorage?
    package let otherPseudoElementIDs: [WebInspectorDOMNodeIdentityStorage]
    package let afterPseudoElementID: WebInspectorDOMNodeIdentityStorage?

    package init(
        parentID: WebInspectorDOMNodeIdentityStorage?,
        ancestorIDs: [WebInspectorDOMNodeIdentityStorage],
        documentRootID: WebInspectorDOMNodeIdentityStorage?,
        record: WebInspectorCanonicalDOMRecord
    ) {
        self.parentID = parentID
        self.ancestorIDs = ancestorIDs
        self.documentRootID = documentRootID
        children = record.children
        contentDocumentID = record.contentDocumentID
        shadowRootIDs = record.shadowRootIDs
        templateContentID = record.templateContentID
        beforePseudoElementID = record.beforePseudoElementID
        otherPseudoElementIDs = record.otherPseudoElementIDs
        afterPseudoElementID = record.afterPseudoElementID
    }
}

/// The single immutable value used to materialize one context-local DOMNode.
package struct WebInspectorDOMModelRecord: Equatable, Sendable {
    package let canonical: WebInspectorCanonicalDOMRecord
    package let topology: WebInspectorDOMModelTopology
}

package let webInspectorDOMNodeSchema = WebInspectorModelSchema<
    DOMNode,
    WebInspectorDOMModelRecord
>(
    featureID: .dom,
    makeModel: { context, id, record in
        DOMNode(id: id, record: record, modelContext: context)
    },
    updateModel: { context, model, record in
        model.replace(with: record, modelContext: context)
    },
    invalidateModel: { _, model in
        model.invalidateCanonicalRecord()
    }
)

/// Builds the complete first DOM commit from one staged reducer.
package func webInspectorDOMSnapshotMutations(
    _ snapshot: WebInspectorCanonicalDOMSnapshot
) -> [WebInspectorModelMutation<DOMNode>] {
    snapshot.records.map { canonical in
        let topology = WebInspectorDOMModelTopology(
            parentID: snapshot.parentByNodeID[canonical.id],
            ancestorIDs: domAncestorIDs(
                for: canonical.id,
                parentByNodeID: snapshot.parentByNodeID
            ),
            documentRootID: snapshot.rootByDocumentScope[
                canonical.id.documentScope
            ],
            record: canonical
        )
        return webInspectorDOMNodeSchema.upsert(
            record: WebInspectorDOMModelRecord(
                canonical: canonical,
                topology: topology
            ),
            queryValue: domNodeQueryValue(
                canonical,
                topology: topology,
                primaryDocumentRootID: snapshot.tree.primaryRootID
            ),
            canonicalRank: WebInspectorModelCanonicalRank(
                rawValue: canonical.insertionOrdinal
            )
        )
    }
}

/// Converts exactly the identities touched by one canonical reducer turn.
/// The reducer has already staged the final value; no context/store scan is
/// needed to construct the generic transaction.
package func webInspectorDOMMutations(
    _ transaction: WebInspectorCanonicalDOMTransaction,
    staged reducer: WebInspectorCanonicalDOMReducer
) -> [WebInspectorModelMutation<DOMNode>] {
    if transaction.tree.primaryRootChange != nil {
        var reducer = reducer
        return webInspectorDOMSnapshotMutations(reducer.snapshot())
    }
    var touchedIDs = Set(transaction.insertedRecords.map(\.id))
    touchedIDs.formUnion(transaction.recordPatches.map(\.id))
    touchedIDs.formUnion(transaction.parentChanges.map(\.nodeID))
    touchedIDs.formUnion(transaction.topologyChangedNodeIDs)
    touchedIDs.formUnion(transaction.queryValueUpserts.keys)
    touchedIDs.subtract(transaction.deletedRecordIDs)

    var mutations: [WebInspectorModelMutation<DOMNode>] = []
    mutations.reserveCapacity(touchedIDs.count + transaction.deletedRecordIDs.count)
    for id in touchedIDs.sorted(by: domIdentityPrecedes) {
        guard let canonical = reducer.record(for: id) else { continue }
        let topology = WebInspectorDOMModelTopology(
            parentID: reducer.parent(of: id),
            ancestorIDs: reducer.ancestry(of: id).map { Array($0.dropLast()) }
                ?? [],
            documentRootID: reducer.root(in: id.documentScope),
            record: canonical
        )
        mutations.append(
            webInspectorDOMNodeSchema.upsert(
                record: WebInspectorDOMModelRecord(
                    canonical: canonical,
                    topology: topology
                ),
                queryValue: domNodeQueryValue(
                    canonical,
                    topology: topology,
                    primaryDocumentRootID: reducer.primaryDocumentRootID
                ),
                canonicalRank: WebInspectorModelCanonicalRank(
                    rawValue: canonical.insertionOrdinal
                )
            )
        )
    }
    for id in transaction.deletedRecordIDs.sorted(by: domIdentityPrecedes) {
        mutations.append(
            webInspectorDOMNodeSchema.delete(id: DOMNode.ID(canonical: id))
        )
    }
    return mutations
}

private func domNodeQueryValue(
    _ record: WebInspectorCanonicalDOMRecord,
    topology: WebInspectorDOMModelTopology,
    primaryDocumentRootID: WebInspectorDOMNodeIdentityStorage?
) -> DOMNode.QueryValue {
    let children: DOMNode.QueryValue.Children = switch topology.children {
    case let .unrequested(count):
        .unrequested(count: count)
    case let .loaded(ids):
        .loaded(ids.map(DOMNode.ID.init(canonical:)))
    }
    return DOMNode.QueryValue(
        id: DOMNode.ID(canonical: record.id),
        nodeName: record.nodeName,
        localName: record.localName,
        nodeValue: record.nodeValue,
        nodeType: record.nodeType,
        frameID: record.frameID.map(WebInspectorFrameID.init),
        documentURL: record.documentURL,
        baseURL: record.baseURL,
        attributes: Dictionary(
            uniqueKeysWithValues: record.attributes.map { ($0.name, $0.value) }
        ),
        attributeList: record.attributes.map(DOMNode.Attribute.init),
        parentID: topology.parentID.map(DOMNode.ID.init(canonical:)),
        documentRootID: topology.documentRootID.map(DOMNode.ID.init(canonical:)),
        primaryDocumentRootID: primaryDocumentRootID.map(
            DOMNode.ID.init(canonical:)
        ),
        children: children,
        contentDocumentID: topology.contentDocumentID.map(DOMNode.ID.init(canonical:)),
        shadowRootIDs: topology.shadowRootIDs.map(DOMNode.ID.init(canonical:)),
        templateContentID: topology.templateContentID.map(DOMNode.ID.init(canonical:)),
        beforePseudoElementID: topology.beforePseudoElementID.map(DOMNode.ID.init(canonical:)),
        otherPseudoElementIDs: topology.otherPseudoElementIDs.map(DOMNode.ID.init(canonical:)),
        afterPseudoElementID: topology.afterPseudoElementID.map(DOMNode.ID.init(canonical:)),
        pseudoType: record.pseudoType.map(DOMPseudoElementKind.init),
        shadowRootType: record.shadowRootType.map(DOMShadowRootKind.init)
    )
}

private func domAncestorIDs(
    for id: WebInspectorDOMNodeIdentityStorage,
    parentByNodeID: [
        WebInspectorDOMNodeIdentityStorage: WebInspectorDOMNodeIdentityStorage
    ]
) -> [WebInspectorDOMNodeIdentityStorage] {
    var result: [WebInspectorDOMNodeIdentityStorage] = []
    var current = parentByNodeID[id]
    var visited: Set<WebInspectorDOMNodeIdentityStorage> = []
    while let nodeID = current, visited.insert(nodeID).inserted {
        result.append(nodeID)
        current = parentByNodeID[nodeID]
    }
    return result.reversed()
}

private func domIdentityPrecedes(
    _ lhs: WebInspectorDOMNodeIdentityStorage,
    _ rhs: WebInspectorDOMNodeIdentityStorage
) -> Bool {
    if lhs.documentScope != rhs.documentScope {
        return WebInspectorDOMDocumentScopeStorage.precedesInCanonicalOrder(
            lhs.documentScope,
            rhs.documentScope
        )
    }
    return lhs.rawNodeID.rawValue < rhs.rawNodeID.rawValue
}
