import Foundation
import Testing
import WebInspectorTransport
@testable import WebInspectorCore

@Test
func runtimeProtocolDispatchingBuildsEvaluateCommandAndDecodesResult() throws {
    let targetID = ProtocolTargetIdentifier("page")
    let intent = RuntimeCommandIntent.evaluate(
        RuntimeEvaluationRequest(
            runtimeAgentTargetID: targetID,
            expression: "document.title",
            objectGroup: RuntimeObjectGroup("console"),
            includeCommandLineAPI: true,
            doNotPauseOnExceptionsAndMuteConsole: false,
            contextID: ExecutionContextID(7),
            returnByValue: false,
            generatePreview: true,
            saveResult: true,
            emulateUserGesture: true
        )
    )
    let command = try RuntimeProtocolCommands().command(for: intent)
    let parameters = try parametersObject(command.parametersData)

    #expect(command.domain == .runtime)
    #expect(command.method == "Runtime.evaluate")
    #expect(command.routing == .target(targetID))
    #expect(parameters["expression"] as? String == "document.title")
    #expect(parameters["objectGroup"] as? String == "console")
    #expect(parameters["contextId"] as? Int == 7)
    #expect(parameters["generatePreview"] as? Bool == true)

    let result = ProtocolCommandResult(
        domain: .runtime,
        method: "Runtime.evaluate",
        targetID: targetID,
        resultData: Data(#"{"result":{"type":"string","value":"Title","description":"Title"},"savedResultIndex":1}"#.utf8)
    )
    let payload = try RuntimeProtocolCommands().evaluationResult(from: result)
    #expect(payload.result.type == .string)
    #expect(payload.result.value == .string("Title"))
    #expect(payload.wasThrown == false)
    #expect(payload.savedResultIndex == 1)
}

@Test
func runtimeProtocolDispatchingBuildsObjectCommandsAndDecodesPropertiesAndCollections() throws {
    let key = RuntimeRemoteObjectIdentifierKey(
        runtimeAgentTargetID: ProtocolTargetIdentifier("frame"),
        objectID: RuntimeRemoteObjectIdentifier("object-1")
    )

    let propertiesCommand = try RuntimeProtocolCommands().command(
        for: .getDisplayableProperties(object: key, fetchStart: 10, fetchCount: 20, generatePreview: true)
    )
    let propertiesParameters = try parametersObject(propertiesCommand.parametersData)
    #expect(propertiesCommand.method == "Runtime.getDisplayableProperties")
    #expect(propertiesParameters["objectId"] as? String == "object-1")
    #expect(propertiesParameters["fetchStart"] as? Int == 10)
    #expect(propertiesParameters["fetchCount"] as? Int == 20)

    let propertiesResult = ProtocolCommandResult(
        domain: .runtime,
        method: "Runtime.getProperties",
        targetID: key.runtimeAgentTargetID,
        resultData: Data(#"{"properties":[{"name":"length","value":{"type":"number","value":3}}],"internalProperties":[{"name":"[[Prototype]]","value":{"type":"object","objectId":"proto"}}]}"#.utf8)
    )
    let properties = try RuntimeProtocolCommands().propertiesResult(from: propertiesResult)
    #expect(properties.properties.first?.name == "length")
    #expect(properties.properties.first?.value?.value == .number(3))
    #expect(properties.internalProperties.first?.value?.objectID == RuntimeRemoteObjectIdentifier("proto"))

    let entriesResult = ProtocolCommandResult(
        domain: .runtime,
        method: "Runtime.getCollectionEntries",
        targetID: key.runtimeAgentTargetID,
        resultData: Data(#"{"entries":[{"key":{"type":"string","value":"k"},"value":{"type":"number","value":1}}]}"#.utf8)
    )
    let entries = try RuntimeProtocolCommands().collectionEntriesResult(from: entriesResult)
    #expect(entries.entries.first?.key?.value == .string("k"))
    #expect(entries.entries.first?.value.value == .number(1))
}

@Test
@MainActor
func runtimeProtocolDispatchingAppliesExecutionContextEventToRuntimeState() async throws {
    let session = RuntimeState()
    let dispatcher = RuntimeProtocolEventDispatcher(handlers: [session])
    let targetID = ProtocolTargetIdentifier("frame")
    let event = ProtocolEventEnvelope(
        sequence: 1,
        domain: .runtime,
        method: "Runtime.executionContextCreated",
        targetID: targetID,
        paramsData: Data(#"{"context":{"id":42,"type":"normal","name":"Frame","frameId":"frame-1"}}"#.utf8)
    )

    try await dispatcher.dispatch(event)

    let snapshot = session.snapshot()
    #expect(snapshot.executionContextsByKey[contextKey(targetID, 42)]?.targetID == targetID)
    #expect(snapshot.executionContextsByKey[contextKey(targetID, 42)]?.frameID == DOMFrameIdentifier("frame-1"))
    #expect(snapshot.normalContextKeyByTargetID[targetID] == contextKey(targetID, 42))
}

@Test
@MainActor
func runtimeProtocolDispatchingAppliesExecutionContextTeardownEvents() async throws {
    let session = RuntimeState()
    let dispatcher = RuntimeProtocolEventDispatcher(handlers: [session])
    let targetID = ProtocolTargetIdentifier("frame")

    try await dispatcher.dispatch(
        ProtocolEventEnvelope(
            sequence: 1,
            domain: .runtime,
            method: "Runtime.executionContextCreated",
            targetID: targetID,
            paramsData: Data(#"{"context":{"id":42,"type":"normal","frameId":"frame-1"}}"#.utf8)
        )
    )
    try await dispatcher.dispatch(
        ProtocolEventEnvelope(
            sequence: 2,
            domain: .runtime,
            method: "Runtime.executionContextDestroyed",
            targetID: targetID,
            paramsData: Data(#"{"executionContextId":42}"#.utf8)
        )
    )
    #expect(session.snapshot().executionContextsByKey[contextKey(targetID, 42)] == nil)
    #expect(session.snapshot().normalContextKeyByTargetID[targetID] == nil)

    try await dispatcher.dispatch(
        ProtocolEventEnvelope(
            sequence: 3,
            domain: .runtime,
            method: "Runtime.executionContextCreated",
            targetID: targetID,
            paramsData: Data(#"{"context":{"id":43,"type":"normal","frameId":"frame-1"}}"#.utf8)
        )
    )
    try await dispatcher.dispatch(
        ProtocolEventEnvelope(
            sequence: 4,
            domain: .runtime,
            method: "Runtime.executionContextsCleared",
            targetID: targetID,
            paramsData: Data("{}".utf8)
        )
    )
    #expect(session.snapshot().executionContextsByKey[contextKey(targetID, 43)] == nil)
    #expect(session.snapshot().normalContextKeyByTargetID[targetID] == nil)
}

@Test
@MainActor
func runtimeSessionTracksUnsupportedOptionalCommandsPerTarget() {
    let session = RuntimeState()
    let pageTargetID = ProtocolTargetIdentifier("page")
    let frameTargetID = ProtocolTargetIdentifier("frame")

    #expect(session.supportsCommand("Runtime.getDisplayableProperties", targetID: pageTargetID))
    session.markCommandUnsupported("Runtime.getDisplayableProperties", targetID: pageTargetID)
    #expect(session.supportsCommand("Runtime.getDisplayableProperties", targetID: pageTargetID) == false)
    #expect(session.supportsCommand("Runtime.getDisplayableProperties", targetID: frameTargetID))
}

private func parametersObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func contextKey(_ runtimeAgentTargetID: ProtocolTargetIdentifier, _ contextID: Int) -> RuntimeExecutionContextKey {
    RuntimeExecutionContextKey(runtimeAgentTargetID: runtimeAgentTargetID, contextID: ExecutionContextID(contextID))
}
