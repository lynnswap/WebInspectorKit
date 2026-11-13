import Foundation

package struct LiveWebInspectorProxyBackend: WebInspectorProxyBackend {
    private let transport: TransportSession
    private let eventSubscriptions: LiveProxyEventSubscriptions

    package init(transport: TransportSession) {
        self.transport = transport
        eventSubscriptions = LiveProxyEventSubscriptions()
    }

    package func dispatchCommand<Payload: WebInspectorProxyCommandPayload>(
        _ command: WebInspectorProxyCommand<Payload>
    ) async throws -> Payload.Result {
        try await dispatchCommandWithReplyBoundary(command).value
    }

    package func dispatchCommandWithReplyBoundary<Payload: WebInspectorProxyCommandPayload>(
        _ command: WebInspectorProxyCommand<Payload>
    ) async throws -> WebInspectorProxyCommandReply<Payload.Result> {
        let protocolCommand = try LiveProxyCommandEncoder.protocolCommand(for: command)
        let result: ProtocolCommand.Result
        do {
            result = try await transport.send(protocolCommand)
        } catch {
            throw mapTransportError(error, domain: command.domain.rawValue, method: command.method)
        }
        let value = try Payload.decodeResult(
            from: result.resultData,
            targetScope: await targetScopeRawValue(for: command.route)
        )
        return WebInspectorProxyCommandReply(
            value: value,
            receivedSequence: result.receivedSequence
        )
    }

    package func finishEventSubscriptions(throwing error: WebInspectorProxyError?) async {
        await eventSubscriptions.finish(throwing: error)
    }

    package func orderedEvents(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        terminalFailureHandler: @escaping WebInspectorProxyTerminalFailureHandler
    ) async -> WebInspectorProxyOrderedEventFeed {
        let transportFeed = await transport.orderedEventFeed()
        let key = LiveProxyEventSubscriptionKey(route: route, targetID: targetID, domain: .ordered)
        let subscriptionID = LiveProxyEventSubscriptionID()

        let stream = AsyncThrowingStream<WebInspectorProxyOrderedEvent, any Error>(
            bufferingPolicy: .unbounded
        ) { continuation in
            let task = Task {
                guard await eventSubscriptions.registerOrdered(
                    key,
                    id: subscriptionID,
                    continuation: continuation
                ) else {
                    return
                }
                for await event in transportFeed.events {
                    guard Task.isCancelled == false else {
                        break
                    }
                    do {
                        continuation.yield(WebInspectorProxyOrderedEvent(
                            sequence: event.sequence,
                            event: try await projectedOrderedEvent(
                                event,
                                route: route,
                                targetID: targetID
                            )
                        ))
                    } catch {
                        let failure = WebInspectorProxyTerminalFailure.eventDecodingFailed(
                            method: event.method,
                            error: error
                        )
                        await terminalFailureHandler(failure)
                        return
                    }
                }
                if let error = await transport.terminalFailure {
                    let failure = WebInspectorProxyTerminalFailure.transportFailed(error)
                    await terminalFailureHandler(failure)
                    continuation.finish(throwing: failure.publicError)
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task {
                    await eventSubscriptions.cancel(key, id: subscriptionID)
                }
            }
        }
        return WebInspectorProxyOrderedEventFeed(
            initialSequence: transportFeed.initialSequence,
            events: stream
        )
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

    package func waitForEventSubscriptions(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        domain: WebInspectorProxyEventDomain,
        minimumCount: Int
    ) async {
        await eventSubscriptions.waitForActiveSubscribers(
            LiveProxyEventSubscriptionKey(route: route, targetID: targetID, domain: domain),
            minimumCount: minimumCount
        )
    }

    package func eventSubscriptionBookkeepingCountForTesting() async -> Int {
        await eventSubscriptions.bookkeepingCount
    }

    package func eventSubscriptionWaiterCountForTesting() async -> Int {
        await eventSubscriptions.waiterCount
    }

    package func waitForEventSubscriptionWaiterForTesting() async {
        await eventSubscriptions.waitForWaiterRegistration()
    }

    package func exerciseCancelledSubscriptionRegistrationForTesting(
        ordered: Bool,
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID
    ) async -> Bool {
        let id = LiveProxyEventSubscriptionID()
        if ordered {
            let key = LiveProxyEventSubscriptionKey(
                route: route,
                targetID: targetID,
                domain: .ordered
            )
            let pair = AsyncThrowingStream<WebInspectorProxyOrderedEvent, any Error>.makeStream()
            await eventSubscriptions.cancel(key, id: id)
            let registered = await eventSubscriptions.registerOrdered(
                key,
                id: id,
                continuation: pair.continuation
            )
            let bookkeepingCount = await eventSubscriptions.bookkeepingCount
            return registered == false && bookkeepingCount == 0
        }
        let key = LiveProxyEventSubscriptionKey(
            route: route,
            targetID: targetID,
            domain: .network
        )
        let pair = AsyncStream<WebInspectorProxyEvent>.makeStream()
        await eventSubscriptions.cancel(key, id: id)
        let registered = await eventSubscriptions.registerDomain(
            key,
            id: id,
            continuation: pair.continuation
        )
        let bookkeepingCount = await eventSubscriptions.bookkeepingCount
        return registered == false && bookkeepingCount == 0
    }

    package nonisolated func events(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        domain: WebInspectorProxyEventDomain,
        terminalFailureHandler: @escaping WebInspectorProxyTerminalFailureHandler
    ) -> AsyncStream<WebInspectorProxyEvent> {
        AsyncStream<WebInspectorProxyEvent> { continuation in
            let key = LiveProxyEventSubscriptionKey(route: route, targetID: targetID, domain: domain)
            let subscriptionID = LiveProxyEventSubscriptionID()
            let task = Task {
                let stream = await transport.events(for: protocolDomain(for: domain))
                guard await eventSubscriptions.registerDomain(
                    key,
                    id: subscriptionID,
                    continuation: continuation
                ) else {
                    return
                }
                for await event in stream {
                    guard Task.isCancelled == false else {
                        break
                    }
                    do {
                        let lifecycleTarget = lifecycleTarget(for: event, route: route, targetID: targetID)
                        let proxyEvent = try LiveProxyEventDecoder.proxyEvent(
                            from: event,
                            targetID: targetID,
                            lifecycleTarget: lifecycleTarget
                        )
                        guard await shouldDeliver(event, to: route) else {
                            continue
                        }
                        continuation.yield(projectedEvent(proxyEvent, from: event, route: route))
                    } catch {
                        let failure = WebInspectorProxyTerminalFailure.eventDecodingFailed(
                            method: event.method,
                            error: error
                        )
                        await terminalFailureHandler(failure)
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task {
                    await eventSubscriptions.cancel(key, id: subscriptionID)
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
        case let .eventDecodingFailed(method, message):
            return WebInspectorProxyError.disconnected(
                "Failed to decode \(method): \(message)"
            )
        case .messageDecodingFailed, .nativeAttachmentInvalidated:
            return WebInspectorProxyTerminalFailure.transportFailed(transportError).publicError
        case let .replyTimeout(method, _):
            return WebInspectorProxyError.timeout(domain: domain, method: method)
        case let .remoteError(method, _, message):
            return WebInspectorProxyError.commandFailed(domain: domain, method: method, message: message)
        case .malformedMessage,
             .missingMainPageTarget,
             .missingTarget,
             .unsupportedDomain,
             .inspectedPageProcessTerminated:
            return WebInspectorProxyError.commandFailed(
                domain: domain,
                method: method,
                message: "\(transportError)"
            )
        }
    }

    private nonisolated func targetScopeRawValue(
        for route: RoutingTargetID
    ) async -> String? {
        guard case let .target(rawValue) = route.storage else {
            return nil
        }
        let targetID = ProtocolTarget.ID(rawValue)
        let snapshot = await transport.snapshot()
        if targetID == snapshot.currentMainPageTargetID {
            return nil
        }
        if let record = snapshot.targetsByID[targetID],
           record.kind == .page,
           record.parentFrameID == nil {
            return nil
        }
        return rawValue
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
            if event.domain == .network,
               let membership = event.networkPageMembership {
                return membership == .currentPage
            }
            if event.domain == .page,
               let belongedToCurrentPage = event.rootPageBelongedToCurrentPage {
                return belongedToCurrentPage
            }
            if event.domain == .dom,
               event.method == "DOM.documentUpdated",
               event.targetRecord?.kind == .frame {
                return false
            }
            if event.domain == .inspector,
               event.targetRecord?.kind == .frame {
                return false
            }
            if event.destroyedCurrentMainPageTarget
                || event.destroyedProvisionalTargetInCurrentPageHierarchy
                || event.detachedCurrentPageFrameTarget {
                return true
            }
            if event.belongedToCurrentPage {
                return true
            }
            let snapshot = await transport.snapshot()
            if event.domain == .target,
               event.method == "Target.targetDestroyed" {
                // The registry has already dropped the destroyed record, so
                // route by event-time facts retained by the transport.
                return event.destroyedCurrentMainPageTarget
                    || event.destroyedProvisionalTargetInCurrentPageHierarchy
            }
            if event.domain == .page,
               event.method == "Page.frameDetached",
               event.detachedCurrentPageFrameTarget {
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
            // WebKit may report subframe domain activity on frame targets while
            // WebInspectorKit exposes a semantic current page.
            switch event.domain {
            case .dom:
                guard event.method != "DOM.documentUpdated" else {
                    return false
                }
                return isCurrentPageFrameTarget(record)
            case .inspector:
                // Inspector excludes frame targets in WebKit's protocol. A
                // frame-origin inspect event is not rewritten into a page event.
                return false
            case .network:
                // WebKit's page/ProxyingNetworkAgent owns process-wide
                // Network.enable. This branch only projects target-wrapped
                // frame Network events if WebKit emits them.
                return isCurrentPageFrameTarget(record)
            case .css:
                return isCurrentPageFrameTarget(record)
            case .console:
                return isCurrentPageFrameTarget(record)
            case .runtime:
                return isCurrentPageFrameTarget(record)
            case .page:
                return isCurrentPageFrameTarget(record)
            default:
                return false
            }
        }
    }

    private nonisolated func projectedOrderedEvent(
        _ event: ProtocolEvent,
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID
    ) async throws -> WebInspectorProxyEvent? {
        switch event.domain {
        case .target, .dom, .inspector, .css, .network, .console, .runtime, .page:
            break
        case .storage, .other:
            return nil
        }
        let lifecycleTarget = lifecycleTarget(for: event, route: route, targetID: targetID)
        let proxyEvent = try LiveProxyEventDecoder.proxyEvent(
            from: event,
            targetID: targetID,
            lifecycleTarget: lifecycleTarget
        )
        guard shouldDeliverOrderedEvent(event, to: route) else {
            return nil
        }
        return projectedEvent(proxyEvent, from: event, route: route)
    }

    private nonisolated func shouldDeliverOrderedEvent(
        _ event: ProtocolEvent,
        to route: RoutingTargetID
    ) -> Bool {
        switch route.storage {
        case let .target(rawValue):
            return event.sourceTargetID?.rawValue == rawValue
                || event.targetID?.rawValue == rawValue
        case .currentPage:
            if event.domain == .target,
               event.method == "Target.targetCreated" {
                return false
            }
            if event.domain == .network,
               let membership = event.networkPageMembership {
                return membership == .currentPage
            }
            if event.domain == .page,
               let belongedToCurrentPage = event.rootPageBelongedToCurrentPage {
                return belongedToCurrentPage
            }
            if event.domain == .dom,
               event.method == "DOM.documentUpdated",
               event.targetRecord?.kind == .frame {
                return false
            }
            if event.domain == .inspector,
               event.targetRecord?.kind == .frame {
                return false
            }
            if event.destroyedCurrentMainPageTarget
                || event.destroyedProvisionalTargetInCurrentPageHierarchy
                || event.detachedCurrentPageFrameTarget {
                return true
            }
            return event.belongedToCurrentPage
        }
    }

    private nonisolated func isCurrentPageFrameTarget(
        _ record: ProtocolTarget.Record
    ) -> Bool {
        // Frame targets are inventoried by the inspected page's
        // WebPageInspectorController. Page topology is payload state, not the
        // ownership boundary, and can legitimately arrive after domain events.
        record.kind == .frame && !record.isProvisional
    }

    private nonisolated func projectedEvent(
        _ proxyEvent: WebInspectorProxyEvent,
        from event: ProtocolEvent,
        route: RoutingTargetID
    ) -> WebInspectorProxyEvent {
        if case let .network(networkEvent) = proxyEvent,
           let stableScopeTargetID = event.networkScopeTargetID {
            return .network(scopedNetworkEvent(
                networkEvent,
                targetRawValue: stableScopeTargetID.rawValue
            ))
        }
        let scopedProxyEvent = scopedAgentOwnedEvent(proxyEvent, from: event)
        guard case .currentPage = route.storage,
              let targetID = event.targetID,
              event.targetRecord?.kind == .frame else {
            return scopedProxyEvent
        }
        switch scopedProxyEvent {
        case let .dom(domEvent):
            return .dom(scopedDOMEvent(domEvent, targetRawValue: targetID.rawValue))
        case let .css(cssEvent):
            return .css(scopedCSSEvent(cssEvent, targetRawValue: targetID.rawValue))
        case let .network(networkEvent):
            let stableScopeTargetID = event.networkScopeTargetID ?? targetID
            return .network(scopedNetworkEvent(
                networkEvent,
                targetRawValue: stableScopeTargetID.rawValue
            ))
        default:
            return scopedProxyEvent
        }
    }

    private nonisolated func scopedAgentOwnedEvent(
        _ proxyEvent: WebInspectorProxyEvent,
        from event: ProtocolEvent
    ) -> WebInspectorProxyEvent {
        let targetScopeRawValue = runtimeAgentScopeRawValue(for: event)
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

    private nonisolated func runtimeAgentScopeRawValue(
        for event: ProtocolEvent
    ) -> String? {
        event.agentScopeTargetID?.rawValue
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

    private nonisolated func scopedCSSEvent(
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

    private nonisolated func scopedStyleSheetID(
        _ id: CSS.StyleSheet.ID,
        targetRawValue: String
    ) -> CSS.StyleSheet.ID {
        guard id.targetScopeRawValue == nil else {
            return id
        }
        return CSS.StyleSheet.ID(id.rawValue, scopedToTargetRawValue: targetRawValue)
    }

    private nonisolated func scopedRuntimeEvent(
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

    private nonisolated func scopedExecutionContextID(
        _ id: Runtime.ExecutionContext.ID,
        targetRawValue: String
    ) -> Runtime.ExecutionContext.ID {
        guard id.targetScopeRawValue == nil else {
            return id
        }
        return Runtime.ExecutionContext.ID(id.rawValue, scopedToTargetRawValue: targetRawValue)
    }

    private nonisolated func scopedConsoleEvent(
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

    private nonisolated func scopedConsoleMessage(
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

    private nonisolated func scopedRemoteObject(
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

    private nonisolated func scopedRemoteObjectID(
        _ id: Runtime.RemoteObject.ID,
        targetRawValue: String
    ) -> Runtime.RemoteObject.ID {
        guard id.targetScopeRawValue == nil else {
            return id
        }
        return Runtime.RemoteObject.ID(id.rawValue, scopedToTargetRawValue: targetRawValue)
    }

    private nonisolated func scopedNetworkEvent(
        _ event: Network.Event,
        targetRawValue: String
    ) -> Network.Event {
        switch event {
        case let .requestWillBeSent(id, request, initiator, resourceType, redirectResponse, timestamp):
            .requestWillBeSent(
                id: scopedNetworkRequestID(id, targetRawValue: targetRawValue),
                request: scopedNetworkRequest(request, targetRawValue: targetRawValue),
                initiator: scopedNetworkInitiator(initiator, targetRawValue: targetRawValue),
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
        case let .requestServedFromMemoryCache(id, response, initiator, resourceType, timestamp):
            .requestServedFromMemoryCache(
                id: scopedNetworkRequestID(id, targetRawValue: targetRawValue),
                response: response,
                initiator: scopedNetworkInitiator(initiator, targetRawValue: targetRawValue),
                resourceType: resourceType,
                timestamp: timestamp
            )
        case let .webSocket(event):
            .webSocket(scopedWebSocketEvent(event, targetRawValue: targetRawValue))
        case let .unknown(rawEvent):
            .unknown(rawEvent)
        }
    }

    private nonisolated func scopedNetworkInitiator(
        _ initiator: Network.Initiator,
        targetRawValue: String
    ) -> Network.Initiator {
        Network.Initiator(
            kind: initiator.kind,
            url: initiator.url,
            line: initiator.line,
            column: initiator.column,
            nodeID: initiator.nodeID.map { scopedDOMNodeID($0, targetRawValue: targetRawValue) }
        )
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
            integrity: request.integrity,
            backendResourceIdentifier: request.backendResourceIdentifier,
            origin: request.origin
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
    ) -> WebInspectorLifecycleTarget? {
        guard event.domain == .target,
              event.method == "Target.didCommitProvisionalTarget",
              let record = event.targetRecord else {
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
    case .ordered:
        preconditionFailure("Ordered events are not a protocol domain.")
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

private struct LiveProxyEventSubscriptionID: Hashable, Sendable {
    var rawValue = UUID()
}

private actor LiveProxyEventSubscriptions {
    typealias DomainContinuation = AsyncStream<WebInspectorProxyEvent>.Continuation
    typealias OrderedContinuation = AsyncThrowingStream<
        WebInspectorProxyOrderedEvent,
        any Error
    >.Continuation

    private struct Waiter {
        let id: UInt64
        let minimumCount: Int
        let promise: ReplyPromise<Void>
    }

    private struct WaiterRegistrationWaiter {
        let id: UInt64
        let promise: ReplyPromise<Void>
    }

    private var activeSubscriberIDs: [LiveProxyEventSubscriptionKey: Set<LiveProxyEventSubscriptionID>] = [:]
    private var domainContinuations: [LiveProxyEventSubscriptionID: DomainContinuation] = [:]
    private var orderedContinuations: [LiveProxyEventSubscriptionID: OrderedContinuation] = [:]
    private var cancelledSubscriptionIDs: Set<LiveProxyEventSubscriptionID> = []
    private var waiters: [LiveProxyEventSubscriptionKey: [Waiter]] = [:]
    private var nextWaiterID: UInt64 = 0
    private var waiterRegistrationWaiters: [WaiterRegistrationWaiter] = []
    private var nextWaiterRegistrationWaiterID: UInt64 = 0
    private var isFinished = false
    private var terminalError: WebInspectorProxyError?

    var bookkeepingCount: Int {
        activeSubscriberIDs.values.reduce(0) { $0 + $1.count }
            + domainContinuations.count
            + orderedContinuations.count
            + cancelledSubscriptionIDs.count
    }

    var waiterCount: Int {
        waiters.values.reduce(0) { $0 + $1.count }
    }

    func waitForWaiterRegistration() async {
        guard waiterCount == 0, isFinished == false else {
            return
        }
        let id = nextWaiterRegistrationWaiterID
        nextWaiterRegistrationWaiterID += 1
        let waiter = WaiterRegistrationWaiter(id: id, promise: ReplyPromise<Void>())
        waiterRegistrationWaiters.append(waiter)
        defer {
            waiterRegistrationWaiters.removeAll { $0.id == id }
        }
        _ = try? await waiter.promise.value()
    }

    func registerDomain(
        _ key: LiveProxyEventSubscriptionKey,
        id: LiveProxyEventSubscriptionID,
        continuation: DomainContinuation
    ) -> Bool {
        guard isFinished == false else {
            continuation.finish()
            return false
        }
        guard cancelledSubscriptionIDs.remove(id) == nil else {
            continuation.finish()
            return false
        }
        domainContinuations[id] = continuation
        register(key, id: id)
        return true
    }

    func registerOrdered(
        _ key: LiveProxyEventSubscriptionKey,
        id: LiveProxyEventSubscriptionID,
        continuation: OrderedContinuation
    ) -> Bool {
        guard isFinished == false else {
            continuation.finish(throwing: terminalError)
            return false
        }
        guard cancelledSubscriptionIDs.remove(id) == nil else {
            continuation.finish()
            return false
        }
        orderedContinuations[id] = continuation
        register(key, id: id)
        return true
    }

    private func register(_ key: LiveProxyEventSubscriptionKey, id: LiveProxyEventSubscriptionID) {
        let inserted = activeSubscriberIDs[key, default: []].insert(id).inserted
        precondition(inserted, "Live event subscription identity was registered twice.")
        guard let pending = waiters.removeValue(forKey: key) else {
            return
        }
        let count = activeSubscriberIDs[key, default: []].count
        var remaining: [Waiter] = []
        for waiter in pending {
            if count >= waiter.minimumCount {
                waiter.promise.fulfill(.success(()))
            } else {
                remaining.append(waiter)
            }
        }
        if remaining.isEmpty == false {
            waiters[key] = remaining
        }
    }

    func cancel(_ key: LiveProxyEventSubscriptionKey, id: LiveProxyEventSubscriptionID) {
        guard isFinished == false else {
            return
        }
        domainContinuations[id] = nil
        orderedContinuations[id] = nil
        guard var ids = activeSubscriberIDs[key],
              ids.remove(id) != nil else {
            cancelledSubscriptionIDs.insert(id)
            return
        }
        if ids.isEmpty {
            activeSubscriberIDs[key] = nil
        } else {
            activeSubscriberIDs[key] = ids
        }
    }

    func waitForActiveSubscriber(_ key: LiveProxyEventSubscriptionKey) async {
        await waitForActiveSubscribers(key, minimumCount: 1)
    }

    func waitForActiveSubscribers(_ key: LiveProxyEventSubscriptionKey, minimumCount: Int) async {
        guard isFinished == false else {
            return
        }
        guard activeSubscriberIDs[key, default: []].count < minimumCount else {
            return
        }
        let waiterID = nextWaiterID
        nextWaiterID += 1
        let waiter = Waiter(
            id: waiterID,
            minimumCount: minimumCount,
            promise: ReplyPromise<Void>()
        )
        addWaiter(waiter, key: key)
        _ = try? await waiter.promise.value()
        removeWaiter(waiterID, key: key)
    }

    func finish(throwing error: WebInspectorProxyError?) {
        guard isFinished == false else {
            return
        }
        isFinished = true
        terminalError = error
        activeSubscriberIDs.removeAll()
        cancelledSubscriptionIDs.removeAll()
        let domainContinuations = Array(domainContinuations.values)
        self.domainContinuations.removeAll()
        let orderedContinuations = Array(orderedContinuations.values)
        self.orderedContinuations.removeAll()
        let pending = waiters.values.flatMap { $0 }
        waiters.removeAll()
        let registrationWaiters = waiterRegistrationWaiters
        waiterRegistrationWaiters.removeAll()
        for waiter in pending {
            waiter.promise.fulfill(.success(()))
        }
        for waiter in registrationWaiters {
            waiter.promise.fulfill(.success(()))
        }
        for continuation in domainContinuations {
            continuation.finish()
        }
        for continuation in orderedContinuations {
            continuation.finish(throwing: error)
        }
    }

    private func addWaiter(_ waiter: Waiter, key: LiveProxyEventSubscriptionKey) {
        guard isFinished == false else {
            waiter.promise.fulfill(.success(()))
            return
        }
        waiters[key, default: []].append(waiter)
        let registrationWaiters = waiterRegistrationWaiters
        waiterRegistrationWaiters.removeAll()
        for waiter in registrationWaiters {
            waiter.promise.fulfill(.success(()))
        }
    }

    private func removeWaiter(_ id: UInt64, key: LiveProxyEventSubscriptionKey) {
        guard var pending = waiters[key],
              let index = pending.firstIndex(where: { $0.id == id }) else {
            return
        }
        pending.remove(at: index)
        if pending.isEmpty {
            waiters[key] = nil
        } else {
            waiters[key] = pending
        }
    }
}
