import Foundation

@MainActor
package struct NetworkEventTranslator {
    package init() {}

    package func translate(_ envelope: WITransportEventEnvelope) -> NetworkPendingEvent? {
        switch envelope.method {
        case "Target.targetCreated":
            guard let params = try? JSONDecoder().decode(TargetCreatedParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .targetCreated(params, envelope.targetIdentifier)
        case "Target.didCommitProvisionalTarget":
            guard let params = try? JSONDecoder().decode(TargetDidCommitProvisionalTargetParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .targetDidCommitProvisionalTarget(params, envelope.targetIdentifier)
        case "Target.targetDestroyed":
            guard let params = try? JSONDecoder().decode(TargetDestroyedParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .targetDestroyed(params, envelope.targetIdentifier)
        case "Network.requestWillBeSent":
            guard let params = try? JSONDecoder().decode(RequestWillBeSentParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .requestWillBeSent(params, envelope.targetIdentifier)
        case "Network.responseReceived":
            guard let params = try? JSONDecoder().decode(ResponseReceivedParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .responseReceived(params, envelope.targetIdentifier)
        case "Network.loadingFinished":
            guard let params = try? JSONDecoder().decode(LoadingFinishedParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .loadingFinished(params, envelope.targetIdentifier)
        case "Network.loadingFailed":
            guard let params = try? JSONDecoder().decode(LoadingFailedParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .loadingFailed(params, envelope.targetIdentifier)
        case "Network.webSocketCreated":
            guard let params = try? JSONDecoder().decode(WebSocketCreatedParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .webSocketCreated(params, envelope.targetIdentifier)
        case "Network.webSocketWillSendHandshakeRequest":
            guard let params = try? JSONDecoder().decode(WebSocketHandshakeRequestParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .webSocketHandshakeRequest(params, envelope.targetIdentifier)
        case "Network.webSocketHandshakeResponseReceived":
            guard let params = try? JSONDecoder().decode(WebSocketHandshakeResponseReceivedParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .webSocketHandshakeResponseReceived(params, envelope.targetIdentifier)
        case "Network.webSocketFrameReceived":
            guard let params = try? JSONDecoder().decode(WebSocketFrameParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .webSocketFrameReceived(params, envelope.targetIdentifier)
        case "Network.webSocketFrameSent":
            guard let params = try? JSONDecoder().decode(WebSocketFrameParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .webSocketFrameSent(params, envelope.targetIdentifier)
        case "Network.webSocketFrameError":
            guard let params = try? JSONDecoder().decode(WebSocketFrameErrorParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .webSocketFrameError(params, envelope.targetIdentifier)
        case "Network.webSocketClosed":
            guard let params = try? JSONDecoder().decode(WebSocketClosedParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .webSocketClosed(params, envelope.targetIdentifier)
        default:
            return nil
        }
    }
}
