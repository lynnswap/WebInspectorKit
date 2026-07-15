import Foundation
import OSLog

private let transportLogger = Logger(
    subsystem: "WebInspectorKit",
    category: "TransportSession"
)

package actor TransportSession {
    package typealias TimeoutSleep = @Sendable (Duration) async throws -> Void
    package typealias ResponseTimeoutDidFire = @Sendable () async -> Void
    package typealias MessageParser = @Sendable (String) async throws -> ParsedProtocolMessage

    private let backend: any TransportBackend
    private let protocolProfile: WebInspectorProtocolProfile
    private let responseTimeout: Duration?
    private let timeoutSleep: TimeoutSleep
    private let responseTimeoutDidFire: ResponseTimeoutDidFire
    private let messageParser: MessageParser
    private var nextCommandID: UInt64
    private var eventSequences: TransportEventSequenceTracker
    private var replyStore: TransportReplyStore
    private var mainPageTargetWaiterStore: TransportSession.MainPageTargetWaiterStore
    private var targetRegistry: TransportTargetRegistry
    private var provisionalTargetMessageStore: TransportProvisionalTargetMessageStore
    private var styleSheetRouting: TransportStyleSheetRouting
    private var networkRouting: TransportNetworkRouting
    private var runtimeContextRegistry: RuntimeContextRegistry
    private var networkOriginRegistry: TransportNetworkOriginRegistry
    private var eventSubscribers: TransportEventSubscriberRegistry
    private var inboundMessageQueue: TransportInboundMessageQueue
    private var closed: Bool

    package init(
        backend: any TransportBackend,
        protocolProfile: WebInspectorProtocolProfile = .released26,
        responseTimeout: Duration? = nil,
        timeoutSleep: TimeoutSleep? = nil,
        responseTimeoutDidFire: ResponseTimeoutDidFire? = nil,
        messageParser: @escaping MessageParser = {
            try await TransportMessageParser.parse($0)
        }
    ) {
        self.backend = backend
        self.protocolProfile = protocolProfile
        self.responseTimeout = responseTimeout
        self.timeoutSleep = timeoutSleep ?? { try await Task.sleep(for: $0) }
        self.responseTimeoutDidFire = responseTimeoutDidFire ?? {}
        self.messageParser = messageParser
        nextCommandID = 0
        eventSequences = TransportEventSequenceTracker()
        replyStore = TransportReplyStore()
        mainPageTargetWaiterStore = TransportSession.MainPageTargetWaiterStore()
        targetRegistry = TransportTargetRegistry()
        provisionalTargetMessageStore = TransportProvisionalTargetMessageStore()
        styleSheetRouting = TransportStyleSheetRouting()
        networkRouting = TransportNetworkRouting()
        runtimeContextRegistry = RuntimeContextRegistry()
        networkOriginRegistry = TransportNetworkOriginRegistry()
        eventSubscribers = TransportEventSubscriberRegistry()
        inboundMessageQueue = TransportInboundMessageQueue()
        closed = false
    }

    package func events(for domain: ProtocolDomain) -> AsyncStream<ProtocolEvent> {
        guard !closed else {
            return finishedStream(of: ProtocolEvent.self)
        }
        let pair = AsyncStream<ProtocolEvent>.makeStream(bufferingPolicy: .unbounded)
        let subscriberID = eventSubscribers.insert(pair.continuation, domain: domain)
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeSubscriber(subscriberID, domain: domain)
            }
        }
        return pair.stream
    }

    package func orderedEvents() -> AsyncStream<ProtocolEvent> {
        guard !closed else {
            return finishedStream(of: ProtocolEvent.self)
        }
        let pair = AsyncStream<ProtocolEvent>.makeStream(bufferingPolicy: .unbounded)
        let subscriberID = eventSubscribers.insertOrdered(pair.continuation)
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeOrderedSubscriber(subscriberID)
            }
        }
        return pair.stream
    }

    package func send(_ command: ProtocolCommand) async throws -> ProtocolCommand.Result {
        try Task.checkCancellation()
        guard !closed else {
            throw TransportSession.Error.transportClosed
        }

        switch command.routing {
        case .root:
            return try await sendRoot(command)
        case let .target(targetID):
            let routingTargetID = command.domain == .network
                ? networkRouting.routingTargetID(forStableTargetID: targetID)
                : targetID
            guard let target = targetRegistry.target(for: routingTargetID) else {
                if command.domain == .network,
                   protocolProfile.usesRootNetworkAgent(
                       forFrameTargetID: routingTargetID
                   ) {
                    return try await sendRoot(
                        command,
                        semanticTargetID: routingTargetID
                    )
                }
                throw TransportSession.Error.missingTarget(routingTargetID)
            }
            if protocolProfile.usesRootAgent(command.domain, for: target.kind) {
                return try await sendRoot(command, semanticTargetID: routingTargetID)
            }
            try requireSupport(for: command, targetID: routingTargetID)
            if let result = transportLocalResult(for: command, targetID: routingTargetID) {
                return result
            }
            return try await sendTarget(command, targetID: routingTargetID)
        case let .octopus(pageTarget):
            let resolvedTarget = try pageTarget ?? currentMainPageTarget()
            try requireSupport(for: command, targetID: resolvedTarget)
            if let result = transportLocalResult(for: command, targetID: resolvedTarget) {
                return result
            }
            return try await sendTarget(command, targetID: resolvedTarget)
        }
    }

    @discardableResult
    package func receiveRootMessage(_ message: String) async -> UInt64 {
        guard !closed else {
            return eventSequences.current.sequence
        }
        inboundMessageQueue.append(message)
        await drainInboundMessages()
        return eventSequences.current.sequence
    }

    package func detach() async {
        guard !closed else {
            return
        }
        closed = true
        for pending in replyStore.pendingReplies {
            await pending.promise.fulfill(.failure(TransportSession.Error.transportClosed))
        }
        for waiter in mainPageTargetWaiterStore.removeAll() {
            await waiter.fulfill(.failure(TransportSession.Error.transportClosed))
        }
        replyStore.removeAll()
        provisionalTargetMessageStore.removeAll()
        networkRouting.removeAll()
        eventSubscribers.finishAndRemoveAll()
        await backend.detach()
    }

    package func waitForCurrentMainPageTarget(timeout: Duration? = nil) async throws -> TransportSession.MainPageTarget {
        guard !closed else {
            throw TransportSession.Error.transportClosed
        }
        if let currentMainPageTargetID = targetRegistry.currentMainPageTargetID {
            return TransportSession.MainPageTarget(
                targetID: currentMainPageTargetID,
                receivedSequence: eventSequences.current.sequence
            )
        }

        let waiter = mainPageTargetWaiterStore.insert()

        let timeoutTask: Task<Void, Never>? = timeout.map { timeout in
            let timeoutSleep = self.timeoutSleep
            return Task {
                do {
                    try await timeoutSleep(timeout)
                } catch {
                    return
                }
                await self.failMainPageTargetWaiter(waiter.id, error: TransportSession.Error.missingMainPageTarget)
            }
        }
        defer {
            timeoutTask?.cancel()
        }

        do {
            return try await withTaskCancellationHandler {
                try await waiter.promise.value()
            } onCancel: {
                Task {
                    await self.failMainPageTargetWaiter(waiter.id, error: CancellationError())
                }
            }
        } catch {
            mainPageTargetWaiterStore.remove(id: waiter.id)
            throw error
        }
    }

    package func snapshot() -> TransportSession.Snapshot {
        TransportSession.Snapshot(
            currentMainPageTargetID: targetRegistry.currentMainPageTargetID,
            targetsByID: targetRegistry.targetsByID,
            frameTargetIDsByFrameID: targetRegistry.frameTargetIDsByFrameID,
            parentFrameIDsByFrameID: targetRegistry.parentFrameIDsByFrameID,
            executionContextsByKey: runtimeContextRegistry.contextsByKey,
            pendingRootReplyIDs: replyStore.pendingRootReplyIDs,
            pendingTargetReplyKeys: replyStore.pendingTargetReplyKeys
        )
    }

    package func requireOpen() throws {
        guard !closed else {
            throw TransportSession.Error.transportClosed
        }
    }

    package func targetID(forExecutionContext key: RuntimeContext.Key) -> ProtocolTarget.ID? {
        runtimeContextRegistry.targetID(for: key)
    }

    package func targetID(forFrameID frameID: ProtocolFrame.ID) -> ProtocolTarget.ID? {
        targetRegistry.targetID(forFrameID: frameID)
    }

    private func requireSupport(
        for command: ProtocolCommand,
        targetID: ProtocolTarget.ID
    ) throws {
        guard let target = targetRegistry.target(for: targetID) else {
            throw TransportSession.Error.missingTarget(targetID)
        }
        guard protocolProfile.supports(command.domain, on: target.kind) else {
            throw TransportSession.Error.unsupportedDomain(
                command.domain,
                targetID: targetID
            )
        }
    }

    private func sendRoot(
        _ command: ProtocolCommand,
        semanticTargetID: ProtocolTarget.ID? = nil
    ) async throws -> ProtocolCommand.Result {
        let commandID = allocateCommandID()
        let promise = ReplyPromise<ProtocolCommand.Result>()
        replyStore.insertRootReply(TransportSession.PendingReply(
            domain: command.domain,
            method: command.method,
            targetID: semanticTargetID,
            promise: promise,
            hasBufferedProvisionalResponse: false
        ), commandID: commandID)
        do {
            try Task.checkCancellation()
            let message = try TransportMessageParser.makeCommandString(
                id: commandID,
                method: command.method,
                parametersData: command.parametersData
            )
            try await backend.sendJSONString(message)
            try Task.checkCancellation()
        } catch {
            await failPendingReply(.root(commandID), error: error)
            throw error
        }
        return try await awaitReply(
            promise,
            timeout: .root(commandID),
            method: command.method,
            targetID: nil
        )
    }

    private func sendTarget(
        _ command: ProtocolCommand,
        targetID: ProtocolTarget.ID
    ) async throws -> ProtocolCommand.Result {
        let innerCommandID = allocateCommandID()
        let outerCommandID = allocateCommandID()
        let key = TransportSession.ReplyKey(targetID: targetID, commandID: innerCommandID)
        let promise = ReplyPromise<ProtocolCommand.Result>()
        replyStore.insertTargetReply(TransportSession.PendingReply(
            domain: command.domain,
            method: command.method,
            targetID: targetID,
            promise: promise,
            hasBufferedProvisionalResponse: false
        ), key: key, rootWrapperID: outerCommandID)
        do {
            try Task.checkCancellation()
            let message = try TransportMessageParser.makeCommandString(
                id: innerCommandID,
                method: command.method,
                parametersData: command.parametersData
            )
            let wrapperMessage = try TransportMessageParser.makeTargetWrapperCommandString(
                id: outerCommandID,
                targetIdentifier: targetID.rawValue,
                message: message
            )
            try await backend.sendJSONString(wrapperMessage)
            try Task.checkCancellation()
        } catch {
            await failPendingReply(.target(key), error: error)
            throw error
        }
        return try await awaitReply(
            promise,
            timeout: .target(key),
            method: command.method,
            targetID: targetID
        )
    }

    private func transportLocalResult(
        for command: ProtocolCommand,
        targetID: ProtocolTarget.ID
    ) -> ProtocolCommand.Result? {
        guard command.method == "DOM.enable" else {
            return nil
        }
        let eventSequence = eventSequences.current
        return ProtocolCommand.Result(
            domain: command.domain,
            method: command.method,
            targetID: targetID,
            receivedSequence: eventSequence.sequence,
            receivedDomainSequences: eventSequence.receivedDomainSequences,
            resultData: Data("{}".utf8)
        )
    }

    private func drainInboundMessages() async {
        guard inboundMessageQueue.startDraining() else {
            return
        }

        defer {
            inboundMessageQueue.finishDraining()
        }

        while let rawMessage = inboundMessageQueue.popNext() {
            guard let parsed = try? await messageParser(rawMessage) else {
                continue
            }
            await handleRootMessage(parsed)
        }
    }

    private func awaitReply(
        _ promise: ReplyPromise<ProtocolCommand.Result>,
        timeout key: TransportSession.PendingKey,
        method: String,
        targetID: ProtocolTarget.ID?
    ) async throws -> ProtocolCommand.Result {
        if Task.isCancelled {
            await failPendingReply(key, error: CancellationError())
        }
        let timeoutTask: Task<Void, Never>? = responseTimeout.map { responseTimeout in
            let timeoutSleep = self.timeoutSleep
            let responseTimeoutDidFire = self.responseTimeoutDidFire
            return Task {
                do {
                    try await timeoutSleep(responseTimeout)
                } catch {
                    return
                }
                await self.failPendingReplyFromTimeout(
                    key,
                    error: TransportSession.Error.replyTimeout(method: method, targetID: targetID)
                )
                await responseTimeoutDidFire()
            }
        }
        defer {
            timeoutTask?.cancel()
        }
        do {
            return try await withTaskCancellationHandler {
                try await promise.value()
            } onCancel: {
                Task {
                    await self.failPendingReply(key, error: CancellationError())
                }
            }
        } catch {
            removePendingReply(key)
            throw error
        }
    }

    private func handleRootMessage(_ parsed: ParsedProtocolMessage) async {
        if let id = parsed.id,
           let key = replyStore.takeTargetReplyKey(forRootWrapperID: id) {
            if parsed.errorMessage != nil,
               let pending = replyStore.removeTargetReply(for: key) {
                await resolve(pending, parsed: parsed)
            }
            return
        }

        if let id = parsed.id,
           let pending = replyStore.removeRootReply(commandID: id) {
            await resolve(pending, parsed: parsed)
            return
        }

        guard let method = parsed.method else {
            return
        }

        if method == "Target.dispatchMessageFromTarget" {
            guard let dispatch = try? TransportMessageParser.decode(TargetDispatchParams.self, from: parsed.paramsData) else {
                return
            }
            guard let targetMessage = try? await messageParser(dispatch.message) else {
                return
            }
            await handleTargetMessage(targetMessage, targetID: dispatch.targetId)
            return
        }

        let domain = ProtocolDomain(method: method)
        let latestRootNetworkTargets: TransportNetworkRouting.EventTargets?
        if protocolProfile.generation == .latest && domain == .network {
            switch resolveLatestRootNetworkEventTargets(
                method: method,
                paramsData: parsed.paramsData
            ) {
            case let .deliver(targets):
                latestRootNetworkTargets = targets
            case .deferred:
                return
            }
        } else {
            latestRootNetworkTargets = nil
        }
        let targetID: ProtocolTarget.ID?
        if let latestRootNetworkTargets {
            targetID = latestRootNetworkTargets.routingTargetID
        } else {
            targetID = targetIDForRootEvent(method: method, paramsData: parsed.paramsData)
        }
        let sourceTargetID = sourceTargetIDForRootEvent(method: method, targetID: targetID)
        let destroyedCurrentMainPageTarget = method == "Target.targetDestroyed"
            && targetID != nil
            && targetID == targetRegistry.currentMainPageTargetID
        let destroyedProvisionalTargetInCurrentPageHierarchy = method == "Target.targetDestroyed"
            && targetID.flatMap { targetRegistry.target(for: $0) }?.isProvisional == true
            && targetID.map { targetRegistry.isTargetInCurrentPageHierarchy($0) } == true
        let detachedCurrentPageFrameTarget = method == "Page.frameDetached"
            && targetID.map(targetRegistry.isFrameTargetInCurrentPage) == true
        let pageBindingTargetID = resolvePageBindingTargetID(
            method: method,
            deliveredTargetID: sourceTargetID ?? targetID,
            deliveredTargetIsExact: false,
            paramsData: parsed.paramsData
        )
        let pendingStyleSheetAddedEvents: [ResolvedStyleSheetAddedEvent]
        do {
            pendingStyleSheetAddedEvents = try await updateRegistryFromRootEvent(
                method: method,
                targetID: targetID,
                sourceTargetID: sourceTargetID,
                paramsData: parsed.paramsData
            )
        } catch {
            transportLogger.fault(
                "Skipped invalid Target.targetCreated: \(String(describing: error), privacy: .public)"
            )
            return
        }
        recordPageNavigationNetworkOrigin(
            method: method,
            targetID: pageBindingTargetID,
            paramsData: parsed.paramsData
        )
        await emitResolvedDeferredRootNetworkEvents()
        // ProxyingPageAgent is installed by the inspected page's
        // WebPageInspectorController and registers IPC receivers for that
        // page in each process. A provisional process is still part of the
        // same semantic current page, not a second inspected page.
        await emit(
            domain: domain,
            method: method,
            targetID: targetID,
            sourceTargetID: sourceTargetID,
            pageBindingTargetID: pageBindingTargetID,
            networkScopeTargetID: latestRootNetworkTargets?.stableScopeTargetID,
            networkPageMembership: latestRootNetworkTargets?.pageMembership,
            rootPageBelongedToCurrentPage: protocolProfile.pageTopologyMayArriveAtRoot
                && domain == .page ? true : nil,
            paramsData: parsed.paramsData,
            destroyedCurrentMainPageTarget: destroyedCurrentMainPageTarget,
            destroyedProvisionalTargetInCurrentPageHierarchy: destroyedProvisionalTargetInCurrentPageHierarchy,
            detachedCurrentPageFrameTarget: detachedCurrentPageFrameTarget
        )
        await emitResolvedStyleSheetAddedEvents(pendingStyleSheetAddedEvents)
        await dispatchCommittedProvisionalTargetMessagesIfNeeded(method: method, paramsData: parsed.paramsData)
    }

    private func handleTargetMessage(_ parsed: ParsedProtocolMessage, targetID: ProtocolTarget.ID) async {
        if targetRegistry.target(for: targetID)?.isProvisional == true {
            markTargetReplyAsBufferedIfNeeded(parsed, targetID: targetID)
            provisionalTargetMessageStore.append(parsed, for: targetID)
            return
        }

        if let id = parsed.id {
            let key = TransportSession.ReplyKey(targetID: targetID, commandID: id)
            if let pending = replyStore.removeTargetReply(for: key) {
                await resolve(pending, parsed: parsed)
                return
            }
        }

        guard let method = parsed.method else {
            return
        }

        if method == "Target.dispatchMessageFromTarget" {
            guard let dispatch = try? TransportMessageParser.decode(TargetDispatchParams.self, from: parsed.paramsData),
                  let targetMessage = try? await messageParser(dispatch.message) else {
                return
            }
            await handleTargetMessage(targetMessage, targetID: dispatch.targetId)
            return
        }

        let emittedTargetID = targetIDForTargetEvent(
            method: method,
            deliveredTargetID: targetID,
            paramsData: parsed.paramsData
        )
        let detachedCurrentPageFrameTarget = method == "Page.frameDetached"
            && targetRegistry.isFrameTargetInCurrentPage(emittedTargetID)
        let pageBindingTargetID = resolvePageBindingTargetID(
            method: method,
            deliveredTargetID: targetID,
            deliveredTargetIsExact: true,
            paramsData: parsed.paramsData
        )
        updateRegistryFromTargetEvent(
            method: method,
            targetID: emittedTargetID,
            sourceTargetID: targetID,
            paramsData: parsed.paramsData
        )
        recordPageNavigationNetworkOrigin(
            method: method,
            targetID: pageBindingTargetID,
            paramsData: parsed.paramsData
        )
        await emitResolvedDeferredRootNetworkEvents()
        await emit(
            domain: ProtocolDomain(method: method),
            method: method,
            targetID: emittedTargetID,
            sourceTargetID: targetID,
            pageBindingTargetID: pageBindingTargetID,
            networkOriginTargetID: ProtocolDomain(method: method) == .network ? targetID : nil,
            paramsData: parsed.paramsData,
            detachedCurrentPageFrameTarget: detachedCurrentPageFrameTarget
        )
    }

    private func resolve(_ pending: TransportSession.PendingReply, parsed: ParsedProtocolMessage) async {
        if let errorMessage = parsed.errorMessage {
            await pending.promise.fulfill(
                .failure(
                    TransportSession.Error.remoteError(
                        method: pending.method,
                        targetID: pending.targetID,
                        message: errorMessage
                    )
                )
            )
            return
        }
        let eventSequence = eventSequences.current
        await pending.promise.fulfill(
            .success(
                ProtocolCommand.Result(
                    domain: pending.domain,
                    method: pending.method,
                    targetID: pending.targetID,
                    receivedSequence: eventSequence.sequence,
                    receivedDomainSequences: eventSequence.receivedDomainSequences,
                    resultData: parsed.resultData
                )
            )
        )
    }

    private func updateRegistryFromRootEvent(
        method: String,
        targetID: ProtocolTarget.ID?,
        sourceTargetID: ProtocolTarget.ID?,
        paramsData: Data
    ) async throws -> [ResolvedStyleSheetAddedEvent] {
        switch method {
        case "Target.targetCreated":
            guard let params = try? TransportMessageParser.decode(TargetCreatedParams.self, from: paramsData) else {
                return []
            }
            return applyTargetCreated(try record(for: params.targetInfo))
        case "Target.targetDestroyed":
            guard let params = try? TransportMessageParser.decode(TargetDestroyedParams.self, from: paramsData) else {
                return []
            }
            await applyTargetDestroyed(params.targetId)
            return []
        case "Target.didCommitProvisionalTarget":
            guard let params = try? TransportMessageParser.decode(TargetCommittedParams.self, from: paramsData) else {
                return []
            }
            return applyTargetCommitted(oldTargetID: params.oldTargetId, newTargetID: params.newTargetId)
        case "Page.frameNavigated", "Page.frameDetached":
            guard protocolProfile.pageTopologyMayArriveAtRoot else {
                return []
            }
            updateRegistryFromTargetEvent(
                method: method,
                targetID: targetID,
                sourceTargetID: sourceTargetID,
                paramsData: paramsData
            )
            return []
        case "Runtime.executionContextCreated", "Runtime.executionContextDestroyed", "Runtime.executionContextsCleared":
            updateRegistryFromTargetEvent(
                method: method,
                targetID: targetID,
                sourceTargetID: sourceTargetID,
                paramsData: paramsData
            )
            return []
        case "CSS.styleSheetAdded", "CSS.styleSheetRemoved":
            updateCSSStyleSheetRegistry(method: method, targetID: targetID, paramsData: paramsData)
            return []
        default:
            return []
        }
    }

    private func updateRegistryFromTargetEvent(
        method: String,
        targetID: ProtocolTarget.ID?,
        sourceTargetID: ProtocolTarget.ID? = nil,
        paramsData: Data
    ) {
        if method == "Page.frameNavigated" {
            guard let params = try? TransportMessageParser.decode(
                PageFrameNavigatedParams.self,
                from: paramsData
            ) else {
                return
            }
            targetRegistry.recordFrameNavigated(
                deliveredTargetID: sourceTargetID ?? targetID,
                frameID: params.frame.id,
                parentFrameID: params.frame.parentId
            )
            return
        }
        if method == "Page.frameDetached" {
            guard let params = try? TransportMessageParser.decode(
                PageFrameDetachedParams.self,
                from: paramsData
            ) else {
                return
            }
            networkRouting.removeFrame(params.frameId)
            targetRegistry.recordFrameDetached(params.frameId)
            return
        }
        guard let targetID else {
            return
        }
        if method == "CSS.styleSheetAdded" || method == "CSS.styleSheetRemoved" {
            updateCSSStyleSheetRegistry(method: method, targetID: targetID, paramsData: paramsData)
            return
        }
        switch method {
        case "Runtime.executionContextCreated":
            guard let params = try? TransportMessageParser.decode(RuntimeExecutionContextCreatedParams.self, from: paramsData) else {
                return
            }
            let frameID = params.context.frameId
            let resolvedTargetID = targetRegistry.recordRuntimeContext(
                deliveredTargetID: targetID,
                frameID: frameID
            )
            let context = RuntimeContext.Record(
                id: params.context.id,
                targetID: resolvedTargetID,
                runtimeAgentTargetID: sourceTargetID ?? targetID,
                type: params.context.type ?? .normal,
                name: params.context.name ?? "",
                frameID: frameID
            )
            runtimeContextRegistry.record(context)
        case "Runtime.executionContextDestroyed":
            guard let params = try? TransportMessageParser.decode(RuntimeExecutionContextDestroyedParams.self, from: paramsData) else {
                return
            }
            let runtimeAgentTargetID = sourceTargetID ?? targetID
            runtimeContextRegistry.remove(
                RuntimeContext.Key(
                    runtimeAgentTargetID: runtimeAgentTargetID,
                    contextID: params.executionContextId
                )
            )
        case "Runtime.executionContextsCleared":
            let runtimeAgentTargetID = sourceTargetID ?? targetID
            runtimeContextRegistry.clear(runtimeAgentTargetID: runtimeAgentTargetID)
        default:
            return
        }
    }

    private func applyTargetCreated(_ record: ProtocolTarget.Record) -> [ResolvedStyleSheetAddedEvent] {
        resolvePendingStyleSheets(for: targetRegistry.recordTargetCreated(record))
    }

    private func record(for targetInfo: TargetInfoPayload) throws -> ProtocolTarget.Record {
        let kind = ProtocolTarget.Kind(protocolType: targetInfo.type)
        let frameID = try protocolProfile.semanticFrameID(
            for: targetInfo.targetId,
            targetKind: kind
        )
        return ProtocolTarget.Record(
            id: targetInfo.targetId,
            kind: kind,
            frameID: frameID,
            capabilities: protocolProfile.capabilities(for: kind),
            isProvisional: targetInfo.isProvisional ?? false,
            isPaused: targetInfo.isPaused ?? false
        )
    }

    private func applyTargetDestroyed(_ targetID: ProtocolTarget.ID) async {
        targetRegistry.removeTarget(targetID)
        networkOriginRegistry.removeTarget(targetID)
        provisionalTargetMessageStore.removeTarget(targetID)
        styleSheetRouting.removeTarget(targetID)
        runtimeContextRegistry.removeTarget(targetID)
        networkRouting.removeTarget(targetID)
        let pendingReplies = replyStore.removeTargetReplies(for: targetID)
        for pending in pendingReplies {
            await pending.promise.fulfill(.failure(TransportSession.Error.missingTarget(targetID)))
        }
    }

    private func applyTargetCommitted(
        oldTargetID: ProtocolTarget.ID?,
        newTargetID: ProtocolTarget.ID
    ) -> [ResolvedStyleSheetAddedEvent] {
        let mutation = targetRegistry.commitTarget(oldTargetID: oldTargetID, newTargetID: newTargetID)
        if let committedOldTargetID = mutation.committedOldTargetID {
            moveBufferedProvisionalTargetMessages(from: committedOldTargetID, to: newTargetID)
        }

        if mutation.shouldRetargetExternalState,
           let oldTargetID = mutation.committedOldTargetID {
            replyStore.retargetPendingReplies(from: oldTargetID, to: newTargetID)
            styleSheetRouting.retarget(from: oldTargetID, to: newTargetID)
            runtimeContextRegistry.retarget(oldTargetID: oldTargetID, newTargetID: newTargetID)
            networkRouting.retarget(from: oldTargetID, to: newTargetID)
        }

        return resolvePendingStyleSheets(for: mutation.resolvedFrameTarget)
    }

    private func resolvePendingStyleSheets(
        for frameTarget: TransportFrameTargetResolution?
    ) -> [ResolvedStyleSheetAddedEvent] {
        guard let frameTarget else {
            return []
        }
        return resolvePendingStyleSheets(frameID: frameTarget.frameID, targetID: frameTarget.targetID)
    }

    private func moveBufferedProvisionalTargetMessages(
        from oldTargetID: ProtocolTarget.ID,
        to newTargetID: ProtocolTarget.ID
    ) {
        provisionalTargetMessageStore.retargetMessages(from: oldTargetID, to: newTargetID)
    }

    private func dispatchCommittedProvisionalTargetMessagesIfNeeded(method: String, paramsData: Data) async {
        guard method == "Target.didCommitProvisionalTarget",
              let params = try? TransportMessageParser.decode(TargetCommittedParams.self, from: paramsData) else {
            return
        }

        let messages = provisionalTargetMessageStore.takeMessages(for: params.newTargetId)
        for message in messages {
            await handleTargetMessage(message, targetID: params.newTargetId)
        }
    }

    private func targetIDForRootEvent(method: String, paramsData: Data) -> ProtocolTarget.ID? {
        switch method {
        case "Target.targetCreated":
            return (try? TransportMessageParser.decode(TargetCreatedParams.self, from: paramsData))?.targetInfo.targetId
        case "Target.targetDestroyed":
            return (try? TransportMessageParser.decode(TargetDestroyedParams.self, from: paramsData))?.targetId
        case "Target.didCommitProvisionalTarget":
            return (try? TransportMessageParser.decode(TargetCommittedParams.self, from: paramsData))?.newTargetId
        case "Runtime.executionContextCreated":
            if let frameID = (try? TransportMessageParser.decode(RuntimeExecutionContextCreatedParams.self, from: paramsData))?.context.frameId {
                return targetRegistry.targetID(forFrameID: frameID) ?? targetRegistry.currentMainPageTargetID
            }
            return targetRegistry.currentMainPageTargetID
        case "Page.frameNavigated":
            guard protocolProfile.pageTopologyMayArriveAtRoot,
                  let params = try? TransportMessageParser.decode(
                    PageFrameNavigatedParams.self,
                    from: paramsData
                  ) else {
                return nil
            }
            if let frameTargetID = targetRegistry.targetID(forFrameID: params.frame.id),
               targetRegistry.target(for: frameTargetID)?.kind == .frame {
                return frameTargetID
            }
            guard params.frame.parentId == nil else {
                return nil
            }
            return targetRegistry.currentMainPageTargetID
        case "Page.frameDetached":
            guard protocolProfile.pageTopologyMayArriveAtRoot,
                  let params = try? TransportMessageParser.decode(
                    PageFrameDetachedParams.self,
                    from: paramsData
                  ) else {
                return nil
            }
            if let frameTargetID = targetRegistry.targetID(forFrameID: params.frameId),
               targetRegistry.target(for: frameTargetID)?.kind == .frame {
                return frameTargetID
            }
            guard targetRegistry.currentMainFrameID == params.frameId else {
                return nil
            }
            return targetRegistry.currentMainPageTargetID
        case "CSS.styleSheetAdded":
            return targetIDForCSSStyleSheetAdded(paramsData: paramsData)
        case "CSS.styleSheetChanged", "CSS.styleSheetRemoved":
            return targetIDForCSSStyleSheetID(paramsData: paramsData)
        case "DOM.documentUpdated":
            return nil
        default:
            switch ProtocolDomain(method: method) {
            case .dom, .runtime, .css, .console, .network, .page, .storage:
                return targetRegistry.currentMainPageTargetID
            default:
                return nil
            }
        }
    }

    private func resolveLatestRootNetworkEventTargets(
        method: String,
        paramsData: Data
    ) -> LatestRootNetworkEventResolution {
        // Do not add WebSocket routing here. WebKit 625's root
        // ProxyingNetworkAgent forwards only HTTP request lifecycle events;
        // InspectorNetworkAgent emits WebSocket events through the page target.
        guard let params = try? TransportMessageParser.decode(
            NetworkRequestRoutingParams.self,
            from: paramsData
        ), let requestID = params.requestId else {
            return .deliver(TransportNetworkRouting.EventTargets(
                routingTargetID: targetRegistry.currentMainPageTargetID,
                stableScopeTargetID: nil,
                pageMembership: .currentPage
            ))
        }
        let isTerminalEvent = method == "Network.loadingFinished"
            || method == "Network.loadingFailed"

        if networkRouting.hasDeferredRequest(requestID) {
            networkRouting.deferEvent(
                requestID: requestID,
                frameID: params.frameId,
                targetID: params.targetId,
                method: method,
                paramsData: paramsData
            )
            return .deferred
        }

        var requestTargets = networkRouting.requestTargets(for: requestID)
        if method == "Network.requestWillBeSent", requestTargets == nil {
            requestTargets = networkRequestTargets(
                frameID: params.frameId,
                targetID: params.targetId
            )
            if let requestTargets {
                networkRouting.record(requestTargets, for: requestID)
            } else {
                networkRouting.deferEvent(
                    requestID: requestID,
                    frameID: params.frameId,
                    targetID: params.targetId,
                    method: method,
                    paramsData: paramsData
                )
                return .deferred
            }
        } else if requestTargets == nil {
            requestTargets = networkRequestTargets(
                frameID: params.frameId,
                targetID: params.targetId
            )
            guard let requestTargets else {
                networkRouting.deferEvent(
                    requestID: requestID,
                    frameID: params.frameId,
                    targetID: params.targetId,
                    method: method,
                    paramsData: paramsData
                )
                return .deferred
            }
            networkRouting.record(requestTargets, for: requestID)
        }

        if isTerminalEvent {
            networkRouting.removeRequest(requestID)
        }
        return .deliver(TransportNetworkRouting.EventTargets(
            routingTargetID: requestTargets?.routingTargetID,
            stableScopeTargetID: requestTargets?.stableScopeTargetID,
            pageMembership: requestTargets.map {
                $0.belongedToCurrentPage ? .currentPage : .otherPage
            } ?? .unresolved
        ))
    }

    private func networkRequestTargets(
        for targetID: ProtocolTarget.ID
    ) -> TransportNetworkRouting.RequestTargets? {
        guard let target = targetRegistry.target(for: targetID),
              target.kind == .page || target.kind == .frame,
              !target.isProvisional else {
            return nil
        }
        let belongedToCurrentPage = target.kind == .frame
            || targetID == targetRegistry.currentMainPageTargetID
        return TransportNetworkRouting.RequestTargets(
            stableScopeTargetID: target.kind == .page ? nil : targetID,
            routingTargetID: targetID,
            belongedToCurrentPage: belongedToCurrentPage
        )
    }

    private func networkRequestTargets(
        frameID: ProtocolFrame.ID?,
        targetID: ProtocolTarget.ID?
    ) -> TransportNetworkRouting.RequestTargets? {
        if let frameID,
           let resolvedTargetID = targetRegistry.targetID(forFrameID: frameID),
           let targets = networkRequestTargets(for: resolvedTargetID) {
            return targets
        }
        guard let targetID,
              !targetID.rawValue.isEmpty else {
            return nil
        }
        return networkRequestTargets(for: targetID)
    }

    private func emitResolvedDeferredRootNetworkEvents() async {
        var targetsByRequestID: [
            String: TransportNetworkRouting.RequestTargets
        ] = [:]
        for (requestID, identity) in networkRouting.deferredRequestIdentities {
            if let targets = networkRequestTargets(
                frameID: identity.frameID,
                targetID: identity.targetID
            ) {
                targetsByRequestID[requestID] = targets
            }
        }

        for event in networkRouting.resolveDeferredEvents(
            targetsByRequestID: targetsByRequestID
        ) {
            await emit(
                domain: .network,
                method: event.method,
                targetID: event.targets.routingTargetID,
                sourceTargetID: event.targets.routingTargetID,
                networkScopeTargetID: event.targets.stableScopeTargetID,
                networkPageMembership: event.targets.belongedToCurrentPage
                    ? .currentPage
                    : .otherPage,
                paramsData: event.paramsData
            )
            if event.method == "Network.loadingFinished"
                || event.method == "Network.loadingFailed" {
                networkRouting.removeRequest(event.requestID)
            }
        }
    }

    private func sourceTargetIDForRootEvent(
        method: String,
        targetID: ProtocolTarget.ID?
    ) -> ProtocolTarget.ID? {
        switch ProtocolDomain(method: method) {
        case .runtime:
            return targetRegistry.currentMainPageTargetID ?? targetID
        default:
            return targetID
        }
    }

    private func targetIDForTargetEvent(
        method: String,
        deliveredTargetID: ProtocolTarget.ID,
        paramsData: Data
    ) -> ProtocolTarget.ID {
        guard method == "Runtime.executionContextCreated",
              let frameID = (try? TransportMessageParser.decode(RuntimeExecutionContextCreatedParams.self, from: paramsData))?.context.frameId else {
            return deliveredTargetID
        }
        return targetRegistry.resolvedTargetIDForRuntimeContext(deliveredTargetID: deliveredTargetID, frameID: frameID)
    }

    private func targetIDForCSSStyleSheetAdded(paramsData: Data) -> ProtocolTarget.ID? {
        guard let params = try? TransportMessageParser.decode(CSSStyleSheetAddedParams.self, from: paramsData) else {
            return nil
        }
        if let frameID = params.header.frameID {
            guard let targetID = targetRegistry.targetID(forFrameID: frameID),
                  targetRegistry.target(for: targetID)?.isProvisional != true else {
                return nil
            }
            return targetID
        }
        return styleSheetRouting.targetID(for: params.header.styleSheetID) ?? targetRegistry.currentMainPageTargetID
    }

    private func targetIDForCSSStyleSheetID(paramsData: Data) -> ProtocolTarget.ID? {
        guard let params = try? TransportMessageParser.decode(CSSStyleSheetIDParams.self, from: paramsData) else {
            return nil
        }
        if styleSheetRouting.hasUnresolvedStyleSheet(params.styleSheetID) {
            return nil
        }
        return styleSheetRouting.targetID(for: params.styleSheetID)
    }

    private func updateCSSStyleSheetRegistry(
        method: String,
        targetID: ProtocolTarget.ID?,
        paramsData: Data
    ) {
        switch method {
        case "CSS.styleSheetAdded":
            guard let params = try? TransportMessageParser.decode(CSSStyleSheetAddedParams.self, from: paramsData) else {
                return
            }
            if let frameID = params.header.frameID {
                if let resolvedTargetID = targetRegistry.targetID(forFrameID: frameID),
                   targetRegistry.target(for: resolvedTargetID)?.isProvisional != true {
                    styleSheetRouting.recordAdded(
                        styleSheetID: params.header.styleSheetID,
                        frameID: frameID,
                        paramsData: paramsData,
                        resolvedTargetID: resolvedTargetID
                    )
                } else {
                    styleSheetRouting.recordAdded(
                        styleSheetID: params.header.styleSheetID,
                        frameID: frameID,
                        paramsData: paramsData,
                        resolvedTargetID: nil
                    )
                }
                return
            }
            if let resolvedTargetID = targetID {
                styleSheetRouting.recordAdded(
                    styleSheetID: params.header.styleSheetID,
                    frameID: nil,
                    paramsData: paramsData,
                    resolvedTargetID: resolvedTargetID
                )
            }
        case "CSS.styleSheetRemoved":
            guard let params = try? TransportMessageParser.decode(CSSStyleSheetIDParams.self, from: paramsData) else {
                return
            }
            styleSheetRouting.remove(styleSheetID: params.styleSheetID)
        default:
            return
        }
    }

    private func resolvePendingStyleSheets(
        frameID: ProtocolFrame.ID,
        targetID: ProtocolTarget.ID
    ) -> [ResolvedStyleSheetAddedEvent] {
        styleSheetRouting.resolvePending(frameID: frameID, targetID: targetID)
    }

    private func emitResolvedStyleSheetAddedEvents(_ events: [ResolvedStyleSheetAddedEvent]) async {
        guard !events.isEmpty else {
            return
        }
        for event in events {
            await emit(
                domain: .css,
                method: "CSS.styleSheetAdded",
                targetID: event.targetID,
                paramsData: event.paramsData
            )
        }
    }

    private func currentMainPageTarget() throws -> ProtocolTarget.ID {
        guard let currentMainPageTargetID = targetRegistry.currentMainPageTargetID else {
            throw TransportSession.Error.missingMainPageTarget
        }
        return currentMainPageTargetID
    }

    private func allocateCommandID() -> UInt64 {
        nextCommandID &+= 1
        return nextCommandID
    }

    private func emit(
        domain: ProtocolDomain,
        method: String,
        targetID: ProtocolTarget.ID?,
        sourceTargetID: ProtocolTarget.ID? = nil,
        pageBindingTargetID: ProtocolTarget.ID? = nil,
        networkOriginTargetID: ProtocolTarget.ID? = nil,
        networkScopeTargetID: ProtocolTarget.ID? = nil,
        networkPageMembership: ProtocolNetworkPageMembership? = nil,
        rootPageBelongedToCurrentPage: Bool? = nil,
        paramsData: Data,
        destroyedCurrentMainPageTarget: Bool = false,
        destroyedProvisionalTargetInCurrentPageHierarchy: Bool = false,
        detachedCurrentPageFrameTarget: Bool = false
    ) async {
        let eventSequence = eventSequences.recordEvent(domain: domain)
        let resolvedNetworkOriginTargetID = resolveNetworkOriginTargetID(
            domain: domain,
            method: method,
            paramsData: paramsData,
            exactTargetID: networkOriginTargetID
        )
        if networkOriginTargetID == nil {
            removeCompletedNetworkRequestOrigin(method: method, paramsData: paramsData)
        }
        let envelope = ProtocolEvent(
            sequence: eventSequence.sequence,
            domain: domain,
            method: method,
            targetID: targetID,
            sourceTargetID: sourceTargetID,
            pageBindingTargetID: pageBindingTargetID,
            networkOriginTargetID: resolvedNetworkOriginTargetID,
            networkScopeTargetID: networkScopeTargetID,
            networkPageMembership: networkPageMembership,
            rootPageBelongedToCurrentPage: rootPageBelongedToCurrentPage,
            receivedDomainSequences: eventSequence.receivedDomainSequences,
            paramsData: paramsData,
            destroyedCurrentMainPageTarget: destroyedCurrentMainPageTarget,
            destroyedProvisionalTargetInCurrentPageHierarchy: destroyedProvisionalTargetInCurrentPageHierarchy,
            detachedCurrentPageFrameTarget: detachedCurrentPageFrameTarget
        )
        for continuation in eventSubscribers.continuations(for: domain) {
            continuation.yield(envelope)
        }
        for continuation in eventSubscribers.orderedContinuations {
            continuation.yield(envelope)
        }
        await notifyMainPageTargetWaitersIfNeeded(receivedSequence: eventSequence.sequence)
    }

    private func resolveNetworkOriginTargetID(
        domain: ProtocolDomain,
        method: String,
        paramsData: Data,
        exactTargetID: ProtocolTarget.ID?
    ) -> ProtocolTarget.ID? {
        guard domain == .network,
              let params = try? TransportMessageParser.decode(NetworkFrameParams.self, from: paramsData),
              let frameID = params.frameId,
              let loaderID = params.loaderId else {
            return exactTargetID
        }
        let key = TransportNetworkOriginRegistry.FrameLoaderKey(
            frameID: frameID,
            loaderID: loaderID
        )
        let payloadTargetID = params.targetId.flatMap { $0.rawValue.isEmpty ? nil : $0 }
        if exactTargetID == nil,
           let payloadTargetID,
           let payloadTarget = targetRegistry.target(for: payloadTargetID),
           payloadTarget.kind == .page || payloadTarget.kind == .frame {
            networkOriginRegistry.record(targetID: payloadTargetID, for: key)
            if let requestID = params.requestId {
                networkOriginRegistry.targetIDsByRequestID[requestID] = payloadTargetID
            }
            return payloadTargetID
        }
        let deliveredTargetID = exactTargetID ?? payloadTargetID
        let usesRootRequestIdentity = exactTargetID == nil
        let establishesFreshRequest = method == "Network.requestWillBeSent"
            || method == "Network.requestServedFromMemoryCache"
        let exactFrameOwner = deliveredTargetID.flatMap {
            networkFrameOwner(exactTargetID: $0, frameID: frameID)
        }
        if let exactFrameOwner {
            networkOriginRegistry.record(targetID: exactFrameOwner, for: key)
            if usesRootRequestIdentity, let requestID = params.requestId {
                networkOriginRegistry.targetIDsByRequestID[requestID] = exactFrameOwner
            }
            return exactFrameOwner
        }
        if usesRootRequestIdentity,
           method != "Network.requestWillBeSent",
           method != "Network.requestServedFromMemoryCache",
           let requestID = params.requestId,
           let requestTargetID = networkOriginRegistry.targetIDsByRequestID[requestID] {
            return requestTargetID
        }
        let targetID: ProtocolTarget.ID?
        let recordedTargetIDs = networkOriginRegistry.targetIDsByFrameLoader[key, default: []]
            .filter(targetRegistry.containsTarget)
        if recordedTargetIDs.count == 1 {
            targetID = recordedTargetIDs.first
        } else if recordedTargetIDs.count > 1 {
            targetID = nil
        } else if targetRegistry.hasUnboundProvisionalPageTarget {
            targetID = nil
        } else {
            targetID = targetRegistry.soleTargetID(forFrameID: frameID)
        }
        if usesRootRequestIdentity,
           let requestID = params.requestId,
           establishesFreshRequest {
            networkOriginRegistry.targetIDsByRequestID.removeValue(forKey: requestID)
        }
        if let targetID {
            networkOriginRegistry.record(targetID: targetID, for: key)
            if usesRootRequestIdentity, let requestID = params.requestId {
                networkOriginRegistry.targetIDsByRequestID[requestID] = targetID
            }
        }
        return targetID
    }

    private func removeCompletedNetworkRequestOrigin(method: String, paramsData: Data) {
        guard method == "Network.loadingFinished" || method == "Network.loadingFailed",
              let params = try? TransportMessageParser.decode(NetworkRequestIDParams.self, from: paramsData) else {
            return
        }
        networkOriginRegistry.targetIDsByRequestID.removeValue(forKey: params.requestId)
    }

    private func recordPageNavigationNetworkOrigin(
        method: String,
        targetID: ProtocolTarget.ID?,
        paramsData: Data
    ) {
        guard method == "Page.frameNavigated",
              let params = try? TransportMessageParser.decode(PageFrameNavigatedParams.self, from: paramsData),
              let loaderID = params.frame.loaderId,
              let targetID else {
            return
        }
        let key = TransportNetworkOriginRegistry.FrameLoaderKey(
            frameID: params.frame.id,
            loaderID: loaderID
        )
        networkOriginRegistry.record(targetID: targetID, for: key)
    }

    private func resolvePageBindingTargetID(
        method: String,
        deliveredTargetID: ProtocolTarget.ID?,
        deliveredTargetIsExact: Bool,
        paramsData: Data
    ) -> ProtocolTarget.ID? {
        guard method == "Page.frameNavigated",
              let params = try? TransportMessageParser.decode(PageFrameNavigatedParams.self, from: paramsData) else {
            return nil
        }
        if deliveredTargetIsExact,
           let deliveredTargetID,
           let record = targetRegistry.target(for: deliveredTargetID),
           (record.kind == .page || record.kind == .frame),
           record.frameID == params.frame.id {
            return deliveredTargetID
        }
        let candidateCount = targetRegistry.targetCount(forFrameID: params.frame.id)
        if targetRegistry.hasUnboundProvisionalPageTarget,
           params.frame.id == targetRegistry.currentMainFrameID {
            return nil
        }
        if candidateCount == 1 {
            return targetRegistry.soleTargetID(forFrameID: params.frame.id)
        }
        if candidateCount == 0,
           let deliveredTargetID,
           targetRegistry.target(for: deliveredTargetID)?.kind == .page {
            return deliveredTargetID
        }
        return nil
    }

    private func networkFrameOwner(
        exactTargetID: ProtocolTarget.ID,
        frameID: ProtocolFrame.ID
    ) -> ProtocolTarget.ID? {
        guard let record = targetRegistry.target(for: exactTargetID) else {
            return nil
        }
        if (record.kind == .page || record.kind == .frame),
           record.frameID == frameID {
            return exactTargetID
        }
        guard record.kind == .page else {
            return nil
        }
        let candidateCount = targetRegistry.targetCount(forFrameID: frameID)
        if candidateCount == 0 {
            return exactTargetID
        }
        return targetRegistry.soleTargetID(forFrameID: frameID)
    }

    private func notifyMainPageTargetWaitersIfNeeded(receivedSequence: UInt64) async {
        guard let currentMainPageTargetID = targetRegistry.currentMainPageTargetID,
              !mainPageTargetWaiterStore.isEmpty else {
            return
        }
        let waiters = mainPageTargetWaiterStore.removeAll()
        let result = TransportSession.MainPageTarget(
            targetID: currentMainPageTargetID,
            receivedSequence: receivedSequence
        )
        for waiter in waiters {
            await waiter.fulfill(.success(result))
        }
    }

    private func failMainPageTargetWaiter(_ waiterID: UInt64, error: any Swift.Error) async {
        let waiter = mainPageTargetWaiterStore.remove(id: waiterID)
        await waiter?.fulfill(.failure(error))
    }

    private func removeSubscriber(_ subscriberID: UInt64, domain: ProtocolDomain) {
        eventSubscribers.remove(subscriberID, domain: domain)
    }

    private func removeOrderedSubscriber(_ subscriberID: UInt64) {
        eventSubscribers.removeOrdered(subscriberID)
    }

    private func removePendingReply(_ key: TransportSession.PendingKey) {
        replyStore.removePendingReply(key)
    }

    private func failPendingReply(_ key: TransportSession.PendingKey, error: any Swift.Error) async {
        let pending: TransportSession.PendingReply?
        switch key {
        case let .root(commandID):
            pending = replyStore.removeRootReply(commandID: commandID)
        case let .target(targetReplyKey):
            pending = replyStore.removeTargetReply(for: targetReplyKey)
                ?? replyStore.removeRetargetedReply(commandID: targetReplyKey.commandID)
        }
        await pending?.promise.fulfill(.failure(error))
    }

    private func failPendingReplyFromTimeout(_ key: TransportSession.PendingKey, error: any Swift.Error) async {
        let pending: TransportSession.PendingReply?
        switch key {
        case let .root(commandID):
            pending = replyStore.removeRootReply(commandID: commandID)
        case let .target(targetReplyKey):
            pending = replyStore.removeTargetReplyForTimeout(targetReplyKey)
        }
        await pending?.promise.fulfill(.failure(error))
    }

    private func markTargetReplyAsBufferedIfNeeded(
        _ parsed: ParsedProtocolMessage,
        targetID: ProtocolTarget.ID
    ) {
        guard let commandID = parsed.id else {
            return
        }
        replyStore.markTargetReplyAsBufferedIfNeeded(commandID: commandID, targetID: targetID)
    }
}

