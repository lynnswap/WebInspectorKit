import Foundation

package extension DOMWireCoding {
    static let eventDecoder = WebInspectorEventDecoder<DOM.Event>(domain: eventDomain) { envelope in
        let event: DOM.Event
        switch envelope.method.rawValue {
        case "DOM.documentUpdated":
            event = .documentUpdated
        case "DOM.inspect":
            let params = try decodeWire(DOMInspectParams.self, from: envelope)
            event = .inspect(DOM.Node.ID(params.nodeId))
        case "DOM.setChildNodes":
            let params = try decodeWire(SetChildNodesParams.self, from: envelope)
            let nodes = try params.nodes.map { try $0.proxyNode() }
            if params.parentId == "0", let root = nodes.first {
                event = .detachedRoot(root)
            } else {
                event = .setChildNodes(parent: DOM.Node.ID(params.parentId), nodes: nodes)
            }
        case "DOM.childNodeInserted":
            let params = try decodeWire(ChildNodeInsertedParams.self, from: envelope)
            event = try .childNodeInserted(
                parent: DOM.Node.ID(params.parentNodeId),
                previous: params.previousNodeID,
                node: params.node.proxyNode()
            )
        case "DOM.childNodeRemoved":
            let params = try decodeWire(ChildNodeRemovedParams.self, from: envelope)
            event = .childNodeRemoved(parent: DOM.Node.ID(params.parentNodeId), node: DOM.Node.ID(params.nodeId))
        case "DOM.childNodeCountUpdated":
            let params = try decodeWire(ChildNodeCountUpdatedParams.self, from: envelope)
            event = .childNodeCountUpdated(DOM.Node.ID(params.nodeId), count: params.childNodeCount)
        case "DOM.attributeModified":
            let params = try decodeWire(AttributeModifiedParams.self, from: envelope)
            event = .attributeModified(DOM.Node.ID(params.nodeId), name: params.name, value: params.value)
        case "DOM.attributeRemoved":
            let params = try decodeWire(AttributeRemovedParams.self, from: envelope)
            event = .attributeRemoved(DOM.Node.ID(params.nodeId), name: params.name)
        case "DOM.inlineStyleInvalidated":
            let params = try decodeWire(InlineStyleInvalidatedParams.self, from: envelope)
            event = .inlineStyleInvalidated(params.nodeIds.map(DOM.Node.ID.init))
        case "DOM.characterDataModified":
            let params = try decodeWire(CharacterDataModifiedParams.self, from: envelope)
            event = .characterDataModified(DOM.Node.ID(params.nodeId), value: params.characterData)
        case "DOM.shadowRootPushed":
            let params = try decodeWire(ShadowRootPushedParams.self, from: envelope)
            event = try .shadowRootPushed(host: DOM.Node.ID(params.hostId), root: params.root.proxyNode())
        case "DOM.shadowRootPopped":
            let params = try decodeWire(ShadowRootPoppedParams.self, from: envelope)
            event = .shadowRootPopped(host: DOM.Node.ID(params.hostId), root: DOM.Node.ID(params.rootId))
        case "DOM.pseudoElementAdded":
            let params = try decodeWire(PseudoElementAddedParams.self, from: envelope)
            event = try .pseudoElementAdded(parent: DOM.Node.ID(params.parentId), element: params.pseudoElement.proxyNode())
        case "DOM.pseudoElementRemoved":
            let params = try decodeWire(PseudoElementRemovedParams.self, from: envelope)
            event = .pseudoElementRemoved(parent: DOM.Node.ID(params.parentId), element: DOM.Node.ID(params.pseudoElementId))
        case "DOM.willDestroyDOMNode":
            let params = try decodeWire(WillDestroyDOMNodeParams.self, from: envelope)
            event = .willDestroyDOMNode(DOM.Node.ID(params.nodeId))
        default:
            return .unknown(RawEvent(envelope))
        }
        return envelope.targetScopeRawValue.map { DomainEventIdentityScope.domEvent(event, target: $0) } ?? event
    }
}

package extension InspectorWireCoding {
    static let eventDecoder = WebInspectorEventDecoder<Inspector.Event>(domain: eventDomain) { envelope in
        switch envelope.method.rawValue {
        case "Inspector.inspect":
            let params = try decodeWire(InspectorInspectParams.self, from: envelope)
            let event = Inspector.Event.inspect(params.object.proxyObject, hints: params.hints?.proxyValue)
            return envelope.targetScopeRawValue.map { DomainEventIdentityScope.inspectorEvent(event, target: $0) } ?? event
        default:
            return .unknown(RawEvent(envelope))
        }
    }
}

