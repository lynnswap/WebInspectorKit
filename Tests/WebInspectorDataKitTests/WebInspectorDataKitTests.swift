import Foundation
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
    try await waitUntil { context.rootNode != nil }

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
    #expect(context.node(for: child.id) === child)

    await runtime.backend.emit(
        .attributeModified(childID, name: "class", value: "after"),
        target: target
    )
    try await waitUntil { child.attributes["class"] == "after" }
    #expect(context.node(for: child.id) === child)

    await runtime.backend.emit(
        .childNodeCountUpdated(childID, count: 2),
        target: target
    )
    try await waitUntil { child.childNodeCount == 2 }
    #expect(context.node(for: child.id) === child)

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
    context.select(grandchild)

    await runtime.backend.emit(
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

@MainActor
@Test
func requestChildrenDispatchesDOMCommandAndMaterializesSetChildNodes() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let childID = DOM.Node.ID("requested-child")

    await runtime.backend.enqueue((), for: "DOM", method: "requestChildNodes")

    await document.requestChildren(depth: 2)

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
    let tree = try await context.treeController()
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
    let parent = try #require(context.node(for: DOMNode.ID(parentID)))
    let child = try #require(context.node(for: DOMNode.ID(childID)))

    await runtime.backend.enqueue("<span id=\"title\"></span>", for: "DOM", method: "getOuterHTML")
    #expect(try await child.copyText(.html) == "<span id=\"title\"></span>")
    #expect(try await child.copyText(.selectorPath) == "#title")
    #expect(try context.xPath(for: child) == "/html/body/div/span")

    await runtime.backend.enqueue((), for: "DOM", method: "highlightNode")
    try await child.highlight()

    await runtime.backend.enqueue((), for: "DOM", method: "hideHighlight")
    try await context.hideHighlight()

    await runtime.backend.enqueue((), for: "DOM", method: "undo")
    try await context.undoDOMChange()

    await runtime.backend.enqueue((), for: "DOM", method: "redo")
    try await context.redoDOMChange()

    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")
    try await context.setElementPickerEnabled(true)
    #expect(context.isElementPickerEnabled)

    await enqueueCSSStyleReplies(on: runtime.backend)
    await runtime.backend.enqueue((), for: "DOM", method: "highlightNode")
    await runtime.backend.emit(.inspect(childID), target: target)
    try await waitUntil { context.selectedNode === child }
    try await waitUntil { child.elementStyles?.phase == .loaded }
    #expect(context.isElementPickerEnabled == false)

    await runtime.backend.enqueue((), for: "DOM", method: "removeNode")
    await runtime.backend.enqueue((), for: "DOM", method: "removeNode")
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    try await context.delete([parent, child])
    #expect(context.selectedNode == nil)
    #expect(child.elementStyles == nil)

    await runtime.backend.enqueue((), for: "Page", method: "reload")
    try await context.reloadPage(ignoringCache: true)

    let commands = await runtime.backend.recordedCommands()
    let outerHTML = try #require(commands.first { $0.domain == "DOM" && $0.method == "getOuterHTML" })
    #expect(outerHTML.payload.cast(as: DOM.GetOuterHTMLPayload.self)?.id == childID)

    let highlight = try #require(commands.first { $0.domain == "DOM" && $0.method == "highlightNode" })
    #expect(highlight.payload.cast(as: DOM.HighlightNodePayload.self)?.id == childID)

    #expect(commands.contains { $0.domain == "DOM" && $0.method == "undo" })
    #expect(commands.contains { $0.domain == "DOM" && $0.method == "redo" })

    let inspectMode = try #require(commands.first { $0.domain == "DOM" && $0.method == "setInspectModeEnabled" })
    #expect(inspectMode.payload.cast(as: DOM.SetInspectModeEnabledPayload.self)?.enabled == true)

    let removals = commands.filter { $0.domain == "DOM" && $0.method == "removeNode" }
    #expect(removals.count == 2)
    #expect(removals.first?.payload.cast(as: DOM.RemoveNodePayload.self)?.id == childID)
    #expect(removals.last?.payload.cast(as: DOM.RemoveNodePayload.self)?.id == parentID)
    let undoMarks = commands.filter { $0.domain == "DOM" && $0.method == "markUndoableState" }
    #expect(undoMarks.count == 2)

    let reload = try #require(commands.first { $0.domain == "Page" && $0.method == "reload" })
    #expect(reload.payload.cast(as: Page.ReloadPayload.self)?.ignoringCache == true)
}

@MainActor
@Test
func domInspectSelectsKnownNodeAndLoadsStyles() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let elementID = DOM.Node.ID("inspect-node")

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )
    let element = try await waitForChild(in: context)

    await enqueueCSSStyleReplies(on: runtime.backend)
    await runtime.backend.enqueue((), for: "DOM", method: "highlightNode")
    await runtime.backend.emit(.inspect(elementID), target: target)

    try await waitUntil { context.selectedNode === element }
    try await waitUntil {
        await runtime.backend.recordedCommands().contains { command in
            command.domain == "DOM"
                && command.method == "highlightNode"
                && command.payload.cast(as: DOM.HighlightNodePayload.self)?.id == elementID
        }
    }
    let styles = try #require(element.elementStyles)
    try await waitUntil { styles.phase == .loaded }
    #expect(styles.sections.map(\.title) == [".card"])

    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "getMatchedStylesForNode")))
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "getComputedStyleForNode")))
}

@MainActor
@Test
func domInspectRequestsSubtreeBeforeSelectingUnresolvedNode() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let staleID = DOM.Node.ID("stale-node")
    let elementID = DOM.Node.ID("resolved-inspect-node")

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: staleID, nodeType: 1, nodeName: "SPAN", localName: "span")
        ]),
        target: target
    )
    try await waitUntil { context.node(for: DOMNode.ID(staleID)) != nil }

    await runtime.backend.enqueue((), for: "DOM", method: "requestChildNodes")
    await enqueueCSSStyleReplies(on: runtime.backend)
    await runtime.backend.enqueue((), for: "DOM", method: "highlightNode")
    await runtime.backend.emit(.inspect(elementID), target: target)
    try await waitUntil {
        await runtime.backend.recordedCommands().contains(
            RecordedCommand(domain: "DOM", method: "requestChildNodes")
        )
    }

    let commands = await runtime.backend.recordedCommands()
    let command = try #require(commands.last {
        $0.domain == "DOM" && $0.method == "requestChildNodes"
    })
    let payload = try #require(command.payload.cast(as: DOM.RequestChildNodesPayload.self))
    #expect(payload.id == document.id.proxyID)
    #expect(payload.depth == -1)

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )

    try await waitUntil { context.selectedNode?.id == DOMNode.ID(elementID) }
    try await waitUntil {
        await runtime.backend.recordedCommands().contains { command in
            command.domain == "DOM"
                && command.method == "highlightNode"
                && command.payload.cast(as: DOM.HighlightNodePayload.self)?.id == elementID
        }
    }
    #expect(context.state == .attached)
    #expect(context.node(for: DOMNode.ID(staleID)) == nil)
    let selected = try #require(context.selectedNode)
    let styles = try #require(selected.elementStyles)
    try await waitUntil { styles.phase == .loaded }
}

@MainActor
@Test
func domInspectBeforeDocumentArrivesRequestsSubtreeAfterRootApplies() async throws {
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
    try await waitUntil {
        await runtime.backend.recordedCommands()
            .contains(RecordedCommand(domain: "DOM", method: "getDocument"))
    }

    await runtime.backend.emit(.inspect(elementID), target: target)
    await runtime.backend.enqueue((), for: "DOM", method: "requestChildNodes")
    await runtime.backend.enqueue((), for: "DOM", method: "highlightNode")
    await enqueueCSSStyleReplies(on: runtime.backend)
    await gate.open()

    try await waitUntil {
        await runtime.backend.recordedCommands().contains(
            RecordedCommand(domain: "DOM", method: "requestChildNodes")
        )
    }
    let commands = await runtime.backend.recordedCommands()
    let command = try #require(commands.last {
        $0.domain == "DOM" && $0.method == "requestChildNodes"
    })
    let payload = try #require(command.payload.cast(as: DOM.RequestChildNodesPayload.self))
    #expect(payload.id == documentID)
    #expect(payload.depth == -1)

    await runtime.backend.emit(
        .setChildNodes(parent: documentID, nodes: [
            DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )

    try await waitUntil { context.selectedNode?.id == DOMNode.ID(elementID) }
    try await waitUntil {
        await runtime.backend.recordedCommands().contains { command in
            command.domain == "DOM"
                && command.method == "highlightNode"
                && command.payload.cast(as: DOM.HighlightNodePayload.self)?.id == elementID
        }
    }
    let selected = try #require(context.selectedNode)
    let styles = try #require(selected.elementStyles)
    try await waitUntil { styles.phase == .loaded }
}

@MainActor
@Test
func explicitSelectionSupersedesPendingDOMInspectResolution() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let selectedID = DOM.Node.ID("manual-selection")
    let inspectedID = DOM.Node.ID("late-inspect-node")

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: selectedID, nodeType: 1, nodeName: "BUTTON", localName: "button")
        ]),
        target: target
    )
    let manualSelection = try await waitForChild(in: context)

    await runtime.backend.enqueue((), for: "DOM", method: "requestChildNodes")
    await runtime.backend.emit(.inspect(inspectedID), target: target)
    try await waitUntil {
        await runtime.backend.recordedCommands().contains(
            RecordedCommand(domain: "DOM", method: "requestChildNodes")
        )
    }

    await enqueueCSSStyleReplies(on: runtime.backend)
    context.select(manualSelection)
    try await waitUntil { context.selectedNode === manualSelection }

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: selectedID, nodeType: 1, nodeName: "BUTTON", localName: "button"),
            DOM.Node(id: inspectedID, nodeType: 1, nodeName: "DIV", localName: "div"),
        ]),
        target: target
    )
    try await waitUntil { context.node(for: DOMNode.ID(inspectedID)) != nil }

    #expect(context.selectedNode === manualSelection)
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
    try await waitUntil { context.rootNode != nil }

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
func startupEnablesTrackedDomainsBeforeInitialDocumentSnapshot() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    await enqueueStartupReplies(on: runtime.backend)

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitForStartupSubscribers(runtime: runtime, target: target)
    try await waitUntil { context.state == .attached }

    let commands = await runtime.backend.recordedCommands()
    #expect(commands.prefix(startupCommands.count) == startupCommands[...])
}

