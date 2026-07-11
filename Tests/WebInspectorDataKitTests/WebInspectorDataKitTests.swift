import Foundation
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

private actor ModelContextActorProbe {
    private let context = WebInspectorModelContext(
        configuration: .init(domains: [])
    )

    func attach(to proxy: WebInspectorProxy) async throws -> WebInspectorModelContext.State {
        try await context.attach(to: proxy, isolation: self)
        return context.state
    }

    func close() async -> WebInspectorModelContext.State {
        await context.close()
        return context.state
    }
}

@MainActor
@Test
func modelContextInheritsACustomCallerActorAndDoesNotRetainIt() async throws {
    try await withDataKitTestRuntime { runtime in
        var probe: ModelContextActorProbe? = ModelContextActorProbe()
        weak let releasedProbe = probe

        let attachedState = try await probe?.attach(to: runtime.proxy)
        #expect(attachedState == .attached)
        #expect(await probe?.close() == .closed)

        probe = nil
        for _ in 0..<100 where releasedProbe != nil {
            await Task.yield()
        }
        #expect(releasedProbe == nil)
    }
}

@MainActor
@Test
func configurationNormalizesCSSAndRejectsUnconfiguredDomains() async throws {
    let configuration = WebInspectorModelContext.Configuration(domains: [.css])
    #expect(configuration.domains == [.dom, .css])
    let context = WebInspectorModelContext.preview(configuration: configuration)

    #expect(try context.rootDOMNode == nil)
    #expect(throws: WebInspectorModelError.domainNotConfigured(.network)) {
        try context.networkRequest(id: NetworkRequest.ID(Network.Request.ID("request")))
    }
    await #expect(throws: WebInspectorModelError.domainNotConfigured(.console)) {
        _ = try await context.consoleMessages()
    }
}

@MainActor
@Test
func attachmentPublishesDOMSnapshotAndAcceptsFilteredSequenceGaps() async throws {
    let documentID = DOM.Node.ID("document")
    let childID = DOM.Node.ID("child")
    let document = DOM.Node(
        id: documentID,
        nodeType: 9,
        nodeName: "#document",
        children: [
            DOM.Node(
                id: childID,
                nodeType: 1,
                nodeName: "DIV",
                localName: "div"
            )
        ]
    )
    try await withAttachedModelContext(
        configuration: .init(domains: [.dom, .network]),
        document: document
    ) { fixture in
        let root = try #require(try fixture.context.rootDOMNode)
        #expect(root.id == DOMNode.ID(documentID))
        #expect(try fixture.context.domNode(id: DOMNode.ID(childID)) != nil)
        #expect(fixture.context.state == .attached)
        #expect(fixture.context.pageGeneration != nil)

        let requestID = Network.Request.ID("gap-request")
        try await fixture.runtime.wire.emitRaw(
            .requestWillBeSent(
                id: requestID,
                request: Network.Request(
                    id: requestID,
                    url: "https://example.com/gap",
                    method: "GET"
                ),
                initiator: Network.Initiator(kind: "other"),
                resourceType: .fetch,
                redirectResponse: nil,
                timestamp: 1
            ),
            target: fixture.target
        )
        // CSS is not configured. This event advances the connection sequence
        // without producing a model record; the next Network delta must still
        // be accepted.
        try await fixture.runtime.wire.emitRaw(
            .mediaQueryResultChanged,
            target: fixture.target
        )
        try await fixture.runtime.wire.emitRaw(
            .responseReceived(
                id: requestID,
                response: Network.Response(
                    url: "https://example.com/gap",
                    status: 204,
                    mimeType: "text/plain"
                ),
                resourceType: .fetch,
                timestamp: 2
            ),
            target: fixture.target
        )

        try await waitUntil {
            try fixture.context.networkRequest(
                id: NetworkRequest.ID(requestID)
            )?.status == 204
        }
        #expect(fixture.context.state == .attached)
    }
}

@MainActor
@Test
func restoredPageReusesCSSAgentAndKeepsModelContextAttached() async throws {
    let pageADocument = DOM.Node(
        id: DOM.Node.ID("page-a-document"),
        nodeType: 9,
        nodeName: "#document"
    )
    try await withAttachedModelContext(
        configuration: .init(domains: [.css]),
        document: pageADocument
    ) { fixture in
        let pageAGeneration = try #require(fixture.context.pageGeneration)

        let pageBDocument = DOM.Node(
            id: DOM.Node.ID("page-b-document"),
            nodeType: 9,
            nodeName: "#document"
        )
        await enqueueStartupReplies(
            on: fixture.runtime.wire,
            configuration: fixture.configuration,
            document: pageBDocument
        )
        try await fixture.runtime.peer.createTarget(.init(
            id: "page-b",
            type: "page",
            frameID: "main-frame",
            isProvisional: true
        ))
        let pageBBaseline = fixture.runtime.wire.observations.commands.count
        try await fixture.runtime.peer.commitProvisionalTarget(
            from: "page-main",
            to: "page-b"
        )
        try await waitUntil {
            guard fixture.context.state == .attached,
                  fixture.context.pageGeneration != pageAGeneration else {
                return false
            }
            return try fixture.context.rootDOMNode?.id
                == DOMNode.ID(DOM.Node.ID("page-b-document"))
        }

        let pageBGeneration = try #require(fixture.context.pageGeneration)
        let pageBCommands = Array(
            fixture.runtime.wire.observations.commands.dropFirst(pageBBaseline)
        )
        let pageBMethods = pageBCommands.map(\.method)
        #expect(pageBCommands.count == 3)
        #expect(Set(pageBMethods) == Set([
            "DOM.getDocument",
            "Page.enable",
            "CSS.enable",
        ]))
        let pageEnableIndex = try #require(
            pageBMethods.firstIndex(of: "Page.enable")
        )
        let cssEnableIndex = try #require(
            pageBMethods.firstIndex(of: "CSS.enable")
        )
        #expect(pageEnableIndex < cssEnableIndex)
        #expect(pageBCommands.allSatisfy {
            $0.destination == .target("page-b")
        })

        let restoredDocument = DOM.Node(
            id: DOM.Node.ID("page-a-restored-document"),
            nodeType: 9,
            nodeName: "#document"
        )
        await fixture.runtime.wire.respond(
            to: "DOM.getDocument",
            with: try domDocumentResult(restoredDocument)
        )
        await fixture.runtime.wire.respond(
            to: "CSS.getAllStyleSheets",
            with: try testJSONObject(
                #"{"headers":[{"styleSheetId":"restored-sheet","frameId":"main-frame","origin":"author","sourceURL":"https://example.test/restored.css"}]}"#
            )
        )
        try await fixture.runtime.peer.createTarget(.init(
            id: "page-main",
            type: "page",
            frameID: "main-frame",
            isProvisional: true
        ))
        let restorationBaseline = fixture.runtime.wire.observations.commands.count
        try await fixture.runtime.peer.commitProvisionalTarget(
            from: "page-b",
            to: "page-main"
        )
        try await waitUntil {
            guard fixture.context.state == .attached,
                  fixture.context.pageGeneration != pageBGeneration else {
                return false
            }
            return try fixture.context.rootDOMNode?.id
                == DOMNode.ID(DOM.Node.ID("page-a-restored-document"))
        }

        let restorationCommands = Array(
            fixture.runtime.wire.observations.commands.dropFirst(restorationBaseline)
        )
        let restorationMethods = restorationCommands.map(\.method)
        #expect(restorationCommands.count == 2)
        #expect(Set(restorationMethods) == Set([
            "DOM.getDocument",
            "CSS.getAllStyleSheets",
        ]))
        #expect(!restorationMethods.contains("Page.enable"))
        #expect(!restorationMethods.contains("CSS.enable"))
        #expect(!restorationMethods.contains("CSS.disable"))
        #expect(restorationCommands.allSatisfy {
            $0.destination == .target("page-main")
        })
        #expect(fixture.context.state == .attached)
    }
}

