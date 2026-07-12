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

    let snapshot = try #require(registry.modelTargetGraphSnapshot())

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
func modelDomainNormalizationAddsDOMOnlyWhenCSSRequiresIt() {
    #expect(ModelDomain.normalized([.css]) == [.dom, .css])
    #expect(ModelDomain.normalized([.network]) == [.network])
    #expect(ModelDomain.normalized([.dom, .runtime]) == [.dom, .runtime])
}

@Test
func parkedCapabilityLedgerKeepsABoundedRestorationWindow() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-0",
        type: "page",
        frameID: "main-frame"
    ))

    let scopeTask = Task {
        let scope: WebInspectorProxyEventScope<Network.Event> = try await core
            .acquireEventScope(
                route: .currentPage,
                targetID: .currentPage,
                domain: .network,
                buffering: .bounded(256),
                extract: { event in
                    guard case let .network(value) = event else {
                        return nil
                    }
                    return value
                }
            )
        return scope
    }
    let initialEnable = try await backend.waitForTargetMessage(
        method: "Network.enable"
    )
    await modelFeedRespond(to: initialEnable, core: core)
    let scope = try await scopeTask.value

    for index in 1...70 {
        let oldTargetID = "page-\(index - 1)"
        let newTargetID = "page-\(index)"
        _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
            id: newTargetID,
            type: "page",
            frameID: "main-frame",
            isProvisional: true
        ))
        let commitBaseline = await backend.sentTargetMessages().count
        _ = await core.receiveRootMessage(
            #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"\#(oldTargetID)","newTargetId":"\#(newTargetID)"}}"#
        )
        let enable = try await backend.waitForTargetMessage(
            method: "Network.enable",
            after: commitBaseline
        )
        #expect(enable.targetIdentifier == ProtocolTarget.ID(newTargetID))
        await modelFeedRespond(to: enable, core: core)
    }

    #expect(await core.parkedCurrentPageCapabilityCountForTesting() == 64)

    let releaseBaseline = await backend.sentTargetMessages().count
    let releaseTask = Task {
        try await core.releaseEventScope(scope.id)
    }
    let disable = try await backend.waitForTargetMessage(
        method: "Network.disable",
        after: releaseBaseline
    )
    #expect(disable.targetIdentifier == ProtocolTarget.ID("page-70"))
    await modelFeedRespond(to: disable, core: core)
    try await releaseTask.value
    #expect(await core.terminalCause == nil)
    await core.close()
}

@Test
func directElementPickerScopesShareOnePhysicalModeAndInitializeOncePerGeneration() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))

    let firstScopeTask = Task {
        try await modelFeedAcquireDirectElementPickerScope(core: core)
    }
    try await modelFeedCompleteElementPickerAcquisition(
        core: core,
        backend: backend,
        targetID: "page-main",
        expectsInitialization: true
    )
    let firstScope = try await firstScopeTask.value

    let acquiredMessageCount = await backend.sentTargetMessages().count
    let secondScope = try await modelFeedAcquireDirectElementPickerScope(core: core)
    #expect(await backend.sentTargetMessages().count == acquiredMessageCount)

    try await core.releaseEventScope(firstScope.id)
    #expect(await backend.sentTargetMessages().count == acquiredMessageCount)

    let secondRelease = Task {
        try await core.releaseEventScope(secondScope.id)
    }
    try await modelFeedCompleteElementPickerRelease(
        core: core,
        backend: backend,
        targetID: "page-main",
        after: acquiredMessageCount
    )
    try await secondRelease.value

    let reacquireBaseline = await backend.sentTargetMessages().count
    let reacquireTask = Task {
        try await modelFeedAcquireDirectElementPickerScope(core: core)
    }
    try await modelFeedCompleteElementPickerAcquisition(
        core: core,
        backend: backend,
        targetID: "page-main",
        after: reacquireBaseline,
        expectsInitialization: false
    )
    let reacquiredScope = try await reacquireTask.value
    let reacquireMethods = try await backend.sentTargetMessages()
        .dropFirst(reacquireBaseline)
        .map { try modelFeedMessageMethod($0.message) }
    #expect(reacquireMethods == [
        "Inspector.enable",
        "DOM.setInspectModeEnabled",
    ])

    let finalRelease = Task {
        try await core.releaseEventScope(reacquiredScope.id)
    }
    try await modelFeedCompleteElementPickerRelease(
        core: core,
        backend: backend,
        targetID: "page-main",
        after: await backend.sentTargetMessages().count
    )
    try await finalRelease.value
    await core.close()
}

@Test
func directElementPickerDiscardsInspectReceivedBeforeModeActivationReply() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))

    let scopeTask = Task {
        try await modelFeedAcquireDirectElementPickerScope(core: core)
    }
    let enable = try await backend.waitForTargetMessage(method: "Inspector.enable")
    await modelFeedRespond(to: enable, core: core)
    let initialized = try await backend.waitForTargetMessage(method: "Inspector.initialized")
    await modelFeedRespond(to: initialized, core: core)
    let activate = try await backend.waitForTargetMessage(method: "DOM.setInspectModeEnabled")
    #expect(try modelFeedElementPickerEnabled(activate.message) == true)

    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: modelFeedInspectorInspectMessage(objectID: "before-activation")
    ))
    await modelFeedRespond(to: activate, core: core)
    let scope = try await scopeTask.value
    var iterator = scope.events.makeAsyncIterator()
    guard case .reset = try #require(try await iterator.next()) else {
        Issue.record("Expected the element-picker scope's initial reset.")
        return
    }

    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: modelFeedInspectorInspectMessage(objectID: "after-activation")
    ))
    guard case let .event(_, event) = try #require(try await iterator.next()),
          case let .inspect(object, _) = event else {
        Issue.record("Expected the post-activation Inspector.inspect event.")
        return
    }
    #expect(object.id == Runtime.RemoteObject.ID("after-activation"))

    let releaseBaseline = await backend.sentTargetMessages().count
    let release = Task {
        try await core.releaseEventScope(scope.id)
    }
    try await modelFeedCompleteElementPickerRelease(
        core: core,
        backend: backend,
        targetID: "page-main",
        after: releaseBaseline
    )
    try await release.value
    await core.close()
}

@Test
func directElementPickerReinitializesAndReactivatesOnReplacementPage() async throws {
    let backend = FakeTransportBackend()
    let parser = ModelFeedArmedMessageParser()
    let core = ConnectionCore(
        backend: backend,
        responseTimeout: nil,
        messageParser: { try await parser.parse($0) }
    )
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-old",
        type: "page",
        frameID: "main-frame"
    ))

    let scopeTask = Task {
        try await modelFeedAcquireDirectElementPickerScope(core: core)
    }
    try await modelFeedCompleteElementPickerAcquisition(
        core: core,
        backend: backend,
        targetID: "page-old",
        expectsInitialization: true
    )
    let scope = try await scopeTask.value
    var iterator = scope.events.makeAsyncIterator()
    guard case .reset = try #require(try await iterator.next()) else {
        Issue.record("Expected the old page generation reset.")
        return
    }

    let replacementBaseline = await backend.sentTargetMessages().count
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-new",
        type: "page",
        frameID: "main-frame",
        isProvisional: true
    ))
    _ = await core.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-old","newTargetId":"page-new"}}"#
    )

    let enable = try await backend.waitForTargetMessage(
        method: "Inspector.enable",
        after: replacementBaseline
    )
    #expect(enable.targetIdentifier == ProtocolTarget.ID("page-new"))
    await modelFeedRespond(to: enable, core: core)
    let initialized = try await backend.waitForTargetMessage(
        method: "Inspector.initialized",
        after: replacementBaseline
    )
    #expect(initialized.targetIdentifier == ProtocolTarget.ID("page-new"))
    await modelFeedRespond(to: initialized, core: core)
    let activate = try await backend.waitForTargetMessage(
        method: "DOM.setInspectModeEnabled",
        after: replacementBaseline
    )
    #expect(activate.targetIdentifier == ProtocolTarget.ID("page-new"))
    let activationPendingKey = TransportSession.PendingKey.target(
        TransportSession.ReplyKey(
            targetID: activate.targetIdentifier,
            commandID: try modelFeedMessageID(activate.message)
        )
    )
    let activationPurpose = try #require(
        await core.pendingReplyPurposes()[activationPendingKey]
    )
    guard case let .elementPickerMode(key, generation, _, enabled) = activationPurpose else {
        Issue.record("Expected the inspect-mode reply to retain its picker owner.")
        return
    }
    #expect(key.route == .currentPage)
    #expect(key.targetID == .currentPage)
    #expect(key.domain == .inspector)
    #expect(generation == (try await core.pageGeneration()))
    #expect(enabled)
    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-new",
        message: modelFeedInspectorInspectMessage(objectID: "before-new-activation")
    ))
    await parser.armNextInvocation()
    let activationReply = Task {
        await modelFeedRespond(to: activate, core: core)
    }
    await parser.waitUntilBlocked()
    let immediateInspect = Task {
        await core.receiveRootMessage(modelFeedTargetDispatchMessage(
            targetID: "page-new",
            message: modelFeedInspectorInspectMessage(objectID: "after-new-activation")
        ))
    }
    _ = await immediateInspect.value
    await parser.release()
    await activationReply.value
    guard case .reset = try #require(try await iterator.next()) else {
        Issue.record("Expected the replacement page generation reset.")
        return
    }
    guard case let .event(_, event) = try #require(try await iterator.next()),
          case let .inspect(object, _) = event else {
        Issue.record("Expected only the post-reactivation inspect event.")
        return
    }
    #expect(object.id == Runtime.RemoteObject.ID("after-new-activation"))

    let releaseBaseline = await backend.sentTargetMessages().count
    let releaseTask = Task {
        try await core.releaseEventScope(scope.id)
    }
    try await modelFeedCompleteElementPickerRelease(
        core: core,
        backend: backend,
        targetID: "page-new",
        after: releaseBaseline
    )
    try await releaseTask.value
    await core.close()
}

@Test
func modelFeedElementPickerPublishesOnlyActivatedInspectAndClosesInWireOrder() async throws {
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
        configuredDomains: [.dom],
        targetID: "page-main"
    )
    var iterator = feed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    _ = try await modelFeedRequireDOMBootstrapSnapshot(iterator.next())
    _ = try modelFeedRequireBootstrapCompletion(try await iterator.next())
    _ = try await modelFeedRequireSynchronization(iterator.next())

    let acquireTask = Task {
        try await feed.acquireElementPicker()
    }
    let enable = try await backend.waitForTargetMessage(method: "Inspector.enable")
    await modelFeedRespond(to: enable, core: core)
    let initialized = try await backend.waitForTargetMessage(method: "Inspector.initialized")
    await modelFeedRespond(to: initialized, core: core)
    let activate = try await backend.waitForTargetMessage(method: "DOM.setInspectModeEnabled")
    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: modelFeedInspectorInspectMessage(objectID: "before-activation")
    ))
    await modelFeedRespond(to: activate, core: core)
    try await acquireTask.value

    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: modelFeedInspectorInspectMessage(objectID: "after-activation")
    ))
    let record = try modelFeedRequireEvent(try await iterator.next())
    guard case let .inspector(event) = record.payload,
          case let .inspect(object, _) = event else {
        Issue.record("Expected the activated Inspector.inspect model record.")
        return
    }
    #expect(record.target.id == WebInspectorTarget.ID("page-main"))
    #expect(object.id == Runtime.RemoteObject.ID("after-activation"))

    let closeBaseline = await backend.sentTargetMessages().count
    let closeTask = Task {
        try await feed.close()
    }
    try await modelFeedCompleteElementPickerRelease(
        core: core,
        backend: backend,
        targetID: "page-main",
        after: closeBaseline
    )
    let pageDisable = try await backend.waitForTargetMessage(
        method: "Page.disable",
        after: closeBaseline
    )
    await modelFeedRespond(to: pageDisable, core: core)
    try await closeTask.value
    #expect(try await iterator.next() == nil)
    await core.close()
}

@Test
func cssModelFeedUsesNormalizedDOMBootstrapAndOneSynchronization() async throws {
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
        configuredDomains: [.css],
        targetID: "page-main"
    )
    var iterator = feed.records.makeAsyncIterator()
    let reset = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    let bootstrap = try await modelFeedRequireDOMBootstrapSnapshot(iterator.next())
    let domCompletion = try await modelFeedRequireBootstrapCompletion(iterator.next())
    let cssSnapshot = try await modelFeedRequireCSSBootstrapSnapshot(iterator.next())
    let cssCompletion = try await modelFeedRequireBootstrapCompletion(iterator.next())
    let synchronization = try await modelFeedRequireSynchronization(iterator.next())
    #expect(bootstrap.generation == reset)
    #expect(domCompletion.domain == .dom)
    #expect(cssSnapshot.count == 1)
    #expect(cssSnapshot.first?.scope.generation == reset)
    #expect(cssSnapshot.first?.scope.target.id == WebInspectorTarget.ID("page-main"))
    #expect(cssSnapshot.first?.scope.navigationEpoch == ModelNavigationEpoch(rawValue: 0))
    #expect(cssSnapshot.first?.scope.domBindingEpoch == ModelDOMBindingEpoch(rawValue: 0))
    #expect(cssCompletion.domain == .css)
    #expect(synchronization.generation == reset)

    let domKey = ConnectionCapabilityKey(
        route: .currentPage,
        targetID: .currentPage,
        domain: .dom
    )
    #expect(await core.capabilityLeaseOwnersForTesting()[domKey] == Set([
        .modelFeed(feed.id, .dom),
        .modelFeed(feed.id, .css),
    ]))
    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable", "CSS.enable"]
    )
    #expect(try await iterator.next() == nil)
    await core.close()
}

@Test
func multiDomainSynchronizationAcceptsReplayBeforeDOMBootstrap() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))

    let openTask = Task {
        try await core.openModelFeed(
            configuredDomains: [.dom, .network]
        )
    }
    let getDocument = try await backend.waitForTargetMessage(method: "DOM.getDocument")
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)
    let networkEnable = try await backend.waitForTargetMessage(method: "Network.enable")
    await modelFeedRespond(to: networkEnable, core: core)
    let feed = try await openTask.value

    var iterator = feed.records.makeAsyncIterator()
    let reset = try await modelFeedRequireReset(iterator.next())
    let targetSnapshot = try await modelFeedRequireTargetSnapshot(iterator.next())
    let replay = try await modelFeedRequireReplayCompletion(iterator.next())
    #expect(replay.generation == reset)
    #expect(replay.domain == .network)

    await modelFeedRespondWithDocument(
        to: getDocument,
        core: core,
        nodeID: "document"
    )
    let bootstrap = try await modelFeedRequireDOMBootstrapSnapshot(iterator.next())
    let bootstrapCompletion = try await modelFeedRequireBootstrapCompletion(iterator.next())
    let synchronization = try await modelFeedRequireSynchronization(iterator.next())
    #expect(bootstrap.generation == reset)
    #expect(bootstrapCompletion.generation == reset)
    #expect(bootstrapCompletion.domain == .dom)
    #expect(synchronization.generation == reset)
    #expect(synchronization.through >= targetSnapshot.through)

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable", "Network.enable"]
    )
    #expect(try await iterator.next() == nil)
    await core.close()
}

@Test
func modelFeedAtomicallyStartsWithResetTargetSnapshotAndEmptySynchronization() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
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

    let feed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [],
        targetID: "page-main"
    )
    var iterator = feed.records.makeAsyncIterator()
    let reset = try await modelFeedRequireReset(iterator.next())
    let snapshot = try await modelFeedRequireTargetSnapshot(iterator.next())
    let synchronization = try await modelFeedRequireSynchronization(iterator.next())

    #expect(reset.rawValue == 1)
    #expect(snapshot.generation == reset)
    #expect(snapshot.through == through)
    #expect(snapshot.snapshot.currentPageID == WebInspectorTarget.ID("page-main"))
    #expect(snapshot.snapshot.targets.map(\.target.id) == [
        WebInspectorTarget.ID("page-main"),
        WebInspectorTarget.ID("frame-a"),
        WebInspectorTarget.ID("frame-b"),
        WebInspectorTarget.ID("frame-child"),
    ])
    #expect(synchronization.generation == reset)
    #expect(synchronization.through == through)

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable"]
    )
    #expect(try await iterator.next() == nil)
    await core.close()
}

@Test
func modelFeedUnavailableBindingUsesOneGenerationForResetSnapshotAndSynchronization() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    let openTask = Task {
        try await core.openModelFeed(configuredDomains: [])
    }
    let through = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)
    let feed = try await openTask.value
    var iterator = feed.records.makeAsyncIterator()

    let reset = try await modelFeedRequireReset(iterator.next())
    #expect(reset.rawValue == 1)
    let snapshot = try await modelFeedRequireTargetSnapshot(iterator.next())
    let synchronization = try await modelFeedRequireSynchronization(iterator.next())

    #expect(snapshot.generation == reset)
    #expect(snapshot.through == through)
    #expect(synchronization.generation == reset)
    #expect(synchronization.through == through)

    // The snapshot watermark subsumes the Target.targetCreated event that
    // established the binding. Closing immediately must not expose a duplicate
    // lifecycle delta at that same sequence.
    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable"]
    )
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
        try await core.openModelFeed(configuredDomains: [.network])
    }
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)
    let enable = try await backend.waitForTargetMessage(method: "Network.enable")
    let enableID = try modelFeedMessageID(enable.message)
    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: #"{"id":\#(enableID),"result":{}}"#
    ))
    let feed = try await openTask.value
    #expect(try await backend.sentTargetMessages().allSatisfy {
        try modelFeedMessageMethod($0.message) != "DOM.getDocument"
    })
    var iterator = feed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(iterator.next())
    let initialSnapshot = try await modelFeedRequireTargetSnapshot(iterator.next())
    let initialReplay = try await modelFeedRequireReplayCompletion(iterator.next())
    let initialSynchronization = try await modelFeedRequireSynchronization(iterator.next())
    #expect(initialReplay.generation == initialSnapshot.generation)
    #expect(initialReplay.domain == .network)
    #expect(initialReplay.through == initialSnapshot.through)
    #expect(initialSynchronization.generation == initialSnapshot.generation)
    #expect(initialSynchronization.through == initialSnapshot.through)
    let initialTargetState = try #require(initialSnapshot.snapshot.targets.first)
    #expect(initialTargetState.navigationEpoch == ModelNavigationEpoch(rawValue: 0))
    #expect(initialTargetState.domBindingEpoch == nil)

    let targetSequence = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "frame-a",
        type: "frame",
        frameID: "frame-a",
        parentFrameID: "main-frame"
    ))
    let targetEvent = try await modelFeedRequireEvent(iterator.next())
    #expect(targetEvent.sequence == targetSequence)
    #expect(targetEvent.sequence > initialSnapshot.through)
    guard case .target(.targetCreated) = targetEvent.payload else {
        Issue.record("Expected a model targetCreated delta.")
        return
    }
    #expect(targetEvent.target.id == WebInspectorTarget.ID("frame-a"))
    #expect(targetEvent.agentTarget.id == WebInspectorTarget.ID("frame-a"))
    #expect(targetEvent.navigationEpoch == ModelNavigationEpoch(rawValue: 0))
    #expect(targetEvent.domBindingEpoch == nil)

    let navigationSequence = await core.receiveRootMessage(
        modelFeedTargetDispatchMessage(
            targetID: "page-main",
            message: #"{"method":"Page.frameNavigated","params":{"frame":{"id":"main-frame","loaderId":"loader-2","url":"https://example.test/next","securityOrigin":"https://example.test","mimeType":"text/html"}}}"#
        )
    )
    let navigationEvent = try await modelFeedRequireEvent(iterator.next())
    #expect(navigationEvent.sequence == navigationSequence)
    #expect(navigationEvent.target.id == WebInspectorTarget.ID("page-main"))
    #expect(navigationEvent.navigationEpoch == ModelNavigationEpoch(rawValue: 1))
    #expect(navigationEvent.domBindingEpoch == nil)
    guard case .target(.frameNavigated) = navigationEvent.payload else {
        Issue.record("Expected a scoped Page.frameNavigated event.")
        return
    }
    let networkSequence = await core.receiveRootMessage(
        #"{"method":"Network.requestWillBeSent","params":{"requestId":"request-1","frameId":"main-frame","loaderId":"main-loader","request":{"url":"https://example.test","method":"GET"},"initiator":{"type":"other"},"timestamp":1,"type":"Document"}}"#
    )
    let networkEvent = try await modelFeedRequireEvent(iterator.next())
    #expect(networkEvent.sequence == networkSequence)
    guard case let .network(event) = networkEvent.payload else {
        Issue.record("Expected a physical-target Network event.")
        return
    }
    #expect(networkEvent.target.id == WebInspectorTarget.ID("page-main"))
    #expect(networkEvent.agentTarget.id == WebInspectorTarget.ID("page-main"))
    #expect(networkEvent.navigationEpoch == ModelNavigationEpoch(rawValue: 1))
    #expect(networkEvent.domBindingEpoch == nil)
    guard case let .requestWillBeSent(id, _, _, _, _, _) = event else {
        Issue.record("Expected Network.requestWillBeSent.")
        return
    }
    #expect(id == Network.Request.ID("request-1"))

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable", "Network.enable"]
    )
    await core.close()
}

