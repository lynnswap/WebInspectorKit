import Foundation
import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

/// A ready-to-use DataKit model runtime backed by ProxyKit's production wire path.
///
/// The runtime is confined to the actor that calls ``start(scenario:isolation:)``.
/// Call ``close()`` and await completion before releasing it.
public final class WebInspectorDataKitTestRuntime {
    /// One DOM node in a test document.
    public struct Node: Equatable, Sendable {
        public let id: String
        public let nodeType: Int
        public let nodeName: String
        public let localName: String
        public let nodeValue: String
        public let attributes: [String: String]
        public let children: [Node]

        public init(
            id: String,
            nodeType: Int = 1,
            nodeName: String,
            localName: String = "",
            nodeValue: String = "",
            attributes: [String: String] = [:],
            children: [Node] = []
        ) {
            self.id = id
            self.nodeType = nodeType
            self.nodeName = nodeName
            self.localName = localName
            self.nodeValue = nodeValue
            self.attributes = attributes
            self.children = children
        }

        /// Creates an element node whose protocol name is the uppercased local name.
        public static func element(
            id: String,
            name: String,
            attributes: [String: String] = [:],
            children: [Node] = []
        ) -> Node {
            Node(
                id: id,
                nodeName: name.uppercased(),
                localName: name,
                attributes: attributes,
                children: children
            )
        }

        /// Creates a text node.
        public static func text(id: String, value: String) -> Node {
            Node(
                id: id,
                nodeType: 3,
                nodeName: "#text",
                nodeValue: value
            )
        }
    }

    /// The initial or replacement DOM document supplied by a scenario.
    public struct Document: Equatable, Sendable {
        public let id: String
        public let frameID: String
        public let url: String?
        public let children: [Node]

        public init(
            id: String = "document",
            frameID: String = "main-frame",
            url: String? = nil,
            children: [Node] = []
        ) {
            self.id = id
            self.frameID = frameID
            self.url = url
            self.children = children
        }
    }

    /// A complete Network request replayed during `Network.enable`.
    public struct NetworkRequest: Sendable {
        public let id: String
        public let url: String
        public let method: String
        public let requestHeaders: [String: String]
        public let postData: String?
        public let status: Int
        public let statusText: String?
        public let responseHeaders: [String: String]
        public let mimeType: String
        public let resourceType: Network.ResourceType
        public let initiatorNodeID: String?
        public let encodedDataLength: Int?
        public let body: Network.Body?

        public init(
            id: String,
            url: String,
            method: String = "GET",
            requestHeaders: [String: String] = [:],
            postData: String? = nil,
            status: Int = 200,
            statusText: String? = nil,
            responseHeaders: [String: String] = [:],
            mimeType: String = "text/plain",
            resourceType: Network.ResourceType = .fetch,
            initiatorNodeID: String? = nil,
            encodedDataLength: Int? = nil,
            body: Network.Body? = nil
        ) {
            self.id = id
            self.url = url
            self.method = method
            self.requestHeaders = requestHeaders
            self.postData = postData
            self.status = status
            self.statusText = statusText
            self.responseHeaders = responseHeaders
            self.mimeType = mimeType
            self.resourceType = resourceType
            self.initiatorNodeID = initiatorNodeID
            self.encodedDataLength = encodedDataLength
            self.body = body
        }
    }

    /// The model bootstrap domain that should fail.
    public enum AttachFailureDomain: Sendable {
        case dom
        case network
        case console
        case runtime
        case css
    }

    /// A deterministic model attachment failure.
    public struct AttachFailure: Sendable {
        public let domain: AttachFailureDomain
        public let message: String

        public init(domain: AttachFailureDomain, message: String) {
            self.domain = domain
            self.message = message
        }
    }

    /// Inputs applied before the model reaches its first ready state.
    public struct Scenario: Sendable {
        public let configuration: WebInspectorModelContainer.Configuration
        public let document: Document
        public let networkReplay: [NetworkRequest]
        public let attachFailure: AttachFailure?

        public init(
            configuration: WebInspectorModelContainer.Configuration = .init(),
            document: Document = .init(),
            networkReplay: [NetworkRequest] = [],
            attachFailure: AttachFailure? = nil
        ) {
            precondition(
                Set(networkReplay.map(\.id)).count == networkReplay.count,
                "A DataKit test scenario cannot replay duplicate Network request identifiers."
            )
            self.configuration = configuration
            self.document = document
            self.networkReplay = networkReplay
            self.attachFailure = attachFailure
        }
    }

