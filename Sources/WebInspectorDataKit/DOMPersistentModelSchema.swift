import WebInspectorProxyKit

extension WebInspectorCanonicalDOMRecord: WebInspectorModelRecord {}

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

package struct WebInspectorDOMModelRecord: Equatable, Sendable,
    WebInspectorModelRecord
{
    package enum Patch: Equatable, Sendable {
        case canonical(WebInspectorCanonicalDOMRecordPatch)
        case topology(WebInspectorDOMModelTopology)
    }

    package var canonical: WebInspectorCanonicalDOMRecord
    package var topology: WebInspectorDOMModelTopology

    package mutating func apply(_ patch: Patch) {
        switch patch {
        case let .canonical(patch):
            canonical.apply(patch)
        case let .topology(topology):
            self.topology = topology
        }
    }
}

private enum DOMNodeSchemaOwnerEffect: Sendable {
    case topology([DOMNode.ID: WebInspectorDOMModelTopology])
    case invalidateResources(Set<WebInspectorCanonicalResourceInvalidation>)
}

package enum WebInspectorDOMModelSchemas {
    package static var registrations: [WebInspectorModelSchemaRegistration] {
        [WebInspectorModelSchemaRegistration(.domNode)]
    }
}

package extension WebInspectorModelSchema where Model == DOMNode {
    /// Canonical DOM record, query, topology, and node-resource mapping.
    static var domNode: Self {
        WebInspectorModelSchema(
            snapshot: domNodeSnapshot,
            delta: domNodeDelta,
            makeModel: { context, id, record in
                DOMNode(
                    id: id,
                    record: record,
                    modelContext: context
                )
            },
            replaceModel: { context, model, record in
                model.replace(
                    with: record,
                    modelContext: context
                )
            },
            applyPatch: { _, model, patch in
                if case let .canonical(canonical) = patch {
                    model.applyCanonicalRecordPatch(canonical)
                }
            },
            invalidateModel: { _, model in
                model.invalidateCanonicalRecord()
            },
            applyOwnerEffect: { _, effect, models in
                switch effect {
                case let .topology(topologyByID):
                    for (id, topology) in topologyByID {
                        models.model(for: id)?.applyCanonicalTopology(
                            topology
                        )
                    }
                case let .invalidateResources(invalidations):
                    models.forEachRegisteredModel { model in
                        model.applyCanonicalResourceInvalidations(
                            invalidations
                        )
                    }
                }
            },
            resetOwnerProjection: { _, models in
                models.forEachRegisteredModel { model in
                    model.resetCanonicalOwnerProjection()
                }
            }
        )
    }
}

private func domNodeSnapshot(
    _ snapshot: WebInspectorCanonicalModelSnapshot
) -> WebInspectorModelSchemaSnapshot<
    DOMNode,
    WebInspectorDOMModelRecord,
    DOMNodeSchemaOwnerEffect
> {
    guard let DOM = snapshot.DOM else {
        preconditionFailure(
            "A configured DOMNode schema requires a canonical DOM projection."
        )
    }
    var projector = DOMNodeTopologyProjector(
        recordsByID: DOM.recordsByID,
        parentByID: DOM.parentByNodeID,
        rootByScope: DOM.rootByDocumentScope
    )
    let entries:
        [WebInspectorModelSchemaSnapshotEntry<
            DOMNode,
            WebInspectorDOMModelRecord
        >] = DOM.records.map { canonical in
            let topology = projector.topology(for: canonical.id)
            return WebInspectorModelSchemaSnapshotEntry(
                id: DOMNode.ID(canonical: canonical.id),
                record: WebInspectorDOMModelRecord(
                    canonical: canonical,
                    topology: topology
                ),
                queryValue: domNodeQueryValue(canonical.queryValue),
                canonicalRank: .init(rawValue: canonical.insertionOrdinal)
            )
        }
    return WebInspectorModelSchemaSnapshot(entries: entries)
}

private func domNodeDelta(
    _ transaction: WebInspectorCanonicalModelTransaction,
    _ lookup: WebInspectorModelSchemaRecordLookup<
        DOMNode,
        WebInspectorDOMModelRecord
    >
) -> WebInspectorModelSchemaDelta<
    DOMNode,
    WebInspectorDOMModelRecord,
    DOMNodeSchemaOwnerEffect
> {
    guard let DOM = transaction.DOM else {
        let invalidations = transaction.CSS?.resourceInvalidations ?? []
        return WebInspectorModelSchemaDelta(
            changes: [],
            ownerEffects: invalidations.isEmpty
                ? []
                : [.invalidateResources(invalidations)]
        )
    }

    var builder = DOMNodeSchemaDeltaBuilder(
        transaction: DOM,
        lookup: lookup
    )
    let result = builder.build()
    let invalidations = DOM.resourceInvalidations.union(
        transaction.CSS?.resourceInvalidations ?? []
    )
    var ownerEffects: [DOMNodeSchemaOwnerEffect] = []
    if !result.topologyByID.isEmpty {
        ownerEffects.append(.topology(result.topologyByID))
    }
    if !invalidations.isEmpty {
        ownerEffects.append(.invalidateResources(invalidations))
    }
    return WebInspectorModelSchemaDelta(
        changes: result.changes,
        ownerEffects: ownerEffects
    )
}

