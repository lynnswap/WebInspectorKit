import Foundation
import Testing
import WebInspectorTestSupport
@testable import WebInspectorProxyKit

private let transportCommandBackendWaitTimeout: Duration = .milliseconds(750)

@Test
func transportCommandBackendDispatchesPageReloadThroughTargetRoute() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = pageTarget(proxy: proxy)

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
func transportCommandBackendDecodesDOMRequestNodeResult() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = pageTarget(proxy: proxy)

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
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = pageTarget(proxy: proxy)

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
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = pageTarget(proxy: proxy)

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
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = pageTarget(proxy: proxy)

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
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = pageTarget(proxy: proxy)

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
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = pageTarget(proxy: proxy)

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
func transportBackedProxyMaterializesCurrentPageFromTransportRegistry() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    let proxyTask = Task {
        try await WebInspectorProxy(transport: transport)
    }

    await installPageTarget(in: transport)

    let proxy = try await throwingValue(of: proxyTask)
    let target = try await proxy.waitForCurrentPage()
    #expect(target.id == .currentPage)
    guard case .page = target.kind else {
        Issue.record("Expected current page target.")
        return
    }
    #expect(target.frameID == FrameID("main-frame"))
    #expect(target.route == .currentPage)
}

@Test
func transportBackedProxyWaitUntilClosedSuspendsUntilClose() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)

    let waitTask = Task {
        try await proxy.waitUntilClosed()
    }

    await proxy.waitForCloseWaiterForTesting()
    #expect(await backend.isDetached() == false)

    await proxy.close()

    try await waitTask.value
    #expect(await backend.isDetached())
}

@Test
func nativeFatalCallbackPropagatesThroughProxyTerminalAPI() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: .milliseconds(750))
    let receiver = TransportReceiver()
    receiver.setCore(core)
    await installPageTarget(in: core)
    let proxy = try await WebInspectorProxy(transport: core)
    let page = try await proxy.waitForCurrentPage()

    receiver.fail("native frontend disconnected")

    await #expect(throws: WebInspectorProxyError.disconnected("native frontend disconnected")) {
        try await proxy.waitUntilClosed()
    }
    await #expect(throws: WebInspectorProxyError.disconnected("native frontend disconnected")) {
        try await page.page.reload()
    }
    #expect(await backend.isDetached())
}

@Test
func proxyWaitUntilClosedReturnsImmediatelyAfterClose() async throws {
    let proxy = WebInspectorProxy(localStateOnly: ())

    await proxy.close()

    let waitTask = Task {
        try await proxy.waitUntilClosed()
    }
    try await throwingValue(of: waitTask, timeout: .milliseconds(100))
}

@Test
func proxyHandleDeallocatesAfterExplicitClose() async {
    weak var weakProxy: WebInspectorProxy?

    do {
        let proxy = WebInspectorProxy(localStateOnly: ())
        weakProxy = proxy
        await proxy.close()
    }

    #expect(weakProxy == nil)
}

@Test
func droppingOpenProxyHandleReachesConnectionCoreDeinit() {
    weak var weakProxy: WebInspectorProxy?

    do {
        let proxy = WebInspectorProxy(localStateOnly: ())
        weakProxy = proxy
    }

    #expect(weakProxy == nil)
}

@Test
func pageTargetAndDomainHandlesDoNotOwnTheProxyLifecycle() async {
    weak var weakProxy: WebInspectorProxy?
    var page: WebInspectorPage?
    var dom: DOM?

    do {
        let proxy = WebInspectorProxy(localStateOnly: ())
        weakProxy = proxy
        page = proxy.page
        dom = page?.dom
    }

    #expect(weakProxy == nil)
    await #expect(throws: WebInspectorProxyError.closed) {
        _ = try await page?.generation
    }
    await #expect(throws: WebInspectorProxyError.closed) {
        _ = try await dom?.getDocument()
    }
    await #expect(throws: WebInspectorProxyError.closed) {
        try await dom?.withEvents { _ in }
    }
}

@Test
func pendingCapabilitySendDoesNotRetainDroppedConnectionCore() async throws {
    let backend = SuspendedSendTransportBackend()
    weak var weakTransport: TransportSession?

    do {
        let transport = TransportSession(backend: backend, responseTimeout: nil)
        weakTransport = transport
        await installPageTarget(in: transport)
        await transport.receiveRootMessage(
            #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-target","type":"frame","frameId":"child-frame","parentFrameId":"main-frame","isProvisional":false}}}"#
        )
        let proxy = try await WebInspectorProxy(transport: transport)
        let frame = WebInspectorTarget(
            id: WebInspectorTarget.ID("frame-target"),
            kind: .frame,
            frameID: FrameID("child-frame"),
            isProvisional: false,
            proxy: proxy,
            route: RoutingTargetID("frame-target")
        )
        let scopeTask = Task {
            do {
                try await frame.network.withEvents { _ in }
                return StructuredScopeOutcome.succeeded
            } catch WebInspectorProxyError.pageUnavailable {
                return .pageUnavailable
            } catch {
                return .other(String(describing: error))
            }
        }

        await backend.waitUntilSendStarted()
        await transport.receiveRootMessage(
            #"{"method":"Target.targetDestroyed","params":{"targetId":"frame-target"}}"#
        )
        #expect(try await value(of: scopeTask) == .pageUnavailable)
        await transport.waitForEventScopeCountForTesting(0)
    }

    #expect(weakTransport == nil)
    await backend.releaseSend()
}

@Test
func proxyWaitUntilClosedWaitsForInFlightCloseConnection() async throws {
    let closeGate = CloseConnectionGate()
    let proxy = WebInspectorProxy(localStateOnly: (), closeConnection: {
        await closeGate.waitUntilReleased()
    })

    let closeTask = Task {
        await proxy.close()
    }
    await closeGate.waitUntilStarted()

    let waitCompletion = CompletionProbe()
    let waitTask = Task {
        try await proxy.waitUntilClosed()
        await waitCompletion.finish()
    }
    await proxy.waitForCloseWaiterForTesting()
    #expect(await waitCompletion.isFinished() == false)

    await closeGate.release()
    try await waitTask.value
    await closeTask.value
    #expect(await waitCompletion.isFinished())
}

@Test
func proxyWaitUntilClosedCancellationRemovesWaiter() async throws {
    let proxy = WebInspectorProxy(localStateOnly: ())

    let waitTask = Task {
        try await proxy.waitUntilClosed()
    }
    await proxy.waitForCloseWaiterForTesting()

    waitTask.cancel()

    do {
        try await waitTask.value
        Issue.record("Expected waitUntilClosed cancellation to throw.")
    } catch is CancellationError {
        // Expected: cancellation is the waiter's failure path while the proxy remains open.
    } catch {
        Issue.record("Expected CancellationError, got \(error).")
    }

    await proxy.close()
    try await proxy.waitUntilClosed()
}

@Test
func transportBackedProxyDoesNotRefreshCurrentPageWhileClosing() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let closeGate = CloseConnectionGate()
    let proxy = try await WebInspectorProxy(transport: transport, closeConnection: {
        await closeGate.waitUntilReleased()
    })

    _ = try await proxy.waitForCurrentPage()
    let closeTask = Task {
        await proxy.close()
    }
    await closeGate.waitUntilStarted()

    do {
        _ = try await proxy.waitForCurrentPage()
        Issue.record("Expected waitForCurrentPage to fail after close started.")
    } catch WebInspectorProxyError.closed {
        // Expected: closing proxies must not refresh and republish current-page targets.
    } catch {
        Issue.record("Expected WebInspectorProxyError.closed, got \(error).")
    }
    #expect(await proxy.currentPage?.id == nil)

    await closeGate.release()
    await closeTask.value
    #expect(await proxy.currentPage?.id == nil)
}

@Test
func transportBackedCurrentPageRouteFollowsCommittedMainPageTarget() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport, targetID: ProtocolTarget.ID("page-old"))
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let firstReloadTask = Task {
        try await target.page.reload()
    }
    let firstSent = try await waitForTargetMessage(backend, method: "Page.reload")
    #expect(firstSent.targetIdentifier == ProtocolTarget.ID("page-old"))
    await receiveTargetReply(
        transport,
        targetID: firstSent.targetIdentifier,
        messageID: try messageID(firstSent.message),
        result: "{}"
    )
    try await firstReloadTask.value

    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-new","type":"page","isProvisional":true}}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-old","newTargetId":"page-new"}}"#
    )

    let secondReloadTask = Task {
        try await target.page.reload()
    }
    let secondSent = try await waitForTargetMessage(backend, method: "Page.reload", after: 1)
    #expect(secondSent.targetIdentifier == ProtocolTarget.ID("page-new"))
    await receiveTargetReply(
        transport,
        targetID: secondSent.targetIdentifier,
        messageID: try messageID(secondSent.message),
        result: "{}"
    )
    try await secondReloadTask.value
}

@Test
func transportBackedWaitForCurrentPageRefreshesDestroyedTargetWithoutLifecycleSubscription() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport, targetID: ProtocolTarget.ID("page-old"), frameID: "old-frame")
    let proxy = try await WebInspectorProxy(transport: transport)

    let cachedTarget = try await proxy.waitForCurrentPage()
    #expect(cachedTarget.frameID == FrameID("old-frame"))

    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"page-old"}}"#
    )

    let replacementTask = Task {
        try await proxy.waitForCurrentPage()
    }
    await installPageTarget(in: transport, targetID: ProtocolTarget.ID("page-new"), frameID: "new-frame")

    let replacement = try await throwingValue(of: replacementTask)
    #expect(replacement.id == .currentPage)
    #expect(replacement.route == .currentPage)
    #expect(replacement.frameID == FrameID("new-frame"))
    #expect(await proxy.currentPage?.frameID == FrameID("new-frame"))
}

