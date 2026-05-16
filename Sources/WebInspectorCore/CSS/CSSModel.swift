import Foundation
import Observation

@MainActor
@Observable
package final class CSSNodeStyles {
    package let identity: CSSNodeStyleIdentity
    package var state: CSSNodeStylesState
    package var sections: [CSSStyleSection]
    package var computedProperties: [CSSComputedStyleProperty]
    package var revision: UInt64

    package init(
        identity: CSSNodeStyleIdentity,
        state: CSSNodeStylesState = .loading,
        sections: [CSSStyleSection] = [],
        computedProperties: [CSSComputedStyleProperty] = [],
        revision: UInt64 = 0
    ) {
        self.identity = identity
        self.state = state
        self.sections = sections
        self.computedProperties = computedProperties
        self.revision = revision
    }
}

@MainActor
@Observable
package final class CSSSession {
    package private(set) var selectedNodeStyles: CSSNodeStyles?
    package private(set) var selectedState: CSSNodeStylesState
    package private(set) var revision: UInt64

    @ObservationIgnored private var stylesByNodeID: [DOMNodeIdentifier: CSSNodeStyles]
    @ObservationIgnored private var activeRefreshRevisionByNodeID: [DOMNodeIdentifier: UInt64]
    @ObservationIgnored private var nextRevision: UInt64

    package init() {
        selectedNodeStyles = nil
        selectedState = .unavailable(.noSelection)
        revision = 0
        stylesByNodeID = [:]
        activeRefreshRevisionByNodeID = [:]
        nextRevision = 0
    }

    package func reset() {
        selectedNodeStyles = nil
        selectedState = .unavailable(.noSelection)
        revision = 0
        stylesByNodeID.removeAll()
        activeRefreshRevisionByNodeID.removeAll()
        nextRevision = 0
    }

    package func markSelectedNodeUnavailable(_ reason: CSSNodeStylesUnavailableReason) {
        selectedNodeStyles = nil
        selectedState = .unavailable(reason)
        revision &+= 1
    }

    package func beginRefresh(identity: CSSNodeStyleIdentity) -> CSSStyleRefreshToken? {
        guard identity.targetCapabilities.contains(.css) else {
            markSelectedNodeUnavailable(.cssUnavailableForTarget(identity.targetID))
            return nil
        }

        nextRevision &+= 1
        let nodeStyles = stylesByNodeID[identity.nodeID] ?? CSSNodeStyles(identity: identity)
        stylesByNodeID[identity.nodeID] = nodeStyles
        nodeStyles.state = .loading
        nodeStyles.revision = nextRevision
        selectedNodeStyles = nodeStyles
        selectedState = .loading
        revision &+= 1
        activeRefreshRevisionByNodeID[identity.nodeID] = nextRevision
        return CSSStyleRefreshToken(identity: identity, revision: nextRevision)
    }

    package func applyRefresh(
        token: CSSStyleRefreshToken,
        matched: CSSMatchedStylesPayload,
        inline: CSSInlineStylesPayload,
        computed: [CSSComputedStyleProperty]
    ) {
        guard activeRefreshRevisionByNodeID[token.identity.nodeID] == token.revision,
              selectedNodeStyles?.identity == token.identity,
              let nodeStyles = stylesByNodeID[token.identity.nodeID] else {
            return
        }

        nodeStyles.sections = Self.makeSections(
            identity: token.identity,
            matched: matched,
            inline: inline
        )
        nodeStyles.computedProperties = computed
        nodeStyles.state = .loaded
        nodeStyles.revision = token.revision
        selectedState = .loaded
        activeRefreshRevisionByNodeID.removeValue(forKey: token.identity.nodeID)
        revision &+= 1
    }

    package func markRefreshFailed(_ token: CSSStyleRefreshToken, message: String) {
        guard activeRefreshRevisionByNodeID[token.identity.nodeID] == token.revision,
              selectedNodeStyles?.identity == token.identity,
              let nodeStyles = stylesByNodeID[token.identity.nodeID] else {
            return
        }
        nodeStyles.state = .failed(message)
        selectedState = .failed(message)
        activeRefreshRevisionByNodeID.removeValue(forKey: token.identity.nodeID)
        revision &+= 1
    }

    package func markNeedsRefresh(targetID: ProtocolTargetIdentifier) {
        var changed = false
        for nodeStyles in stylesByNodeID.values where nodeStyles.identity.targetID == targetID {
            guard !(nodeStyles.state == .loading && activeRefreshRevisionByNodeID[nodeStyles.identity.nodeID] != nil) else {
                continue
            }
            nodeStyles.state = .needsRefresh
            nodeStyles.revision &+= 1
            activeRefreshRevisionByNodeID.removeValue(forKey: nodeStyles.identity.nodeID)
            changed = true
            if selectedNodeStyles === nodeStyles {
                selectedState = .needsRefresh
            }
        }
        if changed {
            revision &+= 1
        }
    }

    package func markNeedsRefresh(targetID: ProtocolTargetIdentifier, nodeID: DOMProtocolNodeID) {
        guard let current = stylesByNodeID.values.first(where: {
            $0.identity.targetID == targetID && $0.identity.protocolNodeID == nodeID
        }) else {
            return
        }
        guard !(current.state == .loading && activeRefreshRevisionByNodeID[current.identity.nodeID] != nil) else {
            return
        }
        current.state = .needsRefresh
        current.revision &+= 1
        activeRefreshRevisionByNodeID.removeValue(forKey: current.identity.nodeID)
        if selectedNodeStyles === current {
            selectedState = .needsRefresh
        }
        revision &+= 1
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
            activeRefreshRevisionByNodeID.removeValue(forKey: nodeID)
        }
        if let removedSelectedNodeID = selectedNodeStyles?.identity.nodeID,
           selectedNodeStyles?.identity.targetID == targetID {
            selectedNodeStyles = nil
            selectedState = .unavailable(.staleNode(removedSelectedNodeID))
        }
        revision &+= 1
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
        _ style: CSSStyle,
        styleID: CSSStyleIdentifier,
        targetID: ProtocolTargetIdentifier
    ) {
        var changed = false
        for nodeStyles in stylesByNodeID.values where nodeStyles.identity.targetID == targetID {
            for sectionIndex in nodeStyles.sections.indices where nodeStyles.sections[sectionIndex].style.id == styleID {
                var section = nodeStyles.sections[sectionIndex]
                let normalizedStyle = Self.normalizedStyle(
                    style,
                    isEditable: section.isEditable,
                    ruleOrigin: section.rule?.origin
                )
                section.style = normalizedStyle
                if var rule = section.rule {
                    rule.style = normalizedStyle
                    section.rule = rule
                }
                nodeStyles.sections[sectionIndex] = section
                nodeStyles.state = .needsRefresh
                changed = true
                if selectedNodeStyles === nodeStyles {
                    selectedState = .needsRefresh
                }
            }
        }
        if changed {
            revision &+= 1
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
        match: CSSRuleMatch,
        kind: CSSStyleSectionKind
    ) {
        let isEditable = match.rule.origin != .userAgent && match.rule.style.id != nil
        var rule = match.rule
        rule.style = normalizedStyle(rule.style, isEditable: isEditable, ruleOrigin: rule.origin)
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
        style: CSSStyle,
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
        _ style: CSSStyle,
        isEditable: Bool,
        ruleOrigin: CSSStyleOrigin?
    ) -> CSSStyle {
        let styleID = style.id
        let effectiveEditable = isEditable && styleID != nil && ruleOrigin != .userAgent
        let canSafelyRewriteStyleText = effectiveEditable && style.cssProperties.allSatisfy { $0.text != nil }
        var normalized = style
        normalized.isEditable = effectiveEditable
        normalized.cssProperties = style.cssProperties.enumerated().map { index, property in
            var normalizedProperty = property
            if let styleID {
                normalizedProperty.id = CSSPropertyIdentifier(styleID: styleID, propertyIndex: index)
            } else {
                normalizedProperty.id = nil
            }
            normalizedProperty.isEditable = canSafelyRewriteStyleText
                && normalizedProperty.text != nil
                && canTogglePropertyText(normalizedProperty)
            return normalizedProperty
        }
        return normalized
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

}
