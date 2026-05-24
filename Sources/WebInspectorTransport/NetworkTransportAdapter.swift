import Foundation
import WebInspectorCore

package enum NetworkTransportAdapter {
    package static func command(for intent: NetworkCommandIntent) throws -> ProtocolCommand {
        switch intent {
        case let .getResponseBody(requestKey, backendResourceIdentifier):
            return ProtocolCommand(
                domain: .network,
                method: "Network.getResponseBody",
                routing: .target(requestKey.targetID),
                parametersData: try parameters(
                    requestKey: requestKey,
                    backendResourceIdentifier: backendResourceIdentifier
                )
            )
        case let .getSerializedCertificate(requestKey, backendResourceIdentifier):
            return ProtocolCommand(
                domain: .network,
                method: "Network.getSerializedCertificate",
                routing: .target(requestKey.targetID),
                parametersData: try parameters(
                    requestKey: requestKey,
                    backendResourceIdentifier: backendResourceIdentifier
                )
            )
        }
    }

    @MainActor
    package static func applyResponseBodyResult(_ result: ProtocolCommandResult, to request: NetworkRequest) throws {
        let payload = try TransportMessageParser.decode(ResponseBodyResult.self, from: result.resultData)
        request.applyResponseBody(
            NetworkBodyPayload(
                body: payload.body,
                base64Encoded: payload.base64Encoded
            )
        )
    }

    @MainActor
    package static func applyNetworkEvent(_ event: ProtocolEventEnvelope, to session: NetworkSession) throws {
        guard event.domain == .network,
              let targetID = event.targetID else {
            return
        }

        switch event.method {
        case "Network.requestWillBeSent":
            let params = try TransportMessageParser.decode(RequestWillBeSentParams.self, from: event.paramsData)
            let existingRequestURL = session.requestSnapshot(
                for: .init(targetID: targetID, requestID: params.requestId)
            )?.request.url
            _ = session.applyRequestWillBeSent(
                targetID: targetID,
                requestID: params.requestId,
                frameID: params.frameId,
                loaderID: params.loaderId,
                documentURL: params.documentURL,
                request: params.request.payload,
                resourceType: params.type.map { NetworkResourceType($0) },
                originatingTargetID: params.targetId,
                backendResourceIdentifier: params.backendResourceIdentifier,
                initiator: params.initiator?.payload,
                redirectResponse: params.redirectResponse?.payload(fallbackURL: existingRequestURL ?? params.request.url),
                timestamp: params.timestamp,
                walltime: params.walltime
            )
        case "Network.responseReceived":
            let params = try TransportMessageParser.decode(ResponseReceivedParams.self, from: event.paramsData)
            session.applyResponseReceived(
                targetID: targetID,
                requestID: params.requestId,
                frameID: params.frameId,
                loaderID: params.loaderId,
                resourceType: params.type.map { NetworkResourceType($0) },
                response: params.response.payload(
                    fallbackURL: session.requestSnapshot(
                        for: .init(targetID: targetID, requestID: params.requestId)
                    )?.request.url ?? ""
                ),
                timestamp: params.timestamp
            )
        case "Network.dataReceived":
            let params = try TransportMessageParser.decode(DataReceivedParams.self, from: event.paramsData)
            session.applyDataReceived(
                targetID: targetID,
                requestID: params.requestId,
                dataLength: params.dataLength,
                encodedDataLength: params.encodedDataLength,
                timestamp: params.timestamp
            )
        case "Network.loadingFinished":
            let params = try TransportMessageParser.decode(LoadingFinishedParams.self, from: event.paramsData)
            session.applyLoadingFinished(
                targetID: targetID,
                requestID: params.requestId,
                timestamp: params.timestamp,
                sourceMapURL: params.sourceMapURL,
                metrics: params.metrics?.payload
            )
        case "Network.loadingFailed":
            let params = try TransportMessageParser.decode(LoadingFailedParams.self, from: event.paramsData)
            session.applyLoadingFailed(
                targetID: targetID,
                requestID: params.requestId,
                timestamp: params.timestamp,
                errorText: params.errorText,
                canceled: params.canceled ?? false
            )
        case "Network.webSocketCreated":
            let params = try TransportMessageParser.decode(WebSocketCreatedParams.self, from: event.paramsData)
            _ = session.applyWebSocketCreated(targetID: targetID, requestID: params.requestId, url: params.url)
        case "Network.webSocketWillSendHandshakeRequest":
            let params = try TransportMessageParser.decode(WebSocketWillSendHandshakeRequestParams.self, from: event.paramsData)
            session.applyWebSocketWillSendHandshakeRequest(
                targetID: targetID,
                requestID: params.requestId,
                timestamp: params.timestamp,
                walltime: params.walltime ?? 0,
                request: params.request.payload
            )
        case "Network.webSocketHandshakeResponseReceived":
            let params = try TransportMessageParser.decode(WebSocketHandshakeResponseReceivedParams.self, from: event.paramsData)
            session.applyWebSocketHandshakeResponseReceived(
                targetID: targetID,
                requestID: params.requestId,
                timestamp: params.timestamp,
                response: params.response.payload
            )
        case "Network.webSocketFrameReceived":
            let params = try TransportMessageParser.decode(WebSocketFrameParams.self, from: event.paramsData)
            session.applyWebSocketFrameReceived(
                targetID: targetID,
                requestID: params.requestId,
                timestamp: params.timestamp,
                response: params.response.payload
            )
        case "Network.webSocketFrameSent":
            let params = try TransportMessageParser.decode(WebSocketFrameParams.self, from: event.paramsData)
            session.applyWebSocketFrameSent(
                targetID: targetID,
                requestID: params.requestId,
                timestamp: params.timestamp,
                response: params.response.payload
            )
        case "Network.webSocketFrameError":
            let params = try TransportMessageParser.decode(WebSocketFrameErrorParams.self, from: event.paramsData)
            session.applyWebSocketFrameError(
                targetID: targetID,
                requestID: params.requestId,
                timestamp: params.timestamp,
                errorMessage: params.errorMessage
            )
        case "Network.webSocketClosed":
            let params = try TransportMessageParser.decode(WebSocketClosedParams.self, from: event.paramsData)
            session.applyWebSocketClosed(targetID: targetID, requestID: params.requestId, timestamp: params.timestamp)
        case "Network.requestServedFromMemoryCache":
            let params = try TransportMessageParser.decode(RequestServedFromMemoryCacheParams.self, from: event.paramsData)
            _ = session.applyRequestServedFromMemoryCache(
                targetID: targetID,
                requestID: params.requestId,
                frameID: params.frameId,
                loaderID: params.loaderId,
                documentURL: params.documentURL,
                timestamp: params.timestamp,
                initiator: params.initiator?.payload,
                resource: params.resource.payload
            )
        default:
            break
        }
    }

    private static func parameters(
        requestKey: NetworkRequestIdentifierKey,
        backendResourceIdentifier: NetworkBackendResourceIdentifier?
    ) throws -> Data {
        var object: [String: Any] = [
            "requestId": requestKey.requestID.rawValue,
        ]
        if let backendResourceIdentifier {
            object["backendResourceIdentifier"] = [
                "sourceProcessID": backendResourceIdentifier.sourceProcessID,
                "resourceID": backendResourceIdentifier.resourceID,
            ]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }

}

private struct ResponseBodyResult: Decodable {
    var body: String
    var base64Encoded: Bool
}

private struct RequestWillBeSentParams: Decodable {
    var requestId: NetworkRequestIdentifier
    var frameId: DOMFrameIdentifier?
    var loaderId: String?
    var documentURL: String?
    var request: RequestPayload
    var type: String?
    var targetId: ProtocolTargetIdentifier?
    var backendResourceIdentifier: NetworkBackendResourceIdentifier?
    var initiator: InitiatorPayload?
    var redirectResponse: ResponsePayload?
    var timestamp: Double
    var walltime: Double?
}

private struct ResponseReceivedParams: Decodable {
    var requestId: NetworkRequestIdentifier
    var frameId: DOMFrameIdentifier?
    var loaderId: String?
    var type: String?
    var response: ResponsePayload
    var timestamp: Double
}

private struct DataReceivedParams: Decodable {
    var requestId: NetworkRequestIdentifier
    var dataLength: Int
    var encodedDataLength: Int
    var timestamp: Double
}

private struct LoadingFinishedParams: Decodable {
    var requestId: NetworkRequestIdentifier
    var timestamp: Double
    var sourceMapURL: String?
    var metrics: MetricsPayload?
}

private struct LoadingFailedParams: Decodable {
    var requestId: NetworkRequestIdentifier
    var timestamp: Double
    var errorText: String
    var canceled: Bool?
}

private struct WebSocketCreatedParams: Decodable {
    var requestId: NetworkRequestIdentifier
    var url: String
}

private struct WebSocketWillSendHandshakeRequestParams: Decodable {
    var requestId: NetworkRequestIdentifier
    var timestamp: Double
    var walltime: Double?
    var request: WebSocketRequestPayload
}

private struct WebSocketHandshakeResponseReceivedParams: Decodable {
    var requestId: NetworkRequestIdentifier
    var timestamp: Double
    var response: WebSocketResponsePayload
}

private struct WebSocketFrameParams: Decodable {
    var requestId: NetworkRequestIdentifier
    var timestamp: Double
    var response: WebSocketFramePayload
}

private struct WebSocketFrameErrorParams: Decodable {
    var requestId: NetworkRequestIdentifier
    var timestamp: Double
    var errorMessage: String
}

private struct WebSocketClosedParams: Decodable {
    var requestId: NetworkRequestIdentifier
    var timestamp: Double
}

private struct RequestServedFromMemoryCacheParams: Decodable {
    var requestId: NetworkRequestIdentifier
    var frameId: DOMFrameIdentifier
    var loaderId: String
    var documentURL: String
    var timestamp: Double
    var initiator: InitiatorPayload?
    var resource: CachedResourcePayload
}

private struct RequestPayload: Decodable {
    var url: String
    var method: String?
    var headers: [String: String]?
    var postData: String?
    var referrerPolicy: String?
    var integrity: String?

    var payload: NetworkRequestPayload {
        NetworkRequestPayload(
            url: url,
            method: method ?? "GET",
            headers: headers ?? [:],
            postData: postData,
            referrerPolicy: referrerPolicy.map { NetworkReferrerPolicy($0) },
            integrity: integrity
        )
    }
}

private struct InitiatorPayload: Decodable {
    var type: String
    var stackTrace: StackTracePayload?
    var url: String?
    var lineNumber: Double?
    var nodeId: DOMProtocolNodeID?

    var payload: NetworkInitiatorPayload {
        NetworkInitiatorPayload(
            type: NetworkInitiatorType(type),
            stackTrace: stackTrace?.payload,
            url: url,
            lineNumber: lineNumber,
            nodeID: nodeId
        )
    }
}

private final class StackTracePayload: Decodable {
    var callFrames: [CallFramePayload]
    var topCallFrameIsBoundary: Bool?
    var truncated: Bool?
    var parentStackTrace: StackTracePayload?

    var payload: ConsoleStackTracePayload {
        ConsoleStackTracePayload(
            callFrames: callFrames.map(\.payload),
            topCallFrameIsBoundary: topCallFrameIsBoundary,
            truncated: truncated,
            parentStackTraces: parentStackTrace.map { [$0.payload] } ?? []
        )
    }
}

private struct CallFramePayload: Decodable {
    var functionName: String
    var url: String
    var scriptId: String
    var lineNumber: Int
    var columnNumber: Int

    var payload: ConsoleCallFramePayload {
        ConsoleCallFramePayload(
            functionName: functionName,
            url: url,
            scriptID: scriptId,
            lineNumber: lineNumber,
            columnNumber: columnNumber
        )
    }
}

private struct ResponsePayload: Decodable {
    var url: String?
    var status: Int
    var statusText: String?
    var headers: [String: String]?
    var mimeType: String?
    var source: String?
    var requestHeaders: [String: String]?
    var timing: ResourceTimingPayload?
    var security: SecurityPayload?

    func payload(fallbackURL: String) -> NetworkResponsePayload {
        NetworkResponsePayload(
            url: url ?? fallbackURL,
            status: status,
            statusText: statusText ?? "",
            headers: headers ?? [:],
            mimeType: mimeType,
            source: source.map { NetworkResponseSource($0) },
            requestHeaders: requestHeaders,
            timing: timing?.payload,
            security: security?.payload
        )
    }
}

private struct ResourceTimingPayload: Decodable {
    var startTime: Double
    var redirectStart: Double
    var redirectEnd: Double
    var fetchStart: Double
    var domainLookupStart: Double
    var domainLookupEnd: Double
    var connectStart: Double
    var connectEnd: Double
    var secureConnectionStart: Double
    var requestStart: Double
    var responseStart: Double
    var responseEnd: Double

    var payload: NetworkResourceTimingPayload {
        NetworkResourceTimingPayload(
            startTime: startTime,
            redirectStart: redirectStart,
            redirectEnd: redirectEnd,
            fetchStart: fetchStart,
            domainLookupStart: domainLookupStart,
            domainLookupEnd: domainLookupEnd,
            connectStart: connectStart,
            connectEnd: connectEnd,
            secureConnectionStart: secureConnectionStart,
            requestStart: requestStart,
            responseStart: responseStart,
            responseEnd: responseEnd
        )
    }
}

private struct SecurityPayload: Decodable {
    var connection: SecurityConnectionPayload?
    var certificate: CertificatePayload?

    var payload: NetworkSecurityPayload {
        NetworkSecurityPayload(
            connection: connection?.payload,
            certificate: certificate?.payload
        )
    }
}

private struct CertificatePayload: Decodable {
    var subject: String?
    var validFrom: Double?
    var validUntil: Double?
    var dnsNames: [String]?
    var ipAddresses: [String]?

    var payload: NetworkCertificatePayload {
        NetworkCertificatePayload(
            subject: subject,
            validFrom: validFrom,
            validUntil: validUntil,
            dnsNames: dnsNames ?? [],
            ipAddresses: ipAddresses ?? []
        )
    }
}

private struct MetricsPayload: Decodable {
    var networkProtocol: String?
    var priority: String?
    var connectionIdentifier: String?
    var remoteAddress: String?
    var requestHeaders: [String: String]?
    var requestHeaderBytesSent: Int?
    var requestBodyBytesSent: Int?
    var responseHeaderBytesReceived: Int?
    var responseBodyBytesReceived: Int?
    var responseBodyDecodedSize: Int?
    var securityConnection: SecurityConnectionPayload?
    var isProxyConnection: Bool?

    enum CodingKeys: String, CodingKey {
        case networkProtocol = "protocol"
        case priority
        case connectionIdentifier
        case remoteAddress
        case requestHeaders
        case requestHeaderBytesSent
        case requestBodyBytesSent
        case responseHeaderBytesReceived
        case responseBodyBytesReceived
        case responseBodyDecodedSize
        case securityConnection
        case isProxyConnection
    }

    var payload: NetworkLoadMetricsPayload {
        NetworkLoadMetricsPayload(
            networkProtocol: networkProtocol,
            priority: priority.map { NetworkPriority($0) },
            connectionIdentifier: connectionIdentifier,
            remoteAddress: remoteAddress,
            requestHeaders: requestHeaders,
            requestHeaderBytesSent: requestHeaderBytesSent,
            requestBodyBytesSent: requestBodyBytesSent,
            responseHeaderBytesReceived: responseHeaderBytesReceived,
            responseBodyBytesReceived: responseBodyBytesReceived,
            responseBodyDecodedSize: responseBodyDecodedSize,
            securityConnection: securityConnection?.payload,
            isProxyConnection: isProxyConnection
        )
    }
}

private struct SecurityConnectionPayload: Decodable {
    var protocolName: String?
    var cipher: String?

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case cipher
    }

    var payload: NetworkSecurityConnectionPayload {
        NetworkSecurityConnectionPayload(protocolName: protocolName, cipher: cipher)
    }
}