@Test
func modelEventScopeSeparatesPhysicalTargetsAndTracksParentlessFrameNavigationEpochs() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "frame-a",
        type: "page",
        frameID: "frame-a"
    ))

    let feed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [.network],
        targetID: "page-main"
    )
    var iterator = feed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(iterator.next())
    let targetSnapshot = try await modelFeedRequireTargetSnapshot(iterator.next())
    let parentlessFrame = try #require(targetSnapshot.snapshot.targets.first {
        $0.target.id == WebInspectorTarget.ID("frame-a")
    })
    #expect(parentlessFrame.target.kind == .frame)
    _ = try await modelFeedRequireReplayCompletion(iterator.next())
    _ = try await modelFeedRequireSynchronization(iterator.next())

    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: #"{"method":"Network.requestWillBeSent","params":{"requestId":"shared-request","frameId":"main-frame","loaderId":"main-loader","request":{"url":"https://example.test/main","method":"GET"},"initiator":{"type":"other"},"timestamp":1,"type":"Fetch"}}"#
    ))
    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "frame-a",
        message: #"{"method":"Network.requestWillBeSent","params":{"requestId":"shared-request","frameId":"frame-a","loaderId":"frame-loader","request":{"url":"https://example.test/frame","method":"GET"},"initiator":{"type":"other"},"timestamp":2,"type":"Fetch","targetId":"worker-origin"}}"#
    ))
    let mainRequest = try await modelFeedRequireEvent(iterator.next())
    let frameRequest = try await modelFeedRequireEvent(iterator.next())
    #expect(mainRequest.target.id == WebInspectorTarget.ID("page-main"))
    #expect(mainRequest.agentTarget.id == WebInspectorTarget.ID("page-main"))
    #expect(frameRequest.target.id == WebInspectorTarget.ID("frame-a"))
    #expect(frameRequest.agentTarget.id == WebInspectorTarget.ID("frame-a"))
    #expect(mainRequest.navigationEpoch == ModelNavigationEpoch(rawValue: 0))
    #expect(frameRequest.navigationEpoch == ModelNavigationEpoch(rawValue: 0))
    guard case let .network(.requestWillBeSent(mainID, mainPayload, _, _, _, _)) = mainRequest.payload,
          case let .network(.requestWillBeSent(frameID, framePayload, _, _, _, _)) = frameRequest.payload else {
        Issue.record("Expected the same raw Network request from both physical targets.")
        return
    }
    #expect(mainID.targetScopeRawValue == nil)
    #expect(frameID.targetScopeRawValue == "frame-a")
    #expect(mainPayload.origin?.frameID == FrameID("main-frame"))
    #expect(mainPayload.origin?.loaderID == "main-loader")
    #expect(
        mainPayload.origin?.mappedFrameTargetID
            == WebInspectorTarget.ID("page-main")
    )
    #expect(framePayload.origin?.frameID == FrameID("frame-a"))
    #expect(framePayload.origin?.loaderID == "frame-loader")
    #expect(framePayload.origin?.targetID == "worker-origin")
    #expect(
        framePayload.origin?.mappedFrameTargetID
            == WebInspectorTarget.ID("frame-a")
    )

    for (loaderID, expectedEpoch) in [
        ("frame-loader-a", UInt64(1)),
        ("frame-loader-a", UInt64(1)),
        ("frame-loader-b", UInt64(2)),
    ] {
        _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
            targetID: "frame-a",
            message: #"{"method":"Page.frameNavigated","params":{"frame":{"id":"frame-a","loaderId":"\#(loaderID)","url":"https://example.test/frame","securityOrigin":"https://example.test","mimeType":"text/html"}}}"#
        ))
        let navigation = try await modelFeedRequireEvent(iterator.next())
        #expect(navigation.target.id == WebInspectorTarget.ID("frame-a"))
        #expect(navigation.agentTarget.id == WebInspectorTarget.ID("frame-a"))
        #expect(navigation.navigationEpoch == ModelNavigationEpoch(rawValue: expectedEpoch))
        #expect(navigation.domBindingEpoch == nil)
        guard case .target(.frameNavigated) = navigation.payload else {
            Issue.record("Expected a frame-scoped navigation event.")
            return
        }
    }

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable", "Network.enable"]
    )
    #expect(try await iterator.next() == nil)

    let lateFeed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [.network],
        targetID: "page-main"
    )
    var lateIterator = lateFeed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(lateIterator.next())
    let lateSnapshot = try await modelFeedRequireTargetSnapshot(lateIterator.next())
    let lateFrame = try #require(lateSnapshot.snapshot.targets.first {
        $0.target.id == WebInspectorTarget.ID("frame-a")
    })
    #expect(lateFrame.navigationEpoch == ModelNavigationEpoch(rawValue: 2))
    #expect(lateFrame.domBindingEpoch == nil)
    _ = try await modelFeedRequireReplayCompletion(lateIterator.next())
    _ = try await modelFeedRequireSynchronization(lateIterator.next())
    try await modelFeedCloseSuccessfully(
        lateFeed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable", "Network.enable"]
    )
    await core.close()
}

@Test
func modelFeedMapsOrdinarySubframeLifecycleToOwningPageAgents() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "frame-agent",
        type: "frame",
        frameID: "isolated-frame",
        parentFrameID: "main-frame"
    ))

    let feed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [.network],
        targetID: "page-main"
    )
    var iterator = feed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    _ = try await modelFeedRequireReplayCompletion(iterator.next())
    _ = try await modelFeedRequireSynchronization(iterator.next())

    _ = await core.receiveRootMessage(
        #"{"method":"Page.frameNavigated","params":{"frame":{"id":"ordinary-subframe","parentId":"main-frame","loaderId":"subframe-loader","url":"https://example.test/frame","securityOrigin":"https://example.test","mimeType":"text/html"}}}"#
    )
    let navigation = try await modelFeedRequireEvent(iterator.next())
    #expect(navigation.target.id == WebInspectorTarget.ID("page-main"))
    #expect(navigation.agentTarget.id == WebInspectorTarget.ID("page-main"))
    #expect(navigation.navigationEpoch == ModelNavigationEpoch(rawValue: 0))
    guard case let .target(.frameNavigated(frame, isNewLoader)) = navigation.payload else {
        Issue.record("Expected an ordinary-subframe navigation event.")
        return
    }
    #expect(frame.id == FrameID("ordinary-subframe"))
    #expect(isNewLoader)

    _ = await core.receiveRootMessage(
        #"{"method":"Page.frameDetached","params":{"frameId":"ordinary-subframe"}}"#
    )
    let detached = try await modelFeedRequireEvent(iterator.next())
    #expect(detached.target.id == WebInspectorTarget.ID("page-main"))
    #expect(detached.agentTarget.id == WebInspectorTarget.ID("page-main"))
    #expect(detached.navigationEpoch == navigation.navigationEpoch)
    guard case .target(
        .frameDetached(frameID: FrameID("ordinary-subframe"))
    ) = detached.payload else {
        Issue.record("Expected an ordinary-subframe detach event.")
        return
    }
    #expect(await core.terminalCause == nil)

    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "frame-agent",
        message: #"{"method":"Page.frameNavigated","params":{"frame":{"id":"nested-ordinary-subframe","parentId":"isolated-frame","loaderId":"nested-loader","url":"https://example.test/nested","securityOrigin":"https://example.test","mimeType":"text/html"}}}"#
    ))
    let nestedNavigation = try await modelFeedRequireEvent(iterator.next())
    #expect(nestedNavigation.target.id == WebInspectorTarget.ID("frame-agent"))
    #expect(nestedNavigation.agentTarget.id == WebInspectorTarget.ID("frame-agent"))
    #expect(nestedNavigation.navigationEpoch == ModelNavigationEpoch(rawValue: 0))
    guard case let .target(
        .frameNavigated(nestedFrame, isNewNestedLoader)
    ) = nestedNavigation.payload else {
        Issue.record("Expected a nested ordinary-subframe navigation event.")
        return
    }
    #expect(nestedFrame.id == FrameID("nested-ordinary-subframe"))
    #expect(isNewNestedLoader)

    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "frame-agent",
        message: #"{"method":"Page.frameDetached","params":{"frameId":"nested-ordinary-subframe"}}"#
    ))
    let nestedDetached = try await modelFeedRequireEvent(iterator.next())
    #expect(nestedDetached.target.id == WebInspectorTarget.ID("frame-agent"))
    #expect(nestedDetached.agentTarget.id == WebInspectorTarget.ID("frame-agent"))
    #expect(nestedDetached.navigationEpoch == nestedNavigation.navigationEpoch)
    guard case .target(
        .frameDetached(frameID: FrameID("nested-ordinary-subframe"))
    ) = nestedDetached.payload else {
        Issue.record("Expected a nested ordinary-subframe detach event.")
        return
    }
    #expect(await core.terminalCause == nil)

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable", "Network.enable"]
    )
    #expect(try await iterator.next() == nil)
    await core.close()
}

@Test
func modelEventScopeUsesAvailableRuntimeFrameAndAgentWideTargetSeparately() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "frame-a",
        type: "frame",
        frameID: "frame-a",
        parentFrameID: "main-frame"
    ))

    let feed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [.runtime],
        targetID: "page-main"
    )
    var iterator = feed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    _ = try await modelFeedRequireReplayCompletion(iterator.next())
    _ = try await modelFeedRequireSynchronization(iterator.next())

    _ = await core.receiveRootMessage(
        #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":7,"type":"normal","name":"frame context","frameId":"frame-a"}}}"#
    )
    let created = try await modelFeedRequireEvent(iterator.next())
    #expect(created.target.id == WebInspectorTarget.ID("frame-a"))
    #expect(created.agentTarget.id == WebInspectorTarget.ID("page-main"))
    #expect(created.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 0))
    guard case let .runtime(.executionContextCreated(context)) = created.payload else {
        Issue.record("Expected a root Runtime execution-context creation.")
        return
    }
    #expect(context.id == Runtime.ExecutionContext.ID("7"))

    _ = await core.receiveRootMessage(
        #"{"method":"Runtime.executionContextDestroyed","params":{"executionContextId":7}}"#
    )
    let destroyed = try await modelFeedRequireEvent(iterator.next())
    #expect(destroyed.target.id == WebInspectorTarget.ID("page-main"))
    #expect(destroyed.agentTarget.id == created.agentTarget.id)
    #expect(destroyed.target == destroyed.agentTarget)
    #expect(destroyed.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 0))
    guard case let .runtime(.executionContextDestroyed(id)) = destroyed.payload else {
        Issue.record("Expected a root Runtime execution-context destruction.")
        return
    }
    #expect(id == Runtime.ExecutionContext.ID("7"))

    _ = await core.receiveRootMessage(
        #"{"method":"Runtime.executionContextsCleared","params":{}}"#
    )
    let cleared = try await modelFeedRequireEvent(iterator.next())
    #expect(cleared.target.id == WebInspectorTarget.ID("page-main"))
    #expect(cleared.agentTarget.id == created.agentTarget.id)
    #expect(cleared.target == cleared.agentTarget)
    #expect(cleared.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 1))
    guard case .runtime(.executionContextsCleared) = cleared.payload else {
        Issue.record("Expected a root Runtime execution-context clear.")
        return
    }

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable", "Runtime.enable"]
    )
    #expect(try await iterator.next() == nil)
    await core.close()
}

@Test
func modelEventScopeUsesDispatchSourceAsRuntimeAgentTarget() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "frame-a",
        type: "frame",
        frameID: "frame-a",
        parentFrameID: "main-frame"
    ))

    let feed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [.runtime],
        targetID: "page-main"
    )
    var iterator = feed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    _ = try await modelFeedRequireReplayCompletion(iterator.next())
    _ = try await modelFeedRequireSynchronization(iterator.next())

    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "frame-a",
        message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":8,"type":"normal","name":"isolated frame","frameId":"frame-a"}}}"#
    ))
    let created = try await modelFeedRequireEvent(iterator.next())
    #expect(created.target.id == WebInspectorTarget.ID("frame-a"))
    #expect(created.agentTarget.id == WebInspectorTarget.ID("frame-a"))
    #expect(created.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 0))
    guard case let .runtime(.executionContextCreated(context)) = created.payload else {
        Issue.record("Expected a target-dispatched Runtime execution-context creation.")
        return
    }
    #expect(context.id.targetScopeRawValue == "frame-a")

    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "frame-a",
        message: #"{"method":"Runtime.executionContextDestroyed","params":{"executionContextId":8}}"#
    ))
    let destroyed = try await modelFeedRequireEvent(iterator.next())
    #expect(destroyed.target.id == WebInspectorTarget.ID("frame-a"))
    #expect(destroyed.agentTarget.id == created.agentTarget.id)
    #expect(destroyed.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 0))

    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "frame-a",
        message: #"{"method":"Runtime.executionContextsCleared","params":{}}"#
    ))
    let cleared = try await modelFeedRequireEvent(iterator.next())
    #expect(cleared.target.id == WebInspectorTarget.ID("frame-a"))
    #expect(cleared.agentTarget.id == created.agentTarget.id)
    #expect(cleared.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 1))

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable", "Runtime.enable"]
    )
    #expect(try await iterator.next() == nil)
    await core.close()
}

@Test
func consoleNetworkReferenceAndNetworkEventUseTheSameAgentTargetScope() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "frame-a",
        type: "frame",
        frameID: "frame-a",
        parentFrameID: "main-frame"
    ))

    let feed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [.network, .console],
        targetID: "page-main"
    )
    var iterator = feed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    _ = try await modelFeedRequireReplayCompletion(iterator.next())
    _ = try await modelFeedRequireReplayCompletion(iterator.next())
    _ = try await modelFeedRequireSynchronization(iterator.next())

    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "frame-a",
        message: #"{"method":"Network.requestWillBeSent","params":{"requestId":"shared-request","frameId":"frame-a","loaderId":"frame-loader","request":{"url":"https://example.test/frame","method":"GET"},"initiator":{"type":"other"},"timestamp":1,"type":"Fetch"}}"#
    ))
    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "frame-a",
        message: #"{"method":"Console.messageAdded","params":{"message":{"source":"network","level":"error","text":"failed","networkRequestId":"shared-request"}}}"#
    ))
    let network = try await modelFeedRequireEvent(iterator.next())
    let console = try await modelFeedRequireEvent(iterator.next())
    #expect(network.agentTarget.id == WebInspectorTarget.ID("frame-a"))
    #expect(console.agentTarget == network.agentTarget)
    #expect(network.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 0))
    #expect(console.runtimeBindingEpoch == network.runtimeBindingEpoch)
    #expect(network.consoleBindingEpoch == ModelConsoleBindingEpoch(rawValue: 0))
    #expect(console.consoleBindingEpoch == network.consoleBindingEpoch)
    guard case let .network(.requestWillBeSent(networkID, _, _, _, _, _)) = network.payload,
          case let .console(.messageAdded(message)) = console.payload else {
        Issue.record("Expected related Network and Console model events.")
        return
    }
    #expect(message.networkRequestID == networkID)
    #expect(networkID.targetScopeRawValue == "frame-a")

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: [
            "Page.enable",
            "Network.enable",
            "Runtime.enable",
            "Console.enable",
        ]
    )
    #expect(try await iterator.next() == nil)
    await core.close()
}

@Test
func modelFeedRejectsAnEventFromAnAgentTargetAfterTargetLoss() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "frame-a",
        type: "frame",
        frameID: "frame-a",
        parentFrameID: "main-frame"
    ))
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "frame-b",
        type: "frame",
        frameID: "frame-b",
        parentFrameID: "main-frame"
    ))

    let feed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [.runtime],
        targetID: "page-main"
    )
    var iterator = feed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    _ = try await modelFeedRequireReplayCompletion(iterator.next())
    _ = try await modelFeedRequireSynchronization(iterator.next())

    _ = await core.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"frame-a"}}"#
    )
    let destroyed = try await modelFeedRequireEvent(iterator.next())
    guard case .target(.targetDestroyed) = destroyed.payload else {
        Issue.record("Expected target loss before the late Runtime event.")
        return
    }
    #expect(destroyed.target.id == WebInspectorTarget.ID("frame-a"))
    #expect(destroyed.agentTarget.id == WebInspectorTarget.ID("frame-a"))

    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "frame-a",
        message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":9,"type":"normal","name":"late","frameId":"frame-b"}}}"#
    ))

    guard await core.terminalCause != nil else {
        Issue.record("The late Runtime event did not terminate the model feed.")
        await core.close()
        return
    }
    await #expect(throws: WebInspectorProxyError.self) {
        try await core.waitUntilClosed()
    }
    guard case let .protocolViolation(message) = await core.terminalCause else {
        Issue.record("Expected a missing model agent target to terminate the connection.")
        return
    }
    #expect(message.contains("Runtime.executionContextCreated"))
    await #expect(throws: WebInspectorProxyError.self) {
        try await iterator.next()
    }
    #expect(await backend.isDetached())
    _ = feed
}

@Test
func navigationEpochRejectsInflightDOMAndCSSBootstrapReplies() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let openTask = Task {
        try await core.openModelFeed(configuredDomains: [.css])
    }
    let staleDOM = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        ordinal: 0
    )
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)
    let cssEnable = try await backend.waitForTargetMessage(method: "CSS.enable")
    await modelFeedRespond(to: cssEnable, core: core)
    let staleCSS = try await backend.waitForTargetMessage(
        method: "CSS.getAllStyleSheets",
        ordinal: 0
    )

    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: #"{"method":"Page.frameNavigated","params":{"frame":{"id":"main-frame","loaderId":"new-loader","url":"https://example.test/new","securityOrigin":"https://example.test","mimeType":"text/html"}}}"#
    ))
    await modelFeedRespondWithDocument(
        to: staleDOM,
        core: core,
        nodeID: "stale-document"
    )
    let freshDOM = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        ordinal: 1
    )
    await modelFeedRespondWithStyleSheets(
        to: staleCSS,
        core: core,
        styleSheetID: "stale-sheet"
    )
    let freshCSS = try await backend.waitForTargetMessage(
        method: "CSS.getAllStyleSheets",
        ordinal: 1
    )
    await modelFeedRespondWithDocument(
        to: freshDOM,
        core: core,
        nodeID: "fresh-document"
    )
    await modelFeedRespondWithStyleSheets(
        to: freshCSS,
        core: core,
        styleSheetID: "fresh-sheet"
    )

    let feed = try await openTask.value
    var iterator = feed.records.makeAsyncIterator()
    let generation = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    let navigation = try await modelFeedRequireEvent(iterator.next())
    #expect(navigation.navigationEpoch == ModelNavigationEpoch(rawValue: 1))
    guard case .target(.frameNavigated) = navigation.payload else {
        Issue.record("Expected the navigation boundary before fresh bootstraps.")
        return
    }
    let domSnapshot = try await modelFeedRequireDOMBootstrapSnapshot(iterator.next())
    #expect(domSnapshot.generation == generation)
    #expect(domSnapshot.navigationEpoch == ModelNavigationEpoch(rawValue: 1))
    #expect(domSnapshot.root.id == DOM.Node.ID("fresh-document"))
    #expect(try await modelFeedRequireBootstrapCompletion(iterator.next()).domain == .dom)
    let styleSheets = try await modelFeedRequireCSSBootstrapSnapshot(iterator.next())
    #expect(styleSheets.count == 1)
    let styleSheet = try #require(styleSheets.first)
    #expect(styleSheet.scope.navigationEpoch == ModelNavigationEpoch(rawValue: 1))
    #expect(styleSheet.header.styleSheetID.rawValue == "fresh-sheet")
    #expect(try await modelFeedRequireBootstrapCompletion(iterator.next()).domain == .css)
    _ = try await modelFeedRequireSynchronization(iterator.next())

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable", "CSS.enable"]
    )
    #expect(try await iterator.next() == nil)
    await core.close()
}

@Test
func modelNavigationWithoutLoaderIDTerminatesAsProtocolViolation() async throws {
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
    _ = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    _ = try await modelFeedRequireReplayCompletion(iterator.next())
    _ = try await modelFeedRequireSynchronization(iterator.next())

    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: #"{"method":"Page.frameNavigated","params":{"frame":{"id":"main-frame","url":"https://example.test/missing-loader","securityOrigin":"https://example.test","mimeType":"text/html"}}}"#
    ))

    await #expect(throws: WebInspectorProxyError.self) {
        try await core.waitUntilClosed()
    }
    guard case let .protocolViolation(message) = await core.terminalCause else {
        Issue.record("Expected a loader-less navigation to terminate the model feed.")
        return
    }
    #expect(message.contains("Page.frameNavigated"))
    await #expect(throws: WebInspectorProxyError.self) {
        try await iterator.next()
    }
    #expect(await backend.isDetached())
    _ = feed
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
        try await core.openModelFeed(configuredDomains: [.network])
    }
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)
    let enable = try await backend.waitForTargetMessage(method: "Network.enable")

    let replayedEventSequence = await core.receiveRootMessage(
        modelFeedTargetDispatchMessage(
            targetID: "page-main",
            message: #"{"method":"Network.requestWillBeSent","params":{"requestId":"enable-replay","frameId":"main-frame","loaderId":"main-loader","request":{"url":"https://example.test/replay","method":"GET"},"initiator":{"type":"other"},"timestamp":1,"type":"Document"}}"#
        )
    )
    await modelFeedRespond(to: enable, core: core)
    let feed = try await openTask.value

    var iterator = feed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(iterator.next())
    let snapshot = try await modelFeedRequireTargetSnapshot(iterator.next())
    let replayedEvent = try await modelFeedRequireEvent(iterator.next())
    let replayCompletion = try await modelFeedRequireReplayCompletion(iterator.next())
    let synchronization = try await modelFeedRequireSynchronization(iterator.next())

    #expect(replayedEvent.sequence == replayedEventSequence)
    #expect(replayedEvent.sequence > snapshot.through)
    guard case let .network(event) = replayedEvent.payload,
          case let .requestWillBeSent(id, _, _, _, _, _) = event else {
        Issue.record("Expected the enable-time Network event before replay completion.")
        return
    }
    #expect(id == Network.Request.ID("enable-replay"))
    #expect(replayCompletion.generation == snapshot.generation)
    #expect(replayCompletion.domain == .network)
    #expect(replayCompletion.through == replayedEventSequence)
    #expect(synchronization.generation == snapshot.generation)
    #expect(synchronization.through == replayedEventSequence)

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable", "Network.enable"]
    )
    #expect(try await iterator.next() == nil)
    await core.close()
}

@Test
func cleanModelFeedCloseReleasesClaimForAReplacementFeed() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))

    let firstFeed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [],
        targetID: "page-main"
    )
    var firstIterator = firstFeed.records.makeAsyncIterator()
    _ = try await firstIterator.next()
    _ = try await firstIterator.next()
    _ = try await firstIterator.next()
    try await modelFeedCloseSuccessfully(
        firstFeed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable"]
    )
    #expect(try await firstIterator.next() == nil)

    let replacementFeed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [],
        targetID: "page-main"
    )
    var replacementIterator = replacementFeed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(replacementIterator.next())
    _ = try await modelFeedRequireTargetSnapshot(replacementIterator.next())
    _ = try await modelFeedRequireSynchronization(replacementIterator.next())
    try await modelFeedCloseSuccessfully(
        replacementFeed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable"]
    )
    #expect(try await replacementIterator.next() == nil)
    await core.close()
}

@Test
func cancelledIteratorRequiresExplicitFeedCloseBeforeReplacement() async throws {
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
        configuredDomains: [],
        targetID: "page-main"
    )
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
        try await core.openModelFeed(configuredDomains: [])
    }

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable"]
    )
    let replacementFeed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [],
        targetID: "page-main"
    )
    var replacementIterator = replacementFeed.records.makeAsyncIterator()
    _ = try await replacementIterator.next()
    _ = try await replacementIterator.next()
    _ = try await replacementIterator.next()
    try await modelFeedCloseSuccessfully(
        replacementFeed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable"]
    )
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
        try await core.openModelFeed(configuredDomains: [])
    }

    let commandID = try modelFeedMessageID(sentMessage)
    _ = await core.receiveRootMessage(#"{"id":\#(commandID),"result":{}}"#)
    _ = try await commandTask.value
    await #expect(throws: ConnectionModelFeedError.connectionAlreadyUsedByDirectConsumer) {
        try await core.openModelFeed(configuredDomains: [])
    }
    await core.close()
}

@Test
func modelFeedAndDirectConsumersClaimConnectionExclusivelyInBothOrders() async throws {
    let directFirstCore = ConnectionCore(backend: FakeTransportBackend(), responseTimeout: nil)
    _ = await directFirstCore.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    _ = try await directFirstCore.send(ProtocolCommand(
        domain: .dom,
        method: "DOM.enable",
        routing: .octopus(pageTarget: nil)
    ))
    await #expect(throws: ConnectionModelFeedError.connectionAlreadyUsedByDirectConsumer) {
        try await directFirstCore.openModelFeed(configuredDomains: [])
    }
    await directFirstCore.close()

    let feedFirstBackend = FakeTransportBackend()
    let feedFirstCore = ConnectionCore(
        backend: feedFirstBackend,
        responseTimeout: nil
    )
    _ = await feedFirstCore.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let feed = try await modelFeedOpenSuccessfully(
        core: feedFirstCore,
        backend: feedFirstBackend,
        configuredDomains: [],
        targetID: "page-main"
    )
    await #expect(throws: ConnectionModelFeedError.alreadyOpen) {
        try await feedFirstCore.openModelFeed(configuredDomains: [])
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

    try await modelFeedCloseSuccessfully(
        feed,
        core: feedFirstCore,
        backend: feedFirstBackend,
        targetID: "page-main",
        enableMethods: ["Page.enable"]
    )
    try await feed.close()
    await feedFirstCore.close()
}

