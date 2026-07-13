import Observation
import Synchronization
import WebInspectorProxyKit

/// Failures caused by the current semantic model state rather than transport.
public enum WebInspectorModelError: Error, Equatable, Sendable {
    case detached
    case synchronizing
    case domainNotConfigured(WebInspectorModelContainer.Domain)
    case staleModel
    case commandRejected(method: String, message: String)
}

/// The audited dynamic hop from a container driver to a runtime-selected
/// context actor. It owns no semantic state, task, feed, proxy, or lifecycle.
private final class WebInspectorModelOwnerEndpoint: @unchecked Sendable {
    enum Delivery: Equatable, Sendable {
        case applied(revision: UInt64)
        case closing
    }

    enum Request: Sendable {
        case apply(WebInspectorModelSchemaTransactionCommit)
        case beginClosing
        case finishClosing(WebInspectorModelSchemaClose)
    }

    enum Response: Sendable {
        case delivery(Delivery)
        case accepted(Bool)
    }

    private let mutex = Mutex(())
    private weak var actor: (any Actor)?
    private weak var context: WebInspectorModelContext?

    func bind(
        _ context: WebInspectorModelContext,
        isolation: isolated (any Actor)
    ) {
        mutex.withLock { _ in
            precondition(
                actor == nil && self.context == nil,
                "A model owner endpoint cannot be rebound."
            )
            actor = isolation
            self.context = context
        }
    }

    func preconditionOwnerIsolation() {
        mutex.withLock { _ in actor }?.preconditionIsolated(
            "WebInspectorModelContext must be used by its owning actor."
        )
    }

    func resolveActor() -> (any Actor)? {
        mutex.withLock { _ in actor }
    }

    func deliver(
        _ request: Request,
        isolation: isolated (any Actor)
    ) -> Response? {
        let context = mutex.withLock { _ -> WebInspectorModelContext? in
            guard let actor else {
                return nil
            }
            precondition(
                actor === isolation,
                "Model delivery ran on a foreign actor."
            )
            return context
        }
        guard let context else {
            return nil
        }
        switch request {
        case let .apply(commit):
            return .delivery(context.applyContainerTransaction(commit))
        case .beginClosing:
            return .accepted(context.beginClosingProjection())
        case let .finishClosing(close):
            return .accepted(context.finishClosingProjection(close))
        }
    }
}

private struct WebInspectorPreparedModelContext {
    let context: WebInspectorModelContext
    let startGate: ReplyPromise<Bool>
}

/// An actor-confined identity graph and query surface owned by a model
/// container.
///
/// A context never owns or attaches a Proxy connection. Observable persistent
/// models remain local to this context; only stable identifiers and immutable
/// records cross isolation boundaries.
@Observable
public final class WebInspectorModelContext: Equatable, SendableMetatype {
    /// The model container that owns this context and its canonical store.
    public nonisolated let container: WebInspectorModelContainer

    @ObservationIgnored package let fetchedResultsQueryCore:
        WebInspectorModelContextCore
    @ObservationIgnored package let modelSchemaContextCore:
        WebInspectorModelSchemaContextCore
    @ObservationIgnored private let modelSchemaOwnerRegistry:
        WebInspectorModelSchemaOwnerRegistry
    @ObservationIgnored private let fetchedResultsControllerRegistry:
        WebInspectorFetchedResultsControllerOwnerRegistry
    @ObservationIgnored private let fetchedResultsControllerRetirementOwner:
        WebInspectorFetchedResultsControllerRetirementOwner
    @ObservationIgnored private let ownerEndpoint:
        WebInspectorModelOwnerEndpoint
    @ObservationIgnored let cssInspectorBaselineStore:
        CSSInspectorBaselineStore
    @ObservationIgnored private let registrationID:
        WebInspectorModelContextRegistrationID
    @ObservationIgnored private var driverTask: Task<Void, Never>?
    @ObservationIgnored private var readiness: ReplyPromise<Void>?
    @ObservationIgnored private var appliedRevision: UInt64?
    @ObservationIgnored private var projectionIsClosing = false
    @ObservationIgnored private var projectionIsClosed = false

    /// Compares contexts by object identity.
    public nonisolated static func == (
        lhs: WebInspectorModelContext,
        rhs: WebInspectorModelContext
    ) -> Bool {
        lhs === rhs
    }

