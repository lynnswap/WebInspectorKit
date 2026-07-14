import Foundation

private enum DomainCommandJSON {
    static func method(_ domain: String, _ name: String) -> WebInspectorProtocolMethod {
        WebInspectorProtocolMethod(
            domain: WebInspectorProtocolDomainToken(rawValue: domain),
            name: name
        )
    }

    static func data(_ object: [String: Any]) throws -> Data {
        try WebInspectorWireJSON.objectData(object)
    }

    static func target(_ rawValue: String?) -> WebInspectorCommandTarget {
        rawValue.map { .target(WebInspectorTarget.ID($0)) } ?? .endpoint
    }

    static func nodeID(_ id: DOM.Node.ID) -> Any {
        Int(id.unscopedRawValue) ?? id.unscopedRawValue
    }

    static func emptyVoid(_ domain: String, _ name: String) -> WebInspectorWireCommand<Void> {
        .void(method(domain, name))
    }
}

package enum DOMWireCoding {
    package static let eventDomain = WebInspectorProtocolDomainToken(rawValue: "DOM")

    package static func getDocument() -> WebInspectorWireCommand<DOM.Node> {
        WebInspectorWireCommand(method: DomainCommandJSON.method("DOM", "getDocument")) { data, context in
            let payload = try liveProxyDecode(ProtocolDOMDocumentResult.self, from: data)
            return try scope(payload.proxyRoot(), to: context.targetScopeRawValue)
        }
    }

    package static func requestChildNodes(_ id: DOM.Node.ID, depth: Int) throws -> WebInspectorWireCommand<Void> {
        .void(
            DomainCommandJSON.method("DOM", "requestChildNodes"),
            parameters: try DomainCommandJSON.data(["nodeId": DomainCommandJSON.nodeID(id), "depth": depth]),
            target: DomainCommandJSON.target(id.targetScopeRawValue)
        )
    }

    package static func requestNode(_ object: Runtime.RemoteObject.ID) throws -> WebInspectorWireCommand<DOM.Node.ID> {
        WebInspectorWireCommand(
            method: DomainCommandJSON.method("DOM", "requestNode"),
            parameters: try DomainCommandJSON.data(["objectId": object.unscopedRawValue]),
            target: .currentPage
        ) { data, _ in
            let payload = try liveProxyDecode(DOMRequestNodeResult.self, from: data)
            return DOM.Node.ID(payload.nodeID)
        }
    }

    package static func outerHTML(_ id: DOM.Node.ID) throws -> WebInspectorWireCommand<String> {
        WebInspectorWireCommand(
            method: DomainCommandJSON.method("DOM", "getOuterHTML"),
            parameters: try DomainCommandJSON.data(["nodeId": DomainCommandJSON.nodeID(id)]),
            target: DomainCommandJSON.target(id.targetScopeRawValue)
        ) { data, _ in try liveProxyDecode(DOMOuterHTMLResult.self, from: data).outerHTML }
    }

    package static func attributes(_ id: DOM.Node.ID) throws -> WebInspectorWireCommand<[DOM.Attribute]> {
        WebInspectorWireCommand(
            method: DomainCommandJSON.method("DOM", "getAttributes"),
            parameters: try DomainCommandJSON.data(["nodeId": DomainCommandJSON.nodeID(id)]),
            target: DomainCommandJSON.target(id.targetScopeRawValue)
        ) { data, _ in try liveProxyDecode(DOMAttributesResult.self, from: data).proxyAttributes() }
    }

    package static func setAttribute(_ id: DOM.Node.ID, name: String, value: String) throws -> WebInspectorWireCommand<Void> {
        try nodeVoid("setAttributeValue", id: id, extra: ["name": name, "value": value])
    }

    package static func setAttributes(_ id: DOM.Node.ID, text: String, name: String?) throws -> WebInspectorWireCommand<Void> {
        var extra: [String: Any] = ["text": text]
        if let name { extra["name"] = name }
        return try nodeVoid("setAttributesAsText", id: id, extra: extra)
    }

    package static func removeAttribute(_ id: DOM.Node.ID, name: String) throws -> WebInspectorWireCommand<Void> {
        try nodeVoid("removeAttribute", id: id, extra: ["name": name])
    }

    package static func setOuterHTML(_ id: DOM.Node.ID, html: String) throws -> WebInspectorWireCommand<Void> {
        try nodeVoid("setOuterHTML", id: id, extra: ["outerHTML": html])
    }

    package static func removeNode(_ id: DOM.Node.ID) throws -> WebInspectorWireCommand<Void> {
        try nodeVoid("removeNode", id: id)
    }

    package static func highlightNode(_ id: DOM.Node.ID) throws -> WebInspectorWireCommand<Void> {
        try nodeVoid("highlightNode", id: id, extra: ["highlightConfig": highlightConfig()])
    }

    package static func setInspectMode(_ enabled: Bool) throws -> WebInspectorWireCommand<Void> {
        .void(
            DomainCommandJSON.method("DOM", "setInspectModeEnabled"),
            parameters: try elementPickerModeParametersData(enabled: enabled),
            target: .currentPage
        )
    }

    package static let hideHighlight = DomainCommandJSON.emptyVoid("DOM", "hideHighlight")
    package static let markUndoableState = DomainCommandJSON.emptyVoid("DOM", "markUndoableState")
    package static let undo = DomainCommandJSON.emptyVoid("DOM", "undo")
    package static let redo = DomainCommandJSON.emptyVoid("DOM", "redo")

    package static let capability = WebInspectorDomainCapabilityDescriptor(
        domain: eventDomain,
        enable: nil,
        release: .retainEnabled,
        reacquisition: .retainPhysicalState,
        mutationOwner: .init(rawValue: "DOM")
    )

    private static func nodeVoid(
        _ name: String,
        id: DOM.Node.ID,
        extra: [String: Any] = [:]
    ) throws -> WebInspectorWireCommand<Void> {
        var object = extra
        object["nodeId"] = DomainCommandJSON.nodeID(id)
        return .void(
            DomainCommandJSON.method("DOM", name),
            parameters: try DomainCommandJSON.data(object),
            target: DomainCommandJSON.target(id.targetScopeRawValue)
        )
    }

    private static func highlightConfig() -> [String: Any] {
        [
            "showInfo": false,
            "contentColor": color(111, 168, 220, 0.66),
            "paddingColor": color(147, 196, 125, 0.66),
            "borderColor": color(255, 229, 153, 0.66),
            "marginColor": color(246, 178, 107, 0.66),
        ]
    }

    private static func color(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Double) -> [String: Any] {
        ["r": red, "g": green, "b": blue, "a": alpha]
    }

    private static func scope(_ node: DOM.Node, to target: String?) -> DOM.Node {
        guard let target else { return node }
        return DomainEventIdentityScope.domNode(node, target: target)
    }
}

