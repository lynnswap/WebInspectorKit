import Testing
import WebViewProxyKit
import WebViewProxyKitTesting

@Test
func webViewProxyPublicLifecycleAndCommandSurfaceWorksFromConsumerPackage() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    guard case .page = target.kind else {
        Issue.record("Expected WebViewProxyTestRuntime to install a page target.")
        return
    }
    #expect(await runtime.proxy.canReload)

    await runtime.backend.enqueue((), for: "Network", method: "enable")
    try await target.network.enable()

    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "Network", method: "enable")))
    #expect(commands.first?.targetID == target.id)

    await runtime.proxy.close()
    try await runtime.proxy.waitUntilClosed()
    #expect(await runtime.proxy.canReload == false)
}

@Test
func webViewProxyNetworkEventsMulticastToConsumerSubscribers() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
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
            id: WebViewProxyTestFixtures.networkRequestID("contract-multicast-request"),
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

    let expectedID = WebViewProxyTestFixtures.networkRequestID("contract-multicast-request")
    #expect(firstID == expectedID)
    #expect(secondID == expectedID)
    #expect(firstResponse.status == 204)
    #expect(secondResponse.status == 204)
    #expect(firstType == .fetch)
    #expect(secondType == .fetch)
    #expect(firstTimestamp == 42)
    #expect(secondTimestamp == 42)
}
