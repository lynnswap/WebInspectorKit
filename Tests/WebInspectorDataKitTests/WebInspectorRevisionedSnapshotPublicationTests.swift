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

@Test
func revisionedSnapshotSubscriptionStartsWithOneAtomicInitialState() async throws {
    let publication = TestPublication(revision: 7, snapshot: [1, 2])
    let sequence = publication.subscribe()
    #expect(publication.activeSubscriberCount == 1)

    var iterator = sequence.makeAsyncIterator()
    let update = try await iterator.next()

    #expect(update == .initial(revision: 7, snapshot: [1, 2]))
}

@Test
func revisionedSnapshotPublicationDeliversAContiguousChange() async throws {
    let publication = TestPublication(snapshot: [])
    var iterator = publication.subscribe().makeAsyncIterator()
    #expect(try await iterator.next() == .initial(revision: 0, snapshot: []))

    publication.publish(
        from: 0,
        to: 1,
        changes: "insert 1",
        latestSnapshot: [1]
    )

    #expect(try await iterator.next() == .changes(
        fromRevision: 0,
        toRevision: 1,
        changes: "insert 1"
    ))
}

@Test
func waitingSubscriberReceivesTheContiguousChangeDirectly() async throws {
    let publication = TestPublication(snapshot: [])
    var iterator = publication.subscribe().makeAsyncIterator()
    _ = try await iterator.next()

    let delivery = Task {
        try await iterator.next()
    }
    while publication.waitingSubscriberCountForTesting == 0 {
        await Task.yield()
    }

    publication.publish(
        from: 0,
        to: 1,
        changes: "insert 1",
        latestSnapshot: [1]
    )

    #expect(try await delivery.value == .changes(
        fromRevision: 0,
        toRevision: 1,
        changes: "insert 1"
    ))
}

@Test
func pendingInitialRefreshesToTheLatestAtomicInitialState() async throws {
    let publication = TestPublication(snapshot: [])
    var iterator = publication.subscribe().makeAsyncIterator()

    publication.publish(from: 0, to: 1, changes: "one", latestSnapshot: [1])
    publication.publish(from: 1, to: 2, changes: "two", latestSnapshot: [1, 2])

    #expect(try await iterator.next() == .initial(revision: 2, snapshot: [1, 2]))
}

@Test
func slowSubscriberReceivesOneLatestReset() async throws {
    let publication = TestPublication(snapshot: [])
    var iterator = publication.subscribe().makeAsyncIterator()
    _ = try await iterator.next()

    publication.publish(from: 0, to: 1, changes: "one", latestSnapshot: [1])
    publication.publish(from: 1, to: 2, changes: "two", latestSnapshot: [1, 2])

    #expect(try await iterator.next() == .reset(revision: 2, snapshot: [1, 2]))
}

@Test
func pendingResetRefreshesWithoutExposingIntermediateStates() async throws {
    let publication = TestPublication(snapshot: [])
    var iterator = publication.subscribe().makeAsyncIterator()
    _ = try await iterator.next()

    publication.publish(from: 0, to: 1, changes: "one", latestSnapshot: [1])
    publication.publish(from: 1, to: 2, changes: "two", latestSnapshot: [1, 2])
    publication.publish(from: 2, to: 3, changes: "three", latestSnapshot: [1, 2, 3])

    #expect(try await iterator.next() == .reset(revision: 3, snapshot: [1, 2, 3]))
}

@Test
func subscribersMaintainIndependentCapacityOneMailboxes() async throws {
    let publication = TestPublication(snapshot: [])
    var fastIterator = publication.subscribe().makeAsyncIterator()
    var slowIterator = publication.subscribe().makeAsyncIterator()
    _ = try await fastIterator.next()
    _ = try await slowIterator.next()

    publication.publish(from: 0, to: 1, changes: "one", latestSnapshot: [1])
    #expect(try await fastIterator.next() == .changes(
        fromRevision: 0,
        toRevision: 1,
        changes: "one"
    ))

    publication.publish(from: 1, to: 2, changes: "two", latestSnapshot: [1, 2])

    #expect(try await fastIterator.next() == .changes(
        fromRevision: 1,
        toRevision: 2,
        changes: "two"
    ))
    #expect(try await slowIterator.next() == .reset(revision: 2, snapshot: [1, 2]))
}