package enum NetworkWireCoding {
    package static let eventDomain = WebInspectorProtocolDomainToken(rawValue: "Network")

    package static func responseBody(
        id: Network.Request.ID,
        backendResourceIdentifier: Network.BackendResourceID?
    ) throws -> WebInspectorWireCommand<Network.Body> {
        var object: [String: Any] = ["requestId": id.unscopedRawValue]
        if let backendResourceIdentifier {
            object["backendResourceIdentifier"] = [
                "sourceProcessID": backendResourceIdentifier.sourceProcessID,
                "resourceID": backendResourceIdentifier.resourceID,
            ]
        }
        return WebInspectorWireCommand(
            method: DomainCommandJSON.method("Network", "getResponseBody"),
            parameters: try DomainCommandJSON.data(object),
            target: DomainCommandJSON.target(id.targetScopeRawValue)
        ) { data, _ in
            let payload = try liveProxyDecode(NetworkResponseBodyResult.self, from: data)
            return Network.Body(data: payload.body, base64Encoded: payload.base64Encoded)
        }
    }

    package static let capability = WebInspectorDomainCapabilityDescriptor(
        domain: eventDomain,
        agentResolution: .currentPage,
        enable: DomainCommandJSON.emptyVoid("Network", "enable"),
        release: .retainEnabled,
        reacquisition: .retainPhysicalState,
        mutationOwner: .init(rawValue: "Network")
    )
}

