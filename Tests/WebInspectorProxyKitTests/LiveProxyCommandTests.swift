import Foundation
import Testing
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import WebInspectorTestSupport

@Test
func transportCommandBackendDecodesResourceTreeAndResourceContent() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: LiveWebInspectorProxyBackend(transport: transport)))
    let treeTask = Task { try await target.page.resourceTree() }
    let treeCommand = try await waitForTargetMessage(backend, method: "Page.getResourceTree")
    #expect(try messageParameters(treeCommand.message).isEmpty)
    await receiveTargetReply(transport, targetID: treeCommand.targetIdentifier,
        messageID: try messageID(treeCommand.message),
        result: #"{"frameTree":{"frame":{"id":"main-frame","loaderId":"loader","url":"https://example.test/","mimeType":"text/html"},"resources":[{"url":"https://example.test/app.js","type":"Script","mimeType":"text/javascript","failed":true,"targetId":"worker-1"}]}}"#)
    let tree = try await treeTask.value.value
    #expect(tree.frame.id == "main-frame")
    #expect(tree.childFrames == nil)
    #expect(tree.resources.first?.failed == true)
    #expect(tree.resources.first?.targetId == "worker-1")
    let contentTask = Task { try await target.page.resourceContent(frameID: FrameID("main-frame"), url: "https://example.test/app.js") }
    let contentCommand = try await waitForTargetMessage(backend, method: "Page.getResourceContent")
    let parameters = try messageParameters(contentCommand.message)
    #expect(parameters["frameId"] as? String == "main-frame")
    #expect(parameters["url"] as? String == "https://example.test/app.js")
    await receiveTargetReply(transport, targetID: contentCommand.targetIdentifier,
        messageID: try messageID(contentCommand.message), result: #"{"content":"Y29uc29sZS5sb2coMSk=","base64Encoded":true}"#)
    let body = try await contentTask.value.value
    #expect(body.data == "Y29uc29sZS5sb2coMSk=")
    #expect(body.base64Encoded)
}

@Test
func transportCommandBackendDispatchesPageReloadThroughTargetRoute() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: LiveWebInspectorProxyBackend(transport: transport)))

    let reloadTask = Task {
        try await target.page.reload()
    }

    let sent = try await waitForTargetMessage(backend, method: "Page.reload")
    #expect(sent.targetIdentifier == ProtocolTarget.ID("page-main"))
    #expect(try messageMethod(sent.message) == "Page.reload")
    #expect(try messageParameters(sent.message)["ignoreCache"] as? Bool == false)

    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: "{}"
    )
    try await reloadTask.value
}

@Test
func transportCommandBackendDispatchesPageLifecycleCommandsThroughTargetRoute() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: LiveWebInspectorProxyBackend(transport: transport)))

    let enableTask = Task {
        try await target.page.enable()
    }
    let enable = try await waitForTargetMessage(backend, method: "Page.enable")
    #expect(enable.targetIdentifier == ProtocolTarget.ID("page-main"))
    #expect(try messageParameters(enable.message).isEmpty)
    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )
    try await enableTask.value

    let disableTask = Task {
        try await target.page.disable()
    }
    let disable = try await waitForTargetMessage(backend, method: "Page.disable")
    #expect(disable.targetIdentifier == ProtocolTarget.ID("page-main"))
    #expect(try messageParameters(disable.message).isEmpty)
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )
    try await disableTask.value
}

@Test
func transportCommandBackendDecodesDOMRequestNodeResult() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: LiveWebInspectorProxyBackend(transport: transport)))

    let requestNodeTask = Task {
        try await target.dom.requestNode(forRemoteObject: Runtime.RemoteObject.ID("remote-node"))
    }

    let sent = try await waitForTargetMessage(backend, method: "DOM.requestNode")
    #expect(sent.targetIdentifier == ProtocolTarget.ID("page-main"))
    #expect(try messageMethod(sent.message) == "DOM.requestNode")
    #expect(try messageParameters(sent.message)["objectId"] as? String == "remote-node")

    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: #"{"nodeId":"protocol-node"}"#
    )

    #expect(try await requestNodeTask.value == DOM.Node.ID("protocol-node"))
}