@MainActor
@Test
func attachmentDrainsLargeEnableReplayBeforePublishingReadiness() async throws {
    try await withDataKitTestRuntime { runtime in
        let target = try await runtime.proxy.waitForCurrentPage()
        let configuration = WebInspectorModelContext.Configuration(
            domains: [.network]
        )
        let context = WebInspectorModelContext(configuration: configuration)
        let enableGate = await runtime.wire.deferReply(
            to: "Network.enable",
            with: try testJSONObject(#"{}"#)
        )
        let attachment = Task {
            try await context.attach(
                to: runtime.proxy,
                isolation: MainActor.shared
            )
        }
        _ = await runtime.wire.observations.waitForCommands(
            method: "Network.enable",
            count: 1
        )

        let replayEventCount = 512
        for index in 0..<replayEventCount {
            let id = Network.Request.ID("enable-replay-\(index)")
            try await runtime.wire.emitRaw(
                .requestWillBeSent(
                    id: id,
                    request: Network.Request(
                        id: id,
                        url: "https://example.com/\(index)",
                        method: "GET"
                    ),
                    initiator: Network.Initiator(kind: "other"),
                    resourceType: .fetch,
                    redirectResponse: nil,
                    timestamp: Double(index)
                ),
                target: target
            )
        }
        enableGate.open()

        try await attachment.value
        #expect(context.state == .attached)
        #expect(try context.networkRequest(
            id: NetworkRequest.ID(Network.Request.ID("enable-replay-511"))
        ) != nil)

        await runtime.wire.respond(to: "Network.disable")
        await context.close()
    }
}

@MainActor
@Test
func closeClearsAttachmentOwnedModelsAndBecomesTerminal() async throws {
    try await withDataKitTestRuntime { runtime in
        let configuration = WebInspectorModelContext.Configuration(domains: [.network])
        let fixture = try await attachModelContext(
            runtime: runtime,
            configuration: configuration
        )
        let requestID = Network.Request.ID("close-request")
        try await emitFinishedRequest(
            id: requestID,
            target: fixture.target,
            wire: runtime.wire
        )
        try await waitUntil {
            try fixture.context.networkRequest(id: NetworkRequest.ID(requestID)) != nil
        }

        await enqueueShutdownReplies(
            on: runtime.wire,
            configuration: configuration
        )
        await fixture.context.close()

        #expect(fixture.context.state == .closed)
        #expect(try fixture.context.networkRequest(id: NetworkRequest.ID(requestID)) == nil)
        await #expect(throws: WebInspectorModelContext.TransitionError.closed) {
            try await fixture.context.attach(to: runtime.proxy, isolation: MainActor.shared)
        }
    }
}

@MainActor
@Test
func concurrentResponseBodyCallersJoinOneProtocolRequest() async throws {
    try await withAttachedModelContext(
        configuration: .init(domains: [.network])
    ) { fixture in
        let requestID = Network.Request.ID("joined-body")
        try await emitFinishedRequest(
            id: requestID,
            target: fixture.target,
            wire: fixture.runtime.wire
        )
        let request = try await requireRequest(
            requestID,
            in: fixture.context
        )
        let gate = await fixture.runtime.wire.deferReply(
            to: "Network.getResponseBody",
            with: try rawNetworkBodyResult(
                Network.Body(data: "shared", base64Encoded: false)
            )
        )

        let expectedBody = request.responseBody
        let first = Task {
            let body = try await fixture.context.responseBody(for: request)
            return body === expectedBody
        }
        let second = Task {
            let body = try await fixture.context.responseBody(for: request)
            return body === expectedBody
        }
        _ = await fixture.runtime.wire.observations.waitForCommands(
            method: "Network.getResponseBody",
            count: 1
        )
        first.cancel()
        gate.open()

        await #expect(throws: CancellationError.self) {
            try await first.value
        }
        let secondUsedSameBody = try await second.value
        #expect(secondUsedSameBody)
        #expect(expectedBody === request.responseBody)
        #expect(expectedBody.phase == .loaded)
        #expect(expectedBody.text == "shared")
        #expect(fixture.runtime.wire.observations.commands.filter {
            $0.method == "Network.getResponseBody"
        }.count == 1)
    }
}

@MainActor
@Test
func clearingNetworkInvalidatesEveryJoinedResponseBodyWaiter() async throws {
    try await withAttachedModelContext(
        configuration: .init(domains: [.network])
    ) { fixture in
        let requestID = Network.Request.ID("cleared-body")
        try await emitFinishedRequest(
            id: requestID,
            target: fixture.target,
            wire: fixture.runtime.wire
        )
        let request = try await requireRequest(
            requestID,
            in: fixture.context
        )
        let body = request.responseBody
        let gate = await fixture.runtime.wire.deferReply(
            to: "Network.getResponseBody",
            with: try rawNetworkBodyResult(
                Network.Body(data: "late", base64Encoded: false)
            )
        )
        let first = Task {
            _ = try await fixture.context.responseBody(for: request)
        }
        let second = Task {
            _ = try await fixture.context.responseBody(for: request)
        }
        _ = await fixture.runtime.wire.observations.waitForCommands(
            method: "Network.getResponseBody",
            count: 1
        )

        await fixture.context.clearNetworkRequests()
        await #expect(throws: WebInspectorProxyError.staleIdentifier) {
            try await first.value
        }
        await #expect(throws: WebInspectorProxyError.staleIdentifier) {
            try await second.value
        }
        guard case .failed(.proxy(.staleIdentifier)) = body.phase else {
            Issue.record("Expected the cleared response body to become stale.")
            return
        }
        #expect(try fixture.context.networkRequest(id: NetworkRequest.ID(requestID)) == nil)
        gate.open()
    }
}

@MainActor
@Test
func responseBodyPreflightFailurePublishesTypedBodyFailure() async {
    let context = WebInspectorModelContext.preview(
        configuration: .init(domains: [.network])
    )
    let requestID = Network.Request.ID("stale-body-preflight")
    let request = NetworkRequest(
        request: Network.Request(
            id: requestID,
            url: "https://example.com/stale",
            method: "GET"
        ),
        initiator: nil,
        resourceType: .fetch,
        timestamp: 1,
        modelContext: context
    )

    await #expect(throws: WebInspectorModelError.staleModel) {
        _ = try await context.responseBody(for: request)
    }
    #expect(request.responseBody.phase == .failed(.model(.staleModel)))
}

