import Foundation

@MainActor
package final class TransportEventHub {
    package static let networkEventMethods: Set<String> = [
        "Target.targetCreated",
        "Target.didCommitProvisionalTarget",
        "Target.targetDestroyed",
        "Network.requestWillBeSent",
        "Network.responseReceived",
        "Network.loadingFinished",
        "Network.loadingFailed",
        "Network.dataReceived",
        "Network.requestServedFromMemoryCache",
        "Network.webSocketCreated",
        "Network.webSocketWillSendHandshakeRequest",
        "Network.webSocketHandshakeResponseReceived",
        "Network.webSocketFrameReceived",
        "Network.webSocketFrameSent",
        "Network.webSocketFrameError",
        "Network.webSocketClosed",
    ]

    package static let domEventMethods: Set<String> = [
        "DOM.documentUpdated",
        "DOM.setChildNodes",
        "DOM.childNodeInserted",
        "DOM.childNodeRemoved",
        "DOM.childNodeCountUpdated",
        "DOM.attributeModified",
        "DOM.attributeRemoved",
        "DOM.characterDataModified",
        "DOM.inspect",
    ]

    private let transportSession: WITransportSession
    private let pageTargetCoordinator: PageTargetCoordinator
    private let ensureAttached: @MainActor () async throws -> Void

    private var networkConsumers: [UUID: @MainActor (WITransportEventEnvelope) -> Void] = [:]
    private var domConsumers: [UUID: @MainActor (WITransportEventEnvelope) -> Void] = [:]
    private var networkEventTask: Task<Void, Never>?
    private var domEventTask: Task<Void, Never>?
    private var networkIngressTask: Task<Void, Error>?
    private var domIngressTask: Task<Void, Error>?
    private var networkIngressReady = false
    private var domIngressReady = false

    package var onNetworkIngressReadyForTesting: (@MainActor () -> Void)?
    package var onDOMIngressReadyForTesting: (@MainActor () -> Void)?

    package init(
        transportSession: WITransportSession,
        pageTargetCoordinator: PageTargetCoordinator,
        ensureAttached: @escaping @MainActor () async throws -> Void
    ) {
        self.transportSession = transportSession
        self.pageTargetCoordinator = pageTargetCoordinator
        self.ensureAttached = ensureAttached
    }

    package var hasNetworkConsumers: Bool {
        !networkConsumers.isEmpty
    }

    package var hasDOMConsumers: Bool {
        !domConsumers.isEmpty
    }

    package func addNetworkConsumer(
        _ identifier: UUID,
        handler: @escaping @MainActor (WITransportEventEnvelope) -> Void
    ) {
        networkConsumers[identifier] = handler
        pageTargetCoordinator.updateInterest(
            hasNetworkConsumers: hasNetworkConsumers,
            hasDOMConsumers: hasDOMConsumers
        )
    }

    package func removeNetworkConsumer(_ identifier: UUID) {
        networkConsumers.removeValue(forKey: identifier)
        pageTargetCoordinator.updateInterest(
            hasNetworkConsumers: hasNetworkConsumers,
            hasDOMConsumers: hasDOMConsumers
        )
        if networkConsumers.isEmpty {
            networkIngressTask?.cancel()
            networkIngressTask = nil
            networkIngressReady = false
            networkEventTask?.cancel()
            networkEventTask = nil
            pageTargetCoordinator.resetNetworkIngressState()
        }
    }

    package func addDOMConsumer(
        _ identifier: UUID,
        handler: @escaping @MainActor (WITransportEventEnvelope) -> Void
    ) {
        domConsumers[identifier] = handler
        pageTargetCoordinator.updateInterest(
            hasNetworkConsumers: hasNetworkConsumers,
            hasDOMConsumers: hasDOMConsumers
        )
    }

    package func removeDOMConsumer(_ identifier: UUID) {
        domConsumers.removeValue(forKey: identifier)
        pageTargetCoordinator.updateInterest(
            hasNetworkConsumers: hasNetworkConsumers,
            hasDOMConsumers: hasDOMConsumers
        )
        if domConsumers.isEmpty {
            domIngressTask?.cancel()
            domIngressTask = nil
            domIngressReady = false
            domEventTask?.cancel()
            domEventTask = nil
        }
    }

    package func startDomainEventTasksIfNeeded() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            try? await self.ensureNetworkEventIngress()
        }
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            try? await self.ensureDOMEventIngress()
        }
    }

    package func ensureNetworkEventIngress() async throws {
        guard !networkConsumers.isEmpty else {
            return
        }
        if networkIngressReady {
            return
        }
        if let networkIngressTask {
            try await networkIngressTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            try await self.ensureAttached()
            let stream = await self.transportSession.eventStream(
                scope: .page,
                methods: Self.networkEventMethods,
                bufferingLimit: nil
            )
            try await self.pageTargetCoordinator.prepareNetworkIngress()
            self.networkIngressReady = true
            self.startNetworkEventLoop(with: stream)
            self.onNetworkIngressReadyForTesting?()
        }
        networkIngressTask = task
        defer { networkIngressTask = nil }
        do {
            try await task.value
        } catch {
            networkIngressReady = false
            throw error
        }
    }

    package func ensureDOMEventIngress() async throws {
        guard !domConsumers.isEmpty else {
            return
        }
        if domIngressReady {
            return
        }
        if let domIngressTask {
            try await domIngressTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            try await self.ensureAttached()
            let stream = await self.transportSession.eventStream(
                scope: .page,
                methods: Self.domEventMethods,
                bufferingLimit: nil
            )
            try await self.pageTargetCoordinator.prepareDOMIngress()
            self.domIngressReady = true
            self.startDOMEventLoop(with: stream)
            self.onDOMIngressReadyForTesting?()
        }
        domIngressTask = task
        defer { domIngressTask = nil }
        do {
            try await task.value
        } catch {
            domIngressReady = false
            throw error
        }
    }

    package func reset() {
        networkIngressTask?.cancel()
        networkIngressTask = nil
        domIngressTask?.cancel()
        domIngressTask = nil
        networkIngressReady = false
        domIngressReady = false
        networkEventTask?.cancel()
        networkEventTask = nil
        domEventTask?.cancel()
        domEventTask = nil
        networkConsumers.removeAll()
        domConsumers.removeAll()
        pageTargetCoordinator.updateInterest(hasNetworkConsumers: false, hasDOMConsumers: false)
        pageTargetCoordinator.resetNetworkIngressState()
    }
}

