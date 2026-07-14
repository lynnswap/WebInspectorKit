import Foundation

package enum DomainEventIdentityScope {
    package static func domNode(_ node: DOM.Node, target: String) -> DOM.Node {
        DOM.Node(
            id: domNodeID(node.id, target: target),
            nodeType: node.nodeType,
            nodeName: node.nodeName,
            localName: node.localName,
            nodeValue: node.nodeValue,
            frameID: node.frameID,
            documentURL: node.documentURL,
            baseURL: node.baseURL,
            attributes: node.attributes,
            attributeList: node.attributeList,
            childNodeCount: node.childNodeCount,
            children: node.children?.map { domNode($0, target: target) },
            contentDocument: node.contentDocument.map { domNode($0, target: target) },
            shadowRoots: node.shadowRoots.map { domNode($0, target: target) },
            templateContent: node.templateContent.map { domNode($0, target: target) },
            beforePseudoElement: node.beforePseudoElement.map { domNode($0, target: target) },
            otherPseudoElements: node.otherPseudoElements.map { domNode($0, target: target) },
            afterPseudoElement: node.afterPseudoElement.map { domNode($0, target: target) },
            pseudoType: node.pseudoType,
            shadowRootType: node.shadowRootType
        )
    }

    package static func domEvent(_ event: DOM.Event, target: String) -> DOM.Event {
        switch event {
        case .documentUpdated:
            .documentUpdated
        case let .setChildNodes(parent, nodes):
            .setChildNodes(parent: domNodeID(parent, target: target), nodes: nodes.map { domNode($0, target: target) })
        case let .detachedRoot(node):
            .detachedRoot(domNode(node, target: target))
        case let .childNodeInserted(parent, previous, node):
            .childNodeInserted(
                parent: domNodeID(parent, target: target),
                previous: previous.map { domNodeID($0, target: target) },
                node: domNode(node, target: target)
            )
        case let .childNodeRemoved(parent, node):
            .childNodeRemoved(parent: domNodeID(parent, target: target), node: domNodeID(node, target: target))
        case let .childNodeCountUpdated(node, count):
            .childNodeCountUpdated(domNodeID(node, target: target), count: count)
        case let .attributeModified(node, name, value):
            .attributeModified(domNodeID(node, target: target), name: name, value: value)
        case let .attributeRemoved(node, name):
            .attributeRemoved(domNodeID(node, target: target), name: name)
        case let .inlineStyleInvalidated(nodes):
            .inlineStyleInvalidated(nodes.map { domNodeID($0, target: target) })
        case let .characterDataModified(node, value):
            .characterDataModified(domNodeID(node, target: target), value: value)
        case let .shadowRootPushed(host, root):
            .shadowRootPushed(host: domNodeID(host, target: target), root: domNode(root, target: target))
        case let .shadowRootPopped(host, root):
            .shadowRootPopped(host: domNodeID(host, target: target), root: domNodeID(root, target: target))
        case let .pseudoElementAdded(parent, element):
            .pseudoElementAdded(parent: domNodeID(parent, target: target), element: domNode(element, target: target))
        case let .pseudoElementRemoved(parent, element):
            .pseudoElementRemoved(parent: domNodeID(parent, target: target), element: domNodeID(element, target: target))
        case let .willDestroyDOMNode(node):
            .willDestroyDOMNode(domNodeID(node, target: target))
        case let .inspect(node):
            .inspect(domNodeID(node, target: target))
        case let .unknown(raw):
            .unknown(raw)
        }
    }

    package static func cssEvent(_ event: CSS.Event, target: String) -> CSS.Event {
        switch event {
        case let .styleSheetChanged(id):
            .styleSheetChanged(styleSheetID(id, target: target))
        case let .styleSheetAdded(header):
            .styleSheetAdded(CSS.StyleSheetHeader(
                styleSheetID: styleSheetID(header.styleSheetID, target: target),
                frameID: header.frameID,
                sourceURL: header.sourceURL,
                origin: header.origin,
                title: header.title,
                disabled: header.disabled,
                isInline: header.isInline,
                startLine: header.startLine,
                startColumn: header.startColumn
            ))
        case let .styleSheetRemoved(id):
            .styleSheetRemoved(styleSheetID(id, target: target))
        case .mediaQueryResultChanged:
            .mediaQueryResultChanged
        case let .nodeLayoutFlagsChanged(node):
            .nodeLayoutFlagsChanged(domNodeID(node, target: target))
        case let .unknown(raw):
            .unknown(raw)
        }
    }

    package static func runtimeEvent(_ event: Runtime.Event, target: String) -> Runtime.Event {
        switch event {
        case let .executionContextCreated(context):
            .executionContextCreated(Runtime.ExecutionContext(
                id: executionContextID(context.id, target: target),
                name: context.name,
                frameID: context.frameID,
                kind: context.kind
            ))
        case let .executionContextDestroyed(id):
            .executionContextDestroyed(executionContextID(id, target: target))
        case .executionContextsCleared:
            .executionContextsCleared
        case let .unknown(raw):
            .unknown(raw)
        }
    }

    package static func inspectorEvent(_ event: Inspector.Event, target: String) -> Inspector.Event {
        switch event {
        case let .inspect(object, hints):
            .inspect(remoteObject(object, target: target), hints: hints)
        case let .unknown(raw):
            .unknown(raw)
        }
    }

    package static func consoleEvent(_ event: Console.Event, target: String) -> Console.Event {
        switch event {
        case let .messageAdded(message):
            .messageAdded(Console.Message(
                source: message.source,
                level: message.level,
                type: message.type,
                text: message.text,
                url: message.url,
                line: message.line,
                column: message.column,
                repeatCount: message.repeatCount,
                parameters: message.parameters.map { remoteObject($0, target: target) },
                stackTrace: message.stackTrace,
                networkRequestID: message.networkRequestID.map { networkRequestID($0, target: target) },
                timestamp: message.timestamp
            ))
        case let .messageRepeatCountUpdated(count, timestamp):
            .messageRepeatCountUpdated(count: count, timestamp: timestamp)
        case let .messagesCleared(reason):
            .messagesCleared(reason: reason)
        case let .unknown(raw):
            .unknown(raw)
        }
    }

    package static func networkEvent(_ event: Network.Event, target: String) -> Network.Event {
        switch event {
        case let .requestWillBeSent(id, request, initiator, resourceType, redirectResponse, timestamp):
            .requestWillBeSent(
                id: networkRequestID(id, target: target),
                request: networkRequest(request, target: target),
                initiator: networkInitiator(initiator, target: target),
                resourceType: resourceType,
                redirectResponse: redirectResponse,
                timestamp: timestamp
            )
        case let .responseReceived(id, response, resourceType, timestamp):
            .responseReceived(id: networkRequestID(id, target: target), response: response, resourceType: resourceType, timestamp: timestamp)
        case let .dataReceived(id, dataLength, encodedDataLength, timestamp):
            .dataReceived(id: networkRequestID(id, target: target), dataLength: dataLength, encodedDataLength: encodedDataLength, timestamp: timestamp)
        case let .loadingFinished(id, timestamp, sourceMapURL, metrics):
            .loadingFinished(id: networkRequestID(id, target: target), timestamp: timestamp, sourceMapURL: sourceMapURL, metrics: metrics)
        case let .loadingFailed(id, errorText, canceled, timestamp):
            .loadingFailed(id: networkRequestID(id, target: target), errorText: errorText, canceled: canceled, timestamp: timestamp)
        case let .requestServedFromMemoryCache(id, response, initiator, resourceType, timestamp):
            .requestServedFromMemoryCache(
                id: networkRequestID(id, target: target),
                response: response,
                initiator: networkInitiator(initiator, target: target),
                resourceType: resourceType,
                timestamp: timestamp
            )
        case let .webSocket(event):
            .webSocket(webSocketEvent(event, target: target))
        case let .unknown(raw):
            .unknown(raw)
        }
    }

    private static func domNodeID(_ id: DOM.Node.ID, target: String) -> DOM.Node.ID {
        id.targetScopeRawValue == nil ? DOM.Node.ID(id.rawValue, scopedToTargetRawValue: target) : id
    }

    private static func styleSheetID(_ id: CSS.StyleSheet.ID, target: String) -> CSS.StyleSheet.ID {
        id.targetScopeRawValue == nil ? CSS.StyleSheet.ID(id.rawValue, scopedToTargetRawValue: target) : id
    }

    private static func executionContextID(
        _ id: Runtime.ExecutionContext.ID,
        target: String
    ) -> Runtime.ExecutionContext.ID {
        id.targetScopeRawValue == nil ? Runtime.ExecutionContext.ID(id.rawValue, scopedToTargetRawValue: target) : id
    }

    private static func remoteObject(_ object: Runtime.RemoteObject, target: String) -> Runtime.RemoteObject {
        Runtime.RemoteObject(
            id: object.id.map { remoteObjectID($0, target: target) },
            kind: object.kind,
            subtype: object.subtype,
            className: object.className,
            description: object.description,
            value: object.value,
            size: object.size,
            preview: object.preview
        )
    }

    private static func remoteObjectID(_ id: Runtime.RemoteObject.ID, target: String) -> Runtime.RemoteObject.ID {
        id.targetScopeRawValue == nil ? Runtime.RemoteObject.ID(id.rawValue, scopedToTargetRawValue: target) : id
    }

    private static func networkRequestID(_ id: Network.Request.ID, target: String) -> Network.Request.ID {
        id.targetScopeRawValue == nil ? Network.Request.ID(id.rawValue, scopedToTargetRawValue: target) : id
    }

    private static func networkRequest(_ request: Network.Request, target: String) -> Network.Request {
        Network.Request(
            id: networkRequestID(request.id, target: target),
            url: request.url,
            method: request.method,
            headers: request.headers,
            postData: request.postData,
            referrerPolicy: request.referrerPolicy,
            integrity: request.integrity,
            backendResourceIdentifier: request.backendResourceIdentifier,
            origin: request.origin
        )
    }

    private static func networkInitiator(_ initiator: Network.Initiator, target: String) -> Network.Initiator {
        Network.Initiator(
            kind: initiator.kind,
            url: initiator.url,
            line: initiator.line,
            column: initiator.column,
            nodeID: initiator.nodeID.map { domNodeID($0, target: target) }
        )
    }

    private static func webSocketEvent(_ event: Network.WebSocketEvent, target: String) -> Network.WebSocketEvent {
        switch event {
        case let .created(id, url):
            .created(id: networkRequestID(id, target: target), url: url)
        case let .handshakeRequest(id, request, timestamp):
            .handshakeRequest(id: networkRequestID(id, target: target), request: networkRequest(request, target: target), timestamp: timestamp)
        case let .handshakeResponse(id, response, timestamp):
            .handshakeResponse(id: networkRequestID(id, target: target), response: response, timestamp: timestamp)
        case let .closed(id, timestamp):
            .closed(id: networkRequestID(id, target: target), timestamp: timestamp)
        case let .frameSent(id, frame, timestamp):
            .frameSent(id: networkRequestID(id, target: target), frame: frame, timestamp: timestamp)
        case let .frameReceived(id, frame, timestamp):
            .frameReceived(id: networkRequestID(id, target: target), frame: frame, timestamp: timestamp)
        case let .error(id, message, timestamp):
            .error(id: networkRequestID(id, target: target), message: message, timestamp: timestamp)
        case let .other(raw):
            .other(raw)
        }
    }
}
