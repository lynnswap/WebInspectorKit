import Foundation
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import WebInspectorTestSupport

private struct DOMCSSGatewayRuntime {
    let container: WebInspectorModelContainer
    let runtime: WebInspectorProxyTestRuntime
    let wire: WebInspectorRawWireDriver
    let domains: Set<WebInspectorModelContainer.Domain>

    static func start(
        domains: Set<WebInspectorModelContainer.Domain> = [.css],
        document: DOM.Node = gatewayDocument(),
        initialTarget: WebInspectorTestPeer.Target = .initialPage
    ) async throws -> Self {
        let runtime = try await WebInspectorProxyTestRuntime.start(
            initialTarget: initialTarget
        )
        let wire = WebInspectorRawWireDriver(peer: runtime.peer)
        await wire.start()
        await wire.respond(to: "Page.enable")
        if domains.contains(.css) {
            await wire.respond(to: "CSS.enable")
            await wire.respond(
                to: "CSS.getAllStyleSheets",
                with: try testJSONObject(#"{"headers":[]}"#)
            )
        }
        await wire.respond(
            to: "DOM.getDocument",
            with: try domDocumentResult(document)
        )
        if domains.contains(.css) {
            await wire.respond(to: "CSS.disable")
        }
        await wire.respond(to: "Page.disable")
        let container = WebInspectorModelContainer(
            configuration: .init(domains: domains)
        )
        try await container.attach(owning: runtime.proxy)
        return Self(
            container: container,
            runtime: runtime,
            wire: wire,
            domains: domains
        )
    }

    func close() async {
        await container.close()
        await runtime.close()
        await wire.stop()
    }
}

private func withDOMCSSGatewayRuntime<Output: Sendable>(
    domains: Set<WebInspectorModelContainer.Domain> = [.css],
    document: DOM.Node = gatewayDocument(),
    initialTarget: WebInspectorTestPeer.Target = .initialPage,
    _ operation: @escaping @Sendable (DOMCSSGatewayRuntime) async throws -> Output
) async throws -> Output {
    let runtime = try await DOMCSSGatewayRuntime.start(
        domains: domains,
        document: document,
        initialTarget: initialTarget
    )
    do {
        let output = try await operation(runtime)
        await runtime.close()
        return output
    } catch {
        await runtime.close()
        throw error
    }
}

@MainActor
private func withMainActorDOMCSSGatewayRuntime<Output: Sendable>(
    domains: Set<WebInspectorModelContainer.Domain> = [.css],
    document: DOM.Node = gatewayDocument(),
    initialTarget: WebInspectorTestPeer.Target = .initialPage,
    _ operation: @escaping @MainActor @Sendable (
        DOMCSSGatewayRuntime
    ) async throws -> Output
) async throws -> Output {
    let runtime = try await DOMCSSGatewayRuntime.start(
        domains: domains,
        document: document,
        initialTarget: initialTarget
    )
    do {
        let output = try await operation(runtime)
        await runtime.close()
        return output
    } catch {
        await runtime.close()
        throw error
    }
}

@Test
func DOMGatewayRoutesCurrentCanonicalNodeThroughItsPhysicalAgent()
    async throws
{
    try await withDOMCSSGatewayRuntime(domains: [.dom]) { fixture in
        let nodeID = try await canonicalDOMNodeID(
            rawValue: "body",
            in: fixture.container.core
        )
        await fixture.wire.respond(
            to: "DOM.getOuterHTML",
            with: try testJSONObject(#"{"outerHTML":"<body></body>"}"#)
        )

        let result = try await fixture.container.core.domOuterHTML(of: nodeID)
        #expect(result == "<body></body>")

        let command = try #require(
            fixture.wire.observations.commands.first {
                $0.method == "DOM.getOuterHTML"
            }
        )
        #expect(command.destination == .target("page-main"))
        let parameters = try command.parameters.decode(DOMNodeParameters.self)
        #expect(parameters.nodeId == "body")
    }
}

@MainActor
@Test
func modelContextRoutesCanonicalDOMMutationAndUndoThroughContainerCore()
    async throws
{
    try await withMainActorDOMCSSGatewayRuntime(domains: [.dom]) { fixture in
        let context = fixture.container.mainContext
        try await context.waitUntilContainerReady()
        let storage = try await canonicalDOMNodeID(
            rawValue: "body",
            in: fixture.container.core
        )
        let node = try #require(
            context.model(for: DOMNode.ID(canonical: storage))
        )
        #expect(try context.selectorPath(for: node) == "body")
        #expect(try context.xPath(for: node) == "/body")
        await fixture.wire.respond(to: "DOM.setAttributeValue")
        await fixture.wire.respond(to: "DOM.markUndoableState")
        await fixture.wire.respond(to: "DOM.undo")
        await fixture.wire.respond(to: "DOM.redo")

        let outcome = try await context.setDOMAttribute(
            "data-state",
            value: "ready",
            on: node
        )
        #expect(outcome.requestedNodeIDs == [node.id])
        #expect(outcome.appliedNodeIDs == [node.id])
        #expect(outcome.failures.isEmpty)
        let undo = try #require(outcome.undo)
        try await undo.undo()
        try await undo.redo()

        let mutation = try #require(
            fixture.wire.observations.commands.first {
                $0.method == "DOM.setAttributeValue"
            }
        )
        #expect(mutation.destination == .target("page-main"))
        let parameters = try mutation.parameters.decode(
            DOMAttributeMutationParameters.self
        )
        #expect(parameters.nodeId == "body")
        #expect(parameters.name == "data-state")
        #expect(parameters.value == "ready")
        #expect(
            fixture.wire.observations.commands.filter {
                $0.method == "DOM.markUndoableState"
            }.count == 1
        )
        #expect(
            fixture.wire.observations.commands.filter {
                $0.method == "DOM.undo"
            }.count == 1
        )
        #expect(
            fixture.wire.observations.commands.filter {
                $0.method == "DOM.redo"
            }.count == 1
        )
    }
}

