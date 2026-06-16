import Foundation
import ObservationBridge
import Testing
import WebInspectorTestSupport
import WebInspectorTransport
import WebKit
@testable import WebInspectorCore

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
        "Runtime.enable",
        "DOM.getDocument",
        "Network.enable",
        "Console.enable",
    ])
    #expect(await session.hasActiveConnection)
    #expect(await session.attachment.dom.snapshot().currentPageTargetID == ProtocolTarget.ID.pageMain)
    #expect(await session.attachment.dom.snapshot().documentsByID.count == 1)
}

@Test
func connectToleratesUnsupportedConsoleEnableForDefaultPageTarget() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    await transport.receiveRootMessage(
        cssCapablePageTargetCreatedMessage(targetID: "page-main", frameID: "main-frame", isProvisional: false)
    )

    let connectTask = Task {
        try await session.connect(transport: transport)
    }
    var sentCount = 0
    for method in ["Inspector.enable", "Inspector.initialized", "Runtime.enable"] {
        let sent = try await waitForTargetMessage(backend, method: method, after: sentCount)
        sentCount = await backend.sentTargetMessages().count
        await receiveTargetReply(
            transport,
            targetID: sent.targetIdentifier,
            messageID: try messageID(sent.message),
            result: "{}"
        )
    }
    let documentMessage = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: sentCount)
    sentCount = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: documentMessage.targetIdentifier,
        messageID: try messageID(documentMessage.message),
        result: mainDocumentResult
    )
    let networkMessage = try await waitForTargetMessage(backend, method: "Network.enable", after: sentCount)
    sentCount = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: networkMessage.targetIdentifier,
        messageID: try messageID(networkMessage.message),
        result: "{}"
    )
    let consoleMessage = try await waitForTargetMessage(backend, method: "Console.enable", after: sentCount)
    await receiveTargetErrorReply(
        transport,
        targetID: consoleMessage.targetIdentifier,
        messageID: try messageID(consoleMessage.message),
        message: "Unknown command: Console.enable"
    )

    try await connectTask.value
    #expect(await session.hasActiveConnection)
    #expect(await session.attachment.console.snapshot().unsupportedCommandsByTargetID[.pageMain]?.contains("Console.enable") == true)
}

@Test
func connectBootstrapsWebPageTargetWithoutDomainMetadataAsCSSCapable() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"web-page","frameId":"main-frame","isProvisional":false}}}"#
    )

    let connectTask = Task {
        try await session.connect(transport: transport)
    }
    let bootstrapMessages = try await completeBootstrap(transport: transport, backend: backend)
    try await connectTask.value

    let htmlID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    await session.attachment.dom.selectNode(htmlID)
    let stylesID: CSSNodeStyles.ID
    switch await session.attachment.dom.selectedCSSNodeStylesID() {
    case let .success(resolvedID):
        stylesID = resolvedID
    case let .failure(reason):
        Issue.record("Expected CSS node styles ID for web-page target, got \(reason)")
        return
    }

    #expect(bootstrapMessages.compactMap { try? messageMethod($0.message) }.contains("CSS.enable") == false)
    #expect(stylesID.targetID == ProtocolTarget.ID.pageMain)
}

@Test
func domainPumpsApplyNetworkEventsToNetworkSession() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Network.requestWillBeSent","params":{"requestId":"request-1","frameId":"main-frame","request":{"url":"https://example.com/app.js"},"timestamp":1}}"#,
        in: session
    )
    let request = try #require(
        await session.attachment.network.requestSnapshot(for: .init(targetID: .pageMain, requestID: .init("request-1")))
    )

    #expect(request.id.targetID == ProtocolTarget.ID.pageMain)
    #expect(request.request.url == "https://example.com/app.js")
}

@Test
func domainPumpsApplyConsoleEventsToConsoleSession() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Console.messageAdded","params":{"message":{"source":"console-api","level":"warning","text":"hello","type":"log","networkRequestId":"request-1"}}}"#,
        in: session
    )

    let snapshot = await session.attachment.console.snapshot()
    let messageID = try #require(snapshot.orderedMessageIDs.first)
    #expect(snapshot.messagesByID[messageID]?.networkRequestKey == NetworkRequest.ID(targetID: .pageMain, requestID: .init("request-1")))
    #expect(snapshot.warningCount == 1)
}

@Test
func domainPumpsReleaseConsoleRuntimeObjectsOnConsoleClear() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Console.messageAdded","params":{"message":{"source":"console-api","level":"log","text":"hello","type":"log","parameters":[{"type":"object","objectId":"console-object","description":"Object"}]}}}"#,
        in: session
    )

    let objectKey = RuntimeRemoteObject.ID(
        runtimeAgentTargetID: .pageMain,
        objectID: RuntimeRemoteObject.ProtocolID("console-object")
    )
    let runtimeSnapshot = await session.attachment.runtime.snapshot()
    let consoleSnapshot = await session.attachment.console.snapshot()
    let linkedParameter = await MainActor.run {
        guard let runtimeObject = session.attachment.runtime.runtimeAgentState(for: .pageMain)?.remoteObjects.first,
              let parameter = session.attachment.console.messages.first?.parameters.first else {
            return false
        }
        return parameter === runtimeObject
    }
    #expect(runtimeSnapshot.remoteObjectsByID[objectKey]?.objectGroup == .console)
    #expect(consoleSnapshot.orderedMessageIDs.isEmpty == false)
    #expect(linkedParameter)

    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Console.messagesCleared","params":{"reason":"console-api"}}"#,
        in: session
    )

    let clearedRuntimeSnapshot = await session.attachment.runtime.snapshot()
    let clearedConsoleSnapshot = await session.attachment.console.snapshot()
    #expect(clearedRuntimeSnapshot.remoteObjectsByID[objectKey] == nil)
    #expect(clearedRuntimeSnapshot.objectGroupRuntimeAgentTargetsByGroup[.console] == nil)
    #expect(clearedConsoleSnapshot.lastClearReasonByTargetID[.pageMain] == .consoleAPI)
}

@Test
func domainPumpsApplyRootScopedConsoleEventsToMainPageConsoleSession() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Console.messageAdded","params":{"message":{"source":"console-api","level":"error","text":"root hello","type":"log","networkRequestId":"request-root"}}}"#,
        in: session
    )

    let snapshot = await session.attachment.console.snapshot()
    let messageID = try #require(snapshot.orderedMessageIDs.first)
    #expect(snapshot.messagesByID[messageID]?.networkRequestKey == NetworkRequest.ID(targetID: .pageMain, requestID: .init("request-root")))
    #expect(snapshot.errorCount == 1)
}

@Test
func domainPumpsApplyRuntimeContextTeardownToRuntimeAndDOMSessions() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":81,"type":"normal","frameId":"main-frame"}}}"#,
        in: session
    )
    #expect(await session.attachment.runtime.snapshot().executionContextsByKey[contextKey(.pageMain, 81)] != nil)
    #expect(await session.attachment.dom.snapshot().executionContextsByKey[contextKey(.pageMain, 81)] != nil)

    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Runtime.executionContextDestroyed","params":{"executionContextId":81}}"#,
        in: session
    )
    #expect(await session.attachment.runtime.snapshot().executionContextsByKey[contextKey(.pageMain, 81)] == nil)
    #expect(await session.attachment.dom.snapshot().executionContextsByKey[contextKey(.pageMain, 81)] == nil)

    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":82,"type":"normal","frameId":"main-frame"}}}"#,
        in: session
    )
    #expect(await session.attachment.runtime.snapshot().executionContextsByKey[contextKey(.pageMain, 82)] != nil)
    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Runtime.executionContextsCleared","params":{}}"#,
        in: session
    )
    #expect(await session.attachment.runtime.snapshot().executionContextsByKey[contextKey(.pageMain, 82)] == nil)
    #expect(await session.attachment.dom.snapshot().executionContextsByKey[contextKey(.pageMain, 82)] == nil)
}

@Test
func runtimeContextDispatchedOnPageResolvesToFrameTargetByFrameID() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":["Runtime"],"isProvisional":false}}}"#,
        in: session
    )
    #expect(await session.attachment.dom.snapshot().targetsByID[.frameAd] != nil)
    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":77,"frameId":"ad-frame"}}}"#,
        in: session
    )

    let runtimeSnapshot = await session.attachment.runtime.snapshot()
    let domSnapshot = await session.attachment.dom.snapshot()
    #expect(runtimeSnapshot.executionContextsByKey[contextKey(.pageMain, 77)]?.targetID == .frameAd)
    #expect(runtimeSnapshot.normalContextKeyByTargetID[.frameAd] == contextKey(.pageMain, 77))
    #expect(domSnapshot.executionContextsByKey[contextKey(.pageMain, 77)]?.targetID == .frameAd)
}

@Test
func rootRuntimeClearRemovesFrameContextOwnedByPageRuntimeAgent() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":["Runtime"],"isProvisional":false}}}"#,
        in: session
    )
    #expect(await session.attachment.dom.snapshot().targetsByID[.frameAd] != nil)
    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":78,"frameId":"ad-frame"}}}"#,
        in: session
    )

    let runtimeContext = await session.attachment.runtime.snapshot().executionContextsByKey[contextKey(.pageMain, 78)]
    let domContext = await session.attachment.dom.snapshot().executionContextsByKey[contextKey(.pageMain, 78)]
    #expect(runtimeContext?.targetID == .frameAd)
    #expect(runtimeContext?.runtimeAgentTargetID == .pageMain)
    #expect(domContext?.targetID == .frameAd)
    #expect(domContext?.runtimeAgentTargetID == .pageMain)

    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Runtime.executionContextsCleared","params":{}}"#,
        in: session
    )
    #expect(await session.attachment.runtime.snapshot().executionContextsByKey[contextKey(.pageMain, 78)] == nil)
    #expect(await session.attachment.dom.snapshot().executionContextsByKey[contextKey(.pageMain, 78)] == nil)
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
        try await session.attachment.network.perform(
            .getResponseBody(
                requestKey: .init(targetID: .frameAd, requestID: .init("request-1")),
                backendResourceIdentifier: nil
            )
        )
    }
    let sent = try await waitForTargetMessage(backend, method: "Network.getResponseBody", after: sentCount)

    #expect(sent.targetIdentifier == ProtocolTarget.ID.frameAd)
    #expect(String(data: Data(sent.message.utf8), encoding: .utf8)?.contains(#""requestId":"request-1""#) == true)

    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: #"{"body":"hello","base64Encoded":false}"#
    )
    let result = try await performTask.value

    #expect(result.method == "Network.getResponseBody")
    #expect(result.targetID == ProtocolTarget.ID.frameAd)
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
    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Network.responseReceived","params":{"requestId":"request-2","timestamp":2,"type":"XHR","response":{"url":"https://example.com/api.json","status":200,"mimeType":"application/json","headers":{"content-type":"application/json"}}}}"#,
        in: session
    )
    let request = try #require(
        await session.attachment.network.request(for: .init(targetID: .pageMain, requestID: .init("request-2")))
    )
    let responseBody = await request.responseBody
    let body = try #require(responseBody)
    #expect(await body.phase == .available)

    let sentCountBeforeFinish = await backend.sentTargetMessages().count
    await session.attachment.network.fetchResponseBody(for: request.id)
    #expect(await backend.sentTargetMessages().count == sentCountBeforeFinish)

    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Network.loadingFinished","params":{"requestId":"request-2","timestamp":3}}"#,
        in: session
    )

    let sentCount = await backend.sentTargetMessages().count
    let fetchTask = Task {
        await session.attachment.network.fetchResponseBody(for: request.id)
    }
    let sent = try await waitForTargetMessage(backend, method: "Network.getResponseBody", after: sentCount)
    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: #"{"body":"{\"ok\":true}","base64Encoded":false}"#
    )
    await fetchTask.value

    #expect(await body.phase == .loaded)
    #expect(await body.textRepresentation == #"{"ok":true}"#)
    let preparation = try #require(await body.prepareTextRepresentation())
    await preparation.wait()
    #expect(await body.textRepresentation?.contains("\n") == true)
    #expect(await body.textRepresentation?.contains(#""ok""#) == true)
}

@Test
func networkResponseBodyFetchErrorDoesNotRetry() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Network.requestWillBeSent","params":{"requestId":"request-error","frameId":"main-frame","request":{"url":"https://example.com/api.json"},"timestamp":1}}"#
    )
    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Network.responseReceived","params":{"requestId":"request-error","timestamp":2,"type":"XHR","response":{"url":"https://example.com/api.json","status":200,"mimeType":"application/json","headers":{"content-type":"application/json"}}}}"#
    )
    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Network.loadingFinished","params":{"requestId":"request-error","timestamp":3}}"#,
        in: session
    )
    let request = try #require(await session.attachment.network.request(for: .init(targetID: .pageMain, requestID: .init("request-error"))))
    let responseBody = await request.responseBody
    let body = try #require(responseBody)
    #expect(await body.phase == .available)

    let sentCount = await backend.sentTargetMessages().count
    let fetchTask = Task {
        await session.attachment.network.fetchResponseBody(for: request.id)
    }
    let sent = try await waitForTargetMessage(backend, method: "Network.getResponseBody", after: sentCount)
    await receiveTargetErrorReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        message: "Not yet implemented"
    )
    await fetchTask.value

    guard case .failed = await body.phase else {
        Issue.record("Expected response body fetch to fail")
        return
    }

    let sentCountAfterFailure = await backend.sentTargetMessages().count
    await session.attachment.network.fetchResponseBody(for: request.id)
    #expect(await backend.sentTargetMessages().count == sentCountAfterFailure)
}

@Test
@MainActor
func selectedElementStyleRefreshLoadsCSSSession() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))
    session.attachment.dom.selectNode(bodyID)

    let sentCount = await backend.sentTargetMessages().count
    let refreshTask = Task {
        await session.attachment.dom.refreshStylesForSelectedNode()
    }
    let messages = try await waitForCSSRefreshMessages(backend, after: sentCount)
    try await replyCSSRefresh(
        transport: transport,
        messages: messages,
        selector: "body",
        styleSheetID: "sheet-body"
    )
    await refreshTask.value

    let styles = try #require(session.attachment.dom.elementStyles.selectedNodeStyles)
    #expect(session.attachment.dom.elementStyles.selectedPhase == .loaded)
    #expect(styles.id.nodeID == bodyID)
    #expect(styles.sections.map(\.title) == ["element.style", "body"])
    #expect(styles.sections[1].style.cssProperties.first?.name == "margin")
    #expect(styles.computedProperties == [CSSComputedStyleProperty(name: "display", value: "block")])
}

@Test
@MainActor
func selectedNodeStylesTracksNewSelectionWhileElementStylesLoad() async throws {
    let targetID = ProtocolTarget.ID("page")
    let css = CSSSession()
    let dom = DOMSession(elementStyles: css)
    dom.applyTargetCreated(
        .init(id: targetID, kind: .page, capabilities: .pageDefault),
        makeCurrentMainPage: true
    )
    _ = dom.replaceDocumentRoot(
        WebInspectorCore.DOMNode.Payload(
            nodeID: .init(1),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                WebInspectorCore.DOMNode.Payload(nodeID: .init(2), nodeType: .element, nodeName: "BODY", localName: "body"),
                WebInspectorCore.DOMNode.Payload(nodeID: .init(3), nodeType: .element, nodeName: "INPUT", localName: "input"),
            ])
        ),
        targetID: targetID
    )
    let snapshot = dom.snapshot()
    let bodyID = try #require(snapshot.currentNodeIDByKey[.init(targetID: targetID, nodeID: .init(2))])
    let inputID = try #require(snapshot.currentNodeIDByKey[.init(targetID: targetID, nodeID: .init(3))])
    let session = InspectorSession(dom: dom)

    dom.selectNode(bodyID)
    let bodyStylesID = try #require(dom.selectedCSSNodeStylesID().successValue)
    let bodyStyles = try applySingleRuleStyles(
        to: css,
        id: bodyStylesID,
        selector: "body",
        marginValue: "0",
        marginText: "margin: 0;"
    )
    #expect(session.attachment.dom.selectedNodeStyles === bodyStyles)

    dom.selectNode(inputID)
    let inputStylesID = try #require(dom.selectedCSSNodeStylesID().successValue)
    let pendingInputStyles = try #require(session.attachment.dom.selectedNodeStyles)
    #expect(pendingInputStyles.id == inputStylesID)
    #expect(pendingInputStyles.phase == .needsRefresh)
    let inputToken = css.beginRefresh(id: inputStylesID)
    let loadingInputStyles = try #require(session.attachment.dom.selectedNodeStyles)
    #expect(loadingInputStyles.id == inputStylesID)
    #expect(loadingInputStyles.phase == .loading)
    #expect(loadingInputStyles.sections.isEmpty)

    let inputStyles = try applySingleRuleStyles(
        to: css,
        id: inputStylesID,
        token: inputToken,
        selector: "input",
        marginValue: "8px",
        marginText: "margin: 8px;"
    )
    #expect(session.attachment.dom.selectedNodeStyles === inputStyles)

    dom.selectNode(nil)
    #expect(session.attachment.dom.selectedNodeStyles == nil)
}

@Test
@MainActor
func selectedElementStyleHydrationLoadsCSSSessionWhenActive() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))
    session.attachment.dom.selectNode(bodyID)

    let sentCount = await backend.sentTargetMessages().count
    session.attachment.dom.setSelectedNodeStyleHydrationActive(true)
    let messages = try await waitForCSSRefreshMessages(backend, after: sentCount)
    try await replyCSSRefresh(
        transport: transport,
        messages: messages,
        selector: "body",
        styleSheetID: "sheet-body"
    )

    await session.attachment.dom.waitUntilSelectedStyleRefreshIdle()
    #expect(session.attachment.dom.elementStyles.selectedPhase == .loaded)
    let styles = try #require(session.attachment.dom.elementStyles.selectedNodeStyles)
    #expect(styles.id.nodeID == bodyID)
    #expect(styles.sections.map(\.title) == ["element.style", "body"])
}

@Test
@MainActor
func selectedElementStyleHydrationCancellationDoesNotPublishFailure() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let htmlID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))
    session.attachment.dom.setSelectedNodeStyleHydrationActive(true)
    session.attachment.dom.selectNode(bodyID)

    let firstSentCount = await backend.sentTargetMessages().count
    _ = try await waitForCSSRefreshMessages(backend, after: firstSentCount)

    let secondSentCount = await backend.sentTargetMessages().count
    session.attachment.dom.selectNode(htmlID)
    let secondMessages = try await waitForCSSRefreshMessages(backend, after: secondSentCount)
    try await replyCSSRefresh(
        transport: transport,
        messages: secondMessages,
        selector: "html",
        styleSheetID: "sheet-html"
    )

    await session.attachment.dom.waitUntilSelectedStyleRefreshIdle()
    #expect(session.attachment.dom.elementStyles.selectedNodeStyles?.id.nodeID == htmlID)
    #expect(session.attachment.dom.elementStyles.selectedPhase == .loaded)
    #expect(session.lastError == nil)
}

@Test
@MainActor
func selectedElementStyleHydrationCancellationResetsLoadingForFutureRefresh() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))
    session.attachment.dom.selectNode(bodyID)

    let firstSentCount = await backend.sentTargetMessages().count
    session.attachment.dom.setSelectedNodeStyleHydrationActive(true)
    _ = try await waitForCSSRefreshMessages(backend, after: firstSentCount)
    #expect(session.attachment.dom.elementStyles.selectedPhase == .loading)

    session.attachment.dom.setSelectedNodeStyleHydrationActive(false)
    #expect(session.attachment.dom.elementStyles.selectedPhase == .needsRefresh)

    let secondSentCount = await backend.sentTargetMessages().count
    session.attachment.dom.setSelectedNodeStyleHydrationActive(true)
    let secondMessages = try await waitForCSSRefreshMessages(backend, after: secondSentCount)
    try await replyCSSRefresh(
        transport: transport,
        messages: secondMessages,
        selector: "body",
        styleSheetID: "sheet-body"
    )

    await session.attachment.dom.waitUntilSelectedStyleRefreshIdle()
    #expect(session.attachment.dom.elementStyles.selectedPhase == .loaded)
    #expect(session.lastError == nil)
}

@Test
@MainActor
func selectedElementStyleHydrationSelectionChangeStartsReplacementRefresh() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let htmlID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))
    session.attachment.dom.setSelectedNodeStyleHydrationActive(true)
    let firstSentCount = await backend.sentTargetMessages().count
    session.attachment.dom.selectNode(bodyID)

    let firstMessages = try await waitForCSSRefreshMessages(backend, after: firstSentCount)
    #expect(try messageParameters(firstMessages.matched.message)["nodeId"] as? Int == 4)
    #expect(session.attachment.dom.elementStyles.selectedPhase == .loading)

    let secondSentCount = await backend.sentTargetMessages().count
    session.attachment.dom.selectNode(htmlID)
    let secondMessages = try await waitForCSSRefreshMessages(backend, after: secondSentCount)
    #expect(try messageParameters(secondMessages.matched.message)["nodeId"] as? Int == 2)
    #expect(session.attachment.dom.elementStyles.selectedNodeStyles?.id.nodeID == htmlID)
    #expect(session.attachment.dom.elementStyles.selectedPhase == .loading)
    #expect(session.lastError == nil)
}

