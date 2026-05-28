import Foundation
import WebInspectorTransport

package struct CSSStyleSheetIdentifier: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    package let rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package var description: String {
        rawValue
    }
}

package struct CSSStyleIdentifier: Hashable, Codable, Sendable {
    package var styleSheetID: CSSStyleSheetIdentifier
    package var ordinal: Int

    package init(styleSheetID: CSSStyleSheetIdentifier, ordinal: Int) {
        self.styleSheetID = styleSheetID
        self.ordinal = ordinal
    }

    private enum CodingKeys: String, CodingKey {
        case styleSheetID = "styleSheetId"
        case ordinal
    }
}

package struct CSSRuleIdentifier: Hashable, Codable, Sendable {
    package var styleSheetID: CSSStyleSheetIdentifier
    package var ordinal: Int

    package init(styleSheetID: CSSStyleSheetIdentifier, ordinal: Int) {
        self.styleSheetID = styleSheetID
        self.ordinal = ordinal
    }

    private enum CodingKeys: String, CodingKey {
        case styleSheetID = "styleSheetId"
        case ordinal
    }
}

package struct CSSStyleSheetHeaderPayload: Equatable, Codable, Sendable {
    package var styleSheetID: CSSStyleSheetIdentifier
    package var frameID: DOMFrameIdentifier?
    package var sourceURL: String?
    package var origin: CSSStyleOrigin?
    package var title: String?
    package var disabled: Bool
    package var isInline: Bool
    package var startLine: Int
    package var startColumn: Int

    package init(
        styleSheetID: CSSStyleSheetIdentifier,
        frameID: DOMFrameIdentifier? = nil,
        sourceURL: String? = nil,
        origin: CSSStyleOrigin? = nil,
        title: String? = nil,
        disabled: Bool = false,
        isInline: Bool = false,
        startLine: Int = 0,
        startColumn: Int = 0
    ) {
        self.styleSheetID = styleSheetID
        self.frameID = frameID
        self.sourceURL = sourceURL
        self.origin = origin
        self.title = title
        self.disabled = disabled
        self.isInline = isInline
        self.startLine = startLine
        self.startColumn = startColumn
    }

    private enum CodingKeys: String, CodingKey {
        case styleSheetID = "styleSheetId"
        case frameID = "frameId"
        case sourceURL
        case origin
        case title
        case disabled
        case isInline
        case startLine
        case startColumn
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        styleSheetID = try container.decode(CSSStyleSheetIdentifier.self, forKey: .styleSheetID)
        frameID = try container.decodeIfPresent(DOMFrameIdentifier.self, forKey: .frameID)
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)
        origin = try container.decodeIfPresent(CSSStyleOrigin.self, forKey: .origin)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        isInline = try container.decodeIfPresent(Bool.self, forKey: .isInline) ?? false
        startLine = try container.decodeIfPresent(Int.self, forKey: .startLine) ?? 0
        startColumn = try container.decodeIfPresent(Int.self, forKey: .startColumn) ?? 0
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(styleSheetID, forKey: .styleSheetID)
        try container.encodeIfPresent(frameID, forKey: .frameID)
        try container.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try container.encodeIfPresent(origin, forKey: .origin)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(disabled, forKey: .disabled)
        try container.encode(isInline, forKey: .isInline)
        try container.encode(startLine, forKey: .startLine)
        try container.encode(startColumn, forKey: .startColumn)
    }
}

package struct CSSSourceRange: Equatable, Codable, Sendable {
    package var startLine: Int
    package var startColumn: Int
    package var endLine: Int
    package var endColumn: Int

    package init(startLine: Int, startColumn: Int, endLine: Int, endColumn: Int) {
        self.startLine = startLine
        self.startColumn = startColumn
        self.endLine = endLine
        self.endColumn = endColumn
    }
}

package enum CSSStyleOrigin: Equatable, Sendable {
    case user
    case userAgent
    case author
    case inspector
    case other(String)

    package init(rawValue: String) {
        switch rawValue {
        case "user":
            self = .user
        case "user-agent":
            self = .userAgent
        case "author":
            self = .author
        case "inspector":
            self = .inspector
        default:
            self = .other(rawValue)
        }
    }
}

extension CSSStyleOrigin: Codable {
    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    package var rawValue: String {
        switch self {
        case .user:
            "user"
        case .userAgent:
            "user-agent"
        case .author:
            "author"
        case .inspector:
            "inspector"
        case let .other(value):
            value
        }
    }
}

package enum CSSPropertyStatus: Equatable, Sendable {
    case active
    case inactive
    case disabled
    case style
    case other(String)

    package init(rawValue: String) {
        switch rawValue {
        case "active":
            self = .active
        case "inactive":
            self = .inactive
        case "disabled":
            self = .disabled
        case "style":
            self = .style
        default:
            self = .other(rawValue)
        }
    }
}

