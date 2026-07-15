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
    try await context.dom.highlight(child.id)

    await runtime.backend.enqueue((), for: "DOM", method: "hideHighlight")
    try await context.dom.hideHighlight()

    await runtime.backend.enqueue((), for: "DOM", method: "undo")
    try await context.editHistory.undo()

    await runtime.backend.enqueue((), for: "DOM", method: "redo")
    try await context.editHistory.redo()

    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")
    try await context.dom.setInspectMode(enabled: true)
    #expect(context.isElementPickerEnabled)

    await enqueueCSSStyleReplies(on: runtime.backend)
    await runtime.backend.emit(.inspect(childID), target: target)
    try await waitUntil { context.selectedNode === child }
    try await waitUntil { child.elementStyles?.phase == .loaded }
    #expect(context.isElementPickerEnabled == false)

    await runtime.backend.enqueue((), for: "DOM", method: "setAttributeValue")
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    try await context.dom.setAttribute("class", value: "updated", on: parent.id)

    await runtime.backend.enqueue((), for: "DOM", method: "setOuterHTML")
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    try await context.dom.setOuterHTML("<span id=\"title\"></span>", of: child.id)

    await runtime.backend.enqueue((), for: "DOM", method: "removeNode")
    await runtime.backend.enqueue((), for: "DOM", method: "removeNode")
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    let deletion = try await context.dom.remove([parent.id, child.id])
    #expect(deletion.acceptedNodeIDs == [child.id, parent.id])
    #expect(context.selectedNode == nil)
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
func elementPickerInspectBeforeEnableContinuationCannotReactivatePicker() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let documentID = DOM.Node.ID("picker-race-document")
    let (target, context) = try await startContext(
        runtime: runtime,
        document: DOM.Node(id: documentID, nodeType: 9, nodeName: "#document")
    )
    let enableGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "DOM", method: "setInspectModeEnabled", gate: enableGate)
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")

    let enableTask = Task { @MainActor in
        try await context.setElementPickerEnabled(true)
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "setInspectModeEnabled",
        count: 1
    )

    await runtime.backend.emit(.inspect(documentID), target: target)
    try await waitUntil { context.selectedNode?.id == DOMNode.ID(documentID) }
    #expect(context.isElementPickerEnabled == false)

    await enableGate.open()
    try await enableTask.value

    #expect(context.isElementPickerEnabled == false)
}

@MainActor
@Test
func overlappingElementPickerEnableAndDisableLinearizeLatestIntent() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let enableGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "DOM", method: "setInspectModeEnabled", gate: enableGate)
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")

    let enableTask = Task { @MainActor in
        try await context.setElementPickerEnabled(true)
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "setInspectModeEnabled",
        count: 1
    )

    let disableTask = Task { @MainActor in
        try await context.setElementPickerEnabled(false)
    }
    await enableGate.open()

    try await enableTask.value
    try await disableTask.value

    let commands = await runtime.backend.recordedCommands().filter {
        $0.domain == "DOM" && $0.method == "setInspectModeEnabled"
    }
    #expect(commands.compactMap {
        $0.payload.cast(as: DOM.SetInspectModeEnabledPayload.self)?.enabled
    } == [true, false])
    #expect(context.isElementPickerEnabled == false)
}

@MainActor
@Test
func unavailableElementPickerRequestDoesNotChangeNextToggleIntent() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let unavailableError = WebInspectorProxyError.disconnected(
        "WebInspectorDataKit has no current page target."
    )

    await #expect(throws: unavailableError) {
        try await context.setElementPickerEnabled(true)
    }
    await #expect(throws: unavailableError) {
        try await context.toggleElementPickerEnabled()
    }

    #expect(context.elementPickerDesiredStateForTesting?.isEnabled == false)
    #expect(context.isElementPickerEnabled == false)
}

@MainActor
@Test
func rapidElementPickerTogglesFlipPendingIntent() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let enableGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "DOM", method: "setInspectModeEnabled", gate: enableGate)
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")

    let enableTask = Task { @MainActor in
        try await context.toggleElementPickerEnabled()
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "setInspectModeEnabled",
        count: 1
    )
    let firstDesiredStateID = try #require(context.elementPickerDesiredStateForTesting?.id)

    let disableTask = Task { @MainActor in
        try await context.toggleElementPickerEnabled()
    }
    try await waitUntil {
        context.elementPickerDesiredStateForTesting?.id != firstDesiredStateID
            && context.elementPickerDesiredStateForTesting?.isEnabled == false
    }
    await enableGate.open()

    try await enableTask.value
    try await disableTask.value

    let commands = await runtime.backend.recordedCommands().filter {
        $0.domain == "DOM" && $0.method == "setInspectModeEnabled"
    }
    #expect(commands.compactMap {
        $0.payload.cast(as: DOM.SetInspectModeEnabledPayload.self)?.enabled
    } == [true, false])
    #expect(context.isElementPickerEnabled == false)
}

@MainActor
@Test
func rapidElementPickerEnableDisableEnableAppliesOnlyLatestIntent() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let enableGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "DOM", method: "setInspectModeEnabled", gate: enableGate)
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")

    let firstEnableTask = Task { @MainActor in
        try await context.toggleElementPickerEnabled()
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "setInspectModeEnabled",
        count: 1
    )
    let firstDesiredStateID = try #require(context.elementPickerDesiredStateForTesting?.id)

    let disableTask = Task { @MainActor in
        try await context.toggleElementPickerEnabled()
    }
    try await waitUntil {
        context.elementPickerDesiredStateForTesting?.id != firstDesiredStateID
            && context.elementPickerDesiredStateForTesting?.isEnabled == false
    }
    let disableDesiredStateID = try #require(context.elementPickerDesiredStateForTesting?.id)

    let latestEnableTask = Task { @MainActor in
        try await context.toggleElementPickerEnabled()
    }
    try await waitUntil {
        context.elementPickerDesiredStateForTesting?.id != disableDesiredStateID
            && context.elementPickerDesiredStateForTesting?.isEnabled == true
    }
    await enableGate.open()

    try await firstEnableTask.value
    try await disableTask.value
    try await latestEnableTask.value

    let commands = await runtime.backend.recordedCommands().filter {
        $0.domain == "DOM" && $0.method == "setInspectModeEnabled"
    }
    #expect(commands.compactMap {
        $0.payload.cast(as: DOM.SetInspectModeEnabledPayload.self)?.enabled
    } == [true])
    #expect(context.isElementPickerEnabled)
}

@MainActor
@Test
func cancellingLatestPickerIntentRestoresEarlierPendingIntent() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let enableGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "DOM", method: "setInspectModeEnabled", gate: enableGate)
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")

    let firstEnableTask = Task { @MainActor in
        try await context.toggleElementPickerEnabled()
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "setInspectModeEnabled",
        count: 1
    )
    let firstDesiredStateID = try #require(context.elementPickerDesiredStateForTesting?.id)

    let disableTask = Task { @MainActor in
        try await context.toggleElementPickerEnabled()
    }
    try await waitUntil {
        context.elementPickerDesiredStateForTesting?.id != firstDesiredStateID
            && context.elementPickerDesiredStateForTesting?.isEnabled == false
    }
    let disableDesiredStateID = try #require(context.elementPickerDesiredStateForTesting?.id)

    let cancelledEnableTask = Task { @MainActor in
        try await context.toggleElementPickerEnabled()
    }
    try await waitUntil {
        context.elementPickerDesiredStateForTesting?.id != disableDesiredStateID
            && context.elementPickerDesiredStateForTesting?.isEnabled == true
    }
    cancelledEnableTask.cancel()
    await enableGate.open()

    try await firstEnableTask.value
    try await disableTask.value
    await #expect(throws: CancellationError.self) {
        try await cancelledEnableTask.value
    }

    let commands = await runtime.backend.recordedCommands().filter {
        $0.domain == "DOM" && $0.method == "setInspectModeEnabled"
    }
    #expect(commands.compactMap {
        $0.payload.cast(as: DOM.SetInspectModeEnabledPayload.self)?.enabled
    } == [true, false])
    #expect(context.isElementPickerEnabled == false)
}

@MainActor
@Test
func cancellingSupersededPickerCallerDoesNotCancelLatestSameIntent() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let enableGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "DOM", method: "setInspectModeEnabled", gate: enableGate)
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")

    let firstEnableTask = Task { @MainActor in
        try await context.setElementPickerEnabled(true)
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "setInspectModeEnabled",
        count: 1
    )
    let firstDesiredStateID = try #require(context.elementPickerDesiredStateForTesting?.id)

    let latestEnableTask = Task { @MainActor in
        try await context.setElementPickerEnabled(true)
    }
    try await waitUntil {
        context.elementPickerDesiredStateForTesting?.id != firstDesiredStateID
            && context.elementPickerDesiredStateForTesting?.isEnabled == true
    }
    firstEnableTask.cancel()
    await enableGate.open()

    await #expect(throws: CancellationError.self) {
        try await firstEnableTask.value
    }
    try await latestEnableTask.value

    let commands = await runtime.backend.recordedCommands().filter {
        $0.domain == "DOM" && $0.method == "setInspectModeEnabled"
    }
    #expect(commands.compactMap {
        $0.payload.cast(as: DOM.SetInspectModeEnabledPayload.self)?.enabled
    } == [true])
    #expect(context.isElementPickerEnabled)
}

@MainActor
@Test
func coalescedElementPickerCallersShareFailureWithoutRetry() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let enableGate = WebInspectorTestGate()
    let enableError = WebInspectorProxyError.commandFailed(
        domain: "DOM",
        method: "setInspectModeEnabled",
        message: "enable failed"
    )

    await runtime.backend.hold(domain: "DOM", method: "setInspectModeEnabled", gate: enableGate)
    await runtime.backend.enqueueFailure(
        enableError,
        for: "DOM",
        method: "setInspectModeEnabled"
    )

    let firstEnableTask = Task { @MainActor in
        try await context.setElementPickerEnabled(true)
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "setInspectModeEnabled",
        count: 1
    )
    let firstDesiredStateID = try #require(context.elementPickerDesiredStateForTesting?.id)

    let latestEnableTask = Task { @MainActor in
        try await context.setElementPickerEnabled(true)
    }
    try await waitUntil {
        context.elementPickerDesiredStateForTesting?.id != firstDesiredStateID
            && context.elementPickerDesiredStateForTesting?.isEnabled == true
    }
    await enableGate.open()

    await #expect(throws: enableError) {
        try await firstEnableTask.value
    }
    await #expect(throws: enableError) {
        try await latestEnableTask.value
    }

    let commands = await runtime.backend.recordedCommands().filter {
        $0.domain == "DOM" && $0.method == "setInspectModeEnabled"
    }
    #expect(commands.compactMap {
        $0.payload.cast(as: DOM.SetInspectModeEnabledPayload.self)?.enabled
    } == [true])
    #expect(context.isElementPickerEnabled == false)

    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")
    try await context.setElementPickerEnabled(true)

    let recoveredCommands = await runtime.backend.recordedCommands().filter {
        $0.domain == "DOM" && $0.method == "setInspectModeEnabled"
    }
    #expect(recoveredCommands.compactMap {
        $0.payload.cast(as: DOM.SetInspectModeEnabledPayload.self)?.enabled
    } == [true, true])
    #expect(context.isElementPickerEnabled)
}

@MainActor
@Test
func cancellingElementPickerEnableWhoseCommandFailsThrowsCancellationWithoutRetry() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let enableGate = WebInspectorTestGate()
    let enableError = WebInspectorProxyError.commandFailed(
        domain: "DOM",
        method: "setInspectModeEnabled",
        message: "enable failed"
    )

    await runtime.backend.hold(domain: "DOM", method: "setInspectModeEnabled", gate: enableGate)
    await runtime.backend.enqueueFailure(
        enableError,
        for: "DOM",
        method: "setInspectModeEnabled"
    )

    let enableTask = Task { @MainActor in
        try await context.setElementPickerEnabled(true)
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "setInspectModeEnabled",
        count: 1
    )
    enableTask.cancel()
    await enableGate.open()

    await #expect(throws: CancellationError.self) {
        try await enableTask.value
    }

    let commands = await runtime.backend.recordedCommands().filter {
        $0.domain == "DOM" && $0.method == "setInspectModeEnabled"
    }
    #expect(commands.compactMap {
        $0.payload.cast(as: DOM.SetInspectModeEnabledPayload.self)?.enabled
    } == [true])
    #expect(context.isElementPickerEnabled == false)
}

@MainActor
@Test
func cancellingElementPickerEnableAwaitsOneSuccessfulDisable() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let commandGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "DOM", method: "setInspectModeEnabled", gate: commandGate)
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")

    let enableTask = Task { @MainActor in
        try await context.setElementPickerEnabled(true)
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "setInspectModeEnabled",
        count: 1
    )

    enableTask.cancel()
    await commandGate.open()

    await #expect(throws: CancellationError.self) {
        try await enableTask.value
    }

    let completed = await runtime.backend.completedCommands().filter {
        $0.domain == "DOM" && $0.method == "setInspectModeEnabled"
    }
    #expect(completed.compactMap {
        $0.payload.cast(as: DOM.SetInspectModeEnabledPayload.self)?.enabled
    } == [true, false])
    #expect(context.isElementPickerEnabled == false)
}

@MainActor
@Test
func cancellingElementPickerEnableDoesNotRetryFailedDisable() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let commandGate = WebInspectorTestGate()
    let rollbackError = WebInspectorProxyError.commandFailed(
        domain: "DOM",
        method: "setInspectModeEnabled",
        message: "rollback failed"
    )

    await runtime.backend.hold(domain: "DOM", method: "setInspectModeEnabled", gate: commandGate)
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")
    await runtime.backend.enqueueFailure(
        rollbackError,
        for: "DOM",
        method: "setInspectModeEnabled"
    )

    let enableTask = Task { @MainActor in
        try await context.setElementPickerEnabled(true)
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "setInspectModeEnabled",
        count: 1
    )

    enableTask.cancel()
    await commandGate.open()

    await #expect(throws: rollbackError) {
        try await enableTask.value
    }

    let commands = await runtime.backend.recordedCommands().filter {
        $0.domain == "DOM" && $0.method == "setInspectModeEnabled"
    }
    #expect(commands.compactMap {
        $0.payload.cast(as: DOM.SetInspectModeEnabledPayload.self)?.enabled
    } == [true, false])
    #expect(context.isElementPickerEnabled)

    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")
    try await context.setElementPickerEnabled(false)
    #expect(context.isElementPickerEnabled == false)

    let recoveredCommands = await runtime.backend.recordedCommands().filter {
        $0.domain == "DOM" && $0.method == "setInspectModeEnabled"
    }
    #expect(recoveredCommands.compactMap {
        $0.payload.cast(as: DOM.SetInspectModeEnabledPayload.self)?.enabled
    } == [true, false, false])
}

@MainActor
@Test
func elementPickerEnableReplyFromPreviousDocumentCannotApply() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(
        runtime: runtime,
        document: DOM.Node(id: DOM.Node.ID("picker-old-document"), nodeType: 9, nodeName: "#document")
    )
    let enableGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "DOM", method: "setInspectModeEnabled", gate: enableGate)
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")

    let enableTask = Task { @MainActor in
        try await context.setElementPickerEnabled(true)
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "setInspectModeEnabled",
        count: 1
    )

    let newDocumentID = DOM.Node.ID("picker-new-document")
    await runtime.backend.enqueue(
        DOM.Node(id: newDocumentID, nodeType: 9, nodeName: "#document"),
        for: "DOM",
        method: "getDocument"
    )
    await runtime.backend.emit(
        .frameNavigated(WebInspectorPageFrameLifecycle(
            id: FrameID("main-frame"),
            parentID: nil,
            loaderID: "picker-new-loader",
            name: "Main",
            url: "https://example.test/picker-new-document",
            securityOrigin: "https://example.test",
            mimeType: "text/html"
        )),
        target: target
    )
    try await waitUntil { context.rootNode?.id == DOMNode.ID(newDocumentID) }

    await enableGate.open()
    await #expect(
        throws: WebInspectorProxyError.disconnected(
            "DOM element picker operation no longer belongs to the current document."
        )
    ) {
        try await enableTask.value
    }

    #expect(context.rootNode?.id == DOMNode.ID(newDocumentID))
    #expect(context.isElementPickerEnabled == false)
    let pickerCommands = await runtime.backend.recordedCommands().filter {
        $0.domain == "DOM" && $0.method == "setInspectModeEnabled"
    }
    #expect(pickerCommands.compactMap {
        $0.payload.cast(as: DOM.SetInspectModeEnabledPayload.self)?.enabled
    } == [true, false])
}

@MainActor
@Test
func failedStalePickerCleanupDoesNotReactivateReplacementDocument() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(
        runtime: runtime,
        document: DOM.Node(id: DOM.Node.ID("picker-stale-document"), nodeType: 9, nodeName: "#document")
    )
    let enableGate = WebInspectorTestGate()
    let rollbackError = WebInspectorProxyError.commandFailed(
        domain: "DOM",
        method: "setInspectModeEnabled",
        message: "stale rollback failed"
    )

    await runtime.backend.hold(domain: "DOM", method: "setInspectModeEnabled", gate: enableGate)
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")
    await runtime.backend.enqueueFailure(
        rollbackError,
        for: "DOM",
        method: "setInspectModeEnabled"
    )

    let enableTask = Task { @MainActor in
        try await context.setElementPickerEnabled(true)
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "setInspectModeEnabled",
        count: 1
    )

    let replacementDocumentID = DOM.Node.ID("picker-replacement-document")
    await runtime.backend.enqueue(
        DOM.Node(id: replacementDocumentID, nodeType: 9, nodeName: "#document"),
        for: "DOM",
        method: "getDocument"
    )
    await runtime.backend.emit(
        .frameNavigated(WebInspectorPageFrameLifecycle(
            id: FrameID("main-frame"),
            parentID: nil,
            loaderID: "picker-replacement-loader",
            name: "Main",
            url: "https://example.test/picker-replacement-document",
            securityOrigin: "https://example.test",
            mimeType: "text/html"
        )),
        target: target
    )
    try await waitUntil {
        context.rootNode?.id == DOMNode.ID(replacementDocumentID)
    }

    await enableGate.open()
    await #expect(throws: rollbackError) {
        try await enableTask.value
    }

    #expect(context.rootNode?.id == DOMNode.ID(replacementDocumentID))
    #expect(context.isElementPickerEnabled == false)
    let pickerCommands = await runtime.backend.recordedCommands().filter {
        $0.domain == "DOM" && $0.method == "setInspectModeEnabled"
    }
    #expect(pickerCommands.compactMap {
        $0.payload.cast(as: DOM.SetInspectModeEnabledPayload.self)?.enabled
    } == [true, false])
}

