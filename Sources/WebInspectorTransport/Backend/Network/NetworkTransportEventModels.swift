import Foundation

package enum NetworkWire {}

package extension NetworkWire {
    enum Transport {}
}

package extension NetworkWire.Transport {
    enum Event {
        struct RequestWillBeSent: Decodable {
            struct Request: Decodable {
                let url: String
                let method: String
                let headers: [String: String]
                let postData: String?
            }

            let requestId: String
            let frameId: String?
            let timestamp: Double
            let walltime: Double?
            let type: String?
            let request: Request
            let redirectResponse: ResponsePayload?
        }

        struct ResponseReceived: Decodable {
            let requestId: String
            let frameId: String?
            let timestamp: Double
            let type: String
            let response: ResponsePayload
        }

        struct LoadingFinished: Decodable {
            struct Metrics: Decodable {
                let requestBodyBytesSent: Int?
                let responseBodyBytesReceived: Int?
                let responseBodyDecodedSize: Int?
            }

            let requestId: String
            let timestamp: Double
            let metrics: Metrics?
        }

        struct LoadingFailed: Decodable {
            let requestId: String
            let timestamp: Double
            let errorText: String
            let canceled: Bool?
        }

        struct TargetDestroyed: Decodable {
            let targetId: String
        }

        struct TargetDidCommitProvisionalTarget: Decodable {
            let oldTargetId: String?
            let newTargetId: String
        }

        struct ResponsePayload: Decodable {
            let url: String?
            let status: Int
            let statusText: String
            let headers: [String: String]
            let mimeType: String
            let requestHeaders: [String: String]?
        }

        struct WebSocketCreated: Decodable {
            let requestId: String
            let url: String
            let timestamp: Double?
        }

        struct WebSocketHandshakeRequest: Decodable {
            struct Request: Decodable {
                let headers: [String: String]
            }

            let requestId: String
            let timestamp: Double
            let walltime: Double?
            let request: Request
        }

        struct WebSocketHandshakeResponseReceived: Decodable {
            struct Response: Decodable {
                let status: Int
                let statusText: String
                let headers: [String: String]
            }

            let requestId: String
            let timestamp: Double
            let response: Response
        }

        struct WebSocketFrame: Decodable {
            struct Frame: Decodable {
                let opcode: Int
                let mask: Bool
                let payloadData: String
                let payloadLength: Int
            }

            let requestId: String
            let timestamp: Double
            let response: Frame
        }

        struct WebSocketFrameError: Decodable {
            let requestId: String
            let timestamp: Double
            let errorMessage: String
        }

        struct WebSocketClosed: Decodable {
            let requestId: String
            let timestamp: Double
        }
    }
}
