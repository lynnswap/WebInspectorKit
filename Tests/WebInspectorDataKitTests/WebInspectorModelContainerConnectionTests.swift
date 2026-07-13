import Synchronization
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import WebInspectorTestSupport

private struct ModelContainerProxyRuntime {
    let runtime: WebInspectorProxyTestRuntime
    let commandTask: Task<Void, Never>

    static func start() async throws -> ModelContainerProxyRuntime {
        let runtime = try await WebInspectorProxyTestRuntime.start()
        let peer = runtime.peer
        let commandTask = Task.detached {
            do {
                while !Task.isCancelled {
                    let command = try await peer.commands.next()
                    try await peer.reply(to: command)
                }
            } catch {
                // Connection close and explicit cancellation are terminal.
            }
        }
        return ModelContainerProxyRuntime(
            runtime: runtime,
            commandTask: commandTask
        )
    }

    func finish() async {
        await runtime.close()
        commandTask.cancel()
        await commandTask.value
    }
}

@Test
func modelContainerOwnsAttachDetachAndTerminalClose() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )
    var states = container.stateUpdates.makeAsyncIterator()
    let proxyRuntime = try await ModelContainerProxyRuntime.start()

    #expect(await states.next() == .detached)
    try await container.attach(owning: proxyRuntime.runtime.proxy)
    #expect(container.state == .attached)
    #expect(await states.next() == .attached)

    await container.detach()
    #expect(container.state == .detached)
    #expect(await states.next() == .detached)

    await container.close()
    #expect(container.state == .closed)
    #expect(await states.next() == .closed)
    #expect(await states.next() == nil)

    var late = container.stateUpdates.makeAsyncIterator()
    #expect(await late.next() == .closed)
    #expect(await late.next() == nil)
    await proxyRuntime.finish()
}

@MainActor
@Test
func synchronizationCursorCompletesConcurrentAndLateWaitersAfterContextACK()
    async throws
{
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )
    let context = container.mainContext
    let proxyRuntime = try await ModelContainerProxyRuntime.start()
    try await container.attach(owning: proxyRuntime.runtime.proxy)
    let checkpoint = try await container.synchronizationCheckpoint()

    let first = Task {
        try await container.waitForSynchronization(after: checkpoint)
    }
    let second = Task {
        try await container.waitForSynchronization(after: checkpoint)
    }
    await waitForSynchronizationWaiterCount(2, in: container.core)

    try await commitReplacementPage(
        using: proxyRuntime.runtime.peer,
        oldTargetID: "page-main",
        newTargetID: "page-replacement"
    )
    let firstCursor = try await first.value
    let secondCursor = try await second.value
    let synchronizedRevision = await container.core.currentRevision

    #expect(firstCursor == secondCursor)
    #expect(firstCursor != checkpoint)
    #expect(
        context.appliedContainerRevisionForTesting
            == synchronizedRevision
    )
    #expect(
        try await container.waitForSynchronization(after: checkpoint)
            == firstCursor
    )

    await container.close()
    await proxyRuntime.finish()
}

