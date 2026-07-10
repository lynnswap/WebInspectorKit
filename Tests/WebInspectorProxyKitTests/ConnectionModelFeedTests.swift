import Dispatch
import Foundation
import Synchronization
import Testing
import WebInspectorTestSupport
@testable import WebInspectorProxyKit

@Test
func modelTargetSnapshotOrdersMainAndCommittedFramesDeterministically() throws {
    var registry = TransportTargetRegistry()
    _ = registry.recordTargetCreated(modelFeedTargetRecord(
        id: "page-main",
        kind: .page,
        frameID: "main-frame"
    ))
    _ = registry.recordTargetCreated(modelFeedTargetRecord(
        id: "frame-b",
        kind: .frame,
        frameID: "frame-b",
        parentFrameID: "main-frame"
    ))
    _ = registry.recordTargetCreated(modelFeedTargetRecord(
        id: "frame-c",
        kind: .frame,
        frameID: "frame-c",
        parentFrameID: "frame-a"
    ))
    _ = registry.recordTargetCreated(modelFeedTargetRecord(
        id: "frame-a",
        kind: .frame,
        frameID: "frame-a",
        parentFrameID: "main-frame"
    ))
    _ = registry.recordTargetCreated(modelFeedTargetRecord(
        id: "frame-parentless",
        kind: .frame,
        frameID: "frame-parentless"
    ))
    _ = registry.recordTargetCreated(modelFeedTargetRecord(
        id: "frame-provisional",
        kind: .frame,
        frameID: "frame-provisional",
        parentFrameID: "main-frame",
        isProvisional: true
    ))

    let snapshot = try #require(registry.modelTargetSnapshot())

    #expect(snapshot.currentPageID == WebInspectorTarget.ID("page-main"))
    #expect(snapshot.targets.map(\.id) == [
        WebInspectorTarget.ID("page-main"),
        WebInspectorTarget.ID("frame-a"),
        WebInspectorTarget.ID("frame-b"),
        WebInspectorTarget.ID("frame-parentless"),
        WebInspectorTarget.ID("frame-c"),
    ])
}

@Test
func modelFeedAtomicallyStartsWithResetTargetSnapshotAndEmptySynchronization() async throws {
    let core = ConnectionCore(backend: FakeTransportBackend(), responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "frame-b",
        type: "frame",
        frameID: "frame-b",
        parentFrameID: "main-frame"
    ))
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "frame-a",
        type: "frame",
        frameID: "frame-a",
        parentFrameID: "main-frame"
    ))
    let through = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "frame-child",
        type: "frame",
        frameID: "frame-child",
        parentFrameID: "frame-a"
    ))

    let feed = try await core.openModelFeed(configuredDomains: [], capacity: 8)
    var iterator = feed.records.makeAsyncIterator()
    let reset = try await modelFeedRequireReset(iterator.next())
    let snapshot = try await modelFeedRequireTargetSnapshot(iterator.next())
    let synchronization = try await modelFeedRequireSynchronization(iterator.next())

    #expect(reset.rawValue == 1)
    #expect(snapshot.generation == reset)
    #expect(snapshot.through == through)
    #expect(snapshot.snapshot.currentPageID == WebInspectorTarget.ID("page-main"))
    #expect(snapshot.snapshot.targets.map(\.id) == [
        WebInspectorTarget.ID("page-main"),
        WebInspectorTarget.ID("frame-a"),
        WebInspectorTarget.ID("frame-b"),
        WebInspectorTarget.ID("frame-child"),
    ])
    #expect(synchronization.generation == reset)
    #expect(synchronization.through == through)

    try await feed.close()
    #expect(try await iterator.next() == nil)
    await core.close()
}

@Test
func modelFeedUnavailableBindingUsesOneGenerationForResetSnapshotAndSynchronization() async throws {
    let core = ConnectionCore(backend: FakeTransportBackend(), responseTimeout: nil)
    let feed = try await core.openModelFeed(configuredDomains: [], capacity: 8)
    var iterator = feed.records.makeAsyncIterator()

    let reset = try await modelFeedRequireReset(iterator.next())
    #expect(reset.rawValue == 1)

    let through = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let snapshot = try await modelFeedRequireTargetSnapshot(iterator.next())
    let synchronization = try await modelFeedRequireSynchronization(iterator.next())

    #expect(snapshot.generation == reset)
    #expect(snapshot.through == through)
    #expect(synchronization.generation == reset)
    #expect(synchronization.through == through)

    // The snapshot watermark subsumes the Target.targetCreated event that
    // established the binding. Closing immediately must not expose a duplicate
    // lifecycle delta at that same sequence.
    try await feed.close()
    #expect(try await iterator.next() == nil)
    await core.close()
}

@Test
func modelFeedPublishesFutureTargetAndConfiguredDomainEventsAfterSnapshotWatermark() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let openTask = Task {
        try await core.openModelFeed(configuredDomains: [.network], capacity: 8)
    }
    let enable = try await backend.waitForTargetMessage(method: "Network.enable")
    let enableID = try modelFeedMessageID(enable.message)
    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: #"{"id":\#(enableID),"result":{}}"#
    ))
    let feed = try await openTask.value
    var iterator = feed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(iterator.next())
    let initialSnapshot = try await modelFeedRequireTargetSnapshot(iterator.next())
    let initialReplay = try await modelFeedRequireReplayCompletion(iterator.next())
    #expect(initialReplay.generation == initialSnapshot.generation)
    #expect(initialReplay.domain == .network)
    #expect(initialReplay.through == initialSnapshot.through)

    let targetSequence = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "frame-a",
        type: "frame",
        frameID: "frame-a",
        parentFrameID: "main-frame"
    ))
    let targetEvent = try await modelFeedRequireEvent(iterator.next())
    #expect(targetEvent.sequence == targetSequence)
    #expect(targetEvent.sequence > initialSnapshot.through)
    guard case let .target(.targetCreated(target)) = targetEvent.payload else {
        Issue.record("Expected a model targetCreated delta.")
        return
    }
    #expect(target.id == WebInspectorTarget.ID("frame-a"))

    _ = await core.receiveRootMessage(
        #"{"method":"DOM.documentUpdated","params":{}}"#
    )
    let networkSequence = await core.receiveRootMessage(
        #"{"method":"Network.requestWillBeSent","params":{"requestId":"request-1","request":{"url":"https://example.test","method":"GET"},"timestamp":1,"type":"Document"}}"#
    )
    let networkEvent = try await modelFeedRequireEvent(iterator.next())
    #expect(networkEvent.sequence == networkSequence)
    guard case let .network(target, event) = networkEvent.payload else {
        Issue.record("Expected a physical-target Network event.")
        return
    }
    #expect(target.id == WebInspectorTarget.ID("page-main"))
    guard case let .requestWillBeSent(id, _, _, _, _) = event else {
        Issue.record("Expected Network.requestWillBeSent.")
        return
    }
    #expect(id == Network.Request.ID("request-1"))

    let closeTask = Task {
        try await feed.close()
    }
    let disable = try await backend.waitForTargetMessage(method: "Network.disable")
    let disableID = try modelFeedMessageID(disable.message)
    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: #"{"id":\#(disableID),"result":{}}"#
    ))
    try await closeTask.value
    await core.close()
}

