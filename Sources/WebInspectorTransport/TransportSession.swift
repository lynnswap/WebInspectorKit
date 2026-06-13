import Foundation

package actor TransportSession {
    package typealias ResponseTimeoutSleep = @Sendable (Duration) async throws -> Void
    package typealias ResponseTimeoutDidFire = @Sendable () async -> Void

    private let backend: any TransportBackend
    private let responseTimeout: Duration?
    private let responseTimeoutSleep: ResponseTimeoutSleep
    private let responseTimeoutDidFire: ResponseTimeoutDidFire
    private var nextCommandID: UInt64
    private var nextSequence: UInt64
    private var lastSequenceByDomain: [ProtocolDomain: UInt64]
    private var nextSubscriberID: UInt64
    private var nextMainPageTargetWaiterID: UInt64
    private var replyStore: TransportReplyStore
    private var mainPageTargetWaiters: [UInt64: ReplyPromise<TransportMainPageTarget>]
    private var targetRegistry: TransportTargetRegistry
    private var provisionalTargetMessagesByTargetID: [ProtocolTargetIdentifier: [ParsedProtocolMessage]]
    private var styleSheetRouting: TransportStyleSheetRouting
    private var runtimeContextRegistry: RuntimeContextRegistry
    private var subscribers: [ProtocolDomain: [UInt64: AsyncStream<ProtocolEventEnvelope>.Continuation]]
    private var orderedSubscribers: [UInt64: AsyncStream<ProtocolEventEnvelope>.Continuation]
    private var inboundMessageQueue: TransportInboundMessageQueue
    private var closed: Bool

    package init(
        backend: any TransportBackend,
        responseTimeout: Duration? = .seconds(5),
        responseTimeoutSleep: ResponseTimeoutSleep? = nil,
        responseTimeoutDidFire: ResponseTimeoutDidFire? = nil
    ) {
        self.backend = backend
        self.responseTimeout = responseTimeout
        self.responseTimeoutSleep = responseTimeoutSleep ?? { try await Task.sleep(for: $0) }
        self.responseTimeoutDidFire = responseTimeoutDidFire ?? {}
        nextCommandID = 0
        nextSequence = 0
        lastSequenceByDomain = [:]
        nextSubscriberID = 0
        nextMainPageTargetWaiterID = 0
        replyStore = TransportReplyStore()
        mainPageTargetWaiters = [:]
        targetRegistry = TransportTargetRegistry()
        provisionalTargetMessagesByTargetID = [:]
        styleSheetRouting = TransportStyleSheetRouting()
        runtimeContextRegistry = RuntimeContextRegistry()
        subscribers = [:]
        orderedSubscribers = [:]
        inboundMessageQueue = TransportInboundMessageQueue()
        closed = false
    }

    private var targetsByID: [ProtocolTargetIdentifier: ProtocolTargetRecord] {
        get { targetRegistry.targetsByID }
        set { targetRegistry.targetsByID = newValue }
    }

    private var frameTargetIDsByFrameID: [DOMFrameIdentifier: ProtocolTargetIdentifier] {
        get { targetRegistry.frameTargetIDsByFrameID }
        set { targetRegistry.frameTargetIDsByFrameID = newValue }
    }

    private var currentMainPageTargetID: ProtocolTargetIdentifier? {
        get { targetRegistry.currentMainPageTargetID }
        set { targetRegistry.currentMainPageTargetID = newValue }
    }

    package func events(for domain: ProtocolDomain) -> AsyncStream<ProtocolEventEnvelope> {
        let pair = AsyncStream<ProtocolEventEnvelope>.makeStream(bufferingPolicy: .unbounded)
        nextSubscriberID &+= 1
        let subscriberID = nextSubscriberID
        subscribers[domain, default: [:]][subscriberID] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeSubscriber(subscriberID, domain: domain)
            }
        }
        return pair.stream
    }

    package func orderedEvents() -> AsyncStream<ProtocolEventEnvelope> {
        let pair = AsyncStream<ProtocolEventEnvelope>.makeStream(bufferingPolicy: .unbounded)
        nextSubscriberID &+= 1
        let subscriberID = nextSubscriberID
        orderedSubscribers[subscriberID] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeOrderedSubscriber(subscriberID)
            }
        }
        return pair.stream
    }

    package func send(_ command: ProtocolCommand) async throws -> ProtocolCommandResult {
        guard !closed else {
            throw TransportError.transportClosed
        }

        switch command.routing {
        case .root:
            return try await sendRoot(command)
        case let .target(targetID):
            guard targetsByID[targetID] != nil else {
                throw TransportError.missingTarget(targetID)
            }
            if let result = transportLocalResult(for: command, targetID: targetID) {
                return result
            }
            return try await sendTarget(command, targetID: targetID)
        case let .octopus(pageTarget):
            let resolvedTarget = try pageTarget ?? currentMainPageTarget()
            guard targetsByID[resolvedTarget] != nil else {
                throw TransportError.missingTarget(resolvedTarget)
            }
            if let result = transportLocalResult(for: command, targetID: resolvedTarget) {
                return result
            }
            return try await sendTarget(command, targetID: resolvedTarget)
        }
    }

    @discardableResult
    package func receiveRootMessage(_ message: String) async -> UInt64 {
        inboundMessageQueue.append(message)
        await drainInboundMessages()
        return nextSequence
    }

    package func detach() async {
        guard !closed else {
            return
        }
        closed = true
        for pending in replyStore.pendingReplies {
            await pending.promise.fulfill(.failure(TransportError.transportClosed))
        }
        for (_, waiter) in mainPageTargetWaiters {
            await waiter.fulfill(.failure(TransportError.transportClosed))
        }
        replyStore.removeAll()
        mainPageTargetWaiters.removeAll()
        provisionalTargetMessagesByTargetID.removeAll()
        for continuations in subscribers.values {
            for continuation in continuations.values {
                continuation.finish()
            }
        }
        for continuation in orderedSubscribers.values {
            continuation.finish()
        }
        subscribers.removeAll()
        orderedSubscribers.removeAll()
        await backend.detach()
    }

    package func waitForCurrentMainPageTarget(timeout: Duration? = nil) async throws -> TransportMainPageTarget {
        guard !closed else {
            throw TransportError.transportClosed
        }
        if let currentMainPageTargetID {
            return TransportMainPageTarget(targetID: currentMainPageTargetID, receivedSequence: nextSequence)
        }

        nextMainPageTargetWaiterID &+= 1
        let waiterID = nextMainPageTargetWaiterID
        let promise = ReplyPromise<TransportMainPageTarget>()
        mainPageTargetWaiters[waiterID] = promise

        let timeoutTask: Task<Void, Never>? = timeout.map { timeout in
            Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                await self.failMainPageTargetWaiter(waiterID, error: TransportError.missingMainPageTarget)
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
                    await self.failMainPageTargetWaiter(waiterID, error: CancellationError())
                }
            }
        } catch {
            mainPageTargetWaiters.removeValue(forKey: waiterID)
            throw error
        }
    }

    package func snapshot() -> TransportSnapshot {
        TransportSnapshot(
            currentMainPageTargetID: currentMainPageTargetID,
            targetsByID: targetsByID,
            frameTargetIDsByFrameID: frameTargetIDsByFrameID,
            executionContextsByKey: runtimeContextRegistry.contextsByKey,
            pendingRootReplyIDs: replyStore.pendingRootReplyIDs,
            pendingTargetReplyKeys: replyStore.pendingTargetReplyKeys
        )
    }

    package func targetIdentifier(forExecutionContext key: RuntimeExecutionContextKey) -> ProtocolTargetIdentifier? {
        runtimeContextRegistry.targetID(for: key)
    }

    package func targetIdentifier(forFrameID frameID: DOMFrameIdentifier) -> ProtocolTargetIdentifier? {
        frameTargetIDsByFrameID[frameID]
    }

    private func sendRoot(_ command: ProtocolCommand) async throws -> ProtocolCommandResult {
        let commandID = allocateCommandID()
        let promise = ReplyPromise<ProtocolCommandResult>()
        replyStore.insertRootReply(TransportPendingReply(
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
        targetID: ProtocolTargetIdentifier
    ) async throws -> ProtocolCommandResult {
        let innerCommandID = allocateCommandID()
        let outerCommandID = allocateCommandID()
        let key = TargetReplyKey(targetID: targetID, commandID: innerCommandID)
        let promise = ReplyPromise<ProtocolCommandResult>()
        replyStore.insertTargetReply(TransportPendingReply(
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
        targetID: ProtocolTargetIdentifier
    ) -> ProtocolCommandResult? {
        guard command.method == "DOM.enable" else {
            return nil
        }
        return ProtocolCommandResult(
            domain: command.domain,
            method: command.method,
            targetID: targetID,
            receivedSequence: nextSequence,
            receivedDomainSequences: lastSequenceByDomain,
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
        _ promise: ReplyPromise<ProtocolCommandResult>,
        timeout key: TransportPendingKey,
        method: String,
        targetID: ProtocolTargetIdentifier?
    ) async throws -> ProtocolCommandResult {
        let timeoutTask: Task<Void, Never>? = responseTimeout.map { responseTimeout in
            let responseTimeoutSleep = self.responseTimeoutSleep
            let responseTimeoutDidFire = self.responseTimeoutDidFire
            return Task {
                do {
                    try await responseTimeoutSleep(responseTimeout)
                } catch {
                    return
                }
                await self.failPendingReplyFromTimeout(
                    key,
                    error: TransportError.replyTimeout(method: method, targetID: targetID)
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

    private func handleTargetMessage(_ parsed: ParsedProtocolMessage, targetID: ProtocolTargetIdentifier) async {
        if targetsByID[targetID]?.isProvisional == true {
            markTargetReplyAsBufferedIfNeeded(parsed, targetID: targetID)
            provisionalTargetMessagesByTargetID[targetID, default: []].append(parsed)
            return
        }

        if let id = parsed.id {
            let key = TargetReplyKey(targetID: targetID, commandID: id)
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

    private func resolve(_ pending: TransportPendingReply, parsed: ParsedProtocolMessage) async {
        if let errorMessage = parsed.errorMessage {
            await pending.promise.fulfill(
                .failure(
                    TransportError.remoteError(
                        method: pending.method,
                        targetID: pending.targetID,
                        message: errorMessage
                    )
                )
            )
            return
        }
        await pending.promise.fulfill(
            .success(
                ProtocolCommandResult(
                    domain: pending.domain,
                    method: pending.method,
                    targetID: pending.targetID,
                    receivedSequence: nextSequence,
                    receivedDomainSequences: lastSequenceByDomain,
                    resultData: parsed.resultData
                )
            )
        )
    }

    private func updateRegistryFromRootEvent(
        method: String,
        targetID: ProtocolTargetIdentifier?,
        sourceTargetID: ProtocolTargetIdentifier?,
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
        targetID: ProtocolTargetIdentifier?,
        sourceTargetID: ProtocolTargetIdentifier? = nil,
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
            let resolvedTargetID = resolvedTargetIDForRuntimeContext(
                deliveredTargetID: targetID,
                frameID: frameID
            )
            let context = RuntimeExecutionContextRecord(
                id: params.context.id,
                targetID: resolvedTargetID,
                runtimeAgentTargetID: sourceTargetID ?? targetID,
                type: params.context.type ?? .normal,
                name: params.context.name ?? "",
                frameID: frameID
            )
            runtimeContextRegistry.record(context)
            if let frameID {
                frameTargetIDsByFrameID[frameID] = resolvedTargetID
            }
        case "Runtime.executionContextDestroyed":
            guard let params = try? TransportMessageParser.decode(RuntimeExecutionContextDestroyedParams.self, from: paramsData) else {
                return
            }
            let runtimeAgentTargetID = sourceTargetID ?? targetID
            runtimeContextRegistry.remove(
                RuntimeExecutionContextKey(
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

    private func applyTargetCreated(_ record: ProtocolTargetRecord) -> [ResolvedStyleSheetAddedEvent] {
        var styleSheetAddedEvents: [ResolvedStyleSheetAddedEvent] = []
        targetsByID[record.id] = record
        if let frameID = record.frameID {
            frameTargetIDsByFrameID[frameID] = record.id
            if !record.isProvisional {
                styleSheetAddedEvents.append(contentsOf: resolvePendingStyleSheets(frameID: frameID, targetID: record.id))
            }
        }
        if currentMainPageTargetID == nil,
           record.kind == .page,
           record.parentFrameID == nil,
           !record.isProvisional {
            currentMainPageTargetID = record.id
        }
        return styleSheetAddedEvents
    }

    private func record(for targetInfo: TargetInfoPayload) -> ProtocolTargetRecord {
        let kind = targetKind(for: targetInfo)
        return ProtocolTargetRecord(
            id: targetInfo.targetId,
            kind: kind,
            frameID: targetInfo.frameId,
            parentFrameID: targetInfo.parentFrameId,
            capabilities: capabilities(for: targetInfo, kind: kind),
            isProvisional: targetInfo.isProvisional ?? false,
            isPaused: targetInfo.isPaused ?? false
        )
    }

    private func capabilities(for targetInfo: TargetInfoPayload, kind: ProtocolTargetKind) -> ProtocolTargetCapabilities {
        ProtocolTargetCapabilities.resolved(for: kind, domainNames: targetInfo.domains)
    }

    private func targetKind(for targetInfo: TargetInfoPayload) -> ProtocolTargetKind {
        let protocolKind = ProtocolTargetKind(protocolType: targetInfo.type)
        guard protocolKind == .page else {
            return protocolKind
        }
        if targetInfo.parentFrameId != nil {
            return .frame
        }
        if let currentMainFrameID,
           let frameID = targetInfo.frameId,
           frameID != currentMainFrameID {
            return .frame
        }
        if currentMainFrameID == nil,
           targetInfo.isProvisional == true {
            return .frame
        }
        return .page
    }

    private var currentMainFrameID: DOMFrameIdentifier? {
        currentMainPageTargetID.flatMap { targetsByID[$0]?.frameID }
    }

    private func resolvedTargetIDForRuntimeContext(
        deliveredTargetID: ProtocolTargetIdentifier,
        frameID: DOMFrameIdentifier?
    ) -> ProtocolTargetIdentifier {
        guard let frameID,
              let existingTargetID = frameTargetIDsByFrameID[frameID],
              targetsByID[existingTargetID]?.kind == .frame,
              targetsByID[deliveredTargetID]?.kind != .frame else {
            return deliveredTargetID
        }
        return existingTargetID
    }

    private func applyTargetDestroyed(_ targetID: ProtocolTargetIdentifier) async {
        targetsByID.removeValue(forKey: targetID)
        provisionalTargetMessagesByTargetID.removeValue(forKey: targetID)
        frameTargetIDsByFrameID = frameTargetIDsByFrameID.filter { $0.value != targetID }
        styleSheetRouting.removeTarget(targetID)
        runtimeContextRegistry.removeTarget(targetID)
        let pendingReplies = replyStore.removeTargetReplies(for: targetID)
        for pending in pendingReplies {
            await pending.promise.fulfill(.failure(TransportError.missingTarget(targetID)))
        }
        if currentMainPageTargetID == targetID {
            currentMainPageTargetID = nil
        }
    }

    private func applyTargetCommitted(
        oldTargetID: ProtocolTargetIdentifier?,
        newTargetID: ProtocolTargetIdentifier
    ) -> [ResolvedStyleSheetAddedEvent] {
        var styleSheetAddedEvents: [ResolvedStyleSheetAddedEvent] = []
        let committedOldTargetID = oldTargetID ?? inferredOldTargetIDForOldlessCommit(newTargetID: newTargetID)
        if let committedOldTargetID {
            moveBufferedProvisionalTargetMessages(from: committedOldTargetID, to: newTargetID)
        }
        if let oldTargetID = committedOldTargetID,
           oldTargetID == currentMainPageTargetID,
           let existingNewRecord = targetsByID[newTargetID],
           !existingNewRecord.isTopLevelPage {
            var committedSubframeRecord = existingNewRecord
            committedSubframeRecord.isProvisional = false
            targetsByID[newTargetID] = committedSubframeRecord
            if let frameID = committedSubframeRecord.frameID {
                frameTargetIDsByFrameID[frameID] = newTargetID
                styleSheetAddedEvents.append(contentsOf: resolvePendingStyleSheets(frameID: frameID, targetID: newTargetID))
            }
            return styleSheetAddedEvents
        }

        let oldRecord = committedOldTargetID.flatMap { targetsByID.removeValue(forKey: $0) }
        guard oldRecord != nil || targetsByID[newTargetID] != nil else {
            return styleSheetAddedEvents
        }

        var newRecord = targetsByID[newTargetID] ?? oldRecord!
        newRecord.id = newTargetID
        newRecord.frameID = newRecord.frameID ?? oldRecord?.frameID
        newRecord.parentFrameID = newRecord.parentFrameID ?? oldRecord?.parentFrameID
        newRecord.isProvisional = false
        targetsByID[newTargetID] = newRecord

        if let oldTargetID = committedOldTargetID {
            replyStore.retargetPendingReplies(from: oldTargetID, to: newTargetID)
            frameTargetIDsByFrameID = frameTargetIDsByFrameID.filter { $0.value != oldTargetID }
            styleSheetRouting.retarget(from: oldTargetID, to: newTargetID)
        }

        if let frameID = newRecord.frameID {
            frameTargetIDsByFrameID[frameID] = newTargetID
            styleSheetAddedEvents.append(contentsOf: resolvePendingStyleSheets(frameID: frameID, targetID: newTargetID))
        }
        if let oldTargetID = committedOldTargetID {
            runtimeContextRegistry.retarget(oldTargetID: oldTargetID, newTargetID: newTargetID)
            if currentMainPageTargetID == oldTargetID,
               newRecord.isTopLevelPage {
                currentMainPageTargetID = newTargetID
            }
        }
        if currentMainPageTargetID == nil,
           newRecord.kind == .page,
           newRecord.parentFrameID == nil {
            currentMainPageTargetID = newTargetID
        }
        return styleSheetAddedEvents
    }

    private func moveBufferedProvisionalTargetMessages(
        from oldTargetID: ProtocolTargetIdentifier,
        to newTargetID: ProtocolTargetIdentifier
    ) {
        guard oldTargetID != newTargetID,
              let messages = provisionalTargetMessagesByTargetID.removeValue(forKey: oldTargetID),
              messages.isEmpty == false else {
            return
        }
        provisionalTargetMessagesByTargetID[newTargetID, default: []].append(contentsOf: messages)
    }

    private func dispatchCommittedProvisionalTargetMessagesIfNeeded(method: String, paramsData: Data) async {
        guard method == "Target.didCommitProvisionalTarget",
              let params = try? TransportMessageParser.decode(TargetCommittedParams.self, from: paramsData),
              let messages = provisionalTargetMessagesByTargetID.removeValue(forKey: params.newTargetId) else {
            return
        }

        for message in messages {
            await handleTargetMessage(message, targetID: params.newTargetId)
        }
    }

    private func inferredOldTargetIDForOldlessCommit(
        newTargetID: ProtocolTargetIdentifier
    ) -> ProtocolTargetIdentifier? {
        if let newRecord = targetsByID[newTargetID],
           newRecord.isProvisional,
           newRecord.isTopLevelPage,
           let currentMainPageTargetID,
           currentMainPageTargetID != newTargetID {
            return currentMainPageTargetID
        }

        guard targetsByID[newTargetID] == nil else {
            return nil
        }

        let provisionalTargetIDs = targetsByID
            .filter { $0.value.isProvisional }
            .map(\.key)
        return provisionalTargetIDs.count == 1 ? provisionalTargetIDs[0] : nil
    }

    private func targetIDForRootEvent(method: String, paramsData: Data) -> ProtocolTargetIdentifier? {
        switch method {
        case "Target.targetCreated":
            return (try? TransportMessageParser.decode(TargetCreatedParams.self, from: paramsData))?.targetInfo.targetId
        case "Target.targetDestroyed":
            return (try? TransportMessageParser.decode(TargetDestroyedParams.self, from: paramsData))?.targetId
        case "Target.didCommitProvisionalTarget":
            return (try? TransportMessageParser.decode(TargetCommittedParams.self, from: paramsData))?.newTargetId
        case "Runtime.executionContextCreated":
            if let frameID = (try? TransportMessageParser.decode(RuntimeExecutionContextCreatedParams.self, from: paramsData))?.context.frameId {
                return frameTargetIDsByFrameID[frameID] ?? currentMainPageTargetID
            }
            return currentMainPageTargetID
        case "CSS.styleSheetAdded":
            return targetIDForCSSStyleSheetAdded(paramsData: paramsData)
        case "CSS.styleSheetChanged", "CSS.styleSheetRemoved":
            return targetIDForCSSStyleSheetID(paramsData: paramsData)
        case "DOM.documentUpdated":
            return nil
        default:
            switch ProtocolDomain(method: method) {
            case .dom, .runtime, .css, .console, .network, .page, .storage:
                return currentMainPageTargetID
            default:
                return nil
            }
        }
    }

    private func sourceTargetIDForRootEvent(
        method: String,
        targetID: ProtocolTargetIdentifier?
    ) -> ProtocolTargetIdentifier? {
        switch ProtocolDomain(method: method) {
        case .runtime:
            return currentMainPageTargetID ?? targetID
        default:
            return targetID
        }
    }

    private func targetIDForTargetEvent(
        method: String,
        deliveredTargetID: ProtocolTargetIdentifier,
        paramsData: Data
    ) -> ProtocolTargetIdentifier {
        guard method == "Runtime.executionContextCreated",
              let frameID = (try? TransportMessageParser.decode(RuntimeExecutionContextCreatedParams.self, from: paramsData))?.context.frameId else {
            return deliveredTargetID
        }
        return resolvedTargetIDForRuntimeContext(deliveredTargetID: deliveredTargetID, frameID: frameID)
    }

    private func targetIDForCSSStyleSheetAdded(paramsData: Data) -> ProtocolTargetIdentifier? {
        guard let params = try? TransportMessageParser.decode(CSSStyleSheetAddedParams.self, from: paramsData) else {
            return nil
        }
        if let frameID = params.header.frameID {
            guard let targetID = frameTargetIDsByFrameID[frameID],
                  targetsByID[targetID]?.isProvisional != true else {
                return nil
            }
            return targetID
        }
        return styleSheetRouting.targetID(for: params.header.styleSheetID) ?? currentMainPageTargetID
    }

    private func targetIDForCSSStyleSheetID(paramsData: Data) -> ProtocolTargetIdentifier? {
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
        targetID: ProtocolTargetIdentifier?,
        paramsData: Data
    ) {
        switch method {
        case "CSS.styleSheetAdded":
            guard let params = try? TransportMessageParser.decode(CSSStyleSheetAddedParams.self, from: paramsData) else {
                return
            }
            if let frameID = params.header.frameID {
                if let resolvedTargetID = frameTargetIDsByFrameID[frameID],
                   targetsByID[resolvedTargetID]?.isProvisional != true {
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
        frameID: DOMFrameIdentifier,
        targetID: ProtocolTargetIdentifier
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

    private func currentMainPageTarget() throws -> ProtocolTargetIdentifier {
        guard let currentMainPageTargetID else {
            throw TransportError.missingMainPageTarget
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
        targetID: ProtocolTargetIdentifier?,
        sourceTargetID: ProtocolTargetIdentifier? = nil,
        paramsData: Data
    ) async {
        nextSequence &+= 1
        lastSequenceByDomain[domain] = nextSequence
        let envelope = ProtocolEventEnvelope(
            sequence: nextSequence,
            domain: domain,
            method: method,
            targetID: targetID,
            sourceTargetID: sourceTargetID,
            receivedDomainSequences: lastSequenceByDomain,
            paramsData: paramsData
        )
        let continuations = subscribers[domain].map { Array($0.values) } ?? []
        for continuation in continuations {
            continuation.yield(envelope)
        }
        for continuation in orderedSubscribers.values {
            continuation.yield(envelope)
        }
        await notifyMainPageTargetWaitersIfNeeded(receivedSequence: nextSequence)
    }

    private func notifyMainPageTargetWaitersIfNeeded(receivedSequence: UInt64) async {
        guard let currentMainPageTargetID,
              !mainPageTargetWaiters.isEmpty else {
            return
        }
        let waiters = mainPageTargetWaiters
        mainPageTargetWaiters.removeAll()
        let result = TransportMainPageTarget(
            targetID: currentMainPageTargetID,
            receivedSequence: receivedSequence
        )
        for waiter in waiters.values {
            await waiter.fulfill(.success(result))
        }
    }

    private func failMainPageTargetWaiter(_ waiterID: UInt64, error: any Error) async {
        let waiter = mainPageTargetWaiters.removeValue(forKey: waiterID)
        await waiter?.fulfill(.failure(error))
    }

    private func removeSubscriber(_ subscriberID: UInt64, domain: ProtocolDomain) {
        subscribers[domain]?.removeValue(forKey: subscriberID)
        if subscribers[domain]?.isEmpty == true {
            subscribers.removeValue(forKey: domain)
        }
    }

    private func removeOrderedSubscriber(_ subscriberID: UInt64) {
        orderedSubscribers.removeValue(forKey: subscriberID)
    }

    private func removePendingReply(_ key: TransportPendingKey) {
        replyStore.removePendingReply(key)
    }

    private func failPendingReply(_ key: TransportPendingKey, error: any Error) async {
        let pending: TransportPendingReply?
        switch key {
        case let .root(commandID):
            pending = replyStore.removeRootReply(commandID: commandID)
        case let .target(targetReplyKey):
            pending = replyStore.removeTargetReply(for: targetReplyKey)
                ?? replyStore.removeRetargetedReply(commandID: targetReplyKey.commandID)
        }
        await pending?.promise.fulfill(.failure(error))
    }

    private func failPendingReplyFromTimeout(_ key: TransportPendingKey, error: any Error) async {
        let pending: TransportPendingReply?
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
        targetID: ProtocolTargetIdentifier
    ) {
        guard let commandID = parsed.id else {
            return
        }
        replyStore.markTargetReplyAsBufferedIfNeeded(commandID: commandID, targetID: targetID)
    }
}

private struct TargetDispatchParams: Decodable {
    var targetId: ProtocolTargetIdentifier
    var message: String
}

private struct TargetCreatedParams: Decodable {
    var targetInfo: TargetInfoPayload
}

private struct TargetInfoPayload: Decodable {
    var targetId: ProtocolTargetIdentifier
    var type: String
    var frameId: DOMFrameIdentifier?
    var parentFrameId: DOMFrameIdentifier?
    var domains: [String]?
    var isProvisional: Bool?
    var isPaused: Bool?

}

private struct TargetDestroyedParams: Decodable {
    var targetId: ProtocolTargetIdentifier
}

private struct TargetCommittedParams: Decodable {
    var oldTargetId: ProtocolTargetIdentifier?
    var newTargetId: ProtocolTargetIdentifier
}

private struct RuntimeExecutionContextCreatedParams: Decodable {
    struct Context: Decodable {
        var id: ExecutionContextID
        var type: RuntimeExecutionContextType?
        var name: String?
        var frameId: DOMFrameIdentifier?
    }

    var context: Context
}

private struct RuntimeExecutionContextDestroyedParams: Decodable {
    var executionContextId: ExecutionContextID
}

private struct CSSStyleSheetAddedParams: Decodable {
    var header: Header

    struct Header: Decodable {
        var styleSheetID: String
        var frameID: DOMFrameIdentifier?

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

private extension ProtocolTargetRecord {
    var isTopLevelPage: Bool {
        kind == .page && parentFrameID == nil
    }
}
