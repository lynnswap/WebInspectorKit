import Foundation
import WebKit

@MainActor
public final class WITransportSession {
    public enum State: String, Sendable {
        case detached
        case attaching
        case attached
    }

    public private(set) var state: State = .detached
    public private(set) var supportSnapshot: WITransportSupportSnapshot

    private let configuration: WITransportConfiguration
    private let backendFactory: @MainActor (WITransportConfiguration) -> any WITransportPlatformBackend
    private let clock: any Clock<Duration>
    private let replyRegistry = ReplyRegistry()
    private let pageTargetTracker = WITransportPageTargetTracker()

    package var onStateTransitionForTesting: (@MainActor (State) -> Void)?

    private weak var webView: WKWebView?
    private var originalInspectability: Bool?
    private var backend: (any WITransportPlatformBackend)?
    private var backendMessageSink: WITransportSessionMessageSink?

    private var queuedPageEvents: [WITransportEventEnvelope] = []
    private var pageEventStreamContinuation: AsyncStream<WITransportEventEnvelope>.Continuation?
    private var pageEventQueueClosed = true
    private var hasAttachedPageEventConsumer = false

    public convenience init(configuration: WITransportConfiguration = .init()) {
        self.init(configuration: configuration, backendFactory: WITransportPlatformBackendFactory.makeDefaultBackend)
    }

    init(
        configuration: WITransportConfiguration = .init(),
        backendFactory: @escaping @MainActor (WITransportConfiguration) -> any WITransportPlatformBackend,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.configuration = configuration
        self.backendFactory = backendFactory
        self.clock = clock
        self.supportSnapshot = backendFactory(configuration).supportSnapshot
    }

    public func attach(to webView: WKWebView) async throws {
        guard state == .detached else {
            throw WITransportError.alreadyAttached
        }

        let originalInspectability = prepareInspectability(for: webView)
        self.originalInspectability = originalInspectability

        let backend = backendFactory(configuration)
        supportSnapshot = backend.supportSnapshot
        guard backend.supportSnapshot.isSupported else {
            restoreInspectabilityIfNeeded(on: webView, originalValue: originalInspectability)
            self.originalInspectability = nil
            throw WITransportError.unsupported(backend.supportSnapshot.failureReason ?? "inspector backend unavailable")
        }

        transition(to: .attaching)
        self.webView = webView
        self.backend = backend
        resetTransportStateForAttach()

        let messageSink = WITransportSessionMessageSink(session: self)
        backendMessageSink = messageSink

        do {
            try await backend.attach(to: webView, messageSink: messageSink)
            supportSnapshot = backend.supportSnapshot
            guard state == .attaching, self.backend != nil else {
                throw WITransportError.transportClosed
            }

            transition(to: .attached)
            log("attached")
        } catch {
            messageSink.invalidate()
            backend.detach()
            backendMessageSink = nil
            self.backend = nil
            disconnectTransportState()
            self.webView = nil
            transition(to: .detached)
            restoreInspectabilityIfNeeded(on: webView, originalValue: originalInspectability)
            self.originalInspectability = nil

            if case .unsupported = (error as? WITransportError) {
                throw error
            }
            if let error = error as? WITransportError {
                throw error
            }
            throw WITransportError.attachFailed(error.localizedDescription)
        }
    }

    public func detach() {
        guard state != .detached else {
            return
        }

        backend?.detach()
        backendMessageSink?.invalidate()
        backend = nil
        backendMessageSink = nil
        disconnectTransportState()
        restoreInspectabilityIfNeeded()
        webView = nil
        transition(to: .detached)
        log("detached")
    }

    public func waitForPageTarget(timeout: Duration? = nil) async throws -> String {
        try await waitForPageTarget(excluding: nil, timeout: timeout)
    }

    package func waitForReplacementPageTarget(
        after targetIdentifier: String,
        timeout: Duration? = nil
    ) async throws -> String {
        try await waitForPageTarget(excluding: targetIdentifier, timeout: timeout)
    }