@Test
func modelFeedReplayCompletionFollowsEnableTimeEventsBeforeOpenReturns() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let openTask = Task {
        try await core.openModelFeed(configuredDomains: [.network], capacity: 8)
    }
    let enable = try await backend.waitForTargetMessage(method: "Network.enable")

    let replayedEventSequence = await core.receiveRootMessage(
        modelFeedTargetDispatchMessage(
            targetID: "page-main",
            message: #"{"method":"Network.requestWillBeSent","params":{"requestId":"enable-replay","request":{"url":"https://example.test/replay","method":"GET"},"timestamp":1,"type":"Document"}}"#
        )
    )
    await modelFeedRespond(to: enable, core: core)
    let feed = try await openTask.value

    var iterator = feed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(iterator.next())
    let snapshot = try await modelFeedRequireTargetSnapshot(iterator.next())
    let replayedEvent = try await modelFeedRequireEvent(iterator.next())
    let replayCompletion = try await modelFeedRequireReplayCompletion(iterator.next())

    #expect(replayedEvent.sequence == replayedEventSequence)
    #expect(replayedEvent.sequence > snapshot.through)
    guard case let .network(_, event) = replayedEvent.payload,
          case let .requestWillBeSent(id, _, _, _, _) = event else {
        Issue.record("Expected the enable-time Network event before replay completion.")
        return
    }
    #expect(id == Network.Request.ID("enable-replay"))
    #expect(replayCompletion.generation == snapshot.generation)
    #expect(replayCompletion.domain == .network)
    #expect(replayCompletion.through == replayedEventSequence)

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Network.enable"]
    )
    #expect(try await iterator.next() == nil)
    await core.close()
}

@Test
func cleanModelFeedCloseReleasesClaimForAReplacementFeed() async throws {
    let core = ConnectionCore(backend: FakeTransportBackend(), responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))

    let firstFeed = try await core.openModelFeed(configuredDomains: [], capacity: 8)
    var firstIterator = firstFeed.records.makeAsyncIterator()
    _ = try await firstIterator.next()
    _ = try await firstIterator.next()
    _ = try await firstIterator.next()
    try await firstFeed.close()
    #expect(try await firstIterator.next() == nil)

    let replacementFeed = try await core.openModelFeed(configuredDomains: [], capacity: 8)
    var replacementIterator = replacementFeed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(replacementIterator.next())
    _ = try await modelFeedRequireTargetSnapshot(replacementIterator.next())
    _ = try await modelFeedRequireSynchronization(replacementIterator.next())
    try await replacementFeed.close()
    #expect(try await replacementIterator.next() == nil)
    await core.close()
}

@Test
func cancelledIteratorRequiresExplicitFeedCloseBeforeReplacement() async throws {
    let core = ConnectionCore(backend: FakeTransportBackend(), responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let feed = try await core.openModelFeed(configuredDomains: [], capacity: 8)
    let ready = ModelFeedProbe()
    let consumer = Task {
        var iterator = feed.records.makeAsyncIterator()
        _ = try await iterator.next()
        _ = try await iterator.next()
        _ = try await iterator.next()
        await ready.finish()
        return try await iterator.next()
    }
    await ready.waitUntilFinished()

    consumer.cancel()
    await #expect(throws: CancellationError.self) {
        try await consumer.value
    }
    await #expect(throws: ConnectionModelFeedError.alreadyOpen) {
        try await core.openModelFeed(configuredDomains: [], capacity: 8)
    }

    try await feed.close()
    let replacementFeed = try await core.openModelFeed(configuredDomains: [], capacity: 8)
    var replacementIterator = replacementFeed.records.makeAsyncIterator()
    _ = try await replacementIterator.next()
    _ = try await replacementIterator.next()
    _ = try await replacementIterator.next()
    try await replacementFeed.close()
    #expect(try await replacementIterator.next() == nil)
    await core.close()
}

@Test
func admittedDirectCommandPermanentlyPreventsOpeningModelFeed() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    let commandTask = Task {
        try await core.send(ProtocolCommand(
            domain: .target,
            method: "Target.getTargets",
            routing: .root
        ))
    }
    let sentMessage = try await backend.waitForMessage()

    await #expect(throws: ConnectionModelFeedError.connectionAlreadyUsedByDirectConsumer) {
        try await core.openModelFeed(configuredDomains: [], capacity: 8)
    }

    let commandID = try modelFeedMessageID(sentMessage)
    _ = await core.receiveRootMessage(#"{"id":\#(commandID),"result":{}}"#)
    _ = try await commandTask.value
    await #expect(throws: ConnectionModelFeedError.connectionAlreadyUsedByDirectConsumer) {
        try await core.openModelFeed(configuredDomains: [], capacity: 8)
    }
    await core.close()
}

@Test
func modelFeedOverflowPoisonsFeedAndConnectionWithoutSilentDrop() async throws {
    let core = ConnectionCore(backend: FakeTransportBackend(), responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let feed = try await core.openModelFeed(configuredDomains: [], capacity: 3)

    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "frame-a",
        type: "frame",
        frameID: "frame-a",
        parentFrameID: "main-frame"
    ))

    var iterator = feed.records.makeAsyncIterator()
    await #expect(throws: ConnectionModelFeedError.bufferOverflow(capacity: 3)) {
        try await iterator.next()
    }
    #expect(await core.terminalCause == .modelFeedFailure(.bufferOverflow(capacity: 3)))
    await #expect(throws: WebInspectorProxyError.self) {
        try await core.waitUntilClosed()
    }
}

