import Testing
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

@Test
func rawPeerDispatchesDOMDocumentCommandThroughProductionTargetRoute() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    let operation = Task {
        try await target.dom.getDocument()
    }
    let command = try await runtime.peer.commands.next()
    #expect(command.destination == .target("page-main"))
    #expect(command.method == "DOM.getDocument")
    #expect(command.parameters == .empty)
    try await runtime.peer.reply(
        to: command,
        with: try jsonObject(
            ##"{"root":{"nodeId":"document","nodeType":9,"nodeName":"#document","localName":"","nodeValue":"","childNodeCount":0}}"##
        )
    )

    let node = try await operation.value
    #expect(node.id == DOM.Node.ID("document"))
    await runtime.close()
}

@Test
func rawPeerRoutesFrameRequestNodeThroughCurrentPageDOMAgent() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    try await runtime.peer.createTarget(.init(
        id: "frame-target",
        type: "frame",
        frameID: "child-frame",
        parentFrameID: "main-frame"
    ))
    let frame = runtime.proxy.frameTarget(id: WebInspectorTarget.ID("frame-target"))

    let operation = Task {
        try await frame.dom.requestNode(
            forRemoteObject: Runtime.RemoteObject.ID("remote-node")
        )
    }
    let command = try await runtime.peer.commands.next()
    #expect(command.destination == .target("page-main"))
    #expect(command.method == "DOM.requestNode")
    let parameters = try command.parameters.decode(RequestNodeParameters.self)
    #expect(parameters.objectId == "remote-node")
    try await runtime.peer.reply(
        to: command,
        with: try jsonObject(#"{"nodeId":"selected-node"}"#)
    )

    #expect(try await operation.value == DOM.Node.ID("selected-node"))
    await runtime.close()
}

@Test
func rawInspectorEventResolvesNodeThroughProductionCommandPath() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let eventTask = Task {
        var iterator = target.dom.events.makeAsyncIterator()
        return await iterator.next()
    }
    await runtime.proxy.waitForEventSubscription(
        targetID: target.id,
        route: target.route,
        domain: .dom
    )
    await runtime.proxy.waitForEventSubscription(
        targetID: target.id,
        route: target.route,
        domain: .inspector
    )

    try await runtime.peer.emitTargetEvent(
        targetID: "page-main",
        method: "Inspector.inspect",
        parameters: try jsonObject(
            #"{"object":{"type":"object","subtype":"node","objectId":"remote-node"},"hints":{}}"#
        )
    )

    let command = try await runtime.peer.commands.next()
    #expect(command.destination == .target("page-main"))
    #expect(command.method == "DOM.requestNode")
    #expect(try command.parameters.decode(RequestNodeParameters.self).objectId == "remote-node")
    try await runtime.peer.reply(
        to: command,
        with: try jsonObject(#"{"nodeId":"selected-node"}"#)
    )

    let event = try #require(await eventTask.value)
    guard case let .inspect(nodeID) = event else {
        Issue.record("Expected Inspector.inspect to resolve to DOM.inspect.")
        await runtime.close()
        return
    }
    #expect(nodeID == DOM.Node.ID("selected-node"))
    await runtime.close()
}

@Test
func rawFrameNetworkEventIsScopedOnSemanticCurrentPageRoute() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let page = try await runtime.proxy.waitForCurrentPage()
    try await runtime.peer.createTarget(.init(
        id: "frame-target",
        type: "frame",
        frameID: "child-frame",
        parentFrameID: "main-frame"
    ))
    let eventTask = Task {
        var iterator = page.network.events.makeAsyncIterator()
        return await iterator.next()
    }
    await runtime.proxy.waitForEventSubscription(
        targetID: page.id,
        route: page.route,
        domain: .network
    )
    try await runtime.peer.emitTargetEvent(
        targetID: "frame-target",
        method: "Network.responseReceived",
        parameters: try responseReceivedParameters(
            requestID: "frame-request",
            status: 201,
            resourceType: "XHR",
            timestamp: 2
        )
    )

    guard case let .responseReceived(frameID, _, _, _) = try #require(await eventTask.value) else {
        Issue.record("Expected Network.responseReceived events.")
        await runtime.close()
        return
    }
    #expect(frameID == Network.Request.ID(
        "frame-request",
        scopedToTargetRawValue: "frame-target"
    ))
    await runtime.close()
}

