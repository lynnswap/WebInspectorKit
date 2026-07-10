import Foundation
import Testing
import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

enum ContractTestSupport {
    static func documentResult(
        id: String = "document",
        documentURL: String? = nil,
        childNodeCount: Int = 0
    ) throws -> WebInspectorTestJSONObject {
        var root: [String: Any] = [
            "nodeId": id,
            "nodeType": 9,
            "nodeName": "#document",
            "localName": "",
            "nodeValue": "",
            "frameId": "main-frame",
            "childNodeCount": childNodeCount,
        ]
        root["documentURL"] = documentURL
        return try jsonObject(["root": root])
    }

    static func setChildNodesParameters() throws -> WebInspectorTestJSONObject {
        try jsonObject([
            "parentId": "contract-document",
            "nodes": [[
                "nodeId": "contract-element",
                "nodeType": 1,
                "nodeName": "MAIN",
                "localName": "main",
                "nodeValue": "",
                "attributes": [
                    "data-contract", "dom",
                    "data-second", "2",
                ],
                "childNodeCount": 0,
            ]],
        ])
    }

    static func requestWillBeSentParameters() throws -> WebInspectorTestJSONObject {
        try jsonObject([
            "requestId": "contract-request",
            "request": [
                "url": "https://example.com/data.json",
                "method": "GET",
                "headers": ["Accept": "application/json"],
            ],
            "type": "Fetch",
            "timestamp": 1,
        ])
    }

    static func responseReceivedParameters() throws -> WebInspectorTestJSONObject {
        try jsonObject([
            "requestId": "contract-request",
            "response": [
                "url": "https://example.com/data.json",
                "status": 200,
                "statusText": "OK",
                "mimeType": "application/json",
                "headers": ["Content-Type": "application/json"],
                "source": "network",
            ],
            "type": "Fetch",
            "timestamp": 2,
        ])
    }

    static func dataReceivedParameters() throws -> WebInspectorTestJSONObject {
        try jsonObject([
            "requestId": "contract-request",
            "dataLength": 7,
            "encodedDataLength": 4,
            "timestamp": 3,
        ])
    }

    static func loadingFinishedParameters() throws -> WebInspectorTestJSONObject {
        try jsonObject([
            "requestId": "contract-request",
            "timestamp": 4,
            "sourceMapURL": "data.json.map",
            "metrics": [
                "protocol": "h2",
                "remoteAddress": "203.0.113.30:443",
                "responseBodyBytesReceived": 4,
                "responseBodyDecodedSize": 7,
            ],
        ])
    }

    static func consoleMessageParameters(text: String) throws -> WebInspectorTestJSONObject {
        try jsonObject([
            "message": [
                "source": "javascript",
                "level": "log",
                "text": text,
            ],
        ])
    }

    static func outerHTMLResult(_ html: String) throws -> WebInspectorTestJSONObject {
        try jsonObject(["outerHTML": html])
    }

    static func responseBodyResult(
        _ body: String,
        base64Encoded: Bool
    ) throws -> WebInspectorTestJSONObject {
        try jsonObject([
            "body": body,
            "base64Encoded": base64Encoded,
        ])
    }

    static func evaluationResult() throws -> WebInspectorTestJSONObject {
        try jsonObject([
            "result": [
                "objectId": "contract-evaluation",
                "type": "string",
                "description": "contract",
                "value": "contract",
            ],
        ])
    }

