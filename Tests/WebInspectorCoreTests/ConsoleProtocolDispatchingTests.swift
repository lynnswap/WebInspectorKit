import Foundation
import Testing
import WebInspectorTransport
@testable import WebInspectorCore

@Test
func consoleProtocolDispatchingBuildsCommandsAndDecodesLoggingChannels() throws {
    let targetID = ProtocolTarget.ID("page")
    let enableCommand = try ConsoleProtocolCommands().command(for: .enable(targetID: targetID))
    #expect(enableCommand.domain == .console)
    #expect(enableCommand.method == "Console.enable")
    #expect(enableCommand.routing == .target(targetID))

    let channelCommand = try ConsoleProtocolCommands().command(
        for: .setLoggingChannelLevel(targetID: targetID, source: .network, level: .verbose)
    )
    let channelParameters = try consoleParametersObject(channelCommand.parametersData)
    #expect(channelCommand.method == "Console.setLoggingChannelLevel")
    #expect(channelParameters["source"] as? String == "network")
    #expect(channelParameters["level"] as? String == "verbose")

    let result = ProtocolCommand.Result(
        domain: .console,
        method: "Console.getLoggingChannels",
        targetID: targetID,
        resultData: Data(#"{"channels":[{"source":"network","level":"verbose"}]}"#.utf8)
    )
    #expect(try ConsoleProtocolCommands().loggingChannels(from: result) == [
        ConsoleLoggingChannel.Payload(source: .network, level: .verbose),
    ])
}

@Test
@MainActor
func consoleProtocolDispatchingAppliesTargetScopedConsoleEvents() async throws {
    let session = ConsoleSession()
    let runtime = RuntimeState()
    let dispatcher = ConsoleProtocolEventDispatcher(handler: session, runtime: runtime)
    let targetID = ProtocolTarget.ID("frame")

    try await dispatcher.dispatch(
        ProtocolEvent(
            sequence: 1,
            domain: .console,
            method: "Console.messageAdded",
            targetID: targetID,
            paramsData: Data(#"{"message":{"source":"network","level":"error","text":"Load failed","type":"log","parameters":[{"type":"object","objectId":"object-1","description":"Error"}],"networkRequestId":"request-1","timestamp":10}}"#.utf8)
        )
    )
    try await dispatcher.dispatch(
        ProtocolEvent(
            sequence: 2,
            domain: .console,
            method: "Console.messageRepeatCountUpdated",
            targetID: targetID,
            paramsData: Data(#"{"count":4,"timestamp":11}"#.utf8)
        )
    )

    var snapshot = session.snapshot()
    let messageID = try #require(snapshot.orderedMessageIDs.first)
    let message = try #require(snapshot.messagesByID[messageID])
    #expect(messageID.targetID == targetID)
    #expect(message.level == .error)
    #expect(message.repeatCount == 4)
    #expect(message.parameters.first?.objectID == RuntimeRemoteObject.ProtocolID("object-1"))
    #expect(message.networkRequestKey == NetworkRequest.ID(targetID: targetID, requestID: .init("request-1")))
    #expect(snapshot.errorCount == 4)

    try await dispatcher.dispatch(
        ProtocolEvent(
            sequence: 3,
            domain: .console,
            method: "Console.messagesCleared",
            targetID: targetID,
            paramsData: Data(#"{"reason":"frontend"}"#.utf8)
        )
    )
    snapshot = session.snapshot()
    #expect(snapshot.orderedMessageIDs.isEmpty)
    #expect(snapshot.lastClearReasonByTargetID[targetID] == .frontend)
}

@Test
@MainActor
func consoleSessionTracksUnsupportedOptionalCommandsPerTarget() {
    let session = ConsoleSession()
    let pageTargetID = ProtocolTarget.ID("page")
    let frameTargetID = ProtocolTarget.ID("frame")

    #expect(session.supportsCommand("Console.getLoggingChannels", targetID: pageTargetID))
    session.markCommandUnsupported("Console.getLoggingChannels", targetID: pageTargetID)
    #expect(session.supportsCommand("Console.getLoggingChannels", targetID: pageTargetID) == false)
    #expect(session.supportsCommand("Console.getLoggingChannels", targetID: frameTargetID))
}

private func consoleParametersObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
