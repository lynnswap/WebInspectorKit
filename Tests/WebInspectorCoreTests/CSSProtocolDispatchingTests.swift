import Foundation
import Testing
import WebInspectorTransport
@testable import WebInspectorCore

@Test
func cssProtocolDispatchingBuildsReadCommands() throws {
    let identity = cssIdentity()

    let matched = try CSSProtocolCommands().command(for: .getMatchedStyles(identity: identity))
    #expect(matched.method == "CSS.getMatchedStylesForNode")
    #expect(matched.routing == .target(identity.targetID))
    let matchedParams = try JSONObject(matched.parametersData)
    #expect(matchedParams["nodeId"] as? Int == 2)
    #expect(matchedParams["includePseudo"] as? Bool == true)
    #expect(matchedParams["includeInherited"] as? Bool == true)

    let inline = try CSSProtocolCommands().command(for: .getInlineStyles(identity: identity))
    #expect(inline.method == "CSS.getInlineStylesForNode")
    #expect(try JSONObject(inline.parametersData)["nodeId"] as? Int == 2)

    let computed = try CSSProtocolCommands().command(for: .getComputedStyle(identity: identity))
    #expect(computed.method == "CSS.getComputedStyleForNode")
    #expect(try JSONObject(computed.parametersData)["nodeId"] as? Int == 2)
}

@Test
func cssProtocolDispatchingBuildsSetStyleTextCommand() throws {
    let styleID = CSSStyle.ID(styleSheetID: .init("sheet-1"), ordinal: 7)
    let command = try CSSProtocolCommands().command(for: .setStyleText(
        targetID: .init("page"),
        styleID: styleID,
        text: "/* margin: 0; */"
    ))

    #expect(command.method == "CSS.setStyleText")
    #expect(command.routing == .target(.init("page")))
    let params = try JSONObject(command.parametersData)
    let encodedStyleID = try #require(params["styleId"] as? [String: Any])
    #expect(encodedStyleID["styleSheetId"] as? String == "sheet-1")
    #expect(encodedStyleID["ordinal"] as? Int == 7)
    #expect(params["text"] as? String == "/* margin: 0; */")
}