    private func waitForPageTarget(
        excluding excludedTargetIdentifier: String?,
        timeout: Duration?
    ) async throws -> String {
        guard backend != nil else {
            throw WITransportError.notAttached
        }

        let resolvedTimeout = timeout ?? configuration.responseTimeout
        let timeoutError = WITransportError.requestTimedOut(
            scope: .root,
            method: "Target.targetCreated"
        )
        var didTimeOut = false
        let waiterTask = Task { @MainActor in
            try await self.pageTargetTracker.waitUntilAvailable(excluding: excludedTargetIdentifier)
        }
        let timeoutTask = Task { [clock] in
            do {
                try await clock.sleep(for: resolvedTimeout)
            } catch {
                return
            }
            await MainActor.run {
                didTimeOut = true
                waiterTask.cancel()
            }
        }

        return try await withTaskCancellationHandler {
            defer {
                timeoutTask.cancel()
            }

            do {
                let identifier = try await waiterTask.value
                timeoutTask.cancel()
                return identifier
            } catch is CancellationError where didTimeOut {
                throw timeoutError
            }
        } onCancel: {
            waiterTask.cancel()
            timeoutTask.cancel()
        }
    }

    package func currentPageTargetIdentifier() -> String? {
        pageTargetTracker.currentIdentifier
    }

    package func pageTargetIdentifiers() -> [String] {
        pageTargetTracker.orderedIdentifiers
    }

    package func sendRootData(
        method: String,
        parametersData: Data? = nil
    ) async throws -> Data {
        guard let backend else {
            throw WITransportError.notAttached
        }

        if let compatibilityResponse = backend.compatibilityResponse(scope: .root, method: method) {
            return compatibilityResponse
        }

        let commandID = replyRegistry.allocateID()
        let message = try commandJSONString(
            identifier: commandID,
            method: method,
            parametersData: parametersData
        )
        return try await awaitReply(id: commandID, scope: .root, isPageCommand: false) {
            try backend.sendRootMessage(message)
        }
    }

    package func sendPageData(
        method: String,
        targetIdentifier: String? = nil,
        parametersData: Data? = nil
    ) async throws -> Data {
        guard let backend else {
            throw WITransportError.notAttached
        }

        let resolvedTargetIdentifier = targetIdentifier ?? pageTargetTracker.currentIdentifier
        guard let resolvedTargetIdentifier else {
            throw WITransportError.pageTargetUnavailable
        }

        if let compatibilityResponse = backend.compatibilityResponse(scope: .page, method: method) {
            return compatibilityResponse
        }

        let commandID = replyRegistry.allocateID()
        let message = try commandJSONString(
            identifier: commandID,
            method: method,
            parametersData: parametersData
        )
        log("sending page command method=\(method) target=\(resolvedTargetIdentifier)")

        return try await awaitReply(id: commandID, scope: .page, isPageCommand: true) {
            try backend.sendPageMessage(
                message,
                targetIdentifier: resolvedTargetIdentifier,
                outerIdentifier: commandID
            )
        }
    }

    package func pageEvents() -> AsyncStream<WITransportEventEnvelope> {
        precondition(pageEventStreamContinuation == nil, "pageEvents() supports only a single consumer.")

        let bufferedEvents = queuedPageEvents
        queuedPageEvents.removeAll(keepingCapacity: true)
        let isClosed = pageEventQueueClosed
        hasAttachedPageEventConsumer = true

        return AsyncStream(bufferingPolicy: .bufferingNewest(configuration.eventBufferLimit)) { continuation in
            self.pageEventStreamContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else {
                    return
                }

                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self.pageEventStreamContinuation = nil
                    }
                } else {
                    Task { @MainActor [weak self] in
                        self?.pageEventStreamContinuation = nil
                    }
                }
            }

            for event in bufferedEvents {
                continuation.yield(event)
            }
            if isClosed {
                continuation.finish()
            }
        }
    }

    fileprivate func handleInboundMessage(_ message: WITransportInboundMessage) {
        switch message {
        case .root(let payload):
            handleIncomingRootMessage(payload)
        case .page(let payload, let targetIdentifier):
            handleIncomingPageMessage(payload, targetIdentifier: targetIdentifier)
        }
    }

    fileprivate func handleBackendFatalFailure(_ message: String) {
        log("transport fatal failure: \(message)")
        guard state != .detached else {
            return
        }

        backend?.detach()
        backend = nil
        backendMessageSink?.invalidate()
        backendMessageSink = nil
        disconnectTransportState()
        restoreInspectabilityIfNeeded()
        webView = nil
        transition(to: .detached)
        originalInspectability = nil
    }
}