private struct DOMNodeSchemaDeltaBuilder {
    private enum ParentAssignment {
        case none
        case parent(WebInspectorDOMNodeIdentityStorage)

        var id: WebInspectorDOMNodeIdentityStorage? {
            switch self {
            case .none:
                nil
            case let .parent(id):
                id
            }
        }
    }

    struct Result {
        let changes:
            [WebInspectorModelSchemaChange<
                DOMNode,
                WebInspectorDOMModelRecord
            >]
        let topologyByID: [DOMNode.ID: WebInspectorDOMModelTopology]
    }

    private let transaction: WebInspectorCanonicalDOMTransaction
    private let lookup:
        WebInspectorModelSchemaRecordLookup<
            DOMNode,
            WebInspectorDOMModelRecord
        >
    private var orderedIDs: [WebInspectorDOMNodeIdentityStorage] = []
    private var seenIDs: Set<WebInspectorDOMNodeIdentityStorage> = []
    private var insertedIDs: Set<WebInspectorDOMNodeIdentityStorage> = []
    private var canonicalPatchesByID: [WebInspectorDOMNodeIdentityStorage: [WebInspectorCanonicalDOMRecordPatch]] = [:]
    private var recordsByID: [WebInspectorDOMNodeIdentityStorage: WebInspectorDOMModelRecord] = [:]
    private var parentAssignments: [WebInspectorDOMNodeIdentityStorage: ParentAssignment] = [:]
    private var explicitRootByScope: [WebInspectorDOMDocumentScopeStorage: WebInspectorDOMNodeIdentityStorage] = [:]
    private var retiredRootScopes: Set<WebInspectorDOMDocumentScopeStorage> = []
    private var projectedTopologyByID: [WebInspectorDOMNodeIdentityStorage: WebInspectorDOMModelTopology] = [:]
    private var topologyStack: Set<WebInspectorDOMNodeIdentityStorage> = []

    init(
        transaction: WebInspectorCanonicalDOMTransaction,
        lookup: WebInspectorModelSchemaRecordLookup<
            DOMNode,
            WebInspectorDOMModelRecord
        >
    ) {
        self.transaction = transaction
        self.lookup = lookup
    }

    mutating func build() -> Result {
        precondition(
            transaction.queryValueDeletes == transaction.deletedRecordIDs,
            "Canonical DOM record and query deletions must have identical membership."
        )
        collectRecordsAndTopologyInputs()
        projectFinalTopology()
        return Result(
            changes: makeChanges(),
            topologyByID: makeTopologyOwnerEffect()
        )
    }

    private mutating func collectRecordsAndTopologyInputs() {
        for canonical in transaction.insertedRecords {
            addToOrder(canonical.id)
            precondition(
                lookup.record(for: DOMNode.ID(canonical: canonical.id)) == nil,
                "Canonical DOM inserted an existing persistent identity."
            )
            insertedIDs.insert(canonical.id)
            recordsByID[canonical.id] = WebInspectorDOMModelRecord(
                canonical: canonical,
                topology: WebInspectorDOMModelTopology(
                    parentID: nil,
                    ancestorIDs: [],
                    documentRootID: nil,
                    record: canonical
                )
            )
        }

        for patch in transaction.recordPatches {
            addToOrder(patch.id)
            var record = requiredWorkingRecord(for: patch.id)
            record.canonical.apply(patch)
            recordsByID[patch.id] = record
            canonicalPatchesByID[patch.id, default: []].append(patch)
        }

        for change in transaction.parentChanges {
            addToOrder(change.nodeID)
            _ = requiredWorkingRecord(for: change.nodeID)
            parentAssignments[change.nodeID] =
                if let parentID = change.parentID {
                    ParentAssignment.parent(parentID)
                } else {
                    ParentAssignment.none
                }
        }

        for id in transaction.topologyChangedNodeIDs.sorted(
            by: Self.precedesInCanonicalOrder
        ) {
            addToOrder(id)
            _ = requiredWorkingRecord(for: id)
        }

        for change in transaction.rootChanges {
            if let rootID = change.rootID {
                precondition(
                    explicitRootByScope.updateValue(
                        rootID,
                        forKey: change.scope
                    ) == nil,
                    "A canonical DOM transaction changed one document root twice."
                )
                addToOrder(rootID)
                _ = requiredWorkingRecord(for: rootID)
            } else {
                retiredRootScopes.insert(change.scope)
            }
        }
    }

