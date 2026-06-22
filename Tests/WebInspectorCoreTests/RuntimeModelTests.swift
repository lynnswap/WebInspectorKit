import Observation
import Synchronization
import Testing
import WebInspectorTransport
@testable import WebInspectorCore
@testable import WebInspectorCoreConsoleNetwork
@testable import WebInspectorCoreDOMCSS
@testable import WebInspectorCoreRuntime
@testable import WebInspectorCoreSupport

@Test
@MainActor
func runtimeSessionTracksTargetOwnedExecutionContextsAndReplacesFrameNormalContext() {
    let session = RuntimeState()
    let frameTargetID = ProtocolTarget.ID("frame-target")

    session.applyExecutionContextCreated(
        RuntimeExecutionContext.Payload(
            id: RuntimeContext.ID(1),
            type: .normal,
            name: "Frame A",
            frameID: DOMFrame.ID("frame-a")
        ),
        targetID: frameTargetID
    )
    session.applyExecutionContextCreated(
        RuntimeExecutionContext.Payload(
            id: RuntimeContext.ID(2),
            type: .normal,
            name: "Frame B",
            frameID: DOMFrame.ID("frame-b")
        ),
        targetID: frameTargetID
    )
    session.registerRemoteObject(
        RuntimeRemoteObject.Payload(type: .object, objectID: RuntimeRemoteObject.ProtocolID("frame-a-object")),
        runtimeAgentTargetID: frameTargetID,
        objectGroup: .console,
        executionContextID: RuntimeContext.ID(1)
    )
    session.applyExecutionContextCreated(
        RuntimeExecutionContext.Payload(
            id: RuntimeContext.ID(3),
            type: .normal,
            name: "Frame A",
            frameID: DOMFrame.ID("frame-a")
        ),
        targetID: frameTargetID
    )

    let snapshot = session.snapshot()
    #expect(snapshot.executionContextsByKey[contextKey(frameTargetID, 1)] == nil)
    #expect(snapshot.executionContextsByKey[contextKey(frameTargetID, 2)]?.targetID == frameTargetID)
    #expect(snapshot.executionContextsByKey[contextKey(frameTargetID, 2)]?.frameID == DOMFrame.ID("frame-b"))
    #expect(snapshot.executionContextsByKey[contextKey(frameTargetID, 3)]?.targetID == frameTargetID)
    #expect(snapshot.executionContextsByKey[contextKey(frameTargetID, 3)]?.frameID == DOMFrame.ID("frame-a"))
    #expect(snapshot.normalContextKeyByTargetID[frameTargetID] == contextKey(frameTargetID, 3))
    #expect(snapshot.selectedContextKey == contextKey(frameTargetID, 3))
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: frameTargetID, objectID: RuntimeRemoteObject.ProtocolID("frame-a-object"))] == nil)
    #expect(snapshot.objectGroupRuntimeAgentTargetsByGroup[.console] == nil)
}

@Test
@MainActor
func runtimeSessionKeepsSameFrameNormalContextsFromDifferentRuntimeAgents() {
    let session = RuntimeState()
    let pageTargetID = ProtocolTarget.ID("page-target")
    let frameTargetID = ProtocolTarget.ID("frame-target")
    let objectID = RuntimeRemoteObject.ProtocolID("page-agent-object")

    session.applyExecutionContextCreated(
        RuntimeContext.Record(
            id: RuntimeContext.ID(1),
            targetID: frameTargetID,
            runtimeAgentTargetID: pageTargetID,
            type: .normal,
            name: "Frame",
            frameID: DOMFrame.ID("frame-a")
        )
    )
    session.registerRemoteObject(
        RuntimeRemoteObject.Payload(type: .object, objectID: objectID),
        runtimeAgentTargetID: pageTargetID,
        objectGroup: .console,
        executionContextID: RuntimeContext.ID(1)
    )
    session.applyExecutionContextCreated(
        RuntimeContext.Record(
            id: RuntimeContext.ID(1),
            targetID: frameTargetID,
            runtimeAgentTargetID: frameTargetID,
            type: .normal,
            name: "Frame",
            frameID: DOMFrame.ID("frame-a")
        )
    )

    let snapshot = session.snapshot()
    #expect(snapshot.executionContextsByKey[contextKey(pageTargetID, 1)]?.runtimeAgentTargetID == pageTargetID)
    #expect(snapshot.executionContextsByKey[contextKey(frameTargetID, 1)]?.runtimeAgentTargetID == frameTargetID)
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: pageTargetID, objectID: objectID)] != nil)
}

