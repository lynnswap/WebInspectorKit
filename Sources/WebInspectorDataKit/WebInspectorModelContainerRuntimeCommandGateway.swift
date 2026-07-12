import WebInspectorProxyKit

package enum WebInspectorRuntimeCommandGatewayError:
    Error,
    Equatable,
    Sendable
{
    case closed
    case detached
    case domainNotConfigured(ModelDomain)
    case foreignStore
    case staleAuthority
    case currentPageUnavailable
    case physicalAgentUnavailable(WebInspectorTarget.ID)
    case consoleMessageNotFound
    case consoleParameterIndexOutOfBounds(Int)
    case runtimeContextNotFound
    case graphNotFound
    case graphClosed
    case objectNotFound
    case objectHasNoRemoteIdentity
    case commandResultMismatch
    case proxy(WebInspectorProxyError)
    case authorization(ConnectionModelCommandError)
    case invalidReply(String)
}

/// Opaque identity for one Core-owned Runtime object graph.
///
/// Raw WebKit object identifiers never leave this graph's registry as command
/// authority. The token and the local resource ordinal must both match before
/// the Core can recover a wire identifier.
package struct WebInspectorRuntimeObjectGraphToken: Hashable, Sendable {
    package let storeID: WebInspectorContainerStoreID
    package let rawValue: UInt64
}

package struct WebInspectorRuntimeObjectResourceID: Hashable, Sendable {
    package let graph: WebInspectorRuntimeObjectGraphToken
    package let ordinal: UInt64
}

package struct WebInspectorRuntimeObjectResource: Equatable, Sendable {
    package let id: WebInspectorRuntimeObjectResourceID
    package let payload: CanonicalRuntimeRemoteObjectPayload
}

package struct WebInspectorConsoleParameterGraph: Equatable, Sendable {
    package let token: WebInspectorRuntimeObjectGraphToken
    package let root: WebInspectorRuntimeObjectResource
}

package struct WebInspectorRuntimeObjectGroupClaim: Equatable, Sendable {
    package let token: WebInspectorRuntimeObjectGraphToken
    package let wireGroup: Runtime.ObjectGroup
}

package struct WebInspectorRuntimeEvaluationResource: Equatable, Sendable {
    package let object: WebInspectorRuntimeObjectResource
    package let wasThrown: Bool
    package let savedResultIndex: Int?
}

package struct WebInspectorRuntimePropertyResource: Equatable, Sendable {
    package let name: String
    package let value: WebInspectorRuntimeObjectResource?
    package let writable: Bool?
    package let get: WebInspectorRuntimeObjectResource?
    package let set: WebInspectorRuntimeObjectResource?
    package let wasThrown: Bool?
    package let configurable: Bool?
    package let enumerable: Bool?
    package let isOwn: Bool?
    package let symbol: WebInspectorRuntimeObjectResource?
    package let isPrivate: Bool?
    package let nativeGetter: Bool?
}

package struct WebInspectorRuntimeCollectionEntryResource: Equatable, Sendable {
    package let key: WebInspectorRuntimeObjectResource?
    package let value: WebInspectorRuntimeObjectResource
}

package enum WebInspectorRuntimeCommandGatewayResult: Equatable, Sendable {
    case evaluation(WebInspectorRuntimeEvaluationResource)
    case properties([WebInspectorRuntimePropertyResource])
    case preview(CanonicalRuntimeObjectPreview)
    case collectionEntries([WebInspectorRuntimeCollectionEntryResource])
}

package struct WebInspectorRuntimeCommandGatewayMetrics: Equatable, Sendable {
    package let graphCount: Int
    package let openGraphCount: Int
    package let operationCount: Int
    package let wireCommandCount: Int
    package let wireGroupReleaseCount: Int
    package let invalidatedGraphCount: Int
}

package struct WebInspectorRuntimeCommandEnvironment: Sendable {
    package let resourceID: UInt64
    package let attachmentGeneration: WebInspectorContainerAttachmentGeneration
    package let pageGeneration: WebInspectorPage.Generation
    package let currentPageID: WebInspectorTarget.ID?
    package let targets: [ModelTargetState]
    package let proxy: WebInspectorProxy
    package let feedID: ConnectionModelFeedID

    fileprivate func targetState(
        _ id: WebInspectorTarget.ID
    ) -> ModelTargetState? {
        targets.first { $0.target.id == id }
    }
}

