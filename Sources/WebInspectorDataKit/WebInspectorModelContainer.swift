import WebInspectorProxyKit
import WebKit

/// Owns one reusable Web Inspector model session and its connection lifecycle.
public final class WebInspectorModelContainer: Equatable, Sendable {
    /// A model-feed domain included in the canonical store.
    public struct Domain: Hashable, Sendable {
        /// Document Object Model records.
        public static let dom = Domain(.dom)

        /// Network request records.
        public static let network = Domain(.network)

        /// Console message records.
        public static let console = Domain(.console)

        /// Runtime execution-context records.
        public static let runtime = Domain(.runtime)

        /// CSS records. CSS also enables the DOM domain.
        public static let css = Domain(.css)

        package let modelDomain: ModelDomain

        private init(_ modelDomain: ModelDomain) {
            self.modelDomain = modelDomain
        }
    }

    /// Immutable configuration copied by a model container at initialization.
    public struct Configuration: Sendable {
        /// Domains projected by the container's single model feed.
        public var domains: Set<Domain>

        /// Creates a model-container configuration.
        public init(
            domains: Set<Domain> = [
                .dom, .network, .console, .runtime, .css,
            ]
        ) {
            self.domains = domains
            if domains.contains(.css) {
                self.domains.insert(.dom)
            }
        }

        package var modelDomains: Set<ModelDomain> {
            Set(domains.map(\.modelDomain))
        }
    }

    /// A terminal or retryable physical connection failure.
    public enum ConnectionFailure: Equatable, Sendable {
        /// The Proxy connection closed.
        case closed

        /// The inspected page is no longer available.
        case pageUnavailable

        /// An inspector message violated the expected protocol contract.
        case protocolViolation(String)

        /// The underlying inspector transport failed.
        case transport(String)
    }

    /// An attachment operation failure.
    public enum Failure: Error, LocalizedError, Equatable, Sendable {
        /// The container was already permanently closed.
        case closed

        /// A newer attachment intent superseded this pending attempt.
        case attachmentSuperseded

        /// One configured model domain failed during initial synchronization.
        case bootstrap(domain: Domain, message: String)

        /// The physical inspector connection failed.
        case connection(ConnectionFailure)

        public var errorDescription: String? {
            switch self {
            case .closed:
                "The model container is closed."
            case .attachmentSuperseded:
                "A newer attachment replaced this attachment attempt."
            case let .bootstrap(domain, message):
                "The \(domain.description) model domain failed to synchronize: \(message)"
            case let .connection(failure):
                failure.description
            }
        }
    }

    /// The current connection lifecycle state.
    public enum State: Equatable, Sendable {
        /// No Proxy is currently adopted.
        case detached

        /// A candidate Proxy is being created or synchronized.
        case attaching

        /// One synchronized Proxy and model feed are adopted.
        case attached

        /// The adopted attachment is being reset and closed.
        case detaching

        /// The current attempt or adopted connection failed.
        case failed(Failure)

        /// Terminal container teardown is in progress.
        case closing

        /// Terminal container teardown completed.
        case closed
    }

    /// A current-value sequence of connection states.
    ///
    /// Each sequence starts atomically with the current state, retains only the
    /// newest unconsumed state, delivers ``State/closed``, and then finishes.
    public struct StateUpdateSequence: AsyncSequence, Sendable {
        public typealias Element = State

        public struct AsyncIterator: AsyncIteratorProtocol, Sendable {
            private let subscription: WebInspectorModelContainerStateSubscription

            package init(
                subscription: WebInspectorModelContainerStateSubscription
            ) {
                self.subscription = subscription
            }

            public mutating func next() async -> State? {
                await subscription.mailbox.next()
            }
        }

        private let subscription: WebInspectorModelContainerStateSubscription

        package init(
            subscription: WebInspectorModelContainerStateSubscription
        ) {
            self.subscription = subscription
        }

        public func makeAsyncIterator() -> AsyncIterator {
            subscription.mailbox.claimIterator()
            return AsyncIterator(subscription: subscription)
        }
    }

    /// The configuration copied when this container was created.
    public nonisolated let configuration: Configuration

    package let core: WebInspectorModelContainerCore

    @MainActor private weak var cachedMainContext: WebInspectorModelContext?

    /// The current connection lifecycle state.
    public nonisolated var state: State {
        core.connectionState
    }

    /// A new current-value connection-state subscription.
    public nonisolated var stateUpdates: StateUpdateSequence {
        core.connectionStateUpdates
    }

    /// The stable main-actor model context for UI consumers.
    @MainActor
    public var mainContext: WebInspectorModelContext {
        if let cachedMainContext {
            return cachedMainContext
        }
        let context = WebInspectorModelContext.mainContext(
            for: self,
            isolation: MainActor.shared
        )
        cachedMainContext = context
        return context
    }