@Test
func transportBackendProjectsFrameDOMEventsAndRoutesScopedCommands() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-target","type":"frame","frameId":"child-frame","parentFrameId":"main-frame","isProvisional":false}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let frameNodeID = DOM.Node.ID("42", scopedToTargetRawValue: "frame-target")
    let frameAttributesTask = Task {
        try await target.dom.attributes(of: frameNodeID)
    }
    let frameAttributes = try await waitForTargetMessage(backend, method: "DOM.getAttributes")
    #expect(frameAttributes.targetIdentifier == ProtocolTarget.ID("frame-target"))
    #expect((try messageParameters(frameAttributes.message)["nodeId"] as? NSNumber)?.intValue == 42)
    await receiveTargetReply(
        transport,
        targetID: frameAttributes.targetIdentifier,
        messageID: try messageID(frameAttributes.message),
        result: #"{"attributes":["class","frame-card"]}"#
    )
    #expect(try await frameAttributesTask.value == [
        DOM.Attribute(name: "class", value: "frame-card"),
    ])

    let frameSetAttributeTask = Task {
        try await target.dom.setAttributeValue(frameNodeID, name: "class", value: "frame-card selected")
    }
    let frameSetAttribute = try await waitForTargetMessage(backend, method: "DOM.setAttributeValue")
    #expect(frameSetAttribute.targetIdentifier == ProtocolTarget.ID("frame-target"))
    var parameters = try messageParameters(frameSetAttribute.message)
    #expect((parameters["nodeId"] as? NSNumber)?.intValue == 42)
    #expect(parameters["name"] as? String == "class")
    #expect(parameters["value"] as? String == "frame-card selected")
    await receiveTargetReply(
        transport,
        targetID: frameSetAttribute.targetIdentifier,
        messageID: try messageID(frameSetAttribute.message),
        result: "{}"
    )
    try await frameSetAttributeTask.value

    let frameSetAttributesTask = Task {
        try await target.dom.setAttributesAsText(frameNodeID, text: #"class="frame-card""#, name: "class")
    }
    let frameSetAttributes = try await waitForTargetMessage(backend, method: "DOM.setAttributesAsText")
    #expect(frameSetAttributes.targetIdentifier == ProtocolTarget.ID("frame-target"))
    parameters = try messageParameters(frameSetAttributes.message)
    #expect((parameters["nodeId"] as? NSNumber)?.intValue == 42)
    #expect(parameters["text"] as? String == #"class="frame-card""#)
    #expect(parameters["name"] as? String == "class")
    await receiveTargetReply(
        transport,
        targetID: frameSetAttributes.targetIdentifier,
        messageID: try messageID(frameSetAttributes.message),
        result: "{}"
    )
    try await frameSetAttributesTask.value

    let frameRemoveAttributeTask = Task {
        try await target.dom.removeAttribute(frameNodeID, name: "hidden")
    }
    let frameRemoveAttribute = try await waitForTargetMessage(backend, method: "DOM.removeAttribute")
    #expect(frameRemoveAttribute.targetIdentifier == ProtocolTarget.ID("frame-target"))
    parameters = try messageParameters(frameRemoveAttribute.message)
    #expect((parameters["nodeId"] as? NSNumber)?.intValue == 42)
    #expect(parameters["name"] as? String == "hidden")
    await receiveTargetReply(
        transport,
        targetID: frameRemoveAttribute.targetIdentifier,
        messageID: try messageID(frameRemoveAttribute.message),
        result: "{}"
    )
    try await frameRemoveAttributeTask.value

    let frameSetOuterHTMLTask = Task {
        try await target.dom.setOuterHTML(frameNodeID, html: #"<article class="frame-card"></article>"#)
    }
    let frameSetOuterHTML = try await waitForTargetMessage(backend, method: "DOM.setOuterHTML")
    #expect(frameSetOuterHTML.targetIdentifier == ProtocolTarget.ID("frame-target"))
    parameters = try messageParameters(frameSetOuterHTML.message)
    #expect((parameters["nodeId"] as? NSNumber)?.intValue == 42)
    #expect(parameters["outerHTML"] as? String == #"<article class="frame-card"></article>"#)
    await receiveTargetReply(
        transport,
        targetID: frameSetOuterHTML.targetIdentifier,
        messageID: try messageID(frameSetOuterHTML.message),
        result: "{}"
    )
    try await frameSetOuterHTMLTask.value

    let messageCountBeforeFrameHighlight = await backend.sentTargetMessages().count
    try await target.dom.highlightNode(frameNodeID)
    #expect(await backend.sentTargetMessages().count == messageCountBeforeFrameHighlight)

    let mainHighlightTask = Task {
        try await target.dom.highlightNode(DOM.Node.ID("42"))
    }
    let highlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: messageCountBeforeFrameHighlight
    )
    #expect(highlight.targetIdentifier == ProtocolTarget.ID("page-main"))
    #expect((try messageParameters(highlight.message)["nodeId"] as? NSNumber)?.intValue == 42)
    await receiveTargetReply(
        transport,
        targetID: highlight.targetIdentifier,
        messageID: try messageID(highlight.message),
        result: "{}"
    )
    try await mainHighlightTask.value

    let matchedStylesTask = Task {
        try await target.css.matchedStyles(for: frameNodeID)
    }
    let matchedStyles = try await waitForTargetMessage(backend, method: "CSS.getMatchedStylesForNode")
    #expect(matchedStyles.targetIdentifier == ProtocolTarget.ID("frame-target"))
    #expect((try messageParameters(matchedStyles.message)["nodeId"] as? NSNumber)?.intValue == 42)
    await receiveTargetReply(
        transport,
        targetID: matchedStyles.targetIdentifier,
        messageID: try messageID(matchedStyles.message),
        result: """
        {
          "matchedCSSRules": [
            {
              "rule": {
                "ruleId": {"styleSheetId": "frame-sheet", "ordinal": 7},
                "selectorList": {"selectors": [{"text": ".frame"}], "text": ".frame"},
                "origin": "author",
                "style": {
                  "styleId": {"styleSheetId": "frame-sheet", "ordinal": 7},
                  "cssProperties": [{"name": "color", "value": "red"}],
                  "cssText": "color: red;"
                }
              },
              "matchingSelectors": [0]
            }
          ],
          "inherited": [],
          "pseudoElements": []
        }
        """
    )
    let frameStyles = try await matchedStylesTask.value
    let frameRuleID = try #require(frameStyles.matchedRules.first?.id)
    let frameStyle = try #require(frameStyles.matchedRules.first?.style)
    #expect(frameRuleID.targetScopeRawValue == "frame-target")
    #expect(frameStyle.id.targetScopeRawValue == "frame-target")
    #expect(frameStyle.id.unscopedRawValue != frameStyle.id.rawValue)

    let setStyleTextTask = Task {
        try await target.css.setStyleText(frameStyle.id, text: "color: blue;")
    }
    let setStyleText = try await waitForTargetMessage(backend, method: "CSS.setStyleText")
    #expect(setStyleText.targetIdentifier == ProtocolTarget.ID("frame-target"))
    await receiveTargetReply(
        transport,
        targetID: setStyleText.targetIdentifier,
        messageID: try messageID(setStyleText.message),
        result: """
        {
          "style": {
            "styleId": {"styleSheetId": "frame-sheet", "ordinal": 7},
            "cssProperties": [{"name": "color", "value": "blue"}],
            "cssText": "color: blue;"
          }
        }
        """
    )
    let updatedFrameStyle = try await setStyleTextTask.value
    #expect(updatedFrameStyle.id.targetScopeRawValue == "frame-target")

    let frameSetRuleSelectorTask = Task {
        try await target.css.setRuleSelector(frameRuleID, selector: ".frame-card")
    }
    let frameSetRuleSelector = try await waitForTargetMessage(backend, method: "CSS.setRuleSelector")
    #expect(frameSetRuleSelector.targetIdentifier == ProtocolTarget.ID("frame-target"))
    parameters = try messageParameters(frameSetRuleSelector.message)
    let frameRuleSelectorPayload = try #require(parameters["ruleId"] as? [String: Any])
    #expect(frameRuleSelectorPayload["styleSheetId"] as? String == "frame-sheet")
    #expect((frameRuleSelectorPayload["ordinal"] as? NSNumber)?.intValue == 7)
    #expect(parameters["selector"] as? String == ".frame-card")
    await receiveTargetReply(
        transport,
        targetID: frameSetRuleSelector.targetIdentifier,
        messageID: try messageID(frameSetRuleSelector.message),
        result: """
        {
          "rule": {
            "ruleId": {"styleSheetId": "frame-sheet", "ordinal": 7},
            "selectorList": {"selectors": [{"text": ".frame-card"}], "text": ".frame-card"},
            "origin": "author",
            "style": {
              "styleId": {"styleSheetId": "frame-sheet", "ordinal": 7},
              "cssProperties": [{"name": "color", "value": "blue"}],
              "cssText": "color: blue;"
            }
          }
        }
        """
    )
    let updatedFrameRule = try await frameSetRuleSelectorTask.value
    #expect(updatedFrameRule.id?.targetScopeRawValue == "frame-target")
    #expect(updatedFrameRule.selectorList.text == ".frame-card")

    let frameSetGroupingHeaderTask = Task {
        try await target.css.setGroupingHeaderText(frameRuleID, text: "@media (min-width: 600px)")
    }
    let frameSetGroupingHeader = try await waitForTargetMessage(
        backend,
        method: "CSS.setGroupingHeaderText"
    )
    #expect(frameSetGroupingHeader.targetIdentifier == ProtocolTarget.ID("frame-target"))
    parameters = try messageParameters(frameSetGroupingHeader.message)
    let frameGroupingRulePayload = try #require(parameters["ruleId"] as? [String: Any])
    #expect(frameGroupingRulePayload["styleSheetId"] as? String == "frame-sheet")
    #expect((frameGroupingRulePayload["ordinal"] as? NSNumber)?.intValue == 7)
    #expect(parameters["headerText"] as? String == "@media (min-width: 600px)")
    await receiveTargetReply(
        transport,
        targetID: frameSetGroupingHeader.targetIdentifier,
        messageID: try messageID(frameSetGroupingHeader.message),
        result: #"{"grouping":{"text":"@media (min-width: 600px)"}}"#
    )
    #expect(try await frameSetGroupingHeaderTask.value.text == "@media (min-width: 600px)")

}