@Test
func explicitConnectionCloseFinishesModelFeedOnlyAfterCloseQuiescence() async throws {
    let closeGate = ModelFeedAsyncGate()
    let backend = FakeTransportBackend()
    let core = ConnectionCore(
        backend: backend,
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
    let feed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [],
        targetID: "page-main"
    )
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
    let fatalBackend = FakeTransportBackend()
    let fatalCore = ConnectionCore(backend: fatalBackend, responseTimeout: nil)
    _ = await fatalCore.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let fatalFeed = try await modelFeedOpenSuccessfully(
        core: fatalCore,
        backend: fatalBackend,
        configuredDomains: [],
        targetID: "page-main"
    )
    var fatalIterator = fatalFeed.records.makeAsyncIterator()
    _ = try await fatalIterator.next()
    _ = try await fatalIterator.next()
    _ = try await fatalIterator.next()
    let fatalHandoff = try #require(fatalCore.failFromNativeCallback("feed fatal"))
    await fatalHandoff.value
    await #expect(throws: WebInspectorProxyError.transportFailure("feed fatal")) {
        try await fatalIterator.next()
    }

    let protocolBackend = FakeTransportBackend()
    let protocolCore = ConnectionCore(
        backend: protocolBackend,
        responseTimeout: nil
    )
    _ = await protocolCore.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let protocolFeed = try await modelFeedOpenSuccessfully(
        core: protocolCore,
        backend: protocolBackend,
        configuredDomains: [],
        targetID: "page-main"
    )
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
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    var feed: ConnectionModelFeed? = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [],
        targetID: "page-main"
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
        try await core.openModelFeed(configuredDomains: [])
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
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    let registeredFeed = Mutex<ConnectionModelFeed?>(nil)
    let feedRegistered = ModelFeedProbe()
    let openTask = Task {
        try await core.openModelFeed(
            configuredDomains: [],
            onRegistered: { feed in
                registeredFeed.withLock { $0 = feed }
                await feedRegistered.finish()
                return true
            }
        )
    }
    await feedRegistered.waitUntilFinished()
    let feed = try #require(registeredFeed.withLock { $0 })
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
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)
    _ = try await openTask.value
    let generation = try await generationTask.value
    let snapshot = try await modelFeedRequireTargetSnapshot(iterator.next())

    #expect(generation == reset)
    #expect(snapshot.generation == reset)
    #expect(snapshot.through == eventSequence)

    await core.replaceModelTargetMutationActionForTesting(nil)
    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable"]
    )
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
    let pendingPurposes = await core.pendingReplyPurposes()

    #expect(replacement.targetID == ProtocolTarget.ID("page-new"))
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
        "Page.enable",
        "CSS.enable",
        "Network.enable",
        "Runtime.enable",
        "Console.enable",
    ])
    #expect(try await modelFeedSentTargetMethods(backend) == enableMethods)

    var iterator = feed.records.makeAsyncIterator()
    let reset = try await modelFeedRequireReset(iterator.next())
    let snapshot = try await modelFeedRequireTargetSnapshot(iterator.next())
    #expect(snapshot.generation == reset)
    let bootstrapSnapshot = try await modelFeedRequireDOMBootstrapSnapshot(iterator.next())
    var bootstrapCompletions: [ModelFeedBootstrapCompletionRecord] = []
    var cssSnapshot: [ModelCSSStyleSheet]?
    var replayCompletions: [ModelFeedReplayCompletionRecord] = []
    for _ in 0..<6 {
        let record = try #require(await iterator.next())
        switch record {
        case .bootstrapComplete:
            bootstrapCompletions.append(
                try modelFeedRequireBootstrapCompletion(record)
            )
        case .bootstrapSnapshot:
            #expect(cssSnapshot == nil)
            cssSnapshot = try modelFeedRequireCSSBootstrapSnapshot(record)
        case .replayComplete:
            replayCompletions.append(try modelFeedRequireReplayCompletion(record))
        default:
            Issue.record("Expected DOM/CSS bootstrap or replay completion.")
        }
    }
    #expect(replayCompletions.map(\.domain) == [
        .network,
        .runtime,
        .console,
    ])
    #expect(replayCompletions.allSatisfy {
        $0.generation == reset && $0.through == snapshot.through
    })
    let synchronization = try await modelFeedRequireSynchronization(iterator.next())
    #expect(bootstrapSnapshot.generation == reset)
    #expect(bootstrapSnapshot.target.id == WebInspectorTarget.ID("page-main"))
    #expect(bootstrapSnapshot.documentEpoch == ModelDOMBindingEpoch(rawValue: 0))
    #expect(cssSnapshot?.count == 1)
    #expect(bootstrapCompletions.map(\.domain) == [.dom, .css])
    #expect(bootstrapCompletions.allSatisfy { $0.generation == reset })
    #expect(synchronization.generation == reset)

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
    let pageKey = ConnectionCapabilityKey(
        route: .currentPage,
        targetID: .currentPage,
        domain: .page
    )
    #expect(owners[pageKey] == Set([.modelFeedNavigation(feed.id)]))
    for domain in [
        WebInspectorProxyEventDomain.css,
        .network,
        .console,
    ] {
        let key = ConnectionCapabilityKey(
            route: .currentPage,
            targetID: .currentPage,
            domain: domain
        )
        #expect(owners[key]?.count == 1)
    }
    let runtimeKey = ConnectionCapabilityKey(
        route: .currentPage,
        targetID: .currentPage,
        domain: .runtime
    )
    #expect(owners[runtimeKey] == Set([
        .modelFeed(feed.id, .runtime),
        .modelFeed(feed.id, .console),
    ]))

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: enableMethods
    )
    #expect(try await modelFeedSentTargetMethods(backend) == enableMethods + [
        "Console.disable",
        "Runtime.disable",
        "Network.disable",
        "CSS.disable",
        "Page.disable",
    ])
    // Page is observation-only, DOM/CSS use authoritative bootstrap records,
    // and replay-only domains each emit exactly one marker.
    #expect(try await iterator.next() == nil)
    #expect(await modelFeedAllCapabilityLeaseOwners(core).isEmpty)
    await core.close()
}

@Test
func registeredModelFeedConsumerDrainsEnableReplayBeforeOpenReturns() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))

    let consumerTask = Mutex<Task<[ConnectionModelFeedRecord], any Error>?>(nil)
    let openTask = Task {
        try await core.openModelFeed(
            configuredDomains: [.network],
            onRegistered: { feed in
                let task = Task {
                    var records: [ConnectionModelFeedRecord] = []
                    for try await record in feed.records {
                        records.append(record)
                        if case .synchronizationComplete = record {
                            return records
                        }
                    }
                    Issue.record("The model feed ended before synchronization.")
                    return records
                }
                consumerTask.withLock { value in
                    value = task
                }
                return true
            }
        )
    }
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)
    let enable = try await backend.waitForTargetMessage(method: "Network.enable")

    let replayEventCount = 512
    for index in 0..<replayEventCount {
        _ = await core.receiveRootMessage(
            modelFeedTargetDispatchMessage(
                targetID: "page-main",
                message: #"{"method":"Network.requestWillBeSent","params":{"requestId":"request-\#(index)","frameId":"main-frame","loaderId":"main-loader","request":{"url":"https://example.test/\#(index)","method":"GET"},"initiator":{"type":"other"},"timestamp":\#(index),"type":"Fetch"}}"#
            )
        )
    }
    await modelFeedRespond(to: enable, core: core)

    let feed = try await openTask.value
    let registeredConsumer = consumerTask.withLock { $0 }
    let records = try await #require(registeredConsumer).value
    let eventRecords = records.compactMap { record -> ModelProtocolEvent? in
        guard case let .event(_, _, payload) = record else {
            return nil
        }
        return payload
    }
    #expect(eventRecords.count == replayEventCount)
    #expect(await core.terminalCause == nil)

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable", "Network.enable"]
    )
    await core.close()
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
            configuredDomains: [.network]
        )
    }
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)
    let enable = try await backend.waitForTargetMessage(method: "Network.enable")
    await modelFeedRespond(
        to: enable,
        core: core,
        errorMessage: "enable rejected"
    )
    let pageDisable = try await backend.waitForTargetMessage(method: "Page.disable")
    await modelFeedRespond(to: pageDisable, core: core)

    await #expect(throws: ConnectionModelFeedError.bootstrapFailed(
        domain: .network,
        message: "enable rejected"
    )) {
        try await openTask.value
    }
    #expect(await core.terminalCause == nil)
    #expect(await backend.isDetached() == false)

    let replacement = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [],
        targetID: "page-main"
    )
    try await modelFeedCloseSuccessfully(
        replacement,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable"]
    )
    await core.close()
}

@Test
func modelFeedActivationPageUnavailableRemainsConnectionLifecycleError() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    await backend.setSendError(WebInspectorProxyError.pageUnavailable)

    await #expect(throws: WebInspectorProxyError.pageUnavailable) {
        try await core.openModelFeed(configuredDomains: [.network])
    }
    #expect(await core.terminalCause == nil)
    #expect(await backend.isDetached() == false)

    await backend.setSendError(nil)
    let replacement = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [],
        targetID: "page-main"
    )
    try await modelFeedCloseSuccessfully(
        replacement,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable"]
    )
    await core.close()
}

@Test(arguments: [
    WebInspectorProxyError.transportFailure("activation transport failed"),
    WebInspectorProxyError.protocolViolation("activation reply malformed"),
])
func modelFeedActivationTerminalErrorIsNotRelabeledAsBootstrap(
    activationError: WebInspectorProxyError
) async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    await backend.setSendError(activationError)

    do {
        _ = try await core.openModelFeed(configuredDomains: [.network])
        Issue.record("Expected activation to terminate the connection.")
    } catch let error as WebInspectorScopeError {
        #expect(error.operationError as? WebInspectorProxyError == activationError)
        #expect((error.operationError is ConnectionModelFeedError) == false)
        #expect((error.cleanupError is ConnectionModelFeedError) == false)
    } catch {
        Issue.record("Expected WebInspectorScopeError, got \(error).")
    }
    await #expect(throws: WebInspectorProxyError.self) {
        try await core.waitUntilClosed()
    }
    #expect(await backend.isDetached())
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
            configuredDomains: [.network]
        )
    }
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)
    let enable = try await backend.waitForTargetMessage(method: "Network.enable")

    openTask.cancel()
    #expect(await modelFeedWaitForNoDesiredCapabilityOwners(core, key: key))
    await modelFeedRespond(to: enable, core: core)
    let disable = try await backend.waitForTargetMessage(method: "Network.disable")
    await modelFeedRespond(to: disable, core: core)
    let pageDisable = try await backend.waitForTargetMessage(method: "Page.disable")
    await modelFeedRespond(to: pageDisable, core: core)

    await #expect(throws: CancellationError.self) {
        try await openTask.value
    }
    #expect(await core.terminalCause == nil)
    #expect(await backend.isDetached() == false)
    #expect(await modelFeedAllCapabilityLeaseOwners(core).isEmpty)

    let replacement = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [],
        targetID: "page-main"
    )
    try await modelFeedCloseSuccessfully(
        replacement,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable"]
    )
    await core.close()
}

@Test(arguments: [1, 2, 3, 4])
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
    let enableModelDomains: [ModelDomain] = [
        .css,
        .css,
        .network,
        .runtime,
        .console,
    ]
    let openTask = Task {
        try await core.openModelFeed(
            configuredDomains: configuredDomains
        )
    }

    for index in 0...failureIndex {
        let message = try await backend.waitForTargetMessage(
            method: enableMethods[index]
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
            if enableMethods[index] == "CSS.enable" {
                let snapshot = try await backend.waitForTargetMessage(
                    method: "CSS.getAllStyleSheets"
                )
                await modelFeedRespondWithStyleSheets(
                    to: snapshot,
                    core: core
                )
            }
        }
    }

    let rollbackMethods = Array(enableMethods[..<failureIndex].reversed()).map {
        $0.replacingOccurrences(of: ".enable", with: ".disable")
    }
    for expectedMethod in rollbackMethods {
        let message = try await backend.waitForTargetMessage(
            method: expectedMethod
        )
        #expect(try modelFeedMessageMethod(message.message) == expectedMethod)
        await modelFeedRespond(to: message, core: core)
    }

    do {
        _ = try await openTask.value
        Issue.record("Expected configured capability acquisition to fail.")
    } catch {
        #expect(error as? ConnectionModelFeedError == .bootstrapFailed(
            domain: enableModelDomains[failureIndex],
            message: "rejected-\(failureIndex)"
        ))
    }
    #expect(try await modelFeedSentTargetMethods(backend) == Array(
        enableMethods[...failureIndex]
    ) + rollbackMethods)
    #expect(await modelFeedAllCapabilityLeaseOwners(core).isEmpty)

    let replacementFeed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [],
        targetID: "page-main"
    )
    try await modelFeedCloseSuccessfully(
        replacementFeed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable"]
    )
    await core.close()
}

@Test
func modelFeedRollbackCancelsPendingCSSAuthoritativeSnapshot() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let openTask = Task {
        try await core.openModelFeed(configuredDomains: [.css, .network])
    }

    let initialDocument = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        ordinal: 0
    )
    await modelFeedRespondWithDocument(to: initialDocument, core: core)
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)
    let cssEnable = try await backend.waitForTargetMessage(method: "CSS.enable")
    await modelFeedRespond(to: cssEnable, core: core)
    let initialCSSSnapshot = try await backend.waitForTargetMessage(
        method: "CSS.getAllStyleSheets",
        ordinal: 0
    )
    await modelFeedRespondWithStyleSheets(to: initialCSSSnapshot, core: core)
    let networkEnable = try await backend.waitForTargetMessage(method: "Network.enable")

    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: #"{"method":"DOM.documentUpdated","params":{}}"#
    ))
    _ = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        ordinal: 1
    )
    _ = try await backend.waitForTargetMessage(
        method: "CSS.getAllStyleSheets",
        ordinal: 1
    )

    await modelFeedRespond(
        to: networkEnable,
        core: core,
        errorMessage: "network rejected"
    )
    let cssDisable = try await backend.waitForTargetMessage(method: "CSS.disable")
    await modelFeedRespond(to: cssDisable, core: core)
    let pageDisable = try await backend.waitForTargetMessage(method: "Page.disable")
    await modelFeedRespond(to: pageDisable, core: core)

    await #expect(throws: ConnectionModelFeedError.bootstrapFailed(
        domain: .network,
        message: "network rejected"
    )) {
        try await openTask.value
    }
    #expect(await core.pendingReplyPurposes().isEmpty)
    #expect(await modelFeedAllCapabilityLeaseOwners(core).isEmpty)
    #expect(await backend.isDetached() == false)
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
            configuredDomains: [.network]
        )
    }
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)
    let enable = try await backend.waitForTargetMessage(method: "Network.enable")

    openTask.cancel()
    await modelFeedRespond(to: enable, core: core)
    let disable = try await backend.waitForTargetMessage(method: "Network.disable")
    await modelFeedRespond(to: disable, core: core)
    let pageDisable = try await backend.waitForTargetMessage(method: "Page.disable")
    await modelFeedRespond(to: pageDisable, core: core)

    await #expect(throws: CancellationError.self) {
        try await openTask.value
    }
    #expect(try await modelFeedSentTargetMethods(backend) == [
        "Page.enable",
        "Network.enable",
        "Network.disable",
        "Page.disable",
    ])
    #expect(await modelFeedAllCapabilityLeaseOwners(core).isEmpty)
    let replacementFeed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [],
        targetID: "page-main"
    )
    try await modelFeedCloseSuccessfully(
        replacementFeed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable"]
    )
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
    duplicateClose.cancel()

    await #expect(throws: ConnectionModelFeedError.alreadyOpen) {
        try await core.openModelFeed(configuredDomains: [])
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
    let pageDisable = try await backend.waitForTargetMessage(method: "Page.disable")
    #expect(await duplicateFinished.isFinished == false)
    await modelFeedRespond(to: pageDisable, core: core)
    try await firstClose.value
    try await duplicateClose.value
    try await feed.close()

    let replacementFeed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [],
        targetID: "page-main"
    )
    try await modelFeedCloseSuccessfully(
        replacementFeed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable"]
    )

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
            configuredDomains: [.network]
        )
    }
    let oldPageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    #expect(oldPageEnable.targetIdentifier == ProtocolTarget.ID("page-old"))
    await modelFeedRespond(to: oldPageEnable, core: core)
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
    let newPageEnable = try await backend.waitForTargetMessage(
        method: "Page.enable",
        ordinal: 1
    )
    #expect(newPageEnable.targetIdentifier == ProtocolTarget.ID("page-new"))
    await modelFeedRespond(to: newPageEnable, core: core)
    let newEnable = try await backend.waitForTargetMessage(
        method: "Network.enable",
        ordinal: 1
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
        .modelFeedNavigation(feed.id),
        .modelFeed(feed.id, .network),
    ]))
    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-new",
        enableMethods: ["Page.enable", "Network.enable"]
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
    let initialSynchronization = try await modelFeedRequireSynchronization(iterator.next())
    #expect(initialReplay.generation == initialSnapshot.generation)
    #expect(initialReplay.domain == .network)
    #expect(initialReplay.through == initialSnapshot.through)
    #expect(initialSynchronization.generation == initialSnapshot.generation)

    _ = await core.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"page-old"}}"#
    )
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-new",
        type: "page",
        frameID: "main-frame"
    ))
    let replacementPageEnable = try await backend.waitForTargetMessage(
        method: "Page.enable",
        ordinal: 1
    )
    #expect(replacementPageEnable.targetIdentifier == ProtocolTarget.ID("page-new"))
    await modelFeedRespond(to: replacementPageEnable, core: core)
    let replacementEnable = try await backend.waitForTargetMessage(
        method: "Network.enable",
        ordinal: 1
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
        .modelFeedNavigation(feed.id),
        .modelFeed(feed.id, .network),
    ]))
    let replacementEventSequence = await core.receiveRootMessage(
        modelFeedTargetDispatchMessage(
            targetID: "page-new",
            message: #"{"method":"Network.requestWillBeSent","params":{"requestId":"replacement-replay","frameId":"main-frame","loaderId":"replacement-loader","request":{"url":"https://example.test/replacement","method":"GET"},"initiator":{"type":"other"},"timestamp":2,"type":"Document"}}"#
        )
    )
    await modelFeedRespond(to: replacementEnable, core: core)

    let replacementReset = try await modelFeedRequireReset(iterator.next())
    let replacementSnapshot = try await modelFeedRequireTargetSnapshot(iterator.next())
    let replacementEvent = try await modelFeedRequireEvent(iterator.next())
    let replacementReplay = try await modelFeedRequireReplayCompletion(iterator.next())
    let replacementSynchronization = try await modelFeedRequireSynchronization(iterator.next())
    #expect(replacementReset.rawValue == initialSnapshot.generation.rawValue + 1)
    #expect(replacementSnapshot.generation == replacementReset)
    #expect(replacementEvent.generation == replacementReset)
    #expect(replacementEvent.sequence == replacementEventSequence)
    #expect(replacementEvent.sequence > replacementSnapshot.through)
    #expect(replacementReplay.generation == replacementReset)
    #expect(replacementReplay.domain == .network)
    #expect(replacementReplay.through == replacementEventSequence)
    #expect(replacementSynchronization.generation == replacementReset)
    #expect(replacementSynchronization.through == replacementEventSequence)

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-new",
        enableMethods: ["Page.enable", "Network.enable"]
    )
    #expect(try await iterator.next() == nil)
    await core.close()
}

@Test
func restoredPageTargetReusesPageAgentAndRefreshesReplayDomains() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-a",
        type: "page",
        frameID: "main-frame"
    ))
    let configuredDomains: Set<ModelDomain> = [
        .css,
        .network,
        .console,
        .runtime,
    ]
    let feed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: configuredDomains,
        targetID: "page-a"
    )
    var iterator = feed.records.makeAsyncIterator()

    _ = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    _ = try await modelFeedRequireDOMBootstrapSnapshot(iterator.next())
    _ = try await modelFeedRequireBootstrapCompletion(iterator.next())
    _ = try await modelFeedRequireCSSBootstrapSnapshot(iterator.next())
    #expect(try await modelFeedRequireBootstrapCompletion(iterator.next()).domain == .css)
    for domain in [ModelDomain.network, .runtime, .console] {
        #expect(try await modelFeedRequireReplayCompletion(iterator.next()).domain == domain)
    }
    _ = try await modelFeedRequireSynchronization(iterator.next())

    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-b",
        type: "page",
        frameID: "main-frame",
        isProvisional: true
    ))
    let pageBCommitBaseline = await backend.sentTargetMessages().count
    _ = await core.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-a","newTargetId":"page-b"}}"#
    )

    let pageBDocument = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        after: pageBCommitBaseline
    )
    await modelFeedRespondWithDocument(to: pageBDocument, core: core, nodeID: "page-b")
    for method in [
        "Page.enable",
        "CSS.enable",
        "Network.enable",
        "Runtime.enable",
        "Console.enable",
    ] {
        let message = try await backend.waitForTargetMessage(
            method: method,
            after: pageBCommitBaseline
        )
        #expect(message.targetIdentifier == ProtocolTarget.ID("page-b"))
        await modelFeedRespond(to: message, core: core)
        if method == "CSS.enable" {
            let snapshot = try await backend.waitForTargetMessage(
                method: "CSS.getAllStyleSheets",
                after: pageBCommitBaseline
            )
            await modelFeedRespondWithStyleSheets(to: snapshot, core: core)
        }
    }

    _ = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    _ = try await modelFeedRequireDOMBootstrapSnapshot(iterator.next())
    _ = try await modelFeedRequireBootstrapCompletion(iterator.next())
    _ = try await modelFeedRequireCSSBootstrapSnapshot(iterator.next())
    #expect(try await modelFeedRequireBootstrapCompletion(iterator.next()).domain == .css)
    for domain in [ModelDomain.network, .runtime, .console] {
        #expect(try await modelFeedRequireReplayCompletion(iterator.next()).domain == domain)
    }
    _ = try await modelFeedRequireSynchronization(iterator.next())

    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-a",
        type: "page",
        frameID: "main-frame",
        isProvisional: true
    ))
    let restorationBaseline = await backend.sentTargetMessages().count
    _ = await core.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-b","newTargetId":"page-a"}}"#
    )

    let restoredDocument = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        after: restorationBaseline
    )
    await modelFeedRespondWithDocument(to: restoredDocument, core: core, nodeID: "page-a-restored")

    let cssSnapshot = try await backend.waitForTargetMessage(
        method: "CSS.getAllStyleSheets",
        after: restorationBaseline
    )
    let networkEnable = try await backend.waitForTargetMessage(
        method: "Network.enable",
        after: restorationBaseline
    )
    let consoleDisable = try await backend.waitForTargetMessage(
        method: "Console.disable",
        after: restorationBaseline
    )
    let runtimeDisable = try await backend.waitForTargetMessage(
        method: "Runtime.disable",
        after: restorationBaseline
    )
    for message in [cssSnapshot, networkEnable, consoleDisable, runtimeDisable] {
        #expect(message.targetIdentifier == ProtocolTarget.ID("page-a"))
    }

    await modelFeedRespondWithStyleSheets(to: cssSnapshot, core: core)
    let postSnapshotCSSSequence = await core.receiveRootMessage(
        modelFeedTargetDispatchMessage(
            targetID: "page-a",
            message: #"{"method":"CSS.styleSheetAdded","params":{"header":{"styleSheetId":"post-snapshot-sheet","frameId":"main-frame","origin":"author"}}}"#
        )
    )
    await modelFeedRespond(to: networkEnable, core: core)

    await modelFeedRespond(to: runtimeDisable, core: core)
    let runtimeEnable = try await backend.waitForTargetMessage(
        method: "Runtime.enable",
        after: restorationBaseline
    )
    await modelFeedRespond(to: runtimeEnable, core: core)

    await modelFeedRespond(to: consoleDisable, core: core)
    let consoleEnable = try await backend.waitForTargetMessage(
        method: "Console.enable",
        after: restorationBaseline
    )
    await modelFeedRespond(to: consoleEnable, core: core)

    let restorationMethods = try await backend.sentTargetMessages()
        .dropFirst(restorationBaseline)
        .map { try modelFeedMessageMethod($0.message) }
    #expect(!restorationMethods.contains("Page.enable"))
    #expect(restorationMethods.filter { $0 == "Network.enable" }.count == 1)
    #expect(restorationMethods.filter { $0 == "CSS.getAllStyleSheets" }.count == 1)
    #expect(!restorationMethods.contains("CSS.disable"))
    #expect(!restorationMethods.contains("CSS.enable"))
    #expect(restorationMethods.filter { $0 == "Console.disable" }.count == 1)
    #expect(restorationMethods.filter { $0 == "Console.enable" }.count == 1)
    #expect(restorationMethods.filter { $0 == "Runtime.disable" }.count == 1)
    #expect(restorationMethods.filter { $0 == "Runtime.enable" }.count == 1)

    let restoredGeneration = try await modelFeedRequireReset(iterator.next())
    let restoredSnapshot = try await modelFeedRequireTargetSnapshot(iterator.next())
    #expect(restoredSnapshot.generation == restoredGeneration)
    #expect(restoredSnapshot.snapshot.currentPageID == WebInspectorTarget.ID("page-a"))
    _ = try await modelFeedRequireDOMBootstrapSnapshot(iterator.next())
    _ = try await modelFeedRequireBootstrapCompletion(iterator.next())
    _ = try await modelFeedRequireCSSBootstrapSnapshot(iterator.next())
    let cssCompletion = try await modelFeedRequireBootstrapCompletion(iterator.next())
    #expect(cssCompletion.domain == .css)
    let postSnapshotCSS = try await modelFeedRequireEvent(iterator.next())
    #expect(postSnapshotCSS.generation == restoredGeneration)
    #expect(postSnapshotCSS.sequence == postSnapshotCSSSequence)
    #expect(postSnapshotCSS.sequence > cssCompletion.through)
    for domain in [ModelDomain.network, .runtime, .console] {
        let replay = try await modelFeedRequireReplayCompletion(iterator.next())
        #expect(replay.generation == restoredGeneration)
        #expect(replay.domain == domain)
    }
    let synchronization = try await modelFeedRequireSynchronization(iterator.next())
    #expect(synchronization.generation == restoredGeneration)
    #expect(await core.terminalCause == nil)

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-a",
        enableMethods: modelFeedExpectedEnableMethods(
            ModelDomain.normalized(configuredDomains)
        )
    )
    #expect(try await iterator.next() == nil)
    await core.close()
}

