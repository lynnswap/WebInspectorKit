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
func transportBackedStartupContinuesAfterResourceTreeFailureWithoutTimeouts() async throws {
    let (_, _, context) = try await startTransportBackedContext(
        targetID: ProtocolTarget.ID("page-resource-tree-unavailable"),
        documentID: "resource-tree-unavailable-root"
    )

    #expect(context.state == .attached)
    #expect(context.rootNode?.id == DOMNode.ID(DOM.Node.ID("resource-tree-unavailable-root")))
    #expect(context.networkResourceTreeError == .commandFailed(
        domain: "Page",
        method: "Page.getResourceTree",
        message: "Resource tree unavailable in this fixture."
    ))
}

@MainActor
@Test
func malformedKnownOrderedEventFailsAttachedContext() async throws {
    let targetID = ProtocolTarget.ID("page-decode-failure")
    let (backend, transport, context) = try await startTransportBackedContext(
        targetID: targetID,
        documentID: "decode-failure-root"
    )
    let proxy = context.inspectionProxyForTesting
    let target = try #require(context.currentPageForTesting)
    let failedStatusTask = Task<WebInspectorContext.Status?, Never> { @MainActor in
        for await status in context.statusUpdates {
            if case .failed = status.state {
                return status
            }
        }
        return nil
    }
    let proxyCloseTask = Task {
        await terminalProxyError(from: proxy)
    }
    let retargetBoundary = context.eventPumpAppliedSequenceForTesting
    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"page-decode-failure"}}"#
    )
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: retargetBoundary))
    let retargetTask = try #require(context.currentPageRetargetTaskForTesting())
    let subscriptionBeforeFailure = context.orderedEventSubscriptionStateForTesting
    let appliedBeforeFailure = context.eventPumpAppliedSequenceForTesting
    let boundaryRegistration = ReplyPromise<Void>()
    let boundaryWaiter = Task { @MainActor in
        await context.waitForOrderedEventsForTesting(
            through: subscriptionBeforeFailure.sequence + 1,
            registration: boundaryRegistration
        )
    }
    try await boundaryRegistration.value()

    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Network.loadingFinished",
        params: "{}"
    )

    let failedStatus = try #require(await failedStatusTask.value)
    let proxyError = try #require(await proxyCloseTask.value)
    guard case let .failed(error) = failedStatus.state,
          case let .disconnected(message) = error else {
        Issue.record("Expected the context to fail with a disconnected error.")
        return
    }
    #expect(message.contains("Network.loadingFinished"))
    #expect(proxyError == error)
    #expect(await boundaryWaiter.value == false)
    await retargetTask.value
    #expect(context.currentPageRetargetTaskForTesting() == nil)
    #expect(context.currentPageForTesting?.id == target.id)
    #expect(context.rootNode?.id == DOMNode.ID(DOM.Node.ID("decode-failure-root")))
    let subscriptionAfterFailure = context.orderedEventSubscriptionStateForTesting
    #expect(subscriptionAfterFailure.generation == subscriptionBeforeFailure.generation + 1)
    #expect(subscriptionAfterFailure.sequence == subscriptionBeforeFailure.sequence)
    #expect(context.eventPumpAppliedSequenceForTesting == appliedBeforeFailure)
    await context.applyOrderedEventForTesting(
        WebInspectorProxyOrderedEvent(
            sequence: subscriptionBeforeFailure.sequence + 1,
            event: .network(.dataReceived(
                id: Network.Request.ID("stale-after-failure"),
                dataLength: 1,
                encodedDataLength: 1,
                timestamp: 4
            ))
        ),
        target: target,
        subscriptionGeneration: subscriptionBeforeFailure.generation
    )
    #expect(context.eventPumpAppliedSequenceForTesting == appliedBeforeFailure)
    #expect(context.orderedEventSubscriptionStateForTesting == subscriptionAfterFailure)
    context.handleOrderedEventStreamFailureForTesting(
        WebInspectorProxyError.disconnected("stale failure callback"),
        subscriptionGeneration: subscriptionBeforeFailure.generation
    )
    #expect(context.eventPumpAppliedSequenceForTesting == appliedBeforeFailure)
    #expect(context.orderedEventSubscriptionStateForTesting == subscriptionAfterFailure)
    #expect(context.state == failedStatus.state)
    #expect(await backend.isDetached())
}

@MainActor
@Test
func malformedKnownOrderedEventFailsAttachingContextWithoutHanging() async throws {
    let targetID = ProtocolTarget.ID("page-startup-decode-failure")
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: nil)
    await installTransportPageTarget(in: transport, targetID: targetID)
    let proxy = try await WebInspectorProxy(transport: transport)
    let container = WebInspectorContainer(proxy: proxy)
    let context = container.mainContext
    let failedStatusTask = Task<WebInspectorContext.Status?, Never> { @MainActor in
        for await status in context.statusUpdates {
            if case .failed = status.state {
                return status
            }
        }
        return nil
    }
    let proxyCloseTask = Task {
        await terminalProxyError(from: proxy)
    }

    _ = try await waitForTransportTargetMessage(backend, method: "Inspector.enable")
    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Network.loadingFinished",
        params: "{}"
    )

    let failedStatus = try #require(await failedStatusTask.value)
    let proxyError = try #require(await proxyCloseTask.value)
    guard case let .failed(error) = failedStatus.state,
          case let .disconnected(message) = error else {
        Issue.record("Expected startup to fail with a disconnected error.")
        return
    }
    #expect(message.contains("Network.loadingFinished"))
    #expect(proxyError == error)
    #expect(await backend.isDetached())
}

