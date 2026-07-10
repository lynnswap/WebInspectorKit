import Foundation
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import WebInspectorTestSupport

@MainActor
@Test
func domEventsPopulateRootAndPreserveChildIdentity() async throws {
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()
        let documentID = DOM.Node.ID("document")
        let childID = DOM.Node.ID("child")
        let grandchildID = DOM.Node.ID("grandchild")

        try await enqueueStartupReplies(
            on: runtime.wire,
            document: DOM.Node(id: documentID, nodeType: 9, nodeName: "#document", childNodeCount: 1)
        )

        let container = WebInspectorContainer(proxy: runtime.proxy)
        let context = container.mainContext
        try await waitForStartupSubscribers(runtime: runtime, target: target)
        try await waitUntil { context.rootNode != nil }

        try await runtime.wire.emitRaw(
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
        #expect(context.node(for: child.id) === child)

        try await runtime.wire.emitRaw(
            .attributeModified(childID, name: "class", value: "after"),
            target: target
        )
        try await waitUntil { child.attributes["class"] == "after" }
        #expect(context.node(for: child.id) === child)

        try await runtime.wire.emitRaw(
            .childNodeCountUpdated(childID, count: 2),
            target: target
        )
        try await waitUntil { child.childNodeCount == 2 }
        #expect(context.node(for: child.id) === child)

        try await runtime.wire.emitRaw(
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
        context.select(grandchild)

        try await runtime.wire.emitRaw(
            .childNodeRemoved(parent: documentID, node: childID),
            target: target
        )
        try await waitUntil {
            guard let root = context.rootNode, case let .loaded(children) = root.children else {
                return false
            }
            return children.isEmpty
        }
        #expect(context.node(for: child.id) == nil)
        #expect(context.node(for: grandchild.id) == nil)
        #expect(context.selectedNode == nil)
    }
}

@MainActor
@Test
func requestChildrenDispatchesDOMCommandAndMaterializesSetChildNodes() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let document = try #require(context.rootNode)
        let childID = DOM.Node.ID("requested-child")

        await runtime.wire.respond(to: "DOM.requestChildNodes")

        await document.requestChildren(depth: 2)

        let commands = runtime.wire.observations.commands
        let command = try #require(commands.first {
            $0.method == "DOM.requestChildNodes"
        })
        #expect(try commandStringParameter(command, "nodeId") == document.id.proxyID.rawValue)
        #expect(try commandIntegerParameter(command, "depth") == 2)

        try await runtime.wire.emitRaw(
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
}

@MainActor
@Test
func domTreeSnapshotBuildsSelectorAndXPathFromDataKitProjection() async throws {
    try await withDataKitTestRuntime { runtime in
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
        let tree = try await context.treeController()
        let snapshot = tree.snapshot

        #expect(snapshot.selectorPath(for: DOMNode.ID(documentID)) == "")
        #expect(snapshot.xPath(for: DOMNode.ID(documentID)) == "/")
        #expect(snapshot.selectorPath(for: DOMNode.ID(featuredCardID)) == "body > div.featured")
        #expect(snapshot.xPath(for: DOMNode.ID(featuredCardID)) == "/html/body/div[2]")
        #expect(snapshot.selectorPath(for: DOMNode.ID(inputID)) == "body > input[type=\"search\"]")
        #expect(snapshot.xPath(for: DOMNode.ID(textID)) == "/html/body/text()")
    }
}

@MainActor
@Test
func domCommandsDispatchThroughDataKitContext() async throws {
    try await withDataKitTestRuntime { runtime in
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
        let parent = try #require(context.node(for: DOMNode.ID(parentID)))
        let child = try #require(context.node(for: DOMNode.ID(childID)))

        await runtime.wire.respond(
            to: "DOM.getOuterHTML",
            with: try rawOuterHTMLResult("<span id=\"title\"></span>")
        )
        #expect(try await child.copyText(.html) == "<span id=\"title\"></span>")
        #expect(try await child.copyText(.selectorPath) == "#title")
        #expect(try context.xPath(for: child) == "/html/body/div/span")

        await runtime.wire.respond(to: "DOM.highlightNode")
        try await context.highlightNode(for: child.id)

        await runtime.wire.respond(to: "DOM.hideHighlight")
        try await context.hideHighlight()

        await runtime.wire.respond(to: "DOM.undo")
        try await context.undoDOMChange()

        await runtime.wire.respond(to: "DOM.redo")
        try await context.redoDOMChange()

        await runtime.wire.respond(to: "DOM.setInspectModeEnabled")
        try await context.setElementPickerEnabled(true)
        #expect(context.isElementPickerEnabled)

        try await enqueueCSSStyleReplies(on: runtime.wire)
        await runtime.wire.respond(to: "DOM.highlightNode")
        try await runtime.wire.emitRaw(.inspect(childID), target: target)
        try await waitUntil { context.selectedNode === child }
        try await waitUntil { child.elementStyles?.phase == .loaded }
        #expect(context.isElementPickerEnabled == false)

        await runtime.wire.respond(to: "DOM.setAttributeValue")
        await runtime.wire.respond(to: "DOM.markUndoableState")
        try await context.setDOMAttribute(
            "class",
            value: "updated",
            on: parent.id,
            options: .automatic
        )

        await runtime.wire.respond(to: "DOM.setOuterHTML")
        await runtime.wire.respond(to: "DOM.markUndoableState")
        try await context.setDOMOuterHTML(
            "<span id=\"title\"></span>",
            of: child.id,
            options: .automatic
        )

        await runtime.wire.respond(to: "DOM.removeNode")
        await runtime.wire.respond(to: "DOM.removeNode")
        await runtime.wire.respond(to: "DOM.markUndoableState")
        await runtime.wire.respond(to: "DOM.markUndoableState")
        let deletion = try await context.removeDOMNodes(
            [parent.id, child.id],
            options: .automatic
        )
        #expect(deletion.acceptedNodeIDs == [child.id, parent.id])
        #expect(context.selectedNode == nil)
        #expect(child.elementStyles == nil)

        await runtime.wire.respond(to: "Page.reload")
        try await context.reloadPage(ignoringCache: true)

        let commands = runtime.wire.observations.commands
        let outerHTML = try #require(commands.first { $0.method == "DOM.getOuterHTML" })
        #expect(try commandStringParameter(outerHTML, "nodeId") == childID.rawValue)

        let highlight = try #require(commands.first { $0.method == "DOM.highlightNode" })
        #expect(try commandStringParameter(highlight, "nodeId") == childID.rawValue)

        #expect(commands.contains { $0.method == "DOM.undo" })
        #expect(commands.contains { $0.method == "DOM.redo" })

        let inspectMode = try #require(commands.first { $0.method == "DOM.setInspectModeEnabled" })
        #expect(try commandBooleanParameter(inspectMode, "enabled"))

        let setAttribute = try #require(commands.first { $0.method == "DOM.setAttributeValue" })
        #expect(try commandStringParameter(setAttribute, "nodeId") == parentID.rawValue)
        #expect(try commandStringParameter(setAttribute, "name") == "class")
        #expect(try commandStringParameter(setAttribute, "value") == "updated")

        let setOuterHTML = try #require(commands.first { $0.method == "DOM.setOuterHTML" })
        #expect(try commandStringParameter(setOuterHTML, "nodeId") == childID.rawValue)
        #expect(try commandStringParameter(setOuterHTML, "outerHTML") == "<span id=\"title\"></span>")

        let removals = commands.filter { $0.method == "DOM.removeNode" }
        #expect(removals.count == 2)
        let firstRemoval = try #require(removals.first)
        let lastRemoval = try #require(removals.last)
        #expect(try commandStringParameter(firstRemoval, "nodeId") == childID.rawValue)
        #expect(try commandStringParameter(lastRemoval, "nodeId") == parentID.rawValue)
        let undoMarks = commands.filter { $0.method == "DOM.markUndoableState" }
        #expect(undoMarks.count == 4)

        let reload = try #require(commands.first { $0.method == "Page.reload" })
        #expect(try commandBooleanParameter(reload, "ignoreCache"))
    }
}

@MainActor
@Test
func domMutationsAndUndoRedoUseOwningFrameTarget() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let frameTarget = try await createFrameTarget(in: runtime)
        let document = try #require(context.rootNode)
        let scopedNodeID = DOM.Node.ID(
            "frame-owned-node",
            scopedToTargetRawValue: frameTarget.id.rawValue
        )

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: document.id.proxyID, nodes: [
                DOM.Node(id: scopedNodeID, nodeType: 3, nodeName: "#text", nodeValue: "frame")
            ]),
            target: target
        )
        try await waitUntil { context.node(for: DOMNode.ID(scopedNodeID)) != nil }

        await runtime.wire.respond(to: "DOM.setAttributeValue")
        await runtime.wire.respond(to: "DOM.markUndoableState")
        try await context.setDOMAttribute(
            "data-edited",
            value: "page",
            on: document.id,
            options: .automatic
        )

        await runtime.wire.respond(to: "DOM.removeNode")
        await runtime.wire.respond(to: "DOM.markUndoableState")
        _ = try await context.removeDOMNodes(
            [DOMNode.ID(scopedNodeID)],
            options: .automatic
        )

        await runtime.wire.respond(to: "DOM.undo")
        try await context.undoDOMChange()

        await runtime.wire.respond(to: "DOM.redo")
        try await context.redoDOMChange()

        let domCommands = runtime.wire.observations.commands
            .filter {
                [
                    "DOM.setAttributeValue",
                    "DOM.removeNode",
                    "DOM.markUndoableState",
                    "DOM.undo",
                    "DOM.redo",
                ].contains($0.method)
            }
        #expect(domCommands.map(\.method) == [
            "DOM.setAttributeValue",
            "DOM.markUndoableState",
            "DOM.removeNode",
            "DOM.markUndoableState",
            "DOM.undo",
            "DOM.redo",
        ])
        #expect(domCommands.prefix(2).allSatisfy { $0.destination == .target(wireTargetID(target)) })
        let frameCommands = domCommands.dropFirst(2)
        #expect(frameCommands.allSatisfy { $0.destination == .target(wireTargetID(frameTarget)) })
        let removal = try #require(frameCommands.first { $0.method == "DOM.removeNode" })
        #expect(try commandStringParameter(removal, "nodeId") == scopedNodeID.unscopedRawValue)
    }
}

@MainActor
@Test
func domDeleteRejectsCrossTargetSelectionBeforeRemovingNodes() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let frameTarget = try await createFrameTarget(in: runtime)
        let document = try #require(context.rootNode)
        let pageNodeID = DOM.Node.ID("page-node")
        let scopedFrameNodeID = DOM.Node.ID(
            "frame-node",
            scopedToTargetRawValue: frameTarget.id.rawValue
        )

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: document.id.proxyID, nodes: [
                DOM.Node(id: pageNodeID, nodeType: 1, nodeName: "DIV", localName: "div"),
                DOM.Node(id: scopedFrameNodeID, nodeType: 1, nodeName: "SPAN", localName: "span"),
            ]),
            target: target
        )
        try await waitUntil {
            context.node(for: DOMNode.ID(pageNodeID)) != nil
                && context.node(for: DOMNode.ID(scopedFrameNodeID)) != nil
        }

        await #expect(throws: WebInspectorProxyError.commandFailed(
            domain: "DOM",
            method: "removeNode",
            message: "Deleting nodes from multiple DOM targets in one mutation is not supported."
        )) {
            _ = try await context.removeDOMNodes([
                DOMNode.ID(pageNodeID),
                DOMNode.ID(scopedFrameNodeID),
            ], options: .automatic)
        }

        let removeCommands = runtime.wire.observations.commands
            .filter { $0.method == "DOM.removeNode" }
        #expect(removeCommands.isEmpty)
    }
}

@MainActor
@Test
func domInspectSelectsKnownNodeAndLoadsStyles() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let document = try #require(context.rootNode)
        let elementID = DOM.Node.ID("inspect-node")

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: document.id.proxyID, nodes: [
                DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
            ]),
            target: target
        )
        let element = try await waitForChild(in: context)

        try await enqueueCSSStyleReplies(on: runtime.wire)
        await runtime.wire.respond(to: "DOM.highlightNode")
        try await runtime.wire.emitRaw(.inspect(elementID), target: target)

        try await waitUntil { context.selectedNode === element }
        try await waitUntil {
            runtime.wire.observations.commands.contains { command in
                command.method == "DOM.highlightNode"
                    && (try? commandStringParameter(command, "nodeId")) == elementID.rawValue
            }
        }
        let styles = try #require(element.elementStyles)
        try await waitUntil { styles.phase == .loaded }
        #expect(styles.sections.map(\.title) == [".card"])

        let commands = runtime.wire.observations.commands
        #expect(commands.contains { $0.method == "CSS.getMatchedStylesForNode" })
        #expect(commands.contains { $0.method == "CSS.getComputedStyleForNode" })
    }
}

@MainActor
@Test
func domInspectWaitsForRequestNodePathBeforeSelectingUnresolvedNode() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let document = try #require(context.rootNode)
        let staleID = DOM.Node.ID("stale-node")
        let elementID = DOM.Node.ID("resolved-inspect-node")

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: document.id.proxyID, nodes: [
                DOM.Node(id: staleID, nodeType: 1, nodeName: "SPAN", localName: "span")
            ]),
            target: target
        )
        try await waitUntil { context.node(for: DOMNode.ID(staleID)) != nil }

        try await enqueueCSSStyleReplies(on: runtime.wire)
        await runtime.wire.respond(to: "DOM.highlightNode")
        try await runtime.wire.emitRaw(.inspect(elementID), target: target)
        #expect(context.selectedNode == nil)

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: document.id.proxyID, nodes: [
                DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
            ]),
            target: target
        )

        try await waitUntil { context.selectedNode?.id == DOMNode.ID(elementID) }
        try await waitUntil {
            runtime.wire.observations.commands.contains { command in
                command.method == "DOM.highlightNode"
                    && (try? commandStringParameter(command, "nodeId")) == elementID.rawValue
            }
        }
        #expect(context.state == .attached)
        #expect(runtime.wire.observations.commandMethods.contains(
            "DOM.requestChildNodes"
        ) == false)
        #expect(context.node(for: DOMNode.ID(staleID)) == nil)
        let selected = try #require(context.selectedNode)
        let styles = try #require(selected.elementStyles)
        try await waitUntil { styles.phase == .loaded }
    }
}

@MainActor
@Test
func domInspectBeforeDocumentArrivesWaitsForRequestNodePathAfterRootApplies() async throws {
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()
        let documentID = DOM.Node.ID("document")
        let elementID = DOM.Node.ID("deferred-inspect-node")

        let gate = await runtime.wire.deferReply(
            to: "DOM.getDocument",
            with: try domDocumentResult(
                DOM.Node(id: documentID, nodeType: 9, nodeName: "#document")
            )
        )
        await enqueueDomainEnableReplies(on: runtime.wire)

        let container = WebInspectorContainer(proxy: runtime.proxy)
        let context = container.mainContext
        try await waitForStartupSubscribers(runtime: runtime, target: target)
        try await waitUntil {
            runtime.wire.observations.commands
                .contains { $0.method == "DOM.getDocument" }
        }

        try await runtime.wire.emitRaw(.inspect(elementID), target: target)
        await runtime.wire.respond(to: "DOM.highlightNode")
        try await enqueueCSSStyleReplies(on: runtime.wire)
        gate.open()

        try await waitUntil { context.rootNode?.id == DOMNode.ID(documentID) }
        #expect(context.selectedNode == nil)

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: documentID, nodes: [
                DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
            ]),
            target: target
        )

        try await waitUntil { context.selectedNode?.id == DOMNode.ID(elementID) }
        try await waitUntil {
            runtime.wire.observations.commands.contains { command in
                command.method == "DOM.highlightNode"
                    && (try? commandStringParameter(command, "nodeId")) == elementID.rawValue
            }
        }
        let selected = try #require(context.selectedNode)
        let styles = try #require(selected.elementStyles)
        try await waitUntil { styles.phase == .loaded }
        #expect(runtime.wire.observations.commandMethods.contains(
            "DOM.requestChildNodes"
        ) == false)
    }
}

@MainActor
@Test
func explicitSelectionSupersedesPendingDOMInspectResolution() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let document = try #require(context.rootNode)
        let selectedID = DOM.Node.ID("manual-selection")
        let inspectedID = DOM.Node.ID("late-inspect-node")

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: document.id.proxyID, nodes: [
                DOM.Node(id: selectedID, nodeType: 1, nodeName: "BUTTON", localName: "button")
            ]),
            target: target
        )
        let manualSelection = try await waitForChild(in: context)

        context.apply(.inspect(inspectedID))

        try await enqueueCSSStyleReplies(on: runtime.wire)
        context.select(manualSelection)
        try await waitUntil { context.selectedNode === manualSelection }

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: document.id.proxyID, nodes: [
                DOM.Node(id: selectedID, nodeType: 1, nodeName: "BUTTON", localName: "button"),
                DOM.Node(id: inspectedID, nodeType: 1, nodeName: "DIV", localName: "div"),
            ]),
            target: target
        )
        try await waitUntil { context.node(for: DOMNode.ID(inspectedID)) != nil }

        #expect(context.selectedNode === manualSelection)
        #expect(runtime.wire.observations.commandMethods.contains(
            "DOM.requestChildNodes"
        ) == false)
    }
}

@MainActor
@Test
func domMutationEventForUnmaterializedNodeIsSkipped() async throws {
    // Live pages emit mutation events for nodes WebKit has bound for this
    // frontend but this context has not materialized (attach mid-flight,
    // evicted subtrees). They must be skipped, not fail the context.
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()
        let documentID = DOM.Node.ID("document")
        let childID = DOM.Node.ID("child")

        try await enqueueStartupReplies(
            on: runtime.wire,
            document: DOM.Node(id: documentID, nodeType: 9, nodeName: "#document", childNodeCount: 1)
        )
        let container = WebInspectorContainer(proxy: runtime.proxy)
        let context = container.mainContext
        try await waitForStartupSubscribers(runtime: runtime, target: target)
        try await waitUntil { context.rootNode != nil }

        try await runtime.wire.emitRaw(
            .attributeModified(DOM.Node.ID("unmaterialized"), name: "class", value: "x"),
            target: target
        )
        try await runtime.wire.emitRaw(
            .setChildNodes(parent: documentID, nodes: [
                DOM.Node(id: childID, nodeType: 1, nodeName: "DIV", localName: "div", childNodeCount: 0)
            ]),
            target: target
        )

        let child = try await waitForChild(in: context)
        #expect(child.id == DOMNode.ID(childID))
        #expect(context.state == .attached)
    }
}

@MainActor
@Test
func startupEnablesTrackedDomainsBeforeInitialDocumentSnapshot() async throws {
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()

        try await enqueueStartupReplies(on: runtime.wire)

        let container = WebInspectorContainer(proxy: runtime.proxy)
        let context = container.mainContext
        try await waitForStartupSubscribers(runtime: runtime, target: target)
        try await waitUntil { context.state == .attached }

        let commands = runtime.wire.observations.commands
        #expect(commands.map(\.method).prefix(startupCommands.count) == startupCommands[...])
    }
}

@MainActor
@Test
func networkEnableFailureFailsStartupBeforeDocumentFetch() async throws {
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()

        await runtime.wire.respond(to: "Inspector.enable")
        await runtime.wire.respond(to: "Inspector.initialized")
        await runtime.wire.respond(to: "Runtime.enable")
        await runtime.wire.fail("Network.enable", message: "Network enable failed.")
        await runtime.wire.respond(to: "Runtime.disable")
        await runtime.wire.respond(to: "Inspector.disable")

        let container = WebInspectorContainer(proxy: runtime.proxy)
        let context = container.mainContext
        try await waitForStartupSubscribers(runtime: runtime, target: target)
        try await waitUntil {
            guard case .failed = context.state else {
                return false
            }
            return true
        }

        guard case let .failed(error) = context.state else {
            Issue.record("Expected failed context state.")
            return
        }
        guard case .commandFailed(domain: "Network", method: "enable", message: _) = error else {
            Issue.record("Expected Network.enable command failure.")
            return
        }

        let commands = runtime.wire.observations.commands
        #expect(commands.map(\.method) == [
            "Inspector.enable",
            "Inspector.initialized",
            "Runtime.enable",
            "Network.enable",
            "Runtime.disable",
            "Inspector.disable",
        ])
        #expect(context.rootNode == nil)
    }
}

@MainActor
@Test
func consoleEnableFailureFailsStartupBeforeAttachingDocument() async throws {
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()

        await runtime.wire.respond(to: "Inspector.enable")
        await runtime.wire.respond(to: "Inspector.initialized")
        await runtime.wire.respond(to: "Runtime.enable")
        await runtime.wire.respond(to: "Network.enable")
        await runtime.wire.respond(
            to: "DOM.getDocument",
            with: try domDocumentResult(
                DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document")
            )
        )
        await runtime.wire.fail("Console.enable", message: "Console enable failed.")
        await runtime.wire.respond(to: "Runtime.disable")
        await runtime.wire.respond(to: "Network.disable")
        await runtime.wire.respond(to: "Inspector.disable")

        let container = WebInspectorContainer(proxy: runtime.proxy)
        let context = container.mainContext
        try await waitForStartupSubscribers(runtime: runtime, target: target)
        try await waitUntil {
            guard case .failed = context.state else {
                return false
            }
            return true
        }

        guard case let .failed(error) = context.state else {
            Issue.record("Expected failed context state.")
            return
        }
        guard case .commandFailed(domain: "Console", method: "enable", message: _) = error else {
            Issue.record("Expected Console.enable command failure.")
            return
        }

        let commands = runtime.wire.observations.commands
        #expect(commands.map(\.method) == [
            "Inspector.enable",
            "Inspector.initialized",
            "Runtime.enable",
            "Network.enable",
            "DOM.getDocument",
            "Console.enable",
            "Runtime.disable",
            "Network.disable",
            "Inspector.disable",
        ])
        #expect(context.rootNode == nil)
    }
}

@MainActor
@Test
func runtimeEnableFailureFailsStartupBeforeConsoleNetworkAndDocumentFetch() async throws {
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()

        await runtime.wire.respond(to: "Inspector.enable")
        await runtime.wire.respond(to: "Inspector.initialized")
        await runtime.wire.fail("Runtime.enable", message: "Runtime enable failed.")
        await runtime.wire.respond(to: "Inspector.disable")

        let container = WebInspectorContainer(proxy: runtime.proxy)
        let context = container.mainContext
        try await waitForStartupSubscribers(runtime: runtime, target: target)
        try await waitUntil {
            guard case .failed = context.state else {
                return false
            }
            return true
        }

        guard case let .failed(error) = context.state else {
            Issue.record("Expected failed context state.")
            return
        }
        guard case .commandFailed(domain: "Runtime", method: "enable", message: _) = error else {
            Issue.record("Expected Runtime.enable command failure.")
            return
        }

        let commands = runtime.wire.observations.commands
        #expect(commands.map(\.method) == [
            "Inspector.enable",
            "Inspector.initialized",
            "Runtime.enable",
            "Inspector.disable",
        ])
        #expect(context.rootNode == nil)
    }
}

@MainActor
@Test
func closeAfterAttachedDisablesEnabledDomains() async throws {
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()

        try await enqueueStartupReplies(on: runtime.wire)
        await enqueueDomainDisableReplies(on: runtime.wire)

        let container = WebInspectorContainer(proxy: runtime.proxy)
        let context = container.mainContext
        try await waitForStartupSubscribers(runtime: runtime, target: target)
        try await waitUntil { context.state == .attached }

        await container.close()

        let commands = runtime.wire.observations.commands
        #expect(commands.map(\.method) == startupCommands + shutdownCommands)
        #expect(context.state == .detached)
        #expect(context.teardownError == nil)
    }
}

@MainActor
@Test
func closeAfterAttachedClearsAttachmentBackedModels() async throws {
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()
        let documentID = DOM.Node.ID("document")
        let requestID = Network.Request.ID("request-1")
        let runtimeContextID = Runtime.ExecutionContext.ID("main")
        let networkResults: WebInspectorFetchedResults<NetworkRequest>
        let consoleResults: WebInspectorFetchedResults<ConsoleMessage>

        try await enqueueStartupReplies(
            on: runtime.wire,
            document: DOM.Node(id: documentID, nodeType: 9, nodeName: "#document")
        )

        let container = WebInspectorContainer(proxy: runtime.proxy)
        let context = container.mainContext
        networkResults = context.fetchedResults()
        consoleResults = context.fetchedResults()
        try await waitForStartupSubscribers(runtime: runtime, target: target)
        try await waitUntil { context.state == .attached }

        try await runtime.wire.emitRaw(
            .requestWillBeSent(
                id: requestID,
                request: Network.Request(id: requestID, url: "https://example.com/app.js", method: "GET"),
                resourceType: .script,
                redirectResponse: nil,
                timestamp: 1
            ),
            target: target
        )
        try await runtime.wire.emitRaw(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "warning"),
                text: "hello",
                timestamp: 2
            )),
            target: target
        )
        try await runtime.wire.emitRaw(
            .executionContextCreated(Runtime.ExecutionContext(id: runtimeContextID, name: "Main", kind: .normal)),
            target: target
        )
        try await waitUntil {
            networkResults.items.count == 1
                && consoleResults.items.count == 1
                && context.executionContexts.count == 1
        }

        let request = try #require(networkResults.items.first)
        let message = try #require(consoleResults.items.first)
        #expect(context.rootNode?.id == DOMNode.ID(documentID))
        #expect(context.node(for: DOMNode.ID(documentID)) != nil)
        #expect(context.registeredRequest(for: request.id) === request)
        #expect(context.registeredMessage(for: message.id) === message)

        await enqueueDomainDisableReplies(on: runtime.wire)
        await container.close()

        #expect(context.state == .detached)
        #expect(context.rootNode == nil)
        #expect(context.node(for: DOMNode.ID(documentID)) == nil)
        #expect(context.registeredRequest(for: request.id) == nil)
        #expect(networkResults.items.isEmpty)
        #expect(context.registeredMessage(for: message.id) == nil)
        #expect(consoleResults.items.isEmpty)
        #expect(context.executionContexts.isEmpty)
        #expect(context.selectedContext == nil)
    }
}

@MainActor
@Test
func closeRecordsNetworkDisableFailureAndDetachesContext() async throws {
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()

        try await enqueueStartupReplies(on: runtime.wire)
        await runtime.wire.respond(to: "Console.disable")
        await runtime.wire.respond(to: "Runtime.disable")
        await runtime.wire.fail("Network.disable", message: "Network disable failed.")
        await runtime.wire.respond(to: "Inspector.disable")

        let container = WebInspectorContainer(proxy: runtime.proxy)
        let context = container.mainContext
        try await waitForStartupSubscribers(runtime: runtime, target: target)
        try await waitUntil { context.state == .attached }

        await container.close()

        #expect(context.state == .detached)
        guard case .commandFailed(domain: "Network", method: "disable", message: _) = context.teardownError else {
            Issue.record("Expected Network.disable teardown error.")
            return
        }
    }
}

@MainActor
@Test
func restartDisablesPreviousDomainTrackingBeforeReenable() async throws {
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()

        try await enqueueStartupReplies(
            on: runtime.wire,
            document: DOM.Node(id: DOM.Node.ID("document-1"), nodeType: 9, nodeName: "#document")
        )

        let container = WebInspectorContainer(proxy: runtime.proxy)
        let context = container.mainContext
        try await waitForStartupSubscribers(runtime: runtime, target: target)
        try await waitUntil { context.rootNode?.id == DOMNode.ID(DOM.Node.ID("document-1")) }

        await enqueueDomainDisableReplies(on: runtime.wire)
        try await enqueueStartupReplies(
            on: runtime.wire,
            document: DOM.Node(id: DOM.Node.ID("document-2"), nodeType: 9, nodeName: "#document")
        )

        context.start()

        try await waitUntil { context.rootNode?.id == DOMNode.ID(DOM.Node.ID("document-2")) }

        let commands = runtime.wire.observations.commands
        #expect(commands.map(\.method) == startupCommands + shutdownCommands + startupCommands)
    }
}

@MainActor
@Test
func restartWaitsForPreviousStartupCleanupBeforeReenable() async throws {
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()
        let enableGate = await runtime.wire.deferReply(to: "Network.enable")
        await runtime.wire.respond(to: "Inspector.enable")
        await runtime.wire.respond(to: "Inspector.initialized")
        await runtime.wire.respond(to: "Runtime.enable")

        let container = WebInspectorContainer(proxy: runtime.proxy)
        let context = container.mainContext
        try await waitForStartupSubscribers(runtime: runtime, target: target)
        try await waitUntil {
            runtime.wire.observations.commandMethods == [
                "Inspector.enable",
                "Inspector.initialized",
                "Runtime.enable",
                "Network.enable",
            ]
        }

        await enqueueDomainDisableReplies(on: runtime.wire)
        try await enqueueStartupReplies(
            on: runtime.wire,
            document: DOM.Node(id: DOM.Node.ID("restarted-document"), nodeType: 9, nodeName: "#document")
        )

        context.start()

        enableGate.open()
        try await waitUntil { context.rootNode?.id == DOMNode.ID(DOM.Node.ID("restarted-document")) }

        let commands = runtime.wire.observations.commands
        #expect(commands.map(\.method) == Array(startupCommands.prefix(4)) + [
            "Runtime.disable",
            "Network.disable",
            "Inspector.disable",
        ] + startupCommands)
    }
}

