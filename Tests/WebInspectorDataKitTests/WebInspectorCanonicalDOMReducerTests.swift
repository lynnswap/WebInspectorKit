import Foundation
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@Test
func canonicalDOMIdentityIncludesEveryLifetimeAndPhysicalTargetAxis() throws {
    let storeA = WebInspectorContainerStoreID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let storeB = WebInspectorContainerStoreID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    let attachmentA = WebInspectorAttachmentGeneration(rawValue: 1)
    let attachmentB = WebInspectorAttachmentGeneration(rawValue: 2)
    let baseEventScope = canonicalDOMScope()
    let base = try #require(
        WebInspectorDOMDocumentScopeStorage(
            storeID: storeA,
            attachmentGeneration: attachmentA,
            eventScope: baseEventScope
        ))
    let variants = [
        WebInspectorDOMDocumentScopeStorage(
            storeID: storeB,
            attachmentGeneration: attachmentA,
            eventScope: baseEventScope
        ),
        WebInspectorDOMDocumentScopeStorage(
            storeID: storeA,
            attachmentGeneration: attachmentB,
            eventScope: baseEventScope
        ),
        WebInspectorDOMDocumentScopeStorage(
            storeID: storeA,
            attachmentGeneration: attachmentA,
            eventScope: canonicalDOMScope(generation: 2)
        ),
        WebInspectorDOMDocumentScopeStorage(
            storeID: storeA,
            attachmentGeneration: attachmentA,
            eventScope: canonicalDOMScope(targetID: "other-target")
        ),
        WebInspectorDOMDocumentScopeStorage(
            storeID: storeA,
            attachmentGeneration: attachmentA,
            eventScope: canonicalDOMScope(domEpoch: 2)
        ),
        WebInspectorDOMDocumentScopeStorage(
            storeID: storeA,
            attachmentGeneration: attachmentA,
            eventScope: canonicalDOMScope(agentTargetID: "other-agent")
        ),
    ].compactMap { $0 }

    #expect(variants.count == 6)
    #expect(variants.allSatisfy { $0 != base })
    #expect(base.semanticTargetID == WebInspectorTarget.ID("page"))
    #expect(base.agentTargetID == WebInspectorTarget.ID("agent"))
    let rawID = DOM.Node.ID("7")
    #expect(
        Set(
            variants.map {
                WebInspectorDOMNodeIdentityStorage(documentScope: $0, rawNodeID: rawID)
            }
        ).count == variants.count)
}

@Test
func canonicalDOMKeepsSameSemanticRawIdentityDistinctAcrossAllocatingAgents() throws {
    let firstEventScope = canonicalDOMScope(agentTargetID: "agent-a")
    let secondEventScope = canonicalDOMScope(agentTargetID: "agent-b")
    let fixture = canonicalDOMReducerFixture(scope: firstEventScope)
    var reducer = fixture.reducer
    let root = canonicalDOMNode(id: "document", type: 9, name: "#document")

    _ = try reducer.bootstrap(scope: firstEventScope, root: root)
    _ = try reducer.bootstrap(scope: secondEventScope, root: root)
    let firstScope = try canonicalDocumentScope(fixture, eventScope: firstEventScope)
    let secondScope = try canonicalDocumentScope(fixture, eventScope: secondEventScope)
    let firstID = canonicalDOMID("document", scope: firstScope)
    let secondID = canonicalDOMID("document", scope: secondScope)

    #expect(firstID != secondID)
    #expect(firstID.documentScope.semanticTargetID == secondID.documentScope.semanticTargetID)
    #expect(firstID.documentScope.agentTargetID == WebInspectorTarget.ID("agent-a"))
    #expect(secondID.documentScope.agentTargetID == WebInspectorTarget.ID("agent-b"))
    #expect(reducer.record(for: firstID) != nil)
    #expect(reducer.record(for: secondID) != nil)

    _ = try reducer.targetLost(scope: firstEventScope)
    #expect(reducer.record(for: firstID) == nil)
    #expect(reducer.record(for: secondID) != nil)
}

@Test
func canonicalDOMScopeDerivesSemanticAndAgentTargetsFromModelScope() {
    let scope = canonicalDOMScope(
        targetID: "semantic-target",
        agentTargetID: "agent-target"
    )

    #expect(scope.semanticTargetID == WebInspectorTarget.ID("semantic-target"))
    #expect(scope.agentTargetID == WebInspectorTarget.ID("agent-target"))
}

@Test
func canonicalDOMBootstrapBuildsNormalizedGraphAndTypedInitialTransaction() throws {
    let fixture = canonicalDOMReducerFixture()
    var reducer = fixture.reducer
    let scope = fixture.scope
    let before = canonicalDOMNode(id: "before", pseudoType: .before)
    let shadow = canonicalDOMNode(id: "shadow", shadowRootType: .open)
    let body = canonicalDOMNode(
        id: "body",
        name: "BODY",
        localName: "body",
        attributes: [DOM.Attribute(name: "id", value: "main")],
        shadowRoots: [shadow],
        beforePseudoElement: before
    )
    let root = canonicalDOMNode(
        id: "document",
        type: 9,
        name: "#document",
        children: [body]
    )

    let transaction = try reducer.bootstrap(scope: scope, root: root)
    let documentScope = try canonicalDocumentScope(fixture, eventScope: scope)
    let rootID = canonicalDOMID("document", scope: documentScope)
    let bodyID = canonicalDOMID("body", scope: documentScope)
    let shadowID = canonicalDOMID("shadow", scope: documentScope)
    let beforeID = canonicalDOMID("before", scope: documentScope)

    #expect(transaction.insertedRecords.count == 4)
    #expect(
        transaction.insertedRecords.map(\.id) == [
            rootID,
            bodyID,
            shadowID,
            beforeID,
        ]
    )
    #expect(transaction.insertedRecords.map(\.insertionOrdinal) == [1, 2, 3, 4])
    #expect(reducer.snapshot().records.map(\.id) == transaction.insertedRecords.map(\.id))
    #expect(transaction.parentChanges.count == 4)
    #expect(
        transaction.rootChanges == [
            WebInspectorCanonicalDOMRootChange(scope: documentScope, rootID: rootID)
        ])
    #expect(transaction.queryValueUpserts.count == 4)
    #expect(reducer.root(in: documentScope) == rootID)
    #expect(reducer.parent(of: bodyID) == rootID)
    #expect(reducer.parent(of: shadowID) == bodyID)
    #expect(reducer.record(for: bodyID)?.queryValue.attributes == ["id": "main"])
    #expect(reducer.performanceCounters.fullGraphBuildCount == 1)
    #expect(reducer.performanceCounters.fullGraphNodeVisitCount == 4)
    #expect(reducer.performanceCounters.unrelatedRecordScanCount == 0)
}