@MainActor
@Test
func modelContextRoutesCanonicalDOMReadsAndPageCommandsThroughContainerCore()
    async throws
{
    try await withMainActorDOMCSSGatewayRuntime(domains: [.dom]) { fixture in
        let context = fixture.container.mainContext
        try await context.waitUntilContainerReady()
        let storage = try await canonicalDOMNodeID(
            rawValue: "body",
            in: fixture.container.core
        )
        let node = try #require(
            context.model(for: DOMNode.ID(canonical: storage))
        )
        await fixture.wire.respond(to: "DOM.requestChildNodes")
        await fixture.wire.respond(
            to: "DOM.getOuterHTML",
            with: try testJSONObject(#"{"outerHTML":"<body></body>"}"#)
        )
        await fixture.wire.respond(to: "DOM.highlightNode")
        await fixture.wire.respond(to: "DOM.hideHighlight")
        await fixture.wire.respond(to: "Page.reload")

        try await context.requestDOMChildren(of: node, depth: 2)
        #expect(try await context.copyText(.html, for: node) == "<body></body>")
        #expect(try await context.copyText(.selectorPath, for: node) == "body")
        #expect(try await context.copyText(.xPath, for: node) == "/body")
        try await context.highlightDOMNode(node)
        try await context.hideDOMHighlight()
        try await context.reload(ignoringCache: true)

        let childRequest = try #require(
            fixture.wire.observations.commands.first {
                $0.method == "DOM.requestChildNodes"
            }
        )
        #expect(childRequest.destination == .target("page-main"))
        let childParameters = try childRequest.parameters.decode(
            DOMChildRequestParameters.self
        )
        #expect(childParameters.nodeId == "body")
        #expect(childParameters.depth == 2)
        let reload = try #require(
            fixture.wire.observations.commands.first {
                $0.method == "Page.reload"
            }
        )
        #expect(reload.destination == .target("page-main"))
        #expect(
            try reload.parameters.decode(PageReloadParameters.self)
                .ignoreCache
        )
    }
}

