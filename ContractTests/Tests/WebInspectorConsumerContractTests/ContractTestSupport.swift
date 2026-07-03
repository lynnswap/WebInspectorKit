import Foundation
import Testing
import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

enum ContractTestSupport {
    static func enqueueDataKitStartupReplies(
        on backend: WebInspectorTestBackend,
        document: DOM.Node = WebInspectorProxyTestFixtures.domDocument()
    ) async {
        await backend.enqueue((), for: "Runtime", method: "enable")
        await backend.enqueue((), for: "Network", method: "enable")
        await backend.enqueue(document, for: "DOM", method: "getDocument")
        await backend.enqueue((), for: "Console", method: "enable")
    }

    static func enqueueDataKitShutdownReplies(on backend: WebInspectorTestBackend) async {
        await backend.enqueue((), for: "Console", method: "disable")
        await backend.enqueue((), for: "Runtime", method: "disable")
        await backend.enqueue((), for: "Network", method: "disable")
    }

    @MainActor
    static func startDataKitContext(
        runtime: WebInspectorProxyTestRuntime,
        document: DOM.Node = WebInspectorProxyTestFixtures.domDocument()
    ) async throws -> (WebInspectorTarget, WebInspectorContainer, WebInspectorContext) {
        let target = try await runtime.proxy.waitForCurrentPage()
        await enqueueDataKitStartupReplies(on: runtime.backend, document: document)

        let container = WebInspectorContainer(proxy: runtime.proxy)
        let context = container.mainContext
        try await waitForDataKitSubscribers(runtime: runtime, target: target)
        try await waitUntil { context.state == .attached }
        return (target, container, context)
    }

    static func waitForDataKitSubscribers(
        runtime: WebInspectorProxyTestRuntime,
        target: WebInspectorTarget,
        count: Int = 1
    ) async throws {
        try await runtime.backend.waitForSubscribers(domain: "DOM", target: target, count: count)
        try await runtime.backend.waitForSubscribers(domain: "Inspector", target: target, count: count)
        try await runtime.backend.waitForSubscribers(domain: "CSS", target: target, count: count)
        try await runtime.backend.waitForSubscribers(domain: "Network", target: target, count: count)
        try await runtime.backend.waitForSubscribers(domain: "Console", target: target, count: count)
        try await runtime.backend.waitForSubscribers(domain: "Runtime", target: target, count: count)
    }

    static func emitFinishedRequest(
        _ request: Network.Request,
        target: WebInspectorTarget,
        backend: WebInspectorTestBackend
    ) async {
        await backend.emit(
            .requestWillBeSent(
                id: request.id,
                request: request,
                resourceType: .fetch,
                redirectResponse: nil,
                timestamp: 1
            ),
            target: target
        )
        await backend.emit(
            .responseReceived(
                id: request.id,
                response: Network.Response(
                    url: request.url,
                    status: 200,
                    statusText: "OK",
                    mimeType: "application/json",
                    headers: ["Content-Type": "application/json"],
                    source: Network.Source(rawValue: "network")
                ),
                resourceType: .fetch,
                timestamp: 2
            ),
            target: target
        )
        await backend.emit(
            .dataReceived(id: request.id, dataLength: 7, encodedDataLength: 4, timestamp: 3),
            target: target
        )
        await backend.emit(
            .loadingFinished(
                id: request.id,
                timestamp: 4,
                sourceMapURL: "data.json.map",
                metrics: Network.Metrics(encodedDataLength: 4, decodedBodyLength: 7)
            ),
            target: target
        )
    }

    static func waitUntil(
        timeout: Duration = .seconds(1),
        isolation: isolated (any Actor)? = #isolation,
        condition: () -> Bool
    ) async throws {
        _ = isolation
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while condition() == false {
            if clock.now >= deadline {
                throw TimedOut()
            }
            await Task.yield()
        }
    }

