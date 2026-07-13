import Observation
import WebInspectorProxyKit

/// A display section in the CSS style sidebar for a DOM element.
public struct CSSStyleSection: Identifiable {
    /// The source of a style section.
    public enum Kind: Hashable, Sendable {
        /// The element's inline `style` declaration.
        case inlineStyle

        /// A matched CSS rule.
        case rule

        /// The style synthesized from presentational HTML attributes.
        case attributesStyle

        /// A pseudo-element style section.
        case pseudoElement(String)

        /// An inherited inline style section for an ancestor.
        case inheritedInlineStyle(ancestorIndex: Int)

        /// An inherited matched rule section for an ancestor.
        case inheritedRule(ancestorIndex: Int)
    }

    /// Stable identity for a CSS style section.
    public struct ID: Hashable, Sendable {
        /// The section kind.
        public let kind: Kind

        /// The ordinal used to disambiguate repeated section kinds.
        public let ordinal: Int
    }

    /// The stable section identity.
    public let id: ID

    /// The source of the section.
    public let kind: Kind

    /// The display title for the section.
    public let title: String?

    /// The matched rule represented by the section, if any.
    public let rule: CSSStyleRule?

    /// The declaration block displayed in the section.
    public let style: CSSStyle

    /// A Boolean value indicating whether the section accepts edits.
    public let isEditable: Bool

    package let proxyRule: CSS.Rule?
    package let proxyStyle: CSS.Style

    package init(
        id: ID,
        kind: Kind,
        title: String?,
        rule: CSS.Rule?,
        style: CSS.Style,
        isEditable: Bool,
        propertyModels: [CSSStyleProperty]? = nil
    ) {
        let styleModel = CSSStyle(style, propertyModels: propertyModels)
        self.id = id
        self.kind = kind
        self.title = title
        self.rule = rule.map { CSSStyleRule($0, styleModel: styleModel) }
        self.style = styleModel
        self.isEditable = isEditable
        proxyRule = rule
        proxyStyle = style
    }
}

/// A DataKit model for a CSS declaration block.
public struct CSSStyle: Identifiable {
    /// Stable identity for a CSS declaration block.
    public struct ID: Hashable, Sendable {
        /// The raw backend style identifier.
        public let rawValue: String

        /// Creates a style identity from a backend identifier string.
        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        /// Creates a style identity from a raw value.
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

    /// A source range using zero-based line and column offsets.
    public struct SourceRange: Sendable, Equatable {
        /// The starting line offset.
        public let startLine: Int

        /// The starting column offset.
        public let startColumn: Int

        /// The ending line offset.
        public let endLine: Int

        /// The ending column offset.
        public let endColumn: Int

        /// Creates a source range.
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

    /// A shorthand declaration reported alongside expanded longhand properties.
    public struct ShorthandEntry: Sendable, Equatable {
        /// The shorthand property name.
        public let name: String

        /// The shorthand property value.
        public let value: String

        /// The declaration priority, such as `important`.
        public let priority: String?

        /// Creates a shorthand entry.
        public init(name: String, value: String, priority: String? = nil) {
            self.name = name
            self.value = value
            self.priority = priority
        }

        package init(_ entry: CSS.Style.ShorthandEntry) {
            self.init(name: entry.name, value: entry.value, priority: entry.priority)
        }
    }

    /// The stable style identity.
    public let id: ID

    /// Longhand declarations in display order.
    public let properties: [CSSStyleProperty]

    /// Shorthand declarations reported by WebKit.
    public let shorthandEntries: [ShorthandEntry]

    /// The serialized declaration text.
    public let cssText: String

    /// Source range for the declaration block, if known.
    public let range: SourceRange?

    /// CSS width hint reported for the styled node.
    public let width: String?

    /// CSS height hint reported for the styled node.
    public let height: String?

    /// A Boolean value indicating whether WebKit accepts edits for this style.
    public let isEditable: Bool

    /// Creates a CSS declaration block.
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

    package init(
        _ style: CSS.Style,
        propertyModels: [CSSStyleProperty]? = nil
    ) {
        self.init(
            id: ID(style.id),
            properties: propertyModels ?? style.properties.map(CSSStyleProperty.init),
            shorthandEntries: style.shorthandEntries.map(ShorthandEntry.init),
            cssText: style.cssText,
            range: style.range.map(SourceRange.init),
            width: style.width,
            height: style.height,
            isEditable: style.isEditable
        )
    }
}

/// A DataKit model for a matched CSS rule.
public struct CSSStyleRule {
    /// Stable identity for an editable CSS rule.
    public struct ID: Hashable, Sendable {
        /// The raw backend rule identifier.
        public let rawValue: String

        /// Creates a rule identity from a backend identifier string.
        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        /// Creates a rule identity from a raw value.
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

    /// WebKit's origin value for a CSS rule.
    public struct Origin: RawRepresentable, Hashable, Sendable {
        /// The raw protocol origin.
        public let rawValue: String

        /// Creates a rule origin from its raw protocol value.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        package init(_ origin: CSS.Origin) {
            rawValue = origin.rawValue
        }
    }

    /// A grouping header around a nested CSS rule.
    public struct Grouping: Sendable, Equatable {
        /// The serialized grouping header text.
        public let text: String

