import Foundation
import Observation
import WebInspectorTransport

private struct CSSPropertyInspectorBaseline: Equatable {
    var name: String
    var value: String
    var priority: String
    var text: String?
    var status: CSSPropertyStatus

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
    /// Core derives this from the owning `CSSStyleIdentifier` and the property's
    /// index in that declaration. Source-less properties have no stable
    /// protocol identity and compare by object identity instead.
    package var id: CSSPropertyIdentifier?
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
    package var status: CSSPropertyStatus
    /// True when WebKit synthesized this row from a shorthand declaration.
    package var implicit: Bool
    package var range: CSSSourceRange?
    /// True when Core can safely rewrite the owning style text for this row.
    package var isEditable: Bool
    /// True after this inspector successfully rewrites the authored style text for this row.
    package var isModifiedByInspector: Bool
    @ObservationIgnored private var inspectorBaseline: CSSPropertyInspectorBaseline?

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

    package convenience init(payload: CSSPropertyPayload, id: CSSPropertyIdentifier?, isEditable: Bool) {
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

    fileprivate func rememberInspectorBaselineIfNeeded() {
        if inspectorBaseline == nil {
            inspectorBaseline = CSSPropertyInspectorBaseline(self)
        }
    }

    fileprivate func updateInspectorModificationState() {
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

    package static func == (lhs: CSSStyle, rhs: CSSStyle) -> Bool {
        if let lhsID = lhs.id, let rhsID = rhs.id {
            return lhsID == rhsID
        }
        return lhs === rhs
    }
}

package struct CSSRuleSourceLocation: Equatable, Sendable {
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
        selectorRange: CSSSourceRange?,
        fallbackLine: Int,
        styleSheetSourceLocation: CSSStyleSheetSourceLocation? = nil
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

package struct CSSStyleSheetSourceLocation: Equatable, Sendable {
    package var sourceURL: String?
    package var startLine: Int
    package var startColumn: Int

    package init(sourceURL: String?, startLine: Int, startColumn: Int) {
        self.sourceURL = sourceURL
        self.startLine = startLine
        self.startColumn = startColumn
    }
}

@Observable
package final class CSSRule: Equatable {
    package var id: CSSRuleIdentifier?
    package var selectorList: CSSSelectorList
    package var sourceURL: String?
    package var sourceLine: Int
    package var styleSheetSourceLocation: CSSStyleSheetSourceLocation?
    package var origin: CSSStyleOrigin
    package var style: CSSStyle
    package var groupings: [CSSGrouping]
    package var isImplicitlyNested: Bool

    package init(
        id: CSSRuleIdentifier? = nil,
        selectorList: CSSSelectorList,
        sourceURL: String? = nil,
        sourceLine: Int,
        styleSheetSourceLocation: CSSStyleSheetSourceLocation? = nil,
        origin: CSSStyleOrigin,
        style: CSSStyle,
        groupings: [CSSGrouping] = [],
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

    package var sourceLocation: CSSRuleSourceLocation? {
        CSSRuleSourceLocation(
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

    package init(payload: CSSComputedStylePropertyPayload) {
        name = payload.name
        value = payload.value
    }

    package static func == (lhs: CSSComputedStyleProperty, rhs: CSSComputedStyleProperty) -> Bool {
        lhs.id == rhs.id
    }
}

@Observable
package final class CSSStyleSection: Equatable {
    package var id: CSSStyleSectionIdentifier
    package var kind: CSSStyleSectionKind
    package var title: String
    package var rule: CSSRule?
    package var style: CSSStyle
    package var isEditable: Bool

    package init(
        id: CSSStyleSectionIdentifier,
        kind: CSSStyleSectionKind,
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

    package static func == (lhs: CSSStyleSection, rhs: CSSStyleSection) -> Bool {
        lhs.id == rhs.id
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

    package let identity: CSSNodeStyleIdentity
    package var state: CSSNodeStylesState
    package var sections: [CSSStyleSection]
    package var computedProperties: [CSSComputedStyleProperty]
    @ObservationIgnored private var refreshPhase: RefreshPhase

    package init(
        identity: CSSNodeStyleIdentity,
        state: CSSNodeStylesState = .loading,
        sections: [CSSStyleSection] = [],
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

    fileprivate func isActiveRefresh(_ token: CSSStyleRefreshToken) -> Bool {
        identity == token.identity && refreshPhase.sequence == token.sequence
    }

    fileprivate func clearRefresh(_ token: CSSStyleRefreshToken) {
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

@MainActor
private struct CSSSelectedNodeStylesSelection {
    private(set) var identity: CSSNodeStyleIdentity?
    private var unavailableReason: CSSNodeStylesUnavailableReason

    init() {
        identity = nil
        unavailableReason = .noSelection
    }

    func state(displayedNodeStyles: CSSNodeStyles?) -> CSSNodeStylesState {
        displayedNodeStyles?.state ?? .unavailable(unavailableReason)
    }

    mutating func select(_ identity: CSSNodeStyleIdentity) {
        self.identity = identity
        unavailableReason = .noSelection
    }

    mutating func markUnavailable(_ reason: CSSNodeStylesUnavailableReason) {
        identity = nil
        unavailableReason = reason
    }

    mutating func markSelectedStylesUnavailable(
        identity: CSSNodeStyleIdentity,
        displayedNodeStyles: CSSNodeStyles?,
        unavailableNodeStyles: CSSNodeStyles,
        reason: CSSNodeStylesUnavailableReason
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

    mutating func markRefreshFailed(_ token: CSSStyleRefreshToken) -> Bool {
        guard identity == token.identity else {
            return false
        }
        unavailableReason = .staleNode(token.identity.nodeID)
        return true
    }

    mutating func clearIfRemovingTarget(
        _ targetID: ProtocolTargetIdentifier,
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
@Observable
package final class CSSSession {
    package struct RefreshResults {
        package var matched: CSSMatchedStylesPayload
        package var inline: CSSInlineStylesPayload
        package var computed: [CSSComputedStylePropertyPayload]
    }

    private struct StyleSheetKey: Equatable, Hashable {
        var targetID: ProtocolTargetIdentifier
        var styleSheetID: CSSStyleSheetIdentifier
    }

    private struct SectionMembership: Equatable {
        var id: CSSStyleSectionIdentifier
        var propertyIDs: [PropertyMembership]
    }

    private enum RefreshCommandResult: Sendable {
        case success(ProtocolCommandResult)
        case failure(RefreshCommandFailure)

        var failure: RefreshCommandFailure? {
            guard case let .failure(failure) = self else {
                return nil
            }
            return failure
        }

        func requireSuccess() throws -> ProtocolCommandResult {
            switch self {
            case let .success(result):
                return result
            case let .failure(failure):
                throw failure.error
            }
        }
    }

    private enum RefreshCommandFailure: Error, Sendable {
        case cancellation
        case transport(TransportError)
        case inspector(InspectorSessionError)
        case other(String)

        init(_ error: any Error) {
            if error is CancellationError {
                self = .cancellation
            } else if let error = error as? TransportError {
                self = .transport(error)
            } else if let error = error as? InspectorSessionError {
                self = .inspector(error)
            } else {
                self = .other(String(describing: error))
            }
        }

        var error: any Error {
            switch self {
            case .cancellation:
                CancellationError()
            case let .transport(error):
                error
            case let .inspector(error):
                error
            case let .other(message):
                InspectorSessionError(message)
            }
        }

        var isCancellation: Bool {
            guard case .cancellation = self else {
                return false
            }
            return true
        }
    }

    private enum PropertyMembership: Equatable {
        case identified(CSSPropertyIdentifier)
        case anonymous(index: Int)
    }

    package private(set) var selectedNodeStyles: CSSNodeStyles?
    package var selectedState: CSSNodeStylesState {
        selection.state(displayedNodeStyles: selectedNodeStyles)
    }

    package func nodeStyles(for identity: CSSNodeStyleIdentity) -> CSSNodeStyles? {
        guard let nodeStyles = stylesByNodeID[identity.nodeID],
              nodeStyles.identity == identity else {
            return nil
        }
        return nodeStyles
    }

    private var selection: CSSSelectedNodeStylesSelection
    @ObservationIgnored private var stylesByNodeID: [DOMNodeIdentifier: CSSNodeStyles]
    @ObservationIgnored private var styleSheetHeadersByKey: [StyleSheetKey: CSSStyleSheetHeaderPayload]
    @ObservationIgnored private var nextRefreshSequence: UInt64
    @ObservationIgnored private var commandChannel: ProtocolCommandChannel?
    @ObservationIgnored private let protocolCommands: CSSProtocolCommands

    package init() {
        selectedNodeStyles = nil
        selection = CSSSelectedNodeStylesSelection()
        stylesByNodeID = [:]
        styleSheetHeadersByKey = [:]
        nextRefreshSequence = 0
        commandChannel = nil
        protocolCommands = CSSProtocolCommands()
    }

    package func reset() {
        selectedNodeStyles = nil
        selection = CSSSelectedNodeStylesSelection()
        stylesByNodeID.removeAll()
        styleSheetHeadersByKey.removeAll()
        nextRefreshSequence = 0
    }

    package func bindProtocolChannel(_ commandChannel: ProtocolCommandChannel) {
        self.commandChannel = commandChannel
    }

    package func unbindProtocolChannel() {
        commandChannel = nil
    }

    @discardableResult
    package func perform(_ intent: CSSCommandIntent) async throws -> ProtocolCommandResult {
        let commandChannel = try requireCommandChannel()
        return try await commandChannel.send(try protocolCommands.command(for: intent))
    }

    package func fetchRefreshResults(for identity: CSSNodeStyleIdentity) async throws -> RefreshResults {
        do {
            return try await fetchRefreshResultsWithoutCompatibilityRetry(for: identity)
        } catch {
            guard shouldRetryAfterEnablingCSSAgent(error) else {
                throw error
            }
            try await enableAgentForCompatibility(targetID: identity.targetID)
            return try await fetchRefreshResultsWithoutCompatibilityRetry(for: identity)
        }
    }

    package func setStyleTextResult(from result: ProtocolCommandResult) throws -> CSSStylePayload {
        try protocolCommands.setStyleTextResult(from: result)
    }

    package func selectNodeStyles(identity: CSSNodeStyleIdentity) {
        selection.select(identity)
        let nodeStyles = ensureNodeStyles(for: identity, initialState: .needsRefresh)
        selectCurrentNodeStyles(nodeStyles)
    }

    package func markSelectedNodeUnavailable(_ reason: CSSNodeStylesUnavailableReason) {
        selection.markUnavailable(reason)
        guard selectedNodeStyles != nil || selectedState != .unavailable(reason) else {
            return
        }
        selectedNodeStyles = nil
    }

    package func markSelectedNodeStylesUnavailable(
        identity: CSSNodeStyleIdentity,
        reason: CSSNodeStylesUnavailableReason
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

    package func refreshState(forSelected identity: CSSNodeStyleIdentity) -> CSSNodeStylesState? {
        nodeStyles(for: identity)?.state
    }

    package func beginRefresh(identity: CSSNodeStyleIdentity) -> CSSStyleRefreshToken? {
        guard identity.targetCapabilities.contains(.css) else {
            markSelectedNodeUnavailable(.cssUnavailableForTarget(identity.targetID))
            return nil
        }

        nextRefreshSequence &+= 1
        let nodeStyles = ensureNodeStyles(for: identity)
        nodeStyles.beginRefresh(sequence: nextRefreshSequence)
        selection.select(identity)
        selectCurrentNodeStyles(nodeStyles)
        return CSSStyleRefreshToken(identity: identity, sequence: nextRefreshSequence)
    }

    package func applyRefresh(
        token: CSSStyleRefreshToken,
        matched: CSSMatchedStylesPayload,
        inline: CSSInlineStylesPayload,
        computed: [CSSComputedStylePropertyPayload]
    ) {
        guard let nodeStyles = stylesByNodeID[token.identity.nodeID],
              nodeStyles.isActiveRefresh(token) else {
            return
        }

        Self.updateSections(
            in: nodeStyles,
            with: Self.makeSections(
                identity: token.identity,
                matched: matched,
                inline: inline,
                styleSheetHeadersByKey: styleSheetHeadersByKey
            )
        )
        Self.updateComputedProperties(
            in: nodeStyles,
            with: computed.map(CSSComputedStyleProperty.init(payload:))
        )
        nodeStyles.state = .loaded
        nodeStyles.clearRefresh(token)
        if selection.identity == token.identity {
            selectCurrentNodeStyles(nodeStyles)
        }
    }

    package func registerStyleSheetHeader(_ header: CSSStyleSheetHeaderPayload, targetID: ProtocolTargetIdentifier) {
        styleSheetHeadersByKey[StyleSheetKey(
            targetID: targetID,
            styleSheetID: header.styleSheetID
        )] = header
    }

    package func removeStyleSheetHeader(styleSheetID: CSSStyleSheetIdentifier, targetID: ProtocolTargetIdentifier) {
        styleSheetHeadersByKey.removeValue(forKey: StyleSheetKey(
            targetID: targetID,
            styleSheetID: styleSheetID
        ))
    }

    package func markRefreshFailed(_ token: CSSStyleRefreshToken, message: String) {
        guard let nodeStyles = stylesByNodeID[token.identity.nodeID],
              nodeStyles.isActiveRefresh(token) else {
            return
        }
        nodeStyles.state = .failed(message)
        nodeStyles.clearRefresh(token)
        if selection.markRefreshFailed(token) {
            selectedNodeStyles = nil
        }
    }

    package func cancelRefresh(identity: CSSNodeStyleIdentity) {
        cancelRefresh(identity: identity, sequence: nil)
    }

    package func cancelRefresh(_ token: CSSStyleRefreshToken) {
        cancelRefresh(identity: token.identity, sequence: token.sequence)
    }

    private func cancelRefresh(identity: CSSNodeStyleIdentity, sequence: UInt64?) {
        guard let nodeStyles = nodeStyles(for: identity),
              nodeStyles.cancelRefresh(sequence: sequence) else {
            return
        }
        if selection.identity == identity {
            selectCurrentNodeStyles(nodeStyles)
        }
    }

    package func markNeedsRefresh(targetID: ProtocolTargetIdentifier) {
        markNeedsRefresh(targetID: targetID, including: { _ in true })
    }

    package func markNeedsRefresh(targetID: ProtocolTargetIdentifier, styleSheetID: CSSStyleSheetIdentifier) {
        markNeedsRefresh(targetID: targetID, including: { nodeStyles in
            Self.nodeStyles(nodeStyles, references: styleSheetID)
        })
    }

    private func markNeedsRefresh(
        targetID: ProtocolTargetIdentifier,
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

    private static func nodeStyles(_ nodeStyles: CSSNodeStyles, references styleSheetID: CSSStyleSheetIdentifier) -> Bool {
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

    package func markNeedsRefresh(targetID: ProtocolTargetIdentifier, nodeID: DOMProtocolNodeID) {
        guard let current = stylesByNodeID.values.first(where: {
            $0.identity.targetID == targetID && $0.identity.protocolNodeID == nodeID
        }) else {
            return
        }
        guard !(current.state == .loading && current.isRefreshing) else {
            return
        }
        current.state = .needsRefresh
        current.clearRefresh()
    }

    package func removeStyles(targetID: ProtocolTargetIdentifier) {
        let removedIDs = stylesByNodeID
            .filter { $0.value.identity.targetID == targetID }
            .map(\.key)
        styleSheetHeadersByKey = styleSheetHeadersByKey.filter { $0.key.targetID != targetID }
        guard !removedIDs.isEmpty else {
            return
        }
        for nodeID in removedIDs {
            stylesByNodeID.removeValue(forKey: nodeID)
        }
        if selection.clearIfRemovingTarget(targetID, displayedNodeStyles: selectedNodeStyles) {
            self.selectedNodeStyles = nil
        }
    }

    package func setStyleTextIntent(for propertyID: CSSPropertyIdentifier, enabled: Bool) -> CSSCommandIntent? {
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
              let text = Self.rewrittenStyleText(style: style, propertyIndex: propertyIndex, enabled: enabled) else {
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
        for identity: CSSNodeStyleIdentity,
        initialState: CSSNodeStylesState = .loading
    ) -> CSSNodeStyles {
        if let nodeStyles = nodeStyles(for: identity) {
            return nodeStyles
        }
        let nodeStyles = CSSNodeStyles(identity: identity, state: initialState)
        stylesByNodeID[identity.nodeID] = nodeStyles
        return nodeStyles
    }

    package func applySetStyleTextResult(
        _ style: CSSStylePayload,
        propertyID: CSSPropertyIdentifier,
        targetID: ProtocolTargetIdentifier
    ) {
        for nodeStyles in stylesByNodeID.values where nodeStyles.identity.targetID == targetID {
            for sectionIndex in nodeStyles.sections.indices where nodeStyles.sections[sectionIndex].style.id == propertyID.styleID {
                let section = nodeStyles.sections[sectionIndex]
                if section.style.cssProperties.indices.contains(propertyID.propertyIndex),
                   section.style.cssProperties[propertyID.propertyIndex].id == propertyID {
                    section.style.cssProperties[propertyID.propertyIndex].rememberInspectorBaselineIfNeeded()
                }
                let normalizedStyle = Self.normalizedStyle(
                    style,
                    isEditable: section.isEditable,
                    ruleOrigin: section.rule?.origin
                )
                Self.updateStyle(section.style, from: normalizedStyle)
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
        _ propertyID: CSSPropertyIdentifier,
        in sections: [CSSStyleSection]
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

    private static func makeSections(
        identity: CSSNodeStyleIdentity,
        matched: CSSMatchedStylesPayload,
        inline: CSSInlineStylesPayload,
        styleSheetHeadersByKey: [StyleSheetKey: CSSStyleSheetHeaderPayload]
    ) -> [CSSStyleSection] {
        var sections: [CSSStyleSection] = []
        var ordinal = 0

        if let inlineStyle = inline.inlineStyle {
            appendSection(
                &sections,
                identity: identity,
                ordinal: &ordinal,
                kind: .inlineStyle,
                title: "element.style",
                style: inlineStyle,
                isEditable: inlineStyle.id != nil
            )
        }

        for match in matched.matchedRules.reversed() {
            appendRuleSection(
                &sections,
                identity: identity,
                ordinal: &ordinal,
                match: match,
                kind: .rule,
                styleSheetHeadersByKey: styleSheetHeadersByKey
            )
        }

        if let attributesStyle = inline.attributesStyle {
            appendSection(
                &sections,
                identity: identity,
                ordinal: &ordinal,
                kind: .attributesStyle,
                title: "Attributes",
                style: attributesStyle,
                isEditable: false
            )
        }

        for pseudo in matched.pseudoElements {
            for match in pseudo.matches.reversed() {
                appendRuleSection(
                    &sections,
                    identity: identity,
                    ordinal: &ordinal,
                    match: match,
                    kind: .pseudoElement(pseudo.pseudoID),
                    styleSheetHeadersByKey: styleSheetHeadersByKey
                )
            }
        }

        for (ancestorIndex, inherited) in matched.inherited.enumerated() {
            if let inlineStyle = inherited.inlineStyle {
                appendSection(
                    &sections,
                    identity: identity,
                    ordinal: &ordinal,
                    kind: .inheritedInlineStyle(ancestorIndex: ancestorIndex),
                    title: "Inherited element.style",
                    style: inlineStyle,
                    isEditable: inlineStyle.id != nil
                )
            }
            for match in inherited.matchedRules.reversed() {
                appendRuleSection(
                    &sections,
                    identity: identity,
                    ordinal: &ordinal,
                    match: match,
                    kind: .inheritedRule(ancestorIndex: ancestorIndex),
                    styleSheetHeadersByKey: styleSheetHeadersByKey
                )
            }
        }

        return sections
    }

    private static func updateSections(
        in nodeStyles: CSSNodeStyles,
        with refreshedSections: [CSSStyleSection]
    ) {
        let oldMembership = sectionMembership(in: nodeStyles.sections)
        let existingSectionsByID = Dictionary(uniqueKeysWithValues: nodeStyles.sections.map { ($0.id, $0) })
        let reconciledSections = refreshedSections.map { refreshedSection in
            guard let existingSection = existingSectionsByID[refreshedSection.id] else {
                return refreshedSection
            }
            updateSection(existingSection, from: refreshedSection)
            return existingSection
        }

        if oldMembership != sectionMembership(in: reconciledSections) {
            nodeStyles.sections = reconciledSections
        }
    }

    private static func updateSection(_ section: CSSStyleSection, from refreshedSection: CSSStyleSection) {
        section.kind = refreshedSection.kind
        section.title = refreshedSection.title
        section.isEditable = refreshedSection.isEditable

        if let refreshedRule = refreshedSection.rule {
            if let rule = section.rule {
                updateRule(rule, from: refreshedRule)
                section.style = rule.style
            } else {
                section.rule = refreshedRule
                section.style = refreshedRule.style
            }
        } else {
            section.rule = nil
            updateStyle(section.style, from: refreshedSection.style)
        }
    }

    private static func updateRule(_ rule: CSSRule, from refreshedRule: CSSRule) {
        rule.id = refreshedRule.id
        rule.selectorList = refreshedRule.selectorList
        rule.sourceURL = refreshedRule.sourceURL
        rule.sourceLine = refreshedRule.sourceLine
        rule.styleSheetSourceLocation = refreshedRule.styleSheetSourceLocation
        rule.origin = refreshedRule.origin
        rule.groupings = refreshedRule.groupings
        rule.isImplicitlyNested = refreshedRule.isImplicitlyNested
        updateStyle(rule.style, from: refreshedRule.style)
    }

    private static func updateStyle(_ style: CSSStyle, from refreshedStyle: CSSStyle) {
        style.id = refreshedStyle.id
        style.shorthandEntries = refreshedStyle.shorthandEntries
        style.cssText = refreshedStyle.cssText
        style.range = refreshedStyle.range
        style.width = refreshedStyle.width
        style.height = refreshedStyle.height
        style.isEditable = refreshedStyle.isEditable
        updateProperties(in: style, with: refreshedStyle.cssProperties)
    }

    private static func updateProperties(in style: CSSStyle, with refreshedProperties: [CSSProperty]) {
        let oldMembership = propertyMembership(in: style.cssProperties)
        let existingPropertiesByID = Dictionary(
            uniqueKeysWithValues: style.cssProperties.compactMap { property in
                property.id.map { ($0, property) }
            }
        )
        let reconciledProperties = refreshedProperties.enumerated().map { index, refreshedProperty in
            let existingProperty: CSSProperty?
            if let propertyID = refreshedProperty.id {
                existingProperty = existingPropertiesByID[propertyID]
            } else if style.cssProperties.indices.contains(index),
                      style.cssProperties[index].id == nil {
                existingProperty = style.cssProperties[index]
            } else {
                existingProperty = nil
            }

            guard let existingProperty else {
                return refreshedProperty
            }
            updateProperty(existingProperty, from: refreshedProperty)
            return existingProperty
        }

        if oldMembership != propertyMembership(in: reconciledProperties) {
            style.cssProperties = reconciledProperties
        }
    }

    private static func updateProperty(_ property: CSSProperty, from refreshedProperty: CSSProperty) {
        property.id = refreshedProperty.id
        property.name = refreshedProperty.name
        property.value = refreshedProperty.value
        property.priority = refreshedProperty.priority
        property.text = refreshedProperty.text
        property.parsedOk = refreshedProperty.parsedOk
        property.status = refreshedProperty.status
        property.implicit = refreshedProperty.implicit
        property.range = refreshedProperty.range
        property.isEditable = refreshedProperty.isEditable
        property.updateInspectorModificationState()
    }

    private static func updateComputedProperties(
        in nodeStyles: CSSNodeStyles,
        with refreshedProperties: [CSSComputedStyleProperty]
    ) {
        let existingPropertiesByName = Dictionary(uniqueKeysWithValues: nodeStyles.computedProperties.map { ($0.name, $0) })
        let oldNames = nodeStyles.computedProperties.map(\.name)
        let reconciledProperties = refreshedProperties.map { refreshedProperty in
            guard let existingProperty = existingPropertiesByName[refreshedProperty.name] else {
                return refreshedProperty
            }
            existingProperty.value = refreshedProperty.value
            return existingProperty
        }

        if oldNames != reconciledProperties.map(\.name) {
            nodeStyles.computedProperties = reconciledProperties
        }
    }

    private static func sectionMembership(in sections: [CSSStyleSection]) -> [SectionMembership] {
        sections.map { section in
            SectionMembership(
                id: section.id,
                propertyIDs: propertyMembership(in: section.style.cssProperties)
            )
        }
    }

    private static func propertyMembership(in properties: [CSSProperty]) -> [PropertyMembership] {
        properties.enumerated().map { index, property in
            if let propertyID = property.id {
                return .identified(propertyID)
            }
            return .anonymous(index: index)
        }
    }

    private static func appendRuleSection(
        _ sections: inout [CSSStyleSection],
        identity: CSSNodeStyleIdentity,
        ordinal: inout Int,
        match: CSSRuleMatchPayload,
        kind: CSSStyleSectionKind,
        styleSheetHeadersByKey: [StyleSheetKey: CSSStyleSheetHeaderPayload]
    ) {
        let isEditable = match.rule.origin != .userAgent && match.rule.style.id != nil
        let ruleStyle = normalizedStyle(match.rule.style, isEditable: isEditable, ruleOrigin: match.rule.origin)
        let rule = CSSRule(
            id: match.rule.id,
            selectorList: match.rule.selectorList,
            sourceURL: match.rule.sourceURL,
            sourceLine: match.rule.sourceLine,
            styleSheetSourceLocation: styleSheetSourceLocation(
                for: match.rule,
                targetID: identity.targetID,
                headersByKey: styleSheetHeadersByKey
            ),
            origin: match.rule.origin,
            style: ruleStyle,
            groupings: match.rule.groupings,
            isImplicitlyNested: match.rule.isImplicitlyNested
        )
        sections.append(
            CSSStyleSection(
                id: .init(nodeID: identity.nodeID, kind: kind, ordinal: ordinal),
                kind: kind,
                title: rule.selectorList.text,
                rule: rule,
                style: rule.style,
                isEditable: isEditable
            )
        )
        ordinal += 1
    }

    private static func styleSheetSourceLocation(
        for rule: CSSRulePayload,
        targetID: ProtocolTargetIdentifier,
        headersByKey: [StyleSheetKey: CSSStyleSheetHeaderPayload]
    ) -> CSSStyleSheetSourceLocation? {
        guard let styleSheetID = rule.id?.styleSheetID ?? rule.style.id?.styleSheetID,
              let header = headersByKey[StyleSheetKey(targetID: targetID, styleSheetID: styleSheetID)] else {
            return nil
        }
        return CSSStyleSheetSourceLocation(
            sourceURL: header.sourceURL,
            startLine: header.startLine,
            startColumn: header.startColumn
        )
    }

    private static func appendSection(
        _ sections: inout [CSSStyleSection],
        identity: CSSNodeStyleIdentity,
        ordinal: inout Int,
        kind: CSSStyleSectionKind,
        title: String,
        style: CSSStylePayload,
        isEditable: Bool
    ) {
        sections.append(
            CSSStyleSection(
                id: .init(nodeID: identity.nodeID, kind: kind, ordinal: ordinal),
                kind: kind,
                title: title,
                style: normalizedStyle(style, isEditable: isEditable, ruleOrigin: nil),
                isEditable: isEditable
            )
        )
        ordinal += 1
    }

    private static func normalizedStyle(
        _ style: CSSStylePayload,
        isEditable: Bool,
        ruleOrigin: CSSStyleOrigin?
    ) -> CSSStyle {
        let styleID = style.id
        let effectiveEditable = isEditable && styleID != nil && ruleOrigin != .userAgent
        let normalizedProperties = style.cssProperties.enumerated().map { index, property in
            let propertyID = styleID.map { CSSPropertyIdentifier(styleID: $0, propertyIndex: index) }
            let isEditable = effectiveEditable
                && canSafelyRewriteStyleText(for: style, propertyIndex: index)
                && property.text != nil
                && canTogglePropertyText(property)
            return CSSProperty(payload: property, id: propertyID, isEditable: isEditable)
        }
        return CSSStyle(
            id: style.id,
            cssProperties: normalizedProperties,
            shorthandEntries: style.shorthandEntries,
            cssText: style.cssText,
            range: style.range,
            width: style.width,
            height: style.height,
            isEditable: effectiveEditable
        )
    }

    private static func canSafelyRewriteStyleText(for style: CSSStylePayload, propertyIndex: Int) -> Bool {
        guard style.cssProperties.indices.contains(propertyIndex) else {
            return false
        }
        if let cssText = style.cssText,
           !cssText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let property = style.cssProperties[propertyIndex]
            guard let propertyText = property.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !propertyText.isEmpty else {
                return false
            }
            return authoredDeclarationRange(
                for: propertyText,
                sourceRange: property.range,
                in: cssText,
                previousPropertyTexts: style.cssProperties[..<propertyIndex].map(\.text)
            ) != nil
        }
        return style.cssProperties.allSatisfy { property in
            property.text != nil
                && !property.implicit
                && property.status != .inactive
        }
    }

    private static func rewrittenStyleText(style: CSSStyle, propertyIndex: Int, enabled: Bool) -> String? {
        guard style.cssProperties.indices.contains(propertyIndex) else {
            return nil
        }
        let property = style.cssProperties[propertyIndex]
        guard property.isEditable,
              let toggledText = toggledPropertyText(property, enabled: enabled) else {
            return nil
        }
        if let cssText = style.cssText,
           !cssText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return rewriteAuthoredStyleText(
                cssText,
                replacing: property,
                in: style,
                propertyIndex: propertyIndex,
                with: toggledText
            )
        }

        var texts: [String] = []
        for index in style.cssProperties.indices {
            if index == propertyIndex {
                texts.append(toggledText)
                continue
            }
            let property = style.cssProperties[index]
            guard let text = property.text,
                  !property.implicit,
                  property.status != .inactive else {
                return nil
            }
            texts.append(text)
        }
        return texts.joined(separator: "\n")
    }

    private static func rewriteAuthoredStyleText(
        _ cssText: String,
        replacing property: CSSProperty,
        in style: CSSStyle,
        propertyIndex: Int,
        with toggledText: String
    ) -> String? {
        guard let propertyText = property.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !propertyText.isEmpty else {
            return nil
        }
        let nsText = cssText as NSString
        if let range = authoredDeclarationRange(
            for: propertyText,
            sourceRange: property.range,
            in: cssText,
            previousPropertyTexts: style.cssProperties[..<propertyIndex].map(\.text)
        ) {
            return nsText.replacingCharacters(in: range, with: toggledText)
        }

        return nil
    }

    private static func authoredDeclarationRange(
        for propertyText: String,
        sourceRange: CSSSourceRange?,
        in cssText: String,
        previousPropertyTexts: [String?]
    ) -> NSRange? {
        let nsText = cssText as NSString
        if let range = sourceRange.flatMap({ nsRange(in: cssText, sourceRange: $0) }),
           NSMaxRange(range) <= nsText.length,
           nsText.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines) == propertyText {
            return range
        }

        let ranges = declarationRanges(of: propertyText, in: cssText)
        if ranges.count == 1 {
            return ranges[0]
        }
        let occurrence = previousPropertyTexts.filter { previousText in
            previousText?.trimmingCharacters(in: .whitespacesAndNewlines) == propertyText
        }.count
        guard ranges.indices.contains(occurrence) else {
            return nil
        }
        return ranges[occurrence]
    }

    private static func nsRange(in text: String, sourceRange: CSSSourceRange) -> NSRange? {
        guard sourceRange.startLine >= 0,
              sourceRange.endLine >= sourceRange.startLine,
              sourceRange.startColumn >= 0,
              sourceRange.endColumn >= 0 else {
            return nil
        }

        let lineStartOffsets = lineStartUTF16Offsets(in: text)
        guard sourceRange.startLine < lineStartOffsets.count,
              sourceRange.endLine < lineStartOffsets.count else {
            return nil
        }
        let startOffset = lineStartOffsets[sourceRange.startLine] + sourceRange.startColumn
        let endOffset = lineStartOffsets[sourceRange.endLine] + sourceRange.endColumn
        guard endOffset >= startOffset,
              endOffset <= (text as NSString).length else {
            return nil
        }
        return NSRange(location: startOffset, length: endOffset - startOffset)
    }

    private static func lineStartUTF16Offsets(in text: String) -> [Int] {
        var offsets = [0]
        var offset = 0
        for scalar in text.unicodeScalars {
            offset += scalar.utf16.count
            if scalar == "\n" {
                offsets.append(offset)
            }
        }
        return offsets
    }

    private static func declarationRanges(of needle: String, in haystack: String) -> [NSRange] {
        let nsHaystack = haystack as NSString
        var searchRange = NSRange(location: 0, length: nsHaystack.length)
        var ranges: [NSRange] = []
        while searchRange.length > 0 {
            let range = nsHaystack.range(of: needle, options: [], range: searchRange)
            guard range.location != NSNotFound else {
                break
            }
            if isDeclarationRange(range, propertyText: needle, in: nsHaystack) {
                ranges.append(range)
            }
            let nextLocation = range.location + max(range.length, 1)
            searchRange = NSRange(location: nextLocation, length: nsHaystack.length - nextLocation)
        }
        return ranges
    }

    private static func isDeclarationRange(_ range: NSRange, propertyText: String, in text: NSString) -> Bool {
        isNormalCSSPosition(range.location, in: text)
            && hasDeclarationBoundary(before: range.location, in: text)
            && hasDeclarationEndBoundary(after: NSMaxRange(range), propertyText: propertyText, in: text)
    }

    private static func isNormalCSSPosition(_ location: Int, in text: NSString) -> Bool {
        var index = 0
        var quotedString: unichar?
        var isEscaped = false
        var isComment = false
        while index < location {
            let character = text.character(at: index)
            let nextCharacter = index + 1 < text.length ? text.character(at: index + 1) : 0

            if isComment {
                if character == asterisk && nextCharacter == slash {
                    isComment = false
                    index += 2
                    continue
                }
                index += 1
                continue
            }

            if let quote = quotedString {
                if isEscaped {
                    isEscaped = false
                } else if character == backslash {
                    isEscaped = true
                } else if character == quote {
                    quotedString = nil
                }
                index += 1
                continue
            }

            if character == slash && nextCharacter == asterisk {
                isComment = true
                index += 2
                continue
            }
            if character == doubleQuote || character == singleQuote {
                quotedString = character
            }
            index += 1
        }
        return !isComment && quotedString == nil
    }

    private static func hasDeclarationBoundary(before location: Int, in text: NSString) -> Bool {
        var index = location - 1
        while index >= 0 {
            let character = text.character(at: index)
            if character == slash,
               index > 0,
               text.character(at: index - 1) == asterisk {
                guard let commentStart = cssCommentStart(endingAt: index, in: text) else {
                    return false
                }
                index = commentStart - 1
                continue
            }
            if !isCSSWhitespace(character) {
                return character == semicolon || character == leftBrace
            }
            index -= 1
        }
        return true
    }

    private static func hasDeclarationBoundary(after location: Int, in text: NSString) -> Bool {
        var index = location
        while index < text.length {
            let character = text.character(at: index)
            let nextCharacter = index + 1 < text.length ? text.character(at: index + 1) : 0
            if character == slash,
               nextCharacter == asterisk {
                guard let commentEnd = cssCommentEnd(startingAt: index, in: text) else {
                    return false
                }
                index = commentEnd + 1
                continue
            }
            if !isCSSWhitespace(character) {
                return character == semicolon || character == rightBrace
            }
            index += 1
        }
        return true
    }

    private static func hasDeclarationEndBoundary(after location: Int, propertyText: String, in text: NSString) -> Bool {
        let trimmedPropertyText = propertyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPropertyText.hasSuffix(";")
            || trimmedPropertyText.hasSuffix("*/") {
            return true
        }
        return hasDeclarationBoundary(after: location, in: text)
    }

    private static func cssCommentStart(endingAt commentEndSlashIndex: Int, in text: NSString) -> Int? {
        var index = 0
        var quotedString: unichar?
        var isEscaped = false
        var commentStart: Int?
        while index <= commentEndSlashIndex {
            let character = text.character(at: index)
            let nextCharacter = index + 1 < text.length ? text.character(at: index + 1) : 0

            if let start = commentStart {
                if character == asterisk,
                   nextCharacter == slash {
                    if index + 1 == commentEndSlashIndex {
                        return start
                    }
                    commentStart = nil
                    index += 2
                    continue
                }
                index += 1
                continue
            }

            if let quote = quotedString {
                if isEscaped {
                    isEscaped = false
                } else if character == backslash {
                    isEscaped = true
                } else if character == quote {
                    quotedString = nil
                }
                index += 1
                continue
            }

            if character == slash,
               nextCharacter == asterisk {
                commentStart = index
                index += 2
                continue
            }
            if character == doubleQuote || character == singleQuote {
                quotedString = character
            }
            index += 1
        }
        return nil
    }

    private static func cssCommentEnd(startingAt commentStartSlashIndex: Int, in text: NSString) -> Int? {
        var index = commentStartSlashIndex + 2
        while index < text.length {
            if text.character(at: index - 1) == asterisk,
               text.character(at: index) == slash {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func isCSSWhitespace(_ character: unichar) -> Bool {
        character == space
            || character == tab
            || character == newline
            || character == carriageReturn
            || character == formFeed
    }

    private static let tab = unichar(9)
    private static let newline = unichar(10)
    private static let formFeed = unichar(12)
    private static let carriageReturn = unichar(13)
    private static let space = unichar(32)
    private static let doubleQuote = unichar(34)
    private static let singleQuote = unichar(39)
    private static let asterisk = unichar(42)
    private static let semicolon = unichar(59)
    private static let leftBrace = unichar(123)
    private static let backslash = unichar(92)
    private static let rightBrace = unichar(125)
    private static let slash = unichar(47)

    private static func canTogglePropertyText(_ property: CSSProperty) -> Bool {
        guard property.status != .inactive else {
            return false
        }
        return toggledPropertyText(property, enabled: !property.isEnabled) != nil
    }

    private static func canTogglePropertyText(_ property: CSSPropertyPayload) -> Bool {
        guard property.status != .inactive else {
            return false
        }
        return toggledPropertyText(property, enabled: property.status == .disabled) != nil
    }

    private static func toggledPropertyText(_ property: CSSProperty, enabled: Bool) -> String? {
        guard let text = property.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              property.isEnabled != enabled else {
            return nil
        }

        if enabled {
            guard text.hasPrefix("/*"),
                  text.hasSuffix("*/") else {
                return nil
            }
            let inner = String(text.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            return inner.isEmpty ? nil : inner
        }

        guard !text.contains("/*"),
              !text.contains("*/") else {
            return nil
        }
        return "/* \(text) */"
    }

    private static func toggledPropertyText(_ property: CSSPropertyPayload, enabled: Bool) -> String? {
        guard let text = property.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              (property.status != .disabled) != enabled else {
            return nil
        }

        if enabled {
            guard text.hasPrefix("/*"),
                  text.hasSuffix("*/") else {
                return nil
            }
            let inner = String(text.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            return inner.isEmpty ? nil : inner
        }

        guard !text.contains("/*"),
              !text.contains("*/") else {
            return nil
        }
        return "/* \(text) */"
    }

    private func fetchRefreshResultsWithoutCompatibilityRetry(for identity: CSSNodeStyleIdentity) async throws -> RefreshResults {
        async let matched = performRefreshCommand(.getMatchedStyles(identity: identity))
        async let inline = performRefreshCommand(.getInlineStyles(identity: identity))
        async let computed = performRefreshCommand(.getComputedStyle(identity: identity))
        let results = await (matched, inline, computed)
        let failures = [results.0, results.1, results.2].compactMap(\.failure)
        if failures.contains(where: \.isCancellation) {
            throw CancellationError()
        }
        if let retryFailure = failures.first(where: { shouldRetryAfterEnablingCSSAgent($0.error) }) {
            throw retryFailure.error
        }
        if let failure = failures.first {
            throw failure.error
        }
        let matchedResult = try results.0.requireSuccess()
        let inlineResult = try results.1.requireSuccess()
        let computedResult = try results.2.requireSuccess()
        return RefreshResults(
            matched: try protocolCommands.matchedStyles(from: matchedResult),
            inline: try protocolCommands.inlineStyles(from: inlineResult),
            computed: try protocolCommands.computedStyles(from: computedResult)
        )
    }

    private func performRefreshCommand(_ intent: CSSCommandIntent) async -> RefreshCommandResult {
        do {
            return .success(try await perform(intent))
        } catch {
            return .failure(RefreshCommandFailure(error))
        }
    }

    private func enableAgentForCompatibility(targetID: ProtocolTargetIdentifier) async throws {
        let commandChannel = try requireCommandChannel()
        guard commandChannel.cssAgentShouldBeEnabledForCompatibility(targetID: targetID) else {
            return
        }

        // Do not enable the WebKit CSS agent proactively. On current simulator
        // WebContent, CSS.enable can crash while synchronizing stylesheet
        // headers during page load, while the read commands work without it.
        _ = try await perform(.enable(targetID: targetID))
        commandChannel.markEnabled(.css, targetID: targetID)
    }

    private func shouldRetryAfterEnablingCSSAgent(_ error: any Error) -> Bool {
        guard case let TransportError.remoteError(method, _, message) = error,
              method.hasPrefix("CSS.") else {
            return false
        }

        let normalizedMessage = message.lowercased()
        return normalizedMessage.contains("enable")
            || normalizedMessage.contains("enabled")
    }

    private func requireCommandChannel() throws -> ProtocolCommandChannel {
        guard let commandChannel else {
            throw InspectorSessionError("Inspector session is not attached.")
        }
        try commandChannel.requireAttached()
        return commandChannel
    }
}
