import Testing
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

@Test
func webInspectorProxyPublicLifecycleAndCommandSurfaceWorksFromConsumerPackage() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    guard case .page = target.kind else {
        Issue.record("Expected WebInspectorProxyTestRuntime to install a page target.")
        return
    }
    #expect(await runtime.proxy.canReload)

    let page = runtime.proxy.page
    let targetDOM: DOM = target.dom
    let targetCSS: CSS = target.css
    let targetNetwork: Network = target.network
    let targetConsole: Console = target.console
    let targetRuntime: Runtime = target.runtime
    let targetPage: Page = target.page
    let currentPageDOM: DOM = page.dom
    let currentPageCSS: CSS = page.css
    let currentPageNetwork: Network = page.network
    let currentPageConsole: Console = page.console
    let currentPageRuntime: Runtime = page.runtime
    let currentPageCommands: Page = page.page
    _ = (
        targetDOM,
        targetCSS,
        targetConsole,
        targetRuntime,
        targetPage,
        currentPageDOM,
        currentPageCSS,
        currentPageNetwork,
        currentPageConsole,
        currentPageRuntime,
        currentPageCommands
    )

    await runtime.backend.enqueue((), for: "Network", method: "enable")
    try await targetNetwork.enable()

    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "Network", method: "enable")))
    #expect(commands.first?.targetID == target.id)

    await runtime.proxy.close()
    try await runtime.proxy.waitUntilClosed()
    #expect(await runtime.proxy.canReload == false)
}

@Test
func webInspectorProxyNetworkEventsMulticastToConsumerSubscribers() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    let firstEventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }
    let secondEventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    try await runtime.backend.waitForSubscribers(domain: "Network", target: target, count: 2)

    await runtime.backend.emit(
        .responseReceived(
            id: WebInspectorProxyTestFixtures.networkRequestID("contract-multicast-request"),
            response: Network.Response(status: 204, mimeType: "application/json"),
            resourceType: .fetch,
            timestamp: 42
        ),
        target: target
    )

    let firstEvent = try #require(try await ContractTestSupport.value(of: firstEventTask))
    let secondEvent = try #require(try await ContractTestSupport.value(of: secondEventTask))

    guard case let .responseReceived(firstID, firstResponse, firstType, firstTimestamp) = firstEvent else {
        Issue.record("Expected the first subscriber to receive Network.responseReceived.")
        return
    }
    guard case let .responseReceived(secondID, secondResponse, secondType, secondTimestamp) = secondEvent else {
        Issue.record("Expected the second subscriber to receive Network.responseReceived.")
        return
    }

    let expectedID = WebInspectorProxyTestFixtures.networkRequestID("contract-multicast-request")
    #expect(firstID == expectedID)
    #expect(secondID == expectedID)
    #expect(firstResponse.status == 204)
    #expect(secondResponse.status == 204)
    #expect(firstType == .fetch)
    #expect(secondType == .fetch)
    #expect(firstTimestamp == 42)
    #expect(secondTimestamp == 42)
}

private func domStructuredEventSurfaceCompiles(_ handle: DOM) async throws {
    try await handle.withEvents { events in
        _ = events
    }
}

private func cssStructuredEventSurfaceCompiles(_ handle: CSS) async throws {
    try await handle.withEvents { events in
        _ = events
    }
}

private func networkStructuredEventSurfaceCompiles(_ handle: Network) async throws {
    try await handle.withEvents { events in
        _ = events
    }
}

private func consoleStructuredEventSurfaceCompiles(_ handle: Console) async throws {
    try await handle.withEvents { events in
        _ = events
    }
}

private func runtimeStructuredEventSurfaceCompiles(_ handle: Runtime) async throws {
    try await handle.withEvents { events in
        _ = events
    }
}
