import Foundation
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

private struct RawWireEvent {
    let method: String
    let parameters: WebInspectorTestJSONObject
}

enum RawWireFixtureError: Error, Equatable {
    case missingRequiredField(method: String, field: String)
}

extension DataKitRawWireDriver {
    func emitRaw(_ event: DOM.Event, target: WebInspectorTarget) async throws {
        try await emit(rawDOMEvent(event), targetID: wireTargetID(target))
    }

    func emitRaw(_ event: DOM.Event, target: WebInspectorTarget.ID) async throws {
        try await emit(rawDOMEvent(event), targetID: target.rawValue)
    }

    func emitRaw(_ event: CSS.Event, target: WebInspectorTarget) async throws {
        try await emit(rawCSSEvent(event), targetID: wireTargetID(target))
    }

    func emitRaw(_ event: CSS.Event, target: WebInspectorTarget.ID) async throws {
        try await emit(rawCSSEvent(event), targetID: target.rawValue)
    }

    func emitRaw(_ event: Network.Event, target: WebInspectorTarget) async throws {
        try await emit(rawNetworkEvent(event), targetID: wireTargetID(target))
    }

    func emitRaw(_ event: Network.Event, target: WebInspectorTarget.ID) async throws {
        try await emit(rawNetworkEvent(event), targetID: target.rawValue)
    }

    func emitRaw(_ event: Console.Event, target: WebInspectorTarget) async throws {
        try await emit(rawConsoleEvent(event), targetID: wireTargetID(target))
    }

    func emitRaw(_ event: Console.Event, target: WebInspectorTarget.ID) async throws {
        try await emit(rawConsoleEvent(event), targetID: target.rawValue)
    }

    func emitRaw(_ event: Runtime.Event, target: WebInspectorTarget) async throws {
        try await emit(rawRuntimeEvent(event), targetID: wireTargetID(target))
    }

    func emitRaw(_ event: Runtime.Event, target: WebInspectorTarget.ID) async throws {
        try await emit(rawRuntimeEvent(event), targetID: target.rawValue)
    }

    func emitRaw(
        _ event: WebInspectorTargetLifecycleEvent,
        target: WebInspectorTarget
    ) async throws {
        try await emitLifecycle(event, targetID: wireTargetID(target))
    }

    func emitRaw(
        _ event: WebInspectorTargetLifecycleEvent,
        target: WebInspectorTarget.ID
    ) async throws {
        try await emitLifecycle(event, targetID: target.rawValue)
    }

    private func emit(_ event: RawWireEvent, targetID: String) async throws {
        try await emitTargetEvent(
            targetID: targetID,
            method: event.method,
            parameters: event.parameters
        )
    }

    private func emitLifecycle(
        _ event: WebInspectorTargetLifecycleEvent,
        targetID: String
    ) async throws {
        switch event {
        case let .didCommitProvisionalTarget(commit):
            try await emitRootEvent(
                method: "Target.didCommitProvisionalTarget",
                parameters: try testJSONObject(TargetCommitWire(
                    oldTargetId: commit.oldTargetID?.rawValue ?? targetID,
                    newTargetId: commit.newTarget.id.rawValue
                ))
            )
        case let .targetDestroyed(destroyedTargetID):
            try await emitRootEvent(
                method: "Target.targetDestroyed",
                parameters: try testJSONObject(TargetDestroyedWire(
                    targetId: destroyedTargetID.rawValue
                ))
            )
        case let .frameNavigated(frame):
            try await emitTargetEvent(
                targetID: targetID,
                method: "Page.frameNavigated",
                parameters: try testJSONObject(PageFrameNavigatedWire(
                    frame: PageFrameWire(frame)
                ))
            )
        case let .frameDetached(frameID):
            try await emitTargetEvent(
                targetID: targetID,
                method: "Page.frameDetached",
                parameters: try testJSONObject(PageFrameDetachedWire(
                    frameId: frameID.rawValue
                ))
            )
        case let .unknown(event):
            try await emit(try rawUnknownEvent(event), targetID: targetID)
        }
    }
}

