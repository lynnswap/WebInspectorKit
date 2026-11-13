import Foundation
import Observation
import ObservationBridge
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import WebInspectorTestSupport

@MainActor
@Test
func domEventsPopulateRootAndPreserveChildIdentity() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let documentID = DOM.Node.ID("document")
    let childID = DOM.Node.ID("child")
    let grandchildID = DOM.Node.ID("grandchild")

    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: documentID, nodeType: 9, nodeName: "#document", childNodeCount: 1)
    )

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitForStartupSubscribers(runtime: runtime, target: target)
    try await waitUntil(in: context) { context.dom.rootNode != nil }

    await runtime.backend.emit(
        .setChildNodes(parent: documentID, nodes: [
            DOM.Node(
                id: childID,
                nodeType: 1,
                nodeName: "DIV",
                localName: "div",
                attributes: ["class": "before"],
                childNodeCount: 0
            )
        ]),
        target: target
    )
    let child = try await waitForChild(in: context)
    #expect(context.dom.node(for: child.id) === child)

    await runtime.backend.emit(
        .attributeModified(childID, name: "class", value: "after"),
        target: target
    )
    try await waitUntil { child.attributes["class"] == "after" }
    #expect(context.dom.node(for: child.id) === child)

    await runtime.backend.emit(
        .childNodeCountUpdated(childID, count: 2),
        target: target
    )
    try await waitUntil { child.childNodeCount == 2 }
    #expect(context.dom.node(for: child.id) === child)

    await runtime.backend.emit(
        .setChildNodes(parent: childID, nodes: [
            DOM.Node(id: grandchildID, nodeType: 3, nodeName: "#text", nodeValue: "hello")
        ]),
        target: target
    )
    try await waitUntil {
        guard case let .loaded(children) = child.children else {
            return false
        }
        return children.first?.id == DOMNode.ID(grandchildID)
    }
    guard case let .loaded(grandchildren) = child.children else {
        Issue.record("Expected loaded child subtree.")
        return
    }
    let grandchild = try #require(grandchildren.first)
    context.dom.select(grandchild)

    await runtime.backend.emit(
        .childNodeRemoved(parent: documentID, node: childID),
        target: target
    )
    try await waitUntil(in: context) {
        guard let root = context.dom.rootNode, case let .loaded(children) = root.children else {
            return false
        }
        return children.isEmpty
    }
    #expect(context.dom.node(for: child.id) == nil)
    #expect(context.dom.node(for: grandchild.id) == nil)
    #expect(context.dom.selectedNode == nil)
}

@MainActor
@Test
func requestChildrenDispatchesDOMCommandAndMaterializesSetChildNodes() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.dom.rootNode)
    let childID = DOM.Node.ID("requested-child")

    await runtime.backend.enqueue((), for: "DOM", method: "requestChildNodes")

    await context.dom.requestChildren(of: document, depth: 2)

    let commands = await runtime.backend.recordedCommands()
    let command = try #require(commands.first {
        $0.domain == "DOM" && $0.method == "requestChildNodes"
    })
    let payload = try #require(command.payload.cast(as: DOM.RequestChildNodesPayload.self))
    #expect(payload.id == document.id.proxyID)
    #expect(payload.depth == 2)

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: childID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )

    try await waitUntil {
        guard case let .loaded(children) = document.children else {
            return false
        }
        return children.first?.id == DOMNode.ID(childID)
    }
}

@MainActor
@Test
func domTreeSnapshotBuildsSelectorAndXPathFromDataKitProjection() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let documentID = DOM.Node.ID("document")
    let htmlID = DOM.Node.ID("html")
    let bodyID = DOM.Node.ID("body")
    let firstCardID = DOM.Node.ID("first-card")
    let featuredCardID = DOM.Node.ID("featured-card")
    let inputID = DOM.Node.ID("search")
    let textID = DOM.Node.ID("body-text")

    let document = DOM.Node(
        id: documentID,
        nodeType: 9,
        nodeName: "#document",
        children: [
            DOM.Node(
                id: htmlID,
                nodeType: 1,
                nodeName: "HTML",
                localName: "html",
                children: [
                    DOM.Node(
                        id: bodyID,
                        nodeType: 1,
                        nodeName: "BODY",
                        localName: "body",
                        children: [
                            DOM.Node(
                                id: firstCardID,
                                nodeType: 1,
                                nodeName: "DIV",
                                localName: "div",
                                attributes: ["class": "card"],
                                attributeList: [DOM.Attribute(name: "class", value: "card")]
                            ),
                            DOM.Node(
                                id: featuredCardID,
                                nodeType: 1,
                                nodeName: "DIV",
                                localName: "div",
                                attributes: ["class": "card featured"],
                                attributeList: [DOM.Attribute(name: "class", value: "card featured")]
                            ),
                            DOM.Node(
                                id: inputID,
                                nodeType: 1,
                                nodeName: "INPUT",
                                localName: "input",
                                attributes: ["type": "search"],
                                attributeList: [DOM.Attribute(name: "type", value: "search")]
                            ),
                            DOM.Node(id: textID, nodeType: 3, nodeName: "#text", nodeValue: "hello"),
                        ]
                    )
                ]
            )
        ]
    )
    let (_, context) = try await startContext(runtime: runtime, document: document)
    let tree = context.dom.treeController()
    let snapshot = tree.snapshot

    #expect(snapshot.selectorPath(for: DOMNode.ID(documentID)) == "")
    #expect(snapshot.xPath(for: DOMNode.ID(documentID)) == "/")
    #expect(snapshot.selectorPath(for: DOMNode.ID(featuredCardID)) == "body > div.featured")
    #expect(snapshot.xPath(for: DOMNode.ID(featuredCardID)) == "/html/body/div[2]")
    #expect(snapshot.selectorPath(for: DOMNode.ID(inputID)) == "body > input[type=\"search\"]")
    #expect(snapshot.xPath(for: DOMNode.ID(textID)) == "/html/body/text()")
}

