import Foundation
import Synchronization

/// Type-erased source work for one model in a canonical context revision.
///
/// Source values are Sendable. The model-specific query engine selected by
/// this batch remains synchronous and isolated to `WebInspectorModelContextCore`.
package struct WebInspectorModelContextQueryBatch: Sendable {
    fileprivate let canonicalRevision: UInt64
    fileprivate let modelTypeID: ObjectIdentifier
    private let stageBody:
        @Sendable (
            isolated WebInspectorModelContextCore,
            inout _WebInspectorModelContextStagedQueryWork
        ) -> Void

    package init<Model: WebInspectorPersistentModel>(
        _ batch: WebInspectorFetchedResultsSourceBatch<Model>
    ) {
        canonicalRevision = batch.canonicalRevision
        modelTypeID = ObjectIdentifier(Model.self)
        stageBody = { core, work in
            work.append(contentsOf: core.stage(batch))
        }
    }

    fileprivate func stage(
        on core: isolated WebInspectorModelContextCore,
        into work: inout _WebInspectorModelContextStagedQueryWork
    ) {
        stageBody(core, &work)
    }
}

package enum WebInspectorModelContextQueryCommitResolution: Equatable, Sendable {
    case published
    case aborted
}

/// The terminal publication phase of one canonical model-context transaction.
///
/// The model owner receives this Sendable commit after query state has been
/// staged. It either patches every materialized model and calls `publish()` in
/// the same owner turn, or calls `abort(throwing:)` when that owner turn cannot
/// complete. The first terminal operation wins. Abort never exposes staged
/// source state and closes every registration owned by the context core.
package final class WebInspectorModelContextQueryCommit: Sendable {
    fileprivate typealias AbortOperation = @Sendable (any Error) async -> Void
    private typealias Waiter = CheckedContinuation<
        WebInspectorModelContextQueryCommitResolution,
        Never
    >

    private enum State: Sendable {
        case pending(
            work: _WebInspectorModelContextStagedQueryWork,
            abort: AbortOperation,
            waiters: [Waiter]
        )
        case resolving(
            WebInspectorModelContextQueryCommitResolution,
            waiters: [Waiter]
        )
        case resolved(WebInspectorModelContextQueryCommitResolution)
    }

    private enum PublishAction {
        case publish(_WebInspectorModelContextStagedQueryWork)
        case lostToAbort
        case repeatedPublish
    }

    private enum AbortAction {
        case abort(
            _WebInspectorModelContextStagedQueryWork,
            AbortOperation
        )
        case awaitResolution
        case resolved(WebInspectorModelContextQueryCommitResolution)
    }

    package let canonicalRevision: UInt64
    fileprivate let token: UInt64
    private let state: Mutex<State>

    fileprivate init(
        canonicalRevision: UInt64,
        token: UInt64,
        work: _WebInspectorModelContextStagedQueryWork,
        abort: @escaping AbortOperation
    ) {
        self.canonicalRevision = canonicalRevision
        self.token = token
        state = Mutex(
            .pending(
                work: work,
                abort: abort,
                waiters: []
            )
        )
    }

    /// Makes every registration mailbox observe this canonical transaction.
    ///
    /// Call only after the same owner has patched all materialized models for
    /// `canonicalRevision`. Returns `false` when an abort already won the
    /// transaction's terminal race.
    @discardableResult
    package func publish(
        applyingControllerOwnerMutations body:
            ([WebInspectorFetchedResultsControllerOwnerMutationBatch]) -> Void
    ) -> Bool {
        let action = state.withLock { state -> PublishAction in
            switch state {
            case let .pending(work, _, waiters):
                state = .resolving(.published, waiters: waiters)
                return .publish(work)
            case .resolving(.aborted, _), .resolved(.aborted):
                return .lostToAbort
            case .resolving(.published, _), .resolved(.published):
                return .repeatedPublish
            }
        }

        switch action {
        case let .publish(work):
            body(work.controllerOwnerBatches)
            precondition(
                work.controllerOwnerBatches.allSatisfy(\.isConsumed),
                "Every fetched-results controller owner batch must be consumed before publication."
            )
            for publication in work.controllerPublications {
                publication.publish()
            }
            for publication in work.rawPublications {
                publication.publish()
            }
            finish(.published)
            return true
        case .lostToAbort:
            return false
        case .repeatedPublish:
            preconditionFailure(
                "A model-context query commit can be published only once."
            )
        }
    }

    /// Publishes a raw-query-only transaction.
    @discardableResult
    package func publish() -> Bool {
        publish { batches in
            precondition(
                batches.isEmpty,
                "A controller-mode query transaction requires owner delivery."
            )
        }
    }

    /// Terminates every affected registration without exposing staged source.
    ///
    /// The context driver calls this when the materialization owner disappears
    /// or otherwise cannot complete its owner turn.
    package func abort(
        throwing error: any Error
    ) async -> WebInspectorModelContextQueryCommitResolution {
        let action = state.withLock { state -> AbortAction in
            switch state {
            case let .pending(work, abort, waiters):
                state = .resolving(.aborted, waiters: waiters)
                return .abort(work, abort)
            case .resolving:
                return .awaitResolution
            case let .resolved(resolution):
                return .resolved(resolution)
            }
        }

        switch action {
        case let .abort(work, abort):
            for batch in work.controllerOwnerBatches {
                batch.discard()
            }
            for publication in work.controllerPublications {
                publication.abort(throwing: error)
            }
            for publication in work.rawPublications {
                publication.abort(throwing: error)
            }
            await abort(error)
            finish(.aborted)
            return .aborted
        case .awaitResolution:
            return await waitUntilResolved()
        case let .resolved(resolution):
            return resolution
        }
    }

    package var isPublishedForTesting: Bool {
        state.withLock { state in
            if case .resolved(.published) = state {
                return true
            }
            return false
        }
    }

    package var isAbortedForTesting: Bool {
        state.withLock { state in
            if case .resolved(.aborted) = state {
                return true
            }
            return false
        }
    }

    fileprivate func waitUntilResolved()
        async -> WebInspectorModelContextQueryCommitResolution
    {
        await withCheckedContinuation { continuation in
            let resolution = state.withLock {
                state -> WebInspectorModelContextQueryCommitResolution? in
                switch state {
                case let .pending(work, abort, waiters):
                    state = .pending(
                        work: work,
                        abort: abort,
                        waiters: waiters + [continuation]
                    )
                    return nil
                case let .resolving(resolution, waiters):
                    state = .resolving(
                        resolution,
                        waiters: waiters + [continuation]
                    )
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

    private func finish(
        _ resolution: WebInspectorModelContextQueryCommitResolution
    ) {
        let waiters = state.withLock { state in
            guard case let .resolving(expectedResolution, waiters) = state,
                expectedResolution == resolution
            else {
                preconditionFailure(
                    "A model-context query commit lost its terminal phase."
                )
            }
            state = .resolved(resolution)
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: resolution)
        }
    }
}

/// Owns one model context's query sources, registrations, and publications.
///
/// The actor is the only isolation boundary. Each model-specific query engine
/// is synchronous and non-Sendable, and remains stored inside this actor.
package actor WebInspectorModelContextCore {
    private enum Lifecycle: Equatable {
        case open
        case closing
        case closed
    }

    private struct ConfiguredModelSource: Equatable {
        let modelTypeID: ObjectIdentifier
        let sourceIdentity: AnyWebInspectorModelSourceBatch.SourceIdentity
    }

    private enum SourceMode {
        case undecided
        case queryOnly
        case modelSources([ConfiguredModelSource])
    }

    private struct OutstandingControllerAdmission {
        let ownerID: WebInspectorFetchedResultsControllerOwnerID
        let gate: WebInspectorFetchedResultsControllerAdmissionGate
        let abandon:
            @Sendable (
                isolated WebInspectorModelContextCore
            ) -> _WebInspectorModelContextStagedQueryDelivery?
    }

    private enum OutstandingOwnerDelivery {
        case query(WebInspectorModelContextQueryCommit)
        case replacement(WebInspectorFetchedResultsControllerReplacementCommit)
    }

    package let identity = _WebInspectorModelContextIdentity()
    private let configuredModelTypeIDs: Set<ObjectIdentifier>?
    private var queryEngines: [ObjectIdentifier: any _WebInspectorAnyQueryEngine] = [:]
    private var lastCanonicalRevision: UInt64?
    private var outstandingOwnerDelivery: OutstandingOwnerDelivery?
    private var nextQueryCommitToken: UInt64 = 0
    private var nextControllerOwnerID: UInt64 = 0
    private var outstandingControllerAdmission: OutstandingControllerAdmission?
    private var sourceMode = SourceMode.undecided
    private var lifecycle = Lifecycle.open

    package init(configuredModelTypeIDs: Set<ObjectIdentifier>? = nil) {
        self.configuredModelTypeIDs = configuredModelTypeIDs
    }

    package func register<Model: WebInspectorPersistentModel>(
        _ model: Model.Type,
        fetchDescriptor: WebInspectorFetchDescriptor<Model> = .init()
    ) async throws -> WebInspectorFetchedResultsQueryRegistration<Model, Never> {
        try ensureOpen()
        await waitForOutstandingControllerAdmission()
        await waitForOutstandingOwnerDelivery()
        try ensureOpen()
        let publication = WebInspectorFetchedResultsQueryRegistration<
            Model,
            Never
        >.Publication()
        let token = try engine(for: model).register(
            fetchDescriptor: fetchDescriptor,
            publication: publication
        )
        return WebInspectorFetchedResultsQueryRegistration(
            contextCore: self,
            token: token,
            publication: publication
        )
    }

    package func register<
        Model: WebInspectorPersistentModel,
        SectionName: Hashable & Sendable
    >(
        _ model: Model.Type,
        fetchDescriptor: WebInspectorFetchDescriptor<Model> = .init(),
        sectionBy: Expression<Model.QueryValue, SectionName>
    ) async throws -> WebInspectorFetchedResultsQueryRegistration<Model, SectionName> {
        try ensureOpen()
        await waitForOutstandingControllerAdmission()
        await waitForOutstandingOwnerDelivery()
        try ensureOpen()
        let publication = WebInspectorFetchedResultsQueryRegistration<
            Model,
            SectionName
        >.Publication()
        let token = try engine(for: model).register(
            fetchDescriptor: fetchDescriptor,
            sectionBy: sectionBy,
            publication: publication
        )
        return WebInspectorFetchedResultsQueryRegistration(
            contextCore: self,
            token: token,
            publication: publication
        )
    }

    package func prepareControllerRegistration<
        Model: WebInspectorPersistentModel
    >(
        _ model: Model.Type,
        fetchDescriptor: WebInspectorFetchDescriptor<Model> = .init()
    ) async throws -> WebInspectorFetchedResultsControllerRegistrationClaim<
        Model,
        Never
    > {
        let publication = WebInspectorFetchedResultsQueryRegistration<
            Model,
            Never
        >.Publication()
        return try await prepareControllerRegistration(
            model,
            fetchDescriptor: fetchDescriptor,
            publication: publication
        ) { engine, ownerID, lease in
            try engine.registerController(
                fetchDescriptor: fetchDescriptor,
                publication: publication,
                ownerID: ownerID,
                lease: lease
            )
        }
    }

    package func prepareControllerRegistration<
        Model: WebInspectorPersistentModel,
        SectionName: Hashable & Sendable
    >(
        _ model: Model.Type,
        fetchDescriptor: WebInspectorFetchDescriptor<Model> = .init(),
        sectionBy: Expression<Model.QueryValue, SectionName>
    ) async throws -> WebInspectorFetchedResultsControllerRegistrationClaim<
        Model,
        SectionName
    > {
        let publication = WebInspectorFetchedResultsQueryRegistration<
            Model,
            SectionName
        >.Publication()
        return try await prepareControllerRegistration(
            model,
            fetchDescriptor: fetchDescriptor,
            publication: publication
        ) { engine, ownerID, lease in
            try engine.registerController(
                fetchDescriptor: fetchDescriptor,
                sectionBy: sectionBy,
                publication: publication,
                ownerID: ownerID,
                lease: lease
            )
        }
    }

    private func prepareControllerRegistration<
        Model: WebInspectorPersistentModel,
        SectionName: Hashable & Sendable
    >(
        _ model: Model.Type,
        fetchDescriptor: WebInspectorFetchDescriptor<Model>,
        publication: WebInspectorFetchedResultsQueryRegistration<
            Model,
            SectionName
        >.Publication,
        install:
            (
                _WebInspectorFetchedResultsQueryEngine<Model>,
                WebInspectorFetchedResultsControllerOwnerID,
                WebInspectorFetchedResultsControllerRegistrationLease
            ) throws -> WebInspectorFetchedResultsQueryRegistrationToken<
                Model,
                SectionName
            >
    ) async throws -> WebInspectorFetchedResultsControllerRegistrationClaim<
        Model,
        SectionName
    > {
        try ensureOpen()
        await waitForOutstandingControllerAdmission()
        await waitForOutstandingOwnerDelivery()
        try ensureOpen()
        try ensureControllerModelConfigured(model)
        precondition(
            nextControllerOwnerID < UInt64.max,
            "A model context exhausted its fetched-results controller owner identity space."
        )
        nextControllerOwnerID += 1
        let ownerID = WebInspectorFetchedResultsControllerOwnerID(
            contextIdentity: identity,
            rawValue: nextControllerOwnerID
        )
        let lease = WebInspectorFetchedResultsControllerRegistrationLease()
        let engine = engine(for: model)
        let token = try install(engine, ownerID, lease)
        let state = try engine.state(
            for: token,
            publication: publication
        )
        let admission = WebInspectorFetchedResultsControllerAdmissionGate(
            ownerID: ownerID
        )
        outstandingControllerAdmission = OutstandingControllerAdmission(
            ownerID: ownerID,
            gate: admission,
            abandon: { core in
                core.typedEngine(for: Model.self)?
                    .close(token, publication: publication)
            }
        )
        return WebInspectorFetchedResultsControllerRegistrationClaim(
            contextCore: self,
            token: token,
            publication: publication,
            ownerID: ownerID,
            lease: lease,
            initialBacking: WebInspectorFetchedResultsControllerBacking(
                fetchDescriptor: fetchDescriptor,
                revision: state.revision,
                snapshot: state.snapshot
            ),
            admission: admission
        )
    }

    package func applyBatch<Model: WebInspectorPersistentModel>(
        _ batch: WebInspectorFetchedResultsSourceBatch<Model>
    ) async throws -> WebInspectorModelContextQueryCommit {
        try await applyBatches([WebInspectorModelContextQueryBatch(batch)])
    }

    package func applyBatches(
        _ batches: [WebInspectorModelContextQueryBatch]
    ) async throws -> WebInspectorModelContextQueryCommit {
        try ensureOpen()
        await waitForOutstandingControllerAdmission()
        await waitForOutstandingOwnerDelivery()
        try ensureOpen()
        switch sourceMode {
        case .undecided:
            sourceMode = .queryOnly
        case .queryOnly:
            break
        case .modelSources:
            preconditionFailure(
                "A model-source context cannot apply query-only source work."
            )
        }
        return stageQueryBatches(batches)
    }

    package func applySourceBatch<
        Model: WebInspectorPersistentModel,
        Record: WebInspectorModelRecord
    >(
        _ batch: WebInspectorModelSourceBatch<Model, Record>
    ) async throws -> WebInspectorModelContextTransactionCommit {
        try await applySourceBatches(
            at: batch.canonicalRevision,
            [AnyWebInspectorModelSourceBatch(batch)]
        )
    }

    /// Stages one complete canonical revision across every configured model
    /// source owned by this context. An empty configured source set still
    /// stages and resolves the explicit revision through the same commit path.
    package func applySourceBatches(
        at canonicalRevision: UInt64,
        _ batches: [AnyWebInspectorModelSourceBatch]
    ) async throws -> WebInspectorModelContextTransactionCommit {
        try ensureOpen()
        await waitForOutstandingControllerAdmission()
        await waitForOutstandingOwnerDelivery()
        try ensureOpen()

        let proposedSources = validatedModelSources(
            in: batches,
            at: canonicalRevision
        )
        switch sourceMode {
        case .undecided:
            break
        case .queryOnly:
            preconditionFailure(
                "A query-only context cannot adopt model-source transactions."
            )
        case let .modelSources(configuredSources):
            precondition(
                configuredSources == proposedSources,
                "Every canonical context transaction must preserve its configured model-source order and identity."
            )
        }

        var recordCommits: [_WebInspectorAnyPreparedModelRecordCommit] = []
        recordCommits.reserveCapacity(batches.count)
        do {
            for batch in batches {
                recordCommits.append(try batch.prepare())
            }
        } catch {
            discardPreparedRecordCommits(recordCommits)
            throw error
        }

        let queryCommit = stageQueryBatches(
            batches.map(\.queryBatch),
            at: canonicalRevision
        )
        if case .undecided = sourceMode {
            sourceMode = .modelSources(proposedSources)
        }
        return WebInspectorModelContextTransactionCommit(
            canonicalRevision: queryCommit.canonicalRevision,
            recordCommits: recordCommits,
            queryCommit: queryCommit
        )
    }

    private func stageQueryBatches(
        _ batches: [WebInspectorModelContextQueryBatch]
    ) -> WebInspectorModelContextQueryCommit {
        precondition(
            batches.isEmpty == false,
            "A model-context query transaction must contain source work."
        )
        return stageQueryBatches(
            batches,
            at: batches[0].canonicalRevision
        )
    }

    private func stageQueryBatches(
        _ batches: [WebInspectorModelContextQueryBatch],
        at canonicalRevision: UInt64
    ) -> WebInspectorModelContextQueryCommit {
        if let lastCanonicalRevision {
            precondition(
                lastCanonicalRevision < canonicalRevision,
                "A model context can apply a canonical revision only once."
            )
        }
        precondition(
            batches.allSatisfy { $0.canonicalRevision == canonicalRevision },
            "One context query transaction must carry one canonical revision."
        )
        precondition(
            Set(batches.map(\.modelTypeID)).count == batches.count,
            "One context query transaction can stage each model type only once."
        )

        var work = _WebInspectorModelContextStagedQueryWork()
        for batch in batches {
            batch.stage(on: self, into: &work)
        }
        lastCanonicalRevision = canonicalRevision

        precondition(
            nextQueryCommitToken < UInt64.max,
            "A model context exhausted its query-commit identity space."
        )
        nextQueryCommitToken += 1
        let token = nextQueryCommitToken

        let commit = WebInspectorModelContextQueryCommit(
            canonicalRevision: canonicalRevision,
            token: token,
            work: work,
            abort: { [weak self] error in
                await self?.abortQueryCommit(
                    token: token,
                    throwing: error
                )
            }
        )
        outstandingOwnerDelivery = .query(commit)
        return commit
    }

    package func close() async {
        switch lifecycle {
        case .open:
            lifecycle = .closing
        case .closing:
            break
        case .closed:
            return
        }

        outstandingControllerAdmission?.gate.abandon()
        await waitForOutstandingControllerAdmission()
        await waitForOutstandingOwnerDelivery()
        guard lifecycle == .closing else {
            return
        }
        finishClose(throwing: nil)
    }

    package func isClosingForTesting() -> Bool {
        lifecycle == .closing
    }

    package func outstandingControllerAdmissionWaiterCountForTesting() -> Int {
        outstandingControllerAdmission?.gate.waiterCountForTesting ?? 0
    }

    package func hasOutstandingControllerAdmissionForTesting() -> Bool {
        outstandingControllerAdmission != nil
    }

    package func registrationCountForTesting<Model: WebInspectorPersistentModel>(
        _ model: Model.Type
    ) -> Int {
        typedEngine(for: model)?.registrationCount ?? 0
    }

    package func queryEngineCountForTesting() -> Int {
        queryEngines.count
    }

    package func sourcePerformanceCountersForTesting<
        Model: WebInspectorPersistentModel
    >(
        _ model: Model.Type
    ) -> WebInspectorFetchedResultsSourcePerformanceCounters {
        typedEngine(for: model)?.sourcePerformanceCounters ?? .init()
    }

    package func resetSourcePerformanceCountersForTesting<
        Model: WebInspectorPersistentModel
    >(
        _ model: Model.Type
    ) {
        typedEngine(for: model)?.sourcePerformanceCounters = .init()
    }

    package func performanceCountersForTesting<
        Model: WebInspectorPersistentModel,
        SectionName: Hashable & Sendable
    >(
        for registration: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>
    ) throws -> WebInspectorFetchedResultsQueryPerformanceCounters {
        try requiredEngine(for: Model.self).performanceCounters(
            for: registration.token,
            publication: registration.publication
        )
    }

    package func resetPerformanceCountersForTesting<
        Model: WebInspectorPersistentModel,
        SectionName: Hashable & Sendable
    >(
        for registration: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>
    ) throws {
        try requiredEngine(for: Model.self).resetPerformanceCounters(
            for: registration.token,
            publication: registration.publication
        )
    }

    package func activeSubscriberCountForTesting<
        Model: WebInspectorPersistentModel,
        SectionName: Hashable & Sendable
    >(
        for registration: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>
    ) throws -> Int {
        try requiredEngine(for: Model.self).activeSubscriberCount(
            for: registration.token,
            publication: registration.publication
        )
    }

    package func waitingSubscriberCountForTesting<
        Model: WebInspectorPersistentModel,
        SectionName: Hashable & Sendable
    >(
        for registration: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>
    ) throws -> Int {
        try requiredEngine(for: Model.self).waitingSubscriberCount(
            for: registration.token,
            publication: registration.publication
        )
    }

    func queryState<
        Model: WebInspectorPersistentModel,
        SectionName: Hashable & Sendable
    >(
        for token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication
    ) async throws -> WebInspectorFetchedResultsQueryState<Model.ID, SectionName> {
        try ensureOpen()
        await waitForOutstandingControllerAdmission()
        await waitForOutstandingOwnerDelivery()
        try ensureOpen()
        return try requiredEngine(for: Model.self).state(
            for: token,
            publication: publication
        )
    }

    func subscribe<
        Model: WebInspectorPersistentModel,
        SectionName: Hashable & Sendable
    >(
        to token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication
    ) async throws -> WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication.UpdateSequence {
        try ensureOpen()
        await waitForOutstandingControllerAdmission()
        await waitForOutstandingOwnerDelivery()
        try ensureOpen()
        return try requiredEngine(for: Model.self).subscribe(
            to: token,
            publication: publication
        )
    }

    func rebase<
        Model: WebInspectorPersistentModel,
        SectionName: Hashable & Sendable
    >(
        _ rebaseToken: WebInspectorRevisionedSnapshotRebaseToken,
        for token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication
    ) async throws -> WebInspectorRevisionedSnapshotRebase<
        WebInspectorFetchedResultsSnapshot<Model.ID, SectionName>
    > {
        try ensureOpen()
        await waitForOutstandingControllerAdmission()
        await waitForOutstandingOwnerDelivery()
        try ensureOpen()
        return try requiredEngine(for: Model.self).rebase(
            rebaseToken,
            for: token,
            publication: publication
        )
    }

    func prepareReplacement<
        Model: WebInspectorPersistentModel,
        SectionName: Hashable & Sendable
    >(
        _ descriptor: WebInspectorFetchDescriptor<Model>,
        for token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication
    ) async throws -> WebInspectorFetchedResultsQueryCandidateToken<Model, SectionName> {
        try ensureOpen()
        await waitForOutstandingControllerAdmission()
        await waitForOutstandingOwnerDelivery()
        try ensureOpen()
        return try requiredEngine(for: Model.self).prepareReplacement(
            descriptor,
            for: token,
            publication: publication
        )
    }

    func commitReplacement<
        Model: WebInspectorPersistentModel,
        SectionName: Hashable & Sendable
    >(
        _ candidateToken: WebInspectorFetchedResultsQueryCandidateToken<Model, SectionName>,
        for token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication
    ) async throws -> WebInspectorFetchedResultsQueryState<Model.ID, SectionName> {
        try ensureOpen()
        await waitForOutstandingControllerAdmission()
        await waitForOutstandingOwnerDelivery()
        try ensureOpen()
        let (state, stagedDelivery) = try requiredEngine(for: Model.self)
            .commitReplacement(
                candidateToken,
                for: token,
                publication: publication
            )
        if let stagedDelivery {
            precondition(
                stagedDelivery.ownerBatch == nil,
                "Raw query replacement cannot stage controller owner state."
            )
            stagedDelivery.publication?.publish()
        }
        return state
    }

    func commitControllerReplacement<
        Model: WebInspectorPersistentModel,
        SectionName: Hashable & Sendable
    >(
        _ candidateToken: WebInspectorFetchedResultsQueryCandidateToken<Model, SectionName>,
        for token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication
    ) async throws -> WebInspectorFetchedResultsControllerReplacementCommit {
        try ensureOpen()
        await waitForOutstandingControllerAdmission()
        await waitForOutstandingOwnerDelivery()
        try ensureOpen()
        try Task.checkCancellation()
        let (_, stagedDelivery) = try requiredEngine(for: Model.self)
            .commitReplacement(
                candidateToken,
                for: token,
                publication: publication
            )
        guard let stagedDelivery,
            case .controller = stagedDelivery.mode,
            let ownerBatch = stagedDelivery.ownerBatch
        else {
            preconditionFailure(
                "A controller descriptor replacement must stage one owner backing value."
            )
        }
        let commit = WebInspectorFetchedResultsControllerReplacementCommit(
            ownerBatch: ownerBatch,
            publication: stagedDelivery.publication
        )
        outstandingOwnerDelivery = .replacement(commit)
        return commit
    }

    func discardReplacement<
        Model: WebInspectorPersistentModel,
        SectionName: Hashable & Sendable
    >(
        _ candidateToken: WebInspectorFetchedResultsQueryCandidateToken<Model, SectionName>,
        for token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication
    ) async {
        guard lifecycle == .open else {
            return
        }
        await waitForOutstandingControllerAdmission()
        await waitForOutstandingOwnerDelivery()
        guard lifecycle == .open else {
            return
        }
        guard let engine = typedEngine(for: Model.self) else {
            return
        }
        engine.discardReplacement(
            candidateToken,
            for: token,
            publication: publication
        )
    }

    func closeQuery<
        Model: WebInspectorPersistentModel,
        SectionName: Hashable & Sendable
    >(
        _ token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication
    ) async {
        guard lifecycle == .open else {
            return
        }
        await waitForOutstandingControllerAdmission()
        await waitForOutstandingOwnerDelivery()
        guard lifecycle == .open else {
            return
        }
        if let stagedDelivery = typedEngine(for: Model.self)?
            .close(token, publication: publication)
        {
            precondition(
                stagedDelivery.ownerBatch == nil,
                "Closing a query cannot stage controller owner state."
            )
            stagedDelivery.publication?.publish()
        }
    }

    fileprivate func stage<Model: WebInspectorPersistentModel>(
        _ batch: WebInspectorFetchedResultsSourceBatch<Model>
    ) -> _WebInspectorModelContextStagedQueryWork {
        engine(for: Model.self).applyBatch(batch)
    }

    private func validatedModelSources(
        in batches: [AnyWebInspectorModelSourceBatch],
        at canonicalRevision: UInt64
    ) -> [ConfiguredModelSource] {
        precondition(
            batches.allSatisfy { $0.canonicalRevision == canonicalRevision },
            "Every model-context source batch must match the explicit canonical revision."
        )

        var seenModelTypeIDs: Set<ObjectIdentifier> = []
        seenModelTypeIDs.reserveCapacity(batches.count)
        var sources: [ConfiguredModelSource] = []
        sources.reserveCapacity(batches.count)
        for batch in batches {
            precondition(
                seenModelTypeIDs.insert(batch.modelTypeID).inserted,
                "One model-context source transaction can stage each model type only once."
            )
            sources.append(
                ConfiguredModelSource(
                    modelTypeID: batch.modelTypeID,
                    sourceIdentity: batch.sourceIdentity
                )
            )
        }
        return sources
    }

    private func discardPreparedRecordCommits(
        _ commits: [_WebInspectorAnyPreparedModelRecordCommit]
    ) {
        for commit in commits.reversed() {
            do {
                try commit.discard()
            } catch {
                preconditionFailure(
                    "A prepared model-record commit became invalid during transaction rollback: \(error)"
                )
            }
        }
    }

    package func resolveControllerAdmission(
        _ ownerID: WebInspectorFetchedResultsControllerOwnerID,
        admission: WebInspectorFetchedResultsControllerAdmissionGate
    ) async -> WebInspectorFetchedResultsControllerAdmissionResolution {
        precondition(
            admission.ownerID == ownerID
                && ownerID.contextIdentity === identity,
            "A fetched-results controller admission carried a foreign owner identity."
        )
        guard let outstanding = outstandingControllerAdmission else {
            admission.acknowledgeCoreResolution()
            return await admission.value()
        }
        guard outstanding.ownerID == ownerID,
            outstanding.gate === admission
        else {
            preconditionFailure(
                "A fetched-results controller admission cannot resolve a different outstanding gate."
            )
        }
        let resolution = await admission.value()
        resolveOutstandingControllerAdmission(
            outstanding,
            resolution: resolution
        )
        admission.acknowledgeCoreResolution()
        return resolution
    }

    private func waitForOutstandingControllerAdmission() async {
        while let admission = outstandingControllerAdmission {
            let resolution = await admission.gate.value()
            resolveOutstandingControllerAdmission(
                admission,
                resolution: resolution
            )
        }
    }

    private func resolveOutstandingControllerAdmission(
        _ admission: OutstandingControllerAdmission,
        resolution: WebInspectorFetchedResultsControllerAdmissionResolution
    ) {
        guard let outstandingControllerAdmission,
            outstandingControllerAdmission.ownerID == admission.ownerID,
            outstandingControllerAdmission.gate === admission.gate
        else {
            return
        }
        self.outstandingControllerAdmission = nil
        admission.gate.recordCoreResolution()
        if resolution == .abandoned {
            if let delivery = admission.abandon(self) {
                precondition(
                    delivery.ownerBatch == nil,
                    "Abandoning an unactivated controller cannot stage owner state."
                )
                delivery.publication?.publish()
            }
        }
    }

    private func waitForOutstandingOwnerDelivery() async {
        while let delivery = outstandingOwnerDelivery {
            switch delivery {
            case let .query(commit):
                _ = await commit.waitUntilResolved()
                if case let .query(current)? = outstandingOwnerDelivery,
                    current === commit
                {
                    outstandingOwnerDelivery = nil
                }
            case let .replacement(commit):
                await commit.waitUntilResolved()
                if case let .replacement(current)? = outstandingOwnerDelivery,
                    current === commit
                {
                    outstandingOwnerDelivery = nil
                }
            }
        }
    }

    private func abortQueryCommit(
        token: UInt64,
        throwing error: any Error
    ) {
        guard case let .query(outstandingQueryCommit)? = outstandingOwnerDelivery,
            outstandingQueryCommit.token == token
        else {
            preconditionFailure(
                "A query-commit abort must resolve the context's outstanding transaction."
            )
        }
        finishClose(throwing: error)
    }

    private func finishClose(
        throwing error: (any Error)?
    ) {
        lifecycle = .closed
        outstandingOwnerDelivery = nil
        let publications = queryEngines.values.flatMap { engine in
            let work = engine.close(throwing: error)
            precondition(
                work.controllerOwnerBatches.isEmpty,
                "Closing query engines cannot stage controller owner values."
            )
            return work.controllerPublications + work.rawPublications
        }
        queryEngines.removeAll(keepingCapacity: false)
        for publication in publications {
            publication.publish()
        }
    }

    private func engine<Model: WebInspectorPersistentModel>(
        for model: Model.Type
    ) -> _WebInspectorFetchedResultsQueryEngine<Model> {
        let key = ObjectIdentifier(model)
        if let engine = queryEngines[key] {
            guard let typed = engine as? _WebInspectorFetchedResultsQueryEngine<Model> else {
                preconditionFailure(
                    "A context query engine was registered under the wrong model type."
                )
            }
            return typed
        }
        let engine = _WebInspectorFetchedResultsQueryEngine<Model>(
            contextIdentity: identity
        )
        queryEngines[key] = engine
        return engine
    }

    private func typedEngine<Model: WebInspectorPersistentModel>(
        for model: Model.Type
    ) -> _WebInspectorFetchedResultsQueryEngine<Model>? {
        let key = ObjectIdentifier(model)
        guard let engine = queryEngines[key] else {
            return nil
        }
        guard let typed = engine as? _WebInspectorFetchedResultsQueryEngine<Model> else {
            preconditionFailure(
                "A context query engine was registered under the wrong model type."
            )
        }
        return typed
    }

    private func requiredEngine<Model: WebInspectorPersistentModel>(
        for model: Model.Type
    ) throws -> _WebInspectorFetchedResultsQueryEngine<Model> {
        guard let engine = typedEngine(for: model) else {
            throw WebInspectorFetchedResultsQueryError.closedRegistration
        }
        return engine
    }

    private func ensureOpen() throws {
        if lifecycle != .open {
            throw WebInspectorFetchedResultsQueryError.closedRegistration
        }
    }

    private func ensureControllerModelConfigured<
        Model: WebInspectorPersistentModel
    >(
        _ model: Model.Type
    ) throws {
        guard let configuredModelTypeIDs else {
            return
        }
        guard configuredModelTypeIDs.contains(ObjectIdentifier(model)) else {
            throw WebInspectorFetchedResultsControllerError.unsupportedModel
        }
    }
}