@MainActor
@Test
func networkEnableFailureFailsStartupBeforeDocumentFetch() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    await runtime.backend.enqueue((), for: "Inspector", method: "enable")
    await runtime.backend.enqueue((), for: "Inspector", method: "initialized")
    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    await runtime.backend.enqueue((), for: "Runtime", method: "disable")
    await runtime.backend.enqueue((), for: "Inspector", method: "disable")

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

    let commands = await runtime.backend.recordedCommands()
    #expect(commands == [
        RecordedCommand(domain: "Inspector", method: "enable"),
        RecordedCommand(domain: "Inspector", method: "initialized"),
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Network", method: "enable"),
        RecordedCommand(domain: "Runtime", method: "disable"),
        RecordedCommand(domain: "Inspector", method: "disable"),
    ])
    #expect(context.rootNode == nil)
}

@MainActor
@Test
func consoleEnableFailureFailsStartupBeforeAttachingDocument() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    await runtime.backend.enqueue((), for: "Inspector", method: "enable")
    await runtime.backend.enqueue((), for: "Inspector", method: "initialized")
    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    await runtime.backend.enqueue((), for: "Network", method: "enable")
    await runtime.backend.enqueue(
        DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document"),
        for: "DOM",
        method: "getDocument"
    )
    await runtime.backend.enqueue((), for: "Runtime", method: "disable")
    await runtime.backend.enqueue((), for: "Network", method: "disable")
    await runtime.backend.enqueue((), for: "Inspector", method: "disable")

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

    let commands = await runtime.backend.recordedCommands()
    #expect(commands == [
        RecordedCommand(domain: "Inspector", method: "enable"),
        RecordedCommand(domain: "Inspector", method: "initialized"),
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Network", method: "enable"),
        RecordedCommand(domain: "DOM", method: "getDocument"),
        RecordedCommand(domain: "Console", method: "enable"),
        RecordedCommand(domain: "Runtime", method: "disable"),
        RecordedCommand(domain: "Network", method: "disable"),
        RecordedCommand(domain: "Inspector", method: "disable"),
    ])
    #expect(context.rootNode == nil)
}

@MainActor
@Test
func runtimeEnableFailureFailsStartupBeforeConsoleNetworkAndDocumentFetch() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    await runtime.backend.enqueue((), for: "Inspector", method: "enable")
    await runtime.backend.enqueue((), for: "Inspector", method: "initialized")
    await runtime.backend.enqueue((), for: "Inspector", method: "disable")

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

    let commands = await runtime.backend.recordedCommands()
    #expect(commands == [
        RecordedCommand(domain: "Inspector", method: "enable"),
        RecordedCommand(domain: "Inspector", method: "initialized"),
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Inspector", method: "disable"),
    ])
    #expect(context.rootNode == nil)
}

@MainActor
@Test
func closeAfterAttachedDisablesEnabledDomains() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    await enqueueStartupReplies(on: runtime.backend)
    await enqueueDomainDisableReplies(on: runtime.backend)

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitForStartupSubscribers(runtime: runtime, target: target)
    try await waitUntil { context.state == .attached }

    await container.close()

    let commands = await runtime.backend.recordedCommands()
    #expect(commands == startupCommands + shutdownCommands)
    #expect(context.state == .detached)
    #expect(context.teardownError == nil)
}

@MainActor
@Test
func closeRecordsNetworkDisableFailureAndDetachesContext() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    await enqueueStartupReplies(on: runtime.backend)
    await runtime.backend.enqueue((), for: "Console", method: "disable")
    await runtime.backend.enqueue((), for: "Runtime", method: "disable")

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

@MainActor
@Test
func restartDisablesPreviousDomainTrackingBeforeReenable() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: DOM.Node.ID("document-1"), nodeType: 9, nodeName: "#document")
    )

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitForStartupSubscribers(runtime: runtime, target: target)
    try await waitUntil { context.rootNode?.id == DOMNode.ID(DOM.Node.ID("document-1")) }

    await enqueueDomainDisableReplies(on: runtime.backend)
    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: DOM.Node.ID("document-2"), nodeType: 9, nodeName: "#document")
    )

    context.start()

    try await waitUntil { context.rootNode?.id == DOMNode.ID(DOM.Node.ID("document-2")) }

    let commands = await runtime.backend.recordedCommands()
    #expect(commands == startupCommands + shutdownCommands + startupCommands)
}

@MainActor
@Test
func restartWaitsForPreviousStartupCleanupBeforeReenable() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let enableGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "Network", method: "enable", gate: enableGate)
    await enqueueDomainEnableReplies(on: runtime.backend)

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitForStartupSubscribers(runtime: runtime, target: target)
    try await waitUntil {
        await runtime.backend.recordedCommands() == [
            RecordedCommand(domain: "Inspector", method: "enable"),
            RecordedCommand(domain: "Inspector", method: "initialized"),
            RecordedCommand(domain: "Runtime", method: "enable"),
            RecordedCommand(domain: "Network", method: "enable"),
        ]
    }

    await enqueueDomainDisableReplies(on: runtime.backend)
    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: DOM.Node.ID("restarted-document"), nodeType: 9, nodeName: "#document")
    )

    context.start()
    for _ in 0..<10 {
        await Task.yield()
    }
    #expect(await runtime.backend.recordedCommands() == [
        RecordedCommand(domain: "Inspector", method: "enable"),
        RecordedCommand(domain: "Inspector", method: "initialized"),
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Network", method: "enable")
    ])

    await enableGate.open()
    try await waitUntil { context.rootNode?.id == DOMNode.ID(DOM.Node.ID("restarted-document")) }

    let commands = await runtime.backend.recordedCommands()
    #expect(commands == Array(startupCommands.prefix(4)) + [
        RecordedCommand(domain: "Runtime", method: "disable"),
        RecordedCommand(domain: "Network", method: "disable"),
        RecordedCommand(domain: "Inspector", method: "disable"),
    ] + startupCommands)
}

@MainActor
@Test
func runtimeEnableReplayIsCapturedBeforeCommandReturns() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let enableGate = WebInspectorTestGate()
    let contextID = Runtime.ExecutionContext.ID("main")

    await runtime.backend.hold(domain: "Runtime", method: "enable", gate: enableGate)
    await enqueueStartupReplies(on: runtime.backend)

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitUntil {
        await runtime.backend.recordedCommands() == [
            RecordedCommand(domain: "Inspector", method: "enable"),
            RecordedCommand(domain: "Inspector", method: "initialized"),
            RecordedCommand(domain: "Runtime", method: "enable")
        ]
    }

    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(id: contextID, name: "Main", kind: .normal)),
        target: target
    )
    try await waitUntil {
        context.executionContexts.first?.id == RuntimeContext.ID(contextID)
    }

    await enableGate.open()
    try await waitUntil { context.state == .attached }
    #expect(context.selectedContext?.id == RuntimeContext.ID(contextID))
}

@MainActor
@Test
func consoleEnableReplayIsCapturedBeforeCommandReturns() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let enableGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "Console", method: "enable", gate: enableGate)
    await enqueueStartupReplies(on: runtime.backend)

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    let results: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()
    try await waitUntil {
        await runtime.backend.recordedCommands() == startupCommands
    }

    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "warning"),
            text: "replayed"
        )),
        target: target
    )
    try await waitUntil { results.items.map(\.text) == ["replayed"] }

    await enableGate.open()
    try await waitUntil { context.state == .attached }
    #expect(results.items.map(\.text) == ["replayed"])
}