@Test
func canonicalDOMRecordPatchAppliesFieldsSequentiallyWithoutReplacingIdentity() throws {
    let fixture = canonicalDOMReducerFixture()
    var reducer = fixture.reducer
    let host = canonicalDOMNode(id: "host")
    _ = try reducer.bootstrap(
        scope: fixture.scope,
        root: canonicalDOMNode(
            id: "document",
            type: 9,
            name: "#document",
            children: [
                canonicalDOMNode(id: "parent", children: [host])
            ]
        )
    )
    let scope = try canonicalDocumentScope(fixture, eventScope: fixture.scope)
    let id = canonicalDOMID("host", scope: scope)
    let childID = canonicalDOMID("child", scope: scope)
    let contentID = canonicalDOMID("content", scope: scope)
    let shadowID = canonicalDOMID("shadow", scope: scope)
    let templateID = canonicalDOMID("template", scope: scope)
    let beforeID = canonicalDOMID("before", scope: scope)
    let markerID = canonicalDOMID("marker", scope: scope)
    let afterID = canonicalDOMID("after", scope: scope)
    let initial = try #require(reducer.record(for: id))
    let firstAttributes = [
        DOM.Attribute(name: "class", value: "first"),
        DOM.Attribute(name: "data-order", value: "1"),
    ]
    let replacement = canonicalDOMNode(
        id: "host",
        type: 3,
        name: "SPAN",
        localName: "span",
        value: "first",
        frameID: FrameID("frame"),
        documentURL: "https://example.test/document",
        baseURL: "https://example.test/",
        attributes: firstAttributes,
        children: [canonicalDOMNode(id: "child")],
        contentDocument: canonicalDOMNode(
            id: "content",
            type: 9,
            name: "#document"
        ),
        shadowRoots: [canonicalDOMNode(id: "shadow")],
        templateContent: canonicalDOMNode(id: "template"),
        beforePseudoElement: canonicalDOMNode(id: "before", pseudoType: .before),
        otherPseudoElements: [
            canonicalDOMNode(id: "marker", pseudoType: .other("marker"))
        ],
        afterPseudoElement: canonicalDOMNode(id: "after", pseudoType: .after),
        pseudoType: .before,
        shadowRootType: .open
    )
    let firstTransaction = try reducer.apply(
        scope: fixture.scope,
        event: .setChildNodes(
            parent: DOM.Node.ID("parent"),
            nodes: [replacement]
        )
    )
    let firstPatch = try #require(
        firstTransaction.recordPatches.first { $0.id == id }
    )
    #expect(
        firstPatch.fields == [
            .nodeName("SPAN"),
            .localName("span"),
            .nodeValue("first"),
            .nodeType(3),
            .frameID(FrameID("frame")),
            .documentURL("https://example.test/document"),
            .baseURL("https://example.test/"),
            .attributes(firstAttributes),
            .children(.loaded([childID])),
            .contentDocument(contentID),
            .shadowRoots([shadowID]),
            .templateContent(templateID),
            .beforePseudoElement(beforeID),
            .otherPseudoElements([markerID]),
            .afterPseudoElement(afterID),
            .pseudoType(.before),
            .shadowRootType(.open),
        ])

    var projected = initial
    projected.apply(firstPatch)
    #expect(projected == reducer.record(for: id))
    #expect(projected.id == initial.id)
    #expect(projected.insertionOrdinal == initial.insertionOrdinal)

    let secondTransaction = try reducer.apply(
        scope: fixture.scope,
        event: .characterDataModified(DOM.Node.ID("host"), value: "second")
    )
    let secondPatch = try #require(
        secondTransaction.recordPatches.first { $0.id == id }
    )
    #expect(secondPatch.fields == [.nodeValue("second")])
    projected.apply(secondPatch)

    #expect(projected == reducer.record(for: id))
    #expect(projected.nodeName == "SPAN")
    #expect(projected.localName == "span")
    #expect(projected.templateContentID == templateID)
    #expect(projected.beforePseudoElementID == beforeID)
    #expect(projected.afterPseudoElementID == afterID)
    #expect(projected.shadowRootType == .open)
    #expect(projected.id == initial.id)
    #expect(projected.insertionOrdinal == initial.insertionOrdinal)
}

@Test
func canonicalDOMBootstrapPreservesEveryProtocolRelationshipWithoutFlatteningIt() throws {
    let fixture = canonicalDOMReducerFixture()
    var reducer = fixture.reducer
    let content = canonicalDOMNode(id: "content", type: 9, name: "#document")
    let template = canonicalDOMNode(id: "template", type: 11, name: "#document-fragment")
    let before = canonicalDOMNode(id: "before", pseudoType: .before)
    let marker = canonicalDOMNode(id: "marker", pseudoType: .other("marker"))
    let after = canonicalDOMNode(id: "after", pseudoType: .after)
    let owner = canonicalDOMNode(
        id: "owner",
        contentDocument: content,
        templateContent: template,
        beforePseudoElement: before,
        otherPseudoElements: [marker],
        afterPseudoElement: after
    )
    _ = try reducer.bootstrap(
        scope: fixture.scope,
        root: canonicalDOMNode(
            id: "document",
            type: 9,
            name: "#document",
            children: [owner]
        )
    )
    let scope = try canonicalDocumentScope(fixture, eventScope: fixture.scope)
    let ownerID = canonicalDOMID("owner", scope: scope)
    let record = try #require(reducer.record(for: ownerID))

    #expect(record.contentDocumentID == canonicalDOMID("content", scope: scope))
    #expect(record.templateContentID == canonicalDOMID("template", scope: scope))
    #expect(record.beforePseudoElementID == canonicalDOMID("before", scope: scope))
    #expect(record.otherPseudoElementIDs == [canonicalDOMID("marker", scope: scope)])
    #expect(record.afterPseudoElementID == canonicalDOMID("after", scope: scope))
    #expect(reducer.parent(of: canonicalDOMID("content", scope: scope)) == ownerID)
    #expect(reducer.parent(of: canonicalDOMID("template", scope: scope)) == ownerID)
    #expect(reducer.parent(of: canonicalDOMID("after", scope: scope)) == ownerID)
}

@Test
func canonicalDOMBootstrapRejectsMalformedPayloadWithoutChangingState() throws {
    let fixture = canonicalDOMReducerFixture()
    var reducer = fixture.reducer
    let validRoot = canonicalDOMNode(id: "document", type: 9, name: "#document")
    _ = try reducer.bootstrap(scope: fixture.scope, root: validRoot)
    let stateBefore = reducer.snapshot()
    let countersBefore = reducer.performanceCounters

    #expect(
        throws: WebInspectorCanonicalDOMError.bootstrapAlreadyExists(
            try canonicalDocumentScope(fixture, eventScope: fixture.scope)
        )
    ) {
        try reducer.bootstrap(scope: fixture.scope, root: validRoot)
    }
    #expect(reducer.snapshot() == stateBefore)
    #expect(reducer.performanceCounters.fullGraphBuildCount == countersBefore.fullGraphBuildCount)

    var fresh = fixture.reducer
    let duplicate = canonicalDOMNode(
        id: "document",
        type: 9,
        name: "#document",
        children: [
            canonicalDOMNode(id: "same"),
            canonicalDOMNode(id: "same"),
        ]
    )
    let freshBefore = fresh.snapshot()
    #expect(throws: (any Error).self) {
        try fresh.bootstrap(scope: fixture.scope, root: duplicate)
    }
    #expect(fresh.snapshot() == freshBefore)

    let inconsistentAttributes = DOM.Node(
        id: DOM.Node.ID("document"),
        nodeType: 9,
        nodeName: "#document",
        attributes: ["class": "dictionary"],
        attributeList: [DOM.Attribute(name: "class", value: "ordered")]
    )
    #expect(throws: (any Error).self) {
        try fresh.bootstrap(scope: fixture.scope, root: inconsistentAttributes)
    }
    #expect(fresh.snapshot() == freshBefore)
}

