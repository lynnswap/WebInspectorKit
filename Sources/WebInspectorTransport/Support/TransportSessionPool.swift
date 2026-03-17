import WebKit

@MainActor
package final class TransportSessionPool {
    package typealias SessionFactory = @MainActor (WKWebView) -> WITransportSession

    @MainActor
    package final class Entry {
        weak var webView: WKWebView?
        let transportSession: WITransportSession
        var retainCount = 0

        private var attachmentTask: Task<Void, Error>?
        private let pageTargetCoordinator: PageTargetCoordinator
        package lazy var eventHub = TransportEventHub(
            transportSession: transportSession,
            pageTargetCoordinator: pageTargetCoordinator,
            ensureAttached: { [weak self] in
                guard let self else {
                    throw WITransportError.transportClosed
                }
                try await self.ensureAttached()
            }
        )

        init(webView: WKWebView, transportSession: WITransportSession) {
            self.webView = webView
            self.transportSession = transportSession
            self.pageTargetCoordinator = PageTargetCoordinator(transportSession: transportSession)
        }

        package var supportSnapshot: WITransportSupportSnapshot {
            transportSession.supportSnapshot
        }

        package var inspectorTransportCapabilities: Set<InspectorTransportCapability> {
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
            if supportSnapshot.capabilities.contains(.networkBootstrapSnapshot) {
                mapped.insert(.networkBootstrapSnapshot)
            }

            return mapped
        }

        package func ensureAttached() async throws {
            if transportSession.state == .attached {
                await pageTargetCoordinator.ensureLifecycleTaskIfNeeded()
                eventHub.startDomainEventTasksIfNeeded()
                return
            }

            if let attachmentTask {
                try await attachmentTask.value
                await pageTargetCoordinator.ensureLifecycleTaskIfNeeded()
                eventHub.startDomainEventTasksIfNeeded()
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
            await pageTargetCoordinator.ensureLifecycleTaskIfNeeded()
            eventHub.startDomainEventTasksIfNeeded()
        }

        package func sendPage<C: WITransportPageCommand>(_ command: sending C) async throws -> C.Response {
            try await ensureAttached()
            return try await transportSession.page.send(command)
        }

        package func sendPageCapturingCurrentTarget<C: WITransportPageCommand>(
            _ command: sending C
        ) async throws -> (targetIdentifier: String, response: C.Response) {
            try await ensureAttached()
            return try await transportSession.sendPageCapturingCurrentTarget(command)
        }

        package func sendPage<C: WITransportPageCommand>(
            _ command: sending C,
            targetIdentifier: String
        ) async throws -> C.Response {
            try await ensureAttached()
            return try await transportSession.sendPage(command, targetIdentifier: targetIdentifier)
        }

        package func currentPageTargetIdentifier() async -> String? {
            await transportSession.currentPageTargetIdentifier()
        }

        package func pageTargetIdentifiers() async -> [String] {
            await transportSession.pageTargetIdentifiers()
        }

        package func sendRoot<C: WITransportRootCommand>(_ command: sending C) async throws -> C.Response {
            try await ensureAttached()
            return try await transportSession.root.send(command)
        }

        package func ensureCSSDomainReady() async throws {
            try await ensureAttached()
        }

        package func detach() {
            attachmentTask?.cancel()
            attachmentTask = nil
            eventHub.reset()
            pageTargetCoordinator.reset()
            transportSession.detach()
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private let sessionFactory: SessionFactory

    package init(sessionFactory: @escaping SessionFactory = { _ in WITransportSession() }) {
        self.sessionFactory = sessionFactory
    }

    package func acquireEntry(for webView: WKWebView) -> Entry {
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
        return entry
    }

    package func releaseEntry(_ entry: Entry) {
        if let webView = entry.webView {
            releaseEntryIfPossible(entry, preferredKey: ObjectIdentifier(webView))
        } else {
            releaseEntryIfPossible(entry, preferredKey: nil)
        }
    }
}

private extension TransportSessionPool {
    func releaseEntryIfPossible(_ entry: Entry, preferredKey: ObjectIdentifier?) {
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

    func removeEntry(_ entry: Entry, preferredKey: ObjectIdentifier?) {
        entry.detach()

        if let preferredKey {
            entries.removeValue(forKey: preferredKey)
            return
        }

        if let match = entries.first(where: { $0.value === entry }) {
            entries.removeValue(forKey: match.key)
        }
    }

    func purgeStaleEntries() {
        let staleKeys = entries.compactMap { key, entry in
            entry.webView == nil && entry.retainCount == 0 ? key : nil
        }

        for key in staleKeys {
            entries[key]?.detach()
            entries.removeValue(forKey: key)
        }
    }
}