private extension WITransportSession {
    func awaitReply(
        id: Int,
        scope: WITransportTargetScope,
        isPageCommand: Bool,
        send: () throws -> Void
    ) async throws -> Data {
        let replyRegistry = self.replyRegistry
        let timeoutTask = Task { [clock, timeout = configuration.responseTimeout] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }

            replyRegistry.resumeIfPending(
                id: id,
                result: .failure(
                    WITransportError.requestTimedOut(
                        scope: scope,
                        method: scope == .root ? "Inspector" : "Target.sendMessageToTarget"
                    )
                )
            )
        }
        defer {
            timeoutTask.cancel()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                replyRegistry.insert(continuation, for: id, isPageCommand: isPageCommand)

                do {
                    try send()
                } catch {
                    replyRegistry.resumeIfPending(id: id, result: .failure(error))
                }
            }
        } onCancel: {
            replyRegistry.resumeIfPending(
                id: id,
                result: .failure(WITransportError.transportClosed)
            )
        }
    }

    func handleIncomingRootMessage(_ messageString: String) {
        guard let parsed = parseMessage(messageString) else {
            return
        }

        if let identifier = parsed.id,
           replyRegistry.containsPendingReply(id: identifier) {
            if replyRegistry.containsPageCommand(id: identifier) {
                if let errorMessage = parsed.errorMessage {
                    replyRegistry.resumeIfPending(
                        id: identifier,
                        result: .failure(
                            WITransportError.remoteError(
                                scope: .root,
                                method: "Target.sendMessageToTarget",
                                message: errorMessage
                            )
                        )
                    )
                }
                return
            }

            if let errorMessage = parsed.errorMessage {
                replyRegistry.resumeIfPending(
                    id: identifier,
                    result: .failure(
                        WITransportError.remoteError(
                            scope: .root,
                            method: "Inspector",
                            message: errorMessage
                        )
                    )
                )
            } else {
                replyRegistry.resumeIfPending(
                    id: identifier,
                    result: .success(dataForJSONObject(parsed.result))
                )
            }
            return
        }

        guard let method = parsed.method else {
            return
        }

        emitSyntheticPageEventIfNeeded(method: method, paramsObject: parsed.params)
    }

    func handleIncomingPageMessage(_ messageString: String, targetIdentifier: String) {
        guard let parsed = parseMessage(messageString) else {
            return
        }

        if let identifier = parsed.id,
           replyRegistry.containsPendingReply(id: identifier) {
            if let errorMessage = parsed.errorMessage {
                replyRegistry.resumeIfPending(
                    id: identifier,
                    result: .failure(
                        WITransportError.remoteError(
                            scope: .page,
                            method: "Inspector",
                            message: errorMessage
                        )
                    )
                )
            } else {
                replyRegistry.resumeIfPending(
                    id: identifier,
                    result: .success(dataForJSONObject(parsed.result))
                )
            }
            return
        }

        guard let method = parsed.method else {
            return
        }

        enqueuePageEvent(
            method: method,
            targetIdentifier: targetIdentifier,
            paramsObject: parsed.params
        )
    }

    func emitSyntheticPageEventIfNeeded(method: String, paramsObject: Any?) {
        guard let params = paramsObject as? [String: Any] else {
            return
        }

        switch method {
        case "Target.targetCreated":
            guard
                let targetInfo = params["targetInfo"] as? [String: Any],
                let targetIdentifier = stringValue(targetInfo["targetId"]),
                stringValue(targetInfo["type"]) == "page"
            else {
                return
            }

            pageTargetTracker.didCreatePageTarget(
                identifier: targetIdentifier,
                isProvisional: boolValue(targetInfo["isProvisional"]) == true
            )
            enqueuePageEvent(
                method: method,
                targetIdentifier: targetIdentifier,
                paramsObject: params
            )

        case "Target.didCommitProvisionalTarget":
            guard let newTargetIdentifier = stringValue(params["newTargetId"]) else {
                return
            }

            let effectiveOldTargetIdentifier = pageTargetTracker.didCommitPageTarget(
                oldIdentifier: stringValue(params["oldTargetId"]),
                newIdentifier: newTargetIdentifier
            )

            var normalizedParams: [String: Any] = ["newTargetId": newTargetIdentifier]
            if let effectiveOldTargetIdentifier {
                normalizedParams["oldTargetId"] = effectiveOldTargetIdentifier
            }

            enqueuePageEvent(
                method: method,
                targetIdentifier: newTargetIdentifier,
                paramsObject: normalizedParams
            )

        case "Target.targetDestroyed":
            guard let targetIdentifier = stringValue(params["targetId"]) else {
                return
            }
            guard pageTargetTracker.didDestroyPageTarget(identifier: targetIdentifier) else {
                return
            }

            enqueuePageEvent(
                method: method,
                targetIdentifier: targetIdentifier,
                paramsObject: params
            )
        default:
            return
        }
    }

    func enqueuePageEvent(
        method: String,
        targetIdentifier: String?,
        paramsObject: Any?
    ) {
        guard !pageEventQueueClosed else {
            return
        }

        let envelope = WITransportEventEnvelope(
            method: method,
            targetScope: .page,
            targetIdentifier: targetIdentifier,
            paramsData: dataForJSONObject(paramsObject)
        )

        if let pageEventStreamContinuation {
            switch pageEventStreamContinuation.yield(envelope) {
            case .enqueued, .dropped:
                return
            case .terminated:
                self.pageEventStreamContinuation = nil
            @unknown default:
                self.pageEventStreamContinuation = nil
            }
        }

        if !hasAttachedPageEventConsumer || !configuration.dropEventsWithoutSubscribers {
            queuedPageEvents.append(envelope)
            if queuedPageEvents.count > configuration.eventBufferLimit {
                queuedPageEvents.removeFirst(queuedPageEvents.count - configuration.eventBufferLimit)
            }
        }
    }

    func resetTransportStateForAttach() {
        replyRegistry.reset()
        pageTargetTracker.reset()
        queuedPageEvents.removeAll(keepingCapacity: true)
        pageEventStreamContinuation = nil
        pageEventQueueClosed = false
        hasAttachedPageEventConsumer = false
    }

    func disconnectTransportState() {
        replyRegistry.resumeAllTransportClosed()
        pageTargetTracker.failWaiters(WITransportError.transportClosed)
        pageTargetTracker.reset()
        closePageEventQueue()
    }

    func closePageEventQueue() {
        guard !pageEventQueueClosed else {
            return
        }

        pageEventQueueClosed = true
        queuedPageEvents.removeAll(keepingCapacity: false)
        let continuation = pageEventStreamContinuation
        pageEventStreamContinuation = nil
        continuation?.finish()
    }

    func parseMessage(
        _ messageString: String
    ) -> (id: Int?, method: String?, params: Any?, result: Any?, errorMessage: String?)? {
        guard let data = messageString.data(using: .utf8) else {
            return nil
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: data, options: []),
            let dictionary = object as? [String: Any]
        else {
            return nil
        }

        return (
            id: identifierValue(dictionary["id"]),
            method: stringValue(dictionary["method"]),
            params: dictionary["params"],
            result: dictionary["result"],
            errorMessage: stringValue((dictionary["error"] as? [String: Any])?["message"])
        )
    }

    func commandJSONString(identifier: Int, method: String, parametersData: Data?) throws -> String {
        var payload: [String: Any] = [
            "id": identifier,
            "method": method,
        ]

        if let parametersData, !parametersData.isEmpty {
            payload["params"] = try jsonObject(from: parametersData)
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

    func jsonObject(from data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw WITransportError.invalidCommandEncoding(error.localizedDescription)
        }
    }

    func dataForJSONObject(_ object: Any?) -> Data {
        guard let object else {
            return Data("{}".utf8)
        }

        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: []) {
            return data
        }
        if object is NSNull {
            return Data("{}".utf8)
        }
        return Data("{}".utf8)
    }

    func identifierValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    func boolValue(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let bool = value as? Bool {
            return bool
        }
        return nil
    }

    func log(_ message: String) {
        configuration.logHandler?("[WebInspectorTransport] \(message)")
    }

    func prepareInspectability(for webView: WKWebView) -> Bool? {
        guard #available(iOS 16.4, macOS 13.3, *) else {
            return nil
        }

        let originalInspectability = webView.isInspectable
        webView.isInspectable = true
        return originalInspectability
    }

    func restoreInspectabilityIfNeeded() {
        guard let webView else {
            originalInspectability = nil
            return
        }
        restoreInspectabilityIfNeeded(on: webView, originalValue: originalInspectability)
    }

    func restoreInspectabilityIfNeeded(on webView: WKWebView, originalValue: Bool?) {
        guard #available(iOS 16.4, macOS 13.3, *), let originalValue else {
            return
        }

        webView.isInspectable = originalValue
    }

    func transition(to newState: State) {
        state = newState
        onStateTransitionForTesting?(newState)
    }
}

