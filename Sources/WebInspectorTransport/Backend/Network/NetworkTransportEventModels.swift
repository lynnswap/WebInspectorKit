import Foundation

package struct RequestWillBeSentParams: Decodable {
    package struct Request: Decodable {
        package let url: String
        package let method: String
        package let headers: [String: String]
        package let postData: String?
    }

    package let requestId: String
    package let frameId: String?
    package let timestamp: Double
    package let walltime: Double?
    package let type: String?
    package let request: Request
    package let redirectResponse: ResponsePayload?
}

package struct ResponseReceivedParams: Decodable {
    package let requestId: String
    package let frameId: String?
    package let timestamp: Double
    package let type: String
    package let response: ResponsePayload
}

package struct LoadingFinishedParams: Decodable {
    package struct Metrics: Decodable {
        package let requestBodyBytesSent: Int?
        package let responseBodyBytesReceived: Int?
        package let responseBodyDecodedSize: Int?
    }

    package let requestId: String
    package let timestamp: Double
    package let metrics: Metrics?
}

package struct LoadingFailedParams: Decodable {
    package let requestId: String
    package let timestamp: Double
    package let errorText: String
    package let canceled: Bool?
}

package struct TargetDidCommitProvisionalTargetParams: Decodable {
    package let oldTargetId: String?
    package let newTargetId: String
}

package struct TargetCreatedParams: Decodable {
    package struct TargetInfo: Decodable {
        package let targetId: String
        package let type: String
        package let isProvisional: Bool?
    }

    package let targetInfo: TargetInfo
}

package struct TargetDestroyedParams: Decodable {
    package let targetId: String
}

package struct ResponsePayload: Decodable {
    package let url: String?
    package let status: Int
    package let statusText: String
    package let headers: [String: String]
    package let mimeType: String
    package let requestHeaders: [String: String]?
}

package struct WebSocketCreatedParams: Decodable {
    package let requestId: String
    package let url: String
    package let timestamp: Double?
}

package struct WebSocketHandshakeRequestParams: Decodable {
    package struct Request: Decodable {
        package let headers: [String: String]
    }

    package let requestId: String
    package let timestamp: Double
    package let walltime: Double?
    package let request: Request
}

package struct WebSocketHandshakeResponseReceivedParams: Decodable {
    package struct Response: Decodable {
        package let status: Int
        package let statusText: String
        package let headers: [String: String]
    }

    package let requestId: String
    package let timestamp: Double
    package let response: Response
}

package struct WebSocketFrameParams: Decodable {
    package struct Frame: Decodable {
        package let opcode: Int
        package let mask: Bool
        package let payloadData: String
        package let payloadLength: Int
    }

    package let requestId: String
    package let timestamp: Double
    package let response: Frame
}

package struct WebSocketFrameErrorParams: Decodable {
    package let requestId: String
    package let timestamp: Double
    package let errorMessage: String
}

package struct WebSocketClosedParams: Decodable {
    package let requestId: String
    package let timestamp: Double
}

package enum NetworkPendingEvent {
    case targetCreated(TargetCreatedParams, String?)
    case targetDidCommitProvisionalTarget(TargetDidCommitProvisionalTargetParams, String?)
    case targetDestroyed(TargetDestroyedParams, String?)
    case requestWillBeSent(RequestWillBeSentParams, String?)
    case responseReceived(ResponseReceivedParams, String?)
    case loadingFinished(LoadingFinishedParams, String?)
    case loadingFailed(LoadingFailedParams, String?)
    case webSocketCreated(WebSocketCreatedParams, String?)
    case webSocketHandshakeRequest(WebSocketHandshakeRequestParams, String?)
    case webSocketHandshakeResponseReceived(WebSocketHandshakeResponseReceivedParams, String?)
    case webSocketFrameReceived(WebSocketFrameParams, String?)
    case webSocketFrameSent(WebSocketFrameParams, String?)
    case webSocketFrameError(WebSocketFrameErrorParams, String?)
    case webSocketClosed(WebSocketClosedParams, String?)
}