@Test
func synchronizationCursorDoesNotAdvanceBeforeEveryContextAcknowledges()
    async throws
{
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )
    let core = container.core
    let proxyRuntime = try await ModelContainerProxyRuntime.start()
    try await container.attach(owning: proxyRuntime.runtime.proxy)

    let registration = try await core.registerContext()
    #expect(registration.claimForMaterialization() == .admitted)
    try await core.activateContext(registration.id)
    var updates = registration.updates.makeAsyncIterator()
    guard case let .initial(initialRevision, _) = await updates.next() else {
        Issue.record("Expected current initial state.")
        return
    }
    try await core.acknowledgeContext(
        registration.id,
        through: initialRevision
    )

    let acknowledgementGate = WebInspectorTestGate()
    let didReceiveReplacement = AsyncStream<Void>.makeStream()
    let didBlock = Mutex(false)
    let contextDriver = Task.detached {
        while let update = await updates.next() {
            let revision: UInt64
            switch update {
            case let .initial(currentRevision, _):
                revision = currentRevision
            case let .changes(_, toRevision, _):
                revision = toRevision
            case let .resetRequired(_, token):
                let rebase = try await core.rebaseContext(
                    token,
                    for: registration.id
                )
                revision = rebase.revision
            }
            let shouldBlock = didBlock.withLock { didBlock in
                guard revision > initialRevision, !didBlock else {
                    return false
                }
                didBlock = true
                return true
            }
            if shouldBlock {
                didReceiveReplacement.continuation.yield()
                await acknowledgementGate.waiter.wait()
            }
            try await core.acknowledgeContext(
                registration.id,
                through: revision
            )
        }
    }
    var replacementIterator = didReceiveReplacement.stream.makeAsyncIterator()
    let checkpoint = try await container.synchronizationCheckpoint()
    let didFinishWait = Mutex(false)
    let wait = Task {
        let cursor = try await container.waitForSynchronization(
            after: checkpoint
        )
        didFinishWait.withLock { $0 = true }
        return cursor
    }

    try await commitReplacementPage(
        using: proxyRuntime.runtime.peer,
        oldTargetID: "page-main",
        newTargetID: "page-replacement"
    )
    _ = await replacementIterator.next()
    #expect(!didFinishWait.withLock { $0 })

    acknowledgementGate.open()
    #expect(try await wait.value != checkpoint)
    _ = await core.unregisterContext(registration.id)
    try await contextDriver.value
    didReceiveReplacement.continuation.finish()

    await container.close()
    await proxyRuntime.finish()
}

@MainActor
@Test
func synchronizationWaitCancellationRemovesOnlyThatWaiter() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )
    let proxyRuntime = try await ModelContainerProxyRuntime.start()
    try await container.attach(owning: proxyRuntime.runtime.proxy)
    let checkpoint = try await container.synchronizationCheckpoint()
    let cancelledWait = Task {
        try await container.waitForSynchronization(after: checkpoint)
    }
    let survivingWait = Task {
        try await container.waitForSynchronization(after: checkpoint)
    }
    await waitForSynchronizationWaiterCount(2, in: container.core)

    cancelledWait.cancel()
    await #expect(throws: CancellationError.self) {
        try await cancelledWait.value
    }
    await waitForSynchronizationWaiterCount(1, in: container.core)
    #expect(container.state == .attached)

    try await commitReplacementPage(
        using: proxyRuntime.runtime.peer,
        oldTargetID: "page-main",
        newTargetID: "page-replacement"
    )
    #expect(try await survivingWait.value != checkpoint)
    #expect(await container.core.synchronizationWaiterCountForTesting == 0)

    await container.close()
    await proxyRuntime.finish()
}

@MainActor
@Test
func synchronizationWaitersFailOnDetachCloseAndFeedTerminal() async throws {
    do {
        let container = WebInspectorModelContainer(
            configuration: .init(domains: [])
        )
        let proxyRuntime = try await ModelContainerProxyRuntime.start()
        try await container.attach(owning: proxyRuntime.runtime.proxy)
        let checkpoint = try await container.synchronizationCheckpoint()
        let wait = Task {
            try await container.waitForSynchronization(after: checkpoint)
        }
        await waitForSynchronizationWaiterCount(1, in: container.core)

        await container.detach()
        await #expect(
            throws: WebInspectorModelContainerCoreError.detached
        ) {
            try await wait.value
        }
        await container.close()
        await proxyRuntime.finish()
    }

    do {
        let container = WebInspectorModelContainer(
            configuration: .init(domains: [])
        )
        let proxyRuntime = try await ModelContainerProxyRuntime.start()
        try await container.attach(owning: proxyRuntime.runtime.proxy)
        let checkpoint = try await container.synchronizationCheckpoint()
        let wait = Task {
            try await container.waitForSynchronization(after: checkpoint)
        }
        await waitForSynchronizationWaiterCount(1, in: container.core)

        await container.close()
        await #expect(
            throws: WebInspectorModelContainerCoreError.closed
        ) {
            try await wait.value
        }
        await proxyRuntime.finish()
    }

    do {
        let container = WebInspectorModelContainer(
            configuration: .init(domains: [])
        )
        let proxyRuntime = try await ModelContainerProxyRuntime.start()
        try await container.attach(owning: proxyRuntime.runtime.proxy)
        let checkpoint = try await container.synchronizationCheckpoint()
        let wait = Task {
            try await container.waitForSynchronization(after: checkpoint)
        }
        await waitForSynchronizationWaiterCount(1, in: container.core)

        await proxyRuntime.runtime.peer.failConnection(
            with: "injected terminal synchronization failure"
        )
        do {
            _ = try await wait.value
            Issue.record("Expected the feed-terminal wait to fail.")
        } catch let error as WebInspectorModelContainerCoreError {
            #expect(
                error
                    == .synchronizationFailed(
                        .connection(
                            .transport(
                                "injected terminal synchronization failure"
                            )
                        )
                    )
            )
        } catch {
            Issue.record("Expected a synchronization error, got \(error).")
        }
        await container.close()
        await proxyRuntime.finish()
    }
}

