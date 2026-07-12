import Foundation
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

private struct CanonicalModelStoreFixture {
    var store: WebInspectorCanonicalModelStore
    let attachmentGeneration: WebInspectorContainerAttachmentGeneration
    let pageGeneration: WebInspectorPage.Generation
    let domains: Set<ModelDomain>
    let targetsByID: [WebInspectorTarget.ID: ModelTarget]
    var nextSequence: UInt64

    init(
        domains: Set<ModelDomain>,
        targets: [ModelTarget] = [canonicalModelPageTarget()],
        attachment: UInt64 = 1,
        page: UInt64 = 1
    ) throws {
        var normalizedDomains = domains
        if normalizedDomains.contains(.css) {
            normalizedDomains.insert(.dom)
        }
        self.domains = normalizedDomains
        attachmentGeneration = WebInspectorContainerAttachmentGeneration(
            rawValue: attachment
        )
        pageGeneration = WebInspectorPage.Generation(rawValue: page)
        targetsByID = Dictionary(
            uniqueKeysWithValues: targets.map { ($0.id, $0) }
        )
        nextSequence = 1
        store = WebInspectorCanonicalModelStore(
            storeID: WebInspectorContainerStoreID(
                rawValue: UUID(
                    uuidString: "A0000000-0000-0000-0000-000000000001"
                )!
            ),
            configuredDomains: domains
        )
        _ = try store.reduce(
            .reset(pageGeneration),
            attachmentGeneration: attachmentGeneration
        )
        _ = try store.reduce(
            .targetSnapshot(
                generation: pageGeneration,
                through: 0,
                snapshot: ModelTargetSnapshot(
                    currentPageID: targets[0].id,
                    targets: targets.map { targetState(for: $0) }
                )
            ),
            attachmentGeneration: attachmentGeneration
        )
    }

    func targetState(for target: ModelTarget) -> ModelTargetState {
        ModelTargetState(
            target: target,
            navigationEpoch: ModelNavigationEpoch(rawValue: 1),
            domBindingEpoch: domains.contains(.dom)
                ? ModelDOMBindingEpoch(rawValue: 1)
                : nil,
            runtimeBindingEpoch: domains.contains(.runtime)
                || domains.contains(.console)
                ? ModelRuntimeBindingEpoch(rawValue: 1)
                : nil,
            consoleBindingEpoch: domains.contains(.console)
                ? ModelConsoleBindingEpoch(rawValue: 1)
                : nil
        )
    }

    func scope(
        targetID: String = "page",
        agentTargetID: String? = nil,
        navigationEpoch: UInt64 = 1,
        DOMBindingEpoch: UInt64? = nil,
        runtimeBindingEpoch: UInt64? = nil,
        consoleBindingEpoch: UInt64? = nil,
        generation: WebInspectorPage.Generation? = nil
    ) -> ModelEventScope {
        let target = targetsByID[WebInspectorTarget.ID(targetID)]!
        let agent = targetsByID[
            WebInspectorTarget.ID(agentTargetID ?? targetID)
        ]!
        return ModelEventScope(
            generation: generation ?? pageGeneration,
            target: target,
            agentTarget: agent,
            navigationEpoch: ModelNavigationEpoch(rawValue: navigationEpoch),
            domBindingEpoch: domains.contains(.dom)
                ? ModelDOMBindingEpoch(rawValue: DOMBindingEpoch ?? 1)
                : nil,
            runtimeBindingEpoch: domains.contains(.runtime)
                || domains.contains(.console)
                ? ModelRuntimeBindingEpoch(rawValue: runtimeBindingEpoch ?? 1)
                : nil,
            consoleBindingEpoch: domains.contains(.console)
                ? ModelConsoleBindingEpoch(rawValue: consoleBindingEpoch ?? 1)
                : nil
        )
    }

    mutating func event(
        _ payload: ModelProtocolEvent,
        scope: ModelEventScope
    ) throws -> WebInspectorCanonicalModelTransaction {
        defer { nextSequence += 1 }
        return try store.reduce(
            .event(
                sequence: nextSequence,
                scope: scope,
                payload: payload
            ),
            attachmentGeneration: attachmentGeneration
        )
    }

    mutating func bootstrapDOM(
        targetID: String = "page",
        root: DOM.Node
    ) throws -> WebInspectorCanonicalModelTransaction {
        let scope = scope(targetID: targetID)
        defer { nextSequence += 1 }
        return try store.reduce(
            .bootstrapSnapshot(
                generation: pageGeneration,
                domain: .dom,
                sequence: nextSequence,
                payload: .domDocument(scope: scope, root: root)
            ),
            attachmentGeneration: attachmentGeneration
        )
    }

    mutating func bootstrapCSS(
        _ styleSheets: [(targetID: String, header: CSS.StyleSheetHeader)]
    ) throws -> WebInspectorCanonicalModelTransaction {
        let records = styleSheets.map { item in
            ModelCSSStyleSheet(
                scope: scope(targetID: item.targetID),
                header: item.header
            )
        }
        defer { nextSequence += 1 }
        return try store.reduce(
            .bootstrapSnapshot(
                generation: pageGeneration,
                domain: .css,
                sequence: nextSequence,
                payload: .cssStyleSheets(records)
            ),
            attachmentGeneration: attachmentGeneration
        )
    }

    mutating func completeBootstrap(_ domain: ModelDomain) throws {
        _ = try store.reduce(
            .bootstrapComplete(
                generation: pageGeneration,
                domain: domain,
                through: nextSequence - 1
            ),
            attachmentGeneration: attachmentGeneration
        )
    }

    mutating func completeReplay(_ domain: ModelDomain) throws {
        _ = try store.reduce(
            .replayComplete(
                generation: pageGeneration,
                domain: domain,
                through: nextSequence - 1
            ),
            attachmentGeneration: attachmentGeneration
        )
    }
}

private func canonicalModelPageTarget(
    id: String = "page",
    frameID: String = "main-frame"
) -> ModelTarget {
    ModelTarget(
        id: WebInspectorTarget.ID(id),
        kind: .page,
        frameID: FrameID(frameID),
        parentFrameID: nil
    )
}

private func canonicalModelFrameTarget(
    id: String = "frame-agent",
    frameID: String = "isolated-frame",
    parentFrameID: String = "main-frame"
) -> ModelTarget {
    ModelTarget(
        id: WebInspectorTarget.ID(id),
        kind: .frame,
        frameID: FrameID(frameID),
        parentFrameID: FrameID(parentFrameID)
    )
}

private func canonicalModelDOMNode(
    id: String,
    type: Int = 1,
    name: String = "DIV",
    localName: String = "div",
    frameID: String? = nil,
    children: [DOM.Node]? = nil,
    contentDocument: DOM.Node? = nil
) -> DOM.Node {
    DOM.Node(
        id: DOM.Node.ID(id),
        nodeType: type,
        nodeName: name,
        localName: localName,
        frameID: frameID.map(FrameID.init),
        childNodeCount: children?.count ?? 0,
        children: children,
        contentDocument: contentDocument
    )
}

private func canonicalModelDocument(
    id: String,
    frameID: String? = nil,
    children: [DOM.Node] = []
) -> DOM.Node {
    canonicalModelDOMNode(
        id: id,
        type: 9,
        name: "#document",
        localName: "",
        frameID: frameID,
        children: children
    )
}

private func canonicalModelConsoleMessage(
    text: String,
    networkRequestID: String? = nil
) -> Console.Message {
    Console.Message(
        source: Console.Source(rawValue: "console-api"),
        level: Console.Level(rawValue: "log"),
        type: Console.Kind(rawValue: "log"),
        text: text,
        repeatCount: 1,
        networkRequestID: networkRequestID.map(Network.Request.ID.init),
        timestamp: 1
    )
}

