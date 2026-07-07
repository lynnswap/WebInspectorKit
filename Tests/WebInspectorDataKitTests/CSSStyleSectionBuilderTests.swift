import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@Test
func sectionBuilderOrdersSectionsAcrossAllKinds() throws {
    let matched = CSS.MatchedStyles(
        matchedRules: [
            builderRule(selector: ".base"),
            builderRule(selector: ".specific"),
        ],
        inherited: [
            CSS.MatchedStyles.InheritedEntry(
                inlineStyle: builderStyle(id: "ancestor-inline"),
                matchedRules: [
                    builderRule(selector: ".ancestor-base"),
                    builderRule(selector: ".ancestor-specific"),
                ]
            ),
            CSS.MatchedStyles.InheritedEntry(
                matchedRules: [
                    builderRule(selector: ".grandparent"),
                ]
            ),
        ],
        pseudoElements: [
            CSS.MatchedStyles.PseudoElementMatches(
                pseudoID: "before",
                matchedRules: [
                    builderRule(selector: ".pseudo-base"),
                    builderRule(selector: ".pseudo-specific"),
                ]
            ),
        ]
    )
    let inline = CSS.InlineStyles(
        inlineStyle: builderStyle(id: "inline"),
        attributesStyle: builderStyle(id: "attributes", isEditable: false)
    )

    let sections = CSSStyleSectionBuilder.makeSections(matched: matched, inline: inline)

    #expect(sections.map(\.kind) == [
        .inlineStyle,
        .rule,
        .rule,
        .attributesStyle,
        .pseudoElement("before"),
        .pseudoElement("before"),
        .inheritedInlineStyle(ancestorIndex: 0),
        .inheritedRule(ancestorIndex: 0),
        .inheritedRule(ancestorIndex: 0),
        .inheritedRule(ancestorIndex: 1),
    ])
    #expect(sections.map(\.title) == [
        "element.style",
        ".specific",
        ".base",
        "Attributes",
        ".pseudo-specific",
        ".pseudo-base",
        "Inherited element.style",
        ".ancestor-specific",
        ".ancestor-base",
        ".grandparent",
    ])
    #expect(sections.map(\.id) == sections.enumerated().map { ordinal, section in
        CSSStyleSection.ID(kind: section.kind, ordinal: ordinal)
    })
    #expect(sections.map(\.id.ordinal) == Array(0..<10))
}

@Test
func sectionBuilderKeepsRuleSectionsEditableExceptUserAgentRules() throws {
    let matched = CSS.MatchedStyles(matchedRules: [
        builderRule(selector: "body", origin: .userAgent),
        builderRule(selector: ".author"),
    ])

    let sections = CSSStyleSectionBuilder.makeSections(matched: matched, inline: nil)

    let authorSection = try #require(sections.first { $0.title == ".author" })
    #expect(authorSection.isEditable)
    #expect(authorSection.style.isEditable)
    #expect(authorSection.style.properties.map(\.isEditable) == [true])
    #expect(authorSection.rule?.style.isEditable == true)

    let userAgentSection = try #require(sections.first { $0.title == "body" })
    #expect(userAgentSection.isEditable == false)
    #expect(userAgentSection.style.isEditable == false)
    #expect(userAgentSection.style.properties.map(\.isEditable) == [false])
}

@Test
func sectionBuilderKeepsAnonymousStylesNonEditable() throws {
    let inline = CSS.InlineStyles(
        inlineStyle: builderStyle(id: "anonymous:inline", isEditable: false),
        attributesStyle: builderStyle(id: "anonymous:attributes", isEditable: false)
    )

    let sections = CSSStyleSectionBuilder.makeSections(matched: CSS.MatchedStyles(), inline: inline)

    #expect(sections.map(\.kind) == [.inlineStyle, .attributesStyle])
    #expect(sections.map(\.isEditable) == [false, false])
    #expect(sections.map(\.style.isEditable) == [false, false])
    #expect(sections.flatMap(\.style.properties).map(\.isEditable) == [false, false])
}

@Test
func sectionBuilderNormalizesPropertyRowEditability() throws {
    let style = CSS.Style(
        id: CSS.Style.ID("sheet:0"),
        properties: [
            builderProperty(name: "margin", value: "0", text: "margin: 0;", index: 0),
            builderProperty(name: "color", value: "red", text: "color: red;", status: .inactive, index: 1),
            builderProperty(name: "display", value: "block", text: "/* display: block; */", status: .disabled, index: 2),
            builderProperty(name: "box-sizing", value: "border-box", text: "box-sizing: border-box;", index: 3),
        ],
        cssText: """
        margin: 0;
        color: red;
        /* display: block; */
        box-sizing: border-box;
        """,
        isEditable: true
    )
    let matched = CSS.MatchedStyles(matchedRules: [
        builderRule(selector: "body", style: style),
    ])

    let sections = CSSStyleSectionBuilder.makeSections(matched: matched, inline: nil)

    let section = try #require(sections.first)
    #expect(section.isEditable)
    #expect(section.style.properties.map(\.isEditable) == [true, false, true, true])
}

@Test
func sectionBuilderMakesNoSectionsWithoutInlineStyles() throws {
    let matched = CSS.MatchedStyles(matchedRules: [
        builderRule(selector: ".only"),
    ])

    let sections = CSSStyleSectionBuilder.makeSections(matched: matched, inline: nil)

    #expect(sections.map(\.kind) == [.rule])
    #expect(sections.first?.rule?.selectorText == ".only")
}

private func builderRule(
    selector: String,
    origin: CSS.Origin = CSS.Origin(rawValue: "author"),
    style: CSS.Style? = nil
) -> CSS.Rule {
    CSS.Rule(
        id: CSS.Rule.ID(selector),
        selectorList: CSS.Rule.SelectorList(selectors: [selector], text: selector),
        origin: origin,
        style: style ?? builderStyle(id: selector)
    )
}

private func builderStyle(id: String, isEditable: Bool = true) -> CSS.Style {
    CSS.Style(
        id: CSS.Style.ID(id),
        properties: [
            builderProperty(name: "margin", value: "0", text: "margin: 0;", index: 0),
        ],
        cssText: "margin: 0;",
        isEditable: isEditable
    )
}

private func builderProperty(
    name: String,
    value: String,
    text: String?,
    status: CSS.Status = .active,
    index: Int = 0
) -> CSS.Property {
    CSS.Property(
        id: CSS.Property.ID("style:\(index)"),
        name: name,
        value: value,
        text: text,
        status: status
    )
}