package struct WebInspectorRuntimeCommandGatewayState {
    fileprivate enum GraphOwner: Sendable {
        case consoleParameter(
            messageID: CanonicalConsoleMessageIDStorage,
            parameterIndex: Int,
            seed: CanonicalConsoleParameterResourceSeed
        )
        case independent(
            wireGroup: Runtime.ObjectGroup,
            boundContextID: CanonicalRuntimeContextIDStorage?
        )
    }

    fileprivate struct Authority: Sendable {
        let resourceID: UInt64
        let attachmentGeneration: WebInspectorContainerAttachmentGeneration
        let pageGeneration: WebInspectorPage.Generation
        let semanticTarget: ModelTarget
        let agentTarget: ModelTarget
        let navigationEpoch: ModelNavigationEpoch
        let runtimeBindingEpoch: ModelRuntimeBindingEpoch
        let consoleBindingEpoch: ModelConsoleBindingEpoch?
        let proxy: WebInspectorProxy
        let feedID: ConnectionModelFeedID

        func hasSameAuthority(as other: Self) -> Bool {
            resourceID == other.resourceID
                && attachmentGeneration == other.attachmentGeneration
                && pageGeneration == other.pageGeneration
                && semanticTarget == other.semanticTarget
                && agentTarget == other.agentTarget
                && navigationEpoch == other.navigationEpoch
                && runtimeBindingEpoch == other.runtimeBindingEpoch
                && consoleBindingEpoch == other.consoleBindingEpoch
                && proxy === other.proxy
                && feedID == other.feedID
        }

        var authorization: ConnectionModelCommandAuthorization {
            ConnectionModelCommandAuthorization(
                feedID: feedID,
                generation: pageGeneration,
                runtime: ConnectionModelCommandAuthorization.Runtime(
                    agentTargetID: agentTarget.id,
                    epoch: runtimeBindingEpoch,
                    semanticTarget:
                        ConnectionModelCommandAuthorization.Runtime
                        .SemanticTarget(
                            targetID: semanticTarget.id,
                            navigationEpoch: navigationEpoch
                        ),
                    consoleBinding: consoleBindingEpoch.map {
                        ConnectionModelCommandAuthorization.Runtime
                            .ConsoleBinding(
                                agentTargetID: agentTarget.id,
                                epoch: $0
                            )
                    }
                )
            )
        }
    }

    fileprivate enum GraphLifecycle: Sendable {
        case open
        case closing
        case terminal(WebInspectorRuntimeCommandGatewayError?)
    }

    fileprivate struct RegisteredObject: Sendable {
        let rawID: Runtime.RemoteObject.ID?
        var payload: CanonicalRuntimeRemoteObjectPayload
    }

    fileprivate struct Graph: Sendable {
        let token: WebInspectorRuntimeObjectGraphToken
        let owner: GraphOwner
        let authority: Authority
        var lifecycle: GraphLifecycle
        var nextObjectOrdinal: UInt64
        var objectsByOrdinal: [UInt64: RegisteredObject]
        var ordinalByRawID: [Runtime.RemoteObject.ID: UInt64]
        var operationIDs: Set<UInt64>
        var closeCompletion: ReplyPromise<Void>?
        var closeTask: Task<Void, Never>?
    }

    fileprivate struct TerminalGraph: Sendable {
        let token: WebInspectorRuntimeObjectGraphToken
        let error: WebInspectorRuntimeCommandGatewayError?
        let closeResult: Result<Void, WebInspectorRuntimeCommandGatewayError>?
    }

    fileprivate struct Operation: Sendable {
        let graphToken: WebInspectorRuntimeObjectGraphToken
        let route: WebInspectorRuntimeCommandRoute
        let completion: ReplyPromise<WebInspectorRuntimeCommandGatewayResult>
        let task: Task<Void, Never>
        var isRetired: Bool
    }

    fileprivate var nextGraphID: UInt64 = 0
    fileprivate var graphs: [UInt64: Graph] = [:]
    fileprivate var terminalGraphs: [UInt64: TerminalGraph] = [:]
    fileprivate var nextOperationID: UInt64 = 0
    fileprivate var operations: [UInt64: Operation] = [:]
    fileprivate var wireCommandCount = 0
    fileprivate var wireGroupReleaseCount = 0
    fileprivate var invalidatedGraphCount = 0

    package init() {}

    package var metrics: WebInspectorRuntimeCommandGatewayMetrics {
        WebInspectorRuntimeCommandGatewayMetrics(
            graphCount: graphs.count + terminalGraphs.count,
            openGraphCount: graphs.values.count {
                if case .open = $0.lifecycle { true } else { false }
            },
            operationCount: operations.count,
            wireCommandCount: wireCommandCount,
            wireGroupReleaseCount: wireGroupReleaseCount,
            invalidatedGraphCount: invalidatedGraphCount
        )
    }
}

private enum WebInspectorRuntimeWireCommand: Sendable {
    case evaluate(
        expression: String,
        context: Runtime.ExecutionContext.ID?,
        objectGroup: Runtime.ObjectGroup
    )
    case properties(object: Runtime.RemoteObject.ID, ownProperties: Bool)
    case preview(object: Runtime.RemoteObject.ID)
    case collectionEntries(object: Runtime.RemoteObject.ID)
}

private enum WebInspectorRuntimeWireResult: Sendable {
    case evaluation(Runtime.EvaluationResult)
    case properties([Runtime.PropertyDescriptor])
    case preview(Runtime.ObjectPreview)
    case collectionEntries([Runtime.CollectionEntry])
}

private struct WebInspectorRuntimeCommandRoute: Sendable {
    let graphToken: WebInspectorRuntimeObjectGraphToken
    let authority: WebInspectorRuntimeCommandGatewayState.Authority
    let command: WebInspectorRuntimeWireCommand
}

private struct WebInspectorRuntimeGraphCloseClaim: Sendable {
    let completion: ReplyPromise<Void>
}