private func rawDOMEvent(_ event: DOM.Event) throws -> RawWireEvent {
    switch event {
    case .documentUpdated:
        return try rawEvent("DOM.documentUpdated", EmptyWireObject())
    case let .setChildNodes(parent, nodes):
        return try rawEvent(
            "DOM.setChildNodes",
            DOMSetChildNodesWire(parentId: parent.rawValue, nodes: nodes.map(DOMNodeWire.init))
        )
    case let .detachedRoot(node):
        return try rawEvent(
            "DOM.setChildNodes",
            DOMSetChildNodesWire(parentId: "0", nodes: [DOMNodeWire(node)])
        )
    case let .childNodeInserted(parent, previous, node):
        return try rawEvent(
            "DOM.childNodeInserted",
            DOMChildNodeInsertedWire(
                parentNodeId: parent.rawValue,
                previousNodeId: previous?.rawValue ?? "0",
                node: DOMNodeWire(node)
            )
        )
    case let .childNodeRemoved(parent, node):
        return try rawEvent(
            "DOM.childNodeRemoved",
            DOMChildNodeRemovedWire(parentNodeId: parent.rawValue, nodeId: node.rawValue)
        )
    case let .childNodeCountUpdated(node, count):
        return try rawEvent(
            "DOM.childNodeCountUpdated",
            DOMChildNodeCountUpdatedWire(nodeId: node.rawValue, childNodeCount: count)
        )
    case let .attributeModified(node, name, value):
        return try rawEvent(
            "DOM.attributeModified",
            DOMAttributeModifiedWire(nodeId: node.rawValue, name: name, value: value)
        )
    case let .attributeRemoved(node, name):
        return try rawEvent(
            "DOM.attributeRemoved",
            DOMAttributeRemovedWire(nodeId: node.rawValue, name: name)
        )
    case let .inlineStyleInvalidated(nodes):
        return try rawEvent(
            "DOM.inlineStyleInvalidated",
            DOMInlineStyleInvalidatedWire(nodeIds: nodes.map(\.rawValue))
        )
    case let .characterDataModified(node, value):
        return try rawEvent(
            "DOM.characterDataModified",
            DOMCharacterDataModifiedWire(nodeId: node.rawValue, characterData: value)
        )
    case let .shadowRootPushed(host, root):
        return try rawEvent(
            "DOM.shadowRootPushed",
            DOMShadowRootPushedWire(hostId: host.rawValue, root: DOMNodeWire(root))
        )
    case let .shadowRootPopped(host, root):
        return try rawEvent(
            "DOM.shadowRootPopped",
            DOMShadowRootPoppedWire(hostId: host.rawValue, rootId: root.rawValue)
        )
    case let .pseudoElementAdded(parent, element):
        return try rawEvent(
            "DOM.pseudoElementAdded",
            DOMPseudoElementAddedWire(parentId: parent.rawValue, pseudoElement: DOMNodeWire(element))
        )
    case let .pseudoElementRemoved(parent, element):
        return try rawEvent(
            "DOM.pseudoElementRemoved",
            DOMPseudoElementRemovedWire(parentId: parent.rawValue, pseudoElementId: element.rawValue)
        )
    case let .willDestroyDOMNode(node):
        return try rawEvent("DOM.willDestroyDOMNode", DOMNodeIDWire(nodeId: node.rawValue))
    case let .inspect(node):
        return try rawEvent("DOM.inspect", DOMNodeIDWire(nodeId: node.rawValue))
    case let .unknown(event):
        return try rawUnknownEvent(event)
    }
}

private func rawCSSEvent(_ event: CSS.Event) throws -> RawWireEvent {
    switch event {
    case let .styleSheetChanged(id):
        return try rawEvent("CSS.styleSheetChanged", CSSStyleSheetIDWire(styleSheetId: id.rawValue))
    case let .styleSheetAdded(header):
        return try rawEvent(
            "CSS.styleSheetAdded",
            CSSStyleSheetAddedWire(header: CSSStyleSheetHeaderWire(header))
        )
    case let .styleSheetRemoved(id):
        return try rawEvent("CSS.styleSheetRemoved", CSSStyleSheetIDWire(styleSheetId: id.rawValue))
    case .mediaQueryResultChanged:
        return try rawEvent("CSS.mediaQueryResultChanged", EmptyWireObject())
    case let .nodeLayoutFlagsChanged(node):
        return try rawEvent("CSS.nodeLayoutFlagsChanged", DOMNodeIDWire(nodeId: node.rawValue))
    case let .unknown(event):
        return try rawUnknownEvent(event)
    }
}