@MainActor
@Test
func currentPageCommitBeforePageEnableAcquiresCommittedPageLease() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let pageEnableGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "Page", method: "enable", gate: pageEnableGate)
    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: DOM.Node.ID("committed-root"), nodeType: 9, nodeName: "#document")
    )
    await runtime.backend.enqueue((), for: "Inspector", method: "enable")
    await runtime.backend.enqueue((), for: "Inspector", method: "initialized")

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitForStartupSubscribers(runtime: runtime, target: target)
    _ = await runtime.backend.waitForRecordedCommands(domain: "Page", method: "enable", count: 1)

    await runtime.backend.emit(
        .didCommitProvisionalTarget(WebInspectorTargetCommitLifecycle(
            oldTargetID: .currentPage,
            newTarget: WebInspectorLifecycleTarget(
                id: .currentPage,
                kind: .page,
                frameID: FrameID("main-frame"),
                isProvisional: false,
                pageBindingID: "committed-agent"
            )
        )),
        target: target
    )
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "Inspector",
        method: "initialized",
        count: 2
    )
    await pageEnableGate.open()

    try await waitUntil(in: context) {
        context.state == .attached
            && context.rootNode?.id == DOMNode.ID(DOM.Node.ID("committed-root"))
    }
    let commands = await runtime.backend.recordedCommands()
    #expect(commands.filter { $0 == RecordedCommand(domain: "Page", method: "enable") }.count == 1)
}

@MainActor
@Test
func unresolvedInspectorInspectDoesNotBlockOrderedModelEvents() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let gate = WebInspectorTestGate()
    let executionContextID = Runtime.ExecutionContext.ID("after-unresolved-inspect")

    await runtime.backend.hold(domain: "DOM", method: "requestNode", gate: gate)
    await runtime.backend.enqueue(DOM.Node.ID("inspected-node"), for: "DOM", method: "requestNode")
    await runtime.backend.emit(
        .inspect(
            Runtime.RemoteObject(
                id: Runtime.RemoteObject.ID("unresolved-node-object"),
                kind: .object,
                subtype: Runtime.Subtype(rawValue: "node")
            ),
            hints: .object([:])
        ),
        target: target
    )
    _ = await runtime.backend.waitForRecordedCommands(domain: "DOM", method: "requestNode", count: 1)

    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(
            id: executionContextID,
            name: "After inspect",
            kind: .normal
        )),
        target: target
    )
    try await waitUntil(in: context) {
        context.executionContexts.map(\.id) == [RuntimeContext.ID(executionContextID)]
    }
    await gate.open()
}

@MainActor
@Test
func supersededOrderedPumpCallbackIsIgnoredBeforeSequenceValidation() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let supersededState = context.orderedEventSubscriptionStateForTesting

    await enqueueDomainDisableReplies(on: runtime.backend)
    await context.stop()
    #expect(context.orderedEventSubscriptionStateForTesting.generation != supersededState.generation)

    await context.applyOrderedEventForTesting(
        WebInspectorProxyOrderedEvent(sequence: supersededState.sequence, event: nil),
        target: target,
        subscriptionGeneration: supersededState.generation
    )
    #expect(context.state == .detached)
}

@MainActor
@Test
func supersededOrderedPumpCannotAdvanceWatermarkAfterReentrantApply() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let originalState = context.orderedEventSubscriptionStateForTesting
    let gate = WebInspectorTestGate()
    let suspensionProbe = CancellationProbe()
    let applyTask = Task {
        await context.applyOrderedEventForTesting(
            WebInspectorProxyOrderedEvent(sequence: originalState.sequence + 1, event: nil),
            target: target,
            subscriptionGeneration: originalState.generation,
            beforeWatermarkUpdate: {
                suspensionProbe.markStarted()
                await gate.wait()
            }
        )
    }
    try await suspensionProbe.waitUntilStarted()

    await enqueueDomainDisableReplies(on: runtime.backend)
    await context.stop()
    await gate.open()
    await applyTask.value

    #expect(context.orderedEventSubscriptionStateForTesting.sequence == originalState.sequence)
    #expect(context.state == .detached)
}

@MainActor
@Test
func supersededOrderedFeedSubscriptionReleasesItsProducer() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let gate = WebInspectorTestGate()
    let suspensionProbe = CancellationProbe()
    let subscribeTask = Task {
        await context.subscribeForTesting(
            to: target,
            beforeValidation: {
                suspensionProbe.markStarted()
                await gate.wait()
            }
        )
    }
    try await suspensionProbe.waitUntilStarted()

    await enqueueDomainDisableReplies(on: runtime.backend)
    await context.stop()
    await gate.open()
    await subscribeTask.value

    try await runtime.backend.waitForNoOrderedEventSubscribers(for: target)
    #expect(context.state == .detached)
}