package extension CSSWireCoding {
    static let eventDecoder = WebInspectorEventDecoder<CSS.Event>(domain: eventDomain) { envelope in
        let event: CSS.Event
        switch envelope.method.rawValue {
        case "CSS.styleSheetChanged":
            event = .styleSheetChanged(CSS.StyleSheet.ID(try decodeWire(StyleSheetChangedParams.self, from: envelope).styleSheetId))
        case "CSS.styleSheetRemoved":
            event = .styleSheetRemoved(CSS.StyleSheet.ID(try decodeWire(StyleSheetRemovedParams.self, from: envelope).styleSheetId))
        case "CSS.styleSheetAdded":
            event = .styleSheetAdded(try decodeWire(StyleSheetAddedParams.self, from: envelope).header.proxyHeader)
        case "CSS.mediaQueryResultChanged":
            event = .mediaQueryResultChanged
        case "CSS.nodeLayoutFlagsChanged":
            event = .nodeLayoutFlagsChanged(DOM.Node.ID(try decodeWire(NodeLayoutFlagsChangedParams.self, from: envelope).nodeId))
        default:
            return .unknown(RawEvent(envelope))
        }
        return envelope.targetScopeRawValue.map { DomainEventIdentityScope.cssEvent(event, target: $0) } ?? event
    }
}

package extension NetworkWireCoding {
    static let eventDecoder = WebInspectorEventDecoder<Network.Event>(domain: eventDomain) { envelope in
        let event: Network.Event
        switch envelope.method.rawValue {
        case "Network.requestWillBeSent":
            let params = try decodeWire(RequestWillBeSentParams.self, from: envelope)
            event = .requestWillBeSent(
                id: Network.Request.ID(params.requestId),
                request: params.request.proxyRequest(
                    id: params.requestId,
                    backendResourceIdentifier: params.backendResourceIdentifier?.proxyIdentifier,
                    origin: Network.Request.Origin(
                        frameID: FrameID(params.frameId),
                        loaderID: params.loaderId,
                        targetID: params.targetId
                    )
                ),
                initiator: params.initiator.proxyInitiator,
                resourceType: params.type.map(Network.ResourceType.init(rawValue:)),
                redirectResponse: params.redirectResponse?.proxyResponse(fallbackURL: params.request.url),
                timestamp: params.timestamp
            )
        case "Network.responseReceived":
            let params = try decodeWire(ResponseReceivedParams.self, from: envelope)
            event = .responseReceived(
                id: Network.Request.ID(params.requestId),
                response: params.response.proxyResponse(fallbackURL: nil),
                resourceType: params.type.map(Network.ResourceType.init(rawValue:)),
                timestamp: params.timestamp
            )
        case "Network.dataReceived":
            let params = try decodeWire(DataReceivedParams.self, from: envelope)
            event = .dataReceived(
                id: Network.Request.ID(params.requestId),
                dataLength: params.dataLength,
                encodedDataLength: params.encodedDataLength,
                timestamp: params.timestamp
            )
        case "Network.loadingFinished":
            let params = try decodeWire(LoadingFinishedParams.self, from: envelope)
            event = .loadingFinished(
                id: Network.Request.ID(params.requestId),
                timestamp: params.timestamp,
                sourceMapURL: params.sourceMapURL,
                metrics: params.metrics?.proxyMetrics(timestamp: params.timestamp)
            )
        case "Network.loadingFailed":
            let params = try decodeWire(LoadingFailedParams.self, from: envelope)
            event = .loadingFailed(
                id: Network.Request.ID(params.requestId),
                errorText: params.errorText,
                canceled: params.canceled ?? false,
                timestamp: params.timestamp
            )
        case "Network.requestServedFromMemoryCache":
            let params = try decodeWire(RequestServedFromMemoryCacheParams.self, from: envelope)
            event = .requestServedFromMemoryCache(
                id: Network.Request.ID(params.requestId),
                response: params.resource.proxyResponse,
                initiator: params.initiator.proxyInitiator,
                resourceType: Network.ResourceType(rawValue: params.resource.type),
                timestamp: params.timestamp
            )
        case "Network.webSocketCreated":
            let params = try decodeWire(WebSocketCreatedParams.self, from: envelope)
            event = .webSocket(.created(id: Network.Request.ID(params.requestId), url: params.url))
        case "Network.webSocketWillSendHandshakeRequest":
            let params = try decodeWire(WebSocketWillSendHandshakeRequestParams.self, from: envelope)
            event = .webSocket(.handshakeRequest(
                id: Network.Request.ID(params.requestId),
                request: params.request.proxyRequest(id: params.requestId),
                timestamp: params.timestamp
            ))
        case "Network.webSocketHandshakeResponseReceived":
            let params = try decodeWire(WebSocketHandshakeResponseReceivedParams.self, from: envelope)
            event = .webSocket(.handshakeResponse(
                id: Network.Request.ID(params.requestId),
                response: params.response.proxyResponse(fallbackURL: nil),
                timestamp: params.timestamp
            ))
        case "Network.webSocketFrameReceived":
            let params = try decodeWire(WebSocketFrameParams.self, from: envelope)
            event = .webSocket(.frameReceived(
                id: Network.Request.ID(params.requestId),
                frame: params.response.proxyFrame,
                timestamp: params.timestamp
            ))
        case "Network.webSocketFrameSent":
            let params = try decodeWire(WebSocketFrameParams.self, from: envelope)
            event = .webSocket(.frameSent(
                id: Network.Request.ID(params.requestId),
                frame: params.response.proxyFrame,
                timestamp: params.timestamp
            ))
        case "Network.webSocketFrameError":
            let params = try decodeWire(WebSocketFrameErrorParams.self, from: envelope)
            event = .webSocket(.error(
                id: Network.Request.ID(params.requestId),
                message: params.errorMessage,
                timestamp: params.timestamp
            ))
        case "Network.webSocketClosed":
            let params = try decodeWire(WebSocketClosedParams.self, from: envelope)
            event = .webSocket(.closed(id: Network.Request.ID(params.requestId), timestamp: params.timestamp))
        default:
            return .unknown(RawEvent(envelope))
        }
        return envelope.targetScopeRawValue.map { DomainEventIdentityScope.networkEvent(event, target: $0) } ?? event
    }
}