private enum LatestRootNetworkEventResolution: Sendable {
    case deliver(TransportNetworkRouting.EventTargets)
    case deferred
}

private struct TransportNetworkRouting: Sendable {
    struct RequestTargets: Equatable, Sendable {
        let stableScopeTargetID: ProtocolTarget.ID?
        var routingTargetID: ProtocolTarget.ID
        let belongedToCurrentPage: Bool
    }

    struct EventTargets: Equatable, Sendable {
        var routingTargetID: ProtocolTarget.ID?
        var stableScopeTargetID: ProtocolTarget.ID?
        var pageMembership: ProtocolNetworkPageMembership
    }

    struct DeferredRequestIdentity: Equatable, Sendable {
        var frameID: ProtocolFrame.ID?
        var targetID: ProtocolTarget.ID?
    }

    struct ResolvedDeferredEvent: Equatable, Sendable {
        var requestID: String
        var method: String
        var paramsData: Data
        var targets: RequestTargets
    }

    private struct DeferredEvent: Equatable, Sendable {
        var requestID: String
        var method: String
        var paramsData: Data
    }

    // ProxyingNetworkAgent rewrites WebProcess resource identifiers through
    // IdentifierRegistry.protocolRequestId(processIdentifier, resourceID)
    // before emitting them. The raw protocol requestId is therefore already
    // the canonical, process-qualified key across the root agent.
    private var requestTargetsByRequestID: [String: RequestTargets] = [:]
    private var deferredRequestIdentitiesByRequestID: [
        String: DeferredRequestIdentity
    ] = [:]
    private var deferredEvents: [DeferredEvent] = []
    private var committedTargetIDsByStableTargetID: [
        ProtocolTarget.ID: ProtocolTarget.ID
    ] = [:]