@MainActor
@Test
func domCommandsDispatchThroughDataKitContext() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let documentID = DOM.Node.ID("document")
    let htmlID = DOM.Node.ID("html")
    let bodyID = DOM.Node.ID("body")
    let parentID = DOM.Node.ID("parent")
    let childID = DOM.Node.ID("child")
    let document = DOM.Node(
        id: documentID,
        nodeType: 9,
        nodeName: "#document",
        children: [
            DOM.Node(
                id: htmlID,
                nodeType: 1,
                nodeName: "HTML",
                localName: "html",
                children: [
                    DOM.Node(
                        id: bodyID,
                        nodeType: 1,
                        nodeName: "BODY",
                        localName: "body",
                        children: [
                            DOM.Node(
                                id: parentID,
                                nodeType: 1,
                                nodeName: "DIV",
                                localName: "div",
                                attributes: ["class": "card"],
                                attributeList: [DOM.Attribute(name: "class", value: "card")],
                                children: [
                                    DOM.Node(
                                        id: childID,
                                        nodeType: 1,
                                        nodeName: "SPAN",
                                        localName: "span",
                                        attributes: ["id": "title"],
                                        attributeList: [DOM.Attribute(name: "id", value: "title")]
                                    )
                                ]
                            )
                        ]
                    )
                ]
            )
        ]
    )
    let (target, context) = try await startContext(runtime: runtime, document: document)
    let parent = try #require(context.dom.node(for: DOMNode.ID(parentID)))
    let child = try #require(context.dom.node(for: DOMNode.ID(childID)))

    await runtime.backend.enqueue("<span id=\"title\"></span>", for: "DOM", method: "getOuterHTML")
    #expect(try await context.dom.copyText(.html, of: child) == "<span id=\"title\"></span>")
    #expect(try await context.dom.copyText(.selectorPath, of: child) == "#title")
    #expect(try context.dom.xPath(for: child) == "/html/body/div/span")

    await runtime.backend.enqueue((), for: "DOM", method: "highlightNode")
    try await context.dom.highlight(child)

    await runtime.backend.enqueue((), for: "DOM", method: "hideHighlight")
    try await context.dom.hideHighlight()

    await runtime.backend.enqueue((), for: "DOM", method: "undo")
    try await context.dom.undo()

    await runtime.backend.enqueue((), for: "DOM", method: "redo")
    try await context.dom.redo()

    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")
    try await context.dom.setElementPickerEnabled(true)
    #expect(context.dom.isElementPickerEnabled)

    await enqueueCSSStyleReplies(on: runtime.backend)
    await runtime.backend.emit(.inspect(childID), target: target)
    try await waitUntil(in: context) { context.dom.selectedNode === child }
    try await waitUntil { child.elementStyles?.phase == .loaded }
    #expect(context.dom.isElementPickerEnabled == false)

    await runtime.backend.enqueue((), for: "DOM", method: "setAttributeValue")
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    try await context.dom.setAttribute("class", value: "updated", on: parent)

    await runtime.backend.enqueue((), for: "DOM", method: "setOuterHTML")
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    try await context.dom.setOuterHTML("<span id=\"title\"></span>", of: child)

    await runtime.backend.enqueue((), for: "DOM", method: "removeNode")
    await runtime.backend.enqueue((), for: "DOM", method: "removeNode")
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    let removedNodes = try await context.dom.remove([parent, child])
    #expect(removedNodes == [child, parent])
    #expect(context.dom.selectedNode == nil)
    #expect(child.elementStyles == nil)

    await runtime.backend.enqueue((), for: "Page", method: "reload")
    try await context.page.reload(ignoringCache: true)

    let commands = await runtime.backend.recordedCommands()
    let outerHTML = try #require(commands.first { $0.domain == "DOM" && $0.method == "getOuterHTML" })
    #expect(outerHTML.payload.cast(as: DOM.GetOuterHTMLPayload.self)?.id == childID)

    let highlight = try #require(commands.first { $0.domain == "DOM" && $0.method == "highlightNode" })
    #expect(highlight.payload.cast(as: DOM.HighlightNodePayload.self)?.id == childID)

    #expect(commands.contains { $0.domain == "DOM" && $0.method == "undo" })
    #expect(commands.contains { $0.domain == "DOM" && $0.method == "redo" })

    let inspectMode = try #require(commands.first { $0.domain == "DOM" && $0.method == "setInspectModeEnabled" })
    #expect(inspectMode.payload.cast(as: DOM.SetInspectModeEnabledPayload.self)?.enabled == true)

    let setAttribute = try #require(commands.first { $0.domain == "DOM" && $0.method == "setAttributeValue" })
    #expect(setAttribute.payload.cast(as: DOM.SetAttributeValuePayload.self)?.id == parentID)
    #expect(setAttribute.payload.cast(as: DOM.SetAttributeValuePayload.self)?.name == "class")
    #expect(setAttribute.payload.cast(as: DOM.SetAttributeValuePayload.self)?.value == "updated")

    let setOuterHTML = try #require(commands.first { $0.domain == "DOM" && $0.method == "setOuterHTML" })
    #expect(setOuterHTML.payload.cast(as: DOM.SetOuterHTMLPayload.self)?.id == childID)
    #expect(setOuterHTML.payload.cast(as: DOM.SetOuterHTMLPayload.self)?.html == "<span id=\"title\"></span>")

    let removals = commands.filter { $0.domain == "DOM" && $0.method == "removeNode" }
    #expect(removals.count == 2)
    #expect(removals.first?.payload.cast(as: DOM.RemoveNodePayload.self)?.id == childID)
    #expect(removals.last?.payload.cast(as: DOM.RemoveNodePayload.self)?.id == parentID)
    let undoMarks = commands.filter { $0.domain == "DOM" && $0.method == "markUndoableState" }
    #expect(undoMarks.count == 4)

    let reload = try #require(commands.first { $0.domain == "Page" && $0.method == "reload" })
    #expect(reload.payload.cast(as: Page.ReloadPayload.self)?.ignoringCache == true)
}

@MainActor
@Test
func domMutationsAndUndoRedoUseOwningFrameTarget() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let frameTarget = await runtime.proxy.installTargetForTesting(kind: .frame)
    let document = try #require(context.dom.rootNode)
    let scopedNodeID = DOM.Node.ID(
        "frame-owned-node",
        scopedToTargetRawValue: frameTarget.id.rawValue
    )

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: scopedNodeID, nodeType: 3, nodeName: "#text", nodeValue: "frame")
        ]),
        target: target
    )
    try await waitUntil(in: context) { context.dom.node(for: DOMNode.ID(scopedNodeID)) != nil }

    await runtime.backend.enqueue((), for: "DOM", method: "setAttributeValue")
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    try await context.dom.setAttribute("data-edited", value: "page", on: document)

    await runtime.backend.enqueue((), for: "DOM", method: "removeNode")
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    let scopedNode = try #require(context.dom.node(for: DOMNode.ID(scopedNodeID)))
    try await context.dom.remove([scopedNode])

    await runtime.backend.enqueue((), for: "DOM", method: "undo")
    try await context.dom.undo()

    await runtime.backend.enqueue((), for: "DOM", method: "redo")
    try await context.dom.redo()

    let domCommands = await runtime.backend.recordedCommands()
        .filter { $0.domain == "DOM" && ["setAttributeValue", "removeNode", "markUndoableState", "undo", "redo"].contains($0.method) }
    #expect(domCommands.map(\.method) == [
        "setAttributeValue",
        "markUndoableState",
        "removeNode",
        "markUndoableState",
        "undo",
        "redo",
    ])
    #expect(domCommands.prefix(2).allSatisfy { $0.targetID == target.id })
    let frameCommands = domCommands.dropFirst(2)
    #expect(frameCommands.allSatisfy { $0.targetID == frameTarget.id })
    #expect(frameCommands.allSatisfy { $0.route == RoutingTargetID(frameTarget.id.rawValue) })
    let removal = try #require(frameCommands.first { $0.method == "removeNode" })
    #expect(removal.payload.cast(as: DOM.RemoveNodePayload.self)?.id == scopedNodeID)
}

@MainActor
@Test
func domDeleteRejectsCrossTargetSelectionBeforeRemovingNodes() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let frameTarget = await runtime.proxy.installTargetForTesting(kind: .frame)
    let document = try #require(context.dom.rootNode)
    let pageNodeID = DOM.Node.ID("page-node")
    let scopedFrameNodeID = DOM.Node.ID(
        "frame-node",
        scopedToTargetRawValue: frameTarget.id.rawValue
    )

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: pageNodeID, nodeType: 1, nodeName: "DIV", localName: "div"),
            DOM.Node(id: scopedFrameNodeID, nodeType: 1, nodeName: "SPAN", localName: "span"),
        ]),
        target: target
    )
    try await waitUntil(in: context) {
        context.dom.node(for: DOMNode.ID(pageNodeID)) != nil
            && context.dom.node(for: DOMNode.ID(scopedFrameNodeID)) != nil
    }

    await #expect(throws: WebInspectorProxyError.commandFailed(
        domain: "DOM",
        method: "removeNode",
        message: "Deleting nodes from multiple DOM targets in one mutation is not supported."
    )) {
        try await context.dom.remove([
            try #require(context.dom.node(for: DOMNode.ID(pageNodeID))),
            try #require(context.dom.node(for: DOMNode.ID(scopedFrameNodeID))),
        ])
    }

    let removeCommands = await runtime.backend.recordedCommands()
        .filter { $0.domain == "DOM" && $0.method == "removeNode" }
    #expect(removeCommands.isEmpty)
}

@MainActor
@Test
func domInspectSelectsKnownNodeAndLoadsStyles() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.dom.rootNode)
    let elementID = DOM.Node.ID("inspect-node")

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )
    let element = try await waitForChild(in: context)

    await enqueueCSSStyleReplies(on: runtime.backend)
    await runtime.backend.emit(.inspect(elementID), target: target)

    try await waitUntil(in: context) { context.dom.selectedNode === element }
    let styles = try #require(element.elementStyles)
    try await waitUntil { styles.phase == .loaded }
    #expect(styles.sections.map(\.title) == [".card"])

    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "getMatchedStylesForNode")))
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "getComputedStyleForNode")))
}