@MainActor
@Test
func synchronizationCheckpointRejectsForeignAndStaleAttachments() async throws {
    let firstContainer = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )
    let firstRuntime = try await ModelContainerProxyRuntime.start()
    try await firstContainer.attach(owning: firstRuntime.runtime.proxy)
    let firstCheckpoint = try await firstContainer
        .synchronizationCheckpoint()

    let foreignContainer = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )
    let foreignRuntime = try await ModelContainerProxyRuntime.start()
    try await foreignContainer.attach(owning: foreignRuntime.runtime.proxy)
    await #expect(
        throws:
            WebInspectorModelContainerCoreError
            .foreignSynchronizationCheckpoint
    ) {
        try await foreignContainer.waitForSynchronization(
            after: firstCheckpoint
        )
    }

    let replacementRuntime = try await ModelContainerProxyRuntime.start()
    try await firstContainer.attach(owning: replacementRuntime.runtime.proxy)
    do {
        _ = try await firstContainer.waitForSynchronization(
            after: firstCheckpoint
        )
        Issue.record("Expected the retired attachment checkpoint to be stale.")
    } catch let error as WebInspectorModelContainerCoreError {
        guard case let .staleSynchronizationGeneration(expected, actual) = error
        else {
            Issue.record("Expected a stale generation error, got \(error).")
            return
        }
        #expect(expected != actual)
    } catch {
        Issue.record("Expected a synchronization error, got \(error).")
    }

    await firstContainer.close()
    await foreignContainer.close()
    await firstRuntime.finish()
    await foreignRuntime.finish()
    await replacementRuntime.finish()
}

@Test
func concurrentAttachKeepsOnlyTheNewestIntentAndClosesTheOlderProxy()
    async throws
{
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )
    let first = try await WebInspectorProxyTestRuntime.start()
    let firstAttach = Task {
        try await container.attach(owning: first.proxy)
    }
    let firstPageEnable = try await first.peer.commands.next()
    #expect(firstPageEnable.method == "Page.enable")
    let firstCleanupResponder = Task.detached {
        do {
            while !Task.isCancelled {
                let command = try await first.peer.commands.next()
                try await first.peer.reply(to: command)
            }
        } catch {
            // The superseded connection closes this command channel.
        }
    }

    let second = try await ModelContainerProxyRuntime.start()
    let secondAttach = Task {
        try await container.attach(owning: second.runtime.proxy)
    }

    await #expect(
        throws: WebInspectorModelContainer.Failure.attachmentSuperseded
    ) {
        try await firstAttach.value
    }
    try await secondAttach.value
    #expect(container.state == .attached)

    await #expect(throws: WebInspectorTestPeerError.staleCommand) {
        try await first.peer.reply(to: firstPageEnable)
    }
    await container.close()
    await first.close()
    firstCleanupResponder.cancel()
    await firstCleanupResponder.value
    await second.finish()
}

