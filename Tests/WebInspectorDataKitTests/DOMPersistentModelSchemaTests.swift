import Foundation
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@Test
func legacyDOMNodeIDsCannotBeConvertedIntoCanonicalAuthority() {
    #expect(DOMNode.ID(DOM.Node.ID("legacy")).canonicalStorage == nil)
}

@MainActor
@Test
func DOMSchemaDrivesGenericFetchFRCAndContextLocalIdentity() async throws {
    var fixture = DOMSchemaFixture()
    let child = domSchemaNode(
        id: "child",
        type: 3,
        name: "#text",
        value: "before"
    )
    let host = domSchemaNode(
        id: "host",
        attributes: [DOM.Attribute(name: "class", value: "before")],
        children: [child]
    )
    _ = try fixture.reducer.bootstrap(
        scope: fixture.pageScope,
        root: domSchemaNode(
            id: "document",
            type: 9,
            name: "#document",
            children: [host]
        )
    )
    let snapshot = fixture.modelSnapshot()
    let firstContext = DOMSchemaFixture.context()
    let secondContext = DOMSchemaFixture.context()
    try await publishDOMInitial(snapshot, to: firstContext)
    try await publishDOMInitial(snapshot, to: secondContext)

    let documentScope = try fixture.documentScope(for: fixture.pageScope)
    let documentID = DOMNode.ID(canonical: fixture.id("document", in: documentScope))
    let hostID = DOMNode.ID(canonical: fixture.id("host", in: documentScope))
    let childID = DOMNode.ID(canonical: fixture.id("child", in: documentScope))
    #expect(
        try await firstContext.fetchIdentifiers(
            WebInspectorFetchDescriptor<DOMNode>()
        ) == [documentID, hostID, childID]
    )

    let controller = try await WebInspectorFetchedResultsController<DOMNode, Never>(
        modelContext: firstContext,
        isolation: MainActor.shared
    )
    #expect(controller.snapshot.itemIDs == [documentID, hostID, childID])
    #expect(firstContext.registeredModel(for: documentID) == nil)
    #expect(firstContext.registeredModel(for: hostID) == nil)
    #expect(firstContext.registeredModel(for: childID) == nil)

    let firstHost = try #require(firstContext.model(for: hostID))
    let sameHost = try #require(firstContext.model(for: hostID))
    let secondHost = try #require(secondContext.model(for: hostID))
    #expect(firstHost === sameHost)
    #expect(firstHost !== secondHost)
    #expect(firstContext.registeredModel(for: documentID) == nil)
    #expect(firstContext.registeredModel(for: childID) == nil)

    let hostUpdate = try fixture.reducer.apply(
        scope: fixture.pageScope,
        event: .attributeModified(
            DOM.Node.ID("host"),
            name: "class",
            value: "after"
        )
    )
    try await publishDOMChanges(hostUpdate, revision: 1, to: firstContext)
    try await publishDOMChanges(hostUpdate, revision: 1, to: secondContext)
    #expect(firstHost.attributes == ["class": "after"])
    #expect(secondHost.attributes == ["class": "after"])
    #expect(controller.revision == 1)
    #expect(
        try await firstContext.fetchIdentifiers(
            WebInspectorFetchDescriptor<DOMNode>(
                predicate: #Predicate { $0.nodeName == "DIV" }
            )
        ) == [hostID]
    )

    let unmaterializedUpdate = try fixture.reducer.apply(
        scope: fixture.pageScope,
        event: .characterDataModified(DOM.Node.ID("child"), value: "after")
    )
    try await publishDOMChanges(
        unmaterializedUpdate,
        revision: 2,
        to: firstContext
    )
    #expect(firstContext.registeredModel(for: childID) == nil)
    #expect(
        try await firstContext.fetchIdentifiers(
            WebInspectorFetchDescriptor<DOMNode>(
                predicate: #Predicate { $0.nodeValue == "after" }
            )
        ) == [childID]
    )
    #expect(firstContext.registeredModel(for: childID) == nil)
    #expect(firstContext.model(for: childID)?.nodeValue == "after")

    await controller.close()
    await firstContext.close()
    await secondContext.close()
}