@MainActor
@Test
func runtimeEnableReplayIsCapturedBeforeCommandReturns() async throws {
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()
        let contextID = Runtime.ExecutionContext.ID("main")

        let enableGate = await runtime.wire.deferReply(to: "Runtime.enable")
        await runtime.wire.respond(to: "Inspector.enable")
        await runtime.wire.respond(to: "Inspector.initialized")
        await runtime.wire.respond(to: "Network.enable")
        await runtime.wire.respond(
            to: "DOM.getDocument",
            with: try emptyDocumentResult()
        )
        await runtime.wire.respond(to: "Console.enable")

        let container = WebInspectorContainer(proxy: runtime.proxy)
        let context = container.mainContext
        try await waitUntil {
            runtime.wire.observations.commandMethods == [
                "Inspector.enable",
                "Inspector.initialized",
                "Runtime.enable"
            ]
        }

        try await runtime.wire.emitRaw(
            .executionContextCreated(Runtime.ExecutionContext(id: contextID, name: "Main", kind: .normal)),
            target: target
        )
        try await waitUntil {
            context.executionContexts.first?.id == RuntimeContext.ID(contextID)
        }

        enableGate.open()
        try await waitUntil { context.state == .attached }
        #expect(context.selectedContext?.id == RuntimeContext.ID(contextID))
    }
}

@MainActor
@Test
func consoleEnableReplayIsCapturedBeforeCommandReturns() async throws {
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()
        let enableGate = await runtime.wire.deferReply(to: "Console.enable")
        await runtime.wire.respond(to: "Inspector.enable")
        await runtime.wire.respond(to: "Inspector.initialized")
        await runtime.wire.respond(to: "Runtime.enable")
        await runtime.wire.respond(to: "Network.enable")
        await runtime.wire.respond(
            to: "DOM.getDocument",
            with: try emptyDocumentResult()
        )

        let container = WebInspectorContainer(proxy: runtime.proxy)
        let context = container.mainContext
        let results: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()
        try await waitUntil {
            runtime.wire.observations.commandMethods == startupCommands
        }

        try await runtime.wire.emitRaw(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "warning"),
                text: "replayed"
            )),
            target: target
        )
        try await waitUntil { results.items.map(\.text) == ["replayed"] }

        enableGate.open()
        try await waitUntil { context.state == .attached }
        #expect(results.items.map(\.text) == ["replayed"])
    }
}

@MainActor
@Test
func startupRefetchesDocumentWhenMainFrameNavigatesBeforeAttach() async throws {
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()
        let staleDocumentID = DOM.Node.ID("stale-startup-document")
        let freshDocumentID = DOM.Node.ID("fresh-startup-document")

        let consoleGate = await runtime.wire.deferReply(to: "Console.enable")
        await runtime.wire.respond(to: "Inspector.enable")
        await runtime.wire.respond(to: "Inspector.initialized")
        await runtime.wire.respond(to: "Runtime.enable")
        await runtime.wire.respond(to: "Network.enable")
        await runtime.wire.respond(
            to: "DOM.getDocument",
            with: try domDocumentResult(
                DOM.Node(id: staleDocumentID, nodeType: 9, nodeName: "#document")
            )
        )
        await runtime.wire.respond(
            to: "DOM.getDocument",
            with: try domDocumentResult(
                DOM.Node(id: freshDocumentID, nodeType: 9, nodeName: "#document")
            )
        )
        let container = WebInspectorContainer(proxy: runtime.proxy)
        let context = container.mainContext
        try await waitUntil {
            runtime.wire.observations.commandMethods == startupCommands
        }

        try await runtime.wire.emitRaw(
            .frameNavigated(WebInspectorPageFrameLifecycle(
                id: FrameID("main-frame"),
                parentID: nil,
                loaderID: "loader-2",
                name: "Main",
                url: "https://example.test/next",
                securityOrigin: "https://example.test",
                mimeType: "text/html"
            )),
            target: target
        )
        consoleGate.open()

        try await waitUntil { context.rootNode?.id == DOMNode.ID(freshDocumentID) }
        #expect(context.state == .attached)
        #expect(context.node(for: DOMNode.ID(staleDocumentID)) == nil)
        #expect(runtime.wire.observations.commandMethods == startupCommands + [
            "DOM.getDocument"
        ])
    }
}

@MainActor
@Test
func transportBackedStartupCapturesRuntimeAndConsoleReplayBeforeEnableReplies() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installTransportPageTarget(in: transport, targetID: ProtocolTarget.ID("page-main"))
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()
    #expect(target.id == .currentPage)
    let container = WebInspectorContainer(proxy: proxy)
    let context = container.mainContext
    let consoleResults: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()

    try await replyTransportInspectorInitialization(backend, transport: transport, targetID: ProtocolTarget.ID("page-main"))

    let runtimeEnable = try await waitForTransportTargetMessage(backend, method: "Runtime.enable")
    await receiveTransportTargetEvent(
        transport,
        targetID: runtimeEnable.targetIdentifier,
        method: "Runtime.executionContextCreated",
        params: #"{"context":{"id":11,"name":"Main","frameId":"main-frame","type":"normal"}}"#
    )
    try await waitUntil {
        context.executionContexts.first?.id == RuntimeContext.ID(Runtime.ExecutionContext.ID("11"))
    }
    await receiveTransportTargetReply(
        transport,
        targetID: runtimeEnable.targetIdentifier,
        messageID: try transportMessageID(runtimeEnable.message),
        result: "{}"
    )

    let networkEnable = try await waitForTransportTargetMessage(backend, method: "Network.enable")
    await receiveTransportTargetReply(
        transport,
        targetID: networkEnable.targetIdentifier,
        messageID: try transportMessageID(networkEnable.message),
        result: "{}"
    )

    let getDocument = try await waitForTransportTargetMessage(backend, method: "DOM.getDocument")
    await receiveTransportTargetReply(
        transport,
        targetID: getDocument.targetIdentifier,
        messageID: try transportMessageID(getDocument.message),
        result: ##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","localName":"","nodeValue":"","frameId":"main-frame","childNodeCount":0}}"##
    )

    let consoleEnable = try await waitForTransportTargetMessage(backend, method: "Console.enable")
    await receiveTransportTargetEvent(
        transport,
        targetID: consoleEnable.targetIdentifier,
        method: "Console.messageAdded",
        params: #"{"message":{"source":"console-api","level":"warning","text":"replayed","repeatCount":1}}"#
    )
    try await waitUntil { consoleResults.items.map(\.text) == ["replayed"] }
    await receiveTransportTargetReply(
        transport,
        targetID: consoleEnable.targetIdentifier,
        messageID: try transportMessageID(consoleEnable.message),
        result: "{}"
    )

    try await waitUntil { context.state == .attached }
    #expect(context.rootNode?.id == DOMNode.ID(DOM.Node.ID("1")))
    #expect(context.selectedContext?.id == RuntimeContext.ID(Runtime.ExecutionContext.ID("11")))
    #expect(consoleResults.items.map(\.text) == ["replayed"])
}

@MainActor
@Test
func transportBackedInspectorInspectMaterializesSelectionAndRestoresHighlight() async throws {
    let targetID = ProtocolTarget.ID("page-main")
    let inspectedID = DOM.Node.ID("42")
    let (backend, transport, context) = try await startTransportBackedContext(
        targetID: targetID,
        documentID: "1"
    )
    let startupMessageCount = await backend.sentTargetMessages().count

    let enablePickerTask = Task { @MainActor in
        try await context.setElementPickerEnabled(true)
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
    #expect(context.isElementPickerEnabled)

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

    try await waitUntil { context.selectedNode?.id == DOMNode.ID(inspectedID) }
    #expect(context.isElementPickerEnabled == false)

    let highlight = try await waitForTransportTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: startupMessageCount
    )
    #expect(highlight.targetIdentifier == targetID)
    #expect((try transportTargetMessageParameters(highlight.message)["nodeId"] as? NSNumber)?.intValue == 42)
    await receiveTransportTargetReply(
        transport,
        targetID: highlight.targetIdentifier,
        messageID: try transportMessageID(highlight.message),
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

    try await waitUntil { context.selectedNode?.elementStyles?.phase == .loaded }
}

@MainActor
@Test
func transportBackedFrameNavigationClearsRestoredPickerHighlight() async throws {
    let targetID = ProtocolTarget.ID("page-main")
    let inspectedID = DOM.Node.ID("42")
    let (backend, transport, context) = try await startTransportBackedContext(
        targetID: targetID,
        documentID: "1"
    )
    let startupMessageCount = await backend.sentTargetMessages().count

    let enablePickerTask = Task { @MainActor in
        try await context.setElementPickerEnabled(true)
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
    try await waitUntil { context.selectedNode?.id == DOMNode.ID(inspectedID) }

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

    try await waitUntil { context.rootNode?.id == DOMNode.ID(DOM.Node.ID("2")) }
    #expect(context.selectedNode == nil)
}

@MainActor
@Test
func transportBackedFrameRuntimeAndConsoleEventsKeepTargetScope() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let frameTargetID = ProtocolTarget.ID("frame-runtime")
    let frameTarget = WebInspectorTarget.ID(frameTargetID.rawValue)
    let scopedContextID = Runtime.ExecutionContext.ID("7", scopedToTargetRawValue: frameTargetID.rawValue)
    let (backend, transport, context) = try await startTransportBackedContext(
        targetID: pageTargetID,
        documentID: "1"
    )
    let consoleResults: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()
    let startupMessageCount = await backend.sentTargetMessages().count

    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-runtime","type":"page","frameId":"frame-runtime","parentFrameId":"main-frame","isProvisional":false}}}"#
    )
    await receiveTransportTargetEvent(
        transport,
        targetID: frameTargetID,
        method: "Runtime.executionContextCreated",
        params: #"{"context":{"id":7,"name":"Frame","frameId":"frame-runtime","type":"normal"}}"#
    )
    try await waitUntil {
        context.executionContexts.contains { $0.id == RuntimeContext.ID(scopedContextID) }
    }
    let frameContext = try #require(context.executionContexts.first { $0.id == RuntimeContext.ID(scopedContextID) })

    var capturedEvaluation: RuntimeEvaluation?
    let evaluationTask = Task { @MainActor in
        capturedEvaluation = try await context.evaluate("window", in: frameContext)
    }
    let evaluate = try await waitForTransportTargetMessage(
        backend,
        method: "Runtime.evaluate",
        after: startupMessageCount
    )
    #expect(evaluate.targetIdentifier == frameTargetID)
    let evaluateParameters = try transportTargetMessageParameters(evaluate.message)
    #expect(evaluateParameters["contextId"] as? Int == 7)
    await receiveTransportTargetReply(
        transport,
        targetID: evaluate.targetIdentifier,
        messageID: try transportMessageID(evaluate.message),
        result: #"{"result":{"type":"object","objectId":"frame-evaluation-object","description":"frame object"}}"#
    )
    try await evaluationTask.value
    let evaluation = try #require(capturedEvaluation)
    #expect(evaluation.object.proxyID?.targetScopeRawValue == frameTargetID.rawValue)
    #expect(evaluation.object.proxyID?.unscopedRawValue == "frame-evaluation-object")

    await receiveTransportTargetEvent(
        transport,
        targetID: frameTargetID,
        method: "Console.messageAdded",
        params: #"{"message":{"source":"console-api","level":"log","text":"frame log","networkRequestId":"frame-request-77","parameters":[{"type":"object","objectId":"frame-console-object","description":"console object"}],"repeatCount":1}}"#
    )
    try await waitUntil { consoleResults.items.map(\.text) == ["frame log"] }
    let consoleMessage = try #require(consoleResults.items.first)
    #expect(consoleMessage.targetID == frameTarget)
    #expect(consoleMessage.networkRequestID == NetworkRequest.ID(
        Network.Request.ID("frame-request-77", scopedToTargetRawValue: frameTargetID.rawValue)
    ))
    let consoleObject = try #require(consoleMessage.parameters.first)
    #expect(consoleObject.proxyID?.targetScopeRawValue == frameTargetID.rawValue)
    #expect(consoleObject.proxyID?.unscopedRawValue == "frame-console-object")
}

@MainActor
@Test
func transportBackedStyleSheetTextEditRoutesToFrameTargetAndMarksUndo() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let frameTargetID = ProtocolTarget.ID("frame-css")
    let styleSheetID = CSS.StyleSheet.ID("frame-sheet", scopedToTargetRawValue: frameTargetID.rawValue)
    let (backend, transport, context) = try await startTransportBackedContext(
        targetID: pageTargetID,
        documentID: "1"
    )
    let startupMessageCount = await backend.sentTargetMessages().count

    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-css","type":"page","frameId":"frame-css","parentFrameId":"main-frame","isProvisional":false}}}"#
    )

    let editTask = Task { @MainActor in
        try await context.setCSSStyleSheetText(
            "body { color: red; }",
            for: styleSheetID,
            options: .automatic
        )
    }
    let setStyleSheetText = try await waitForTransportTargetMessage(
        backend,
        method: "CSS.setStyleSheetText",
        after: startupMessageCount
    )
    #expect(setStyleSheetText.targetIdentifier == frameTargetID)
    let parameters = try transportTargetMessageParameters(setStyleSheetText.message)
    #expect(parameters["styleSheetId"] as? String == "frame-sheet")
    #expect(parameters["text"] as? String == "body { color: red; }")
    await receiveTransportTargetReply(
        transport,
        targetID: setStyleSheetText.targetIdentifier,
        messageID: try transportMessageID(setStyleSheetText.message),
        result: "{}"
    )

    let markUndoableState = try await waitForTransportTargetMessage(
        backend,
        method: "DOM.markUndoableState",
        after: startupMessageCount
    )
    #expect(markUndoableState.targetIdentifier == frameTargetID)
    await receiveTransportTargetReply(
        transport,
        targetID: markUndoableState.targetIdentifier,
        messageID: try transportMessageID(markUndoableState.message),
        result: "{}"
    )
    try await editTask.value
}

@MainActor
@Test
func currentPageCommitClearsOldLifecycleStateBeforeAcceptingNewPageEvents() async throws {
    try await withDataKitTestRuntime { runtime in
        let (_, context) = try await startContext(runtime: runtime)
        let results: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()
        let concreteResults = try await context.consoleMessages()
        await context.apply(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "log"),
                text: "old page"
            )),
            targetID: .currentPage
        )
        try await waitUntil { results.items.map(\.text) == ["old page"] }
        #expect(concreteResults.items.map(\.text) == ["old page"])

        context.apply(.didCommitProvisionalTarget(WebInspectorTargetCommitLifecycle(
            oldTargetID: .currentPage,
            newTarget: WebInspectorLifecycleTarget(
                id: .currentPage,
                kind: .page,
                frameID: FrameID("committed-main-frame"),
                isProvisional: false,
                pageBindingID: "committed-page"
            )
        )))

        #expect(results.items.isEmpty)
        #expect(concreteResults.items.isEmpty)
        await context.apply(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "log"),
                text: "new page"
            )),
            targetID: .currentPage
        )
        #expect(results.items.map(\.text) == ["new page"])
        #expect(concreteResults.items.map(\.text) == ["new page"])
    }
}

@MainActor
@Test
func currentPageCommitRetargetsDataKitStateToNewTransportTarget() async throws {
    let oldTargetID = ProtocolTarget.ID("page-old")
    let newTargetID = ProtocolTarget.ID("page-new")
    let oldRootID = DOMNode.ID(DOM.Node.ID("old-root"))
    let newRootID = DOMNode.ID(DOM.Node.ID("new-root"))
    let oldRouteChildID = DOMNode.ID(DOM.Node.ID("old-route-child"))
    let retainedRequestID = Network.Request.ID("commit-retained-request")
    let (backend, transport, context) = try await startTransportBackedContext(
        targetID: oldTargetID,
        documentID: "old-root"
    )
    let networkResults: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
    let domTreeController = try await context.treeController()
    let domUpdates = DOMTreeUpdateRecorder(stream: domTreeController.updates)
    defer { domUpdates.cancel() }
    try await domUpdates.waitUntilStarted()
    try await domUpdates.waitForUpdateCount(1)
    let startupMessageCount = await backend.sentTargetMessages().count

    #expect(context.state == .attached)
    #expect(context.rootNode?.id == oldRootID)
    #expect(context.node(for: oldRootID) != nil)
    await receiveTransportTargetEvent(
        transport,
        targetID: oldTargetID,
        method: "Network.requestWillBeSent",
        params: #"{"requestId":"commit-retained-request","request":{"url":"https://example.test/retained","method":"GET"},"type":"Fetch","timestamp":1}"#
    )
    try await waitUntil {
        networkResults.items.map(\.id) == [NetworkRequest.ID(retainedRequestID)]
    }

    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-new","type":"page","frameId":"new-main-frame","isProvisional":true}}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-old","newTargetId":"page-new"}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"page-old"}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Page.frameNavigated","params":{"frame":{"id":"new-main-frame","loaderId":"loader-2","name":"Main","url":"https://example.test/next","securityOrigin":"https://example.test","mimeType":"text/html"}}}"#
    )

    try await replyTransportInspectorInitialization(
        backend,
        transport: transport,
        targetID: newTargetID,
        after: startupMessageCount,
        timeout: .seconds(30)
    )

    let runtimeEnable = try await waitForTransportTargetMessage(
        backend,
        method: "Runtime.enable",
        after: startupMessageCount,
        timeout: .seconds(30)
    )
    #expect(runtimeEnable.targetIdentifier == newTargetID)
    await receiveTransportTargetReply(
        transport,
        targetID: runtimeEnable.targetIdentifier,
        messageID: try transportMessageID(runtimeEnable.message),
        result: "{}"
    )

    let networkEnable = try await waitForTransportTargetMessage(
        backend,
        method: "Network.enable",
        after: startupMessageCount,
        timeout: .seconds(30)
    )
    #expect(networkEnable.targetIdentifier == newTargetID)
    await receiveTransportTargetReply(
        transport,
        targetID: networkEnable.targetIdentifier,
        messageID: try transportMessageID(networkEnable.message),
        result: "{}"
    )

    let getDocument = try await waitForTransportTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: startupMessageCount,
        timeout: .seconds(30)
    )
    #expect(getDocument.targetIdentifier == newTargetID)
    await receiveTransportTargetReply(
        transport,
        targetID: getDocument.targetIdentifier,
        messageID: try transportMessageID(getDocument.message),
        result: transportDocumentResult(nodeID: "new-root")
    )

    let consoleEnable = try await waitForTransportTargetMessageReplyingToInterleavedGetDocuments(
        backend,
        transport: transport,
        targetID: newTargetID,
        method: "Console.enable",
        after: startupMessageCount,
        documentNodeID: "new-root",
        repliedGetDocumentMessageIDs: [try transportMessageID(getDocument.message)],
        timeout: .seconds(30)
    )
    #expect(consoleEnable.targetIdentifier == newTargetID)
    await receiveTransportTargetReply(
        transport,
        targetID: consoleEnable.targetIdentifier,
        messageID: try transportMessageID(consoleEnable.message),
        result: "{}"
    )

    try await waitUntil { context.rootNode?.id == newRootID }
    try await waitUntil {
        domUpdates.updates.contains { update in
            guard case let .snapshot(snapshot, .pageChanged) = update else {
                return false
            }
            return snapshot.rootNodeID == newRootID
        }
    }
    let resetUpdateIndex = try #require(domUpdates.updates.firstIndex { update in
        guard case let .snapshot(snapshot, .reset) = update else {
            return false
        }
        return snapshot.rootNodeID == nil
    })
    let pageChangedUpdateIndex = try #require(domUpdates.updates.firstIndex { update in
        guard case let .snapshot(snapshot, .pageChanged) = update else {
            return false
        }
        return snapshot.rootNodeID == newRootID
    })
    #expect(resetUpdateIndex < pageChangedUpdateIndex)
    #expect(context.state == .attached)
    #expect(context.node(for: oldRootID) == nil)
    #expect(context.node(for: newRootID) != nil)
    #expect(networkResults.items.map(\.id) == [NetworkRequest.ID(retainedRequestID)])

    let postCommitRequestID = Network.Request.ID("commit-post-request")
    await receiveTransportTargetEvent(
        transport,
        targetID: newTargetID,
        method: "Network.requestWillBeSent",
        params: #"{"requestId":"commit-post-request","request":{"url":"https://example.test/after-commit","method":"GET"},"type":"Fetch","timestamp":2}"#
    )
    try await waitUntil {
        Set(networkResults.items.map(\.id)) == [
            NetworkRequest.ID(retainedRequestID),
            NetworkRequest.ID(postCommitRequestID),
        ]
    }

    let sentMessages = await backend.sentTargetMessages()
    let retargetMessages = Array(sentMessages.dropFirst(startupMessageCount))
    let staleRouteMethods = try retargetMessages
        .filter { $0.targetIdentifier == oldTargetID }
        .map { try transportTargetMessageMethod($0.message) }
    #expect(staleRouteMethods.allSatisfy { $0 == "DOM.getDocument" })

    let newTargetMessages = retargetMessages.filter { $0.targetIdentifier == newTargetID }
    let newTargetMethods = try newTargetMessages.map { try transportTargetMessageMethod($0.message) }
    let runtimeEnableIndex = try #require(newTargetMethods.firstIndex(of: "Runtime.enable"))
    let preRuntimeMethods = Array(newTargetMethods[..<runtimeEnableIndex])
    #expect(preRuntimeMethods.allSatisfy {
        $0 == "DOM.getDocument" || $0 == "Inspector.enable" || $0 == "Inspector.initialized"
    })
    let trackingMethods = Array(newTargetMethods[runtimeEnableIndex...])
    #expect(Array(trackingMethods.prefix(3)) == [
        "Runtime.enable",
        "Network.enable",
        "DOM.getDocument",
    ])
    #expect(trackingMethods.contains("Console.enable"))
    #expect(Set(newTargetMethods).isSubset(of: [
        "Inspector.enable",
        "Inspector.initialized",
        "Runtime.enable",
        "Network.enable",
        "DOM.getDocument",
        "Console.enable",
    ]))

    await receiveTransportTargetEvent(
        transport,
        targetID: oldTargetID,
        method: "DOM.childNodeInserted",
        params: ##"{"parentNodeId":"new-root","previousNodeId":null,"node":{"nodeId":"old-route-child","nodeType":1,"nodeName":"DIV","localName":"div","nodeValue":"","childNodeCount":0}}"##
    )
    await receiveTransportTargetEvent(
        transport,
        targetID: newTargetID,
        method: "DOM.attributeModified",
        params: #"{"nodeId":"new-root","name":"data-probe","value":"new"}"#
    )
    try await waitUntil { context.rootNode?.attributes["data-probe"] == "new" }
    try await waitUntil {
        domUpdates.updates.last == .delta(.nodeChanged(nodeID: newRootID))
    }
    #expect(domUpdates.updates[(pageChangedUpdateIndex + 1)...].allSatisfy { update in
        guard case .delta = update else {
            return false
        }
        return true
    })
    #expect(context.rootNode?.childNodeCount == 0)
    #expect(context.node(for: oldRouteChildID) == nil)
}

@MainActor
@Test
func currentPageTargetDestroyedClearsStreamStateBeforeWaitingForReplacement() async throws {
    try await withDataKitTestRuntime { runtime in
        let (_, context) = try await startContext(runtime: runtime)
        let oldRoot = context.rootNode
        let legacyResults: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()
        let concreteResults = try await context.consoleMessages()
        await context.apply(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "log"),
                text: "destroyed page"
            )),
            targetID: .currentPage
        )
        #expect(legacyResults.items.map(\.text) == ["destroyed page"])
        #expect(concreteResults.items.map(\.text) == ["destroyed page"])

        context.apply(.targetDestroyed(targetID: .currentPage))

        #expect(context.rootNode === oldRoot)
        #expect(legacyResults.items.isEmpty)
        #expect(concreteResults.items.isEmpty)
    }
}

@MainActor
@Test
func currentPageTargetDestroyedDuringRetargetDoesNotDetachOrClearNetwork() async throws {
    let oldTargetID = ProtocolTarget.ID("page-old")
    let newTargetID = ProtocolTarget.ID("page-new-after-destroy")
    let retainedRequestID = Network.Request.ID("destroy-retained-request")
    let (backend, transport, context) = try await startTransportBackedContext(
        targetID: oldTargetID,
        documentID: "destroyed-root"
    )
    let networkResults: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
    let startupMessageCount = await backend.sentTargetMessages().count

    #expect(context.state == .attached)
    #expect(context.rootNode?.id == DOMNode.ID(DOM.Node.ID("destroyed-root")))
    await receiveTransportTargetEvent(
        transport,
        targetID: oldTargetID,
        method: "Network.requestWillBeSent",
        params: #"{"requestId":"destroy-retained-request","request":{"url":"https://example.test/retained","method":"GET"},"type":"Fetch","timestamp":1}"#
    )
    try await waitUntil {
        networkResults.items.map(\.id) == [NetworkRequest.ID(retainedRequestID)]
    }

    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"page-old"}}"#
    )
    #expect(context.state == .attached)
    #expect(context.rootNode?.id == DOMNode.ID(DOM.Node.ID("destroyed-root")))
    #expect(networkResults.items.map(\.id) == [NetworkRequest.ID(retainedRequestID)])
    await installTransportPageTarget(in: transport, targetID: newTargetID)

    try await replyTransportInspectorInitialization(
        backend,
        transport: transport,
        targetID: newTargetID,
        after: startupMessageCount,
        timeout: .seconds(30)
    )

    let runtimeEnable = try await waitForTransportTargetMessage(
        backend,
        method: "Runtime.enable",
        after: startupMessageCount,
        timeout: .seconds(30)
    )
    #expect(runtimeEnable.targetIdentifier == newTargetID)
    await receiveTransportTargetReply(
        transport,
        targetID: runtimeEnable.targetIdentifier,
        messageID: try transportMessageID(runtimeEnable.message),
        result: "{}"
    )

    let networkEnable = try await waitForTransportTargetMessage(
        backend,
        method: "Network.enable",
        after: startupMessageCount,
        timeout: .seconds(30)
    )
    #expect(networkEnable.targetIdentifier == newTargetID)
    await receiveTransportTargetReply(
        transport,
        targetID: networkEnable.targetIdentifier,
        messageID: try transportMessageID(networkEnable.message),
        result: "{}"
    )

    let getDocument = try await waitForTransportTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: startupMessageCount,
        timeout: .seconds(30)
    )
    #expect(getDocument.targetIdentifier == newTargetID)
    await receiveTransportTargetReply(
        transport,
        targetID: getDocument.targetIdentifier,
        messageID: try transportMessageID(getDocument.message),
        result: transportDocumentResult(nodeID: "reattached-root")
    )

    let consoleEnable = try await waitForTransportTargetMessage(
        backend,
        method: "Console.enable",
        after: startupMessageCount,
        timeout: .seconds(30)
    )
    #expect(consoleEnable.targetIdentifier == newTargetID)
    await receiveTransportTargetReply(
        transport,
        targetID: consoleEnable.targetIdentifier,
        messageID: try transportMessageID(consoleEnable.message),
        result: "{}"
    )

    try await waitUntil {
        context.rootNode?.id == DOMNode.ID(DOM.Node.ID("reattached-root"))
    }
    #expect(context.state == .attached)
    #expect(context.rootNode?.id == DOMNode.ID(DOM.Node.ID("reattached-root")))
    #expect(networkResults.items.map(\.id) == [NetworkRequest.ID(retainedRequestID)])

    let pickerMessageCount = await backend.sentTargetMessages().count
    let pickerTask = Task { @MainActor in
        try await context.setElementPickerEnabled(true)
    }
    let inspectMode = try await waitForTransportTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: pickerMessageCount
    )
    #expect(inspectMode.targetIdentifier == newTargetID)
    await receiveTransportTargetReply(
        transport,
        targetID: inspectMode.targetIdentifier,
        messageID: try transportMessageID(inspectMode.message),
        result: "{}"
    )
    try await pickerTask.value
    #expect(context.isElementPickerEnabled)
}

@MainActor
@Test
func startBeginsFreshNetworkAttachmentEpoch() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let networkResults: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        let staleRequestID = Network.Request.ID("stale-before-restart")

        try await emitFinishedRequest(id: staleRequestID, target: target, backend: runtime.wire)
        try await waitUntil {
            networkResults.items.map(\.id) == [NetworkRequest.ID(staleRequestID)]
        }
        let concreteNetworkResults = try await context.networkRequests()
        #expect(concreteNetworkResults.items.map(\.id) == [NetworkRequest.ID(staleRequestID)])

        await enqueueDomainDisableReplies(on: runtime.wire)
        try await enqueueStartupReplies(
            on: runtime.wire,
            document: DOM.Node(id: DOM.Node.ID("fresh-after-restart"), nodeType: 9, nodeName: "#document")
        )

        context.start()

        #expect(networkResults.items.isEmpty)
        #expect(concreteNetworkResults.items.isEmpty)
        #expect(context.registeredRequest(for: NetworkRequest.ID(staleRequestID)) == nil)
        try await waitUntil { networkResults.items.isEmpty }
        try await waitUntil {
            context.rootNode?.id == DOMNode.ID(DOM.Node.ID("fresh-after-restart"))
                && context.state == .attached
        }
        #expect(networkResults.items.isEmpty)
    }
}

