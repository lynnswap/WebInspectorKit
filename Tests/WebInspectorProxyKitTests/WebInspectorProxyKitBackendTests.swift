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
func rawElementPickerResolvesInspectorEventThroughProductionCommandPath() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let eventTask = Task {
        try await runtime.page.dom.withElementPicker { events in
            for try await event in events {
                guard case let .event(_, nodeID) = event else {
                    continue
                }
                return nodeID
            }
            throw WebInspectorProxyError.closed
        }
    }

    var command = try await runtime.peer.commands.next()
    #expect(command.method == "Inspector.enable")
    try await runtime.peer.reply(to: command)
    command = try await runtime.peer.commands.next()
    #expect(command.method == "Inspector.initialized")
    try await runtime.peer.reply(to: command)
    command = try await runtime.peer.commands.next()
    #expect(command.method == "DOM.setInspectModeEnabled")
    try await runtime.peer.reply(to: command)

    try await runtime.peer.emitTargetEvent(
        targetID: "page-main",
        method: "Inspector.inspect",
        parameters: try jsonObject(
            #"{"object":{"type":"object","subtype":"node","objectId":"remote-node"},"hints":{}}"#
        )
    )

    command = try await runtime.peer.commands.next()
    #expect(command.destination == .target("page-main"))
    #expect(command.method == "DOM.requestNode")
    #expect(try command.parameters.decode(RequestNodeParameters.self).objectId == "remote-node")
    try await runtime.peer.reply(
        to: command,
        with: try jsonObject(#"{"nodeId":"selected-node"}"#)
    )

    command = try await runtime.peer.commands.next()
    #expect(command.method == "DOM.setInspectModeEnabled")
    try await runtime.peer.reply(to: command)
    command = try await runtime.peer.commands.next()
    #expect(command.method == "Inspector.disable")
    try await runtime.peer.reply(to: command)

    #expect(try await eventTask.value == DOM.Node.ID("selected-node"))
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