@Test
func restoredCSSSnapshotRejectionDuringCloseCleansKnownEnabledWireState() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-a",
        type: "page",
        frameID: "main-frame"
    ))
    let feed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [.css],
        targetID: "page-a"
    )

    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-b",
        type: "page",
        frameID: "main-frame",
        isProvisional: true
    ))
    let pageBCommitBaseline = await backend.sentTargetMessages().count
    _ = await core.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-a","newTargetId":"page-b"}}"#
    )
    let pageBDocument = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        after: pageBCommitBaseline
    )
    await modelFeedRespondWithDocument(to: pageBDocument, core: core)
    for method in ["Page.enable", "CSS.enable"] {
        let command = try await backend.waitForTargetMessage(
            method: method,
            after: pageBCommitBaseline
        )
        await modelFeedRespond(to: command, core: core)
        if method == "CSS.enable" {
            let snapshot = try await backend.waitForTargetMessage(
                method: "CSS.getAllStyleSheets",
                after: pageBCommitBaseline
            )
            await modelFeedRespondWithStyleSheets(to: snapshot, core: core)
        }
    }

    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-a",
        type: "page",
        frameID: "main-frame",
        isProvisional: true
    ))
    let restorationBaseline = await backend.sentTargetMessages().count
    _ = await core.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-b","newTargetId":"page-a"}}"#
    )
    let restoredDocument = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        after: restorationBaseline
    )
    await modelFeedRespondWithDocument(to: restoredDocument, core: core)
    let cssSnapshot = try await backend.waitForTargetMessage(
        method: "CSS.getAllStyleSheets",
        after: restorationBaseline
    )

    let closeTask = Task {
        try await feed.close()
    }
    let cssKey = ConnectionCapabilityKey(
        route: .currentPage,
        targetID: .currentPage,
        domain: .css
    )
    #expect(await modelFeedWaitForNoDesiredCapabilityOwners(core, key: cssKey))
    await modelFeedRespond(
        to: cssSnapshot,
        core: core,
        errorMessage: "snapshot rejected"
    )

    let cssDisable = try await backend.waitForTargetMessage(
        method: "CSS.disable",
        after: restorationBaseline
    )
    #expect(cssDisable.targetIdentifier == ProtocolTarget.ID("page-a"))
    await modelFeedRespond(to: cssDisable, core: core)
    let pageDisable = try await backend.waitForTargetMessage(
        method: "Page.disable",
        after: restorationBaseline
    )
    #expect(pageDisable.targetIdentifier == ProtocolTarget.ID("page-a"))
    await modelFeedRespond(to: pageDisable, core: core)

    try await closeTask.value
    let restorationMethods = try await backend.sentTargetMessages()
        .dropFirst(restorationBaseline)
        .map { try modelFeedMessageMethod($0.message) }
    #expect(restorationMethods == [
        "DOM.getDocument",
        "CSS.getAllStyleSheets",
        "CSS.disable",
        "Page.disable",
    ])
    #expect(await core.terminalCause == nil)
    await core.close()
}

@Test
func restoredNetworkReplayRejectionDuringCloseDisablesKnownEnabledAgent() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-a",
        type: "page",
        frameID: "main-frame"
    ))
    let feed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [.network],
        targetID: "page-a"
    )

    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-b",
        type: "page",
        frameID: "main-frame",
        isProvisional: true
    ))
    let pageBCommitBaseline = await backend.sentTargetMessages().count
    _ = await core.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-a","newTargetId":"page-b"}}"#
    )
    let pageBPageEnable = try await backend.waitForTargetMessage(
        method: "Page.enable",
        after: pageBCommitBaseline
    )
    await modelFeedRespond(to: pageBPageEnable, core: core)
    let pageBEnable = try await backend.waitForTargetMessage(
        method: "Network.enable",
        after: pageBCommitBaseline
    )
    await modelFeedRespond(to: pageBEnable, core: core)

    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-a",
        type: "page",
        frameID: "main-frame",
        isProvisional: true
    ))
    let restorationBaseline = await backend.sentTargetMessages().count
    _ = await core.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-b","newTargetId":"page-a"}}"#
    )
    let restoredEnable = try await backend.waitForTargetMessage(
        method: "Network.enable",
        after: restorationBaseline
    )

    let closeTask = Task {
        try await feed.close()
    }
    let networkKey = ConnectionCapabilityKey(
        route: .currentPage,
        targetID: .currentPage,
        domain: .network
    )
    #expect(await modelFeedWaitForNoDesiredCapabilityOwners(core, key: networkKey))
    await modelFeedRespond(
        to: restoredEnable,
        core: core,
        errorMessage: "replay rejected"
    )
    let disable = try await backend.waitForTargetMessage(
        method: "Network.disable",
        after: restorationBaseline
    )
    #expect(disable.targetIdentifier == ProtocolTarget.ID("page-a"))
    await modelFeedRespond(to: disable, core: core)
    let pageDisable = try await backend.waitForTargetMessage(
        method: "Page.disable",
        after: restorationBaseline
    )
    await modelFeedRespond(to: pageDisable, core: core)

    try await closeTask.value
    let restorationMethods = try await backend.sentTargetMessages()
        .dropFirst(restorationBaseline)
        .map { try modelFeedMessageMethod($0.message) }
    #expect(restorationMethods == [
        "Network.enable",
        "Network.disable",
        "Page.disable",
    ])
    #expect(await core.terminalCause == nil)
    await core.close()
}

@Test
func uncertainRestoredPageAcceptsOnlyTheAlreadyEnabledPostcondition() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-a",
        type: "page",
        frameID: "main-frame"
    ))

    let openTask = Task {
        try await core.openModelFeed(configuredDomains: [.css])
    }
    let pageADocument = try await backend.waitForTargetMessage(method: "DOM.getDocument")
    await modelFeedRespondWithDocument(to: pageADocument, core: core)
    _ = try await backend.waitForTargetMessage(method: "Page.enable")

    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-b",
        type: "page",
        frameID: "main-frame",
        isProvisional: true
    ))
    let pageBCommitBaseline = await backend.sentTargetMessages().count
    _ = await core.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-a","newTargetId":"page-b"}}"#
    )
    let pageBDocument = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        after: pageBCommitBaseline
    )
    await modelFeedRespondWithDocument(to: pageBDocument, core: core)
    let pageBEnable = try await backend.waitForTargetMessage(
        method: "Page.enable",
        after: pageBCommitBaseline
    )
    await modelFeedRespond(to: pageBEnable, core: core)
    let pageBCSSEnable = try await backend.waitForTargetMessage(
        method: "CSS.enable",
        after: pageBCommitBaseline
    )
    await modelFeedRespond(to: pageBCSSEnable, core: core)
    let pageBCSSSnapshot = try await backend.waitForTargetMessage(
        method: "CSS.getAllStyleSheets",
        after: pageBCommitBaseline
    )
    await modelFeedRespondWithStyleSheets(to: pageBCSSSnapshot, core: core)
    let feed = try await openTask.value

    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-a",
        type: "page",
        frameID: "main-frame",
        isProvisional: true
    ))
    let restorationBaseline = await backend.sentTargetMessages().count
    _ = await core.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-b","newTargetId":"page-a"}}"#
    )
    let restoredDocument = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        after: restorationBaseline
    )
    await modelFeedRespondWithDocument(to: restoredDocument, core: core)
    let restoredPageEnable = try await backend.waitForTargetMessage(
        method: "Page.enable",
        after: restorationBaseline
    )
    #expect(restoredPageEnable.targetIdentifier == ProtocolTarget.ID("page-a"))
    await modelFeedRespond(
        to: restoredPageEnable,
        core: core,
        errorMessage: "Page domain already enabled"
    )
    let restoredCSSEnable = try await backend.waitForTargetMessage(
        method: "CSS.enable",
        after: restorationBaseline
    )
    #expect(restoredCSSEnable.targetIdentifier == ProtocolTarget.ID("page-a"))
    await modelFeedRespond(to: restoredCSSEnable, core: core)
    let restoredCSSSnapshot = try await backend.waitForTargetMessage(
        method: "CSS.getAllStyleSheets",
        after: restorationBaseline
    )
    await modelFeedRespondWithStyleSheets(to: restoredCSSSnapshot, core: core)

    #expect(await core.terminalCause == nil)
    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-a",
        enableMethods: ["Page.enable", "CSS.enable"]
    )
    await core.close()
}

@Test
func restoredConsoleReplaySubsumesBufferedProvisionalMessages() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-a",
        type: "page",
        frameID: "main-frame"
    ))
    let feed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [.console],
        targetID: "page-a"
    )
    var iterator = feed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    _ = try await modelFeedRequireReplayCompletion(iterator.next())
    _ = try await modelFeedRequireSynchronization(iterator.next())

    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-b",
        type: "page",
        frameID: "main-frame",
        isProvisional: true
    ))
    let pageBCommitBaseline = await backend.sentTargetMessages().count
    _ = await core.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-a","newTargetId":"page-b"}}"#
    )
    let pageBPageEnable = try await backend.waitForTargetMessage(
        method: "Page.enable",
        after: pageBCommitBaseline
    )
    await modelFeedRespond(to: pageBPageEnable, core: core)
    let pageBEnable = try await backend.waitForTargetMessage(
        method: "Console.enable",
        after: pageBCommitBaseline
    )
    await modelFeedRespond(to: pageBEnable, core: core)
    _ = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    _ = try await modelFeedRequireReplayCompletion(iterator.next())
    _ = try await modelFeedRequireSynchronization(iterator.next())

    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-a",
        type: "page",
        frameID: "main-frame",
        isProvisional: true
    ))
    let message = #"{"method":"Console.messageAdded","params":{"message":{"source":"javascript","level":"log","text":"restored"}}}"#
    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-a",
        message: message
    ))

    let restorationBaseline = await backend.sentTargetMessages().count
    _ = await core.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-b","newTargetId":"page-a"}}"#
    )
    let disable = try await backend.waitForTargetMessage(
        method: "Console.disable",
        after: restorationBaseline
    )
    await modelFeedRespond(to: disable, core: core)
    let enable = try await backend.waitForTargetMessage(
        method: "Console.enable",
        after: restorationBaseline
    )
    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-a",
        message: message
    ))
    await modelFeedRespond(to: enable, core: core)

    _ = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    let replayedMessage = try await modelFeedRequireEvent(iterator.next())
    guard case let .console(.messageAdded(consoleMessage)) = replayedMessage.payload else {
        Issue.record("Expected the authoritative Console replay message.")
        return
    }
    #expect(consoleMessage.text == "restored")
    #expect(try await modelFeedRequireReplayCompletion(iterator.next()).domain == .console)
    _ = try await modelFeedRequireSynchronization(iterator.next())

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-a",
        enableMethods: ["Page.enable", "Runtime.enable", "Console.enable"]
    )
    #expect(try await iterator.next() == nil)
    await core.close()
}

@Test
func parkedCSSAgentDisablesBeforeItsPageDependencyWhenNoOwnerReturns() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-a",
        type: "page",
        frameID: "main-frame"
    ))
    let feed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [.css],
        targetID: "page-a"
    )

    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-b",
        type: "page",
        frameID: "main-frame",
        isProvisional: true
    ))
    let pageBCommitBaseline = await backend.sentTargetMessages().count
    _ = await core.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-a","newTargetId":"page-b"}}"#
    )
    let pageBDocument = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        after: pageBCommitBaseline
    )
    await modelFeedRespondWithDocument(to: pageBDocument, core: core)
    for method in ["Page.enable", "CSS.enable"] {
        let command = try await backend.waitForTargetMessage(
            method: method,
            after: pageBCommitBaseline
        )
        await modelFeedRespond(to: command, core: core)
        if method == "CSS.enable" {
            let snapshot = try await backend.waitForTargetMessage(
                method: "CSS.getAllStyleSheets",
                after: pageBCommitBaseline
            )
            await modelFeedRespondWithStyleSheets(to: snapshot, core: core)
        }
    }
    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-b",
        enableMethods: ["Page.enable", "CSS.enable"]
    )

    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-a",
        type: "page",
        frameID: "main-frame",
        isProvisional: true
    ))
    let restorationBaseline = await backend.sentTargetMessages().count
    _ = await core.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-b","newTargetId":"page-a"}}"#
    )
    let cssDisable = try await backend.waitForTargetMessage(
        method: "CSS.disable",
        after: restorationBaseline
    )
    let commandsBeforeCSSCompletion = try await backend.sentTargetMessages()
        .dropFirst(restorationBaseline)
        .map { try modelFeedMessageMethod($0.message) }
    #expect(commandsBeforeCSSCompletion == ["CSS.disable"])

    await modelFeedRespond(to: cssDisable, core: core)
    let pageDisable = try await backend.waitForTargetMessage(
        method: "Page.disable",
        after: restorationBaseline
    )
    await modelFeedRespond(to: pageDisable, core: core)
    let cleanupMethods = try await backend.sentTargetMessages()
        .dropFirst(restorationBaseline)
        .map { try modelFeedMessageMethod($0.message) }
    #expect(cleanupMethods == ["CSS.disable", "Page.disable"])
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
    let feed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [.dom],
        targetID: "page-main"
    )
    #expect(try await modelFeedSentTargetMethods(backend) == ["Page.enable"])
    #expect(await modelFeedAllCapabilityLeaseOwners(core) == Set([
        .modelFeedNavigation(feed.id),
        .modelFeed(feed.id, .dom),
    ]))

    var iterator = feed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    _ = try await modelFeedRequireDOMBootstrapSnapshot(iterator.next())
    _ = try await modelFeedRequireBootstrapCompletion(iterator.next())
    _ = try await modelFeedRequireSynchronization(iterator.next())

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable"]
    )
    #expect(try await modelFeedSentTargetMethods(backend) == [
        "Page.enable",
        "Page.disable",
    ])
    #expect(await modelFeedAllCapabilityLeaseOwners(core).isEmpty)
    await core.close()
}

@Test
func domBootstrapRequestsMainAndCommittedFramesInSnapshotOrder() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
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

    let openTask = Task {
        try await core.openModelFeed(configuredDomains: [.dom])
    }
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)
    let mainDocument = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        ordinal: 0
    )
    #expect(mainDocument.targetIdentifier == ProtocolTarget.ID("page-main"))
    #expect(try await modelFeedDOMGetDocumentMessages(backend).count == 1)
    await modelFeedRespondWithDocument(to: mainDocument, core: core, nodeID: "1")

    let firstFrameDocument = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        ordinal: 1
    )
    #expect(firstFrameDocument.targetIdentifier == ProtocolTarget.ID("frame-a"))
    #expect(try await modelFeedDOMGetDocumentMessages(backend).count == 2)
    await modelFeedRespondWithDocument(to: firstFrameDocument, core: core, nodeID: "1")

    let secondFrameDocument = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        ordinal: 2
    )
    #expect(secondFrameDocument.targetIdentifier == ProtocolTarget.ID("frame-b"))
    await modelFeedRespondWithDocument(to: secondFrameDocument, core: core, nodeID: "1")
    let feed = try await openTask.value

    var iterator = feed.records.makeAsyncIterator()
    let reset = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    let snapshots = try await [
        modelFeedRequireDOMBootstrapSnapshot(iterator.next()),
        modelFeedRequireDOMBootstrapSnapshot(iterator.next()),
        modelFeedRequireDOMBootstrapSnapshot(iterator.next()),
    ]
    #expect(snapshots.map(\.target.id) == [
        WebInspectorTarget.ID("page-main"),
        WebInspectorTarget.ID("frame-a"),
        WebInspectorTarget.ID("frame-b"),
    ])
    #expect(snapshots.allSatisfy {
        $0.generation == reset && $0.documentEpoch == ModelDOMBindingEpoch(rawValue: 0)
    })
    #expect(snapshots[0].root.id == DOM.Node.ID("1"))
    #expect(snapshots[1].root.id != DOM.Node.ID("1"))
    #expect(snapshots[2].root.id != DOM.Node.ID("1"))
    _ = try await modelFeedRequireBootstrapCompletion(iterator.next())
    _ = try await modelFeedRequireSynchronization(iterator.next())

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable"]
    )
    #expect(try await iterator.next() == nil)
    await core.close()
}

@Test
func domDocumentInvalidationPrecedesMainTargetDeltasAndFreshBootstrap() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))

    let openTask = Task {
        try await core.openModelFeed(configuredDomains: [.css])
    }
    let staleDocument = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        ordinal: 0
    )
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)
    let cssEnable = try await backend.waitForTargetMessage(method: "CSS.enable")
    await modelFeedRespond(to: cssEnable, core: core)
    let initialCSSSnapshotCommand = try await backend.waitForTargetMessage(
        method: "CSS.getAllStyleSheets",
        ordinal: 0
    )
    await modelFeedRespondWithStyleSheets(
        to: initialCSSSnapshotCommand,
        core: core
    )
    let feed = try await openTask.value
    var iterator = feed.records.makeAsyncIterator()
    let reset = try await modelFeedRequireReset(iterator.next())
    let targetSnapshot = try await modelFeedRequireTargetSnapshot(iterator.next())
    _ = try await modelFeedRequireCSSBootstrapSnapshot(iterator.next())
    #expect(try await modelFeedRequireBootstrapCompletion(iterator.next()).domain == .css)

    let oldAuthorization = ConnectionModelCommandAuthorization(
        feedID: feed.id,
        generation: reset,
        document: ConnectionModelCommandAuthorization.Document(
            targetID: WebInspectorTarget.ID("page-main"),
            epoch: ModelDOMBindingEpoch(rawValue: 0)
        )
    )
    let oldCommand = Task {
        try await core.send(modelFeedCommand(
            domain: .dom,
            method: "DOM.querySelector",
            authority: oldAuthorization
        ))
    }
    await core.waitForModelCommandReadinessWaiterCountForTesting(1)

    let invalidationSequence = await core.receiveRootMessage(
        modelFeedTargetDispatchMessage(
            targetID: "page-main",
            message: #"{"method":"DOM.documentUpdated","params":{}}"#
        )
    )
    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        try await oldCommand.value
    }
    let invalidation = try await modelFeedRequireDOMDocumentInvalidation(iterator.next())
    #expect(invalidation.generation == reset)
    #expect(invalidation.sequence == invalidationSequence)
    #expect(invalidation.target.id == WebInspectorTarget.ID("page-main"))
    #expect(invalidation.agentTarget.id == WebInspectorTarget.ID("page-main"))
    #expect(invalidation.documentEpoch == ModelDOMBindingEpoch(rawValue: 1))

    let refreshedCSSCommand = try await backend.waitForTargetMessage(
        method: "CSS.getAllStyleSheets",
        ordinal: 1
    )
    let suppressedDOMSequence = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: #"{"method":"DOM.childNodeCountUpdated","params":{"nodeId":1,"childNodeCount":2}}"#
    ))
    let suppressedCSSSequence = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: #"{"method":"CSS.styleSheetAdded","params":{"header":{"styleSheetId":"sheet-main","origin":"author"}}}"#
    ))

    await modelFeedRespondWithStyleSheets(to: refreshedCSSCommand, core: core)
    let refreshedCSSRecord = try #require(await iterator.next())
    guard case let .bootstrapSnapshot(_, .css, cssSnapshotSequence, _) = refreshedCSSRecord else {
        Issue.record("Expected the refreshed authoritative CSS snapshot.")
        return
    }
    let refreshedStyleSheets = try modelFeedRequireCSSBootstrapSnapshot(
        refreshedCSSRecord
    )
    #expect(refreshedStyleSheets.allSatisfy {
        $0.scope.domBindingEpoch == ModelDOMBindingEpoch(rawValue: 1)
            && $0.scope.agentTarget == $0.scope.target
    })
    let refreshedCSSCompletion = try await modelFeedRequireBootstrapCompletion(
        iterator.next()
    )
    #expect(suppressedCSSSequence <= cssSnapshotSequence)
    #expect(refreshedCSSCompletion.through == cssSnapshotSequence)

    await modelFeedRespondWithDocument(to: staleDocument, core: core, nodeID: "stale")
    let retryDocument = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        ordinal: 1
    )
    #expect(retryDocument.targetIdentifier == ProtocolTarget.ID("page-main"))
    await modelFeedRespondWithDocument(to: retryDocument, core: core, nodeID: "fresh")

    let initialBootstrap = try await modelFeedRequireDOMBootstrapSnapshot(iterator.next())
    #expect(initialBootstrap.generation == reset)
    #expect(initialBootstrap.target.id == WebInspectorTarget.ID("page-main"))
    #expect(initialBootstrap.agentTarget.id == WebInspectorTarget.ID("page-main"))
    #expect(initialBootstrap.documentEpoch == ModelDOMBindingEpoch(rawValue: 1))
    #expect(initialBootstrap.root.id == DOM.Node.ID("fresh"))
    #expect(suppressedDOMSequence < initialBootstrap.sequence)
    let initialCompletion = try await modelFeedRequireBootstrapCompletion(iterator.next())
    let initialSync = try await modelFeedRequireSynchronization(iterator.next())
    #expect(initialCompletion.through == initialBootstrap.sequence)
    #expect(initialSync.generation == targetSnapshot.generation)

    let domSequence = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: #"{"method":"DOM.childNodeCountUpdated","params":{"nodeId":1,"childNodeCount":3}}"#
    ))
    let cssSequence = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: #"{"method":"CSS.styleSheetChanged","params":{"styleSheetId":"restored-sheet"}}"#
    ))
    let domEvent = try await modelFeedRequireEvent(iterator.next())
    let cssEvent = try await modelFeedRequireEvent(iterator.next())
    #expect(domEvent.sequence == domSequence)
    #expect(cssEvent.sequence == cssSequence)
    #expect(domEvent.domBindingEpoch == ModelDOMBindingEpoch(rawValue: 1))
    #expect(cssEvent.domBindingEpoch == ModelDOMBindingEpoch(rawValue: 1))
    guard case .dom = domEvent.payload, case .css = cssEvent.payload else {
        Issue.record("Expected only post-bootstrap DOM/CSS deltas.")
        return
    }

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable", "CSS.enable"]
    )
    #expect(try await iterator.next() == nil)
    await core.close()
}