@MainActor
@Test
func DOMSchemaRelationshipsResolveOnlyTheRequestedCanonicalIDs() async throws {
    var fixture = DOMSchemaFixture()
    let host = domSchemaNode(
        id: "host",
        children: [domSchemaNode(id: "child")],
        contentDocument: domSchemaNode(
            id: "content",
            type: 9,
            name: "#document"
        ),
        shadowRoots: [
            domSchemaNode(id: "shadow", shadowRootType: .open)
        ],
        templateContent: domSchemaNode(id: "template"),
        beforePseudoElement: domSchemaNode(
            id: "before",
            pseudoType: .before
        ),
        otherPseudoElements: [
            domSchemaNode(id: "marker", pseudoType: .other("marker"))
        ],
        afterPseudoElement: domSchemaNode(id: "after", pseudoType: .after)
    )
    _ = try fixture.reducer.bootstrap(
        scope: fixture.pageScope,
        root: domSchemaNode(
            id: "document",
            type: 9,
            name: "#document",
            children: [host]
        )
    )
    let context = DOMSchemaFixture.context()
    try await publishDOMInitial(fixture.modelSnapshot(), to: context)
    let scope = try fixture.documentScope(for: fixture.pageScope)
    let id: (String) -> DOMNode.ID = {
        DOMNode.ID(canonical: fixture.id($0, in: scope))
    }
    let relatedIDs = [
        id("document"),
        id("child"),
        id("content"),
        id("shadow"),
        id("template"),
        id("before"),
        id("marker"),
        id("after"),
    ]
    let model = try #require(context.model(for: id("host")))
    #expect(relatedIDs.allSatisfy { context.registeredModel(for: $0) == nil })

    guard case let .loaded(children) = model.children else {
        Issue.record("The canonical host must expose loaded child IDs.")
        return
    }
    #expect(children.map(\.id) == [id("child")])
    #expect(context.registeredModel(for: id("child")) === children[0])
    #expect(context.registeredModel(for: id("document")) == nil)
    #expect(context.registeredModel(for: id("content")) == nil)

    #expect(model.contentDocument?.id == id("content"))
    #expect(context.registeredModel(for: id("shadow")) == nil)
    #expect(model.shadowRoots.map(\.id) == [id("shadow")])
    #expect(context.registeredModel(for: id("template")) == nil)
    #expect(model.templateContent?.id == id("template"))
    #expect(model.beforePseudoElement?.id == id("before"))
    #expect(model.otherPseudoElements.map(\.id) == [id("marker")])
    #expect(model.afterPseudoElement?.id == id("after"))
    #expect(context.registeredModel(for: id("document")) == nil)

    let document = try #require(model.documentRoot)
    #expect(document.id == id("document"))
    #expect(model.parent === document)
    await context.close()
}

