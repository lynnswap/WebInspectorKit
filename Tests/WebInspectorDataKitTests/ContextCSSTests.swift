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
    try await waitUntil(in: context) { context.rootNode?.id == DOMNode.ID(initialDocument.id) }

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
    try await waitUntil(in: context) { context.rootNode?.id == DOMNode.ID(navigatedDocument.id) }

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
    try await waitUntil(in: context) {
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
    try await waitUntil(in: context) { context.rootNode?.id == DOMNode.ID(DOM.Node.ID("document-2")) }

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
    try await waitUntil(in: context) {
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
    _ = try await runtime.backend.waitForRecordedCommandsForTesting(domain: "CSS", method: "getComputedStyleForNode", count: 1)

    await runtime.backend.emit(.styleSheetChanged(CSS.StyleSheet.ID("sheet-1")), target: target)
    try await waitUntil { styles.phase == .needsRefresh }

    await computedGate.open()
    _ = await runtime.backend.waitForCompletedCommands(domain: "CSS", method: "getComputedStyleForNode", count: 1)
    #expect(styles.phase == .needsRefresh)
    #expect(styles.computedProperties.isEmpty)
}

@MainActor
@Test
func cssInspectorBaselineIsSharedAcrossNodesAndSurvivesStaleLoads() throws {
    let context = WebInspectorContext.preview()
    let firstStyles = CSSStyles(
        nodeID: DOMNode.ID(DOM.Node.ID("shared-baseline-first")),
        modelContext: context
    )
    let secondStyles = CSSStyles(
        nodeID: DOMNode.ID(DOM.Node.ID("shared-baseline-second")),
        modelContext: context
    )
    let initialStyle = cssBaselineStyle(
        id: CSS.Style.ID("shared-baseline-style"),
        properties: [("color", "red")]
    )
    for styles in [firstStyles, secondStyles] {
        styles.load(
            matchedStyles: cssMatchedStyles([initialStyle]),
            inlineStyles: .init(),
            computedProperties: []
        )
    }

    let firstColor = try #require(firstStyles.sections.first?.style.properties.first)
    let editedStyle = cssBaselineStyle(
        id: initialStyle.id,
        properties: [("color", "blue")]
    )
    firstStyles.applySetStyleText(result: editedStyle, for: firstColor.id)

    secondStyles.load(
        matchedStyles: cssMatchedStyles([editedStyle]),
        inlineStyles: .init(),
        computedProperties: []
    )
    #expect(secondStyles.sections.first?.style.properties.first?.isModifiedByInspector == true)

    // A delayed response for another matching node is observational only. It
    // cannot prove that the shared declaration was restored.
    secondStyles.load(
        matchedStyles: cssMatchedStyles([initialStyle]),
        inlineStyles: .init(),
        computedProperties: []
    )
    firstStyles.load(
        matchedStyles: cssMatchedStyles([editedStyle]),
        inlineStyles: .init(),
        computedProperties: []
    )
    #expect(firstStyles.sections.first?.style.properties.first?.isModifiedByInspector == true)
}

@MainActor
@Test
func cssInspectorBaselineRekeysOnlyToUniqueSemanticDeclarationAfterInsertion() throws {
    let context = WebInspectorContext.preview()
    let styles = CSSStyles(
        nodeID: DOMNode.ID(DOM.Node.ID("topology-baseline-node")),
        modelContext: context
    )
    let initialStyle = cssBaselineStyle(
        id: CSS.Style.ID("topology-baseline-style"),
        properties: [("inset", "0"), ("height", "100%")]
    )
    styles.load(
        matchedStyles: cssMatchedStyles([initialStyle]),
        inlineStyles: .init(),
        computedProperties: []
    )

    let initialProperties = try #require(styles.sections.first?.style.properties)
    let inset = try #require(initialProperties.first { $0.name == "inset" })
    let height = try #require(initialProperties.first { $0.name == "height" })
    let editedHeight = cssBaselineStyle(
        id: initialStyle.id,
        properties: [("inset", "0"), ("height", "50%")]
    )
    styles.applySetStyleText(result: editedHeight, for: height.id)

    let expandedStyle = cssBaselineStyle(
        id: initialStyle.id,
        properties: [
            ("inset", "1px"),
            ("top", "1px"),
            ("right", "1px"),
            ("bottom", "1px"),
            ("left", "1px"),
            ("height", "50%"),
        ]
    )
    styles.applySetStyleText(result: expandedStyle, for: inset.id)

    let expandedProperties = try #require(styles.sections.first?.style.properties)
    #expect(expandedProperties.first { $0.name == "top" }?.isModifiedByInspector == false)
    #expect(expandedProperties.first { $0.name == "height" }?.isModifiedByInspector == true)
}

@MainActor
@Test
func cssInspectorBaselineDoesNotRekeyAmbiguousDuplicateDeclarations() throws {
    let context = WebInspectorContext.preview()
    let styles = CSSStyles(
        nodeID: DOMNode.ID(DOM.Node.ID("duplicate-baseline-node")),
        modelContext: context
    )
    let initialStyle = cssBaselineStyle(
        id: CSS.Style.ID("duplicate-baseline-style"),
        properties: [("color", "red"), ("color", "green")]
    )
    styles.load(
        matchedStyles: cssMatchedStyles([initialStyle]),
        inlineStyles: .init(),
        computedProperties: []
    )

    let secondColor = try #require(styles.sections.first?.style.properties.last)
    let editedStyle = cssBaselineStyle(
        id: initialStyle.id,
        properties: [("margin", "0"), ("color", "red"), ("color", "blue")]
    )
    styles.applySetStyleText(result: editedStyle, for: secondColor.id)

    let colors = try #require(styles.sections.first?.style.properties.filter { $0.name == "color" })
    #expect(colors.count == 2)
    #expect(colors.allSatisfy { $0.isModifiedByInspector == false })
}

@MainActor
@Test
func cssInspectorBaselineDoesNotCrossDocumentOrTargetLifetime() throws {
    let context = WebInspectorContext.preview()
    let pageStyles = CSSStyles(
        nodeID: DOMNode.ID(DOM.Node.ID("page-baseline-node")),
        modelContext: context
    )
    let pageInitial = cssBaselineStyle(
        id: CSS.Style.ID("page-baseline-style"),
        properties: [("color", "red")]
    )
    pageStyles.load(
        matchedStyles: cssMatchedStyles([pageInitial]),
        inlineStyles: .init(),
        computedProperties: []
    )
    let pageColor = try #require(pageStyles.sections.first?.style.properties.first)
    let pageEdited = cssBaselineStyle(
        id: pageInitial.id,
        properties: [("color", "blue")]
    )
    pageStyles.applySetStyleText(result: pageEdited, for: pageColor.id)

    context.apply(DOM.Event.documentUpdated)
    pageStyles.load(
        matchedStyles: cssMatchedStyles([pageEdited]),
        inlineStyles: .init(),
        computedProperties: []
    )
    #expect(pageStyles.sections.first?.style.properties.first?.isModifiedByInspector == false)

    let frameTargetID = WebInspectorTarget.ID("baseline-frame")
    let frameStyles = CSSStyles(
        nodeID: DOMNode.ID(DOM.Node.ID("frame-baseline-node")),
        modelContext: context
    )
    let frameInitial = cssBaselineStyle(
        id: CSS.Style.ID("frame-baseline-style", scopedToTargetRawValue: frameTargetID.rawValue),
        properties: [("display", "block")]
    )
    frameStyles.load(
        matchedStyles: cssMatchedStyles([frameInitial]),
        inlineStyles: .init(),
        computedProperties: []
    )
    let frameDisplay = try #require(frameStyles.sections.first?.style.properties.first)
    let frameEdited = cssBaselineStyle(
        id: frameInitial.id,
        properties: [("display", "none")]
    )
    frameStyles.applySetStyleText(result: frameEdited, for: frameDisplay.id)

    context.apply(.targetDestroyed(targetID: frameTargetID))
    frameStyles.load(
        matchedStyles: cssMatchedStyles([frameEdited]),
        inlineStyles: .init(),
        computedProperties: []
    )
    #expect(frameStyles.sections.first?.style.properties.first?.isModifiedByInspector == false)
}

@MainActor
@Test
func changingSelectionCancelsCSSLoadWithoutLeavingPriorResourceLoading() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let firstID = DOM.Node.ID("cancelled-style-first")
    let secondID = DOM.Node.ID("cancelled-style-second")
    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: firstID, nodeType: 1, nodeName: "DIV", localName: "div"),
            DOM.Node(id: secondID, nodeType: 1, nodeName: "DIV", localName: "div"),
        ]),
        target: target
    )
    try await waitUntil(in: context) {
        context.node(for: DOMNode.ID(firstID)) != nil
            && context.node(for: DOMNode.ID(secondID)) != nil
    }
    let first = try #require(context.node(for: DOMNode.ID(firstID)))
    let second = try #require(context.node(for: DOMNode.ID(secondID)))
    let matchedGate = WebInspectorTestGate()
    await runtime.backend.hold(
        domain: "CSS",
        method: "getMatchedStylesForNode",
        gate: matchedGate
    )
    await enqueueCSSStyleReplies(on: runtime.backend)
    await enqueueCSSStyleReplies(on: runtime.backend)

    context.select(first)
    let firstStyles = try #require(first.elementStyles)
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "CSS",
        method: "getMatchedStylesForNode",
        count: 1
    )

    context.select(second)
    let secondStyles = try #require(second.elementStyles)
    await matchedGate.open()

    try await waitUntil { secondStyles.phase == .loaded }
    #expect(firstStyles.phase == .unavailable)
}