@Test
func cssBootstrapRetriesStaleScopeAndPublishesOnlyTheLatestBinding() async throws {
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
        configuredDomains: [.css],
        targetID: "page-main"
    )
    var iterator = feed.records.makeAsyncIterator()
    let generation = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    _ = try await modelFeedRequireDOMBootstrapSnapshot(iterator.next())
    #expect(try await modelFeedRequireBootstrapCompletion(iterator.next()).domain == .dom)
    _ = try await modelFeedRequireCSSBootstrapSnapshot(iterator.next())
    #expect(try await modelFeedRequireBootstrapCompletion(iterator.next()).domain == .css)
    _ = try await modelFeedRequireSynchronization(iterator.next())

    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: #"{"method":"DOM.documentUpdated","params":{}}"#
    ))
    let firstInvalidation = try await modelFeedRequireDOMDocumentInvalidation(iterator.next())
    #expect(firstInvalidation.documentEpoch == ModelDOMBindingEpoch(rawValue: 1))
    let firstDOMSnapshot = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        ordinal: 1
    )
    let firstCSSSnapshot = try await backend.waitForTargetMessage(
        method: "CSS.getAllStyleSheets",
        ordinal: 1
    )

    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: #"{"method":"DOM.documentUpdated","params":{}}"#
    ))
    let secondInvalidation = try await modelFeedRequireDOMDocumentInvalidation(iterator.next())
    #expect(secondInvalidation.documentEpoch == ModelDOMBindingEpoch(rawValue: 2))
    let subsumedCSSSequence = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: #"{"method":"CSS.styleSheetAdded","params":{"header":{"styleSheetId":"subsumed-sheet","frameId":"main-frame","origin":"author"}}}"#
    ))

    await modelFeedRespondWithStyleSheets(to: firstCSSSnapshot, core: core)
    let secondCSSSnapshot = try await backend.waitForTargetMessage(
        method: "CSS.getAllStyleSheets",
        ordinal: 2
    )
    await modelFeedRespondWithStyleSheets(to: secondCSSSnapshot, core: core)
    let currentCSSRecord = try #require(await iterator.next())
    guard case let .bootstrapSnapshot(
        recordGeneration,
        .css,
        snapshotSequence,
        _
    ) = currentCSSRecord else {
        Issue.record("Expected only the retried CSS bootstrap to publish.")
        return
    }
    #expect(recordGeneration == generation)
    #expect(subsumedCSSSequence <= snapshotSequence)
    let currentStyleSheets = try modelFeedRequireCSSBootstrapSnapshot(currentCSSRecord)
    #expect(currentStyleSheets.count == 1)
    #expect(currentStyleSheets.first?.scope.generation == generation)
    #expect(currentStyleSheets.first?.scope.navigationEpoch == ModelNavigationEpoch(rawValue: 0))
    #expect(currentStyleSheets.first?.scope.domBindingEpoch == ModelDOMBindingEpoch(rawValue: 2))
    let cssCompletion = try await modelFeedRequireBootstrapCompletion(iterator.next())
    #expect(cssCompletion.domain == .css)
    #expect(cssCompletion.through == snapshotSequence)

    let postSnapshotSequence = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: #"{"method":"CSS.styleSheetChanged","params":{"styleSheetId":"restored-sheet"}}"#
    ))
    let postSnapshotEvent = try await modelFeedRequireEvent(iterator.next())
    #expect(postSnapshotEvent.sequence == postSnapshotSequence)
    #expect(postSnapshotEvent.sequence > snapshotSequence)
    #expect(postSnapshotEvent.domBindingEpoch == ModelDOMBindingEpoch(rawValue: 2))
    guard case .css = postSnapshotEvent.payload else {
        Issue.record("Expected the post-snapshot CSS delta.")
        return
    }

    await modelFeedRespondWithDocument(to: firstDOMSnapshot, core: core, nodeID: "stale")
    let secondDOMSnapshot = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        ordinal: 2
    )
    await modelFeedRespondWithDocument(to: secondDOMSnapshot, core: core, nodeID: "current")
    let domSnapshot = try await modelFeedRequireDOMBootstrapSnapshot(iterator.next())
    #expect(domSnapshot.generation == generation)
    #expect(domSnapshot.documentEpoch == ModelDOMBindingEpoch(rawValue: 2))
    #expect(domSnapshot.root.id == DOM.Node.ID("current"))
    #expect(try await modelFeedRequireBootstrapCompletion(iterator.next()).domain == .dom)

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable", "CSS.enable"]
    )
    #expect(try await iterator.next() == nil)
    await core.close()
}

@Test
func frameDocumentUpdatedBypassesPublicFilterWithOneModelInvalidationBoundary() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "frame-a",
        type: "frame",
        frameID: "frame-a",
        parentFrameID: "main-frame"
    ))

    let openTask = Task {
        try await core.openModelFeed(configuredDomains: [.dom])
    }
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)

    let mainDocument = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        ordinal: 0
    )
    await modelFeedRespondWithDocument(to: mainDocument, core: core, nodeID: "main")
    let frameDocument = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        ordinal: 1
    )
    await modelFeedRespondWithDocument(to: frameDocument, core: core, nodeID: "frame")
    let feed = try await openTask.value
    var iterator = feed.records.makeAsyncIterator()
    let generation = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    _ = try await modelFeedRequireDOMBootstrapSnapshot(iterator.next())
    let initialFrameBootstrap = try await modelFeedRequireDOMBootstrapSnapshot(iterator.next())
    #expect(initialFrameBootstrap.target.id == WebInspectorTarget.ID("frame-a"))
    #expect(initialFrameBootstrap.documentEpoch == ModelDOMBindingEpoch(rawValue: 0))
    _ = try await modelFeedRequireBootstrapCompletion(iterator.next())
    _ = try await modelFeedRequireSynchronization(iterator.next())

    let publicFrameDocumentEvent = ProtocolEvent(
        sequence: 1,
        domain: .dom,
        method: "DOM.documentUpdated",
        targetID: ProtocolTarget.ID("frame-a"),
        paramsData: Data("{}".utf8)
    )
    #expect(ConnectionEventProjection.shouldDeliver(
        publicFrameDocumentEvent,
        to: .currentPage,
        in: await core.snapshot()
    ) == false)

    let oldAuthorization = ConnectionModelCommandAuthorization(
        feedID: feed.id,
        generation: generation,
        document: ConnectionModelCommandAuthorization.Document(
            targetID: WebInspectorTarget.ID("frame-a"),
            epoch: ModelDOMBindingEpoch(rawValue: 0)
        )
    )
    let oldCommand = Task {
        try await core.send(modelFeedCommand(
            domain: .dom,
            method: "DOM.querySelector",
            authority: oldAuthorization,
            routing: .target(ProtocolTarget.ID("frame-a"))
        ))
    }
    let oldCommandMessage = try await backend.waitForTargetMessage(
        method: "DOM.querySelector"
    )

    let invalidationSequence = await core.receiveRootMessage(
        modelFeedTargetDispatchMessage(
            targetID: "frame-a",
            message: #"{"method":"DOM.documentUpdated","params":{}}"#
        )
    )
    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        try await oldCommand.value
    }
    let invalidation = try await modelFeedRequireDOMDocumentInvalidation(iterator.next())
    #expect(invalidation.generation == generation)
    #expect(invalidation.sequence == invalidationSequence)
    #expect(invalidation.target.id == WebInspectorTarget.ID("frame-a"))
    #expect(invalidation.documentEpoch == ModelDOMBindingEpoch(rawValue: 1))
    await modelFeedRespond(to: oldCommandMessage, core: core)

    let suppressedDOMSequence = await core.receiveRootMessage(
        modelFeedTargetDispatchMessage(
            targetID: "frame-a",
            message: #"{"method":"DOM.childNodeCountUpdated","params":{"nodeId":7,"childNodeCount":1}}"#
        )
    )
    let refreshedFrameDocument = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        ordinal: 2
    )
    #expect(refreshedFrameDocument.targetIdentifier == ProtocolTarget.ID("frame-a"))
    await modelFeedRespondWithDocument(
        to: refreshedFrameDocument,
        core: core,
        nodeID: "fresh-frame"
    )
    let refreshedFrameBootstrap = try await modelFeedRequireDOMBootstrapSnapshot(iterator.next())
    #expect(refreshedFrameBootstrap.generation == generation)
    #expect(refreshedFrameBootstrap.sequence == suppressedDOMSequence)
    #expect(refreshedFrameBootstrap.target.id == WebInspectorTarget.ID("frame-a"))
    #expect(refreshedFrameBootstrap.documentEpoch == ModelDOMBindingEpoch(rawValue: 1))
    #expect(refreshedFrameBootstrap.root.id.targetScopeRawValue == "frame-a")
    _ = try await modelFeedRequireBootstrapCompletion(iterator.next())

    let laterDOMSequence = await core.receiveRootMessage(
        modelFeedTargetDispatchMessage(
            targetID: "frame-a",
            message: #"{"method":"DOM.childNodeCountUpdated","params":{"nodeId":7,"childNodeCount":2}}"#
        )
    )
    let laterDOMEvent = try await modelFeedRequireEvent(iterator.next())
    #expect(laterDOMEvent.sequence == laterDOMSequence)
    #expect(laterDOMEvent.domBindingEpoch == ModelDOMBindingEpoch(rawValue: 1))
    guard case .dom = laterDOMEvent.payload else {
        Issue.record("Expected only the post-bootstrap frame DOM delta.")
        return
    }

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable"]
    )
    #expect(try await iterator.next() == nil)
    await core.close()
}

@Test
func domBootstrapTracksTargetsAddedAndDestroyedBeforeInitialSync() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))

    let openTask = Task {
        try await core.openModelFeed(configuredDomains: [.dom])
    }
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)
    let feed = try await openTask.value
    let mainDocument = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        ordinal: 0
    )
    var iterator = feed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())

    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "frame-a",
        type: "frame",
        frameID: "frame-a",
        parentFrameID: "main-frame"
    ))
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "frame-b",
        type: "frame",
        frameID: "frame-b",
        parentFrameID: "main-frame"
    ))
    let frameAEvent = try await modelFeedRequireEvent(iterator.next())
    let frameBEvent = try await modelFeedRequireEvent(iterator.next())
    guard case .target(.targetCreated) = frameAEvent.payload,
          case .target(.targetCreated) = frameBEvent.payload else {
        Issue.record("Expected targetCreated deltas before bootstrap completion.")
        return
    }
    #expect(frameAEvent.target.id == WebInspectorTarget.ID("frame-a"))
    #expect(frameBEvent.target.id == WebInspectorTarget.ID("frame-b"))

    await modelFeedRespondWithDocument(to: mainDocument, core: core, nodeID: "main")
    let frameADocument = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        ordinal: 1
    )
    #expect(frameADocument.targetIdentifier == ProtocolTarget.ID("frame-a"))
    await modelFeedRespondWithDocument(to: frameADocument, core: core, nodeID: "a")
    let frameBDocument = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        ordinal: 2
    )
    #expect(frameBDocument.targetIdentifier == ProtocolTarget.ID("frame-b"))

    _ = await core.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"frame-b"}}"#
    )
    let mainBootstrap = try await modelFeedRequireDOMBootstrapSnapshot(iterator.next())
    let frameABootstrap = try await modelFeedRequireDOMBootstrapSnapshot(iterator.next())
    let frameBDestroyed = try await modelFeedRequireEvent(iterator.next())
    guard case .target(.targetDestroyed) = frameBDestroyed.payload else {
        Issue.record("Expected the removed frame target delta.")
        return
    }
    #expect(frameBDestroyed.target.id == WebInspectorTarget.ID("frame-b"))
    // This late reply no longer owns a pending operation and cannot publish.
    await modelFeedRespondWithDocument(to: frameBDocument, core: core, nodeID: "stale-b")

    #expect(mainBootstrap.target.id == WebInspectorTarget.ID("page-main"))
    #expect(frameABootstrap.target.id == WebInspectorTarget.ID("frame-a"))
    _ = try await modelFeedRequireBootstrapCompletion(iterator.next())
    _ = try await modelFeedRequireSynchronization(iterator.next())
    #expect(await backend.sentTargetMessages().filter {
        (try? modelFeedMessageMethod($0.message)) == "DOM.getDocument"
    }.count == 3)

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable"]
    )
    #expect(try await iterator.next() == nil)
    await core.close()
}

@Test
func domBootstrapRestartsWithFreshEpochAndSyncAfterRetarget() async throws {
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
        configuredDomains: [.dom],
        targetID: "page-old"
    )
    var iterator = feed.records.makeAsyncIterator()
    let initialReset = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    let initialBootstrap = try await modelFeedRequireDOMBootstrapSnapshot(iterator.next())
    _ = try await modelFeedRequireBootstrapCompletion(iterator.next())
    _ = try await modelFeedRequireSynchronization(iterator.next())
    #expect(initialBootstrap.target.id == WebInspectorTarget.ID("page-old"))
    #expect(initialBootstrap.documentEpoch == ModelDOMBindingEpoch(rawValue: 0))

    _ = await core.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"page-old"}}"#
    )
    let replacementReset = try await modelFeedRequireReset(iterator.next())
    #expect(replacementReset.rawValue == initialReset.rawValue + 1)

    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-new",
        type: "page",
        frameID: "main-frame"
    ))
    let replacementSnapshot = try await modelFeedRequireTargetSnapshot(iterator.next())
    let replacementDocument = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        ordinal: 1
    )
    #expect(replacementDocument.targetIdentifier == ProtocolTarget.ID("page-new"))
    let replacementPageEnable = try await backend.waitForTargetMessage(
        method: "Page.enable",
        ordinal: 1
    )
    await modelFeedRespond(to: replacementPageEnable, core: core)
    await modelFeedRespondWithDocument(to: replacementDocument, core: core, nodeID: "new")
    let replacementBootstrap = try await modelFeedRequireDOMBootstrapSnapshot(iterator.next())
    let replacementCompletion = try await modelFeedRequireBootstrapCompletion(iterator.next())
    let replacementSync = try await modelFeedRequireSynchronization(iterator.next())
    #expect(replacementSnapshot.generation == replacementReset)
    #expect(replacementBootstrap.generation == replacementReset)
    #expect(replacementBootstrap.target.id == WebInspectorTarget.ID("page-new"))
    #expect(replacementBootstrap.documentEpoch == ModelDOMBindingEpoch(rawValue: 0))
    #expect(replacementCompletion.generation == replacementReset)
    #expect(replacementSync.generation == replacementReset)

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-new",
        enableMethods: ["Page.enable"]
    )
    #expect(try await iterator.next() == nil)
    await core.close()
}

@Test
func pendingDOMBootstrapReplyFromSupersededBindingCannotPublish() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-old",
        type: "page",
        frameID: "main-frame"
    ))
    let openTask = Task {
        try await core.openModelFeed(configuredDomains: [.dom])
    }
    let oldDocument = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        ordinal: 0
    )
    let oldPageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: oldPageEnable, core: core)
    let feed = try await openTask.value
    var iterator = feed.records.makeAsyncIterator()
    let initialReset = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())

    _ = await core.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"page-old"}}"#
    )
    let replacementReset = try await modelFeedRequireReset(iterator.next())
    #expect(replacementReset.rawValue == initialReset.rawValue + 1)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-new",
        type: "page",
        frameID: "main-frame"
    ))
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    let newDocument = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        ordinal: 1
    )
    #expect(newDocument.targetIdentifier == ProtocolTarget.ID("page-new"))
    let newPageEnable = try await backend.waitForTargetMessage(
        method: "Page.enable",
        ordinal: 1
    )
    await modelFeedRespond(to: newPageEnable, core: core)

    await modelFeedRespondWithDocument(to: oldDocument, core: core, nodeID: "stale-old")
    await modelFeedRespondWithDocument(to: newDocument, core: core, nodeID: "fresh-new")
    let bootstrap = try await modelFeedRequireDOMBootstrapSnapshot(iterator.next())
    #expect(bootstrap.generation == replacementReset)
    #expect(bootstrap.target.id == WebInspectorTarget.ID("page-new"))
    #expect(bootstrap.root.id == DOM.Node.ID("fresh-new"))
    _ = try await modelFeedRequireBootstrapCompletion(iterator.next())
    _ = try await modelFeedRequireSynchronization(iterator.next())

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-new",
        enableMethods: ["Page.enable"]
    )
    #expect(try await iterator.next() == nil)
    await core.close()
}

@Test
func terminatedDOMFeedCannotAdvanceBootstrapQueue() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "frame-a",
        type: "frame",
        frameID: "frame-a",
        parentFrameID: "main-frame"
    ))
    var openTask: Task<ConnectionModelFeed, any Error>? = Task {
        try await core.openModelFeed(configuredDomains: [.dom])
    }
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)
    var feed: ConnectionModelFeed? = try await #require(openTask).value
    openTask = nil
    let records = try #require(feed).records
    let getDocument = try await backend.waitForTargetMessage(method: "DOM.getDocument")
    feed = nil

    await modelFeedRespondWithDocument(to: getDocument, core: core)
    #expect(await core.terminalCause == .modelFeedFailure(.consumerTerminated))
    await #expect(throws: WebInspectorProxyError.self) {
        try await core.waitUntilClosed()
    }
    #expect(try await modelFeedDOMGetDocumentMessages(backend).map(\.targetIdentifier) == [
        ProtocolTarget.ID("page-main"),
    ])
    var iterator = records.makeAsyncIterator()
    #expect(try await iterator.next() == nil)
}

@Test
func requiredDOMBootstrapFailureTerminatesTheFeed() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let openTask = Task {
        try await core.openModelFeed(configuredDomains: [.dom])
    }
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)
    let feed = try await openTask.value
    var iterator = feed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    let getDocument = try await backend.waitForTargetMessage(method: "DOM.getDocument")
    await modelFeedRespond(
        to: getDocument,
        core: core,
        errorMessage: "document rejected"
    )

    let expectedError = ConnectionModelFeedError.bootstrapFailed(
        domain: .dom,
        message: "document rejected"
    )
    await #expect(throws: WebInspectorProxyError.self) {
        try await core.waitUntilClosed()
    }
    #expect(await core.terminalCause == .modelFeedFailure(expectedError))
    await #expect(throws: expectedError) {
        try await iterator.next()
    }
    #expect(await backend.isDetached())
    _ = feed
}

@Test
func requiredDOMRefreshFailurePreservesTypedDomainInMailbox() async throws {
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
        configuredDomains: [.dom],
        targetID: "page-main"
    )
    var iterator = feed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    _ = try await modelFeedRequireDOMBootstrapSnapshot(iterator.next())
    _ = try await modelFeedRequireBootstrapCompletion(iterator.next())
    _ = try await modelFeedRequireSynchronization(iterator.next())

    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: #"{"method":"DOM.documentUpdated","params":{}}"#
    ))
    let invalidation = try await modelFeedRequireDOMDocumentInvalidation(iterator.next())
    #expect(invalidation.documentEpoch == ModelDOMBindingEpoch(rawValue: 1))
    let refresh = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        ordinal: 1
    )
    await modelFeedRespond(
        to: refresh,
        core: core,
        errorMessage: "refresh rejected"
    )

    let expectedError = ConnectionModelFeedError.bootstrapFailed(
        domain: .dom,
        message: "refresh rejected"
    )
    await #expect(throws: WebInspectorProxyError.self) {
        try await core.waitUntilClosed()
    }
    #expect(await core.terminalCause == .modelFeedFailure(expectedError))
    await #expect(throws: expectedError) {
        try await iterator.next()
    }
    #expect(await backend.isDetached())
    _ = feed
}

@Test
func malformedRequiredDOMBootstrapReplyTerminatesWithoutTaskLeak() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let openTask = Task {
        try await core.openModelFeed(configuredDomains: [.dom])
    }
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)
    let feed = try await openTask.value
    var iterator = feed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    let getDocument = try await backend.waitForTargetMessage(method: "DOM.getDocument")
    let commandID = try modelFeedMessageID(getDocument.message)

    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: #"{"id":\#(commandID),"result":{"root":{"nodeId":"incomplete"}}}"#
    ))

    await #expect(throws: WebInspectorProxyError.self) {
        try await core.waitUntilClosed()
    }
    guard case let .protocolViolation(message) = await core.terminalCause else {
        Issue.record("Expected malformed bootstrap data to terminate as a protocol violation.")
        return
    }
    #expect(message.contains("Failed to decode DOM.getDocument reply"))
    #expect(await core.pendingReplyPurposes().isEmpty)
    await #expect(throws: WebInspectorProxyError.self) {
        try await iterator.next()
    }
    #expect(await backend.isDetached())
    _ = feed
}

@Test
func closingDOMModelFeedCancelsAndAwaitsPendingBootstrap() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let openTask = Task {
        try await core.openModelFeed(configuredDomains: [.dom])
    }
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)
    let feed = try await openTask.value
    _ = try await backend.waitForTargetMessage(method: "DOM.getDocument")
    var iterator = feed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())

    let closeTask = Task {
        try await feed.close()
    }
    let pageDisable = try await backend.waitForTargetMessage(method: "Page.disable")
    await modelFeedRespond(to: pageDisable, core: core)
    try await closeTask.value
    #expect(await core.pendingReplyPurposes().isEmpty)
    #expect(try await iterator.next() == nil)
    #expect(await backend.isDetached() == false)

    let replacement = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [],
        targetID: "page-main"
    )
    var replacementIterator = replacement.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(replacementIterator.next())
    _ = try await modelFeedRequireTargetSnapshot(replacementIterator.next())
    _ = try await modelFeedRequireSynchronization(replacementIterator.next())
    try await modelFeedCloseSuccessfully(
        replacement,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable"]
    )
    #expect(try await replacementIterator.next() == nil)
    await core.close()
}

@Test
func closingCSSModelFeedCancelsPendingAuthoritativeSnapshot() async throws {
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
        configuredDomains: [.css],
        targetID: "page-main"
    )
    let baseline = await backend.sentTargetMessages().count

    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: #"{"method":"DOM.documentUpdated","params":{}}"#
    ))
    _ = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        after: baseline
    )
    _ = try await backend.waitForTargetMessage(
        method: "CSS.getAllStyleSheets",
        after: baseline
    )

    let closeTask = Task {
        try await feed.close()
    }
    let cssDisable = try await backend.waitForTargetMessage(
        method: "CSS.disable",
        after: baseline
    )
    await modelFeedRespond(to: cssDisable, core: core)
    let pageDisable = try await backend.waitForTargetMessage(
        method: "Page.disable",
        after: baseline
    )
    await modelFeedRespond(to: pageDisable, core: core)

    try await closeTask.value
    #expect(await core.pendingReplyPurposes().isEmpty)
    #expect(await backend.isDetached() == false)
    await core.close()
}

