import Foundation
import Testing
import WebKit
@testable import WebInspectorCore
@testable import WebInspectorRuntime
@testable import WebInspectorTransport

@Test
func connectBootstrapsMainPageDocumentInOrder() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)

    try await connect(session, transport: transport, backend: backend)

    let methods = await targetMessageMethods(backend)
    #expect(methods == [
        "Inspector.enable",
        "Inspector.initialized",
        "CSS.enable",
        "Runtime.enable",
        "DOM.getDocument",
        "Network.enable",
    ])
    #expect(await session.isAttached)
    #expect(await session.dom.snapshot().currentPageTargetID == ProtocolTargetIdentifier.pageMain)
    #expect(await session.dom.snapshot().documentsByID.count == 1)
}

@Test
func domainPumpsApplyNetworkEventsToNetworkSession() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Network.requestWillBeSent","params":{"requestId":"request-1","frameId":"main-frame","request":{"url":"https://example.com/app.js"},"timestamp":1}}"#
    )
    let request = try await waitUntil {
        await session.network.requestSnapshot(for: .init(targetID: .pageMain, requestID: .init("request-1")))
    }

    #expect(request.id.targetID == ProtocolTargetIdentifier.pageMain)
    #expect(request.request.url == "https://example.com/app.js")
}

@Test
func networkLazyFetchReturnsCommandResultFromRequestTarget() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","domains":["Network"],"isProvisional":false}}}"#
    )

    let sentCount = await backend.sentTargetMessages().count
    let performTask = Task {
        try await session.perform(
            .getResponseBody(
                requestKey: .init(targetID: .frameAd, requestID: .init("request-1")),
                backendResourceIdentifier: nil
            )
        )
    }
    let sent = try await waitForTargetMessage(backend, method: "Network.getResponseBody", after: sentCount)

    #expect(sent.targetIdentifier == ProtocolTargetIdentifier.frameAd)
    #expect(String(data: Data(sent.message.utf8), encoding: .utf8)?.contains(#""requestId":"request-1""#) == true)

    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: #"{"body":"hello","base64Encoded":false}"#
    )
    let result = try await performTask.value

    #expect(result.method == "Network.getResponseBody")
    #expect(result.targetID == ProtocolTargetIdentifier.frameAd)
    #expect(String(data: result.resultData, encoding: .utf8)?.contains(#""body":"hello""#) == true)
}

@Test
func networkResponseBodyFetchAppliesResultToCoreRequest() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Network.requestWillBeSent","params":{"requestId":"request-2","frameId":"main-frame","request":{"url":"https://example.com/api.json"},"timestamp":1}}"#
    )
    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Network.responseReceived","params":{"requestId":"request-2","timestamp":2,"type":"XHR","response":{"url":"https://example.com/api.json","status":200,"mimeType":"application/json","headers":{"content-type":"application/json"}}}}"#
    )
    let request = try await waitUntil {
        await session.network.request(for: .init(targetID: .pageMain, requestID: .init("request-2")))
    }
    let responseBody = await request.responseBody
    let body = try #require(responseBody)
    #expect(await body.fetchState == .available)

    let sentCount = await backend.sentTargetMessages().count
    let fetchTask = Task {
        await session.fetchResponseBody(for: request.id)
    }
    let sent = try await waitForTargetMessage(backend, method: "Network.getResponseBody", after: sentCount)
    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: #"{"body":"{\"ok\":true}","base64Encoded":false}"#
    )
    await fetchTask.value

    #expect(await body.fetchState == .loaded)
    #expect(await body.textRepresentation?.contains("\n") == true)
    #expect(await body.textRepresentation?.contains(#""ok""#) == true)
}

@Test
func selectedElementStyleRefreshLoadsCSSSession() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))
    await session.dom.selectNode(bodyID)

    let sentCount = await backend.sentTargetMessages().count
    let refreshTask = Task {
        await session.refreshStylesForSelectedNode()
    }
    let messages = try await waitForCSSRefreshMessages(backend, after: sentCount)
    try await replyCSSRefresh(
        transport: transport,
        messages: messages,
        selector: "body",
        styleSheetID: "sheet-body"
    )
    await refreshTask.value

    let styles = try #require(await session.css.selectedNodeStyles)
    #expect(await session.css.selectedState == .loaded)
    #expect(await styles.identity.nodeID == bodyID)
    #expect(await styles.sections.map(\.title) == ["element.style", "body"])
    #expect(await styles.sections[1].style.cssProperties.first?.name == "margin")
    #expect(await styles.computedProperties == [CSSComputedStyleProperty(name: "display", value: "block")])
}

@Test
func selectedElementStyleRefreshDropsResultsWhenSelectionChanges() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let htmlID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))
    await session.dom.selectNode(bodyID)

    let firstSentCount = await backend.sentTargetMessages().count
    let firstRefresh = Task {
        await session.refreshStylesForSelectedNode()
    }
    let firstMessages = try await waitForCSSRefreshMessages(backend, after: firstSentCount)

    await session.dom.selectNode(htmlID)
    let secondSentCount = await backend.sentTargetMessages().count
    let secondRefresh = Task {
        await session.refreshStylesForSelectedNode()
    }
    let secondMessages = try await waitForCSSRefreshMessages(backend, after: secondSentCount)

    try await replyCSSRefresh(
        transport: transport,
        messages: firstMessages,
        selector: "body",
        styleSheetID: "sheet-body"
    )
    try await replyCSSRefresh(
        transport: transport,
        messages: secondMessages,
        selector: "html",
        styleSheetID: "sheet-html"
    )
    await firstRefresh.value
    await secondRefresh.value

    let styles = try #require(await session.css.selectedNodeStyles)
    #expect(await styles.identity.nodeID == htmlID)
    #expect(await styles.sections.map(\.title) == ["element.style", "html"])
}

@Test
func cssPropertyToggleSendsSetStyleTextAndRefreshesStyles() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))
    await session.dom.selectNode(bodyID)

    let refreshCount = await backend.sentTargetMessages().count
    let refreshTask = Task {
        await session.refreshStylesForSelectedNode()
    }
    let initialRefreshMessages = try await waitForCSSRefreshMessages(backend, after: refreshCount)
    try await replyCSSRefresh(
        transport: transport,
        messages: initialRefreshMessages,
        selector: "body",
        styleSheetID: "sheet-body"
    )
    await refreshTask.value

    let propertyID = CSSPropertyIdentifier(
        styleID: CSSStyleIdentifier(styleSheetID: .init("sheet-body"), ordinal: 1),
        propertyIndex: 0
    )
    let toggleSentCount = await backend.sentTargetMessages().count
    let toggleTask = Task {
        try await session.setCSSProperty(propertyID, enabled: false)
    }
    let setStyleText = try await waitForTargetMessage(backend, method: "CSS.setStyleText", after: toggleSentCount)
    #expect(setStyleText.targetIdentifier == ProtocolTargetIdentifier.pageMain)
    #expect(try messageParameters(setStyleText.message)["text"] as? String == "/* margin: 0; */")
    let refreshAfterToggleCount = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: setStyleText.targetIdentifier,
        messageID: try messageID(setStyleText.message),
        result: #"{"style":{"styleId":{"styleSheetId":"sheet-body","ordinal":1},"cssProperties":[{"name":"margin","value":"0","text":"/* margin: 0; */","status":"disabled"}]}}"#
    )

    let refreshMessages = try await waitForCSSRefreshMessages(
        backend,
        after: refreshAfterToggleCount
    )
    await transport.receiveRootMessage(
        #"{"method":"CSS.styleSheetChanged","params":{"styleSheetId":"sheet-body"}}"#
    )
    try await replyCSSRefresh(
        transport: transport,
        messages: refreshMessages,
        selector: "body",
        styleSheetID: "sheet-body",
        marginStatus: "disabled",
        marginText: "/* margin: 0; */"
    )
    try await toggleTask.value

    let styles = try #require(await session.css.selectedNodeStyles)
    #expect(await session.css.selectedState == .loaded)
    #expect(await styles.sections[1].style.cssProperties[0].isEnabled == false)
}

@Test
func cssAndDOMStyleInvalidationsMarkSelectedNodeStylesNeedsRefresh() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))
    await session.dom.selectNode(bodyID)
    await transport.receiveRootMessage(
        #"{"method":"CSS.styleSheetAdded","params":{"header":{"styleSheetId":"sheet-body"}}}"#
    )

    let sentCount = await backend.sentTargetMessages().count
    let refreshTask = Task {
        await session.refreshStylesForSelectedNode()
    }
    let messages = try await waitForCSSRefreshMessages(backend, after: sentCount)
    try await replyCSSRefresh(transport: transport, messages: messages, selector: "body", styleSheetID: "sheet-body")
    await refreshTask.value
    #expect(await session.css.selectedState == .loaded)

    await transport.receiveRootMessage(
        #"{"method":"CSS.styleSheetChanged","params":{"styleSheetId":"sheet-body"}}"#
    )
    _ = try await waitUntil {
        await session.css.selectedState == .needsRefresh ? true : nil
    }

    let refreshAgainCount = await backend.sentTargetMessages().count
    let refreshAgain = Task {
        await session.refreshStylesForSelectedNode()
    }
    let messagesAgain = try await waitForCSSRefreshMessages(backend, after: refreshAgainCount)
    try await replyCSSRefresh(transport: transport, messages: messagesAgain, selector: "body", styleSheetID: "sheet-body")
    await refreshAgain.value
    #expect(await session.css.selectedState == .loaded)

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.attributeModified","params":{"nodeId":4,"name":"class","value":"featured"}}"#
    )
    _ = try await waitUntil {
        await session.css.selectedState == .needsRefresh ? true : nil
    }

    let refreshAfterAttributeCount = await backend.sentTargetMessages().count
    let refreshAfterAttribute = Task {
        await session.refreshStylesForSelectedNode()
    }
    let messagesAfterAttribute = try await waitForCSSRefreshMessages(backend, after: refreshAfterAttributeCount)
    try await replyCSSRefresh(transport: transport, messages: messagesAfterAttribute, selector: "body", styleSheetID: "sheet-body")
    await refreshAfterAttribute.value
    #expect(await session.css.selectedState == .loaded)

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.childNodeInserted","params":{"parentNodeId":4,"previousNodeId":5,"node":{"nodeId":6,"nodeType":1,"nodeName":"ASIDE","localName":"aside"}}}"#
    )
    _ = try await waitUntil {
        await session.css.selectedState == .needsRefresh ? true : nil
    }
}

@Test
func documentUpdatedClearsSelectedCSSNodeStylesForInvalidatedDocument() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))
    await session.dom.selectNode(bodyID)

    let sentCount = await backend.sentTargetMessages().count
    let refreshTask = Task {
        await session.refreshStylesForSelectedNode()
    }
    let messages = try await waitForCSSRefreshMessages(backend, after: sentCount)
    try await replyCSSRefresh(transport: transport, messages: messages, selector: "body", styleSheetID: "sheet-body")
    await refreshTask.value
    #expect(await session.css.selectedNodeStyles != nil)

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.documentUpdated","params":{}}"#
    )
    _ = try await waitUntil {
        await session.css.selectedNodeStyles == nil ? true : nil
    }
    #expect(await session.css.selectedState == .unavailable(.staleNode(bodyID)))
}

@Test
func explicitDOMReloadClearsSelectedCSSNodeStylesForReplacedDocument() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))
    await session.dom.selectNode(bodyID)

    let sentCount = await backend.sentTargetMessages().count
    let refreshTask = Task {
        await session.refreshStylesForSelectedNode()
    }
    let messages = try await waitForCSSRefreshMessages(backend, after: sentCount)
    try await replyCSSRefresh(transport: transport, messages: messages, selector: "body", styleSheetID: "sheet-body")
    await refreshTask.value
    #expect(await session.css.selectedNodeStyles != nil)

    let reloadSentCount = await backend.sentTargetMessages().count
    let reloadTask = Task {
        try await session.reloadDOMDocument()
    }
    let reload = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: reloadSentCount)
    await receiveTargetReply(
        transport,
        targetID: reload.targetIdentifier,
        messageID: try messageID(reload.message),
        result: manualReloadDocumentResult
    )
    try await reloadTask.value

    #expect(await session.css.selectedNodeStyles == nil)
    #expect(await session.css.selectedState == .unavailable(.staleNode(bodyID)))
}

@Test
func domMutationRemovingSelectedNodeClearsSelectedCSSNodeStyles() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))
    await session.dom.selectNode(bodyID)

    let sentCount = await backend.sentTargetMessages().count
    let refreshTask = Task {
        await session.refreshStylesForSelectedNode()
    }
    let messages = try await waitForCSSRefreshMessages(backend, after: sentCount)
    try await replyCSSRefresh(transport: transport, messages: messages, selector: "body", styleSheetID: "sheet-body")
    await refreshTask.value
    #expect(await session.css.selectedState == .loaded)

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.childNodeRemoved","params":{"nodeId":4}}"#
    )
    _ = try await waitUntil {
        await session.dom.selectedNodeID == nil ? true : nil
    }

    #expect(await session.css.selectedNodeStyles == nil)
    #expect(await session.css.selectedState == .unavailable(.staleNode(bodyID)))
}

@Test
func localDOMDeleteClearsSelectedCSSNodeStylesWithoutBackendMutationEvent() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))
    await session.dom.selectNode(bodyID)

    let sentCount = await backend.sentTargetMessages().count
    let refreshTask = Task {
        await session.refreshStylesForSelectedNode()
    }
    let messages = try await waitForCSSRefreshMessages(backend, after: sentCount)
    try await replyCSSRefresh(transport: transport, messages: messages, selector: "body", styleSheetID: "sheet-body")
    await refreshTask.value
    #expect(await session.css.selectedState == .loaded)

    let countBeforeDelete = await backend.sentTargetMessages().count
    let deleteTask = Task {
        try await session.deleteDOMNode(bodyID, undoManager: nil)
    }
    let removeNode = try await waitForTargetMessage(backend, method: "DOM.removeNode", after: countBeforeDelete)
    await receiveTargetReply(
        transport,
        targetID: removeNode.targetIdentifier,
        messageID: try messageID(removeNode.message),
        result: "{}"
    )
    try await deleteTask.value

    #expect(await session.dom.selectedNodeID == nil)
    #expect(await session.css.selectedNodeStyles == nil)
    #expect(await session.css.selectedState == .unavailable(.staleNode(bodyID)))
}

@Test
func frameDocumentRefreshUpdatesOnlyFrameDocument() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let pageDocumentID = try #require(await session.dom.snapshot().currentPageDocumentID)

    let sentCount = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":["DOM"],"isProvisional":false}}}"#
    )
    _ = try await waitUntil {
        await session.dom.snapshot().targetsByID[.frameAd]
    }

    let sent = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: sentCount)
    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: ##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","children":[{"nodeId":2,"nodeType":1,"nodeName":"HTML","localName":"html"}]}}"##
    )
    _ = try await waitUntil {
        await session.dom.snapshot().targetsByID[.frameAd]?.currentDocumentID
    }

    let snapshot = await session.dom.snapshot()
    #expect(snapshot.currentPageDocumentID == pageDocumentID)
    #expect(snapshot.targetsByID[.frameAd]?.currentDocumentID != nil)
    #expect(snapshot.targetsByID[.frameAd]?.currentDocumentID != pageDocumentID)
}