package extension ConsoleWireCoding {
    static let eventDecoder = WebInspectorEventDecoder<Console.Event>(domain: eventDomain) { envelope in
        let event: Console.Event
        switch envelope.method.rawValue {
        case "Console.messageAdded":
            event = .messageAdded(try decodeWire(MessageAddedParams.self, from: envelope).message.proxyMessage)
        case "Console.messageRepeatCountUpdated":
            let params = try decodeWire(MessageRepeatCountUpdatedParams.self, from: envelope)
            event = .messageRepeatCountUpdated(count: params.count, timestamp: params.timestamp)
        case "Console.messagesCleared":
            event = .messagesCleared(reason: Console.ClearReason(rawValue: try decodeWire(MessagesClearedParams.self, from: envelope).reason))
        default:
            return .unknown(RawEvent(envelope))
        }
        return envelope.targetScopeRawValue.map { DomainEventIdentityScope.consoleEvent(event, target: $0) } ?? event
    }
}

package extension RuntimeWireCoding {
    static let eventDecoder = WebInspectorEventDecoder<Runtime.Event>(domain: eventDomain) { envelope in
        let event: Runtime.Event
        switch envelope.method.rawValue {
        case "Runtime.executionContextCreated":
            event = .executionContextCreated(try decodeWire(ExecutionContextCreatedParams.self, from: envelope).context.proxyContext)
        case "Runtime.executionContextDestroyed":
            event = .executionContextDestroyed(Runtime.ExecutionContext.ID(
                try decodeWire(ExecutionContextDestroyedParams.self, from: envelope).executionContextId
            ))
        case "Runtime.executionContextsCleared":
            event = .executionContextsCleared
        default:
            return .unknown(RawEvent(envelope))
        }
        return envelope.targetScopeRawValue.map { DomainEventIdentityScope.runtimeEvent(event, target: $0) } ?? event
    }
}

package extension PageWireCoding {
    static let eventDecoder = WebInspectorEventDecoder<Page.Event>(domain: eventDomain) { envelope in
        switch envelope.method.rawValue {
        case "Page.frameNavigated":
            return .frameNavigated(try decodeWire(PageFrameNavigatedParams.self, from: envelope).frame.proxyFrame)
        case "Page.frameDetached":
            return .frameDetached(FrameID(try decodeWire(PageFrameDetachedParams.self, from: envelope).frameId))
        default:
            return .unknown(RawEvent(envelope))
        }
    }
}

