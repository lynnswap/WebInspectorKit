import Foundation

/// Types and commands for the Web Inspector CSS domain.
public enum CSS {
    /// A target-scoped client for CSS commands and events.
    public struct Client: Sendable {
        package let context: DomainClientContext

        package init(context: DomainClientContext) {
            self.context = context
        }

        /// Enables CSS domain events and commands for the target.
        public func enable() async throws {
            try await context.dispatchVoid(
                domain: .css,
                method: "enable",
                payload: EnablePayload()
            )
        }

        /// Disables CSS domain events for the target.
        public func disable() async throws {
            try await context.dispatchVoid(
                domain: .css,
                method: "disable",
                payload: DisablePayload()
            )
        }

        /// Returns cascade information for the supplied DOM node.
        public func matchedStyles(for node: DOM.Node.ID) async throws -> MatchedStyles {
            try await context.dispatch(
                domain: .css,
                method: "getMatchedStylesForNode",
                payload: GetMatchedStylesForNodePayload(node: node),
                returning: MatchedStyles.self
            )
        }

        /// Returns the computed CSS properties for the supplied DOM node.
        public func computedStyle(for node: DOM.Node.ID) async throws -> [ComputedProperty] {
            try await context.dispatch(
                domain: .css,
                method: "getComputedStyleForNode",
                payload: GetComputedStyleForNodePayload(node: node),
                returning: [ComputedProperty].self
            )
        }

        /// Returns the inline and attribute-derived style declarations for the node.
        public func inlineStyles(for node: DOM.Node.ID) async throws -> InlineStyles {
            try await context.dispatch(
                domain: .css,
                method: "getInlineStylesForNode",
                payload: GetInlineStylesForNodePayload(node: node),
                returning: InlineStyles.self
            )
        }

        /// Replaces the declaration text for a style and returns the updated style.
        public func setStyleText(_ id: Style.ID, text: String) async throws -> Style {
            try await context.dispatch(
                domain: .css,
                method: "setStyleText",
                payload: SetStyleTextPayload(id: id, text: text),
                returning: Style.self
            )
        }

        /// Replaces the full text of a stylesheet.
        public func setStyleSheetText(_ id: StyleSheet.ID, text: String) async throws {
            try await context.dispatchVoid(
                domain: .css,
                method: "setStyleSheetText",
                payload: SetStyleSheetTextPayload(id: id, text: text)
            )
        }

        /// Replaces the selector text for a rule and returns the updated rule.
        public func setRuleSelector(_ id: Rule.ID, selector: String) async throws -> Rule {
            try await context.dispatch(
                domain: .css,
                method: "setRuleSelector",
                payload: SetRuleSelectorPayload(id: id, selector: selector),
                returning: Rule.self
            )
        }

        /// Replaces the grouping header for a nested rule and returns the updated grouping.
        public func setGroupingHeaderText(_ id: Rule.ID, text: String) async throws -> Rule.Grouping {
            try await context.dispatch(
                domain: .css,
                method: "setGroupingHeaderText",
                payload: SetGroupingHeaderTextPayload(id: id, text: text),
                returning: Rule.Grouping.self
            )
        }

        /// CSS domain events emitted by this target.
        public var events: EventStream {
            EventStream {
                context.cssEvents()
            }
        }
    }

    package struct EnablePayload: Sendable {
        package init() {}
    }

    package struct DisablePayload: Sendable {
        package init() {}
    }

    package struct GetMatchedStylesForNodePayload: Sendable {
        package let node: DOM.Node.ID

        package init(node: DOM.Node.ID) {
            self.node = node
        }
    }

    package struct GetComputedStyleForNodePayload: Sendable {
        package let node: DOM.Node.ID

        package init(node: DOM.Node.ID) {
            self.node = node
        }
    }

    package struct GetInlineStylesForNodePayload: Sendable {
        package let node: DOM.Node.ID

        package init(node: DOM.Node.ID) {
            self.node = node
        }
    }

    package struct SetStyleTextPayload: Sendable {
        package let id: Style.ID
        package let text: String

        package init(id: Style.ID, text: String) {
            self.id = id
            self.text = text
        }
    }

    package struct SetStyleSheetTextPayload: Sendable {
        package let id: StyleSheet.ID
        package let text: String

        package init(id: StyleSheet.ID, text: String) {
            self.id = id
            self.text = text
        }
    }

    package struct SetRuleSelectorPayload: Sendable {
        package let id: Rule.ID
        package let selector: String

        package init(id: Rule.ID, selector: String) {
            self.id = id
            self.selector = selector
        }
    }