@Test
@MainActor
func selectedElementStyleHydrationClearsStylesAfterSelectionDisappears() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))
    session.attachment.dom.selectNode(bodyID)

    let sentCount = await backend.sentTargetMessages().count
    session.attachment.dom.setSelectedNodeStyleHydrationActive(true)
    let messages = try await waitForCSSRefreshMessages(backend, after: sentCount)
    try await replyCSSRefresh(
        transport: transport,
        messages: messages,
        selector: "body",
        styleSheetID: "sheet-body"
    )
    await session.attachment.dom.waitUntilSelectedStyleRefreshIdle()

    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.childNodeRemoved","params":{"nodeId":4}}"#,
        in: session
    )

    #expect(session.attachment.dom.selectedNodeID == nil)
    #expect(session.attachment.dom.elementStyles.selectedNodeStyles == nil)
}

@Test
@MainActor
func selectedElementStyleHydrationRefreshesAfterCSSEvents() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let bodyID = try await hydrateSelectedBodyStyles(
        session: session,
        transport: transport,
        backend: backend
    )

    let sheetChangedCount = await backend.sentTargetMessages().count
    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"CSS.styleSheetChanged","params":{"styleSheetId":"sheet-body"}}"#
    )
    let sheetChangedMessages = try await waitForCSSRefreshMessages(backend, after: sheetChangedCount)
    #expect(try messageParameters(sheetChangedMessages.matched.message)["nodeId"] as? Int == 4)
    try await replyCSSRefresh(
        transport: transport,
        messages: sheetChangedMessages,
        selector: "body",
        styleSheetID: "sheet-body-refresh"
    )
    await session.attachment.dom.waitUntilSelectedStyleRefreshIdle()
    #expect(session.attachment.dom.elementStyles.selectedNodeStyles?.id.nodeID == bodyID)
    #expect(session.attachment.dom.elementStyles.selectedPhase == .loaded)

    let layoutChangedCount = await backend.sentTargetMessages().count
    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"CSS.nodeLayoutFlagsChanged","params":{"nodeId":4}}"#
    )
    let layoutChangedMessages = try await waitForCSSRefreshMessages(backend, after: layoutChangedCount)
    #expect(try messageParameters(layoutChangedMessages.matched.message)["nodeId"] as? Int == 4)
    try await replyCSSRefresh(
        transport: transport,
        messages: layoutChangedMessages,
        selector: "body",
        styleSheetID: "sheet-body-layout"
    )
    await session.attachment.dom.waitUntilSelectedStyleRefreshIdle()
    #expect(session.attachment.dom.elementStyles.selectedNodeStyles?.id.nodeID == bodyID)
    #expect(session.attachment.dom.elementStyles.selectedPhase == .loaded)
    #expect(session.lastError == nil)
}

@Test
@MainActor
func selectedElementStyleHydrationCancelsAfterDocumentUpdateInvalidatesRoot() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    _ = try await hydrateSelectedBodyStyles(
        session: session,
        transport: transport,
        backend: backend
    )

    let sentCount = await backend.sentTargetMessages().count
    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.documentUpdated","params":{}}"#,
        in: session
    )

    #expect(session.attachment.dom.currentPageRootNode == nil)
    #expect(session.attachment.dom.elementStyles.selectedPhase == .unavailable(.noSelection))
    #expect(await backend.sentTargetMessages().count == sentCount)
}

@Test
@MainActor
func selectedElementStyleHydrationClearsAfterSelectedTargetDestroyed() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    _ = try await hydrateSelectedBodyStyles(
        session: session,
        transport: transport,
        backend: backend
    )

    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetDestroyed","params":{"targetId":"page-main"}}"#,
        in: session
    )

    #expect(session.attachment.dom.selectedNodeID == nil)
    #expect(session.attachment.dom.elementStyles.selectedPhase == .unavailable(.noSelection))
    #expect(session.lastError == nil)
}

@Test
@MainActor
func selectedElementStyleHydrationMarksStaleWhenTransportTargetDisappearsBeforeDOMEvent() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let css = CSSSession()
    let dom = DOMSession(elementStyles: css)
    var recordedError: InspectorSession.Error?
    let channel = ProtocolCommandChannel(
        transport: transport,
        isCurrent: { true },
        isAttached: { true },
        appliedSequence: { 0 },
        shouldEnableCompatibilityCSS: { _ in false },
        markTargetDomainEnabled: { _, _ in }
    )
    dom.bindProtocolChannel(channel) { error in
        recordedError = error
    }

    dom.applyTargetCreated(
        .init(
            id: .pageMain,
            kind: .page,
            frameID: .init("main-frame"),
            capabilities: .pageDefault
        ),
        makeCurrentMainPage: true
    )
    _ = dom.replaceDocumentRoot(
        WebInspectorCore.DOMNode.Payload(
            nodeID: .init(1),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                WebInspectorCore.DOMNode.Payload(
                    nodeID: .init(2),
                    nodeType: .element,
                    nodeName: "HTML",
                    localName: "html",
                    regularChildren: .loaded([
                        WebInspectorCore.DOMNode.Payload(
                            nodeID: .init(4),
                            nodeType: .element,
                            nodeName: "BODY",
                            localName: "body"
                        ),
                    ])
                ),
            ])
        ),
        targetID: .pageMain
    )
    let bodyID = try #require(dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(4))])
    dom.selectNode(bodyID)

    let sentCount = await backend.sentTargetMessages().count
    dom.setSelectedNodeStyleHydrationActive(true)
    await dom.waitUntilSelectedStyleRefreshIdle()

    #expect(await backend.sentTargetMessages().count == sentCount)
    #expect(css.selectedPhase == .unavailable(.staleNode(bodyID)))
    #expect(css.selectedNodeStyles == nil)
    #expect(recordedError == nil)
}

@Test
func selectedElementStyleRefreshEnablesCSSAgentOnlyAfterBackendRequiresIt() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))
    await session.attachment.dom.selectNode(bodyID)

    let sentCount = await backend.sentTargetMessages().count
    let refreshTask = Task {
        await session.attachment.dom.refreshStylesForSelectedNode()
    }
    let firstMessages = try await waitForCSSRefreshMessages(backend, after: sentCount)
    await receiveTargetErrorReply(
        transport,
        targetID: firstMessages.matched.targetIdentifier,
        messageID: try messageID(firstMessages.matched.message),
        message: "CSS agent is not enabled"
    )
    await receiveTargetErrorReply(
        transport,
        targetID: firstMessages.inline.targetIdentifier,
        messageID: try messageID(firstMessages.inline.message),
        message: "CSS agent is not enabled"
    )
    await receiveTargetErrorReply(
        transport,
        targetID: firstMessages.computed.targetIdentifier,
        messageID: try messageID(firstMessages.computed.message),
        message: "CSS agent is not enabled"
    )

    let cssEnable = try await waitForTargetMessage(backend, method: "CSS.enable", after: sentCount)
    let retrySentCount = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: cssEnable.targetIdentifier,
        messageID: try messageID(cssEnable.message),
        result: "{}"
    )
    let retryMessages = try await waitForCSSRefreshMessages(backend, after: retrySentCount)
    try await replyCSSRefresh(
        transport: transport,
        messages: retryMessages,
        selector: "body",
        styleSheetID: "sheet-body"
    )
    await refreshTask.value

    let styles = try #require(await session.attachment.dom.elementStyles.selectedNodeStyles)
    #expect(await session.attachment.dom.elementStyles.selectedPhase == .loaded)
    #expect(await styles.id.nodeID == bodyID)
}

@Test
@MainActor
func selectedElementStyleRefreshDropsResultsWhenSelectionChanges() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let htmlID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))
    session.attachment.dom.selectNode(bodyID)

    let firstSentCount = await backend.sentTargetMessages().count
    let firstRefresh = Task {
        await session.attachment.dom.refreshStylesForSelectedNode()
    }
    let firstMessages = try await waitForCSSRefreshMessages(backend, after: firstSentCount)

    session.attachment.dom.selectNode(htmlID)
    let secondSentCount = await backend.sentTargetMessages().count
    let secondRefresh = Task {
        await session.attachment.dom.refreshStylesForSelectedNode()
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

    let styles = try #require(session.attachment.dom.elementStyles.selectedNodeStyles)
    #expect(styles.id.nodeID == htmlID)
    #expect(styles.sections.map(\.title) == ["element.style", "html"])
}

@Test
@MainActor
func cssPropertyToggleSendsSetStyleTextAndRefreshesStyles() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))
    session.attachment.dom.selectNode(bodyID)

    let refreshCount = await backend.sentTargetMessages().count
    let refreshTask = Task {
        await session.attachment.dom.refreshStylesForSelectedNode()
    }
    let initialRefreshMessages = try await waitForCSSRefreshMessages(backend, after: refreshCount)
    try await replyCSSRefresh(
        transport: transport,
        messages: initialRefreshMessages,
        selector: "body",
        styleSheetID: "sheet-body"
    )
    await refreshTask.value

    let propertyID = CSSProperty.ID(
        styleID: CSSStyle.ID(styleSheetID: .init("sheet-body"), ordinal: 1),
        propertyIndex: 0
    )
    let toggleSentCount = await backend.sentTargetMessages().count
    session.attachment.dom.requestSetCSSProperty(propertyID, enabled: false)
    let setStyleText = try await waitForTargetMessage(backend, method: "CSS.setStyleText", after: toggleSentCount)
    #expect(setStyleText.targetIdentifier == ProtocolTarget.ID.pageMain)
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
    await session.attachment.dom.waitUntilSelectedStyleRefreshIdle()

    let styles = try #require(session.attachment.dom.elementStyles.selectedNodeStyles)
    #expect(session.attachment.dom.elementStyles.selectedPhase == .loaded)
    #expect(styles.sections[1].style.cssProperties[0].isEnabled == false)
}

@Test
func cssAndDOMStyleInvalidationsMarkSelectedNodeStylesNeedsRefresh() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))
    await session.attachment.dom.selectNode(bodyID)
    await transport.receiveRootMessage(
        #"{"method":"CSS.styleSheetAdded","params":{"header":{"styleSheetId":"sheet-body"}}}"#
    )

    let sentCount = await backend.sentTargetMessages().count
    let refreshTask = Task {
        await session.attachment.dom.refreshStylesForSelectedNode()
    }
    let messages = try await waitForCSSRefreshMessages(backend, after: sentCount)
    try await replyCSSRefresh(transport: transport, messages: messages, selector: "body", styleSheetID: "sheet-body")
    await refreshTask.value
    #expect(await session.attachment.dom.elementStyles.selectedPhase == .loaded)

    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"CSS.styleSheetChanged","params":{"styleSheetId":"sheet-body"}}"#,
        in: session
    )
    #expect(await session.attachment.dom.elementStyles.selectedPhase == .needsRefresh)

    let refreshAgainCount = await backend.sentTargetMessages().count
    let refreshAgain = Task {
        await session.attachment.dom.refreshStylesForSelectedNode()
    }
    let messagesAgain = try await waitForCSSRefreshMessages(backend, after: refreshAgainCount)
    try await replyCSSRefresh(transport: transport, messages: messagesAgain, selector: "body", styleSheetID: "sheet-body")
    await refreshAgain.value
    #expect(await session.attachment.dom.elementStyles.selectedPhase == .loaded)

    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.attributeModified","params":{"nodeId":4,"name":"class","value":"featured"}}"#,
        in: session
    )
    #expect(await session.attachment.dom.elementStyles.selectedPhase == .needsRefresh)

    let refreshAfterAttributeCount = await backend.sentTargetMessages().count
    let refreshAfterAttribute = Task {
        await session.attachment.dom.refreshStylesForSelectedNode()
    }
    let messagesAfterAttribute = try await waitForCSSRefreshMessages(backend, after: refreshAfterAttributeCount)
    try await replyCSSRefresh(transport: transport, messages: messagesAfterAttribute, selector: "body", styleSheetID: "sheet-body")
    await refreshAfterAttribute.value
    #expect(await session.attachment.dom.elementStyles.selectedPhase == .loaded)

    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.attributeModified","params":{"nodeId":5,"name":"class","value":"child-only"}}"#,
        in: session
    )
    #expect(await session.attachment.dom.elementStyles.selectedPhase == .needsRefresh)

    let refreshAfterRelatedAttributeCount = await backend.sentTargetMessages().count
    let refreshAfterRelatedAttribute = Task {
        await session.attachment.dom.refreshStylesForSelectedNode()
    }
    let messagesAfterRelatedAttribute = try await waitForCSSRefreshMessages(
        backend,
        after: refreshAfterRelatedAttributeCount
    )
    try await replyCSSRefresh(
        transport: transport,
        messages: messagesAfterRelatedAttribute,
        selector: "body",
        styleSheetID: "sheet-body"
    )
    await refreshAfterRelatedAttribute.value
    #expect(await session.attachment.dom.elementStyles.selectedPhase == .loaded)

    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.childNodeInserted","params":{"parentNodeId":4,"previousNodeId":5,"node":{"nodeId":6,"nodeType":1,"nodeName":"ASIDE","localName":"aside"}}}"#,
        in: session
    )
    #expect(await session.attachment.dom.elementStyles.selectedPhase == .needsRefresh)

    let refreshAfterChildInsertCount = await backend.sentTargetMessages().count
    let refreshAfterChildInsert = Task {
        await session.attachment.dom.refreshStylesForSelectedNode()
    }
    let messagesAfterChildInsert = try await waitForCSSRefreshMessages(backend, after: refreshAfterChildInsertCount)
    try await replyCSSRefresh(
        transport: transport,
        messages: messagesAfterChildInsert,
        selector: "body",
        styleSheetID: "sheet-body"
    )
    await refreshAfterChildInsert.value
    #expect(await session.attachment.dom.elementStyles.selectedPhase == .loaded)

    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.childNodeCountUpdated","params":{"nodeId":4,"childNodeCount":3}}"#,
        in: session
    )
    #expect(await session.attachment.dom.elementStyles.selectedPhase == .needsRefresh)
}

@Test
func documentUpdatedClearsSelectedCSSNodeStylesForInvalidatedDocument() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))
    await session.attachment.dom.selectNode(bodyID)

    let sentCount = await backend.sentTargetMessages().count
    let refreshTask = Task {
        await session.attachment.dom.refreshStylesForSelectedNode()
    }
    let messages = try await waitForCSSRefreshMessages(backend, after: sentCount)
    try await replyCSSRefresh(transport: transport, messages: messages, selector: "body", styleSheetID: "sheet-body")
    await refreshTask.value
    #expect(await session.attachment.dom.elementStyles.selectedNodeStyles != nil)

    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.documentUpdated","params":{}}"#,
        in: session
    )
    #expect(await session.attachment.dom.elementStyles.selectedNodeStyles == nil)
}

@Test
func explicitDOMReloadClearsSelectedCSSNodeStylesForReplacedDocument() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))
    await session.attachment.dom.selectNode(bodyID)

    let sentCount = await backend.sentTargetMessages().count
    let refreshTask = Task {
        await session.attachment.dom.refreshStylesForSelectedNode()
    }
    let messages = try await waitForCSSRefreshMessages(backend, after: sentCount)
    try await replyCSSRefresh(transport: transport, messages: messages, selector: "body", styleSheetID: "sheet-body")
    await refreshTask.value
    #expect(await session.attachment.dom.elementStyles.selectedNodeStyles != nil)

    let reloadSentCount = await backend.sentTargetMessages().count
    let reloadTask = Task {
        try await session.attachment.dom.reloadDocument()
    }
    let reload = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: reloadSentCount)
    await receiveTargetReply(
        transport,
        targetID: reload.targetIdentifier,
        messageID: try messageID(reload.message),
        result: manualReloadDocumentResult
    )
    try await reloadTask.value

    #expect(await session.attachment.dom.elementStyles.selectedNodeStyles == nil)
}

@Test
func domMutationRemovingSelectedNodeClearsSelectedCSSNodeStyles() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))
    await session.attachment.dom.selectNode(bodyID)

    let sentCount = await backend.sentTargetMessages().count
    let refreshTask = Task {
        await session.attachment.dom.refreshStylesForSelectedNode()
    }
    let messages = try await waitForCSSRefreshMessages(backend, after: sentCount)
    try await replyCSSRefresh(transport: transport, messages: messages, selector: "body", styleSheetID: "sheet-body")
    await refreshTask.value
    #expect(await session.attachment.dom.elementStyles.selectedPhase == .loaded)

    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.childNodeRemoved","params":{"nodeId":4}}"#,
        in: session
    )

    #expect(await session.attachment.dom.elementStyles.selectedNodeStyles == nil)
}

@Test
func localDOMDeleteClearsSelectedCSSNodeStylesWithoutBackendMutationEvent() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))
    await session.attachment.dom.selectNode(bodyID)

    let sentCount = await backend.sentTargetMessages().count
    let refreshTask = Task {
        await session.attachment.dom.refreshStylesForSelectedNode()
    }
    let messages = try await waitForCSSRefreshMessages(backend, after: sentCount)
    try await replyCSSRefresh(transport: transport, messages: messages, selector: "body", styleSheetID: "sheet-body")
    await refreshTask.value
    #expect(await session.attachment.dom.elementStyles.selectedPhase == .loaded)

    let countBeforeDelete = await backend.sentTargetMessages().count
    let deleteTask = Task {
        try await session.attachment.dom.deleteNode(bodyID, undoManager: nil)
    }
    let removeNode = try await waitForTargetMessage(backend, method: "DOM.removeNode", after: countBeforeDelete)
    await receiveTargetReply(
        transport,
        targetID: removeNode.targetIdentifier,
        messageID: try messageID(removeNode.message),
        result: "{}"
    )
    try await deleteTask.value

    #expect(await session.attachment.dom.selectedNodeID == nil)
    #expect(await session.attachment.dom.elementStyles.selectedNodeStyles == nil)
}

@Test
func frameDocumentRefreshUpdatesOnlyFrameDocument() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let pageDocumentID = try #require(await session.attachment.dom.snapshot().currentPageDocumentID)

    let sentCount = await backend.sentTargetMessages().count
    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":["DOM"],"isProvisional":false}}}"#,
        in: session
    )

    let sent = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: sentCount)
    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: ##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","children":[{"nodeId":2,"nodeType":1,"nodeName":"HTML","localName":"html"}]}}"##
    )
    await session.attachment.dom.waitUntilDocumentRequestsIdle(targetID: sent.targetIdentifier)

    let snapshot = await session.attachment.dom.snapshot()
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
    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":[],"isProvisional":false}}}"#,
        in: session
    )
    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .frameAd,
        message: #"{"method":"DOM.documentUpdated","params":{}}"#,
        in: session
    )

    #expect(await backend.sentTargetMessages().count == sentCount)
    #expect(await session.attachment.dom.snapshot().targetsByID[.frameAd]?.currentDocumentID == nil)
}

@Test
func frameTargetWithoutAdvertisedDomainsUsesWebKitFrameDefaultAndDoesNotHydrateOnCreation() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let sentCount = await backend.sentTargetMessages().count
    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#,
        in: session
    )

    #expect(await backend.sentTargetMessages().count == sentCount)
    #expect(await session.attachment.dom.snapshot().targetsByID[.frameAd]?.currentDocumentID == nil)
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
    #expect(sent.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: firstLazyFrameDocumentResult
    )

    #expect(await session.attachment.dom.snapshot().targetsByID[.frameAd]?.currentDocumentID != nil)
}

@Test
func frameTargetWithAdvertisedCSSCapabilityHydratesDOMWithoutCSSEnableOnCreation() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let frameTargetID = ProtocolTarget.ID("frame-css")
    let sentCount = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-css","type":"frame","frameId":"css-frame","parentFrameId":"main-frame","domains":["DOM","CSS"],"isProvisional":false}}}"#
    )

    let documentRequest = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: sentCount)
    #expect(documentRequest.targetIdentifier == frameTargetID)
    await receiveTargetReply(
        transport,
        targetID: documentRequest.targetIdentifier,
        messageID: try messageID(documentRequest.message),
        result: firstLazyFrameDocumentResult
    )
    let messages = await backend.sentTargetMessages().dropFirst(sentCount)
    #expect(messages.compactMap { try? messageMethod($0.message) }.contains("CSS.enable") == false)
}

@Test
func cssOnlyFrameTargetDoesNotSendCSSEnableOnCreation() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let sentCount = await backend.sentTargetMessages().count
    let targetCreatedSequence = await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-css-race","type":"frame","frameId":"css-frame-race","parentFrameId":"main-frame","domains":["CSS"],"isProvisional":false}}}"#
    )
    await expectProtocolEventApplied(targetCreatedSequence, in: session)

    #expect(await backend.sentTargetMessages().count == sentCount)
    #expect(await session.lastError == nil)
}

@Test
func frameTargetWithAdvertisedRuntimeAndConsoleEnablesRuntimeBeforeConsole() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let sentCount = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":["Runtime","Console"],"isProvisional":false}}}"#
    )

    let runtimeEnable = try await waitForTargetMessage(backend, method: "Runtime.enable", after: sentCount)
    #expect(runtimeEnable.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetReply(
        transport,
        targetID: runtimeEnable.targetIdentifier,
        messageID: try messageID(runtimeEnable.message),
        result: "{}"
    )

    let consoleEnable = try await waitForTargetMessage(backend, method: "Console.enable", after: sentCount)
    #expect(consoleEnable.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetReply(
        transport,
        targetID: consoleEnable.targetIdentifier,
        messageID: try messageID(consoleEnable.message),
        result: "{}"
    )
}