@MainActor
@Test
func cancellingCSSMutationDoesNotWaitForBlockedStyleRefresh() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let elementID = DOM.Node.ID("cancelled-style-mutation")
    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )
    let element = try await waitForChild(in: context)
    await enqueueCSSStyleReplies(
        cssToggleStyle(margin: "0", paddingStatus: .active),
        on: runtime.backend
    )
    context.select(element)
    let styles = try #require(element.elementStyles)
    try await waitUntil { styles.phase == .loaded }
    let paddingID = try #require(
        styles.sections.first?.style.properties.first { $0.name == "padding" }?.id
    )

    let matchedGate = WebInspectorTestGate()
    await runtime.backend.hold(
        domain: "CSS",
        method: "getMatchedStylesForNode",
        gate: matchedGate
    )
    await enqueueCSSStyleReplies(
        cssToggleStyle(margin: "0", paddingStatus: .active),
        on: runtime.backend
    )
    try context.css.refreshStyles(for: element.id)
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "CSS",
        method: "getMatchedStylesForNode",
        count: 2
    )

    let mutationCompletion = ResponseBodyFetchCompletionProbe()
    let mutationTask = Task { @MainActor in
        defer {
            mutationCompletion.finish()
        }
        try await context.css.setProperty(
            paddingID,
            enabled: false,
            options: WebInspectorMutationOptions(undo: .disabled)
        )
    }
    try await context.waitForQueuedCSSOperationCountForTesting(1, for: target)
    mutationTask.cancel()
    try await waitUntil { mutationCompletion.isFinished }
    await #expect(throws: CancellationError.self) {
        try await mutationTask.value
    }

    await matchedGate.open()
}