@MainActor
@Test
func startupRefetchesDocumentWhenMainFrameNavigatesBeforeAttach() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let consoleGate = WebInspectorTestGate()
    let staleDocumentID = DOM.Node.ID("stale-startup-document")
    let freshDocumentID = DOM.Node.ID("fresh-startup-document")

    await runtime.backend.hold(domain: "Console", method: "enable", gate: consoleGate)
    await runtime.backend.enqueue((), for: "Inspector", method: "enable")
    await runtime.backend.enqueue((), for: "Inspector", method: "initialized")
    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    await runtime.backend.enqueue((), for: "Network", method: "enable")
    await runtime.backend.enqueue(
        DOM.Node(id: staleDocumentID, nodeType: 9, nodeName: "#document"),
        for: "DOM",
        method: "getDocument"
    )
    await runtime.backend.enqueue(
        DOM.Node(id: freshDocumentID, nodeType: 9, nodeName: "#document"),
        for: "DOM",
        method: "getDocument"
    )
    await runtime.backend.enqueue((), for: "Console", method: "enable")

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitUntil {
        await runtime.backend.recordedCommands() == startupCommands
    }

    await runtime.backend.emit(
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
    await consoleGate.open()

    try await waitUntil { context.rootNode?.id == DOMNode.ID(freshDocumentID) }
    #expect(context.state == .attached)
    #expect(context.node(for: DOMNode.ID(staleDocumentID)) == nil)
    #expect(await runtime.backend.recordedCommands() == startupCommands + [
        RecordedCommand(domain: "DOM", method: "getDocument")
    ])
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
func transportBackedFrameInspectProjectsFrameDocumentUnderIframeOwner() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let frameTargetID = ProtocolTarget.ID("frame-child")
    let iframeOwnerID = DOMNode.ID(DOM.Node.ID("iframe-owner"))
    let scopedFrameDocumentID = DOMNode.ID(DOM.Node.ID("frame-document", scopedToTargetRawValue: frameTargetID.rawValue))
    let scopedInspectedID = DOMNode.ID(DOM.Node.ID("42", scopedToTargetRawValue: frameTargetID.rawValue))
    let (backend, transport, context) = try await startTransportBackedContext(
        targetID: pageTargetID,
        documentID: "1"
    )
    let controller = try await context.treeController()
    let startupMessageCount = await backend.sentTargetMessages().count

    await receiveTransportTargetEvent(
        transport,
        targetID: pageTargetID,
        method: "DOM.setChildNodes",
        params: ##"{"parentId":"1","nodes":[{"nodeId":"iframe-owner","nodeType":1,"nodeName":"IFRAME","localName":"iframe","nodeValue":"","frameId":"child-frame","childNodeCount":0,"attributes":["src","https://child.example.test/"]}]}"##
    )
    try await waitUntil { context.node(for: iframeOwnerID) != nil }

    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-child","type":"page","frameId":"child-frame","parentFrameId":"main-frame","isProvisional":false}}}"#
    )
    await receiveTransportTargetEvent(
        transport,
        targetID: frameTargetID,
        method: "Inspector.inspect",
        params: #"{"object":{"type":"object","subtype":"node","objectId":"frame-node-object"}}"#
    )

    let requestNode = try await waitForTransportTargetMessage(
        backend,
        method: "DOM.requestNode",
        after: startupMessageCount
    )
    #expect(requestNode.targetIdentifier == pageTargetID)
    #expect(try transportTargetMessageParameters(requestNode.message)["objectId"] as? String == "frame-node-object")
    let afterRequestNodeCount = await backend.sentTargetMessages().count
    await receiveTransportTargetReply(
        transport,
        targetID: requestNode.targetIdentifier,
        messageID: try transportMessageID(requestNode.message),
        result: #"{"nodeId":42}"#
    )

    let frameGetDocument = try await waitForTransportTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: afterRequestNodeCount
    )
    #expect(frameGetDocument.targetIdentifier == frameTargetID)
    await receiveTransportTargetReply(
        transport,
        targetID: frameGetDocument.targetIdentifier,
        messageID: try transportMessageID(frameGetDocument.message),
        result: ##"{"root":{"nodeId":"frame-document","nodeType":9,"nodeName":"#document","localName":"","nodeValue":"","frameId":"child-frame","documentURL":"https://child.example.test/","childNodeCount":1,"children":[{"nodeId":"frame-html","nodeType":1,"nodeName":"HTML","localName":"html","nodeValue":"","childNodeCount":1,"children":[{"nodeId":"frame-body","nodeType":1,"nodeName":"BODY","localName":"body","nodeValue":"","childNodeCount":1,"children":[{"nodeId":42,"nodeType":1,"nodeName":"BUTTON","localName":"button","nodeValue":"","childNodeCount":0}]}]}]}}"##
    )

    try await waitUntil {
        controller.snapshot.selectedNodeID == scopedInspectedID
            && controller.snapshot.parent(of: scopedFrameDocumentID) == iframeOwnerID
    }
    let snapshot = controller.snapshot
    let iframe = try #require(context.node(for: iframeOwnerID))
    #expect(iframe.contentDocument?.id == scopedFrameDocumentID)
    #expect(snapshot.visibleChildren(of: iframeOwnerID).nodeIDs == [scopedFrameDocumentID])
    #expect(snapshot.ancestorNodeIDs(of: scopedInspectedID).contains(iframeOwnerID))

    let matchedStyles = try await waitForTransportTargetMessage(
        backend,
        method: "CSS.getMatchedStylesForNode",
        after: startupMessageCount
    )
    #expect(matchedStyles.targetIdentifier == frameTargetID)
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
    #expect(inlineStyles.targetIdentifier == frameTargetID)
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
    #expect(computedStyle.targetIdentifier == frameTargetID)
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
    #expect(preRuntimeMethods.allSatisfy { $0 == "DOM.getDocument" || $0 == "Inspector.enable" || $0 == "Inspector.initialized" })
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
    #expect(context.rootNode?.childNodeCount == 0)
    #expect(context.node(for: oldRouteChildID) == nil)
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
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let staleID = Runtime.ExecutionContext.ID("stale")
    let replayID = Runtime.ExecutionContext.ID("replayed")
    let enableGate = WebInspectorTestGate()

    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(id: staleID, name: "Stale", kind: .normal)),
        target: target
    )
    try await waitUntil {
        context.executionContexts.first?.id == RuntimeContext.ID(staleID)
    }

    await runtime.backend.hold(domain: "Runtime", method: "enable", gate: enableGate)
    await enqueueDomainDisableReplies(on: runtime.backend)
    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: DOM.Node.ID("restarted-document"), nodeType: 9, nodeName: "#document")
    )

    context.start()
    try await waitUntil {
        await runtime.backend.recordedCommands() == startupCommands + shutdownCommands + [
            RecordedCommand(domain: "Inspector", method: "enable"),
            RecordedCommand(domain: "Inspector", method: "initialized"),
            RecordedCommand(domain: "Runtime", method: "enable"),
        ]
    }
    #expect(context.executionContexts.isEmpty)
    #expect(context.selectedContext == nil)

    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(id: replayID, name: "Replayed", kind: .normal)),
        target: target
    )
    try await waitUntil {
        context.executionContexts.map(\.id) == [RuntimeContext.ID(replayID)]
    }

    await enableGate.open()
    try await waitUntil { context.rootNode?.id == DOMNode.ID(DOM.Node.ID("restarted-document")) }
    #expect(context.selectedContext?.id == RuntimeContext.ID(replayID))
}

@MainActor
@Test
func restartClearsConsoleMessagesBeforeConsoleReplay() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let results: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()
    let enableGate = WebInspectorTestGate()

    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "warning"),
            text: "old"
        )),
        target: target
    )
    try await waitUntil { results.items.map(\.text) == ["old"] }

    await runtime.backend.hold(domain: "Console", method: "enable", gate: enableGate)
    await enqueueDomainDisableReplies(on: runtime.backend)
    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: DOM.Node.ID("restarted-document"), nodeType: 9, nodeName: "#document")
    )

    context.start()
    try await waitUntil {
        await runtime.backend.recordedCommands() == startupCommands + shutdownCommands + startupCommands
    }
    #expect(results.items.isEmpty)

    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "warning"),
            text: "old"
        )),
        target: target
    )
    try await waitUntil { results.items.map(\.text) == ["old"] }

    await enableGate.open()
    try await waitUntil { context.rootNode?.id == DOMNode.ID(DOM.Node.ID("restarted-document")) }
    #expect(results.items.count == 1)
}

@MainActor
@Test
func documentUpdatedReloadsRootDocument() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let undoCommands = try context.domUndoRedoCommands()
    let replacementID = DOM.Node.ID("replacement-document")

    await runtime.backend.enqueue(
        DOM.Node(id: replacementID, nodeType: 9, nodeName: "#document"),
        for: "DOM",
        method: "getDocument"
    )

    await runtime.backend.emit(.documentUpdated, target: target)

    try await waitUntil {
        context.rootNode?.id == DOMNode.ID(replacementID)
    }
    await #expect(throws: WebInspectorProxyError.disconnected("DOM undo/redo target is no longer current.")) {
        try await undoCommands.undo()
    }

    let commands = await runtime.backend.recordedCommands()
    #expect(!commands.contains { $0.domain == "DOM" && $0.method == "undo" })
}

@MainActor
@Test
func childInsertIntoUnrequestedParentDoesNotMarkChildrenLoaded() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
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
        document.childNodeCount == 1
    }
    guard case let .unrequested(count) = document.children else {
        Issue.record("Expected parent children to stay unrequested.")
        return
    }
    #expect(count == 1)
    #expect(context.node(for: DOMNode.ID(insertedID)) == nil)
}

@MainActor
@Test
func domTreeControllerPublishesCurrentSnapshotAndChildTransactions() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(
        runtime: runtime,
        document: DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document", childNodeCount: 1)
    )
    let document = try #require(context.rootNode)
    let controller = try await context.treeController()
    let recorder = DOMTreeTransactionRecorder(stream: controller.transactions)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()

    #expect(controller.snapshot.rootNodeID == document.id)
    #expect(Set(controller.snapshot.nodesByID.keys) == Set([document.id]))
    #expect(controller.snapshot.node(for: document.id)?.children == .unrequested(count: 1))

    let childID = DOM.Node.ID("child")
    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: childID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )

    try await recorder.waitForTransactionCount(1)
    let childrenChanged = try #require(recorder.transactions.last)
    #expect(childrenChanged.changes == [.childrenReplaced(parentID: document.id)])
    #expect(childrenChanged.oldSnapshot.node(for: document.id)?.children == .unrequested(count: 1))
    #expect(childrenChanged.newSnapshot.children(of: document.id) == [DOMNode.ID(childID)])
    #expect(childrenChanged.newSnapshot.parent(of: DOMNode.ID(childID)) == document.id)
    #expect(controller.snapshot.children(of: document.id) == [DOMNode.ID(childID)])
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

