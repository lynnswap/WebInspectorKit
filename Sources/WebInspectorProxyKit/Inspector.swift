import Foundation

package enum Inspector {
    package struct Client: Sendable {
        private let context: DomainClientContext

        package init(context: DomainClientContext) {
            self.context = context
        }

        package func enable() async throws {
            try await context.dispatch(EnablePayload())
        }

        package func disable() async throws {
            try await context.dispatch(DisablePayload())
        }

        package func initialized() async throws {
            try await context.dispatch(InitializedPayload())
        }
    }

    package struct EnablePayload: Sendable {
        package init() {}
    }

    package struct DisablePayload: Sendable {
        package init() {}
    }

    package struct InitializedPayload: Sendable {
        package init() {}
    }

    package enum Event: Sendable {
        case inspect(Runtime.RemoteObject, hints: Runtime.JSONValue?)
        case unknown(RawEvent)
    }
}
