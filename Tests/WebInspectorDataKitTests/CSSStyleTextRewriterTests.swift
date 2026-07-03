import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@Test
func rewriterCommentsOutPropertyBySerializingStyleText() throws {
    let style = rewriterStyle(properties: [
        rewriterProperty(name: "margin", value: "0", text: "margin: 0;", index: 0),
        rewriterProperty(name: "box-sizing", value: "border-box", text: "box-sizing: border-box;", index: 1),
    ])

    let rewritten = CSSStyleTextRewriter.rewrittenStyleText(style: style, propertyIndex: 0, enabled: false)

    #expect(rewritten == "/* margin: 0; */\nbox-sizing: border-box;")
}

@Test
func rewriterUncommentsDisabledPropertyText() throws {
    let style = rewriterStyle(properties: [
        rewriterProperty(name: "margin", value: "0", text: "/* margin: 0; */", status: .disabled, index: 0),
    ])

    let rewritten = CSSStyleTextRewriter.rewrittenStyleText(style: style, propertyIndex: 0, enabled: true)

    #expect(rewritten == "margin: 0;")
}

@Test
func rewriterRewritesAuthoredStyleTextWithoutSerializingInactiveRows() throws {
    let style = rewriterStyle(
        properties: [
            rewriterProperty(name: "font-family", value: "sans-serif", text: "font-family: sans-serif;", index: 0),
            rewriterProperty(name: "font-size", value: "10pt", text: "font-size: 10pt;", index: 1),
            rewriterProperty(name: "font-size", value: "12px", text: "font-size: 12px;", status: .inactive, isEditable: false, index: 2),
        ],
        cssText: "font-family: sans-serif;\nfont-size: 10pt;"
    )

    let rewritten = CSSStyleTextRewriter.rewrittenStyleText(style: style, propertyIndex: 1, enabled: false)

    #expect(rewritten == "font-family: sans-serif;\n/* font-size: 10pt; */")
}

