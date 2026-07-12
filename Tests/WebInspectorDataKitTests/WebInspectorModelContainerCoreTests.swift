import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

private struct ModelContainerCoreFixture {
    let core: WebInspectorModelContainerCore
    let pageTarget = ModelTarget(
        id: WebInspectorTarget.ID("page"),
        kind: .page,
        frameID: FrameID("main-frame"),
        parentFrameID: nil
    )
    var attachmentGeneration = WebInspectorContainerAttachmentGeneration(
        rawValue: 1
    )
    var pageGeneration = WebInspectorPage.Generation(rawValue: 1)
    var nextSequence: UInt64 = 1

    init(domains: Set<ModelDomain> = [.network]) {
        core = WebInspectorModelContainerCore(
            configuredDomains: domains
        )
    }

    mutating func establishAttachment(
        attachment: UInt64 = 1,
        page: UInt64 = 1
    ) async throws {
        try await beginAttachment(attachment: attachment, page: page)
        _ = try await publishTargetSnapshot()
    }

    mutating func beginAttachment(
        attachment: UInt64,
        page: UInt64 = 1
    ) async throws {
        attachmentGeneration = WebInspectorContainerAttachmentGeneration(
            rawValue: attachment
        )
        pageGeneration = WebInspectorPage.Generation(rawValue: page)
        nextSequence = 1
        _ = try await core.reduce(
            .reset(pageGeneration),
            attachmentGeneration: attachmentGeneration
        )
    }

    func publishTargetSnapshot() async throws
        -> WebInspectorCanonicalModelCommit?
    {
        try await core.reduce(
            .targetSnapshot(
                generation: pageGeneration,
                through: 0,
                snapshot: ModelTargetSnapshot(
                    currentPageID: pageTarget.id,
                    targets: [
                        ModelTargetState(
                            target: pageTarget,
                            navigationEpoch: ModelNavigationEpoch(rawValue: 1),
                            domBindingEpoch: nil,
                            runtimeBindingEpoch: nil,
                            consoleBindingEpoch: nil
                        )
                    ]
                )
            ),
            attachmentGeneration: attachmentGeneration
        )
    }

    func scope() -> ModelEventScope {
        ModelEventScope(
            generation: pageGeneration,
            target: pageTarget,
            agentTarget: pageTarget,
            navigationEpoch: ModelNavigationEpoch(rawValue: 1),
            domBindingEpoch: nil,
            runtimeBindingEpoch: nil,
            consoleBindingEpoch: nil
        )
    }

    mutating func event(
        _ payload: ModelProtocolEvent
    ) async throws -> WebInspectorCanonicalModelCommit? {
        defer { nextSequence += 1 }
        return try await core.reduce(
            .event(
                sequence: nextSequence,
                scope: scope(),
                payload: payload
            ),
            attachmentGeneration: attachmentGeneration
        )
    }
}

private func registerActiveContext(
    _ core: WebInspectorModelContainerCore
) async throws -> WebInspectorModelContextRegistration {
    let registration = try await core.registerContext()
    #expect(registration.claimForMaterialization() == .admitted)
    try await core.activateContext(registration.id)
    return registration
}

@Test
func modelContainerCoreInstallsOneStableInactiveMainContextSeed() async throws {
    let core = WebInspectorModelContainerCore(
        configuredDomains: [.network]
    )
    let seed = core.mainContextSeed
    let sameSeed = core.mainContextSeed
    #expect(seed.id == sameSeed.id)
    #expect(await core.metrics.activeContextRegistrationCount == 0)

    #expect(seed.claimForMaterialization() == .admitted)
    try await core.activateContext(seed.id)
    var iterator = seed.updates.makeAsyncIterator()
    guard case let .initial(revision, snapshot) = await iterator.next() else {
        Issue.record("Expected the seed's synchronous initial state.")
        return
    }
    #expect(revision == 0)
    #expect(snapshot.binding == nil)
    #expect(snapshot.network?.requests.isEmpty == true)

    try await core.activateContext(seed.id)
    #expect(await core.metrics.activeContextRegistrationCount == 1)
}