@MainActor
@Test
func domMutationsAndUndoRedoUseOwningFrameTarget() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let frameTarget = await runtime.proxy.installTargetForTesting(kind: .frame)
    let document = try #require(context.rootNode)
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
    try await waitUntil { context.node(for: DOMNode.ID(scopedNodeID)) != nil }

    await runtime.backend.enqueue((), for: "DOM", method: "setAttributeValue")
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    try await context.dom.setAttribute("data-edited", value: "page", on: document.id)

    await runtime.backend.enqueue((), for: "DOM", method: "removeNode")
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    _ = try await context.dom.remove([DOMNode.ID(scopedNodeID)])

    await runtime.backend.enqueue((), for: "DOM", method: "undo")
    try await context.editHistory.undo()

    await runtime.backend.enqueue((), for: "DOM", method: "redo")
    try await context.editHistory.redo()

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
    let document = try #require(context.rootNode)
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
    try await waitUntil {
        context.node(for: DOMNode.ID(pageNodeID)) != nil
            && context.node(for: DOMNode.ID(scopedFrameNodeID)) != nil
    }

    await #expect(throws: WebInspectorProxyError.commandFailed(
        domain: "DOM",
        method: "removeNode",
        message: "Deleting nodes from multiple DOM targets in one mutation is not supported."
    )) {
        _ = try await context.dom.remove([
            DOMNode.ID(pageNodeID),
            DOMNode.ID(scopedFrameNodeID),
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
    await runtime.backend.emit(.inspect(elementID), target: target)

    try await waitUntil { context.selectedNode === element }
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

    await enqueueCSSStyleReplies(on: runtime.backend)
    await runtime.backend.emit(.inspect(elementID), target: target)
    #expect(context.selectedNode == nil)

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )

    try await waitUntil { context.selectedNode?.id == DOMNode.ID(elementID) }
    #expect(context.state == .attached)
    #expect(await runtime.backend.recordedCommands().contains(
        RecordedCommand(domain: "DOM", method: "requestChildNodes")
    ) == false)
    #expect(context.node(for: DOMNode.ID(staleID)) == nil)
    let selected = try #require(context.selectedNode)
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
    try await waitUntil {
        await runtime.backend.recordedCommands()
            .contains(RecordedCommand(domain: "DOM", method: "getDocument"))
    }

    await runtime.backend.emit(.inspect(elementID), target: target)
    await enqueueCSSStyleReplies(on: runtime.backend)
    await gate.open()

    try await waitUntil { context.rootNode?.id == DOMNode.ID(documentID) }
    #expect(context.selectedNode == nil)

    await runtime.backend.emit(
        .setChildNodes(parent: documentID, nodes: [
            DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )

    try await waitUntil { context.selectedNode?.id == DOMNode.ID(elementID) }
    let selected = try #require(context.selectedNode)
    let styles = try #require(selected.elementStyles)
    try await waitUntil { styles.phase == .loaded }
    #expect(await runtime.backend.recordedCommands().contains(
        RecordedCommand(domain: "DOM", method: "requestChildNodes")
    ) == false)
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

    context.apply(.inspect(inspectedID))

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
    await runtime.backend.enqueue((), for: "Page", method: "enable")
    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    await runtime.backend.enqueue((), for: "Runtime", method: "disable")
    await runtime.backend.enqueue((), for: "Page", method: "disable")
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
        RecordedCommand(domain: "Page", method: "enable"),
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Network", method: "enable"),
        RecordedCommand(domain: "Runtime", method: "disable"),
        RecordedCommand(domain: "Page", method: "disable"),
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
    await runtime.backend.enqueue((), for: "Page", method: "enable")
    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    await runtime.backend.enqueue((), for: "Network", method: "enable")
    await runtime.backend.enqueue(
        DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document"),
        for: "DOM",
        method: "getDocument"
    )
    await runtime.backend.enqueue((), for: "Runtime", method: "disable")
    await runtime.backend.enqueue((), for: "Network", method: "disable")
    await runtime.backend.enqueue((), for: "Page", method: "disable")
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
        RecordedCommand(domain: "Page", method: "enable"),
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Network", method: "enable"),
        RecordedCommand(domain: "DOM", method: "getDocument"),
        RecordedCommand(domain: "Console", method: "enable"),
        RecordedCommand(domain: "Runtime", method: "disable"),
        RecordedCommand(domain: "Network", method: "disable"),
        RecordedCommand(domain: "Page", method: "disable"),
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
    await runtime.backend.enqueue((), for: "Page", method: "enable")
    await runtime.backend.enqueue((), for: "Page", method: "disable")
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
        RecordedCommand(domain: "Page", method: "enable"),
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Page", method: "disable"),
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
func closeAfterAttachedClearsAttachmentBackedModels() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let documentID = DOM.Node.ID("document")
    let requestID = Network.Request.ID("request-1")
    let runtimeContextID = Runtime.ExecutionContext.ID("main")
    let networkResults: WebInspectorFetchedResults<NetworkRequest>
    let consoleResults: WebInspectorFetchedResults<ConsoleMessage>

    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: documentID, nodeType: 9, nodeName: "#document")
    )

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    networkResults = context.fetchedResults()
    consoleResults = context.fetchedResults()
    try await waitForStartupSubscribers(runtime: runtime, target: target)
    try await waitUntil { context.state == .attached }

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
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "warning"),
            text: "hello",
            timestamp: 2
        )),
        target: target
    )
    await runtime.backend.emit(
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

    await enqueueDomainDisableReplies(on: runtime.backend)
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
            RecordedCommand(domain: "Page", method: "enable"),
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

    await enableGate.open()
    try await waitUntil { context.rootNode?.id == DOMNode.ID(DOM.Node.ID("restarted-document")) }

    let commands = await runtime.backend.recordedCommands()
    #expect(commands == Array(startupCommands.prefix(5)) + [
        RecordedCommand(domain: "Runtime", method: "disable"),
        RecordedCommand(domain: "Network", method: "disable"),
        RecordedCommand(domain: "Page", method: "disable"),
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
            RecordedCommand(domain: "Page", method: "enable"),
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
    await runtime.backend.enqueue((), for: "Page", method: "enable")
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

    try await replyTransportInspectorAndPageInitialization(backend, transport: transport, targetID: ProtocolTarget.ID("page-main"))

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
func transportBackedInspectorInspectMaterializesSelectionWithoutOwningPresentationHighlight() async throws {
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
    let sentMethods = try await backend.sentTargetMessages().map { message in
        try transportTargetMessageMethod(message.message)
    }
    #expect(sentMethods.contains("DOM.highlightNode") == false)

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

    try await waitUntil { context.selectedNode?.elementStyles?.phase == .loaded }
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

    let highlightTask = Task { @MainActor in
        let selectedNode = try #require(context.selectedNode)
        try await context.dom.highlight(selectedNode.id)
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

    try await waitUntil { context.rootNode?.id == DOMNode.ID(DOM.Node.ID("2")) }
    #expect(context.selectedNode == nil)
}

@MainActor
@Test
func transportBackedFrameRuntimeAndConsoleEventsKeepTargetScope() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let frameTargetID = ProtocolTarget.ID("frame-42-7")
    let frameTarget = WebInspectorTarget.ID(frameTargetID.rawValue)
    let scopedContextID = Runtime.ExecutionContext.ID("7", scopedToTargetRawValue: frameTargetID.rawValue)
    let (backend, transport, context) = try await startTransportBackedContext(
        targetID: pageTargetID,
        documentID: "1",
        protocolProfile: .latest
    )
    let consoleResults: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()
    let startupMessageCount = await backend.sentTargetMessages().count

    await installTransportFrameTarget(
        in: transport,
        pageTargetID: pageTargetID,
        targetID: frameTargetID,
        frameID: "frame-7.42",
        parentFrameID: "main-frame"
    )
    await receiveTransportTargetEvent(
        transport,
        targetID: frameTargetID,
        method: "Runtime.executionContextCreated",
        params: #"{"context":{"id":7,"name":"Frame","frameId":"frame-7.42","type":"normal"}}"#
    )
    try await waitUntil {
        context.executionContexts.contains { $0.id == RuntimeContext.ID(scopedContextID) }
    }
    let frameContext = try #require(context.executionContexts.first { $0.id == RuntimeContext.ID(scopedContextID) })

    var capturedEvaluation: RuntimeEvaluation?
    let evaluationTask = Task { @MainActor in
        capturedEvaluation = try await context.runtime.evaluate("window", in: frameContext)
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
func consoleMessagesClearedForDistinctTargetsDoNotSendRuntimeCommands() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let commandCountBeforeClear = await runtime.backend.recordedCommands().count

    context.apply(
        Console.Event.messagesCleared(reason: Console.ClearReason(rawValue: "console-api")),
        targetID: WebInspectorTarget.ID("console-frame-a")
    )
    context.apply(
        Console.Event.messagesCleared(reason: Console.ClearReason(rawValue: "console-api")),
        targetID: WebInspectorTarget.ID("console-frame-b")
    )

    let clearCommands = await runtime.backend.recordedCommands().dropFirst(commandCountBeforeClear)
    #expect(!clearCommands.contains(RecordedCommand(domain: "Runtime", method: "releaseObjectGroup")))
}

@MainActor
@Test
func transportBackedStyleSheetTextEditRoutesToFrameTargetAndMarksUndo() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let frameTargetID = ProtocolTarget.ID("frame-42-7")
    let styleSheetID = CSS.StyleSheet.ID("frame-sheet", scopedToTargetRawValue: frameTargetID.rawValue)
    let (backend, transport, context) = try await startTransportBackedContext(
        targetID: pageTargetID,
        documentID: "1",
        protocolProfile: .latest
    )
    let startupMessageCount = await backend.sentTargetMessages().count

    await installTransportFrameTarget(
        in: transport,
        pageTargetID: pageTargetID,
        targetID: frameTargetID,
        frameID: "frame-7.42",
        parentFrameID: "main-frame"
    )

    let editTask = Task { @MainActor in
        try await context.css.setStyleSheetText("body { color: red; }", for: styleSheetID)
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
        params: #"{"requestId":"commit-retained-request","frameId":"main-frame","loaderId":"loader-1","request":{"url":"https://example.test/retained","method":"GET"},"initiator":{"type":"other"},"type":"Fetch","timestamp":1}"#
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

    try await replyTransportInspectorAndPageInitialization(
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
        params: #"{"requestId":"commit-post-request","frameId":"new-main-frame","loaderId":"loader-2","request":{"url":"https://example.test/after-commit","method":"GET"},"initiator":{"type":"other"},"type":"Fetch","timestamp":2}"#
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
        $0 == "DOM.getDocument" || $0 == "Inspector.enable" || $0 == "Inspector.initialized" || $0 == "Page.enable"
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
        "Page.enable",
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
        params: #"{"requestId":"destroy-retained-request","frameId":"main-frame","loaderId":"loader-1","request":{"url":"https://example.test/retained","method":"GET"},"initiator":{"type":"other"},"type":"Fetch","timestamp":1}"#
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

    try await replyTransportInspectorAndPageInitialization(
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
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let networkResults: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
    let staleRequestID = Network.Request.ID("stale-before-restart")

    await emitFinishedRequest(id: staleRequestID, target: target, backend: runtime.backend)
    try await waitUntil {
        networkResults.items.map(\.id) == [NetworkRequest.ID(staleRequestID)]
    }

    await enqueueDomainDisableReplies(on: runtime.backend)
    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: DOM.Node.ID("fresh-after-restart"), nodeType: 9, nodeName: "#document")
    )

    context.start()

    try await waitUntil { networkResults.items.isEmpty }
    try await waitUntil {
        context.rootNode?.id == DOMNode.ID(DOM.Node.ID("fresh-after-restart"))
            && context.state == .attached
    }
    #expect(networkResults.items.isEmpty)
}

@MainActor
@Test
func networkNavigationVisitIdentityDoesNotRepeatAcrossRestart() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let networkResults: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()

    await runtime.backend.emit(
        .requestWillBeSent(
            id: Network.Request.ID("before-restart"),
            request: Network.Request(
                id: Network.Request.ID("before-restart"),
                url: "https://example.test/before-restart",
                method: "GET",
                origin: Network.Request.Origin(
                    frameID: FrameID("main-frame"),
                    loaderID: "main-loader",
                    targetID: nil
                )
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    try await waitUntil { networkResults.items.count == 1 }
    let retainedVisit = try #require(networkResults.items.first?.navigationVisit)

    await enqueueDomainDisableReplies(on: runtime.backend)
    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: DOM.Node.ID("restart-identity-root"), nodeType: 9, nodeName: "#document")
    )
    context.start()
    try await waitUntil { networkResults.items.isEmpty }
    try await waitUntil {
        context.rootNode?.id == DOMNode.ID(DOM.Node.ID("restart-identity-root"))
            && context.state == .attached
    }

    await runtime.backend.emit(
        .requestWillBeSent(
            id: Network.Request.ID("after-restart"),
            request: Network.Request(
                id: Network.Request.ID("after-restart"),
                url: "https://example.test/after-restart",
                method: "GET",
                origin: Network.Request.Origin(
                    frameID: FrameID("main-frame"),
                    loaderID: "main-loader",
                    targetID: nil
                )
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 2
        ),
        target: target
    )
    try await waitUntil { networkResults.items.count == 1 }
    let restartedVisit = try #require(networkResults.items.first?.navigationVisit)
    #expect(restartedVisit != retainedVisit)
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
    for method in ["Inspector.enable", "Page.enable", "Runtime.enable", "Network.enable", "Console.enable"] {
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

    try await replyTransportInspectorAndPageInitialization(
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
        params: #"{"requestId":"navigated-request","frameId":"main-frame","loaderId":"loader-2","request":{"url":"https://example.test/after-frame-navigation","method":"GET"},"initiator":{"type":"other"},"type":"Document","timestamp":3}"#
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
func networkNavigationGroupsEachAtoBtoAFrameVisitSeparately() async throws {
    let targetID = ProtocolTarget.ID("page-main")
    let (_, transport, context) = try await startTransportBackedContext(
        targetID: targetID,
        documentID: "navigation-visit-root"
    )
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()

    for (index, visit) in [
        ("loader-a", "a-first", 1.0),
        ("loader-b", "b", 2.0),
        ("loader-a", "a-return", 3.0),
    ].enumerated() {
        let (loaderID, prefix, timestamp) = visit
        await emitTransportNetworkRequest(
            id: "\(prefix)-provisional",
            frameID: "child-frame",
            loaderID: loaderID,
            timestamp: timestamp,
            targetID: targetID,
            transport: transport
        )
        try await waitUntil { results.items.count == index * 2 + 1 }

        await emitTransportFrameNavigated(
            frameID: "child-frame",
            loaderID: loaderID,
            targetID: targetID,
            transport: transport
        )
        await emitTransportNetworkRequest(
            id: "\(prefix)-committed",
            frameID: "child-frame",
            loaderID: loaderID,
            timestamp: timestamp + 0.5,
            targetID: targetID,
            transport: transport
        )
        try await waitUntil { results.items.count == (index + 1) * 2 }
    }

    let visits = try results.items.map { request in
        try #require(request.navigationVisit)
    }
    #expect(visits.count == 6)
    #expect(Dictionary(grouping: visits, by: { $0 }).values.map(\.count).sorted() == [2, 2, 2])
    #expect(visits[0] == visits[1])
    #expect(visits[2] == visits[3])
    #expect(visits[4] == visits[5])
    #expect(visits[0] != visits[4])
}

@MainActor
@Test
func networkRequestBeforeFrameCommitSharesVisitWithCommittedRequest() async throws {
    let targetID = ProtocolTarget.ID("page-main")
    let (_, transport, context) = try await startTransportBackedContext(
        targetID: targetID,
        documentID: "provisional-visit-root"
    )
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()

    await emitTransportNetworkRequest(
        id: "before-commit",
        frameID: "child-frame",
        loaderID: "child-loader",
        timestamp: 1,
        targetID: targetID,
        transport: transport
    )
    try await waitUntil { results.items.count == 1 }
    await emitTransportFrameNavigated(
        frameID: "child-frame",
        loaderID: "child-loader",
        targetID: targetID,
        transport: transport
    )
    await emitTransportNetworkRequest(
        id: "after-commit",
        frameID: "child-frame",
        loaderID: "child-loader",
        timestamp: 2,
        targetID: targetID,
        transport: transport
    )
    try await waitUntil { results.items.count == 2 }

    let provisionalVisit = try #require(results.items[0].navigationVisit)
    let committedVisit = try #require(results.items[1].navigationVisit)
    #expect(provisionalVisit == committedVisit)
}

@MainActor
@Test
func ambiguousFrameCommitDoesNotGuessBetweenPendingNetworkTargets() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()

    await applyOriginatedNetworkRequest(
        id: "ambiguous-current",
        loaderID: "current-loader",
        originTargetID: "page-current",
        timestamp: 1,
        context: context
    )
    await applyOriginatedNetworkRequest(
        id: "ambiguous-first-pending",
        loaderID: "shared-pending-loader",
        originTargetID: "page-next-1",
        timestamp: 2,
        context: context
    )
    await applyOriginatedNetworkRequest(
        id: "ambiguous-second-pending",
        loaderID: "shared-pending-loader",
        originTargetID: "page-next-2",
        timestamp: 3,
        context: context
    )
    let firstPendingVisit = try #require(results.items[1].navigationVisit)
    let secondPendingVisit = try #require(results.items[2].navigationVisit)
    await applyOriginatedNetworkRequest(
        id: "ambiguous-unattributed-pending",
        loaderID: "shared-pending-loader",
        originTargetID: nil,
        timestamp: 4,
        context: context
    )
    let unattributedPendingVisit = try #require(results.items[3].navigationVisit)

    context.apply(.frameNavigated(WebInspectorPageFrameLifecycle(
        id: FrameID("main-frame"),
        parentID: nil,
        loaderID: "shared-pending-loader",
        name: "Main",
        url: "https://example.test/next",
        securityOrigin: "https://example.test",
        mimeType: "text/html"
    )))
    await applyOriginatedNetworkRequest(
        id: "ambiguous-committed",
        loaderID: "shared-pending-loader",
        originTargetID: nil,
        timestamp: 5,
        context: context
    )

    let committedVisit = try #require(results.items[4].navigationVisit)
    #expect(firstPendingVisit != secondPendingVisit)
    #expect(unattributedPendingVisit != firstPendingVisit)
    #expect(unattributedPendingVisit != secondPendingVisit)
    #expect(committedVisit == unattributedPendingVisit)
}

@MainActor
@Test
func frameCommitUsesExactPageBindingForPendingNetworkTarget() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()

    await applyOriginatedNetworkRequest(
        id: "exact-current",
        loaderID: "current-loader",
        originTargetID: "page-current",
        timestamp: 1,
        context: context
    )
    await applyOriginatedNetworkRequest(
        id: "exact-first-pending",
        loaderID: "shared-pending-loader",
        originTargetID: "page-next-1",
        timestamp: 2,
        context: context
    )
    await applyOriginatedNetworkRequest(
        id: "exact-second-pending",
        loaderID: "shared-pending-loader",
        originTargetID: "page-next-2",
        timestamp: 3,
        context: context
    )
    let firstPendingVisit = try #require(results.items[1].navigationVisit)
    let secondPendingVisit = try #require(results.items[2].navigationVisit)

    context.apply(.frameNavigated(WebInspectorPageFrameLifecycle(
        id: FrameID("main-frame"),
        parentID: nil,
        pageBindingID: "page-next-2",
        loaderID: "shared-pending-loader",
        name: "Main",
        url: "https://example.test/next",
        securityOrigin: "https://example.test",
        mimeType: "text/html"
    )))
    await applyOriginatedNetworkRequest(
        id: "exact-committed",
        loaderID: "shared-pending-loader",
        originTargetID: "page-next-2",
        timestamp: 4,
        context: context
    )

    let committedVisit = try #require(results.items[3].navigationVisit)
    #expect(firstPendingVisit != secondPendingVisit)
    #expect(committedVisit == secondPendingVisit)
}

@MainActor
@Test
func frameDetachmentRetainsNetworkHistoryAndLateTerminalEvents() async throws {
    let targetID = ProtocolTarget.ID("page-main")
    let (_, transport, context) = try await startTransportBackedContext(
        targetID: targetID,
        documentID: "detached-frame-root"
    )
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()

    await emitTransportNetworkRequest(
        id: "detached-request",
        frameID: "child-frame",
        loaderID: "child-loader",
        timestamp: 1,
        targetID: targetID,
        transport: transport
    )
    try await waitUntil { results.items.count == 1 }
    let retainedRequest = try #require(results.items.first)
    let retainedVisit = try #require(retainedRequest.navigationVisit)

    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Network.responseReceived",
        params: #"{"requestId":"detached-request","frameId":"child-frame","loaderId":"child-loader","type":"Fetch","response":{"url":"https://example.test/detached-request","status":200,"statusText":"OK","headers":{},"mimeType":"text/plain","source":"network"},"timestamp":1.5}"#
    )
    try await waitUntil { retainedRequest.status == 200 }

    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Page.frameDetached",
        params: #"{"frameId":"child-frame"}"#
    )
    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Network.loadingFinished",
        params: #"{"requestId":"detached-request","timestamp":2}"#
    )
    try await waitUntil { retainedRequest.state == .finished }

    #expect(results.items == [retainedRequest])
    #expect(retainedRequest.navigationVisit == retainedVisit)

    await emitTransportNetworkRequest(
        id: "reused-detached-frame",
        frameID: "child-frame",
        loaderID: "child-loader",
        timestamp: 3,
        targetID: targetID,
        transport: transport
    )
    try await waitUntil { results.items.count == 2 }
    let reusedFrameRequest = try #require(results.items.last)
    #expect(reusedFrameRequest.navigationVisit != retainedVisit)
}

@MainActor
@Test
func memoryCacheOnlyRequestSharesFrameNavigationVisit() async throws {
    let targetID = ProtocolTarget.ID("page-main")
    let (_, transport, context) = try await startTransportBackedContext(
        targetID: targetID,
        documentID: "memory-cache-visit-root"
    )
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()

    await emitTransportFrameNavigated(
        frameID: "child-frame",
        loaderID: "child-loader",
        targetID: targetID,
        transport: transport
    )
    await emitTransportNetworkRequest(
        id: "committed-request",
        frameID: "child-frame",
        loaderID: "child-loader",
        timestamp: 1,
        targetID: targetID,
        transport: transport
    )
    try await waitUntil { results.items.count == 1 }
    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Network.requestServedFromMemoryCache",
        params: #"{"requestId":"cached-only","frameId":"child-frame","loaderId":"child-loader","documentURL":"https://example.test/","timestamp":2,"initiator":{"type":"other"},"resource":{"url":"https://example.test/cached.css","type":"Stylesheet","bodySize":1234,"response":{"url":"https://example.test/cached.css","status":200,"mimeType":"text/css","headers":{}}}}"#
    )
    try await waitUntil { results.items.count == 2 }

    let committedVisit = try #require(results.items[0].navigationVisit)
    let cachedVisit = try #require(results.items[1].navigationVisit)
    #expect(cachedVisit == committedVisit)
}

