import Foundation

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

package struct CSSProperty: Equatable, Codable, Sendable {
    package var id: CSSPropertyIdentifier?
    package var name: String
    package var value: String
    package var priority: String
    package var text: String?
    package var parsedOk: Bool
    package var status: CSSPropertyStatus
    package var implicit: Bool
    package var range: CSSSourceRange?
    package var isEditable: Bool

    package init(
        id: CSSPropertyIdentifier? = nil,
        name: String,
        value: String,
        priority: String = "",
        text: String? = nil,
        parsedOk: Bool = true,
        status: CSSPropertyStatus = .style,
        implicit: Bool = false,
        range: CSSSourceRange? = nil,
        isEditable: Bool = false
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.priority = priority
        self.text = text
        self.parsedOk = parsedOk
        self.status = status
        self.implicit = implicit
        self.range = range
        self.isEditable = isEditable
    }

    package var isEnabled: Bool {
        status != .disabled
    }

    package var isOverridden: Bool {
        status == .inactive
    }

    package var isParsed: Bool {
        parsedOk
    }

    package var isImplicit: Bool {
        implicit
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case value
        case priority
        case text
        case parsedOk
        case status
        case implicit
        case range
        case isEditable
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(CSSPropertyIdentifier.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        value = try container.decode(String.self, forKey: .value)
        priority = try container.decodeIfPresent(String.self, forKey: .priority) ?? ""
        text = try container.decodeIfPresent(String.self, forKey: .text)
        parsedOk = try container.decodeIfPresent(Bool.self, forKey: .parsedOk) ?? true
        status = try container.decodeIfPresent(CSSPropertyStatus.self, forKey: .status) ?? .style
        implicit = try container.decodeIfPresent(Bool.self, forKey: .implicit) ?? false
        range = try container.decodeIfPresent(CSSSourceRange.self, forKey: .range)
        isEditable = try container.decodeIfPresent(Bool.self, forKey: .isEditable) ?? false
    }
}

package struct CSSStyle: Equatable, Codable, Sendable {
    package var id: CSSStyleIdentifier?
    package var cssProperties: [CSSProperty]
    package var shorthandEntries: [CSSShorthandEntry]
    package var cssText: String?
    package var range: CSSSourceRange?
    package var width: String?
    package var height: String?
    package var isEditable: Bool

    package init(
        id: CSSStyleIdentifier? = nil,
        cssProperties: [CSSProperty],
        shorthandEntries: [CSSShorthandEntry] = [],
        cssText: String? = nil,
        range: CSSSourceRange? = nil,
        width: String? = nil,
        height: String? = nil,
        isEditable: Bool = false
    ) {
        self.id = id
        self.cssProperties = cssProperties
        self.shorthandEntries = shorthandEntries
        self.cssText = cssText
        self.range = range
        self.width = width
        self.height = height
        self.isEditable = isEditable
    }

    private enum CodingKeys: String, CodingKey {
        case id = "styleId"
        case cssProperties
        case shorthandEntries
        case cssText
        case range
        case width
        case height
        case isEditable
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(CSSStyleIdentifier.self, forKey: .id)
        cssProperties = try container.decode([CSSProperty].self, forKey: .cssProperties)
        shorthandEntries = try container.decodeIfPresent([CSSShorthandEntry].self, forKey: .shorthandEntries) ?? []
        cssText = try container.decodeIfPresent(String.self, forKey: .cssText)
        range = try container.decodeIfPresent(CSSSourceRange.self, forKey: .range)
        width = try container.decodeIfPresent(String.self, forKey: .width)
        height = try container.decodeIfPresent(String.self, forKey: .height)
        isEditable = try container.decodeIfPresent(Bool.self, forKey: .isEditable) ?? false
    }
}

package struct CSSRule: Equatable, Codable, Sendable {
    package var id: CSSRuleIdentifier?
    package var selectorList: CSSSelectorList
    package var sourceURL: String?
    package var sourceLine: Int
    package var origin: CSSStyleOrigin
    package var style: CSSStyle
    package var groupings: [CSSGrouping]
    package var isImplicitlyNested: Bool

    package init(
        id: CSSRuleIdentifier? = nil,
        selectorList: CSSSelectorList,
        sourceURL: String? = nil,
        sourceLine: Int,
        origin: CSSStyleOrigin,
        style: CSSStyle,
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
        style = try container.decode(CSSStyle.self, forKey: .style)
        groupings = try container.decodeIfPresent([CSSGrouping].self, forKey: .groupings) ?? []
        isImplicitlyNested = try container.decodeIfPresent(Bool.self, forKey: .isImplicitlyNested) ?? false
    }
}

package struct CSSRuleMatch: Equatable, Codable, Sendable {
    package var rule: CSSRule
    package var matchingSelectors: [Int]

    package init(rule: CSSRule, matchingSelectors: [Int]) {
        self.rule = rule
        self.matchingSelectors = matchingSelectors
    }
}

package struct CSSPseudoIdMatches: Equatable, Codable, Sendable {
    package var pseudoID: String
    package var matches: [CSSRuleMatch]

    package init(pseudoID: String, matches: [CSSRuleMatch]) {
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
        matches = try container.decodeIfPresent([CSSRuleMatch].self, forKey: .matches) ?? []
    }
}

package struct CSSInheritedStyleEntry: Equatable, Codable, Sendable {
    package var inlineStyle: CSSStyle?
    package var matchedRules: [CSSRuleMatch]

    package init(inlineStyle: CSSStyle? = nil, matchedRules: [CSSRuleMatch]) {
        self.inlineStyle = inlineStyle
        self.matchedRules = matchedRules
    }

    private enum CodingKeys: String, CodingKey {
        case inlineStyle
        case matchedRules = "matchedCSSRules"
    }
}

package struct CSSMatchedStylesPayload: Equatable, Codable, Sendable {
    package var matchedRules: [CSSRuleMatch]
    package var pseudoElements: [CSSPseudoIdMatches]
    package var inherited: [CSSInheritedStyleEntry]

    package init(
        matchedRules: [CSSRuleMatch] = [],
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
        matchedRules = try container.decodeIfPresent([CSSRuleMatch].self, forKey: .matchedRules) ?? []
        pseudoElements = try container.decodeIfPresent([CSSPseudoIdMatches].self, forKey: .pseudoElements) ?? []
        inherited = try container.decodeIfPresent([CSSInheritedStyleEntry].self, forKey: .inherited) ?? []
    }
}

package struct CSSInlineStylesPayload: Equatable, Codable, Sendable {
    package var inlineStyle: CSSStyle?
    package var attributesStyle: CSSStyle?

    package init(inlineStyle: CSSStyle? = nil, attributesStyle: CSSStyle? = nil) {
        self.inlineStyle = inlineStyle
        self.attributesStyle = attributesStyle
    }
}

package struct CSSComputedStyleProperty: Equatable, Codable, Sendable {
    package var name: String
    package var value: String

    package init(name: String, value: String) {
        self.name = name
        self.value = value
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

package struct CSSStyleSection: Equatable, Sendable {
    package var id: CSSStyleSectionIdentifier
    package var kind: CSSStyleSectionKind
    package var title: String
    package var subtitle: String?
    package var rule: CSSRule?
    package var style: CSSStyle
    package var isEditable: Bool

    package init(
        id: CSSStyleSectionIdentifier,
        kind: CSSStyleSectionKind,
        title: String,
        subtitle: String? = nil,
        rule: CSSRule? = nil,
        style: CSSStyle,
        isEditable: Bool
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.rule = rule
        self.style = style
        self.isEditable = isEditable
    }
}

package struct CSSStyleRefreshToken: Equatable, Sendable {
    package var identity: CSSNodeStyleIdentity
    package var revision: UInt64

    package init(identity: CSSNodeStyleIdentity, revision: UInt64) {
        self.identity = identity
        self.revision = revision
    }
}