@Test
func transportBackendRoutesRequestNodeThroughPageDOMAgentWithoutInventingFrameScope() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-target","type":"frame","frameId":"child-frame","parentFrameId":"main-frame","isProvisional":false}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = proxy.frameTarget(id: WebInspectorTarget.ID("frame-target"))

    let requestNodeTask = Task {
        try await target.dom.requestNode(
            forRemoteObject: Runtime.RemoteObject.ID("frame-object", scopedToTargetRawValue: "frame-target")
        )
    }
    let requestNode = try await waitForTargetMessage(backend, method: "DOM.requestNode")
    #expect(requestNode.targetIdentifier == ProtocolTarget.ID("page-main"))
    #expect(try messageParameters(requestNode.message)["objectId"] as? String == "frame-object")
    await receiveTargetReply(
        transport,
        targetID: requestNode.targetIdentifier,
        messageID: try messageID(requestNode.message),
        result: #"{"nodeId":"frame-node"}"#
    )
    let nodeID = try await requestNodeTask.value
    #expect(nodeID == DOM.Node.ID("frame-node"))
    #expect(nodeID.targetScopeRawValue == nil)
}

@Test
func transportBackendForwardsBackendResourceIdentifierToResponseBodyCommand() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()
    let id = Network.Request.ID("cached-request")
    let backendResourceIdentifier = Network.BackendResourceID(
        sourceProcessID: "77",
        resourceID: "1234"
    )

    let bodyTask = Task {
        try await target.network.responseBody(
            for: id,
            backendResourceIdentifier: backendResourceIdentifier
        )
    }
    let bodyCommand = try await waitForTargetMessage(backend, method: "Network.getResponseBody")
    let parameters = try messageParameters(bodyCommand.message)
    #expect(parameters["requestId"] as? String == "cached-request")
    let identifier = try #require(parameters["backendResourceIdentifier"] as? [String: Any])
    #expect(identifier["sourceProcessID"] as? String == "77")
    #expect(identifier["resourceID"] as? String == "1234")
    await receiveTargetReply(
        transport,
        targetID: bodyCommand.targetIdentifier,
        messageID: try messageID(bodyCommand.message),
        result: #"{"body":"cached body","base64Encoded":false}"#
    )
    let body = try await bodyTask.value
    #expect(body.data == "cached body")
}

@Test
func transportCommandBackendDecodesRuntimeEvaluationResult() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = pageTarget(proxy: proxy)

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
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = pageTarget(proxy: proxy)
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

@Test
func pendingRepliesClassifyDirectAndCapabilityOwners() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)

    let directTask = Task {
        try await proxy.page.page.reload()
    }
    let reload = try await waitForTargetMessage(backend, method: "Page.reload")
    let reloadPendingKey = TransportSession.PendingKey.target(
        TransportSession.ReplyKey(
            targetID: reload.targetIdentifier,
            commandID: try messageID(reload.message)
        )
    )
    let reloadPurposes = await transport.pendingReplyPurposes()
    guard case let .direct(bindingGeneration, documentEpoch) = try #require(
        reloadPurposes[reloadPendingKey]
    ) else {
        Issue.record("Expected a direct reply purpose.")
        return
    }
    #expect(bindingGeneration == (try await transport.pageGeneration()))
    #expect(documentEpoch == nil)
    await receiveTargetReply(
        transport,
        targetID: reload.targetIdentifier,
        messageID: try messageID(reload.message),
        result: "{}"
    )
    try await directTask.value

    let bodyGate = CloseConnectionGate()
    let scopeTask = Task {
        try await proxy.page.network.withEvents { _ in
            await bodyGate.waitUntilReleased()
        }
    }
    let generation = try await transport.pageGeneration()
    let enable = try await waitForTargetMessage(backend, method: "Network.enable")
    let enableOperationID = try await requireCapabilityReplyPurpose(
        in: transport,
        message: enable,
        expectedGeneration: generation
    )
    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )
    await bodyGate.waitUntilStarted()
    #expect(await transport.pendingReplyPurposes().isEmpty)

    await bodyGate.release()
    let disable = try await waitForTargetMessage(backend, method: "Network.disable")
    let disableOperationID = try await requireCapabilityReplyPurpose(
        in: transport,
        message: disable,
        expectedGeneration: generation
    )
    #expect(disableOperationID > enableOperationID)
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )
    try await scopeTask.value
    #expect(await transport.pendingReplyPurposes().isEmpty)
}

@Test
func structuredNetworkScopeBuffersReplayBeforeEnableReplyAndBalancesDisable() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)

    let scopeTask = Task {
        try await proxy.page.network.withEvents(buffering: .bounded(1)) { events in
            var iterator = events.makeAsyncIterator()
            let reset = try await iterator.next()
            let event = try await iterator.next()
            return (reset, event)
        }
    }

    let enable = try await waitForTargetMessage(backend, method: "Network.enable")
    await receiveTargetEvent(
        transport,
        targetID: enable.targetIdentifier,
        method: "Network.loadingFinished",
        params: #"{"requestId":"enable-replay","timestamp":1}"#
    )
    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )

    let disable = try await waitForTargetMessage(backend, method: "Network.disable")
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )

    let (reset, event) = try await throwingValue(of: scopeTask)
    let generation: WebInspectorPage.Generation
    guard case let .reset(value)? = reset else {
        Issue.record("Expected an initial generation reset.")
        return
    }
    generation = value
    guard case let .event(eventGeneration, .loadingFinished(id, _, _, _))? = event else {
        Issue.record("Expected enable-time Network replay.")
        return
    }
    #expect(eventGeneration == generation)
    #expect(id == Network.Request.ID("enable-replay"))
}

@Test
func structuredNetworkScopePreservesFrameScopedIdentifiers() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-target","type":"frame","frameId":"child-frame","parentFrameId":"main-frame","isProvisional":false}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)

    let scopeTask = Task {
        try await proxy.page.network.withEvents { events in
            var iterator = events.makeAsyncIterator()
            _ = try await iterator.next()
            return try await iterator.next()
        }
    }

    let enable = try await waitForTargetMessage(backend, method: "Network.enable")
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("frame-target"),
        method: "Network.requestWillBeSent",
        params: #"{"requestId":"frame-request","request":{"url":"https://frame.example.test/","method":"GET"},"timestamp":1}"#
    )
    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )
    let disable = try await waitForTargetMessage(backend, method: "Network.disable")
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )

    guard case let .event(_, .requestWillBeSent(id, request, _, _, _))? = try await throwingValue(of: scopeTask) else {
        Issue.record("Expected a projected frame Network event.")
        return
    }
    #expect(id.targetScopeRawValue == "frame-target")
    #expect(request.id.targetScopeRawValue == "frame-target")
}

@Test
func structuredRuntimeScopePreservesFrameScopedIdentifiers() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-target","type":"frame","frameId":"child-frame","parentFrameId":"main-frame","isProvisional":false}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)

    let scopeTask = Task {
        try await proxy.page.runtime.withEvents { events in
            var iterator = events.makeAsyncIterator()
            _ = try await iterator.next()
            return try await iterator.next()
        }
    }

    let enable = try await waitForTargetMessage(backend, method: "Runtime.enable")
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("frame-target"),
        method: "Runtime.executionContextCreated",
        params: #"{"context":{"id":7,"name":"Frame","frameId":"child-frame","type":"normal"}}"#
    )
    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )
    let disable = try await waitForTargetMessage(backend, method: "Runtime.disable")
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )

    guard case let .event(_, .executionContextCreated(context))? = try await throwingValue(of: scopeTask) else {
        Issue.record("Expected a projected frame Runtime event.")
        return
    }
    #expect(context.id.targetScopeRawValue == "frame-target")
}

@Test
func structuredConsoleScopePreservesFrameScopedIdentifiers() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-target","type":"frame","frameId":"child-frame","parentFrameId":"main-frame","isProvisional":false}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)

    let scopeTask = Task {
        try await proxy.page.console.withEvents { events in
            var iterator = events.makeAsyncIterator()
            _ = try await iterator.next()
            return try await iterator.next()
        }
    }

    let enable = try await waitForTargetMessage(backend, method: "Console.enable")
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("frame-target"),
        method: "Console.messageAdded",
        params: #"{"message":{"source":"javascript","level":"log","text":"frame","parameters":[{"objectId":"frame-object","type":"object"}],"networkRequestId":"frame-request"}}"#
    )
    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )
    let disable = try await waitForTargetMessage(backend, method: "Console.disable")
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )

    guard case let .event(_, .messageAdded(message))? = try await throwingValue(of: scopeTask) else {
        Issue.record("Expected a projected frame Console event.")
        return
    }
    #expect(message.parameters.first?.id?.targetScopeRawValue == "frame-target")
    #expect(message.networkRequestID?.targetScopeRawValue == "frame-target")
}

