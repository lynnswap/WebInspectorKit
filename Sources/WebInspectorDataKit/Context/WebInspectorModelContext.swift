import Foundation

/// A caller-confined identity map and generic query surface issued by one
/// model container.
///
/// The type is intentionally not Sendable. Stable identifiers and immutable
/// QueryValue values cross actors; observable model instances do not.
public final class WebInspectorModelContext: Equatable, SendableMetatype {
    public nonisolated let container: WebInspectorModelContainer
    package let lifecycle: WebInspectorModelContextLifecycle

    package init(
        container: WebInspectorModelContainer,
        executor: WebInspectorModelContextExecutor,
        store: WebInspectorModelStore,
        didClose: @escaping @Sendable (UUID) -> Void
    ) {
        self.container = container
        lifecycle = WebInspectorModelContextLifecycle(
            executor: executor,
            store: store,
            didClose: didClose
        )
        lifecycle.bind(to: self)
    }

    deinit {
        lifecycle.synchronouslyInvalidateDormantIssuance()
    }

    public static nonisolated func == (
        lhs: WebInspectorModelContext,
        rhs: WebInspectorModelContext
    ) -> Bool {
        lhs === rhs
    }

    /// Resolves or materializes the context-local observable model for an ID.
    public func model<ID>(for id: ID) -> ID.Model?
    where ID: WebInspectorPersistentIdentifier {
        lifecycle.activate()
        return lifecycle.materialize(id)
    }

    /// Returns a model only if this context already materialized its ID.
    public func registeredModel<ID>(for id: ID) -> ID.Model?
    where ID: WebInspectorPersistentIdentifier {
        lifecycle.activate()
        return lifecycle.registeredModel(id)
    }

    /// Fetches stable identifiers after predicate/sort evaluation on the query
    /// actor and returns on the caller's isolation.
    public nonisolated(nonsending) func fetchIdentifiers<Model>(
        _ descriptor: WebInspectorFetchDescriptor<Model>
    ) async throws -> [Model.ID]
    where Model: WebInspectorPersistentModel {
        let reply = WebInspectorContextReply<[Model.ID]>()
        guard
            lifecycle.requestFetchIdentifiers(
                descriptor: descriptor,
                reply: reply
            )
        else {
            throw lifecycle.closedFetchError
        }
        return try await reply.cancellableValue()
    }

    /// Fetches and materializes models on this context's owner executor.
    public nonisolated(nonsending) func fetch<Model>(
        _ descriptor: WebInspectorFetchDescriptor<Model>
    ) async throws -> [Model]
    where Model: WebInspectorPersistentModel {
        let itemIDs = try await fetchIdentifiers(descriptor)
        return itemIDs.compactMap { lifecycle.materialize($0) }
    }

    /// Closes this context without detaching its shared container.
    public nonisolated(nonsending) func close() async {
        let reply = lifecycle.beginClose(reason: .contextClosed)
        _ = try? await reply.value()
    }
}

@available(
    *,
    unavailable,
    message: "contexts cannot be shared across concurrency contexts"
)
extension WebInspectorModelContext: @unchecked Sendable {}