    static func waitUntil(
        timeout: Duration = .seconds(1),
        isolation: isolated (any Actor)? = #isolation,
        condition: () async -> Bool
    ) async throws {
        _ = isolation
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while await condition() == false {
            if clock.now >= deadline {
                throw TimedOut()
            }
            await Task.yield()
        }
    }

    static func value<T: Sendable>(
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
}

struct TimedOut: Error {}

actor ContractDataKitActor {
    nonisolated let inspectorContainer: WebInspectorContainer

    private let runtime: WebInspectorProxyTestRuntime
    private var context: WebInspectorContext?

    init(runtime: WebInspectorProxyTestRuntime, inspectorContainer: WebInspectorContainer? = nil) {
        self.runtime = runtime
        let container = inspectorContainer ?? WebInspectorContainer(proxy: runtime.proxy)
        self.inspectorContainer = container
        context = nil
    }

    @discardableResult
    func start(
        document: DOM.Node = WebInspectorProxyTestFixtures.domDocument(),
        expectedSubscriberCount: Int = 1
    ) async throws -> WebInspectorTarget {
        let context = modelContext()
        let target = try await runtime.proxy.waitForCurrentPage()
        await ContractTestSupport.enqueueDataKitStartupReplies(on: runtime.backend, document: document)
        context.start()
        try await ContractTestSupport.waitForDataKitSubscribers(
            runtime: runtime,
            target: target,
            count: expectedSubscriberCount
        )
        try await ContractTestSupport.waitUntil { context.state == .attached }
        return target
    }

    func assertPublicSurfaceIsUsable() async throws {
        let context = modelContext()
        let requestResults: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        let consoleResults: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()
        let sectionedRequests: WebInspectorFetchedResults<NetworkRequest> =
            context.fetchedResults(sectionBy: \.method)
        let sectionedConsole: WebInspectorFetchedResults<ConsoleMessage> =
            context.fetchedResults(sectionBy: \.level)
        let requestController: WebInspectorFetchedResultsController<NetworkRequest> =
            context.fetchedResultsController()
        let consoleController: WebInspectorFetchedResultsController<ConsoleMessage> =
            context.fetchedResultsController()

        #expect(requestResults.items.isEmpty)
        #expect(consoleResults.items.isEmpty)
        #expect(sectionedRequests.sections.isEmpty)
        #expect(sectionedConsole.sections.isEmpty)
        #expect(requestController.snapshot.itemIDs.isEmpty)
        #expect(consoleController.snapshot.itemIDs.isEmpty)
        _ = requestController.transactions
        _ = consoleController.transactions
        #expect(context.state == .attached)

        let root = try #require(context.rootNode)
        #expect(root.nodeName == "#document")
        #expect(context.node(for: root.id) === root)
        requirePersistentModel(root)

        let treeController = try await context.treeController()
        let treeSnapshot: DOMTreeSnapshot = treeController.snapshot
        #expect(treeSnapshot.rootNodeID == root.id)
        #expect(treeSnapshot.node(for: root.id)?.nodeName == "#document")
        _ = treeController.transactions

        context.select(root)
        #expect(context.selectedNode === root)
        context.select(nil)
        context.selectContext(nil)
        context.clearNetworkRequests()
        #expect(context.selectedNode == nil)
        #expect(context.selectedContext == nil)
    }

    func assertFakeBackendDrivesDOMNetworkAndRuntimeContracts() async throws {
        let context = modelContext()
        let document = WebInspectorProxyTestFixtures.domDocument(
            id: "contract-document",
            documentURL: "https://example.com/",
            childNodeCount: 1
        )
        let target = try await start(document: document)

        await runtime.backend.emit(
            .setChildNodes(parent: WebInspectorProxyTestFixtures.domNodeID("contract-document"), nodes: [
                WebInspectorProxyTestFixtures.domNode(
                    id: "contract-element",
                    nodeType: 1,
                    nodeName: "MAIN",
                    localName: "main",
                    attributes: ["data-contract": "dom"]
                ),
            ]),
            target: target
        )

        try await ContractTestSupport.waitUntil {
            guard let root = context.rootNode,
                  case let .loaded(children) = root.children else {
                return false
            }
            return children.first?.attributes["data-contract"] == "dom"
        }
        let root = try #require(context.rootNode)
        guard case let .loaded(children) = root.children else {
            Issue.record("Expected the seeded document to load children.")
            return
        }
        let child = try #require(children.first)
        #expect(context.node(for: child.id) === child)

        let request = WebInspectorProxyTestFixtures.networkRequest(
            id: "contract-request",
            url: "https://example.com/data.json",
            headers: ["Accept": "application/json"]
        )
        let requestController: WebInspectorFetchedResultsController<NetworkRequest> =
            context.fetchedResultsController()
        await ContractTestSupport.emitFinishedRequest(request, target: target, backend: runtime.backend)

        let requests: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        try await ContractTestSupport.waitUntil {
            requests.items.first?.state == .finished
        }
        let requestModel = try #require(requests.items.first)
        #expect(requestModel.url == "https://example.com/data.json")
        #expect(requestModel.method == "GET")
        #expect(requestModel.status == 200)
        #expect(requestModel.statusText == "OK")
        #expect(requestModel.responseURL == "https://example.com/data.json")
        #expect(requestModel.responseSource == "network")
        #expect(requestModel.responseHeaders["Content-Type"] == "application/json")
        #expect(requestModel.decodedDataLength == 7)
        #expect(requestModel.encodedDataLength == 4)
        #expect(requestModel.sourceMapURL == "data.json.map")
        #expect(requestModel.metrics?.encodedDataLength == 4)
        #expect(requestModel.metrics?.decodedBodyLength == 7)
        #expect(context.registeredRequest(for: requestModel.id) === requestModel)
        #expect(requestController.snapshot.itemIDs == [requestModel.id])

        await runtime.backend.enqueue(
            Network.Body(data: "{\"ok\":true}", base64Encoded: false),
            for: "Network",
            method: "getResponseBody"
        )
        await requestModel.fetchResponseBody()
        #expect(requestModel.responseBody.phase == .loaded)
        #expect(requestModel.responseBody.text == "{\"ok\":true}")
        #expect(requestModel.responseBody.isBase64Encoded == false)

        await runtime.backend.enqueue(
            Runtime.EvaluationResult(
                object: WebInspectorProxyTestFixtures.runtimeRemoteObject(
                    id: "contract-evaluation",
                    kind: .string,
                    description: "contract",
                    value: .string("contract")
                )
            ),
            for: "Runtime",
            method: "evaluate"
        )

        let evaluation = try await context.evaluate("document.title")
        #expect(evaluation.isException == false)
        #expect(evaluation.object.kind == .string)
        #expect(evaluation.object.value == .string("contract"))
        #expect(evaluation.object.description == "contract")
        #expect(evaluation.object.canRequestProperties)
    }

    func waitForConsoleMessage(text: String) async throws {
        let context = modelContext()
        let messages: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()
        try await ContractTestSupport.waitUntil {
            messages.items.contains { $0.text == text }
        }
    }

    private func modelContext() -> WebInspectorContext {
        if let context {
            return context
        }
        let context = WebInspectorContext(inspectorContainer, isolation: self)
        self.context = context
        return context
    }

    private func requirePersistentModel<Model: WebInspectorPersistentModel>(_ model: Model) {
        #expect(Set([model]).contains(model))
    }

    func stopContext(enqueueShutdownReplies: Bool = true) async {
        guard let context else {
            return
        }
        if enqueueShutdownReplies {
            await ContractTestSupport.enqueueDataKitShutdownReplies(on: runtime.backend)
        }
        await context.stop()
        #expect(context.state == .detached)
        #expect(context.teardownError == nil)
    }

    func close() async {
        await stopContext()
        await inspectorContainer.close()
    }
}
