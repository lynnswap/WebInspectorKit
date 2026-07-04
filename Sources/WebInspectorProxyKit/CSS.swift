import Foundation

public enum CSS {
    public struct Client: Sendable {
        package let context: DomainClientContext

        package init(context: DomainClientContext) {
            self.context = context
        }

        public func enable() async throws {
            try await context.dispatchVoid(
                domain: .css,
                method: "enable",
                payload: EnablePayload()
            )
        }

        public func disable() async throws {
            try await context.dispatchVoid(
                domain: .css,
                method: "disable",
                payload: DisablePayload()
            )
        }

        public func matchedStyles(for node: DOM.Node.ID) async throws -> MatchedStyles {
            try await context.dispatch(
                domain: .css,
                method: "getMatchedStylesForNode",
                payload: GetMatchedStylesForNodePayload(node: node),
                returning: MatchedStyles.self
            )
        }

        public func computedStyle(for node: DOM.Node.ID) async throws -> [ComputedProperty] {
            try await context.dispatch(
                domain: .css,
                method: "getComputedStyleForNode",
                payload: GetComputedStyleForNodePayload(node: node),
                returning: [ComputedProperty].self
            )
        }

        public func inlineStyles(for node: DOM.Node.ID) async throws -> InlineStyles {
            try await context.dispatch(
                domain: .css,
                method: "getInlineStylesForNode",
                payload: GetInlineStylesForNodePayload(node: node),
                returning: InlineStyles.self
            )
        }

        public func setStyleText(_ id: Style.ID, text: String) async throws -> Style {
            try await context.dispatch(
                domain: .css,
                method: "setStyleText",
                payload: SetStyleTextPayload(id: id, text: text),
                returning: Style.self
            )
        }

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

    public struct MatchedStyles: Sendable {
        /// One entry per ancestor in cascade order; WebKit reports the
        /// ancestor's inline style alongside its matched rules.
        public struct InheritedEntry: Sendable {
            public let inlineStyle: Style?
            public let matchedRules: [Rule]

            public init(inlineStyle: Style? = nil, matchedRules: [Rule] = []) {
                self.inlineStyle = inlineStyle
                self.matchedRules = matchedRules
            }
        }

        public struct PseudoElementMatches: Sendable {
            public let pseudoID: String
            public let matchedRules: [Rule]

            public init(pseudoID: String, matchedRules: [Rule] = []) {
                self.pseudoID = pseudoID
                self.matchedRules = matchedRules
            }
        }

        public let matchedRules: [Rule]
        public let inherited: [InheritedEntry]
        public let pseudoElements: [PseudoElementMatches]

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
        public let inlineStyle: Style?
        public let attributesStyle: Style?

        public init(inlineStyle: Style? = nil, attributesStyle: Style? = nil) {
            self.inlineStyle = inlineStyle
            self.attributesStyle = attributesStyle
        }
    }

    public struct Style: Identifiable, Sendable {
        public struct ID: Hashable, Sendable {
            package let rawValue: String

            package init(_ rawValue: String) {
                self.rawValue = rawValue
            }
        }

        public let id: ID
        public var properties: [Property]
        public var shorthandEntries: [ShorthandEntry]
        public var cssText: String
        public var range: SourceRange?
        public var width: String?
        public var height: String?
        public var isEditable: Bool

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

        public struct SourceRange: Sendable {
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
        }

        public struct ShorthandEntry: Sendable {
            public let name: String
            public let value: String
            public let priority: String?

            public init(name: String, value: String, priority: String? = nil) {
                self.name = name
                self.value = value
                self.priority = priority
            }
        }
    }

    public struct Rule: Sendable {
        public var id: ID?
        public var selectorList: SelectorList
        public var sourceURL: String?
        public var sourceLine: Int?
        public var sourceLocation: Style.SourceRange?
        public var origin: Origin
        public var style: Style
        public var groupings: [Grouping]
        public var isImplicitlyNested: Bool

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

        public struct ID: Hashable, Sendable {
            package let rawValue: String

            package init(_ rawValue: String) {
                self.rawValue = rawValue
            }
        }

        public struct SelectorList: Sendable {
            public let selectors: [String]
            public let text: String
            public let range: Style.SourceRange?

            public init(selectors: [String] = [], text: String = "", range: Style.SourceRange? = nil) {
                self.selectors = selectors
                self.text = text
                self.range = range
            }
        }

        public struct Grouping: Sendable {
            public let text: String

            public init(text: String) {
                self.text = text
            }
        }
    }

    public struct Property: Identifiable, Sendable {
        public struct ID: Hashable, Sendable {
            package let rawValue: String

            package init(_ rawValue: String) {
                self.rawValue = rawValue
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
        public let range: Style.SourceRange?
        public let isEditable: Bool
        public let isModifiedByInspector: Bool

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

    public enum Status: Sendable {
        case active
        case inactive
        case disabled
    }

    public struct Origin: RawRepresentable, Hashable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    public struct ComputedProperty: Sendable {
        public let name: String
        public let value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public struct StyleSheetHeader: Sendable {
        public let styleSheetID: StyleSheet.ID
        public let frameID: FrameID?
        public let sourceURL: String?
        public let origin: Origin
        public let title: String?
        public let disabled: Bool
        public let isInline: Bool
        public let startLine: Int
        public let startColumn: Int

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

    public enum StyleSheet {
        public struct ID: Hashable, Sendable {
            package let rawValue: String

            package init(_ rawValue: String) {
                self.rawValue = rawValue
            }
        }
    }

    public enum Event: Sendable {
        case styleSheetChanged
        case styleSheetAdded(StyleSheetHeader)
        case styleSheetRemoved(StyleSheet.ID)
        case mediaQueryResultChanged
        case nodeLayoutFlagsChanged(DOM.Node.ID)
        case unknown(RawEvent)
    }

    public struct EventStream: AsyncSequence, Sendable {
        public typealias Element = Event
        public typealias AsyncIterator = AsyncStream<Event>.Iterator

        private let makeStream: @Sendable () -> AsyncStream<Event>

        package init(
            _ makeStream: @escaping @Sendable () -> AsyncStream<Event> = {
                finishedStream(of: Event.self)
            }
        ) {
            self.makeStream = makeStream
        }

        public func makeAsyncIterator() -> AsyncIterator {
            makeStream().makeAsyncIterator()
        }
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
}
