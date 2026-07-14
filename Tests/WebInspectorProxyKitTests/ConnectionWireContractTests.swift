import Foundation
import Testing
import WebInspectorProxyKitTesting
@testable import WebInspectorProxyKit

private enum CompositeEvent: Sendable {
    case page(WebInspectorRoutedEvent<Page.Event>)
    case network(WebInspectorRoutedEvent<Network.Event>)
}

@Test
func compositeScopePreservesPageNetworkFIFOAndReplyBoundary() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    defer { Task { await runtime.close() } }

    let scopeTask = Task {
        try await runtime.page.orderedScope(
            descriptor: WebInspectorOrderedScopeDescriptor(
                decoders: [
                    PageWireCoding.eventDecoder.routed().map(CompositeEvent.page),
                    NetworkWireCoding.eventDecoder.routed().map(CompositeEvent.network),
                ],
                capabilities: [PageWireCoding.capability, NetworkWireCoding.capability]
            ),
            buffering: .bounded(16)
        )
    }
    try await replyNext(runtime.peer, method: "Page.enable")
    try await replyNext(runtime.peer, method: "Network.enable")
    let scope = try await scopeTask.value

    let bootstrapTask = Task { try await scope.command(DOMWireCoding.getDocument()) }
    let bootstrapCommand = try await runtime.peer.commands.next()
    #expect(bootstrapCommand.method == "DOM.getDocument")

    try await runtime.peer.emitTargetEvent(
        targetID: "page-main",
        method: "Page.frameNavigated",
        parameters: try WebInspectorTestJSONObject(json: pageFrameParameters)
    )
    try await runtime.peer.emitTargetEvent(
        targetID: "page-main",
        method: "Network.dataReceived",
        parameters: try WebInspectorTestJSONObject(json: networkDataParameters(id: "request-before"))
    )
    try await runtime.peer.reply(
        to: bootstrapCommand,
        with: try WebInspectorTestJSONObject(json: domDocumentResult)
    )
    let bootstrap = try await bootstrapTask.value

    #expect(bootstrap.generation.rawValue == 1)
    #expect(bootstrap.semanticTarget?.id == .currentPage)
    #expect(bootstrap.semanticTarget?.kind == .page)
    #expect(bootstrap.semanticTarget?.frameID?.rawValue == "main-frame")
    #expect(bootstrap.agentTarget?.id.rawValue == "page-main")

    try await runtime.peer.emitTargetEvent(
        targetID: "page-main",
        method: "Network.dataReceived",
        parameters: try WebInspectorTestJSONObject(json: networkDataParameters(id: "request-after"))
    )

    let prefix = try await scope.drain(through: bootstrap.boundary)
    let routed = prefix.compactMap { record -> WebInspectorEventSequence? in
        guard case let .event(_, event) = record else { return nil }
        switch event {
        case let .page(value):
            #expect(value.semanticTarget?.id == .currentPage)
            #expect(value.agentTarget?.id.rawValue == "page-main")
            return value.sequence
        case let .network(value):
            return value.sequence
        }
    }
    #expect(routed.count == 2)
    #expect(routed[0] < routed[1])

    var iterator = scope.events.makeAsyncIterator()
    let postBoundary = try await iterator.next()
    guard case let .event(_, .network(event)) = postBoundary,
          case let .dataReceived(id, _, _, _) = event.value else {
        Issue.record("Expected the post-boundary Network event.")
        await closeCompositeScope(scope, peer: runtime.peer)
        return
    }
    #expect(id.unscopedRawValue == "request-after")

    await closeCompositeScope(scope, peer: runtime.peer)
}