@Test
func modelContainerCoreUnmaterializedSeedDoesNotBlockDetach() async throws {
    var fixture = ModelContainerCoreFixture()
    let seed = fixture.core.mainContextSeed
    try await fixture.establishAttachment()

    let reset = try #require(try await fixture.core.resetForDetach())
    try await fixture.core.waitForAcknowledgements(
        reset.acknowledgementBarrier
    )
    #expect(await fixture.core.metrics.activeContextRegistrationCount == 0)
    #expect(
        await fixture.core.acknowledgedRevision(for: seed.id)
            == reset.commit.toRevision
    )

    #expect(seed.claimForMaterialization() == .admitted)
    try await fixture.core.activateContext(seed.id)
    #expect(await fixture.core.acknowledgedRevision(for: seed.id) == nil)
    let materializedBarrier = try await fixture.core
        .makeAcknowledgementBarrier(through: reset.commit.toRevision)
    var iterator = seed.updates.makeAsyncIterator()
    guard case let .resetRequired(latestRevision, token) = await iterator.next()
    else {
        Issue.record("Expected the inactive seed to preserve a rebase marker.")
        return
    }
    #expect(latestRevision == reset.commit.toRevision)
    let rebase = try await fixture.core.rebaseContext(token, for: seed.id)
    #expect(rebase.revision == reset.commit.toRevision)
    #expect(rebase.snapshot.binding == nil)
    #expect(rebase.snapshot.network?.requests.isEmpty == true)
    try await fixture.core.acknowledgeContext(
        seed.id,
        through: rebase.revision
    )
    try await fixture.core.waitForAcknowledgements(materializedBarrier)
    try await fixture.core.finishDetach(reset)
}

@Test
func modelContainerCoreClaimedSeedIsCapturedBeforeActorActivation() async throws {
    var fixture = ModelContainerCoreFixture()
    let seed = fixture.core.mainContextSeed
    #expect(seed.claimForMaterialization() == .admitted)
    try await fixture.establishAttachment()

    let reset = try #require(try await fixture.core.resetForDetach())
    #expect(await fixture.core.acknowledgedRevision(for: seed.id) == nil)
    try await fixture.core.activateContext(seed.id)
    var iterator = seed.updates.makeAsyncIterator()
    guard case let .resetRequired(_, token) = await iterator.next() else {
        Issue.record("Expected the claimed seed to rebase at the reset boundary.")
        return
    }
    let rebase = try await fixture.core.rebaseContext(token, for: seed.id)
    try await fixture.core.acknowledgeContext(
        seed.id,
        through: rebase.revision
    )
    try await fixture.core.waitForAcknowledgements(
        reset.acknowledgementBarrier
    )
    try await fixture.core.finishDetach(reset)
}

@Test
func modelContainerCoreCloseWinsAnUnclaimedCustomReservation() async throws {
    let core = WebInspectorModelContainerCore(
        configuredDomains: [.network]
    )
    let reservation = try await core.registerContext()
    #expect(await core.metrics.activeContextRegistrationCount == 0)

    let close = await core.beginClose()
    #expect(reservation.claimForMaterialization() == .closed)
    var iterator = reservation.updates.makeAsyncIterator()
    #expect(await iterator.next() == nil)
    try await core.finishClose(close)
    #expect(await core.isClosed)
}

@Test
func modelContainerCoreClaimWinsCloseAndRequiresSupervisorCompletion() async throws {
    let core = WebInspectorModelContainerCore(
        configuredDomains: [.network]
    )
    let registration = try await core.registerContext()
    #expect(registration.claimForMaterialization() == .admitted)

    let close = await core.beginClose()
    try await core.activateContext(registration.id)
    var iterator = registration.updates.makeAsyncIterator()
    guard case .initial = await iterator.next() else {
        Issue.record("A claimed construction retains its concrete initial state.")
        return
    }
    #expect(await iterator.next() == nil)

    let finishingClose = Task {
        try await core.finishClose(close)
    }
    await Task.yield()
    #expect(await core.isClosed == false)
    #expect(await core.unregisterContext(registration.id))
    try await finishingClose.value
    #expect(await core.isClosed)
}

@Test
func modelContainerCoreCloseWaitsForTheDriverSupervisorAcknowledgement() async throws {
    let core = WebInspectorModelContainerCore(
        configuredDomains: [.network]
    )
    let registration = try await registerActiveContext(core)
    let consumedInitial = AsyncStream<Void>.makeStream()
    let driver = Task {
        var iterator = registration.updates.makeAsyncIterator()
        _ = await iterator.next()
        consumedInitial.continuation.yield()
        return await iterator.next() == nil
    }
    for await _ in consumedInitial.stream.prefix(1) {}

    let close = await core.beginClose()
    let supervisor = Task {
        let driverDidFinish = await driver.value
        let didUnregister = await core.unregisterContext(registration.id)
        return driverDidFinish && didUnregister
    }
    let finishingClose = Task {
        try await core.finishClose(close)
    }

    #expect(await supervisor.value)
    try await finishingClose.value
    #expect(await core.isClosed)
}