private final class ReplyRegistry: @unchecked Sendable {
    private struct State {
        var nextWireID = 1
        var continuationsByID: [Int: CheckedContinuation<Data, Error>] = [:]
        var pageCommandIDs: Set<Int> = []
    }

    private let lock = NSLock()
    private var state = State()

    func allocateID() -> Int {
        lock.withLock {
            defer { state.nextWireID += 1 }
            return state.nextWireID
        }
    }

    func insert(
        _ continuation: CheckedContinuation<Data, Error>,
        for id: Int,
        isPageCommand: Bool
    ) {
        lock.withLock {
            state.continuationsByID[id] = continuation
            if isPageCommand {
                state.pageCommandIDs.insert(id)
            }
        }
    }

    func containsPendingReply(id: Int) -> Bool {
        lock.withLock {
            state.continuationsByID[id] != nil
        }
    }

    func containsPageCommand(id: Int) -> Bool {
        lock.withLock {
            state.pageCommandIDs.contains(id)
        }
    }

    func resumeIfPending(id: Int, result: Result<Data, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            state.pageCommandIDs.remove(id)
            return state.continuationsByID.removeValue(forKey: id)
        }
        guard let continuation else {
            return
        }

        switch result {
        case .success(let data):
            continuation.resume(returning: data)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    func resumeAllTransportClosed() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Data, Error>] in
            let continuations = Array(state.continuationsByID.values)
            state.nextWireID = 1
            state.continuationsByID.removeAll(keepingCapacity: true)
            state.pageCommandIDs.removeAll(keepingCapacity: true)
            return continuations
        }

        for continuation in continuations {
            continuation.resume(throwing: WITransportError.transportClosed)
        }
    }

    func reset() {
        lock.withLock {
            state.nextWireID = 1
            state.continuationsByID.removeAll(keepingCapacity: true)
            state.pageCommandIDs.removeAll(keepingCapacity: true)
        }
    }
}

