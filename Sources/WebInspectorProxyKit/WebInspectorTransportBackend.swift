import Foundation
import WebInspectorTransport

package struct WebInspectorTransportBackend: WebInspectorProxyBackend {
    private let transport: TransportSession
    private let eventSubscriptions: WebInspectorTransportEventSubscriptions

    package init(transport: TransportSession) {
        self.transport = transport
        eventSubscriptions = WebInspectorTransportEventSubscriptions()
    }

    package func dispatchCommand<Payload: Sendable, Result: Sendable>(
        _ command: WebInspectorProxyCommand<Payload, Result>
    ) async throws -> Result {
        let protocolCommand = try WebInspectorTransportCommandEncoder.protocolCommand(for: command)
        let result: ProtocolCommand.Result
        do {
            result = try await transport.send(protocolCommand)
        } catch {
            throw mapTransportError(error, domain: command.domain.rawValue, method: command.method)
        }
        return try WebInspectorTransportCommandDecoder.decode(Result.self, for: command, from: result)
    }

    package func waitForEventSubscription(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        domain: WebInspectorProxyEventDomain
    ) async {
        await eventSubscriptions.waitForActiveSubscriber(
            WebInspectorTransportEventSubscriptionKey(route: route, targetID: targetID, domain: domain)
        )
    }

    package nonisolated func events(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        domain: WebInspectorProxyEventDomain
    ) -> AsyncStream<WebInspectorProxyEvent> {
        AsyncStream<WebInspectorProxyEvent> { continuation in
            let key = WebInspectorTransportEventSubscriptionKey(route: route, targetID: targetID, domain: domain)
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
                        continuation.yield(try WebInspectorTransportEventDecoder.proxyEvent(from: event, targetID: targetID))
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
            guard let currentMainPageTargetID = snapshot.currentMainPageTargetID else {
                return false
            }
            guard let targetID = event.targetID else {
                return true
            }
            return targetID == currentMainPageTargetID
        }
    }
}

private func protocolDomain(for domain: WebInspectorProxyEventDomain) -> ProtocolDomain {
    switch domain {
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
    }
}

private struct WebInspectorTransportEventSubscriptionKey: Hashable, Sendable {
    var route: RoutingTargetID
    var targetID: WebInspectorTarget.ID
    var domain: WebInspectorProxyEventDomain
}

private actor WebInspectorTransportEventSubscriptions {
    private var activeSubscriberCounts: [WebInspectorTransportEventSubscriptionKey: Int] = [:]
    private var waiters: [WebInspectorTransportEventSubscriptionKey: [CheckedContinuation<Void, Never>]] = [:]

    func register(_ key: WebInspectorTransportEventSubscriptionKey) {
        activeSubscriberCounts[key, default: 0] += 1
        let continuations = waiters.removeValue(forKey: key) ?? []
        for continuation in continuations {
            continuation.resume()
        }
    }

    func unregister(_ key: WebInspectorTransportEventSubscriptionKey) {
        guard let count = activeSubscriberCounts[key] else {
            return
        }
        if count <= 1 {
            activeSubscriberCounts[key] = nil
        } else {
            activeSubscriberCounts[key] = count - 1
        }
    }

    func waitForActiveSubscriber(_ key: WebInspectorTransportEventSubscriptionKey) async {
        guard activeSubscriberCounts[key, default: 0] == 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }
}

private enum WebInspectorTransportCommandEncoder {
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
             (.dom, "undo"),
             (.dom, "redo"),
             (.network, "enable"),
             (.network, "disable"),
             (.console, "enable"),
             (.console, "disable"),
             (.console, "clearMessages"),
             (.runtime, "enable"),
             (.runtime, "disable"),
             (.css, "enable"),
             (.css, "disable"):
            return emptyData()

        case (.dom, "requestChildNodes"):
            let payload = try payload(command.payload, as: DOM.RequestChildNodesPayload.self, command: command)
            return try data([
                "nodeId": payload.id.rawValue,
                "depth": max(1, payload.depth),
            ])

        case (.dom, "requestNode"):
            let payload = try payload(command.payload, as: DOM.RequestNodePayload.self, command: command)
            return try data(["objectId": payload.objectID.rawValue])

        case (.dom, "getOuterHTML"):
            let payload = try payload(command.payload, as: DOM.GetOuterHTMLPayload.self, command: command)
            return try data(["nodeId": payload.id.rawValue])

        case (.dom, "removeNode"):
            let payload = try payload(command.payload, as: DOM.RemoveNodePayload.self, command: command)
            return try data(["nodeId": payload.id.rawValue])

        case (.network, "getResponseBody"):
            let payload = try payload(command.payload, as: Network.GetResponseBodyPayload.self, command: command)
            return try data(["requestId": payload.id.rawValue])

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
            return try data(["nodeId": payload.node.rawValue])

        case (.css, "getComputedStyleForNode"):
            let payload = try payload(command.payload, as: CSS.GetComputedStyleForNodePayload.self, command: command)
            return try data(["nodeId": payload.node.rawValue])

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
                message: "Transport command bridge expected \(Expected.self), got \(Payload.self)."
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
            message: "Transport command bridge does not support \(command.domain.rawValue).\(command.method)."
        )
    }
}

private enum WebInspectorTransportCommandDecoder {
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
        if Result.self == Network.Body.self {
            let payload = try decode(ResponseBodyResult.self, from: result.resultData)
            return Network.Body(data: payload.body, base64Encoded: payload.base64Encoded) as! Result
        }

        throw WebInspectorProxyError.commandFailed(
            domain: command.domain.rawValue,
            method: command.method,
            message: "Transport command bridge does not decode \(Result.self) for \(command.domain.rawValue).\(command.method)."
        )
    }

    private static func decode<Payload: Decodable>(_ type: Payload.Type, from data: Data) throws -> Payload {
        try JSONDecoder().decode(type, from: data)
    }

    private struct DocumentResult: Decodable {
        var root: WebInspectorTransportDOMNodePayload
    }

    private struct RequestNodeResult: Decodable {
        var nodeId: String
    }

    private struct OuterHTMLResult: Decodable {
        var outerHTML: String
    }

    private struct ResponseBodyResult: Decodable {
        var body: String
        var base64Encoded: Bool
    }
}
