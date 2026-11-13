import Foundation
import Testing
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import WebInspectorTestSupport

@Test
func transportBackendDecodesRootScopedDOMDocumentUpdatedForCurrentPage() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: LiveWebInspectorProxyBackend(transport: transport)))

    let eventTask = Task {
        var iterator = target.dom.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .dom)
    await transport.receiveRootMessage(#"{"method":"DOM.documentUpdated","params":{}}"#)

    let event = try #require(try await value(of: eventTask))
    guard case .documentUpdated = event else {
        Issue.record("Expected DOM.documentUpdated.")
        return
    }
}

@Test
func transportBackendDecodesDOMShadowAndPseudoEventsForTargetRoute() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: LiveWebInspectorProxyBackend(transport: transport)))

    let eventTask = Task {
        var iterator = target.dom.events.makeAsyncIterator()
        var events: [DOM.Event] = []
        for _ in 0..<4 {
            if let event = await iterator.next() {
                events.append(event)
            }
        }
        return events
    }

    await waitForEventSubscription(target, domain: .dom)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "DOM.shadowRootPushed",
        params: ##"{"hostId":1,"root":{"nodeId":2,"nodeType":11,"nodeName":"#document-fragment","localName":"","nodeValue":"","childNodeCount":0}}"##
    )
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "DOM.shadowRootPopped",
        params: #"{"hostId":1,"rootId":2}"#
    )
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "DOM.pseudoElementAdded",
        params: #"{"parentId":1,"pseudoElement":{"nodeId":3,"nodeType":1,"nodeName":"::before","localName":"","nodeValue":"","childNodeCount":0,"pseudoType":"before"}}"#
    )
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "DOM.pseudoElementRemoved",
        params: #"{"parentId":1,"pseudoElementId":3}"#
    )

    let events = try await value(of: eventTask)
    #expect(events.count == 4)
    guard case let .shadowRootPushed(host, root) = events[0] else {
        Issue.record("Expected DOM.shadowRootPushed.")
        return
    }
    #expect(host == DOM.Node.ID("1"))
    #expect(root.id == DOM.Node.ID("2"))
    guard case let .shadowRootPopped(poppedHost, poppedRoot) = events[1] else {
        Issue.record("Expected DOM.shadowRootPopped.")
        return
    }
    #expect(poppedHost == DOM.Node.ID("1"))
    #expect(poppedRoot == DOM.Node.ID("2"))
    guard case let .pseudoElementAdded(parent, element) = events[2] else {
        Issue.record("Expected DOM.pseudoElementAdded.")
        return
    }
    #expect(parent == DOM.Node.ID("1"))
    #expect(element.id == DOM.Node.ID("3"))
    guard case let .pseudoElementRemoved(removedParent, removedElement) = events[3] else {
        Issue.record("Expected DOM.pseudoElementRemoved.")
        return
    }
    #expect(removedParent == DOM.Node.ID("1"))
    #expect(removedElement == DOM.Node.ID("3"))
}

@Test
func transportBackendNormalizesInspectorInspectToDOMInspectEvent() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(
        backend: backend,
        protocolProfile: .latest,
        responseTimeout: .milliseconds(750)
    )
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: LiveWebInspectorProxyBackend(transport: transport)))

    let eventTask = Task {
        var iterator = target.dom.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .dom)
    await waitForEventSubscription(target, domain: .inspector)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Inspector.inspect",
        params: #"{"object":{"objectId":"remote-node","type":"object","subtype":"node"},"hints":{}}"#
    )

    let requestNode = try await waitForTargetMessage(backend, method: "DOM.requestNode")
    #expect(requestNode.targetIdentifier == ProtocolTarget.ID("page-main"))
    #expect(try messageParameters(requestNode.message)["objectId"] as? String == "remote-node")
    await receiveTargetReply(
        transport,
        targetID: requestNode.targetIdentifier,
        messageID: try messageID(requestNode.message),
        result: #"{"nodeId":42}"#
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .inspect(nodeID) = event else {
        Issue.record("Expected Inspector.inspect to normalize to DOM.inspect.")
        return
    }
    #expect(nodeID == DOM.Node.ID("42"))
}

