import Foundation

// How each inspector command is written to WebKit and how its reply is read.
// A command that takes no parameters and returns nothing only names its
// domain and method.

// MARK: - DOM

extension DOM.GetDocumentPayload: WebInspectorProxyCommandPayload {
    package static var domain: WebInspectorProxyDomain { .dom }
    package static var method: String { "getDocument" }

    package static func decodeResult(from data: Data, targetScope: String?) throws -> DOM.Node {
        try decodeReply(DocumentResult.self, from: data).root.proxyNode()
    }
}

extension DOM.RequestChildNodesPayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .dom }
    package static var method: String { "requestChildNodes" }

    package var owningTargetScope: String? {
        id.targetScopeRawValue
    }

    package func parameters() throws -> [String: Any] {
        [
            "nodeId": LiveProxyCommandEncoder.nodeIDValue(id),
            "depth": depth,
        ]
    }
}

extension DOM.RequestNodePayload: WebInspectorProxyCommandPayload {
    package static var domain: WebInspectorProxyDomain { .dom }
    package static var method: String { "requestNode" }

    package var owningTargetScope: String? {
        objectID.targetScopeRawValue
    }

    package func parameters() throws -> [String: Any] {
        ["objectId": objectID.unscopedRawValue]
    }

    package static func decodeResult(from data: Data, targetScope: String?) throws -> DOM.Node.ID {
        let nodeID = try decodeReply(RequestNodeResult.self, from: data).nodeId
        if let targetScope {
            return DOM.Node.ID(nodeID, scopedToTargetRawValue: targetScope)
        }
        return DOM.Node.ID(nodeID)
    }
}

extension DOM.GetOuterHTMLPayload: WebInspectorProxyCommandPayload {
    package static var domain: WebInspectorProxyDomain { .dom }
    package static var method: String { "getOuterHTML" }

    package var owningTargetScope: String? {
        id.targetScopeRawValue
    }

    package func parameters() throws -> [String: Any] {
        ["nodeId": LiveProxyCommandEncoder.nodeIDValue(id)]
    }

    package static func decodeResult(from data: Data, targetScope: String?) throws -> String {
        try decodeReply(OuterHTMLResult.self, from: data).outerHTML
    }
}

extension DOM.GetAttributesPayload: WebInspectorProxyCommandPayload {
    package static var domain: WebInspectorProxyDomain { .dom }
    package static var method: String { "getAttributes" }

    package var owningTargetScope: String? {
        id.targetScopeRawValue
    }

    package func parameters() throws -> [String: Any] {
        ["nodeId": LiveProxyCommandEncoder.nodeIDValue(id)]
    }

    package static func decodeResult(from data: Data, targetScope: String?) throws -> [DOM.Attribute] {
        try decodeReply(DOMAttributesResult.self, from: data).proxyAttributes()
    }
}

extension DOM.SetAttributeValuePayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .dom }
    package static var method: String { "setAttributeValue" }

    package var owningTargetScope: String? {
        id.targetScopeRawValue
    }

    package func parameters() throws -> [String: Any] {
        [
            "nodeId": LiveProxyCommandEncoder.nodeIDValue(id),
            "name": name,
            "value": value,
        ]
    }
}

extension DOM.SetAttributesAsTextPayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .dom }
    package static var method: String { "setAttributesAsText" }

    package var owningTargetScope: String? {
        id.targetScopeRawValue
    }

    package func parameters() throws -> [String: Any] {
        var object: [String: Any] = [
            "nodeId": LiveProxyCommandEncoder.nodeIDValue(id),
            "text": text,
        ]
        if let name {
            object["name"] = name
        }
        return object
    }
}

extension DOM.RemoveAttributePayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .dom }
    package static var method: String { "removeAttribute" }

    package var owningTargetScope: String? {
        id.targetScopeRawValue
    }

    package func parameters() throws -> [String: Any] {
        [
            "nodeId": LiveProxyCommandEncoder.nodeIDValue(id),
            "name": name,
        ]
    }
}

