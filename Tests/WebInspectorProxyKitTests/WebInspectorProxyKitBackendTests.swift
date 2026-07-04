import Testing
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

@Test
func domGetDocumentDispatchesToTargetRoute() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let expectedNode = DOM.Node(
        id: DOM.Node.ID("document"),
        nodeType: 9,
        nodeName: "#document"
    )

    await runtime.backend.enqueue(expectedNode, for: "DOM", method: "getDocument")

    let node = try await target.dom.getDocument()
    #expect(node.id == expectedNode.id)

    let commands = await runtime.backend.recordedCommands()
    let command = try #require(commands.first)
    #expect(command.targetID == target.id)
    #expect(command.route == target.route)
    #expect(command.domain == "DOM")
    #expect(command.method == "getDocument")
    #expect(command.payload.cast(as: DOM.GetDocumentPayload.self) != nil)
}

@Test
func domRequestNodeDispatchesToTargetRoute() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let objectID = Runtime.RemoteObject.ID("remote-node")
    let expectedNodeID = DOM.Node.ID("selected-node")

    await runtime.backend.enqueue(expectedNodeID, for: "DOM", method: "requestNode")

    let nodeID = try await target.dom.requestNode(forRemoteObject: objectID)
    #expect(nodeID == expectedNodeID)

    let commands = await runtime.backend.recordedCommands()
    let command = try #require(commands.first)
    #expect(command.targetID == target.id)
    #expect(command.route == target.route)
    #expect(command.domain == "DOM")
    #expect(command.method == "requestNode")
    let payload = try #require(command.payload.cast(as: DOM.RequestNodePayload.self))
    #expect(payload.objectID == objectID)
}

@Test
func inspectorInspectResolvesNodeRemoteObjectToDOMInspectEvent() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let objectID = Runtime.RemoteObject.ID("remote-node")
    let expectedNodeID = DOM.Node.ID("selected-node")

    let eventTask = Task {
        var iterator = target.dom.events.makeAsyncIterator()
        return await iterator.next()
    }

    try await runtime.backend.waitForSubscribers(domain: "DOM", target: target, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "Inspector", target: target, count: 1)
    await runtime.backend.enqueue(expectedNodeID, for: "DOM", method: "requestNode")

    await runtime.backend.emit(
        .inspect(
            Runtime.RemoteObject(
                id: objectID,
                kind: .object,
                subtype: Runtime.Subtype(rawValue: "node")
            ),
            hints: .object([:]),
            origin: nil
        ),
        target: target
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .inspect(nodeID) = event else {
        Issue.record("Expected Inspector.inspect to resolve to DOM.inspect.")
        return
    }
    #expect(nodeID == expectedNodeID)

    let commands = await runtime.backend.recordedCommands()
    let command = try #require(commands.first)
    #expect(command.targetID == target.id)
    #expect(command.route == target.route)
    #expect(command.domain == "DOM")
    #expect(command.method == "requestNode")
    let payload = try #require(command.payload.cast(as: DOM.RequestNodePayload.self))
    #expect(payload.objectID == objectID)
}

@Test
func domInspectEventPassesThroughWithoutRequestNode() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let expectedNodeID = DOM.Node.ID("protocol-node")

    let eventTask = Task {
        var iterator = target.dom.events.makeAsyncIterator()
        return await iterator.next()
    }

    try await runtime.backend.waitForSubscribers(domain: "DOM", target: target, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "Inspector", target: target, count: 1)

    await runtime.backend.emit(.inspect(expectedNodeID), target: target)

    let event = try #require(try await value(of: eventTask))
    guard case let .inspect(nodeID) = event else {
        Issue.record("Expected DOM.inspect to pass through.")
        return
    }
    #expect(nodeID == expectedNodeID)
    #expect(await runtime.backend.recordedCommands().isEmpty)
}

@Test
func inspectorInspectIgnoresNonNodeRemoteObject() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let recorder = EventRecorder<DOM.Event>()

    let eventTask = Task {
        var iterator = target.dom.events.makeAsyncIterator()
        if let event = await iterator.next() {
            await recorder.record(event)
        }
    }

    try await runtime.backend.waitForSubscribers(domain: "DOM", target: target, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "Inspector", target: target, count: 1)

    await runtime.backend.emit(
        .inspect(
            Runtime.RemoteObject(
                id: Runtime.RemoteObject.ID("function-object"),
                kind: .function
            ),
            hints: .object([:]),
            origin: nil
        ),
        target: target
    )

    try await Task.sleep(for: .milliseconds(100))
    #expect(await recorder.value() == nil)
    eventTask.cancel()
    #expect(await runtime.backend.recordedCommands().isEmpty)
}