@Test
func canonicalDOMAppliesEveryLocalPatchWithoutRebuildingTheGraph() throws {
    let fixture = canonicalDOMReducerFixture()
    var reducer = fixture.reducer
    let lazy = canonicalDOMNode(id: "lazy", childCount: 1)
    let text = canonicalDOMNode(id: "text", type: 3, name: "#text", value: "before")
    let host = canonicalDOMNode(
        id: "host",
        attributes: [DOM.Attribute(name: "class", value: "before")]
    )
    let root = canonicalDOMNode(
        id: "document",
        type: 9,
        name: "#document",
        children: [lazy, text, host]
    )
    _ = try reducer.bootstrap(scope: fixture.scope, root: root)
    let documentScope = try canonicalDocumentScope(fixture, eventScope: fixture.scope)
    let lazyID = canonicalDOMID("lazy", scope: documentScope)
    let textID = canonicalDOMID("text", scope: documentScope)
    let hostID = canonicalDOMID("host", scope: documentScope)

    let countTransaction = try reducer.apply(
        scope: fixture.scope,
        event: .childNodeCountUpdated(DOM.Node.ID("lazy"), count: 2)
    )
    #expect(
        countTransaction.recordPatches.first?.fields == [
            .children(.unrequested(count: 2))
        ])

    let children = [canonicalDOMNode(id: "first"), canonicalDOMNode(id: "second")]
    _ = try reducer.apply(
        scope: fixture.scope,
        event: .setChildNodes(parent: DOM.Node.ID("lazy"), nodes: children)
    )
    let inserted = canonicalDOMNode(id: "inserted")
    _ = try reducer.apply(
        scope: fixture.scope,
        event: .childNodeInserted(
            parent: DOM.Node.ID("lazy"),
            previous: DOM.Node.ID("first"),
            node: inserted
        )
    )
    #expect(
        reducer.record(for: lazyID)?.children
            == .loaded([
                canonicalDOMID("first", scope: documentScope),
                canonicalDOMID("inserted", scope: documentScope),
                canonicalDOMID("second", scope: documentScope),
            ]))
    _ = try reducer.apply(
        scope: fixture.scope,
        event: .childNodeRemoved(parent: DOM.Node.ID("lazy"), node: DOM.Node.ID("inserted"))
    )

    let attributeTransaction = try reducer.apply(
        scope: fixture.scope,
        event: .attributeModified(DOM.Node.ID("host"), name: "class", value: "after")
    )
    #expect(attributeTransaction.queryValueUpserts[hostID]?.attributes == ["class": "after"])
    #expect(attributeTransaction.resourceInvalidations == [.subtree(hostID)])
    _ = try reducer.apply(
        scope: fixture.scope,
        event: .attributeRemoved(DOM.Node.ID("host"), name: "class")
    )
    _ = try reducer.apply(
        scope: fixture.scope,
        event: .characterDataModified(DOM.Node.ID("text"), value: "after")
    )
    #expect(reducer.record(for: textID)?.nodeValue == "after")

    let shadow = canonicalDOMNode(id: "shadow", shadowRootType: .closed)
    _ = try reducer.apply(
        scope: fixture.scope,
        event: .shadowRootPushed(host: DOM.Node.ID("host"), root: shadow)
    )
    #expect(reducer.record(for: hostID)?.shadowRootIDs == [canonicalDOMID("shadow", scope: documentScope)])
    _ = try reducer.apply(
        scope: fixture.scope,
        event: .shadowRootPushed(
            host: DOM.Node.ID("host"),
            root: canonicalDOMNode(
                id: "shadow",
                attributes: [DOM.Attribute(name: "data-state", value: "updated")],
                shadowRootType: .closed
            )
        )
    )
    #expect(
        reducer.record(for: canonicalDOMID("shadow", scope: documentScope))?.queryValue.attributes == [
            "data-state": "updated"
        ])
    _ = try reducer.apply(
        scope: fixture.scope,
        event: .shadowRootPopped(host: DOM.Node.ID("host"), root: DOM.Node.ID("shadow"))
    )

    let before = canonicalDOMNode(id: "before", pseudoType: .before)
    let other = canonicalDOMNode(id: "marker", pseudoType: .other("marker"))
    _ = try reducer.apply(
        scope: fixture.scope,
        event: .pseudoElementAdded(parent: DOM.Node.ID("host"), element: before)
    )
    _ = try reducer.apply(
        scope: fixture.scope,
        event: .pseudoElementAdded(parent: DOM.Node.ID("host"), element: other)
    )
    _ = try reducer.apply(
        scope: fixture.scope,
        event: .pseudoElementRemoved(parent: DOM.Node.ID("host"), element: DOM.Node.ID("before"))
    )
    #expect(
        reducer.record(for: hostID)?.otherPseudoElementIDs == [
            canonicalDOMID("marker", scope: documentScope)
        ])

    let inlineTransaction = try reducer.apply(
        scope: fixture.scope,
        event: .inlineStyleInvalidated([DOM.Node.ID("host"), DOM.Node.ID("text")])
    )
    #expect(inlineTransaction.resourceInvalidations == [.subtree(hostID), .subtree(textID)])
    let detached = canonicalDOMNode(id: "detached")
    _ = try reducer.apply(scope: fixture.scope, event: .detachedRoot(detached))
    _ = try reducer.apply(scope: fixture.scope, event: .willDestroyDOMNode(DOM.Node.ID("detached")))

    #expect(try reducer.apply(scope: fixture.scope, event: .inspect(DOM.Node.ID("host"))).isEmpty)
    #expect(
        try reducer.apply(
            scope: fixture.scope,
            event: .unknown(RawEvent(method: "DOM.future"))
        ).isEmpty)
    #expect(reducer.performanceCounters.fullGraphBuildCount == 1)
    #expect(reducer.performanceCounters.unrelatedRecordScanCount == 0)
}

@Test
func canonicalDOMMatchesWebKitCountAndFirstInsertionSemantics() throws {
    let fixture = canonicalDOMReducerFixture()
    var reducer = fixture.reducer
    let unrequestedParent = canonicalDOMNode(id: "unrequested", childCount: 0)
    let loadedParent = canonicalDOMNode(
        id: "loaded",
        children: [canonicalDOMNode(id: "existing")]
    )
    let root = canonicalDOMNode(
        id: "document",
        type: 9,
        name: "#document",
        children: [unrequestedParent, loadedParent]
    )
    _ = try reducer.bootstrap(scope: fixture.scope, root: root)
    let documentScope = try canonicalDocumentScope(fixture, eventScope: fixture.scope)
    let unrequestedID = canonicalDOMID("unrequested", scope: documentScope)
    let loadedID = canonicalDOMID("loaded", scope: documentScope)
    let existingID = canonicalDOMID("existing", scope: documentScope)
    let insertedID = canonicalDOMID("inserted", scope: documentScope)
    let whitespaceID = canonicalDOMID("whitespace", scope: documentScope)

    let insertion = try reducer.apply(
        scope: fixture.scope,
        event: .childNodeInserted(
            parent: DOM.Node.ID("unrequested"),
            previous: nil,
            node: canonicalDOMNode(
                id: "inserted",
                childCount: 0,
                children: [
                    canonicalDOMNode(
                        id: "whitespace",
                        type: 3,
                        name: "#text",
                        localName: "",
                        value: "\n    "
                    )
                ]
            )
        )
    )
    #expect(insertion.insertedRecords.map(\.id) == [insertedID, whitespaceID])
    #expect(reducer.record(for: unrequestedID)?.children == .loaded([insertedID]))
    #expect(reducer.record(for: insertedID)?.children == .loaded([whitespaceID]))

    let countOnly = try reducer.apply(
        scope: fixture.scope,
        event: .childNodeCountUpdated(DOM.Node.ID("loaded"), count: 99)
    )
    #expect(countOnly.isEmpty)
    #expect(reducer.record(for: loadedID)?.children == .loaded([existingID]))
}

