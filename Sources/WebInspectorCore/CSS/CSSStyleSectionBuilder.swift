import Foundation
import WebInspectorTransport

@MainActor
enum CSSStyleSectionBuilder {
    static func makeSections(
        identity: CSSNodeStyleIdentity,
        matched: CSSMatchedStylesPayload,
        inline: CSSInlineStylesPayload,
        styleSheetHeaders: CSSStyleSheetHeaderRegistry
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
                styleSheetHeaders: styleSheetHeaders
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
                    styleSheetHeaders: styleSheetHeaders
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
                    styleSheetHeaders: styleSheetHeaders
                )
            }
        }

        return sections
    }

    static func normalizedStyle(
        _ style: CSSStylePayload,
        isEditable: Bool,
        ruleOrigin: CSSStyleOrigin?
    ) -> CSSStyle {
        let styleID = style.id
        let effectiveEditable = isEditable && styleID != nil && ruleOrigin != .userAgent
        let normalizedProperties = style.cssProperties.enumerated().map { index, property in
            let propertyID = styleID.map { CSSPropertyIdentifier(styleID: $0, propertyIndex: index) }
            let isEditable = effectiveEditable
                && CSSStyleTextRewriter.canSafelyRewriteStyleText(for: style, propertyIndex: index)
                && property.text != nil
                && CSSStyleTextRewriter.canTogglePropertyText(property)
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

    private static func appendRuleSection(
        _ sections: inout [CSSStyleSection],
        identity: CSSNodeStyleIdentity,
        ordinal: inout Int,
        match: CSSRuleMatchPayload,
        kind: CSSStyleSectionKind,
        styleSheetHeaders: CSSStyleSheetHeaderRegistry
    ) {
        let isEditable = match.rule.origin != .userAgent && match.rule.style.id != nil
        let ruleStyle = normalizedStyle(match.rule.style, isEditable: isEditable, ruleOrigin: match.rule.origin)
        let rule = CSSRule(
            id: match.rule.id,
            selectorList: match.rule.selectorList,
            sourceURL: match.rule.sourceURL,
            sourceLine: match.rule.sourceLine,
            styleSheetSourceLocation: styleSheetHeaders.sourceLocation(
                for: match.rule,
                targetID: identity.targetID
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
}
