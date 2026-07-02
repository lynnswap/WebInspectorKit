import Testing
import WebViewProxyKit
import WebViewProxyKitTesting

@Test
func domGetDocumentDispatchesToTargetRoute() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
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
func networkEventsAreSeparatedByTarget() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
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
    let runtime = try await WebViewProxyTestRuntime.start()
    let originalTarget = try await runtime.proxy.waitForCurrentPage()
    let retargetedHandle = WebViewTarget(
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
func pageReloadDispatchesToTargetRoute() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
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
    let runtime = try await WebViewProxyTestRuntime.start()
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

private struct TimedOut: Error {}

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