@Test
func closingModelFeedDoesNotReadmitDOMBootstrapDuringCommit() async throws {
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
        configuredDomains: [.dom, .network],
        targetID: "page-old"
    )
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-new",
        type: "page",
        frameID: "main-frame",
        isProvisional: true
    ))

    let closeTask = Task {
        try await feed.close()
    }
    _ = try await backend.waitForTargetMessage(method: "Network.disable")
    _ = await core.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-old","newTargetId":"page-new"}}"#
    )
    let replacementPageEnable = try await backend.waitForTargetMessage(
        method: "Page.enable",
        ordinal: 1
    )
    await modelFeedRespond(to: replacementPageEnable, core: core)
    let replacementPageDisable = try await backend.waitForTargetMessage(
        method: "Page.disable"
    )
    await modelFeedRespond(to: replacementPageDisable, core: core)
    try await closeTask.value

    #expect(try await modelFeedDOMGetDocumentMessages(backend).map(\.targetIdentifier) == [
        ProtocolTarget.ID("page-old"),
    ])
    #expect(await core.pendingReplyPurposes().isEmpty)
    await core.close()
}

@Test
func rollingBackModelFeedDoesNotReadmitDOMBootstrapDuringCommit() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-old",
        type: "page",
        frameID: "main-frame"
    ))
    let openTask = Task {
        try await core.openModelFeed(
            configuredDomains: [.dom, .network, .console]
        )
    }
    let getDocument = try await backend.waitForTargetMessage(method: "DOM.getDocument")
    await modelFeedRespondWithDocument(to: getDocument, core: core)
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)
    let networkEnable = try await backend.waitForTargetMessage(method: "Network.enable")
    await modelFeedRespond(to: networkEnable, core: core)
    let runtimeEnable = try await backend.waitForTargetMessage(method: "Runtime.enable")
    await modelFeedRespond(to: runtimeEnable, core: core)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-new",
        type: "page",
        frameID: "main-frame",
        isProvisional: true
    ))
    let consoleEnable = try await backend.waitForTargetMessage(method: "Console.enable")
    await modelFeedRespond(
        to: consoleEnable,
        core: core,
        errorMessage: "console rejected"
    )
    let runtimeDisable = try await backend.waitForTargetMessage(method: "Runtime.disable")
    await modelFeedRespond(to: runtimeDisable, core: core)
    _ = try await backend.waitForTargetMessage(method: "Network.disable")

    _ = await core.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-old","newTargetId":"page-new"}}"#
    )
    let replacementPageEnable = try await backend.waitForTargetMessage(
        method: "Page.enable",
        ordinal: 1
    )
    await modelFeedRespond(to: replacementPageEnable, core: core)
    let replacementPageDisable = try await backend.waitForTargetMessage(
        method: "Page.disable"
    )
    await modelFeedRespond(to: replacementPageDisable, core: core)
    await #expect(throws: ConnectionModelFeedError.bootstrapFailed(
        domain: .console,
        message: "console rejected"
    )) {
        try await openTask.value
    }
    #expect(try await modelFeedDOMGetDocumentMessages(backend).map(\.targetIdentifier) == [
        ProtocolTarget.ID("page-old"),
    ])
    #expect(await core.pendingReplyPurposes().isEmpty)
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
            configuredDomains: [.network, .console]
        )
    }
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)
    let networkEnable = try await backend.waitForTargetMessage(method: "Network.enable")
    await modelFeedRespond(to: networkEnable, core: core)
    let runtimeEnable = try await backend.waitForTargetMessage(method: "Runtime.enable")
    await modelFeedRespond(to: runtimeEnable, core: core)
    let consoleEnable = try await backend.waitForTargetMessage(method: "Console.enable")
    await modelFeedRespond(
        to: consoleEnable,
        core: core,
        errorMessage: "console rejected"
    )
    let runtimeDisable = try await backend.waitForTargetMessage(method: "Runtime.disable")
    await modelFeedRespond(to: runtimeDisable, core: core)
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
func explicitCloseDuringModelFeedRollbackLetsTerminalOwnerRetireRegistration() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let openTask = Task {
        try await core.openModelFeed(
            configuredDomains: [.network, .console]
        )
    }
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)
    let networkEnable = try await backend.waitForTargetMessage(method: "Network.enable")
    await modelFeedRespond(to: networkEnable, core: core)
    let runtimeEnable = try await backend.waitForTargetMessage(method: "Runtime.enable")
    await modelFeedRespond(to: runtimeEnable, core: core)
    let consoleEnable = try await backend.waitForTargetMessage(method: "Console.enable")
    await modelFeedRespond(
        to: consoleEnable,
        core: core,
        errorMessage: "console rejected"
    )
    let runtimeDisable = try await backend.waitForTargetMessage(method: "Runtime.disable")
    await modelFeedRespond(to: runtimeDisable, core: core)
    _ = try await backend.waitForTargetMessage(method: "Network.disable")

    await core.close()

    await #expect(throws: ConnectionModelFeedError.bootstrapFailed(
        domain: .console,
        message: "console rejected"
    )) {
        try await openTask.value
    }
    #expect(await core.terminalCause == .explicitClose)
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
            configuredDomains: [.network, .console]
        )
    }
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)
    let networkEnable = try await backend.waitForTargetMessage(method: "Network.enable")
    await modelFeedRespond(to: networkEnable, core: core)
    let runtimeEnable = try await backend.waitForTargetMessage(method: "Runtime.enable")
    await modelFeedRespond(to: runtimeEnable, core: core)
    let consoleEnable = try await backend.waitForTargetMessage(method: "Console.enable")
    await modelFeedRespond(
        to: consoleEnable,
        core: core,
        errorMessage: "console rejected"
    )
    let runtimeDisable = try await backend.waitForTargetMessage(method: "Runtime.disable")
    await modelFeedRespond(to: runtimeDisable, core: core)
    let networkDisable = try await backend.waitForTargetMessage(method: "Network.disable")
    await modelFeedRespond(
        to: networkDisable,
        core: core,
        errorMessage: "disable rejected"
    )
    let pageDisable = try await backend.waitForTargetMessage(method: "Page.disable")
    await modelFeedRespond(to: pageDisable, core: core)

    do {
        _ = try await openTask.value
        Issue.record("Expected activation and rollback cleanup to fail.")
    } catch let error as WebInspectorScopeError {
        #expect(error.operationError as? ConnectionModelFeedError == .bootstrapFailed(
            domain: .console,
            message: "console rejected"
        ))
        #expect(error.cleanupError as? WebInspectorProxyError == .commandRejected(
            method: "Network.disable",
            message: "disable rejected"
        ))
    } catch {
        Issue.record("Expected WebInspectorScopeError, got \(error).")
    }
    guard case let .fatal(message) = await core.terminalCause else {
        Issue.record("Expected rollback cleanup failure to terminate the connection.")
        return
    }
    #expect(message.contains("Failed to release model feed capabilities"))
    #expect(await modelFeedAllCapabilityLeaseOwners(core).isEmpty)
    #expect(await backend.isDetached())
    await #expect(throws: WebInspectorProxyError.self) {
        try await core.openModelFeed(configuredDomains: [])
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
    let pageDisable = try await backend.waitForTargetMessage(method: "Page.disable")
    await modelFeedRespond(to: pageDisable, core: core)
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

@Test
func modelBindingCommandWaitsForInitialSynchronizationBeforeWire() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))

    let openTask = Task {
        try await core.openModelFeed(
            configuredDomains: [.dom, .network]
        )
    }
    let bootstrap = try await backend.waitForTargetMessage(method: "DOM.getDocument")
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)
    let networkEnable = try await backend.waitForTargetMessage(method: "Network.enable")
    await modelFeedRespond(to: networkEnable, core: core)
    let feed = try await openTask.value
    let generation = try await core.pageGeneration()
    let authorization = ConnectionModelCommandAuthorization(
        feedID: feed.id,
        generation: generation
    )

    let commandTask = Task {
        try await core.send(modelFeedCommand(
            domain: .page,
            method: "Page.reload",
            authority: authorization
        ))
    }
    await core.waitForModelCommandReadinessWaiterCountForTesting(1)
    #expect(await backend.sentTargetMessages().allSatisfy {
        (try? modelFeedMessageMethod($0.message)) != "Page.reload"
    })

    await modelFeedRespondWithDocument(to: bootstrap, core: core)
    let reload = try await backend.waitForTargetMessage(method: "Page.reload")
    await modelFeedRespond(to: reload, core: core)
    _ = try await commandTask.value
    await core.waitForModelCommandOwnerCountForTesting(0)

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable", "Network.enable"]
    )
    await core.close()
}

@Test
func ordinaryFrameLoadersAdvanceOnlyTheDeliveringRuntimeBinding() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main", type: "page", frameID: "main-frame"
    ))
    let feed = try await modelFeedOpenSuccessfully(
        core: core, backend: backend, configuredDomains: [.runtime], targetID: "page-main"
    )
    var iterator = feed.records.makeAsyncIterator()
    let generation = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    _ = try await modelFeedRequireReplayCompletion(iterator.next())
    _ = try await modelFeedRequireSynchronization(iterator.next())

    let originalAuthority = modelRuntimeAuthorization(
        feedID: feed.id,
        generation: generation,
        agentTargetID: "page-main",
        runtimeEpoch: 0,
        semanticTargetID: "page-main",
        navigationEpoch: 0
    )

    _ = await core.receiveRootMessage(
        #"{"method":"Page.frameNavigated","params":{"frame":{"id":"ordinary-frame-a","parentId":"main-frame","loaderId":"loader-a","url":"https://example.test/a","securityOrigin":"https://example.test","mimeType":"text/html"}}}"#
    )
    let firstChildNavigation = try await modelFeedRequireEvent(iterator.next())
    #expect(firstChildNavigation.target.id == WebInspectorTarget.ID("page-main"))
    #expect(firstChildNavigation.agentTarget.id == WebInspectorTarget.ID("page-main"))
    #expect(firstChildNavigation.navigationEpoch == ModelNavigationEpoch(rawValue: 0))
    #expect(firstChildNavigation.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 1))

    var baseline = await backend.sentTargetMessages().count
    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        _ = try await core.send(modelFeedCommand(
            domain: .runtime,
            method: "Runtime.getProperties",
            authority: originalAuthority,
            routing: .target(ProtocolTarget.ID("page-main"))
        ))
    }
    #expect(await backend.sentTargetMessages().count == baseline)

    let firstChildAuthority = modelRuntimeAuthorization(
        feedID: feed.id,
        generation: generation,
        agentTargetID: "page-main",
        runtimeEpoch: 1,
        semanticTargetID: "page-main",
        navigationEpoch: 0
    )
    baseline = try await modelFeedSendRuntimeCommand(
        core: core,
        backend: backend,
        authorization: firstChildAuthority,
        targetID: "page-main",
        after: baseline
    )

    for (frameID, loaderID, expectedRuntimeEpoch) in [
        ("ordinary-frame-b", "loader-b", UInt64(2)),
        ("ordinary-frame-a", "loader-a", UInt64(2)),
    ] {
        _ = await core.receiveRootMessage(
            #"{"method":"Page.frameNavigated","params":{"frame":{"id":"\#(frameID)","parentId":"main-frame","loaderId":"\#(loaderID)","url":"https://example.test/child","securityOrigin":"https://example.test","mimeType":"text/html"}}}"#
        )
        let navigation = try await modelFeedRequireEvent(iterator.next())
        #expect(navigation.navigationEpoch == ModelNavigationEpoch(rawValue: 0))
        #expect(navigation.runtimeBindingEpoch
            == ModelRuntimeBindingEpoch(rawValue: expectedRuntimeEpoch))
    }

    let latestChildAuthority = modelRuntimeAuthorization(
        feedID: feed.id,
        generation: generation,
        agentTargetID: "page-main",
        runtimeEpoch: 2,
        semanticTargetID: "page-main",
        navigationEpoch: 0
    )
    baseline = try await modelFeedSendRuntimeCommand(
        core: core,
        backend: backend,
        authorization: latestChildAuthority,
        targetID: "page-main",
        after: baseline
    )

    _ = await core.receiveRootMessage(
        #"{"method":"Page.frameNavigated","params":{"frame":{"id":"main-frame","loaderId":"main-loader","url":"https://example.test/main","securityOrigin":"https://example.test","mimeType":"text/html"}}}"#
    )
    let mainNavigation = try await modelFeedRequireEvent(iterator.next())
    #expect(mainNavigation.navigationEpoch == ModelNavigationEpoch(rawValue: 1))
    #expect(mainNavigation.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 3))

    let staleNavigationAuthority = modelRuntimeAuthorization(
        feedID: feed.id,
        generation: generation,
        agentTargetID: "page-main",
        runtimeEpoch: 3,
        semanticTargetID: "page-main",
        navigationEpoch: 0
    )
    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        _ = try await core.send(modelFeedCommand(
            domain: .runtime,
            method: "Runtime.getProperties",
            authority: staleNavigationAuthority,
            routing: .target(ProtocolTarget.ID("page-main"))
        ))
    }
    #expect(await backend.sentTargetMessages().count == baseline)

    let currentAuthority = modelRuntimeAuthorization(
        feedID: feed.id,
        generation: generation,
        agentTargetID: "page-main",
        runtimeEpoch: 3,
        semanticTargetID: "page-main",
        navigationEpoch: 1
    )
    _ = try await modelFeedSendRuntimeCommand(
        core: core,
        backend: backend,
        authorization: currentAuthority,
        targetID: "page-main",
        after: baseline
    )

    try await modelFeedCloseSuccessfully(
        feed, core: core, backend: backend, targetID: "page-main",
        enableMethods: ["Page.enable", "Runtime.enable"]
    )
    await core.close()
}

@Test
func frameAgentRootAndChildNavigationAdvanceDifferentEpochs() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main", type: "page", frameID: "main-frame"
    ))
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "frame-agent",
        type: "frame",
        frameID: "isolated-frame",
        parentFrameID: "main-frame"
    ))
    let feed = try await modelFeedOpenSuccessfully(
        core: core, backend: backend, configuredDomains: [.runtime], targetID: "page-main"
    )
    var iterator = feed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    _ = try await modelFeedRequireReplayCompletion(iterator.next())
    _ = try await modelFeedRequireSynchronization(iterator.next())

    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "frame-agent",
        message: #"{"method":"Page.frameNavigated","params":{"frame":{"id":"isolated-frame","loaderId":"root-loader","url":"https://example.test/frame","securityOrigin":"https://example.test","mimeType":"text/html"}}}"#
    ))
    let rootNavigation = try await modelFeedRequireEvent(iterator.next())
    #expect(rootNavigation.target.id == WebInspectorTarget.ID("frame-agent"))
    #expect(rootNavigation.agentTarget.id == WebInspectorTarget.ID("frame-agent"))
    #expect(rootNavigation.navigationEpoch == ModelNavigationEpoch(rawValue: 1))
    #expect(rootNavigation.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 1))

    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "frame-agent",
        message: #"{"method":"Page.frameNavigated","params":{"frame":{"id":"nested-frame","parentId":"isolated-frame","loaderId":"nested-loader","url":"https://example.test/nested","securityOrigin":"https://example.test","mimeType":"text/html"}}}"#
    ))
    let childNavigation = try await modelFeedRequireEvent(iterator.next())
    #expect(childNavigation.target.id == WebInspectorTarget.ID("frame-agent"))
    #expect(childNavigation.agentTarget.id == WebInspectorTarget.ID("frame-agent"))
    #expect(childNavigation.navigationEpoch == ModelNavigationEpoch(rawValue: 1))
    #expect(childNavigation.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 2))

    try await modelFeedCloseSuccessfully(
        feed, core: core, backend: backend, targetID: "page-main",
        enableMethods: ["Page.enable", "Runtime.enable"]
    )
    await core.close()
}

@Test
func semanticFrameNavigationDeduplicatesAcrossDeliveringAgents() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main", type: "page", frameID: "main-frame"
    ))
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "frame-agent", type: "frame", frameID: "isolated-frame",
        parentFrameID: "main-frame"
    ))
    let feed = try await modelFeedOpenSuccessfully(
        core: core, backend: backend, configuredDomains: [.runtime], targetID: "page-main"
    )
    var iterator = feed.records.makeAsyncIterator()
    _ = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    _ = try await modelFeedRequireReplayCompletion(iterator.next())
    _ = try await modelFeedRequireSynchronization(iterator.next())

    let navigationMessage =
        #"{"method":"Page.frameNavigated","params":{"frame":{"id":"isolated-frame","loaderId":"shared-loader","url":"https://example.test/frame","securityOrigin":"https://example.test","mimeType":"text/html"}}}"#
    _ = await core.receiveRootMessage(navigationMessage)
    let pageAgentDelivery = try await modelFeedRequireEvent(iterator.next())
    #expect(pageAgentDelivery.target.id == WebInspectorTarget.ID("frame-agent"))
    #expect(pageAgentDelivery.agentTarget.id == WebInspectorTarget.ID("page-main"))
    #expect(pageAgentDelivery.navigationEpoch == ModelNavigationEpoch(rawValue: 1))
    #expect(pageAgentDelivery.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 1))

    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "frame-agent",
        message: navigationMessage
    ))
    let frameAgentDelivery = try await modelFeedRequireEvent(iterator.next())
    #expect(frameAgentDelivery.target.id == WebInspectorTarget.ID("frame-agent"))
    #expect(frameAgentDelivery.agentTarget.id == WebInspectorTarget.ID("frame-agent"))
    #expect(frameAgentDelivery.navigationEpoch == ModelNavigationEpoch(rawValue: 1))
    #expect(frameAgentDelivery.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 1))

    let ordinaryNavigationMessage =
        #"{"method":"Page.frameNavigated","params":{"frame":{"id":"shared-ordinary-frame","parentId":"isolated-frame","loaderId":"ordinary-loader","url":"https://example.test/ordinary","securityOrigin":"https://example.test","mimeType":"text/html"}}}"#
    _ = await core.receiveRootMessage(ordinaryNavigationMessage)
    let pageOrdinaryDelivery = try await modelFeedRequireEvent(iterator.next())
    guard case let .target(
        .frameNavigated(_, pageObservedNewLoader)
    ) = pageOrdinaryDelivery.payload else {
        Issue.record("Expected the page agent's ordinary-frame navigation.")
        return
    }
    #expect(pageOrdinaryDelivery.target.id == WebInspectorTarget.ID("page-main"))
    #expect(pageOrdinaryDelivery.navigationEpoch == ModelNavigationEpoch(rawValue: 0))
    #expect(pageOrdinaryDelivery.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 2))
    #expect(pageObservedNewLoader)

    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "frame-agent",
        message: ordinaryNavigationMessage
    ))
    let frameOrdinaryDelivery = try await modelFeedRequireEvent(iterator.next())
    guard case let .target(
        .frameNavigated(_, frameObservedNewLoader)
    ) = frameOrdinaryDelivery.payload else {
        Issue.record("Expected the frame agent's ordinary-frame navigation.")
        return
    }
    #expect(frameOrdinaryDelivery.target.id == WebInspectorTarget.ID("frame-agent"))
    #expect(frameOrdinaryDelivery.navigationEpoch == ModelNavigationEpoch(rawValue: 1))
    #expect(frameOrdinaryDelivery.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 2))
    #expect(!frameObservedNewLoader)

    try await modelFeedCloseSuccessfully(
        feed, core: core, backend: backend, targetID: "page-main",
        enableMethods: ["Page.enable", "Runtime.enable"]
    )
    await core.close()
}

@Test
func runtimeBindingEpochScopesAndWireAdmissionTrackOnlyTheDeliveringAgent() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main", type: "page", frameID: "main-frame"
    ))
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "frame-a", type: "frame", frameID: "frame-a", parentFrameID: "main-frame"
    ))
    let feed = try await modelFeedOpenSuccessfully(
        core: core, backend: backend, configuredDomains: [.runtime], targetID: "page-main"
    )
    var iterator = feed.records.makeAsyncIterator()
    let generation = try await modelFeedRequireReset(iterator.next())
    let snapshot = try await modelFeedRequireTargetSnapshot(iterator.next())
    #expect(snapshot.snapshot.targets.allSatisfy {
        $0.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 0)
    })
    _ = try await modelFeedRequireReplayCompletion(iterator.next())
    _ = try await modelFeedRequireSynchronization(iterator.next())

    let oldRoot = modelRuntimeAuthorization(
        feedID: feed.id, generation: generation, agentTargetID: "page-main",
        runtimeEpoch: 0, semanticTargetID: "frame-a", navigationEpoch: 0
    )
    let otherAgent = modelRuntimeAuthorization(
        feedID: feed.id, generation: generation, agentTargetID: "frame-a", runtimeEpoch: 0
    )
    _ = await core.receiveRootMessage(
        #"{"method":"Page.frameNavigated","params":{"frame":{"id":"frame-a","loaderId":"loader-1","url":"https://example.test/frame","securityOrigin":"https://example.test","mimeType":"text/html"}}}"#
    )
    let navigation = try await modelFeedRequireEvent(iterator.next())
    #expect(navigation.target.id == WebInspectorTarget.ID("frame-a"))
    #expect(navigation.agentTarget.id == WebInspectorTarget.ID("page-main"))
    #expect(navigation.navigationEpoch == ModelNavigationEpoch(rawValue: 1))
    #expect(navigation.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 1))

    var baseline = await backend.sentTargetMessages().count
    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        _ = try await core.send(modelFeedCommand(
            domain: .runtime, method: "Runtime.getProperties", authority: oldRoot,
            routing: .target(ProtocolTarget.ID("page-main"))
        ))
    }
    #expect(await backend.sentTargetMessages().count == baseline)
    baseline = try await modelFeedSendRuntimeCommand(
        core: core, backend: backend, authorization: otherAgent,
        targetID: "frame-a", after: baseline
    )

    let epochOne = modelRuntimeAuthorization(
        feedID: feed.id, generation: generation, agentTargetID: "page-main",
        runtimeEpoch: 1, semanticTargetID: "frame-a", navigationEpoch: 1
    )
    baseline = try await modelFeedSendRuntimeCommand(
        core: core, backend: backend, authorization: epochOne,
        targetID: "page-main", after: baseline
    )
    _ = await core.receiveRootMessage(
        #"{"method":"Runtime.executionContextsCleared","params":{}}"#
    )
    let clear = try await modelFeedRequireEvent(iterator.next())
    #expect(clear.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 2))
    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        _ = try await core.send(modelFeedCommand(
            domain: .runtime, method: "Runtime.getProperties", authority: epochOne,
            routing: .target(ProtocolTarget.ID("page-main"))
        ))
    }
    #expect(await backend.sentTargetMessages().count == baseline)
    let epochTwo = modelRuntimeAuthorization(
        feedID: feed.id, generation: generation, agentTargetID: "page-main", runtimeEpoch: 2
    )
    _ = try await modelFeedSendRuntimeCommand(
        core: core, backend: backend, authorization: epochTwo,
        targetID: "page-main", after: baseline
    )

    try await modelFeedCloseSuccessfully(
        feed, core: core, backend: backend, targetID: "page-main",
        enableMethods: ["Page.enable", "Runtime.enable"]
    )
    await core.close()
}

