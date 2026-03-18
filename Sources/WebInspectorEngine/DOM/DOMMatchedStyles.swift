import Foundation

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
}

public struct DOMMatchedStyleRule: Codable, Hashable, Sendable {
    public enum Origin: String, Codable, Hashable, Sendable {
        case inline
        case author
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
}

public struct DOMMatchedStyleDeclaration: Codable, Hashable, Sendable {
    public var name: String
    public var value: String
    public var important: Bool

    public init(name: String, value: String, important: Bool) {
        self.name = name
        self.value = value
        self.important = important
    }
}
