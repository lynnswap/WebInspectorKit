import Foundation
import WebInspectorTransport

package struct WebInspectorTransportCommandBackend: WebInspectorProxyBackend {
    private let transport: TransportSession

    package init(transport: TransportSession) {
        self.transport = transport
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
        _ = route
        _ = targetID
        preconditionFailure("WebInspectorTransportCommandBackend does not own \(domain.rawValue) event streams.")
    }

    package nonisolated func events(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        domain: WebInspectorProxyEventDomain
    ) -> AsyncStream<WebInspectorProxyEvent> {
        _ = route
        _ = targetID
        preconditionFailure("WebInspectorTransportCommandBackend does not own \(domain.rawValue) event streams.")
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
}

private enum WebInspectorTransportCommandEncoder {
    static func protocolCommand<Payload: Sendable, Result: Sendable>(
        for command: WebInspectorProxyCommand<Payload, Result>
    ) throws -> ProtocolCommand {
        let domain = protocolDomain(for: command.domain)
        return ProtocolCommand(
            domain: domain,
            method: "\(command.domain.rawValue).\(command.method)",
            routing: .target(ProtocolTarget.ID(command.route.rawValue)),
            parametersData: try parametersData(for: command)
        )
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
        var root: ProtocolDOMNode
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

    private final class ProtocolDOMNode: Decodable {
        var nodeId: String
        var nodeType: Int
        var nodeName: String
        var localName: String
        var nodeValue: String
        var frameId: String?
        var childNodeCount: Int?
        var children: [ProtocolDOMNode]?
        var attributes: [String]?
        var documentURL: String?
        var baseURL: String?
        var pseudoType: String?
        var shadowRootType: String?
        var contentDocument: ProtocolDOMNode?
        var shadowRoots: [ProtocolDOMNode]?
        var templateContent: ProtocolDOMNode?
        var pseudoElements: [ProtocolDOMNode]?

        private enum CodingKeys: String, CodingKey {
            case nodeId
            case nodeType
            case nodeName
            case localName
            case nodeValue
            case frameId
            case childNodeCount
            case children
            case attributes
            case documentURL
            case baseURL
            case pseudoType
            case shadowRootType
            case contentDocument
            case shadowRoots
            case templateContent
            case pseudoElements
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let integerID = try? container.decode(Int.self, forKey: .nodeId) {
                nodeId = String(integerID)
            } else {
                nodeId = try container.decode(String.self, forKey: .nodeId)
            }
            nodeType = try container.decode(Int.self, forKey: .nodeType)
            nodeName = try container.decode(String.self, forKey: .nodeName)
            localName = try container.decode(String.self, forKey: .localName)
            nodeValue = try container.decode(String.self, forKey: .nodeValue)
            frameId = try container.decodeIfPresent(String.self, forKey: .frameId)
            childNodeCount = try container.decodeIfPresent(Int.self, forKey: .childNodeCount)
            children = try container.decodeIfPresent([ProtocolDOMNode].self, forKey: .children)
            attributes = try container.decodeIfPresent([String].self, forKey: .attributes)
            documentURL = try container.decodeIfPresent(String.self, forKey: .documentURL)
            baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
            pseudoType = try container.decodeIfPresent(String.self, forKey: .pseudoType)
            shadowRootType = try container.decodeIfPresent(String.self, forKey: .shadowRootType)
            contentDocument = try container.decodeIfPresent(ProtocolDOMNode.self, forKey: .contentDocument)
            shadowRoots = try container.decodeIfPresent([ProtocolDOMNode].self, forKey: .shadowRoots)
            templateContent = try container.decodeIfPresent(ProtocolDOMNode.self, forKey: .templateContent)
            pseudoElements = try container.decodeIfPresent([ProtocolDOMNode].self, forKey: .pseudoElements)
        }

        func proxyNode() throws -> DOM.Node {
            let pseudoElements = try (pseudoElements ?? []).map { try $0.proxyNode() }
            return DOM.Node(
                id: DOM.Node.ID(nodeId),
                nodeType: nodeType,
                nodeName: nodeName,
                localName: localName,
                nodeValue: nodeValue,
                frameID: frameId.map(FrameID.init),
                documentURL: documentURL,
                baseURL: baseURL,
                attributes: try attributeDictionary(),
                childNodeCount: childNodeCount ?? 0,
                children: try children?.map { try $0.proxyNode() },
                contentDocument: try contentDocument?.proxyNode(),
                shadowRoots: try (shadowRoots ?? []).map { try $0.proxyNode() },
                templateContent: try templateContent?.proxyNode(),
                beforePseudoElement: pseudoElements.first { $0.pseudoType?.isBefore == true },
                otherPseudoElements: pseudoElements.filter { $0.pseudoType?.isBefore != true && $0.pseudoType?.isAfter != true },
                afterPseudoElement: pseudoElements.first { $0.pseudoType?.isAfter == true },
                pseudoType: Self.pseudoType(pseudoType),
                shadowRootType: Self.shadowRootType(shadowRootType)
            )
        }

        private func attributeDictionary() throws -> [String: String] {
            guard let attributes else {
                return [:]
            }
            guard attributes.count.isMultiple(of: 2) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [CodingKeys.attributes],
                    debugDescription: "DOM.Node attributes must be an even flat name/value array."
                ))
            }
            var result: [String: String] = [:]
            result.reserveCapacity(attributes.count / 2)
            for index in stride(from: 0, to: attributes.count, by: 2) {
                result[attributes[index]] = attributes[index + 1]
            }
            return result
        }

        private static func pseudoType(_ value: String?) -> DOM.PseudoType? {
            switch value {
            case nil:
                nil
            case "before":
                .before
            case "after":
                .after
            case let .some(value):
                .other(value)
            }
        }

        private static func shadowRootType(_ value: String?) -> DOM.ShadowRootType? {
            switch value {
            case nil:
                nil
            case "open":
                .open
            case "closed":
                .closed
            case "user-agent":
                .userAgent
            case let .some(value):
                .other(value)
            }
        }
    }
}

private extension DOM.PseudoType {
    var isBefore: Bool {
        if case .before = self {
            return true
        }
        return false
    }

    var isAfter: Bool {
        if case .after = self {
            return true
        }
        return false
    }
}