@Test
func consoleBindingEpochInvalidatesOnlyConsoleOwnedRuntimeAuthority() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main", type: "page", frameID: "main-frame"
    ))
    let feed = try await modelFeedOpenSuccessfully(
        core: core, backend: backend,
        configuredDomains: [.runtime, .console], targetID: "page-main"
    )
    var iterator = feed.records.makeAsyncIterator()
    let generation = try await modelFeedRequireReset(iterator.next())
    let snapshot = try await modelFeedRequireTargetSnapshot(iterator.next())
    let initial = try #require(snapshot.snapshot.targets.first)
    #expect(initial.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 0))
    #expect(initial.consoleBindingEpoch == ModelConsoleBindingEpoch(rawValue: 0))
    #expect(try await modelFeedRequireReplayCompletion(iterator.next()).domain == .runtime)
    #expect(try await modelFeedRequireReplayCompletion(iterator.next()).domain == .console)
    _ = try await modelFeedRequireSynchronization(iterator.next())

    let oldConsole = modelRuntimeAuthorization(
        feedID: feed.id, generation: generation, agentTargetID: "page-main",
        runtimeEpoch: 0, consoleEpoch: 0
    )
    let independent = modelRuntimeAuthorization(
        feedID: feed.id, generation: generation, agentTargetID: "page-main", runtimeEpoch: 0
    )
    _ = await core.receiveRootMessage(
        #"{"method":"Console.messagesCleared","params":{"reason":"console-api"}}"#
    )
    let clear = try await modelFeedRequireEvent(iterator.next())
    #expect(clear.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 0))
    #expect(clear.consoleBindingEpoch == ModelConsoleBindingEpoch(rawValue: 1))

    var baseline = await backend.sentTargetMessages().count
    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        _ = try await core.send(modelFeedCommand(
            domain: .runtime, method: "Runtime.getProperties", authority: oldConsole,
            routing: .target(ProtocolTarget.ID("page-main"))
        ))
    }
    #expect(await backend.sentTargetMessages().count == baseline)
    baseline = try await modelFeedSendRuntimeCommand(
        core: core, backend: backend, authorization: independent,
        targetID: "page-main", after: baseline
    )

    let freshConsole = modelRuntimeAuthorization(
        feedID: feed.id, generation: generation, agentTargetID: "page-main",
        runtimeEpoch: 0, consoleEpoch: 1
    )
    baseline = try await modelFeedSendRuntimeCommand(
        core: core, backend: backend, authorization: freshConsole,
        targetID: "page-main", after: baseline
    )
    _ = await core.receiveRootMessage(
        #"{"method":"Page.frameNavigated","params":{"frame":{"id":"main-frame","loaderId":"main-loader-1","url":"https://example.test/next","securityOrigin":"https://example.test","mimeType":"text/html"}}}"#
    )
    let navigation = try await modelFeedRequireEvent(iterator.next())
    #expect(navigation.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 1))
    #expect(navigation.consoleBindingEpoch == ModelConsoleBindingEpoch(rawValue: 1))
    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        _ = try await core.send(modelFeedCommand(
            domain: .runtime, method: "Runtime.getProperties", authority: freshConsole,
            routing: .target(ProtocolTarget.ID("page-main"))
        ))
    }
    #expect(await backend.sentTargetMessages().count == baseline)
    let navigatedConsole = modelRuntimeAuthorization(
        feedID: feed.id, generation: generation, agentTargetID: "page-main",
        runtimeEpoch: 1, consoleEpoch: 1
    )
    _ = try await modelFeedSendRuntimeCommand(
        core: core, backend: backend, authorization: navigatedConsole,
        targetID: "page-main", after: baseline
    )

    try await modelFeedCloseSuccessfully(
        feed, core: core, backend: backend, targetID: "page-main",
        enableMethods: ["Page.enable", "Runtime.enable", "Console.enable"]
    )
    await core.close()
}

@Test
func consoleOnlyFeedArmsRuntimeInvalidationWithoutProjectingRuntimeContexts() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main", type: "page", frameID: "main-frame"
    ))
    let feed = try await modelFeedOpenSuccessfully(
        core: core, backend: backend, configuredDomains: [.console], targetID: "page-main"
    )
    var iterator = feed.records.makeAsyncIterator()
    let generation = try await modelFeedRequireReset(iterator.next())
    let snapshot = try await modelFeedRequireTargetSnapshot(iterator.next())
    let initial = try #require(snapshot.snapshot.targets.first)
    #expect(initial.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 0))
    #expect(initial.consoleBindingEpoch == ModelConsoleBindingEpoch(rawValue: 0))
    #expect(try await modelFeedRequireReplayCompletion(iterator.next()).domain == .console)
    _ = try await modelFeedRequireSynchronization(iterator.next())
    #expect(try await modelFeedSentTargetMethods(backend) == [
        "Page.enable", "Runtime.enable", "Console.enable",
    ])

    _ = await core.receiveRootMessage(
        #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":42,"type":"normal","name":"not projected","frameId":"main-frame"}}}"#
    )
    _ = await core.receiveRootMessage(
        #"{"method":"Console.messageAdded","params":{"message":{"source":"console-api","level":"log","text":"visible"}}}"#
    )
    guard case .console(.messageAdded) = try await modelFeedRequireEvent(iterator.next()).payload else {
        Issue.record("Console-only feeds must not project RuntimeContext creation.")
        return
    }

    let old = modelRuntimeAuthorization(
        feedID: feed.id, generation: generation, agentTargetID: "page-main",
        runtimeEpoch: 0, consoleEpoch: 0
    )
    _ = await core.receiveRootMessage(
        #"{"method":"Runtime.executionContextsCleared","params":{}}"#
    )
    let runtimeClear = try await modelFeedRequireEvent(iterator.next())
    guard case .runtime(.executionContextsCleared) = runtimeClear.payload else {
        Issue.record("Expected an operational Runtime clear boundary.")
        return
    }
    #expect(runtimeClear.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 1))

    let baseline = await backend.sentTargetMessages().count
    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        _ = try await core.send(modelFeedCommand(
            domain: .runtime, method: "Runtime.getProperties", authority: old,
            routing: .target(ProtocolTarget.ID("page-main"))
        ))
    }
    #expect(await backend.sentTargetMessages().count == baseline)
    let fresh = modelRuntimeAuthorization(
        feedID: feed.id, generation: generation, agentTargetID: "page-main",
        runtimeEpoch: 1, consoleEpoch: 0
    )
    _ = try await modelFeedSendRuntimeCommand(
        core: core, backend: backend, authorization: fresh,
        targetID: "page-main", after: baseline
    )

    let independent = modelRuntimeAuthorization(
        feedID: feed.id, generation: generation, agentTargetID: "page-main", runtimeEpoch: 1
    )
    await #expect(throws: ConnectionModelCommandError.domainNotConfigured(.runtime)) {
        _ = try await core.send(modelFeedCommand(
            domain: .runtime, method: "Runtime.getProperties", authority: independent,
            routing: .target(ProtocolTarget.ID("page-main"))
        ))
    }
    try await modelFeedCloseSuccessfully(
        feed, core: core, backend: backend, targetID: "page-main",
        enableMethods: ["Page.enable", "Runtime.enable", "Console.enable"]
    )
    await core.close()
}

@Test
func runtimeBindingEpochDoesNotReuseATargetBindingAfterTargetLoss() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main", type: "page", frameID: "main-frame"
    ))
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "frame-agent", type: "frame", frameID: "frame-agent",
        parentFrameID: "main-frame"
    ))
    let feed = try await modelFeedOpenSuccessfully(
        core: core, backend: backend, configuredDomains: [.runtime], targetID: "page-main"
    )
    var iterator = feed.records.makeAsyncIterator()
    let generation = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    _ = try await modelFeedRequireReplayCompletion(iterator.next())
    _ = try await modelFeedRequireSynchronization(iterator.next())
    let old = modelRuntimeAuthorization(
        feedID: feed.id, generation: generation, agentTargetID: "frame-agent", runtimeEpoch: 0
    )

    _ = await core.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"frame-agent"}}"#
    )
    #expect(try await modelFeedRequireEvent(iterator.next()).runtimeBindingEpoch
        == ModelRuntimeBindingEpoch(rawValue: 0))
    var baseline = await backend.sentTargetMessages().count
    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        _ = try await core.send(modelFeedCommand(
            domain: .runtime, method: "Runtime.getProperties", authority: old,
            routing: .target(ProtocolTarget.ID("frame-agent"))
        ))
    }
    #expect(await backend.sentTargetMessages().count == baseline)

    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "frame-agent", type: "frame", frameID: "frame-agent",
        parentFrameID: "main-frame"
    ))
    #expect(try await modelFeedRequireEvent(iterator.next()).runtimeBindingEpoch
        == ModelRuntimeBindingEpoch(rawValue: 1))
    let fresh = modelRuntimeAuthorization(
        feedID: feed.id, generation: generation, agentTargetID: "frame-agent", runtimeEpoch: 1
    )
    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        _ = try await core.send(modelFeedCommand(
            domain: .runtime, method: "Runtime.getProperties", authority: fresh,
            routing: .target(ProtocolTarget.ID("page-main"))
        ))
    }
    #expect(await backend.sentTargetMessages().count == baseline)
    baseline = try await modelFeedSendRuntimeCommand(
        core: core, backend: backend, authorization: fresh,
        targetID: "frame-agent", after: baseline
    )
    _ = baseline
    try await modelFeedCloseSuccessfully(
        feed, core: core, backend: backend, targetID: "page-main",
        enableMethods: ["Page.enable", "Runtime.enable"]
    )
    await core.close()
}

@Test
func pageReplacementRejectsOldConsoleRuntimeAuthorityAndIssuesANewBinding() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-old", type: "page", frameID: "main-frame"
    ))
    let feed = try await modelFeedOpenSuccessfully(
        core: core, backend: backend, configuredDomains: [.console], targetID: "page-old"
    )
    var iterator = feed.records.makeAsyncIterator()
    let oldGeneration = try await modelFeedRequireReset(iterator.next())
    _ = try await modelFeedRequireTargetSnapshot(iterator.next())
    _ = try await modelFeedRequireReplayCompletion(iterator.next())
    _ = try await modelFeedRequireSynchronization(iterator.next())
    let old = modelRuntimeAuthorization(
        feedID: feed.id, generation: oldGeneration, agentTargetID: "page-old",
        runtimeEpoch: 0, consoleEpoch: 0
    )
    _ = await core.receiveRootMessage(
        #"{"method":"Target.targetDestroyed","params":{"targetId":"page-old"}}"#
    )
    let baseline = await backend.sentTargetMessages().count
    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        _ = try await core.send(modelFeedCommand(
            domain: .runtime, method: "Runtime.getProperties", authority: old,
            routing: .target(ProtocolTarget.ID("page-old"))
        ))
    }
    #expect(await backend.sentTargetMessages().count == baseline)

    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-new", type: "page", frameID: "main-frame"
    ))
    for method in ["Page.enable", "Runtime.enable", "Console.enable"] {
        let message = try await backend.waitForTargetMessage(method: method, ordinal: 1)
        await modelFeedRespond(to: message, core: core)
    }
    let replacementGeneration = try await modelFeedRequireReset(iterator.next())
    let snapshot = try await modelFeedRequireTargetSnapshot(iterator.next())
    #expect(replacementGeneration.rawValue == oldGeneration.rawValue + 1)
    #expect(snapshot.snapshot.currentPageID == WebInspectorTarget.ID("page-new"))
    #expect(snapshot.snapshot.targets.first?.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 0))
    #expect(snapshot.snapshot.targets.first?.consoleBindingEpoch == ModelConsoleBindingEpoch(rawValue: 0))
    _ = try await modelFeedRequireReplayCompletion(iterator.next())
    _ = try await modelFeedRequireSynchronization(iterator.next())

    let fresh = modelRuntimeAuthorization(
        feedID: feed.id, generation: replacementGeneration, agentTargetID: "page-new",
        runtimeEpoch: 0, consoleEpoch: 0
    )
    _ = try await modelFeedSendRuntimeCommand(
        core: core, backend: backend, authorization: fresh,
        targetID: "page-new", after: await backend.sentTargetMessages().count
    )
    try await modelFeedCloseSuccessfully(
        feed, core: core, backend: backend, targetID: "page-new",
        enableMethods: ["Page.enable", "Runtime.enable", "Console.enable"]
    )
    await core.close()
}

@Test
func documentAndRuntimeAuthorityValidateTheirBindingEpochsIndependently() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main", type: "page", frameID: "main-frame"
    ))
    let feed = try await modelFeedOpenSuccessfully(
        core: core, backend: backend,
        configuredDomains: [.dom, .runtime], targetID: "page-main"
    )
    let generation = try await core.pageGeneration()
    let old = modelRuntimeAuthorization(
        feedID: feed.id, generation: generation, agentTargetID: "page-main",
        runtimeEpoch: 0, semanticTargetID: "page-main", navigationEpoch: 0,
        document: ConnectionModelCommandAuthorization.Document(
            targetID: WebInspectorTarget.ID("page-main"),
            epoch: ModelDOMBindingEpoch(rawValue: 0)
        )
    )
    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: #"{"method":"DOM.documentUpdated","params":{}}"#
    ))
    let bootstrap = try await backend.waitForTargetMessage(
        method: "DOM.getDocument", ordinal: 1
    )
    var baseline = await backend.sentTargetMessages().count
    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        _ = try await core.send(modelFeedCommand(
            domain: .dom, method: "DOM.querySelector", authority: old,
            routing: .target(ProtocolTarget.ID("page-main"))
        ))
    }
    #expect(await backend.sentTargetMessages().count == baseline)
    baseline = try await modelFeedSendRuntimeCommand(
        core: core, backend: backend, authorization: old,
        targetID: "page-main", after: baseline
    )
    await modelFeedRespondWithDocument(to: bootstrap, core: core, nodeID: "replacement")
    _ = await core.receiveRootMessage(
        #"{"method":"Runtime.executionContextsCleared","params":{}}"#
    )
    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        _ = try await core.send(modelFeedCommand(
            domain: .runtime, method: "Runtime.getProperties", authority: old,
            routing: .target(ProtocolTarget.ID("page-main"))
        ))
    }
    #expect(await backend.sentTargetMessages().count == baseline)
    try await modelFeedCloseSuccessfully(
        feed, core: core, backend: backend, targetID: "page-main",
        enableMethods: ["Page.enable", "Runtime.enable"]
    )
    await core.close()
}

@Test
func documentRefreshInvalidatesDocumentCommandsButPreservesBindingCommands() async throws {
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
        configuredDomains: [.css, .network],
        targetID: "page-main"
    )
    let generation = try await core.pageGeneration()
    let oldDocument = ConnectionModelCommandAuthorization.Document(
        targetID: WebInspectorTarget.ID("page-main"),
        epoch: ModelDOMBindingEpoch(rawValue: 0)
    )
    let documentAuthorization = ConnectionModelCommandAuthorization(
        feedID: feed.id,
        generation: generation,
        document: oldDocument
    )
    let bindingAuthorization = ConnectionModelCommandAuthorization(
        feedID: feed.id,
        generation: generation,
        document: oldDocument
    )
    let baseline = await backend.sentTargetMessages().count

    let domTask = Task {
        try await core.send(modelFeedCommand(
            domain: .dom,
            method: "DOM.querySelector",
            authority: documentAuthorization
        ))
    }
    let cssTask = Task {
        try await core.send(modelFeedCommand(
            domain: .css,
            method: "CSS.getMatchedStylesForNode",
            authority: documentAuthorization
        ))
    }
    let networkTask = Task {
        try await core.send(modelFeedCommand(
            domain: .network,
            method: "Network.getResponseBody",
            authority: bindingAuthorization
        ))
    }
    let domMessage = try await backend.waitForTargetMessage(
        method: "DOM.querySelector",
        after: baseline
    )
    let cssMessage = try await backend.waitForTargetMessage(
        method: "CSS.getMatchedStylesForNode",
        after: baseline
    )
    let networkMessage = try await backend.waitForTargetMessage(
        method: "Network.getResponseBody",
        after: baseline
    )

    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: #"{"method":"DOM.documentUpdated","params":{}}"#
    ))
    let refreshedCSSSnapshot = try await backend.waitForTargetMessage(
        method: "CSS.getAllStyleSheets",
        ordinal: 1
    )
    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        try await domTask.value
    }
    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        try await cssTask.value
    }
    await modelFeedRespond(to: domMessage, core: core)
    await modelFeedRespond(to: cssMessage, core: core)
    await modelFeedRespond(to: networkMessage, core: core)
    await modelFeedRespondWithStyleSheets(to: refreshedCSSSnapshot, core: core)
    _ = try await networkTask.value

    let countBeforeOldAuthority = await backend.sentTargetMessages().count
    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        _ = try await core.send(modelFeedCommand(
            domain: .dom,
            method: "DOM.querySelector",
            authority: documentAuthorization
        ))
    }
    #expect(await backend.sentTargetMessages().count == countBeforeOldAuthority)

    let pageTask = Task {
        try await core.send(modelFeedCommand(
            domain: .page,
            method: "Page.reload",
            authority: bindingAuthorization
        ))
    }
    let pageMessage = try await backend.waitForTargetMessage(
        method: "Page.reload",
        after: countBeforeOldAuthority
    )
    await modelFeedRespond(to: pageMessage, core: core)
    _ = try await pageTask.value

    let freshAuthorization = ConnectionModelCommandAuthorization(
        feedID: feed.id,
        generation: generation,
        document: ConnectionModelCommandAuthorization.Document(
            targetID: WebInspectorTarget.ID("page-main"),
            epoch: ModelDOMBindingEpoch(rawValue: 1)
        )
    )
    let freshDOMTask = Task {
        try await core.send(modelFeedCommand(
            domain: .dom,
            method: "DOM.querySelector",
            authority: freshAuthorization
        ))
    }
    let freshCSSTask = Task {
        try await core.send(modelFeedCommand(
            domain: .css,
            method: "CSS.getMatchedStylesForNode",
            authority: freshAuthorization
        ))
    }
    let freshPickerTask = Task {
        try await core.send(modelFeedCommand(
            domain: .inspector,
            method: "Inspector.setInspectModeEnabled",
            authority: freshAuthorization
        ))
    }
    await core.waitForModelCommandReadinessWaiterCountForTesting(3)
    let beforeFreshBootstrap = await backend.sentTargetMessages().count
    let refreshBootstrap = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        after: baseline
    )
    #expect(await backend.sentTargetMessages().count == beforeFreshBootstrap)
    await modelFeedRespondWithDocument(to: refreshBootstrap, core: core, nodeID: "fresh")
    let freshDOMMessage = try await backend.waitForTargetMessage(
        method: "DOM.querySelector",
        after: beforeFreshBootstrap
    )
    let freshCSSMessage = try await backend.waitForTargetMessage(
        method: "CSS.getMatchedStylesForNode",
        after: beforeFreshBootstrap
    )
    let freshPickerMessage = try await backend.waitForTargetMessage(
        method: "Inspector.setInspectModeEnabled",
        after: beforeFreshBootstrap
    )
    await modelFeedRespond(to: freshDOMMessage, core: core)
    await modelFeedRespond(to: freshCSSMessage, core: core)
    await modelFeedRespond(to: freshPickerMessage, core: core)
    _ = try await freshDOMTask.value
    _ = try await freshCSSTask.value
    _ = try await freshPickerTask.value
    await core.waitForModelCommandOwnerCountForTesting(0)

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable", "CSS.enable", "Network.enable"]
    )
    await core.close()
}

@Test
func modelAuthorityRejectsForeignUnconfiguredAndConnectionOwnedCommandsWithoutWire() async throws {
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
        configuredDomains: [],
        targetID: "page-main"
    )
    let authorization = ConnectionModelCommandAuthorization(
        feedID: feed.id,
        generation: try await core.pageGeneration(),
        document: ConnectionModelCommandAuthorization.Document(
            targetID: WebInspectorTarget.ID("page-main"),
            epoch: ModelDOMBindingEpoch(rawValue: 0)
        )
    )
    let baseline = await backend.sentTargetMessages().count

    await #expect(throws: WebInspectorProxyError.connectionInUse) {
        _ = try await core.send(ProtocolCommand(
            domain: .dom,
            method: "DOM.enable",
            routing: .octopus(pageTarget: nil)
        ))
    }
    await #expect(throws: ConnectionModelCommandError.domainNotConfigured(.dom)) {
        _ = try await core.send(modelFeedCommand(
            domain: .dom,
            method: "DOM.querySelector",
            authority: authorization
        ))
    }
    await #expect(throws: ConnectionModelCommandError.internalCommand(
        domain: .network,
        method: "Network.enable"
    )) {
        _ = try await core.send(modelFeedCommand(
            domain: .network,
            method: "Network.enable",
            authority: authorization
        ))
    }

    let foreignCore = ConnectionCore(backend: FakeTransportBackend(), responseTimeout: nil)
    await #expect(throws: ConnectionModelCommandError.notActive) {
        _ = try await foreignCore.send(modelFeedCommand(
            domain: .page,
            method: "Page.reload",
            authority: authorization
        ))
    }
    #expect(await backend.sentTargetMessages().count == baseline)

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable"]
    )
    await #expect(throws: ConnectionModelCommandError.notActive) {
        _ = try await core.send(modelFeedCommand(
            domain: .page,
            method: "Page.reload",
            authority: authorization
        ))
    }
    await foreignCore.close()
    await core.close()
}

@Test
func modelPageHandlePropagatesAuthorizationThroughTypedDomainDispatch() async throws {
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
        configuredDomains: [],
        targetID: "page-main"
    )
    let proxy = try await WebInspectorProxy(transport: core)
    let modelPage = WebInspectorPage(
        proxy: proxy,
        commandAuthorization: ConnectionModelCommandAuthorization(
            feedID: feed.id,
            generation: try await core.pageGeneration()
        )
    )

    let commandTask = Task {
        try await modelPage.page.reload()
    }
    let reload = try await backend.waitForTargetMessage(method: "Page.reload")
    await modelFeedRespond(to: reload, core: core)
    try await commandTask.value

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-main",
        enableMethods: ["Page.enable"]
    )
    await proxy.close()
}

@Test
func modelCommandCancellationAndFeedCloseDrainAllCommandOwnersBeforeDisable() async throws {
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
        configuredDomains: [.dom, .network],
        targetID: "page-main"
    )
    let generation = try await core.pageGeneration()
    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: "page-main",
        message: #"{"method":"DOM.documentUpdated","params":{}}"#
    ))
    let documentAuthorization = ConnectionModelCommandAuthorization(
        feedID: feed.id,
        generation: generation,
        document: ConnectionModelCommandAuthorization.Document(
            targetID: WebInspectorTarget.ID("page-main"),
            epoch: ModelDOMBindingEpoch(rawValue: 1)
        )
    )
    let bindingAuthorization = ConnectionModelCommandAuthorization(
        feedID: feed.id,
        generation: generation
    )

    let cancelledTask = Task {
        try await core.send(modelFeedCommand(
            domain: .dom,
            method: "DOM.querySelector",
            authority: documentAuthorization
        ))
    }
    await core.waitForModelCommandReadinessWaiterCountForTesting(1)
    cancelledTask.cancel()
    await #expect(throws: CancellationError.self) {
        try await cancelledTask.value
    }
    await core.waitForModelCommandOwnerCountForTesting(0)
    #expect(await core.modelCommandReadinessWaiterCountForTesting() == 0)

    let waitingTask = Task {
        try await core.send(modelFeedCommand(
            domain: .dom,
            method: "DOM.querySelector",
            authority: documentAuthorization
        ))
    }
    let pendingTask = Task {
        try await core.send(modelFeedCommand(
            domain: .page,
            method: "Page.reload",
            authority: bindingAuthorization
        ))
    }
    await core.waitForModelCommandReadinessWaiterCountForTesting(1)
    _ = try await backend.waitForTargetMessage(method: "Page.reload")
    let closeTask = Task {
        try await feed.close()
    }
    let disable = try await backend.waitForTargetMessage(method: "Network.disable")
    await #expect(throws: ConnectionModelCommandError.notActive) {
        try await waitingTask.value
    }
    await #expect(throws: ConnectionModelCommandError.notActive) {
        try await pendingTask.value
    }
    #expect(await core.modelCommandOwnerCountForTesting() == 0)
    #expect(await core.modelCommandReadinessWaiterCountForTesting() == 0)
    await modelFeedRespond(to: disable, core: core)
    let pageDisable = try await backend.waitForTargetMessage(method: "Page.disable")
    await modelFeedRespond(to: pageDisable, core: core)
    try await closeTask.value
    await core.close()
}

