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
        guard case .failed(.staleIdentifier) = body.phase else {
            Issue.record("Expected the cleared response body to become stale.")
            return
        }
        #expect(try fixture.context.networkRequest(id: NetworkRequest.ID(requestID)) == nil)
        gate.open()
    }
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

private struct AttachedModelFixture {
    let runtime: DataKitTestRuntime
    let target: WebInspectorTarget
    let context: WebInspectorModelContext
    let configuration: WebInspectorModelContext.Configuration
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