@MainActor
@Test
func domInspectWaitsForRequestNodePathBeforeSelectingUnresolvedNode() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.dom.rootNode)
    let staleID = DOM.Node.ID("stale-node")
    let elementID = DOM.Node.ID("resolved-inspect-node")

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: staleID, nodeType: 1, nodeName: "SPAN", localName: "span")
        ]),
        target: target
    )
    try await waitUntil(in: context) { context.dom.node(for: DOMNode.ID(staleID)) != nil }

    await enqueueCSSStyleReplies(on: runtime.backend)
    await runtime.backend.emit(.inspect(elementID), target: target)
    #expect(context.dom.selectedNode == nil)

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )

    try await waitUntil(in: context) { context.dom.selectedNode?.id == DOMNode.ID(elementID) }
    #expect(context.state == .attached)
    #expect(await runtime.backend.recordedCommands().contains(
        RecordedCommand(domain: "DOM", method: "requestChildNodes")
    ) == false)
    #expect(context.dom.node(for: DOMNode.ID(staleID)) == nil)
    let selected = try #require(context.dom.selectedNode)
    let styles = try #require(selected.elementStyles)
    try await waitUntil { styles.phase == .loaded }
}

@MainActor
@Test
func domInspectBeforeDocumentArrivesWaitsForRequestNodePathAfterRootApplies() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let gate = WebInspectorTestGate()
    let documentID = DOM.Node.ID("document")
    let elementID = DOM.Node.ID("deferred-inspect-node")

    await runtime.backend.hold(domain: "DOM", method: "getDocument", gate: gate)
    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: documentID, nodeType: 9, nodeName: "#document")
    )

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitForStartupSubscribers(runtime: runtime, target: target)
    _ = try await runtime.backend.waitForRecordedCommandsForTesting(domain: "DOM", method: "getDocument", count: 1)

    await runtime.backend.emit(.inspect(elementID), target: target)
    await enqueueCSSStyleReplies(on: runtime.backend)
    await gate.open()

    try await waitUntil(in: context) { context.dom.rootNode?.id == DOMNode.ID(documentID) }
    #expect(context.dom.selectedNode == nil)

    await runtime.backend.emit(
        .setChildNodes(parent: documentID, nodes: [
            DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )

    try await waitUntil(in: context) { context.dom.selectedNode?.id == DOMNode.ID(elementID) }
    let selected = try #require(context.dom.selectedNode)
    let styles = try #require(selected.elementStyles)
    try await waitUntil { styles.phase == .loaded }
    #expect(await runtime.backend.recordedCommands().contains(
        RecordedCommand(domain: "DOM", method: "requestChildNodes")
    ) == false)
}

@MainActor
@Test
func domBootstrapAppliesMutationPrefixAfterDocumentSnapshot() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let gate = WebInspectorTestGate()
    let documentID = DOM.Node.ID("document")
    let bodyID = DOM.Node.ID("body")

    await runtime.backend.hold(domain: "DOM", method: "getDocument", gate: gate)
    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(
            id: documentID,
            nodeType: 9,
            nodeName: "#document",
            childNodeCount: 1,
            children: [
                DOM.Node(
                    id: bodyID,
                    nodeType: 1,
                    nodeName: "BODY",
                    localName: "body"
                )
            ]
        )
    )

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitForStartupSubscribers(runtime: runtime, target: target)
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "getDocument",
        count: 1
    )

    await runtime.backend.emit(
        .setChildNodes(parent: documentID, nodes: [
            DOM.Node(
                id: bodyID,
                nodeType: 1,
                nodeName: "BODY",
                localName: "body"
            )
        ]),
        target: target
    )
    await runtime.backend.emit(
        .attributeModified(bodyID, name: "data-before-reply", value: "preserved"),
        target: target
    )
    await gate.open()

    try await waitUntil(in: context) { context.state == .attached }
    let body = try #require(context.dom.node(for: DOMNode.ID(bodyID)))
    #expect(body.attributes["data-before-reply"] == "preserved")
}

@MainActor
@Test
func documentUpdatedDuringAttachRestartsDOMBootstrap() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let gate = WebInspectorTestGate()
    let staleDocumentID = DOM.Node.ID("stale-document")
    let currentDocumentID = DOM.Node.ID("current-document")

    await runtime.backend.hold(domain: "DOM", method: "getDocument", gate: gate)
    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: staleDocumentID, nodeType: 9, nodeName: "#document")
    )
    await runtime.backend.enqueue(
        DOM.Node(id: currentDocumentID, nodeType: 9, nodeName: "#document"),
        for: "DOM",
        method: "getDocument"
    )

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitForStartupSubscribers(runtime: runtime, target: target)
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "getDocument",
        count: 1
    )

    await runtime.backend.emit(.documentUpdated, target: target)
    await gate.open()

    try await waitUntil(in: context) {
        context.state == .attached
            && context.dom.rootNode?.id == DOMNode.ID(currentDocumentID)
    }
    #expect(context.dom.node(for: DOMNode.ID(staleDocumentID)) == nil)
    let commands = await runtime.backend.recordedCommands()
    #expect(commands.filter { $0 == RecordedCommand(domain: "DOM", method: "getDocument") }.count == 2)
}

@MainActor
@Test
func consecutiveDocumentUpdatesReloadLatestDocumentWithinSingleLoad() async throws {
    let targetID = ProtocolTarget.ID("page-reload")
    let (backend, transport, context) = try await startTransportBackedContext(
        targetID: targetID,
        documentID: "initial-root"
    )
    let startupMessageCount = await backend.sentTargetMessages().count

    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "DOM.documentUpdated",
        params: "{}"
    )
    let staleReload = try await waitForTransportTargetMessage(
        backend,
        method: "DOM.getDocument",
        ordinal: 0,
        after: startupMessageCount
    )

    let secondUpdateBaseline = context.eventPumpAppliedSequenceForTesting
    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "DOM.documentUpdated",
        params: "{}"
    )
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: secondUpdateBaseline))

    await receiveTransportTargetReply(
        transport,
        targetID: staleReload.targetIdentifier,
        messageID: try transportMessageID(staleReload.message),
        result: transportDocumentResult(nodeID: "stale-root")
    )
    let currentReload = try await waitForTransportTargetMessage(
        backend,
        method: "DOM.getDocument",
        ordinal: 1,
        after: startupMessageCount
    )

    await receiveTransportTargetReply(
        transport,
        targetID: currentReload.targetIdentifier,
        messageID: try transportMessageID(currentReload.message),
        result: transportDocumentResult(nodeID: "current-root")
    )
    try await waitUntil(in: context) {
        context.dom.rootNode?.id == DOMNode.ID(DOM.Node.ID("current-root"))
    }

    #expect(context.dom.rootNode?.id == DOMNode.ID(DOM.Node.ID("current-root")))
    #expect(context.dom.node(for: DOMNode.ID(DOM.Node.ID("stale-root"))) == nil)
}

@MainActor
@Test
func explicitSelectionSupersedesPendingDOMInspectResolution() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.dom.rootNode)
    let selectedID = DOM.Node.ID("manual-selection")
    let inspectedID = DOM.Node.ID("late-inspect-node")

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: selectedID, nodeType: 1, nodeName: "BUTTON", localName: "button")
        ]),
        target: target
    )
    let manualSelection = try await waitForChild(in: context)

    context.apply(.inspect(inspectedID))

    await enqueueCSSStyleReplies(on: runtime.backend)
    context.dom.select(manualSelection)
    try await waitUntil(in: context) { context.dom.selectedNode === manualSelection }

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: selectedID, nodeType: 1, nodeName: "BUTTON", localName: "button"),
            DOM.Node(id: inspectedID, nodeType: 1, nodeName: "DIV", localName: "div"),
        ]),
        target: target
    )
    try await waitUntil(in: context) { context.dom.node(for: DOMNode.ID(inspectedID)) != nil }

    #expect(context.dom.selectedNode === manualSelection)
    #expect(await runtime.backend.recordedCommands().contains(
        RecordedCommand(domain: "DOM", method: "requestChildNodes")
    ) == false)
}