extension DOM.SetOuterHTMLPayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .dom }
    package static var method: String { "setOuterHTML" }

    package var owningTargetScope: String? {
        id.targetScopeRawValue
    }

    package func parameters() throws -> [String: Any] {
        [
            "nodeId": LiveProxyCommandEncoder.nodeIDValue(id),
            "outerHTML": html,
        ]
    }
}

extension DOM.RemoveNodePayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .dom }
    package static var method: String { "removeNode" }

    package var owningTargetScope: String? {
        id.targetScopeRawValue
    }

    package func parameters() throws -> [String: Any] {
        ["nodeId": LiveProxyCommandEncoder.nodeIDValue(id)]
    }
}

extension DOM.MarkUndoableStatePayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .dom }
    package static var method: String { "markUndoableState" }
}

extension DOM.HighlightNodePayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .dom }
    package static var method: String { "highlightNode" }

    package func parameters() throws -> [String: Any] {
        [
            "nodeId": LiveProxyCommandEncoder.nodeIDValue(id),
            "highlightConfig": LiveProxyCommandEncoder.highlightConfig(),
        ]
    }
}

extension DOM.HideHighlightPayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .dom }
    package static var method: String { "hideHighlight" }
}

extension DOM.SetInspectModeEnabledPayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .dom }
    package static var method: String { "setInspectModeEnabled" }

    package func parameters() throws -> [String: Any] {
        var object: [String: Any] = ["enabled": enabled]
        if enabled {
            object["highlightConfig"] = LiveProxyCommandEncoder.highlightConfig()
        }
        return object
    }
}

extension DOM.UndoPayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .dom }
    package static var method: String { "undo" }
}

extension DOM.RedoPayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .dom }
    package static var method: String { "redo" }
}

// MARK: - CSS

extension CSS.EnablePayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .css }
    package static var method: String { "enable" }
}

extension CSS.DisablePayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .css }
    package static var method: String { "disable" }
}

extension CSS.GetMatchedStylesForNodePayload: WebInspectorProxyCommandPayload {
    package static var domain: WebInspectorProxyDomain { .css }
    package static var method: String { "getMatchedStylesForNode" }

    package var owningTargetScope: String? {
        node.targetScopeRawValue
    }

    package func parameters() throws -> [String: Any] {
        ["nodeId": LiveProxyCommandEncoder.nodeIDValue(node)]
    }

    package static func decodeResult(from data: Data, targetScope: String?) throws -> CSS.MatchedStyles {
        try decodeReply(CSSMatchedStylesResult.self, from: data)
            .proxyMatchedStyles(targetScopeRawValue: targetScope)
    }
}

extension CSS.GetComputedStyleForNodePayload: WebInspectorProxyCommandPayload {
    package static var domain: WebInspectorProxyDomain { .css }
    package static var method: String { "getComputedStyleForNode" }

    package var owningTargetScope: String? {
        node.targetScopeRawValue
    }

    package func parameters() throws -> [String: Any] {
        ["nodeId": LiveProxyCommandEncoder.nodeIDValue(node)]
    }

    package static func decodeResult(from data: Data, targetScope: String?) throws -> [CSS.ComputedProperty] {
        try decodeReply(CSSComputedStyleResult.self, from: data).computedStyle.map(\.proxyProperty)
    }
}

extension CSS.GetInlineStylesForNodePayload: WebInspectorProxyCommandPayload {
    package static var domain: WebInspectorProxyDomain { .css }
    package static var method: String { "getInlineStylesForNode" }

    package var owningTargetScope: String? {
        node.targetScopeRawValue
    }

    package func parameters() throws -> [String: Any] {
        ["nodeId": LiveProxyCommandEncoder.nodeIDValue(node)]
    }

    package static func decodeResult(from data: Data, targetScope: String?) throws -> CSS.InlineStyles {
        try decodeReply(CSSInlineStylesResult.self, from: data)
            .proxyInlineStyles(targetScopeRawValue: targetScope)
    }
}

extension CSS.SetStyleTextPayload: WebInspectorProxyCommandPayload {
    package static var domain: WebInspectorProxyDomain { .css }
    package static var method: String { "setStyleText" }