    public enum RuntimeError: Error, Equatable, Sendable {
        case closed
    }

    private enum ReplacementObservation {
        case dom(
            WebInspectorFetchedResultsController<
                WebInspectorDataKit.DOMNode,
                Never
            >,
            baselineRevision: UInt64,
            oldIDs: Set<WebInspectorDataKit.DOMNode.ID>,
            expectedCount: Int
        )
        case network(
            WebInspectorFetchedResultsController<
                WebInspectorDataKit.NetworkRequest,
                Never
            >,
            baselineRevision: UInt64,
            oldIDs: Set<WebInspectorDataKit.NetworkRequest.ID>,
            expectedCount: Int
        )
        func validate(
            isolation: isolated (any Actor)
        ) {
            _ = isolation
            switch self {
            case let .dom(results, baselineRevision, oldIDs, expectedCount):
                WebInspectorDataKitTestRuntime.validateReplacement(
                    results,
                    baselineRevision: baselineRevision,
                    oldIDs: oldIDs,
                    expectedCount: expectedCount
                )
            case let .network(results, baselineRevision, oldIDs, expectedCount):
                WebInspectorDataKitTestRuntime.validateReplacement(
                    results,
                    baselineRevision: baselineRevision,
                    oldIDs: oldIDs,
                    expectedCount: expectedCount
                )
            }
        }

        func close(
            isolation: isolated (any Actor)
        ) async {
            _ = isolation
            switch self {
            case let .dom(results, _, _, _):
                await results.close()
            case let .network(results, _, _, _):
                await results.close()
            }
        }
    }

    /// The model container that owns the production feed and every context.
    public let container: WebInspectorModelContainer

    /// The ready, actor-confined context vended by ``container``.
    public let model: WebInspectorModelContext

    private let proxyRuntime: WebInspectorProxyTestRuntime
    private let driver: ScenarioDriver
    private let driverTask: Task<Void, Never>
    private var isClosed: Bool

    /// Starts the production ProxyKit path and returns after DataKit is ready.
    public static func start(
        scenario: Scenario = .init(),
        isolation: isolated (any Actor) = #isolation
    ) async throws -> WebInspectorDataKitTestRuntime {
        let proxyRuntime = try await WebInspectorProxyTestRuntime.start()
        let driver = ScenarioDriver(
            peer: proxyRuntime.peer,
            document: scenario.document,
            networkReplay: scenario.networkReplay,
            attachFailure: scenario.attachFailure
        )
        let driverTask = ScenarioDriver.makeConsumerTask(
            commands: proxyRuntime.peer.commands,
            driver: driver
        )
        let container = WebInspectorModelContainer(
            configuration: scenario.configuration
        )

        do {
            let model = try await container.makeContext(isolation: isolation)
            try await container.attach(owning: proxyRuntime.proxy)
            return WebInspectorDataKitTestRuntime(
                container: container,
                model: model,
                proxyRuntime: proxyRuntime,
                driver: driver,
                driverTask: driverTask
            )
        } catch {
            await container.close()
            await proxyRuntime.close()
            driverTask.cancel()
            await driverTask.value
            throw error
        }
    }

    /// Emits a complete Network request on the current page.
    public nonisolated(nonsending) func emitNetworkRequest(
        _ request: NetworkRequest
    ) async throws {
        guard !isClosed else {
            throw RuntimeError.closed
        }
        try await driver.emitNetworkRequest(request)
    }

    /// Commits a provisional page target and waits for the replacement model.
    public func replacePage(
        with document: Document,
        networkReplay: [NetworkRequest] = [],
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        guard !isClosed else {
            throw RuntimeError.closed
        }
        precondition(
            Set(networkReplay.map(\.id)).count == networkReplay.count,
            "A DataKit test scenario cannot replay duplicate Network request identifiers."
        )
        let synchronizationCheckpoint = try await container
            .synchronizationCheckpoint()
        let observations = try await makeReplacementObservations(
            document: document,
            networkReplay: networkReplay,
            isolation: isolation
        )
        let replacement = await driver.prepareReplacement(
            document: document,
            networkReplay: networkReplay
        )

        do {
            try await proxyRuntime.peer.createTarget(.init(
                id: replacement.newTargetID,
                type: "page",
                frameID: document.frameID,
                isProvisional: true
            ))
            try await proxyRuntime.peer.commitProvisionalTarget(
                from: replacement.oldTargetID,
                to: replacement.newTargetID
            )
        } catch {
            await driver.rollbackReplacement(replacement)
            await Self.close(observations, isolation: isolation)
            throw error
        }

        do {
            _ = try await container.waitForSynchronization(
                after: synchronizationCheckpoint
            )
            for observation in observations {
                observation.validate(isolation: isolation)
            }
        } catch {
            await Self.close(observations, isolation: isolation)
            throw error
        }
        await Self.close(observations, isolation: isolation)
    }