    private init(
        container: WebInspectorModelContainer,
        registrationID: WebInspectorModelContextRegistrationID
    ) {
        let schema = container.core.modelSchemaRegistry.makeContext()
        let queryCore = WebInspectorModelContextCore(
            configuredModelTypeIDs:
                container.core.modelSchemaRegistry.configuredModelTypeIDs
        )
        self.container = container
        self.registrationID = registrationID
        fetchedResultsQueryCore = queryCore
        modelSchemaContextCore = schema.core
        modelSchemaOwnerRegistry = schema.owner
        fetchedResultsControllerRegistry =
            WebInspectorFetchedResultsControllerOwnerRegistry(
                contextIdentity: queryCore.identity
            )
        fetchedResultsControllerRetirementOwner =
            WebInspectorFetchedResultsControllerRetirementOwner()
        ownerEndpoint = WebInspectorModelOwnerEndpoint()
        cssInspectorBaselineStore = CSSInspectorBaselineStore()
        modelSchemaOwnerRegistry.bind(to: self)
    }

    package static func mainContext(
        for container: WebInspectorModelContainer,
        isolation: isolated (any Actor)
    ) -> WebInspectorModelContext {
        let seed = container.core.mainContextSeed
        let prepared = prepare(
            container: container,
            registrationID: seed.id,
            updates: seed.updates,
            isolation: isolation
        )
        switch seed.claimForMaterialization() {
        case .admitted:
            prepared.startGate.fulfill(.success(true))
        case .closed:
            _ = prepared.context.beginClosingProjection()
            prepared.startGate.fulfill(.success(false))
        }
        return prepared.context
    }

    package static func customContext(
        for container: WebInspectorModelContainer,
        registration: WebInspectorModelContextRegistration,
        isolation: isolated (any Actor)
    ) -> WebInspectorModelContext? {
        let prepared = prepare(
            container: container,
            registrationID: registration.id,
            updates: registration.updates,
            isolation: isolation
        )
        guard registration.claimForMaterialization() == .admitted else {
            _ = prepared.context.beginClosingProjection()
            prepared.startGate.fulfill(.success(false))
            return nil
        }
        prepared.startGate.fulfill(.success(true))
        return prepared.context
    }

    private static func prepare(
        container: WebInspectorModelContainer,
        registrationID: WebInspectorModelContextRegistrationID,
        updates: WebInspectorCanonicalModelUpdateSequence,
        isolation: isolated (any Actor)
    ) -> WebInspectorPreparedModelContext {
        let context = WebInspectorModelContext(
            container: container,
            registrationID: registrationID
        )
        context.ownerEndpoint.bind(context, isolation: isolation)
        let readiness = ReplyPromise<Void>()
        context.readiness = readiness
        let startGate = ReplyPromise<Bool>()
        context.driverTask = makeDriverTask(
            core: container.core,
            registrationID: registrationID,
            updates: updates,
            startGate: startGate,
            readiness: readiness,
            queryCore: context.fetchedResultsQueryCore,
            retirementOwner: context.fetchedResultsControllerRetirementOwner,
            schemaCore: context.modelSchemaContextCore,
            endpoint: context.ownerEndpoint
        )
        return WebInspectorPreparedModelContext(
            context: context,
            startGate: startGate
        )
    }

    deinit {
        driverTask?.cancel()
    }

    /// Returns the context-local model only when this context has already
    /// materialized the identifier.
    public func registeredModel<ID: WebInspectorPersistentIdentifier>(
        for id: ID
    ) -> ID.Model? {
        preconditionOwnerIsolation()
        return modelSchemaOwnerRegistry.registeredModel(for: id, owner: self)
    }

    /// Resolves an identifier into this context's stable Observable model.
    public func model<ID: WebInspectorPersistentIdentifier>(
        for id: ID
    ) -> ID.Model? {
        preconditionOwnerIsolation()
        return modelSchemaOwnerRegistry.model(for: id, owner: self)
    }

    package func modelSchemaOwnerResource<
        Model: WebInspectorPersistentModel,
        Resource: AnyObject
    >(
        for model: Model.Type,
        as resource: Resource.Type
    ) -> Resource? {
        preconditionOwnerIsolation()
        return modelSchemaOwnerRegistry.ownerResource(
            for: model,
            as: resource,
            owner: self
        )
    }