@Test
func frameTargetWithUnsupportedRuntimeStillEnablesConsole() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let sentCount = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":["Runtime","Console"],"isProvisional":false}}}"#
    )

    let runtimeEnable = try await waitForTargetMessage(backend, method: "Runtime.enable", after: sentCount)
    #expect(runtimeEnable.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetErrorReply(
        transport,
        targetID: runtimeEnable.targetIdentifier,
        messageID: try messageID(runtimeEnable.message),
        message: "Unknown command: Runtime.enable"
    )

    let consoleEnable = try await waitForTargetMessage(backend, method: "Console.enable", after: sentCount)
    #expect(consoleEnable.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetReply(
        transport,
        targetID: consoleEnable.targetIdentifier,
        messageID: try messageID(consoleEnable.message),
        result: "{}"
    )

    #expect(await session.attachment.runtime.snapshot().unsupportedCommandsByTargetID[.frameAd]?.contains("Runtime.enable") == true)
    #expect(await session.lastError == nil)
}

@Test
func consoleEnableTargetNotFoundDoesNotMarkCommandUnsupported() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let sentCount = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":["Runtime","Console"],"isProvisional":false}}}"#
    )

    let runtimeEnable = try await waitForTargetMessage(backend, method: "Runtime.enable", after: sentCount)
    #expect(runtimeEnable.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetReply(
        transport,
        targetID: runtimeEnable.targetIdentifier,
        messageID: try messageID(runtimeEnable.message),
        result: "{}"
    )

    let consoleEnable = try await waitForTargetMessage(backend, method: "Console.enable", after: sentCount)
    #expect(consoleEnable.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetErrorReply(
        transport,
        targetID: consoleEnable.targetIdentifier,
        messageID: try messageID(consoleEnable.message),
        message: "Target not found"
    )

    #expect(await session.waitUntilRuntimeConsoleEnableFinished(targetID: .frameAd))
    #expect(await session.lastError != nil)
    #expect(await session.attachment.console.snapshot().unsupportedCommandsByTargetID[.frameAd]?.contains("Console.enable") != true)
}

@Test
func frameTargetWithAdvertisedRuntimeOnlyEnablesRuntimeWithoutConsole() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let sentCount = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":["Runtime"],"isProvisional":false}}}"#
    )

    let runtimeEnable = try await waitForTargetMessage(backend, method: "Runtime.enable", after: sentCount)
    #expect(runtimeEnable.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetReply(
        transport,
        targetID: runtimeEnable.targetIdentifier,
        messageID: try messageID(runtimeEnable.message),
        result: "{}"
    )

    #expect(await session.waitUntilRuntimeConsoleEnableFinished(targetID: .frameAd))
    let messages = await backend.sentTargetMessages().dropFirst(sentCount)
    #expect(messages.compactMap { try? messageMethod($0.message) }.contains("Console.enable") == false)
}

@Test
func serviceWorkerTargetCreatedAfterAttachEnablesRuntimeBeforeConsole() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let serviceWorkerTargetID = ProtocolTarget.ID("service-worker-1")
    let sentCount = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"service-worker-1","type":"service-worker","isProvisional":false}}}"#
    )

    let runtimeEnable = try await waitForTargetMessage(backend, method: "Runtime.enable", after: sentCount)
    #expect(runtimeEnable.targetIdentifier == serviceWorkerTargetID)
    await receiveTargetReply(
        transport,
        targetID: runtimeEnable.targetIdentifier,
        messageID: try messageID(runtimeEnable.message),
        result: "{}"
    )

    let consoleEnable = try await waitForTargetMessage(backend, method: "Console.enable", after: sentCount)
    #expect(consoleEnable.targetIdentifier == serviceWorkerTargetID)
    await receiveTargetReply(
        transport,
        targetID: consoleEnable.targetIdentifier,
        messageID: try messageID(consoleEnable.message),
        result: "{}"
    )
}

@Test
func workerTargetCreatedAfterAttachEnablesRuntimeBeforeConsoleWithoutDomainMetadata() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let workerTargetID = ProtocolTarget.ID("worker-1")
    let sentCount = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"worker-1","type":"worker","isProvisional":false}}}"#
    )

    let runtimeEnable = try await waitForTargetMessage(backend, method: "Runtime.enable", after: sentCount)
    #expect(runtimeEnable.targetIdentifier == workerTargetID)
    await receiveTargetReply(
        transport,
        targetID: runtimeEnable.targetIdentifier,
        messageID: try messageID(runtimeEnable.message),
        result: "{}"
    )

    let consoleEnable = try await waitForTargetMessage(backend, method: "Console.enable", after: sentCount)
    #expect(consoleEnable.targetIdentifier == workerTargetID)
    await receiveTargetReply(
        transport,
        targetID: consoleEnable.targetIdentifier,
        messageID: try messageID(consoleEnable.message),
        result: "{}"
    )
}

@Test
func serviceWorkerTargetDiscoveredBeforeAttachEnablesRuntimeBeforeConsoleAfterConnect() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    let serviceWorkerTargetID = ProtocolTarget.ID("service-worker-1")

    await transport.receiveRootMessage(
        cssCapablePageTargetCreatedMessage(targetID: "page-main", frameID: "main-frame", isProvisional: false)
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"service-worker-1","type":"service-worker","isProvisional":false}}}"#
    )

    let connectTask = Task {
        try await session.connect(transport: transport)
    }
    let bootstrapMessages = try await completeBootstrap(transport: transport, backend: backend)
    try await connectTask.value

    let runtimeEnable = try await waitForTargetMessage(backend, method: "Runtime.enable", after: bootstrapMessages.count)
    #expect(runtimeEnable.targetIdentifier == serviceWorkerTargetID)
    await receiveTargetReply(
        transport,
        targetID: runtimeEnable.targetIdentifier,
        messageID: try messageID(runtimeEnable.message),
        result: "{}"
    )

    let consoleEnable = try await waitForTargetMessage(backend, method: "Console.enable", after: bootstrapMessages.count)
    #expect(consoleEnable.targetIdentifier == serviceWorkerTargetID)
    await receiveTargetReply(
        transport,
        targetID: consoleEnable.targetIdentifier,
        messageID: try messageID(consoleEnable.message),
        result: "{}"
    )
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
    #expect(frameRequest.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetReply(
        transport,
        targetID: frameRequest.targetIdentifier,
        messageID: try messageID(frameRequest.message),
        result: firstLazyFrameDocumentResult
    )

    #expect(await session.attachment.dom.snapshot().targetsByID[.frameAd]?.currentDocumentID != nil)
}

@Test
func provisionalFrameDocumentReplyBeforeCommitRehydratesCommittedFrame() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let provisionalTargetID = ProtocolTarget.ID("frame-provisional")
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
    #expect(await session.attachment.dom.snapshot().targetsByID[provisionalTargetID]?.currentDocumentID == nil)

    let sentCountBeforeCommit = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"frame-provisional","newTargetId":"frame-ad"}}"#
    )
    let committedRequest = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: sentCountBeforeCommit
    )
    #expect(committedRequest.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetReply(
        transport,
        targetID: committedRequest.targetIdentifier,
        messageID: try messageID(committedRequest.message),
        result: secondLazyFrameDocumentResult
    )
    await session.attachment.dom.waitUntilDocumentRequestsIdle(targetID: committedRequest.targetIdentifier)

    let snapshot = await session.attachment.dom.snapshot()
    #expect(snapshot.targetsByID[ProtocolTarget.ID.frameAd]?.currentDocumentID != nil)
    #expect(snapshot.targetsByID[provisionalTargetID] == nil)
}

@Test
func committedProvisionalFrameWithRuntimeAndConsoleEnablesCommittedTarget() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let sentCountBeforeFrameTarget = await backend.sentTargetMessages().count
    let targetCreatedSequence = await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-provisional","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":["Runtime","Console"],"isProvisional":true}}}"#
    )
    await expectProtocolEventApplied(targetCreatedSequence, in: session)
    #expect(await backend.sentTargetMessages().count == sentCountBeforeFrameTarget)

    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"frame-provisional","newTargetId":"frame-ad"}}"#
    )

    let runtimeEnable = try await waitForTargetMessage(
        backend,
        method: "Runtime.enable",
        after: sentCountBeforeFrameTarget
    )
    #expect(runtimeEnable.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetReply(
        transport,
        targetID: runtimeEnable.targetIdentifier,
        messageID: try messageID(runtimeEnable.message),
        result: "{}"
    )

    let consoleEnable = try await waitForTargetMessage(
        backend,
        method: "Console.enable",
        after: sentCountBeforeFrameTarget
    )
    #expect(consoleEnable.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetReply(
        transport,
        targetID: consoleEnable.targetIdentifier,
        messageID: try messageID(consoleEnable.message),
        result: "{}"
    )
}

@Test
func committedNavigatedFrameReEnablesRuntimeAndConsoleOnNewTarget() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let sentCountBeforeFrameTarget = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":["Runtime","Console"],"isProvisional":false}}}"#
    )
    let firstRuntimeEnable = try await waitForTargetMessage(
        backend,
        method: "Runtime.enable",
        after: sentCountBeforeFrameTarget
    )
    #expect(firstRuntimeEnable.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetReply(
        transport,
        targetID: firstRuntimeEnable.targetIdentifier,
        messageID: try messageID(firstRuntimeEnable.message),
        result: "{}"
    )
    let firstConsoleEnable = try await waitForTargetMessage(
        backend,
        method: "Console.enable",
        after: sentCountBeforeFrameTarget
    )
    #expect(firstConsoleEnable.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetReply(
        transport,
        targetID: firstConsoleEnable.targetIdentifier,
        messageID: try messageID(firstConsoleEnable.message),
        result: "{}"
    )

    let sentCountBeforeNavigation = await backend.sentTargetMessages().count
    let targetCreatedSequence = await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-next","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":["Runtime","Console"],"isProvisional":true}}}"#
    )
    await expectProtocolEventApplied(targetCreatedSequence, in: session)
    #expect(await backend.sentTargetMessages().count == sentCountBeforeNavigation)

    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"frame-ad","newTargetId":"frame-next"}}"#
    )

    let secondRuntimeEnable = try await waitForTargetMessage(
        backend,
        method: "Runtime.enable",
        after: sentCountBeforeNavigation
    )
    #expect(secondRuntimeEnable.targetIdentifier == ProtocolTarget.ID("frame-next"))
    await receiveTargetReply(
        transport,
        targetID: secondRuntimeEnable.targetIdentifier,
        messageID: try messageID(secondRuntimeEnable.message),
        result: "{}"
    )

    let secondConsoleEnable = try await waitForTargetMessage(
        backend,
        method: "Console.enable",
        after: sentCountBeforeNavigation
    )
    #expect(secondConsoleEnable.targetIdentifier == ProtocolTarget.ID("frame-next"))
    await receiveTargetReply(
        transport,
        targetID: secondConsoleEnable.targetIdentifier,
        messageID: try messageID(secondConsoleEnable.message),
        result: "{}"
    )
}

@Test
func subframeCommitDoesNotRetargetPageRuntimeOrConsoleState() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":7,"type":"normal","frameId":"main-frame"}}}"#,
        in: session
    )
    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"Console.messageAdded","params":{"message":{"source":"console-api","level":"log","text":"page message","type":"log"}}}"#,
        in: session
    )
    let initialRuntimeSnapshot = await session.attachment.runtime.snapshot()
    let initialConsoleSnapshot = await session.attachment.console.snapshot()
    #expect(initialRuntimeSnapshot.executionContextsByKey[contextKey(.pageMain, 7)]?.targetID == .pageMain)
    #expect(initialConsoleSnapshot.orderedMessageIDs.first?.targetID == .pageMain)

    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-committed","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":["Runtime","Console"],"isProvisional":true}}}"#
    )
    let commitSequence = await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"frame-committed"}}"#
    )
    await expectProtocolEventApplied(commitSequence, in: session)
    let runtimeSnapshot = await session.attachment.runtime.snapshot()
    let consoleSnapshot = await session.attachment.console.snapshot()

    #expect(runtimeSnapshot.executionContextsByKey[contextKey(.pageMain, 7)]?.targetID == .pageMain)
    #expect(runtimeSnapshot.executionContextsByKey[contextKey(ProtocolTarget.ID("frame-committed"), 7)] == nil)
    #expect(consoleSnapshot.orderedMessageIDs.first?.targetID == .pageMain)
    #expect(consoleSnapshot.orderedMessageIDs.contains { $0.targetID == ProtocolTarget.ID("frame-committed") } == false)
}

@Test
func provisionalFrameCommitCancelsInFlightDocumentRequestBeforeRehydrating() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let provisionalTargetID = ProtocolTarget.ID("frame-provisional")
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
    #expect(committedRequest.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetReply(
        transport,
        targetID: committedRequest.targetIdentifier,
        messageID: try messageID(committedRequest.message),
        result: secondLazyFrameDocumentResult
    )
    await session.attachment.dom.waitUntilDocumentRequestsIdle(targetID: committedRequest.targetIdentifier)

    #expect(
        await pendingTargetReplyKeys(transport).contains(
            TransportSession.ReplyKey(targetID: .frameAd, commandID: firstRequestMessageID)
        ) == false
    )
    await receiveTargetReply(
        transport,
        targetID: .frameAd,
        messageID: firstRequestMessageID,
        result: firstLazyFrameDocumentResult
    )

    let snapshot = await session.attachment.dom.snapshot()
    #expect(snapshot.currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(201))] != nil)
    #expect(snapshot.currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(101))] == nil)
}

@Test
func oldlessProvisionalFrameCommitCancelsInFlightDocumentRequestBeforeRehydrating() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let provisionalTargetID = ProtocolTarget.ID("frame-provisional")
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
    #expect(committedRequest.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetReply(
        transport,
        targetID: committedRequest.targetIdentifier,
        messageID: try messageID(committedRequest.message),
        result: secondLazyFrameDocumentResult
    )
    await session.attachment.dom.waitUntilDocumentRequestsIdle(targetID: committedRequest.targetIdentifier)

    #expect(
        await pendingTargetReplyKeys(transport).contains(
            TransportSession.ReplyKey(targetID: .frameAd, commandID: firstRequestMessageID)
        ) == false
    )
    await receiveTargetReply(
        transport,
        targetID: .frameAd,
        messageID: firstRequestMessageID,
        result: firstLazyFrameDocumentResult
    )

    let snapshot = await session.attachment.dom.snapshot()
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
    #expect(frameDocumentRequest.targetIdentifier == ProtocolTarget.ID.frameAd)

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
    let snapshotWhileFrameRequestIsPending = await session.attachment.dom.snapshot()
    #expect(snapshotWhileFrameRequestIsPending.nodesByID[bodyID]?.nodeName == "BODY")
    #expect(snapshotWhileFrameRequestIsPending.targetsByID[.frameAd]?.currentDocumentID == nil)

    await receiveTargetReply(
        transport,
        targetID: frameDocumentRequest.targetIdentifier,
        messageID: try messageID(frameDocumentRequest.message),
        result: firstLazyFrameDocumentResult
    )
    await session.attachment.dom.waitUntilDocumentRequestsIdle(targetID: frameDocumentRequest.targetIdentifier)
    let finalSnapshot = await session.attachment.dom.snapshot()
    #expect(finalSnapshot.targetsByID[.frameAd]?.currentDocumentID != nil)
    #expect(finalSnapshot.currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(4))] == bodyID)
}

@Test
func pageDocumentUpdatedInvalidatesCurrentPageDocumentWithoutReloading() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let pageDocumentID = try #require(await session.attachment.dom.snapshot().currentPageDocumentID)
    let sentCount = await backend.sentTargetMessages().count

    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.documentUpdated","params":{}}"#,
        in: session
    )
    let snapshot = await session.attachment.dom.snapshot()

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

    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.documentUpdated","params":{}}"#,
        in: session
    )
    let invalidatedSnapshot = await session.attachment.dom.snapshot()
    #expect(invalidatedSnapshot.currentPageDocumentID == nil)

    let sentCount = await backend.sentTargetMessages().count
    let ensureTask = Task {
        await session.attachment.dom.ensureDocumentLoaded()
    }
    let reload = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: sentCount
    )
    #expect(reload.targetIdentifier == ProtocolTarget.ID.pageMain)
    await receiveTargetReply(
        transport,
        targetID: reload.targetIdentifier,
        messageID: try messageID(reload.message),
        result: manualReloadDocumentResult
    )

    #expect(await ensureTask.value)
    let finalSnapshot = await session.attachment.dom.snapshot()
    #expect(finalSnapshot.currentPageDocumentID?.localDocumentLifetimeID == .init(2))
    #expect(finalSnapshot.currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(40))] != nil)
}

@Test("Regression: documentUpdated reopens document request gate while previous getDocument is pending")
func documentUpdatedAllowsNewDocumentRequestWhilePreviousRequestIsPending() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.documentUpdated","params":{}}"#,
        in: session
    )
    #expect(await session.attachment.dom.snapshot().currentPageDocumentID == nil)

    let sentCount = await backend.sentTargetMessages().count
    let ensureTask = Task {
        await session.attachment.dom.ensureDocumentLoaded()
    }
    let firstRequest = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: sentCount
    )
    let afterFirstRequest = await backend.sentTargetMessages().count

    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.documentUpdated","params":{}}"#,
        in: session
    )
    let secondRequest = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: afterFirstRequest
    )

    #expect(secondRequest.targetIdentifier == ProtocolTarget.ID.pageMain)
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
            TransportSession.ReplyKey(targetID: firstRequest.targetIdentifier, commandID: try messageID(firstRequest.message))
        ) == false
    )
    await receiveTargetReply(
        transport,
        targetID: firstRequest.targetIdentifier,
        messageID: try messageID(firstRequest.message),
        result: staleReloadDocumentResult
    )

    let finalSnapshot = await session.attachment.dom.snapshot()
    #expect(finalSnapshot.currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(40))] != nil)
    #expect(finalSnapshot.currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(50))] == nil)
}

@Test("Regression: element picker begins after page documentUpdated invalidates loaded document")
func elementPickerBeginsAfterDocumentUpdatedInvalidatesLoadedDocument() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.documentUpdated","params":{}}"#,
        in: session
    )
    #expect(await session.attachment.dom.snapshot().currentPageDocumentID == nil)
    #expect(await session.attachment.dom.canSelectElement == false)
    #expect(await session.attachment.dom.canBeginElementPicker)

    let sentCount = await backend.sentTargetMessages().count
    let beginTask = Task {
        try await session.attachment.dom.beginElementPicker()
    }
    let documentRequest = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: sentCount
    )
    #expect(documentRequest.targetIdentifier == ProtocolTarget.ID.pageMain)
    #expect(
        await backend.sentTargetMessages().dropFirst(sentCount).compactMap { try? messageMethod($0.message) } == [
            "DOM.getDocument",
        ]
    )

    let afterDocumentRequest = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: documentRequest.targetIdentifier,
        messageID: try messageID(documentRequest.message),
        result: manualReloadDocumentResult
    )

    let enableMessage = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: afterDocumentRequest
    )
    #expect(enableMessage.targetIdentifier == ProtocolTarget.ID.pageMain)
    #expect(try boolParameter("enabled", in: enableMessage.message) == true)
    await receiveTargetReply(
        transport,
        targetID: enableMessage.targetIdentifier,
        messageID: try messageID(enableMessage.message),
        result: "{}"
    )

    try await beginTask.value
    #expect(await session.attachment.dom.isSelectingElement)
}