@Test
func structuredNetworkScopesShareOneLeaseAndLateScopeIsFutureOnly() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let firstGate = CloseConnectionGate()
    let secondGate = CloseConnectionGate()

    let firstScope = Task {
        try await proxy.page.network.withEvents { events in
            var iterator = events.makeAsyncIterator()
            let reset = try await iterator.next()
            await firstGate.waitUntilReleased()
            return reset
        }
    }

    let enable = try await waitForTargetMessage(backend, method: "Network.enable")
    await receiveTargetEvent(
        transport,
        targetID: enable.targetIdentifier,
        method: "Network.loadingFinished",
        params: #"{"requestId":"first-only","timestamp":1}"#
    )
    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )
    await firstGate.waitUntilStarted()

    let secondScope = Task {
        try await proxy.page.network.withEvents { events in
            var iterator = events.makeAsyncIterator()
            let reset = try await iterator.next()
            await secondGate.waitUntilReleased()
            let event = try await iterator.next()
            return (reset, event)
        }
    }

    await secondGate.waitUntilStarted()
    await receiveTargetEvent(
        transport,
        targetID: enable.targetIdentifier,
        method: "Network.loadingFinished",
        params: #"{"requestId":"future","timestamp":2}"#
    )
    await secondGate.release()

    let (secondReset, secondEvent) = try await throwingValue(of: secondScope)
    guard case .reset? = secondReset else {
        Issue.record("Expected the late scope's generation reset.")
        return
    }
    guard case let .event(_, .loadingFinished(id, _, _, _))? = secondEvent else {
        Issue.record("Expected the late scope's future event.")
        return
    }
    #expect(id == Network.Request.ID("future"))

    let sentMessages = await backend.sentTargetMessages()
    let enableCount = try sentMessages.filter {
        try messageMethod($0.message) == "Network.enable"
    }.count
    #expect(enableCount == 1)
    let disableCountBeforeFinalRelease = try sentMessages.filter {
        try messageMethod($0.message) == "Network.disable"
    }.count
    #expect(disableCountBeforeFinalRelease == 0)

    await firstGate.release()
    let disable = try await waitForTargetMessage(backend, method: "Network.disable")
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )
    _ = try await throwingValue(of: firstScope)
}

@Test
func structuredNetworkScopeCancellationDuringEnableWaitsAndBalancesLease() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let bodyProbe = CompletionProbe()
    let completionProbe = CompletionProbe()

    let scopeTask = Task {
        let outcome: StructuredScopeOutcome
        do {
            try await proxy.page.network.withEvents { _ in
                await bodyProbe.finish()
            }
            outcome = .succeeded
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            outcome = .other(String(describing: error))
        }
        await completionProbe.finish()
        return outcome
    }

    let enable = try await waitForTargetMessage(backend, method: "Network.enable")
    scopeTask.cancel()
    await transport.waitForEventScopeCountForTesting(0)
    #expect(await completionProbe.isFinished() == false)
    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )
    let disable = try await waitForTargetMessage(backend, method: "Network.disable")
    #expect(await completionProbe.isFinished() == false)
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )

    #expect(try await value(of: scopeTask) == .cancelled)
    #expect(await completionProbe.isFinished())
    #expect(await bodyProbe.isFinished() == false)
}

@Test
func structuredNetworkScopeCancelledActivationIsNotTreatedAsPreviouslyActive() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let cancellationGate = CloseConnectionGate()
    await transport.replaceEventScopeActivationCancellationActionForTesting {
        await cancellationGate.waitUntilReleased()
    }

    let scopeTask = Task {
        do {
            try await proxy.page.network.withEvents { _ in }
            return StructuredScopeOutcome.succeeded
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .other(String(describing: error))
        }
    }

    let enable = try await waitForTargetMessage(backend, method: "Network.enable")
    scopeTask.cancel()
    await cancellationGate.waitUntilStarted()

    await receiveTargetError(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        message: "enable rejected"
    )
    #expect(await transport.terminalCause == nil)

    await cancellationGate.release()
    #expect(try await value(of: scopeTask) == .cancelled)
    await transport.waitForEventScopeCountForTesting(0)
    #expect(await transport.terminalCause == nil)

    let messages = await backend.sentTargetMessages()
    #expect(try messages.filter { try messageMethod($0.message) == "Network.enable" }.count == 1)
    #expect(try messages.filter { try messageMethod($0.message) == "Network.disable" }.isEmpty)
}

@Test
func structuredNetworkScopeCancellationDuringSharedEnableDoesNotCancelPeerLease() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let cancelledBodyProbe = CompletionProbe()
    let peerGate = CloseConnectionGate()

    let cancelledScope = Task {
        do {
            try await proxy.page.network.withEvents { _ in
                await cancelledBodyProbe.finish()
            }
            return StructuredScopeOutcome.succeeded
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .other(String(describing: error))
        }
    }
    let peerScope = Task {
        try await proxy.page.network.withEvents { events in
            var iterator = events.makeAsyncIterator()
            _ = try await iterator.next()
            await peerGate.waitUntilReleased()
        }
    }

    let enable = try await waitForTargetMessage(backend, method: "Network.enable")
    await transport.waitForEventScopeCountForTesting(2)
    cancelledScope.cancel()
    await transport.waitForEventScopeCountForTesting(1)

    #expect(try await value(of: cancelledScope) == .cancelled)
    #expect(await cancelledBodyProbe.isFinished() == false)
    var sentMessages = await backend.sentTargetMessages()
    #expect(try sentMessages.filter { try messageMethod($0.message) == "Network.enable" }.count == 1)
    #expect(try sentMessages.filter { try messageMethod($0.message) == "Network.disable" }.isEmpty)

    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )
    await peerGate.waitUntilStarted()

    sentMessages = await backend.sentTargetMessages()
    #expect(try sentMessages.filter { try messageMethod($0.message) == "Network.enable" }.count == 1)
    #expect(try sentMessages.filter { try messageMethod($0.message) == "Network.disable" }.isEmpty)

    await peerGate.release()
    let disable = try await waitForTargetMessage(backend, method: "Network.disable")
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )
    _ = try await throwingValue(of: peerScope)
}

@Test
func structuredNetworkScopeCancellationDuringEnablePreservesCleanupFailure() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)

    let scopeTask = Task {
        do {
            try await proxy.page.network.withEvents { _ in }
            return StructuredScopeOutcome.succeeded
        } catch let error as WebInspectorScopeError {
            let operationIsCancellation = error.operationError is CancellationError
            let cleanupIsExpected: Bool
            if let cleanupError = error.cleanupError as? WebInspectorProxyError,
               case WebInspectorProxyError.commandRejected(
                method: "Network.disable",
                message: "disable rejected"
               ) = cleanupError {
                cleanupIsExpected = true
            } else {
                cleanupIsExpected = false
            }
            return operationIsCancellation && cleanupIsExpected
                ? .combinedFailure
                : .other(String(describing: error))
        } catch {
            return .other(String(describing: error))
        }
    }

    let enable = try await waitForTargetMessage(backend, method: "Network.enable")
    scopeTask.cancel()
    await transport.waitForEventScopeCountForTesting(0)
    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )
    let disable = try await waitForTargetMessage(backend, method: "Network.disable")
    await receiveTargetError(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        message: "disable rejected"
    )

    #expect(try await value(of: scopeTask) == .combinedFailure)
}

@Test
func structuredNetworkScopeEnableTimeoutTerminatesConnectionWithoutReenabling() async throws {
    let backend = FakeTransportBackend()
    let timeout = ManualResponseTimeout()
    let transport = TransportSession(
        backend: backend,
        responseTimeout: .seconds(30),
        timeoutSleep: { duration in
            try await timeout.sleep(for: duration)
        }
    )
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)

    let scopeTask = Task {
        do {
            try await proxy.page.network.withEvents { _ in }
            return StructuredScopeOutcome.succeeded
        } catch WebInspectorProxyError.timeout(domain: "Network", method: "enable") {
            return .timeout
        } catch {
            return .other(String(describing: error))
        }
    }

    _ = try await waitForTargetMessage(backend, method: "Network.enable")
    await timeout.waitUntilSuspended()
    await timeout.fireNext()

    #expect(await scopeTask.value == .timeout)
    do {
        try await proxy.waitUntilClosed()
        Issue.record("Expected uncertain enable timeout to terminate the connection.")
    } catch WebInspectorProxyError.disconnected {
        // A timed-out enable may have succeeded on the wire, so the connection
        // is terminal after the initiating scope receives its timeout.
    } catch {
        Issue.record("Expected a disconnected terminal result, got \(error).")
    }

    let secondScope = Task {
        do {
            try await proxy.page.network.withEvents { _ in }
            return StructuredScopeOutcome.succeeded
        } catch WebInspectorProxyError.transportFailure {
            return .transportFailure
        } catch {
            return .other(String(describing: error))
        }
    }
    #expect(await secondScope.value == .transportFailure)

    let messages = await backend.sentTargetMessages()
    let enableCount = try messages.filter {
        try messageMethod($0.message) == "Network.enable"
    }.count
    #expect(enableCount == 1)
}

@Test
func structuredNetworkScopeDisableTimeoutTerminatesConnectionWithoutReusingWireState() async throws {
    let backend = FakeTransportBackend()
    let timeout = ManualResponseTimeout()
    let transport = TransportSession(
        backend: backend,
        responseTimeout: .seconds(30),
        timeoutSleep: { duration in
            try await timeout.sleep(for: duration)
        }
    )
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)

    let scopeTask = Task {
        do {
            try await proxy.page.network.withEvents { _ in }
            return StructuredScopeOutcome.succeeded
        } catch WebInspectorProxyError.timeout(domain: "Network", method: "disable") {
            return .timeout
        } catch {
            return .other(String(describing: error))
        }
    }

    let enable = try await waitForTargetMessage(backend, method: "Network.enable")
    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )
    _ = try await waitForTargetMessage(backend, method: "Network.disable")
    await timeout.waitUntilSuspended()
    await timeout.fireNext()

    #expect(try await value(of: scopeTask) == .timeout)
    do {
        try await proxy.waitUntilClosed()
        Issue.record("Expected uncertain disable timeout to terminate the connection.")
    } catch WebInspectorProxyError.disconnected {
        // A timed-out disable may have succeeded on the wire, so no later
        // scope can safely reuse the connection's cached capability state.
    } catch {
        Issue.record("Expected a disconnected terminal result, got \(error).")
    }

    let secondScope = Task {
        do {
            try await proxy.page.network.withEvents { _ in }
            return StructuredScopeOutcome.succeeded
        } catch WebInspectorProxyError.transportFailure {
            return .transportFailure
        } catch {
            return .other(String(describing: error))
        }
    }
    #expect(try await value(of: secondScope) == .transportFailure)

    let messages = await backend.sentTargetMessages()
    #expect(try messages.filter { try messageMethod($0.message) == "Network.enable" }.count == 1)
    #expect(try messages.filter { try messageMethod($0.message) == "Network.disable" }.count == 1)
}