@MainActor
@Test
func DOMRelationshipDeltaUpdatesOnlyTheExistingOwner() async throws {
    var fixture = DOMSchemaFixture()
    _ = try fixture.reducer.bootstrap(
        scope: fixture.pageScope,
        root: domSchemaNode(
            id: "document",
            type: 9,
            name: "#document",
            children: [domSchemaNode(id: "host")]
        )
    )
    let context = DOMSchemaFixture.context()
    try await publishDOMInitial(fixture.modelSnapshot(), to: context)
    let scope = try fixture.documentScope(for: fixture.pageScope)
    let id: (String) -> DOMNode.ID = {
        DOMNode.ID(canonical: fixture.id($0, in: scope))
    }
    let host = try #require(context.model(for: id("host")))
    let replacement = domSchemaNode(
        id: "host",
        children: [domSchemaNode(id: "child")],
        contentDocument: domSchemaNode(
            id: "content",
            type: 9,
            name: "#document"
        ),
        shadowRoots: [
            domSchemaNode(id: "shadow", shadowRootType: .closed)
        ],
        templateContent: domSchemaNode(id: "template"),
        beforePseudoElement: domSchemaNode(
            id: "before",
            pseudoType: .before
        ),
        otherPseudoElements: [
            domSchemaNode(id: "marker", pseudoType: .other("marker"))
        ],
        afterPseudoElement: domSchemaNode(id: "after", pseudoType: .after)
    )
    let relationshipDelta = try fixture.reducer.apply(
        scope: fixture.pageScope,
        event: .setChildNodes(
            parent: DOM.Node.ID("document"),
            nodes: [replacement]
        )
    )
    try await publishDOMChanges(
        relationshipDelta,
        revision: 1,
        to: context
    )

    let relatedIDs = [
        id("document"),
        id("child"),
        id("content"),
        id("shadow"),
        id("template"),
        id("before"),
        id("marker"),
        id("after"),
    ]
    #expect(context.registeredModel(for: id("host")) === host)
    #expect(host.childNodeCount == 1)
    #expect(relatedIDs.allSatisfy { context.registeredModel(for: $0) == nil })

    guard case let .loaded(children) = host.children else {
        Issue.record("The relationship delta must install loaded children.")
        return
    }
    #expect(children.map(\.id) == [id("child")])
    #expect(host.contentDocument?.id == id("content"))
    #expect(host.shadowRoots.map(\.id) == [id("shadow")])
    #expect(host.templateContent?.id == id("template"))
    #expect(host.beforePseudoElement?.id == id("before"))
    #expect(host.otherPseudoElements.map(\.id) == [id("marker")])
    #expect(host.afterPseudoElement?.id == id("after"))
    #expect(context.registeredModel(for: id("document")) == nil)
    await context.close()
}

@MainActor
@Test
func DOMSchemaResetReplacesRecordsAndResourcesWithoutReplacingIdentity() async throws {
    var fixture = DOMSchemaFixture()
    _ = try fixture.reducer.bootstrap(
        scope: fixture.pageScope,
        root: domSchemaNode(
            id: "document",
            type: 9,
            name: "#document",
            children: [
                domSchemaNode(
                    id: "host",
                    attributes: [DOM.Attribute(name: "class", value: "before")]
                )
            ]
        )
    )
    let context = DOMSchemaFixture.context()
    try await publishDOMInitial(fixture.modelSnapshot(), to: context)
    let scope = try fixture.documentScope(for: fixture.pageScope)
    let documentID = DOMNode.ID(
        canonical: fixture.id("document", in: scope)
    )
    let hostID = DOMNode.ID(canonical: fixture.id("host", in: scope))
    let host = try #require(context.model(for: hostID))
    let styles = loadedStyles(for: host, in: context)
    let update = try fixture.reducer.apply(
        scope: fixture.pageScope,
        event: .attributeModified(
            DOM.Node.ID("host"),
            name: "class",
            value: "after"
        )
    )
    #expect(update.isEmpty == false)

    try await publishDOMReset(
        fixture.modelSnapshot(),
        revision: 1,
        to: context
    )
    #expect(context.registeredModel(for: hostID) === host)
    #expect(host.attributes == ["class": "after"])
    #expect(host.modelContext === context)
    #expect(host.elementStyles == nil)
    #expect(styles.modelContext == nil)
    #expect(styles.phase == .unavailable)
    #expect(context.registeredModel(for: documentID) == nil)
    #expect(host.parent?.id == documentID)
    await context.close()
}