@Test
func malformedKnownDomainEventTerminatesOnlyItsScope() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    defer { Task { await runtime.close() } }
    let scope = try await runtime.page.orderedScope(
        descriptor: WebInspectorOrderedScopeDescriptor(
            decoders: [DOMWireCoding.eventDecoder],
            capabilities: [DOMWireCoding.capability]
        ),
        buffering: .bounded(4)
    )
    var iterator = scope.events.makeAsyncIterator()
    _ = try await iterator.next()

    try await runtime.peer.emitTargetEvent(
        targetID: "page-main",
        method: "DOM.childNodeInserted",
        parameters: try WebInspectorTestJSONObject(json: #"{"parentNodeId":"1"}"#)
    )
    await #expect(throws: WebInspectorEventDecodingError.self) {
        _ = try await iterator.next()
    }

    let documentTask = Task { try await runtime.page.dom.getDocument() }
    let command = try await runtime.peer.commands.next()
    #expect(command.method == "DOM.getDocument")
    try await runtime.peer.reply(
        to: command,
        with: try WebInspectorTestJSONObject(json: domDocumentResult)
    )
    #expect(try await documentTask.value.id.unscopedRawValue == "1")
    await scope.close()
}

@Test
func networkOverflowStopsDeliveryButRetainsThePhysicalLease() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    defer { Task { await runtime.close() } }

    let firstTask = Task { try await openNetworkScope(on: runtime.page, capacity: 1) }
    try await replyNext(runtime.peer, method: "Network.enable")
    let first = try await firstTask.value

    try await runtime.peer.emitTargetEvent(
        targetID: "page-main",
        method: "Network.dataReceived",
        parameters: try WebInspectorTestJSONObject(json: networkDataParameters(id: "one"))
    )
    try await runtime.peer.emitTargetEvent(
        targetID: "page-main",
        method: "Network.dataReceived",
        parameters: try WebInspectorTestJSONObject(json: networkDataParameters(id: "two"))
    )

    var iterator = first.events.makeAsyncIterator()
    _ = try await iterator.next()
    _ = try await iterator.next()
    await #expect(throws: WebInspectorProxyError.self) {
        _ = try await iterator.next()
    }

    let replacement = try await openNetworkScope(on: runtime.page, capacity: 2)
    await first.close()
    await replacement.close()
}

@Test
func capabilityLeasesCoalesceEnableAndDisableAtLastRelease() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    defer { Task { await runtime.close() } }

    let firstTask = Task { try await openConsoleScope(on: runtime.page) }
    try await replyNext(runtime.peer, method: "Console.enable")
    let first = try await firstTask.value
    let second = try await openConsoleScope(on: runtime.page)

    await first.close()
    let finalClose = Task { await second.close() }
    try await replyNext(runtime.peer, method: "Console.disable")
    await finalClose.value
}

@Test
func descendantWorkerIsEnrolledAndEnabledAfterScopeRegistration() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    defer { Task { await runtime.close() } }

    let scope = try await runtime.page.orderedScope(
        descriptor: WebInspectorOrderedScopeDescriptor(
            selection: .descendants(of: .currentPage, kinds: [.worker]),
            decoders: [RuntimeWireCoding.eventDecoder.routed()],
            capabilities: [RuntimeWireCoding.capability]
        ),
        buffering: .bounded(4)
    )
    try await runtime.peer.createTarget(.init(
        id: "worker-one",
        type: "worker",
        frameID: "main-frame"
    ))
    try await replyNext(runtime.peer, method: "Runtime.enable", destination: .target("worker-one"))

    try await runtime.peer.emitTargetEvent(
        targetID: "worker-one",
        method: "Runtime.executionContextCreated",
        parameters: try WebInspectorTestJSONObject(json: #"{"context":{"id":9,"name":"worker","type":"normal"}}"#)
    )
    var iterator = scope.events.makeAsyncIterator()
    _ = try await iterator.next()
    guard case let .event(_, routed) = try await iterator.next() else {
        Issue.record("Expected a worker Runtime event.")
        return
    }
    #expect(routed.semanticTarget?.id == .currentPage)
    #expect(routed.agentTarget?.id.rawValue == "worker-one")
    #expect(routed.agentTarget?.kind == .worker)

    let closeTask = Task { await scope.close() }
    try await replyNext(runtime.peer, method: "Runtime.disable", destination: .target("worker-one"))
    await closeTask.value
}

@Test
func malformedTargetControlPlaneTerminatesThePhysicalConnection() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    do {
        try await runtime.peer.emitRootEvent(
            method: "Target.targetCreated",
            parameters: try WebInspectorTestJSONObject(json: #"{"targetInfo":"malformed"}"#)
        )
    } catch WebInspectorTestPeerError.connectionClosed {
        // The peer observes the same physical terminal chosen by ConnectionCore.
    }

    await #expect(throws: WebInspectorProxyError.self) {
        try await runtime.proxy.waitUntilClosed()
    }
}