@Test("Regression: stale setChildNodes from previous page does not move head children into new body")
func staleSetChildNodesAfterPageNavigationDoesNotMoveHeadChildrenIntoNewBody() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let countBeforeOldDocumentReload = await backend.sentTargetMessages().count
    let oldDocumentReloadTask = Task {
        try await session.attachment.dom.reloadDocument()
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
    let requestIntent = try #require(await session.attachment.dom.requestChildNodesIntent(for: oldHeadID))
    let countBeforeRequest = await backend.sentTargetMessages().count
    let requestTask = Task {
        try await session.attachment.dom.perform(requestIntent)
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

    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":4,"nodes":[{"nodeId":8,"nodeType":1,"nodeName":"STYLE","localName":"style"}]}}"#,
        in: session
    )
    #expect(await session.attachment.dom.snapshot().currentPageDocumentID == nil)
    #expect(await backend.sentTargetMessages().count == countBeforeNavigation)

    let countBeforeManualReload = await backend.sentTargetMessages().count
    let manualReloadTask = Task {
        try await session.attachment.dom.reloadDocument()
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

    let snapshot = await session.attachment.dom.snapshot()
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
    #expect(frameDocumentRequest.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetReply(
        transport,
        targetID: frameDocumentRequest.targetIdentifier,
        messageID: try messageID(frameDocumentRequest.message),
        result: firstLazyFrameDocumentResult
    )
    await session.attachment.dom.waitUntilDocumentRequestsIdle(targetID: frameDocumentRequest.targetIdentifier)

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

    let beforeUpdate = await session.attachment.dom.snapshot()
    _ = try #require(beforeUpdate.currentPageDocumentID)
    let frameDocumentID = try #require(beforeUpdate.targetsByID[.frameAd]?.currentDocumentID)
    let frameRootID = try #require(beforeUpdate.documentsByID[frameDocumentID]?.rootNodeID)
    await session.attachment.dom.selectNode(mainNodeID)
    assertProjectionContainsFrameDocument(
        in: await session.attachment.dom.treeProjection(rootTargetID: .pageMain),
        iframeNodeID: iframeNodeID,
        frameRootNodeID: frameRootID
    )

    let sentCountBeforeTargetlessUpdate = await backend.sentTargetMessages().count
    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"DOM.documentUpdated","params":{}}"#,
        in: session
    )

    let afterUpdate = await session.attachment.dom.snapshot()
    #expect(afterUpdate.currentPageDocumentID == nil)
    #expect(afterUpdate.targetsByID[ProtocolTarget.ID.frameAd]?.currentDocumentID == frameDocumentID)
    #expect(afterUpdate.selection.selectedNodeID == nil)
    #expect(await backend.sentTargetMessages().count == sentCountBeforeTargetlessUpdate)
    #expect((await session.attachment.dom.treeProjection(rootTargetID: .pageMain)).rows.map(\.nodeID).contains(frameRootID) == false)
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
    #expect(firstFrameDocumentRequest.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetReply(
        transport,
        targetID: firstFrameDocumentRequest.targetIdentifier,
        messageID: try messageID(firstFrameDocumentRequest.message),
        result: firstLazyFrameDocumentResult
    )
    await session.attachment.dom.waitUntilDocumentRequestsIdle(targetID: firstFrameDocumentRequest.targetIdentifier)

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

    let beforeUpdate = await session.attachment.dom.snapshot()
    let pageDocumentID = try #require(beforeUpdate.currentPageDocumentID)
    let firstFrameDocumentID = try #require(beforeUpdate.targetsByID[.frameAd]?.currentDocumentID)
    let firstFrameRootID = try #require(beforeUpdate.documentsByID[firstFrameDocumentID]?.rootNodeID)
    assertProjectionContainsFrameDocument(
        in: await session.attachment.dom.treeProjection(rootTargetID: .pageMain),
        iframeNodeID: iframeNodeID,
        frameRootNodeID: firstFrameRootID
    )

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":6,"nodes":[{"nodeId":7,"nodeType":1,"nodeName":"SPAN","localName":"span"}]}}"#
    )
    let afterIframeOwnerUpdate = await session.attachment.dom.snapshot()
    #expect(afterIframeOwnerUpdate.currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(7))] == nil)
    assertProjectionContainsFrameDocument(
        in: await session.attachment.dom.treeProjection(rootTargetID: .pageMain),
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
        in: await session.attachment.dom.treeProjection(rootTargetID: .pageMain),
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
    #expect(frameDocumentReload.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetReply(
        transport,
        targetID: frameDocumentReload.targetIdentifier,
        messageID: try messageID(frameDocumentReload.message),
        result: secondLazyFrameDocumentResult
    )

    await session.attachment.dom.waitUntilDocumentRequestsIdle(targetID: frameDocumentReload.targetIdentifier)
    let afterUpdate = await session.attachment.dom.snapshot()
    #expect(afterUpdate.targetsByID[.frameAd]?.currentDocumentID != firstFrameDocumentID)
    let secondFrameDocumentID = try #require(afterUpdate.targetsByID[.frameAd]?.currentDocumentID)
    let secondFrameRootID = try #require(afterUpdate.documentsByID[secondFrameDocumentID]?.rootNodeID)

    #expect(afterUpdate.currentPageDocumentID == pageDocumentID)
    #expect(afterUpdate.nodesByID[mainNodeID] != nil)
    #expect(afterUpdate.nodesByID[iframeNodeID] != nil)
    #expect(afterUpdate.nodesByID[firstFrameRootID] == nil)
    assertProjectionContainsFrameDocument(
        in: await session.attachment.dom.treeProjection(rootTargetID: .pageMain),
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
    #expect(initialFrameDocumentRequest.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetReply(
        transport,
        targetID: initialFrameDocumentRequest.targetIdentifier,
        messageID: try messageID(initialFrameDocumentRequest.message),
        result: firstLazyFrameDocumentResult
    )
    await session.attachment.dom.waitUntilDocumentRequestsIdle(targetID: initialFrameDocumentRequest.targetIdentifier)

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
    #expect(firstReload.targetIdentifier == ProtocolTarget.ID.frameAd)

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
    #expect(secondReload.targetIdentifier == ProtocolTarget.ID.frameAd)
    #expect(try messageID(secondReload.message) != messageID(firstReload.message))

    #expect(
        await pendingTargetReplyKeys(transport).contains(
            TransportSession.ReplyKey(targetID: firstReload.targetIdentifier, commandID: try messageID(firstReload.message))
        ) == false
    )
    await receiveTargetReply(
        transport,
        targetID: firstReload.targetIdentifier,
        messageID: try messageID(firstReload.message),
        result: firstLazyFrameDocumentResult
    )
    #expect(await session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(101))] == nil)

    await receiveTargetReply(
        transport,
        targetID: secondReload.targetIdentifier,
        messageID: try messageID(secondReload.message),
        result: secondLazyFrameDocumentResult
    )

    await session.attachment.dom.waitUntilDocumentRequestsIdle(targetID: secondReload.targetIdentifier)
    let snapshot = await session.attachment.dom.snapshot()
    #expect(snapshot.currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(201))] != nil)
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
    #expect(frameDocumentRequest.targetIdentifier == ProtocolTarget.ID.frameAd)
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
    #expect(htmlHydrationRequest.targetIdentifier == ProtocolTarget.ID.pageMain)
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
    #expect(bodyHydrationRequest.targetIdentifier == ProtocolTarget.ID.pageMain)
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
    let snapshot = await session.attachment.dom.snapshot()
    let frameDocumentID = try #require(snapshot.targetsByID[.frameAd]?.currentDocumentID)
    let frameRootID = try #require(snapshot.documentsByID[frameDocumentID]?.rootNodeID)
    assertProjectionContainsFrameDocument(
        in: await session.attachment.dom.treeProjection(rootTargetID: .pageMain),
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

    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#,
        in: session
    )

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
        try await session.attachment.dom.perform(.getDocument(targetID: .frameAd))
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
    let firstFrameDocumentID = try #require(await session.attachment.dom.snapshot().targetsByID[.frameAd]?.currentDocumentID)
    let firstFrameRootID = try #require(await session.attachment.dom.snapshot().documentsByID[firstFrameDocumentID]?.rootNodeID)

    assertProjectionContainsFrameDocument(
        in: await session.attachment.dom.treeProjection(rootTargetID: .pageMain),
        iframeNodeID: iframeNodeID,
        frameRootNodeID: firstFrameRootID
    )

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":6,"nodes":[{"nodeId":7,"nodeType":1,"nodeName":"SPAN","localName":"span"}]}}"#
    )
    #expect(await session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(7))] == nil)
    assertProjectionContainsFrameDocument(
        in: await session.attachment.dom.treeProjection(rootTargetID: .pageMain),
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
    try await replyToPickerDisableAndRestoredHighlight(
        disable,
        transport: transport,
        backend: backend,
        expectedTargetID: .frameAd,
        expectedNodeID: 104
    )
    await session.attachment.dom.waitUntilElementPickerIdle()
    let selectedNode = try #require(await session.attachment.dom.selectedNode)
    #expect(await selectedNode.nodeName == "CANVAS")
    let snapshot = await session.attachment.dom.snapshot()
    let projection = await session.attachment.dom.treeProjection(rootTargetID: .pageMain)

    #expect(snapshot.framesByID[DOMFrame.ID("main-frame")]?.currentDocumentID == snapshot.currentPageDocumentID)
    #expect(snapshot.framesByID[DOMFrame.ID("ad-frame")]?.currentDocumentID == firstFrameDocumentID)
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

    let snapshot = await session.attachment.dom.snapshot()
    #expect(snapshot.currentPageTargetID == ProtocolTarget.ID.pageNext)
    #expect(snapshot.targetsByID[.pageNext]?.currentDocumentID != nil)
    #expect(snapshot.targetsByID[.pageMain] == nil)
    #expect(bootstrapMessages.map(\.targetIdentifier).allSatisfy { $0 == .pageNext })
    #expect(bootstrapMessages.compactMap { try? messageMethod($0.message) } == [
        "Inspector.enable",
        "Inspector.initialized",
        "Runtime.enable",
        "DOM.getDocument",
        "Network.enable",
        "Console.enable",
    ])
}

@Test
func runtimeEvaluationResultUsesCommittedReplyTargetAfterNavigationCommit() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let sentCountBeforeEvaluate = await backend.sentTargetMessages().count
    let intent = await session.attachment.runtime.evaluateIntent(expression: "window", targetID: .pageMain)
    let evaluateTask = Task {
        try await session.attachment.runtime.perform(intent)
    }
    let evaluateMessage = try await waitForTargetMessage(
        backend,
        method: "Runtime.evaluate",
        after: sentCountBeforeEvaluate
    )
    let sentCountBeforeCommit = await backend.sentTargetMessages().count

    await transport.receiveRootMessage(
        cssCapablePageTargetCreatedMessage(targetID: "page-next", isProvisional: true)
    )
    let commitSequence = await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"page-next"}}"#
    )
    await expectProtocolEventApplied(commitSequence, in: session)

    await receiveTargetReply(
        transport,
        targetID: .pageNext,
        messageID: try messageID(evaluateMessage.message),
        result: #"{"result":{"type":"object","objectId":"eval-object","description":"Window"}}"#
    )
    let result = try await evaluateTask.value

    let objectID = RuntimeRemoteObject.ProtocolID("eval-object")
    let snapshot = await session.attachment.runtime.snapshot()
    #expect(result.targetID == ProtocolTarget.ID.pageNext)
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: .pageMain, objectID: objectID)] == nil)
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: .pageNext, objectID: objectID)]?.payload.description == "Window")

    try await completeBootstrap(
        transport: transport,
        backend: backend,
        after: sentCountBeforeCommit,
        documentResult: manualReloadDocumentResult
    )
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

    await session.attachment.dom.waitUntilDocumentRequestsIdle(targetID: .pageNext)
    let snapshot = await session.attachment.dom.snapshot()
    #expect(snapshot.currentPageTargetID == .pageNext)
    #expect(snapshot.currentNodeIDByKey[.init(targetID: .pageNext, nodeID: .init(3))] != nil)
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

    await receiveAndApplyRuntimeContextCreated(transport, contextID: 7, in: session)
    #expect(await session.attachment.runtime.snapshot().executionContextsByKey[contextKey(.pageMain, 7)]?.targetID == .pageMain)
    let intent = await session.attachment.dom.beginInspectSelectionRequest(
        targetID: .pageMain,
        objectID: "selected-object"
    )
    guard case let .success(commandIntent) = intent else {
        Issue.record("Expected DOM.requestNode intent")
        return
    }

    let sentCount = await backend.sentTargetMessages().count
    let performTask = Task {
        try await session.attachment.dom.perform(commandIntent)
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

    let selectedNode = try #require(await session.attachment.dom.selectedNode)
    let nodeName = await selectedNode.nodeName
    let attributes = await selectedNode.attributes
    #expect(nodeName == "DIV")
    #expect(attributes == [WebInspectorCore.DOMNode.Attribute(name: "id", value: "selected")])
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
    let intent = await session.attachment.dom.beginInspectSelectionRequest(
        targetID: .pageMain,
        objectID: "selected-object"
    )
    guard case let .success(commandIntent) = intent else {
        Issue.record("Expected DOM.requestNode intent")
        return
    }

    let sentCount = await backend.sentTargetMessages().count
    let performTask = Task {
        try await session.attachment.dom.perform(commandIntent)
    }
    let sent = try await waitForTargetMessage(backend, method: "DOM.requestNode", after: sentCount)
    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: #"{"nodeId":164}"#
    )
    _ = try await performTask.value

    #expect(await session.attachment.dom.selectedNodeID == expectedNodeID)
    let selectedNode = try #require(await session.attachment.dom.selectedNode)
    #expect(await selectedNode.attributes == [WebInspectorCore.DOMNode.Attribute(name: "id", value: "picked")])
}

@Test("Regression: detached setChildNodes root keeps requestNode selectable")
func detachedSetChildNodesRootKeepsRequestNodeSelectable() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let intent = await session.attachment.dom.beginInspectSelectionRequest(
        targetID: .pageMain,
        objectID: "detached-selected-object"
    )
    guard case let .success(commandIntent) = intent else {
        Issue.record("Expected DOM.requestNode intent")
        return
    }

    let sentCount = await backend.sentTargetMessages().count
    let performTask = Task {
        try await session.attachment.dom.perform(commandIntent)
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

    let selectedNode = try #require(await session.attachment.dom.selectedNode)
    #expect(await selectedNode.nodeName == "IMG")
    #expect(await selectedNode.attributes == [WebInspectorCore.DOMNode.Attribute(name: "src", value: "https://ads.example/detached.webp")])
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
    await session.attachment.dom.waitUntilDocumentRequestsIdle(targetID: frameDocumentRequest.targetIdentifier)

    let intent = await session.attachment.dom.beginInspectSelectionRequest(
        targetID: .frameAd,
        objectID: "detached-frame-object"
    )
    guard case let .success(commandIntent) = intent else {
        Issue.record("Expected DOM.requestNode intent")
        return
    }

    let sentCount = await backend.sentTargetMessages().count
    let performTask = Task {
        try await session.attachment.dom.perform(commandIntent)
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

    let selectedNode = try #require(await session.attachment.dom.selectedNode)
    #expect(await selectedNode.nodeName == "IMG")
    #expect(await session.attachment.dom.selectedNodeID?.documentID.targetID == ProtocolTarget.ID.frameAd)
}

@Test
func requestNodeReplyBeforePathPushKeepsSelectionPendingUntilParentArrives() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let snapshotBeforeSelection = await session.attachment.dom.snapshot()

    await receiveAndApplyRuntimeContextCreated(transport, contextID: 7, in: session)
    let intent = await session.attachment.dom.beginInspectSelectionRequest(
        targetID: .pageMain,
        objectID: "missing-object"
    )
    guard case let .success(commandIntent) = intent else {
        Issue.record("Expected DOM.requestNode intent")
        return
    }

    let sentCount = await backend.sentTargetMessages().count
    let performTask = Task {
        try await session.attachment.dom.perform(commandIntent)
    }
    let sent = try await waitForTargetMessage(backend, method: "DOM.requestNode", after: sentCount)
    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: #"{"nodeId":999}"#
    )
    _ = try await performTask.value

    let snapshot = await session.attachment.dom.snapshot()
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

    let sentCountBeforePathPush = await backend.sentTargetMessages().count
    let setChildNodesSequence = await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":2,"nodes":[{"nodeId":999,"nodeType":1,"nodeName":"DIV","localName":"div","attributes":["id","late-path"]}]}}"#
    )
    await expectProtocolEventApplied(setChildNodesSequence, in: session)
    let restoredHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: sentCountBeforePathPush
    )
    #expect(restoredHighlight.targetIdentifier == ProtocolTarget.ID.pageMain)
    #expect(try integerParameter("nodeId", in: restoredHighlight.message) == 999)
    await receiveTargetReply(
        transport,
        targetID: restoredHighlight.targetIdentifier,
        messageID: try messageID(restoredHighlight.message),
        result: "{}"
    )

    let selectedNode = try #require(await session.attachment.dom.selectedNode)
    #expect(await selectedNode.nodeName == "DIV")
    #expect(await selectedNode.attributes == [WebInspectorCore.DOMNode.Attribute(name: "id", value: "late-path")])
    let resolvedSnapshot = await session.attachment.dom.snapshot()
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
        try await session.attachment.dom.beginElementPicker()
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
    #expect(await session.attachment.dom.isSelectingElement)

    let sentCountBeforeCancel = await backend.sentTargetMessages().count
    let cancelTask = Task {
        await session.attachment.dom.cancelElementPicker()
    }
    let disableMessage = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeCancel
    )
    #expect(try boolParameter("enabled", in: disableMessage.message) == false)
    try await replyToPickerDisableAndHiddenHighlight(
        disableMessage,
        transport: transport,
        backend: backend,
        expectedTargetID: .pageMain
    )
    await cancelTask.value

    #expect(await session.attachment.dom.isSelectingElement == false)
}

@Test
func elementPickerCancelRestoresExistingSelectedNodeHighlight() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let htmlID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    await session.attachment.dom.selectNode(htmlID)
    try await beginPicker(session: session, transport: transport, backend: backend)

    let sentCountBeforeCancel = await backend.sentTargetMessages().count
    let cancelTask = Task {
        await session.attachment.dom.cancelElementPicker()
    }
    let disableMessage = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeCancel
    )
    #expect(try boolParameter("enabled", in: disableMessage.message) == false)
    try await replyToPickerDisableAndRestoredHighlight(
        disableMessage,
        transport: transport,
        backend: backend,
        expectedTargetID: .pageMain,
        expectedNodeID: 2
    )
    await cancelTask.value

    #expect(await session.attachment.dom.selectedNodeID == htmlID)
    #expect(await session.attachment.dom.isSelectingElement == false)
}

@Test
func restoreSelectedNodeHighlightHidesWhenSelectionIsMissing() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let sentCount = await backend.sentTargetMessages().count
    let restoreTask = Task {
        await session.attachment.dom.restoreSelectedNodeHighlightOrHide()
    }
    let hideHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: sentCount
    )
    #expect(hideHighlight.targetIdentifier == ProtocolTarget.ID.pageMain)
    await receiveTargetReply(
        transport,
        targetID: hideHighlight.targetIdentifier,
        messageID: try messageID(hideHighlight.message),
        result: "{}"
    )
    await restoreTask.value
}

@Test
func restoreSelectedNodeHighlightNoOpsWhileElementPickerIsActive() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let htmlID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    await session.attachment.dom.selectNode(htmlID)
    try await beginPicker(session: session, transport: transport, backend: backend)
    #expect(await session.attachment.dom.isSelectingElement)

    let sentCount = await backend.sentTargetMessages().count
    await session.attachment.dom.restoreSelectedNodeHighlightOrHide()
    #expect(await backend.sentTargetMessages().count == sentCount)

    let sentCountBeforeCancel = await backend.sentTargetMessages().count
    let cancelTask = Task {
        await session.attachment.dom.cancelElementPicker()
    }
    let disableMessage = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeCancel
    )
    try await replyToPickerDisableAndRestoredHighlight(
        disableMessage,
        transport: transport,
        backend: backend,
        expectedTargetID: .pageMain,
        expectedNodeID: 2
    )
    await cancelTask.value
}

@Test
func targetDestroyedClearsActiveElementPicker() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await beginPicker(session: session, transport: transport, backend: backend)
    #expect(await session.attachment.dom.isSelectingElement)

    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetDestroyed","params":{"targetId":"page-main"}}"#,
        in: session
    )
    await session.attachment.dom.waitUntilElementPickerIdle()
    #expect(await session.attachment.dom.isSelectingElement == false)
}

@Test
func targetCommitClearsElementPickerForOldTarget() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await beginPicker(session: session, transport: transport, backend: backend)
    #expect(await session.attachment.dom.isSelectingElement)

    let sentCountBeforeNavigation = await backend.sentTargetMessages().count
    await receiveAndApplyRootMessage(
        transport,
        message: cssCapablePageTargetCreatedMessage(targetID: "page-next", isProvisional: true),
        in: session
    )
    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"page-next"}}"#,
        in: session
    )

    await session.attachment.dom.waitUntilElementPickerIdle()
    #expect(await session.attachment.dom.isSelectingElement == false)

    let bootstrapMessages = try await completeBootstrap(
        transport: transport,
        backend: backend,
        after: sentCountBeforeNavigation,
        documentResult: manualReloadDocumentResult
    )
    #expect(bootstrapMessages.map(\.targetIdentifier).allSatisfy { $0 == .pageNext })
}

@Test
func subframeCommitDoesNotClearPageElementPicker() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await beginPicker(session: session, transport: transport, backend: backend)
    #expect(await session.attachment.dom.isSelectingElement)

    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-committed","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","domains":["DOM","Runtime","Console"],"isProvisional":true}}}"#
    )
    let commitSequence = await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"frame-committed"}}"#
    )
    await expectProtocolEventApplied(commitSequence, in: session)

    #expect(await session.attachment.dom.isSelectingElement)
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
        try await session.attachment.dom.beginElementPicker()
    }

    let enableMessage = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforePicker
    )
    #expect(enableMessage.targetIdentifier == ProtocolTarget.ID.pageNext)
    await receiveTargetReply(
        transport,
        targetID: enableMessage.targetIdentifier,
        messageID: try messageID(enableMessage.message),
        result: "{}"
    )
    try await beginTask.value
    #expect(await session.attachment.dom.isSelectingElement)
}

@Test("Regression: element picker ignores inspect events before inspect-mode enable completes")
func elementPickerIgnoresInspectEventBeforeInspectModeReply() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    await receiveAndApplyRuntimeContextCreated(transport, contextID: 7, in: session)

    let sentCount = await backend.sentTargetMessages().count
    let beginTask = Task {
        try await session.attachment.dom.beginElementPicker()
    }
    let enableMessage = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCount
    )
    #expect(try boolParameter("enabled", in: enableMessage.message) == true)
    #expect(await session.attachment.dom.isSelectingElement)

    let sentCountBeforeInspect = await backend.sentTargetMessages().count
    let inspectBeforeEnableSequence = await transport.receiveRootMessage(#"{"method":"Inspector.inspect","params":{"object":{"objectId":"{\"injectedScriptId\":7,\"id\":99}"},"hints":{}}}"#)
    await expectProtocolEventApplied(inspectBeforeEnableSequence, in: session)
    let messagesBeforeEnableReply = await backend.sentTargetMessages().dropFirst(sentCountBeforeInspect)
    #expect(messagesBeforeEnableReply.allSatisfy { (try? messageMethod($0.message)) != "DOM.requestNode" })
    #expect(await session.attachment.dom.isSelectingElement)

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
    #expect(requestNode.targetIdentifier == ProtocolTarget.ID.pageMain)

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
    try await replyToPickerDisableAndRestoredHighlight(
        disableMessage,
        transport: transport,
        backend: backend,
        expectedTargetID: .pageMain,
        expectedNodeID: 3
    )

    await session.attachment.dom.waitUntilElementPickerIdle()
    let selectedNode = try #require(await session.attachment.dom.selectedNode)
    #expect(await selectedNode.nodeName == "DIV")
    #expect(await session.attachment.dom.isSelectingElement == false)
}

