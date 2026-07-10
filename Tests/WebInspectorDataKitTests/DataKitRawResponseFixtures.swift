import Foundation
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

func rawOuterHTMLResult(_ html: String) throws -> WebInspectorTestJSONObject {
    try testJSONObject(DOMOuterHTMLResultWire(outerHTML: html))
}

func rawCSSMatchedStylesResult(_ styles: CSS.MatchedStyles) throws -> WebInspectorTestJSONObject {
    try testJSONObject(CSSMatchedStylesResultWire(styles))
}

func rawCSSInlineStylesResult(_ styles: CSS.InlineStyles) throws -> WebInspectorTestJSONObject {
    try testJSONObject(CSSInlineStylesResultWire(styles))
}

func rawCSSComputedStyleResult(
    _ properties: [CSS.ComputedProperty]
) throws -> WebInspectorTestJSONObject {
    try testJSONObject(CSSComputedStyleResultWire(
        computedStyle: properties.map(CSSComputedPropertyWire.init)
    ))
}

func rawCSSStyleResult(_ style: CSS.Style) throws -> WebInspectorTestJSONObject {
    try testJSONObject(CSSSetStyleResultWire(style: CSSStyleWire(style)))
}

func rawCSSRuleResult(_ rule: CSS.Rule) throws -> WebInspectorTestJSONObject {
    try testJSONObject(CSSSetRuleResultWire(rule: CSSRuleWire(rule)))
}

func rawNetworkBodyResult(_ body: Network.Body) throws -> WebInspectorTestJSONObject {
    try testJSONObject(NetworkBodyResultWire(
        body: body.data,
        base64Encoded: body.base64Encoded
    ))
}

func rawRuntimeEvaluationResult(
    _ result: Runtime.EvaluationResult
) throws -> WebInspectorTestJSONObject {
    try testJSONObject(RuntimeEvaluationResultWire(
        result: RuntimeRemoteObjectWire(result.object),
        wasThrown: result.wasThrown,
        savedResultIndex: result.savedResultIndex
    ))
}

func rawRuntimePropertiesResult(
    _ properties: [Runtime.PropertyDescriptor]
) throws -> WebInspectorTestJSONObject {
    try testJSONObject(RuntimePropertiesResultWire(
        properties: properties.map(RuntimePropertyDescriptorWire.init)
    ))
}

func rawRuntimeCollectionEntriesResult(
    _ entries: [Runtime.CollectionEntry]
) throws -> WebInspectorTestJSONObject {
    try testJSONObject(RuntimeCollectionEntriesResultWire(
        entries: entries.map(RuntimeCollectionEntryWire.init)
    ))
}

private struct DOMOuterHTMLResultWire: Encodable {
    let outerHTML: String
}

private struct CSSMatchedStylesResultWire: Encodable {
    let matchedCSSRules: [CSSRuleMatchWire]
    let pseudoElements: [CSSPseudoElementMatchesWire]
    let inherited: [CSSInheritedEntryWire]

    init(_ styles: CSS.MatchedStyles) {
        matchedCSSRules = styles.matchedRules.map { CSSRuleMatchWire(rule: CSSRuleWire($0)) }
        pseudoElements = styles.pseudoElements.map(CSSPseudoElementMatchesWire.init)
        inherited = styles.inherited.map(CSSInheritedEntryWire.init)
    }
}

private struct CSSRuleMatchWire: Encodable {
    let rule: CSSRuleWire
}

private struct CSSPseudoElementMatchesWire: Encodable {
    let pseudoId: String
    let matches: [CSSRuleMatchWire]

    init(_ value: CSS.MatchedStyles.PseudoElementMatches) {
        pseudoId = value.pseudoID
        matches = value.matchedRules.map { CSSRuleMatchWire(rule: CSSRuleWire($0)) }
    }
}

private struct CSSInheritedEntryWire: Encodable {
    let inlineStyle: CSSStyleWire?
    let matchedCSSRules: [CSSRuleMatchWire]

    init(_ value: CSS.MatchedStyles.InheritedEntry) {
        inlineStyle = value.inlineStyle.map(CSSStyleWire.init)
        matchedCSSRules = value.matchedRules.map { CSSRuleMatchWire(rule: CSSRuleWire($0)) }
    }
}

private struct CSSInlineStylesResultWire: Encodable {
    let inlineStyle: CSSStyleWire?
    let attributesStyle: CSSStyleWire?

    init(_ styles: CSS.InlineStyles) {
        inlineStyle = styles.inlineStyle.map(CSSStyleWire.init)
        attributesStyle = styles.attributesStyle.map(CSSStyleWire.init)
    }
}

private struct CSSComputedStyleResultWire: Encodable {
    let computedStyle: [CSSComputedPropertyWire]
}

private struct CSSComputedPropertyWire: Encodable {
    let name: String
    let value: String

    init(_ property: CSS.ComputedProperty) {
        name = property.name
        value = property.value
    }
}

private struct CSSSetStyleResultWire: Encodable {
    let style: CSSStyleWire
}

private struct CSSSetRuleResultWire: Encodable {
    let rule: CSSRuleWire
}

private struct CSSRuleWire: Encodable {
    let ruleId: CSSBackendIDWire?
    let selectorList: CSSSelectorListWire
    let sourceURL: String?
    let sourceLine: Int?
    let sourceLocation: CSSSourceRangeWire?
    let origin: String
    let style: CSSStyleWire
    let groupings: [CSSGroupingWire]
    let isImplicitlyNested: Bool

