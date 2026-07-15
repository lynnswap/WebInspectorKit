import Foundation
import WebInspectorProxyKit

package enum WebInspectorConsoleRuntimeWireEvent: Sendable {
    case console(WebInspectorRoutedEvent<Console.Event>)
    case runtime(WebInspectorRoutedEvent<Runtime.Event>)
    case page(WebInspectorRoutedEvent<Page.Event>)
    case target(WebInspectorRoutedEvent<WebInspectorConsoleRuntimeTargetEvent>)
}

package enum WebInspectorConsoleRuntimeTargetEvent: Sendable {
    case targetDestroyed(WebInspectorTarget.ID)
    case unknown
}

private struct WebInspectorConsoleRuntimeTargetDestroyedPayload: Decodable {
    let targetID: String

    private enum CodingKeys: String, CodingKey {
        case targetID = "targetId"
    }
}

private let webInspectorConsoleRuntimeTargetEventDecoder = WebInspectorEventDecoder<
    WebInspectorConsoleRuntimeTargetEvent
>(domain: WebInspectorProtocolDomainToken(rawValue: "Target")) { envelope in
    guard envelope.method.rawValue == "Target.targetDestroyed" else {
        return .unknown
    }
    let payload = try WebInspectorWireJSON.decode(
        WebInspectorConsoleRuntimeTargetDestroyedPayload.self,
        from: envelope.parameters
    )
    return .targetDestroyed(WebInspectorTarget.ID(payload.targetID))
}

private struct WebInspectorConsoleRuntimeRecoveryRequest: Error, Sendable {
    let reason: WebInspectorRecoveryReason
    let fingerprint: WebInspectorRecoveryFingerprint
}