@MainActor
@Test
func currentPageCommitOnSameProtocolAgentRetainsRequiredDomainLeases() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)

    await runtime.backend.enqueue(
        DOM.Node(id: DOM.Node.ID("same-agent-root"), nodeType: 9, nodeName: "#document"),
        for: "DOM",
        method: "getDocument"
    )
    await runtime.backend.emit(
        .didCommitProvisionalTarget(WebInspectorTargetCommitLifecycle(
            oldTargetID: .currentPage,
            newTarget: WebInspectorLifecycleTarget(
                id: .currentPage,
                kind: .page,
                frameID: FrameID("main-frame"),
                isProvisional: false,
                pageBindingID: nil
            )
        )),
        target: target
    )

    try await waitUntil(in: context) {
        context.rootNode?.id == DOMNode.ID(DOM.Node.ID("same-agent-root"))
    }
    await emitOriginatedNetworkRequest(
        id: "same-agent-network",
        loaderID: "same-agent-loader",
        originTargetID: nil,
        timestamp: 1,
        target: target,
        backend: runtime.backend
    )
    try await waitUntil {
        context.network.requests.map(\.id) == [NetworkRequest.ID(Network.Request.ID("same-agent-network"))]
    }

    let commands = await runtime.backend.recordedCommands()
    for command in startupCommands where command.method != "getDocument" && command.method != "getResourceTree" {
        #expect(commands.filter { $0 == command }.count == 1)
    }
    #expect(context.state == .attached)
}

@MainActor
@Test
func currentPageCommitInitializesNewAgentWithoutReenablingPage() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)

    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: DOM.Node.ID("new-agent-root"), nodeType: 9, nodeName: "#document")
    )
    await runtime.backend.emit(
        .didCommitProvisionalTarget(WebInspectorTargetCommitLifecycle(
            oldTargetID: .currentPage,
            newTarget: WebInspectorLifecycleTarget(
                id: .currentPage,
                kind: .page,
                frameID: FrameID("main-frame"),
                isProvisional: false,
                pageBindingID: "new-agent"
            )
        )),
        target: target
    )
    try await waitUntil(in: context) {
        context.rootNode?.id == DOMNode.ID(DOM.Node.ID("new-agent-root"))
    }

    await emitOriginatedNetworkRequest(
        id: "new-agent-network",
        loaderID: "new-agent-loader",
        originTargetID: "new-agent",
        timestamp: 1,
        target: target,
        backend: runtime.backend
    )
    try await waitUntil {
        context.network.requests.map(\.id) == [NetworkRequest.ID(Network.Request.ID("new-agent-network"))]
    }

    let commands = await runtime.backend.recordedCommands()
    #expect(commands.filter { $0 == RecordedCommand(domain: "Page", method: "enable") }.count == 1)
    for command in [
        RecordedCommand(domain: "Inspector", method: "enable"),
        RecordedCommand(domain: "Inspector", method: "initialized"),
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Network", method: "enable"),
        RecordedCommand(domain: "Console", method: "enable"),
    ] {
        #expect(commands.filter { $0 == command }.count == 2)
    }
    #expect(context.state == .attached)
}

@MainActor
@Test
func documentUpdatedDuringCurrentPageRetargetUsesTheRetargetDocumentLoad() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let consoleEnableGate = WebInspectorTestGate()
    let getDocumentGate = WebInspectorTestGate()
    let staleDocumentID = DOM.Node.ID("stale-retarget-root")
    let currentDocumentID = DOM.Node.ID("current-retarget-root")

    await runtime.backend.hold(domain: "Console", method: "enable", gate: consoleEnableGate)
    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: staleDocumentID, nodeType: 9, nodeName: "#document")
    )
    await runtime.backend.enqueue(
        DOM.Node(id: currentDocumentID, nodeType: 9, nodeName: "#document"),
        for: "DOM",
        method: "getDocument"
    )
    await runtime.backend.enqueue(
        DOM.Node(id: currentDocumentID, nodeType: 9, nodeName: "#document"),
        for: "DOM",
        method: "getDocument"
    )

    await runtime.backend.emit(
        .didCommitProvisionalTarget(WebInspectorTargetCommitLifecycle(
            oldTargetID: .currentPage,
            newTarget: WebInspectorLifecycleTarget(
                id: .currentPage,
                kind: .page,
                frameID: FrameID("main-frame"),
                isProvisional: false,
                pageBindingID: "retarget-document-agent"
            )
        )),
        target: target
    )
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "Console",
        method: "enable",
        count: 2
    )

    await runtime.backend.hold(domain: "DOM", method: "getDocument", gate: getDocumentGate)
    await runtime.backend.emit(.documentUpdated, target: target)
    await consoleEnableGate.open()
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "getDocument",
        count: 3
    )
    await runtime.backend.emit(
        .attributeModified(currentDocumentID, name: "data-buffered", value: "preserved"),
        target: target
    )
    await getDocumentGate.open()

    try await waitUntil(in: context) {
        context.rootNode?.id == DOMNode.ID(currentDocumentID)
            && context.rootNode?.attributes["data-buffered"] == "preserved"
    }
    let commands = await runtime.backend.recordedCommands()
    #expect(commands.filter {
        $0 == RecordedCommand(domain: "DOM", method: "getDocument")
    }.count == 3)
    #expect(context.node(for: DOMNode.ID(staleDocumentID)) == nil)
    #expect(context.state == .attached)
}

