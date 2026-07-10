import Foundation

package enum ConnectionEventProjection {
    package nonisolated static func projectedDOMBootstrapNode(
        _ node: DOM.Node,
        target: ModelTarget
    ) -> DOM.Node {
        guard target.kind == .frame else {
            return node
        }
        return scopedDOMNode(node, targetRawValue: target.id.rawValue)
    }

    package nonisolated static func shouldDeliver(
        _ event: ProtocolEvent,
        to route: RoutingTargetID,
        in snapshot: TransportSession.Snapshot
    ) -> Bool {
        switch route.storage {
        case let .target(rawValue):
            if let targetID = event.targetID {
                return targetID.rawValue == rawValue
            }
            return snapshot.currentMainPageTargetID?.rawValue == rawValue
        case .currentPage:
            if event.domain == .target,
               event.method == "Target.targetDestroyed" {
                // The registry has already dropped the destroyed record, so
                // route by the event-time fact: only the destruction of the
                // then-current main page belongs to the semantic page route.
                return event.destroyedCurrentMainPageTarget
            }
            guard let currentMainPageTargetID = snapshot.currentMainPageTargetID else {
                return false
            }
            guard let targetID = event.targetID else {
                return true
            }
            if targetID == currentMainPageTargetID {
                return true
            }
            guard let record = snapshot.targetsByID[targetID] else {
                return false
            }
            // WebKit may report subframe domain activity on frame targets while
            // WebInspectorKit exposes a semantic current page.
            switch event.domain {
            case .dom:
                guard event.method != "DOM.documentUpdated" else {
                    return false
                }
                return Self.isCurrentPageFrameTarget(record, in: snapshot, currentMainPageTargetID: currentMainPageTargetID)
            case .inspector:
                // Inspector excludes frame targets in WebKit's protocol. A
                // frame-origin inspect event is not a state this projection
                // boundary supports or rewrites into a page event.
                return false
            case .network:
                // WebKit's page/ProxyingNetworkAgent owns process-wide
                // Network.enable. This branch only projects target-wrapped
                // frame Network events if WebKit emits them.
                return Self.isCurrentPageFrameTarget(record, in: snapshot, currentMainPageTargetID: currentMainPageTargetID)
            case .css:
                return Self.isCurrentPageFrameTarget(record, in: snapshot, currentMainPageTargetID: currentMainPageTargetID)
            case .console:
                return Self.isCurrentPageFrameTarget(record, in: snapshot, currentMainPageTargetID: currentMainPageTargetID)
            case .runtime:
                return Self.isCurrentPageFrameTarget(record, in: snapshot, currentMainPageTargetID: currentMainPageTargetID)
            default:
                return false
            }
        }
    }

    private nonisolated static func isCurrentPageFrameTarget(
        _ record: ProtocolTarget.Record,
        in snapshot: TransportSession.Snapshot,
        currentMainPageTargetID: ProtocolTarget.ID
    ) -> Bool {
        guard record.kind == .frame,
              let mainFrameID = snapshot.targetsByID[currentMainPageTargetID]?.frameID else {
            return false
        }

        guard var parentFrameID = record.parentFrameID else {
            // WebKit may omit parentFrameId for a cross-origin frame target even
            // though its frameId differs from the current page's main frame.
            // TransportTargetRegistry already classifies that target as .frame;
            // the current-page route must preserve the same semantic boundary
            // or picker, DOM, and Network events are silently filtered.
            guard let frameID = record.frameID else {
                return false
            }
            return frameID != mainFrameID
        }

        var visitedFrameIDs = Set<ProtocolFrame.ID>()
        while visitedFrameIDs.insert(parentFrameID).inserted {
            if parentFrameID == mainFrameID {
                return true
            }
            guard let parentTargetID = snapshot.frameTargetIDsByFrameID[parentFrameID],
                  let parentRecord = snapshot.targetsByID[parentTargetID],
                  let nextParentFrameID = parentRecord.parentFrameID else {
                return false
            }
            parentFrameID = nextParentFrameID
        }
        return false
    }

    package nonisolated static func projectedEvent(
        _ proxyEvent: WebInspectorProxyEvent,
        from event: ProtocolEvent,
        route: RoutingTargetID,
        in snapshot: TransportSession.Snapshot
    ) -> WebInspectorProxyEvent {
        let scopedProxyEvent = Self.scopedAgentOwnedEvent(proxyEvent, from: event, route: route, snapshot: snapshot)
        guard case .currentPage = route.storage,
              let targetID = event.targetID else {
            return scopedProxyEvent
        }
        guard let currentMainPageTargetID = snapshot.currentMainPageTargetID,
              targetID != currentMainPageTargetID,
              let record = snapshot.targetsByID[targetID],
              Self.isCurrentPageFrameTarget(record, in: snapshot, currentMainPageTargetID: currentMainPageTargetID) else {
            return scopedProxyEvent
        }
        switch scopedProxyEvent {
        case let .dom(domEvent):
            return .dom(Self.scopedDOMEvent(domEvent, targetRawValue: targetID.rawValue))
        case let .css(cssEvent):
            return .css(Self.scopedCSSEvent(cssEvent, targetRawValue: targetID.rawValue))
        case let .network(networkEvent):
            return .network(Self.scopedNetworkEvent(networkEvent, targetRawValue: targetID.rawValue))
        default:
            return scopedProxyEvent
        }
    }

    private nonisolated static func scopedAgentOwnedEvent(
        _ proxyEvent: WebInspectorProxyEvent,
        from event: ProtocolEvent,
        route: RoutingTargetID,
        snapshot: TransportSession.Snapshot
    ) -> WebInspectorProxyEvent {
        let targetScopeRawValue = runtimeAgentScopeRawValue(for: event, route: route, snapshot: snapshot)
        switch proxyEvent {
        case let .runtime(runtimeEvent):
            return .runtime(scopedRuntimeEvent(runtimeEvent, targetScopeRawValue: targetScopeRawValue))
        case let .console(targetedEvent):
            return .console(Console.TargetedEvent(
                event: scopedConsoleEvent(targetedEvent.event, targetScopeRawValue: targetScopeRawValue),
                targetID: targetedEvent.targetID
            ))
        case .targetLifecycle, .dom, .inspector, .css, .network:
            return proxyEvent
        }
    }

    private nonisolated static func runtimeAgentScopeRawValue(
        for event: ProtocolEvent,
        route: RoutingTargetID,
        snapshot: TransportSession.Snapshot
    ) -> String? {
        let agentTargetID = event.sourceTargetID ?? event.targetID
        guard let agentTargetID else {
            return nil
        }
        if agentTargetID == snapshot.currentMainPageTargetID {
            return nil
        }
        if let record = snapshot.targetsByID[agentTargetID],
           record.kind == .page,
           record.parentFrameID == nil {
            return nil
        }
        return agentTargetID.rawValue
    }

    private nonisolated static func scopedDOMEvent(
        _ event: DOM.Event,
        targetRawValue: String
    ) -> DOM.Event {
        switch event {
        case .documentUpdated:
            .documentUpdated
        case let .setChildNodes(parent, nodes):
            .setChildNodes(
                parent: scopedDOMNodeID(parent, targetRawValue: targetRawValue),
                nodes: nodes.map { scopedDOMNode($0, targetRawValue: targetRawValue) }
            )
        case let .detachedRoot(node):
            .detachedRoot(scopedDOMNode(node, targetRawValue: targetRawValue))
        case let .childNodeInserted(parent, previous, node):
            .childNodeInserted(
                parent: scopedDOMNodeID(parent, targetRawValue: targetRawValue),
                previous: previous.map { scopedDOMNodeID($0, targetRawValue: targetRawValue) },
                node: scopedDOMNode(node, targetRawValue: targetRawValue)
            )
        case let .childNodeRemoved(parent, node):
            .childNodeRemoved(
                parent: scopedDOMNodeID(parent, targetRawValue: targetRawValue),
                node: scopedDOMNodeID(node, targetRawValue: targetRawValue)
            )
        case let .childNodeCountUpdated(node, count):
            .childNodeCountUpdated(scopedDOMNodeID(node, targetRawValue: targetRawValue), count: count)
        case let .attributeModified(node, name, value):
            .attributeModified(scopedDOMNodeID(node, targetRawValue: targetRawValue), name: name, value: value)
        case let .attributeRemoved(node, name):
            .attributeRemoved(scopedDOMNodeID(node, targetRawValue: targetRawValue), name: name)
        case let .inlineStyleInvalidated(nodes):
            .inlineStyleInvalidated(nodes.map { scopedDOMNodeID($0, targetRawValue: targetRawValue) })
        case let .characterDataModified(node, value):
            .characterDataModified(scopedDOMNodeID(node, targetRawValue: targetRawValue), value: value)
        case let .shadowRootPushed(host, root):
            .shadowRootPushed(
                host: scopedDOMNodeID(host, targetRawValue: targetRawValue),
                root: scopedDOMNode(root, targetRawValue: targetRawValue)
            )
        case let .shadowRootPopped(host, root):
            .shadowRootPopped(
                host: scopedDOMNodeID(host, targetRawValue: targetRawValue),
                root: scopedDOMNodeID(root, targetRawValue: targetRawValue)
            )
        case let .pseudoElementAdded(parent, element):
            .pseudoElementAdded(
                parent: scopedDOMNodeID(parent, targetRawValue: targetRawValue),
                element: scopedDOMNode(element, targetRawValue: targetRawValue)
            )
        case let .pseudoElementRemoved(parent, element):
            .pseudoElementRemoved(
                parent: scopedDOMNodeID(parent, targetRawValue: targetRawValue),
                element: scopedDOMNodeID(element, targetRawValue: targetRawValue)
            )
        case let .willDestroyDOMNode(node):
            .willDestroyDOMNode(scopedDOMNodeID(node, targetRawValue: targetRawValue))
        case let .inspect(node):
            .inspect(scopedDOMNodeID(node, targetRawValue: targetRawValue))
        case let .unknown(rawEvent):
            .unknown(rawEvent)
        }
    }

    private nonisolated static func scopedDOMNode(
        _ node: DOM.Node,
        targetRawValue: String
    ) -> DOM.Node {
        DOM.Node(
            id: scopedDOMNodeID(node.id, targetRawValue: targetRawValue),
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
            children: node.children?.map { scopedDOMNode($0, targetRawValue: targetRawValue) },
            contentDocument: node.contentDocument.map { scopedDOMNode($0, targetRawValue: targetRawValue) },
            shadowRoots: node.shadowRoots.map { scopedDOMNode($0, targetRawValue: targetRawValue) },
            templateContent: node.templateContent.map { scopedDOMNode($0, targetRawValue: targetRawValue) },
            beforePseudoElement: node.beforePseudoElement.map { scopedDOMNode($0, targetRawValue: targetRawValue) },
            otherPseudoElements: node.otherPseudoElements.map { scopedDOMNode($0, targetRawValue: targetRawValue) },
            afterPseudoElement: node.afterPseudoElement.map { scopedDOMNode($0, targetRawValue: targetRawValue) },
            pseudoType: node.pseudoType,
            shadowRootType: node.shadowRootType
        )
    }

    private nonisolated static func scopedDOMNodeID(
        _ id: DOM.Node.ID,
        targetRawValue: String
    ) -> DOM.Node.ID {
        guard id.targetScopeRawValue == nil else {
            return id
        }
        return DOM.Node.ID(id.rawValue, scopedToTargetRawValue: targetRawValue)
    }

    private nonisolated static func scopedCSSEvent(
        _ event: CSS.Event,
        targetRawValue: String
    ) -> CSS.Event {
        switch event {
        case let .styleSheetChanged(id):
            .styleSheetChanged(scopedStyleSheetID(id, targetRawValue: targetRawValue))
        case let .styleSheetAdded(header):
            .styleSheetAdded(CSS.StyleSheetHeader(
                styleSheetID: scopedStyleSheetID(header.styleSheetID, targetRawValue: targetRawValue),
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
            .styleSheetRemoved(scopedStyleSheetID(id, targetRawValue: targetRawValue))
        case .mediaQueryResultChanged:
            .mediaQueryResultChanged
        case let .nodeLayoutFlagsChanged(id):
            .nodeLayoutFlagsChanged(scopedDOMNodeID(id, targetRawValue: targetRawValue))
        case let .unknown(rawEvent):
            .unknown(rawEvent)
        }
    }

    private nonisolated static func scopedStyleSheetID(
        _ id: CSS.StyleSheet.ID,
        targetRawValue: String
    ) -> CSS.StyleSheet.ID {
        guard id.targetScopeRawValue == nil else {
            return id
        }
        return CSS.StyleSheet.ID(id.rawValue, scopedToTargetRawValue: targetRawValue)
    }

    private nonisolated static func scopedRuntimeEvent(
        _ event: Runtime.Event,
        targetScopeRawValue: String?
    ) -> Runtime.Event {
        guard let targetScopeRawValue else {
            return event
        }
        switch event {
        case let .executionContextCreated(context):
            return .executionContextCreated(Runtime.ExecutionContext(
                id: scopedExecutionContextID(context.id, targetRawValue: targetScopeRawValue),
                name: context.name,
                frameID: context.frameID,
                kind: context.kind
            ))
        case let .executionContextDestroyed(id):
            return .executionContextDestroyed(scopedExecutionContextID(id, targetRawValue: targetScopeRawValue))
        case .executionContextsCleared:
            return .executionContextsCleared(target: WebInspectorTarget.ID(targetScopeRawValue))
        case let .unknown(rawEvent):
            return .unknown(rawEvent)
        }
    }

    private nonisolated static func scopedExecutionContextID(
        _ id: Runtime.ExecutionContext.ID,
        targetRawValue: String
    ) -> Runtime.ExecutionContext.ID {
        guard id.targetScopeRawValue == nil else {
            return id
        }
        return Runtime.ExecutionContext.ID(id.rawValue, scopedToTargetRawValue: targetRawValue)
    }

    private nonisolated static func scopedConsoleEvent(
        _ event: Console.Event,
        targetScopeRawValue: String?
    ) -> Console.Event {
        guard let targetScopeRawValue else {
            return event
        }
        switch event {
        case let .messageAdded(message):
            return .messageAdded(scopedConsoleMessage(message, targetRawValue: targetScopeRawValue))
        case let .messageRepeatCountUpdated(count, timestamp):
            return .messageRepeatCountUpdated(count: count, timestamp: timestamp)
        case let .messagesCleared(reason):
            return .messagesCleared(reason: reason)
        case let .unknown(rawEvent):
            return .unknown(rawEvent)
        }
    }

    private nonisolated static func scopedConsoleMessage(
        _ message: Console.Message,
        targetRawValue: String
    ) -> Console.Message {
        Console.Message(
            source: message.source,
            level: message.level,
            type: message.type,
            text: message.text,
            url: message.url,
            line: message.line,
            column: message.column,
            repeatCount: message.repeatCount,
            parameters: message.parameters.map { scopedRemoteObject($0, targetRawValue: targetRawValue) },
            stackTrace: message.stackTrace,
            networkRequestID: message.networkRequestID.map {
                scopedNetworkRequestID($0, targetRawValue: targetRawValue)
            },
            timestamp: message.timestamp
        )
    }

    private nonisolated static func scopedRemoteObject(
        _ object: Runtime.RemoteObject,
        targetRawValue: String
    ) -> Runtime.RemoteObject {
        Runtime.RemoteObject(
            id: object.id.map { scopedRemoteObjectID($0, targetRawValue: targetRawValue) },
            kind: object.kind,
            subtype: object.subtype,
            className: object.className,
            description: object.description,
            value: object.value,
            size: object.size,
            preview: object.preview
        )
    }

    private nonisolated static func scopedRemoteObjectID(
        _ id: Runtime.RemoteObject.ID,
        targetRawValue: String
    ) -> Runtime.RemoteObject.ID {
        guard id.targetScopeRawValue == nil else {
            return id
        }
        return Runtime.RemoteObject.ID(id.rawValue, scopedToTargetRawValue: targetRawValue)
    }

    private nonisolated static func scopedNetworkEvent(
        _ event: Network.Event,
        targetRawValue: String
    ) -> Network.Event {
        switch event {
        case let .requestWillBeSent(id, request, resourceType, redirectResponse, timestamp):
            .requestWillBeSent(
                id: scopedNetworkRequestID(id, targetRawValue: targetRawValue),
                request: scopedNetworkRequest(request, targetRawValue: targetRawValue),
                resourceType: resourceType,
                redirectResponse: redirectResponse,
                timestamp: timestamp
            )
        case let .responseReceived(id, response, resourceType, timestamp):
            .responseReceived(
                id: scopedNetworkRequestID(id, targetRawValue: targetRawValue),
                response: response,
                resourceType: resourceType,
                timestamp: timestamp
            )
        case let .dataReceived(id, dataLength, encodedDataLength, timestamp):
            .dataReceived(
                id: scopedNetworkRequestID(id, targetRawValue: targetRawValue),
                dataLength: dataLength,
                encodedDataLength: encodedDataLength,
                timestamp: timestamp
            )
        case let .loadingFinished(id, timestamp, sourceMapURL, metrics):
            .loadingFinished(
                id: scopedNetworkRequestID(id, targetRawValue: targetRawValue),
                timestamp: timestamp,
                sourceMapURL: sourceMapURL,
                metrics: metrics
            )
        case let .loadingFailed(id, errorText, canceled, timestamp):
            .loadingFailed(
                id: scopedNetworkRequestID(id, targetRawValue: targetRawValue),
                errorText: errorText,
                canceled: canceled,
                timestamp: timestamp
            )
        case let .requestServedFromMemoryCache(id, response, resourceType, timestamp):
            .requestServedFromMemoryCache(
                id: scopedNetworkRequestID(id, targetRawValue: targetRawValue),
                response: response,
                resourceType: resourceType,
                timestamp: timestamp
            )
        case let .webSocket(event):
            .webSocket(scopedWebSocketEvent(event, targetRawValue: targetRawValue))
        case let .unknown(rawEvent):
            .unknown(rawEvent)
        }
    }

    private nonisolated static func scopedWebSocketEvent(
        _ event: Network.WebSocketEvent,
        targetRawValue: String
    ) -> Network.WebSocketEvent {
        switch event {
        case let .created(id, url):
            .created(id: scopedNetworkRequestID(id, targetRawValue: targetRawValue), url: url)
        case let .handshakeRequest(id, request, timestamp):
            .handshakeRequest(
                id: scopedNetworkRequestID(id, targetRawValue: targetRawValue),
                request: scopedNetworkRequest(request, targetRawValue: targetRawValue),
                timestamp: timestamp
            )
        case let .handshakeResponse(id, response, timestamp):
            .handshakeResponse(
                id: scopedNetworkRequestID(id, targetRawValue: targetRawValue),
                response: response,
                timestamp: timestamp
            )
        case let .closed(id, timestamp):
            .closed(id: scopedNetworkRequestID(id, targetRawValue: targetRawValue), timestamp: timestamp)
        case let .frameSent(id, frame, timestamp):
            .frameSent(id: scopedNetworkRequestID(id, targetRawValue: targetRawValue), frame: frame, timestamp: timestamp)
        case let .frameReceived(id, frame, timestamp):
            .frameReceived(id: scopedNetworkRequestID(id, targetRawValue: targetRawValue), frame: frame, timestamp: timestamp)
        case let .error(id, message, timestamp):
            .error(id: scopedNetworkRequestID(id, targetRawValue: targetRawValue), message: message, timestamp: timestamp)
        case let .other(rawEvent):
            .other(rawEvent)
        }
    }

    private nonisolated static func scopedNetworkRequest(
        _ request: Network.Request,
        targetRawValue: String
    ) -> Network.Request {
        Network.Request(
            id: scopedNetworkRequestID(request.id, targetRawValue: targetRawValue),
            url: request.url,
            method: request.method,
            headers: request.headers,
            postData: request.postData,
            referrerPolicy: request.referrerPolicy,
            integrity: request.integrity,
            backendResourceIdentifier: request.backendResourceIdentifier
        )
    }

    private nonisolated static func scopedNetworkRequestID(
        _ id: Network.Request.ID,
        targetRawValue: String
    ) -> Network.Request.ID {
        guard id.targetScopeRawValue == nil else {
            return id
        }
        return Network.Request.ID(id.rawValue, scopedToTargetRawValue: targetRawValue)
    }

    package nonisolated static func lifecycleTarget(
        for event: ProtocolEvent,
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        in snapshot: TransportSession.Snapshot
    ) -> WebInspectorLifecycleTarget? {
        guard event.domain == .target,
              event.method == "Target.didCommitProvisionalTarget",
              let protocolTargetID = event.targetID else {
            return nil
        }
        guard let record = snapshot.targetsByID[protocolTargetID] else {
            return nil
        }
        return WebInspectorLifecycleTarget(
            semanticID: Self.semanticTargetID(for: route, targetID: targetID),
            record: record
        )
    }

    private nonisolated static func semanticTargetID(
        for route: RoutingTargetID,
        targetID: WebInspectorTarget.ID
    ) -> WebInspectorTarget.ID {
        switch route.storage {
        case .currentPage:
            .currentPage
        case .target:
            targetID
        }
    }
}
