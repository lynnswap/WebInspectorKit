import Observation
import Synchronization
import Testing
@testable import WebInspectorCore

@Test
@MainActor
func runtimeSessionTracksTargetOwnedExecutionContextsAndReplacesFrameNormalContext() {
    let session = RuntimeSession()
    let frameTargetID = ProtocolTargetIdentifier("frame-target")

    session.applyExecutionContextCreated(
        RuntimeExecutionContextPayload(
            id: ExecutionContextID(1),
            type: .normal,
            name: "Frame A",
            frameID: DOMFrameIdentifier("frame-a")
        ),
        targetID: frameTargetID
    )
    session.applyExecutionContextCreated(
        RuntimeExecutionContextPayload(
            id: ExecutionContextID(2),
            type: .normal,
            name: "Frame B",
            frameID: DOMFrameIdentifier("frame-b")
        ),
        targetID: frameTargetID
    )
    session.registerRemoteObject(
        RuntimeRemoteObjectPayload(type: .object, objectID: RuntimeRemoteObjectIdentifier("frame-a-object")),
        runtimeAgentTargetID: frameTargetID,
        objectGroup: .console,
        executionContextID: ExecutionContextID(1)
    )
    session.applyExecutionContextCreated(
        RuntimeExecutionContextPayload(
            id: ExecutionContextID(3),
            type: .normal,
            name: "Frame A",
            frameID: DOMFrameIdentifier("frame-a")
        ),
        targetID: frameTargetID
    )

    let snapshot = session.snapshot()
    #expect(snapshot.executionContextsByKey[contextKey(frameTargetID, 1)] == nil)
    #expect(snapshot.executionContextsByKey[contextKey(frameTargetID, 2)]?.targetID == frameTargetID)
    #expect(snapshot.executionContextsByKey[contextKey(frameTargetID, 2)]?.frameID == DOMFrameIdentifier("frame-b"))
    #expect(snapshot.executionContextsByKey[contextKey(frameTargetID, 3)]?.targetID == frameTargetID)
    #expect(snapshot.executionContextsByKey[contextKey(frameTargetID, 3)]?.frameID == DOMFrameIdentifier("frame-a"))
    #expect(snapshot.normalContextKeyByTargetID[frameTargetID] == contextKey(frameTargetID, 3))
    #expect(snapshot.selectedContextKey == contextKey(frameTargetID, 3))
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: frameTargetID, objectID: RuntimeRemoteObjectIdentifier("frame-a-object"))] == nil)
    #expect(snapshot.objectGroupRuntimeAgentTargetsByGroup[.console] == nil)
}

@Test
@MainActor
func runtimeSessionKeepsSameFrameNormalContextsFromDifferentRuntimeAgents() {
    let session = RuntimeSession()
    let pageTargetID = ProtocolTargetIdentifier("page-target")
    let frameTargetID = ProtocolTargetIdentifier("frame-target")
    let objectID = RuntimeRemoteObjectIdentifier("page-agent-object")

    session.applyExecutionContextCreated(
        RuntimeExecutionContextRecord(
            id: ExecutionContextID(1),
            targetID: frameTargetID,
            runtimeAgentTargetID: pageTargetID,
            type: .normal,
            name: "Frame",
            frameID: DOMFrameIdentifier("frame-a")
        )
    )
    session.registerRemoteObject(
        RuntimeRemoteObjectPayload(type: .object, objectID: objectID),
        runtimeAgentTargetID: pageTargetID,
        objectGroup: .console,
        executionContextID: ExecutionContextID(1)
    )
    session.applyExecutionContextCreated(
        RuntimeExecutionContextRecord(
            id: ExecutionContextID(1),
            targetID: frameTargetID,
            runtimeAgentTargetID: frameTargetID,
            type: .normal,
            name: "Frame",
            frameID: DOMFrameIdentifier("frame-a")
        )
    )

    let snapshot = session.snapshot()
    #expect(snapshot.executionContextsByKey[contextKey(pageTargetID, 1)]?.runtimeAgentTargetID == pageTargetID)
    #expect(snapshot.executionContextsByKey[contextKey(frameTargetID, 1)]?.runtimeAgentTargetID == frameTargetID)
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: pageTargetID, objectID: objectID)] != nil)
}