private func rawNetworkEvent(_ event: Network.Event) throws -> RawWireEvent {
    switch event {
    case let .requestWillBeSent(id, request, initiator, resourceType, redirectResponse, timestamp):
        return try rawEvent(
            "Network.requestWillBeSent",
            NetworkRequestWillBeSentWire(
                requestId: id.rawValue,
                frameId: request.origin?.frameID.rawValue ?? "main-frame",
                loaderId: request.origin?.loaderID ?? "main-loader",
                targetId: request.origin?.targetID,
                request: NetworkRequestWire(request),
                initiator: NetworkInitiatorWire(initiator),
                type: resourceType?.rawValue,
                redirectResponse: redirectResponse.map(NetworkResponseWire.init),
                timestamp: timestamp,
                backendResourceIdentifier: request.backendResourceIdentifier.map(NetworkBackendResourceWire.init)
            )
        )
    case let .responseReceived(id, response, resourceType, timestamp):
        return try rawEvent(
            "Network.responseReceived",
            NetworkResponseReceivedWire(
                requestId: id.rawValue,
                type: resourceType?.rawValue,
                response: NetworkResponseWire(response),
                timestamp: timestamp
            )
        )
    case let .dataReceived(id, dataLength, encodedDataLength, timestamp):
        return try rawEvent(
            "Network.dataReceived",
            NetworkDataReceivedWire(
                requestId: id.rawValue,
                dataLength: dataLength,
                encodedDataLength: encodedDataLength,
                timestamp: timestamp
            )
        )
    case let .loadingFinished(id, timestamp, sourceMapURL, metrics):
        return try rawEvent(
            "Network.loadingFinished",
            NetworkLoadingFinishedWire(
                requestId: id.rawValue,
                timestamp: timestamp,
                sourceMapURL: sourceMapURL,
                metrics: metrics.map(NetworkMetricsWire.init)
            )
        )
    case let .loadingFailed(id, errorText, cancelled, timestamp):
        return try rawEvent(
            "Network.loadingFailed",
            NetworkLoadingFailedWire(
                requestId: id.rawValue,
                timestamp: timestamp,
                errorText: errorText,
                canceled: cancelled
            )
        )
    case let .requestServedFromMemoryCache(id, response, initiator, resourceType, timestamp):
        guard let url = response.url else {
            throw RawWireFixtureError.missingRequiredField(
                method: "Network.requestServedFromMemoryCache",
                field: "resource.url"
            )
        }
        return try rawEvent(
            "Network.requestServedFromMemoryCache",
            NetworkMemoryCacheWire(
                requestId: id.rawValue,
                timestamp: timestamp,
                initiator: NetworkInitiatorWire(initiator),
                resource: NetworkCachedResourceWire(
                    url: url,
                    type: resourceType?.rawValue ?? Network.ResourceType.other.rawValue,
                    bodySize: response.bodySize,
                    response: NetworkResponseWire(response)
                )
            )
        )
    case let .webSocket(event):
        return try rawWebSocketEvent(event)
    case let .unknown(event):
        return try rawUnknownEvent(event)
    }
}

private func rawWebSocketEvent(_ event: Network.WebSocketEvent) throws -> RawWireEvent {
    switch event {
    case let .created(id, url):
        return try rawEvent(
            "Network.webSocketCreated",
            NetworkWebSocketCreatedWire(requestId: id.rawValue, url: url)
        )
    case let .handshakeRequest(id, request, timestamp):
        return try rawEvent(
            "Network.webSocketWillSendHandshakeRequest",
            NetworkWebSocketHandshakeRequestWire(
                requestId: id.rawValue,
                timestamp: timestamp,
                request: NetworkWebSocketRequestWire(headers: request.headers)
            )
        )
    case let .handshakeResponse(id, response, timestamp):
        return try rawEvent(
            "Network.webSocketHandshakeResponseReceived",
            NetworkWebSocketHandshakeResponseWire(
                requestId: id.rawValue,
                timestamp: timestamp,
                response: NetworkResponseWire(response)
            )
        )
    case let .closed(id, timestamp):
        return try rawEvent(
            "Network.webSocketClosed",
            NetworkWebSocketClosedWire(requestId: id.rawValue, timestamp: timestamp)
        )
    case let .frameSent(id, frame, timestamp):
        return try rawEvent(
            "Network.webSocketFrameSent",
            NetworkWebSocketFrameEventWire(
                requestId: id.rawValue,
                timestamp: timestamp,
                response: NetworkWebSocketFrameWire(frame)
            )
        )
    case let .frameReceived(id, frame, timestamp):
        return try rawEvent(
            "Network.webSocketFrameReceived",
            NetworkWebSocketFrameEventWire(
                requestId: id.rawValue,
                timestamp: timestamp,
                response: NetworkWebSocketFrameWire(frame)
            )
        )
    case let .error(id, message, timestamp):
        return try rawEvent(
            "Network.webSocketFrameError",
            NetworkWebSocketErrorWire(
                requestId: id.rawValue,
                timestamp: timestamp,
                errorMessage: message
            )
        )
    case let .other(event):
        return try rawUnknownEvent(event)
    }
}