@MainActor
@Test
func domMutationEventForUnmaterializedNodeIsSkipped() async throws {
    // Live pages emit mutation events for nodes WebKit has bound for this
    // frontend but this context has not materialized (attach mid-flight,
    // evicted subtrees). They must be skipped, not fail the context.
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let documentID = DOM.Node.ID("document")
    let childID = DOM.Node.ID("child")

    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: documentID, nodeType: 9, nodeName: "#document", childNodeCount: 1)
    )
    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitForStartupSubscribers(runtime: runtime, target: target)
    try await waitUntil(in: context) { context.dom.rootNode != nil }

    await runtime.backend.emit(
        .attributeModified(DOM.Node.ID("unmaterialized"), name: "class", value: "x"),
        target: target
    )
    await runtime.backend.emit(
        .setChildNodes(parent: documentID, nodes: [
            DOM.Node(id: childID, nodeType: 1, nodeName: "DIV", localName: "div", childNodeCount: 0)
        ]),
        target: target
    )

    let child = try await waitForChild(in: context)
    #expect(child.id == DOMNode.ID(childID))
    #expect(context.state == .attached)
}

@MainActor
@Test
func transportBackedInspectorInspectMaterializesSelectionAndRestoresPersistentHighlight() async throws {
    let targetID = ProtocolTarget.ID("page-main")
    let inspectedID = DOM.Node.ID("42")
    let (backend, transport, context) = try await startTransportBackedContext(
        targetID: targetID,
        documentID: "1"
    )
    let startupMessageCount = await backend.sentTargetMessages().count

    let enablePickerTask = Task { @MainActor in
        try await context.dom.setElementPickerEnabled(true)
    }
    let inspectMode = try await waitForTransportTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: startupMessageCount
    )
    #expect(inspectMode.targetIdentifier == targetID)
    await receiveTransportTargetReply(
        transport,
        targetID: inspectMode.targetIdentifier,
        messageID: try transportMessageID(inspectMode.message),
        result: "{}"
    )
    try await enablePickerTask.value
    #expect(context.dom.isElementPickerEnabled)

    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Inspector.inspect",
        params: #"{"object":{"type":"object","subtype":"node","objectId":"node-object"}}"#
    )
    let requestNode = try await waitForTransportTargetMessage(
        backend,
        method: "DOM.requestNode",
        after: startupMessageCount
    )
    #expect(requestNode.targetIdentifier == targetID)
    #expect(try transportTargetMessageParameters(requestNode.message)["objectId"] as? String == "node-object")

    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "DOM.setChildNodes",
        params: ##"{"parentId":"1","nodes":[{"nodeId":42,"nodeType":1,"nodeName":"DIV","localName":"div","nodeValue":"","childNodeCount":0}]}"##
    )
    await receiveTransportTargetReply(
        transport,
        targetID: requestNode.targetIdentifier,
        messageID: try transportMessageID(requestNode.message),
        result: #"{"nodeId":42}"#
    )

    try await waitUntil(in: context) { context.dom.selectedNode?.id == DOMNode.ID(inspectedID) }
    #expect(context.dom.isElementPickerEnabled == false)

    let persistentHighlight = try await waitForTransportTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: startupMessageCount
    )
    #expect(persistentHighlight.targetIdentifier == targetID)
    #expect(
        (try transportTargetMessageParameters(persistentHighlight.message)["nodeId"] as? NSNumber)?.intValue
            == 42
    )
    await receiveTransportTargetReply(
        transport,
        targetID: persistentHighlight.targetIdentifier,
        messageID: try transportMessageID(persistentHighlight.message),
        result: "{}"
    )

    let cssEnable = try await waitForTransportTargetMessage(
        backend,
        method: "CSS.enable",
        after: startupMessageCount
    )
    #expect(cssEnable.targetIdentifier == targetID)
    await receiveTransportTargetReply(
        transport,
        targetID: cssEnable.targetIdentifier,
        messageID: try transportMessageID(cssEnable.message),
        result: "{}"
    )

    let matchedStyles = try await waitForTransportTargetMessage(
        backend,
        method: "CSS.getMatchedStylesForNode",
        after: startupMessageCount
    )
    #expect(matchedStyles.targetIdentifier == targetID)
    await receiveTransportTargetReply(
        transport,
        targetID: matchedStyles.targetIdentifier,
        messageID: try transportMessageID(matchedStyles.message),
        result: #"{"matchedCSSRules":[],"inherited":[],"pseudoElements":[]}"#
    )

    let inlineStyles = try await waitForTransportTargetMessage(
        backend,
        method: "CSS.getInlineStylesForNode",
        after: startupMessageCount
    )
    #expect(inlineStyles.targetIdentifier == targetID)
    await receiveTransportTargetReply(
        transport,
        targetID: inlineStyles.targetIdentifier,
        messageID: try transportMessageID(inlineStyles.message),
        result: "{}"
    )

    let computedStyle = try await waitForTransportTargetMessage(
        backend,
        method: "CSS.getComputedStyleForNode",
        after: startupMessageCount
    )
    #expect(computedStyle.targetIdentifier == targetID)
    await receiveTransportTargetReply(
        transport,
        targetID: computedStyle.targetIdentifier,
        messageID: try transportMessageID(computedStyle.message),
        result: #"{"computedStyle":[]}"#
    )

    try await waitUntil(in: context) { context.dom.selectedNode?.elementStyles?.phase == .loaded }
}

@MainActor
@Test
func transportBackedFrameNavigationClearsSelectionPresentationHighlight() async throws {
    let targetID = ProtocolTarget.ID("page-main")
    let inspectedID = DOM.Node.ID("42")
    let (backend, transport, context) = try await startTransportBackedContext(
        targetID: targetID,
        documentID: "1"
    )
    let startupMessageCount = await backend.sentTargetMessages().count

    let enablePickerTask = Task { @MainActor in
        try await context.dom.setElementPickerEnabled(true)
    }
    let inspectMode = try await waitForTransportTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: startupMessageCount
    )
    await receiveTransportTargetReply(
        transport,
        targetID: inspectMode.targetIdentifier,
        messageID: try transportMessageID(inspectMode.message),
        result: "{}"
    )
    try await enablePickerTask.value

    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Inspector.inspect",
        params: #"{"object":{"type":"object","subtype":"node","objectId":"node-object"}}"#
    )
    let requestNode = try await waitForTransportTargetMessage(
        backend,
        method: "DOM.requestNode",
        after: startupMessageCount
    )
    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "DOM.setChildNodes",
        params: ##"{"parentId":"1","nodes":[{"nodeId":42,"nodeType":1,"nodeName":"DIV","localName":"div","nodeValue":"","childNodeCount":0}]}"##
    )
    await receiveTransportTargetReply(
        transport,
        targetID: requestNode.targetIdentifier,
        messageID: try transportMessageID(requestNode.message),
        result: #"{"nodeId":42}"#
    )
    try await waitUntil(in: context) { context.dom.selectedNode?.id == DOMNode.ID(inspectedID) }

    let highlightTask = Task { @MainActor in
        let selectedNode = try #require(context.dom.selectedNode)
        try await context.dom.highlight(selectedNode)
    }

    let highlight = try await waitForTransportTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: startupMessageCount
    )
    await receiveTransportTargetReply(
        transport,
        targetID: highlight.targetIdentifier,
        messageID: try transportMessageID(highlight.message),
        result: "{}"
    )
    try await highlightTask.value

    let beforeNavigationMessageCount = await backend.sentTargetMessages().count
    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Page.frameNavigated",
        params: #"{"frame":{"id":"main-frame","loaderId":"loader-2","name":"Main","url":"https://example.test/next","securityOrigin":"https://example.test","mimeType":"text/html"}}"#
    )

    let hideHighlight = try await waitForTransportTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: beforeNavigationMessageCount
    )
    #expect(hideHighlight.targetIdentifier == targetID)
    await receiveTransportTargetReply(
        transport,
        targetID: hideHighlight.targetIdentifier,
        messageID: try transportMessageID(hideHighlight.message),
        result: "{}"
    )

    let getDocument = try await waitForTransportTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: beforeNavigationMessageCount
    )
    await receiveTransportTargetReply(
        transport,
        targetID: getDocument.targetIdentifier,
        messageID: try transportMessageID(getDocument.message),
        result: transportDocumentResult(nodeID: "2")
    )

    try await waitUntil(in: context) { context.dom.rootNode?.id == DOMNode.ID(DOM.Node.ID("2")) }
    #expect(context.dom.selectedNode == nil)
}

