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

package extension RequestWillBeSentParams.Request {
    init(dictionary: [String: Any]) throws {
        guard let url = transportString(from: dictionary["url"]),
              let method = transportString(from: dictionary["method"]) else {
            throw WITransportError.invalidResponse("Invalid Network.requestWillBeSent.request payload.")
        }

        self.init(
            url: url,
            method: method,
            headers: transportStringDictionary(from: dictionary["headers"]) ?? [:],
            postData: transportString(from: dictionary["postData"])
        )
    }
}

extension RequestWillBeSentParams: WITransportObjectDecodable {
    package init(wiTransportObject: Any) throws {
        guard let dictionary = transportDictionary(from: wiTransportObject),
              let requestId = transportString(from: dictionary["requestId"]),
              let timestamp = transportDouble(from: dictionary["timestamp"]),
              let requestDictionary = transportDictionary(from: dictionary["request"]) else {
            throw WITransportError.invalidResponse("Invalid Network.requestWillBeSent payload.")
        }

        self.init(
            requestId: requestId,
            frameId: transportString(from: dictionary["frameId"]),
            timestamp: timestamp,
            walltime: transportDouble(from: dictionary["walltime"]),
            type: transportString(from: dictionary["type"]),
            request: try .init(dictionary: requestDictionary),
            redirectResponse: try transportDictionary(from: dictionary["redirectResponse"]).map(ResponsePayload.init(dictionary:))
        )
    }
}

package struct ResponseReceivedParams: Decodable {
    package let requestId: String
    package let frameId: String?
    package let timestamp: Double
    package let type: String
    package let response: ResponsePayload
}