@Test
func frameTargetWithoutDOMCapabilityDoesNotHydrateOnCreationOrDocumentUpdated() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let sentCount = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":[],"isProvisional":false}}}"#
    )
    _ = try await waitUntil {
        await session.dom.snapshot().targetsByID[.frameAd]
    }
    await receiveTargetDispatch(
        transport,
        targetID: .frameAd,
        message: #"{"method":"DOM.documentUpdated","params":{}}"#
    )

    #expect(await backend.sentTargetMessages().count == sentCount)
    #expect(await session.dom.snapshot().targetsByID[.frameAd]?.currentDocumentID == nil)
}

@Test
func frameTargetWithoutAdvertisedDomainsUsesWebKitFrameDefaultAndDoesNotHydrateOnCreation() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let sentCount = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#
    )
    _ = try await waitUntil {
        await session.dom.snapshot().targetsByID[.frameAd]
    }

    #expect(await backend.sentTargetMessages().count == sentCount)
    #expect(await session.dom.snapshot().targetsByID[.frameAd]?.currentDocumentID == nil)
}

@Test
func frameTargetWithAdvertisedDOMCapabilityHydratesOnCreation() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let sentCount = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":["DOM","Runtime"],"isProvisional":false}}}"#
    )
    let sent = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: sentCount)
    #expect(sent.targetIdentifier == ProtocolTargetIdentifier.frameAd)
    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: firstLazyFrameDocumentResult
    )

    #expect(await session.dom.snapshot().targetsByID[.frameAd]?.currentDocumentID != nil)
}

@Test
func frameTargetWithAdvertisedCSSCapabilityIsEnabledOnCreation() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let frameTargetID = ProtocolTargetIdentifier("frame-css")
    let sentCount = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-css","type":"frame","frameId":"css-frame","parentFrameId":"main-frame","domains":["DOM","CSS"],"isProvisional":false}}}"#
    )

    let cssEnable = try await waitForTargetMessage(backend, method: "CSS.enable", after: sentCount)
    #expect(cssEnable.targetIdentifier == frameTargetID)
    await receiveTargetReply(
        transport,
        targetID: cssEnable.targetIdentifier,
        messageID: try messageID(cssEnable.message),
        result: "{}"
    )

    let documentRequest = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: sentCount)
    #expect(documentRequest.targetIdentifier == frameTargetID)
    await receiveTargetReply(
        transport,
        targetID: documentRequest.targetIdentifier,
        messageID: try messageID(documentRequest.message),
        result: firstLazyFrameDocumentResult
    )
}

@Test
func frameTargetCSSCapabilityEnableIgnoresDestroyedTargetRace() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let frameTargetID = ProtocolTargetIdentifier("frame-css-race")
    let sentCount = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-css-race","type":"frame","frameId":"css-frame-race","parentFrameId":"main-frame","domains":["CSS"],"isProvisional":false}}}"#
    )

    let cssEnable = try await waitForTargetMessage(backend, method: "CSS.enable", after: sentCount)
    #expect(cssEnable.targetIdentifier == frameTargetID)
    let pendingKey = TargetReplyKey(
        targetID: frameTargetID,
        commandID: try messageID(cssEnable.message)
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"frame-css-race"}}"#
    )
    _ = try await waitUntil {
        await pendingTargetReplyKeys(transport).contains(pendingKey) == false ? true : nil
    }

    #expect(await session.lastError == nil)
}

@Test
func frameTargetCSSCapabilityEnableIgnoresStaleConnectionAfterDetach() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let frameTargetID = ProtocolTargetIdentifier("frame-css-stale")
    let sentCount = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-css-stale","type":"frame","frameId":"css-frame-stale","parentFrameId":"main-frame","domains":["CSS"],"isProvisional":false}}}"#
    )

    let cssEnable = try await waitForTargetMessage(backend, method: "CSS.enable", after: sentCount)
    let pendingKey = TargetReplyKey(
        targetID: frameTargetID,
        commandID: try messageID(cssEnable.message)
    )
    await session.detach()
    _ = try await waitUntil {
        await pendingTargetReplyKeys(transport).contains(pendingKey) == false ? true : nil
    }
    try await Task.sleep(for: .milliseconds(5))

    #expect(await session.lastError == nil)
}

@Test
func domCapableFrameTargetDiscoveredBeforeAttachHydratesAfterConnect() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)

    await transport.receiveRootMessage(
        cssCapablePageTargetCreatedMessage(targetID: "page-main", frameID: "main-frame", isProvisional: false)
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":["DOM","Runtime"],"isProvisional":false}}}"#
    )

    let connectTask = Task {
        try await session.connect(transport: transport)
    }
    let bootstrapMessages = try await completeBootstrap(transport: transport, backend: backend)
    try await connectTask.value

    let frameRequest = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: bootstrapMessages.count
    )
    #expect(frameRequest.targetIdentifier == ProtocolTargetIdentifier.frameAd)
    await receiveTargetReply(
        transport,
        targetID: frameRequest.targetIdentifier,
        messageID: try messageID(frameRequest.message),
        result: firstLazyFrameDocumentResult
    )

    #expect(await session.dom.snapshot().targetsByID[.frameAd]?.currentDocumentID != nil)
}

@Test
func provisionalFrameDocumentReplyBeforeCommitRehydratesCommittedFrame() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let provisionalTargetID = ProtocolTargetIdentifier("frame-provisional")
    let sentCountBeforeFrameTarget = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-provisional","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":["DOM","Runtime"],"isProvisional":true}}}"#
    )
    let firstRequest = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: sentCountBeforeFrameTarget
    )
    #expect(firstRequest.targetIdentifier == provisionalTargetID)
    await receiveTargetReply(
        transport,
        targetID: firstRequest.targetIdentifier,
        messageID: try messageID(firstRequest.message),
        result: firstLazyFrameDocumentResult
    )
    #expect(await session.dom.snapshot().targetsByID[provisionalTargetID]?.currentDocumentID == nil)

    let sentCountBeforeCommit = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"frame-provisional","newTargetId":"frame-ad"}}"#
    )
    let committedRequest = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: sentCountBeforeCommit
    )
    #expect(committedRequest.targetIdentifier == ProtocolTargetIdentifier.frameAd)
    await receiveTargetReply(
        transport,
        targetID: committedRequest.targetIdentifier,
        messageID: try messageID(committedRequest.message),
        result: secondLazyFrameDocumentResult
    )

    let snapshot: DOMSessionSnapshot = try await waitUntil {
        let snapshot = await session.dom.snapshot()
        guard snapshot.targetsByID[ProtocolTargetIdentifier.frameAd]?.currentDocumentID != nil else {
            return nil
        }
        return snapshot
    }
    #expect(snapshot.targetsByID[provisionalTargetID] == nil)
}

@Test
func provisionalFrameCommitCancelsInFlightDocumentRequestBeforeRehydrating() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let provisionalTargetID = ProtocolTargetIdentifier("frame-provisional")
    let sentCountBeforeFrameTarget = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-provisional","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":["DOM","Runtime"],"isProvisional":true}}}"#
    )
    let firstRequest = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: sentCountBeforeFrameTarget
    )
    #expect(firstRequest.targetIdentifier == provisionalTargetID)
    let firstRequestMessageID = try messageID(firstRequest.message)

    let sentCountBeforeCommit = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"frame-provisional","newTargetId":"frame-ad"}}"#
    )
    let committedRequest = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: sentCountBeforeCommit
    )
    #expect(committedRequest.targetIdentifier == ProtocolTargetIdentifier.frameAd)
    await receiveTargetReply(
        transport,
        targetID: committedRequest.targetIdentifier,
        messageID: try messageID(committedRequest.message),
        result: secondLazyFrameDocumentResult
    )
    _ = try await waitUntil {
        await session.dom.snapshot().currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(201))]
    }

    #expect(
        await pendingTargetReplyKeys(transport).contains(
            TargetReplyKey(targetID: .frameAd, commandID: firstRequestMessageID)
        ) == false
    )
    await receiveTargetReply(
        transport,
        targetID: .frameAd,
        messageID: firstRequestMessageID,
        result: firstLazyFrameDocumentResult
    )

    let snapshot = await session.dom.snapshot()
    #expect(snapshot.currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(201))] != nil)
    #expect(snapshot.currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(101))] == nil)
}

@Test
func oldlessProvisionalFrameCommitCancelsInFlightDocumentRequestBeforeRehydrating() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let provisionalTargetID = ProtocolTargetIdentifier("frame-provisional")
    let sentCountBeforeFrameTarget = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-provisional","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":["DOM","Runtime"],"isProvisional":true}}}"#
    )
    let firstRequest = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: sentCountBeforeFrameTarget
    )
    #expect(firstRequest.targetIdentifier == provisionalTargetID)
    let firstRequestMessageID = try messageID(firstRequest.message)

    let sentCountBeforeCommit = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"newTargetId":"frame-ad"}}"#
    )
    let committedRequest = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: sentCountBeforeCommit
    )
    #expect(committedRequest.targetIdentifier == ProtocolTargetIdentifier.frameAd)
    await receiveTargetReply(
        transport,
        targetID: committedRequest.targetIdentifier,
        messageID: try messageID(committedRequest.message),
        result: secondLazyFrameDocumentResult
    )
    _ = try await waitUntil {
        await session.dom.snapshot().currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(201))]
    }

    #expect(
        await pendingTargetReplyKeys(transport).contains(
            TargetReplyKey(targetID: .frameAd, commandID: firstRequestMessageID)
        ) == false
    )
    await receiveTargetReply(
        transport,
        targetID: .frameAd,
        messageID: firstRequestMessageID,
        result: firstLazyFrameDocumentResult
    )

    let snapshot = await session.dom.snapshot()
    #expect(snapshot.currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(201))] != nil)
    #expect(snapshot.currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(101))] == nil)
}

@Test("Regression: frame getDocument request does not block page DOM events")
func frameDocumentRequestDoesNotBlockPageDOMEvents() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let sentCountBeforeFrameTarget = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":["DOM","Runtime"],"isProvisional":false}}}"#
    )
    let frameDocumentRequest = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: sentCountBeforeFrameTarget
    )
    #expect(frameDocumentRequest.targetIdentifier == ProtocolTargetIdentifier.frameAd)

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: pageHTMLChildrenSetChildNodesMessage
    )
    let bodyID = try await waitForCurrentNode(
        in: session,
        targetID: .pageMain,
        protocolNodeID: .init(4)
    )
    let snapshotWhileFrameRequestIsPending = await session.dom.snapshot()
    #expect(snapshotWhileFrameRequestIsPending.nodesByID[bodyID]?.nodeName == "BODY")
    #expect(snapshotWhileFrameRequestIsPending.targetsByID[.frameAd]?.currentDocumentID == nil)

    await receiveTargetReply(
        transport,
        targetID: frameDocumentRequest.targetIdentifier,
        messageID: try messageID(frameDocumentRequest.message),
        result: firstLazyFrameDocumentResult
    )
    let finalSnapshot: DOMSessionSnapshot = try await waitUntil {
        let snapshot = await session.dom.snapshot()
        guard snapshot.targetsByID[.frameAd]?.currentDocumentID != nil else {
            return nil
        }
        return snapshot
    }
    #expect(finalSnapshot.currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(4))] == bodyID)
}

@Test
func pageDocumentUpdatedInvalidatesCurrentPageDocumentWithoutReloading() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let pageDocumentID = try #require(await session.dom.snapshot().currentPageDocumentID)
    let sentCount = await backend.sentTargetMessages().count

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.documentUpdated","params":{}}"#
    )
    let snapshot: DOMSessionSnapshot = try await waitUntil {
        let snapshot = await session.dom.snapshot()
        guard snapshot.currentPageDocumentID == nil else {
            return nil
        }
        return snapshot
    }

    #expect(snapshot.currentPageDocumentID == nil)
    #expect(snapshot.documentsByID[pageDocumentID]?.lifecycle == .invalidated)
    #expect(snapshot.currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(1))] == nil)
    #expect(await backend.sentTargetMessages().count == sentCount)
}

@Test
func ensureDOMDocumentLoadedReloadsInvalidatedPageDocument() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.documentUpdated","params":{}}"#
    )
    let invalidatedSnapshot: DOMSessionSnapshot = try await waitUntil {
        let snapshot = await session.dom.snapshot()
        guard snapshot.currentPageDocumentID == nil else {
            return nil
        }
        return snapshot
    }
    #expect(invalidatedSnapshot.currentPageDocumentID == nil)

    let sentCount = await backend.sentTargetMessages().count
    let ensureTask = Task {
        await session.ensureDOMDocumentLoaded()
    }
    let reload = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: sentCount
    )
    #expect(reload.targetIdentifier == ProtocolTargetIdentifier.pageMain)
    await receiveTargetReply(
        transport,
        targetID: reload.targetIdentifier,
        messageID: try messageID(reload.message),
        result: manualReloadDocumentResult
    )

    #expect(await ensureTask.value)
    let finalSnapshot = await session.dom.snapshot()
    #expect(finalSnapshot.currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(40))] != nil)
}

@Test("Regression: documentUpdated reopens document request gate while previous getDocument is pending")
func documentUpdatedAllowsNewDocumentRequestWhilePreviousRequestIsPending() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.documentUpdated","params":{}}"#
    )
    let _: DOMSessionSnapshot = try await waitUntil {
        let snapshot = await session.dom.snapshot()
        guard snapshot.currentPageDocumentID == nil else {
            return nil
        }
        return snapshot
    }

    let sentCount = await backend.sentTargetMessages().count
    let ensureTask = Task {
        await session.ensureDOMDocumentLoaded()
    }
    let firstRequest = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: sentCount
    )
    let afterFirstRequest = await backend.sentTargetMessages().count

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.documentUpdated","params":{}}"#
    )
    let secondRequest = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: afterFirstRequest
    )

    #expect(secondRequest.targetIdentifier == ProtocolTargetIdentifier.pageMain)
    #expect(try messageID(secondRequest.message) != messageID(firstRequest.message))

    await receiveTargetReply(
        transport,
        targetID: secondRequest.targetIdentifier,
        messageID: try messageID(secondRequest.message),
        result: manualReloadDocumentResult
    )
    #expect(await ensureTask.value)

    #expect(
        await pendingTargetReplyKeys(transport).contains(
            TargetReplyKey(targetID: firstRequest.targetIdentifier, commandID: try messageID(firstRequest.message))
        ) == false
    )
    await receiveTargetReply(
        transport,
        targetID: firstRequest.targetIdentifier,
        messageID: try messageID(firstRequest.message),
        result: staleReloadDocumentResult
    )

    let finalSnapshot = await session.dom.snapshot()
    #expect(finalSnapshot.currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(40))] != nil)
    #expect(finalSnapshot.currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(50))] == nil)
}

