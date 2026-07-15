import Observation

package protocol _WebInspectorAnyFetchedResultsEndpoint: Sendable {
    var registrationID: WebInspectorQueryRegistrationID { get }
    var modelTypeID: ObjectIdentifier { get }
    func close(reason: WebInspectorModelContextCloseReason)
}

package final class _WebInspectorFetchedResultsEndpoint<
    Model: WebInspectorPersistentModel
>: _WebInspectorAnyFetchedResultsEndpoint, @unchecked Sendable {
    private enum Phase {
        case open
        case closing
        case closed
    }

    package let id = WebInspectorQueryRegistrationID()
    package weak var controller: WebInspectorFetchedResultsController<Model>?
    package var pendingReply: WebInspectorContextReply<Void>?
    package let closeReply = WebInspectorContextReply<Void>()
    private var phase = Phase.open

    package var registrationID: WebInspectorQueryRegistrationID {
        id
    }

    package var modelTypeID: ObjectIdentifier {
        ObjectIdentifier(Model.self)
    }

    package func install(
        controller: WebInspectorFetchedResultsController<Model>
    ) {
        self.controller = controller
    }

    @discardableResult
    package func begin(
        reply: WebInspectorContextReply<Void>
    ) -> Bool {
        guard case .open = phase else {
            reply.fail(WebInspectorFetchError.contextClosed)
            return false
        }
        pendingReply?.fail(CancellationError())
        pendingReply = reply
        return true
    }

    package func beginClose() -> Bool {
        guard case .open = phase else { return false }
        phase = .closing
        return true
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
            var insertedItemIDs: Set<Model.ID> = []
            var deletedItemIDs: Set<Model.ID> = []
            for change in difference.itemChanges {
                switch change {
                case let .insert(itemID, _):
                    insertedItemIDs.insert(itemID)
                case let .delete(itemID, _):
                    deletedItemIDs.insert(itemID)
                case .move:
                    break
                }
            }
            let queryValueIDs = insertedItemIDs.union(
                difference.updatedItemIDs
            )
            let insertedModels = lifecycle.materialize(
                Array(insertedItemIDs),
                as: Model.self
            )
            let changedQueryValues = lifecycle.queryValues(
                Array(queryValueIDs),
                as: Model.self
            )
            controller.acceptChanges(
                insertedModels: Dictionary(
                    uniqueKeysWithValues: insertedModels.map { ($0.id, $0) }
                ),
                changedQueryValues: Dictionary(
                    uniqueKeysWithValues: changedQueryValues.map { ($0.id, $0) }
                ),
                deletedItemIDs: deletedItemIDs,
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

    package func close(
        reason: WebInspectorModelContextCloseReason
    ) {
        if case .closed = phase { return }
        phase = .closed
        controller?.acceptClose(reason.fetchError)
        pendingReply?.fail(reason.fetchError)
        pendingReply = nil
        closeReply.succeed(())
    }
}

/// A flat, identity-preserving fetched-results controller.
@Observable
public final class WebInspectorFetchedResultsController<
    Model: WebInspectorPersistentModel
> {
    private struct SuccessfulState {
        var descriptor: WebInspectorFetchDescriptor<Model>
        var fetchedObjectsByID: [Model.ID: Model]
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

    #if DEBUG
        @ObservationIgnored package private(set) var containsCallCountForTesting = 0
    #endif

    public var fetchDescriptor: WebInspectorFetchDescriptor<Model> {
        switch state {
        case let .pending(_, descriptor, _): descriptor
        case let .accepted(success): success.descriptor
        case let .closed(descriptor, _): descriptor
        }
    }

    public var fetchedObjects: [Model]? {
        guard let success = successfulState else { return nil }
        return success.snapshot.itemIDs.compactMap {
            success.fetchedObjectsByID[$0]
        }
    }

    public var snapshot: WebInspectorFetchedResultsSnapshot<Model.ID>? {
        successfulState?.snapshot
    }

    /// Immutable values from the same accepted state as fetchedObjects.
    /// Feature UI may transfer these values to background projection work
    /// without reading context-owned observable models off their executor.
    package var fetchedQueryValues: [Model.QueryValue]? {
        guard let success = successfulState else { return nil }
        return success.snapshot.itemIDs.compactMap {
            success.fetchedQueryValuesByID[$0]
        }
    }

    /// Returns the immutable value from the currently accepted result in O(1).
    /// The lookup and ``fetchedQueryValues`` are replaced in the same owner turn.
    package func fetchedQueryValue(for id: Model.ID) -> Model.QueryValue? {
        successfulState?.fetchedQueryValuesByID[id]
    }

    /// Returns whether the currently accepted result owns this identity.
    package func contains(_ id: Model.ID) -> Bool {
        #if DEBUG
            containsCallCountForTesting += 1
        #endif
        return successfulState?.fetchedObjectsByID[id] != nil
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
        if endpoint.begin(reply: reply),
            !modelContext.lifecycle.requestPerformFetch(
                endpoint: endpoint,
                descriptor: descriptor,
                reply: reply
            )
        {
            endpoint.acceptFailure(modelContext.lifecycle.closedFetchError)
        }
        try await reply.cancellableValue()
    }

    public nonisolated(nonsending) func refetch(
        using descriptor: WebInspectorFetchDescriptor<Model>
    ) async throws {
        let reply = WebInspectorContextReply<Void>()
        if endpoint.begin(reply: reply),
            !modelContext.lifecycle.requestRefetch(
                endpoint: endpoint,
                descriptor: descriptor,
                reply: reply
            )
        {
            endpoint.acceptFailure(modelContext.lifecycle.closedFetchError)
        }
        try await reply.cancellableValue()
    }

    public nonisolated(nonsending) func close() async {
        if endpoint.beginClose() {
            if !modelContext.lifecycle.requestClose(endpoint: endpoint) {
                endpoint.close(reason: .contextClosed)
            }
        }
        _ = try? await endpoint.closeReply.value()
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
        insertedModels: [Model.ID: Model],
        changedQueryValues: [Model.ID: Model.QueryValue],
        deletedItemIDs: Set<Model.ID>,
        itemIDs: [Model.ID],
        difference: WebInspectorFetchedResultsDifference<Model.ID>,
        clearsFetchError: Bool
    ) {
        guard var success = successfulState else { return }
        let fromRevision = success.revision
        let toRevision = WebInspectorFetchedResultsRevision(
            rawValue: fromRevision.rawValue + 1
        )
        for id in deletedItemIDs {
            success.fetchedObjectsByID[id] = nil
            success.fetchedQueryValuesByID[id] = nil
        }
        success.fetchedObjectsByID.merge(insertedModels) { _, new in new }
        success.fetchedQueryValuesByID.merge(changedQueryValues) { _, new in
            new
        }
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
            fetchedObjectsByID: Dictionary(
                uniqueKeysWithValues: models.map { ($0.id, $0) }
            ),
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
