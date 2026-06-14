import Observation
import Synchronization
import Testing
import WebInspectorTransport
@testable import WebInspectorCore

@Test
func protocolTargetCapabilitiesTreatPageTargetsAsCSSCapable() {
    #expect(ProtocolTarget.Kind(protocolType: "web-page") == .page)
    #expect(ProtocolTarget.Capabilities.pageDefault.contains(.css))
    #expect(ProtocolTarget.Capabilities.pageDefault.contains(.console))
    #expect(ProtocolTarget.Capabilities.protocolDefault(for: .page).contains(.css))
    #expect(ProtocolTarget.Capabilities.protocolDefault(for: .worker).contains(.console))
    #expect(ProtocolTarget.Capabilities.protocolDefault(for: .serviceWorker).contains(.console))
    #expect(ProtocolTarget.Capabilities.protocolDefault(for: .frame).contains(.css) == false)
    #expect(ProtocolTarget.Capabilities.protocolDefault(for: .frame).contains(.console) == false)
    #expect(ProtocolTarget.Capabilities(domainNames: ["DOM", "CSS", "Console"]).contains(.css))
    #expect(ProtocolTarget.Capabilities(domainNames: ["DOM", "CSS", "Console"]).contains(.console))
    #expect(ProtocolTarget.Capabilities.resolved(for: .page, domainNames: ["DOM"]).contains(.css))
    #expect(ProtocolTarget.Capabilities.resolved(for: .page, domainNames: ["DOM"]).contains(.console))
    #expect(ProtocolTarget.Capabilities.resolved(for: .frame, domainNames: ["DOM"]).contains(.css) == false)
    #expect(ProtocolTarget.Capabilities.resolved(for: .frame, domainNames: ["DOM"]).contains(.console) == false)
}

@Test
func selectedCSSNodeStyleIdentityRequiresElementCurrentNodeAndCSSTarget() async throws {
    let pageTargetID = ProtocolTarget.ID("page")
    let session = await DOMSession()
    await session.applyTargetCreated(
        .init(id: pageTargetID, kind: .page),
        makeCurrentMainPage: true
    )
    let rootID = await session.replaceDocumentRoot(
        DOMNode.Payload(
            nodeID: .init(1),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                DOMNode.Payload(nodeID: .init(2), nodeType: .element, nodeName: "BODY", localName: "body"),
            ])
        ),
        targetID: pageTargetID
    )
    let snapshot = await session.snapshot()
    let bodyID = try #require(snapshot.currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(2))])

    await session.selectNode(bodyID)
    let identity = try #require(await session.selectedCSSNodeStyleIdentity().successValue)
    #expect(identity.targetID == pageTargetID)
    #expect(identity.protocolNodeID == .init(2))

    await session.selectNode(rootID)
    #expect(await session.selectedCSSNodeStyleIdentity().failureValue == .nonElementNode(.document))

    await session.applyTargetCreated(.init(id: .init("plain"), kind: .page, capabilities: [.dom]))
    let plainRootID = await session.replaceDocumentRoot(
        DOMNode.Payload(
            nodeID: .init(1),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                DOMNode.Payload(nodeID: .init(2), nodeType: .element, nodeName: "BODY", localName: "body"),
            ])
        ),
        targetID: .init("plain")
    )
    let plainDocumentID = plainRootID.documentID
    let plainBodyID = DOMNode.ID(documentID: plainDocumentID, nodeID: .init(2))
    await session.selectNode(plainBodyID)
    #expect(await session.selectedCSSNodeStyleIdentity().failureValue == .cssUnavailableForTarget(.init("plain")))

    let staleNodeID = DOMNode.ID(documentID: plainDocumentID, nodeID: .init(999))
    #expect(await session.cssNodeStyleIdentity(for: staleNodeID).failureValue == .staleNode(staleNodeID))
}