@Test("Regression: stale setChildNodes from previous page does not move head children into new body")
func staleSetChildNodesAfterPageNavigationDoesNotMoveHeadChildrenIntoNewBody() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let countBeforeOldDocumentReload = await backend.sentTargetMessages().count
    let oldDocumentReloadTask = Task {
        try await session.reloadDOMDocument()
    }
    let oldDocumentReload = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: countBeforeOldDocumentReload
    )
    await receiveTargetReply(
        transport,
        targetID: oldDocumentReload.targetIdentifier,
        messageID: try messageID(oldDocumentReload.message),
        result: oldDocumentWithHeadNodeFourResult
    )
    try await oldDocumentReloadTask.value

    let oldHeadID = try await waitForCurrentNode(
        in: session,
        targetID: .pageMain,
        protocolNodeID: .init(4)
    )
    let requestIntent = try #require(await session.dom.requestChildNodesIntent(for: oldHeadID))
    let countBeforeRequest = await backend.sentTargetMessages().count
    let requestTask = Task {
        try await session.perform(requestIntent)
    }
    let oldHeadRequest = try await waitForTargetMessage(
        backend,
        method: "DOM.requestChildNodes",
        after: countBeforeRequest
    )
    await receiveTargetReply(
        transport,
        targetID: oldHeadRequest.targetIdentifier,
        messageID: try messageID(oldHeadRequest.message),
        result: "{}"
    )
    _ = try await requestTask.value

    let countBeforeNavigation = await backend.sentTargetMessages().count
    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.documentUpdated","params":{}}"#
    )

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":4,"nodes":[{"nodeId":8,"nodeType":1,"nodeName":"STYLE","localName":"style"}]}}"#
    )
    let _: DOMSessionSnapshot = try await waitUntil {
        let snapshot = await session.dom.snapshot()
        guard snapshot.currentPageDocumentID == nil else {
            return nil
        }
        return snapshot
    }
    #expect(await backend.sentTargetMessages().count == countBeforeNavigation)

    let countBeforeManualReload = await backend.sentTargetMessages().count
    let manualReloadTask = Task {
        try await session.reloadDOMDocument()
    }
    let newDocumentReload = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: countBeforeManualReload
    )
    await receiveTargetReply(
        transport,
        targetID: newDocumentReload.targetIdentifier,
        messageID: try messageID(newDocumentReload.message),
        result: newDocumentWithBodyNodeFourResult
    )
    try await manualReloadTask.value

    let newBodyID = try await waitForCurrentNode(
        in: session,
        targetID: .pageMain,
        protocolNodeID: .init(4)
    )

    let snapshot = await session.dom.snapshot()
    #expect(snapshot.currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(8))] == nil)
    #expect(snapshot.nodesByID[newBodyID]?.regularChildIDs.isEmpty == true)
}

@Test("Regression: root-scoped documentUpdated invalidates the current page document")
func rootScopedDocumentUpdatedInvalidatesCurrentPageDocument() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let mainNodeID = try await waitForCurrentNode(
        in: session,
        targetID: .pageMain,
        protocolNodeID: .init(5)
    )

    let sentCountBeforeFrameTarget = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":["DOM","Runtime"],"isProvisional":false}}}"#
    )
    let frameDocumentRequest = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: sentCountBeforeFrameTarget
    )
    #expect(frameDocumentRequest.targetIdentifier == ProtocolTargetIdentifier.frameAd)
    await receiveTargetReply(
        transport,
        targetID: frameDocumentRequest.targetIdentifier,
        messageID: try messageID(frameDocumentRequest.message),
        result: firstLazyFrameDocumentResult
    )
    _ = try await waitUntil {
        await session.dom.snapshot().targetsByID[.frameAd]
    }

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.childNodeInserted","params":{"parentNodeId":4,"previousNodeId":5,"node":{"nodeId":6,"nodeType":1,"nodeName":"IFRAME","localName":"iframe","frameId":"main-frame","attributes":["src","https://frame.example/ad"]}}}"#
    )
    let iframeNodeID = try await waitForCurrentNode(
        in: session,
        targetID: .pageMain,
        protocolNodeID: .init(6)
    )

    let beforeUpdate = await session.dom.snapshot()
    _ = try #require(beforeUpdate.currentPageDocumentID)
    let frameDocumentID = try #require(beforeUpdate.targetsByID[.frameAd]?.currentDocumentID)
    let frameRootID = try #require(beforeUpdate.documentsByID[frameDocumentID]?.rootNodeID)
    await session.dom.selectNode(mainNodeID)
    assertProjectionContainsFrameDocument(
        in: await session.dom.treeProjection(rootTargetID: .pageMain),
        iframeNodeID: iframeNodeID,
        frameRootNodeID: frameRootID
    )

    let sentCountBeforeTargetlessUpdate = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(#"{"method":"DOM.documentUpdated","params":{}}"#)

    let afterUpdate: DOMSessionSnapshot = try await waitUntil {
        let snapshot = await session.dom.snapshot()
        guard snapshot.currentPageDocumentID == nil else {
            return nil
        }
        return snapshot
    }
    #expect(afterUpdate.currentPageDocumentID == nil)
    #expect(afterUpdate.targetsByID[ProtocolTargetIdentifier.frameAd]?.currentDocumentID == frameDocumentID)
    #expect(afterUpdate.selection.selectedNodeID == nil)
    #expect(await backend.sentTargetMessages().count == sentCountBeforeTargetlessUpdate)
    #expect((await session.dom.treeProjection(rootTargetID: .pageMain)).rows.map(\.nodeID).contains(frameRootID) == false)
}

@Test("Lazy iframe insertion and frame document update keep the parent page tree intact")
func lazyIframeInsertionAndFrameDocumentUpdateKeepParentPageTree() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let mainNodeID = try await waitForCurrentNode(
        in: session,
        targetID: .pageMain,
        protocolNodeID: .init(5)
    )

    let sentCountBeforeFrameTarget = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":["DOM","Runtime"],"isProvisional":false}}}"#
    )
    let firstFrameDocumentRequest = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: sentCountBeforeFrameTarget
    )
    #expect(firstFrameDocumentRequest.targetIdentifier == ProtocolTargetIdentifier.frameAd)
    await receiveTargetReply(
        transport,
        targetID: firstFrameDocumentRequest.targetIdentifier,
        messageID: try messageID(firstFrameDocumentRequest.message),
        result: firstLazyFrameDocumentResult
    )
    _ = try await waitUntil {
        await session.dom.snapshot().targetsByID[.frameAd]
    }

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.childNodeInserted","params":{"parentNodeId":4,"previousNodeId":5,"node":{"nodeId":6,"nodeType":1,"nodeName":"IFRAME","localName":"iframe","frameId":"main-frame","attributes":["src","https://frame.example/ad"]}}}"#
    )
    let iframeNodeID = try await waitForCurrentNode(
        in: session,
        targetID: .pageMain,
        protocolNodeID: .init(6)
    )

    let beforeUpdate = await session.dom.snapshot()
    let pageDocumentID = try #require(beforeUpdate.currentPageDocumentID)
    let firstFrameDocumentID = try #require(beforeUpdate.targetsByID[.frameAd]?.currentDocumentID)
    let firstFrameRootID = try #require(beforeUpdate.documentsByID[firstFrameDocumentID]?.rootNodeID)
    assertProjectionContainsFrameDocument(
        in: await session.dom.treeProjection(rootTargetID: .pageMain),
        iframeNodeID: iframeNodeID,
        frameRootNodeID: firstFrameRootID
    )

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":6,"nodes":[{"nodeId":7,"nodeType":1,"nodeName":"SPAN","localName":"span"}]}}"#
    )
    let afterIframeOwnerUpdate = await session.dom.snapshot()
    #expect(afterIframeOwnerUpdate.currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(7))] == nil)
    assertProjectionContainsFrameDocument(
        in: await session.dom.treeProjection(rootTargetID: .pageMain),
        iframeNodeID: iframeNodeID,
        frameRootNodeID: firstFrameRootID
    )

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":4,"nodes":[{"nodeId":5,"nodeType":1,"nodeName":"MAIN","localName":"main","attributes":["id","content"]},{"nodeId":6,"nodeType":1,"nodeName":"IFRAME","localName":"iframe","frameId":"main-frame","attributes":["src","https://frame.example/ad"]}]}}"#
    )
    let refreshedIframeNodeID = try await waitForCurrentNode(
        in: session,
        targetID: .pageMain,
        protocolNodeID: .init(6)
    )
    #expect(refreshedIframeNodeID == iframeNodeID)
    assertProjectionContainsFrameDocument(
        in: await session.dom.treeProjection(rootTargetID: .pageMain),
        iframeNodeID: refreshedIframeNodeID,
        frameRootNodeID: firstFrameRootID
    )

    let sentCountBeforeFrameUpdate = await backend.sentTargetMessages().count
    await receiveTargetDispatch(
        transport,
        targetID: .frameAd,
        message: #"{"method":"DOM.documentUpdated","params":{}}"#
    )
    let frameDocumentReload = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: sentCountBeforeFrameUpdate
    )
    #expect(frameDocumentReload.targetIdentifier == ProtocolTargetIdentifier.frameAd)
    await receiveTargetReply(
        transport,
        targetID: frameDocumentReload.targetIdentifier,
        messageID: try messageID(frameDocumentReload.message),
        result: secondLazyFrameDocumentResult
    )

    let afterUpdate: DOMSessionSnapshot = try await waitUntil {
        let snapshot = await session.dom.snapshot()
        guard let currentDocumentID = snapshot.targetsByID[.frameAd]?.currentDocumentID,
              currentDocumentID != firstFrameDocumentID else {
            return nil
        }
        return snapshot
    }
    let secondFrameDocumentID = try #require(afterUpdate.targetsByID[.frameAd]?.currentDocumentID)
    let secondFrameRootID = try #require(afterUpdate.documentsByID[secondFrameDocumentID]?.rootNodeID)

    #expect(afterUpdate.currentPageDocumentID == pageDocumentID)
    #expect(afterUpdate.nodesByID[mainNodeID] != nil)
    #expect(afterUpdate.nodesByID[iframeNodeID] != nil)
    #expect(afterUpdate.nodesByID[firstFrameRootID] == nil)
    assertProjectionContainsFrameDocument(
        in: await session.dom.treeProjection(rootTargetID: .pageMain),
        iframeNodeID: iframeNodeID,
        frameRootNodeID: secondFrameRootID
    )
}

@Test("Regression: repeated frame documentUpdated reissues an in-flight frame reload")
func repeatedFrameDocumentUpdatedReissuesInFlightFrameReload() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let sentCountBeforeFrameTarget = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":["DOM","Runtime"],"isProvisional":false}}}"#
    )
    let initialFrameDocumentRequest = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: sentCountBeforeFrameTarget
    )
    #expect(initialFrameDocumentRequest.targetIdentifier == ProtocolTargetIdentifier.frameAd)
    await receiveTargetReply(
        transport,
        targetID: initialFrameDocumentRequest.targetIdentifier,
        messageID: try messageID(initialFrameDocumentRequest.message),
        result: firstLazyFrameDocumentResult
    )
    _ = try await waitUntil {
        await session.dom.snapshot().targetsByID[.frameAd]?.currentDocumentID
    }

    let sentCountBeforeFirstUpdate = await backend.sentTargetMessages().count
    await receiveTargetDispatch(
        transport,
        targetID: .frameAd,
        message: #"{"method":"DOM.documentUpdated","params":{}}"#
    )
    let firstReload = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: sentCountBeforeFirstUpdate
    )
    #expect(firstReload.targetIdentifier == ProtocolTargetIdentifier.frameAd)

    let sentCountBeforeSecondUpdate = await backend.sentTargetMessages().count
    await receiveTargetDispatch(
        transport,
        targetID: .frameAd,
        message: #"{"method":"DOM.documentUpdated","params":{}}"#
    )
    let secondReload = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: sentCountBeforeSecondUpdate
    )
    #expect(secondReload.targetIdentifier == ProtocolTargetIdentifier.frameAd)
    #expect(try messageID(secondReload.message) != messageID(firstReload.message))

    #expect(
        await pendingTargetReplyKeys(transport).contains(
            TargetReplyKey(targetID: firstReload.targetIdentifier, commandID: try messageID(firstReload.message))
        ) == false
    )
    await receiveTargetReply(
        transport,
        targetID: firstReload.targetIdentifier,
        messageID: try messageID(firstReload.message),
        result: firstLazyFrameDocumentResult
    )
    #expect(await session.dom.snapshot().currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(101))] == nil)

    await receiveTargetReply(
        transport,
        targetID: secondReload.targetIdentifier,
        messageID: try messageID(secondReload.message),
        result: secondLazyFrameDocumentResult
    )

    let snapshot: DOMSessionSnapshot = try await waitUntil {
        let snapshot = await session.dom.snapshot()
        guard snapshot.currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(201))] != nil else {
            return nil
        }
        return snapshot
    }
    #expect(snapshot.currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(101))] == nil)
}

@Test("Pending frame document hydrates page owner path before projection")
func pendingFrameDocumentHydratesPageOwnerPathBeforeProjection() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let sentCountBeforeFrameTarget = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":["DOM","Runtime"],"isProvisional":false}}}"#
    )
    let frameDocumentRequest = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: sentCountBeforeFrameTarget
    )
    #expect(frameDocumentRequest.targetIdentifier == ProtocolTargetIdentifier.frameAd)
    await receiveTargetReply(
        transport,
        targetID: frameDocumentRequest.targetIdentifier,
        messageID: try messageID(frameDocumentRequest.message),
        result: firstLazyFrameDocumentResult
    )

    let htmlHydrationRequest = try await waitForTargetMessage(
        backend,
        method: "DOM.requestChildNodes",
        after: sentCountBeforeFrameTarget
    )
    #expect(htmlHydrationRequest.targetIdentifier == ProtocolTargetIdentifier.pageMain)
    #expect(try integerParameter("nodeId", in: htmlHydrationRequest.message) == 2)
    let sentCountAfterHTMLHydrationRequest = await backend.sentTargetMessages().count
    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":2,"nodes":[{"nodeId":3,"nodeType":1,"nodeName":"HEAD","localName":"head"},{"nodeId":4,"nodeType":1,"nodeName":"BODY","localName":"body","childNodeCount":2}]}}"#
    )
    await receiveTargetReply(
        transport,
        targetID: htmlHydrationRequest.targetIdentifier,
        messageID: try messageID(htmlHydrationRequest.message),
        result: "{}"
    )

    let bodyHydrationRequest = try await waitForTargetMessage(
        backend,
        method: "DOM.requestChildNodes",
        after: sentCountAfterHTMLHydrationRequest
    )
    #expect(bodyHydrationRequest.targetIdentifier == ProtocolTargetIdentifier.pageMain)
    #expect(try integerParameter("nodeId", in: bodyHydrationRequest.message) == 4)
    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":4,"nodes":[{"nodeId":5,"nodeType":1,"nodeName":"MAIN","localName":"main","attributes":["id","content"]},{"nodeId":6,"nodeType":1,"nodeName":"IFRAME","localName":"iframe","frameId":"main-frame","attributes":["src","https://frame.example/ad"]}]}}"#
    )
    await receiveTargetReply(
        transport,
        targetID: bodyHydrationRequest.targetIdentifier,
        messageID: try messageID(bodyHydrationRequest.message),
        result: "{}"
    )

    let iframeNodeID = try await waitForCurrentNode(
        in: session,
        targetID: .pageMain,
        protocolNodeID: .init(6)
    )
    let snapshot = await session.dom.snapshot()
    let frameDocumentID = try #require(snapshot.targetsByID[.frameAd]?.currentDocumentID)
    let frameRootID = try #require(snapshot.documentsByID[frameDocumentID]?.rootNodeID)
    assertProjectionContainsFrameDocument(
        in: await session.dom.treeProjection(rootTargetID: .pageMain),
        iframeNodeID: iframeNodeID,
        frameRootNodeID: frameRootID
    )
}