    private mutating func projectFinalTopology() {
        for id in orderedIDs where !transaction.deletedRecordIDs.contains(id) {
            let projectedTopology = topology(for: id)
            var record = requiredWorkingRecord(for: id)
            record.topology = projectedTopology
            recordsByID[id] = record
        }
    }

    private mutating func topology(
        for id: WebInspectorDOMNodeIdentityStorage
    ) -> WebInspectorDOMModelTopology {
        if let projected = projectedTopologyByID[id] {
            return projected
        }
        precondition(
            topologyStack.insert(id).inserted,
            "Canonical DOM schema topology contains a parent cycle."
        )
        defer { topologyStack.remove(id) }

        let record = requiredWorkingRecord(for: id)
        let parentID: WebInspectorDOMNodeIdentityStorage?
        if let assignment = parentAssignments[id] {
            parentID = assignment.id
        } else {
            parentID = record.topology.parentID
        }
        let parentTopology: WebInspectorDOMModelTopology?
        if let parentID,
            !transaction.deletedRecordIDs.contains(parentID)
        {
            parentTopology = topology(for: parentID)
        } else {
            parentTopology = nil
        }
        let ancestorIDs =
            parentID.map { parentID in
                (parentTopology?.ancestorIDs ?? []) + [parentID]
            } ?? []
        let documentRootID: WebInspectorDOMNodeIdentityStorage?
        if explicitRootByScope[id.documentScope] == id {
            documentRootID = id
        } else if retiredRootScopes.contains(id.documentScope) {
            documentRootID = nil
        } else if let parentID,
            parentID.documentScope == id.documentScope
        {
            documentRootID = parentTopology?.documentRootID
        } else {
            documentRootID = record.topology.documentRootID
        }
        let projected = WebInspectorDOMModelTopology(
            parentID: parentID,
            ancestorIDs: ancestorIDs,
            documentRootID: documentRootID,
            record: record.canonical
        )
        projectedTopologyByID[id] = projected
        return projected
    }

    private mutating func makeChanges() -> [WebInspectorModelSchemaChange<
        DOMNode,
        WebInspectorDOMModelRecord
    >] {
        var changes:
            [WebInspectorModelSchemaChange<
                DOMNode,
                WebInspectorDOMModelRecord
            >] = []
        for id in orderedIDs where !transaction.deletedRecordIDs.contains(id) {
            guard let record = recordsByID[id] else {
                preconditionFailure(
                    "DOM schema order referenced an absent final record."
                )
            }
            let persistentID = DOMNode.ID(canonical: id)
            if insertedIDs.contains(id) {
                guard let query = transaction.queryValueUpserts[id] else {
                    preconditionFailure(
                        "A canonical DOM insertion omitted its query value."
                    )
                }
                changes.append(
                    .insert(
                        id: persistentID,
                        record: record,
                        queryValue: domNodeQueryValue(query),
                        canonicalRank: .init(
                            rawValue: record.canonical.insertionOrdinal
                        )
                    )
                )
                continue
            }

            let previous = requiredLookupRecord(for: id)
            var patches = (canonicalPatchesByID[id] ?? []).map(
                WebInspectorDOMModelRecord.Patch.canonical
            )
            if previous.topology != record.topology {
                patches.append(.topology(record.topology))
            }
            precondition(
                !patches.isEmpty,
                "A DOM schema update did not change record content or topology."
            )
            let query = transaction.queryValueUpserts[id]
            changes.append(
                .update(
                    id: persistentID,
                    patches: WebInspectorModelRecordPatchBatch(patches),
                    queryValue: query.map(domNodeQueryValue),
                    canonicalRank: query.map { _ in
                        .init(rawValue: record.canonical.insertionOrdinal)
                    }
                )
            )
        }

        let deleted = transaction.deletedRecordIDs.sorted { lhs, rhs in
            let lhsRecord = requiredLookupRecord(for: lhs)
            let rhsRecord = requiredLookupRecord(for: rhs)
            return lhsRecord.canonical.insertionOrdinal
                < rhsRecord.canonical.insertionOrdinal
        }
        changes.append(
            contentsOf: deleted.map {
                .delete(id: DOMNode.ID(canonical: $0))
            })
        return changes
    }

    private func makeTopologyOwnerEffect()
        -> [DOMNode.ID: WebInspectorDOMModelTopology]
    {
        Dictionary(
            uniqueKeysWithValues: orderedIDs.compactMap { id in
                guard !insertedIDs.contains(id),
                    !transaction.deletedRecordIDs.contains(id),
                    let record = recordsByID[id]
                else {
                    return nil
                }
                let hasTopologyInput =
                    parentAssignments[id] != nil
                    || transaction.topologyChangedNodeIDs.contains(id)
                    || explicitRootByScope[id.documentScope] == id
                    || canonicalPatchesByID[id]?.contains(where: {
                        $0.fields.contains(where: Self.isTopologyField)
                    }) == true
                guard hasTopologyInput else {
                    return nil
                }
                return (DOMNode.ID(canonical: id), record.topology)
            }
        )
    }