@Test
func cssProtocolDispatchingDecodesReadAndSetStyleTextResults() throws {
    let matched = try CSSProtocolCommands().matchedStyles(from: ProtocolCommand.Result(
        domain: .css,
        method: "CSS.getMatchedStylesForNode",
        targetID: .init("page"),
        resultData: Data("""
        {
          "matchedCSSRules": [
            {
              "rule": {
                "ruleId": {"styleSheetId": "sheet", "ordinal": 1},
                "selectorList": {"selectors": [{"text": "body"}], "text": "body"},
                "origin": "author",
                "style": {
                  "styleId": {"styleSheetId": "sheet", "ordinal": 1},
                  "cssProperties": [{"name": "margin", "value": "0", "text": "margin: 0;"}]
                }
              },
              "matchingSelectors": [0]
            }
          ]
        }
        """.utf8)
    ))
    #expect(matched.matchedRules.first?.rule.selectorList.text == "body")
    #expect(matched.matchedRules.first?.rule.style.cssProperties.first?.status == .style)

    let inline = try CSSProtocolCommands().inlineStyles(from: ProtocolCommand.Result(
        domain: .css,
        method: "CSS.getInlineStylesForNode",
        targetID: .init("page"),
        resultData: Data("""
        {
          "inlineStyle": {
            "styleId": {"styleSheetId": "inline", "ordinal": 0},
            "cssProperties": [{"name": "padding", "value": "4px", "text": "padding: 4px;"}]
          }
        }
        """.utf8)
    ))
    #expect(inline.inlineStyle?.cssProperties.first?.name == "padding")

    let computed = try CSSProtocolCommands().computedStyles(from: ProtocolCommand.Result(
        domain: .css,
        method: "CSS.getComputedStyleForNode",
        targetID: .init("page"),
        resultData: Data(#"{"computedStyle":[{"name":"display","value":"block"}]}"#.utf8)
    ))
    #expect(computed == [CSSComputedStyleProperty.Payload(name: "display", value: "block")])

    let setStyle = try CSSProtocolCommands().setStyleTextResult(from: ProtocolCommand.Result(
        domain: .css,
        method: "CSS.setStyleText",
        targetID: .init("page"),
        resultData: Data("""
        {
          "style": {
            "styleId": {"styleSheetId": "inline", "ordinal": 0},
            "cssProperties": [{"name": "margin", "value": "0", "text": "/* margin: 0; */", "status": "disabled"}]
          }
        }
        """.utf8)
    ))
    #expect(setStyle.cssProperties.first?.status == .disabled)
}

@Test
func cssProtocolDispatchingAppliesTargetScopedInvalidationEvents() async throws {
    let css = await CSSSession()
    let identity = cssIdentity()
    let token = try #require(await css.beginRefresh(identity: identity))
    await css.applyRefresh(
        token: token,
        matched: .init(),
        inline: .init(),
        computed: []
    )

    try await CSSProtocolEventDispatcher(handler: css).dispatch(
        ProtocolEvent(
            sequence: 1,
            domain: .css,
            method: "CSS.styleSheetChanged",
            targetID: identity.targetID,
            paramsData: Data(#"{"styleSheetId":"untracked"}"#.utf8)
        )
    )
    #expect(await css.selectedState == .needsRefresh)

    let refreshToken = try #require(await css.beginRefresh(identity: identity))
    await css.applyRefresh(
        token: refreshToken,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: cssRule(selector: "body", styleID: .init(styleSheetID: .init("sheet"), ordinal: 0), properties: [
                    CSSProperty.Payload(name: "margin", value: "0", text: "margin: 0;"),
                ]),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    try await CSSProtocolEventDispatcher(handler: css).dispatch(
        ProtocolEvent(
            sequence: 2,
            domain: .css,
            method: "CSS.styleSheetChanged",
            targetID: identity.targetID,
            paramsData: Data(#"{"styleSheetId":"sheet"}"#.utf8)
        )
    )
    #expect(await css.selectedState == .needsRefresh)
}

@Test
@MainActor
func cssProtocolDispatchingRegistersStyleSheetHeaderOffsets() async throws {
    let css = CSSSession()
    let identity = cssIdentity()

    try await CSSProtocolEventDispatcher(handler: css).dispatch(
        ProtocolEvent(
            sequence: 1,
            domain: .css,
            method: "CSS.styleSheetAdded",
            targetID: identity.targetID,
            paramsData: Data("""
            {
              "header": {
                "styleSheetId": "sheet",
                "sourceURL": "https://example.com/document.html",
                "origin": "author",
                "isInline": true,
                "startLine": 12,
                "startColumn": 7
              }
            }
            """.utf8)
        )
    )

    let token = try #require(css.beginRefresh(identity: identity))
    css.applyRefresh(
        token: token,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: cssRule(
                    selector: ".card",
                    styleID: .init(styleSheetID: .init("sheet"), ordinal: 0),
                    selectorRange: CSSStyle.SourceRange(startLine: 0, startColumn: 3, endLine: 0, endColumn: 8),
                    properties: [
                        CSSProperty.Payload(name: "display", value: "grid", text: "display: grid;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    let sourceLocation = try #require(css.selectedNodeStyles?.sections.first?.rule?.sourceLocation)
    #expect(sourceLocation == CSSRule.SourceLocation(
        sourceURL: "https://example.com/document.html",
        line: 12,
        column: 10
    ))
}

private func cssIdentity() -> CSSNodeStyles.Identity {
    let targetID = ProtocolTarget.ID("page")
    let documentID = DOMDocument.ID(targetID: targetID, localDocumentLifetimeID: .init(1))
    return CSSNodeStyles.Identity(
        nodeID: DOMNode.ID(documentID: documentID, nodeID: .init(2)),
        targetID: targetID,
        documentID: documentID,
        protocolNodeID: .init(2),
        targetCapabilities: [.css, .dom]
    )
}

private func cssRule(
    selector: String,
    styleID: CSSStyle.ID,
    sourceURL: String? = nil,
    sourceLine: Int = 1,
    selectorRange: CSSStyle.SourceRange? = nil,
    properties: [CSSProperty.Payload]
) -> CSSRule.Payload {
    CSSRule.Payload(
        id: CSSRule.ID(styleSheetID: styleID.styleSheetID, ordinal: styleID.ordinal),
        selectorList: CSSRule.SelectorList(selectors: [CSSRule.Selector(text: selector)], text: selector, range: selectorRange),
        sourceURL: sourceURL,
        sourceLine: sourceLine,
        origin: .author,
        style: CSSStyle.Payload(id: styleID, cssProperties: properties)
    )
}

private func JSONObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