@Test
func callerCancellationBeforePromotionClosesTheCandidateAndReturnsCancellation()
    async throws
{
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let attach = Task {
        try await container.attach(owning: runtime.proxy)
    }
    let pageEnable = try await runtime.peer.commands.next()
    #expect(pageEnable.method == "Page.enable")

    attach.cancel()
    await #expect(throws: CancellationError.self) {
        try await attach.value
    }
    #expect(container.state == .detached)
    await #expect(throws: WebInspectorTestPeerError.staleCommand) {
        try await runtime.peer.reply(to: pageEnable)
    }

    await container.close()
    await runtime.close()
}

@Test
func supersededNativeSuccessClosesItsAttemptOwnedProxyExactlyOnce() async throws {
    let closeCount = Mutex(0)
    let proxy = WebInspectorProxy(
        localStateOnly: (),
        closeConnection: {
            closeCount.withLock { $0 += 1 }
        }
    )
    let core = WebInspectorModelContainerCore(
        configuredDomains: [],
        modelSchemaRegistry: WebInspectorModelSchemaRegistry([])
    )
    let first = try await core.reserveAttachmentAttempt()
    let nativeTask = Task<WebInspectorProxy, any Error> {
        proxy
    }
    await core.installNativeProxyCreationTask(nativeTask, for: first)

    let second = try await core.reserveAttachmentAttempt()
    await #expect(
        throws: WebInspectorModelContainer.Failure.attachmentSuperseded
    ) {
        try await core.completeAttachmentAttempt(first)
    }
    #expect(closeCount.withLock { $0 } == 1)

    let failedNativeTask = Task<WebInspectorProxy, any Error> {
        throw CancellationError()
    }
    await core.installNativeProxyCreationTask(
        failedNativeTask,
        for: second
    )
    await #expect(throws: WebInspectorModelContainer.Failure.self) {
        try await core.completeAttachmentAttempt(second)
    }
    #expect(closeCount.withLock { $0 } == 1)
    await core.closeConnection()
}

@Test
func detachBeforeNativeTaskInstallCancelsBeforeCreationAndWaitsForQuiescence()
    async throws
{
    let core = WebInspectorModelContainerCore(
        configuredDomains: [],
        modelSchemaRegistry: WebInspectorModelSchemaRegistry([])
    )
    let attempt = try await core.reserveAttachmentAttempt()
    let nativeCreationStarted = Mutex(false)
    let proxy = WebInspectorProxy(localStateOnly: ())
    var states = core.connectionStateUpdates.makeAsyncIterator()
    #expect(await states.next() == .detached)

    let nativeTask = Task<WebInspectorProxy, any Error> {
        try await attempt.waitForNativeCreationStart()
        nativeCreationStarted.withLock { $0 = true }
        return proxy
    }
    let detachFinished = Mutex(false)
    let detachTask = Task {
        await core.detachConnection()
        detachFinished.withLock { $0 = true }
    }
    #expect(await states.next() == .detaching)
    #expect(!detachFinished.withLock { $0 })

    await core.installNativeProxyCreationTask(nativeTask, for: attempt)
    await #expect(
        throws: WebInspectorModelContainer.Failure.attachmentSuperseded
    ) {
        try await core.completeAttachmentAttempt(attempt)
    }
    await detachTask.value

    #expect(!nativeCreationStarted.withLock { $0 })
    #expect(detachFinished.withLock { $0 })
    #expect(core.connectionState == .detached)
    await core.closeConnection()
}

