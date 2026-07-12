import Foundation
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@Test
func canonicalCSSBootstrapDiffsAuthoritativeMembershipAndTombstonesRemovals() throws {
    let fixture = canonicalCSSReducerFixture()
    var reducer = fixture.reducer
    let first = canonicalCSSModelStyleSheet(id: "first", scope: fixture.scope, title: "before")
    let removed = canonicalCSSModelStyleSheet(id: "removed", scope: fixture.scope)

    let initial = try reducer.bootstrap(scopes: [fixture.scope], styleSheets: [first, removed])
    #expect(initial.insertedRecords.count == 2)
    #expect(initial.updatedRecords.isEmpty)
    #expect(initial.cascadeRevisionChanges.map(\.revision) == [1])

    let updated = canonicalCSSModelStyleSheet(id: "first", scope: fixture.scope, title: "after")
    let added = canonicalCSSModelStyleSheet(id: "added", scope: fixture.scope)
    let diff = try reducer.bootstrap(scopes: [fixture.scope], styleSheets: [updated, added])
    let documentScope = try canonicalCSSDocumentScope(fixture, eventScope: fixture.scope)
    let firstID = canonicalCSSID("first", scope: documentScope)
    let removedID = canonicalCSSID("removed", scope: documentScope)
    let addedID = canonicalCSSID("added", scope: documentScope)

    #expect(diff.updatedRecords.map(\.id) == [firstID])
    #expect(diff.insertedRecords.map(\.id) == [addedID])
    #expect(diff.deletedRecordIDs == [removedID])
    #expect(reducer.record(for: firstID)?.title == "after")
    #expect(reducer.cascadeRevision(in: documentScope) == 2)

    let beforeFailure = reducer.snapshot()
    let countersBeforeFailure = reducer.performanceCounters
    #expect(throws: WebInspectorCanonicalCSSError.reusedStyleSheet(removedID)) {
        try reducer.bootstrap(scopes: [fixture.scope], styleSheets: [updated, removed])
    }
    #expect(reducer.snapshot() == beforeFailure)
    #expect(
        reducer.performanceCounters.fullSnapshotHeaderVisitCount == countersBeforeFailure.fullSnapshotHeaderVisitCount)
}

@Test
func canonicalCSSBootstrapRejectsDuplicateOrMalformedHeaderWithStrongGuarantee() throws {
    let fixture = canonicalCSSReducerFixture()
    var reducer = fixture.reducer
    let valid = canonicalCSSModelStyleSheet(id: "valid", scope: fixture.scope)
    _ = try reducer.bootstrap(scopes: [fixture.scope], styleSheets: [valid])
    let before = reducer.snapshot()
    let counters = reducer.performanceCounters

    #expect(throws: WebInspectorCanonicalCSSError.self) {
        try reducer.bootstrap(scopes: [fixture.scope], styleSheets: [valid, valid])
    }
    #expect(reducer.snapshot() == before)
    #expect(reducer.performanceCounters.fullSnapshotHeaderVisitCount == counters.fullSnapshotHeaderVisitCount)

    let invalid = WebInspectorCanonicalCSSStyleSheetSnapshotRecord(
        scope: fixture.scope,
        header: CSS.StyleSheetHeader(
            styleSheetID: CSS.StyleSheet.ID("invalid"),
            origin: CSS.Origin(rawValue: "author"),
            startLine: -1
        )
    )
    #expect(throws: WebInspectorCanonicalCSSError.self) {
        try reducer.bootstrap(scopes: [fixture.scope], styleSheets: [invalid])
    }
    #expect(reducer.snapshot() == before)

    let route = try canonicalCSSDocumentScope(fixture, eventScope: fixture.scope).targetRoute
    #expect(throws: WebInspectorCanonicalCSSError.duplicateBootstrapScope(route)) {
        try reducer.bootstrap(
            scopes: [fixture.scope, fixture.scope],
            styleSheets: [valid]
        )
    }
    let unlistedScope = canonicalCSSScope(targetID: "unlisted")
    #expect(throws: WebInspectorCanonicalCSSError.self) {
        try reducer.bootstrap(
            scopes: [fixture.scope],
            styleSheets: [canonicalCSSModelStyleSheet(id: "unlisted", scope: unlistedScope)]
        )
    }
    #expect(reducer.snapshot() == before)
}

