import Foundation
import Observation

public enum DOMStyleLoadState: String, Hashable, Codable, Sendable {
    case idle
    case loading
    case loaded
    case failed
}

public enum DOMStyleInvalidationReason: String, Hashable, Codable, Sendable {
    case domMutation
    case styleSheetChanged
    case mediaQueryChanged
    case selectionChanged
    case manualRefresh
}

@MainActor
@Observable
public final class DOMStyleState {
    public private(set) var sourceRevision: Int
    public private(set) var loadState: DOMStyleLoadState
    public private(set) var needsRefresh: Bool
    public private(set) var matched: DOMMatchedStyleState
    public private(set) var computed: DOMComputedStyleState
    public private(set) var errorMessage: String?

    public init(
        sourceRevision: Int = 0,
        loadState: DOMStyleLoadState = .idle,
        needsRefresh: Bool = false,
        matched: DOMMatchedStyleState = .empty,
        computed: DOMComputedStyleState = .empty,
        errorMessage: String? = nil
    ) {
        self.sourceRevision = sourceRevision
        self.loadState = loadState
        self.needsRefresh = needsRefresh
        self.matched = matched
        self.computed = computed
        self.errorMessage = errorMessage
    }

    public var isLoading: Bool {
        loadState == .loading
    }

    public func recordSourceRevision(_ revision: Int) {
        guard sourceRevision != revision else {
            return
        }
        sourceRevision = revision
    }

    public func beginLoading() {
        loadState = .loading
        needsRefresh = false
        matched = .empty
        computed = .empty
        errorMessage = nil
    }

    public func apply(_ payload: DOMNodeStylePayload) {
        matched = payload.matched
        computed = payload.computed
        loadState = .loaded
        needsRefresh = false
        errorMessage = nil
    }

    public func fail(_ message: String) {
        loadState = .failed
        matched = .empty
        computed = .empty
        errorMessage = message
    }

    public func invalidate(reason: DOMStyleInvalidationReason) {
        sourceRevision &+= 1
        if sourceRevision < 0 {
            sourceRevision = 0
        }
        needsRefresh = true

        if loadState == .idle {
            return
        }

        if loadState == .failed {
            errorMessage = nil
        }
    }

    public func reset(sourceRevision: Int = 0) {
        self.sourceRevision = sourceRevision
        loadState = .idle
        needsRefresh = false
        matched = .empty
        computed = .empty
        errorMessage = nil
    }

    func setNeedsRefreshForCompatibility(_ value: Bool) {
        needsRefresh = value
    }

    func setLoadStateForCompatibility(isLoading: Bool) {
        loadState = isLoading ? .loading : .loaded
    }

    func setMatchedForCompatibility(
        rules: [DOMStyleRule],
        isTruncated: Bool,
        blockedStylesheetCount: Int
    ) {
        matched = DOMMatchedStyleState(
            sections: rules.isEmpty ? [] : [
                DOMStyleSection(kind: .element, rules: rules)
            ],
            isTruncated: isTruncated,
            blockedStylesheetCount: blockedStylesheetCount
        )
    }
}

public struct DOMNodeStylePayload: Codable, Hashable, Sendable {
    public var nodeId: Int
    public var matched: DOMMatchedStyleState
    public var computed: DOMComputedStyleState

    public init(
        nodeId: Int,
        matched: DOMMatchedStyleState,
        computed: DOMComputedStyleState
    ) {
        self.nodeId = nodeId
        self.matched = matched
        self.computed = computed
    }
}

public struct DOMMatchedStyleState: Codable, Hashable, Sendable {
    public static let empty = Self(sections: [], isTruncated: false, blockedStylesheetCount: 0)

    public var sections: [DOMStyleSection]
    public var isTruncated: Bool
    public var blockedStylesheetCount: Int

    public init(
        sections: [DOMStyleSection],
        isTruncated: Bool,
        blockedStylesheetCount: Int
    ) {
        self.sections = sections
        self.isTruncated = isTruncated
        self.blockedStylesheetCount = blockedStylesheetCount
    }

    public var allRules: [DOMStyleRule] {
        sections.flatMap(\.rules)
    }

    public var isEmpty: Bool {
        allRules.isEmpty
    }
}

public struct DOMComputedStyleState: Codable, Hashable, Sendable {
    public static let empty = Self(properties: [])

