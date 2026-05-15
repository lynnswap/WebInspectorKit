import Foundation
import Testing
import WebKit
@testable import V2_WebInspectorCore
@testable import V2_WebInspectorRuntime
@testable import V2_WebInspectorTransport

@Test
func connectBootstrapsMainPageDocumentInOrder() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)

    try await connect(session, transport: transport, backend: backend)

    let methods = await targetMessageMethods(backend)
    #expect(methods == [
        "Inspector.enable",
        "Inspector.initialized",
        // DOM.enable is resolved by TransportSession compatibility and is not routed to the backend.
        "Runtime.enable",
        "DOM.getDocument",
        "Network.enable",
    ])
    #expect(await session.isAttached)
    #expect(await session.dom.snapshot().currentPage?.mainTargetID == ProtocolTargetIdentifier.pageMain)
    #expect(await session.dom.snapshot().documentsByID.count == 1)
}

@Test
func domainPumpsApplyNetworkEventsToNetworkSession() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
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
func networkLazyFetchReturnsCommandResultFromPageTarget() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

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

    #expect(sent.targetIdentifier == ProtocolTargetIdentifier.pageMain)
    #expect(String(data: Data(sent.message.utf8), encoding: .utf8)?.contains(#""requestId":"request-1""#) == true)

    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: #"{"body":"hello","base64Encoded":false}"#
    )
    let result = try await performTask.value

    #expect(result.method == "Network.getResponseBody")
    #expect(result.targetID == ProtocolTargetIdentifier.pageMain)
    #expect(String(data: result.resultData, encoding: .utf8)?.contains(#""body":"hello""#) == true)
}

@Test
func networkResponseBodyFetchAppliesResultToCoreRequest() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
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
    let body = try await #require(request.responseBody)
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
func frameDocumentRefreshUpdatesOnlyFrameDocument() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)
    let pageDocumentID = try #require(await session.dom.snapshot().currentPageDocumentID)

    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-ad","type":"frame","frameId":"ad-frame","parentFrameId":"main-frame","isProvisional":false}}}"#
    )
    _ = try await waitUntil {
        await session.dom.snapshot().targetsByID[.frameAd]
    }

    let sentCount = await backend.sentTargetMessages().count
    let performTask = Task {
        try await session.perform(.getDocument(targetID: .frameAd))
    }
    let sent = try await waitForTargetMessage(backend, method: "DOM.getDocument", after: sentCount)
    await receiveTargetReply(
        transport,
        targetID: sent.targetIdentifier,
        messageID: try messageID(sent.message),
        result: ##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","children":[{"nodeId":2,"nodeType":1,"nodeName":"HTML","localName":"html"}]}}"##
    )
    _ = try await performTask.value

    let snapshot = await session.dom.snapshot()
    #expect(snapshot.currentPageDocumentID == pageDocumentID)
    #expect(snapshot.targetsByID[.frameAd]?.currentDocumentID != nil)
    #expect(snapshot.targetsByID[.frameAd]?.currentDocumentID != pageDocumentID)
}