package enum ConsoleWireCoding {
    package static let eventDomain = WebInspectorProtocolDomainToken(rawValue: "Console")

    package static let clearMessages = DomainCommandJSON.emptyVoid("Console", "clearMessages")

    package static func setLoggingChannelLevel(
        _ source: Console.ChannelSource,
        _ level: Console.ChannelLevel
    ) throws -> WebInspectorWireCommand<Void> {
        .void(
            DomainCommandJSON.method("Console", "setLoggingChannelLevel"),
            parameters: try DomainCommandJSON.data(["source": source.rawValue, "level": level.rawValue])
        )
    }

    package static let capability = WebInspectorDomainCapabilityDescriptor(
        domain: eventDomain,
        enable: DomainCommandJSON.emptyVoid("Console", "enable"),
        release: .disable(DomainCommandJSON.emptyVoid("Console", "disable")),
        mutationOwner: .init(rawValue: "Console")
    )
}

package enum RuntimeWireCoding {
    package static let eventDomain = WebInspectorProtocolDomainToken(rawValue: "Runtime")

    package static func evaluate(
        expression: String,
        context: Runtime.ExecutionContext.ID?,
        objectGroup: Runtime.ObjectGroup?
    ) throws -> WebInspectorWireCommand<Runtime.EvaluationResult> {
        var object: [String: Any] = ["expression": expression]
        if let context {
            object["contextId"] = Int(context.unscopedRawValue) ?? context.unscopedRawValue
        }
        if let objectGroup { object["objectGroup"] = objectGroup.rawProtocolValue }
        return WebInspectorWireCommand(
            method: DomainCommandJSON.method("Runtime", "evaluate"),
            parameters: try DomainCommandJSON.data(object),
            target: DomainCommandJSON.target(context?.targetScopeRawValue)
        ) { data, decodeContext in
            try liveProxyDecode(RuntimeEvaluationWireResult.self, from: data)
                .proxyResult(targetScopeRawValue: decodeContext.targetScopeRawValue)
        }
    }

    package static func properties(
        object: Runtime.RemoteObject.ID,
        ownProperties: Bool
    ) throws -> WebInspectorWireCommand<[Runtime.PropertyDescriptor]> {
        WebInspectorWireCommand(
            method: DomainCommandJSON.method("Runtime", "getProperties"),
            parameters: try DomainCommandJSON.data(["objectId": object.unscopedRawValue, "ownProperties": ownProperties]),
            target: DomainCommandJSON.target(object.targetScopeRawValue)
        ) { data, context in
            try liveProxyDecode(RuntimePropertiesWireResult.self, from: data)
                .proxyProperties(targetScopeRawValue: context.targetScopeRawValue)
        }
    }

    package static func preview(_ object: Runtime.RemoteObject.ID) throws -> WebInspectorWireCommand<Runtime.ObjectPreview> {
        WebInspectorWireCommand(
            method: DomainCommandJSON.method("Runtime", "getPreview"),
            parameters: try DomainCommandJSON.data(["objectId": object.unscopedRawValue]),
            target: DomainCommandJSON.target(object.targetScopeRawValue)
        ) { data, _ in try liveProxyDecode(RuntimePreviewWireResult.self, from: data).preview.proxyPreview }
    }

    package static func collectionEntries(
        _ object: Runtime.RemoteObject.ID
    ) throws -> WebInspectorWireCommand<[Runtime.CollectionEntry]> {
        WebInspectorWireCommand(
            method: DomainCommandJSON.method("Runtime", "getCollectionEntries"),
            parameters: try DomainCommandJSON.data(["objectId": object.unscopedRawValue]),
            target: DomainCommandJSON.target(object.targetScopeRawValue)
        ) { data, context in
            try liveProxyDecode(RuntimeCollectionEntriesWireResult.self, from: data)
                .proxyEntries(targetScopeRawValue: context.targetScopeRawValue)
        }
    }

    package static func releaseObject(_ id: Runtime.RemoteObject.ID) throws -> WebInspectorWireCommand<Void> {
        .void(
            DomainCommandJSON.method("Runtime", "releaseObject"),
            parameters: try DomainCommandJSON.data(["objectId": id.unscopedRawValue]),
            target: DomainCommandJSON.target(id.targetScopeRawValue)
        )
    }

    package static func releaseObjectGroup(_ group: Runtime.ObjectGroup) throws -> WebInspectorWireCommand<Void> {
        .void(
            DomainCommandJSON.method("Runtime", "releaseObjectGroup"),
            parameters: try DomainCommandJSON.data(["objectGroup": group.rawProtocolValue])
        )
    }

    package static let capability = WebInspectorDomainCapabilityDescriptor(
        domain: eventDomain,
        enable: DomainCommandJSON.emptyVoid("Runtime", "enable"),
        release: .disable(DomainCommandJSON.emptyVoid("Runtime", "disable")),
        mutationOwner: .init(rawValue: "Runtime")
    )
}