@MainActor
@Test
func unfinishedResponseBodyPreflightRemainsRetryableAfterLoadingFinishes() async throws {
    try await withAttachedModelContext(
        configuration: .init(domains: [.network])
    ) { fixture in
        let requestID = Network.Request.ID("retryable-body-preflight")
        try await fixture.runtime.wire.emitRaw(
            .requestWillBeSent(
                id: requestID,
                request: Network.Request(
                    id: requestID,
                    url: "https://example.com/retryable-body-preflight",
                    method: "GET"
                ),
                initiator: Network.Initiator(kind: "other"),
                resourceType: .fetch,
                redirectResponse: nil,
                timestamp: 1
            ),
            target: fixture.target
        )
        try await fixture.runtime.wire.emitRaw(
            .responseReceived(
                id: requestID,
                response: Network.Response(
                    url: "https://example.com/retryable-body-preflight",
                    status: 200,
                    mimeType: "text/plain"
                ),
                resourceType: .fetch,
                timestamp: 2
            ),
            target: fixture.target
        )
        try await waitUntil {
            try fixture.context.networkRequest(
                id: NetworkRequest.ID(requestID)
            )?.state == .responded
        }
        let request = try #require(
            try fixture.context.networkRequest(id: NetworkRequest.ID(requestID))
        )
        let body = request.responseBody

        await #expect(throws: WebInspectorModelError.commandRejected(
            method: "Network.getResponseBody",
            message: "The response body is not available for this request."
        )) {
            _ = try await fixture.context.responseBody(for: request)
        }
        #expect(body.phase == .available)
        #expect(fixture.runtime.wire.observations.commands.contains {
            $0.method == "Network.getResponseBody"
        } == false)

        await fixture.runtime.wire.respond(
            to: "Network.getResponseBody",
            with: try rawNetworkBodyResult(
                Network.Body(data: "loaded after finish", base64Encoded: false)
            )
        )
        try await fixture.runtime.wire.emitRaw(
            .loadingFinished(
                id: requestID,
                timestamp: 3,
                sourceMapURL: nil,
                metrics: nil
            ),
            target: fixture.target
        )
        try await waitUntil { request.state == .finished }

        let loadedBody = try await fixture.context.responseBody(for: request)
        #expect(loadedBody === body)
        #expect(body.phase == .loaded)
        #expect(body.text == "loaded after finish")
        #expect(fixture.runtime.wire.observations.commands.filter {
            $0.method == "Network.getResponseBody"
        }.count == 1)
    }
}

@MainActor
@Test
func loadingFailureTerminatesResponseBodyWithWebKitReason() {
    let context = WebInspectorModelContext.preview(
        configuration: .init(domains: [.network])
    )
    let requestID = Network.Request.ID("failed-body")
    let request = NetworkRequest(
        request: Network.Request(
            id: requestID,
            url: "https://example.com/failed.mp4",
            method: "GET"
        ),
        initiator: nil,
        resourceType: .media,
        timestamp: 1,
        modelContext: context
    )
    request.applyResponse(
        Network.Response(
            url: "https://example.com/failed.mp4",
            status: 200,
            mimeType: "video/mp4"
        ),
        resourceType: .media,
        timestamp: 2
    )

    request.fail(
        errorText: "The media connection was interrupted.",
        canceled: false,
        timestamp: 3
    )

    #expect(
        request.responseBody.phase == .failed(.loadingFailed(
            errorText: "The media connection was interrupted.",
            canceled: false
        ))
    )
}

@MainActor
@Test
func elementPickerSelectsResolvedNodeAndBalancesItsScopedLease() async throws {
    let selectedID = DOM.Node.ID("42")
    let document = DOM.Node(
        id: DOM.Node.ID("document"),
        nodeType: 9,
        nodeName: "#document",
        children: [
            DOM.Node(
                id: selectedID,
                nodeType: 1,
                nodeName: "BUTTON",
                localName: "button"
            )
        ]
    )
    try await withAttachedModelContext(
        configuration: .init(domains: [.dom]),
        document: document
    ) { fixture in
        await fixture.runtime.wire.respond(to: "Inspector.enable")
        await fixture.runtime.wire.respond(to: "Inspector.initialized")
        await fixture.runtime.wire.respond(to: "DOM.setInspectModeEnabled")
        await fixture.runtime.wire.respond(
            to: "DOM.requestNode",
            with: try testJSONObject(#"{"nodeId":42}"#)
        )
        await fixture.runtime.wire.respond(to: "DOM.setInspectModeEnabled")
        await fixture.runtime.wire.respond(to: "Inspector.disable")

        try await fixture.context.setElementPickerEnabled(true)
        #expect(try fixture.context.isElementPickerEnabled)
        try await fixture.runtime.wire.emitTargetEvent(
            targetID: wireTargetID(fixture.target),
            method: "Inspector.inspect",
            parameters: try testJSONObject(
                #"{"object":{"objectId":"remote-node","type":"object","subtype":"node"},"hints":{}}"#
            )
        )

        try await waitUntil {
            try fixture.context.selectedDOMNode?.id == DOMNode.ID(selectedID)
                && fixture.context.isElementPickerEnabled == false
        }
        let methods = fixture.runtime.wire.observations.commandMethods
        #expect(methods.containsSubsequence([
            "Inspector.enable",
            "Inspector.initialized",
            "DOM.setInspectModeEnabled",
            "DOM.requestNode",
            "DOM.setInspectModeEnabled",
            "Inspector.disable",
        ]))
    }
}

@MainActor
@Test
func explicitDOMSelectionSupersedesPendingPickerResolution() async throws {
    let inspectedID = DOM.Node.ID("42")
    let manualID = DOM.Node.ID("manual")
    let document = DOM.Node(
        id: DOM.Node.ID("document"),
        nodeType: 9,
        nodeName: "#document",
        children: [
            DOM.Node(id: inspectedID, nodeType: 1, nodeName: "DIV", localName: "div"),
            DOM.Node(id: manualID, nodeType: 1, nodeName: "BUTTON", localName: "button"),
        ]
    )
    try await withAttachedModelContext(
        configuration: .init(domains: [.dom]),
        document: document
    ) { fixture in
        await fixture.runtime.wire.respond(to: "Inspector.enable")
        await fixture.runtime.wire.respond(to: "Inspector.initialized")
        await fixture.runtime.wire.respond(to: "DOM.setInspectModeEnabled")
        let requestNodeGate = await fixture.runtime.wire.deferReply(
            to: "DOM.requestNode",
            with: try testJSONObject(#"{"nodeId":42}"#)
        )
        await fixture.runtime.wire.respond(to: "DOM.setInspectModeEnabled")
        await fixture.runtime.wire.respond(to: "Inspector.disable")

        try await fixture.context.setElementPickerEnabled(true)
        try await fixture.runtime.wire.emitTargetEvent(
            targetID: wireTargetID(fixture.target),
            method: "Inspector.inspect",
            parameters: try testJSONObject(
                #"{"object":{"objectId":"remote-node","type":"object","subtype":"node"},"hints":{}}"#
            )
        )
        _ = await fixture.runtime.wire.observations.waitForCommands(
            method: "DOM.requestNode",
            count: 1
        )
        let manual = try #require(
            try fixture.context.domNode(id: DOMNode.ID(manualID))
        )
        try fixture.context.selectDOMNode(manual)
        requestNodeGate.open()

        try await waitUntil {
            try fixture.context.isElementPickerEnabled == false
        }
        #expect(try fixture.context.selectedDOMNode === manual)
    }
}