    func requestTargets(for requestID: String) -> RequestTargets? {
        requestTargetsByRequestID[requestID]
    }

    var deferredRequestIdentities: [String: DeferredRequestIdentity] {
        deferredRequestIdentitiesByRequestID
    }

    func hasDeferredRequest(_ requestID: String) -> Bool {
        deferredRequestIdentitiesByRequestID[requestID] != nil
    }

    func routingTargetID(
        forStableTargetID targetID: ProtocolTarget.ID
    ) -> ProtocolTarget.ID {
        committedTargetIDsByStableTargetID[targetID] ?? targetID
    }

    mutating func record(_ targets: RequestTargets, for requestID: String) {
        requestTargetsByRequestID[requestID] = targets
    }

    mutating func deferEvent(
        requestID: String,
        frameID: ProtocolFrame.ID?,
        targetID: ProtocolTarget.ID?,
        method: String,
        paramsData: Data
    ) {
        var identity = deferredRequestIdentitiesByRequestID[requestID]
            ?? DeferredRequestIdentity(frameID: nil, targetID: nil)
        identity.frameID = identity.frameID ?? frameID
        if identity.targetID == nil,
           let targetID,
           !targetID.rawValue.isEmpty {
            identity.targetID = targetID
        }
        deferredRequestIdentitiesByRequestID[requestID] = identity
        deferredEvents.append(DeferredEvent(
            requestID: requestID,
            method: method,
            paramsData: paramsData
        ))
    }

