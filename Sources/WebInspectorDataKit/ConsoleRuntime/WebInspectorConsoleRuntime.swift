import Foundation
import WebInspectorProxyKit

package enum WebInspectorConsoleRuntimeWireEvent: Sendable {
    case console(WebInspectorRoutedEvent<Console.Event>)
    case runtime(WebInspectorRoutedEvent<Runtime.Event>)
    case page(WebInspectorRoutedEvent<Page.Event>)
}

private struct WebInspectorConsoleRuntimeRecoveryRequest: Error, Sendable {
    let reason: WebInspectorRecoveryReason
    let fingerprint: WebInspectorRecoveryFingerprint
}

/// Sole semantic owner of Console messages, Runtime contexts, and remote
/// object scope lifetimes.
package actor WebInspectorConsoleRuntimeFeature: WebInspectorModelFeature {
    package static let id = WebInspectorFeatureID.consoleRuntime

    private struct RuntimeHandle: Sendable {
        let rawID: Runtime.RemoteObject.ID
    }

    private struct ObjectScopeState: Sendable {
        let group: Runtime.ObjectGroup
        var nextOrdinal: UInt64 = 0
        var handles: [RuntimeObject.ID: RuntimeHandle] = [:]
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
    private var runtimeBindingEpoch: UInt64 = 0
    private var consoleBindingEpoch: UInt64 = 0
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
        await publish(.synchronizing(generation: await currentGeneration()))

        while !closeRequested {
            do {
                try await runOrderedScope()
                return closeRequested ? .detached : .connectionFailed(
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
        do { try await connection.page.console.clearMessages() }
        catch {
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
        let rawContext: Runtime.ExecutionContext.ID?
        if let contextID {
            guard let record = canonicalStore?.runtimeContext(for: contextID.canonicalStorage) else {
                throw WebInspectorCommandError.staleIdentifier
            }
            rawContext = Runtime.ExecutionContext.ID(
                record.id.rawContextID.rawValue,
                scopedToTargetRawValue: record.id.agentTargetID.rawValue
            )
        } else {
            rawContext = nil
        }
        let result: Runtime.EvaluationResult
        do {
            result = try await connection.page.runtime.evaluate(
                expression,
                in: rawContext,
                objectGroup: group
            )
        } catch {
            throw webInspectorCommandError(
                error,
                featureID: .consoleRuntime,
                phase: "Runtime.evaluate"
            )
        }
        let object = try retain(result.object, in: scopeID)
        return RuntimeEvaluation(object: object, isException: result.wasThrown)
    }

    package func properties(
        of object: RuntimeObject,
        in scopeID: UUID
    ) async throws -> [RuntimeObject.Property] {
        guard let connection else { throw WebInspectorCommandError.containerClosed }
        let rawID = try rawObjectID(for: object, scopeID: scopeID)
        let properties: [Runtime.PropertyDescriptor]
        do { properties = try await connection.page.runtime.properties(of: rawID) }
        catch {
            throw webInspectorCommandError(
                error,
                featureID: .consoleRuntime,
                phase: "Runtime.getProperties"
            )
        }
        return try properties.map { property in
            RuntimeObject.Property(
                name: property.name,
                value: property.value?.description,
                object: try property.value.map { try retain($0, in: scopeID) }
            )
        }
    }

    package func preview(
        of object: RuntimeObject,
        in scopeID: UUID
    ) async throws -> Runtime.ObjectPreview {
        guard let connection else { throw WebInspectorCommandError.containerClosed }
        let rawID = try rawObjectID(for: object, scopeID: scopeID)
        do { return try await connection.page.runtime.preview(of: rawID) }
        catch {
            throw webInspectorCommandError(
                error,
                featureID: .consoleRuntime,
                phase: "Runtime.getPreview"
            )
        }
    }

    package func entries(
        of object: RuntimeObject,
        in scopeID: UUID
    ) async throws -> [RuntimeObject.Entry] {
        guard let connection else { throw WebInspectorCommandError.containerClosed }
        let rawID = try rawObjectID(for: object, scopeID: scopeID)
        let entries: [Runtime.CollectionEntry]
        do { entries = try await connection.page.runtime.collectionEntries(of: rawID) }
        catch {
            throw webInspectorCommandError(
                error,
                featureID: .consoleRuntime,
                phase: "Runtime.getCollectionEntries"
            )
        }
        return try entries.map { entry in
            RuntimeObject.Entry(
                key: try entry.key.map { try retain($0, in: scopeID) },
                value: try retain(entry.value, in: scopeID)
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
        let reply = try await scope.command(PageWireCoding.resourceTree())
        let prefix = try await scope.drain(through: reply.boundary)
        if prefix.contains(where: invalidatesBootstrap) {
            throw recovery(
                code: "console-runtime.bootstrap.invalidated",
                phase: "bootstrap",
                reason: .targetChanged
            )
        }
        let route = try featureScope(from: reply)
        runtimeBindingEpoch &+= 1
        consoleBindingEpoch &+= 1
        let binding = makeScope(route)
        var staged = CanonicalConsoleRuntimeStore(storeID: connection.storeID)
        _ = try staged.reset(
            attachmentGeneration: connection.attachmentGeneration,
            pageGeneration: route.generation
        )
        for event in prefix {
            try reduceBootstrap(event, defaultScope: binding, staged: &staged)
        }
        let previous = canonicalStore?.snapshot()
        let current = staged.snapshot()
        var transaction = WebInspectorModelTransaction()
        appendReplacement(previous: previous, current: current, to: &transaction)
        transaction.setFeatureState(
            .ready(
                generation: route.generation,
                revision: WebInspectorStoreRevision(rawValue: 0)
            ),
            for: .consoleRuntime
        )
        let revision = try await storeSink.commit(transaction)
        canonicalStore = staged
        transition(to: .ready(generation: route.generation, revision: revision))

        for try await event in scope.events {
            if closeRequested { return }
            guard var staged = canonicalStore else { continue }
            do {
                try await reduceLive(event, staged: &staged)
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
            canonicalStore = staged
        }
    }

    private func reduceBootstrap(
        _ event: WebInspectorPageEvent<WebInspectorConsoleRuntimeWireEvent>,
        defaultScope: WebInspectorConsoleRuntimeEventScope,
        staged: inout CanonicalConsoleRuntimeStore
    ) throws {
        guard case let .event(_, value) = event else { return }
        let transaction: CanonicalConsoleRuntimeTransaction?
        switch value {
        case let .runtime(routed):
            transaction = try staged.reduceRuntime(
                routed.value,
                scope: makeScope(try featureScope(from: routed))
            )
        case let .console(routed):
            transaction = try staged.reduceConsole(
                routed.value,
                scope: makeScope(try featureScope(from: routed))
            )
        case let .page(routed):
            switch routed.value {
            case let .frameDetached(frameID):
                transaction = staged.frameWasDetached(frameID)
            case .frameNavigated, .unknown:
                transaction = nil
            }
        }
        _ = transaction
        _ = defaultScope
    }

    private func reduceLive(
        _ event: WebInspectorPageEvent<WebInspectorConsoleRuntimeWireEvent>,
        staged: inout CanonicalConsoleRuntimeStore
    ) async throws {
        switch event {
        case .reset:
            throw recovery(
                code: "console-runtime.generation.reset",
                phase: "events",
                reason: .targetChanged
            )
        case let .event(_, .runtime(routed)):
            if let canonical = try staged.reduceRuntime(
                routed.value,
                scope: makeScope(try featureScope(from: routed))
            ) {
                try await commit(canonical, staged: staged)
            }
        case let .event(_, .console(routed)):
            if let canonical = try staged.reduceConsole(
                routed.value,
                scope: makeScope(try featureScope(from: routed))
            ) {
                try await commit(canonical, staged: staged)
            }
        case let .event(_, .page(routed)):
            switch routed.value {
            case let .frameNavigated(frame) where frame.parentID == nil:
                throw recovery(
                    code: "console-runtime.main-frame.navigated",
                    phase: "events",
                    reason: .targetChanged
                )
            case let .frameNavigated(frame):
                try await commit(staged.frameWasNavigated(frame.id), staged: staged)
            case let .frameDetached(frameID):
                try await commit(staged.frameWasDetached(frameID), staged: staged)
            case .unknown:
                break
            }
        }
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
            transaction.append(contentsOf: previous.runtimeContexts.compactMap { entry in
                let id = RuntimeContext.ID(canonical: entry.record.id)
                return contextIDs.contains(id) ? nil : webInspectorRuntimeContextSchema.delete(id: id)
            })
            transaction.append(contentsOf: previous.consoleMessages.compactMap { entry in
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
            navigationEpoch: route.generation,
            runtimeBindingEpoch: WebInspectorRuntimeBindingGeneration(
                rawValue: runtimeBindingEpoch
            ),
            consoleBindingEpoch: WebInspectorConsoleBindingGeneration(
                rawValue: consoleBindingEpoch
            )
        )
    }

    private func retain(
        _ remote: Runtime.RemoteObject,
        in scopeID: UUID
    ) throws -> RuntimeObject {
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
        if let rawID = remote.id { scope.handles[id] = RuntimeHandle(rawID: rawID) }
        objectScopes[scopeID] = scope
        return RuntimeObject(id: id, remoteObject: remote)
    }

    private func rawObjectID(
        for object: RuntimeObject,
        scopeID: UUID
    ) throws -> Runtime.RemoteObject.ID {
        if let handle = objectScopes[scopeID]?.handles[object.id] {
            return handle.rawID
        }
        guard case let .consoleParameter(messageID, parameterIndex) = object.id.storage,
            let record = canonicalStore?.consoleMessage(for: messageID.canonicalStorage),
            record.parameters.indices.contains(parameterIndex),
            let rawID = record.parameters[parameterIndex].payload.rawObjectID
        else { throw WebInspectorCommandError.staleIdentifier }
        return rawID
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
        let objectIDs = Set(scope.handles.values.map(\.rawID))
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
        return WebInspectorFeatureEventScope(
            generation: WebInspectorPageGeneration(rawValue: event.generation.rawValue),
            semanticTarget: WebInspectorFeatureTarget(semantic),
            agentTarget: WebInspectorFeatureTarget(agent)
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
        case let .event(_, .page(routed)):
            if case let .frameNavigated(frame) = routed.value { return frame.parentID == nil }
            return false
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

public final class WebInspectorConsole: WebInspectorFeatureHandle, Sendable {
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

public final class WebInspectorRuntime: WebInspectorFeatureHandle, Sendable {
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
