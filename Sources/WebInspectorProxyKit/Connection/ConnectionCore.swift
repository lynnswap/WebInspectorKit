import Foundation

package actor ConnectionCore {
    package typealias CloseAction = @Sendable () async -> Void

    private enum State: Sendable {
        case open
        case closing
        case closed(Result<Void, ConnectionError>)
    }

    private struct ReplyKey: Hashable, Sendable {
        let targetID: ProtocolTarget.ID
        let commandID: UInt64
    }

    private enum PendingLocation: Hashable, Sendable {
        case root(UInt64)
        case target(ReplyKey)
    }

    private struct PreparedReply: Sendable {
        let finish: @Sendable (WebInspectorReplyBoundary?) -> Void
    }

    private struct ReplyMetadata: Sendable {
        let generation: WebInspectorPage.Generation
        let semanticTargetID: WebInspectorTarget.ID?
        let agentTargetID: WebInspectorTarget.ID?
        let semanticTarget: WebInspectorTarget?
        let agentTarget: WebInspectorTarget?
    }

    private struct PendingReply: Sendable {
        let method: WebInspectorProtocolMethod
        let targetID: ProtocolTarget.ID?
        let scopeID: WebInspectorOrderedScopeID?
        let prepare: @Sendable (Data, WebInspectorWireDecodeContext) throws -> PreparedReply
        let fail: @Sendable (any Error) -> Void
    }

    private struct ScopeActivation: Sendable {
        let id: UUID
        let scopeID: WebInspectorOrderedScopeID
        let targetID: ProtocolTarget.ID
        let generation: WebInspectorPage.Generation
        let task: Task<Void, Never>
    }

    private let backend: any ConnectionBackend
    private let protocolProfile: WebInspectorProtocolProfile
    private let responseTimeout: Duration?
    private var closeAction: CloseAction?
    private var state: State = .open
    private var closeTask: Task<Void, Never>?
    private var terminalResult: Result<Void, ConnectionError>?
    private let closeCompletion = ReplyPromise<Void>()

    private var nextCommandID: UInt64 = 0
    private var eventSequence = WebInspectorEventSequence(rawValue: 0)
    private var generation = WebInspectorPage.Generation(rawValue: 0)
    private var targets = ConnectionTargetRegistry()
    private var rootReplies: [UInt64: PendingReply] = [:]
    private var targetReplies: [ReplyKey: PendingReply] = [:]
    private var targetReplyByWrapperID: [UInt64: ReplyKey] = [:]
    private var provisionalMessagesByTargetID: [ProtocolTarget.ID: [ParsedProtocolMessage]] = [:]
    private var currentPageWaiters: [UUID: ReplyPromise<ProtocolTarget.Record>] = [:]
    private var scopes = ConnectionOrderedScopeRegistry()
    private var capabilities = ConnectionCapabilityRegistry()
    private var scopeActivations: [UUID: ScopeActivation] = [:]

    package init(
        backend: any ConnectionBackend,
        protocolProfile: WebInspectorProtocolProfile,
        responseTimeout: Duration?,
        closeAction: CloseAction? = nil
    ) {
        self.backend = backend
        self.protocolProfile = protocolProfile
        self.responseTimeout = responseTimeout
        self.closeAction = closeAction
    }

    package func requireOpen() throws {
        switch state {
        case .open:
            return
        case .closing:
            throw ConnectionError.closed
        case let .closed(result):
            switch result {
            case .success: throw ConnectionError.closed
            case let .failure(error): throw error
            }
        }
    }

    package var wasExplicitlyClosed: Bool {
        guard case .success? = terminalResult else { return false }
        return true
    }

    package func pageGeneration() throws -> WebInspectorPage.Generation {
        try requireOpen()
        guard targets.currentPageID != nil else { throw WebInspectorProxyError.pageUnavailable }
        return generation
    }

    package func currentMainPageRecord() -> ProtocolTarget.Record? {
        targets.currentPage
    }

    package func waitForCurrentMainPageTarget(
        timeout: Duration?
    ) async throws -> ProtocolTarget.Record {
        try requireOpen()
        if let current = targets.currentPage { return current }
        let id = UUID()
        let promise = ReplyPromise<ProtocolTarget.Record>()
        currentPageWaiters[id] = promise
        do {
            let value = try await Self.await(promise, timeout: timeout) {
                ConnectionError.replyTimeout(method: "Target.waitForCurrentPage")
            }
            currentPageWaiters.removeValue(forKey: id)
            return value
        } catch {
            currentPageWaiters.removeValue(forKey: id)
            throw error
        }
    }

    package func send<Result: Sendable>(
        _ command: WebInspectorWireCommand<Result>,
        route endpointRoute: WebInspectorRoute,
        in scopeID: WebInspectorOrderedScopeID? = nil
    ) async throws -> Result {
        let promise = ReplyPromise<Result>()
        let location = try await start(
            command,
            route: endpointRoute,
            scopeID: scopeID,
            finish: { value, boundary, _ in
                guard boundary == nil else {
                    promise.fulfill(.failure(WebInspectorProxyError.replyBoundaryUnavailable))
                    return
                }
                promise.fulfill(.success(value))
            },
            fail: { promise.fulfill(.failure($0)) }
        )
        do {
            return try await Self.await(promise, timeout: responseTimeout) {
                ConnectionError.replyTimeout(method: command.method.rawValue)
            }
        } catch {
            removePending(at: location)?.fail(error)
            clearBoundary(for: scopeID)
            throw map(error, method: command.method)
        }
    }

    package func sendScoped<Result: Sendable>(
        _ command: WebInspectorWireCommand<Result>,
        route endpointRoute: WebInspectorRoute,
        scopeID: WebInspectorOrderedScopeID
    ) async throws -> WebInspectorScopedReply<Result> {
        try await joinCommandTargetActivation(
            command,
            route: endpointRoute,
            scopeID: scopeID
        )
        guard var scope = scopes.entries[scopeID], scope.deliveryIsActive else {
            throw WebInspectorProxyError.replyBoundaryUnavailable
        }
        guard scope.outstandingBoundary == nil else {
            throw WebInspectorProxyError.replyBoundaryAlreadyOutstanding
        }
        let reservation = WebInspectorReplyBoundary(watermark: eventSequence)
        scope.outstandingBoundary = reservation
        scopes.entries[scopeID] = scope

        let promise = ReplyPromise<WebInspectorScopedReply<Result>>()
        let location: PendingLocation
        do {
            location = try await start(
                command,
                route: endpointRoute,
                scopeID: scopeID,
                finish: { value, boundary, metadata in
                    guard let boundary else {
                        promise.fulfill(.failure(WebInspectorProxyError.replyBoundaryUnavailable))
                        return
                    }
                    promise.fulfill(
                        .success(
                            WebInspectorScopedReply(
                                value: value,
                        boundary: boundary,
                        generation: metadata.generation,
                        semanticTargetID: metadata.semanticTargetID,
                        agentTargetID: metadata.agentTargetID,
                        semanticTarget: metadata.semanticTarget,
                        agentTarget: metadata.agentTarget
                    )))
                },
                fail: { promise.fulfill(.failure($0)) }
            )
        } catch {
            clearBoundary(for: scopeID)
            throw error
        }
        do {
            return try await Self.await(promise, timeout: responseTimeout) {
                ConnectionError.replyTimeout(method: command.method.rawValue)
            }
        } catch {
            removePending(at: location)?.fail(error)
            clearBoundary(for: scopeID)
            throw map(error, method: command.method)
        }
    }

    package func completeBoundary(
        _ boundary: WebInspectorReplyBoundary,
        in scopeID: WebInspectorOrderedScopeID
    ) throws {
        guard var scope = scopes.entries[scopeID],
            scope.outstandingBoundary?.token == boundary.token
        else {
            throw WebInspectorProxyError.replyBoundaryUnavailable
        }
        scope.outstandingBoundary = nil
        scopes.entries[scopeID] = scope
    }

    package func openScope<Element: Sendable>(
        descriptor: WebInspectorOrderedScopeDescriptor<Element>,
        buffering: WebInspectorEventBufferingPolicy,
        proxyReference: WebInspectorProxyReference
    ) async throws -> WebInspectorOrderedEventScope<Element> {
        try requireOpen()
        let capacity = try buffering.validatedCapacity()
        let id = WebInspectorOrderedScopeID()
        let mailbox = WebInspectorOrderedScopeMailbox<Element>(capacity: capacity)
        let selectedTargets = targets.selectedTargets(for: descriptor.selection)
        let sink = ConnectionOrderedScopeSink(descriptor: descriptor, mailbox: mailbox)
        scopes.entries[id] = .init(
            selection: descriptor.selection,
            descriptorCapabilities: descriptor.capabilities,
            sink: sink,
            selectedTargets: selectedTargets,
            leases: [],
            deliveryIsActive: true,
            outstandingBoundary: nil
        )

        do {
            for targetID in selectedTargets.sorted(by: { $0.rawValue < $1.rawValue }) {
                do {
                    try await acquireCapabilities(
                        descriptor.capabilities,
                        for: targetID,
                        scopeID: id
                    )
                } catch {
                    try Task.checkCancellation()
                    guard shouldIgnoreInitialAcquisitionFailure(
                        for: targetID,
                        in: id
                    ) else {
                        throw error
                    }
                }
            }
            return WebInspectorOrderedEventScope(
                id: id,
                proxyReference: proxyReference,
                mailbox: mailbox
            )
        } catch {
            await closeScope(id)
            throw error
        }
    }

    package func closeScope(_ id: WebInspectorOrderedScopeID) async {
        guard let entry = scopes.entries.removeValue(forKey: id) else { return }
        entry.sink.finish(nil)
        let activations = scopeActivations.values
            .filter { $0.scopeID == id }
            .map(\.task)
        for activation in activations { activation.cancel() }
        for lease in entry.leases.reversed() {
            await release(lease)
        }
    }

    package func receiveRootMessage(_ message: String) async {
        guard case .open = state else { return }
        do {
            let parsed = try await ConnectionMessageParser.parse(message)
            guard case .open = state else { return }
            try await handleRoot(parsed)
        } catch let error as ConnectionError {
            _ = beginTerminal(.failure(error))
        } catch {
            _ = beginTerminal(.failure(.unreadableEnvelope))
        }
    }

    package nonisolated func failFromNativeCallback(_ message: String) -> Task<Void, Never> {
        Task { await self.failPhysical(.failed(message)) }
    }

    package func close() async {
        let task = beginTerminal(.success(()))
        await task.value
    }

    package func waitUntilClosed() async throws {
        try await closeCompletion.value()
    }

    private func start<Result: Sendable>(
        _ command: WebInspectorWireCommand<Result>,
        route endpointRoute: WebInspectorRoute,
        scopeID: WebInspectorOrderedScopeID?,
        finish: @escaping @Sendable (Result, WebInspectorReplyBoundary?, ReplyMetadata) -> Void,
        fail: @escaping @Sendable (any Error) -> Void
    ) async throws -> PendingLocation {
        try requireOpen()
        let route = try resolve(command.target, endpoint: endpointRoute)
        let physicalTargetID = targets.resolve(route)
        if route != .root, physicalTargetID == nil {
            throw WebInspectorProxyError.pageUnavailable
        }
        let semanticTargetID: WebInspectorTarget.ID? =
            switch route {
            case .root: nil
        case .currentPage: .currentPage
        case let .target(id): id
        }
        let agentTargetID = physicalTargetID.map { WebInspectorTarget.ID($0.rawValue) }
        let semanticTarget: WebInspectorTarget? =
            switch route {
            case .root: nil
        case .currentPage: targets.target(for: physicalTargetID, identity: .currentPage)
        case let .target(id): targets.target(for: physicalTargetID, identity: id)
        }
        let agentTarget = targets.target(for: physicalTargetID)
        let pending = PendingReply(
            method: command.method,
            targetID: physicalTargetID,
            scopeID: scopeID,
            prepare: { data, replyContext in
                let value = try command.decodeReply(data, replyContext)
                let metadata = ReplyMetadata(
                    generation: replyContext.generation,
                    semanticTargetID: semanticTargetID,
                    agentTargetID: agentTargetID,
                    semanticTarget: semanticTarget,
                    agentTarget: agentTarget
                )
                return PreparedReply { boundary in
                    finish(value, boundary, metadata)
                }
            },
            fail: fail
        )

        let location: PendingLocation
        let outbound: String
        switch route {
        case .root:
            let id = allocateCommandID()
            location = .root(id)
            rootReplies[id] = pending
            outbound = try ConnectionMessageParser.makeCommandString(
                id: id,
                method: command.method,
                parameters: command.parameters
            )
        case .currentPage, .target:
            guard let physicalTargetID else { throw WebInspectorProxyError.pageUnavailable }
            let innerID = allocateCommandID()
            let outerID = allocateCommandID()
            let key = ReplyKey(targetID: physicalTargetID, commandID: innerID)
            location = .target(key)
            targetReplies[key] = pending
            targetReplyByWrapperID[outerID] = key
            let inner = try ConnectionMessageParser.makeCommandString(
                id: innerID,
                method: command.method,
                parameters: command.parameters
            )
            outbound = try ConnectionMessageParser.makeTargetWrapperCommandString(
                id: outerID,
                targetID: physicalTargetID,
                message: inner
            )
        }

        do {
            try await backend.sendJSONString(outbound)
            return location
        } catch {
            removePending(at: location)?.fail(error)
            throw map(error, method: command.method)
        }
    }

    private func handleRoot(_ parsed: ParsedProtocolMessage) async throws {
        if let id = parsed.id, let targetKey = targetReplyByWrapperID.removeValue(forKey: id) {
            if let error = parsed.error,
                let pending = targetReplies.removeValue(forKey: targetKey)
            {
                pending.fail(
                    ConnectionError.remoteError(
                        method: pending.method.rawValue,
                        code: error.code,
                        message: error.message
                    )
                )
                clearBoundary(for: pending.scopeID)
            }
            return
        }
        if let id = parsed.id, let pending = rootReplies.removeValue(forKey: id) {
            complete(pending, parsed: parsed)
            return
        }
        guard let method = parsed.method else { return }
        if method.rawValue == "Target.dispatchMessageFromTarget" {
            let dispatch: TargetDispatchParameters
            do {
                dispatch = try WebInspectorWireJSON.decode(TargetDispatchParameters.self, from: parsed.parameters)
            } catch {
                throw ConnectionError.malformedTargetControlPlane(method.rawValue)
            }
            let nested: ParsedProtocolMessage
            do {
                nested = try await ConnectionMessageParser.parse(dispatch.message)
            } catch {
                throw ConnectionError.malformedTargetControlPlane(method.rawValue)
            }
            try await handleTarget(nested, deliveredBy: dispatch.targetID)
            return
        }

        try await handleEvent(method: method, parameters: parsed.parameters, deliveredBy: nil)
    }

    private func handleTarget(
        _ parsed: ParsedProtocolMessage,
        deliveredBy targetID: ProtocolTarget.ID
    ) async throws {
        guard let target = targets.record(for: targetID) else { return }
        if target.isProvisional {
            provisionalMessagesByTargetID[targetID, default: []].append(parsed)
            return
        }
        if let id = parsed.id {
            let key = ReplyKey(targetID: targetID, commandID: id)
            if let pending = targetReplies.removeValue(forKey: key) {
                targetReplyByWrapperID = targetReplyByWrapperID.filter { $0.value != key }
                complete(pending, parsed: parsed)
                return
            }
        }
        guard let method = parsed.method else { return }
        if method.rawValue == "Target.dispatchMessageFromTarget" {
            let dispatch: TargetDispatchParameters
            do {
                dispatch = try WebInspectorWireJSON.decode(TargetDispatchParameters.self, from: parsed.parameters)
            } catch {
                throw ConnectionError.malformedTargetControlPlane(method.rawValue)
            }
            let nested: ParsedProtocolMessage
            do {
                nested = try await ConnectionMessageParser.parse(dispatch.message)
            } catch {
                throw ConnectionError.malformedTargetControlPlane(method.rawValue)
            }
            try await handleTarget(nested, deliveredBy: dispatch.targetID)
            return
        }
        try await handleEvent(method: method, parameters: parsed.parameters, deliveredBy: targetID)
    }

    private func handleEvent(
        method: WebInspectorProtocolMethod,
        parameters: Data,
        deliveredBy targetID: ProtocolTarget.ID?
    ) async throws {
        let committedTargetID: ProtocolTarget.ID? = if method.domain.rawValue == "Target" {
            try handleTargetControl(
                method: method,
                parameters: parameters,
                deliveredBy: targetID
            )
        } else {
            nil
        }
        routeEvent(method: method, parameters: parameters, deliveredBy: targetID)
        if let committedTargetID {
            try await dispatchProvisionalMessages(for: committedTargetID)
        }
    }

    private func dispatchProvisionalMessages(
        for targetID: ProtocolTarget.ID
    ) async throws {
        let messages = provisionalMessagesByTargetID.removeValue(forKey: targetID) ?? []
        for message in messages {
            guard case .open = state else { return }
            try await handleTarget(message, deliveredBy: targetID)
        }
    }

    private func complete(_ pending: PendingReply, parsed: ParsedProtocolMessage) {
        if let error = parsed.error {
            pending.fail(
                ConnectionError.remoteError(
                    method: pending.method.rawValue,
                    code: error.code,
                    message: error.message
                )
            )
            clearBoundary(for: pending.scopeID)
            return
        }
        let context = WebInspectorWireDecodeContext(
            generation: generation,
            targetID: pending.targetID.map { WebInspectorTarget.ID($0.rawValue) },
            targetScopeRawValue: targets.targetScopeRawValue(for: pending.targetID)
        )
        do {
            let prepared = try pending.prepare(parsed.result, context)
            if let scopeID = pending.scopeID {
                guard var scope = scopes.entries[scopeID], scope.deliveryIsActive,
                    let reserved = scope.outstandingBoundary
                else {
                    pending.fail(WebInspectorProxyError.replyBoundaryUnavailable)
                    return
                }
                let boundary = WebInspectorReplyBoundary(
                    token: reserved.token,
                    watermark: eventSequence
                )
                scope.outstandingBoundary = boundary
                let delivery = scope.sink.boundary(boundary)
                if case .enqueued = delivery {
                    scopes.entries[scopeID] = scope
                    prepared.finish(boundary)
                } else {
                    scope.deliveryIsActive = false
                    scopes.entries[scopeID] = scope
                    pending.fail(WebInspectorProxyError.replyBoundaryUnavailable)
                }
            } else {
                prepared.finish(nil)
            }
        } catch {
            clearBoundary(for: pending.scopeID)
            pending.fail(
                WebInspectorProxyError.commandFailed(
                    domain: pending.method.domain.rawValue,
                method: pending.method.name,
                message: "Malformed command result: \(error)"
            ))
        }
    }

    private func handleTargetControl(
        method: WebInspectorProtocolMethod,
        parameters: Data,
        deliveredBy parentTargetID: ProtocolTarget.ID?
    ) throws -> ProtocolTarget.ID? {
        switch method.rawValue {
        case "Target.targetCreated":
            let payload: TargetCreatedParameters
            do { payload = try WebInspectorWireJSON.decode(TargetCreatedParameters.self, from: parameters) } catch {
                throw ConnectionError.malformedTargetControlPlane(method.rawValue)
            }
            let info = payload.targetInfo
            let isProvisional = info.isProvisional ?? false
            let kind = targets.targetKind(
                protocolType: info.type,
                parentTargetID: parentTargetID
            )
            let record = ProtocolTarget.Record(
                id: info.targetID,
                kind: kind,
                parentTargetID: parentTargetID,
                frameID: try protocolProfile.semanticFrameID(
                    for: info.targetID,
                    targetKind: kind
                ),
                isProvisional: isProvisional,
                isPaused: info.isPaused ?? false
            )
            let bindingChanged = targets.insert(record)
            if bindingChanged { advanceGeneration() }
            resumeCurrentPageWaitersIfPossible()
            reconcileScopesAfterTargetMutation()
            return nil

        case "Target.targetDestroyed":
            let payload: TargetDestroyedParameters
            do { payload = try WebInspectorWireJSON.decode(TargetDestroyedParameters.self, from: parameters) } catch {
                throw ConnectionError.malformedTargetControlPlane(method.rawValue)
            }
            let bindingChanged = targets.remove(payload.targetID)
            provisionalMessagesByTargetID.removeValue(forKey: payload.targetID)
            failPendingReplies(for: payload.targetID)
            _ = capabilities.targetDisappeared(payload.targetID)
            if bindingChanged { advanceGeneration() }
            reconcileScopesAfterTargetMutation()
            return nil

        case "Target.didCommitProvisionalTarget":
            let payload: TargetCommittedParameters
            do { payload = try WebInspectorWireJSON.decode(TargetCommittedParameters.self, from: parameters) } catch {
                throw ConnectionError.malformedTargetControlPlane(method.rawValue)
            }
            let mutation = targets.commit(old: payload.oldTargetID, new: payload.newTargetID)
            if let retiredTargetID = mutation.retiredTargetID {
                failPendingReplies(for: retiredTargetID)
                _ = capabilities.targetDisappeared(retiredTargetID)
            }
            if mutation.bindingChanged { advanceGeneration() }
            resumeCurrentPageWaitersIfPossible()
            reconcileScopesAfterTargetMutation()
            return mutation.committedTargetID

        default:
            return nil
        }
    }

    private func routeEvent(
        method: WebInspectorProtocolMethod,
        parameters: Data,
        deliveredBy targetID: ProtocolTarget.ID?
    ) {
        eventSequence = WebInspectorEventSequence(rawValue: eventSequence.rawValue &+ 1)
        let agentTargetID = targetID ?? targets.currentPageID
        for id in scopes.entries.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            guard var scope = scopes.entries[id], scope.deliveryIsActive,
                  scope.sink.domains.contains(method.domain),
                  let agentTargetID,
                scope.selectedTargets.contains(agentTargetID)
            else {
                continue
            }
            let semanticTarget = targets.semanticTarget(for: scope.selection)
            let agentTarget = targets.target(for: agentTargetID)
            let envelope = WebInspectorRoutedEventEnvelope(
                sequence: eventSequence,
                generation: generation,
                semanticTargetID: semanticTarget?.id,
                agentTargetID: agentTarget?.id,
                semanticTarget: semanticTarget,
                agentTarget: agentTarget,
                method: method,
                parameters: parameters,
                targetScopeRawValue: targets.targetScopeRawValue(for: agentTargetID)
            )
            switch scope.sink.deliver(envelope) {
            case .enqueued, .unrelated:
                break
            case .overflow, .terminated:
                scope.deliveryIsActive = false
                scopes.entries[id] = scope
            }
        }
    }

    private func advanceGeneration() {
        generation = WebInspectorPage.Generation(rawValue: generation.rawValue &+ 1)
        for id in scopes.entries.keys {
            guard var entry = scopes.entries[id], entry.deliveryIsActive else { continue }
            if case .currentPage = entry.selection.anchor {
                if case .enqueued = entry.sink.generationDidChange(generation) {
                    entry.outstandingBoundary = nil
                } else {
                    entry.deliveryIsActive = false
                }
                scopes.entries[id] = entry
            }
        }
    }

    private func reconcileScopesAfterTargetMutation() {
        for id in scopes.entries.keys {
            guard var entry = scopes.entries[id] else { continue }
            let previous = entry.selectedTargets
            let current = targets.selectedTargets(for: entry.selection)
            entry.selectedTargets = current
            scopes.entries[id] = entry
            for removed in previous.subtracting(current) {
                removeLeases(for: removed, from: id)
            }
            for added in current.subtracting(previous) {
                scheduleActivation(scopeID: id, targetID: added)
            }
        }
    }

    private func scheduleActivation(
        scopeID: WebInspectorOrderedScopeID,
        targetID: ProtocolTarget.ID
    ) {
        guard let scope = scopes.entries[scopeID],
              scope.deliveryIsActive,
            scope.selectedTargets.contains(targetID)
        else {
            return
        }
        let scheduledGeneration = generation
        guard
            !scopeActivations.values.contains(where: {
                $0.scopeID == scopeID
                && $0.targetID == targetID
                && $0.generation == scheduledGeneration
            })
        else {
            return
        }
        let activationID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runScopeActivation(
                activationID,
                scopeID: scopeID,
                targetID: targetID,
                scheduledGeneration: scheduledGeneration
            )
        }
        scopeActivations[activationID] = ScopeActivation(
            id: activationID,
            scopeID: scopeID,
            targetID: targetID,
            generation: scheduledGeneration,
            task: task
        )
    }

    private func runScopeActivation(
        _ activationID: UUID,
        scopeID: WebInspectorOrderedScopeID,
        targetID: ProtocolTarget.ID,
        scheduledGeneration: WebInspectorPage.Generation
    ) async {
        defer { removeScopeActivation(activationID) }
        do {
            try Task.checkCancellation()
            guard
                let entry = activeScope(
                    scopeID,
                selecting: targetID,
                generation: scheduledGeneration
                )
            else {
                return
            }
            try await acquireCapabilities(
                entry.descriptorCapabilities,
                for: targetID,
                scopeID: scopeID,
                scheduledGeneration: scheduledGeneration
            )
        } catch {
            guard
                scopeActivationIsCurrent(
                    activationID,
                scopeID: scopeID,
                targetID: targetID,
                generation: scheduledGeneration
                )
            else {
                return
            }
            failScopeDelivery(scopeID, error: error)
        }
    }

    private func removeScopeActivation(_ id: UUID) {
        scopeActivations.removeValue(forKey: id)
    }

    private func joinCommandTargetActivation<Result: Sendable>(
        _ command: WebInspectorWireCommand<Result>,
        route endpointRoute: WebInspectorRoute,
        scopeID: WebInspectorOrderedScopeID
    ) async throws {
        while true {
            try Task.checkCancellation()
            guard let scope = scopes.entries[scopeID], scope.deliveryIsActive else {
                throw WebInspectorProxyError.replyBoundaryUnavailable
            }

            let route = try resolve(command.target, endpoint: endpointRoute)
            let targetID = targets.resolve(route)
            if route != .root, targetID == nil {
                throw WebInspectorProxyError.pageUnavailable
            }
            let expectedGeneration = generation
            let activations = scopeActivations.values
                .filter {
                    $0.scopeID == scopeID
                        && $0.targetID == targetID
                        && $0.generation == expectedGeneration
                }
                .map(\.task)
            for activation in activations {
                await activation.value
            }

            try Task.checkCancellation()
            guard let scope = scopes.entries[scopeID], scope.deliveryIsActive else {
                throw WebInspectorProxyError.replyBoundaryUnavailable
            }
            let currentRoute = try resolve(command.target, endpoint: endpointRoute)
            if generation == expectedGeneration,
               targets.resolve(currentRoute) == targetID {
                return
            }
        }
    }

    private func shouldIgnoreInitialAcquisitionFailure(
        for targetID: ProtocolTarget.ID,
        in scopeID: WebInspectorOrderedScopeID
    ) -> Bool {
        guard let scope = scopes.entries[scopeID], scope.deliveryIsActive else {
            return false
        }
        return !scope.selectedTargets.contains(targetID)
            || targets.record(for: targetID) == nil
    }

    private func activeScope(
        _ scopeID: WebInspectorOrderedScopeID,
        selecting targetID: ProtocolTarget.ID,
        generation expectedGeneration: WebInspectorPage.Generation
    ) -> ConnectionOrderedScopeRegistry.Entry? {
        guard generation == expectedGeneration,
              let scope = scopes.entries[scopeID],
              scope.deliveryIsActive,
              scope.selectedTargets.contains(targetID),
            targets.record(for: targetID) != nil
        else {
            return nil
        }
        return scope
    }

    private func scopeActivationIsCurrent(
        _ activationID: UUID,
        scopeID: WebInspectorOrderedScopeID,
        targetID: ProtocolTarget.ID,
        generation expectedGeneration: WebInspectorPage.Generation
    ) -> Bool {
        guard let activation = scopeActivations[activationID],
              activation.scopeID == scopeID,
              activation.targetID == targetID,
            activation.generation == expectedGeneration
        else {
            return false
        }
        return activeScope(
            scopeID,
            selecting: targetID,
            generation: expectedGeneration
        ) != nil
    }

    private func failScopeDelivery(_ id: WebInspectorOrderedScopeID, error: any Error) {
        guard var entry = scopes.entries[id], entry.deliveryIsActive else { return }
        entry.deliveryIsActive = false
        entry.sink.finish(error)
        scopes.entries[id] = entry
    }

    private func acquireCapabilities(
        _ descriptors: [WebInspectorDomainCapabilityDescriptor],
        for selectedTargetID: ProtocolTarget.ID,
        scopeID: WebInspectorOrderedScopeID,
        scheduledGeneration: WebInspectorPage.Generation? = nil
    ) async throws {
        var visiting: Set<ConnectionCapabilityKey> = []
        var acquired: Set<ConnectionCapabilityKey> = []
        for descriptor in descriptors {
            try await acquire(
                descriptor,
                selectedTargetID: selectedTargetID,
                scopeID: scopeID,
                scheduledGeneration: scheduledGeneration,
                visiting: &visiting,
                acquired: &acquired
            )
        }
    }

    private func acquire(
        _ descriptor: WebInspectorDomainCapabilityDescriptor,
        selectedTargetID: ProtocolTarget.ID,
        scopeID: WebInspectorOrderedScopeID,
        scheduledGeneration: WebInspectorPage.Generation?,
        visiting: inout Set<ConnectionCapabilityKey>,
        acquired: inout Set<ConnectionCapabilityKey>
    ) async throws {
        try requireActiveScope(
            scopeID,
            selecting: selectedTargetID,
            scheduledGeneration: scheduledGeneration
        )
        let agentTargetID = try resolveAgent(descriptor.agentResolution, selected: selectedTargetID)
        if let agentTargetID {
            guard let agent = targets.record(for: agentTargetID) else {
                throw WebInspectorProxyError.pageUnavailable
            }
            guard protocolProfile.supports(descriptor.domain, on: agent.kind) else {
                return
            }
        }
        let key = ConnectionCapabilityKey(
            agentTargetID: agentTargetID,
            domain: descriptor.domain,
            configurationID: descriptor.configurationID
        )
        if acquired.contains(key) { return }
        guard visiting.insert(key).inserted else {
            throw WebInspectorProxyError.commandFailed(
                domain: descriptor.domain.rawValue,
                method: "enable",
                message: "Capability dependency cycle."
            )
        }
        defer { visiting.remove(key) }
        for dependency in descriptor.dependencies {
            try await acquire(
                dependency,
                selectedTargetID: selectedTargetID,
                scopeID: scopeID,
                scheduledGeneration: scheduledGeneration,
                visiting: &visiting,
                acquired: &acquired
            )
        }

        try requireActiveScope(
            scopeID,
            selecting: selectedTargetID,
            scheduledGeneration: scheduledGeneration
        )

        var entry = capabilities.entry(for: key, descriptor: descriptor)
        if entry.owners.contains(scopeID) {
            acquired.insert(key)
            return
        }
        entry.owners.insert(scopeID)
        capabilities.set(entry, for: key)
        appendLease(.init(scopeID: scopeID, key: key))

        do {
            try await ensureCapabilityActive(key)
            try requireActiveScope(
                scopeID,
                selecting: selectedTargetID,
                scheduledGeneration: scheduledGeneration
            )
            acquired.insert(key)
        } catch {
            if var current = capabilities.entries[key] {
                current.owners.remove(scopeID)
                capabilities.set(current, for: key)
            }
            throw error
        }
    }

    private func requireActiveScope(
        _ scopeID: WebInspectorOrderedScopeID,
        selecting targetID: ProtocolTarget.ID,
        scheduledGeneration: WebInspectorPage.Generation?
    ) throws {
        try Task.checkCancellation()
        guard let scope = scopes.entries[scopeID],
              scope.deliveryIsActive,
            scope.selectedTargets.contains(targetID)
        else {
            throw CancellationError()
        }
        if let scheduledGeneration, generation != scheduledGeneration {
            throw CancellationError()
        }
    }

    private func ensureCapabilityActive(_ key: ConnectionCapabilityKey) async throws {
        while true {
            guard var entry = capabilities.entries[key] else {
                throw WebInspectorProxyError.pageUnavailable
            }

            switch entry.physical {
            case .enabled:
                return

            case .retained:
                switch entry.descriptor.reacquisition {
                case .retainPhysicalState:
                    return
                case .enable:
                    entry.physical = .inactive
                    capabilities.set(entry, for: key)
                    continue
                }

            case let .enabling(_, completion), let .disabling(_, completion):
                try await completion.valueIgnoringCancellation()
                continue

            case .inactive, .unknown:
                guard let enable = entry.descriptor.enable else {
                    entry.physical = .enabled
                    capabilities.set(entry, for: key)
                    return
                }

                let completion = ReplyPromise<Void>()
                let operationID = capabilities.allocateOperationID()
                entry.physical = .enabling(operationID: operationID, completion: completion)
                capabilities.set(entry, for: key)
                do {
                    _ = try await send(enable, route: route(for: key.agentTargetID))
                    guard var current = capabilities.entries[key] else {
                        throw WebInspectorProxyError.pageUnavailable
                    }
                    guard case let .enabling(activeID, _) = current.physical,
                        activeID == operationID
                    else {
                        try await completion.valueIgnoringCancellation()
                        continue
                    }
                    current.physical = .enabled
                    capabilities.set(current, for: key)
                    completion.fulfill(.success(()))
                    return
                } catch {
                    if var current = capabilities.entries[key],
                       case let .enabling(activeID, _) = current.physical,
                        activeID == operationID
                    {
                        current.physical = .unknown
                        capabilities.set(current, for: key)
                    }
                    completion.fulfill(.failure(error))
                    throw error
                }
            }
        }
    }

    private func release(_ lease: ConnectionCapabilityRegistry.Lease) async {
        guard var entry = capabilities.entries[lease.key] else { return }
        entry.owners.remove(lease.scopeID)
        guard entry.owners.isEmpty else {
            capabilities.set(entry, for: lease.key)
            return
        }
        switch entry.descriptor.release {
        case .retainEnabled:
            entry.physical = .retained
            capabilities.set(entry, for: lease.key)
        case let .disable(command):
            let completion = ReplyPromise<Void>()
            let operationID = capabilities.allocateOperationID()
            entry.physical = .disabling(operationID: operationID, completion: completion)
            capabilities.set(entry, for: lease.key)
            do {
                _ = try await send(command, route: route(for: lease.key.agentTargetID))
                guard var current = capabilities.entries[lease.key] else { return }
                if case let .disabling(activeID, _) = current.physical, activeID == operationID {
                    current.physical = .inactive
                    capabilities.set(current, for: lease.key)
                    completion.fulfill(.success(()))
                    capabilities.removeIfInactiveAndUnowned(lease.key)
                }
            } catch {
                if var current = capabilities.entries[lease.key] {
                    current.physical = .unknown
                    capabilities.set(current, for: lease.key)
                }
                completion.fulfill(.failure(error))
            }
        }
    }

    private func appendLease(_ lease: ConnectionCapabilityRegistry.Lease) {
        guard var scope = scopes.entries[lease.scopeID], !scope.leases.contains(lease) else { return }
        scope.leases.append(lease)
        scopes.entries[lease.scopeID] = scope
    }

    private func removeLeases(
        for targetID: ProtocolTarget.ID,
        from scopeID: WebInspectorOrderedScopeID
    ) {
        guard var scope = scopes.entries[scopeID] else { return }
        let removed = scope.leases.filter { $0.key.agentTargetID == targetID }
        scope.leases.removeAll { $0.key.agentTargetID == targetID }
        scopes.entries[scopeID] = scope
        for lease in removed {
            guard var entry = capabilities.entries[lease.key] else { continue }
            entry.owners.remove(scopeID)
            capabilities.set(entry, for: lease.key)
        }
    }

    private func resolveAgent(
        _ resolution: WebInspectorCapabilityAgentResolution,
        selected: ProtocolTarget.ID
    ) throws -> ProtocolTarget.ID? {
        switch resolution {
        case .selectedTarget: return selected
        case .currentPage:
            guard let current = targets.currentPageID else { throw WebInspectorProxyError.pageUnavailable }
            return current
        case .root: return nil
        }
    }

    private func route(for targetID: ProtocolTarget.ID?) -> WebInspectorRoute {
        targetID.map { .target(WebInspectorTarget.ID($0.rawValue)) } ?? .root
    }

    private func resolve(
        _ target: WebInspectorCommandTarget,
        endpoint: WebInspectorRoute
    ) throws -> WebInspectorRoute {
        switch target {
        case .endpoint: return endpoint
        case .currentPage: return .currentPage
        case .root: return .root
        case let .target(id): return .target(id)
        }
    }

    private func allocateCommandID() -> UInt64 {
        nextCommandID &+= 1
        return nextCommandID
    }

    private func removePending(at location: PendingLocation) -> PendingReply? {
        switch location {
        case let .root(id): return rootReplies.removeValue(forKey: id)
        case let .target(key):
            targetReplyByWrapperID = targetReplyByWrapperID.filter { $0.value != key }
            return targetReplies.removeValue(forKey: key)
        }
    }

    private func failPendingReplies(for targetID: ProtocolTarget.ID) {
        let keys = targetReplies.keys.filter { $0.targetID == targetID }
        for key in keys {
            guard let pending = removePending(at: .target(key)) else { continue }
            clearBoundary(for: pending.scopeID)
            pending.fail(WebInspectorProxyError.pageUnavailable)
        }
    }

    private func clearBoundary(for scopeID: WebInspectorOrderedScopeID?) {
        guard let scopeID, var scope = scopes.entries[scopeID] else { return }
        scope.outstandingBoundary = nil
        scopes.entries[scopeID] = scope
    }

    private func resumeCurrentPageWaitersIfPossible() {
        guard let current = targets.currentPage else { return }
        let waiters = currentPageWaiters.values
        currentPageWaiters.removeAll()
        for waiter in waiters { waiter.fulfill(.success(current)) }
    }

    private func failPhysical(_ error: ConnectionError) async {
        let task = beginTerminal(.failure(error))
        await task.value
    }

    private func beginTerminal(_ result: Result<Void, ConnectionError>) -> Task<Void, Never> {
        if let closeTask { return closeTask }
        guard case .open = state else {
            return Task {}
        }
        state = .closing
        terminalResult = result

        let failure: any Error =
            switch result {
            case .success: WebInspectorProxyError.closed
        case let .failure(error): map(error, method: nil)
        }
        let pending = Array(rootReplies.values) + Array(targetReplies.values)
        rootReplies.removeAll()
        targetReplies.removeAll()
        targetReplyByWrapperID.removeAll()
        for reply in pending { reply.fail(failure) }
        for waiter in currentPageWaiters.values { waiter.fulfill(.failure(failure)) }
        currentPageWaiters.removeAll()
        for entry in scopes.entries.values { entry.sink.finish(result.isSuccess ? nil : failure) }
        scopes.entries.removeAll()
        let activations = scopeActivations.values.map(\.task)
        scopeActivations.removeAll()
        for task in activations { task.cancel() }

        let closeAction = self.closeAction
        self.closeAction = nil
        let backend = backend
        let task = Task { [weak self] in
            if let closeAction { await closeAction() } else { await backend.detach() }
            for activation in activations { await activation.value }
            await self?.finishTerminal(result)
        }
        closeTask = task
        return task
    }

    private func finishTerminal(_ result: Result<Void, ConnectionError>) {
        state = .closed(result)
        switch result {
        case .success: closeCompletion.fulfill(.success(()))
        case let .failure(error): closeCompletion.fulfill(.failure(map(error, method: nil)))
        }
        closeTask = nil
    }

    private nonisolated func map(
        _ error: any Error,
        method: WebInspectorProtocolMethod?
    ) -> any Error {
        guard let connection = error as? ConnectionError else { return error }
        switch connection {
        case .closed: return WebInspectorProxyError.closed
        case let .failed(message): return WebInspectorProxyError.disconnected(message)
        case .unreadableEnvelope:
            return WebInspectorProxyError.disconnected("Unreadable Web Inspector envelope.")
        case let .malformedTargetControlPlane(method):
            return WebInspectorProxyError.disconnected("Malformed \(method) control-plane message.")
        case let .missingTarget(target):
            return WebInspectorProxyError.commandRejected(
                method: method?.rawValue ?? "", message: "Missing target \(target).")
        case let .replyTimeout(method):
            let parsed = WebInspectorProtocolMethod(rawValue: method)
            return WebInspectorProxyError.timeout(domain: parsed.domain.rawValue, method: parsed.name)
        case let .remoteError(method, code, message):
            return webInspectorProxyRemoteError(
                method: method,
                code: code,
                message: message
            )
        }
    }

    private nonisolated static func await<Value: Sendable>(
        _ promise: ReplyPromise<Value>,
        timeout: Duration?,
        timeoutError: @escaping @Sendable () -> any Error
    ) async throws -> Value {
        guard let timeout else { return try await promise.value() }
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await promise.value() }
            group.addTask {
                try await ContinuousClock().sleep(for: timeout)
                throw timeoutError()
            }
            guard let value = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return value
        }
    }
}

private struct TargetDispatchParameters: Decodable {
    let targetID: ProtocolTarget.ID
    let message: String

    private enum CodingKeys: String, CodingKey {
        case targetID = "targetId"
        case message
    }
}

private struct TargetCreatedParameters: Decodable {
    let targetInfo: TargetInfo

    struct TargetInfo: Decodable {
        let targetID: ProtocolTarget.ID
        let type: String
        let isProvisional: Bool?
        let isPaused: Bool?

        private enum CodingKeys: String, CodingKey {
            case targetID = "targetId"
            case type
            case isProvisional
            case isPaused
        }
    }
}

private struct TargetDestroyedParameters: Decodable {
    let targetID: ProtocolTarget.ID

    private enum CodingKeys: String, CodingKey { case targetID = "targetId" }
}

private struct TargetCommittedParameters: Decodable {
    let oldTargetID: ProtocolTarget.ID
    let newTargetID: ProtocolTarget.ID

    private enum CodingKeys: String, CodingKey {
        case oldTargetID = "oldTargetId"
        case newTargetID = "newTargetId"
    }
}

private extension Result where Success == Void, Failure == ConnectionError {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
