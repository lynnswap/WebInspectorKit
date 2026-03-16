import Foundation

@MainActor
package struct NetworkEventTranslator {
    package init() {}

    package func translate(_ envelope: WITransportEventEnvelope) -> NetworkPendingEvent? {
        switch envelope.method {
        case "Network.requestWillBeSent":
            guard let params = try? envelope.decodeParams(RequestWillBeSentParams.self) else {
                return nil
            }
            return .requestWillBeSent(params, envelope.targetIdentifier)
        case "Network.responseReceived":
            guard let params = try? envelope.decodeParams(ResponseReceivedParams.self) else {
                return nil
            }
            return .responseReceived(params, envelope.targetIdentifier)
        case "Network.loadingFinished":
            guard let params = try? envelope.decodeParams(LoadingFinishedParams.self) else {
                return nil
            }
            return .loadingFinished(params, envelope.targetIdentifier)
        case "Network.loadingFailed":
            guard let params = try? envelope.decodeParams(LoadingFailedParams.self) else {
                return nil
            }
            return .loadingFailed(params, envelope.targetIdentifier)
        case "Network.webSocketCreated":
            guard let params = try? envelope.decodeParams(WebSocketCreatedParams.self) else {
                return nil
            }
            return .webSocketCreated(params, envelope.targetIdentifier)
        case "Network.webSocketWillSendHandshakeRequest":
            guard let params = try? envelope.decodeParams(WebSocketHandshakeRequestParams.self) else {
                return nil
            }
            return .webSocketHandshakeRequest(params, envelope.targetIdentifier)
        case "Network.webSocketHandshakeResponseReceived":
            guard let params = try? envelope.decodeParams(WebSocketHandshakeResponseReceivedParams.self) else {
                return nil
            }
            return .webSocketHandshakeResponseReceived(params, envelope.targetIdentifier)
        case "Network.webSocketFrameReceived":
            guard let params = try? envelope.decodeParams(WebSocketFrameParams.self) else {
                return nil
            }
            return .webSocketFrameReceived(params, envelope.targetIdentifier)
        case "Network.webSocketFrameSent":
            guard let params = try? envelope.decodeParams(WebSocketFrameParams.self) else {
                return nil
            }
            return .webSocketFrameSent(params, envelope.targetIdentifier)
        case "Network.webSocketFrameError":
            guard let params = try? envelope.decodeParams(WebSocketFrameErrorParams.self) else {
                return nil
            }
            return .webSocketFrameError(params, envelope.targetIdentifier)
        case "Network.webSocketClosed":
            guard let params = try? envelope.decodeParams(WebSocketClosedParams.self) else {
                return nil
            }
            return .webSocketClosed(params, envelope.targetIdentifier)
        default:
            return nil
        }
    }
}
