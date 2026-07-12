import Foundation
import Observation
import Synchronization

package final class WebInspectorFetchedResultsControllerRegistrationLease: Sendable {
    private enum State: Sendable {
        case active
        case cancelled
    }

    private let state = Mutex(State.active)

    package var isActive: Bool {
        state.withLock { $0 == .active }
    }

    package var isCancelled: Bool {
        state.withLock { $0 == .cancelled }
    }

    package func cancel() {
        state.withLock { $0 = .cancelled }
    }
}

package struct WebInspectorFetchedResultsControllerOwnerID: Hashable, Sendable {
    let contextIdentity: _WebInspectorModelContextIdentity
    let rawValue: UInt64

    package static func == (
        lhs: WebInspectorFetchedResultsControllerOwnerID,
        rhs: WebInspectorFetchedResultsControllerOwnerID
    ) -> Bool {
        lhs.contextIdentity === rhs.contextIdentity
            && lhs.rawValue == rhs.rawValue
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(contextIdentity))
        hasher.combine(rawValue)
    }
}

package struct WebInspectorFetchedResultsControllerBacking<
    Model: WebInspectorPersistentModel,
    SectionName: Hashable & Sendable
>: Sendable {
    package let fetchDescriptor: WebInspectorFetchDescriptor<Model>
    package let revision: UInt64
    package let snapshot: WebInspectorFetchedResultsSnapshot<Model.ID, SectionName>
}

public enum WebInspectorFetchedResultsControllerError: Error, Equatable, Sendable {
    /// The context's schema inventory does not include the requested model.
    case unsupportedModel
    /// The controller has begun or completed closing.
    case closed
}

package enum WebInspectorFetchedResultsControllerAdmissionResolution: Equatable, Sendable {
    case activated
    case abandoned
}

package final class WebInspectorFetchedResultsControllerAdmissionGate: Sendable {
    private typealias Waiter = CheckedContinuation<
        WebInspectorFetchedResultsControllerAdmissionResolution,
        Never
    >

    private struct State: Sendable {
        var resolution: WebInspectorFetchedResultsControllerAdmissionResolution?
        var waiters: [Waiter] = []
        var coreResolutionWasRecorded = false
        var claimantAcknowledgedCoreResolution = false
    }

    private let state = Mutex(State())
    package let ownerID: WebInspectorFetchedResultsControllerOwnerID

    package init(ownerID: WebInspectorFetchedResultsControllerOwnerID) {
        self.ownerID = ownerID
    }

    @discardableResult
    package func activate() -> Bool {
        resolve(.activated)
    }

    @discardableResult
    package func abandon() -> Bool {
        resolve(.abandoned)
    }

    package func value() async -> WebInspectorFetchedResultsControllerAdmissionResolution {
        await withCheckedContinuation { continuation in
            let resolution = state.withLock {
                state -> WebInspectorFetchedResultsControllerAdmissionResolution? in
                if let resolution = state.resolution {
                    return resolution
                }
                state.waiters.append(continuation)
                return nil
            }
            if let resolution {
                continuation.resume(returning: resolution)
            }
        }
    }

    package var waiterCountForTesting: Int {
        state.withLock { $0.waiters.count }
    }

    package func recordCoreResolution() {
        state.withLock { state in
            precondition(
                state.resolution != nil,
                "Core cannot record an unresolved fetched-results admission."
            )
            precondition(
                state.coreResolutionWasRecorded == false,
                "Core can record one fetched-results admission resolution only once."
            )
            state.coreResolutionWasRecorded = true
        }
    }

    package func acknowledgeCoreResolution() {
        state.withLock { state in
            precondition(
                state.coreResolutionWasRecorded,
                "A fetched-results admission claimant cannot acknowledge a foreign gate."
            )
            precondition(
                state.claimantAcknowledgedCoreResolution == false,
                "A fetched-results admission claimant can acknowledge Core only once."
            )
            state.claimantAcknowledgedCoreResolution = true
        }
    }

    private func resolve(
        _ resolution: WebInspectorFetchedResultsControllerAdmissionResolution
    ) -> Bool {
        let waiters = state.withLock { state -> [Waiter]? in
            guard state.resolution == nil else {
                return nil
            }
            state.resolution = resolution
            let waiters = state.waiters
            state.waiters.removeAll(keepingCapacity: false)
            return waiters
        }
        guard let waiters else {
            return false
        }
        for waiter in waiters {
            waiter.resume(returning: resolution)
        }
        return true
    }
}

