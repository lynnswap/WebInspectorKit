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
    public let rule: CSS.Rule?
    public let style: CSS.Style
    public let isEditable: Bool
}

enum CSSStyleSectionBuilder {
    static func makeSections(matched: CSS.MatchedStyles, inline: CSS.InlineStyles?) -> [CSSStyleSection] {
        var sections: [CSSStyleSection] = []
        var ordinal = 0

        if let inlineStyle = inline?.inlineStyle {
            appendSection(
                &sections,
                ordinal: &ordinal,
                kind: .inlineStyle,
                title: "element.style",
                style: inlineStyle,
                isEditable: inlineStyle.isEditable
            )
        }

        for rule in matched.matchedRules.reversed() {
            appendRuleSection(
                &sections,
                ordinal: &ordinal,
                rule: rule,
                kind: .rule
            )
        }

        if let attributesStyle = inline?.attributesStyle {
            appendSection(
                &sections,
                ordinal: &ordinal,
                kind: .attributesStyle,
                title: "Attributes",
                style: attributesStyle,
                isEditable: false
            )
        }

        for pseudo in matched.pseudoElements {
            for rule in pseudo.matchedRules.reversed() {
                appendRuleSection(
                    &sections,
                    ordinal: &ordinal,
                    rule: rule,
                    kind: .pseudoElement(pseudo.pseudoID)
                )
            }
        }

        for (ancestorIndex, inherited) in matched.inherited.enumerated() {
            if let inlineStyle = inherited.inlineStyle {
                appendSection(
                    &sections,
                    ordinal: &ordinal,
                    kind: .inheritedInlineStyle(ancestorIndex: ancestorIndex),
                    title: "Inherited element.style",
                    style: inlineStyle,
                    isEditable: inlineStyle.isEditable
                )
            }
            for rule in inherited.matchedRules.reversed() {
                appendRuleSection(
                    &sections,
                    ordinal: &ordinal,
                    rule: rule,
                    kind: .inheritedRule(ancestorIndex: ancestorIndex)
                )
            }
        }

        return sections
    }

    static func normalizedStyle(
        _ style: CSS.Style,
        isEditable: Bool,
        ruleOrigin: CSS.Origin?
    ) -> CSS.Style {
        let effectiveEditable = isEditable && style.isEditable && ruleOrigin != .userAgent
        var rewriteContext = effectiveEditable ? CSSStyleTextRewriter.RewriteContext(style: style) : nil
        let normalizedProperties = style.properties.enumerated().map { index, property in
            let isEditable = effectiveEditable
                && (rewriteContext?.canSafelyRewriteStyleText(propertyIndex: index) == true)
                && property.text != nil
                && CSSStyleTextRewriter.canTogglePropertyText(property)
            return CSS.Property(
                id: property.id,
                name: property.name,
                value: property.value,
                priority: property.priority,
                text: property.text,
                parsedOk: property.parsedOk,
                status: property.status,
                implicit: property.implicit,
                range: property.range,
                isEditable: isEditable,
                isModifiedByInspector: property.isModifiedByInspector
            )
        }
        var normalized = style
        normalized.properties = normalizedProperties
        normalized.isEditable = effectiveEditable
        return normalized
    }

    private static func appendRuleSection(
        _ sections: inout [CSSStyleSection],
        ordinal: inout Int,
        rule: CSS.Rule,
        kind: CSSStyleSection.Kind
    ) {
        let isEditable = rule.origin != .userAgent && rule.style.isEditable
        var rule = rule
        rule.style = normalizedStyle(rule.style, isEditable: isEditable, ruleOrigin: rule.origin)
        sections.append(
            CSSStyleSection(
                id: .init(kind: kind, ordinal: ordinal),
                kind: kind,
                title: rule.selectorList.text,
                rule: rule,
                style: rule.style,
                isEditable: isEditable
            )
        )
        ordinal += 1
    }

    private static func appendSection(
        _ sections: inout [CSSStyleSection],
        ordinal: inout Int,
        kind: CSSStyleSection.Kind,
        title: String,
        style: CSS.Style,
        isEditable: Bool
    ) {
        sections.append(
            CSSStyleSection(
                id: .init(kind: kind, ordinal: ordinal),
                kind: kind,
                title: title,
                rule: nil,
                style: normalizedStyle(style, isEditable: isEditable, ruleOrigin: nil),
                isEditable: isEditable
            )
        )
        ordinal += 1
    }
}

extension CSS.Origin {
    static let userAgent = CSS.Origin(rawValue: "user-agent")
}