private func rawConsoleEvent(_ event: Console.Event) throws -> RawWireEvent {
    switch event {
    case let .messageAdded(message):
        return try rawEvent(
            "Console.messageAdded",
            ConsoleMessageAddedWire(message: ConsoleMessageWire(message))
        )
    case let .messageRepeatCountUpdated(count, timestamp):
        return try rawEvent(
            "Console.messageRepeatCountUpdated",
            ConsoleRepeatCountWire(count: count, timestamp: timestamp)
        )
    case let .messagesCleared(reason):
        return try rawEvent("Console.messagesCleared", ConsoleMessagesClearedWire(reason: reason.rawValue))
    case let .unknown(event):
        return try rawUnknownEvent(event)
    }
}

private func rawRuntimeEvent(_ event: Runtime.Event) throws -> RawWireEvent {
    switch event {
    case let .executionContextCreated(context):
        return try rawEvent(
            "Runtime.executionContextCreated",
            RuntimeContextCreatedWire(context: RuntimeExecutionContextWire(context))
        )
    case let .executionContextDestroyed(id):
        return try rawEvent(
            "Runtime.executionContextDestroyed",
            RuntimeContextDestroyedWire(executionContextId: id.rawValue)
        )
    case .executionContextsCleared:
        return try rawEvent("Runtime.executionContextsCleared", EmptyWireObject())
    case let .unknown(event):
        return try rawUnknownEvent(event)
    }
}

private func rawEvent(_ method: String, _ parameters: some Encodable) throws -> RawWireEvent {
    RawWireEvent(method: method, parameters: try testJSONObject(parameters))
}

private func rawUnknownEvent(_ event: RawEvent) throws -> RawWireEvent {
    let method = event.method.contains(".") ? event.method : "\(event.domain).\(event.method)"
    let parameters: WebInspectorTestJSONObject
    if event.params.isEmpty {
        parameters = .empty
    } else {
        guard let json = String(data: event.params, encoding: .utf8) else {
            throw WebInspectorTestPeerError.invalidJSONObject
        }
        parameters = try WebInspectorTestJSONObject(json: json)
    }
    return RawWireEvent(method: method, parameters: parameters)
}

private struct EmptyWireObject: Encodable {}

private struct TargetCommitWire: Encodable {
    let oldTargetId: String
    let newTargetId: String
}

private struct TargetDestroyedWire: Encodable {
    let targetId: String
}

private struct PageFrameNavigatedWire: Encodable {
    let frame: PageFrameWire
}

private struct PageFrameDetachedWire: Encodable {
    let frameId: String
}

private struct PageFrameWire: Encodable {
    let id: String
    let parentId: String?
    let loaderId: String?
    let name: String?
    let url: String
    let securityOrigin: String?
    let mimeType: String?

    init(_ frame: WebInspectorPageFrameLifecycle) {
        id = frame.id.rawValue
        parentId = frame.parentID?.rawValue
        loaderId = frame.loaderID
        name = frame.name
        url = frame.url
        securityOrigin = frame.securityOrigin
        mimeType = frame.mimeType
    }
}

private struct DOMSetChildNodesWire: Encodable {
    let parentId: String
    let nodes: [DOMNodeWire]
}

private struct DOMChildNodeInsertedWire: Encodable {
    let parentNodeId: String
    let previousNodeId: String
    let node: DOMNodeWire
}