@Test
func transportBackendNormalizesLatestRootInspectorInspectToPageDOMInspectEvent() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(
        backend: backend,
        protocolProfile: .latest,
        responseTimeout: .milliseconds(750)
    )
    await installPageTarget(in: transport)
    let target = pageTarget(
        proxy: WebInspectorProxy(
            backend: LiveWebInspectorProxyBackend(transport: transport)
        )
    )

    let eventTask = Task {
        var iterator = target.dom.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .dom)
    await waitForEventSubscription(target, domain: .inspector)
    await transport.receiveRootMessage(
        #"{"method":"Inspector.inspect","params":{"object":{"objectId":"remote-node","type":"object","subtype":"node"},"hints":{}}}"#
    )

    let requestNode = try await waitForTargetMessage(
        backend,
        method: "DOM.requestNode"
    )
    #expect(requestNode.targetIdentifier == ProtocolTarget.ID("page-main"))
    #expect(
        try messageParameters(requestNode.message)["objectId"] as? String
            == "remote-node"
    )
    await receiveTargetReply(
        transport,
        targetID: requestNode.targetIdentifier,
        messageID: try messageID(requestNode.message),
        result: #"{"nodeId":42}"#
    )

    guard case let .inspect(nodeID)? = try await value(of: eventTask) else {
        Issue.record("Expected latest root Inspector.inspect on the page DOM route.")
        return
    }
    #expect(nodeID == DOM.Node.ID("42"))
}

@Test
func transportBackendProjectsFrameDOMEventsBeforePageTopologyAndRoutesScopedCommands() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(
        backend: backend,
        protocolProfile: .latest,
        responseTimeout: .milliseconds(750)
    )
    await installPageTarget(in: transport)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-42-7","type":"frame","isProvisional":false,"isPaused":false}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let eventTask = Task {
        var iterator = target.dom.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .dom)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("frame-42-7"),
        method: "DOM.setChildNodes",
        params: #"{"parentId":42,"nodes":[{"nodeId":43,"nodeType":1,"nodeName":"SPAN","localName":"span","nodeValue":"","childNodeCount":0}]}"#
    )

    let event = try await value(of: eventTask)
    guard case let .setChildNodes(parentID, nodes)? = event else {
        Issue.record("Expected frame DOM.setChildNodes to be projected into the current page DOM stream.")
        return
    }
    #expect(parentID == DOM.Node.ID("42", scopedToTargetRawValue: "frame-42-7"))
    #expect(nodes.first?.id == DOM.Node.ID("43", scopedToTargetRawValue: "frame-42-7"))

    let frameNodeID = DOM.Node.ID("42", scopedToTargetRawValue: "frame-42-7")
    let frameAttributesTask = Task {
        try await target.dom.attributes(of: frameNodeID)
    }
    let frameAttributes = try await waitForTargetMessage(backend, method: "DOM.getAttributes")
    #expect(frameAttributes.targetIdentifier == ProtocolTarget.ID("frame-42-7"))
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
    #expect(frameSetAttribute.targetIdentifier == ProtocolTarget.ID("frame-42-7"))
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
    #expect(frameSetAttributes.targetIdentifier == ProtocolTarget.ID("frame-42-7"))
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
    #expect(frameRemoveAttribute.targetIdentifier == ProtocolTarget.ID("frame-42-7"))
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
    #expect(frameSetOuterHTML.targetIdentifier == ProtocolTarget.ID("frame-42-7"))
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
    #expect(matchedStyles.targetIdentifier == ProtocolTarget.ID("frame-42-7"))
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
    #expect(frameRuleID.targetScopeRawValue == "frame-42-7")
    #expect(frameStyle.id.targetScopeRawValue == "frame-42-7")
    #expect(frameStyle.id.unscopedRawValue != frameStyle.id.rawValue)

    let setStyleTextTask = Task {
        try await target.css.setStyleText(frameStyle.id, text: "color: blue;")
    }
    let setStyleText = try await waitForTargetMessage(backend, method: "CSS.setStyleText")
    #expect(setStyleText.targetIdentifier == ProtocolTarget.ID("frame-42-7"))
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
    #expect(updatedFrameStyle.id.targetScopeRawValue == "frame-42-7")

    let frameSetRuleSelectorTask = Task {
        try await target.css.setRuleSelector(frameRuleID, selector: ".frame-card")
    }
    let frameSetRuleSelector = try await waitForTargetMessage(backend, method: "CSS.setRuleSelector")
    #expect(frameSetRuleSelector.targetIdentifier == ProtocolTarget.ID("frame-42-7"))
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
    #expect(updatedFrameRule.id?.targetScopeRawValue == "frame-42-7")
    #expect(updatedFrameRule.selectorList.text == ".frame-card")

    let frameSetGroupingHeaderTask = Task {
        try await target.css.setGroupingHeaderText(frameRuleID, text: "@media (min-width: 600px)")
    }
    let frameSetGroupingHeader = try await waitForTargetMessage(
        backend,
        method: "CSS.setGroupingHeaderText"
    )
    #expect(frameSetGroupingHeader.targetIdentifier == ProtocolTarget.ID("frame-42-7"))
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

    let cssEventTask = Task {
        var iterator = target.css.events.makeAsyncIterator()
        return await iterator.next()
    }
    await waitForEventSubscription(target, domain: .css)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("frame-42-7"),
        method: "CSS.styleSheetChanged",
        params: #"{"styleSheetId":"frame-sheet"}"#
    )
    let cssEvent = try #require(try await value(of: cssEventTask))
    guard case let .styleSheetChanged(styleSheetID) = cssEvent else {
        Issue.record("Expected frame CSS.styleSheetChanged to be projected into the current page CSS stream.")
        return
    }
    #expect(styleSheetID.targetScopeRawValue == "frame-42-7")
    #expect(styleSheetID.unscopedRawValue == "frame-sheet")
}

