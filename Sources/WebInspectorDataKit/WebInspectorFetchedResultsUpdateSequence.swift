/// A single-consumer stream of one fetched-results registration's updates.
///
/// Copies share the same capacity-one subscription. Creating more than one
/// iterator is a programming error.
public struct WebInspectorFetchedResultsUpdateSequence<
    ItemID: Hashable & Sendable,
    SectionName: Hashable & Sendable
>: AsyncSequence, Sendable {
    public typealias Element = WebInspectorFetchedResultsUpdate<ItemID, SectionName>
    public typealias Failure = any Error

    public struct AsyncIterator: AsyncIteratorProtocol, Sendable {
        public typealias Element = WebInspectorFetchedResultsUpdate<ItemID, SectionName>
        public typealias Failure = any Error

        fileprivate typealias Snapshot = WebInspectorFetchedResultsSnapshot<ItemID, SectionName>
        fileprivate typealias Changes = WebInspectorFetchedResultsChanges<ItemID, SectionName>
        fileprivate typealias BaseIterator = WebInspectorRevisionedSnapshotSequence<
            Snapshot,
            Changes,
            any Error
        >.AsyncIterator

        private var base: BaseIterator
        private let rebase:
            @Sendable (
                WebInspectorRevisionedSnapshotRebaseToken
            ) async throws -> WebInspectorRevisionedSnapshotRebase<Snapshot>

        fileprivate init(
            base: BaseIterator,
            rebase:
                @escaping @Sendable (
                    WebInspectorRevisionedSnapshotRebaseToken
                ) async throws -> WebInspectorRevisionedSnapshotRebase<Snapshot>
        ) {
            self.base = base
            self.rebase = rebase
        }

        public mutating func next() async throws -> Element? {
            guard let update = try await base.next() else {
                return nil
            }
            switch update {
            case let .initial(revision, snapshot):
                return .initial(revision: revision, snapshot: snapshot)

            case let .changes(fromRevision, toRevision, changes):
                return .changes(
                    fromRevision: fromRevision,
                    toRevision: toRevision,
                    sectionChanges: changes.sectionChanges,
                    itemChanges: changes.itemChanges,
                    updatedItemIDs: changes.updatedItemIDs
                )

            case let .resetRequired(_, token):
                let rebased = try await rebase(token)
                switch rebased.disposition {
                case .initial:
                    return .initial(
                        revision: rebased.revision,
                        snapshot: rebased.snapshot
                    )
                case .reset:
                    return .reset(
                        revision: rebased.revision,
                        snapshot: rebased.snapshot
                    )
                }
            }
        }
    }

    package typealias Snapshot = WebInspectorFetchedResultsSnapshot<ItemID, SectionName>
    package typealias Changes = WebInspectorFetchedResultsChanges<ItemID, SectionName>
    package typealias BaseSequence = WebInspectorRevisionedSnapshotSequence<
        Snapshot,
        Changes,
        any Error
    >

    private let base: BaseSequence
    private let rebase:
        @Sendable (
            WebInspectorRevisionedSnapshotRebaseToken
        ) async throws -> WebInspectorRevisionedSnapshotRebase<Snapshot>

    package init(
        base: BaseSequence,
        rebase:
            @escaping @Sendable (
                WebInspectorRevisionedSnapshotRebaseToken
            ) async throws -> WebInspectorRevisionedSnapshotRebase<Snapshot>
    ) {
        self.base = base
        self.rebase = rebase
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), rebase: rebase)
    }
}