@Test
func explicitSequenceCancellationRemovesOnlyItsSubscriber() async throws {
    let publication = TestPublication(snapshot: [])
    let cancelledSequence = publication.subscribe()
    var remainingIterator = publication.subscribe().makeAsyncIterator()
    _ = try await remainingIterator.next()
    #expect(publication.activeSubscriberCount == 2)

    cancelledSequence.cancel()
    #expect(publication.activeSubscriberCount == 1)

    publication.publish(from: 0, to: 1, changes: "one", latestSnapshot: [1])
    #expect(try await remainingIterator.next() == .changes(
        fromRevision: 0,
        toRevision: 1,
        changes: "one"
    ))
}

@Test
func explicitIteratorCancellationRemovesOnlyItsSubscriber() async throws {
    let publication = TestPublication(snapshot: [])
    var cancelledIterator = publication.subscribe().makeAsyncIterator()
    var remainingIterator = publication.subscribe().makeAsyncIterator()
    _ = try await cancelledIterator.next()
    _ = try await remainingIterator.next()

    cancelledIterator.cancel()
    #expect(publication.activeSubscriberCount == 1)

    publication.publish(from: 0, to: 1, changes: "one", latestSnapshot: [1])
    #expect(try await remainingIterator.next() == .changes(
        fromRevision: 0,
        toRevision: 1,
        changes: "one"
    ))
}

@Test
func taskCancellationUnregistersAWaitingSubscriber() async throws {
    let publication = TestPublication(snapshot: [])
    let sequence = publication.subscribe()
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
func successfulFinishDrainsPublishedUpdateThenTerminatesCurrentAndFutureSubscribers() async throws {
    let publication = TestPublication(snapshot: [])
    var iterator = publication.subscribe().makeAsyncIterator()
    _ = try await iterator.next()
    publication.publish(from: 0, to: 1, changes: "one", latestSnapshot: [1])

    publication.finish()

    #expect(try await iterator.next() == .changes(
        fromRevision: 0,
        toRevision: 1,
        changes: "one"
    ))
    #expect(try await iterator.next() == nil)
    #expect(publication.activeSubscriberCount == 0)

    var lateIterator = publication.subscribe().makeAsyncIterator()
    #expect(try await lateIterator.next() == nil)
}

@Test
func failedFinishUsesTheSequenceFailureTypeForCurrentAndFutureSubscribers() async throws {
    let publication = TestPublication(snapshot: [])
    let sequence = publication.subscribe()
    requireTypedFailure(sequence)
    var iterator = sequence.makeAsyncIterator()
    _ = try await iterator.next()

    publication.finish(throwing: .failed)

    await #expect(throws: RevisionedSnapshotTestFailure.failed) {
        try await iterator.next()
    }
    #expect(try await iterator.next() == nil)

    var lateIterator = publication.subscribe().makeAsyncIterator()
    await #expect(throws: RevisionedSnapshotTestFailure.failed) {
        try await lateIterator.next()
    }
    #expect(try await lateIterator.next() == nil)
}

#if os(macOS)
@Test
func noncontiguousRevisionFailsFast() async {
    await #expect(processExitsWith: .failure) {
        let publication = TestPublication(snapshot: [])
        publication.publish(
            from: 0,
            to: 2,
            changes: "gap",
            latestSnapshot: [2]
        )
    }
}

@Test
func aSecondIteratorFailsFastEvenFromASequenceCopy() async {
    await #expect(processExitsWith: .failure) {
        let publication = TestPublication(snapshot: [])
        let sequence = publication.subscribe()
        let sequenceCopy = sequence
        _ = sequence.makeAsyncIterator()
        _ = sequenceCopy.makeAsyncIterator()
    }
}
#endif

private func requireTypedFailure<Sequence: AsyncSequence>(
    _: Sequence
) where Sequence.Failure == RevisionedSnapshotTestFailure {}