@MainActor
@Test
func responseOnlyRequestSharesFrameNavigationVisit() async throws {
    let targetID = ProtocolTarget.ID("page-main")
    let (_, transport, context) = try await startTransportBackedContext(
        targetID: targetID,
        documentID: "response-only-visit-root"
    )
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()

    await emitTransportFrameNavigated(
        frameID: "child-frame",
        loaderID: "child-loader",
        targetID: targetID,
        transport: transport
    )
    await emitTransportNetworkRequest(
        id: "committed-request",
        frameID: "child-frame",
        loaderID: "child-loader",
        timestamp: 1,
        targetID: targetID,
        transport: transport
    )
    try await waitUntil { results.items.count == 1 }
    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Network.responseReceived",
        params: #"{"requestId":"response-only","frameId":"child-frame","loaderId":"child-loader","type":"Fetch","response":{"url":"https://example.test/response-only","status":200,"statusText":"OK","headers":{},"mimeType":"text/plain","source":"network"},"timestamp":2}"#
    )
    try await waitUntil { results.items.count == 2 }

    let committedVisit = try #require(results.items[0].navigationVisit)
    let responseVisit = try #require(results.items[1].navigationVisit)
    #expect(responseVisit == committedVisit)
}

@MainActor
@Test
func subframeDetachmentDoesNotAdvanceTopLevelNetworkVisit() async throws {
    let targetID = ProtocolTarget.ID("page-main")
    let (_, transport, context) = try await startTransportBackedContext(
        targetID: targetID,
        documentID: "subframe-detach-top-level-root"
    )
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()

    await emitTransportNetworkRequest(
        id: "top-level-before-detach",
        frameID: "main-frame",
        loaderID: "top-level-loader",
        timestamp: 1,
        targetID: targetID,
        transport: transport
    )
    await emitTransportNetworkRequest(
        id: "subframe-before-detach",
        frameID: "child-frame",
        loaderID: "child-loader",
        timestamp: 2,
        targetID: targetID,
        transport: transport
    )
    try await waitUntil { results.items.count == 2 }
    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Page.frameDetached",
        params: #"{"frameId":"child-frame"}"#
    )
    await emitTransportNetworkRequest(
        id: "top-level-after-detach",
        frameID: "main-frame",
        loaderID: "top-level-loader",
        timestamp: 3,
        targetID: targetID,
        transport: transport
    )
    try await waitUntil { results.items.count == 3 }

    let beforeDetach = try #require(results.items[0].navigationVisit)
    let afterDetach = try #require(results.items[2].navigationVisit)
    #expect(beforeDetach == afterDetach)
}

@MainActor
@Test
func networkEventWithoutFrameMembershipHasNoNavigationVisit() async throws {
    let targetID = ProtocolTarget.ID("page-main")
    let (_, transport, context) = try await startTransportBackedContext(
        targetID: targetID,
        documentID: "missing-frame-membership-root"
    )
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()

    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Network.responseReceived",
        params: #"{"requestId":"missing-membership","frameId":"","loaderId":"","response":{"url":"https://example.test/missing-membership","status":200,"statusText":"OK","headers":{},"mimeType":"text/plain","source":"network"},"timestamp":1}"#
    )
    try await waitUntil { results.items.count == 1 }

    #expect(results.items[0].navigationVisit == nil)
}

@MainActor
@Test
func delayedNetworkConsumerUsesEventTimeTargetAfterFrameRetarget() async throws {
    let transport = TransportSession(backend: FakeTransportBackend(), responseTimeout: .milliseconds(750))
    await installTransportPageTarget(
        in: transport,
        targetID: ProtocolTarget.ID("page-current"),
        frameID: "main-frame"
    )
    let stream = await transport.events(for: .network)
    var iterator = stream.makeAsyncIterator()

    await transport.receiveRootMessage(
        #"{"method":"Network.responseReceived","params":{"requestId":"event-time-old","frameId":"main-frame","loaderId":"reused-loader","response":{"url":"https://example.test/old","status":200,"headers":{}},"timestamp":1}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-provisional","type":"page","frameId":"main-frame","isProvisional":true}}}"#
    )

    let protocolEvent = try #require(await iterator.next())
    let proxyEvent = try LiveProxyEventDecoder.proxyEvent(
        from: protocolEvent,
        targetID: .currentPage
    )
    guard case let .network(oldNetworkEvent) = proxyEvent else {
        Issue.record("Expected delayed Network event.")
        return
    }

    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
    await context.apply(oldNetworkEvent)
    let newID = Network.Request.ID("event-time-new")
    await context.apply(.requestWillBeSent(
        id: newID,
        request: Network.Request(
            id: newID,
            url: "https://example.test/new",
            method: "GET",
            origin: Network.Request.Origin(
                frameID: FrameID("main-frame"),
                loaderID: "reused-loader",
                targetID: "page-provisional"
            )
        ),
        resourceType: .document,
        redirectResponse: nil,
        timestamp: 2
    ))

    let oldVisit = try #require(results.items[0].navigationVisit)
    let newVisit = try #require(results.items[1].navigationVisit)
    #expect(oldVisit != newVisit)
}

@MainActor
@Test
func workerInitiatedRequestSharesOwningFrameNavigationVisit() async throws {
    let transport = TransportSession(backend: FakeTransportBackend(), responseTimeout: .milliseconds(750))
    await installTransportPageTarget(
        in: transport,
        targetID: ProtocolTarget.ID("page-main"),
        frameID: "main-frame"
    )
    let stream = await transport.events(for: .network)
    var iterator = stream.makeAsyncIterator()

    await receiveTransportTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.requestWillBeSent",
        params: #"{"requestId":"document-request","frameId":"main-frame","loaderId":"main-loader","documentURL":"https://example.test/","request":{"url":"https://example.test/","method":"GET"},"initiator":{"type":"other"},"timestamp":1}"#
    )
    await receiveTransportTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.requestWillBeSent",
        params: #"{"requestId":"worker-request","frameId":"main-frame","loaderId":"main-loader","documentURL":"https://example.test/","request":{"url":"https://example.test/worker-data","method":"GET"},"initiator":{"type":"script"},"timestamp":2,"targetId":"worker-1"}"#
    )

    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
    for _ in 0..<2 {
        let protocolEvent = try #require(await iterator.next())
        let proxyEvent = try LiveProxyEventDecoder.proxyEvent(
            from: protocolEvent,
            targetID: .currentPage
        )
        guard case let .network(networkEvent) = proxyEvent else {
            Issue.record("Expected Network.requestWillBeSent.")
            return
        }
        await context.apply(networkEvent)
    }

    let documentVisit = try #require(results.items[0].navigationVisit)
    let workerVisit = try #require(results.items[1].navigationVisit)
    #expect(workerVisit == documentVisit)
}

@MainActor
@Test
func abandonedProvisionalTargetDoesNotReuseNetworkNavigationVisit() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()

    await emitOriginatedNetworkRequest(
        id: "abandoned-provisional",
        frameID: "main-frame",
        loaderID: "reused-loader",
        originTargetID: "page-abandoned",
        timestamp: 1,
        target: target,
        backend: runtime.backend
    )
    await emitOriginatedNetworkRequest(
        id: "abandoned-child-provisional",
        frameID: "child-frame",
        loaderID: "child-reused-loader",
        originTargetID: "page-abandoned",
        timestamp: 1.5,
        target: target,
        backend: runtime.backend
    )
    try await waitUntil { results.items.count == 2 }
    await runtime.backend.emit(
        .targetDestroyed(targetID: WebInspectorTarget.ID("page-abandoned")),
        target: target
    )
    await emitOriginatedNetworkRequest(
        id: "later-provisional",
        frameID: "main-frame",
        loaderID: "reused-loader",
        originTargetID: "page-abandoned",
        timestamp: 2,
        target: target,
        backend: runtime.backend
    )
    await emitOriginatedNetworkRequest(
        id: "later-child-provisional",
        frameID: "child-frame",
        loaderID: "child-reused-loader",
        originTargetID: "page-abandoned",
        timestamp: 2.5,
        target: target,
        backend: runtime.backend
    )
    try await waitUntil { results.items.count == 4 }

    let abandonedVisit = try #require(results.items[0].navigationVisit)
    let abandonedChildVisit = try #require(results.items[1].navigationVisit)
    let laterVisit = try #require(results.items[2].navigationVisit)
    let laterChildVisit = try #require(results.items[3].navigationVisit)
    #expect(abandonedVisit != laterVisit)
    #expect(abandonedChildVisit != laterChildVisit)
}

@MainActor
@Test
func targetCommitBeforeFrameCommitDoesNotAdvanceNetworkVisitTwice() async throws {
    let visits = try await networkVisitsAcrossTopLevelCommit(order: .targetThenFrame)

    #expect(visits.provisional == visits.committed)
}

@MainActor
@Test
func frameCommitBeforeTargetCommitDoesNotAdvanceNetworkVisitTwice() async throws {
    let visits = try await networkVisitsAcrossTopLevelCommit(order: .frameThenTarget)

    #expect(visits.provisional == visits.committed)
}

@MainActor
@Test
func targetCommitBeforeFrameCommitPreservesUnattributedNetworkVisit() async throws {
    let visits = try await networkVisitsAcrossTopLevelCommit(
        order: .targetThenFrame,
        provisionalOriginTargetID: nil,
        currentLoaderID: "current-loader",
        provisionalLoaderID: "provisional-loader"
    )

    #expect(visits.provisional == visits.committed)
}

@MainActor
@Test
func frameCommitBeforeTargetCommitPreservesUnattributedNetworkVisit() async throws {
    let visits = try await networkVisitsAcrossTopLevelCommit(
        order: .frameThenTarget,
        provisionalOriginTargetID: nil,
        currentLoaderID: "current-loader",
        provisionalLoaderID: "provisional-loader"
    )

    #expect(visits.provisional == visits.committed)
}

@MainActor
@Test
func ambiguousFrameCommitPreservesCandidatesUntilExactTargetCommit() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()

    await emitOriginatedNetworkRequest(
        id: "candidate-current",
        loaderID: "current-loader",
        originTargetID: "page-current",
        timestamp: 1,
        target: target,
        backend: runtime.backend
    )
    await emitOriginatedNetworkRequest(
        id: "candidate-a",
        loaderID: "shared-loader",
        originTargetID: "page-next-1",
        timestamp: 2,
        target: target,
        backend: runtime.backend
    )
    await emitOriginatedNetworkRequest(
        id: "candidate-b",
        loaderID: "shared-loader",
        originTargetID: "page-next-2",
        timestamp: 3,
        target: target,
        backend: runtime.backend
    )
    try await waitUntil { results.items.count == 3 }
    let candidateAVisit = try #require(results.items[1].navigationVisit)
    let candidateBVisit = try #require(results.items[2].navigationVisit)

    try await emitTopLevelFrameCommit(
        target: target,
        context: context,
        backend: runtime.backend,
        documentID: "ambiguous-frame-root",
        loaderID: "shared-loader"
    )
    try await emitTopLevelTargetCommit(
        target: target,
        context: context,
        backend: runtime.backend,
        documentID: "exact-target-root",
        pageBindingID: "page-next-2"
    )
    await emitOriginatedNetworkRequest(
        id: "candidate-b-committed",
        loaderID: "shared-loader",
        originTargetID: "page-next-2",
        timestamp: 4,
        target: target,
        backend: runtime.backend
    )
    try await waitUntil { results.items.count == 4 }

    let committedVisit = try #require(results.items[3].navigationVisit)
    #expect(candidateAVisit != candidateBVisit)
    #expect(committedVisit == candidateBVisit)
}

@MainActor
@Test
func networkTargetCommitCommitsPendingNavigationVisit() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()

    await emitOriginatedNetworkRequest(
        id: "a-first",
        loaderID: "loader-a",
        originTargetID: "page-a",
        timestamp: 1,
        target: target,
        backend: runtime.backend
    )
    await emitOriginatedNetworkRequest(
        id: "b-provisional",
        loaderID: "loader-b",
        originTargetID: "page-b",
        timestamp: 2,
        target: target,
        backend: runtime.backend
    )
    await emitOriginatedNetworkRequest(
        id: "a-during-b-provisional",
        loaderID: "loader-a",
        originTargetID: "page-a",
        timestamp: 2.5,
        target: target,
        backend: runtime.backend
    )
    try await waitUntil { results.items.count == 3 }

    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: DOM.Node.ID("page-b-root"), nodeType: 9, nodeName: "#document")
    )
    await runtime.backend.emit(
        .didCommitProvisionalTarget(WebInspectorTargetCommitLifecycle(
            oldTargetID: .currentPage,
            newTarget: WebInspectorLifecycleTarget(
                id: .currentPage,
                kind: .page,
                frameID: FrameID("main-frame"),
                isProvisional: false,
                pageBindingID: "page-b"
            )
        )),
        target: target
    )
    try await waitUntil {
        context.rootNode?.id == DOMNode.ID(DOM.Node.ID("page-b-root"))
            && context.state == .attached
    }
    await emitOriginatedNetworkRequest(
        id: "b-committed",
        loaderID: "loader-b",
        originTargetID: "page-b",
        timestamp: 3,
        target: target,
        backend: runtime.backend
    )
    await emitOriginatedNetworkRequest(
        id: "a-return-provisional",
        loaderID: "loader-a",
        originTargetID: "page-a-return",
        timestamp: 4,
        target: target,
        backend: runtime.backend
    )
    try await waitUntil { results.items.count == 5 }

    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: DOM.Node.ID("page-a-return-root"), nodeType: 9, nodeName: "#document")
    )
    await runtime.backend.emit(
        .didCommitProvisionalTarget(WebInspectorTargetCommitLifecycle(
            oldTargetID: .currentPage,
            newTarget: WebInspectorLifecycleTarget(
                id: .currentPage,
                kind: .page,
                frameID: FrameID("main-frame"),
                isProvisional: false,
                pageBindingID: "page-a-return"
            )
        )),
        target: target
    )
    try await waitUntil {
        context.rootNode?.id == DOMNode.ID(DOM.Node.ID("page-a-return-root"))
            && context.state == .attached
    }
    await emitOriginatedNetworkRequest(
        id: "a-return-committed",
        loaderID: "loader-a",
        originTargetID: "page-a-return",
        timestamp: 5,
        target: target,
        backend: runtime.backend
    )
    try await waitUntil { results.items.count == 6 }

    let visits = try results.items.map { try #require($0.navigationVisit) }
    #expect(visits[0] == visits[2])
    #expect(visits[1] == visits[3])
    #expect(visits[4] == visits[5])
    #expect(visits[0] != visits[4])
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
            RecordedCommand(domain: "Page", method: "enable"),
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
    let document = try #require(context.rootNode)
    await runtime.backend.enqueue((), for: "DOM", method: "setAttributeValue")
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    try await context.dom.setAttribute("data-before-reset", value: "1", on: document.id)
    let undoCommands = try context.domUndoRedoCommands()
    let controller = try await context.treeController()
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
    await runtime.backend.enqueue((), for: "DOM", method: "undo")
    await #expect(throws: WebInspectorProxyError.disconnected("DOM undo/redo target is no longer current.")) {
        try await context.editHistory.undo()
    }

    let commands = await runtime.backend.recordedCommands()
    #expect(!commands.contains { $0.domain == "DOM" && $0.method == "undo" })
}

@MainActor
@Test
func childInsertIntoKnownEmptyParentMaterializesFirstChild() async throws {
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
        context.node(for: DOMNode.ID(insertedID)) != nil
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
        document.childNodeCount == 2
    }
    guard case let .unrequested(count) = document.children else {
        Issue.record("Expected an incomplete nonempty parent to stay unrequested.")
        return
    }
    #expect(count == 2)
    #expect(context.node(for: DOMNode.ID(insertedID)) == nil)
}