@Test
func closeBeforeNativeTaskInstallCancelsBeforeCreationAndWaitsForQuiescence()
    async throws
{
    let core = WebInspectorModelContainerCore(
        configuredDomains: [],
        modelSchemaRegistry: WebInspectorModelSchemaRegistry([])
    )
    let attempt = try await core.reserveAttachmentAttempt()
    let nativeCreationStarted = Mutex(false)
    let proxy = WebInspectorProxy(localStateOnly: ())
    var states = core.connectionStateUpdates.makeAsyncIterator()
    #expect(await states.next() == .detached)

    let nativeTask = Task<WebInspectorProxy, any Error> {
        try await attempt.waitForNativeCreationStart()
        nativeCreationStarted.withLock { $0 = true }
        return proxy
    }
    let closeFinished = Mutex(false)
    let closeTask = Task {
        await core.closeConnection()
        closeFinished.withLock { $0 = true }
    }
    #expect(await states.next() == .closing)
    #expect(!closeFinished.withLock { $0 })

    await core.installNativeProxyCreationTask(nativeTask, for: attempt)
    await #expect(throws: WebInspectorModelContainer.Failure.closed) {
        try await core.completeAttachmentAttempt(attempt)
    }
    await closeTask.value

    #expect(!nativeCreationStarted.withLock { $0 })
    #expect(closeFinished.withLock { $0 })
    #expect(core.connectionState == .closed)
    #expect(await states.next() == .closed)
    #expect(await states.next() == nil)
}

@Test
func nativeCreationFailureWithoutAnAdoptedProxyPublishesFailedThenDetaches()
    async throws
{
    let core = WebInspectorModelContainerCore(
        configuredDomains: [],
        modelSchemaRegistry: WebInspectorModelSchemaRegistry([])
    )
    let attempt = try await core.reserveAttachmentAttempt()
    let nativeTask = Task<WebInspectorProxy, any Error> {
        try await attempt.waitForNativeCreationStart()
        try await core.beginNativeProxyCreation(for: attempt)
        throw WebInspectorProxyError.attachFailed("native failed")
    }
    await core.installNativeProxyCreationTask(nativeTask, for: attempt)

    await #expect(
        throws: WebInspectorModelContainer.Failure.connection(
            .transport("native failed")
        )
    ) {
        try await core.completeAttachmentAttempt(attempt)
    }
    #expect(
        core.connectionState
            == .failed(.connection(.transport("native failed")))
    )

    await core.detachConnection()
    #expect(core.connectionState == .detached)
    await core.closeConnection()
}

@Test
func nativeCreationFailurePreservesThePreviouslyAdoptedAttachment()
    async throws
{
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )
    let proxyRuntime = try await ModelContainerProxyRuntime.start()
    try await container.attach(owning: proxyRuntime.runtime.proxy)
    let activeCheckpoint = try await container.synchronizationCheckpoint()

    let attempt = try await container.core.reserveAttachmentAttempt()
    let creationStarted = AsyncStream<Void>.makeStream()
    var creationStartedIterator = creationStarted.stream.makeAsyncIterator()
    let failureGate = WebInspectorTestGate()
    let nativeTask = Task<WebInspectorProxy, any Error> {
        try await attempt.waitForNativeCreationStart()
        try await container.core.beginNativeProxyCreation(for: attempt)
        creationStarted.continuation.yield()
        await failureGate.waiter.wait()
        throw WebInspectorProxyError.attachFailed("replacement failed")
    }
    await container.core.installNativeProxyCreationTask(
        nativeTask,
        for: attempt
    )
    let replacement = Task {
        try await container.core.completeAttachmentAttempt(attempt)
    }
    _ = await creationStartedIterator.next()
    #expect(
        try await container.synchronizationCheckpoint()
            == activeCheckpoint
    )
    failureGate.open()
    await #expect(
        throws: WebInspectorModelContainer.Failure.connection(
            .transport("replacement failed")
        )
    ) {
        try await replacement.value
    }
    creationStarted.continuation.finish()
    #expect(container.state == .attached)
    #expect(
        try await container.synchronizationCheckpoint()
            == activeCheckpoint
    )

    await container.close()
    await proxyRuntime.finish()
}