@Test
@MainActor
func runtimeExecutionContextStableOrderIncludesRuntimeAgentTarget() {
    let pageTargetID = ProtocolTarget.ID("page-target")
    let frameTargetID = ProtocolTarget.ID("frame-target")
    let records = [
        RuntimeContext.Record(
            id: RuntimeContext.ID(1),
            targetID: frameTargetID,
            runtimeAgentTargetID: frameTargetID,
            name: "Frame",
            frameID: DOMFrame.ID("frame")
        ),
        RuntimeContext.Record(
            id: RuntimeContext.ID(1),
            targetID: pageTargetID,
            runtimeAgentTargetID: pageTargetID,
            name: "Page",
            frameID: DOMFrame.ID("page")
        ),
    ]

    let orderedKeys = records.sorted(by: RuntimeContext.Record.stableOrder).map(\.key)

    #expect(orderedKeys == [
        contextKey(frameTargetID, 1),
        contextKey(pageTargetID, 1),
    ])
}

@Test
@MainActor
func runtimeEvaluateIntentDoesNotUseActiveContextFromAnotherTarget() throws {
    let session = RuntimeState()
    let pageTargetID = ProtocolTarget.ID("page")
    let frameTargetID = ProtocolTarget.ID("frame")
    session.applyExecutionContextCreated(
        RuntimeExecutionContext.Payload(id: RuntimeContext.ID(1), type: .normal, frameID: DOMFrame.ID("main-frame")),
        targetID: pageTargetID
    )

    let intent = session.evaluateIntent(expression: "1 + 1", targetID: frameTargetID)
    guard case let .evaluate(request) = intent else {
        Issue.record("Expected evaluate intent")
        return
    }
    #expect(request.contextID == nil)
}

@Test
@MainActor
func runtimeEvaluateIntentRoutesSelectedContextToRuntimeAgentTarget() throws {
    let session = RuntimeState()
    let pageTargetID = ProtocolTarget.ID("page")
    let frameTargetID = ProtocolTarget.ID("frame")
    session.applyExecutionContextCreated(
        RuntimeContext.Record(
            id: RuntimeContext.ID(2),
            targetID: frameTargetID,
            runtimeAgentTargetID: pageTargetID,
            frameID: DOMFrame.ID("frame")
        )
    )

    let intent = session.evaluateIntent(expression: "window.location.href", targetID: frameTargetID)
    guard case let .evaluate(request) = intent else {
        Issue.record("Expected evaluate intent")
        return
    }
    #expect(request.runtimeAgentTargetID == pageTargetID)
    #expect(request.contextID == RuntimeContext.ID(2))
}

@Test
@MainActor
func runtimeEvaluateIntentKeepsPageDefaultContextWhenFrameContextsShareTarget() throws {
    let session = RuntimeState()
    let pageTargetID = ProtocolTarget.ID("page")
    session.applyTargetCreated(
        ProtocolTarget.Record(
            id: pageTargetID,
            kind: .page,
            frameID: DOMFrame.ID("main-frame")
        )
    )
    session.applyExecutionContextCreated(
        RuntimeContext.Record(
            id: RuntimeContext.ID(1),
            targetID: pageTargetID,
            type: .normal,
            name: "Main",
            frameID: DOMFrame.ID("main-frame")
        )
    )
    session.applyExecutionContextCreated(
        RuntimeContext.Record(
            id: RuntimeContext.ID(2),
            targetID: pageTargetID,
            type: .normal,
            name: "Subframe",
            frameID: DOMFrame.ID("ad-frame")
        )
    )

    let intent = session.evaluateIntent(expression: "document.URL", targetID: pageTargetID)
    guard case let .evaluate(request) = intent else {
        Issue.record("Expected evaluate intent")
        return
    }
    #expect(request.contextID == RuntimeContext.ID(1))
    #expect(session.snapshot().normalContextKeyByTargetID[pageTargetID] == contextKey(pageTargetID, 1))
}