@Test
func transportCommandBackendPreservesDOMRequestChildNodesRecursiveDepth() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: LiveWebInspectorProxyBackend(transport: transport)))

    let requestChildrenTask = Task {
        try await target.dom.requestChildNodes(DOM.Node.ID("document"), depth: -1)
    }

    let sent = try await waitForTargetMessage(backend, method: "DOM.requestChildNodes")
    #expect(sent.targetIdentifier == ProtocolTarget.ID("page-main"))
    #expect(try messageMethod(sent.message) == "DOM.requestChildNodes")
    let parameters = try messageParameters(sent.message)
    #expect(parameters["nodeId"] as? String == "document")
    #expect((parameters["depth"] as? NSNumber)?.intValue == -1)

    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: "{}"
    )
    try await requestChildrenTask.value
}

@Test
func transportCommandBackendEncodesDOMEditingCommandsAndDecodesAttributes() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: LiveWebInspectorProxyBackend(transport: transport)))

    let attributesTask = Task {
        try await target.dom.attributes(of: DOM.Node.ID("42"))
    }
    let attributes = try await waitForTargetMessage(backend, method: "DOM.getAttributes")
    var parameters = try messageParameters(attributes.message)
    #expect((parameters["nodeId"] as? NSNumber)?.intValue == 42)
    await receiveTargetReply(
        transport,
        targetID: attributes.targetIdentifier,
        messageID: try messageID(attributes.message),
        result: #"{"attributes":["class","card","data-id","42"]}"#
    )
    #expect(try await attributesTask.value == [
        DOM.Attribute(name: "class", value: "card"),
        DOM.Attribute(name: "data-id", value: "42"),
    ])

    let setAttributeTask = Task {
        try await target.dom.setAttributeValue(DOM.Node.ID("42"), name: "class", value: "card selected")
    }
    let setAttribute = try await waitForTargetMessage(backend, method: "DOM.setAttributeValue")
    parameters = try messageParameters(setAttribute.message)
    #expect((parameters["nodeId"] as? NSNumber)?.intValue == 42)
    #expect(parameters["name"] as? String == "class")
    #expect(parameters["value"] as? String == "card selected")
    await receiveTargetReply(
        transport,
        targetID: setAttribute.targetIdentifier,
        messageID: try messageID(setAttribute.message),
        result: "{}"
    )
    try await setAttributeTask.value

    let setAttributesTask = Task {
        try await target.dom.setAttributesAsText(DOM.Node.ID("42"), text: #"class="card" hidden"#, name: "class")
    }
    let setAttributes = try await waitForTargetMessage(backend, method: "DOM.setAttributesAsText")
    parameters = try messageParameters(setAttributes.message)
    #expect((parameters["nodeId"] as? NSNumber)?.intValue == 42)
    #expect(parameters["text"] as? String == #"class="card" hidden"#)
    #expect(parameters["name"] as? String == "class")
    await receiveTargetReply(
        transport,
        targetID: setAttributes.targetIdentifier,
        messageID: try messageID(setAttributes.message),
        result: "{}"
    )
    try await setAttributesTask.value

    let removeAttributeTask = Task {
        try await target.dom.removeAttribute(DOM.Node.ID("42"), name: "hidden")
    }
    let removeAttribute = try await waitForTargetMessage(backend, method: "DOM.removeAttribute")
    parameters = try messageParameters(removeAttribute.message)
    #expect((parameters["nodeId"] as? NSNumber)?.intValue == 42)
    #expect(parameters["name"] as? String == "hidden")
    await receiveTargetReply(
        transport,
        targetID: removeAttribute.targetIdentifier,
        messageID: try messageID(removeAttribute.message),
        result: "{}"
    )
    try await removeAttributeTask.value

    let setOuterHTMLTask = Task {
        try await target.dom.setOuterHTML(DOM.Node.ID("42"), html: #"<section class="card"></section>"#)
    }
    let setOuterHTML = try await waitForTargetMessage(backend, method: "DOM.setOuterHTML")
    parameters = try messageParameters(setOuterHTML.message)
    #expect((parameters["nodeId"] as? NSNumber)?.intValue == 42)
    #expect(parameters["outerHTML"] as? String == #"<section class="card"></section>"#)
    await receiveTargetReply(
        transport,
        targetID: setOuterHTML.targetIdentifier,
        messageID: try messageID(setOuterHTML.message),
        result: "{}"
    )
    try await setOuterHTMLTask.value
}

@Test
func transportCommandBackendEncodesDOMHighlightAndInspectModeCommands() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: LiveWebInspectorProxyBackend(transport: transport)))

    let highlightTask = Task {
        try await target.dom.highlightNode(DOM.Node.ID("42"))
    }

    let highlight = try await waitForTargetMessage(backend, method: "DOM.highlightNode")
    #expect(highlight.targetIdentifier == ProtocolTarget.ID("page-main"))
    var parameters = try messageParameters(highlight.message)
    #expect((parameters["nodeId"] as? NSNumber)?.intValue == 42)
    let highlightConfig = try #require(parameters["highlightConfig"] as? [String: Any])
    #expect(highlightConfig["showInfo"] as? Bool == false)

    await receiveTargetReply(
        transport,
        targetID: highlight.targetIdentifier,
        messageID: try messageID(highlight.message),
        result: "{}"
    )
    try await highlightTask.value

    let enableTask = Task {
        try await target.dom.setInspectMode(enabled: true)
    }

    let enable = try await waitForTargetMessage(backend, method: "DOM.setInspectModeEnabled")
    parameters = try messageParameters(enable.message)
    #expect(parameters["enabled"] as? Bool == true)
    #expect(parameters["highlightConfig"] is [String: Any])
    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )
    try await enableTask.value

    let disableTask = Task {
        try await target.dom.setInspectMode(enabled: false)
    }

    let disable = try await waitForTargetMessage(backend, method: "DOM.setInspectModeEnabled", ordinal: 1)
    parameters = try messageParameters(disable.message)
    #expect(parameters["enabled"] as? Bool == false)
    #expect(parameters["highlightConfig"] == nil)
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )
    try await disableTask.value

    let markTask = Task {
        try await target.dom.markUndoableState()
    }

    let mark = try await waitForTargetMessage(backend, method: "DOM.markUndoableState")
    #expect(mark.targetIdentifier == ProtocolTarget.ID("page-main"))
    #expect(try messageParameters(mark.message).isEmpty)
    await receiveTargetReply(
        transport,
        targetID: mark.targetIdentifier,
        messageID: try messageID(mark.message),
        result: "{}"
    )
    try await markTask.value
}