@Test
func modelFeedAndDirectConsumersClaimConnectionExclusivelyInBothOrders() async throws {
    let directFirstCore = ConnectionCore(backend: FakeTransportBackend(), responseTimeout: nil)
    _ = await directFirstCore.events(for: .network)
    await #expect(throws: ConnectionModelFeedError.connectionAlreadyUsedByDirectConsumer) {
        try await directFirstCore.openModelFeed(configuredDomains: [], capacity: 8)
    }
    await directFirstCore.close()

    let feedFirstCore = ConnectionCore(backend: FakeTransportBackend(), responseTimeout: nil)
    _ = await feedFirstCore.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let feed = try await feedFirstCore.openModelFeed(configuredDomains: [], capacity: 8)
    await #expect(throws: ConnectionModelFeedError.alreadyOpen) {
        try await feedFirstCore.openModelFeed(configuredDomains: [], capacity: 8)
    }
    await #expect(throws: WebInspectorProxyError.connectionInUse) {
        try await feedFirstCore.send(ProtocolCommand(
            domain: .target,
            method: "Target.getTargets",
            routing: .root
        ))
    }
    await #expect(throws: WebInspectorProxyError.connectionInUse) {
        let _: WebInspectorProxyEventScope<Network.Event> = try await feedFirstCore.acquireEventScope(
            route: .currentPage,
            targetID: .currentPage,
            domain: .network,
            buffering: .bounded(8),
            extract: { event in
                guard case let .network(value) = event else {
                    return nil
                }
                return value
            }
        )
    }

    try await feed.close()
    try await feed.close()
    await feedFirstCore.close()
}

#if os(macOS)
@Test
func legacyPassiveStreamAfterModelFeedIsAProgrammerError() async {
    await #expect(processExitsWith: .failure) {
        let core = ConnectionCore(backend: FakeTransportBackend(), responseTimeout: nil)
        _ = try await core.openModelFeed(configuredDomains: [], capacity: 8)
        _ = await core.events(for: .network)
    }
}
#endif

@Test
func explicitConnectionCloseFinishesModelFeedOnlyAfterCloseQuiescence() async throws {
    let closeGate = ModelFeedAsyncGate()
    let core = ConnectionCore(
        backend: FakeTransportBackend(),
        responseTimeout: nil,
        closeAction: {
            await closeGate.waitUntilReleased()
        }
    )
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let feed = try await core.openModelFeed(configuredDomains: [], capacity: 8)
    let observerReady = ModelFeedProbe()
    let observerFinished = ModelFeedProbe()
    let observer = Task {
        var iterator = feed.records.makeAsyncIterator()
        _ = try await iterator.next()
        _ = try await iterator.next()
        _ = try await iterator.next()
        await observerReady.finish()
        let terminal = try await iterator.next()
        await observerFinished.finish()
        return terminal == nil
    }
    await observerReady.waitUntilFinished()

    let closeTask = Task {
        await core.close()
    }
    await closeGate.waitUntilStarted()
    #expect(await observerFinished.isFinished == false)

    await closeGate.release()
    await closeTask.value
    #expect(try await observer.value)
}

@Test
func fatalAndProtocolTerminationFailModelFeed() async throws {
    let fatalCore = ConnectionCore(backend: FakeTransportBackend(), responseTimeout: nil)
    _ = await fatalCore.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let fatalFeed = try await fatalCore.openModelFeed(configuredDomains: [], capacity: 8)
    var fatalIterator = fatalFeed.records.makeAsyncIterator()
    _ = try await fatalIterator.next()
    _ = try await fatalIterator.next()
    _ = try await fatalIterator.next()
    let fatalHandoff = try #require(fatalCore.failFromNativeCallback("feed fatal"))
    await fatalHandoff.value
    await #expect(throws: WebInspectorProxyError.transportFailure("feed fatal")) {
        try await fatalIterator.next()
    }

    let protocolCore = ConnectionCore(backend: FakeTransportBackend(), responseTimeout: nil)
    _ = await protocolCore.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let protocolFeed = try await protocolCore.openModelFeed(configuredDomains: [], capacity: 8)
    var protocolIterator = protocolFeed.records.makeAsyncIterator()
    _ = try await protocolIterator.next()
    _ = try await protocolIterator.next()
    _ = try await protocolIterator.next()
    _ = await protocolCore.receiveRootMessage("not-json")
    await #expect(throws: WebInspectorProxyError.protocolViolation("Malformed root protocol message.")) {
        try await protocolIterator.next()
    }
}

@Test
func droppingModelFeedFinishesMailboxButKeepsConnectionClaimedUntilClose() async throws {
    let core = ConnectionCore(backend: FakeTransportBackend(), responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    var feed: ConnectionModelFeed? = try await core.openModelFeed(
        configuredDomains: [],
        capacity: 8
    )
    weak let weakFeed = feed
    let records = try #require(feed).records
    feed = nil

    var iterator = records.makeAsyncIterator()
    _ = try await iterator.next()
    _ = try await iterator.next()
    _ = try await iterator.next()
    #expect(try await iterator.next() == nil)
    #expect(weakFeed == nil)
    await #expect(throws: ConnectionModelFeedError.alreadyOpen) {
        try await core.openModelFeed(configuredDomains: [], capacity: 8)
    }
    await #expect(throws: WebInspectorProxyError.connectionInUse) {
        try await core.send(ProtocolCommand(
            domain: .target,
            method: "Target.getTargets",
            routing: .root
        ))
    }
    await core.close()
}