@MainActor
@Test
func domTreeControllerPublishesInitialSnapshotAndChildDeltas() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
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
    let document = try #require(context.rootNode)
    let controller = try await context.treeController()
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
    let child = try #require(context.node(for: DOMNode.ID(childID)))

    await runtime.backend.emit(
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

@MainActor
@Test
func domTreeControllerPublishesAssociatedSubtreeDeltas() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
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

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: hostID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )
    try await recorder.waitForUpdateCount(2)
    let host = try #require(context.node(for: DOMNode.ID(hostID)))

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
    #expect(context.node(for: DOMNode.ID(beforePseudoID)) == nil)
    #expect(
        controller.snapshot.visibleChildren(of: DOMNode.ID(hostID)).nodeIDs == [DOMNode.ID(shadowRootID)]
    )

    await runtime.backend.emit(
        .shadowRootPopped(host: hostID, root: shadowRootID),
        target: target
    )

    try await recorder.waitForUpdateCount(6)
    #expect(host.shadowRoots.isEmpty)
    #expect(context.node(for: DOMNode.ID(shadowRootID)) == nil)
    #expect(context.node(for: DOMNode.ID(shadowChildID)) == nil)
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
    let document = try #require(context.rootNode)
    let controller = try await context.treeController()
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
    try await waitUntil { context.node(for: DOMNode.ID(elementID))?.attributes["class"] == "selected" }
    try await recorder.waitForUpdateCount(3)

    await runtime.backend.emit(
        .childNodeCountUpdated(elementID, count: 1),
        target: target
    )
    try await waitUntil { context.node(for: DOMNode.ID(elementID))?.childNodeCount == 1 }
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
    try await waitUntil { context.node(for: DOMNode.ID(textID))?.nodeValue == "new" }
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
func domTreeControllerPublishesSelectionDeltasWithoutOwningExpansion() async throws {
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
    try context.dom.select(child.id, reveal: .selectOnly)

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

    try context.dom.select(document.id, reveal: .none)
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
    let document = try #require(context.rootNode)
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

    await runtime.backend.emit(
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


@MainActor
@Test
func fetchedResultsControllerPublishesNetworkInsertAndContentUpdateTransactions() async throws {
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
    let firstIndexPath = WebInspectorFetchedResultsIndexPath(section: 0, item: 0)
    #expect(inserted.itemChanges == [.insert(itemID: modelID, indexPath: firstIndexPath)])
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
    try await recorder.waitForTransactionCount(2)
    #expect(results.items.first === request)
    let responseUpdate = try #require(recorder.transactions.last)
    #expect(responseUpdate.oldSnapshot == responseUpdate.newSnapshot)
    #expect(responseUpdate.itemChanges == [.update(itemID: modelID, indexPath: firstIndexPath)])

    await runtime.backend.emit(
        .dataReceived(id: requestID, dataLength: 7, encodedDataLength: 3, timestamp: 3),
        target: target
    )

    try await waitUntil { request.decodedDataLength == 7 && request.encodedDataLength == 3 }
    try await recorder.waitForTransactionCount(3)
    #expect(results.items.first === request)
    #expect(recorder.transactions.last?.itemChanges == [.update(itemID: modelID, indexPath: firstIndexPath)])

    await runtime.backend.emit(
        .loadingFinished(id: requestID, timestamp: 4, sourceMapURL: nil, metrics: nil),
        target: target
    )

    try await waitUntil { request.state == .finished }
    try await recorder.waitForTransactionCount(4)
    #expect(results.items.first === request)
    #expect(recorder.transactions.last?.itemChanges == [.update(itemID: modelID, indexPath: firstIndexPath)])

    await runtime.backend.emit(
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

    let failedRequestID = Network.Request.ID("controller-failed-request")
    let failedModelID = NetworkRequest.ID(failedRequestID)
    let failedIndexPath = WebInspectorFetchedResultsIndexPath(section: 0, item: 1)
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

    try await recorder.waitForTransactionCount(6)
    #expect(recorder.transactions.last?.itemChanges == [.insert(itemID: failedModelID, indexPath: failedIndexPath)])
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
    try await recorder.waitForTransactionCount(7)
    #expect(results.items.last === failedRequest)
    #expect(recorder.transactions.last?.itemChanges == [.update(itemID: failedModelID, indexPath: failedIndexPath)])

    let socketRequestID = Network.Request.ID("controller-socket-request")
    let socketModelID = NetworkRequest.ID(socketRequestID)
    let socketIndexPath = WebInspectorFetchedResultsIndexPath(section: 0, item: 2)
    await runtime.backend.emit(
        .webSocket(.created(id: socketRequestID, url: "wss://example.com/socket")),
        target: target
    )

    try await recorder.waitForTransactionCount(8)
    #expect(recorder.transactions.last?.itemChanges == [.insert(itemID: socketModelID, indexPath: socketIndexPath)])
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
    try await recorder.waitForTransactionCount(9)
    #expect(results.items.last === socketRequest)
    #expect(recorder.transactions.last?.itemChanges == [.update(itemID: socketModelID, indexPath: socketIndexPath)])

    await runtime.backend.emit(
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

    await runtime.backend.emit(
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

    await runtime.backend.emit(
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

    await runtime.backend.emit(
        .webSocket(.error(id: socketRequestID, message: "decode failed", timestamp: 12)),
        target: target
    )

    try await waitUntil { socketRequest.webSocket?.frames.count == 3 }
    try await recorder.waitForTransactionCount(13)
    #expect(results.items.last === socketRequest)
    #expect(recorder.transactions.last?.itemChanges == [.update(itemID: socketModelID, indexPath: socketIndexPath)])

    await runtime.backend.emit(
        .webSocket(.closed(id: socketRequestID, timestamp: 13)),
        target: target
    )

    try await waitUntil { socketRequest.state == .finished && socketRequest.webSocket?.readyState == .closed }
    try await recorder.waitForTransactionCount(14)
    #expect(results.items.last === socketRequest)
    #expect(recorder.transactions.last?.itemChanges == [.update(itemID: socketModelID, indexPath: socketIndexPath)])
}

@MainActor
@Test
func unfilteredNetworkContentUpdateDoesNotVisitFullMembership() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    for index in 0..<2_305 {
        let requestID = Network.Request.ID("request-\(index)")
        await context.apply(.requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "https://example.test/\(index)",
                method: "GET"
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: Double(index)
        ))
    }

    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
    let controller = WebInspectorFetchedResultsController(fetchedResults: results)
    let recorder = FetchedResultsTransactionRecorder(stream: controller.transactions)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()
    let membershipVisitBaseline = results.networkFullMembershipVisitCountForTesting
    let updatedIndex = 1_152
    let requestID = Network.Request.ID("request-\(updatedIndex)")

    await context.apply(.responseReceived(
        id: requestID,
        response: Network.Response(
            url: "https://example.test/\(updatedIndex)",
            status: 201,
            statusText: "Created",
            mimeType: "application/json"
        ),
        resourceType: .fetch,
        timestamp: 3_000
    ))

    try await recorder.waitForTransactionCount(1)
    #expect(results.networkFullMembershipVisitCountForTesting == membershipVisitBaseline)
    #expect(recorder.transactions.last?.itemChanges == [
        .update(
            itemID: NetworkRequest.ID(requestID),
            indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: updatedIndex)
        ),
    ])
}

@MainActor
@Test
func sectionedNetworkResultsPublishTopologyWhenSectionKeyChanges() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults(sectionBy: \.mimeType)
    let controller = WebInspectorFetchedResultsController(fetchedResults: results)
    let recorder = FetchedResultsTransactionRecorder(stream: controller.transactions)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()

    let requestID = Network.Request.ID("sectioned-controller-request")
    let modelID = NetworkRequest.ID(requestID)
    await runtime.backend.emit(
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
    #expect(controller.snapshot.sectionIDs == [WebInspectorFetchSectionID(rawValue: "")])
    #expect(controller.snapshot.itemIDs == [modelID])

    await runtime.backend.emit(
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

@MainActor
@Test
func sectionedNetworkResultsPublishItemMoveWhenSectionKeyChangesBetweenExistingSections() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults(sectionBy: \.resourceCategory)
    let controller = WebInspectorFetchedResultsController(fetchedResults: results)
    let recorder = FetchedResultsTransactionRecorder(stream: controller.transactions)
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
    #expect(controller.snapshot.sections.map(\.id) == [
        WebInspectorFetchSectionID(rawValue: "image"),
        WebInspectorFetchSectionID(rawValue: "xhrFetch"),
    ])
    #expect(controller.snapshot.sections.map(\.itemIDs) == [
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

    context.clearNetworkRequests()
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
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let descriptor = WebInspectorFetchDescriptor<NetworkRequest>(
        sortBy: [SortDescriptor(\.requestSentTimestamp, order: .forward)],
        fetchLimit: 1
    )
    let networkResults: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults(for: descriptor)
    let staleRequestID = Network.Request.ID("stale-query-before-restart")

    await emitFinishedRequest(id: staleRequestID, target: target, backend: runtime.backend)
    try await waitUntil {
        networkResults.items.map(\.id) == [NetworkRequest.ID(staleRequestID)]
    }

    await enqueueDomainDisableReplies(on: runtime.backend)
    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: DOM.Node.ID("fresh-query-root"), nodeType: 9, nodeName: "#document")
    )

    context.start()

    try await waitUntil {
        networkResults.items.isEmpty && context.state == .attached
    }

    let freshRequestID = Network.Request.ID("fresh-query-after-restart")
    await emitFinishedRequest(id: freshRequestID, target: target, backend: runtime.backend)
    try await waitUntil {
        networkResults.items.map(\.id) == [NetworkRequest.ID(freshRequestID)]
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
    let controller = WebInspectorFetchedResultsController(fetchedResults: results)
    let recorder = FetchedResultsTransactionRecorder(stream: controller.transactions)
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
    let controller = WebInspectorFetchedResultsController(fetchedResults: results)
    let recorder = FetchedResultsTransactionRecorder(stream: controller.transactions)
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

    let clearedEventBaseline = context.eventPumpAppliedSequenceForTesting
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
    let didProcessClearedEvents = await context.waitForEventPumpAppliedSequenceForTesting(
        after: clearedEventBaseline,
        count: 4
    )
    #expect(didProcessClearedEvents)
    #expect(context.state == .attached)
    #expect(results.items.isEmpty)
    #expect(recorder.transactions.count == 3)

    let redirectedEventBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(
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

    await runtime.backend.emit(
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
    #expect(commands.contains(RecordedCommand(domain: "Page", method: "enable")))
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "enable")))
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "getMatchedStylesForNode")))
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "getInlineStylesForNode")))
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "getComputedStyleForNode")))
}

@MainActor
@Test
func selectingDOMNodeDoesNotRetryFailedCSSStyleRead() async throws {
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

    await runtime.backend.enqueueFailure(
        WebInspectorProxyError.commandFailed(
            domain: "CSS",
            method: "getMatchedStylesForNode",
            message: "CSS agent is not enabled."
        ),
        for: "CSS",
        method: "getMatchedStylesForNode"
    )
    context.select(element)

    let styles = try #require(element.elementStyles)
    try await waitUntil {
        if case .failed = styles.phase {
            return true
        }
        return false
    }

    let cssCommands = await runtime.backend.recordedCommands()
        .filter { $0.domain == "CSS" }
    #expect(cssCommands == [
        RecordedCommand(domain: "CSS", method: "enable"),
        RecordedCommand(domain: "CSS", method: "getMatchedStylesForNode"),
    ])
}

@MainActor
@Test
func failedStyleLeasePreservesPageLifecycleUntilContextStops() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let initialDocument = DOM.Node(id: DOM.Node.ID("document-1"), nodeType: 9, nodeName: "#document")
    let navigatedDocument = DOM.Node(id: DOM.Node.ID("document-2"), nodeType: 9, nodeName: "#document")

    await enqueueDomainEnableReplies(on: runtime.backend)
    await runtime.backend.enqueue(initialDocument, for: "DOM", method: "getDocument")
    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitForStartupSubscribers(runtime: runtime, target: target)
    try await waitUntil { context.rootNode?.id == DOMNode.ID(initialDocument.id) }

    await runtime.backend.emit(
        .setChildNodes(parent: initialDocument.id, nodes: [
            DOM.Node(
                id: DOM.Node.ID("styled-node"),
                nodeType: 1,
                nodeName: "DIV",
                localName: "div",
                childNodeCount: 0
            )
        ]),
        target: target
    )
    let element = try await waitForChild(in: context)
    await runtime.backend.enqueueFailure(
        WebInspectorProxyError.commandFailed(domain: "CSS", method: "enable", message: "CSS unavailable"),
        for: "CSS",
        method: "enable"
    )
    context.select(element)
    let styles = try #require(element.elementStyles)
    try await waitUntil {
        if case .failed = styles.phase {
            return true
        }
        return false
    }

    #expect(await runtime.backend.recordedCommands().filter {
        $0.domain == "Page" && ($0.method == "enable" || $0.method == "disable")
    } == [RecordedCommand(domain: "Page", method: "enable")])

    await runtime.backend.enqueue(navigatedDocument, for: "DOM", method: "getDocument")
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
    try await waitUntil { context.rootNode?.id == DOMNode.ID(navigatedDocument.id) }

    await enqueueDomainDisableReplies(on: runtime.backend)
    await context.stop()
    #expect(await runtime.backend.recordedCommands().filter {
        $0.domain == "Page" && ($0.method == "enable" || $0.method == "disable")
    } == [
        RecordedCommand(domain: "Page", method: "enable"),
        RecordedCommand(domain: "Page", method: "disable"),
    ])
}

@MainActor
@Test
func changingSelectionDuringStyleLeaseAcquisitionEnablesDomainsOnce() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let firstID = DOM.Node.ID("styled-node-1")
    let secondID = DOM.Node.ID("styled-node-2")

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: firstID, nodeType: 1, nodeName: "DIV", localName: "div", childNodeCount: 0),
            DOM.Node(id: secondID, nodeType: 1, nodeName: "DIV", localName: "div", childNodeCount: 0),
        ]),
        target: target
    )
    try await waitUntil {
        context.node(for: DOMNode.ID(firstID)) != nil
            && context.node(for: DOMNode.ID(secondID)) != nil
    }
    let first = try #require(context.node(for: DOMNode.ID(firstID)))
    let second = try #require(context.node(for: DOMNode.ID(secondID)))
    let cssEnableGate = WebInspectorTestGate()
    await runtime.backend.hold(domain: "CSS", method: "enable", gate: cssEnableGate)

    context.select(first)
    _ = await runtime.backend.waitForRecordedCommands(domain: "CSS", method: "enable", count: 1)

    context.select(second)
    await enqueueCSSStyleReplies(on: runtime.backend)
    await cssEnableGate.open()

    let styles = try #require(second.elementStyles)
    try await waitUntil { styles.phase == .loaded }
    let lifecycleCommands = await runtime.backend.recordedCommands().filter {
        ($0.domain == "Page" || $0.domain == "CSS") && $0.method == "enable"
    }
    #expect(lifecycleCommands == [
        RecordedCommand(domain: "Page", method: "enable"),
        RecordedCommand(domain: "CSS", method: "enable"),
    ])
}

@MainActor
@Test
func stoppingContextReleasesSelectedStyleLeaseInReverseDependencyOrder() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(
                id: DOM.Node.ID("styled-node"),
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
    try await waitUntil { styles.phase == .loaded }

    await runtime.backend.enqueue((), for: "CSS", method: "disable")
    await runtime.backend.enqueue((), for: "Page", method: "disable")
    await enqueueDomainDisableReplies(on: runtime.backend)
    await context.stop()

    let styleLifecycleCommands = await runtime.backend.recordedCommands().filter {
        ($0.domain == "Page" || $0.domain == "CSS")
            && ($0.method == "enable" || $0.method == "disable")
    }
    #expect(styleLifecycleCommands == [
        RecordedCommand(domain: "Page", method: "enable"),
        RecordedCommand(domain: "CSS", method: "enable"),
        RecordedCommand(domain: "CSS", method: "disable"),
        RecordedCommand(domain: "Page", method: "disable"),
    ])
    #expect(context.state == .detached)
}

@MainActor
@Test
func restartingContextReacquiresSelectedStyleLease() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(
        runtime: runtime,
        document: DOM.Node(id: DOM.Node.ID("document-1"), nodeType: 9, nodeName: "#document")
    )

    func selectStyledChild(id: DOM.Node.ID) async throws {
        let document = try #require(context.rootNode)
        await runtime.backend.emit(
            .setChildNodes(parent: document.id.proxyID, nodes: [
                DOM.Node(
                    id: id,
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
        try await waitUntil { styles.phase == .loaded }
    }

    try await selectStyledChild(id: DOM.Node.ID("styled-node-1"))

    await runtime.backend.enqueue((), for: "CSS", method: "disable")
    await runtime.backend.enqueue((), for: "Page", method: "disable")
    await enqueueDomainDisableReplies(on: runtime.backend)
    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: DOM.Node.ID("document-2"), nodeType: 9, nodeName: "#document")
    )
    context.start()
    try await waitUntil { context.rootNode?.id == DOMNode.ID(DOM.Node.ID("document-2")) }

    try await selectStyledChild(id: DOM.Node.ID("styled-node-2"))

    let styleLifecycleCommands = await runtime.backend.recordedCommands().filter {
        ($0.domain == "Page" || $0.domain == "CSS")
            && ($0.method == "enable" || $0.method == "disable")
    }
    #expect(styleLifecycleCommands == [
        RecordedCommand(domain: "Page", method: "enable"),
        RecordedCommand(domain: "CSS", method: "enable"),
        RecordedCommand(domain: "CSS", method: "disable"),
        RecordedCommand(domain: "Page", method: "disable"),
        RecordedCommand(domain: "Page", method: "enable"),
        RecordedCommand(domain: "CSS", method: "enable"),
    ])
}

@MainActor
@Test
func selectingFrameScopedDOMNodeEnablesOnlyFrameCSSBeforeStyleRead() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let frameTargetRawValue = "frame-css-agent"
    let elementID = DOM.Node.ID("frame-styled-node", scopedToTargetRawValue: frameTargetRawValue)

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

    await runtime.backend.enqueue((), for: "CSS", method: "enable")
    await enqueueCSSStyleReplies(on: runtime.backend)

    context.select(element)

    let styles = try #require(element.elementStyles)
    try await waitUntil { styles.phase == .loaded }

    let frameCommands = await runtime.backend.recordedCommands().filter {
        $0.targetID == WebInspectorTarget.ID(frameTargetRawValue)
    }
    #expect(frameCommands.map(\.domain) == ["CSS", "CSS", "CSS", "CSS"])
    #expect(frameCommands.map(\.method) == [
        "enable",
        "getMatchedStylesForNode",
        "getInlineStylesForNode",
        "getComputedStyleForNode",
    ])
}

@MainActor
@Test
func destroyingFrameDiscardsOnlyFrameCSSLease() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let pageElementID = DOM.Node.ID("page-styled-node")
    let frameTargetRawValue = "frame-css-agent"
    let frameTargetID = WebInspectorTarget.ID(frameTargetRawValue)
    let frameElementID = DOM.Node.ID("frame-styled-node", scopedToTargetRawValue: frameTargetRawValue)

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: pageElementID, nodeType: 1, nodeName: "DIV", localName: "div", childNodeCount: 0),
            DOM.Node(id: frameElementID, nodeType: 1, nodeName: "DIV", localName: "div", childNodeCount: 0),
        ]),
        target: target
    )
    try await waitUntil {
        context.node(for: DOMNode.ID(pageElementID)) != nil
            && context.node(for: DOMNode.ID(frameElementID)) != nil
    }
    let pageElement = try #require(context.node(for: DOMNode.ID(pageElementID)))
    let frameElement = try #require(context.node(for: DOMNode.ID(frameElementID)))

    await enqueueCSSStyleReplies(on: runtime.backend)
    context.select(pageElement)
    let pageStyles = try #require(pageElement.elementStyles)
    try await waitUntil { pageStyles.phase == .loaded }

    await runtime.backend.enqueue((), for: "CSS", method: "enable")
    await enqueueCSSStyleReplies(on: runtime.backend)
    context.select(frameElement)
    let frameStyles = try #require(frameElement.elementStyles)
    try await waitUntil { frameStyles.phase == .loaded }

    let eventBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(.targetDestroyed(targetID: frameTargetID), target: target)
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: eventBaseline))

    await runtime.backend.enqueue((), for: "CSS", method: "disable")
    await runtime.backend.enqueue((), for: "Page", method: "disable")
    await enqueueDomainDisableReplies(on: runtime.backend)
    await context.stop()

    let frameLifecycleMethods = await runtime.backend.recordedCommands().filter {
        $0.targetID == frameTargetID && $0.domain == "CSS"
    }.map(\.method)
    #expect(frameLifecycleMethods == [
        "enable",
        "getMatchedStylesForNode",
        "getInlineStylesForNode",
        "getComputedStyleForNode",
    ])

    let pageStyleLifecycle = await runtime.backend.recordedCommands().filter {
        $0.targetID == target.id
            && ($0.domain == "Page" || $0.domain == "CSS")
            && ($0.method == "enable" || $0.method == "disable")
    }
    #expect(pageStyleLifecycle == [
        RecordedCommand(domain: "Page", method: "enable"),
        RecordedCommand(domain: "CSS", method: "enable"),
        RecordedCommand(domain: "CSS", method: "disable"),
        RecordedCommand(domain: "Page", method: "disable"),
    ])
}

