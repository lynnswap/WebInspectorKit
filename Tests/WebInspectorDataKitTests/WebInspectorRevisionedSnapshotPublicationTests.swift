import Testing
@testable import WebInspectorDataKit

private enum RevisionedSnapshotTestFailure: Error, Equatable, Sendable {
    case failed
}

private typealias TestPublication = WebInspectorRevisionedSnapshotPublication<
    [Int],
    String,
    RevisionedSnapshotTestFailure
>
private typealias TestSequence = TestPublication.UpdateSequence
private typealias TestUpdate = TestPublication.Update
private typealias TestRebaseToken = TestPublication.RebaseToken

@Test
func revisionedSnapshotSubscriptionStartsWithOneOwnerAtomicInitialState() async throws {
    let owner = RevisionedSnapshotTestOwner(revision: 7, snapshot: [1, 2])
    let sequence = await owner.subscribe()
    #expect(owner.publication.activeSubscriberCount == 1)

    var iterator = sequence.makeAsyncIterator()
    let update = try await iterator.next()

    #expect(update == .initial(revision: 7, snapshot: [1, 2]))
    let initialCaptures = await owner.initialSnapshotCaptureCount
    let rebaseCaptures = await owner.rebaseSnapshotCaptureCount
    #expect(initialCaptures == 1)
    #expect(rebaseCaptures == 0)
}

@Test
func waitingSubscriberReceivesAContiguousChangeWithoutSnapshotWork() async throws {
    let owner = RevisionedSnapshotTestOwner()
    var iterator = await owner.subscribe().makeAsyncIterator()
    #expect(try await iterator.next() == .initial(revision: 0, snapshot: []))

    let delivery = Task {
        try await iterator.next()
    }
    while owner.publication.waitingSubscriberCountForTesting == 0 {
        await Task.yield()
    }

    await owner.publish(1)

    #expect(
        try await delivery.value
            == .changes(
                fromRevision: 0,
                toRevision: 1,
                changes: "insert 1"
            ))
    let rebaseCaptures = await owner.rebaseSnapshotCaptureCount
    #expect(rebaseCaptures == 0)
}

@Test
func pendingInitialCoalescesToOwnerSuppliedInitialRebase() async throws {
    let owner = RevisionedSnapshotTestOwner()
    var iterator = await owner.subscribe().makeAsyncIterator()

    await owner.publish(1)
    await owner.publish(2)

    let capturesBeforeDequeue = await owner.rebaseSnapshotCaptureCount
    #expect(capturesBeforeDequeue == 0)
    guard case let .resetRequired(latestRevision, token) = try await iterator.next() else {
        Issue.record("Expected an owner-supplied initial rebase request.")
        return
    }
    #expect(latestRevision == 2)

    let rebase = try await owner.rebase(token)
    #expect(
        rebase
            == .init(
                disposition: .initial,
                revision: 2,
                snapshot: [1, 2]
            ))
    let capturesAfterRebase = await owner.rebaseSnapshotCaptureCount
    #expect(capturesAfterRebase == 1)
}

@Test
func pendingChangeAndResetMarkerCoalesceWithoutSnapshotWork() async throws {
    let owner = RevisionedSnapshotTestOwner()
    var iterator = await owner.subscribe().makeAsyncIterator()
    _ = try await iterator.next()

    await owner.publish(1)
    await owner.publish(2)
    await owner.publish(3)

    let capturesBeforeDequeue = await owner.rebaseSnapshotCaptureCount
    #expect(capturesBeforeDequeue == 0)
    guard case let .resetRequired(latestRevision, token) = try await iterator.next() else {
        Issue.record("Expected a reset request after a pending change overflowed.")
        return
    }
    #expect(latestRevision == 3)

    let rebase = try await owner.rebase(token)
    #expect(
        rebase
            == .init(
                disposition: .reset,
                revision: 3,
                snapshot: [1, 2, 3]
            ))
}

@Test
func permanentlySlowSubscriberDoesNoSnapshotWorkWhilePublishing() async throws {
    let owner = RevisionedSnapshotTestOwner()
    let sequence = await owner.subscribe()
    var iterator = sequence.makeAsyncIterator()
    _ = try await iterator.next()

    await owner.publish(1...100)

    let rebaseCaptures = await owner.rebaseSnapshotCaptureCount
    #expect(rebaseCaptures == 0)
    #expect(owner.publication.activeSubscriberCount == 1)
    sequence.cancel()
}