@Test
func targetMutationCannotReenterBeforeSnapshotPublication() async throws {
    let core = ConnectionCore(backend: FakeTransportBackend(), responseTimeout: nil)
    let feed = try await core.openModelFeed(configuredDomains: [], capacity: 8)
    var iterator = feed.records.makeAsyncIterator()
    let reset = try await modelFeedRequireReset(iterator.next())
    let mutationGate = ModelFeedSynchronousGate()
    await core.replaceModelTargetMutationActionForTesting {
        mutationGate.block()
    }

    let receiveTask = Task {
        await core.receiveRootMessage(modelFeedTargetCreatedMessage(
            id: "page-main",
            type: "page",
            frameID: "main-frame"
        ))
    }
    await mutationGate.waitUntilBlocked()

    let generationStarted = ModelFeedProbe()
    let generationFinished = ModelFeedProbe()
    let generationTask = Task {
        await generationStarted.finish()
        let generation = try await core.pageGeneration()
        await generationFinished.finish()
        return generation
    }
    await generationStarted.waitUntilFinished()
    #expect(await generationFinished.isFinished == false)

    mutationGate.release()
    let eventSequence = await receiveTask.value
    let generation = try await generationTask.value
    let snapshot = try await modelFeedRequireTargetSnapshot(iterator.next())

    #expect(generation == reset)
    #expect(snapshot.generation == reset)
    #expect(snapshot.through == eventSequence)

    await core.replaceModelTargetMutationActionForTesting(nil)
    try await feed.close()
    await core.close()
}

@Test
func replacementMainPageWaiterResumesAfterCapabilityOwnershipIsReconciled() async throws {
    let waiterRegistered = ModelFeedProbe()
    let backend = FakeTransportBackend()
    let core = ConnectionCore(
        backend: backend,
        responseTimeout: nil,
        timeoutSleep: { _ in
            await waiterRegistered.finish()
            try await Task.sleep(for: .seconds(30))
        }
    )
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-old",
        type: "page",
        frameID: "main-frame"
    ))

    let scopeTask = Task {
        let scope: WebInspectorProxyEventScope<Network.Event> = try await core.acquireEventScope(
            route: .currentPage,
            targetID: .currentPage,
            domain: .network,
            buffering: .bounded(8),
            extract: { event in
                guard case let .network(value) = event else {
                    return nil
                }
                return value
            }
        )
        return scope
    }
    let initialEnable = try await backend.waitForTargetMessage(method: "Network.enable")
    let initialEnableID = try modelFeedMessageID(initialEnable.message)
    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-old",
        message: #"{"id":\#(initialEnableID),"result":{}}"#
    ))
    let scope = try await scopeTask.value

    _ = await core.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"page-old"}}"#
    )
    let orderedEvents = await core.orderedEvents()
    let eventObservationTask = Task {
        var iterator = orderedEvents.makeAsyncIterator()
        let event = await iterator.next()
        let purposes = await core.pendingReplyPurposes()
        return (event, purposes)
    }
    let waiterTask = Task {
        try await core.waitForCurrentMainPageTarget(timeout: .seconds(1))
    }
    await waiterRegistered.waitUntilFinished()

    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-new",
        type: "page",
        frameID: "main-frame"
    ))
    let replacement = try await waiterTask.value
    let eventObservation = await eventObservationTask.value
    let replacementEvent = try #require(eventObservation.0)
    let pendingPurposes = eventObservation.1

    #expect(replacement.targetID == ProtocolTarget.ID("page-new"))
    #expect(replacementEvent.method == "Target.targetCreated")
    #expect(replacementEvent.targetID == ProtocolTarget.ID("page-new"))
    #expect(pendingPurposes.count == 1)
    let pending = try #require(pendingPurposes.first)
    guard case let .target(replyKey) = pending.key,
          case let .capability(capabilityKey, generation, _) = pending.value else {
        Issue.record("Expected one reconciled current-page capability owner.")
        await core.close()
        _ = scope
        return
    }
    #expect(replyKey.targetID == ProtocolTarget.ID("page-new"))
    #expect(replyKey.targetID != ProtocolTarget.ID("page-old"))
    #expect(capabilityKey.route == .currentPage)
    #expect(capabilityKey.targetID == .currentPage)
    #expect(capabilityKey.domain == .network)
    #expect(generation.rawValue == 2)

    await core.close()
    _ = scope
}

@Test
func modelFeedAcquiresAndReleasesConfiguredCapabilitiesInDeterministicOrder() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let configuredDomains = Set(ModelDomain.acquisitionOrder)
    let enableMethods = modelFeedExpectedEnableMethods(configuredDomains)
    let feed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: configuredDomains,
        targetID: "page-main"
    )

    #expect(enableMethods == [
        "CSS.enable",
        "Network.enable",
        "Console.enable",
        "Runtime.enable",
    ])
    #expect(try await modelFeedSentTargetMethods(backend) == enableMethods)

    var iterator = feed.records.makeAsyncIterator()
    let reset = try await modelFeedRequireReset(iterator.next())
    let snapshot = try await modelFeedRequireTargetSnapshot(iterator.next())
    #expect(snapshot.generation == reset)
    let replayCompletions = try await [
        modelFeedRequireReplayCompletion(iterator.next()),
        modelFeedRequireReplayCompletion(iterator.next()),
        modelFeedRequireReplayCompletion(iterator.next()),
        modelFeedRequireReplayCompletion(iterator.next()),
    ]
    #expect(replayCompletions.map(\.domain) == [
        .css,
        .network,
        .console,
        .runtime,
    ])
    #expect(replayCompletions.allSatisfy {
        $0.generation == reset && $0.through == snapshot.through
    })

    let owners = await core.capabilityLeaseOwnersForTesting()
    let domKey = ConnectionCapabilityKey(
        route: .currentPage,
        targetID: .currentPage,
        domain: .dom
    )
    #expect(owners[domKey] == Set([
        .modelFeed(feed.id, .dom),
        .modelFeed(feed.id, .css),
    ]))
    for domain in [
        WebInspectorProxyEventDomain.css,
        .network,
        .console,
        .runtime,
    ] {
        let key = ConnectionCapabilityKey(
            route: .currentPage,
            targetID: .currentPage,
            domain: domain
        )
        #expect(owners[key]?.count == 1)
    }

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: enableMethods
    )
    #expect(try await modelFeedSentTargetMethods(backend) == enableMethods + [
        "Runtime.disable",
        "Console.disable",
        "Network.disable",
        "CSS.disable",
    ])
    // The shared local DOM lease emits no replay marker, and each physical
    // wire capability emits exactly one marker.
    #expect(try await iterator.next() == nil)
    #expect(await modelFeedAllCapabilityLeaseOwners(core).isEmpty)
    await core.close()
}