@Test
@MainActor
func runtimeEvaluateIntentPromotesTargetFrameContextWhenItArrivesAfterSubframeContext() throws {
    let session = RuntimeState()
    let pageTargetID = ProtocolTarget.ID("page")
    session.applyTargetCreated(
        ProtocolTarget.Record(
            id: pageTargetID,
            kind: .page,
            frameID: DOMFrame.ID("main-frame")
        )
    )
    session.applyExecutionContextCreated(
        RuntimeContext.Record(
            id: RuntimeContext.ID(1),
            targetID: pageTargetID,
            type: .normal,
            name: "Subframe",
            frameID: DOMFrame.ID("ad-frame")
        )
    )
    session.applyExecutionContextCreated(
        RuntimeContext.Record(
            id: RuntimeContext.ID(2),
            targetID: pageTargetID,
            type: .normal,
            name: "Main",
            frameID: DOMFrame.ID("main-frame")
        )
    )

    let intent = session.evaluateIntent(expression: "document.URL", targetID: pageTargetID)
    guard case let .evaluate(request) = intent else {
        Issue.record("Expected evaluate intent")
        return
    }
    #expect(request.contextID == RuntimeContext.ID(2))
    #expect(session.snapshot().normalContextKeyByTargetID[pageTargetID] == contextKey(pageTargetID, 2))
    #expect(session.snapshot().selectedContextKey == contextKey(pageTargetID, 2))
}

@Test
@MainActor
func runtimeEvaluateIntentDoesNotOverrideExplicitSelectedContextWhenTargetFrameContextArrives() throws {
    let session = RuntimeState()
    let pageTargetID = ProtocolTarget.ID("page")
    session.applyTargetCreated(
        ProtocolTarget.Record(
            id: pageTargetID,
            kind: .page,
            frameID: DOMFrame.ID("main-frame")
        )
    )
    session.applyExecutionContextCreated(
        RuntimeContext.Record(
            id: RuntimeContext.ID(1),
            targetID: pageTargetID,
            type: .normal,
            name: "Subframe",
            frameID: DOMFrame.ID("ad-frame")
        )
    )
    session.selectExecutionContext(contextKey(pageTargetID, 1))
    session.applyExecutionContextCreated(
        RuntimeContext.Record(
            id: RuntimeContext.ID(2),
            targetID: pageTargetID,
            type: .normal,
            name: "Main",
            frameID: DOMFrame.ID("main-frame")
        )
    )

    let intent = session.evaluateIntent(expression: "document.URL", targetID: pageTargetID)
    guard case let .evaluate(request) = intent else {
        Issue.record("Expected evaluate intent")
        return
    }
    #expect(request.contextID == RuntimeContext.ID(1))
    #expect(session.snapshot().normalContextKeyByTargetID[pageTargetID] == contextKey(pageTargetID, 2))
    #expect(session.snapshot().selectedContextKey == contextKey(pageTargetID, 1))
}

@Test
@MainActor
func runtimeTargetFrameMetadataPromotesExistingMatchingContext() throws {
    let session = RuntimeState()
    let pageTargetID = ProtocolTarget.ID("page")
    session.applyExecutionContextCreated(
        RuntimeContext.Record(
            id: RuntimeContext.ID(1),
            targetID: pageTargetID,
            type: .normal,
            name: "Subframe",
            frameID: DOMFrame.ID("ad-frame")
        )
    )
    session.applyExecutionContextCreated(
        RuntimeContext.Record(
            id: RuntimeContext.ID(2),
            targetID: pageTargetID,
            type: .normal,
            name: "Main",
            frameID: DOMFrame.ID("main-frame")
        )
    )

    session.applyTargetCreated(
        ProtocolTarget.Record(
            id: pageTargetID,
            kind: .page,
            frameID: DOMFrame.ID("main-frame")
        )
    )

    let intent = session.evaluateIntent(expression: "document.URL", targetID: pageTargetID)
    guard case let .evaluate(request) = intent else {
        Issue.record("Expected evaluate intent")
        return
    }
    #expect(request.contextID == RuntimeContext.ID(2))
    #expect(session.snapshot().normalContextKeyByTargetID[pageTargetID] == contextKey(pageTargetID, 2))
    #expect(session.snapshot().selectedContextKey == contextKey(pageTargetID, 2))
}

