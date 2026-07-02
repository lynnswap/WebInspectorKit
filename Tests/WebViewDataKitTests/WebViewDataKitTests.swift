import Testing
import WebViewDataKit
import WebViewProxyKit
import WebViewProxyKitTesting

@MainActor
@Test
func domEventsPopulateRootAndPreserveChildIdentity() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let documentID = DOM.Node.ID("document")
    let childID = DOM.Node.ID("child")
    let grandchildID = DOM.Node.ID("grandchild")

    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: documentID, nodeType: 9, nodeName: "#document", childNodeCount: 1)
    )

    let container = WebViewModelContainer(proxy: runtime.proxy)
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
func startupEnablesTrackedDomainsBeforeInitialDocumentSnapshot() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    await enqueueStartupReplies(on: runtime.backend)

    let container = WebViewModelContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitForStartupSubscribers(runtime: runtime, target: target)
    try await waitUntil { context.state == .attached }

    let commands = await runtime.backend.recordedCommands()
    #expect(commands.prefix(startupCommands.count) == startupCommands[...])
}

@MainActor
@Test
func networkEnableFailureFailsStartupBeforeDocumentFetch() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    await runtime.backend.enqueue((), for: "Runtime", method: "disable")

    let container = WebViewModelContainer(proxy: runtime.proxy)
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
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Network", method: "enable"),
        RecordedCommand(domain: "Runtime", method: "disable"),
    ])
    #expect(context.rootNode == nil)
}

@MainActor
@Test
func consoleEnableFailureFailsStartupBeforeAttachingDocument() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    await runtime.backend.enqueue((), for: "Network", method: "enable")
    await runtime.backend.enqueue(
        DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document"),
        for: "DOM",
        method: "getDocument"
    )
    await runtime.backend.enqueue((), for: "Runtime", method: "disable")
    await runtime.backend.enqueue((), for: "Network", method: "disable")

    let container = WebViewModelContainer(proxy: runtime.proxy)
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
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Network", method: "enable"),
        RecordedCommand(domain: "DOM", method: "getDocument"),
        RecordedCommand(domain: "Console", method: "enable"),
        RecordedCommand(domain: "Runtime", method: "disable"),
        RecordedCommand(domain: "Network", method: "disable"),
    ])
    #expect(context.rootNode == nil)
}

@MainActor
@Test
func runtimeEnableFailureFailsStartupBeforeConsoleNetworkAndDocumentFetch() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    let container = WebViewModelContainer(proxy: runtime.proxy)
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
        RecordedCommand(domain: "Runtime", method: "enable"),
    ])
    #expect(context.rootNode == nil)
}

@MainActor
@Test
func closeAfterAttachedDisablesEnabledDomains() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    await enqueueStartupReplies(on: runtime.backend)
    await enqueueDomainDisableReplies(on: runtime.backend)

    let container = WebViewModelContainer(proxy: runtime.proxy)
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
    let runtime = try await WebViewProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    await enqueueStartupReplies(on: runtime.backend)
    await runtime.backend.enqueue((), for: "Console", method: "disable")
    await runtime.backend.enqueue((), for: "Runtime", method: "disable")

    let container = WebViewModelContainer(proxy: runtime.proxy)
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
    let runtime = try await WebViewProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: DOM.Node.ID("document-1"), nodeType: 9, nodeName: "#document")
    )

    let container = WebViewModelContainer(proxy: runtime.proxy)
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
    let runtime = try await WebViewProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let enableGate = WebViewTestGate()

    await runtime.backend.hold(domain: "Network", method: "enable", gate: enableGate)
    await enqueueDomainEnableReplies(on: runtime.backend)

    let container = WebViewModelContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitForStartupSubscribers(runtime: runtime, target: target)
    try await waitUntil {
        await runtime.backend.recordedCommands() == [
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
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Network", method: "enable")
    ])

    await enableGate.open()
    try await waitUntil { context.rootNode?.id == DOMNode.ID(DOM.Node.ID("restarted-document")) }

    let commands = await runtime.backend.recordedCommands()
    #expect(commands == Array(startupCommands.prefix(2)) + [
        RecordedCommand(domain: "Runtime", method: "disable"),
        RecordedCommand(domain: "Network", method: "disable"),
    ] + startupCommands)
}