    package struct SetGroupingHeaderTextPayload: Sendable {
        package let id: Rule.ID
        package let text: String

        package init(id: Rule.ID, text: String) {
            self.id = id
            self.text = text
        }
    }

    /// Cascade and inherited style information for one DOM node.
    public struct MatchedStyles: Sendable {
        /// One entry per ancestor in cascade order; WebKit reports the
        /// ancestor's inline style alongside its matched rules.
        public struct InheritedEntry: Sendable {
            /// The inline style for the ancestor, if WebKit reported one.
            public let inlineStyle: Style?

            /// Rules that match the ancestor.
            public let matchedRules: [Rule]

            /// Creates an inherited style entry.
            public init(inlineStyle: Style? = nil, matchedRules: [Rule] = []) {
                self.inlineStyle = inlineStyle
                self.matchedRules = matchedRules
            }
        }

        /// Rules that match one pseudo element.
        public struct PseudoElementMatches: Sendable {
            /// WebKit's pseudo-element identifier.
            public let pseudoID: String

            /// Rules that match the pseudo element.
            public let matchedRules: [Rule]

            /// Creates pseudo-element matched style information.
            public init(pseudoID: String, matchedRules: [Rule] = []) {
                self.pseudoID = pseudoID
                self.matchedRules = matchedRules
            }
        }

        /// Rules that match the requested node.
        public let matchedRules: [Rule]

        /// Matched styles for ancestor elements.
        public let inherited: [InheritedEntry]

        /// Matched styles for pseudo elements associated with the node.
        public let pseudoElements: [PseudoElementMatches]

        /// Creates matched style information.
        public init(
            matchedRules: [Rule] = [],
            inherited: [InheritedEntry] = [],
            pseudoElements: [PseudoElementMatches] = []
        ) {
            self.matchedRules = matchedRules
            self.inherited = inherited
            self.pseudoElements = pseudoElements
        }
    }

    /// Result of `CSS.getInlineStylesForNode` — the element's `style`
    /// attribute declaration and the style synthesized from presentational
    /// HTML attributes.
    public struct InlineStyles: Sendable {
        /// The declaration represented by the element's `style` attribute.
        public let inlineStyle: Style?

        /// The declaration synthesized from presentational HTML attributes.
        public let attributesStyle: Style?

        /// Creates inline style information.
        public init(inlineStyle: Style? = nil, attributesStyle: Style? = nil) {
            self.inlineStyle = inlineStyle
            self.attributesStyle = attributesStyle
        }
    }

    /// A CSS declaration block returned by the inspector protocol.
    public struct Style: Identifiable, Sendable {
        /// Stable identity for an editable CSS declaration block.
        public struct ID: Hashable, Sendable {
            package let rawValue: String

            package init(_ rawValue: String) {
                self.rawValue = rawValue
            }
        }

        /// The backend identity for the style.
        public let id: ID

        /// Longhand declarations in protocol order.
        public var properties: [Property]

        /// Shorthand declarations reported by WebKit.
        public var shorthandEntries: [ShorthandEntry]

        /// The serialized declaration text.
        public var cssText: String

        /// Source range for the declaration block, if known.
        public var range: SourceRange?

        /// CSS width hint reported for the styled node.
        public var width: String?

        /// CSS height hint reported for the styled node.
        public var height: String?

        /// A Boolean value indicating whether WebKit accepts edits for this style.
        public var isEditable: Bool

        /// Creates a CSS declaration block.
        public init(
            id: ID,
            properties: [Property] = [],
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

        /// A protocol source range using zero-based line and column offsets.
        public struct SourceRange: Sendable {
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
        }

        /// A shorthand declaration reported alongside expanded longhand properties.
        public struct ShorthandEntry: Sendable {
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
        }
    }

    /// A CSS rule and its declaration block.
    public struct Rule: Sendable {
        /// The backend identity for editable rules.
        public var id: ID?

        /// The selector list attached to the rule.
        public var selectorList: SelectorList

        /// The stylesheet URL where the rule was declared.
        public var sourceURL: String?

        /// The source line for the rule, if known.
        public var sourceLine: Int?

        /// The detailed source range for the rule, if known.
        public var sourceLocation: Style.SourceRange?

        /// The origin of the rule in WebKit's cascade model.
        public var origin: Origin

        /// The rule declaration block.
        public var style: Style

        /// Nested grouping headers enclosing the rule.
        public var groupings: [Grouping]

        /// A Boolean value indicating whether the rule is implicitly nested.
        public var isImplicitlyNested: Bool

