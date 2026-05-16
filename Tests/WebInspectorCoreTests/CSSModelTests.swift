import Testing
@testable import WebInspectorCore

@Test
func protocolTargetCapabilitiesRequireExplicitCSSDomainParsing() {
    #expect(ProtocolTargetCapabilities.pageDefault.contains(.css) == false)
    #expect(ProtocolTargetCapabilities.protocolDefault(for: .page).contains(.css) == false)
    #expect(ProtocolTargetCapabilities.protocolDefault(for: .frame).contains(.css) == false)
    #expect(ProtocolTargetCapabilities(domainNames: ["DOM", "CSS"]).contains(.css))
}

@Test
func selectedCSSNodeStyleIdentityRequiresElementCurrentNodeAndCSSTarget() async throws {
    let pageTargetID = ProtocolTargetIdentifier("page")
    let session = await DOMSession()
    await session.applyTargetCreated(
        .init(id: pageTargetID, kind: .page, capabilities: [.dom, .css]),
        makeCurrentMainPage: true
    )
    let rootID = await session.replaceDocumentRoot(
        DOMNodePayload(
            nodeID: .init(1),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                DOMNodePayload(nodeID: .init(2), nodeType: .element, nodeName: "BODY", localName: "body"),
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
        DOMNodePayload(
            nodeID: .init(1),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                DOMNodePayload(nodeID: .init(2), nodeType: .element, nodeName: "BODY", localName: "body"),
            ])
        ),
        targetID: .init("plain")
    )
    let plainDocumentID = plainRootID.documentID
    let plainBodyID = DOMNodeIdentifier(documentID: plainDocumentID, nodeID: .init(2))
    await session.selectNode(plainBodyID)
    #expect(await session.selectedCSSNodeStyleIdentity().failureValue == .cssUnavailableForTarget(.init("plain")))

    let staleNodeID = DOMNodeIdentifier(documentID: plainDocumentID, nodeID: .init(999))
    #expect(await session.cssNodeStyleIdentity(for: staleNodeID).failureValue == .staleNode(staleNodeID))
}

@Test
func cssSessionBuildsOrderedSectionsAndPropertyRowState() async throws {
    let css = await CSSSession()
    let identity = cssIdentity()
    let token = try #require(await css.beginRefresh(identity: identity))

    await css.applyRefresh(
        token: token,
        matched: CSSMatchedStylesPayload(
            matchedRules: [
                CSSRuleMatch(
                    rule: rule(
                        selector: "body",
                        properties: [
                            CSSProperty(name: "margin", value: "0", text: "margin: 0;", status: .active),
                            CSSProperty(name: "color", value: "red", text: "color: red;", status: .inactive),
                            CSSProperty(name: "display", value: "block", text: "/* display: block; */", status: .disabled),
                            CSSProperty(name: "box-sizing", value: "border-box", text: "box-sizing: border-box;"),
                        ]
                    ),
                    matchingSelectors: [0]
                ),
            ]
        ),
        inline: CSSInlineStylesPayload(
            inlineStyle: style(
                id: CSSStyleIdentifier(styleSheetID: .init("inline"), ordinal: 0),
                properties: [
                    CSSProperty(name: "padding", value: "4px", text: "padding: 4px;"),
                ]
            ),
            attributesStyle: style(properties: [
                CSSProperty(name: "width", value: "100", text: "width: 100;"),
            ])
        ),
        computed: [
            CSSComputedStyleProperty(name: "display", value: "block"),
        ]
    )

    let selected = try #require(await css.selectedNodeStyles)
    #expect(await css.selectedState == .loaded)
    #expect(await selected.sections.map(\.kind) == [.inlineStyle, .rule, .attributesStyle])
    #expect(await selected.sections[0].title == "element.style")
    #expect(await selected.sections[1].title == "body")
    #expect(await selected.sections[2].isEditable == false)
    #expect(await selected.computedProperties == [CSSComputedStyleProperty(name: "display", value: "block")])

    let properties = await selected.sections[1].style.cssProperties
    #expect(properties[0].isEnabled)
    #expect(properties[0].isOverridden == false)
    #expect(properties[1].isOverridden)
    #expect(properties[2].isEnabled == false)
    #expect(properties[3].isEnabled)
    #expect(properties[0].isEditable)
    #expect(properties[2].isEditable)
}