private func canonicalModelRuntimeContext(
    id: String,
    frameID: String?
) -> Runtime.ExecutionContext {
    Runtime.ExecutionContext(
        id: Runtime.ExecutionContext.ID(id),
        name: id,
        frameID: frameID.map(FrameID.init),
        kind: .normal
    )
}

private func canonicalModelFrameLifecycle(
    id: String,
    parentID: String
) -> WebInspectorPageFrameLifecycle {
    WebInspectorPageFrameLifecycle(
        id: FrameID(id),
        parentID: FrameID(parentID),
        loaderID: "loader-\(id)",
        name: nil,
        url: "https://example.test/\(id)",
        securityOrigin: "https://example.test",
        mimeType: "text/html"
    )
}

private func canonicalModelStyleSheet(
    id: String,
    frameID: String
) -> CSS.StyleSheetHeader {
    CSS.StyleSheetHeader(
        styleSheetID: CSS.StyleSheet.ID(id),
        frameID: FrameID(frameID),
        sourceURL: "https://example.test/\(id).css",
        origin: CSS.Origin(rawValue: "author")
    )
}

private func requireCanonicalStoreSendable<T: Sendable>(_: T.Type) {}

@Test
func canonicalModelStoreIsPureSendableAndNormalizesCSSDependency() throws {
    requireCanonicalStoreSendable(WebInspectorCanonicalModelStore.self)
    let fixture = try CanonicalModelStoreFixture(domains: [.css])

    #expect(fixture.store.configuredDomains == [.dom, .css])
    #expect(fixture.store.bindingSnapshot?.isSynchronized == false)
}

@Test
func canonicalModelStoreEnforcesSequenceWatermarkAndSynchronizationBoundaries() throws {
    var fixture = try CanonicalModelStoreFixture(domains: [.network])
    let before = fixture.store.snapshot(reason: .onDemandRebase)
    let stale = ConnectionModelFeedRecord.event(
        sequence: 0,
        scope: fixture.scope(),
        payload: .network(
            canonicalRequestWillBeSent(
                id: "stale",
                url: "https://example.test/stale",
                timestamp: 1
            )
        )
    )

    #expect(throws: WebInspectorCanonicalModelStoreError.self) {
        try fixture.store.reduce(
            stale,
            attachmentGeneration: fixture.attachmentGeneration
        )
    }
    #expect(fixture.store.snapshot(reason: .onDemandRebase) == before)

    _ = try fixture.event(
        .network(
            canonicalRequestWillBeSent(
                id: "request",
                url: "https://example.test/",
                timestamp: 1
            )
        ),
        scope: fixture.scope()
    )
    #expect(throws: WebInspectorCanonicalModelStoreError.self) {
        try fixture.store.reduce(
            .synchronizationComplete(
                generation: fixture.pageGeneration,
                through: fixture.nextSequence - 1
            ),
            attachmentGeneration: fixture.attachmentGeneration
        )
    }
    try fixture.completeReplay(.network)
    _ = try fixture.store.reduce(
        .synchronizationComplete(
            generation: fixture.pageGeneration,
            through: fixture.nextSequence - 1
        ),
        attachmentGeneration: fixture.attachmentGeneration
    )
    #expect(fixture.store.bindingSnapshot?.isSynchronized == true)
    #expect(fixture.store.bindingSnapshot?.lastSequence == 1)
}

@Test
func canonicalModelStoreRequiresDOMAndCSSBootstrapBeforeLiveDeltas() throws {
    var fixture = try CanonicalModelStoreFixture(domains: [.css])
    let scope = fixture.scope()

    #expect(throws: WebInspectorCanonicalModelStoreError.self) {
        try fixture.event(
            .dom(.attributeModified(DOM.Node.ID("root"), name: "id", value: "x")),
            scope: scope
        )
    }
    _ = try fixture.bootstrapDOM(
        root: canonicalModelDocument(id: "root")
    )
    #expect(throws: WebInspectorCanonicalModelStoreError.self) {
        try fixture.event(
            .css(.mediaQueryResultChanged),
            scope: scope
        )
    }
    _ = try fixture.bootstrapCSS([])
    try fixture.completeBootstrap(.dom)
    try fixture.completeBootstrap(.css)
    _ = try fixture.store.reduce(
        .synchronizationComplete(
            generation: fixture.pageGeneration,
            through: fixture.nextSequence - 1
        ),
        attachmentGeneration: fixture.attachmentGeneration
    )

    #expect(fixture.store.bindingSnapshot?.readyDOMTargetIDs == [WebInspectorTarget.ID("page")])
    #expect(fixture.store.bindingSnapshot?.isCSSReady == true)
    #expect(fixture.store.bindingSnapshot?.isSynchronized == true)
}

@Test
func canonicalModelStoreEmitsOnlyAValidatedInspectorActionSeam() throws {
    var fixture = try CanonicalModelStoreFixture(domains: [.dom])
    _ = try fixture.bootstrapDOM(
        root: canonicalModelDocument(id: "document")
    )
    let objectID = Runtime.RemoteObject.ID("node-object")
    let action = try fixture.event(
        .inspector(
            .inspect(
                Runtime.RemoteObject(
                    id: objectID,
                    kind: .object,
                    subtype: Runtime.Subtype(rawValue: "node")
                ),
                hints: nil
            )
        ),
        scope: fixture.scope()
    )

    #expect(
        action.actions == [
            .inspectRemoteObject(
                scope: fixture.scope(),
                objectID: objectID
            )
        ]
    )
    #expect(action.network == nil)
    #expect(action.DOM == nil)
    #expect(action.CSS == nil)
    #expect(action.consoleRuntime == nil)

    let ignored = try fixture.event(
        .inspector(
            .unknown(
                RawEvent(domain: "Inspector", method: "ignored")
            )
        ),
        scope: fixture.scope()
    )
    #expect(ignored.isEmpty)
}

@Test
func canonicalModelStoreKeepsSemanticAndAgentTargetsDistinctAndResolvesConsoleReferences() throws {
    let page = canonicalModelPageTarget()
    let frame = canonicalModelFrameTarget()
    var fixture = try CanonicalModelStoreFixture(
        domains: [.network, .console, .runtime],
        targets: [page, frame]
    )
    let networkScope = fixture.scope(
        targetID: "frame-agent",
        agentTargetID: "page"
    )
    let first = try fixture.event(
        .network(
            canonicalRequestWillBeSent(
                id: "first",
                url: "https://example.test/first",
                timestamp: 1
            )
        ),
        scope: networkScope
    )
    let firstNetwork = try #require(first.network)
    guard
        case let .insert(firstRecord, _) = try #require(
            firstNetwork.requestChanges.first
        )
    else {
        Issue.record("Expected a canonical Network insertion.")
        return
    }
    #expect(firstRecord.id.agentTargetID == WebInspectorTarget.ID("page"))
    #expect(firstRecord.membership.semanticTargetID == WebInspectorTarget.ID("frame-agent"))

    let resolved = try fixture.event(
        .console(
            .messageAdded(
                canonicalModelConsoleMessage(
                    text: "resolved",
                    networkRequestID: "first"
                )
            )
        ),
        scope: fixture.scope(
            targetID: "frame-agent",
            agentTargetID: "frame-agent"
        )
    )
    let resolvedConsole = try #require(resolved.consoleRuntime)
    guard
        case let .insert(resolvedRecord, _) = try #require(
            resolvedConsole.consoleMessageChanges.first
        )
    else {
        Issue.record("Expected a canonical Console insertion.")
        return
    }
    #expect(
        resolvedRecord.networkRequestReference
            == .resolved(
                rawRequestID: Network.Request.ID("first"),
                requestID: firstRecord.id
            )
    )

    let unresolved = try fixture.event(
        .console(
            .messageAdded(
                canonicalModelConsoleMessage(
                    text: "unresolved",
                    networkRequestID: "later"
                )
            )
        ),
        scope: fixture.scope(targetID: "frame-agent")
    )
    let unresolvedConsole = try #require(unresolved.consoleRuntime)
    guard
        case let .insert(unresolvedRecord, _) = try #require(
            unresolvedConsole.consoleMessageChanges.first
        )
    else {
        Issue.record("Expected an unresolved Console insertion.")
        return
    }
    #expect(
        unresolvedRecord.networkRequestReference
            == .unresolved(rawRequestID: Network.Request.ID("later"))
    )

    let later = try fixture.event(
        .network(
            canonicalRequestWillBeSent(
                id: "later",
                url: "https://example.test/later",
                timestamp: 2
            )
        ),
        scope: networkScope
    )
    let laterConsole = try #require(later.consoleRuntime)
    guard
        case let .update(messageID, .networkRequestReference(reference), _) =
            try #require(laterConsole.consoleMessageChanges.first)
    else {
        Issue.record("Expected the Network insertion to resolve pending Console state.")
        return
    }
    #expect(messageID == unresolvedRecord.id)
    guard case let .resolved(_, laterRequestID) = reference else {
        Issue.record("Expected an exact scoped Network identity.")
        return
    }
    #expect(laterRequestID.agentTargetID == WebInspectorTarget.ID("page"))
}

