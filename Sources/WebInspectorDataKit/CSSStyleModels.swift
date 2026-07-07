import WebInspectorProxyKit

public struct CSSStyleSection: Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case inlineStyle
        case rule
        case attributesStyle
        case pseudoElement(String)
        case inheritedInlineStyle(ancestorIndex: Int)
        case inheritedRule(ancestorIndex: Int)
    }

    public struct ID: Hashable, Sendable {
        public let kind: Kind
        public let ordinal: Int
    }

    public let id: ID
    public let kind: Kind
    public let title: String?
    public let rule: CSSStyleRule?
    public let style: CSSStyle
    public let isEditable: Bool

    package let proxyRule: CSS.Rule?
    package let proxyStyle: CSS.Style

    package init(
        id: ID,
        kind: Kind,
        title: String?,
        rule: CSS.Rule?,
        style: CSS.Style,
        isEditable: Bool
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.rule = rule.map(CSSStyleRule.init)
        self.style = CSSStyle(style)
        self.isEditable = isEditable
        proxyRule = rule
        proxyStyle = style
    }
}

public struct CSSStyle: Sendable, Identifiable {
    public struct ID: Hashable, Sendable {
        public let rawValue: String

        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        package init(_ id: CSS.Style.ID) {
            rawValue = id.rawValue
        }

        package var proxyID: CSS.Style.ID {
            CSS.Style.ID(rawValue)
        }
    }

    public struct SourceRange: Sendable, Equatable {
        public let startLine: Int
        public let startColumn: Int
        public let endLine: Int
        public let endColumn: Int

        public init(startLine: Int, startColumn: Int, endLine: Int, endColumn: Int) {
            self.startLine = startLine
            self.startColumn = startColumn
            self.endLine = endLine
            self.endColumn = endColumn
        }

        package init(_ range: CSS.Style.SourceRange) {
            self.init(
                startLine: range.startLine,
                startColumn: range.startColumn,
                endLine: range.endLine,
                endColumn: range.endColumn
            )
        }

        package var proxyRange: CSS.Style.SourceRange {
            CSS.Style.SourceRange(
                startLine: startLine,
                startColumn: startColumn,
                endLine: endLine,
                endColumn: endColumn
            )
        }
    }

    public struct ShorthandEntry: Sendable, Equatable {
        public let name: String
        public let value: String
        public let priority: String?

        public init(name: String, value: String, priority: String? = nil) {
            self.name = name
            self.value = value
            self.priority = priority
        }

        package init(_ entry: CSS.Style.ShorthandEntry) {
            self.init(name: entry.name, value: entry.value, priority: entry.priority)
        }
    }

    public let id: ID
    public let properties: [CSSStyleProperty]
    public let shorthandEntries: [ShorthandEntry]
    public let cssText: String
    public let range: SourceRange?
    public let width: String?
    public let height: String?
    public let isEditable: Bool

    public init(
        id: ID,
        properties: [CSSStyleProperty] = [],
        shorthandEntries: [ShorthandEntry] = [],
        cssText: String = "",
        range: SourceRange? = nil,
        width: String? = nil,
        height: String? = nil,
        isEditable: Bool = false
    ) {
        self.id = id
        self.properties = properties
        self.shorthandEntries = shorthandEntries
        self.cssText = cssText
        self.range = range
        self.width = width
        self.height = height
        self.isEditable = isEditable
    }

    package init(_ style: CSS.Style) {
        self.init(
            id: ID(style.id),
            properties: style.properties.map(CSSStyleProperty.init),
            shorthandEntries: style.shorthandEntries.map(ShorthandEntry.init),
            cssText: style.cssText,
            range: style.range.map(SourceRange.init),
            width: style.width,
            height: style.height,
            isEditable: style.isEditable
        )
    }
}

public struct CSSStyleRule: Sendable {
    public struct ID: Hashable, Sendable {
        public let rawValue: String

        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        package init(_ id: CSS.Rule.ID) {
            rawValue = id.rawValue
        }

        package var proxyID: CSS.Rule.ID {
            CSS.Rule.ID(rawValue)
        }
    }