@Test
func retargetFailsModelCommandsForOldMainAndFrameBinding() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "frame-child",
        type: "frame",
        frameID: "child-frame",
        parentFrameID: "main-frame"
    ))
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-next",
        type: "page",
        frameID: "main-frame",
        isProvisional: true
    ))
    let feed = try await modelFeedOpenSuccessfully(
        core: core,
        backend: backend,
        configuredDomains: [],
        targetID: "page-main"
    )
    let authorization = ConnectionModelCommandAuthorization(
        feedID: feed.id,
        generation: try await core.pageGeneration()
    )
    let baseline = await backend.sentTargetMessages().count
    let mainTask = Task {
        try await core.send(modelFeedCommand(
            domain: .page,
            method: "Page.reload",
            authority: authorization,
            routing: .target(ProtocolTarget.ID("page-main"))
        ))
    }
    let frameTask = Task {
        try await core.send(modelFeedCommand(
            domain: .page,
            method: "Page.reload",
            authority: authorization,
            routing: .target(ProtocolTarget.ID("frame-child"))
        ))
    }
    _ = try await backend.waitForTargetMessage(
        method: "Page.reload",
        ordinal: 0,
        after: baseline
    )
    _ = try await backend.waitForTargetMessage(
        method: "Page.reload",
        ordinal: 1,
        after: baseline
    )

    _ = await core.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"page-next"}}"#
    )
    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        try await mainTask.value
    }
    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        try await frameTask.value
    }
    #expect(await core.modelCommandOwnerCountForTesting() == 0)

    let replacementPageEnable = try await backend.waitForTargetMessage(
        method: "Page.enable",
        ordinal: 1
    )
    await modelFeedRespond(to: replacementPageEnable, core: core)
    #expect(await core.snapshot().pendingTargetReplyKeys.isEmpty)
    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-next",
        enableMethods: ["Page.enable"]
    )
    await core.close()
}

@Test
func generationReadinessWaiterDoesNotChaseReplacementSynchronization() async throws {
    let backend = FakeTransportBackend()
    let core = ConnectionCore(backend: backend, responseTimeout: nil)
    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))
    let openTask = Task {
        try await core.openModelFeed(configuredDomains: [.dom])
    }
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: core)
    let feed = try await openTask.value
    let oldBootstrap = try await backend.waitForTargetMessage(method: "DOM.getDocument")
    let oldAuthorization = ConnectionModelCommandAuthorization(
        feedID: feed.id,
        generation: try await core.pageGeneration()
    )
    let oldTask = Task {
        try await core.send(modelFeedCommand(
            domain: .page,
            method: "Page.reload",
            authority: oldAuthorization
        ))
    }
    await core.waitForModelCommandReadinessWaiterCountForTesting(1)

    _ = await core.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-next",
        type: "page",
        frameID: "main-frame",
        isProvisional: true
    ))
    _ = await core.receiveRootMessage(
        #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-main","newTargetId":"page-next"}}"#
    )
    await #expect(throws: WebInspectorProxyError.staleIdentifier) {
        try await oldTask.value
    }
    await modelFeedRespondWithDocument(to: oldBootstrap, core: core, nodeID: "late")

    let newBootstrap = try await backend.waitForTargetMessage(
        method: "DOM.getDocument",
        ordinal: 1
    )
    let replacementPageEnable = try await backend.waitForTargetMessage(
        method: "Page.enable",
        ordinal: 1
    )
    await modelFeedRespond(to: replacementPageEnable, core: core)
    await modelFeedRespondWithDocument(to: newBootstrap, core: core, nodeID: "new")
    #expect(await backend.sentTargetMessages().allSatisfy {
        (try? modelFeedMessageMethod($0.message)) != "Page.reload"
    })

    let newAuthorization = ConnectionModelCommandAuthorization(
        feedID: feed.id,
        generation: try await core.pageGeneration()
    )
    let newTask = Task {
        try await core.send(modelFeedCommand(
            domain: .page,
            method: "Page.reload",
            authority: newAuthorization
        ))
    }
    let reload = try await backend.waitForTargetMessage(method: "Page.reload")
    await modelFeedRespond(to: reload, core: core)
    _ = try await newTask.value

    try await modelFeedCloseSuccessfully(
        feed,
        core: core,
        backend: backend,
        targetID: "page-next",
        enableMethods: ["Page.enable"]
    )
    await core.close()
}

@Test
func terminalCloseDrainsPendingModelCommandTasks() async throws {
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
        configuredDomains: [],
        targetID: "page-main"
    )
    let authorization = ConnectionModelCommandAuthorization(
        feedID: feed.id,
        generation: try await core.pageGeneration()
    )
    let commandTask = Task {
        try await core.send(modelFeedCommand(
            domain: .page,
            method: "Page.reload",
            authority: authorization
        ))
    }
    _ = try await backend.waitForTargetMessage(method: "Page.reload")

    await core.close()

    await #expect(throws: TransportSession.Error.transportClosed) {
        try await commandTask.value
    }
    #expect(await core.modelCommandOwnerCountForTesting() == 0)
    #expect(await core.modelCommandReadinessWaiterCountForTesting() == 0)
    #expect(await backend.isDetached())
}

@Test
func readinessWaitingModelCommandRunnerDoesNotKeepCoreAlive() async throws {
    let backend = FakeTransportBackend()
    var core: ConnectionCore? = ConnectionCore(backend: backend, responseTimeout: nil)
    weak let weakCore = core
    _ = await core?.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))

    var openTask: Task<ConnectionModelFeed?, any Error>? = Task { [weak core] in
        try await core?.openModelFeed(configuredDomains: [.dom])
    }
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: try #require(core))
    var feed: ConnectionModelFeed? = try await #require(openTask).value
    openTask = nil
    _ = try await backend.waitForTargetMessage(method: "DOM.getDocument")
    let authorization = ConnectionModelCommandAuthorization(
        feedID: try #require(feed?.id),
        generation: try await #require(core).pageGeneration()
    )
    feed = nil

    let runner = try await #require(core).startModelCommandForTesting(
        modelFeedCommand(
            domain: .page,
            method: "Page.reload",
            authority: authorization
        ),
        authorization: authorization
    )
    await core?.waitForModelCommandReadinessWaiterCountForTesting(1)

    core = nil

    #expect(weakCore == nil)
    await #expect(throws: TransportSession.Error.transportClosed) {
        try await runner.value
    }
}

@Test
func replyWaitingModelCommandRunnerDoesNotKeepCoreAlive() async throws {
    let backend = FakeTransportBackend()
    var core: ConnectionCore? = ConnectionCore(backend: backend, responseTimeout: nil)
    weak let weakCore = core
    _ = await core?.receiveRootMessage(modelFeedTargetCreatedMessage(
        id: "page-main",
        type: "page",
        frameID: "main-frame"
    ))

    var openTask: Task<ConnectionModelFeed?, any Error>? = Task { [weak core] in
        try await core?.openModelFeed(configuredDomains: [])
    }
    let pageEnable = try await backend.waitForTargetMessage(method: "Page.enable")
    await modelFeedRespond(to: pageEnable, core: try #require(core))
    var feed: ConnectionModelFeed? = try await #require(openTask).value
    openTask = nil
    let authorization = ConnectionModelCommandAuthorization(
        feedID: try #require(feed?.id),
        generation: try await #require(core).pageGeneration()
    )
    feed = nil

    let runner = try await #require(core).startModelCommandForTesting(
        modelFeedCommand(
            domain: .page,
            method: "Page.reload",
            authority: authorization
        ),
        authorization: authorization
    )
    _ = try await backend.waitForTargetMessage(method: "Page.reload")

    core = nil

    #expect(weakCore == nil)
    await #expect(throws: TransportSession.Error.transportClosed) {
        try await runner.value
    }
}

private func modelRuntimeAuthorization(
    feedID: ConnectionModelFeedID,
    generation: WebInspectorPage.Generation,
    agentTargetID: String,
    runtimeEpoch: UInt64,
    semanticTargetID: String? = nil,
    navigationEpoch: UInt64? = nil,
    consoleEpoch: UInt64? = nil,
    document: ConnectionModelCommandAuthorization.Document? = nil
) -> ConnectionModelCommandAuthorization {
    let semanticTarget: ConnectionModelCommandAuthorization.Runtime.SemanticTarget?
    if let semanticTargetID {
        guard let navigationEpoch else {
            preconditionFailure("A Runtime semantic target requires an exact navigation epoch.")
        }
        semanticTarget = ConnectionModelCommandAuthorization.Runtime.SemanticTarget(
            targetID: WebInspectorTarget.ID(semanticTargetID),
            navigationEpoch: ModelNavigationEpoch(rawValue: navigationEpoch)
        )
    } else {
        precondition(navigationEpoch == nil)
        semanticTarget = nil
    }
    let agentTargetID = WebInspectorTarget.ID(agentTargetID)
    let consoleBinding = consoleEpoch.map { epoch in
        ConnectionModelCommandAuthorization.Runtime.ConsoleBinding(
            agentTargetID: agentTargetID,
            epoch: ModelConsoleBindingEpoch(rawValue: epoch)
        )
    }
    return ConnectionModelCommandAuthorization(
        feedID: feedID,
        generation: generation,
        document: document,
        runtime: ConnectionModelCommandAuthorization.Runtime(
            agentTargetID: agentTargetID,
            epoch: ModelRuntimeBindingEpoch(rawValue: runtimeEpoch),
            semanticTarget: semanticTarget,
            consoleBinding: consoleBinding
        )
    )
}

@discardableResult
private func modelFeedSendRuntimeCommand(
    core: ConnectionCore,
    backend: FakeTransportBackend,
    authorization: ConnectionModelCommandAuthorization,
    targetID: String,
    after baseline: Int
) async throws -> Int {
    let task = Task {
        try await core.send(modelFeedCommand(
            domain: .runtime,
            method: "Runtime.getProperties",
            authority: authorization,
            routing: .target(ProtocolTarget.ID(targetID))
        ))
    }
    let command = try await backend.waitForTargetMessage(
        method: "Runtime.getProperties",
        after: baseline
    )
    await modelFeedRespond(to: command, core: core)
    _ = try await task.value
    return await backend.sentTargetMessages().count
}

private func modelFeedCommand(
    domain: ProtocolDomain,
    method: String,
    authority: ConnectionModelCommandAuthorization,
    routing: ProtocolCommand.Routing = .octopus(pageTarget: nil)
) -> ProtocolCommand {
    ProtocolCommand(
        domain: domain,
        method: method,
        routing: routing,
        authority: .modelFeed(authority)
    )
}

private func modelFeedExpectedEnableMethods(
    _ configuredDomains: Set<ModelDomain>
) -> [String] {
    var seenDomains: Set<WebInspectorProxyEventDomain> = [.page]
    var methods: [String] = ["Page.enable"]
    for domain in ModelDomain.ordered(configuredDomains) {
        let capabilityDomains = ConnectionCapabilityActivationPlan.domains(
            for: domain.capabilityDependencies,
            includePageDependencyForCSS: false
        )
        for dependency in capabilityDomains where dependency != .dom {
            guard seenDomains.insert(dependency).inserted else {
                continue
            }
            methods.append("\(dependency.rawValue).enable")
        }
    }
    return methods
}

private func modelFeedAcquireDirectElementPickerScope(
    core: ConnectionCore
) async throws -> WebInspectorProxyEventScope<Inspector.Event> {
    try await core.acquireEventScope(
        route: .currentPage,
        targetID: .currentPage,
        domain: .inspector,
        buffering: .bounded(8),
        extract: { event in
            guard case let .inspector(value) = event else {
                return nil
            }
            return value
        }
    )
}

private func modelFeedCompleteElementPickerAcquisition(
    core: ConnectionCore,
    backend: FakeTransportBackend,
    targetID: String,
    after baseline: Int = 0,
    expectsInitialization: Bool
) async throws {
    let enable = try await backend.waitForTargetMessage(
        method: "Inspector.enable",
        after: baseline
    )
    #expect(enable.targetIdentifier == ProtocolTarget.ID(targetID))
    await modelFeedRespond(to: enable, core: core)
    if expectsInitialization {
        let initialized = try await backend.waitForTargetMessage(
            method: "Inspector.initialized",
            after: baseline
        )
        #expect(initialized.targetIdentifier == ProtocolTarget.ID(targetID))
        await modelFeedRespond(to: initialized, core: core)
    }
    let activate = try await backend.waitForTargetMessage(
        method: "DOM.setInspectModeEnabled",
        after: baseline
    )
    #expect(activate.targetIdentifier == ProtocolTarget.ID(targetID))
    #expect(try modelFeedElementPickerEnabled(activate.message) == true)
    await modelFeedRespond(to: activate, core: core)
}

private func modelFeedCompleteElementPickerRelease(
    core: ConnectionCore,
    backend: FakeTransportBackend,
    targetID: String,
    after baseline: Int
) async throws {
    let deactivate = try await backend.waitForTargetMessage(
        method: "DOM.setInspectModeEnabled",
        after: baseline
    )
    #expect(deactivate.targetIdentifier == ProtocolTarget.ID(targetID))
    #expect(try modelFeedElementPickerEnabled(deactivate.message) == false)
    await modelFeedRespond(to: deactivate, core: core)
    let disable = try await backend.waitForTargetMessage(
        method: "Inspector.disable",
        after: baseline
    )
    #expect(disable.targetIdentifier == ProtocolTarget.ID(targetID))
    await modelFeedRespond(to: disable, core: core)
}

private func modelFeedElementPickerEnabled(_ message: String) throws -> Bool {
    let object = try JSONSerialization.jsonObject(with: Data(message.utf8))
    let dictionary = try #require(object as? [String: Any])
    let parameters = try #require(dictionary["params"] as? [String: Any])
    return try #require(parameters["enabled"] as? Bool)
}

private func modelFeedInspectorInspectMessage(objectID: String) -> String {
    let data = try! JSONSerialization.data(
        withJSONObject: [
            "method": "Inspector.inspect",
            "params": [
                "object": [
                    "objectId": objectID,
                    "type": "object",
                    "subtype": "node",
                ],
                "hints": [:] as [String: Any],
            ] as [String: Any],
        ],
        options: [.sortedKeys]
    )
    return String(decoding: data, as: UTF8.self)
}

private func modelFeedOpenSuccessfully(
    core: ConnectionCore,
    backend: FakeTransportBackend,
    configuredDomains: Set<ModelDomain>,
    targetID: String
) async throws -> ConnectionModelFeed {
    let normalizedDomains = ModelDomain.normalized(configuredDomains)
    let enableMethods = modelFeedExpectedEnableMethods(normalizedDomains)
    let targetMessageCount = await backend.sentTargetMessages().count
    let openTask = Task {
        try await core.openModelFeed(
            configuredDomains: configuredDomains
        )
    }
    if normalizedDomains.contains(.dom) {
        let message = try await backend.waitForTargetMessage(
            method: "DOM.getDocument",
            after: targetMessageCount
        )
        #expect(message.targetIdentifier == ProtocolTarget.ID(targetID))
        await modelFeedRespondWithDocument(to: message, core: core)
    }
    for expectedMethod in enableMethods {
        let message = try await backend.waitForTargetMessage(
            method: expectedMethod,
            after: targetMessageCount
        )
        #expect(try modelFeedMessageMethod(message.message) == expectedMethod)
        #expect(message.targetIdentifier == ProtocolTarget.ID(targetID))
        await modelFeedRespond(to: message, core: core)
        if expectedMethod == "CSS.enable" {
            let snapshot = try await backend.waitForTargetMessage(
                method: "CSS.getAllStyleSheets",
                after: targetMessageCount
            )
            #expect(snapshot.targetIdentifier == ProtocolTarget.ID(targetID))
            await modelFeedRespondWithStyleSheets(to: snapshot, core: core)
        }
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
    try await backend.sentTargetMessages().compactMap {
        let method = try modelFeedMessageMethod($0.message)
        return method == "DOM.getDocument" || method == "CSS.getAllStyleSheets"
            ? nil
            : method
    }
}

private func modelFeedDOMGetDocumentMessages(
    _ backend: FakeTransportBackend
) async throws -> [SentTargetMessage] {
    try await backend.sentTargetMessages().filter {
        try modelFeedMessageMethod($0.message) == "DOM.getDocument"
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

private func modelFeedRespondWithDocument(
    to message: SentTargetMessage,
    core: ConnectionCore,
    nodeID: String = "1"
) async {
    let messageID = try! modelFeedMessageID(message.message)
    let reply: [String: Any] = [
        "id": messageID,
        "result": [
            "root": [
                "nodeId": nodeID,
                "nodeType": 9,
                "nodeName": "#document",
                "localName": "",
                "nodeValue": "",
                "childNodeCount": 0,
                "children": [] as [[String: Any]],
            ] as [String: Any],
        ] as [String: Any],
    ]
    let data = try! JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: message.targetIdentifier.rawValue,
        message: String(decoding: data, as: UTF8.self)
    ))
}

private func modelFeedRespondWithStyleSheets(
    to message: SentTargetMessage,
    core: ConnectionCore,
    styleSheetID: String = "restored-sheet"
) async {
    let messageID = try! modelFeedMessageID(message.message)
    let reply: [String: Any] = [
        "id": messageID,
        "result": [
            "headers": [
                [
                    "styleSheetId": styleSheetID,
                    "frameId": "main-frame",
                    "origin": "author",
                    "sourceURL": "https://example.test/restored.css",
                ] as [String: Any],
            ],
        ] as [String: Any],
    ]
    let data = try! JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
    _ = await core.receiveRootMessage(modelFeedTargetDispatchMessage(
        targetID: message.targetIdentifier.rawValue,
        message: String(decoding: data, as: UTF8.self)
    ))
}

private struct ModelFeedEventRecord {
    let scope: ModelEventScope
    let sequence: UInt64
    let payload: ModelProtocolEvent

    var generation: WebInspectorPage.Generation { scope.generation }
    var target: ModelTarget { scope.target }
    var agentTarget: ModelTarget { scope.agentTarget }
    var navigationEpoch: ModelNavigationEpoch { scope.navigationEpoch }
    var domBindingEpoch: ModelDOMBindingEpoch? { scope.domBindingEpoch }
    var runtimeBindingEpoch: ModelRuntimeBindingEpoch? { scope.runtimeBindingEpoch }
    var consoleBindingEpoch: ModelConsoleBindingEpoch? { scope.consoleBindingEpoch }
}

private struct ModelFeedTargetSnapshotRecord {
    let generation: WebInspectorPage.Generation
    let through: UInt64
    let snapshot: ModelTargetSnapshot
}

private struct ModelFeedDOMDocumentInvalidationRecord {
    let scope: ModelEventScope
    let sequence: UInt64

    var generation: WebInspectorPage.Generation { scope.generation }
    var target: ModelTarget { scope.target }
    var agentTarget: ModelTarget { scope.agentTarget }
    var documentEpoch: ModelDOMBindingEpoch {
        guard let epoch = scope.domBindingEpoch else {
            preconditionFailure("A DOM invalidation test record has no binding epoch.")
        }
        return epoch
    }
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

private struct ModelFeedDOMBootstrapSnapshotRecord {
    let generation: WebInspectorPage.Generation
    let sequence: UInt64
    let scope: ModelEventScope
    let root: DOM.Node

    var target: ModelTarget { scope.target }
    var agentTarget: ModelTarget { scope.agentTarget }
    var navigationEpoch: ModelNavigationEpoch { scope.navigationEpoch }
    var documentEpoch: ModelDOMBindingEpoch {
        guard let epoch = scope.domBindingEpoch else {
            preconditionFailure("A DOM bootstrap test record has no binding epoch.")
        }
        return epoch
    }
}

private struct ModelFeedBootstrapCompletionRecord {
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

private func modelFeedRequireDOMDocumentInvalidation(
    _ record: ConnectionModelFeedRecord?
) throws -> ModelFeedDOMDocumentInvalidationRecord {
    guard case let .domDocumentInvalidated(sequence, scope) = try #require(record) else {
        Issue.record("Expected a DOM document invalidation boundary.")
        throw ModelFeedTestError.unexpectedRecord
    }
    return ModelFeedDOMDocumentInvalidationRecord(
        scope: scope,
        sequence: sequence,
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

private func modelFeedRequireDOMBootstrapSnapshot(
    _ record: ConnectionModelFeedRecord?
) throws -> ModelFeedDOMBootstrapSnapshotRecord {
    guard case let .bootstrapSnapshot(generation, domain, sequence, payload) = try #require(record),
          domain == .dom,
          case let .domDocument(scope, root) = payload else {
        Issue.record("Expected a DOM bootstrap snapshot.")
        throw ModelFeedTestError.unexpectedRecord
    }
    return ModelFeedDOMBootstrapSnapshotRecord(
        generation: generation,
        sequence: sequence,
        scope: scope,
        root: root
    )
}

private func modelFeedRequireCSSBootstrapSnapshot(
    _ record: ConnectionModelFeedRecord?
) throws -> [ModelCSSStyleSheet] {
    guard case let .bootstrapSnapshot(_, domain, _, payload) = try #require(record),
          domain == .css,
          case let .cssStyleSheets(styleSheets) = payload else {
        Issue.record("Expected a CSS bootstrap snapshot, got \(String(describing: record)).")
        throw ModelFeedTestError.unexpectedRecord
    }
    return styleSheets
}

private func modelFeedRequireBootstrapCompletion(
    _ record: ConnectionModelFeedRecord?
) throws -> ModelFeedBootstrapCompletionRecord {
    guard case let .bootstrapComplete(generation, domain, through) = try #require(record) else {
        Issue.record("Expected model bootstrap completion.")
        throw ModelFeedTestError.unexpectedRecord
    }
    return ModelFeedBootstrapCompletionRecord(
        generation: generation,
        domain: domain,
        through: through
    )
}

private func modelFeedRequireEvent(
    _ record: ConnectionModelFeedRecord?
) throws -> ModelFeedEventRecord {
    guard case let .event(sequence, scope, payload) = try #require(record) else {
        Issue.record("Expected model feed event.")
        throw ModelFeedTestError.unexpectedRecord
    }
    return ModelFeedEventRecord(
        scope: scope,
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

private actor ModelFeedArmedMessageParser {
    private var shouldBlockNextInvocation = false
    private var isBlocked = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func armNextInvocation() {
        precondition(!shouldBlockNextInvocation && !isBlocked)
        shouldBlockNextInvocation = true
        isReleased = false
    }

    func parse(_ message: String) async throws -> ParsedProtocolMessage {
        guard shouldBlockNextInvocation else {
            return try await TransportMessageParser.parse(message)
        }
        shouldBlockNextInvocation = false
        isBlocked = true
        let startWaiters = self.startWaiters
        self.startWaiters.removeAll()
        for waiter in startWaiters {
            waiter.resume()
        }
        if !isReleased {
            await withCheckedContinuation { continuation in
                if isReleased {
                    continuation.resume()
                } else {
                    releaseWaiters.append(continuation)
                }
            }
        }
        isBlocked = false
        return try await TransportMessageParser.parse(message)
    }

    func waitUntilBlocked() async {
        guard !isBlocked else {
            return
        }
        await withCheckedContinuation { continuation in
            if isBlocked {
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