@Test
func modelContainerCoreCancelledFinishCloseCanRetryTheSameTransaction() async throws {
    let core = WebInspectorModelContainerCore(
        configuredDomains: [.network]
    )
    let registration = try await registerActiveContext(core)
    var iterator = registration.updates.makeAsyncIterator()
    _ = await iterator.next()
    let close = await core.beginClose()

    let cancelledFinish = Task {
        try await core.finishClose(close)
    }
    await Task.yield()
    cancelledFinish.cancel()
    await #expect(throws: CancellationError.self) {
        try await cancelledFinish.value
    }
    #expect(await core.isClosed == false)

    #expect(await iterator.next() == nil)
    #expect(await core.unregisterContext(registration.id))
    try await core.finishClose(close)
    #expect(await core.isClosed)
}

@Test
func modelContainerCoreCloseDrainsAConcretePendingChangeBeforeTerminal() async throws {
    var fixture = ModelContainerCoreFixture()
    try await fixture.establishAttachment()
    let registration = try await registerActiveContext(fixture.core)
    var iterator = registration.updates.makeAsyncIterator()
    _ = await iterator.next()
    let commit = try #require(
        try await fixture.event(
            .network(
                canonicalRequestWillBeSent(
                    id: "pending-close",
                    url: "https://example.test/pending-close",
                    timestamp: 1
                )
            )
        )
    )

    let close = await fixture.core.beginClose()
    #expect(
        await iterator.next()
            == .changes(
                fromRevision: commit.fromRevision,
                toRevision: commit.toRevision,
                changes: commit.transaction
            )
    )
    #expect(await iterator.next() == nil)
    #expect(await fixture.core.unregisterContext(registration.id))
    try await fixture.core.finishClose(close)
}

@Test
func modelContainerCoreCloseSupersedesAnOutstandingRebase() async throws {
    var fixture = ModelContainerCoreFixture()
    try await fixture.establishAttachment()
    let registration = try await registerActiveContext(fixture.core)
    var iterator = registration.updates.makeAsyncIterator()
    _ = await iterator.next()
    _ = try await fixture.event(
        .network(
            canonicalRequestWillBeSent(
                id: "first-close-rebase",
                url: "https://example.test/first-close-rebase",
                timestamp: 1
            )
        )
    )
    _ = try await fixture.event(
        .network(
            canonicalRequestWillBeSent(
                id: "second-close-rebase",
                url: "https://example.test/second-close-rebase",
                timestamp: 2
            )
        )
    )
    guard case let .resetRequired(_, token) = await iterator.next() else {
        Issue.record("Expected an outstanding rebase token.")
        return
    }

    let close = await fixture.core.beginClose()
    await #expect(throws: WebInspectorModelContainerCoreError.closed) {
        try await fixture.core.rebaseContext(token, for: registration.id)
    }
    #expect(await iterator.next() == nil)
    #expect(await fixture.core.unregisterContext(registration.id))
    try await fixture.core.finishClose(close)
}

@Test
func modelContainerCoreAbandonsAFailedCustomConstruction() async throws {
    let core = WebInspectorModelContainerCore(
        configuredDomains: [.network]
    )
    let registration = try await core.registerContext()

    #expect(await core.abandonContext(registration.id))
    #expect(registration.claimForMaterialization() == .closed)
    var iterator = registration.updates.makeAsyncIterator()
    #expect(await iterator.next() == nil)
    #expect(await core.metrics.activeContextRegistrationCount == 0)
}

@Test
func modelContainerCoreCapturesAnAttachRevisionAcknowledgementBoundary() async throws {
    var fixture = ModelContainerCoreFixture()
    try await fixture.establishAttachment()
    let registration = try await registerActiveContext(fixture.core)
    var iterator = registration.updates.makeAsyncIterator()
    guard case let .initial(initialRevision, _) = await iterator.next() else {
        Issue.record("Expected initial state.")
        return
    }
    try await fixture.core.acknowledgeContext(
        registration.id,
        through: initialRevision
    )

    let commit = try #require(
        try await fixture.event(
            .network(
                canonicalRequestWillBeSent(
                    id: "attach-boundary",
                    url: "https://example.test/attach-boundary",
                    timestamp: 1
                )
            )
        )
    )
    let barrier = try await fixture.core.makeAcknowledgementBarrier(
        through: commit.toRevision
    )
    guard case let .changes(_, appliedRevision, _) = await iterator.next()
    else {
        Issue.record("Expected attach-boundary changes.")
        return
    }
    try await fixture.core.acknowledgeContext(
        registration.id,
        through: appliedRevision
    )
    try await fixture.core.waitForAcknowledgements(barrier)
}

