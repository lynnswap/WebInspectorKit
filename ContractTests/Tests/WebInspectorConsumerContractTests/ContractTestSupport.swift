import Foundation
import Testing
import WebInspectorDataKit
import WebInspectorDataKitTesting
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

enum ContractTestSupport {
    static func enqueueDataKitStartupReplies(
        on backend: WebInspectorTestBackend,
        document: DOM.Node = WebInspectorProxyTestFixtures.domDocument(),
        requiresDomainEnableReplies: Bool = true,
        pageEnableFailure: WebInspectorProxyError? = nil
    ) async {
        if requiresDomainEnableReplies {
            await backend.enqueue((), for: "Inspector", method: "enable")
            await backend.enqueue((), for: "Inspector", method: "initialized")
            if let pageEnableFailure {
                await backend.enqueueFailure(pageEnableFailure, for: "Page", method: "enable")
            } else {
                await backend.enqueue((), for: "Page", method: "enable")
            }
            await backend.enqueue((), for: "Runtime", method: "enable")
            await backend.enqueue((), for: "Network", method: "enable")
            await backend.enqueue((), for: "Console", method: "enable")
        }
        await backend.enqueue(document, for: "DOM", method: "getDocument")
    }

    static func enqueueDataKitShutdownReplies(on backend: WebInspectorTestBackend) async {
        await backend.enqueue((), for: "Console", method: "disable")
        await backend.enqueue((), for: "Runtime", method: "disable")
        await backend.enqueue((), for: "Network", method: "disable")
        await backend.enqueue((), for: "Page", method: "disable")
        await backend.enqueue((), for: "Inspector", method: "disable")
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
                metrics: Network.Metrics(
                    networkProtocol: "h2",
                    remoteAddress: "203.0.113.30:443",
                    encodedDataLength: 4,
                    decodedBodyLength: 7
                )
            ),
            target: target
        )
    }

}

struct ContractEventStreamEnded: Error {}

@MainActor
final class ContractDataKitActor {
    private let runtime: WebInspectorProxyTestRuntime
    private let inspector = WebInspector()

    init(runtime: WebInspectorProxyTestRuntime) {
        self.runtime = runtime
    }

    @discardableResult
    func start(
        document: DOM.Node = WebInspectorProxyTestFixtures.domDocument(),
        requiresDomainEnableReplies: Bool = true,
        pageEnableFailure: WebInspectorProxyError? = nil
    ) async throws -> WebInspectorTarget {
        let target = try await runtime.proxy.waitForCurrentPage()
        await ContractTestSupport.enqueueDataKitStartupReplies(
            on: runtime.backend,
            document: document,
            requiresDomainEnableReplies: requiresDomainEnableReplies,
            pageEnableFailure: pageEnableFailure
        )
        if pageEnableFailure != nil {
            await runtime.backend.enqueue((), for: "Inspector", method: "disable")
        }
        try await inspector.attachForTesting(to: runtime.proxy)
        return target
    }

    func assertPublicSurfaceIsUsable() async throws {
        let context = modelContext()
        #expect(context.network.requests.isEmpty)
        #expect(context.console.messages.isEmpty)
        let _: AsyncStream<WebInspectorCollectionChange<NetworkRequest>> = context.network.requestChanges
        let _: AsyncStream<WebInspectorCollectionChange<ConsoleMessage>> = context.console.messageChanges
        #expect(context.state == .attached)

        let root = try #require(context.dom.rootNode)
        #expect(root.nodeName == "#document")
        #expect(context.dom.node(for: root.id) === root)
        requirePersistentModel(root)

        let treeController = context.dom.treeController()
        let treeSnapshot: DOMTreeSnapshot = treeController.snapshot
        #expect(treeSnapshot.rootNodeID == root.id)
        #expect(treeSnapshot.node(for: root.id)?.nodeName == "#document")
        _ = treeController.revision
        _ = treeController.selectedNodeID
        _ = treeController.updates
        _ = treeController.revealRequests

        context.dom.select(root)
        #expect(context.dom.selectedNode === root)
        context.dom.select(nil)
        context.runtime.select(nil)
        context.network.clearRequests()
        #expect(context.dom.selectedNode == nil)
        #expect(context.runtime.selectedContext == nil)
    }

