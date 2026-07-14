import Observation

package class _WebInspectorAnyFetchedResultsEndpoint: @unchecked Sendable {
    package var registrationID: WebInspectorQueryRegistrationID {
        fatalError("abstract fetched-results endpoint")
    }

    package var modelTypeID: ObjectIdentifier {
        fatalError("abstract fetched-results endpoint")
    }

    package func close(reason: WebInspectorModelContextCloseReason) {
        fatalError("abstract fetched-results endpoint")
    }
}

package final class _WebInspectorFetchedResultsEndpoint<
    Model: WebInspectorPersistentModel
>: _WebInspectorAnyFetchedResultsEndpoint, @unchecked Sendable {
    package let id = WebInspectorQueryRegistrationID()
    package weak var controller: WebInspectorFetchedResultsController<Model>?
    package var pendingReply: WebInspectorContextReply<Void>?

    package override init() {}

    package override var registrationID: WebInspectorQueryRegistrationID {
        id
    }

    package override var modelTypeID: ObjectIdentifier {
        ObjectIdentifier(Model.self)
    }

    package func install(
        controller: WebInspectorFetchedResultsController<Model>
    ) {
        self.controller = controller
    }

    package func begin(
        reply: WebInspectorContextReply<Void>
    ) {
        pendingReply?.fail(CancellationError())
        pendingReply = reply
    }

    package func markOperationBegan(
        using descriptor: WebInspectorFetchDescriptor<Model>
    ) {
        controller?.beginFetch(using: descriptor)
    }

    package func accept(
        itemIDs: [Model.ID],
        disposition:
            _WebInspectorQueryAttempt<Model>.SuccessDisposition,
        lifecycle: WebInspectorModelContextLifecycle
    ) {
        guard let controller else {
            pendingReply?.fail(CancellationError())
            pendingReply = nil
            return
        }
        let models = lifecycle.materialize(itemIDs, as: Model.self)
        let queryValues = lifecycle.queryValues(itemIDs, as: Model.self)
        switch disposition {
        case .initial:
            controller.acceptInitial(
                models: models,
                queryValues: queryValues,
                itemIDs: itemIDs
            )
        case .reset:
            controller.acceptReset(
                models: models,
                queryValues: queryValues,
                itemIDs: itemIDs
            )
        }
        pendingReply?.succeed(())
        pendingReply = nil
    }

    package func apply(
        _ delivery: _WebInspectorQueryDelivery<Model>,
        lifecycle: WebInspectorModelContextLifecycle
    ) {
        guard let controller else { return }
        switch delivery.kind {
        case let .initial(itemIDs):
            let models = lifecycle.materialize(itemIDs, as: Model.self)
            let queryValues = lifecycle.queryValues(itemIDs, as: Model.self)
            controller.acceptInitial(
                models: models,
                queryValues: queryValues,
                itemIDs: itemIDs
            )
            pendingReply?.succeed(())
            pendingReply = nil
        case let .changes(itemIDs, difference):
            let models = lifecycle.materialize(itemIDs, as: Model.self)
            let queryValues = lifecycle.queryValues(itemIDs, as: Model.self)
            controller.acceptChanges(
                models: models,
                queryValues: queryValues,
                itemIDs: itemIDs,
                difference: difference,
                clearsFetchError: delivery.clearsFetchError
            )
        case let .reset(itemIDs):
            let models = lifecycle.materialize(itemIDs, as: Model.self)
            let queryValues = lifecycle.queryValues(itemIDs, as: Model.self)
            controller.acceptReset(
                models: models,
                queryValues: queryValues,
                itemIDs: itemIDs,
                clearsFetchError: delivery.clearsFetchError
            )
            pendingReply?.succeed(())
            pendingReply = nil
        case let .failure(error):
            controller.acceptFailure(error)
            pendingReply?.fail(error)
            pendingReply = nil
        }
    }

    package func acceptFailure(_ error: WebInspectorFetchError) {
        controller?.acceptFailure(error)
        pendingReply?.fail(error)
        pendingReply = nil
    }

    package override func close(
        reason: WebInspectorModelContextCloseReason
    ) {
        controller?.acceptClose(reason.fetchError)
        pendingReply?.fail(reason.fetchError)
        pendingReply = nil
    }
}

/// A flat, identity-preserving fetched-results controller.
@Observable
public final class WebInspectorFetchedResultsController<
    Model: WebInspectorPersistentModel