extension CSSPropertyStatus: Codable {
    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    package var rawValue: String {
        switch self {
        case .active:
            "active"
        case .inactive:
            "inactive"
        case .disabled:
            "disabled"
        case .style:
            "style"
        case let .other(value):
            value
        }
    }
}

package struct CSSNodeStyleIdentity: Equatable, Hashable, Sendable {
    package var nodeID: DOMNodeIdentifier
    package var targetID: ProtocolTargetIdentifier
    package var documentID: DOMDocumentIdentifier
    package var protocolNodeID: DOMProtocolNodeID
    package var targetCapabilities: ProtocolTargetCapabilities

    package init(
        nodeID: DOMNodeIdentifier,
        targetID: ProtocolTargetIdentifier,
        documentID: DOMDocumentIdentifier,
        protocolNodeID: DOMProtocolNodeID,
        targetCapabilities: ProtocolTargetCapabilities
    ) {
        self.nodeID = nodeID
        self.targetID = targetID
        self.documentID = documentID
        self.protocolNodeID = protocolNodeID
        self.targetCapabilities = targetCapabilities
    }
}

package enum CSSNodeStylesUnavailableReason: Error, Equatable, Sendable {
    case noSelection
    case nonElementNode(DOMNodeType)
    case staleNode(DOMNodeIdentifier)
    case cssUnavailableForTarget(ProtocolTargetIdentifier)
}

package enum CSSCommandIntent: Equatable, Sendable {
    case enable(targetID: ProtocolTargetIdentifier)
    case getMatchedStyles(identity: CSSNodeStyleIdentity, includePseudo: Bool = true, includeInherited: Bool = true)
    case getInlineStyles(identity: CSSNodeStyleIdentity)
    case getComputedStyle(identity: CSSNodeStyleIdentity)
    case setStyleText(targetID: ProtocolTargetIdentifier, styleID: CSSStyleIdentifier, text: String)
}

package struct CSSPropertyIdentifier: Hashable, Codable, Sendable {
    package var styleID: CSSStyleIdentifier
    package var propertyIndex: Int

    package init(styleID: CSSStyleIdentifier, propertyIndex: Int) {
        self.styleID = styleID
        self.propertyIndex = propertyIndex
    }
}

package struct CSSSelector: Equatable, Codable, Sendable {
    package var text: String
    package var specificity: [Int]?
    package var dynamic: Bool?

    package init(text: String, specificity: [Int]? = nil, dynamic: Bool? = nil) {
        self.text = text
        self.specificity = specificity
        self.dynamic = dynamic
    }
}

package struct CSSSelectorList: Equatable, Codable, Sendable {
    package var selectors: [CSSSelector]
    package var text: String
    package var range: CSSSourceRange?

    package init(selectors: [CSSSelector], text: String, range: CSSSourceRange? = nil) {
        self.selectors = selectors
        self.text = text
        self.range = range
    }
}

package struct CSSGrouping: Equatable, Codable, Sendable {
    package var type: String
    package var ruleID: CSSRuleIdentifier?
    package var text: String?
    package var sourceURL: String?
    package var range: CSSSourceRange?

    package init(
        type: String,
        ruleID: CSSRuleIdentifier? = nil,
        text: String? = nil,
        sourceURL: String? = nil,
        range: CSSSourceRange? = nil
    ) {
        self.type = type
        self.ruleID = ruleID
        self.text = text
        self.sourceURL = sourceURL
        self.range = range
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case ruleID = "ruleId"
        case text
        case sourceURL
        case range
    }
}