@MainActor
@Test
func sharedContainerContextsReenableDomainsOnCommittedPageTarget() async throws {
    let oldTargetID = ProtocolTarget.ID("page-old")
    let newTargetID = ProtocolTarget.ID("page-new")
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installTransportPageTarget(in: transport, targetID: oldTargetID)
    let proxy = try await WebInspectorProxy(transport: transport)
    let container = WebInspectorContainer(proxy: proxy)

    let autoReplier = startAutoReplyingTransportTargetMessages(
        backend: backend,
        transport: transport
    ) { targetID in
        targetID == newTargetID ? "new-shared-root" : "old-shared-root"
    }
    defer { autoReplier.cancel() }

    let contextA = container.mainContext
    let contextB = WebInspectorContext(container, isolation: MainActor.shared)
    contextB.start()
    try await waitUntil(timeout: .seconds(5)) {
        contextA.state == .attached && contextB.state == .attached
    }
    let preSwapMessageCount = await backend.sentTargetMessages().count

    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-new","type":"page","frameId":"new-main-frame","isProvisional":true}}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-old","newTargetId":"page-new"}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"page-old"}}"#
    )

    let newRootID = DOMNode.ID(DOM.Node.ID("new-shared-root"))
    try await waitUntil(timeout: .seconds(5)) {
        contextA.state == .attached && contextB.state == .attached
            && contextA.rootNode?.id == newRootID
            && contextB.rootNode?.id == newRootID
    }

    let postSwapMessages = Array((await backend.sentTargetMessages()).dropFirst(preSwapMessageCount))
    for method in ["Inspector.enable", "Runtime.enable", "Network.enable", "Console.enable"] {
        let sends = try postSwapMessages.filter {
            try $0.targetIdentifier == newTargetID && transportTargetMessageMethod($0.message) == method
        }
        #expect(sends.count == 1, "expected exactly one \(method) on the committed page target")
    }
}

@MainActor
@Test
func currentPageDestroyWithoutReplacementRegressesToAttachingAndRecovers() async throws {
    let doomedTargetID = ProtocolTarget.ID("page-doomed")
    let rebornTargetID = ProtocolTarget.ID("page-reborn")
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installTransportPageTarget(in: transport, targetID: doomedTargetID)
    let proxy = try await WebInspectorProxy(
        transport: transport,
        configuration: .init(responseTimeout: .milliseconds(750), bootstrapTimeout: .milliseconds(100))
    )
    let container = WebInspectorContainer(proxy: proxy)

    let autoReplier = startAutoReplyingTransportTargetMessages(
        backend: backend,
        transport: transport
    ) { targetID in
        targetID == rebornTargetID ? "reborn-root" : "doomed-root"
    }
    defer { autoReplier.cancel() }

    let context = container.mainContext
    try await waitUntil(timeout: .seconds(5)) { context.state == .attached }
    #expect(context.rootNode != nil)

    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"page-doomed"}}"#
    )

    try await waitUntil(timeout: .seconds(5)) {
        context.state == .attaching && context.rootNode == nil
    }

    await installTransportPageTarget(in: transport, targetID: rebornTargetID, frameID: "reborn-frame")

    let rebornRootID = DOMNode.ID(DOM.Node.ID("reborn-root"))
    try await waitUntil(timeout: .seconds(5)) {
        context.state == .attached && context.rootNode?.id == rebornRootID
    }
}

@MainActor
@Test
func startCancelsInFlightCurrentPageRetargetBeforeRestarting() async throws {
    let targetID = ProtocolTarget.ID("page-restart")
    let (_, _, context) = try await startTransportBackedContext(
        targetID: targetID,
        documentID: "restart-old-root"
    )
    let cancellationProbe = CancellationProbe()
    context.installCurrentPageRetargetTaskForTesting(Task {
        cancellationProbe.markStarted()
        await withTaskCancellationHandler {
            while Task.isCancelled == false {
                try? await Task.sleep(for: .milliseconds(10))
            }
            cancellationProbe.markCancelled()
        } onCancel: {
            cancellationProbe.markCancelled()
        }
    })
    try await waitUntil(timeout: .seconds(5)) {
        cancellationProbe.started()
    }

    context.start()
    try await waitUntil(timeout: .seconds(5)) {
        cancellationProbe.cancelled()
    }
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

    try await replyTransportInspectorInitialization(
        backend,
        transport: transport,
        targetID: newTargetID,
        after: startupMessageCount
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

    try await waitUntil { context.rootNode?.id == DOMNode.ID(DOM.Node.ID("undo-new-root")) }
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
func mainFrameNavigatedReloadsDOMAndClearsRuntimeContexts() async throws {
    let targetID = ProtocolTarget.ID("page-main")
    let navigatedRootID = DOMNode.ID(DOM.Node.ID("navigated-root"))
    let navigatedRequestID = Network.Request.ID("navigated-request")
    let (backend, transport, context) = try await startTransportBackedContext(
        targetID: targetID,
        documentID: "initial-root"
    )
    let networkResults: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
    let undoCommands = try context.domUndoRedoCommands()
    let startupMessageCount = await backend.sentTargetMessages().count

    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Runtime.executionContextCreated",
        params: #"{"context":{"id":21,"name":"Main","frameId":"main-frame","type":"normal"}}"#
    )
    try await waitUntil { context.executionContexts.map(\.id) == [RuntimeContext.ID(Runtime.ExecutionContext.ID("21"))] }

    await transport.receiveRootMessage(
        #"{"method":"Page.frameNavigated","params":{"frame":{"id":"main-frame","loaderId":"loader-2","name":"Main","url":"https://example.test/next","securityOrigin":"https://example.test","mimeType":"text/html"}}}"#
    )

    let getDocument = try await waitForTransportTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: startupMessageCount
    )
    #expect(getDocument.targetIdentifier == targetID)
    #expect(context.executionContexts.isEmpty)
    await receiveTransportTargetReply(
        transport,
        targetID: getDocument.targetIdentifier,
        messageID: try transportMessageID(getDocument.message),
        result: transportDocumentResult(nodeID: "navigated-root")
    )

    try await waitUntil { context.rootNode?.id == navigatedRootID }
    #expect(context.executionContexts.isEmpty)
    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Network.requestWillBeSent",
        params: #"{"requestId":"navigated-request","request":{"url":"https://example.test/after-frame-navigation","method":"GET"},"type":"Document","timestamp":3}"#
    )
    try await waitUntil {
        networkResults.items.map(\.id) == [NetworkRequest.ID(navigatedRequestID)]
    }
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
func restartClearsRuntimeContextsBeforeEnableReplay() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let staleID = Runtime.ExecutionContext.ID("stale")
        let replayID = Runtime.ExecutionContext.ID("replayed")
        let enableGate = await runtime.wire.deferReply(to: "Runtime.enable")

        try await runtime.wire.emitRaw(
            .executionContextCreated(Runtime.ExecutionContext(id: staleID, name: "Stale", kind: .normal)),
            target: target
        )
        try await waitUntil {
            context.executionContexts.first?.id == RuntimeContext.ID(staleID)
        }

        await enqueueDomainDisableReplies(on: runtime.wire)
        try await enqueueStartupReplies(
            on: runtime.wire,
            document: DOM.Node(id: DOM.Node.ID("restarted-document"), nodeType: 9, nodeName: "#document")
        )

        context.start()
        try await waitUntil {
            runtime.wire.observations.commandMethods == startupCommands + shutdownCommands + [
                "Inspector.enable",
                "Inspector.initialized",
                "Runtime.enable",
            ]
        }
        #expect(context.executionContexts.isEmpty)
        #expect(context.selectedContext == nil)

        try await runtime.wire.emitRaw(
            .executionContextCreated(Runtime.ExecutionContext(id: replayID, name: "Replayed", kind: .normal)),
            target: target
        )
        try await waitUntil {
            context.executionContexts.map(\.id) == [RuntimeContext.ID(replayID)]
        }

        enableGate.open()
        try await waitUntil { context.rootNode?.id == DOMNode.ID(DOM.Node.ID("restarted-document")) }
        #expect(context.selectedContext?.id == RuntimeContext.ID(replayID))
    }
}

@MainActor
@Test
func restartClearsConsoleMessagesBeforeConsoleReplay() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let results: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()
        let enableGate = await runtime.wire.deferReply(to: "Console.enable")

        try await runtime.wire.emitRaw(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "warning"),
                text: "old"
            )),
            target: target
        )
        try await waitUntil { results.items.map(\.text) == ["old"] }

        await enqueueDomainDisableReplies(on: runtime.wire)
        try await enqueueStartupReplies(
            on: runtime.wire,
            document: DOM.Node(id: DOM.Node.ID("restarted-document"), nodeType: 9, nodeName: "#document")
        )

        context.start()
        try await waitUntil {
            runtime.wire.observations.commandMethods == startupCommands + shutdownCommands + startupCommands
        }
        #expect(results.items.isEmpty)

        try await runtime.wire.emitRaw(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "warning"),
                text: "old"
            )),
            target: target
        )
        try await waitUntil { results.items.map(\.text) == ["old"] }

        enableGate.open()
        try await waitUntil { context.rootNode?.id == DOMNode.ID(DOM.Node.ID("restarted-document")) }
        #expect(results.items.count == 1)
    }
}

@MainActor
@Test
func documentUpdatedReloadsRootDocument() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let document = try #require(context.rootNode)
        await runtime.wire.respond(to: "DOM.setAttributeValue")
        await runtime.wire.respond(to: "DOM.markUndoableState")
        try await context.setDOMAttribute(
            "data-before-reset",
            value: "1",
            on: document.id,
            options: .automatic
        )
        let undoCommands = try context.domUndoRedoCommands()
        let controller = try await context.treeController()
        let recorder = DOMTreeUpdateRecorder(stream: controller.updates)
        defer { recorder.cancel() }
        try await recorder.waitUntilStarted()
        try await recorder.waitForUpdateCount(1)
        let replacementID = DOM.Node.ID("replacement-document")

        await runtime.wire.respond(
            to: "DOM.getDocument",
            with: try domDocumentResult(
                DOM.Node(id: replacementID, nodeType: 9, nodeName: "#document")
            )
        )

        try await runtime.wire.emitRaw(.documentUpdated, target: target)

        try await waitUntil {
            context.rootNode?.id == DOMNode.ID(replacementID)
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
        await runtime.wire.respond(to: "DOM.undo")
        await #expect(throws: WebInspectorProxyError.disconnected("DOM undo/redo target is no longer current.")) {
            try await context.undoDOMChange()
        }

        let commands = runtime.wire.observations.commands
        #expect(!commands.contains { $0.method == "DOM.undo" })
    }
}

@MainActor
@Test
func childInsertIntoUnrequestedParentDoesNotMarkChildrenLoaded() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let document = try #require(context.rootNode)
        let insertedID = DOM.Node.ID("inserted-child")

        try await runtime.wire.emitRaw(
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
            document.childNodeCount == 1
        }
        guard case let .unrequested(count) = document.children else {
            Issue.record("Expected parent children to stay unrequested.")
            return
        }
        #expect(count == 1)
        #expect(context.node(for: DOMNode.ID(insertedID)) == nil)
    }
}

@MainActor
@Test
func domTreeControllerPublishesInitialSnapshotAndChildDeltas() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(
            runtime: runtime,
            document: DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document", childNodeCount: 1)
        )
        let document = try #require(context.rootNode)
        let controller = try await context.treeController()
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
        try await runtime.wire.emitRaw(
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
}

@MainActor
@Test
func domTreeControllerPrunesRetainedChildDescendantsOnReplacement() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(
            runtime: runtime,
            document: DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document", childNodeCount: 1)
        )
        let document = try #require(context.rootNode)
        let controller = try await context.treeController()
        let recorder = DOMTreeUpdateRecorder(stream: controller.updates)
        defer { recorder.cancel() }
        try await recorder.waitUntilStarted()
        try await recorder.waitForUpdateCount(1)

        let childID = DOM.Node.ID("child")
        let removedSpanID = DOM.Node.ID("removed-span")
        let removedEmID = DOM.Node.ID("removed-em")
        try await runtime.wire.emitRaw(
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
        let child = try #require(context.node(for: DOMNode.ID(childID)))

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: document.id.proxyID, nodes: [
                DOM.Node(id: childID, nodeType: 1, nodeName: "DIV", localName: "div", childNodeCount: 0)
            ]),
            target: target
        )

        try await recorder.waitForUpdateCount(3)
        try await waitUntil {
            context.node(for: DOMNode.ID(removedSpanID)) == nil
                && context.node(for: DOMNode.ID(removedEmID)) == nil
        }
        #expect(context.node(for: DOMNode.ID(childID)) === child)
        #expect(controller.snapshot.node(for: DOMNode.ID(childID)) != nil)
        #expect(controller.snapshot.node(for: DOMNode.ID(removedSpanID)) == nil)
        #expect(controller.snapshot.node(for: DOMNode.ID(removedEmID)) == nil)
        #expect(controller.snapshot.parent(of: DOMNode.ID(removedEmID)) == nil)
    }
}

@MainActor
@Test
func domTreeControllerPublishesAssociatedSubtreeDeltas() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(
            runtime: runtime,
            document: DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document", childNodeCount: 1)
        )
        let document = try #require(context.rootNode)
        let controller = try await context.treeController()
        let recorder = DOMTreeUpdateRecorder(stream: controller.updates)
        defer { recorder.cancel() }
        try await recorder.waitUntilStarted()
        try await recorder.waitForUpdateCount(1)

        let iframeID = DOM.Node.ID("iframe")
        let frameDocumentID = DOM.Node.ID("frame-document")
        let frameBodyID = DOM.Node.ID("frame-body")
        try await runtime.wire.emitRaw(
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
}

@MainActor
@Test
func domTreeControllerAppliesDynamicShadowAndPseudoElementDeltas() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(
            runtime: runtime,
            document: DOM.Node(
                id: DOM.Node.ID("document"),
                nodeType: 9,
                nodeName: "#document",
                childNodeCount: 1
            )
        )
        let document = try #require(context.rootNode)
        let controller = try await context.treeController()
        let recorder = DOMTreeUpdateRecorder(stream: controller.updates)
        defer { recorder.cancel() }
        try await recorder.waitUntilStarted()
        try await recorder.waitForUpdateCount(1)

        let hostID = DOM.Node.ID("shadow-host")
        let shadowRootID = DOM.Node.ID("dynamic-shadow-root")
        let shadowChildID = DOM.Node.ID("dynamic-shadow-child")
        let beforePseudoID = DOM.Node.ID("dynamic-before-pseudo")

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: document.id.proxyID, nodes: [
                DOM.Node(id: hostID, nodeType: 1, nodeName: "DIV", localName: "div")
            ]),
            target: target
        )
        try await recorder.waitForUpdateCount(2)
        let host = try #require(context.node(for: DOMNode.ID(hostID)))

        try await runtime.wire.emitRaw(
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

        try await runtime.wire.emitRaw(
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

        try await runtime.wire.emitRaw(
            .pseudoElementRemoved(parent: hostID, element: beforePseudoID),
            target: target
        )

        try await recorder.waitForUpdateCount(5)
        #expect(host.beforePseudoElement == nil)
        #expect(context.node(for: DOMNode.ID(beforePseudoID)) == nil)
        #expect(
            controller.snapshot.visibleChildren(of: DOMNode.ID(hostID)).nodeIDs == [DOMNode.ID(shadowRootID)]
        )

        try await runtime.wire.emitRaw(
            .shadowRootPopped(host: hostID, root: shadowRootID),
            target: target
        )

        try await recorder.waitForUpdateCount(6)
        #expect(host.shadowRoots.isEmpty)
        #expect(context.node(for: DOMNode.ID(shadowRootID)) == nil)
        #expect(context.node(for: DOMNode.ID(shadowChildID)) == nil)
        #expect(controller.snapshot.visibleChildren(of: DOMNode.ID(hostID)).nodeIDs == [])
    }
}

@MainActor
@Test
func domTreeControllerPublishesOnlyDeltasForSameDocumentMutations() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(
            runtime: runtime,
            document: DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document", childNodeCount: 1)
        )
        let document = try #require(context.rootNode)
        let controller = try await context.treeController()
        let recorder = DOMTreeUpdateRecorder(stream: controller.updates)
        defer { recorder.cancel() }
        try await recorder.waitUntilStarted()
        try await recorder.waitForUpdateCount(1)

        let elementID = DOM.Node.ID("element")
        let textID = DOM.Node.ID("text")
        let insertedID = DOM.Node.ID("inserted")

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: document.id.proxyID, nodes: [
                DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div", childNodeCount: 1)
            ]),
            target: target
        )
        try await recorder.waitForUpdateCount(2)

        try await runtime.wire.emitRaw(
            .attributeModified(elementID, name: "class", value: "selected"),
            target: target
        )
        try await waitUntil { context.node(for: DOMNode.ID(elementID))?.attributes["class"] == "selected" }
        try await recorder.waitForUpdateCount(3)

        try await runtime.wire.emitRaw(
            .childNodeCountUpdated(elementID, count: 1),
            target: target
        )
        try await waitUntil { context.node(for: DOMNode.ID(elementID))?.childNodeCount == 1 }
        try await recorder.waitForUpdateCount(4)

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: elementID, nodes: [
                DOM.Node(id: textID, nodeType: 3, nodeName: "#text", nodeValue: "old")
            ]),
            target: target
        )
        try await recorder.waitForUpdateCount(5)

        try await runtime.wire.emitRaw(
            .characterDataModified(textID, value: "new"),
            target: target
        )
        try await waitUntil { context.node(for: DOMNode.ID(textID))?.nodeValue == "new" }
        try await recorder.waitForUpdateCount(6)

        try await runtime.wire.emitRaw(
            .childNodeInserted(
                parent: document.id.proxyID,
                previous: elementID,
                node: DOM.Node(id: insertedID, nodeType: 1, nodeName: "SPAN", localName: "span")
            ),
            target: target
        )
        try await recorder.waitForUpdateCount(7)

        try await runtime.wire.emitRaw(
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
}

@MainActor
@Test
func domTreeControllerSnapshotIncludesRecursiveDOMAssociations() async throws {
    try await withDataKitTestRuntime { runtime in
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

        let controller = try await context.treeController()
        let snapshot = controller.snapshot
        let document = try #require(context.rootNode)
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
}

@MainActor
@Test
func domTreeControllerPublishesSelectionDeltasWithoutOwningExpansion() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(
            runtime: runtime,
            document: DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document")
        )
        let document = try #require(context.rootNode)
        let parentID = DOM.Node.ID("parent")
        let childID = DOM.Node.ID("child")

        try await runtime.wire.emitRaw(
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

        try await waitUntil { context.node(for: DOMNode.ID(childID)) != nil }
        let parent = try #require(context.node(for: DOMNode.ID(parentID)))
        let child = try #require(context.node(for: DOMNode.ID(childID)))
        let controller = try await context.treeController()
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

        try await enqueueCSSStyleReplies(on: runtime.wire)
        try context.selectNode(child.id, reveal: .selectOnly)

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

        context.select(nil)

        try await recorder.waitForUpdateCount(3)
        guard case let .delta(selectionCleared) = recorder.updates.last else {
            Issue.record("Expected DOM selection clear delta.")
            return
        }
        #expect(selectionCleared == .selectionChanged(nodeID: nil))
        #expect(controller.snapshot.selectedNodeID == nil)

        try context.selectNode(document.id, reveal: .none)
        try await recorder.waitForUpdateCount(4)
        #expect(revealRecorder.requests.count == 1)
    }
}

@MainActor
@Test
func setChildNodesReplacementPublishesSelectionClearingForRemovedDescendant() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(
            runtime: runtime,
            document: DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document")
        )
        let document = try #require(context.rootNode)
        let parentID = DOM.Node.ID("parent")
        let selectedID = DOM.Node.ID("selected-text")
        let replacementID = DOM.Node.ID("replacement-text")

        try await runtime.wire.emitRaw(
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
        try await waitUntil { context.node(for: DOMNode.ID(selectedID)) != nil }

        let selected = try #require(context.node(for: DOMNode.ID(selectedID)))
        let controller = try await context.treeController()
        let recorder = DOMTreeUpdateRecorder(stream: controller.updates)
        defer { recorder.cancel() }
        try await recorder.waitUntilStarted()
        try await recorder.waitForUpdateCount(1)

        context.select(selected)
        try await recorder.waitForUpdateCount(2)
        #expect(controller.snapshot.selectedNodeID == selected.id)

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: parentID, nodes: [
                DOM.Node(id: replacementID, nodeType: 3, nodeName: "#text", nodeValue: "replacement")
            ]),
            target: target
        )

        try await waitUntil {
            context.selectedNode == nil
                && context.node(for: DOMNode.ID(selectedID)) == nil
                && context.node(for: DOMNode.ID(replacementID)) != nil
        }
        try await waitUntil {
            recorder.updates.contains(.delta(.selectionChanged(nodeID: nil)))
        }
        #expect(controller.snapshot.selectedNodeID == nil)
    }
}


@MainActor
@Test
func fetchedResultsUpdatesStartWithExactCurrentState() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let requestID = seedFetchedResultsRequest(
        "initial-publication",
        url: "https://example.com/initial",
        timestamp: 1,
        in: context
    )
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
    var iterator = results.updates().makeAsyncIterator()

    guard case let .initial(revision, snapshot)? = await iterator.next() else {
        Issue.record("Expected the first fetched-results publication to be initial state.")
        return
    }

    #expect(revision == results.revision)
    #expect(snapshot == results.snapshot)
    #expect(snapshot.itemIDs == [requestID])
}

@MainActor
@Test
func fetchedResultsUpdatesCannotMissMutationAfterRegistration() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
    var iterator = results.updates().makeAsyncIterator()

    let requestID = seedFetchedResultsRequest(
        "registered-before-mutation",
        url: "https://example.com/registered",
        timestamp: 1,
        in: context
    )

    guard case let .initial(revision, snapshot)? = await iterator.next() else {
        Issue.record("Expected the pending initial value to coalesce to current state.")
        return
    }

    #expect(revision == results.revision)
    #expect(snapshot == results.snapshot)
    #expect(snapshot.itemIDs == [requestID])
}

@MainActor
@Test
func fetchedResultsPropertyUpdatesDoNotInvalidateTopologyQueries() {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let requestID = seedFetchedResultsRequest(
        "property-generation",
        url: "https://example.com/original",
        timestamp: 1,
        in: context
    )
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
    let initialRevision = results.revision
    let initialTopologyRevision = results.topologyRevision

    seedFetchedResultsRequest(
        "property-generation",
        url: "https://example.com/updated",
        timestamp: 2,
        in: context
    )

    #expect(results.revision == initialRevision &+ 1)
    #expect(results.topologyRevision == initialTopologyRevision)
    #expect(results.snapshot.itemIDs == [requestID])
}

@MainActor
@Test
func networkRequestIndexDrainsDifferentIDMutationsInSequenceOrder() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let firstID = seedFetchedResultsRequest(
        "ordered-first",
        url: "https://example.com/first",
        timestamp: 1,
        in: context
    )
    let secondID = seedFetchedResultsRequest(
        "ordered-second",
        url: "https://example.com/second",
        timestamp: 2,
        in: context
    )
    let first = try #require(context.registeredRequest(for: firstID))
    let second = try #require(context.registeredRequest(for: secondID))
    let index = NetworkRequestIndex()

    let secondMutation = Task {
        await index.upsert(
            NetworkRequestRecordInput(request: second, orderIndex: 1),
            sequence: 2
        )
    }
    try await waitUntil {
        await index.isMutationPendingForTesting(sequence: 2)
    }
    await index.upsert(
        NetworkRequestRecordInput(request: first, orderIndex: 0),
        sequence: 1
    )
    _ = await secondMutation.value

    let delta = await index.delta(
        plan: NetworkRequestQueryPlan(
            descriptor: WebInspectorFetchDescriptor<NetworkRequest>(),
            context: context
        ),
        sectionBy: nil,
        oldSnapshot: WebInspectorFetchedResultsSnapshot(),
        changedSince: 0
    )
    #expect(delta.sequence == 2)
    #expect(delta.snapshot.itemIDs == [firstID, secondID])
}

@MainActor
@Test
func networkRequestIndexBuffersUpsertUntilEarlierReplaceArrives() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let firstID = seedFetchedResultsRequest(
        "replace-first",
        url: "https://example.com/first",
        timestamp: 1,
        in: context
    )
    let secondID = seedFetchedResultsRequest(
        "replace-second",
        url: "https://example.com/second",
        timestamp: 2,
        in: context
    )
    let first = try #require(context.registeredRequest(for: firstID))
    let second = try #require(context.registeredRequest(for: secondID))
    let index = NetworkRequestIndex()

    let upsert = Task {
        await index.upsert(
            NetworkRequestRecordInput(request: second, orderIndex: 1),
            sequence: 2
        )
    }
    try await waitUntil {
        await index.isMutationPendingForTesting(sequence: 2)
    }
    await index.replace(
        with: [NetworkRequestRecordInput(request: first, orderIndex: 0)],
        sequence: 1
    )
    _ = await upsert.value

    let delta = await index.delta(
        plan: NetworkRequestQueryPlan(
            descriptor: WebInspectorFetchDescriptor<NetworkRequest>(),
            context: context
        ),
        sectionBy: nil,
        oldSnapshot: WebInspectorFetchedResultsSnapshot(),
        changedSince: 0
    )
    #expect(delta.sequence == 2)
    #expect(delta.snapshot.itemIDs == [firstID, secondID])
}

@MainActor
@Test
func networkRequestIndexCheckpointRecoversSkippedOverlappingPropertyUpdates() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let firstID = seedFetchedResultsRequest(
        "overlap-first",
        url: "https://example.com/first",
        timestamp: 1,
        in: context
    )
    let secondID = seedFetchedResultsRequest(
        "overlap-second",
        url: "https://example.com/second",
        timestamp: 2,
        in: context
    )
    let first = try #require(context.registeredRequest(for: firstID))
    let second = try #require(context.registeredRequest(for: secondID))
    let plan = NetworkRequestQueryPlan(
        descriptor: WebInspectorFetchDescriptor<NetworkRequest>(),
        context: context
    )
    let index = NetworkRequestIndex()
    await index.replace(
        with: [
            NetworkRequestRecordInput(request: first, orderIndex: 0),
            NetworkRequestRecordInput(request: second, orderIndex: 1),
        ],
        sequence: 1
    )
    let initial = await index.delta(
        plan: plan,
        sectionBy: nil,
        oldSnapshot: WebInspectorFetchedResultsSnapshot(),
        changedSince: 0
    )
    #expect(initial.sequence == 1)
    #expect(initial.snapshot.itemIDs == [firstID, secondID])

    seedFetchedResultsRequest(
        "overlap-first",
        url: "https://example.com/first-updated",
        timestamp: 3,
        in: context
    )
    await index.upsert(
        NetworkRequestRecordInput(request: first, orderIndex: 0),
        sequence: 2
    )
    let skippedFirstDelta = await index.delta(
        plan: plan,
        sectionBy: nil,
        oldSnapshot: initial.snapshot,
        changedSince: initial.sequence
    )
    #expect(skippedFirstDelta.reconfigureItemIDs == [firstID])

    seedFetchedResultsRequest(
        "overlap-second",
        url: "https://example.com/second-updated",
        timestamp: 4,
        in: context
    )
    await index.upsert(
        NetworkRequestRecordInput(request: second, orderIndex: 1),
        sequence: 3
    )

    // Model the context discarding `skippedFirstDelta` after a newer index
    // sequence arrived. The next delta starts at the result's unchanged
    // checkpoint and must recover both property notifications.
    let recoveredDelta = await index.delta(
        plan: plan,
        sectionBy: nil,
        oldSnapshot: initial.snapshot,
        changedSince: initial.sequence
    )
    #expect(recoveredDelta.sequence == 3)
    #expect(recoveredDelta.reconfigureItemIDs == Set([firstID, secondID]))
    #expect(recoveredDelta.snapshot == initial.snapshot)
}

@MainActor
@Test
func stalledFetchedResultsSubscriberKeepsOnlyNewestUpdateAndUnionsReconfigurations() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let firstID = seedFetchedResultsRequest(
        "stalled-first",
        url: "https://example.com/first",
        timestamp: 1,
        in: context
    )
    let secondID = seedFetchedResultsRequest(
        "stalled-second",
        url: "https://example.com/second",
        timestamp: 2,
        in: context
    )
    let firstIdentity = try #require(context.registeredRequest(for: firstID))
    let secondIdentity = try #require(context.registeredRequest(for: secondID))

    var results: WebInspectorFetchedResults<NetworkRequest>? = context.fetchedResults()
    weak let weakResults = results
    var iterator = try #require(results).updates().makeAsyncIterator()
    guard case .initial? = await iterator.next() else {
        Issue.record("Expected fetched-results initial state before stalling the subscriber.")
        return
    }

    seedFetchedResultsRequest(
        "stalled-first",
        url: "https://example.com/first-updated",
        timestamp: 3,
        in: context
    )
    seedFetchedResultsRequest(
        "stalled-second",
        url: "https://example.com/second-updated",
        timestamp: 4,
        in: context
    )

    let expectedRevision = try #require(results).revision
    let expectedSnapshot = try #require(results).snapshot
    results = nil
    #expect(weakResults == nil)
    #expect(context.registeredRequest(for: firstID) === firstIdentity)
    #expect(context.registeredRequest(for: secondID) === secondIdentity)

    guard case let .transaction(revision, transaction, reconfigureItemIDs)? = await iterator.next() else {
        Issue.record("Expected the newest coalesced fetched-results transaction.")
        return
    }
    #expect(revision == expectedRevision)
    #expect(transaction.newSnapshot == expectedSnapshot)
    #expect(reconfigureItemIDs == Set([firstID, secondID]))

    let remainingUpdate = await iterator.next()
    #expect(remainingUpdate == nil)
}

