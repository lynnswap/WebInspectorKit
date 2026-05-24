import Testing
@testable import WebInspectorCore

@Test
func protocolTargetCapabilitiesTreatPageTargetsAsCSSCapable() {
    #expect(ProtocolTargetKind(protocolType: "web-page") == .page)
    #expect(ProtocolTargetCapabilities.pageDefault.contains(.css))
    #expect(ProtocolTargetCapabilities.protocolDefault(for: .page).contains(.css))
    #expect(ProtocolTargetCapabilities.protocolDefault(for: .frame).contains(.css) == false)
    #expect(ProtocolTargetCapabilities(domainNames: ["DOM", "CSS"]).contains(.css))
    #expect(ProtocolTargetCapabilities.resolved(for: .page, domainNames: ["DOM"]).contains(.css))
    #expect(ProtocolTargetCapabilities.resolved(for: .frame, domainNames: ["DOM"]).contains(.css) == false)
}

@Test
func selectedCSSNodeStyleIdentityRequiresElementCurrentNodeAndCSSTarget() async throws {
    let pageTargetID = ProtocolTargetIdentifier("page")
    let session = await DOMSession()
    await session.applyTargetCreated(
        .init(id: pageTargetID, kind: .page),
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
@MainActor
func cssSessionBuildsOrderedSectionsAndPropertyRowState() throws {
    let css = CSSSession()
    let identity = cssIdentity()
    let token = try #require(css.beginRefresh(identity: identity))

    css.applyRefresh(
        token: token,
        matched: CSSMatchedStylesPayload(
            matchedRules: [
                CSSRuleMatchPayload(
                    rule: rule(
                        selector: "body",
                        properties: [
                            CSSPropertyPayload(name: "margin", value: "0", text: "margin: 0;", status: .active),
                            CSSPropertyPayload(name: "color", value: "red", text: "color: red;", status: .inactive),
                            CSSPropertyPayload(name: "display", value: "block", text: "/* display: block; */", status: .disabled),
                            CSSPropertyPayload(name: "box-sizing", value: "border-box", text: "box-sizing: border-box;"),
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
        inline: CSSInlineStylesPayload(
            inlineStyle: style(
                id: CSSStyleIdentifier(styleSheetID: .init("inline"), ordinal: 0),
                properties: [
                    CSSPropertyPayload(name: "padding", value: "4px", text: "padding: 4px;"),
                ]
            ),
            attributesStyle: style(properties: [
                CSSPropertyPayload(name: "width", value: "100", text: "width: 100;"),
            ])
        ),
        computed: [
            CSSComputedStylePropertyPayload(name: "display", value: "block"),
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
func cssSessionPreservesObservableStyleObjectsWhenRefreshingSameRows() throws {
    let css = CSSSession()
    let identity = cssIdentity()
    let styleID = CSSStyleIdentifier(styleSheetID: .init("sheet"), ordinal: 0)
    let token = try #require(css.beginRefresh(identity: identity))

    css.applyRefresh(
        token: token,
        matched: CSSMatchedStylesPayload(matchedRules: [
            CSSRuleMatchPayload(
                rule: rule(
                    selector: "body",
                    styleID: styleID,
                    properties: [
                        CSSPropertyPayload(name: "margin", value: "0", text: "margin: 0;", status: .active),
                        CSSPropertyPayload(name: "box-sizing", value: "border-box", text: "box-sizing: border-box;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: [
            CSSComputedStylePropertyPayload(name: "display", value: "block"),
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
        matched: CSSMatchedStylesPayload(matchedRules: [
            CSSRuleMatchPayload(
                rule: rule(
                    selector: "body",
                    styleID: styleID,
                    properties: [
                        CSSPropertyPayload(name: "margin", value: "4px", text: "margin: 4px;", status: .active),
                        CSSPropertyPayload(name: "box-sizing", value: "border-box", text: "/* box-sizing: border-box; */", status: .disabled),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: [
            CSSComputedStylePropertyPayload(name: "display", value: "inline"),
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
        matched: CSSMatchedStylesPayload(
            matchedRules: [
                CSSRuleMatchPayload(
                    rule: rule(selector: ".base", styleID: .init(styleSheetID: .init("base"), ordinal: 0), properties: [
                        CSSPropertyPayload(name: "color", value: "black", text: "color: black;"),
                    ]),
                    matchingSelectors: [0]
                ),
                CSSRuleMatchPayload(
                    rule: rule(selector: ".specific", styleID: .init(styleSheetID: .init("specific"), ordinal: 1), properties: [
                        CSSPropertyPayload(name: "color", value: "red", text: "color: red;"),
                    ]),
                    matchingSelectors: [0]
                ),
            ],
            inherited: [
                CSSInheritedStyleEntry(matchedRules: [
                    CSSRuleMatchPayload(
                        rule: rule(selector: ".ancestor-base", styleID: .init(styleSheetID: .init("ancestor-base"), ordinal: 0), properties: [
                            CSSPropertyPayload(name: "font", value: "inherit", text: "font: inherit;"),
                        ]),
                        matchingSelectors: [0]
                    ),
                    CSSRuleMatchPayload(
                        rule: rule(selector: ".ancestor-specific", styleID: .init(styleSheetID: .init("ancestor-specific"), ordinal: 1), properties: [
                            CSSPropertyPayload(name: "font", value: "system", text: "font: system;"),
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
    let styleID = CSSStyleIdentifier(styleSheetID: .init("inline"), ordinal: 0)
    let token = try #require(await css.beginRefresh(identity: identity))
    await css.applyRefresh(
        token: token,
        matched: .init(),
        inline: CSSInlineStylesPayload(
            inlineStyle: style(
                id: styleID,
                properties: [
                    CSSPropertyPayload(name: "margin", value: "0", text: "margin: 0;", status: .active),
                    CSSPropertyPayload(name: "box-sizing", value: "border-box", text: "box-sizing: border-box;"),
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
            CSSRuleMatchPayload(
                rule: rule(
                    selector: "body",
                    styleID: disabledStyleID,
                    properties: [
                        CSSPropertyPayload(name: "margin", value: "0", text: "/* margin: 0; */", status: .disabled),
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
func cssSessionRewritesAuthoredStyleTextWithoutSerializingInactiveRows() async throws {
    let css = await CSSSession()
    let identity = cssIdentity()
    let styleID = CSSStyleIdentifier(styleSheetID: .init("sheet"), ordinal: 0)
    let token = try #require(await css.beginRefresh(identity: identity))
    await css.applyRefresh(
        token: token,
        matched: CSSMatchedStylesPayload(matchedRules: [
            CSSRuleMatchPayload(
                rule: rule(
                    selector: "body",
                    styleID: styleID,
                    properties: [
                        CSSPropertyPayload(
                            name: "font-family",
                            value: "sans-serif",
                            text: "font-family: sans-serif;",
                            status: .active
                        ),
                        CSSPropertyPayload(
                            name: "font-size",
                            value: "10pt",
                            text: "font-size: 10pt;",
                            status: .active
                        ),
                        CSSPropertyPayload(
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
        for: CSSPropertyIdentifier(styleID: styleID, propertyIndex: 1),
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
    let styleID = CSSStyleIdentifier(styleSheetID: .init("sheet"), ordinal: 0)
    let token = try #require(await css.beginRefresh(identity: identity))
    await css.applyRefresh(
        token: token,
        matched: CSSMatchedStylesPayload(matchedRules: [
            CSSRuleMatchPayload(
                rule: rule(
                    selector: "body::before",
                    styleID: styleID,
                    properties: [
                        CSSPropertyPayload(
                            name: "content",
                            value: #""color: red;""#,
                            text: #"content: "color: red;";"#,
                            status: .active
                        ),
                        CSSPropertyPayload(
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
        for: CSSPropertyIdentifier(styleID: styleID, propertyIndex: 1),
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
    let beforeCommentStyleID = CSSStyleIdentifier(styleSheetID: .init("sheet"), ordinal: 0)
    let afterCommentStyleID = CSSStyleIdentifier(styleSheetID: .init("sheet"), ordinal: 1)
    let token = try #require(await css.beginRefresh(identity: identity))
    await css.applyRefresh(
        token: token,
        matched: CSSMatchedStylesPayload(matchedRules: [
            CSSRuleMatchPayload(
                rule: rule(
                    selector: ".before-comment",
                    styleID: beforeCommentStyleID,
                    properties: [
                        CSSPropertyPayload(
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
            CSSRuleMatchPayload(
                rule: rule(
                    selector: ".after-comment",
                    styleID: afterCommentStyleID,
                    properties: [
                        CSSPropertyPayload(
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
        for: CSSPropertyIdentifier(styleID: beforeCommentStyleID, propertyIndex: 0),
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
        for: CSSPropertyIdentifier(styleID: afterCommentStyleID, propertyIndex: 0),
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
    let styleID = CSSStyleIdentifier(styleSheetID: .init("ua"), ordinal: 0)
    let token = try #require(await css.beginRefresh(identity: identity))
    await css.applyRefresh(
        token: token,
        matched: CSSMatchedStylesPayload(matchedRules: [
            CSSRuleMatchPayload(
                rule: rule(
                    selector: "body",
                    styleID: styleID,
                    origin: .userAgent,
                    properties: [
                        CSSPropertyPayload(name: "display", value: "block", text: "display: block;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: CSSInlineStylesPayload(attributesStyle: style(properties: [
            CSSPropertyPayload(name: "width", value: "100", text: "width: 100;"),
        ])),
        computed: []
    )

    #expect(await css.setStyleTextIntent(
        for: CSSPropertyIdentifier(styleID: styleID, propertyIndex: 0),
        enabled: false
    ) == nil)
}

@Test
@MainActor
func cssSessionDoesNotSynthesizeStyleTextWhenOtherPropertiesHaveNoAuthoredText() throws {
    let css = CSSSession()
    let identity = cssIdentity()
    let styleID = CSSStyleIdentifier(styleSheetID: .init("sheet"), ordinal: 0)
    let token = try #require(css.beginRefresh(identity: identity))
    css.applyRefresh(
        token: token,
        matched: CSSMatchedStylesPayload(matchedRules: [
            CSSRuleMatchPayload(
                rule: rule(
                    selector: "body",
                    styleID: styleID,
                    properties: [
                        CSSPropertyPayload(name: "margin", value: "0", text: "margin: 0;"),
                        CSSPropertyPayload(name: "margin-top", value: "0", implicit: true),
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
        for: CSSPropertyIdentifier(styleID: styleID, propertyIndex: 0),
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
        matched: CSSMatchedStylesPayload(matchedRules: [
            CSSRuleMatchPayload(
                rule: rule(
                    selector: "body",
                    properties: [
                        CSSPropertyPayload(name: "margin", value: "0", text: "margin: 0;"),
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
        matched: CSSMatchedStylesPayload(matchedRules: [
            CSSRuleMatchPayload(
                rule: rule(
                    selector: "body",
                    styleID: .init(styleSheetID: .init("tracked"), ordinal: 0),
                    properties: [
                        CSSPropertyPayload(name: "margin", value: "0", text: "margin: 0;"),
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
    let styleID = CSSStyleIdentifier(styleSheetID: .init("sheet"), ordinal: 0)
    let token = try #require(await css.beginRefresh(identity: identity))
    await css.applyRefresh(
        token: token,
        matched: CSSMatchedStylesPayload(matchedRules: [
            CSSRuleMatchPayload(
                rule: rule(
                    selector: "body",
                    styleID: styleID,
                    properties: [
                        CSSPropertyPayload(name: "margin", value: "0", text: "margin: 0;"),
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
@MainActor
func cssSessionMarksSetStyleTextPropertyAsModifiedByInspector() throws {
    let css = CSSSession()
    let identity = cssIdentity()
    let styleID = CSSStyleIdentifier(styleSheetID: .init("sheet"), ordinal: 0)
    let propertyID = CSSPropertyIdentifier(styleID: styleID, propertyIndex: 0)
    let token = try #require(css.beginRefresh(identity: identity))
    css.applyRefresh(
        token: token,
        matched: CSSMatchedStylesPayload(matchedRules: [
            CSSRuleMatchPayload(
                rule: rule(
                    selector: "body",
                    styleID: styleID,
                    properties: [
                        CSSPropertyPayload(name: "margin", value: "0", text: "margin: 0;", status: .active),
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
        CSSStylePayload(id: styleID, cssProperties: [
            CSSPropertyPayload(name: "margin", value: "0", text: "/* margin: 0; */", status: .disabled),
        ]),
        propertyID: propertyID,
        targetID: identity.targetID
    )

    #expect(property.status == .disabled)
    #expect(property.isModifiedByInspector)

    let refreshToken = try #require(css.beginRefresh(identity: identity))
    css.applyRefresh(
        token: refreshToken,
        matched: CSSMatchedStylesPayload(matchedRules: [
            CSSRuleMatchPayload(
                rule: rule(
                    selector: "body",
                    styleID: styleID,
                    properties: [
                        CSSPropertyPayload(name: "margin", value: "0", text: "/* margin: 0; */", status: .disabled),
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
        CSSStylePayload(id: styleID, cssProperties: [
            CSSPropertyPayload(name: "margin", value: "0", text: "margin: 0;", status: .active),
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
    let sharedStyleID = CSSStyleIdentifier(styleSheetID: .init("sheet"), ordinal: 0)
    let pageIdentity = cssIdentity(targetID: .init("page"), nodeRawID: 2)
    let frameIdentity = cssIdentity(targetID: .init("frame"), nodeRawID: 2)

    let pageToken = try #require(css.beginRefresh(identity: pageIdentity))
    css.applyRefresh(
        token: pageToken,
        matched: CSSMatchedStylesPayload(matchedRules: [
            CSSRuleMatchPayload(
                rule: rule(
                    selector: "body",
                    styleID: sharedStyleID,
                    properties: [
                        CSSPropertyPayload(name: "margin", value: "0", text: "margin: 0;"),
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
        matched: CSSMatchedStylesPayload(matchedRules: [
            CSSRuleMatchPayload(
                rule: rule(
                    selector: "body",
                    styleID: sharedStyleID,
                    properties: [
                        CSSPropertyPayload(name: "margin", value: "10px", text: "margin: 10px;"),
                    ]
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )

    css.applySetStyleTextResult(
        CSSStylePayload(id: sharedStyleID, cssProperties: [
            CSSPropertyPayload(name: "margin", value: "0", text: "/* margin: 0; */", status: .disabled),
        ]),
        propertyID: CSSPropertyIdentifier(styleID: sharedStyleID, propertyIndex: 0),
        targetID: pageIdentity.targetID
    )

    let selectedFrameStyles = try #require(css.selectedNodeStyles)
    #expect(css.selectedState == .loaded)
    #expect(selectedFrameStyles.identity.targetID == frameIdentity.targetID)
    #expect(selectedFrameStyles.sections[0].style.cssProperties[0].value == "10px")
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
    properties: [CSSPropertyPayload],
    cssText: String? = nil
) -> CSSRulePayload {
    CSSRulePayload(
        id: CSSRuleIdentifier(styleSheetID: styleID.styleSheetID, ordinal: styleID.ordinal),
        selectorList: CSSSelectorList(selectors: [CSSSelector(text: selector)], text: selector),
        sourceLine: 1,
        origin: origin,
        style: style(id: styleID, properties: properties, cssText: cssText)
    )
}

private func style(
    id: CSSStyleIdentifier? = nil,
    properties: [CSSPropertyPayload],
    cssText: String? = nil
) -> CSSStylePayload {
    CSSStylePayload(id: id, cssProperties: properties, cssText: cssText)
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
