import Foundation

package struct LiveWebInspectorProxyBackend: WebInspectorProxyBackend {
    private let transport: TransportSession

    package init(transport: TransportSession) {
        self.transport = transport
    }

    package func dispatchCommand<Payload: Sendable, Result: Sendable>(
        _ command: WebInspectorProxyCommand<Payload, Result>
    ) async throws -> WebInspectorProxyCommandResult<Result> {
        let protocolCommand = try LiveProxyCommandEncoder.protocolCommand(for: command)
        let result: ProtocolCommand.Result
        do {
            result = try await transport.send(protocolCommand)
        } catch {
            throw mapTransportError(error, domain: command.domain.rawValue, method: command.method)
        }
        let targetScopeRawValue = await targetScopeRawValue(for: command.route)
        let value = try LiveProxyCommandDecoder.decode(
            Result.self,
            for: command,
            targetScopeRawValue: targetScopeRawValue,
            from: result
        )
        return WebInspectorProxyCommandResult(
            value: value,
            modelFeedSequence: result.modelFeedSequence
        )
    }

    package func acquireEventScope<Element: Sendable>(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        domain: WebInspectorProxyEventDomain,
        buffering: WebInspectorEventBufferingPolicy,
        extract: @escaping @Sendable (WebInspectorProxyEvent) -> Element?
    ) async throws -> WebInspectorProxyEventScope<Element> {
        try await transport.acquireEventScope(
            route: route,
            targetID: targetID,
            domain: domain,
            buffering: buffering,
            extract: extract
        )
    }

    package func releaseEventScope(_ id: WebInspectorProxyEventScopeID) async throws {
        try await transport.releaseEventScope(id)
    }

    private func mapTransportError(_ error: any Error, domain: String, method: String) -> any Error {
        guard let transportError = error as? TransportSession.Error else {
            return error
        }
        switch transportError {
        case .transportClosed:
            return WebInspectorProxyError.closed
        case let .transportFailure(message):
            return WebInspectorProxyError.disconnected(message)
        case .replyTimeout:
            return WebInspectorProxyError.timeout(domain: domain, method: method)
        case let .remoteError(_, _, message):
            return WebInspectorProxyError.commandFailed(domain: domain, method: method, message: message)
        case .malformedMessage, .missingMainPageTarget, .missingTarget:
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
            parametersData: try parametersData(for: command),
            authority: command.authority
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
            return try data(["objectId": payload.objectID.unscopedRawValue])

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
            return try elementPickerModeParametersData(enabled: payload.enabled)

        case (.network, "getResponseBody"):
            let payload = try payload(command.payload, as: Network.GetResponseBodyPayload.self, command: command)
            var object: [String: Any] = ["requestId": payload.id.unscopedRawValue]
            if let backendResourceIdentifier = payload.backendResourceIdentifier {
                object["backendResourceIdentifier"] = [
                    "sourceProcessID": backendResourceIdentifier.sourceProcessID,
                    "resourceID": backendResourceIdentifier.resourceID,
                ]
            }
            return try data(object)

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
                let rawValue = context.unscopedRawValue
                object["contextId"] = Int(rawValue) ?? rawValue
            }
            if let objectGroup = payload.objectGroup {
                object["objectGroup"] = Self.objectGroupRawValue(objectGroup)
            }
            return try data(object)

        case (.runtime, "getProperties"):
            let payload = try payload(command.payload, as: Runtime.GetPropertiesPayload.self, command: command)
            return try data([
                "objectId": payload.object.unscopedRawValue,
                "ownProperties": payload.ownProperties,
            ])

        case (.runtime, "getPreview"):
            let payload = try payload(command.payload, as: Runtime.GetPreviewPayload.self, command: command)
            return try data(["objectId": payload.object.unscopedRawValue])

        case (.runtime, "getCollectionEntries"):
            let payload = try payload(command.payload, as: Runtime.GetCollectionEntriesPayload.self, command: command)
            return try data(["objectId": payload.object.unscopedRawValue])

        case (.runtime, "releaseObject"):
            let payload = try payload(command.payload, as: Runtime.ReleaseObjectPayload.self, command: command)
            return try data(["objectId": payload.id.unscopedRawValue])

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
        targetScopeRawValue: String?,
        from result: ProtocolCommand.Result
    ) throws -> Result {
        if Result.self == Void.self {
            return () as! Result
        }
        if Result.self == DOM.Node.self {
            let payload = try decode(ProtocolDOMDocumentResult.self, from: result.resultData)
            return try payload.proxyRoot() as! Result
        }
        if Result.self == DOM.Node.ID.self {
            let payload = try decode(RequestNodeResult.self, from: result.resultData)
            if let targetScopeRawValue {
                return DOM.Node.ID(payload.nodeId, scopedToTargetRawValue: targetScopeRawValue) as! Result
            }
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
            return payload.proxyMatchedStyles(targetScopeRawValue: targetScopeRawValue) as! Result
        }
        if Result.self == CSS.InlineStyles.self {
            let payload = try decode(CSSInlineStylesResult.self, from: result.resultData)
            return payload.proxyInlineStyles(targetScopeRawValue: targetScopeRawValue) as! Result
        }
        if Result.self == [CSS.ComputedProperty].self {
            let payload = try decode(CSSComputedStyleResult.self, from: result.resultData)
            return payload.computedStyle.map(\.proxyProperty) as! Result
        }
        if Result.self == CSS.Style.self {
            let payload = try decode(CSSSetStyleTextResult.self, from: result.resultData)
            return payload.style.proxyStyle(targetScopeRawValue: targetScopeRawValue) as! Result
        }
        if Result.self == CSS.Rule.self {
            let payload = try decode(CSSSetRuleSelectorResult.self, from: result.resultData)
            return payload.rule.proxyRule(targetScopeRawValue: targetScopeRawValue) as! Result
        }
        if Result.self == CSS.Rule.Grouping.self {
            let payload = try decode(CSSSetGroupingHeaderTextResult.self, from: result.resultData)
            return payload.grouping.proxyGrouping as! Result
        }
        if Result.self == Runtime.EvaluationResult.self {
            let payload = try decode(RuntimeEvaluationResultPayload.self, from: result.resultData)
            return payload.proxyResult(targetScopeRawValue: targetScopeRawValue) as! Result
        }
        if Result.self == [Runtime.PropertyDescriptor].self {
            let payload = try decode(RuntimePropertiesResultPayload.self, from: result.resultData)
            return payload.proxyProperties(targetScopeRawValue: targetScopeRawValue) as! Result
        }
        if Result.self == Runtime.ObjectPreview.self {
            let payload = try decode(RuntimePreviewResultPayload.self, from: result.resultData)
            return payload.preview.proxyPreview as! Result
        }
        if Result.self == [Runtime.CollectionEntry].self {
            let payload = try decode(RuntimeCollectionEntriesResultPayload.self, from: result.resultData)
            return payload.proxyEntries(targetScopeRawValue: targetScopeRawValue) as! Result
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

    func proxyResult(targetScopeRawValue: String?) -> Runtime.EvaluationResult {
        Runtime.EvaluationResult(
            object: result.proxyObject(targetScopeRawValue: targetScopeRawValue),
            wasThrown: wasThrown ?? false,
            savedResultIndex: savedResultIndex
        )
    }
}

private struct RuntimePropertiesResultPayload: Decodable {
    var properties: [RuntimePropertyDescriptorPayload]

    func proxyProperties(targetScopeRawValue: String?) -> [Runtime.PropertyDescriptor] {
        properties.map { $0.proxyProperty(targetScopeRawValue: targetScopeRawValue) }
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

    func proxyProperty(targetScopeRawValue: String?) -> Runtime.PropertyDescriptor {
        Runtime.PropertyDescriptor(
            name: name,
            value: value?.proxyObject(targetScopeRawValue: targetScopeRawValue),
            writable: writable,
            get: get?.proxyObject(targetScopeRawValue: targetScopeRawValue),
            set: set?.proxyObject(targetScopeRawValue: targetScopeRawValue),
            wasThrown: wasThrown,
            configurable: configurable,
            enumerable: enumerable,
            isOwn: isOwn,
            symbol: symbol?.proxyObject(targetScopeRawValue: targetScopeRawValue),
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

    func proxyEntries(targetScopeRawValue: String?) -> [Runtime.CollectionEntry] {
        entries.map { $0.proxyEntry(targetScopeRawValue: targetScopeRawValue) }
    }
}

private struct RuntimeCollectionEntryPayload: Decodable {
    var key: RuntimeRemoteObjectPayload?
    var value: RuntimeRemoteObjectPayload

    func proxyEntry(targetScopeRawValue: String?) -> Runtime.CollectionEntry {
        Runtime.CollectionEntry(
            key: key?.proxyObject(targetScopeRawValue: targetScopeRawValue),
            value: value.proxyObject(targetScopeRawValue: targetScopeRawValue)
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