@MainActor
@Test
func stalledFetchedResultsSubscriberDoesNotReconfigureRemovedItems() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let requestID = seedFetchedResultsRequest(
        "stalled-removed",
        url: "https://example.com/original",
        timestamp: 1,
        in: context
    )
    var results: WebInspectorFetchedResults<NetworkRequest>? = context.fetchedResults()
    var iterator = try #require(results).updates().makeAsyncIterator()
    guard case .initial? = await iterator.next() else {
        Issue.record("Expected fetched-results initial state before stalling the subscriber.")
        return
    }

    seedFetchedResultsRequest(
        "stalled-removed",
        url: "https://example.com/updated",
        timestamp: 2,
        in: context
    )
    await context.clearNetworkRequests()

    let expectedRevision = try #require(results).revision
    results = nil

    guard case let .transaction(revision, transaction, reconfigureItemIDs)? = await iterator.next() else {
        Issue.record("Expected the coalesced removal transaction.")
        return
    }
    #expect(revision == expectedRevision)
    #expect(transaction.isReset)
    #expect(transaction.newSnapshot.itemIDs.isEmpty)
    #expect(reconfigureItemIDs.isEmpty)
    #expect(context.registeredRequest(for: requestID) == nil)

    let remainingUpdate = await iterator.next()
    #expect(remainingUpdate == nil)
}

@MainActor
@Test
func fetchedResultsPublishNetworkTopologyAndPropertyUpdates() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        let recorder = FetchedResultsTransactionRecorder(stream: results.updates())
        defer { recorder.cancel() }
        try await recorder.waitUntilStarted()

        let requestID = Network.Request.ID("controller-request")
        try await runtime.wire.emitRaw(
            .requestWillBeSent(
                id: requestID,
                request: Network.Request(id: requestID, url: "https://example.com/first", method: "GET"),
                resourceType: .fetch,
                redirectResponse: nil,
                timestamp: 1
            ),
            target: target
        )

        try await recorder.waitForTransactionCount(1)
        let inserted = try #require(recorder.transactions.last)
        let modelID = NetworkRequest.ID(requestID)
        let firstIndexPath = WebInspectorFetchedResultsIndexPath(section: 0, item: 0)
        #expect(inserted.itemChanges == [.insert(itemID: modelID, indexPath: firstIndexPath)])
        #expect(inserted.oldSnapshot.itemIDs == [])
        #expect(inserted.newSnapshot.itemIDs == [modelID])
        #expect(recorder.reconfigureItemIDSets.last == [])
        #expect(results.snapshot.itemIDs == [modelID])
        let request = try #require(results.items.first)

        try await runtime.wire.emitRaw(
            .responseReceived(
                id: requestID,
                response: Network.Response(status: 200, statusText: "OK", mimeType: "text/plain"),
                resourceType: .fetch,
                timestamp: 2
            ),
            target: target
        )

        try await waitUntil { request.status == 200 }
        try await recorder.waitForTransactionCount(2)
        #expect(results.items.first === request)
        #expect(recorder.transactions.last?.itemChanges == [.update(itemID: modelID, indexPath: firstIndexPath)])
        #expect(recorder.reconfigureItemIDSets.last == [modelID])

        try await runtime.wire.emitRaw(
            .dataReceived(id: requestID, dataLength: 7, encodedDataLength: 3, timestamp: 3),
            target: target
        )

        try await waitUntil { request.decodedDataLength == 7 && request.encodedDataLength == 3 }
        try await recorder.waitForTransactionCount(3)
        #expect(results.items.first === request)
        #expect(recorder.transactions.last?.itemChanges == [.update(itemID: modelID, indexPath: firstIndexPath)])
        #expect(recorder.reconfigureItemIDSets.last == [modelID])

        try await runtime.wire.emitRaw(
            .loadingFinished(id: requestID, timestamp: 4, sourceMapURL: nil, metrics: nil),
            target: target
        )

        try await waitUntil { request.state == .finished }
        try await recorder.waitForTransactionCount(4)
        #expect(results.items.first === request)
        #expect(recorder.transactions.last?.itemChanges == [.update(itemID: modelID, indexPath: firstIndexPath)])
        #expect(recorder.reconfigureItemIDSets.last == [modelID])

        try await runtime.wire.emitRaw(
            .requestServedFromMemoryCache(
                id: requestID,
                response: Network.Response(url: "https://example.com/first", status: 200),
                resourceType: nil,
                timestamp: 5
            ),
            target: target
        )

        try await waitUntil { request.finishedOrFailedTimestamp == 5 }
        try await recorder.waitForTransactionCount(5)
        #expect(results.items.first === request)
        #expect(recorder.transactions.last?.itemChanges == [.update(itemID: modelID, indexPath: firstIndexPath)])
        #expect(recorder.reconfigureItemIDSets.last == [modelID])

        let failedRequestID = Network.Request.ID("controller-failed-request")
        let failedModelID = NetworkRequest.ID(failedRequestID)
        let failedIndexPath = WebInspectorFetchedResultsIndexPath(section: 0, item: 1)
        try await runtime.wire.emitRaw(
            .requestWillBeSent(
                id: failedRequestID,
                request: Network.Request(id: failedRequestID, url: "https://example.com/failed", method: "GET"),
                resourceType: .fetch,
                redirectResponse: nil,
                timestamp: 6
            ),
            target: target
        )

        try await recorder.waitForTransactionCount(6)
        #expect(recorder.transactions.last?.itemChanges == [.insert(itemID: failedModelID, indexPath: failedIndexPath)])
        #expect(recorder.reconfigureItemIDSets.last == [])
        let failedRequest = try #require(results.items.last)

        try await runtime.wire.emitRaw(
            .loadingFailed(id: failedRequestID, errorText: "cancelled", canceled: true, timestamp: 7),
            target: target
        )

        try await waitUntil {
            if case .failed(errorText: "cancelled", canceled: true) = failedRequest.state {
                return true
            }
            return false
        }
        try await recorder.waitForTransactionCount(7)
        #expect(results.items.last === failedRequest)
        #expect(recorder.transactions.last?.itemChanges == [.update(itemID: failedModelID, indexPath: failedIndexPath)])
        #expect(recorder.reconfigureItemIDSets.last == [failedModelID])

        let socketRequestID = Network.Request.ID("controller-socket-request")
        let socketModelID = NetworkRequest.ID(socketRequestID)
        let socketIndexPath = WebInspectorFetchedResultsIndexPath(section: 0, item: 2)
        try await runtime.wire.emitRaw(
            .webSocket(.created(id: socketRequestID, url: "wss://example.com/socket")),
            target: target
        )

        try await recorder.waitForTransactionCount(8)
        #expect(recorder.transactions.last?.itemChanges == [.insert(itemID: socketModelID, indexPath: socketIndexPath)])
        #expect(recorder.reconfigureItemIDSets.last == [])
        let socketRequest = try #require(results.items.last)

        try await runtime.wire.emitRaw(
            .webSocket(.handshakeRequest(
                id: socketRequestID,
                request: Network.Request(
                    id: socketRequestID,
                    url: "wss://example.com/socket",
                    method: "GET",
                    headers: ["Upgrade": "websocket"]
                ),
                timestamp: 8
            )),
            target: target
        )

        try await waitUntil { socketRequest.webSocket?.handshakeRequest?.headers["Upgrade"] == "websocket" }
        try await recorder.waitForTransactionCount(9)
        #expect(results.items.last === socketRequest)
        #expect(recorder.transactions.last?.itemChanges == [.update(itemID: socketModelID, indexPath: socketIndexPath)])
        #expect(recorder.reconfigureItemIDSets.last == [socketModelID])

        try await runtime.wire.emitRaw(
            .webSocket(.handshakeResponse(
                id: socketRequestID,
                response: Network.Response(status: 101, statusText: "Switching Protocols"),
                timestamp: 9
            )),
            target: target
        )

        try await waitUntil { socketRequest.status == 101 }
        try await recorder.waitForTransactionCount(10)
        #expect(results.items.last === socketRequest)
        #expect(recorder.transactions.last?.itemChanges == [.update(itemID: socketModelID, indexPath: socketIndexPath)])
        #expect(recorder.reconfigureItemIDSets.last == [socketModelID])

        try await runtime.wire.emitRaw(
            .webSocket(.frameSent(
                id: socketRequestID,
                frame: Network.WebSocketFrame(opcode: 1, mask: true, payloadData: "hello", payloadLength: 5),
                timestamp: 10
            )),
            target: target
        )

        try await waitUntil { socketRequest.webSocket?.frames.count == 1 }
        try await recorder.waitForTransactionCount(11)
        #expect(results.items.last === socketRequest)
        #expect(recorder.transactions.last?.itemChanges == [.update(itemID: socketModelID, indexPath: socketIndexPath)])
        #expect(recorder.reconfigureItemIDSets.last == [socketModelID])

        try await runtime.wire.emitRaw(
            .webSocket(.frameReceived(
                id: socketRequestID,
                frame: Network.WebSocketFrame(opcode: 1, mask: false, payloadData: "world", payloadLength: 5),
                timestamp: 11
            )),
            target: target
        )

        try await waitUntil { socketRequest.webSocket?.frames.count == 2 }
        try await recorder.waitForTransactionCount(12)
        #expect(results.items.last === socketRequest)
        #expect(recorder.transactions.last?.itemChanges == [.update(itemID: socketModelID, indexPath: socketIndexPath)])
        #expect(recorder.reconfigureItemIDSets.last == [socketModelID])

        try await runtime.wire.emitRaw(
            .webSocket(.error(id: socketRequestID, message: "decode failed", timestamp: 12)),
            target: target
        )

        try await waitUntil { socketRequest.webSocket?.frames.count == 3 }
        try await recorder.waitForTransactionCount(13)
        #expect(results.items.last === socketRequest)
        #expect(recorder.transactions.last?.itemChanges == [.update(itemID: socketModelID, indexPath: socketIndexPath)])
        #expect(recorder.reconfigureItemIDSets.last == [socketModelID])

        try await runtime.wire.emitRaw(
            .webSocket(.closed(id: socketRequestID, timestamp: 13)),
            target: target
        )

        try await waitUntil { socketRequest.state == .finished && socketRequest.webSocket?.readyState == .closed }
        try await recorder.waitForTransactionCount(14)
        #expect(results.items.last === socketRequest)
        #expect(recorder.transactions.last?.itemChanges == [.update(itemID: socketModelID, indexPath: socketIndexPath)])
        #expect(recorder.reconfigureItemIDSets.last == [socketModelID])
    }
}

@MainActor
@Test
func sectionedNetworkResultsPublishTopologyWhenSectionKeyChanges() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults(sectionBy: \.mimeType)
        let recorder = FetchedResultsTransactionRecorder(stream: results.updates())
        defer { recorder.cancel() }
        try await recorder.waitUntilStarted()

        let requestID = Network.Request.ID("sectioned-controller-request")
        let modelID = NetworkRequest.ID(requestID)
        try await runtime.wire.emitRaw(
            .requestWillBeSent(
                id: requestID,
                request: Network.Request(id: requestID, url: "https://media.example.com/clip.mp4", method: "GET"),
                resourceType: .fetch,
                redirectResponse: nil,
                timestamp: 1
            ),
            target: target
        )

        try await recorder.waitForTransactionCount(1)
        #expect(results.snapshot.sectionIDs == [WebInspectorFetchSectionID(rawValue: "")])
        #expect(results.snapshot.itemIDs == [modelID])

        try await runtime.wire.emitRaw(
            .responseReceived(
                id: requestID,
                response: Network.Response(
                    url: "https://media.example.com/clip.mp4",
                    status: 200,
                    mimeType: "video/mp4"
                ),
                resourceType: .fetch,
                timestamp: 2
            ),
            target: target
        )

        try await recorder.waitForTransactionCount(2)
        let sectionChange = try #require(recorder.transactions.last)
        #expect(sectionChange.isReset == false)
        #expect(sectionChange.oldSnapshot.sectionIDs == [WebInspectorFetchSectionID(rawValue: "")])
        #expect(sectionChange.newSnapshot.sectionIDs == [WebInspectorFetchSectionID(rawValue: "video/mp4")])
        #expect(sectionChange.oldSnapshot.itemIDs == [modelID])
        #expect(sectionChange.newSnapshot.itemIDs == [modelID])
        #expect(sectionChange.sectionChanges == [
            .delete(sectionID: WebInspectorFetchSectionID(rawValue: ""), index: 0),
            .insert(sectionID: WebInspectorFetchSectionID(rawValue: "video/mp4"), index: 0),
        ])
        #expect(sectionChange.itemChanges == [])
    }
}

@MainActor
@Test
func sectionedNetworkResultsPublishItemMoveWhenSectionKeyChangesBetweenExistingSections() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults(sectionBy: \.resourceCategory)
    let recorder = FetchedResultsTransactionRecorder(stream: results.updates())
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()

    let imageID = Network.Request.ID("existing-image-section")
    let movingID = Network.Request.ID("moving-xhr-to-image")
    let remainingXHRID = Network.Request.ID("remaining-xhr-section")
    await context.apply(.requestWillBeSent(
        id: imageID,
        request: Network.Request(id: imageID, url: "https://cdn.example.com/photo.png", method: "GET"),
        resourceType: .image,
        redirectResponse: nil,
        timestamp: 1
    ))
    await context.apply(.requestWillBeSent(
        id: movingID,
        request: Network.Request(id: movingID, url: "https://api.example.com/avatar", method: "GET"),
        resourceType: .xhr,
        redirectResponse: nil,
        timestamp: 2
    ))
    await context.apply(.requestWillBeSent(
        id: remainingXHRID,
        request: Network.Request(id: remainingXHRID, url: "https://api.example.com/data", method: "GET"),
        resourceType: .xhr,
        redirectResponse: nil,
        timestamp: 3
    ))
    try await recorder.waitForTransactionCount(3)

    let movingModelID = NetworkRequest.ID(movingID)
    await context.apply(.responseReceived(
        id: movingID,
        response: Network.Response(
            url: "https://api.example.com/avatar",
            status: 200,
            mimeType: "image/png"
        ),
        resourceType: .xhr,
        timestamp: 4
    ))

    try await recorder.waitForTransactionCount(4)
    #expect(results.snapshot.sections.map(\.id) == [
        WebInspectorFetchSectionID(rawValue: "image"),
        WebInspectorFetchSectionID(rawValue: "xhrFetch"),
    ])
    #expect(results.snapshot.sections.map(\.itemIDs) == [
        [NetworkRequest.ID(imageID), movingModelID],
        [NetworkRequest.ID(remainingXHRID)],
    ])
    #expect(recorder.transactions.last?.itemChanges == [
        .move(
            itemID: movingModelID,
            from: WebInspectorFetchedResultsIndexPath(section: 1, item: 0),
            to: WebInspectorFetchedResultsIndexPath(section: 0, item: 1)
        ),
    ])
}

@MainActor
@Test
func networkFetchDescriptorAppliesPredicateSortAndLimit() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    await context.apply(.requestWillBeSent(
        id: Network.Request.ID("graphql-old"),
        request: Network.Request(id: Network.Request.ID("graphql-old"), url: "https://api.example.com/graphql?older", method: "POST"),
        resourceType: .fetch,
        redirectResponse: nil,
        timestamp: 1
    ))
    await context.apply(.requestWillBeSent(
        id: Network.Request.ID("image"),
        request: Network.Request(id: Network.Request.ID("image"), url: "https://static.example.com/photo.png", method: "GET"),
        resourceType: .image,
        redirectResponse: nil,
        timestamp: 2
    ))
    await context.apply(.requestWillBeSent(
        id: Network.Request.ID("graphql-new"),
        request: Network.Request(id: Network.Request.ID("graphql-new"), url: "https://api.example.com/graphql?newer", method: "POST"),
        resourceType: .fetch,
        redirectResponse: nil,
        timestamp: 3
    ))

    let xhrFetch = NetworkRequest.ResourceCategory.xhrFetch
    let search = "graphql"
    let descriptor = WebInspectorFetchDescriptor<NetworkRequest>(
        predicate: #Predicate { request in
            request.resourceCategory == xhrFetch
                && request.searchableText.localizedStandardContains(search)
        },
        sortBy: [SortDescriptor(\.requestSentTimestamp, order: .reverse)],
        fetchLimit: 1
    )

    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults(for: descriptor)

    #expect(results.items.map(\.id) == [NetworkRequest.ID(Network.Request.ID("graphql-new"))])
}

@MainActor
@Test
func networkFetchDescriptorPlansURLAndMIMETypePredicates() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    await context.apply(.requestWillBeSent(
        id: Network.Request.ID("api"),
        request: Network.Request(id: Network.Request.ID("api"), url: "https://api.example.com/data.json", method: "GET"),
        resourceType: .fetch,
        redirectResponse: nil,
        timestamp: 1
    ))
    await context.apply(.requestWillBeSent(
        id: Network.Request.ID("image"),
        request: Network.Request(id: Network.Request.ID("image"), url: "https://static.example.com/photo", method: "GET"),
        resourceType: .image,
        redirectResponse: nil,
        timestamp: 2
    ))
    await context.apply(.responseReceived(
        id: Network.Request.ID("image"),
        response: Network.Response(
            url: "https://static.example.com/photo",
            status: 200,
            mimeType: "image/png"
        ),
        resourceType: .image,
        timestamp: 3
    ))
    await context.apply(.requestWillBeSent(
        id: Network.Request.ID("script"),
        request: Network.Request(id: Network.Request.ID("script"), url: "https://cdn.example.com/app.js", method: "GET"),
        resourceType: .script,
        redirectResponse: nil,
        timestamp: 4
    ))

    let descriptor = WebInspectorFetchDescriptor<NetworkRequest>(
        predicate: #Predicate { request in
            request.url.localizedStandardContains("api")
                || request.mimeType == "image/png"
        },
        sortBy: [SortDescriptor(\.requestSentTimestamp, order: .forward)]
    )
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults(for: descriptor)

    #expect(results.items.map(\.id) == [
        NetworkRequest.ID(Network.Request.ID("api")),
        NetworkRequest.ID(Network.Request.ID("image")),
    ])
}

@MainActor
@Test
func clearNetworkRequestsResetsDescriptorBackedQueryState() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let descriptor = WebInspectorFetchDescriptor<NetworkRequest>(
        sortBy: [SortDescriptor(\.requestSentTimestamp, order: .forward)],
        fetchLimit: 2
    )
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults(for: descriptor)

    for (index, name) in ["stale-a", "stale-b", "stale-c"].enumerated() {
        await context.apply(.requestWillBeSent(
            id: Network.Request.ID(name),
            request: Network.Request(id: Network.Request.ID(name), url: "https://example.com/\(name)", method: "GET"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: Double(index + 1)
        ))
    }
    #expect(results.items.map(\.id) == [
        NetworkRequest.ID(Network.Request.ID("stale-a")),
        NetworkRequest.ID(Network.Request.ID("stale-b")),
    ])

    await context.clearNetworkRequests()
    #expect(results.items.isEmpty)

    let freshID = Network.Request.ID("fresh-after-clear")
    await context.apply(.requestWillBeSent(
        id: freshID,
        request: Network.Request(id: freshID, url: "https://example.com/fresh", method: "GET"),
        resourceType: .fetch,
        redirectResponse: nil,
        timestamp: 10
    ))

    #expect(results.items.map(\.id) == [NetworkRequest.ID(freshID)])
}

@MainActor
@Test
func startResetsDescriptorBackedNetworkQueryState() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let descriptor = WebInspectorFetchDescriptor<NetworkRequest>(
            sortBy: [SortDescriptor(\.requestSentTimestamp, order: .forward)],
            fetchLimit: 1
        )
        let networkResults: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults(for: descriptor)
        let staleRequestID = Network.Request.ID("stale-query-before-restart")

        try await emitFinishedRequest(id: staleRequestID, target: target, backend: runtime.wire)
        try await waitUntil {
            networkResults.items.map(\.id) == [NetworkRequest.ID(staleRequestID)]
        }

        await enqueueDomainDisableReplies(on: runtime.wire)
        try await enqueueStartupReplies(
            on: runtime.wire,
            document: DOM.Node(id: DOM.Node.ID("fresh-query-root"), nodeType: 9, nodeName: "#document")
        )

        context.start()

        try await waitUntil {
            networkResults.items.isEmpty && context.state == .attached
        }

        let freshRequestID = Network.Request.ID("fresh-query-after-restart")
        try await emitFinishedRequest(id: freshRequestID, target: target, backend: runtime.wire)
        try await waitUntil {
            networkResults.items.map(\.id) == [NetworkRequest.ID(freshRequestID)]
        }
    }
}

@MainActor
@Test
func networkFetchDescriptorOrdersEqualTimestampsByNewestInsertionFirst() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let descriptor = WebInspectorFetchDescriptor<NetworkRequest>(
        sortBy: [SortDescriptor(\.requestSentTimestamp, order: .reverse)]
    )
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults(for: descriptor)
    let recorder = FetchedResultsTransactionRecorder(stream: results.updates())
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()

    let firstID = Network.Request.ID("same-timestamp-first")
    let secondID = Network.Request.ID("same-timestamp-second")
    let firstModelID = NetworkRequest.ID(firstID)
    let secondModelID = NetworkRequest.ID(secondID)

    await context.apply(.requestWillBeSent(
        id: firstID,
        request: Network.Request(id: firstID, url: "https://example.com/first", method: "GET"),
        resourceType: .fetch,
        redirectResponse: nil,
        timestamp: 1
    ))
    try await recorder.waitForTransactionCount(1)
    #expect(results.items.map(\.id) == [firstModelID])

    await context.apply(.requestWillBeSent(
        id: secondID,
        request: Network.Request(id: secondID, url: "https://example.com/second", method: "GET"),
        resourceType: .fetch,
        redirectResponse: nil,
        timestamp: 1
    ))

    try await recorder.waitForTransactionCount(2)
    #expect(results.items.map(\.id) == [secondModelID, firstModelID])
    #expect(recorder.transactions.last?.itemChanges == [
        .insert(itemID: secondModelID, indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)),
    ])
}

@MainActor
@Test
func networkFetchDescriptorPublishesPredicateEnterAndLeave() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let descriptor = WebInspectorFetchDescriptor<NetworkRequest>(
        predicate: #Predicate { request in
            (request.statusCode ?? 0) >= 400
        }
    )
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults(for: descriptor)
    let recorder = FetchedResultsTransactionRecorder(stream: results.updates())
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()

    let requestID = Network.Request.ID("status-request")
    let modelID = NetworkRequest.ID(requestID)
    await context.apply(.requestWillBeSent(
        id: requestID,
        request: Network.Request(id: requestID, url: "https://api.example.com/status", method: "GET"),
        resourceType: .fetch,
        redirectResponse: nil,
        timestamp: 1
    ))
    #expect(results.items.isEmpty)
    #expect(recorder.transactions.isEmpty)

    await context.apply(.responseReceived(
        id: requestID,
        response: Network.Response(url: "https://api.example.com/status", status: 500),
        resourceType: .fetch,
        timestamp: 2
    ))

    try await recorder.waitForTransactionCount(1)
    #expect(results.items.map(\.id) == [modelID])
    #expect(recorder.transactions.last?.itemChanges == [
        .insert(itemID: modelID, indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)),
    ])

    await context.apply(.responseReceived(
        id: requestID,
        response: Network.Response(url: "https://api.example.com/status", status: 200),
        resourceType: .fetch,
        timestamp: 3
    ))

    try await recorder.waitForTransactionCount(2)
    #expect(results.items.isEmpty)
    #expect(recorder.transactions.last?.itemChanges == [
        .delete(itemID: modelID, indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)),
    ])
    #expect(context.registeredRequest(for: modelID) != nil)
}

@MainActor
@Test
func networkFetchDescriptorSupportsResourceCategorySets() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)

    await context.apply(.requestWillBeSent(
        id: Network.Request.ID("pending-avatar"),
        request: Network.Request(id: Network.Request.ID("pending-avatar"), url: "https://api.example.com/avatar.png", method: "GET"),
        resourceType: .xhr,
        redirectResponse: nil,
        timestamp: 1
    ))
    await context.apply(.requestWillBeSent(
        id: Network.Request.ID("script"),
        request: Network.Request(id: Network.Request.ID("script"), url: "https://cdn.example.com/app.js", method: "GET"),
        resourceType: .script,
        redirectResponse: nil,
        timestamp: 2
    ))
    await context.apply(.requestWillBeSent(
        id: Network.Request.ID("image"),
        request: Network.Request(id: Network.Request.ID("image"), url: "https://cdn.example.com/photo.png", method: "GET"),
        resourceType: .image,
        redirectResponse: nil,
        timestamp: 3
    ))
    await context.apply(.requestWillBeSent(
        id: Network.Request.ID("movie"),
        request: Network.Request(id: Network.Request.ID("movie"), url: "https://media.example.com/clip.mp4", method: "GET"),
        resourceType: .fetch,
        redirectResponse: nil,
        timestamp: 4
    ))

    let mediaCategories: [NetworkRequest.ResourceCategory] = [.image, .media]
    let descriptor = WebInspectorFetchDescriptor<NetworkRequest>(
        predicate: #Predicate { request in
            mediaCategories.contains(request.resourceCategory)
        },
        sortBy: [SortDescriptor(\.requestSentTimestamp, order: .reverse)]
    )
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults(for: descriptor)

    #expect(results.items.map(\.id) == [
        NetworkRequest.ID(Network.Request.ID("image")),
    ])

    await context.apply(.responseReceived(
        id: Network.Request.ID("pending-avatar"),
        response: Network.Response(
            url: "https://api.example.com/avatar.png",
            status: 200,
            mimeType: "image/png"
        ),
        resourceType: .xhr,
        timestamp: 5
    ))
    await context.apply(.responseReceived(
        id: Network.Request.ID("movie"),
        response: Network.Response(
            url: "https://media.example.com/clip.mp4",
            status: 200,
            mimeType: "application/octet-stream"
        ),
        resourceType: .fetch,
        timestamp: 6
    ))

    #expect(results.items.map(\.id) == [
        NetworkRequest.ID(Network.Request.ID("movie")),
        NetworkRequest.ID(Network.Request.ID("image")),
        NetworkRequest.ID(Network.Request.ID("pending-avatar")),
    ])
}

@MainActor
@Test
func networkRequestResourceCategoryUsesResponseHeadersWithoutPendingURLInference() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let requestID = Network.Request.ID("header-avatar")
    await context.apply(.requestWillBeSent(
        id: requestID,
        request: Network.Request(id: requestID, url: "https://api.example.com/avatar.png", method: "GET"),
        resourceType: .xhr,
        redirectResponse: nil,
        timestamp: 1
    ))
    let request = try #require(context.registeredRequest(forProxyID: requestID))

    #expect(request.resourceCategory == .xhrFetch)

    await context.apply(.responseReceived(
        id: requestID,
        response: Network.Response(
            url: "https://api.example.com/avatar",
            status: 200,
            mimeType: nil,
            headers: ["Content-Type": "image/png; charset=utf-8"]
        ),
        resourceType: .xhr,
        timestamp: 2
    ))

    #expect(request.resourceCategory == .image)
    #expect(request.searchableText.localizedStandardContains("image/png") == false)

    let scriptVideoID = Network.Request.ID("script-video")
    await context.apply(.requestWillBeSent(
        id: scriptVideoID,
        request: Network.Request(id: scriptVideoID, url: "https://cdn.example.com/player.js", method: "GET"),
        resourceType: .script,
        redirectResponse: nil,
        timestamp: 3
    ))
    let scriptVideoRequest = try #require(context.registeredRequest(forProxyID: scriptVideoID))
    #expect(scriptVideoRequest.resourceCategory == .script)

    await context.apply(.responseReceived(
        id: scriptVideoID,
        response: Network.Response(
            url: "https://cdn.example.com/player.js",
            status: 200,
            mimeType: "video/mp4"
        ),
        resourceType: .script,
        timestamp: 4
    ))

    #expect(scriptVideoRequest.resourceCategory == .media)
}