    package var owningTargetScope: String? {
        id.targetScopeRawValue
    }

    package func parameters() throws -> [String: Any] {
        [
            "styleId": try LiveProxyCommandEncoder.styleSheetOrdinal(
                id.unscopedRawValue,
                describedAs: "CSS style identifier is not backed by a WebKit CSSStyleId.",
                for: Self.self
            ),
            "text": text,
        ]
    }

    package static func decodeResult(from data: Data, targetScope: String?) throws -> CSS.Style {
        try decodeReply(CSSSetStyleTextResult.self, from: data)
            .style.proxyStyle(targetScopeRawValue: targetScope)
    }
}

extension CSS.SetStyleSheetTextPayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .css }
    package static var method: String { "setStyleSheetText" }

    package var owningTargetScope: String? {
        id.targetScopeRawValue
    }

    package func parameters() throws -> [String: Any] {
        [
            "styleSheetId": id.unscopedRawValue,
            "text": text,
        ]
    }
}

extension CSS.SetRuleSelectorPayload: WebInspectorProxyCommandPayload {
    package static var domain: WebInspectorProxyDomain { .css }
    package static var method: String { "setRuleSelector" }

    package var owningTargetScope: String? {
        id.targetScopeRawValue
    }

    package func parameters() throws -> [String: Any] {
        [
            "ruleId": try LiveProxyCommandEncoder.styleSheetOrdinal(
                id.unscopedRawValue,
                describedAs: "CSS rule identifier is not backed by a WebKit CSSRuleId.",
                for: Self.self
            ),
            "selector": selector,
        ]
    }

    package static func decodeResult(from data: Data, targetScope: String?) throws -> CSS.Rule {
        try decodeReply(CSSSetRuleSelectorResult.self, from: data)
            .rule.proxyRule(targetScopeRawValue: targetScope)
    }
}

extension CSS.SetGroupingHeaderTextPayload: WebInspectorProxyCommandPayload {
    package static var domain: WebInspectorProxyDomain { .css }
    package static var method: String { "setGroupingHeaderText" }

    package var owningTargetScope: String? {
        id.targetScopeRawValue
    }

    package func parameters() throws -> [String: Any] {
        [
            "ruleId": try LiveProxyCommandEncoder.styleSheetOrdinal(
                id.unscopedRawValue,
                describedAs: "CSS rule identifier is not backed by a WebKit CSSRuleId.",
                for: Self.self
            ),
            "headerText": text,
        ]
    }

    package static func decodeResult(from data: Data, targetScope: String?) throws -> CSS.Rule.Grouping {
        try decodeReply(CSSSetGroupingHeaderTextResult.self, from: data).grouping.proxyGrouping
    }
}

// MARK: - Network

extension Network.EnablePayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .network }
    package static var method: String { "enable" }
}

extension Network.DisablePayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .network }
    package static var method: String { "disable" }
}

extension Network.GetResponseBodyPayload: WebInspectorProxyCommandPayload {
    package static var domain: WebInspectorProxyDomain { .network }
    package static var method: String { "getResponseBody" }

    package var owningTargetScope: String? {
        id.targetScopeRawValue
    }

    package func parameters() throws -> [String: Any] {
        var object: [String: Any] = ["requestId": id.unscopedRawValue]
        if let backendResourceIdentifier {
            object["backendResourceIdentifier"] = [
                "sourceProcessID": backendResourceIdentifier.sourceProcessID,
                "resourceID": backendResourceIdentifier.resourceID,
            ]
        }
        return object
    }

    package static func decodeResult(from data: Data, targetScope: String?) throws -> Network.Body {
        let reply = try decodeReply(ResponseBodyResult.self, from: data)
        return Network.Body(data: reply.body, base64Encoded: reply.base64Encoded)
    }
}

// MARK: - Console

extension Console.EnablePayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .console }
    package static var method: String { "enable" }
}

extension Console.DisablePayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .console }
    package static var method: String { "disable" }
}

extension Console.ClearMessagesPayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .console }
    package static var method: String { "clearMessages" }
}

extension Console.SetLoggingChannelLevelPayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .console }
    package static var method: String { "setLoggingChannelLevel" }

    package func parameters() throws -> [String: Any] {
        [
            "source": source.rawValue,
            "level": level.rawValue,
        ]
    }
}

// MARK: - Runtime

extension Runtime.EnablePayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .runtime }
    package static var method: String { "enable" }
}

extension Runtime.DisablePayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .runtime }
    package static var method: String { "disable" }
}

extension Runtime.EvaluatePayload: WebInspectorProxyCommandPayload {
    package static var domain: WebInspectorProxyDomain { .runtime }
    package static var method: String { "evaluate" }

    package var owningTargetScope: String? {
        context?.targetScopeRawValue
    }

    package func parameters() throws -> [String: Any] {
        var object: [String: Any] = ["expression": expression]
        if let context {
            let rawValue = context.unscopedRawValue
            object["contextId"] = Int(rawValue) ?? rawValue
        }
        return object
    }

    package static func decodeResult(from data: Data, targetScope: String?) throws -> Runtime.EvaluationResult {
        try decodeReply(RuntimeEvaluationResultPayload.self, from: data)
            .proxyResult(targetScopeRawValue: targetScope)
    }
}

extension Runtime.GetPropertiesPayload: WebInspectorProxyCommandPayload {
    package static var domain: WebInspectorProxyDomain { .runtime }
    package static var method: String { "getProperties" }

    package var owningTargetScope: String? {
        object.targetScopeRawValue
    }

    package func parameters() throws -> [String: Any] {
        [
            "objectId": object.unscopedRawValue,
            "ownProperties": ownProperties,
        ]
    }

    package static func decodeResult(from data: Data, targetScope: String?) throws -> [Runtime.PropertyDescriptor] {
        try decodeReply(RuntimePropertiesResultPayload.self, from: data)
            .proxyProperties(targetScopeRawValue: targetScope)
    }
}

extension Runtime.GetPreviewPayload: WebInspectorProxyCommandPayload {
    package static var domain: WebInspectorProxyDomain { .runtime }
    package static var method: String { "getPreview" }

    package var owningTargetScope: String? {
        object.targetScopeRawValue
    }

    package func parameters() throws -> [String: Any] {
        ["objectId": object.unscopedRawValue]
    }

    package static func decodeResult(from data: Data, targetScope: String?) throws -> Runtime.ObjectPreview {
        try decodeReply(RuntimePreviewResultPayload.self, from: data).preview.proxyPreview
    }
}

extension Runtime.GetCollectionEntriesPayload: WebInspectorProxyCommandPayload {
    package static var domain: WebInspectorProxyDomain { .runtime }
    package static var method: String { "getCollectionEntries" }

    package var owningTargetScope: String? {
        object.targetScopeRawValue
    }

    package func parameters() throws -> [String: Any] {
        ["objectId": object.unscopedRawValue]
    }

    package static func decodeResult(from data: Data, targetScope: String?) throws -> [Runtime.CollectionEntry] {
        try decodeReply(RuntimeCollectionEntriesResultPayload.self, from: data)
            .proxyEntries(targetScopeRawValue: targetScope)
    }
}

extension Runtime.ReleaseObjectPayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .runtime }
    package static var method: String { "releaseObject" }

    package var owningTargetScope: String? {
        id.targetScopeRawValue
    }

    package func parameters() throws -> [String: Any] {
        ["objectId": id.unscopedRawValue]
    }
}

extension Runtime.ReleaseObjectGroupPayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .runtime }
    package static var method: String { "releaseObjectGroup" }

    package func parameters() throws -> [String: Any] {
        switch group {
        case .console:
            ["objectGroup": "console"]
        case let .other(value):
            ["objectGroup": value]
        }
    }
}

// MARK: - Page

extension Page.EnablePayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .page }
    package static var method: String { "enable" }
}

extension Page.DisablePayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .page }
    package static var method: String { "disable" }
}

