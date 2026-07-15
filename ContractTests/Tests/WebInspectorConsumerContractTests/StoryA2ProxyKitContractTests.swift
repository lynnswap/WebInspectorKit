import Foundation
import Testing
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

@Test
func testJSONObjectPublicInitializersValidateAndCanonicalizeTypedFixtures() throws {
    struct Fixture: Codable, Equatable {
        let name: String
        let count: Int
    }

    let fixture = Fixture(name: "contract", count: 2)
    let encoded = try WebInspectorTestJSONObject(encoding: fixture)
    let fromData = try WebInspectorTestJSONObject(
        data: Data(#"{"count":2,"name":"contract"}"#.utf8)
    )

    #expect(encoded == fromData)
    #expect(try encoded.decode(Fixture.self) == fixture)
    #expect(throws: WebInspectorTestPeerError.invalidJSONObject) {
        try WebInspectorTestJSONObject(data: Data("[]".utf8))
    }
    #expect(throws: WebInspectorTestPeerError.invalidJSONObject) {
        try WebInspectorTestJSONObject(encoding: [1, 2])
    }
}

@Test
func webInspectorProxyPublicLifecycleAndCommandSurfaceWorksFromConsumerPackage() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let page = runtime.page
    let currentPageDOM: DOM = page.dom
    let currentPageCSS: CSS = page.css
    let currentPageNetwork: Network = page.network
    let currentPageConsole: Console = page.console
    let currentPageRuntime: Runtime = page.runtime
    let currentPageCommands: Page = page.page
    _ = (
        currentPageDOM,
        currentPageCSS,
        currentPageNetwork,
        currentPageConsole,
        currentPageRuntime,
        currentPageCommands
    )

    let reloadTask = Task {
        try await currentPageCommands.reload()
    }
    let command = try await runtime.peer.commands.next()
    #expect(command.destination == .target("page-main"))
    #expect(command.method == "Page.reload")
    try await runtime.peer.reply(to: command)
    try await reloadTask.value

    await runtime.proxy.close()
    try await runtime.proxy.waitUntilClosed()
}

@Test
func webInspectorProxyNetworkEventsReachConsumerScope() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let page = runtime.page
    let readiness = AsyncStream<Void>.makeStream()

    let eventTask = Task {
        try await page.network.withEvents { events in
            var iterator = events.makeAsyncIterator()
            readiness.continuation.yield()
            while let pageEvent = try await iterator.next() {
                if case let .event(_, event) = pageEvent {
                    return event
                }
            }
            throw ContractEventStreamEnded()
        }
    }

    let command = try await runtime.peer.commands.next()
    #expect(command.destination == .target("page-main"))
    #expect(command.method == "Network.enable")
    try await runtime.peer.reply(to: command)

    var readinessIterator = readiness.stream.makeAsyncIterator()
    _ = await readinessIterator.next()
    try await runtime.peer.emitTargetEvent(
        targetID: "page-main",
        method: "Network.dataReceived",
        parameters: ContractTestSupport.jsonObject([
            "requestId": "contract-scope-request",
            "dataLength": 4,
            "encodedDataLength": 3,
            "timestamp": 42,
        ])
    )

    let event = try await eventTask.value

    guard case let .dataReceived(id, dataLength, encodedDataLength, timestamp) = event else {
        Issue.record("Expected the consumer scope to receive Network.dataReceived.")
        return
    }

    let expectedID = WebInspectorProxyTestFixtures.networkRequestID(
        "contract-scope-request"
    )
    #expect(id == expectedID)
    #expect(dataLength == 4)
    #expect(encodedDataLength == 3)
    #expect(timestamp == 42)
    await runtime.close()
}

private struct ContractEventStreamEnded: Error {}

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