private struct CachedResourcePayload: Decodable {
    var url: String
    var type: String
    var response: ResponsePayload?
    var bodySize: Int
    var sourceMapURL: String?

    var payload: NetworkCachedResourcePayload {
        NetworkCachedResourcePayload(
            url: url,
            type: NetworkResourceType(type),
            response: response?.payload(fallbackURL: url),
            bodySize: bodySize,
            sourceMapURL: sourceMapURL
        )
    }
}

private struct WebSocketRequestPayload: Decodable {
    var headers: [String: String]?

    var payload: NetworkWebSocketRequestPayload {
        NetworkWebSocketRequestPayload(headers: headers ?? [:])
    }
}

private struct WebSocketResponsePayload: Decodable {
    var status: Int
    var statusText: String?
    var headers: [String: String]?

    var payload: NetworkWebSocketResponsePayload {
        NetworkWebSocketResponsePayload(
            status: status,
            statusText: statusText ?? "",
            headers: headers ?? [:]
        )
    }
}

private struct WebSocketFramePayload: Decodable {
    var opcode: Int
    var mask: Bool
    var payloadData: String
    var payloadLength: Int

    var payload: NetworkWebSocketFramePayload {
        NetworkWebSocketFramePayload(
            opcode: opcode,
            mask: mask,
            payloadData: payloadData,
            payloadLength: payloadLength
        )
    }
}
