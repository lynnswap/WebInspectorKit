import Foundation

package actor TransportSession {
    package typealias TimeoutSleep = @Sendable (Duration) async throws -> Void
    package typealias ResponseTimeoutDidFire = @Sendable () async -> Void

    private let backend: any TransportBackend
    private let responseTimeout: Duration?
    private let timeoutSleep: TimeoutSleep
    private let responseTimeoutDidFire: ResponseTimeoutDidFire
    private var nextCommandID: UInt64
    private var eventSequences: TransportEventSequenceTracker
    private var replyStore: TransportReplyStore
    private var mainPageTargetWaiterStore: TransportSession.MainPageTargetWaiterStore
    private var targetRegistry: TransportTargetRegistry
    private var provisionalTargetMessageStore: TransportProvisionalTargetMessageStore
    private var styleSheetRouting: TransportStyleSheetRouting
    private var runtimeContextRegistry: RuntimeContextRegistry
    private var eventSubscribers: TransportEventSubscriberRegistry
    private var inboundMessageQueue: TransportInboundMessageQueue
    private var closed: Bool

    package init(
        backend: any TransportBackend,
        responseTimeout: Duration? = .seconds(5),
        timeoutSleep: TimeoutSleep? = nil,
        responseTimeoutDidFire: ResponseTimeoutDidFire? = nil
    ) {
        self.backend = backend
        self.responseTimeout = responseTimeout
        self.timeoutSleep = timeoutSleep ?? { try await Task.sleep(for: $0) }
        self.responseTimeoutDidFire = responseTimeoutDidFire ?? {}
        nextCommandID = 0
        eventSequences = TransportEventSequenceTracker()
        replyStore = TransportReplyStore()
        mainPageTargetWaiterStore = TransportSession.MainPageTargetWaiterStore()
        targetRegistry = TransportTargetRegistry()
        provisionalTargetMessageStore = TransportProvisionalTargetMessageStore()
        styleSheetRouting = TransportStyleSheetRouting()
        runtimeContextRegistry = RuntimeContextRegistry()
        eventSubscribers = TransportEventSubscriberRegistry()
        inboundMessageQueue = TransportInboundMessageQueue()
        closed = false
    }

    package func events(for domain: ProtocolDomain) -> AsyncStream<ProtocolEvent> {
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
        guard !closed else {
            throw TransportSession.Error.transportClosed
        }

        switch command.routing {
        case .root:
            return try await sendRoot(command)
        case let .target(targetID):
            guard targetRegistry.containsTarget(targetID) else {
                throw TransportSession.Error.missingTarget(targetID)
            }
            if let result = transportLocalResult(for: command, targetID: targetID) {
                return result
            }
            return try await sendTarget(command, targetID: targetID)
        case let .octopus(pageTarget):
            let resolvedTarget = try pageTarget ?? currentMainPageTarget()
            guard targetRegistry.containsTarget(resolvedTarget) else {
                throw TransportSession.Error.missingTarget(resolvedTarget)
            }
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
            executionContextsByKey: runtimeContextRegistry.contextsByKey,
            pendingRootReplyIDs: replyStore.pendingRootReplyIDs,
            pendingTargetReplyKeys: replyStore.pendingTargetReplyKeys
        )
    }

    package func targetID(forExecutionContext key: RuntimeContext.Key) -> ProtocolTarget.ID? {
        runtimeContextRegistry.targetID(for: key)
    }

    package func targetID(forFrameID frameID: ProtocolFrame.ID) -> ProtocolTarget.ID? {
        targetRegistry.targetID(forFrameID: frameID)
    }

    private func sendRoot(_ command: ProtocolCommand) async throws -> ProtocolCommand.Result {
        let commandID = allocateCommandID()
        let promise = ReplyPromise<ProtocolCommand.Result>()
        replyStore.insertRootReply(TransportSession.PendingReply(
            domain: command.domain,
            method: command.method,
            targetID: nil,
            promise: promise,
            hasBufferedProvisionalResponse: false
        ), commandID: commandID)
        do {
            let message = try TransportMessageParser.makeCommandString(
                id: commandID,
                method: command.method,
                parametersData: command.parametersData
            )
            try await backend.sendJSONString(message)
        } catch {
            _ = replyStore.removeRootReply(commandID: commandID)
            await promise.fulfill(.failure(error))
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
        } catch {
            _ = replyStore.removeTargetReply(for: key)
            await promise.fulfill(.failure(error))
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
            guard let parsed = try? await TransportMessageParser.parse(rawMessage) else {
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
            guard let targetMessage = try? await TransportMessageParser.parse(dispatch.message) else {
                return
            }
            await handleTargetMessage(targetMessage, targetID: dispatch.targetId)
            return
        }

        let targetID = targetIDForRootEvent(method: method, paramsData: parsed.paramsData)
        let sourceTargetID = sourceTargetIDForRootEvent(method: method, targetID: targetID)
        let pendingStyleSheetAddedEvents = await updateRegistryFromRootEvent(
            method: method,
            targetID: targetID,
            sourceTargetID: sourceTargetID,
            paramsData: parsed.paramsData
        )
        await emit(
            domain: ProtocolDomain(method: method),
            method: method,
            targetID: targetID,
            sourceTargetID: sourceTargetID,
            paramsData: parsed.paramsData
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
                  let targetMessage = try? await TransportMessageParser.parse(dispatch.message) else {
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
        updateRegistryFromTargetEvent(
            method: method,
            targetID: emittedTargetID,
            sourceTargetID: targetID,
            paramsData: parsed.paramsData
        )
        await emit(
            domain: ProtocolDomain(method: method),
            method: method,
            targetID: emittedTargetID,
            sourceTargetID: targetID,
            paramsData: parsed.paramsData
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
    ) async -> [ResolvedStyleSheetAddedEvent] {
        switch method {
        case "Target.targetCreated":
            guard let params = try? TransportMessageParser.decode(TargetCreatedParams.self, from: paramsData) else {
                return []
            }
            return applyTargetCreated(record(for: params.targetInfo))
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

    private func record(for targetInfo: TargetInfoPayload) -> ProtocolTarget.Record {
        let kind = targetRegistry.targetKind(
            protocolType: targetInfo.type,
            frameID: targetInfo.frameId,
            parentFrameID: targetInfo.parentFrameId,
            isProvisional: targetInfo.isProvisional
        )
        return ProtocolTarget.Record(
            id: targetInfo.targetId,
            kind: kind,
            frameID: targetInfo.frameId,
            parentFrameID: targetInfo.parentFrameId,
            capabilities: capabilities(for: targetInfo, kind: kind),
            isProvisional: targetInfo.isProvisional ?? false,
            isPaused: targetInfo.isPaused ?? false
        )
    }

    private func capabilities(for targetInfo: TargetInfoPayload, kind: ProtocolTarget.Kind) -> ProtocolTarget.Capabilities {
        ProtocolTarget.Capabilities.resolved(for: kind, domainNames: targetInfo.domains)
    }

    private func applyTargetDestroyed(_ targetID: ProtocolTarget.ID) async {
        targetRegistry.removeTarget(targetID)
        provisionalTargetMessageStore.removeTarget(targetID)
        styleSheetRouting.removeTarget(targetID)
        runtimeContextRegistry.removeTarget(targetID)
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
        paramsData: Data
    ) async {
        let eventSequence = eventSequences.recordEvent(domain: domain)
        let envelope = ProtocolEvent(
            sequence: eventSequence.sequence,
            domain: domain,
            method: method,
            targetID: targetID,
            sourceTargetID: sourceTargetID,
            receivedDomainSequences: eventSequence.receivedDomainSequences,
            paramsData: paramsData
        )
        for continuation in eventSubscribers.continuations(for: domain) {
            continuation.yield(envelope)
        }
        for continuation in eventSubscribers.orderedContinuations {
            continuation.yield(envelope)
        }
        await notifyMainPageTargetWaitersIfNeeded(receivedSequence: eventSequence.sequence)
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
    var frameId: ProtocolFrame.ID?
    var parentFrameId: ProtocolFrame.ID?
    var domains: [String]?
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

private struct RuntimeExecutionContextDestroyedParams: Decodable {
    var executionContextId: RuntimeContext.ID
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
