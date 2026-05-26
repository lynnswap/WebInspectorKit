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
    #expect(snapshot.activeContextID == ExecutionContextID(3))
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
func runtimeSessionPreservesTransportSeededContextMetadata() {
    let session = RuntimeSession()
    let targetID = ProtocolTargetIdentifier("page")

    session.applyExecutionContextCreated(
        ExecutionContextRecord(
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
    #expect(snapshot.activeContextID == nil)
}

@Test
@MainActor
func runtimeRemoteObjectIdentityIncludesTargetAndObjectID() {
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

    session.registerRemoteObject(pageObject, targetID: pageTargetID, objectGroup: RuntimeObjectGroup("console"))
    session.registerRemoteObject(frameObject, targetID: frameTargetID, objectGroup: RuntimeObjectGroup("console"))

    let snapshot = session.snapshot()
    #expect(snapshot.remoteObjectsByID[.init(targetID: pageTargetID, objectID: objectID)]?.description == "page object")
    #expect(snapshot.remoteObjectsByID[.init(targetID: frameTargetID, objectID: objectID)]?.description == "frame object")
    #expect(snapshot.objectGroupByRemoteObjectID[.init(targetID: pageTargetID, objectID: objectID)] == RuntimeObjectGroup("console"))
    #expect(snapshot.objectGroupTargetsByGroup[RuntimeObjectGroup("console")] == [pageTargetID, frameTargetID])
}