> {
    private struct SuccessfulState {
        var descriptor: WebInspectorFetchDescriptor<Model>
        var fetchedObjects: [Model]
        var fetchedQueryValues: [Model.QueryValue]
        var fetchedQueryValuesByID: [Model.ID: Model.QueryValue]
        var snapshot: WebInspectorFetchedResultsSnapshot<Model.ID>
        var revision: WebInspectorFetchedResultsRevision
    }

    private enum State {
        case pending(
            accepted: SuccessfulState?,
            requestedDescriptor: WebInspectorFetchDescriptor<Model>,
            fetchError: (any Error)?
        )
        case accepted(SuccessfulState)
        case closed(
            descriptor: WebInspectorFetchDescriptor<Model>,
            error: WebInspectorFetchError
        )
    }

    public let modelContext: WebInspectorModelContext
    private var state: State

    @ObservationIgnored private let endpoint: _WebInspectorFetchedResultsEndpoint<Model>
    @ObservationIgnored private let publisher =
        _WebInspectorFetchedResultsUpdatePublisher<Model.ID>()

    public var fetchDescriptor: WebInspectorFetchDescriptor<Model> {
        switch state {
        case let .pending(_, descriptor, _): descriptor
        case let .accepted(success): success.descriptor
        case let .closed(descriptor, _): descriptor
        }
    }

    public var fetchedObjects: [Model]? {
        successfulState?.fetchedObjects
    }

    public var snapshot: WebInspectorFetchedResultsSnapshot<Model.ID>? {
        successfulState?.snapshot
    }

    /// Immutable values from the same accepted state as fetchedObjects.
    /// Feature UI may transfer these values to background projection work
    /// without reading context-owned observable models off their executor.
    package var fetchedQueryValues: [Model.QueryValue]? {
        successfulState?.fetchedQueryValues
    }

    /// Returns the immutable value from the currently accepted result in O(1).
    /// The lookup and ``fetchedQueryValues`` are replaced in the same owner turn.
    package func fetchedQueryValue(for id: Model.ID) -> Model.QueryValue? {
        successfulState?.fetchedQueryValuesByID[id]
    }

    public var revision: WebInspectorFetchedResultsRevision? {
        successfulState?.revision
    }

    public var fetchError: (any Error)? {
        switch state {
        case let .pending(_, _, error): error
        case .accepted: nil
        case let .closed(_, error): error
        }
    }

    public var updates: WebInspectorFetchedResultsUpdateSequence<Model.ID> {
        publisher.sequence()
    }

    public init(
        fetchDescriptor: WebInspectorFetchDescriptor<Model> = .init(),
        modelContext: WebInspectorModelContext
    ) {
        self.modelContext = modelContext
        state = .pending(
            accepted: nil,
            requestedDescriptor: fetchDescriptor,
            fetchError: nil
        )
        let endpoint = _WebInspectorFetchedResultsEndpoint<Model>()
        self.endpoint = endpoint
        endpoint.install(controller: self)
    }

    deinit {
        endpoint.pendingReply?.fail(CancellationError())
        publisher.finish()
        modelContext.lifecycle.synchronouslyInvalidateRegistration(endpoint)
    }

    public nonisolated(nonsending) func performFetch() async throws {
        let descriptor = fetchDescriptor
        let reply = WebInspectorContextReply<Void>()
        endpoint.begin(reply: reply)
        if !modelContext.lifecycle.requestPerformFetch(
            endpoint: endpoint,
            descriptor: descriptor,
            reply: reply
        ) {
            endpoint.acceptFailure(modelContext.lifecycle.closedFetchError)
        }
        try await reply.cancellableValue()
    }

    public nonisolated(nonsending) func refetch(
        using descriptor: WebInspectorFetchDescriptor<Model>
    ) async throws {
        let reply = WebInspectorContextReply<Void>()
        endpoint.begin(reply: reply)
        if !modelContext.lifecycle.requestRefetch(
            endpoint: endpoint,
            descriptor: descriptor,
            reply: reply
        ) {
            endpoint.acceptFailure(modelContext.lifecycle.closedFetchError)
        }
        try await reply.cancellableValue()
    }

    public nonisolated(nonsending) func close() async {
        let reply = WebInspectorContextReply<Void>()
        if modelContext.lifecycle.requestClose(
            endpoint: endpoint,
            reply: reply
        ) {
            _ = try? await reply.value()
        } else {
            endpoint.close(reason: .contextClosed)
        }
    }

    /// Best-effort synchronous teardown for an owner-isolated deinitializer.
    /// Explicit ``close()`` remains the deterministic async join authority.
    package func synchronouslyInvalidateRegistration() {
        publisher.finish()
        modelContext.lifecycle.synchronouslyInvalidateRegistration(endpoint)
        acceptClose(modelContext.lifecycle.closedFetchError)
    }

    private var successfulState: SuccessfulState? {
        switch state {
        case let .pending(accepted, _, _): accepted
        case let .accepted(success): success
        case .closed: nil
        }
    }

    package func beginFetch(
        using descriptor: WebInspectorFetchDescriptor<Model>
    ) {
        if case .closed = state { return }
        state = .pending(
            accepted: successfulState,
            requestedDescriptor: descriptor,
            fetchError: nil
        )
    }

    package func acceptInitial(
        models: [Model],
        queryValues: [Model.QueryValue],
        itemIDs: [Model.ID]
    ) {
        acceptSuccess(
            models: models,
            queryValues: queryValues,
            itemIDs: itemIDs,
            disposition: .initial,
            clearsFetchError: true
        )
    }

    package func acceptReset(
        models: [Model],
        queryValues: [Model.QueryValue],
        itemIDs: [Model.ID],
        clearsFetchError: Bool = true
    ) {
        acceptSuccess(
            models: models,
            queryValues: queryValues,
            itemIDs: itemIDs,
            disposition: successfulState == nil ? .initial : .reset,
            clearsFetchError: clearsFetchError
        )
    }

    package func acceptChanges(
        models: [Model],
        queryValues: [Model.QueryValue],
        itemIDs: [Model.ID],
        difference: WebInspectorFetchedResultsDifference<Model.ID>,
        clearsFetchError: Bool
    ) {
        guard var success = successfulState else { return }
        let fromRevision = success.revision
        let toRevision = WebInspectorFetchedResultsRevision(
            rawValue: fromRevision.rawValue + 1
        )
        success.fetchedObjects = models
        success.fetchedQueryValues = queryValues
        success.fetchedQueryValuesByID = Dictionary(
            uniqueKeysWithValues: queryValues.map { ($0.id, $0) }
        )
        success.snapshot = WebInspectorFetchedResultsSnapshot(
            itemIDs: itemIDs
        )
        success.revision = toRevision

        switch state {
        case let .pending(_, descriptor, error):
            state = .pending(
                accepted: success,
                requestedDescriptor: descriptor,
                fetchError: clearsFetchError ? nil : error
            )
        case .accepted:
            state = .accepted(success)
        case .closed:
            return
        }

        let update = WebInspectorFetchedResultsUpdate<Model.ID>.changes(
            fromRevision: fromRevision,
            toRevision: toRevision,
            itemChanges: difference.itemChanges,
            updatedItemIDs: difference.updatedItemIDs
        )
        publisher.publish(
            update,
            revision: toRevision,
            snapshot: success.snapshot
        )
    }

    package func acceptFailure(_ error: WebInspectorFetchError) {
        if case .closed = state { return }
        state = .pending(
            accepted: successfulState,
            requestedDescriptor: fetchDescriptor,
            fetchError: error
        )
    }

    package func acceptClose(_ error: WebInspectorFetchError) {
        if case .closed = state { return }
        state = .closed(descriptor: fetchDescriptor, error: error)
        publisher.finish()
    }

    private enum PublicationDisposition {
        case initial
        case reset
    }

    private func acceptSuccess(
        models: [Model],
        queryValues: [Model.QueryValue],
        itemIDs: [Model.ID],
        disposition: PublicationDisposition,
        clearsFetchError: Bool
    ) {
        if case .closed = state { return }
        let descriptor: WebInspectorFetchDescriptor<Model>
        let preservedPending: (WebInspectorFetchDescriptor<Model>, (any Error)?)?
        switch state {
        case let .pending(accepted, requestedDescriptor, error):
            descriptor =
                clearsFetchError
                ? requestedDescriptor
                : accepted?.descriptor ?? requestedDescriptor
            preservedPending =
                clearsFetchError
                ? nil
                : (requestedDescriptor, error)
        case let .accepted(success):
            descriptor = success.descriptor
            preservedPending = nil
        case .closed:
            return
        }

        let nextRevision = WebInspectorFetchedResultsRevision(
            rawValue: (successfulState?.revision.rawValue ?? 0) + 1
        )
        let snapshot = WebInspectorFetchedResultsSnapshot(
            itemIDs: itemIDs
        )
        let success = SuccessfulState(
            descriptor: descriptor,
            fetchedObjects: models,
            fetchedQueryValues: queryValues,
            fetchedQueryValuesByID: Dictionary(
                uniqueKeysWithValues: queryValues.map { ($0.id, $0) }
            ),
            snapshot: snapshot,
            revision: nextRevision
        )
        if let preservedPending {
            state = .pending(
                accepted: success,
                requestedDescriptor: preservedPending.0,
                fetchError: preservedPending.1
            )
        } else {
            state = .accepted(success)
        }

        let update: WebInspectorFetchedResultsUpdate<Model.ID> =
            switch disposition {
            case .initial:
                .initial(revision: nextRevision, snapshot: snapshot)
            case .reset:
                .reset(revision: nextRevision, snapshot: snapshot)
            }
        publisher.publish(
            update,
            revision: nextRevision,
            snapshot: snapshot
        )
    }
}