@Test
@MainActor
func runtimeEvaluateIntentDoesNotUseActiveContextFromAnotherTarget() throws {
    let session = RuntimeSession()
    let pageTargetID = ProtocolTargetIdentifier("page")
    let frameTargetID = ProtocolTargetIdentifier("frame")
    session.applyExecutionContextCreated(
        RuntimeExecutionContextPayload(id: ExecutionContextID(1), type: .normal, frameID: DOMFrameIdentifier("main-frame")),
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
    let session = RuntimeSession()
    let pageTargetID = ProtocolTargetIdentifier("page")
    let frameTargetID = ProtocolTargetIdentifier("frame")
    session.applyExecutionContextCreated(
        RuntimeExecutionContextRecord(
            id: ExecutionContextID(2),
            targetID: frameTargetID,
            runtimeAgentTargetID: pageTargetID,
            frameID: DOMFrameIdentifier("frame")
        )
    )

    let intent = session.evaluateIntent(expression: "window.location.href", targetID: frameTargetID)
    guard case let .evaluate(request) = intent else {
        Issue.record("Expected evaluate intent")
        return
    }
    #expect(request.runtimeAgentTargetID == pageTargetID)
    #expect(request.contextID == ExecutionContextID(2))
}

@Test
@MainActor
func runtimeEvaluateIntentKeepsPageDefaultContextWhenFrameContextsShareTarget() throws {
    let session = RuntimeSession()
    let pageTargetID = ProtocolTargetIdentifier("page")
    session.applyExecutionContextCreated(
        RuntimeExecutionContextRecord(
            id: ExecutionContextID(1),
            targetID: pageTargetID,
            type: .normal,
            name: "Main",
            frameID: DOMFrameIdentifier("main-frame")
        )
    )
    session.applyExecutionContextCreated(
        RuntimeExecutionContextRecord(
            id: ExecutionContextID(2),
            targetID: pageTargetID,
            type: .normal,
            name: "Subframe",
            frameID: DOMFrameIdentifier("ad-frame")
        )
    )

    let intent = session.evaluateIntent(expression: "document.URL", targetID: pageTargetID)
    guard case let .evaluate(request) = intent else {
        Issue.record("Expected evaluate intent")
        return
    }
    #expect(request.contextID == ExecutionContextID(1))
    #expect(session.snapshot().normalContextKeyByTargetID[pageTargetID] == contextKey(pageTargetID, 1))
}

@Test
@MainActor
func runtimeEvaluateIntentHonorsSelectedContextBeforeTargetNormalContext() throws {
    let session = RuntimeSession()
    let targetID = ProtocolTargetIdentifier("page")
    session.applyExecutionContextCreated(
        RuntimeExecutionContextRecord(
            id: ExecutionContextID(1),
            targetID: targetID,
            type: .normal,
            name: "Page"
        )
    )
    session.applyExecutionContextCreated(
        RuntimeExecutionContextRecord(
            id: ExecutionContextID(2),
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
    #expect(request.contextID == ExecutionContextID(2))
    #expect(session.snapshot().selectedContextKey == contextKey(targetID, 2))
}

@Test
@MainActor
func runtimeSessionPreservesTransportSeededContextMetadata() {
    let session = RuntimeSession()
    let targetID = ProtocolTargetIdentifier("page")

    session.applyExecutionContextCreated(
        RuntimeExecutionContextRecord(
            id: ExecutionContextID(1),
            targetID: targetID,
            type: .internal,
            name: "Isolated World",
            frameID: DOMFrameIdentifier("main-frame")
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
    let session = RuntimeSession()
    let pageTargetID = ProtocolTargetIdentifier("page")
    let frameTargetID = ProtocolTargetIdentifier("frame")
    let otherFrameTargetID = ProtocolTargetIdentifier("other-frame")

    session.applyExecutionContextCreated(
        RuntimeExecutionContextRecord(
            id: ExecutionContextID(1),
            targetID: frameTargetID,
            runtimeAgentTargetID: pageTargetID,
            frameID: DOMFrameIdentifier("frame")
        )
    )
    session.applyExecutionContextCreated(
        RuntimeExecutionContextRecord(
            id: ExecutionContextID(2),
            targetID: otherFrameTargetID,
            runtimeAgentTargetID: otherFrameTargetID,
            frameID: DOMFrameIdentifier("other-frame")
        )
    )
    session.registerRemoteObject(
        RuntimeRemoteObjectPayload(type: .object, objectID: RuntimeRemoteObjectIdentifier("page-object")),
        runtimeAgentTargetID: pageTargetID,
        objectGroup: .console,
        executionContextID: ExecutionContextID(1)
    )
    session.registerRemoteObject(
        RuntimeRemoteObjectPayload(type: .object, objectID: RuntimeRemoteObjectIdentifier("page-console-object")),
        runtimeAgentTargetID: pageTargetID,
        objectGroup: .console
    )
    session.registerRemoteObject(
        RuntimeRemoteObjectPayload(type: .object, objectID: RuntimeRemoteObjectIdentifier("other-object")),
        runtimeAgentTargetID: otherFrameTargetID,
        objectGroup: .console,
        executionContextID: ExecutionContextID(2)
    )

    session.applyExecutionContextsCleared(runtimeAgentTargetID: pageTargetID)
    let snapshot = session.snapshot()

    #expect(snapshot.executionContextsByKey[contextKey(pageTargetID, 1)] == nil)
    #expect(snapshot.executionContextsByKey[contextKey(otherFrameTargetID, 2)]?.targetID == otherFrameTargetID)
    #expect(snapshot.normalContextKeyByTargetID[frameTargetID] == nil)
    #expect(snapshot.normalContextKeyByTargetID[otherFrameTargetID] == contextKey(otherFrameTargetID, 2))
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: pageTargetID, objectID: RuntimeRemoteObjectIdentifier("page-object"))] == nil)
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: pageTargetID, objectID: RuntimeRemoteObjectIdentifier("page-console-object"))] == nil)
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: otherFrameTargetID, objectID: RuntimeRemoteObjectIdentifier("other-object"))] != nil)
    #expect(snapshot.objectGroupRuntimeAgentTargetsByGroup[.console] == [otherFrameTargetID])
}