@MainActor
@Test
func frameRootReconciliationUpdatesMaterializedDescendantTopologyOnly() async throws {
    let frameID = FrameID("child-frame")
    var fixture = DOMSchemaFixture()
    let frameScope = fixture.scope(
        targetID: "frame-target",
        agentTargetID: "frame-agent",
        kind: .frame,
        frameID: frameID
    )
    _ = try fixture.reducer.bootstrap(
        scope: frameScope,
        root: domSchemaNode(
            id: "frame-document",
            type: 9,
            name: "#document",
            frameID: frameID,
            children: [
                domSchemaNode(
                    id: "frame-body",
                    children: [domSchemaNode(id: "frame-leaf")]
                )
            ]
        )
    )
    let context = DOMSchemaFixture.context()
    try await publishDOMInitial(fixture.modelSnapshot(), to: context)

    let frameDocumentScope = try fixture.documentScope(for: frameScope)
    let frameRootID = DOMNode.ID(
        canonical: fixture.id("frame-document", in: frameDocumentScope)
    )
    let frameBodyID = DOMNode.ID(
        canonical: fixture.id("frame-body", in: frameDocumentScope)
    )
    let leafID = DOMNode.ID(
        canonical: fixture.id("frame-leaf", in: frameDocumentScope)
    )
    let leaf = try #require(context.model(for: leafID))
    let leafStyles = loadedStyles(for: leaf, in: context)
    #expect(leaf.canonicalAncestorIDsForTesting == [
        frameRootID.canonicalStorage,
        frameBodyID.canonicalStorage,
    ].compactMap { $0 })
    #expect(context.registeredModel(for: frameRootID) == nil)
    #expect(context.registeredModel(for: frameBodyID) == nil)

    let pageTransaction = try fixture.reducer.bootstrap(
        scope: fixture.pageScope,
        root: domSchemaNode(
            id: "page-document",
            type: 9,
            name: "#document",
            children: [
                domSchemaNode(
                    id: "iframe",
                    name: "IFRAME",
                    localName: "iframe",
                    frameID: frameID
                )
            ]
        )
    )
    try await publishDOMChanges(pageTransaction, revision: 1, to: context)
    let pageDocumentScope = try fixture.documentScope(for: fixture.pageScope)
    let pageRootStorage = fixture.id("page-document", in: pageDocumentScope)
    let ownerStorage = fixture.id("iframe", in: pageDocumentScope)
    #expect(leaf.canonicalAncestorIDsForTesting == [
        pageRootStorage,
        ownerStorage,
        frameRootID.canonicalStorage,
        frameBodyID.canonicalStorage,
    ].compactMap { $0 })
    #expect(context.registeredModel(for: frameRootID) == nil)
    #expect(context.registeredModel(for: frameBodyID) == nil)
    #expect(leafStyles.phase == .loaded)

    let lateFrameRoot = try #require(context.model(for: frameRootID))
    #expect(lateFrameRoot.parent?.id == DOMNode.ID(canonical: ownerStorage))
    #expect(lateFrameRoot.documentRoot === lateFrameRoot)

    var pageSubtreeInvalidation = WebInspectorCanonicalDOMTransaction()
    pageSubtreeInvalidation.resourceInvalidations = [.subtree(ownerStorage)]
    try await publishDOMChanges(
        pageSubtreeInvalidation,
        revision: 2,
        to: context
    )
    #expect(leafStyles.phase == .loaded)

    let ownerLoss = try fixture.reducer.targetLost(scope: fixture.pageScope)
    try await publishDOMChanges(ownerLoss, revision: 3, to: context)
    #expect(leaf.canonicalAncestorIDsForTesting == [
        frameRootID.canonicalStorage,
        frameBodyID.canonicalStorage,
    ].compactMap { $0 })
    #expect(lateFrameRoot.parent == nil)
    #expect(lateFrameRoot.documentRoot === lateFrameRoot)
    await context.close()
}