@Test
func replayMarkerOverflowClaimsTerminalStateAndCannotReturnAnOpenFeed() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let openTask = Task {
        try await core.openModelFeed(
            configuredDomains: [.network],
            capacity: 2
        )
    }
    let enable = try await backend.waitForTargetMessage(method: "Network.enable")

    await modelFeedRespond(to: enable, core: core)
    #expect(await core.terminalCause == .modelFeedFailure(.bufferOverflow(capacity: 2)))
    do {
        _ = try await openTask.value
        Issue.record("A replay-marker overflow must not return an open model feed.")
    } catch {
        #expect(error is WebInspectorScopeError)
    }
    #expect(await backend.isDetached())
}

@Test
func rejectedEnableDoesNotPublishReplayMarkerOrPoisonFullFeed() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let openTask = Task {
        try await core.openModelFeed(
            configuredDomains: [.network],
            capacity: 2
        )
    }
    let enable = try await backend.waitForTargetMessage(method: "Network.enable")
    await modelFeedRespond(
        to: enable,
        core: core,
        errorMessage: "enable rejected"
    )

    await #expect(throws: WebInspectorProxyError.commandRejected(
        method: "Network.enable",
        message: "enable rejected"
    )) {
        try await openTask.value
    }
    #expect(await core.terminalCause == nil)
    #expect(await backend.isDetached() == false)

    let replacement = try await core.openModelFeed(
        configuredDomains: [],
        capacity: 3
    )
    try await replacement.close()
    await core.close()
}

@Test
func cancelledActivationDoesNotPublishReplayMarkerAfterOwnerStopsBeingDesired() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let key = ConnectionCapabilityKey(
        route: .currentPage,
        targetID: .currentPage,
        domain: .network
    )
    let openTask = Task {
        try await core.openModelFeed(
            configuredDomains: [.network],
            capacity: 2
        )
    }
    let enable = try await backend.waitForTargetMessage(method: "Network.enable")

    openTask.cancel()
    #expect(await modelFeedWaitForNoDesiredCapabilityOwners(core, key: key))
    await modelFeedRespond(to: enable, core: core)
    let disable = try await backend.waitForTargetMessage(method: "Network.disable")
    await modelFeedRespond(to: disable, core: core)

    await #expect(throws: CancellationError.self) {
        try await openTask.value
    }
    #expect(await core.terminalCause == nil)
    #expect(await backend.isDetached() == false)
    #expect(await modelFeedAllCapabilityLeaseOwners(core).isEmpty)

    let replacement = try await core.openModelFeed(
        configuredDomains: [],
        capacity: 3
    )
    try await replacement.close()
    await core.close()
}

@Test(arguments: [0, 1, 2, 3])
func modelFeedCapabilityFailureRollsBackSuccessfulPrefixInReverseOrder(
    failureIndex: Int
) async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let configuredDomains = Set(ModelDomain.acquisitionOrder)
    let enableMethods = modelFeedExpectedEnableMethods(configuredDomains)
    let openTask = Task {
        try await core.openModelFeed(
            configuredDomains: configuredDomains,
            capacity: 32
        )
    }

    for index in 0...failureIndex {
        let message = try await backend.waitForTargetMessage(
            ordinal: 0,
            after: index
        )
        #expect(try modelFeedMessageMethod(message.message) == enableMethods[index])
        if index == failureIndex {
            await modelFeedRespond(
                to: message,
                core: core,
                errorMessage: "rejected-\(failureIndex)"
            )
        } else {
            await modelFeedRespond(to: message, core: core)
        }
    }

    let rollbackMethods = Array(enableMethods[..<failureIndex].reversed()).map {
        $0.replacingOccurrences(of: ".enable", with: ".disable")
    }
    for (offset, expectedMethod) in rollbackMethods.enumerated() {
        let message = try await backend.waitForTargetMessage(
            ordinal: 0,
            after: failureIndex + 1 + offset
        )
        #expect(try modelFeedMessageMethod(message.message) == expectedMethod)
        await modelFeedRespond(to: message, core: core)
    }

    do {
        _ = try await openTask.value
        Issue.record("Expected configured capability acquisition to fail.")
    } catch {
        #expect(error as? WebInspectorProxyError == .commandRejected(
            method: enableMethods[failureIndex],
            message: "rejected-\(failureIndex)"
        ))
    }
    #expect(try await modelFeedSentTargetMethods(backend) == Array(
        enableMethods[...failureIndex]
    ) + rollbackMethods)
    #expect(await modelFeedAllCapabilityLeaseOwners(core).isEmpty)

    let replacementFeed = try await core.openModelFeed(
        configuredDomains: [],
        capacity: 8
    )
    try await replacementFeed.close()
    await core.close()
}

@Test
func modelFeedActivationCancellationRollsBackAfterEnableAndDisableQuiesce() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let openTask = Task {
        try await core.openModelFeed(
            configuredDomains: [.network],
            capacity: 8
        )
    }
    let enable = try await backend.waitForTargetMessage(method: "Network.enable")

    openTask.cancel()
    await modelFeedRespond(to: enable, core: core)
    let disable = try await backend.waitForTargetMessage(method: "Network.disable")
    await modelFeedRespond(to: disable, core: core)

    await #expect(throws: CancellationError.self) {
        try await openTask.value
    }
    #expect(try await modelFeedSentTargetMethods(backend) == [
        "Network.enable",
        "Network.disable",
    ])
    #expect(await modelFeedAllCapabilityLeaseOwners(core).isEmpty)
    let replacementFeed = try await core.openModelFeed(
        configuredDomains: [],
        capacity: 8
    )
    try await replacementFeed.close()
    await core.close()
}

@Test
func modelFeedCloseKeepsClaimUntilDisableAndSharesDuplicateCloseCompletion() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let feed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [.network],
        targetID: "page-main"
    )
    let firstClose = Task {
        try await feed.close()
    }
    let disable = try await backend.waitForTargetMessage(method: "Network.disable")
    let duplicateFinished = ModelFeedProbe()
    let duplicateClose = Task {
        try await feed.close()
        await duplicateFinished.finish()
    }

    await #expect(throws: ConnectionModelFeedError.alreadyOpen) {
        try await core.openModelFeed(configuredDomains: [], capacity: 8)
    }
    await #expect(throws: WebInspectorProxyError.connectionInUse) {
        try await core.send(ProtocolCommand(
            domain: .target,
            method: "Target.getTargets",
            routing: .root
        ))
    }
    #expect(await duplicateFinished.isFinished == false)

    await modelFeedRespond(to: disable, core: core)
    try await firstClose.value
    try await duplicateClose.value
    try await feed.close()

    let replacementFeed = try await core.openModelFeed(
        configuredDomains: [],
        capacity: 8
    )
    try await replacementFeed.close()

    let sentCount = await backend.sentMessages().count
    let directCommand = Task {
        try await core.send(ProtocolCommand(
            domain: .target,
            method: "Target.getTargets",
            routing: .root
        ))
    }
    let directMessage = try await backend.waitForMessage(after: sentCount)
    let directID = try modelFeedMessageID(directMessage)
    _ = await core.receiveRootMessage(#"{"id":\#(directID),"result":{}}"#)
    _ = try await directCommand.value
    await core.close()
}