    private mutating func requiredWorkingRecord(
        for id: WebInspectorDOMNodeIdentityStorage
    ) -> WebInspectorDOMModelRecord {
        if let record = recordsByID[id] {
            return record
        }
        let record = requiredLookupRecord(for: id)
        recordsByID[id] = record
        return record
    }

    private func requiredLookupRecord(
        for id: WebInspectorDOMNodeIdentityStorage
    ) -> WebInspectorDOMModelRecord {
        guard let record = lookup.record(for: DOMNode.ID(canonical: id)) else {
            preconditionFailure(
                "Canonical DOM schema work referenced a missing record."
            )
        }
        return record
    }

    private mutating func addToOrder(
        _ id: WebInspectorDOMNodeIdentityStorage
    ) {
        if seenIDs.insert(id).inserted {
            orderedIDs.append(id)
        }
    }

    private static func isTopologyField(
        _ field: WebInspectorCanonicalDOMRecordPatch.Field
    ) -> Bool {
        switch field {
        case .children,
            .contentDocument,
            .shadowRoots,
            .templateContent,
            .beforePseudoElement,
            .otherPseudoElements,
            .afterPseudoElement:
            true
        case .nodeName,
            .localName,
            .nodeValue,
            .nodeType,
            .frameID,
            .documentURL,
            .baseURL,
            .attributes,
            .pseudoType,
            .shadowRootType:
            false
        }
    }

    private static func precedesInCanonicalOrder(
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
}

private struct DOMNodeTopologyProjector {
    private let recordsByID: [WebInspectorDOMNodeIdentityStorage: WebInspectorCanonicalDOMRecord]
    private let parentByID: [WebInspectorDOMNodeIdentityStorage: WebInspectorDOMNodeIdentityStorage]
    private let rootByScope: [WebInspectorDOMDocumentScopeStorage: WebInspectorDOMNodeIdentityStorage]
    private var topologyByID: [WebInspectorDOMNodeIdentityStorage: WebInspectorDOMModelTopology] = [:]
    private var stack: Set<WebInspectorDOMNodeIdentityStorage> = []

    init(
        recordsByID: [WebInspectorDOMNodeIdentityStorage: WebInspectorCanonicalDOMRecord],
        parentByID: [WebInspectorDOMNodeIdentityStorage: WebInspectorDOMNodeIdentityStorage],
        rootByScope: [WebInspectorDOMDocumentScopeStorage: WebInspectorDOMNodeIdentityStorage]
    ) {
        self.recordsByID = recordsByID
        self.parentByID = parentByID
        self.rootByScope = rootByScope
    }

    mutating func topology(
        for id: WebInspectorDOMNodeIdentityStorage
    ) -> WebInspectorDOMModelTopology {
        if let topology = topologyByID[id] {
            return topology
        }
        guard let record = recordsByID[id] else {
            preconditionFailure(
                "Canonical DOM snapshot topology referenced a missing record."
            )
        }
        precondition(
            stack.insert(id).inserted,
            "Canonical DOM snapshot topology contains a parent cycle."
        )
        defer { stack.remove(id) }
        let parentID = parentByID[id]
        let parentTopology = parentID.map { topology(for: $0) }
        let ancestors =
            parentID.map { parentID in
                (parentTopology?.ancestorIDs ?? []) + [parentID]
            } ?? []
        let documentRootID: WebInspectorDOMNodeIdentityStorage?
        if rootByScope[id.documentScope] == id {
            documentRootID = id
        } else if let parentID,
            parentID.documentScope == id.documentScope
        {
            documentRootID = parentTopology?.documentRootID
        } else {
            documentRootID = nil
        }
        let result = WebInspectorDOMModelTopology(
            parentID: parentID,
            ancestorIDs: ancestors,
            documentRootID: documentRootID,
            record: record
        )
        topologyByID[id] = result
        return result
    }
}

private func domNodeQueryValue(
    _ query: WebInspectorCanonicalDOMQueryValue
) -> DOMNode.QueryValue {
    DOMNode.QueryValue(
        id: DOMNode.ID(canonical: query.id),
        nodeName: query.nodeName,
        localName: query.localName,
        nodeValue: query.nodeValue,
        nodeType: query.nodeType,
        frameID: query.frameID,
        documentURL: query.documentURL,
        baseURL: query.baseURL,
        attributes: query.attributes,
        childNodeCount: query.childNodeCount,
        pseudoType: query.pseudoType,
        shadowRootType: query.shadowRootType
    )
}