@Test("Lazy iframe insertion and frame document update keep the parent page tree intact")
func lazyIframeInsertionAndFrameDocumentUpdateKeepParentPageTree() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":2,"nodes":[{"nodeId":3,"nodeType":1,"nodeName":"HEAD","localName":"head"},{"nodeId":4,"nodeType":1,"nodeName":"BODY","localName":"body","children":[{"nodeId":5,"nodeType":1,"nodeName":"MAIN","localName":"main","attributes":["id","content"]}]}]}}"#
    )
    let mainNodeID = try await waitForCurrentNode(
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
        message: #"{"method":"DOM.childNodeInserted","params":{"parentNodeId":4,"previousNodeId":5,"node":{"nodeId":6,"nodeType":1,"nodeName":"IFRAME","localName":"iframe","frameId":"ad-frame","attributes":["src","https://frame.example/ad"]}}}"#
    )
    let iframeNodeID = try await waitForCurrentNode(
        in: session,
        targetID: .pageMain,
        protocolNodeID: .init(6)
    )

    let sentCountBeforeFirstFrameDocument = await backend.sentTargetMessages().count
    let firstFrameDocumentTask = Task {
        try await session.perform(.getDocument(targetID: .frameAd))
    }
    let firstFrameDocumentRequest = try await waitForTargetMessage(
        backend,
        method: "DOM.getDocument",
        after: sentCountBeforeFirstFrameDocument
    )
    #expect(firstFrameDocumentRequest.targetIdentifier == ProtocolTargetIdentifier.frameAd)
    await receiveTargetReply(
        transport,
        targetID: firstFrameDocumentRequest.targetIdentifier,
        messageID: try messageID(firstFrameDocumentRequest.message),
        result: firstLazyFrameDocumentResult
    )
    _ = try await firstFrameDocumentTask.value

    let beforeUpdate = await session.dom.snapshot()
    let pageDocumentID = try #require(beforeUpdate.currentPageDocumentID)
    let firstFrameDocumentID = try #require(beforeUpdate.targetsByID[.frameAd]?.currentDocumentID)
    let firstFrameRootID = try #require(beforeUpdate.documentsByID[firstFrameDocumentID]?.rootNodeID)
    assertProjectionContainsFrameDocument(
        in: await session.dom.treeProjection(rootTargetID: .pageMain),
        iframeNodeID: iframeNodeID,
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
        guard snapshot.targetsByID[.frameAd]?.currentDocumentID != firstFrameDocumentID else {
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

@Test("DOM.Node.frameId on an iframe owner is the owner frame, not the child frame identity")
func lazyIframeOwnerFrameIdIsNotTreatedAsChildFrameIdentity() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await receiveTargetDispatch(
        transport,
        targetID: .pageMain,
        message: #"{"method":"DOM.setChildNodes","params":{"parentId":2,"nodes":[{"nodeId":3,"nodeType":1,"nodeName":"HEAD","localName":"head"},{"nodeId":4,"nodeType":1,"nodeName":"BODY","localName":"body","children":[{"nodeId":5,"nodeType":1,"nodeName":"MAIN","localName":"main","attributes":["id","content"]}]}]}}"#
    )
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

    let snapshot: DOMSessionSnapshot = try await waitUntil {
        let snapshot = await session.dom.snapshot()
        guard snapshot.targetsByID[.frameAd]?.currentDocumentID != firstFrameDocumentID else {
            return nil
        }
        return snapshot
    }
    let frameDocumentID = try #require(snapshot.targetsByID[.frameAd]?.currentDocumentID)
    let frameRootID = try #require(snapshot.documentsByID[frameDocumentID]?.rootNodeID)
    let projectionRows = await session.dom.treeProjection(rootTargetID: .pageMain).rows.map(\.nodeID)

    #expect(snapshot.framesByID[DOMFrameIdentifier("main-frame")]?.ownerNodeID == nil)
    #expect(snapshot.framesByID[DOMFrameIdentifier("ad-frame")]?.ownerNodeID == nil)
    #expect(snapshot.nodesByID[iframeNodeID] != nil)
    #expect(projectionRows.contains(frameRootID) == false)
}

@Test
func targetCommitBootstrapsCommittedMainPageDocument() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    let sentCountBeforeCommit = await backend.sentTargetMessages().count
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-next","type":"page","isProvisional":true}}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"page-next"}}"#
    )

    let bootstrapMessages = try await completeBootstrap(
        transport: transport,
        backend: backend,
        after: sentCountBeforeCommit
    )

    let snapshot = await session.dom.snapshot()
    #expect(snapshot.currentPage?.mainTargetID == ProtocolTargetIdentifier.pageNext)
    #expect(snapshot.targetsByID[.pageNext]?.currentDocumentID != nil)
    #expect(snapshot.targetsByID[.pageMain] == nil)
    #expect(bootstrapMessages.map { $0.targetIdentifier } == Array(repeating: ProtocolTargetIdentifier.pageNext, count: 5))
}

@Test
func requestNodeWaitsForPathPushBeforeSelectingNode() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
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

@Test
func requestNodeFailureDoesNotMutateDOMTree() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(
        configuration: .init(responseTimeout: .seconds(1), bootstrapTimeout: .seconds(1), eventApplicationTimeout: .milliseconds(1))
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
    #expect(snapshot.selection.failure == .unresolvedNode(.init(targetID: .pageMain, nodeID: .init(999))))
}

@Test
func elementPickerBeginAndCancelToggleInspectMode() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
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
func inspectorInspectSelectsRequestedNodeAndDisablesPicker() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
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
func inspectorInspectRecordedExecutionContextOverridesEventTargetHint() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
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
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
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
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
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
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
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
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
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
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
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
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
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
func frameDOMNodeCopyDeleteRouteThroughPageTargetWithScopedNodeID() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
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
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = V2_InspectorSession(configuration: .test)
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
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = V2_InspectorSession(configuration: .test)
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
func reloadDOMDocumentCancelsActiveElementPickerBeforeReplacingDocument() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = V2_InspectorSession(configuration: .test)
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
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = V2_InspectorSession(configuration: .test)
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
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = V2_InspectorSession(configuration: .test)
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
    #expect(session.lastError == V2_InspectorSessionError("DOM document changed before undo."))
}

@Test
func detachCancelsPumpsAndClearsModelState() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
    try await connect(session, transport: transport, backend: backend)

    await session.detach()

    #expect(await backend.isDetached())
    #expect(await session.isAttached == false)
    #expect(await session.dom.snapshot().currentPage == nil)
    #expect(await session.network.snapshot().orderedRequestIDs.isEmpty)
}

@Test
func detachDuringConnectKeepsSessionDetached() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#
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
    let session = await V2_InspectorSession(
        configuration: .init(
            responseTimeout: .milliseconds(20),
            bootstrapTimeout: .seconds(1),
            eventApplicationTimeout: .milliseconds(25)
        )
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#
    )

    await #expect(throws: TransportError.replyTimeout(method: "Inspector.enable", targetID: .pageMain)) {
        try await session.connect(transport: transport)
    }

    #expect(await session.dom.snapshot().currentPage == nil)
    #expect(await session.network.snapshot().orderedRequestIDs.isEmpty)
    #expect(await session.isAttached == false)
    #expect(await session.lastError != nil)
}