@Test
func DOMGatewayUsesTheCanonicalPhysicalAgentWithoutTargetFallback()
    async throws
{
    try await withDOMCSSGatewayRuntime(
        domains: [.dom],
        document: gatewayDocument(),
        initialTarget: .init(
            id: "physical-agent",
            type: "page",
            frameID: "main-frame"
        )
    ) { fixture in
        let nodeID = try await canonicalDOMNodeID(
            rawValue: "body",
            agentTargetID: WebInspectorTarget.ID("physical-agent"),
            in: fixture.container.core
        )
        await fixture.wire.respond(
            to: "DOM.getOuterHTML",
            with: try testJSONObject(#"{"outerHTML":"<body>frame</body>"}"#)
        )

        _ = try await fixture.container.core.domOuterHTML(of: nodeID)
        let commands = fixture.wire.observations.commands.filter {
            $0.method == "DOM.getOuterHTML"
        }
        #expect(commands.count == 1)
        #expect(commands.first?.destination == .target("physical-agent"))
    }
}

@Test
func DOMGatewayRejectsStaleAndForeignCanonicalIdentitiesBeforeWire()
    async throws
{
    try await withDOMCSSGatewayRuntime(domains: [.dom]) { fixture in
        let current = try await canonicalDOMNodeID(
            rawValue: "body",
            in: fixture.container.core
        )
        let missing = WebInspectorDOMNodeIdentityStorage(
            documentScope: current.documentScope,
            rawNodeID: DOM.Node.ID("missing")
        )
        await #expect(throws: WebInspectorDOMCSSCommandError.nodeNotFound) {
            _ = try await fixture.container.core.domOuterHTML(of: missing)
        }

        let foreignScope = WebInspectorDOMDocumentScopeStorage(
            storeID: WebInspectorContainerStoreID(),
            attachmentGeneration: current.documentScope.attachmentGeneration,
            pageGeneration: current.documentScope.pageGeneration,
            semanticTargetID: current.documentScope.semanticTargetID,
            agentTargetID: current.documentScope.agentTargetID,
            domBindingEpoch: current.documentScope.domBindingEpoch
        )
        let foreign = WebInspectorDOMNodeIdentityStorage(
            documentScope: foreignScope,
            rawNodeID: current.rawNodeID
        )
        await #expect(throws: WebInspectorDOMCSSCommandError.foreignStore) {
            _ = try await fixture.container.core.domOuterHTML(of: foreign)
        }
        #expect(
            fixture.wire.observations.commands.contains {
                $0.method == "DOM.getOuterHTML"
            } == false
        )
    }
}

@Test
func DOMReadInvalidatesWhenItsNodeIsRemovedBeforeReply() async throws {
    try await withDOMCSSGatewayRuntime(domains: [.dom]) { fixture in
        let nodeID = try await canonicalDOMNodeID(
            rawValue: "body",
            in: fixture.container.core
        )
        let gate = await fixture.wire.deferReply(
            to: "DOM.getOuterHTML",
            with: try testJSONObject(#"{"outerHTML":"obsolete"}"#)
        )
        let operation = Task {
            try await fixture.container.core.domOuterHTML(of: nodeID)
        }
        _ = await fixture.wire.observations.waitForCommands(
            method: "DOM.getOuterHTML",
            count: 1
        )

        try await fixture.wire.emitRaw(
            .childNodeRemoved(
                parent: DOM.Node.ID("document"),
                node: DOM.Node.ID("body")
            ),
            target: WebInspectorTarget.ID("page-main")
        )
        await #expect(throws: WebInspectorDOMCSSCommandError.staleNode) {
            _ = try await operation.value
        }
        gate.open()
        try await requireDOMCSSOperationCount(
            0,
            in: fixture.container.core
        )
    }
}

@Test
func DOMReadInvalidatesWhenNodePresentationChangesBeforeReply()
    async throws
{
    try await withDOMCSSGatewayRuntime(domains: [.dom]) { fixture in
        let nodeID = try await canonicalDOMNodeID(
            rawValue: "body",
            in: fixture.container.core
        )
        let gate = await fixture.wire.deferReply(
            to: "DOM.getOuterHTML",
            with: try testJSONObject(#"{"outerHTML":"<body></body>"}"#)
        )
        let operation = Task {
            try await fixture.container.core.domOuterHTML(of: nodeID)
        }
        _ = await fixture.wire.observations.waitForCommands(
            method: "DOM.getOuterHTML",
            count: 1
        )

        try await fixture.wire.emitRaw(
            .attributeModified(
                DOM.Node.ID("body"),
                name: "class",
                value: "changed"
            ),
            target: WebInspectorTarget.ID("page-main")
        )
        await #expect(throws: WebInspectorDOMCSSCommandError.staleNode) {
            _ = try await operation.value
        }
        gate.open()
        try await requireDOMCSSOperationCount(
            0,
            in: fixture.container.core
        )
    }
}

@Test
func DOMRemovalSuccessValidatesDocumentInsteadOfDeletedNode() async throws {
    try await withDOMCSSGatewayRuntime(domains: [.dom]) { fixture in
        let nodeID = try await canonicalDOMNodeID(
            rawValue: "body",
            in: fixture.container.core
        )
        let gate = await fixture.wire.deferReply(to: "DOM.removeNode")
        let operation = Task {
            try await fixture.container.core.removeDOMNode(nodeID)
        }
        _ = await fixture.wire.observations.waitForCommands(
            method: "DOM.removeNode",
            count: 1
        )
        try await fixture.wire.emitRaw(
            .childNodeRemoved(
                parent: DOM.Node.ID("document"),
                node: DOM.Node.ID("body")
            ),
            target: WebInspectorTarget.ID("page-main")
        )
        gate.open()
        try await operation.value
        #expect(
            await fixture.container.core.canonicalSnapshotForTesting()
                .DOM?.records.contains { $0.id == nodeID } == false
        )
    }
}