private struct DOMChildNodeRemovedWire: Encodable {
    let parentNodeId: String
    let nodeId: String
}

private struct DOMChildNodeCountUpdatedWire: Encodable {
    let nodeId: String
    let childNodeCount: Int
}

private struct DOMAttributeModifiedWire: Encodable {
    let nodeId: String
    let name: String
    let value: String
}

private struct DOMAttributeRemovedWire: Encodable {
    let nodeId: String
    let name: String
}

private struct DOMInlineStyleInvalidatedWire: Encodable {
    let nodeIds: [String]
}

private struct DOMCharacterDataModifiedWire: Encodable {
    let nodeId: String
    let characterData: String
}

private struct DOMShadowRootPushedWire: Encodable {
    let hostId: String
    let root: DOMNodeWire
}

private struct DOMShadowRootPoppedWire: Encodable {
    let hostId: String
    let rootId: String
}

private struct DOMPseudoElementAddedWire: Encodable {
    let parentId: String
    let pseudoElement: DOMNodeWire
}

private struct DOMPseudoElementRemovedWire: Encodable {
    let parentId: String
    let pseudoElementId: String
}

private struct DOMNodeIDWire: Encodable {
    let nodeId: String
}

private struct CSSStyleSheetIDWire: Encodable {
    let styleSheetId: String
}

private struct CSSStyleSheetAddedWire: Encodable {
    let header: CSSStyleSheetHeaderWire
}

private struct CSSStyleSheetHeaderWire: Encodable {
    let styleSheetId: String
    let frameId: String?
    let sourceURL: String?
    let origin: String
    let title: String?
    let disabled: Bool
    let isInline: Bool
    let startLine: Int
    let startColumn: Int

    init(_ header: CSS.StyleSheetHeader) {
        styleSheetId = header.styleSheetID.rawValue
        frameId = header.frameID?.rawValue
        sourceURL = header.sourceURL
        origin = header.origin.rawValue
        title = header.title
        disabled = header.disabled
        isInline = header.isInline
        startLine = header.startLine
        startColumn = header.startColumn
    }
}

private struct NetworkRequestWillBeSentWire: Encodable {
    let requestId: String
    let frameId: String
    let loaderId: String
    let targetId: String?
    let request: NetworkRequestWire
    let initiator: NetworkInitiatorWire
    let type: String?
    let redirectResponse: NetworkResponseWire?
    let timestamp: Double
    let backendResourceIdentifier: NetworkBackendResourceWire?
}

private struct NetworkInitiatorWire: Encodable {
    let type: String
    let url: String?
    let lineNumber: Int?
    let nodeId: String?

    init(_ initiator: Network.Initiator) {
        type = initiator.kind
        url = initiator.url
        lineNumber = initiator.line
        nodeId = initiator.nodeID?.rawValue
    }
}

private struct NetworkRequestWire: Encodable {
    let url: String
    let method: String
    let headers: [String: String]
    let postData: String?
    let referrerPolicy: String?
    let integrity: String?

    init(_ request: Network.Request) {
        url = request.url
        method = request.method
        headers = request.headers
        postData = request.postData
        referrerPolicy = request.referrerPolicy?.rawValue
        integrity = request.integrity
    }
}

private struct NetworkBackendResourceWire: Encodable {
    let sourceProcessID: String
    let resourceID: String

    init(_ identifier: Network.BackendResourceID) {
        sourceProcessID = identifier.sourceProcessID
        resourceID = identifier.resourceID
    }
}

private struct NetworkResponseWire: Encodable {
    let url: String?
    let status: Int?
    let statusText: String?
    let headers: [String: String]
    let mimeType: String?
    let source: String?
    let requestHeaders: [String: String]?

    init(_ response: Network.Response) {
        url = response.url
        status = response.status
        statusText = response.statusText
        headers = response.headers
        mimeType = response.mimeType
        source = response.source?.rawValue
        requestHeaders = response.requestHeaders
    }
}

private struct NetworkResponseReceivedWire: Encodable {
    let requestId: String
    let type: String?
    let response: NetworkResponseWire
    let timestamp: Double
}

private struct NetworkDataReceivedWire: Encodable {
    let requestId: String
    let dataLength: Int
    let encodedDataLength: Int
    let timestamp: Double
}

