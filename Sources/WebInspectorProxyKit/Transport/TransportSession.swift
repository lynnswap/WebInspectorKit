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
        orderedEventFeed().events
    }

    package func orderedEventFeed() -> ProtocolOrderedEventFeed {
        guard !closed else {
            return ProtocolOrderedEventFeed(
                initialSequence: eventSequences.current.sequence,
                events: finishedStream(of: ProtocolEvent.self)
            )
        }
        let pair = AsyncStream<ProtocolEvent>.makeStream(bufferingPolicy: .unbounded)
        let subscriberID = eventSubscribers.insertOrdered(pair.continuation)
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeOrderedSubscriber(subscriberID)
            }
        }
        return ProtocolOrderedEventFeed(
            initialSequence: eventSequences.current.sequence,
            events: pair.stream
        )
    }

    package func send(_ command: ProtocolCommand) async throws -> ProtocolCommand.Result {
        try Task.checkCancellation()
        guard !closed else {
            throw TransportSession.Error.transportClosed
        }

        if isLatestRootNetworkCommand(command) {
            let semanticTargetID: ProtocolTarget.ID?
            switch command.routing {
            case .root:
                semanticTargetID = nil
            case let .target(targetID):
                semanticTargetID = networkRouting.routingTargetID(
                    forStableTargetID: targetID
                )
            case let .octopus(pageTarget):
                semanticTargetID = try pageTarget ?? currentMainPageTarget()
            }
            return try await sendRoot(
                command,
                semanticTargetID: semanticTargetID
            )
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
            pending.promise.fulfill(.failure(TransportSession.Error.transportClosed))
        }
        for waiter in mainPageTargetWaiterStore.removeAll() {
            waiter.fulfill(.failure(TransportSession.Error.transportClosed))
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
                self.failMainPageTargetWaiter(waiter.id, error: TransportSession.Error.missingMainPageTarget)
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
            failPendingReply(.root(commandID), error: error)
            throw error
        }
        return try await awaitReply(
            promise,
            timeout: .root(commandID),
            method: command.method,
            targetID: nil
        )
    }

    private func isLatestRootNetworkCommand(
        _ command: ProtocolCommand
    ) -> Bool {
        guard protocolProfile.generation == .latest,
              command.domain == .network,
              command.method == "Network.getResponseBody",
              let params = try? TransportMessageParser.decode(
                  NetworkRequestIDParams.self,
                  from: command.parametersData
              ) else {
            return false
        }
        return isProcessQualifiedNetworkRequestID(params.requestId)
    }

    private func isProcessQualifiedNetworkRequestID(_ requestID: String) -> Bool {
        let prefix = "request-"
        guard requestID.hasPrefix(prefix) else {
            return false
        }
        let components = requestID
            .dropFirst(prefix.count)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2,
              let processID = UInt64(components[0]),
              String(processID) == components[0],
              let resourceID = UInt64(components[1]),
              String(resourceID) == components[1] else {
            return false
        }
        return true
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
            failPendingReply(.target(key), error: error)
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
            failPendingReply(key, error: CancellationError())
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
                resolve(pending, parsed: parsed)
            }
            return
        }

        if let id = parsed.id,
           let pending = replyStore.removeRootReply(commandID: id) {
            resolve(pending, parsed: parsed)
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
        let isLatestRootNetworkEvent = protocolProfile.generation == .latest
            && domain == .network
        // Do not scope or defer these events by frame topology. WebKit's
        // page-owned ProxyingNetworkAgent has already process-qualified the
        // requestId; frame and target fields are lifecycle metadata only.
        let targetID = isLatestRootNetworkEvent
            ? targetRegistry.currentMainPageTargetID
            : targetIDForRootEvent(method: method, paramsData: parsed.paramsData)
        let sourceTargetID = sourceTargetIDForRootEvent(method: method, targetID: targetID)
        let destroyedCurrentMainPageTarget = method == "Target.targetDestroyed"
            && targetID != nil
            && targetID == targetRegistry.currentMainPageTargetID
        let destroyedProvisionalTargetInCurrentPageHierarchy = method == "Target.targetDestroyed"
            && targetID.map { targetRegistry.isProvisionalTargetInCurrentPage($0) } == true
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
            pendingStyleSheetAddedEvents = try updateRegistryFromRootEvent(
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
        // These proxying agents are installed by the inspected page's
        // WebPageInspectorController and register IPC receivers for that page
        // in each process. A provisional process is still part of the same
        // semantic current page, not a second inspected page.
        await emit(
            domain: domain,
            method: method,
            targetID: targetID,
            sourceTargetID: sourceTargetID,
            pageBindingTargetID: pageBindingTargetID,
            networkPageMembership: isLatestRootNetworkEvent ? .currentPage : nil,
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
                resolve(pending, parsed: parsed)
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

    private func resolve(_ pending: TransportSession.PendingReply, parsed: ParsedProtocolMessage) {
        if let errorMessage = parsed.errorMessage {
            pending.promise.fulfill(
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
        pending.promise.fulfill(
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
    ) throws -> [ResolvedStyleSheetAddedEvent] {
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
            applyTargetDestroyed(params.targetId)
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

    private func applyTargetDestroyed(_ targetID: ProtocolTarget.ID) {
        targetRegistry.removeTarget(targetID)
        networkOriginRegistry.removeTarget(targetID)
        provisionalTargetMessageStore.removeTarget(targetID)
        styleSheetRouting.removeTarget(targetID)
        runtimeContextRegistry.removeTarget(targetID)
        networkRouting.removeTarget(targetID)
        let pendingReplies = replyStore.removeTargetReplies(for: targetID)
        for pending in pendingReplies {
            pending.promise.fulfill(.failure(TransportSession.Error.missingTarget(targetID)))
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
            targetRecord: targetID.flatMap { targetRegistry.target(for: $0) },
            belongedToCurrentPage: eventBelongsToCurrentPage(targetID: targetID),
            agentScopeTargetID: eventAgentScopeTargetID(
                targetID: sourceTargetID ?? targetID
            ),
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
        notifyMainPageTargetWaitersIfNeeded(receivedSequence: eventSequence.sequence)
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

    private func eventBelongsToCurrentPage(targetID: ProtocolTarget.ID?) -> Bool {
        guard let targetID else {
            return targetRegistry.currentMainPageTargetID != nil
        }
        if targetID == targetRegistry.currentMainPageTargetID {
            return true
        }
        guard let record = targetRegistry.target(for: targetID) else {
            return false
        }
        return record.kind == .frame && !record.isProvisional
    }

    private func eventAgentScopeTargetID(targetID: ProtocolTarget.ID?) -> ProtocolTarget.ID? {
        guard let targetID,
              let record = targetRegistry.target(for: targetID) else {
            return nil
        }
        switch record.kind {
        case .page:
            return nil
        case .frame, .worker, .serviceWorker, .other:
            return targetID
        }
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

    private func notifyMainPageTargetWaitersIfNeeded(receivedSequence: UInt64) {
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
            waiter.fulfill(.success(result))
        }
    }

    private func failMainPageTargetWaiter(_ waiterID: UInt64, error: any Swift.Error) {
        let waiter = mainPageTargetWaiterStore.remove(id: waiterID)
        waiter?.fulfill(.failure(error))
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

    private func failPendingReply(_ key: TransportSession.PendingKey, error: any Swift.Error) {
        let pending: TransportSession.PendingReply?
        switch key {
        case let .root(commandID):
            pending = replyStore.removeRootReply(commandID: commandID)
        case let .target(targetReplyKey):
            pending = replyStore.removeTargetReply(for: targetReplyKey)
                ?? replyStore.removeRetargetedReply(commandID: targetReplyKey.commandID)
        }
        pending?.promise.fulfill(.failure(error))
    }

    private func failPendingReplyFromTimeout(_ key: TransportSession.PendingKey, error: any Swift.Error) {
        let pending: TransportSession.PendingReply?
        switch key {
        case let .root(commandID):
            pending = replyStore.removeRootReply(commandID: commandID)
        case let .target(targetReplyKey):
            pending = replyStore.removeTargetReplyForTimeout(targetReplyKey)
        }
        pending?.promise.fulfill(.failure(error))
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

private struct TransportNetworkRouting: Sendable {
    private var committedTargetIDsByStableTargetID: [
        ProtocolTarget.ID: ProtocolTarget.ID
    ] = [:]

    func routingTargetID(
        forStableTargetID targetID: ProtocolTarget.ID
    ) -> ProtocolTarget.ID {
        committedTargetIDsByStableTargetID[targetID] ?? targetID
    }

    mutating func removeTarget(_ targetID: ProtocolTarget.ID) {
        committedTargetIDsByStableTargetID =
            committedTargetIDsByStableTargetID.filter {
                $0.value != targetID
            }
    }

    mutating func retarget(
        from oldTargetID: ProtocolTarget.ID,
        to newTargetID: ProtocolTarget.ID
    ) {
        for stableTargetID in committedTargetIDsByStableTargetID.keys where
            committedTargetIDsByStableTargetID[stableTargetID] == oldTargetID
        {
            committedTargetIDsByStableTargetID[stableTargetID] = newTargetID
        }
        committedTargetIDsByStableTargetID[oldTargetID] = newTargetID
    }

    mutating func removeAll() {
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
