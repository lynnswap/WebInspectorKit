import Foundation
import Observation
import WebInspectorTransport

private struct CSSPropertyInspectorBaseline: Equatable {
    var name: String
    var value: String
    var priority: String
    var text: String?
    var status: CSSProperty.Status

    init(_ property: CSSProperty) {
        name = property.name
        value = property.value
        priority = property.priority
        text = property.text
        status = property.status
    }
}

@Observable
package final class CSSProperty: Equatable {
    /// Stable row identity within an editable CSS declaration.
    ///
    /// Core derives this from the owning `CSSStyle.ID` and the property's
    /// index in that declaration. Source-less properties have no stable
    /// protocol identity and compare by object identity instead.
    package var id: CSSProperty.ID?
    package var name: String
    package var value: String
    package var priority: String
    package var text: String?
    /// WebKit protocol parse result for the authored declaration text.
    ///
    /// `false` means the backend kept the property text, but couldn't parse it
    /// as a valid CSS declaration.
    package var parsedOk: Bool
    /// WebKit protocol cascade/editing state for this property.
    ///
    /// `.disabled` is a commented-out declaration. `.inactive` is enabled but
    /// overridden inside the owning declaration.
    package var status: CSSProperty.Status
    /// True when WebKit synthesized this row from a shorthand declaration.
    package var implicit: Bool
    package var range: CSSStyle.SourceRange?
    /// True when Core can safely rewrite the owning style text for this row.
    package var isEditable: Bool
    /// True after this inspector successfully rewrites the authored style text for this row.
    package var isModifiedByInspector: Bool
    @ObservationIgnored private var inspectorBaseline: CSSPropertyInspectorBaseline?

    package init(
        id: CSSProperty.ID? = nil,
        name: String,
        value: String,
        priority: String = "",
        text: String? = nil,
        parsedOk: Bool = true,
        status: CSSProperty.Status = .style,
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

    package convenience init(payload: CSSProperty.Payload, id: CSSProperty.ID?, isEditable: Bool) {
        self.init(
            id: id,
            name: payload.name,
            value: payload.value,
            priority: payload.priority,
            text: payload.text,
            parsedOk: payload.parsedOk,
            status: payload.status,
            implicit: payload.implicit,
            range: payload.range,
            isEditable: isEditable
        )
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

    package static func == (lhs: CSSProperty, rhs: CSSProperty) -> Bool {
        if let lhsID = lhs.id, let rhsID = rhs.id {
            return lhsID == rhsID
        }
        return lhs === rhs
    }

    func rememberInspectorBaselineIfNeeded() {
        if inspectorBaseline == nil {
            inspectorBaseline = CSSPropertyInspectorBaseline(self)
        }
    }

    func updateInspectorModificationState() {
        guard let inspectorBaseline else {
            isModifiedByInspector = false
            return
        }
        let isModified = CSSPropertyInspectorBaseline(self) != inspectorBaseline
        isModifiedByInspector = isModified
        if isModified == false {
            self.inspectorBaseline = nil
        }
    }
}

@Observable
package final class CSSStyle: Equatable {
    package var id: CSSStyle.ID?
    package var cssProperties: [CSSProperty]
    package var shorthandEntries: [CSSStyle.ShorthandEntry]
    package var cssText: String?
    package var range: CSSStyle.SourceRange?
    package var width: String?
    package var height: String?
    package var isEditable: Bool

    package init(
        id: CSSStyle.ID? = nil,
        cssProperties: [CSSProperty],
        shorthandEntries: [CSSStyle.ShorthandEntry] = [],
        cssText: String? = nil,
        range: CSSStyle.SourceRange? = nil,
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

    package static func == (lhs: CSSStyle, rhs: CSSStyle) -> Bool {
        if let lhsID = lhs.id, let rhsID = rhs.id {
            return lhsID == rhsID
        }
        return lhs === rhs
    }
}

package extension CSSRule {
    struct SourceLocation: Equatable, Sendable {
        package var sourceURL: String
        /// Zero-based source line, matching WebKit source location values.
        package var line: Int
        /// Zero-based source column when the selector range provides one.
        package var column: Int?

        package init(sourceURL: String, line: Int, column: Int? = nil) {
            self.sourceURL = sourceURL
            self.line = line
            self.column = column
        }

        package init?(
            sourceURL: String?,
            selectorRange: CSSStyle.SourceRange?,
            fallbackLine: Int,
            styleSheetSourceLocation: CSSStyleSheet.SourceLocation? = nil
        ) {
            guard let resolvedSourceURL = Self.nonEmpty(sourceURL) ?? Self.nonEmpty(styleSheetSourceLocation?.sourceURL) else {
                return nil
            }
            let line: Int
            let column: Int?
            if let selectorRange {
                line = selectorRange.startLine
                column = selectorRange.startColumn
            } else {
                line = fallbackLine
                column = nil
            }

            if let styleSheetSourceLocation {
                let offsetColumn = column.map { column in
                    line == 0 ? styleSheetSourceLocation.startColumn + column : column
                }
                self.init(
                    sourceURL: resolvedSourceURL,
                    line: styleSheetSourceLocation.startLine + line,
                    column: offsetColumn
                )
            } else {
                self.init(sourceURL: resolvedSourceURL, line: line, column: column)
            }
        }

        private static func nonEmpty(_ value: String?) -> String? {
            guard let value, !value.isEmpty else {
                return nil
            }
            return value
        }
    }
}

package extension CSSStyleSheet {
    struct SourceLocation: Equatable, Sendable {
        package var sourceURL: String?
        package var startLine: Int
        package var startColumn: Int

        package init(sourceURL: String?, startLine: Int, startColumn: Int) {
            self.sourceURL = sourceURL
            self.startLine = startLine
            self.startColumn = startColumn
        }
    }
}

@Observable
package final class CSSRule: Equatable {
    package var id: CSSRule.ID?
    package var selectorList: CSSRule.SelectorList
    package var sourceURL: String?
    package var sourceLine: Int
    package var styleSheetSourceLocation: CSSStyleSheet.SourceLocation?
    package var origin: CSSStyle.Origin
    package var style: CSSStyle
    package var groupings: [CSSRule.Grouping]
    package var isImplicitlyNested: Bool

    package init(
        id: CSSRule.ID? = nil,
        selectorList: CSSRule.SelectorList,
        sourceURL: String? = nil,
        sourceLine: Int,
        styleSheetSourceLocation: CSSStyleSheet.SourceLocation? = nil,
        origin: CSSStyle.Origin,
        style: CSSStyle,
        groupings: [CSSRule.Grouping] = [],
        isImplicitlyNested: Bool = false
    ) {
        self.id = id
        self.selectorList = selectorList
        self.sourceURL = sourceURL
        self.sourceLine = sourceLine
        self.styleSheetSourceLocation = styleSheetSourceLocation
        self.origin = origin
        self.style = style
        self.groupings = groupings
        self.isImplicitlyNested = isImplicitlyNested
    }

    package var sourceLocation: CSSRule.SourceLocation? {
        CSSRule.SourceLocation(
            sourceURL: sourceURL,
            selectorRange: selectorList.range,
            fallbackLine: sourceLine,
            styleSheetSourceLocation: styleSheetSourceLocation
        )
    }

    package static func == (lhs: CSSRule, rhs: CSSRule) -> Bool {
        if let lhsID = lhs.id, let rhsID = rhs.id {
            return lhsID == rhsID
        }
        return lhs === rhs
    }
}

@Observable
package final class CSSComputedStyleProperty: Equatable {
    /// Computed-style rows are keyed by CSS property name in the computed list.
    package var id: String {
        name
    }

    package var name: String
    package var value: String

    package init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    package init(payload: CSSComputedStyleProperty.Payload) {
        name = payload.name
        value = payload.value
    }

    package static func == (lhs: CSSComputedStyleProperty, rhs: CSSComputedStyleProperty) -> Bool {
        lhs.id == rhs.id
    }
}

package extension CSSStyle {
    @Observable
    final class Section: Equatable {
        package var id: CSSStyle.Section.ID
        package var kind: CSSStyle.Section.Kind
        package var title: String
        package var rule: CSSRule?
        package var style: CSSStyle
        package var isEditable: Bool

        package init(
            id: CSSStyle.Section.ID,
            kind: CSSStyle.Section.Kind,
            title: String,
            rule: CSSRule? = nil,
            style: CSSStyle,
            isEditable: Bool
        ) {
            self.id = id
            self.kind = kind
            self.title = title
            self.rule = rule
            self.style = style
            self.isEditable = isEditable
        }

        package static func == (lhs: CSSStyle.Section, rhs: CSSStyle.Section) -> Bool {
            lhs.id == rhs.id
        }
    }
}

@MainActor
@Observable
package final class CSSNodeStyles {
    private enum RefreshPhase: Equatable {
        case idle
        case refreshing(sequence: UInt64)

        var sequence: UInt64? {
            switch self {
            case .idle:
                nil
            case let .refreshing(sequence):
                sequence
            }
        }

        var isRefreshing: Bool {
            sequence != nil
        }
    }

    package let identity: CSSNodeStyles.Identity
    package var state: CSSNodeStyles.State
    package var sections: [CSSStyle.Section]
    package var computedProperties: [CSSComputedStyleProperty]
    @ObservationIgnored private var refreshPhase: RefreshPhase

    package init(
        identity: CSSNodeStyles.Identity,
        state: CSSNodeStyles.State = .loading,
        sections: [CSSStyle.Section] = [],
        computedProperties: [CSSComputedStyleProperty] = []
    ) {
        self.identity = identity
        self.state = state
        self.sections = sections
        self.computedProperties = computedProperties
        refreshPhase = .idle
    }

    fileprivate var isRefreshing: Bool {
        refreshPhase.isRefreshing
    }

    fileprivate func beginRefresh(sequence: UInt64) {
        state = .loading
        refreshPhase = .refreshing(sequence: sequence)
    }

    fileprivate func isActiveRefresh(_ token: CSSStyle.RefreshToken) -> Bool {
        identity == token.identity && refreshPhase.sequence == token.sequence
    }

    fileprivate func clearRefresh(_ token: CSSStyle.RefreshToken) {
        guard isActiveRefresh(token) else {
            return
        }
        refreshPhase = .idle
    }

    fileprivate func clearRefresh() {
        refreshPhase = .idle
    }

    fileprivate func cancelRefresh(sequence: UInt64?) -> Bool {
        guard let activeSequence = refreshPhase.sequence,
              sequence.map({ $0 == activeSequence }) ?? true,
              state == .loading else {
            return false
        }
        refreshPhase = .idle
        state = .needsRefresh
        return true
    }
}

private struct CSSStyleSheetHeaderKey: Equatable, Hashable {
    var targetID: ProtocolTarget.ID
    var styleSheetID: CSSStyleSheet.ID
}

@MainActor
private struct CSSSelectedStyleCoordinator {
    private(set) var identity: CSSNodeStyles.Identity?
    private var unavailableReason: CSSNodeStyles.UnavailableReason

    init() {
        identity = nil
        unavailableReason = .noSelection
    }

    func state(displayedNodeStyles: CSSNodeStyles?) -> CSSNodeStyles.State {
        displayedNodeStyles?.state ?? .unavailable(unavailableReason)
    }

    mutating func select(_ identity: CSSNodeStyles.Identity) {
        self.identity = identity
        unavailableReason = .noSelection
    }

    mutating func markUnavailable(_ reason: CSSNodeStyles.UnavailableReason) {
        identity = nil
        unavailableReason = reason
    }

    mutating func markSelectedStylesUnavailable(
        identity: CSSNodeStyles.Identity,
        displayedNodeStyles: CSSNodeStyles?,
        unavailableNodeStyles: CSSNodeStyles,
        reason: CSSNodeStyles.UnavailableReason
    ) -> Bool {
        if self.identity == identity {
            unavailableReason = reason
            return true
        }
        guard displayedNodeStyles === unavailableNodeStyles else {
            return false
        }
        unavailableReason = reason
        return true
    }

    mutating func markRefreshFailed(_ token: CSSStyle.RefreshToken) -> Bool {
        guard identity == token.identity else {
            return false
        }
        unavailableReason = .staleNode(token.identity.nodeID)
        return true
    }

    mutating func clearIfRemovingTarget(
        _ targetID: ProtocolTarget.ID,
        displayedNodeStyles: CSSNodeStyles?
    ) -> Bool {
        var didClearDisplayedNodeStyles = false
        if let displayedNodeStyles,
           displayedNodeStyles.identity.targetID == targetID {
            unavailableReason = .staleNode(displayedNodeStyles.identity.nodeID)
            didClearDisplayedNodeStyles = true
        }
        if identity?.targetID == targetID {
            identity = nil
        }
        return didClearDisplayedNodeStyles
    }
}

@MainActor
private struct CSSNodeStyleStore {
    private var stylesByNodeID: [DOMNode.ID: CSSNodeStyles] = [:]

    mutating func removeAll() {
        stylesByNodeID.removeAll()
    }

    func nodeStyles(for identity: CSSNodeStyles.Identity) -> CSSNodeStyles? {
        guard let nodeStyles = stylesByNodeID[identity.nodeID],
              nodeStyles.identity == identity else {
            return nil
        }
        return nodeStyles
    }

    mutating func ensureNodeStyles(
        for identity: CSSNodeStyles.Identity,
        initialState: CSSNodeStyles.State = .loading
    ) -> CSSNodeStyles {
        if let nodeStyles = nodeStyles(for: identity) {
            return nodeStyles
        }
        let nodeStyles = CSSNodeStyles(identity: identity, state: initialState)
        stylesByNodeID[identity.nodeID] = nodeStyles
        return nodeStyles
    }

    func nodeStyles(targetID: ProtocolTarget.ID) -> [CSSNodeStyles] {
        stylesByNodeID.values.filter { $0.identity.targetID == targetID }
    }

    func nodeStyles(targetID: ProtocolTarget.ID, protocolNodeID: DOMNode.ProtocolID) -> CSSNodeStyles? {
        stylesByNodeID.values.first {
            $0.identity.targetID == targetID && $0.identity.protocolNodeID == protocolNodeID
        }
    }

    mutating func markNeedsRefresh(
        targetID: ProtocolTarget.ID,
        including shouldMark: (CSSNodeStyles) -> Bool
    ) {
        for nodeStyles in stylesByNodeID.values
        where nodeStyles.identity.targetID == targetID && shouldMark(nodeStyles) {
            guard !(nodeStyles.state == .loading && nodeStyles.isRefreshing) else {
                continue
            }
            nodeStyles.state = .needsRefresh
            nodeStyles.clearRefresh()
        }
    }

    mutating func removeStyles(targetID: ProtocolTarget.ID) -> Bool {
        let removedIDs = stylesByNodeID
            .filter { $0.value.identity.targetID == targetID }
            .map(\.key)
        guard !removedIDs.isEmpty else {
            return false
        }
        for nodeID in removedIDs {
            stylesByNodeID.removeValue(forKey: nodeID)
        }
        return true
    }
}

struct CSSStyleSheetHeaderRegistry {
    private var headersByKey: [CSSStyleSheetHeaderKey: CSSStyleSheet.HeaderPayload] = [:]

    mutating func removeAll() {
        headersByKey.removeAll()
    }

    mutating func register(_ header: CSSStyleSheet.HeaderPayload, targetID: ProtocolTarget.ID) {
        headersByKey[CSSStyleSheetHeaderKey(
            targetID: targetID,
            styleSheetID: header.styleSheetID
        )] = header
    }

    mutating func remove(styleSheetID: CSSStyleSheet.ID, targetID: ProtocolTarget.ID) {
        headersByKey.removeValue(forKey: CSSStyleSheetHeaderKey(
            targetID: targetID,
            styleSheetID: styleSheetID
        ))
    }

    mutating func removeTarget(_ targetID: ProtocolTarget.ID) {
        headersByKey = headersByKey.filter { $0.key.targetID != targetID }
    }

    func sourceLocation(
        for rule: CSSRule.Payload,
        targetID: ProtocolTarget.ID
    ) -> CSSStyleSheet.SourceLocation? {
        guard let styleSheetID = rule.id?.styleSheetID ?? rule.style.id?.styleSheetID,
              let header = headersByKey[CSSStyleSheetHeaderKey(targetID: targetID, styleSheetID: styleSheetID)] else {
            return nil
        }
        return CSSStyleSheet.SourceLocation(
            sourceURL: header.sourceURL,
            startLine: header.startLine,
            startColumn: header.startColumn
        )
    }
}

@MainActor
@Observable
package final class CSSSession {
    package struct RefreshResults {
        package var matched: CSSStyle.MatchedStylesPayload
        package var inline: CSSStyle.InlineStylesPayload
        package var computed: [CSSComputedStyleProperty.Payload]
    }

    package private(set) var selectedNodeStyles: CSSNodeStyles?
    package var selectedState: CSSNodeStyles.State {
        selection.state(displayedNodeStyles: selectedNodeStyles)
    }

    package func nodeStyles(for identity: CSSNodeStyles.Identity) -> CSSNodeStyles? {
        nodeStyleStore.nodeStyles(for: identity)
    }

    private var selection: CSSSelectedStyleCoordinator
    @ObservationIgnored private var nodeStyleStore: CSSNodeStyleStore
    @ObservationIgnored private var styleSheetHeaders: CSSStyleSheetHeaderRegistry
    @ObservationIgnored private var nextRefreshSequence: UInt64
    @ObservationIgnored private let refreshCoordinator: CSSSession.StyleRefreshCoordinator

    package init() {
        selectedNodeStyles = nil
        selection = CSSSelectedStyleCoordinator()
        nodeStyleStore = CSSNodeStyleStore()
        styleSheetHeaders = CSSStyleSheetHeaderRegistry()
        nextRefreshSequence = 0
        refreshCoordinator = CSSSession.StyleRefreshCoordinator()
    }

    package func reset() {
        selectedNodeStyles = nil
        selection = CSSSelectedStyleCoordinator()
        nodeStyleStore.removeAll()
        styleSheetHeaders.removeAll()
        nextRefreshSequence = 0
    }

    package func bindProtocolChannel(_ commandChannel: ProtocolCommandChannel) {
        refreshCoordinator.bindProtocolChannel(commandChannel)
    }

    package func unbindProtocolChannel() {
        refreshCoordinator.unbindProtocolChannel()
    }

    @discardableResult
    package func perform(_ intent: CSSCommand.Intent) async throws -> ProtocolCommand.Result {
        try await refreshCoordinator.perform(intent)
    }

    package func fetchRefreshResults(for identity: CSSNodeStyles.Identity) async throws -> RefreshResults {
        try await refreshCoordinator.fetchRefreshResults(for: identity)
    }

    package func setStyleTextResult(from result: ProtocolCommand.Result) throws -> CSSStyle.Payload {
        try refreshCoordinator.setStyleTextResult(from: result)
    }

    package func selectNodeStyles(identity: CSSNodeStyles.Identity) {
        selection.select(identity)
        let nodeStyles = ensureNodeStyles(for: identity, initialState: .needsRefresh)
        selectCurrentNodeStyles(nodeStyles)
    }

    package func markSelectedNodeUnavailable(_ reason: CSSNodeStyles.UnavailableReason) {
        selection.markUnavailable(reason)
        guard selectedNodeStyles != nil || selectedState != .unavailable(reason) else {
            return
        }
        selectedNodeStyles = nil
    }

    package func markSelectedNodeStylesUnavailable(
        identity: CSSNodeStyles.Identity,
        reason: CSSNodeStyles.UnavailableReason
    ) {
        let nodeStyles = ensureNodeStyles(for: identity)
        nodeStyles.state = .unavailable(reason)
        nodeStyles.clearRefresh()
        guard selection.markSelectedStylesUnavailable(
            identity: identity,
            displayedNodeStyles: selectedNodeStyles,
            unavailableNodeStyles: nodeStyles,
            reason: reason
        ) else {
            return
        }
        selectedNodeStyles = nil
    }

    package func refreshState(forSelected identity: CSSNodeStyles.Identity) -> CSSNodeStyles.State? {
        nodeStyles(for: identity)?.state
    }

    package func beginRefresh(identity: CSSNodeStyles.Identity) -> CSSStyle.RefreshToken? {
        guard identity.targetCapabilities.contains(.css) else {
            markSelectedNodeUnavailable(.cssUnavailableForTarget(identity.targetID))
            return nil
        }

        nextRefreshSequence &+= 1
        let nodeStyles = ensureNodeStyles(for: identity)
        nodeStyles.beginRefresh(sequence: nextRefreshSequence)
        selection.select(identity)
        selectCurrentNodeStyles(nodeStyles)
        return CSSStyle.RefreshToken(identity: identity, sequence: nextRefreshSequence)
    }

    package func applyRefresh(
        token: CSSStyle.RefreshToken,
        matched: CSSStyle.MatchedStylesPayload,
        inline: CSSStyle.InlineStylesPayload,
        computed: [CSSComputedStyleProperty.Payload]
    ) {
        guard let nodeStyles = nodeStyleStore.nodeStyles(for: token.identity),
              nodeStyles.isActiveRefresh(token) else {
            return
        }

        CSSStyle.Reconciler.updateSections(
            in: nodeStyles,
            with: CSSStyle.SectionBuilder.makeSections(
                identity: token.identity,
                matched: matched,
                inline: inline,
                styleSheetHeaders: styleSheetHeaders
            )
        )
        CSSStyle.Reconciler.updateComputedProperties(
            in: nodeStyles,
            with: computed.map(CSSComputedStyleProperty.init(payload:))
        )
        nodeStyles.state = .loaded
        nodeStyles.clearRefresh(token)
        if selection.identity == token.identity {
            selectCurrentNodeStyles(nodeStyles)
        }
    }

    package func registerStyleSheetHeader(_ header: CSSStyleSheet.HeaderPayload, targetID: ProtocolTarget.ID) {
        styleSheetHeaders.register(header, targetID: targetID)
    }

    package func removeStyleSheetHeader(styleSheetID: CSSStyleSheet.ID, targetID: ProtocolTarget.ID) {
        styleSheetHeaders.remove(styleSheetID: styleSheetID, targetID: targetID)
    }

    package func markRefreshFailed(_ token: CSSStyle.RefreshToken, message: String) {
        guard let nodeStyles = nodeStyleStore.nodeStyles(for: token.identity),
              nodeStyles.isActiveRefresh(token) else {
            return
        }
        nodeStyles.state = .failed(message)
        nodeStyles.clearRefresh(token)
        if selection.markRefreshFailed(token) {
            selectedNodeStyles = nil
        }
    }

    package func cancelRefresh(identity: CSSNodeStyles.Identity) {
        cancelRefresh(identity: identity, sequence: nil)
    }

    package func cancelRefresh(_ token: CSSStyle.RefreshToken) {
        cancelRefresh(identity: token.identity, sequence: token.sequence)
    }

    private func cancelRefresh(identity: CSSNodeStyles.Identity, sequence: UInt64?) {
        guard let nodeStyles = nodeStyles(for: identity),
              nodeStyles.cancelRefresh(sequence: sequence) else {
            return
        }
        if selection.identity == identity {
            selectCurrentNodeStyles(nodeStyles)
        }
    }

    package func markNeedsRefresh(targetID: ProtocolTarget.ID) {
        markNeedsRefresh(targetID: targetID, including: { _ in true })
    }

    package func markNeedsRefresh(targetID: ProtocolTarget.ID, styleSheetID: CSSStyleSheet.ID) {
        markNeedsRefresh(targetID: targetID, including: { nodeStyles in
            Self.nodeStyles(nodeStyles, references: styleSheetID)
        })
    }

    private func markNeedsRefresh(
        targetID: ProtocolTarget.ID,
        including shouldMark: (CSSNodeStyles) -> Bool
    ) {
        nodeStyleStore.markNeedsRefresh(targetID: targetID, including: shouldMark)
    }

    private static func nodeStyles(_ nodeStyles: CSSNodeStyles, references styleSheetID: CSSStyleSheet.ID) -> Bool {
        nodeStyles.sections.contains { section in
            switch section.kind {
            case .inlineStyle, .attributesStyle:
                false
            default:
                section.rule?.id?.styleSheetID == styleSheetID
                    || section.rule?.style.id?.styleSheetID == styleSheetID
                    || section.style.id?.styleSheetID == styleSheetID
            }
        }
    }

    package func markNeedsRefresh(targetID: ProtocolTarget.ID, nodeID: DOMNode.ProtocolID) {
        guard let current = nodeStyleStore.nodeStyles(targetID: targetID, protocolNodeID: nodeID) else {
            return
        }
        guard !(current.state == .loading && current.isRefreshing) else {
            return
        }
        current.state = .needsRefresh
        current.clearRefresh()
    }

    package func removeStyles(targetID: ProtocolTarget.ID) {
        styleSheetHeaders.removeTarget(targetID)
        guard nodeStyleStore.removeStyles(targetID: targetID) else {
            return
        }
        if selection.clearIfRemovingTarget(targetID, displayedNodeStyles: selectedNodeStyles) {
            self.selectedNodeStyles = nil
        }
    }

    package func setStyleTextIntent(for propertyID: CSSProperty.ID, enabled: Bool) -> CSSCommand.Intent? {
        guard let nodeStyles = selectedNodeStyles,
              selection.identity == nodeStyles.identity,
              case .loaded = selectedState,
              case .loaded = nodeStyles.state,
              let (sectionIndex, propertyIndex) = Self.locateProperty(propertyID, in: nodeStyles.sections),
              nodeStyles.sections[sectionIndex].isEditable else {
            return nil
        }

        let style = nodeStyles.sections[sectionIndex].style
        guard style.isEditable,
              style.id == propertyID.styleID,
              style.cssProperties.indices.contains(propertyIndex) else {
            return nil
        }
        let property = style.cssProperties[propertyIndex]
        guard property.isEditable,
              property.isEnabled != enabled,
              let text = CSSStyle.TextRewriter.rewrittenStyleText(style: style, propertyIndex: propertyIndex, enabled: enabled) else {
            return nil
        }
        return .setStyleText(targetID: nodeStyles.identity.targetID, styleID: propertyID.styleID, text: text)
    }

    private func selectCurrentNodeStyles(_ nodeStyles: CSSNodeStyles) {
        switch nodeStyles.state {
        case .unavailable, .failed:
            guard selectedNodeStyles != nil else {
                return
            }
            selectedNodeStyles = nil
        case .loading, .loaded, .needsRefresh:
            selection.select(nodeStyles.identity)
            guard selectedNodeStyles !== nodeStyles else {
                return
            }
            selectedNodeStyles = nodeStyles
        }
    }

    private func ensureNodeStyles(
        for identity: CSSNodeStyles.Identity,
        initialState: CSSNodeStyles.State = .loading
    ) -> CSSNodeStyles {
        nodeStyleStore.ensureNodeStyles(for: identity, initialState: initialState)
    }

    package func applySetStyleTextResult(
        _ style: CSSStyle.Payload,
        propertyID: CSSProperty.ID,
        targetID: ProtocolTarget.ID
    ) {
        for nodeStyles in nodeStyleStore.nodeStyles(targetID: targetID) {
            for sectionIndex in nodeStyles.sections.indices where nodeStyles.sections[sectionIndex].style.id == propertyID.styleID {
                let section = nodeStyles.sections[sectionIndex]
                if section.style.cssProperties.indices.contains(propertyID.propertyIndex),
                   section.style.cssProperties[propertyID.propertyIndex].id == propertyID {
                    section.style.cssProperties[propertyID.propertyIndex].rememberInspectorBaselineIfNeeded()
                }
                let normalizedStyle = CSSStyle.SectionBuilder.normalizedStyle(
                    style,
                    isEditable: section.isEditable,
                    ruleOrigin: section.rule?.origin
                )
                CSSStyle.Reconciler.updateStyle(section.style, from: normalizedStyle)
                if section.style.cssProperties.indices.contains(propertyID.propertyIndex),
                   section.style.cssProperties[propertyID.propertyIndex].id == propertyID {
                    section.style.cssProperties[propertyID.propertyIndex].updateInspectorModificationState()
                }
                if let rule = section.rule {
                    rule.style = section.style
                }
                nodeStyles.state = .needsRefresh
            }
        }
    }

    private static func locateProperty(
        _ propertyID: CSSProperty.ID,
        in sections: [CSSStyle.Section]
    ) -> (sectionIndex: Int, propertyIndex: Int)? {
        for sectionIndex in sections.indices {
            let style = sections[sectionIndex].style
            guard style.id == propertyID.styleID,
                  style.cssProperties.indices.contains(propertyID.propertyIndex) else {
                continue
            }
            return (sectionIndex, propertyID.propertyIndex)
        }
        return nil
    }

}