@Test
func canonicalDOMRejectsInvalidDeltaWithStrongGuarantee() throws {
    let fixture = canonicalDOMReducerFixture()
    var reducer = fixture.reducer
    let parent = canonicalDOMNode(id: "parent", children: [canonicalDOMNode(id: "child")])
    let root = canonicalDOMNode(
        id: "document",
        type: 9,
        name: "#document",
        children: [parent]
    )
    _ = try reducer.bootstrap(scope: fixture.scope, root: root)
    let before = reducer.snapshot()
    let counters = reducer.performanceCounters

    #expect(throws: (any Error).self) {
        try reducer.apply(
            scope: fixture.scope,
            event: .childNodeInserted(
                parent: DOM.Node.ID("parent"),
                previous: DOM.Node.ID("missing"),
                node: canonicalDOMNode(id: "never-inserted")
            )
        )
    }
    #expect(reducer.snapshot() == before)
    #expect(reducer.performanceCounters.incrementalNodeVisitCount == counters.incrementalNodeVisitCount)

    _ = try reducer.apply(
        scope: fixture.scope,
        event: .childNodeRemoved(parent: DOM.Node.ID("parent"), node: DOM.Node.ID("child"))
    )
    #expect(throws: WebInspectorCanonicalDOMError.documentUpdatedRequiresInvalidationBoundary) {
        try reducer.apply(scope: fixture.scope, event: .documentUpdated)
    }
}

@Test
func canonicalDOMRematerializesAChildIdentityPreservedAcrossFrameOwnerReplacement() throws {
    let fixture = canonicalDOMReducerFixture()
    var reducer = fixture.reducer
    _ = try reducer.bootstrap(
        scope: fixture.scope,
        root: canonicalDOMNode(
            id: "document",
            type: 9,
            name: "#document",
            children: [
                canonicalDOMNode(
                    id: "parent",
                    children: [
                        canonicalDOMNode(
                            id: "old-frame-owner",
                            children: [
                                canonicalDOMNode(
                                    id: "preserved-whitespace",
                                    type: 3,
                                    name: "#text",
                                    value: "\n    "
                                )
                            ]
                        )
                    ]
                )
            ]
        )
    )
    let documentScope = try canonicalDocumentScope(fixture, eventScope: fixture.scope)
    let oldOwnerID = canonicalDOMID("old-frame-owner", scope: documentScope)
    let newOwnerID = canonicalDOMID("new-frame-owner", scope: documentScope)
    let preservedID = canonicalDOMID("preserved-whitespace", scope: documentScope)
    let preservedOrdinal = try #require(reducer.record(for: preservedID)).insertionOrdinal

    let removal = try reducer.apply(
        scope: fixture.scope,
        event: .childNodeRemoved(
            parent: DOM.Node.ID("parent"),
            node: DOM.Node.ID("old-frame-owner")
        )
    )
    #expect(removal.deletedRecordIDs == [oldOwnerID, preservedID])

    let insertion = try reducer.apply(
        scope: fixture.scope,
        event: .childNodeInserted(
            parent: DOM.Node.ID("parent"),
            previous: nil,
            node: canonicalDOMNode(
                id: "new-frame-owner",
                children: [
                    canonicalDOMNode(
                        id: "preserved-whitespace",
                        type: 3,
                        name: "#text",
                        value: "\n    "
                    )
                ]
            )
        )
    )

    #expect(insertion.insertedRecords.map(\.id) == [newOwnerID, preservedID])
    #expect(reducer.parent(of: preservedID) == newOwnerID)
    #expect(reducer.record(for: preservedID)?.nodeValue == "\n    ")
    #expect(reducer.record(for: preservedID)?.insertionOrdinal == preservedOrdinal)
}

@Test
func canonicalDOMSetChildNodesReplacesOnlyTheMaterializedChildSubtrees() throws {
    let fixture = canonicalDOMReducerFixture()
    var reducer = fixture.reducer
    let parent = canonicalDOMNode(
        id: "parent",
        children: [
            canonicalDOMNode(
                id: "retained",
                attributes: [DOM.Attribute(name: "class", value: "before")]
            ),
            canonicalDOMNode(id: "removed"),
        ])
    _ = try reducer.bootstrap(
        scope: fixture.scope,
        root: canonicalDOMNode(
            id: "document",
            type: 9,
            name: "#document",
            children: [parent]
        )
    )
    let documentScope = try canonicalDocumentScope(fixture, eventScope: fixture.scope)
    let retainedID = canonicalDOMID("retained", scope: documentScope)
    let removedID = canonicalDOMID("removed", scope: documentScope)
    let addedID = canonicalDOMID("added", scope: documentScope)
    let rootID = canonicalDOMID("document", scope: documentScope)
    let retainedOrdinal = try #require(reducer.record(for: retainedID)).insertionOrdinal
    let before = reducer.performanceCounters

    let transaction = try reducer.apply(
        scope: fixture.scope,
        event: .setChildNodes(
            parent: DOM.Node.ID("parent"),
            nodes: [
                canonicalDOMNode(
                    id: "retained",
                    attributes: [DOM.Attribute(name: "class", value: "after")]
                ),
                canonicalDOMNode(id: "added"),
            ])
    )

    #expect(transaction.deletedRecordIDs == [removedID])
    #expect(transaction.insertedRecords.map(\.id) == [addedID])
    #expect(transaction.recordPatches.contains { $0.id == retainedID })
    #expect(transaction.deletedRecordIDs.contains(rootID) == false)
    #expect(reducer.record(for: retainedID)?.queryValue.attributes == ["class": "after"])
    #expect(reducer.record(for: retainedID)?.insertionOrdinal == retainedOrdinal)
    #expect(reducer.record(for: removedID) == nil)
    #expect(reducer.record(for: addedID) != nil)
    #expect(reducer.performanceCounters.fullGraphBuildCount == before.fullGraphBuildCount)
    #expect(reducer.performanceCounters.unrelatedRecordScanCount == 0)
}