    public var properties: [DOMComputedStyleProperty]

    public init(properties: [DOMComputedStyleProperty]) {
        self.properties = properties
    }

    public var isEmpty: Bool {
        properties.isEmpty
    }
}

public struct DOMStyleSection: Codable, Hashable, Sendable {
    public var kind: DOMStyleSectionKind
    public var title: String?
    public var relatedNodeId: Int?
    public var rules: [DOMStyleRule]

    public init(
        kind: DOMStyleSectionKind,
        title: String? = nil,
        relatedNodeId: Int? = nil,
        rules: [DOMStyleRule]
    ) {
        self.kind = kind
        self.title = title
        self.relatedNodeId = relatedNodeId
        self.rules = rules
    }
}

public enum DOMStyleSectionKind: String, Codable, Hashable, Sendable {
    case element
    case pseudoElement
    case inherited
}

public struct DOMStyleRule: Codable, Hashable, Sendable {
    public var origin: DOMStyleOrigin
    public var selectorText: String
    public var matchedSelectorTexts: [String]
    public var declarations: [DOMStyleDeclaration]
    public var source: DOMStyleSource
    public var groupings: [DOMStyleGrouping]

    public init(
        origin: DOMStyleOrigin,
        selectorText: String,
        matchedSelectorTexts: [String] = [],
        declarations: [DOMStyleDeclaration],
        source: DOMStyleSource,
        groupings: [DOMStyleGrouping] = []
    ) {
        self.origin = origin
        self.selectorText = selectorText
        self.matchedSelectorTexts = matchedSelectorTexts
        self.declarations = declarations
        self.source = source
        self.groupings = groupings
    }
}

public enum DOMStyleOrigin: String, Codable, Hashable, Sendable {
    case inline
    case attribute
    case author
    case user
    case userAgent
    case inspector
}

public struct DOMStyleDeclaration: Codable, Hashable, Sendable {
    public var name: String
    public var value: String
    public var important: Bool
    public var isImplicit: Bool
    public var isOverridden: Bool

    public init(
        name: String,
        value: String,
        important: Bool,
        isImplicit: Bool = false,
        isOverridden: Bool = false
    ) {
        self.name = name
        self.value = value
        self.important = important
        self.isImplicit = isImplicit
        self.isOverridden = isOverridden
    }
}

public struct DOMStyleSource: Codable, Hashable, Sendable {
    public var label: String
    public var url: String?
    public var line: Int?
    public var column: Int?

    public init(
        label: String,
        url: String? = nil,
        line: Int? = nil,
        column: Int? = nil
    ) {
        self.label = label
        self.url = url
        self.line = line
        self.column = column
    }
}

public struct DOMStyleGrouping: Codable, Hashable, Sendable {
    public var kind: String?
    public var text: String

