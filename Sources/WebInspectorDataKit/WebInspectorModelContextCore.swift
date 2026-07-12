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
            inout [_WebInspectorModelContextPendingQueryPublication]
        ) -> Void

    package init<Model: WebInspectorPersistentModel>(
        _ batch: WebInspectorFetchedResultsSourceBatch<Model>
    ) {
        canonicalRevision = batch.canonicalRevision
        modelTypeID = ObjectIdentifier(Model.self)
        stageBody = { core, publications in
            publications.append(contentsOf: core.stage(batch))
        }
    }

    fileprivate func stage(
        on core: isolated WebInspectorModelContextCore,
        into publications: inout [_WebInspectorModelContextPendingQueryPublication]
    ) {
        stageBody(core, &publications)
    }
}

/// The publication phase of one canonical model-context transaction.
///
/// The model owner receives this Sendable commit after query state has been
/// staged. It patches every materialized model first, then calls `publish()`
/// in the same owner turn. Publication is exactly once; the context core does
/// not accept a later query operation until this commit has been published.
package final class WebInspectorModelContextQueryCommit: Sendable {
    private enum State: Sendable {
        case pending(
            publications: [_WebInspectorModelContextPendingQueryPublication],
            waiters: [CheckedContinuation<Void, Never>]
        )
        case publishing(waiters: [CheckedContinuation<Void, Never>])
        case published
    }

    package let canonicalRevision: UInt64
    private let state: Mutex<State>

    fileprivate init(
        canonicalRevision: UInt64,
        publications: [_WebInspectorModelContextPendingQueryPublication]
    ) {
        self.canonicalRevision = canonicalRevision
        state = Mutex(.pending(publications: publications, waiters: []))
    }

    /// Makes every registration mailbox observe this canonical transaction.
    ///
    /// Call only after the same owner has patched all materialized models for
    /// `canonicalRevision`.
    package func publish() {
        let publications = state.withLock { state in
            switch state {
            case let .pending(publications, waiters):
                state = .publishing(waiters: waiters)
                return publications
            case .publishing, .published:
                preconditionFailure(
                    "A model-context query commit can be published only once."
                )
            }
        }

        for publication in publications {
            publication.publish()
        }

        let waiters = state.withLock { state in
            guard case let .publishing(waiters) = state else {
                preconditionFailure(
                    "A model-context query commit lost its publication phase."
                )
            }
            state = .published
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    package var isPublishedForTesting: Bool {
        state.withLock { state in
            if case .published = state {
                return true
            }
            return false
        }
    }

    fileprivate func waitUntilPublished() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                switch state {
                case let .pending(publications, waiters):
                    state = .pending(
                        publications: publications,
                        waiters: waiters + [continuation]
                    )
                    return false
                case let .publishing(waiters):
                    state = .publishing(waiters: waiters + [continuation])
                    return false
                case .published:
                    return true
                }
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}

/// Owns one model context's query sources, registrations, and publications.
///
/// The actor is the only isolation boundary. Each model-specific query engine
/// is synchronous and non-Sendable, and remains stored inside this actor.
package actor WebInspectorModelContextCore {
    private var queryEngines: [ObjectIdentifier: any _WebInspectorAnyQueryEngine] = [:]
    private var lastCanonicalRevision: UInt64?
    private var outstandingQueryCommit: WebInspectorModelContextQueryCommit?
    private var isClosed = false

    package init() {}

    package func register<Model: WebInspectorPersistentModel>(
        _ model: Model.Type,
        fetchDescriptor: WebInspectorFetchDescriptor<Model> = .init()
    ) async throws -> WebInspectorFetchedResultsQueryRegistration<Model, Never> {
        await waitForOutstandingQueryCommit()
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
        await waitForOutstandingQueryCommit()
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

    package func applyBatch<Model: WebInspectorPersistentModel>(
        _ batch: WebInspectorFetchedResultsSourceBatch<Model>
    ) async -> WebInspectorModelContextQueryCommit {
        await applyBatches([WebInspectorModelContextQueryBatch(batch)])
    }

    package func applyBatches(
        _ batches: [WebInspectorModelContextQueryBatch]
    ) async -> WebInspectorModelContextQueryCommit {
        await waitForOutstandingQueryCommit()
        precondition(
            isClosed == false,
            "A closed model context cannot stage a canonical query transaction."
        )
        precondition(
            batches.isEmpty == false,
            "A model-context query transaction must contain source work."
        )

        let canonicalRevision = batches[0].canonicalRevision
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

        var publications: [_WebInspectorModelContextPendingQueryPublication] = []
        for batch in batches {
            batch.stage(on: self, into: &publications)
        }
        lastCanonicalRevision = canonicalRevision

        let commit = WebInspectorModelContextQueryCommit(
            canonicalRevision: canonicalRevision,
            publications: publications
        )
        outstandingQueryCommit = commit
        return commit
    }

    package func close() async {
        await waitForOutstandingQueryCommit()
        guard isClosed == false else {
            return
        }
        isClosed = true
        let publications = queryEngines.values.flatMap { $0.close() }
        queryEngines.removeAll(keepingCapacity: false)
        for publication in publications {
            publication.publish()
        }
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
        await waitForOutstandingQueryCommit()
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
        await waitForOutstandingQueryCommit()
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
        await waitForOutstandingQueryCommit()
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
        await waitForOutstandingQueryCommit()
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
        await waitForOutstandingQueryCommit()
        let (state, pendingPublication) = try requiredEngine(for: Model.self)
            .commitReplacement(
                candidateToken,
                for: token,
                publication: publication
            )
        pendingPublication?.publish()
        return state
    }

    func discardReplacement<
        Model: WebInspectorPersistentModel,
        SectionName: Hashable & Sendable
    >(
        _ candidateToken: WebInspectorFetchedResultsQueryCandidateToken<Model, SectionName>,
        for token: WebInspectorFetchedResultsQueryRegistrationToken<Model, SectionName>,
        publication: WebInspectorFetchedResultsQueryRegistration<Model, SectionName>.Publication
    ) async {
        await waitForOutstandingQueryCommit()
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
        await waitForOutstandingQueryCommit()
        typedEngine(for: Model.self)?
            .close(token, publication: publication)?
            .publish()
    }

    fileprivate func stage<Model: WebInspectorPersistentModel>(
        _ batch: WebInspectorFetchedResultsSourceBatch<Model>
    ) -> [_WebInspectorModelContextPendingQueryPublication] {
        engine(for: Model.self).applyBatch(batch)
    }

    private func waitForOutstandingQueryCommit() async {
        while let commit = outstandingQueryCommit {
            await commit.waitUntilPublished()
            if outstandingQueryCommit === commit {
                outstandingQueryCommit = nil
            }
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
        let engine = _WebInspectorFetchedResultsQueryEngine<Model>()
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
        if isClosed {
            throw WebInspectorFetchedResultsQueryError.closedRegistration
        }
    }
}