    init(_ rule: CSS.Rule) {
        ruleId = rule.id.map { CSSBackendIDWire($0.unscopedRawValue) }
        selectorList = CSSSelectorListWire(rule.selectorList)
        sourceURL = rule.sourceURL
        sourceLine = rule.sourceLine
        sourceLocation = rule.sourceLocation.map(CSSSourceRangeWire.init)
        origin = rule.origin.rawValue
        style = CSSStyleWire(rule.style)
        groupings = rule.groupings.map(CSSGroupingWire.init)
        isImplicitlyNested = rule.isImplicitlyNested
    }
}

private struct CSSSelectorListWire: Encodable {
    let selectors: [CSSSelectorWire]
    let text: String
    let range: CSSSourceRangeWire?

    init(_ list: CSS.Rule.SelectorList) {
        selectors = list.selectors.map(CSSSelectorWire.init)
        text = list.text
        range = list.range.map(CSSSourceRangeWire.init)
    }
}

private struct CSSSelectorWire: Encodable {
    let text: String

    init(_ text: String) {
        self.text = text
    }
}

private struct CSSGroupingWire: Encodable {
    let text: String

    init(_ grouping: CSS.Rule.Grouping) {
        text = grouping.text
    }
}

private struct CSSStyleWire: Encodable {
    let styleId: CSSBackendIDWire?
    let cssProperties: [CSSPropertyWire]
    let shorthandEntries: [CSSShorthandWire]
    let cssText: String
    let range: CSSSourceRangeWire?
    let width: String?
    let height: String?

    init(_ style: CSS.Style) {
        styleId = style.isEditable ? CSSBackendIDWire(style.id.unscopedRawValue) : nil
        cssProperties = style.properties.map(CSSPropertyWire.init)
        shorthandEntries = style.shorthandEntries.map(CSSShorthandWire.init)
        cssText = style.cssText
        range = style.range.map(CSSSourceRangeWire.init)
        width = style.width
        height = style.height
    }
}

private struct CSSBackendIDWire: Encodable {
    let styleSheetId: String
    let ordinal: Int

    init(_ rawValue: String) {
        let separator = "\u{1F}"
        let components = rawValue.components(separatedBy: separator)
        if components.count > 1, let ordinal = Int(components.last ?? "") {
            styleSheetId = components.dropLast().joined(separator: separator)
            self.ordinal = ordinal
        } else {
            styleSheetId = rawValue
            ordinal = 0
        }
    }
}

private struct CSSPropertyWire: Encodable {
    let name: String
    let value: String
    let priority: String?
    let text: String?
    let parsedOk: Bool
    let status: String
    let implicit: Bool
    let range: CSSSourceRangeWire?

    init(_ property: CSS.Property) {
        name = property.name
        value = property.value
        priority = property.priority
        text = property.text
        parsedOk = property.parsedOk
        switch property.status {
        case .active: status = "active"
        case .inactive: status = "inactive"
        case .disabled: status = "disabled"
        }
        implicit = property.implicit
        range = property.range.map(CSSSourceRangeWire.init)
    }
}

private struct CSSShorthandWire: Encodable {
    let name: String
    let value: String
    let priority: String?

    init(_ shorthand: CSS.Style.ShorthandEntry) {
        name = shorthand.name
        value = shorthand.value
        priority = shorthand.priority
    }
}

private struct CSSSourceRangeWire: Encodable {
    let startLine: Int
    let startColumn: Int
    let endLine: Int
    let endColumn: Int

    init(_ range: CSS.Style.SourceRange) {
        startLine = range.startLine
        startColumn = range.startColumn
        endLine = range.endLine
        endColumn = range.endColumn
    }
}

private struct NetworkBodyResultWire: Encodable {
    let body: String
    let base64Encoded: Bool
}

private struct RuntimeEvaluationResultWire: Encodable {
    let result: RuntimeRemoteObjectWire
    let wasThrown: Bool
    let savedResultIndex: Int?
}

private struct RuntimePropertiesResultWire: Encodable {
    let properties: [RuntimePropertyDescriptorWire]
}

private struct RuntimePropertyDescriptorWire: Encodable {
    let name: String
    let value: RuntimeRemoteObjectWire?
    let writable: Bool?
    let get: RuntimeRemoteObjectWire?
    let set: RuntimeRemoteObjectWire?
    let wasThrown: Bool?
    let configurable: Bool?
    let enumerable: Bool?
    let isOwn: Bool?
    let symbol: RuntimeRemoteObjectWire?
    let isPrivate: Bool?
    let nativeGetter: Bool?

    init(_ property: Runtime.PropertyDescriptor) {
        name = property.name
        value = property.value.map(RuntimeRemoteObjectWire.init)
        writable = property.writable
        get = property.get.map(RuntimeRemoteObjectWire.init)
        set = property.set.map(RuntimeRemoteObjectWire.init)
        wasThrown = property.wasThrown
        configurable = property.configurable
        enumerable = property.enumerable
        isOwn = property.isOwn
        symbol = property.symbol.map(RuntimeRemoteObjectWire.init)
        isPrivate = property.isPrivate
        nativeGetter = property.nativeGetter
    }
}

private struct RuntimeCollectionEntriesResultWire: Encodable {
    let entries: [RuntimeCollectionEntryWire]
}

private struct RuntimeCollectionEntryWire: Encodable {
    let key: RuntimeRemoteObjectWire?
    let value: RuntimeRemoteObjectWire

    init(_ entry: Runtime.CollectionEntry) {
        key = entry.key.map(RuntimeRemoteObjectWire.init)
        value = RuntimeRemoteObjectWire(entry.value)
    }
}
