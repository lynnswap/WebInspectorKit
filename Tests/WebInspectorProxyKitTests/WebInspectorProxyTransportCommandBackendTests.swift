import Foundation
import Testing
import WebInspectorProxyKit
import WebInspectorTestSupport

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
    #expect(child.attributeList == [DOM.Attribute(name: "lang", value: "en")])
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
func proxyWaitUntilClosedWaitsForInFlightCloseConnection() async throws {
    let closeGate = CloseConnectionGate()
    let proxy = WebInspectorProxy(closeConnection: {
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
func transportBackendDeliversCurrentPageTargetCommitLifecycleAfterRetarget() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(
        in: transport,
        targetID: ProtocolTarget.ID("page-old"),
        frameID: nil
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()
    #expect(target.frameID == nil)

    let eventTask = Task<WebInspectorTargetLifecycleEvent?, Never> {
        var iterator = target.lifecycleEvents.makeAsyncIterator()
        while let event = await iterator.next() {
            if case .didCommitProvisionalTarget = event {
                return event
            }
        }
        return nil
    }

    await waitForEventSubscription(target, domain: .target)
    await installPageTarget(
        in: transport,
        targetID: ProtocolTarget.ID("page-new"),
        frameID: "new-main-frame"
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-old","newTargetId":"page-new"}}"#
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .didCommitProvisionalTarget(commit) = event else {
        Issue.record("Expected Target.didCommitProvisionalTarget lifecycle event.")
        return
    }
    #expect(commit.oldTargetID == WebInspectorTarget.ID.currentPage)
    #expect(commit.newTarget.id == WebInspectorTarget.ID.currentPage)
    guard case .page = commit.newTarget.kind else {
        Issue.record("Expected committed target to remain a page.")
        return
    }
    #expect(commit.newTarget.frameID == FrameID("new-main-frame"))
    #expect(commit.newTarget.isProvisional == false)
    let cachedTarget = try await proxy.waitForCurrentPage()
    #expect(cachedTarget.frameID == FrameID("new-main-frame"))
    #expect(cachedTarget.isProvisional == false)
    #expect(await transport.snapshot().currentMainPageTargetID == ProtocolTarget.ID("page-new"))
}

@Test
func transportBackendDeliversCurrentPageTargetDestroyedLifecycle() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport, targetID: ProtocolTarget.ID("page-main"))
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let eventTask = Task {
        var iterator = target.lifecycleEvents.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .target)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"page-main"}}"#
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .targetDestroyed(targetID) = event else {
        Issue.record("Expected Target.targetDestroyed lifecycle event.")
        return
    }
    #expect(targetID == .currentPage)
    #expect(await transport.snapshot().currentMainPageTargetID == nil)
    #expect(await proxy.currentPage == nil)

    let replacementTask = Task {
        try await proxy.waitForCurrentPage()
    }
    await installPageTarget(in: transport, targetID: ProtocolTarget.ID("page-replacement"))
    let replacement = try await throwingValue(of: replacementTask)
    #expect(replacement.id == .currentPage)
    #expect(replacement.route == .currentPage)
    #expect(await transport.snapshot().currentMainPageTargetID == ProtocolTarget.ID("page-replacement"))
}

