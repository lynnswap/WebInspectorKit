import Foundation
import WebInspectorCore

package enum RuntimeTransportAdapter {
    package static func command(for intent: RuntimeCommandIntent) throws -> ProtocolCommand {
        switch intent {
        case let .enable(targetID):
            return ProtocolCommand(domain: .runtime, method: "Runtime.enable", routing: .target(targetID))
        case let .evaluate(request):
            return ProtocolCommand(
                domain: .runtime,
                method: "Runtime.evaluate",
                routing: .target(request.targetID),
                parametersData: try data(evaluationParameters(request))
            )
        case let .getPreview(object):
            return ProtocolCommand(
                domain: .runtime,
                method: "Runtime.getPreview",
                routing: .target(object.targetID),
                parametersData: try data(["objectId": object.objectID.rawValue])
            )
        case let .getProperties(object, ownProperties, fetchStart, fetchCount, generatePreview):
            return ProtocolCommand(
                domain: .runtime,
                method: "Runtime.getProperties",
                routing: .target(object.targetID),
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
                routing: .target(object.targetID),
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
                routing: .target(object.targetID),
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
                routing: .target(object.targetID),
                parametersData: try data(["objectId": object.objectID.rawValue])
            )
        case let .releaseObjectGroup(targetID, objectGroup):
            return ProtocolCommand(
                domain: .runtime,
                method: "Runtime.releaseObjectGroup",
                routing: .target(targetID),
                parametersData: try data(["objectGroup": objectGroup.rawValue])
            )
        }
    }

    package static func evaluationResult(from result: ProtocolCommandResult) throws -> RuntimeEvaluationResultPayload {
        try TransportMessageParser.decode(RuntimeEvaluationResultPayload.self, from: result.resultData)
    }

    package static func previewResult(from result: ProtocolCommandResult) throws -> RuntimePreviewResultPayload {
        try TransportMessageParser.decode(RuntimePreviewResultPayload.self, from: result.resultData)
    }

    package static func propertiesResult(from result: ProtocolCommandResult) throws -> RuntimePropertiesResultPayload {
        try TransportMessageParser.decode(RuntimePropertiesResultPayload.self, from: result.resultData)
    }

    package static func collectionEntriesResult(from result: ProtocolCommandResult) throws -> RuntimeCollectionEntriesResultPayload {
        try TransportMessageParser.decode(RuntimeCollectionEntriesResultPayload.self, from: result.resultData)
    }

    package static func saveResult(from result: ProtocolCommandResult) throws -> RuntimeSaveResultPayload {
        try TransportMessageParser.decode(RuntimeSaveResultPayload.self, from: result.resultData)
    }

    @MainActor
    package static func applyRuntimeEvent(_ event: ProtocolEventEnvelope, to session: RuntimeSession) throws {
        guard event.domain == .runtime else {
            return
        }
        switch event.method {
        case "Runtime.executionContextCreated":
            guard let targetID = event.targetID else {
                return
            }
            let params = try TransportMessageParser.decode(ExecutionContextCreatedParams.self, from: event.paramsData)
            session.applyExecutionContextCreated(params.context, targetID: targetID)
        case "Runtime.executionContextDestroyed":
            let params = try TransportMessageParser.decode(ExecutionContextDestroyedParams.self, from: event.paramsData)
            session.applyExecutionContextDestroyed(params.executionContextId)
        case "Runtime.executionContextsCleared":
            guard let targetID = event.targetID else {
                return
            }
            session.applyExecutionContextsCleared(targetID: targetID)
        default:
            return
        }
    }

    private static func evaluationParameters(_ request: RuntimeEvaluationRequest) -> [String: Any] {
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

    private static func objectParameters(
        _ object: RuntimeRemoteObjectIdentifierKey,
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

    private static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }
}

private struct ExecutionContextCreatedParams: Decodable {
    var context: RuntimeExecutionContextPayload
}

private struct ExecutionContextDestroyedParams: Decodable {
    var executionContextId: ExecutionContextID
}