@Test
func canonicalModelStoreResolvesNetworkRequestOriginWithoutReplacingUnknownTargets() throws {
    let page = canonicalModelPageTarget()
    let frame = canonicalModelFrameTarget()
    var fixture = try CanonicalModelStoreFixture(
        domains: [.network, .dom],
        targets: [page, frame]
    )
    let deliveryScope = fixture.scope(
        targetID: "page",
        agentTargetID: "page"
    )

    let firstWorker = try fixture.event(
        .network(
            canonicalRequestWillBeSent(
                id: "worker-one",
                url: "https://example.test/worker-one",
                initiatorNodeID: "worker-node",
                originFrameID: "isolated-frame",
                originLoaderID: "worker-loader",
                originTargetID: "worker-origin",
                mappedFrameTargetID: "frame-agent",
                timestamp: 1
            )
        ),
        scope: fixture.scope(
            targetID: "frame-agent",
            agentTargetID: "page"
        )
    )
    guard case let .insert(firstWorkerRecord, _) = try #require(
        firstWorker.network?.requestChanges.first
    ) else {
        Issue.record("Expected the first worker-origin request insertion.")
        return
    }
    #expect(firstWorkerRecord.id.agentTargetID == WebInspectorTarget.ID("page"))
    #expect(
        firstWorkerRecord.membership.origin
            == .protocolTarget(WebInspectorTarget.ID("worker-origin"))
    )
    #expect(firstWorkerRecord.membership.targetAuthority == nil)
    #expect(firstWorkerRecord.membership.frameID == FrameID("isolated-frame"))
    #expect(firstWorkerRecord.membership.loaderID == "worker-loader")
    guard case let .opaqueInitiator(workerGroup) = try #require(
        fixture.store.snapshot(reason: .onDemandRebase)
            .network?.entries.first?.record.groupKey
    ) else {
        Issue.record("Expected opaque worker-origin grouping.")
        return
    }
    #expect(workerGroup.semanticTargetID == WebInspectorTarget.ID("worker-origin"))
    #expect(workerGroup.targetAuthority == nil)

    _ = try fixture.event(
        .network(
            canonicalRequestWillBeSent(
                id: "worker-two",
                url: "https://example.test/worker-two",
                initiatorNodeID: "worker-node",
                originFrameID: "isolated-frame",
                originLoaderID: "worker-loader",
                originTargetID: "worker-origin",
                mappedFrameTargetID: "frame-agent",
                timestamp: 2
            )
        ),
        scope: deliveryScope
    )
    let workerEntry = try #require(
        fixture.store.snapshot(reason: .onDemandRebase)
            .network?.entries.first?.record
    )
    #expect(workerEntry.requestIDs.count == 2)

    let mapped = try fixture.event(
        .network(
            canonicalRequestWillBeSent(
                id: "mapped-frame",
                url: "https://example.test/frame",
                originFrameID: "isolated-frame",
                originLoaderID: "frame-loader",
                mappedFrameTargetID: "frame-agent",
                timestamp: 3
            )
        ),
        scope: deliveryScope
    )
    guard case let .insert(mappedRecord, _) = try #require(
        mapped.network?.requestChanges.first
    ) else {
        Issue.record("Expected the mapped-frame request insertion.")
        return
    }
    #expect(
        mappedRecord.membership.origin
            == .mappedFrame(
                frameID: FrameID("isolated-frame"),
                targetID: WebInspectorTarget.ID("frame-agent")
            )
    )
    #expect(
        mappedRecord.membership.targetAuthority?.navigationEpoch
            == ModelNavigationEpoch(rawValue: 1)
    )

    let fallback = try fixture.event(
        .network(
            canonicalRequestWillBeSent(
                id: "event-fallback",
                url: "https://example.test/fallback",
                originFrameID: "ordinary-frame",
                originLoaderID: "ordinary-loader",
                timestamp: 4
            )
        ),
        scope: deliveryScope
    )
    guard case let .insert(fallbackRecord, _) = try #require(
        fallback.network?.requestChanges.first
    ) else {
        Issue.record("Expected the event-fallback request insertion.")
        return
    }
    #expect(
        fallbackRecord.membership.origin
            == .eventTarget(WebInspectorTarget.ID("page"))
    )

    let beforeUnavailableMapping = fixture.store.snapshot(
        reason: .onDemandRebase
    )
    #expect(throws: WebInspectorCanonicalModelStoreError.self) {
        try fixture.event(
            .network(
                canonicalRequestWillBeSent(
                    id: "unavailable-frame-target",
                    url: "https://example.test/unavailable",
                    originFrameID: "missing-frame",
                    mappedFrameTargetID: "missing-target",
                    timestamp: 4.5
                )
            ),
            scope: deliveryScope
        )
    }
    #expect(
        fixture.store.snapshot(reason: .onDemandRebase)
            == beforeUnavailableMapping
    )

    let redirect = try fixture.event(
        .network(
            canonicalRequestWillBeSent(
                id: "mapped-frame",
                url: "https://example.test/frame-redirected",
                redirectResponse: Network.Response(
                    url: "https://example.test/frame",
                    status: 302
                ),
                originFrameID: "missing-frame",
                originLoaderID: "other-loader",
                mappedFrameTargetID: "missing-target",
                timestamp: 4.75
            )
        ),
        scope: deliveryScope
    )
    guard case let .update(redirectID, _, _) = try #require(
        redirect.network?.requestChanges.first
    ) else {
        Issue.record("Expected a redirect update.")
        return
    }
    let redirectedRecord = try #require(
        fixture.store.snapshot(reason: .onDemandRebase)
            .network?.requests.first(where: { $0.record.id == redirectID })?
            .record
    )
    #expect(redirectedRecord.membership == mappedRecord.membership)

    let response = try fixture.event(
        .network(
            .responseReceived(
                id: Network.Request.ID("mapped-frame"),
                response: Network.Response(
                    url: "https://example.test/frame-redirected",
                    status: 200
                ),
                resourceType: .fetch,
                timestamp: 5
            )
        ),
        scope: fixture.scope(
            targetID: "frame-agent",
            agentTargetID: "page"
        )
    )
    guard case let .update(responseID, _, _) = try #require(
        response.network?.requestChanges.first
    ) else {
        Issue.record("Expected a response update.")
        return
    }
    let responseRecord = try #require(
        fixture.store.snapshot(reason: .onDemandRebase)
            .network?.requests.first(where: { $0.record.id == responseID })?
            .record
    )
    #expect(responseRecord.membership == mappedRecord.membership)

    let targetLoss = try fixture.event(
        .target(.targetDestroyed),
        scope: fixture.scope(targetID: "frame-agent")
    )
    #expect(
        targetLoss.network?.requestChanges == [
            .delete(mappedRecord.id)
        ]
    )
    let lateRedirect = try fixture.event(
        .network(
            canonicalRequestWillBeSent(
                id: "mapped-frame",
                url: "https://example.test/too-late",
                redirectResponse: Network.Response(
                    url: "https://example.test/frame-redirected",
                    status: 302
                ),
                originFrameID: "missing-frame",
                originLoaderID: "late-loader",
                mappedFrameTargetID: "missing-target",
                timestamp: 6
            )
        ),
        scope: deliveryScope
    )
    #expect(lateRedirect.network == nil)
}