@Test
func transportBackendDeliversCurrentPagePageFrameLifecycle() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport, targetID: ProtocolTarget.ID("page-main"))
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()

    let eventTask = Task {
        var iterator = target.lifecycleEvents.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        return [first, second].compactMap { $0 }
    }

    await waitForEventSubscription(target, domain: .page)
    await transport.receiveRootMessage(
        #"{"method":"Page.frameNavigated","params":{"frame":{"id":"main-frame","loaderId":"loader-1","name":"Main","url":"https://example.test/","securityOrigin":"https://example.test","mimeType":"text/html"}}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Page.frameDetached","params":{"frameId":"child-frame"}}"#
    )

    let events = try await value(of: eventTask)
    #expect(events.count == 2)
    guard case let .frameNavigated(frame) = events[0] else {
        Issue.record("Expected Page.frameNavigated lifecycle event.")
        return
    }
    #expect(frame.id == FrameID("main-frame"))
    #expect(frame.parentID == nil)
    #expect(frame.loaderID == "loader-1")
    #expect(frame.name == "Main")
    #expect(frame.url == "https://example.test/")
    #expect(frame.securityOrigin == "https://example.test")
    #expect(frame.mimeType == "text/html")

    guard case let .frameDetached(frameID) = events[1] else {
        Issue.record("Expected Page.frameDetached lifecycle event.")
        return
    }
    #expect(frameID == FrameID("child-frame"))
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
func transportBackendNormalizesFrameInspectorInspectForCurrentPageRoute() async throws {
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
        let first = await iterator.next()
        let second = await iterator.next()
        return [first, second].compactMap { $0 }
    }

    await waitForEventSubscription(target, domain: .dom)
    await waitForEventSubscription(target, domain: .inspector)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("frame-target"),
        method: "Inspector.inspect",
        params: #"{"object":{"objectId":"remote-frame-node","type":"object","subtype":"node"},"hints":{}}"#
    )

    let requestNode = try await waitForTargetMessage(backend, method: "DOM.requestNode")
    #expect(requestNode.targetIdentifier == ProtocolTarget.ID("page-main"))
    #expect(try messageParameters(requestNode.message)["objectId"] as? String == "remote-frame-node")
    await receiveTargetReply(
        transport,
        targetID: requestNode.targetIdentifier,
        messageID: try messageID(requestNode.message),
        result: #"{"nodeId":42}"#
    )

    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("frame-target"),
        method: "DOM.setChildNodes",
        params: #"{"parentId":42,"nodes":[{"nodeId":43,"nodeType":1,"nodeName":"SPAN","localName":"span","nodeValue":"","childNodeCount":0}]}"#
    )

    let events = try await value(of: eventTask)
    #expect(events.count == 2)
    guard case let .inspect(nodeID)? = events.first else {
        Issue.record("Expected frame Inspector.inspect to normalize to DOM.inspect.")
        return
    }
    #expect(nodeID == DOM.Node.ID("42", scopedToTargetRawValue: "frame-target"))
    guard case let .setChildNodes(parentID, nodes)? = events.last else {
        Issue.record("Expected frame DOM.setChildNodes to be projected into the current page DOM stream.")
        return
    }
    #expect(parentID == DOM.Node.ID("42", scopedToTargetRawValue: "frame-target"))
    #expect(nodes.first?.id == DOM.Node.ID("43", scopedToTargetRawValue: "frame-target"))

    let frameNodeID = DOM.Node.ID("42", scopedToTargetRawValue: "frame-target")
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
    let frameStyle = try #require(frameStyles.matchedRules.first?.style)
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
func transportBackendDeliversFrameNetworkEventsToCurrentPageRoute() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-target","type":"frame","frameId":"child-frame","parentFrameId":"main-frame","isProvisional":false}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()
    #expect(target.route == .currentPage)

    let eventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        return await iterator.next()
    }

    await waitForEventSubscription(target, domain: .network)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("frame-target"),
        method: "Network.requestWillBeSent",
        params: #"{"requestId":"frame-request","frameId":"child-frame","request":{"url":"https://frame.example.test/","method":"GET"},"timestamp":7.5,"type":"Document"}"#
    )

    let event = try #require(try await value(of: eventTask))
    guard case let .requestWillBeSent(id, request, resourceType, _, timestamp) = event else {
        Issue.record("Expected current-page route to receive frame Network.requestWillBeSent.")
        return
    }
    #expect(id == Network.Request.ID("frame-request", scopedToTargetRawValue: "frame-target"))
    #expect(request.id == id)
    #expect(request.url == "https://frame.example.test/")
    #expect(request.method == "GET")
    #expect(resourceType == .document)
    #expect(timestamp == 7.5)

    let bodyTask = Task {
        try await target.network.responseBody(for: id)
    }
    let bodyCommand = try await waitForTargetMessage(backend, method: "Network.getResponseBody")
    #expect(bodyCommand.targetIdentifier == ProtocolTarget.ID("frame-target"))
    #expect(try messageParameters(bodyCommand.message)["requestId"] as? String == "frame-request")
    await receiveTargetReply(
        transport,
        targetID: bodyCommand.targetIdentifier,
        messageID: try messageID(bodyCommand.message),
        result: #"{"body":"frame body","base64Encoded":false}"#
    )
    let body = try await bodyTask.value
    #expect(body.data == "frame body")
    #expect(body.base64Encoded == false)
}

@Test
func transportBackendDoesNotDeliverUnrelatedFrameNetworkEventsToCurrentPageRoute() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"other-frame-target","type":"frame","frameId":"other-child-frame","parentFrameId":"other-main-frame","isProvisional":false}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()
    #expect(target.route == .currentPage)

    let eventProbe = CompletionProbe()
    let eventTask = Task {
        var iterator = target.network.events.makeAsyncIterator()
        if await iterator.next() != nil {
            await eventProbe.finish()
        }
    }
    defer {
        eventTask.cancel()
    }

    await waitForEventSubscription(target, domain: .network)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("other-frame-target"),
        method: "Network.requestWillBeSent",
        params: #"{"requestId":"other-frame-request","frameId":"other-child-frame","request":{"url":"https://other-frame.example.test/","method":"GET"},"timestamp":8.5,"type":"Document"}"#
    )

    try await Task.sleep(for: .milliseconds(100))
    #expect(await eventProbe.isFinished() == false)
}

