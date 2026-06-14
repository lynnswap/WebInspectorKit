import Foundation
import WebInspectorTransport

package struct ConsoleProtocolCommands {
    package func command(for intent: ConsoleCommandIntent) throws -> ProtocolCommand {
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

    package func loggingChannels(from result: ProtocolCommand.Result) throws -> [ConsoleLoggingChannelPayload] {
        let payload = try TransportMessageParser.decode(LoggingChannelsResult.self, from: result.resultData)
        return payload.channels
    }

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }
}

@MainActor
package protocol ConsoleProtocolEventHandler: AnyObject {
    func consoleMessageAdded(_ message: ConsoleMessagePayload, targetID: ProtocolTarget.ID, parameters: [RuntimeRemoteObject]?)
    func consoleRepeatCountUpdated(count: Int, timestamp: Double?, targetID: ProtocolTarget.ID)
    func consoleMessagesCleared(reason: ConsoleClearReason, targetID: ProtocolTarget.ID)
}

@MainActor
package final class ConsoleProtocolEventDispatcher: ProtocolDomainEventDispatcher {
    private weak var handler: (any ConsoleProtocolEventHandler)?
    private weak var runtime: RuntimeState?

    package init(handler: any ConsoleProtocolEventHandler, runtime: RuntimeState) {
        self.handler = handler
        self.runtime = runtime
    }

    package var domain: ProtocolDomain { .console }

    package func dispatch(_ event: ProtocolEvent) async throws {
        guard event.domain == .console,
              let targetID = event.targetID,
              let handler else {
            return
        }

        switch event.method {
        case "Console.messageAdded":
            let params = try TransportMessageParser.decode(MessageAddedParams.self, from: event.paramsData)
            let registeredParameters = runtime.map { runtime in
                params.message.parameters.map { parameter in
                    runtime.registerRemoteObject(
                        parameter,
                        runtimeAgentTargetID: targetID,
                        objectGroup: .console
                    )
                }
            }
            handler.consoleMessageAdded(params.message, targetID: targetID, parameters: registeredParameters)
        case "Console.messageRepeatCountUpdated":
            let params = try TransportMessageParser.decode(MessageRepeatCountUpdatedParams.self, from: event.paramsData)
            handler.consoleRepeatCountUpdated(count: params.count, timestamp: params.timestamp, targetID: targetID)
        case "Console.messagesCleared":
            let params = try TransportMessageParser.decode(MessagesClearedParams.self, from: event.paramsData)
            handler.consoleMessagesCleared(reason: params.reason, targetID: targetID)
            runtime?.releaseObjectGroup(.console, runtimeAgentTargetID: targetID)
        default:
            break
        }
    }
}

extension ConsoleSession: ConsoleProtocolEventHandler {
    package func consoleMessageAdded(
        _ message: ConsoleMessagePayload,
        targetID: ProtocolTarget.ID,
        parameters: [RuntimeRemoteObject]?
    ) {
        applyMessageAdded(message, targetID: targetID, parameters: parameters)
    }

    package func consoleRepeatCountUpdated(count: Int, timestamp: Double?, targetID: ProtocolTarget.ID) {
        applyRepeatCountUpdated(count: count, timestamp: timestamp, targetID: targetID)
    }

    package func consoleMessagesCleared(reason: ConsoleClearReason, targetID: ProtocolTarget.ID) {
        applyMessagesCleared(reason: reason, targetID: targetID)
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