    func assertFakeBackendDrivesDOMNetworkAndRuntimeContracts() async throws {
        let context = modelContext()
        let document = WebInspectorProxyTestFixtures.domDocument(
            id: "contract-document",
            documentURL: "https://example.com/",
            childNodeCount: 1
        )
        let target = try await start(document: document)
        let treeController = context.dom.treeController()
        var treeUpdates = treeController.updates.makeAsyncIterator()
        _ = try #require(await treeUpdates.next())

        await runtime.backend.emit(
            .setChildNodes(parent: WebInspectorProxyTestFixtures.domNodeID("contract-document"), nodes: [
                WebInspectorProxyTestFixtures.domNode(
                    id: "contract-element",
                    nodeType: 1,
                    nodeName: "MAIN",
                    localName: "main",
                    attributes: ["data-second": "2", "data-contract": "dom"],
                    attributeList: [
                        DOM.Attribute(name: "data-contract", value: "dom"),
                        DOM.Attribute(name: "data-second", value: "2"),
                    ]
                ),
            ]),
            target: target
        )

        _ = try #require(await treeUpdates.next())
        let root = try #require(context.dom.rootNode)
        guard case let .loaded(children) = root.children else {
            Issue.record("Expected the seeded document to load children.")
            return
        }
        let child = try #require(children.first)
        #expect(context.dom.node(for: child.id) === child)
        #expect(child.attributeList.map(\.name) == ["data-contract", "data-second"])

        #expect(treeController.snapshot.selectorPath(for: child.id) == "main")
        #expect(try context.dom.selectorPath(for: child) == "main")
        #expect(try context.dom.xPath(for: child) == "/main")

        await runtime.backend.enqueue("<main data-contract=\"dom\"></main>", for: "DOM", method: "getOuterHTML")
        #expect(try await context.dom.copyText(.html, of: child) == "<main data-contract=\"dom\"></main>")
        #expect(try await context.dom.copyText(.selectorPath, of: child) == "main")

        await runtime.backend.enqueue((), for: "DOM", method: "highlightNode")
        try await context.dom.highlight(child)
        await runtime.backend.enqueue((), for: "DOM", method: "hideHighlight")
        try await context.dom.hideHighlight()
        await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")
        try await context.dom.setElementPickerEnabled(true)
        #expect(context.dom.isElementPickerEnabled)
        await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")
        try await context.dom.setElementPickerEnabled(false)
        #expect(context.dom.isElementPickerEnabled == false)
        await runtime.backend.enqueue((), for: "DOM", method: "removeNode")
        await runtime.backend.enqueue((), for: "DOM", method: "markUndoableState")
        try await context.dom.remove([child])
        await runtime.backend.enqueue((), for: "Page", method: "reload")
        try await context.page.reload()

        let domCommands = await runtime.backend.recordedCommands()
        #expect(domCommands.contains(RecordedCommand(domain: "DOM", method: "getOuterHTML")))
        #expect(domCommands.contains(RecordedCommand(domain: "DOM", method: "highlightNode")))
        #expect(domCommands.contains(RecordedCommand(domain: "DOM", method: "hideHighlight")))
        #expect(domCommands.contains(RecordedCommand(domain: "DOM", method: "setInspectModeEnabled")))
        #expect(domCommands.contains(RecordedCommand(domain: "DOM", method: "removeNode")))
        #expect(domCommands.contains(RecordedCommand(domain: "DOM", method: "markUndoableState")))
        #expect(domCommands.contains(RecordedCommand(domain: "Page", method: "reload")))

        let request = WebInspectorProxyTestFixtures.networkRequest(
            id: "contract-request",
            url: "https://example.com/data.json",
            headers: ["Accept": "application/json"]
        )
        var requestChanges = context.network.requestChanges.makeAsyncIterator()
        await ContractTestSupport.emitFinishedRequest(request, target: target, backend: runtime.backend)

        while context.network.requests.first?.state != .finished {
            guard await requestChanges.next() != nil else {
                throw ContractEventStreamEnded()
            }
        }
        let requestModel = try #require(context.network.requests.first)
        #expect(requestModel.url == "https://example.com/data.json")
        #expect(requestModel.method == "GET")
        #expect(requestModel.status == 200)
        #expect(requestModel.statusText == "OK")
        #expect(requestModel.responseURL == "https://example.com/data.json")
        #expect(requestModel.responseSource == "network")
        #expect(requestModel.hasResponse)
        #expect(requestModel.hasResponseBody)
        #expect(requestModel.responseHeaders["Content-Type"] == "application/json")
        #expect(requestModel.decodedDataLength == 7)
        #expect(requestModel.encodedDataLength == 4)
        #expect(requestModel.sourceMapURL == "data.json.map")
        #expect(requestModel.metrics?.networkProtocol == "h2")
        #expect(requestModel.metrics?.remoteAddress == "203.0.113.30:443")
        #expect(requestModel.metrics?.encodedDataLength == 4)
        #expect(requestModel.metrics?.decodedBodyLength == 7)
        #expect(context.network.request(for: requestModel.id) === requestModel)
        #expect(context.network.requests.map(\.id) == [requestModel.id])

        await runtime.backend.enqueue(
            Network.Body(data: "{\"ok\":true}", base64Encoded: false),
            for: "Network",
            method: "getResponseBody"
        )
        await context.network.fetchResponseBody(for: requestModel)
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

        let evaluation = try await context.runtime.evaluate("document.title")
        #expect(evaluation.isException == false)
        #expect(evaluation.object.kind == .string)
        #expect(evaluation.object.value == .string("contract"))
        #expect(evaluation.object.description == "contract")
        #expect(evaluation.object.canRequestProperties)
    }

    private func modelContext() -> WebInspector {
        inspector
    }

    private func requirePersistentModel<Model: WebInspectorPersistentModel>(_ model: Model) {
        #expect(Set([model]).contains(model))
    }

    func close() async {
        await ContractTestSupport.enqueueDataKitShutdownReplies(on: runtime.backend)
        await inspector.detachForTesting()
        #expect(inspector.state == .detached)
    }
}