    public init(kind: String? = nil, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct DOMComputedStyleProperty: Codable, Hashable, Sendable {
    public var name: String
    public var value: String
    public var isImplicit: Bool

    public init(name: String, value: String, isImplicit: Bool) {
        self.name = name
        self.value = value
        self.isImplicit = isImplicit
    }
}

@available(*, deprecated, renamed: "DOMStyleDeclaration")
public struct DOMMatchedStyleDeclaration: Codable, Hashable, Sendable {
    public var name: String
    public var value: String
    public var important: Bool

    public init(name: String, value: String, important: Bool) {
        self.name = name
        self.value = value
        self.important = important
    }

    init(_ declaration: DOMStyleDeclaration) {
        self.init(
            name: declaration.name,
            value: declaration.value,
            important: declaration.important
        )
    }

    var styleDeclaration: DOMStyleDeclaration {
        DOMStyleDeclaration(
            name: name,
            value: value,
            important: important
        )
    }
}

@available(*, deprecated, renamed: "DOMStyleRule")
public struct DOMMatchedStyleRule: Codable, Hashable, Sendable {
    @available(*, deprecated, renamed: "DOMStyleOrigin")
    public enum Origin: String, Codable, Hashable, Sendable {
        case inline
        case attribute
        case author
        case user
        case userAgent
        case inspector
    }

    public var origin: Origin
    public var selectorText: String
    public var declarations: [DOMMatchedStyleDeclaration]
    public var sourceLabel: String
    public var atRuleContext: [String]

    public init(
        origin: Origin,
        selectorText: String,
        declarations: [DOMMatchedStyleDeclaration],
        sourceLabel: String,
        atRuleContext: [String] = []
    ) {
        self.origin = origin
        self.selectorText = selectorText
        self.declarations = declarations
        self.sourceLabel = sourceLabel
        self.atRuleContext = atRuleContext
    }

    init(_ rule: DOMStyleRule) {
        self.init(
            origin: Origin(rule.origin),
            selectorText: rule.selectorText,
            declarations: rule.declarations.map(DOMMatchedStyleDeclaration.init),
            sourceLabel: rule.source.label,
            atRuleContext: rule.groupings.map(\.text)
        )
    }

    var styleRule: DOMStyleRule {
        DOMStyleRule(
            origin: DOMStyleOrigin(origin),
            selectorText: selectorText,
            matchedSelectorTexts: origin == .author ? [selectorText] : [],
            declarations: declarations.map(\.styleDeclaration),
            source: DOMStyleSource(label: sourceLabel),
            groupings: atRuleContext.map { DOMStyleGrouping(text: $0) }
        )
    }
}

private extension DOMStyleOrigin {
    init(_ origin: DOMMatchedStyleRule.Origin) {
        switch origin {
        case .inline:
            self = .inline
        case .attribute:
            self = .attribute
        case .author:
            self = .author
        case .user:
            self = .user
        case .userAgent:
            self = .userAgent
        case .inspector:
            self = .inspector
        }
    }
}

private extension DOMMatchedStyleRule.Origin {
    init(_ origin: DOMStyleOrigin) {
        switch origin {
        case .inline:
            self = .inline
        case .attribute:
            self = .attribute
        case .author:
            self = .author
        case .user:
            self = .user
        case .userAgent:
            self = .userAgent
        case .inspector:
            self = .inspector
        }
    }
}

public extension DOMStyleRule {
    @available(*, deprecated, message: "Use init(origin:selectorText:matchedSelectorTexts:declarations:source:groupings:) instead.")
    init(
        origin: DOMStyleOrigin,
        selectorText: String,
        declarations: [DOMStyleDeclaration],
        sourceLabel: String,
        atRuleContext: [String] = []
    ) {
        self.init(
            origin: origin,
            selectorText: selectorText,
            matchedSelectorTexts: origin == .author ? [selectorText] : [],
            declarations: declarations,
            source: DOMStyleSource(label: sourceLabel),
            groupings: atRuleContext.map { DOMStyleGrouping(text: $0) }
        )
    }

    @available(*, deprecated, message: "Use source.label instead.")
    var sourceLabel: String {
        source.label
    }

    @available(*, deprecated, message: "Use groupings.map(\\.text) instead.")
    var atRuleContext: [String] {
        groupings.map(\.text)
    }
}

@available(*, deprecated, message: "Use DOMNodeStylePayload instead.")
public struct DOMMatchedStylesPayload: Codable, Hashable, Sendable {
    public var nodeId: Int
    public var rules: [DOMMatchedStyleRule]
    public var truncated: Bool
    public var blockedStylesheetCount: Int

    public init(
        nodeId: Int,
        rules: [DOMMatchedStyleRule],
        truncated: Bool,
        blockedStylesheetCount: Int
    ) {
        self.nodeId = nodeId
        self.rules = rules
        self.truncated = truncated
        self.blockedStylesheetCount = blockedStylesheetCount
    }

    public var stylePayload: DOMNodeStylePayload {
        DOMNodeStylePayload(
            nodeId: nodeId,
            matched: DOMMatchedStyleState(
                sections: rules.isEmpty ? [] : [
                    DOMStyleSection(kind: .element, relatedNodeId: nodeId, rules: rules.map(\.styleRule))
                ],
                isTruncated: truncated,
                blockedStylesheetCount: blockedStylesheetCount
            ),
            computed: .empty
        )
    }
}

public extension DOMNodeStylePayload {
    @available(*, deprecated, message: "Use matched/computed directly.")
    var legacyMatchedStylesPayload: DOMMatchedStylesPayload {
        DOMMatchedStylesPayload(
            nodeId: nodeId,
            rules: matched.allRules.map(DOMMatchedStyleRule.init),
            truncated: matched.isTruncated,
            blockedStylesheetCount: matched.blockedStylesheetCount
        )
    }
}