/// Sole semantic owner of Console messages, Runtime contexts, and remote
/// object scope lifetimes.
package actor WebInspectorConsoleRuntimeFeature: WebInspectorModelFeature {
    package static let id = WebInspectorFeatureID.consoleRuntime

    private struct FrameNavigationKey: Hashable, Sendable {
        let agentTargetID: WebInspectorTarget.ID
        let frameID: FrameID
    }

    private struct FrameNavigationIdentity: Equatable, Sendable {
        let loaderID: String
    }

    private struct FrameAuthority: Equatable, Sendable {
        let frameID: FrameID
        let navigationIdentity: FrameNavigationIdentity?
    }

    private struct RuntimeObjectAuthority: Equatable, Sendable {
        let attachmentGeneration: WebInspectorAttachmentGeneration
        let pageGeneration: WebInspectorPageGeneration
        let semanticTargetID: WebInspectorTarget.ID
        let agentTargetID: WebInspectorTarget.ID
        let navigationEpoch: WebInspectorNavigationEpoch
        let runtimeBindingEpoch: WebInspectorRuntimeBindingGeneration
        let consoleBindingEpoch: WebInspectorConsoleBindingGeneration?
        let frame: FrameAuthority?
        let sourceContextID: CanonicalRuntimeContextIDStorage?
    }

    private struct RuntimeHandle: Sendable {
        let rawID: Runtime.RemoteObject.ID
        let authority: RuntimeObjectAuthority
        let objectGroup: Runtime.ObjectGroup
    }

    private struct ObjectScopeState: Sendable {
        let group: Runtime.ObjectGroup
        var nextOrdinal: UInt64 = 0
        var handles: [RuntimeObject.ID: RuntimeHandle] = [:]
    }

    private struct FrameTargetBinding: Equatable, Sendable {
        let frameID: FrameID?
        let navigationIdentity: FrameNavigationIdentity?
    }

    private let registry: WebInspectorFeatureRegistry
    private var connection: WebInspectorFeatureConnection?
    private var storeSink: WebInspectorModelStoreSink?
    private var orderedScope: WebInspectorOrderedEventScope<WebInspectorConsoleRuntimeWireEvent>?
    private var canonicalStore: CanonicalConsoleRuntimeStore?
    private var state: WebInspectorFeatureState = .disabled
    private var recoveryBudget = WebInspectorFeatureRecoveryBudget()
    private var closeRequested = false
    private var explicitRetryRequested = false
    private var retryWaiter: CheckedContinuation<Void, Never>?
    private var runtimeBindingEpochs: [WebInspectorTarget.ID: UInt64] = [:]
    private var consoleBindingEpochs: [WebInspectorTarget.ID: UInt64] = [:]
    private var navigationEpochs: [WebInspectorTarget.ID: WebInspectorNavigationEpoch] = [:]
    private var frameNavigationIdentities: [FrameNavigationKey: FrameNavigationIdentity] = [:]
    private var latestFrameNavigationIdentities: [FrameID: FrameNavigationIdentity] = [:]
    private var frameTargetBindings: [WebInspectorTarget.ID: FrameTargetBinding] = [:]
    private var currentPageRuntimeRoute: WebInspectorFeatureEventScope?
    private var currentPageMainFrameID: FrameID?
    private var objectScopes: [UUID: ObjectScopeState] = [:]

    package init(registry: WebInspectorFeatureRegistry) {
        self.registry = registry
    }

    package func run(
        connection: WebInspectorFeatureConnection,
        store: WebInspectorModelStoreSink
    ) async -> WebInspectorFeatureTermination {
        self.connection = connection
        storeSink = store
        closeRequested = false
        explicitRetryRequested = false
        recoveryBudget = WebInspectorFeatureRecoveryBudget()
        canonicalStore = CanonicalConsoleRuntimeStore(storeID: connection.storeID)
        objectScopes.removeAll(keepingCapacity: true)
        runtimeBindingEpochs.removeAll(keepingCapacity: true)
        consoleBindingEpochs.removeAll(keepingCapacity: true)
        navigationEpochs.removeAll(keepingCapacity: true)
        frameNavigationIdentities.removeAll(keepingCapacity: true)
        latestFrameNavigationIdentities.removeAll(keepingCapacity: true)
        frameTargetBindings.removeAll(keepingCapacity: true)
        currentPageRuntimeRoute = nil
        currentPageMainFrameID = nil
        await publish(.synchronizing(generation: await currentGeneration()))

        while !closeRequested {
            do {
                try await runOrderedScope()
                return closeRequested
                    ? .detached
                    : .connectionFailed(
                        connectionFailure(
                            code: "console-runtime.scope.ended",
                            phase: "events",
                            message: "The Console/Runtime event scope ended unexpectedly."
                        )
                    )
            } catch is CancellationError {
                return .detached
            } catch let request as WebInspectorConsoleRuntimeRecoveryRequest {
                await orderedScope?.close()
                orderedScope = nil
                await releaseAllObjectScopes()
                let generation = await currentGeneration()
                switch recoveryBudget.consume(request.fingerprint, generation: generation) {
                case .retry:
                    await publish(.recovering(generation: generation, reason: request.reason))
                case .repeatedFingerprint, .generationBudgetExhausted:
                    await publish(
                        .unavailable(
                            generation: generation,
                            error: .recoveryBudgetExhausted(
                                WebInspectorFailureDescription(
                                    code: "console-runtime.recovery.exhausted",
                                    phase: request.fingerprint.phase,
                                    message: String(describing: request.reason)
                                )
                            )
                        )
                    )
                    await waitForExplicitRetry()
                    recoveryBudget.begin(
                        generation: await currentGeneration(),
                        explicitRetry: true
                    )
                }
            } catch {
                await orderedScope?.close()
                orderedScope = nil
                await releaseAllObjectScopes()
                if isConnectionTerminal(error) { return termination(for: error) }
                let generation = await currentGeneration()
                await publish(
                    .unavailable(
                        generation: generation,
                        error: .bootstrap(
                            webInspectorFailureDescription(
                                error,
                                code: "console-runtime.bootstrap.failed",
                                phase: "bootstrap"
                            )
                        )
                    )
                )
                await waitForExplicitRetry()
                recoveryBudget.begin(
                    generation: await currentGeneration(),
                    explicitRetry: true
                )
            }
        }
        return .detached
    }

    package func retry() async {
        guard case .unavailable = state else { return }
        explicitRetryRequested = true
        retryWaiter?.resume()
        retryWaiter = nil
    }

    package func close() async {
        guard !closeRequested else { return }
        closeRequested = true
        explicitRetryRequested = true
        retryWaiter?.resume()
        retryWaiter = nil
        await orderedScope?.close()
        orderedScope = nil
        await releaseAllObjectScopes()
        if var canonicalStore,
            canonicalStore.attachmentGeneration != nil,
            let storeSink
        {
            let canonical = canonicalStore.clearForDetach()
            var transaction = WebInspectorModelTransaction()
            append(canonical, staged: canonicalStore, to: &transaction)
            transaction.setFeatureState(.disabled, for: .consoleRuntime)
            _ = try? await storeSink.commit(transaction)
            self.canonicalStore = canonicalStore
        }
        connection = nil
        self.storeSink = nil
        transition(to: .disabled)
    }

    package func clearConsole() async throws {
        guard let connection else { throw WebInspectorCommandError.containerClosed }
        do { try await connection.page.console.clearMessages() } catch {
            throw webInspectorCommandError(
                error,
                featureID: .consoleRuntime,
                phase: "Console.clearMessages"
            )
        }
    }

    package func setLoggingChannelLevel(
        _ source: Console.ChannelSource,
        level: Console.ChannelLevel
    ) async throws {
        guard let connection else { throw WebInspectorCommandError.containerClosed }
        do {
            try await connection.page.console.setLoggingChannelLevel(source, level: level)
        } catch {
            throw webInspectorCommandError(
                error,
                featureID: .consoleRuntime,
                phase: "Console.setLoggingChannelLevel"
            )
        }
    }

    package func makeObjectScope() -> WebInspectorRuntimeObjectScope {
        let id = UUID()
        objectScopes[id] = ObjectScopeState(
            group: .other("WebInspectorDataKit.\(id.uuidString)")
        )
        return WebInspectorRuntimeObjectScope(id: id, owner: self)
    }

    package func evaluate(
        _ expression: String,
        in contextID: RuntimeContext.ID?,
        scopeID: UUID
    ) async throws -> RuntimeEvaluation {
        guard let connection, let group = objectScopes[scopeID]?.group else {
            throw WebInspectorCommandError.staleIdentifier
        }
        let (rawContext, authority) = try evaluationAuthority(for: contextID)
        try requireCurrent(authority, in: scopeID)
        let result: Runtime.EvaluationResult
        do {
            result = try await connection.page.runtime.evaluate(
                expression,
                in: rawContext,
                objectGroup: group
            )
        } catch {
            try requireCurrent(authority, in: scopeID)
            throw webInspectorCommandError(
                error,
                featureID: .consoleRuntime,
                phase: "Runtime.evaluate"
            )
        }
        try await requireCurrentAfterCommand(
            authority,
            in: scopeID,
            returned: [result.object],
            using: connection
        )
        let object = try retain(
            result.object,
            in: scopeID,
            authority: authority,
            objectGroup: group
        )
        return RuntimeEvaluation(object: object, isException: result.wasThrown)
    }

    package func properties(
        of object: RuntimeObject,
        in scopeID: UUID
    ) async throws -> [RuntimeObject.Property] {
        guard let connection else { throw WebInspectorCommandError.containerClosed }
        let source = try runtimeHandle(for: object, scopeID: scopeID)
        try requireCurrent(source.authority, in: scopeID)
        let properties: [Runtime.PropertyDescriptor]
        do {
            properties = try await connection.page.runtime.properties(
                of: source.rawID
            )
        } catch {
            try requireCurrent(source.authority, in: scopeID)
            throw webInspectorCommandError(
                error,
                featureID: .consoleRuntime,
                phase: "Runtime.getProperties"
            )
        }
        try await requireCurrentAfterCommand(
            source.authority,
            in: scopeID,
            returned: properties.flatMap(Self.remoteObjects),
            using: connection
        )
        return try properties.map { property in
            RuntimeObject.Property(
                name: property.name,
                value: property.value?.description,
                object: try property.value.map {
                    try retain(
                        $0,
                        in: scopeID,
                        authority: source.authority,
                        objectGroup: source.objectGroup
                    )
                }
            )
        }
    }

    package func preview(
        of object: RuntimeObject,
        in scopeID: UUID
    ) async throws -> Runtime.ObjectPreview {
        guard let connection else { throw WebInspectorCommandError.containerClosed }
        let source = try runtimeHandle(for: object, scopeID: scopeID)
        try requireCurrent(source.authority, in: scopeID)
        let preview: Runtime.ObjectPreview
        do {
            preview = try await connection.page.runtime.preview(of: source.rawID)
        } catch {
            try requireCurrent(source.authority, in: scopeID)
            throw webInspectorCommandError(
                error,
                featureID: .consoleRuntime,
                phase: "Runtime.getPreview"
            )
        }
        try requireCurrent(source.authority, in: scopeID)
        return preview
    }

    package func entries(
        of object: RuntimeObject,
        in scopeID: UUID
    ) async throws -> [RuntimeObject.Entry] {
        guard let connection else { throw WebInspectorCommandError.containerClosed }
        let source = try runtimeHandle(for: object, scopeID: scopeID)
        try requireCurrent(source.authority, in: scopeID)
        let entries: [Runtime.CollectionEntry]
        do {
            entries = try await connection.page.runtime.collectionEntries(
                of: source.rawID
            )
        } catch {
            try requireCurrent(source.authority, in: scopeID)
            throw webInspectorCommandError(
                error,
                featureID: .consoleRuntime,
                phase: "Runtime.getCollectionEntries"
            )
        }
        try await requireCurrentAfterCommand(
            source.authority,
            in: scopeID,
            returned: entries.flatMap(Self.remoteObjects),
            using: connection
        )
        return try entries.map { entry in
            RuntimeObject.Entry(
                key: try entry.key.map {
                    try retain(
                        $0,
                        in: scopeID,
                        authority: source.authority,
                        objectGroup: source.objectGroup
                    )
                },
                value: try retain(
                    entry.value,
                    in: scopeID,
                    authority: source.authority,
                    objectGroup: source.objectGroup
                )
            )
        }
    }

    package func closeObjectScope(_ id: UUID) async {
        guard let scope = objectScopes.removeValue(forKey: id), let connection else { return }
        await releaseRemoteObjects(in: scope, using: connection)
    }

    private func runOrderedScope() async throws {
        guard let connection, let storeSink else { throw CancellationError() }
        let descriptor = WebInspectorOrderedScopeDescriptor<WebInspectorConsoleRuntimeWireEvent>(
            decoders: [
                ConsoleWireCoding.eventDecoder.routed().map(WebInspectorConsoleRuntimeWireEvent.console),
                RuntimeWireCoding.eventDecoder.routed().map(WebInspectorConsoleRuntimeWireEvent.runtime),
                PageWireCoding.eventDecoder.routed().map(WebInspectorConsoleRuntimeWireEvent.page),
                webInspectorConsoleRuntimeTargetEventDecoder.routed().map(
                    WebInspectorConsoleRuntimeWireEvent.target
                ),
            ],
            capabilities: [
                ConsoleWireCoding.capability,
                RuntimeWireCoding.capability,
                PageWireCoding.capability,
            ]
        )
        let scope = try await connection.page.orderedScope(
            descriptor: descriptor,
            buffering: .bounded(2_048)
        )
        orderedScope = scope
        try await bootstrapCurrentTarget(in: scope, storeSink: storeSink)

        for try await event in scope.events {
            if closeRequested { return }
            if case let .reset(generation) = event {
                await releaseAllObjectScopes()
                await publish(
                    .synchronizing(
                        generation: WebInspectorPageGeneration(
                            rawValue: generation.rawValue
                        )
                    )
                )
                try await bootstrapCurrentTarget(in: scope, storeSink: storeSink)
                continue
            }
            guard var staged = canonicalStore else { continue }
            do {
                let canonical = try reduce(event, staged: &staged)
                canonicalStore = staged
                let invalidatedObjectIDs = invalidateObjectHandles(
                    for: canonical?.resourceInvalidations ?? []
                )
                await releaseRemoteObjectIDs(invalidatedObjectIDs)
                if let canonical {
                    try await commit(canonical, staged: staged)
                }
            } catch let error as CanonicalConsoleRuntimeProtocolViolation {
                throw recovery(
                    code: "console-runtime.protocol.\(String(describing: error))",
                    phase: "events",
                    reason: .malformedDomainEvent(
                        webInspectorFailureDescription(
                            error,
                            code: "console-runtime.protocol",
                            phase: "events"
                        )
                    )
                )
            }
        }
    }

    private func bootstrapCurrentTarget(
        in scope: WebInspectorOrderedEventScope<WebInspectorConsoleRuntimeWireEvent>,
        storeSink: WebInspectorModelStoreSink
    ) async throws {
        guard let connection else { throw CancellationError() }
        while !closeRequested {
            let reply = try await scope.command(PageWireCoding.resourceTree())
            let prefix = try await scope.drain(through: reply.boundary)
            if closeRequested { throw CancellationError() }
            if prefix.contains(where: invalidatesBootstrap) {
                await releaseAllObjectScopes()
                await publish(.synchronizing(generation: await currentGeneration()))
                continue
            }

            let route = try featureScope(from: reply)
            runtimeBindingEpochs.removeAll(keepingCapacity: true)
            consoleBindingEpochs.removeAll(keepingCapacity: true)
            navigationEpochs = [
                route.semanticTargetID: WebInspectorNavigationEpoch(rawValue: 0)
            ]
            frameNavigationIdentities.removeAll(keepingCapacity: true)
            latestFrameNavigationIdentities.removeAll(keepingCapacity: true)
            frameTargetBindings.removeAll(keepingCapacity: true)
            currentPageRuntimeRoute = route
            currentPageMainFrameID = reply.value.frame.id
            var staged = CanonicalConsoleRuntimeStore(storeID: connection.storeID)
            _ = try staged.reset(
                attachmentGeneration: connection.attachmentGeneration,
                pageGeneration: route.generation
            )
            var invalidatedObjectIDs: Set<Runtime.RemoteObject.ID> = []
            for event in prefix {
                if let canonical = try reduce(event, staged: &staged) {
                    invalidatedObjectIDs.formUnion(
                        invalidateObjectHandles(
                            for: canonical.resourceInvalidations
                        )
                    )
                }
            }
            installFrameNavigationIdentities(
                from: reply.value,
                agentTargetID: route.agentTargetID
            )
            reconcileFrameTargetBindings()
            await releaseRemoteObjectIDs(invalidatedObjectIDs)
            let previous = canonicalStore?.snapshot()
            let current = staged.snapshot()
            var transaction = WebInspectorModelTransaction()
            appendReplacement(
                previous: previous,
                current: current,
                to: &transaction
            )
            transaction.setFeatureState(
                .ready(
                    generation: route.generation,
                    revision: WebInspectorStoreRevision(rawValue: 0)
                ),
                for: .consoleRuntime
            )
            canonicalStore = staged
            let revision = try await storeSink.commit(transaction)
            transition(
                to: .ready(generation: route.generation, revision: revision)
            )
            return
        }
        throw CancellationError()
    }

    private func reduce(
        _ event: WebInspectorPageEvent<WebInspectorConsoleRuntimeWireEvent>,
        staged: inout CanonicalConsoleRuntimeStore
    ) throws -> CanonicalConsoleRuntimeTransaction? {
        guard case let .event(_, value) = event else { return nil }
        let transaction: CanonicalConsoleRuntimeTransaction?
        switch value {
        case let .runtime(routed):
            let route = try featureScope(from: routed)
            transaction = try reduceRuntime(
                routed.value,
                route: route,
                staged: &staged
            )
        case let .console(routed):
            let route = try featureScope(from: routed)
            if case .messagesCleared = routed.value {
                advanceConsoleBindingEpoch(for: route.agentTargetID)
            }
            transaction = try staged.reduceConsole(
                routed.value,
                scope: makeScope(route)
            )
        case let .page(routed):
            switch routed.value {
            case let .frameDetached(frameID):
                removeFrameNavigationAuthority(for: frameID)
                transaction = staged.frameWasDetached(frameID)
            case let .frameNavigated(frame):
                transaction = try frameWasNavigated(
                    frame,
                    route: try featureScope(from: routed),
                    staged: &staged
                )
            case .unknown:
                transaction = nil
            }
        case let .target(routed):
            switch routed.value {
            case let .targetDestroyed(targetID):
                advanceRuntimeBindingEpoch(for: targetID)
                advanceConsoleBindingEpoch(for: targetID)
                advanceNavigationEpoch(for: targetID)
                frameNavigationIdentities = frameNavigationIdentities.filter {
                    $0.key.agentTargetID != targetID
                }
                frameTargetBindings[targetID] = nil
                transaction = staged.targetWasLost(targetID)
            case .unknown:
                transaction = nil
            }
        }
        return transaction
    }

    private func reduceRuntime(
        _ event: Runtime.Event,
        route: WebInspectorFeatureEventScope,
        staged: inout CanonicalConsoleRuntimeStore
    ) throws -> CanonicalConsoleRuntimeTransaction? {
        var canonical = CanonicalConsoleRuntimeTransaction()
        switch event {
        case let .executionContextCreated(context):
            if route.agentTarget.kind == .frame,
                context.kind == .normal
            {
                let currentBinding = FrameTargetBinding(
                    frameID: context.frameID,
                    navigationIdentity: context.frameID.flatMap {
                        latestFrameNavigationIdentities[$0]
                    }
                )
                let previousBinding = frameTargetBindings[route.agentTargetID]
                let bindingProvesNavigation =
                    previousBinding.map {
                        $0 != currentBinding
                    } ?? false
                // WebInspectorUI treats a second Normal context as a frame
                // navigation and clears every context that preceded it.
                let storeRequiresReplacement =
                    staged.frameTargetNormalContextRequiresReplacement(
                        context,
                        scope: makeScope(route)
                    )
                if bindingProvesNavigation || storeRequiresReplacement {
                    advanceRuntimeBindingEpoch(for: route.agentTargetID)
                    advanceNavigationEpoch(for: route.semanticTargetID)
                    let scope = makeScope(route)
                    merge(
                        try staged.runtimeBindingDidAdvance(scope: scope),
                        into: &canonical
                    )
                    merge(
                        try staged.semanticTargetNavigated(scope: scope),
                        into: &canonical
                    )
                }
                frameTargetBindings[route.agentTargetID] = currentBinding
            }
        case .executionContextsCleared:
            advanceRuntimeBindingEpoch(for: route.agentTargetID)
        case .executionContextDestroyed, .unknown:
            break
        }
        merge(
            try staged.reduceRuntime(event, scope: makeScope(route)),
            into: &canonical
        )
        return canonical.isEmpty ? nil : canonical
    }

    private func frameWasNavigated(
        _ frame: Page.Frame,
        route: WebInspectorFeatureEventScope,
        staged: inout CanonicalConsoleRuntimeStore
    ) throws -> CanonicalConsoleRuntimeTransaction? {
        let key = FrameNavigationKey(
            agentTargetID: route.agentTargetID,
            frameID: frame.id
        )
        let nextIdentity = FrameNavigationIdentity(loaderID: frame.loaderID)
        let boundIdentity = frameTargetBindings[route.agentTargetID].flatMap {
            $0.frameID == frame.id ? $0.navigationIdentity : nil
        }
        let previousIdentity =
            frameNavigationIdentities[key]
            ?? (route.agentTarget.kind == .frame
                ? boundIdentity
                : nil)
        frameNavigationIdentities[key] = nextIdentity
        latestFrameNavigationIdentities[frame.id] = nextIdentity
        guard previousIdentity != nextIdentity else { return nil }

        let ownsNavigatedFrame: Bool
        switch route.agentTarget.kind {
        case .page:
            ownsNavigatedFrame = frame.parentID == nil
            if ownsNavigatedFrame {
                currentPageMainFrameID = frame.id
            }
        case .frame:
            if let binding = frameTargetBindings[route.agentTargetID],
                let boundFrameID = binding.frameID
            {
                ownsNavigatedFrame = boundFrameID == frame.id
            } else {
                // The first frame event establishes ownership; it is not a
                // navigation cut until Runtime or a prior Page event proves
                // which frame this target owns.
                ownsNavigatedFrame = false
            }
            if ownsNavigatedFrame
                || frameTargetBindings[route.agentTargetID]?.frameID == nil
            {
                frameTargetBindings[route.agentTargetID] = FrameTargetBinding(
                    frameID: frame.id,
                    navigationIdentity: nextIdentity
                )
            }
        case .worker, .other:
            ownsNavigatedFrame = false
        }

        var canonical = CanonicalConsoleRuntimeTransaction()
        if ownsNavigatedFrame {
            advanceRuntimeBindingEpoch(for: route.agentTargetID)
            advanceNavigationEpoch(for: route.semanticTargetID)
            let scope = makeScope(route)
            merge(
                try staged.runtimeBindingDidAdvance(scope: scope),
                into: &canonical
            )
            merge(
                try staged.semanticTargetNavigated(scope: scope),
                into: &canonical
            )
        }
        merge(staged.frameWasNavigated(frame.id), into: &canonical)
        return canonical.isEmpty ? nil : canonical
    }

    private func commit(
        _ canonical: CanonicalConsoleRuntimeTransaction,
        staged: CanonicalConsoleRuntimeStore
    ) async throws {
        guard let storeSink else { throw WebInspectorCommandError.containerClosed }
        var transaction = WebInspectorModelTransaction()
        append(canonical, staged: staged, to: &transaction)
        guard !transaction.isEmpty else { return }
        let revision = try await storeSink.commit(transaction)
        refreshReadyRevision(revision)
    }

    private func append(
        _ canonical: CanonicalConsoleRuntimeTransaction,
        staged: CanonicalConsoleRuntimeStore,
        to transaction: inout WebInspectorModelTransaction
    ) {
        let mutations = webInspectorConsoleRuntimeMutations(canonical, staged: staged)
        transaction.append(contentsOf: mutations.contexts)
        transaction.append(contentsOf: mutations.messages)
    }

    private func appendReplacement(
        previous: CanonicalConsoleRuntimeSnapshot?,
        current: CanonicalConsoleRuntimeSnapshot,
        to transaction: inout WebInspectorModelTransaction
    ) {
        let contextIDs = Set(current.runtimeContexts.map { RuntimeContext.ID(canonical: $0.record.id) })
        let messageIDs = Set(current.consoleMessages.map { ConsoleMessage.ID(canonical: $0.record.id) })
        if let previous {
            transaction.append(
                contentsOf: previous.runtimeContexts.compactMap { entry in
                    let id = RuntimeContext.ID(canonical: entry.record.id)
                    return contextIDs.contains(id) ? nil : webInspectorRuntimeContextSchema.delete(id: id)
                })
            transaction.append(
                contentsOf: previous.consoleMessages.compactMap { entry in
                    let id = ConsoleMessage.ID(canonical: entry.record.id)
                    return messageIDs.contains(id) ? nil : webInspectorConsoleMessageSchema.delete(id: id)
                })
        }
        let mutations = webInspectorConsoleRuntimeSnapshotMutations(current)
        transaction.append(contentsOf: mutations.contexts)
        transaction.append(contentsOf: mutations.messages)
    }

    private func makeScope(
        _ route: WebInspectorFeatureEventScope
    ) -> WebInspectorConsoleRuntimeEventScope {
        WebInspectorConsoleRuntimeEventScope(
            route: route,
            navigationEpoch: navigationEpochs[route.semanticTargetID]
                ?? WebInspectorNavigationEpoch(rawValue: 0),
            runtimeBindingEpoch: WebInspectorRuntimeBindingGeneration(
                rawValue: runtimeBindingEpochs[route.agentTargetID] ?? 0
            ),
            consoleBindingEpoch: WebInspectorConsoleBindingGeneration(
                rawValue: consoleBindingEpochs[route.agentTargetID] ?? 0
            )
        )
    }

    private func advanceNavigationEpoch(
        for targetID: WebInspectorTarget.ID
    ) {
        let current =
            navigationEpochs[targetID]
            ?? WebInspectorNavigationEpoch(rawValue: 0)
        let (next, overflow) = current.rawValue.addingReportingOverflow(1)
        precondition(!overflow, "Console/Runtime navigation epoch exhausted.")
        navigationEpochs[targetID] = WebInspectorNavigationEpoch(rawValue: next)
    }

    private func advanceRuntimeBindingEpoch(
        for agentTargetID: WebInspectorTarget.ID
    ) {
        let current = runtimeBindingEpochs[agentTargetID] ?? 0
        let (next, overflow) = current.addingReportingOverflow(1)
        precondition(!overflow, "Runtime binding epoch exhausted.")
        runtimeBindingEpochs[agentTargetID] = next
    }

    private func advanceConsoleBindingEpoch(
        for agentTargetID: WebInspectorTarget.ID
    ) {
        let current = consoleBindingEpochs[agentTargetID] ?? 0
        let (next, overflow) = current.addingReportingOverflow(1)
        precondition(!overflow, "Console binding epoch exhausted.")
        consoleBindingEpochs[agentTargetID] = next
    }

    private func installFrameNavigationIdentities(
        from tree: Page.ResourceTree,
        agentTargetID: WebInspectorTarget.ID
    ) {
        let identity = FrameNavigationIdentity(
            loaderID: tree.frame.loaderID
        )
        frameNavigationIdentities[
            FrameNavigationKey(
                agentTargetID: agentTargetID,
                frameID: tree.frame.id
            )
        ] = identity
        latestFrameNavigationIdentities[tree.frame.id] = identity
        for child in tree.childFrames {
            installFrameNavigationIdentities(
                from: child,
                agentTargetID: agentTargetID
            )
        }
    }

    private func reconcileFrameTargetBindings() {
        for (targetID, binding) in frameTargetBindings {
            frameTargetBindings[targetID] = FrameTargetBinding(
                frameID: binding.frameID,
                navigationIdentity: binding.frameID.flatMap {
                    latestFrameNavigationIdentities[$0]
                }
            )
        }
    }

    private func removeFrameNavigationAuthority(for frameID: FrameID) {
        frameNavigationIdentities = frameNavigationIdentities.filter {
            $0.key.frameID != frameID
        }
        latestFrameNavigationIdentities[frameID] = nil
        frameTargetBindings = frameTargetBindings.filter {
            $0.value.frameID != frameID
        }
        if currentPageMainFrameID == frameID {
            currentPageMainFrameID = nil
        }
    }

    private func merge(
        _ addition: CanonicalConsoleRuntimeTransaction?,
        into transaction: inout CanonicalConsoleRuntimeTransaction
    ) {
        guard let addition else { return }
        transaction.runtimeContextChanges.append(
            contentsOf: addition.runtimeContextChanges
        )
        transaction.consoleMessageChanges.append(
            contentsOf: addition.consoleMessageChanges
        )
        transaction.resourceInvalidations.append(
            contentsOf: addition.resourceInvalidations
        )
    }

    private func retain(
        _ remote: Runtime.RemoteObject,
        in scopeID: UUID,
        authority: RuntimeObjectAuthority,
        objectGroup: Runtime.ObjectGroup
    ) throws -> RuntimeObject {
        try requireCurrent(authority, in: scopeID)
        try validateRemoteObjectTarget(remote, authority: authority)
        guard var scope = objectScopes[scopeID] else {
            throw WebInspectorCommandError.staleIdentifier
        }
        let (ordinal, overflow) = scope.nextOrdinal.addingReportingOverflow(1)
        guard !overflow else {
            throw WebInspectorCommandError.rejected(
                WebInspectorFailureDescription(
                    code: "runtime.scope.exhausted",
                    phase: "Runtime.object",
                    message: "The Runtime object scope exhausted its identity space."
                )
            )
        }
        let id = RuntimeObject.ID(scopeID: scopeID, ordinal: ordinal)
        scope.nextOrdinal = ordinal
        if let rawID = remote.id {
            scope.handles[id] = RuntimeHandle(
                rawID: rawID,
                authority: authority,
                objectGroup: objectGroup
            )
        }
        objectScopes[scopeID] = scope
        return RuntimeObject(id: id, remoteObject: remote)
    }

    private func runtimeHandle(
        for object: RuntimeObject,
        scopeID: UUID
    ) throws -> RuntimeHandle {
        guard objectScopes[scopeID] != nil else {
            throw WebInspectorCommandError.staleIdentifier
        }
        if let handle = objectScopes[scopeID]?.handles[object.id] {
            return handle
        }
        guard case let .consoleParameter(messageID, parameterIndex) = object.id.storage,
            let record = canonicalStore?.consoleMessage(for: messageID.canonicalStorage),
            record.parameters.indices.contains(parameterIndex),
            let rawID = record.parameters[parameterIndex].payload.rawObjectID
        else { throw WebInspectorCommandError.staleIdentifier }
        let parameterAuthority = record.parameters[parameterIndex].authority
        let authority = RuntimeObjectAuthority(
            attachmentGeneration: record.id.attachmentGeneration,
            pageGeneration: parameterAuthority.pageGeneration,
            semanticTargetID: parameterAuthority.semanticTargetID,
            agentTargetID: parameterAuthority.agentTargetID,
            navigationEpoch: parameterAuthority.navigationEpoch,
            runtimeBindingEpoch: parameterAuthority.runtimeBindingEpoch,
            consoleBindingEpoch: parameterAuthority.consoleBindingEpoch,
            frame: nil,
            sourceContextID: nil
        )
        return RuntimeHandle(
            rawID: rawID,
            authority: authority,
            objectGroup: .console
        )
    }

    private func evaluationAuthority(
        for contextID: RuntimeContext.ID?
    ) throws -> (
        rawContextID: Runtime.ExecutionContext.ID?,
        authority: RuntimeObjectAuthority
    ) {
        if let contextID {
            guard
                let record = canonicalStore?.runtimeContext(
                    for: contextID.canonicalStorage
                )
            else {
                throw WebInspectorCommandError.staleIdentifier
            }
            return (
                record.id.rawContextID,
                RuntimeObjectAuthority(
                    attachmentGeneration: record.id.attachmentGeneration,
                    pageGeneration: record.id.pageGeneration,
                    semanticTargetID: record.membership.semanticTargetID,
                    agentTargetID: record.id.agentTargetID,
                    navigationEpoch: record.membership.navigationEpoch,
                    runtimeBindingEpoch: record.membership.runtimeBindingEpoch,
                    consoleBindingEpoch: nil,
                    frame: record.frameID.map {
                        FrameAuthority(
                            frameID: $0,
                            navigationIdentity:
                                latestFrameNavigationIdentities[$0]
                        )
                    },
                    sourceContextID: record.id
                )
            )
        }
        guard let connection,
            let route = currentPageRuntimeRoute,
            let frameID = currentPageMainFrameID
        else {
            throw WebInspectorCommandError.staleIdentifier
        }
        return (
            nil,
            RuntimeObjectAuthority(
                attachmentGeneration: connection.attachmentGeneration,
                pageGeneration: route.generation,
                semanticTargetID: route.semanticTargetID,
                agentTargetID: route.agentTargetID,
                navigationEpoch: navigationEpochs[route.semanticTargetID]
                    ?? WebInspectorNavigationEpoch(rawValue: 0),
                runtimeBindingEpoch: WebInspectorRuntimeBindingGeneration(
                    rawValue: runtimeBindingEpochs[route.agentTargetID] ?? 0
                ),
                consoleBindingEpoch: nil,
                frame: FrameAuthority(
                    frameID: frameID,
                    navigationIdentity: latestFrameNavigationIdentities[frameID]
                ),
                sourceContextID: nil
            )
        )
    }

    private func requireCurrent(
        _ authority: RuntimeObjectAuthority,
        in scopeID: UUID
    ) throws {
        guard objectScopes[scopeID] != nil,
            isCurrent(authority)
        else {
            throw WebInspectorCommandError.staleIdentifier
        }
    }

    private func isCurrent(_ authority: RuntimeObjectAuthority) -> Bool {
        guard connection?.attachmentGeneration == authority.attachmentGeneration,
            canonicalStore?.attachmentGeneration == authority.attachmentGeneration,
            canonicalStore?.pageGeneration == authority.pageGeneration,
            (navigationEpochs[authority.semanticTargetID]
                ?? WebInspectorNavigationEpoch(rawValue: 0))
                == authority.navigationEpoch,
            WebInspectorRuntimeBindingGeneration(
                rawValue: runtimeBindingEpochs[authority.agentTargetID] ?? 0
            ) == authority.runtimeBindingEpoch
        else {
            return false
        }
        if let consoleBindingEpoch = authority.consoleBindingEpoch,
            WebInspectorConsoleBindingGeneration(
                rawValue: consoleBindingEpochs[authority.agentTargetID] ?? 0
            ) != consoleBindingEpoch
        {
            return false
        }
        if let frame = authority.frame,
            latestFrameNavigationIdentities[frame.frameID]
                != frame.navigationIdentity
        {
            return false
        }
        if let sourceContextID = authority.sourceContextID,
            canonicalStore?.runtimeContext(for: sourceContextID) == nil
        {
            return false
        }
        return true
    }

    private func requireCurrentAfterCommand(
        _ authority: RuntimeObjectAuthority,
        in scopeID: UUID,
        returned objects: [Runtime.RemoteObject],
        using connection: WebInspectorFeatureConnection
    ) async throws {
        let canApply =
            objectScopes[scopeID] != nil
            && isCurrent(authority)
            && objects.allSatisfy {
                remoteObjectTargetMatches($0, authority: authority)
            }
        guard canApply else {
            await releaseRemoteObjects(objects, using: connection)
            throw WebInspectorCommandError.staleIdentifier
        }
    }

    private func validateRemoteObjectTarget(
        _ object: Runtime.RemoteObject,
        authority: RuntimeObjectAuthority
    ) throws {
        guard remoteObjectTargetMatches(object, authority: authority) else {
            throw WebInspectorCommandError.staleIdentifier
        }
    }

    private func remoteObjectTargetMatches(
        _ object: Runtime.RemoteObject,
        authority: RuntimeObjectAuthority
    ) -> Bool {
        guard let targetID = object.id?.targetScopeRawValue else {
            return true
        }
        return targetID == authority.agentTargetID.rawValue
    }

    private static func remoteObjects(
        in property: Runtime.PropertyDescriptor
    ) -> [Runtime.RemoteObject] {
        [property.value, property.get, property.set, property.symbol]
            .compactMap { $0 }
    }

    private static func remoteObjects(
        in entry: Runtime.CollectionEntry
    ) -> [Runtime.RemoteObject] {
        [entry.key, entry.value].compactMap { $0 }
    }

    private func invalidateObjectHandles(
        for invalidations: [CanonicalConsoleRuntimeResourceInvalidation]
    ) -> Set<Runtime.RemoteObject.ID> {
        guard !invalidations.isEmpty else { return [] }
        var removed: Set<Runtime.RemoteObject.ID> = []
        for scopeID in Array(objectScopes.keys) {
            guard var scope = objectScopes[scopeID] else { continue }
            let invalidIDs = scope.handles.compactMap { id, handle in
                invalidations.contains {
                    invalidates(handle.authority, with: $0)
                } ? id : nil
            }
            for id in invalidIDs {
                if let handle = scope.handles.removeValue(forKey: id) {
                    removed.insert(handle.rawID)
                }
            }
            objectScopes[scopeID] = scope
        }
        return removed
    }

    private func invalidates(
        _ authority: RuntimeObjectAuthority,
        with invalidation: CanonicalConsoleRuntimeResourceInvalidation
    ) -> Bool {
        switch invalidation {
        case let .runtimeBinding(agentTargetID, epoch):
            authority.agentTargetID == agentTargetID
                && authority.runtimeBindingEpoch != epoch
        case let .consoleBinding(agentTargetID, epoch):
            authority.agentTargetID == agentTargetID
                && authority.consoleBindingEpoch.map { $0 != epoch } == true
        case let .semanticNavigation(semanticTargetID, navigationEpoch):
            authority.semanticTargetID == semanticTargetID
                && authority.navigationEpoch != navigationEpoch
        case let .frameNavigated(frameID), let .frameDetached(frameID):
            authority.frame?.frameID == frameID
        case let .targetLost(targetID):
            authority.agentTargetID == targetID
                || authority.semanticTargetID == targetID
        case .attachmentDetached, .attachmentReset:
            true
        }
    }

    private func releaseAllObjectScopes() async {
        guard let connection else {
            objectScopes.removeAll(keepingCapacity: true)
            return
        }
        let scopes = objectScopes.values
        objectScopes.removeAll(keepingCapacity: true)
        for scope in scopes {
            await releaseRemoteObjects(in: scope, using: connection)
        }
    }

    private func releaseRemoteObjects(
        in scope: ObjectScopeState,
        using connection: WebInspectorFeatureConnection
    ) async {
        await releaseRemoteObjectIDs(
            Set(scope.handles.values.map(\.rawID)),
            using: connection
        )
    }

    private func releaseRemoteObjects(
        _ objects: [Runtime.RemoteObject],
        using connection: WebInspectorFeatureConnection
    ) async {
        await releaseRemoteObjectIDs(
            Set(objects.compactMap(\.id)),
            using: connection
        )
    }

    private func releaseRemoteObjectIDs(
        _ objectIDs: Set<Runtime.RemoteObject.ID>
    ) async {
        guard let connection else { return }
        await releaseRemoteObjectIDs(objectIDs, using: connection)
    }

    private func releaseRemoteObjectIDs(
        _ objectIDs: Set<Runtime.RemoteObject.ID>,
        using connection: WebInspectorFeatureConnection
    ) async {
        for objectID in objectIDs {
            // Do not replace this with releaseObjectGroup: WebKit object
            // groups are target-local, while that command has no target ID.
            // RemoteObject.ID retains the owning target for correct routing.
            try? await connection.page.runtime.releaseObject(objectID)
        }
    }

    private func featureScope<Value: Sendable>(
        from event: WebInspectorRoutedEvent<Value>
    ) throws -> WebInspectorFeatureEventScope {
        guard let semantic = event.semanticTarget, let agent = event.agentTarget else {
            throw recovery(
                code: "console-runtime.route.missing",
                phase: "events",
                reason: .malformedDomainEvent(
                    WebInspectorFailureDescription(
                        code: "console-runtime.route.missing",
                        phase: "events",
                        message: "Console/Runtime event lacked target authority."
                    )
                )
            )
        }
        let agentTarget = WebInspectorFeatureTarget(agent)
        let semanticTarget =
            agentTarget.kind == .frame
            ? agentTarget
            : WebInspectorFeatureTarget(semantic)
        return WebInspectorFeatureEventScope(
            generation: WebInspectorPageGeneration(rawValue: event.generation.rawValue),
            semanticTarget: semanticTarget,
            agentTarget: agentTarget
        )
    }

    private func featureScope<Value: Sendable>(
        from reply: WebInspectorScopedReply<Value>
    ) throws -> WebInspectorFeatureEventScope {
        guard let semantic = reply.semanticTarget, let agent = reply.agentTarget else {
            throw WebInspectorFeatureError.bootstrap(
                WebInspectorFailureDescription(
                    code: "console-runtime.bootstrap.route",
                    phase: "bootstrap",
                    message: "Page.getResourceTree reply lacked target authority."
                )
            )
        }
        return WebInspectorFeatureEventScope(
            generation: WebInspectorPageGeneration(rawValue: reply.generation.rawValue),
            semanticTarget: WebInspectorFeatureTarget(semantic),
            agentTarget: WebInspectorFeatureTarget(agent)
        )
    }

    private func invalidatesBootstrap(
        _ event: WebInspectorPageEvent<WebInspectorConsoleRuntimeWireEvent>
    ) -> Bool {
        switch event {
        case .reset:
            return true
        case .event:
            return false
        }
    }

    private func recovery(
        code: String,
        phase: String,
        reason: WebInspectorRecoveryReason
    ) -> WebInspectorConsoleRuntimeRecoveryRequest {
        WebInspectorConsoleRuntimeRecoveryRequest(
            reason: reason,
            fingerprint: WebInspectorRecoveryFingerprint(code: code, phase: phase)
        )
    }

    private func transition(to newState: WebInspectorFeatureState) {
        webInspectorLogFeatureTransition(feature: .consoleRuntime, from: state, to: newState)
        state = newState
        registry.publish(newState, for: .consoleRuntime)
    }

    private func publish(_ newState: WebInspectorFeatureState) async {
        if let storeSink {
            var transaction = WebInspectorModelTransaction()
            transaction.setFeatureState(newState, for: .consoleRuntime)
            if let revision = try? await storeSink.commit(transaction),
                case let .ready(generation, _) = newState
            {
                transition(to: .ready(generation: generation, revision: revision))
                return
            }
        }
        transition(to: newState)
    }

    private func refreshReadyRevision(_ revision: WebInspectorStoreRevision) {
        guard case let .ready(generation, _) = state else { return }
        transition(to: .ready(generation: generation, revision: revision))
    }

    private func currentGeneration() async -> WebInspectorPageGeneration {
        guard let connection,
            let generation = try? await connection.page.generation
        else { return WebInspectorPageGeneration(rawValue: 0) }
        return WebInspectorPageGeneration(rawValue: generation.rawValue)
    }

    private func waitForExplicitRetry() async {
        if explicitRetryRequested {
            explicitRetryRequested = false
            return
        }
        await withCheckedContinuation { retryWaiter = $0 }
        explicitRetryRequested = false
    }

    private func isConnectionTerminal(_ error: any Error) -> Bool {
        guard let proxy = error as? WebInspectorProxyError else { return false }
        switch proxy {
        case .closed, .disconnected, .transportFailure:
            return true
        default:
            return false
        }
    }

    private func termination(for error: any Error) -> WebInspectorFeatureTermination {
        if error is CancellationError { return .detached }
        return .connectionFailed(
            connectionFailure(
                code: "console-runtime.connection",
                phase: "events",
                message: String(describing: error)
            )
        )
    }

    private func connectionFailure(
        code: String,
        phase: String,
        message: String
    ) -> WebInspectorConnectionFailure {
        .native(WebInspectorFailureDescription(code: code, phase: phase, message: message))
    }
}