@Test
@MainActor
func runtimeSessionTargetDestroyedClearsExecutionContextsByRuntimeAgentTarget() {
    let session = RuntimeSession()
    let pageTargetID = ProtocolTargetIdentifier("page")
    let frameTargetID = ProtocolTargetIdentifier("frame")
    session.applyExecutionContextCreated(
        RuntimeExecutionContextRecord(
            id: ExecutionContextID(1),
            targetID: frameTargetID,
            runtimeAgentTargetID: pageTargetID,
            frameID: DOMFrameIdentifier("frame")
        )
    )
    session.registerRemoteObject(
        RuntimeRemoteObjectPayload(type: .object, objectID: RuntimeRemoteObjectIdentifier("page-object")),
        runtimeAgentTargetID: pageTargetID,
        objectGroup: .console,
        executionContextID: ExecutionContextID(1)
    )

    session.applyTargetDestroyed(pageTargetID)
    let snapshot = session.snapshot()

    #expect(snapshot.executionContextsByKey[contextKey(pageTargetID, 1)] == nil)
    #expect(snapshot.normalContextKeyByTargetID[frameTargetID] == nil)
    #expect(snapshot.selectedContextKey == nil)
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: pageTargetID, objectID: RuntimeRemoteObjectIdentifier("page-object"))] == nil)
    #expect(snapshot.objectGroupRuntimeAgentTargetsByGroup[.console] == nil)
}