@MainActor
@Test
func documentResetHidesRecordedPageHighlight() async throws {
    let highlightedID = DOM.Node.ID("highlighted-node")
    let document = DOM.Node(
        id: DOM.Node.ID("highlight-document"),
        nodeType: 9,
        nodeName: "#document",
        children: [
            DOM.Node(
                id: highlightedID,
                nodeType: 1,
                nodeName: "MAIN",
                localName: "main"
            ),
        ]
    )
    try await withAttachedModelContext(
        configuration: .init(domains: [.dom]),
        document: document
    ) { fixture in
        let highlightedNode = try #require(
            try fixture.context.domNode(id: DOMNode.ID(highlightedID))
        )
        await fixture.runtime.wire.respond(to: "DOM.highlightNode")
        try await fixture.context.highlightDOMNode(highlightedNode)

        await fixture.runtime.wire.respond(to: "DOM.hideHighlight")
        await fixture.runtime.wire.respond(
            to: "DOM.getDocument",
            with: try domDocumentResult(DOM.Node(
                id: DOM.Node.ID("replacement-document"),
                nodeType: 9,
                nodeName: "#document"
            ))
        )
        try await fixture.runtime.wire.emitRaw(.documentUpdated, target: fixture.target)

        _ = await fixture.runtime.wire.observations.waitForCommands(
            method: "DOM.hideHighlight",
            count: 1
        )
        #expect(fixture.runtime.wire.observations.commands.filter {
            $0.method == "DOM.hideHighlight"
        }.count == 1)
    }
}

@MainActor
@Test
func runtimeObjectGroupsUseUniqueWireNamesAndReleaseExactlyOnce() async throws {
    try await withAttachedModelContext(
        configuration: .init(domains: [.runtime])
    ) { fixture in
        await fixture.runtime.wire.respond(to: "Runtime.releaseObjectGroup")
        await fixture.runtime.wire.respond(to: "Runtime.releaseObjectGroup")

        try await fixture.context.withRuntimeObjectGroup(named: "first group") { group in
            #expect(group.isClosed == false)
        }
        try await fixture.context.withRuntimeObjectGroup(named: "second group") { group in
            #expect(group.isClosed == false)
        }

        let releases = fixture.runtime.wire.observations.commands.filter {
            $0.method == "Runtime.releaseObjectGroup"
        }
        #expect(releases.count == 2)
        let names = try releases.map {
            try commandStringParameter($0, "objectGroup")
        }
        #expect(Set(names).count == 2)
        #expect(names[0].contains("first_group"))
        #expect(names[1].contains("second_group"))
    }
}

@MainActor
@Test
func runtimeGroupCleanupFailureLeavesGroupRetryableAndItsObjectUsable() async throws {
    try await withAttachedModelContext(
        configuration: .init(domains: [.runtime])
    ) { fixture in
        await fixture.runtime.wire.respond(
            to: "Runtime.evaluate",
            with: try rawRuntimeEvaluationResult(Runtime.EvaluationResult(
                object: Runtime.RemoteObject(
                    id: Runtime.RemoteObject.ID("retry-object"),
                    kind: .object,
                    description: "object"
                )
            ))
        )
        await fixture.runtime.wire.fail(
            "Runtime.releaseObjectGroup",
            message: "transient release failure"
        )
        var capturedGroup: RuntimeObjectGroup?
        var capturedObject: RuntimeObject?

        await #expect(throws: WebInspectorProxyError.self) {
            try await fixture.context.withRuntimeObjectGroup(named: "retry") { group in
                capturedGroup = group
                capturedObject = try await group.evaluate("({ value: 1 })").object
            }
        }

        let group = try #require(capturedGroup)
        let object = try #require(capturedObject)
        #expect(group.isClosed == false)
        await fixture.runtime.wire.respond(
            to: "Runtime.getProperties",
            with: try rawRuntimePropertiesResult([])
        )
        #expect(try await group.properties(of: object).isEmpty)

        await fixture.runtime.wire.respond(to: "Runtime.releaseObjectGroup")
        try await group.close()
        #expect(group.isClosed)
        await #expect(throws: WebInspectorModelError.staleModel) {
            _ = try await group.properties(of: object)
        }
        #expect(fixture.runtime.wire.observations.commands.filter {
            $0.method == "Runtime.releaseObjectGroup"
        }.count == 2)
    }
}

@MainActor
@Test
func runtimeGroupPreservesOperationAndCleanupFailures() async throws {
    try await withAttachedModelContext(
        configuration: .init(domains: [.runtime])
    ) { fixture in
        await fixture.runtime.wire.fail(
            "Runtime.releaseObjectGroup",
            message: "cleanup failed"
        )

        do {
            try await fixture.context.withRuntimeObjectGroup { _ in
                throw ModelContextTestFailure.operation
            }
            Issue.record("Expected both Runtime scope failures.")
        } catch let error as WebInspectorRuntimeScopeError {
            #expect(error.operationError is ModelContextTestFailure)
            #expect(error.cleanupError is WebInspectorProxyError)
        }
    }
}

@MainActor
@Test
func runtimeGroupCleansUpWhenTheOperationIsCancelled() async throws {
    try await withAttachedModelContext(
        configuration: .init(domains: [.runtime])
    ) { fixture in
        await fixture.runtime.wire.respond(to: "Runtime.releaseObjectGroup")

        await #expect(throws: CancellationError.self) {
            try await fixture.context.withRuntimeObjectGroup { _ in
                throw CancellationError()
            }
        }
        #expect(fixture.runtime.wire.observations.commands.filter {
            $0.method == "Runtime.releaseObjectGroup"
        }.count == 1)
    }
}

