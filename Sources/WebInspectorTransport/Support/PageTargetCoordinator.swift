@MainActor
package final class PageTargetCoordinator {
    private let transportSession: WITransportSession

    private var pageTargetLifecycleTask: Task<Void, Never>?
    private var pageTargetLifecycleSubscriptionPending = false
    private var hasNetworkInterest = false
    private var hasDOMInterest = false
    private var networkEnabledTargetIdentifiers: Set<String> = []

    package init(transportSession: WITransportSession) {
        self.transportSession = transportSession
    }

    package func updateInterest(hasNetworkConsumers: Bool, hasDOMConsumers: Bool) {
        hasNetworkInterest = hasNetworkConsumers
        hasDOMInterest = hasDOMConsumers
    }

    package func ensureLifecycleTaskIfNeeded() async {
        guard pageTargetLifecycleTask == nil, !pageTargetLifecycleSubscriptionPending else {
            return
        }
        pageTargetLifecycleSubscriptionPending = true
        defer {
            pageTargetLifecycleSubscriptionPending = false
        }

        let pageTargetLifecycleStream = await transportSession.pageTargetLifecycleStream()

        pageTargetLifecycleTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            for await event in pageTargetLifecycleStream {
                if Task.isCancelled {
                    break
                }
                await self.handlePageTargetLifecycleEvent(event)
            }

            self.pageTargetLifecycleTask = nil
        }
    }

    package func prepareNetworkIngress() async throws {
        try await enableNetworkDomainOnCurrentTargetIfNeeded()
    }

    package func prepareDOMIngress() async throws {
        do {
            try await enableDOMDomainOnCurrentTargetIfNeeded()
        } catch let error as WITransportError {
            guard shouldIgnoreMissingDOMEnable(error) else {
                throw error
            }
        }
    }

    package func resetNetworkIngressState() {
        networkEnabledTargetIdentifiers.removeAll()
    }

    package func reset() {
        pageTargetLifecycleTask?.cancel()
        pageTargetLifecycleTask = nil
        pageTargetLifecycleSubscriptionPending = false
        hasNetworkInterest = false
        hasDOMInterest = false
        networkEnabledTargetIdentifiers.removeAll()
    }
}

private extension PageTargetCoordinator {
    func handlePageTargetLifecycleEvent(_ event: WITransportPageTargetLifecycleEvent) async {
        guard event.targetType == "page" else {
            return
        }

        if event.kind == .destroyed {
            networkEnabledTargetIdentifiers.remove(event.targetIdentifier)
        }

        if hasNetworkInterest {
            do {
                try await handleNetworkPageTargetLifecycleEvent(event)
            } catch {
                guard shouldIgnorePageTargetLifecycleError(error) else {
                    return
                }
            }
        }

        if hasDOMInterest {
            do {
                try await handleDOMPageTargetLifecycleEvent(event)
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

    func handleNetworkPageTargetLifecycleEvent(
        _ event: WITransportPageTargetLifecycleEvent
    ) async throws {
        switch event.kind {
        case .created, .committedProvisional:
            try await enableNetworkDomainIfNeeded(on: event.targetIdentifier)
        case .destroyed:
            try await enableNetworkDomainOnCurrentTargetIfNeeded()
        }
    }

    func handleDOMPageTargetLifecycleEvent(
        _ event: WITransportPageTargetLifecycleEvent
    ) async throws {
        switch event.kind {
        case .created:
            guard !event.isProvisional else {
                return
            }
            try await enableDOMDomainOnCurrentTargetIfNeeded(matching: event.targetIdentifier)
        case .committedProvisional:
            try await enableDOMDomainOnCurrentTargetIfNeeded(matching: event.targetIdentifier)
        case .destroyed:
            try await enableDOMDomainOnCurrentTargetIfNeeded()
        }
    }

    func enableNetworkDomainOnCurrentTargetIfNeeded() async throws {
        if let targetIdentifier = await transportSession.currentPageTargetIdentifier() {
            try await enableNetworkDomainIfNeeded(on: targetIdentifier)
            return
        }

        _ = try await transportSession.page.send(WITransportCommands.Network.Enable())
    }

    func enableNetworkDomainIfNeeded(on targetIdentifier: String) async throws {
        guard networkEnabledTargetIdentifiers.contains(targetIdentifier) == false else {
            return
        }

        _ = try await transportSession.sendPage(
            WITransportCommands.Network.Enable(),
            targetIdentifier: targetIdentifier
        )
        networkEnabledTargetIdentifiers.insert(targetIdentifier)
    }

    func enableDOMDomainOnCurrentTargetIfNeeded(
        matching expectedTargetIdentifier: String? = nil
    ) async throws {
        guard let targetIdentifier = await transportSession.currentPageTargetIdentifier() else {
            return
        }
        if let expectedTargetIdentifier, expectedTargetIdentifier != targetIdentifier {
            return
        }

        _ = try await transportSession.sendPage(
            WITransportCommands.DOM.Enable(),
            targetIdentifier: targetIdentifier
        )
    }

    func shouldIgnoreMissingDOMEnable(_ error: WITransportError) -> Bool {
        guard case let .remoteError(_, method, message) = error else {
            return false
        }
        guard method == WITransportCommands.DOM.Enable.method else {
            return false
        }
        return message.contains("'DOM.enable' was not found")
            || message.contains("DOM.enable was not found")
    }

    func shouldIgnorePageTargetLifecycleError(_ error: Error) -> Bool {
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