    public struct Origin: RawRepresentable, Hashable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        package init(_ origin: CSS.Origin) {
            rawValue = origin.rawValue
        }
    }

    public struct Grouping: Sendable, Equatable {
        public let text: String

        public init(text: String) {
            self.text = text
        }

        package init(_ grouping: CSS.Rule.Grouping) {
            self.init(text: grouping.text)
        }
    }

    public let id: ID?
    public let selectors: [String]
    public let selectorText: String
    public let selectorRange: CSSStyle.SourceRange?
    public let sourceURL: String?
    public let sourceLine: Int?
    public let sourceLocation: CSSStyle.SourceRange?
    public let origin: Origin
    public let style: CSSStyle
    public let groupings: [Grouping]
    public let isImplicitlyNested: Bool

    public init(
        id: ID? = nil,
        selectors: [String] = [],
        selectorText: String = "",
        selectorRange: CSSStyle.SourceRange? = nil,
        sourceURL: String? = nil,
        sourceLine: Int? = nil,
        sourceLocation: CSSStyle.SourceRange? = nil,
        origin: Origin,
        style: CSSStyle,
        groupings: [Grouping] = [],
        isImplicitlyNested: Bool = false
    ) {
        self.id = id
        self.selectors = selectors
        self.selectorText = selectorText
        self.selectorRange = selectorRange
        self.sourceURL = sourceURL
        self.sourceLine = sourceLine
        self.sourceLocation = sourceLocation
        self.origin = origin
        self.style = style
        self.groupings = groupings
        self.isImplicitlyNested = isImplicitlyNested
    }

    package init(_ rule: CSS.Rule) {
        self.init(
            id: rule.id.map(ID.init),
            selectors: rule.selectorList.selectors,
            selectorText: rule.selectorList.text,
            selectorRange: rule.selectorList.range.map(CSSStyle.SourceRange.init),
            sourceURL: rule.sourceURL,
            sourceLine: rule.sourceLine,
            sourceLocation: rule.sourceLocation.map(CSSStyle.SourceRange.init),
            origin: Origin(rule.origin),
            style: CSSStyle(rule.style),
            groupings: rule.groupings.map(Grouping.init),
            isImplicitlyNested: rule.isImplicitlyNested
        )
    }
}

public struct CSSStyleProperty: Sendable, Identifiable {
    public struct ID: Hashable, Sendable {
        public let rawValue: String

        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        package init(_ id: CSS.Property.ID) {
            rawValue = id.rawValue
        }

        package var proxyID: CSS.Property.ID {
            CSS.Property.ID(rawValue)
        }
    }

    public enum Status: Sendable, Equatable {
        case active
        case inactive
        case disabled

        package init(_ status: CSS.Status) {
            switch status {
            case .active:
                self = .active
            case .inactive:
                self = .inactive
            case .disabled:
                self = .disabled
            }
        }

        package var proxyStatus: CSS.Status {
            switch self {
            case .active:
                .active
            case .inactive:
                .inactive
            case .disabled:
                .disabled
            }
        }
    }

    public let id: ID
    public let name: String
    public let value: String
    public let priority: String?
    public let text: String?
    public let parsedOk: Bool
    public let status: Status
    public let implicit: Bool
    public let range: CSSStyle.SourceRange?
    public let isEditable: Bool
    public let isModifiedByInspector: Bool

    public var isEnabled: Bool {
        status != .disabled
    }

    public var isOverridden: Bool {
        status == .inactive
    }

    public init(
        id: ID,
        name: String,
        value: String,
        priority: String? = nil,
        text: String? = nil,
        parsedOk: Bool = true,
        status: Status = .active,
        implicit: Bool = false,
        range: CSSStyle.SourceRange? = nil,
        isEditable: Bool = false,
        isModifiedByInspector: Bool = false
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
        self.isModifiedByInspector = isModifiedByInspector
    }

    package init(_ property: CSS.Property) {
        self.init(
            id: ID(property.id),
            name: property.name,
            value: property.value,
            priority: property.priority,
            text: property.text,
            parsedOk: property.parsedOk,
            status: Status(property.status),
            implicit: property.implicit,
            range: property.range.map(CSSStyle.SourceRange.init),
            isEditable: property.isEditable,
            isModifiedByInspector: property.isModifiedByInspector
        )
    }
}

public struct CSSComputedProperty: Sendable, Equatable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    package init(_ property: CSS.ComputedProperty) {
        self.init(name: property.name, value: property.value)
    }
}