@Test
func DOMDocumentCommandsRejectAReplacedDocumentLease() async throws {
    try await withDOMCSSGatewayRuntime(domains: [.dom]) { fixture in
        let nodeID = try await canonicalDOMNodeID(
            rawValue: "body",
            in: fixture.container.core
        )
        let gate = await fixture.wire.deferReply(to: "DOM.undo")
        let operation = Task {
            try await fixture.container.core.undoDOMChange(
                in: nodeID.documentScope
            )
        }
        _ = await fixture.wire.observations.waitForCommands(
            method: "DOM.undo",
            count: 1
        )
        await fixture.wire.respond(
            to: "DOM.getDocument",
            with: try domDocumentResult(
                gatewayDocument(
                    documentID: "replacement-document",
                    bodyID: "replacement-body"
                )
            )
        )
        try await fixture.wire.emitRaw(
            .documentUpdated,
            target: WebInspectorTarget.ID("page-main")
        )
        await #expect(
            throws: WebInspectorDOMCSSCommandError.staleDocument
        ) {
            try await operation.value
        }
        gate.open()
        _ = try await canonicalDOMNodeID(
            rawValue: "replacement-body",
            in: fixture.container.core
        )
    }
}

@Test
func DOMHighlightUsesNodeAdmissionAndAttachmentCompletionLease()
    async throws
{
    try await withDOMCSSGatewayRuntime(domains: [.dom]) { fixture in
        let nodeID = try await canonicalDOMNodeID(
            rawValue: "body",
            in: fixture.container.core
        )
        await fixture.wire.respond(to: "DOM.highlightNode")
        await fixture.wire.respond(to: "DOM.hideHighlight")

        try await fixture.container.core.highlightDOMNode(nodeID)
        try await fixture.container.core.hideDOMHighlight()

        let highlights = fixture.wire.observations.commands.filter {
            $0.method == "DOM.highlightNode"
        }
        #expect(highlights.count == 1)
        #expect(highlights.first?.destination == .target("page-main"))
        let parameters = try #require(highlights.first).parameters.decode(
            DOMNodeParameters.self
        )
        #expect(parameters.nodeId == "body")
        #expect(
            fixture.wire.observations.commands.filter {
                $0.method == "DOM.hideHighlight"
            }.count == 1
        )
    }
}

@Test
func elementPickerResolvesOneCanonicalNodeAndReleasesItsFeedLease()
    async throws
{
    try await withDOMCSSGatewayRuntime(domains: [.dom]) { fixture in
        await fixture.wire.respond(to: "Inspector.enable")
        await fixture.wire.respond(to: "Inspector.initialized")
        await fixture.wire.respond(to: "DOM.setInspectModeEnabled")
        await fixture.wire.respond(
            to: "DOM.requestNode",
            with: try testJSONObject(#"{"nodeId":"body"}"#)
        )
        await fixture.wire.respond(to: "DOM.setInspectModeEnabled")
        await fixture.wire.respond(to: "Inspector.disable")

        let operation = Task {
            try await fixture.container.core.pickDOMNode()
        }
        _ = await fixture.wire.observations.waitForCompletedCommands(
            method: "DOM.setInspectModeEnabled",
            count: 1
        )
        try await fixture.runtime.peer.emitTargetEvent(
            targetID: "page-main",
            method: "Inspector.inspect",
            parameters: try testJSONObject(
                #"{"object":{"objectId":"remote-body","type":"object","subtype":"node"},"hints":{}}"#
            )
        )

        let selectedID = try #require(try await operation.value)
        #expect(selectedID.rawNodeID == DOM.Node.ID("body"))
        #expect(
            await fixture.container.core.canonicalSnapshotForTesting()
                .DOM?.records.contains { $0.id == selectedID } == true
        )
        #expect(
            fixture.wire.observations.commands.filter {
                $0.method == "DOM.setInspectModeEnabled"
            }.count == 2
        )
        #expect(
            fixture.wire.observations.commands.filter {
                $0.method == "Inspector.disable"
            }.count == 1
        )
        #expect(
            await fixture.container.core.metrics.elementPickerOperationCount
                == 0
        )
    }
}