@Test
@MainActor
func runtimeEvaluateIntentHonorsSelectedContextBeforeTargetNormalContext() throws {
    let session = RuntimeState()
    let targetID = ProtocolTarget.ID("page")
    session.applyExecutionContextCreated(
        RuntimeContext.Record(
            id: RuntimeContext.ID(1),
            targetID: targetID,
            type: .normal,
            name: "Page"
        )
    )
    session.applyExecutionContextCreated(
        RuntimeContext.Record(
            id: RuntimeContext.ID(2),
            targetID: targetID,
            type: .user,
            name: "Selected Isolated World"
        )
    )

    session.selectExecutionContext(contextKey(targetID, 2))

    let intent = session.evaluateIntent(expression: "window.location.href", targetID: targetID)
    guard case let .evaluate(request) = intent else {
        Issue.record("Expected evaluate intent")
        return
    }
    #expect(request.contextID == RuntimeContext.ID(2))
    #expect(session.snapshot().selectedContextKey == contextKey(targetID, 2))
}

@Test
@MainActor
func runtimeSessionPreservesTransportSeededContextMetadata() {
    let session = RuntimeState()
    let targetID = ProtocolTarget.ID("page")

    session.applyExecutionContextCreated(
        RuntimeContext.Record(
            id: RuntimeContext.ID(1),
            targetID: targetID,
            type: .internal,
            name: "Isolated World",
            frameID: DOMFrame.ID("main-frame")
        )
    )

    let snapshot = session.snapshot()
    #expect(snapshot.executionContextsByKey[contextKey(targetID, 1)]?.type == .internal)
    #expect(snapshot.executionContextsByKey[contextKey(targetID, 1)]?.name == "Isolated World")
    #expect(snapshot.normalContextKeyByTargetID[targetID] == nil)
    #expect(snapshot.selectedContextKey == nil)
}

@Test
@MainActor
func runtimeSessionClearsExecutionContextsByRuntimeAgentTarget() {
    let session = RuntimeState()
    let pageTargetID = ProtocolTarget.ID("page")
    let frameTargetID = ProtocolTarget.ID("frame")
    let otherFrameTargetID = ProtocolTarget.ID("other-frame")

    session.applyExecutionContextCreated(
        RuntimeContext.Record(
            id: RuntimeContext.ID(1),
            targetID: frameTargetID,
            runtimeAgentTargetID: pageTargetID,
            frameID: DOMFrame.ID("frame")
        )
    )
    session.applyExecutionContextCreated(
        RuntimeContext.Record(
            id: RuntimeContext.ID(2),
            targetID: otherFrameTargetID,
            runtimeAgentTargetID: otherFrameTargetID,
            frameID: DOMFrame.ID("other-frame")
        )
    )
    session.registerRemoteObject(
        RuntimeRemoteObject.Payload(type: .object, objectID: RuntimeRemoteObject.ProtocolID("page-object")),
        runtimeAgentTargetID: pageTargetID,
        objectGroup: .console,
        executionContextID: RuntimeContext.ID(1)
    )
    session.registerRemoteObject(
        RuntimeRemoteObject.Payload(type: .object, objectID: RuntimeRemoteObject.ProtocolID("page-console-object")),
        runtimeAgentTargetID: pageTargetID,
        objectGroup: .console
    )
    session.registerRemoteObject(
        RuntimeRemoteObject.Payload(type: .object, objectID: RuntimeRemoteObject.ProtocolID("other-object")),
        runtimeAgentTargetID: otherFrameTargetID,
        objectGroup: .console,
        executionContextID: RuntimeContext.ID(2)
    )

    session.applyExecutionContextsCleared(runtimeAgentTargetID: pageTargetID)
    let snapshot = session.snapshot()

    #expect(snapshot.executionContextsByKey[contextKey(pageTargetID, 1)] == nil)
    #expect(snapshot.executionContextsByKey[contextKey(otherFrameTargetID, 2)]?.targetID == otherFrameTargetID)
    #expect(snapshot.normalContextKeyByTargetID[frameTargetID] == nil)
    #expect(snapshot.normalContextKeyByTargetID[otherFrameTargetID] == contextKey(otherFrameTargetID, 2))
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: pageTargetID, objectID: RuntimeRemoteObject.ProtocolID("page-object"))] == nil)
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: pageTargetID, objectID: RuntimeRemoteObject.ProtocolID("page-console-object"))] == nil)
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: otherFrameTargetID, objectID: RuntimeRemoteObject.ProtocolID("other-object"))] != nil)
    #expect(snapshot.objectGroupRuntimeAgentTargetsByGroup[.console] == [otherFrameTargetID])
}