@Test
func canonicalNetworkGroupingIgnoresUnrelatedFrameNavigation() throws {
    let page = canonicalModelPageTarget()
    let frameA = canonicalModelFrameTarget(
        id: "frame-a",
        frameID: "frame-a"
    )
    let frameB = canonicalModelFrameTarget(
        id: "frame-b",
        frameID: "frame-b"
    )
    var fixture = try CanonicalModelStoreFixture(
        domains: [.network],
        targets: [page, frameA, frameB]
    )
    let deliveryScope = fixture.scope()

    _ = try fixture.event(
        .network(
            canonicalRequestWillBeSent(
                id: "frame-a-before",
                url: "https://example.test/a-before",
                initiatorNodeID: "node-a",
                originFrameID: "frame-a",
                mappedFrameTargetID: "frame-a",
                timestamp: 1
            )
        ),
        scope: deliveryScope
    )
    _ = try fixture.event(
        .target(
            .frameNavigated(
                canonicalModelFrameLifecycle(
                    id: "frame-b",
                    parentID: "main-frame"
                ),
                isNewLoader: true
            )
        ),
        scope: fixture.scope(
            targetID: "frame-b",
            navigationEpoch: 2
        )
    )
    _ = try fixture.event(
        .network(
            canonicalRequestWillBeSent(
                id: "frame-a-after",
                url: "https://example.test/a-after",
                initiatorNodeID: "node-a",
                originFrameID: "frame-a",
                mappedFrameTargetID: "frame-a",
                timestamp: 2
            )
        ),
        scope: deliveryScope
    )

    let entries = try #require(
        fixture.store.snapshot(reason: .onDemandRebase).network?.entries
    )
    #expect(entries.count == 1)
    #expect(entries[0].record.requestIDs.map(\.rawRequestID) == [
        Network.Request.ID("frame-a-before"),
        Network.Request.ID("frame-a-after"),
    ])
    guard case let .opaqueInitiator(groupKey) = entries[0].record.groupKey else {
        Issue.record("Expected opaque frame initiator grouping.")
        return
    }
    #expect(groupKey.semanticTargetID == WebInspectorTarget.ID("frame-a"))
    #expect(
        groupKey.targetAuthority?.navigationEpoch
            == ModelNavigationEpoch(rawValue: 1)
    )
}

@Test
func canonicalModelStoreResolvesConsoleReferenceAtWebSocketIdentityReservation() throws {
    var fixture = try CanonicalModelStoreFixture(domains: [.network, .console])
    let console = try fixture.event(
        .console(
            .messageAdded(
                canonicalModelConsoleMessage(
                    text: "socket",
                    networkRequestID: "socket"
                )
            )
        ),
        scope: fixture.scope()
    )
    let consoleTransaction = try #require(console.consoleRuntime)
    guard
        case let .insert(message, _) = try #require(
            consoleTransaction.consoleMessageChanges.first
        )
    else {
        Issue.record("Expected Console insertion.")
        return
    }

    let reservation = try fixture.event(
        .network(
            .webSocket(
                .created(
                    id: Network.Request.ID("socket"),
                    url: "wss://example.test/socket"
                )
            )
        ),
        scope: fixture.scope()
    )
    #expect(reservation.network == nil)
    let resolution = try #require(reservation.consoleRuntime)
    guard
        case let .update(id, .networkRequestReference(reference), _) =
            try #require(resolution.consoleMessageChanges.first)
    else {
        Issue.record("Expected pending Console resolution at WebSocket reservation.")
        return
    }
    #expect(id == message.id)
    guard case let .resolved(_, requestID) = reference else {
        Issue.record("Expected a resolved WebSocket request identity.")
        return
    }
    #expect(requestID.rawRequestID == Network.Request.ID("socket"))
}

@Test
func canonicalModelStoreAtomicallyInvalidatesDOMAndCSSDocumentState() throws {
    var fixture = try CanonicalModelStoreFixture(domains: [.css])
    _ = try fixture.bootstrapDOM(
        root: canonicalModelDocument(
            id: "document",
            children: [canonicalModelDOMNode(id: "body")]
        )
    )
    _ = try fixture.bootstrapCSS([
        (
            targetID: "page",
            header: canonicalModelStyleSheet(id: "sheet", frameID: "main-frame")
        )
    ])

    let invalidationScope = fixture.scope(DOMBindingEpoch: 2)
    let transaction = try fixture.store.reduce(
        .domDocumentInvalidated(
            sequence: fixture.nextSequence,
            scope: invalidationScope
        ),
        attachmentGeneration: fixture.attachmentGeneration
    )
    fixture.nextSequence += 1
    #expect(transaction.DOM?.deletedRecordIDs.count == 2)
    #expect(transaction.CSS?.deletedRecordIDs.count == 1)
    #expect(fixture.store.bindingSnapshot?.readyDOMTargetIDs.isEmpty == true)
    #expect(fixture.store.bindingSnapshot?.isCSSReady == false)
    let afterInvalidation = fixture.store.snapshot(reason: .onDemandRebase)
    #expect(afterInvalidation.DOM?.recordsByID.isEmpty == true)
    #expect(afterInvalidation.CSS?.recordsByID.isEmpty == true)

    let malformedScope = fixture.scope(DOMBindingEpoch: 4)
    #expect(throws: WebInspectorCanonicalModelStoreError.self) {
        try fixture.store.reduce(
            .domDocumentInvalidated(
                sequence: fixture.nextSequence,
                scope: malformedScope
            ),
            attachmentGeneration: fixture.attachmentGeneration
        )
    }
    #expect(
        fixture.store.snapshot(reason: .onDemandRebase)
            == afterInvalidation
    )
}