    /// Creates a detached reusable model container.
    public nonisolated init(
        configuration: Configuration = .init()
    ) {
        let normalizedConfiguration = Configuration(
            domains: configuration.domains
        )
        let modelDomains = normalizedConfiguration.modelDomains
        self.configuration = normalizedConfiguration
        core = WebInspectorModelContainerCore(
            configuredDomains: modelDomains,
            modelSchemaRegistry: WebInspectorModelSchemaInventory.registry(
                configuredDomains: modelDomains
            )
        )
    }

    package nonisolated init(
        configuration: Configuration,
        modelSchemaRegistry: WebInspectorModelSchemaRegistry
    ) {
        let normalizedConfiguration = Configuration(
            domains: configuration.domains
        )
        self.configuration = normalizedConfiguration
        core = WebInspectorModelContainerCore(
            configuredDomains: normalizedConfiguration.modelDomains,
            modelSchemaRegistry: modelSchemaRegistry
        )
    }

    /// Creates a container and attaches it to a web view.
    @MainActor
    public convenience init(
        attachingTo webView: WKWebView,
        configuration: Configuration = .init(),
        proxyConfiguration: WebInspectorProxy.Configuration = .init()
    ) async throws {
        self.init(configuration: configuration)
        try await attach(
            to: webView,
            proxyConfiguration: proxyConfiguration
        )
    }

    /// Attaches this container to a web view.
    @MainActor
    public func attach(
        to webView: WKWebView,
        proxyConfiguration: WebInspectorProxy.Configuration = .init()
    ) async throws {
        try await attach {
            try await WebInspectorProxy(
                attachingTo: webView,
                configuration: proxyConfiguration
            )
        }
    }

    package func attach(
        makeProxy: @escaping @MainActor @Sendable () async throws
            -> WebInspectorProxy
    ) async throws {
        let core = core
        let attempt = try await core.reserveAttachmentAttempt()
        try await withTaskCancellationHandler {
            let nativeTask = Task.detached {
                try await attempt.waitForNativeCreationStart()
                try await core.beginNativeProxyCreation(for: attempt)
                try Task.checkCancellation()
                return try await makeProxy()
            }
            await core.installNativeProxyCreationTask(
                nativeTask,
                for: attempt
            )
            try await core.completeAttachmentAttempt(attempt)
        } onCancel: {
            attempt.cancelFromCaller()
        }
    }

    /// Adopts exclusive ownership of an already connected ProxyKit connection.
    package func attach(owning proxy: WebInspectorProxy) async throws {
        try await core.attach(owning: proxy)
    }

    package func synchronizationCheckpoint() async throws
        -> WebInspectorModelContainerSynchronizationCursor
    {
        try await core.synchronizationCheckpoint()
    }

    package func waitForSynchronization(
        after checkpoint: WebInspectorModelContainerSynchronizationCursor
    ) async throws -> WebInspectorModelContainerSynchronizationCursor {
        try await core.waitForSynchronization(after: checkpoint)
    }

    /// Creates an independently owned context on the caller's actor.
    public func makeContext(
        isolation: isolated (any Actor) = #isolation
    ) async throws -> WebInspectorModelContext {
        let registration: WebInspectorModelContextRegistration
        do {
            registration = try await core.registerContext()
        } catch WebInspectorModelContainerCoreError.closed {
            throw Failure.closed
        } catch {
            preconditionFailure(
                "Model context registration failed outside its public contract: \(error)"
            )
        }

        do {
            try Task.checkCancellation()
        } catch {
            _ = await core.abandonContext(registration.id)
            throw error
        }

        guard
            let context = WebInspectorModelContext.customContext(
                for: self,
                registration: registration,
                isolation: isolation
            )
        else {
            _ = await core.abandonContext(registration.id)
            throw Failure.closed
        }

        try await context.waitUntilReady()
        return context
    }

    /// Detaches the current connection while preserving this container.
    public func detach() async {
        await core.detachConnection()
    }

    /// Permanently closes the container and every resource it owns.
    public func close() async {
        await core.closeConnection()
    }

    public nonisolated static func == (
        lhs: WebInspectorModelContainer,
        rhs: WebInspectorModelContainer
    ) -> Bool {
        lhs === rhs
    }
}

package extension WebInspectorModelContainer.Domain {
    var description: String {
        switch modelDomain {
        case .dom:
            "DOM"
        case .network:
            "Network"
        case .console:
            "Console"
        case .runtime:
            "Runtime"
        case .css:
            "CSS"
        }
    }
}

private extension WebInspectorModelContainer.ConnectionFailure {
    var description: String {
        switch self {
        case .closed:
            "The inspector connection closed."
        case .pageUnavailable:
            "The inspected page is unavailable."
        case let .protocolViolation(message):
            "The inspector protocol was violated: \(message)"
        case let .transport(message):
            "The inspector transport failed: \(message)"
        }
    }
}