package struct CSSShorthandEntry: Equatable, Codable, Sendable {
    package var name: String
    package var value: String

    package init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

package struct CSSPropertyPayload: Equatable, Codable, Sendable {
    package var name: String
    package var value: String
    package var priority: String
    package var text: String?
    package var parsedOk: Bool
    package var status: CSSPropertyStatus
    package var implicit: Bool
    package var range: CSSSourceRange?

    package init(
        name: String,
        value: String,
        priority: String = "",
        text: String? = nil,
        parsedOk: Bool = true,
        status: CSSPropertyStatus = .style,
        implicit: Bool = false,
        range: CSSSourceRange? = nil
    ) {
        self.name = name
        self.value = value
        self.priority = priority
        self.text = text
        self.parsedOk = parsedOk
        self.status = status
        self.implicit = implicit
        self.range = range
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case value
        case priority
        case text
        case parsedOk
        case status
        case implicit
        case range
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        value = try container.decode(String.self, forKey: .value)
        priority = try container.decodeIfPresent(String.self, forKey: .priority) ?? ""
        text = try container.decodeIfPresent(String.self, forKey: .text)
        parsedOk = try container.decodeIfPresent(Bool.self, forKey: .parsedOk) ?? true
        status = try container.decodeIfPresent(CSSPropertyStatus.self, forKey: .status) ?? .style
        implicit = try container.decodeIfPresent(Bool.self, forKey: .implicit) ?? false
        range = try container.decodeIfPresent(CSSSourceRange.self, forKey: .range)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(value, forKey: .value)
        try container.encode(priority, forKey: .priority)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encode(parsedOk, forKey: .parsedOk)
        try container.encode(status, forKey: .status)
        try container.encode(implicit, forKey: .implicit)
        try container.encodeIfPresent(range, forKey: .range)
    }
}

package struct CSSStylePayload: Equatable, Codable, Sendable {
    package var id: CSSStyleIdentifier?
    package var cssProperties: [CSSPropertyPayload]
    package var shorthandEntries: [CSSShorthandEntry]
    package var cssText: String?
    package var range: CSSSourceRange?
    package var width: String?
    package var height: String?

    package init(
        id: CSSStyleIdentifier? = nil,
        cssProperties: [CSSPropertyPayload],
        shorthandEntries: [CSSShorthandEntry] = [],
        cssText: String? = nil,
        range: CSSSourceRange? = nil,
        width: String? = nil,
        height: String? = nil
    ) {
        self.id = id
        self.cssProperties = cssProperties
        self.shorthandEntries = shorthandEntries
        self.cssText = cssText
        self.range = range
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey {
        case id = "styleId"
        case cssProperties
        case shorthandEntries
        case cssText
        case range
        case width
        case height
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(CSSStyleIdentifier.self, forKey: .id)
        cssProperties = try container.decode([CSSPropertyPayload].self, forKey: .cssProperties)
        shorthandEntries = try container.decodeIfPresent([CSSShorthandEntry].self, forKey: .shorthandEntries) ?? []
        cssText = try container.decodeIfPresent(String.self, forKey: .cssText)
        range = try container.decodeIfPresent(CSSSourceRange.self, forKey: .range)
        width = try container.decodeIfPresent(String.self, forKey: .width)
        height = try container.decodeIfPresent(String.self, forKey: .height)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(cssProperties, forKey: .cssProperties)
        try container.encode(shorthandEntries, forKey: .shorthandEntries)
        try container.encodeIfPresent(cssText, forKey: .cssText)
        try container.encodeIfPresent(range, forKey: .range)
        try container.encodeIfPresent(width, forKey: .width)
        try container.encodeIfPresent(height, forKey: .height)
    }
}

package struct CSSRulePayload: Equatable, Codable, Sendable {
    package var id: CSSRuleIdentifier?
    package var selectorList: CSSSelectorList
    package var sourceURL: String?
    package var sourceLine: Int
    package var origin: CSSStyleOrigin
    package var style: CSSStylePayload
    package var groupings: [CSSGrouping]
    package var isImplicitlyNested: Bool

    package init(
        id: CSSRuleIdentifier? = nil,
        selectorList: CSSSelectorList,
        sourceURL: String? = nil,
        sourceLine: Int,
        origin: CSSStyleOrigin,
        style: CSSStylePayload,
        groupings: [CSSGrouping] = [],
        isImplicitlyNested: Bool = false
    ) {
        self.id = id
        self.selectorList = selectorList
        self.sourceURL = sourceURL
        self.sourceLine = sourceLine
        self.origin = origin
        self.style = style
        self.groupings = groupings
        self.isImplicitlyNested = isImplicitlyNested
    }

    private enum CodingKeys: String, CodingKey {
        case id = "ruleId"
        case selectorList
        case sourceURL
        case sourceLine
        case origin
        case style
        case groupings
        case isImplicitlyNested
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(CSSRuleIdentifier.self, forKey: .id)
        selectorList = try container.decode(CSSSelectorList.self, forKey: .selectorList)
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)
        sourceLine = try container.decodeIfPresent(Int.self, forKey: .sourceLine) ?? 0
        origin = try container.decode(CSSStyleOrigin.self, forKey: .origin)
        style = try container.decode(CSSStylePayload.self, forKey: .style)
        groupings = try container.decodeIfPresent([CSSGrouping].self, forKey: .groupings) ?? []
        isImplicitlyNested = try container.decodeIfPresent(Bool.self, forKey: .isImplicitlyNested) ?? false
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(selectorList, forKey: .selectorList)
        try container.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try container.encode(sourceLine, forKey: .sourceLine)
        try container.encode(origin, forKey: .origin)
        try container.encode(style, forKey: .style)
        try container.encode(groupings, forKey: .groupings)
        try container.encode(isImplicitlyNested, forKey: .isImplicitlyNested)
    }
}

package struct CSSRuleMatchPayload: Equatable, Codable, Sendable {
    package var rule: CSSRulePayload
    package var matchingSelectors: [Int]

    package init(rule: CSSRulePayload, matchingSelectors: [Int]) {
        self.rule = rule
        self.matchingSelectors = matchingSelectors
    }
}

package struct CSSPseudoIdMatches: Equatable, Codable, Sendable {
    package var pseudoID: String
    package var matches: [CSSRuleMatchPayload]

    package init(pseudoID: String, matches: [CSSRuleMatchPayload]) {
        self.pseudoID = pseudoID
        self.matches = matches
    }

    private enum CodingKeys: String, CodingKey {
        case pseudoID = "pseudoId"
        case matches
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let pseudoID = try? container.decode(String.self, forKey: .pseudoID) {
            self.pseudoID = pseudoID
        } else {
            self.pseudoID = try String(container.decode(Int.self, forKey: .pseudoID))
        }
        matches = try container.decodeIfPresent([CSSRuleMatchPayload].self, forKey: .matches) ?? []
    }
}

package struct CSSInheritedStyleEntry: Equatable, Codable, Sendable {
    package var inlineStyle: CSSStylePayload?
    package var matchedRules: [CSSRuleMatchPayload]

    package init(inlineStyle: CSSStylePayload? = nil, matchedRules: [CSSRuleMatchPayload]) {
        self.inlineStyle = inlineStyle
        self.matchedRules = matchedRules
    }

    private enum CodingKeys: String, CodingKey {
        case inlineStyle
        case matchedRules = "matchedCSSRules"
    }
}

package struct CSSMatchedStylesPayload: Equatable, Codable, Sendable {
    package var matchedRules: [CSSRuleMatchPayload]
    package var pseudoElements: [CSSPseudoIdMatches]
    package var inherited: [CSSInheritedStyleEntry]

    package init(
        matchedRules: [CSSRuleMatchPayload] = [],
        pseudoElements: [CSSPseudoIdMatches] = [],
        inherited: [CSSInheritedStyleEntry] = []
    ) {
        self.matchedRules = matchedRules
        self.pseudoElements = pseudoElements
        self.inherited = inherited
    }

    private enum CodingKeys: String, CodingKey {
        case matchedRules = "matchedCSSRules"
        case pseudoElements
        case inherited
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        matchedRules = try container.decodeIfPresent([CSSRuleMatchPayload].self, forKey: .matchedRules) ?? []
        pseudoElements = try container.decodeIfPresent([CSSPseudoIdMatches].self, forKey: .pseudoElements) ?? []
        inherited = try container.decodeIfPresent([CSSInheritedStyleEntry].self, forKey: .inherited) ?? []
    }
}

package struct CSSInlineStylesPayload: Equatable, Codable, Sendable {
    package var inlineStyle: CSSStylePayload?
    package var attributesStyle: CSSStylePayload?

    package init(inlineStyle: CSSStylePayload? = nil, attributesStyle: CSSStylePayload? = nil) {
        self.inlineStyle = inlineStyle
        self.attributesStyle = attributesStyle
    }
}

package struct CSSComputedStylePropertyPayload: Equatable, Codable, Sendable {
    package var name: String
    package var value: String

    package init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case value
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        value = try container.decode(String.self, forKey: .value)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(value, forKey: .value)
    }
}

package enum CSSNodeStylesState: Equatable, Sendable {
    case loading
    case loaded
    case unavailable(CSSNodeStylesUnavailableReason)
    case failed(String)
    case needsRefresh
}

package enum CSSStyleSectionKind: Equatable, Hashable, Sendable {
    case inlineStyle
    case rule
    case attributesStyle
    case pseudoElement(String)
    case inheritedInlineStyle(ancestorIndex: Int)
    case inheritedRule(ancestorIndex: Int)
}

package struct CSSStyleSectionIdentifier: Hashable, Sendable {
    package var nodeID: DOMNodeIdentifier
    package var kind: CSSStyleSectionKind
    package var ordinal: Int

    package init(nodeID: DOMNodeIdentifier, kind: CSSStyleSectionKind, ordinal: Int) {
        self.nodeID = nodeID
        self.kind = kind
        self.ordinal = ordinal
    }
}

package struct CSSStyleRefreshToken: Equatable, Sendable {
    package var identity: CSSNodeStyleIdentity
    package var sequence: UInt64

    package init(identity: CSSNodeStyleIdentity, sequence: UInt64) {
        self.identity = identity
        self.sequence = sequence
    }
}
