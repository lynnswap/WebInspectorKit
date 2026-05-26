import Foundation
import Testing
@testable import WebInspectorCore
@testable import WebInspectorTransport

@Test
func consoleTransportAdapterBuildsCommandsAndDecodesLoggingChannels() throws {
    let targetID = ProtocolTargetIdentifier("page")
    let enableCommand = try ConsoleTransportAdapter.command(for: .enable(targetID: targetID))
    #expect(enableCommand.domain == .console)
    #expect(enableCommand.method == "Console.enable")
    #expect(enableCommand.routing == .target(targetID))

    let channelCommand = try ConsoleTransportAdapter.command(
        for: .setLoggingChannelLevel(targetID: targetID, source: .network, level: .verbose)
    )
    let channelParameters = try consoleParametersObject(channelCommand.parametersData)
    #expect(channelCommand.method == "Console.setLoggingChannelLevel")
    #expect(channelParameters["source"] as? String == "network")
    #expect(channelParameters["level"] as? String == "verbose")

    let result = ProtocolCommandResult(
        domain: .console,
        method: "Console.getLoggingChannels",
        targetID: targetID,
        resultData: Data(#"{"channels":[{"source":"network","level":"verbose"}]}"#.utf8)
    )
    #expect(try ConsoleTransportAdapter.loggingChannels(from: result) == [
        ConsoleLoggingChannelPayload(source: .network, level: .verbose),
    ])
}

@Test
@MainActor
func consoleTransportAdapterAppliesTargetScopedConsoleEvents() throws {
    let session = ConsoleSession()
    let targetID = ProtocolTargetIdentifier("frame")

    try ConsoleTransportAdapter.applyConsoleEvent(
        ProtocolEventEnvelope(
            sequence: 1,
            domain: .console,
            method: "Console.messageAdded",
            targetID: targetID,
            paramsData: Data(#"{"message":{"source":"network","level":"error","text":"Load failed","type":"log","parameters":[{"type":"object","objectId":"object-1","description":"Error"}],"networkRequestId":"request-1","timestamp":10}}"#.utf8)
        ),
        to: session
    )
    try ConsoleTransportAdapter.applyConsoleEvent(
        ProtocolEventEnvelope(
            sequence: 2,
            domain: .console,
            method: "Console.messageRepeatCountUpdated",
            targetID: targetID,
            paramsData: Data(#"{"count":4,"timestamp":11}"#.utf8)
        ),
        to: session
    )

    var snapshot = session.snapshot()
    let messageID = try #require(snapshot.orderedMessageIDs.first)
    let message = try #require(snapshot.messagesByID[messageID])
    #expect(messageID.targetID == targetID)
    #expect(message.level == .error)
    #expect(message.repeatCount == 4)
    #expect(message.parameters.first?.objectID == RuntimeRemoteObjectIdentifier("object-1"))
    #expect(message.networkRequestKey == NetworkRequestIdentifierKey(targetID: targetID, requestID: .init("request-1")))
    #expect(snapshot.errorCount == 4)

    try ConsoleTransportAdapter.applyConsoleEvent(
        ProtocolEventEnvelope(
            sequence: 3,
            domain: .console,
            method: "Console.messagesCleared",
            targetID: targetID,
            paramsData: Data(#"{"reason":"frontend"}"#.utf8)
        ),
        to: session
    )
    snapshot = session.snapshot()
    #expect(snapshot.orderedMessageIDs.isEmpty)
    #expect(snapshot.lastClearReasonByTargetID[targetID] == .frontend)
}

@Test
@MainActor
func consoleSessionTracksUnsupportedOptionalCommandsPerTarget() {
    let session = ConsoleSession()
    let pageTargetID = ProtocolTargetIdentifier("page")
    let frameTargetID = ProtocolTargetIdentifier("frame")

    #expect(session.supportsCommand("Console.getLoggingChannels", targetID: pageTargetID))
    session.markCommandUnsupported("Console.getLoggingChannels", targetID: pageTargetID)
    #expect(session.supportsCommand("Console.getLoggingChannels", targetID: pageTargetID) == false)
    #expect(session.supportsCommand("Console.getLoggingChannels", targetID: frameTargetID))
}

private func consoleParametersObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
