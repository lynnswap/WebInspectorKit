import Foundation

actor WITransportMessageRouter {
    typealias RootDispatcher = @Sendable (_ message: String) async throws -> Void
    typealias PageDispatcher = @Sendable (_ message: String, _ targetIdentifier: String, _ outerIdentifier: Int) async throws -> Void

    private struct PendingRootRequest {
        let method: String
        let continuation: CheckedContinuation<WITransportPayload, Error>
        let timeoutTask: Task<Void, Never>
    }

    private struct PendingPageRequest {
        let method: String
        let outerIdentifier: Int
        let targetIdentifier: String
        let continuation: CheckedContinuation<WITransportPayload, Error>
        let timeoutTask: Task<Void, Never>
    }

    private struct EventSubscription {
        let scope: WITransportTargetScope
        let methods: Set<String>?
        let continuation: AsyncStream<WITransportEventEnvelope>.Continuation
    }

    private struct ParsedMessage {
        let identifier: Int?
        let method: String?
        let paramsPayload: WITransportPayload?
        let resultPayload: WITransportPayload?
        let errorMessage: String?
    }

    private struct KnownTarget {
        let identifier: String
        let type: String
        let isProvisional: Bool
        let creationOrder: Int
    }

    private let configuration: WITransportConfiguration
    private let clock: any Clock<Duration>
    private var rootDispatcher: RootDispatcher?
    private var pageDispatcher: PageDispatcher?
    private var nextIdentifierValue = 1

    private var pendingRootRequests: [Int: PendingRootRequest] = [:]
    private var pendingPageRequests: [Int: PendingPageRequest] = [:]
    private var pageOuterToInnerIdentifiers: [Int: Int] = [:]

    private var subscriptions: [UUID: EventSubscription] = [:]
    private var pageTargetChangeSubscriptions: [UUID: AsyncStream<WITransportPageTargetChange>.Continuation] = [:]
    private var pageTargetLifecycleSubscriptions: [UUID: AsyncStream<WITransportPageTargetLifecycleEvent>.Continuation] = [:]
    private var backlogs: [WITransportTargetScope: [WITransportEventEnvelope]] = [:]
    private var currentPageTargetIdentifier: String?
    private var committedPageTargetIdentifier: String?
    private var knownTargets: [String: KnownTarget] = [:]
    private var nextTargetCreationOrder = 0
    private var pageTargetWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        configuration: WITransportConfiguration,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.configuration = configuration
        self.clock = clock
    }

    func connect(
        rootDispatcher: @escaping RootDispatcher,
        pageDispatcher: @escaping PageDispatcher
    ) {
        self.rootDispatcher = rootDispatcher
        self.pageDispatcher = pageDispatcher
        currentPageTargetIdentifier = nil
        committedPageTargetIdentifier = nil
        knownTargets.removeAll()
        nextTargetCreationOrder = 0
        log("router connected")
    }

    func disconnect() {
        rootDispatcher = nil
        pageDispatcher = nil
        currentPageTargetIdentifier = nil
        committedPageTargetIdentifier = nil
        knownTargets.removeAll()

        for pending in pendingRootRequests.values {
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: WITransportError.transportClosed)
        }
        pendingRootRequests.removeAll()

        for pending in pendingPageRequests.values {
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: WITransportError.transportClosed)
        }
        pendingPageRequests.removeAll()
        pageOuterToInnerIdentifiers.removeAll()

        for waiter in pageTargetWaiters {
            waiter.resume()
        }
        pageTargetWaiters.removeAll()

        for subscription in subscriptions.values {
            subscription.continuation.finish()
        }
        subscriptions.removeAll()
        for continuation in pageTargetChangeSubscriptions.values {
            continuation.finish()
        }
        pageTargetChangeSubscriptions.removeAll()
        for continuation in pageTargetLifecycleSubscriptions.values {
            continuation.finish()
        }
        pageTargetLifecycleSubscriptions.removeAll()
        backlogs.removeAll()

        log("router disconnected")
    }

    func waitForPageTarget(timeout: Duration) async throws {
        if currentPageTargetIdentifier != nil {
            return
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.awaitPageTargetReady()
            }
            group.addTask {
                try await self.clock.sleep(for: timeout)
                throw WITransportError.requestTimedOut(scope: .root, method: "Target.targetCreated")
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }

    func events(
        scope: WITransportTargetScope,
        methods: Set<String>?,
        bufferingLimit: Int?
    ) -> AsyncStream<WITransportEventEnvelope> {
        let limit = max(1, bufferingLimit ?? configuration.eventBufferLimit)
        return AsyncStream(bufferingPolicy: .bufferingNewest(limit)) { continuation in
            let identifier = UUID()
            subscriptions[identifier] = EventSubscription(scope: scope, methods: methods, continuation: continuation)

            if let backlog = backlogs[scope], !backlog.isEmpty {
                for event in backlog where methods == nil || methods?.contains(event.method) == true {
                    continuation.yield(event)
                }
            }

            continuation.onTermination = { _ in
                Task {
                    await self.removeSubscription(identifier)
                }
            }
        }
    }

    func pageTargetChanges(bufferingLimit: Int?) -> AsyncStream<WITransportPageTargetChange> {
        let limit = max(1, bufferingLimit ?? configuration.eventBufferLimit)
        return AsyncStream(bufferingPolicy: .bufferingNewest(limit)) { continuation in
            let identifier = UUID()
            pageTargetChangeSubscriptions[identifier] = continuation
            continuation.onTermination = { _ in
                Task {
                    await self.removePageTargetChangeSubscription(identifier)
                }
            }
        }
    }

    func pageTargetLifecycles(bufferingLimit: Int?) -> AsyncStream<WITransportPageTargetLifecycleEvent> {
        let limit = max(1, bufferingLimit ?? configuration.eventBufferLimit)
        return AsyncStream(bufferingPolicy: .bufferingNewest(limit)) { continuation in
            let identifier = UUID()
            pageTargetLifecycleSubscriptions[identifier] = continuation
            continuation.onTermination = { _ in
                Task {
                    await self.removePageTargetLifecycleSubscription(identifier)
                }
            }
        }
    }

    func send(scope: WITransportTargetScope, method: String, parametersData: Data?) async throws -> WITransportPayload {
        try await send(
            scope: scope,
            method: method,
            parametersPayload: parametersData.map(WITransportPayload.data),
            targetIdentifierOverride: nil
        )
    }

    func send(
        scope: WITransportTargetScope,
        method: String,
        parametersData: Data?,
        targetIdentifierOverride: String?
    ) async throws -> WITransportPayload {
        try await send(
            scope: scope,
            method: method,
            parametersPayload: parametersData.map(WITransportPayload.data),
            targetIdentifierOverride: targetIdentifierOverride
        )
    }

    func send(
        scope: WITransportTargetScope,
        method: String,
        parametersPayload: WITransportPayload?,
        targetIdentifierOverride: String?
    ) async throws -> WITransportPayload {
        switch scope {
        case .root:
            return try await sendRootCommand(method: method, parametersPayload: parametersPayload)
        case .page:
            return try await sendPageCommand(
                method: method,
                parametersPayload: parametersPayload,
                targetIdentifierOverride: targetIdentifierOverride
            )
        }
    }

    func handleIncomingRootMessage(_ messageString: String) {
        handleIncomingRootMessage(messageString, parsedPayload: nil)
    }

    func handleIncomingRootMessage(_ messageString: String, parsedPayload: WITransportPayload?) {
        guard let parsed = parseMessage(messageString, parsedPayload: parsedPayload) else {
            return
        }

        if let identifier = parsed.identifier {
            if completeRootRequestIfPossible(identifier: identifier, parsed: parsed) {
                return
            }
            if completePageOuterRequestIfPossible(identifier: identifier, parsed: parsed) {
                return
            }
        }

        guard let method = parsed.method else {
            return
        }

        updatePageTargetStateIfNeeded(method: method, paramsPayload: parsed.paramsPayload)
        emitEventIfNeeded(
            scope: .root,
            method: method,
            targetIdentifier: nil,
            paramsPayload: parsed.paramsPayload
        )
    }

    func handleIncomingPageMessage(_ messageString: String, targetIdentifier: String) {
        handleIncomingPageMessage(messageString, parsedPayload: nil, targetIdentifier: targetIdentifier)
    }

    func handleIncomingPageMessage(
        _ messageString: String,
        parsedPayload: WITransportPayload?,
        targetIdentifier: String
    ) {
        guard let parsed = parseMessage(messageString, parsedPayload: parsedPayload) else {
            return
        }

        if let identifier = parsed.identifier {
            if completePageInnerRequestIfPossible(identifier: identifier, parsed: parsed) {
                return
            }
        }

        guard let method = parsed.method else {
            return
        }

        emitEventIfNeeded(
            scope: .page,
            method: method,
            targetIdentifier: targetIdentifier,
            paramsPayload: parsed.paramsPayload
        )
    }

    func currentPageTargetIdentifierSnapshot() -> String? {
        currentPageTargetIdentifier
    }

    func pageTargetIdentifiersSnapshot() -> [String] {
        knownTargets.values
            .filter { $0.type == "page" }
            .sorted { lhs, rhs in
                if lhs.identifier == currentPageTargetIdentifier {
                    return true
                }
                if rhs.identifier == currentPageTargetIdentifier {
                    return false
                }
                return lhs.creationOrder > rhs.creationOrder
            }
            .map(\.identifier)
    }

    func sendPageCommandCapturingCurrentTarget(
        method: String,
        parametersData: Data?
    ) async throws -> (targetIdentifier: String, payload: WITransportPayload) {
        try await sendPageCommandCapturingCurrentTarget(
            method: method,
            parametersPayload: parametersData.map(WITransportPayload.data)
        )
    }

    func sendPageCommandCapturingCurrentTarget(
        method: String,
        parametersPayload: WITransportPayload?
    ) async throws -> (targetIdentifier: String, payload: WITransportPayload) {
        guard let targetIdentifier = currentPageTargetIdentifier else {
            throw WITransportError.pageTargetUnavailable
        }

        let payload = try await sendPageCommand(
            method: method,
            parametersPayload: parametersPayload,
            targetIdentifierOverride: targetIdentifier
        )
        return (targetIdentifier, payload)
    }
}