@MainActor
@Test
func domTreeControllerPublishesSelectionTransactionsWithoutOwningExpansion() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(
        runtime: runtime,
        document: DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document")
    )
    let document = try #require(context.rootNode)
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

    try await waitUntil { context.node(for: DOMNode.ID(childID)) != nil }
    let parent = try #require(context.node(for: DOMNode.ID(parentID)))
    let child = try #require(context.node(for: DOMNode.ID(childID)))
    let controller = try await context.treeController()
    let recorder = DOMTreeTransactionRecorder(stream: controller.transactions)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()

    #expect(controller.snapshot.children(of: document.id) == [parent.id])
    #expect(controller.snapshot.children(of: parent.id) == [child.id])
    #expect(controller.snapshot.ancestorNodeIDs(of: child.id) == [parent.id, document.id])

    await enqueueCSSStyleReplies(on: runtime.backend)
    context.select(child)

    try await recorder.waitForTransactionCount(1)
    let selection = try #require(recorder.transactions.last)
    #expect(selection.changes == [.selectionChanged(nodeID: child.id)])
    #expect(selection.oldSnapshot.selectedNodeID == nil)
    #expect(selection.newSnapshot.selectedNodeID == child.id)
    #expect(controller.snapshot.selectedNodeID == child.id)

    context.select(nil)

    try await recorder.waitForTransactionCount(2)
    let selectionCleared = try #require(recorder.transactions.last)
    #expect(selectionCleared.changes == [.selectionChanged(nodeID: nil)])
    #expect(selectionCleared.oldSnapshot.selectedNodeID == child.id)
    #expect(selectionCleared.newSnapshot.selectedNodeID == nil)
    #expect(controller.snapshot.selectedNodeID == nil)
}


@MainActor
@Test
func fetchedResultsControllerPublishesNetworkTopologyTransactionsOnly() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
    let controller = WebInspectorFetchedResultsController(fetchedResults: results)
    let recorder = FetchedResultsTransactionRecorder(stream: controller.transactions)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()

    let requestID = Network.Request.ID("controller-request")
    await runtime.backend.emit(
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
    #expect(inserted.itemChanges == [.insert(itemID: modelID, indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0))])
    #expect(inserted.oldSnapshot.itemIDs == [])
    #expect(inserted.newSnapshot.itemIDs == [modelID])
    #expect(controller.snapshot.itemIDs == [modelID])
    let request = try #require(results.items.first)

    await runtime.backend.emit(
        .responseReceived(
            id: requestID,
            response: Network.Response(status: 200, statusText: "OK", mimeType: "text/plain"),
            resourceType: .fetch,
            timestamp: 2
        ),
        target: target
    )

    try await waitUntil { request.status == 200 }
    #expect(results.items.first === request)
    #expect(recorder.transactions.count == 1)

    await runtime.backend.emit(
        .dataReceived(id: requestID, dataLength: 7, encodedDataLength: 3, timestamp: 3),
        target: target
    )

    try await waitUntil { request.decodedDataLength == 7 && request.encodedDataLength == 3 }
    #expect(results.items.first === request)
    #expect(recorder.transactions.count == 1)

    await runtime.backend.emit(
        .loadingFinished(id: requestID, timestamp: 4, sourceMapURL: nil, metrics: nil),
        target: target
    )

    try await waitUntil { request.state == .finished }
    #expect(results.items.first === request)
    #expect(recorder.transactions.count == 1)

    await runtime.backend.emit(
        .requestServedFromMemoryCache(
            id: requestID,
            response: Network.Response(url: "https://example.com/first", status: 200),
            timestamp: 5
        ),
        target: target
    )

    try await waitUntil { request.finishedOrFailedTimestamp == 5 }
    #expect(results.items.first === request)
    #expect(recorder.transactions.count == 1)

    let failedRequestID = Network.Request.ID("controller-failed-request")
    let failedModelID = NetworkRequest.ID(failedRequestID)
    await runtime.backend.emit(
        .requestWillBeSent(
            id: failedRequestID,
            request: Network.Request(id: failedRequestID, url: "https://example.com/failed", method: "GET"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 6
        ),
        target: target
    )

    try await recorder.waitForTransactionCount(2)
    #expect(recorder.transactions.last?.itemChanges == [.insert(itemID: failedModelID, indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 1))])
    let failedRequest = try #require(results.items.last)

    await runtime.backend.emit(
        .loadingFailed(id: failedRequestID, errorText: "cancelled", canceled: true, timestamp: 7),
        target: target
    )

    try await waitUntil {
        if case .failed(errorText: "cancelled", canceled: true) = failedRequest.state {
            return true
        }
        return false
    }
    #expect(results.items.last === failedRequest)
    #expect(recorder.transactions.count == 2)

    let socketRequestID = Network.Request.ID("controller-socket-request")
    let socketModelID = NetworkRequest.ID(socketRequestID)
    await runtime.backend.emit(
        .webSocket(.created(id: socketRequestID, url: "wss://example.com/socket")),
        target: target
    )

    try await recorder.waitForTransactionCount(3)
    #expect(recorder.transactions.last?.itemChanges == [.insert(itemID: socketModelID, indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 2))])
    let socketRequest = try #require(results.items.last)

    await runtime.backend.emit(
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
    #expect(results.items.last === socketRequest)
    #expect(recorder.transactions.count == 3)

    await runtime.backend.emit(
        .webSocket(.handshakeResponse(
            id: socketRequestID,
            response: Network.Response(status: 101, statusText: "Switching Protocols"),
            timestamp: 9
        )),
        target: target
    )

    try await waitUntil { socketRequest.status == 101 }
    #expect(results.items.last === socketRequest)
    #expect(recorder.transactions.count == 3)

    await runtime.backend.emit(
        .webSocket(.frameSent(
            id: socketRequestID,
            frame: Network.WebSocketFrame(opcode: 1, mask: true, payloadData: "hello", payloadLength: 5),
            timestamp: 10
        )),
        target: target
    )

    try await waitUntil { socketRequest.webSocket?.frames.count == 1 }
    #expect(results.items.last === socketRequest)
    #expect(recorder.transactions.count == 3)

    await runtime.backend.emit(
        .webSocket(.frameReceived(
            id: socketRequestID,
            frame: Network.WebSocketFrame(opcode: 1, mask: false, payloadData: "world", payloadLength: 5),
            timestamp: 11
        )),
        target: target
    )

    try await waitUntil { socketRequest.webSocket?.frames.count == 2 }
    #expect(results.items.last === socketRequest)
    #expect(recorder.transactions.count == 3)

    await runtime.backend.emit(
        .webSocket(.error(id: socketRequestID, message: "decode failed", timestamp: 12)),
        target: target
    )

    try await waitUntil { socketRequest.webSocket?.frames.count == 3 }
    #expect(results.items.last === socketRequest)
    #expect(recorder.transactions.count == 3)

    await runtime.backend.emit(
        .webSocket(.closed(id: socketRequestID, timestamp: 13)),
        target: target
    )

    try await waitUntil { socketRequest.state == .finished && socketRequest.webSocket?.readyState == .closed }
    #expect(results.items.last === socketRequest)
    #expect(recorder.transactions.count == 3)
}

@MainActor
@Test
func clearNetworkRequestsPublishesResetAndIgnoresClearedEvents() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
    let controller = WebInspectorFetchedResultsController(fetchedResults: results)
    let recorder = FetchedResultsTransactionRecorder(stream: controller.transactions)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()

    let firstRequestID = Network.Request.ID("clear-first-request")
    let firstModelID = NetworkRequest.ID(firstRequestID)
    await runtime.backend.emit(
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
    await runtime.backend.emit(
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
    #expect(controller.snapshot.itemIDs == [firstModelID, secondModelID])

    context.clearNetworkRequests()

    try await recorder.waitForTransactionCount(3)
    let reset = try #require(recorder.transactions.last)
    #expect(reset.isReset)
    #expect(reset.oldSnapshot.itemIDs == [firstModelID, secondModelID])
    #expect(reset.newSnapshot.itemIDs == [])
    #expect(reset.sectionChanges == [])
    #expect(reset.itemChanges == [])
    #expect(controller.snapshot.itemIDs == [])
    #expect(results.items.isEmpty)
    #expect(context.registeredRequest(for: firstModelID) == nil)
    #expect(context.registeredRequest(for: secondModelID) == nil)

    await runtime.backend.emit(
        .responseReceived(
            id: firstRequestID,
            response: Network.Response(status: 200),
            resourceType: .fetch,
            timestamp: 3
        ),
        target: target
    )
    await runtime.backend.emit(
        .dataReceived(id: firstRequestID, dataLength: 7, encodedDataLength: 4, timestamp: 4),
        target: target
    )
    await runtime.backend.emit(
        .loadingFinished(id: secondRequestID, timestamp: 5, sourceMapURL: nil, metrics: nil),
        target: target
    )
    await runtime.backend.emit(
        .webSocket(.closed(id: secondRequestID, timestamp: 6)),
        target: target
    )
    for _ in 0..<10 {
        await Task.yield()
    }
    #expect(context.state == .attached)
    #expect(results.items.isEmpty)
    #expect(recorder.transactions.count == 3)

    await runtime.backend.emit(
        .requestWillBeSent(
            id: firstRequestID,
            request: Network.Request(id: firstRequestID, url: "https://example.com/reused", method: "GET"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 7
        ),
        target: target
    )

    try await recorder.waitForTransactionCount(4)
    let reusedRequest = try #require(results.items.first)
    #expect(reusedRequest.id == firstModelID)
    #expect(reusedRequest.url == "https://example.com/reused")
    #expect(context.registeredRequest(for: firstModelID) === reusedRequest)
}

@MainActor
@Test
func networkRequestExposesDataKitQueryableProperties() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()

    let apiRequestID = Network.Request.ID("queryable-api-request")
    await runtime.backend.emit(
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
    await runtime.backend.emit(
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
    await runtime.backend.emit(
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

@MainActor
@Test
func fetchedResultsControllerPublishesConsoleInsertUpdateAndDeleteTransactions() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let results: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()
    let controller = WebInspectorFetchedResultsController(fetchedResults: results)
    let recorder = FetchedResultsTransactionRecorder(stream: controller.transactions)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()

    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "log"),
            text: "first"
        )),
        target: target
    )

    try await recorder.waitForTransactionCount(1)
    let firstID = try #require(controller.snapshot.itemIDs.first)
    #expect(recorder.transactions.last?.itemChanges == [.insert(itemID: firstID, indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0))])

    await runtime.backend.emit(
        .messageRepeatCountUpdated(count: 3, timestamp: 2),
        target: target
    )

    try await recorder.waitForTransactionCount(2)
    #expect(recorder.transactions.last?.itemChanges == [.update(itemID: firstID, indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0))])

    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "log"),
            text: "second"
        )),
        target: target
    )

    try await recorder.waitForTransactionCount(3)
    let secondID = try #require(controller.snapshot.itemIDs.last)
    #expect(recorder.transactions.last?.itemChanges == [.insert(itemID: secondID, indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 1))])

    await runtime.backend.emit(
        .messagesCleared(reason: Console.ClearReason(rawValue: "console-api")),
        target: target
    )

    try await recorder.waitForTransactionCount(4)
    #expect(recorder.transactions.last?.itemChanges == [
        .delete(itemID: secondID, indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 1)),
        .delete(itemID: firstID, indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)),
    ])
    #expect(controller.snapshot.itemIDs == [])
}