@Test
@MainActor
func runtimeSessionTargetCommitDropsOldRuntimeAgentObjects() {
    let session = RuntimeSession()
    let oldTargetID = ProtocolTargetIdentifier("page-old")
    let newTargetID = ProtocolTargetIdentifier("page-new")
    let objectID = RuntimeRemoteObjectIdentifier("old-object")

    session.applyExecutionContextCreated(
        RuntimeExecutionContextRecord(id: ExecutionContextID(1), targetID: oldTargetID)
    )
    session.registerRemoteObject(
        RuntimeRemoteObjectPayload(type: .object, objectID: objectID),
        runtimeAgentTargetID: oldTargetID,
        objectGroup: .console,
        executionContextID: ExecutionContextID(1)
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
    let session = RuntimeSession()
    let oldTargetID = ProtocolTargetIdentifier("page-old")
    let newTargetID = ProtocolTargetIdentifier("page-new")
    let oldContextKey = contextKey(oldTargetID, 1)
    let newContextKey = contextKey(newTargetID, 1)

    session.applyExecutionContextCreated(
        RuntimeExecutionContextRecord(
            id: ExecutionContextID(1),
            targetID: oldTargetID,
            name: "old"
        )
    )
    session.selectExecutionContext(oldContextKey)
    session.applyExecutionContextCreated(
        RuntimeExecutionContextRecord(
            id: ExecutionContextID(1),
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
    let session = RuntimeSession()
    let didChange = Mutex(false)

    withObservationTracking {
        _ = session.snapshot().remoteObjectsByID.count
    } onChange: {
        didChange.withLock { $0 = true }
    }

    session.registerRemoteObject(
        RuntimeRemoteObjectPayload(type: .object, objectID: RuntimeRemoteObjectIdentifier("object-1")),
        runtimeAgentTargetID: ProtocolTargetIdentifier("page"),
        objectGroup: RuntimeObjectGroup("console")
    )

    #expect(didChange.withLock { $0 })
}

@Test
@MainActor
func runtimeTargetAndAgentStatesKeepStableObservableIdentity() throws {
    let session = RuntimeSession()
    let targetID = ProtocolTargetIdentifier("page")

    session.applyExecutionContextCreated(
        RuntimeExecutionContextRecord(id: ExecutionContextID(1), targetID: targetID, name: "page")
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
        RuntimeExecutionContextRecord(id: ExecutionContextID(2), targetID: targetID, name: "page")
    )

    #expect(session.targetState(for: targetID) === targetState)
    #expect(session.runtimeAgentState(for: targetID) === agentState)
    #expect(targetState.normalContextKey == contextKey(targetID, 2))
    #expect(agentState.executionContexts.map(\.id) == [ExecutionContextID(2)])
    #expect(targetDidChange.withLock { $0 })
    #expect(agentDidChange.withLock { $0 })
}

@Test
@MainActor
func runtimeExecutionContextKeepsStableObservableIdentityWhenUpdated() throws {
    let session = RuntimeSession()
    let targetID = ProtocolTargetIdentifier("page")

    session.applyExecutionContextCreated(
        RuntimeExecutionContextRecord(id: ExecutionContextID(1), targetID: targetID, name: "before")
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
        RuntimeExecutionContextRecord(id: ExecutionContextID(1), targetID: targetID, name: "after")
    )

    #expect(agentState.executionContexts.first === context)
    #expect(context.name == "after")
    #expect(didChange.withLock { $0 })
}

@Test
@MainActor
func runtimeExecutionContextKeepsStableObservableIdentityWhenRetargeted() throws {
    let session = RuntimeSession()
    let oldTargetID = ProtocolTargetIdentifier("page-old")
    let newTargetID = ProtocolTargetIdentifier("page-new")
    let oldContextKey = contextKey(oldTargetID, 1)
    let newContextKey = contextKey(newTargetID, 1)

    session.applyExecutionContextCreated(
        RuntimeExecutionContextRecord(id: ExecutionContextID(1), targetID: oldTargetID, name: "page")
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
    let session = RuntimeSession()
    let targetID = ProtocolTargetIdentifier("page")
    let objectID = RuntimeRemoteObjectIdentifier("object-1")

    session.registerRemoteObject(
        RuntimeRemoteObjectPayload(type: .object, description: "before", objectID: objectID),
        runtimeAgentTargetID: targetID,
        objectGroup: RuntimeObjectGroup("console")
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
        RuntimeRemoteObjectPayload(type: .object, description: "after", objectID: objectID),
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
    let session = RuntimeSession()
    let pageTargetID = ProtocolTargetIdentifier("page")
    let frameTargetID = ProtocolTargetIdentifier("frame")
    let objectID = RuntimeRemoteObjectIdentifier("object-1")
    let pageObject = RuntimeRemoteObjectPayload(
        type: .object,
        description: "page object",
        objectID: objectID
    )
    let frameObject = RuntimeRemoteObjectPayload(
        type: .object,
        description: "frame object",
        objectID: objectID
    )

    session.registerRemoteObject(pageObject, runtimeAgentTargetID: pageTargetID, objectGroup: RuntimeObjectGroup("console"))
    session.registerRemoteObject(frameObject, runtimeAgentTargetID: frameTargetID, objectGroup: RuntimeObjectGroup("console"))

    let snapshot = session.snapshot()
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: pageTargetID, objectID: objectID)]?.payload.description == "page object")
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: frameTargetID, objectID: objectID)]?.payload.description == "frame object")
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: pageTargetID, objectID: objectID)]?.objectGroup == RuntimeObjectGroup("console"))
    #expect(snapshot.objectGroupRuntimeAgentTargetsByGroup[RuntimeObjectGroup("console")] == [pageTargetID, frameTargetID])
}

@Test
@MainActor
func runtimeReleaseObjectDropsEmptyObjectGroupTargets() {
    let session = RuntimeSession()
    let targetID = ProtocolTargetIdentifier("page")
    let objectGroup = RuntimeObjectGroup("console")
    let objectID = RuntimeRemoteObjectIdentifier("object-1")

    session.registerRemoteObject(
        RuntimeRemoteObjectPayload(type: .object, objectID: objectID),
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
    let session = RuntimeSession()
    let targetID = ProtocolTargetIdentifier("page")
    let objectGroup = RuntimeObjectGroup("console")
    let objectID = RuntimeRemoteObjectIdentifier("object-1")

    session.registerRemoteObject(
        RuntimeRemoteObjectPayload(type: .object, objectID: objectID),
        runtimeAgentTargetID: targetID,
        objectGroup: objectGroup
    )
    session.registerRemoteObject(
        RuntimeRemoteObjectPayload(type: .object, objectID: objectID),
        runtimeAgentTargetID: targetID
    )

    let snapshot = session.snapshot()
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: targetID, objectID: objectID)]?.objectGroup == nil)
    #expect(snapshot.objectGroupRuntimeAgentTargetsByGroup[objectGroup] == nil)
}

private func contextKey(_ runtimeAgentTargetID: ProtocolTargetIdentifier, _ contextID: Int) -> RuntimeExecutionContextKey {
    RuntimeExecutionContextKey(runtimeAgentTargetID: runtimeAgentTargetID, contextID: ExecutionContextID(contextID))
}