@MainActor
@Test
func domUndoRedoCommandsFailAfterCurrentPageRetarget() async throws {
    let oldTargetID = ProtocolTarget.ID("page-undo-old")
    let newTargetID = ProtocolTarget.ID("page-undo-new")
    let (backend, transport, context) = try await startTransportBackedContext(
        targetID: oldTargetID,
        documentID: "undo-old-root"
    )
    let undoCommands = try context.domUndoRedoCommands()
    let startupMessageCount = await backend.sentTargetMessages().count

    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-undo-new","type":"page","frameId":"main-frame","isProvisional":true}}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-undo-old","newTargetId":"page-undo-new"}}"#
    )

    try await replyTransportInspectorAndPageInitialization(
        backend,
        transport: transport,
        targetID: newTargetID,
        after: startupMessageCount,
        includePageEnable: false
    )

    let runtimeEnable = try await waitForTransportTargetMessage(
        backend,
        method: "Runtime.enable",
        after: startupMessageCount
    )
    await receiveTransportTargetReply(
        transport,
        targetID: runtimeEnable.targetIdentifier,
        messageID: try transportMessageID(runtimeEnable.message),
        result: "{}"
    )

    let networkEnable = try await waitForTransportTargetMessage(
        backend,
        method: "Network.enable",
        after: startupMessageCount
    )
    await receiveTransportTargetReply(
        transport,
        targetID: networkEnable.targetIdentifier,
        messageID: try transportMessageID(networkEnable.message),
        result: "{}"
    )

    try await replyTransportResourceTreeUnavailable(
        backend,
        transport: transport,
        after: startupMessageCount
    )

    let getDocument = try await waitForTransportTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: startupMessageCount
    )
    #expect(getDocument.targetIdentifier == newTargetID)
    await receiveTransportTargetReply(
        transport,
        targetID: getDocument.targetIdentifier,
        messageID: try transportMessageID(getDocument.message),
        result: transportDocumentResult(nodeID: "undo-new-root")
    )

    let consoleEnable = try await waitForTransportTargetMessage(
        backend,
        method: "Console.enable",
        after: startupMessageCount
    )
    await receiveTransportTargetReply(
        transport,
        targetID: consoleEnable.targetIdentifier,
        messageID: try transportMessageID(consoleEnable.message),
        result: "{}"
    )

    try await waitUntil(in: context) { context.dom.rootNode?.id == DOMNode.ID(DOM.Node.ID("undo-new-root")) }
    await #expect(throws: WebInspectorProxyError.disconnected("DOM undo/redo target is no longer current.")) {
        try await undoCommands.undo()
    }

    let sentMethods = try await backend.sentTargetMessages().map { message in
        try transportTargetMessageMethod(message.message)
    }
    #expect(!sentMethods.contains("DOM.undo"))
}

@MainActor
@Test
func documentUpdatedReloadsRootDocument() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.dom.rootNode)
    await runtime.backend.enqueue((), for: "DOM", method: "setAttributeValue")
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    try await context.dom.setAttribute("data-before-reset", value: "1", on: document)
    let undoCommands = try context.domUndoRedoCommands()
    let controller = context.dom.treeController()
    let recorder = DOMTreeUpdateRecorder(stream: controller.updates)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()
    try await recorder.waitForUpdateCount(1)
    let replacementID = DOM.Node.ID("replacement-document")

    await runtime.backend.enqueue(
        DOM.Node(id: replacementID, nodeType: 9, nodeName: "#document"),
        for: "DOM",
        method: "getDocument"
    )

    await runtime.backend.emit(.documentUpdated, target: target)

    try await waitUntil(in: context) {
        context.dom.rootNode?.id == DOMNode.ID(replacementID)
    }
    try await waitUntil {
        recorder.updates.contains { update in
            guard case let .snapshot(snapshot, .documentUpdated) = update else {
                return false
            }
            return snapshot.rootNodeID == DOMNode.ID(replacementID)
        }
    }
    let resetUpdateIndex = try #require(recorder.updates.firstIndex { update in
        guard case let .snapshot(snapshot, .reset) = update else {
            return false
        }
        return snapshot.rootNodeID == nil
    })
    let documentUpdatedIndex = try #require(recorder.updates.firstIndex { update in
        guard case let .snapshot(snapshot, .documentUpdated) = update else {
            return false
        }
        return snapshot.rootNodeID == DOMNode.ID(replacementID)
    })
    #expect(resetUpdateIndex < documentUpdatedIndex)
    await #expect(throws: WebInspectorProxyError.disconnected("DOM undo/redo target is no longer current.")) {
        try await undoCommands.undo()
    }
    await runtime.backend.enqueue((), for: "DOM", method: "undo")
    await #expect(throws: WebInspectorProxyError.disconnected("DOM undo/redo target is no longer current.")) {
        try await context.dom.undo()
    }

    let commands = await runtime.backend.recordedCommands()
    #expect(!commands.contains { $0.domain == "DOM" && $0.method == "undo" })
}

@MainActor
@Test
func childInsertIntoKnownEmptyParentMaterializesFirstChild() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.dom.rootNode)
    let insertedID = DOM.Node.ID("inserted-child")

    await runtime.backend.emit(
        .childNodeInserted(
            parent: document.id.proxyID,
            previous: nil,
            node: DOM.Node(
                id: insertedID,
                nodeType: 1,
                nodeName: "DIV",
                localName: "div"
            )
        ),
        target: target
    )

    try await waitUntil(in: context) {
        context.dom.node(for: DOMNode.ID(insertedID)) != nil
    }
    guard case let .loaded(children) = document.children else {
        Issue.record("Expected the first inserted child to make a known-empty parent complete.")
        return
    }
    #expect(children.map(\.id) == [DOMNode.ID(insertedID)])
}

@MainActor
@Test
func childInsertIntoNonemptyUnrequestedParentDoesNotMarkChildrenLoaded() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(
        runtime: runtime,
        document: DOM.Node(
            id: DOM.Node.ID("document"),
            nodeType: 9,
            nodeName: "#document",
            childNodeCount: 1
        )
    )
    let document = try #require(context.dom.rootNode)
    let insertedID = DOM.Node.ID("inserted-child")

    await runtime.backend.emit(
        .childNodeInserted(
            parent: document.id.proxyID,
            previous: nil,
            node: DOM.Node(
                id: insertedID,
                nodeType: 1,
                nodeName: "DIV",
                localName: "div"
            )
        ),
        target: target
    )

    try await waitUntil {
        document.childNodeCount == 2
    }
    guard case let .unrequested(count) = document.children else {
        Issue.record("Expected an incomplete nonempty parent to stay unrequested.")
        return
    }
    #expect(count == 2)
    #expect(context.dom.node(for: DOMNode.ID(insertedID)) == nil)
}

@MainActor
@Test
func domTreeControllerPublishesInitialSnapshotAndChildDeltas() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(
        runtime: runtime,
        document: DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document", childNodeCount: 1)
    )
    let document = try #require(context.dom.rootNode)
    let controller = context.dom.treeController()
    let recorder = DOMTreeUpdateRecorder(stream: controller.updates)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()
    try await recorder.waitForUpdateCount(1)

    #expect(controller.snapshot.rootNodeID == document.id)
    #expect(Set(controller.snapshot.nodesByID.keys) == Set([document.id]))
    #expect(controller.snapshot.node(for: document.id)?.children == .unrequested(count: 1))
    guard case let .snapshot(initialSnapshot, .initialDocument) = recorder.updates.first else {
        Issue.record("Expected initial DOM tree snapshot.")
        return
    }
    #expect(initialSnapshot.node(for: document.id)?.children == .unrequested(count: 1))

    let childID = DOM.Node.ID("child")
    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: childID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )

    try await recorder.waitForUpdateCount(2)
    guard case let .delta(childrenChanged) = recorder.updates.last else {
        Issue.record("Expected DOM children replacement delta.")
        return
    }
    #expect(childrenChanged == .childrenReplaced(parentID: document.id, childIDs: [DOMNode.ID(childID)]))
    #expect(controller.snapshot.children(of: document.id) == [DOMNode.ID(childID)])
    #expect(controller.snapshot.parent(of: DOMNode.ID(childID)) == document.id)
}