@Test
func transportCommandBackendDecodesDOMDocumentResult() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: LiveWebInspectorProxyBackend(transport: transport)))

    let documentTask = Task {
        try await target.dom.getDocument()
    }

    let sent = try await waitForTargetMessage(backend, method: "DOM.getDocument")
    #expect(sent.targetIdentifier == ProtocolTarget.ID("page-main"))
    #expect(try messageMethod(sent.message) == "DOM.getDocument")
    #expect(try messageParameters(sent.message).isEmpty)

    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: ##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","localName":"","nodeValue":"","frameId":"main-frame","documentURL":"https://example.test/","baseURL":"https://example.test/","childNodeCount":1,"children":[{"nodeId":2,"nodeType":1,"nodeName":"HTML","localName":"html","nodeValue":"","attributes":["lang","en"],"childNodeCount":0}]}}"##
    )

    let document = try await documentTask.value
    #expect(document.id == DOM.Node.ID("1"))
    #expect(document.frameID == FrameID("main-frame"))
    #expect(document.documentURL == "https://example.test/")
    #expect(document.baseURL == "https://example.test/")
    #expect(document.childNodeCount == 1)
    let child = try #require(document.children?.first)
    #expect(child.id == DOM.Node.ID("2"))
    #expect(child.attributes["lang"] == "en")
    #expect(child.attributeList == [DOM.Attribute(name: "lang", value: "en")])
}