@Test
func elementPickerCallerCancellationReleasesOnlyItsOwnedLease()
    async throws
{
    try await withDOMCSSGatewayRuntime(domains: [.dom]) { fixture in
        await fixture.wire.respond(to: "Inspector.enable")
        await fixture.wire.respond(to: "Inspector.initialized")
        await fixture.wire.respond(to: "DOM.setInspectModeEnabled")
        await fixture.wire.respond(to: "DOM.setInspectModeEnabled")
        await fixture.wire.respond(to: "Inspector.disable")

        let operation = Task {
            try await fixture.container.core.pickDOMNode()
        }
        _ = await fixture.wire.observations.waitForCompletedCommands(
            method: "DOM.setInspectModeEnabled",
            count: 1
        )
        operation.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await operation.value
        }

        #expect(
            fixture.wire.observations.commands.filter {
                $0.method == "DOM.setInspectModeEnabled"
            }.count == 2
        )
        #expect(
            fixture.wire.observations.commands.filter {
                $0.method == "Inspector.disable"
            }.count == 1
        )
        #expect(
            await fixture.container.core.metrics.elementPickerOperationCount
                == 0
        )
        #expect(fixture.container.state == .attached)
    }
}

@Test
func elementPickerKeepsExclusiveOwnershipThroughPhysicalLeaseRelease()
    async throws
{
    try await withDOMCSSGatewayRuntime(domains: [.dom]) { fixture in
        await fixture.wire.respond(to: "Inspector.enable")
        await fixture.wire.respond(to: "Inspector.initialized")
        await fixture.wire.respond(to: "DOM.setInspectModeEnabled")
        await fixture.wire.respond(
            to: "DOM.requestNode",
            with: try testJSONObject(#"{"nodeId":"body"}"#)
        )
        let releaseGate = await fixture.wire.deferReply(
            to: "DOM.setInspectModeEnabled"
        )
        await fixture.wire.respond(to: "Inspector.disable")

        let operation = Task {
            try await fixture.container.core.pickDOMNode()
        }
        _ = await fixture.wire.observations.waitForCompletedCommands(
            method: "DOM.setInspectModeEnabled",
            count: 1
        )
        try await fixture.runtime.peer.emitTargetEvent(
            targetID: "page-main",
            method: "Inspector.inspect",
            parameters: try testJSONObject(
                #"{"object":{"objectId":"remote-body","type":"object","subtype":"node"},"hints":{}}"#
            )
        )
        _ = await fixture.wire.observations.waitForCommands(
            method: "DOM.setInspectModeEnabled",
            count: 2
        )

        await #expect(
            throws: WebInspectorElementPickerError.operationAlreadyActive
        ) {
            _ = try await fixture.container.core.pickDOMNode()
        }
        #expect(
            await fixture.container.core.metrics.elementPickerOperationCount
                == 1
        )

        releaseGate.open()
        _ = try #require(try await operation.value)
        #expect(
            await fixture.container.core.metrics.elementPickerOperationCount
                == 0
        )
    }
}

@Test
func CSSGatewayCoalescesOnlyTheExactNodeCascadeResourceLease()
    async throws
{
    try await withDOMCSSGatewayRuntime { fixture in
        let nodeID = try await canonicalDOMNodeID(
            rawValue: "body",
            in: fixture.container.core
        )
        await fixture.wire.respond(
            to: "CSS.getMatchedStylesForNode",
            with: try rawCSSMatchedStylesResult(.init())
        )
        await fixture.wire.respond(
            to: "CSS.getInlineStylesForNode",
            with: try rawCSSInlineStylesResult(.init())
        )
        await fixture.wire.respond(
            to: "CSS.getComputedStyleForNode",
            with: try rawCSSComputedStyleResult([])
        )

        let first = Task {
            try await fixture.container.core.loadCSSResource(for: nodeID)
        }
        let second = Task {
            try await fixture.container.core.loadCSSResource(for: nodeID)
        }
        let firstResource = try await first.value
        let secondResource = try await second.value

        #expect(firstResource.lease == secondResource.lease)
        #expect(
            fixture.wire.observations.commands.filter {
                $0.method == "CSS.getMatchedStylesForNode"
            }.count == 1
        )
        #expect(
            fixture.wire.observations.commands.filter {
                $0.method == "CSS.getInlineStylesForNode"
            }.count == 1
        )
        #expect(
            fixture.wire.observations.commands.filter {
                $0.method == "CSS.getComputedStyleForNode"
            }.count == 1
        )
        let metrics = await fixture.container.core.metrics
        #expect(metrics.core.domCSSCommandWireOperationCount == 1)
        #expect(metrics.core.domCSSCommandCoalescedWaiterCount == 1)
        #expect(metrics.domCSSCommandOperationCount == 0)
    }
}

