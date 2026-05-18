import Foundation
import Observation

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

@Observable
package final class CSSRule: Equatable {
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

    package static func == (lhs: CSSStyleSection, rhs: CSSStyleSection) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
@Observable
package final class CSSNodeStyles {
    package let identity: CSSNodeStyleIdentity
    package var state: CSSNodeStylesState
    package var sections: [CSSStyleSection]
    package var computedProperties: [CSSComputedStyleProperty]

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
    }
}

@MainActor
@Observable
package final class CSSSession {
    package private(set) var selectedNodeStyles: CSSNodeStyles?
    package private(set) var selectedState: CSSNodeStylesState

    @ObservationIgnored private var stylesByNodeID: [DOMNodeIdentifier: CSSNodeStyles]
    @ObservationIgnored private var activeRefreshSequenceByNodeID: [DOMNodeIdentifier: UInt64]
    @ObservationIgnored private var nextRefreshSequence: UInt64

    package init() {
        selectedNodeStyles = nil
        selectedState = .unavailable(.noSelection)
        stylesByNodeID = [:]
        activeRefreshSequenceByNodeID = [:]
        nextRefreshSequence = 0
    }

    package func reset() {
        selectedNodeStyles = nil
        selectedState = .unavailable(.noSelection)
        stylesByNodeID.removeAll()
        activeRefreshSequenceByNodeID.removeAll()
        nextRefreshSequence = 0
    }

    package func markSelectedNodeUnavailable(_ reason: CSSNodeStylesUnavailableReason) {
        selectedNodeStyles = nil
        selectedState = .unavailable(reason)
    }

    package func beginRefresh(identity: CSSNodeStyleIdentity) -> CSSStyleRefreshToken? {
        guard identity.targetCapabilities.contains(.css) else {
            markSelectedNodeUnavailable(.cssUnavailableForTarget(identity.targetID))
            return nil
        }

        nextRefreshSequence &+= 1
        let nodeStyles = stylesByNodeID[identity.nodeID] ?? CSSNodeStyles(identity: identity)
        stylesByNodeID[identity.nodeID] = nodeStyles
        nodeStyles.state = .loading
        selectedNodeStyles = nodeStyles
        selectedState = .loading
        activeRefreshSequenceByNodeID[identity.nodeID] = nextRefreshSequence
        return CSSStyleRefreshToken(identity: identity, sequence: nextRefreshSequence)
    }

    package func applyRefresh(
        token: CSSStyleRefreshToken,
        matched: CSSMatchedStylesPayload,
        inline: CSSInlineStylesPayload,
        computed: [CSSComputedStylePropertyPayload]
    ) {
        guard activeRefreshSequenceByNodeID[token.identity.nodeID] == token.sequence,
              selectedNodeStyles?.identity == token.identity,
              let nodeStyles = stylesByNodeID[token.identity.nodeID] else {
            return
        }

        nodeStyles.sections = Self.makeSections(
            identity: token.identity,
            matched: matched,
            inline: inline
        )
        nodeStyles.computedProperties = computed.map(CSSComputedStyleProperty.init(payload:))
        nodeStyles.state = .loaded
        selectedState = .loaded
        activeRefreshSequenceByNodeID.removeValue(forKey: token.identity.nodeID)
    }

    package func markRefreshFailed(_ token: CSSStyleRefreshToken, message: String) {
        guard activeRefreshSequenceByNodeID[token.identity.nodeID] == token.sequence,
              selectedNodeStyles?.identity == token.identity,
              let nodeStyles = stylesByNodeID[token.identity.nodeID] else {
            return
        }
        nodeStyles.state = .failed(message)
        selectedState = .failed(message)
        activeRefreshSequenceByNodeID.removeValue(forKey: token.identity.nodeID)
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
            guard !(nodeStyles.state == .loading && activeRefreshSequenceByNodeID[nodeStyles.identity.nodeID] != nil) else {
                continue
            }
            nodeStyles.state = .needsRefresh
            activeRefreshSequenceByNodeID.removeValue(forKey: nodeStyles.identity.nodeID)
            if selectedNodeStyles === nodeStyles {
                selectedState = .needsRefresh
            }
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
        guard !(current.state == .loading && activeRefreshSequenceByNodeID[current.identity.nodeID] != nil) else {
            return
        }
        current.state = .needsRefresh
        activeRefreshSequenceByNodeID.removeValue(forKey: current.identity.nodeID)
        if selectedNodeStyles === current {
            selectedState = .needsRefresh
        }
    }

    package func removeStyles(targetID: ProtocolTargetIdentifier) {
        let removedIDs = stylesByNodeID
            .filter { $0.value.identity.targetID == targetID }
            .map(\.key)
        guard !removedIDs.isEmpty else {
            return
        }
        for nodeID in removedIDs {
            stylesByNodeID.removeValue(forKey: nodeID)
            activeRefreshSequenceByNodeID.removeValue(forKey: nodeID)
        }
        if let removedSelectedNodeID = selectedNodeStyles?.identity.nodeID,
           selectedNodeStyles?.identity.targetID == targetID {
            selectedNodeStyles = nil
            selectedState = .unavailable(.staleNode(removedSelectedNodeID))
        }
    }

    package func setStyleTextIntent(for propertyID: CSSPropertyIdentifier, enabled: Bool) -> CSSCommandIntent? {
        guard let nodeStyles = selectedNodeStyles,
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

    package func applySetStyleTextResult(
        _ style: CSSStylePayload,
        styleID: CSSStyleIdentifier,
        targetID: ProtocolTargetIdentifier
    ) {
        for nodeStyles in stylesByNodeID.values where nodeStyles.identity.targetID == targetID {
            for sectionIndex in nodeStyles.sections.indices where nodeStyles.sections[sectionIndex].style.id == styleID {
                let section = nodeStyles.sections[sectionIndex]
                let normalizedStyle = Self.normalizedStyle(
                    style,
                    isEditable: section.isEditable,
                    ruleOrigin: section.rule?.origin
                )
                section.style = normalizedStyle
                if let rule = section.rule {
                    rule.style = normalizedStyle
                }
                nodeStyles.state = .needsRefresh
                if selectedNodeStyles === nodeStyles {
                    selectedState = .needsRefresh
                }
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
        inline: CSSInlineStylesPayload
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
            appendRuleSection(&sections, identity: identity, ordinal: &ordinal, match: match, kind: .rule)
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
                    kind: .pseudoElement(pseudo.pseudoID)
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
                    kind: .inheritedRule(ancestorIndex: ancestorIndex)
                )
            }
        }

        return sections
    }

    private static func appendRuleSection(
        _ sections: inout [CSSStyleSection],
        identity: CSSNodeStyleIdentity,
        ordinal: inout Int,
        match: CSSRuleMatchPayload,
        kind: CSSStyleSectionKind
    ) {
        let isEditable = match.rule.origin != .userAgent && match.rule.style.id != nil
        let ruleStyle = normalizedStyle(match.rule.style, isEditable: isEditable, ruleOrigin: match.rule.origin)
        let rule = CSSRule(
            id: match.rule.id,
            selectorList: match.rule.selectorList,
            sourceURL: match.rule.sourceURL,
            sourceLine: match.rule.sourceLine,
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
                subtitle: rule.sourceURL,
                rule: rule,
                style: rule.style,
                isEditable: isEditable
            )
        )
        ordinal += 1
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
        let canSafelyRewriteStyleText = effectiveEditable && style.cssProperties.allSatisfy { $0.text != nil }
        let normalizedProperties = style.cssProperties.enumerated().map { index, property in
            let propertyID = styleID.map { CSSPropertyIdentifier(styleID: $0, propertyIndex: index) }
            let isEditable = canSafelyRewriteStyleText
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

    private static func rewrittenStyleText(style: CSSStyle, propertyIndex: Int, enabled: Bool) -> String? {
        guard style.cssProperties.indices.contains(propertyIndex) else {
            return nil
        }
        let property = style.cssProperties[propertyIndex]
        guard property.isEditable,
              style.cssProperties.allSatisfy({ $0.text != nil }),
              let toggledText = toggledPropertyText(property, enabled: enabled) else {
            return nil
        }

        var texts: [String] = []
        for index in style.cssProperties.indices {
            if index == propertyIndex {
                texts.append(toggledText)
                continue
            }
            guard let text = style.cssProperties[index].text else {
                return nil
            }
            texts.append(text)
        }
        return texts.joined(separator: "\n")
    }

    private static func canTogglePropertyText(_ property: CSSProperty) -> Bool {
        toggledPropertyText(property, enabled: !property.isEnabled) != nil
    }

    private static func canTogglePropertyText(_ property: CSSPropertyPayload) -> Bool {
        toggledPropertyText(property, enabled: property.status == .disabled) != nil
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

}