@MainActor
@Test
func clearNetworkRequestsPublishesResetAndIgnoresClearedEvents() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        let recorder = FetchedResultsTransactionRecorder(stream: results.updates())
        defer { recorder.cancel() }
        try await recorder.waitUntilStarted()

        let firstRequestID = Network.Request.ID("clear-first-request")
        let firstModelID = NetworkRequest.ID(firstRequestID)
        try await runtime.wire.emitRaw(
            .requestWillBeSent(
                id: firstRequestID,
                request: Network.Request(id: firstRequestID, url: "https://example.com/first", method: "GET"),
                resourceType: .fetch,
                redirectResponse: nil,
                timestamp: 1
            ),
            target: target
        )
        try await recorder.waitForTransactionCount(1)

        let secondRequestID = Network.Request.ID("clear-second-request")
        let secondModelID = NetworkRequest.ID(secondRequestID)
        try await runtime.wire.emitRaw(
            .requestWillBeSent(
                id: secondRequestID,
                request: Network.Request(id: secondRequestID, url: "https://example.com/second", method: "GET"),
                resourceType: .fetch,
                redirectResponse: nil,
                timestamp: 2
            ),
            target: target
        )
        try await recorder.waitForTransactionCount(2)
        #expect(results.snapshot.itemIDs == [firstModelID, secondModelID])

        await context.clearNetworkRequests()

        try await recorder.waitForTransactionCount(3)
        let reset = try #require(recorder.transactions.last)
        #expect(reset.isReset)
        #expect(reset.oldSnapshot.itemIDs == [firstModelID, secondModelID])
        #expect(reset.newSnapshot.itemIDs == [])
        #expect(reset.sectionChanges == [])
        #expect(reset.itemChanges == [])
        #expect(results.snapshot.itemIDs == [])
        #expect(results.items.isEmpty)
        #expect(context.registeredRequest(for: firstModelID) == nil)
        #expect(context.registeredRequest(for: secondModelID) == nil)

        let clearedEventBaseline = context.eventPumpAppliedSequenceForTesting
        try await runtime.wire.emitRaw(
            .responseReceived(
                id: firstRequestID,
                response: Network.Response(status: 200),
                resourceType: .fetch,
                timestamp: 3
            ),
            target: target
        )
        try await runtime.wire.emitRaw(
            .dataReceived(id: firstRequestID, dataLength: 7, encodedDataLength: 4, timestamp: 4),
            target: target
        )
        try await runtime.wire.emitRaw(
            .loadingFinished(id: secondRequestID, timestamp: 5, sourceMapURL: nil, metrics: nil),
            target: target
        )
        try await runtime.wire.emitRaw(
            .webSocket(.closed(id: secondRequestID, timestamp: 6)),
            target: target
        )
        let didProcessClearedEvents = await context.waitForEventPumpAppliedSequenceForTesting(
            after: clearedEventBaseline,
            count: 4
        )
        #expect(didProcessClearedEvents)
        #expect(context.state == .attached)
        #expect(results.items.isEmpty)
        #expect(recorder.transactions.count == 3)

        let redirectedEventBaseline = context.eventPumpAppliedSequenceForTesting
        try await runtime.wire.emitRaw(
            .requestWillBeSent(
                id: firstRequestID,
                request: Network.Request(
                    id: firstRequestID,
                    url: "https://example.com/redirected",
                    method: "GET"
                ),
                resourceType: .fetch,
                redirectResponse: Network.Response(url: "https://example.com/first", status: 302),
                timestamp: 7
            ),
            target: target
        )
        let didProcessRedirectedEvent = await context.waitForEventPumpAppliedSequenceForTesting(
            after: redirectedEventBaseline
        )
        #expect(didProcessRedirectedEvent)
        #expect(results.items.isEmpty)
        #expect(recorder.transactions.count == 3)
        #expect(context.registeredRequest(for: firstModelID) == nil)

        try await runtime.wire.emitRaw(
            .requestWillBeSent(
                id: firstRequestID,
                request: Network.Request(
                    id: firstRequestID,
                    url: "https://example.com/reused",
                    method: "GET"
                ),
                resourceType: .fetch,
                redirectResponse: nil,
                timestamp: 8
            ),
            target: target
        )

        try await recorder.waitForTransactionCount(4)
        let reusedRequest = try #require(results.items.first)
        #expect(reusedRequest.id == firstModelID)
        #expect(reusedRequest.url == "https://example.com/reused")
        #expect(context.registeredRequest(for: firstModelID) === reusedRequest)
    }
}

@MainActor
@Test
func networkRequestExposesDataKitQueryableProperties() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()

        let apiRequestID = Network.Request.ID("queryable-api-request")
        try await runtime.wire.emitRaw(
            .requestWillBeSent(
                id: apiRequestID,
                request: Network.Request(
                    id: apiRequestID,
                    url: "https://api.example.test/graphql?operation=Feed",
                    method: "POST"
                ),
                resourceType: .fetch,
                redirectResponse: nil,
                timestamp: 1
            ),
            target: target
        )
        try await runtime.wire.emitRaw(
            .responseReceived(
                id: apiRequestID,
                response: Network.Response(
                    url: "https://api.example.test/graphql?operation=Feed",
                    status: 201,
                    statusText: "Created",
                    mimeType: "application/json"
                ),
                resourceType: .fetch,
                timestamp: 2
            ),
            target: target
        )

        try await waitUntil { results.items.first?.statusCode == 201 }
        let apiRequest = try #require(results.items.first)
        #expect(apiRequest.resourceCategory == .xhrFetch)
        #expect(apiRequest.statusCode == 201)
        #expect(apiRequest.searchableText.localizedStandardContains("graphql"))
        #expect(apiRequest.searchableText.localizedStandardContains("POST"))
        #expect(apiRequest.searchableText.localizedStandardContains("201"))
        #expect(apiRequest.searchableText.localizedStandardContains("Created"))

        let cssRequestID = Network.Request.ID("queryable-css-request")
        try await runtime.wire.emitRaw(
            .responseReceived(
                id: cssRequestID,
                response: Network.Response(
                    url: "https://example.test/app.css",
                    status: 200,
                    mimeType: "text/css; charset=utf-8"
                ),
                resourceType: .other,
                timestamp: 3
            ),
            target: target
        )

        try await waitUntil { results.items.count == 2 }
        let cssRequest = try #require(results.items.last)
        #expect(cssRequest.resourceCategory == .stylesheet)
        #expect(cssRequest.searchableText.localizedStandardContains("app.css"))
        #expect(cssRequest.statusCode == 200)
    }
}

@MainActor
@Test
func fetchedResultsPublishConsoleInsertUpdateAndDeleteTransactions() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let results: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()
        let recorder = FetchedResultsTransactionRecorder(stream: results.updates())
        defer { recorder.cancel() }
        try await recorder.waitUntilStarted()

        try await runtime.wire.emitRaw(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "log"),
                text: "first"
            )),
            target: target
        )

        try await recorder.waitForTransactionCount(1)
        let firstID = try #require(results.snapshot.itemIDs.first)
        #expect(recorder.transactions.last?.itemChanges == [.insert(itemID: firstID, indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0))])

        try await runtime.wire.emitRaw(
            .messageRepeatCountUpdated(count: 3, timestamp: 2),
            target: target
        )

        try await recorder.waitForTransactionCount(2)
        #expect(recorder.transactions.last?.itemChanges == [.update(itemID: firstID, indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0))])

        try await runtime.wire.emitRaw(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "log"),
                text: "second"
            )),
            target: target
        )

        try await recorder.waitForTransactionCount(3)
        let secondID = try #require(results.snapshot.itemIDs.last)
        #expect(recorder.transactions.last?.itemChanges == [.insert(itemID: secondID, indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 1))])

        try await runtime.wire.emitRaw(
            .messagesCleared(reason: Console.ClearReason(rawValue: "console-api")),
            target: target
        )

        try await recorder.waitForTransactionCount(4)
        #expect(recorder.transactions.last?.itemChanges == [
            .delete(itemID: secondID, indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 1)),
            .delete(itemID: firstID, indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)),
        ])
        #expect(results.snapshot.itemIDs == [])
    }
}

@MainActor
@Test
func fetchedResultsCanBeSectionedByStringKeyPath() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults(sectionBy: \.method)
        let recorder = FetchedResultsTransactionRecorder(stream: results.updates())
        defer { recorder.cancel() }
        try await recorder.waitUntilStarted()

        let getID = Network.Request.ID("sectioned-get")
        try await runtime.wire.emitRaw(
            .requestWillBeSent(
                id: getID,
                request: Network.Request(id: getID, url: "https://example.com/get", method: "GET"),
                resourceType: .fetch,
                redirectResponse: nil,
                timestamp: 1
            ),
            target: target
        )

        try await recorder.waitForTransactionCount(1)
        #expect(results.sections.map(\.title) == ["GET"])
        #expect(results.snapshot.sectionIDs == [WebInspectorFetchSectionID(rawValue: "GET")])
        #expect(recorder.transactions.last?.sectionChanges == [
            .insert(sectionID: WebInspectorFetchSectionID(rawValue: "GET"), index: 0)
        ])
        #expect(recorder.transactions.last?.itemChanges == [
            .insert(
                itemID: NetworkRequest.ID(getID),
                indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)
            )
        ])

        let postID = Network.Request.ID("sectioned-post")
        try await runtime.wire.emitRaw(
            .requestWillBeSent(
                id: postID,
                request: Network.Request(id: postID, url: "https://example.com/post", method: "POST"),
                resourceType: .fetch,
                redirectResponse: nil,
                timestamp: 2
            ),
            target: target
        )

        try await recorder.waitForTransactionCount(2)
        #expect(results.sections.map(\.title) == ["GET", "POST"])
        #expect(recorder.transactions.last?.sectionChanges == [
            .insert(sectionID: WebInspectorFetchSectionID(rawValue: "POST"), index: 1)
        ])
        #expect(recorder.transactions.last?.itemChanges == [
            .insert(
                itemID: NetworkRequest.ID(postID),
                indexPath: WebInspectorFetchedResultsIndexPath(section: 1, item: 0)
            )
        ])

        let secondGetID = Network.Request.ID("sectioned-second-get")
        try await runtime.wire.emitRaw(
            .requestWillBeSent(
                id: secondGetID,
                request: Network.Request(id: secondGetID, url: "https://example.com/get-2", method: "GET"),
                resourceType: .fetch,
                redirectResponse: nil,
                timestamp: 3
            ),
            target: target
        )

        try await recorder.waitForTransactionCount(3)
        #expect(results.sections.map(\.items.count) == [2, 1])
        #expect(recorder.transactions.last?.sectionChanges == [])
        #expect(recorder.transactions.last?.itemChanges == [
            .insert(
                itemID: NetworkRequest.ID(secondGetID),
                indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 1)
            )
        ])
    }
}

@MainActor
@Test
func fetchedResultsCanBeSectionedByRawRepresentableKeyPath() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let results: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults(sectionBy: \.level)

        try await runtime.wire.emitRaw(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "warning"),
                text: "warning"
            )),
            target: target
        )

        try await waitUntil { results.sections.first?.title == "warning" }
        #expect(results.sections.map(\.id) == [WebInspectorFetchSectionID(rawValue: "warning")])
        #expect(results.sections.first?.items.first?.text == "warning")
    }
}

@MainActor
@Test
func fetchedResultsTransactionDiffsMovesByItemID() {
    let first = NetworkRequest.ID(Network.Request.ID("first"))
    let second = NetworkRequest.ID(Network.Request.ID("second"))
    let oldSnapshot = WebInspectorFetchedResultsSnapshot(itemIDs: [first, second])
    let newSnapshot = WebInspectorFetchedResultsSnapshot(itemIDs: [second, first])

    let transaction = WebInspectorFetchedResultsTransaction<NetworkRequest.ID>(
        oldSnapshot: oldSnapshot,
        newSnapshot: newSnapshot
    )

    #expect(transaction.itemChanges == [
        .move(itemID: second, from: WebInspectorFetchedResultsIndexPath(section: 0, item: 1), to: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)),
        .move(itemID: first, from: WebInspectorFetchedResultsIndexPath(section: 0, item: 0), to: WebInspectorFetchedResultsIndexPath(section: 0, item: 1)),
    ])
}

@MainActor
@Test
func selectingDOMNodeLoadsCSSStylesAndComputedProperties() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let document = try #require(context.rootNode)
        let elementID = DOM.Node.ID("styled-node")

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: document.id.proxyID, nodes: [
                DOM.Node(
                    id: elementID,
                    nodeType: 1,
                    nodeName: "DIV",
                    localName: "div",
                    childNodeCount: 0
                )
            ]),
            target: target
        )
        let element = try await waitForChild(in: context)

        try await enqueueCSSStyleReplies(on: runtime.wire)

        context.select(element)

        let styles = try #require(element.elementStyles)
        #expect(styles.phase == .loading)
        try await waitUntil { styles.phase == .loaded }
        #expect(styles.sections.map(\.title) == [".card"])
        #expect(styles.sections.map(\.kind) == [.rule])
        #expect(styles.computedProperties.map(\.name) == ["display"])

        let commands = runtime.wire.observations.commands
        #expect(commands.contains { $0.method == "CSS.enable" } == false)
        #expect(commands.contains { $0.method == "CSS.getMatchedStylesForNode" })
        #expect(commands.contains { $0.method == "CSS.getInlineStylesForNode" })
        #expect(commands.contains { $0.method == "CSS.getComputedStyleForNode" })
    }
}

@MainActor
@Test
func selectingDOMNodeRetriesCSSStyleLoadAfterEnablingAgent() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let document = try #require(context.rootNode)
        let elementID = DOM.Node.ID("styled-node")

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: document.id.proxyID, nodes: [
                DOM.Node(
                    id: elementID,
                    nodeType: 1,
                    nodeName: "DIV",
                    localName: "div",
                    childNodeCount: 0
                )
            ]),
            target: target
        )
        let element = try await waitForChild(in: context)

        await runtime.wire.fail(
            "CSS.getMatchedStylesForNode",
            message: "CSS agent is not enabled."
        )
        await runtime.wire.respond(to: "CSS.enable")
        try await enqueueCSSStyleReplies(on: runtime.wire)

        context.select(element)

        let styles = try #require(element.elementStyles)
        try await waitUntil { styles.phase == .loaded }
        #expect(styles.sections.map(\.title) == [".card"])
        #expect(styles.computedProperties.map(\.name) == ["display"])

        let cssCommands = runtime.wire.observations.commands
            .filter { $0.method.hasPrefix("CSS.") }
        #expect(cssCommands.map(\.method) == [
            "CSS.getMatchedStylesForNode",
            "CSS.enable",
            "CSS.getMatchedStylesForNode",
            "CSS.getInlineStylesForNode",
            "CSS.getComputedStyleForNode",
        ])
    }
}

@MainActor
@Test
func selectingFrameScopedDOMNodeRetriesCSSStyleLoadByEnablingFrameAgent() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let document = try #require(context.rootNode)
        let frameTargetRawValue = "frame-css-agent"
        _ = try await createFrameTarget(
            in: runtime,
            id: frameTargetRawValue,
            frameID: "frame-css-agent"
        )
        let elementID = DOM.Node.ID("frame-styled-node", scopedToTargetRawValue: frameTargetRawValue)

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: document.id.proxyID, nodes: [
                DOM.Node(
                    id: elementID,
                    nodeType: 1,
                    nodeName: "DIV",
                    localName: "div",
                    childNodeCount: 0
                )
            ]),
            target: target
        )
        let element = try await waitForChild(in: context)

        await runtime.wire.fail(
            "CSS.getMatchedStylesForNode",
            message: "CSS agent is not enabled."
        )
        await runtime.wire.respond(to: "CSS.enable")
        try await enqueueCSSStyleReplies(on: runtime.wire)

        context.select(element)

        let styles = try #require(element.elementStyles)
        try await waitUntil { styles.phase == .loaded }

        let enableCommand = runtime.wire.observations.commands.first {
            $0.method == "CSS.enable"
        }
        #expect(enableCommand?.destination == .target(frameTargetRawValue))
    }
}

@MainActor
@Test
func selectingNonElementDOMNodeDoesNotRequestCSSStyles() async throws {
    try await withDataKitTestRuntime { runtime in
        let (_, context) = try await startContext(runtime: runtime)
        let document = try #require(context.rootNode)

        context.select(document)

        #expect(document.elementStyles == nil)
        let commands = runtime.wire.observations.commands
        #expect(commands.contains { $0.method == "CSS.getMatchedStylesForNode" } == false)
        #expect(commands.contains { $0.method == "CSS.getComputedStyleForNode" } == false)
    }
}

@MainActor
@Test
func cssEventsAndSelectedDOMMutationsMarkSelectedStylesStale() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let document = try #require(context.rootNode)
        let selectedID = DOM.Node.ID("selected")
        let otherID = DOM.Node.ID("other")

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: document.id.proxyID, nodes: [
                DOM.Node(id: selectedID, nodeType: 1, nodeName: "DIV", localName: "div"),
                DOM.Node(id: otherID, nodeType: 1, nodeName: "SPAN", localName: "span"),
            ]),
            target: target
        )
        try await waitUntil {
            guard case let .loaded(children) = document.children else {
                return false
            }
            return children.count == 2
        }
        guard case let .loaded(children) = document.children else {
            Issue.record("Expected loaded document children.")
            return
        }
        let selected = try #require(children.first { $0.id == DOMNode.ID(selectedID) })

        try await enqueueCSSStyleReplies(on: runtime.wire)
        context.select(selected)
        let styles = try #require(selected.elementStyles)
        try await waitUntil { styles.phase == .loaded }

        @MainActor
        func reloadSelectedStyles() async throws {
            try await enqueueCSSStyleReplies(on: runtime.wire)
            context.select(selected)
            try await waitUntil { styles.phase == .loaded }
        }

        try await runtime.wire.emitRaw(.styleSheetChanged(CSS.StyleSheet.ID("sheet-1")), target: target)
        try await waitUntil { styles.phase == .needsRefresh }

        try await reloadSelectedStyles()

        try await runtime.wire.emitRaw(
            .styleSheetAdded(CSS.StyleSheetHeader(
                styleSheetID: CSS.StyleSheet.ID("sheet-1"),
                origin: CSS.Origin(rawValue: "author")
            )),
            target: target
        )
        try await waitUntil { styles.phase == .needsRefresh }

        try await reloadSelectedStyles()

        try await runtime.wire.emitRaw(.styleSheetRemoved(CSS.StyleSheet.ID("sheet-1")), target: target)
        try await waitUntil { styles.phase == .needsRefresh }

        try await reloadSelectedStyles()

        try await runtime.wire.emitRaw(.mediaQueryResultChanged, target: target)
        try await waitUntil { styles.phase == .needsRefresh }

        try await reloadSelectedStyles()

        let otherAttributeBaseline = context.eventPumpAppliedSequenceForTesting
        try await runtime.wire.emitRaw(.attributeModified(otherID, name: "class", value: "ignored"), target: target)
        let didProcessOtherAttribute = await context.waitForEventPumpAppliedSequenceForTesting(
            after: otherAttributeBaseline
        )
        #expect(didProcessOtherAttribute)
        #expect(styles.phase == .loaded)

        let otherLayoutBaseline = context.eventPumpAppliedSequenceForTesting
        try await runtime.wire.emitRaw(.nodeLayoutFlagsChanged(otherID), target: target)
        let didProcessOtherLayout = await context.waitForEventPumpAppliedSequenceForTesting(
            after: otherLayoutBaseline
        )
        #expect(didProcessOtherLayout)
        #expect(styles.phase == .loaded)

        try await runtime.wire.emitRaw(.nodeLayoutFlagsChanged(selectedID), target: target)
        try await waitUntil { styles.phase == .needsRefresh }

        try await reloadSelectedStyles()

        try await runtime.wire.emitRaw(.attributeModified(selectedID, name: "class", value: "changed"), target: target)
        try await waitUntil { styles.phase == .needsRefresh }
    }
}

@MainActor
@Test
func cssInvalidationDuringStyleFetchIsNotOverwrittenByStaleResult() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let document = try #require(context.rootNode)
        let elementID = DOM.Node.ID("styled-node")
        let computedGate = await runtime.wire.deferReply(
            to: "CSS.getComputedStyleForNode",
            with: try rawCSSComputedStyleResult([
                CSS.ComputedProperty(name: "display", value: "grid"),
            ])
        )

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: document.id.proxyID, nodes: [
                DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
            ]),
            target: target
        )
        let element = try await waitForChild(in: context)

        await runtime.wire.respond(
            to: "CSS.getMatchedStylesForNode",
            with: try rawCSSMatchedStylesResult(CSS.MatchedStyles(matchedRules: [
                CSS.Rule(
                    selectorList: CSS.Rule.SelectorList(selectors: [".card"], text: ".card"),
                    origin: CSS.Origin(rawValue: "regular"),
                    style: CSS.Style(id: CSS.Style.ID("style-1"))
                )
            ]))
        )
        await runtime.wire.respond(
            to: "CSS.getInlineStylesForNode",
            with: try rawCSSInlineStylesResult(CSS.InlineStyles())
        )

        context.select(element)
        let styles = try #require(element.elementStyles)
        try await waitUntil {
            runtime.wire.observations.commandMethods.contains(
                "CSS.getComputedStyleForNode"
            )
        }

        try await runtime.wire.emitRaw(.styleSheetChanged(CSS.StyleSheet.ID("sheet-1")), target: target)
        try await waitUntil { styles.phase == .needsRefresh }

        computedGate.open()
        _ = await runtime.wire.observations.waitForCompletedCommands(
            method: "CSS.getComputedStyleForNode",
            count: 1
        )
        #expect(styles.phase == .needsRefresh)
        #expect(styles.computedProperties.isEmpty)
    }
}

@MainActor
@Test
func selectingDOMNodeLoadsInlineAndAttributesStyleSections() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let document = try #require(context.rootNode)
        let elementID = DOM.Node.ID("styled-node")

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: document.id.proxyID, nodes: [
                DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
            ]),
            target: target
        )
        let element = try await waitForChild(in: context)

        await runtime.wire.respond(
            to: "CSS.getMatchedStylesForNode",
            with: try rawCSSMatchedStylesResult(CSS.MatchedStyles(matchedRules: [
                CSS.Rule(
                    selectorList: CSS.Rule.SelectorList(selectors: [".card"], text: ".card"),
                    origin: CSS.Origin(rawValue: "regular"),
                    style: CSS.Style(id: CSS.Style.ID("style-rule"), cssText: "display: grid;")
                )
            ]))
        )
        await runtime.wire.respond(
            to: "CSS.getInlineStylesForNode",
            with: try rawCSSInlineStylesResult(CSS.InlineStyles(
                inlineStyle: CSS.Style(
                    id: CSS.Style.ID("style-inline"),
                    properties: [
                        CSS.Property(
                            id: CSS.Property.ID("inline-color"),
                            name: "color",
                            value: "red",
                            text: "color: red;",
                            isEditable: true
                        )
                    ],
                    cssText: "color: red;",
                    isEditable: true
                ),
                attributesStyle: CSS.Style(
                    id: CSS.Style.ID("style-attributes"),
                    properties: [
                        CSS.Property(id: CSS.Property.ID("attribute-width"), name: "width", value: "100px")
                    ]
                )
            ))
        )
        await runtime.wire.respond(
            to: "CSS.getComputedStyleForNode",
            with: try rawCSSComputedStyleResult([
                CSS.ComputedProperty(name: "display", value: "grid"),
            ])
        )

        context.select(element)

        let styles = try #require(element.elementStyles)
        try await waitUntil { styles.phase == .loaded }
        #expect(styles.sections.map(\.kind) == [.inlineStyle, .rule, .attributesStyle])
        #expect(styles.sections.map(\.title) == ["element.style", ".card", "Attributes"])
        #expect(styles.sections.map(\.isEditable) == [true, false, false])
    }
}

@MainActor
@Test
func styleSheetChangedWhileHydrationActiveTriggersImmediateRefetch() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let document = try #require(context.rootNode)
        let elementID = DOM.Node.ID("styled-node")

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: document.id.proxyID, nodes: [
                DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
            ]),
            target: target
        )
        let element = try await waitForChild(in: context)

        context.setStyleHydrationActive(true)
        try await enqueueCSSStyleReplies(on: runtime.wire)
        context.select(element)
        let styles = try #require(element.elementStyles)
        try await waitUntil { styles.phase == .loaded }

        try await enqueueCSSStyleReplies(on: runtime.wire)
        try await runtime.wire.emitRaw(.styleSheetChanged(CSS.StyleSheet.ID("sheet-1")), target: target)

        try await waitUntil {
            matchedStylesCommandCount(on: runtime.wire) == 2
        }
        try await waitUntil { styles.phase == .loaded }
    }
}

@MainActor
@Test
func styleSheetChangedWhileHydrationInactiveDefersRefetchUntilActivation() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let document = try #require(context.rootNode)
        let elementID = DOM.Node.ID("styled-node")

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: document.id.proxyID, nodes: [
                DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
            ]),
            target: target
        )
        let element = try await waitForChild(in: context)

        try await enqueueCSSStyleReplies(on: runtime.wire)
        context.select(element)
        let styles = try #require(element.elementStyles)
        try await waitUntil { styles.phase == .loaded }

        try await runtime.wire.emitRaw(.styleSheetChanged(CSS.StyleSheet.ID("sheet-1")), target: target)
        try await waitUntil { styles.phase == .needsRefresh }
        #expect(styles.phase == .needsRefresh)
        #expect(matchedStylesCommandCount(on: runtime.wire) == 1)

        try await enqueueCSSStyleReplies(on: runtime.wire)
        context.setStyleHydrationActive(true)

        try await waitUntil { styles.phase == .loaded }
        #expect(matchedStylesCommandCount(on: runtime.wire) == 2)
    }
}

@MainActor
@Test
func requestSetCSSPropertyTogglesDeclarationAndRefreshesStyles() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let document = try #require(context.rootNode)
        let elementID = DOM.Node.ID("styled-node")

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: document.id.proxyID, nodes: [
                DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
            ]),
            target: target
        )
        let element = try await waitForChild(in: context)

        context.setStyleHydrationActive(true)
        try await enqueueCSSStyleReplies(on: runtime.wire)
        context.select(element)
        let styles = try #require(element.elementStyles)
        try await waitUntil { styles.phase == .loaded }

        let disabledStyle = CSS.Style(
            id: CSS.Style.ID("style-1"),
            properties: [
                CSS.Property(
                    id: CSS.Property.ID("property-1"),
                    name: "display",
                    value: "grid",
                    text: "/* display: grid; */",
                    status: .disabled,
                    isEditable: true
                )
            ],
            cssText: "/* display: grid; */",
            isEditable: true
        )
        await runtime.wire.respond(
            to: "CSS.setStyleText",
            with: try rawCSSStyleResult(disabledStyle)
        )
        await runtime.wire.respond(
            to: "CSS.getMatchedStylesForNode",
            with: try rawCSSMatchedStylesResult(CSS.MatchedStyles(matchedRules: [
                CSS.Rule(
                    selectorList: CSS.Rule.SelectorList(selectors: [".card"], text: ".card"),
                    origin: CSS.Origin(rawValue: "regular"),
                    style: disabledStyle
                )
            ]))
        )
        await runtime.wire.respond(
            to: "CSS.getInlineStylesForNode",
            with: try rawCSSInlineStylesResult(CSS.InlineStyles())
        )
        await runtime.wire.respond(
            to: "CSS.getComputedStyleForNode",
            with: try rawCSSComputedStyleResult([
                CSS.ComputedProperty(name: "display", value: "grid"),
            ])
        )

        let propertyID = try #require(styles.sections.first?.style.properties.first?.id)
        await runtime.wire.respond(to: "DOM.markUndoableState")
        #expect(context.requestSetCSSProperty(
            propertyID,
            enabled: false,
            options: .automatic
        ))

        try await waitUntil {
            matchedStylesCommandCount(on: runtime.wire) == 2
        }
        try await waitUntil { styles.phase == .loaded }

        let commands = runtime.wire.observations.commands
        let setStyleText = try #require(commands.last { $0.method == "CSS.setStyleText" })
        #expect(try commandNestedStringParameter(
            setStyleText,
            object: "styleId",
            key: "styleSheetId"
        ) == "style-1")
        #expect(try commandStringParameter(setStyleText, "text") == "/* display: grid; */")
        let undoMarks = commands.filter { $0.method == "DOM.markUndoableState" }
        #expect(undoMarks.count == 1)
        #expect(undoMarks.first?.destination == .target(wireTargetID(target)))

        let property = try #require(styles.sections.first?.style.properties.first)
        #expect(property.status == .disabled)
        #expect(property.isModifiedByInspector)
    }
}

@MainActor
@Test
func setCSSDeclarationTextRewritesStyleTextAndMarksUndoableState() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let document = try #require(context.rootNode)
        let elementID = DOM.Node.ID("styled-node")

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: document.id.proxyID, nodes: [
                DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
            ]),
            target: target
        )
        let element = try await waitForChild(in: context)

        try await enqueueCSSStyleReplies(on: runtime.wire)
        context.select(element)
        let styles = try #require(element.elementStyles)
        try await waitUntil { styles.phase == .loaded }

        let updatedStyle = CSS.Style(
            id: CSS.Style.ID("style-1"),
            properties: [
                CSS.Property(
                    id: CSS.Property.ID("property-1"),
                    name: "display",
                    value: "flex",
                    text: "display: flex;",
                    isEditable: true,
                    isModifiedByInspector: true
                )
            ],
            cssText: "display: flex;",
            isEditable: true
        )
        await runtime.wire.respond(
            to: "CSS.setStyleText",
            with: try rawCSSStyleResult(updatedStyle)
        )
        await runtime.wire.respond(to: "DOM.markUndoableState")

        let propertyID = try #require(styles.sections.first?.style.properties.first?.id)
        try await context.setCSSDeclarationText(
            "display: flex;",
            for: propertyID,
            options: .automatic
        )

        let commands = runtime.wire.observations.commands
        let setStyleText = try #require(commands.last { $0.method == "CSS.setStyleText" })
        #expect(try commandNestedStringParameter(
            setStyleText,
            object: "styleId",
            key: "styleSheetId"
        ) == "style-1")
        #expect(try commandStringParameter(setStyleText, "text") == "display: flex;")
        let undoMarks = commands.filter { $0.method == "DOM.markUndoableState" }
        #expect(undoMarks.count == 1)
        #expect(undoMarks.first?.destination == .target(wireTargetID(target)))

        let property = try #require(styles.sections.first?.style.properties.first)
        #expect(property.value == "flex")
        #expect(property.text == "display: flex;")
        #expect(property.isModifiedByInspector)
        #expect(styles.phase == .needsRefresh)
    }
}

