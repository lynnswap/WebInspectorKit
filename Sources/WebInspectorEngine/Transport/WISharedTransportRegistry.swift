import WebKit
import WebInspectorTransport

@MainActor
final class WISharedTransportRegistry {
    static let shared = WISharedTransportRegistry()
    typealias SessionFactory = @MainActor (WKWebView) -> WITransportSession

    private static let networkEventMethods: Set<String> = [
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

    private static let domEventMethods: Set<String> = [
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

    @MainActor
    final class Lease: InspectorTransportCapabilityProviding {
        private weak var registry: WISharedTransportRegistry?
        fileprivate let entry: Entry
        private var released = false

        fileprivate init(registry: WISharedTransportRegistry, entry: Entry) {
            self.registry = registry
            self.entry = entry
        }

        package var inspectorTransportCapabilities: Set<InspectorTransportCapability> {
            entry.inspectorTransportCapabilities
        }

        var supportSnapshot: WITransportSupportSnapshot {
            entry.supportSnapshot
        }

        func ensureAttached() async throws {
            try await entry.ensureAttached()
        }

        func sendPage<C: WITransportPageCommand>(_ command: C) async throws -> C.Response {
            try await entry.sendPage(command)
        }

        func sendRoot<C: WITransportRootCommand>(_ command: C) async throws -> C.Response {
            try await entry.sendRoot(command)
        }

        func addNetworkConsumer(
            _ identifier: UUID,
            handler: @escaping @MainActor (WITransportEventEnvelope) -> Void
        ) {
            entry.addNetworkConsumer(identifier, handler: handler)
        }

        func removeNetworkConsumer(_ identifier: UUID) {
            entry.removeNetworkConsumer(identifier)
        }

        func addDOMConsumer(
            _ identifier: UUID,
            handler: @escaping @MainActor (WITransportEventEnvelope) -> Void
        ) {
            entry.addDOMConsumer(identifier, handler: handler)
        }

        func ensureNetworkEventIngress() async throws {
            try await entry.ensureNetworkEventIngress()
        }

        func removeDOMConsumer(_ identifier: UUID) {
            entry.removeDOMConsumer(identifier)
        }

        func ensureDOMEventIngress() async throws {
            try await entry.ensureDOMEventIngress()
        }

        func ensureCSSDomainReady() async throws {
            try await entry.ensureCSSDomainReady()
        }

        func release() {
            guard !released else {
                return
            }
            released = true
            registry?.releaseLease(self)
        }
    }

    @MainActor
    final class Entry {
        weak var webView: WKWebView?
        let transportSession: WITransportSession
        var retainCount = 0

        private var attachmentTask: Task<Void, Error>?
        private var networkConsumers: [UUID: @MainActor (WITransportEventEnvelope) -> Void] = [:]
        private var domConsumers: [UUID: @MainActor (WITransportEventEnvelope) -> Void] = [:]
        private var networkEventTask: Task<Void, Never>?
        private var domEventTask: Task<Void, Never>?
        private var networkIngressTask: Task<Void, Error>?
        private var domIngressTask: Task<Void, Error>?
        private var networkIngressReady = false
        private var domIngressReady = false

        init(webView: WKWebView, transportSession: WITransportSession) {
            self.webView = webView
            self.transportSession = transportSession
        }

        var supportSnapshot: WITransportSupportSnapshot {
            transportSession.supportSnapshot
        }

        var inspectorTransportCapabilities: Set<InspectorTransportCapability> {
            var mapped: Set<InspectorTransportCapability> = []

            if supportSnapshot.capabilities.contains(.domDomain) {
                mapped.insert(.domDomain)
            }
            if supportSnapshot.capabilities.contains(.networkDomain) {
                mapped.insert(.networkDomain)
            }
            if supportSnapshot.capabilities.contains(.pageTargetRouting) {
                mapped.insert(.pageTargetRouting)
            }
            if supportSnapshot.capabilities.contains(.remoteFrontendHosting) {
                mapped.insert(.remoteFrontendHosting)
            }

            return mapped
        }

        func ensureAttached() async throws {
            if transportSession.state == .attached {
                startEventTasksIfNeeded()
                return
            }

            if let attachmentTask {
                try await attachmentTask.value
                startEventTasksIfNeeded()
                return
            }

            let task = Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else {
                    throw WITransportError.transportClosed
                }
                if self.transportSession.state == .detached {
                    try await self.transportSession.attach(to: webView)
                }
            }

            attachmentTask = task
            do {
                try await task.value
            } catch {
                attachmentTask = nil
                throw error
            }
            attachmentTask = nil
            startEventTasksIfNeeded()
        }

        func sendPage<C: WITransportPageCommand>(_ command: sending C) async throws -> C.Response {
            try await ensureAttached()
            return try await transportSession.page.send(command)
        }

        func sendRoot<C: WITransportRootCommand>(_ command: sending C) async throws -> C.Response {
            try await ensureAttached()
            return try await transportSession.root.send(command)
        }

        func addNetworkConsumer(
            _ identifier: UUID,
            handler: @escaping @MainActor (WITransportEventEnvelope) -> Void
        ) {
            networkConsumers[identifier] = handler
        }

        func removeNetworkConsumer(_ identifier: UUID) {
            networkConsumers.removeValue(forKey: identifier)
            if networkConsumers.isEmpty {
                networkIngressTask?.cancel()
                networkIngressTask = nil
                networkIngressReady = false
                networkEventTask?.cancel()
                networkEventTask = nil
            }
        }

        func addDOMConsumer(
            _ identifier: UUID,
            handler: @escaping @MainActor (WITransportEventEnvelope) -> Void
        ) {
            domConsumers[identifier] = handler
        }

        func removeDOMConsumer(_ identifier: UUID) {
            domConsumers.removeValue(forKey: identifier)
            if domConsumers.isEmpty {
                domIngressTask?.cancel()
                domIngressTask = nil
                domIngressReady = false
                domEventTask?.cancel()
                domEventTask = nil
            }
        }

        func detach() {
            attachmentTask?.cancel()
            attachmentTask = nil
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
            transportSession.detach()
        }

        private func startEventTasksIfNeeded() {
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

        func ensureNetworkEventIngress() async throws {
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
                _ = try await self.transportSession.page.send(WITransportCommands.Network.Enable())
                let stream = await self.transportSession.eventStream(
                    scope: .page,
                    methods: WISharedTransportRegistry.networkEventMethods,
                    bufferingLimit: nil
                )
                self.networkIngressReady = true
                self.startNetworkEventLoop(with: stream)
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

        func ensureDOMEventIngress() async throws {
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
                do {
                    _ = try await self.transportSession.page.send(WITransportCommands.DOM.Enable())
                } catch let error as WITransportError {
                    guard self.shouldIgnoreMissingDOMEnable(error) else {
                        throw error
                    }
                }
                let stream = await self.transportSession.eventStream(
                    scope: .page,
                    methods: WISharedTransportRegistry.domEventMethods,
                    bufferingLimit: nil
                )
                self.domIngressReady = true
                self.startDOMEventLoop(with: stream)
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

        func ensureCSSDomainReady() async throws {
            // CSS getters do not require `CSS.enable` on the native transport path,
            // and enabling the domain can crash WebContent on iOS simulator.
            try await ensureAttached()
        }

        private func startNetworkEventLoop(with stream: AsyncStream<WITransportEventEnvelope>) {
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
                self.networkEventTask = nil
                self.restartNetworkIngressIfNeeded()
            }
        }

        private func startDOMEventLoop(with stream: AsyncStream<WITransportEventEnvelope>) {
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

        private func restartNetworkIngressIfNeeded() {
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

        private func restartDOMIngressIfNeeded() {
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

        private func publish(
            _ event: WITransportEventEnvelope,
            to consumers: [UUID: @MainActor (WITransportEventEnvelope) -> Void]
        ) {
            for handler in consumers.values {
                handler(event)
            }
        }

        private func shouldIgnoreMissingDOMEnable(_ error: WITransportError) -> Bool {
            guard case let .remoteError(_, method, message) = error else {
                return false
            }
            guard method == WITransportCommands.DOM.Enable.method else {
                return false
            }
            return message.contains("'DOM.enable' was not found")
                || message.contains("DOM.enable was not found")
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private let sessionFactory: SessionFactory

    init(sessionFactory: @escaping SessionFactory = { _ in WITransportSession() }) {
        self.sessionFactory = sessionFactory
    }

    func acquireLease(for webView: WKWebView) -> Lease {
        purgeStaleEntries()

        let key = ObjectIdentifier(webView)
        let entry: Entry
        if let existing = entries[key] {
            entry = existing
        } else {
            let created = Entry(
                webView: webView,
                transportSession: sessionFactory(webView)
            )
            entries[key] = created
            entry = created
        }

        entry.retainCount += 1
        return Lease(registry: self, entry: entry)
    }

    private func releaseLease(_ lease: Lease) {
        guard let webView = lease.entry.webView else {
            releaseEntryIfPossible(lease.entry, preferredKey: nil)
            return
        }

        releaseEntryIfPossible(lease.entry, preferredKey: ObjectIdentifier(webView))
    }

    private func releaseEntryIfPossible(_ entry: Entry, preferredKey: ObjectIdentifier?) {
        guard entry.retainCount > 0 else {
            removeEntry(entry, preferredKey: preferredKey)
            return
        }

        entry.retainCount -= 1
        guard entry.retainCount == 0 else {
            return
        }

        removeEntry(entry, preferredKey: preferredKey)
    }

    private func removeEntry(_ entry: Entry, preferredKey: ObjectIdentifier?) {
        entry.detach()

        if let preferredKey {
            entries.removeValue(forKey: preferredKey)
            return
        }

        if let match = entries.first(where: { $0.value === entry }) {
            entries.removeValue(forKey: match.key)
        }
    }

    private func purgeStaleEntries() {
        let staleKeys = entries.compactMap { key, entry in
            entry.webView == nil && entry.retainCount == 0 ? key : nil
        }

        for key in staleKeys {
            entries[key]?.detach()
            entries.removeValue(forKey: key)
        }
    }
}