@Test
func canonicalModelStorePropagatesTargetLossAcrossEveryCanonicalDomain() throws {
    let page = canonicalModelPageTarget()
    let frame = canonicalModelFrameTarget()
    var fixture = try CanonicalModelStoreFixture(
        domains: [.dom, .css, .network, .runtime, .console],
        targets: [page, frame]
    )
    let frameOwner = canonicalModelDOMNode(
        id: "frame-owner",
        name: "IFRAME",
        localName: "iframe",
        frameID: "isolated-frame"
    )
    _ = try fixture.bootstrapDOM(
        root: canonicalModelDocument(
            id: "page-document",
            children: [frameOwner]
        )
    )
    _ = try fixture.bootstrapDOM(
        targetID: "frame-agent",
        root: canonicalModelDocument(
            id: "frame-document",
            frameID: "isolated-frame"
        )
    )
    _ = try fixture.bootstrapCSS([
        (
            targetID: "frame-agent",
            header: canonicalModelStyleSheet(
                id: "frame-sheet",
                frameID: "isolated-frame"
            )
        )
    ])
    let frameScope = fixture.scope(targetID: "frame-agent")
    _ = try fixture.event(
        .network(
            canonicalRequestWillBeSent(
                id: "frame-request",
                url: "https://frame.example.test/",
                timestamp: 1
            )
        ),
        scope: frameScope
    )
    _ = try fixture.event(
        .runtime(
            .executionContextCreated(
                canonicalModelRuntimeContext(
                    id: "frame-context",
                    frameID: "isolated-frame"
                )
            )
        ),
        scope: frameScope
    )
    _ = try fixture.event(
        .console(.messageAdded(canonicalModelConsoleMessage(text: "frame"))),
        scope: frameScope
    )

    let loss = try fixture.event(
        .target(.targetDestroyed),
        scope: frameScope
    )
    #expect(loss.network?.requestChanges.count == 1)
    #expect(loss.DOM?.deletedRecordIDs.count == 1)
    #expect(loss.CSS?.deletedRecordIDs.count == 1)
    #expect(loss.consoleRuntime?.runtimeContextChanges.count == 1)
    #expect(loss.consoleRuntime?.consoleMessageChanges.count == 1)
    #expect(
        loss.feedChanges == [
            .targetRemoved(WebInspectorTarget.ID("frame-agent"))
        ]
    )

    let snapshot = fixture.store.snapshot(reason: .onDemandRebase)
    #expect(snapshot.network?.requests.isEmpty == true)
    #expect(snapshot.consoleRuntime?.runtimeContexts.isEmpty == true)
    #expect(snapshot.consoleRuntime?.consoleMessages.isEmpty == true)
    #expect(snapshot.CSS?.recordsByID.isEmpty == true)
    #expect(snapshot.DOM?.recordsByID.count == 2)
}

@Test
func canonicalModelStoreRemovesNetworkMembershipWhenOnlySemanticTargetIsLost() throws {
    let page = canonicalModelPageTarget()
    let frame = canonicalModelFrameTarget()
    var fixture = try CanonicalModelStoreFixture(
        domains: [.network],
        targets: [page, frame]
    )
    let routedThroughRoot = fixture.scope(
        targetID: "frame-agent",
        agentTargetID: "page"
    )
    _ = try fixture.event(
        .network(
            canonicalRequestWillBeSent(
                id: "semantic-frame-request",
                url: "https://frame.example.test/root-agent",
                timestamp: 1
            )
        ),
        scope: routedThroughRoot
    )
    _ = try fixture.event(
        .network(
            .webSocket(
                .created(
                    id: Network.Request.ID("semantic-frame-socket"),
                    url: "wss://frame.example.test/socket"
                )
            )
        ),
        scope: routedThroughRoot
    )

    let loss = try fixture.event(
        .target(.targetDestroyed),
        scope: fixture.scope(targetID: "frame-agent")
    )
    #expect(loss.network?.requestChanges.count == 1)
    #expect(fixture.store.networkRequestID(forRawRequestID: Network.Request.ID("semantic-frame-request")) == nil)
    #expect(fixture.store.networkRequestID(forRawRequestID: Network.Request.ID("semantic-frame-socket")) == nil)
    #expect(
        fixture.store.networkPerformanceCountersForTesting.targetLossIndexLookupCount
            == 2
    )
    #expect(
        fixture.store.networkPerformanceCountersForTesting.targetLossFullScanCount
            == 0
    )
}

@Test
func canonicalModelStoreProvisionalReplacementAtomicallyRemovesOldTargetAndInstallsNewAuthority() throws {
    let page = canonicalModelPageTarget()
    let oldFrame = canonicalModelFrameTarget(id: "old-frame-agent")
    var fixture = try CanonicalModelStoreFixture(
        domains: [.network],
        targets: [page, oldFrame]
    )
    _ = try fixture.event(
        .network(
            canonicalRequestWillBeSent(
                id: "old-request",
                url: "https://old.example.test/",
                timestamp: 1
            )
        ),
        scope: fixture.scope(
            targetID: "old-frame-agent",
            agentTargetID: "page"
        )
    )

    let newFrame = canonicalModelFrameTarget(id: "new-frame-agent")
    let newScope = ModelEventScope(
        generation: fixture.pageGeneration,
        target: newFrame,
        agentTarget: newFrame,
        navigationEpoch: ModelNavigationEpoch(rawValue: 1),
        domBindingEpoch: nil,
        runtimeBindingEpoch: nil,
        consoleBindingEpoch: nil
    )
    let replacement = try fixture.event(
        .target(
            .didCommitProvisionalTarget(
                oldTargetID: WebInspectorTarget.ID("old-frame-agent")
            )
        ),
        scope: newScope
    )

    #expect(replacement.network?.requestChanges.count == 1)
    #expect(
        replacement.feedChanges == [
            .provisionalTargetCommitted(
                oldTargetID: WebInspectorTarget.ID("old-frame-agent"),
                newTarget: newFrame
            )
        ]
    )
    #expect(
        fixture.store.bindingSnapshot?.targets.map(\.target.id).contains(
            WebInspectorTarget.ID("new-frame-agent")
        ) == true
    )
    #expect(
        fixture.store.bindingSnapshot?.targets.map(\.target.id).contains(
            WebInspectorTarget.ID("old-frame-agent")
        ) == false
    )
}

