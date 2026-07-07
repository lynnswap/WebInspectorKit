import Foundation

enum LiveProxyEventDecoder {
    static func proxyEvent(
        from event: ProtocolEvent,
        targetID: WebInspectorTarget.ID,
        lifecycleTarget: WebInspectorLifecycleTarget? = nil
    ) throws -> WebInspectorProxyEvent {
        switch event.domain {
        case .target:
            return try .targetLifecycle(targetLifecycleEvent(from: event, targetID: targetID, target: lifecycleTarget))
        case .dom:
            return try .dom(domEvent(from: event))
        case .inspector:
            return try .inspector(inspectorEvent(from: event))
        case .css:
            return try .css(cssEvent(from: event))
        case .network:
            return try .network(networkEvent(from: event))
        case .console:
            return try .console(Console.TargetedEvent(
                event: consoleEvent(from: event),
                targetID: event.targetID.map { WebInspectorTarget.ID($0.rawValue) }
            ))
        case .runtime:
            return try .runtime(runtimeEvent(from: event, targetID: targetID))
        case .page:
            return try .targetLifecycle(pageLifecycleEvent(from: event))
        case .storage, .other:
            return .dom(.unknown(rawEvent(from: event)))
        }
    }

    private static func targetLifecycleEvent(
        from event: ProtocolEvent,
        targetID: WebInspectorTarget.ID,
        target: WebInspectorLifecycleTarget?
    ) throws -> WebInspectorTargetLifecycleEvent {
        switch event.method {
        case "Target.didCommitProvisionalTarget":
            let params = try decode(TargetCommittedParams.self, from: event)
            guard let lifecycleTarget = target else {
                return .unknown(rawEvent(from: event))
            }
            return .didCommitProvisionalTarget(WebInspectorTargetCommitLifecycle(
                oldTargetID: params.oldTargetId.map { _ in targetID },
                newTarget: lifecycleTarget
            ))
        case "Target.targetDestroyed":
            _ = try decode(TargetDestroyedParams.self, from: event)
            return .targetDestroyed(targetID: targetID)
        default:
            return .unknown(rawEvent(from: event))
        }
    }

    private static func pageLifecycleEvent(from event: ProtocolEvent) throws -> WebInspectorTargetLifecycleEvent {
        switch event.method {
        case "Page.frameNavigated":
            let params = try decode(PageFrameNavigatedParams.self, from: event)
            return .frameNavigated(params.frame.proxyFrame)
        case "Page.frameDetached":
            let params = try decode(PageFrameDetachedParams.self, from: event)
            return .frameDetached(frameID: FrameID(params.frameId))
        default:
            return .unknown(rawEvent(from: event))
        }
    }

