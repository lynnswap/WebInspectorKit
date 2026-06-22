import Foundation
import Testing
import WebInspectorTransport
@testable import WebInspectorCore
@testable import WebInspectorCoreConsoleNetwork
@testable import WebInspectorCoreDOMCSS
@testable import WebInspectorCoreRuntime
@testable import WebInspectorCoreSupport

@Test
func runtimeProtocolDispatchingBuildsEvaluateCommandAndDecodesResult() throws {
    let targetID = ProtocolTarget.ID("page")
    let intent = RuntimeCommand.Intent.evaluate(
        RuntimeEvaluation.Request(
            runtimeAgentTargetID: targetID,
            expression: "document.title",
            objectGroup: RuntimeRemoteObject.Group("console"),
            includeCommandLineAPI: true,
            doNotPauseOnExceptionsAndMuteConsole: false,
            contextID: RuntimeContext.ID(7),
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

    let result = ProtocolCommand.Result(
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
    let key = RuntimeRemoteObject.ID(
        runtimeAgentTargetID: ProtocolTarget.ID("frame"),
        objectID: RuntimeRemoteObject.ProtocolID("object-1")
    )

    let propertiesCommand = try RuntimeProtocolCommands().command(
        for: .getDisplayableProperties(object: key, fetchStart: 10, fetchCount: 20, generatePreview: true)
    )
    let propertiesParameters = try parametersObject(propertiesCommand.parametersData)
    #expect(propertiesCommand.method == "Runtime.getDisplayableProperties")
    #expect(propertiesParameters["objectId"] as? String == "object-1")
    #expect(propertiesParameters["fetchStart"] as? Int == 10)
    #expect(propertiesParameters["fetchCount"] as? Int == 20)

    let propertiesResult = ProtocolCommand.Result(
        domain: .runtime,
        method: "Runtime.getProperties",
        targetID: key.runtimeAgentTargetID,
        resultData: Data(#"{"properties":[{"name":"length","value":{"type":"number","value":3}}],"internalProperties":[{"name":"[[Prototype]]","value":{"type":"object","objectId":"proto"}}]}"#.utf8)
    )
    let properties = try RuntimeProtocolCommands().propertiesResult(from: propertiesResult)
    #expect(properties.properties.first?.name == "length")
    #expect(properties.properties.first?.value?.value == .number(3))
    #expect(properties.internalProperties.first?.value?.objectID == RuntimeRemoteObject.ProtocolID("proto"))

    let entriesResult = ProtocolCommand.Result(
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
    let targetID = ProtocolTarget.ID("frame")
    let event = ProtocolEvent(
        sequence: 1,
        domain: .runtime,
        method: "Runtime.executionContextCreated",
        targetID: targetID,
        paramsData: Data(#"{"context":{"id":42,"type":"normal","name":"Frame","frameId":"frame-1"}}"#.utf8)
    )

    try await dispatcher.dispatch(event)

    let snapshot = session.snapshot()
    #expect(snapshot.executionContextsByKey[contextKey(targetID, 42)]?.targetID == targetID)
    #expect(snapshot.executionContextsByKey[contextKey(targetID, 42)]?.frameID == DOMFrame.ID("frame-1"))
    #expect(snapshot.normalContextKeyByTargetID[targetID] == contextKey(targetID, 42))
}

@Test
@MainActor
func runtimeProtocolDispatchingAppliesExecutionContextTeardownEvents() async throws {
    let session = RuntimeState()
    let dispatcher = RuntimeProtocolEventDispatcher(handlers: [session])
    let targetID = ProtocolTarget.ID("frame")

    try await dispatcher.dispatch(
        ProtocolEvent(
            sequence: 1,
            domain: .runtime,
            method: "Runtime.executionContextCreated",
            targetID: targetID,
            paramsData: Data(#"{"context":{"id":42,"type":"normal","frameId":"frame-1"}}"#.utf8)
        )
    )
    try await dispatcher.dispatch(
        ProtocolEvent(
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
        ProtocolEvent(
            sequence: 3,
            domain: .runtime,
            method: "Runtime.executionContextCreated",
            targetID: targetID,
            paramsData: Data(#"{"context":{"id":43,"type":"normal","frameId":"frame-1"}}"#.utf8)
        )
    )
    try await dispatcher.dispatch(
        ProtocolEvent(
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
    let pageTargetID = ProtocolTarget.ID("page")
    let frameTargetID = ProtocolTarget.ID("frame")

    #expect(session.supportsCommand("Runtime.getDisplayableProperties", targetID: pageTargetID))
    session.markCommandUnsupported("Runtime.getDisplayableProperties", targetID: pageTargetID)
    #expect(session.supportsCommand("Runtime.getDisplayableProperties", targetID: pageTargetID) == false)
    #expect(session.supportsCommand("Runtime.getDisplayableProperties", targetID: frameTargetID))
}

private func parametersObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func contextKey(_ runtimeAgentTargetID: ProtocolTarget.ID, _ contextID: Int) -> RuntimeContext.Key {
    RuntimeContext.Key(runtimeAgentTargetID: runtimeAgentTargetID, contextID: RuntimeContext.ID(contextID))
}