@Test
func transportCommandBackendEncodesAndDecodesCSSStyleCommands() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: LiveWebInspectorProxyBackend(transport: transport)))

    let matchedStylesTask = Task {
        try await target.css.matchedStyles(for: DOM.Node.ID("42"))
    }

    let matchedStylesCommand = try await waitForTargetMessage(backend, method: "CSS.getMatchedStylesForNode")
    #expect(matchedStylesCommand.targetIdentifier == ProtocolTarget.ID("page-main"))
    var parameters = try messageParameters(matchedStylesCommand.message)
    #expect((parameters["nodeId"] as? NSNumber)?.intValue == 42)
    await receiveTargetReply(
        transport,
        targetID: matchedStylesCommand.targetIdentifier,
        messageID: try messageID(matchedStylesCommand.message),
        result: """
        {
          "matchedCSSRules": [
            {
              "rule": {
                "ruleId": {"styleSheetId": "sheet", "ordinal": 1},
                "selectorList": {"selectors": [{"text": "body"}], "text": "body"},
                "origin": "author",
                "style": {
                  "styleId": {"styleSheetId": "sheet", "ordinal": 1},
                  "cssProperties": [
                    {"name": "margin", "value": "0", "text": "margin: 0;", "status": "active"}
                  ],
                  "cssText": "margin: 0;"
                }
              },
              "matchingSelectors": [0]
            }
          ],
          "inherited": [
            {
              "inlineStyle": {
                "cssProperties": [
                  {"name": "color", "value": "red", "text": "color: red;"}
                ],
                "cssText": "color: red;"
              },
              "matchedCSSRules": [
                {
                  "rule": {
                    "ruleId": {"styleSheetId": "sheet", "ordinal": 3},
                    "selectorList": {"selectors": [{"text": "html"}], "text": "html", "range": {"startLine": 4, "startColumn": 0, "endLine": 4, "endColumn": 4}},
                    "origin": "author",
                    "style": {
                      "styleId": {"styleSheetId": "sheet", "ordinal": 3},
                      "cssProperties": [{"name": "font-size", "value": "16px"}]
                    }
                  },
                  "matchingSelectors": [0]
                }
              ]
            }
          ],
          "pseudoElements": [
            {
              "pseudoId": "before",
              "matches": [
                {
                  "rule": {
                    "selectorList": {"selectors": [{"text": "body::before"}], "text": "body::before"},
                    "origin": "author",
                    "style": {
                      "styleId": {"styleSheetId": "sheet", "ordinal": 2},
                      "cssProperties": [{"name": "content", "value": "before"}]
                    }
                  },
                  "matchingSelectors": [0]
                }
              ]
            }
          ]
        }
        """
    )

    let matchedStyles = try await matchedStylesTask.value
    let rule = try #require(matchedStyles.matchedRules.first)
    #expect(rule.selectorList.text == "body")
    #expect(rule.style.properties.first?.name == "margin")
    #expect(rule.style.properties.first?.status == .active)
    #expect(rule.style.isEditable)
    let inheritedEntry = try #require(matchedStyles.inherited.first)
    #expect(inheritedEntry.inlineStyle?.properties.first?.name == "color")
    #expect(inheritedEntry.inlineStyle?.isEditable == false)
    #expect(inheritedEntry.matchedRules.first?.selectorList.text == "html")
    #expect(inheritedEntry.matchedRules.first?.selectorList.range?.startLine == 4)
    let pseudo = try #require(matchedStyles.pseudoElements.first)
    #expect(pseudo.pseudoID == "before")
    #expect(pseudo.matchedRules.first?.selectorList.text == "body::before")

    let inlineStylesTask = Task {
        try await target.css.inlineStyles(for: DOM.Node.ID("42"))
    }
    let inlineStylesCommand = try await waitForTargetMessage(backend, method: "CSS.getInlineStylesForNode")
    parameters = try messageParameters(inlineStylesCommand.message)
    #expect((parameters["nodeId"] as? NSNumber)?.intValue == 42)
    await receiveTargetReply(
        transport,
        targetID: inlineStylesCommand.targetIdentifier,
        messageID: try messageID(inlineStylesCommand.message),
        result: """
        {
          "inlineStyle": {
            "cssProperties": [
              {"name": "color", "value": "blue", "text": "color: blue;"}
            ],
            "cssText": "color: blue;"
          },
          "attributesStyle": {
            "cssProperties": [
              {"name": "width", "value": "20"}
            ]
          }
        }
        """
    )
    let inlineStyles = try await inlineStylesTask.value
    #expect(inlineStyles.inlineStyle?.properties.first?.name == "color")
    #expect(inlineStyles.inlineStyle?.isEditable == false)
    #expect(inlineStyles.attributesStyle?.properties.first?.name == "width")
    #expect(inlineStyles.attributesStyle?.isEditable == false)

    let computedStyleTask = Task {
        try await target.css.computedStyle(for: DOM.Node.ID("42"))
    }

    let computedStyleCommand = try await waitForTargetMessage(backend, method: "CSS.getComputedStyleForNode")
    parameters = try messageParameters(computedStyleCommand.message)
    #expect((parameters["nodeId"] as? NSNumber)?.intValue == 42)
    await receiveTargetReply(
        transport,
        targetID: computedStyleCommand.targetIdentifier,
        messageID: try messageID(computedStyleCommand.message),
        result: #"{"computedStyle":[{"name":"display","value":"block"}]}"#
    )
    #expect(try await computedStyleTask.value.first?.value == "block")

    let setStyleTextTask = Task {
        try await target.css.setStyleText(rule.style.id, text: "margin: 1px;")
    }

    let setStyleTextCommand = try await waitForTargetMessage(backend, method: "CSS.setStyleText")
    parameters = try messageParameters(setStyleTextCommand.message)
    let styleID = try #require(parameters["styleId"] as? [String: Any])
    #expect(styleID["styleSheetId"] as? String == "sheet")
    #expect((styleID["ordinal"] as? NSNumber)?.intValue == 1)
    #expect(parameters["text"] as? String == "margin: 1px;")
    await receiveTargetReply(
        transport,
        targetID: setStyleTextCommand.targetIdentifier,
        messageID: try messageID(setStyleTextCommand.message),
        result: """
        {
          "style": {
            "styleId": {"styleSheetId": "sheet", "ordinal": 1},
            "cssProperties": [
              {"name": "margin", "value": "1px", "text": "/* margin: 1px; */", "status": "disabled"}
            ],
            "cssText": "/* margin: 1px; */"
          }
        }
        """
    )
    let updatedStyle = try await setStyleTextTask.value
    #expect(updatedStyle.properties.first?.value == "1px")
    #expect(updatedStyle.properties.first?.status == .disabled)

    let setStyleSheetTextTask = Task {
        try await target.css.setStyleSheetText(CSS.StyleSheet.ID("sheet"), text: "body { color: blue; }")
    }
    let setStyleSheetTextCommand = try await waitForTargetMessage(backend, method: "CSS.setStyleSheetText")
    parameters = try messageParameters(setStyleSheetTextCommand.message)
    #expect(parameters["styleSheetId"] as? String == "sheet")
    #expect(parameters["text"] as? String == "body { color: blue; }")
    await receiveTargetReply(
        transport,
        targetID: setStyleSheetTextCommand.targetIdentifier,
        messageID: try messageID(setStyleSheetTextCommand.message),
        result: "{}"
    )
    try await setStyleSheetTextTask.value

    let ruleID = try #require(rule.id)
    let setRuleSelectorTask = Task {
        try await target.css.setRuleSelector(ruleID, selector: ".card")
    }
    let setRuleSelectorCommand = try await waitForTargetMessage(backend, method: "CSS.setRuleSelector")
    parameters = try messageParameters(setRuleSelectorCommand.message)
    let ruleIDPayload = try #require(parameters["ruleId"] as? [String: Any])
    #expect(ruleIDPayload["styleSheetId"] as? String == "sheet")
    #expect((ruleIDPayload["ordinal"] as? NSNumber)?.intValue == 1)
    #expect(parameters["selector"] as? String == ".card")
    await receiveTargetReply(
        transport,
        targetID: setRuleSelectorCommand.targetIdentifier,
        messageID: try messageID(setRuleSelectorCommand.message),
        result: """
        {
          "rule": {
            "ruleId": {"styleSheetId": "sheet", "ordinal": 1},
            "selectorList": {"selectors": [{"text": ".card"}], "text": ".card"},
            "origin": "author",
            "style": {
              "styleId": {"styleSheetId": "sheet", "ordinal": 1},
              "cssProperties": [{"name": "margin", "value": "1px"}],
              "cssText": "margin: 1px;"
            }
          }
        }
        """
    )
    let updatedRule = try await setRuleSelectorTask.value
    #expect(updatedRule.selectorList.text == ".card")
    #expect(updatedRule.id?.targetScopeRawValue == nil)
    #expect(updatedRule.id?.unscopedRawValue == "sheet\u{1F}1")

    let setGroupingHeaderTextTask = Task {
        try await target.css.setGroupingHeaderText(ruleID, text: "@media (width > 600px)")
    }
    let setGroupingHeaderTextCommand = try await waitForTargetMessage(
        backend,
        method: "CSS.setGroupingHeaderText"
    )
    parameters = try messageParameters(setGroupingHeaderTextCommand.message)
    let groupingRuleIDPayload = try #require(parameters["ruleId"] as? [String: Any])
    #expect(groupingRuleIDPayload["styleSheetId"] as? String == "sheet")
    #expect((groupingRuleIDPayload["ordinal"] as? NSNumber)?.intValue == 1)
    #expect(parameters["headerText"] as? String == "@media (width > 600px)")
    await receiveTargetReply(
        transport,
        targetID: setGroupingHeaderTextCommand.targetIdentifier,
        messageID: try messageID(setGroupingHeaderTextCommand.message),
        result: #"{"grouping":{"text":"@media (width > 600px)"}}"#
    )
    #expect(try await setGroupingHeaderTextTask.value.text == "@media (width > 600px)")
}