@MainActor
@Test
func cssRuleSelectorEditsMarkUndoableStateOnOwningTarget() async throws {
    try await withDataKitTestRuntime { runtime in
        let (_, context) = try await startContext(runtime: runtime)
        let frameTarget = try await createFrameTarget(in: runtime)
        let proxyRuleID = CSS.Rule.ID(
            "frame-sheet\u{1F}3",
            scopedToTargetRawValue: frameTarget.id.rawValue
        )
        let ruleID = CSSStyleRule.ID(proxyRuleID)

        await runtime.wire.respond(
            to: "CSS.setRuleSelector",
            with: try rawCSSRuleResult(CSS.Rule(
                id: proxyRuleID,
                selectorList: CSS.Rule.SelectorList(selectors: [".updated"], text: ".updated"),
                origin: CSS.Origin(rawValue: "regular"),
                style: CSS.Style(
                    id: CSS.Style.ID(
                        "frame-sheet\u{1F}4",
                        scopedToTargetRawValue: frameTarget.id.rawValue
                    ),
                    isEditable: true
                )
            ))
        )
        await runtime.wire.respond(to: "DOM.markUndoableState")

        try await context.setCSSRuleSelector(
            ".updated",
            for: ruleID,
            options: .automatic
        )

        let commands = runtime.wire.observations.commands
        let setRuleSelector = try #require(commands.first { $0.method == "CSS.setRuleSelector" })
        #expect(setRuleSelector.destination == .target(wireTargetID(frameTarget)))
        #expect(try commandNestedStringParameter(
            setRuleSelector,
            object: "ruleId",
            key: "styleSheetId"
        ) == "frame-sheet")

        let markUndoableState = try #require(commands.first { $0.method == "DOM.markUndoableState" })
        #expect(markUndoableState.destination == .target(wireTargetID(frameTarget)))
    }
}

@MainActor
@Test
func requestSetCSSPropertyRefusesStaleAndNonEditableProperties() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let document = try #require(context.rootNode)
        let elementID = DOM.Node.ID("styled-node")

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: document.id.proxyID, nodes: [
                DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
            ]),
            target: target
        )
        let element = try await waitForChild(in: context)

        await runtime.wire.respond(
            to: "CSS.getMatchedStylesForNode",
            with: try rawCSSMatchedStylesResult(CSS.MatchedStyles(matchedRules: [
                CSS.Rule(
                    selectorList: CSS.Rule.SelectorList(selectors: ["div"], text: "div"),
                    origin: CSS.Origin(rawValue: "user-agent"),
                    style: CSS.Style(
                        id: CSS.Style.ID("style-ua"),
                        properties: [
                            CSS.Property(
                                id: CSS.Property.ID("property-ua"),
                                name: "display",
                                value: "block",
                                text: "display: block;",
                                isEditable: true
                            )
                        ],
                        cssText: "display: block;",
                        isEditable: true
                    )
                ),
                CSS.Rule(
                    selectorList: CSS.Rule.SelectorList(selectors: [".card"], text: ".card"),
                    origin: CSS.Origin(rawValue: "regular"),
                    style: CSS.Style(
                        id: CSS.Style.ID("style-1"),
                        properties: [
                            CSS.Property(
                                id: CSS.Property.ID("property-1"),
                                name: "display",
                                value: "grid",
                                text: "display: grid;",
                                isEditable: true
                            )
                        ],
                        cssText: "display: grid;",
                        isEditable: true
                    )
                ),
            ]))
        )
        await runtime.wire.respond(
            to: "CSS.getInlineStylesForNode",
            with: try rawCSSInlineStylesResult(CSS.InlineStyles())
        )
        await runtime.wire.respond(
            to: "CSS.getComputedStyleForNode",
            with: try rawCSSComputedStyleResult([
                CSS.ComputedProperty(name: "display", value: "grid"),
            ])
        )
        context.select(element)
        let styles = try #require(element.elementStyles)
        try await waitUntil { styles.phase == .loaded }

        let userAgentSection = try #require(styles.sections.first { $0.title == "div" })
        #expect(userAgentSection.isEditable == false)
        let userAgentPropertyID = try #require(userAgentSection.style.properties.first?.id)
        #expect(context.requestSetCSSProperty(
            userAgentPropertyID,
            enabled: false,
            options: .automatic
        ) == false)

        let editableSection = try #require(styles.sections.first { $0.title == ".card" })
        let editablePropertyID = try #require(editableSection.style.properties.first?.id)

        try await runtime.wire.emitRaw(.styleSheetChanged(CSS.StyleSheet.ID("sheet-1")), target: target)
        try await waitUntil { styles.phase == .needsRefresh }
        #expect(context.requestSetCSSProperty(
            editablePropertyID,
            enabled: false,
            options: .automatic
        ) == false)

        let commands = runtime.wire.observations.commands
        #expect(commands.contains { $0.method == "CSS.setStyleText" } == false)
    }
}

@MainActor
@Test
func removingLoadedChildPurgesDescendantsFromIdentityMap() async throws {
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()
        let documentID = DOM.Node.ID("document")
        let childID = DOM.Node.ID("child")
        let grandchildID = DOM.Node.ID("grandchild")

        try await enqueueStartupReplies(
            on: runtime.wire,
            document: DOM.Node(id: documentID, nodeType: 9, nodeName: "#document")
        )

        let container = WebInspectorContainer(proxy: runtime.proxy)
        let context = container.mainContext
        try await waitForStartupSubscribers(runtime: runtime, target: target)
        try await waitUntil { context.rootNode != nil }

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: documentID, nodes: [
                DOM.Node(
                    id: childID,
                    nodeType: 1,
                    nodeName: "SECTION",
                    localName: "section",
                    childNodeCount: 1,
                    children: [
                        DOM.Node(
                            id: grandchildID,
                            nodeType: 1,
                            nodeName: "SPAN",
                            localName: "span"
                        )
                    ]
                )
            ]),
            target: target
        )

        try await waitUntil {
            context.node(for: DOMNode.ID(grandchildID)) != nil
        }

        try await runtime.wire.emitRaw(
            .childNodeRemoved(parent: documentID, node: childID),
            target: target
        )

        try await waitUntil {
            context.node(for: DOMNode.ID(childID)) == nil
                && context.node(for: DOMNode.ID(grandchildID)) == nil
        }
    }
}

@MainActor
@Test
func setChildNodesPreservesReparentedDescendantIdentity() async throws {
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()
        let documentID = DOM.Node.ID("document")
        let oldParentID = DOM.Node.ID("old-parent")
        let newParentID = DOM.Node.ID("new-parent")
        let movedChildID = DOM.Node.ID("moved-child")

        try await enqueueStartupReplies(
            on: runtime.wire,
            document: DOM.Node(id: documentID, nodeType: 9, nodeName: "#document")
        )

        let container = WebInspectorContainer(proxy: runtime.proxy)
        let context = container.mainContext
        try await waitForStartupSubscribers(runtime: runtime, target: target)
        try await waitUntil { context.rootNode != nil }

        try await runtime.wire.emitRaw(
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

        try await waitUntil { context.node(for: DOMNode.ID(movedChildID)) != nil }
        let movedChild = try #require(context.node(for: DOMNode.ID(movedChildID)))

        try await runtime.wire.emitRaw(
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

        try await waitUntil {
            context.node(for: DOMNode.ID(oldParentID)) == nil
                && context.node(for: DOMNode.ID(newParentID)) != nil
        }
        #expect(context.node(for: DOMNode.ID(movedChildID)) === movedChild)
    }
}

@MainActor
@Test
func setChildNodesPrunesOmittedDescendantsWhenReusingChildNode() async throws {
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()
        let documentID = DOM.Node.ID("document")
        let childID = DOM.Node.ID("child")
        let removedSpanID = DOM.Node.ID("removed-span")
        let removedEmID = DOM.Node.ID("removed-em")

        try await enqueueStartupReplies(
            on: runtime.wire,
            document: DOM.Node(id: documentID, nodeType: 9, nodeName: "#document")
        )

        let container = WebInspectorContainer(proxy: runtime.proxy)
        let context = container.mainContext
        try await waitForStartupSubscribers(runtime: runtime, target: target)
        try await waitUntil { context.rootNode != nil }

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: documentID, nodes: [
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

        try await waitUntil { context.node(for: DOMNode.ID(removedEmID)) != nil }
        let child = try #require(context.node(for: DOMNode.ID(childID)))

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: documentID, nodes: [
                DOM.Node(id: childID, nodeType: 1, nodeName: "DIV", localName: "div", childNodeCount: 0)
            ]),
            target: target
        )

        try await waitUntil {
            context.node(for: DOMNode.ID(removedSpanID)) == nil
                && context.node(for: DOMNode.ID(removedEmID)) == nil
        }
        #expect(context.node(for: DOMNode.ID(childID)) === child)
    }
}

@MainActor
@Test
func setChildNodesPreservesLoadedDescendantsForShallowRefresh() async throws {
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()
        let documentID = DOM.Node.ID("document")
        let childID = DOM.Node.ID("child")
        let grandchildID = DOM.Node.ID("grandchild")

        try await enqueueStartupReplies(
            on: runtime.wire,
            document: DOM.Node(id: documentID, nodeType: 9, nodeName: "#document")
        )

        let container = WebInspectorContainer(proxy: runtime.proxy)
        let context = container.mainContext
        try await waitForStartupSubscribers(runtime: runtime, target: target)
        try await waitUntil { context.rootNode != nil }

        try await runtime.wire.emitRaw(
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

        try await waitUntil { context.node(for: DOMNode.ID(grandchildID)) != nil }
        let grandchild = try #require(context.node(for: DOMNode.ID(grandchildID)))

        try await runtime.wire.emitRaw(
            .setChildNodes(parent: documentID, nodes: [
                DOM.Node(id: childID, nodeType: 1, nodeName: "DIV", localName: "div", childNodeCount: 1)
            ]),
            target: target
        )

        try await waitUntil {
            guard let child = context.node(for: DOMNode.ID(childID)),
                  case let .loaded(children) = child.children else {
                return false
            }
            return children.first === grandchild
        }
        #expect(context.node(for: DOMNode.ID(grandchildID)) === grandchild)
    }
}

@MainActor
@Test
func closeDuringStartupKeepsContextDetached() async throws {
    try await withDataKitTestRuntime { runtime in
        let documentID = DOM.Node.ID("document")

        let gate = await runtime.wire.deferReply(
            to: "DOM.getDocument",
            with: try domDocumentResult(
                DOM.Node(id: documentID, nodeType: 9, nodeName: "#document")
            )
        )
        await enqueueDomainEnableReplies(on: runtime.wire)
        await enqueueDomainDisableReplies(on: runtime.wire)

        let container = WebInspectorContainer(proxy: runtime.proxy)
        let context = container.mainContext
        let startupTask = try #require(context.startupTaskForTesting())
        try await waitUntil {
            runtime.wire.observations.commands
                .contains { $0.method == "DOM.getDocument" }
        }

        await container.close()
        #expect(context.state == .detached)

        gate.open()
        await startupTask.value
        _ = await runtime.wire.observations.waitForCommands(method: "Inspector.disable", count: 1)

        #expect(context.state == .detached)
        #expect(context.rootNode == nil)

        let commands = runtime.wire.observations.commands
        #expect(commands.map(\.method) == Array(startupCommands.prefix(5)) + [
            "Runtime.disable",
            "Network.disable",
            "Inspector.disable",
        ])
    }
}

@MainActor
@Test
func stopDuringStartupReleasesLateRuntimeAcquire() async throws {
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()
        let gate = await runtime.wire.deferReply(to: "Runtime.enable")

        await runtime.wire.respond(to: "Inspector.enable")
        await runtime.wire.respond(to: "Inspector.initialized")

        let container = WebInspectorContainer(proxy: runtime.proxy)
        let context = container.mainContext
        try await waitForStartupSubscribers(runtime: runtime, target: target)
        try await waitUntil {
            runtime.wire.observations.commandMethods == [
                "Inspector.enable",
                "Inspector.initialized",
                "Runtime.enable",
            ]
        }

        await runtime.wire.respond(to: "Inspector.disable")
        await context.stop()
        #expect(context.state == .detached)

        await runtime.wire.respond(to: "Runtime.disable")
        gate.open()
        try await waitUntil {
            runtime.wire.observations.commandMethods == [
                "Inspector.enable",
                "Inspector.initialized",
                "Runtime.enable",
                "Inspector.disable",
                "Runtime.disable",
            ]
        }
        #expect(context.state == .detached)
    }
}

@MainActor
@Test
func domainEnablementReleaseDuringPendingEnableDisablesAfterEnableCompletes() async throws {
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()
        let registry = WebInspectorDomainEnablementRegistry()
        let gate = await runtime.wire.deferReply(to: "Runtime.enable")

        let acquireTask = Task {
            try await registry.acquire(.runtime, on: target)
        }

        try await waitUntil {
            runtime.wire.observations.commandMethods == [
                "Runtime.enable"
            ]
        }

        let releaseTask = Task {
            await registry.release(.runtime, on: target)
        }

        await runtime.wire.respond(to: "Runtime.disable")
        gate.open()

        try await acquireTask.value
        #expect(await releaseTask.value == nil)

        let commands = runtime.wire.observations.commands
        #expect(commands.map(\.method) == [
            "Runtime.enable",
            "Runtime.disable",
        ])
    }
}

@MainActor
@Test
func domainEnablementAcquireWaitsForFinalReleaseDisable() async throws {
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()
        let registry = WebInspectorDomainEnablementRegistry()
        let disableGate = await runtime.wire.deferReply(to: "Runtime.disable")

        await runtime.wire.respond(to: "Runtime.enable")
        try await registry.acquire(.runtime, on: target)

        let releaseTask = Task {
            await registry.release(.runtime, on: target)
        }
        try await waitUntil {
            runtime.wire.observations.commandMethods == [
                "Runtime.enable",
                "Runtime.disable",
            ]
        }

        let acquireWaitBaseline = await registry.acquireWaitingForDisableSequenceForTesting
        let acquireTask = Task {
            try await registry.acquire(.runtime, on: target)
        }
        await registry.waitForAcquireWaitingForDisableForTesting(after: acquireWaitBaseline)
        #expect(runtime.wire.observations.commandMethods == [
            "Runtime.enable",
            "Runtime.disable",
        ])

        await runtime.wire.respond(to: "Runtime.enable")
        disableGate.open()

        #expect(await releaseTask.value == nil)
        try await acquireTask.value
        #expect(runtime.wire.observations.commandMethods == [
            "Runtime.enable",
            "Runtime.disable",
            "Runtime.enable",
        ])
    }
}

@MainActor
@Test
func domainEnablementAcquireWaitsForPendingReleaseDisable() async throws {
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()
        let registry = WebInspectorDomainEnablementRegistry()
        let enableGate = await runtime.wire.deferReply(to: "Runtime.enable")
        let disableGate = await runtime.wire.deferReply(to: "Runtime.disable")

        let firstAcquireTask = Task {
            try await registry.acquire(.runtime, on: target)
        }
        try await waitUntil {
            runtime.wire.observations.commandMethods == [
                "Runtime.enable"
            ]
        }

        let releaseTask = Task {
            await registry.release(.runtime, on: target)
        }
        let acquireWaitBaseline = await registry.acquireWaitingForDisableSequenceForTesting
        let secondAcquireTask = Task {
            try await registry.acquire(.runtime, on: target)
        }
        await registry.waitForAcquireWaitingForDisableForTesting(after: acquireWaitBaseline)

        enableGate.open()
        try await waitUntil {
            runtime.wire.observations.commandMethods == [
                "Runtime.enable",
                "Runtime.disable",
            ]
        }
        #expect(runtime.wire.observations.commandMethods == [
            "Runtime.enable",
            "Runtime.disable",
        ])

        await runtime.wire.respond(to: "Runtime.enable")
        disableGate.open()

        try await firstAcquireTask.value
        #expect(await releaseTask.value == nil)
        try await secondAcquireTask.value
        #expect(runtime.wire.observations.commandMethods == [
            "Runtime.enable",
            "Runtime.disable",
            "Runtime.enable",
        ])
    }
}

@MainActor
@Test
func domainEnablementDiscardLeasePreservesSharedEnabledLease() async throws {
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()
        let registry = WebInspectorDomainEnablementRegistry()

        await runtime.wire.respond(to: "Runtime.enable")
        try await registry.acquire(.runtime, on: target)
        try await registry.acquire(.runtime, on: target)

        await registry.discardLease(.runtime, on: target)

        await runtime.wire.respond(to: "Runtime.disable")
        #expect(await registry.release(.runtime, on: target) == nil)

        let commands = runtime.wire.observations.commands
        #expect(commands.map(\.method) == [
            "Runtime.enable",
            "Runtime.disable",
        ])
    }
}

@MainActor
@Test
func domainLeaseRetargetInterleavingReenablesCommittedPageBinding() async throws {
    try await withDataKitTestRuntime { runtime in
        let registry = WebInspectorDomainEnablementRegistry()
        let oldPage = WebInspectorTarget(
            id: .currentPage,
            kind: .page,
            frameID: nil,
            isProvisional: false,
            proxy: runtime.proxy,
            route: .currentPage,
            pageBindingID: "page-old"
        )
        let newPage = WebInspectorTarget(
            id: .currentPage,
            kind: .page,
            frameID: nil,
            isProvisional: false,
            proxy: runtime.proxy,
            route: .currentPage,
            pageBindingID: "page-new"
        )

        await runtime.wire.respond(to: "Runtime.enable")
        try await registry.acquire(.runtime, on: oldPage)
        try await registry.acquire(.runtime, on: oldPage)

        await registry.discardLease(.runtime, on: oldPage)
        await runtime.wire.respond(to: "Runtime.enable")
        try await registry.acquire(.runtime, on: newPage)

        await registry.discardLease(.runtime, on: oldPage)
        try await registry.acquire(.runtime, on: newPage)

        let commands = runtime.wire.observations.commands
        #expect(commands.map(\.method) == [
            "Runtime.enable",
            "Runtime.enable",
        ])
    }
}

@MainActor
@Test
func networkEventsPopulateAllRequestsInOrder() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let requestID = Network.Request.ID("request-1")

        try await runtime.wire.emitRaw(
            .requestWillBeSent(
                id: requestID,
                request: Network.Request(
                    id: requestID,
                    url: "https://example.com/data.json",
                    method: "GET",
                    headers: ["Accept": "application/json"]
                ),
                resourceType: .fetch,
                redirectResponse: nil,
                timestamp: 1
            ),
            target: target
        )
        try await runtime.wire.emitRaw(
            .responseReceived(
                id: requestID,
                response: Network.Response(
                    url: "https://cdn.example.com/data.json",
                    status: 200,
                    statusText: "OK",
                    mimeType: "application/json",
                    headers: ["Content-Type": "application/json"],
                    source: Network.Source(rawValue: "network")
                ),
                resourceType: .fetch,
                timestamp: 2
            ),
            target: target
        )
        try await runtime.wire.emitRaw(
            .dataReceived(id: requestID, dataLength: 12, encodedDataLength: 5, timestamp: 3),
            target: target
        )
        try await runtime.wire.emitRaw(
            .loadingFinished(id: requestID, timestamp: 4, sourceMapURL: nil, metrics: nil),
            target: target
        )

        let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        try await waitUntil {
            results.items.count == 1 && results.items.first?.state == .finished
        }
        let request = try #require(results.items.first)
        #expect(request.url == "https://example.com/data.json")
        #expect(request.method == "GET")
        #expect(request.resourceType == .fetch)
        #expect(request.status == 200)
        #expect(request.statusText == "OK")
        #expect(request.responseURL == "https://cdn.example.com/data.json")
        #expect(request.mimeType == "application/json")
        #expect(request.responseSource == "network")
        #expect(request.hasResponse)
        #expect(request.hasResponseBody)
        #expect(request.requestHeaders["Accept"] == "application/json")
        #expect(request.responseHeaders["Content-Type"] == "application/json")
        #expect(request.requestSentTimestamp == 1)
        #expect(request.responseReceivedTimestamp == 2)
        #expect(request.lastDataReceivedTimestamp == 3)
        #expect(request.finishedOrFailedTimestamp == 4)
        #expect(request.decodedDataLength == 12)
        #expect(request.encodedDataLength == 5)
        #expect(context.registeredRequest(for: request.id) === request)
    }
}

@MainActor
@Test
func responseReceivedWithoutRequestWillBeSentCreatesRequest() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let requestID = Network.Request.ID("response-first-request")

        try await runtime.wire.emitRaw(
            .responseReceived(
                id: requestID,
                response: Network.Response(
                    url: "https://example.com/late.css",
                    status: 200,
                    statusText: "OK",
                    mimeType: "text/css",
                    headers: ["Content-Type": "text/css"],
                    source: Network.Source(rawValue: "network"),
                    requestHeaders: ["Accept": "text/css"]
                ),
                resourceType: .stylesheet,
                timestamp: 2
            ),
            target: target
        )
        try await runtime.wire.emitRaw(
            .dataReceived(id: requestID, dataLength: 9, encodedDataLength: 4, timestamp: 3),
            target: target
        )
        try await runtime.wire.emitRaw(
            .loadingFinished(id: requestID, timestamp: 4, sourceMapURL: nil, metrics: nil),
            target: target
        )

        let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        try await waitUntil {
            results.items.first?.state == .finished
        }
        let request = try #require(results.items.first)
        #expect(request.id == NetworkRequest.ID(requestID))
        #expect(request.url == "https://example.com/late.css")
        #expect(request.method == "GET")
        #expect(request.resourceType == .stylesheet)
        #expect(request.status == 200)
        #expect(request.mimeType == "text/css")
        #expect(request.requestSentTimestamp == 2)
        #expect(request.responseReceivedTimestamp == 2)
        #expect(request.lastDataReceivedTimestamp == 3)
        #expect(request.finishedOrFailedTimestamp == 4)
        #expect(request.requestHeaders["Accept"] == "text/css")
        #expect(request.responseHeaders["Content-Type"] == "text/css")
        #expect(request.decodedDataLength == 9)
        #expect(request.encodedDataLength == 4)
    }
}

@MainActor
@Test
func responseReceivedWithoutResourceTypePreservesRequestResourceType() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let requestID = Network.Request.ID("response-type-preserved-request")
    let modelID = NetworkRequest.ID(requestID)

    await context.apply(.requestWillBeSent(
        id: requestID,
        request: Network.Request(id: requestID, url: "https://example.com/image.png", method: "GET"),
        resourceType: .image,
        redirectResponse: nil,
        timestamp: 1
    ))
    await context.apply(.responseReceived(
        id: requestID,
        response: Network.Response(
            url: "https://example.com/image.png",
            status: 200,
            statusText: "OK",
            mimeType: "image/png"
        ),
        resourceType: nil,
        timestamp: 2
    ))

    let request = try #require(context.registeredRequest(for: modelID))
    #expect(request.resourceType == .image)
    #expect(request.responseReceivedTimestamp == 2)
}

@MainActor
@Test
func loadingFinishedStoresTerminalMetadataAndOverridesDataTotals() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let requestID = Network.Request.ID("request-with-terminal-metadata")

        try await runtime.wire.emitRaw(
            .requestWillBeSent(
                id: requestID,
                request: Network.Request(id: requestID, url: "https://example.com/app.js", method: "GET"),
                resourceType: .script,
                redirectResponse: nil,
                timestamp: 1
            ),
            target: target
        )
        try await runtime.wire.emitRaw(
            .dataReceived(id: requestID, dataLength: 5, encodedDataLength: 2, timestamp: 2),
            target: target
        )
        try await runtime.wire.emitRaw(
            .loadingFinished(
                id: requestID,
                timestamp: 3,
                sourceMapURL: "app.js.map",
                metrics: Network.Metrics(
                    networkProtocol: "h3",
                    remoteAddress: "203.0.113.20:443",
                    encodedDataLength: 9,
                    decodedBodyLength: 12
                )
            ),
            target: target
        )

        let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        try await waitUntil {
            results.items.first?.state == .finished
        }
        let request = try #require(results.items.first)
        #expect(request.sourceMapURL == "app.js.map")
        #expect(request.metrics?.networkProtocol == "h3")
        #expect(request.metrics?.remoteAddress == "203.0.113.20:443")
        #expect(request.metrics?.encodedDataLength == 9)
        #expect(request.metrics?.decodedBodyLength == 12)
        #expect(request.lastDataReceivedTimestamp == 2)
        #expect(request.finishedOrFailedTimestamp == 3)
        #expect(request.decodedDataLength == 12)
        #expect(request.encodedDataLength == 9)
    }
}

@MainActor
@Test
func loadingFinishedClampsNegativeMetricTotals() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let requestID = Network.Request.ID("request-with-negative-terminal-metrics")

        try await runtime.wire.emitRaw(
            .requestWillBeSent(
                id: requestID,
                request: Network.Request(id: requestID, url: "https://example.com/negative", method: "GET"),
                resourceType: .fetch,
                redirectResponse: nil,
                timestamp: 1
            ),
            target: target
        )
        try await runtime.wire.emitRaw(
            .dataReceived(id: requestID, dataLength: 5, encodedDataLength: 4, timestamp: 2),
            target: target
        )
        try await runtime.wire.emitRaw(
            .loadingFinished(
                id: requestID,
                timestamp: 3,
                sourceMapURL: nil,
                metrics: Network.Metrics(encodedDataLength: -8, decodedBodyLength: -13)
            ),
            target: target
        )

        let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        try await waitUntil {
            results.items.first?.state == .finished
        }
        let request = try #require(results.items.first)
        #expect(request.metrics?.encodedDataLength == -8)
        #expect(request.metrics?.decodedBodyLength == -13)
        #expect(request.decodedDataLength == 0)
        #expect(request.encodedDataLength == 0)
    }
}

@MainActor
@Test
func repeatedRequestWillBeSentClearsStaleResponseFields() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let requestID = Network.Request.ID("redirected-request")

        try await runtime.wire.emitRaw(
            .requestWillBeSent(
                id: requestID,
                request: Network.Request(id: requestID, url: "https://example.com/redirect", method: "GET"),
                resourceType: .document,
                redirectResponse: nil,
                timestamp: 1
            ),
            target: target
        )
        try await runtime.wire.emitRaw(
            .responseReceived(
                id: requestID,
                response: Network.Response(
                    url: "https://example.com/redirect",
                    status: 302,
                    statusText: "Found",
                    mimeType: "text/html",
                    headers: ["Location": "https://example.com/final"],
                    source: Network.Source(rawValue: "network")
                ),
                resourceType: .document,
                timestamp: 2
            ),
            target: target
        )

        let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        try await waitUntil {
            results.items.first?.status == 302
        }

        try await runtime.wire.emitRaw(
            .requestWillBeSent(
                id: requestID,
                request: Network.Request(id: requestID, url: "https://example.com/final", method: "GET"),
                resourceType: .document,
                redirectResponse: Network.Response(status: 302),
                timestamp: 3
            ),
            target: target
        )

        let request = try #require(results.items.first)
        try await waitUntil {
            request.url == "https://example.com/final" && request.state == .pending
        }
        #expect(request.status == nil)
        #expect(request.statusText == nil)
        #expect(request.responseURL == nil)
        #expect(request.mimeType == nil)
        #expect(request.responseSource == nil)
        #expect(request.responseHeaders.isEmpty)
        #expect(request.requestSentTimestamp == 3)
        #expect(request.responseReceivedTimestamp == nil)
        #expect(request.lastDataReceivedTimestamp == nil)
        #expect(request.finishedOrFailedTimestamp == nil)
        #expect(request.decodedDataLength == 0)
        #expect(request.encodedDataLength == 0)
        #expect(request.responseBody.phase == .available)
        #expect(request.responseBody.text == nil)
        #expect(request.redirects.count == 1)
        #expect(request.redirects.first?.request.url == "https://example.com/redirect")
        #expect(request.redirects.first?.response.status == 302)
        #expect(request.redirects.first?.timestamp == 3)
    }
}