@MainActor
@Test
func DOMAndCSSInvalidationsReachExactExistingResourcesAndDeletionOwners() async throws {
    var fixture = DOMSchemaFixture()
    _ = try fixture.reducer.bootstrap(
        scope: fixture.pageScope,
        root: domSchemaNode(
            id: "page-document",
            type: 9,
            name: "#document",
            children: [
                domSchemaNode(
                    id: "host",
                    children: [domSchemaNode(id: "child")]
                ),
                domSchemaNode(id: "sibling"),
            ]
        )
    )
    let otherScope = fixture.scope(
        targetID: "other",
        agentTargetID: "other-agent"
    )
    _ = try fixture.reducer.bootstrap(
        scope: otherScope,
        root: domSchemaNode(
            id: "other-document",
            type: 9,
            name: "#document",
            children: [domSchemaNode(id: "other-element")]
        )
    )
    let context = DOMSchemaFixture.context()
    try await publishDOMInitial(fixture.modelSnapshot(), to: context)
    let pageDocumentScope = try fixture.documentScope(for: fixture.pageScope)
    let otherDocumentScope = try fixture.documentScope(for: otherScope)
    let pageID: (String) -> DOMNode.ID = {
        DOMNode.ID(canonical: fixture.id($0, in: pageDocumentScope))
    }
    let otherID: (String) -> DOMNode.ID = {
        DOMNode.ID(canonical: fixture.id($0, in: otherDocumentScope))
    }
    let host = try #require(context.model(for: pageID("host")))
    let child = try #require(context.model(for: pageID("child")))
    let sibling = try #require(context.model(for: pageID("sibling")))
    let other = try #require(context.model(for: otherID("other-element")))
    let hostStyles = loadedStyles(for: host, in: context)
    let childStyles = loadedStyles(for: child, in: context)
    let siblingStyles = loadedStyles(for: sibling, in: context)
    let otherStyles = loadedStyles(for: other, in: context)
    let hostStorage = fixture.id("host", in: pageDocumentScope)
    let resource = WebInspectorCanonicalCSSResource(
        lease: WebInspectorCanonicalCSSResourceLease(
            nodeID: hostStorage,
            cascadeRevision: 1,
            presentationRevision: WebInspectorCanonicalPresentationRevision(
                targetRevision: 0,
                subtreeComponents: [],
                nodeRevision: 0
            )
        ),
        matchedStyles: CSS.MatchedStyles(),
        inlineStyles: CSS.InlineStyles(),
        computedProperties: []
    )
    let acceptedGeneration = hostStyles.beginCanonicalLoading()
    #expect(hostStyles.load(resource, generation: acceptedGeneration))
    let staleGeneration = hostStyles.beginCanonicalLoading()
    hostStyles.markCanonicalNeedsRefresh()
    #expect(hostStyles.load(resource, generation: staleGeneration) == false)
    #expect(hostStyles.phase == .needsRefresh)
    hostStyles.load(
        matchedStyles: CSS.MatchedStyles(),
        inlineStyles: CSS.InlineStyles(),
        computedProperties: []
    )

    var nodeInvalidation = WebInspectorCanonicalDOMTransaction()
    nodeInvalidation.resourceInvalidations = [
        .nodes([fixture.id("child", in: pageDocumentScope)])
    ]
    try await publishDOMChanges(nodeInvalidation, revision: 1, to: context)
    #expect(hostStyles.phase == .loaded)
    #expect(childStyles.phase == .needsRefresh)
    #expect(siblingStyles.phase == .loaded)
    #expect(otherStyles.phase == .loaded)
    childStyles.load(
        matchedStyles: CSS.MatchedStyles(),
        inlineStyles: CSS.InlineStyles(),
        computedProperties: []
    )

    var subtreeInvalidation = WebInspectorCanonicalDOMTransaction()
    subtreeInvalidation.resourceInvalidations = [
        .subtree(fixture.id("host", in: pageDocumentScope))
    ]
    try await publishDOMChanges(subtreeInvalidation, revision: 2, to: context)
    #expect(hostStyles.phase == .needsRefresh)
    #expect(childStyles.phase == .needsRefresh)
    #expect(siblingStyles.phase == .loaded)
    #expect(otherStyles.phase == .loaded)
    hostStyles.load(
        matchedStyles: CSS.MatchedStyles(),
        inlineStyles: CSS.InlineStyles(),
        computedProperties: []
    )
    childStyles.load(
        matchedStyles: CSS.MatchedStyles(),
        inlineStyles: CSS.InlineStyles(),
        computedProperties: []
    )

    var CSS = WebInspectorCanonicalCSSTransaction()
    CSS.resourceInvalidations = [.target(pageDocumentScope)]
    try await publishCSSChanges(CSS, revision: 3, to: context)
    #expect(hostStyles.phase == .needsRefresh)
    #expect(childStyles.phase == .needsRefresh)
    #expect(siblingStyles.phase == .needsRefresh)
    #expect(otherStyles.phase == .loaded)

    let replacementScope = fixture.scope(domEpoch: 2)
    let documentInvalidation = try fixture.reducer.invalidateDocument(
        replacementScope
    )
    try await publishDOMChanges(
        documentInvalidation,
        revision: 4,
        to: context
    )
    #expect(context.registeredModel(for: pageID("host")) == nil)
    #expect(host.modelContext == nil)
    #expect(hostStyles.phase == .unavailable)
    #expect(context.registeredModel(for: otherID("other-element")) === other)
    #expect(other.modelContext === context)
    #expect(otherStyles.phase == .loaded)

    let targetLoss = try fixture.reducer.targetLost(scope: otherScope)
    try await publishDOMChanges(targetLoss, revision: 5, to: context)
    #expect(context.registeredModel(for: otherID("other-element")) == nil)
    #expect(other.modelContext == nil)
    #expect(otherStyles.phase == .unavailable)
    await context.close()
}