    static func jsonObject(_ object: [String: Any]) throws -> WebInspectorTestJSONObject {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return try WebInspectorTestJSONObject(data: data)
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
}

struct TimedOut: Error {}

actor ContractDataKitActor {
    private struct EvaluationSnapshot: Sendable {
        let isException: Bool
        let kind: Runtime.Kind
        let value: Runtime.JSONValue?
        let description: String?
        let canRequestProperties: Bool
    }

    nonisolated let inspectorContainer: WebInspectorContainer

    private let runtime: WebInspectorProxyTestRuntime
    private var context: WebInspectorContext?
    private var commands: [WebInspectorTestPeer.Command]

    init(runtime: WebInspectorProxyTestRuntime, inspectorContainer: WebInspectorContainer? = nil) {
        self.runtime = runtime
        let container = inspectorContainer ?? WebInspectorContainer(proxy: runtime.proxy)
        self.inspectorContainer = container
        context = nil
        commands = []
    }

    @discardableResult
    func start(
        document: WebInspectorTestJSONObject? = nil,
        sharesDomainLeases: Bool = false
    ) async throws -> WebInspectorTarget {
        let documentResult: WebInspectorTestJSONObject
        if let document {
            documentResult = document
        } else {
            documentResult = try ContractTestSupport.documentResult()
        }

        let context = modelContext()
        let target = try await runtime.proxy.waitForCurrentPage()
        context.start()

        if sharesDomainLeases == false {
            var command = try await runtime.peer.commands.next()
            commands.append(command)
            try #require(command.destination == .target("page-main"))
            try #require(command.method == "Inspector.enable")
            try await runtime.peer.reply(to: command)

            command = try await runtime.peer.commands.next()
            commands.append(command)
            try #require(command.destination == .target("page-main"))
            try #require(command.method == "Inspector.initialized")
            try await runtime.peer.reply(to: command)

            command = try await runtime.peer.commands.next()
            commands.append(command)
            try #require(command.destination == .target("page-main"))
            try #require(command.method == "Runtime.enable")
            try await runtime.peer.reply(to: command)

            command = try await runtime.peer.commands.next()
            commands.append(command)
            try #require(command.destination == .target("page-main"))
            try #require(command.method == "Network.enable")
            try await runtime.peer.reply(to: command)
        }

        var command = try await runtime.peer.commands.next()
        commands.append(command)
        try #require(command.destination == .target("page-main"))
        try #require(command.method == "DOM.getDocument")
        try await runtime.peer.reply(to: command, with: documentResult)

        if sharesDomainLeases == false {
            command = try await runtime.peer.commands.next()
            commands.append(command)
            try #require(command.destination == .target("page-main"))
            try #require(command.method == "Console.enable")
            try await runtime.peer.reply(to: command)
        }

        try await ContractTestSupport.waitUntil { context.state == .attached }
        return target
    }

    func observedCommands() -> [WebInspectorTestPeer.Command] {
        commands
    }

    func assertPublicSurfaceIsUsable() async throws {
        let context = modelContext()
        let requestResults: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        let consoleResults: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()
        let sectionedRequests: WebInspectorFetchedResults<NetworkRequest> =
            context.fetchedResults(sectionBy: \.method)
        let sectionedConsole: WebInspectorFetchedResults<ConsoleMessage> =
            context.fetchedResults(sectionBy: \.level)
        let concreteRequests = try await context.networkRequests(matching: NetworkQuery(
            search: "  contract  ",
            resourceCategories: [.xhrFetch],
            methods: ["GET"],
            sort: .requestTimeAscending,
            section: .method,
            offset: 0,
            limit: 10
        ))
        let concreteConsole = try await context.consoleMessages(matching: ConsoleQuery(
            levels: [Console.Level(rawValue: "warning")],
            sort: .insertionDescending,
            section: .level,
            offset: 0,
            limit: 10
        ))
        #expect(requestResults.items.isEmpty)
        #expect(consoleResults.items.isEmpty)
        #expect(sectionedRequests.sections.isEmpty)
        #expect(sectionedConsole.sections.isEmpty)
        #expect(concreteRequests.items.isEmpty)
        #expect(concreteConsole.items.isEmpty)
        #expect(requestResults.snapshot.itemIDs.isEmpty)
        #expect(consoleResults.snapshot.itemIDs.isEmpty)
        _ = requestResults.updates()
        _ = consoleResults.updates()
        try await concreteRequests.update(NetworkQuery(sort: .requestTimeDescending))
        try await concreteConsole.update(ConsoleQuery(sort: .insertionAscending))
        #expect(context.state == .attached)

        let root = try #require(context.rootNode)
        #expect(root.nodeName == "#document")
        #expect(context.node(for: root.id) === root)
        requirePersistentModel(root)

        let treeController = try await context.treeController()
        let treeSnapshot: DOMTreeSnapshot = treeController.snapshot
        #expect(treeSnapshot.rootNodeID == root.id)
        #expect(treeSnapshot.node(for: root.id)?.nodeName == "#document")
        _ = treeController.revision
        _ = treeController.selectedNodeID
        _ = treeController.updates
        _ = treeController.revealRequests

        context.select(root)
        #expect(context.selectedNode === root)
        context.select(nil)
        context.selectContext(nil)
        await context.clearNetworkRequests()
        #expect(context.selectedNode == nil)
        #expect(context.selectedContext == nil)
    }

    func assertRawPeerDrivesDOMNetworkAndRuntimeContracts() async throws {
        let context = modelContext()
        try await start(document: ContractTestSupport.documentResult(
            id: "contract-document",
            documentURL: "https://example.com/",
            childNodeCount: 1
        ))

        try await runtime.peer.emitTargetEvent(
            targetID: "page-main",
            method: "DOM.setChildNodes",
            parameters: ContractTestSupport.setChildNodesParameters()
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
        #expect(child.attributeList.map(\.name) == ["data-contract", "data-second"])

        let treeController = try await context.treeController()
        #expect(treeController.snapshot.selectorPath(for: child.id) == "main")
        #expect(try context.selectorPath(for: child) == "main")
        #expect(try context.xPath(for: child) == "/main")

        let copyHTMLTask = Task {
            try await child.copyText(.html, isolation: self)
        }
        var command = try await runtime.peer.commands.next()
        commands.append(command)
        try #require(command.destination == .target("page-main"))
        try #require(command.method == "DOM.getOuterHTML")
        try await runtime.peer.reply(
            to: command,
            with: ContractTestSupport.outerHTMLResult("<main data-contract=\"dom\"></main>")
        )
        #expect(try await copyHTMLTask.value == "<main data-contract=\"dom\"></main>")
        #expect(try await child.copyText(.selectorPath) == "main")

        let highlightTask = Task {
            try await child.highlight(isolation: self)
        }
        command = try await runtime.peer.commands.next()
        commands.append(command)
        try #require(command.method == "DOM.highlightNode")
        try await runtime.peer.reply(to: command)
        try await highlightTask.value

        let hideHighlightTask = Task {
            try await context.hideHighlight(isolation: self)
        }
        command = try await runtime.peer.commands.next()
        commands.append(command)
        try #require(command.method == "DOM.hideHighlight")
        try await runtime.peer.reply(to: command)
        try await hideHighlightTask.value

        let enablePickerTask = Task {
            try await context.setElementPickerEnabled(true, isolation: self)
        }
        command = try await runtime.peer.commands.next()
        commands.append(command)
        try #require(command.method == "DOM.setInspectModeEnabled")
        try await runtime.peer.reply(to: command)
        try await enablePickerTask.value
        #expect(context.isElementPickerEnabled)

        let disablePickerTask = Task {
            try await context.setElementPickerEnabled(false, isolation: self)
        }
        command = try await runtime.peer.commands.next()
        commands.append(command)
        try #require(command.method == "DOM.setInspectModeEnabled")
        try await runtime.peer.reply(to: command)
        try await disablePickerTask.value
        #expect(context.isElementPickerEnabled == false)

        let deleteTask = Task {
            try await child.delete(isolation: self)
        }
        command = try await runtime.peer.commands.next()
        commands.append(command)
        try #require(command.method == "DOM.removeNode")
        try await runtime.peer.reply(to: command)
        command = try await runtime.peer.commands.next()
        commands.append(command)
        try #require(command.method == "DOM.markUndoableState")
        try await runtime.peer.reply(to: command)
        try await deleteTask.value

        let reloadTask = Task {
            try await context.reloadPage(isolation: self)
        }
        command = try await runtime.peer.commands.next()
        commands.append(command)
        try #require(command.method == "Page.reload")
        try await runtime.peer.reply(to: command)
        try await reloadTask.value

        #expect(commands.contains { $0.method == "DOM.getOuterHTML" })
        #expect(commands.contains { $0.method == "DOM.highlightNode" })
        #expect(commands.contains { $0.method == "DOM.hideHighlight" })
        #expect(commands.contains { $0.method == "DOM.setInspectModeEnabled" })
        #expect(commands.contains { $0.method == "DOM.removeNode" })
        #expect(commands.contains { $0.method == "DOM.markUndoableState" })
        #expect(commands.contains { $0.method == "Page.reload" })

        let requestResults: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        try await runtime.peer.emitTargetEvent(
            targetID: "page-main",
            method: "Network.requestWillBeSent",
            parameters: ContractTestSupport.requestWillBeSentParameters()
        )
        try await runtime.peer.emitTargetEvent(
            targetID: "page-main",
            method: "Network.responseReceived",
            parameters: ContractTestSupport.responseReceivedParameters()
        )
        try await runtime.peer.emitTargetEvent(
            targetID: "page-main",
            method: "Network.dataReceived",
            parameters: ContractTestSupport.dataReceivedParameters()
        )
        try await runtime.peer.emitTargetEvent(
            targetID: "page-main",
            method: "Network.loadingFinished",
            parameters: ContractTestSupport.loadingFinishedParameters()
        )

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
        #expect(context.registeredRequest(for: requestModel.id) === requestModel)
        #expect(requestResults.snapshot.itemIDs == [requestModel.id])

        let bodyTask = Task {
            await requestModel.fetchResponseBody(isolation: self)
        }
        command = try await runtime.peer.commands.next()
        commands.append(command)
        try #require(command.method == "Network.getResponseBody")
        try await runtime.peer.reply(
            to: command,
            with: ContractTestSupport.responseBodyResult(
                "{\"ok\":true}",
                base64Encoded: false
            )
        )
        await bodyTask.value
        #expect(requestModel.responseBody.phase == .loaded)
        #expect(requestModel.responseBody.text == "{\"ok\":true}")
        #expect(requestModel.responseBody.isBase64Encoded == false)

        let evaluationTask = Task {
            let evaluation = try await context.evaluate(
                "document.title",
                isolation: self
            )
            return EvaluationSnapshot(
                isException: evaluation.isException,
                kind: evaluation.object.kind,
                value: evaluation.object.value,
                description: evaluation.object.description,
                canRequestProperties: evaluation.object.canRequestProperties
            )
        }
        command = try await runtime.peer.commands.next()
        commands.append(command)
        try #require(command.method == "Runtime.evaluate")
        try await runtime.peer.reply(
            to: command,
            with: ContractTestSupport.evaluationResult()
        )

        let evaluation = try await evaluationTask.value
        #expect(evaluation.isException == false)
        #expect(evaluation.kind == .string)
        #expect(evaluation.value == .string("contract"))
        #expect(evaluation.description == "contract")
        #expect(evaluation.canRequestProperties)
    }

    func emitConsoleMessage(text: String) async throws {
        try await runtime.peer.emitTargetEvent(
            targetID: "page-main",
            method: "Console.messageAdded",
            parameters: ContractTestSupport.consoleMessageParameters(text: text)
        )
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

    func stopContext(expectsDomainDisableCommands: Bool = true) async throws {
        guard let context else {
            return
        }
        let stopTask = Task {
            await context.stop(isolation: self)
        }

        if expectsDomainDisableCommands {
            var command = try await runtime.peer.commands.next()
            commands.append(command)
            try #require(command.method == "Console.disable")
            try await runtime.peer.reply(to: command)

            command = try await runtime.peer.commands.next()
            commands.append(command)
            try #require(command.method == "Runtime.disable")
            try await runtime.peer.reply(to: command)

            command = try await runtime.peer.commands.next()
            commands.append(command)
            try #require(command.method == "Network.disable")
            try await runtime.peer.reply(to: command)

            command = try await runtime.peer.commands.next()
            commands.append(command)
            try #require(command.method == "Inspector.disable")
            try await runtime.peer.reply(to: command)
        }

        await stopTask.value
        #expect(context.state == .detached)
        #expect(context.teardownError == nil)
    }

    func close() async throws {
        try await stopContext()
        await inspectorContainer.close()
    }
}
