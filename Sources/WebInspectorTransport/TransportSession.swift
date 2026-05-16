import Foundation
import WebInspectorCore

package actor TransportSession {
    private struct PendingReply: Sendable {
        var domain: ProtocolDomain
        var method: String
        var targetID: ProtocolTargetIdentifier?
        var promise: ReplyPromise<ProtocolCommandResult>
        var hasBufferedProvisionalResponse: Bool
    }

    private let backend: any TransportBackend
    private let responseTimeout: Duration?
    private var nextCommandID: UInt64
    private var nextSequence: UInt64
    private var lastSequenceByDomain: [ProtocolDomain: UInt64]
    private var nextSubscriberID: UInt64
    private var nextMainPageTargetWaiterID: UInt64
    private var rootReplies: [UInt64: PendingReply]
    private var targetReplies: [TargetReplyKey: PendingReply]
    private var targetReplyKeysByRootWrapperID: [UInt64: TargetReplyKey]
    private var mainPageTargetWaiters: [UInt64: ReplyPromise<TransportMainPageTarget>]
    private var targetsByID: [ProtocolTargetIdentifier: ProtocolTargetRecord]
    private var provisionalTargetMessagesByTargetID: [ProtocolTargetIdentifier: [ParsedProtocolMessage]]
    private var frameTargetIDsByFrameID: [DOMFrameIdentifier: ProtocolTargetIdentifier]
    private var styleSheetTargetIDsByStyleSheetID: [CSSStyleSheetIdentifier: ProtocolTargetIdentifier]
    private var unresolvedStyleSheetFrameIDsByStyleSheetID: [CSSStyleSheetIdentifier: DOMFrameIdentifier]
    private var executionContextsByID: [ExecutionContextID: ExecutionContextRecord]
    private var currentMainPageTargetID: ProtocolTargetIdentifier?
    private var subscribers: [ProtocolDomain: [UInt64: AsyncStream<ProtocolEventEnvelope>.Continuation]]
    private var orderedSubscribers: [UInt64: AsyncStream<ProtocolEventEnvelope>.Continuation]
    private var inboundMessages: [String]
    private var isDrainingInboundMessages: Bool
    private var closed: Bool

    package init(backend: any TransportBackend, responseTimeout: Duration? = .seconds(5)) {
        self.backend = backend
        self.responseTimeout = responseTimeout
        nextCommandID = 0
        nextSequence = 0
        lastSequenceByDomain = [:]
        nextSubscriberID = 0
        nextMainPageTargetWaiterID = 0
        rootReplies = [:]
        targetReplies = [:]
        targetReplyKeysByRootWrapperID = [:]
        mainPageTargetWaiters = [:]
        targetsByID = [:]
        provisionalTargetMessagesByTargetID = [:]
        frameTargetIDsByFrameID = [:]
        styleSheetTargetIDsByStyleSheetID = [:]
        unresolvedStyleSheetFrameIDsByStyleSheetID = [:]
        executionContextsByID = [:]
        currentMainPageTargetID = nil
        subscribers = [:]
        orderedSubscribers = [:]
        inboundMessages = []
        isDrainingInboundMessages = false
        closed = false
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
        inboundMessages.append(message)
        await drainInboundMessages()
        return nextSequence
    }

    package func detach() async {
        guard !closed else {
            return
        }
        closed = true
        for (_, pending) in rootReplies {
            await pending.promise.fulfill(.failure(TransportError.transportClosed))
        }
        for (_, pending) in targetReplies {
            await pending.promise.fulfill(.failure(TransportError.transportClosed))
        }
        for (_, waiter) in mainPageTargetWaiters {
            await waiter.fulfill(.failure(TransportError.transportClosed))
        }
        rootReplies.removeAll()
        targetReplies.removeAll()
        targetReplyKeysByRootWrapperID.removeAll()
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
            executionContextsByID: executionContextsByID,
            pendingRootReplyIDs: rootReplies.keys.sorted(),
            pendingTargetReplyKeys: targetReplies.keys.sorted()
        )
    }

    package func targetIdentifier(forExecutionContext contextID: ExecutionContextID) -> ProtocolTargetIdentifier? {
        executionContextsByID[contextID]?.targetID
    }

    package func targetIdentifier(forFrameID frameID: DOMFrameIdentifier) -> ProtocolTargetIdentifier? {
        frameTargetIDsByFrameID[frameID]
    }

    private func sendRoot(_ command: ProtocolCommand) async throws -> ProtocolCommandResult {
        let commandID = allocateCommandID()
        let promise = ReplyPromise<ProtocolCommandResult>()
        rootReplies[commandID] = PendingReply(
            domain: command.domain,
            method: command.method,
            targetID: nil,
            promise: promise,
            hasBufferedProvisionalResponse: false
        )
        do {
            let message = try TransportMessageParser.makeCommandString(
                id: commandID,
                method: command.method,
                parametersData: command.parametersData
            )
            try await backend.sendJSONString(message)
        } catch {
            rootReplies.removeValue(forKey: commandID)
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
        targetReplies[key] = PendingReply(
            domain: command.domain,
            method: command.method,
            targetID: targetID,
            promise: promise,
            hasBufferedProvisionalResponse: false
        )
        targetReplyKeysByRootWrapperID[outerCommandID] = key
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
            _ = removeTargetReply(for: key)
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

    private enum PendingKey: Sendable {
        case root(UInt64)
        case target(TargetReplyKey)
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
        guard !isDrainingInboundMessages else {
            return
        }

        isDrainingInboundMessages = true
        defer {
            isDrainingInboundMessages = false
        }

        while !inboundMessages.isEmpty {
            let rawMessage = inboundMessages.removeFirst()
            guard let parsed = try? await TransportMessageParser.parse(rawMessage) else {
                continue
            }
            await handleRootMessage(parsed)
        }
    }

    private func awaitReply(
        _ promise: ReplyPromise<ProtocolCommandResult>,
        timeout key: PendingKey,
        method: String,
        targetID: ProtocolTargetIdentifier?
    ) async throws -> ProtocolCommandResult {
        let timeoutTask: Task<Void, Never>? = responseTimeout.map { responseTimeout in
            Task {
                do {
                    try await Task.sleep(for: responseTimeout)
                } catch {
                    return
                }
                await self.failPendingReplyFromTimeout(
                    key,
                    error: TransportError.replyTimeout(method: method, targetID: targetID)
                )
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
           let key = targetReplyKeysByRootWrapperID.removeValue(forKey: id) {
            if parsed.errorMessage != nil,
               let pending = removeTargetReply(for: key) {
                await resolve(pending, parsed: parsed)
            }
            return
        }

        if let id = parsed.id,
           let pending = rootReplies.removeValue(forKey: id) {
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
        await updateRegistryFromRootEvent(method: method, targetID: targetID, paramsData: parsed.paramsData)
        await emit(domain: ProtocolDomain(method: method), method: method, targetID: targetID, paramsData: parsed.paramsData)
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
            if let pending = removeTargetReply(for: key) {
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

        updateRegistryFromTargetEvent(method: method, targetID: targetID, paramsData: parsed.paramsData)
        await emit(domain: ProtocolDomain(method: method), method: method, targetID: targetID, paramsData: parsed.paramsData)
    }

    private func resolve(_ pending: PendingReply, parsed: ParsedProtocolMessage) async {
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
        paramsData: Data
    ) async {
        switch method {
        case "Target.targetCreated":
            guard let params = try? TransportMessageParser.decode(TargetCreatedParams.self, from: paramsData) else {
                return
            }
            applyTargetCreated(record(for: params.targetInfo))
        case "Target.targetDestroyed":
            guard let params = try? TransportMessageParser.decode(TargetDestroyedParams.self, from: paramsData) else {
                return
            }
            await applyTargetDestroyed(params.targetId)
        case "Target.didCommitProvisionalTarget":
            guard let params = try? TransportMessageParser.decode(TargetCommittedParams.self, from: paramsData) else {
                return
            }
            applyTargetCommitted(oldTargetID: params.oldTargetId, newTargetID: params.newTargetId)
        case "Runtime.executionContextCreated":
            updateRegistryFromTargetEvent(method: method, targetID: targetID, paramsData: paramsData)
        case "CSS.styleSheetAdded", "CSS.styleSheetRemoved":
            updateCSSStyleSheetRegistry(method: method, targetID: targetID, paramsData: paramsData)
        default:
            break
        }
    }

    private func updateRegistryFromTargetEvent(method: String, targetID: ProtocolTargetIdentifier?, paramsData: Data) {
        guard let targetID else {
            return
        }
        if method == "CSS.styleSheetAdded" || method == "CSS.styleSheetRemoved" {
            updateCSSStyleSheetRegistry(method: method, targetID: targetID, paramsData: paramsData)
            return
        }
        guard method == "Runtime.executionContextCreated",
              let params = try? TransportMessageParser.decode(RuntimeExecutionContextCreatedParams.self, from: paramsData) else {
            return
        }
        let frameID = params.context.frameId
        let resolvedTargetID = resolvedTargetIDForRuntimeContext(
            deliveredTargetID: targetID,
            frameID: frameID
        )
        executionContextsByID[params.context.id] = ExecutionContextRecord(
            id: params.context.id,
            targetID: resolvedTargetID,
            frameID: frameID
        )
        if let frameID {
            frameTargetIDsByFrameID[frameID] = resolvedTargetID
        }
    }

    private func applyTargetCreated(_ record: ProtocolTargetRecord) {
        targetsByID[record.id] = record
        if let frameID = record.frameID {
            frameTargetIDsByFrameID[frameID] = record.id
            resolvePendingStyleSheets(frameID: frameID, targetID: record.id)
        }
        if currentMainPageTargetID == nil,
           record.kind == .page,
           record.parentFrameID == nil,
           !record.isProvisional {
            currentMainPageTargetID = record.id
        }
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
        if let domains = targetInfo.domains {
            return ProtocolTargetCapabilities(domainNames: domains)
        }
        return ProtocolTargetCapabilities.protocolDefault(for: kind)
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
        styleSheetTargetIDsByStyleSheetID = styleSheetTargetIDsByStyleSheetID.filter { $0.value != targetID }
        executionContextsByID = executionContextsByID.filter { $0.value.targetID != targetID }
        let pendingReplies = targetReplies.keys
            .filter { $0.targetID == targetID }
            .compactMap { removeTargetReply(for: $0) }
        for pending in pendingReplies {
            await pending.promise.fulfill(.failure(TransportError.missingTarget(targetID)))
        }
        if currentMainPageTargetID == targetID {
            currentMainPageTargetID = nil
        }
    }

    private func applyTargetCommitted(oldTargetID: ProtocolTargetIdentifier?, newTargetID: ProtocolTargetIdentifier) {
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
                resolvePendingStyleSheets(frameID: frameID, targetID: newTargetID)
            }
            return
        }

        let oldRecord = committedOldTargetID.flatMap { targetsByID.removeValue(forKey: $0) }
        guard oldRecord != nil || targetsByID[newTargetID] != nil else {
            return
        }

        var newRecord = targetsByID[newTargetID] ?? oldRecord!
        newRecord.id = newTargetID
        newRecord.frameID = newRecord.frameID ?? oldRecord?.frameID
        newRecord.parentFrameID = newRecord.parentFrameID ?? oldRecord?.parentFrameID
        newRecord.isProvisional = false
        targetsByID[newTargetID] = newRecord

        if let oldTargetID = committedOldTargetID {
            retargetPendingReplies(from: oldTargetID, to: newTargetID)
            frameTargetIDsByFrameID = frameTargetIDsByFrameID.filter { $0.value != oldTargetID }
            for (styleSheetID, targetID) in styleSheetTargetIDsByStyleSheetID where targetID == oldTargetID {
                styleSheetTargetIDsByStyleSheetID[styleSheetID] = newTargetID
            }
        }

        if let frameID = newRecord.frameID {
            frameTargetIDsByFrameID[frameID] = newTargetID
            resolvePendingStyleSheets(frameID: frameID, targetID: newTargetID)
        }
        if let oldTargetID = committedOldTargetID {
            for (contextID, record) in executionContextsByID where record.targetID == oldTargetID {
                executionContextsByID[contextID] = ExecutionContextRecord(
                    id: record.id,
                    targetID: newTargetID,
                    frameID: record.frameID
                )
            }
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
            case .dom, .runtime, .css, .network, .page, .storage:
                return currentMainPageTargetID
            default:
                return nil
            }
        }
    }

    private func targetIDForCSSStyleSheetAdded(paramsData: Data) -> ProtocolTargetIdentifier? {
        guard let params = try? TransportMessageParser.decode(CSSStyleSheetAddedParams.self, from: paramsData) else {
            return nil
        }
        if let frameID = params.header.frameID,
           frameTargetIDsByFrameID[frameID] == nil {
            return nil
        }
        if let frameID = params.header.frameID {
            return frameTargetIDsByFrameID[frameID]
        }
        return styleSheetTargetIDsByStyleSheetID[params.header.styleSheetID] ?? currentMainPageTargetID
    }

    private func targetIDForCSSStyleSheetID(paramsData: Data) -> ProtocolTargetIdentifier? {
        guard let params = try? TransportMessageParser.decode(CSSStyleSheetIDParams.self, from: paramsData) else {
            return nil
        }
        if unresolvedStyleSheetFrameIDsByStyleSheetID[params.styleSheetID] != nil {
            return nil
        }
        return styleSheetTargetIDsByStyleSheetID[params.styleSheetID]
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
                if let resolvedTargetID = frameTargetIDsByFrameID[frameID] {
                    styleSheetTargetIDsByStyleSheetID[params.header.styleSheetID] = resolvedTargetID
                    unresolvedStyleSheetFrameIDsByStyleSheetID.removeValue(forKey: params.header.styleSheetID)
                } else {
                    styleSheetTargetIDsByStyleSheetID.removeValue(forKey: params.header.styleSheetID)
                    unresolvedStyleSheetFrameIDsByStyleSheetID[params.header.styleSheetID] = frameID
                }
                return
            }
            if let resolvedTargetID = targetID {
                styleSheetTargetIDsByStyleSheetID[params.header.styleSheetID] = resolvedTargetID
                unresolvedStyleSheetFrameIDsByStyleSheetID.removeValue(forKey: params.header.styleSheetID)
            }
        case "CSS.styleSheetRemoved":
            guard let params = try? TransportMessageParser.decode(CSSStyleSheetIDParams.self, from: paramsData) else {
                return
            }
            styleSheetTargetIDsByStyleSheetID.removeValue(forKey: params.styleSheetID)
            unresolvedStyleSheetFrameIDsByStyleSheetID.removeValue(forKey: params.styleSheetID)
        default:
            return
        }
    }

    private func resolvePendingStyleSheets(frameID: DOMFrameIdentifier, targetID: ProtocolTargetIdentifier) {
        let styleSheetIDs = unresolvedStyleSheetFrameIDsByStyleSheetID
            .filter { $0.value == frameID }
            .map(\.key)
        for styleSheetID in styleSheetIDs {
            styleSheetTargetIDsByStyleSheetID[styleSheetID] = targetID
            unresolvedStyleSheetFrameIDsByStyleSheetID.removeValue(forKey: styleSheetID)
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

    private func emit(domain: ProtocolDomain, method: String, targetID: ProtocolTargetIdentifier?, paramsData: Data) async {
        nextSequence &+= 1
        lastSequenceByDomain[domain] = nextSequence
        let envelope = ProtocolEventEnvelope(
            sequence: nextSequence,
            domain: domain,
            method: method,
            targetID: targetID,
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

    private func removePendingReply(_ key: PendingKey) {
        switch key {
        case let .root(commandID):
            rootReplies.removeValue(forKey: commandID)
        case let .target(targetReplyKey):
            _ = removeTargetReply(for: targetReplyKey)
        }
    }

    private func failPendingReply(_ key: PendingKey, error: any Error) async {
        let pending: PendingReply?
        switch key {
        case let .root(commandID):
            pending = rootReplies.removeValue(forKey: commandID)
        case let .target(targetReplyKey):
            pending = removeTargetReply(for: targetReplyKey)
                ?? removeRetargetedReply(commandID: targetReplyKey.commandID)
        }
        await pending?.promise.fulfill(.failure(error))
    }

    private func failPendingReplyFromTimeout(_ key: PendingKey, error: any Error) async {
        let pending: PendingReply?
        switch key {
        case let .root(commandID):
            pending = rootReplies.removeValue(forKey: commandID)
        case let .target(targetReplyKey):
            pending = removeTargetReplyForTimeout(targetReplyKey)
        }
        await pending?.promise.fulfill(.failure(error))
    }

    private func removeTargetReply(for key: TargetReplyKey) -> PendingReply? {
        let pending = targetReplies.removeValue(forKey: key)
        if let wrapperID = targetReplyKeysByRootWrapperID.first(where: { $0.value == key })?.key {
            targetReplyKeysByRootWrapperID.removeValue(forKey: wrapperID)
        }
        return pending
    }

    private func removeTargetReplyForTimeout(_ key: TargetReplyKey) -> PendingReply? {
        if let pending = targetReplies[key] {
            guard !pending.hasBufferedProvisionalResponse else {
                return nil
            }
            return removeTargetReply(for: key)
        }

        guard let retargetedKey = targetReplies.keys.first(where: { $0.commandID == key.commandID }) else {
            return nil
        }
        guard targetReplies[retargetedKey]?.hasBufferedProvisionalResponse != true else {
            return nil
        }
        return removeTargetReply(for: retargetedKey)
    }

    private func markTargetReplyAsBufferedIfNeeded(
        _ parsed: ParsedProtocolMessage,
        targetID: ProtocolTargetIdentifier
    ) {
        guard let commandID = parsed.id else {
            return
        }
        let key = TargetReplyKey(targetID: targetID, commandID: commandID)
        guard var pending = targetReplies[key] else {
            return
        }
        pending.hasBufferedProvisionalResponse = true
        targetReplies[key] = pending
    }

    private func removeRetargetedReply(commandID: UInt64) -> PendingReply? {
        guard let key = targetReplies.keys.first(where: { $0.commandID == commandID }) else {
            return nil
        }
        return removeTargetReply(for: key)
    }

    private func retargetPendingReplies(
        from oldTargetID: ProtocolTargetIdentifier,
        to newTargetID: ProtocolTargetIdentifier
    ) {
        let oldKeys = targetReplies.keys.filter { $0.targetID == oldTargetID }
        for oldKey in oldKeys {
            guard var pending = targetReplies.removeValue(forKey: oldKey) else {
                continue
            }
            let newKey = TargetReplyKey(targetID: newTargetID, commandID: oldKey.commandID)
            pending.targetID = newTargetID
            targetReplies[newKey] = pending
            if let wrapperID = targetReplyKeysByRootWrapperID.first(where: { $0.value == oldKey })?.key {
                targetReplyKeysByRootWrapperID[wrapperID] = newKey
            }
        }
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
        var frameId: DOMFrameIdentifier?
    }

    var context: Context
}

private struct CSSStyleSheetAddedParams: Decodable {
    var header: CSSStyleSheetHeaderPayload
}

private struct CSSStyleSheetHeaderPayload: Decodable {
    var styleSheetID: CSSStyleSheetIdentifier
    var frameID: DOMFrameIdentifier?

    private enum CodingKeys: String, CodingKey {
        case styleSheetID = "styleSheetId"
        case frameID = "frameId"
    }
}

private struct CSSStyleSheetIDParams: Decodable {
    var styleSheetID: CSSStyleSheetIdentifier

    private enum CodingKeys: String, CodingKey {
        case styleSheetID = "styleSheetId"
    }
}

private extension ProtocolTargetRecord {
    var isTopLevelPage: Bool {
        kind == .page && parentFrameID == nil
    }
}