    private static func domEvent(from event: ProtocolEvent) throws -> DOM.Event {
        switch event.method {
        case "DOM.documentUpdated":
            return .documentUpdated
        case "DOM.inspect":
            let params = try decode(DOMInspectParams.self, from: event)
            return .inspect(DOM.Node.ID(params.nodeId))
        case "DOM.setChildNodes":
            let params = try decode(SetChildNodesParams.self, from: event)
            let nodes = try params.nodes.map { try $0.proxyNode() }
            if params.parentId == "0", let root = nodes.first {
                return .detachedRoot(root)
            }
            return .setChildNodes(parent: DOM.Node.ID(params.parentId), nodes: nodes)
        case "DOM.childNodeInserted":
            let params = try decode(ChildNodeInsertedParams.self, from: event)
            return try .childNodeInserted(
                parent: DOM.Node.ID(params.parentNodeId),
                previous: params.previousNodeId.map(DOM.Node.ID.init),
                node: params.node.proxyNode()
            )
        case "DOM.childNodeRemoved":
            let params = try decode(ChildNodeRemovedParams.self, from: event)
            return .childNodeRemoved(parent: DOM.Node.ID(params.parentNodeId), node: DOM.Node.ID(params.nodeId))
        case "DOM.childNodeCountUpdated":
            let params = try decode(ChildNodeCountUpdatedParams.self, from: event)
            return .childNodeCountUpdated(DOM.Node.ID(params.nodeId), count: params.childNodeCount)
        case "DOM.attributeModified":
            let params = try decode(AttributeModifiedParams.self, from: event)
            return .attributeModified(DOM.Node.ID(params.nodeId), name: params.name, value: params.value)
        case "DOM.attributeRemoved":
            let params = try decode(AttributeRemovedParams.self, from: event)
            return .attributeRemoved(DOM.Node.ID(params.nodeId), name: params.name)
        case "DOM.inlineStyleInvalidated":
            let params = try decode(InlineStyleInvalidatedParams.self, from: event)
            return .inlineStyleInvalidated(params.nodeIds.map(DOM.Node.ID.init))
        case "DOM.characterDataModified":
            let params = try decode(CharacterDataModifiedParams.self, from: event)
            return .characterDataModified(DOM.Node.ID(params.nodeId), value: params.characterData)
        case "DOM.shadowRootPushed":
            let params = try decode(ShadowRootPushedParams.self, from: event)
            return try .shadowRootPushed(host: DOM.Node.ID(params.hostId), root: params.root.proxyNode())
        case "DOM.shadowRootPopped":
            let params = try decode(ShadowRootPoppedParams.self, from: event)
            return .shadowRootPopped(host: DOM.Node.ID(params.hostId), root: DOM.Node.ID(params.rootId))
        case "DOM.pseudoElementAdded":
            let params = try decode(PseudoElementAddedParams.self, from: event)
            return try .pseudoElementAdded(parent: DOM.Node.ID(params.parentId), element: params.pseudoElement.proxyNode())
        case "DOM.pseudoElementRemoved":
            let params = try decode(PseudoElementRemovedParams.self, from: event)
            return .pseudoElementRemoved(parent: DOM.Node.ID(params.parentId), element: DOM.Node.ID(params.pseudoElementId))
        case "DOM.willDestroyDOMNode":
            let params = try decode(WillDestroyDOMNodeParams.self, from: event)
            return .willDestroyDOMNode(DOM.Node.ID(params.nodeId))
        default:
            return .unknown(rawEvent(from: event))
        }
    }

    private static func inspectorEvent(from event: ProtocolEvent) throws -> Inspector.Event {
        switch event.method {
        case "Inspector.inspect":
            let params = try decode(InspectorInspectParams.self, from: event)
            let origin = event.targetID.map {
                Inspector.EventOrigin(
                    targetID: WebInspectorTarget.ID($0.rawValue),
                    route: RoutingTargetID($0.rawValue)
                )
            }
            return .inspect(params.object.proxyObject, hints: params.hints?.proxyValue, origin: origin)
        default:
            return .unknown(rawEvent(from: event))
        }
    }

    private static func cssEvent(from event: ProtocolEvent) throws -> CSS.Event {
        switch event.method {
        case "CSS.styleSheetChanged":
            let params = try decode(StyleSheetChangedParams.self, from: event)
            return .styleSheetChanged(CSS.StyleSheet.ID(params.styleSheetId))
        case "CSS.styleSheetRemoved":
            let params = try decode(StyleSheetRemovedParams.self, from: event)
            return .styleSheetRemoved(CSS.StyleSheet.ID(params.styleSheetId))
        case "CSS.styleSheetAdded":
            let params = try decode(StyleSheetAddedParams.self, from: event)
            return .styleSheetAdded(params.header.proxyHeader)
        case "CSS.mediaQueryResultChanged":
            return .mediaQueryResultChanged
        case "CSS.nodeLayoutFlagsChanged":
            let params = try decode(NodeLayoutFlagsChangedParams.self, from: event)
            return .nodeLayoutFlagsChanged(DOM.Node.ID(params.nodeId))
        default:
            return .unknown(rawEvent(from: event))
        }
    }

