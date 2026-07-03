import Foundation
import Testing
import WebInspectorProxyKit
import WebInspectorTestSupport
import WebInspectorTransport

private let transportCommandBackendWaitTimeout: Duration = .milliseconds(750)

@Test
func transportCommandBackendDispatchesPageReloadThroughTargetRoute() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: WebInspectorTransportBackend(transport: transport)))

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
    let target = pageTarget(proxy: WebInspectorProxy(backend: WebInspectorTransportBackend(transport: transport)))

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
    let target = pageTarget(proxy: WebInspectorProxy(backend: WebInspectorTransportBackend(transport: transport)))

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
func transportCommandBackendEncodesDOMHighlightAndInspectModeCommands() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: WebInspectorTransportBackend(transport: transport)))

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
}

@Test
func transportCommandBackendDecodesDOMDocumentResult() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: WebInspectorTransportBackend(transport: transport)))

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
}

@Test
func transportCommandBackendEncodesAndDecodesCSSStyleCommands() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: WebInspectorTransportBackend(transport: transport)))

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
          "inlineStyle": {
            "cssProperties": [
              {"name": "color", "value": "red", "text": "color: red;"}
            ],
            "cssText": "color: red;"
          },
          "attributesStyle": {
            "cssProperties": [
              {"name": "width", "value": "20"}
            ]
          },
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
    #expect(matchedStyles.inlineStyle?.properties.first?.name == "color")
    #expect(matchedStyles.inlineStyle?.isEditable == false)
    #expect(matchedStyles.inlineStyle?.properties.first?.isEditable == false)
    #expect(matchedStyles.attributesStyle?.properties.first?.name == "width")
    #expect(matchedStyles.attributesStyle?.isEditable == false)
    #expect(matchedStyles.pseudoElements.first?.selectorList.text == "body::before")

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
func transportBackedProxyCloseDetachesTransportAndFinishesEventStreams() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let eventTask = Task {
        var iterator = target.dom.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .dom)
    await proxy.close()

    #expect(await backend.isDetached())
    #expect(try await value(of: eventTask) == nil)
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
func transportBackendDecodesRootScopedDOMDocumentUpdatedForCurrentPage() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: WebInspectorTransportBackend(transport: transport)))

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
    let target = pageTarget(proxy: WebInspectorProxy(backend: WebInspectorTransportBackend(transport: transport)))

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
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: WebInspectorTransportBackend(transport: transport)))

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
func transportBackendDecodesNetworkResponseEventForTargetRoute() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: WebInspectorTransportBackend(transport: transport)))

    let eventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .network)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.responseReceived",
        params: #"{"requestId":"request-1","type":"Document","response":{"url":"https://example.test/","status":200,"statusText":"OK","mimeType":"text/html","headers":{"content-type":"text/html"},"source":"network"},"timestamp":12.5}"#
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .responseReceived(id, response, resourceType, timestamp) = event else {
        Issue.record("Expected Network.responseReceived.")
        return
    }
    #expect(id == Network.Request.ID("request-1"))
    #expect(response.url == "https://example.test/")
    #expect(response.status == 200)
    #expect(response.headers["content-type"] == "text/html")
    #expect(response.source == Network.Source(rawValue: "network"))
    #expect(resourceType == .document)
    #expect(timestamp == 12.5)
}