package enum CSSWireCoding {
    package static let eventDomain = WebInspectorProtocolDomainToken(rawValue: "CSS")

    package static func matchedStyles(_ node: DOM.Node.ID) throws -> WebInspectorWireCommand<CSS.MatchedStyles> {
        WebInspectorWireCommand(
            method: DomainCommandJSON.method("CSS", "getMatchedStylesForNode"),
            parameters: try DomainCommandJSON.data(["nodeId": DomainCommandJSON.nodeID(node)]),
            target: DomainCommandJSON.target(node.targetScopeRawValue)
        ) { data, context in
            try liveProxyDecode(CSSMatchedStylesWireResult.self, from: data)
                .proxyMatchedStyles(targetScopeRawValue: context.targetScopeRawValue)
        }
    }

    package static func computedStyle(_ node: DOM.Node.ID) throws -> WebInspectorWireCommand<[CSS.ComputedProperty]> {
        WebInspectorWireCommand(
            method: DomainCommandJSON.method("CSS", "getComputedStyleForNode"),
            parameters: try DomainCommandJSON.data(["nodeId": DomainCommandJSON.nodeID(node)]),
            target: DomainCommandJSON.target(node.targetScopeRawValue)
        ) { data, _ in try liveProxyDecode(CSSComputedStyleWireResult.self, from: data).computedStyle.map(\.proxyProperty) }
    }

    package static func inlineStyles(_ node: DOM.Node.ID) throws -> WebInspectorWireCommand<CSS.InlineStyles> {
        WebInspectorWireCommand(
            method: DomainCommandJSON.method("CSS", "getInlineStylesForNode"),
            parameters: try DomainCommandJSON.data(["nodeId": DomainCommandJSON.nodeID(node)]),
            target: DomainCommandJSON.target(node.targetScopeRawValue)
        ) { data, context in
            try liveProxyDecode(CSSInlineStylesWireResult.self, from: data)
                .proxyInlineStyles(targetScopeRawValue: context.targetScopeRawValue)
        }
    }

    package static func setStyleText(_ id: CSS.Style.ID, text: String) throws -> WebInspectorWireCommand<CSS.Style> {
        WebInspectorWireCommand(
            method: DomainCommandJSON.method("CSS", "setStyleText"),
            parameters: try DomainCommandJSON.data(["styleId": try styleID(id.unscopedRawValue), "text": text]),
            target: DomainCommandJSON.target(id.targetScopeRawValue)
        ) { data, context in
            try liveProxyDecode(CSSSetStyleTextWireResult.self, from: data)
                .style.proxyStyle(targetScopeRawValue: context.targetScopeRawValue)
        }
    }

    package static func setStyleSheetText(_ id: CSS.StyleSheet.ID, text: String) throws -> WebInspectorWireCommand<Void> {
        .void(
            DomainCommandJSON.method("CSS", "setStyleSheetText"),
            parameters: try DomainCommandJSON.data(["styleSheetId": id.unscopedRawValue, "text": text]),
            target: DomainCommandJSON.target(id.targetScopeRawValue)
        )
    }

    package static func setRuleSelector(_ id: CSS.Rule.ID, selector: String) throws -> WebInspectorWireCommand<CSS.Rule> {
        WebInspectorWireCommand(
            method: DomainCommandJSON.method("CSS", "setRuleSelector"),
            parameters: try DomainCommandJSON.data(["ruleId": try styleID(id.unscopedRawValue), "selector": selector]),
            target: DomainCommandJSON.target(id.targetScopeRawValue)
        ) { data, context in
            try liveProxyDecode(CSSSetRuleSelectorWireResult.self, from: data)
                .rule.proxyRule(targetScopeRawValue: context.targetScopeRawValue)
        }
    }

    package static func setGroupingHeaderText(_ id: CSS.Rule.ID, text: String) throws -> WebInspectorWireCommand<CSS.Rule.Grouping> {
        WebInspectorWireCommand(
            method: DomainCommandJSON.method("CSS", "setGroupingHeaderText"),
            parameters: try DomainCommandJSON.data(["ruleId": try styleID(id.unscopedRawValue), "headerText": text]),
            target: DomainCommandJSON.target(id.targetScopeRawValue)
        ) { data, _ in try liveProxyDecode(CSSSetGroupingHeaderTextWireResult.self, from: data).grouping.proxyGrouping }
    }

    package static let capability = WebInspectorDomainCapabilityDescriptor(
        domain: eventDomain,
        dependencies: [PageWireCoding.capability],
        enable: DomainCommandJSON.emptyVoid("CSS", "enable"),
        release: .disable(DomainCommandJSON.emptyVoid("CSS", "disable")),
        mutationOwner: .init(rawValue: "CSS")
    )

    private static func styleID(_ rawValue: String) throws -> [String: Any] {
        let components = rawValue.split(separator: CSSWireStyleID.separator, omittingEmptySubsequences: false)
        guard components.count == 2, let ordinal = Int(components[1]) else {
            throw WebInspectorProxyError.staleIdentifier
        }
        return ["styleSheetId": String(components[0]), "ordinal": ordinal]
    }
}