// WebKit reports DOM.Node.frameId as the frame that owns the node's document.
// For an iframe element in the page DOM that is the page frame, not the
// cross-origin child frame whose document arrives through a separate target.
@Test("Regression: DOM.Node.frameId on an iframe owner is the owner frame, not the child frame identity")
func lazyIframeOwnerFrameIdIsNotTreatedAsChildFrameIdentity() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    _ = try await waitForCurrentNode(
        in: session,
        targetID: .pageMain,
        protocolNodeID: .init(5)
    )

    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#
    )
    _ = try await waitUntil {
        await session.dom.snapshot().targetsByID[.frameAd]
    }

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.childNodeInserted","params":{"parentNodeId":4,"previousNodeId":5,"node":{"nodeId":6,"nodeType":1,"nodeName":"IFRAME","localName":"iframe","frameId":"main-frame","attributes":["src","https://frame.example/ad"]}}}"#
    )
    let iframeNodeID = try await waitForCurrentNode(
        in: session,
        targetID: .pageMain,
        protocolNodeID: .init(6)
    )

    let sentCountBeforeFrameDocument = await backend.sentTargetMessages().count
    let frameDocumentTask = Task {
        try await session.perform(.getDocument(targetID: .frameAd))
    }
    let frameDocumentRequest = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: sentCountBeforeFrameDocument
    )
    await receiveTargetReply(
        transport,
        targetID: frameDocumentRequest.targetIdentifier,
        messageID: try messageID(frameDocumentRequest.message),
        result: firstLazyFrameDocumentResult
    )
    _ = try await frameDocumentTask.value
    let firstFrameDocumentID = try #require(await session.dom.snapshot().targetsByID[.frameAd]?.currentDocumentID)
    let firstFrameRootID = try #require(await session.dom.snapshot().documentsByID[firstFrameDocumentID]?.rootNodeID)

    assertProjectionContainsFrameDocument(
        in: await session.dom.treeProjection(rootTargetID: .pageMain),
        iframeNodeID: iframeNodeID,
        frameRootNodeID: firstFrameRootID
    )

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":6,"nodes":[{"nodeId":7,"nodeType":1,"nodeName":"SPAN","localName":"span"}]}}"#
    )
    #expect(await session.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(7))] == nil)
    assertProjectionContainsFrameDocument(
        in: await session.dom.treeProjection(rootTargetID: .pageMain),
        iframeNodeID: iframeNodeID,
        frameRootNodeID: firstFrameRootID
    )

    try await beginPicker(session: session, transport: transport, backend: backend)
    let sentCountBeforeInspect = await backend.sentTargetMessages().count
    await receiveTargetDispatch(
        transport,
        targetID: .frameAd,
        message: #"{"method":"DOM.inspect","params":{"nodeId":104}}"#
    )
    let disable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeInspect
    )
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )
    let selectedNode = try await waitUntil {
        await session.dom.selectedNode
    }
    #expect(await selectedNode.nodeName == "CANVAS")
    let snapshot = await session.dom.snapshot()
    let projection = await session.dom.treeProjection(rootTargetID: .pageMain)

    #expect(snapshot.framesByID[DOMFrameIdentifier("main-frame")]?.currentDocumentID == snapshot.currentPageDocumentID)
    #expect(snapshot.framesByID[DOMFrameIdentifier("ad-frame")]?.currentDocumentID == firstFrameDocumentID)
    #expect(snapshot.nodesByID[iframeNodeID] != nil)
    assertProjectionContainsFrameDocument(
        in: projection,
        iframeNodeID: iframeNodeID,
        frameRootNodeID: firstFrameRootID
    )
}

@Test
func targetCommitBootstrapsCommittedMainPageTarget() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let sentCountBeforeCommit = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        cssCapablePageTargetCreatedMessage(targetID: "page-next", isProvisional: true)
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"page-next"}}"#
    )

    let bootstrapMessages = try await completeBootstrap(
        transport: transport,
        backend: backend,
        after: sentCountBeforeCommit,
        documentResult: manualReloadDocumentResult
    )

    let snapshot = await session.dom.snapshot()
    #expect(snapshot.currentPageTargetID == ProtocolTargetIdentifier.pageNext)
    #expect(snapshot.targetsByID[.pageNext]?.currentDocumentID != nil)
    #expect(snapshot.targetsByID[.pageMain] == nil)
    #expect(bootstrapMessages.map(\.targetIdentifier).allSatisfy { $0 == .pageNext })
    #expect(bootstrapMessages.compactMap { try? messageMethod($0.message) } == [
        "Inspector.enable",
        "Inspector.initialized",
        "CSS.enable",
        "Runtime.enable",
        "DOM.getDocument",
        "Network.enable",
    ])
}

@Test("Regression: provisional DOM events from link navigation are ignored before committed document reload")
func linkNavigationBuffersProvisionalDOMEventsUntilCommit() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let sentCountBeforeNavigation = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        cssCapablePageTargetCreatedMessage(targetID: "page-next", isProvisional: true)
    )
    await receiveTargetDispatch(
        transport,
        targetID: .pageNext,
        message: #"{"method":"DOM.childNodeCountUpdated","params":{"nodeId":3,"childNodeCount":0}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"page-next"}}"#
    )

    let bootstrapMessages = try await completeBootstrap(
        transport: transport,
        backend: backend,
        after: sentCountBeforeNavigation,
        documentResult: newDocumentWithHeadChildCountResult
    )

    let snapshot: DOMSessionSnapshot = try await waitUntil {
        let snapshot = await session.dom.snapshot()
        guard snapshot.currentPageTargetID == .pageNext,
              snapshot.currentNodeIDByKey[.init(targetID: .pageNext, nodeID: .init(3))] != nil else {
            return nil
        }
        return snapshot
    }
    let headID = try #require(snapshot.currentNodeIDByKey[.init(targetID: .pageNext, nodeID: .init(3))])
    #expect(bootstrapMessages.map(\.targetIdentifier).allSatisfy { $0 == .pageNext })
    #expect(snapshot.nodesByID[headID]?.nodeName == "HEAD")
    #expect(snapshot.nodesByID[headID]?.regularChildren.knownCount == 2)
}

@Test
func requestNodeWaitsForPathPushBeforeSelectingNode() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":7,"frameId":"main-frame"}}}"#
    )
    _ = try await waitUntil {
        await session.dom.snapshot().executionContextsByID[ExecutionContextID(7)]
    }
    let intent = await session.dom.beginInspectSelectionRequest(
        targetID: .pageMain,
        objectID: "selected-object"
    )
    guard case let .success(commandIntent) = intent else {
        Issue.record("Expected DOM.requestNode intent")
        return
    }

    let sentCount = await backend.sentTargetMessages().count
    let performTask = Task {
        try await session.perform(commandIntent)
    }
    let sent = try await waitForTargetMessage(backend, method: "DOM.requestNode", after: sentCount)
    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":2,"nodes":[{"nodeId":3,"nodeType":1,"nodeName":"DIV","localName":"div","attributes":["id","selected"]}]}}"#
    )
    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: #"{"nodeId":3}"#
    )
    _ = try await performTask.value

    let selectedNode = try #require(await session.dom.selectedNode)
    let nodeName = await selectedNode.nodeName
    let attributes = await selectedNode.attributes
    #expect(nodeName == "DIV")
    #expect(attributes == [DOMAttribute(name: "id", value: "selected")])
}

@Test("Regression: backend setChildNodes without explicit hydration keeps requestNode selectable")
func backendSetChildNodesWithoutExplicitHydrationKeepsRequestNodeSelectable() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":2,"nodes":[{"nodeId":3,"nodeType":1,"nodeName":"HEAD","localName":"head"},{"nodeId":4,"nodeType":1,"nodeName":"BODY","localName":"body","children":[{"nodeId":164,"nodeType":1,"nodeName":"DIV","localName":"div","attributes":["id","picked"]}]}]}}"#
    )

    let expectedNodeID = try await waitForCurrentNode(
        in: session,
        targetID: .pageMain,
        protocolNodeID: .init(164)
    )
    let intent = await session.dom.beginInspectSelectionRequest(
        targetID: .pageMain,
        objectID: "selected-object"
    )
    guard case let .success(commandIntent) = intent else {
        Issue.record("Expected DOM.requestNode intent")
        return
    }

    let sentCount = await backend.sentTargetMessages().count
    let performTask = Task {
        try await session.perform(commandIntent)
    }
    let sent = try await waitForTargetMessage(backend, method: "DOM.requestNode", after: sentCount)
    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: #"{"nodeId":164}"#
    )
    _ = try await performTask.value

    #expect(await session.dom.selectedNodeID == expectedNodeID)
    let selectedNode = try #require(await session.dom.selectedNode)
    #expect(await selectedNode.attributes == [DOMAttribute(name: "id", value: "picked")])
}

@Test("Regression: detached setChildNodes root keeps requestNode selectable")
func detachedSetChildNodesRootKeepsRequestNodeSelectable() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let intent = await session.dom.beginInspectSelectionRequest(
        targetID: .pageMain,
        objectID: "detached-selected-object"
    )
    guard case let .success(commandIntent) = intent else {
        Issue.record("Expected DOM.requestNode intent")
        return
    }

    let sentCount = await backend.sentTargetMessages().count
    let performTask = Task {
        try await session.perform(commandIntent)
    }
    let sent = try await waitForTargetMessage(backend, method: "DOM.requestNode", after: sentCount)
    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":0,"nodes":[{"nodeId":200,"nodeType":1,"nodeName":"DIV","localName":"div","children":[{"nodeId":201,"nodeType":1,"nodeName":"IMG","localName":"img"}]}]}}"#
    )
    let attributeSequence = await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.attributeModified","params":{"nodeId":201,"name":"src","value":"https://ads.example/detached.webp"}}"#
    )
    await expectProtocolEventApplied(attributeSequence, in: session)
    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: #"{"nodeId":201}"#
    )
    _ = try await performTask.value

    let selectedNode = try #require(await session.dom.selectedNode)
    #expect(await selectedNode.nodeName == "IMG")
    #expect(await selectedNode.attributes == [DOMAttribute(name: "src", value: "https://ads.example/detached.webp")])
}

@Test("Regression: detached frame setChildNodes root keeps requestNode selectable")
func detachedFrameSetChildNodesRootKeepsRequestNodeSelectable() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let sentCountBeforeFrameTarget = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":["DOM","Runtime"],"isProvisional":false}}}"#
    )
    let frameDocumentRequest = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: sentCountBeforeFrameTarget
    )
    await receiveTargetReply(
        transport,
        targetID: frameDocumentRequest.targetIdentifier,
        messageID: try messageID(frameDocumentRequest.message),
        result: firstLazyFrameDocumentResult
    )
    _ = try await waitUntil {
        await session.dom.snapshot().targetsByID[ProtocolTargetIdentifier.frameAd]?.currentDocumentID
    }

    let intent = await session.dom.beginInspectSelectionRequest(
        targetID: .frameAd,
        objectID: "detached-frame-object"
    )
    guard case let .success(commandIntent) = intent else {
        Issue.record("Expected DOM.requestNode intent")
        return
    }

    let sentCount = await backend.sentTargetMessages().count
    let performTask = Task {
        try await session.perform(commandIntent)
    }
    let sent = try await waitForTargetMessage(backend, method: "DOM.requestNode", after: sentCount)
    await receiveTargetDispatch(
        transport,
        targetID: .frameAd,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":0,"nodes":[{"nodeId":300,"nodeType":1,"nodeName":"DIV","localName":"div","children":[{"nodeId":301,"nodeType":1,"nodeName":"IMG","localName":"img"}]}]}}"#
    )
    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: #"{"nodeId":301}"#
    )
    _ = try await performTask.value

    let selectedNode = try #require(await session.dom.selectedNode)
    #expect(await selectedNode.nodeName == "IMG")
    #expect(await session.dom.selectedNodeID?.documentID.targetID == ProtocolTargetIdentifier.frameAd)
}

@Test
func requestNodeReplyBeforePathPushKeepsSelectionPendingUntilParentArrives() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(
        configuration: .init(responseTimeout: .seconds(1), bootstrapTimeout: .seconds(1))
    )
    try await connect(session, transport: transport, backend: backend)
    let snapshotBeforeSelection = await session.dom.snapshot()

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":7,"frameId":"main-frame"}}}"#
    )
    _ = try await waitUntil {
        await session.dom.snapshot().executionContextsByID[ExecutionContextID(7)]
    }
    let intent = await session.dom.beginInspectSelectionRequest(
        targetID: .pageMain,
        objectID: "missing-object"
    )
    guard case let .success(commandIntent) = intent else {
        Issue.record("Expected DOM.requestNode intent")
        return
    }

    let sentCount = await backend.sentTargetMessages().count
    let performTask = Task {
        try await session.perform(commandIntent)
    }
    let sent = try await waitForTargetMessage(backend, method: "DOM.requestNode", after: sentCount)
    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: #"{"nodeId":999}"#
    )
    _ = try await performTask.value

    let snapshot = await session.dom.snapshot()
    #expect(snapshot.documentsByID.keys == snapshotBeforeSelection.documentsByID.keys)
    #expect(snapshot.nodesByID.keys == snapshotBeforeSelection.nodesByID.keys)
    #expect(snapshot.selection.selectedNodeID == nil)
    #expect(snapshot.selection.failure == nil)
    let pendingRequest = try #require(snapshot.selection.pendingRequest)
    #expect(pendingRequest.targetID == .pageMain)
    #expect(snapshot.transactions.contains { transaction in
        transaction.targetID == .pageMain
            && transaction.documentID == pendingRequest.documentID
            && transaction.kind == .requestNode(selectionRequestID: pendingRequest.id, objectID: "missing-object")
            && transaction.requestedProtocolNodeID == .init(999)
    })
    #expect(await session.lastError == nil)

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":2,"nodes":[{"nodeId":999,"nodeType":1,"nodeName":"DIV","localName":"div","attributes":["id","late-path"]}]}}"#
    )

    let selectedNode = try await waitUntil {
        await session.dom.selectedNode
    }
    #expect(await selectedNode.nodeName == "DIV")
    #expect(await selectedNode.attributes == [DOMAttribute(name: "id", value: "late-path")])
    let resolvedSnapshot = await session.dom.snapshot()
    #expect(resolvedSnapshot.selection.pendingRequest == nil)
    #expect(resolvedSnapshot.selection.failure == nil)
}

@Test
func elementPickerBeginAndCancelToggleInspectMode() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let sentCount = await backend.sentTargetMessages().count
    let beginTask = Task {
        try await session.beginElementPicker()
    }
    let enableMessage = try await waitForTargetMessage(backend, method: "DOM.setInspectModeEnabled", after: sentCount)
    #expect(try boolParameter("enabled", in: enableMessage.message) == true)
    await receiveTargetReply(
        transport,
        targetID: enableMessage.targetIdentifier,
        messageID: try messageID(enableMessage.message),
        result: "{}"
    )
    try await beginTask.value
    #expect(await session.isSelectingElement)

    let sentCountBeforeCancel = await backend.sentTargetMessages().count
    let cancelTask = Task {
        await session.cancelElementPicker()
    }
    let disableMessage = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeCancel
    )
    #expect(try boolParameter("enabled", in: disableMessage.message) == false)
    await receiveTargetReply(
        transport,
        targetID: disableMessage.targetIdentifier,
        messageID: try messageID(disableMessage.message),
        result: "{}"
    )
    await cancelTask.value

    #expect(await session.isSelectingElement == false)
}