@MainActor
@Test
func completedRequestDoesNotTreatLaterRequestWillBeSentAsRedirect() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let requestID = Network.Request.ID("reused-request")

        try await runtime.wire.emitRaw(
            .requestWillBeSent(
                id: requestID,
                request: Network.Request(id: requestID, url: "https://example.com/first", method: "GET"),
                resourceType: .document,
                redirectResponse: nil,
                timestamp: 1
            ),
            target: target
        )
        try await runtime.wire.emitRaw(
            .loadingFinished(
                id: requestID,
                timestamp: 2,
                sourceMapURL: "first.map",
                metrics: Network.Metrics(encodedDataLength: 20, decodedBodyLength: 40)
            ),
            target: target
        )

        let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        try await waitUntil { results.items.first?.state == .finished }
        let request = try #require(results.items.first)

        try await runtime.wire.emitRaw(
            .requestWillBeSent(
                id: requestID,
                request: Network.Request(id: requestID, url: "https://example.com/second", method: "GET"),
                resourceType: .document,
                redirectResponse: Network.Response(status: 302),
                timestamp: 3
            ),
            target: target
        )

        try await waitUntil {
            request.url == "https://example.com/second" && request.state == .pending
        }
        #expect(results.items.first === request)
        #expect(request.redirects.isEmpty)
        #expect(request.requestSentTimestamp == 3)
        #expect(request.finishedOrFailedTimestamp == nil)
        #expect(request.sourceMapURL == nil)
        #expect(request.metrics == nil)
    }
}

@MainActor
@Test
func loadingFailedStoresFailureTimestampAndClampsDataLength() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let requestID = Network.Request.ID("failed-request")

        try await runtime.wire.emitRaw(
            .requestWillBeSent(
                id: requestID,
                request: Network.Request(id: requestID, url: "https://example.com/fail", method: "GET"),
                resourceType: .fetch,
                redirectResponse: nil,
                timestamp: 1
            ),
            target: target
        )
        try await runtime.wire.emitRaw(
            .dataReceived(id: requestID, dataLength: -10, encodedDataLength: -20, timestamp: 2),
            target: target
        )
        try await runtime.wire.emitRaw(
            .loadingFailed(id: requestID, errorText: "cancelled", canceled: true, timestamp: 3),
            target: target
        )

        let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        try await waitUntil { results.items.first?.state == .failed(errorText: "cancelled", canceled: true) }
        let request = try #require(results.items.first)
        #expect(request.requestSentTimestamp == 1)
        #expect(request.lastDataReceivedTimestamp == 2)
        #expect(request.finishedOrFailedTimestamp == 3)
        #expect(request.decodedDataLength == 0)
        #expect(request.encodedDataLength == 0)
    }
}

@MainActor
@Test
func memoryCacheEventCreatesFinishedCachedRequestFromResponse() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let requestID = Network.Request.ID("cached-request")

        try await runtime.wire.emitRaw(
            .requestServedFromMemoryCache(
                id: requestID,
                response: Network.Response(
                    url: "https://example.com/cached.css",
                    status: 200,
                    statusText: "OK",
                    mimeType: "text/css",
                    headers: ["Content-Type": "text/css"],
                    source: Network.Source(rawValue: "memory-cache"),
                    requestHeaders: ["Accept": "text/css"],
                    bodySize: 2048
                ),
                resourceType: .stylesheet,
                timestamp: 5
            ),
            target: target
        )

        let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        try await waitUntil {
            results.items.count == 1 && results.items.first?.state == .finished
        }
        let request = try #require(results.items.first)
        #expect(request.url == "https://example.com/cached.css")
        #expect(request.method == "GET")
        #expect(request.resourceType == .stylesheet)
        #expect(request.status == 200)
        #expect(request.statusText == "OK")
        #expect(request.responseURL == "https://example.com/cached.css")
        #expect(request.mimeType == "text/css")
        #expect(request.responseSource == "memory-cache")
        #expect(request.requestHeaders["Accept"] == "text/css")
        #expect(request.responseHeaders["Content-Type"] == "text/css")
        #expect(request.requestSentTimestamp == 5)
        #expect(request.responseReceivedTimestamp == 5)
        #expect(request.lastDataReceivedTimestamp == nil)
        #expect(request.finishedOrFailedTimestamp == 5)
        #expect(request.decodedDataLength == 2048)
        #expect(request.encodedDataLength == 2048)
        #expect(request.responseBody.phase == .available)
        #expect(context.registeredRequest(for: request.id) === request)
    }
}

@MainActor
@Test
func memoryCacheEventWithoutURLForNewRequestIsSkipped() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)

        await #expect(throws: RawWireFixtureError.missingRequiredField(
            method: "Network.requestServedFromMemoryCache",
            field: "resource.url"
        )) {
            try await runtime.wire.emitRaw(
                .requestServedFromMemoryCache(
                    id: Network.Request.ID("cached-request-without-url"),
                    response: Network.Response(status: 200),
                    resourceType: nil,
                    timestamp: 5
                ),
                target: target
            )
        }
        try await runtime.wire.emitRaw(
            .requestServedFromMemoryCache(
                id: Network.Request.ID("cached-request-with-url"),
                response: Network.Response(url: "https://example.com/cached.css", status: 200),
                resourceType: nil,
                timestamp: 6
            ),
            target: target
        )

        let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        try await waitUntil { results.items.count == 1 }
        #expect(results.items.first?.url == "https://example.com/cached.css")
        #expect(context.state == .attached)
    }
}

@MainActor
@Test
func webSocketCreatedCreatesRequestWithConnectingState() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let requestID = Network.Request.ID("websocket-created")

        try await runtime.wire.emitRaw(
            .webSocket(.created(id: requestID, url: "wss://example.com/socket")),
            target: target
        )

        let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        try await waitUntil { results.items.count == 1 }
        let request = try #require(results.items.first)
        #expect(request.url == "wss://example.com/socket")
        #expect(request.method == "GET")
        #expect(request.resourceType == .webSocket)
        #expect(request.state == .pending)
        #expect(request.requestSentTimestamp == nil)
        #expect(request.webSocket?.readyState == .connecting)
        #expect(request.hasResponse == false)
        #expect(request.hasResponseBody == false)
        #expect(context.registeredRequest(for: request.id) === request)
    }
}

@MainActor
@Test
func webSocketCreatedPreservesExistingNetworkLifecycleMetadata() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let requestID = Network.Request.ID("websocket-created-after-request")

        try await runtime.wire.emitRaw(
            .requestWillBeSent(
                id: requestID,
                request: Network.Request(
                    id: requestID,
                    url: "wss://example.com/socket",
                    method: "GET",
                    headers: ["Upgrade": "websocket"]
                ),
                resourceType: .webSocket,
                redirectResponse: nil,
                timestamp: 1
            ),
            target: target
        )
        try await runtime.wire.emitRaw(
            .responseReceived(
                id: requestID,
                response: Network.Response(
                    status: 101,
                    statusText: "Switching Protocols",
                    headers: ["Upgrade": "websocket"],
                    requestHeaders: ["Upgrade": "websocket"]
                ),
                resourceType: .webSocket,
                timestamp: 2
            ),
            target: target
        )
        try await runtime.wire.emitRaw(
            .dataReceived(id: requestID, dataLength: 7, encodedDataLength: 3, timestamp: 3),
            target: target
        )

        let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        try await waitUntil { results.items.first?.decodedDataLength == 7 }
        let request = try #require(results.items.first)
        let webSocket = try #require(request.webSocket)

        try await runtime.wire.emitRaw(
            .webSocket(.created(id: requestID, url: "wss://example.com/socket?created")),
            target: target
        )
        try await waitUntil { request.url == "wss://example.com/socket?created" }
        try await runtime.wire.emitRaw(
            .webSocket(.handshakeRequest(
                id: requestID,
                request: Network.Request(
                    id: requestID,
                    url: "",
                    method: "GET",
                    headers: ["Upgrade": "websocket"]
                ),
                timestamp: nil
            )),
            target: target
        )
        try await runtime.wire.emitRaw(
            .webSocket(.handshakeResponse(
                id: requestID,
                response: Network.Response(
                    status: 101,
                    statusText: "Switching Protocols",
                    headers: ["Upgrade": "websocket"],
                    requestHeaders: ["Upgrade": "websocket"]
                ),
                timestamp: nil
            )),
            target: target
        )
        try await waitUntil { request.webSocket?.readyState == .open }

        let currentWebSocket = try #require(request.webSocket)
        #expect(currentWebSocket === webSocket)
        #expect(request.url == "wss://example.com/socket?created")
        #expect(request.method == "GET")
        #expect(request.requestHeaders["Upgrade"] == "websocket")
        #expect(currentWebSocket.handshakeRequest?.url == "wss://example.com/socket?created")
        #expect(request.status == 101)
        #expect(request.responseHeaders["Upgrade"] == "websocket")
        #expect(request.requestSentTimestamp == 1)
        #expect(request.responseReceivedTimestamp == 2)
        #expect(request.lastDataReceivedTimestamp == 3)
        #expect(request.finishedOrFailedTimestamp == nil)
        #expect(request.decodedDataLength == 7)
        #expect(request.encodedDataLength == 3)
        #expect(request.state == .responded)
    }
}

@MainActor
@Test
func webSocketLifecycleStoresHandshakeFramesErrorAndClosedState() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let requestID = Network.Request.ID("websocket-lifecycle")

        try await runtime.wire.emitRaw(
            .webSocket(.created(id: requestID, url: "wss://example.com/socket")),
            target: target
        )
        let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        try await waitUntil { results.items.count == 1 }
        let request = try #require(results.items.first)

        try await runtime.wire.emitRaw(
            .webSocket(.handshakeRequest(
                id: requestID,
                request: Network.Request(
                    id: requestID,
                    url: "wss://example.com/socket",
                    method: "GET",
                    headers: ["Upgrade": "websocket"]
                ),
                timestamp: 1
            )),
            target: target
        )
        try await waitUntil {
            request.webSocket?.handshakeRequest?.headers["Upgrade"] == "websocket"
        }
        #expect(request.requestHeaders["Upgrade"] == "websocket")
        #expect(request.requestSentTimestamp == 1)
        #expect(request.webSocket?.readyState == .connecting)
        #expect(request.state == .pending)

        try await runtime.wire.emitRaw(
            .webSocket(.handshakeResponse(
                id: requestID,
                response: Network.Response(
                    status: 101,
                    statusText: "Switching Protocols",
                    headers: ["Upgrade": "websocket"],
                    requestHeaders: ["Upgrade": "websocket"]
                ),
                timestamp: 2
            )),
            target: target
        )
        try await waitUntil {
            request.webSocket?.readyState == .open && request.state == .responded
        }
        #expect(request.webSocket?.handshakeResponse?.status == 101)
        #expect(request.status == 101)
        #expect(request.responseHeaders["Upgrade"] == "websocket")
        #expect(request.requestHeaders["Upgrade"] == "websocket")
        #expect(request.responseReceivedTimestamp == 2)
        #expect(request.hasResponse)
        #expect(request.hasResponseBody == false)

        try await runtime.wire.emitRaw(
            .webSocket(.frameSent(
                id: requestID,
                frame: Network.WebSocketFrame(opcode: 1, mask: true, payloadData: "hello", payloadLength: 5),
                timestamp: 3
            )),
            target: target
        )
        try await runtime.wire.emitRaw(
            .webSocket(.frameReceived(
                id: requestID,
                frame: Network.WebSocketFrame(opcode: 1, mask: false, payloadData: "world", payloadLength: 5),
                timestamp: 4
            )),
            target: target
        )
        try await runtime.wire.emitRaw(
            .webSocket(.error(id: requestID, message: "boom", timestamp: 5)),
            target: target
        )
        try await waitUntil { request.webSocket?.frames.count == 3 }
        let webSocket = try #require(request.webSocket)
        #expect(webSocket.frames.map(\.direction) == [.sent, .received, .error("boom")])
        #expect(webSocket.frames[0].opcode == 1)
        #expect(webSocket.frames[0].mask == true)
        #expect(webSocket.frames[0].payloadData == "hello")
        #expect(webSocket.frames[0].payloadLength == 5)
        #expect(webSocket.frames[1].payloadData == "world")
        #expect(webSocket.frames[2].errorMessage == "boom")
        #expect(webSocket.frames.map(\.timestamp) == [3, 4, 5])
        #expect(request.decodedDataLength == 10)
        #expect(request.lastDataReceivedTimestamp == 5)

        try await runtime.wire.emitRaw(
            .webSocket(.closed(id: requestID, timestamp: 6)),
            target: target
        )
        try await waitUntil {
            request.webSocket?.readyState == .closed && request.state == .finished
        }
        #expect(request.finishedOrFailedTimestamp == 6)
    }
}

@MainActor
@Test
func webSocketEventForUnknownRequestIsSkipped() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let requestID = Network.Request.ID("missing-websocket")

        try await runtime.wire.emitRaw(
            .webSocket(.handshakeResponse(
                id: requestID,
                response: Network.Response(status: 101),
                timestamp: 1
            )),
            target: target
        )
        try await runtime.wire.emitRaw(
            .webSocket(.created(id: requestID, url: "wss://example.com/socket")),
            target: target
        )

        let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        try await waitUntil { results.items.count == 1 }
        #expect(results.items.first?.webSocket?.readyState == .connecting)
        #expect(results.items.first?.webSocket?.handshakeResponse == nil)
        #expect(context.state == .attached)
    }
}

@MainActor
@Test
func webSocketOtherEventDoesNotMutateRequests() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()

        let baseline = context.eventPumpAppliedSequenceForTesting
        try await runtime.wire.emitRaw(
            .webSocket(.other(RawEvent(domain: "Network", method: "webSocketFutureEvent"))),
            target: target
        )
        let didProcessOtherEvent = await context.waitForEventPumpAppliedSequenceForTesting(after: baseline)
        #expect(didProcessOtherEvent)

        #expect(results.items.isEmpty)
        #expect(context.state == .attached)
    }
}

@MainActor
@Test
func requestPostDataCreatesNetworkBodyWithFormRepresentation() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let requestID = Network.Request.ID("form-request")

        try await runtime.wire.emitRaw(
            .requestWillBeSent(
                id: requestID,
                request: Network.Request(
                    id: requestID,
                    url: "https://example.com/form",
                    method: "POST",
                    headers: ["Content-Type": " application/x-www-form-urlencoded; charset=utf-8"],
                    postData: "name=Jane+Doe&city=Tokyo%20East"
                ),
                resourceType: .fetch,
                redirectResponse: nil,
                timestamp: 1
            ),
            target: target
        )

        let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        try await waitUntil { results.items.count == 1 }
        let request = try #require(results.items.first)
        let body = try #require(request.requestBody)
        #expect(body.role == .request)
        #expect(body.kind == .form)
        #expect(body.phase == .loaded)
        #expect(body.full == "name=Jane+Doe&city=Tokyo%20East")
        #expect(body.text == "name=Jane+Doe&city=Tokyo%20East")
        #expect(body.size == "name=Jane+Doe&city=Tokyo%20East".utf8.count)
        #expect(body.isBase64Encoded == false)
        #expect(body.isTruncated == false)
        #expect(body.sourceSyntaxKind == .plainText)
        #expect(body.textRepresentation == "name=Jane Doe\ncity=Tokyo East")
        #expect(body.textRepresentationSyntaxKind == .plainText)
        #expect(request.canFetchResponseBody == false)
    }
}

@MainActor
@Test
func responseRequestHeadersRefreshRequestBodyHints() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let requestID = Network.Request.ID("form-request-hints")

        try await runtime.wire.emitRaw(
            .requestWillBeSent(
                id: requestID,
                request: Network.Request(
                    id: requestID,
                    url: "https://example.com/form",
                    method: "POST",
                    postData: "name=Jane+Doe&city=Tokyo%20East"
                ),
                resourceType: .fetch,
                redirectResponse: nil,
                timestamp: 1
            ),
            target: target
        )

        let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        try await waitUntil { results.items.count == 1 }
        let request = try #require(results.items.first)
        let body = try #require(request.requestBody)
        #expect(body.kind == .text)
        #expect(body.textRepresentation == "name=Jane+Doe&city=Tokyo%20East")

        try await runtime.wire.emitRaw(
            .responseReceived(
                id: requestID,
                response: Network.Response(
                    status: 200,
                    headers: ["Content-Type": "text/plain"],
                    requestHeaders: ["Content-Type": "application/x-www-form-urlencoded"]
                ),
                resourceType: .fetch,
                timestamp: 2
            ),
            target: target
        )

        try await waitUntil { body.kind == .form }
        #expect(request.requestHeaders["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(body.textRepresentation == "name=Jane Doe\ncity=Tokyo East")
        #expect(body.textRepresentationSyntaxKind == .plainText)
    }
}

@MainActor
@Test
func responseBodyPublishesHintsAndFetchLifecycle() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let requestID = Network.Request.ID("json-response-body")

        try await runtime.wire.emitRaw(
            .requestWillBeSent(
                id: requestID,
                request: Network.Request(
                    id: requestID,
                    url: "https://example.com/api/data.json",
                    method: "GET"
                ),
                resourceType: .fetch,
                redirectResponse: nil,
                timestamp: 1
            ),
            target: target
        )
        try await runtime.wire.emitRaw(
            .responseReceived(
                id: requestID,
                response: Network.Response(status: 200),
                resourceType: .fetch,
                timestamp: 2
            ),
            target: target
        )

        let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        try await waitUntil { results.items.first?.state == .responded }
        let request = try #require(results.items.first)
        let body = request.responseBody
        #expect(body.role == .response)
        #expect(body.kind == .text)
        #expect(body.phase == .available)
        #expect(body.full == nil)
        #expect(body.sourceSyntaxKind == .json)
        #expect(body.textRepresentation == nil)
        #expect(body.textRepresentationSyntaxKind == .json)
        #expect(request.canFetchResponseBody == false)

        try await runtime.wire.emitRaw(
            .loadingFinished(id: requestID, timestamp: 3, sourceMapURL: nil, metrics: nil),
            target: target
        )
        try await waitUntil { request.canFetchResponseBody }

        await runtime.wire.respond(
            to: "Network.getResponseBody",
            with: try rawNetworkBodyResult(
                Network.Body(data: #"{"ok":true}"#, base64Encoded: false)
            )
        )

        await request.fetchResponseBody()
        #expect(body.phase == .loaded)
        #expect(body.full == #"{"ok":true}"#)
        #expect(body.text == #"{"ok":true}"#)
        #expect(body.size == #"{"ok":true}"#.utf8.count)
        #expect(body.isBase64Encoded == false)
        #expect(body.isTruncated == false)
        #expect(body.textRepresentation == #"{"ok":true}"#)
        #expect(body.textRepresentationSyntaxKind == .json)
        #expect(request.canFetchResponseBody == false)

        let commandsBeforeSecondFetch = runtime.wire.observations.commands
        await request.fetchResponseBody()
        let commandsAfterSecondFetch = runtime.wire.observations.commands
        #expect(commandsAfterSecondFetch == commandsBeforeSecondFetch)
    }
}

@MainActor
@Test
func fetchResponseBodyStoresLoadedAndFailedPhases() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let loadedID = Network.Request.ID("loaded-request")
        let failedID = Network.Request.ID("failed-request")

        try await emitFinishedRequest(id: loadedID, target: target, backend: runtime.wire)
        try await emitFinishedRequest(id: failedID, target: target, backend: runtime.wire)

        let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        try await waitUntil {
            results.items.count == 2 && results.items.allSatisfy { $0.state == .finished }
        }
        let loadedRequest = try #require(results.items.first { $0.id == NetworkRequest.ID(loadedID) })
        let failedRequest = try #require(results.items.first { $0.id == NetworkRequest.ID(failedID) })

        await runtime.wire.respond(
            to: "Network.getResponseBody",
            with: try rawNetworkBodyResult(
                Network.Body(data: "hello", base64Encoded: false)
            )
        )
        await runtime.wire.fail(
            "Network.getResponseBody",
            message: "Response body is unavailable."
        )

        await loadedRequest.fetchResponseBody()
        #expect(loadedRequest.responseBody.phase == .loaded)
        #expect(loadedRequest.responseBody.text == "hello")
        #expect(loadedRequest.responseBody.isBase64Encoded == false)

        await failedRequest.fetchResponseBody()
        guard case let .failed(error) = failedRequest.responseBody.phase else {
            Issue.record("Expected failed response body phase.")
            return
        }
        guard case .commandFailed(domain: "Network", method: "getResponseBody", message: _) = error else {
            Issue.record("Expected Network.getResponseBody command failure, got \(error).")
            return
        }

        let commands = runtime.wire.observations.commands
        #expect(commands.contains { $0.method == "Network.getResponseBody" })
    }
}

@MainActor
@Test
func fetchResponseBodyDropsCompletionAfterNetworkClear() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let requestID = Network.Request.ID("cleared-body-request")
        let gate = await runtime.wire.deferReply(
            to: "Network.getResponseBody",
            with: try rawNetworkBodyResult(
                Network.Body(data: "stale-body", base64Encoded: false)
            )
        )

        try await emitFinishedRequest(id: requestID, target: target, backend: runtime.wire)
        try await waitUntil {
            context.registeredRequest(for: NetworkRequest.ID(requestID))?.state == .finished
        }
        let request = try #require(context.registeredRequest(for: NetworkRequest.ID(requestID)))
        let body = request.responseBody
        let fetchTask = Task {
            await request.fetchResponseBody()
        }
        try await waitUntil {
            runtime.wire.observations.commands.contains { $0.method == "Network.getResponseBody" }
        }

        await context.clearNetworkRequests()
        #expect(context.registeredRequest(for: NetworkRequest.ID(requestID)) == nil)
        gate.open()
        await fetchTask.value

        #expect(body.phase == NetworkBody.Phase.fetching)
        #expect(body.text == nil)
        #expect(request.responseBody === body)
    }
}

@MainActor
@Test
func consoleEventsPopulateRepeatAndClearFetchedMessages() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let requestID = Network.Request.ID("request-1")

        let results: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()
        try await runtime.wire.emitRaw(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "warning"),
                type: Console.Kind(rawValue: "log"),
                text: "hello",
                url: "https://example.com/app.js",
                line: 12,
                column: 4,
                repeatCount: 1,
                networkRequestID: requestID,
                timestamp: 1
            )),
            target: target
        )

        try await waitUntil { results.items.count == 1 }
        let message = try #require(results.items.first)
        #expect(message.source == Console.Source(rawValue: "console-api"))
        #expect(message.level == Console.Level(rawValue: "warning"))
        #expect(message.kind == Console.Kind(rawValue: "log"))
        #expect(message.text == "hello")
        #expect(message.url == "https://example.com/app.js")
        #expect(message.line == 12)
        #expect(message.column == 4)
        #expect(message.repeatCount == 1)
        #expect(message.networkRequestID == NetworkRequest.ID(requestID))
        #expect(message.timestamp == 1)
        #expect(context.registeredMessage(for: message.id) === message)

        try await runtime.wire.emitRaw(
            .messageRepeatCountUpdated(count: 3, timestamp: 2),
            target: target
        )
        try await waitUntil { message.repeatCount == 3 }
        #expect(results.items.first === message)
        #expect(message.timestamp == 2)

        try await runtime.wire.emitRaw(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "javascript"),
                level: Console.Level(rawValue: "error"),
                text: "second"
            )),
            target: target
        )
        try await waitUntil { results.items.count == 2 }
        #expect(results.items.map(\.text) == ["hello", "second"])

        try await runtime.wire.emitRaw(
            .messagesCleared(reason: Console.ClearReason(rawValue: "console-api")),
            target: target
        )
        try await waitUntil { results.items.isEmpty }
        #expect(context.registeredMessage(for: message.id) == nil)
    }
}

@MainActor
@Test
func consoleFetchedResultsHonorDescriptorsForInitialUpdatesAndDescriptorChanges() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let allResults: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()

        try await runtime.wire.emitRaw(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "warning"),
                text: "middle"
            )),
            target: target
        )
        try await runtime.wire.emitRaw(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "javascript"),
                level: Console.Level(rawValue: "error"),
                text: "zeta"
            )),
            target: target
        )
        try await runtime.wire.emitRaw(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "warning"),
                text: "omega"
            )),
            target: target
        )
        try await waitUntil { allResults.items.count == 3 }

        let warningDescriptor = WebInspectorFetchDescriptor<ConsoleMessage>(
            predicate: #Predicate { message in
                message.level.rawValue == "warning"
            },
            sortBy: [SortDescriptor(\.text, order: .reverse)],
            fetchLimit: 2
        )
        let warningResults: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults(for: warningDescriptor)

        #expect(warningResults.items.map(\.text) == ["omega", "middle"])

        try await runtime.wire.emitRaw(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "warning"),
                text: "zebra"
            )),
            target: target
        )
        try await waitUntil {
            warningResults.items.map(\.text) == ["zebra", "omega"]
        }

        warningResults.updateFetchDescriptor(WebInspectorFetchDescriptor<ConsoleMessage>(
            sortBy: [SortDescriptor(\.text)],
            fetchLimit: 2,
            fetchOffset: 1
        ))

        try await waitUntil {
            warningResults.items.map(\.text) == ["omega", "zebra"]
        }
    }
}

@MainActor
@Test
func consoleMessageParametersRegisterRuntimeObjects() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let objectID = Runtime.RemoteObject.ID("console-object")
        let results: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()

        try await runtime.wire.emitRaw(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "log"),
                text: "first",
                parameters: [
                    Runtime.RemoteObject(id: objectID, kind: .object, description: "before")
                ]
            )),
            target: target
        )
        try await waitUntil { results.items.count == 1 }
        let firstMessage = try #require(results.items.first)
        let firstParameter = try #require(firstMessage.parameters.first)
        #expect(firstParameter.description == "before")

        try await runtime.wire.emitRaw(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "log"),
                text: "second",
                parameters: [
                    Runtime.RemoteObject(id: objectID, kind: .object, description: "after")
                ]
            )),
            target: target
        )
        try await waitUntil { results.items.count == 2 }
        let secondMessage = try #require(results.items.last)
        let secondParameter = try #require(secondMessage.parameters.first)

        #expect(firstParameter === secondParameter)
        #expect(firstParameter.description == "after")
    }
}

@MainActor
@Test
func consoleMessagesClearedInvalidatesRuntimeObjectsWithoutRuntimeCommand() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let objectID = Runtime.RemoteObject.ID("console-stale-object")
        let results: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()

        let messageEventBaseline = context.eventPumpAppliedSequenceForTesting
        try await runtime.wire.emitRaw(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "log"),
                text: "clear me",
                parameters: [
                    Runtime.RemoteObject(id: objectID, kind: .object, description: "console object")
                ]
            )),
            target: target
        )
        #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: messageEventBaseline))
        try await waitUntil { results.items.count == 1 }
        let message = try #require(results.items.first)
        let parameter = try #require(message.parameters.first)

        let commandCountBeforeClear = runtime.wire.observations.commands.count
        let eventBaseline = context.eventPumpAppliedSequenceForTesting
        try await runtime.wire.emitRaw(
            .messagesCleared(reason: Console.ClearReason(rawValue: "console-api")),
            target: target
        )

        #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: eventBaseline))
        try await waitUntil { results.items.isEmpty }
        do {
            _ = try await parameter.properties()
            Issue.record("Expected cleared console RuntimeObject to be stale.")
        } catch let error as WebInspectorProxyError {
            #expect(error == .disconnected("RuntimeObject is not registered in this WebInspectorContext."))
        }
        let clearCommands = runtime.wire.observations.commands.dropFirst(commandCountBeforeClear)
        #expect(!clearCommands.contains { $0.method == "Runtime.releaseObjectGroup" })
        #expect(context.state == .attached)
    }
}

@MainActor
@Test
func evaluateRegistersRuntimeObjectInSelectedContext() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let contextID = Runtime.ExecutionContext.ID("main")
        let objectID = Runtime.RemoteObject.ID("evaluation-result")

        try await runtime.wire.emitRaw(
            .executionContextCreated(Runtime.ExecutionContext(
                id: contextID,
                name: "Main",
                kind: .normal
            )),
            target: target
        )
        try await waitUntil { context.executionContexts.count == 1 }
        let runtimeContext = try #require(context.executionContexts.first)
        context.selectContext(runtimeContext)

        await runtime.wire.respond(
            to: "Runtime.evaluate",
            with: try rawRuntimeEvaluationResult(Runtime.EvaluationResult(
                object: Runtime.RemoteObject(
                    id: objectID,
                    kind: .string,
                    description: "hello",
                    value: .string("hello")
                ),
                wasThrown: true,
                savedResultIndex: 7
            ))
        )

        let result = try await context.evaluate("throw 'hello'", in: runtimeContext)
        #expect(result.isException)
        #expect(result.object.kind == .string)
        #expect(result.object.value == .string("hello"))
        #expect(result.object.description == "hello")

        let commands = runtime.wire.observations.commands
        let command = try #require(commands.last { $0.method == "Runtime.evaluate" })
        #expect(try commandStringParameter(command, "expression") == "throw 'hello'")
        #expect(try commandStringParameter(command, "contextId") == contextID.unscopedRawValue)
    }
}

