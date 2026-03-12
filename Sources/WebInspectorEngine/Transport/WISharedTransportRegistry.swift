import WebKit
import WebInspectorTransport

@MainActor
package final class WISharedTransportRegistry {
    package static let shared = WISharedTransportRegistry()
    package typealias SessionFactory = @MainActor (WKWebView) -> WITransportSession

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
    package final class Lease: InspectorTransportCapabilityProviding {
        private weak var registry: WISharedTransportRegistry?
        fileprivate let entry: Entry
        private var released = false

        fileprivate init(registry: WISharedTransportRegistry, entry: Entry) {
            self.registry = registry
            self.entry = entry
        }

        package var onNetworkIngressReadyForTesting: (@MainActor () -> Void)? {
            get { entry.onNetworkIngressReadyForTesting }
            set { entry.onNetworkIngressReadyForTesting = newValue }
        }

        package var onDOMIngressReadyForTesting: (@MainActor () -> Void)? {
            get { entry.onDOMIngressReadyForTesting }
            set { entry.onDOMIngressReadyForTesting = newValue }
        }

        package var inspectorTransportCapabilities: Set<InspectorTransportCapability> {
            entry.inspectorTransportCapabilities
        }

        package var inspectorTransportSupportSnapshot: WITransportSupportSnapshot? {
            supportSnapshot
        }

        package var supportSnapshot: WITransportSupportSnapshot {
            entry.supportSnapshot
        }

        package func ensureAttached() async throws {
            try await entry.ensureAttached()
        }

        package func sendPage<C: WITransportPageCommand>(_ command: C) async throws -> C.Response {
            try await entry.sendPage(command)
        }

        package func sendRoot<C: WITransportRootCommand>(_ command: C) async throws -> C.Response {
            try await entry.sendRoot(command)
        }

        package func addNetworkConsumer(
            _ identifier: UUID,
            handler: @escaping @MainActor (WITransportEventEnvelope) -> Void
        ) {
            entry.addNetworkConsumer(identifier, handler: handler)
        }

        package func removeNetworkConsumer(_ identifier: UUID) {
            entry.removeNetworkConsumer(identifier)
        }

        package func addDOMConsumer(
            _ identifier: UUID,
            handler: @escaping @MainActor (WITransportEventEnvelope) -> Void
        ) {
            entry.addDOMConsumer(identifier, handler: handler)
        }

        package func ensureNetworkEventIngress() async throws {
            try await entry.ensureNetworkEventIngress()
        }

        package func removeDOMConsumer(_ identifier: UUID) {
            entry.removeDOMConsumer(identifier)
        }

        package func ensureDOMEventIngress() async throws {
            try await entry.ensureDOMEventIngress()
        }

        package func ensureCSSDomainReady() async throws {
            try await entry.ensureCSSDomainReady()
        }

        package func release() {
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
        private var pageTargetLifecycleTask: Task<Void, Never>?
        private var pageTargetLifecycleSubscriptionPending = false
        private var networkIngressTask: Task<Void, Error>?
        private var domIngressTask: Task<Void, Error>?
        private var networkIngressReady = false
        private var domIngressReady = false
        var onNetworkIngressReadyForTesting: (@MainActor () -> Void)?
        var onDOMIngressReadyForTesting: (@MainActor () -> Void)?

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

            return mapped
        }

        func ensureAttached() async throws {
            if transportSession.state == .attached {
                await ensurePageTargetLifecycleTaskIfNeeded()
                startDomainEventTasksIfNeeded()
                return
            }

            if let attachmentTask {
                try await attachmentTask.value
                await ensurePageTargetLifecycleTaskIfNeeded()
                startDomainEventTasksIfNeeded()
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
            await ensurePageTargetLifecycleTaskIfNeeded()
            startDomainEventTasksIfNeeded()
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
            pageTargetLifecycleTask?.cancel()
            pageTargetLifecycleTask = nil
            networkConsumers.removeAll()
            domConsumers.removeAll()
            transportSession.detach()
        }

        private func startDomainEventTasksIfNeeded() {
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

        private func ensurePageTargetLifecycleTaskIfNeeded() async {
            guard pageTargetLifecycleTask == nil, !pageTargetLifecycleSubscriptionPending else {
                return
            }
            pageTargetLifecycleSubscriptionPending = true
            defer {
                pageTargetLifecycleSubscriptionPending = false
            }

            let pageTargetChangeStream = await self.transportSession.pageTargetChangeStream()

            pageTargetLifecycleTask = Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                for await event in pageTargetChangeStream {
                    if Task.isCancelled {
                        break
                    }
                    await self.handlePageTargetLifecycleEvent(event)
                }

                self.pageTargetLifecycleTask = nil
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

        func ensureCSSDomainReady() async throws {
            // CSS getters work without `CSS.enable` on the native transport path,
            // and explicitly enabling the domain can crash WebContent on macOS HTTPS pages.
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

        private func handlePageTargetLifecycleEvent(_ event: WITransportPageTargetChange) async {
            _ = event
            if !networkConsumers.isEmpty {
                do {
                    _ = try await self.transportSession.page.send(WITransportCommands.Network.Enable())
                } catch {
                    guard shouldIgnorePageTargetLifecycleError(error) else {
                        return
                    }
                }
            }

            if !domConsumers.isEmpty {
                do {
                    _ = try await self.transportSession.page.send(WITransportCommands.DOM.Enable())
                } catch let error as WITransportError {
                    guard shouldIgnoreMissingDOMEnable(error) || shouldIgnorePageTargetLifecycleError(error) else {
                        return
                    }
                } catch {
                    guard shouldIgnorePageTargetLifecycleError(error) else {
                        return
                    }
                }
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

        private func shouldIgnorePageTargetLifecycleError(_ error: Error) -> Bool {
            if error is CancellationError {
                return true
            }

            guard let transportError = error as? WITransportError else {
                return false
            }

            switch transportError {
            case .notAttached, .pageTargetUnavailable, .transportClosed:
                return true
            default:
                return false
            }
        }

    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private let sessionFactory: SessionFactory

    init(sessionFactory: @escaping SessionFactory = { _ in WITransportSession() }) {
        self.sessionFactory = sessionFactory
    }

    package func acquireLease(for webView: WKWebView) -> Lease {
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