@Test
func transportBackendDecodesWebSocketHandshakeEventsForTargetRoute() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: WebInspectorTransportBackend(transport: transport)))

    let requestEventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .network)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.webSocketWillSendHandshakeRequest",
        params: #"{"requestId":"ws-1","timestamp":1.25,"request":{"headers":{"Upgrade":"websocket","Sec-WebSocket-Key":"abc"}}}"#
    )

    let requestEvent = try #require(try await value(of: requestEventTask))
    guard case let .webSocket(.handshakeRequest(id, request, timestamp)) = requestEvent else {
        Issue.record("Expected Network.webSocketWillSendHandshakeRequest.")
        return
    }
    #expect(id == Network.Request.ID("ws-1"))
    #expect(request.id == Network.Request.ID("ws-1"))
    #expect(request.method == "GET")
    #expect(request.headers["Upgrade"] == "websocket")
    #expect(request.headers["Sec-WebSocket-Key"] == "abc")
    #expect(timestamp == 1.25)

    let responseEventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .network)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Network.webSocketHandshakeResponseReceived",
        params: #"{"requestId":"ws-1","timestamp":2.5,"response":{"status":101,"statusText":"Switching Protocols","headers":{"Upgrade":"websocket"}}}"#
    )

    let responseEvent = try #require(try await value(of: responseEventTask))
    guard case let .webSocket(.handshakeResponse(responseID, response, responseTimestamp)) = responseEvent else {
        Issue.record("Expected Network.webSocketHandshakeResponseReceived.")
        return
    }
    #expect(responseID == Network.Request.ID("ws-1"))
    #expect(response.status == 101)
    #expect(response.statusText == "Switching Protocols")
    #expect(response.headers["Upgrade"] == "websocket")
    #expect(responseTimestamp == 2.5)
}

@Test
func transportBackendFiltersEventsByRoute() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-target","type":"frame","frameId":"frame-1","isProvisional":false}}}"#
    )
    let proxy = WebInspectorProxy(backend: WebInspectorTransportBackend(transport: transport))
    let page = pageTarget(proxy: proxy)
    let frame = WebInspectorTarget(
        id: WebInspectorTarget.ID("frame-target"),
        kind: .frame,
        frameID: FrameID("frame-1"),
        isProvisional: false,
        proxy: proxy,
        route: RoutingTargetID("frame-target")
    )

    let pageEventTask = Task {
        var iterator = page.network.events.makeAsyncIterator()
        return await iterator.next()
    }
    let frameEventTask = Task {
        var iterator = frame.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(page, domain: .network)
    await waitForEventSubscription(frame, domain: .network)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("frame-target"),
        method: "Network.loadingFinished",
        params: #"{"requestId":"frame-request","timestamp":4,"sourceMapURL":"frame.js.map","metrics":{"responseBodyBytesReceived":128,"responseBodyDecodedSize":256}}"#
    )

    let frameEvent = try #require(try await value(of: frameEventTask))
    guard case let .loadingFinished(id, timestamp, sourceMapURL, metrics) = frameEvent else {
        Issue.record("Expected frame route to receive Network.loadingFinished.")
        return
    }
    #expect(id == Network.Request.ID("frame-request"))
    #expect(timestamp == 4)
    #expect(sourceMapURL == "frame.js.map")
    #expect(metrics?.encodedDataLength == 128)
    #expect(metrics?.decodedBodyLength == 256)

    pageEventTask.cancel()
}

@Test
func transportBackendRuntimeClearedUsesSemanticTargetID() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let proxy = WebInspectorProxy(backend: WebInspectorTransportBackend(transport: transport))
    let retargeted = WebInspectorTarget(
        id: WebInspectorTarget.ID("semantic-page"),
        kind: .page,
        frameID: FrameID("main-frame"),
        isProvisional: false,
        proxy: proxy,
        route: RoutingTargetID("page-main")
    )

    let eventTask = Task {
        var iterator = retargeted.runtime.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(retargeted, domain: .runtime)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Runtime.executionContextsCleared",
        params: "{}"
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .executionContextsCleared(target) = event else {
        Issue.record("Expected Runtime.executionContextsCleared.")
        return
    }
    #expect(target == WebInspectorTarget.ID("semantic-page"))
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

private func installPageTarget(
    in transport: TransportSession,
    targetID: ProtocolTarget.ID = ProtocolTarget.ID("page-main")
) async {
    let targetID = jsonEscapedString(targetID.rawValue)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"\#(targetID)","type":"page","frameId":"main-frame","isProvisional":false}}}"#
    )
}

private func waitForEventSubscription(
    _ target: WebInspectorTarget,
    domain: WebInspectorProxyEventDomain
) async {
    await target.proxy.waitForEventSubscription(targetID: target.id, route: target.route, domain: domain)
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

private struct TimedOut: Error {}

private func value<T: Sendable>(
    of task: Task<T, Never>,
    timeout: Duration = .seconds(1)
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
    timeout: Duration = .seconds(1)
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