@Test(arguments: ["Network", "Console", "Runtime", "CSS"])
func rawPeerDispatchesDomainEnableAndDisable(_ domain: String) async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    let enableTask = Task {
        switch domain {
        case "Network": try await target.network.enable()
        case "Console": try await target.console.enable()
        case "Runtime": try await target.runtime.enable()
        case "CSS": try await target.css.enable()
        default: preconditionFailure("Unexpected test domain.")
        }
    }
    let enable = try await runtime.peer.commands.next()
    #expect(enable.destination == .target("page-main"))
    #expect(enable.method == "\(domain).enable")
    try await runtime.peer.reply(to: enable)
    try await enableTask.value

    let disableTask = Task {
        switch domain {
        case "Network": try await target.network.disable()
        case "Console": try await target.console.disable()
        case "Runtime": try await target.runtime.disable()
        case "CSS": try await target.css.disable()
        default: preconditionFailure("Unexpected test domain.")
        }
    }
    let disable = try await runtime.peer.commands.next()
    #expect(disable.destination == .target("page-main"))
    #expect(disable.method == "\(domain).disable")
    try await runtime.peer.reply(to: disable)
    try await disableTask.value
    await runtime.close()
}

@Test
func rawPeerPreservesScopedCSSRoutingAndStripsWireIdentifierScope() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let page = try await runtime.proxy.waitForCurrentPage()
    try await runtime.peer.createTarget(.init(
        id: "frame-target",
        type: "frame",
        frameID: "child-frame",
        parentFrameID: "main-frame"
    ))
    let styleSheetID = CSS.StyleSheet.ID(
        "frame-sheet",
        scopedToTargetRawValue: "frame-target"
    )

    let operation = Task {
        try await page.css.setStyleSheetText(
            styleSheetID,
            text: "body { color: red; }"
        )
    }
    let command = try await runtime.peer.commands.next()
    #expect(command.destination == .target("frame-target"))
    #expect(command.method == "CSS.setStyleSheetText")
    let parameters = try command.parameters.decode(SetStyleSheetTextParameters.self)
    #expect(parameters.styleSheetId == "frame-sheet")
    #expect(parameters.text == "body { color: red; }")
    try await runtime.peer.reply(to: command)
    try await operation.value
    await runtime.close()
}

@Test
func rawPeerPreservesScopedRuntimeRoutingAndStripsWireIdentifierScope() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let page = try await runtime.proxy.waitForCurrentPage()
    try await runtime.peer.createTarget(.init(
        id: "frame-target",
        type: "frame",
        frameID: "child-frame",
        parentFrameID: "main-frame"
    ))
    let contextID = Runtime.ExecutionContext.ID(
        "frame-context",
        scopedToTargetRawValue: "frame-target"
    )

    let operation = Task {
        try await page.runtime.evaluate("window", in: contextID)
    }
    let command = try await runtime.peer.commands.next()
    #expect(command.destination == .target("frame-target"))
    #expect(command.method == "Runtime.evaluate")
    let parameters = try command.parameters.decode(EvaluateParameters.self)
    #expect(parameters.expression == "window")
    #expect(parameters.contextId == "frame-context")
    try await runtime.peer.reply(
        to: command,
        with: try jsonObject(
            #"{"result":{"type":"object","objectId":"frame-object"}}"#
        )
    )

    let result = try await operation.value
    #expect(result.object.id == Runtime.RemoteObject.ID(
        "frame-object",
        scopedToTargetRawValue: "frame-target"
    ))
    await runtime.close()
}

private struct RequestNodeParameters: Decodable, Sendable {
    let objectId: String
}

private struct SetStyleSheetTextParameters: Decodable, Sendable {
    let styleSheetId: String
    let text: String
}

private struct EvaluateParameters: Decodable, Sendable {
    let expression: String
    let contextId: String
}

private func jsonObject(_ json: String) throws -> WebInspectorTestJSONObject {
    try WebInspectorTestJSONObject(json: json)
}

private func responseReceivedParameters(
    requestID: String,
    status: Int,
    resourceType: String,
    timestamp: Double
) throws -> WebInspectorTestJSONObject {
    try jsonObject(
        """
        {
          "requestId": "\(requestID)",
          "response": {"status": \(status)},
          "type": "\(resourceType)",
          "timestamp": \(timestamp)
        }
        """
    )
}