private extension TransportEventHub {
    func startNetworkEventLoop(with stream: AsyncStream<WITransportEventEnvelope>) {
        guard networkEventTask == nil else {
            return
        }

        networkEventTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            for await event in stream {
                if Task.isCancelled {
                    break
                }
                self.publish(event, to: self.networkConsumers)
            }

            self.networkIngressReady = false
            self.pageTargetCoordinator.resetNetworkIngressState()
            self.networkEventTask = nil
            self.restartNetworkIngressIfNeeded()
        }
    }

    func startDOMEventLoop(with stream: AsyncStream<WITransportEventEnvelope>) {
        guard domEventTask == nil else {
            return
        }

        domEventTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            for await event in stream {
                if Task.isCancelled {
                    break
                }
                self.publish(event, to: self.domConsumers)
            }

            self.domIngressReady = false
            self.domEventTask = nil
            self.restartDOMIngressIfNeeded()
        }
    }

    func restartNetworkIngressIfNeeded() {
        guard !Task.isCancelled else {
            return
        }
        guard !networkConsumers.isEmpty else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            try? await self.ensureNetworkEventIngress()
        }
    }

    func restartDOMIngressIfNeeded() {
        guard !Task.isCancelled else {
            return
        }
        guard !domConsumers.isEmpty else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            try? await self.ensureDOMEventIngress()
        }
    }

    func publish(
        _ event: WITransportEventEnvelope,
        to consumers: [UUID: @MainActor (WITransportEventEnvelope) -> Void]
    ) {
        for handler in consumers.values {
            handler(event)
        }
    }
}