@Test
func modelFeedBootstrapFailurePublishesFailedAndCanConvergeToDetached()
    async throws
{
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [.network])
    )
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let peer = runtime.peer
    let commandTask = Task.detached {
        do {
            while !Task.isCancelled {
                let command = try await peer.commands.next()
                if command.method == "Network.enable" {
                    try await peer.fail(
                        command,
                        message: "network bootstrap failed"
                    )
                } else {
                    try await peer.reply(to: command)
                }
            }
        } catch {
            // Failed adoption closes the connection.
        }
    }

    do {
        try await container.attach(owning: runtime.proxy)
        Issue.record("Expected Network bootstrap failure.")
    } catch let failure as WebInspectorModelContainer.Failure {
        guard case let .bootstrap(domain, message) = failure else {
            Issue.record("Unexpected attachment failure: \(failure)")
            return
        }
        #expect(domain == .network)
        #expect(message.contains("network bootstrap failed"))
    }
    guard case let .failed(failure) = container.state else {
        Issue.record("Expected failed Container state.")
        return
    }
    guard case .bootstrap(domain: .network, _) = failure else {
        Issue.record("Expected retained Network bootstrap failure.")
        return
    }

    await container.detach()
    #expect(container.state == .detached)
    await container.close()
    await runtime.close()
    commandTask.cancel()
    await commandTask.value
}

@Test
func noOpDetachWaitsForTheCurrentContextRevision() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )
    let registration = try await container.core.registerContext()
    #expect(registration.claimForMaterialization() == .admitted)
    try await container.core.activateContext(registration.id)
    var updates = registration.updates.makeAsyncIterator()
    guard case let .initial(revision, _) = await updates.next() else {
        Issue.record("Expected current initial state.")
        return
    }
    var states = container.stateUpdates.makeAsyncIterator()
    #expect(await states.next() == .detached)
    let detachFinished = Mutex(false)
    let detachTask = Task {
        await container.detach()
        detachFinished.withLock { $0 = true }
    }
    #expect(await states.next() == .detaching)
    #expect(!detachFinished.withLock { $0 })

    try await container.core.acknowledgeContext(
        registration.id,
        through: revision
    )
    await detachTask.value
    #expect(detachFinished.withLock { $0 })
    #expect(container.state == .detached)

    let closeTask = Task { await container.close() }
    _ = await updates.next()
    _ = await container.core.unregisterContext(registration.id)
    await closeTask.value
}

@Test
func terminalCloseWinsAClaimedSeedAndWaitsForItsSupervisor() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )
    let seed = container.core.mainContextSeed
    #expect(seed.claimForMaterialization() == .admitted)
    var states = container.stateUpdates.makeAsyncIterator()
    #expect(await states.next() == .detached)
    let closeFinished = Mutex(false)
    let closeTask = Task {
        await container.close()
        closeFinished.withLock { $0 = true }
    }
    #expect(await states.next() == .closing)
    #expect(!closeFinished.withLock { $0 })

    try await container.core.activateContext(seed.id)
    _ = await container.core.unregisterContext(seed.id)
    await closeTask.value
    #expect(closeFinished.withLock { $0 })
    #expect(container.state == .closed)
}

@Test
func activeFeedTerminalUsesANonSelfAwaitingCleanupPath() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )
    let proxyRuntime = try await ModelContainerProxyRuntime.start()
    try await container.attach(owning: proxyRuntime.runtime.proxy)
    var states = container.stateUpdates.makeAsyncIterator()
    #expect(await states.next() == .attached)

    await proxyRuntime.runtime.peer.failConnection(with: "transport lost")
    guard case .failed = await states.next() else {
        Issue.record("Expected feed-terminal failure state.")
        return
    }
    guard case .failed = container.state else {
        Issue.record("Expected current feed-terminal failure state.")
        return
    }

    await container.detach()
    #expect(container.state == .detached)
    await container.close()
    await proxyRuntime.finish()
}