@Test
func networkEventsAreSeparatedByTarget() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let firstTarget = try await runtime.proxy.waitForCurrentPage()
    let secondTarget = await runtime.proxy.installTargetForTesting(kind: .frame)

    let firstEventTask = Task {
        var iterator = firstTarget.network.events.makeAsyncIterator()
        return await iterator.next()
    }
    let secondEventTask = Task {
        var iterator = secondTarget.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    try await runtime.backend.waitForSubscribers(domain: "Network", target: firstTarget.id, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "Network", target: secondTarget.id, count: 1)

    await runtime.backend.emit(
        .responseReceived(
            id: Network.Request.ID("first-request"),
            response: Network.Response(status: 200),
            resourceType: .document,
            timestamp: 1
        ),
        target: firstTarget.id
    )
    await runtime.backend.emit(
        .responseReceived(
            id: Network.Request.ID("second-request"),
            response: Network.Response(status: 201),
            resourceType: .xhr,
            timestamp: 2
        ),
        target: secondTarget.id
    )

    let firstEvent = try #require(try await value(of: firstEventTask))
    let secondEvent = try #require(try await value(of: secondEventTask))

    guard case let .responseReceived(firstID, _, firstType, firstTimestamp) = firstEvent else {
        Issue.record("Expected first target to receive Network.responseReceived.")
        return
    }
    #expect(firstID == Network.Request.ID("first-request"))
    #expect(firstType == .document)
    #expect(firstTimestamp == 1)

    guard case let .responseReceived(secondID, _, secondType, secondTimestamp) = secondEvent else {
        Issue.record("Expected second target to receive Network.responseReceived.")
        return
    }
    #expect(secondID == Network.Request.ID("second-request"))
    #expect(secondType == .xhr)
    #expect(secondTimestamp == 2)
}

@Test
func networkEventsAreSeparatedByRouteForStableTargetID() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let originalTarget = try await runtime.proxy.waitForCurrentPage()
    let retargetedHandle = WebInspectorTarget(
        id: originalTarget.id,
        kind: originalTarget.kind,
        frameID: originalTarget.frameID,
        isProvisional: originalTarget.isProvisional,
        proxy: runtime.proxy,
        route: RoutingTargetID("retargeted-route")
    )

    let originalEventTask = Task {
        var iterator = originalTarget.network.events.makeAsyncIterator()
        return await iterator.next()
    }
    let retargetedEventTask = Task {
        var iterator = retargetedHandle.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    try await runtime.backend.waitForSubscribers(domain: "Network", target: originalTarget, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "Network", target: retargetedHandle, count: 1)

    await runtime.backend.emit(
        .responseReceived(
            id: Network.Request.ID("retargeted-request"),
            response: Network.Response(status: 202),
            resourceType: .fetch,
            timestamp: 3
        ),
        target: retargetedHandle
    )
    await runtime.backend.emit(
        .responseReceived(
            id: Network.Request.ID("original-request"),
            response: Network.Response(status: 200),
            resourceType: .document,
            timestamp: 4
        ),
        target: originalTarget
    )

    let originalEvent = try #require(try await value(of: originalEventTask))
    let retargetedEvent = try #require(try await value(of: retargetedEventTask))

    guard case let .responseReceived(originalID, _, _, _) = originalEvent else {
        Issue.record("Expected original route to receive Network.responseReceived.")
        return
    }
    #expect(originalID == Network.Request.ID("original-request"))

    guard case let .responseReceived(retargetedID, _, _, _) = retargetedEvent else {
        Issue.record("Expected retargeted route to receive Network.responseReceived.")
        return
    }
    #expect(retargetedID == Network.Request.ID("retargeted-request"))
}

@Test
func networkLoadingFinishedCarriesTerminalMetadata() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    let eventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    try await runtime.backend.waitForSubscribers(domain: "Network", target: target, count: 1)

    await runtime.backend.emit(
        .loadingFinished(
            id: Network.Request.ID("terminal-request"),
            timestamp: 8,
            sourceMapURL: "terminal.js.map",
            metrics: Network.Metrics(encodedDataLength: 256, decodedBodyLength: 512)
        ),
        target: target
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .loadingFinished(id, timestamp, sourceMapURL, metrics) = event else {
        Issue.record("Expected Network.loadingFinished.")
        return
    }
    #expect(id == Network.Request.ID("terminal-request"))
    #expect(timestamp == 8)
    #expect(sourceMapURL == "terminal.js.map")
    #expect(metrics?.encodedDataLength == 256)
    #expect(metrics?.decodedBodyLength == 512)
}