@Test
func canonicalModelStoreAcceptsOrdinaryAndNestedFrameLifecycleOnTheirDeliveryAgents() throws {
    let page = canonicalModelPageTarget()
    let frameAgent = canonicalModelFrameTarget()
    var fixture = try CanonicalModelStoreFixture(
        domains: [.dom, .runtime],
        targets: [page, frameAgent]
    )
    let ordinaryDocument = canonicalModelDocument(id: "ordinary-document")
    let ordinaryOwner = canonicalModelDOMNode(
        id: "ordinary-owner",
        name: "IFRAME",
        localName: "iframe",
        frameID: "ordinary-frame",
        contentDocument: ordinaryDocument
    )
    _ = try fixture.bootstrapDOM(
        root: canonicalModelDocument(
            id: "page-document",
            children: [ordinaryOwner]
        )
    )
    let nestedDocument = canonicalModelDocument(id: "nested-document")
    let nestedOwner = canonicalModelDOMNode(
        id: "nested-owner",
        name: "IFRAME",
        localName: "iframe",
        frameID: "nested-ordinary-frame",
        contentDocument: nestedDocument
    )
    _ = try fixture.bootstrapDOM(
        targetID: "frame-agent",
        root: canonicalModelDocument(
            id: "isolated-document",
            frameID: "isolated-frame",
            children: [nestedOwner]
        )
    )
    _ = try fixture.event(
        .runtime(
            .executionContextCreated(
                canonicalModelRuntimeContext(
                    id: "ordinary-context",
                    frameID: "ordinary-frame"
                )
            )
        ),
        scope: fixture.scope()
    )
    for (id, frameID) in [
        ("main-context", "main-frame"),
        ("sibling-context", "sibling-frame"),
    ] {
        _ = try fixture.event(
            .runtime(
                .executionContextCreated(
                    canonicalModelRuntimeContext(id: id, frameID: frameID)
                )
            ),
            scope: fixture.scope()
        )
    }
    _ = try fixture.event(
        .runtime(
            .executionContextCreated(
                canonicalModelRuntimeContext(
                    id: "nested-context",
                    frameID: "nested-ordinary-frame"
                )
            )
        ),
        scope: fixture.scope(targetID: "frame-agent")
    )

    let ordinaryNavigation = try fixture.event(
        .target(
            .frameNavigated(
                canonicalModelFrameLifecycle(
                    id: "ordinary-frame",
                    parentID: "main-frame"
                ),
                isNewLoader: true
            )
        ),
        scope: fixture.scope(runtimeBindingEpoch: 2)
    )
    #expect(
        ordinaryNavigation.feedChanges == [
            .frameNavigated(
                frameID: FrameID("ordinary-frame"),
                deliveryTargetID: WebInspectorTarget.ID("page"),
                navigationEpoch: ModelNavigationEpoch(rawValue: 1)
            )
        ]
    )
    #expect(ordinaryNavigation.consoleRuntime?.runtimeContextChanges.count == 1)
    #expect(
        ordinaryNavigation.consoleRuntime?.resourceInvalidations == [
            .runtimeBinding(
                agentTargetID: WebInspectorTarget.ID("page"),
                epoch: ModelRuntimeBindingEpoch(rawValue: 2)
            )
        ]
    )
    #expect(
        fixture.store.snapshot(reason: .onDemandRebase)
            .consoleRuntime?.runtimeContexts.count == 3)

    _ = try fixture.event(
        .runtime(
            .executionContextCreated(
                canonicalModelRuntimeContext(
                    id: "ordinary-context-new",
                    frameID: "ordinary-frame"
                )
            )
        ),
        scope: fixture.scope(runtimeBindingEpoch: 2)
    )
    let duplicateOrdinaryNavigation = try fixture.event(
        .target(
            .frameNavigated(
                canonicalModelFrameLifecycle(
                    id: "ordinary-frame",
                    parentID: "main-frame"
                ),
                isNewLoader: false
            )
        ),
        scope: fixture.scope(runtimeBindingEpoch: 2)
    )
    #expect(duplicateOrdinaryNavigation.consoleRuntime == nil)

    let ordinaryDetach = try fixture.event(
        .target(.frameDetached(frameID: FrameID("ordinary-frame"))),
        scope: fixture.scope(runtimeBindingEpoch: 2)
    )
    #expect(ordinaryDetach.DOM?.deletedRecordIDs.count == 1)
    #expect(ordinaryDetach.consoleRuntime?.runtimeContextChanges.count == 1)

    let nestedNavigation = try fixture.event(
        .target(
            .frameNavigated(
                canonicalModelFrameLifecycle(
                    id: "nested-ordinary-frame",
                    parentID: "isolated-frame"
                ),
                isNewLoader: true
            )
        ),
        scope: fixture.scope(
            targetID: "frame-agent",
            runtimeBindingEpoch: 2
        )
    )
    #expect(
        nestedNavigation.feedChanges == [
            .frameNavigated(
                frameID: FrameID("nested-ordinary-frame"),
                deliveryTargetID: WebInspectorTarget.ID("frame-agent"),
                navigationEpoch: ModelNavigationEpoch(rawValue: 1)
            )
        ]
    )
    #expect(nestedNavigation.consoleRuntime?.runtimeContextChanges.count == 1)
    #expect(
        nestedNavigation.consoleRuntime?.resourceInvalidations == [
            .runtimeBinding(
                agentTargetID: WebInspectorTarget.ID("frame-agent"),
                epoch: ModelRuntimeBindingEpoch(rawValue: 2)
            )
        ]
    )
    let nestedDetach = try fixture.event(
        .target(.frameDetached(frameID: FrameID("nested-ordinary-frame"))),
        scope: fixture.scope(
            targetID: "frame-agent",
            runtimeBindingEpoch: 2
        )
    )
    #expect(nestedDetach.DOM?.deletedRecordIDs.count == 1)
    #expect(nestedDetach.consoleRuntime?.runtimeContextChanges.isEmpty == true)
    #expect(fixture.store.bindingSnapshot?.targets.count == 2)
}

@Test
func canonicalModelStoreKeepsNewContextsAcrossDuplicateCrossAgentNavigation() throws {
    let page = canonicalModelPageTarget()
    let frameAgent = canonicalModelFrameTarget()
    var fixture = try CanonicalModelStoreFixture(
        domains: [.runtime],
        targets: [page, frameAgent]
    )
    _ = try fixture.event(
        .runtime(
            .executionContextCreated(
                canonicalModelRuntimeContext(
                    id: "old-frame-context",
                    frameID: "isolated-frame"
                )
            )
        ),
        scope: fixture.scope(
            targetID: "frame-agent",
            agentTargetID: "page"
        )
    )

    let firstDelivery = try fixture.event(
        .target(
            .frameNavigated(
                canonicalModelFrameLifecycle(
                    id: "isolated-frame",
                    parentID: "main-frame"
                ),
                isNewLoader: true
            )
        ),
        scope: fixture.scope(
            targetID: "frame-agent",
            agentTargetID: "page",
            navigationEpoch: 2,
            runtimeBindingEpoch: 2
        )
    )
    #expect(firstDelivery.consoleRuntime?.runtimeContextChanges.count == 1)

    _ = try fixture.event(
        .runtime(
            .executionContextCreated(
                canonicalModelRuntimeContext(
                    id: "new-frame-context",
                    frameID: "isolated-frame"
                )
            )
        ),
        scope: fixture.scope(
            targetID: "frame-agent",
            navigationEpoch: 2
        )
    )
    let duplicateDelivery = try fixture.event(
        .target(
            .frameNavigated(
                canonicalModelFrameLifecycle(
                    id: "isolated-frame",
                    parentID: "main-frame"
                ),
                isNewLoader: false
            )
        ),
        scope: fixture.scope(
            targetID: "frame-agent",
            navigationEpoch: 2,
            runtimeBindingEpoch: 2
        )
    )

    #expect(duplicateDelivery.consoleRuntime?.runtimeContextChanges.isEmpty == true)
    #expect(
        duplicateDelivery.consoleRuntime?.resourceInvalidations == [
            .runtimeBinding(
                agentTargetID: WebInspectorTarget.ID("frame-agent"),
                epoch: ModelRuntimeBindingEpoch(rawValue: 2)
            )
        ]
    )
    #expect(
        fixture.store.snapshot(reason: .onDemandRebase)
            .consoleRuntime?.runtimeContexts.map(\.record.id.rawContextID)
            == [Runtime.ExecutionContext.ID("new-frame-context")]
    )
}

@Test
func canonicalModelStoreDeduplicatesOrdinaryFrameCleanupAcrossAgents() throws {
    let page = canonicalModelPageTarget()
    let frameAgent = canonicalModelFrameTarget()
    var fixture = try CanonicalModelStoreFixture(
        domains: [.runtime],
        targets: [page, frameAgent]
    )
    _ = try fixture.event(
        .runtime(
            .executionContextCreated(
                canonicalModelRuntimeContext(
                    id: "old-ordinary-context",
                    frameID: "shared-ordinary-frame"
                )
            )
        ),
        scope: fixture.scope()
    )
    let frame = canonicalModelFrameLifecycle(
        id: "shared-ordinary-frame",
        parentID: "isolated-frame"
    )
    let firstDelivery = try fixture.event(
        .target(.frameNavigated(frame, isNewLoader: true)),
        scope: fixture.scope(runtimeBindingEpoch: 2)
    )
    #expect(firstDelivery.consoleRuntime?.runtimeContextChanges.count == 1)

    _ = try fixture.event(
        .runtime(
            .executionContextCreated(
                canonicalModelRuntimeContext(
                    id: "new-ordinary-context",
                    frameID: "shared-ordinary-frame"
                )
            )
        ),
        scope: fixture.scope(targetID: "frame-agent")
    )
    let duplicateDelivery = try fixture.event(
        .target(.frameNavigated(frame, isNewLoader: false)),
        scope: fixture.scope(
            targetID: "frame-agent",
            runtimeBindingEpoch: 2
        )
    )

    #expect(duplicateDelivery.consoleRuntime?.runtimeContextChanges.isEmpty == true)
    #expect(
        duplicateDelivery.consoleRuntime?.resourceInvalidations == [
            .runtimeBinding(
                agentTargetID: WebInspectorTarget.ID("frame-agent"),
                epoch: ModelRuntimeBindingEpoch(rawValue: 2)
            )
        ]
    )
    #expect(
        fixture.store.snapshot(reason: .onDemandRebase)
            .consoleRuntime?.runtimeContexts.map(\.record.id.rawContextID)
            == [Runtime.ExecutionContext.ID("new-ordinary-context")]
    )
}