@Test
func structuredNetworkScopePreservesBodyAndCleanupFailures() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)

    let scopeTask = Task {
        do {
            try await proxy.page.network.withEvents { _ -> Void in
                throw StructuredScopeBodyFailure()
            }
            return StructuredScopeOutcome.succeeded
        } catch let error as WebInspectorScopeError {
            let operationIsExpected = error.operationError is StructuredScopeBodyFailure
            let cleanupIsExpected: Bool
            if let cleanupError = error.cleanupError as? WebInspectorProxyError,
               case WebInspectorProxyError.commandRejected(
                method: "Network.disable",
                message: "disable rejected"
               ) = cleanupError {
                cleanupIsExpected = true
            } else {
                cleanupIsExpected = false
            }
            return operationIsExpected && cleanupIsExpected ? .combinedFailure : .other(String(describing: error))
        } catch {
            return .other(String(describing: error))
        }
    }

    let enable = try await waitForTargetMessage(backend, method: "Network.enable")
    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )
    let disable = try await waitForTargetMessage(backend, method: "Network.disable")
    await receiveTargetError(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        message: "disable rejected"
    )

    #expect(await scopeTask.value == StructuredScopeOutcome.combinedFailure)
}

@Test
func structuredNetworkScopeThrowsCleanupFailureAfterSuccessfulBody() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)

    let scopeTask = Task {
        do {
            try await proxy.page.network.withEvents { _ in }
            return StructuredScopeOutcome.succeeded
        } catch WebInspectorProxyError.commandRejected(
            method: "Network.disable",
            message: "disable rejected"
        ) {
            return .cleanupFailure
        } catch {
            return .other(String(describing: error))
        }
    }
    let enable = try await waitForTargetMessage(backend, method: "Network.enable")
    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )
    let disable = try await waitForTargetMessage(backend, method: "Network.disable")
    await receiveTargetError(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        message: "disable rejected"
    )

    #expect(await scopeTask.value == .cleanupFailure)
}

@Test
func structuredNetworkScopeRethrowsBodyFailureAfterSuccessfulCleanup() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)

    let scopeTask = Task {
        do {
            try await proxy.page.network.withEvents { _ -> Void in
                throw StructuredScopeBodyFailure()
            }
            return StructuredScopeOutcome.succeeded
        } catch is StructuredScopeBodyFailure {
            return .bodyFailure
        } catch {
            return .other(String(describing: error))
        }
    }
    let enable = try await waitForTargetMessage(backend, method: "Network.enable")
    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )
    let disable = try await waitForTargetMessage(backend, method: "Network.disable")
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )

    #expect(await scopeTask.value == .bodyFailure)
}

@Test
func structuredNetworkScopeEndsNormallyOnExplicitClose() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let closeGate = CloseConnectionGate()
    let proxy = try await WebInspectorProxy(transport: transport, closeConnection: {
        await closeGate.waitUntilReleased()
    })
    let bodyGate = CloseConnectionGate()
    let bodyCompletion = CompletionProbe()

    let scopeTask = Task {
        do {
            return try await proxy.page.network.withEvents { events in
                var iterator = events.makeAsyncIterator()
                _ = try await iterator.next()
                await bodyGate.waitUntilReleased()
                guard try await iterator.next() == nil else {
                    return StructuredScopeOutcome.other(
                        "Expected explicit close to finish the stream normally."
                    )
                }
                await bodyCompletion.finish()
                return StructuredScopeOutcome.succeeded
            }
        } catch {
            return StructuredScopeOutcome.other(String(describing: error))
        }
    }
    let enable = try await waitForTargetMessage(backend, method: "Network.enable")
    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )
    await bodyGate.waitUntilStarted()
    await bodyGate.release()

    let closeTask = Task {
        await proxy.close()
    }
    await closeGate.waitUntilStarted()

    #expect(await transport.activeEventScopeSubscriberCountForTesting() == 1)
    #expect(await bodyCompletion.isFinished() == false)

    await closeGate.release()
    await closeTask.value

    #expect(await scopeTask.value == .succeeded)
    #expect(await bodyCompletion.isFinished())
}

@Test
func structuredNetworkScopeThrowsTransportFailureOnNativeFatal() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let bodyGate = CloseConnectionGate()

    let scopeTask = Task {
        do {
            try await proxy.page.network.withEvents { events in
                var iterator = events.makeAsyncIterator()
                _ = try await iterator.next()
                await bodyGate.waitUntilReleased()
                while try await iterator.next() != nil {}
            }
            return StructuredScopeOutcome.succeeded
        } catch WebInspectorProxyError.transportFailure("native fatal") {
            return .transportFailure
        } catch {
            return .other(String(describing: error))
        }
    }
    let enable = try await waitForTargetMessage(backend, method: "Network.enable")
    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )
    await bodyGate.waitUntilStarted()
    await bodyGate.release()

    let fatalHandoff = try #require(transport.failFromNativeCallback("native fatal"))
    await fatalHandoff.value

    #expect(await scopeTask.value == .transportFailure)
}

@Test
func structuredNetworkScopeMalformedKnownEventTerminatesWithProtocolViolation() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let bodyGate = CloseConnectionGate()

    let scopeTask = Task {
        do {
            try await proxy.page.network.withEvents { events in
                var iterator = events.makeAsyncIterator()
                _ = try await iterator.next()
                await bodyGate.waitUntilReleased()
                while try await iterator.next() != nil {}
            }
            return StructuredScopeOutcome.succeeded
        } catch is WebInspectorScopeError {
            return .other("Connection termination must not also report a cleanup failure.")
        } catch WebInspectorProxyError.protocolViolation {
            return .protocolViolation
        } catch {
            return .other(String(describing: error))
        }
    }
    let enable = try await waitForTargetMessage(backend, method: "Network.enable")
    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )
    await bodyGate.waitUntilStarted()
    await bodyGate.release()

    await receiveTargetEvent(
        transport,
        targetID: enable.targetIdentifier,
        method: "Network.loadingFinished",
        params: #"{"timestamp":1}"#
    )

    #expect(await scopeTask.value == .protocolViolation)
}

@Test
func malformedTargetCreatedTerminatesBeforeRegistryCanDrift() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))

    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"type":"page","isProvisional":false}}}"#
    )

    do {
        try await transport.waitUntilClosed()
        Issue.record("Expected malformed Target.targetCreated to terminate the connection.")
    } catch WebInspectorProxyError.protocolViolation {
        // Registry-mutating known events are fail-fast at ingress.
    } catch {
        Issue.record("Expected protocol violation, got \(error).")
    }
    #expect(await transport.snapshot().targetsByID.isEmpty)
}

@Test
func targetCommitWithoutRequiredOldTargetTerminatesWithProtocolViolation() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)

    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"newTargetId":"page-next"}}"#
    )

    do {
        try await transport.waitUntilClosed()
        Issue.record("Expected missing oldTargetId to terminate the connection.")
    } catch WebInspectorProxyError.protocolViolation {
        // iOS 18.4+ makes both commit identifiers required.
    } catch {
        Issue.record("Expected protocol violation, got \(error).")
    }
}

@Test
func structuredNetworkScopeKeepsUnknownMethodsAsRawEvents() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)

    let scopeTask = Task {
        try await proxy.page.network.withEvents { events in
            var iterator = events.makeAsyncIterator()
            _ = try await iterator.next()
            return try await iterator.next()
        }
    }
    let enable = try await waitForTargetMessage(backend, method: "Network.enable")
    await receiveTargetEvent(
        transport,
        targetID: enable.targetIdentifier,
        method: "Network.futureEvent",
        params: #"{"value":42}"#
    )
    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )
    let disable = try await waitForTargetMessage(backend, method: "Network.disable")
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )

    guard case let .event(_, .unknown(rawEvent))? = try await throwingValue(of: scopeTask) else {
        Issue.record("Expected an unknown Network event.")
        return
    }
    #expect(rawEvent.domain == "Network")
    #expect(rawEvent.method == "futureEvent")
}

@Test
func structuredNetworkScopeMalformedRootEnvelopeTerminatesWithProtocolViolation() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let bodyGate = CloseConnectionGate()

    let scopeTask = Task {
        do {
            try await proxy.page.network.withEvents { events in
                var iterator = events.makeAsyncIterator()
                _ = try await iterator.next()
                await bodyGate.waitUntilReleased()
                while try await iterator.next() != nil {}
            }
            return StructuredScopeOutcome.succeeded
        } catch WebInspectorProxyError.protocolViolation {
            return .protocolViolation
        } catch {
            return .other(String(describing: error))
        }
    }
    let enable = try await waitForTargetMessage(backend, method: "Network.enable")
    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )
    await bodyGate.waitUntilStarted()
    await bodyGate.release()

    await transport.receiveRootMessage("{")

    #expect(await scopeTask.value == .protocolViolation)
}