private func decodeWire<Value: Decodable>(
    _ type: Value.Type,
    from envelope: WebInspectorRoutedEventEnvelope
) throws -> Value {
    try liveProxyDecode(type, from: envelope.parameters)
}

private struct PageFrameNavigatedParams: Decodable {
    var frame: PageFramePayload
}

private struct PageFrameDetachedParams: Decodable {
    var frameId: String
}

private struct PageFramePayload: Decodable {
    var id: String
    var parentId: String?
    var loaderId: String?
    var name: String?
    var url: String
    var securityOrigin: String?
    var mimeType: String?

    var proxyFrame: Page.Frame {
        Page.Frame(
            id: FrameID(id),
            parentID: parentId.map(FrameID.init),
            loaderID: loaderId,
            name: name,
            url: url,
            securityOrigin: securityOrigin,
            mimeType: mimeType
        )
    }
}

private struct DOMInspectParams: Decodable {
    var nodeId: String

    private enum CodingKeys: String, CodingKey {
        case nodeId
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodeId = try container.decodeStringOrInteger(forKey: .nodeId)
    }
}

private struct SetChildNodesParams: Decodable {
    var parentId: String
    var nodes: [ProtocolDOMNodePayload]

    private enum CodingKeys: String, CodingKey {
        case parentId
        case nodes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parentId = try container.decodeStringOrInteger(forKey: .parentId)
        nodes = try container.decode([ProtocolDOMNodePayload].self, forKey: .nodes)
    }
}

private struct ChildNodeInsertedParams: Decodable {
    var parentNodeId: String
    var previousNodeId: String
    var node: ProtocolDOMNodePayload

    var previousNodeID: DOM.Node.ID? {
        previousNodeId == "0" ? nil : DOM.Node.ID(previousNodeId)
    }

    private enum CodingKeys: String, CodingKey {
        case parentNodeId
        case previousNodeId
        case node
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parentNodeId = try container.decodeStringOrInteger(forKey: .parentNodeId)
        previousNodeId = try container.decodeStringOrInteger(forKey: .previousNodeId)
        node = try container.decode(ProtocolDOMNodePayload.self, forKey: .node)
    }
}

private struct ChildNodeRemovedParams: Decodable {
    var parentNodeId: String
    var nodeId: String

    private enum CodingKeys: String, CodingKey {
        case parentNodeId
        case nodeId
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parentNodeId = try container.decodeStringOrInteger(forKey: .parentNodeId)
        nodeId = try container.decodeStringOrInteger(forKey: .nodeId)
    }
}

private struct ChildNodeCountUpdatedParams: Decodable {
    var nodeId: String
    var childNodeCount: Int

    private enum CodingKeys: String, CodingKey {
        case nodeId
        case childNodeCount
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodeId = try container.decodeStringOrInteger(forKey: .nodeId)
        childNodeCount = try container.decode(Int.self, forKey: .childNodeCount)
    }
}

private struct AttributeModifiedParams: Decodable {
    var nodeId: String
    var name: String
    var value: String

    private enum CodingKeys: String, CodingKey {
        case nodeId
        case name
        case value
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodeId = try container.decodeStringOrInteger(forKey: .nodeId)
        name = try container.decode(String.self, forKey: .name)
        value = try container.decode(String.self, forKey: .value)
    }
}

private struct AttributeRemovedParams: Decodable {
    var nodeId: String
    var name: String

    private enum CodingKeys: String, CodingKey {
        case nodeId
        case name
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodeId = try container.decodeStringOrInteger(forKey: .nodeId)
        name = try container.decode(String.self, forKey: .name)
    }
}

private struct InlineStyleInvalidatedParams: Decodable {
    var nodeIds: [String]

    private enum CodingKeys: String, CodingKey {
        case nodeIds
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let values = try container.decode([FlexibleStringPayload].self, forKey: .nodeIds)
        nodeIds = values.map(\.stringValue)
    }
}

private struct FlexibleStringPayload: Decodable {
    var stringValue: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            stringValue = string
        } else {
            stringValue = String(try container.decode(Int.self))
        }
    }
}

private struct CharacterDataModifiedParams: Decodable {
    var nodeId: String
    var characterData: String