@MainActor
@Test
func fetchedResultsCanBeSectionedByStringKeyPath() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults(sectionBy: \.method)
    let controller = WebInspectorFetchedResultsController(fetchedResults: results)
    let recorder = FetchedResultsTransactionRecorder(stream: controller.transactions)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()

    let getID = Network.Request.ID("sectioned-get")
    await runtime.backend.emit(
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
    #expect(controller.snapshot.sectionIDs == [WebInspectorFetchSectionID(rawValue: "GET")])
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
    await runtime.backend.emit(
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
    await runtime.backend.emit(
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

@MainActor
@Test
func fetchedResultsCanBeSectionedByRawRepresentableKeyPath() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let results: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults(sectionBy: \.level)

    await runtime.backend.emit(
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

@MainActor
@Test
func fetchedResultsTransactionDiffsMovesByItemID() {
    let first = NetworkRequest.ID(Network.Request.ID("first"))
    let second = NetworkRequest.ID(Network.Request.ID("second"))
    let oldSnapshot = WebInspectorFetchedResultsSnapshot(itemIDs: [first, second])
    let newSnapshot = WebInspectorFetchedResultsSnapshot(itemIDs: [second, first])

    let transaction = WebInspectorFetchedResultsTransaction<NetworkRequest>(
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
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let elementID = DOM.Node.ID("styled-node")

    await runtime.backend.emit(
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

    await enqueueCSSStyleReplies(on: runtime.backend)

    context.select(element)

    let styles = try #require(element.elementStyles)
    #expect(styles.phase == .loading)
    try await waitUntil { styles.phase == .loaded }
    #expect(styles.sections.map(\.title) == [".card"])
    #expect(styles.sections.map(\.kind) == [.rule])
    #expect(styles.computedProperties.map(\.name) == ["display"])

    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "enable")) == false)
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "getMatchedStylesForNode")))
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "getInlineStylesForNode")))
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "getComputedStyleForNode")))
}

@MainActor
@Test
func selectingNonElementDOMNodeDoesNotRequestCSSStyles() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)

    context.select(document)
    for _ in 0..<10 {
        await Task.yield()
    }

    #expect(document.elementStyles == nil)
    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "getMatchedStylesForNode")) == false)
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "getComputedStyleForNode")) == false)
}

@MainActor
@Test
func cssEventsAndSelectedDOMMutationsMarkSelectedStylesStale() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let selectedID = DOM.Node.ID("selected")
    let otherID = DOM.Node.ID("other")

    await runtime.backend.emit(
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

    await enqueueCSSStyleReplies(on: runtime.backend)
    context.select(selected)
    let styles = try #require(selected.elementStyles)
    try await waitUntil { styles.phase == .loaded }

    func reloadSelectedStyles() async throws {
        await enqueueCSSStyleReplies(on: runtime.backend)
        context.select(selected)
        try await waitUntil { styles.phase == .loaded }
    }

    await runtime.backend.emit(.styleSheetChanged, target: target)
    try await waitUntil { styles.phase == .needsRefresh }

    try await reloadSelectedStyles()

    await runtime.backend.emit(
        .styleSheetAdded(CSS.StyleSheetHeader(
            styleSheetID: CSS.StyleSheet.ID("sheet-1"),
            origin: CSS.Origin(rawValue: "author")
        )),
        target: target
    )
    try await waitUntil { styles.phase == .needsRefresh }

    try await reloadSelectedStyles()

    await runtime.backend.emit(.styleSheetRemoved(CSS.StyleSheet.ID("sheet-1")), target: target)
    try await waitUntil { styles.phase == .needsRefresh }

    try await reloadSelectedStyles()

    await runtime.backend.emit(.mediaQueryResultChanged, target: target)
    try await waitUntil { styles.phase == .needsRefresh }

    try await reloadSelectedStyles()

    await runtime.backend.emit(.attributeModified(otherID, name: "class", value: "ignored"), target: target)
    for _ in 0..<10 {
        await Task.yield()
    }
    #expect(styles.phase == .loaded)

    await runtime.backend.emit(.nodeLayoutFlagsChanged(otherID), target: target)
    for _ in 0..<10 {
        await Task.yield()
    }
    #expect(styles.phase == .loaded)

    await runtime.backend.emit(.nodeLayoutFlagsChanged(selectedID), target: target)
    try await waitUntil { styles.phase == .needsRefresh }

    try await reloadSelectedStyles()

    await runtime.backend.emit(.attributeModified(selectedID, name: "class", value: "changed"), target: target)
    try await waitUntil { styles.phase == .needsRefresh }
}

@MainActor
@Test
func cssInvalidationDuringStyleFetchIsNotOverwrittenByStaleResult() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let elementID = DOM.Node.ID("styled-node")
    let computedGate = WebInspectorTestGate()

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )
    let element = try await waitForChild(in: context)

    await runtime.backend.enqueue(
        CSS.MatchedStyles(matchedRules: [
            CSS.Rule(
                selectorList: CSS.Rule.SelectorList(selectors: [".card"], text: ".card"),
                origin: CSS.Origin(rawValue: "regular"),
                style: CSS.Style(id: CSS.Style.ID("style-1"))
            )
        ]),
        for: "CSS",
        method: "getMatchedStylesForNode"
    )
    await runtime.backend.enqueue(CSS.InlineStyles(), for: "CSS", method: "getInlineStylesForNode")
    await runtime.backend.hold(domain: "CSS", method: "getComputedStyleForNode", gate: computedGate)
    await runtime.backend.enqueue(
        [CSS.ComputedProperty(name: "display", value: "grid")],
        for: "CSS",
        method: "getComputedStyleForNode"
    )

    context.select(element)
    let styles = try #require(element.elementStyles)
    try await waitUntil {
        await runtime.backend.recordedCommands().contains(
            RecordedCommand(domain: "CSS", method: "getComputedStyleForNode")
        )
    }

    await runtime.backend.emit(.styleSheetChanged, target: target)
    try await waitUntil { styles.phase == .needsRefresh }

    await computedGate.open()
    for _ in 0..<10 {
        await Task.yield()
    }
    #expect(styles.phase == .needsRefresh)
    #expect(styles.computedProperties.isEmpty)
}

@MainActor
@Test
func selectingDOMNodeLoadsInlineAndAttributesStyleSections() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let elementID = DOM.Node.ID("styled-node")

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )
    let element = try await waitForChild(in: context)

    await runtime.backend.enqueue(
        CSS.MatchedStyles(matchedRules: [
            CSS.Rule(
                selectorList: CSS.Rule.SelectorList(selectors: [".card"], text: ".card"),
                origin: CSS.Origin(rawValue: "regular"),
                style: CSS.Style(id: CSS.Style.ID("style-rule"), cssText: "display: grid;")
            )
        ]),
        for: "CSS",
        method: "getMatchedStylesForNode"
    )
    await runtime.backend.enqueue(
        CSS.InlineStyles(
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
        ),
        for: "CSS",
        method: "getInlineStylesForNode"
    )
    await runtime.backend.enqueue(
        [CSS.ComputedProperty(name: "display", value: "grid")],
        for: "CSS",
        method: "getComputedStyleForNode"
    )

    context.select(element)

    let styles = try #require(element.elementStyles)
    try await waitUntil { styles.phase == .loaded }
    #expect(styles.sections.map(\.kind) == [.inlineStyle, .rule, .attributesStyle])
    #expect(styles.sections.map(\.title) == ["element.style", ".card", "Attributes"])
    #expect(styles.sections.map(\.isEditable) == [true, false, false])
}

@MainActor
@Test
func styleSheetChangedWhileHydrationActiveTriggersImmediateRefetch() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let elementID = DOM.Node.ID("styled-node")

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )
    let element = try await waitForChild(in: context)

    context.setStyleHydrationActive(true)
    await enqueueCSSStyleReplies(on: runtime.backend)
    context.select(element)
    let styles = try #require(element.elementStyles)
    try await waitUntil { styles.phase == .loaded }

    await enqueueCSSStyleReplies(on: runtime.backend)
    await runtime.backend.emit(.styleSheetChanged, target: target)

    try await waitUntil {
        await matchedStylesCommandCount(on: runtime.backend) == 2
    }
    try await waitUntil { styles.phase == .loaded }
}