    mutating func resolveDeferredEvents(
        targetsByRequestID: [String: RequestTargets]
    ) -> [ResolvedDeferredEvent] {
        guard !targetsByRequestID.isEmpty else {
            return []
        }
        for (requestID, targets) in targetsByRequestID {
            requestTargetsByRequestID[requestID] = targets
            deferredRequestIdentitiesByRequestID.removeValue(
                forKey: requestID
            )
        }
        let resolvedRequestIDs = Set(targetsByRequestID.keys)
        let resolvedEvents = deferredEvents.compactMap { event in
            targetsByRequestID[event.requestID].map { targets in
                ResolvedDeferredEvent(
                    requestID: event.requestID,
                    method: event.method,
                    paramsData: event.paramsData,
                    targets: targets
                )
            }
        }
        deferredEvents.removeAll {
            resolvedRequestIDs.contains($0.requestID)
        }
        return resolvedEvents
    }

    mutating func removeRequest(_ requestID: String) {
        requestTargetsByRequestID.removeValue(forKey: requestID)
        deferredRequestIdentitiesByRequestID.removeValue(forKey: requestID)
        deferredEvents.removeAll { $0.requestID == requestID }
    }

    mutating func removeTarget(_ targetID: ProtocolTarget.ID) {
        let deferredRequestIDs = Set(
            deferredRequestIdentitiesByRequestID.compactMap {
                $0.value.targetID == targetID ? $0.key : nil
            }
        )
        for requestID in deferredRequestIDs {
            deferredRequestIdentitiesByRequestID.removeValue(forKey: requestID)
        }
        deferredEvents.removeAll {
            deferredRequestIDs.contains($0.requestID)
        }
        committedTargetIDsByStableTargetID =
            committedTargetIDsByStableTargetID.filter {
                $0.value != targetID
            }
    }

