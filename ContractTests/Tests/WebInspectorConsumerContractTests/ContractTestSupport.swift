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

    private struct BodySnapshot: Sendable {
        let phase: NetworkBody.Phase
        let text: String?
        let isBase64Encoded: Bool
    }

    private let runtime: WebInspectorProxyTestRuntime
    private let context: WebInspectorModelContext
    private var commands: [WebInspectorTestPeer.Command]

    init(runtime: WebInspectorProxyTestRuntime) {
        self.runtime = runtime
        context = WebInspectorModelContext()
        commands = []
    }

    func start(
        document: WebInspectorTestJSONObject? = nil
    ) async throws {
        let documentResult = try document ?? ContractTestSupport.documentResult()
        let attachTask = Task {
            try await context.attach(to: runtime.proxy, isolation: self)
        }
        var observedMethods: Set<String> = []
        for _ in 0..<5 {
            let command = try await runtime.peer.commands.next()
            commands.append(command)
            try #require(command.destination == .target("page-main"))
            observedMethods.insert(command.method)
            if command.method == "DOM.getDocument" {
                try await runtime.peer.reply(to: command, with: documentResult)
            } else {
                try await runtime.peer.reply(to: command)
            }
        }
        #expect(observedMethods == [
            "CSS.enable",
            "Network.enable",
            "Console.enable",
            "Runtime.enable",
            "DOM.getDocument",
        ])
        try await attachTask.value
        #expect(context.state == .attached)
    }

    func observedCommands() -> [WebInspectorTestPeer.Command] {
        commands
    }

    func assertPublicSurfaceIsUsable() async throws {
        let requests = try await context.networkRequests(matching: NetworkQuery(
            search: "  contract  ",
            resourceCategories: [.xhrFetch],
            methods: ["GET"],
            sort: .requestTimeAscending,
            section: .method,
            offset: 0,
            limit: 10
        ))
        let messages = try await context.consoleMessages(matching: ConsoleQuery(
            levels: [Console.Level(rawValue: "warning")],
            sort: .insertionDescending,
            section: .level,
            offset: 0,
            limit: 10
        ))
        #expect(requests.items.isEmpty)
        #expect(messages.items.isEmpty)
        #expect(requests.snapshot.itemIDs.isEmpty)
        #expect(messages.snapshot.itemIDs.isEmpty)
        _ = requests.updates()
        _ = messages.updates()
        try await requests.update(NetworkQuery(sort: .requestTimeDescending))
        try await messages.update(ConsoleQuery(sort: .insertionAscending))

        let root = try #require(try context.rootDOMNode)
        #expect(root.nodeName == "#document")
        #expect(try context.domNode(id: root.id) === root)
        requirePersistentModel(root)

        let treeController = try context.domTree
        let treeSnapshot: DOMTreeSnapshot = treeController.snapshot
        #expect(treeSnapshot.rootNodeID == root.id)
        #expect(treeSnapshot.node(for: root.id)?.nodeName == "#document")
        _ = treeController.revision
        _ = treeController.selectedNodeID
        _ = treeController.updates
        _ = treeController.revealRequests

        try context.selectDOMNode(root)
        #expect(try context.selectedDOMNode === root)
        try context.selectDOMNode(nil)
        await context.clearNetworkRequests()
        #expect(try context.selectedDOMNode == nil)
        #expect(try context.runtimeContexts.isEmpty)
    }

    func assertRawPeerDrivesDOMNetworkAndRuntimeContracts() async throws {
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
        try await ContractTestSupport.waitUntil(isolation: self) {
            guard let root = try? context.rootDOMNode,
                  case let .loaded(children) = root.children else {
                return false
            }
            return children.first?.attributes["data-contract"] == "dom"
        }
        let root = try #require(try context.rootDOMNode)
        guard case let .loaded(children) = root.children else {
            Issue.record("Expected the seeded document to load children.")
            return
        }
        let child = try #require(children.first)
        #expect(try context.domNode(id: child.id) === child)
        #expect(child.attributeList.map(\.name) == ["data-contract", "data-second"])
        #expect(try context.selectorPath(for: child) == "main")
        #expect(try context.xPath(for: child) == "/main")

        let copyHTMLTask = Task {
            try await context.copyText(.html, for: child)
        }
        var command = try await replyNext(
            expectedMethod: "DOM.getOuterHTML",
            result: ContractTestSupport.outerHTMLResult(
                "<main data-contract=\"dom\"></main>"
            )
        )
        #expect(try await copyHTMLTask.value == "<main data-contract=\"dom\"></main>")

        let highlightTask = Task {
            try await context.highlightDOMNode(child)
        }
        command = try await replyNext(expectedMethod: "DOM.highlightNode")
        try await highlightTask.value

        let hideTask = Task {
            try await context.hideDOMHighlight()
        }
        command = try await replyNext(expectedMethod: "DOM.hideHighlight")
        try await hideTask.value

        let enablePicker = Task {
            try await context.setElementPickerEnabled(true)
        }
        _ = try await replyNext(expectedMethod: "Inspector.enable")
        _ = try await replyNext(expectedMethod: "Inspector.initialized")
        _ = try await replyNext(expectedMethod: "DOM.setInspectModeEnabled")
        try await enablePicker.value
        #expect(try context.isElementPickerEnabled)

        let disablePicker = Task {
            try await context.setElementPickerEnabled(false)
        }
        _ = try await replyNext(expectedMethod: "DOM.setInspectModeEnabled")
        _ = try await replyNext(expectedMethod: "Inspector.disable")
        try await disablePicker.value
        #expect(try context.isElementPickerEnabled == false)

        let deleteTask = Task {
            try await context.removeDOMNodes([child]).appliedNodeIDs
        }
        _ = try await replyNext(expectedMethod: "DOM.removeNode")
        _ = try await replyNext(expectedMethod: "DOM.markUndoableState")
        let deletedNodeIDs = try await deleteTask.value
        #expect(deletedNodeIDs == [child.id])

        let reloadTask = Task {
            try await context.reload()
        }
        _ = try await replyNext(expectedMethod: "Page.reload")
        try await reloadTask.value

        let requestResults = try await context.networkRequests()
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
            method: "Network.loadingFinished",
            parameters: ContractTestSupport.loadingFinishedParameters()
        )
        try await ContractTestSupport.waitUntil(isolation: self) {
            requestResults.items.first?.state == .finished
        }
        let request = try #require(requestResults.items.first)
        #expect(request.url == "https://example.com/data.json")
        #expect(request.status == 200)
        #expect(request.responseHeaders["Content-Type"] == "application/json")
        #expect(request.metrics?.networkProtocol == "h2")

        let bodyTask = Task {
            let body = try await context.responseBody(for: request, isolation: self)
            return BodySnapshot(
                phase: body.phase,
                text: body.text,
                isBase64Encoded: body.isBase64Encoded
            )
        }
        _ = try await replyNext(
            expectedMethod: "Network.getResponseBody",
            result: ContractTestSupport.responseBodyResult(
                "{\"ok\":true}",
                base64Encoded: false
            )
        )
        let body = try await bodyTask.value
        #expect(body.phase == .loaded)
        #expect(body.text == "{\"ok\":true}")
        #expect(body.isBase64Encoded == false)

        let evaluationTask = Task {
            try await context.withRuntimeObjectGroup(named: "contract") { group in
                let evaluation = try await group.evaluate("document.title")
                return EvaluationSnapshot(
                    isException: evaluation.isException,
                    kind: evaluation.object.kind,
                    value: evaluation.object.value,
                    description: evaluation.object.description,
                    canRequestProperties: evaluation.object.canRequestProperties
                )
            }
        }
        _ = try await replyNext(
            expectedMethod: "Runtime.evaluate",
            result: ContractTestSupport.evaluationResult()
        )
        _ = try await replyNext(expectedMethod: "Runtime.releaseObjectGroup")
        let evaluation = try await evaluationTask.value
        #expect(evaluation.isException == false)
        #expect(evaluation.kind == .string)
        #expect(evaluation.value == .string("contract"))
        #expect(evaluation.description == "contract")
        #expect(evaluation.canRequestProperties)

        _ = command
    }

    func close() async throws {
        let closeTask = Task {
            await context.close()
        }
        for expectedMethod in [
            "Runtime.disable",
            "Console.disable",
            "Network.disable",
            "CSS.disable",
        ] {
            _ = try await replyNext(expectedMethod: expectedMethod)
        }
        await closeTask.value
        #expect(context.state == .closed)
    }

    @discardableResult
    private func replyNext(
        expectedMethod: String,
        result: WebInspectorTestJSONObject = .empty
    ) async throws -> WebInspectorTestPeer.Command {
        let command = try await runtime.peer.commands.next()
        commands.append(command)
        try #require(command.destination == .target("page-main"))
        try #require(command.method == expectedMethod)
        try await runtime.peer.reply(to: command, with: result)
        return command
    }

    private func requirePersistentModel<Model: WebInspectorPersistentModel>(
        _ model: Model
    ) {
        #expect(Set([model]).contains(model))
    }
}