@MainActor
private final class WITransportPageTargetTracker {
    private struct KnownPageTarget {
        let identifier: String
        let isProvisional: Bool
        let creationOrder: Int
    }

    private struct AvailabilityWaiter {
        let excludedIdentifier: String?
        let continuation: CheckedContinuation<String, Error>
    }

    private var targetsByIdentifier: [String: KnownPageTarget] = [:]
    private var currentIdentifierStorage: String?
    private var committedIdentifierStorage: String?
    private var nextCreationOrder = 0
    private var availabilityWaiters: [UUID: AvailabilityWaiter] = [:]

    var currentIdentifier: String? {
        currentIdentifierStorage
    }

    var orderedIdentifiers: [String] {
        targetsByIdentifier.values
            .sorted { lhs, rhs in
                if lhs.identifier == currentIdentifierStorage {
                    return true
                }
                if rhs.identifier == currentIdentifierStorage {
                    return false
                }
                return lhs.creationOrder > rhs.creationOrder
            }
            .map(\.identifier)
    }

    func didCreatePageTarget(identifier: String, isProvisional: Bool) {
        targetsByIdentifier[identifier] = KnownPageTarget(
            identifier: identifier,
            isProvisional: isProvisional,
            creationOrder: nextCreationOrderValue()
        )
        refreshCurrentIdentifier()
    }