@MainActor
@Test
func styleSheetChangedWhileHydrationInactiveDefersRefetchUntilActivation() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let elementID = DOM.Node.ID("styled-node")

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )
    let element = try await waitForChild(in: context)

    await enqueueCSSStyleReplies(on: runtime.backend)
    context.select(element)
    let styles = try #require(element.elementStyles)
    try await waitUntil { styles.phase == .loaded }

    await runtime.backend.emit(.styleSheetChanged, target: target)
    try await waitUntil { styles.phase == .needsRefresh }
    for _ in 0..<10 {
        await Task.yield()
    }
    #expect(styles.phase == .needsRefresh)
    #expect(await matchedStylesCommandCount(on: runtime.backend) == 1)

    await enqueueCSSStyleReplies(on: runtime.backend)
    context.setStyleHydrationActive(true)

    try await waitUntil { styles.phase == .loaded }
    #expect(await matchedStylesCommandCount(on: runtime.backend) == 2)
}

@MainActor
@Test
func requestSetCSSPropertyTogglesDeclarationAndRefreshesStyles() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let elementID = DOM.Node.ID("styled-node")

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )
    let element = try await waitForChild(in: context)

    context.setStyleHydrationActive(true)
    await enqueueCSSStyleReplies(on: runtime.backend)
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
    await runtime.backend.enqueue(disabledStyle, for: "CSS", method: "setStyleText")
    await runtime.backend.enqueue(
        CSS.MatchedStyles(matchedRules: [
            CSS.Rule(
                selectorList: CSS.Rule.SelectorList(selectors: [".card"], text: ".card"),
                origin: CSS.Origin(rawValue: "regular"),
                style: disabledStyle
            )
        ]),
        for: "CSS",
        method: "getMatchedStylesForNode"
    )
    await runtime.backend.enqueue(CSS.InlineStyles(), for: "CSS", method: "getInlineStylesForNode")
    await runtime.backend.enqueue(
        [CSS.ComputedProperty(name: "display", value: "grid")],
        for: "CSS",
        method: "getComputedStyleForNode"
    )

    let propertyID = try #require(styles.sections.first?.style.properties.first?.id)
    #expect(context.requestSetCSSProperty(propertyID, enabled: false))

    try await waitUntil {
        await matchedStylesCommandCount(on: runtime.backend) == 2
    }
    try await waitUntil { styles.phase == .loaded }

    let commands = await runtime.backend.recordedCommands()
    let setStyleText = try #require(commands.last { $0 == RecordedCommand(domain: "CSS", method: "setStyleText") })
    let payload = try #require(setStyleText.payload.cast(as: CSS.SetStyleTextPayload.self))
    #expect(payload.id == CSS.Style.ID("style-1"))
    #expect(payload.text == "/* display: grid; */")

    let property = try #require(styles.sections.first?.style.properties.first)
    #expect(property.status == .disabled)
    #expect(property.isModifiedByInspector)
}

@MainActor
@Test
func requestSetCSSPropertyRefusesStaleAndNonEditableProperties() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let elementID = DOM.Node.ID("styled-node")

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )
    let element = try await waitForChild(in: context)

    await runtime.backend.enqueue(
        CSS.MatchedStyles(matchedRules: [
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
        ]),
        for: "CSS",
        method: "getMatchedStylesForNode"
    )
    await runtime.backend.enqueue(CSS.InlineStyles(), for: "CSS", method: "getInlineStylesForNode")
    await runtime.backend.enqueue(
        [CSS.ComputedProperty(name: "display", value: "grid")],
        for: "CSS",
        method: "getComputedStyleForNode"
    )
    context.select(element)
    let styles = try #require(element.elementStyles)
    try await waitUntil { styles.phase == .loaded }

    let userAgentSection = try #require(styles.sections.first { $0.title == "div" })
    #expect(userAgentSection.isEditable == false)
    let userAgentPropertyID = try #require(userAgentSection.style.properties.first?.id)
    #expect(context.requestSetCSSProperty(userAgentPropertyID, enabled: false) == false)

    let editableSection = try #require(styles.sections.first { $0.title == ".card" })
    let editablePropertyID = try #require(editableSection.style.properties.first?.id)

    await runtime.backend.emit(.styleSheetChanged, target: target)
    try await waitUntil { styles.phase == .needsRefresh }
    #expect(context.requestSetCSSProperty(editablePropertyID, enabled: false) == false)

    for _ in 0..<10 {
        await Task.yield()
    }
    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "setStyleText")) == false)
}

@MainActor
@Test
func removingLoadedChildPurgesDescendantsFromIdentityMap() async throws {
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
    try await waitUntil { context.rootNode != nil }

    await runtime.backend.emit(
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

    await runtime.backend.emit(
        .childNodeRemoved(parent: documentID, node: childID),
        target: target
    )

    try await waitUntil {
        context.node(for: DOMNode.ID(childID)) == nil
            && context.node(for: DOMNode.ID(grandchildID)) == nil
    }
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
    try await waitUntil { context.rootNode != nil }

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

    try await waitUntil { context.node(for: DOMNode.ID(movedChildID)) != nil }
    let movedChild = try #require(context.node(for: DOMNode.ID(movedChildID)))

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

    try await waitUntil {
        context.node(for: DOMNode.ID(oldParentID)) == nil
            && context.node(for: DOMNode.ID(newParentID)) != nil
    }
    #expect(context.node(for: DOMNode.ID(movedChildID)) === movedChild)
}

@MainActor
@Test
func setChildNodesPrunesOmittedDescendantsWhenReusingChildNode() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let documentID = DOM.Node.ID("document")
    let childID = DOM.Node.ID("child")
    let removedSpanID = DOM.Node.ID("removed-span")
    let removedEmID = DOM.Node.ID("removed-em")

    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: documentID, nodeType: 9, nodeName: "#document")
    )

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitForStartupSubscribers(runtime: runtime, target: target)
    try await waitUntil { context.rootNode != nil }

    await runtime.backend.emit(
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

    await runtime.backend.emit(
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
    try await waitUntil { context.rootNode != nil }

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

    try await waitUntil { context.node(for: DOMNode.ID(grandchildID)) != nil }
    let grandchild = try #require(context.node(for: DOMNode.ID(grandchildID)))

    await runtime.backend.emit(
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

@MainActor
@Test
func closeDuringStartupKeepsContextDetached() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let gate = WebInspectorTestGate()
    let documentID = DOM.Node.ID("document")

    await runtime.backend.hold(domain: "DOM", method: "getDocument", gate: gate)
    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: documentID, nodeType: 9, nodeName: "#document")
    )
    await enqueueDomainDisableReplies(on: runtime.backend)

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitUntil {
        await runtime.backend.recordedCommands()
            .contains(RecordedCommand(domain: "DOM", method: "getDocument"))
    }

    await container.close()
    #expect(context.state == .detached)

    await gate.open()
    for _ in 0..<10 {
        await Task.yield()
    }

    #expect(context.state == .detached)
    #expect(context.rootNode == nil)

    let commands = await runtime.backend.recordedCommands()
    #expect(commands == Array(startupCommands.prefix(5)) + [
        RecordedCommand(domain: "Runtime", method: "disable"),
        RecordedCommand(domain: "Network", method: "disable"),
        RecordedCommand(domain: "Inspector", method: "disable"),
    ])
}

@MainActor
@Test
func domainEnablementReleaseDuringPendingEnableDisablesAfterEnableCompletes() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let registry = WebInspectorDomainEnablementRegistry()
    let gate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "Runtime", method: "enable", gate: gate)

    let acquireTask = Task {
        try await registry.acquire(.runtime, on: target)
    }

    try await waitUntil {
        await runtime.backend.recordedCommands() == [
            RecordedCommand(domain: "Runtime", method: "enable")
        ]
    }

    let releaseTask = Task {
        await registry.release(.runtime, on: target)
    }

    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    await runtime.backend.enqueue((), for: "Runtime", method: "disable")
    await gate.open()

    try await acquireTask.value
    #expect(await releaseTask.value == nil)

    let commands = await runtime.backend.recordedCommands()
    #expect(commands == [
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Runtime", method: "disable"),
    ])
}