@Test
func modelFeedRetargetDuringAcquisitionMovesPendingCapabilityToReplacement() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-old",
        type: "page",
        frameID: "main-frame"
    ))
    let openTask = Task {
        try await core.openModelFeed(
            configuredDomains: [.network],
            capacity: 16
        )
    }
    let oldEnable = try await backend.waitForTargetMessage(method: "Network.enable")
    #expect(oldEnable.targetIdentifier == ProtocolTarget.ID("page-old"))

    _ = await core.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"page-old"}}"#
    )
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-new",
        type: "page",
        frameID: "main-frame"
    ))
    let newEnable = try await backend.waitForTargetMessage(
        method: "Network.enable",
        ordinal: 0,
        after: 1
    )
    #expect(newEnable.targetIdentifier == ProtocolTarget.ID("page-new"))
    let pendingPurposes = await core.pendingReplyPurposes()
    #expect(pendingPurposes.keys.allSatisfy { key in
        guard case let .target(replyKey) = key else {
            return false
        }
        return replyKey.targetID == ProtocolTarget.ID("page-new")
    })

    await modelFeedRespond(to: newEnable, core: core)
    let feed = try await openTask.value
    #expect(await modelFeedAllCapabilityLeaseOwners(core) == Set([
        .modelFeed(feed.id, .network),
    ]))
    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-new",
        enableMethods: ["Network.enable"]
    )
    await core.close()
}

@Test
func activeModelFeedLeaseReconcilesOntoReplacementTarget() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-old",
        type: "page",
        frameID: "main-frame"
    ))
    let feed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [.network],
        targetID: "page-old"
    )
    var iterator = feed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(iterator.next())
    let initialSnapshot = try await modelFeedRequireTargetSnapshot(iterator.next())
    let initialReplay = try await modelFeedRequireReplayCompletion(iterator.next())
    #expect(initialReplay.generation == initialSnapshot.generation)
    #expect(initialReplay.domain == .network)
    #expect(initialReplay.through == initialSnapshot.through)

    _ = await core.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"page-old"}}"#
    )
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-new",
        type: "page",
        frameID: "main-frame"
    ))
    let replacementEnable = try await backend.waitForTargetMessage(
        method: "Network.enable",
        ordinal: 0,
        after: 1
    )
    #expect(replacementEnable.targetIdentifier == ProtocolTarget.ID("page-new"))
    let pendingPurposes = await core.pendingReplyPurposes()
    #expect(pendingPurposes.keys.allSatisfy { key in
        guard case let .target(replyKey) = key else {
            return false
        }
        return replyKey.targetID == ProtocolTarget.ID("page-new")
    })
    #expect(await modelFeedAllCapabilityLeaseOwners(core) == Set([
        .modelFeed(feed.id, .network),
    ]))
    let replacementEventSequence = await core.receiveRootMessage(
        modelFeedTargetDispatchMessage(
            targetID: "page-new",
            message: #"{"method":"Network.requestWillBeSent","params":{"requestId":"replacement-replay","request":{"url":"https://example.test/replacement","method":"GET"},"timestamp":2,"type":"Document"}}"#
        )
    )
    await modelFeedRespond(to: replacementEnable, core: core)

    let replacementReset = try await modelFeedRequireReset(iterator.next())
    let replacementSnapshot = try await modelFeedRequireTargetSnapshot(iterator.next())
    let replacementEvent = try await modelFeedRequireEvent(iterator.next())
    let replacementReplay = try await modelFeedRequireReplayCompletion(iterator.next())
    #expect(replacementReset.rawValue == initialSnapshot.generation.rawValue + 1)
    #expect(replacementSnapshot.generation == replacementReset)
    #expect(replacementEvent.generation == replacementReset)
    #expect(replacementEvent.sequence == replacementEventSequence)
    #expect(replacementEvent.sequence > replacementSnapshot.through)
    #expect(replacementReplay.generation == replacementReset)
    #expect(replacementReplay.domain == .network)
    #expect(replacementReplay.through == replacementEventSequence)

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-new",
        enableMethods: ["Network.enable"]
    )
    #expect(try await iterator.next() == nil)
    await core.close()
}

@Test
func domModelFeedCapabilityIsLocalButParticipatesInLeaseTransaction() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let feed = try await core.openModelFeed(
        configuredDomains: [.dom],
        capacity: 8
    )
    #expect(await backend.sentTargetMessages().isEmpty)
    #expect(await modelFeedAllCapabilityLeaseOwners(core) == Set([
        .modelFeed(feed.id, .dom),
    ]))

    try await feed.close()
    #expect(await backend.sentTargetMessages().isEmpty)
    #expect(await modelFeedAllCapabilityLeaseOwners(core).isEmpty)
    await core.close()
}

@Test
func terminalDuringModelFeedRollbackCompletesWithoutLeakingClaim() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let openTask = Task {
        try await core.openModelFeed(
            configuredDomains: [.network, .console],
            capacity: 16
        )
    }
    let networkEnable = try await backend.waitForTargetMessage(method: "Network.enable")
    await modelFeedRespond(to: networkEnable, core: core)
    let consoleEnable = try await backend.waitForTargetMessage(method: "Console.enable")
    await modelFeedRespond(
        to: consoleEnable,
        core: core,
        errorMessage: "console rejected"
    )
    _ = try await backend.waitForTargetMessage(method: "Network.disable")

    let fatalHandoff = try #require(core.failFromNativeCallback("fatal during rollback"))
    await fatalHandoff.value
    await #expect(throws: WebInspectorScopeError.self) {
        try await openTask.value
    }
    #expect(await core.terminalCause == .fatal("fatal during rollback"))
    #expect(await modelFeedAllCapabilityLeaseOwners(core).isEmpty)
    #expect(await backend.isDetached())
}