@MainActor
@Test
func cssPropertyIdentitySurvivesRefreshAndQueuedMutationTouchesOnlySubmittedProperty() async throws {
    let bodyID = DOM.Node.ID("body")
    let document = DOM.Node(
        id: DOM.Node.ID("document"),
        nodeType: 9,
        nodeName: "#document",
        children: [
            DOM.Node(
                id: bodyID,
                nodeType: 1,
                nodeName: "BODY",
                localName: "body"
            ),
        ]
    )
    try await withAttachedModelContext(
        configuration: .init(domains: [.css]),
        document: document
    ) { fixture in
        let body = try #require(try fixture.context.domNode(id: DOMNode.ID(bodyID)))
        let initialStyle = cssTestStyle(margin: "0", paddingStatus: .active)
        try await enqueueCSSLoadReplies(style: initialStyle, on: fixture.runtime.wire)
        let styles = try await fixture.context.cssStyles(for: body)
        let initialSection = try #require(styles.sections.first)
        let margin = try #require(initialSection.style.properties.first { $0.name == "margin" })
        let padding = try #require(initialSection.style.properties.first { $0.name == "padding" })

        let stalePadding = CSSStyleProperty(
            id: padding.id,
            name: padding.name,
            value: padding.value,
            text: padding.text,
            status: padding.status,
            isEditable: padding.isEditable
        )
        await #expect(throws: WebInspectorModelError.staleModel) {
            _ = try await fixture.context.setCSSProperty(
                stalePadding,
                enabled: false,
                undo: .disabled
            )
        }
        #expect(stalePadding.isMutationPending == false)

        let refreshedStyle = cssTestStyle(margin: "4px", paddingStatus: .active)
        let matchedReply = await fixture.runtime.wire.deferReply(
            to: "CSS.getMatchedStylesForNode",
            with: try rawCSSMatchedStylesResult(cssMatchedStyles(style: refreshedStyle))
        )
        await fixture.runtime.wire.respond(
            to: "CSS.getInlineStylesForNode",
            with: try rawCSSInlineStylesResult(.init())
        )
        await fixture.runtime.wire.respond(
            to: "CSS.getComputedStyleForNode",
            with: try rawCSSComputedStyleResult([])
        )
        let refresh = Task {
            try await fixture.context.refreshCSSStyles(for: body)
        }
        _ = await fixture.runtime.wire.observations.waitForCommands(
            method: "CSS.getMatchedStylesForNode",
            count: 2
        )

        let disabledPaddingStyle = cssTestStyle(margin: "4px", paddingStatus: .disabled)
        await fixture.runtime.wire.respond(
            to: "CSS.setStyleText",
            with: try rawCSSStyleResult(disabledPaddingStyle)
        )
        let toggle = Task {
            _ = try await fixture.context.setCSSProperty(
                padding,
                enabled: false,
                undo: .disabled
            )
        }
        try await waitUntil { padding.isMutationPending }

        #expect(margin.isMutationPending == false)
        #expect(fixture.runtime.wire.observations.commands.filter {
            $0.method == "CSS.setStyleText"
        }.isEmpty)

        matchedReply.open()
        try await refresh.value
        let setStyleCommand = await fixture.runtime.wire.observations.waitForCommands(
            method: "CSS.setStyleText",
            count: 1
        ).last
        #expect(try setStyleCommand.map { try commandStringParameter($0, "text") }
            == "margin: 4px;\n/* padding: 8px; */")
        _ = try await toggle.value

        let currentSection = try #require(styles.sections.first)
        let currentMargin = try #require(currentSection.style.properties.first { $0.name == "margin" })
        let currentPadding = try #require(currentSection.style.properties.first { $0.name == "padding" })
        #expect(currentMargin === margin)
        #expect(currentPadding === padding)
        #expect(margin.value == "4px")
        #expect(margin.status == .active)
        #expect(margin.isMutationPending == false)
        #expect(padding.status == .disabled)
        #expect(padding.text == "/* padding: 8px; */")
        #expect(padding.isMutationPending == false)

        let structurallyChangedStyle = cssTestStyleWithLeadingColor()
        styles.load(
            matchedStyles: cssMatchedStyles(style: structurallyChangedStyle),
            inlineStyles: .init(),
            computedProperties: []
        )
        let changedSection = try #require(styles.sections.first)
        let replacementAtOldMarginID = try #require(changedSection.style.properties.first)
        let shiftedMargin = try #require(
            changedSection.style.properties.first { $0.name == "margin" }
        )
        #expect(replacementAtOldMarginID.id == margin.id)
        #expect(replacementAtOldMarginID.name == "color")
        #expect(replacementAtOldMarginID !== margin)
        #expect(shiftedMargin !== margin)
        await #expect(throws: WebInspectorModelError.staleModel) {
            _ = try await fixture.context.setCSSProperty(
                margin,
                enabled: false,
                undo: .disabled
            )
        }
    }
}

@MainActor
@Test
func cancellingCSSLoadingRestoresRefreshableResourcePhase() throws {
    let context = WebInspectorModelContext.preview()
    let styles = CSSStyles(
        nodeID: DOMNode.ID(DOM.Node.ID("cancelled-node")),
        modelContext: context
    )

    styles.cancelLoading()
    #expect(styles.phase == .unavailable)

    styles.load(
        matchedStyles: .init(),
        inlineStyles: .init(),
        computedProperties: []
    )
    styles.markLoading()
    styles.cancelLoading()

    #expect(styles.phase == .needsRefresh)
    #expect(styles.sections.isEmpty)
}

@MainActor
@Test
func cancellingQueuedCSSOperationDoesNotChangeActiveLoadingPhase() async throws {
    let context = WebInspectorModelContext.preview()
    let styles = CSSStyles(
        nodeID: DOMNode.ID(DOM.Node.ID("queued-cancellation-node")),
        modelContext: context
    )
    let holderEntered = DataKitRawWireGate()
    let releaseHolder = DataKitRawWireGate()
    let holder = Task {
        try await styles.withExclusiveOperation {
            holderEntered.open()
            await releaseHolder.waiter.wait()
        }
    }
    await holderEntered.waiter.wait()

    let queued = Task {
        try await styles.withExclusiveOperation {}
    }
    await Task.yield()
    queued.cancel()

    await #expect(throws: CancellationError.self) {
        try await queued.value
    }
    #expect(styles.phase == .loading)

    releaseHolder.open()
    try await holder.value
}

@MainActor
@Test
func cancellingInFlightCSSLoadPreservesCancellationAndResourcePhase() async throws {
    let bodyID = DOM.Node.ID("cancelled-css-body")
    let document = DOM.Node(
        id: DOM.Node.ID("cancelled-css-document"),
        nodeType: 9,
        nodeName: "#document",
        children: [
            DOM.Node(
                id: bodyID,
                nodeType: 1,
                nodeName: "BODY",
                localName: "body"
            ),
        ]
    )
    try await withAttachedModelContext(
        configuration: .init(domains: [.css]),
        document: document
    ) { fixture in
        let body = try #require(try fixture.context.domNode(id: DOMNode.ID(bodyID)))
        let gate = await fixture.runtime.wire.deferReply(
            to: "CSS.getMatchedStylesForNode",
            with: try rawCSSMatchedStylesResult(.init())
        )
        let load = Task {
            _ = try await fixture.context.cssStyles(for: body)
        }
        _ = await fixture.runtime.wire.observations.waitForCommands(
            method: "CSS.getMatchedStylesForNode",
            count: 1
        )

        load.cancel()
        gate.open()

        await #expect(throws: CancellationError.self) {
            try await load.value
        }
        #expect(body.elementStyles?.phase == .unavailable)
    }
}