    private static func networkEvent(from event: ProtocolEvent) throws -> Network.Event {
        switch event.method {
        case "Network.requestWillBeSent":
            let params = try decode(RequestWillBeSentParams.self, from: event)
            return .requestWillBeSent(
                id: Network.Request.ID(params.requestId),
                request: params.request.proxyRequest(
                    id: params.requestId,
                    backendResourceIdentifier: params.backendResourceIdentifier?.proxyIdentifier
                ),
                resourceType: params.type.map(Network.ResourceType.init(rawValue:)),
                redirectResponse: params.redirectResponse?.proxyResponse(fallbackURL: params.request.url),
                timestamp: params.timestamp
            )
        case "Network.responseReceived":
            let params = try decode(ResponseReceivedParams.self, from: event)
            return .responseReceived(
                id: Network.Request.ID(params.requestId),
                response: params.response.proxyResponse(fallbackURL: nil),
                resourceType: params.type.map(Network.ResourceType.init(rawValue:)),
                timestamp: params.timestamp
            )
        case "Network.dataReceived":
            let params = try decode(DataReceivedParams.self, from: event)
            return .dataReceived(
                id: Network.Request.ID(params.requestId),
                dataLength: params.dataLength,
                encodedDataLength: params.encodedDataLength,
                timestamp: params.timestamp
            )
        case "Network.loadingFinished":
            let params = try decode(LoadingFinishedParams.self, from: event)
            return .loadingFinished(
                id: Network.Request.ID(params.requestId),
                timestamp: params.timestamp,
                sourceMapURL: params.sourceMapURL,
                metrics: params.metrics?.proxyMetrics(timestamp: params.timestamp)
            )
        case "Network.loadingFailed":
            let params = try decode(LoadingFailedParams.self, from: event)
            return .loadingFailed(
                id: Network.Request.ID(params.requestId),
                errorText: params.errorText,
                canceled: params.canceled ?? false,
                timestamp: params.timestamp
            )
        case "Network.requestServedFromMemoryCache":
            let params = try decode(RequestServedFromMemoryCacheParams.self, from: event)
            return .requestServedFromMemoryCache(
                id: Network.Request.ID(params.requestId),
                response: params.resource.proxyResponse,
                resourceType: Network.ResourceType(rawValue: params.resource.type),
                timestamp: params.timestamp
            )
        case "Network.webSocketCreated":
            let params = try decode(WebSocketCreatedParams.self, from: event)
            return .webSocket(.created(id: Network.Request.ID(params.requestId), url: params.url))
        case "Network.webSocketWillSendHandshakeRequest":
            let params = try decode(WebSocketWillSendHandshakeRequestParams.self, from: event)
            return .webSocket(.handshakeRequest(
                id: Network.Request.ID(params.requestId),
                request: params.request.proxyRequest(id: params.requestId),
                timestamp: params.timestamp
            ))
        case "Network.webSocketHandshakeResponseReceived":
            let params = try decode(WebSocketHandshakeResponseReceivedParams.self, from: event)
            return .webSocket(.handshakeResponse(
                id: Network.Request.ID(params.requestId),
                response: params.response.proxyResponse(fallbackURL: nil),
                timestamp: params.timestamp
            ))
        case "Network.webSocketFrameReceived":
            let params = try decode(WebSocketFrameParams.self, from: event)
            return .webSocket(.frameReceived(
                id: Network.Request.ID(params.requestId),
                frame: params.response.proxyFrame,
                timestamp: params.timestamp
            ))
        case "Network.webSocketFrameSent":
            let params = try decode(WebSocketFrameParams.self, from: event)
            return .webSocket(.frameSent(
                id: Network.Request.ID(params.requestId),
                frame: params.response.proxyFrame,
                timestamp: params.timestamp
            ))
        case "Network.webSocketFrameError":
            let params = try decode(WebSocketFrameErrorParams.self, from: event)
            return .webSocket(.error(
                id: Network.Request.ID(params.requestId),
                message: params.errorMessage,
                timestamp: params.timestamp
            ))
        case "Network.webSocketClosed":
            let params = try decode(WebSocketClosedParams.self, from: event)
            return .webSocket(.closed(id: Network.Request.ID(params.requestId), timestamp: params.timestamp))
        default:
            return .unknown(rawEvent(from: event))
        }
    }