@MainActor
@Test
func committedTargetRequiredNetworkEnableFailureFailsContext() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)

    await runtime.backend.enqueue((), for: "Inspector", method: "enable")
    await runtime.backend.enqueue((), for: "Inspector", method: "initialized")
    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    await runtime.backend.enqueueFailure(
        WebInspectorProxyError.commandFailed(
            domain: "Network",
            method: "enable",
            message: "Network initialization failed"
        ),
        for: "Network",
        method: "enable"
    )
    await runtime.backend.enqueue((), for: "Runtime", method: "disable")
    await runtime.backend.enqueue((), for: "Page", method: "disable")
    await runtime.backend.enqueue((), for: "Inspector", method: "disable")
    await runtime.backend.emit(
        .didCommitProvisionalTarget(WebInspectorTargetCommitLifecycle(
            oldTargetID: .currentPage,
            newTarget: WebInspectorLifecycleTarget(
                id: .currentPage,
                kind: .page,
                frameID: FrameID("main-frame"),
                isProvisional: false,
                pageBindingID: "replacement-agent"
            )
        )),
        target: target
    )

    try await waitUntil(in: context) {
        if case .failed = context.state {
            return true
        }
        return false
    }
    guard case let .failed(error) = context.state else {
        Issue.record("Expected a failed context after required Network.enable failed.")
        return
    }
    #expect(error == .commandFailed(
        domain: "Network",
        method: "enable",
        message: "Network initialization failed"
    ))
}