    func didCommitPageTarget(oldIdentifier: String?, newIdentifier: String) -> String? {
        let effectiveOldIdentifier = oldIdentifier ?? inferredCommittedOldIdentifier(excluding: newIdentifier)
        if let effectiveOldIdentifier,
           let previous = targetsByIdentifier.removeValue(forKey: effectiveOldIdentifier) {
            targetsByIdentifier[newIdentifier] = KnownPageTarget(
                identifier: newIdentifier,
                isProvisional: false,
                creationOrder: previous.creationOrder
            )
        } else if let existing = targetsByIdentifier[newIdentifier] {
            targetsByIdentifier[newIdentifier] = KnownPageTarget(
                identifier: newIdentifier,
                isProvisional: false,
                creationOrder: existing.creationOrder
            )
        } else {
            targetsByIdentifier[newIdentifier] = KnownPageTarget(
                identifier: newIdentifier,
                isProvisional: false,
                creationOrder: nextCreationOrderValue()
            )
        }

        committedIdentifierStorage = newIdentifier
        refreshCurrentIdentifier()
        return effectiveOldIdentifier
    }

    func didDestroyPageTarget(identifier: String) -> Bool {
        guard targetsByIdentifier.removeValue(forKey: identifier) != nil else {
            return false
        }
        if committedIdentifierStorage == identifier {
            committedIdentifierStorage = nil
        }
        refreshCurrentIdentifier()
        return true
    }

    func waitUntilAvailable(excluding excludedIdentifier: String? = nil) async throws -> String {
        while true {
            if let currentIdentifierStorage,
               currentIdentifierStorage != excludedIdentifier {
                return currentIdentifierStorage
            }

            let waiterID = UUID()
            let nextIdentifier = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if let currentIdentifierStorage,
                       currentIdentifierStorage != excludedIdentifier {
                        continuation.resume(returning: currentIdentifierStorage)
                        return
                    }
                    availabilityWaiters[waiterID] = AvailabilityWaiter(
                        excludedIdentifier: excludedIdentifier,
                        continuation: continuation
                    )
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelAvailabilityWaiter(id: waiterID)
                }
            }

            if currentIdentifierStorage == nextIdentifier,
               nextIdentifier != excludedIdentifier {
                return nextIdentifier
            }
        }
    }

    func failWaiters(_ error: Error) {
        guard !availabilityWaiters.isEmpty else {
            return
        }
        let waiters = Array(availabilityWaiters.values.map(\.continuation))
        availabilityWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    func reset() {
        targetsByIdentifier.removeAll(keepingCapacity: true)
        currentIdentifierStorage = nil
        committedIdentifierStorage = nil
        nextCreationOrder = 0
        availabilityWaiters.removeAll(keepingCapacity: true)
    }

    private func refreshCurrentIdentifier() {
        let previousIdentifier = currentIdentifierStorage
        currentIdentifierStorage = preferredIdentifier()

        guard previousIdentifier != currentIdentifierStorage else {
            return
        }

        if let currentIdentifierStorage, !availabilityWaiters.isEmpty {
            let waiterIDsToResume = availabilityWaiters.compactMap { waiterID, waiter in
                waiter.excludedIdentifier == currentIdentifierStorage ? nil : waiterID
            }
            let waiters = waiterIDsToResume.compactMap { availabilityWaiters.removeValue(forKey: $0)?.continuation }
            for waiter in waiters {
                waiter.resume(returning: currentIdentifierStorage)
            }
        }
    }

    private func preferredIdentifier() -> String? {
        if let committedIdentifier = committedIdentifierStorage,
           let target = targetsByIdentifier[committedIdentifier],
           !target.isProvisional {
            return committedIdentifier
        }

        return targetsByIdentifier.values
            .filter { !$0.isProvisional }
            .sorted { $0.creationOrder > $1.creationOrder }
            .first?
            .identifier
    }

    private func inferredCommittedOldIdentifier(excluding newIdentifier: String) -> String? {
        let provisionalTargets = targetsByIdentifier.values.filter {
            $0.identifier != newIdentifier && $0.isProvisional
        }
        guard provisionalTargets.count == 1 else {
            return nil
        }
        return provisionalTargets.first?.identifier
    }

    private func nextCreationOrderValue() -> Int {
        defer { nextCreationOrder += 1 }
        return nextCreationOrder
    }

    private func cancelAvailabilityWaiter(id: UUID) {
        guard let waiter = availabilityWaiters.removeValue(forKey: id)?.continuation else {
            return
        }
        waiter.resume(throwing: CancellationError())
    }
}

private final class SessionReference: @unchecked Sendable {
    weak var session: WITransportSession?

    init(_ session: WITransportSession) {
        self.session = session
    }
}