private struct NetworkLoadingFinishedWire: Encodable {
    let requestId: String
    let timestamp: Double
    let sourceMapURL: String?
    let metrics: NetworkMetricsWire?
}

private struct NetworkMetricsWire: Encodable {
    let networkProtocol: String?
    let remoteAddress: String?
    let responseBodyBytesReceived: Int?
    let responseBodyDecodedSize: Int?

    enum CodingKeys: String, CodingKey {
        case networkProtocol = "protocol"
        case remoteAddress
        case responseBodyBytesReceived
        case responseBodyDecodedSize
    }

    init(_ metrics: Network.Metrics) {
        networkProtocol = metrics.networkProtocol
        remoteAddress = metrics.remoteAddress
        responseBodyBytesReceived = metrics.encodedDataLength
        responseBodyDecodedSize = metrics.decodedBodyLength
    }
}

private struct NetworkLoadingFailedWire: Encodable {
    let requestId: String
    let timestamp: Double
    let errorText: String
    let canceled: Bool
}

private struct NetworkMemoryCacheWire: Encodable {
    let requestId: String
    let timestamp: Double
    let initiator: NetworkInitiatorWire
    let resource: NetworkCachedResourceWire
}

private struct NetworkCachedResourceWire: Encodable {
    let url: String
    let type: String
    let bodySize: Int?
    let response: NetworkResponseWire
}

private struct NetworkWebSocketCreatedWire: Encodable {
    let requestId: String
    let url: String
}

private struct NetworkWebSocketHandshakeRequestWire: Encodable {
    let requestId: String
    let timestamp: Double?
    let request: NetworkWebSocketRequestWire
}

private struct NetworkWebSocketRequestWire: Encodable {
    let headers: [String: String]
}

private struct NetworkWebSocketHandshakeResponseWire: Encodable {
    let requestId: String
    let timestamp: Double?
    let response: NetworkResponseWire
}

private struct NetworkWebSocketClosedWire: Encodable {
    let requestId: String
    let timestamp: Double
}

private struct NetworkWebSocketFrameEventWire: Encodable {
    let requestId: String
    let timestamp: Double
    let response: NetworkWebSocketFrameWire
}

private struct NetworkWebSocketFrameWire: Encodable {
    let opcode: Int
    let mask: Bool
    let payloadData: String
    let payloadLength: Int

    init(_ frame: Network.WebSocketFrame) {
        opcode = frame.opcode
        mask = frame.mask
        payloadData = frame.payloadData
        payloadLength = frame.payloadLength
    }
}

private struct NetworkWebSocketErrorWire: Encodable {
    let requestId: String
    let timestamp: Double
    let errorMessage: String
}

private struct ConsoleMessageAddedWire: Encodable {
    let message: ConsoleMessageWire
}

private struct ConsoleMessageWire: Encodable {
    let source: String
    let level: String
    let type: String?
    let text: String
    let url: String?
    let line: Int?
    let column: Int?
    let repeatCount: Int
    let parameters: [RuntimeRemoteObjectWire]
    let stackTrace: ConsoleStackTraceWire?
    let networkRequestId: String?
    let timestamp: Double?

    init(_ message: Console.Message) {
        source = message.source.rawValue
        level = message.level.rawValue
        type = message.type?.rawValue
        text = message.text
        url = message.url
        line = message.line
        column = message.column
        repeatCount = message.repeatCount
        parameters = message.parameters.map(RuntimeRemoteObjectWire.init)
        stackTrace = message.stackTrace.map(ConsoleStackTraceWire.init)
        networkRequestId = message.networkRequestID?.rawValue
        timestamp = message.timestamp
    }
}

private struct ConsoleStackTraceWire: Encodable {
    let callFrames: [ConsoleCallFrameWire]

    init(_ stackTrace: Console.StackTrace) {
        callFrames = stackTrace.callFrames.map(ConsoleCallFrameWire.init)
    }
}

private struct ConsoleCallFrameWire: Encodable {
    let functionName: String
    let url: String
    let lineNumber: Int
    let columnNumber: Int

    init(_ frame: Console.CallFrame) {
        functionName = frame.functionName
        url = frame.url
        lineNumber = frame.line
        columnNumber = frame.column
    }
}