@Test
func targetDestroyedClearsActiveElementPicker() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await beginPicker(session: session, transport: transport, backend: backend)
    #expect(await session.isSelectingElement)

    await transport.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"page-main"}}"#
    )
    _ = try await waitUntil {
        await session.isSelectingElement == false ? true : nil
    }
}

@Test
func targetCommitClearsElementPickerForOldTarget() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await beginPicker(session: session, transport: transport, backend: backend)
    #expect(await session.isSelectingElement)

    let sentCountBeforeNavigation = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        cssCapablePageTargetCreatedMessage(targetID: "page-next", isProvisional: true)
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"page-next"}}"#
    )

    _ = try await waitUntil {
        await session.isSelectingElement == false ? true : nil
    }

    let bootstrapMessages = try await completeBootstrap(
        transport: transport,
        backend: backend,
        after: sentCountBeforeNavigation,
        documentResult: manualReloadDocumentResult
    )
    #expect(bootstrapMessages.map(\.targetIdentifier).allSatisfy { $0 == .pageNext })
}

@Test
func elementPickerUsesBootstrappedTargetAfterTargetCommit() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let sentCountBeforeNavigation = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        cssCapablePageTargetCreatedMessage(targetID: "page-next", isProvisional: true)
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"page-next"}}"#
    )
    try await completeBootstrap(
        transport: transport,
        backend: backend,
        after: sentCountBeforeNavigation,
        documentResult: manualReloadDocumentResult
    )

    let sentCountBeforePicker = await backend.sentTargetMessages().count
    let beginTask = Task {
        try await session.beginElementPicker()
    }

    let enableMessage = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforePicker
    )
    #expect(enableMessage.targetIdentifier == ProtocolTargetIdentifier.pageNext)
    await receiveTargetReply(
        transport,
        targetID: enableMessage.targetIdentifier,
        messageID: try messageID(enableMessage.message),
        result: "{}"
    )
    try await beginTask.value
    #expect(await session.isSelectingElement)
}

@Test("Regression: element picker ignores inspect events before inspect-mode enable completes")
func elementPickerIgnoresInspectEventBeforeInspectModeReply() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":7,"frameId":"main-frame"}}}"#
    )
    _ = try await waitUntil {
        await session.dom.snapshot().executionContextsByID[ExecutionContextID(7)]
    }

    let sentCount = await backend.sentTargetMessages().count
    let beginTask = Task {
        try await session.beginElementPicker()
    }
    let enableMessage = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCount
    )
    #expect(try boolParameter("enabled", in: enableMessage.message) == true)
    #expect(await session.isSelectingElement)

    let sentCountBeforeInspect = await backend.sentTargetMessages().count
    let inspectBeforeEnableSequence = await transport.receiveRootMessage(#"{"method":"Inspector.inspect","params":{"object":{"objectId":"{\"injectedScriptId\":7,\"id\":99}"},"hints":{}}}"#)
    await expectProtocolEventApplied(inspectBeforeEnableSequence, in: session)
    let messagesBeforeEnableReply = await backend.sentTargetMessages().dropFirst(sentCountBeforeInspect)
    #expect(messagesBeforeEnableReply.allSatisfy { (try? messageMethod($0.message)) != "DOM.requestNode" })
    #expect(await session.isSelectingElement)

    await receiveTargetReply(
        transport,
        targetID: enableMessage.targetIdentifier,
        messageID: try messageID(enableMessage.message),
        result: "{}"
    )
    try await beginTask.value

    let sentCountBeforeAcceptedInspect = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(#"{"method":"Inspector.inspect","params":{"object":{"objectId":"{\"injectedScriptId\":7,\"id\":99}"},"hints":{}}}"#)
    let requestNode = try await waitForTargetMessage(
        backend,
        method: "DOM.requestNode",
        after: sentCountBeforeAcceptedInspect
    )
    #expect(requestNode.targetIdentifier == ProtocolTargetIdentifier.pageMain)

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":2,"nodes":[{"nodeId":3,"nodeType":1,"nodeName":"DIV","localName":"div","attributes":["id","selected"]}]}}"#
    )
    let sentCountBeforeRequestReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: requestNode.targetIdentifier,
        messageID: try messageID(requestNode.message),
        result: #"{"nodeId":3}"#
    )
    let disableMessage = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeRequestReply
    )
    #expect(try boolParameter("enabled", in: disableMessage.message) == false)
    await receiveTargetReply(
        transport,
        targetID: disableMessage.targetIdentifier,
        messageID: try messageID(disableMessage.message),
        result: "{}"
    )

    let selectedNode = try await waitUntil {
        await session.dom.selectedNode
    }
    #expect(await selectedNode.nodeName == "DIV")
    #expect(await session.isSelectingElement == false)
}

@Test("Regression: restarted picker ignores stale inspect event while enable is pending")
func restartedElementPickerIgnoresStaleInspectEventBeforeInspectModeReply() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":7,"frameId":"main-frame"}}}"#
    )
    _ = try await waitUntil {
        await session.dom.snapshot().executionContextsByID[ExecutionContextID(7)]
    }

    let sentCountBeforeFirstBegin = await backend.sentTargetMessages().count
    let firstBeginTask = Task {
        try await session.beginElementPicker()
    }
    let firstEnable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeFirstBegin
    )
    #expect(try boolParameter("enabled", in: firstEnable.message) == true)

    let sentCountBeforeCancel = await backend.sentTargetMessages().count
    let cancelTask = Task {
        await session.cancelElementPicker()
    }
    let cancelDisable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeCancel
    )
    #expect(try boolParameter("enabled", in: cancelDisable.message) == false)
    await receiveTargetReply(
        transport,
        targetID: cancelDisable.targetIdentifier,
        messageID: try messageID(cancelDisable.message),
        result: "{}"
    )
    await cancelTask.value

    let sentCountBeforeRestart = await backend.sentTargetMessages().count
    let restartTask = Task {
        try await session.beginElementPicker()
    }
    let restartEnable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeRestart
    )
    #expect(try boolParameter("enabled", in: restartEnable.message) == true)
    #expect(await session.isSelectingElement)

    let sentCountBeforeStaleInspect = await backend.sentTargetMessages().count
    let staleInspectSequence = await transport.receiveRootMessage(#"{"method":"Inspector.inspect","params":{"object":{"objectId":"{\"injectedScriptId\":7,\"id\":99}"},"hints":{}}}"#)
    await expectProtocolEventApplied(staleInspectSequence, in: session)
    let messagesAfterStaleInspect = await backend.sentTargetMessages().dropFirst(sentCountBeforeStaleInspect)
    #expect(messagesAfterStaleInspect.allSatisfy { (try? messageMethod($0.message)) != "DOM.requestNode" })
    #expect(messagesAfterStaleInspect.allSatisfy { (try? messageMethod($0.message)) != "DOM.setInspectModeEnabled" })
    #expect(await session.isSelectingElement)

    await receiveTargetReply(
        transport,
        targetID: firstEnable.targetIdentifier,
        messageID: try messageID(firstEnable.message),
        result: "{}"
    )
    try await firstBeginTask.value
    #expect(await session.isSelectingElement)

    await receiveTargetReply(
        transport,
        targetID: restartEnable.targetIdentifier,
        messageID: try messageID(restartEnable.message),
        result: "{}"
    )
    try await restartTask.value

    let sentCountBeforeAcceptedInspect = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(#"{"method":"Inspector.inspect","params":{"object":{"objectId":"{\"injectedScriptId\":7,\"id\":99}"},"hints":{}}}"#)
    let requestNode = try await waitForTargetMessage(
        backend,
        method: "DOM.requestNode",
        after: sentCountBeforeAcceptedInspect
    )
    #expect(requestNode.targetIdentifier == ProtocolTargetIdentifier.pageMain)
    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":2,"nodes":[{"nodeId":3,"nodeType":1,"nodeName":"DIV","localName":"div","attributes":["id","selected"]}]}}"#
    )
    let sentCountBeforeRequestReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: requestNode.targetIdentifier,
        messageID: try messageID(requestNode.message),
        result: #"{"nodeId":3}"#
    )
    let disable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeRequestReply
    )
    #expect(try boolParameter("enabled", in: disable.message) == false)
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )

    let selectedNode = try await waitUntil {
        await session.dom.selectedNode
    }
    #expect(await selectedNode.nodeName == "DIV")
    #expect(await session.isSelectingElement == false)
}

@Test
func staleInspectEventCompletionDoesNotCancelRestartedPicker() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":7,"frameId":"main-frame"}}}"#
    )
    _ = try await waitUntil {
        await session.dom.snapshot().executionContextsByID[ExecutionContextID(7)]
    }
    try await beginPicker(session: session, transport: transport, backend: backend)

    let sentCountBeforeInspect = await backend.sentTargetMessages().count
    let inspectSequence = await transport.receiveRootMessage(#"{"method":"Inspector.inspect","params":{"object":{"objectId":"{\"injectedScriptId\":7,\"id\":99}"},"hints":{}}}"#)
    let requestNode = try await waitForTargetMessage(
        backend,
        method: "DOM.requestNode",
        after: sentCountBeforeInspect
    )

    let sentCountBeforeCancel = await backend.sentTargetMessages().count
    let cancelTask = Task {
        await session.cancelElementPicker()
    }
    let cancelDisable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeCancel
    )
    #expect(try boolParameter("enabled", in: cancelDisable.message) == false)
    await receiveTargetReply(
        transport,
        targetID: cancelDisable.targetIdentifier,
        messageID: try messageID(cancelDisable.message),
        result: "{}"
    )
    await cancelTask.value

    let sentCountBeforeRestart = await backend.sentTargetMessages().count
    let restartTask = Task {
        try await session.beginElementPicker()
    }
    let restartEnable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeRestart
    )
    #expect(try boolParameter("enabled", in: restartEnable.message) == true)
    await receiveTargetReply(
        transport,
        targetID: restartEnable.targetIdentifier,
        messageID: try messageID(restartEnable.message),
        result: "{}"
    )
    try await restartTask.value
    #expect(await session.isSelectingElement)

    let sentCountBeforeStaleReply = await backend.sentTargetMessages().count
    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":2,"nodes":[{"nodeId":3,"nodeType":1,"nodeName":"DIV","localName":"div","attributes":["id","old-picker"]}]}}"#
    )
    await receiveTargetReply(
        transport,
        targetID: requestNode.targetIdentifier,
        messageID: try messageID(requestNode.message),
        result: #"{"nodeId":3}"#
    )
    await expectProtocolEventApplied(inspectSequence, in: session)

    let messagesAfterStaleReply = await backend.sentTargetMessages().dropFirst(sentCountBeforeStaleReply)
    #expect(await session.isSelectingElement)
    #expect(messagesAfterStaleReply.allSatisfy { (try? messageMethod($0.message)) != "DOM.setInspectModeEnabled" })
}

@Test
func inspectorInspectSelectsRequestedNodeAndDisablesPicker() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":7,"frameId":"main-frame"}}}"#
    )
    _ = try await waitUntil {
        await session.dom.snapshot().executionContextsByID[ExecutionContextID(7)]
    }
    try await beginPicker(session: session, transport: transport, backend: backend)
    let sentCountBeforeInspect = await backend.sentTargetMessages().count

    await transport.receiveRootMessage(#"{"method":"Inspector.inspect","params":{"object":{"objectId":"{\"injectedScriptId\":7,\"id\":99}"},"hints":{}}}"#)
    let requestNode = try await waitForTargetMessage(
        backend,
        method: "DOM.requestNode",
        after: sentCountBeforeInspect
    )
    #expect(requestNode.targetIdentifier == ProtocolTargetIdentifier.pageMain)
    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":2,"nodes":[{"nodeId":3,"nodeType":1,"nodeName":"DIV","localName":"div","attributes":["id","selected"]}]}}"#
    )
    let sentCountBeforeRequestReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: requestNode.targetIdentifier,
        messageID: try messageID(requestNode.message),
        result: #"{"nodeId":3}"#
    )
    let disable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeRequestReply
    )
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )

    let selectedNode = try await waitUntil {
        await session.dom.selectedNode
    }
    #expect(await selectedNode.nodeName == "DIV")
    #expect(await session.isSelectingElement == false)
}

@Test
func inspectorInspectWaitsForPathPushEventsBeforeSelectingNode() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(
        configuration: .init(
            responseTimeout: .seconds(1),
            bootstrapTimeout: .seconds(1)
        )
    )
    try await connect(session, transport: transport, backend: backend)
    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":7,"frameId":"main-frame"}}}"#
    )
    _ = try await waitUntil {
        await session.dom.snapshot().executionContextsByID[ExecutionContextID(7)]
    }
    try await beginPicker(session: session, transport: transport, backend: backend)
    let sentCountBeforeInspect = await backend.sentTargetMessages().count

    await transport.receiveRootMessage(#"{"method":"Inspector.inspect","params":{"object":{"objectId":"{\"injectedScriptId\":7,\"id\":99}"},"hints":{}}}"#)
    let requestNode = try await waitForTargetMessage(
        backend,
        method: "DOM.requestNode",
        after: sentCountBeforeInspect
    )

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":2,"nodes":[{"nodeId":3,"nodeType":1,"nodeName":"DIV","localName":"div","attributes":["id","selected-after-path-push"]}]}}"#
    )
    let sentCountBeforeRequestReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: requestNode.targetIdentifier,
        messageID: try messageID(requestNode.message),
        result: #"{"nodeId":3}"#
    )
    let disable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeRequestReply
    )
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )

    let selectedNode = try await waitUntil {
        await session.dom.selectedNode
    }
    #expect(await selectedNode.attributes == [DOMAttribute(name: "id", value: "selected-after-path-push")])
    #expect(await session.isSelectingElement == false)
}

@Test
func inspectorInspectRecordedExecutionContextOverridesEventTargetHint() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#
    )
    _ = try await waitUntil {
        await session.dom.snapshot().targetsByID[.frameAd]
    }
    _ = await session.dom.replaceDocumentRoot(
        DOMNodePayload(
            nodeID: .init(1),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                DOMNodePayload(nodeID: .init(2), nodeType: .element, nodeName: "HTML", localName: "html"),
            ])
        ),
        targetID: .frameAd
    )
    await receiveTargetDispatch(
        transport,
        targetID: .frameAd,
        message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":77,"frameId":"ad-frame"}}}"#
    )
    _ = try await waitUntil {
        await session.dom.snapshot().executionContextsByID[ExecutionContextID(77)]
    }
    try await beginPicker(session: session, transport: transport, backend: backend)
    let sentCountBeforeInspect = await backend.sentTargetMessages().count

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Inspector.inspect","params":{"object":{"objectId":"{\"injectedScriptId\":77,\"id\":99}"},"hints":{}}}"#
    )
    let requestNode = try await waitForTargetMessage(
        backend,
        method: "DOM.requestNode",
        after: sentCountBeforeInspect
    )
    #expect(requestNode.targetIdentifier == ProtocolTargetIdentifier.frameAd)

    await receiveTargetDispatch(
        transport,
        targetID: .frameAd,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":2,"nodes":[{"nodeId":3,"nodeType":1,"nodeName":"DIV","localName":"div","attributes":["id","selected"]}]}}"#
    )
    let sentCountBeforeRequestReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: requestNode.targetIdentifier,
        messageID: try messageID(requestNode.message),
        result: #"{"nodeId":3}"#
    )
    let disable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeRequestReply
    )
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )

    let selectedNode = try await waitUntil {
        await session.dom.selectedNode
    }
    #expect(await selectedNode.nodeName == "DIV")
    #expect(await session.isSelectingElement == false)
}