@Test
func dequeuedResetTracksLaterPublishesAndRebasesToTheLatestOwnerRevision() async throws {
    let owner = RevisionedSnapshotTestOwner()
    var iterator = await owner.subscribe().makeAsyncIterator()
    _ = try await iterator.next()

    await owner.publish(1)
    await owner.publish(2)
    guard case let .resetRequired(markerRevision, token) = try await iterator.next() else {
        Issue.record("Expected a reset request.")
        return
    }
    #expect(markerRevision == 2)

    await owner.publish(3)
    let rebase = try await owner.rebase(token, thenPublish: 4)
    #expect(
        rebase
            == .init(
                disposition: .reset,
                revision: 3,
                snapshot: [1, 2, 3]
            ))

    #expect(
        try await iterator.next()
            == .changes(
                fromRevision: 3,
                toRevision: 4,
                changes: "insert 4"
            ))
}

@Test
func slowSubscribersRequestIndependentOwnerSnapshotsOnlyWhenConsumed() async throws {
    let owner = RevisionedSnapshotTestOwner()
    var firstIterator = await owner.subscribe().makeAsyncIterator()
    var secondIterator = await owner.subscribe().makeAsyncIterator()
    _ = try await firstIterator.next()
    _ = try await secondIterator.next()

    await owner.publish(1)
    await owner.publish(2)
    let capturesBeforeDequeue = await owner.rebaseSnapshotCaptureCount
    #expect(capturesBeforeDequeue == 0)

    guard case let .resetRequired(_, firstToken) = try await firstIterator.next(),
        case let .resetRequired(_, secondToken) = try await secondIterator.next()
    else {
        Issue.record("Expected independent reset requests.")
        return
    }

    _ = try await owner.rebase(firstToken)
    let capturesAfterFirst = await owner.rebaseSnapshotCaptureCount
    #expect(capturesAfterFirst == 1)

    _ = try await owner.rebase(secondToken)
    let capturesAfterSecond = await owner.rebaseSnapshotCaptureCount
    #expect(capturesAfterSecond == 2)
}

@Test
func explicitSequenceCancellationRemovesOnlyItsSubscriber() async throws {
    let publication = TestPublication()
    let cancelledSequence = publication.subscribe(revision: 0, snapshot: [])
    var remainingIterator =
        publication
        .subscribe(revision: 0, snapshot: [])
        .makeAsyncIterator()
    _ = try await remainingIterator.next()
    #expect(publication.activeSubscriberCount == 2)

    cancelledSequence.cancel()
    #expect(publication.activeSubscriberCount == 1)

    publication.publish(from: 0, to: 1, changes: "one")
    #expect(
        try await remainingIterator.next()
            == .changes(
                fromRevision: 0,
                toRevision: 1,
                changes: "one"
            ))
}

@Test
func explicitIteratorCancellationRemovesOnlyItsSubscriber() async throws {
    let publication = TestPublication()
    var cancelledIterator =
        publication
        .subscribe(revision: 0, snapshot: [])
        .makeAsyncIterator()
    var remainingIterator =
        publication
        .subscribe(revision: 0, snapshot: [])
        .makeAsyncIterator()
    _ = try await cancelledIterator.next()
    _ = try await remainingIterator.next()

    cancelledIterator.cancel()
    #expect(publication.activeSubscriberCount == 1)

    publication.publish(from: 0, to: 1, changes: "one")
    #expect(
        try await remainingIterator.next()
            == .changes(
                fromRevision: 0,
                toRevision: 1,
                changes: "one"
            ))
}

@Test
func taskCancellationUnregistersAWaitingSubscriber() async throws {
    let publication = TestPublication()
    let sequence = publication.subscribe(revision: 0, snapshot: [])
    let consumedInitial = AsyncStream<Void>.makeStream()

    let consumer = Task {
        var iterator = sequence.makeAsyncIterator()
        _ = try await iterator.next()
        consumedInitial.continuation.yield()
        return try await iterator.next()
    }

    for await _ in consumedInitial.stream.prefix(1) {}
    consumer.cancel()

    #expect(try await consumer.value == nil)
    #expect(publication.activeSubscriberCount == 0)
}

@Test
func foreignPublicationRejectsARebaseToken() async throws {
    let publication = TestPublication()
    let foreignPublication = TestPublication(revision: 2)
    var iterator =
        publication
        .subscribe(revision: 0, snapshot: [])
        .makeAsyncIterator()
    _ = try await iterator.next()
    publication.publish(from: 0, to: 1, changes: "one")
    publication.publish(from: 1, to: 2, changes: "two")
    guard case let .resetRequired(_, token) = try await iterator.next() else {
        Issue.record("Expected a reset request.")
        return
    }

    #expect(throws: WebInspectorRevisionedSnapshotRebaseError.foreignPublication) {
        try foreignPublication.rebase(token, revision: 2, snapshot: [1, 2])
    }
}