@MainActor
@Test
func cssToggleQueuedBehindRefreshUsesRefreshedStyleText() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let elementID = DOM.Node.ID("queued-style-mutation")
    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )
    let element = try await waitForChild(in: context)
    let initialStyle = cssToggleStyle(margin: "0", paddingStatus: .active)
    await enqueueCSSStyleReplies(initialStyle, on: runtime.backend)
    context.select(element)
    let styles = try #require(element.elementStyles)
    try await waitUntil { styles.phase == .loaded }
    let paddingID = try #require(
        styles.sections.first?.style.properties.first { $0.name == "padding" }?.id
    )

    let refreshedStyle = cssToggleStyle(margin: "4px", paddingStatus: .active)
    let matchedGate = WebInspectorTestGate()
    await runtime.backend.hold(
        domain: "CSS",
        method: "getMatchedStylesForNode",
        gate: matchedGate
    )
    await enqueueCSSStyleReplies(refreshedStyle, on: runtime.backend)
    let disabledStyle = cssToggleStyle(margin: "4px", paddingStatus: .disabled)
    await runtime.backend.enqueue(disabledStyle, for: "CSS", method: "setStyleText")

    try context.css.refreshStyles(for: element.id)
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "CSS",
        method: "getMatchedStylesForNode",
        count: 2
    )

    let accepted = context.css.requestSetProperty(
        paddingID,
        enabled: false,
        options: WebInspectorMutationOptions(undo: .disabled)
    )
    #expect(accepted)
    guard accepted else {
        await matchedGate.open()
        return
    }

    await matchedGate.open()
    let setStyleCommands = await runtime.backend.waitForRecordedCommands(
        domain: "CSS",
        method: "setStyleText",
        count: 1
    )
    let payload = try #require(setStyleCommands.last?.payload.cast(as: CSS.SetStyleTextPayload.self))
    #expect(payload.text == "margin: 4px;\n/* padding: 8px; */")
    _ = await runtime.backend.waitForCompletedCommands(
        domain: "CSS",
        method: "setStyleText",
        count: 1
    )
}