@Test
func CSSGatewayInvalidatesTheWholeResourceWhenCascadeAdvances()
    async throws
{
    try await withDOMCSSGatewayRuntime { fixture in
        let nodeID = try await canonicalDOMNodeID(
            rawValue: "body",
            in: fixture.container.core
        )
        let matchedGate = await fixture.wire.deferReply(
            to: "CSS.getMatchedStylesForNode",
            with: try rawCSSMatchedStylesResult(.init())
        )
        let inlineGate = await fixture.wire.deferReply(
            to: "CSS.getInlineStylesForNode",
            with: try rawCSSInlineStylesResult(.init())
        )
        let computedGate = await fixture.wire.deferReply(
            to: "CSS.getComputedStyleForNode",
            with: try rawCSSComputedStyleResult([])
        )
        let operation = Task {
            try await fixture.container.core.loadCSSResource(for: nodeID)
        }
        _ = await fixture.wire.observations.waitForCommands(
            method: "CSS.getMatchedStylesForNode",
            count: 1
        )
        _ = await fixture.wire.observations.waitForCommands(
            method: "CSS.getInlineStylesForNode",
            count: 1
        )
        _ = await fixture.wire.observations.waitForCommands(
            method: "CSS.getComputedStyleForNode",
            count: 1
        )

        try await fixture.wire.emitRaw(
            .mediaQueryResultChanged,
            target: WebInspectorTarget.ID("page-main")
        )
        await #expect(throws: WebInspectorDOMCSSCommandError.staleCascade) {
            _ = try await operation.value
        }
        matchedGate.open()
        inlineGate.open()
        computedGate.open()
        try await requireDOMCSSOperationCount(
            0,
            in: fixture.container.core
        )
    }
}

@Test
func CSSGatewayInvalidatesTheResourceOnDOMPresentationChanges()
    async throws
{
    try await withDOMCSSGatewayRuntime { fixture in
        let nodeID = try await canonicalDOMNodeID(
            rawValue: "body",
            in: fixture.container.core
        )
        let matchedGate = await fixture.wire.deferReply(
            to: "CSS.getMatchedStylesForNode",
            with: try rawCSSMatchedStylesResult(.init())
        )
        let inlineGate = await fixture.wire.deferReply(
            to: "CSS.getInlineStylesForNode",
            with: try rawCSSInlineStylesResult(.init())
        )
        let computedGate = await fixture.wire.deferReply(
            to: "CSS.getComputedStyleForNode",
            with: try rawCSSComputedStyleResult([])
        )
        let operation = Task {
            try await fixture.container.core.loadCSSResource(for: nodeID)
        }
        _ = await fixture.wire.observations.waitForCommands(
            method: "CSS.getMatchedStylesForNode",
            count: 1
        )
        _ = await fixture.wire.observations.waitForCommands(
            method: "CSS.getInlineStylesForNode",
            count: 1
        )
        _ = await fixture.wire.observations.waitForCommands(
            method: "CSS.getComputedStyleForNode",
            count: 1
        )

        try await fixture.wire.emitRaw(
            .attributeModified(
                DOM.Node.ID("body"),
                name: "class",
                value: "changed"
            ),
            target: WebInspectorTarget.ID("page-main")
        )
        await #expect(throws: WebInspectorDOMCSSCommandError.staleCascade) {
            _ = try await operation.value
        }
        matchedGate.open()
        inlineGate.open()
        computedGate.open()
        try await requireDOMCSSOperationCount(
            0,
            in: fixture.container.core
        )
    }
}

@Test
func CSSGatewayChangesTheLeaseAfterDOMPresentationChanges()
    async throws
{
    try await withDOMCSSGatewayRuntime { fixture in
        let nodeID = try await canonicalDOMNodeID(
            rawValue: "body",
            in: fixture.container.core
        )
        await fixture.wire.respond(
            to: "CSS.getMatchedStylesForNode",
            with: try rawCSSMatchedStylesResult(.init())
        )
        await fixture.wire.respond(
            to: "CSS.getInlineStylesForNode",
            with: try rawCSSInlineStylesResult(.init())
        )
        await fixture.wire.respond(
            to: "CSS.getComputedStyleForNode",
            with: try rawCSSComputedStyleResult([])
        )
        let first = try await fixture.container.core.loadCSSResource(
            for: nodeID
        )

        try await fixture.wire.emitRaw(
            .attributeModified(
                DOM.Node.ID("body"),
                name: "class",
                value: "changed"
            ),
            target: WebInspectorTarget.ID("page-main")
        )
        await fixture.wire.respond(
            to: "CSS.getMatchedStylesForNode",
            with: try rawCSSMatchedStylesResult(.init())
        )
        await fixture.wire.respond(
            to: "CSS.getInlineStylesForNode",
            with: try rawCSSInlineStylesResult(.init())
        )
        await fixture.wire.respond(
            to: "CSS.getComputedStyleForNode",
            with: try rawCSSComputedStyleResult([])
        )
        let second = try await fixture.container.core.loadCSSResource(
            for: nodeID
        )

        #expect(first.lease.cascadeRevision == second.lease.cascadeRevision)
        #expect(
            first.lease.presentationRevision
                != second.lease.presentationRevision
        )
        #expect(first.lease != second.lease)
    }
}