@MainActor
@Test
func runtimeEnableReplayIsCapturedBeforeCommandReturns() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let enableGate = WebViewTestGate()
    let contextID = Runtime.ExecutionContext.ID("main")

    await runtime.backend.hold(domain: "Runtime", method: "enable", gate: enableGate)
    await enqueueStartupReplies(on: runtime.backend)

    let container = WebViewModelContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitUntil {
        await runtime.backend.recordedCommands() == [
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
    let runtime = try await WebViewProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let enableGate = WebViewTestGate()

    await runtime.backend.hold(domain: "Console", method: "enable", gate: enableGate)
    await enqueueStartupReplies(on: runtime.backend)

    let container = WebViewModelContainer(proxy: runtime.proxy)
    let context = container.mainContext
    let results: WebViewFetchedResults<ConsoleMessage> = context.fetchedResults(for: .allConsoleMessages)
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
func restartClearsRuntimeContextsBeforeEnableReplay() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let staleID = Runtime.ExecutionContext.ID("stale")
    let replayID = Runtime.ExecutionContext.ID("replayed")
    let enableGate = WebViewTestGate()

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
            RecordedCommand(domain: "Runtime", method: "enable")
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
    let runtime = try await WebViewProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let results: WebViewFetchedResults<ConsoleMessage> = context.fetchedResults(for: .allConsoleMessages)
    let enableGate = WebViewTestGate()

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
    let runtime = try await WebViewProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
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
}

@MainActor
@Test
func childInsertIntoUnrequestedParentDoesNotMarkChildrenLoaded() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
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
func selectingDOMNodeLoadsCSSStylesAndComputedProperties() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
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
    #expect(styles.sections.map(\.selectorList.text) == [".card"])
    #expect(styles.computedProperties.map(\.name) == ["display"])

    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "enable")) == false)
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "getMatchedStylesForNode")))
    #expect(commands.contains(RecordedCommand(domain: "CSS", method: "getComputedStyleForNode")))
}

@MainActor
@Test
func selectingNonElementDOMNodeDoesNotRequestCSSStyles() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
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
    let runtime = try await WebViewProxyTestRuntime.start()
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

    await runtime.backend.emit(.styleSheetChanged, target: target)
    try await waitUntil { styles.phase == .needsRefresh }

    await enqueueCSSStyleReplies(on: runtime.backend)
    context.select(selected)
    try await waitUntil { styles.phase == .loaded }

    await runtime.backend.emit(.attributeModified(otherID, name: "class", value: "ignored"), target: target)
    for _ in 0..<10 {
        await Task.yield()
    }
    #expect(styles.phase == .loaded)

    await runtime.backend.emit(.attributeModified(selectedID, name: "class", value: "changed"), target: target)
    try await waitUntil { styles.phase == .needsRefresh }
}

@MainActor
@Test
func cssInvalidationDuringStyleFetchIsNotOverwrittenByStaleResult() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let document = try #require(context.rootNode)
    let elementID = DOM.Node.ID("styled-node")
    let computedGate = WebViewTestGate()

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
func removingLoadedChildPurgesDescendantsFromIdentityMap() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let documentID = DOM.Node.ID("document")
    let childID = DOM.Node.ID("child")
    let grandchildID = DOM.Node.ID("grandchild")

    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: documentID, nodeType: 9, nodeName: "#document")
    )

    let container = WebViewModelContainer(proxy: runtime.proxy)
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
func closeDuringStartupKeepsContextDetached() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
    let gate = WebViewTestGate()
    let documentID = DOM.Node.ID("document")

    await runtime.backend.hold(domain: "DOM", method: "getDocument", gate: gate)
    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: documentID, nodeType: 9, nodeName: "#document")
    )
    await enqueueDomainDisableReplies(on: runtime.backend)

    let container = WebViewModelContainer(proxy: runtime.proxy)
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
    #expect(commands == Array(startupCommands.prefix(3)) + [
        RecordedCommand(domain: "Runtime", method: "disable"),
        RecordedCommand(domain: "Network", method: "disable"),
    ])
}