@Test
@MainActor
func selectedNodeStylesResolvesSelectedDOMNodeThroughCSSSession() throws {
    let pageTargetID = ProtocolTarget.ID("page")
    let css = CSSSession()
    let session = DOMSession(elementStyles: css)
    session.applyTargetCreated(
        .init(id: pageTargetID, kind: .page, capabilities: .pageDefault),
        makeCurrentMainPage: true
    )
    let rootID = session.replaceDocumentRoot(
        DOMNode.Payload(
            nodeID: .init(1),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                DOMNode.Payload(nodeID: .init(2), nodeType: .element, nodeName: "BODY", localName: "body"),
            ])
        ),
        targetID: pageTargetID
    )
    let snapshot = session.snapshot()
    let bodyID = try #require(snapshot.currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(2))])

    session.selectNode(bodyID)
    let identity = try #require(session.selectedCSSNodeStyleIdentity().successValue)

    let pendingStyles = try #require(session.selectedNodeStyles)
    #expect(pendingStyles.identity == identity)
    #expect(pendingStyles.state == .needsRefresh)
    #expect(pendingStyles.sections.isEmpty)

    let token = try #require(css.beginRefresh(identity: identity))
    let loadingStyles = try #require(session.selectedNodeStyles)
    #expect(loadingStyles.identity == identity)
    #expect(loadingStyles.state == .loading)
    #expect(loadingStyles.sections.isEmpty)

    css.applyRefresh(
        token: token,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: "body",
                    properties: [
                        CSSProperty.Payload(name: "margin", value: "0", text: "margin: 0;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    let loadedStyles = try #require(session.selectedNodeStyles)
    #expect(loadedStyles.identity == identity)
    #expect(loadedStyles.state == .loaded)
    #expect(loadedStyles.sections.map(\.title) == ["body"])

    session.selectNode(rootID)
    #expect(session.selectedNodeStyles == nil)
}

@Test
@MainActor
func cssSessionBuildsOrderedSectionsAndPropertyRowState() throws {
    let css = CSSSession()
    let identity = cssIdentity()
    let token = try #require(css.beginRefresh(identity: identity))

    css.applyRefresh(
        token: token,
        matched: CSSStyle.MatchedStylesPayload(
            matchedRules: [
                CSSRule.MatchPayload(
                    rule: rule(
                        selector: "body",
                        properties: [
                            CSSProperty.Payload(name: "margin", value: "0", text: "margin: 0;", status: .active),
                            CSSProperty.Payload(name: "color", value: "red", text: "color: red;", status: .inactive),
                            CSSProperty.Payload(name: "display", value: "block", text: "/* display: block; */", status: .disabled),
                            CSSProperty.Payload(name: "box-sizing", value: "border-box", text: "box-sizing: border-box;"),
                        ],
                        cssText: """
                        margin: 0;
                        color: red;
                        /* display: block; */
                        box-sizing: border-box;
                        """
                    ),
                    matchingSelectors: [0]
                ),
            ]
        ),
        inline: CSSStyle.InlineStylesPayload(
            inlineStyle: style(
                id: CSSStyle.ID(styleSheetID: .init("inline"), ordinal: 0),
                properties: [
                    CSSProperty.Payload(name: "padding", value: "4px", text: "padding: 4px;"),
                ]
            ),
            attributesStyle: style(properties: [
                CSSProperty.Payload(name: "width", value: "100", text: "width: 100;"),
            ])
        ),
        computed: [
            CSSComputedStyleProperty.Payload(name: "display", value: "block"),
        ]
    )

    let selected = try #require(css.selectedNodeStyles)
    #expect(css.selectedState == .loaded)
    #expect(selected.sections.map(\.kind) == [.inlineStyle, .rule, .attributesStyle])
    #expect(selected.sections[0].title == "element.style")
    #expect(selected.sections[1].title == "body")
    #expect(selected.sections[2].isEditable == false)
    #expect(selected.computedProperties == [CSSComputedStyleProperty(name: "display", value: "block")])

    let properties = selected.sections[1].style.cssProperties
    #expect(properties[0].isEnabled)
    #expect(properties[0].isOverridden == false)
    #expect(properties[1].isOverridden)
    #expect(properties[2].isEnabled == false)
    #expect(properties[3].isEnabled)
    #expect(properties[0].isEditable)
    #expect(properties[1].isEditable == false)
    #expect(properties[2].isEditable)
}

@Test
@MainActor
func cssRuleSourceLocationPrefersSelectorRangeOverSourceLine() throws {
    let css = CSSSession()
    let identity = cssIdentity()
    let token = try #require(css.beginRefresh(identity: identity))

    css.applyRefresh(
        token: token,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: ".result-card",
                    sourceURL: "https://styles.example/assets/result-card.css",
                    sourceLine: 4,
                    selectorRange: CSSStyle.SourceRange(startLine: 27, startColumn: 22164, endLine: 27, endColumn: 22176),
                    properties: [
                        CSSProperty.Payload(name: "display", value: "flex", text: "display: flex;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    let section = try #require(css.selectedNodeStyles?.sections.first)
    let rule = try #require(section.rule)
    #expect(section.title == ".result-card")
    #expect(rule.sourceURL == "https://styles.example/assets/result-card.css")
    #expect(rule.sourceLocation == CSSRule.SourceLocation(
        sourceURL: "https://styles.example/assets/result-card.css",
        line: 27,
        column: 22164
    ))
}

@Test
@MainActor
func cssRuleSourceLocationFallsBackToSourceLineWhenSelectorRangeIsMissing() throws {
    let css = CSSSession()
    let identity = cssIdentity()
    let token = try #require(css.beginRefresh(identity: identity))

    css.applyRefresh(
        token: token,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: "body",
                    sourceURL: "styles.css",
                    sourceLine: 11,
                    properties: [
                        CSSProperty.Payload(name: "margin", value: "0", text: "margin: 0;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    let rule = try #require(css.selectedNodeStyles?.sections.first?.rule)
    #expect(rule.sourceLocation == CSSRule.SourceLocation(sourceURL: "styles.css", line: 11))
}

@Test
@MainActor
func cssRuleSourceLocationAppliesStyleSheetHeaderOffset() throws {
    let css = CSSSession()
    let identity = cssIdentity()
    css.registerStyleSheetHeader(
        CSSStyleSheet.HeaderPayload(
            styleSheetID: .init("sheet"),
            sourceURL: "https://example.com/document.html",
            origin: .author,
            isInline: true,
            startLine: 18,
            startColumn: 6
        ),
        targetID: identity.targetID
    )
    let token = try #require(css.beginRefresh(identity: identity))

    css.applyRefresh(
        token: token,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: ".inline-rule",
                    sourceLine: 2,
                    selectorRange: CSSStyle.SourceRange(startLine: 0, startColumn: 4, endLine: 0, endColumn: 16),
                    properties: [
                        CSSProperty.Payload(name: "color", value: "red", text: "color: red;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    let rule = try #require(css.selectedNodeStyles?.sections.first?.rule)
    #expect(rule.sourceLocation == CSSRule.SourceLocation(
        sourceURL: "https://example.com/document.html",
        line: 18,
        column: 10
    ))
}

@Test
@MainActor
func cssRuleSourceLocationKeepsSubsequentLineColumnsRelativeToLineStart() throws {
    let css = CSSSession()
    let identity = cssIdentity()
    css.registerStyleSheetHeader(
        CSSStyleSheet.HeaderPayload(
            styleSheetID: .init("sheet"),
            sourceURL: "https://example.com/document.html",
            origin: .author,
            isInline: true,
            startLine: 18,
            startColumn: 6
        ),
        targetID: identity.targetID
    )
    let token = try #require(css.beginRefresh(identity: identity))

    css.applyRefresh(
        token: token,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: ".later-rule",
                    selectorRange: CSSStyle.SourceRange(startLine: 3, startColumn: 4, endLine: 3, endColumn: 15),
                    properties: [
                        CSSProperty.Payload(name: "color", value: "blue", text: "color: blue;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    let rule = try #require(css.selectedNodeStyles?.sections.first?.rule)
    #expect(rule.sourceLocation == CSSRule.SourceLocation(
        sourceURL: "https://example.com/document.html",
        line: 21,
        column: 4
    ))
}

@Test
@MainActor
func cssRuleSourceLocationScopesStyleSheetHeadersByTarget() throws {
    let css = CSSSession()
    let pageIdentity = cssIdentity(targetID: .init("page"), nodeRawID: 2)
    let frameIdentity = cssIdentity(targetID: .init("frame"), nodeRawID: 3)
    css.registerStyleSheetHeader(
        CSSStyleSheet.HeaderPayload(
            styleSheetID: .init("sheet"),
            sourceURL: "https://example.com/page.html",
            origin: .author,
            isInline: true,
            startLine: 10,
            startColumn: 1
        ),
        targetID: pageIdentity.targetID
    )
    css.registerStyleSheetHeader(
        CSSStyleSheet.HeaderPayload(
            styleSheetID: .init("sheet"),
            sourceURL: "https://example.com/frame.html",
            origin: .author,
            isInline: true,
            startLine: 30,
            startColumn: 2
        ),
        targetID: frameIdentity.targetID
    )
    css.removeStyleSheetHeader(styleSheetID: .init("sheet"), targetID: frameIdentity.targetID)

    let token = try #require(css.beginRefresh(identity: pageIdentity))
    css.applyRefresh(
        token: token,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: ".target-rule",
                    selectorRange: CSSStyle.SourceRange(startLine: 0, startColumn: 4, endLine: 0, endColumn: 16),
                    properties: [
                        CSSProperty.Payload(name: "display", value: "block", text: "display: block;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    let rule = try #require(css.selectedNodeStyles?.sections.first?.rule)
    #expect(rule.sourceLocation == CSSRule.SourceLocation(
        sourceURL: "https://example.com/page.html",
        line: 10,
        column: 5
    ))
}

@Test
@MainActor
func cssSessionRemovesStyleSheetHeadersEvenWhenTargetHasNoCachedStyles() throws {
    let css = CSSSession()
    let identity = cssIdentity()
    css.registerStyleSheetHeader(
        CSSStyleSheet.HeaderPayload(
            styleSheetID: .init("sheet"),
            sourceURL: "https://example.com/stale.html",
            origin: .author,
            isInline: true,
            startLine: 10,
            startColumn: 1
        ),
        targetID: identity.targetID
    )
    css.removeStyles(targetID: identity.targetID)

    let token = try #require(css.beginRefresh(identity: identity))
    css.applyRefresh(
        token: token,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: ".fresh-rule",
                    selectorRange: CSSStyle.SourceRange(startLine: 0, startColumn: 4, endLine: 0, endColumn: 15),
                    properties: [
                        CSSProperty.Payload(name: "display", value: "block", text: "display: block;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    let rule = try #require(css.selectedNodeStyles?.sections.first?.rule)
    #expect(rule.sourceLocation == nil)
}

@Test
@MainActor
func cssSessionPreservesObservableStyleObjectsWhenRefreshingSameRows() throws {
    let css = CSSSession()
    let identity = cssIdentity()
    let styleID = CSSStyle.ID(styleSheetID: .init("sheet"), ordinal: 0)
    let token = try #require(css.beginRefresh(identity: identity))

    css.applyRefresh(
        token: token,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: "body",
                    styleID: styleID,
                    properties: [
                        CSSProperty.Payload(name: "margin", value: "0", text: "margin: 0;", status: .active),
                        CSSProperty.Payload(name: "box-sizing", value: "border-box", text: "box-sizing: border-box;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: [
            CSSComputedStyleProperty.Payload(name: "display", value: "block"),
        ]
    )

    let styles = try #require(css.selectedNodeStyles)
    let section = styles.sections[0]
    let style = section.style
    let margin = style.cssProperties[0]
    let boxSizing = style.cssProperties[1]
    let computedDisplay = styles.computedProperties[0]

    let refreshToken = try #require(css.beginRefresh(identity: identity))
    css.applyRefresh(
        token: refreshToken,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: "body",
                    styleID: styleID,
                    properties: [
                        CSSProperty.Payload(name: "margin", value: "4px", text: "margin: 4px;", status: .active),
                        CSSProperty.Payload(name: "box-sizing", value: "border-box", text: "/* box-sizing: border-box; */", status: .disabled),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: [
            CSSComputedStyleProperty.Payload(name: "display", value: "inline"),
        ]
    )

    #expect(styles.sections[0] === section)
    #expect(styles.sections[0].style === style)
    #expect(styles.sections[0].style.cssProperties[0] === margin)
    #expect(styles.sections[0].style.cssProperties[1] === boxSizing)
    #expect(styles.computedProperties[0] === computedDisplay)
    #expect(margin.value == "4px")
    #expect(boxSizing.status == .disabled)
    #expect(computedDisplay.value == "inline")
}

@Test
@MainActor
func cssSessionRendersMatchedRulesInCascadeOrder() throws {
    let css = CSSSession()
    let identity = cssIdentity()
    let token = try #require(css.beginRefresh(identity: identity))
    css.applyRefresh(
        token: token,
        matched: CSSStyle.MatchedStylesPayload(
            matchedRules: [
                CSSRule.MatchPayload(
                    rule: rule(selector: ".base", styleID: .init(styleSheetID: .init("base"), ordinal: 0), properties: [
                        CSSProperty.Payload(name: "color", value: "black", text: "color: black;"),
                    ]),
                    matchingSelectors: [0]
                ),
                CSSRule.MatchPayload(
                    rule: rule(selector: ".specific", styleID: .init(styleSheetID: .init("specific"), ordinal: 1), properties: [
                        CSSProperty.Payload(name: "color", value: "red", text: "color: red;"),
                    ]),
                    matchingSelectors: [0]
                ),
            ],
            inherited: [
                CSSStyle.InheritedStyleEntry(matchedRules: [
                    CSSRule.MatchPayload(
                        rule: rule(selector: ".ancestor-base", styleID: .init(styleSheetID: .init("ancestor-base"), ordinal: 0), properties: [
                            CSSProperty.Payload(name: "font", value: "inherit", text: "font: inherit;"),
                        ]),
                        matchingSelectors: [0]
                    ),
                    CSSRule.MatchPayload(
                        rule: rule(selector: ".ancestor-specific", styleID: .init(styleSheetID: .init("ancestor-specific"), ordinal: 1), properties: [
                            CSSProperty.Payload(name: "font", value: "system", text: "font: system;"),
                        ]),
                        matchingSelectors: [0]
                    ),
                ]),
            ]
        ),
        inline: .init(),
        computed: []
    )

    let styles = try #require(css.selectedNodeStyles)
    #expect(styles.sections.map(\.title) == [
        ".specific",
        ".base",
        ".ancestor-specific",
        ".ancestor-base",
    ])
}

@Test
func cssSessionBuildsSetStyleTextIntentByCommentingAndUncommentingPropertyText() async throws {
    let css = await CSSSession()
    let identity = cssIdentity()
    let styleID = CSSStyle.ID(styleSheetID: .init("inline"), ordinal: 0)
    let token = try #require(await css.beginRefresh(identity: identity))
    await css.applyRefresh(
        token: token,
        matched: .init(),
        inline: CSSStyle.InlineStylesPayload(
            inlineStyle: style(
                id: styleID,
                properties: [
                    CSSProperty.Payload(name: "margin", value: "0", text: "margin: 0;", status: .active),
                    CSSProperty.Payload(name: "box-sizing", value: "border-box", text: "box-sizing: border-box;"),
                ]
            )
        ),
        computed: []
    )

    let disabledIntent = try #require(await css.setStyleTextIntent(
        for: CSSProperty.ID(styleID: styleID, propertyIndex: 0),
        enabled: false
    ))
    #expect(disabledIntent == .setStyleText(
        targetID: identity.targetID,
        styleID: styleID,
        text: "/* margin: 0; */\nbox-sizing: border-box;"
    ))

    let disabledStyleID = CSSStyle.ID(styleSheetID: .init("rule"), ordinal: 0)
    let disabledToken = try #require(await css.beginRefresh(identity: identity))
    await css.applyRefresh(
        token: disabledToken,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: "body",
                    styleID: disabledStyleID,
                    properties: [
                        CSSProperty.Payload(name: "margin", value: "0", text: "/* margin: 0; */", status: .disabled),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    let enabledIntent = try #require(await css.setStyleTextIntent(
        for: CSSProperty.ID(styleID: disabledStyleID, propertyIndex: 0),
        enabled: true
    ))
    #expect(enabledIntent == .setStyleText(targetID: identity.targetID, styleID: disabledStyleID, text: "margin: 0;"))
}

@Test
func cssSessionRewritesAuthoredStyleTextWithoutSerializingInactiveRows() async throws {
    let css = await CSSSession()
    let identity = cssIdentity()
    let styleID = CSSStyle.ID(styleSheetID: .init("sheet"), ordinal: 0)
    let token = try #require(await css.beginRefresh(identity: identity))
    await css.applyRefresh(
        token: token,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: "body",
                    styleID: styleID,
                    properties: [
                        CSSProperty.Payload(
                            name: "font-family",
                            value: "sans-serif",
                            text: "font-family: sans-serif;",
                            status: .active
                        ),
                        CSSProperty.Payload(
                            name: "font-size",
                            value: "10pt",
                            text: "font-size: 10pt;",
                            status: .active
                        ),
                        CSSProperty.Payload(
                            name: "font-size",
                            value: "12px",
                            text: "font-size: 12px;",
                            status: .inactive
                        ),
                    ],
                    cssText: "font-family: sans-serif;\nfont-size: 10pt;"
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    let intent = try #require(await css.setStyleTextIntent(
        for: CSSProperty.ID(styleID: styleID, propertyIndex: 1),
        enabled: false
    ))
    #expect(intent == .setStyleText(
        targetID: identity.targetID,
        styleID: styleID,
        text: "font-family: sans-serif;\n/* font-size: 10pt; */"
    ))
}

@Test
func cssSessionRewritesOnlyDeclarationMatchesOutsideStrings() async throws {
    let css = await CSSSession()
    let identity = cssIdentity()
    let styleID = CSSStyle.ID(styleSheetID: .init("sheet"), ordinal: 0)
    let token = try #require(await css.beginRefresh(identity: identity))
    await css.applyRefresh(
        token: token,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: "body::before",
                    styleID: styleID,
                    properties: [
                        CSSProperty.Payload(
                            name: "content",
                            value: #""color: red;""#,
                            text: #"content: "color: red;";"#,
                            status: .active
                        ),
                        CSSProperty.Payload(
                            name: "color",
                            value: "red",
                            text: "color: red;",
                            status: .active
                        ),
                    ],
                    cssText: """
                    content: "color: red;";
                    color: red;
                    """
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    let intent = try #require(await css.setStyleTextIntent(
        for: CSSProperty.ID(styleID: styleID, propertyIndex: 1),
        enabled: false
    ))
    #expect(intent == .setStyleText(
        targetID: identity.targetID,
        styleID: styleID,
        text: """
        content: "color: red;";
        /* color: red; */
        """
    ))
}

@Test
func cssSessionTreatsCommentsAsDeclarationBoundaries() async throws {
    let css = await CSSSession()
    let identity = cssIdentity()
    let beforeCommentStyleID = CSSStyle.ID(styleSheetID: .init("sheet"), ordinal: 0)
    let afterCommentStyleID = CSSStyle.ID(styleSheetID: .init("sheet"), ordinal: 1)
    let token = try #require(await css.beginRefresh(identity: identity))
    await css.applyRefresh(
        token: token,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: ".before-comment",
                    styleID: beforeCommentStyleID,
                    properties: [
                        CSSProperty.Payload(
                            name: "color",
                            value: "red",
                            text: "color: red;",
                            status: .active
                        ),
                    ],
                    cssText: """
                    /* note /* marker */
                    color: red;
                    """
                ),
                matchingSelectors: [0]
            ),
            CSSRule.MatchPayload(
                rule: rule(
                    selector: ".after-comment",
                    styleID: afterCommentStyleID,
                    properties: [
                        CSSProperty.Payload(
                            name: "color",
                            value: "red",
                            text: "color: red",
                            status: .active
                        ),
                    ],
                    cssText: "color: red /* note */;"
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    let beforeCommentIntent = try #require(await css.setStyleTextIntent(
        for: CSSProperty.ID(styleID: beforeCommentStyleID, propertyIndex: 0),
        enabled: false
    ))
    #expect(beforeCommentIntent == .setStyleText(
        targetID: identity.targetID,
        styleID: beforeCommentStyleID,
        text: """
        /* note /* marker */
        /* color: red; */
        """
    ))

    let afterCommentIntent = try #require(await css.setStyleTextIntent(
        for: CSSProperty.ID(styleID: afterCommentStyleID, propertyIndex: 0),
        enabled: false
    ))
    #expect(afterCommentIntent == .setStyleText(
        targetID: identity.targetID,
        styleID: afterCommentStyleID,
        text: "/* color: red */ /* note */;"
    ))
}

