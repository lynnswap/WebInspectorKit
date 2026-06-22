import WebInspectorCoreSupport
import Foundation
import WebInspectorTransport

package struct RuntimeProtocolCommands {
    package func command(for intent: RuntimeCommand.Intent) throws -> ProtocolCommand {
        switch intent {
        case let .enable(targetID):
            return ProtocolCommand(domain: .runtime, method: "Runtime.enable", routing: .target(targetID))
        case let .evaluate(request):
            return ProtocolCommand(
                domain: .runtime,
                method: "Runtime.evaluate",
                routing: .target(request.runtimeAgentTargetID),
                parametersData: try data(evaluationParameters(request))
            )
        case let .getPreview(object):
            return ProtocolCommand(
                domain: .runtime,
                method: "Runtime.getPreview",
                routing: .target(object.runtimeAgentTargetID),
                parametersData: try data(["objectId": object.objectID.rawValue])
            )
        case let .getProperties(object, ownProperties, fetchStart, fetchCount, generatePreview):
            return ProtocolCommand(
                domain: .runtime,
                method: "Runtime.getProperties",
                routing: .target(object.runtimeAgentTargetID),
                parametersData: try data(
                    objectParameters(
                        object,
                        ownProperties: ownProperties,
                        fetchStart: fetchStart,
                        fetchCount: fetchCount,
                        generatePreview: generatePreview
                    )
                )
            )
        case let .getDisplayableProperties(object, fetchStart, fetchCount, generatePreview):
            return ProtocolCommand(
                domain: .runtime,
                method: "Runtime.getDisplayableProperties",
                routing: .target(object.runtimeAgentTargetID),
                parametersData: try data(
                    objectParameters(
                        object,
                        fetchStart: fetchStart,
                        fetchCount: fetchCount,
                        generatePreview: generatePreview
                    )
                )
            )
        case let .getCollectionEntries(object, objectGroup, fetchStart, fetchCount):
            var parameters = objectParameters(object, fetchStart: fetchStart, fetchCount: fetchCount)
            if let objectGroup {
                parameters["objectGroup"] = objectGroup.rawValue
            }
            return ProtocolCommand(
                domain: .runtime,
                method: "Runtime.getCollectionEntries",
                routing: .target(object.runtimeAgentTargetID),
                parametersData: try data(parameters)
            )
        case let .saveResult(targetID, argument, contextID):
            var parameters: [String: Any] = ["value": argument.parametersObject]
            if let contextID {
                parameters["contextId"] = contextID.rawValue
            }
            return ProtocolCommand(
                domain: .runtime,
                method: "Runtime.saveResult",
                routing: .target(targetID),
                parametersData: try data(parameters)
            )
        case let .setSavedResultAlias(targetID, alias):
            var parameters: [String: Any] = [:]
            if let alias {
                parameters["alias"] = alias
            }
            return ProtocolCommand(
                domain: .runtime,
                method: "Runtime.setSavedResultAlias",
                routing: .target(targetID),
                parametersData: try data(parameters)
            )
        case let .releaseObject(object):
            return ProtocolCommand(
                domain: .runtime,
                method: "Runtime.releaseObject",
                routing: .target(object.runtimeAgentTargetID),
                parametersData: try data(["objectId": object.objectID.rawValue])
            )
        case let .releaseObjectGroup(runtimeAgentTargetID, objectGroup):
            return ProtocolCommand(
                domain: .runtime,
                method: "Runtime.releaseObjectGroup",
                routing: .target(runtimeAgentTargetID),
                parametersData: try data(["objectGroup": objectGroup.rawValue])
            )
        }
    }

    package func evaluationResult(from result: ProtocolCommand.Result) throws -> RuntimeEvaluation.ResultPayload {
        try TransportMessageParser.decode(RuntimeEvaluation.ResultPayload.self, from: result.resultData)
    }

    package func previewResult(from result: ProtocolCommand.Result) throws -> RuntimeRemoteObject.Preview.ResultPayload {
        try TransportMessageParser.decode(RuntimeRemoteObject.Preview.ResultPayload.self, from: result.resultData)
    }

    package func propertiesResult(from result: ProtocolCommand.Result) throws -> RuntimeRemoteObject.PropertiesResultPayload {
        try TransportMessageParser.decode(RuntimeRemoteObject.PropertiesResultPayload.self, from: result.resultData)
    }

    package func collectionEntriesResult(from result: ProtocolCommand.Result) throws -> RuntimeRemoteObject.CollectionEntriesResultPayload {
        try TransportMessageParser.decode(RuntimeRemoteObject.CollectionEntriesResultPayload.self, from: result.resultData)
    }

    package func saveResult(from result: ProtocolCommand.Result) throws -> RuntimeEvaluation.SaveResultPayload {
        try TransportMessageParser.decode(RuntimeEvaluation.SaveResultPayload.self, from: result.resultData)
    }

    private func evaluationParameters(_ request: RuntimeEvaluation.Request) -> [String: Any] {
        var parameters: [String: Any] = [
            "expression": request.expression,
        ]
        if let objectGroup = request.objectGroup {
            parameters["objectGroup"] = objectGroup.rawValue
        }
        if let includeCommandLineAPI = request.includeCommandLineAPI {
            parameters["includeCommandLineAPI"] = includeCommandLineAPI
        }
        if let doNotPauseOnExceptionsAndMuteConsole = request.doNotPauseOnExceptionsAndMuteConsole {
            parameters["doNotPauseOnExceptionsAndMuteConsole"] = doNotPauseOnExceptionsAndMuteConsole
        }
        if let contextID = request.contextID {
            parameters["contextId"] = contextID.rawValue
        }
        if let returnByValue = request.returnByValue {
            parameters["returnByValue"] = returnByValue
        }
        if let generatePreview = request.generatePreview {
            parameters["generatePreview"] = generatePreview
        }
        if let saveResult = request.saveResult {
            parameters["saveResult"] = saveResult
        }
        if let emulateUserGesture = request.emulateUserGesture {
            parameters["emulateUserGesture"] = emulateUserGesture
        }
        return parameters
    }

    private func objectParameters(
        _ object: RuntimeRemoteObject.ID,
        ownProperties: Bool? = nil,
        fetchStart: Int? = nil,
        fetchCount: Int? = nil,
        generatePreview: Bool? = nil
    ) -> [String: Any] {
        var parameters: [String: Any] = [
            "objectId": object.objectID.rawValue,
        ]
        if let ownProperties {
            parameters["ownProperties"] = ownProperties
        }
        if let fetchStart {
            parameters["fetchStart"] = fetchStart
        }
        if let fetchCount {
            parameters["fetchCount"] = fetchCount
        }
        if let generatePreview {
            parameters["generatePreview"] = generatePreview
        }
        return parameters
    }

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }
}