private struct DOMSchemaFixture {
    let storeID = WebInspectorContainerStoreID(
        rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-0000000000D0"
        )!
    )
    let attachmentGeneration = WebInspectorContainerAttachmentGeneration(
        rawValue: 1
    )
    let pageScope: WebInspectorCanonicalDOMEventScope
    var reducer: WebInspectorCanonicalDOMReducer

    init() {
        let pageScope = Self.makeScope(
            targetID: "page",
            agentTargetID: "page-agent",
            kind: .page,
            frameID: nil,
            domEpoch: 1
        )
        self.pageScope = pageScope
        reducer = WebInspectorCanonicalDOMReducer(
            storeID: storeID,
            attachmentGeneration: attachmentGeneration
        )
    }

    @MainActor
    static func context() -> WebInspectorModelContext {
        WebInspectorModelContext(
            modelSchemaRegistry: WebInspectorModelSchemaRegistry(
                WebInspectorDOMModelSchemas.registrations
            ),
            isolation: MainActor.shared
        )
    }

    func scope(
        targetID: String = "page",
        agentTargetID: String = "page-agent",
        kind: WebInspectorTarget.Kind = .page,
        frameID: FrameID? = nil,
        domEpoch: UInt64 = 1
    ) -> WebInspectorCanonicalDOMEventScope {
        Self.makeScope(
            targetID: targetID,
            agentTargetID: agentTargetID,
            kind: kind,
            frameID: frameID,
            domEpoch: domEpoch
        )
    }

    func documentScope(
        for eventScope: WebInspectorCanonicalDOMEventScope
    ) throws -> WebInspectorDOMDocumentScopeStorage {
        try #require(
            WebInspectorDOMDocumentScopeStorage(
                storeID: storeID,
                attachmentGeneration: attachmentGeneration,
                eventScope: eventScope
            )
        )
    }

    func id(
        _ rawValue: String,
        in scope: WebInspectorDOMDocumentScopeStorage
    ) -> WebInspectorDOMNodeIdentityStorage {
        WebInspectorDOMNodeIdentityStorage(
            documentScope: scope,
            rawNodeID: DOM.Node.ID(rawValue)
        )
    }

    mutating func modelSnapshot() -> WebInspectorCanonicalModelSnapshot {
        WebInspectorCanonicalModelSnapshot(
            binding: nil,
            network: nil,
            DOM: reducer.snapshot(),
            CSS: nil,
            consoleRuntime: nil
        )
    }

    private static func makeScope(
        targetID: String,
        agentTargetID: String,
        kind: WebInspectorTarget.Kind,
        frameID: FrameID?,
        domEpoch: UInt64
    ) -> WebInspectorCanonicalDOMEventScope {
        WebInspectorCanonicalDOMEventScope(
            modelScope: ModelEventScope(
                generation: WebInspectorPage.Generation(rawValue: 1),
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
                domBindingEpoch: ModelDOMBindingEpoch(rawValue: domEpoch),
                runtimeBindingEpoch: nil,
                consoleBindingEpoch: nil
            )
        )
    }
}