    /// Closes the model, connection, and command consumer in ownership order.
    public nonisolated(nonsending) func close() async {
        guard !isClosed else {
            return
        }
        isClosed = true
        await container.close()
        await proxyRuntime.close()
        driverTask.cancel()
        await driverTask.value
    }

    private init(
        container: WebInspectorModelContainer,
        model: WebInspectorModelContext,
        proxyRuntime: WebInspectorProxyTestRuntime,
        driver: ScenarioDriver,
        driverTask: Task<Void, Never>
    ) {
        self.container = container
        self.model = model
        self.proxyRuntime = proxyRuntime
        self.driver = driver
        self.driverTask = driverTask
        isClosed = false
    }

    private func makeReplacementObservations(
        document: Document,
        networkReplay: [NetworkRequest],
        isolation: isolated (any Actor)
    ) async throws -> [ReplacementObservation] {
        let domains = container.configuration.domains
        var observations: [ReplacementObservation] = []
        do {
            if domains.contains(.dom) {
                let results = try await WebInspectorFetchedResultsController<
                    WebInspectorDataKit.DOMNode,
                    Never
                >(modelContext: model, isolation: isolation)
                observations.append(.dom(
                    results,
                    baselineRevision: results.revision,
                    oldIDs: Set(results.snapshot.itemIDs),
                    expectedCount: document.modelNodeCount
                ))
            }
            if domains.contains(.network) {
                let results = try await WebInspectorFetchedResultsController<
                    WebInspectorDataKit.NetworkRequest,
                    Never
                >(modelContext: model, isolation: isolation)
                observations.append(.network(
                    results,
                    baselineRevision: results.revision,
                    oldIDs: Set(results.snapshot.itemIDs),
                    expectedCount: networkReplay.count
                ))
            }
            return observations
        } catch {
            await Self.close(observations, isolation: isolation)
            throw error
        }
    }

    private static func close(
        _ observations: [ReplacementObservation],
        isolation: isolated (any Actor)
    ) async {
        for observation in observations {
            await observation.close(isolation: isolation)
        }
    }

    private static func validateReplacement<
        Model: WebInspectorPersistentModel
    >(
        _ results: WebInspectorFetchedResultsController<Model, Never>,
        baselineRevision: UInt64,
        oldIDs: Set<Model.ID>,
        expectedCount: Int
    ) {
        let ids = results.snapshot.itemIDs
        precondition(
            results.revision >= baselineRevision
                && ids.count == expectedCount
                && Set(ids).isDisjoint(with: oldIDs),
            "A synchronized DataKit test replacement published unexpected model membership."
        )
    }

    deinit {
        driverTask.cancel()
    }
}

