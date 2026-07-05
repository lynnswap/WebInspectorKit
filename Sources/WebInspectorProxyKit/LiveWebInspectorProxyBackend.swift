import Foundation

package struct LiveWebInspectorProxyBackend: WebInspectorProxyBackend {
    private let transport: TransportSession
    private let eventSubscriptions: LiveProxyEventSubscriptions

    package init(transport: TransportSession) {
        self.transport = transport
        eventSubscriptions = LiveProxyEventSubscriptions()
    }

    package func dispatchCommand<Payload: Sendable, Result: Sendable>(
        _ command: WebInspectorProxyCommand<Payload, Result>
    ) async throws -> Result {
        let protocolCommand = try LiveProxyCommandEncoder.protocolCommand(for: command)
        let result: ProtocolCommand.Result
        do {
            result = try await transport.send(protocolCommand)
        } catch {
            throw mapTransportError(error, domain: command.domain.rawValue, method: command.method)
        }
        return try LiveProxyCommandDecoder.decode(Result.self, for: command, from: result)
    }

    package func waitForEventSubscription(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        domain: WebInspectorProxyEventDomain
    ) async {
        await eventSubscriptions.waitForActiveSubscriber(
            LiveProxyEventSubscriptionKey(route: route, targetID: targetID, domain: domain)
        )
    }

    package nonisolated func events(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        domain: WebInspectorProxyEventDomain
    ) -> AsyncStream<WebInspectorProxyEvent> {
        AsyncStream<WebInspectorProxyEvent> { continuation in
            let key = LiveProxyEventSubscriptionKey(route: route, targetID: targetID, domain: domain)
            let task = Task {
                let stream = await transport.events(for: protocolDomain(for: domain))
                guard Task.isCancelled == false else {
                    continuation.finish()
                    return
                }
                await eventSubscriptions.register(key)
                for await event in stream {
                    guard Task.isCancelled == false else {
                        break
                    }
                    guard await shouldDeliver(event, to: route) else {
                        continue
                    }
                    do {
                        let lifecycleTarget = await lifecycleTarget(for: event, route: route, targetID: targetID)
                        let proxyEvent = try LiveProxyEventDecoder.proxyEvent(
                            from: event,
                            targetID: targetID,
                            lifecycleTarget: lifecycleTarget
                        )
                        continuation.yield(await projectedEvent(proxyEvent, from: event, route: route))
                    } catch {
                        preconditionFailure("Failed to decode \(event.method): \(error)")
                    }
                }
                await eventSubscriptions.unregister(key)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task {
                    await eventSubscriptions.unregister(key)
                }
            }
        }
    }

    private func mapTransportError(_ error: any Error, domain: String, method: String) -> any Error {
        guard let transportError = error as? TransportSession.Error else {
            return error
        }
        switch transportError {
        case .transportClosed:
            return WebInspectorProxyError.closed
        case let .replyTimeout(method, _):
            return WebInspectorProxyError.timeout(domain: domain, method: method)
        case let .remoteError(method, _, message):
            return WebInspectorProxyError.commandFailed(domain: domain, method: method, message: message)
        case .malformedMessage, .missingMainPageTarget, .missingTarget:
            return WebInspectorProxyError.commandFailed(
                domain: domain,
                method: method,
                message: "\(transportError)"
            )
        }
    }

    private nonisolated func shouldDeliver(_ event: ProtocolEvent, to route: RoutingTargetID) async -> Bool {
        switch route.storage {
        case let .target(rawValue):
            if let targetID = event.targetID {
                return targetID.rawValue == rawValue
            }
            let snapshot = await transport.snapshot()
            return snapshot.currentMainPageTargetID?.rawValue == rawValue
        case .currentPage:
            let snapshot = await transport.snapshot()
            if event.domain == .target,
               event.method == "Target.targetDestroyed",
               snapshot.currentMainPageTargetID == nil,
               event.targetID != nil {
                return true
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
            // WebKit reports subframe picker and request activity on frame
            // targets while WebInspectorKit exposes a semantic current page.
            switch event.domain {
            case .dom:
                guard event.method != "DOM.documentUpdated" else {
                    return false
                }
                return isCurrentPageFrameTarget(record, in: snapshot, currentMainPageTargetID: currentMainPageTargetID)
            case .inspector:
                return isCurrentPageFrameTarget(record, in: snapshot, currentMainPageTargetID: currentMainPageTargetID)
            case .network:
                // WebKit's page/ProxyingNetworkAgent owns process-wide
                // Network.enable. This branch only projects target-wrapped
                // frame Network events if WebKit emits them.
                return isCurrentPageFrameTarget(record, in: snapshot, currentMainPageTargetID: currentMainPageTargetID)
            default:
                return false
            }
        }
    }

    private nonisolated func isCurrentPageFrameTarget(
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

    private nonisolated func projectedEvent(
        _ proxyEvent: WebInspectorProxyEvent,
        from event: ProtocolEvent,
        route: RoutingTargetID
    ) async -> WebInspectorProxyEvent {
        guard case .currentPage = route.storage,
              let targetID = event.targetID else {
            return proxyEvent
        }
        let snapshot = await transport.snapshot()
        if event.domain == .inspector,
           targetID == snapshot.currentMainPageTargetID {
            return mainPageInspectorEvent(proxyEvent)
        }
        guard let currentMainPageTargetID = snapshot.currentMainPageTargetID,
              targetID != currentMainPageTargetID,
              let record = snapshot.targetsByID[targetID],
              isCurrentPageFrameTarget(record, in: snapshot, currentMainPageTargetID: currentMainPageTargetID) else {
            return proxyEvent
        }
        switch proxyEvent {
        case let .dom(domEvent):
            return .dom(scopedDOMEvent(domEvent, targetRawValue: targetID.rawValue))
        case let .network(networkEvent):
            return .network(scopedNetworkEvent(networkEvent, targetRawValue: targetID.rawValue))
        default:
            return proxyEvent
        }
    }

    private nonisolated func mainPageInspectorEvent(
        _ proxyEvent: WebInspectorProxyEvent
    ) -> WebInspectorProxyEvent {
        guard case let .inspector(event) = proxyEvent,
              case let .inspect(object, hints, _) = event else {
            return proxyEvent
        }
        return .inspector(.inspect(object, hints: hints, origin: nil))
    }

    private nonisolated func scopedDOMEvent(
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

    private nonisolated func scopedDOMNode(
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

    private nonisolated func scopedDOMNodeID(
        _ id: DOM.Node.ID,
        targetRawValue: String
    ) -> DOM.Node.ID {
        guard id.targetScopeRawValue == nil else {
            return id
        }
        return DOM.Node.ID(id.rawValue, scopedToTargetRawValue: targetRawValue)
    }

    private nonisolated func scopedNetworkEvent(
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
        case let .requestServedFromMemoryCache(id, response, timestamp):
            .requestServedFromMemoryCache(
                id: scopedNetworkRequestID(id, targetRawValue: targetRawValue),
                response: response,
                timestamp: timestamp
            )
        case let .webSocket(event):
            .webSocket(scopedWebSocketEvent(event, targetRawValue: targetRawValue))
        case let .unknown(rawEvent):
            .unknown(rawEvent)
        }
    }

    private nonisolated func scopedWebSocketEvent(
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

    private nonisolated func scopedNetworkRequest(
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
            integrity: request.integrity
        )
    }

    private nonisolated func scopedNetworkRequestID(
        _ id: Network.Request.ID,
        targetRawValue: String
    ) -> Network.Request.ID {
        guard id.targetScopeRawValue == nil else {
            return id
        }
        return Network.Request.ID(id.rawValue, scopedToTargetRawValue: targetRawValue)
    }

    private nonisolated func lifecycleTarget(
        for event: ProtocolEvent,
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID
    ) async -> WebInspectorLifecycleTarget? {
        guard event.domain == .target,
              event.method == "Target.didCommitProvisionalTarget",
              let protocolTargetID = event.targetID else {
            return nil
        }
        let snapshot = await transport.snapshot()
        guard let record = snapshot.targetsByID[protocolTargetID] else {
            return nil
        }
        return WebInspectorLifecycleTarget(
            semanticID: semanticTargetID(for: route, targetID: targetID),
            record: record
        )
    }

    private nonisolated func semanticTargetID(
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

private func protocolDomain(for domain: WebInspectorProxyEventDomain) -> ProtocolDomain {
    switch domain {
    case .target:
        .target
    case .dom:
        .dom
    case .inspector:
        .inspector
    case .css:
        .css
    case .network:
        .network
    case .console:
        .console
    case .runtime:
        .runtime
    case .page:
        .page
    }
}

private struct LiveProxyEventSubscriptionKey: Hashable, Sendable {
    var route: RoutingTargetID
    var targetID: WebInspectorTarget.ID
    var domain: WebInspectorProxyEventDomain
}

private actor LiveProxyEventSubscriptions {
    private var activeSubscriberCounts: [LiveProxyEventSubscriptionKey: Int] = [:]
    private var waiters: [LiveProxyEventSubscriptionKey: [CheckedContinuation<Void, Never>]] = [:]

    func register(_ key: LiveProxyEventSubscriptionKey) {
        activeSubscriberCounts[key, default: 0] += 1
        let continuations = waiters.removeValue(forKey: key) ?? []
        for continuation in continuations {
            continuation.resume()
        }
    }

    func unregister(_ key: LiveProxyEventSubscriptionKey) {
        guard let count = activeSubscriberCounts[key] else {
            return
        }
        if count <= 1 {
            activeSubscriberCounts[key] = nil
        } else {
            activeSubscriberCounts[key] = count - 1
        }
    }

    func waitForActiveSubscriber(_ key: LiveProxyEventSubscriptionKey) async {
        guard activeSubscriberCounts[key, default: 0] == 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }
}

private enum LiveProxyCommandEncoder {
    static func protocolCommand<Payload: Sendable, Result: Sendable>(
        for command: WebInspectorProxyCommand<Payload, Result>
    ) throws -> ProtocolCommand {
        let domain = protocolDomain(for: command.domain)
        return ProtocolCommand(
            domain: domain,
            method: "\(command.domain.rawValue).\(command.method)",
            routing: routing(for: command.route),
            parametersData: try parametersData(for: command)
        )
    }

    private static func routing(for route: RoutingTargetID) -> ProtocolCommand.Routing {
        switch route.storage {
        case let .target(rawValue):
            .target(ProtocolTarget.ID(rawValue))
        case .currentPage:
            .octopus(pageTarget: nil)
        }
    }

    private static func protocolDomain(for domain: WebInspectorProxyDomain) -> ProtocolDomain {
        switch domain {
        case .dom:
            .dom
        case .css:
            .css
        case .network:
            .network
        case .console:
            .console
        case .runtime:
            .runtime
        case .page:
            .page
        case .inspector:
            .inspector
        }
    }

    private static func parametersData<Payload: Sendable, Result: Sendable>(
        for command: WebInspectorProxyCommand<Payload, Result>
    ) throws -> Data {
        switch (command.domain, command.method) {
        case (.page, "reload"):
            let payload = try payload(command.payload, as: Page.ReloadPayload.self, command: command)
            return try data(["ignoreCache": payload.ignoringCache])

        case (.dom, "getDocument"),
             (.dom, "hideHighlight"),
             (.dom, "markUndoableState"),
             (.dom, "undo"),
             (.dom, "redo"),
             (.network, "enable"),
             (.network, "disable"),
             (.console, "enable"),
             (.console, "disable"),
             (.console, "clearMessages"),
             (.runtime, "enable"),
             (.runtime, "disable"),
             (.inspector, "enable"),
             (.inspector, "disable"),
             (.inspector, "initialized"),
             (.css, "enable"),
             (.css, "disable"):
            return emptyData()

        case (.dom, "requestChildNodes"):
            let payload = try payload(command.payload, as: DOM.RequestChildNodesPayload.self, command: command)
            return try data([
                "nodeId": nodeIDValue(payload.id.rawValue),
                "depth": payload.depth,
            ])

        case (.dom, "requestNode"):
            let payload = try payload(command.payload, as: DOM.RequestNodePayload.self, command: command)
            return try data(["objectId": payload.objectID.rawValue])

        case (.dom, "getOuterHTML"):
            let payload = try payload(command.payload, as: DOM.GetOuterHTMLPayload.self, command: command)
            return try data(["nodeId": nodeIDValue(payload.id.rawValue)])

        case (.dom, "getAttributes"):
            let payload = try payload(command.payload, as: DOM.GetAttributesPayload.self, command: command)
            return try data(["nodeId": nodeIDValue(payload.id.rawValue)])

        case (.dom, "setAttributeValue"):
            let payload = try payload(command.payload, as: DOM.SetAttributeValuePayload.self, command: command)
            return try data([
                "nodeId": nodeIDValue(payload.id.rawValue),
                "name": payload.name,
                "value": payload.value,
            ])

        case (.dom, "setAttributesAsText"):
            let payload = try payload(command.payload, as: DOM.SetAttributesAsTextPayload.self, command: command)
            var object: [String: Any] = [
                "nodeId": nodeIDValue(payload.id.rawValue),
                "text": payload.text,
            ]
            if let name = payload.name {
                object["name"] = name
            }
            return try data(object)

        case (.dom, "removeAttribute"):
            let payload = try payload(command.payload, as: DOM.RemoveAttributePayload.self, command: command)
            return try data([
                "nodeId": nodeIDValue(payload.id.rawValue),
                "name": payload.name,
            ])

        case (.dom, "setOuterHTML"):
            let payload = try payload(command.payload, as: DOM.SetOuterHTMLPayload.self, command: command)
            return try data([
                "nodeId": nodeIDValue(payload.id.rawValue),
                "outerHTML": payload.html,
            ])

        case (.dom, "removeNode"):
            let payload = try payload(command.payload, as: DOM.RemoveNodePayload.self, command: command)
            return try data(["nodeId": nodeIDValue(payload.id.rawValue)])

        case (.dom, "highlightNode"):
            let payload = try payload(command.payload, as: DOM.HighlightNodePayload.self, command: command)
            return try data([
                "nodeId": nodeIDValue(payload.id.rawValue),
                "highlightConfig": highlightConfig(),
            ])

        case (.dom, "setInspectModeEnabled"):
            let payload = try payload(command.payload, as: DOM.SetInspectModeEnabledPayload.self, command: command)
            var object: [String: Any] = ["enabled": payload.enabled]
            if payload.enabled {
                object["highlightConfig"] = highlightConfig()
            }
            return try data(object)

        case (.network, "getResponseBody"):
            let payload = try payload(command.payload, as: Network.GetResponseBodyPayload.self, command: command)
            return try data(["requestId": payload.id.unscopedRawValue])

        case (.console, "setLoggingChannelLevel"):
            let payload = try payload(command.payload, as: Console.SetLoggingChannelLevelPayload.self, command: command)
            return try data([
                "source": payload.source.rawValue,
                "level": payload.level.rawValue,
            ])

        case (.runtime, "evaluate"):
            let payload = try payload(command.payload, as: Runtime.EvaluatePayload.self, command: command)
            var object: [String: Any] = ["expression": payload.expression]
            if let context = payload.context {
                object["contextId"] = Int(context.rawValue) ?? context.rawValue
            }
            return try data(object)

        case (.runtime, "getProperties"):
            let payload = try payload(command.payload, as: Runtime.GetPropertiesPayload.self, command: command)
            return try data([
                "objectId": payload.object.rawValue,
                "ownProperties": payload.ownProperties,
            ])

        case (.runtime, "getPreview"):
            let payload = try payload(command.payload, as: Runtime.GetPreviewPayload.self, command: command)
            return try data(["objectId": payload.object.rawValue])

        case (.runtime, "getCollectionEntries"):
            let payload = try payload(command.payload, as: Runtime.GetCollectionEntriesPayload.self, command: command)
            return try data(["objectId": payload.object.rawValue])

        case (.runtime, "releaseObject"):
            let payload = try payload(command.payload, as: Runtime.ReleaseObjectPayload.self, command: command)
            return try data(["objectId": payload.id.rawValue])

        case (.runtime, "releaseObjectGroup"):
            let payload = try payload(command.payload, as: Runtime.ReleaseObjectGroupPayload.self, command: command)
            return try data(["objectGroup": objectGroupRawValue(payload.group)])

        case (.css, "getMatchedStylesForNode"):
            let payload = try payload(command.payload, as: CSS.GetMatchedStylesForNodePayload.self, command: command)
            return try data(["nodeId": nodeIDValue(payload.node.rawValue)])

        case (.css, "getInlineStylesForNode"):
            let payload = try payload(command.payload, as: CSS.GetInlineStylesForNodePayload.self, command: command)
            return try data(["nodeId": nodeIDValue(payload.node.rawValue)])

        case (.css, "getComputedStyleForNode"):
            let payload = try payload(command.payload, as: CSS.GetComputedStyleForNodePayload.self, command: command)
            return try data(["nodeId": nodeIDValue(payload.node.rawValue)])

        case (.css, "setStyleText"):
            let payload = try payload(command.payload, as: CSS.SetStyleTextPayload.self, command: command)
            return try data([
                "styleId": try styleIDPayload(payload.id, command: command),
                "text": payload.text,
            ])

        case (.css, "setStyleSheetText"):
            let payload = try payload(command.payload, as: CSS.SetStyleSheetTextPayload.self, command: command)
            return try data([
                "styleSheetId": payload.id.unscopedRawValue,
                "text": payload.text,
            ])

        case (.css, "setRuleSelector"):
            let payload = try payload(command.payload, as: CSS.SetRuleSelectorPayload.self, command: command)
            return try data([
                "ruleId": try ruleIDPayload(payload.id, command: command),
                "selector": payload.selector,
            ])

        case (.css, "setGroupingHeaderText"):
            let payload = try payload(command.payload, as: CSS.SetGroupingHeaderTextPayload.self, command: command)
            return try data([
                "ruleId": try ruleIDPayload(payload.id, command: command),
                "headerText": payload.text,
            ])

        default:
            throw unsupported(command)
        }
    }

    private static func payload<Expected, Payload: Sendable, Result: Sendable>(
        _ payload: Payload,
        as type: Expected.Type,
        command: WebInspectorProxyCommand<Payload, Result>
    ) throws -> Expected {
        guard let value = payload as? Expected else {
            throw WebInspectorProxyError.commandFailed(
                domain: command.domain.rawValue,
                method: command.method,
                message: "Live proxy command bridge expected \(Expected.self), got \(Payload.self)."
            )
        }
        return value
    }

    private static func objectGroupRawValue(_ group: Runtime.ObjectGroup) -> String {
        switch group {
        case .console:
            "console"
        case let .other(value):
            value
        }
    }

    private static func nodeIDValue(_ rawValue: String) -> Any {
        let rawValue = DOM.Node.ID(rawValue).unscopedRawValue
        if let value = Int(rawValue) {
            return value
        }
        return rawValue
    }

    private static func styleIDPayload<Payload: Sendable, Result: Sendable>(
        _ id: CSS.Style.ID,
        command: WebInspectorProxyCommand<Payload, Result>
    ) throws -> [String: Any] {
        let rawValue = id.unscopedRawValue
        let components = rawValue.split(separator: CSSStyleIDPayload.separator, omittingEmptySubsequences: false)
        guard components.count == 2,
              let ordinal = Int(components[1]) else {
            throw WebInspectorProxyError.commandFailed(
                domain: command.domain.rawValue,
                method: command.method,
                message: "CSS style identifier is not backed by a WebKit CSSStyleId."
            )
        }
        return [
            "styleSheetId": String(components[0]),
            "ordinal": ordinal,
        ]
    }

    private static func ruleIDPayload<Payload: Sendable, Result: Sendable>(
        _ id: CSS.Rule.ID,
        command: WebInspectorProxyCommand<Payload, Result>
    ) throws -> [String: Any] {
        let rawValue = id.unscopedRawValue
        let components = rawValue.split(separator: CSSStyleIDPayload.separator, omittingEmptySubsequences: false)
        guard components.count == 2,
              let ordinal = Int(components[1]) else {
            throw WebInspectorProxyError.commandFailed(
                domain: command.domain.rawValue,
                method: command.method,
                message: "CSS rule identifier is not backed by a WebKit CSSRuleId."
            )
        }
        return [
            "styleSheetId": String(components[0]),
            "ordinal": ordinal,
        ]
    }

    private static func highlightConfig() -> [String: Any] {
        [
            "showInfo": false,
            "contentColor": highlightColor(red: 111, green: 168, blue: 220, alpha: 0.66),
            "paddingColor": highlightColor(red: 147, green: 196, blue: 125, alpha: 0.66),
            "borderColor": highlightColor(red: 255, green: 229, blue: 153, alpha: 0.66),
            "marginColor": highlightColor(red: 246, green: 178, blue: 107, alpha: 0.66),
        ]
    }

    private static func highlightColor(red: Int, green: Int, blue: Int, alpha: Double) -> [String: Any] {
        [
            "r": red,
            "g": green,
            "b": blue,
            "a": alpha,
        ]
    }

    private static func data(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw TransportSession.Error.malformedMessage
        }
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }

    private static func emptyData() -> Data {
        Data("{}".utf8)
    }

    private static func unsupported<Payload: Sendable, Result: Sendable>(
        _ command: WebInspectorProxyCommand<Payload, Result>
    ) -> WebInspectorProxyError {
        .commandFailed(
            domain: command.domain.rawValue,
            method: command.method,
            message: "Live proxy command bridge does not support \(command.domain.rawValue).\(command.method)."
        )
    }
}

private enum LiveProxyCommandDecoder {
    static func decode<Payload: Sendable, Result: Sendable>(
        _ type: Result.Type,
        for command: WebInspectorProxyCommand<Payload, Result>,
        from result: ProtocolCommand.Result
    ) throws -> Result {
        if Result.self == Void.self {
            return () as! Result
        }
        if Result.self == DOM.Node.self {
            let payload = try decode(DocumentResult.self, from: result.resultData)
            return try payload.root.proxyNode() as! Result
        }
        if Result.self == DOM.Node.ID.self {
            let payload = try decode(RequestNodeResult.self, from: result.resultData)
            return DOM.Node.ID(payload.nodeId) as! Result
        }
        if Result.self == String.self {
            let payload = try decode(OuterHTMLResult.self, from: result.resultData)
            return payload.outerHTML as! Result
        }
        if Result.self == [DOM.Attribute].self {
            let payload = try decode(DOMAttributesResult.self, from: result.resultData)
            return try payload.proxyAttributes() as! Result
        }
        if Result.self == Network.Body.self {
            let payload = try decode(ResponseBodyResult.self, from: result.resultData)
            return Network.Body(data: payload.body, base64Encoded: payload.base64Encoded) as! Result
        }
        if Result.self == CSS.MatchedStyles.self {
            let payload = try decode(CSSMatchedStylesResult.self, from: result.resultData)
            return payload.proxyMatchedStyles(targetScopeRawValue: targetScopeRawValue(for: command)) as! Result
        }
        if Result.self == CSS.InlineStyles.self {
            let payload = try decode(CSSInlineStylesResult.self, from: result.resultData)
            return payload.proxyInlineStyles(targetScopeRawValue: targetScopeRawValue(for: command)) as! Result
        }
        if Result.self == [CSS.ComputedProperty].self {
            let payload = try decode(CSSComputedStyleResult.self, from: result.resultData)
            return payload.computedStyle.map(\.proxyProperty) as! Result
        }
        if Result.self == CSS.Style.self {
            let payload = try decode(CSSSetStyleTextResult.self, from: result.resultData)
            return payload.style.proxyStyle(targetScopeRawValue: targetScopeRawValue(for: command)) as! Result
        }
        if Result.self == CSS.Rule.self {
            let payload = try decode(CSSSetRuleSelectorResult.self, from: result.resultData)
            return payload.rule.proxyRule(targetScopeRawValue: targetScopeRawValue(for: command)) as! Result
        }
        if Result.self == CSS.Rule.Grouping.self {
            let payload = try decode(CSSSetGroupingHeaderTextResult.self, from: result.resultData)
            return payload.grouping.proxyGrouping as! Result
        }
        if Result.self == Runtime.EvaluationResult.self {
            let payload = try decode(RuntimeEvaluationResultPayload.self, from: result.resultData)
            return payload.proxyResult as! Result
        }
        if Result.self == [Runtime.PropertyDescriptor].self {
            let payload = try decode(RuntimePropertiesResultPayload.self, from: result.resultData)
            return payload.proxyProperties as! Result
        }
        if Result.self == Runtime.ObjectPreview.self {
            let payload = try decode(RuntimePreviewResultPayload.self, from: result.resultData)
            return payload.preview.proxyPreview as! Result
        }
        if Result.self == [Runtime.CollectionEntry].self {
            let payload = try decode(RuntimeCollectionEntriesResultPayload.self, from: result.resultData)
            return payload.proxyEntries as! Result
        }

        throw WebInspectorProxyError.commandFailed(
            domain: command.domain.rawValue,
            method: command.method,
            message: "Live proxy command bridge does not decode \(Result.self) for \(command.domain.rawValue).\(command.method)."
        )
    }

    private static func decode<Payload: Decodable>(_ type: Payload.Type, from data: Data) throws -> Payload {
        try JSONDecoder().decode(type, from: data)
    }

    private static func targetScopeRawValue<Payload: Sendable, Result: Sendable>(
        for command: WebInspectorProxyCommand<Payload, Result>
    ) -> String? {
        guard case let .target(rawValue) = command.route.storage else {
            return nil
        }
        return rawValue
    }

    private struct DocumentResult: Decodable {
        var root: ProtocolDOMNodePayload
    }

    private struct RequestNodeResult: Decodable {
        var nodeId: String

        private enum CodingKeys: String, CodingKey {
            case nodeId
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            nodeId = try container.decodeStringOrInteger(forKey: .nodeId)
        }
    }

    private struct OuterHTMLResult: Decodable {
        var outerHTML: String
    }

    private struct DOMAttributesResult: Decodable {
        var attributes: [String]

        func proxyAttributes() throws -> [DOM.Attribute] {
            guard attributes.count.isMultiple(of: 2) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription: "DOM.getAttributes returned an odd number of attribute entries."
                    )
                )
            }
            return stride(from: 0, to: attributes.count, by: 2).map { index in
                DOM.Attribute(name: attributes[index], value: attributes[index + 1])
            }
        }
    }

    private struct ResponseBodyResult: Decodable {
        var body: String
        var base64Encoded: Bool
    }
}

private struct CSSMatchedStylesResult: Decodable {
    var matchedCSSRules: [CSSRuleMatchPayload]?
    var pseudoElements: [CSSPseudoIDMatchesPayload]?
    var inherited: [CSSInheritedStyleEntryPayload]?

    func proxyMatchedStyles(targetScopeRawValue: String?) -> CSS.MatchedStyles {
        CSS.MatchedStyles(
            matchedRules: matchedCSSRules?.map { $0.rule.proxyRule(targetScopeRawValue: targetScopeRawValue) } ?? [],
            inherited: inherited?.map { $0.proxyEntry(targetScopeRawValue: targetScopeRawValue) } ?? [],
            pseudoElements: pseudoElements?.map { $0.proxyMatches(targetScopeRawValue: targetScopeRawValue) } ?? []
        )
    }
}

private struct CSSInlineStylesResult: Decodable {
    var inlineStyle: CSSStylePayload?
    var attributesStyle: CSSStylePayload?

    func proxyInlineStyles(targetScopeRawValue: String?) -> CSS.InlineStyles {
        CSS.InlineStyles(
            inlineStyle: inlineStyle?.proxyStyle(
                fallbackID: "anonymous:inline",
                targetScopeRawValue: targetScopeRawValue
            ),
            attributesStyle: attributesStyle?.proxyStyle(
                fallbackID: "anonymous:attributes",
                targetScopeRawValue: targetScopeRawValue
            )
        )
    }
}

private struct CSSComputedStyleResult: Decodable {
    var computedStyle: [CSSComputedPropertyPayload]
}

private struct CSSSetStyleTextResult: Decodable {
    var style: CSSStylePayload
}

private struct CSSSetRuleSelectorResult: Decodable {
    var rule: CSSRulePayload
}

private struct CSSSetGroupingHeaderTextResult: Decodable {
    var grouping: CSSGroupingPayload
}

private struct RuntimeEvaluationResultPayload: Decodable {
    var result: RuntimeRemoteObjectPayload
    var wasThrown: Bool?
    var savedResultIndex: Int?

    var proxyResult: Runtime.EvaluationResult {
        Runtime.EvaluationResult(
            object: result.proxyObject,
            wasThrown: wasThrown ?? false,
            savedResultIndex: savedResultIndex
        )
    }
}

private struct RuntimePropertiesResultPayload: Decodable {
    var properties: [RuntimePropertyDescriptorPayload]

    var proxyProperties: [Runtime.PropertyDescriptor] {
        properties.map(\.proxyProperty)
    }
}

private struct RuntimePropertyDescriptorPayload: Decodable {
    var name: String
    var value: RuntimeRemoteObjectPayload?
    var writable: Bool?
    var get: RuntimeRemoteObjectPayload?
    var set: RuntimeRemoteObjectPayload?
    var wasThrown: Bool?
    var configurable: Bool?
    var enumerable: Bool?
    var isOwn: Bool?
    var symbol: RuntimeRemoteObjectPayload?
    var isPrivate: Bool?
    var nativeGetter: Bool?

    var proxyProperty: Runtime.PropertyDescriptor {
        Runtime.PropertyDescriptor(
            name: name,
            value: value?.proxyObject,
            writable: writable,
            get: get?.proxyObject,
            set: set?.proxyObject,
            wasThrown: wasThrown,
            configurable: configurable,
            enumerable: enumerable,
            isOwn: isOwn,
            symbol: symbol?.proxyObject,
            isPrivate: isPrivate,
            nativeGetter: nativeGetter
        )
    }
}

private struct RuntimePreviewResultPayload: Decodable {
    var preview: ObjectPreviewPayload
}

private struct RuntimeCollectionEntriesResultPayload: Decodable {
    var entries: [RuntimeCollectionEntryPayload]

    var proxyEntries: [Runtime.CollectionEntry] {
        entries.map(\.proxyEntry)
    }
}

private struct RuntimeCollectionEntryPayload: Decodable {
    var key: RuntimeRemoteObjectPayload?
    var value: RuntimeRemoteObjectPayload

    var proxyEntry: Runtime.CollectionEntry {
        Runtime.CollectionEntry(
            key: key?.proxyObject,
            value: value.proxyObject
        )
    }
}

private struct CSSRuleMatchPayload: Decodable {
    var rule: CSSRulePayload
}

private struct CSSPseudoIDMatchesPayload: Decodable {
    var pseudoId: FlexibleStringPayload
    var matches: [CSSRuleMatchPayload]

    func proxyMatches(targetScopeRawValue: String?) -> CSS.MatchedStyles.PseudoElementMatches {
        CSS.MatchedStyles.PseudoElementMatches(
            pseudoID: pseudoId.stringValue,
            matchedRules: matches.map { $0.rule.proxyRule(targetScopeRawValue: targetScopeRawValue) }
        )
    }
}

/// WebKit has shipped `pseudoId` both as a string and as an integer enum
/// value depending on version; accept either.
private struct FlexibleStringPayload: Decodable {
    var stringValue: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            stringValue = string
        } else {
            stringValue = String(try container.decode(Int.self))
        }
    }
}

