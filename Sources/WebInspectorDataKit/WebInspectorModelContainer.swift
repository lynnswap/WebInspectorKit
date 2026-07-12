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

    /// The current connection lifecycle state.
    public nonisolated var state: State {
        core.connectionState
    }

    /// A new current-value connection-state subscription.
    public nonisolated var stateUpdates: StateUpdateSequence {
        core.connectionStateUpdates
    }

    /// Creates a detached reusable model container.
    public nonisolated init(
        configuration: Configuration = .init()
    ) {
        let normalizedConfiguration = Configuration(
            domains: configuration.domains
        )
        self.configuration = normalizedConfiguration
        core = WebInspectorModelContainerCore(
            configuredDomains: normalizedConfiguration.modelDomains
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
        let core = core
        let attempt = try await core.reserveAttachmentAttempt()
        let createProxy:
            @MainActor @Sendable () async throws
                -> WebInspectorProxy = {
                    try await WebInspectorProxy(
                        attachingTo: webView,
                        configuration: proxyConfiguration
                    )
                }
        try await withTaskCancellationHandler {
            let nativeTask = Task.detached {
                try await attempt.waitForNativeCreationStart()
                try await core.beginNativeProxyCreation(for: attempt)
                try Task.checkCancellation()
                return try await createProxy()
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
