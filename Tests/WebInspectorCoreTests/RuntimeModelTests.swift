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
            name: "Frame",
            frameID: DOMFrameIdentifier("frame")
        ),
        targetID: frameTargetID
    )
    session.applyExecutionContextCreated(
        RuntimeExecutionContextPayload(
            id: ExecutionContextID(2),
            type: .normal,
            name: "Frame replacement",
            frameID: DOMFrameIdentifier("frame")
        ),
        targetID: frameTargetID
    )

    let snapshot = session.snapshot()
    #expect(snapshot.executionContextsByID[ExecutionContextID(1)] == nil)
    #expect(snapshot.executionContextsByID[ExecutionContextID(2)]?.targetID == frameTargetID)
    #expect(snapshot.executionContextsByID[ExecutionContextID(2)]?.frameID == DOMFrameIdentifier("frame"))
    #expect(snapshot.normalContextIDByTargetID[frameTargetID] == ExecutionContextID(2))
    #expect(snapshot.activeContextID == ExecutionContextID(2))
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