@Test
func structuredNetworkScopePreservesPendingEventBeforeRetargetResetAndNewReplay() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let gate = CloseConnectionGate()

    let scopeTask = Task {
        try await proxy.page.network.withEvents(buffering: .bounded(2)) { events in
            var iterator = events.makeAsyncIterator()
            let initialReset = try await iterator.next()
            await gate.waitUntilReleased()
            let precedingEvent = try await iterator.next()
            let replacementReset = try await iterator.next()
            let replay = try await iterator.next()
            return (initialReset, precedingEvent, replacementReset, replay)
        }
    }

    let initialEnable = try await waitForTargetMessage(backend, method: "Network.enable")
    await receiveTargetReply(
        transport,
        targetID: initialEnable.targetIdentifier,
        messageID: try messageID(initialEnable.message),
        result: "{}"
    )
    await gate.waitUntilStarted()

    await receiveTargetEvent(
        transport,
        targetID: initialEnable.targetIdentifier,
        method: "Network.loadingFinished",
        params: #"{"requestId":"preceding-event","timestamp":2}"#
    )

    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-next","type":"page","frameId":"main-frame","isProvisional":true}}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"page-next"}}"#
    )

    let replacementEnable = try await waitForTargetMessage(
        backend,
        method: "Network.enable",
        ordinal: 1
    )
    #expect(replacementEnable.targetIdentifier == ProtocolTarget.ID("page-next"))
    await receiveTargetEvent(
        transport,
        targetID: replacementEnable.targetIdentifier,
        method: "Network.loadingFinished",
        params: #"{"requestId":"replacement-replay","timestamp":3}"#
    )
    await receiveTargetReply(
        transport,
        targetID: replacementEnable.targetIdentifier,
        messageID: try messageID(replacementEnable.message),
        result: "{}"
    )
    await gate.release()

    let disable = try await waitForTargetMessage(backend, method: "Network.disable")
    #expect(disable.targetIdentifier == ProtocolTarget.ID("page-next"))
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )

    let (initial, preceding, replacement, replay) = try await throwingValue(of: scopeTask)
    guard case let .reset(initialGeneration)? = initial,
          case let .reset(replacementGeneration)? = replacement else {
        Issue.record("Expected initial and replacement reset markers.")
        return
    }
    #expect(initialGeneration != replacementGeneration)
    guard case let .event(precedingGeneration, .loadingFinished(precedingID, _, _, _))? = preceding else {
        Issue.record("Expected the pending old-generation event before the replacement reset.")
        return
    }
    #expect(precedingGeneration == initialGeneration)
    #expect(precedingID == Network.Request.ID("preceding-event"))
    guard case let .event(eventGeneration, .loadingFinished(id, _, _, _))? = replay else {
        Issue.record("Expected replacement enable replay.")
        return
    }
    #expect(eventGeneration == replacementGeneration)
    #expect(id == Network.Request.ID("replacement-replay"))
}

@Test
func structuredNetworkScopeCoalescesConsecutiveDirectReplacementResetsWithoutConsumingCapacity() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let gate = CloseConnectionGate()

    let scopeTask = Task {
        try await proxy.page.network.withEvents(buffering: .bounded(1)) { events in
            var iterator = events.makeAsyncIterator()
            let initialReset = try await iterator.next()
            await gate.waitUntilReleased()
            let replacementReset = try await iterator.next()
            let replay = try await iterator.next()
            return (initialReset, replacementReset, replay)
        }
    }

    let initialEnable = try await waitForTargetMessage(backend, method: "Network.enable")
    await receiveTargetReply(
        transport,
        targetID: initialEnable.targetIdentifier,
        messageID: try messageID(initialEnable.message),
        result: "{}"
    )
    await gate.waitUntilStarted()

    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-next-1","type":"page","frameId":"main-frame","isProvisional":true}}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"page-next-1"}}"#
    )
    let firstReplacementEnable = try await waitForTargetMessage(
        backend,
        method: "Network.enable",
        ordinal: 1
    )
    #expect(firstReplacementEnable.targetIdentifier == ProtocolTarget.ID("page-next-1"))
    let intermediateGeneration = try await proxy.page.generation
    await receiveTargetReply(
        transport,
        targetID: firstReplacementEnable.targetIdentifier,
        messageID: try messageID(firstReplacementEnable.message),
        result: "{}"
    )

    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-next-2","type":"page","frameId":"main-frame","isProvisional":true}}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-next-1","newTargetId":"page-next-2"}}"#
    )
    let latestGeneration = try await proxy.page.generation
    #expect(latestGeneration != intermediateGeneration)

    let secondReplacementEnable = try await waitForTargetMessage(
        backend,
        method: "Network.enable",
        ordinal: 2
    )
    #expect(secondReplacementEnable.targetIdentifier == ProtocolTarget.ID("page-next-2"))
    await receiveTargetEvent(
        transport,
        targetID: secondReplacementEnable.targetIdentifier,
        method: "Network.loadingFinished",
        params: #"{"requestId":"latest-replay","timestamp":4}"#
    )
    await receiveTargetReply(
        transport,
        targetID: secondReplacementEnable.targetIdentifier,
        messageID: try messageID(secondReplacementEnable.message),
        result: "{}"
    )
    await gate.release()

    let disable = try await waitForTargetMessage(backend, method: "Network.disable")
    #expect(disable.targetIdentifier == ProtocolTarget.ID("page-next-2"))
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )

    let (initial, replacement, replay) = try await throwingValue(of: scopeTask)
    guard case let .reset(initialGeneration)? = initial,
          case let .reset(replacementGeneration)? = replacement else {
        Issue.record("Expected one initial reset and one coalesced replacement reset.")
        return
    }
    #expect(initialGeneration != replacementGeneration)
    #expect(replacementGeneration == latestGeneration)
    guard case let .event(eventGeneration, .loadingFinished(id, _, _, _))? = replay else {
        Issue.record("Expected the latest generation replay immediately after the coalesced reset.")
        return
    }
    #expect(eventGeneration == latestGeneration)
    #expect(id == Network.Request.ID("latest-replay"))
}

@Test
func structuredNetworkScopeSurvivesReplacementDestroyedDuringReenable() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let gate = CloseConnectionGate()

    let scopeTask = Task {
        try await proxy.page.network.withEvents(buffering: .bounded(1)) { events in
            var iterator = events.makeAsyncIterator()
            let initialReset = try await iterator.next()
            await gate.waitUntilReleased()
            let replacementReset = try await iterator.next()
            let replay = try await iterator.next()
            return (initialReset, replacementReset, replay)
        }
    }

    let initialEnable = try await waitForTargetMessage(backend, method: "Network.enable")
    await receiveTargetReply(
        transport,
        targetID: initialEnable.targetIdentifier,
        messageID: try messageID(initialEnable.message),
        result: "{}"
    )
    await gate.waitUntilStarted()

    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-replacement-a","type":"page","frameId":"main-frame","isProvisional":true}}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"page-replacement-a"}}"#
    )
    let abandonedEnable = try await waitForTargetMessage(
        backend,
        method: "Network.enable",
        ordinal: 1
    )
    #expect(abandonedEnable.targetIdentifier == ProtocolTarget.ID("page-replacement-a"))

    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"page-replacement-a"}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-replacement-b","type":"page","frameId":"main-frame","isProvisional":false}}}"#
    )
    let latestGeneration = try await proxy.page.generation

    let replacementEnable = try await waitForTargetMessage(
        backend,
        method: "Network.enable",
        ordinal: 2
    )
    #expect(replacementEnable.targetIdentifier == ProtocolTarget.ID("page-replacement-b"))
    await receiveTargetEvent(
        transport,
        targetID: replacementEnable.targetIdentifier,
        method: "Network.loadingFinished",
        params: #"{"requestId":"surviving-replay","timestamp":5}"#
    )
    await receiveTargetReply(
        transport,
        targetID: replacementEnable.targetIdentifier,
        messageID: try messageID(replacementEnable.message),
        result: "{}"
    )
    await gate.release()

    let disable = try await waitForTargetMessage(backend, method: "Network.disable")
    #expect(disable.targetIdentifier == ProtocolTarget.ID("page-replacement-b"))
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )

    let (initial, replacement, replay) = try await throwingValue(of: scopeTask)
    guard case let .reset(initialGeneration)? = initial,
          case let .reset(replacementGeneration)? = replacement else {
        Issue.record("Expected initial and latest replacement resets.")
        return
    }
    #expect(initialGeneration != replacementGeneration)
    #expect(replacementGeneration == latestGeneration)
    guard case let .event(eventGeneration, .loadingFinished(id, _, _, _))? = replay else {
        Issue.record("Expected replay from the surviving replacement target.")
        return
    }
    #expect(eventGeneration == latestGeneration)
    #expect(id == Network.Request.ID("surviving-replay"))
    #expect(await transport.terminalCause == nil)
}

@Test
func structuredNetworkScopeCoalescesDestroyCreateIntoOneReplacementReset() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let gate = CloseConnectionGate()

    let scopeTask = Task {
        try await proxy.page.network.withEvents(buffering: .bounded(1)) { events in
            var iterator = events.makeAsyncIterator()
            let initialReset = try await iterator.next()
            await gate.waitUntilReleased()
            let replacementReset = try await iterator.next()
            let replay = try await iterator.next()
            return (initialReset, replacementReset, replay)
        }
    }

    let initialEnable = try await waitForTargetMessage(backend, method: "Network.enable")
    await receiveTargetReply(
        transport,
        targetID: initialEnable.targetIdentifier,
        messageID: try messageID(initialEnable.message),
        result: "{}"
    )
    await gate.waitUntilStarted()

    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"page-main"}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-next","type":"page","frameId":"main-frame","isProvisional":false}}}"#
    )

    let replacementEnable = try await waitForTargetMessage(
        backend,
        method: "Network.enable",
        ordinal: 1
    )
    #expect(replacementEnable.targetIdentifier == ProtocolTarget.ID("page-next"))
    await receiveTargetEvent(
        transport,
        targetID: replacementEnable.targetIdentifier,
        method: "Network.loadingFinished",
        params: #"{"requestId":"destroy-create-replay","timestamp":4}"#
    )
    await receiveTargetReply(
        transport,
        targetID: replacementEnable.targetIdentifier,
        messageID: try messageID(replacementEnable.message),
        result: "{}"
    )
    await gate.release()

    let disable = try await waitForTargetMessage(backend, method: "Network.disable")
    #expect(disable.targetIdentifier == ProtocolTarget.ID("page-next"))
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )

    let (initial, replacement, replay) = try await throwingValue(of: scopeTask)
    guard case let .reset(initialGeneration)? = initial,
          case let .reset(replacementGeneration)? = replacement else {
        Issue.record("Expected exactly one reset for the replacement generation.")
        return
    }
    #expect(initialGeneration != replacementGeneration)
    guard case let .event(eventGeneration, .loadingFinished(id, _, _, _))? = replay else {
        Issue.record("Expected replacement replay immediately after the reset.")
        return
    }
    #expect(eventGeneration == replacementGeneration)
    #expect(id == Network.Request.ID("destroy-create-replay"))
}