private final class WITransportSessionMessageSink: WITransportBackendMessageSink, @unchecked Sendable {
    private let sessionReference: SessionReference
    private let inboundPump: InboundMessagePump

    init(session: WITransportSession) {
        self.sessionReference = SessionReference(session)
        self.inboundPump = InboundMessagePump(session: session)
    }

    func didReceiveRootMessage(_ message: String) {
        inboundPump.enqueue(.root(message))
    }

    func didReceivePageMessage(_ message: String, targetIdentifier: String) {
        inboundPump.enqueue(.page(message: message, targetIdentifier: targetIdentifier))
    }

    func didReceiveFatalFailure(_ message: String) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                sessionReference.session?.handleBackendFatalFailure(message)
            }
            return
        }

        Task { @MainActor in
            sessionReference.session?.handleBackendFatalFailure(message)
        }
    }

    func waitForPendingMessagesForTesting() async {
        await inboundPump.waitUntilDrained()
    }

    func invalidate() {
        inboundPump.invalidate()
    }
}

private final class InboundMessagePump: @unchecked Sendable {
    private struct State {
        var isActive = true
        var isDraining = false
        var queue: [WITransportInboundMessage] = []
        var readIndex = 0
        var drainWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let sessionReference: SessionReference
    private let stateLock = NSLock()
    private var state = State()

    init(session: WITransportSession) {
        self.sessionReference = SessionReference(session)
    }

    func enqueue(_ message: WITransportInboundMessage) {
        var shouldStartDrain = false

        stateLock.lock()
        if state.isActive {
            state.queue.append(message)
            if !state.isDraining {
                state.isDraining = true
                shouldStartDrain = true
            }
        }
        stateLock.unlock()

        guard shouldStartDrain else {
            return
        }

        if Thread.isMainThread {
            drainPendingMessagesOnMainThreadIfPossible()
            return
        }

        Task.detached { [weak self] in
            await self?.drain()
        }
    }

    func waitUntilDrained() async {
        await MainActor.run {
            drainPendingMessagesOnMainThreadIfPossible()
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stateLock.lock()
            state.drainWaiters.append(continuation)
            stateLock.unlock()
            resumeDrainWaitersIfNeeded()
        }
    }

    func invalidate() {
        stateLock.lock()
        guard state.isActive else {
            stateLock.unlock()
            return
        }
        state.isActive = false
        state.queue.removeAll(keepingCapacity: false)
        state.readIndex = 0
        state.isDraining = false
        let drainWaiters = state.drainWaiters
        state.drainWaiters.removeAll(keepingCapacity: true)
        stateLock.unlock()

        for drainWaiter in drainWaiters {
            drainWaiter.resume()
        }
    }

    private func nextMessage() -> WITransportInboundMessage? {
        stateLock.lock()
        let result: WITransportInboundMessage?
        if state.readIndex < state.queue.count {
            result = state.queue[state.readIndex]
            state.readIndex += 1
            if state.readIndex == state.queue.count {
                state.queue.removeAll(keepingCapacity: true)
                state.readIndex = 0
            }
        } else {
            state.queue.removeAll(keepingCapacity: true)
            state.readIndex = 0
            state.isDraining = false
            result = nil
        }
        stateLock.unlock()

        if result == nil {
            resumeDrainWaitersIfNeeded()
        }
        return result
    }

    private func drain() async {
        while let message = nextMessage() {
            if let session = await MainActor.run(body: { sessionReference.session }) {
                await MainActor.run {
                    session.handleInboundMessage(message)
                }
            }
        }
    }

    private func drainPendingMessagesOnMainThreadIfPossible() {
        guard let session = MainActor.assumeIsolated({ sessionReference.session }) else {
            return
        }

        while let message = nextMessage() {
            MainActor.assumeIsolated {
                session.handleInboundMessage(message)
            }
        }
    }

    private func resumeDrainWaitersIfNeeded() {
        stateLock.lock()
        let drainWaiters: [CheckedContinuation<Void, Never>]
        if state.queue.isEmpty && !state.isDraining && !state.drainWaiters.isEmpty {
            drainWaiters = state.drainWaiters
            state.drainWaiters.removeAll(keepingCapacity: true)
        } else {
            drainWaiters = []
        }
        stateLock.unlock()

        for drainWaiter in drainWaiters {
            drainWaiter.resume()
        }
    }
}