@Test
func modelContainerCoreRegistersTwoContextsWithEqualInitialStateAndDeltas() async throws {
    let fixture = ModelContainerCoreFixture()
    let first = try await registerActiveContext(fixture.core)
    let second = try await registerActiveContext(fixture.core)
    var firstIterator = first.updates.makeAsyncIterator()
    var secondIterator = second.updates.makeAsyncIterator()

    let firstInitial = await firstIterator.next()
    let secondInitial = await secondIterator.next()
    #expect(firstInitial == secondInitial)
    #expect(
        firstInitial
            == .initial(
                revision: 0,
                snapshot: WebInspectorCanonicalModelSnapshot(
                    binding: nil,
                    network: CanonicalNetworkSnapshot(
                        requests: [],
                        entries: []
                    ),
                    DOM: nil,
                    CSS: nil,
                    consoleRuntime: nil
                )
            )
    )
    try await fixture.core.acknowledgeContext(first.id, through: 0)
    try await fixture.core.acknowledgeContext(second.id, through: 0)

    let reset = try await fixture.core.reduce(
        .reset(fixture.pageGeneration),
        attachmentGeneration: fixture.attachmentGeneration
    )
    let firstReset = await firstIterator.next()
    let secondReset = await secondIterator.next()
    #expect(firstReset == secondReset)
    #expect(
        firstReset
            == .changes(
                fromRevision: 0,
                toRevision: 1,
                changes: try #require(reset).transaction
            )
    )
}

@Test
func modelContainerCoreLateRegistrationStartsFromOneAtomicCurrentSnapshot() async throws {
    var fixture = ModelContainerCoreFixture()
    try await fixture.establishAttachment()
    _ = try await fixture.event(
        .network(
            canonicalRequestWillBeSent(
                id: "first",
                url: "https://example.test/first",
                timestamp: 1
            )
        )
    )

    let registration = try await registerActiveContext(fixture.core)
    var iterator = registration.updates.makeAsyncIterator()
    guard case let .initial(initialRevision, snapshot) = await iterator.next()
    else {
        Issue.record("Expected a late owner-atomic initial snapshot.")
        return
    }
    #expect(initialRevision == 3)
    #expect(snapshot.network?.requests.count == 1)

    let second = try #require(
        try await fixture.event(
            .network(
                canonicalRequestWillBeSent(
                    id: "second",
                    url: "https://example.test/second",
                    timestamp: 2
                )
            )
        )
    )
    #expect(
        await iterator.next()
            == .changes(
                fromRevision: initialRevision,
                toRevision: initialRevision + 1,
                changes: second.transaction
            )
    )
}

@Test
func modelContainerCoreRebasesOnlyTheSlowContextOnDemand() async throws {
    var fixture = ModelContainerCoreFixture()
    try await fixture.establishAttachment()
    let fast = try await registerActiveContext(fixture.core)
    let slow = try await registerActiveContext(fixture.core)
    var fastIterator = fast.updates.makeAsyncIterator()
    var slowIterator = slow.updates.makeAsyncIterator()
    _ = await fastIterator.next()
    _ = await slowIterator.next()
    let snapshotBaseline = await fixture.core.metrics.canonicalStore
        .fullSnapshotBuildCount

    let first = try #require(
        try await fixture.event(
            .network(
                canonicalRequestWillBeSent(
                    id: "first",
                    url: "https://example.test/first",
                    timestamp: 1
                )
            )
        )
    )
    #expect(
        await fastIterator.next()
            == .changes(
                fromRevision: first.fromRevision,
                toRevision: first.toRevision,
                changes: first.transaction
            )
    )
    let second = try #require(
        try await fixture.event(
            .network(
                canonicalRequestWillBeSent(
                    id: "second",
                    url: "https://example.test/second",
                    timestamp: 2
                )
            )
        )
    )
    #expect(
        await fastIterator.next()
            == .changes(
                fromRevision: second.fromRevision,
                toRevision: second.toRevision,
                changes: second.transaction
            )
    )
    #expect(
        await fixture.core.metrics.canonicalStore.fullSnapshotBuildCount
            == snapshotBaseline
    )

    guard
        case let .resetRequired(latestRevision, token) =
            await slowIterator.next()
    else {
        Issue.record("Expected only the slow context to request a rebase.")
        return
    }
    #expect(latestRevision == second.toRevision)
    #expect(
        await fixture.core.metrics.canonicalStore.fullSnapshotBuildCount
            == snapshotBaseline
    )
    await #expect(
        throws: WebInspectorModelContainerCoreError.rebaseTokenMismatch(
            fast.id
        )
    ) {
        try await fixture.core.rebaseContext(token, for: fast.id)
    }
    #expect(
        await fixture.core.metrics.canonicalStore.fullSnapshotBuildCount
            == snapshotBaseline
    )
    let rebase = try await fixture.core.rebaseContext(
        token,
        for: slow.id
    )
    #expect(rebase.disposition == .reset)
    #expect(rebase.revision == second.toRevision)
    #expect(rebase.snapshot.network?.requests.count == 2)
    #expect(
        await fixture.core.metrics.canonicalStore.fullSnapshotBuildCount
            == snapshotBaseline + 1
    )
    #expect(
        await fixture.core.metrics.canonicalStore.onDemandSnapshotBuildCount
            == 1
    )
    await #expect(
        throws: WebInspectorModelContainerCoreError.rebase(.staleToken)
    ) {
        try await fixture.core.rebaseContext(token, for: slow.id)
    }
    #expect(
        await fixture.core.metrics.canonicalStore.fullSnapshotBuildCount
            == snapshotBaseline + 1
    )
    #expect(
        await fixture.core.metrics.canonicalStore.onDemandSnapshotBuildCount
            == 1
    )
}