@Test
func canonicalCSSEmptyBootstrapStillEstablishesTargetAuthority() throws {
    let fixture = canonicalCSSReducerFixture()
    var reducer = fixture.reducer
    let documentScope = try canonicalCSSDocumentScope(fixture, eventScope: fixture.scope)

    let bootstrap = try reducer.bootstrap(scopes: [fixture.scope], styleSheets: [])
    #expect(bootstrap.insertedRecords.isEmpty)
    #expect(
        bootstrap.cascadeRevisionChanges == [
            WebInspectorCanonicalCSSCascadeRevisionChange(scope: documentScope, revision: 1)
        ])
    #expect(bootstrap.resourceInvalidations == [.target(documentScope)])

    let nextScope = canonicalCSSScope(domEpoch: 2)
    let invalidation = try reducer.invalidateDocument(nextScope)
    #expect(invalidation.deletedRecordIDs.isEmpty)
    _ = try reducer.targetLost(scope: nextScope)
}

@Test
func canonicalCSSAppliesMembershipCascadeAndNodeInvalidationDeltas() throws {
    let fixture = canonicalCSSReducerFixture()
    var reducer = fixture.reducer
    let header = canonicalCSSHeader(id: "sheet", title: "title")
    let add = try reducer.apply(scope: fixture.scope, event: .styleSheetAdded(header))
    let documentScope = try canonicalCSSDocumentScope(fixture, eventScope: fixture.scope)
    let sheetID = canonicalCSSID("sheet", scope: documentScope)
    let nodeID = WebInspectorDOMNodeIdentityStorage(
        documentScope: documentScope,
        rawNodeID: DOM.Node.ID("node")
    )

    #expect(add.insertedRecords.map(\.id) == [sheetID])
    #expect(add.cascadeRevisionChanges.map(\.revision) == [1])
    let changed = try reducer.apply(
        scope: fixture.scope,
        event: .styleSheetChanged(CSS.StyleSheet.ID("sheet"))
    )
    #expect(changed.cascadeRevisionChanges.map(\.revision) == [2])
    #expect(changed.resourceInvalidations == [.target(documentScope)])
    let media = try reducer.apply(scope: fixture.scope, event: .mediaQueryResultChanged)
    #expect(media.cascadeRevisionChanges.map(\.revision) == [3])
    let layout = try reducer.apply(
        scope: fixture.scope,
        event: .nodeLayoutFlagsChanged(DOM.Node.ID("node"))
    )
    #expect(layout.resourceInvalidations == [.nodes([nodeID])])
    #expect(layout.cascadeRevisionChanges.isEmpty)
    #expect(
        try reducer.apply(
            scope: fixture.scope,
            event: .unknown(RawEvent(domain: "CSS", method: "future"))
        ).isEmpty)

    let removal = try reducer.apply(
        scope: fixture.scope,
        event: .styleSheetRemoved(CSS.StyleSheet.ID("sheet"))
    )
    #expect(removal.deletedRecordIDs == [sheetID])
    #expect(removal.cascadeRevisionChanges.map(\.revision) == [4])
    let stateAfterRemoval = reducer.snapshot()
    #expect(throws: WebInspectorCanonicalCSSError.reusedStyleSheet(sheetID)) {
        try reducer.apply(scope: fixture.scope, event: .styleSheetAdded(header))
    }
    #expect(reducer.snapshot() == stateAfterRemoval)
    #expect(reducer.performanceCounters.unrelatedCollectionScanCount == 0)
}