@MainActor
@Test
func concurrentCSSMutationsSerializeAndRefreshBeforeRewriting() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let elementID = DOM.Node.ID("serialized-style-mutation")
    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )
    let element = try await waitForChild(in: context)
    let initialStyle = cssToggleStyle(margin: "0", paddingStatus: .active)
    await enqueueCSSStyleReplies(initialStyle, on: runtime.backend)
    context.select(element)
    let styles = try #require(element.elementStyles)
    try await waitUntil { styles.phase == .loaded }
    let marginID = try #require(
        styles.sections.first?.style.properties.first { $0.name == "margin" }?.id
    )
    let paddingID = try #require(
        styles.sections.first?.style.properties.first { $0.name == "padding" }?.id
    )

    let firstMutationGate = WebInspectorTestGate()
    await runtime.backend.hold(domain: "CSS", method: "setStyleText", gate: firstMutationGate)
    let marginDisabled = cssToggleStyle(
        margin: "0",
        marginStatus: .disabled,
        paddingStatus: .active
    )
    let bothDisabled = cssToggleStyle(
        margin: "0",
        marginStatus: .disabled,
        paddingStatus: .disabled
    )
    await runtime.backend.enqueue(marginDisabled, for: "CSS", method: "setStyleText")
    await enqueueCSSStyleReplies(marginDisabled, on: runtime.backend)
    await runtime.backend.enqueue(bothDisabled, for: "CSS", method: "setStyleText")

    let firstMutation = Task { @MainActor in
        try await context.css.setProperty(
            marginID,
            enabled: false,
            options: WebInspectorMutationOptions(undo: .disabled)
        )
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "CSS",
        method: "setStyleText",
        count: 1
    )
    let secondMutation = Task { @MainActor in
        try await context.css.setProperty(
            paddingID,
            enabled: false,
            options: WebInspectorMutationOptions(undo: .disabled)
        )
    }
    try await context.waitForQueuedCSSOperationCountForTesting(1, for: target)
    #expect(await runtime.backend.recordedCommands().filter {
        $0.domain == "CSS" && $0.method == "setStyleText"
    }.count == 1)

    await firstMutationGate.open()
    try await firstMutation.value
    try await secondMutation.value

    let setStyleCommands = await runtime.backend.recordedCommands().filter {
        $0.domain == "CSS" && $0.method == "setStyleText"
    }
    #expect(setStyleCommands.count == 2)
    let secondPayload = try #require(
        setStyleCommands.last?.payload.cast(as: CSS.SetStyleTextPayload.self)
    )
    #expect(secondPayload.text == "/* margin: 0; */\n/* padding: 8px; */")
}