@Test
func modelContainerCoreClosingOneContextLeavesItsSiblingActive() async throws {
    var fixture = ModelContainerCoreFixture()
    try await fixture.establishAttachment()
    let closed = try await registerActiveContext(fixture.core)
    let remaining = try await registerActiveContext(fixture.core)
    var closedIterator = closed.updates.makeAsyncIterator()
    var remainingIterator = remaining.updates.makeAsyncIterator()
    _ = await closedIterator.next()
    _ = await remainingIterator.next()

    #expect(try await fixture.core.beginContextClose(closed.id))
    #expect(await closedIterator.next() == nil)
    #expect(await fixture.core.unregisterContext(closed.id))
    let commit = try #require(
        try await fixture.event(
            .network(
                canonicalRequestWillBeSent(
                    id: "remaining",
                    url: "https://example.test/remaining",
                    timestamp: 1
                )
            )
        )
    )
    #expect(
        await remainingIterator.next()
            == .changes(
                fromRevision: commit.fromRevision,
                toRevision: commit.toRevision,
                changes: commit.transaction
            )
    )
    #expect(await fixture.core.metrics.activeContextRegistrationCount == 1)
}

@Test
func modelContainerCoreDetachWaitsForAnIndependentlyClosingContext() async throws {
    var fixture = ModelContainerCoreFixture()
    try await fixture.establishAttachment()
    let registration = try await registerActiveContext(fixture.core)
    var iterator = registration.updates.makeAsyncIterator()
    guard case let .initial(revision, _) = await iterator.next() else {
        Issue.record("Expected initial state.")
        return
    }
    try await fixture.core.acknowledgeContext(
        registration.id,
        through: revision
    )
    #expect(try await fixture.core.beginContextClose(registration.id))
    #expect(await iterator.next() == nil)

    let reset = try #require(try await fixture.core.resetForDetach())
    let core = fixture.core
    let barrier = reset.acknowledgementBarrier
    let cancelledWait = Task {
        try await core.waitForAcknowledgements(barrier)
    }
    await Task.yield()
    cancelledWait.cancel()
    await #expect(throws: CancellationError.self) {
        try await cancelledWait.value
    }

    #expect(await core.unregisterContext(registration.id))
    try await core.waitForAcknowledgements(barrier)
    try await core.finishDetach(reset)
}

@Test
func modelContainerCoreDetachBlocksMutationAndExcludesLaterContext() async throws {
    var fixture = ModelContainerCoreFixture()
    try await fixture.establishAttachment()
    let existing = try await registerActiveContext(fixture.core)
    var existingIterator = existing.updates.makeAsyncIterator()
    _ = await existingIterator.next()

    let reset = try #require(try await fixture.core.resetForDetach())
    #expect(try await fixture.core.resetForDetach() == reset)
    await #expect(throws: WebInspectorModelContainerCoreError.detachInProgress) {
        try await fixture.beginAttachment(attachment: 2)
    }

    let later = try await registerActiveContext(fixture.core)
    var laterIterator = later.updates.makeAsyncIterator()
    guard
        case let .initial(laterRevision, laterSnapshot) =
            await laterIterator.next()
    else {
        Issue.record("Expected a post-reset empty initial snapshot.")
        return
    }
    #expect(laterRevision == reset.commit.toRevision)
    #expect(laterSnapshot.binding == nil)
    #expect(laterSnapshot.network?.requests.isEmpty == true)

    guard
        case let .changes(_, resetRevision, _) =
            await existingIterator.next()
    else {
        Issue.record("Expected the captured detach reset.")
        return
    }
    try await fixture.core.acknowledgeContext(
        existing.id,
        through: resetRevision
    )
    try await fixture.core.finishDetach(reset)
    try await fixture.core.finishDetach(reset)

    try await fixture.beginAttachment(attachment: 2)
    guard case .changes = await existingIterator.next(),
        case .changes = await laterIterator.next()
    else {
        Issue.record("Both contexts must continue into the new attachment.")
        return
    }
}