@Test("Regression: restarted picker ignores stale inspect event while enable is pending")
func restartedElementPickerIgnoresStaleInspectEventBeforeInspectModeReply() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    await receiveAndApplyRuntimeContextCreated(transport, contextID: 7, in: session)

    let sentCountBeforeFirstBegin = await backend.sentTargetMessages().count
    let firstBeginTask = Task {
        try await session.attachment.dom.beginElementPicker()
    }
    let firstEnable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeFirstBegin
    )
    #expect(try boolParameter("enabled", in: firstEnable.message) == true)

    let sentCountBeforeCancel = await backend.sentTargetMessages().count
    let cancelTask = Task {
        await session.attachment.dom.cancelElementPicker()
    }
    let cancelDisable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeCancel
    )
    #expect(try boolParameter("enabled", in: cancelDisable.message) == false)
    try await replyToPickerDisableAndHiddenHighlight(
        cancelDisable,
        transport: transport,
        backend: backend,
        expectedTargetID: .pageMain
    )
    await cancelTask.value

    let sentCountBeforeRestart = await backend.sentTargetMessages().count
    let restartTask = Task {
        try await session.attachment.dom.beginElementPicker()
    }
    let restartEnable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeRestart
    )
    #expect(try boolParameter("enabled", in: restartEnable.message) == true)
    #expect(await session.attachment.dom.isSelectingElement)

    let sentCountBeforeStaleInspect = await backend.sentTargetMessages().count
    let staleInspectSequence = await transport.receiveRootMessage(#"{"method":"Inspector.inspect","params":{"object":{"objectId":"{\"injectedScriptId\":7,\"id\":99}"},"hints":{}}}"#)
    await expectProtocolEventApplied(staleInspectSequence, in: session)
    let messagesAfterStaleInspect = await backend.sentTargetMessages().dropFirst(sentCountBeforeStaleInspect)
    #expect(messagesAfterStaleInspect.allSatisfy { (try? messageMethod($0.message)) != "DOM.requestNode" })
    #expect(messagesAfterStaleInspect.allSatisfy { (try? messageMethod($0.message)) != "DOM.setInspectModeEnabled" })
    #expect(await session.attachment.dom.isSelectingElement)

    await receiveTargetReply(
        transport,
        targetID: firstEnable.targetIdentifier,
        messageID: try messageID(firstEnable.message),
        result: "{}"
    )
    try await firstBeginTask.value
    #expect(await session.attachment.dom.isSelectingElement)

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
    #expect(requestNode.targetIdentifier == ProtocolTarget.ID.pageMain)
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
    try await replyToPickerDisableAndRestoredHighlight(
        disable,
        transport: transport,
        backend: backend,
        expectedTargetID: .pageMain,
        expectedNodeID: 3
    )

    await session.attachment.dom.waitUntilElementPickerIdle()
    let selectedNode = try #require(await session.attachment.dom.selectedNode)
    #expect(await selectedNode.nodeName == "DIV")
    #expect(await session.attachment.dom.isSelectingElement == false)
}

@Test
func staleInspectEventCompletionDoesNotCancelRestartedPicker() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    await receiveAndApplyRuntimeContextCreated(transport, contextID: 7, in: session)
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
        await session.attachment.dom.cancelElementPicker()
    }
    let cancelDisable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeCancel
    )
    #expect(try boolParameter("enabled", in: cancelDisable.message) == false)
    try await replyToPickerDisableAndHiddenHighlight(
        cancelDisable,
        transport: transport,
        backend: backend,
        expectedTargetID: .pageMain
    )
    await cancelTask.value

    let sentCountBeforeRestart = await backend.sentTargetMessages().count
    let restartTask = Task {
        try await session.attachment.dom.beginElementPicker()
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
    #expect(await session.attachment.dom.isSelectingElement)

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
    #expect(await session.attachment.dom.isSelectingElement)
    #expect(messagesAfterStaleReply.allSatisfy { (try? messageMethod($0.message)) != "DOM.setInspectModeEnabled" })
}

@Test
func inspectorInspectSelectsRequestedNodeAndDisablesPicker() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    await receiveAndApplyRuntimeContextCreated(transport, contextID: 7, in: session)
    try await beginPicker(session: session, transport: transport, backend: backend)
    let sentCountBeforeInspect = await backend.sentTargetMessages().count

    await transport.receiveRootMessage(#"{"method":"Inspector.inspect","params":{"object":{"objectId":"{\"injectedScriptId\":7,\"id\":99}"},"hints":{}}}"#)
    let requestNode = try await waitForTargetMessage(
        backend,
        method: "DOM.requestNode",
        after: sentCountBeforeInspect
    )
    #expect(requestNode.targetIdentifier == ProtocolTarget.ID.pageMain)
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
    try await replyToPickerDisableAndRestoredHighlight(
        disable,
        transport: transport,
        backend: backend,
        expectedTargetID: .pageMain,
        expectedNodeID: 3
    )

    await session.attachment.dom.waitUntilElementPickerIdle()
    let selectedNode = try #require(await session.attachment.dom.selectedNode)
    #expect(await selectedNode.nodeName == "DIV")
    #expect(await session.attachment.dom.isSelectingElement == false)
}

@Test
func pendingPickerSelectionDoesNotRestorePreviousNodeHighlight() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let previousNodeID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    await session.attachment.dom.selectNode(previousNodeID)
    try await beginPicker(session: session, transport: transport, backend: backend)
    let sentCountBeforeInspect = await backend.sentTargetMessages().count

    await transport.receiveRootMessage(#"{"method":"Inspector.inspect","params":{"object":{"objectId":"pending-node-object"},"hints":{}}}"#)
    let requestNode = try await waitForTargetMessage(
        backend,
        method: "DOM.requestNode",
        after: sentCountBeforeInspect
    )
    let sentCountBeforeRequestReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: requestNode.targetIdentifier,
        messageID: try messageID(requestNode.message),
        result: #"{"nodeId":999}"#
    )
    let disable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeRequestReply
    )
    try await replyToPickerDisableAndHiddenHighlight(
        disable,
        transport: transport,
        backend: backend,
        expectedTargetID: .pageMain
    )
    await session.attachment.dom.waitUntilElementPickerIdle()

    let pendingSnapshot = await session.attachment.dom.snapshot()
    #expect(pendingSnapshot.selection.selectedNodeID == previousNodeID)
    #expect(pendingSnapshot.selection.pendingRequest != nil)

    let sentCountBeforePathPush = await backend.sentTargetMessages().count
    let setChildNodesSequence = await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":2,"nodes":[{"nodeId":999,"nodeType":1,"nodeName":"DIV","localName":"div","attributes":["id","late-picked"]}]}}"#
    )
    await expectProtocolEventApplied(setChildNodesSequence, in: session)
    let restoredHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: sentCountBeforePathPush
    )
    #expect(restoredHighlight.targetIdentifier == ProtocolTarget.ID.pageMain)
    #expect(try integerParameter("nodeId", in: restoredHighlight.message) == 999)
    await receiveTargetReply(
        transport,
        targetID: restoredHighlight.targetIdentifier,
        messageID: try messageID(restoredHighlight.message),
        result: "{}"
    )

    let selectedNode = try #require(await session.attachment.dom.selectedNode)
    #expect(await selectedNode.attributes == [WebInspectorCore.DOMNode.Attribute(name: "id", value: "late-picked")])
}

@Test
func pendingPickerSelectionHidesPreviousFrameHighlight() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#,
        in: session
    )
    _ = await session.attachment.dom.replaceDocumentRoot(
        WebInspectorCore.DOMNode.Payload(
            nodeID: .init(101),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                WebInspectorCore.DOMNode.Payload(nodeID: .init(102), nodeType: .element, nodeName: "HTML", localName: "html"),
            ])
        ),
        targetID: .frameAd
    )
    let frameHTMLID = try #require(await session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(102))])
    await session.attachment.dom.selectNode(frameHTMLID)
    let countBeforePreviousHighlight = await backend.sentTargetMessages().count
    let previousHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: frameHTMLID)
    }
    let previousHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforePreviousHighlight
    )
    #expect(previousHighlight.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetReply(
        transport,
        targetID: previousHighlight.targetIdentifier,
        messageID: try messageID(previousHighlight.message),
        result: "{}"
    )
    await previousHighlightTask.value

    let countBeforeBeginPicker = await backend.sentTargetMessages().count
    let beginPickerTask = Task {
        try await session.attachment.dom.beginElementPicker()
    }
    let beginPickerHide = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: countBeforeBeginPicker
    )
    #expect(beginPickerHide.targetIdentifier == ProtocolTarget.ID.frameAd)
    let sentCountBeforeBeginPickerHideReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: beginPickerHide.targetIdentifier,
        messageID: try messageID(beginPickerHide.message),
        result: "{}"
    )
    let enable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeBeginPickerHideReply
    )
    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )
    try await beginPickerTask.value

    let sentCountBeforeInspect = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(#"{"method":"Inspector.inspect","params":{"object":{"objectId":"pending-node-object"},"hints":{}}}"#)
    let requestNode = try await waitForTargetMessage(
        backend,
        method: "DOM.requestNode",
        after: sentCountBeforeInspect
    )
    let sentCountBeforeRequestReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: requestNode.targetIdentifier,
        messageID: try messageID(requestNode.message),
        result: #"{"nodeId":999}"#
    )
    let disable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: sentCountBeforeRequestReply
    )
    let sentCountBeforeDisableReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )
    let pageHide = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: sentCountBeforeDisableReply
    )
    #expect(pageHide.targetIdentifier == ProtocolTarget.ID.pageMain)
    await receiveTargetReply(
        transport,
        targetID: pageHide.targetIdentifier,
        messageID: try messageID(pageHide.message),
        result: "{}"
    )
    await session.attachment.dom.waitUntilElementPickerIdle()

    let pendingSnapshot = await session.attachment.dom.snapshot()
    #expect(pendingSnapshot.selection.selectedNodeID == frameHTMLID)
    #expect(pendingSnapshot.selection.pendingRequest != nil)
}

@Test
func directHighlightHidesPreviousTargetBeforeHighlightingNewTarget() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let pageHTMLID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#,
        in: session
    )
    _ = await session.attachment.dom.replaceDocumentRoot(
        WebInspectorCore.DOMNode.Payload(
            nodeID: .init(101),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                WebInspectorCore.DOMNode.Payload(nodeID: .init(102), nodeType: .element, nodeName: "HTML", localName: "html"),
            ])
        ),
        targetID: .frameAd
    )
    let frameHTMLID = try #require(await session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(102))])

    let countBeforeFrameHighlight = await backend.sentTargetMessages().count
    let frameHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: frameHTMLID)
    }
    let frameHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeFrameHighlight
    )
    #expect(frameHighlight.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetReply(
        transport,
        targetID: frameHighlight.targetIdentifier,
        messageID: try messageID(frameHighlight.message),
        result: "{}"
    )
    await frameHighlightTask.value

    let countBeforePageHighlight = await backend.sentTargetMessages().count
    let pageHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: pageHTMLID)
    }
    let frameHide = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: countBeforePageHighlight
    )
    #expect(frameHide.targetIdentifier == ProtocolTarget.ID.frameAd)
    let countBeforeFrameHideReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: frameHide.targetIdentifier,
        messageID: try messageID(frameHide.message),
        result: "{}"
    )
    let pageHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeFrameHideReply
    )
    #expect(pageHighlight.targetIdentifier == ProtocolTarget.ID.pageMain)
    #expect(try integerParameter("nodeId", in: pageHighlight.message) == 2)
    await receiveTargetReply(
        transport,
        targetID: pageHighlight.targetIdentifier,
        messageID: try messageID(pageHighlight.message),
        result: "{}"
    )
    await pageHighlightTask.value
}

@Test
func staleHideReplyDoesNotForgetNewerHighlightOnSameTarget() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let pageHTMLID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#,
        in: session
    )
    _ = await session.attachment.dom.replaceDocumentRoot(
        WebInspectorCore.DOMNode.Payload(
            nodeID: .init(101),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                WebInspectorCore.DOMNode.Payload(nodeID: .init(102), nodeType: .element, nodeName: "HTML", localName: "html"),
            ])
        ),
        targetID: .frameAd
    )
    let frameHTMLID = try #require(await session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(102))])

    let countBeforeInitialHighlight = await backend.sentTargetMessages().count
    let initialHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: pageHTMLID)
    }
    let initialHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeInitialHighlight
    )
    #expect(initialHighlight.targetIdentifier == ProtocolTarget.ID.pageMain)
    await receiveTargetReply(
        transport,
        targetID: initialHighlight.targetIdentifier,
        messageID: try messageID(initialHighlight.message),
        result: "{}"
    )
    await initialHighlightTask.value

    let countBeforeHide = await backend.sentTargetMessages().count
    let hideTask = Task {
        await session.attachment.dom.hideNodeHighlight()
    }
    let staleHide = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: countBeforeHide
    )
    #expect(staleHide.targetIdentifier == ProtocolTarget.ID.pageMain)

    let countBeforeReplacementHighlight = await backend.sentTargetMessages().count
    let replacementHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: pageHTMLID)
    }
    let replacementHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeReplacementHighlight
    )
    #expect(replacementHighlight.targetIdentifier == ProtocolTarget.ID.pageMain)
    await receiveTargetReply(
        transport,
        targetID: replacementHighlight.targetIdentifier,
        messageID: try messageID(replacementHighlight.message),
        result: "{}"
    )
    await replacementHighlightTask.value

    await receiveTargetReply(
        transport,
        targetID: staleHide.targetIdentifier,
        messageID: try messageID(staleHide.message),
        result: "{}"
    )
    await hideTask.value

    let countBeforeFrameHighlight = await backend.sentTargetMessages().count
    let frameHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: frameHTMLID)
    }
    let pageHide = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: countBeforeFrameHighlight
    )
    #expect(pageHide.targetIdentifier == ProtocolTarget.ID.pageMain)
    let countBeforePageHideReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: pageHide.targetIdentifier,
        messageID: try messageID(pageHide.message),
        result: "{}"
    )
    let frameHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforePageHideReply
    )
    #expect(frameHighlight.targetIdentifier == ProtocolTarget.ID.frameAd)
    #expect(try integerParameter("nodeId", in: frameHighlight.message) == 102)
    await receiveTargetReply(
        transport,
        targetID: frameHighlight.targetIdentifier,
        messageID: try messageID(frameHighlight.message),
        result: "{}"
    )
    await frameHighlightTask.value
}

@Test
func cancelledDirectHighlightDoesNotRecordError() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let htmlID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))

    let countBeforeHighlight = await backend.sentTargetMessages().count
    let highlightTask = Task {
        await session.attachment.dom.highlightNode(for: htmlID)
    }
    let highlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeHighlight
    )
    #expect(highlight.targetIdentifier == ProtocolTarget.ID.pageMain)

    highlightTask.cancel()
    await highlightTask.value

    #expect(await session.lastError == nil)
}

@Test
func documentInvalidationHidesSelectedNodeHighlight() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let htmlID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    await session.attachment.dom.selectNode(htmlID)

    let countBeforeHighlight = await backend.sentTargetMessages().count
    let highlightTask = Task {
        await session.attachment.dom.highlightNode(for: htmlID, owner: .selection)
    }
    let highlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeHighlight
    )
    #expect(highlight.targetIdentifier == ProtocolTarget.ID.pageMain)
    await receiveTargetReply(
        transport,
        targetID: highlight.targetIdentifier,
        messageID: try messageID(highlight.message),
        result: "{}"
    )
    await highlightTask.value

    let countBeforeInvalidation = await backend.sentTargetMessages().count
    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.documentUpdated","params":{}}"#,
        in: session
    )
    let hideHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: countBeforeInvalidation
    )
    #expect(hideHighlight.targetIdentifier == ProtocolTarget.ID.pageMain)
    await receiveTargetReply(
        transport,
        targetID: hideHighlight.targetIdentifier,
        messageID: try messageID(hideHighlight.message),
        result: "{}"
    )
    #expect(await session.attachment.dom.selectedNodeID == nil)
}

@Test
func selectionClearHidesInFlightSelectedNodeHighlight() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let htmlID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    await session.attachment.dom.selectNode(htmlID)

    let countBeforeHighlight = await backend.sentTargetMessages().count
    let highlightTask = Task {
        await session.attachment.dom.highlightNode(for: htmlID, owner: .selection)
    }
    let highlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeHighlight
    )
    #expect(highlight.targetIdentifier == ProtocolTarget.ID.pageMain)

    let countBeforeSelectionClear = await backend.sentTargetMessages().count
    await session.attachment.dom.selectNode(nil)
    await receiveTargetReply(
        transport,
        targetID: highlight.targetIdentifier,
        messageID: try messageID(highlight.message),
        result: "{}"
    )
    await highlightTask.value
    let hideHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: countBeforeSelectionClear
    )
    #expect(hideHighlight.targetIdentifier == ProtocolTarget.ID.pageMain)
    await receiveTargetReply(
        transport,
        targetID: hideHighlight.targetIdentifier,
        messageID: try messageID(hideHighlight.message),
        result: "{}"
    )
    #expect(await session.attachment.dom.selectedNodeID == nil)
}

@Test
func staleSelectionClearDoesNotHideNewerSameTargetHighlight() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let htmlID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))

    let countBeforeInitialHighlight = await backend.sentTargetMessages().count
    let initialHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: htmlID)
    }
    let initialHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeInitialHighlight
    )
    await receiveTargetReply(
        transport,
        targetID: initialHighlight.targetIdentifier,
        messageID: try messageID(initialHighlight.message),
        result: "{}"
    )
    await initialHighlightTask.value
    let staleGeneration = try #require(await session.attachment.dom.highlightController.possibleVisibleGeneration(targetID: .pageMain))

    let countBeforeNewerHighlight = await backend.sentTargetMessages().count
    let newerHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: htmlID)
    }
    let newerHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeNewerHighlight
    )

    let countBeforeStaleClear = await backend.sentTargetMessages().count
    await session.attachment.dom.hideNodeHighlightIfCurrent(targetID: .pageMain, generation: staleGeneration)
    #expect(await backend.sentTargetMessages().count == countBeforeStaleClear)

    await receiveTargetReply(
        transport,
        targetID: newerHighlight.targetIdentifier,
        messageID: try messageID(newerHighlight.message),
        result: "{}"
    )
    await newerHighlightTask.value
}

@Test
func selectionClearDoesNotHideNewerTransientHighlightOnSameTarget() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let htmlID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))

    await session.attachment.dom.selectNode(htmlID)
    let countBeforeSelectionHighlight = await backend.sentTargetMessages().count
    let selectionHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: htmlID, owner: .selection)
    }
    let selectionHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeSelectionHighlight
    )
    await receiveTargetReply(
        transport,
        targetID: selectionHighlight.targetIdentifier,
        messageID: try messageID(selectionHighlight.message),
        result: "{}"
    )
    await selectionHighlightTask.value

    let countBeforeTransientHighlight = await backend.sentTargetMessages().count
    let transientHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: bodyID, owner: .transient)
    }
    let transientHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeTransientHighlight
    )
    #expect(try integerParameter("nodeId", in: transientHighlight.message) == 4)

    let countBeforeSelectionClear = await backend.sentTargetMessages().count
    await session.attachment.dom.selectNode(nil)
    await Task.yield()

    #expect(await backend.sentTargetMessages().count == countBeforeSelectionClear)
    #expect(await session.attachment.dom.highlightController.possibleVisibleNodeID(targetID: .pageMain) == bodyID)
    #expect(await session.attachment.dom.highlightController.possibleVisibleOwner(targetID: .pageMain) == .transient)

    await receiveTargetReply(
        transport,
        targetID: transientHighlight.targetIdentifier,
        messageID: try messageID(transientHighlight.message),
        result: "{}"
    )
    await transientHighlightTask.value
}

@Test
func staleSelectionClearRestoresCurrentSelectionHighlight() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let htmlID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))

    await session.attachment.dom.selectNode(htmlID)
    let countBeforeInitialHighlight = await backend.sentTargetMessages().count
    let initialHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: htmlID)
    }
    let initialHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeInitialHighlight
    )
    await receiveTargetReply(
        transport,
        targetID: initialHighlight.targetIdentifier,
        messageID: try messageID(initialHighlight.message),
        result: "{}"
    )
    await initialHighlightTask.value
    let staleGeneration = try #require(await session.attachment.dom.highlightController.possibleVisibleGeneration(targetID: .pageMain))

    await session.attachment.dom.selectNode(bodyID)
    let countBeforeStaleClear = await backend.sentTargetMessages().count
    let staleClearTask = Task {
        await session.attachment.dom.hideNodeHighlightIfCurrent(targetID: .pageMain, generation: staleGeneration)
    }
    let restoredHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeStaleClear
    )
    #expect(restoredHighlight.targetIdentifier == ProtocolTarget.ID.pageMain)
    #expect(try integerParameter("nodeId", in: restoredHighlight.message) == 4)
    await receiveTargetReply(
        transport,
        targetID: restoredHighlight.targetIdentifier,
        messageID: try messageID(restoredHighlight.message),
        result: "{}"
    )
    await staleClearTask.value
}