    /// Returns one actor-evaluated snapshot of matching persistent IDs.
    public nonisolated(nonsending) func fetchIdentifiers<
        Model: WebInspectorPersistentModel
    >(
        _ descriptor: WebInspectorFetchDescriptor<Model>
    ) async throws -> [Model.ID] {
        preconditionOwnerIsolation()
        try await waitUntilReady()
        guard !projectionIsClosed else {
            throw WebInspectorModelContextQueryError.closed
        }
        do {
            return try await fetchedResultsQueryCore.fetchIdentifiers(
                Model.self,
                fetchDescriptor: descriptor
            )
        } catch WebInspectorFetchedResultsQueryError.closedRegistration {
            throw WebInspectorModelContextQueryError.closed
        }
    }

    /// Materializes one complete query snapshot before releasing its source
    /// admission claim.
    public nonisolated(nonsending) func fetch<
        Model: WebInspectorPersistentModel
    >(
        _ descriptor: WebInspectorFetchDescriptor<Model>
    ) async throws -> [Model] {
        preconditionOwnerIsolation()
        try await waitUntilReady()
        guard !projectionIsClosed else {
            throw WebInspectorModelContextQueryError.closed
        }
        let claim: WebInspectorModelFetchClaim<Model>
        do {
            claim = try await fetchedResultsQueryCore.prepareModelFetch(
                Model.self,
                fetchDescriptor: descriptor
            )
        } catch WebInspectorFetchedResultsQueryError.closedRegistration {
            throw WebInspectorModelContextQueryError.closed
        }
        do {
            try Task.checkCancellation()
        } catch {
            await claim.abandon()
            throw error
        }
        guard !projectionIsClosed, !claim.wasAbandoned else {
            await claim.abandon()
            throw WebInspectorModelContextQueryError.closed
        }
        let models = claim.ids.map { id -> Model in
            guard let model = model(for: id) else {
                preconditionFailure(
                    "A fetch ID must resolve before owner admission is released."
                )
            }
            return model
        }
        guard await claim.complete() == .activated else {
            throw WebInspectorModelContextQueryError.closed
        }
        return models
    }

    /// Closes only this context registration. The container and its other
    /// contexts remain active.
    public nonisolated(nonsending) func close() async {
        preconditionOwnerIsolation()
        let task = driverTask
        let shouldNotifyCore = !projectionIsClosing
        _ = beginClosingProjection()
        if shouldNotifyCore {
            do {
                _ = try await container.core.beginContextClose(registrationID)
            } catch WebInspectorModelContainerCoreError.closed {
                // Container teardown owns the same terminal boundary.
            } catch {
                preconditionFailure(
                    "A model context close lost its Core registration: \(error)"
                )
            }
        }
        await task?.value
        driverTask = nil
    }

    package nonisolated(nonsending) func waitUntilReady() async throws {
        preconditionOwnerIsolation()
        guard let readiness else {
            throw WebInspectorModelContextQueryError.closed
        }
        try await readiness.valueIgnoringCancellation()
    }

    package func preconditionOwnerIsolation() {
        ownerEndpoint.preconditionOwnerIsolation()
    }

    package func requireConfigured(
        _ domain: WebInspectorModelContainer.Domain
    ) throws {
        preconditionOwnerIsolation()
        guard container.configuration.domains.contains(domain) else {
            throw WebInspectorModelError.domainNotConfigured(domain)
        }
        guard !projectionIsClosed else {
            throw WebInspectorModelError.staleModel
        }
    }

    package var appliedContainerRevisionForTesting: UInt64? {
        preconditionOwnerIsolation()
        return appliedRevision
    }

    @discardableResult
    package func publish(
        _ commit: WebInspectorModelSchemaTransactionCommit
    ) -> Bool {
        preconditionOwnerIsolation()
        return commit.publish(on: modelSchemaOwnerRegistry, owner: self)
    }

    package func applyFetchedResultsControllerOwnerMutations(
        _ mutations: [WebInspectorFetchedResultsControllerOwnerMutationBatch]
    ) {
        preconditionOwnerIsolation()
        fetchedResultsControllerRegistry.apply(mutations)
    }