@Test
func cssSessionRendersMatchedRulesInCascadeOrder() async throws {
    let css = await CSSSession()
    let identity = cssIdentity()
    let token = try #require(await css.beginRefresh(identity: identity))
    await css.applyRefresh(
        token: token,
        matched: CSSMatchedStylesPayload(
            matchedRules: [
                CSSRuleMatch(
                    rule: rule(selector: ".base", styleID: .init(styleSheetID: .init("base"), ordinal: 0), properties: [
                        CSSProperty(name: "color", value: "black", text: "color: black;"),
                    ]),
                    matchingSelectors: [0]
                ),
                CSSRuleMatch(
                    rule: rule(selector: ".specific", styleID: .init(styleSheetID: .init("specific"), ordinal: 1), properties: [
                        CSSProperty(name: "color", value: "red", text: "color: red;"),
                    ]),
                    matchingSelectors: [0]
                ),
            ],
            inherited: [
                CSSInheritedStyleEntry(matchedRules: [
                    CSSRuleMatch(
                        rule: rule(selector: ".ancestor-base", styleID: .init(styleSheetID: .init("ancestor-base"), ordinal: 0), properties: [
                            CSSProperty(name: "font", value: "inherit", text: "font: inherit;"),
                        ]),
                        matchingSelectors: [0]
                    ),
                    CSSRuleMatch(
                        rule: rule(selector: ".ancestor-specific", styleID: .init(styleSheetID: .init("ancestor-specific"), ordinal: 1), properties: [
                            CSSProperty(name: "font", value: "system", text: "font: system;"),
                        ]),
                        matchingSelectors: [0]
                    ),
                ]),
            ]
        ),
        inline: .init(),
        computed: []
    )

    let styles = try #require(await css.selectedNodeStyles)
    #expect(await styles.sections.map(\.title) == [
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
    let styleID = CSSStyleIdentifier(styleSheetID: .init("inline"), ordinal: 0)
    let token = try #require(await css.beginRefresh(identity: identity))
    await css.applyRefresh(
        token: token,
        matched: .init(),
        inline: CSSInlineStylesPayload(
            inlineStyle: style(
                id: styleID,
                properties: [
                    CSSProperty(name: "margin", value: "0", text: "margin: 0;", status: .active),
                    CSSProperty(name: "box-sizing", value: "border-box", text: "box-sizing: border-box;"),
                ]
            )
        ),
        computed: []
    )

    let disabledIntent = try #require(await css.setStyleTextIntent(
        for: CSSPropertyIdentifier(styleID: styleID, propertyIndex: 0),
        enabled: false
    ))
    #expect(disabledIntent == .setStyleText(
        targetID: identity.targetID,
        styleID: styleID,
        text: "/* margin: 0; */\nbox-sizing: border-box;"
    ))

    let disabledStyleID = CSSStyleIdentifier(styleSheetID: .init("rule"), ordinal: 0)
    let disabledToken = try #require(await css.beginRefresh(identity: identity))
    await css.applyRefresh(
        token: disabledToken,
        matched: CSSMatchedStylesPayload(matchedRules: [
            CSSRuleMatch(
                rule: rule(
                    selector: "body",
                    styleID: disabledStyleID,
                    properties: [
                        CSSProperty(name: "margin", value: "0", text: "/* margin: 0; */", status: .disabled),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    let enabledIntent = try #require(await css.setStyleTextIntent(
        for: CSSPropertyIdentifier(styleID: disabledStyleID, propertyIndex: 0),
        enabled: true
    ))
    #expect(enabledIntent == .setStyleText(targetID: identity.targetID, styleID: disabledStyleID, text: "margin: 0;"))
}

@Test
func cssSessionRejectsNonEditableToggleTargets() async throws {
    let css = await CSSSession()
    let identity = cssIdentity()
    let styleID = CSSStyleIdentifier(styleSheetID: .init("ua"), ordinal: 0)
    let token = try #require(await css.beginRefresh(identity: identity))
    await css.applyRefresh(
        token: token,
        matched: CSSMatchedStylesPayload(matchedRules: [
            CSSRuleMatch(
                rule: rule(
                    selector: "body",
                    styleID: styleID,
                    origin: .userAgent,
                    properties: [
                        CSSProperty(name: "display", value: "block", text: "display: block;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: CSSInlineStylesPayload(attributesStyle: style(properties: [
            CSSProperty(name: "width", value: "100", text: "width: 100;"),
        ])),
        computed: []
    )

    #expect(await css.setStyleTextIntent(
        for: CSSPropertyIdentifier(styleID: styleID, propertyIndex: 0),
        enabled: false
    ) == nil)
}

@Test
func cssSessionDoesNotSynthesizeStyleTextWhenOtherPropertiesHaveNoAuthoredText() async throws {
    let css = await CSSSession()
    let identity = cssIdentity()
    let styleID = CSSStyleIdentifier(styleSheetID: .init("sheet"), ordinal: 0)
    let token = try #require(await css.beginRefresh(identity: identity))
    await css.applyRefresh(
        token: token,
        matched: CSSMatchedStylesPayload(matchedRules: [
            CSSRuleMatch(
                rule: rule(
                    selector: "body",
                    styleID: styleID,
                    properties: [
                        CSSProperty(name: "margin", value: "0", text: "margin: 0;"),
                        CSSProperty(name: "margin-top", value: "0", implicit: true),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    let styles = try #require(await css.selectedNodeStyles)
    #expect(await styles.sections[0].style.cssProperties[0].isEditable == false)
    #expect(await css.setStyleTextIntent(
        for: CSSPropertyIdentifier(styleID: styleID, propertyIndex: 0),
        enabled: false
    ) == nil)
}

@Test
func cssSessionInFlightRefreshWinsOverInvalidation() async throws {
    let css = await CSSSession()
    let identity = cssIdentity()
    let token = try #require(await css.beginRefresh(identity: identity))

    await css.markNeedsRefresh(targetID: identity.targetID)
    await css.applyRefresh(
        token: token,
        matched: CSSMatchedStylesPayload(matchedRules: [
            CSSRuleMatch(
                rule: rule(
                    selector: "body",
                    properties: [
                        CSSProperty(name: "margin", value: "0", text: "margin: 0;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    #expect(await css.selectedState == .loaded)
    #expect(await css.selectedNodeStyles?.sections.map(\.title) == ["body"])
}

@Test
func cssSessionRejectsEditIntentWhenSelectedStylesNeedRefresh() async throws {
    let css = await CSSSession()
    let identity = cssIdentity()
    let styleID = CSSStyleIdentifier(styleSheetID: .init("sheet"), ordinal: 0)
    let token = try #require(await css.beginRefresh(identity: identity))
    await css.applyRefresh(
        token: token,
        matched: CSSMatchedStylesPayload(matchedRules: [
            CSSRuleMatch(
                rule: rule(
                    selector: "body",
                    styleID: styleID,
                    properties: [
                        CSSProperty(name: "margin", value: "0", text: "margin: 0;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )
    #expect(await css.setStyleTextIntent(
        for: CSSPropertyIdentifier(styleID: styleID, propertyIndex: 0),
        enabled: false
    ) != nil)

    await css.markNeedsRefresh(targetID: identity.targetID)

    #expect(await css.setStyleTextIntent(
        for: CSSPropertyIdentifier(styleID: styleID, propertyIndex: 0),
        enabled: false
    ) == nil)
}

@Test
func cssSessionAppliesSetStyleTextResultOnlyToEditedTarget() async throws {
    let css = await CSSSession()
    let sharedStyleID = CSSStyleIdentifier(styleSheetID: .init("sheet"), ordinal: 0)
    let pageIdentity = cssIdentity(targetID: .init("page"), nodeRawID: 2)
    let frameIdentity = cssIdentity(targetID: .init("frame"), nodeRawID: 2)

    let pageToken = try #require(await css.beginRefresh(identity: pageIdentity))
    await css.applyRefresh(
        token: pageToken,
        matched: CSSMatchedStylesPayload(matchedRules: [
            CSSRuleMatch(
                rule: rule(
                    selector: "body",
                    styleID: sharedStyleID,
                    properties: [
                        CSSProperty(name: "margin", value: "0", text: "margin: 0;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    let frameToken = try #require(await css.beginRefresh(identity: frameIdentity))
    await css.applyRefresh(
        token: frameToken,
        matched: CSSMatchedStylesPayload(matchedRules: [
            CSSRuleMatch(
                rule: rule(
                    selector: "body",
                    styleID: sharedStyleID,
                    properties: [
                        CSSProperty(name: "margin", value: "10px", text: "margin: 10px;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    await css.applySetStyleTextResult(
        CSSStyle(id: sharedStyleID, cssProperties: [
            CSSProperty(name: "margin", value: "0", text: "/* margin: 0; */", status: .disabled),
        ]),
        styleID: sharedStyleID,
        targetID: pageIdentity.targetID
    )

    let selectedFrameStyles = try #require(await css.selectedNodeStyles)
    #expect(await css.selectedState == .loaded)
    #expect(await selectedFrameStyles.identity.targetID == frameIdentity.targetID)
    #expect(await selectedFrameStyles.sections[0].style.cssProperties[0].value == "10px")
}

private func cssIdentity(
    targetID: ProtocolTargetIdentifier = ProtocolTargetIdentifier("page"),
    nodeRawID: Int = 2
) -> CSSNodeStyleIdentity {
    let documentID = DOMDocumentIdentifier(targetID: targetID, localDocumentLifetimeID: .init(1))
    return CSSNodeStyleIdentity(
        nodeID: DOMNodeIdentifier(documentID: documentID, nodeID: .init(nodeRawID)),
        targetID: targetID,
        documentID: documentID,
        protocolNodeID: .init(nodeRawID),
        targetCapabilities: [.css, .dom]
    )
}

private func rule(
    selector: String,
    styleID: CSSStyleIdentifier = CSSStyleIdentifier(styleSheetID: .init("sheet"), ordinal: 0),
    origin: CSSStyleOrigin = .author,
    properties: [CSSProperty]
) -> CSSRule {
    CSSRule(
        id: CSSRuleIdentifier(styleSheetID: styleID.styleSheetID, ordinal: styleID.ordinal),
        selectorList: CSSSelectorList(selectors: [CSSSelector(text: selector)], text: selector),
        sourceLine: 1,
        origin: origin,
        style: style(id: styleID, properties: properties)
    )
}

private func style(
    id: CSSStyleIdentifier? = nil,
    properties: [CSSProperty]
) -> CSSStyle {
    CSSStyle(id: id, cssProperties: properties)
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