package extension WebInspectorModelContainerCore {
    /// Claims a Console parameter and its descendants as one exact Runtime
    /// object graph. Console owns the backend `"console"` group; closing or
    /// invalidating this local graph never sends `Runtime.releaseObjectGroup`.
    func claimConsoleParameterGraph(
        messageID: CanonicalConsoleMessageIDStorage,
        parameterIndex: Int
    ) throws -> WebInspectorConsoleParameterGraph {
        guard configuredDomains.contains(.console) else {
            throw WebInspectorRuntimeCommandGatewayError
                .domainNotConfigured(.console)
        }
        guard messageID.storeID == storeID else {
            throw WebInspectorRuntimeCommandGatewayError.foreignStore
        }
        let environment = try runtimeCommandEnvironment()
        guard let message = runtimeCommandConsoleMessage(for: messageID) else {
            throw WebInspectorRuntimeCommandGatewayError.consoleMessageNotFound
        }
        guard message.parameters.indices.contains(parameterIndex) else {
            throw WebInspectorRuntimeCommandGatewayError
                .consoleParameterIndexOutOfBounds(parameterIndex)
        }
        let seed = message.parameters[parameterIndex]
        let owner = WebInspectorRuntimeCommandGatewayState.GraphOwner
            .consoleParameter(
                messageID: messageID,
                parameterIndex: parameterIndex,
                seed: seed
            )
        let authority = try runtimeCommandAuthority(
            for: owner,
            environment: environment
        )
        let token = allocateRuntimeGraphToken()
        var graph = WebInspectorRuntimeCommandGatewayState.Graph(
            token: token,
            owner: owner,
            authority: authority,
            lifecycle: .open,
            nextObjectOrdinal: 0,
            objectsByOrdinal: [:],
            ordinalByRawID: [:],
            operationIDs: [],
            closeCompletion: nil,
            closeTask: nil
        )
        let root = registerRuntimeObject(seed.payload, in: &graph)
        precondition(
            runtimeCommandGatewayState.graphs[token.rawValue] == nil
                && runtimeCommandGatewayState.terminalGraphs[token.rawValue]
                    == nil,
            "Runtime graph allocator reused an active identity."
        )
        runtimeCommandGatewayState.graphs[token.rawValue] = graph
        return WebInspectorConsoleParameterGraph(token: token, root: root)
    }

    /// Creates one independent, uniquely named backend object group. An
    /// optional canonical RuntimeContext binds evaluation to that exact
    /// execution context; an unbound group claims the canonical current page.
    func createRuntimeObjectGroup(
        named name: String,
        boundTo contextID: CanonicalRuntimeContextIDStorage? = nil
    ) throws -> WebInspectorRuntimeObjectGroupClaim {
        guard configuredDomains.contains(.runtime) else {
            throw WebInspectorRuntimeCommandGatewayError
                .domainNotConfigured(.runtime)
        }
        if let contextID, contextID.storeID != storeID {
            throw WebInspectorRuntimeCommandGatewayError.foreignStore
        }
        let environment = try runtimeCommandEnvironment()
        let token = allocateRuntimeGraphToken()
        let wireName = [
            "WebInspectorDataKit",
            storeID.rawValue.uuidString,
            String(token.rawValue),
            name,
        ].joined(separator: ":")
        let wireGroup = Runtime.ObjectGroup.other(wireName)
        let owner = WebInspectorRuntimeCommandGatewayState.GraphOwner
            .independent(
                wireGroup: wireGroup,
                boundContextID: contextID
            )
        let authority = try runtimeCommandAuthority(
            for: owner,
            environment: environment
        )
        let graph = WebInspectorRuntimeCommandGatewayState.Graph(
            token: token,
            owner: owner,
            authority: authority,
            lifecycle: .open,
            nextObjectOrdinal: 0,
            objectsByOrdinal: [:],
            ordinalByRawID: [:],
            operationIDs: [],
            closeCompletion: nil,
            closeTask: nil
        )
        precondition(
            runtimeCommandGatewayState.graphs[token.rawValue] == nil
                && runtimeCommandGatewayState.terminalGraphs[token.rawValue]
                    == nil,
            "Runtime graph allocator reused an active identity."
        )
        runtimeCommandGatewayState.graphs[token.rawValue] = graph
        return WebInspectorRuntimeObjectGroupClaim(
            token: token,
            wireGroup: wireGroup
        )
    }

    func evaluateRuntimeExpression(
        _ expression: String,
        in token: WebInspectorRuntimeObjectGraphToken
    ) async throws -> WebInspectorRuntimeEvaluationResource {
        let result = try await performRuntimeCommand(
            graph: token,
            makeCommand: { owner, _ in
                guard
                    case let .independent(wireGroup, boundContextID) = owner
                else {
                    throw WebInspectorRuntimeCommandGatewayError.graphClosed
                }
                let context = boundContextID.flatMap {
                    runtimeCommandContext(for: $0)?.id.rawContextID
                }
                if boundContextID != nil, context == nil {
                    throw WebInspectorRuntimeCommandGatewayError
                        .runtimeContextNotFound
                }
                return .evaluate(
                    expression: expression,
                    context: context,
                    objectGroup: wireGroup
                )
            }
        )
        guard case let .evaluation(evaluation) = result else {
            throw WebInspectorRuntimeCommandGatewayError.commandResultMismatch
        }
        return evaluation
    }

    func runtimeProperties(
        of objectID: WebInspectorRuntimeObjectResourceID,
        ownProperties: Bool = true
    ) async throws -> [WebInspectorRuntimePropertyResource] {
        let result = try await performRuntimeObjectCommand(
            objectID,
            command: { .properties(object: $0, ownProperties: ownProperties) }
        )
        guard case let .properties(properties) = result else {
            throw WebInspectorRuntimeCommandGatewayError.commandResultMismatch
        }
        return properties
    }

    func runtimePreview(
        of objectID: WebInspectorRuntimeObjectResourceID
    ) async throws -> CanonicalRuntimeObjectPreview {
        let result = try await performRuntimeObjectCommand(
            objectID,
            command: { .preview(object: $0) }
        )
        guard case let .preview(preview) = result else {
            throw WebInspectorRuntimeCommandGatewayError.commandResultMismatch
        }
        return preview
    }

    func runtimeCollectionEntries(
        of objectID: WebInspectorRuntimeObjectResourceID
    ) async throws -> [WebInspectorRuntimeCollectionEntryResource] {
        let result = try await performRuntimeObjectCommand(
            objectID,
            command: { .collectionEntries(object: $0) }
        )
        guard case let .collectionEntries(entries) = result else {
            throw WebInspectorRuntimeCommandGatewayError.commandResultMismatch
        }
        return entries
    }

    /// Closes one local graph. Independent groups first reject new operations,
    /// drain every already-claimed command, send their unique wire release once,
    /// and only then invalidate local object identities. Caller cancellation
    /// removes only that caller's wait from the Core-owned close completion.
    func closeRuntimeObjectGraph(
        _ token: WebInspectorRuntimeObjectGraphToken
    ) async throws {
        try Task.checkCancellation()
        let claim = try claimRuntimeObjectGraphClose(token)
        try await claim.completion.value()
    }

    var runtimeCommandGatewayMetrics: WebInspectorRuntimeCommandGatewayMetrics {
        runtimeCommandGatewayState.metrics
    }
}

private extension WebInspectorModelContainerCore {
    func allocateRuntimeGraphToken() -> WebInspectorRuntimeObjectGraphToken {
        precondition(
            runtimeCommandGatewayState.nextGraphID < UInt64.max,
            "Runtime graph identity exhausted UInt64."
        )
        runtimeCommandGatewayState.nextGraphID += 1
        return WebInspectorRuntimeObjectGraphToken(
            storeID: storeID,
            rawValue: runtimeCommandGatewayState.nextGraphID
        )
    }