@Test
func inspectorInspectOpaqueObjectIDFallsBackToPickerTarget() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await beginPicker(session: session, transport: transport, backend: backend)
    let sentCountBeforeInspect = await backend.sentTargetMessages().count

    await transport.receiveRootMessage(#"{"method":"Inspector.inspect","params":{"object":{"objectId":"opaque-remote-node"},"hints":{}}}"#)
    let requestNode = try await waitForTargetMessage(
        backend,
        method: "DOM.requestNode",
        after: sentCountBeforeInspect
    )
    #expect(requestNode.targetIdentifier == ProtocolTargetIdentifier.pageMain)
    #expect(String(data: Data(requestNode.message.utf8), encoding: .utf8)?.contains(#""objectId":"opaque-remote-node""#) == true)

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":2,"nodes":[{"nodeId":3,"nodeType":1,"nodeName":"DIV","localName":"div","attributes":["id","selected"]}]}}"#
    )
    let sentCountBeforeRequestReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: requestNode.targetIdentifier,
        messageID: try messageID(requestNode.message),
        result: #"{"nodeId":3}"#
    )
    let disable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeRequestReply
    )
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )

    let selectedNode = try await waitUntil {
        await session.dom.selectedNode
    }
    #expect(await selectedNode.nodeName == "DIV")
    #expect(await session.isSelectingElement == false)
}

@Test
func targetScopedInspectorInspectUsesEventTargetAsFallback() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#
    )
    _ = try await waitUntil {
        await session.dom.snapshot().targetsByID[.frameAd]
    }
    _ = await session.dom.replaceDocumentRoot(
        DOMNodePayload(
            nodeID: .init(1),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                DOMNodePayload(nodeID: .init(2), nodeType: .element, nodeName: "HTML", localName: "html"),
            ])
        ),
        targetID: .frameAd
    )
    try await beginPicker(session: session, transport: transport, backend: backend)
    let sentCountBeforeInspect = await backend.sentTargetMessages().count

    await receiveTargetDispatch(
        transport,
        targetID: .frameAd,
        message: #"{"method":"Inspector.inspect","params":{"object":{"objectId":"opaque-frame-node"},"hints":{}}}"#
    )
    let requestNode = try await waitForTargetMessage(
        backend,
        method: "DOM.requestNode",
        after: sentCountBeforeInspect
    )
    #expect(requestNode.targetIdentifier == ProtocolTargetIdentifier.frameAd)

    await receiveTargetDispatch(
        transport,
        targetID: .frameAd,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":2,"nodes":[{"nodeId":3,"nodeType":1,"nodeName":"DIV","localName":"div","attributes":["id","selected"]}]}}"#
    )
    let sentCountBeforeRequestReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: requestNode.targetIdentifier,
        messageID: try messageID(requestNode.message),
        result: #"{"nodeId":3}"#
    )
    let disable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeRequestReply
    )
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )

    let selectedNode = try await waitUntil {
        await session.dom.selectedNode
    }
    #expect(await selectedNode.nodeName == "DIV")
    #expect(await session.isSelectingElement == false)
}

@Test
func targetScopedInspectorInspectFallsBackToEventTargetWhenContextIsUnrecorded() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#
    )
    _ = try await waitUntil {
        await session.dom.snapshot().targetsByID[.frameAd]
    }
    _ = await session.dom.replaceDocumentRoot(
        DOMNodePayload(
            nodeID: .init(1),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                DOMNodePayload(nodeID: .init(2), nodeType: .element, nodeName: "HTML", localName: "html"),
            ])
        ),
        targetID: .frameAd
    )
    try await beginPicker(session: session, transport: transport, backend: backend)
    let sentCountBeforeInspect = await backend.sentTargetMessages().count
    let objectID = #"{"injectedScriptId":777,"id":99}"#

    await receiveTargetDispatch(
        transport,
        targetID: .frameAd,
        message: #"{"method":"Inspector.inspect","params":{"object":{"objectId":"\#(jsonEscapedString(objectID))"},"hints":{}}}"#
    )
    let requestNode = try await waitForTargetMessage(
        backend,
        method: "DOM.requestNode",
        after: sentCountBeforeInspect
    )
    #expect(requestNode.targetIdentifier == ProtocolTargetIdentifier.frameAd)

    await receiveTargetDispatch(
        transport,
        targetID: .frameAd,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":2,"nodes":[{"nodeId":3,"nodeType":1,"nodeName":"DIV","localName":"div","attributes":["id","selected"]}]}}"#
    )
    let sentCountBeforeRequestReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: requestNode.targetIdentifier,
        messageID: try messageID(requestNode.message),
        result: #"{"nodeId":3}"#
    )
    let disable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeRequestReply
    )
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )

    let selectedNode = try await waitUntil {
        await session.dom.selectedNode
    }
    #expect(await selectedNode.nodeName == "DIV")
    #expect(await session.isSelectingElement == false)
}

@Test
func domInspectSelectsKnownProtocolNodeWithoutRequestNode() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await beginPicker(session: session, transport: transport, backend: backend)
    let sentCountBeforeInspect = await backend.sentTargetMessages().count

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.inspect","params":{"nodeId":2}}"#
    )
    let disable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeInspect
    )
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )

    let selectedNode = try #require(await session.dom.selectedNode)
    #expect(await selectedNode.nodeName == "HTML")
    #expect(await backend.sentTargetMessages().dropFirst(sentCountBeforeInspect).contains {
        (try? messageMethod($0.message)) == "DOM.requestNode"
    } == false)
}

@Test
func domInspectReloadsDocumentBeforeFailingUnknownProtocolNode() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await beginPicker(session: session, transport: transport, backend: backend)
    let sentCountBeforeInspect = await backend.sentTargetMessages().count

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.inspect","params":{"nodeId":4}}"#
    )
    let reload = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: sentCountBeforeInspect
    )
    await receiveTargetReply(
        transport,
        targetID: reload.targetIdentifier,
        messageID: try messageID(reload.message),
        result: nestedDocumentResult
    )
    let disable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeInspect
    )
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )

    let selectedNode = try await waitUntil {
        await session.dom.selectedNode
    }
    #expect(await selectedNode.nodeName == "DIV")
    #expect(await session.isSelectingElement == false)
}

@Test
func domNavigationCopyDeleteAndReloadUseRuntimeAPIs() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    #expect(await session.hasInspectablePageWebView == false)
    let htmlID = try #require(await session.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(2))])
    await session.dom.selectNode(htmlID)

    let countBeforeHTMLCopy = await backend.sentTargetMessages().count
    let copyTask = Task {
        try await session.copySelectedDOMNodeText(.html)
    }
    let outerHTML = try await waitForTargetMessage(backend, method: "DOM.getOuterHTML", after: countBeforeHTMLCopy)
    await receiveTargetReply(
        transport,
        targetID: outerHTML.targetIdentifier,
        messageID: try messageID(outerHTML.message),
        result: #"{"outerHTML":"<html></html>"}"#
    )
    #expect(try await copyTask.value == "<html></html>")

    let countBeforeSelectorCopy = await backend.sentTargetMessages().count
    #expect(try await session.copySelectedDOMNodeText(.selectorPath) == "html")
    #expect(await backend.sentTargetMessages().count == countBeforeSelectorCopy)

    let countBeforeDelete = await backend.sentTargetMessages().count
    let deleteTask = Task {
        try await session.deleteSelectedDOMNode(undoManager: nil)
    }
    let removeNode = try await waitForTargetMessage(backend, method: "DOM.removeNode", after: countBeforeDelete)
    await receiveTargetReply(
        transport,
        targetID: removeNode.targetIdentifier,
        messageID: try messageID(removeNode.message),
        result: "{}"
    )
    try await deleteTask.value
    #expect(await session.dom.selectedNodeID == nil)

    let countBeforeReload = await backend.sentTargetMessages().count
    let reloadTask = Task {
        try await session.reloadDOMDocument()
    }
    let getDocument = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: countBeforeReload)
    await receiveTargetReply(
        transport,
        targetID: getDocument.targetIdentifier,
        messageID: try messageID(getDocument.message),
        result: ##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","children":[{"nodeId":2,"nodeType":1,"nodeName":"HTML","localName":"html","children":[{"nodeId":4,"nodeType":1,"nodeName":"BODY","localName":"body"}]}]}}"##
    )
    try await reloadTask.value

    let reloadedBody = await session.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(4))]
    #expect(reloadedBody != nil)
}

@Test
func deletingDOMNodeClearsExistingSelectionEvenWhenDeletingAnotherNode() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)

    let htmlID = try #require(await session.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(2))])
    let bodyID = try #require(await session.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(4))])
    await session.dom.selectNode(htmlID)

    let countBeforeDelete = await backend.sentTargetMessages().count
    let deleteTask = Task {
        try await session.deleteDOMNode(bodyID, undoManager: nil)
    }
    let removeNode = try await waitForTargetMessage(backend, method: "DOM.removeNode", after: countBeforeDelete)
    await receiveTargetReply(
        transport,
        targetID: removeNode.targetIdentifier,
        messageID: try messageID(removeNode.message),
        result: "{}"
    )
    try await deleteTask.value

    #expect(await session.dom.selectedNodeID == nil)
}

@MainActor
@Test
func multiNodeDeleteRegistersSingleUndoGroup() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)

    let headID = try #require(session.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(3))])
    let bodyID = try #require(session.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(4))])
    let undoManager = UndoManager()

    let countBeforeDelete = await backend.sentTargetMessages().count
    let deleteTask = Task {
        try await session.deleteDOMNodes([headID, bodyID], undoManager: undoManager)
    }
    let firstRemoveNode = try await waitForTargetMessage(backend, method: "DOM.removeNode", after: countBeforeDelete)
    await receiveTargetReply(
        transport,
        targetID: firstRemoveNode.targetIdentifier,
        messageID: try messageID(firstRemoveNode.message),
        result: "{}"
    )
    let countAfterFirstRemove = await backend.sentTargetMessages().count
    let secondRemoveNode = try await waitForTargetMessage(backend, method: "DOM.removeNode", after: countAfterFirstRemove)
    await receiveTargetReply(
        transport,
        targetID: secondRemoveNode.targetIdentifier,
        messageID: try messageID(secondRemoveNode.message),
        result: "{}"
    )
    try await deleteTask.value

    #expect(undoManager.canUndo)
    #expect(undoManager.undoActionName == "Delete Nodes")

    let countBeforeUndo = await backend.sentTargetMessages().count
    undoManager.undo()
    #expect(undoManager.canUndo == false)
    #expect(undoManager.canRedo)

    let firstUndo = try await waitForTargetMessage(backend, method: "DOM.undo", after: countBeforeUndo)
    await receiveTargetReply(
        transport,
        targetID: firstUndo.targetIdentifier,
        messageID: try messageID(firstUndo.message),
        result: "{}"
    )
    let firstDocumentReload = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: countBeforeUndo)
    await receiveTargetReply(
        transport,
        targetID: firstDocumentReload.targetIdentifier,
        messageID: try messageID(firstDocumentReload.message),
        result: mainDocumentResult
    )

    let secondUndo = try await waitForTargetMessage(backend, method: "DOM.undo", ordinal: 1, after: countBeforeUndo)
    await receiveTargetReply(
        transport,
        targetID: secondUndo.targetIdentifier,
        messageID: try messageID(secondUndo.message),
        result: "{}"
    )
    let secondDocumentReload = try await waitForTargetMessage(backend, method: "DOM.getDocument", ordinal: 1, after: countBeforeUndo)
    await receiveTargetReply(
        transport,
        targetID: secondDocumentReload.targetIdentifier,
        messageID: try messageID(secondDocumentReload.message),
        result: mainDocumentResult
    )
}

@Test
func frameDOMNodeCopyDeleteRouteThroughPageTargetWithScopedNodeID() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#
    )
    _ = try await waitUntil {
        await session.dom.snapshot().targetsByID[.frameAd]
    }
    _ = await session.dom.replaceDocumentRoot(
        DOMNodePayload(
            nodeID: .init(101),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                DOMNodePayload(nodeID: .init(102), nodeType: .element, nodeName: "HTML", localName: "html"),
            ])
        ),
        targetID: .frameAd
    )
    let frameHTMLID = try #require(await session.dom.snapshot().currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(102))])
    await session.dom.selectNode(frameHTMLID)

    let countBeforeHighlight = await backend.sentTargetMessages().count
    let highlightTask = Task {
        await session.highlightNode(for: frameHTMLID)
    }
    let highlightNode = try await waitForTargetMessage(backend, method: "DOM.highlightNode", after: countBeforeHighlight)
    #expect(highlightNode.targetIdentifier == ProtocolTargetIdentifier.frameAd)
    #expect(try integerParameter("nodeId", in: highlightNode.message) == 102)
    await receiveTargetReply(
        transport,
        targetID: highlightNode.targetIdentifier,
        messageID: try messageID(highlightNode.message),
        result: "{}"
    )
    await highlightTask.value

    let countBeforeHideHighlight = await backend.sentTargetMessages().count
    let hideHighlightTask = Task {
        await session.hideNodeHighlight()
    }
    let hideHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: countBeforeHideHighlight
    )
    #expect(hideHighlight.targetIdentifier == ProtocolTargetIdentifier.frameAd)
    await receiveTargetReply(
        transport,
        targetID: hideHighlight.targetIdentifier,
        messageID: try messageID(hideHighlight.message),
        result: "{}"
    )
    await hideHighlightTask.value

    let countBeforeHTMLCopy = await backend.sentTargetMessages().count
    let copyTask = Task {
        try await session.copySelectedDOMNodeText(.html)
    }
    let outerHTML = try await waitForTargetMessage(backend, method: "DOM.getOuterHTML", after: countBeforeHTMLCopy)
    #expect(outerHTML.targetIdentifier == ProtocolTargetIdentifier.pageMain)
    #expect(try stringParameter("nodeId", in: outerHTML.message) == "frame-ad:102")
    await receiveTargetReply(
        transport,
        targetID: outerHTML.targetIdentifier,
        messageID: try messageID(outerHTML.message),
        result: #"{"outerHTML":"<html></html>"}"#
    )
    #expect(try await copyTask.value == "<html></html>")

    let countBeforeDelete = await backend.sentTargetMessages().count
    let deleteTask = Task {
        try await session.deleteSelectedDOMNode(undoManager: nil)
    }
    let removeNode = try await waitForTargetMessage(backend, method: "DOM.removeNode", after: countBeforeDelete)
    #expect(removeNode.targetIdentifier == ProtocolTargetIdentifier.pageMain)
    #expect(try stringParameter("nodeId", in: removeNode.message) == "frame-ad:102")
    await receiveTargetReply(
        transport,
        targetID: removeNode.targetIdentifier,
        messageID: try messageID(removeNode.message),
        result: "{}"
    )
    try await deleteTask.value
    #expect(await session.dom.selectedNodeID == nil)
}