@Test
func modelContainerCoreDetachRejectsAForeignTransaction() async throws {
    var first = ModelContainerCoreFixture()
    var second = ModelContainerCoreFixture()
    try await first.establishAttachment()
    try await second.establishAttachment()
    let firstReset = try #require(try await first.core.resetForDetach())
    let secondReset = try #require(try await second.core.resetForDetach())

    await #expect(
        throws: WebInspectorModelContainerCoreError
            .detachTransactionMismatch
    ) {
        try await first.core.finishDetach(secondReset)
    }
    try await first.core.finishDetach(firstReset)
    try await second.core.finishDetach(secondReset)
}

@Test
func modelContainerCoreTerminalCloseWinsAnInFlightDetach() async throws {
    var fixture = ModelContainerCoreFixture()
    try await fixture.establishAttachment()
    let registration = try await registerActiveContext(fixture.core)
    var iterator = registration.updates.makeAsyncIterator()
    _ = await iterator.next()
    let reset = try #require(try await fixture.core.resetForDetach())

    let close = await fixture.core.beginClose()
    guard case .changes = await iterator.next() else {
        Issue.record("A concrete detach reset remains drainable before close.")
        return
    }
    #expect(await iterator.next() == nil)
    #expect(await fixture.core.unregisterContext(registration.id))
    try await fixture.core.finishClose(close)
    #expect(await fixture.core.isClosed)
    try await fixture.core.finishDetach(reset)
    await #expect(throws: WebInspectorModelContainerCoreError.closed) {
        try await fixture.core.registerContext()
    }
}

@Test
func modelContainerCoreDetachPublishesEmptyResetAndKeepsStreamsAlive() async throws {
    var fixture = ModelContainerCoreFixture()
    try await fixture.establishAttachment()
    _ = try await fixture.event(
        .network(
            canonicalRequestWillBeSent(
                id: "old",
                url: "https://example.test/old",
                timestamp: 1
            )
        )
    )
    let first = try await registerActiveContext(fixture.core)
    let second = try await registerActiveContext(fixture.core)
    var firstIterator = first.updates.makeAsyncIterator()
    var secondIterator = second.updates.makeAsyncIterator()
    _ = await firstIterator.next()
    _ = await secondIterator.next()
    let snapshotBaseline = await fixture.core.metrics.canonicalStore
        .fullSnapshotBuildCount

    let reset = try #require(try await fixture.core.resetForDetach())
    #expect(
        await fixture.core.metrics.canonicalStore.fullSnapshotBuildCount
            == snapshotBaseline + 1
    )
    #expect(
        await fixture.core.metrics.canonicalStore.resetSnapshotBuildCount
            == 1
    )
    guard
        case let .changes(firstFrom, firstTo, firstTransaction) =
            await firstIterator.next(),
        case let .changes(secondFrom, secondTo, secondTransaction) =
            await secondIterator.next()
    else {
        Issue.record("Expected one contiguous detach reset per context.")
        return
    }
    #expect(firstFrom == reset.commit.fromRevision)
    #expect(firstTo == reset.commit.toRevision)
    #expect(secondFrom == firstFrom)
    #expect(secondTo == firstTo)
    #expect(firstTransaction == secondTransaction)
    #expect(firstTransaction.resetSnapshot?.binding == nil)
    #expect(firstTransaction.resetSnapshot?.network?.requests.isEmpty == true)
    try await fixture.core.acknowledgeContext(first.id, through: firstTo)
    try await fixture.core.acknowledgeContext(second.id, through: secondTo)
    try await fixture.core.waitForAcknowledgements(
        reset.acknowledgementBarrier
    )
    try await fixture.core.finishDetach(reset)

    try await fixture.beginAttachment(attachment: 2)
    guard case .changes = await firstIterator.next(),
        case .changes = await secondIterator.next()
    else {
        Issue.record("A detach reset must not terminate context streams.")
        return
    }
    _ = try await fixture.publishTargetSnapshot()
    guard case .changes = await firstIterator.next(),
        case .changes = await secondIterator.next()
    else {
        Issue.record("A reattached target snapshot must remain contiguous.")
        return
    }
    #expect(
        await fixture.core.metrics.canonicalStore.fullSnapshotBuildCount
            == snapshotBaseline + 1
    )
}