public final class WebInspectorConsole: WebInspectorRetryableFeatureHandle, Sendable {
    private let owner: WebInspectorConsoleRuntimeFeature
    private let registry: WebInspectorFeatureRegistry

    package init(owner: WebInspectorConsoleRuntimeFeature, registry: WebInspectorFeatureRegistry) {
        self.owner = owner
        self.registry = registry
    }

    public var state: WebInspectorFeatureState { registry.state(for: .consoleRuntime) }
    public var stateUpdates: WebInspectorStateUpdates<WebInspectorFeatureState> {
        registry.updates(for: .consoleRuntime)
    }
    public func retry() async { await owner.retry() }
    public func clear() async throws { try await owner.clearConsole() }
    public func setLoggingChannelLevel(
        _ source: Console.ChannelSource,
        level: Console.ChannelLevel
    ) async throws {
        try await owner.setLoggingChannelLevel(source, level: level)
    }
}

public final class WebInspectorRuntime: WebInspectorRetryableFeatureHandle, Sendable {
    private let owner: WebInspectorConsoleRuntimeFeature
    private let registry: WebInspectorFeatureRegistry

    package init(owner: WebInspectorConsoleRuntimeFeature, registry: WebInspectorFeatureRegistry) {
        self.owner = owner
        self.registry = registry
    }