    package func installFetchedResultsController<
        Model: WebInspectorPersistentModel,
        SectionName: Hashable & Sendable
    >(
        _ controller: WebInspectorFetchedResultsController<Model, SectionName>,
        ownerID: WebInspectorFetchedResultsControllerOwnerID,
        lease: WebInspectorFetchedResultsControllerRegistrationLease
    ) throws {
        preconditionOwnerIsolation()
        guard !projectionIsClosed else {
            throw WebInspectorFetchedResultsControllerError.closed
        }
        fetchedResultsControllerRegistry.install(
            controller,
            ownerID: ownerID,
            lease: lease
        )
    }

    package var isPersistentModelProjectionClosed: Bool {
        preconditionOwnerIsolation()
        return projectionIsClosed
    }

    package var fetchedResultsControllerOwnerCountForTesting: Int {
        preconditionOwnerIsolation()
        return fetchedResultsControllerRegistry.countForTesting
    }

    package func markFetchedResultsControllerClosing(
        _ ownerID: WebInspectorFetchedResultsControllerOwnerID
    ) {
        preconditionOwnerIsolation()
        fetchedResultsControllerRegistry.markClosing(ownerID)
    }

    package func removeFetchedResultsController(
        _ ownerID: WebInspectorFetchedResultsControllerOwnerID
    ) {
        preconditionOwnerIsolation()
        fetchedResultsControllerRegistry.remove(ownerID)
    }

    package func scheduleFetchedResultsControllerQueryRetirement<
        Model: WebInspectorPersistentModel,
        SectionName: Hashable & Sendable
    >(
        _ token: WebInspectorFetchedResultsQueryRegistrationToken<
            Model,
            SectionName
        >,
        publication: WebInspectorFetchedResultsQueryRegistration<
            Model,
            SectionName
        >.Publication
    ) {
        preconditionOwnerIsolation()
        let queryCore = fetchedResultsQueryCore
        fetchedResultsControllerRetirementOwner.submit {
            await queryCore.closeQuery(token, publication: publication)
        }
    }

    package nonisolated(nonsending)
    func waitForFetchedResultsControllerRetirementsForTesting() async {
        preconditionOwnerIsolation()
        await fetchedResultsControllerRetirementOwner.waitForCurrentTasks()
    }

    fileprivate func applyContainerTransaction(
        _ commit: WebInspectorModelSchemaTransactionCommit
    ) -> WebInspectorModelOwnerEndpoint.Delivery {
        guard !projectionIsClosing, !projectionIsClosed else {
            return .closing
        }
        let revision = commit.canonicalRevision
        if let appliedRevision {
            precondition(
                appliedRevision < revision,
                "A model context must apply canonical revisions monotonically."
            )
        }
        precondition(
            publish(commit),
            "A container schema transaction must publish exactly once."
        )
        appliedRevision = revision
        return .applied(revision: revision)
    }

    fileprivate func beginClosingProjection() -> Bool {
        guard !projectionIsClosed else {
            return true
        }
        projectionIsClosing = true
        projectionIsClosed = true
        fetchedResultsControllerRegistry.closeAll()
        return true
    }

    fileprivate func finishClosingProjection(
        _ close: WebInspectorModelSchemaClose
    ) -> Bool {
        _ = beginClosingProjection()
        close.apply(on: modelSchemaOwnerRegistry, owner: self)
        readiness = nil
        driverTask = nil
        return true
    }
}

@available(
    *,
    unavailable,
    message: "contexts cannot be shared across concurrency contexts"
)
extension WebInspectorModelContext: @unchecked Sendable {}