@Test
func transportCommandBackendDecodesRuntimeEvaluationResult() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: LiveWebInspectorProxyBackend(transport: transport)))

    let evaluateTask = Task {
        try await target.runtime.evaluate("document.title", in: Runtime.ExecutionContext.ID("7"))
    }

    let sent = try await waitForTargetMessage(backend, method: "Runtime.evaluate")
    #expect(sent.targetIdentifier == ProtocolTarget.ID("page-main"))
    #expect(try messageMethod(sent.message) == "Runtime.evaluate")
    let parameters = try messageParameters(sent.message)
    #expect(parameters["expression"] as? String == "document.title")
    #expect((parameters["contextId"] as? NSNumber)?.intValue == 7)

    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: #"{"result":{"type":"string","value":"Title","description":"Title"},"wasThrown":true,"savedResultIndex":3}"#
    )

    let result = try await evaluateTask.value
    #expect(result.object.kind == .string)
    #expect(result.object.value == .string("Title"))
    #expect(result.object.description == "Title")
    #expect(result.wasThrown == true)
    #expect(result.savedResultIndex == 3)
}

@Test
func transportCommandBackendDecodesRuntimePropertiesPreviewAndCollectionEntries() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: LiveWebInspectorProxyBackend(transport: transport)))
    let objectID = Runtime.RemoteObject.ID("object-1")

    let propertiesTask = Task {
        try await target.runtime.properties(of: objectID)
    }
    let propertiesCommand = try await waitForTargetMessage(backend, method: "Runtime.getProperties")
    await receiveTargetReply(
        transport,
        targetID: propertiesCommand.targetIdentifier,
        messageID: try messageID(propertiesCommand.message),
        result: #"{"properties":[{"name":"answer","value":{"type":"number","value":42,"description":"42"},"writable":true,"isOwn":true},{"name":"accessor","get":{"type":"function","objectId":"getter-1","description":"get answer"},"set":{"type":"undefined","description":"undefined"},"wasThrown":false,"configurable":true,"enumerable":false,"symbol":{"type":"symbol","description":"Symbol(answer)"},"isPrivate":false,"nativeGetter":true}],"internalProperties":[{"name":"[[Prototype]]","value":{"type":"object","objectId":"prototype-1","description":"Object"}}]}"#
    )

    let properties = try await propertiesTask.value
    #expect(properties.count == 2)
    #expect(properties[0].name == "answer")
    #expect(properties[0].value?.kind == .number)
    #expect(properties[0].value?.value == .number(42))
    #expect(properties[0].writable == true)
    #expect(properties[0].isOwn == true)
    #expect(properties[1].name == "accessor")
    #expect(properties[1].get?.kind == .function)
    #expect(properties[1].get?.id == Runtime.RemoteObject.ID("getter-1"))
    #expect(properties[1].set?.kind == .undefined)
    #expect(properties[1].wasThrown == false)
    #expect(properties[1].configurable == true)
    #expect(properties[1].enumerable == false)
    #expect(properties[1].symbol?.kind == .symbol)
    #expect(properties[1].symbol?.description == "Symbol(answer)")
    #expect(properties[1].isPrivate == false)
    #expect(properties[1].nativeGetter == true)

    let previewTask = Task {
        try await target.runtime.preview(of: objectID)
    }
    let previewCommand = try await waitForTargetMessage(backend, method: "Runtime.getPreview")
    await receiveTargetReply(
        transport,
        targetID: previewCommand.targetIdentifier,
        messageID: try messageID(previewCommand.message),
        result: #"{"preview":{"type":"object","subtype":"map","description":"Map(1)","lossless":true,"overflow":false,"properties":[{"name":"size","type":"number","value":"1"}],"entries":[{"key":{"type":"string","description":"key","lossless":true},"value":{"type":"number","description":"42","lossless":true}}],"size":1}}"#
    )

    let preview = try await previewTask.value
    #expect(preview.kind == .object)
    #expect(preview.subtype == Runtime.Subtype(rawValue: "map"))
    #expect(preview.description == "Map(1)")
    #expect(preview.lossless == true)
    #expect(preview.overflow == false)
    #expect(preview.properties.first?.name == "size")
    #expect(preview.properties.first?.value == "1")
    #expect(preview.entries.first?.key == "key")
    #expect(preview.entries.first?.value == "42")
    #expect(preview.size == 1)

    let entriesTask = Task {
        try await target.runtime.collectionEntries(of: objectID)
    }
    let entriesCommand = try await waitForTargetMessage(backend, method: "Runtime.getCollectionEntries")
    await receiveTargetReply(
        transport,
        targetID: entriesCommand.targetIdentifier,
        messageID: try messageID(entriesCommand.message),
        result: #"{"entries":[{"key":{"type":"string","value":"key","description":"key"},"value":{"type":"object","objectId":"entry-value","description":"entry value"}},{"value":{"type":"number","value":42,"description":"42"}}]}"#
    )

    let entries = try await entriesTask.value
    #expect(entries.count == 2)
    #expect(entries[0].key?.value == .string("key"))
    #expect(entries[0].value.id == Runtime.RemoteObject.ID("entry-value"))
    #expect(entries[0].value.description == "entry value")
    #expect(entries[1].key == nil)
    #expect(entries[1].value.value == .number(42))
}
