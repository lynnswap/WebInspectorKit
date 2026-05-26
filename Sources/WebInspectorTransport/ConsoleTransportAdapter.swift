import Foundation
import WebInspectorCore

package enum ConsoleTransportAdapter {
    package static func command(for intent: ConsoleCommandIntent) throws -> ProtocolCommand {
        switch intent {
        case let .enable(targetID):
            return ProtocolCommand(domain: .console, method: "Console.enable", routing: .target(targetID))
        case let .disable(targetID):
            return ProtocolCommand(domain: .console, method: "Console.disable", routing: .target(targetID))
        case let .clearMessages(targetID):
            return ProtocolCommand(domain: .console, method: "Console.clearMessages", routing: .target(targetID))
        case let .setConsoleClearAPIEnabled(targetID, enabled):
            return ProtocolCommand(
                domain: .console,
                method: "Console.setConsoleClearAPIEnabled",
                routing: .target(targetID),
                parametersData: try data(["enable": enabled])
            )
        case let .getLoggingChannels(targetID):
            return ProtocolCommand(domain: .console, method: "Console.getLoggingChannels", routing: .target(targetID))
        case let .setLoggingChannelLevel(targetID, source, level):
            return ProtocolCommand(
                domain: .console,
                method: "Console.setLoggingChannelLevel",
                routing: .target(targetID),
                parametersData: try data([
                    "source": source.rawValue,
                    "level": level.rawValue,
                ])
            )
        }
    }

    package static func loggingChannels(from result: ProtocolCommandResult) throws -> [ConsoleLoggingChannelPayload] {
        let payload = try TransportMessageParser.decode(LoggingChannelsResult.self, from: result.resultData)
        return payload.channels
    }

    package static func messagePayload(from event: ProtocolEventEnvelope) throws -> ConsoleMessagePayload? {
        guard event.method == "Console.messageAdded" else {
            return nil
        }
        let params = try TransportMessageParser.decode(MessageAddedParams.self, from: event.paramsData)
        return params.message
    }

    @MainActor
    package static func applyConsoleEvent(_ event: ProtocolEventEnvelope, to session: ConsoleSession) throws {
        guard event.domain == .console,
              let targetID = event.targetID else {
            return
        }

        switch event.method {
        case "Console.messageAdded":
            let params = try TransportMessageParser.decode(MessageAddedParams.self, from: event.paramsData)
            session.applyMessageAdded(params.message, targetID: targetID)
        case "Console.messageRepeatCountUpdated":
            let params = try TransportMessageParser.decode(MessageRepeatCountUpdatedParams.self, from: event.paramsData)
            session.applyRepeatCountUpdated(count: params.count, timestamp: params.timestamp, targetID: targetID)
        case "Console.messagesCleared":
            let params = try TransportMessageParser.decode(MessagesClearedParams.self, from: event.paramsData)
            session.applyMessagesCleared(reason: params.reason, targetID: targetID)
        default:
            break
        }
    }

    private static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }
}

private struct LoggingChannelsResult: Decodable {
    var channels: [ConsoleLoggingChannelPayload]
}

private struct MessageAddedParams: Decodable {
    var message: ConsoleMessagePayload
}

private struct MessageRepeatCountUpdatedParams: Decodable {
    var count: Int
    var timestamp: Double?
}

private struct MessagesClearedParams: Decodable {
    var reason: ConsoleClearReason
}