    private enum CodingKeys: String, CodingKey {
        case nodeId
        case characterData
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodeId = try container.decodeStringOrInteger(forKey: .nodeId)
        characterData = try container.decode(String.self, forKey: .characterData)
    }
}

private struct ShadowRootPushedParams: Decodable {
    var hostId: String
    var root: ProtocolDOMNodePayload

    private enum CodingKeys: String, CodingKey {
        case hostId
        case root
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostId = try container.decodeStringOrInteger(forKey: .hostId)
        root = try container.decode(ProtocolDOMNodePayload.self, forKey: .root)
    }
}

private struct ShadowRootPoppedParams: Decodable {
    var hostId: String
    var rootId: String

    private enum CodingKeys: String, CodingKey {
        case hostId
        case rootId
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostId = try container.decodeStringOrInteger(forKey: .hostId)
        rootId = try container.decodeStringOrInteger(forKey: .rootId)
    }
}

private struct PseudoElementAddedParams: Decodable {
    var parentId: String
    var pseudoElement: ProtocolDOMNodePayload

    private enum CodingKeys: String, CodingKey {
        case parentId
        case pseudoElement
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parentId = try container.decodeStringOrInteger(forKey: .parentId)
        pseudoElement = try container.decode(ProtocolDOMNodePayload.self, forKey: .pseudoElement)
    }
}

private struct PseudoElementRemovedParams: Decodable {
    var parentId: String
    var pseudoElementId: String

    private enum CodingKeys: String, CodingKey {
        case parentId
        case pseudoElementId
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parentId = try container.decodeStringOrInteger(forKey: .parentId)
        pseudoElementId = try container.decodeStringOrInteger(forKey: .pseudoElementId)
    }
}

private struct WillDestroyDOMNodeParams: Decodable {
    var nodeId: String

    private enum CodingKeys: String, CodingKey {
        case nodeId
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodeId = try container.decodeStringOrInteger(forKey: .nodeId)
    }
}

private struct InspectorInspectParams: Decodable {
    var object: RuntimeRemoteObjectPayload
    var hints: RuntimeJSONValuePayload?
}

private struct StyleSheetChangedParams: Decodable {
    var styleSheetId: String
}

private struct StyleSheetRemovedParams: Decodable {
    var styleSheetId: String
}

struct StyleSheetAddedParams: Codable {
    var header: StyleSheetHeaderPayload
}

private struct NodeLayoutFlagsChangedParams: Decodable {
    var nodeId: String

    private enum CodingKeys: String, CodingKey {
        case nodeId
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodeId = try container.decodeStringOrInteger(forKey: .nodeId)
    }
}

struct StyleSheetHeaderPayload: Codable {
    var styleSheetId: String
    var frameId: String?
    var sourceURL: String?
    var origin: String
    var title: String?
    var disabled: Bool?
    var isInline: Bool?
    var startLine: Int?
    var startColumn: Int?

    var proxyHeader: CSS.StyleSheetHeader {
        CSS.StyleSheetHeader(
            styleSheetID: CSS.StyleSheet.ID(styleSheetId),
            frameID: frameId.map(FrameID.init),
            sourceURL: sourceURL,
            origin: CSS.Origin(rawValue: origin),
            title: title,
            disabled: disabled ?? false,
            isInline: isInline ?? false,
            startLine: startLine ?? 0,
            startColumn: startColumn ?? 0
        )
    }
}

private struct RequestWillBeSentParams: Decodable {
    var requestId: String
    var frameId: String
    var loaderId: String
    var request: RequestPayload
    var initiator: InitiatorPayload
    var type: String?
    var redirectResponse: ResponsePayload?
    var timestamp: Double
    var targetId: String?
    var backendResourceIdentifier: BackendResourceIdentifierPayload?

    private enum CodingKeys: String, CodingKey {
        case requestId
        case frameId
        case loaderId
        case request
        case initiator
        case type
        case redirectResponse
        case timestamp
        case targetId
        case backendResourceIdentifier
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try container.decode(String.self, forKey: .requestId)
        frameId = try container.decode(String.self, forKey: .frameId)
        loaderId = try container.decode(String.self, forKey: .loaderId)
        request = try container.decode(RequestPayload.self, forKey: .request)
        initiator = try container.decode(InitiatorPayload.self, forKey: .initiator)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        redirectResponse = try container.decodeIfPresent(
            ResponsePayload.self,
            forKey: .redirectResponse
        )
        timestamp = try container.decode(Double.self, forKey: .timestamp)
        targetId = try container.decodeIfPresent(String.self, forKey: .targetId)
        if targetId?.isEmpty == true {
            throw DecodingError.dataCorruptedError(
                forKey: .targetId,
                in: container,
                debugDescription: "Network targetId must be non-empty when present."
            )
        }
        backendResourceIdentifier = try container.decodeIfPresent(
            BackendResourceIdentifierPayload.self,
            forKey: .backendResourceIdentifier
        )
    }
}