@MainActor
@Test
func domTreeControllerPrunesRetainedChildDescendantsOnReplacement() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(
        runtime: runtime,
        document: DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document", childNodeCount: 1)
    )
    let document = try #require(context.dom.rootNode)
    let controller = context.dom.treeController()
    let recorder = DOMTreeUpdateRecorder(stream: controller.updates)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()
    try await recorder.waitForUpdateCount(1)

    let childID = DOM.Node.ID("child")
    let removedSpanID = DOM.Node.ID("removed-span")
    let removedEmID = DOM.Node.ID("removed-em")
    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(
                id: childID,
                nodeType: 1,
                nodeName: "DIV",
                localName: "div",
                children: [
                    DOM.Node(id: removedSpanID, nodeType: 1, nodeName: "SPAN", localName: "span"),
                    DOM.Node(id: removedEmID, nodeType: 1, nodeName: "EM", localName: "em"),
                ]
            )
        ]),
        target: target
    )

    try await recorder.waitForUpdateCount(2)
    #expect(controller.snapshot.node(for: DOMNode.ID(removedSpanID)) != nil)
    #expect(controller.snapshot.node(for: DOMNode.ID(removedEmID)) != nil)
    let child = try #require(context.dom.node(for: DOMNode.ID(childID)))

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: childID, nodeType: 1, nodeName: "DIV", localName: "div", childNodeCount: 0)
        ]),
        target: target
    )

    try await recorder.waitForUpdateCount(3)
    try await waitUntil(in: context) {
        context.dom.node(for: DOMNode.ID(removedSpanID)) == nil
            && context.dom.node(for: DOMNode.ID(removedEmID)) == nil
    }
    #expect(context.dom.node(for: DOMNode.ID(childID)) === child)
    #expect(controller.snapshot.node(for: DOMNode.ID(childID)) != nil)
    #expect(controller.snapshot.node(for: DOMNode.ID(removedSpanID)) == nil)
    #expect(controller.snapshot.node(for: DOMNode.ID(removedEmID)) == nil)
    #expect(controller.snapshot.parent(of: DOMNode.ID(removedEmID)) == nil)
}

@MainActor
@Test
func domTreeControllerPublishesAssociatedSubtreeDeltas() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(
        runtime: runtime,
        document: DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document", childNodeCount: 1)
    )
    let document = try #require(context.dom.rootNode)
    let controller = context.dom.treeController()
    let recorder = DOMTreeUpdateRecorder(stream: controller.updates)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()
    try await recorder.waitForUpdateCount(1)

    let iframeID = DOM.Node.ID("iframe")
    let frameDocumentID = DOM.Node.ID("frame-document")
    let frameBodyID = DOM.Node.ID("frame-body")
    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(
                id: iframeID,
                nodeType: 1,
                nodeName: "IFRAME",
                localName: "iframe",
                frameID: FrameID("child-frame"),
                childNodeCount: 0,
                contentDocument: DOM.Node(
                    id: frameDocumentID,
                    nodeType: 9,
                    nodeName: "#document",
                    children: [
                        DOM.Node(id: frameBodyID, nodeType: 1, nodeName: "BODY", localName: "body")
                    ]
                )
            )
        ]),
        target: target
    )

    try await recorder.waitForUpdateCount(2)
    guard case let .delta(childrenChanged) = recorder.updates.last else {
        Issue.record("Expected associated subtree replacement delta.")
        return
    }
    #expect(childrenChanged == .childrenReplaced(parentID: document.id, childIDs: [DOMNode.ID(iframeID)]))
    #expect(controller.snapshot.visibleChildren(of: DOMNode.ID(iframeID)).nodeIDs == [DOMNode.ID(frameDocumentID)])
    #expect(controller.snapshot.parent(of: DOMNode.ID(frameDocumentID)) == DOMNode.ID(iframeID))
    #expect(controller.snapshot.parent(of: DOMNode.ID(frameBodyID)) == DOMNode.ID(frameDocumentID))
}

@MainActor
@Test
func domTreeControllerAppliesDynamicShadowAndPseudoElementDeltas() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(
        runtime: runtime,
        document: DOM.Node(
            id: DOM.Node.ID("document"),
            nodeType: 9,
            nodeName: "#document",
            childNodeCount: 1
        )
    )
    let document = try #require(context.dom.rootNode)
    let controller = context.dom.treeController()
    let recorder = DOMTreeUpdateRecorder(stream: controller.updates)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()
    try await recorder.waitForUpdateCount(1)

    let hostID = DOM.Node.ID("shadow-host")
    let shadowRootID = DOM.Node.ID("dynamic-shadow-root")
    let shadowChildID = DOM.Node.ID("dynamic-shadow-child")
    let beforePseudoID = DOM.Node.ID("dynamic-before-pseudo")

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: hostID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )
    try await recorder.waitForUpdateCount(2)
    let host = try #require(context.dom.node(for: DOMNode.ID(hostID)))

    await runtime.backend.emit(
        .shadowRootPushed(
            host: hostID,
            root: DOM.Node(
                id: shadowRootID,
                nodeType: 11,
                nodeName: "#shadow-root",
                children: [
                    DOM.Node(
                        id: shadowChildID,
                        nodeType: 1,
                        nodeName: "SPAN",
                        localName: "span"
                    )
                ],
                shadowRootType: .open
            )
        ),
        target: target
    )

    try await recorder.waitForUpdateCount(3)
    #expect(host.shadowRoots.map(\.id) == [DOMNode.ID(shadowRootID)])
    #expect(
        controller.snapshot.visibleChildren(of: DOMNode.ID(hostID)).nodeIDs == [DOMNode.ID(shadowRootID)]
    )
    #expect(controller.snapshot.parent(of: DOMNode.ID(shadowRootID)) == DOMNode.ID(hostID))
    #expect(controller.snapshot.parent(of: DOMNode.ID(shadowChildID)) == DOMNode.ID(shadowRootID))
    #expect(recorder.updates.last == .delta(.childrenReplaced(
        parentID: DOMNode.ID(hostID),
        childIDs: [DOMNode.ID(shadowRootID)]
    )))

    await runtime.backend.emit(
        .pseudoElementAdded(
            parent: hostID,
            element: DOM.Node(
                id: beforePseudoID,
                nodeType: 1,
                nodeName: "::before",
                pseudoType: .before
            )
        ),
        target: target
    )

    try await recorder.waitForUpdateCount(4)
    #expect(host.beforePseudoElement?.id == DOMNode.ID(beforePseudoID))
    #expect(controller.snapshot.visibleChildren(of: DOMNode.ID(hostID)).nodeIDs == [
        DOMNode.ID(beforePseudoID),
        DOMNode.ID(shadowRootID),
    ])
    #expect(controller.snapshot.parent(of: DOMNode.ID(beforePseudoID)) == DOMNode.ID(hostID))

    await runtime.backend.emit(
        .pseudoElementRemoved(parent: hostID, element: beforePseudoID),
        target: target
    )

    try await recorder.waitForUpdateCount(5)
    #expect(host.beforePseudoElement == nil)
    #expect(context.dom.node(for: DOMNode.ID(beforePseudoID)) == nil)
    #expect(
        controller.snapshot.visibleChildren(of: DOMNode.ID(hostID)).nodeIDs == [DOMNode.ID(shadowRootID)]
    )

    await runtime.backend.emit(
        .shadowRootPopped(host: hostID, root: shadowRootID),
        target: target
    )

    try await recorder.waitForUpdateCount(6)
    #expect(host.shadowRoots.isEmpty)
    #expect(context.dom.node(for: DOMNode.ID(shadowRootID)) == nil)
    #expect(context.dom.node(for: DOMNode.ID(shadowChildID)) == nil)
    #expect(controller.snapshot.visibleChildren(of: DOMNode.ID(hostID)).nodeIDs == [])
}