private struct CSSInheritedStyleEntryPayload: Decodable {
    var inlineStyle: CSSStylePayload?
    var matchedCSSRules: [CSSRuleMatchPayload]?

    func proxyEntry(targetScopeRawValue: String?) -> CSS.MatchedStyles.InheritedEntry {
        CSS.MatchedStyles.InheritedEntry(
            inlineStyle: inlineStyle?.proxyStyle(
                fallbackID: "anonymous:inherited-inline",
                targetScopeRawValue: targetScopeRawValue
            ),
            matchedRules: matchedCSSRules?.map { $0.rule.proxyRule(targetScopeRawValue: targetScopeRawValue) } ?? []
        )
    }
}

private struct CSSRulePayload: Decodable {
    var ruleId: CSSRuleIDPayload?
    var selectorList: CSSSelectorListPayload
    var sourceURL: String?
    var sourceLine: Int?
    var sourceLocation: CSSSourceRangePayload?
    var origin: String
    var style: CSSStylePayload
    var groupings: [CSSGroupingPayload]?
    var isImplicitlyNested: Bool?

    func proxyRule(targetScopeRawValue: String?) -> CSS.Rule {
        let fallbackStyleID = "anonymous:rule:\(origin):\(selectorList.text):\(sourceURL ?? ""):\(sourceLine ?? -1)"
        return CSS.Rule(
            id: ruleId.map { payload in
                targetScopeRawValue.map {
                    CSS.Rule.ID(payload.rawValue, scopedToTargetRawValue: $0)
                } ?? CSS.Rule.ID(payload.rawValue)
            },
            selectorList: selectorList.proxySelectorList,
            sourceURL: sourceURL,
            sourceLine: sourceLine,
            sourceLocation: sourceLocation?.proxyRange,
            origin: CSS.Origin(rawValue: origin),
            style: style.proxyStyle(fallbackID: fallbackStyleID, targetScopeRawValue: targetScopeRawValue),
            groupings: groupings?.map(\.proxyGrouping) ?? [],
            isImplicitlyNested: isImplicitlyNested ?? false
        )
    }
}