private extension WebInspectorModelContext {
    nonisolated static func makeDriverTask(
        core: WebInspectorModelContainerCore,
        registrationID: WebInspectorModelContextRegistrationID,
        updates: WebInspectorCanonicalModelUpdateSequence,
        startGate: ReplyPromise<Bool>,
        readiness: ReplyPromise<Void>,
        queryCore: WebInspectorModelContextCore,
        retirementOwner: WebInspectorFetchedResultsControllerRetirementOwner,
        schemaCore: WebInspectorModelSchemaContextCore,
        endpoint: WebInspectorModelOwnerEndpoint
    ) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            await drive(
                core: core,
                registrationID: registrationID,
                updates: updates,
                startGate: startGate,
                readiness: readiness,
                queryCore: queryCore,
                retirementOwner: retirementOwner,
                schemaCore: schemaCore,
                endpoint: endpoint
            )
        }
    }

    static func drive(
        core: WebInspectorModelContainerCore,
        registrationID: WebInspectorModelContextRegistrationID,
        updates: WebInspectorCanonicalModelUpdateSequence,
        startGate: ReplyPromise<Bool>,
        readiness: ReplyPromise<Void>,
        queryCore: WebInspectorModelContextCore,
        retirementOwner: WebInspectorFetchedResultsControllerRetirementOwner,
        schemaCore: WebInspectorModelSchemaContextCore,
        endpoint: WebInspectorModelOwnerEndpoint
    ) async {
        guard (try? await startGate.valueIgnoringCancellation()) == true else {
            await closeProjection(
                queryCore: queryCore,
                retirementOwner: retirementOwner,
                schemaCore: schemaCore,
                endpoint: endpoint
            )
            readiness.fulfill(.success(()))
            return
        }

        var terminalFailure: (any Error)?
        do {
            try await core.activateContext(registrationID)
            var iterator = updates.makeAsyncIterator()
            var appliedRevision: UInt64?
            while let update = await iterator.next() {
                let transaction: WebInspectorModelSchemaTransaction
                switch update {
                case let .initial(revision, snapshot):
                    precondition(appliedRevision == nil)
                    transaction = schemaCore.initial(
                        at: revision,
                        snapshot: snapshot
                    )
                case let .changes(fromRevision, toRevision, changes):
                    precondition(
                        appliedRevision == fromRevision
                            && toRevision == fromRevision + 1
                    )
                    transaction = schemaCore.changes(
                        at: toRevision,
                        transaction: changes
                    )
                case let .resetRequired(latestRevision, token):
                    let rebase = try await core.rebaseContext(
                        token,
                        for: registrationID
                    )
                    precondition(latestRevision <= rebase.revision)
                    switch rebase.disposition {
                    case .initial:
                        precondition(appliedRevision == nil)
                        transaction = schemaCore.initial(
                            at: rebase.revision,
                            snapshot: rebase.snapshot
                        )
                    case .reset:
                        precondition(
                            appliedRevision.map { $0 < rebase.revision } == true
                        )
                        transaction = schemaCore.reset(
                            at: rebase.revision,
                            snapshot: rebase.snapshot
                        )
                    }
                }

                let commit = try await transaction.stage(on: queryCore)
                let delivery = await deliver(
                    .apply(commit),
                    endpoint: endpoint
                )
                guard case let .delivery(.applied(revision))? = delivery else {
                    _ = await commit.abort(
                        throwing: WebInspectorModelContextQueryError.closed
                    )
                    break
                }
                precondition(revision == transaction.canonicalRevision)
                appliedRevision = revision
                try await core.acknowledgeContext(
                    registrationID,
                    through: revision
                )
                readiness.fulfill(.success(()))
            }
        } catch let error {
            if let coreError = error as? WebInspectorModelContainerCoreError,
                coreError == .closed
            {
                // Container teardown owns the same terminal boundary.
            } else if error is CancellationError {
                // Context release cancels only this registration driver.
            } else {
                terminalFailure = error
            }
        }

        await closeProjection(
            queryCore: queryCore,
            retirementOwner: retirementOwner,
            schemaCore: schemaCore,
            endpoint: endpoint
        )
        _ = await core.unregisterContext(registrationID)
        if let terminalFailure {
            readiness.fulfill(.failure(terminalFailure))
            preconditionFailure(
                "A model context subscription violated its Core contract: \(terminalFailure)"
            )
        }
        readiness.fulfill(.success(()))
    }

    static func closeProjection(
        queryCore: WebInspectorModelContextCore,
        retirementOwner: WebInspectorFetchedResultsControllerRetirementOwner,
        schemaCore: WebInspectorModelSchemaContextCore,
        endpoint: WebInspectorModelOwnerEndpoint
    ) async {
        _ = await deliver(.beginClosing, endpoint: endpoint)
        await retirementOwner.close()
        await queryCore.close()
        _ = await deliver(
            .finishClosing(schemaCore.close()),
            endpoint: endpoint
        )
    }

    static func deliver(
        _ request: WebInspectorModelOwnerEndpoint.Request,
        endpoint: WebInspectorModelOwnerEndpoint
    ) async -> WebInspectorModelOwnerEndpoint.Response? {
        guard let owner = endpoint.resolveActor() else {
            return nil
        }
        return await endpoint.deliver(request, isolation: owner)
    }
}