@MainActor
@Test
func frameNavigationAndRuntimeContextApplyInSourceOrder() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let executionContextID = Runtime.ExecutionContext.ID("after-navigation")

    await runtime.backend.enqueue(
        DOM.Node(id: DOM.Node.ID("navigated-root"), nodeType: 9, nodeName: "#document"),
        for: "DOM",
        method: "getDocument"
    )
    await runtime.backend.emit(
        .frameNavigated(WebInspectorPageFrameLifecycle(
            id: FrameID("main-frame"),
            parentID: nil,
            loaderID: "navigated-loader",
            name: "Main",
            url: "https://example.test/next",
            securityOrigin: "https://example.test",
            mimeType: "text/html"
        )),
        target: target
    )
    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(
            id: executionContextID,
            name: "After navigation",
            kind: .normal
        )),
        target: target
    )

    try await waitUntil(in: context) {
        context.executionContexts.map(\.id) == [RuntimeContext.ID(executionContextID)]
    }
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
    try await waitUntil(in: context) { context.state == .attached }

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
    try await waitUntil(in: context) {
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
    try await waitUntil(in: context) {
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
        RecordedCommand(domain: "Page", method: "getResourceTree"),
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
    try await waitUntil(in: context) {
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
    try await waitUntil(in: context) { context.state == .attached }

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
    let requestSecurity = Network.Security(
        connection: Network.Security.Connection(tlsProtocol: "TLS 1.3")
    )
    let runtimeContextID = Runtime.ExecutionContext.ID("main")

    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: documentID, nodeType: 9, nodeName: "#document")
    )

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitForStartupSubscribers(runtime: runtime, target: target)
    try await waitUntil(in: context) { context.state == .attached }

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
        .responseReceived(
            id: requestID,
            response: Network.Response(status: 200).reporting(security: requestSecurity),
            resourceType: .script,
            timestamp: 1.5
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
    try await waitUntil(in: context) {
        context.network.requests.count == 1
            && context.network.requests.first?.security == requestSecurity
            && context.console.messages.count == 1
            && context.executionContexts.count == 1
    }

    let request = try #require(context.network.requests.first)
    let message = try #require(context.console.messages.first)
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
    #expect(context.network.requests.isEmpty)
    #expect(request.security == requestSecurity)
    #expect(context.registeredMessage(for: message.id) == nil)
    #expect(context.console.messages.isEmpty)
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
    try await waitUntil(in: context) { context.state == .attached }

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
    try await waitUntil(in: context) { context.rootNode?.id == DOMNode.ID(DOM.Node.ID("document-1")) }

    await enqueueDomainDisableReplies(on: runtime.backend)
    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: DOM.Node.ID("document-2"), nodeType: 9, nodeName: "#document")
    )

    context.start()

    try await waitUntil(in: context) { context.rootNode?.id == DOMNode.ID(DOM.Node.ID("document-2")) }

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
    try await waitForRecordedCommands(on: runtime.backend, expected: [
            RecordedCommand(domain: "Inspector", method: "enable"),
            RecordedCommand(domain: "Inspector", method: "initialized"),
            RecordedCommand(domain: "Page", method: "enable"),
            RecordedCommand(domain: "Runtime", method: "enable"),
            RecordedCommand(domain: "Network", method: "enable"),
        ])

    await enqueueDomainDisableReplies(on: runtime.backend)
    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: DOM.Node.ID("restarted-document"), nodeType: 9, nodeName: "#document")
    )

    context.start()

    await enableGate.open()
    try await waitUntil(in: context) { context.rootNode?.id == DOMNode.ID(DOM.Node.ID("restarted-document")) }

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
func restartSynchronouslyRejectsSupersededOrderedEventsAcrossDomains() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let oldDocumentID = DOM.Node.ID("old-generation-document")
    let oldElementID = DOM.Node.ID("old-generation-element")
    let freshDocumentID = DOM.Node.ID("fresh-generation-document")
    let freshElementID = DOM.Node.ID("fresh-generation-element")
    let oldRequestID = Network.Request.ID("old-generation-request")
    let staleRequestID = Network.Request.ID("stale-generation-request")
    let freshRequestID = Network.Request.ID("fresh-generation-request")
    let oldRuntimeID = Runtime.ExecutionContext.ID("old-generation-runtime")
    let staleRuntimeID = Runtime.ExecutionContext.ID("stale-generation-runtime")
    let freshRuntimeID = Runtime.ExecutionContext.ID("fresh-generation-runtime")
    let oldDocument = DOM.Node(
        id: oldDocumentID,
        nodeType: 9,
        nodeName: "#document",
        childNodeCount: 1,
        children: [
            DOM.Node(
                id: oldElementID,
                nodeType: 1,
                nodeName: "DIV",
                localName: "div",
                attributes: ["data-generation": "seed"]
            )
        ]
    )
    let freshDocument = DOM.Node(
        id: freshDocumentID,
        nodeType: 9,
        nodeName: "#document",
        childNodeCount: 1,
        children: [
            DOM.Node(
                id: freshElementID,
                nodeType: 1,
                nodeName: "DIV",
                localName: "div",
                attributes: ["data-generation": "fresh-seed"]
            )
        ]
    )
    let (target, context) = try await startContext(runtime: runtime, document: oldDocument)
    var networkChanges = context.network.requestChanges.makeAsyncIterator()

    let seedAppliedBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(
        .requestWillBeSent(
            id: oldRequestID,
            request: Network.Request(
                id: oldRequestID,
                url: "https://example.test/old",
                method: "GET"
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    await runtime.backend.emit(
        .attributeModified(oldElementID, name: "data-generation", value: "old"),
        target: target
    )
    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "warning"),
            text: "old-console"
        )),
        target: target
    )
    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(
            id: oldRuntimeID,
            name: "Old Runtime",
            kind: .normal
        )),
        target: target
    )
    await runtime.backend.emit(.mediaQueryResultChanged, target: target)
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(
        after: seedAppliedBaseline,
        count: 5
    ))

    let oldElement = try #require(context.node(for: DOMNode.ID(oldElementID)))
    context.select(oldElement)
    context.seedSelectedNodeStyles(matchedStyles: CSS.MatchedStyles())
    let oldStyles = try #require(oldElement.elementStyles)
    let oldConsoleMessage = try #require(context.console.messages.first)
    let oldRuntimeContext = try #require(context.executionContexts.first)
    #expect(oldStyles.phase == .loaded)
    #expect(context.network.requests.count == 1)
    #expect(oldElement.attributes["data-generation"] == "old")
    #expect(oldConsoleMessage.text == "old-console")
    #expect(oldRuntimeContext.id == RuntimeContext.ID(oldRuntimeID))
    #expect(await networkChanges.next() == .inserted([NetworkRequest.ID(oldRequestID)]))

    let supersededSubscription = context.orderedEventSubscriptionStateForTesting
    let appliedBaseline = context.eventPumpAppliedSequenceForTesting
    #expect(await runtime.backend.activeOrderedEventSubscriberCount(for: target) == 1)
    let disableGate = WebInspectorTestGate()
    await runtime.backend.hold(domain: "Console", method: "disable", gate: disableGate)
    await enqueueDomainDisableReplies(on: runtime.backend)
    await enqueueStartupReplies(on: runtime.backend, document: freshDocument)

    context.start()
    let restartTask = try #require(context.startupTaskForTesting())
    let linearizedSubscription = context.orderedEventSubscriptionStateForTesting
    #expect(linearizedSubscription.generation == supersededSubscription.generation + 1)
    #expect(linearizedSubscription.sequence == supersededSubscription.sequence)
    #expect(context.network.requests.isEmpty)
    #expect(context.registeredRequest(forProxyID: oldRequestID) == nil)
    #expect(await networkChanges.next() == .reset)

    _ = await runtime.backend.waitForRecordedCommands(
        domain: "Console",
        method: "disable",
        count: 1
    )

    let staleEvents: [WebInspectorProxyEvent] = [
        .network(.responseReceived(
            id: staleRequestID,
            response: Network.Response(
                url: "https://example.test/stale",
                status: 200,
                mimeType: "text/plain"
            ),
            resourceType: .fetch,
            timestamp: 2
        )),
        .dom(.attributeModified(
            oldElementID,
            name: "data-generation",
            value: "stale"
        )),
        .console(Console.TargetedEvent(
            event: .messageAdded(Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "error"),
                text: "stale-console"
            )),
            targetID: target.id
        )),
        .runtime(.executionContextCreated(Runtime.ExecutionContext(
            id: staleRuntimeID,
            name: "Stale Runtime",
            kind: .normal
        ))),
        .css(.mediaQueryResultChanged),
    ]
    for event in staleEvents {
        await context.applyOrderedEventForTesting(
            WebInspectorProxyOrderedEvent(
                sequence: supersededSubscription.sequence,
                event: event
            ),
            target: target,
            subscriptionGeneration: supersededSubscription.generation
        )
    }

    #expect(context.orderedEventSubscriptionStateForTesting == linearizedSubscription)
    #expect(context.eventPumpAppliedSequenceForTesting == appliedBaseline)
    #expect(context.network.requests.isEmpty)
    #expect(context.registeredRequest(forProxyID: staleRequestID) == nil)
    #expect(oldElement.attributes["data-generation"] == "old")
    #expect(oldStyles.phase == .loaded)
    #expect(context.console.messages.first === oldConsoleMessage)
    #expect(context.console.messages.map(\.text) == ["old-console"])
    #expect(context.executionContexts.first === oldRuntimeContext)
    #expect(context.executionContexts.map(\.id) == [RuntimeContext.ID(oldRuntimeID)])

    await disableGate.open()
    await restartTask.value
    try await waitForStartupSubscribers(runtime: runtime, target: target)
    #expect(await runtime.backend.activeOrderedEventSubscriberCount(for: target) == 1)
    #expect(context.state == .attached)

    let freshElement = try #require(context.node(for: DOMNode.ID(freshElementID)))
    context.select(freshElement)
    context.seedSelectedNodeStyles(matchedStyles: CSS.MatchedStyles())
    let freshStyles = try #require(freshElement.elementStyles)
    #expect(freshStyles.phase == .loaded)
    let freshAppliedBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(
        .responseReceived(
            id: freshRequestID,
            response: Network.Response(
                url: "https://example.test/fresh",
                status: 201,
                mimeType: "application/json"
            ),
            resourceType: .fetch,
            timestamp: 3
        ),
        target: target
    )
    await runtime.backend.emit(
        .attributeModified(freshElementID, name: "data-generation", value: "fresh"),
        target: target
    )
    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "log"),
            text: "fresh-console"
        )),
        target: target
    )
    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(
            id: freshRuntimeID,
            name: "Fresh Runtime",
            kind: .normal
        )),
        target: target
    )
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(
        after: freshAppliedBaseline,
        count: 4
    ))

    context.seedSelectedNodeStyles(matchedStyles: CSS.MatchedStyles())
    #expect(freshStyles.phase == .loaded)
    let freshCSSAppliedBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(.mediaQueryResultChanged, target: target)
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(
        after: freshCSSAppliedBaseline
    ))

    let freshSubscription = context.orderedEventSubscriptionStateForTesting
    #expect(freshSubscription.generation == linearizedSubscription.generation + 1)
    #expect(freshSubscription.sequence > supersededSubscription.sequence)
    #expect(context.network.requests.count == 1)
    #expect(context.registeredRequest(forProxyID: freshRequestID) != nil)
    #expect(await networkChanges.next() == .inserted([NetworkRequest.ID(freshRequestID)]))
    #expect(freshElement.attributes["data-generation"] == "fresh")
    #expect(freshStyles.phase == .needsRefresh)
    #expect(context.console.messages.map(\.text) == ["fresh-console"])
    #expect(context.executionContexts.map(\.id) == [RuntimeContext.ID(freshRuntimeID)])
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
    try await waitForRecordedCommands(on: runtime.backend, expected: startupCommands)

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

    try await waitUntil(in: context) { context.rootNode?.id == DOMNode.ID(freshDocumentID) }
    #expect(context.state == .attached)
    #expect(context.node(for: DOMNode.ID(staleDocumentID)) == nil)
    #expect(await runtime.backend.recordedCommands() == startupCommands + [
        RecordedCommand(domain: "DOM", method: "getDocument")
    ])
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
        context.network.requests.map(\.id) == [NetworkRequest.ID(retainedRequestID)]
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
        timeout: .seconds(30),
        includePageEnable: false
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

    try await replyTransportResourceTreeUnavailable(
        backend,
        transport: transport,
        after: startupMessageCount,
        timeout: .seconds(30)
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

    try await waitUntil(in: context) { context.rootNode?.id == newRootID }
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
    #expect(context.network.requests.map(\.id) == [NetworkRequest.ID(retainedRequestID)])

    let postCommitRequestID = Network.Request.ID("commit-post-request")
    await receiveTransportTargetEvent(
        transport,
        targetID: newTargetID,
        method: "Network.requestWillBeSent",
        params: #"{"requestId":"commit-post-request","frameId":"new-main-frame","loaderId":"loader-2","request":{"url":"https://example.test/after-commit","method":"GET"},"initiator":{"type":"other"},"type":"Fetch","timestamp":2}"#
    )
    try await waitUntil {
        Set(context.network.requests.map(\.id)) == [
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
        $0 == "DOM.getDocument" || $0 == "Page.getResourceTree" || $0 == "Inspector.enable" || $0 == "Inspector.initialized" || $0 == "Page.enable"
    })
    let trackingMethods = Array(newTargetMethods[runtimeEnableIndex...])
    #expect(Array(trackingMethods.prefix(4)) == [
        "Runtime.enable",
        "Network.enable",
        "Page.getResourceTree",
        "DOM.getDocument",
    ])
    #expect(trackingMethods.contains("Console.enable"))
    #expect(Set(newTargetMethods).isSubset(of: [
        "Inspector.enable",
        "Inspector.initialized",
        "Page.enable",
        "Runtime.enable",
        "Network.enable",
        "Page.getResourceTree",
        "DOM.getDocument",
        "Console.enable",
    ]))

    await receiveTransportTargetEvent(
        transport,
        targetID: oldTargetID,
        method: "DOM.childNodeInserted",
        params: ##"{"parentNodeId":"new-root","previousNodeId":0,"node":{"nodeId":"old-route-child","nodeType":1,"nodeName":"DIV","localName":"div","nodeValue":"","childNodeCount":0}}"##
    )
    await receiveTransportTargetEvent(
        transport,
        targetID: newTargetID,
        method: "DOM.attributeModified",
        params: #"{"nodeId":"new-root","name":"data-probe","value":"new"}"#
    )
    try await waitUntil(in: context) { context.rootNode?.attributes["data-probe"] == "new" }
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
func currentPageProcessTerminationInterruptsPickerAndRetargetsWithoutClearingNetwork() async throws {
    let oldTargetID = ProtocolTarget.ID("page-old")
    let newTargetID = ProtocolTarget.ID("page-new-after-destroy")
    let retainedRequestID = Network.Request.ID("destroy-retained-request")
    let (backend, transport, context) = try await startTransportBackedContext(
        targetID: oldTargetID,
        documentID: "destroyed-root"
    )
    let startupMessageCount = await backend.sentTargetMessages().count

    #expect(context.state == .attached)
    #expect(context.rootNode?.id == DOMNode.ID(DOM.Node.ID("destroyed-root")))
    await receiveTransportTargetEvent(
        transport,
        targetID: oldTargetID,
        method: "Network.requestWillBeSent",
        params: #"{"requestId":"destroy-retained-request","frameId":"main-frame","loaderId":"loader-1","request":{"url":"https://example.test/retained","method":"GET"},"initiator":{"type":"other"},"type":"Fetch","timestamp":1}"#
    )
    await receiveTransportTargetEvent(
        transport,
        targetID: oldTargetID,
        method: "Network.responseReceived",
        params: #"{"requestId":"destroy-retained-request","frameId":"main-frame","loaderId":"loader-1","type":"Fetch","response":{"url":"https://example.test/retained","status":200,"headers":{},"security":{"connection":{"protocol":"TLS 1.3"},"certificate":{"subject":"retained.example.test"}}},"timestamp":1.5}"#
    )
    try await waitUntil {
        context.network.requests.map(\.id) == [NetworkRequest.ID(retainedRequestID)]
            && context.network.requests.first?.security?.certificate?.subject == "retained.example.test"
    }
    let retainedRequest = try #require(context.network.requests.first)

    let interruptedPickerMessageCount = await backend.sentTargetMessages().count
    let interruptedPickerTask = Task { @MainActor in
        try await context.setElementPickerEnabled(true)
    }
    let interruptedInspectMode = try await waitForTransportTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: interruptedPickerMessageCount
    )
    #expect(interruptedInspectMode.targetIdentifier == oldTargetID)

    await transport.currentPageProcessDidTerminate()
    do {
        try await interruptedPickerTask.value
        Issue.record("Expected the in-flight picker command to fail when its WebContent process terminated.")
    } catch {}

    #expect(context.state == .attached)
    #expect(context.rootNode?.id == DOMNode.ID(DOM.Node.ID("destroyed-root")))
    #expect(context.isElementPickerEnabled == false)
    #expect(context.network.requests.map(\.id) == [NetworkRequest.ID(retainedRequestID)])
    #expect(context.network.requests.first === retainedRequest)
    #expect(retainedRequest.security?.connection?.tlsProtocol == "TLS 1.3")
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

    try await replyTransportResourceTreeUnavailable(
        backend,
        transport: transport,
        after: startupMessageCount,
        timeout: .seconds(30)
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

    try await waitUntil(in: context) {
        context.rootNode?.id == DOMNode.ID(DOM.Node.ID("reattached-root"))
    }
    #expect(context.state == .attached)
    #expect(context.rootNode?.id == DOMNode.ID(DOM.Node.ID("reattached-root")))
    #expect(context.network.requests.map(\.id) == [NetworkRequest.ID(retainedRequestID)])
    #expect(context.network.requests.first === retainedRequest)
    #expect(retainedRequest.security?.certificate?.subject == "retained.example.test")

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
func sharedContainerContextsInitializeCommittedTargetWithoutReenablingPage() async throws {
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
    let contextB = WebInspectorContext(container)
    contextB.start()
    try await waitUntil(in: contextA, contextB, timeout: .seconds(5)) {
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
    try await waitUntil(in: contextA, contextB, timeout: .seconds(5)) {
        contextA.state == .attached && contextB.state == .attached
            && contextA.rootNode?.id == newRootID
            && contextB.rootNode?.id == newRootID
    }

    let postSwapMessages = Array((await backend.sentTargetMessages()).dropFirst(preSwapMessageCount))
    let pageEnables = try postSwapMessages.filter {
        try $0.targetIdentifier == newTargetID && transportTargetMessageMethod($0.message) == "Page.enable"
    }
    #expect(pageEnables.isEmpty, "Page.enable is semantic across a provisional-target commit")

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
    try await waitUntil(in: context, timeout: .seconds(5)) { context.state == .attached }
    #expect(context.rootNode != nil)

    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"page-doomed"}}"#
    )

    try await waitUntil(in: context, timeout: .seconds(5)) {
        context.state == .attaching && context.rootNode == nil
    }

    await installTransportPageTarget(in: transport, targetID: rebornTargetID, frameID: "reborn-frame")

    let rebornRootID = DOMNode.ID(DOM.Node.ID("reborn-root"))
    try await waitUntil(in: context, timeout: .seconds(5)) {
        context.state == .attached && context.rootNode?.id == rebornRootID
    }
}