@Test
func canonicalDOMDocumentInvalidationRetiresExactScopeAndAllowsRawIDInNextEpoch() throws {
    let fixture = canonicalDOMReducerFixture()
    var reducer = fixture.reducer
    _ = try reducer.bootstrap(
        scope: fixture.scope,
        root: canonicalDOMNode(id: "document", type: 9, name: "#document")
    )
    let oldScope = try canonicalDocumentScope(fixture, eventScope: fixture.scope)
    let oldID = canonicalDOMID("document", scope: oldScope)
    let replacementModelScope = canonicalDOMScope(domEpoch: 2)
    let invalidation = try reducer.invalidateDocument(replacementModelScope)
    #expect(invalidation.deletedRecordIDs == [oldID])
    #expect(reducer.record(for: oldID) == nil)
    #expect(throws: (any Error).self) {
        try reducer.apply(
            scope: fixture.scope,
            event: .inspect(DOM.Node.ID("document"))
        )
    }

    _ = try reducer.bootstrap(
        scope: replacementModelScope,
        root: canonicalDOMNode(id: "document", type: 9, name: "#document")
    )
    let newScope = try canonicalDocumentScope(fixture, eventScope: replacementModelScope)
    let newID = canonicalDOMID("document", scope: newScope)
    #expect(newID != oldID)
    #expect(reducer.record(for: newID) != nil)

    let invalidJump = canonicalDOMScope(domEpoch: 4)
    let before = reducer.snapshot()
    #expect(throws: (any Error).self) {
        try reducer.invalidateDocument(invalidJump)
    }
    #expect(reducer.snapshot() == before)
}

@Test
func canonicalDOMInsertionOrdinalSurvivesDeletionAndMatchesLateSnapshot() throws {
    let fixture = canonicalDOMReducerFixture()
    var reducer = fixture.reducer
    _ = try reducer.bootstrap(
        scope: fixture.scope,
        root: canonicalDOMNode(
            id: "document",
            type: 9,
            name: "#document",
            children: [canonicalDOMNode(id: "existing")]
        )
    )
    let documentScope = try canonicalDocumentScope(fixture, eventScope: fixture.scope)
    let firstID = canonicalDOMID("first", scope: documentScope)
    let secondID = canonicalDOMID("second", scope: documentScope)

    let firstInsertion = try reducer.apply(
        scope: fixture.scope,
        event: .childNodeInserted(
            parent: DOM.Node.ID("document"),
            previous: DOM.Node.ID("existing"),
            node: canonicalDOMNode(id: "first")
        )
    )
    let firstOrdinal = try #require(firstInsertion.insertedRecords.first?.insertionOrdinal)
    _ = try reducer.apply(
        scope: fixture.scope,
        event: .childNodeRemoved(
            parent: DOM.Node.ID("document"),
            node: DOM.Node.ID("first")
        )
    )
    let secondInsertion = try reducer.apply(
        scope: fixture.scope,
        event: .childNodeInserted(
            parent: DOM.Node.ID("document"),
            previous: DOM.Node.ID("existing"),
            node: canonicalDOMNode(id: "second")
        )
    )
    let secondRecord = try #require(secondInsertion.insertedRecords.first)

    #expect(firstInsertion.insertedRecords.map(\.id) == [firstID])
    #expect(secondRecord.id == secondID)
    #expect(secondRecord.insertionOrdinal > firstOrdinal)
    #expect(reducer.record(for: firstID) == nil)
    #expect(
        reducer.snapshot().records.first(where: { $0.id == secondID })?.insertionOrdinal
            == secondRecord.insertionOrdinal
    )

    let replacementScope = canonicalDOMScope(domEpoch: 2)
    _ = try reducer.invalidateDocument(replacementScope)
    let replacement = try reducer.bootstrap(
        scope: replacementScope,
        root: canonicalDOMNode(id: "document", type: 9, name: "#document")
    )
    #expect(
        try #require(replacement.insertedRecords.first).insertionOrdinal
            > secondRecord.insertionOrdinal
    )
}

@Test
func canonicalDOMInsertionOrdinalOverflowHasStrongExceptionGuarantee() throws {
    let fixture = canonicalDOMReducerFixture()
    var reducer = fixture.reducer
    reducer.setLastInsertionOrdinalForTesting(UInt64.max - 1)
    let before = reducer.snapshot()
    let countersBefore = reducer.performanceCounters

    #expect(throws: WebInspectorCanonicalDOMError.insertionOrdinalExhausted) {
        try reducer.bootstrap(
            scope: fixture.scope,
            root: canonicalDOMNode(
                id: "document",
                type: 9,
                name: "#document",
                children: [canonicalDOMNode(id: "child")]
            )
        )
    }
    #expect(reducer.snapshot() == before)
    #expect(
        reducer.performanceCounters.fullSnapshotBuildCount
            == countersBefore.fullSnapshotBuildCount + 1
    )
    #expect(
        reducer.performanceCounters.fullGraphBuildCount
            == countersBefore.fullGraphBuildCount
    )
    #expect(
        reducer.performanceCounters.fullGraphNodeVisitCount
            == countersBefore.fullGraphNodeVisitCount
    )
    #expect(
        reducer.performanceCounters.incrementalNodeVisitCount
            == countersBefore.incrementalNodeVisitCount
    )
    #expect(
        reducer.performanceCounters.recordMutationCount
            == countersBefore.recordMutationCount
    )

    let committed = try reducer.bootstrap(
        scope: fixture.scope,
        root: canonicalDOMNode(id: "document", type: 9, name: "#document")
    )
    #expect(committed.insertedRecords.map(\.insertionOrdinal) == [UInt64.max])
}

@Test
func canonicalDOMLinksFrameOwnerAndFrameRootIncrementallyInEitherArrivalOrder() throws {
    let frameID = FrameID("child-frame")
    let pageScope = canonicalDOMScope(targetID: "page", kind: .page)
    let frameScope = canonicalDOMScope(
        targetID: "frame-target",
        kind: .frame,
        frameID: frameID
    )
    let fixture = canonicalDOMReducerFixture(scope: pageScope)
    let pageDocumentScope = try canonicalDocumentScope(fixture, eventScope: pageScope)
    let frameDocumentScope = try canonicalDocumentScope(fixture, eventScope: frameScope)
    let ownerID = canonicalDOMID("iframe", scope: pageDocumentScope)
    let embeddedDocumentID = canonicalDOMID("embedded-document", scope: pageDocumentScope)
    let embeddedChildID = canonicalDOMID("embedded-child", scope: pageDocumentScope)
    let frameRootID = canonicalDOMID("frame-document", scope: frameDocumentScope)
    let pageRoot = canonicalDOMNode(
        id: "page-document",
        type: 9,
        name: "#document",
        children: [
            canonicalDOMNode(
                id: "iframe",
                name: "IFRAME",
                localName: "iframe",
                frameID: frameID,
                contentDocument: canonicalDOMNode(
                    id: "embedded-document",
                    type: 9,
                    name: "#document",
                    frameID: frameID,
                    children: [canonicalDOMNode(id: "embedded-child")]
                )
            )
        ]
    )
    let frameRoot = canonicalDOMNode(
        id: "frame-document",
        type: 9,
        name: "#document",
        frameID: frameID
    )

    var ownerFirst = fixture.reducer
    _ = try ownerFirst.bootstrap(scope: pageScope, root: pageRoot)
    #expect(ownerFirst.record(for: embeddedDocumentID) != nil)
    let frameTransaction = try ownerFirst.bootstrap(scope: frameScope, root: frameRoot)
    #expect(ownerFirst.record(for: ownerID)?.contentDocumentID == frameRootID)
    #expect(ownerFirst.parent(of: frameRootID) == ownerID)
    #expect(ownerFirst.record(for: embeddedDocumentID) == nil)
    #expect(ownerFirst.record(for: embeddedChildID) == nil)
    #expect(frameTransaction.deletedRecordIDs == [embeddedDocumentID, embeddedChildID])
    #expect(frameTransaction.queryValueUpserts[ownerID] == nil)
    #expect(
        frameTransaction.parentChanges.contains(
            WebInspectorCanonicalDOMParentChange(nodeID: frameRootID, parentID: ownerID)
        ))
    _ = try ownerFirst.targetLost(scope: frameScope)
    #expect(ownerFirst.record(for: ownerID)?.contentDocumentID == nil)

    var rootFirst = fixture.reducer
    _ = try rootFirst.bootstrap(scope: frameScope, root: frameRoot)
    let pageTransaction = try rootFirst.bootstrap(scope: pageScope, root: pageRoot)
    #expect(rootFirst.record(for: ownerID)?.contentDocumentID == frameRootID)
    #expect(rootFirst.parent(of: frameRootID) == ownerID)
    #expect(rootFirst.record(for: embeddedDocumentID) == nil)
    #expect(rootFirst.record(for: embeddedChildID) == nil)
    #expect(pageTransaction.insertedRecords.contains { $0.id == embeddedDocumentID } == false)
    #expect(pageTransaction.insertedRecords.contains { $0.id == embeddedChildID } == false)
    let ownerLoss = try rootFirst.targetLost(scope: pageScope)
    #expect(rootFirst.parent(of: frameRootID) == nil)
    #expect(
        ownerLoss.parentChanges == [
            WebInspectorCanonicalDOMParentChange(nodeID: frameRootID, parentID: nil)
        ])
}