@Test
func transportBackendDoesNotDeliverFrameDocumentUpdatedToCurrentPageDOMRoute() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-target","type":"frame","frameId":"child-frame","parentFrameId":"main-frame","isProvisional":false}}}"#
    )
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()
    #expect(target.route == .currentPage)

    let eventProbe = CompletionProbe()
    let eventTask = Task {
        var iterator = target.dom.events.makeAsyncIterator()
        if await iterator.next() != nil {
            await eventProbe.finish()
        }
    }
    defer {
        eventTask.cancel()
    }

    await waitForEventSubscription(target, domain: .dom)
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("frame-target"),
        method: "DOM.documentUpdated",
        params: "{}"
    )

    try await Task.sleep(for: .milliseconds(100))
    #expect(await eventProbe.isFinished() == false)
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
        params: #"{"requestId":"frame-request","timestamp":4,"sourceMapURL":"frame.js.map","metrics":{"protocol":"h2","remoteAddress":"203.0.113.10:443","responseBodyBytesReceived":128,"responseBodyDecodedSize":256}}"#
    )

    let frameEvent = try #require(try await value(of: frameEventTask))
    guard case let .loadingFinished(id, timestamp, sourceMapURL, metrics) = frameEvent else {
        Issue.record("Expected frame route to receive Network.loadingFinished.")
        return
    }
    #expect(id == Network.Request.ID("frame-request"))
    #expect(timestamp == 4)
    #expect(sourceMapURL == "frame.js.map")
    #expect(metrics?.networkProtocol == "h2")
    #expect(metrics?.remoteAddress == "203.0.113.10:443")
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

@Test
func transportCommandBackendDecodesRuntimeEvaluationResult() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    await installPageTarget(in: transport)
    let target = pageTarget(proxy: WebInspectorProxy(backend: WebInspectorTransportBackend(transport: transport)))

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
    let target = pageTarget(proxy: WebInspectorProxy(backend: WebInspectorTransportBackend(transport: transport)))
    let objectID = Runtime.RemoteObject.ID("object-1")

    let propertiesTask = Task {
        try await target.runtime.properties(of: objectID)
    }
    let propertiesCommand = try await waitForTargetMessage(backend, method: "Runtime.getProperties")
    await receiveTargetReply(
        transport,
        targetID: propertiesCommand.targetIdentifier,
        messageID: try messageID(propertiesCommand.message),
        result: #"{"properties":[{"name":"answer","value":{"type":"number","value":42,"description":"42"},"writable":true,"isOwn":true}]}"#
    )

    let properties = try await propertiesTask.value
    #expect(properties.count == 1)
    #expect(properties[0].name == "answer")
    #expect(properties[0].value?.kind == .number)
    #expect(properties[0].value?.value == .number(42))
    #expect(properties[0].writable == true)
    #expect(properties[0].isOwn == true)

    let previewTask = Task {
        try await target.runtime.preview(of: objectID)
    }
    let previewCommand = try await waitForTargetMessage(backend, method: "Runtime.getPreview")
    await receiveTargetReply(
        transport,
        targetID: previewCommand.targetIdentifier,
        messageID: try messageID(previewCommand.message),
        result: #"{"preview":{"type":"object","description":"Object","lossless":true,"overflow":false,"properties":[{"name":"answer","value":"42"}],"size":1}}"#
    )

    let preview = try await previewTask.value
    #expect(preview.kind == .object)
    #expect(preview.description == "Object")
    #expect(preview.lossless == true)
    #expect(preview.overflow == false)
    #expect(preview.properties.first?.name == "answer")
    #expect(preview.properties.first?.value == "42")
    #expect(preview.size == 1)

    let entriesTask = Task {
        try await target.runtime.collectionEntries(of: objectID)
    }
    let entriesCommand = try await waitForTargetMessage(backend, method: "Runtime.getCollectionEntries")
    await receiveTargetReply(
        transport,
        targetID: entriesCommand.targetIdentifier,
        messageID: try messageID(entriesCommand.message),
        result: #"{"entries":[{"key":{"type":"string","value":"key","description":"key"},"value":{"type":"object","objectId":"entry-value","description":"entry value"}}]}"#
    )

    let entries = try await entriesTask.value
    #expect(entries.count == 1)
    #expect(entries[0].key?.value == .string("key"))
    #expect(entries[0].value.id == Runtime.RemoteObject.ID("entry-value"))
    #expect(entries[0].value.description == "entry value")
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