    func runtimeCommandAuthority(
        for owner: WebInspectorRuntimeCommandGatewayState.GraphOwner,
        environment: WebInspectorRuntimeCommandEnvironment
    ) throws -> WebInspectorRuntimeCommandGatewayState.Authority {
        switch owner {
        case let .consoleParameter(messageID, parameterIndex, expectedSeed):
            guard messageID.storeID == storeID else {
                throw WebInspectorRuntimeCommandGatewayError.foreignStore
            }
            guard let message = runtimeCommandConsoleMessage(for: messageID)
            else {
                throw WebInspectorRuntimeCommandGatewayError
                    .consoleMessageNotFound
            }
            guard message.parameters.indices.contains(parameterIndex) else {
                throw WebInspectorRuntimeCommandGatewayError
                    .consoleParameterIndexOutOfBounds(parameterIndex)
            }
            let seed = message.parameters[parameterIndex]
            guard seed == expectedSeed,
                seed.authority.ownerMessageID == messageID,
                seed.authority.pageGeneration == message.membership.pageGeneration,
                seed.authority.semanticTargetID
                    == message.membership.semanticTargetID,
                seed.authority.agentTargetID == message.membership.agentTargetID,
                seed.authority.navigationEpoch
                    == message.membership.navigationEpoch,
                seed.authority.runtimeBindingEpoch
                    == message.membership.runtimeBindingEpoch,
                seed.authority.consoleBindingEpoch
                    == message.membership.consoleBindingEpoch
            else {
                throw WebInspectorRuntimeCommandGatewayError.staleAuthority
            }
            return try makeRuntimeCommandAuthority(
                environment: environment,
                attachmentGeneration: messageID.attachmentGeneration,
                pageGeneration: seed.authority.pageGeneration,
                semanticTargetID: seed.authority.semanticTargetID,
                agentTargetID: seed.authority.agentTargetID,
                navigationEpoch: seed.authority.navigationEpoch,
                runtimeBindingEpoch: seed.authority.runtimeBindingEpoch,
                consoleBindingEpoch: seed.authority.consoleBindingEpoch
            )

        case let .independent(_, boundContextID):
            if let boundContextID {
                guard boundContextID.storeID == storeID else {
                    throw WebInspectorRuntimeCommandGatewayError.foreignStore
                }
                guard
                    let context = runtimeCommandContext(for: boundContextID)
                else {
                    throw WebInspectorRuntimeCommandGatewayError
                        .runtimeContextNotFound
                }
                return try makeRuntimeCommandAuthority(
                    environment: environment,
                    attachmentGeneration: boundContextID.attachmentGeneration,
                    pageGeneration: boundContextID.pageGeneration,
                    semanticTargetID: context.membership.semanticTargetID,
                    agentTargetID: boundContextID.agentTargetID,
                    navigationEpoch: context.membership.navigationEpoch,
                    runtimeBindingEpoch: context.membership.runtimeBindingEpoch,
                    consoleBindingEpoch: nil
                )
            }

            guard let currentPageID = environment.currentPageID,
                let currentPage = environment.targetState(currentPageID),
                let runtimeBindingEpoch = currentPage.runtimeBindingEpoch
            else {
                throw WebInspectorRuntimeCommandGatewayError
                    .currentPageUnavailable
            }
            return try makeRuntimeCommandAuthority(
                environment: environment,
                attachmentGeneration: environment.attachmentGeneration,
                pageGeneration: environment.pageGeneration,
                semanticTargetID: currentPageID,
                agentTargetID: currentPageID,
                navigationEpoch: currentPage.navigationEpoch,
                runtimeBindingEpoch: runtimeBindingEpoch,
                consoleBindingEpoch: nil
            )
        }
    }

    func makeRuntimeCommandAuthority(
        environment: WebInspectorRuntimeCommandEnvironment,
        attachmentGeneration: WebInspectorContainerAttachmentGeneration,
        pageGeneration: WebInspectorPage.Generation,
        semanticTargetID: WebInspectorTarget.ID,
        agentTargetID: WebInspectorTarget.ID,
        navigationEpoch: ModelNavigationEpoch,
        runtimeBindingEpoch: ModelRuntimeBindingEpoch,
        consoleBindingEpoch: ModelConsoleBindingEpoch?
    ) throws -> WebInspectorRuntimeCommandGatewayState.Authority {
        guard environment.attachmentGeneration == attachmentGeneration,
            environment.pageGeneration == pageGeneration
        else {
            throw WebInspectorRuntimeCommandGatewayError.staleAuthority
        }
        guard let semanticState = environment.targetState(semanticTargetID),
            semanticState.navigationEpoch == navigationEpoch
        else {
            throw WebInspectorRuntimeCommandGatewayError.staleAuthority
        }
        guard let agentState = environment.targetState(agentTargetID) else {
            throw WebInspectorRuntimeCommandGatewayError
                .physicalAgentUnavailable(agentTargetID)
        }
        let consoleBindingMatches = if let consoleBindingEpoch {
            agentState.consoleBindingEpoch == consoleBindingEpoch
        } else {
            true
        }
        guard agentState.runtimeBindingEpoch == runtimeBindingEpoch,
            consoleBindingMatches
        else {
            throw WebInspectorRuntimeCommandGatewayError.staleAuthority
        }
        return WebInspectorRuntimeCommandGatewayState.Authority(
            resourceID: environment.resourceID,
            attachmentGeneration: environment.attachmentGeneration,
            pageGeneration: environment.pageGeneration,
            semanticTarget: semanticState.target,
            agentTarget: agentState.target,
            navigationEpoch: navigationEpoch,
            runtimeBindingEpoch: runtimeBindingEpoch,
            consoleBindingEpoch: consoleBindingEpoch,
            proxy: environment.proxy,
            feedID: environment.feedID
        )
    }

    func registerRuntimeObject(
        _ payload: CanonicalRuntimeRemoteObjectPayload,
        in graph: inout WebInspectorRuntimeCommandGatewayState.Graph
    ) -> WebInspectorRuntimeObjectResource {
        if let rawID = payload.rawObjectID,
            let ordinal = graph.ordinalByRawID[rawID]
        {
            guard var registered = graph.objectsByOrdinal[ordinal] else {
                preconditionFailure(
                    "Runtime raw-object index lost its registered resource."
                )
            }
            registered.payload = payload
            graph.objectsByOrdinal[ordinal] = registered
            return WebInspectorRuntimeObjectResource(
                id: WebInspectorRuntimeObjectResourceID(
                    graph: graph.token,
                    ordinal: ordinal
                ),
                payload: payload
            )
        }
        precondition(
            graph.nextObjectOrdinal < UInt64.max,
            "Runtime graph exhausted object resource ordinals."
        )
        graph.nextObjectOrdinal += 1
        let ordinal = graph.nextObjectOrdinal
        graph.objectsByOrdinal[ordinal] =
            WebInspectorRuntimeCommandGatewayState.RegisteredObject(
                rawID: payload.rawObjectID,
                payload: payload
            )
        if let rawID = payload.rawObjectID {
            precondition(
                graph.ordinalByRawID.updateValue(ordinal, forKey: rawID) == nil,
                "Runtime graph registered one raw object twice."
            )
        }
        return WebInspectorRuntimeObjectResource(
            id: WebInspectorRuntimeObjectResourceID(
                graph: graph.token,
                ordinal: ordinal
            ),
            payload: payload
        )
    }