private actor ScenarioDriver {
    struct Replacement: Sendable {
        let oldTargetID: String
        let newTargetID: String
        let oldDocument: WebInspectorDataKitTestRuntime.Document
        let oldNetworkReplay: [WebInspectorDataKitTestRuntime.NetworkRequest]
    }

    private let peer: WebInspectorTestPeer
    private var currentTargetID: String
    private var document: WebInspectorDataKitTestRuntime.Document
    private var networkReplay: [WebInspectorDataKitTestRuntime.NetworkRequest]
    private var responseBodies: [String: Network.Body]
    private var attachFailure: WebInspectorDataKitTestRuntime.AttachFailure?
    private var replacementOrdinal: UInt64

    init(
        peer: WebInspectorTestPeer,
        document: WebInspectorDataKitTestRuntime.Document,
        networkReplay: [WebInspectorDataKitTestRuntime.NetworkRequest],
        attachFailure: WebInspectorDataKitTestRuntime.AttachFailure?
    ) {
        self.peer = peer
        currentTargetID = "page-main"
        self.document = document
        self.networkReplay = networkReplay
        responseBodies = Dictionary(
            uniqueKeysWithValues: networkReplay.compactMap { request in
                request.body.map { (request.id, $0) }
            }
        )
        self.attachFailure = attachFailure
        replacementOrdinal = 0
    }

    nonisolated static func makeConsumerTask(
        commands: WebInspectorTestPeer.Commands,
        driver: ScenarioDriver
    ) -> Task<Void, Never> {
        Task.detached {
            while !Task.isCancelled {
                do {
                    let command = try await commands.next()
                    try await driver.respond(to: command)
                } catch is CancellationError {
                    return
                } catch WebInspectorTestPeerError.connectionClosed {
                    return
                } catch WebInspectorTestPeerError.staleCommand {
                    return
                } catch {
                    await driver.terminateAfterUnexpectedFailure(error)
                    return
                }
            }
        }
    }

    func emitNetworkRequest(
        _ request: WebInspectorDataKitTestRuntime.NetworkRequest
    ) async throws {
        responseBodies[request.id] = request.body
        try await emitNetworkRequest(
            request,
            targetID: currentTargetID,
            frameID: document.frameID
        )
    }

    func prepareReplacement(
        document: WebInspectorDataKitTestRuntime.Document,
        networkReplay: [WebInspectorDataKitTestRuntime.NetworkRequest]
    ) -> Replacement {
        replacementOrdinal &+= 1
        precondition(replacementOrdinal != 0, "DataKit test target ordinal exhausted.")
        let replacement = Replacement(
            oldTargetID: currentTargetID,
            newTargetID: "page-replacement-\(replacementOrdinal)",
            oldDocument: self.document,
            oldNetworkReplay: self.networkReplay
        )
        currentTargetID = replacement.newTargetID
        self.document = document
        self.networkReplay = networkReplay
        responseBodies = Dictionary(
            uniqueKeysWithValues: networkReplay.compactMap { request in
                request.body.map { (request.id, $0) }
            }
        )
        return replacement
    }

    func rollbackReplacement(_ replacement: Replacement) {
        guard currentTargetID == replacement.newTargetID else {
            return
        }
        currentTargetID = replacement.oldTargetID
        document = replacement.oldDocument
        networkReplay = replacement.oldNetworkReplay
        responseBodies = Dictionary(
            uniqueKeysWithValues: replacement.oldNetworkReplay.compactMap { request in
                request.body.map { (request.id, $0) }
            }
        )
    }

    private func respond(to command: WebInspectorTestPeer.Command) async throws {
        if let failure = matchingAttachFailure(for: command.method) {
            attachFailure = nil
            try await peer.fail(command, message: failure.message)
            return
        }

        switch command.method {
        case "Page.enable", "CSS.enable", "Console.enable", "Runtime.enable",
             "Page.disable", "CSS.disable", "Console.disable", "Runtime.disable", "Network.disable",
             "Inspector.enable", "Inspector.initialized", "Inspector.disable",
             "DOM.setInspectModeEnabled", "DOM.hideHighlight",
             "Runtime.releaseObjectGroup":
            try await peer.reply(to: command)
        case "Network.enable":
            guard case let .target(targetID) = command.destination else {
                try await peer.fail(command, message: "Network.enable must target a page.")
                return
            }
            for request in networkReplay {
                try await emitNetworkRequest(
                    request,
                    targetID: targetID,
                    frameID: document.frameID
                )
            }
            try await peer.reply(to: command)
        case "DOM.getDocument":
            try await peer.reply(
                to: command,
                with: try WebInspectorTestJSONObject(encoding:
                    DOMDocumentResult(root: DOMNodeWire(document: document))
                )
            )
        case "Network.getResponseBody":
            let parameters = try command.parameters.decode(ResponseBodyParameters.self)
            guard let body = responseBodies[parameters.requestId] else {
                try await peer.fail(
                    command,
                    message: "No DataKit test response body for \(parameters.requestId)."
                )
                return
            }
            try await peer.reply(
                to: command,
                with: try WebInspectorTestJSONObject(encoding:
                    ResponseBodyResult(body: body.data, base64Encoded: body.base64Encoded)
                )
            )
        default:
            try await peer.fail(
                command,
                message: "Unsupported DataKit test scenario command: \(command.method)."
            )
        }
    }

    private func matchingAttachFailure(
        for method: String
    ) -> WebInspectorDataKitTestRuntime.AttachFailure? {
        guard let attachFailure else {
            return nil
        }
        let expectedMethod: String
        switch attachFailure.domain {
        case .dom: expectedMethod = "DOM.getDocument"
        case .network: expectedMethod = "Network.enable"
        case .console: expectedMethod = "Console.enable"
        case .runtime: expectedMethod = "Runtime.enable"
        case .css: expectedMethod = "CSS.enable"
        }
        return method == expectedMethod ? attachFailure : nil
    }

    private func emitNetworkRequest(
        _ request: WebInspectorDataKitTestRuntime.NetworkRequest,
        targetID: String,
        frameID: String
    ) async throws {
        try await peer.emitTargetEvent(
            targetID: targetID,
            method: "Network.requestWillBeSent",
            parameters: try WebInspectorTestJSONObject(encoding:
                RequestWillBeSentParameters(
                    requestId: request.id,
                    frameId: frameID,
                    loaderId: "\(frameID)-loader",
                    request: .init(
                        url: request.url,
                        method: request.method,
                        headers: request.requestHeaders,
                        postData: request.postData
                    ),
                    initiator: .init(
                        type: "other",
                        nodeId: request.initiatorNodeID
                    ),
                    timestamp: 1,
                    type: request.resourceType.rawValue
                )
            )
        )
        try await peer.emitTargetEvent(
            targetID: targetID,
            method: "Network.responseReceived",
            parameters: try WebInspectorTestJSONObject(encoding:
                ResponseReceivedParameters(
                    requestId: request.id,
                    response: .init(
                        url: request.url,
                        status: request.status,
                        statusText: request.statusText,
                        mimeType: request.mimeType,
                        headers: request.responseHeaders
                    ),
                    timestamp: 2,
                    type: request.resourceType.rawValue
                )
            )
        )
        try await peer.emitTargetEvent(
            targetID: targetID,
            method: "Network.loadingFinished",
            parameters: try WebInspectorTestJSONObject(encoding:
                LoadingFinishedParameters(
                    requestId: request.id,
                    timestamp: 3,
                    metrics: request.encodedDataLength.map {
                        LoadingFinishedParameters.Metrics(
                            responseBodyBytesReceived: $0
                        )
                    }
                )
            )
        )
    }

    private func terminateAfterUnexpectedFailure(_ error: any Error) async {
        await peer.failConnection(
            with: "DataKit test scenario driver failed: \(error)"
        )
    }
}