package final class WebInspectorFetchedResultsControllerRegistrationClaim<
    Model: WebInspectorPersistentModel,
    SectionName: Hashable & Sendable
>: Sendable {
    private typealias Resolution = WebInspectorFetchedResultsControllerAdmissionResolution
    private typealias ResolutionWaiter = CheckedContinuation<Resolution, Never>

    private enum ResolutionState: Sendable {
        case pending
        case resolving([ResolutionWaiter])
        case resolved(Resolution)
    }

    private enum ResolutionAction {
        case resolve
        case wait
        case resolved(Resolution)
    }

    package typealias Publication = WebInspectorFetchedResultsQueryRegistration<
        Model,
        SectionName
    >.Publication

    private let contextCore: WebInspectorModelContextCore
    private let resolutionState = Mutex(ResolutionState.pending)
    package let token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>
    package let publication: Publication
    package let ownerID: WebInspectorFetchedResultsControllerOwnerID
    package let lease: WebInspectorFetchedResultsControllerRegistrationLease
    package let initialBacking: WebInspectorFetchedResultsControllerBacking<Model, SectionName>
    package let admission: WebInspectorFetchedResultsControllerAdmissionGate

    package init(
        contextCore: WebInspectorModelContextCore,
        token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>,
        publication: Publication,
        ownerID: WebInspectorFetchedResultsControllerOwnerID,
        lease: WebInspectorFetchedResultsControllerRegistrationLease,
        initialBacking: WebInspectorFetchedResultsControllerBacking<Model, SectionName>,
        admission: WebInspectorFetchedResultsControllerAdmissionGate
    ) {
        self.contextCore = contextCore
        self.token = token
        self.publication = publication
        self.ownerID = ownerID
        self.lease = lease
        self.initialBacking = initialBacking
        self.admission = admission
    }

    package func activate() async throws {
        let resolution = await resolve(requesting: .activated)
        guard resolution == .activated else {
            throw CancellationError()
        }
    }

    package func abandon() async {
        _ = await resolve(requesting: .abandoned)
    }

    private func resolve(requesting requestedResolution: Resolution) async -> Resolution {
        let action = resolutionState.withLock { state -> ResolutionAction in
            switch state {
            case .pending:
                state = .resolving([])
                return .resolve
            case .resolving:
                return .wait
            case let .resolved(resolution):
                return .resolved(resolution)
            }
        }
        switch action {
        case .resolve:
            switch requestedResolution {
            case .activated:
                _ = admission.activate()
            case .abandoned:
                _ = admission.abandon()
            }
            let resolution = await contextCore.resolveControllerAdmission(
                ownerID,
                admission: admission
            )
            finishResolution(resolution)
            return resolution
        case .wait:
            return await waitForResolution()
        case let .resolved(resolution):
            return resolution
        }
    }

    private func waitForResolution() async -> Resolution {
        await withCheckedContinuation { continuation in
            let resolution = resolutionState.withLock { state -> Resolution? in
                switch state {
                case .pending:
                    preconditionFailure(
                        "A fetched-results admission cannot wait before resolution begins."
                    )
                case let .resolving(waiters):
                    state = .resolving(waiters + [continuation])
                    return nil
                case let .resolved(resolution):
                    return resolution
                }
            }
            if let resolution {
                continuation.resume(returning: resolution)
            }
        }
    }

    private func finishResolution(_ resolution: Resolution) {
        let waiters = resolutionState.withLock { state -> [ResolutionWaiter] in
            guard case let .resolving(waiters) = state else {
                preconditionFailure(
                    "A fetched-results admission claim can resolve only once."
                )
            }
            state = .resolved(resolution)
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: resolution)
        }
    }

    deinit {
        _ = admission.abandon()
    }
}