@Test
func staleSnapshotAndRepeatedTokenAreRejectedExplicitly() async throws {
    let publication = TestPublication()
    var snapshotBuildCount = 0
    func makeSnapshot(_ values: [Int]) -> [Int] {
        snapshotBuildCount += 1
        return values
    }
    var iterator =
        publication
        .subscribe(revision: 0, snapshot: [])
        .makeAsyncIterator()
    _ = try await iterator.next()
    publication.publish(from: 0, to: 1, changes: "one")
    publication.publish(from: 1, to: 2, changes: "two")
    guard case let .resetRequired(_, token) = try await iterator.next() else {
        Issue.record("Expected a reset request.")
        return
    }

    #expect(
        throws: WebInspectorRevisionedSnapshotRebaseError.staleSnapshot(
            expectedRevision: 2,
            suppliedRevision: 1
        )
    ) {
        try publication.rebase(
            token,
            revision: 1,
            snapshot: makeSnapshot([1])
        )
    }
    #expect(snapshotBuildCount == 0)

    #expect(
        try publication.rebase(
            token,
            revision: 2,
            snapshot: makeSnapshot([1, 2])
        )
            == .init(
                disposition: .reset,
                revision: 2,
                snapshot: [1, 2]
            ))
    #expect(snapshotBuildCount == 1)
    #expect(throws: WebInspectorRevisionedSnapshotRebaseError.staleToken) {
        try publication.rebase(
            token,
            revision: 2,
            snapshot: makeSnapshot([1, 2])
        )
    }
    #expect(snapshotBuildCount == 1)
}

@Test
func cancellationInvalidatesADequeuedRebaseToken() async throws {
    let publication = TestPublication()
    var iterator =
        publication
        .subscribe(revision: 0, snapshot: [])
        .makeAsyncIterator()
    _ = try await iterator.next()
    publication.publish(from: 0, to: 1, changes: "one")
    publication.publish(from: 1, to: 2, changes: "two")
    guard case let .resetRequired(_, token) = try await iterator.next() else {
        Issue.record("Expected a reset request.")
        return
    }

    iterator.cancel()
    #expect(throws: WebInspectorRevisionedSnapshotRebaseError.subscriptionCancelled) {
        try publication.rebase(token, revision: 2, snapshot: [1, 2])
    }
}

@Test
func successfulFinishSupersedesAnOutstandingRebase() async throws {
    let publication = TestPublication()
    var iterator =
        publication
        .subscribe(revision: 0, snapshot: [])
        .makeAsyncIterator()
    _ = try await iterator.next()
    publication.publish(from: 0, to: 1, changes: "one")
    publication.publish(from: 1, to: 2, changes: "two")
    guard case let .resetRequired(_, token) = try await iterator.next() else {
        Issue.record("Expected a reset request.")
        return
    }

    publication.finish()

    #expect(throws: WebInspectorRevisionedSnapshotRebaseError.publicationTerminated) {
        try publication.rebase(token, revision: 2, snapshot: [1, 2])
    }
    #expect(try await iterator.next() == nil)
    #expect(publication.activeSubscriberCount == 0)
}

@Test
func successfulFinishSupersedesAPendingResetMarkerBeforeDequeue() async throws {
    let publication = TestPublication()
    var iterator =
        publication
        .subscribe(revision: 0, snapshot: [])
        .makeAsyncIterator()
    _ = try await iterator.next()
    publication.publish(from: 0, to: 1, changes: "one")
    publication.publish(from: 1, to: 2, changes: "two")

    publication.finish()

    #expect(try await iterator.next() == nil)
    #expect(publication.activeSubscriberCount == 0)
}

@Test
func rebaseBeforeSuccessfulFinishEstablishesTheSnapshotBoundaryFirst() async throws {
    let publication = TestPublication()
    var iterator =
        publication
        .subscribe(revision: 0, snapshot: [])
        .makeAsyncIterator()
    _ = try await iterator.next()
    publication.publish(from: 0, to: 1, changes: "one")
    publication.publish(from: 1, to: 2, changes: "two")
    guard case let .resetRequired(_, token) = try await iterator.next() else {
        Issue.record("Expected a reset request.")
        return
    }

    #expect(try publication.rebase(token, revision: 2, snapshot: [1, 2]).revision == 2)
    publication.finish()
    #expect(try await iterator.next() == nil)
}