private struct DOMDocumentResult: Encodable {
    let root: DOMNodeWire
}

private struct DOMNodeWire: Encodable {
    let nodeId: String
    let nodeType: Int
    let nodeName: String
    let localName: String
    let nodeValue: String
    let frameId: String?
    let documentURL: String?
    let attributes: [String]
    let childNodeCount: Int
    let children: [DOMNodeWire]

    init(document: WebInspectorDataKitTestRuntime.Document) {
        nodeId = document.id
        nodeType = 9
        nodeName = "#document"
        localName = ""
        nodeValue = ""
        frameId = document.frameID
        documentURL = document.url
        attributes = []
        childNodeCount = document.children.count
        children = document.children.map(DOMNodeWire.init(node:))
    }

    init(node: WebInspectorDataKitTestRuntime.Node) {
        nodeId = node.id
        nodeType = node.nodeType
        nodeName = node.nodeName
        localName = node.localName
        nodeValue = node.nodeValue
        frameId = nil
        documentURL = nil
        attributes = node.attributes.sorted { $0.key < $1.key }.flatMap { [$0.key, $0.value] }
        childNodeCount = node.children.count
        children = node.children.map(DOMNodeWire.init(node:))
    }
}

private struct RequestWillBeSentParameters: Encodable {
    struct Request: Encodable {
        let url: String
        let method: String
        let headers: [String: String]
        let postData: String?
    }

    struct Initiator: Encodable {
        let type: String
        let nodeId: String?
    }

    let requestId: String
    let frameId: String
    let loaderId: String
    let request: Request
    let initiator: Initiator
    let timestamp: Double
    let type: String
}

private struct ResponseReceivedParameters: Encodable {
    struct Response: Encodable {
        let url: String
        let status: Int
        let statusText: String?
        let mimeType: String
        let headers: [String: String]
    }

    let requestId: String
    let response: Response
    let timestamp: Double
    let type: String
}

private struct LoadingFinishedParameters: Encodable {
    struct Metrics: Encodable {
        let responseBodyBytesReceived: Int
    }

    let requestId: String
    let timestamp: Double
    let metrics: Metrics?
}

private struct ResponseBodyParameters: Decodable {
    let requestId: String
}

private struct ResponseBodyResult: Encodable {
    let body: String
    let base64Encoded: Bool
}

private extension WebInspectorDataKitTestRuntime.Document {
    var modelNodeCount: Int {
        1 + children.reduce(into: 0) { count, node in
            count += node.modelNodeCount
        }
    }
}

private extension WebInspectorDataKitTestRuntime.Node {
    var modelNodeCount: Int {
        1 + children.reduce(into: 0) { count, node in
            count += node.modelNodeCount
        }
    }
}