@Test
func canonicalDOMPrimaryTreeLinksFrameSubtreeInEitherArrivalOrder() throws {
    let frameID = FrameID("child-frame")
    let pageScope = canonicalDOMScope(targetID: "page", kind: .page)
    let frameScope = canonicalDOMScope(
        targetID: "frame-target",
        kind: .frame,
        frameID: frameID
    )
    let fixture = canonicalDOMReducerFixture(scope: pageScope)
    let pageDocumentScope = try canonicalDocumentScope(
        fixture,
        eventScope: pageScope
    )
    let frameDocumentScope = try canonicalDocumentScope(
        fixture,
        eventScope: frameScope
    )
    let pageRootID = canonicalDOMID("page-document", scope: pageDocumentScope)
    let ownerID = canonicalDOMID("iframe", scope: pageDocumentScope)
    let embeddedDocumentID = canonicalDOMID(
        "embedded-frame-document",
        scope: pageDocumentScope
    )
    let frameRootID = canonicalDOMID(
        "frame-document",
        scope: frameDocumentScope
    )
    let frameChildID = canonicalDOMID("frame-child", scope: frameDocumentScope)
    let pageRoot = canonicalDOMNode(
        id: "page-document",
        type: 9,
        name: "#document",
        children: [
            canonicalDOMNode(
                id: "iframe",
                name: "IFRAME",
                localName: "iframe",
                frameID: FrameID("main-frame"),
                contentDocument: canonicalDOMNode(
                    id: "embedded-frame-document",
                    type: 9,
                    name: "#document",
                    frameID: frameID
                )
            )
        ]
    )
    let frameRoot = canonicalDOMNode(
        id: "frame-document",
        type: 9,
        name: "#document",
        frameID: frameID,
        children: [canonicalDOMNode(id: "frame-child")]
    )

    var ownerFirst = fixture.reducer
    var pageBootstrap = try ownerFirst.bootstrap(
        scope: pageScope,
        root: pageRoot
    )
    ownerFirst.reconcilePrimaryTree(
        rootID: pageRootID,
        transaction: &pageBootstrap
    )
    #expect(
        Set(pageBootstrap.tree.upsertedRows.map(\.id))
            == [pageRootID, ownerID, embeddedDocumentID]
    )
    #expect(
        pageBootstrap.tree.upsertedRows.first(where: { $0.id == ownerID })?
            .parentID == pageRootID
    )
    var lateFrame = try ownerFirst.bootstrap(
        scope: frameScope,
        root: frameRoot
    )
    let beforeLateFrame = ownerFirst.performanceCounters
    ownerFirst.reconcilePrimaryTree(
        rootID: pageRootID,
        transaction: &lateFrame
    )
    #expect(lateFrame.tree.upsertedRows.map(\.id).contains(frameRootID))
    #expect(lateFrame.tree.upsertedRows.map(\.id).contains(frameChildID))
    #expect(
        Set(ownerFirst.snapshot().tree.rows.map(\.id)) == [
            pageRootID, ownerID, frameRootID, frameChildID,
        ])
    #expect(
        ownerFirst.performanceCounters.treeProjectionUnrelatedRecordScanCount
            == 0
    )
    #expect(
        ownerFirst.performanceCounters.treeProjectionNodeVisitCount
            - beforeLateFrame.treeProjectionNodeVisitCount
            == 2
    )

    var frameFirst = fixture.reducer
    var earlyFrame = try frameFirst.bootstrap(
        scope: frameScope,
        root: frameRoot
    )
    frameFirst.reconcilePrimaryTree(rootID: nil, transaction: &earlyFrame)
    #expect(earlyFrame.tree.isEmpty)
    #expect(frameFirst.snapshot().tree.rows.isEmpty)
    var lateOwner = try frameFirst.bootstrap(
        scope: pageScope,
        root: pageRoot
    )
    frameFirst.reconcilePrimaryTree(
        rootID: pageRootID,
        transaction: &lateOwner
    )
    #expect(lateOwner.tree.primaryRootChange?.rootID == pageRootID)
    #expect(
        Set(frameFirst.snapshot().tree.rows.map(\.id)) == [
            pageRootID, ownerID, frameRootID, frameChildID,
        ])
    #expect(
        frameFirst.snapshot().tree.rows.first(where: {
            $0.id == frameRootID
        })?.parentID == ownerID
    )
}

@Test
func canonicalDOMRawNodeLookupRequiresTheExactActiveDocumentScope() throws {
    let fixture = canonicalDOMReducerFixture()
    var reducer = fixture.reducer
    _ = try reducer.bootstrap(
        scope: fixture.scope,
        root: canonicalDOMNode(
            id: "document",
            type: 9,
            name: "#document",
            children: [canonicalDOMNode(id: "target")]
        )
    )
    let expected = canonicalDOMID(
        "target",
        scope: try canonicalDocumentScope(
            fixture,
            eventScope: fixture.scope
        )
    )
    #expect(
        try reducer.nodeID(
            for: DOM.Node.ID("target"),
            in: fixture.scope
        ) == expected
    )
    #expect(
        try reducer.nodeID(
            for: DOM.Node.ID("missing"),
            in: fixture.scope
        ) == nil
    )
    #expect(throws: WebInspectorCanonicalDOMError.self) {
        try reducer.nodeID(
            for: DOM.Node.ID("target"),
            in: canonicalDOMScope(domEpoch: 2)
        )
    }
}