@MainActor
@Test
func networkEventsPopulateAllRequestsInOrder() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("request-1")

    await runtime.backend.emit(
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
    await runtime.backend.emit(
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
    await runtime.backend.emit(
        .dataReceived(id: requestID, dataLength: 12, encodedDataLength: 5, timestamp: 3),
        target: target
    )
    await runtime.backend.emit(
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

@MainActor
@Test
func responseReceivedWithoutRequestWillBeSentCreatesRequest() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("response-first-request")

    await runtime.backend.emit(
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
    await runtime.backend.emit(
        .dataReceived(id: requestID, dataLength: 9, encodedDataLength: 4, timestamp: 3),
        target: target
    )
    await runtime.backend.emit(
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

@MainActor
@Test
func loadingFinishedStoresTerminalMetadataAndOverridesDataTotals() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("request-with-terminal-metadata")

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(id: requestID, url: "https://example.com/app.js", method: "GET"),
            resourceType: .script,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    await runtime.backend.emit(
        .dataReceived(id: requestID, dataLength: 5, encodedDataLength: 2, timestamp: 2),
        target: target
    )
    await runtime.backend.emit(
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

@MainActor
@Test
func loadingFinishedClampsNegativeMetricTotals() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("request-with-negative-terminal-metrics")

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(id: requestID, url: "https://example.com/negative", method: "GET"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    await runtime.backend.emit(
        .dataReceived(id: requestID, dataLength: 5, encodedDataLength: 4, timestamp: 2),
        target: target
    )
    await runtime.backend.emit(
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

@MainActor
@Test
func repeatedRequestWillBeSentClearsStaleResponseFields() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("redirected-request")

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(id: requestID, url: "https://example.com/redirect", method: "GET"),
            resourceType: .document,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    await runtime.backend.emit(
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

    await runtime.backend.emit(
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

@MainActor
@Test
func completedRequestDoesNotTreatLaterRequestWillBeSentAsRedirect() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("reused-request")

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(id: requestID, url: "https://example.com/first", method: "GET"),
            resourceType: .document,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    await runtime.backend.emit(
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

    await runtime.backend.emit(
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

@MainActor
@Test
func loadingFailedStoresFailureTimestampAndClampsDataLength() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("failed-request")

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(id: requestID, url: "https://example.com/fail", method: "GET"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    await runtime.backend.emit(
        .dataReceived(id: requestID, dataLength: -10, encodedDataLength: -20, timestamp: 2),
        target: target
    )
    await runtime.backend.emit(
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

@MainActor
@Test
func memoryCacheEventCreatesFinishedCachedRequestFromResponse() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("cached-request")

    await runtime.backend.emit(
        .requestServedFromMemoryCache(
            id: requestID,
            response: Network.Response(
                url: "https://example.com/cached.css",
                status: 200,
                statusText: "OK",
                mimeType: "text/css",
                headers: ["Content-Type": "text/css"],
                source: Network.Source(rawValue: "memory-cache"),
                requestHeaders: ["Accept": "text/css"]
            ),
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
    #expect(request.resourceType == nil)
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
    #expect(request.decodedDataLength == 0)
    #expect(request.encodedDataLength == 0)
    #expect(request.responseBody.phase == .available)
    #expect(context.registeredRequest(for: request.id) === request)
}

@MainActor
@Test
func memoryCacheEventWithoutURLForNewRequestIsSkipped() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)

    await runtime.backend.emit(
        .requestServedFromMemoryCache(
            id: Network.Request.ID("cached-request-without-url"),
            response: Network.Response(status: 200),
            timestamp: 5
        ),
        target: target
    )
    await runtime.backend.emit(
        .requestServedFromMemoryCache(
            id: Network.Request.ID("cached-request-with-url"),
            response: Network.Response(url: "https://example.com/cached.css", status: 200),
            timestamp: 6
        ),
        target: target
    )

    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
    try await waitUntil { results.items.count == 1 }
    #expect(results.items.first?.url == "https://example.com/cached.css")
    #expect(context.state == .attached)
}

@MainActor
@Test
func webSocketCreatedCreatesRequestWithConnectingState() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("websocket-created")

    await runtime.backend.emit(
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

@MainActor
@Test
func webSocketCreatedPreservesExistingNetworkLifecycleMetadata() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("websocket-created-after-request")

    await runtime.backend.emit(
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
    await runtime.backend.emit(
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
    await runtime.backend.emit(
        .dataReceived(id: requestID, dataLength: 7, encodedDataLength: 3, timestamp: 3),
        target: target
    )

    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
    try await waitUntil { results.items.first?.decodedDataLength == 7 }
    let request = try #require(results.items.first)
    let webSocket = try #require(request.webSocket)

    await runtime.backend.emit(
        .webSocket(.created(id: requestID, url: "wss://example.com/socket?created")),
        target: target
    )
    try await waitUntil { request.url == "wss://example.com/socket?created" }
    await runtime.backend.emit(
        .webSocket(.handshakeRequest(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "wss://example.com/socket?created",
                method: "GET",
                headers: ["Upgrade": "websocket"]
            ),
            timestamp: nil
        )),
        target: target
    )
    await runtime.backend.emit(
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
    #expect(request.method == "GET")
    #expect(request.requestHeaders["Upgrade"] == "websocket")
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

@MainActor
@Test
func webSocketLifecycleStoresHandshakeFramesErrorAndClosedState() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("websocket-lifecycle")

    await runtime.backend.emit(
        .webSocket(.created(id: requestID, url: "wss://example.com/socket")),
        target: target
    )
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
    try await waitUntil { results.items.count == 1 }
    let request = try #require(results.items.first)

    await runtime.backend.emit(
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

    await runtime.backend.emit(
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

    await runtime.backend.emit(
        .webSocket(.frameSent(
            id: requestID,
            frame: Network.WebSocketFrame(opcode: 1, mask: true, payloadData: "hello", payloadLength: 5),
            timestamp: 3
        )),
        target: target
    )
    await runtime.backend.emit(
        .webSocket(.frameReceived(
            id: requestID,
            frame: Network.WebSocketFrame(opcode: 1, mask: false, payloadData: "world", payloadLength: 5),
            timestamp: 4
        )),
        target: target
    )
    await runtime.backend.emit(
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

    await runtime.backend.emit(
        .webSocket(.closed(id: requestID, timestamp: 6)),
        target: target
    )
    try await waitUntil {
        request.webSocket?.readyState == .closed && request.state == .finished
    }
    #expect(request.finishedOrFailedTimestamp == 6)
}

@MainActor
@Test
func webSocketEventForUnknownRequestIsSkipped() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("missing-websocket")

    await runtime.backend.emit(
        .webSocket(.handshakeResponse(
            id: requestID,
            response: Network.Response(status: 101),
            timestamp: 1
        )),
        target: target
    )
    await runtime.backend.emit(
        .webSocket(.created(id: requestID, url: "wss://example.com/socket")),
        target: target
    )

    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
    try await waitUntil { results.items.count == 1 }
    #expect(results.items.first?.webSocket?.readyState == .connecting)
    #expect(results.items.first?.webSocket?.handshakeResponse == nil)
    #expect(context.state == .attached)
}

@MainActor
@Test
func webSocketOtherEventDoesNotMutateRequests() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()

    await runtime.backend.emit(
        .webSocket(.other(RawEvent(domain: "Network", method: "webSocketFutureEvent"))),
        target: target
    )
    for _ in 0..<10 {
        await Task.yield()
    }

    #expect(results.items.isEmpty)
    #expect(context.state == .attached)
}

@MainActor
@Test
func requestPostDataCreatesNetworkBodyWithFormRepresentation() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("form-request")

    await runtime.backend.emit(
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

@MainActor
@Test
func responseRequestHeadersRefreshRequestBodyHints() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("form-request-hints")

    await runtime.backend.emit(
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

    await runtime.backend.emit(
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

@MainActor
@Test
func responseBodyPublishesHintsAndFetchLifecycle() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("json-response-body")

    await runtime.backend.emit(
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
    await runtime.backend.emit(
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

    await runtime.backend.emit(
        .loadingFinished(id: requestID, timestamp: 3, sourceMapURL: nil, metrics: nil),
        target: target
    )
    try await waitUntil { request.canFetchResponseBody }

    await runtime.backend.enqueue(
        Network.Body(data: #"{"ok":true}"#, base64Encoded: false),
        for: "Network",
        method: "getResponseBody"
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

    let commandsBeforeSecondFetch = await runtime.backend.recordedCommands()
    await request.fetchResponseBody()
    let commandsAfterSecondFetch = await runtime.backend.recordedCommands()
    #expect(commandsAfterSecondFetch == commandsBeforeSecondFetch)
}

@MainActor
@Test
func fetchResponseBodyStoresLoadedAndFailedPhases() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let loadedID = Network.Request.ID("loaded-request")
    let failedID = Network.Request.ID("failed-request")

    await emitFinishedRequest(id: loadedID, target: target, backend: runtime.backend)
    await emitFinishedRequest(id: failedID, target: target, backend: runtime.backend)

    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
    try await waitUntil {
        results.items.count == 2 && results.items.allSatisfy { $0.state == .finished }
    }
    let loadedRequest = try #require(results.items.first { $0.id == NetworkRequest.ID(loadedID) })
    let failedRequest = try #require(results.items.first { $0.id == NetworkRequest.ID(failedID) })

    await runtime.backend.enqueue(
        Network.Body(data: "hello", base64Encoded: false),
        for: "Network",
        method: "getResponseBody"
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
        Issue.record("Expected Network.getResponseBody command failure.")
        return
    }

    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "Network", method: "getResponseBody")))
}

@MainActor
@Test
func consoleEventsPopulateRepeatAndClearFetchedMessages() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("request-1")

    let results: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()
    await runtime.backend.emit(
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

    await runtime.backend.emit(
        .messageRepeatCountUpdated(count: 3, timestamp: 2),
        target: target
    )
    try await waitUntil { message.repeatCount == 3 }
    #expect(results.items.first === message)
    #expect(message.timestamp == 2)

    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "javascript"),
            level: Console.Level(rawValue: "error"),
            text: "second"
        )),
        target: target
    )
    try await waitUntil { results.items.count == 2 }
    #expect(results.items.map(\.text) == ["hello", "second"])

    await runtime.backend.enqueue((), for: "Runtime", method: "releaseObjectGroup")
    await runtime.backend.emit(
        .messagesCleared(reason: Console.ClearReason(rawValue: "console-api")),
        target: target
    )
    try await waitUntil { results.items.isEmpty }
    #expect(context.registeredMessage(for: message.id) == nil)
    try await waitUntil {
        await runtime.backend.recordedCommands()
            .contains(RecordedCommand(domain: "Runtime", method: "releaseObjectGroup"))
    }
}

@MainActor
@Test
func consoleMessageParametersRegisterRuntimeObjects() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let objectID = Runtime.RemoteObject.ID("console-object")
    let results: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()

    await runtime.backend.emit(
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

    await runtime.backend.emit(
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

@MainActor
@Test
func consoleMessagesClearedReleasesConsoleRuntimeObjects() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let objectID = Runtime.RemoteObject.ID("console-stale-object")
    let results: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()

    await runtime.backend.emit(
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
    try await waitUntil { results.items.count == 1 }
    let message = try #require(results.items.first)
    let parameter = try #require(message.parameters.first)

    await runtime.backend.enqueue((), for: "Runtime", method: "releaseObjectGroup")
    await runtime.backend.emit(
        .messagesCleared(reason: Console.ClearReason(rawValue: "console-api")),
        target: target
    )

    try await waitUntil {
        await runtime.backend.recordedCommands()
            .contains(RecordedCommand(domain: "Runtime", method: "releaseObjectGroup"))
    }
    try await waitUntil { results.items.isEmpty }
    do {
        _ = try await parameter.properties()
        Issue.record("Expected cleared console RuntimeObject to be stale.")
    } catch let error as WebInspectorProxyError {
        #expect(error == .disconnected("RuntimeObject is not registered in this WebInspectorContext."))
    }
    #expect(context.state == .attached)
}

@MainActor
@Test
func evaluateRegistersRuntimeObjectInSelectedContext() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let contextID = Runtime.ExecutionContext.ID("main")
    let objectID = Runtime.RemoteObject.ID("evaluation-result")

    await runtime.backend.emit(
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

    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(
                id: objectID,
                kind: .string,
                description: "hello",
                value: .string("hello")
            ),
            wasThrown: true,
            savedResultIndex: 7
        ),
        for: "Runtime",
        method: "evaluate"
    )

    let result = try await context.evaluate("throw 'hello'", in: runtimeContext)
    #expect(result.isException)
    #expect(result.object.kind == .string)
    #expect(result.object.value == .string("hello"))
    #expect(result.object.description == "hello")

    let commands = await runtime.backend.recordedCommands()
    let command = try #require(commands.last { $0.domain == "Runtime" && $0.method == "evaluate" })
    let payload = try #require(command.payload.cast(as: Runtime.EvaluatePayload.self))
    #expect(payload.expression == "throw 'hello'")
    #expect(payload.context == contextID)
}

@MainActor
@Test
func runtimeObjectPropertiesAndCollectionEntriesUseRuntimeCommands() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let objectID = Runtime.RemoteObject.ID("root-object")
    let childID = Runtime.RemoteObject.ID("child-object")
    let entryValueID = Runtime.RemoteObject.ID("entry-value")

    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(id: objectID, kind: .object, description: "root")
        ),
        for: "Runtime",
        method: "evaluate"
    )
    let evaluation = try await context.evaluate("window")

    await runtime.backend.enqueue(
        [
            Runtime.PropertyDescriptor(
                name: "answer",
                value: Runtime.RemoteObject(id: nil, kind: .number, description: "42", value: .number(42))
            ),
            Runtime.PropertyDescriptor(
                name: "child",
                value: Runtime.RemoteObject(id: childID, kind: .object, description: "child")
            ),
        ],
        for: "Runtime",
        method: "getProperties"
    )

    let properties = try await evaluation.object.properties()
    #expect(properties.count == 2)
    #expect(properties[0].name == "answer")
    #expect(properties[0].value == "42")
    #expect(properties[0].object == nil)
    let child = try #require(properties[1].object)
    #expect(child.description == "child")

    await runtime.backend.enqueue(
        [
            Runtime.CollectionEntry(
                key: Runtime.RemoteObject(id: nil, kind: .string, description: "key", value: .string("key")),
                value: Runtime.RemoteObject(id: entryValueID, kind: .object, description: "entry value")
            )
        ],
        for: "Runtime",
        method: "getCollectionEntries"
    )

    let entries = try await evaluation.object.collectionEntries()
    #expect(entries.count == 1)
    #expect(entries[0].key?.value == .string("key"))
    #expect(entries[0].value?.description == "entry value")

    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "Runtime", method: "getProperties")))
    #expect(commands.contains(RecordedCommand(domain: "Runtime", method: "getCollectionEntries")))
}

@MainActor
@Test
func staleRuntimeObjectThrowsWithoutFailingContext() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let contextID = Runtime.ExecutionContext.ID("main")
    let objectID = Runtime.RemoteObject.ID("stale-object")

    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(
            id: contextID,
            name: "Main",
            kind: .normal
        )),
        target: target
    )
    try await waitUntil { context.executionContexts.count == 1 }

    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(id: objectID, kind: .object, description: "stale")
        ),
        for: "Runtime",
        method: "evaluate"
    )
    let evaluation = try await context.evaluate("window")

    await runtime.backend.emit(.executionContextsCleared(target: target.id), target: target)
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

@MainActor
@Test
func runtimeEventsPopulateContextsAndFallbackSelection() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let mainID = Runtime.ExecutionContext.ID("main")
    let utilityID = Runtime.ExecutionContext.ID("utility")

    await runtime.backend.emit(
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

    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(
            id: mainID,
            name: "Main Updated",
            kind: .normal
        )),
        target: target
    )
    try await waitUntil { mainContext.name == "Main Updated" }
    #expect(context.executionContexts.first === mainContext)

    await runtime.backend.emit(
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

    await runtime.backend.emit(
        .executionContextDestroyed(utilityID),
        target: target
    )
    try await waitUntil {
        context.executionContexts.count == 1 && context.selectedContext === mainContext
    }
    #expect(context.executionContexts.first === mainContext)

    await runtime.backend.emit(
        .executionContextsCleared(target: target.id),
        target: target
    )
    try await waitUntil {
        context.executionContexts.isEmpty && context.selectedContext == nil
    }
}

@MainActor
private func startContext(
    runtime: WebInspectorProxyTestRuntime,
    document: DOM.Node = DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document")
) async throws -> (WebInspectorTarget, WebInspectorContext) {
    let target = try await runtime.proxy.waitForCurrentPage()
    await enqueueStartupReplies(on: runtime.backend, document: document)

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitForStartupSubscribers(runtime: runtime, target: target)
    try await waitUntil { context.state == .attached }
    return (target, context)
}

private var startupCommands: [RecordedCommand] {
    [
        RecordedCommand(domain: "Inspector", method: "enable"),
        RecordedCommand(domain: "Inspector", method: "initialized"),
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Network", method: "enable"),
        RecordedCommand(domain: "DOM", method: "getDocument"),
        RecordedCommand(domain: "Console", method: "enable"),
    ]
}

private var shutdownCommands: [RecordedCommand] {
    [
        RecordedCommand(domain: "Console", method: "disable"),
        RecordedCommand(domain: "Runtime", method: "disable"),
        RecordedCommand(domain: "Network", method: "disable"),
        RecordedCommand(domain: "Inspector", method: "disable"),
    ]
}

private func enqueueStartupReplies(
    on backend: WebInspectorTestBackend,
    document: DOM.Node = DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document")
) async {
    await enqueueDomainEnableReplies(on: backend)
    await backend.enqueue(document, for: "DOM", method: "getDocument")
}

private func enqueueDomainEnableReplies(on backend: WebInspectorTestBackend) async {
    await backend.enqueue((), for: "Inspector", method: "enable")
    await backend.enqueue((), for: "Inspector", method: "initialized")
    await backend.enqueue((), for: "Runtime", method: "enable")
    await backend.enqueue((), for: "Network", method: "enable")
    await backend.enqueue((), for: "Console", method: "enable")
}

private func enqueueDomainDisableReplies(on backend: WebInspectorTestBackend) async {
    await backend.enqueue((), for: "Console", method: "disable")
    await backend.enqueue((), for: "Runtime", method: "disable")
    await backend.enqueue((), for: "Network", method: "disable")
    await backend.enqueue((), for: "Inspector", method: "disable")
}

private func enqueueCSSStyleReplies(on backend: WebInspectorTestBackend) async {
    await backend.enqueue(
        CSS.MatchedStyles(matchedRules: [
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
            )
        ]),
        for: "CSS",
        method: "getMatchedStylesForNode"
    )
    await backend.enqueue(
        CSS.InlineStyles(),
        for: "CSS",
        method: "getInlineStylesForNode"
    )
    await backend.enqueue(
        [
            CSS.ComputedProperty(name: "display", value: "grid")
        ],
        for: "CSS",
        method: "getComputedStyleForNode"
    )
}

private func matchedStylesCommandCount(on backend: WebInspectorTestBackend) async -> Int {
    await backend.recordedCommands()
        .filter { $0 == RecordedCommand(domain: "CSS", method: "getMatchedStylesForNode") }
        .count
}

@MainActor
private func waitForStartupSubscribers(
    runtime: WebInspectorProxyTestRuntime,
    target: WebInspectorTarget
) async throws {
    try await runtime.backend.waitForSubscribers(domain: "DOM", target: target, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "Inspector", target: target, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "CSS", target: target, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "Network", target: target, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "Console", target: target, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "Runtime", target: target, count: 1)
}

private func emitFinishedRequest(
    id: Network.Request.ID,
    target: WebInspectorTarget,
    backend: WebInspectorTestBackend
) async {
    await backend.emit(
        .requestWillBeSent(
            id: id,
            request: Network.Request(id: id, url: "https://example.com/\(id)", method: "GET"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    await backend.emit(
        .responseReceived(
            id: id,
            response: Network.Response(status: 200, mimeType: "text/plain"),
            resourceType: .fetch,
            timestamp: 2
        ),
        target: target
    )
    await backend.emit(.loadingFinished(id: id, timestamp: 3, sourceMapURL: nil, metrics: nil), target: target)
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
private final class DOMTreeTransactionRecorder {
    private(set) var transactions: [DOMTreeTransaction] = []

    private var task: Task<Void, Never>?
    private var hasStarted = false

    init(stream: AsyncStream<DOMTreeTransaction>) {
        task = Task { @MainActor [weak self] in
            self?.hasStarted = true
            for await transaction in stream {
                self?.transactions.append(transaction)
            }
        }
    }

    func waitUntilStarted() async throws {
        try await waitUntil { self.hasStarted }
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
private final class FetchedResultsTransactionRecorder<Model: WebInspectorFetchableModel> {
    private(set) var transactions: [WebInspectorFetchedResultsTransaction<Model>] = []

    private var task: Task<Void, Never>?
    private var hasStarted = false

    init(stream: AsyncStream<WebInspectorFetchedResultsTransaction<Model>>) {
        task = Task { @MainActor [weak self] in
            self?.hasStarted = true
            for await transaction in stream {
                self?.transactions.append(transaction)
            }
        }
    }

    func waitUntilStarted() async throws {
        try await waitUntil { self.hasStarted }
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
