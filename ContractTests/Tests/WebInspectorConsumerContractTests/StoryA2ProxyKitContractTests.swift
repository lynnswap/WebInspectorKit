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
func webInspectorProxyNetworkEventsMulticastToConsumerSubscribers() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let page = runtime.page

    let eventTask = Task {
        try await page.network.withEvents { firstEvents in
            try await page.network.withEvents { secondEvents in
                try await runtime.peer.emitTargetEvent(
                    targetID: "page-main",
                    method: "Network.responseReceived",
                    parameters: ContractTestSupport.jsonObject([
                        "requestId": "contract-multicast-request",
                        "response": [
                            "status": 204,
                            "mimeType": "application/json",
                        ],
                        "type": "Fetch",
                        "timestamp": 42,
                    ])
                )

                var firstIterator = firstEvents.makeAsyncIterator()
                var firstEvent: Network.Event?
                while firstEvent == nil, let pageEvent = try await firstIterator.next() {
                    if case let .event(_, event) = pageEvent {
                        firstEvent = event
                    }
                }

                var secondIterator = secondEvents.makeAsyncIterator()
                var secondEvent: Network.Event?
                while secondEvent == nil, let pageEvent = try await secondIterator.next() {
                    if case let .event(_, event) = pageEvent {
                        secondEvent = event
                    }
                }
                return (firstEvent, secondEvent)
            }
        }
    }

    var command = try await runtime.peer.commands.next()
    #expect(command.destination == .target("page-main"))
    #expect(command.method == "Network.enable")
    try await runtime.peer.reply(to: command)

    command = try await runtime.peer.commands.next()
    #expect(command.destination == .target("page-main"))
    #expect(command.method == "Network.disable")
    try await runtime.peer.reply(to: command)

    let (firstValue, secondValue) = try await eventTask.value
    let firstEvent = try #require(firstValue)
    let secondEvent = try #require(secondValue)

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
    await runtime.close()
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