@Test
func structuredNetworkScopeTreatsCurrentPageDestroyDuringDisableAsSuccessfulCleanup() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let bodyGate = CloseConnectionGate()

    let scopeTask = Task {
        do {
            try await proxy.page.network.withEvents { events in
                var iterator = events.makeAsyncIterator()
                _ = try await iterator.next()
                await bodyGate.waitUntilReleased()
            }
            return StructuredScopeOutcome.succeeded
        } catch {
            return .other(String(describing: error))
        }
    }

    let enable = try await waitForTargetMessage(backend, method: "Network.enable")
    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )
    await bodyGate.waitUntilStarted()
    await bodyGate.release()

    let disable = try await waitForTargetMessage(backend, method: "Network.disable")
    #expect(disable.targetIdentifier == ProtocolTarget.ID("page-main"))
    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"page-main"}}"#
    )

    #expect(await scopeTask.value == .succeeded)
    #expect(await transport.terminalCause == nil)
    let messages = await backend.sentTargetMessages()
    let disableCount = try messages.filter {
        try messageMethod($0.message) == "Network.disable"
    }.count
    #expect(disableCount == 1)
}

@Test
func structuredPhysicalTargetScopeFinishesWithoutDisableWhenTargetIsDestroyed() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-target","type":"frame","frameId":"child-frame","parentFrameId":"main-frame","isProvisional":false}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let frame = WebInspectorTarget(
        id: WebInspectorTarget.ID("frame-target"),
        kind: .frame,
        frameID: FrameID("child-frame"),
        isProvisional: false,
        proxy: proxy,
        route: RoutingTargetID("frame-target")
    )
    let bodyGate = CloseConnectionGate()

    let scopeTask = Task {
        do {
            try await frame.network.withEvents { events in
                var iterator = events.makeAsyncIterator()
                _ = try await iterator.next()
                await bodyGate.waitUntilReleased()
                while try await iterator.next() != nil {}
            }
            return StructuredScopeOutcome.succeeded
        } catch WebInspectorProxyError.pageUnavailable {
            return .pageUnavailable
        } catch {
            return .other(String(describing: error))
        }
    }

    let enable = try await waitForTargetMessage(backend, method: "Network.enable")
    #expect(enable.targetIdentifier == ProtocolTarget.ID("frame-target"))
    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )
    await bodyGate.waitUntilStarted()
    await bodyGate.release()
    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"frame-target"}}"#
    )

    #expect(await scopeTask.value == .pageUnavailable)
    let messages = await backend.sentTargetMessages()
    let disableCount = try messages.filter {
        try messageMethod($0.message) == "Network.disable"
    }.count
    #expect(disableCount == 0)
    #expect(await transport.terminalCause == nil)
}

@Test
func structuredPhysicalTargetScopeFailsAcquisitionWhenTargetDiesDuringEnable() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-target","type":"frame","frameId":"child-frame","parentFrameId":"main-frame","isProvisional":false}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let frame = WebInspectorTarget(
        id: WebInspectorTarget.ID("frame-target"),
        kind: .frame,
        frameID: FrameID("child-frame"),
        isProvisional: false,
        proxy: proxy,
        route: RoutingTargetID("frame-target")
    )
    let bodyProbe = CompletionProbe()

    let scopeTask = Task {
        do {
            try await frame.network.withEvents { _ in
                await bodyProbe.finish()
            }
            return StructuredScopeOutcome.succeeded
        } catch WebInspectorProxyError.pageUnavailable {
            return .pageUnavailable
        } catch {
            return .other(String(describing: error))
        }
    }

    let enable = try await waitForTargetMessage(backend, method: "Network.enable")
    #expect(enable.targetIdentifier == ProtocolTarget.ID("frame-target"))
    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"frame-target"}}"#
    )

    #expect(await scopeTask.value == .pageUnavailable)
    #expect(await bodyProbe.isFinished() == false)
    await transport.waitForEventScopeCountForTesting(0)
    let messages = await backend.sentTargetMessages()
    let disableCount = try messages.filter {
        try messageMethod($0.message) == "Network.disable"
    }.count
    #expect(disableCount == 0)
}

@Test
func structuredFixedTargetScopeFailsAtCommitWithoutRetargetingPendingEnable() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-next","type":"page","frameId":"main-frame","isProvisional":true}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let fixedPage = WebInspectorTarget(
        id: WebInspectorTarget.ID("page-main"),
        kind: .page,
        frameID: FrameID("main-frame"),
        isProvisional: false,
        proxy: proxy,
        route: RoutingTargetID("page-main")
    )
    let bodyProbe = CompletionProbe()

    let scopeTask = Task {
        do {
            try await fixedPage.network.withEvents { _ in
                await bodyProbe.finish()
            }
            return StructuredScopeOutcome.succeeded
        } catch WebInspectorProxyError.pageUnavailable {
            return .pageUnavailable
        } catch {
            return .other(String(describing: error))
        }
    }

    let enable = try await waitForTargetMessage(backend, method: "Network.enable")
    #expect(enable.targetIdentifier == ProtocolTarget.ID("page-main"))
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"page-next"}}"#
    )

    #expect(try await value(of: scopeTask) == .pageUnavailable)
    #expect(await bodyProbe.isFinished() == false)
    await transport.waitForEventScopeCountForTesting(0)
    #expect(await transport.terminalCause == nil)

    let messages = await backend.sentTargetMessages()
    #expect(messages.count == 1)
    #expect(messages[0].targetIdentifier == ProtocolTarget.ID("page-main"))
    #expect(try messageMethod(messages[0].message) == "Network.enable")
}

@Test
func structuredNetworkScopeLateAcquireDuringReenableDoesNotDisableLiveLease() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let firstGate = CloseConnectionGate()
    let lateGate = CloseConnectionGate()

    let firstScope = Task {
        try await proxy.page.network.withEvents { events in
            var iterator = events.makeAsyncIterator()
            _ = try await iterator.next()
            await firstGate.waitUntilReleased()
        }
    }

    let initialEnable = try await waitForTargetMessage(backend, method: "Network.enable")
    await receiveTargetReply(
        transport,
        targetID: initialEnable.targetIdentifier,
        messageID: try messageID(initialEnable.message),
        result: "{}"
    )
    await firstGate.waitUntilStarted()

    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-next","type":"page","frameId":"main-frame","isProvisional":true}}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"page-next"}}"#
    )
    let replacementEnable = try await waitForTargetMessage(
        backend,
        method: "Network.enable",
        ordinal: 1
    )

    await firstGate.release()
    await transport.waitForEventScopeCountForTesting(0)

    let lateScope = Task {
        try await proxy.page.network.withEvents { events in
            var iterator = events.makeAsyncIterator()
            _ = try await iterator.next()
            await lateGate.waitUntilReleased()
        }
    }
    await transport.waitForEventScopeCountForTesting(1)

    await receiveTargetReply(
        transport,
        targetID: replacementEnable.targetIdentifier,
        messageID: try messageID(replacementEnable.message),
        result: "{}"
    )
    await lateGate.waitUntilStarted()
    _ = try await throwingValue(of: firstScope)

    let messagesBeforeLateRelease = await backend.sentTargetMessages()
    let disableCount = try messagesBeforeLateRelease.filter {
        try messageMethod($0.message) == "Network.disable"
    }.count
    #expect(disableCount == 0)

    await lateGate.release()
    let disable = try await waitForTargetMessage(backend, method: "Network.disable")
    #expect(disable.targetIdentifier == ProtocolTarget.ID("page-next"))
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )
    _ = try await throwingValue(of: lateScope)
}

@Test
func structuredNetworkScopeLateAcquireDuringDisableReenablesAfterCleanup() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let firstGate = CloseConnectionGate()
    let lateGate = CloseConnectionGate()

    let firstScope = Task {
        try await proxy.page.network.withEvents { events in
            var iterator = events.makeAsyncIterator()
            _ = try await iterator.next()
            await firstGate.waitUntilReleased()
        }
    }
    let firstEnable = try await waitForTargetMessage(backend, method: "Network.enable")
    await receiveTargetReply(
        transport,
        targetID: firstEnable.targetIdentifier,
        messageID: try messageID(firstEnable.message),
        result: "{}"
    )
    await firstGate.waitUntilStarted()

    await firstGate.release()
    let firstDisable = try await waitForTargetMessage(backend, method: "Network.disable")
    await transport.waitForEventScopeCountForTesting(0)

    let lateScope = Task {
        try await proxy.page.network.withEvents { events in
            var iterator = events.makeAsyncIterator()
            _ = try await iterator.next()
            await lateGate.waitUntilReleased()
        }
    }
    await transport.waitForEventScopeCountForTesting(1)

    await receiveTargetReply(
        transport,
        targetID: firstDisable.targetIdentifier,
        messageID: try messageID(firstDisable.message),
        result: "{}"
    )
    _ = try await throwingValue(of: firstScope)

    let secondEnable = try await waitForTargetMessage(
        backend,
        method: "Network.enable",
        ordinal: 1
    )
    await receiveTargetReply(
        transport,
        targetID: secondEnable.targetIdentifier,
        messageID: try messageID(secondEnable.message),
        result: "{}"
    )
    await lateGate.waitUntilStarted()

    let messagesBeforeLateRelease = await backend.sentTargetMessages()
    let disableCount = try messagesBeforeLateRelease.filter {
        try messageMethod($0.message) == "Network.disable"
    }.count
    #expect(disableCount == 1)

    await lateGate.release()
    let finalDisable = try await waitForTargetMessage(
        backend,
        method: "Network.disable",
        ordinal: 1
    )
    await receiveTargetReply(
        transport,
        targetID: finalDisable.targetIdentifier,
        messageID: try messageID(finalDisable.message),
        result: "{}"
    )
    _ = try await throwingValue(of: lateScope)
}