    mutating func removeFrame(_ frameID: ProtocolFrame.ID) {
        let deferredRequestIDs = Set(
            deferredRequestIdentitiesByRequestID.compactMap {
                $0.value.frameID == frameID ? $0.key : nil
            }
        )
        for requestID in deferredRequestIDs {
            deferredRequestIdentitiesByRequestID.removeValue(forKey: requestID)
        }
        deferredEvents.removeAll {
            deferredRequestIDs.contains($0.requestID)
        }
    }

    mutating func retarget(
        from oldTargetID: ProtocolTarget.ID,
        to newTargetID: ProtocolTarget.ID
    ) {
        for requestID in requestTargetsByRequestID.keys where
            requestTargetsByRequestID[requestID]?.routingTargetID == oldTargetID
        {
            requestTargetsByRequestID[requestID]?.routingTargetID = newTargetID
        }
        for requestID in deferredRequestIdentitiesByRequestID.keys where
            deferredRequestIdentitiesByRequestID[requestID]?.targetID
                == oldTargetID
        {
            deferredRequestIdentitiesByRequestID[requestID]?.targetID =
                newTargetID
        }
        for stableTargetID in committedTargetIDsByStableTargetID.keys where
            committedTargetIDsByStableTargetID[stableTargetID] == oldTargetID
        {
            committedTargetIDsByStableTargetID[stableTargetID] = newTargetID
        }
        committedTargetIDsByStableTargetID[oldTargetID] = newTargetID
    }