@MainActor
@Test
func cssMutationRejectsReusedPositionalPropertyIDAfterTopologyChange() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let elementID = DOM.Node.ID("shifted-style-mutation")
    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )
    let element = try await waitForChild(in: context)
    await enqueueCSSStyleReplies(
        cssToggleStyle(margin: "0", paddingStatus: .active),
        on: runtime.backend
    )
    context.select(element)
    let styles = try #require(element.elementStyles)
    try await waitUntil { styles.phase == .loaded }
    let paddingID = try #require(
        styles.sections.first?.style.properties.first { $0.name == "padding" }?.id
    )

    await runtime.backend.emit(.styleSheetChanged(CSS.StyleSheet.ID("queued-toggle-style")), target: target)
    try await waitUntil { styles.phase == .needsRefresh }
    let shiftedStyle = cssToggleStyleWithLeadingColor()
    await enqueueCSSStyleReplies(shiftedStyle, on: runtime.backend)
    await runtime.backend.enqueue(shiftedStyle, for: "CSS", method: "setStyleText")

    await #expect(throws: WebInspectorProxyError.commandFailed(
        domain: "CSS",
        method: "setStyleText",
        message: "CSS declaration changed before the queued mutation could run."
    )) {
        try await context.css.setProperty(
            paddingID,
            enabled: false,
            options: WebInspectorMutationOptions(undo: .disabled)
        )
    }
    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "setStyleText")) == false)
}