package final class WebInspectorFetchedResultsControllerReplacementCommit: Sendable {
    private typealias Waiter = CheckedContinuation<Void, Never>

    private enum State: Sendable {
        case pending([Waiter])
        case publishing([Waiter])
        case published
    }

    private let ownerBatch: WebInspectorFetchedResultsControllerOwnerMutationBatch
    private let publication: _WebInspectorModelContextPendingQueryPublication?
    private let state = Mutex(State.pending([]))

    init(
        ownerBatch: WebInspectorFetchedResultsControllerOwnerMutationBatch,
        publication: _WebInspectorModelContextPendingQueryPublication?
    ) {
        self.ownerBatch = ownerBatch
        self.publication = publication
    }

    package func publish(
        applyingOwnerMutation body:
            ([WebInspectorFetchedResultsControllerOwnerMutationBatch]) -> Void
    ) {
        state.withLock { state in
            guard case let .pending(waiters) = state else {
                preconditionFailure(
                    "A fetched-results controller replacement can be published only once."
                )
            }
            state = .publishing(waiters)
        }
        body([ownerBatch])
        precondition(
            ownerBatch.isConsumed,
            "A fetched-results controller replacement owner batch must be consumed before publication."
        )
        publication?.publish()
        let waiters = state.withLock { state -> [Waiter] in
            guard case let .publishing(waiters) = state else {
                preconditionFailure(
                    "A fetched-results controller replacement lost its publication phase."
                )
            }
            state = .published
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    package func waitUntilResolved() async {
        await withCheckedContinuation { continuation in
            let isResolved = state.withLock { state -> Bool in
                switch state {
                case let .pending(waiters):
                    state = .pending(waiters + [continuation])
                    return false
                case let .publishing(waiters):
                    state = .publishing(waiters + [continuation])
                    return false
                case .published:
                    return true
                }
            }
            if isResolved {
                continuation.resume()
            }
        }
    }
}

package struct WebInspectorFetchedResultsControllerOwnerMutationBatch: Sendable {
    package let ownerID: WebInspectorFetchedResultsControllerOwnerID
    package let lease: WebInspectorFetchedResultsControllerRegistrationLease

    private let modelTypeID: ObjectIdentifier
    private let sectionNameTypeID: ObjectIdentifier
    private let payload: any Sendable
    private let consumption = _WebInspectorFetchedResultsControllerOwnerMutationConsumption()

    package init<
        Model: WebInspectorPersistentModel,
        SectionName: Hashable & Sendable
    >(
        ownerID: WebInspectorFetchedResultsControllerOwnerID,
        lease: WebInspectorFetchedResultsControllerRegistrationLease,
        backing: WebInspectorFetchedResultsControllerBacking<Model, SectionName>
    ) {
        self.ownerID = ownerID
        self.lease = lease
        modelTypeID = ObjectIdentifier(Model.self)
        sectionNameTypeID = ObjectIdentifier(SectionName.self)
        payload = backing
    }

    package var isConsumed: Bool {
        consumption.isConsumed
    }

    package func consume<
        Model: WebInspectorPersistentModel,
        SectionName: Hashable & Sendable,
        Output
    >(
        as model: Model.Type,
        sectionName: SectionName.Type,
        _ body: (WebInspectorFetchedResultsControllerBacking<Model, SectionName>) -> Output
    ) -> Output {
        precondition(
            modelTypeID == ObjectIdentifier(model)
                && sectionNameTypeID == ObjectIdentifier(sectionName),
            "A fetched-results controller owner batch was opened with the wrong types."
        )
        guard
            let backing = payload
                as? WebInspectorFetchedResultsControllerBacking<Model, SectionName>
        else {
            preconditionFailure(
                "A fetched-results controller owner batch lost its concrete backing type."
            )
        }
        return consumption.consume {
            body(backing)
        }
    }

    package func discard() {
        consumption.consume {}
    }
}

private final class _WebInspectorFetchedResultsControllerOwnerMutationConsumption: Sendable {
    private enum State: Sendable {
        case available
        case consuming
        case consumed
    }

    private let state = Mutex(State.available)

    var isConsumed: Bool {
        state.withLock { $0 == .consumed }
    }

    func consume<Output>(_ body: () -> Output) -> Output {
        state.withLock { state in
            guard state == .available else {
                preconditionFailure(
                    "A fetched-results controller owner batch can be consumed only once."
                )
            }
            state = .consuming
        }
        let output = body()
        state.withLock { state in
            precondition(
                state == .consuming,
                "A fetched-results controller owner batch lost its consumption phase."
            )
            state = .consumed
        }
        return output
    }
}

private final class _WeakWebInspectorFetchedResultsController<
    Model: WebInspectorPersistentModel,
    SectionName: Hashable & Sendable
> {
    weak var value: WebInspectorFetchedResultsController<Model, SectionName>?

    init(_ value: WebInspectorFetchedResultsController<Model, SectionName>) {
        self.value = value
    }
}

private struct _WebInspectorFetchedResultsControllerOwnerEntry {
    enum State {
        case active
        case closing
    }

    let lease: WebInspectorFetchedResultsControllerRegistrationLease
    let apply: (WebInspectorFetchedResultsControllerOwnerMutationBatch) -> Bool
    var state: State
}

/// Caller-confined weak routing for fetched-results controller owner batches.
package final class WebInspectorFetchedResultsControllerOwnerRegistry {
    private let contextIdentity: _WebInspectorModelContextIdentity
    private var entries:
        [WebInspectorFetchedResultsControllerOwnerID:
            _WebInspectorFetchedResultsControllerOwnerEntry] = [:]

    package init(contextIdentity: _WebInspectorModelContextIdentity) {
        self.contextIdentity = contextIdentity
    }

    package var countForTesting: Int {
        entries.count
    }

    package func install<
        Model: WebInspectorPersistentModel,
        SectionName: Hashable & Sendable
    >(
        _ controller: WebInspectorFetchedResultsController<Model, SectionName>,
        ownerID: WebInspectorFetchedResultsControllerOwnerID,
        lease: WebInspectorFetchedResultsControllerRegistrationLease
    ) {
        preconditionOwnerID(ownerID)
        precondition(
            entries[ownerID] == nil,
            "A fetched-results controller owner can be installed only once."
        )
        let weakController = _WeakWebInspectorFetchedResultsController(controller)
        entries[ownerID] = _WebInspectorFetchedResultsControllerOwnerEntry(
            lease: lease,
            apply: { batch in
                guard let controller = weakController.value else {
                    return false
                }
                batch.consume(
                    as: Model.self,
                    sectionName: SectionName.self
                ) { backing in
                    controller.apply(backing)
                }
                return true
            },
            state: .active
        )
    }

    package func markClosing(
        _ ownerID: WebInspectorFetchedResultsControllerOwnerID
    ) {
        preconditionOwnerID(ownerID)
        guard var entry = entries[ownerID] else {
            preconditionFailure(
                "A fetched-results controller cannot close without an installed owner entry."
            )
        }
        if case .active = entry.state {
            entry.state = .closing
            entries[ownerID] = entry
        }
    }

    package func remove(
        _ ownerID: WebInspectorFetchedResultsControllerOwnerID
    ) {
        preconditionOwnerID(ownerID)
        guard let entry = entries.removeValue(forKey: ownerID) else {
            preconditionFailure(
                "A fetched-results controller owner entry can be removed only once."
            )
        }
        precondition(
            entry.lease.isCancelled,
            "A fetched-results controller owner entry must be cancelled before removal."
        )
    }

    package func apply(
        _ batches: [WebInspectorFetchedResultsControllerOwnerMutationBatch]
    ) {
        for batch in batches {
            preconditionOwnerID(batch.ownerID)
            guard let entry = entries[batch.ownerID] else {
                if batch.lease.isCancelled {
                    batch.discard()
                    continue
                }
                preconditionFailure(
                    "An active fetched-results controller owner batch lost its routing entry."
                )
            }
            precondition(
                entry.lease === batch.lease,
                "A fetched-results controller owner batch carried a foreign lease."
            )
            switch entry.state {
            case .closing:
                precondition(
                    batch.lease.isCancelled,
                    "A closing fetched-results controller must cancel its registration lease."
                )
                batch.discard()
            case .active:
                if batch.lease.isCancelled {
                    batch.discard()
                } else if entry.apply(batch) == false {
                    preconditionFailure(
                        "An active fetched-results controller disappeared without cancelling its lease."
                    )
                }
            }
        }
    }

    package func closeAll() {
        for ownerID in Array(entries.keys) {
            guard var entry = entries[ownerID] else {
                preconditionFailure(
                    "A fetched-results controller owner registry lost an enumerated entry."
                )
            }
            entry.lease.cancel()
            entry.state = .closing
            entries[ownerID] = entry
        }
    }

    private func preconditionOwnerID(
        _ ownerID: WebInspectorFetchedResultsControllerOwnerID
    ) {
        precondition(
            ownerID.contextIdentity === contextIdentity,
            "A fetched-results controller owner cannot move between model contexts."
        )
    }
}

@available(
    *,
    unavailable,
    message: "fetched-results controller owner registries are caller-confined"
)
extension WebInspectorFetchedResultsControllerOwnerRegistry: Sendable {}

/// An actor-confined observable owner for one persistent-model query.
@Observable
public final class WebInspectorFetchedResultsController<
    Model: WebInspectorPersistentModel,
    SectionName: Hashable & Sendable
> {
    private typealias Publication = WebInspectorFetchedResultsQueryRegistration<
        Model,
        SectionName
    >.Publication

    private typealias Token = WebInspectorFetchedResultsQueryRegistrationToken<
        Model,
        SectionName
    >

    private typealias CloseWaiter = CheckedContinuation<Void, Never>

    private enum CloseState {
        case open
        case closing([CloseWaiter])
        case closed
    }

    /// The identity graph used to resolve the controller's item IDs.
    public let modelContext: WebInspectorModelContext

    private var backing:
        WebInspectorFetchedResultsControllerBacking<
            Model,
            SectionName
        >

    @ObservationIgnored private let contextCore: WebInspectorModelContextCore
    @ObservationIgnored private let token: Token
    @ObservationIgnored private let publication: Publication
    @ObservationIgnored private let ownerID: WebInspectorFetchedResultsControllerOwnerID
    @ObservationIgnored private let lease: WebInspectorFetchedResultsControllerRegistrationLease
    @ObservationIgnored private var closeState = CloseState.open

    /// The descriptor currently committed by the query owner.
    public var fetchDescriptor: WebInspectorFetchDescriptor<Model> {
        backing.fetchDescriptor
    }

    /// The current fetched-results revision.
    public var revision: UInt64 {
        backing.revision
    }

    /// The current section and item identity snapshot.
    public var snapshot: WebInspectorFetchedResultsSnapshot<Model.ID, SectionName> {
        backing.snapshot
    }

    package var usesOneSharedPublicationForTesting: Bool {
        token.publicationIdentity == ObjectIdentifier(publication)
    }

    package var publicationRevisionForTesting: UInt64 {
        publication.currentRevisionForTesting
    }

    package var isClosingForTesting: Bool {
        if case .closing = closeState {
            return true
        }
        return false
    }

    public convenience init(
        fetchDescriptor: WebInspectorFetchDescriptor<Model> = .init(),
        modelContext: WebInspectorModelContext,
        isolation: isolated (any Actor) = #isolation
    ) async throws where SectionName == Never {
        modelContext.preconditionOwnerIsolation()
        try await modelContext.waitUntilContainerReady()
        let claim = try await modelContext.fetchedResultsQueryCore
            .prepareControllerRegistration(
                Model.self,
                fetchDescriptor: fetchDescriptor
            )
        do {
            try Task.checkCancellation()
        } catch {
            await claim.abandon()
            throw error
        }
        try await self.init(
            modelContext: modelContext,
            claim: claim,
            isolation: isolation
        )
    }

    public convenience init(
        fetchDescriptor: WebInspectorFetchDescriptor<Model> = .init(),
        sectionBy: Expression<Model.QueryValue, SectionName>,
        modelContext: WebInspectorModelContext,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        modelContext.preconditionOwnerIsolation()
        try await modelContext.waitUntilContainerReady()
        let claim = try await modelContext.fetchedResultsQueryCore
            .prepareControllerRegistration(
                Model.self,
                fetchDescriptor: fetchDescriptor,
                sectionBy: sectionBy
            )
        do {
            try Task.checkCancellation()
        } catch {
            await claim.abandon()
            throw error
        }
        try await self.init(
            modelContext: modelContext,
            claim: claim,
            isolation: isolation
        )
    }

    package init(
        modelContext: WebInspectorModelContext,
        claim: WebInspectorFetchedResultsControllerRegistrationClaim<
            Model,
            SectionName
        >,
        isolation: isolated (any Actor)
    ) async throws {
        self.modelContext = modelContext
        backing = claim.initialBacking
        contextCore = modelContext.fetchedResultsQueryCore
        token = claim.token
        publication = claim.publication
        ownerID = claim.ownerID
        lease = claim.lease

        var didInstallOwner = false
        do {
            try modelContext.installFetchedResultsController(
                self,
                ownerID: ownerID,
                lease: lease
            )
            didInstallOwner = true
            try await claim.activate()
            guard modelContext.isFetchedResultsProjectionClosed == false else {
                throw WebInspectorFetchedResultsControllerError.closed
            }
        } catch {
            lease.cancel()
            publication.finish()
            await claim.abandon()
            if didInstallOwner {
                if modelContext.isFetchedResultsProjectionClosed == false {
                    modelContext.markFetchedResultsControllerClosing(ownerID)
                }
                modelContext.removeFetchedResultsController(ownerID)
            }
            throw error
        }
    }

    package func apply(
        _ backing: WebInspectorFetchedResultsControllerBacking<Model, SectionName>
    ) {
        modelContext.preconditionOwnerIsolation()
        self.backing = backing
    }

    public nonisolated(nonsending) func update(
        _ descriptor: WebInspectorFetchDescriptor<Model>
    ) async throws {
        modelContext.preconditionOwnerIsolation()
        guard case .open = closeState else {
            throw WebInspectorFetchedResultsControllerError.closed
        }
        let candidate = try await contextCore.prepareReplacement(
            descriptor,
            for: token,
            publication: publication
        )
        do {
            try Task.checkCancellation()
            let commit = try await contextCore.commitControllerReplacement(
                candidate,
                for: token,
                publication: publication
            )
            commit.publish { [modelContext] mutations in
                modelContext.applyFetchedResultsControllerOwnerMutations(
                    mutations
                )
            }
        } catch {
            await contextCore.discardReplacement(
                candidate,
                for: token,
                publication: publication
            )
            throw error
        }
    }

    public func updates() -> WebInspectorFetchedResultsUpdateSequence<
        Model.ID,
        SectionName
    > {
        modelContext.preconditionOwnerIsolation()
        let current = backing
        let base = publication.subscribe(
            revision: current.revision,
            snapshot: current.snapshot
        )
        return WebInspectorFetchedResultsUpdateSequence(
            base: base,
            rebase: { [contextCore, token, publication] rebaseToken in
                try await contextCore.rebase(
                    rebaseToken,
                    for: token,
                    publication: publication
                )
            }
        )
    }

    public nonisolated(nonsending) func close() async {
        modelContext.preconditionOwnerIsolation()
        switch closeState {
        case .open:
            closeState = .closing([])
        case .closing:
            await waitForClose()
            return
        case .closed:
            return
        }

        lease.cancel()
        modelContext.markFetchedResultsControllerClosing(ownerID)
        publication.finish()
        await contextCore.closeQuery(
            token,
            publication: publication
        )
        modelContext.removeFetchedResultsController(ownerID)
        finishClose()
    }

    private nonisolated(nonsending) func waitForClose() async {
        await withCheckedContinuation { continuation in
            switch closeState {
            case .open:
                preconditionFailure(
                    "A fetched-results controller close waiter requires an active close."
                )
            case let .closing(waiters):
                closeState = .closing(waiters + [continuation])
            case .closed:
                continuation.resume()
            }
        }
    }

    private func finishClose() {
        guard case let .closing(waiters) = closeState else {
            preconditionFailure(
                "A fetched-results controller can finish only one active close."
            )
        }
        closeState = .closed
        for waiter in waiters {
            waiter.resume()
        }
    }

    deinit {
        lease.cancel()
        publication.finish()
    }
}

@available(
    *,
    unavailable,
    message: "fetched-results controllers are confined to their model-context actor"
)
extension WebInspectorFetchedResultsController: Sendable {}