package enum PageWireCoding {
    package static let eventDomain = WebInspectorProtocolDomainToken(rawValue: "Page")

    package static func reload(ignoringCache: Bool) throws -> WebInspectorWireCommand<Void> {
        .void(
            DomainCommandJSON.method("Page", "reload"),
            parameters: try DomainCommandJSON.data(["ignoreCache": ignoringCache])
        )
    }

    package static func resourceTree() -> WebInspectorWireCommand<Page.ResourceTree> {
        WebInspectorWireCommand(method: DomainCommandJSON.method("Page", "getResourceTree")) { data, _ in
            try liveProxyDecode(PageResourceTreeResult.self, from: data).frameTree.proxyTree
        }
    }

    package static func resourceContent(
        frameID: FrameID,
        url: String
    ) throws -> WebInspectorWireCommand<Page.ResourceContent> {
        WebInspectorWireCommand(
            method: DomainCommandJSON.method("Page", "getResourceContent"),
            parameters: try DomainCommandJSON.data(["frameId": frameID.rawValue, "url": url])
        ) { data, _ in
            let payload = try liveProxyDecode(PageResourceContentResult.self, from: data)
            return Page.ResourceContent(content: payload.content, base64Encoded: payload.base64Encoded)
        }
    }

    package static let capability = WebInspectorDomainCapabilityDescriptor(
        domain: eventDomain,
        agentResolution: .currentPage,
        enable: DomainCommandJSON.emptyVoid("Page", "enable"),
        release: .disable(DomainCommandJSON.emptyVoid("Page", "disable")),
        mutationOwner: .init(rawValue: "Page")
    )
}

private struct PageResourceTreeResult: Decodable {
    let frameTree: PageResourceTreePayload
}

private struct PageResourceTreePayload: Decodable {
    let frame: PageResourceFramePayload
    let childFrames: [PageResourceTreePayload]?
    let resources: [PageResourcePayload]

    var proxyTree: Page.ResourceTree {
        Page.ResourceTree(
            frame: frame.proxyFrame,
            childFrames: (childFrames ?? []).map(\.proxyTree),
            resources: resources.map(\.proxyResource)
        )
    }
}

private struct PageResourceFramePayload: Decodable {
    let id: String
    let parentId: String?
    let loaderId: String?
    let name: String?
    let url: String
    let securityOrigin: String?
    let mimeType: String?

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

private struct PageResourcePayload: Decodable {
    let url: String
    let type: String
    let mimeType: String
    let failed: Bool?
    let canceled: Bool?
    let sourceMapURL: String?
    let targetId: String?