        /// Creates a CSS rule.
        public init(
            id: ID? = nil,
            selectorList: SelectorList,
            sourceURL: String? = nil,
            sourceLine: Int? = nil,
            sourceLocation: Style.SourceRange? = nil,
            origin: Origin,
            style: Style,
            groupings: [Grouping] = [],
            isImplicitlyNested: Bool = false
        ) {
            self.id = id
            self.selectorList = selectorList
            self.sourceURL = sourceURL
            self.sourceLine = sourceLine
            self.sourceLocation = sourceLocation
            self.origin = origin
            self.style = style
            self.groupings = groupings
            self.isImplicitlyNested = isImplicitlyNested
        }

        /// Stable identity for an editable CSS rule.
        public struct ID: Hashable, Sendable {
            package let rawValue: String

            package init(_ rawValue: String) {
                self.rawValue = rawValue
            }
        }

        /// Selector text and parsed selector components.
        public struct SelectorList: Sendable {
            /// Individual selectors in the list.
            public let selectors: [String]

            /// The serialized selector text.
            public let text: String

            /// Source range for the selector list, if known.
            public let range: Style.SourceRange?

            /// Creates a selector list.
            public init(selectors: [String] = [], text: String = "", range: Style.SourceRange? = nil) {
                self.selectors = selectors
                self.text = text
                self.range = range
            }
        }

        /// A grouping header around a nested CSS rule.
        public struct Grouping: Sendable {
            /// The serialized grouping header text.
            public let text: String

            /// Creates a grouping header.
            public init(text: String) {
                self.text = text
            }
        }
    }

    /// A CSS property declaration.
    public struct Property: Identifiable, Sendable {
        /// Stable identity for an editable CSS property.
        public struct ID: Hashable, Sendable {
            package let rawValue: String

            package init(_ rawValue: String) {
                self.rawValue = rawValue
            }
        }

        /// The backend identity for the property declaration.
        public let id: ID

        /// The property name.
        public let name: String

        /// The property value.
        public let value: String

        /// The declaration priority, such as `important`.
        public let priority: String?

        /// The original declaration text, if WebKit reported it.
        public let text: String?

        /// A Boolean value indicating whether WebKit parsed the declaration successfully.
        public let parsedOk: Bool

        /// The cascade status of the declaration.
        public let status: Status

        /// A Boolean value indicating whether the declaration is implicit.
        public let implicit: Bool

        /// Source range for the declaration, if known.
        public let range: Style.SourceRange?

        /// A Boolean value indicating whether WebKit accepts edits for this declaration.
        public let isEditable: Bool

        /// A Boolean value indicating whether the declaration was changed through the inspector.
        public let isModifiedByInspector: Bool

        /// Creates a CSS property declaration.
        public init(
            id: ID,
            name: String,
            value: String,
            priority: String? = nil,
            text: String? = nil,
            parsedOk: Bool = true,
            status: Status = .active,
            implicit: Bool = false,
            range: Style.SourceRange? = nil,
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
    }

    /// Cascade status for a CSS declaration.
    public enum Status: Sendable {
        /// The declaration applies to the element.
        case active

        /// The declaration is overridden by another declaration.
        case inactive

        /// The declaration is disabled in the inspector.
        case disabled
    }

    /// WebKit's origin value for a CSS rule or declaration.
    public struct Origin: RawRepresentable, Hashable, Sendable {
        /// The raw protocol origin.
        public let rawValue: String

        /// Creates an origin from its raw protocol value.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    /// A computed CSS property returned for a DOM node.
    public struct ComputedProperty: Sendable {
        /// The computed property name.
        public let name: String

        /// The computed property value.
        public let value: String

        /// Creates a computed property.
        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    /// Metadata for a stylesheet known to the inspected page.
    public struct StyleSheetHeader: Sendable {
        /// The backend identity for the stylesheet.
        public let styleSheetID: StyleSheet.ID

        /// The frame that owns the stylesheet, if WebKit reported one.
        public let frameID: FrameID?

        /// The stylesheet URL, if any.
        public let sourceURL: String?

        /// The stylesheet origin.
        public let origin: Origin

        /// The stylesheet title, if any.
        public let title: String?

        /// A Boolean value indicating whether the stylesheet is disabled.
        public let disabled: Bool

        /// A Boolean value indicating whether the stylesheet is inline.
        public let isInline: Bool

        /// The starting source line for the stylesheet.
        public let startLine: Int

        /// The starting source column for the stylesheet.
        public let startColumn: Int

        /// Creates stylesheet metadata.
        public init(
            styleSheetID: StyleSheet.ID,
            frameID: FrameID? = nil,
            sourceURL: String? = nil,
            origin: Origin,
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
    }