private struct ConsoleRepeatCountWire: Encodable {
    let count: Int
    let timestamp: Double?
}

private struct ConsoleMessagesClearedWire: Encodable {
    let reason: String
}

private struct RuntimeContextCreatedWire: Encodable {
    let context: RuntimeExecutionContextWire
}

private struct RuntimeContextDestroyedWire: Encodable {
    let executionContextId: String
}

private struct RuntimeExecutionContextWire: Encodable {
    let id: String
    let name: String
    let frameId: String?
    let type: String

    init(_ context: Runtime.ExecutionContext) {
        id = context.id.rawValue
        name = context.name
        frameId = context.frameID?.rawValue
        switch context.kind {
        case .normal: type = "normal"
        case .user: type = "user"
        case .internalContext: type = "internal"
        case let .other(value): type = value
        }
    }
}

struct RuntimeRemoteObjectWire: Encodable {
    let objectId: String?
    let type: String
    let subtype: String?
    let className: String?
    let description: String?
    let value: RuntimeJSONValueWire?
    let size: Int?
    let preview: RuntimeObjectPreviewWire?

    init(_ object: Runtime.RemoteObject) {
        objectId = object.id?.rawValue
        let kind = Self.wireKind(object.kind, explicitSubtype: object.subtype?.rawValue)
        type = kind.type
        subtype = kind.subtype
        className = object.className
        description = object.description
        value = object.value.map(RuntimeJSONValueWire.init)
        size = object.size
        preview = object.preview.map(RuntimeObjectPreviewWire.init)
    }

    private static func wireKind(
        _ kind: Runtime.Kind,
        explicitSubtype: String?
    ) -> (type: String, subtype: String?) {
        switch kind {
        case .object: ("object", explicitSubtype)
        case .function: ("function", explicitSubtype)
        case .string: ("string", explicitSubtype)
        case .number: ("number", explicitSubtype)
        case .boolean: ("boolean", explicitSubtype)
        case .symbol: ("symbol", explicitSubtype)
        case .bigint: ("bigint", explicitSubtype)
        case .undefined: ("undefined", explicitSubtype)
        case .null: ("object", explicitSubtype ?? "null")
        case .array: ("object", explicitSubtype ?? "array")
        case .error: ("object", explicitSubtype ?? "error")
        case let .other(value): (value, explicitSubtype)
        }
    }
}

struct RuntimeJSONValueWire: Encodable {
    let value: Runtime.JSONValue

    init(_ value: Runtime.JSONValue) {
        self.value = value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        case let .array(values): try container.encode(values.map(Self.init))
        case let .object(values): try container.encode(values.mapValues(Self.init))
        }
    }
}

struct RuntimeObjectPreviewWire: Encodable {
    let type: String?
    let subtype: String?
    let description: String?
    let lossless: Bool
    let overflow: Bool
    let properties: [RuntimePropertyPreviewWire]
    let entries: [RuntimeEntryPreviewWire]
    let size: Int?

    init(_ preview: Runtime.ObjectPreview) {
        type = preview.kind.map { RuntimeRemoteObjectWire(
            Runtime.RemoteObject(id: nil, kind: $0)
        ).type }
        subtype = preview.subtype?.rawValue
        description = preview.description
        lossless = preview.lossless
        overflow = preview.overflow
        properties = preview.properties.map(RuntimePropertyPreviewWire.init)
        entries = preview.entries.map(RuntimeEntryPreviewWire.init)
        size = preview.size
    }
}

struct RuntimePropertyPreviewWire: Encodable {
    let name: String
    let value: String?

    init(_ preview: Runtime.PropertyPreview) {
        name = preview.name
        value = preview.value
    }
}

struct RuntimeEntryPreviewWire: Encodable {
    let key: RuntimeRemoteObjectWire?
    let value: RuntimeRemoteObjectWire?

    init(_ preview: Runtime.EntryPreview) {
        key = preview.key.map {
            RuntimeRemoteObjectWire(Runtime.RemoteObject(
                id: nil,
                kind: .string,
                description: $0,
                value: .string($0)
            ))
        }
        value = preview.value.map {
            RuntimeRemoteObjectWire(Runtime.RemoteObject(
                id: nil,
                kind: .string,
                description: $0,
                value: .string($0)
            ))
        }
    }
}