    var proxyResource: Page.Resource {
        Page.Resource(
            url: url,
            type: Network.ResourceType(rawValue: type),
            mimeType: mimeType,
            failed: failed ?? false,
            canceled: canceled ?? false,
            sourceMapURL: sourceMapURL,
            targetID: targetId
        )
    }
}

private struct PageResourceContentResult: Decodable {
    let content: String
    let base64Encoded: Bool
}

package enum InspectorWireCoding {
    package static let eventDomain = WebInspectorProtocolDomainToken(rawValue: "Inspector")
    package static let enable = DomainCommandJSON.emptyVoid("Inspector", "enable")
    package static let disable = DomainCommandJSON.emptyVoid("Inspector", "disable")
    package static let initialized = DomainCommandJSON.emptyVoid("Inspector", "initialized")

    package static let capability = WebInspectorDomainCapabilityDescriptor(
        domain: eventDomain,
        enable: enable,
        release: .disable(disable),
        mutationOwner: .init(rawValue: "Inspector")
    )
}

private struct DOMRequestNodeResult: Decodable {
    let nodeID: String
    private enum CodingKeys: String, CodingKey { case nodeID = "nodeId" }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try container.decodeStringOrInteger(forKey: .nodeID)
    }
}

private struct DOMOuterHTMLResult: Decodable { let outerHTML: String }

private struct DOMAttributesResult: Decodable {
    let attributes: [String]
    func proxyAttributes() throws -> [DOM.Attribute] {
        guard attributes.count.isMultiple(of: 2) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Odd DOM attribute vector."))
        }
        return stride(from: 0, to: attributes.count, by: 2).map {
            DOM.Attribute(name: attributes[$0], value: attributes[$0 + 1])
        }
    }
}

private struct NetworkResponseBodyResult: Decodable {
    let body: String
    let base64Encoded: Bool
}

private struct CSSMatchedStylesWireResult: Decodable {
    let matchedCSSRules: [CSSRuleMatchWirePayload]?
    let pseudoElements: [CSSPseudoMatchesWirePayload]?
    let inherited: [CSSInheritedStyleWirePayload]?
    func proxyMatchedStyles(targetScopeRawValue: String?) -> CSS.MatchedStyles {
        CSS.MatchedStyles(
            matchedRules: matchedCSSRules?.map { $0.rule.proxyRule(targetScopeRawValue: targetScopeRawValue) } ?? [],
            inherited: inherited?.map { $0.proxyEntry(targetScopeRawValue: targetScopeRawValue) } ?? [],
            pseudoElements: pseudoElements?.map { $0.proxyMatches(targetScopeRawValue: targetScopeRawValue) } ?? []
        )
    }
}

private struct CSSInlineStylesWireResult: Decodable {
    let inlineStyle: CSSStyleWirePayload?
    let attributesStyle: CSSStyleWirePayload?
    func proxyInlineStyles(targetScopeRawValue: String?) -> CSS.InlineStyles {
        CSS.InlineStyles(
            inlineStyle: inlineStyle?.proxyStyle(fallbackID: "anonymous:inline", targetScopeRawValue: targetScopeRawValue),
            attributesStyle: attributesStyle?.proxyStyle(fallbackID: "anonymous:attributes", targetScopeRawValue: targetScopeRawValue)
        )
    }
}

private struct CSSComputedStyleWireResult: Decodable { let computedStyle: [CSSComputedPropertyWirePayload] }
private struct CSSSetStyleTextWireResult: Decodable { let style: CSSStyleWirePayload }
private struct CSSSetRuleSelectorWireResult: Decodable { let rule: CSSRuleWirePayload }
private struct CSSSetGroupingHeaderTextWireResult: Decodable { let grouping: CSSGroupingWirePayload }

private struct RuntimeEvaluationWireResult: Decodable {
    let result: RuntimeRemoteObjectPayload
    let wasThrown: Bool?
    let savedResultIndex: Int?
    func proxyResult(targetScopeRawValue: String?) -> Runtime.EvaluationResult {
        Runtime.EvaluationResult(
            object: result.proxyObject(targetScopeRawValue: targetScopeRawValue),
            wasThrown: wasThrown ?? false,
            savedResultIndex: savedResultIndex
        )
    }
}