@MainActor
@Test
func domTreeControllerPublishesOnlyDeltasForSameDocumentMutations() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(
        runtime: runtime,
        document: DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document", childNodeCount: 1)
    )
    let document = try #require(context.dom.rootNode)
    let controller = context.dom.treeController()
    let recorder = DOMTreeUpdateRecorder(stream: controller.updates)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()
    try await recorder.waitForUpdateCount(1)

    let elementID = DOM.Node.ID("element")
    let textID = DOM.Node.ID("text")
    let insertedID = DOM.Node.ID("inserted")

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div", childNodeCount: 1)
        ]),
        target: target
    )
    try await recorder.waitForUpdateCount(2)

    await runtime.backend.emit(
        .attributeModified(elementID, name: "class", value: "selected"),
        target: target
    )
    try await waitUntil(in: context) { context.dom.node(for: DOMNode.ID(elementID))?.attributes["class"] == "selected" }
    try await recorder.waitForUpdateCount(3)

    await runtime.backend.emit(
        .childNodeCountUpdated(elementID, count: 1),
        target: target
    )
    try await waitUntil(in: context) { context.dom.node(for: DOMNode.ID(elementID))?.childNodeCount == 1 }
    try await recorder.waitForUpdateCount(4)

    await runtime.backend.emit(
        .setChildNodes(parent: elementID, nodes: [
            DOM.Node(id: textID, nodeType: 3, nodeName: "#text", nodeValue: "old")
        ]),
        target: target
    )
    try await recorder.waitForUpdateCount(5)

    await runtime.backend.emit(
        .characterDataModified(textID, value: "new"),
        target: target
    )
    try await waitUntil(in: context) { context.dom.node(for: DOMNode.ID(textID))?.nodeValue == "new" }
    try await recorder.waitForUpdateCount(6)

    await runtime.backend.emit(
        .childNodeInserted(
            parent: document.id.proxyID,
            previous: elementID,
            node: DOM.Node(id: insertedID, nodeType: 1, nodeName: "SPAN", localName: "span")
        ),
        target: target
    )
    try await recorder.waitForUpdateCount(7)

    await runtime.backend.emit(
        .childNodeRemoved(parent: document.id.proxyID, node: insertedID),
        target: target
    )
    try await recorder.waitForUpdateCount(8)

    let mutationUpdates = Array(recorder.updates.dropFirst())
    #expect(mutationUpdates.allSatisfy { update in
        guard case .delta = update else {
            return false
        }
        return true
    })
    #expect(mutationUpdates == [
        .delta(.childrenReplaced(parentID: document.id, childIDs: [DOMNode.ID(elementID)])),
        .delta(.nodeChanged(nodeID: DOMNode.ID(elementID))),
        .delta(.childCountChanged(nodeID: DOMNode.ID(elementID))),
        .delta(.childrenReplaced(parentID: DOMNode.ID(elementID), childIDs: [DOMNode.ID(textID)])),
        .delta(.nodeChanged(nodeID: DOMNode.ID(textID))),
        .delta(.childInserted(
            parentID: document.id,
            nodeID: DOMNode.ID(insertedID),
            previousSiblingID: DOMNode.ID(elementID)
        )),
        .delta(.childRemoved(parentID: document.id, nodeID: DOMNode.ID(insertedID))),
    ])
}

@MainActor
@Test
func domTreeControllerSnapshotIncludesRecursiveDOMAssociations() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let documentID = DOM.Node.ID("document")
    let iframeID = DOM.Node.ID("iframe")
    let frameDocumentID = DOM.Node.ID("frame-document")
    let frameBodyID = DOM.Node.ID("frame-body")
    let templateHostID = DOM.Node.ID("template-host")
    let templateContentID = DOM.Node.ID("template-content")
    let shadowHostID = DOM.Node.ID("shadow-host")
    let beforePseudoID = DOM.Node.ID("before-pseudo")
    let shadowRootID = DOM.Node.ID("shadow-root")
    let shadowSpanID = DOM.Node.ID("shadow-span")
    let afterPseudoID = DOM.Node.ID("after-pseudo")
    let ignoredIframeChildID = DOM.Node.ID("ignored-iframe-child")

    let (_, context) = try await startContext(
        runtime: runtime,
        document: DOM.Node(
            id: documentID,
            nodeType: 9,
            nodeName: "#document",
            children: [
                DOM.Node(
                    id: iframeID,
                    nodeType: 1,
                    nodeName: "IFRAME",
                    localName: "iframe",
                    frameID: FrameID("child-frame"),
                    documentURL: "https://example.test/frame",
                    baseURL: "https://example.test/",
                    attributes: ["data-second": "2", "src": "/frame"],
                    attributeList: [
                        DOM.Attribute(name: "src", value: "/frame"),
                        DOM.Attribute(name: "data-second", value: "2"),
                    ],
                    children: [
                        DOM.Node(id: ignoredIframeChildID, nodeType: 1, nodeName: "SPAN", localName: "span")
                    ],
                    contentDocument: DOM.Node(
                        id: frameDocumentID,
                        nodeType: 9,
                        nodeName: "#document",
                        children: [
                            DOM.Node(id: frameBodyID, nodeType: 1, nodeName: "BODY", localName: "body")
                        ]
                    )
                ),
                DOM.Node(
                    id: templateHostID,
                    nodeType: 1,
                    nodeName: "TEMPLATE",
                    localName: "template",
                    templateContent: DOM.Node(
                        id: templateContentID,
                        nodeType: 11,
                        nodeName: "#document-fragment"
                    )
                ),
                DOM.Node(
                    id: shadowHostID,
                    nodeType: 1,
                    nodeName: "DIV",
                    localName: "div",
                    shadowRoots: [
                        DOM.Node(
                            id: shadowRootID,
                            nodeType: 11,
                            nodeName: "#shadow-root",
                            children: [
                                DOM.Node(id: shadowSpanID, nodeType: 1, nodeName: "SPAN", localName: "span")
                            ],
                            shadowRootType: .open
                        )
                    ],
                    beforePseudoElement: DOM.Node(
                        id: beforePseudoID,
                        nodeType: 1,
                        nodeName: "::before",
                        pseudoType: .before
                    ),
                    afterPseudoElement: DOM.Node(
                        id: afterPseudoID,
                        nodeType: 1,
                        nodeName: "::after",
                        pseudoType: .after
                    )
                ),
            ]
        )
    )

    let controller = context.dom.treeController()
    let snapshot = controller.snapshot
    let document = try #require(context.dom.rootNode)
    let iframe = try #require(snapshot.node(for: DOMNode.ID(iframeID)))
    let templateContent = try #require(snapshot.node(for: DOMNode.ID(templateContentID)))
    let shadowRoot = try #require(snapshot.node(for: DOMNode.ID(shadowRootID)))

    #expect(snapshot.displayRootIDs() == [DOMNode.ID(iframeID), DOMNode.ID(templateHostID), DOMNode.ID(shadowHostID)])
    #expect(snapshot.visibleChildren(of: DOMNode.ID(iframeID)).nodeIDs == [DOMNode.ID(frameDocumentID)])
    #expect(snapshot.visibleChildren(of: DOMNode.ID(templateHostID)).nodeIDs == [DOMNode.ID(templateContentID)])
    #expect(snapshot.visibleChildren(of: DOMNode.ID(shadowHostID)).nodeIDs == [
        DOMNode.ID(beforePseudoID),
        DOMNode.ID(shadowRootID),
        DOMNode.ID(afterPseudoID),
    ])
    #expect(snapshot.visibleChildren(of: DOMNode.ID(shadowRootID)).nodeIDs == [DOMNode.ID(shadowSpanID)])
    #expect(snapshot.children(of: DOMNode.ID(iframeID)) == [DOMNode.ID(ignoredIframeChildID)])
    #expect(snapshot.parent(of: DOMNode.ID(frameDocumentID)) == DOMNode.ID(iframeID))
    #expect(snapshot.parent(of: DOMNode.ID(templateContentID)) == DOMNode.ID(templateHostID))
    #expect(snapshot.parent(of: DOMNode.ID(beforePseudoID)) == DOMNode.ID(shadowHostID))
    #expect(snapshot.isTemplateContent(DOMNode.ID(templateContentID)))
    #expect(iframe.kind == DOMNode.Kind.element)
    #expect(iframe.frameID == FrameID("child-frame"))
    #expect(iframe.documentURL == "https://example.test/frame")
    #expect(iframe.baseURL == "https://example.test/")
    #expect(iframe.attributes["src"] == "/frame")
    #expect(iframe.attributeList.map(\.name) == ["src", "data-second"])
    #expect(iframe.contentDocumentID == DOMNode.ID(frameDocumentID))
    #expect(templateContent.kind == DOMNode.Kind.documentFragment)
    #expect(shadowRoot.shadowRootType == DOM.ShadowRootType.open)
    #expect(document.contentDocument == nil)
}