@MainActor
@Test
func destroyingFrameDuringCSSAcquisitionMakesSelectedStylesUnavailable() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let frameTargetRawValue = "pending-frame-css-agent"
    let frameTargetID = WebInspectorTarget.ID(frameTargetRawValue)
    let frameElementID = DOM.Node.ID("frame-styled-node", scopedToTargetRawValue: frameTargetRawValue)

    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(
                id: frameElementID,
                nodeType: 1,
                nodeName: "DIV",
                localName: "div",
                childNodeCount: 0
            )
        ]),
        target: target
    )
    let frameElement = try await waitForChild(in: context)
    let cssEnableGate = WebInspectorTestGate()
    await runtime.backend.hold(domain: "CSS", method: "enable", gate: cssEnableGate)

    context.select(frameElement)
    let styles = try #require(frameElement.elementStyles)
    _ = await runtime.backend.waitForRecordedCommands(domain: "CSS", method: "enable", count: 1)

    let eventBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(.targetDestroyed(targetID: frameTargetID), target: target)
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: eventBaseline))
    await cssEnableGate.open()

    try await waitUntil { styles.phase == .unavailable }
    let frameLifecycleMethods = await runtime.backend.recordedCommands().filter {
        $0.targetID == frameTargetID && $0.domain == "CSS"
    }.map(\.method)
    #expect(frameLifecycleMethods == ["enable"])

    await enqueueDomainDisableReplies(on: runtime.backend)
    await context.stop()
}

@MainActor
@Test
func selectingNonElementDOMNodeDoesNotRequestCSSStyles() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)

    context.select(document)

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

    await runtime.backend.emit(.styleSheetChanged(CSS.StyleSheet.ID("sheet-1")), target: target)
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

    let otherAttributeBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(.attributeModified(otherID, name: "class", value: "ignored"), target: target)
    let didProcessOtherAttribute = await context.waitForEventPumpAppliedSequenceForTesting(
        after: otherAttributeBaseline
    )
    #expect(didProcessOtherAttribute)
    #expect(styles.phase == .loaded)

    let otherLayoutBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(.nodeLayoutFlagsChanged(otherID), target: target)
    let didProcessOtherLayout = await context.waitForEventPumpAppliedSequenceForTesting(
        after: otherLayoutBaseline
    )
    #expect(didProcessOtherLayout)
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

    await runtime.backend.emit(.styleSheetChanged(CSS.StyleSheet.ID("sheet-1")), target: target)
    try await waitUntil { styles.phase == .needsRefresh }

    await computedGate.open()
    _ = await runtime.backend.waitForCompletedCommands(domain: "CSS", method: "getComputedStyleForNode", count: 1)
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

    context.css.setStyleHydrationActive(true)
    await enqueueCSSStyleReplies(on: runtime.backend)
    context.select(element)
    let styles = try #require(element.elementStyles)
    try await waitUntil { styles.phase == .loaded }

    await enqueueCSSStyleReplies(on: runtime.backend)
    await runtime.backend.emit(.styleSheetChanged(CSS.StyleSheet.ID("sheet-1")), target: target)

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

    await runtime.backend.emit(.styleSheetChanged(CSS.StyleSheet.ID("sheet-1")), target: target)
    try await waitUntil { styles.phase == .needsRefresh }
    #expect(styles.phase == .needsRefresh)
    #expect(await matchedStylesCommandCount(on: runtime.backend) == 1)

    await enqueueCSSStyleReplies(on: runtime.backend)
    context.css.setStyleHydrationActive(true)

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

    context.css.setStyleHydrationActive(true)
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
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    #expect(context.css.requestSetProperty(propertyID, enabled: false))

    try await waitUntil {
        await matchedStylesCommandCount(on: runtime.backend) == 2
    }
    try await waitUntil { styles.phase == .loaded }

    let commands = await runtime.backend.recordedCommands()
    let setStyleText = try #require(commands.last { $0 == RecordedCommand(domain: "CSS", method: "setStyleText") })
    let payload = try #require(setStyleText.payload.cast(as: CSS.SetStyleTextPayload.self))
    #expect(payload.id == CSS.Style.ID("style-1"))
    #expect(payload.text == "/* display: grid; */")
    let undoMarks = commands.filter { $0.domain == "DOM" && $0.method == "markUndoableState" }
    #expect(undoMarks.count == 1)
    #expect(undoMarks.first?.targetID == target.id)

    let property = try #require(styles.sections.first?.style.properties.first)
    #expect(property.status == .disabled)
    #expect(property.isModifiedByInspector)
}

@MainActor
@Test
func setCSSDeclarationTextRewritesStyleTextAndMarksUndoableState() async throws {
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
    await runtime.backend.enqueue(updatedStyle, for: "CSS", method: "setStyleText")
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")

    let propertyID = try #require(styles.sections.first?.style.properties.first?.id)
    try await context.css.setDeclarationText("display: flex;", for: propertyID)

    let commands = await runtime.backend.recordedCommands()
    let setStyleText = try #require(commands.last { $0 == RecordedCommand(domain: "CSS", method: "setStyleText") })
    let payload = try #require(setStyleText.payload.cast(as: CSS.SetStyleTextPayload.self))
    #expect(payload.id == CSS.Style.ID("style-1"))
    #expect(payload.text == "display: flex;")
    let undoMarks = commands.filter { $0.domain == "DOM" && $0.method == "markUndoableState" }
    #expect(undoMarks.count == 1)
    #expect(undoMarks.first?.targetID == target.id)

    let property = try #require(styles.sections.first?.style.properties.first)
    #expect(property.value == "flex")
    #expect(property.text == "display: flex;")
    #expect(property.isModifiedByInspector)
    #expect(styles.phase == .needsRefresh)
}

@MainActor
@Test
func cssRuleSelectorEditsMarkUndoableStateOnOwningTarget() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let frameTarget = await runtime.proxy.installTargetForTesting(kind: .frame)
    let proxyRuleID = CSS.Rule.ID("frame-rule", scopedToTargetRawValue: frameTarget.id.rawValue)
    let ruleID = CSSStyleRule.ID(proxyRuleID)

    await runtime.backend.enqueue(
        CSS.Rule(
            id: proxyRuleID,
            selectorList: CSS.Rule.SelectorList(selectors: [".updated"], text: ".updated"),
            origin: CSS.Origin(rawValue: "regular"),
            style: CSS.Style(id: CSS.Style.ID("frame-style", scopedToTargetRawValue: frameTarget.id.rawValue))
        ),
        for: "CSS",
        method: "setRuleSelector"
    )
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")

    try await context.css.setRuleSelector(".updated", for: ruleID)

    let commands = await runtime.backend.recordedCommands()
    let setRuleSelector = try #require(commands.first { $0.domain == "CSS" && $0.method == "setRuleSelector" })
    #expect(setRuleSelector.targetID == frameTarget.id)
    #expect(setRuleSelector.route == RoutingTargetID(frameTarget.id.rawValue))
    #expect(setRuleSelector.payload.cast(as: CSS.SetRuleSelectorPayload.self)?.id == proxyRuleID)

    let markUndoableState = try #require(commands.first { $0.domain == "DOM" && $0.method == "markUndoableState" })
    #expect(markUndoableState.targetID == frameTarget.id)
    #expect(markUndoableState.route == RoutingTargetID(frameTarget.id.rawValue))
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
    #expect(context.css.requestSetProperty(userAgentPropertyID, enabled: false) == false)

    let editableSection = try #require(styles.sections.first { $0.title == ".card" })
    let editablePropertyID = try #require(editableSection.style.properties.first?.id)

    await runtime.backend.emit(.styleSheetChanged(CSS.StyleSheet.ID("sheet-1")), target: target)
    try await waitUntil { styles.phase == .needsRefresh }
    #expect(context.css.requestSetProperty(editablePropertyID, enabled: false) == false)

    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "setStyleText")) == false)
}

@MainActor
@Test
func lateCSSPropertyReplyDoesNotApplyToReplacementDocument() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let fixture = try await loadEditableCSSFixture(runtime: runtime, target: target, context: context)
    let mutationGate = WebInspectorTestGate()
    let replacementStyle = CSS.Style(
        id: CSS.Style.ID("style-1"),
        properties: [
            CSS.Property(
                id: CSS.Property.ID("property-1"),
                name: "display",
                value: "none",
                text: "/* display: grid; */",
                status: .disabled,
                isEditable: true
            )
        ],
        cssText: "/* display: grid; */",
        isEditable: true
    )

    await runtime.backend.hold(domain: "CSS", method: "setStyleText", gate: mutationGate)
    await runtime.backend.enqueue(replacementStyle, for: "CSS", method: "setStyleText")
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    let mutationTask = Task { @MainActor in
        try await context.css.setProperty(fixture.propertyID, enabled: false)
    }
    _ = await runtime.backend.waitForRecordedCommands(domain: "CSS", method: "setStyleText", count: 1)

    let replacementDocumentID = DOM.Node.ID("replacement-after-property")
    await runtime.backend.enqueue(
        DOM.Node(id: replacementDocumentID, nodeType: 9, nodeName: "#document"),
        for: "DOM",
        method: "getDocument"
    )
    context.apply(DOM.Event.documentUpdated)
    try await waitUntil { context.rootNode?.id == DOMNode.ID(replacementDocumentID) }
    await mutationGate.open()

    await #expect(throws: WebInspectorProxyError.disconnected("CSS mutation no longer belongs to the current document.")) {
        try await mutationTask.value
    }
    #expect(context.selectedNode == nil)
    #expect(fixture.styles.sections.first?.style.properties.first?.status == .active)
    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "DOM", method: "markUndoableState")) == false)
}

@MainActor
@Test
func lateCSSDeclarationReplyDoesNotApplyToReplacementStyles() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let fixture = try await loadEditableCSSFixture(runtime: runtime, target: target, context: context)
    let mutationGate = WebInspectorTestGate()
    let replacementStyle = CSS.Style(
        id: CSS.Style.ID("style-1"),
        properties: [
            CSS.Property(
                id: CSS.Property.ID("property-1"),
                name: "display",
                value: "flex",
                text: "display: flex;",
                isEditable: true
            )
        ],
        cssText: "display: flex;",
        isEditable: true
    )

    await runtime.backend.hold(domain: "CSS", method: "setStyleText", gate: mutationGate)
    await runtime.backend.enqueue(replacementStyle, for: "CSS", method: "setStyleText")
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    let mutationTask = Task { @MainActor in
        try await context.css.setDeclarationText("display: flex;", for: fixture.propertyID)
    }
    _ = await runtime.backend.waitForRecordedCommands(domain: "CSS", method: "setStyleText", count: 1)

    context.select(nil)
    await mutationGate.open()

    await #expect(throws: WebInspectorProxyError.disconnected("CSS mutation no longer belongs to the current document.")) {
        try await mutationTask.value
    }
    #expect(fixture.styles.sections.first?.style.properties.first?.value == "grid")
    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "DOM", method: "markUndoableState")) == false)
}

@MainActor
@Test
func lateCSSRuleReplyDoesNotRecordUndoAfterDocumentReset() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let ruleID = CSSStyleRule.ID("late-rule")
    let mutationGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "CSS", method: "setRuleSelector", gate: mutationGate)
    await runtime.backend.enqueue(
        CSS.Rule(
            id: ruleID.proxyID,
            selectorList: CSS.Rule.SelectorList(selectors: [".updated"], text: ".updated"),
            origin: CSS.Origin(rawValue: "regular"),
            style: CSS.Style(id: CSS.Style.ID("late-rule-style"))
        ),
        for: "CSS",
        method: "setRuleSelector"
    )
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    let mutationTask = Task { @MainActor in
        try await context.css.setRuleSelector(".updated", for: ruleID)
    }
    _ = await runtime.backend.waitForRecordedCommands(domain: "CSS", method: "setRuleSelector", count: 1)

    context.apply(DOM.Event.documentUpdated)
    await mutationGate.open()

    await #expect(throws: WebInspectorProxyError.disconnected("CSS mutation no longer belongs to the current document.")) {
        try await mutationTask.value
    }
    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "DOM", method: "markUndoableState")) == false)
}

@MainActor
@Test
func destroyedCSSTargetRejectsLateStyleSheetReply() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let frameTargetID = WebInspectorTarget.ID("destroyed-css-frame")
    let styleSheetID = CSS.StyleSheet.ID(
        "destroyed-sheet",
        scopedToTargetRawValue: frameTargetID.rawValue
    )
    let mutationGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "CSS", method: "setStyleSheetText", gate: mutationGate)
    await runtime.backend.enqueue((), for: "CSS", method: "setStyleSheetText")
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    let mutationTask = Task { @MainActor in
        try await context.css.setStyleSheetText("body { color: red; }", for: styleSheetID)
    }
    _ = await runtime.backend.waitForRecordedCommands(domain: "CSS", method: "setStyleSheetText", count: 1)

    context.apply(.targetDestroyed(targetID: frameTargetID))
    await mutationGate.open()

    await #expect(throws: WebInspectorProxyError.disconnected("CSS mutation no longer belongs to the current document.")) {
        try await mutationTask.value
    }
    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "DOM", method: "markUndoableState")) == false)
}

@MainActor
@Test
func childFrameNavigationRejectsLateStyleSheetAndRuleReplies() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (pageTarget, context) = try await startContext(runtime: runtime)
    let frameTargetID = WebInspectorTarget.ID("navigating-css-frame")
    let frameID = FrameID("navigating-child-frame")
    let styleSheetID = CSS.StyleSheet.ID(
        "child-sheet",
        scopedToTargetRawValue: frameTargetID.rawValue
    )
    let ruleProxyID = CSS.Rule.ID(
        "child-sheet\u{1F}1",
        scopedToTargetRawValue: frameTargetID.rawValue
    )
    let ruleID = CSSStyleRule.ID(ruleProxyID)

    let firstHeaderBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(
        .styleSheetAdded(CSS.StyleSheetHeader(
            styleSheetID: styleSheetID,
            frameID: frameID,
            origin: CSS.Origin(rawValue: "author")
        )),
        target: pageTarget
    )
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: firstHeaderBaseline))

    let styleSheetGate = WebInspectorTestGate()
    await runtime.backend.hold(domain: "CSS", method: "setStyleSheetText", gate: styleSheetGate)
    await runtime.backend.enqueue((), for: "CSS", method: "setStyleSheetText")
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    let styleSheetTask = Task { @MainActor in
        try await context.css.setStyleSheetText("body { color: red; }", for: styleSheetID)
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "CSS",
        method: "setStyleSheetText",
        count: 1
    )

    let firstNavigationBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(
        .frameNavigated(WebInspectorPageFrameLifecycle(
            id: frameID,
            parentID: FrameID("main-frame"),
            loaderID: "child-loader-2",
            name: "Child",
            url: "https://example.test/child-2",
            securityOrigin: "https://example.test",
            mimeType: "text/html"
        )),
        target: pageTarget
    )
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: firstNavigationBaseline))
    await styleSheetGate.open()

    await #expect(throws: WebInspectorProxyError.disconnected("CSS mutation no longer belongs to the current document.")) {
        try await styleSheetTask.value
    }

    let secondHeaderBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(
        .styleSheetAdded(CSS.StyleSheetHeader(
            styleSheetID: styleSheetID,
            frameID: frameID,
            origin: CSS.Origin(rawValue: "author")
        )),
        target: pageTarget
    )
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: secondHeaderBaseline))

    let ruleGate = WebInspectorTestGate()
    await runtime.backend.hold(domain: "CSS", method: "setRuleSelector", gate: ruleGate)
    await runtime.backend.enqueue(
        CSS.Rule(
            id: ruleProxyID,
            selectorList: CSS.Rule.SelectorList(selectors: [".updated"], text: ".updated"),
            origin: CSS.Origin(rawValue: "regular"),
            style: CSS.Style(id: CSS.Style.ID(
                "child-sheet\u{1F}1",
                scopedToTargetRawValue: frameTargetID.rawValue
            ))
        ),
        for: "CSS",
        method: "setRuleSelector"
    )
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    let ruleTask = Task { @MainActor in
        try await context.css.setRuleSelector(".updated", for: ruleID)
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "CSS",
        method: "setRuleSelector",
        count: 1
    )

    let secondNavigationBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(
        .frameNavigated(WebInspectorPageFrameLifecycle(
            id: frameID,
            parentID: FrameID("main-frame"),
            loaderID: "child-loader-3",
            name: "Child",
            url: "https://example.test/child-3",
            securityOrigin: "https://example.test",
            mimeType: "text/html"
        )),
        target: pageTarget
    )
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: secondNavigationBaseline))
    await ruleGate.open()

    await #expect(throws: WebInspectorProxyError.disconnected("CSS mutation no longer belongs to the current document.")) {
        try await ruleTask.value
    }
    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "DOM", method: "markUndoableState")) == false)
}

@MainActor
@Test
func childFrameNavigationPreservesUnrelatedStyleSheetMutation() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (pageTarget, context) = try await startContext(runtime: runtime)
    let navigatingFrameID = FrameID("navigating-frame")
    let stableFrameID = FrameID("stable-frame")
    let stableTargetID = WebInspectorTarget.ID("stable-css-frame")
    let stableStyleSheetID = CSS.StyleSheet.ID(
        "stable-sheet",
        scopedToTargetRawValue: stableTargetID.rawValue
    )

    let headerBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(
        .styleSheetAdded(CSS.StyleSheetHeader(
            styleSheetID: stableStyleSheetID,
            frameID: stableFrameID,
            origin: CSS.Origin(rawValue: "author")
        )),
        target: pageTarget
    )
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: headerBaseline))

    let mutationGate = WebInspectorTestGate()
    await runtime.backend.hold(domain: "CSS", method: "setStyleSheetText", gate: mutationGate)
    await runtime.backend.enqueue((), for: "CSS", method: "setStyleSheetText")
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    let mutationTask = Task { @MainActor in
        try await context.css.setStyleSheetText("body { color: green; }", for: stableStyleSheetID)
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "CSS",
        method: "setStyleSheetText",
        count: 1
    )

    let navigationBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(
        .frameNavigated(WebInspectorPageFrameLifecycle(
            id: navigatingFrameID,
            parentID: FrameID("main-frame"),
            loaderID: "navigating-loader-2",
            name: "Navigating",
            url: "https://example.test/navigating",
            securityOrigin: "https://example.test",
            mimeType: "text/html"
        )),
        target: pageTarget
    )
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: navigationBaseline))
    await mutationGate.open()

    try await mutationTask.value
    let commands = await runtime.backend.recordedCommands()
    let undo = try #require(commands.first {
        $0.domain == "DOM" && $0.method == "markUndoableState"
    })
    #expect(undo.targetID == stableTargetID)
}