private struct RuntimePropertiesWireResult: Decodable {
    let properties: [RuntimePropertyWirePayload]
    func proxyProperties(targetScopeRawValue: String?) -> [Runtime.PropertyDescriptor] {
        properties.map { $0.proxyProperty(targetScopeRawValue: targetScopeRawValue) }
    }
}

private struct RuntimePropertyWirePayload: Decodable {
    let name: String
    let value: RuntimeRemoteObjectPayload?
    let writable: Bool?
    let get: RuntimeRemoteObjectPayload?
    let set: RuntimeRemoteObjectPayload?
    let wasThrown: Bool?
    let configurable: Bool?
    let enumerable: Bool?
    let isOwn: Bool?
    let symbol: RuntimeRemoteObjectPayload?
    let isPrivate: Bool?
    let nativeGetter: Bool?
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

private struct RuntimePreviewWireResult: Decodable { let preview: ObjectPreviewPayload }
private struct RuntimeCollectionEntriesWireResult: Decodable {
    let entries: [RuntimeCollectionEntryWirePayload]
    func proxyEntries(targetScopeRawValue: String?) -> [Runtime.CollectionEntry] {
        entries.map { $0.proxyEntry(targetScopeRawValue: targetScopeRawValue) }
    }
}

private struct RuntimeCollectionEntryWirePayload: Decodable {
    let key: RuntimeRemoteObjectPayload?
    let value: RuntimeRemoteObjectPayload
    func proxyEntry(targetScopeRawValue: String?) -> Runtime.CollectionEntry {
        Runtime.CollectionEntry(
            key: key?.proxyObject(targetScopeRawValue: targetScopeRawValue),
            value: value.proxyObject(targetScopeRawValue: targetScopeRawValue)
        )
    }
}

private struct CSSRuleMatchWirePayload: Decodable { let rule: CSSRuleWirePayload }
private struct CSSPseudoMatchesWirePayload: Decodable {
    let pseudoId: FlexibleStringWirePayload
    let matches: [CSSRuleMatchWirePayload]
    func proxyMatches(targetScopeRawValue: String?) -> CSS.MatchedStyles.PseudoElementMatches {
        .init(pseudoID: pseudoId.stringValue, matchedRules: matches.map { $0.rule.proxyRule(targetScopeRawValue: targetScopeRawValue) })
    }
}

private struct FlexibleStringWirePayload: Decodable {
    let stringValue: String
    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let string = try? value.decode(String.self) { stringValue = string }
        else { stringValue = String(try value.decode(Int.self)) }
    }
}

private struct CSSInheritedStyleWirePayload: Decodable {
    let inlineStyle: CSSStyleWirePayload?
    let matchedCSSRules: [CSSRuleMatchWirePayload]?
    func proxyEntry(targetScopeRawValue: String?) -> CSS.MatchedStyles.InheritedEntry {
        .init(
            inlineStyle: inlineStyle?.proxyStyle(fallbackID: "anonymous:inherited-inline", targetScopeRawValue: targetScopeRawValue),
            matchedRules: matchedCSSRules?.map { $0.rule.proxyRule(targetScopeRawValue: targetScopeRawValue) } ?? []
        )
    }
}

private struct CSSRuleWirePayload: Decodable {
    let ruleId: CSSRuleIDWirePayload?
    let selectorList: CSSSelectorListWirePayload
    let sourceURL: String?
    let sourceLine: Int?
    let sourceLocation: CSSSourceRangeWirePayload?
    let origin: String
    let style: CSSStyleWirePayload
    let groupings: [CSSGroupingWirePayload]?
    let isImplicitlyNested: Bool?
    func proxyRule(targetScopeRawValue: String?) -> CSS.Rule {
        let fallback = "anonymous:rule:\(origin):\(selectorList.text):\(sourceURL ?? ""):\(sourceLine ?? -1)"
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
            style: style.proxyStyle(fallbackID: fallback, targetScopeRawValue: targetScopeRawValue),
            groupings: groupings?.map(\.proxyGrouping) ?? [],
            isImplicitlyNested: isImplicitlyNested ?? false
        )
    }
}