@MainActor
@Test
func deleteUndoRedoKeepsUndoManagerStacksAvailableDuringAsyncProtocolWork() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let htmlID = try #require(session.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(2))])
    session.dom.selectNode(htmlID)

    let undoManager = UndoManager()
    let countBeforeDelete = await backend.sentTargetMessages().count
    let deleteTask = Task {
        try await session.deleteSelectedDOMNode(undoManager: undoManager)
    }
    let removeNode = try await waitForTargetMessage(backend, method: "DOM.removeNode", after: countBeforeDelete)
    await receiveTargetReply(
        transport,
        targetID: removeNode.targetIdentifier,
        messageID: try messageID(removeNode.message),
        result: "{}"
    )
    try await deleteTask.value
    #expect(undoManager.canUndo)
    #expect(undoManager.canRedo == false)

    let countBeforeUndo = await backend.sentTargetMessages().count
    undoManager.undo()
    #expect(undoManager.canRedo)
    let undo = try await waitForTargetMessage(backend, method: "DOM.undo", after: countBeforeUndo)
    await receiveTargetReply(
        transport,
        targetID: undo.targetIdentifier,
        messageID: try messageID(undo.message),
        result: "{}"
    )
    let documentAfterUndo = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: countBeforeUndo)
    await receiveTargetReply(
        transport,
        targetID: documentAfterUndo.targetIdentifier,
        messageID: try messageID(documentAfterUndo.message),
        result: mainDocumentResult
    )

    let countBeforeRedo = await backend.sentTargetMessages().count
    undoManager.redo()
    #expect(undoManager.canUndo)
    let redo = try await waitForTargetMessage(backend, method: "DOM.redo", after: countBeforeRedo)
    await receiveTargetReply(
        transport,
        targetID: redo.targetIdentifier,
        messageID: try messageID(redo.message),
        result: "{}"
    )
    let documentAfterRedo = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: countBeforeRedo)
    await receiveTargetReply(
        transport,
        targetID: documentAfterRedo.targetIdentifier,
        messageID: try messageID(documentAfterRedo.message),
        result: mainDocumentResult
    )
}

@MainActor
@Test
func reloadDOMDocumentDiscardsDeleteUndoHistory() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let htmlID = try #require(session.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(2))])
    session.dom.selectNode(htmlID)

    let undoManager = UndoManager()
    let countBeforeDelete = await backend.sentTargetMessages().count
    let deleteTask = Task {
        try await session.deleteSelectedDOMNode(undoManager: undoManager)
    }
    let removeNode = try await waitForTargetMessage(backend, method: "DOM.removeNode", after: countBeforeDelete)
    await receiveTargetReply(
        transport,
        targetID: removeNode.targetIdentifier,
        messageID: try messageID(removeNode.message),
        result: "{}"
    )
    try await deleteTask.value
    #expect(undoManager.canUndo)

    let countBeforeReload = await backend.sentTargetMessages().count
    let reloadTask = Task {
        try await session.reloadDOMDocument()
    }
    let getDocument = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: countBeforeReload)
    #expect(undoManager.canUndo == false)
    await receiveTargetReply(
        transport,
        targetID: getDocument.targetIdentifier,
        messageID: try messageID(getDocument.message),
        result: mainDocumentResult
    )
    try await reloadTask.value
}

@MainActor
@Test
func reloadDOMDocumentCancelsQueuedDeleteUndoOperationsBeforeTheySend() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let htmlID = try #require(session.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(2))])
    session.dom.selectNode(htmlID)

    let undoManager = UndoManager()
    let countBeforeDelete = await backend.sentTargetMessages().count
    let deleteTask = Task {
        try await session.deleteSelectedDOMNode(undoManager: undoManager)
    }
    let removeNode = try await waitForTargetMessage(backend, method: "DOM.removeNode", after: countBeforeDelete)
    await receiveTargetReply(
        transport,
        targetID: removeNode.targetIdentifier,
        messageID: try messageID(removeNode.message),
        result: "{}"
    )
    try await deleteTask.value
    #expect(undoManager.canUndo)

    let countBeforeQueuedOperations = await backend.sentTargetMessages().count
    let reloadReplyTask = Task {
        let getDocument = await backend.waitForTargetMessage(method: "DOM.getDocument", after: countBeforeQueuedOperations)
        await receiveTargetReply(
            transport,
            targetID: getDocument.targetIdentifier,
            messageID: try messageID(getDocument.message),
            result: mainDocumentResult
        )
    }

    undoManager.undo()
    #expect(undoManager.canRedo)
    undoManager.redo()

    try await session.reloadDOMDocument()
    try await reloadReplyTask.value

    let methodsAfterReload = await targetMessageMethods(backend).dropFirst(countBeforeQueuedOperations)
    #expect(methodsAfterReload.contains("DOM.getDocument"))
    #expect(methodsAfterReload.contains("DOM.undo") == false)
    #expect(methodsAfterReload.contains("DOM.redo") == false)
}

@MainActor
@Test
func deleteUndoReloadCancellationClearsUndoHistory() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let htmlID = try #require(session.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(2))])
    session.dom.selectNode(htmlID)

    let undoManager = UndoManager()
    let countBeforeDelete = await backend.sentTargetMessages().count
    let deleteTask = Task {
        try await session.deleteSelectedDOMNode(undoManager: undoManager)
    }
    let removeNode = try await waitForTargetMessage(backend, method: "DOM.removeNode", after: countBeforeDelete)
    await receiveTargetReply(
        transport,
        targetID: removeNode.targetIdentifier,
        messageID: try messageID(removeNode.message),
        result: "{}"
    )
    try await deleteTask.value
    #expect(undoManager.canUndo)

    let countBeforeUndo = await backend.sentTargetMessages().count
    undoManager.undo()
    let undo = try await waitForTargetMessage(backend, method: "DOM.undo", after: countBeforeUndo)
    await receiveTargetReply(
        transport,
        targetID: undo.targetIdentifier,
        messageID: try messageID(undo.message),
        result: "{}"
    )
    _ = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: countBeforeUndo)
    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.documentUpdated","params":{}}"#
    )

    _ = try await waitUntil {
        await MainActor.run {
            undoManager.canRedo == false ? session.lastError : nil
        }
    }
    #expect(undoManager.canUndo == false)
    #expect(undoManager.canRedo == false)
    #expect(session.lastError == InspectorSessionError(String(describing: CancellationError())))
}

@MainActor
@Test
func reloadDOMDocumentCancelsActiveElementPickerBeforeReplacingDocument() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await beginPicker(session: session, transport: transport, backend: backend)
    #expect(session.isSelectingElement)

    let countBeforeReload = await backend.sentTargetMessages().count
    let reloadTask = Task {
        try await session.reloadDOMDocument()
    }
    let disablePicker = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: countBeforeReload
    )
    #expect(try boolParameter("enabled", in: disablePicker.message) == false)
    await receiveTargetReply(
        transport,
        targetID: disablePicker.targetIdentifier,
        messageID: try messageID(disablePicker.message),
        result: "{}"
    )
    let getDocument = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: countBeforeReload)
    await receiveTargetReply(
        transport,
        targetID: getDocument.targetIdentifier,
        messageID: try messageID(getDocument.message),
        result: mainDocumentResult
    )
    try await reloadTask.value
    #expect(session.isSelectingElement == false)
}

@MainActor
@Test
func deleteUndoKeepsOlderUndoStatesCurrentAfterReload() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    _ = session.dom.replaceDocumentRoot(
        DOMNodePayload(
            nodeID: .init(1),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                DOMNodePayload(
                    nodeID: .init(2),
                    nodeType: .element,
                    nodeName: "HTML",
                    localName: "html",
                    regularChildren: .loaded([
                        DOMNodePayload(
                            nodeID: .init(3),
                            nodeType: .element,
                            nodeName: "BODY",
                            localName: "body",
                            regularChildren: .loaded([
                                DOMNodePayload(nodeID: .init(4), nodeType: .element, nodeName: "DIV", localName: "div"),
                            ])
                        ),
                    ])
                ),
            ])
        ),
        targetID: .pageMain
    )
    let bodyID = try #require(session.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(3))])
    let divID = try #require(session.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(4))])
    let undoManager = UndoManager()

    session.dom.selectNode(divID)
    let countBeforeFirstDelete = await backend.sentTargetMessages().count
    let firstDeleteTask = Task {
        try await session.deleteSelectedDOMNode(undoManager: undoManager)
    }
    let firstRemoveNode = try await waitForTargetMessage(backend, method: "DOM.removeNode", after: countBeforeFirstDelete)
    await receiveTargetReply(
        transport,
        targetID: firstRemoveNode.targetIdentifier,
        messageID: try messageID(firstRemoveNode.message),
        result: "{}"
    )
    try await firstDeleteTask.value

    session.dom.selectNode(bodyID)
    let countBeforeSecondDelete = await backend.sentTargetMessages().count
    let secondDeleteTask = Task {
        try await session.deleteSelectedDOMNode(undoManager: undoManager)
    }
    let secondRemoveNode = try await waitForTargetMessage(backend, method: "DOM.removeNode", after: countBeforeSecondDelete)
    await receiveTargetReply(
        transport,
        targetID: secondRemoveNode.targetIdentifier,
        messageID: try messageID(secondRemoveNode.message),
        result: "{}"
    )
    try await secondDeleteTask.value
    #expect(undoManager.canUndo)

    let countBeforeFirstUndo = await backend.sentTargetMessages().count
    undoManager.undo()
    let firstUndo = try await waitForTargetMessage(backend, method: "DOM.undo", after: countBeforeFirstUndo)
    await receiveTargetReply(
        transport,
        targetID: firstUndo.targetIdentifier,
        messageID: try messageID(firstUndo.message),
        result: "{}"
    )
    let documentAfterFirstUndo = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: countBeforeFirstUndo)
    await receiveTargetReply(
        transport,
        targetID: documentAfterFirstUndo.targetIdentifier,
        messageID: try messageID(documentAfterFirstUndo.message),
        result: nestedDocumentResult
    )
    _ = try await waitUntil {
        await session.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(4))]
    }

    let countBeforeSecondUndo = await backend.sentTargetMessages().count
    undoManager.undo()
    let secondUndo = try await waitForTargetMessage(backend, method: "DOM.undo", after: countBeforeSecondUndo)
    #expect(secondUndo.targetIdentifier == ProtocolTargetIdentifier.pageMain)
    await receiveTargetReply(
        transport,
        targetID: secondUndo.targetIdentifier,
        messageID: try messageID(secondUndo.message),
        result: "{}"
    )
    let documentAfterSecondUndo = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: countBeforeSecondUndo)
    await receiveTargetReply(
        transport,
        targetID: documentAfterSecondUndo.targetIdentifier,
        messageID: try messageID(documentAfterSecondUndo.message),
        result: nestedDocumentResult
    )
    #expect(session.lastError == nil)
}

@MainActor
@Test
func deleteUndoIsDiscardedWhenDocumentIdentityChanges() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let htmlID = try #require(session.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(2))])
    session.dom.selectNode(htmlID)

    let undoManager = UndoManager()
    let countBeforeDelete = await backend.sentTargetMessages().count
    let deleteTask = Task {
        try await session.deleteSelectedDOMNode(undoManager: undoManager)
    }
    let removeNode = try await waitForTargetMessage(backend, method: "DOM.removeNode", after: countBeforeDelete)
    await receiveTargetReply(
        transport,
        targetID: removeNode.targetIdentifier,
        messageID: try messageID(removeNode.message),
        result: "{}"
    )
    try await deleteTask.value
    #expect(undoManager.canUndo)

    _ = session.dom.replaceDocumentRoot(
        DOMNodePayload(nodeID: .init(1), nodeType: .document, nodeName: "#document"),
        targetID: .pageMain
    )

    let countBeforeUndo = await backend.sentTargetMessages().count
    undoManager.undo()

    #expect(await backend.sentTargetMessages().count == countBeforeUndo)
    #expect(undoManager.canUndo == false)
    #expect(undoManager.canRedo == false)
    #expect(session.lastError == InspectorSessionError("DOM document changed before undo."))
}

@Test
func detachCancelsPumpsAndClearsModelState() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await session.detach()

    #expect(await backend.isDetached())
    #expect(await session.isAttached == false)
    #expect(await session.dom.snapshot().currentPageTargetID == nil)
    #expect(await session.network.snapshot().orderedRequestIDs.isEmpty)
}

@Test
func detachDuringConnectKeepsSessionDetached() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    await transport.receiveRootMessage(
        cssCapablePageTargetCreatedMessage(targetID: "page-main", frameID: "main-frame", isProvisional: false)
    )

    let connectTask = Task {
        try await session.connect(transport: transport)
    }
    _ = try await waitForTargetMessage(backend, method: "Inspector.enable")

    await session.detach()

    await #expect(throws: TransportError.transportClosed) {
        try await connectTask.value
    }
    #expect(await session.isAttached == false)
    #expect(await session.lastError == nil)
    #expect(await backend.isDetached())
}

@Test
func bootstrapFailureClearsSeededModelState() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(20))
    let session = await InspectorSession(
        configuration: .init(
            responseTimeout: .milliseconds(20),
            bootstrapTimeout: .seconds(1)
        )
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#
    )

    await #expect(throws: TransportError.replyTimeout(method: "Inspector.enable", targetID: .pageMain)) {
        try await session.connect(transport: transport)
    }

    #expect(await session.dom.snapshot().currentPageTargetID == nil)
    #expect(await session.network.snapshot().orderedRequestIDs.isEmpty)
    #expect(await session.isAttached == false)
    #expect(await session.lastError != nil)
}

@Test
func performIsRejectedUntilBootstrapAttaches() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    await transport.receiveRootMessage(
        cssCapablePageTargetCreatedMessage(targetID: "page-main", frameID: "main-frame", isProvisional: false)
    )

    let connectTask = Task {
        try await session.connect(transport: transport)
    }
    _ = try await waitForTargetMessage(backend, method: "Inspector.enable")

    await #expect(throws: InspectorSessionError("Inspector session is not attached.")) {
        try await session.perform(.getDocument(targetID: .pageMain))
    }

    try await completeBootstrap(transport: transport, backend: backend)
    try await connectTask.value
    #expect(await session.isAttached)
}

@MainActor
@Test
func attachInspectabilityPreparationRestoresOriginalValue() throws {
    let webView = WKWebView(frame: .zero)
    let initialValue = webView.isInspectable
    webView.isInspectable = false

    let originalValue = InspectorSession.prepareInspectability(for: webView)

    #expect(originalValue == false)
    #expect(webView.isInspectable == true)

    InspectorSession.restoreInspectabilityIfNeeded(on: webView, originalValue: originalValue)

    #expect(webView.isInspectable == false)
    webView.isInspectable = initialValue
}

private func connect(
    _ session: InspectorSession,
    transport: TransportSession,
    backend: FakeTransportBackend
) async throws {
    await transport.receiveRootMessage(
        cssCapablePageTargetCreatedMessage(targetID: "page-main", frameID: "main-frame", isProvisional: false)
    )
    let connectTask = Task {
        try await session.connect(transport: transport)
    }
    do {
        try await completeBootstrap(transport: transport, backend: backend)
    } catch {
        do {
            try await connectTask.value
        } catch {
            throw error
        }
        throw error
    }
    try await connectTask.value
}