private struct CSSSelectorListPayload: Decodable {
    var selectors: [CSSSelectorPayload]
    var text: String
    var range: CSSSourceRangePayload?

    var proxySelectorList: CSS.Rule.SelectorList {
        CSS.Rule.SelectorList(
            selectors: selectors.map(\.text),
            text: text,
            range: range?.proxyRange
        )
    }
}

private struct CSSSelectorPayload: Decodable {
    var text: String
}

private struct CSSGroupingPayload: Decodable {
    var text: String?

    var proxyGrouping: CSS.Rule.Grouping {
        CSS.Rule.Grouping(text: text ?? "")
    }
}

private struct CSSStylePayload: Decodable {
    var styleId: CSSStyleIDPayload?
    var cssProperties: [CSSPropertyPayload]
    var shorthandEntries: [CSSShorthandEntryPayload]?
    var cssText: String?
    var range: CSSSourceRangePayload?
    var width: String?
    var height: String?

    func proxyStyle(
        fallbackID: String = "anonymous:style",
        targetScopeRawValue: String? = nil
    ) -> CSS.Style {
        let rawStyleID = styleId?.rawValue ?? fallbackID
        let styleID = targetScopeRawValue.map {
            CSS.Style.ID(rawStyleID, scopedToTargetRawValue: $0)
        } ?? CSS.Style.ID(rawStyleID)
        let isEditable = styleId != nil
        return CSS.Style(
            id: styleID,
            properties: cssProperties.enumerated().map { offset, payload in
                payload.proxyProperty(styleID: styleID.rawValue, index: offset, isEditable: isEditable)
            },
            shorthandEntries: shorthandEntries?.map(\.proxyEntry) ?? [],
            cssText: cssText ?? "",
            range: range?.proxyRange,
            width: width,
            height: height,
            isEditable: isEditable
        )
    }
}