@Test
func pageReloadDispatchesToTargetRoute() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    await runtime.backend.enqueue((), for: "Page", method: "reload")

    try await target.page.reload()

    let commands = await runtime.backend.recordedCommands()
    let command = try #require(commands.first)
    #expect(command.targetID == target.id)
    #expect(command.route == target.route)
    #expect(command.domain == "Page")
    #expect(command.method == "reload")
    let payload = try #require(command.payload.cast(as: Page.ReloadPayload.self))
    #expect(payload.ignoringCache == false)
}

@Test
func networkEnableAndDisableDispatchToTargetRoute() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    await runtime.backend.enqueue((), for: "Network", method: "enable")
    await runtime.backend.enqueue((), for: "Network", method: "disable")

    try await target.network.enable()
    try await target.network.disable()

    let commands = await runtime.backend.recordedCommands()
    let enable = try #require(commands.first)
    #expect(enable.targetID == target.id)
    #expect(enable.route == target.route)
    #expect(enable.domain == "Network")
    #expect(enable.method == "enable")
    #expect(enable.payload.cast(as: Network.EnablePayload.self) != nil)

    let disable = try #require(commands.dropFirst().first)
    #expect(disable.targetID == target.id)
    #expect(disable.route == target.route)
    #expect(disable.domain == "Network")
    #expect(disable.method == "disable")
    #expect(disable.payload.cast(as: Network.DisablePayload.self) != nil)
}

@Test
func consoleEnableAndDisableDispatchToTargetRoute() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    await runtime.backend.enqueue((), for: "Console", method: "enable")
    await runtime.backend.enqueue((), for: "Console", method: "disable")

    try await target.console.enable()
    try await target.console.disable()

    let commands = await runtime.backend.recordedCommands()
    let enable = try #require(commands.first)
    #expect(enable.targetID == target.id)
    #expect(enable.route == target.route)
    #expect(enable.domain == "Console")
    #expect(enable.method == "enable")
    #expect(enable.payload.cast(as: Console.EnablePayload.self) != nil)

    let disable = try #require(commands.dropFirst().first)
    #expect(disable.targetID == target.id)
    #expect(disable.route == target.route)
    #expect(disable.domain == "Console")
    #expect(disable.method == "disable")
    #expect(disable.payload.cast(as: Console.DisablePayload.self) != nil)
}

@Test
func runtimeEnableAndDisableDispatchToTargetRoute() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    await runtime.backend.enqueue((), for: "Runtime", method: "disable")

    try await target.runtime.enable()
    try await target.runtime.disable()

    let commands = await runtime.backend.recordedCommands()
    let enable = try #require(commands.first)
    #expect(enable.targetID == target.id)
    #expect(enable.route == target.route)
    #expect(enable.domain == "Runtime")
    #expect(enable.method == "enable")
    #expect(enable.payload.cast(as: Runtime.EnablePayload.self) != nil)

    let disable = try #require(commands.dropFirst().first)
    #expect(disable.targetID == target.id)
    #expect(disable.route == target.route)
    #expect(disable.domain == "Runtime")
    #expect(disable.method == "disable")
    #expect(disable.payload.cast(as: Runtime.DisablePayload.self) != nil)
}

@Test
func cssEnableAndDisableDispatchToTargetRoute() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    await runtime.backend.enqueue((), for: "CSS", method: "enable")
    await runtime.backend.enqueue((), for: "CSS", method: "disable")

    try await target.css.enable()
    try await target.css.disable()

    let commands = await runtime.backend.recordedCommands()
    let enable = try #require(commands.first)
    #expect(enable.targetID == target.id)
    #expect(enable.route == target.route)
    #expect(enable.domain == "CSS")
    #expect(enable.method == "enable")
    #expect(enable.payload.cast(as: CSS.EnablePayload.self) != nil)

    let disable = try #require(commands.dropFirst().first)
    #expect(disable.targetID == target.id)
    #expect(disable.route == target.route)
    #expect(disable.domain == "CSS")
    #expect(disable.method == "disable")
    #expect(disable.payload.cast(as: CSS.DisablePayload.self) != nil)
}

private struct TimedOut: Error {}

private actor EventRecorder<Element: Sendable> {
    private var recordedValue: Element?

    func record(_ value: Element) {
        recordedValue = value
    }

    func value() -> Element? {
        recordedValue
    }
}

private func value<T: Sendable>(
    of task: Task<T, Never>,
    timeout: Duration = .seconds(1)
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            await task.value
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimedOut()
        }
        guard let value = try await group.next() else {
            throw TimedOut()
        }
        group.cancelAll()
        return value
    }
}