extension Page.ReloadPayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .page }
    package static var method: String { "reload" }

    package func parameters() throws -> [String: Any] {
        ["ignoreCache": ignoringCache]
    }
}

extension Page.ResourceContentPayload: WebInspectorProxyCommandPayload {
    package static var domain: WebInspectorProxyDomain { .page }
    package static var method: String { "getResourceContent" }

    package func parameters() throws -> [String: Any] {
        [
            "frameId": frameID.rawValue,
            "url": url,
        ]
    }

    package static func decodeResult(from data: Data, targetScope: String?) throws -> Network.Body {
        let reply = try decodeReply(ResourceContentResult.self, from: data)
        return Network.Body(data: reply.content, base64Encoded: reply.base64Encoded)
    }
}

extension Page.ResourceTreePayload: WebInspectorProxyCommandPayload {
    package static var domain: WebInspectorProxyDomain { .page }
    package static var method: String { "getResourceTree" }

    package static func decodeResult(from data: Data, targetScope: String?) throws -> Page.ResourceTree {
        try decodeReply(ResourceTreeResult.self, from: data).frameTree
    }
}

// MARK: - Inspector

extension Inspector.EnablePayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .inspector }
    package static var method: String { "enable" }
}

extension Inspector.DisablePayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .inspector }
    package static var method: String { "disable" }
}

extension Inspector.InitializedPayload: WebInspectorProxyCommandPayload {
    package typealias Result = Void
    package static var domain: WebInspectorProxyDomain { .inspector }
    package static var method: String { "initialized" }
}

// MARK: - Wire encoding

enum LiveProxyCommandEncoder {
    static func protocolCommand<Payload: WebInspectorProxyCommandPayload>(
        for command: WebInspectorProxyCommand<Payload>
    ) throws -> ProtocolCommand {
        ProtocolCommand(
            domain: protocolDomain(for: Payload.domain),
            method: "\(Payload.domain.rawValue).\(Payload.method)",
            routing: routing(for: command.route),
            parametersData: try data(command.payload.parameters())
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

    /// WebKit node identifiers are integers on the wire.
    fileprivate static func nodeIDValue(_ id: DOM.Node.ID) -> Any {
        let rawValue = id.unscopedRawValue
        if let value = Int(rawValue) {
            return value
        }
        return rawValue
    }

    /// The wire form of WebKit's `CSSStyleId` and `CSSRuleId`: a stylesheet
    /// and an ordinal in it.
    fileprivate static func styleSheetOrdinal<Payload: WebInspectorProxyCommandPayload>(
        _ rawValue: String,
        describedAs failureMessage: String,
        for payload: Payload.Type
    ) throws -> [String: Any] {
        let components = rawValue.split(separator: CSS.styleIdentifierSeparator, omittingEmptySubsequences: false)
        guard components.count == 2,
              let ordinal = Int(components[1]) else {
            throw WebInspectorProxyError.commandFailed(
                domain: Payload.domain.rawValue,
                method: Payload.method,
                message: failureMessage
            )
        }
        return [
            "styleSheetId": String(components[0]),
            "ordinal": ordinal,
        ]
    }

    fileprivate static func highlightConfig() -> [String: Any] {
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
}

// MARK: - Reply payloads

private func decodeReply<Payload: Decodable>(_ type: Payload.Type, from data: Data) throws -> Payload {
    try JSONDecoder().decode(type, from: data)
}

private struct ResourceTreeResult: Decodable {
    let frameTree: Page.ResourceTree
}

private struct ResourceContentResult: Decodable {
    let content: String
    let base64Encoded: Bool
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
    var styleSheetId: String
    var ordinal: Int

    var rawValue: String {
        "\(styleSheetId)\(CSS.styleIdentifierSeparator)\(ordinal)"
    }
}

private struct CSSRuleIDPayload: Decodable {
    var styleSheetId: String
    var ordinal: Int

    var rawValue: String {
        "\(styleSheetId)\(CSS.styleIdentifierSeparator)\(ordinal)"
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
            id: CSS.Property.ID("\(styleID)\(CSS.styleIdentifierSeparator)\(index)"),
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