@MainActor
@Test
func cssTopologyChangePreservesInspectorBaselineForUnrelatedStyle() throws {
    let context = WebInspectorModelContext.preview()
    let styles = CSSStyles(
        nodeID: DOMNode.ID(DOM.Node.ID("baseline-node")),
        modelContext: context
    )
    let editedBefore = cssBaselineTestStyle(
        id: "edited-style",
        properties: [("color", "red")]
    )
    let unrelatedBefore = cssBaselineTestStyle(
        id: "unrelated-style",
        properties: [("margin", "0")]
    )
    styles.load(
        matchedStyles: cssBaselineMatchedStyles([editedBefore, unrelatedBefore]),
        inlineStyles: .init(),
        computedProperties: []
    )
    let editedProperty = try #require(
        styles.sections
            .flatMap(\.style.properties)
            .first { $0.name == "color" }
    )

    let editedAfter = cssBaselineTestStyle(
        id: "edited-style",
        properties: [("color", "blue")]
    )
    styles.applySetStyleText(result: editedAfter, for: editedProperty.id)
    #expect(editedProperty.isModifiedByInspector)

    let unrelatedAfter = cssBaselineTestStyle(
        id: "unrelated-style",
        properties: [("display", "block"), ("margin", "0")]
    )
    styles.load(
        matchedStyles: cssBaselineMatchedStyles([editedAfter, unrelatedAfter]),
        inlineStyles: .init(),
        computedProperties: []
    )

    #expect(editedProperty.isModifiedByInspector)
    #expect(
        styles.sections
            .flatMap(\.style.properties)
            .first { $0.name == "color" } === editedProperty
    )
}

@MainActor
@Test
func cssTopologyExpansionRekeysUniqueInspectorBaselinesWithinStyle() throws {
    let context = WebInspectorModelContext.preview()
    let styles = CSSStyles(
        nodeID: DOMNode.ID(DOM.Node.ID("expanded-baseline-node")),
        modelContext: context
    )
    let initialStyle = cssBaselineTestStyle(
        id: "expanded-style",
        properties: [("inset", "0"), ("height", "100%"), ("opacity", "0")]
    )
    styles.load(
        matchedStyles: cssBaselineMatchedStyles([initialStyle]),
        inlineStyles: .init(),
        computedProperties: []
    )

    let height = try #require(
        styles.sections
            .flatMap(\.style.properties)
            .first { $0.name == "height" }
    )
    let heightEditedStyle = cssBaselineTestStyle(
        id: "expanded-style",
        properties: [("inset", "0"), ("height", "50%"), ("opacity", "0")]
    )
    styles.applySetStyleText(result: heightEditedStyle, for: height.id)
    #expect(height.isModifiedByInspector)

    let inset = try #require(
        styles.sections
            .flatMap(\.style.properties)
            .first { $0.name == "inset" }
    )
    let expandedStyle = cssBaselineTestStyle(
        id: "expanded-style",
        properties: [
            ("inset", "1px"),
            ("top", "1px"),
            ("right", "1px"),
            ("bottom", "1px"),
            ("left", "1px"),
            ("height", "50%"),
            ("opacity", "0"),
        ]
    )
    styles.applySetStyleText(result: expandedStyle, for: inset.id)

    let editedProperties = styles.sections.flatMap(\.style.properties)
    #expect(editedProperties.first { $0.name == "inset" }?.isModifiedByInspector == true)
    #expect(editedProperties.first { $0.name == "height" }?.isModifiedByInspector == true)

    styles.load(
        matchedStyles: cssBaselineMatchedStyles([expandedStyle]),
        inlineStyles: .init(),
        computedProperties: []
    )
    let refreshedProperties = styles.sections.flatMap(\.style.properties)
    #expect(refreshedProperties.first { $0.name == "inset" }?.isModifiedByInspector == true)
    #expect(refreshedProperties.first { $0.name == "height" }?.isModifiedByInspector == true)
}

@MainActor
@Test
func sharedRuleInspectorBaselineFollowsStyleAcrossDOMNodes() throws {
    let context = WebInspectorModelContext.preview()
    let firstStyles = CSSStyles(
        nodeID: DOMNode.ID(DOM.Node.ID("first-shared-style-node")),
        modelContext: context
    )
    let secondStyles = CSSStyles(
        nodeID: DOMNode.ID(DOM.Node.ID("second-shared-style-node")),
        modelContext: context
    )
    let initialStyle = cssTestStyle(margin: "0", paddingStatus: .active)
    for styles in [firstStyles, secondStyles] {
        styles.load(
            matchedStyles: cssBaselineMatchedStyles([initialStyle]),
            inlineStyles: .init(),
            computedProperties: []
        )
    }

    let firstPadding = try #require(
        firstStyles.sections
            .flatMap(\.style.properties)
            .first { $0.name == "padding" }
    )
    let editedStyle = cssTestStyle(margin: "0", paddingStatus: .disabled)
    firstStyles.applySetStyleText(result: editedStyle, for: firstPadding.id)
    #expect(firstPadding.status == .disabled)
    #expect(firstPadding.isModifiedByInspector)

    secondStyles.load(
        matchedStyles: cssBaselineMatchedStyles([editedStyle]),
        inlineStyles: .init(),
        computedProperties: []
    )
    let secondPadding = try #require(
        secondStyles.sections
            .flatMap(\.style.properties)
            .first { $0.name == "padding" }
    )
    #expect(secondPadding !== firstPadding)
    #expect(secondPadding.status == .disabled)
    #expect(secondPadding.isModifiedByInspector)

    secondStyles.applySetStyleText(result: initialStyle, for: secondPadding.id)
    #expect(secondPadding.status == .active)
    #expect(secondPadding.isModifiedByInspector == false)

    firstStyles.load(
        matchedStyles: cssBaselineMatchedStyles([initialStyle]),
        inlineStyles: .init(),
        computedProperties: []
    )
    #expect(
        firstStyles.sections
            .flatMap(\.style.properties)
            .first { $0.name == "padding" }?
            .isModifiedByInspector == false
    )
}

@MainActor
@Test
func staleSharedRuleLoadCannotRetireInspectorBaseline() throws {
    let context = WebInspectorModelContext.preview()
    let editedStyles = CSSStyles(
        nodeID: DOMNode.ID(DOM.Node.ID("edited-shared-style-node")),
        modelContext: context
    )
    let staleStyles = CSSStyles(
        nodeID: DOMNode.ID(DOM.Node.ID("stale-shared-style-node")),
        modelContext: context
    )
    let initialStyle = cssBaselineTestStyle(
        id: "stale-shared-style",
        properties: [("color", "red")]
    )
    editedStyles.load(
        matchedStyles: cssBaselineMatchedStyles([initialStyle]),
        inlineStyles: .init(),
        computedProperties: []
    )
    let editedColor = try #require(editedStyles.sections.first?.style.properties.first)
    let editedStyle = cssBaselineTestStyle(
        id: "stale-shared-style",
        properties: [("color", "blue")]
    )
    editedStyles.applySetStyleText(result: editedStyle, for: editedColor.id)

    let staleResponseStyle = cssBaselineTestStyle(
        id: "stale-shared-style",
        properties: [("display", "block"), ("color", "red")]
    )
    staleStyles.load(
        matchedStyles: cssBaselineMatchedStyles([staleResponseStyle]),
        inlineStyles: .init(),
        computedProperties: []
    )
    editedStyles.load(
        matchedStyles: cssBaselineMatchedStyles([editedStyle]),
        inlineStyles: .init(),
        computedProperties: []
    )

    #expect(staleStyles.sections.first?.style.properties.first?.isModifiedByInspector == false)
    #expect(editedStyles.sections.first?.style.properties.first?.isModifiedByInspector == true)
}