@Test
func CSSStyleSheetMutationUsesCanonicalStyleSheetAndDocumentAuthority()
    async throws
{
    try await withDOMCSSGatewayRuntime { fixture in
        let header = CSS.StyleSheetHeader(
            styleSheetID: CSS.StyleSheet.ID("sheet"),
            frameID: FrameID("main-frame"),
            sourceURL: "https://example.test/style.css",
            origin: .init(rawValue: "author")
        )
        try await fixture.wire.emitRaw(
            .styleSheetAdded(header),
            target: WebInspectorTarget.ID("page-main")
        )
        let styleSheetID = try await canonicalCSSStyleSheetID(
            rawValue: "sheet",
            in: fixture.container.core
        )
        await fixture.wire.respond(to: "CSS.setStyleSheetText")

        try await fixture.container.core.setCSSStyleSheetText(
            "body { color: red; }",
            for: styleSheetID
        )

        let command = try #require(
            fixture.wire.observations.commands.first {
                $0.method == "CSS.setStyleSheetText"
            }
        )
        #expect(command.destination == .target("page-main"))
        let parameters = try command.parameters.decode(
            CSSStyleSheetTextParameters.self
        )
        #expect(parameters.styleSheetId == "sheet")
        #expect(parameters.text == "body { color: red; }")
    }
}

@Test
func DOMCSSGatewayCallerCancellationDoesNotCancelTheSharedCSSResource()
    async throws
{
    try await withDOMCSSGatewayRuntime { fixture in
        let nodeID = try await canonicalDOMNodeID(
            rawValue: "body",
            in: fixture.container.core
        )
        let matchedGate = await fixture.wire.deferReply(
            to: "CSS.getMatchedStylesForNode",
            with: try rawCSSMatchedStylesResult(.init())
        )
        await fixture.wire.respond(
            to: "CSS.getInlineStylesForNode",
            with: try rawCSSInlineStylesResult(.init())
        )
        await fixture.wire.respond(
            to: "CSS.getComputedStyleForNode",
            with: try rawCSSComputedStyleResult([])
        )
        let first = Task.detached {
            try await fixture.container.core.loadCSSResource(for: nodeID)
        }
        let second = Task.detached {
            try await fixture.container.core.loadCSSResource(for: nodeID)
        }
        _ = await fixture.wire.observations.waitForCommands(
            method: "CSS.getMatchedStylesForNode",
            count: 1
        )
        first.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await first.value
        }
        #expect(await fixture.container.core.metrics.domCSSCommandOperationCount == 1)
        matchedGate.open()
        _ = try await second.value
        try await requireDOMCSSOperationCount(
            0,
            in: fixture.container.core
        )
    }
}

@Test
func DOMCSSGatewayDetachInvalidatesAndDrainsPendingWireWork()
    async throws
{
    let fixture = try await DOMCSSGatewayRuntime.start(domains: [.dom])
    let nodeID = try await canonicalDOMNodeID(
        rawValue: "body",
        in: fixture.container.core
    )
    let gate = await fixture.wire.deferReply(
        to: "DOM.getOuterHTML",
        with: try testJSONObject(#"{"outerHTML":"obsolete"}"#)
    )
    let operation = Task {
        try await fixture.container.core.domOuterHTML(of: nodeID)
    }
    _ = await fixture.wire.observations.waitForCommands(
        method: "DOM.getOuterHTML",
        count: 1
    )
    await fixture.wire.respond(to: "Page.disable")
    await fixture.container.detach()
    await #expect(throws: WebInspectorDOMCSSCommandError.detached) {
        _ = try await operation.value
    }
    #expect(await fixture.container.core.metrics.domCSSCommandOperationCount == 0)
    gate.open()
    await fixture.container.close()
    await fixture.runtime.close()
    await fixture.wire.stop()
}