    /// Namespace for stylesheet identity values.
    public enum StyleSheet {
        /// Stable identity for a stylesheet.
        public struct ID: Hashable, Sendable {
            package let rawValue: String

            package init(_ rawValue: String) {
                self.rawValue = rawValue
            }
        }
    }

    /// Events emitted by the CSS domain.
    public enum Event: Sendable {
        /// A stylesheet's contents changed.
        case styleSheetChanged(StyleSheet.ID)

        /// A stylesheet was added to the page.
        case styleSheetAdded(StyleSheetHeader)

        /// A stylesheet was removed from the page.
        case styleSheetRemoved(StyleSheet.ID)

        /// Media query evaluation changed.
        case mediaQueryResultChanged

        /// Layout flags changed for a DOM node.
        case nodeLayoutFlagsChanged(DOM.Node.ID)

        /// An event that is not modeled by this package.
        case unknown(RawEvent)
    }

    /// An asynchronous stream of CSS domain events.
    public struct EventStream: AsyncSequence, Sendable {
        /// The event yielded by the stream.
        public typealias Element = Event

        /// The iterator type used by the stream.
        public typealias AsyncIterator = AsyncStream<Event>.Iterator

        private let makeStream: @Sendable () -> AsyncStream<Event>

        package init(
            _ makeStream: @escaping @Sendable () -> AsyncStream<Event> = {
                finishedStream(of: Event.self)
            }
        ) {
            self.makeStream = makeStream
        }

        /// Creates an iterator over CSS events.
        public func makeAsyncIterator() -> AsyncIterator {
            makeStream().makeAsyncIterator()
        }
    }
}

package extension CSS.StyleSheet.ID {
    private static var targetScopeSeparator: Character { "\u{1E}" }

    init(_ rawValue: String, scopedToTargetRawValue targetRawValue: String) {
        self.init("\(targetRawValue)\(Self.targetScopeSeparator)\(rawValue)")
    }

    var targetScopeRawValue: String? {
        let parts = rawValue.split(separator: Self.targetScopeSeparator, maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return nil
        }
        return String(parts[0])
    }

    var unscopedRawValue: String {
        let parts = rawValue.split(separator: Self.targetScopeSeparator, maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return rawValue
        }
        return String(parts[1])
    }
}

package extension CSS.Rule.ID {
    private static var targetScopeSeparator: Character { "\u{1E}" }

    init(_ rawValue: String, scopedToTargetRawValue targetRawValue: String) {
        self.init("\(targetRawValue)\(Self.targetScopeSeparator)\(rawValue)")
    }

    var targetScopeRawValue: String? {
        let parts = rawValue.split(separator: Self.targetScopeSeparator, maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return nil
        }
        return String(parts[0])
    }

    var unscopedRawValue: String {
        let parts = rawValue.split(separator: Self.targetScopeSeparator, maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return rawValue
        }
        return String(parts[1])
    }

    var owningStyleSheetID: CSS.StyleSheet.ID? {
        CSS.owningStyleSheetID(
            from: unscopedRawValue,
            targetScopeRawValue: targetScopeRawValue
        )
    }
}

package extension CSS.Style.ID {
    private static var targetScopeSeparator: Character { "\u{1E}" }

    init(_ rawValue: String, scopedToTargetRawValue targetRawValue: String) {
        self.init("\(targetRawValue)\(Self.targetScopeSeparator)\(rawValue)")
    }

    var targetScopeRawValue: String? {
        let parts = rawValue.split(separator: Self.targetScopeSeparator, maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return nil
        }
        return String(parts[0])
    }

    var unscopedRawValue: String {
        let parts = rawValue.split(separator: Self.targetScopeSeparator, maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return rawValue
        }
        return String(parts[1])
    }

    var owningStyleSheetID: CSS.StyleSheet.ID? {
        CSS.owningStyleSheetID(
            from: unscopedRawValue,
            targetScopeRawValue: targetScopeRawValue
        )
    }
}

package extension CSS {
    static var styleIdentifierSeparator: Character { "\u{1F}" }

    private static func owningStyleSheetID(
        from rawValue: String,
        targetScopeRawValue: String?
    ) -> CSS.StyleSheet.ID? {
        let components = rawValue.split(
            separator: styleIdentifierSeparator,
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
              Int(components[1]) != nil else {
            return nil
        }
        let styleSheetRawValue = String(components[0])
        return targetScopeRawValue.map {
            CSS.StyleSheet.ID(styleSheetRawValue, scopedToTargetRawValue: $0)
        } ?? CSS.StyleSheet.ID(styleSheetRawValue)
    }
}