@Test
func failedFinishSupersedesRebaseThenUsesTheSequenceFailureType() async throws {
    let publication = TestPublication()
    let sequence = publication.subscribe(revision: 0, snapshot: [])
    requireTypedFailure(sequence)
    var iterator = sequence.makeAsyncIterator()
    _ = try await iterator.next()
    publication.publish(from: 0, to: 1, changes: "one")
    publication.publish(from: 1, to: 2, changes: "two")
    guard case let .resetRequired(_, token) = try await iterator.next() else {
        Issue.record("Expected a reset request.")
        return
    }

    publication.finish(throwing: .failed)

    #expect(throws: WebInspectorRevisionedSnapshotRebaseError.publicationTerminated) {
        try publication.rebase(token, revision: 2, snapshot: [1, 2])
    }
    await #expect(throws: RevisionedSnapshotTestFailure.failed) {
        try await iterator.next()
    }
    #expect(try await iterator.next() == nil)

    var lateIterator =
        publication
        .subscribe(revision: 2, snapshot: [1, 2])
        .makeAsyncIterator()
    await #expect(throws: RevisionedSnapshotTestFailure.failed) {
        try await lateIterator.next()
    }
    #expect(try await lateIterator.next() == nil)
}

@Test
func successfulFinishDrainsAConcretePendingChange() async throws {
    let publication = TestPublication()
    var iterator =
        publication
        .subscribe(revision: 0, snapshot: [])
        .makeAsyncIterator()
    _ = try await iterator.next()
    publication.publish(from: 0, to: 1, changes: "one")

    publication.finish()

    #expect(
        try await iterator.next()
            == .changes(
                fromRevision: 0,
                toRevision: 1,
                changes: "one"
            ))
    #expect(try await iterator.next() == nil)
}

#if os(macOS)
    @Test
    func noncontiguousRevisionFailsFast() async {
        await #expect(processExitsWith: .failure) {
            let publication = TestPublication()
            publication.publish(from: 0, to: 2, changes: "gap")
        }
    }

    @Test
    func staleInitialRevisionFailsFast() async {
        await #expect(processExitsWith: .failure) {
            let publication = TestPublication(revision: 1)
            _ = publication.subscribe(revision: 0, snapshot: [])
        }
    }

    @Test
    func requestingAnotherUpdateBeforeRebaseFailsFast() async {
        await #expect(processExitsWith: .failure) {
            let publication = TestPublication()
            var iterator =
                publication
                .subscribe(revision: 0, snapshot: [])
                .makeAsyncIterator()
            _ = try await iterator.next()
            publication.publish(from: 0, to: 1, changes: "one")
            publication.publish(from: 1, to: 2, changes: "two")
            _ = try await iterator.next()
            _ = try await iterator.next()
        }
    }

    @Test
    func aSecondIteratorFailsFastEvenFromASequenceCopy() async {
        await #expect(processExitsWith: .failure) {
            let publication = TestPublication()
            let sequence = publication.subscribe(revision: 0, snapshot: [])
            let sequenceCopy = sequence
            _ = sequence.makeAsyncIterator()
            _ = sequenceCopy.makeAsyncIterator()
        }
    }
#endif

private actor RevisionedSnapshotTestOwner {
    nonisolated let publication: TestPublication
    private var revision: UInt64
    private var snapshot: [Int]
    private(set) var initialSnapshotCaptureCount = 0
    private(set) var rebaseSnapshotCaptureCount = 0

    init(revision: UInt64 = 0, snapshot: [Int] = []) {
        publication = TestPublication(revision: revision)
        self.revision = revision
        self.snapshot = snapshot
    }

    func subscribe() -> TestSequence {
        initialSnapshotCaptureCount += 1
        return publication.subscribe(revision: revision, snapshot: snapshot)
    }

    func publish(_ value: Int) {
        precondition(revision < UInt64.max)
        let fromRevision = revision
        revision += 1
        snapshot.append(value)
        publication.publish(
            from: fromRevision,
            to: revision,
            changes: "insert \(value)"
        )
    }

    func publish(_ values: ClosedRange<Int>) {
        for value in values {
            publish(value)
        }
    }

    func rebase(_ token: TestRebaseToken) throws -> TestPublication.Rebase {
        rebaseSnapshotCaptureCount += 1
        return try publication.rebase(
            token,
            revision: revision,
            snapshot: snapshot
        )
    }

    func rebase(
        _ token: TestRebaseToken,
        thenPublish value: Int
    ) throws -> TestPublication.Rebase {
        let rebase = try self.rebase(token)
        publish(value)
        return rebase
    }
}

private func requireTypedFailure<Sequence: AsyncSequence>(
    _: Sequence
) where Sequence.Failure == RevisionedSnapshotTestFailure {}