    func performRuntimeObjectCommand(
        _ objectID: WebInspectorRuntimeObjectResourceID,
        command: (Runtime.RemoteObject.ID) -> WebInspectorRuntimeWireCommand
    ) async throws -> WebInspectorRuntimeCommandGatewayResult {
        try await performRuntimeCommand(
            graph: objectID.graph,
            makeCommand: { _, graph in
                guard let object = graph.objectsByOrdinal[objectID.ordinal]
                else {
                    throw WebInspectorRuntimeCommandGatewayError.objectNotFound
                }
                guard let rawID = object.rawID else {
                    throw WebInspectorRuntimeCommandGatewayError
                        .objectHasNoRemoteIdentity
                }
                return command(rawID)
            }
        )
    }

    func performRuntimeCommand(
        graph token: WebInspectorRuntimeObjectGraphToken,
        makeCommand: (
            WebInspectorRuntimeCommandGatewayState.GraphOwner,
            WebInspectorRuntimeCommandGatewayState.Graph
        ) throws -> WebInspectorRuntimeWireCommand
    ) async throws -> WebInspectorRuntimeCommandGatewayResult {
        try Task.checkCancellation()
        let completion = try claimRuntimeCommand(
            graph: token,
            makeCommand: makeCommand
        )
        return try await completion.value()
    }