@MainActor
package protocol RuntimeProtocolEventHandler: AnyObject {
    func runtimeExecutionContextCreated(_ record: RuntimeContext.Record)
    func runtimeExecutionContextDestroyed(_ key: RuntimeContext.Key)
    func runtimeExecutionContextsCleared(runtimeAgentTargetID: ProtocolTarget.ID)
}

@MainActor
package final class RuntimeProtocolEventDispatcher: ProtocolDomainEventDispatcher {
    private let handlers: [any RuntimeProtocolEventHandler]

    package init(handlers: [any RuntimeProtocolEventHandler]) {
        self.handlers = handlers
    }

    package var domain: ProtocolDomain { .runtime }

    package func dispatch(_ event: ProtocolEvent) async throws {
        guard event.domain == .runtime,
              let targetID = event.targetID else {
            return
        }
        switch event.method {
        case "Runtime.executionContextCreated":
            let params = try TransportMessageParser.decode(ExecutionContextCreatedParams.self, from: event.paramsData)
            let record = RuntimeContext.Record(
                id: params.context.id,
                targetID: targetID,
                runtimeAgentTargetID: event.sourceTargetID ?? targetID,
                type: params.context.type ?? .normal,
                name: params.context.name ?? "",
                frameID: params.context.frameID
            )
            for handler in handlers {
                handler.runtimeExecutionContextCreated(record)
            }
        case "Runtime.executionContextDestroyed":
            let params = try TransportMessageParser.decode(ExecutionContextDestroyedParams.self, from: event.paramsData)
            let key = RuntimeContext.Key(
                runtimeAgentTargetID: event.sourceTargetID ?? targetID,
                contextID: params.executionContextId
            )
            for handler in handlers {
                handler.runtimeExecutionContextDestroyed(key)
            }
        case "Runtime.executionContextsCleared":
            let runtimeAgentTargetID = event.sourceTargetID ?? targetID
            for handler in handlers {
                handler.runtimeExecutionContextsCleared(runtimeAgentTargetID: runtimeAgentTargetID)
            }
        default:
            return
        }
    }
}

extension RuntimeState: RuntimeProtocolEventHandler {
    package func runtimeExecutionContextCreated(_ record: RuntimeContext.Record) {
        applyExecutionContextCreated(record)
    }

    package func runtimeExecutionContextDestroyed(_ key: RuntimeContext.Key) {
        applyExecutionContextDestroyed(key)
    }

    package func runtimeExecutionContextsCleared(runtimeAgentTargetID: ProtocolTarget.ID) {
        applyExecutionContextsCleared(runtimeAgentTargetID: runtimeAgentTargetID)
    }
}

private struct ExecutionContextCreatedParams: Decodable {
    var context: RuntimeExecutionContext.Payload
}

private struct ExecutionContextDestroyedParams: Decodable {
    var executionContextId: RuntimeContext.ID
}