@Test
@MainActor
func runtimeSessionTargetDestroyedClearsExecutionContextsByRuntimeAgentTarget() {
    let session = RuntimeState()
    let pageTargetID = ProtocolTarget.ID("page")
    let frameTargetID = ProtocolTarget.ID("frame")
    session.applyExecutionContextCreated(
        RuntimeContext.Record(
            id: RuntimeContext.ID(1),
            targetID: frameTargetID,
            runtimeAgentTargetID: pageTargetID,
            frameID: DOMFrame.ID("frame")
        )
    )
    session.registerRemoteObject(
        RuntimeRemoteObject.Payload(type: .object, objectID: RuntimeRemoteObject.ProtocolID("page-object")),
        runtimeAgentTargetID: pageTargetID,
        objectGroup: .console,
        executionContextID: RuntimeContext.ID(1)
    )

    session.applyTargetDestroyed(pageTargetID)
    let snapshot = session.snapshot()

    #expect(snapshot.executionContextsByKey[contextKey(pageTargetID, 1)] == nil)
    #expect(snapshot.normalContextKeyByTargetID[frameTargetID] == nil)
    #expect(snapshot.selectedContextKey == nil)
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: pageTargetID, objectID: RuntimeRemoteObject.ProtocolID("page-object"))] == nil)
    #expect(snapshot.objectGroupRuntimeAgentTargetsByGroup[.console] == nil)
}

@Test
@MainActor
func runtimeSessionTargetCommitDropsOldRuntimeAgentObjects() {
    let session = RuntimeState()
    let oldTargetID = ProtocolTarget.ID("page-old")
    let newTargetID = ProtocolTarget.ID("page-new")
    let objectID = RuntimeRemoteObject.ProtocolID("old-object")

    session.applyExecutionContextCreated(
        RuntimeContext.Record(id: RuntimeContext.ID(1), targetID: oldTargetID)
    )
    session.registerRemoteObject(
        RuntimeRemoteObject.Payload(type: .object, objectID: objectID),
        runtimeAgentTargetID: oldTargetID,
        objectGroup: .console,
        executionContextID: RuntimeContext.ID(1)
    )

    session.applyTargetCommitted(oldTargetID: oldTargetID, newTargetID: newTargetID)
    let snapshot = session.snapshot()

    #expect(snapshot.executionContextsByKey[contextKey(newTargetID, 1)]?.targetID == newTargetID)
    #expect(snapshot.executionContextsByKey[contextKey(newTargetID, 1)]?.runtimeAgentTargetID == newTargetID)
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: oldTargetID, objectID: objectID)] == nil)
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: newTargetID, objectID: objectID)] == nil)
    #expect(snapshot.objectGroupRuntimeAgentTargetsByGroup[.console] == nil)
}

@Test
@MainActor
func runtimeSessionTargetCommitPreservesCommittedContextWhenIDsCollide() {
    let session = RuntimeState()
    let oldTargetID = ProtocolTarget.ID("page-old")
    let newTargetID = ProtocolTarget.ID("page-new")
    let oldContextKey = contextKey(oldTargetID, 1)
    let newContextKey = contextKey(newTargetID, 1)

    session.applyExecutionContextCreated(
        RuntimeContext.Record(
            id: RuntimeContext.ID(1),
            targetID: oldTargetID,
            name: "old"
        )
    )
    session.selectExecutionContext(oldContextKey)
    session.applyExecutionContextCreated(
        RuntimeContext.Record(
            id: RuntimeContext.ID(1),
            targetID: newTargetID,
            name: "new"
        )
    )
    let oldContext = session.executionContext(for: oldContextKey)
    let newContext = session.executionContext(for: newContextKey)

    session.applyTargetCommitted(oldTargetID: oldTargetID, newTargetID: newTargetID)
    let snapshot = session.snapshot()

    #expect(snapshot.executionContextsByKey[oldContextKey] == nil)
    #expect(snapshot.executionContextsByKey[newContextKey]?.name == "new")
    #expect(snapshot.normalContextKeyByTargetID[newTargetID] == newContextKey)
    #expect(snapshot.selectedContextKey == newContextKey)
    #expect(session.executionContext(for: newContextKey) === newContext)
    #expect(session.executionContext(for: newContextKey) !== oldContext)
}