@MainActor
@Test
func removedAndReusedStyleSheetIDRejectsPriorMutationReply() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (pageTarget, context) = try await startContext(runtime: runtime)
    let frameTargetID = WebInspectorTarget.ID("reused-css-frame")
    let frameID = FrameID("reused-css-frame-id")
    let styleSheetID = CSS.StyleSheet.ID(
        "reused-sheet",
        scopedToTargetRawValue: frameTargetID.rawValue
    )

    let firstHeaderBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(
        .styleSheetAdded(CSS.StyleSheetHeader(
            styleSheetID: styleSheetID,
            frameID: frameID,
            origin: CSS.Origin(rawValue: "author")
        )),
        target: pageTarget
    )
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: firstHeaderBaseline))

    let priorMutationGate = WebInspectorTestGate()
    await runtime.backend.hold(domain: "CSS", method: "setStyleSheetText", gate: priorMutationGate)
    await runtime.backend.enqueue((), for: "CSS", method: "setStyleSheetText")
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    let priorMutationTask = Task { @MainActor in
        try await context.css.setStyleSheetText("body { color: red; }", for: styleSheetID)
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "CSS",
        method: "setStyleSheetText",
        count: 1
    )

    let removalBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(.styleSheetRemoved(styleSheetID), target: pageTarget)
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: removalBaseline))

    let reusedHeaderBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(
        .styleSheetAdded(CSS.StyleSheetHeader(
            styleSheetID: styleSheetID,
            frameID: frameID,
            origin: CSS.Origin(rawValue: "author")
        )),
        target: pageTarget
    )
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: reusedHeaderBaseline))
    await priorMutationGate.open()

    await #expect(throws: WebInspectorProxyError.disconnected("CSS mutation no longer belongs to the current document.")) {
        try await priorMutationTask.value
    }
    var commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "DOM", method: "markUndoableState")) == false)

    await runtime.backend.enqueue((), for: "CSS", method: "setStyleSheetText")
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    try await context.css.setStyleSheetText("body { color: blue; }", for: styleSheetID)

    commands = await runtime.backend.recordedCommands()
    let undoCommands = commands.filter {
        $0.domain == "DOM" && $0.method == "markUndoableState"
    }
    #expect(undoCommands.count == 1)
    #expect(undoCommands.first?.targetID == frameTargetID)
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
    let startupTask = try #require(context.startupTaskForTesting())
    try await waitUntil {
        await runtime.backend.recordedCommands()
            .contains(RecordedCommand(domain: "DOM", method: "getDocument"))
    }

    await container.close()
    #expect(context.state == .detached)

    await gate.open()
    await startupTask.value

    #expect(context.state == .detached)
    #expect(context.rootNode == nil)

    let commands = await runtime.backend.recordedCommands()
    #expect(commands == Array(startupCommands.prefix(6)) + [
        RecordedCommand(domain: "Runtime", method: "disable"),
        RecordedCommand(domain: "Network", method: "disable"),
        RecordedCommand(domain: "Page", method: "disable"),
        RecordedCommand(domain: "Inspector", method: "disable"),
    ])
}

@MainActor
@Test
func stopDuringStartupReleasesLateRuntimeAcquire() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let gate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "Runtime", method: "enable", gate: gate)
    await runtime.backend.enqueue((), for: "Inspector", method: "enable")
    await runtime.backend.enqueue((), for: "Inspector", method: "initialized")
    await runtime.backend.enqueue((), for: "Page", method: "enable")
    await runtime.backend.enqueue((), for: "Runtime", method: "enable")

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitForStartupSubscribers(runtime: runtime, target: target)
    try await waitUntil {
        await runtime.backend.recordedCommands() == [
            RecordedCommand(domain: "Inspector", method: "enable"),
            RecordedCommand(domain: "Inspector", method: "initialized"),
            RecordedCommand(domain: "Page", method: "enable"),
            RecordedCommand(domain: "Runtime", method: "enable"),
        ]
    }

    await runtime.backend.enqueue((), for: "Page", method: "disable")
    await runtime.backend.enqueue((), for: "Inspector", method: "disable")
    await context.stop()
    #expect(context.state == .detached)

    await runtime.backend.enqueue((), for: "Runtime", method: "disable")
    await gate.open()
    try await waitUntil {
        await runtime.backend.recordedCommands() == [
            RecordedCommand(domain: "Inspector", method: "enable"),
            RecordedCommand(domain: "Inspector", method: "initialized"),
            RecordedCommand(domain: "Page", method: "enable"),
            RecordedCommand(domain: "Runtime", method: "enable"),
            RecordedCommand(domain: "Page", method: "disable"),
            RecordedCommand(domain: "Inspector", method: "disable"),
            RecordedCommand(domain: "Runtime", method: "disable"),
        ]
    }
    #expect(context.state == .detached)
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
func domainEnablementKeepsPageAliveForCSSLeaseInDependencyOrder() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let registry = WebInspectorDomainEnablementRegistry()

    await runtime.backend.enqueue((), for: "Page", method: "enable")
    await runtime.backend.enqueue((), for: "CSS", method: "enable")
    try await registry.acquireStyleAccess(on: target)

    await runtime.backend.enqueue((), for: "CSS", method: "disable")
    await runtime.backend.enqueue((), for: "Page", method: "disable")
    #expect(await registry.releaseStyleAccess(on: target) == nil)

    #expect(await runtime.backend.recordedCommands() == [
        RecordedCommand(domain: "Page", method: "enable"),
        RecordedCommand(domain: "CSS", method: "enable"),
        RecordedCommand(domain: "CSS", method: "disable"),
        RecordedCommand(domain: "Page", method: "disable"),
    ])
}

@MainActor
@Test
func domainEnablementFrameCSSLeaseNeverSendsPageCommands() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let registry = WebInspectorDomainEnablementRegistry()
    let target = WebInspectorTarget(
        id: WebInspectorTarget.ID("frame-css-agent"),
        kind: .frame,
        frameID: nil,
        isProvisional: false,
        proxy: runtime.proxy,
        route: RoutingTargetID("frame-css-agent")
    )

    await runtime.backend.enqueue((), for: "CSS", method: "enable")
    try await registry.acquireStyleAccess(on: target)
    await runtime.backend.enqueue((), for: "CSS", method: "disable")
    #expect(await registry.releaseStyleAccess(on: target) == nil)

    #expect(await runtime.backend.recordedCommands() == [
        RecordedCommand(domain: "CSS", method: "enable"),
        RecordedCommand(domain: "CSS", method: "disable"),
    ])
}

@MainActor
@Test
func domainEnablementFrameCSSFailureStaysLocalWithoutPageOrRetry() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let registry = WebInspectorDomainEnablementRegistry()
    let target = WebInspectorTarget(
        id: WebInspectorTarget.ID("frame-css-agent"),
        kind: .frame,
        frameID: nil,
        isProvisional: false,
        proxy: runtime.proxy,
        route: RoutingTargetID("frame-css-agent")
    )
    let failure = WebInspectorProxyError.commandFailed(
        domain: "CSS",
        method: "enable",
        message: "CSS unavailable"
    )

    await runtime.backend.enqueueFailure(failure, for: "CSS", method: "enable")

    await #expect(throws: failure) {
        try await registry.acquireStyleAccess(on: target)
    }
    #expect(await runtime.backend.recordedCommands() == [
        RecordedCommand(domain: "CSS", method: "enable"),
    ])
}

@MainActor
@Test
func domainEnablementCSSFailureRollsBackPageWithoutRetrying() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let registry = WebInspectorDomainEnablementRegistry()
    let failure = WebInspectorProxyError.commandFailed(
        domain: "CSS",
        method: "enable",
        message: "CSS unavailable"
    )

    await runtime.backend.enqueue((), for: "Page", method: "enable")
    await runtime.backend.enqueueFailure(failure, for: "CSS", method: "enable")
    await runtime.backend.enqueue((), for: "Page", method: "disable")

    await #expect(throws: failure) {
        try await registry.acquireStyleAccess(on: target)
    }
    #expect(await runtime.backend.recordedCommands() == [
        RecordedCommand(domain: "Page", method: "enable"),
        RecordedCommand(domain: "CSS", method: "enable"),
        RecordedCommand(domain: "Page", method: "disable"),
    ])
}

@MainActor
@Test
func domainEnablementReacquiresCSSForCommittedPageBinding() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
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

    await runtime.backend.enqueue((), for: "Page", method: "enable")
    await runtime.backend.enqueue((), for: "CSS", method: "enable")
    try await registry.acquireStyleAccess(on: oldPage)
    await registry.discardStyleAccess(on: oldPage)

    await runtime.backend.enqueue((), for: "Page", method: "enable")
    await runtime.backend.enqueue((), for: "CSS", method: "enable")
    try await registry.acquireStyleAccess(on: newPage)

    #expect(await runtime.backend.recordedCommands() == [
        RecordedCommand(domain: "Page", method: "enable"),
        RecordedCommand(domain: "CSS", method: "enable"),
        RecordedCommand(domain: "Page", method: "enable"),
        RecordedCommand(domain: "CSS", method: "enable"),
    ])
}

@MainActor
@Test
func domainEnablementAcquireWaitsForFinalReleaseDisable() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let registry = WebInspectorDomainEnablementRegistry()
    let disableGate = WebInspectorTestGate()

    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    try await registry.acquire(.runtime, on: target)
    await runtime.backend.hold(domain: "Runtime", method: "disable", gate: disableGate)
    await runtime.backend.enqueue((), for: "Runtime", method: "disable")

    let releaseTask = Task {
        await registry.release(.runtime, on: target)
    }
    try await waitUntil {
        await runtime.backend.recordedCommands() == [
            RecordedCommand(domain: "Runtime", method: "enable"),
            RecordedCommand(domain: "Runtime", method: "disable"),
        ]
    }

    let acquireWaitBaseline = await registry.acquireWaitingForDisableSequenceForTesting
    let acquireTask = Task {
        try await registry.acquire(.runtime, on: target)
    }
    await registry.waitForAcquireWaitingForDisableForTesting(after: acquireWaitBaseline)
    #expect(await runtime.backend.recordedCommands() == [
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Runtime", method: "disable"),
    ])

    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    await disableGate.open()

    #expect(await releaseTask.value == nil)
    try await acquireTask.value
    #expect(await runtime.backend.recordedCommands() == [
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Runtime", method: "disable"),
        RecordedCommand(domain: "Runtime", method: "enable"),
    ])
}

@MainActor
@Test
func domainEnablementAcquireWaitsForPendingReleaseDisable() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let registry = WebInspectorDomainEnablementRegistry()
    let enableGate = WebInspectorTestGate()
    let disableGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "Runtime", method: "enable", gate: enableGate)
    await runtime.backend.hold(domain: "Runtime", method: "disable", gate: disableGate)

    let firstAcquireTask = Task {
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
    let acquireWaitBaseline = await registry.acquireWaitingForDisableSequenceForTesting
    let secondAcquireTask = Task {
        try await registry.acquire(.runtime, on: target)
    }
    await registry.waitForAcquireWaitingForDisableForTesting(after: acquireWaitBaseline)

    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    await runtime.backend.enqueue((), for: "Runtime", method: "disable")
    await enableGate.open()
    try await waitUntil {
        await runtime.backend.recordedCommands() == [
            RecordedCommand(domain: "Runtime", method: "enable"),
            RecordedCommand(domain: "Runtime", method: "disable"),
        ]
    }
    #expect(await runtime.backend.recordedCommands() == [
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Runtime", method: "disable"),
    ])

    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    await disableGate.open()

    try await firstAcquireTask.value
    #expect(await releaseTask.value == nil)
    try await secondAcquireTask.value
    #expect(await runtime.backend.recordedCommands() == [
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Runtime", method: "disable"),
        RecordedCommand(domain: "Runtime", method: "enable"),
    ])
}

@MainActor
@Test
func domainEnablementDiscardLeasePreservesSharedEnabledLease() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let registry = WebInspectorDomainEnablementRegistry()

    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    try await registry.acquire(.runtime, on: target)
    try await registry.acquire(.runtime, on: target)

    await registry.discardLease(.runtime, on: target)

    await runtime.backend.enqueue((), for: "Runtime", method: "disable")
    #expect(await registry.release(.runtime, on: target) == nil)

    let commands = await runtime.backend.recordedCommands()
    #expect(commands == [
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Runtime", method: "disable"),
    ])
}

@MainActor
@Test
func domainLeaseRetargetInterleavingReenablesCommittedPageBinding() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
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

    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    try await registry.acquire(.runtime, on: oldPage)
    try await registry.acquire(.runtime, on: oldPage)

    await registry.discardLease(.runtime, on: oldPage)
    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    try await registry.acquire(.runtime, on: newPage)

    await registry.discardLease(.runtime, on: oldPage)
    try await registry.acquire(.runtime, on: newPage)

    let commands = await runtime.backend.recordedCommands()
    #expect(commands == [
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Runtime", method: "enable"),
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
func multipartContinuationPreservesFinishedLifecycleAcrossLaterParts() throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let requestID = Network.Request.ID("multipart-continuation")
    let request = NetworkRequest(
        request: Network.Request(
            id: requestID,
            url: "https://example.com/camera",
            method: "GET"
        ),
        initiator: nil,
        resourceType: .image,
        timestamp: 1,
        modelContext: context
    )
    let responseBody = request.responseBody

    request.applyResponse(
        Network.Response(
            url: "https://example.com/camera",
            status: 200,
            mimeType: "MULTIPART/X-MIXED-REPLACE"
        ),
        resourceType: .image,
        timestamp: 2
    )
    request.finish(timestamp: 3, sourceMapURL: nil, metrics: nil)
    responseBody.load(Network.Body(data: "first part", base64Encoded: false))

    request.applyResponse(
        Network.Response(
            url: "https://example.com/camera",
            status: 200,
            mimeType: "image/jpeg",
            headers: ["X-Part": "2"]
        ),
        resourceType: .image,
        timestamp: 4
    )

    #expect(request.responseBody === responseBody)
    #expect(request.state == .finished)
    #expect(request.finishedOrFailedTimestamp == 3)
    #expect(request.responseReceivedTimestamp == 4)
    #expect(request.mimeType == "image/jpeg")
    #expect(request.responseHeaders["X-Part"] == "2")
    #expect(responseBody.phase == .available)
    #expect(responseBody.full == nil)
    #expect(request.canFetchResponseBody)

    request.applyDataReceived(dataLength: 12, encodedDataLength: 10, timestamp: 5)

    #expect(request.state == .finished)
    #expect(request.finishedOrFailedTimestamp == 3)
    #expect(request.lastDataReceivedTimestamp == 5)
    #expect(request.decodedDataLength == 12)
    #expect(request.encodedDataLength == 10)
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
func networkRequestPreservesInitialInitiatorAcrossRedirects() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("initiator-redirect")
    let initialNodeID = DOM.Node.ID("17")
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "https://example.com/start",
                method: "GET",
                origin: Network.Request.Origin(
                    frameID: FrameID("main-frame"),
                    loaderID: "initial-loader",
                    targetID: "page-initial"
                )
            ),
            initiator: Network.Initiator(kind: "other", nodeID: initialNodeID),
            resourceType: .document,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    try await waitUntil { results.items.count == 1 }
    let initialVisit = try #require(results.items.first?.navigationVisit)
    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "https://example.com/final",
                method: "GET",
                origin: Network.Request.Origin(
                    frameID: FrameID("main-frame"),
                    loaderID: "redirect-loader",
                    targetID: "page-redirect"
                )
            ),
            initiator: Network.Initiator(kind: "other", nodeID: DOM.Node.ID("99")),
            resourceType: .document,
            redirectResponse: Network.Response(
                url: "https://example.com/start",
                status: 302,
                statusText: "Found"
            ),
            timestamp: 2
        ),
        target: target
    )

    try await waitUntil { results.items.first?.redirects.count == 1 }
    let request = try #require(results.items.first)
    #expect(request.initiator?.nodeID == initialNodeID)
    #expect(request.navigationVisit == initialVisit)
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
            initiator: Network.Initiator(kind: "other", nodeID: DOM.Node.ID("41")),
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
    #expect(request.lifecycleRevision == 0)

    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(id: requestID, url: "https://example.com/second", method: "GET"),
            initiator: Network.Initiator(kind: "other", nodeID: DOM.Node.ID("42")),
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
    #expect(request.initiator?.nodeID == DOM.Node.ID("42"))
    #expect(request.lifecycleRevision == 1)
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
                requestHeaders: ["Accept": "text/css"],
                bodySize: 2048
            ),
            initiator: Network.Initiator(kind: "other", nodeID: DOM.Node.ID("23")),
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
    #expect(request.initiator?.nodeID == DOM.Node.ID("23"))
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
            resourceType: nil,
            timestamp: 5
        ),
        target: target
    )
    await runtime.backend.emit(
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
                url: "",
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

    let baseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(
        .webSocket(.other(RawEvent(domain: "Network", method: "webSocketFutureEvent"))),
        target: target
    )
    let didProcessOtherEvent = await context.waitForEventPumpAppliedSequenceForTesting(after: baseline)
    #expect(didProcessOtherEvent)

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
    #expect(request.requestBody === body)
    #expect(request.requestHeaders["Content-Type"] == "application/x-www-form-urlencoded")
    #expect(body.textRepresentation == "name=Jane Doe\ncity=Tokyo East")
    #expect(body.textRepresentationSyntaxKind == .plainText)
}

@MainActor
@Test
func responseMetadataAndRedirectPreserveResponseBodyIdentity() throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let requestID = Network.Request.ID("stable-response-body")
    let request = NetworkRequest(
        request: Network.Request(
            id: requestID,
            url: "https://example.com/start.txt",
            method: "GET"
        ),
        initiator: nil,
        resourceType: .fetch,
        timestamp: 1,
        modelContext: context
    )
    let body = request.responseBody

    request.applyResponse(
        Network.Response(
            url: "https://example.com/start.txt",
            status: 200,
            mimeType: "text/plain"
        ),
        resourceType: .fetch,
        timestamp: 2
    )
    body.load(Network.Body(data: "first payload", base64Encoded: false))

    request.applyResponse(
        Network.Response(
            url: "https://example.com/video.mp4",
            status: 206,
            mimeType: "video/mp4"
        ),
        resourceType: .media,
        timestamp: 3
    )

    #expect(request.responseBody === body)
    #expect(body.phase == .available)
    #expect(body.full == nil)
    #expect(body.size == nil)
    #expect(body.kind == .binary)

    body.load(Network.Body(data: "second payload", base64Encoded: false))
    request.applyRedirect(
        to: Network.Request(
            id: requestID,
            url: "https://example.com/final.json",
            method: "GET"
        ),
        redirectResponse: Network.Response(
            url: "https://example.com/video.mp4",
            status: 302,
            mimeType: "video/mp4"
        ),
        timestamp: 4,
        resourceType: .fetch
    )

    #expect(request.responseBody === body)
    #expect(body.phase == .available)
    #expect(body.full == nil)
    #expect(body.size == nil)
    #expect(body.kind == .text)
    #expect(body.sourceSyntaxKind == .json)
}

enum StaleResponseBodyFetchCompletion: Sendable {
    case success
    case failure
}