@Test
func modelContainerCoreUnregistrationSatisfiesDetachAcknowledgement() async throws {
    var fixture = ModelContainerCoreFixture()
    try await fixture.establishAttachment()
    let applied = try await registerActiveContext(fixture.core)
    let closed = try await registerActiveContext(fixture.core)
    var appliedIterator = applied.updates.makeAsyncIterator()
    var closedIterator = closed.updates.makeAsyncIterator()
    _ = await appliedIterator.next()
    _ = await closedIterator.next()

    let reset = try #require(try await fixture.core.resetForDetach())
    guard case let .changes(_, revision, _) = await appliedIterator.next()
    else {
        Issue.record("Expected detach reset.")
        return
    }
    try await fixture.core.acknowledgeContext(applied.id, through: revision)
    #expect(await fixture.core.unregisterContext(closed.id))
    try await fixture.core.waitForAcknowledgements(
        reset.acknowledgementBarrier
    )
    try await fixture.core.finishDetach(reset)
    #expect(await closedIterator.next() == nil)
}

@Test
func modelContainerCoreCancelledFinishDetachCanBeRetried() async throws {
    var fixture = ModelContainerCoreFixture()
    try await fixture.establishAttachment()
    let registration = try await registerActiveContext(fixture.core)
    var iterator = registration.updates.makeAsyncIterator()
    _ = await iterator.next()

    let reset = try #require(try await fixture.core.resetForDetach())
    guard case let .changes(_, revision, _) = await iterator.next() else {
        Issue.record("Expected detach reset.")
        return
    }
    let core = fixture.core
    let cancelledWait = Task {
        try await core.finishDetach(reset)
    }
    await Task.yield()
    cancelledWait.cancel()
    await #expect(throws: CancellationError.self) {
        try await cancelledWait.value
    }

    try await core.acknowledgeContext(
        registration.id,
        through: revision
    )
    try await core.finishDetach(reset)
}

@Test
func modelContainerCoreTerminalCloseFinishesStreamsAndRejectsNewWork() async throws {
    var fixture = ModelContainerCoreFixture()
    try await fixture.establishAttachment()
    let registration = try await registerActiveContext(fixture.core)
    let pendingInitial = try await registerActiveContext(fixture.core)
    var iterator = registration.updates.makeAsyncIterator()
    var pendingInitialIterator = pendingInitial.updates.makeAsyncIterator()
    _ = await iterator.next()

    let core = fixture.core
    let mainSeedID = core.mainContextSeed.id
    let close = await core.beginClose()
    #expect(await core.beginClose() == close)
    #expect(await core.isClosed == false)
    #expect(core.mainContextSeed.claimForMaterialization() == .closed)
    await #expect(throws: WebInspectorModelContainerCoreError.closed) {
        try await core.registerContext()
    }
    await #expect(throws: WebInspectorModelContainerCoreError.closed) {
        try await core.activateContext(mainSeedID)
    }
    #expect(await iterator.next() == nil)
    guard case .initial = await pendingInitialIterator.next() else {
        Issue.record("A concrete pending initial state must remain drainable.")
        return
    }
    #expect(await pendingInitialIterator.next() == nil)
    let finishingClose = Task {
        try await core.finishClose(close)
    }
    await Task.yield()
    #expect(await core.isClosed == false)
    #expect(await core.unregisterContext(registration.id))
    #expect(await core.unregisterContext(pendingInitial.id))
    try await finishingClose.value
    try await fixture.core.finishClose(close)
    #expect(await fixture.core.isClosed)
    #expect(await fixture.core.metrics.activeContextRegistrationCount == 0)
    var mainIterator = fixture.core.mainContextSeed.updates.makeAsyncIterator()
    #expect(await mainIterator.next() == nil)
    await #expect(throws: WebInspectorModelContainerCoreError.closed) {
        try await fixture.core.registerContext()
    }
    await #expect(throws: WebInspectorModelContainerCoreError.closed) {
        try await fixture.event(
            .network(
                .unknown(
                    RawEvent(domain: "Network", method: "closed")
                )
            )
        )
    }
    await #expect(throws: WebInspectorModelContainerCoreError.closed) {
        try await fixture.core.resetForDetach()
    }
}