@MainActor
@Test
func inspectorBaselinesDoNotAliasTargetScopedStyleIDs() throws {
    let context = WebInspectorModelContext.preview()
    let firstStyles = CSSStyles(
        nodeID: DOMNode.ID(DOM.Node.ID("first-target-node")),
        modelContext: context
    )
    let secondStyles = CSSStyles(
        nodeID: DOMNode.ID(DOM.Node.ID("second-target-node")),
        modelContext: context
    )
    let firstInitial = cssBaselineTestStyle(
        id: CSS.Style.ID("shared-style", scopedToTargetRawValue: "frame-a"),
        properties: [("color", "red")]
    )
    let secondInitial = cssBaselineTestStyle(
        id: CSS.Style.ID("shared-style", scopedToTargetRawValue: "frame-b"),
        properties: [("color", "red")]
    )
    firstStyles.load(
        matchedStyles: cssBaselineMatchedStyles([firstInitial]),
        inlineStyles: .init(),
        computedProperties: []
    )
    secondStyles.load(
        matchedStyles: cssBaselineMatchedStyles([secondInitial]),
        inlineStyles: .init(),
        computedProperties: []
    )

    let firstColor = try #require(firstStyles.sections.first?.style.properties.first)
    let firstEdited = cssBaselineTestStyle(
        id: CSS.Style.ID("shared-style", scopedToTargetRawValue: "frame-a"),
        properties: [("color", "blue")]
    )
    firstStyles.applySetStyleText(result: firstEdited, for: firstColor.id)

    let secondColor = try #require(secondStyles.sections.first?.style.properties.first)
    #expect(firstColor.isModifiedByInspector)
    #expect(secondColor.isModifiedByInspector == false)
}

@MainActor
@Test
func resettingFrameTargetRetiresOnlyItsInspectorBaselines() throws {
    let context = WebInspectorModelContext.preview()
    let firstTargetID = WebInspectorTarget.ID("frame-a")
    let secondTargetID = WebInspectorTarget.ID("frame-b")
    let firstStyles = CSSStyles(
        nodeID: DOMNode.ID(DOM.Node.ID("first-frame-node")),
        modelContext: context
    )
    let secondStyles = CSSStyles(
        nodeID: DOMNode.ID(DOM.Node.ID("second-frame-node")),
        modelContext: context
    )
    let firstInitial = cssBaselineTestStyle(
        id: CSS.Style.ID("reset-style", scopedToTargetRawValue: firstTargetID.rawValue),
        properties: [("color", "red")]
    )
    let secondInitial = cssBaselineTestStyle(
        id: CSS.Style.ID("reset-style", scopedToTargetRawValue: secondTargetID.rawValue),
        properties: [("color", "red")]
    )
    firstStyles.load(
        matchedStyles: cssBaselineMatchedStyles([firstInitial]),
        inlineStyles: .init(),
        computedProperties: []
    )
    secondStyles.load(
        matchedStyles: cssBaselineMatchedStyles([secondInitial]),
        inlineStyles: .init(),
        computedProperties: []
    )
    let firstColor = try #require(firstStyles.sections.first?.style.properties.first)
    let secondColor = try #require(secondStyles.sections.first?.style.properties.first)
    let firstEdited = cssBaselineTestStyle(
        id: CSS.Style.ID("reset-style", scopedToTargetRawValue: firstTargetID.rawValue),
        properties: [("color", "blue")]
    )
    let secondEdited = cssBaselineTestStyle(
        id: CSS.Style.ID("reset-style", scopedToTargetRawValue: secondTargetID.rawValue),
        properties: [("color", "blue")]
    )
    firstStyles.applySetStyleText(result: firstEdited, for: firstColor.id)
    secondStyles.applySetStyleText(result: secondEdited, for: secondColor.id)

    context.cssInspectorBaselineStore.reset(targetID: firstTargetID)
    firstStyles.load(
        matchedStyles: cssBaselineMatchedStyles([firstEdited]),
        inlineStyles: .init(),
        computedProperties: []
    )
    secondStyles.load(
        matchedStyles: cssBaselineMatchedStyles([secondEdited]),
        inlineStyles: .init(),
        computedProperties: []
    )

    #expect(firstStyles.sections.first?.style.properties.first?.isModifiedByInspector == false)
    #expect(secondStyles.sections.first?.style.properties.first?.isModifiedByInspector == true)
}

private struct AttachedModelFixture {
    let runtime: DataKitTestRuntime
    let target: WebInspectorTarget
    let context: WebInspectorModelContext
    let configuration: WebInspectorModelContext.Configuration
}

private func cssTestStyle(
    margin: String,
    paddingStatus: CSS.Status
) -> CSS.Style {
    let styleID = "test-style\u{1F}0"
    let paddingText = paddingStatus == .disabled
        ? "/* padding: 8px; */"
        : "padding: 8px;"
    return CSS.Style(
        id: CSS.Style.ID(styleID),
        properties: [
            CSS.Property(
                id: CSS.Property.ID("\(styleID)\u{1F}0"),
                name: "margin",
                value: margin,
                text: "margin: \(margin);",
                status: .active,
                isEditable: true
            ),
            CSS.Property(
                id: CSS.Property.ID("\(styleID)\u{1F}1"),
                name: "padding",
                value: "8px",
                text: paddingText,
                status: paddingStatus,
                isEditable: true
            ),
        ],
        cssText: "margin: \(margin);\n\(paddingText)",
        isEditable: true
    )
}

private func cssMatchedStyles(style: CSS.Style) -> CSS.MatchedStyles {
    CSS.MatchedStyles(matchedRules: [
        CSS.Rule(
            id: CSS.Rule.ID("test-rule\u{1F}0"),
            selectorList: CSS.Rule.SelectorList(selectors: ["body"], text: "body"),
            origin: CSS.Origin(rawValue: "author"),
            style: style
        ),
    ])
}

private func cssTestStyleWithLeadingColor() -> CSS.Style {
    let styleID = "test-style\u{1F}0"
    return CSS.Style(
        id: CSS.Style.ID(styleID),
        properties: [
            CSS.Property(
                id: CSS.Property.ID("\(styleID)\u{1F}0"),
                name: "color",
                value: "red",
                text: "color: red;",
                status: .active,
                isEditable: true
            ),
            CSS.Property(
                id: CSS.Property.ID("\(styleID)\u{1F}1"),
                name: "margin",
                value: "4px",
                text: "margin: 4px;",
                status: .active,
                isEditable: true
            ),
            CSS.Property(
                id: CSS.Property.ID("\(styleID)\u{1F}2"),
                name: "padding",
                value: "8px",
                text: "/* padding: 8px; */",
                status: .disabled,
                isEditable: true
            ),
        ],
        cssText: "color: red;\nmargin: 4px;\n/* padding: 8px; */",
        isEditable: true
    )
}