private struct BackendResourceIdentifierPayload: Decodable {
    var sourceProcessID: String
    var resourceID: String

    var proxyIdentifier: Network.BackendResourceID {
        Network.BackendResourceID(sourceProcessID: sourceProcessID, resourceID: resourceID)
    }
}

private struct ResponseReceivedParams: Decodable {
    var requestId: String
    var type: String?
    var response: ResponsePayload
    var timestamp: Double
}

private struct DataReceivedParams: Decodable {
    var requestId: String
    var dataLength: Int
    var encodedDataLength: Int
    var timestamp: Double
}

private struct LoadingFinishedParams: Decodable {
    var requestId: String
    var timestamp: Double
    var sourceMapURL: String?
    var metrics: MetricsPayload?
}

private struct LoadingFailedParams: Decodable {
    var requestId: String
    var timestamp: Double
    var errorText: String
    var canceled: Bool?
}

private struct RequestServedFromMemoryCacheParams: Decodable {
    var requestId: String
    var timestamp: Double
    var initiator: InitiatorPayload
    var resource: CachedResourcePayload
}

private struct InitiatorPayload: Decodable {
    var type: String
    var url: String?
    var lineNumber: Double?
    var nodeId: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case url
        case lineNumber
        case nodeId
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        lineNumber = try container.decodeIfPresent(Double.self, forKey: .lineNumber)
        guard container.contains(.nodeId) else {
            nodeId = nil
            return
        }
        let rawNodeID = try container.decodeStringOrInteger(forKey: .nodeId)
        guard let numericNodeID = Int64(rawNodeID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .nodeId,
                in: container,
                debugDescription: "Network initiator nodeId must be an integer."
            )
        }
        nodeId = numericNodeID > 0 ? rawNodeID : nil
    }

    var proxyInitiator: Network.Initiator {
        Network.Initiator(
            kind: type,
            url: url,
            line: lineNumber.map(Int.init),
            nodeID: nodeId.map(DOM.Node.ID.init)
        )
    }
}

private struct RequestPayload: Decodable {
    var url: String
    var method: String?
    var headers: [String: String]?
    var postData: String?
    var referrerPolicy: String?
    var integrity: String?

    func proxyRequest(
        id: String,
        backendResourceIdentifier: Network.BackendResourceID? = nil,
        origin: Network.Request.Origin? = nil
    ) -> Network.Request {
        Network.Request(
            id: Network.Request.ID(id),
            url: url,
            method: method ?? "GET",
            headers: headers ?? [:],
            postData: postData,
            referrerPolicy: referrerPolicy.map(Network.ReferrerPolicy.init(rawValue:)),
            integrity: integrity,
            backendResourceIdentifier: backendResourceIdentifier,
            origin: origin
        )
    }
}

private struct ResponsePayload: Decodable {
    var url: String?
    var status: Int?
    var statusText: String?
    var headers: [String: String]?
    var mimeType: String?
    var source: String?
    var requestHeaders: [String: String]?

    func proxyResponse(fallbackURL: String?, bodySize: Int? = nil) -> Network.Response {
        Network.Response(
            url: url ?? fallbackURL,
            status: status,
            statusText: statusText,
            mimeType: mimeType,
            headers: headers ?? [:],
            source: source.map(Network.Source.init(rawValue:)),
            requestHeaders: requestHeaders,
            bodySize: bodySize
        )
    }
}

private struct MetricsPayload: Decodable {
    var networkProtocol: String?
    var remoteAddress: String?
    var responseBodyBytesReceived: Int?
    var responseBodyDecodedSize: Int?

    enum CodingKeys: String, CodingKey {
        case networkProtocol = "protocol"
        case remoteAddress
        case responseBodyBytesReceived
        case responseBodyDecodedSize
    }