@Test
func modelContainerCoreStrongExceptionLeavesRevisionAndPublicationContiguous() async throws {
    var fixture = ModelContainerCoreFixture()
    try await fixture.establishAttachment()
    let registration = try await registerActiveContext(fixture.core)
    var iterator = registration.updates.makeAsyncIterator()
    _ = await iterator.next()
    let before = await fixture.core.metrics

    await #expect(throws: WebInspectorModelContainerCoreError.self) {
        try await fixture.core.reduce(
            .event(
                sequence: 0,
                scope: fixture.scope(),
                payload: .network(
                    canonicalRequestWillBeSent(
                        id: "stale",
                        url: "https://example.test/stale",
                        timestamp: 1
                    )
                )
            ),
            attachmentGeneration: fixture.attachmentGeneration
        )
    }
    #expect(await fixture.core.currentRevision == before.revision)
    #expect(
        await fixture.core.metrics.core.publishedTransactionCount
            == before.core.publishedTransactionCount
    )

    let valid = try #require(
        try await fixture.event(
            .network(
                canonicalRequestWillBeSent(
                    id: "valid",
                    url: "https://example.test/valid",
                    timestamp: 1
                )
            )
        )
    )
    #expect(
        await iterator.next()
            == .changes(
                fromRevision: before.revision,
                toRevision: before.revision + 1,
                changes: valid.transaction
            )
    )
}

@Test
func modelContainerCoreTenThousandNoOpsDoNotPublishOrBuildSnapshots() async throws {
    var fixture = ModelContainerCoreFixture()
    try await fixture.establishAttachment()
    let registration = try await registerActiveContext(fixture.core)
    var iterator = registration.updates.makeAsyncIterator()
    _ = await iterator.next()
    let baseline = await fixture.core.metrics

    for index in 0..<10_000 {
        let commit = try await fixture.event(
            .network(
                .unknown(
                    RawEvent(
                        domain: "Network",
                        method: "ignored\(index)"
                    )
                )
            )
        )
        #expect(commit == nil)
    }

    let after = await fixture.core.metrics
    #expect(after.revision == baseline.revision)
    #expect(
        after.core.publishedTransactionCount
            == baseline.core.publishedTransactionCount
    )
    #expect(
        after.core.ignoredEmptyTransactionCount
            == baseline.core.ignoredEmptyTransactionCount + 10_000
    )
    #expect(
        after.canonicalStore.fullSnapshotBuildCount
            == baseline.canonicalStore.fullSnapshotBuildCount
    )
    #expect(
        after.canonicalStore.bindingEpochMapMutationCount
            == baseline.canonicalStore.bindingEpochMapMutationCount
    )
}

@Test
func modelContainerCoreFastSubscriberConsumesTenThousandDeltasWithoutSnapshots() async throws {
    var fixture = ModelContainerCoreFixture()
    try await fixture.establishAttachment()
    _ = try await fixture.event(
        .network(
            canonicalRequestWillBeSent(
                id: "request",
                url: "https://example.test/stream",
                timestamp: 1
            )
        )
    )
    let registration = try await registerActiveContext(fixture.core)
    var iterator = registration.updates.makeAsyncIterator()
    _ = await iterator.next()
    let baseline = await fixture.core.metrics

    for index in 0..<10_000 {
        let commit = try #require(
            try await fixture.event(
                .network(
                    .dataReceived(
                        id: Network.Request.ID("request"),
                        dataLength: 1,
                        encodedDataLength: 1,
                        timestamp: Double(index + 2)
                    )
                )
            )
        )
        guard
            case let .changes(fromRevision, toRevision, _) =
                await iterator.next()
        else {
            Issue.record("A fast context must receive a contiguous delta.")
            return
        }
        #expect(fromRevision == commit.fromRevision)
        #expect(toRevision == commit.toRevision)
    }

    let after = await fixture.core.metrics
    #expect(after.revision == baseline.revision + 10_000)
    #expect(
        after.canonicalStore.fullSnapshotBuildCount
            == baseline.canonicalStore.fullSnapshotBuildCount
    )
    #expect(
        after.canonicalStore.onDemandSnapshotBuildCount
            == baseline.canonicalStore.onDemandSnapshotBuildCount
    )
}

#if os(macOS)
    @Test
    func modelContainerCoreSeedRejectsASecondMaterializationOwner() async {
        await #expect(processExitsWith: .failure) {
            let core = WebInspectorModelContainerCore(
                configuredDomains: [.network]
            )
            let seed = core.mainContextSeed
            _ = seed.claimForMaterialization()
            _ = seed.claimForMaterialization()
        }
    }

    @Test
    func modelContainerCoreRegistrationSequenceRejectsASecondIterator() async {
        await #expect(processExitsWith: .failure) {
            let core = WebInspectorModelContainerCore(
                configuredDomains: [.network]
            )
            let registration = try await core.registerContext()
            let copy = registration.updates
            _ = registration.updates.makeAsyncIterator()
            _ = copy.makeAsyncIterator()
        }
    }
#endif