        /// Creates a grouping header.
        public init(text: String) {
            self.text = text
        }

        package init(_ grouping: CSS.Rule.Grouping) {
            self.init(text: grouping.text)
        }
    }

    /// The rule identity, if WebKit can edit the rule.
    public let id: ID?

    /// Individual selectors in the rule's selector list.
    public let selectors: [String]

    /// The serialized selector text.
    public let selectorText: String

    /// Source range for the selector list, if known.
    public let selectorRange: CSSStyle.SourceRange?

    /// The stylesheet URL where the rule was declared.
    public let sourceURL: String?

    /// The source line for the rule, if known.
    public let sourceLine: Int?

    /// The detailed source range for the rule, if known.
    public let sourceLocation: CSSStyle.SourceRange?

    /// The origin of the rule in WebKit's cascade model.
    public let origin: Origin

    /// The declaration block for the rule.
    public let style: CSSStyle

    /// Nested grouping headers enclosing the rule.
    public let groupings: [Grouping]

    /// A Boolean value indicating whether the rule is implicitly nested.
    public let isImplicitlyNested: Bool

    /// Creates a CSS rule model.
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

    package init(_ rule: CSS.Rule, styleModel: CSSStyle? = nil) {
        self.init(
            id: rule.id.map(ID.init),
            selectors: rule.selectorList.selectors,
            selectorText: rule.selectorList.text,
            selectorRange: rule.selectorList.range.map(CSSStyle.SourceRange.init),
            sourceURL: rule.sourceURL,
            sourceLine: rule.sourceLine,
            sourceLocation: rule.sourceLocation.map(CSSStyle.SourceRange.init),
            origin: Origin(rule.origin),
            style: styleModel ?? CSSStyle(rule.style),
            groupings: rule.groupings.map(Grouping.init),
            isImplicitlyNested: rule.isImplicitlyNested
        )
    }
}

/// An observable CSS property declaration with stable backend identity.
@Observable
public final class CSSStyleProperty: Identifiable {
    /// Stable identity for an editable CSS property.
    public struct ID: Hashable, Sendable {
        /// The raw backend property identifier.
        public let rawValue: String

        /// Creates a property identity from a backend identifier string.
        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        /// Creates a property identity from a raw value.
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

    /// Cascade status for a CSS declaration.
    public enum Status: Sendable, Equatable {
        /// The declaration applies to the element.
        case active

        /// The declaration is overridden by another declaration.
        case inactive

        /// The declaration is disabled in the inspector.
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

    /// The stable property identity.
    public let id: ID

    /// The property name.
    public private(set) var name: String

    /// The property value.
    public private(set) var value: String

    /// The declaration priority, such as `important`.
    public private(set) var priority: String?

    /// The original declaration text, if WebKit reported it.
    public private(set) var text: String?

    /// A Boolean value indicating whether WebKit parsed the declaration successfully.
    public private(set) var parsedOk: Bool

    /// The cascade status of the declaration.
    public private(set) var status: Status

    /// A Boolean value indicating whether the declaration is implicit.
    public private(set) var implicit: Bool

    /// Source range for the declaration, if known.
    public private(set) var range: CSSStyle.SourceRange?

    /// A Boolean value indicating whether WebKit accepts edits for this declaration.
    public private(set) var isEditable: Bool

    /// A Boolean value indicating whether the declaration was changed through DataKit.
    public private(set) var isModifiedByInspector: Bool

    /// A Boolean value indicating whether this declaration has a submitted mutation awaiting completion.
    public private(set) var isMutationPending: Bool

    @ObservationIgnored package weak var ownerStyles: CSSStyles?

    /// A Boolean value indicating whether the declaration is enabled.
    public var isEnabled: Bool {
        status != .disabled
    }

    /// A Boolean value indicating whether the declaration is overridden.
    public var isOverridden: Bool {
        status == .inactive
    }

    /// Creates a CSS property declaration model.
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
        isMutationPending = false
        ownerStyles = nil
    }

    package convenience init(_ property: CSS.Property) {
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

    package func update(from property: CSSStyleProperty) {
        if name != property.name { name = property.name }
        if value != property.value { value = property.value }
        if priority != property.priority { priority = property.priority }
        if text != property.text { text = property.text }
        if parsedOk != property.parsedOk { parsedOk = property.parsedOk }
        if status != property.status { status = property.status }
        if implicit != property.implicit { implicit = property.implicit }
        if range != property.range { range = property.range }
        if isEditable != property.isEditable { isEditable = property.isEditable }
        if isModifiedByInspector != property.isModifiedByInspector {
            isModifiedByInspector = property.isModifiedByInspector
        }
    }

    package func beginMutation() -> Bool {
        guard isMutationPending == false else {
            return false
        }
        isMutationPending = true
        return true
    }

    package func endMutation() {
        isMutationPending = false
    }

    package func bindOwner(_ styles: CSSStyles) {
        ownerStyles = styles
    }
}

/// A computed CSS property for a DOM node.
public struct CSSComputedProperty: Sendable, Equatable {
    /// The computed property name.
    public let name: String

    /// The computed property value.
    public let value: String

    /// Creates a computed property.
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    package init(_ property: CSS.ComputedProperty) {
        self.init(name: property.name, value: property.value)
    }
}