@Test
func closeDrainsATerminalOperationQueuedBehindItsLifecycleTurn() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )
    let proxyRuntime = try await ModelContainerProxyRuntime.start()
    try await container.attach(owning: proxyRuntime.runtime.proxy)
    let resource = try #require(await container.core.activeAttachment)

    let pending = try await container.core.reserveAttachmentAttempt()
    var states = container.stateUpdates.makeAsyncIterator()
    #expect(await states.next() == .attached)
    let close = Task { await container.close() }
    #expect(await states.next() == .closing)

    let terminal = Task {
        await proxyRuntime.runtime.peer.failConnection(
            with: "terminal while close is queued"
        )
    }
    await resource.supervisorTask?.value

    let nativeTask = Task<WebInspectorProxy, any Error> {
        try await pending.waitForNativeCreationStart()
        try Task.checkCancellation()
        return WebInspectorProxy(localStateOnly: ())
    }
    await container.core.installNativeProxyCreationTask(
        nativeTask,
        for: pending
    )
    await #expect(throws: WebInspectorModelContainer.Failure.closed) {
        try await container.core.completeAttachmentAttempt(pending)
    }

    await close.value
    await terminal.value
    #expect(container.state == .closed)
    #expect(await states.next() == .closed)
    #expect(await states.next() == nil)
    await proxyRuntime.finish()
}