@Test
func staleSelectionClearDoesNotRestoreSelectionOverNewerHighlight() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let htmlID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))

    await session.attachment.dom.selectNode(htmlID)
    let countBeforeInitialHighlight = await backend.sentTargetMessages().count
    let initialHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: htmlID)
    }
    let initialHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeInitialHighlight
    )
    await receiveTargetReply(
        transport,
        targetID: initialHighlight.targetIdentifier,
        messageID: try messageID(initialHighlight.message),
        result: "{}"
    )
    await initialHighlightTask.value
    let staleGeneration = try #require(await session.attachment.dom.highlightController.possibleVisibleGeneration(targetID: .pageMain))

    await session.attachment.dom.selectNode(bodyID)
    let countBeforeNewerHighlight = await backend.sentTargetMessages().count
    let newerHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: htmlID)
    }
    let newerHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeNewerHighlight
    )

    let countBeforeStaleClear = await backend.sentTargetMessages().count
    await session.attachment.dom.hideNodeHighlightIfCurrent(targetID: .pageMain, generation: staleGeneration)
    #expect(await backend.sentTargetMessages().count == countBeforeStaleClear)

    await receiveTargetReply(
        transport,
        targetID: newerHighlight.targetIdentifier,
        messageID: try messageID(newerHighlight.message),
        result: "{}"
    )
    await newerHighlightTask.value
}

@Test
func directHighlightStopsWhenCancelledDuringStaleHide() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let pageHTMLID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#,
        in: session
    )
    _ = await session.attachment.dom.replaceDocumentRoot(
        WebInspectorCore.DOMNode.Payload(
            nodeID: .init(101),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                WebInspectorCore.DOMNode.Payload(nodeID: .init(102), nodeType: .element, nodeName: "HTML", localName: "html"),
            ])
        ),
        targetID: .frameAd
    )
    let frameHTMLID = try #require(await session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(102))])

    let countBeforeFrameHighlight = await backend.sentTargetMessages().count
    let frameHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: frameHTMLID)
    }
    let frameHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeFrameHighlight
    )
    #expect(frameHighlight.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetReply(
        transport,
        targetID: frameHighlight.targetIdentifier,
        messageID: try messageID(frameHighlight.message),
        result: "{}"
    )
    await frameHighlightTask.value

    let countBeforePageHighlight = await backend.sentTargetMessages().count
    let pageHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: pageHTMLID)
    }
    let frameHide = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: countBeforePageHighlight
    )
    #expect(frameHide.targetIdentifier == ProtocolTarget.ID.frameAd)

    pageHighlightTask.cancel()
    let countBeforeHideReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: frameHide.targetIdentifier,
        messageID: try messageID(frameHide.message),
        result: "{}"
    )
    await pageHighlightTask.value
    #expect(await backend.sentTargetMessages().count == countBeforeHideReply)
}

@Test
func cancelledStaleHideStopsBeforeClearingNextTarget() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let pageHTMLID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#,
        in: session
    )
    _ = await session.attachment.dom.replaceDocumentRoot(
        WebInspectorCore.DOMNode.Payload(
            nodeID: .init(101),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                WebInspectorCore.DOMNode.Payload(nodeID: .init(102), nodeType: .element, nodeName: "HTML", localName: "html"),
            ])
        ),
        targetID: .frameAd
    )
    let frameHTMLID = try #require(await session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(102))])

    let countBeforeFrameHighlight = await backend.sentTargetMessages().count
    let frameHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: frameHTMLID)
    }
    let frameHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeFrameHighlight
    )
    await receiveTargetReply(
        transport,
        targetID: frameHighlight.targetIdentifier,
        messageID: try messageID(frameHighlight.message),
        result: "{}"
    )
    await frameHighlightTask.value

    let countBeforePageHighlight = await backend.sentTargetMessages().count
    let pageHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: pageHTMLID)
    }
    let failedFrameHide = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: countBeforePageHighlight
    )
    #expect(failedFrameHide.targetIdentifier == ProtocolTarget.ID.frameAd)
    let countBeforeFailedFrameHideReply = await backend.sentTargetMessages().count
    await receiveTargetErrorReply(
        transport,
        targetID: failedFrameHide.targetIdentifier,
        messageID: try messageID(failedFrameHide.message),
        message: "Cannot hide frame highlight"
    )
    let pageHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeFailedFrameHideReply
    )
    #expect(pageHighlight.targetIdentifier == ProtocolTarget.ID.pageMain)
    await receiveTargetReply(
        transport,
        targetID: pageHighlight.targetIdentifier,
        messageID: try messageID(pageHighlight.message),
        result: "{}"
    )
    await pageHighlightTask.value

    let countBeforeHideAll = await backend.sentTargetMessages().count
    let hideTask = Task {
        await session.attachment.dom.hideNodeHighlight()
    }
    let frameHide = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: countBeforeHideAll
    )
    #expect(frameHide.targetIdentifier == ProtocolTarget.ID.frameAd)

    hideTask.cancel()
    let countBeforeFrameHideReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: frameHide.targetIdentifier,
        messageID: try messageID(frameHide.message),
        result: "{}"
    )
    await hideTask.value
    #expect(await backend.sentTargetMessages().count == countBeforeFrameHideReply)
}

@Test
func staleHideSnapshotDoesNotHideNewerLaterTargetHighlight() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#,
        in: session
    )

    await session.attachment.dom.highlightController.markHighlightMayBeVisible(targetID: .frameAd)
    await session.attachment.dom.highlightController.markHighlightMayBeVisible(targetID: .pageMain)
    let stalePageGeneration = try #require(await session.attachment.dom.highlightController.possibleVisibleGeneration(targetID: .pageMain))

    let countBeforeHideAll = await backend.sentTargetMessages().count
    let hideTask = Task {
        await session.attachment.dom.hideNodeHighlight()
    }
    let frameHide = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: countBeforeHideAll
    )
    #expect(frameHide.targetIdentifier == ProtocolTarget.ID.frameAd)

    await session.attachment.dom.highlightController.markHighlightMayBeVisible(targetID: .pageMain)
    let newerPageGeneration = try #require(await session.attachment.dom.highlightController.possibleVisibleGeneration(targetID: .pageMain))
    #expect(newerPageGeneration != stalePageGeneration)

    let countBeforeFrameHideReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: frameHide.targetIdentifier,
        messageID: try messageID(frameHide.message),
        result: "{}"
    )
    await hideTask.value

    #expect(await backend.sentTargetMessages().count == countBeforeFrameHideReply)
    #expect(await session.attachment.dom.highlightController.possibleVisibleGeneration(targetID: .pageMain) == newerPageGeneration)
}

@Test
func directHighlightDoesNotHideStaleHighlightWhilePickerIsActive() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let pageHTMLID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#,
        in: session
    )
    await session.attachment.dom.highlightController.markHighlightMayBeVisible(targetID: .frameAd)
    await MainActor.run {
        session.attachment.dom.isSelectingElement = true
    }

    let countBeforeHighlight = await backend.sentTargetMessages().count
    await session.attachment.dom.highlightNode(for: pageHTMLID)

    #expect(await backend.sentTargetMessages().count == countBeforeHighlight)
}

@Test
func directHighlightStopsWhenPickerStartsDuringStaleHide() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let pageHTMLID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#,
        in: session
    )
    _ = await session.attachment.dom.replaceDocumentRoot(
        WebInspectorCore.DOMNode.Payload(
            nodeID: .init(101),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                WebInspectorCore.DOMNode.Payload(nodeID: .init(102), nodeType: .element, nodeName: "HTML", localName: "html"),
            ])
        ),
        targetID: .frameAd
    )
    let frameHTMLID = try #require(await session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(102))])

    let countBeforeFrameHighlight = await backend.sentTargetMessages().count
    let frameHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: frameHTMLID)
    }
    let frameHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeFrameHighlight
    )
    #expect(frameHighlight.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetReply(
        transport,
        targetID: frameHighlight.targetIdentifier,
        messageID: try messageID(frameHighlight.message),
        result: "{}"
    )
    await frameHighlightTask.value

    let countBeforePageHighlight = await backend.sentTargetMessages().count
    let pageHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: pageHTMLID)
    }
    let originalFrameHide = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: countBeforePageHighlight
    )
    #expect(originalFrameHide.targetIdentifier == ProtocolTarget.ID.frameAd)

    let countBeforeBeginPicker = await backend.sentTargetMessages().count
    let beginPickerTask = Task {
        try await session.attachment.dom.beginElementPicker()
    }
    let pickerFrameHide = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: countBeforeBeginPicker
    )
    #expect(pickerFrameHide.targetIdentifier == ProtocolTarget.ID.frameAd)
    let countBeforePickerHideReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: pickerFrameHide.targetIdentifier,
        messageID: try messageID(pickerFrameHide.message),
        result: "{}"
    )
    let enable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: countBeforePickerHideReply
    )
    await receiveTargetReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        result: "{}"
    )
    try await beginPickerTask.value
    #expect(await session.attachment.dom.isSelectingElement)

    let countBeforeOriginalHideReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: originalFrameHide.targetIdentifier,
        messageID: try messageID(originalFrameHide.message),
        result: "{}"
    )
    await pageHighlightTask.value
    #expect(await backend.sentTargetMessages().count == countBeforeOriginalHideReply)
}

@Test
func beginElementPickerDoesNotEnableInspectModeAfterCancelDuringStaleHide() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let pageHTMLID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))

    let countBeforeHighlight = await backend.sentTargetMessages().count
    let highlightTask = Task {
        await session.attachment.dom.highlightNode(for: pageHTMLID)
    }
    let highlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeHighlight
    )
    #expect(highlight.targetIdentifier == ProtocolTarget.ID.pageMain)
    await receiveTargetReply(
        transport,
        targetID: highlight.targetIdentifier,
        messageID: try messageID(highlight.message),
        result: "{}"
    )
    await highlightTask.value

    let countBeforeBeginPicker = await backend.sentTargetMessages().count
    let beginPickerTask = Task {
        try await session.attachment.dom.beginElementPicker()
    }
    let beginHide = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: countBeforeBeginPicker
    )
    #expect(beginHide.targetIdentifier == ProtocolTarget.ID.pageMain)

    let countBeforeCancel = await backend.sentTargetMessages().count
    let cancelTask = Task {
        await session.attachment.dom.cancelElementPicker()
    }
    let disable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: countBeforeCancel
    )
    #expect(try boolParameter("enabled", in: disable.message) == false)
    let countBeforeDisableReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: disable.targetIdentifier,
        messageID: try messageID(disable.message),
        result: "{}"
    )
    let cancelHide = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: countBeforeDisableReply
    )
    #expect(cancelHide.targetIdentifier == ProtocolTarget.ID.pageMain)
    await receiveTargetReply(
        transport,
        targetID: cancelHide.targetIdentifier,
        messageID: try messageID(cancelHide.message),
        result: "{}"
    )
    await cancelTask.value

    let countBeforeBeginHideReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: beginHide.targetIdentifier,
        messageID: try messageID(beginHide.message),
        result: "{}"
    )
    try await beginPickerTask.value
    #expect(await session.attachment.dom.isSelectingElement == false)
    #expect(await backend.sentTargetMessages().count == countBeforeBeginHideReply)
}

@Test
func beginElementPickerRestoresSelectedHighlightWhenEnableFails() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let pageHTMLID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    await session.attachment.dom.selectNode(pageHTMLID)

    let countBeforeHighlight = await backend.sentTargetMessages().count
    let highlightTask = Task {
        await session.attachment.dom.highlightNode(for: pageHTMLID)
    }
    let highlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeHighlight
    )
    await receiveTargetReply(
        transport,
        targetID: highlight.targetIdentifier,
        messageID: try messageID(highlight.message),
        result: "{}"
    )
    await highlightTask.value

    let countBeforeBeginPicker = await backend.sentTargetMessages().count
    let beginPickerTask = Task {
        try await session.attachment.dom.beginElementPicker()
    }
    let beginHide = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: countBeforeBeginPicker
    )
    #expect(beginHide.targetIdentifier == ProtocolTarget.ID.pageMain)
    let countBeforeBeginHideReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: beginHide.targetIdentifier,
        messageID: try messageID(beginHide.message),
        result: "{}"
    )
    let enable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: countBeforeBeginHideReply
    )
    #expect(try boolParameter("enabled", in: enable.message) == true)
    let countBeforeEnableError = await backend.sentTargetMessages().count
    await receiveTargetErrorReply(
        transport,
        targetID: enable.targetIdentifier,
        messageID: try messageID(enable.message),
        message: "Cannot enable inspect mode"
    )
    let restoredHighlight = try await waitForBackendTargetMessage(
        backend,
        method: "DOM.highlightNode",
        ordinal: 0,
        after: countBeforeEnableError,
        timeout: .seconds(15)
    )
    #expect(restoredHighlight.targetIdentifier == ProtocolTarget.ID.pageMain)
    #expect(try integerParameter("nodeId", in: restoredHighlight.message) == 2)
    await receiveTargetReply(
        transport,
        targetID: restoredHighlight.targetIdentifier,
        messageID: try messageID(restoredHighlight.message),
        result: "{}"
    )
    do {
        try await beginPickerTask.value
        Issue.record("Expected beginElementPicker to fail")
    } catch {
    }
    #expect(await session.attachment.dom.isSelectingElement == false)
}

@Test
func cancelledBeginElementPickerDoesNotEnableInspectModeAfterStaleHide() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let pageHTMLID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))

    let countBeforeHighlight = await backend.sentTargetMessages().count
    let highlightTask = Task {
        await session.attachment.dom.highlightNode(for: pageHTMLID)
    }
    let highlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeHighlight
    )
    await receiveTargetReply(
        transport,
        targetID: highlight.targetIdentifier,
        messageID: try messageID(highlight.message),
        result: "{}"
    )
    await highlightTask.value

    let countBeforeBeginPicker = await backend.sentTargetMessages().count
    let beginPickerTask = Task {
        try await session.attachment.dom.beginElementPicker()
    }
    let beginHide = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: countBeforeBeginPicker
    )
    #expect(beginHide.targetIdentifier == ProtocolTarget.ID.pageMain)

    let countBeforeCancel = await backend.sentTargetMessages().count
    beginPickerTask.cancel()
    await receiveTargetReply(
        transport,
        targetID: beginHide.targetIdentifier,
        messageID: try messageID(beginHide.message),
        result: "{}"
    )
    try await beginPickerTask.value
    #expect(await session.attachment.dom.isSelectingElement == false)
    #expect(await backend.sentTargetMessages().count == countBeforeCancel)
}

@Test
func cancelledBeginElementPickerRestoresSelectedHighlightAfterStaleHide() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let pageHTMLID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    await session.attachment.dom.selectNode(pageHTMLID)

    let countBeforeHighlight = await backend.sentTargetMessages().count
    let highlightTask = Task {
        await session.attachment.dom.highlightNode(for: pageHTMLID)
    }
    let highlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeHighlight
    )
    await receiveTargetReply(
        transport,
        targetID: highlight.targetIdentifier,
        messageID: try messageID(highlight.message),
        result: "{}"
    )
    await highlightTask.value

    let countBeforeBeginPicker = await backend.sentTargetMessages().count
    let beginPickerTask = Task {
        try await session.attachment.dom.beginElementPicker()
    }
    let beginHide = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: countBeforeBeginPicker
    )
    #expect(beginHide.targetIdentifier == ProtocolTarget.ID.pageMain)

    let countBeforeCancel = await backend.sentTargetMessages().count
    beginPickerTask.cancel()
    await receiveTargetReply(
        transport,
        targetID: beginHide.targetIdentifier,
        messageID: try messageID(beginHide.message),
        result: "{}"
    )
    let restoredHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeCancel
    )
    #expect(restoredHighlight.targetIdentifier == ProtocolTarget.ID.pageMain)
    #expect(try integerParameter("nodeId", in: restoredHighlight.message) == 2)
    await receiveTargetReply(
        transport,
        targetID: restoredHighlight.targetIdentifier,
        messageID: try messageID(restoredHighlight.message),
        result: "{}"
    )
    try await beginPickerTask.value
    #expect(await session.attachment.dom.isSelectingElement == false)
}

@Test
func cancelledBeginElementPickerRestoresSelectedHighlightAfterEnableCancellation() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let pageHTMLID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    await session.attachment.dom.selectNode(pageHTMLID)

    let countBeforeHighlight = await backend.sentTargetMessages().count
    let highlightTask = Task {
        await session.attachment.dom.highlightNode(for: pageHTMLID)
    }
    let highlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeHighlight
    )
    await receiveTargetReply(
        transport,
        targetID: highlight.targetIdentifier,
        messageID: try messageID(highlight.message),
        result: "{}"
    )
    await highlightTask.value

    let countBeforeBeginPicker = await backend.sentTargetMessages().count
    let beginPickerTask = Task {
        try await session.attachment.dom.beginElementPicker()
    }
    let beginHide = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: countBeforeBeginPicker
    )
    #expect(beginHide.targetIdentifier == ProtocolTarget.ID.pageMain)
    let countBeforeBeginHideReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: beginHide.targetIdentifier,
        messageID: try messageID(beginHide.message),
        result: "{}"
    )
    let enable = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: countBeforeBeginHideReply
    )
    #expect(try boolParameter("enabled", in: enable.message) == true)

    let countBeforeCancel = await backend.sentTargetMessages().count
    beginPickerTask.cancel()
    let restoredHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeCancel
    )
    #expect(restoredHighlight.targetIdentifier == ProtocolTarget.ID.pageMain)
    #expect(try integerParameter("nodeId", in: restoredHighlight.message) == 2)
    await receiveTargetReply(
        transport,
        targetID: restoredHighlight.targetIdentifier,
        messageID: try messageID(restoredHighlight.message),
        result: "{}"
    )
    do {
        try await beginPickerTask.value
        Issue.record("Expected beginElementPicker to fail")
    } catch {
    }
    #expect(await session.attachment.dom.isSelectingElement == false)
}

@Test
func cancelledDirectHighlightIsHiddenBeforeRestoringSelection() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let pageHTMLID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#,
        in: session
    )
    _ = await session.attachment.dom.replaceDocumentRoot(
        WebInspectorCore.DOMNode.Payload(
            nodeID: .init(101),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                WebInspectorCore.DOMNode.Payload(nodeID: .init(102), nodeType: .element, nodeName: "HTML", localName: "html"),
            ])
        ),
        targetID: .frameAd
    )
    let frameHTMLID = try #require(await session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(102))])
    await session.attachment.dom.selectNode(frameHTMLID)

    let countBeforeHoverHighlight = await backend.sentTargetMessages().count
    let hoverHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: pageHTMLID)
    }
    let pageHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeHoverHighlight
    )
    #expect(pageHighlight.targetIdentifier == ProtocolTarget.ID.pageMain)
    #expect(try integerParameter("nodeId", in: pageHighlight.message) == 2)

    hoverHighlightTask.cancel()
    await hoverHighlightTask.value
    await receiveTargetReply(
        transport,
        targetID: pageHighlight.targetIdentifier,
        messageID: try messageID(pageHighlight.message),
        result: "{}"
    )

    let countBeforeRestore = await backend.sentTargetMessages().count
    let restoreTask = Task {
        await session.attachment.dom.restoreSelectedNodeHighlightOrHide()
    }
    let pageHide = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: countBeforeRestore
    )
    #expect(pageHide.targetIdentifier == ProtocolTarget.ID.pageMain)
    let countBeforePageHideReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: pageHide.targetIdentifier,
        messageID: try messageID(pageHide.message),
        result: "{}"
    )
    let frameHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforePageHideReply
    )
    #expect(frameHighlight.targetIdentifier == ProtocolTarget.ID.frameAd)
    #expect(try integerParameter("nodeId", in: frameHighlight.message) == 102)
    await receiveTargetReply(
        transport,
        targetID: frameHighlight.targetIdentifier,
        messageID: try messageID(frameHighlight.message),
        result: "{}"
    )
    await restoreTask.value
}

@Test
func directHighlightSkipsDestroyedPreviousTarget() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let pageHTMLID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#,
        in: session
    )
    _ = await session.attachment.dom.replaceDocumentRoot(
        WebInspectorCore.DOMNode.Payload(
            nodeID: .init(101),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                WebInspectorCore.DOMNode.Payload(nodeID: .init(102), nodeType: .element, nodeName: "HTML", localName: "html"),
            ])
        ),
        targetID: .frameAd
    )
    let frameHTMLID = try #require(await session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(102))])

    let countBeforeFrameHighlight = await backend.sentTargetMessages().count
    let frameHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: frameHTMLID)
    }
    let frameHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeFrameHighlight
    )
    #expect(frameHighlight.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetReply(
        transport,
        targetID: frameHighlight.targetIdentifier,
        messageID: try messageID(frameHighlight.message),
        result: "{}"
    )
    await frameHighlightTask.value
    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetDestroyed","params":{"targetId":"frame-ad"}}"#,
        in: session
    )

    let countBeforePageHighlight = await backend.sentTargetMessages().count
    let pageHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: pageHTMLID)
    }
    let pageHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforePageHighlight
    )
    #expect(pageHighlight.targetIdentifier == ProtocolTarget.ID.pageMain)
    #expect(try integerParameter("nodeId", in: pageHighlight.message) == 2)
    let newMethods = await backend.sentTargetMessages()
        .dropFirst(countBeforePageHighlight)
        .compactMap { try? messageMethod($0.message) }
    #expect(newMethods == ["DOM.highlightNode"])
    await receiveTargetReply(
        transport,
        targetID: pageHighlight.targetIdentifier,
        messageID: try messageID(pageHighlight.message),
        result: "{}"
    )
    await pageHighlightTask.value
    #expect(await session.lastError == nil)
}