private struct CSSStyleIDPayload: Decodable {
    static let separator: Character = "\u{1F}"

    var styleSheetId: String
    var ordinal: Int

    var rawValue: String {
        "\(styleSheetId)\(Self.separator)\(ordinal)"
    }
}

private struct CSSRuleIDPayload: Decodable {
    var styleSheetId: String
    var ordinal: Int

    var rawValue: String {
        "\(styleSheetId)\(CSSStyleIDPayload.separator)\(ordinal)"
    }
}

private struct CSSPropertyPayload: Decodable {
    var name: String
    var value: String
    var priority: String?
    var text: String?
    var parsedOk: Bool?
    var status: String?
    var implicit: Bool?
    var range: CSSSourceRangePayload?

    func proxyProperty(styleID: String, index: Int, isEditable: Bool) -> CSS.Property {
        CSS.Property(
            id: CSS.Property.ID("\(styleID)\(CSSStyleIDPayload.separator)\(index)"),
            name: name,
            value: value,
            priority: priority,
            text: text,
            parsedOk: parsedOk ?? true,
            status: CSS.Status(rawProtocolValue: status),
            implicit: implicit ?? false,
            range: range?.proxyRange,
            isEditable: isEditable,
            isModifiedByInspector: false
        )
    }
}

private struct CSSShorthandEntryPayload: Decodable {
    var name: String
    var value: String
    var priority: String?

    var proxyEntry: CSS.Style.ShorthandEntry {
        CSS.Style.ShorthandEntry(name: name, value: value, priority: priority)
    }
}

private struct CSSComputedPropertyPayload: Decodable {
    var name: String
    var value: String

    var proxyProperty: CSS.ComputedProperty {
        CSS.ComputedProperty(name: name, value: value)
    }
}

private struct CSSSourceRangePayload: Decodable {
    var startLine: Int
    var startColumn: Int
    var endLine: Int
    var endColumn: Int

    var proxyRange: CSS.Style.SourceRange {
        CSS.Style.SourceRange(
            startLine: startLine,
            startColumn: startColumn,
            endLine: endLine,
            endColumn: endColumn
        )
    }
}

private extension CSS.Status {
    init(rawProtocolValue: String?) {
        switch rawProtocolValue {
        case "inactive":
            self = .inactive
        case "disabled":
            self = .disabled
        default:
            self = .active
        }
    }
}