@Test
func performIsRejectedUntilBootstrapAttaches() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .seconds(1))
    let session = await V2_InspectorSession(configuration: .test)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#
    )

    let connectTask = Task {
        try await session.connect(transport: transport)
    }
    _ = try await waitForTargetMessage(backend, method: "Inspector.enable")

    await #expect(throws: V2_InspectorSessionError("Inspector session is not attached.")) {
        try await session.perform(.getDocument(targetID: .pageMain))
    }

    try await completeBootstrap(transport: transport, backend: backend)
    try await connectTask.value
    #expect(await session.isAttached)
}

@MainActor
@Test
func attachInspectabilityPreparationRestoresOriginalValue() throws {
    guard #available(iOS 16.4, macOS 13.3, *) else {
        return
    }
    let webView = WKWebView(frame: .zero)
    let initialValue = webView.isInspectable
    webView.isInspectable = false

    let originalValue = V2_InspectorSession.prepareInspectability(for: webView)

    #expect(originalValue == false)
    #expect(webView.isInspectable == true)

    V2_InspectorSession.restoreInspectabilityIfNeeded(on: webView, originalValue: originalValue)

    #expect(webView.isInspectable == false)
    webView.isInspectable = initialValue
}

@MainActor
@Test
func eventPumpTimeoutRemovesWaiter() async {
    let pump = V2_DomainEventPump()

    await pump.waitUntilApplied(10, timeout: .milliseconds(1))

    #expect(pump.pendingWaiterCount == 0)
}

private func connect(
    _ session: V2_InspectorSession,
    transport: TransportSession,
    backend: FakeTransportBackend
) async throws {
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#
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

@discardableResult
private func completeBootstrap(
    transport: TransportSession,
    backend: FakeTransportBackend,
    after initialSentCount: Int = 0
) async throws -> [SentTargetMessage] {
    var sentCount = initialSentCount
    var sentMessages: [SentTargetMessage] = []
    // DOM.enable is resolved by TransportSession compatibility, so this helper only replies to backend-routed commands.
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
        result: mainDocumentResult
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
    session: V2_InspectorSession,
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

private let mainDocumentResult = ##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","children":[{"nodeId":2,"nodeType":1,"nodeName":"HTML","localName":"html","children":[]}]}}"##
private let nestedDocumentResult = ##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","children":[{"nodeId":2,"nodeType":1,"nodeName":"HTML","localName":"html","children":[{"nodeId":3,"nodeType":1,"nodeName":"BODY","localName":"body","children":[{"nodeId":4,"nodeType":1,"nodeName":"DIV","localName":"div"}]}]}]}}"##
private let firstLazyFrameDocumentResult = ##"{"root":{"nodeId":101,"nodeType":9,"nodeName":"#document","children":[{"nodeId":102,"nodeType":1,"nodeName":"HTML","localName":"html","children":[{"nodeId":103,"nodeType":1,"nodeName":"BODY","localName":"body","children":[{"nodeId":104,"nodeType":1,"nodeName":"CANVAS","localName":"canvas"}]}]}]}}"##
private let secondLazyFrameDocumentResult = ##"{"root":{"nodeId":201,"nodeType":9,"nodeName":"#document","children":[{"nodeId":202,"nodeType":1,"nodeName":"HTML","localName":"html","children":[{"nodeId":203,"nodeType":1,"nodeName":"BODY","localName":"body","children":[{"nodeId":204,"nodeType":1,"nodeName":"VIDEO","localName":"video"}]}]}]}}"##

private func targetMessageMethods(_ backend: FakeTransportBackend) async -> [String?] {
    await backend.sentTargetMessages().map { try? messageMethod($0.message) }
}

private func waitForTargetMessage(
    _ backend: FakeTransportBackend,
    method: String,
    after count: Int = 0
) async throws -> SentTargetMessage {
    try await waitUntil {
        let messages = await backend.sentTargetMessages()
        return messages.dropFirst(count).first { (try? messageMethod($0.message)) == method }
    }
}

private func waitUntil<Value: Sendable>(_ body: @escaping @Sendable () async -> Value?) async throws -> Value {
    let deadline = ContinuousClock.now + .seconds(1)
    while ContinuousClock.now < deadline {
        if let value = await body() {
            return value
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw TransportError.replyTimeout(method: "test wait", targetID: nil)
}

private func waitForCurrentNode(
    in session: V2_InspectorSession,
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

private func receiveTargetDispatch(
    _ transport: TransportSession,
    targetID: ProtocolTargetIdentifier,
    message: String
) async {
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

private extension V2_InspectorSessionConfiguration {
    static let test = V2_InspectorSessionConfiguration(
        responseTimeout: .seconds(1),
        bootstrapTimeout: .seconds(1),
        eventApplicationTimeout: .milliseconds(25)
    )
}

private extension DOMSessionSnapshot {
    var currentPageDocumentID: DOMDocumentIdentifier? {
        guard let currentPage else {
            return nil
        }
        return targetsByID[currentPage.mainTargetID]?.currentDocumentID
    }
}