@Test
func restoreSelectedFrameHighlightHidesPageHoverHighlight() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let pageHTMLID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#,
        in: session
    )
    _ = await session.attachment.dom.replaceDocumentRoot(
        WebInspectorCore.DOMNode.Payload(
            nodeID: .init(101),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                WebInspectorCore.DOMNode.Payload(nodeID: .init(102), nodeType: .element, nodeName: "HTML", localName: "html"),
            ])
        ),
        targetID: .frameAd
    )
    let frameHTMLID = try #require(await session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(102))])
    await session.attachment.dom.selectNode(frameHTMLID)

    let countBeforeHoverHighlight = await backend.sentTargetMessages().count
    let hoverHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: pageHTMLID)
    }
    let hoverHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeHoverHighlight
    )
    #expect(hoverHighlight.targetIdentifier == ProtocolTarget.ID.pageMain)
    #expect(try integerParameter("nodeId", in: hoverHighlight.message) == 2)
    await receiveTargetReply(
        transport,
        targetID: hoverHighlight.targetIdentifier,
        messageID: try messageID(hoverHighlight.message),
        result: "{}"
    )
    await hoverHighlightTask.value

    let countBeforeRestore = await backend.sentTargetMessages().count
    let restoreTask = Task {
        await session.attachment.dom.restoreSelectedNodeHighlightOrHide()
    }
    let pageHide = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: countBeforeRestore
    )
    #expect(pageHide.targetIdentifier == ProtocolTarget.ID.pageMain)
    let countBeforePageHideReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: pageHide.targetIdentifier,
        messageID: try messageID(pageHide.message),
        result: "{}"
    )
    let frameHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforePageHideReply
    )
    #expect(frameHighlight.targetIdentifier == ProtocolTarget.ID.frameAd)
    #expect(try integerParameter("nodeId", in: frameHighlight.message) == 102)
    await receiveTargetReply(
        transport,
        targetID: frameHighlight.targetIdentifier,
        messageID: try messageID(frameHighlight.message),
        result: "{}"
    )
    await restoreTask.value
}

@Test
func restoreSelectedHighlightStopsWhenSelectionChangesDuringStaleHide() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let pageHTMLID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#,
        in: session
    )
    _ = await session.attachment.dom.replaceDocumentRoot(
        WebInspectorCore.DOMNode.Payload(
            nodeID: .init(101),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                WebInspectorCore.DOMNode.Payload(nodeID: .init(102), nodeType: .element, nodeName: "HTML", localName: "html"),
            ])
        ),
        targetID: .frameAd
    )
    let frameHTMLID = try #require(await session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(102))])
    await session.attachment.dom.selectNode(frameHTMLID)

    let countBeforeHoverHighlight = await backend.sentTargetMessages().count
    let hoverHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: pageHTMLID)
    }
    let hoverHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeHoverHighlight
    )
    #expect(hoverHighlight.targetIdentifier == ProtocolTarget.ID.pageMain)
    await receiveTargetReply(
        transport,
        targetID: hoverHighlight.targetIdentifier,
        messageID: try messageID(hoverHighlight.message),
        result: "{}"
    )
    await hoverHighlightTask.value

    let countBeforeRestore = await backend.sentTargetMessages().count
    let restoreTask = Task {
        await session.attachment.dom.restoreSelectedNodeHighlightOrHide()
    }
    let pageHide = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: countBeforeRestore
    )
    #expect(pageHide.targetIdentifier == ProtocolTarget.ID.pageMain)

    await session.attachment.dom.selectNode(pageHTMLID)
    let countBeforeReplacementHighlight = await backend.sentTargetMessages().count
    let replacementHighlightTask = Task {
        await session.attachment.dom.highlightNode(for: pageHTMLID)
    }
    let replacementHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.highlightNode",
        after: countBeforeReplacementHighlight
    )
    #expect(replacementHighlight.targetIdentifier == ProtocolTarget.ID.pageMain)
    #expect(try integerParameter("nodeId", in: replacementHighlight.message) == 2)
    await receiveTargetReply(
        transport,
        targetID: replacementHighlight.targetIdentifier,
        messageID: try messageID(replacementHighlight.message),
        result: "{}"
    )
    await replacementHighlightTask.value

    let countBeforeHideReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: pageHide.targetIdentifier,
        messageID: try messageID(pageHide.message),
        result: "{}"
    )
    await restoreTask.value
    #expect(await backend.sentTargetMessages().count == countBeforeHideReply)
}

@Test
func inspectorInspectWaitsForPathPushEventsBeforeSelectingNode() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    await receiveAndApplyRuntimeContextCreated(transport, contextID: 7, in: session)
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
    try await replyToPickerDisableAndRestoredHighlight(
        disable,
        transport: transport,
        backend: backend,
        expectedTargetID: .pageMain,
        expectedNodeID: 3
    )

    await session.attachment.dom.waitUntilElementPickerIdle()
    let selectedNode = try #require(await session.attachment.dom.selectedNode)
    #expect(await selectedNode.attributes == [WebInspectorCore.DOMNode.Attribute(name: "id", value: "selected-after-path-push")])
    #expect(await session.attachment.dom.isSelectingElement == false)
}

@Test
func inspectorInspectRecordedExecutionContextOverridesEventTargetHint() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#,
        in: session
    )
    #expect(await session.attachment.dom.snapshot().targetsByID[.frameAd] != nil)
    _ = await session.attachment.dom.replaceDocumentRoot(
        WebInspectorCore.DOMNode.Payload(
            nodeID: .init(1),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                WebInspectorCore.DOMNode.Payload(nodeID: .init(2), nodeType: .element, nodeName: "HTML", localName: "html"),
            ])
        ),
        targetID: .frameAd
    )
    await receiveAndApplyRuntimeContextCreated(
        transport,
        targetID: .frameAd,
        contextID: 77,
        frameID: "ad-frame",
        in: session
    )
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
    #expect(requestNode.targetIdentifier == ProtocolTarget.ID.frameAd)

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
    try await replyToPickerDisableAndRestoredHighlight(
        disable,
        transport: transport,
        backend: backend,
        expectedTargetID: .frameAd,
        expectedNodeID: 3
    )

    await session.attachment.dom.waitUntilElementPickerIdle()
    let selectedNode = try #require(await session.attachment.dom.selectedNode)
    #expect(await selectedNode.nodeName == "DIV")
    #expect(await session.attachment.dom.isSelectingElement == false)
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
    #expect(requestNode.targetIdentifier == ProtocolTarget.ID.pageMain)
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
    try await replyToPickerDisableAndRestoredHighlight(
        disable,
        transport: transport,
        backend: backend,
        expectedTargetID: .pageMain,
        expectedNodeID: 3
    )

    await session.attachment.dom.waitUntilElementPickerIdle()
    let selectedNode = try #require(await session.attachment.dom.selectedNode)
    #expect(await selectedNode.nodeName == "DIV")
    #expect(await session.attachment.dom.isSelectingElement == false)
}

@Test
func targetScopedInspectorInspectUsesEventTargetAsFallback() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#,
        in: session
    )
    _ = await session.attachment.dom.replaceDocumentRoot(
        WebInspectorCore.DOMNode.Payload(
            nodeID: .init(1),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                WebInspectorCore.DOMNode.Payload(nodeID: .init(2), nodeType: .element, nodeName: "HTML", localName: "html"),
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
    #expect(requestNode.targetIdentifier == ProtocolTarget.ID.frameAd)

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
    try await replyToPickerDisableAndRestoredHighlight(
        disable,
        transport: transport,
        backend: backend,
        expectedTargetID: .frameAd,
        expectedNodeID: 3
    )

    await session.attachment.dom.waitUntilElementPickerIdle()
    let selectedNode = try #require(await session.attachment.dom.selectedNode)
    #expect(await selectedNode.nodeName == "DIV")
    #expect(await session.attachment.dom.isSelectingElement == false)
}

@Test
func targetScopedInspectorInspectFallsBackToEventTargetWhenContextIsUnrecorded() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#,
        in: session
    )
    _ = await session.attachment.dom.replaceDocumentRoot(
        WebInspectorCore.DOMNode.Payload(
            nodeID: .init(1),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                WebInspectorCore.DOMNode.Payload(nodeID: .init(2), nodeType: .element, nodeName: "HTML", localName: "html"),
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
    #expect(requestNode.targetIdentifier == ProtocolTarget.ID.frameAd)

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
    try await replyToPickerDisableAndRestoredHighlight(
        disable,
        transport: transport,
        backend: backend,
        expectedTargetID: .frameAd,
        expectedNodeID: 3
    )

    await session.attachment.dom.waitUntilElementPickerIdle()
    let selectedNode = try #require(await session.attachment.dom.selectedNode)
    #expect(await selectedNode.nodeName == "DIV")
    #expect(await session.attachment.dom.isSelectingElement == false)
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
    try await replyToPickerDisableAndRestoredHighlight(
        disable,
        transport: transport,
        backend: backend,
        expectedTargetID: .pageMain,
        expectedNodeID: 2
    )

    let selectedNode = try #require(await session.attachment.dom.selectedNode)
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
    try await replyToPickerDisableAndRestoredHighlight(
        disable,
        transport: transport,
        backend: backend,
        expectedTargetID: .pageMain,
        expectedNodeID: 4
    )

    await session.attachment.dom.waitUntilElementPickerIdle()
    let selectedNode = try #require(await session.attachment.dom.selectedNode)
    #expect(await selectedNode.nodeName == "DIV")
    #expect(await session.attachment.dom.isSelectingElement == false)
}

@Test
func domNavigationCopyDeleteAndReloadUseRuntimeAPIs() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    #expect(await session.hasInspectablePageWebView == false)
    let htmlID = try #require(await session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(2))])
    await session.attachment.dom.selectNode(htmlID)

    let countBeforeHTMLCopy = await backend.sentTargetMessages().count
    let copyTask = Task {
        try await session.attachment.dom.copySelectedNodeText(.html)
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
    #expect(try await session.attachment.dom.copySelectedNodeText(.selectorPath) == "html")
    #expect(await backend.sentTargetMessages().count == countBeforeSelectorCopy)

    let countBeforeDelete = await backend.sentTargetMessages().count
    let deleteTask = Task {
        try await session.attachment.dom.deleteSelectedNode(undoManager: nil)
    }
    let removeNode = try await waitForTargetMessage(backend, method: "DOM.removeNode", after: countBeforeDelete)
    await receiveTargetReply(
        transport,
        targetID: removeNode.targetIdentifier,
        messageID: try messageID(removeNode.message),
        result: "{}"
    )
    try await deleteTask.value
    #expect(await session.attachment.dom.selectedNodeID == nil)

    let countBeforeReload = await backend.sentTargetMessages().count
    let reloadTask = Task {
        try await session.attachment.dom.reloadDocument()
    }
    let getDocument = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: countBeforeReload)
    await receiveTargetReply(
        transport,
        targetID: getDocument.targetIdentifier,
        messageID: try messageID(getDocument.message),
        result: ##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","children":[{"nodeId":2,"nodeType":1,"nodeName":"HTML","localName":"html","children":[{"nodeId":4,"nodeType":1,"nodeName":"BODY","localName":"body"}]}]}}"##
    )
    try await reloadTask.value

    let reloadedBody = await session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(4))]
    #expect(reloadedBody != nil)
}

@Test
func deletingDOMNodeClearsExistingSelectionEvenWhenDeletingAnotherNode() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)

    let htmlID = try #require(await session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(2))])
    let bodyID = try #require(await session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(4))])
    await session.attachment.dom.selectNode(htmlID)

    let countBeforeDelete = await backend.sentTargetMessages().count
    let deleteTask = Task {
        try await session.attachment.dom.deleteNode(bodyID, undoManager: nil)
    }
    let removeNode = try await waitForTargetMessage(backend, method: "DOM.removeNode", after: countBeforeDelete)
    await receiveTargetReply(
        transport,
        targetID: removeNode.targetIdentifier,
        messageID: try messageID(removeNode.message),
        result: "{}"
    )
    try await deleteTask.value

    #expect(await session.attachment.dom.selectedNodeID == nil)
}

@MainActor
@Test
func multiNodeDeleteRegistersSingleUndoGroup() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)

    let headID = try #require(session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(3))])
    let bodyID = try #require(session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(4))])
    let undoManager = UndoManager()

    let countBeforeDelete = await backend.sentTargetMessages().count
    let deleteTask = Task {
        try await session.attachment.dom.deleteNodes([headID, bodyID], undoManager: undoManager)
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
    await receiveAndApplyRootMessage(
        transport,
        message: #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#,
        in: session
    )
    #expect(await session.attachment.dom.snapshot().targetsByID[.frameAd] != nil)
    _ = await session.attachment.dom.replaceDocumentRoot(
        WebInspectorCore.DOMNode.Payload(
            nodeID: .init(101),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                WebInspectorCore.DOMNode.Payload(nodeID: .init(102), nodeType: .element, nodeName: "HTML", localName: "html"),
            ])
        ),
        targetID: .frameAd
    )
    let frameHTMLID = try #require(await session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .frameAd, nodeID: .init(102))])
    await session.attachment.dom.selectNode(frameHTMLID)

    let countBeforeHighlight = await backend.sentTargetMessages().count
    let highlightTask = Task {
        await session.attachment.dom.highlightNode(for: frameHTMLID)
    }
    let highlightNode = try await waitForTargetMessage(backend, method: "DOM.highlightNode", after: countBeforeHighlight)
    #expect(highlightNode.targetIdentifier == ProtocolTarget.ID.frameAd)
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
        await session.attachment.dom.hideNodeHighlight()
    }
    let hideHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: countBeforeHideHighlight
    )
    #expect(hideHighlight.targetIdentifier == ProtocolTarget.ID.frameAd)
    await receiveTargetReply(
        transport,
        targetID: hideHighlight.targetIdentifier,
        messageID: try messageID(hideHighlight.message),
        result: "{}"
    )
    await hideHighlightTask.value

    let countBeforeHTMLCopy = await backend.sentTargetMessages().count
    let copyTask = Task {
        try await session.attachment.dom.copySelectedNodeText(.html)
    }
    let outerHTML = try await waitForTargetMessage(backend, method: "DOM.getOuterHTML", after: countBeforeHTMLCopy)
    #expect(outerHTML.targetIdentifier == ProtocolTarget.ID.pageMain)
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
        try await session.attachment.dom.deleteSelectedNode(undoManager: nil)
    }
    let removeNode = try await waitForTargetMessage(backend, method: "DOM.removeNode", after: countBeforeDelete)
    #expect(removeNode.targetIdentifier == ProtocolTarget.ID.pageMain)
    #expect(try stringParameter("nodeId", in: removeNode.message) == "frame-ad:102")
    await receiveTargetReply(
        transport,
        targetID: removeNode.targetIdentifier,
        messageID: try messageID(removeNode.message),
        result: "{}"
    )
    try await deleteTask.value
    #expect(await session.attachment.dom.selectedNodeID == nil)
}

@MainActor
@Test
func deleteUndoRedoKeepsUndoManagerStacksAvailableDuringAsyncProtocolWork() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let htmlID = try #require(session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(2))])
    session.attachment.dom.selectNode(htmlID)

    let undoManager = UndoManager()
    let countBeforeDelete = await backend.sentTargetMessages().count
    let deleteTask = Task {
        try await session.attachment.dom.deleteSelectedNode(undoManager: undoManager)
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
    let htmlID = try #require(session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(2))])
    session.attachment.dom.selectNode(htmlID)

    let undoManager = UndoManager()
    let countBeforeDelete = await backend.sentTargetMessages().count
    let deleteTask = Task {
        try await session.attachment.dom.deleteSelectedNode(undoManager: undoManager)
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
        try await session.attachment.dom.reloadDocument()
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
    let htmlID = try #require(session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(2))])
    session.attachment.dom.selectNode(htmlID)

    let undoManager = UndoManager()
    let countBeforeDelete = await backend.sentTargetMessages().count
    let deleteTask = Task {
        try await session.attachment.dom.deleteSelectedNode(undoManager: undoManager)
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
        let getDocument = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: countBeforeQueuedOperations)
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

    try await session.attachment.dom.reloadDocument()
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
    let htmlID = try #require(session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(2))])
    session.attachment.dom.selectNode(htmlID)

    let undoManager = UndoManager()
    let countBeforeDelete = await backend.sentTargetMessages().count
    let deleteTask = Task {
        try await session.attachment.dom.deleteSelectedNode(undoManager: undoManager)
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
    await receiveAndApplyTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.documentUpdated","params":{}}"#,
        in: session
    )

    await session.attachment.dom.waitUntilDeleteUndoOperationsIdle()
    #expect(undoManager.canUndo == false)
    #expect(undoManager.canRedo == false)
    #expect(session.lastError == InspectorSession.Error(String(describing: CancellationError())))
}

@MainActor
@Test
func reloadDOMDocumentCancelsActiveElementPickerBeforeReplacingDocument() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    try await beginPicker(session: session, transport: transport, backend: backend)
    #expect(session.attachment.dom.isSelectingElement)

    let countBeforeReload = await backend.sentTargetMessages().count
    let reloadTask = Task {
        try await session.attachment.dom.reloadDocument()
    }
    let disablePicker = try await waitForTargetMessage(
        backend,
        method: "DOM.setInspectModeEnabled",
        after: countBeforeReload
    )
    #expect(try boolParameter("enabled", in: disablePicker.message) == false)
    try await replyToPickerDisableAndHiddenHighlight(
        disablePicker,
        transport: transport,
        backend: backend,
        expectedTargetID: .pageMain
    )
    let getDocument = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: countBeforeReload)
    await receiveTargetReply(
        transport,
        targetID: getDocument.targetIdentifier,
        messageID: try messageID(getDocument.message),
        result: mainDocumentResult
    )
    try await reloadTask.value
    #expect(session.attachment.dom.isSelectingElement == false)
}

@MainActor
@Test
func deleteUndoKeepsOlderUndoStatesCurrentAfterReload() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    _ = session.attachment.dom.replaceDocumentRoot(
        WebInspectorCore.DOMNode.Payload(
            nodeID: .init(1),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                WebInspectorCore.DOMNode.Payload(
                    nodeID: .init(2),
                    nodeType: .element,
                    nodeName: "HTML",
                    localName: "html",
                    regularChildren: .loaded([
                        WebInspectorCore.DOMNode.Payload(
                            nodeID: .init(3),
                            nodeType: .element,
                            nodeName: "BODY",
                            localName: "body",
                            regularChildren: .loaded([
                                WebInspectorCore.DOMNode.Payload(nodeID: .init(4), nodeType: .element, nodeName: "DIV", localName: "div"),
                            ])
                        ),
                    ])
                ),
            ])
        ),
        targetID: .pageMain
    )
    let bodyID = try #require(session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(3))])
    let divID = try #require(session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(4))])
    let undoManager = UndoManager()

    session.attachment.dom.selectNode(divID)
    let countBeforeFirstDelete = await backend.sentTargetMessages().count
    let firstDeleteTask = Task {
        try await session.attachment.dom.deleteSelectedNode(undoManager: undoManager)
    }
    let firstRemoveNode = try await waitForTargetMessage(backend, method: "DOM.removeNode", after: countBeforeFirstDelete)
    await receiveTargetReply(
        transport,
        targetID: firstRemoveNode.targetIdentifier,
        messageID: try messageID(firstRemoveNode.message),
        result: "{}"
    )
    try await firstDeleteTask.value

    session.attachment.dom.selectNode(bodyID)
    let countBeforeSecondDelete = await backend.sentTargetMessages().count
    let secondDeleteTask = Task {
        try await session.attachment.dom.deleteSelectedNode(undoManager: undoManager)
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
    await session.attachment.dom.waitUntilDeleteUndoOperationsIdle()
    #expect(session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(4))] != nil)

    let countBeforeSecondUndo = await backend.sentTargetMessages().count
    undoManager.undo()
    let secondUndo = try await waitForTargetMessage(backend, method: "DOM.undo", after: countBeforeSecondUndo)
    #expect(secondUndo.targetIdentifier == ProtocolTarget.ID.pageMain)
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
    let htmlID = try #require(session.attachment.dom.snapshot().currentNodeIDByKey[.init(targetID: .pageMain, nodeID: .init(2))])
    session.attachment.dom.selectNode(htmlID)

    let undoManager = UndoManager()
    let countBeforeDelete = await backend.sentTargetMessages().count
    let deleteTask = Task {
        try await session.attachment.dom.deleteSelectedNode(undoManager: undoManager)
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

    _ = session.attachment.dom.replaceDocumentRoot(
        WebInspectorCore.DOMNode.Payload(nodeID: .init(1), nodeType: .document, nodeName: "#document"),
        targetID: .pageMain
    )

    let countBeforeUndo = await backend.sentTargetMessages().count
    undoManager.undo()

    #expect(await backend.sentTargetMessages().count == countBeforeUndo)
    #expect(undoManager.canUndo == false)
    #expect(undoManager.canRedo == false)
    #expect(session.lastError == InspectorSession.Error("DOM document changed before undo."))
}

@Test
func detachCancelsPumpsAndClearsModelState() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await session.detach()

    #expect(await backend.isDetached())
    #expect(await session.hasActiveConnection == false)
    #expect(await session.attachment.dom.snapshot().currentPageTargetID == nil)
    #expect(await session.attachment.network.snapshot().orderedRequestIDs.isEmpty)
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

    await #expect(throws: TransportSession.Error.transportClosed) {
        try await connectTask.value
    }
    #expect(await session.hasActiveConnection == false)
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
            bootstrapTimeout: testBootstrapTimeout
        )
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#
    )

    await #expect(throws: TransportSession.Error.replyTimeout(method: "Inspector.enable", targetID: .pageMain)) {
        try await session.connect(transport: transport)
    }

    #expect(await session.attachment.dom.snapshot().currentPageTargetID == nil)
    #expect(await session.attachment.network.snapshot().orderedRequestIDs.isEmpty)
    #expect(await session.hasActiveConnection == false)
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

    await #expect(throws: InspectorSession.Error("Inspector session is not attached.")) {
        try await session.attachment.dom.perform(.getDocument(targetID: .pageMain))
    }

    try await completeBootstrap(transport: transport, backend: backend)
    try await connectTask.value
    #expect(await session.hasActiveConnection)
}