@Test
func canonicalModelStoreAppliesRuntimeAndConsoleEpochsAtTheirOwnBoundaries() throws {
    var fixture = try CanonicalModelStoreFixture(domains: [.runtime, .console])
    _ = try fixture.event(
        .runtime(
            .executionContextCreated(
                canonicalModelRuntimeContext(
                    id: "context",
                    frameID: "main-frame"
                )
            )
        ),
        scope: fixture.scope()
    )
    _ = try fixture.event(
        .console(.messageAdded(canonicalModelConsoleMessage(text: "message"))),
        scope: fixture.scope()
    )

    let navigationScope = fixture.scope(
        navigationEpoch: 2,
        runtimeBindingEpoch: 2,
        consoleBindingEpoch: 1
    )
    let navigation = try fixture.event(
        .target(
            .frameNavigated(
                canonicalModelFrameLifecycle(
                    id: "main-frame",
                    parentID: "main-frame"
                ),
                isNewLoader: true
            )
        ),
        scope: navigationScope
    )
    #expect(navigation.consoleRuntime?.runtimeContextChanges.count == 1)
    #expect(
        navigation.consoleRuntime?.resourceInvalidations == [
            .runtimeBinding(
                agentTargetID: WebInspectorTarget.ID("page"),
                epoch: ModelRuntimeBindingEpoch(rawValue: 2)
            ),
            .semanticNavigation(
                semanticTargetID: WebInspectorTarget.ID("page"),
                navigationEpoch: ModelNavigationEpoch(rawValue: 2)
            ),
        ]
    )

    let duplicateNavigation = try fixture.event(
        .target(
            .frameNavigated(
                canonicalModelFrameLifecycle(
                    id: "main-frame",
                    parentID: "main-frame"
                ),
                isNewLoader: false
            )
        ),
        scope: navigationScope
    )
    #expect(duplicateNavigation.consoleRuntime == nil)

    let clearConsole = try fixture.event(
        .console(
            .messagesCleared(
                reason: Console.ClearReason(rawValue: "frontend")
            )
        ),
        scope: fixture.scope(
            navigationEpoch: 2,
            runtimeBindingEpoch: 2,
            consoleBindingEpoch: 2
        )
    )
    #expect(clearConsole.consoleRuntime?.consoleMessageChanges.count == 1)
    #expect(
        clearConsole.consoleRuntime?.resourceInvalidations == [
            .consoleBinding(
                agentTargetID: WebInspectorTarget.ID("page"),
                epoch: ModelConsoleBindingEpoch(rawValue: 2)
            )
        ]
    )

    let beforeMalformed = fixture.store.snapshot(reason: .onDemandRebase)
    #expect(throws: WebInspectorCanonicalModelStoreError.self) {
        try fixture.event(
            .runtime(.executionContextsCleared),
            scope: fixture.scope(
                navigationEpoch: 2,
                runtimeBindingEpoch: 4,
                consoleBindingEpoch: 2
            )
        )
    }
    #expect(
        fixture.store.snapshot(reason: .onDemandRebase)
            == beforeMalformed
    )
}

@Test
func canonicalModelStoreResetScopesIdentitiesWithoutReusingOrdinals() throws {
    var fixture = try CanonicalModelStoreFixture(domains: [.network, .console])
    let firstNetwork = try fixture.event(
        .network(
            canonicalRequestWillBeSent(
                id: "same",
                url: "https://example.test/first",
                timestamp: 1
            )
        ),
        scope: fixture.scope()
    )
    guard
        case let .insert(firstRequest, _) = try #require(
            firstNetwork.network?.requestChanges.first
        )
    else {
        Issue.record("Expected first request.")
        return
    }
    let firstConsole = try fixture.event(
        .console(.messageAdded(canonicalModelConsoleMessage(text: "first"))),
        scope: fixture.scope()
    )
    guard
        case let .insert(firstMessage, _) = try #require(
            firstConsole.consoleRuntime?.consoleMessageChanges.first
        )
    else {
        Issue.record("Expected first Console message.")
        return
    }

    let nextPage = WebInspectorPage.Generation(rawValue: 2)
    let reset = try fixture.store.reduce(
        .reset(nextPage),
        attachmentGeneration: fixture.attachmentGeneration
    )
    #expect(reset.network?.requestChanges.count == 1)
    #expect(reset.consoleRuntime?.consoleMessageChanges.count == 1)
    let page = canonicalModelPageTarget()
    _ = try fixture.store.reduce(
        .targetSnapshot(
            generation: nextPage,
            through: 0,
            snapshot: ModelTargetSnapshot(
                currentPageID: page.id,
                targets: [
                    ModelTargetState(
                        target: page,
                        navigationEpoch: ModelNavigationEpoch(rawValue: 1),
                        domBindingEpoch: nil,
                        runtimeBindingEpoch: ModelRuntimeBindingEpoch(rawValue: 1),
                        consoleBindingEpoch: ModelConsoleBindingEpoch(rawValue: 1)
                    )
                ]
            )
        ),
        attachmentGeneration: fixture.attachmentGeneration
    )
    let nextScope = ModelEventScope(
        generation: nextPage,
        target: page,
        agentTarget: page,
        navigationEpoch: ModelNavigationEpoch(rawValue: 1),
        domBindingEpoch: nil,
        runtimeBindingEpoch: ModelRuntimeBindingEpoch(rawValue: 1),
        consoleBindingEpoch: ModelConsoleBindingEpoch(rawValue: 1)
    )
    let secondNetwork = try fixture.store.reduce(
        .event(
            sequence: 1,
            scope: nextScope,
            payload: .network(
                canonicalRequestWillBeSent(
                    id: "same",
                    url: "https://example.test/second",
                    timestamp: 2
                )
            )
        ),
        attachmentGeneration: fixture.attachmentGeneration
    )
    guard
        case let .insert(secondRequest, _) = try #require(
            secondNetwork.network?.requestChanges.first
        )
    else {
        Issue.record("Expected second request.")
        return
    }
    let secondConsole = try fixture.store.reduce(
        .event(
            sequence: 2,
            scope: nextScope,
            payload: .console(
                .messageAdded(canonicalModelConsoleMessage(text: "second"))
            )
        ),
        attachmentGeneration: fixture.attachmentGeneration
    )
    guard
        case let .insert(secondMessage, _) = try #require(
            secondConsole.consoleRuntime?.consoleMessageChanges.first
        )
    else {
        Issue.record("Expected second Console message.")
        return
    }
    #expect(secondRequest.id != firstRequest.id)
    #expect(secondRequest.id.pageGeneration == nextPage)
    #expect(secondMessage.id.ordinal > firstMessage.id.ordinal)

    let beforeInvalidReset = fixture.store.snapshot(reason: .onDemandRebase)
    #expect(throws: WebInspectorCanonicalModelStoreError.self) {
        try fixture.store.reduce(
            .reset(nextPage),
            attachmentGeneration: fixture.attachmentGeneration
        )
    }
    #expect(
        fixture.store.snapshot(reason: .onDemandRebase)
            == beforeInvalidReset
    )

    let newAttachment = WebInspectorContainerAttachmentGeneration(rawValue: 2)
    _ = try fixture.store.reduce(
        .reset(WebInspectorPage.Generation(rawValue: 1)),
        attachmentGeneration: newAttachment
    )
    #expect(
        fixture.store.bindingSnapshot?.attachmentGeneration
            == newAttachment
    )
}