@Test
func DOMCSSGatewayCloseInvalidatesAndDrainsPendingWireWork()
    async throws
{
    let fixture = try await DOMCSSGatewayRuntime.start(domains: [.dom])
    let nodeID = try await canonicalDOMNodeID(
        rawValue: "body",
        in: fixture.container.core
    )
    let gate = await fixture.wire.deferReply(
        to: "DOM.getOuterHTML",
        with: try testJSONObject(#"{"outerHTML":"obsolete"}"#)
    )
    let operation = Task {
        try await fixture.container.core.domOuterHTML(of: nodeID)
    }
    _ = await fixture.wire.observations.waitForCommands(
        method: "DOM.getOuterHTML",
        count: 1
    )
    await fixture.container.close()
    await #expect(throws: WebInspectorDOMCSSCommandError.closed) {
        _ = try await operation.value
    }
    #expect(await fixture.container.core.metrics.domCSSCommandOperationCount == 0)
    gate.open()
    await fixture.runtime.close()
    await fixture.wire.stop()
}

@Test
func DOMCSSGatewayRejectsNewCommandsAfterBeginClose() async throws {
    let fixture = try await DOMCSSGatewayRuntime.start(domains: [.dom])
    let nodeID = try await canonicalDOMNodeID(
        rawValue: "body",
        in: fixture.container.core
    )
    _ = await fixture.container.core.beginClose()

    await #expect(throws: WebInspectorDOMCSSCommandError.closed) {
        _ = try await fixture.container.core.domOuterHTML(of: nodeID)
    }
    #expect(
        fixture.wire.observations.commands.contains {
            $0.method == "DOM.getOuterHTML"
        } == false
    )
    await fixture.close()
}

private struct DOMNodeParameters: Decodable {
    let nodeId: String
}

private struct DOMAttributeMutationParameters: Decodable {
    let nodeId: String
    let name: String
    let value: String
}

private struct DOMChildRequestParameters: Decodable {
    let nodeId: String
    let depth: Int
}

private struct PageReloadParameters: Decodable {
    let ignoreCache: Bool
}

private struct CSSStyleSheetTextParameters: Decodable {
    let styleSheetId: String
    let text: String
}

private func gatewayDocument(
    documentID: String = "document",
    bodyID: String = "body",
    frameID: String = "main-frame"
) -> DOM.Node {
    DOM.Node(
        id: DOM.Node.ID(documentID),
        nodeType: 9,
        nodeName: "#document",
        frameID: FrameID(frameID),
        childNodeCount: 1,
        children: [
            DOM.Node(
                id: DOM.Node.ID(bodyID),
                nodeType: 1,
                nodeName: "BODY",
                localName: "body"
            )
        ]
    )
}

private func canonicalDOMNodeID(
    rawValue: String,
    agentTargetID: WebInspectorTarget.ID = WebInspectorTarget.ID("page-main"),
    in core: WebInspectorModelContainerCore
) async throws -> WebInspectorDOMNodeIdentityStorage {
    for _ in 0..<1_000 {
        let snapshot = await core.canonicalSnapshotForTesting()
        if let id = snapshot.DOM?.records.lazy.map(\.id).first(where: {
            $0.rawNodeID.rawValue == rawValue
                && $0.documentScope.agentTargetID == agentTargetID
        }) {
            return id
        }
        await Task.yield()
    }
    Issue.record(
        "Canonical DOM node \(rawValue) for \(agentTargetID.rawValue) was not published."
    )
    throw WebInspectorDOMCSSCommandError.nodeNotFound
}

private func requireDOMCSSOperationCount(
    _ expectedCount: Int,
    in core: WebInspectorModelContainerCore
) async throws {
    for _ in 0..<1_000 {
        if await core.metrics.domCSSCommandOperationCount == expectedCount {
            return
        }
        await Task.yield()
    }
    Issue.record("DOM/CSS operation count did not become \(expectedCount).")
}

private func canonicalCSSStyleSheetID(
    rawValue: String,
    in core: WebInspectorModelContainerCore
) async throws -> WebInspectorCSSStyleSheetIdentityStorage {
    for _ in 0..<1_000 {
        let snapshot = await core.canonicalSnapshotForTesting()
        if let id = snapshot.CSS?.recordsByID.keys.first(where: {
            $0.rawStyleSheetID.rawValue == rawValue
        }) {
            return id
        }
        await Task.yield()
    }
    Issue.record("Canonical CSS stylesheet \(rawValue) was not published.")
    throw WebInspectorDOMCSSCommandError.styleSheetNotFound
}