@MainActor
@Test
func runtimeObjectPropertiesAndCollectionEntriesUseRuntimeCommands() async throws {
    try await withDataKitTestRuntime { runtime in
        let (_, context) = try await startContext(runtime: runtime)
        let objectID = Runtime.RemoteObject.ID("root-object")
        let childID = Runtime.RemoteObject.ID("child-object")
        let entryValueID = Runtime.RemoteObject.ID("entry-value")

        await runtime.wire.respond(
            to: "Runtime.evaluate",
            with: try rawRuntimeEvaluationResult(Runtime.EvaluationResult(
                object: Runtime.RemoteObject(id: objectID, kind: .object, description: "root")
            ))
        )
        let evaluation = try await context.evaluate("window")

        await runtime.wire.respond(
            to: "Runtime.getProperties",
            with: try rawRuntimePropertiesResult([
                Runtime.PropertyDescriptor(
                    name: "answer",
                    value: Runtime.RemoteObject(id: nil, kind: .number, description: "42", value: .number(42))
                ),
                Runtime.PropertyDescriptor(
                    name: "child",
                    value: Runtime.RemoteObject(id: childID, kind: .object, description: "child")
                ),
            ])
        )

        let properties = try await evaluation.object.properties()
        #expect(properties.count == 2)
        #expect(properties[0].name == "answer")
        #expect(properties[0].value == "42")
        #expect(properties[0].object == nil)
        let child = try #require(properties[1].object)
        #expect(child.description == "child")

        await runtime.wire.respond(
            to: "Runtime.getCollectionEntries",
            with: try rawRuntimeCollectionEntriesResult([
                Runtime.CollectionEntry(
                    key: Runtime.RemoteObject(id: nil, kind: .string, description: "key", value: .string("key")),
                    value: Runtime.RemoteObject(id: entryValueID, kind: .object, description: "entry value")
                )
            ])
        )

        let entries = try await evaluation.object.collectionEntries()
        #expect(entries.count == 1)
        #expect(entries[0].key?.value == .string("key"))
        #expect(entries[0].value?.description == "entry value")

        let commands = runtime.wire.observations.commands
        #expect(commands.contains { $0.method == "Runtime.getProperties" })
        #expect(commands.contains { $0.method == "Runtime.getCollectionEntries" })
    }
}

@MainActor
@Test
func staleRuntimeObjectThrowsWithoutFailingContext() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let contextID = Runtime.ExecutionContext.ID("main")
        let objectID = Runtime.RemoteObject.ID("stale-object")

        try await runtime.wire.emitRaw(
            .executionContextCreated(Runtime.ExecutionContext(
                id: contextID,
                name: "Main",
                kind: .normal
            )),
            target: target
        )
        try await waitUntil { context.executionContexts.count == 1 }

        await runtime.wire.respond(
            to: "Runtime.evaluate",
            with: try rawRuntimeEvaluationResult(Runtime.EvaluationResult(
                object: Runtime.RemoteObject(id: objectID, kind: .object, description: "stale")
            ))
        )
        let evaluation = try await context.evaluate("window")

        try await runtime.wire.emitRaw(.executionContextsCleared(target: target.id), target: target)
        try await waitUntil {
            context.executionContexts.isEmpty && context.selectedContext == nil
        }

        do {
            _ = try await evaluation.object.properties()
            Issue.record("Expected stale runtime object to throw.")
        } catch let error as WebInspectorProxyError {
            #expect(error == .disconnected("RuntimeObject is not registered in this WebInspectorContext."))
        }
        #expect(context.state == .attached)
    }
}

@MainActor
@Test
func runtimeEvaluationRejectsReplyAfterRuntimeClearWithoutKnownContexts() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        #expect(context.executionContexts.isEmpty)
        let gate = await runtime.wire.deferReply(
            to: "Runtime.evaluate",
            with: try rawRuntimeEvaluationResult(Runtime.EvaluationResult(
                object: Runtime.RemoteObject(
                    id: Runtime.RemoteObject.ID("stale-evaluation-reply"),
                    kind: .object
                )
            ))
        )

        let evaluationTask = Task { @MainActor () -> WebInspectorProxyError? in
            do {
                _ = try await context.evaluate("window")
                return nil
            } catch let error as WebInspectorProxyError {
                return error
            } catch {
                Issue.record("Unexpected evaluation error: \(error)")
                return nil
            }
        }
        _ = await runtime.wire.observations.waitForCommands(method: "Runtime.evaluate", count: 1)
        let eventBaseline = context.eventPumpAppliedSequenceForTesting
        try await runtime.wire.emitRaw(.executionContextsCleared(target: target.id), target: target)
        #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: eventBaseline))
        gate.open()

        #expect(await evaluationTask.value == .disconnected(
            "Runtime evaluation target is no longer current in this WebInspectorContext."
        ))
        #expect(context.state == .attached)
    }
}

@MainActor
@Test
func runtimePropertiesRejectReplyAfterObjectClear() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let contextID = Runtime.ExecutionContext.ID("properties-race")
        try await runtime.wire.emitRaw(
            .executionContextCreated(Runtime.ExecutionContext(
                id: contextID,
                name: "Properties race",
                kind: .normal
            )),
            target: target
        )
        try await waitUntil { context.executionContexts.count == 1 }
        await runtime.wire.respond(
            to: "Runtime.evaluate",
            with: try rawRuntimeEvaluationResult(Runtime.EvaluationResult(
                object: Runtime.RemoteObject(
                    id: Runtime.RemoteObject.ID("properties-root"),
                    kind: .object
                )
            ))
        )
        let root = try await context.evaluate("window").object
        let gate = await runtime.wire.deferReply(
            to: "Runtime.getProperties",
            with: try rawRuntimePropertiesResult([
                Runtime.PropertyDescriptor(
                    name: "child",
                    value: Runtime.RemoteObject(
                        id: Runtime.RemoteObject.ID("stale-property-child"),
                        kind: .object
                    )
                )
            ])
        )

        let propertiesTask = Task { @MainActor () -> WebInspectorProxyError? in
            do {
                _ = try await root.properties()
                return nil
            } catch let error as WebInspectorProxyError {
                return error
            } catch {
                Issue.record("Unexpected Runtime.getProperties error: \(error)")
                return nil
            }
        }
        _ = await runtime.wire.observations.waitForCommands(method: "Runtime.getProperties", count: 1)
        let eventBaseline = context.eventPumpAppliedSequenceForTesting
        try await runtime.wire.emitRaw(.executionContextsCleared(target: target.id), target: target)
        #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: eventBaseline))
        gate.open()

        #expect(await propertiesTask.value == .disconnected(
            "RuntimeObject is not registered in this WebInspectorContext."
        ))
        #expect(context.state == .attached)
    }
}

@MainActor
@Test
func runtimeCollectionEntriesRejectReplyAfterObjectClear() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let contextID = Runtime.ExecutionContext.ID("entries-race")
        try await runtime.wire.emitRaw(
            .executionContextCreated(Runtime.ExecutionContext(
                id: contextID,
                name: "Entries race",
                kind: .normal
            )),
            target: target
        )
        try await waitUntil { context.executionContexts.count == 1 }
        await runtime.wire.respond(
            to: "Runtime.evaluate",
            with: try rawRuntimeEvaluationResult(Runtime.EvaluationResult(
                object: Runtime.RemoteObject(
                    id: Runtime.RemoteObject.ID("entries-root"),
                    kind: .object
                )
            ))
        )
        let root = try await context.evaluate("new Map()").object
        let gate = await runtime.wire.deferReply(
            to: "Runtime.getCollectionEntries",
            with: try rawRuntimeCollectionEntriesResult([
                Runtime.CollectionEntry(
                    value: Runtime.RemoteObject(
                        id: Runtime.RemoteObject.ID("stale-entry-value"),
                        kind: .object
                    )
                )
            ])
        )

        let entriesTask = Task { @MainActor () -> WebInspectorProxyError? in
            do {
                _ = try await root.collectionEntries()
                return nil
            } catch let error as WebInspectorProxyError {
                return error
            } catch {
                Issue.record("Unexpected Runtime.getCollectionEntries error: \(error)")
                return nil
            }
        }
        _ = await runtime.wire.observations.waitForCommands(method: "Runtime.getCollectionEntries", count: 1)
        let eventBaseline = context.eventPumpAppliedSequenceForTesting
        try await runtime.wire.emitRaw(.executionContextsCleared(target: target.id), target: target)
        #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: eventBaseline))
        gate.open()

        #expect(await entriesTask.value == .disconnected(
            "RuntimeObject is not registered in this WebInspectorContext."
        ))
        #expect(context.state == .attached)
    }
}

@MainActor
@Test
func runtimeEventsPopulateContextsAndFallbackSelection() async throws {
    try await withDataKitTestRuntime { runtime in
        let (target, context) = try await startContext(runtime: runtime)
        let mainID = Runtime.ExecutionContext.ID("main")
        let utilityID = Runtime.ExecutionContext.ID("utility")

        try await runtime.wire.emitRaw(
            .executionContextCreated(Runtime.ExecutionContext(
                id: mainID,
                name: "Main",
                kind: .normal
            )),
            target: target
        )
        try await waitUntil { context.executionContexts.count == 1 }
        let mainContext = try #require(context.executionContexts.first)
        #expect(context.selectedContext === mainContext)
        #expect(mainContext.name == "Main")
        #expect(mainContext.kind == .normal)

        try await runtime.wire.emitRaw(
            .executionContextCreated(Runtime.ExecutionContext(
                id: mainID,
                name: "Main Updated",
                kind: .normal
            )),
            target: target
        )
        try await waitUntil { mainContext.name == "Main Updated" }
        #expect(context.executionContexts.first === mainContext)

        try await runtime.wire.emitRaw(
            .executionContextCreated(Runtime.ExecutionContext(
                id: utilityID,
                name: "Utility",
                kind: .user
            )),
            target: target
        )
        try await waitUntil { context.executionContexts.count == 2 }
        let utilityContext = try #require(context.executionContexts.first { $0.id == RuntimeContext.ID(utilityID) })
        #expect(context.selectedContext === mainContext)

        context.selectContext(utilityContext)
        #expect(context.selectedContext === utilityContext)

        try await runtime.wire.emitRaw(
            .executionContextDestroyed(utilityID),
            target: target
        )
        try await waitUntil {
            context.executionContexts.count == 1 && context.selectedContext === mainContext
        }
        #expect(context.executionContexts.first === mainContext)

        try await runtime.wire.emitRaw(
            .executionContextsCleared(target: target.id),
            target: target
        )
        try await waitUntil {
            context.executionContexts.isEmpty && context.selectedContext == nil
        }
    }
}

@MainActor
@Test
func dataKitTestRuntimeScopeQuiescesPendingWorkAndReleasesOwners() async throws {
    weak var weakWire: DataKitRawWireDriver?
    weak var weakPeer: WebInspectorTestPeer?
    weak var weakProxy: WebInspectorProxy?
    var observations: DataKitRawWireDriver.Observations?
    var observationWaiter: Task<[WebInspectorTestPeer.Command], Never>?
    var pendingReply: Task<Void, any Error>?

    try await withDataKitTestRuntime { runtime in
        weakWire = runtime.wire
        weakPeer = runtime.peer
        weakProxy = runtime.proxy

        let runtimeObservations = runtime.wire.observations
        observations = runtimeObservations
        observationWaiter = Task {
            await runtimeObservations.waitForCommands(
                method: "Test.neverReceived",
                count: 1
            )
        }
        try await waitUntil {
            runtimeObservations.pendingWaiterCountForTesting == 1
        }

        _ = await runtime.wire.deferReply(to: "Page.reload")
        let page = runtime.page
        pendingReply = Task {
            try await page.page.reload()
        }
        _ = await runtimeObservations.waitForCommands(method: "Page.reload", count: 1)
    }

    let finishedObservationWaiter = try #require(observationWaiter)
    #expect(await finishedObservationWaiter.value.isEmpty)
    #expect(observations?.pendingWaiterCountForTesting == 0)

    let finishedReply = try #require(pendingReply)
    await #expect(throws: WebInspectorProxyError.closed) {
        try await finishedReply.value
    }

    #expect(weakWire == nil)
    #expect(weakPeer == nil)
    #expect(weakProxy == nil)
}

@MainActor
private func startContext(
    runtime: DataKitTestRuntime,
    document: DOM.Node = DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document")
) async throws -> (WebInspectorTarget, WebInspectorContext) {
    let target = try await runtime.proxy.waitForCurrentPage()
    try await enqueueStartupReplies(on: runtime.wire, document: document)

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitForStartupSubscribers(runtime: runtime, target: target)
    try await waitUntil { context.state == .attached }
    return (target, context)
}

private var startupCommands: [String] {
    [
        "Inspector.enable",
        "Inspector.initialized",
        "Runtime.enable",
        "Network.enable",
        "DOM.getDocument",
        "Console.enable",
    ]
}

private var shutdownCommands: [String] {
    [
        "Console.disable",
        "Runtime.disable",
        "Network.disable",
        "Inspector.disable",
    ]
}

private func enqueueStartupReplies(
    on backend: DataKitRawWireDriver,
    document: DOM.Node = DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document")
) async throws {
    await enqueueDomainEnableReplies(on: backend)
    await backend.respond(
        to: "DOM.getDocument",
        with: try domDocumentResult(document)
    )
}

private func enqueueDomainEnableReplies(on backend: DataKitRawWireDriver) async {
    await backend.respond(to: "Inspector.enable")
    await backend.respond(to: "Inspector.initialized")
    await backend.respond(to: "Runtime.enable")
    await backend.respond(to: "Network.enable")
    await backend.respond(to: "Console.enable")
}

private func enqueueDomainDisableReplies(on backend: DataKitRawWireDriver) async {
    await backend.respond(to: "Console.disable")
    await backend.respond(to: "Runtime.disable")
    await backend.respond(to: "Network.disable")
    await backend.respond(to: "Inspector.disable")
}

private func enqueueCSSStyleReplies(on backend: DataKitRawWireDriver) async throws {
    await backend.respond(
        to: "CSS.getMatchedStylesForNode",
        with: try testJSONObject(
            #"{"matchedCSSRules":[{"rule":{"selectorList":{"selectors":[{"text":".card"}],"text":".card"},"origin":"regular","style":{"styleId":{"styleSheetId":"style-1","ordinal":0},"cssProperties":[{"name":"display","value":"grid","text":"display: grid;"}],"cssText":"display: grid;"}}}]}"#
        )
    )
    await backend.respond(
        to: "CSS.getInlineStylesForNode",
        with: try testJSONObject("{}")
    )
    await backend.respond(
        to: "CSS.getComputedStyleForNode",
        with: try testJSONObject(
            #"{"computedStyle":[{"name":"display","value":"grid"}]}"#
        )
    )
}

private func matchedStylesCommandCount(on backend: DataKitRawWireDriver) -> Int {
    backend.observations.commands
        .filter { $0.method == "CSS.getMatchedStylesForNode" }
        .count
}

@MainActor
private func waitForStartupSubscribers(
    runtime: DataKitTestRuntime,
    target: WebInspectorTarget
) async throws {
    _ = runtime
    await target.waitForModelEventSubscriptions()
}

private func emitFinishedRequest(
    id: Network.Request.ID,
    target: WebInspectorTarget,
    backend: DataKitRawWireDriver
) async throws {
    let targetID = target.pageBindingID ?? "page-main"
    try await backend.emitTargetEvent(
        targetID: targetID,
        method: "Network.requestWillBeSent",
        parameters: try testJSONObject(
            """
            {"requestId":"\(id.rawValue)","request":{"url":"https://example.com/\(id.rawValue)","method":"GET","headers":{}},"type":"Fetch","timestamp":1}
            """
        )
    )
    try await backend.emitTargetEvent(
        targetID: targetID,
        method: "Network.responseReceived",
        parameters: try testJSONObject(
            """
            {"requestId":"\(id.rawValue)","response":{"status":200,"mimeType":"text/plain"},"type":"Fetch","timestamp":2}
            """
        )
    )
    try await backend.emitTargetEvent(
        targetID: targetID,
        method: "Network.loadingFinished",
        parameters: try testJSONObject(
            """
            {"requestId":"\(id.rawValue)","timestamp":3}
            """
        )
    )
}

@MainActor
private func startTransportBackedContext(
    targetID: ProtocolTarget.ID,
    documentID: String
) async throws -> (FakeTransportBackend, TransportSession, WebInspectorContext) {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installTransportPageTarget(in: transport, targetID: targetID)
    let proxy = try await WebInspectorProxy(transport: transport)
    let container = WebInspectorContainer(proxy: proxy)
    let context = container.mainContext

    try await replyTransportInspectorInitialization(backend, transport: transport, targetID: targetID)

    let runtimeEnable = try await waitForTransportTargetMessage(backend, method: "Runtime.enable")
    #expect(runtimeEnable.targetIdentifier == targetID)
    await receiveTransportTargetReply(
        transport,
        targetID: runtimeEnable.targetIdentifier,
        messageID: try transportMessageID(runtimeEnable.message),
        result: "{}"
    )

    let networkEnable = try await waitForTransportTargetMessage(backend, method: "Network.enable")
    #expect(networkEnable.targetIdentifier == targetID)
    await receiveTransportTargetReply(
        transport,
        targetID: networkEnable.targetIdentifier,
        messageID: try transportMessageID(networkEnable.message),
        result: "{}"
    )

    let getDocument = try await waitForTransportTargetMessage(backend, method: "DOM.getDocument")
    #expect(getDocument.targetIdentifier == targetID)
    await receiveTransportTargetReply(
        transport,
        targetID: getDocument.targetIdentifier,
        messageID: try transportMessageID(getDocument.message),
        result: transportDocumentResult(nodeID: documentID)
    )

    let consoleEnable = try await waitForTransportTargetMessage(backend, method: "Console.enable")
    #expect(consoleEnable.targetIdentifier == targetID)
    await receiveTransportTargetReply(
        transport,
        targetID: consoleEnable.targetIdentifier,
        messageID: try transportMessageID(consoleEnable.message),
        result: "{}"
    )

    try await waitUntil { context.state == .attached }
    return (backend, transport, context)
}

@discardableResult
private func replyTransportInspectorInitialization(
    _ backend: FakeTransportBackend,
    transport: TransportSession,
    targetID: ProtocolTarget.ID,
    after count: Int = 0,
    timeout: Duration = .seconds(1)
) async throws -> (enable: SentTargetMessage, initialized: SentTargetMessage) {
    let inspectorEnable = try await waitForTransportTargetMessage(
        backend,
        method: "Inspector.enable",
        after: count,
        timeout: timeout
    )
    #expect(inspectorEnable.targetIdentifier == targetID)
    await receiveTransportTargetReply(
        transport,
        targetID: inspectorEnable.targetIdentifier,
        messageID: try transportMessageID(inspectorEnable.message),
        result: "{}"
    )

    let inspectorInitialized = try await waitForTransportTargetMessage(
        backend,
        method: "Inspector.initialized",
        after: count,
        timeout: timeout
    )
    #expect(inspectorInitialized.targetIdentifier == targetID)
    await receiveTransportTargetReply(
        transport,
        targetID: inspectorInitialized.targetIdentifier,
        messageID: try transportMessageID(inspectorInitialized.message),
        result: "{}"
    )

    return (enable: inspectorEnable, initialized: inspectorInitialized)
}

private func installTransportPageTarget(
    in transport: TransportSession,
    targetID: ProtocolTarget.ID,
    frameID: String = "main-frame"
) async {
    let targetID = jsonEscapedString(targetID.rawValue)
    let frameID = jsonEscapedString(frameID)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"\#(targetID)","type":"page","frameId":"\#(frameID)","isProvisional":false}}}"#
    )
}

@MainActor
private func startAutoReplyingTransportTargetMessages(
    backend: FakeTransportBackend,
    transport: TransportSession,
    documentNodeID: @escaping @MainActor @Sendable (ProtocolTarget.ID) -> String
) -> Task<Void, Never> {
    Task { @MainActor in
        var repliedTargetMessageCount = 0
        while Task.isCancelled == false {
            do {
                let sentMessage = try await backend.waitForTargetMessage(after: repliedTargetMessageCount)
                repliedTargetMessageCount += 1

                let messageID = try transportMessageID(sentMessage.message)
                let method = try transportTargetMessageMethod(sentMessage.message)
                let result = method == "DOM.getDocument"
                    ? transportDocumentResult(nodeID: documentNodeID(sentMessage.targetIdentifier))
                    : "{}"

                await receiveTransportTargetReply(
                    transport,
                    targetID: sentMessage.targetIdentifier,
                    messageID: messageID,
                    result: result
                )
            } catch is CancellationError {
                return
            } catch {
                Issue.record("Failed to auto-reply to transport target message: \(error)")
                return
            }
        }
    }
}

private func waitForTransportTargetMessage(
    _ backend: FakeTransportBackend,
    method: String,
    ordinal: Int = 0,
    after count: Int = 0,
    timeout: Duration = .seconds(1)
) async throws -> SentTargetMessage {
    try await withThrowingTaskGroup(of: SentTargetMessage.self) { group in
        group.addTask {
            try await backend.waitForTargetMessage(method: method, ordinal: ordinal, after: count)
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            let sentMethods = await backend.sentTargetMessages().enumerated().map { index, message in
                let method = (try? transportTargetMessageMethod(message.message)) ?? "<unknown>"
                return "#\(index):\(method)@\(message.targetIdentifier.rawValue)"
            }.joined(separator: ", ")
            throw TimedOut(
                "Timed out waiting for \(method) ordinal \(ordinal) after \(count) within \(timeout). "
                    + "Sent target messages: [\(sentMethods)]"
            )
        }
        guard let message = try await group.next() else {
            throw TimedOut()
        }
        group.cancelAll()
        return message
    }
}

private func waitForTransportTargetMessageReplyingToInterleavedGetDocuments(
    _ backend: FakeTransportBackend,
    transport: TransportSession,
    targetID: ProtocolTarget.ID,
    method expectedMethod: String,
    after count: Int,
    documentNodeID: String,
    repliedGetDocumentMessageIDs: Set<UInt64>,
    timeout: Duration = .seconds(1)
) async throws -> SentTargetMessage {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var repliedGetDocumentMessageIDs = repliedGetDocumentMessageIDs

    while true {
        let sentMessages = await backend.sentTargetMessages()
        for sentMessage in sentMessages.dropFirst(count) where sentMessage.targetIdentifier == targetID {
            let method = try transportTargetMessageMethod(sentMessage.message)
            if method == expectedMethod {
                return sentMessage
            }
            guard method == "DOM.getDocument" else {
                continue
            }

            let messageID = try transportMessageID(sentMessage.message)
            guard repliedGetDocumentMessageIDs.insert(messageID).inserted else {
                continue
            }
            await receiveTransportTargetReply(
                transport,
                targetID: sentMessage.targetIdentifier,
                messageID: messageID,
                result: transportDocumentResult(nodeID: documentNodeID)
            )
        }

        if clock.now >= deadline {
            let sentMethods = try sentMessages.enumerated().map { index, message in
                "#\(index):\(try transportTargetMessageMethod(message.message))@\(message.targetIdentifier.rawValue)"
            }.joined(separator: ", ")
            throw TimedOut(
                "Timed out waiting for \(expectedMethod) after \(count) within \(timeout). "
                    + "Sent target messages: [\(sentMethods)]"
            )
        }

        await Task.yield()
    }
}

private func receiveTransportTargetReply(
    _ transport: TransportSession,
    targetID: ProtocolTarget.ID,
    messageID: UInt64,
    result: String
) async {
    await transport.receiveRootMessage(transportTargetDispatchMessage(
        targetID: targetID,
        message: #"{"id":\#(messageID),"result":\#(result)}"#
    ))
}

private func receiveTransportTargetEvent(
    _ transport: TransportSession,
    targetID: ProtocolTarget.ID,
    method: String,
    params: String
) async {
    await transport.receiveRootMessage(transportTargetDispatchMessage(
        targetID: targetID,
        message: #"{"method":"\#(method)","params":\#(params)}"#
    ))
}

private func transportDocumentResult(nodeID: String) -> String {
    let escapedNodeID = jsonEscapedString(nodeID)
    return ##"{"root":{"nodeId":"\##(escapedNodeID)","nodeType":9,"nodeName":"#document","localName":"","nodeValue":"","frameId":"main-frame","childNodeCount":0}}"##
}

private func transportTargetDispatchMessage(targetID: ProtocolTarget.ID, message: String) -> String {
    let escapedTargetID = jsonEscapedString(targetID.rawValue)
    let escapedMessage = jsonEscapedString(message)
    return #"{"method":"Target.dispatchMessageFromTarget","params":{"targetId":"\#(escapedTargetID)","message":"\#(escapedMessage)"}}"#
}

private func jsonEscapedString(_ string: String) -> String {
    string
        .replacingOccurrences(of: #"\"#, with: #"\\"#)
        .replacingOccurrences(of: #"""#, with: #"\""#)
}

private func transportMessageID(_ message: String) throws -> UInt64 {
    let object = try transportMessageObject(message)
    if let number = object["id"] as? NSNumber {
        return number.uint64Value
    }
    if let string = object["id"] as? String,
       let id = UInt64(string) {
        return id
    }
    throw TransportSession.Error.malformedMessage
}

private func transportTargetMessageMethod(_ message: String) throws -> String {
    let object = try transportMessageObject(message)
    guard let method = object["method"] as? String else {
        throw TransportSession.Error.malformedMessage
    }
    return method
}

private func transportTargetMessageParameters(_ message: String) throws -> [String: Any] {
    let object = try transportMessageObject(message)
    return try #require(object["params"] as? [String: Any])
}

private func transportMessageObject(_ message: String) throws -> [String: Any] {
    let data = try #require(message.data(using: .utf8))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@MainActor
private final class DOMTreeUpdateRecorder {
    private(set) var updates: [DOMTreeUpdate] = []

    private var task: Task<Void, Never>?
    private var hasStarted = false

    init(stream: AsyncStream<DOMTreeUpdate>) {
        task = Task { @MainActor [weak self] in
            self?.hasStarted = true
            for await update in stream {
                self?.updates.append(update)
            }
        }
    }

    func waitUntilStarted() async throws {
        try await waitUntil { self.hasStarted }
    }

    func waitForUpdateCount(_ count: Int) async throws {
        try await waitUntil { self.updates.count >= count }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}

@MainActor
private final class DOMTreeRevealRequestRecorder {
    private(set) var requests: [DOMTreeRevealRequest] = []

    private var task: Task<Void, Never>?
    private var hasStarted = false

    init(stream: AsyncStream<DOMTreeRevealRequest>) {
        task = Task { @MainActor [weak self] in
            self?.hasStarted = true
            for await request in stream {
                self?.requests.append(request)
            }
        }
    }

    func waitUntilStarted() async throws {
        try await waitUntil { self.hasStarted }
    }

    func waitForRequestCount(_ count: Int) async throws {
        try await waitUntil { self.requests.count >= count }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}

@MainActor
@discardableResult
private func seedFetchedResultsRequest(
    _ requestID: String,
    url: String,
    timestamp: Double,
    in context: WebInspectorContext
) -> NetworkRequest.ID {
    context.seedNetworkRequest(
        requestID: requestID,
        url: url,
        resourceTypeRawValue: "Fetch",
        responseMIMEType: "text/plain",
        responseStatus: 200,
        responseStatusText: "OK",
        timestamp: timestamp
    )
}

@MainActor
private final class FetchedResultsTransactionRecorder<ItemID: Hashable & Sendable> {
    private(set) var updates: [WebInspectorFetchedResultsUpdate<ItemID>] = []
    private(set) var transactions: [WebInspectorFetchedResultsTransaction<ItemID>] = []
    private(set) var reconfigureItemIDSets: [Set<ItemID>] = []

    private var task: Task<Void, Never>?
    private var hasConsumedInitialUpdate = false

    init(stream: AsyncStream<WebInspectorFetchedResultsUpdate<ItemID>>) {
        task = Task { @MainActor [weak self] in
            for await update in stream {
                self?.updates.append(update)
                guard case let .transaction(_, transaction, reconfigureItemIDs) = update else {
                    self?.hasConsumedInitialUpdate = true
                    continue
                }
                self?.transactions.append(transaction)
                self?.reconfigureItemIDSets.append(reconfigureItemIDs)
            }
        }
    }

    func waitUntilStarted() async throws {
        try await waitUntil { self.hasConsumedInitialUpdate }
    }

    func waitForTransactionCount(_ count: Int) async throws {
        try await waitUntil { self.transactions.count >= count }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}

@MainActor
private func waitForChild(in context: WebInspectorContext) async throws -> DOMNode {
    try await waitUntil {
        guard let root = context.rootNode else {
            return false
        }
        guard case let .loaded(children) = root.children else {
            return false
        }
        return children.isEmpty == false
    }

    let root = try #require(context.rootNode)
    guard case let .loaded(children) = root.children else {
        Issue.record("Expected loaded root children.")
        throw TestFailure()
    }
    return try #require(children.first)
}

private struct TestFailure: Error {}
private struct TimedOut: Error, CustomStringConvertible {
    var description: String

    init(_ description: String = "Timed out") {
        self.description = description
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var hasStarted = false
    private var isCancelled = false

    func markStarted() {
        lock.lock()
        defer {
            lock.unlock()
        }
        hasStarted = true
    }

    func markCancelled() {
        lock.lock()
        defer {
            lock.unlock()
        }
        isCancelled = true
    }

    func started() -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return hasStarted
    }

    func cancelled() -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return isCancelled
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor @Sendable () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while condition() == false {
        if clock.now >= deadline {
            throw TimedOut()
        }
        await Task.yield()
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while await condition() == false {
        if clock.now >= deadline {
            throw TimedOut()
        }
        await Task.yield()
    }
}