    func claimRuntimeCommand(
        graph token: WebInspectorRuntimeObjectGraphToken,
        makeCommand: (
            WebInspectorRuntimeCommandGatewayState.GraphOwner,
            WebInspectorRuntimeCommandGatewayState.Graph
        ) throws -> WebInspectorRuntimeWireCommand
    ) throws -> ReplyPromise<WebInspectorRuntimeCommandGatewayResult> {
        guard token.storeID == storeID else {
            throw WebInspectorRuntimeCommandGatewayError.foreignStore
        }
        let environment = try runtimeCommandEnvironment()
        guard var graph = runtimeCommandGatewayState.graphs[token.rawValue],
            graph.token == token
        else {
            if let terminal = runtimeCommandGatewayState.terminalGraphs[
                token.rawValue
            ], terminal.token == token {
                throw terminal.error
                    ?? WebInspectorRuntimeCommandGatewayError.graphClosed
            }
            throw WebInspectorRuntimeCommandGatewayError.graphNotFound
        }
        switch graph.lifecycle {
        case .open:
            break
        case .closing:
            throw WebInspectorRuntimeCommandGatewayError.graphClosed
        case let .terminal(error):
            throw error ?? WebInspectorRuntimeCommandGatewayError.graphClosed
        }
        let currentAuthority = try runtimeCommandAuthority(
            for: graph.owner,
            environment: environment
        )
        guard graph.authority.hasSameAuthority(as: currentAuthority) else {
            retireRuntimeObjectGraph(token, with: .staleAuthority)
            throw WebInspectorRuntimeCommandGatewayError.staleAuthority
        }
        let command = try makeCommand(graph.owner, graph)
        precondition(
            runtimeCommandGatewayState.nextOperationID < UInt64.max,
            "Runtime command operation identity exhausted UInt64."
        )
        runtimeCommandGatewayState.nextOperationID += 1
        let operationID = runtimeCommandGatewayState.nextOperationID
        let route = WebInspectorRuntimeCommandRoute(
            graphToken: token,
            authority: graph.authority,
            command: command
        )
        let completion = ReplyPromise<WebInspectorRuntimeCommandGatewayResult>()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let result = await Self.performRuntimeWireCommand(route)
            guard let self else {
                completion.fulfill(
                    .failure(WebInspectorRuntimeCommandGatewayError.closed)
                )
                return
            }
            await self.finishRuntimeCommand(operationID, result: result)
        }
        let operation = WebInspectorRuntimeCommandGatewayState.Operation(
            graphToken: token,
            route: route,
            completion: completion,
            task: task,
            isRetired: false
        )
        precondition(
            runtimeCommandGatewayState.operations[operationID] == nil,
            "Runtime command operation identity was reused."
        )
        graph.operationIDs.insert(operationID)
        runtimeCommandGatewayState.graphs[token.rawValue] = graph
        runtimeCommandGatewayState.operations[operationID] = operation
        runtimeCommandGatewayState.wireCommandCount += 1
        return completion
    }

    nonisolated static func performRuntimeWireCommand(
        _ route: WebInspectorRuntimeCommandRoute
    ) async -> Result<
        WebInspectorRuntimeWireResult,
        WebInspectorRuntimeCommandGatewayError
    > {
        let target = route.authority.proxy.modelTarget(
            route.authority.agentTarget,
            authorization: route.authority.authorization
        )
        do {
            switch route.command {
            case let .evaluate(expression, context, objectGroup):
                return .success(
                    .evaluation(
                        try await target.runtime.evaluate(
                            expression,
                            in: context,
                            objectGroup: objectGroup
                        )
                    )
                )
            case let .properties(object, ownProperties):
                return .success(
                    .properties(
                        try await target.runtime.properties(
                            of: object,
                            ownProperties: ownProperties
                        )
                    )
                )
            case let .preview(object):
                return .success(
                    .preview(try await target.runtime.preview(of: object))
                )
            case let .collectionEntries(object):
                return .success(
                    .collectionEntries(
                        try await target.runtime.collectionEntries(of: object)
                    )
                )
            }
        } catch let error as WebInspectorProxyError {
            return .failure(.proxy(error))
        } catch let error as ConnectionModelCommandError {
            return .failure(.authorization(error))
        } catch is CancellationError {
            return .failure(.staleAuthority)
        } catch {
            return .failure(.invalidReply(String(reflecting: error)))
        }
    }

    func finishRuntimeCommand(
        _ operationID: UInt64,
        result: Result<
            WebInspectorRuntimeWireResult,
            WebInspectorRuntimeCommandGatewayError
        >
    ) {
        guard
            let operation = runtimeCommandGatewayState.operations.removeValue(
                forKey: operationID
            )
        else {
            preconditionFailure(
                "A Runtime command completed without its Core operation owner."
            )
        }
        guard var graph = runtimeCommandGatewayState.graphs[
            operation.graphToken.rawValue
        ], graph.token == operation.graphToken else {
            preconditionFailure(
                "A Runtime command outlived its graph registry entry."
            )
        }
        precondition(
            graph.operationIDs.remove(operationID) != nil,
            "A Runtime command graph lost operation membership."
        )
        runtimeCommandGatewayState.graphs[graph.token.rawValue] = graph
        guard !operation.isRetired else {
            compactRuntimeObjectGraphIfQuiescent(graph.token)
            return
        }

        do {
            try validateRuntimeCommandCompletion(
                operation.route,
                graph: graph
            )
            switch result {
            case let .failure(error):
                precondition(
                    operation.completion.fulfill(.failure(error)),
                    "A Runtime command completed twice."
                )
            case let .success(wireResult):
                let materialized = try materializeRuntimeResult(
                    wireResult,
                    graphToken: graph.token
                )
                precondition(
                    operation.completion.fulfill(.success(materialized)),
                    "A Runtime command completed twice."
                )
            }
        } catch let error as WebInspectorRuntimeCommandGatewayError {
            retireRuntimeObjectGraph(
                operation.graphToken,
                with: error
            )
            precondition(
                operation.completion.fulfill(.failure(error)),
                "A stale Runtime command completed twice."
            )
        } catch {
            preconditionFailure(
                "Runtime command completion escaped its declared error contract: \(error)"
            )
        }
    }

    func validateRuntimeCommandCompletion(
        _ route: WebInspectorRuntimeCommandRoute,
        graph: WebInspectorRuntimeCommandGatewayState.Graph
    ) throws {
        switch graph.lifecycle {
        case .open, .closing:
            break
        case let .terminal(error):
            throw error ?? WebInspectorRuntimeCommandGatewayError.graphClosed
        }
        let environment = try runtimeCommandEnvironment()
        let currentAuthority = try runtimeCommandAuthority(
            for: graph.owner,
            environment: environment
        )
        guard graph.authority.hasSameAuthority(as: currentAuthority),
            graph.authority.hasSameAuthority(as: route.authority),
            route.graphToken == graph.token
        else {
            throw WebInspectorRuntimeCommandGatewayError.staleAuthority
        }
    }

    func materializeRuntimeResult(
        _ result: WebInspectorRuntimeWireResult,
        graphToken: WebInspectorRuntimeObjectGraphToken
    ) throws -> WebInspectorRuntimeCommandGatewayResult {
        guard var graph = runtimeCommandGatewayState.graphs[graphToken.rawValue],
            graph.token == graphToken
        else {
            throw WebInspectorRuntimeCommandGatewayError.graphNotFound
        }
        let materialized: WebInspectorRuntimeCommandGatewayResult
        switch result {
        case let .evaluation(evaluation):
            materialized = .evaluation(
                WebInspectorRuntimeEvaluationResource(
                    object: registerRuntimeObject(
                        CanonicalRuntimeRemoteObjectPayload(evaluation.object),
                        in: &graph
                    ),
                    wasThrown: evaluation.wasThrown,
                    savedResultIndex: evaluation.savedResultIndex
                )
            )
        case let .properties(properties):
            materialized = .properties(
                properties.map { property in
                    WebInspectorRuntimePropertyResource(
                        name: property.name,
                        value: property.value.map {
                            registerRuntimeObject(
                                CanonicalRuntimeRemoteObjectPayload($0),
                                in: &graph
                            )
                        },
                        writable: property.writable,
                        get: property.get.map {
                            registerRuntimeObject(
                                CanonicalRuntimeRemoteObjectPayload($0),
                                in: &graph
                            )
                        },
                        set: property.set.map {
                            registerRuntimeObject(
                                CanonicalRuntimeRemoteObjectPayload($0),
                                in: &graph
                            )
                        },
                        wasThrown: property.wasThrown,
                        configurable: property.configurable,
                        enumerable: property.enumerable,
                        isOwn: property.isOwn,
                        symbol: property.symbol.map {
                            registerRuntimeObject(
                                CanonicalRuntimeRemoteObjectPayload($0),
                                in: &graph
                            )
                        },
                        isPrivate: property.isPrivate,
                        nativeGetter: property.nativeGetter
                    )
                }
            )
        case let .preview(preview):
            materialized = .preview(CanonicalRuntimeObjectPreview(preview))
        case let .collectionEntries(entries):
            materialized = .collectionEntries(
                entries.map { entry in
                    WebInspectorRuntimeCollectionEntryResource(
                        key: entry.key.map {
                            registerRuntimeObject(
                                CanonicalRuntimeRemoteObjectPayload($0),
                                in: &graph
                            )
                        },
                        value: registerRuntimeObject(
                            CanonicalRuntimeRemoteObjectPayload(entry.value),
                            in: &graph
                        )
                    )
                }
            )
        }
        runtimeCommandGatewayState.graphs[graphToken.rawValue] = graph
        return materialized
    }

    func claimRuntimeObjectGraphClose(
        _ token: WebInspectorRuntimeObjectGraphToken
    ) throws -> WebInspectorRuntimeGraphCloseClaim {
        guard token.storeID == storeID else {
            throw WebInspectorRuntimeCommandGatewayError.foreignStore
        }
        guard var graph = runtimeCommandGatewayState.graphs[token.rawValue],
            graph.token == token
        else {
            if let terminal = runtimeCommandGatewayState.terminalGraphs[
                token.rawValue
            ], terminal.token == token {
                if let closeResult = terminal.closeResult {
                    let completion = ReplyPromise<Void>()
                    completion.fulfill(
                        closeResult.mapError { $0 as any Error }
                    )
                    return WebInspectorRuntimeGraphCloseClaim(
                        completion: completion
                    )
                }
                throw terminal.error
                    ?? WebInspectorRuntimeCommandGatewayError.graphClosed
            }
            throw WebInspectorRuntimeCommandGatewayError.graphNotFound
        }
        if let closeCompletion = graph.closeCompletion {
            return WebInspectorRuntimeGraphCloseClaim(
                completion: closeCompletion
            )
        }
        switch graph.lifecycle {
        case .open:
            break
        case .closing:
            preconditionFailure(
                "A closing Runtime graph must retain its close completion."
            )
        case let .terminal(error):
            throw error ?? WebInspectorRuntimeCommandGatewayError.graphClosed
        }

        let completion = ReplyPromise<Void>()
        graph.lifecycle = .closing
        graph.closeCompletion = completion
        let tasks = graph.operationIDs.sorted().map { operationID in
            guard let operation = runtimeCommandGatewayState.operations[operationID]
            else {
                preconditionFailure(
                    "A Runtime graph close lost an admitted operation."
                )
            }
            return operation.task
        }
        let closeTask = Task.detached(priority: .userInitiated) { [weak self] in
            for task in tasks {
                await task.value
            }
            guard let self else {
                completion.fulfill(
                    .failure(WebInspectorRuntimeCommandGatewayError.closed)
                )
                return
            }
            await self.releaseRuntimeObjectGraphAfterDrain(token)
        }
        graph.closeTask = closeTask
        runtimeCommandGatewayState.graphs[token.rawValue] = graph
        return WebInspectorRuntimeGraphCloseClaim(
            completion: completion
        )
    }

    func releaseRuntimeObjectGraphAfterDrain(
        _ token: WebInspectorRuntimeObjectGraphToken
    ) async {
        guard let graph = runtimeCommandGatewayState.graphs[token.rawValue],
            graph.token == token
        else {
            preconditionFailure(
                "A Runtime graph close outlived its registry entry."
            )
        }
        guard case .closing = graph.lifecycle else {
            finishRetiredRuntimeGraphCloseTask(token)
            return
        }
        precondition(
            graph.operationIDs.isEmpty,
            "A Runtime graph release started before admitted operations drained."
        )
        do {
            let environment = try runtimeCommandEnvironment()
            let currentAuthority = try runtimeCommandAuthority(
                for: graph.owner,
                environment: environment
            )
            guard graph.authority.hasSameAuthority(as: currentAuthority) else {
                throw WebInspectorRuntimeCommandGatewayError.staleAuthority
            }
            switch graph.owner {
            case .consoleParameter:
                finishRuntimeObjectGraphClose(token, result: .success(()))
            case let .independent(wireGroup, _):
                runtimeCommandGatewayState.wireGroupReleaseCount += 1
                let result = await Self.performRuntimeObjectGroupRelease(
                    authority: graph.authority,
                    wireGroup: wireGroup
                )
                finishRuntimeObjectGraphClose(token, result: result)
            }
        } catch let error as WebInspectorRuntimeCommandGatewayError {
            finishRuntimeObjectGraphClose(token, result: .failure(error))
        } catch {
            preconditionFailure(
                "Runtime graph release escaped its declared error contract: \(error)"
            )
        }
    }

    nonisolated static func performRuntimeObjectGroupRelease(
        authority: WebInspectorRuntimeCommandGatewayState.Authority,
        wireGroup: Runtime.ObjectGroup
    ) async -> Result<Void, WebInspectorRuntimeCommandGatewayError> {
        let target = authority.proxy.modelTarget(
            authority.agentTarget,
            authorization: authority.authorization
        )
        do {
            try await target.runtime.releaseObjectGroup(wireGroup)
            return .success(())
        } catch let error as WebInspectorProxyError {
            return .failure(.proxy(error))
        } catch let error as ConnectionModelCommandError {
            return .failure(.authorization(error))
        } catch is CancellationError {
            return .failure(.staleAuthority)
        } catch {
            return .failure(.invalidReply(String(reflecting: error)))
        }
    }

    func finishRuntimeObjectGraphClose(
        _ token: WebInspectorRuntimeObjectGraphToken,
        result: Result<Void, WebInspectorRuntimeCommandGatewayError>
    ) {
        guard var graph = runtimeCommandGatewayState.graphs[token.rawValue],
            graph.token == token,
            let completion = graph.closeCompletion
        else {
            preconditionFailure(
                "A Runtime graph close completed without its owner state."
            )
        }
        guard case .closing = graph.lifecycle else {
            graph.closeTask = nil
            runtimeCommandGatewayState.graphs[token.rawValue] = graph
            return
        }
        graph.lifecycle = .terminal(result.failure)
        graph.objectsByOrdinal.removeAll(keepingCapacity: false)
        graph.ordinalByRawID.removeAll(keepingCapacity: false)
        graph.closeTask = nil
        runtimeCommandGatewayState.graphs[token.rawValue] = graph
        precondition(
            completion.fulfill(result.mapError { $0 as any Error }),
            "A Runtime graph close completed twice."
        )
        compactRuntimeObjectGraphIfQuiescent(token)
    }

    func finishRetiredRuntimeGraphCloseTask(
        _ token: WebInspectorRuntimeObjectGraphToken
    ) {
        guard var graph = runtimeCommandGatewayState.graphs[token.rawValue],
            graph.token == token
        else {
            preconditionFailure(
                "A retired Runtime close task lost its graph."
            )
        }
        graph.closeTask = nil
        runtimeCommandGatewayState.graphs[token.rawValue] = graph
        compactRuntimeObjectGraphIfQuiescent(token)
    }

    func retireRuntimeObjectGraph(
        _ token: WebInspectorRuntimeObjectGraphToken,
        with error: WebInspectorRuntimeCommandGatewayError
    ) {
        guard var graph = runtimeCommandGatewayState.graphs[token.rawValue],
            graph.token == token
        else {
            return
        }
        if case .terminal = graph.lifecycle {
            return
        }
        for operationID in graph.operationIDs.sorted() {
            guard var operation = runtimeCommandGatewayState.operations[operationID]
            else {
                preconditionFailure(
                    "A Runtime graph invalidation lost an operation."
                )
            }
            guard !operation.isRetired else {
                continue
            }
            operation.isRetired = true
            runtimeCommandGatewayState.operations[operationID] = operation
            precondition(
                operation.completion.fulfill(.failure(error)),
                "A Runtime command was invalidated twice."
            )
            operation.task.cancel()
        }
        graph.lifecycle = .terminal(error)
        graph.objectsByOrdinal.removeAll(keepingCapacity: false)
        graph.ordinalByRawID.removeAll(keepingCapacity: false)
        if let completion = graph.closeCompletion {
            completion.fulfill(.failure(error))
        }
        graph.closeTask?.cancel()
        runtimeCommandGatewayState.graphs[token.rawValue] = graph
        runtimeCommandGatewayState.invalidatedGraphCount += 1
        compactRuntimeObjectGraphIfQuiescent(token)
    }

    func compactRuntimeObjectGraphIfQuiescent(
        _ token: WebInspectorRuntimeObjectGraphToken
    ) {
        guard let graph = runtimeCommandGatewayState.graphs[token.rawValue],
            graph.token == token,
            case let .terminal(error) = graph.lifecycle,
            graph.operationIDs.isEmpty,
            graph.closeTask == nil
        else {
            return
        }
        let closeResult: Result<
            Void,
            WebInspectorRuntimeCommandGatewayError
        >? = if graph.closeCompletion != nil {
            if let error {
                .failure(error)
            } else {
                .success(())
            }
        } else {
            nil
        }
        precondition(
            runtimeCommandGatewayState.terminalGraphs[token.rawValue] == nil,
            "Runtime graph was compacted twice."
        )
        runtimeCommandGatewayState.terminalGraphs[token.rawValue] =
            WebInspectorRuntimeCommandGatewayState.TerminalGraph(
                token: token,
                error: error,
                closeResult: closeResult
            )
        runtimeCommandGatewayState.graphs[token.rawValue] = nil
    }
}