@MainActor
@Test
func cssMutationRejectsReusedStyleIDAfterRuleInsertion() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let elementID = DOM.Node.ID("shifted-rule-mutation")
    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )
    let element = try await waitForChild(in: context)
    let submittedStyle = cssSinglePropertyStyle(
        id: CSS.Style.ID("rule-sheet\u{1F}0"),
        name: "color",
        value: "red"
    )
    await enqueueCSSStyleReplies(
        CSS.MatchedStyles(matchedRules: [cssRule(selector: ".original", style: submittedStyle)]),
        on: runtime.backend
    )
    context.select(element)
    let styles = try #require(element.elementStyles)
    try await waitUntil { styles.phase == .loaded }
    let colorID = try #require(styles.sections.first?.style.properties.first?.id)

    await runtime.backend.emit(.styleSheetChanged(CSS.StyleSheet.ID("rule-sheet")), target: target)
    try await waitUntil { styles.phase == .needsRefresh }
    let insertedStyle = cssSinglePropertyStyle(
        id: CSS.Style.ID("rule-sheet\u{1F}0"),
        name: "color",
        value: "red"
    )
    let shiftedOriginalStyle = cssSinglePropertyStyle(
        id: CSS.Style.ID("rule-sheet\u{1F}1"),
        name: "color",
        value: "red"
    )
    await enqueueCSSStyleReplies(
        CSS.MatchedStyles(matchedRules: [
            cssRule(selector: ".inserted", style: insertedStyle),
            cssRule(selector: ".original", style: shiftedOriginalStyle),
        ]),
        on: runtime.backend
    )
    await runtime.backend.enqueue(insertedStyle, for: "CSS", method: "setStyleText")

    await #expect(throws: WebInspectorProxyError.commandFailed(
        domain: "CSS",
        method: "setStyleText",
        message: "CSS declaration changed before the queued mutation could run."
    )) {
        try await context.css.setProperty(
            colorID,
            enabled: false,
            options: WebInspectorMutationOptions(undo: .disabled)
        )
    }
    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "setStyleText")) == false)
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

    _ = try await runtime.backend.waitForRecordedCommandsForTesting(domain: "CSS", method: "getMatchedStylesForNode", count: 2)
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

    _ = try await runtime.backend.waitForRecordedCommandsForTesting(domain: "CSS", method: "getMatchedStylesForNode", count: 2)
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
                isEditable: true
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
func requestSetCSSPropertyRefusesNonEditableAndRefreshesStaleProperties() async throws {
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
    await enqueueCSSStyleReplies(on: runtime.backend)
    await runtime.backend.enqueue(
        CSS.Style(
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
        ),
        for: "CSS",
        method: "setStyleText"
    )
    #expect(context.css.requestSetProperty(
        editablePropertyID,
        enabled: false,
        options: WebInspectorMutationOptions(undo: .disabled)
    ))
    _ = await runtime.backend.waitForCompletedCommands(
        domain: "CSS",
        method: "setStyleText",
        count: 1
    )

    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "setStyleText")))
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
    try await waitUntil(in: context) { context.rootNode?.id == DOMNode.ID(replacementDocumentID) }
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
    let ruleProxyID = CSS.Rule.ID(
        "reused-sheet\u{1F}1",
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

    let priorMutationGate = WebInspectorTestGate()
    await runtime.backend.hold(domain: "CSS", method: "setStyleSheetText", gate: priorMutationGate)
    await runtime.backend.enqueue((), for: "CSS", method: "setStyleSheetText")
    await runtime.backend.enqueue((), for: "CSS", method: "setStyleSheetText")
    await runtime.backend.enqueue(
        CSS.Rule(
            id: ruleProxyID,
            selectorList: CSS.Rule.SelectorList(selectors: [".updated"], text: ".updated"),
            origin: CSS.Origin(rawValue: "regular"),
            style: CSS.Style(id: CSS.Style.ID(
                "reused-sheet\u{1F}1",
                scopedToTargetRawValue: frameTargetID.rawValue
            ))
        ),
        for: "CSS",
        method: "setRuleSelector"
    )
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    let priorMutationTask = Task { @MainActor in
        try await context.css.setStyleSheetText("body { color: red; }", for: styleSheetID)
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "CSS",
        method: "setStyleSheetText",
        count: 1
    )

    let queuedStyleSheetTask = Task { @MainActor in
        try await context.css.setStyleSheetText(
            "body { color: orange; }",
            for: styleSheetID,
            options: WebInspectorMutationOptions(undo: .disabled)
        )
    }
    let frameTarget = runtime.proxy.frameTarget(id: frameTargetID)
    try await context.waitForQueuedCSSOperationCountForTesting(1, for: frameTarget)
    let queuedRuleTask = Task { @MainActor in
        try await context.css.setRuleSelector(
            ".updated",
            for: ruleID,
            options: WebInspectorMutationOptions(undo: .disabled)
        )
    }
    try await context.waitForQueuedCSSOperationCountForTesting(2, for: frameTarget)

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
    await #expect(throws: WebInspectorProxyError.disconnected("CSS mutation no longer belongs to the current document.")) {
        try await queuedStyleSheetTask.value
    }
    await #expect(throws: WebInspectorProxyError.disconnected("CSS mutation no longer belongs to the current document.")) {
        try await queuedRuleTask.value
    }
    var commands = await runtime.backend.recordedCommands()
    #expect(commands.filter {
        $0.domain == "CSS" && $0.method == "setStyleSheetText"
    }.count == 1)
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "setRuleSelector")) == false)
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
func queuedRuleSelectorRejectsPositionalIDAfterStyleSheetReplacement() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let styleSheetID = CSS.StyleSheet.ID("queued-rule-sheet")
    let ruleProxyID = CSS.Rule.ID("queued-rule-sheet\u{1F}0")
    let ruleID = CSSStyleRule.ID(ruleProxyID)
    let mutationGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "CSS", method: "setStyleSheetText", gate: mutationGate)
    await runtime.backend.enqueue((), for: "CSS", method: "setStyleSheetText")
    await runtime.backend.enqueue(
        CSS.Rule(
            id: ruleProxyID,
            selectorList: CSS.Rule.SelectorList(selectors: [".updated"], text: ".updated"),
            origin: CSS.Origin(rawValue: "author"),
            style: CSS.Style(id: CSS.Style.ID("queued-rule-sheet\u{1F}0"))
        ),
        for: "CSS",
        method: "setRuleSelector"
    )
    let styleSheetTask = Task { @MainActor in
        try await context.css.setStyleSheetText(
            ".inserted {} .original {}",
            for: styleSheetID,
            options: WebInspectorMutationOptions(undo: .disabled)
        )
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "CSS",
        method: "setStyleSheetText",
        count: 1
    )

    let selectorTask = Task { @MainActor in
        try await context.css.setRuleSelector(
            ".updated",
            for: ruleID,
            options: WebInspectorMutationOptions(undo: .disabled)
        )
    }
    try await context.waitForQueuedCSSOperationCountForTesting(1, for: target)
    await mutationGate.open()

    try await styleSheetTask.value
    await #expect(throws: WebInspectorProxyError.disconnected(
        "CSS mutation no longer belongs to the current document."
    )) {
        try await selectorTask.value
    }
    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "setRuleSelector")) == false)
}