@Test
func canonicalDOMRejectsAmbiguousFrameOwnershipBeforeCommittingAnyNode() throws {
    let frameID = FrameID("shared-frame")
    let pageScope = canonicalDOMScope(targetID: "page")
    let fixture = canonicalDOMReducerFixture(scope: pageScope)
    var reducer = fixture.reducer
    let sharedContainingFramePage = canonicalDOMNode(
        id: "document",
        type: 9,
        name: "#document",
        children: [
            canonicalDOMNode(
                id: "first-owner",
                name: "IFRAME",
                localName: "iframe",
                frameID: frameID
            ),
            canonicalDOMNode(
                id: "second-owner",
                name: "IFRAME",
                localName: "iframe",
                frameID: frameID
            ),
        ]
    )
    _ = try reducer.bootstrap(scope: pageScope, root: sharedContainingFramePage)
    #expect(reducer.snapshot().records.count == 3)

    reducer = fixture.reducer
    let before = reducer.snapshot()
    let ambiguousPage = canonicalDOMNode(
        id: "document",
        type: 9,
        name: "#document",
        children: [
            canonicalDOMNode(
                id: "first-owner",
                name: "IFRAME",
                localName: "iframe",
                frameID: FrameID("main-frame"),
                contentDocument: canonicalDOMNode(
                    id: "first-content-document",
                    type: 9,
                    name: "#document",
                    frameID: frameID
                )
            ),
            canonicalDOMNode(
                id: "second-owner",
                name: "IFRAME",
                localName: "iframe",
                frameID: FrameID("main-frame"),
                contentDocument: canonicalDOMNode(
                    id: "second-content-document",
                    type: 9,
                    name: "#document",
                    frameID: frameID
                )
            ),
        ]
    )
    #expect(throws: WebInspectorCanonicalDOMError.ambiguousFrameOwner(frameID)) {
        try reducer.bootstrap(scope: pageScope, root: ambiguousPage)
    }
    #expect(reducer.snapshot() == before)

    let frameScopeA = canonicalDOMScope(
        targetID: "frame-a",
        kind: .frame,
        frameID: frameID
    )
    let frameScopeB = canonicalDOMScope(
        targetID: "frame-b",
        kind: .frame,
        frameID: frameID
    )
    _ = try reducer.bootstrap(
        scope: frameScopeA,
        root: canonicalDOMNode(
            id: "frame-a-root",
            type: 9,
            name: "#document",
            frameID: frameID
        )
    )
    let afterFirstFrame = reducer.snapshot()
    #expect(throws: WebInspectorCanonicalDOMError.ambiguousFrameRoot(frameID)) {
        try reducer.bootstrap(
            scope: frameScopeB,
            root: canonicalDOMNode(
                id: "frame-b-root",
                type: 9,
                name: "#document",
                frameID: frameID
            )
        )
    }
    #expect(reducer.snapshot() == afterFirstFrame)
}

@Test
func canonicalDOMIncrementalFrameOwnerSuppressesEmbeddedDocumentWhenExternalRootExists() throws {
    let frameID = FrameID("incremental-frame")
    let pageScope = canonicalDOMScope(targetID: "page")
    let frameScope = canonicalDOMScope(
        targetID: "frame-target",
        kind: .frame,
        frameID: frameID
    )
    let fixture = canonicalDOMReducerFixture(scope: pageScope)
    var reducer = fixture.reducer
    _ = try reducer.bootstrap(
        scope: frameScope,
        root: canonicalDOMNode(
            id: "frame-document",
            type: 9,
            name: "#document",
            frameID: frameID
        )
    )
    _ = try reducer.bootstrap(
        scope: pageScope,
        root: canonicalDOMNode(
            id: "page-document",
            type: 9,
            name: "#document",
            children: [canonicalDOMNode(id: "container", children: [])]
        )
    )
    let transaction = try reducer.apply(
        scope: pageScope,
        event: .childNodeInserted(
            parent: DOM.Node.ID("container"),
            previous: nil,
            node: canonicalDOMNode(
                id: "iframe",
                name: "IFRAME",
                localName: "iframe",
                frameID: frameID,
                contentDocument: canonicalDOMNode(
                    id: "embedded-document",
                    type: 9,
                    name: "#document",
                    frameID: frameID,
                    children: [canonicalDOMNode(id: "embedded-child")]
                )
            )
        )
    )
    let pageDocumentScope = try canonicalDocumentScope(fixture, eventScope: pageScope)
    let frameDocumentScope = try canonicalDocumentScope(fixture, eventScope: frameScope)
    let ownerID = canonicalDOMID("iframe", scope: pageDocumentScope)
    let frameRootID = canonicalDOMID("frame-document", scope: frameDocumentScope)
    let embeddedDocumentID = canonicalDOMID("embedded-document", scope: pageDocumentScope)
    let embeddedChildID = canonicalDOMID("embedded-child", scope: pageDocumentScope)

    #expect(transaction.insertedRecords.map(\.id) == [ownerID])
    #expect(reducer.record(for: embeddedDocumentID) == nil)
    #expect(reducer.record(for: embeddedChildID) == nil)
    #expect(reducer.record(for: ownerID)?.contentDocumentID == frameRootID)
    #expect(reducer.parent(of: frameRootID) == ownerID)
}

@Test
func canonicalDOMPseudoAdditionAtomicallyReplacesExistingSlotOrIdentity() throws {
    let fixture = canonicalDOMReducerFixture()
    var reducer = fixture.reducer
    _ = try reducer.bootstrap(
        scope: fixture.scope,
        root: canonicalDOMNode(
            id: "document",
            type: 9,
            name: "#document",
            children: [canonicalDOMNode(id: "host")]
        )
    )
    let documentScope = try canonicalDocumentScope(fixture, eventScope: fixture.scope)
    let hostID = canonicalDOMID("host", scope: documentScope)
    let firstID = canonicalDOMID("before", scope: documentScope)
    let replacementID = canonicalDOMID("replacement-before", scope: documentScope)

    _ = try reducer.apply(
        scope: fixture.scope,
        event: .pseudoElementAdded(
            parent: DOM.Node.ID("host"),
            element: canonicalDOMNode(id: "before", pseudoType: .before)
        )
    )
    let sameIdentityUpdate = try reducer.apply(
        scope: fixture.scope,
        event: .pseudoElementAdded(
            parent: DOM.Node.ID("host"),
            element: canonicalDOMNode(
                id: "before",
                attributes: [DOM.Attribute(name: "data-state", value: "updated")],
                pseudoType: .before
            )
        )
    )
    #expect(sameIdentityUpdate.insertedRecords.isEmpty)
    #expect(sameIdentityUpdate.deletedRecordIDs.isEmpty)
    #expect(sameIdentityUpdate.recordPatches.contains { $0.id == firstID })
    #expect(reducer.record(for: firstID)?.queryValue.attributes == ["data-state": "updated"])

    let identityReplacement = try reducer.apply(
        scope: fixture.scope,
        event: .pseudoElementAdded(
            parent: DOM.Node.ID("host"),
            element: canonicalDOMNode(id: "replacement-before", pseudoType: .before)
        )
    )
    #expect(identityReplacement.deletedRecordIDs == [firstID])
    #expect(identityReplacement.insertedRecords.map(\.id) == [replacementID])
    #expect(reducer.record(for: hostID)?.beforePseudoElementID == replacementID)
    #expect(reducer.record(for: firstID) == nil)
    #expect(reducer.record(for: replacementID) != nil)
}