    func proxyMetrics(timestamp: Double) -> Network.Metrics {
        Network.Metrics(
            timestamp: timestamp,
            networkProtocol: networkProtocol,
            remoteAddress: remoteAddress,
            encodedDataLength: responseBodyBytesReceived,
            decodedBodyLength: responseBodyDecodedSize
        )
    }
}

private struct CachedResourcePayload: Decodable {
    var url: String
    var type: String
    var bodySize: Int?
    var response: ResponsePayload?

    var proxyResponse: Network.Response {
        response?.proxyResponse(fallbackURL: url, bodySize: bodySize)
            ?? Network.Response(url: url, bodySize: bodySize)
    }
}

private struct WebSocketCreatedParams: Decodable {
    var requestId: String
    var url: String
}

private struct WebSocketWillSendHandshakeRequestParams: Decodable {
    var requestId: String
    var timestamp: Double?
    var request: WebSocketHandshakeRequestPayload
}

private struct WebSocketHandshakeResponseReceivedParams: Decodable {
    var requestId: String
    var timestamp: Double?
    var response: ResponsePayload
}

private struct WebSocketHandshakeRequestPayload: Decodable {
    var headers: [String: String]?

    func proxyRequest(id: String) -> Network.Request {
        Network.Request(
            id: Network.Request.ID(id),
            url: "",
            method: "GET",
            headers: headers ?? [:]
        )
    }
}

private struct WebSocketFrameParams: Decodable {
    var requestId: String
    var timestamp: Double
    var response: WebSocketFramePayload
}

private struct WebSocketFrameErrorParams: Decodable {
    var requestId: String
    var timestamp: Double
    var errorMessage: String
}

private struct WebSocketClosedParams: Decodable {
    var requestId: String
    var timestamp: Double
}

private struct WebSocketFramePayload: Decodable {
    var opcode: Int
    var mask: Bool
    var payloadData: String
    var payloadLength: Int

    var proxyFrame: Network.WebSocketFrame {
        Network.WebSocketFrame(opcode: opcode, mask: mask, payloadData: payloadData, payloadLength: payloadLength)
    }
}

private struct MessageAddedParams: Decodable {
    var message: ConsoleMessagePayload
}

private struct MessageRepeatCountUpdatedParams: Decodable {
    var count: Int
    var timestamp: Double?
}

private struct MessagesClearedParams: Decodable {
    var reason: String
}

private struct ConsoleMessagePayload: Decodable {
    var source: String
    var level: String
    var type: String?
    var text: String?
    var url: String?
    var line: Int?
    var column: Int?
    var repeatCount: Int?
    var parameters: [RuntimeRemoteObjectPayload]?
    var stackTrace: StackTracePayload?
    var networkRequestId: String?
    var timestamp: Double?

    var proxyMessage: Console.Message {
        Console.Message(
            source: Console.Source(rawValue: source),
            level: Console.Level(rawValue: level),
            type: type.map(Console.Kind.init(rawValue:)),
            text: text ?? "",
            url: url,
            line: line,
            column: column,
            repeatCount: repeatCount ?? 1,
            parameters: parameters?.map(\.proxyObject) ?? [],
            stackTrace: stackTrace?.proxyStackTrace,
            networkRequestID: networkRequestId.map(Network.Request.ID.init),
            timestamp: timestamp
        )
    }
}

private final class StackTracePayload: Decodable {
    var callFrames: [CallFramePayload]
    var parentStackTrace: StackTracePayload?

    var proxyStackTrace: Console.StackTrace {
        var frames = callFrames.map(\.proxyCallFrame)
        if let parentStackTrace {
            frames.append(contentsOf: parentStackTrace.proxyStackTrace.callFrames)
        }
        return Console.StackTrace(callFrames: frames)
    }
}

private struct CallFramePayload: Decodable {
    var functionName: String
    var url: String
    var lineNumber: Int
    var columnNumber: Int

    var proxyCallFrame: Console.CallFrame {
        Console.CallFrame(functionName: functionName, url: url, line: lineNumber, column: columnNumber)
    }
}

private struct ExecutionContextCreatedParams: Decodable {
    var context: ExecutionContextPayload
}

private struct ExecutionContextDestroyedParams: Decodable {
    var executionContextId: String

    private enum CodingKeys: String, CodingKey {
        case executionContextId
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        executionContextId = try container.decodeStringOrInteger(forKey: .executionContextId)
    }
}