@MainActor
@Test(arguments: [
    StaleResponseBodyFetchCompletion.success,
    StaleResponseBodyFetchCompletion.failure,
])
func staleResponseBodyFetchCompletionCannotMutateNewerRevision(
    completion: StaleResponseBodyFetchCompletion
) async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("stale-body-\(completion)")
    let gate = WebInspectorTestGate()

    await emitFinishedRequest(id: requestID, target: target, backend: runtime.backend)
    try await waitUntil {
        context.registeredRequest(for: NetworkRequest.ID(requestID))?.state == .finished
    }
    let request = try #require(context.registeredRequest(for: NetworkRequest.ID(requestID)))
    let body = request.responseBody
    await runtime.backend.hold(domain: "Network", method: "getResponseBody", gate: gate)

    let fetchTask = Task {
        await request.fetchResponseBody()
    }
    try await waitUntil {
        await runtime.backend.recordedCommands().contains(
            RecordedCommand(domain: "Network", method: "getResponseBody")
        )
    }

    await runtime.backend.emit(
        .responseReceived(
            id: requestID,
            response: Network.Response(
                url: "https://example.com/replacement.mp4",
                status: 206,
                mimeType: "video/mp4"
            ),
            resourceType: .media,
            timestamp: 4
        ),
        target: target
    )
    try await waitUntil {
        request.responseBody.phase == .available && request.responseBody.kind == .binary
    }

    switch completion {
    case .success:
        await runtime.backend.enqueue(
            Network.Body(data: "obsolete", base64Encoded: false),
            for: "Network",
            method: "getResponseBody"
        )
    case .failure:
        await runtime.backend.enqueueFailure(
            WebInspectorProxyError.commandFailed(
                domain: "Network",
                method: "getResponseBody",
                message: "obsolete failure"
            ),
            for: "Network",
            method: "getResponseBody"
        )
    }
    await gate.open()
    await fetchTask.value

    #expect(request.responseBody === body)
    #expect(body.phase == .available)
    #expect(body.full == nil)
    #expect(body.size == nil)
    #expect(body.kind == .binary)
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
func concurrentResponseBodyCallersShareCompletionAcrossCallerCancellation() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("coalesced-body-request")
    let gate = WebInspectorTestGate()

    await emitFinishedRequest(id: requestID, target: target, backend: runtime.backend)
    try await waitUntil {
        context.registeredRequest(for: NetworkRequest.ID(requestID))?.state == .finished
    }
    let request = try #require(context.registeredRequest(for: NetworkRequest.ID(requestID)))
    let body = request.responseBody
    await runtime.backend.hold(domain: "Network", method: "getResponseBody", gate: gate)
    await runtime.backend.enqueue(
        Network.Body(data: "shared", base64Encoded: false),
        for: "Network",
        method: "getResponseBody"
    )

    let first = Task { @MainActor in
        await request.fetchResponseBody()
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "Network",
        method: "getResponseBody",
        count: 1
    )
    let second = Task { @MainActor in
        await request.fetchResponseBody()
    }
    try await waitUntil {
        body.responseFetchWaiterCountForTesting == 2
    }

    first.cancel()
    await first.value
    try await waitUntil {
        body.responseFetchWaiterCountForTesting == 1
    }
    #expect(body.phase == .fetching)
    #expect(await runtime.backend.recordedCommands().filter {
        $0 == RecordedCommand(domain: "Network", method: "getResponseBody")
    }.count == 1)

    await gate.open()
    await second.value

    #expect(body.phase == .loaded)
    #expect(body.text == "shared")
    #expect(request.responseBody === body)
    #expect(body.responseFetchWaiterCountForTesting == 0)
}

@MainActor
@Test
func responseReplacementResolvesEveryJoinedResponseBodyWaiter() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("replaced-coalesced-body")
    let gate = WebInspectorTestGate()

    await emitFinishedRequest(id: requestID, target: target, backend: runtime.backend)
    try await waitUntil {
        context.registeredRequest(for: NetworkRequest.ID(requestID))?.state == .finished
    }
    let request = try #require(context.registeredRequest(for: NetworkRequest.ID(requestID)))
    let body = request.responseBody
    await runtime.backend.hold(domain: "Network", method: "getResponseBody", gate: gate)
    await runtime.backend.enqueue(
        Network.Body(data: "obsolete", base64Encoded: false),
        for: "Network",
        method: "getResponseBody"
    )
    let firstProbe = ResponseBodyFetchCompletionProbe()
    let secondProbe = ResponseBodyFetchCompletionProbe()
    let first = Task { @MainActor in
        await request.fetchResponseBody()
        firstProbe.finish()
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "Network",
        method: "getResponseBody",
        count: 1
    )
    let second = Task { @MainActor in
        await request.fetchResponseBody()
        secondProbe.finish()
    }
    try await waitUntil {
        body.responseFetchWaiterCountForTesting == 2
    }

    await runtime.backend.emit(
        .responseReceived(
            id: requestID,
            response: Network.Response(
                url: "https://example.com/replaced-body",
                status: 200,
                mimeType: "multipart/x-mixed-replace"
            ),
            resourceType: .fetch,
            timestamp: 4
        ),
        target: target
    )
    try await waitUntil {
        body.phase == .available
    }

    do {
        try await waitUntil {
            firstProbe.isFinished && secondProbe.isFinished
        }
    } catch {
        await gate.open()
        await first.value
        await second.value
        throw error
    }

    #expect(request.responseBody === body)
    #expect(body.phase == .available)
    #expect(body.full == nil)
    #expect(body.responseFetchWaiterCountForTesting == 0)
    await gate.open()
    await first.value
    await second.value
}

@MainActor
@Test
func clearingNetworkResolvesEveryJoinedResponseBodyWaiter() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("cleared-coalesced-body")
    let gate = WebInspectorTestGate()

    await emitFinishedRequest(id: requestID, target: target, backend: runtime.backend)
    try await waitUntil {
        context.registeredRequest(for: NetworkRequest.ID(requestID))?.state == .finished
    }
    let request = try #require(context.registeredRequest(for: NetworkRequest.ID(requestID)))
    let body = request.responseBody
    await runtime.backend.hold(domain: "Network", method: "getResponseBody", gate: gate)
    await runtime.backend.enqueue(
        Network.Body(data: "obsolete", base64Encoded: false),
        for: "Network",
        method: "getResponseBody"
    )
    let firstProbe = ResponseBodyFetchCompletionProbe()
    let secondProbe = ResponseBodyFetchCompletionProbe()
    let first = Task { @MainActor in
        await request.fetchResponseBody()
        firstProbe.finish()
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "Network",
        method: "getResponseBody",
        count: 1
    )
    let second = Task { @MainActor in
        await request.fetchResponseBody()
        secondProbe.finish()
    }
    try await waitUntil {
        body.responseFetchWaiterCountForTesting == 2
    }

    context.clearNetworkRequests()
    #expect(context.registeredRequest(for: NetworkRequest.ID(requestID)) == nil)

    do {
        try await waitUntil {
            firstProbe.isFinished && secondProbe.isFinished
        }
    } catch {
        await gate.open()
        await first.value
        await second.value
        throw error
    }

    #expect(
        body.phase
            == NetworkBody.Phase.failed(NetworkBody.invalidatedResponseFetchError)
    )
    #expect(body.text == nil)
    #expect(request.responseBody === body)
    #expect(body.responseFetchWaiterCountForTesting == 0)
    await gate.open()
    await first.value
    await second.value
}

@MainActor
@Test
func fetchResponseBodyRejectsLateCompletionAfterNetworkClear() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("cleared-body-request")
    let gate = WebInspectorTestGate()

    await emitFinishedRequest(id: requestID, target: target, backend: runtime.backend)
    try await waitUntil {
        context.registeredRequest(for: NetworkRequest.ID(requestID))?.state == .finished
    }
    let request = try #require(context.registeredRequest(for: NetworkRequest.ID(requestID)))
    let body = request.responseBody
    await runtime.backend.hold(domain: "Network", method: "getResponseBody", gate: gate)

    let fetchTask = Task {
        await request.fetchResponseBody()
    }
    try await waitUntil {
        await runtime.backend.recordedCommands().contains(RecordedCommand(domain: "Network", method: "getResponseBody"))
    }

    context.clearNetworkRequests()
    #expect(context.registeredRequest(for: NetworkRequest.ID(requestID)) == nil)
    await runtime.backend.enqueue(
        Network.Body(data: "stale-body", base64Encoded: false),
        for: "Network",
        method: "getResponseBody"
    )
    await gate.open()
    await fetchTask.value

    #expect(
        body.phase
            == NetworkBody.Phase.failed(NetworkBody.invalidatedResponseFetchError)
    )
    #expect(body.text == nil)
    #expect(request.responseBody === body)
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

    await runtime.backend.emit(
        .messagesCleared(reason: Console.ClearReason(rawValue: "console-api")),
        target: target
    )
    try await waitUntil { results.items.isEmpty }
    #expect(context.registeredMessage(for: message.id) == nil)
}

@MainActor
@Test
func consoleRepeatUpdatesStayWithinTheirTarget() throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let firstTargetID = WebInspectorTarget.ID("console-frame-a")
    let secondTargetID = WebInspectorTarget.ID("console-frame-b")
    let unknownTargetID = WebInspectorTarget.ID("console-frame-unknown")

    context.apply(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "log"),
            text: "first"
        )),
        targetID: firstTargetID
    )
    context.apply(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "log"),
            text: "second"
        )),
        targetID: secondTargetID
    )

    let results: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()
    let first = try #require(results.items.first { $0.targetID == firstTargetID })
    let second = try #require(results.items.first { $0.targetID == secondTargetID })

    context.apply(
        .messageRepeatCountUpdated(count: 3, timestamp: 3),
        targetID: firstTargetID
    )
    context.apply(
        .messageRepeatCountUpdated(count: 9, timestamp: 9),
        targetID: unknownTargetID
    )

    #expect(first.repeatCount == 3)
    #expect(first.timestamp == 3)
    #expect(second.repeatCount == 1)
    #expect(second.timestamp == nil)
}

@MainActor
@Test
func consoleFetchedResultsHonorDescriptorsForInitialUpdatesAndDescriptorChanges() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let allResults: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()

    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "warning"),
            text: "middle"
        )),
        target: target
    )
    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "javascript"),
            level: Console.Level(rawValue: "error"),
            text: "zeta"
        )),
        target: target
    )
    await runtime.backend.emit(
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

    await runtime.backend.emit(
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

@MainActor
@Test
func consoleFetchedResultsPreserveTieOrderAndCustomComparators() {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    for text in ["item2", "item10"] {
        context.apply(.messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "log"),
            text: text
        )))
    }

    let reverseTieResults: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults(
        for: WebInspectorFetchDescriptor(
            sortBy: [SortDescriptor(\.level.rawValue, order: .reverse)],
            fetchLimit: 1
        )
    )
    let lexicalResults: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults(
        for: WebInspectorFetchDescriptor(
            sortBy: [SortDescriptor(\.text, comparator: .lexical)]
        )
    )

    #expect(reverseTieResults.items.map(\.text) == ["item2"])
    #expect(lexicalResults.items.map(\.text) == ["item10", "item2"])
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
func consoleMessagesClearedInvalidatesRuntimeObjectsWithoutRuntimeCommand() async throws {
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

    let commandCountBeforeClear = await runtime.backend.recordedCommands().count
    await runtime.backend.emit(
        .messagesCleared(reason: Console.ClearReason(rawValue: "console-api")),
        target: target
    )

    try await waitUntil { results.items.isEmpty }
    #expect(parameter.canRequestProperties == false)
    do {
        _ = try await parameter.properties()
        Issue.record("Expected cleared console RuntimeObject to be stale.")
    } catch let error as WebInspectorProxyError {
        #expect(error == .disconnected("RuntimeObject is not registered in this WebInspectorContext."))
    }
    let clearCommands = await runtime.backend.recordedCommands().dropFirst(commandCountBeforeClear)
    #expect(!clearCommands.contains(RecordedCommand(domain: "Runtime", method: "releaseObjectGroup")))
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
    #expect(evaluation.object.canRequestProperties == false)

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
func lateEvaluateReplyDoesNotRegisterObjectAfterContextDestruction() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let contextID = Runtime.ExecutionContext.ID("late-evaluate-context")
    let evaluationGate = WebInspectorTestGate()

    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(
            id: contextID,
            name: "Main",
            frameID: FrameID("main-frame"),
            kind: .normal
        )),
        target: target
    )
    try await waitUntil { context.executionContexts.count == 1 }
    let runtimeContext = try #require(context.executionContexts.first)

    await runtime.backend.hold(domain: "Runtime", method: "evaluate", gate: evaluationGate)
    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(
                id: Runtime.RemoteObject.ID("late-evaluate-object"),
                kind: .object,
                description: "stale"
            )
        ),
        for: "Runtime",
        method: "evaluate"
    )
    await runtime.backend.enqueue((), for: "Runtime", method: "releaseObject")

    var evaluationError: WebInspectorProxyError?
    let evaluationTask = Task { @MainActor in
        do {
            _ = try await context.evaluate("window", in: runtimeContext)
        } catch {
            evaluationError = error as? WebInspectorProxyError
        }
    }
    _ = await runtime.backend.waitForRecordedCommands(domain: "Runtime", method: "evaluate", count: 1)

    await runtime.backend.emit(.executionContextDestroyed(contextID), target: target)
    try await waitUntil { context.executionContexts.isEmpty }
    await evaluationGate.open()

    await evaluationTask.value
    #expect(evaluationError == .disconnected("Runtime command result is no longer current."))
    let commands = await runtime.backend.recordedCommands()
    let releaseCommand = try #require(commands.last {
        $0.domain == "Runtime" && $0.method == "releaseObject"
    })
    let releasePayload = try #require(
        releaseCommand.payload.cast(as: Runtime.ReleaseObjectPayload.self)
    )
    #expect(releaseCommand.targetID == target.id)
    #expect(releasePayload.id == Runtime.RemoteObject.ID("late-evaluate-object"))
    #expect(context.state == .attached)
}

@MainActor
@Test
func evaluateRejectsRemoteObjectOwnedByDifferentTarget() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let frameTargetID = WebInspectorTarget.ID("runtime-frame")
    let otherTargetID = WebInspectorTarget.ID("other-runtime-frame")
    let contextID = Runtime.ExecutionContext.ID(
        "frame-context",
        scopedToTargetRawValue: frameTargetID.rawValue
    )
    let otherObjectID = Runtime.RemoteObject.ID(
        "foreign-object",
        scopedToTargetRawValue: otherTargetID.rawValue
    )

    context.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: contextID,
            name: "Frame",
            frameID: FrameID("runtime-frame-id"),
            kind: .normal
        )),
        targetID: frameTargetID
    )
    let frameContext = try #require(context.executionContexts.first)

    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(id: otherObjectID, kind: .object)
        ),
        for: "Runtime",
        method: "evaluate"
    )
    await runtime.backend.enqueue((), for: "Runtime", method: "releaseObject")

    do {
        _ = try await context.evaluate("window", in: frameContext)
        Issue.record("Expected an evaluation result from another target to be rejected.")
    } catch let error as WebInspectorProxyError {
        #expect(error == .disconnected("Runtime command result is no longer current."))
    }

    let commands = await runtime.backend.recordedCommands()
    #expect(
        commands.first {
            $0.domain == "Runtime" && $0.method == "evaluate"
        }?.targetID == frameTargetID
    )
    let releaseCommand = try #require(commands.first {
        $0.domain == "Runtime" && $0.method == "releaseObject"
    })
    let releasePayload = try #require(
        releaseCommand.payload.cast(as: Runtime.ReleaseObjectPayload.self)
    )
    #expect(releaseCommand.targetID == otherTargetID)
    #expect(releasePayload.id == otherObjectID)
    #expect(context.state == .attached)

    let frameObjectID = Runtime.RemoteObject.ID(
        "frame-object",
        scopedToTargetRawValue: frameTargetID.rawValue
    )
    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(id: frameObjectID, kind: .object)
        ),
        for: "Runtime",
        method: "evaluate"
    )
    let evaluation = try await context.evaluate("window", in: frameContext)
    #expect(evaluation.object.canRequestProperties)
}

@MainActor
@Test
func propertiesRejectAccessorOwnedByDifferentTarget() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let frameTargetID = WebInspectorTarget.ID("property-runtime-frame")
    let otherTargetID = WebInspectorTarget.ID("other-property-runtime-frame")
    let contextID = Runtime.ExecutionContext.ID(
        "property-frame-context",
        scopedToTargetRawValue: frameTargetID.rawValue
    )

    context.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: contextID,
            name: "Property frame",
            frameID: FrameID("property-frame-id"),
            kind: .normal
        )),
        targetID: frameTargetID
    )
    let frameContext = try #require(context.executionContexts.first)
    let rootObjectID = Runtime.RemoteObject.ID(
        "property-root",
        scopedToTargetRawValue: frameTargetID.rawValue
    )
    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(id: rootObjectID, kind: .object)
        ),
        for: "Runtime",
        method: "evaluate"
    )
    let root = try await context.evaluate("window", in: frameContext).object

    let foreignAccessorID = Runtime.RemoteObject.ID(
        "foreign-getter",
        scopedToTargetRawValue: otherTargetID.rawValue
    )
    await runtime.backend.enqueue(
        [
            Runtime.PropertyDescriptor(
                name: "value",
                get: Runtime.RemoteObject(id: foreignAccessorID, kind: .function)
            )
        ],
        for: "Runtime",
        method: "getProperties"
    )
    await runtime.backend.enqueue((), for: "Runtime", method: "releaseObject")

    do {
        _ = try await root.properties()
        Issue.record("Expected a property accessor from another target to be rejected.")
    } catch let error as WebInspectorProxyError {
        #expect(error == .disconnected("Runtime command result is no longer current."))
    }

    let commands = await runtime.backend.recordedCommands()
    #expect(
        commands.first {
            $0.domain == "Runtime" && $0.method == "getProperties"
        }?.targetID == frameTargetID
    )
    let releaseCommand = try #require(commands.first {
        $0.domain == "Runtime" && $0.method == "releaseObject"
    })
    let releasePayload = try #require(
        releaseCommand.payload.cast(as: Runtime.ReleaseObjectPayload.self)
    )
    #expect(releaseCommand.targetID == otherTargetID)
    #expect(releasePayload.id == foreignAccessorID)
    #expect(root.canRequestProperties)
    #expect(context.state == .attached)
}

@MainActor
@Test
func childFrameNavigationAndDetachClearOnlyChildRuntimeAuthority() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let mainContextID = Runtime.ExecutionContext.ID("main-context")
    let childContextID = Runtime.ExecutionContext.ID("child-context")
    let childFrameID = FrameID("child-frame")
    let propertiesGate = WebInspectorTestGate()

    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(
            id: mainContextID,
            name: "Main",
            frameID: FrameID("main-frame"),
            kind: .normal
        )),
        target: target
    )
    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(
            id: childContextID,
            name: "Child",
            frameID: childFrameID,
            kind: .normal
        )),
        target: target
    )
    try await waitUntil { context.executionContexts.count == 2 }
    let childContext = try #require(context.executionContexts.first {
        $0.id == RuntimeContext.ID(childContextID)
    })

    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(
                id: Runtime.RemoteObject.ID("child-window"),
                kind: .object,
                description: "child window"
            )
        ),
        for: "Runtime",
        method: "evaluate"
    )
    let childWindow = try await context.evaluate("window", in: childContext).object

    await runtime.backend.hold(domain: "Runtime", method: "getProperties", gate: propertiesGate)
    await runtime.backend.enqueue(
        [
            Runtime.PropertyDescriptor(
                name: "lateChild",
                value: Runtime.RemoteObject(
                    id: Runtime.RemoteObject.ID("late-child-property"),
                    kind: .object
                )
            )
        ],
        for: "Runtime",
        method: "getProperties"
    )
    var propertiesError: WebInspectorProxyError?
    let propertiesTask = Task { @MainActor in
        do {
            _ = try await childWindow.properties()
        } catch {
            propertiesError = error as? WebInspectorProxyError
        }
    }
    _ = await runtime.backend.waitForRecordedCommands(domain: "Runtime", method: "getProperties", count: 1)

    let lifecycleBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(
        .frameNavigated(WebInspectorPageFrameLifecycle(
            id: childFrameID,
            parentID: FrameID("main-frame"),
            loaderID: "child-loader-2",
            name: "Child",
            url: "https://example.test/child-next",
            securityOrigin: "https://example.test",
            mimeType: "text/html"
        )),
        target: target
    )
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: lifecycleBaseline))
    #expect(context.executionContexts.map(\.id) == [RuntimeContext.ID(mainContextID)])

    await propertiesGate.open()
    await propertiesTask.value
    #expect(propertiesError == .disconnected("Runtime command result is no longer current."))
    #expect(context.executionContexts.map(\.id) == [RuntimeContext.ID(mainContextID)])

    let detachedContextID = Runtime.ExecutionContext.ID("detached-child-context")
    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(
            id: detachedContextID,
            name: "Detached child",
            frameID: childFrameID,
            kind: .normal
        )),
        target: target
    )
    try await waitUntil { context.executionContexts.count == 2 }
    let detachBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(.frameDetached(frameID: childFrameID), target: target)
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: detachBaseline))
    #expect(context.executionContexts.map(\.id) == [RuntimeContext.ID(mainContextID)])
}