@Test
func cssSessionRejectsNonEditableToggleTargets() async throws {
    let css = await CSSSession()
    let identity = cssIdentity()
    let styleID = CSSStyle.ID(styleSheetID: .init("ua"), ordinal: 0)
    let token = try #require(await css.beginRefresh(identity: identity))
    await css.applyRefresh(
        token: token,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: "body",
                    styleID: styleID,
                    origin: .userAgent,
                    properties: [
                        CSSProperty.Payload(name: "display", value: "block", text: "display: block;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: CSSStyle.InlineStylesPayload(attributesStyle: style(properties: [
            CSSProperty.Payload(name: "width", value: "100", text: "width: 100;"),
        ])),
        computed: []
    )

    #expect(await css.setStyleTextIntent(
        for: CSSProperty.ID(styleID: styleID, propertyIndex: 0),
        enabled: false
    ) == nil)
}

@Test
@MainActor
func cssSessionDoesNotSynthesizeStyleTextWhenOtherPropertiesHaveNoAuthoredText() throws {
    let css = CSSSession()
    let identity = cssIdentity()
    let styleID = CSSStyle.ID(styleSheetID: .init("sheet"), ordinal: 0)
    let token = try #require(css.beginRefresh(identity: identity))
    css.applyRefresh(
        token: token,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: "body",
                    styleID: styleID,
                    properties: [
                        CSSProperty.Payload(name: "margin", value: "0", text: "margin: 0;"),
                        CSSProperty.Payload(name: "margin-top", value: "0", implicit: true),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    let styles = try #require(css.selectedNodeStyles)
    #expect(styles.sections[0].style.cssProperties[0].isEditable == false)
    #expect(css.setStyleTextIntent(
        for: CSSProperty.ID(styleID: styleID, propertyIndex: 0),
        enabled: false
    ) == nil)
}

