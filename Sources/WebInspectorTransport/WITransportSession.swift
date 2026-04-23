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
    private var queuedPageEventSequences: [UInt64] = []
    private var pageEventStreamContinuation: AsyncStream<WITransportEventEnvelope>.Continuation?
    private var pageEventQueueClosed = true
    private var hasAttachedPageEventConsumer = false
    private var nextPageEventSequence: UInt64 = 0
    private var pendingPageEventDeliverySequences: [UInt64] = []
    private var activePageEventDeliverySequence: UInt64?
    private var settledPageEventSequence: UInt64 = 0
    private var outOfOrderSettledPageEventSequences: Set<UInt64> = []
    private var activePageEventDeliveryCount: UInt64 = 0
    private var pageEventDrainWaiters: [PageEventDrainWaiter] = []
    private var stableNetworkBootstrapAvailability: StableNetworkBootstrapAvailability = .unknown

#if DEBUG
    package var derivedPageTargetIdentifierProviderForTesting: (@MainActor (WKWebView) -> String?)?
#endif

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
        stableNetworkBootstrapAvailability = .unknown

        let messageSink = WITransportSessionMessageSink(session: self)
        backendMessageSink = messageSink

        do {
            try await backend.attach(to: webView, messageSink: messageSink)
            supportSnapshot = backend.supportSnapshot
            guard state == .attaching, self.backend != nil else {
                throw WITransportError.transportClosed
            }

            if pageTargetTracker.allowsDerivedCommittedSeed,
               let derivedTargetIdentifier = refreshDerivedPageTargetIdentifierIfNeeded() {
                log("derived current page target target=\(derivedTargetIdentifier)")
            } else {
                log("derived current page target unavailable")
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

        if let derivedTargetIdentifier = refreshDerivedPageTargetIdentifierIfNeeded(),
           derivedTargetIdentifier != excludedTargetIdentifier {
            return derivedTargetIdentifier
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
        if let currentIdentifier = pageTargetTracker.currentIdentifier {
            return currentIdentifier
        }
        if pageTargetTracker.allowsDerivedCommittedSeed {
            return refreshDerivedPageTargetIdentifierIfNeeded()
        }
        return nil
    }

    package func currentObservedPageTargetIdentifier() -> String? {
        pageTargetTracker.observedCurrentIdentifier
    }

    package func targetKind(for identifier: String?) -> WITransportTargetKind? {
        pageTargetTracker.targetKind(for: identifier)
    }

    package var responseTimeout: Duration {
        configuration.responseTimeout
    }

    package func pageTargetIdentifiers() -> [String] {
        if pageTargetTracker.allowsDerivedCommittedSeed {
            _ = refreshDerivedPageTargetIdentifierIfNeeded()
        }
        return pageTargetTracker.orderedIdentifiers
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

        if let compatibilityResponse = backend.compatibilityResponse(scope: .page, method: method) {
            return compatibilityResponse
        }

        let resolvedTargetIdentifier: String
        if let targetIdentifier {
            resolvedTargetIdentifier = targetIdentifier
        } else if let currentTargetIdentifier = refreshDerivedPageTargetIdentifierIfNeeded() ?? pageTargetTracker.currentIdentifier {
            resolvedTargetIdentifier = currentTargetIdentifier
        } else {
            resolvedTargetIdentifier = try await waitForPageTarget(timeout: configuration.responseTimeout)
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

    package func waitForPendingMessages() async {
        await backendMessageSink?.waitForPendingMessages()
    }

    package func waitForPostActivePageEventsToDrain() async {
        let targetSequence = nextPageEventSequence
        guard targetSequence > settledPageEventSequence else {
            return
        }

        await withCheckedContinuation { continuation in
            pageEventDrainWaiters.append(
                PageEventDrainWaiter(
                    targetSequence: targetSequence,
                    continuation: continuation
                )
            )
            resumePageEventDrainWaitersIfNeeded()
        }
    }

    package func pageEvents() -> AsyncStream<WITransportEventEnvelope> {
        precondition(pageEventStreamContinuation == nil, "pageEvents() supports only a single consumer.")

        let bufferedEvents = queuedPageEvents
        let bufferedEventSequences = queuedPageEventSequences
        queuedPageEvents.removeAll(keepingCapacity: true)
        queuedPageEventSequences.removeAll(keepingCapacity: true)
        let isClosed = pageEventQueueClosed
        hasAttachedPageEventConsumer = true

        return AsyncStream(bufferingPolicy: .bufferingNewest(configuration.eventBufferLimit)) { continuation in
            self.pageEventStreamContinuation = continuation
            self.pendingPageEventDeliverySequences = bufferedEventSequences
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

    package func shouldAttemptStableNetworkBootstrap() -> Bool {
        supportSnapshot.capabilities.contains(.networkBootstrapSnapshot)
            && stableNetworkBootstrapAvailability != .unavailable
    }

    @discardableResult
    package func markStableNetworkBootstrapUnavailable() -> Bool {
        let wasUnavailable = stableNetworkBootstrapAvailability == .unavailable
        stableNetworkBootstrapAvailability = .unavailable
        return !wasUnavailable
    }

    package func markStableNetworkBootstrapAvailable() {
        stableNetworkBootstrapAvailability = .available
    }
}

private struct PageEventDrainWaiter {
    let targetSequence: UInt64
    let continuation: CheckedContinuation<Void, Never>
}

extension WITransportSession {
    enum StableNetworkBootstrapAvailability {
        case unknown
        case available
        case unavailable
    }
}

package enum WISharedInspectorTransportClient: Hashable, Sendable {
    case dom
    case network
}

package typealias WISharedInspectorTransportEventHandler = @MainActor (WITransportEventEnvelope) async -> Void

@MainActor
package final class WISharedInspectorTransport {
    private enum ClientDemand {
        case attached
        case suspended
    }

    private struct ClientState {
        weak var webView: WKWebView?
        let demand: ClientDemand
        let sequence: Int
    }

    private let sessionFactory: @MainActor () -> WITransportSession
    private var clientStates: [WISharedInspectorTransportClient: ClientState] = [:]
    private var eventHandlers: [WISharedInspectorTransportClient: WISharedInspectorTransportEventHandler] = [:]
    private var session: WITransportSession?
    private var attachTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private weak var attachedWebView: WKWebView?
    private var nextSequence = 1

    package private(set) var supportSnapshot: WITransportSupportSnapshot

    package init(
        sessionFactory: @escaping @MainActor () -> WITransportSession = { WITransportSession() }
    ) {
        self.sessionFactory = sessionFactory
        self.supportSnapshot = sessionFactory().supportSnapshot
    }

    isolated deinit {
        attachTask?.cancel()
        eventTask?.cancel()
    }

    package func setEventHandler(
        _ handler: WISharedInspectorTransportEventHandler?,
        for client: WISharedInspectorTransportClient
    ) {
        eventHandlers[client] = handler
    }

    package func attach(
        client: WISharedInspectorTransportClient,
        to webView: WKWebView
    ) async {
        clientStates[client] = ClientState(
            webView: webView,
            demand: .attached,
            sequence: nextDemandSequence()
        )
        await reconcileAttachment()
    }

    package func suspend(client: WISharedInspectorTransportClient) async {
        clientStates[client] = ClientState(
            webView: nil,
            demand: .suspended,
            sequence: nextDemandSequence()
        )
        await reconcileAttachment()
    }

    package func detach(client: WISharedInspectorTransportClient) async {
        clientStates.removeValue(forKey: client)
        await reconcileAttachment()
    }

    package func attachedSession() async -> WITransportSession? {
        await attachTask?.value
        return session
    }

    package func waitForAttachForTesting() async {
        await attachTask?.value
    }

    package func currentPageTargetIdentifier() -> String? {
        session?.currentPageTargetIdentifier()
    }

    package func currentObservedPageTargetIdentifier() -> String? {
        session?.currentObservedPageTargetIdentifier()
    }

    package func targetKind(for identifier: String?) -> WITransportTargetKind? {
        session?.targetKind(for: identifier)
    }
}

private extension WISharedInspectorTransport {
    func nextDemandSequence() -> Int {
        defer { nextSequence += 1 }
        return nextSequence
    }

    func reconcileAttachment() async {
        let desiredWebView = desiredAttachedWebView()

        guard let desiredWebView else {
            attachTask?.cancel()
            attachTask = nil
            eventTask?.cancel()
            eventTask = nil
            session?.detach()
            session = nil
            attachedWebView = nil
            supportSnapshot = sessionFactory().supportSnapshot
            return
        }

        if attachedWebView === desiredWebView,
           session != nil,
           attachTask == nil {
            return
        }

        attachTask?.cancel()
        attachTask = nil
        eventTask?.cancel()
        eventTask = nil
        session?.detach()

        let session = sessionFactory()
        self.session = session
        attachedWebView = desiredWebView
        supportSnapshot = session.supportSnapshot

        attachTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else {
                return
            }

            do {
                try await session.attach(to: desiredWebView)
            } catch {
                guard self.session === session else {
                    return
                }
                let message: String
                if let localizedError = error as? LocalizedError,
                   let description = localizedError.errorDescription,
                   !description.isEmpty {
                    message = description
                } else {
                    message = error.localizedDescription
                }
                NSLog("[WebInspectorTransport] shared transport attach failed: %@", message)
                self.session = nil
                self.attachedWebView = nil
                self.supportSnapshot = self.sessionFactory().supportSnapshot
                return
            }

            guard self.session === session else {
                session.detach()
                return
            }

            self.supportSnapshot = session.supportSnapshot
            self.startEventLoop(using: session)
            self.attachTask = nil
        }
    }

    func desiredAttachedWebView() -> WKWebView? {
        clientStates
            .values
            .filter { $0.demand == .attached && $0.webView != nil }
            .max(by: { $0.sequence < $1.sequence })?
            .webView
    }

    func startEventLoop(using session: WITransportSession) {
        eventTask?.cancel()
        let stream = session.pageEvents()
        eventTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else {
                return
            }
            for await envelope in stream {
                guard self.session === session else {
                    break
                }
                session.beginPageEventDelivery()
                for client in [WISharedInspectorTransportClient.network, .dom] {
                    guard let handler = self.eventHandlers[client] else {
                        continue
                    }
                    await handler(envelope)
                }
                session.finishPageEventDelivery()
            }
            if self.session === session {
                self.eventTask = nil
            }
        }
    }
}

extension WITransportSession {
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

        if method.hasPrefix("Target.") || method.hasPrefix("DOM.") || method == "Inspector.inspect" {
            log("received root event method=\(method)")
        }

        if method.hasPrefix("DOM.") || method == "Inspector.inspect" {
            enqueuePageEvent(
                method: method,
                targetIdentifier: inspectEventTargetIdentifier(from: parsed.params)
                    ?? currentPageTargetIdentifier()
                    ?? refreshDerivedPageTargetIdentifierIfNeeded(),
                paramsObject: parsed.params
            )
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

        if method.hasPrefix("DOM.") || method.hasPrefix("Target.") {
            log("received page event method=\(method) target=\(targetIdentifier)")
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
                let targetType = stringValue(targetInfo["type"])
            else {
                return
            }

            let targetKind = pageTargetTracker.didCreateTarget(
                identifier: targetIdentifier,
                type: targetType,
                isProvisional: boolValue(targetInfo["isProvisional"]) == true
            )
            guard targetKind == .page || targetKind == .frame else {
                return
            }
            let isProvisional = boolValue(targetInfo["isProvisional"]) == true
            let currentIdentifier = pageTargetTracker.currentIdentifier ?? "nil"
            log(
                "\(targetKind.rawValue) target created target=\(targetIdentifier) provisional=\(isProvisional) current=\(currentIdentifier)"
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

            let committedTarget = pageTargetTracker.didCommitTarget(
                oldIdentifier: stringValue(params["oldTargetId"]),
                newIdentifier: newTargetIdentifier
            )
            guard committedTarget.kind == .page || committedTarget.kind == .frame else {
                return
            }
            let currentIdentifier = pageTargetTracker.currentIdentifier ?? "nil"
            let oldIdentifierDescription = committedTarget.effectiveOldIdentifier ?? "nil"
            log(
                "\(committedTarget.kind.rawValue) target committed old=\(oldIdentifierDescription) new=\(newTargetIdentifier) current=\(currentIdentifier)"
            )

            var normalizedParams: [String: Any] = ["newTargetId": newTargetIdentifier]
            if let effectiveOldTargetIdentifier = committedTarget.effectiveOldIdentifier {
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
            guard let targetKind = pageTargetTracker.didDestroyTarget(identifier: targetIdentifier),
                  targetKind == .page || targetKind == .frame else {
                return
            }
            let currentIdentifier = pageTargetTracker.currentIdentifier ?? "nil"
            log("\(targetKind.rawValue) target destroyed target=\(targetIdentifier) current=\(currentIdentifier)")

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
        nextPageEventSequence &+= 1
        let sequence = nextPageEventSequence

        if let pageEventStreamContinuation {
            switch pageEventStreamContinuation.yield(envelope) {
            case .enqueued:
                pendingPageEventDeliverySequences.append(sequence)
                return
            case .dropped:
                if let droppedSequence = pendingPageEventDeliverySequences.first {
                    pendingPageEventDeliverySequences.removeFirst()
                    markPageEventSequenceSettled(droppedSequence)
                    pendingPageEventDeliverySequences.append(sequence)
                } else {
                    markPageEventSequenceSettled(sequence)
                }
                resumePageEventDrainWaitersIfNeeded()
                return
            case .terminated:
                self.pageEventStreamContinuation = nil
            @unknown default:
                self.pageEventStreamContinuation = nil
            }
        }

        if !hasAttachedPageEventConsumer || !configuration.dropEventsWithoutSubscribers {
            queuedPageEvents.append(envelope)
            queuedPageEventSequences.append(sequence)
            if queuedPageEvents.count > configuration.eventBufferLimit {
                let droppedCount = queuedPageEvents.count - configuration.eventBufferLimit
                queuedPageEvents.removeFirst(droppedCount)
                let droppedSequences = Array(queuedPageEventSequences.prefix(droppedCount))
                queuedPageEventSequences.removeFirst(droppedCount)
                for droppedSequence in droppedSequences {
                    markPageEventSequenceSettled(droppedSequence)
                }
            }
        }
    }

    func resetTransportStateForAttach() {
        replyRegistry.reset()
        pageTargetTracker.reset()
        queuedPageEvents.removeAll(keepingCapacity: true)
        queuedPageEventSequences.removeAll(keepingCapacity: true)
        pageEventStreamContinuation = nil
        pageEventQueueClosed = false
        hasAttachedPageEventConsumer = false
        nextPageEventSequence = 0
        pendingPageEventDeliverySequences.removeAll(keepingCapacity: true)
        activePageEventDeliverySequence = nil
        settledPageEventSequence = 0
        outOfOrderSettledPageEventSequences.removeAll(keepingCapacity: true)
        activePageEventDeliveryCount = 0
        pageEventDrainWaiters.removeAll(keepingCapacity: true)
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
        queuedPageEventSequences.removeAll(keepingCapacity: false)
        pendingPageEventDeliverySequences.removeAll(keepingCapacity: false)
        activePageEventDeliverySequence = nil
        outOfOrderSettledPageEventSequences.removeAll(keepingCapacity: true)
        let drainWaiters = pageEventDrainWaiters
        pageEventDrainWaiters.removeAll(keepingCapacity: true)
        let continuation = pageEventStreamContinuation
        pageEventStreamContinuation = nil
        continuation?.finish()
        for waiter in drainWaiters {
            waiter.continuation.resume()
        }
    }

    package func beginPageEventDelivery() {
        activePageEventDeliveryCount &+= 1
        if activePageEventDeliverySequence == nil, !pendingPageEventDeliverySequences.isEmpty {
            activePageEventDeliverySequence = pendingPageEventDeliverySequences.removeFirst()
        }
    }

    package func finishPageEventDelivery() {
        if activePageEventDeliveryCount > 0 {
            activePageEventDeliveryCount &-= 1
        }
        if let activePageEventDeliverySequence {
            markPageEventSequenceSettled(activePageEventDeliverySequence)
            self.activePageEventDeliverySequence = nil
        }
        resumePageEventDrainWaitersIfNeeded()
    }

    func resumePageEventDrainWaitersIfNeeded() {
        guard !pageEventDrainWaiters.isEmpty else {
            return
        }
        let readyWaiters = pageEventDrainWaiters.filter {
            settledPageEventSequence >= $0.targetSequence
        }
        guard !readyWaiters.isEmpty else {
            return
        }
        pageEventDrainWaiters.removeAll {
            settledPageEventSequence >= $0.targetSequence
        }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
    }

    private func markPageEventSequenceSettled(_ sequence: UInt64) {
        guard sequence > 0 else {
            return
        }
        guard sequence > settledPageEventSequence else {
            return
        }

        if sequence == settledPageEventSequence + 1 {
            settledPageEventSequence = sequence
            while outOfOrderSettledPageEventSequences.remove(settledPageEventSequence + 1) != nil {
                settledPageEventSequence &+= 1
            }
            return
        }

        outOfOrderSettledPageEventSequences.insert(sequence)
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

    func inspectEventTargetIdentifier(from paramsObject: Any?) -> String? {
        guard let params = paramsObject as? [String: Any] else {
            return nil
        }
        return stringValue(params["targetId"])
            ?? stringValue(params["targetIdentifier"])
            ?? stringValue((params["target"] as? [String: Any])?["targetId"])
    }

    func refreshDerivedPageTargetIdentifierIfNeeded() -> String? {
        guard pageTargetTracker.allowsDerivedCommittedSeed,
              let webView,
              let targetIdentifier = derivedPageTargetIdentifier(from: webView) else {
            return nil
        }
        pageTargetTracker.seedCommittedPageTarget(identifier: targetIdentifier)
        return targetIdentifier
    }

    func derivedPageTargetIdentifier(from webView: WKWebView) -> String? {
#if DEBUG
        if let derivedPageTargetIdentifierProviderForTesting {
            return derivedPageTargetIdentifierProviderForTesting(webView)
        }
#endif
        let handleSelector = NSSelectorFromString("_handle")
        guard webView.responds(to: handleSelector),
              let handle = (webView.value(forKey: "_handle") as AnyObject?) else {
            return nil
        }

        let pageIDSelector = NSSelectorFromString("webPageID")
        let legacyPageIDSelector = NSSelectorFromString("_webPageID")
        let pageIDValue =
            (handle.responds(to: pageIDSelector) ? handle.value(forKey: "webPageID") as? NSNumber : nil)
            ?? (handle.responds(to: legacyPageIDSelector) ? handle.value(forKey: "_webPageID") as? NSNumber : nil)

        guard let pageIDValue else {
            return nil
        }

        return "page-\(pageIDValue.uint64Value)"
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

    private struct KnownTarget {
        let identifier: String
        let kind: WITransportTargetKind
        let isProvisional: Bool
        let creationOrder: Int
    }

    struct CommitResult {
        let effectiveOldIdentifier: String?
        let kind: WITransportTargetKind
    }

    private struct AvailabilityWaiter {
        let excludedIdentifier: String?
        let continuation: CheckedContinuation<String, Error>
    }

    private var targetsByIdentifier: [String: KnownPageTarget] = [:]
    private var knownTargetsByIdentifier: [String: KnownTarget] = [:]
    private var recentlyDestroyedTargetKinds: [String: WITransportTargetKind] = [:]
    private var hasObservedLifecycleEvents = false
    private var hasDerivedCommittedSeed = false
    private var currentIdentifierStorage: String?
    private var committedIdentifierStorage: String?
    private var nextCreationOrder = 0
    private var availabilityWaiters: [UUID: AvailabilityWaiter] = [:]

    var currentIdentifier: String? {
        currentIdentifierStorage
    }

    var observedCurrentIdentifier: String? {
        guard hasDerivedCommittedSeed == false else {
            return nil
        }
        return currentIdentifierStorage
    }

    var allowsDerivedCommittedSeed: Bool {
        !hasObservedLifecycleEvents && currentIdentifierStorage == nil
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

    func targetKind(for identifier: String?) -> WITransportTargetKind? {
        guard let identifier else {
            return nil
        }
        return knownTargetsByIdentifier[identifier]?.kind
            ?? recentlyDestroyedTargetKinds[identifier]
    }

    @discardableResult
    func didCreateTarget(identifier: String, type: String, isProvisional: Bool) -> WITransportTargetKind {
        let kind = targetKind(forType: type)
        recentlyDestroyedTargetKinds.removeValue(forKey: identifier)
        let creationOrder = knownTargetsByIdentifier[identifier]?.creationOrder ?? nextCreationOrderValue()
        knownTargetsByIdentifier[identifier] = KnownTarget(
            identifier: identifier,
            kind: kind,
            isProvisional: isProvisional,
            creationOrder: creationOrder
        )

        hasObservedLifecycleEvents = true
        guard kind == .page else {
            return kind
        }
        if hasDerivedCommittedSeed,
           let committedIdentifierStorage {
            if committedIdentifierStorage == identifier {
                hasDerivedCommittedSeed = false
            } else if isProvisional == false {
                targetsByIdentifier.removeValue(forKey: committedIdentifierStorage)
                self.committedIdentifierStorage = nil
                hasDerivedCommittedSeed = false
            }
        }
        targetsByIdentifier[identifier] = KnownPageTarget(
            identifier: identifier,
            isProvisional: isProvisional,
            creationOrder: creationOrder
        )
        refreshCurrentIdentifier()
        return kind
    }

    func didCommitTarget(oldIdentifier: String?, newIdentifier: String) -> CommitResult {
        recentlyDestroyedTargetKinds.removeValue(forKey: newIdentifier)
        let effectiveOldIdentifier = oldIdentifier ?? inferredCommittedOldIdentifier(excluding: newIdentifier)
        let kind = knownTargetsByIdentifier[newIdentifier]?.kind
            ?? effectiveOldIdentifier.flatMap { knownTargetsByIdentifier[$0]?.kind }
            ?? .page

        if let effectiveOldIdentifier,
           let previousTarget = knownTargetsByIdentifier.removeValue(forKey: effectiveOldIdentifier) {
            knownTargetsByIdentifier[newIdentifier] = KnownTarget(
                identifier: newIdentifier,
                kind: previousTarget.kind,
                isProvisional: false,
                creationOrder: previousTarget.creationOrder
            )
        } else if let existingTarget = knownTargetsByIdentifier[newIdentifier] {
            knownTargetsByIdentifier[newIdentifier] = KnownTarget(
                identifier: newIdentifier,
                kind: existingTarget.kind,
                isProvisional: false,
                creationOrder: existingTarget.creationOrder
            )
        } else {
            knownTargetsByIdentifier[newIdentifier] = KnownTarget(
                identifier: newIdentifier,
                kind: kind,
                isProvisional: false,
                creationOrder: nextCreationOrderValue()
            )
        }

        guard kind == .page else {
            return CommitResult(effectiveOldIdentifier: effectiveOldIdentifier, kind: kind)
        }

        hasObservedLifecycleEvents = true
        hasDerivedCommittedSeed = false
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
        return CommitResult(effectiveOldIdentifier: effectiveOldIdentifier, kind: kind)
    }

    func didDestroyTarget(identifier: String) -> WITransportTargetKind? {
        let kind = knownTargetsByIdentifier.removeValue(forKey: identifier)?.kind
        guard let kind else {
            return nil
        }
        recentlyDestroyedTargetKinds[identifier] = kind

        guard kind == .page else {
            return kind
        }

        hasObservedLifecycleEvents = true
        if committedIdentifierStorage == identifier {
            hasDerivedCommittedSeed = false
        }
        guard targetsByIdentifier.removeValue(forKey: identifier) != nil else {
            return nil
        }
        if committedIdentifierStorage == identifier {
            committedIdentifierStorage = nil
        }
        refreshCurrentIdentifier()
        return kind
    }

    func seedCommittedPageTarget(identifier: String) {
        let creationOrder = knownTargetsByIdentifier[identifier]?.creationOrder ?? targetsByIdentifier[identifier]?.creationOrder ?? nextCreationOrderValue()
        knownTargetsByIdentifier[identifier] = KnownTarget(
            identifier: identifier,
            kind: .page,
            isProvisional: false,
            creationOrder: creationOrder
        )
        if let existing = targetsByIdentifier[identifier] {
            targetsByIdentifier[identifier] = KnownPageTarget(
                identifier: identifier,
                isProvisional: false,
                creationOrder: existing.creationOrder
            )
        } else {
            targetsByIdentifier[identifier] = KnownPageTarget(
                identifier: identifier,
                isProvisional: false,
                creationOrder: creationOrder
            )
        }

        committedIdentifierStorage = identifier
        hasDerivedCommittedSeed = true
        refreshCurrentIdentifier()
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
        knownTargetsByIdentifier.removeAll(keepingCapacity: true)
        recentlyDestroyedTargetKinds.removeAll(keepingCapacity: true)
        hasObservedLifecycleEvents = false
        hasDerivedCommittedSeed = false
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

    private func targetKind(forType type: String) -> WITransportTargetKind {
        switch type {
        case "page":
            return .page
        case "frame":
            return .frame
        default:
            return .other
        }
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

    func waitForPendingMessages() async {
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
