import Foundation
import WebInspectorTransport

package enum CSSCommand {}
package enum CSSStyleSheet {}

package extension CSSStyleSheet {
    struct ID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
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

    struct HeaderPayload: Equatable, Codable, Sendable {
        package var styleSheetID: ID
        package var frameID: DOMFrame.ID?
        package var sourceURL: String?
        package var origin: CSSStyle.Origin?
        package var title: String?
        package var disabled: Bool
        package var isInline: Bool
        package var startLine: Int
        package var startColumn: Int

        package init(
            styleSheetID: ID,
            frameID: DOMFrame.ID? = nil,
            sourceURL: String? = nil,
            origin: CSSStyle.Origin? = nil,
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
            styleSheetID = try container.decode(ID.self, forKey: .styleSheetID)
            frameID = try container.decodeIfPresent(DOMFrame.ID.self, forKey: .frameID)
            sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)
            origin = try container.decodeIfPresent(CSSStyle.Origin.self, forKey: .origin)
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
}

package extension CSSStyle {
    struct ID: Hashable, Codable, Sendable {
        package var styleSheetID: CSSStyleSheet.ID
        package var ordinal: Int

        package init(styleSheetID: CSSStyleSheet.ID, ordinal: Int) {
            self.styleSheetID = styleSheetID
            self.ordinal = ordinal
        }

        private enum CodingKeys: String, CodingKey {
            case styleSheetID = "styleSheetId"
            case ordinal
        }
    }

    struct SourceRange: Equatable, Codable, Sendable {
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

    enum Origin: Equatable, Sendable {
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

    struct ShorthandEntry: Equatable, Codable, Sendable {
        package var name: String
        package var value: String

        package init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    struct Payload: Equatable, Codable, Sendable {
        package var id: ID?
        package var cssProperties: [CSSProperty.Payload]
        package var shorthandEntries: [ShorthandEntry]
        package var cssText: String?
        package var range: SourceRange?
        package var width: String?
        package var height: String?

        package init(
            id: ID? = nil,
            cssProperties: [CSSProperty.Payload],
            shorthandEntries: [ShorthandEntry] = [],
            cssText: String? = nil,
            range: SourceRange? = nil,
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
            id = try container.decodeIfPresent(ID.self, forKey: .id)
            cssProperties = try container.decode([CSSProperty.Payload].self, forKey: .cssProperties)
            shorthandEntries = try container.decodeIfPresent([ShorthandEntry].self, forKey: .shorthandEntries) ?? []
            cssText = try container.decodeIfPresent(String.self, forKey: .cssText)
            range = try container.decodeIfPresent(SourceRange.self, forKey: .range)
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

    struct PseudoIDMatches: Equatable, Codable, Sendable {
        package var pseudoID: String
        package var matches: [CSSRule.MatchPayload]

        package init(pseudoID: String, matches: [CSSRule.MatchPayload]) {
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
            matches = try container.decodeIfPresent([CSSRule.MatchPayload].self, forKey: .matches) ?? []
        }
    }

    struct InheritedStyleEntry: Equatable, Codable, Sendable {
        package var inlineStyle: Payload?
        package var matchedRules: [CSSRule.MatchPayload]

        package init(inlineStyle: Payload? = nil, matchedRules: [CSSRule.MatchPayload]) {
            self.inlineStyle = inlineStyle
            self.matchedRules = matchedRules
        }

        private enum CodingKeys: String, CodingKey {
            case inlineStyle
            case matchedRules = "matchedCSSRules"
        }
    }

    struct MatchedStylesPayload: Equatable, Codable, Sendable {
        package var matchedRules: [CSSRule.MatchPayload]
        package var pseudoElements: [PseudoIDMatches]
        package var inherited: [InheritedStyleEntry]

        package init(
            matchedRules: [CSSRule.MatchPayload] = [],
            pseudoElements: [PseudoIDMatches] = [],
            inherited: [InheritedStyleEntry] = []
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
            matchedRules = try container.decodeIfPresent([CSSRule.MatchPayload].self, forKey: .matchedRules) ?? []
            pseudoElements = try container.decodeIfPresent([PseudoIDMatches].self, forKey: .pseudoElements) ?? []
            inherited = try container.decodeIfPresent([InheritedStyleEntry].self, forKey: .inherited) ?? []
        }
    }

    struct InlineStylesPayload: Equatable, Codable, Sendable {
        package var inlineStyle: Payload?
        package var attributesStyle: Payload?

        package init(inlineStyle: Payload? = nil, attributesStyle: Payload? = nil) {
            self.inlineStyle = inlineStyle
            self.attributesStyle = attributesStyle
        }
    }

    struct RefreshToken: Equatable, Sendable {
        package var identity: CSSNodeStyles.Identity
        package var sequence: UInt64

        package init(identity: CSSNodeStyles.Identity, sequence: UInt64) {
            self.identity = identity
            self.sequence = sequence
        }
    }
}

extension CSSStyle.Origin: Codable {
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

package extension CSSProperty {
    struct ID: Hashable, Codable, Sendable {
        package var styleID: CSSStyle.ID
        package var propertyIndex: Int

        package init(styleID: CSSStyle.ID, propertyIndex: Int) {
            self.styleID = styleID
            self.propertyIndex = propertyIndex
        }
    }

    enum Status: Equatable, Sendable {
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

    struct Payload: Equatable, Codable, Sendable {
        package var name: String
        package var value: String
        package var priority: String
        package var text: String?
        package var parsedOk: Bool
        package var status: Status
        package var implicit: Bool
        package var range: CSSStyle.SourceRange?

        package init(
            name: String,
            value: String,
            priority: String = "",
            text: String? = nil,
            parsedOk: Bool = true,
            status: Status = .style,
            implicit: Bool = false,
            range: CSSStyle.SourceRange? = nil
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
            status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .style
            implicit = try container.decodeIfPresent(Bool.self, forKey: .implicit) ?? false
            range = try container.decodeIfPresent(CSSStyle.SourceRange.self, forKey: .range)
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
}

extension CSSProperty.Status: Codable {
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

package extension CSSRule {
    struct ID: Hashable, Codable, Sendable {
        package var styleSheetID: CSSStyleSheet.ID
        package var ordinal: Int

        package init(styleSheetID: CSSStyleSheet.ID, ordinal: Int) {
            self.styleSheetID = styleSheetID
            self.ordinal = ordinal
        }

        private enum CodingKeys: String, CodingKey {
            case styleSheetID = "styleSheetId"
            case ordinal
        }
    }

    struct Selector: Equatable, Codable, Sendable {
        package var text: String
        package var specificity: [Int]?
        package var dynamic: Bool?

        package init(text: String, specificity: [Int]? = nil, dynamic: Bool? = nil) {
            self.text = text
            self.specificity = specificity
            self.dynamic = dynamic
        }
    }

    struct SelectorList: Equatable, Codable, Sendable {
        package var selectors: [Selector]
        package var text: String
        package var range: CSSStyle.SourceRange?

        package init(selectors: [Selector], text: String, range: CSSStyle.SourceRange? = nil) {
            self.selectors = selectors
            self.text = text
            self.range = range
        }
    }

    struct Grouping: Equatable, Codable, Sendable {
        package var type: String
        package var ruleID: ID?
        package var text: String?
        package var sourceURL: String?
        package var range: CSSStyle.SourceRange?

        package init(
            type: String,
            ruleID: ID? = nil,
            text: String? = nil,
            sourceURL: String? = nil,
            range: CSSStyle.SourceRange? = nil
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

    struct Payload: Equatable, Codable, Sendable {
        package var id: ID?
        package var selectorList: SelectorList
        package var sourceURL: String?
        package var sourceLine: Int
        package var origin: CSSStyle.Origin
        package var style: CSSStyle.Payload
        package var groupings: [Grouping]
        package var isImplicitlyNested: Bool

        package init(
            id: ID? = nil,
            selectorList: SelectorList,
            sourceURL: String? = nil,
            sourceLine: Int,
            origin: CSSStyle.Origin,
            style: CSSStyle.Payload,
            groupings: [Grouping] = [],
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
            id = try container.decodeIfPresent(ID.self, forKey: .id)
            selectorList = try container.decode(SelectorList.self, forKey: .selectorList)
            sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)
            sourceLine = try container.decodeIfPresent(Int.self, forKey: .sourceLine) ?? 0
            origin = try container.decode(CSSStyle.Origin.self, forKey: .origin)
            style = try container.decode(CSSStyle.Payload.self, forKey: .style)
            groupings = try container.decodeIfPresent([Grouping].self, forKey: .groupings) ?? []
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

    struct MatchPayload: Equatable, Codable, Sendable {
        package var rule: Payload
        package var matchingSelectors: [Int]

        package init(rule: Payload, matchingSelectors: [Int]) {
            self.rule = rule
            self.matchingSelectors = matchingSelectors
        }
    }
}

package extension CSSComputedStyleProperty {
    struct Payload: Equatable, Codable, Sendable {
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
}

package extension CSSNodeStyles {
    struct Identity: Equatable, Hashable, Sendable {
        package var nodeID: DOMNode.ID
        package var targetID: ProtocolTarget.ID
        package var documentID: DOMDocument.ID
        package var protocolNodeID: DOMNode.ProtocolID
        package var targetCapabilities: ProtocolTarget.Capabilities

        package init(
            nodeID: DOMNode.ID,
            targetID: ProtocolTarget.ID,
            documentID: DOMDocument.ID,
            protocolNodeID: DOMNode.ProtocolID,
            targetCapabilities: ProtocolTarget.Capabilities
        ) {
            self.nodeID = nodeID
            self.targetID = targetID
            self.documentID = documentID
            self.protocolNodeID = protocolNodeID
            self.targetCapabilities = targetCapabilities
        }
    }

    enum UnavailableReason: Swift.Error, Equatable, Sendable {
        case noSelection
        case nonElementNode(DOMNode.Kind)
        case staleNode(DOMNode.ID)
        case cssUnavailableForTarget(ProtocolTarget.ID)
    }

    enum State: Equatable, Sendable {
        case loading
        case loaded
        case unavailable(UnavailableReason)
        case failed(String)
        case needsRefresh
    }
}

package extension CSSStyle.Section {
    enum Kind: Equatable, Hashable, Sendable {
        case inlineStyle
        case rule
        case attributesStyle
        case pseudoElement(String)
        case inheritedInlineStyle(ancestorIndex: Int)
        case inheritedRule(ancestorIndex: Int)
    }

    struct ID: Hashable, Sendable {
        package var nodeID: DOMNode.ID
        package var kind: Kind
        package var ordinal: Int

        package init(nodeID: DOMNode.ID, kind: Kind, ordinal: Int) {
            self.nodeID = nodeID
            self.kind = kind
            self.ordinal = ordinal
        }
    }
}

package extension CSSCommand {
    enum Intent: Equatable, Sendable {
        case enable(targetID: ProtocolTarget.ID)
        case getMatchedStyles(identity: CSSNodeStyles.Identity, includePseudo: Bool = true, includeInherited: Bool = true)
        case getInlineStyles(identity: CSSNodeStyles.Identity)
        case getComputedStyle(identity: CSSNodeStyles.Identity)
        case setStyleText(targetID: ProtocolTarget.ID, styleID: CSSStyle.ID, text: String)
    }
}