private extension WITransportMessageRouter {
    func awaitPageTargetReady() async {
        if currentPageTargetIdentifier != nil {
            return
        }

        await withCheckedContinuation { continuation in
            pageTargetWaiters.append(continuation)
        }
    }

    func removeSubscription(_ identifier: UUID) {
        subscriptions.removeValue(forKey: identifier)
    }

    func sendRootCommand(method: String, parametersPayload: WITransportPayload?) async throws -> WITransportPayload {
        guard let rootDispatcher else {
            throw WITransportError.notAttached
        }

        let identifier = nextIdentifier()
        let jsonString = try commandJSONString(identifier: identifier, method: method, parametersPayload: parametersPayload)

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = timeoutTask(identifier: identifier, method: method, scope: .root)
            pendingRootRequests[identifier] = PendingRootRequest(
                method: method,
                continuation: continuation,
                timeoutTask: timeoutTask
            )

            Task {
                do {
                    try await rootDispatcher(jsonString)
                } catch {
                    self.failRootRequest(identifier: identifier, error: error)
                }
            }
        }
    }

    func sendPageCommand(
        method: String,
        parametersPayload: WITransportPayload?,
        targetIdentifierOverride: String?
    ) async throws -> WITransportPayload {
        guard let pageDispatcher else {
            throw WITransportError.notAttached
        }
        let resolvedTargetIdentifier = targetIdentifierOverride ?? currentPageTargetIdentifier
        guard let targetIdentifier = resolvedTargetIdentifier else {
            throw WITransportError.pageTargetUnavailable
        }

        log("sending page command method=\(method) target=\(targetIdentifier)")

        let innerIdentifier = nextIdentifier()
        let outerIdentifier = nextIdentifier()
        let innerMessage = try commandJSONString(
            identifier: innerIdentifier,
            method: method,
            parametersPayload: parametersPayload
        )

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = timeoutTask(identifier: innerIdentifier, method: method, scope: .page)
            pendingPageRequests[innerIdentifier] = PendingPageRequest(
                method: method,
                outerIdentifier: outerIdentifier,
                targetIdentifier: targetIdentifier,
                continuation: continuation,
                timeoutTask: timeoutTask
            )
            pageOuterToInnerIdentifiers[outerIdentifier] = innerIdentifier

            Task {
                do {
                    try await pageDispatcher(innerMessage, targetIdentifier, outerIdentifier)
                } catch {
                    self.failPageRequest(innerIdentifier: innerIdentifier, error: error)
                }
            }
        }
    }

    func failRootRequest(identifier: Int, error: Error) {
        guard let pending = pendingRootRequests.removeValue(forKey: identifier) else {
            return
        }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
    }

    func failPageRequest(innerIdentifier: Int, error: Error) {
        guard let pending = pendingPageRequests.removeValue(forKey: innerIdentifier) else {
            return
        }
        pending.timeoutTask.cancel()
        pageOuterToInnerIdentifiers.removeValue(forKey: pending.outerIdentifier)
        pending.continuation.resume(throwing: error)
    }

    func timeoutTask(identifier: Int, method: String, scope: WITransportTargetScope) -> Task<Void, Never> {
        Task {
            do {
                try await clock.sleep(for: configuration.responseTimeout)
            } catch {
                return
            }

            self.timeoutRequest(identifier: identifier, method: method, scope: scope)
        }
    }

    func timeoutRequest(identifier: Int, method: String, scope: WITransportTargetScope) {
        switch scope {
        case .root:
            guard let pending = pendingRootRequests.removeValue(forKey: identifier) else {
                return
            }
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: WITransportError.requestTimedOut(scope: .root, method: method))
        case .page:
            guard let pending = pendingPageRequests.removeValue(forKey: identifier) else {
                return
            }
            pending.timeoutTask.cancel()
            pageOuterToInnerIdentifiers.removeValue(forKey: pending.outerIdentifier)
            pending.continuation.resume(throwing: WITransportError.requestTimedOut(scope: .page, method: method))
        }
    }

    private func completeRootRequestIfPossible(identifier: Int, parsed: ParsedMessage) -> Bool {
        guard let pending = pendingRootRequests.removeValue(forKey: identifier) else {
            return false
        }
        pending.timeoutTask.cancel()

        if let errorMessage = parsed.errorMessage {
            pending.continuation.resume(
                throwing: WITransportError.remoteError(scope: .root, method: pending.method, message: errorMessage)
            )
        } else {
            pending.continuation.resume(returning: parsed.resultPayload ?? .object([:]))
        }
        return true
    }

    private func completePageOuterRequestIfPossible(identifier: Int, parsed: ParsedMessage) -> Bool {
        guard let innerIdentifier = pageOuterToInnerIdentifiers.removeValue(forKey: identifier) else {
            return false
        }
        guard let pending = pendingPageRequests[innerIdentifier] else {
            return true
        }

        if let errorMessage = parsed.errorMessage {
            pending.timeoutTask.cancel()
            pendingPageRequests.removeValue(forKey: innerIdentifier)
            pending.continuation.resume(
                throwing: WITransportError.remoteError(scope: .root, method: "Target.sendMessageToTarget", message: errorMessage)
            )
        }
        return true
    }

    private func completePageInnerRequestIfPossible(identifier: Int, parsed: ParsedMessage) -> Bool {
        guard let pending = pendingPageRequests.removeValue(forKey: identifier) else {
            return false
        }
        pending.timeoutTask.cancel()
        pageOuterToInnerIdentifiers.removeValue(forKey: pending.outerIdentifier)

        if let errorMessage = parsed.errorMessage {
            pending.continuation.resume(
                throwing: WITransportError.remoteError(scope: .page, method: pending.method, message: errorMessage)
            )
        } else {
            pending.continuation.resume(returning: parsed.resultPayload ?? .object([:]))
        }
        return true
    }

    func updatePageTargetStateIfNeeded(method: String, paramsPayload: WITransportPayload?) {
        guard let params = paramsPayload?.dictionaryObject else {
            return
        }

        if method == "Target.targetCreated" {
            let targetInfo = transportDictionary(from: params["targetInfo"])
            let targetType = transportString(from: targetInfo?["type"])
            let targetIdentifier = transportString(from: targetInfo?["targetId"])
            let isProvisional = transportBool(from: targetInfo?["isProvisional"])
            log("target created id=\(targetIdentifier ?? "n/a") type=\(targetType ?? "n/a") provisional=\(String(describing: isProvisional))")

            guard targetInfo != nil, let targetType, let targetIdentifier else {
                return
            }

            knownTargets[targetIdentifier] = KnownTarget(
                identifier: targetIdentifier,
                type: targetType,
                isProvisional: isProvisional == true,
                creationOrder: nextTargetOrder()
            )
            refreshPreferredPageTarget(reason: "targetCreated")
            emitPageTargetLifecycleEvent(
                .created,
                targetIdentifier: targetIdentifier,
                oldTargetIdentifier: nil,
                targetType: targetType,
                isProvisional: isProvisional == true
            )
            return
        }

        if method == "Target.didCommitProvisionalTarget" {
            guard
                let newTargetIdentifier = transportString(from: params["newTargetId"])
            else {
                return
            }

            log("target committed old=\(transportString(from: params["oldTargetId"]) ?? "n/a") new=\(newTargetIdentifier)")

            if let oldTargetIdentifier = transportString(from: params["oldTargetId"]) {
                if var target = knownTargets.removeValue(forKey: oldTargetIdentifier) {
                    target = KnownTarget(
                        identifier: newTargetIdentifier,
                        type: target.type,
                        isProvisional: false,
                        creationOrder: target.creationOrder
                    )
                    knownTargets[newTargetIdentifier] = target
                }
            } else if knownTargets[newTargetIdentifier] == nil {
                knownTargets[newTargetIdentifier] = KnownTarget(
                    identifier: newTargetIdentifier,
                    type: "page",
                    isProvisional: false,
                    creationOrder: nextTargetOrder()
                )
            }

            if let existing = knownTargets[newTargetIdentifier] {
                knownTargets[newTargetIdentifier] = KnownTarget(
                    identifier: existing.identifier,
                    type: existing.type,
                    isProvisional: false,
                    creationOrder: existing.creationOrder
                )
            }

            committedPageTargetIdentifier = newTargetIdentifier
            refreshPreferredPageTarget(reason: "didCommitProvisionalTarget")
            emitPageTargetLifecycleEvent(
                .committedProvisional,
                targetIdentifier: newTargetIdentifier,
                oldTargetIdentifier: transportString(from: params["oldTargetId"]),
                targetType: knownTargets[newTargetIdentifier]?.type ?? "page",
                isProvisional: false
            )
            return
        }

        if method == "Target.targetDestroyed",
           let targetIdentifier = transportString(from: params["targetId"]) {
            let target = knownTargets[targetIdentifier]
            if committedPageTargetIdentifier == targetIdentifier {
                committedPageTargetIdentifier = nil
            }
            knownTargets.removeValue(forKey: targetIdentifier)
            refreshPreferredPageTarget(reason: "targetDestroyed")
            emitPageTargetLifecycleEvent(
                .destroyed,
                targetIdentifier: targetIdentifier,
                oldTargetIdentifier: nil,
                targetType: target?.type ?? "page",
                isProvisional: target?.isProvisional ?? false
            )
        }
    }

    func refreshPreferredPageTarget(reason: String) {
        let selectedTarget = preferredTarget(ofType: "page")
        let previousTargetIdentifier = currentPageTargetIdentifier
        currentPageTargetIdentifier = selectedTarget?.identifier

        guard previousTargetIdentifier != currentPageTargetIdentifier else {
            return
        }

        if let selectedTarget {
            log("selected page target id=\(selectedTarget.identifier) type=\(selectedTarget.type) reason=\(reason)")
            resumePageTargetWaiters()
        } else {
            log("cleared page target reason=\(reason)")
        }

        let change = WITransportPageTargetChange(
            targetIdentifier: selectedTarget?.identifier,
            reason: reason
        )
        for continuation in pageTargetChangeSubscriptions.values {
            continuation.yield(change)
        }
    }

    func removePageTargetChangeSubscription(_ identifier: UUID) {
        pageTargetChangeSubscriptions.removeValue(forKey: identifier)
    }

    func removePageTargetLifecycleSubscription(_ identifier: UUID) {
        pageTargetLifecycleSubscriptions.removeValue(forKey: identifier)
    }

    private func preferredTarget(ofType type: String) -> KnownTarget? {
        let nonProvisionalTargets = knownTargets.values.filter { $0.type == type && !$0.isProvisional }

        if type == "page",
           let committedPageTargetIdentifier,
           let committedTarget = nonProvisionalTargets.first(where: { $0.identifier == committedPageTargetIdentifier }) {
            return committedTarget
        }

        return nonProvisionalTargets
            .sorted { lhs, rhs in
                lhs.creationOrder > rhs.creationOrder
            }
            .first
    }

    func resumePageTargetWaiters() {
        guard !pageTargetWaiters.isEmpty else {
            return
        }

        let waiters = pageTargetWaiters
        pageTargetWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func emitPageTargetLifecycleEvent(
        _ kind: WITransportPageTargetLifecycleKind,
        targetIdentifier: String,
        oldTargetIdentifier: String?,
        targetType: String,
        isProvisional: Bool
    ) {
        let event = WITransportPageTargetLifecycleEvent(
            kind: kind,
            targetIdentifier: targetIdentifier,
            oldTargetIdentifier: oldTargetIdentifier,
            targetType: targetType,
            isProvisional: isProvisional
        )

        for continuation in pageTargetLifecycleSubscriptions.values {
            continuation.yield(event)
        }
    }

    func emitEventIfNeeded(
        scope: WITransportTargetScope,
        method: String,
        targetIdentifier: String?,
        paramsPayload: WITransportPayload?
    ) {
        let matchingSubscriptions = subscriptions.values.filter { subscription in
            guard subscription.scope == scope else {
                return false
            }
            guard let methods = subscription.methods else {
                return true
            }
            return methods.contains(method)
        }

        let shouldBufferForFutureSubscribers = !configuration.dropEventsWithoutSubscribers
        guard !matchingSubscriptions.isEmpty || shouldBufferForFutureSubscribers else {
            return
        }

        let envelope = WITransportEventEnvelope(
            method: method,
            targetScope: scope,
            targetIdentifier: targetIdentifier,
            paramsPayload: paramsPayload ?? .object([:])
        )

        if shouldBufferForFutureSubscribers {
            var backlog = backlogs[scope, default: []]
            backlog.append(envelope)
            if backlog.count > configuration.eventBufferLimit {
                backlog.removeFirst(backlog.count - configuration.eventBufferLimit)
            }
            backlogs[scope] = backlog
        }

        for subscription in matchingSubscriptions {
            subscription.continuation.yield(envelope)
        }
    }

    func commandJSONString(identifier: Int, method: String, parametersPayload: WITransportPayload?) throws -> String {
        var payload: [String: Any] = [
            "id": identifier,
            "method": method,
        ]

        if let parametersPayload {
            let paramsObject = try parametersPayload.jsonObject()
            if transportIsEmptyJSONObject(paramsObject) == false {
                payload["params"] = paramsObject
            }
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [])
            guard let jsonString = String(data: data, encoding: .utf8), !jsonString.isEmpty else {
                throw WITransportError.invalidCommandEncoding("The payload could not be converted to UTF-8.")
            }
            return jsonString
        } catch let error as WITransportError {
            throw error
        } catch {
            throw WITransportError.invalidCommandEncoding(error.localizedDescription)
        }
    }

    private func parseMessage(_ messageString: String, parsedPayload: WITransportPayload?) -> ParsedMessage? {
        let dictionary: [String: Any]
        if let parsedDictionary = parsedPayload?.dictionaryObject {
            dictionary = parsedDictionary
        } else if let data = messageString.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: []),
                  let parsedDictionary = transportDictionary(from: object) {
            dictionary = parsedDictionary
        } else {
            return nil
        }

        return ParsedMessage(
            identifier: identifierValue(dictionary["id"]),
            method: transportString(from: dictionary["method"]),
            paramsPayload: dictionary.keys.contains("params") ? .object(dictionary["params"]) : nil,
            resultPayload: dictionary.keys.contains("result") ? .object(dictionary["result"]) : nil,
            errorMessage: transportString(from: transportDictionary(from: dictionary["error"])?["message"])
        )
    }

    func identifierValue(_ value: Any?) -> Int? {
        transportInt(from: value)
    }

    func nextIdentifier() -> Int {
        defer { nextIdentifierValue += 1 }
        return nextIdentifierValue
    }

    func nextTargetOrder() -> Int {
        defer { nextTargetCreationOrder += 1 }
        return nextTargetCreationOrder
    }

    func log(_ message: String) {
        configuration.logHandler?(message)
    }
}