@Test
func rewriterRewritesOnlyDeclarationMatchesOutsideStrings() throws {
    let style = rewriterStyle(
        properties: [
            rewriterProperty(name: "content", value: #""color: red;""#, text: #"content: "color: red;";"#, index: 0),
            rewriterProperty(name: "color", value: "red", text: "color: red;", index: 1),
        ],
        cssText: """
        content: "color: red;";
        color: red;
        """
    )

    let rewritten = CSSStyleTextRewriter.rewrittenStyleText(style: style, propertyIndex: 1, enabled: false)

    #expect(rewritten == """
    content: "color: red;";
    /* color: red; */
    """)
}

@Test
func rewriterTreatsCommentsAsDeclarationBoundaries() throws {
    let beforeCommentStyle = rewriterStyle(
        properties: [
            rewriterProperty(name: "color", value: "red", text: "color: red;", index: 0),
        ],
        cssText: """
        /* note /* marker */
        color: red;
        """
    )

    let beforeCommentRewritten = CSSStyleTextRewriter.rewrittenStyleText(
        style: beforeCommentStyle,
        propertyIndex: 0,
        enabled: false
    )
    #expect(beforeCommentRewritten == """
    /* note /* marker */
    /* color: red; */
    """)

    let afterCommentStyle = rewriterStyle(
        properties: [
            rewriterProperty(name: "color", value: "red", text: "color: red", index: 0),
        ],
        cssText: "color: red /* note */;"
    )

    let afterCommentRewritten = CSSStyleTextRewriter.rewrittenStyleText(
        style: afterCommentStyle,
        propertyIndex: 0,
        enabled: false
    )
    #expect(afterCommentRewritten == "/* color: red */ /* note */;")
}

@Test
func rewriterRewritesRepeatedAuthoredDeclarationByPropertyOccurrence() throws {
    let style = rewriterStyle(
        properties: [
            rewriterProperty(name: "color", value: "red", text: "color: red;", index: 0),
            rewriterProperty(name: "color", value: "red", text: "color: red;", index: 1),
        ],
        cssText: """
        color: red;
        color: red;
        """
    )

    let firstRewritten = CSSStyleTextRewriter.rewrittenStyleText(style: style, propertyIndex: 0, enabled: false)
    #expect(firstRewritten == """
    /* color: red; */
    color: red;
    """)

    let secondRewritten = CSSStyleTextRewriter.rewrittenStyleText(style: style, propertyIndex: 1, enabled: false)
    #expect(secondRewritten == """
    color: red;
    /* color: red; */
    """)
}

@Test
func rewriterResolvesStylesheetRelativeSourceRanges() throws {
    let style = rewriterStyle(
        properties: [
            rewriterProperty(
                name: "color",
                value: "red",
                text: "color: red;",
                range: CSS.Style.SourceRange(startLine: 1, startColumn: 0, endLine: 1, endColumn: 11),
                index: 0
            ),
            rewriterProperty(
                name: "color",
                value: "red",
                text: "color: red;",
                range: CSS.Style.SourceRange(startLine: 2, startColumn: 0, endLine: 2, endColumn: 11),
                index: 1
            ),
        ],
        cssText: """
        color: red;
        color: red;
        """,
        range: CSS.Style.SourceRange(startLine: 1, startColumn: 0, endLine: 3, endColumn: 0)
    )

    let rewritten = CSSStyleTextRewriter.rewrittenStyleText(style: style, propertyIndex: 0, enabled: false)

    #expect(rewritten == """
    /* color: red; */
    color: red;
    """)
}

@Test
func rewriterRefusesTogglesForMissingOrUntoggleableText() throws {
    #expect(CSSStyleTextRewriter.canTogglePropertyText(
        rewriterProperty(name: "margin", value: "0", text: nil)
    ) == false)
    #expect(CSSStyleTextRewriter.canTogglePropertyText(
        rewriterProperty(name: "color", value: "red", text: "color: red;", status: .inactive)
    ) == false)
    #expect(CSSStyleTextRewriter.canTogglePropertyText(
        rewriterProperty(name: "color", value: "red", text: "color: red; /* note */")
    ) == false)
    #expect(CSSStyleTextRewriter.canTogglePropertyText(
        rewriterProperty(name: "color", value: "red", text: "color: red;", status: .disabled)
    ) == false)
    #expect(CSSStyleTextRewriter.canTogglePropertyText(
        rewriterProperty(name: "color", value: "red", text: "color: red;")
    ))
    #expect(CSSStyleTextRewriter.canTogglePropertyText(
        rewriterProperty(name: "color", value: "red", text: "/* color: red; */", status: .disabled)
    ))
}

@Test
func rewriterDoesNotSynthesizeStyleTextWhenOtherPropertiesHaveNoAuthoredText() throws {
    let style = rewriterStyle(properties: [
        rewriterProperty(name: "margin", value: "0", text: "margin: 0;", index: 0),
        rewriterProperty(name: "margin-top", value: "0", text: nil, implicit: true, isEditable: false, index: 1),
    ])

    #expect(CSSStyleTextRewriter.canSafelyRewriteStyleText(style: style, propertyIndex: 0) == false)
    #expect(CSSStyleTextRewriter.rewrittenStyleText(style: style, propertyIndex: 0, enabled: false) == nil)
}

@Test
func rewriterRefusesUnsafeAuthoredStyleText() throws {
    let missingDeclarationStyle = rewriterStyle(
        properties: [
            rewriterProperty(name: "color", value: "red", text: "color: red;", index: 0),
        ],
        cssText: "background: blue;"
    )
    #expect(CSSStyleTextRewriter.canSafelyRewriteStyleText(style: missingDeclarationStyle, propertyIndex: 0) == false)
    #expect(CSSStyleTextRewriter.rewrittenStyleText(style: missingDeclarationStyle, propertyIndex: 0, enabled: false) == nil)

    let quotedDeclarationStyle = rewriterStyle(
        properties: [
            rewriterProperty(name: "color", value: "red", text: "color: red;", index: 0),
        ],
        cssText: #"content: "color: red;";"#
    )
    #expect(CSSStyleTextRewriter.canSafelyRewriteStyleText(style: quotedDeclarationStyle, propertyIndex: 0) == false)

    let safeStyle = rewriterStyle(
        properties: [
            rewriterProperty(name: "color", value: "red", text: "color: red;", index: 0),
        ],
        cssText: "color: red;"
    )
    #expect(CSSStyleTextRewriter.canSafelyRewriteStyleText(style: safeStyle, propertyIndex: 0))
    #expect(CSSStyleTextRewriter.canSafelyRewriteStyleText(style: safeStyle, propertyIndex: 1) == false)
}

private func rewriterProperty(
    name: String,
    value: String,
    text: String?,
    status: CSS.Status = .active,
    implicit: Bool = false,
    range: CSS.Style.SourceRange? = nil,
    isEditable: Bool = true,
    index: Int = 0
) -> CSS.Property {
    CSS.Property(
        id: CSS.Property.ID("style:\(index)"),
        name: name,
        value: value,
        text: text,
        status: status,
        implicit: implicit,
        range: range,
        isEditable: isEditable
    )
}

private func rewriterStyle(
    properties: [CSS.Property],
    cssText: String = "",
    range: CSS.Style.SourceRange? = nil
) -> CSS.Style {
    CSS.Style(
        id: CSS.Style.ID("style"),
        properties: properties,
        cssText: cssText,
        range: range,
        isEditable: true
    )
}