@MainActor
@Test
func domTreeControllerPublishesSelectionDeltasWithoutOwningExpansion() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(
        runtime: runtime,
        document: DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document")
    )
    let document = try #require(context.dom.rootNode)
    let parentID = DOM.Node.ID("parent")
    let childID = DOM.Node.ID("child")

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(
                id: parentID,
                nodeType: 1,
                nodeName: "SECTION",
                localName: "section",
                children: [
                    DOM.Node(id: childID, nodeType: 1, nodeName: "SPAN", localName: "span")
                ]
            )
        ]),
        target: target
    )

    try await waitUntil(in: context) { context.dom.node(for: DOMNode.ID(childID)) != nil }
    let parent = try #require(context.dom.node(for: DOMNode.ID(parentID)))
    let child = try #require(context.dom.node(for: DOMNode.ID(childID)))
    let controller = context.dom.treeController()
    let recorder = DOMTreeUpdateRecorder(stream: controller.updates)
    let revealRecorder = DOMTreeRevealRequestRecorder(stream: controller.revealRequests)
    defer { recorder.cancel() }
    defer { revealRecorder.cancel() }
    try await recorder.waitUntilStarted()
    try await revealRecorder.waitUntilStarted()
    try await recorder.waitForUpdateCount(1)

    #expect(controller.snapshot.children(of: document.id) == [parent.id])
    #expect(controller.snapshot.children(of: parent.id) == [child.id])
    #expect(controller.snapshot.ancestorNodeIDs(of: child.id) == [parent.id, document.id])

    await enqueueCSSStyleReplies(on: runtime.backend)
    context.dom.select(child, reveal: .selectOnly)

    try await recorder.waitForUpdateCount(2)
    try await revealRecorder.waitForRequestCount(1)
    guard case let .delta(selection) = recorder.updates.last else {
        Issue.record("Expected DOM selection delta.")
        return
    }
    #expect(selection == .selectionChanged(nodeID: child.id))
    #expect(controller.snapshot.selectedNodeID == child.id)
    #expect(revealRecorder.requests.last == DOMTreeRevealRequest(
        nodeID: child.id,
        ancestorNodeIDs: [parent.id, document.id],
        shouldSelect: true,
        shouldScroll: false
    ))

    context.dom.select(nil)

    try await recorder.waitForUpdateCount(3)
    guard case let .delta(selectionCleared) = recorder.updates.last else {
        Issue.record("Expected DOM selection clear delta.")
        return
    }
    #expect(selectionCleared == .selectionChanged(nodeID: nil))
    #expect(controller.snapshot.selectedNodeID == nil)

    context.dom.select(document, reveal: .none)
    try await recorder.waitForUpdateCount(4)
    #expect(revealRecorder.requests.count == 1)
}

@MainActor
@Test
func setChildNodesReplacementPublishesSelectionClearingForRemovedDescendant() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(
        runtime: runtime,
        document: DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document")
    )
    let document = try #require(context.dom.rootNode)
    let parentID = DOM.Node.ID("parent")
    let selectedID = DOM.Node.ID("selected-text")
    let replacementID = DOM.Node.ID("replacement-text")

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(
                id: parentID,
                nodeType: 1,
                nodeName: "DIV",
                localName: "div",
                children: [
                    DOM.Node(id: selectedID, nodeType: 3, nodeName: "#text", nodeValue: "selected")
                ]
            )
        ]),
        target: target
    )
    try await waitUntil(in: context) { context.dom.node(for: DOMNode.ID(selectedID)) != nil }

    let selected = try #require(context.dom.node(for: DOMNode.ID(selectedID)))
    let controller = context.dom.treeController()
    let recorder = DOMTreeUpdateRecorder(stream: controller.updates)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()
    try await recorder.waitForUpdateCount(1)

    context.dom.select(selected)
    try await recorder.waitForUpdateCount(2)
    #expect(controller.snapshot.selectedNodeID == selected.id)

    await runtime.backend.emit(
        .setChildNodes(parent: parentID, nodes: [
            DOM.Node(id: replacementID, nodeType: 3, nodeName: "#text", nodeValue: "replacement")
        ]),
        target: target
    )

    try await waitUntil(in: context) {
        context.dom.selectedNode == nil
            && context.dom.node(for: DOMNode.ID(selectedID)) == nil
            && context.dom.node(for: DOMNode.ID(replacementID)) != nil
    }
    try await waitUntil {
        recorder.updates.contains(.delta(.selectionChanged(nodeID: nil)))
    }
    #expect(controller.snapshot.selectedNodeID == nil)
}

@MainActor
@Test
func setChildNodesPreservesReparentedDescendantIdentity() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let documentID = DOM.Node.ID("document")
    let oldParentID = DOM.Node.ID("old-parent")
    let newParentID = DOM.Node.ID("new-parent")
    let movedChildID = DOM.Node.ID("moved-child")

    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: documentID, nodeType: 9, nodeName: "#document")
    )

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitForStartupSubscribers(runtime: runtime, target: target)
    try await waitUntil(in: context) { context.dom.rootNode != nil }

    await runtime.backend.emit(
        .setChildNodes(parent: documentID, nodes: [
            DOM.Node(
                id: oldParentID,
                nodeType: 1,
                nodeName: "SECTION",
                localName: "section",
                children: [
                    DOM.Node(id: movedChildID, nodeType: 1, nodeName: "SPAN", localName: "span")
                ]
            )
        ]),
        target: target
    )

    try await waitUntil(in: context) { context.dom.node(for: DOMNode.ID(movedChildID)) != nil }
    let movedChild = try #require(context.dom.node(for: DOMNode.ID(movedChildID)))

    await runtime.backend.emit(
        .setChildNodes(parent: documentID, nodes: [
            DOM.Node(
                id: newParentID,
                nodeType: 1,
                nodeName: "ARTICLE",
                localName: "article",
                children: [
                    DOM.Node(id: movedChildID, nodeType: 1, nodeName: "SPAN", localName: "span")
                ]
            )
        ]),
        target: target
    )

    try await waitUntil(in: context) {
        context.dom.node(for: DOMNode.ID(oldParentID)) == nil
            && context.dom.node(for: DOMNode.ID(newParentID)) != nil
    }
    #expect(context.dom.node(for: DOMNode.ID(movedChildID)) === movedChild)
}

@MainActor
@Test
func setChildNodesPreservesLoadedDescendantsForShallowRefresh() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let documentID = DOM.Node.ID("document")
    let childID = DOM.Node.ID("child")
    let grandchildID = DOM.Node.ID("grandchild")

    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: documentID, nodeType: 9, nodeName: "#document")
    )

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitForStartupSubscribers(runtime: runtime, target: target)
    try await waitUntil(in: context) { context.dom.rootNode != nil }

    await runtime.backend.emit(
        .setChildNodes(parent: documentID, nodes: [
            DOM.Node(
                id: childID,
                nodeType: 1,
                nodeName: "DIV",
                localName: "div",
                children: [
                    DOM.Node(id: grandchildID, nodeType: 1, nodeName: "SPAN", localName: "span")
                ]
            )
        ]),
        target: target
    )

    try await waitUntil(in: context) { context.dom.node(for: DOMNode.ID(grandchildID)) != nil }
    let grandchild = try #require(context.dom.node(for: DOMNode.ID(grandchildID)))

    await runtime.backend.emit(
        .setChildNodes(parent: documentID, nodes: [
            DOM.Node(id: childID, nodeType: 1, nodeName: "DIV", localName: "div", childNodeCount: 1)
        ]),
        target: target
    )

    try await waitUntil(in: context) {
        guard let child = context.dom.node(for: DOMNode.ID(childID)),
              case let .loaded(children) = child.children else {
            return false
        }
        return children.first === grandchild
    }
    #expect(context.dom.node(for: DOMNode.ID(grandchildID)) === grandchild)
}
