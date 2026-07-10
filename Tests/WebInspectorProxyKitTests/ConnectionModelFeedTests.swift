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
    let core = ConnectionCore(backend: FakeTransportBackend(), responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let feed = try await core.openModelFeed(configuredDomains: [.network], capacity: 8)
    var iterator = feed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(iterator.next())
    let initialSnapshot = try await modelFeedRequireTargetSnapshot(iterator.next())

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

    try await feed.close()
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