@Test
func modelFeedRollbackDisableRejectionTerminatesInsteadOfReusingEnabledState() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let openTask = Task {
        try await core.openModelFeed(
            configuredDomains: [.network, .console],
            capacity: 16
        )
    }
    let networkEnable = try await backend.waitForTargetMessage(method: "Network.enable")
    await modelFeedRespond(to: networkEnable, core: core)
    let consoleEnable = try await backend.waitForTargetMessage(method: "Console.enable")
    await modelFeedRespond(
        to: consoleEnable,
        core: core,
        errorMessage: "console rejected"
    )
    let networkDisable = try await backend.waitForTargetMessage(method: "Network.disable")
    await modelFeedRespond(
        to: networkDisable,
        core: core,
        errorMessage: "disable rejected"
    )

    await #expect(throws: WebInspectorScopeError.self) {
        try await openTask.value
    }
    guard case let .fatal(message) = await core.terminalCause else {
        Issue.record("Expected rollback cleanup failure to terminate the connection.")
        return
    }
    #expect(message.contains("Failed to release model feed capabilities"))
    #expect(await modelFeedAllCapabilityLeaseOwners(core).isEmpty)
    #expect(await backend.isDetached())
    await #expect(throws: WebInspectorProxyError.self) {
        try await core.openModelFeed(configuredDomains: [], capacity: 8)
    }
}

@Test
func modelFeedCloseDisableRejectionPoisonsMailboxAndTerminatesConnection() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let feed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [.network],
        targetID: "page-main"
    )
    var iterator = feed.records.makeAsyncIterator()
    _ = try await iterator.next()
    _ = try await iterator.next()

    let closeTask = Task {
        try await feed.close()
    }
    let disable = try await backend.waitForTargetMessage(method: "Network.disable")
    await modelFeedRespond(
        to: disable,
        core: core,
        errorMessage: "disable rejected"
    )
    let expectedError = WebInspectorProxyError.commandRejected(
        method: "Network.disable",
        message: "disable rejected"
    )
    await #expect(throws: expectedError) {
        try await closeTask.value
    }
    await #expect(throws: expectedError) {
        try await iterator.next()
    }

    guard case let .fatal(message) = await core.terminalCause else {
        Issue.record("Expected model feed close cleanup failure to terminate the connection.")
        return
    }
    #expect(message.contains("Failed to release model feed capabilities"))
    #expect(await modelFeedAllCapabilityLeaseOwners(core).isEmpty)
    #expect(await backend.isDetached())
    try await feed.close()
}

private func modelFeedExpectedEnableMethods(
    _ configuredDomains: Set<ModelDomain>
) -> [String] {
    var seenDomains: Set<WebInspectorProxyEventDomain> = []
    var methods: [String] = []
    for domain in ModelDomain.ordered(configuredDomains) {
        for dependency in domain.capabilityDependencies where dependency != .dom {
            guard seenDomains.insert(dependency).inserted else {
                continue
            }
            methods.append("\(dependency.rawValue).enable")
        }
    }
    return methods
}

private func modelFeedOpenSuccessfully(
    core: ConnectionCore,
    backend: FakeTransportBackend,
    configuredDomains: Set<ModelDomain>,
    targetID: String
) async throws -> ConnectionModelFeed {
    let enableMethods = modelFeedExpectedEnableMethods(configuredDomains)
    let targetMessageCount = await backend.sentTargetMessages().count
    let openTask = Task {
        try await core.openModelFeed(
            configuredDomains: configuredDomains,
            capacity: 32
        )
    }
    for (offset, expectedMethod) in enableMethods.enumerated() {
        let message = try await backend.waitForTargetMessage(
            ordinal: 0,
            after: targetMessageCount + offset
        )
        #expect(try modelFeedMessageMethod(message.message) == expectedMethod)
        #expect(message.targetIdentifier == ProtocolTarget.ID(targetID))
        await modelFeedRespond(to: message, core: core)
    }
    return try await openTask.value
}

private func modelFeedCloseSuccessfully(
    _ feed: ConnectionModelFeed,
    core: ConnectionCore,
    backend: FakeTransportBackend,
    targetID: String,
    enableMethods: [String]
) async throws {
    let disableMethods = enableMethods.reversed().map {
        $0.replacingOccurrences(of: ".enable", with: ".disable")
    }
    let targetMessageCount = await backend.sentTargetMessages().count
    let closeTask = Task {
        try await feed.close()
    }
    for (offset, expectedMethod) in disableMethods.enumerated() {
        let message = try await backend.waitForTargetMessage(
            ordinal: 0,
            after: targetMessageCount + offset
        )
        #expect(try modelFeedMessageMethod(message.message) == expectedMethod)
        #expect(message.targetIdentifier == ProtocolTarget.ID(targetID))
        await modelFeedRespond(to: message, core: core)
    }
    try await closeTask.value
}

private func modelFeedSentTargetMethods(
    _ backend: FakeTransportBackend
) async throws -> [String] {
    try await backend.sentTargetMessages().map {
        try modelFeedMessageMethod($0.message)
    }
}

private func modelFeedAllCapabilityLeaseOwners(
    _ core: ConnectionCore
) async -> Set<ConnectionCapabilityLeaseOwner> {
    await core.capabilityLeaseOwnersForTesting().values.reduce(into: []) {
        $0.formUnion($1)
    }
}

private func modelFeedWaitForNoDesiredCapabilityOwners(
    _ core: ConnectionCore,
    key: ConnectionCapabilityKey
) async -> Bool {
    for _ in 0..<1_000 {
        if await core.desiredCapabilityLeaseOwnersForTesting()[key]?.isEmpty == true {
            return true
        }
        await Task.yield()
    }
    return false
}

private func modelFeedMessageMethod(_ message: String) throws -> String {
    let object = try JSONSerialization.jsonObject(with: Data(message.utf8))
    let dictionary = try #require(object as? [String: Any])
    return try #require(dictionary["method"] as? String)
}

private func modelFeedRespond(
    to message: SentTargetMessage,
    core: ConnectionCore,
    errorMessage: String? = nil
) async {
    let messageID = try! modelFeedMessageID(message.message)
    let reply: [String: Any]
    if let errorMessage {
        reply = [
            "id": messageID,
            "error": ["message": errorMessage],
        ]
    } else {
        reply = [
            "id": messageID,
            "result": [:] as [String: Any],
        ]
    }
    let data = try! JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: message.targetIdentifier.rawValue,
        message: String(decoding: data, as: UTF8.self)
    ))
}