extension ResponseReceivedParams: WITransportObjectDecodable {
    package init(wiTransportObject: Any) throws {
        guard let dictionary = transportDictionary(from: wiTransportObject),
              let requestId = transportString(from: dictionary["requestId"]),
              let timestamp = transportDouble(from: dictionary["timestamp"]),
              let type = transportString(from: dictionary["type"]),
              let responseDictionary = transportDictionary(from: dictionary["response"]) else {
            throw WITransportError.invalidResponse("Invalid Network.responseReceived payload.")
        }

        self.init(
            requestId: requestId,
            frameId: transportString(from: dictionary["frameId"]),
            timestamp: timestamp,
            type: type,
            response: try .init(dictionary: responseDictionary)
        )
    }
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

package extension LoadingFinishedParams.Metrics {
    init(dictionary: [String: Any]) {
        self.init(
            requestBodyBytesSent: transportInt(from: dictionary["requestBodyBytesSent"]),
            responseBodyBytesReceived: transportInt(from: dictionary["responseBodyBytesReceived"]),
            responseBodyDecodedSize: transportInt(from: dictionary["responseBodyDecodedSize"])
        )
    }
}

extension LoadingFinishedParams: WITransportObjectDecodable {
    package init(wiTransportObject: Any) throws {
        guard let dictionary = transportDictionary(from: wiTransportObject),
              let requestId = transportString(from: dictionary["requestId"]),
              let timestamp = transportDouble(from: dictionary["timestamp"]) else {
            throw WITransportError.invalidResponse("Invalid Network.loadingFinished payload.")
        }

        self.init(
            requestId: requestId,
            timestamp: timestamp,
            metrics: transportDictionary(from: dictionary["metrics"]).map(LoadingFinishedParams.Metrics.init(dictionary:))
        )
    }
}

package struct LoadingFailedParams: Decodable {
    package let requestId: String
    package let timestamp: Double
    package let errorText: String
    package let canceled: Bool?
}

extension LoadingFailedParams: WITransportObjectDecodable {
    package init(wiTransportObject: Any) throws {
        guard let dictionary = transportDictionary(from: wiTransportObject),
              let requestId = transportString(from: dictionary["requestId"]),
              let timestamp = transportDouble(from: dictionary["timestamp"]),
              let errorText = transportString(from: dictionary["errorText"]) else {
            throw WITransportError.invalidResponse("Invalid Network.loadingFailed payload.")
        }

        self.init(
            requestId: requestId,
            timestamp: timestamp,
            errorText: errorText,
            canceled: transportBool(from: dictionary["canceled"])
        )
    }
}

package struct ResponsePayload: Decodable {
    package let url: String?
    package let status: Int
    package let statusText: String
    package let headers: [String: String]
    package let mimeType: String
    package let requestHeaders: [String: String]?
}

package extension ResponsePayload {
    init(dictionary: [String: Any]) throws {
        guard let status = transportInt(from: dictionary["status"]),
              let statusText = transportString(from: dictionary["statusText"]),
              let mimeType = transportString(from: dictionary["mimeType"]) else {
            throw WITransportError.invalidResponse("Invalid network response payload.")
        }

        self.init(
            url: transportString(from: dictionary["url"]),
            status: status,
            statusText: statusText,
            headers: transportStringDictionary(from: dictionary["headers"]) ?? [:],
            mimeType: mimeType,
            requestHeaders: transportStringDictionary(from: dictionary["requestHeaders"])
        )
    }
}

package struct WebSocketCreatedParams: Decodable {
    package let requestId: String
    package let url: String
    package let timestamp: Double?
}

extension WebSocketCreatedParams: WITransportObjectDecodable {
    package init(wiTransportObject: Any) throws {
        guard let dictionary = transportDictionary(from: wiTransportObject),
              let requestId = transportString(from: dictionary["requestId"]),
              let url = transportString(from: dictionary["url"]) else {
            throw WITransportError.invalidResponse("Invalid Network.webSocketCreated payload.")
        }

        self.init(
            requestId: requestId,
            url: url,
            timestamp: transportDouble(from: dictionary["timestamp"])
        )
    }
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

package extension WebSocketHandshakeRequestParams.Request {
    init(dictionary: [String: Any]) {
        self.init(headers: transportStringDictionary(from: dictionary["headers"]) ?? [:])
    }
}

extension WebSocketHandshakeRequestParams: WITransportObjectDecodable {
    package init(wiTransportObject: Any) throws {
        guard let dictionary = transportDictionary(from: wiTransportObject),
              let requestId = transportString(from: dictionary["requestId"]),
              let timestamp = transportDouble(from: dictionary["timestamp"]),
              let requestDictionary = transportDictionary(from: dictionary["request"]) else {
            throw WITransportError.invalidResponse("Invalid Network.webSocketWillSendHandshakeRequest payload.")
        }

        self.init(
            requestId: requestId,
            timestamp: timestamp,
            walltime: transportDouble(from: dictionary["walltime"]),
            request: .init(dictionary: requestDictionary)
        )
    }
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

package extension WebSocketHandshakeResponseReceivedParams.Response {
    init(dictionary: [String: Any]) throws {
        guard let status = transportInt(from: dictionary["status"]),
              let statusText = transportString(from: dictionary["statusText"]) else {
            throw WITransportError.invalidResponse("Invalid websocket handshake response payload.")
        }

        self.init(
            status: status,
            statusText: statusText,
            headers: transportStringDictionary(from: dictionary["headers"]) ?? [:]
        )
    }
}

extension WebSocketHandshakeResponseReceivedParams: WITransportObjectDecodable {
    package init(wiTransportObject: Any) throws {
        guard let dictionary = transportDictionary(from: wiTransportObject),
              let requestId = transportString(from: dictionary["requestId"]),
              let timestamp = transportDouble(from: dictionary["timestamp"]),
              let responseDictionary = transportDictionary(from: dictionary["response"]) else {
            throw WITransportError.invalidResponse("Invalid Network.webSocketHandshakeResponseReceived payload.")
        }

        self.init(
            requestId: requestId,
            timestamp: timestamp,
            response: try .init(dictionary: responseDictionary)
        )
    }
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

package extension WebSocketFrameParams.Frame {
    init(dictionary: [String: Any]) throws {
        guard let opcode = transportInt(from: dictionary["opcode"]),
              let mask = transportBool(from: dictionary["mask"]),
              let payloadData = transportString(from: dictionary["payloadData"]),
              let payloadLength = transportInt(from: dictionary["payloadLength"]) else {
            throw WITransportError.invalidResponse("Invalid websocket frame payload.")
        }

        self.init(
            opcode: opcode,
            mask: mask,
            payloadData: payloadData,
            payloadLength: payloadLength
        )
    }
}

extension WebSocketFrameParams: WITransportObjectDecodable {
    package init(wiTransportObject: Any) throws {
        guard let dictionary = transportDictionary(from: wiTransportObject),
              let requestId = transportString(from: dictionary["requestId"]),
              let timestamp = transportDouble(from: dictionary["timestamp"]),
              let responseDictionary = transportDictionary(from: dictionary["response"]) else {
            throw WITransportError.invalidResponse("Invalid websocket frame event payload.")
        }

        self.init(
            requestId: requestId,
            timestamp: timestamp,
            response: try .init(dictionary: responseDictionary)
        )
    }
}

package struct WebSocketFrameErrorParams: Decodable {
    package let requestId: String
    package let timestamp: Double
    package let errorMessage: String
}

extension WebSocketFrameErrorParams: WITransportObjectDecodable {
    package init(wiTransportObject: Any) throws {
        guard let dictionary = transportDictionary(from: wiTransportObject),
              let requestId = transportString(from: dictionary["requestId"]),
              let timestamp = transportDouble(from: dictionary["timestamp"]),
              let errorMessage = transportString(from: dictionary["errorMessage"]) else {
            throw WITransportError.invalidResponse("Invalid websocket frame error payload.")
        }

        self.init(requestId: requestId, timestamp: timestamp, errorMessage: errorMessage)
    }
}

package struct WebSocketClosedParams: Decodable {
    package let requestId: String
    package let timestamp: Double
}

extension WebSocketClosedParams: WITransportObjectDecodable {
    package init(wiTransportObject: Any) throws {
        guard let dictionary = transportDictionary(from: wiTransportObject),
              let requestId = transportString(from: dictionary["requestId"]),
              let timestamp = transportDouble(from: dictionary["timestamp"]) else {
            throw WITransportError.invalidResponse("Invalid websocket closed payload.")
        }

        self.init(requestId: requestId, timestamp: timestamp)
    }
}

package enum NetworkPendingEvent {
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