    mutating func removeAll() {
        requestTargetsByRequestID.removeAll()
        deferredRequestIdentitiesByRequestID.removeAll()
        deferredEvents.removeAll()
        committedTargetIDsByStableTargetID.removeAll()
    }
}

private struct TargetDispatchParams: Decodable {
    var targetId: ProtocolTarget.ID
    var message: String
}

private struct TargetCreatedParams: Decodable {
    var targetInfo: TargetInfoPayload
}

private struct TargetInfoPayload: Decodable {
    var targetId: ProtocolTarget.ID
    var type: String
    var isProvisional: Bool?
    var isPaused: Bool?
}

private struct TargetDestroyedParams: Decodable {
    var targetId: ProtocolTarget.ID
}

private struct TargetCommittedParams: Decodable {
    var oldTargetId: ProtocolTarget.ID?
    var newTargetId: ProtocolTarget.ID
}

private struct RuntimeExecutionContextCreatedParams: Decodable {
    struct Context: Decodable {
        var id: RuntimeContext.ID
        var type: RuntimeContext.Kind?
        var name: String?
        var frameId: ProtocolFrame.ID?
    }

    var context: Context
}

private struct PageFrameNavigatedParams: Decodable {
    struct Frame: Decodable {
        var id: ProtocolFrame.ID
        var parentId: ProtocolFrame.ID?
        var loaderId: String?
    }