private struct ModelFeedEventRecord {
    let generation: WebInspectorPage.Generation
    let sequence: UInt64
    let payload: ModelProtocolEvent
}

private struct ModelFeedTargetSnapshotRecord {
    let generation: WebInspectorPage.Generation
    let through: UInt64
    let snapshot: ModelTargetSnapshot
}

private struct ModelFeedSynchronizationRecord {
    let generation: WebInspectorPage.Generation
    let through: UInt64
}

private struct ModelFeedReplayCompletionRecord {
    let generation: WebInspectorPage.Generation
    let domain: ModelDomain
    let through: UInt64
}

private enum ModelFeedTestError: Error {
    case unexpectedRecord
}

private func modelFeedRequireReset(
    _ record: ConnectionModelFeedRecord?
) throws -> WebInspectorPage.Generation {
    guard case let .reset(generation) = try #require(record) else {
        Issue.record("Expected model feed reset.")
        throw ModelFeedTestError.unexpectedRecord
    }
    return generation
}

private func modelFeedRequireTargetSnapshot(
    _ record: ConnectionModelFeedRecord?
) throws -> ModelFeedTargetSnapshotRecord {
    guard case let .targetSnapshot(generation, through, snapshot) = try #require(record) else {
        Issue.record("Expected model target snapshot.")
        throw ModelFeedTestError.unexpectedRecord
    }
    return ModelFeedTargetSnapshotRecord(
        generation: generation,
        through: through,
        snapshot: snapshot
    )
}

private func modelFeedRequireSynchronization(
    _ record: ConnectionModelFeedRecord?
) throws -> ModelFeedSynchronizationRecord {
    guard case let .synchronizationComplete(generation, through) = try #require(record) else {
        Issue.record("Expected model feed synchronization completion.")
        throw ModelFeedTestError.unexpectedRecord
    }
    return ModelFeedSynchronizationRecord(generation: generation, through: through)
}

private func modelFeedRequireReplayCompletion(
    _ record: ConnectionModelFeedRecord?
) throws -> ModelFeedReplayCompletionRecord {
    guard case let .replayComplete(generation, domain, through) = try #require(record) else {
        Issue.record("Expected model feed replay completion.")
        throw ModelFeedTestError.unexpectedRecord
    }
    return ModelFeedReplayCompletionRecord(
        generation: generation,
        domain: domain,
        through: through
    )
}

private func modelFeedRequireEvent(
    _ record: ConnectionModelFeedRecord?
) throws -> ModelFeedEventRecord {
    guard case let .event(generation, sequence, payload) = try #require(record) else {
        Issue.record("Expected model feed event.")
        throw ModelFeedTestError.unexpectedRecord
    }
    return ModelFeedEventRecord(
        generation: generation,
        sequence: sequence,
        payload: payload
    )
}

private func modelFeedTargetRecord(
    id: String,
    kind: ProtocolTarget.Kind,
    frameID: String?,
    parentFrameID: String? = nil,
    isProvisional: Bool = false
) -> ProtocolTarget.Record {
    ProtocolTarget.Record(
        id: ProtocolTarget.ID(id),
        kind: kind,
        frameID: frameID.map { ProtocolFrame.ID($0) },
        parentFrameID: parentFrameID.map { ProtocolFrame.ID($0) },
        isProvisional: isProvisional
    )
}

private func modelFeedMessageID(_ message: String) throws -> UInt64 {
    let object = try JSONSerialization.jsonObject(with: Data(message.utf8))
    let dictionary = try #require(object as? [String: Any])
    return try #require(dictionary["id"] as? UInt64)
}

private func modelFeedTargetCreatedMessage(
    id: String,
    type: String,
    frameID: String?,
    parentFrameID: String? = nil,
    isProvisional: Bool = false
) -> String {
    var targetInfo: [String: Any] = [
        "targetId": id,
        "type": type,
        "isProvisional": isProvisional,
    ]
    if let frameID {
        targetInfo["frameId"] = frameID
    }
    if let parentFrameID {
        targetInfo["parentFrameId"] = parentFrameID
    }
    let data = try! JSONSerialization.data(
        withJSONObject: [
            "method": "Target.targetCreated",
            "params": ["targetInfo": targetInfo],
        ],
        options: [.sortedKeys]
    )
    return String(decoding: data, as: UTF8.self)
}

private func modelFeedTargetDispatchMessage(
    targetID: String,
    message: String
) -> String {
    let data = try! JSONSerialization.data(
        withJSONObject: [
            "method": "Target.dispatchMessageFromTarget",
            "params": [
                "targetId": targetID,
                "message": message,
            ],
        ],
        options: [.sortedKeys]
    )
    return String(decoding: data, as: UTF8.self)
}

private actor ModelFeedAsyncGate {
    private var isStarted = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        isStarted = true
        let startWaiters = self.startWaiters
        self.startWaiters.removeAll()
        for waiter in startWaiters {
            waiter.resume()
        }
        guard !isReleased else {
            return
        }
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
        }
    }

    func waitUntilStarted() async {
        guard !isStarted else {
            return
        }
        await withCheckedContinuation { continuation in
            if isStarted {
                continuation.resume()
            } else {
                startWaiters.append(continuation)
            }
        }
    }

    func release() {
        isReleased = true
        let releaseWaiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        for waiter in releaseWaiters {
            waiter.resume()
        }
    }
}

private actor ModelFeedProbe {
    private(set) var isFinished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func finish() {
        guard !isFinished else {
            return
        }
        isFinished = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilFinished() async {
        guard !isFinished else {
            return
        }
        await withCheckedContinuation { continuation in
            if isFinished {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }
}

private final class ModelFeedSynchronousGate: Sendable {
    private struct State {
        var isBlocked = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())
    private let releaseSemaphore = DispatchSemaphore(value: 0)

    func block() {
        let waiters = state.withLock { state in
            state.isBlocked = true
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
        releaseSemaphore.wait()
    }

    func waitUntilBlocked() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                guard !state.isBlocked else {
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func release() {
        releaseSemaphore.signal()
    }
}
