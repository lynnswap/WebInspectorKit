import Foundation
import Testing
@testable import WebInspectorCore
@testable import WebInspectorTransport

@Test
func cssTransportAdapterBuildsReadCommands() throws {
    let identity = cssIdentity()

    let matched = try CSSTransportAdapter.command(for: .getMatchedStyles(identity: identity))
    #expect(matched.method == "CSS.getMatchedStylesForNode")
    #expect(matched.routing == .target(identity.targetID))
    let matchedParams = try JSONObject(matched.parametersData)
    #expect(matchedParams["nodeId"] as? Int == 2)
    #expect(matchedParams["includePseudo"] as? Bool == true)
    #expect(matchedParams["includeInherited"] as? Bool == true)

    let inline = try CSSTransportAdapter.command(for: .getInlineStyles(identity: identity))
    #expect(inline.method == "CSS.getInlineStylesForNode")
    #expect(try JSONObject(inline.parametersData)["nodeId"] as? Int == 2)

    let computed = try CSSTransportAdapter.command(for: .getComputedStyle(identity: identity))
    #expect(computed.method == "CSS.getComputedStyleForNode")
    #expect(try JSONObject(computed.parametersData)["nodeId"] as? Int == 2)
}

@Test
func cssTransportAdapterBuildsSetStyleTextCommand() throws {
    let styleID = CSSStyleIdentifier(styleSheetID: .init("sheet-1"), ordinal: 7)
    let command = try CSSTransportAdapter.command(for: .setStyleText(
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
func cssTransportAdapterDecodesReadAndSetStyleTextResults() throws {
    let matched = try CSSTransportAdapter.matchedStyles(from: ProtocolCommandResult(
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

    let inline = try CSSTransportAdapter.inlineStyles(from: ProtocolCommandResult(
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

    let computed = try CSSTransportAdapter.computedStyles(from: ProtocolCommandResult(
        domain: .css,
        method: "CSS.getComputedStyleForNode",
        targetID: .init("page"),
        resultData: Data(#"{"computedStyle":[{"name":"display","value":"block"}]}"#.utf8)
    ))
    #expect(computed == [CSSComputedStyleProperty(name: "display", value: "block")])

    let setStyle = try CSSTransportAdapter.setStyleTextResult(from: ProtocolCommandResult(
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
func cssTransportAdapterAppliesTargetScopedInvalidationEvents() async throws {
    let css = await CSSSession()
    let identity = cssIdentity()
    let token = try #require(await css.beginRefresh(identity: identity))
    await css.applyRefresh(
        token: token,
        matched: .init(),
        inline: CSSInlineStylesPayload(inlineStyle: CSSStyle(
            id: CSSStyleIdentifier(styleSheetID: .init("inline"), ordinal: 0),
            cssProperties: [
                CSSProperty(name: "margin", value: "0", text: "margin: 0;"),
            ]
        )),
        computed: []
    )

    try await CSSTransportAdapter.applyCSSEvent(
        ProtocolEventEnvelope(
            sequence: 1,
            domain: .css,
            method: "CSS.styleSheetChanged",
            targetID: identity.targetID,
            paramsData: Data(#"{"styleSheetId":"sheet"}"#.utf8)
        ),
        to: css
    )
    #expect(await css.selectedState == .needsRefresh)
}

private func cssIdentity() -> CSSNodeStyleIdentity {
    let targetID = ProtocolTargetIdentifier("page")
    let documentID = DOMDocumentIdentifier(targetID: targetID, localDocumentLifetimeID: .init(1))
    return CSSNodeStyleIdentity(
        nodeID: DOMNodeIdentifier(documentID: documentID, nodeID: .init(2)),
        targetID: targetID,
        documentID: documentID,
        protocolNodeID: .init(2),
        targetCapabilities: [.css, .dom]
    )
}

private func JSONObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