@Test
func pageNavigationKeepsThePublicConnectionStateAttached() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )
    let proxyRuntime = try await ModelContainerProxyRuntime.start()
    try await container.attach(owning: proxyRuntime.runtime.proxy)
    let stateRevision = container.core.connectionStatePublication.revision

    let registration = try await container.core.registerContext()
    #expect(registration.claimForMaterialization() == .admitted)
    try await container.core.activateContext(registration.id)
    var updates = registration.updates.makeAsyncIterator()
    guard case let .initial(initialRevision, _) = await updates.next() else {
        Issue.record("Expected current initial state.")
        return
    }
    try await container.core.acknowledgeContext(
        registration.id,
        through: initialRevision
    )

    try await proxyRuntime.runtime.peer.emitTargetEvent(
        targetID: "page-main",
        method: "Page.frameNavigated",
        parameters: try WebInspectorTestJSONObject(
            json: #"""
                {
                    "frame": {
                        "id": "main-frame",
                        "loaderId": "loader-2",
                        "url": "https://example.test/next",
                        "securityOrigin": "https://example.test",
                        "mimeType": "text/html"
                    }
                }
                """#)
    )
    guard case let .changes(_, revision, _) = await updates.next() else {
        Issue.record("Expected a canonical navigation change.")
        return
    }
    try await container.core.acknowledgeContext(
        registration.id,
        through: revision
    )

    #expect(container.state == .attached)
    #expect(container.core.connectionStatePublication.revision == stateRevision)
    _ = await container.core.unregisterContext(registration.id)
    await container.close()
    await proxyRuntime.finish()
}

@Test
func supersedingWhileInitialStateAwaitsContextAcknowledgementCannotPromoteOldProxy()
    async throws
{
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )
    let core = container.core
    let registration = try await core.registerContext()
    #expect(registration.claimForMaterialization() == .admitted)
    try await core.activateContext(registration.id)

    let acknowledgementGate = WebInspectorTestGate()
    let blocked = AsyncStream<Void>.makeStream()
    let didBlock = Mutex(false)
    let contextDriver = Task.detached {
        var iterator = registration.updates.makeAsyncIterator()
        while let update = await iterator.next() {
            let revision: UInt64
            switch update {
            case let .initial(initialRevision, _):
                revision = initialRevision
            case let .changes(_, toRevision, _):
                revision = toRevision
            case let .resetRequired(_, token):
                let rebase = try await core.rebaseContext(
                    token,
                    for: registration.id
                )
                revision = rebase.revision
            }
            let shouldBlock = didBlock.withLock { didBlock in
                guard revision > 0, !didBlock else {
                    return false
                }
                didBlock = true
                return true
            }
            if shouldBlock {
                blocked.continuation.yield()
                await acknowledgementGate.waiter.wait()
            }
            try await core.acknowledgeContext(
                registration.id,
                through: revision
            )
        }
        _ = await core.unregisterContext(registration.id)
    }
    var blockedIterator = blocked.stream.makeAsyncIterator()

    let first = try await ModelContainerProxyRuntime.start()
    let firstAttach = Task {
        try await container.attach(owning: first.runtime.proxy)
    }
    _ = await blockedIterator.next()
    #expect(container.state == .attaching)

    let second = try await ModelContainerProxyRuntime.start()
    let secondAttach = Task {
        try await container.attach(owning: second.runtime.proxy)
    }
    _ = try? await first.runtime.proxy.waitUntilClosed()
    acknowledgementGate.open()

    await #expect(
        throws: WebInspectorModelContainer.Failure.attachmentSuperseded
    ) {
        try await firstAttach.value
    }
    try await secondAttach.value
    #expect(container.state == .attached)

    await container.close()
    try await contextDriver.value
    blocked.continuation.finish()
    await first.finish()
    await second.finish()
}

@Test
func callerCancellationAfterAttemptPromotionDoesNotInvalidateTheResource() {
    let control = WebInspectorModelContainerAttachmentAttemptControl()
    #expect(control.markPromoted())

    #expect(!control.invalidate(.callerCancelled))
    #expect(control.isPromoted)
    #expect(control.invalidation == nil)
}

@Test
func modelContainerAttachWaitsForCapturedContextAcknowledgement() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )
    let core = container.core
    let registration = try await core.registerContext()
    #expect(registration.claimForMaterialization() == .admitted)
    try await core.activateContext(registration.id)

    let acknowledgementGate = WebInspectorTestGate()
    let receivedUpdate = AsyncStream<Void>.makeStream()
    let didBlock = Mutex(false)
    let contextDriver = Task.detached {
        var iterator = registration.updates.makeAsyncIterator()
        while let update = await iterator.next() {
            let revision: UInt64
            switch update {
            case let .initial(initialRevision, _):
                revision = initialRevision
            case let .changes(_, toRevision, _):
                revision = toRevision
            case let .resetRequired(_, token):
                let rebase = try await core.rebaseContext(
                    token,
                    for: registration.id
                )
                revision = rebase.revision
            }
            let shouldBlock = didBlock.withLock { didBlock in
                guard revision > 0, !didBlock else {
                    return false
                }
                didBlock = true
                return true
            }
            if shouldBlock {
                receivedUpdate.continuation.yield()
                await acknowledgementGate.waiter.wait()
            }
            try await core.acknowledgeContext(
                registration.id,
                through: revision
            )
        }
        _ = await core.unregisterContext(registration.id)
    }
    var receivedIterator = receivedUpdate.stream.makeAsyncIterator()
    let proxyRuntime = try await ModelContainerProxyRuntime.start()
    let attachFinished = Mutex(false)
    let attachTask = Task {
        defer { attachFinished.withLock { $0 = true } }
        try await container.attach(owning: proxyRuntime.runtime.proxy)
    }

    _ = await receivedIterator.next()
    #expect(container.state == .attaching)
    #expect(!attachFinished.withLock { $0 })
    acknowledgementGate.open()
    try await attachTask.value
    #expect(container.state == .attached)

    await container.close()
    try await contextDriver.value
    receivedUpdate.continuation.finish()
    await proxyRuntime.finish()
}

private func commitReplacementPage(
    using peer: WebInspectorTestPeer,
    oldTargetID: String,
    newTargetID: String
) async throws {
    try await peer.createTarget(.init(
        id: newTargetID,
        type: "page",
        frameID: "replacement-frame",
        isProvisional: true
    ))
    try await peer.commitProvisionalTarget(
        from: oldTargetID,
        to: newTargetID
    )
}

private func waitForSynchronizationWaiterCount(
    _ expectedCount: Int,
    in core: WebInspectorModelContainerCore,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    for _ in 0..<1_000 {
        if await core.synchronizationWaiterCountForTesting
            == expectedCount
        {
            return
        }
        await Task.yield()
    }
    Issue.record(
        "The synchronization waiter count did not reach \(expectedCount).",
        sourceLocation: sourceLocation
    )
}