@Test
func canonicalDOMNormalMutationVisitsOnlyChangedRecordInLargeGraph() throws {
    let fixture = canonicalDOMReducerFixture()
    var reducer = fixture.reducer
    let children = (0..<10_000).map { index in
        canonicalDOMNode(id: "node-\(index)")
    }
    var bootstrap = try reducer.bootstrap(
        scope: fixture.scope,
        root: canonicalDOMNode(
            id: "document",
            type: 9,
            name: "#document",
            children: children
        )
    )
    let documentScope = try canonicalDocumentScope(fixture, eventScope: fixture.scope)
    let rootID = canonicalDOMID("document", scope: documentScope)
    reducer.reconcilePrimaryTree(
        rootID: rootID,
        transaction: &bootstrap
    )
    let changedID = canonicalDOMID("node-997", scope: documentScope)
    let insertionOrdinal = try #require(reducer.record(for: changedID)).insertionOrdinal
    let before = reducer.performanceCounters
    var transaction = try reducer.apply(
        scope: fixture.scope,
        event: .attributeModified(DOM.Node.ID("node-997"), name: "data-state", value: "changed")
    )
    reducer.reconcilePrimaryTree(
        rootID: rootID,
        transaction: &transaction
    )
    let after = reducer.performanceCounters

    #expect(after.fullGraphBuildCount == before.fullGraphBuildCount)
    #expect(after.fullGraphNodeVisitCount == before.fullGraphNodeVisitCount)
    #expect(after.incrementalNodeVisitCount - before.incrementalNodeVisitCount == 1)
    #expect(after.recordMutationCount - before.recordMutationCount == 1)
    #expect(after.unrelatedRecordScanCount == 0)
    #expect(after.treeProjectionNodeVisitCount == before.treeProjectionNodeVisitCount)
    #expect(after.treeProjectionUnrelatedRecordScanCount == 0)
    #expect(transaction.tree.upsertedRows.map(\.id) == [changedID])
    #expect(reducer.record(for: changedID)?.insertionOrdinal == insertionOrdinal)
}

@Test
func canonicalDOMResetPublishesOneFullMembershipClear() throws {
    let fixture = canonicalDOMReducerFixture()
    var reducer = fixture.reducer
    _ = try reducer.bootstrap(
        scope: fixture.scope,
        root: canonicalDOMNode(
            id: "document",
            type: 9,
            name: "#document",
            children: [canonicalDOMNode(id: "child")]
        )
    )
    let documentScope = try canonicalDocumentScope(fixture, eventScope: fixture.scope)
    let reset = reducer.reset()

    #expect(reset.deletedRecordIDs.count == 2)
    #expect(reset.queryValueDeletes == reset.deletedRecordIDs)
    #expect(
        reset.rootChanges == [
            WebInspectorCanonicalDOMRootChange(scope: documentScope, rootID: nil)
        ])
    #expect(reset.resourceInvalidations == [.target(documentScope)])
    #expect(reducer.snapshot().recordsByID.isEmpty)
}

private struct CanonicalDOMReducerFixture {
    let storeID: WebInspectorContainerStoreID
    let attachmentGeneration: WebInspectorAttachmentGeneration
    let scope: WebInspectorCanonicalDOMEventScope
    let reducer: WebInspectorCanonicalDOMReducer
}

private func canonicalDOMReducerFixture(
    scope: WebInspectorCanonicalDOMEventScope = canonicalDOMScope()
) -> CanonicalDOMReducerFixture {
    let storeID = WebInspectorContainerStoreID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    )
    let attachmentGeneration = WebInspectorAttachmentGeneration(rawValue: 3)
    return CanonicalDOMReducerFixture(
        storeID: storeID,
        attachmentGeneration: attachmentGeneration,
        scope: scope,
        reducer: WebInspectorCanonicalDOMReducer(
            storeID: storeID,
            attachmentGeneration: attachmentGeneration
        )
    )
}

private func canonicalDOMScope(
    generation: UInt64 = 1,
    targetID: String = "page",
    agentTargetID: String = "agent",
    kind: WebInspectorFeatureTarget.Kind = .page,
    frameID: FrameID? = nil,
    domEpoch: UInt64 = 1
) -> WebInspectorCanonicalDOMEventScope {
    let modelScope = WebInspectorFeatureEventScope(
        generation: WebInspectorPageGeneration(rawValue: generation),
        semanticTarget: WebInspectorFeatureTarget(
            id: WebInspectorTarget.ID(targetID),
            kind: kind,
            frameID: frameID
        ),
        agentTarget: WebInspectorFeatureTarget(
            id: WebInspectorTarget.ID(agentTargetID),
            kind: kind,
            frameID: frameID
        )
    )
    return WebInspectorCanonicalDOMEventScope(
        modelScope: modelScope,
        bindingScopeID: WebInspectorDOMBindingScopeID(rawValue: domEpoch)
    )
}

private func canonicalDocumentScope(
    _ fixture: CanonicalDOMReducerFixture,
    eventScope: WebInspectorCanonicalDOMEventScope
) throws -> WebInspectorDOMDocumentScopeStorage {
    WebInspectorDOMDocumentScopeStorage(
        storeID: fixture.storeID,
        attachmentGeneration: fixture.attachmentGeneration,
        eventScope: eventScope
    )
}

private func canonicalDOMID(
    _ rawValue: String,
    scope: WebInspectorDOMDocumentScopeStorage
) -> WebInspectorDOMNodeIdentityStorage {
    WebInspectorDOMNodeIdentityStorage(
        documentScope: scope,
        rawNodeID: DOM.Node.ID(rawValue)
    )
}

private func canonicalDOMNode(
    id: String,
    type: Int = 1,
    name: String = "DIV",
    localName: String = "div",
    value: String = "",
    frameID: FrameID? = nil,
    documentURL: String? = nil,
    baseURL: String? = nil,
    attributes: [DOM.Attribute] = [],
    childCount: Int? = nil,
    children: [DOM.Node]? = nil,
    contentDocument: DOM.Node? = nil,
    shadowRoots: [DOM.Node] = [],
    templateContent: DOM.Node? = nil,
    beforePseudoElement: DOM.Node? = nil,
    otherPseudoElements: [DOM.Node] = [],
    afterPseudoElement: DOM.Node? = nil,
    pseudoType: DOM.PseudoType? = nil,
    shadowRootType: DOM.ShadowRootType? = nil
) -> DOM.Node {
    DOM.Node(
        id: DOM.Node.ID(id),
        nodeType: type,
        nodeName: name,
        localName: localName,
        nodeValue: value,
        frameID: frameID,
        documentURL: documentURL,
        baseURL: baseURL,
        attributes: Dictionary(uniqueKeysWithValues: attributes.map { ($0.name, $0.value) }),
        attributeList: attributes,
        childNodeCount: childCount ?? children?.count ?? 0,
        children: children,
        contentDocument: contentDocument,
        shadowRoots: shadowRoots,
        templateContent: templateContent,
        beforePseudoElement: beforePseudoElement,
        otherPseudoElements: otherPseudoElements,
        afterPseudoElement: afterPseudoElement,
        pseudoType: pseudoType,
        shadowRootType: shadowRootType
    )
}