@Test
func canonicalModelStoreDetachResetClearsEveryDomainAndRetainsGenerationAuthority() throws {
    var fixture = try CanonicalModelStoreFixture(
        domains: [.dom, .css, .network, .runtime, .console]
    )
    _ = try fixture.bootstrapDOM(
        root: canonicalModelDocument(
            id: "document",
            frameID: "main-frame"
        )
    )
    _ = try fixture.bootstrapCSS([
        (
            targetID: "page",
            header: canonicalModelStyleSheet(
                id: "sheet",
                frameID: "main-frame"
            )
        )
    ])
    _ = try fixture.event(
        .network(
            canonicalRequestWillBeSent(
                id: "request",
                url: "https://example.test/",
                timestamp: 1
            )
        ),
        scope: fixture.scope()
    )
    _ = try fixture.event(
        .runtime(
            .executionContextCreated(
                canonicalModelRuntimeContext(
                    id: "context",
                    frameID: "main-frame"
                )
            )
        ),
        scope: fixture.scope()
    )
    _ = try fixture.event(
        .console(.messageAdded(canonicalModelConsoleMessage(text: "message"))),
        scope: fixture.scope()
    )

    let transaction = fixture.store.clearForDetach()
    #expect(
        transaction.feedChanges == [
            .detached(
                attachmentGeneration: fixture.attachmentGeneration,
                pageGeneration: fixture.pageGeneration
            )
        ]
    )
    #expect(transaction.network?.requestChanges.count == 1)
    #expect(transaction.DOM?.deletedRecordIDs.count == 1)
    #expect(transaction.CSS?.deletedRecordIDs.count == 1)
    #expect(transaction.consoleRuntime?.runtimeContextChanges.count == 1)
    #expect(transaction.consoleRuntime?.consoleMessageChanges.count == 1)
    #expect(transaction.resetSnapshot?.binding == nil)
    #expect(transaction.resetSnapshot?.network?.requests.isEmpty == true)
    #expect(transaction.resetSnapshot?.DOM?.recordsByID.isEmpty == true)
    #expect(transaction.resetSnapshot?.CSS?.recordsByID.isEmpty == true)
    #expect(
        transaction.resetSnapshot?.consoleRuntime?.runtimeContexts.isEmpty
            == true
    )
    #expect(
        transaction.resetSnapshot?.consoleRuntime?.consoleMessages.isEmpty
            == true
    )
    #expect(fixture.store.bindingSnapshot == nil)
    #expect(fixture.store.performanceCounters.resetSnapshotBuildCount == 1)

    #expect(fixture.store.clearForDetach().isEmpty)
    #expect(fixture.store.performanceCounters.resetSnapshotBuildCount == 1)
    #expect(throws: WebInspectorCanonicalModelStoreError.self) {
        try fixture.store.reduce(
            .reset(fixture.pageGeneration),
            attachmentGeneration: fixture.attachmentGeneration
        )
    }
    #expect(throws: WebInspectorCanonicalModelStoreError.self) {
        try fixture.store.reduce(
            .reset(
                WebInspectorPage.Generation(
                    rawValue: fixture.pageGeneration.rawValue + 1
                )
            ),
            attachmentGeneration: fixture.attachmentGeneration
        )
    }

    let nextAttachment = WebInspectorContainerAttachmentGeneration(rawValue: 2)
    _ = try fixture.store.reduce(
        .reset(WebInspectorPage.Generation(rawValue: 1)),
        attachmentGeneration: nextAttachment
    )
    #expect(
        fixture.store.bindingSnapshot?.attachmentGeneration == nextAttachment
    )
}

@Test
func canonicalModelStoreBuildsSnapshotsOnlyOnExplicitBoundaryAndNotForTenThousandDeltas() throws {
    var fixture = try CanonicalModelStoreFixture(domains: [.network])
    _ = try fixture.event(
        .network(
            canonicalRequestWillBeSent(
                id: "request",
                url: "https://example.test/stream",
                timestamp: 1
            )
        ),
        scope: fixture.scope()
    )
    let baselineFullRebuilds = fixture.store
        .networkPerformanceCountersForTesting.entryFullRebuildCount

    for index in 0..<10_000 {
        _ = try fixture.event(
            .network(
                .dataReceived(
                    id: Network.Request.ID("request"),
                    dataLength: 1,
                    encodedDataLength: 1,
                    timestamp: Double(index + 2)
                )
            ),
            scope: fixture.scope()
        )
    }

    #expect(fixture.store.performanceCounters.fullSnapshotBuildCount == 0)
    #expect(fixture.store.performanceCounters.fullSnapshotRecordVisitCount == 0)
    #expect(fixture.store.performanceCounters.unrelatedRecordScanCount == 0)
    #expect(
        fixture.store.networkPerformanceCountersForTesting.entryFullRebuildCount
            == baselineFullRebuilds
    )
    #expect(
        fixture.store.networkPerformanceCountersForTesting.entryIncrementalUpdateCount
            >= 10_000
    )

    let snapshot = fixture.store.snapshot(reason: .onDemandRebase)
    #expect(snapshot.network?.requests.count == 1)
    #expect(snapshot.network?.entries.count == 1)
    #expect(fixture.store.performanceCounters.fullSnapshotBuildCount == 1)
    #expect(fixture.store.performanceCounters.onDemandSnapshotBuildCount == 1)
    #expect(fixture.store.performanceCounters.fullSnapshotRecordVisitCount == 2)
}

@Test
func canonicalModelStoreAccountsOnlyExplicitInitialResetAndRebaseSnapshots() throws {
    var fixture = try CanonicalModelStoreFixture(domains: [.network])
    _ = fixture.store.snapshot(reason: .initial)
    _ = fixture.store.snapshot(reason: .reset)
    _ = fixture.store.snapshot(reason: .onDemandRebase)

    #expect(fixture.store.performanceCounters.fullSnapshotBuildCount == 3)
    #expect(fixture.store.performanceCounters.initialSnapshotBuildCount == 1)
    #expect(fixture.store.performanceCounters.resetSnapshotBuildCount == 1)
    #expect(fixture.store.performanceCounters.onDemandSnapshotBuildCount == 1)
}

@Test
func canonicalModelStoreDoesNotMutateBindingEpochMapsOrPublishForTenThousandNoOps() throws {
    var fixture = try CanonicalModelStoreFixture(
        domains: [.network, .console]
    )
    let scope = fixture.scope()
    var publicationCandidateCount = 0

    for index in 0..<10_000 {
        let transaction = try fixture.event(
            .network(
                .unknown(
                    RawEvent(
                        domain: "Network",
                        method: "ignored\(index)"
                    )
                )
            ),
            scope: scope
        )
        if !transaction.isEmpty {
            publicationCandidateCount += 1
        }
    }

    #expect(publicationCandidateCount == 0)
    #expect(fixture.store.performanceCounters.bindingEpochMapMutationCount == 0)
    #expect(fixture.store.performanceCounters.fullSnapshotBuildCount == 0)
    #expect(fixture.store.bindingSnapshot?.lastSequence == 10_000)
}
