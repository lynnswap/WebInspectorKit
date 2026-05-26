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
    #expect(snapshot.executionContextsByID[ExecutionContextID(1)] == nil)
    #expect(snapshot.executionContextsByID[ExecutionContextID(2)]?.targetID == frameTargetID)
    #expect(snapshot.executionContextsByID[ExecutionContextID(2)]?.frameID == DOMFrameIdentifier("frame-b"))
    #expect(snapshot.executionContextsByID[ExecutionContextID(3)]?.targetID == frameTargetID)
    #expect(snapshot.executionContextsByID[ExecutionContextID(3)]?.frameID == DOMFrameIdentifier("frame-a"))
    #expect(snapshot.normalContextIDByTargetID[frameTargetID] == ExecutionContextID(3))
    #expect(snapshot.selectedContextID == ExecutionContextID(3))
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: frameTargetID, objectID: RuntimeRemoteObjectIdentifier("frame-a-object"))] == nil)
    #expect(snapshot.objectGroupRuntimeAgentTargetsByGroup[.console] == nil)
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
        RuntimeExecutionContext(
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
func runtimeEvaluateIntentHonorsSelectedContextBeforeTargetNormalContext() throws {
    let session = RuntimeSession()
    let targetID = ProtocolTargetIdentifier("page")
    session.applyExecutionContextCreated(
        RuntimeExecutionContext(
            id: ExecutionContextID(1),
            targetID: targetID,
            type: .normal,
            name: "Page"
        )
    )
    session.applyExecutionContextCreated(
        RuntimeExecutionContext(
            id: ExecutionContextID(2),
            targetID: targetID,
            type: .user,
            name: "Selected Isolated World"
        )
    )

    session.selectExecutionContext(ExecutionContextID(2))

    let intent = session.evaluateIntent(expression: "window.location.href", targetID: targetID)
    guard case let .evaluate(request) = intent else {
        Issue.record("Expected evaluate intent")
        return
    }
    #expect(request.contextID == ExecutionContextID(2))
    #expect(session.snapshot().selectedContextID == ExecutionContextID(2))
}

@Test
@MainActor
func runtimeSessionPreservesTransportSeededContextMetadata() {
    let session = RuntimeSession()
    let targetID = ProtocolTargetIdentifier("page")

    session.applyExecutionContextCreated(
        RuntimeExecutionContext(
            id: ExecutionContextID(1),
            targetID: targetID,
            type: .internal,
            name: "Isolated World",
            frameID: DOMFrameIdentifier("main-frame")
        )
    )

    let snapshot = session.snapshot()
    #expect(snapshot.executionContextsByID[ExecutionContextID(1)]?.type == .internal)
    #expect(snapshot.executionContextsByID[ExecutionContextID(1)]?.name == "Isolated World")
    #expect(snapshot.normalContextIDByTargetID[targetID] == nil)
    #expect(snapshot.selectedContextID == nil)
}

@Test
@MainActor
func runtimeSessionClearsExecutionContextsByRuntimeAgentTarget() {
    let session = RuntimeSession()
    let pageTargetID = ProtocolTargetIdentifier("page")
    let frameTargetID = ProtocolTargetIdentifier("frame")
    let otherFrameTargetID = ProtocolTargetIdentifier("other-frame")

    session.applyExecutionContextCreated(
        RuntimeExecutionContext(
            id: ExecutionContextID(1),
            targetID: frameTargetID,
            runtimeAgentTargetID: pageTargetID,
            frameID: DOMFrameIdentifier("frame")
        )
    )
    session.applyExecutionContextCreated(
        RuntimeExecutionContext(
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

    #expect(snapshot.executionContextsByID[ExecutionContextID(1)] == nil)
    #expect(snapshot.executionContextsByID[ExecutionContextID(2)]?.targetID == otherFrameTargetID)
    #expect(snapshot.normalContextIDByTargetID[frameTargetID] == nil)
    #expect(snapshot.normalContextIDByTargetID[otherFrameTargetID] == ExecutionContextID(2))
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
        RuntimeExecutionContext(
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

    #expect(snapshot.executionContextsByID[ExecutionContextID(1)] == nil)
    #expect(snapshot.normalContextIDByTargetID[frameTargetID] == nil)
    #expect(snapshot.selectedContextID == nil)
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
        RuntimeExecutionContext(id: ExecutionContextID(1), targetID: oldTargetID)
    )
    session.registerRemoteObject(
        RuntimeRemoteObjectPayload(type: .object, objectID: objectID),
        runtimeAgentTargetID: oldTargetID,
        objectGroup: .console,
        executionContextID: ExecutionContextID(1)
    )

    session.applyTargetCommitted(oldTargetID: oldTargetID, newTargetID: newTargetID)
    let snapshot = session.snapshot()

    #expect(snapshot.executionContextsByID[ExecutionContextID(1)]?.targetID == newTargetID)
    #expect(snapshot.executionContextsByID[ExecutionContextID(1)]?.runtimeAgentTargetID == newTargetID)
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: oldTargetID, objectID: objectID)] == nil)
    #expect(snapshot.remoteObjectsByID[.init(runtimeAgentTargetID: newTargetID, objectID: objectID)] == nil)
    #expect(snapshot.objectGroupRuntimeAgentTargetsByGroup[.console] == nil)
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