@Test
func structuredNetworkScopeOverflowTerminatesOnlyStalledSubscriber() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let stalledGate = CloseConnectionGate()
    let peerGate = CloseConnectionGate()
    let peerConsumedGate = CloseConnectionGate()

    let stalled = Task {
        do {
            try await proxy.page.network.withEvents(buffering: .bounded(2)) { events in
                await stalledGate.waitUntilReleased()
                for try await _ in events {}
            }
            return StructuredScopeOutcome.succeeded
        } catch WebInspectorProxyError.eventBufferOverflow(capacity: 2) {
            return .overflow
        } catch {
            return .other(String(describing: error))
        }
    }
    let peer = Task {
        try await proxy.page.network.withEvents(buffering: .bounded(2)) { events in
            var iterator = events.makeAsyncIterator()
            _ = try await iterator.next()
            await peerGate.waitUntilReleased()
            let first = try await iterator.next()
            let second = try await iterator.next()
            await peerConsumedGate.waitUntilReleased()
            let third = try await iterator.next()
            return (first, second, third)
        }
    }

    let enable = try await waitForTargetMessage(backend, method: "Network.enable")
    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )
    await stalledGate.waitUntilStarted()
    await peerGate.waitUntilStarted()

    for ordinal in 1...2 {
        await receiveTargetEvent(
            transport,
            targetID: enable.targetIdentifier,
            method: "Network.loadingFinished",
            params: #"{"requestId":"overflow-\#(ordinal)","timestamp":\#(ordinal)}"#
        )
    }
    await peerGate.release()
    await peerConsumedGate.waitUntilStarted()
    await receiveTargetEvent(
        transport,
        targetID: enable.targetIdentifier,
        method: "Network.loadingFinished",
        params: #"{"requestId":"overflow-3","timestamp":3}"#
    )
    await peerConsumedGate.release()
    await stalledGate.release()

    let disable = try await waitForTargetMessage(backend, method: "Network.disable")
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )

    #expect(await stalled.value == .overflow)
    let (first, second, third) = try await throwingValue(of: peer)
    guard case let .event(_, .loadingFinished(firstID, _, _, _))? = first,
          case let .event(_, .loadingFinished(secondID, _, _, _))? = second,
          case let .event(_, .loadingFinished(thirdID, _, _, _))? = third else {
        Issue.record("Expected the peer subscriber to receive all events.")
        return
    }
    #expect(firstID == Network.Request.ID("overflow-1"))
    #expect(secondID == Network.Request.ID("overflow-2"))
    #expect(thirdID == Network.Request.ID("overflow-3"))
}

private func pageTarget(proxy: WebInspectorProxy) -> WebInspectorTarget {
    WebInspectorTarget(
        id: WebInspectorTarget.ID("page-main"),
        kind: .page,
        frameID: FrameID("main-frame"),
        isProvisional: false,
        proxy: proxy,
        route: RoutingTargetID("page-main")
    )
}

private func requireCapabilityReplyPurpose(
    in transport: TransportSession,
    message: SentTargetMessage,
    expectedGeneration: WebInspectorPage.Generation
) async throws -> UInt64 {
    let pendingKey = TransportSession.PendingKey.target(
        TransportSession.ReplyKey(
            targetID: message.targetIdentifier,
            commandID: try messageID(message.message)
        )
    )
    let purposes = await transport.pendingReplyPurposes()
    #expect(purposes.count == 1)
    let purpose = try #require(purposes[pendingKey])
    switch purpose {
    case .direct, .elementPickerMode, .modelCommand, .capabilityAuxiliary:
        Issue.record("Expected a capability reply purpose.")
        return 0
    case .modelBootstrap:
        Issue.record("Expected a capability reply purpose.")
        return 0
    case let .capability(key, generation, operationID):
        #expect(key.route == .currentPage)
        #expect(key.targetID == .currentPage)
        #expect(key.domain == .network)
        #expect(generation == expectedGeneration)
        #expect(operationID > 0)
        return operationID
    }
}

private func installPageTarget(
    in transport: TransportSession,
    targetID: ProtocolTarget.ID = ProtocolTarget.ID("page-main"),
    frameID: String? = "main-frame"
) async {
    let targetID = jsonEscapedString(targetID.rawValue)
    let frameIDField = frameID.map {
        #","frameId":"\#(jsonEscapedString($0))""#
    } ?? ""
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"\#(targetID)","type":"page"\#(frameIDField),"isProvisional":false}}}"#
    )
}

private func receiveTargetEvent(
    _ transport: TransportSession,
    targetID: ProtocolTarget.ID,
    method: String,
    params: String
) async {
    await transport.receiveRootMessage(targetDispatchMessage(
        targetID: targetID,
        message: #"{"method":"\#(method)","params":\#(params)}"#
    ))
}

private func waitForTargetMessage(
    _ backend: FakeTransportBackend,
    method: String,
    ordinal: Int = 0,
    after count: Int = 0
) async throws -> SentTargetMessage {
    try await withThrowingTaskGroup(of: SentTargetMessage.self) { group in
        defer {
            group.cancelAll()
        }

        group.addTask {
            try await backend.waitForTargetMessage(method: method, ordinal: ordinal, after: count)
        }
        group.addTask {
            try await Task.sleep(for: transportCommandBackendWaitTimeout)
            throw WebInspectorProxyError.timeout(domain: "test", method: method)
        }

        guard let message = try await group.next() else {
            throw WebInspectorProxyError.timeout(domain: "test", method: method)
        }
        return message
    }
}

private func receiveTargetReply(
    _ transport: TransportSession,
    targetID: ProtocolTarget.ID,
    messageID: UInt64,
    result: String
) async {
    await transport.receiveRootMessage(targetDispatchMessage(
        targetID: targetID,
        message: #"{"id":\#(messageID),"result":\#(result)}"#
    ))
}

private func receiveTargetError(
    _ transport: TransportSession,
    targetID: ProtocolTarget.ID,
    messageID: UInt64,
    message: String
) async {
    let escapedMessage = jsonEscapedString(message)
    await transport.receiveRootMessage(targetDispatchMessage(
        targetID: targetID,
        message: #"{"id":\#(messageID),"error":{"message":"\#(escapedMessage)"}}"#
    ))
}

private func targetDispatchMessage(
    targetID: ProtocolTarget.ID,
    message: String
) -> String {
    let escapedTargetID = jsonEscapedString(targetID.rawValue)
    let escapedMessage = jsonEscapedString(message)
    return #"{"method":"Target.dispatchMessageFromTarget","params":{"targetId":"\#(escapedTargetID)","message":"\#(escapedMessage)"}}"#
}

private func jsonEscapedString(_ string: String) -> String {
    string
        .replacingOccurrences(of: #"\"#, with: #"\\"#)
        .replacingOccurrences(of: #"""#, with: #"\""#)
        .replacingOccurrences(of: "\n", with: #"\n"#)
        .replacingOccurrences(of: "\r", with: #"\r"#)
        .replacingOccurrences(of: "\t", with: #"\t"#)
}

private func messageID(_ message: String) throws -> UInt64 {
    let object = try messageObject(message)
    if let number = object["id"] as? NSNumber {
        return number.uint64Value
    }
    if let string = object["id"] as? String,
       let id = UInt64(string) {
        return id
    }
    throw TransportSession.Error.malformedMessage
}

private func messageMethod(_ message: String) throws -> String? {
    try messageObject(message)["method"] as? String
}

private func messageParameters(_ message: String) throws -> [String: Any] {
    try messageObject(message)["params"] as? [String: Any] ?? [:]
}

private func messageObject(_ message: String) throws -> [String: Any] {
    let data = try #require(message.data(using: .utf8))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private actor SuspendedSendTransportBackend: TransportBackend {
    private var sendStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var sendContinuations: [CheckedContinuation<Void, Never>] = []

    func sendJSONString(_ message: String) async throws {
        _ = message
        sendStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            sendContinuations.append(continuation)
        }
    }

    func detach() async {}

    func waitUntilSendStarted() async {
        guard sendStarted == false else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseSend() {
        let continuations = sendContinuations
        sendContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private actor CloseConnectionGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilReleased() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard released == false else {
            return
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard started == false else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor CompletionProbe {
    private var finished = false

    func finish() {
        finished = true
    }

    func isFinished() -> Bool {
        finished
    }
}

private actor EventDeliveryProbe {
    private var firstCount = 0
    private var secondCount = 0
    private var firstWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var secondWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func recordFirst() {
        firstCount += 1
        resumeSatisfiedWaiters()
    }

    func recordSecond() {
        secondCount += 1
        resumeSatisfiedWaiters()
    }

    func waitForFirstCount(_ count: Int) async {
        guard firstCount < count else {
            return
        }
        await withCheckedContinuation { continuation in
            firstWaiters.append((count, continuation))
        }
    }

    func waitForSecondCount(_ count: Int) async {
        guard secondCount < count else {
            return
        }
        await withCheckedContinuation { continuation in
            secondWaiters.append((count, continuation))
        }
    }

    private func resumeSatisfiedWaiters() {
        let readyFirstWaiters = firstWaiters.filter { firstCount >= $0.count }
        firstWaiters.removeAll { firstCount >= $0.count }
        let readySecondWaiters = secondWaiters.filter { secondCount >= $0.count }
        secondWaiters.removeAll { secondCount >= $0.count }
        for waiter in readyFirstWaiters + readySecondWaiters {
            waiter.continuation.resume()
        }
    }
}

private struct TimedOut: Error {}

private struct StructuredScopeBodyFailure: Error {}

private enum StructuredScopeOutcome: Equatable, Sendable {
    case succeeded
    case cancelled
    case bodyFailure
    case cleanupFailure
    case combinedFailure
    case overflow
    case transportFailure
    case protocolViolation
    case pageUnavailable
    case timeout
    case other(String)
}

private func value<T: Sendable>(
    of task: Task<T, Never>,
    timeout: Duration = .seconds(5)
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            await task.value
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimedOut()
        }
        guard let value = try await group.next() else {
            throw TimedOut()
        }
        group.cancelAll()
        return value
    }
}

private func throwingValue<T: Sendable>(
    of task: Task<T, any Error>,
    timeout: Duration = .seconds(5)
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await task.value
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimedOut()
        }
        guard let value = try await group.next() else {
            throw TimedOut()
        }
        group.cancelAll()
        return value
    }
}