private func domSchemaNode(
    id: String,
    type: Int = 1,
    name: String = "DIV",
    localName: String = "div",
    value: String = "",
    frameID: FrameID? = nil,
    attributes: [DOM.Attribute] = [],
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
        attributes: Dictionary(
            uniqueKeysWithValues: attributes.map { ($0.name, $0.value) }
        ),
        attributeList: attributes,
        childNodeCount: children?.count ?? 0,
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

@MainActor
private func loadedStyles(
    for node: DOMNode,
    in context: WebInspectorModelContext
) -> CSSStyles {
    let styles = CSSStyles(nodeID: node.id, modelContext: context)
    node.setElementStyles(styles)
    styles.load(
        matchedStyles: CSS.MatchedStyles(),
        inlineStyles: CSS.InlineStyles(),
        computedProperties: []
    )
    return styles
}

@MainActor
private func publishDOMInitial(
    _ snapshot: WebInspectorCanonicalModelSnapshot,
    to context: WebInspectorModelContext
) async throws {
    let transaction = context.modelSchemaContextCore.initial(
        at: 0,
        snapshot: snapshot
    )
    let commit = try await transaction.stage(
        on: context.fetchedResultsQueryCore
    )
    #expect(context.publish(commit))
}

@MainActor
private func publishDOMChanges(
    _ DOM: WebInspectorCanonicalDOMTransaction,
    revision: UInt64,
    to context: WebInspectorModelContext
) async throws {
    var canonical = WebInspectorCanonicalModelTransaction()
    canonical.DOM = DOM
    try await publishCanonicalChanges(
        canonical,
        revision: revision,
        to: context
    )
}

@MainActor
private func publishDOMReset(
    _ snapshot: WebInspectorCanonicalModelSnapshot,
    revision: UInt64,
    to context: WebInspectorModelContext
) async throws {
    let transaction = context.modelSchemaContextCore.reset(
        at: revision,
        snapshot: snapshot
    )
    let commit = try await transaction.stage(
        on: context.fetchedResultsQueryCore
    )
    #expect(context.publish(commit))
}

@MainActor
private func publishCSSChanges(
    _ CSS: WebInspectorCanonicalCSSTransaction,
    revision: UInt64,
    to context: WebInspectorModelContext
) async throws {
    var canonical = WebInspectorCanonicalModelTransaction()
    canonical.CSS = CSS
    try await publishCanonicalChanges(
        canonical,
        revision: revision,
        to: context
    )
}

@MainActor
private func publishCanonicalChanges(
    _ canonical: WebInspectorCanonicalModelTransaction,
    revision: UInt64,
    to context: WebInspectorModelContext
) async throws {
    let transaction = context.modelSchemaContextCore.changes(
        at: revision,
        transaction: canonical
    )
    let commit = try await transaction.stage(
        on: context.fetchedResultsQueryCore
    )
    #expect(context.publish(commit))
}