private func cssBaselineTestStyle(
    id: String,
    properties: [(name: String, value: String)]
) -> CSS.Style {
    cssBaselineTestStyle(id: CSS.Style.ID(id), properties: properties)
}

private func cssBaselineTestStyle(
    id: CSS.Style.ID,
    properties: [(name: String, value: String)]
) -> CSS.Style {
    let rawID = id.rawValue
    return CSS.Style(
        id: id,
        properties: properties.enumerated().map { index, property in
            CSS.Property(
                id: CSS.Property.ID("\(rawID)\u{1F}\(index)"),
                name: property.name,
                value: property.value,
                text: "\(property.name): \(property.value);",
                status: .active,
                isEditable: true
            )
        },
        cssText: properties
            .map { "\($0.name): \($0.value);" }
            .joined(separator: "\n"),
        isEditable: true
    )
}

private func cssBaselineMatchedStyles(_ styles: [CSS.Style]) -> CSS.MatchedStyles {
    CSS.MatchedStyles(
        matchedRules: styles.enumerated().map { index, style in
            CSS.Rule(
                id: CSS.Rule.ID("baseline-rule-\(index)"),
                selectorList: CSS.Rule.SelectorList(
                    selectors: [".baseline-\(index)"],
                    text: ".baseline-\(index)"
                ),
                origin: CSS.Origin(rawValue: "author"),
                style: style
            )
        }
    )
}

private func enqueueCSSLoadReplies(
    style: CSS.Style,
    on wire: DataKitRawWireDriver
) async throws {
    await wire.respond(
        to: "CSS.getMatchedStylesForNode",
        with: try rawCSSMatchedStylesResult(cssMatchedStyles(style: style))
    )
    await wire.respond(
        to: "CSS.getInlineStylesForNode",
        with: try rawCSSInlineStylesResult(.init())
    )
    await wire.respond(
        to: "CSS.getComputedStyleForNode",
        with: try rawCSSComputedStyleResult([])
    )
}

@MainActor
private func withAttachedModelContext<Output>(
    configuration: WebInspectorModelContext.Configuration,
    document: DOM.Node = DOM.Node(
        id: DOM.Node.ID("document"),
        nodeType: 9,
        nodeName: "#document"
    ),
    _ operation: @MainActor (AttachedModelFixture) async throws -> Output
) async throws -> Output {
    try await withDataKitTestRuntime { runtime in
        let fixture = try await attachModelContext(
            runtime: runtime,
            configuration: configuration,
            document: document
        )
        let result: Result<Output, any Error>
        do {
            result = .success(try await operation(fixture))
        } catch {
            result = .failure(error)
        }
        await enqueueShutdownReplies(
            on: runtime.wire,
            configuration: configuration
        )
        await fixture.context.close()
        return try result.get()
    }
}

@MainActor
private func attachModelContext(
    runtime: DataKitTestRuntime,
    configuration: WebInspectorModelContext.Configuration,
    document: DOM.Node = DOM.Node(
        id: DOM.Node.ID("document"),
        nodeType: 9,
        nodeName: "#document"
    )
) async throws -> AttachedModelFixture {
    let target = try await runtime.proxy.waitForCurrentPage()
    await enqueueStartupReplies(
        on: runtime.wire,
        configuration: configuration,
        document: document
    )
    let context = WebInspectorModelContext(configuration: configuration)
    try await context.attach(to: runtime.proxy, isolation: MainActor.shared)
    return AttachedModelFixture(
        runtime: runtime,
        target: target,
        context: context,
        configuration: configuration
    )
}

private func enqueueStartupReplies(
    on wire: DataKitRawWireDriver,
    configuration: WebInspectorModelContext.Configuration,
    document: DOM.Node
) async {
    if configuration.domains.contains(.css) {
        await wire.respond(to: "Page.enable")
        await wire.respond(to: "CSS.enable")
    }
    if configuration.domains.contains(.network) {
        await wire.respond(to: "Network.enable")
    }
    if configuration.domains.contains(.console) {
        await wire.respond(to: "Console.enable")
    }
    if configuration.domains.contains(.runtime) {
        await wire.respond(to: "Runtime.enable")
    }
    if configuration.domains.contains(.dom) {
        await wire.respond(
            to: "DOM.getDocument",
            with: try! domDocumentResult(document)
        )
    }
}

private func enqueueShutdownReplies(
    on wire: DataKitRawWireDriver,
    configuration: WebInspectorModelContext.Configuration
) async {
    if configuration.domains.contains(.runtime) {
        await wire.respond(to: "Runtime.disable")
    }
    if configuration.domains.contains(.console) {
        await wire.respond(to: "Console.disable")
    }
    if configuration.domains.contains(.network) {
        await wire.respond(to: "Network.disable")
    }
    if configuration.domains.contains(.css) {
        await wire.respond(to: "CSS.disable")
        await wire.respond(to: "Page.disable")
    }
}

private func emitFinishedRequest(
    id: Network.Request.ID,
    target: WebInspectorTarget,
    wire: DataKitRawWireDriver
) async throws {
    try await wire.emitRaw(
        .requestWillBeSent(
            id: id,
            request: Network.Request(
                id: id,
                url: "https://example.com/\(id.rawValue)",
                method: "GET"
            ),
            initiator: Network.Initiator(kind: "other"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    try await wire.emitRaw(
        .responseReceived(
            id: id,
            response: Network.Response(
                url: "https://example.com/\(id.rawValue)",
                status: 200,
                mimeType: "text/plain"
            ),
            resourceType: .fetch,
            timestamp: 2
        ),
        target: target
    )
    try await wire.emitRaw(
        .loadingFinished(
            id: id,
            timestamp: 3,
            sourceMapURL: nil,
            metrics: nil
        ),
        target: target
    )
}

@MainActor
private func requireRequest(
    _ id: Network.Request.ID,
    in context: WebInspectorModelContext
) async throws -> NetworkRequest {
    try await waitUntil {
        try context.networkRequest(id: NetworkRequest.ID(id))?.state == .finished
    }
    return try #require(
        try context.networkRequest(id: NetworkRequest.ID(id))
    )
}

@MainActor
private func waitUntil(
    _ condition: @MainActor () throws -> Bool
) async throws {
    for _ in 0..<2_000 {
        if try condition() {
            return
        }
        await Task.yield()
    }
    throw ModelContextTestFailure.timedOut
}

private enum ModelContextTestFailure: Error {
    case operation
    case timedOut
}

private extension Array where Element == String {
    func containsSubsequence(_ subsequence: [String]) -> Bool {
        var index = subsequence.startIndex
        for element in self where index < subsequence.endIndex {
            if element == subsequence[index] {
                subsequence.formIndex(after: &index)
            }
        }
        return index == subsequence.endIndex
    }
}