@Test
@MainActor
func runtimeSessionSnapshotInvalidatesObserversWhenRemoteObjectIsRegistered() {
    let session = RuntimeState()
    let didChange = Mutex(false)

    withObservationTracking {
        _ = session.snapshot().remoteObjectsByID.count
    } onChange: {
        didChange.withLock { $0 = true }
    }

    session.registerRemoteObject(
        RuntimeRemoteObject.Payload(type: .object, objectID: RuntimeRemoteObject.ProtocolID("object-1")),
        runtimeAgentTargetID: ProtocolTarget.ID("page"),
        objectGroup: RuntimeRemoteObject.Group("console")
    )

    #expect(didChange.withLock { $0 })
}

@Test
@MainActor
func runtimeTargetAndAgentStatesKeepStableObservableIdentity() throws {
    let session = RuntimeState()
    let targetID = ProtocolTarget.ID("page")

    session.applyExecutionContextCreated(
        RuntimeContext.Record(id: RuntimeContext.ID(1), targetID: targetID, name: "page")
    )

    let targetState = try #require(session.targetState(for: targetID))
    let agentState = try #require(session.runtimeAgentState(for: targetID))
    let targetDidChange = Mutex(false)
    let agentDidChange = Mutex(false)

    withObservationTracking {
        _ = targetState.normalContextKey
    } onChange: {
        targetDidChange.withLock { $0 = true }
    }
    withObservationTracking {
        _ = agentState.executionContexts.count
    } onChange: {
        agentDidChange.withLock { $0 = true }
    }

    session.applyExecutionContextCreated(
        RuntimeContext.Record(id: RuntimeContext.ID(2), targetID: targetID, name: "page")
    )

    #expect(session.targetState(for: targetID) === targetState)
    #expect(session.runtimeAgentState(for: targetID) === agentState)
    #expect(targetState.normalContextKey == contextKey(targetID, 2))
    #expect(agentState.executionContexts.map(\.id) == [RuntimeContext.ID(2)])
    #expect(targetDidChange.withLock { $0 })
    #expect(agentDidChange.withLock { $0 })
}

@Test
@MainActor
func runtimeExecutionContextKeepsStableObservableIdentityWhenUpdated() throws {
    let session = RuntimeState()
    let targetID = ProtocolTarget.ID("page")

    session.applyExecutionContextCreated(
        RuntimeContext.Record(id: RuntimeContext.ID(1), targetID: targetID, name: "before")
    )

    let agentState = try #require(session.runtimeAgentState(for: targetID))
    let context = try #require(agentState.executionContexts.first)
    let didChange = Mutex(false)

    withObservationTracking {
        _ = context.name
    } onChange: {
        didChange.withLock { $0 = true }
    }

    session.applyExecutionContextCreated(
        RuntimeContext.Record(id: RuntimeContext.ID(1), targetID: targetID, name: "after")
    )

    #expect(agentState.executionContexts.first === context)
    #expect(context.name == "after")
    #expect(didChange.withLock { $0 })
}

@Test
@MainActor
func runtimeExecutionContextKeepsStableObservableIdentityWhenRetargeted() throws {
    let session = RuntimeState()
    let oldTargetID = ProtocolTarget.ID("page-old")
    let newTargetID = ProtocolTarget.ID("page-new")
    let oldContextKey = contextKey(oldTargetID, 1)
    let newContextKey = contextKey(newTargetID, 1)

    session.applyExecutionContextCreated(
        RuntimeContext.Record(id: RuntimeContext.ID(1), targetID: oldTargetID, name: "page")
    )

    let context = try #require(session.executionContext(for: oldContextKey))
    session.applyTargetCommitted(oldTargetID: oldTargetID, newTargetID: newTargetID)

    #expect(session.executionContext(for: newContextKey) === context)
    #expect(context.targetID == newTargetID)
    #expect(context.runtimeAgentTargetID == newTargetID)
}