private struct CSSSelectorListWirePayload: Decodable {
    let selectors: [CSSSelectorWirePayload]
    let text: String
    let range: CSSSourceRangeWirePayload?
    var proxySelectorList: CSS.Rule.SelectorList { .init(selectors: selectors.map(\.text), text: text, range: range?.proxyRange) }
}
private struct CSSSelectorWirePayload: Decodable { let text: String }
private struct CSSGroupingWirePayload: Decodable {
    let text: String?
    var proxyGrouping: CSS.Rule.Grouping { .init(text: text ?? "") }
}

private struct CSSStyleWirePayload: Decodable {
    let styleId: CSSWireStyleID?
    let cssProperties: [CSSPropertyWirePayload]
    let shorthandEntries: [CSSShorthandWirePayload]?
    let cssText: String?
    let range: CSSSourceRangeWirePayload?
    let width: String?
    let height: String?
    func proxyStyle(fallbackID: String = "anonymous:style", targetScopeRawValue: String? = nil) -> CSS.Style {
        let raw = styleId?.rawValue ?? fallbackID
        let id = targetScopeRawValue.map { CSS.Style.ID(raw, scopedToTargetRawValue: $0) } ?? CSS.Style.ID(raw)
        let editable = styleId != nil
        return CSS.Style(
            id: id,
            properties: cssProperties.enumerated().map { $0.element.proxyProperty(styleID: id.rawValue, index: $0.offset, isEditable: editable) },
            shorthandEntries: shorthandEntries?.map(\.proxyEntry) ?? [],
            cssText: cssText ?? "",
            range: range?.proxyRange,
            width: width,
            height: height,
            isEditable: editable
        )
    }
}

private struct CSSWireStyleID: Decodable {
    static let separator: Character = "\u{1F}"
    let styleSheetId: String
    let ordinal: Int
    var rawValue: String { "\(styleSheetId)\(Self.separator)\(ordinal)" }
}
private struct CSSRuleIDWirePayload: Decodable {
    let styleSheetId: String
    let ordinal: Int
    var rawValue: String { "\(styleSheetId)\(CSSWireStyleID.separator)\(ordinal)" }
}
private struct CSSPropertyWirePayload: Decodable {
    let name: String
    let value: String
    let priority: String?
    let text: String?
    let parsedOk: Bool?
    let status: String?
    let implicit: Bool?
    let range: CSSSourceRangeWirePayload?
    func proxyProperty(styleID: String, index: Int, isEditable: Bool) -> CSS.Property {
        CSS.Property(
            id: CSS.Property.ID("\(styleID)\(CSSWireStyleID.separator)\(index)"),
            name: name,
            value: value,
            priority: priority,
            text: text,
            parsedOk: parsedOk ?? true,
            status: CSS.Status(wireValue: status),
            implicit: implicit ?? false,
            range: range?.proxyRange,
            isEditable: isEditable,
            isModifiedByInspector: false
        )
    }
}
private struct CSSShorthandWirePayload: Decodable {
    let name: String
    let value: String
    let priority: String?
    var proxyEntry: CSS.Style.ShorthandEntry { .init(name: name, value: value, priority: priority) }
}
private struct CSSComputedPropertyWirePayload: Decodable {
    let name: String
    let value: String
    var proxyProperty: CSS.ComputedProperty { .init(name: name, value: value) }
}
private struct CSSSourceRangeWirePayload: Decodable {
    let startLine: Int
    let startColumn: Int
    let endLine: Int
    let endColumn: Int
    var proxyRange: CSS.Style.SourceRange { .init(startLine: startLine, startColumn: startColumn, endLine: endLine, endColumn: endColumn) }
}

private extension CSS.Status {
    init(wireValue: String?) {
        switch wireValue {
        case "inactive": self = .inactive
        case "disabled": self = .disabled
        default: self = .active
        }
    }
}

private extension Runtime.ObjectGroup {
    var rawProtocolValue: String {
        switch self { case .console: "console"; case let .other(value): value }
    }
}
