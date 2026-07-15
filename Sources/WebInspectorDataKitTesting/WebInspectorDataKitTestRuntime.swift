import Foundation
import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

/// A ready-to-use DataKit model runtime backed by ProxyKit's production wire path.
///
/// The runtime owns only the raw scenario driver and resource lifecycle. Obtain
/// model contexts from ``container`` so tests use DataKit's production context
/// ownership. Call ``close()`` and await completion before releasing the runtime.
public actor WebInspectorDataKitTestRuntime {
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
        public let responseRequestHeaders: [String: String]?
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
            responseRequestHeaders: [String: String]? = nil,
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
            self.responseRequestHeaders = responseRequestHeaders
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

    /// The protocol bootstrap domain that should fail.
    public enum AttachFailureDomain: Equatable, Sendable {
        case dom
        case network
        case console
        case runtime
        case css
    }

    /// A deterministic feature bootstrap failure.
    public struct AttachFailure: Equatable, Sendable {
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

    /// Failures from the testing runtime's lifecycle and input boundary.
    public enum RuntimeError: Error, Equatable, Sendable {
        /// The runtime has started or completed resource teardown.
        case closed

        /// Another raw-input operation is suspended on the runtime.
        case inputOperationInProgress

        /// The production connection reached a physical failure or a required
        /// semantic feature could not sustain the connection contract.
        case connectionFailed(WebInspectorConnectionFailure)
    }

    /// The runtime's explicit resource-lifecycle phase.
    public enum LifecycleState: Equatable, Sendable {
        /// The runtime accepts raw input.
        case running

        /// Resource owners are joining their asynchronous close work.
        case closing

        /// All owned resources have completed teardown.
        case closed
    }

    /// Monotonic observations owned by the raw scenario driver.
    public struct CounterSnapshot: Equatable, Sendable {
        /// Raw target/root events accepted by ProxyKit's connection boundary.
        public let acceptedRawInputCount: UInt64

        /// Outbound commands for which the scenario driver completed a reply.
        public let completedCommandCount: UInt64

        /// Provisional target replacements accepted by the raw peer.
        public let pageReplacementCount: UInt64

        fileprivate init(
            acceptedRawInputCount: UInt64,
            completedCommandCount: UInt64,
            pageReplacementCount: UInt64
        ) {
            self.acceptedRawInputCount = acceptedRawInputCount
            self.completedCommandCount = completedCommandCount
            self.pageReplacementCount = pageReplacementCount
        }
    }

    /// One enabled feature's terminal availability at a testing boundary.
    public struct FeatureBoundary: Equatable, Sendable {
        /// The enabled feature represented by this boundary.
        public let featureID: WebInspectorFeatureID

        /// The feature's captured ready or static-unsupported state.
        public let state: WebInspectorFeatureState

        fileprivate init(
            featureID: WebInspectorFeatureID,
            state: WebInspectorFeatureState
        ) {
            self.featureID = featureID
            self.state = state
        }
    }

    /// A testing-only raw-input and feature-owner boundary.
    ///
    /// Every listed feature is ready or statically unsupported when captured.
    /// A replacement advances the generation of each supported feature. Any
    /// unexpected feature failure throws `RuntimeError.connectionFailed`
    /// instead of producing a boundary.
    /// This snapshot does not imply that a consumer's ModelContext or
    /// fetched-results controller has applied that revision.
    public struct BoundarySnapshot: Equatable, Sendable {
        /// Raw-driver counters captured after the feature observations.
        public let counters: CounterSnapshot

        /// Terminal observations ordered by feature name.
        public let features: [FeatureBoundary]

        /// Returns the terminal availability captured for one enabled feature.
        public func featureState(
            for featureID: WebInspectorFeatureID
        ) -> WebInspectorFeatureState? {
            features.first { $0.featureID == featureID }?.state
        }

        fileprivate init(
            counters: CounterSnapshot,
            features: [FeatureBoundary]
        ) {
            self.counters = counters
            self.features = features
        }
    }

    /// The model container that owns production models and every context.
    public nonisolated let container: WebInspectorModelContainer

    /// The runtime's current resource-lifecycle phase.
    public private(set) var lifecycleState: LifecycleState

    private let proxyRuntime: WebInspectorProxyTestRuntime
    private let driver: ScenarioDriver
    private let driverTask: Task<Void, Never>
    private var closeTask: Task<Void, Never>?
    private var isInputOperationActive: Bool

    /// Starts the production path and waits for each enabled feature to reach
    /// ready. Feature or physical connection failure joins teardown and throws
    /// `RuntimeError.connectionFailed`.
    public nonisolated static func start(
        scenario: Scenario = .init()
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

        let runtime = WebInspectorDataKitTestRuntime(
            container: container,
            proxyRuntime: proxyRuntime,
            driver: driver,
            driverTask: driverTask
        )
        do {
            try await container.attach(owning: proxyRuntime.proxy)
            _ = try await runtime.boundarySnapshot()
            return runtime
        } catch {
            await runtime.close()
            throw error
        }
    }

    /// Returns the scenario driver's current immutable counters.
    public func counterSnapshot() async -> CounterSnapshot {
        await driver.counterSnapshot()
    }

    /// Waits until all enabled features reach ready. Feature or physical
    /// connection failure throws `RuntimeError.connectionFailed`.
    ///
    /// This boundary stops at feature owners. A consumer that needs context or
    /// query completion waits on its own fetched-results update sequence.
    public func boundarySnapshot() async throws -> BoundarySnapshot {
        try requireRunning()
        return try await makeBoundarySnapshot(after: nil)
    }

    /// Emits a complete Network request on the current page.
    public func emitNetworkRequest(
        _ request: NetworkRequest
    ) async throws {
        try beginInputOperation()
        defer { endInputOperation() }
        try await driver.emitNetworkRequest(request)
    }

    /// Emits only `Network.requestWillBeSent` for a staged request lifecycle.
    public func emitNetworkRequestWillBeSent(
        _ request: NetworkRequest
    ) async throws {
        try beginInputOperation()
        defer { endInputOperation() }
        try await driver.emitNetworkRequestWillBeSent(request)
    }

    /// Emits only `Network.responseReceived` for a staged request lifecycle.
    public func emitNetworkResponseReceived(
        _ request: NetworkRequest
    ) async throws {
        try beginInputOperation()
        defer { endInputOperation() }
        try await driver.emitNetworkResponseReceived(request)
    }

    /// Emits only `Network.loadingFinished` for a staged request lifecycle.
    public func emitNetworkLoadingFinished(
        _ request: NetworkRequest
    ) async throws {
        try beginInputOperation()
        defer { endInputOperation() }
        try await driver.emitNetworkLoadingFinished(request)
    }

    /// Emits one `DOM.attributeModified` event on the current page target.
    public func emitDOMAttributeModified(
        nodeID: String,
        name: String,
        value: String
    ) async throws {
        try beginInputOperation()
        defer { endInputOperation() }
        try await driver.emitDOMAttributeModified(
            nodeID: nodeID,
            name: name,
            value: value
        )
    }

    /// Emits one `DOM.setChildNodes` event on the current page target.
    public func emitDOMSetChildNodes(
        parentID: String,
        children: [Node]
    ) async throws {
        try beginInputOperation()
        defer { endInputOperation() }
        try await driver.emitDOMSetChildNodes(
            parentID: parentID,
            children: children
        )
    }

    /// Emits one `DOM.childNodeCountUpdated` event on the current page target.
    public func emitDOMChildNodeCountUpdated(
        nodeID: String,
        count: Int
    ) async throws {
        try beginInputOperation()
        defer { endInputOperation() }
        try await driver.emitDOMChildNodeCountUpdated(
            nodeID: nodeID,
            count: count
        )
    }

    /// Emits one `DOM.childNodeInserted` event on the current page target.
    public func emitDOMChildNodeInserted(
        parentID: String,
        previousNodeID: String? = nil,
        node: Node
    ) async throws {
        try beginInputOperation()
        defer { endInputOperation() }
        try await driver.emitDOMChildNodeInserted(
            parentID: parentID,
            previousNodeID: previousNodeID,
            node: node
        )
    }

    /// Emits one `DOM.childNodeRemoved` event on the current page target.
    public func emitDOMChildNodeRemoved(
        parentID: String,
        nodeID: String
    ) async throws {
        try beginInputOperation()
        defer { endInputOperation() }
        try await driver.emitDOMChildNodeRemoved(
            parentID: parentID,
            nodeID: nodeID
        )
    }

    /// Commits a provisional page target and waits for previously-ready feature
    /// owners to reach ready in the replacement generation.
    ///
    /// The returned boundary does not wait for consumer ModelContext or FRC
    /// application. Observe the consumer-owned FRC update when that completion
    /// matters to the test.
    @discardableResult
    public func replacePage(
        with document: Document,
        networkReplay: [NetworkRequest] = []
    ) async throws -> BoundarySnapshot {
        try beginInputOperation()
        defer { endInputOperation() }
        precondition(
            Set(networkReplay.map(\.id)).count == networkReplay.count,
            "A DataKit test scenario cannot replay duplicate Network request identifiers."
        )
        let baseline = try await makeBoundarySnapshot(after: nil)
        try await driver.replacePage(
            document: document,
            networkReplay: networkReplay
        )
        return try await makeBoundarySnapshot(after: baseline)
    }

    /// Closes the container, connection, and command consumer in ownership order.
    /// Concurrent or repeated calls join the same teardown.
    public func close() async {
        let task: Task<Void, Never>
        switch lifecycleState {
        case .running:
            lifecycleState = .closing
            task = Task { [container, proxyRuntime, driverTask] in
                await container.close()
                await proxyRuntime.close()
                driverTask.cancel()
                await driverTask.value
            }
            closeTask = task
        case .closing:
            guard let closeTask else {
                preconditionFailure("A closing DataKit test runtime must own its close task.")
            }
            task = closeTask
        case .closed:
            return
        }

        await task.value
        lifecycleState = .closed
        closeTask = nil
    }

    private init(
        container: WebInspectorModelContainer,
        proxyRuntime: WebInspectorProxyTestRuntime,
        driver: ScenarioDriver,
        driverTask: Task<Void, Never>
    ) {
        self.container = container
        self.proxyRuntime = proxyRuntime
        self.driver = driver
        self.driverTask = driverTask
        lifecycleState = .running
        closeTask = nil
        isInputOperationActive = false
    }

    private func requireRunning() throws {
        guard lifecycleState == .running else {
            throw RuntimeError.closed
        }
    }

    private func beginInputOperation() throws {
        try requireRunning()
        guard !isInputOperationActive else {
            throw RuntimeError.inputOperationInProgress
        }
        isInputOperationActive = true
    }

    private func endInputOperation() {
        isInputOperationActive = false
    }

    private func makeBoundarySnapshot(
        after baseline: BoundarySnapshot?
    ) async throws -> BoundarySnapshot {
        let baselineStates = Dictionary(
            uniqueKeysWithValues: baseline?.features.map {
                ($0.featureID, $0.state)
            } ?? []
        )
        let featureIDs = container.configuration.enabledFeatures.sorted {
            $0.name < $1.name
        }
        let container = container
        let features = try await withThrowingTaskGroup(
            of: FeatureBoundary.self,
            returning: [FeatureBoundary].self
        ) { group in
            for featureID in featureIDs {
                let requiredGeneration = Self.requiredGeneration(
                    after: baselineStates[featureID]
                )
                group.addTask {
                    try await Self.waitForTerminalFeatureState(
                        featureID,
                        in: container,
                        after: requiredGeneration
                    )
                }
            }

            var boundaries: [FeatureBoundary] = []
            for try await boundary in group {
                boundaries.append(boundary)
            }
            return boundaries.sorted { $0.featureID.name < $1.featureID.name }
        }
        return BoundarySnapshot(
            counters: await driver.counterSnapshot(),
            features: features
        )
    }

    private nonisolated static func requiredGeneration(
        after state: WebInspectorFeatureState?
    ) -> WebInspectorPageGeneration? {
        switch state {
        case let .ready(generation, _):
            generation
        case .disabled, .synchronizing, .unsupported, nil:
            nil
        }
    }

    private nonisolated static func waitForTerminalFeatureState(
        _ featureID: WebInspectorFeatureID,
        in container: WebInspectorModelContainer,
        after requiredGeneration: WebInspectorPageGeneration?
    ) async throws -> FeatureBoundary {
        try await withThrowingTaskGroup(of: FeatureBoundary.self) { group in
            group.addTask {
                try await waitForFeatureBoundary(
                    featureID,
                    in: container,
                    after: requiredGeneration
                )
            }
            group.addTask {
                var states = container.stateUpdates.makeAsyncIterator()
                while let state = await states.next() {
                    try Task.checkCancellation()
                    switch state {
                    case let .failed(_, failure):
                        throw RuntimeError.connectionFailed(failure)
                    case .closing, .closed:
                        throw RuntimeError.closed
                    case .detached, .attaching, .attached, .detaching:
                        continue
                    }
                }
                try Task.checkCancellation()
                throw RuntimeError.closed
            }
            guard let boundary = try await group.next() else {
                throw RuntimeError.closed
            }
            group.cancelAll()
            return boundary
        }
    }

    private nonisolated static func waitForFeatureBoundary(
        _ featureID: WebInspectorFeatureID,
        in container: WebInspectorModelContainer,
        after requiredGeneration: WebInspectorPageGeneration?
    ) async throws -> FeatureBoundary {
        var updates = container.featureStateUpdates(for: featureID)
            .makeAsyncIterator()
        while let state = await updates.next() {
            try Task.checkCancellation()
            switch container.state {
            case let .failed(_, failure):
                throw RuntimeError.connectionFailed(failure)
            case .closing, .closed:
                throw RuntimeError.closed
            case .detached, .attaching, .attached, .detaching:
                break
            }

            switch state {
            case let .ready(generation, _):
                guard requiredGeneration.map({ generation > $0 }) ?? true else {
                    continue
                }
                return FeatureBoundary(featureID: featureID, state: state)
            case .unsupported:
                return FeatureBoundary(featureID: featureID, state: state)
            case .disabled, .synchronizing:
                continue
            }
        }

        try Task.checkCancellation()
        if case let .failed(_, failure) = container.state {
            throw RuntimeError.connectionFailed(failure)
        }
        throw RuntimeError.closed
    }

    isolated deinit {
        driverTask.cancel()
        closeTask?.cancel()
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
    private var acceptedRawInputCount: UInt64
    private var completedCommandCount: UInt64
    private var pageReplacementCount: UInt64

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
        acceptedRawInputCount = 0
        completedCommandCount = 0
        pageReplacementCount = 0
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

    func counterSnapshot()
        -> WebInspectorDataKitTestRuntime.CounterSnapshot
    {
        WebInspectorDataKitTestRuntime.CounterSnapshot(
            acceptedRawInputCount: acceptedRawInputCount,
            completedCommandCount: completedCommandCount,
            pageReplacementCount: pageReplacementCount
        )
    }

    func emitNetworkRequest(
        _ request: WebInspectorDataKitTestRuntime.NetworkRequest
    ) async throws {
        responseBodies[request.id] = request.body
        try await emitNetworkRequestWillBeSent(
            request,
            targetID: currentTargetID,
            frameID: document.frameID
        )
        try await emitNetworkResponseReceived(
            request,
            targetID: currentTargetID
        )
        try await emitNetworkLoadingFinished(
            request,
            targetID: currentTargetID
        )
    }

    func emitNetworkRequestWillBeSent(
        _ request: WebInspectorDataKitTestRuntime.NetworkRequest
    ) async throws {
        responseBodies[request.id] = request.body
        try await emitNetworkRequestWillBeSent(
            request,
            targetID: currentTargetID,
            frameID: document.frameID
        )
    }

    func emitNetworkResponseReceived(
        _ request: WebInspectorDataKitTestRuntime.NetworkRequest
    ) async throws {
        try await emitNetworkResponseReceived(
            request,
            targetID: currentTargetID
        )
    }

    func emitNetworkLoadingFinished(
        _ request: WebInspectorDataKitTestRuntime.NetworkRequest
    ) async throws {
        try await emitNetworkLoadingFinished(
            request,
            targetID: currentTargetID
        )
    }

    func emitDOMAttributeModified(
        nodeID: String,
        name: String,
        value: String
    ) async throws {
        try await peer.emitTargetEvent(
            targetID: currentTargetID,
            method: "DOM.attributeModified",
            parameters: try WebInspectorTestJSONObject(
                encoding:
                    DOMAttributeModifiedParameters(
                        nodeId: nodeID,
                        name: name,
                        value: value
                    )
            )
        )
        recordAcceptedRawInput()
    }

    func emitDOMSetChildNodes(
        parentID: String,
        children: [WebInspectorDataKitTestRuntime.Node]
    ) async throws {
        try await peer.emitTargetEvent(
            targetID: currentTargetID,
            method: "DOM.setChildNodes",
            parameters: try WebInspectorTestJSONObject(
                encoding:
                    DOMSetChildNodesParameters(
                        parentId: parentID,
                        nodes: children.map { DOMNodeWire(node: $0, depth: 0) }
                    )
            )
        )
        recordAcceptedRawInput()
    }

    func emitDOMChildNodeCountUpdated(
        nodeID: String,
        count: Int
    ) async throws {
        try await peer.emitTargetEvent(
            targetID: currentTargetID,
            method: "DOM.childNodeCountUpdated",
            parameters: try WebInspectorTestJSONObject(
                encoding:
                    DOMChildNodeCountUpdatedParameters(
                        nodeId: nodeID,
                        childNodeCount: count
                    )
            )
        )
        recordAcceptedRawInput()
    }

    func emitDOMChildNodeInserted(
        parentID: String,
        previousNodeID: String?,
        node: WebInspectorDataKitTestRuntime.Node
    ) async throws {
        try await peer.emitTargetEvent(
            targetID: currentTargetID,
            method: "DOM.childNodeInserted",
            parameters: try WebInspectorTestJSONObject(
                encoding:
                    DOMChildNodeInsertedParameters(
                        parentNodeId: parentID,
                        previousNodeId: previousNodeID ?? "0",
                        node: DOMNodeWire(node: node, depth: 0)
                    )
            )
        )
        recordAcceptedRawInput()
    }

    func emitDOMChildNodeRemoved(
        parentID: String,
        nodeID: String
    ) async throws {
        try await peer.emitTargetEvent(
            targetID: currentTargetID,
            method: "DOM.childNodeRemoved",
            parameters: try WebInspectorTestJSONObject(
                encoding:
                    DOMChildNodeRemovedParameters(
                        parentNodeId: parentID,
                        nodeId: nodeID
                    )
            )
        )
        recordAcceptedRawInput()
    }

    func replacePage(
        document: WebInspectorDataKitTestRuntime.Document,
        networkReplay: [WebInspectorDataKitTestRuntime.NetworkRequest]
    ) async throws {
        let replacement = prepareReplacement(
            document: document,
            networkReplay: networkReplay
        )
        do {
            try await peer.createTarget(
                .init(
                    id: replacement.newTargetID,
                    type: "page",
                    isProvisional: true
                ))
            recordAcceptedRawInput()
            try await peer.commitProvisionalTarget(
                from: replacement.oldTargetID,
                to: replacement.newTargetID
            )
            recordAcceptedRawInput()
            Self.increment(
                &pageReplacementCount,
                named: "page replacement"
            )
        } catch {
            rollbackReplacement(replacement)
            throw error
        }
    }

    private func prepareReplacement(
        document: WebInspectorDataKitTestRuntime.Document,
        networkReplay: [WebInspectorDataKitTestRuntime.NetworkRequest]
    ) -> Replacement {
        Self.increment(&replacementOrdinal, named: "target ordinal")
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

    private func rollbackReplacement(_ replacement: Replacement) {
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
        try await performResponse(to: command)
        Self.increment(&completedCommandCount, named: "completed command")
    }

    private func performResponse(to command: WebInspectorTestPeer.Command) async throws {
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
                with: try WebInspectorTestJSONObject(
                    encoding:
                        DOMDocumentResult(root: DOMNodeWire(document: document))
                )
            )
        case "Page.getResourceTree":
            try await peer.reply(
                to: command,
                with: try WebInspectorTestJSONObject(
                    encoding:
                        PageResourceTreeResult(document: document)
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
                with: try WebInspectorTestJSONObject(
                    encoding:
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
        try await emitNetworkRequestWillBeSent(
            request,
            targetID: targetID,
            frameID: frameID
        )
        try await emitNetworkResponseReceived(request, targetID: targetID)
        try await emitNetworkLoadingFinished(request, targetID: targetID)
    }

    private func emitNetworkRequestWillBeSent(
        _ request: WebInspectorDataKitTestRuntime.NetworkRequest,
        targetID: String,
        frameID: String
    ) async throws {
        try await peer.emitTargetEvent(
            targetID: targetID,
            method: "Network.requestWillBeSent",
            parameters: try WebInspectorTestJSONObject(
                encoding:
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
        recordAcceptedRawInput()
    }

    private func emitNetworkResponseReceived(
        _ request: WebInspectorDataKitTestRuntime.NetworkRequest,
        targetID: String
    ) async throws {
        try await peer.emitTargetEvent(
            targetID: targetID,
            method: "Network.responseReceived",
            parameters: try WebInspectorTestJSONObject(
                encoding:
                    ResponseReceivedParameters(
                        requestId: request.id,
                        response: .init(
                            url: request.url,
                            status: request.status,
                            statusText: request.statusText,
                            mimeType: request.mimeType,
                            headers: request.responseHeaders,
                            requestHeaders: request.responseRequestHeaders
                        ),
                        timestamp: 2,
                        type: request.resourceType.rawValue
                    )
            )
        )
        recordAcceptedRawInput()
    }

    private func emitNetworkLoadingFinished(
        _ request: WebInspectorDataKitTestRuntime.NetworkRequest,
        targetID: String
    ) async throws {
        try await peer.emitTargetEvent(
            targetID: targetID,
            method: "Network.loadingFinished",
            parameters: try WebInspectorTestJSONObject(
                encoding:
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
        recordAcceptedRawInput()
    }

    private func recordAcceptedRawInput() {
        Self.increment(&acceptedRawInputCount, named: "accepted raw input")
    }

    private static func increment(
        _ value: inout UInt64,
        named counterName: StaticString
    ) {
        let (next, overflow) = value.addingReportingOverflow(1)
        precondition(!overflow, "DataKit test \(counterName) counter exhausted.")
        value = next
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

private struct PageResourceTreeResult: Encodable {
    struct FrameTree: Encodable {
        struct Frame: Encodable {
            let id: String
            let loaderId: String
            let name: String
            let url: String
            let securityOrigin: String?
            let mimeType: String
        }

        struct Resource: Encodable {
            let url: String
            let type: String
            let mimeType: String
        }

        let frame: Frame
        let resources: [Resource]
    }

    let frameTree: FrameTree

    init(document: WebInspectorDataKitTestRuntime.Document) {
        frameTree = FrameTree(
            frame: .init(
                id: document.frameID,
                loaderId: "\(document.frameID)-loader",
                name: "",
                url: document.url ?? "",
                securityOrigin: nil,
                mimeType: "text/html"
            ),
            resources: []
        )
    }
}

private struct DOMAttributeModifiedParameters: Encodable {
    let nodeId: String
    let name: String
    let value: String
}

private struct DOMSetChildNodesParameters: Encodable {
    let parentId: String
    let nodes: [DOMNodeWire]
}

private struct DOMChildNodeCountUpdatedParameters: Encodable {
    let nodeId: String
    let childNodeCount: Int
}

private struct DOMChildNodeInsertedParameters: Encodable {
    let parentNodeId: String
    let previousNodeId: String
    let node: DOMNodeWire
}

private struct DOMChildNodeRemovedParameters: Encodable {
    let parentNodeId: String
    let nodeId: String
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
    let childNodeCount: Int?
    let children: [DOMNodeWire]?

    init(document: WebInspectorDataKitTestRuntime.Document) {
        nodeId = document.id
        nodeType = 9
        nodeName = "#document"
        localName = ""
        nodeValue = ""
        frameId = document.frameID
        documentURL = document.url
        attributes = []
        let protocolChildren = document.children.filter { !$0.isASCIIWhitespaceText }
        childNodeCount = protocolChildren.count
        children =
            protocolChildren.isEmpty
            ? nil
            : protocolChildren.map { DOMNodeWire(node: $0, depth: .max) }
    }

    init(node: WebInspectorDataKitTestRuntime.Node, depth: Int) {
        nodeId = node.id
        nodeType = node.nodeType
        nodeName = node.nodeName
        localName = node.localName
        nodeValue = node.nodeValue
        frameId = nil
        documentURL = nil
        attributes = node.attributes.sorted { $0.key < $1.key }.flatMap { [$0.key, $0.value] }
        let protocolChildren = node.children.filter { !$0.isASCIIWhitespaceText }
        childNodeCount = node.isContainer ? protocolChildren.count : nil
        if depth > 0 {
            children =
                protocolChildren.isEmpty
                ? nil
                : protocolChildren.map { DOMNodeWire(node: $0, depth: depth - 1) }
        } else if node.children.count == 1, node.children[0].nodeType == 3 {
            children = [DOMNodeWire(node: node.children[0], depth: 0)]
        } else {
            children = nil
        }
    }
}

private extension WebInspectorDataKitTestRuntime.Node {
    var isContainer: Bool {
        nodeType == 1 || nodeType == 9 || nodeType == 11
    }

    var isASCIIWhitespaceText: Bool {
        guard nodeType == 3 else {
            return false
        }
        return nodeValue.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x09, 0x0A, 0x0C, 0x0D, 0x20:
                true
            default:
                false
            }
        }
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
        let requestHeaders: [String: String]?
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