@Test
@MainActor
func runtimeRemoteObjectKeepsStableObservableIdentity() throws {
    let session = RuntimeState()
    let targetID = ProtocolTarget.ID("page")
    let objectID = RuntimeRemoteObject.ProtocolID("object-1")

    session.registerRemoteObject(
        RuntimeRemoteObject.Payload(type: .object, description: "before", objectID: objectID),
        runtimeAgentTargetID: targetID,
        objectGroup: RuntimeRemoteObject.Group("console")
    )

    let agentState = try #require(session.runtimeAgentState(for: targetID))
    let remoteObject = try #require(agentState.remoteObjects.first)
    let didChange = Mutex(false)

    withObservationTracking {
        _ = remoteObject.payload.description
    } onChange: {
        didChange.withLock { $0 = true }
    }

    session.registerRemoteObject(
        RuntimeRemoteObject.Payload(type: .object, description: "after", objectID: objectID),
        runtimeAgentTargetID: targetID
    )

    #expect(agentState.remoteObjects.first === remoteObject)
    #expect(remoteObject.payload.description == "after")
    #expect(remoteObject.objectGroup == nil)
    #expect(didChange.withLock { $0 })
}

@Test
@MainActor
func runtimeRemoteObjectIdentityIncludesRuntimeAgentTargetAndObjectID() {
    let session = RuntimeState()
    let pageTargetID = ProtocolTarget.ID("page")
    let frameTargetID = ProtocolTarget.ID("frame")
    let objectID = RuntimeRemoteObject.ProtocolID("object-1")
    let pageObject = RuntimeRemoteObject.Payload(
        type: .object,
        description: "page object",
        objectID: objectID
    )
    let frameObject = RuntimeRemoteObject.Payload(
        type: .object,
        description: "frame object",
        objectID: objectID
    )

    session.registerRemoteObject(pageObject, runtimeAgentTargetID: pageTargetID, objectGroup: RuntimeRemoteObject.Group("console"))
    session.registerRemoteObject(frameObject, runtimeAgentTargetID: frameTargetID, objectGroup: RuntimeRemoteObject.Group("console"))

    let snapshot = session.snapshot()
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: pageTargetID, objectID: objectID)]?.payload.description == "page object")
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: frameTargetID, objectID: objectID)]?.payload.description == "frame object")
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: pageTargetID, objectID: objectID)]?.objectGroup == RuntimeRemoteObject.Group("console"))
    #expect(snapshot.objectGroupRuntimeAgentTargetsByGroup[RuntimeRemoteObject.Group("console")] == [pageTargetID, frameTargetID])
}

@Test
@MainActor
func runtimeReleaseObjectDropsEmptyObjectGroupTargets() {
    let session = RuntimeState()
    let targetID = ProtocolTarget.ID("page")
    let objectGroup = RuntimeRemoteObject.Group("console")
    let objectID = RuntimeRemoteObject.ProtocolID("object-1")

    session.registerRemoteObject(
        RuntimeRemoteObject.Payload(type: .object, objectID: objectID),
        runtimeAgentTargetID: targetID,
        objectGroup: objectGroup
    )
    session.releaseObject(.init(runtimeAgentTargetID: targetID, objectID: objectID))

    let snapshot = session.snapshot()
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: targetID, objectID: objectID)] == nil)
    #expect(snapshot.objectGroupRuntimeAgentTargetsByGroup[objectGroup] == nil)
}

@Test
@MainActor
func runtimeObjectGroupTargetsAreDerivedFromCurrentRemoteObjects() {
    let session = RuntimeState()
    let targetID = ProtocolTarget.ID("page")
    let objectGroup = RuntimeRemoteObject.Group("console")
    let objectID = RuntimeRemoteObject.ProtocolID("object-1")

    session.registerRemoteObject(
        RuntimeRemoteObject.Payload(type: .object, objectID: objectID),
        runtimeAgentTargetID: targetID,
        objectGroup: objectGroup
    )
    session.registerRemoteObject(
        RuntimeRemoteObject.Payload(type: .object, objectID: objectID),
        runtimeAgentTargetID: targetID
    )

    let snapshot = session.snapshot()
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: targetID, objectID: objectID)]?.objectGroup == nil)
    #expect(snapshot.objectGroupRuntimeAgentTargetsByGroup[objectGroup] == nil)
}

private func contextKey(_ runtimeAgentTargetID: ProtocolTarget.ID, _ contextID: Int) -> RuntimeContext.Key {
    RuntimeContext.Key(runtimeAgentTargetID: runtimeAgentTargetID, contextID: RuntimeContext.ID(contextID))
}