@Test
func canonicalCSSFailedFirstDeltaDoesNotEstablishOrMutateScope() throws {
    let fixture = canonicalCSSReducerFixture()
    var reducer = fixture.reducer
    let before = reducer.snapshot()
    let counters = reducer.performanceCounters
    let missingID = canonicalCSSID(
        "missing",
        scope: try canonicalCSSDocumentScope(fixture, eventScope: fixture.scope)
    )

    #expect(throws: WebInspectorCanonicalCSSError.missingStyleSheet(missingID)) {
        try reducer.apply(
            scope: fixture.scope,
            event: .styleSheetChanged(CSS.StyleSheet.ID("missing"))
        )
    }
    #expect(reducer.snapshot() == before)
    #expect(reducer.performanceCounters.incrementalLookupCount == counters.incrementalLookupCount)

    let differentEpoch = canonicalCSSScope(domEpoch: 2)
    _ = try reducer.apply(
        scope: differentEpoch,
        event: .styleSheetAdded(canonicalCSSHeader(id: "new"))
    )
    #expect(
        try reducer.record(
            for: canonicalCSSID(
                "new",
                scope: canonicalCSSDocumentScope(fixture, eventScope: differentEpoch)
            )) != nil)
}

@Test
func canonicalCSSIdentitySeparatesTargetsAndDocumentEpochsForSameRawStyleSheetID() throws {
    let pageScope = canonicalCSSScope(targetID: "page")
    let frameScope = canonicalCSSScope(
        targetID: "frame",
        kind: .frame,
        frameID: FrameID("frame")
    )
    let fixture = canonicalCSSReducerFixture(scope: pageScope)
    var reducer = fixture.reducer
    let pageSheet = canonicalCSSModelStyleSheet(id: "7", scope: pageScope)
    let frameSheet = canonicalCSSModelStyleSheet(id: "7", scope: frameScope)
    _ = try reducer.bootstrap(
        scopes: [pageScope, frameScope],
        styleSheets: [pageSheet, frameSheet]
    )
    let pageID = canonicalCSSID(
        "7",
        scope: try canonicalCSSDocumentScope(fixture, eventScope: pageScope)
    )
    let frameID = canonicalCSSID(
        "7",
        scope: try canonicalCSSDocumentScope(fixture, eventScope: frameScope)
    )

    #expect(pageID != frameID)
    #expect(reducer.record(for: pageID) != nil)
    #expect(reducer.record(for: frameID) != nil)

    let nextPageScope = canonicalCSSScope(targetID: "page", domEpoch: 2)
    _ = try reducer.invalidateDocument(nextPageScope)
    let nextPageID = canonicalCSSID(
        "7",
        scope: try canonicalCSSDocumentScope(fixture, eventScope: nextPageScope)
    )
    _ = try reducer.apply(
        scope: nextPageScope,
        event: .styleSheetAdded(canonicalCSSHeader(id: "7"))
    )
    #expect(nextPageID != pageID)
    #expect(reducer.record(for: pageID) == nil)
    #expect(reducer.record(for: nextPageID) != nil)
    #expect(reducer.record(for: frameID) != nil)
}