    var frame: Frame
}

private struct PageFrameDetachedParams: Decodable {
    var frameId: ProtocolFrame.ID
}

private struct NetworkRequestRoutingParams: Decodable {
    var requestId: String?
    var frameId: ProtocolFrame.ID?
    var targetId: ProtocolTarget.ID?
}

private struct RuntimeExecutionContextDestroyedParams: Decodable {
    var executionContextId: RuntimeContext.ID
}

private struct NetworkFrameParams: Decodable {
    var frameId: ProtocolFrame.ID?
    var loaderId: String?
    var requestId: String?
    var targetId: ProtocolTarget.ID?
}

private struct NetworkRequestIDParams: Decodable {
    var requestId: String
}

private struct TransportNetworkOriginRegistry: Sendable {
    struct FrameLoaderKey: Hashable, Sendable {
        let frameID: ProtocolFrame.ID
        let loaderID: String
    }

    var targetIDsByFrameLoader: [FrameLoaderKey: Set<ProtocolTarget.ID>] = [:]
    var targetIDsByRequestID: [String: ProtocolTarget.ID] = [:]

    mutating func record(targetID: ProtocolTarget.ID, for key: FrameLoaderKey) {
        targetIDsByFrameLoader[key, default: []].insert(targetID)
    }

    mutating func removeTarget(_ targetID: ProtocolTarget.ID) {
        for key in Array(targetIDsByFrameLoader.keys) {
            targetIDsByFrameLoader[key]?.remove(targetID)
            if targetIDsByFrameLoader[key]?.isEmpty == true {
                targetIDsByFrameLoader.removeValue(forKey: key)
            }
        }
        targetIDsByRequestID = targetIDsByRequestID.filter { $0.value != targetID }
    }
}

private struct CSSStyleSheetAddedParams: Decodable {
    var header: Header

    struct Header: Decodable {
        var styleSheetID: String
        var frameID: ProtocolFrame.ID?

        private enum CodingKeys: String, CodingKey {
            case styleSheetID = "styleSheetId"
            case frameID = "frameId"
        }
    }
}

private struct CSSStyleSheetIDParams: Decodable {
    var styleSheetID: String

    private enum CodingKeys: String, CodingKey {
        case styleSheetID = "styleSheetId"
    }
}