@Test
func domActionAvailabilityWaitsForActiveAttachment() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = await InspectorSession(configuration: .test)
    await transport.receiveRootMessage(
        cssCapablePageTargetCreatedMessage(targetID: "page-main", frameID: "main-frame", isProvisional: false)
    )

    let connectTask = Task {
        try await session.connect(transport: transport)
    }

    var sentCount = 0
    for method in ["Inspector.enable", "Inspector.initialized", "Runtime.enable"] {
        let sent = try await waitForTargetMessage(backend, method: method, after: sentCount)
        sentCount = await backend.sentTargetMessages().count
        await receiveTargetReply(
            transport,
            targetID: sent.targetIdentifier,
            messageID: try messageID(sent.message),
            result: "{}"
        )
    }

    let documentMessage = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: sentCount)
    sentCount = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: documentMessage.targetIdentifier,
        messageID: try messageID(documentMessage.message),
        result: mainDocumentResult
    )

    await session.attachment.dom.waitUntilDocumentRequestsIdle(targetID: documentMessage.targetIdentifier)
    #expect(await session.attachment.dom.snapshot().currentPageDocumentID != nil)
    #expect(await session.hasActiveConnection == false)
    #expect(await session.attachment.dom.canReloadDocument == false)
    #expect(await session.attachment.dom.canSelectElement == false)

    let networkMessage = try await waitForTargetMessage(backend, method: "Network.enable", after: sentCount)
    sentCount = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: networkMessage.targetIdentifier,
        messageID: try messageID(networkMessage.message),
        result: "{}"
    )

    let consoleMessage = try await waitForTargetMessage(backend, method: "Console.enable", after: sentCount)
    await receiveTargetReply(
        transport,
        targetID: consoleMessage.targetIdentifier,
        messageID: try messageID(consoleMessage.message),
        result: "{}"
    )

    try await connectTask.value
    #expect(await session.hasActiveConnection)
    #expect(await session.attachment.dom.canReloadDocument)
    #expect(await session.attachment.dom.canSelectElement)
}

@Test
@MainActor
func selectedElementStyleHydrationWaitsForActiveAttachmentDuringBootstrap() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    await transport.receiveRootMessage(
        cssCapablePageTargetCreatedMessage(targetID: "page-main", frameID: "main-frame", isProvisional: false)
    )

    let connectTask = Task {
        try await session.connect(transport: transport)
    }

    var sentCount = 0
    for method in ["Inspector.enable", "Inspector.initialized", "Runtime.enable"] {
        let sent = try await waitForTargetMessage(backend, method: method, after: sentCount)
        sentCount = await backend.sentTargetMessages().count
        await receiveTargetReply(
            transport,
            targetID: sent.targetIdentifier,
            messageID: try messageID(sent.message),
            result: "{}"
        )
    }

    let documentMessage = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: sentCount)
    sentCount = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: documentMessage.targetIdentifier,
        messageID: try messageID(documentMessage.message),
        result: mainDocumentResult
    )

    await session.attachment.dom.waitUntilDocumentRequestsIdle(targetID: documentMessage.targetIdentifier)
    let htmlID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(2))
    session.attachment.dom.selectNode(htmlID)

    let networkMessage = try await waitForTargetMessage(backend, method: "Network.enable", after: sentCount)
    sentCount = await backend.sentTargetMessages().count
    #expect(session.hasActiveConnection == false)

    session.attachment.dom.setSelectedNodeStyleHydrationActive(true)
    #expect(session.attachment.dom.elementStyles.selectedPhase == .needsRefresh)
    #expect(await backend.sentTargetMessages().count == sentCount)

    await receiveTargetReply(
        transport,
        targetID: networkMessage.targetIdentifier,
        messageID: try messageID(networkMessage.message),
        result: "{}"
    )

    let consoleMessage = try await waitForTargetMessage(backend, method: "Console.enable", after: sentCount)
    sentCount = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: consoleMessage.targetIdentifier,
        messageID: try messageID(consoleMessage.message),
        result: "{}"
    )

    try await connectTask.value
    #expect(session.hasActiveConnection)

    let messages = try await waitForCSSRefreshMessages(backend, after: sentCount)
    try await replyCSSRefresh(
        transport: transport,
        messages: messages,
        selector: "html",
        styleSheetID: "sheet-html"
    )

    await session.attachment.dom.waitUntilSelectedStyleRefreshIdle()
    #expect(session.attachment.dom.elementStyles.selectedPhase == .loaded)
}

@MainActor
@Test
func domActionAvailabilityObservationFiresWhenBootstrapAttaches() async throws {
    let backend = FakeTransportBackend()
    let transport = testTransport(backend)
    let session = InspectorSession(configuration: .test)
    await transport.receiveRootMessage(
        cssCapablePageTargetCreatedMessage(targetID: "page-main", frameID: "main-frame", isProvisional: false)
    )

    let availabilityObservation = withPortableContinuousObservation { _ in
        _ = session.attachment.dom.canBeginElementPicker
    }
    let rootObservation = withPortableContinuousObservation { _ in
        _ = session.attachment.dom.treeRevision
    }
    defer {
        availabilityObservation.cancel()
        rootObservation.cancel()
    }
    let renderedAvailability = await availabilityObservation.values {
        session.attachment.dom.canBeginElementPicker
    }
    let renderedRootState = await rootObservation.values {
        session.attachment.dom.currentPageRootNode != nil
    }
    #expect(await renderedAvailability.waitUntilValue(false))
    #expect(await renderedRootState.waitUntilValue(false))

    let connectTask = Task {
        try await session.connect(transport: transport)
    }

    var sentCount = 0
    for method in ["Inspector.enable", "Inspector.initialized", "Runtime.enable"] {
        let sent = try await waitForTargetMessage(backend, method: method, after: sentCount)
        sentCount = await backend.sentTargetMessages().count
        await receiveTargetReply(
            transport,
            targetID: sent.targetIdentifier,
            messageID: try messageID(sent.message),
            result: "{}"
        )
    }

    let documentMessage = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: sentCount)
    sentCount = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: documentMessage.targetIdentifier,
        messageID: try messageID(documentMessage.message),
        result: mainDocumentResult
    )

    await session.attachment.dom.waitUntilDocumentRequestsIdle(targetID: documentMessage.targetIdentifier)
    #expect(await renderedRootState.waitUntilValue(true))
    #expect(session.hasActiveConnection == false)
    #expect(session.attachment.dom.canBeginElementPicker == false)

    let networkMessage = try await waitForTargetMessage(backend, method: "Network.enable", after: sentCount)
    sentCount = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: networkMessage.targetIdentifier,
        messageID: try messageID(networkMessage.message),
        result: "{}"
    )

    let consoleMessage = try await waitForTargetMessage(backend, method: "Console.enable", after: sentCount)
    await receiveTargetReply(
        transport,
        targetID: consoleMessage.targetIdentifier,
        messageID: try messageID(consoleMessage.message),
        result: "{}"
    )

    try await connectTask.value
    #expect(session.hasActiveConnection)
    #expect(await renderedAvailability.waitUntilValue(true))
}

@MainActor
@Test
func attachInspectabilityPreparationRestoresOriginalValue() throws {
    let webView = TestInspectableWebView(isInspectable: false)
    webView.isInspectable = false

    let originalValue = InspectorSession.prepareInspectability(for: webView)

    #expect(originalValue == false)
    #expect(webView.isInspectable == true)

    InspectorSession.restoreInspectabilityIfNeeded(on: webView, originalValue: originalValue)

    #expect(webView.isInspectable == false)
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
        connectTask.cancel()
        _ = try? await connectTask.value
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
    for method in ["Inspector.enable", "Inspector.initialized", "Runtime.enable"] {
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
    sentCount = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: networkMessage.targetIdentifier,
        messageID: try messageID(networkMessage.message),
        result: "{}"
    )

    let consoleMessage = try await waitForTargetMessage(backend, method: "Console.enable", after: sentCount)
    sentMessages.append(consoleMessage)
    await receiveTargetReply(
        transport,
        targetID: consoleMessage.targetIdentifier,
        messageID: try messageID(consoleMessage.message),
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
        try await session.attachment.dom.beginElementPicker()
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

@discardableResult
private func replyToPickerDisableAndRestoredHighlight(
    _ disableMessage: SentTargetMessage,
    transport: TransportSession,
    backend: FakeTransportBackend,
    expectedTargetID: ProtocolTarget.ID? = nil,
    expectedNodeID: Int? = nil
) async throws -> SentTargetMessage {
    let sentCountBeforeDisableReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: disableMessage.targetIdentifier,
        messageID: try messageID(disableMessage.message),
        result: "{}"
    )
    let firstMessage = try await waitForNextTargetMessage(
        backend,
        after: sentCountBeforeDisableReply
    )
    switch try messageMethod(firstMessage.message) {
    case "DOM.highlightNode":
        let highlight = firstMessage
        if let expectedTargetID {
            #expect(highlight.targetIdentifier == expectedTargetID)
        }
        if let expectedNodeID {
            #expect(try integerParameter("nodeId", in: highlight.message) == expectedNodeID)
        }
        await receiveTargetReply(
            transport,
            targetID: highlight.targetIdentifier,
            messageID: try messageID(highlight.message),
            result: "{}"
        )
        return highlight
    case "DOM.hideHighlight":
        let sentCountBeforeHideReply = await backend.sentTargetMessages().count
        await receiveTargetReply(
            transport,
            targetID: firstMessage.targetIdentifier,
            messageID: try messageID(firstMessage.message),
            result: "{}"
        )
        let highlight = try await waitForTargetMessage(
            backend,
            method: "DOM.highlightNode",
            after: sentCountBeforeHideReply
        )
        if let expectedTargetID {
            #expect(highlight.targetIdentifier == expectedTargetID)
        }
        if let expectedNodeID {
            #expect(try integerParameter("nodeId", in: highlight.message) == expectedNodeID)
        }
        await receiveTargetReply(
            transport,
            targetID: highlight.targetIdentifier,
            messageID: try messageID(highlight.message),
            result: "{}"
        )
        return highlight
    default:
        throw InspectorSession.Error("Expected DOM.highlightNode or DOM.hideHighlight after disabling inspect mode.")
    }
}

private func waitForNextTargetMessage(
    _ backend: FakeTransportBackend,
    after count: Int = 0
) async throws -> SentTargetMessage {
    try await waitForBackendTargetMessage(
        backend,
        method: nil,
        ordinal: 0,
        after: count
    )
}

@discardableResult
private func replyToPickerDisableAndHiddenHighlight(
    _ disableMessage: SentTargetMessage,
    transport: TransportSession,
    backend: FakeTransportBackend,
    expectedTargetID: ProtocolTarget.ID? = nil
) async throws -> SentTargetMessage {
    let sentCountBeforeDisableReply = await backend.sentTargetMessages().count
    await receiveTargetReply(
        transport,
        targetID: disableMessage.targetIdentifier,
        messageID: try messageID(disableMessage.message),
        result: "{}"
    )
    let hideHighlight = try await waitForTargetMessage(
        backend,
        method: "DOM.hideHighlight",
        after: sentCountBeforeDisableReply
    )
    if let expectedTargetID {
        #expect(hideHighlight.targetIdentifier == expectedTargetID)
    }
    await receiveTargetReply(
        transport,
        targetID: hideHighlight.targetIdentifier,
        messageID: try messageID(hideHighlight.message),
        result: "{}"
    )
    return hideHighlight
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
        await session.attachment.dom.requestChildNodes(for: htmlID)
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

private final class TestInspectableWebView: InspectorSession.InspectableWebView {
    var isInspectable: Bool

    init(isInspectable: Bool) {
        self.isInspectable = isInspectable
    }
}

private func targetMessageMethods(_ backend: FakeTransportBackend) async -> [String?] {
    await backend.sentTargetMessages().map { try? messageMethod($0.message) }
}

private func waitForTargetMessage(
    _ backend: FakeTransportBackend,
    method: String,
    after count: Int = 0
) async throws -> SentTargetMessage {
    try await waitForBackendTargetMessage(
        backend,
        method: method,
        ordinal: 0,
        after: count
    )
}

private func waitForTargetMessage(
    _ backend: FakeTransportBackend,
    method: String,
    ordinal: Int,
    after count: Int = 0
) async throws -> SentTargetMessage {
    try await waitForBackendTargetMessage(
        backend,
        method: method,
        ordinal: ordinal,
        after: count
    )
}

private func waitForBackendTargetMessage(
    _ backend: FakeTransportBackend,
    method: String?,
    ordinal: Int,
    after count: Int,
    timeout: Duration = .seconds(5)
) async throws -> SentTargetMessage {
    try await withThrowingTaskGroup(of: SentTargetMessage.self) { group in
        defer {
            group.cancelAll()
        }

        group.addTask {
            if let method {
                try await backend.waitForTargetMessage(method: method, ordinal: ordinal, after: count)
            } else {
                try await backend.waitForTargetMessage(ordinal: ordinal, after: count)
            }
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TransportSession.Error.replyTimeout(method: method ?? "target message", targetID: nil)
        }

        guard let message = try await group.next() else {
            throw TransportSession.Error.replyTimeout(method: method ?? "target message", targetID: nil)
        }
        return message
    }
}

@MainActor
private func hydrateSelectedBodyStyles(
    session: InspectorSession,
    transport: TransportSession,
    backend: FakeTransportBackend
) async throws -> WebInspectorCore.DOMNode.ID {
    try await hydratePageHTMLChildren(session: session, transport: transport, backend: backend)
    let bodyID = try await waitForCurrentNode(in: session, targetID: .pageMain, protocolNodeID: .init(4))
    session.attachment.dom.selectNode(bodyID)

    let sentCount = await backend.sentTargetMessages().count
    session.attachment.dom.setSelectedNodeStyleHydrationActive(true)
    let messages = try await waitForCSSRefreshMessages(backend, after: sentCount)
    try await replyCSSRefresh(
        transport: transport,
        messages: messages,
        selector: "body",
        styleSheetID: "sheet-body"
    )
    await session.attachment.dom.waitUntilSelectedStyleRefreshIdle()
    #expect(session.attachment.dom.elementStyles.selectedPhase == .loaded)
    return bodyID
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
    let matched = try await waitForTargetMessage(backend, method: "CSS.getMatchedStylesForNode", after: count)
    let inline = try await waitForTargetMessage(backend, method: "CSS.getInlineStylesForNode", after: count)
    let computed = try await waitForTargetMessage(backend, method: "CSS.getComputedStyleForNode", after: count)
    return CSSRefreshMessages(matched: matched, inline: inline, computed: computed)
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

@discardableResult
@MainActor
private func applySingleRuleStyles(
    to css: CSSSession,
    id: CSSNodeStyles.ID,
    token: CSSStyle.RefreshToken? = nil,
    selector: String,
    marginValue: String,
    marginText: String
) throws -> CSSNodeStyles {
    let token = token ?? css.beginRefresh(id: id)
    let styleSheetID = CSSStyleSheet.ID("test-sheet")
    let styleID = CSSStyle.ID(styleSheetID: styleSheetID, ordinal: 0)
    css.applyRefresh(
        token: token,
        matched: CSSStyle.MatchedStylesPayload(matchedRules: [
            CSSRule.MatchPayload(
                rule: CSSRule.Payload(
                    id: CSSRule.ID(styleSheetID: styleSheetID, ordinal: 0),
                    selectorList: CSSRule.SelectorList(selectors: [CSSRule.Selector(text: selector)], text: selector),
                    sourceLine: 0,
                    origin: .author,
                    style: CSSStyle.Payload(
                        id: styleID,
                        cssProperties: [
                            CSSProperty.Payload(
                                name: "margin",
                                value: marginValue,
                                text: marginText
                            ),
                        ],
                        cssText: marginText
                    )
                ),
                matchingSelectors: [0]
            ),
        ]),
        inline: .init(),
        computed: []
    )
    return try #require(css.nodeStyles(for: id))
}

private func waitForCurrentNode(
    in session: InspectorSession,
    targetID: ProtocolTarget.ID,
    protocolNodeID: WebInspectorCore.DOMNode.ProtocolID
) async throws -> WebInspectorCore.DOMNode.ID {
    await session.attachment.dom.waitUntilDocumentRequestsIdle(targetID: targetID)
    return try #require(
        await session.attachment.dom.snapshot().currentNodeIDByKey[
            .init(targetID: targetID, nodeID: protocolNodeID)
        ]
    )
}

private func assertProjectionContainsFrameDocument(
    in projection: DOMTreeProjection,
    iframeNodeID: WebInspectorCore.DOMNode.ID,
    frameRootNodeID: WebInspectorCore.DOMNode.ID,
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
    targetID: ProtocolTarget.ID,
    message: String
) async -> UInt64 {
    await transport.receiveRootMessage(targetDispatchMessage(targetID: targetID, message: message))
}

@discardableResult
private func receiveAndApplyTargetDispatch(
    _ transport: TransportSession,
    targetID: ProtocolTarget.ID,
    message: String,
    in session: InspectorSession,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> UInt64 {
    let sequence = await receiveTargetDispatch(transport, targetID: targetID, message: message)
    await expectProtocolEventApplied(sequence, in: session, sourceLocation: sourceLocation)
    return sequence
}

private func receiveAndApplyRuntimeContextCreated(
    _ transport: TransportSession,
    targetID: ProtocolTarget.ID = .pageMain,
    contextID: Int,
    frameID: String = "main-frame",
    in session: InspectorSession,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    await receiveAndApplyTargetDispatch(
        transport,
        targetID: targetID,
        message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":\#(contextID),"frameId":"\#(jsonEscapedString(frameID))"}}}"#,
        in: session,
        sourceLocation: sourceLocation
    )
}

@discardableResult
private func receiveAndApplyRootMessage(
    _ transport: TransportSession,
    message: String,
    in session: InspectorSession,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> UInt64 {
    let sequence = await transport.receiveRootMessage(message)
    await expectProtocolEventApplied(sequence, in: session, sourceLocation: sourceLocation)
    return sequence
}

private func receiveTargetReply(
    _ transport: TransportSession,
    targetID: ProtocolTarget.ID,
    messageID: UInt64,
    result: String
) async {
    await receiveTargetDispatch(
        transport,
        targetID: targetID,
        message: #"{"id":\#(messageID),"result":\#(result)}"#
    )
}

private func receiveTargetErrorReply(
    _ transport: TransportSession,
    targetID: ProtocolTarget.ID,
    messageID: UInt64,
    message: String
) async {
    await receiveTargetDispatch(
        transport,
        targetID: targetID,
        message: #"{"id":\#(messageID),"error":{"message":"\#(message)"}}"#
    )
}

private func expectProtocolEventApplied(
    _ sequence: UInt64,
    in session: InspectorSession,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    #expect(await session.waitUntilProtocolEventApplied(sequence), sourceLocation: sourceLocation)
}

private func pendingTargetReplyKeys(_ transport: TransportSession) async -> [TransportSession.ReplyKey] {
    await transport.snapshot().pendingTargetReplyKeys
}

private func contextKey(
    _ runtimeAgentTargetID: ProtocolTarget.ID,
    _ contextID: Int
) -> RuntimeContext.Key {
    RuntimeContext.Key(runtimeAgentTargetID: runtimeAgentTargetID, contextID: RuntimeContext.ID(contextID))
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
    throw TransportSession.Error.malformedMessage
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

private extension ProtocolTarget.ID {
    static let pageMain = ProtocolTarget.ID("page-main")
    static let pageNext = ProtocolTarget.ID("page-next")
    static let frameAd = ProtocolTarget.ID("frame-ad")
}

private extension InspectorSession.Configuration {
    static let test = InspectorSession.Configuration(
        responseTimeout: testResponseTimeout,
        bootstrapTimeout: testBootstrapTimeout
    )
}

private let testResponseTimeout: Duration = .milliseconds(750)
private let testBootstrapTimeout: Duration = .milliseconds(750)

private extension DOMSession.Snapshot {
    var currentPageDocumentID: WebInspectorCore.DOMDocument.ID? {
        guard let currentPageTargetID else {
            return nil
        }
        return targetsByID[currentPageTargetID]?.currentDocumentID
    }
}

private extension Result {
    var successValue: Success? {
        if case let .success(value) = self {
            return value
        }
        return nil
    }
}