@Test
func canonicalCSSKeepsSameSemanticStyleSheetDistinctAcrossAllocatingAgents() throws {
    let firstEventScope = canonicalCSSScope(agentTargetID: "agent-a")
    let secondEventScope = canonicalCSSScope(agentTargetID: "agent-b")
    let fixture = canonicalCSSReducerFixture(scope: firstEventScope)
    var reducer = fixture.reducer
    _ = try reducer.bootstrap(
        scopes: [firstEventScope, secondEventScope],
        styleSheets: [
            canonicalCSSModelStyleSheet(id: "7", scope: firstEventScope),
            canonicalCSSModelStyleSheet(id: "7", scope: secondEventScope),
        ]
    )
    let firstScope = try canonicalCSSDocumentScope(fixture, eventScope: firstEventScope)
    let secondScope = try canonicalCSSDocumentScope(fixture, eventScope: secondEventScope)
    let firstID = canonicalCSSID("7", scope: firstScope)
    let secondID = canonicalCSSID("7", scope: secondScope)

    #expect(firstID != secondID)
    #expect(firstID.documentScope.semanticTargetID == secondID.documentScope.semanticTargetID)
    #expect(firstID.documentScope.agentTargetID == WebInspectorTarget.ID("agent-a"))
    #expect(secondID.documentScope.agentTargetID == WebInspectorTarget.ID("agent-b"))
    #expect(reducer.record(for: firstID) != nil)
    #expect(reducer.record(for: secondID) != nil)

    let layout = try reducer.apply(
        scope: secondEventScope,
        event: .nodeLayoutFlagsChanged(DOM.Node.ID("node"))
    )
    #expect(
        layout.resourceInvalidations == [
            .nodes([
                WebInspectorDOMNodeIdentityStorage(
                    documentScope: secondScope,
                    rawNodeID: DOM.Node.ID("node")
                )
            ])
        ])
}

@Test
func canonicalCSSDocumentInvalidationAndTargetLossTouchOnlyIndexedScope() throws {
    let pageScope = canonicalCSSScope(targetID: "page")
    let otherScope = canonicalCSSScope(targetID: "other")
    let fixture = canonicalCSSReducerFixture(scope: pageScope)
    var reducer = fixture.reducer
    _ = try reducer.bootstrap(
        scopes: [pageScope, otherScope],
        styleSheets: [
            canonicalCSSModelStyleSheet(id: "page-sheet", scope: pageScope),
            canonicalCSSModelStyleSheet(id: "other-sheet", scope: otherScope),
        ]
    )
    let otherDocumentScope = try canonicalCSSDocumentScope(fixture, eventScope: otherScope)
    let otherID = canonicalCSSID("other-sheet", scope: otherDocumentScope)
    let nextPageScope = canonicalCSSScope(targetID: "page", domEpoch: 2)

    let invalidation = try reducer.invalidateDocument(nextPageScope)
    #expect(invalidation.deletedRecordIDs.count == 1)
    #expect(reducer.record(for: otherID) != nil)
    let loss = try reducer.targetLost(scope: otherScope)
    #expect(loss.deletedRecordIDs == [otherID])
    #expect(reducer.record(for: otherID) == nil)
}

@Test
func canonicalCSSNormalEventLooksUpOnlyOneSheetInLargeMembership() throws {
    let fixture = canonicalCSSReducerFixture()
    var reducer = fixture.reducer
    let sheets = (0..<2_000).map { index in
        canonicalCSSModelStyleSheet(id: "sheet-\(index)", scope: fixture.scope)
    }
    _ = try reducer.bootstrap(scopes: [fixture.scope], styleSheets: sheets)
    let before = reducer.performanceCounters
    _ = try reducer.apply(
        scope: fixture.scope,
        event: .styleSheetChanged(CSS.StyleSheet.ID("sheet-997"))
    )
    let after = reducer.performanceCounters

    #expect(after.fullSnapshotHeaderVisitCount == before.fullSnapshotHeaderVisitCount)
    #expect(after.incrementalLookupCount - before.incrementalLookupCount == 1)
    #expect(after.recordMutationCount == before.recordMutationCount)
    #expect(after.unrelatedCollectionScanCount == 0)
}

@Test
func canonicalCSSResetClearsMembershipAndResourceRevisions() throws {
    let fixture = canonicalCSSReducerFixture()
    var reducer = fixture.reducer
    _ = try reducer.bootstrap(
        scopes: [fixture.scope],
        styleSheets: [
            canonicalCSSModelStyleSheet(id: "first", scope: fixture.scope),
            canonicalCSSModelStyleSheet(id: "second", scope: fixture.scope),
        ]
    )
    let documentScope = try canonicalCSSDocumentScope(fixture, eventScope: fixture.scope)
    let reset = reducer.reset()

    #expect(reset.deletedRecordIDs.count == 2)
    #expect(reset.resourceInvalidations == [.target(documentScope)])
    #expect(reducer.snapshot().recordsByID.isEmpty)
    #expect(reducer.cascadeRevision(in: documentScope) == 0)
}