@Test
@MainActor
func cssSessionInFlightRefreshWinsOverInvalidation() throws {
    let css = CSSSession()
    let identity = cssIdentity()
    let token = try #require(css.beginRefresh(identity: identity))

    css.markNeedsRefresh(targetID: identity.targetID)
    css.applyRefresh(
        token: token,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: "body",
                    properties: [
                        CSSProperty.Payload(name: "margin", value: "0", text: "margin: 0;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    #expect(css.selectedState == .loaded)
    #expect(css.selectedNodeStyles?.sections.map(\.title) == ["body"])
}

@Test
func cssSessionInvalidatesOnlyNodeStylesThatReferenceChangedStyleSheet() async throws {
    let css = await CSSSession()
    let identity = cssIdentity()
    let token = try #require(await css.beginRefresh(identity: identity))
    await css.applyRefresh(
        token: token,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: "body",
                    styleID: .init(styleSheetID: .init("tracked"), ordinal: 0),
                    properties: [
                        CSSProperty.Payload(name: "margin", value: "0", text: "margin: 0;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    await css.markNeedsRefresh(targetID: identity.targetID, styleSheetID: .init("untracked"))
    #expect(await css.selectedState == .loaded)

    await css.markNeedsRefresh(targetID: identity.targetID, styleSheetID: .init("tracked"))
    #expect(await css.selectedState == .needsRefresh)
}

@Test
func cssSessionRejectsEditIntentWhenSelectedStylesNeedRefresh() async throws {
    let css = await CSSSession()
    let identity = cssIdentity()
    let styleID = CSSStyle.ID(styleSheetID: .init("sheet"), ordinal: 0)
    let token = try #require(await css.beginRefresh(identity: identity))
    await css.applyRefresh(
        token: token,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: "body",
                    styleID: styleID,
                    properties: [
                        CSSProperty.Payload(name: "margin", value: "0", text: "margin: 0;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )
    #expect(await css.setStyleTextIntent(
        for: CSSProperty.ID(styleID: styleID, propertyIndex: 0),
        enabled: false
    ) != nil)

    await css.markNeedsRefresh(targetID: identity.targetID)

    #expect(await css.setStyleTextIntent(
        for: CSSProperty.ID(styleID: styleID, propertyIndex: 0),
        enabled: false
    ) == nil)
}

@Test
@MainActor
func cssSessionMarksSetStyleTextPropertyAsModifiedByInspector() throws {
    let css = CSSSession()
    let identity = cssIdentity()
    let styleID = CSSStyle.ID(styleSheetID: .init("sheet"), ordinal: 0)
    let propertyID = CSSProperty.ID(styleID: styleID, propertyIndex: 0)
    let token = try #require(css.beginRefresh(identity: identity))
    css.applyRefresh(
        token: token,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: "body",
                    styleID: styleID,
                    properties: [
                        CSSProperty.Payload(name: "margin", value: "0", text: "margin: 0;", status: .active),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    let property = try #require(css.selectedNodeStyles?.sections[0].style.cssProperties[0])
    #expect(property.isModifiedByInspector == false)

    css.applySetStyleTextResult(
        CSSStyle.Payload(id: styleID, cssProperties: [
            CSSProperty.Payload(name: "margin", value: "0", text: "/* margin: 0; */", status: .disabled),
        ]),
        propertyID: propertyID,
        targetID: identity.targetID
    )

    #expect(property.status == .disabled)
    #expect(property.isModifiedByInspector)

    let refreshToken = try #require(css.beginRefresh(identity: identity))
    css.applyRefresh(
        token: refreshToken,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: "body",
                    styleID: styleID,
                    properties: [
                        CSSProperty.Payload(name: "margin", value: "0", text: "/* margin: 0; */", status: .disabled),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    #expect(css.selectedState == .loaded)
    #expect(property.isModifiedByInspector)

    css.applySetStyleTextResult(
        CSSStyle.Payload(id: styleID, cssProperties: [
            CSSProperty.Payload(name: "margin", value: "0", text: "margin: 0;", status: .active),
        ]),
        propertyID: propertyID,
        targetID: identity.targetID
    )

    #expect(property.status == .active)
    #expect(property.isModifiedByInspector == false)
}

@Test
@MainActor
func cssSessionAppliesSetStyleTextResultOnlyToEditedTarget() throws {
    let css = CSSSession()
    let sharedStyleID = CSSStyle.ID(styleSheetID: .init("sheet"), ordinal: 0)
    let pageIdentity = cssIdentity(targetID: .init("page"), nodeRawID: 2)
    let frameIdentity = cssIdentity(targetID: .init("frame"), nodeRawID: 2)

    let pageToken = try #require(css.beginRefresh(identity: pageIdentity))
    css.applyRefresh(
        token: pageToken,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: "body",
                    styleID: sharedStyleID,
                    properties: [
                        CSSProperty.Payload(name: "margin", value: "0", text: "margin: 0;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    let frameToken = try #require(css.beginRefresh(identity: frameIdentity))
    css.applyRefresh(
        token: frameToken,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: "body",
                    styleID: sharedStyleID,
                    properties: [
                        CSSProperty.Payload(name: "margin", value: "10px", text: "margin: 10px;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    css.applySetStyleTextResult(
        CSSStyle.Payload(id: sharedStyleID, cssProperties: [
            CSSProperty.Payload(name: "margin", value: "0", text: "/* margin: 0; */", status: .disabled),
        ]),
        propertyID: CSSProperty.ID(styleID: sharedStyleID, propertyIndex: 0),
        targetID: pageIdentity.targetID
    )

    let selectedFrameStyles = try #require(css.selectedNodeStyles)
    #expect(css.selectedState == .loaded)
    #expect(selectedFrameStyles.identity.targetID == frameIdentity.targetID)
    #expect(selectedFrameStyles.sections[0].style.cssProperties[0].value == "10px")
}

@Test
@MainActor
func cssSessionClearsSelectedStylesWhenTargetBecomesStale() throws {
    let css = CSSSession()
    let identity = cssIdentity()
    let token = try #require(css.beginRefresh(identity: identity))
    css.applyRefresh(
        token: token,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: "body",
                    properties: [
                        CSSProperty.Payload(name: "margin", value: "0", text: "margin: 0;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )
    let selectedStyles = try #require(css.selectedNodeStyles)

    css.removeStyles(targetID: identity.targetID)

    #expect(css.selectedNodeStyles == nil)
    #expect(css.selectedState == .unavailable(.staleNode(identity.nodeID)))
    #expect(selectedStyles.state == .loaded)
    #expect(css.refreshState(forSelected: identity) == nil)
}

@Test
@MainActor
func cssSessionClearsSelectedStylesWhenCurrentStylesBecomeUnavailable() throws {
    let css = CSSSession()
    let identity = cssIdentity()
    let token = try #require(css.beginRefresh(identity: identity))
    css.applyRefresh(
        token: token,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: "body",
                    properties: [
                        CSSProperty.Payload(name: "margin", value: "0", text: "margin: 0;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )
    let selectedStyles = try #require(css.selectedNodeStyles)

    css.markSelectedNodeStylesUnavailable(identity: identity, reason: .staleNode(identity.nodeID))

    #expect(css.selectedNodeStyles == nil)
    #expect(css.selectedState == .unavailable(.staleNode(identity.nodeID)))
    #expect(selectedStyles.state == .unavailable(.staleNode(identity.nodeID)))
    #expect(css.refreshState(forSelected: identity) == .unavailable(.staleNode(identity.nodeID)))
}

@Test
@MainActor
func cssSessionDoesNotDisplayUnavailableStylesForUnselectedIdentity() throws {
    let css = CSSSession()
    let identity = cssIdentity()
    css.markSelectedNodeStylesUnavailable(identity: identity, reason: .staleNode(identity.nodeID))

    css.markSelectedNodeUnavailable(.noSelection)

    #expect(css.selectedNodeStyles == nil)
    #expect(css.selectedState == .unavailable(.noSelection))
    #expect(css.refreshState(forSelected: identity) == .unavailable(.staleNode(identity.nodeID)))
}

@Test
@MainActor
func cssSessionCancelsActiveRefreshBackToNeedsRefresh() throws {
    let css = CSSSession()
    let identity = cssIdentity()

    _ = try #require(css.beginRefresh(identity: identity))
    #expect(css.selectedState == .loading)

    css.cancelRefresh(identity: identity)

    #expect(css.selectedState == .needsRefresh)
    #expect(css.refreshState(forSelected: identity) == .needsRefresh)
}

@Test
@MainActor
func cssSessionIgnoresStaleRefreshCancellationAfterNewRefreshBegins() throws {
    let css = CSSSession()
    let identity = cssIdentity()

    let staleToken = try #require(css.beginRefresh(identity: identity))
    let currentToken = try #require(css.beginRefresh(identity: identity))

    css.cancelRefresh(staleToken)

    #expect(css.selectedState == .loading)
    #expect(css.refreshState(forSelected: identity) == .loading)

    css.cancelRefresh(currentToken)

    #expect(css.selectedState == .needsRefresh)
    #expect(css.refreshState(forSelected: identity) == .needsRefresh)
}

@Test
@MainActor
func cssSessionRefreshDoesNotRepublishCurrentSelectedNodeStyles() throws {
    let css = CSSSession()
    let identity = cssIdentity()
    css.selectNodeStyles(identity: identity)
    let selectedStyles = try #require(css.selectedNodeStyles)

    let selectedNodeStylesInvalidations = Mutex(0)
    withObservationTracking {
        _ = css.selectedNodeStyles
    } onChange: {
        selectedNodeStylesInvalidations.withLock { $0 += 1 }
    }

    let token = try #require(css.beginRefresh(identity: identity))

    #expect(css.selectedNodeStyles === selectedStyles)
    #expect(css.selectedState == .loading)
    #expect(selectedNodeStylesInvalidations.withLock { $0 } == 0)

    css.applyRefresh(
        token: token,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: rule(
                    selector: "body",
                    properties: [
                        CSSProperty.Payload(name: "margin", value: "0", text: "margin: 0;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    #expect(css.selectedNodeStyles === selectedStyles)
    #expect(css.selectedState == .loaded)
    #expect(selectedNodeStylesInvalidations.withLock { $0 } == 0)
}

private func cssIdentity(
    targetID: ProtocolTarget.ID = ProtocolTarget.ID("page"),
    nodeRawID: Int = 2
) -> CSSNodeStyles.Identity {
    let documentID = DOMDocument.ID(targetID: targetID, localDocumentLifetimeID: .init(1))
    return CSSNodeStyles.Identity(
        nodeID: DOMNode.ID(documentID: documentID, nodeID: .init(nodeRawID)),
        targetID: targetID,
        documentID: documentID,
        protocolNodeID: .init(nodeRawID),
        targetCapabilities: [.css, .dom]
    )
}

private func rule(
    selector: String,
    styleID: CSSStyle.ID = CSSStyle.ID(styleSheetID: .init("sheet"), ordinal: 0),
    origin: CSSStyle.Origin = .author,
    sourceURL: String? = nil,
    sourceLine: Int = 1,
    selectorRange: CSSStyle.SourceRange? = nil,
    properties: [CSSProperty.Payload],
    cssText: String? = nil
) -> CSSRule.Payload {
    CSSRule.Payload(
        id: CSSRule.ID(styleSheetID: styleID.styleSheetID, ordinal: styleID.ordinal),
        selectorList: CSSRule.SelectorList(selectors: [CSSRule.Selector(text: selector)], text: selector, range: selectorRange),
        sourceURL: sourceURL,
        sourceLine: sourceLine,
        origin: origin,
        style: style(id: styleID, properties: properties, cssText: cssText)
    )
}

private func style(
    id: CSSStyle.ID? = nil,
    properties: [CSSProperty.Payload],
    cssText: String? = nil
) -> CSSStyle.Payload {
    CSSStyle.Payload(id: id, cssProperties: properties, cssText: cssText)
}

private extension Result {
    var successValue: Success? {
        if case let .success(value) = self {
            return value
        }
        return nil
    }

    var failureValue: Failure? {
        if case let .failure(value) = self {
            return value
        }
        return nil
    }
}