@Test
func pageResourceCommandsUseTypedWireCodecs() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    defer { Task { await runtime.close() } }

    let treeTask = Task { try await runtime.page.page.resourceTree() }
    let treeCommand = try await runtime.peer.commands.next()
    #expect(treeCommand.method == "Page.getResourceTree")
    try await runtime.peer.reply(
        to: treeCommand,
        with: try WebInspectorTestJSONObject(json: resourceTreeResult)
    )
    let tree = try await treeTask.value
    #expect(tree.frame.id.rawValue == "main-frame")
    #expect(tree.resources.first?.url == "https://example.test/app.js")

    let contentTask = Task {
        try await runtime.page.page.resourceContent(
            frameID: FrameID("main-frame"),
            url: "https://example.test/app.js"
        )
    }
    let contentCommand = try await runtime.peer.commands.next()
    #expect(contentCommand.method == "Page.getResourceContent")
    try await runtime.peer.reply(
        to: contentCommand,
        with: try WebInspectorTestJSONObject(json: #"{"content":"Y29uc29sZS5sb2coMSk=","base64Encoded":true}"#)
    )
    let content = try await contentTask.value
    #expect(content.base64Encoded)
    #expect(content.content == "Y29uc29sZS5sb2coMSk=")
}

private func openNetworkScope(
    on page: WebInspectorPage,
    capacity: Int
) async throws -> WebInspectorOrderedEventScope<Network.Event> {
    try await page.orderedScope(
        descriptor: WebInspectorOrderedScopeDescriptor(
            decoders: [NetworkWireCoding.eventDecoder],
            capabilities: [NetworkWireCoding.capability]
        ),
        buffering: .bounded(capacity)
    )
}

private func openConsoleScope(
    on page: WebInspectorPage
) async throws -> WebInspectorOrderedEventScope<Console.Event> {
    try await page.orderedScope(
        descriptor: WebInspectorOrderedScopeDescriptor(
            decoders: [ConsoleWireCoding.eventDecoder],
            capabilities: [ConsoleWireCoding.capability]
        ),
        buffering: .bounded(4)
    )
}

private func closeCompositeScope(
    _ scope: WebInspectorOrderedEventScope<CompositeEvent>,
    peer: WebInspectorTestPeer
) async {
    let closeTask = Task { await scope.close() }
    do { try await replyNext(peer, method: "Page.disable") }
    catch { Issue.record("Failed to release Page capability: \(error)") }
    await closeTask.value
}

private func replyNext(
    _ peer: WebInspectorTestPeer,
    method: String,
    destination: WebInspectorTestPeer.Command.Destination? = nil
) async throws {
    let command = try await peer.commands.next()
    #expect(command.method == method)
    if let destination { #expect(command.destination == destination) }
    try await peer.reply(to: command)
}

private let pageFrameParameters = #"""
{
    "frame": {
        "id": "main-frame",
        "loaderId": "loader-one",
        "name": "",
        "url": "https://example.test/",
        "securityOrigin": "https://example.test",
        "mimeType": "text/html"
    }
}
"""#

private func networkDataParameters(id: String) -> String {
    #"{"requestId":"\#(id)","dataLength":4,"encodedDataLength":3,"timestamp":1.5}"#
}

private let domDocumentResult = #"""
{
    "root": {
        "nodeId": 1,
        "nodeType": 9,
        "nodeName": "#document",
        "localName": "",
        "nodeValue": "",
        "frameId": "main-frame",
        "childNodeCount": 0
    }
}
"""#

private let resourceTreeResult = #"""
{
    "frameTree": {
        "frame": {
            "id": "main-frame",
            "loaderId": "loader-one",
            "name": "",
            "url": "https://example.test/",
            "securityOrigin": "https://example.test",
            "mimeType": "text/html"
        },
        "resources": [{
            "url": "https://example.test/app.js",
            "type": "Script",
            "mimeType": "text/javascript"
        }]
    }
}
"""#