    private static func consoleEvent(from event: ProtocolEvent) throws -> Console.Event {
        switch event.method {
        case "Console.messageAdded":
            let params = try decode(MessageAddedParams.self, from: event)
            return .messageAdded(params.message.proxyMessage)
        case "Console.messageRepeatCountUpdated":
            let params = try decode(MessageRepeatCountUpdatedParams.self, from: event)
            return .messageRepeatCountUpdated(count: params.count, timestamp: params.timestamp)
        case "Console.messagesCleared":
            let params = try decode(MessagesClearedParams.self, from: event)
            return .messagesCleared(reason: Console.ClearReason(rawValue: params.reason))
        default:
            return .unknown(rawEvent(from: event))
        }
    }

    private static func runtimeEvent(from event: ProtocolEvent, targetID: WebInspectorTarget.ID) throws -> Runtime.Event {
        switch event.method {
        case "Runtime.executionContextCreated":
            let params = try decode(ExecutionContextCreatedParams.self, from: event)
            return .executionContextCreated(params.context.proxyContext)
        case "Runtime.executionContextDestroyed":
            let params = try decode(ExecutionContextDestroyedParams.self, from: event)
            return .executionContextDestroyed(Runtime.ExecutionContext.ID(params.executionContextId))
        case "Runtime.executionContextsCleared":
            return .executionContextsCleared(target: targetID)
        default:
            return .unknown(rawEvent(from: event))
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from event: ProtocolEvent) throws -> T {
        try liveProxyDecode(type, from: event.paramsData)
    }

    private static func rawEvent(from event: ProtocolEvent) -> RawEvent {
        RawEvent(domain: event.domain.description, method: shortMethodName(event.method), params: event.paramsData)
    }

    private static func shortMethodName(_ method: String) -> String {
        method.split(separator: ".", maxSplits: 1).last.map(String.init) ?? method
    }
}

private struct TargetCommittedParams: Decodable {
    var oldTargetId: String?
    var newTargetId: String
}

private struct TargetDestroyedParams: Decodable {
    var targetId: String
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

    var proxyFrame: WebInspectorPageFrameLifecycle {
        WebInspectorPageFrameLifecycle(
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
    var previousNodeId: String?
    var node: ProtocolDOMNodePayload

    private enum CodingKeys: String, CodingKey {
        case parentNodeId
        case previousNodeId
        case node
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parentNodeId = try container.decodeStringOrInteger(forKey: .parentNodeId)
        previousNodeId = try container.decodeStringOrIntegerIfPresent(forKey: .previousNodeId)
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

private struct StyleSheetAddedParams: Decodable {
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

private struct StyleSheetHeaderPayload: Decodable {
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
    var request: RequestPayload
    var type: String?
    var redirectResponse: ResponsePayload?
    var timestamp: Double
    var backendResourceIdentifier: BackendResourceIdentifierPayload?
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
    var resource: CachedResourcePayload
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
        backendResourceIdentifier: Network.BackendResourceID? = nil
    ) -> Network.Request {
        Network.Request(
            id: Network.Request.ID(id),
            url: url,
            method: method ?? "GET",
            headers: headers ?? [:],
            postData: postData,
            referrerPolicy: referrerPolicy.map(Network.ReferrerPolicy.init(rawValue:)),
            integrity: integrity,
            backendResourceIdentifier: backendResourceIdentifier
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