private struct CanonicalCSSReducerFixture {
    let storeID: WebInspectorContainerStoreID
    let attachmentGeneration: WebInspectorContainerAttachmentGeneration
    let scope: WebInspectorCanonicalDOMEventScope
    let reducer: WebInspectorCanonicalCSSReducer
}

private func canonicalCSSReducerFixture(
    scope: WebInspectorCanonicalDOMEventScope = canonicalCSSScope()
) -> CanonicalCSSReducerFixture {
    let storeID = WebInspectorContainerStoreID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
    )
    let attachmentGeneration = WebInspectorContainerAttachmentGeneration(rawValue: 4)
    return CanonicalCSSReducerFixture(
        storeID: storeID,
        attachmentGeneration: attachmentGeneration,
        scope: scope,
        reducer: WebInspectorCanonicalCSSReducer(
            storeID: storeID,
            attachmentGeneration: attachmentGeneration
        )
    )
}

private func canonicalCSSScope(
    generation: UInt64 = 1,
    targetID: String = "page",
    agentTargetID: String = "agent",
    kind: WebInspectorTarget.Kind = .page,
    frameID: FrameID? = nil,
    domEpoch: UInt64? = 1
) -> WebInspectorCanonicalDOMEventScope {
    let modelScope = ModelEventScope(
        generation: WebInspectorPage.Generation(rawValue: generation),
        target: ModelTarget(
            id: WebInspectorTarget.ID(targetID),
            kind: kind,
            frameID: frameID,
            parentFrameID: nil
        ),
        agentTarget: ModelTarget(
            id: WebInspectorTarget.ID(agentTargetID),
            kind: kind,
            frameID: frameID,
            parentFrameID: nil
        ),
        navigationEpoch: ModelNavigationEpoch(rawValue: 1),
        domBindingEpoch: domEpoch.map(ModelDOMBindingEpoch.init(rawValue:))
    )
    return WebInspectorCanonicalDOMEventScope(modelScope: modelScope)
}

private func canonicalCSSDocumentScope(
    _ fixture: CanonicalCSSReducerFixture,
    eventScope: WebInspectorCanonicalDOMEventScope
) throws -> WebInspectorDOMDocumentScopeStorage {
    try #require(
        WebInspectorDOMDocumentScopeStorage(
            storeID: fixture.storeID,
            attachmentGeneration: fixture.attachmentGeneration,
            eventScope: eventScope
        ))
}

private func canonicalCSSID(
    _ rawValue: String,
    scope: WebInspectorDOMDocumentScopeStorage
) -> WebInspectorCSSStyleSheetIdentityStorage {
    WebInspectorCSSStyleSheetIdentityStorage(
        documentScope: scope,
        rawStyleSheetID: CSS.StyleSheet.ID(rawValue)
    )
}

private func canonicalCSSModelStyleSheet(
    id: String,
    scope: WebInspectorCanonicalDOMEventScope,
    title: String? = nil
) -> WebInspectorCanonicalCSSStyleSheetSnapshotRecord {
    WebInspectorCanonicalCSSStyleSheetSnapshotRecord(
        scope: scope,
        header: canonicalCSSHeader(id: id, title: title)
    )
}

private func canonicalCSSHeader(
    id: String,
    title: String? = nil
) -> CSS.StyleSheetHeader {
    CSS.StyleSheetHeader(
        styleSheetID: CSS.StyleSheet.ID(id),
        sourceURL: "https://example.test/\(id).css",
        origin: CSS.Origin(rawValue: "author"),
        title: title
    )
}