@MainActor
@Test
func startCancelsInFlightCurrentPageRetargetBeforeRestarting() async throws {
    let oldTargetID = ProtocolTarget.ID("page-restart-old")
    let newTargetID = ProtocolTarget.ID("page-restart-new")
    let restartedRootID = DOMNode.ID(DOM.Node.ID("restarted-root"))
    let staleRetargetRootID = DOMNode.ID(DOM.Node.ID("stale-retarget-root"))
    let (backend, transport, context) = try await startTransportBackedContext(
        targetID: oldTargetID,
        documentID: "restart-old-root"
    )
    let startupMessageCount = await backend.sentTargetMessages().count

    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-restart-new","type":"page","frameId":"main-frame","isProvisional":true}}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-restart-old","newTargetId":"page-restart-new"}}"#
    )

    try await replyTransportInspectorAndPageInitialization(
        backend,
        transport: transport,
        targetID: newTargetID,
        after: startupMessageCount,
        includePageEnable: false
    )
    for method in ["Runtime.enable", "Network.enable"] {
        let enable = try await waitForTransportTargetMessage(
            backend,
            method: method,
            after: startupMessageCount
        )
        await receiveTransportTargetReply(
            transport,
            targetID: enable.targetIdentifier,
            messageID: try transportMessageID(enable.message),
            result: "{}"
        )
    }
    try await replyTransportResourceTreeUnavailable(
        backend,
        transport: transport,
        after: startupMessageCount
    )
    let retargetGetDocument = try await waitForTransportTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: startupMessageCount
    )
    #expect(retargetGetDocument.targetIdentifier == newTargetID)
    let retargetTask = try #require(context.currentPageRetargetTaskForTesting())
    let restartMessageCount = await backend.sentTargetMessages().count

    let autoReplier = startAutoReplyingTransportTargetMessages(
        backend: backend,
        transport: transport,
        after: restartMessageCount
    ) { targetID in
        targetID == newTargetID ? "restarted-root" : "restart-unexpected-root"
    }
    defer { autoReplier.cancel() }

    context.start()
    #expect(retargetTask.isCancelled)
    try await waitUntil(in: context, timeout: .seconds(5)) {
        context.state == .attached && context.rootNode?.id == restartedRootID
    }

    await receiveTransportTargetReply(
        transport,
        targetID: retargetGetDocument.targetIdentifier,
        messageID: try transportMessageID(retargetGetDocument.message),
        result: transportDocumentResult(nodeID: "stale-retarget-root")
    )
    await retargetTask.value

    #expect(context.state == .attached)
    #expect(context.rootNode?.id == restartedRootID)
    #expect(context.node(for: staleRetargetRootID) == nil)
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
    let undoCommands = try context.domUndoRedoCommands()
    let startupMessageCount = await backend.sentTargetMessages().count

    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Runtime.executionContextCreated",
        params: #"{"context":{"id":21,"name":"Main","frameId":"main-frame","type":"normal"}}"#
    )
    try await waitUntil(in: context) { context.executionContexts.map(\.id) == [RuntimeContext.ID(Runtime.ExecutionContext.ID("21"))] }

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

    try await waitUntil(in: context) { context.rootNode?.id == navigatedRootID }
    #expect(context.executionContexts.isEmpty)
    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Network.requestWillBeSent",
        params: #"{"requestId":"navigated-request","frameId":"main-frame","loaderId":"loader-2","request":{"url":"https://example.test/after-frame-navigation","method":"GET"},"initiator":{"type":"other"},"type":"Document","timestamp":3}"#
    )
    try await waitUntil {
        context.network.requests.map(\.id) == [NetworkRequest.ID(navigatedRequestID)]
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
    _ = try await runtime.backend.waitForRecordedCommandsForTesting(domain: "DOM", method: "getDocument", count: 1)

    await container.close()
    #expect(context.state == .detached)

    await gate.open()
    await startupTask.value

    #expect(context.state == .detached)
    #expect(context.rootNode == nil)

    let commands = await runtime.backend.recordedCommands()
    #expect(commands == Array(startupCommands.prefix(7)) + [
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
    try await waitForRecordedCommands(on: runtime.backend, expected: [
            RecordedCommand(domain: "Inspector", method: "enable"),
            RecordedCommand(domain: "Inspector", method: "initialized"),
            RecordedCommand(domain: "Page", method: "enable"),
            RecordedCommand(domain: "Runtime", method: "enable"),
        ])

    await runtime.backend.enqueue((), for: "Page", method: "disable")
    await runtime.backend.enqueue((), for: "Inspector", method: "disable")
    await context.stop()
    #expect(context.state == .detached)

    await runtime.backend.enqueue((), for: "Runtime", method: "disable")
    await gate.open()
    try await waitForRecordedCommands(on: runtime.backend, expected: [
            RecordedCommand(domain: "Inspector", method: "enable"),
            RecordedCommand(domain: "Inspector", method: "initialized"),
            RecordedCommand(domain: "Page", method: "enable"),
            RecordedCommand(domain: "Runtime", method: "enable"),
            RecordedCommand(domain: "Page", method: "disable"),
            RecordedCommand(domain: "Inspector", method: "disable"),
            RecordedCommand(domain: "Runtime", method: "disable"),
        ])
    #expect(context.state == .detached)
}