@MainActor
@Test
func ruleSelectorAcceptsItsOwnStyleSheetChangedEventBeforeReply() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let styleSheetID = CSS.StyleSheet.ID("selector-own-event-sheet")
    let ruleProxyID = CSS.Rule.ID("selector-own-event-sheet\u{1F}0")
    let ruleID = CSSStyleRule.ID(ruleProxyID)
    let mutationGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "CSS", method: "setRuleSelector", gate: mutationGate)
    await runtime.backend.enqueue(
        CSS.Rule(
            id: ruleProxyID,
            selectorList: CSS.Rule.SelectorList(selectors: [".updated"], text: ".updated"),
            origin: CSS.Origin(rawValue: "author"),
            style: CSS.Style(id: CSS.Style.ID("selector-own-event-sheet\u{1F}0"))
        ),
        for: "CSS",
        method: "setRuleSelector"
    )
    await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
    let selectorTask = Task { @MainActor in
        try await context.css.setRuleSelector(".updated", for: ruleID)
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "CSS",
        method: "setRuleSelector",
        count: 1
    )
    let eventBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(.styleSheetChanged(styleSheetID), target: target)
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: eventBaseline))
    await mutationGate.open()

    try await selectorTask.value
    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "DOM", method: "markUndoableState")))
}

@MainActor
@Test
func queuedDeclarationRefreshesAfterStyleSheetReplacement() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let elementID = DOM.Node.ID("queued-after-sheet-replacement")
    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )
    let element = try await waitForChild(in: context)
    await enqueueCSSStyleReplies(
        cssToggleStyle(margin: "0", paddingStatus: .active),
        on: runtime.backend
    )
    context.select(element)
    let styles = try #require(element.elementStyles)
    try await waitUntil { styles.phase == .loaded }
    let paddingID = try #require(
        styles.sections.first?.style.properties.first { $0.name == "padding" }?.id
    )

    let mutationGate = WebInspectorTestGate()
    await runtime.backend.hold(domain: "CSS", method: "setStyleSheetText", gate: mutationGate)
    await runtime.backend.enqueue((), for: "CSS", method: "setStyleSheetText")
    let styleSheetTask = Task { @MainActor in
        try await context.css.setStyleSheetText(
            "color: red; margin: 0; padding: 8px;",
            for: CSS.StyleSheet.ID("queued-toggle-style"),
            options: WebInspectorMutationOptions(undo: .disabled)
        )
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "CSS",
        method: "setStyleSheetText",
        count: 1
    )

    await enqueueCSSStyleReplies(cssToggleStyleWithLeadingColor(), on: runtime.backend)
    await runtime.backend.enqueue(
        cssToggleStyleWithLeadingColor(),
        for: "CSS",
        method: "setStyleText"
    )
    let declarationTask = Task { @MainActor in
        try await context.css.setProperty(
            paddingID,
            enabled: false,
            options: WebInspectorMutationOptions(undo: .disabled)
        )
    }
    try await context.waitForQueuedCSSOperationCountForTesting(1, for: target)
    await mutationGate.open()

    try await styleSheetTask.value
    await #expect(throws: WebInspectorProxyError.commandFailed(
        domain: "CSS",
        method: "setStyleText",
        message: "CSS declaration changed before the queued mutation could run."
    )) {
        try await declarationTask.value
    }
    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "setStyleText")) == false)
}