private func testTransport(_ backend: FakeTransportBackend) -> TransportSession {
    TransportSession(backend: backend, responseTimeout: nil)
}

private func cssCapablePageTargetCreatedMessage(
    targetID: String,
    frameID: String? = nil,
    isProvisional: Bool
) -> String {
    let framePair = frameID.map { #","frameId":"\#($0)""# } ?? ""
    return #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"\#(targetID)","type":"page"\#(framePair),"domains":["DOM","Runtime","Target","Inspector","Network","CSS"],"isProvisional":\#(isProvisional)}}}"#
}

@discardableResult
private func completeBootstrap(
    transport: TransportSession,
    backend: FakeTransportBackend,
    after initialSentCount: Int = 0,
    documentResult: String = mainDocumentResult
) async throws -> [SentTargetMessage] {
    var sentCount = initialSentCount
    var sentMessages: [SentTargetMessage] = []
    for method in ["Inspector.enable", "Inspector.initialized", "CSS.enable", "Runtime.enable"] {
        let sent = try await waitForTargetMessage(backend, method: method, after: sentCount)
        sentMessages.append(sent)
        sentCount = await backend.sentTargetMessages().count
        await receiveTargetReply(
            transport,
            targetID: sent.targetIdentifier,
            messageID: try messageID(sent.message),
            result: "{}"
        )
    }

    let documentMessage = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: sentCount)
    sentMessages.append(documentMessage)
    sentCount = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: documentMessage.targetIdentifier,
        messageID: try messageID(documentMessage.message),
        result: documentResult
    )

    let networkMessage = try await waitForTargetMessage(backend, method: "Network.enable", after: sentCount)
    sentMessages.append(networkMessage)
    await receiveTargetReply(
        transport,
        targetID: networkMessage.targetIdentifier,
        messageID: try messageID(networkMessage.message),
        result: "{}"
    )
    return sentMessages
}

private func beginPicker(
    session: InspectorSession,
    transport: TransportSession,
    backend: FakeTransportBackend
) async throws {
    let sentCount = await backend.sentTargetMessages().count
    let beginTask = Task {
        try await session.beginElementPicker()
    }
    let enableMessage = try await waitForTargetMessage(backend, method: "DOM.setInspectModeEnabled", after: sentCount)
    await receiveTargetReply(
        transport,
        targetID: enableMessage.targetIdentifier,
        messageID: try messageID(enableMessage.message),
        result: "{}"
    )
    try await beginTask.value
}

private func hydratePageHTMLChildren(
    session: InspectorSession,
    transport: TransportSession,
    backend: FakeTransportBackend
) async throws {
    let htmlID = try await waitForCurrentNode(
        in: session,
        targetID: .pageMain,
        protocolNodeID: .init(2)
    )
    let sentCount = await backend.sentTargetMessages().count
    let requestTask = Task {
        await session.requestChildNodes(for: htmlID)
    }
    let request = try await waitForTargetMessage(backend, method: "DOM.requestChildNodes", after: sentCount)
    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: pageHTMLChildrenSetChildNodesMessage
    )
    await receiveTargetReply(
        transport,
        targetID: request.targetIdentifier,
        messageID: try messageID(request.message),
        result: "{}"
    )
    #expect(await requestTask.value)
}

private let mainDocumentResult = ##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","children":[{"nodeId":2,"nodeType":1,"nodeName":"HTML","localName":"html","childNodeCount":2}]}}"##
private let pageHTMLChildrenSetChildNodesMessage = #"{"method":"DOM.setChildNodes","params":{"parentId":2,"nodes":[{"nodeId":3,"nodeType":1,"nodeName":"HEAD","localName":"head"},{"nodeId":4,"nodeType":1,"nodeName":"BODY","localName":"body","children":[{"nodeId":5,"nodeType":1,"nodeName":"MAIN","localName":"main","attributes":["id","content"]}]}]}}"#
private let nestedDocumentResult = ##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","children":[{"nodeId":2,"nodeType":1,"nodeName":"HTML","localName":"html","children":[{"nodeId":3,"nodeType":1,"nodeName":"BODY","localName":"body","children":[{"nodeId":4,"nodeType":1,"nodeName":"DIV","localName":"div"}]}]}]}}"##
private let manualReloadDocumentResult = ##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","children":[{"nodeId":2,"nodeType":1,"nodeName":"HTML","localName":"html","children":[{"nodeId":3,"nodeType":1,"nodeName":"BODY","localName":"body","children":[{"nodeId":40,"nodeType":1,"nodeName":"MAIN","localName":"main"}]}]}]}}"##
private let staleReloadDocumentResult = ##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","children":[{"nodeId":2,"nodeType":1,"nodeName":"HTML","localName":"html","children":[{"nodeId":3,"nodeType":1,"nodeName":"BODY","localName":"body","children":[{"nodeId":50,"nodeType":1,"nodeName":"SECTION","localName":"section"}]}]}]}}"##
private let oldDocumentWithHeadNodeFourResult = ##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","children":[{"nodeId":2,"nodeType":1,"nodeName":"HTML","localName":"html","children":[{"nodeId":4,"nodeType":1,"nodeName":"HEAD","localName":"head","childNodeCount":1},{"nodeId":5,"nodeType":1,"nodeName":"BODY","localName":"body"}]}]}}"##
private let newDocumentWithBodyNodeFourResult = ##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","children":[{"nodeId":2,"nodeType":1,"nodeName":"HTML","localName":"html","children":[{"nodeId":3,"nodeType":1,"nodeName":"HEAD","localName":"head"},{"nodeId":4,"nodeType":1,"nodeName":"BODY","localName":"body"}]}]}}"##
private let newDocumentWithHeadChildCountResult = ##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","children":[{"nodeId":2,"nodeType":1,"nodeName":"HTML","localName":"html","children":[{"nodeId":3,"nodeType":1,"nodeName":"HEAD","localName":"head","childNodeCount":2},{"nodeId":4,"nodeType":1,"nodeName":"BODY","localName":"body"}]}]}}"##
private let firstLazyFrameDocumentResult = ##"{"root":{"nodeId":101,"nodeType":9,"nodeName":"#document","documentURL":"https://frame.example/ad","baseURL":"https://frame.example/ad","children":[{"nodeId":102,"nodeType":1,"nodeName":"HTML","localName":"html","children":[{"nodeId":103,"nodeType":1,"nodeName":"BODY","localName":"body","children":[{"nodeId":104,"nodeType":1,"nodeName":"CANVAS","localName":"canvas"}]}]}]}}"##
private let secondLazyFrameDocumentResult = ##"{"root":{"nodeId":201,"nodeType":9,"nodeName":"#document","documentURL":"https://frame.example/ad","baseURL":"https://frame.example/ad","children":[{"nodeId":202,"nodeType":1,"nodeName":"HTML","localName":"html","children":[{"nodeId":203,"nodeType":1,"nodeName":"BODY","localName":"body","children":[{"nodeId":204,"nodeType":1,"nodeName":"VIDEO","localName":"video"}]}]}]}}"##

private func targetMessageMethods(_ backend: FakeTransportBackend) async -> [String?] {
    await backend.sentTargetMessages().map { try? messageMethod($0.message) }
}

private func waitForTargetMessage(
    _ backend: FakeTransportBackend,
    method: String,
    after count: Int = 0
) async throws -> SentTargetMessage {
    try await waitUntil(timeoutError: TransportError.replyTimeout(method: method, targetID: nil)) {
        let messages = await backend.sentTargetMessages()
        return messages.dropFirst(count).first { sent in
            (try? messageMethod(sent.message)) == method
        }
    }
}

private func waitForTargetMessage(
    _ backend: FakeTransportBackend,
    method: String,
    ordinal: Int,
    after count: Int = 0
) async throws -> SentTargetMessage {
    try await waitUntil(timeoutError: TransportError.replyTimeout(method: method, targetID: nil)) {
        let matches = await backend.sentTargetMessages()
            .dropFirst(count)
            .filter { sent in
                (try? messageMethod(sent.message)) == method
            }
        guard matches.indices.contains(ordinal) else {
            return nil
        }
        return matches[ordinal]
    }
}

private struct CSSRefreshMessages {
    var matched: SentTargetMessage
    var inline: SentTargetMessage
    var computed: SentTargetMessage
}

private func waitForCSSRefreshMessages(
    _ backend: FakeTransportBackend,
    after count: Int
) async throws -> CSSRefreshMessages {
    async let matched = waitForTargetMessage(backend, method: "CSS.getMatchedStylesForNode", after: count)
    async let inline = waitForTargetMessage(backend, method: "CSS.getInlineStylesForNode", after: count)
    async let computed = waitForTargetMessage(backend, method: "CSS.getComputedStyleForNode", after: count)
    return try await CSSRefreshMessages(matched: matched, inline: inline, computed: computed)
}

private func replyCSSRefresh(
    transport: TransportSession,
    messages: CSSRefreshMessages,
    selector: String,
    styleSheetID: String,
    marginStatus: String = "active",
    marginText: String = "margin: 0;"
) async throws {
    await receiveTargetReply(
        transport,
        targetID: messages.matched.targetIdentifier,
        messageID: try messageID(messages.matched.message),
        result: cssMatchedStylesResult(
            selector: selector,
            styleSheetID: styleSheetID,
            marginStatus: marginStatus,
            marginText: marginText
        )
    )
    await receiveTargetReply(
        transport,
        targetID: messages.inline.targetIdentifier,
        messageID: try messageID(messages.inline.message),
        result: #"{"inlineStyle":{"styleId":{"styleSheetId":"inline","ordinal":0},"cssProperties":[{"name":"box-sizing","value":"border-box","text":"box-sizing: border-box;","status":"active"}]}}"#
    )
    await receiveTargetReply(
        transport,
        targetID: messages.computed.targetIdentifier,
        messageID: try messageID(messages.computed.message),
        result: #"{"computedStyle":[{"name":"display","value":"block"}]}"#
    )
}

private func cssMatchedStylesResult(
    selector: String,
    styleSheetID: String,
    marginStatus: String,
    marginText: String
) -> String {
    """
    {"matchedCSSRules":[{"rule":{"ruleId":{"styleSheetId":"\(styleSheetID)","ordinal":1},"selectorList":{"selectors":[{"text":"\(selector)"}],"text":"\(selector)"},"origin":"author","style":{"styleId":{"styleSheetId":"\(styleSheetID)","ordinal":1},"cssProperties":[{"name":"margin","value":"0","text":"\(jsonEscapedString(marginText))","status":"\(marginStatus)"}]}},"matchingSelectors":[0]}]}
    """
}

private func waitUntil<Value: Sendable>(
    timeout: Duration = .seconds(1),
    timeoutError: any Error = TransportError.replyTimeout(method: "test wait", targetID: nil),
    _ body: @escaping @Sendable () async -> Value?
) async throws -> Value {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let value = await body() {
            return value
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw timeoutError
}

private func waitForCurrentNode(
    in session: InspectorSession,
    targetID: ProtocolTargetIdentifier,
    protocolNodeID: DOMProtocolNodeID
) async throws -> DOMNodeIdentifier {
    try await waitUntil {
        await session.dom.snapshot().currentNodeIDByKey[
            .init(targetID: targetID, nodeID: protocolNodeID)
        ]
    }
}

private func assertProjectionContainsFrameDocument(
    in projection: DOMTreeProjection,
    iframeNodeID: DOMNodeIdentifier,
    frameRootNodeID: DOMNodeIdentifier,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let rowIDs = projection.rows.map(\.nodeID)
    guard let iframeIndex = rowIDs.firstIndex(of: iframeNodeID) else {
        Issue.record("Expected iframe owner in DOM projection", sourceLocation: sourceLocation)
        return
    }
    guard let frameRootIndex = rowIDs.firstIndex(of: frameRootNodeID) else {
        Issue.record("Expected projected frame document in DOM projection", sourceLocation: sourceLocation)
        return
    }
    #expect(frameRootIndex > iframeIndex, sourceLocation: sourceLocation)
    #expect(
        projection.rows[frameRootIndex].depth == projection.rows[iframeIndex].depth + 1,
        sourceLocation: sourceLocation
    )
}

@discardableResult
private func receiveTargetDispatch(
    _ transport: TransportSession,
    targetID: ProtocolTargetIdentifier,
    message: String
) async -> UInt64 {
    await transport.receiveRootMessage(targetDispatchMessage(targetID: targetID, message: message))
}

private func receiveTargetReply(
    _ transport: TransportSession,
    targetID: ProtocolTargetIdentifier,
    messageID: UInt64,
    result: String
) async {
    await receiveTargetDispatch(
        transport,
        targetID: targetID,
        message: #"{"id":\#(messageID),"result":\#(result)}"#
    )
}

private func expectProtocolEventApplied(
    _ sequence: UInt64,
    in session: InspectorSession,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    #expect(await session.waitUntilProtocolEventApplied(sequence), sourceLocation: sourceLocation)
}

private func pendingTargetReplyKeys(_ transport: TransportSession) async -> [TargetReplyKey] {
    await transport.snapshot().pendingTargetReplyKeys
}

private func targetDispatchMessage(
    targetID: ProtocolTargetIdentifier,
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
}

private func messageID(_ message: String) throws -> UInt64 {
    let data = try #require(message.data(using: .utf8))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    if let number = object["id"] as? NSNumber {
        return number.uint64Value
    }
    if let string = object["id"] as? String,
       let id = UInt64(string) {
        return id
    }
    throw TransportError.malformedMessage
}

private func messageMethod(_ message: String) throws -> String? {
    let data = try #require(message.data(using: .utf8))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return object["method"] as? String
}

private func messageParameters(_ message: String) throws -> [String: Any] {
    let data = try #require(message.data(using: .utf8))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(object["params"] as? [String: Any])
}

private func boolParameter(_ name: String, in message: String) throws -> Bool? {
    let data = try #require(message.data(using: .utf8))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return (object["params"] as? [String: Any])?[name] as? Bool
}

private func stringParameter(_ name: String, in message: String) throws -> String? {
    let data = try #require(message.data(using: .utf8))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return (object["params"] as? [String: Any])?[name] as? String
}

private func integerParameter(_ name: String, in message: String) throws -> Int? {
    let data = try #require(message.data(using: .utf8))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let value = (object["params"] as? [String: Any])?[name]
    if let number = value as? NSNumber {
        return number.intValue
    }
    if let int = value as? Int {
        return int
    }
    return nil
}

private extension ProtocolTargetIdentifier {
    static let pageMain = ProtocolTargetIdentifier("page-main")
    static let pageNext = ProtocolTargetIdentifier("page-next")
    static let frameAd = ProtocolTargetIdentifier("frame-ad")
}

private extension InspectorSessionConfiguration {
    static let test = InspectorSessionConfiguration(
        responseTimeout: .seconds(1),
        bootstrapTimeout: .seconds(1)
    )
}

private extension DOMSessionSnapshot {
    var currentPageDocumentID: DOMDocumentIdentifier? {
        guard let currentPageTargetID else {
            return nil
        }
        return targetsByID[currentPageTargetID]?.currentDocumentID
    }
}