@MainActor
@Test
func newNormalFrameContextReplacesPriorTargetContextsAndObjects() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let frameTargetID = WebInspectorTarget.ID("frame-runtime-replacement")
    let frameID = FrameID("child-frame")
    let firstContextID = Runtime.ExecutionContext.ID(
        "1",
        scopedToTargetRawValue: frameTargetID.rawValue
    )
    let utilityContextID = Runtime.ExecutionContext.ID(
        "2",
        scopedToTargetRawValue: frameTargetID.rawValue
    )
    let replacementContextID = Runtime.ExecutionContext.ID(
        "3",
        scopedToTargetRawValue: frameTargetID.rawValue
    )

    context.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: firstContextID,
            name: "First",
            frameID: frameID,
            kind: .normal
        )),
        targetID: frameTargetID
    )
    context.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: utilityContextID,
            name: "Utility",
            frameID: frameID,
            kind: .user
        )),
        targetID: frameTargetID
    )
    let firstContext = try #require(context.executionContexts.first {
        $0.id == RuntimeContext.ID(firstContextID)
    })

    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(
                id: Runtime.RemoteObject.ID(
                    "old-object",
                    scopedToTargetRawValue: frameTargetID.rawValue
                ),
                kind: .object
            )
        ),
        for: "Runtime",
        method: "evaluate"
    )
    let oldObject = try await context.evaluate("window", in: firstContext).object

    await runtime.backend.enqueue(
        [Runtime.PropertyDescriptor(name: "frameProperty")],
        for: "Runtime",
        method: "getProperties"
    )
    _ = try await oldObject.properties()

    context.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: firstContextID,
            name: "First Updated",
            frameID: frameID,
            kind: .normal
        )),
        targetID: frameTargetID
    )
    #expect(context.executionContexts.first { $0.id == firstContext.id } === firstContext)
    #expect(firstContext.name == "First Updated")
    #expect(oldObject.canRequestProperties)

    let frameCommands = await runtime.backend.recordedCommands()
        .filter { $0.domain == "Runtime" }
    #expect(frameCommands.first { $0.method == "evaluate" }?.targetID == frameTargetID)
    #expect(frameCommands.first { $0.method == "getProperties" }?.targetID == frameTargetID)

    context.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: replacementContextID,
            name: "Replacement",
            frameID: frameID,
            kind: .normal
        )),
        targetID: frameTargetID
    )

    #expect(context.executionContexts.map(\.id) == [RuntimeContext.ID(replacementContextID)])
    #expect(oldObject.canRequestProperties == false)
    do {
        _ = try await oldObject.properties()
        Issue.record("Expected the replaced frame RuntimeObject to be stale.")
    } catch let error as WebInspectorProxyError {
        #expect(error == .disconnected("RuntimeObject is not registered in this WebInspectorContext."))
    }
}

@MainActor
@Test
func destroyedTargetRejectsLateCollectionEntriesReply() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (pageTarget, context) = try await startContext(runtime: runtime)
    let frameTargetID = WebInspectorTarget.ID("destroyed-runtime-frame")
    let contextID = Runtime.ExecutionContext.ID(
        "1",
        scopedToTargetRawValue: frameTargetID.rawValue
    )
    let collectionGate = WebInspectorTestGate()

    context.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: contextID,
            name: "Frame",
            frameID: FrameID("destroyed-frame"),
            kind: .normal
        )),
        targetID: frameTargetID
    )
    let frameContext = try #require(context.executionContexts.first)
    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(
                id: Runtime.RemoteObject.ID(
                    "frame-collection",
                    scopedToTargetRawValue: frameTargetID.rawValue
                ),
                kind: .object
            )
        ),
        for: "Runtime",
        method: "evaluate"
    )
    let collection = try await context.evaluate("new Map", in: frameContext).object

    await runtime.backend.hold(domain: "Runtime", method: "getCollectionEntries", gate: collectionGate)
    await runtime.backend.enqueue(
        [
            Runtime.CollectionEntry(
                value: Runtime.RemoteObject(
                    id: Runtime.RemoteObject.ID(
                        "late-entry",
                        scopedToTargetRawValue: frameTargetID.rawValue
                    ),
                    kind: .object
                )
            )
        ],
        for: "Runtime",
        method: "getCollectionEntries"
    )
    await runtime.backend.enqueue((), for: "Runtime", method: "releaseObject")
    var entriesError: WebInspectorProxyError?
    let entriesTask = Task { @MainActor in
        do {
            _ = try await collection.collectionEntries()
        } catch {
            entriesError = error as? WebInspectorProxyError
        }
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "Runtime",
        method: "getCollectionEntries",
        count: 1
    )
    let frameCommands = await runtime.backend.recordedCommands()
        .filter { $0.domain == "Runtime" }
    #expect(frameCommands.first { $0.method == "evaluate" }?.targetID == frameTargetID)
    #expect(frameCommands.first { $0.method == "getCollectionEntries" }?.targetID == frameTargetID)

    let lifecycleBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(.targetDestroyed(targetID: frameTargetID), target: pageTarget)
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: lifecycleBaseline))
    #expect(context.executionContexts.isEmpty)
    #expect(collection.canRequestProperties == false)
    await collectionGate.open()

    await entriesTask.value
    #expect(entriesError == .disconnected("Runtime command result is no longer current."))
    let commands = await runtime.backend.recordedCommands()
    let releaseCommand = try #require(commands.last {
        $0.domain == "Runtime" && $0.method == "releaseObject"
    })
    let releasePayload = try #require(
        releaseCommand.payload.cast(as: Runtime.ReleaseObjectPayload.self)
    )
    #expect(releaseCommand.targetID == frameTargetID)
    #expect(
        releasePayload.id == Runtime.RemoteObject.ID(
            "late-entry",
            scopedToTargetRawValue: frameTargetID.rawValue
        )
    )
    #expect(context.state == .attached)
}

@MainActor
@Test
func childScopedExecutionContextsClearedPreservesMainRuntimeAuthority() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (pageTarget, context) = try await startContext(runtime: runtime)
    let mainContextID = Runtime.ExecutionContext.ID("main-clear-context")
    let frameTargetID = WebInspectorTarget.ID("frame-clear-target")
    let childContextID = Runtime.ExecutionContext.ID(
        "child-clear-context",
        scopedToTargetRawValue: frameTargetID.rawValue
    )

    context.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: mainContextID,
            name: "Main",
            frameID: FrameID("main-frame"),
            kind: .normal
        )),
        targetID: pageTarget.id
    )
    context.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: childContextID,
            name: "Child",
            frameID: FrameID("child-frame"),
            kind: .normal
        )),
        targetID: frameTargetID
    )
    let mainContext = try #require(context.executionContexts.first {
        $0.id == RuntimeContext.ID(mainContextID)
    })
    let childContext = try #require(context.executionContexts.first {
        $0.id == RuntimeContext.ID(childContextID)
    })

    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(
                id: Runtime.RemoteObject.ID("main-clear-object"),
                kind: .object
            )
        ),
        for: "Runtime",
        method: "evaluate"
    )
    let mainObject = try await context.evaluate("window", in: mainContext).object
    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(
                id: Runtime.RemoteObject.ID(
                    "child-clear-object",
                    scopedToTargetRawValue: frameTargetID.rawValue
                ),
                kind: .object
            )
        ),
        for: "Runtime",
        method: "evaluate"
    )
    let childObject = try await context.evaluate("window", in: childContext).object

    context.apply(
        .executionContextsCleared(target: frameTargetID),
        targetID: pageTarget.id
    )

    #expect(context.executionContexts.map(\.id) == [RuntimeContext.ID(mainContextID)])
    #expect(context.selectedContext === mainContext)
    #expect(mainObject.canRequestProperties)
    #expect(childObject.canRequestProperties == false)
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
        RecordedCommand(domain: "Page", method: "enable"),
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
        RecordedCommand(domain: "Page", method: "disable"),
        RecordedCommand(domain: "Inspector", method: "disable"),
    ]
}

private func enqueueStartupReplies(
    on backend: WebInspectorTestBackend,
    document: DOM.Node = DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document")
) async {
    await enqueueDomainEnableReplies(on: backend)
    await backend.enqueue((), for: "CSS", method: "enable")
    await backend.enqueue(document, for: "DOM", method: "getDocument")
}

private func enqueueDomainEnableReplies(on backend: WebInspectorTestBackend) async {
    await backend.enqueue((), for: "Inspector", method: "enable")
    await backend.enqueue((), for: "Inspector", method: "initialized")
    await backend.enqueue((), for: "Page", method: "enable")
    await backend.enqueue((), for: "Runtime", method: "enable")
    await backend.enqueue((), for: "Network", method: "enable")
    await backend.enqueue((), for: "Console", method: "enable")
}

private func enqueueDomainDisableReplies(on backend: WebInspectorTestBackend) async {
    await backend.enqueue((), for: "Console", method: "disable")
    await backend.enqueue((), for: "Runtime", method: "disable")
    await backend.enqueue((), for: "Network", method: "disable")
    await backend.enqueue((), for: "Page", method: "disable")
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

private struct EditableCSSFixture {
    var styles: CSSStyles
    var propertyID: CSSStyleProperty.ID
}

@MainActor
private func loadEditableCSSFixture(
    runtime: WebInspectorProxyTestRuntime,
    target: WebInspectorTarget,
    context: WebInspectorContext
) async throws -> EditableCSSFixture {
    let document = try #require(context.rootNode)
    let elementID = DOM.Node.ID("authority-styled-node")
    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )
    try await waitUntil { context.node(for: DOMNode.ID(elementID)) != nil }
    let element = try #require(context.node(for: DOMNode.ID(elementID)))

    await enqueueCSSStyleReplies(on: runtime.backend)
    context.select(element)
    let styles = try #require(element.elementStyles)
    try await waitUntil { styles.phase == .loaded }
    let propertyID = try #require(styles.sections.first?.style.properties.first?.id)
    return EditableCSSFixture(styles: styles, propertyID: propertyID)
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
    documentID: String,
    protocolProfile: WebInspectorProtocolProfile = .released26
) async throws -> (FakeTransportBackend, TransportSession, WebInspectorContext) {
    let backend = FakeTransportBackend()
    let transport = TransportSession(
        backend: backend,
        protocolProfile: protocolProfile,
        responseTimeout: .milliseconds(750)
    )
    await installTransportPageTarget(in: transport, targetID: targetID)
    let proxy = try await WebInspectorProxy(transport: transport)
    let container = WebInspectorContainer(proxy: proxy)
    let context = container.mainContext

    try await replyTransportInspectorAndPageInitialization(backend, transport: transport, targetID: targetID)

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
private func replyTransportInspectorAndPageInitialization(
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

    let pageEnable = try await waitForTransportTargetMessage(
        backend,
        method: "Page.enable",
        after: count,
        timeout: timeout
    )
    #expect(pageEnable.targetIdentifier == targetID)
    await receiveTransportTargetReply(
        transport,
        targetID: pageEnable.targetIdentifier,
        messageID: try transportMessageID(pageEnable.message),
        result: "{}"
    )

    return (enable: inspectorEnable, initialized: inspectorInitialized)
}

private func installTransportPageTarget(
    in transport: TransportSession,
    targetID: ProtocolTarget.ID,
    frameID: String = "main-frame"
) async {
    let escapedTargetID = jsonEscapedString(targetID.rawValue)
    let escapedFrameID = jsonEscapedString(frameID)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"\#(escapedTargetID)","type":"page","isProvisional":false,"isPaused":false}}}"#
    )
    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Page.frameNavigated",
        params: #"{"frame":{"id":"\#(escapedFrameID)","loaderId":"main-loader","name":"Main","url":"https://example.test/","securityOrigin":"https://example.test","mimeType":"text/html"}}"#
    )
}

private func installTransportFrameTarget(
    in transport: TransportSession,
    pageTargetID: ProtocolTarget.ID,
    targetID: ProtocolTarget.ID,
    frameID: String,
    parentFrameID: String
) async {
    let escapedTargetID = jsonEscapedString(targetID.rawValue)
    let escapedFrameID = jsonEscapedString(frameID)
    let escapedParentFrameID = jsonEscapedString(parentFrameID)
    await receiveTransportTargetEvent(
        transport,
        targetID: pageTargetID,
        method: "Page.frameNavigated",
        params: #"{"frame":{"id":"\#(escapedFrameID)","parentId":"\#(escapedParentFrameID)","loaderId":"frame-loader","name":"Frame","url":"https://frame.example.test/","securityOrigin":"https://frame.example.test","mimeType":"text/html"}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"\#(escapedTargetID)","type":"frame","isProvisional":false,"isPaused":false}}}"#
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

private func emitTransportNetworkRequest(
    id: String,
    frameID: String,
    loaderID: String,
    timestamp: Double,
    targetID: ProtocolTarget.ID,
    transport: TransportSession
) async {
    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Network.requestWillBeSent",
        params: #"{"requestId":"\#(jsonEscapedString(id))","frameId":"\#(jsonEscapedString(frameID))","loaderId":"\#(jsonEscapedString(loaderID))","request":{"url":"https://example.test/\#(jsonEscapedString(id))","method":"GET"},"initiator":{"type":"parser","nodeId":42},"type":"Fetch","timestamp":\#(timestamp)}"#
    )
}

private func emitOriginatedNetworkRequest(
    id: String,
    frameID: String = "main-frame",
    loaderID: String,
    originTargetID: String?,
    timestamp: Double,
    target: WebInspectorTarget,
    backend: WebInspectorTestBackend
) async {
    let requestID = Network.Request.ID(id)
    await backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "https://example.test/\(id)",
                method: "GET",
                origin: Network.Request.Origin(
                    frameID: FrameID(frameID),
                    loaderID: loaderID,
                    targetID: originTargetID
                )
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: timestamp
        ),
        target: target
    )
}

@MainActor
private func applyOriginatedNetworkRequest(
    id: String,
    frameID: String = "main-frame",
    loaderID: String,
    originTargetID: String?,
    timestamp: Double,
    context: WebInspectorContext
) async {
    let requestID = Network.Request.ID(id)
    await context.apply(.requestWillBeSent(
        id: requestID,
        request: Network.Request(
            id: requestID,
            url: "https://example.test/\(id)",
            method: "GET",
            origin: Network.Request.Origin(
                frameID: FrameID(frameID),
                loaderID: loaderID,
                targetID: originTargetID
            )
        ),
        resourceType: .fetch,
        redirectResponse: nil,
        timestamp: timestamp
    ))
}

private enum NetworkTopLevelCommitOrder {
    case targetThenFrame
    case frameThenTarget
}

@MainActor
private func networkVisitsAcrossTopLevelCommit(
    order: NetworkTopLevelCommitOrder,
    provisionalOriginTargetID: String? = "page-next",
    currentLoaderID: String = "reused-loader",
    provisionalLoaderID: String = "reused-loader"
) async throws -> (provisional: NetworkNavigationVisit, committed: NetworkNavigationVisit) {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let results: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()

    await emitOriginatedNetworkRequest(
        id: "commit-order-current",
        loaderID: currentLoaderID,
        originTargetID: "page-current",
        timestamp: 1,
        target: target,
        backend: runtime.backend
    )
    await emitOriginatedNetworkRequest(
        id: "commit-order-provisional",
        loaderID: provisionalLoaderID,
        originTargetID: provisionalOriginTargetID,
        timestamp: 2,
        target: target,
        backend: runtime.backend
    )
    try await waitUntil { results.items.count == 2 }
    let provisionalVisit = try #require(results.items[1].navigationVisit)

    switch order {
    case .targetThenFrame:
        try await emitTopLevelTargetCommit(
            target: target,
            context: context,
            backend: runtime.backend,
            documentID: "target-before-frame-root"
        )
        try await emitTopLevelFrameCommit(
            target: target,
            context: context,
            backend: runtime.backend,
            documentID: "frame-after-target-root",
            loaderID: provisionalLoaderID
        )
    case .frameThenTarget:
        try await emitTopLevelFrameCommit(
            target: target,
            context: context,
            backend: runtime.backend,
            documentID: "frame-before-target-root",
            loaderID: provisionalLoaderID
        )
        try await emitTopLevelTargetCommit(
            target: target,
            context: context,
            backend: runtime.backend,
            documentID: "target-after-frame-root"
        )
    }

    await emitOriginatedNetworkRequest(
        id: "commit-order-committed",
        loaderID: provisionalLoaderID,
        originTargetID: provisionalOriginTargetID,
        timestamp: 3,
        target: target,
        backend: runtime.backend
    )
    try await waitUntil { results.items.count == 3 }
    return (provisionalVisit, try #require(results.items[2].navigationVisit))
}

@MainActor
private func emitTopLevelTargetCommit(
    target: WebInspectorTarget,
    context: WebInspectorContext,
    backend: WebInspectorTestBackend,
    documentID: String,
    pageBindingID: String = "page-next"
) async throws {
    await enqueueStartupReplies(
        on: backend,
        document: DOM.Node(id: DOM.Node.ID(documentID), nodeType: 9, nodeName: "#document")
    )
    await backend.emit(
        .didCommitProvisionalTarget(WebInspectorTargetCommitLifecycle(
            oldTargetID: .currentPage,
            newTarget: WebInspectorLifecycleTarget(
                id: .currentPage,
                kind: .page,
                frameID: FrameID("main-frame"),
                isProvisional: false,
                pageBindingID: pageBindingID
            )
        )),
        target: target
    )
    try await waitUntil {
        context.rootNode?.id == DOMNode.ID(DOM.Node.ID(documentID))
            && context.state == .attached
    }
}

@MainActor
private func emitTopLevelFrameCommit(
    target: WebInspectorTarget,
    context: WebInspectorContext,
    backend: WebInspectorTestBackend,
    documentID: String,
    loaderID: String
) async throws {
    await backend.enqueue(
        DOM.Node(id: DOM.Node.ID(documentID), nodeType: 9, nodeName: "#document"),
        for: "DOM",
        method: "getDocument"
    )
    await backend.emit(
        .frameNavigated(WebInspectorPageFrameLifecycle(
            id: FrameID("main-frame"),
            parentID: nil,
            loaderID: loaderID,
            name: "Main",
            url: "https://example.test/next",
            securityOrigin: "https://example.test",
            mimeType: "text/html"
        )),
        target: target
    )
    try await waitUntil {
        context.rootNode?.id == DOMNode.ID(DOM.Node.ID(documentID))
    }
}

private func emitTransportFrameNavigated(
    frameID: String,
    loaderID: String,
    targetID: ProtocolTarget.ID,
    transport: TransportSession
) async {
    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Page.frameNavigated",
        params: #"{"frame":{"id":"\#(jsonEscapedString(frameID))","parentId":"main-frame","loaderId":"\#(jsonEscapedString(loaderID))","name":"","url":"https://example.test/","securityOrigin":"https://example.test","mimeType":"text/html"}}"#
    )
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

@MainActor
private final class ResponseBodyFetchCompletionProbe {
    private(set) var isFinished = false

    func finish() {
        isFinished = true
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