@Test
func transportBackendIgnoresImpossibleFrameInspectorOrigin() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-target","type":"frame","frameId":"child-frame","parentFrameId":"main-frame","isProvisional":false}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let eventTask = Task {
        var iterator = target.dom.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .dom)
    await waitForEventSubscription(target, domain: .inspector)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("frame-target"),
        method: "Inspector.inspect",
        params: #"{"object":{"objectId":"remote-frame-node","type":"object","subtype":"node"},"hints":{}}"#
    )
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Inspector.inspect",
        params: #"{"object":{"objectId":"remote-main-node","type":"object","subtype":"node"},"hints":{}}"#
    )

    let requestNode = try await waitForTargetMessage(backend, method: "DOM.requestNode")
    #expect(requestNode.targetIdentifier == ProtocolTarget.ID("page-main"))
    #expect(try messageParameters(requestNode.message)["objectId"] as? String == "remote-main-node")
    await receiveTargetReply(
        transport,
        targetID: requestNode.targetIdentifier,
        messageID: try messageID(requestNode.message),
        result: #"{"nodeId":42}"#
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .inspect(nodeID) = event else {
        Issue.record("Expected main-page Inspector.inspect to normalize to DOM.inspect.")
        return
    }
    #expect(nodeID == DOM.Node.ID("42"))
}

@Test
func transportBackendTreatsZeroPreviousNodeAsTheFirstChild() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: LiveWebInspectorProxyBackend(transport: transport)))

    let eventTask = Task {
        var iterator = target.dom.events.makeAsyncIterator()
        return await iterator.next()
    }
    await waitForEventSubscription(target, domain: .dom)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "DOM.childNodeInserted",
        params: #"{"parentNodeId":1,"previousNodeId":0,"node":{"nodeId":2,"nodeType":1,"nodeName":"DIV","localName":"div","nodeValue":""}}"#
    )

    guard case let .childNodeInserted(parent, previous, node)? = try await value(of: eventTask) else {
        Issue.record("Expected a decoded DOM child insertion event.")
        return
    }

    #expect(parent == DOM.Node.ID("1"))
    #expect(previous == nil)
    #expect(node.id == DOM.Node.ID("2"))
}