package extension WebInspectorModelContainerCore {
    func applyRuntimeCommandInvalidations(
        from transaction: WebInspectorCanonicalModelTransaction
    ) {
        guard let consoleRuntime = transaction.consoleRuntime else {
            return
        }
        var deletedMessages: Set<CanonicalConsoleMessageIDStorage> = []
        var deletedContexts: Set<CanonicalRuntimeContextIDStorage> = []
        for change in consoleRuntime.consoleMessageChanges {
            if case let .delete(id) = change {
                deletedMessages.insert(id)
            }
        }
        for change in consoleRuntime.runtimeContextChanges {
            if case let .delete(id) = change {
                deletedContexts.insert(id)
            }
        }

        let tokens = runtimeCommandGatewayState.graphs.values.compactMap {
            graph -> WebInspectorRuntimeObjectGraphToken? in
            if case .terminal = graph.lifecycle {
                return nil
            }
            switch graph.owner {
            case let .consoleParameter(messageID, _, _):
                if deletedMessages.contains(messageID) {
                    return graph.token
                }
            case let .independent(_, boundContextID):
                if let boundContextID,
                    deletedContexts.contains(boundContextID)
                {
                    return graph.token
                }
            }
            for invalidation in consoleRuntime.resourceInvalidations {
                switch invalidation {
                case let .runtimeBinding(agentTargetID, _):
                    if graph.authority.agentTarget.id == agentTargetID {
                        return graph.token
                    }
                case let .consoleBinding(agentTargetID, _):
                    if case .consoleParameter = graph.owner,
                        graph.authority.agentTarget.id == agentTargetID
                    {
                        return graph.token
                    }
                case let .semanticNavigation(semanticTargetID, _):
                    if graph.authority.semanticTarget.id == semanticTargetID {
                        return graph.token
                    }
                case .frameDetached:
                    // WebKit discards the detached frame's InjectedScript,
                    // but Console parameter payloads do not carry frame
                    // identity. Console graphs must therefore retire
                    // conservatively at this boundary.
                    if case .consoleParameter = graph.owner {
                        return graph.token
                    }
                case let .targetLost(targetID):
                    if graph.authority.semanticTarget.id == targetID
                        || graph.authority.agentTarget.id == targetID
                    {
                        return graph.token
                    }
                case .attachmentDetached, .attachmentReset:
                    return graph.token
                }
            }
            return nil
        }
        for token in tokens.sorted(by: { $0.rawValue < $1.rawValue }) {
            retireRuntimeObjectGraph(token, with: .staleAuthority)
        }
    }

    func invalidateAllRuntimeCommandResources(
        with error: WebInspectorRuntimeCommandGatewayError
    ) {
        let tokens = runtimeCommandGatewayState.graphs.values
            .map(\.token)
            .sorted { $0.rawValue < $1.rawValue }
        for token in tokens {
            retireRuntimeObjectGraph(token, with: error)
        }
    }

    func waitForRuntimeCommandOperationsToFinish() async {
        let operationTasks = runtimeCommandGatewayState.operations.values
            .map(\.task)
        let closeTasks = runtimeCommandGatewayState.graphs.values
            .compactMap(\.closeTask)
        for task in operationTasks {
            await task.value
        }
        for task in closeTasks {
            await task.value
        }
        precondition(
            runtimeCommandGatewayState.operations.isEmpty,
            "Model Container lifecycle completed before Runtime commands quiesced."
        )
        precondition(
            runtimeCommandGatewayState.graphs.values.allSatisfy {
                $0.closeTask == nil
            },
            "Model Container lifecycle retained a Runtime graph close task."
        )
    }

    func releaseRuntimeCommandStorageForClose() {
        precondition(
            runtimeCommandGatewayState.operations.isEmpty,
            "Runtime command storage was released with active operations."
        )
        precondition(
            runtimeCommandGatewayState.graphs.values.allSatisfy {
                $0.closeTask == nil
            },
            "Runtime command storage was released with active close tasks."
        )
        runtimeCommandGatewayState = WebInspectorRuntimeCommandGatewayState()
    }

    func discardRuntimeCommandTombstonesAfterDetach() {
        precondition(
            runtimeCommandGatewayState.operations.isEmpty
                && runtimeCommandGatewayState.graphs.isEmpty,
            "Runtime graph tombstones were discarded before detach quiesced."
        )
        runtimeCommandGatewayState.terminalGraphs.removeAll(
            keepingCapacity: false
        )
    }
}

private extension Result where Success == Void,
    Failure == WebInspectorRuntimeCommandGatewayError
{
    var failure: WebInspectorRuntimeCommandGatewayError? {
        if case let .failure(error) = self {
            error
        } else {
            nil
        }
    }
}