private struct ExecutionContextPayload: Decodable {
    var id: String
    var name: String?
    var frameId: String?
    var type: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case frameId
        case type
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeStringOrInteger(forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        frameId = try container.decodeIfPresent(String.self, forKey: .frameId)
        type = try container.decodeIfPresent(String.self, forKey: .type)
    }

    var proxyContext: Runtime.ExecutionContext {
        Runtime.ExecutionContext(
            id: Runtime.ExecutionContext.ID(id),
            name: name ?? "",
            frameID: frameId.map(FrameID.init),
            kind: Runtime.ContextKind(rawProtocolValue: type)
        )
    }
}

struct RuntimeRemoteObjectPayload: Decodable {
    var objectId: String?
    var type: String
    var subtype: String?
    var className: String?
    var description: String?
    var value: RuntimeJSONValuePayload?
    var size: Int?
    var preview: ObjectPreviewPayload?

    var proxyObject: Runtime.RemoteObject {
        proxyObject(targetScopeRawValue: nil)
    }

    func proxyObject(targetScopeRawValue: String?) -> Runtime.RemoteObject {
        Runtime.RemoteObject(
            id: objectId.map { rawValue in
                targetScopeRawValue.map {
                    Runtime.RemoteObject.ID(rawValue, scopedToTargetRawValue: $0)
                } ?? Runtime.RemoteObject.ID(rawValue)
            },
            kind: Runtime.Kind(rawProtocolValue: type, subtype: subtype),
            subtype: subtype.map(Runtime.Subtype.init(rawValue:)),
            className: className,
            description: description,
            value: value?.proxyValue,
            size: size,
            preview: preview?.proxyPreview
        )
    }
}

struct ObjectPreviewPayload: Decodable {
    var type: String?
    var subtype: String?
    var description: String?
    var lossless: Bool?
    var overflow: Bool?
    var properties: [PropertyPreviewPayload]?
    var entries: [EntryPreviewPayload]?
    var size: Int?

    var proxyPreview: Runtime.ObjectPreview {
        Runtime.ObjectPreview(
            kind: type.map { Runtime.Kind(rawProtocolValue: $0, subtype: subtype) },
            subtype: subtype.map(Runtime.Subtype.init(rawValue:)),
            description: description,
            lossless: lossless ?? false,
            overflow: overflow ?? false,
            properties: properties?.map(\.proxyProperty) ?? [],
            entries: entries?.map(\.proxyEntry) ?? [],
            size: size
        )
    }
}

struct PropertyPreviewPayload: Decodable {
    var name: String
    var value: String?

    var proxyProperty: Runtime.PropertyPreview {
        Runtime.PropertyPreview(name: name, value: value)
    }
}

struct EntryPreviewPayload: Decodable {
    var key: RuntimeRemoteObjectPayload?
    var value: RuntimeRemoteObjectPayload?

    var proxyEntry: Runtime.EntryPreview {
        Runtime.EntryPreview(key: key?.description, value: value?.description)
    }
}

indirect enum RuntimeJSONValuePayload: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([RuntimeJSONValuePayload])
    case object([String: RuntimeJSONValuePayload])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .number(Double(value))
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RuntimeJSONValuePayload].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: RuntimeJSONValuePayload].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
        }
    }

    var proxyValue: Runtime.JSONValue {
        switch self {
        case let .string(value):
            .string(value)
        case let .number(value):
            .number(value)
        case let .bool(value):
            .bool(value)
        case .null:
            .null
        case let .array(value):
            .array(value.map(\.proxyValue))
        case let .object(value):
            .object(value.mapValues(\.proxyValue))
        }
    }
}

private extension Runtime.ContextKind {
    init(rawProtocolValue: String?) {
        switch rawProtocolValue {
        case nil, "normal":
            self = .normal
        case "user":
            self = .user
        case "internal":
            self = .internalContext
        case let .some(value):
            self = .other(value)
        }
    }
}

private extension Runtime.Kind {
    init(rawProtocolValue: String, subtype: String?) {
        switch rawProtocolValue {
        case "object":
            if subtype == "array" {
                self = .array
            } else if subtype == "null" {
                self = .null
            } else if subtype == "error" {
                self = .error
            } else {
                self = .object
            }
        case "function":
            self = .function
        case "string":
            self = .string
        case "number":
            self = .number
        case "boolean":
            self = .boolean
        case "symbol":
            self = .symbol
        case "bigint":
            self = .bigint
        case "undefined":
            self = .undefined
        default:
            self = .other(rawProtocolValue)
        }
    }
}