@MainActor
@Test
func networkEventsPopulateAllRequestsInOrder() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
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
                status: 200,
                mimeType: "application/json",
                headers: ["Content-Type": "application/json"]
            ),
            resourceType: .fetch,
            timestamp: 2
        ),
        target: target
    )
    await runtime.backend.emit(
        .dataReceived(id: requestID, dataLength: 12, timestamp: 3),
        target: target
    )
    await runtime.backend.emit(
        .loadingFinished(id: requestID, timestamp: 4),
        target: target
    )

    let results: WebViewFetchedResults<NetworkRequest> = context.fetchedResults(for: .allRequests)
    try await waitUntil {
        results.items.count == 1 && results.items.first?.state == .finished
    }
    let request = try #require(results.items.first)
    #expect(request.url == "https://example.com/data.json")
    #expect(request.method == "GET")
    #expect(request.resourceType == .fetch)
    #expect(request.status == 200)
    #expect(request.mimeType == "application/json")
    #expect(request.requestHeaders["Accept"] == "application/json")
    #expect(request.responseHeaders["Content-Type"] == "application/json")
}

@MainActor
@Test
func repeatedRequestWillBeSentClearsStaleResponseFields() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
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
                status: 302,
                mimeType: "text/html",
                headers: ["Location": "https://example.com/final"]
            ),
            resourceType: .document,
            timestamp: 2
        ),
        target: target
    )

    let results: WebViewFetchedResults<NetworkRequest> = context.fetchedResults(for: .allRequests)
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
    #expect(request.mimeType == nil)
    #expect(request.responseHeaders.isEmpty)
    #expect(request.responseBody.phase == .available)
    #expect(request.responseBody.text == nil)
}

@MainActor
@Test
func fetchResponseBodyStoresLoadedAndFailedPhases() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let loadedID = Network.Request.ID("loaded-request")
    let failedID = Network.Request.ID("failed-request")

    await emitFinishedRequest(id: loadedID, target: target, backend: runtime.backend)
    await emitFinishedRequest(id: failedID, target: target, backend: runtime.backend)

    let results: WebViewFetchedResults<NetworkRequest> = context.fetchedResults(for: .allRequests)
    try await waitUntil { results.items.count == 2 }
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
    let runtime = try await WebViewProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("request-1")

    let results: WebViewFetchedResults<ConsoleMessage> = context.fetchedResults(for: .allConsoleMessages)
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
}

@MainActor
@Test
func runtimeEventsPopulateContextsAndFallbackSelection() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
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
    runtime: WebViewProxyTestRuntime
) async throws -> (WebViewTarget, WebViewModelContext) {
    let target = try await runtime.proxy.waitForCurrentPage()
    await enqueueStartupReplies(on: runtime.backend)

    let container = WebViewModelContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitForStartupSubscribers(runtime: runtime, target: target)
    try await waitUntil { context.state == .attached }
    return (target, context)
}

private var startupCommands: [RecordedCommand] {
    [
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
    ]
}

private func enqueueStartupReplies(
    on backend: WebViewTestBackend,
    document: DOM.Node = DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document")
) async {
    await enqueueDomainEnableReplies(on: backend)
    await backend.enqueue(document, for: "DOM", method: "getDocument")
}

private func enqueueDomainEnableReplies(on backend: WebViewTestBackend) async {
    await backend.enqueue((), for: "Runtime", method: "enable")
    await backend.enqueue((), for: "Network", method: "enable")
    await backend.enqueue((), for: "Console", method: "enable")
}

private func enqueueDomainDisableReplies(on backend: WebViewTestBackend) async {
    await backend.enqueue((), for: "Console", method: "disable")
    await backend.enqueue((), for: "Runtime", method: "disable")
    await backend.enqueue((), for: "Network", method: "disable")
}

private func enqueueCSSStyleReplies(on backend: WebViewTestBackend) async {
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
        [
            CSS.ComputedProperty(name: "display", value: "grid")
        ],
        for: "CSS",
        method: "getComputedStyleForNode"
    )
}

@MainActor
private func waitForStartupSubscribers(
    runtime: WebViewProxyTestRuntime,
    target: WebViewTarget
) async throws {
    try await runtime.backend.waitForSubscribers(domain: "DOM", target: target, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "CSS", target: target, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "Network", target: target, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "Console", target: target, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "Runtime", target: target, count: 1)
}

private func emitFinishedRequest(
    id: Network.Request.ID,
    target: WebViewTarget,
    backend: WebViewTestBackend
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
    await backend.emit(.loadingFinished(id: id, timestamp: 3), target: target)
}

@MainActor
private func waitForChild(in context: WebViewModelContext) async throws -> DOMNode {
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
private struct TimedOut: Error {}

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