    public var state: WebInspectorFeatureState { registry.state(for: .consoleRuntime) }
    public var stateUpdates: WebInspectorStateUpdates<WebInspectorFeatureState> {
        registry.updates(for: .consoleRuntime)
    }
    public func retry() async { await owner.retry() }
    public func makeObjectScope() async -> WebInspectorRuntimeObjectScope {
        await owner.makeObjectScope()
    }
}

public final class WebInspectorRuntimeObjectScope: Sendable {
    public let id: UUID
    private let owner: WebInspectorConsoleRuntimeFeature

    package init(id: UUID, owner: WebInspectorConsoleRuntimeFeature) {
        self.id = id
        self.owner = owner
    }

    public func evaluate(
        _ expression: String,
        in context: RuntimeContext.ID? = nil
    ) async throws -> RuntimeEvaluation {
        try await owner.evaluate(expression, in: context, scopeID: id)
    }

    public func properties(of object: RuntimeObject) async throws -> [RuntimeObject.Property] {
        try await owner.properties(of: object, in: id)
    }

    public func preview(of object: RuntimeObject) async throws -> Runtime.ObjectPreview {
        try await owner.preview(of: object, in: id)
    }

    public func entries(of object: RuntimeObject) async throws -> [RuntimeObject.Entry] {
        try await owner.entries(of: object, in: id)
    }

    public func close() async { await owner.closeObjectScope(id) }
}
