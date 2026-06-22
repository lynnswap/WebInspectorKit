import WebInspectorUIBase
import WebInspectorCore
import WebInspectorTransport

@MainActor
package enum NetworkPreviewFixtures {
    package enum Mode {
        case root
        case rootLongTitle
        case detail
        case detailResponseOnlyShort
        case detailRequestAndResponseShort
        case detailResponseOnlyLong
        case detailRequestAndResponseLong
    }

    package static func makePanelModel(mode: Mode) -> NetworkPanelModel {
        let network = makeNetworkSession(mode: mode)
        let model = NetworkPanelModel(network: network)
        switch mode {
        case .detail,
             .detailResponseOnlyShort,
             .detailRequestAndResponseShort,
             .detailResponseOnlyLong,
             .detailRequestAndResponseLong:
            model.selectRequest(model.displayRequests.first)
        case .root, .rootLongTitle:
            break
        }
        return model
    }

    package static func makeNetworkSession(mode: Mode) -> NetworkSession {
        let network = NetworkSession()
        applySampleData(to: network, mode: mode)
        return network
    }

    package static func applySampleData(to network: NetworkSession, mode: Mode) {
        switch mode {
        case .detailResponseOnlyShort:
            applyRequest(
                to: network,
                requestID: "1001",
                url: "https://api.example.com/v1/status.json",
                method: "GET",
                resourceType: .xhr,
                responseMimeType: "application/json",
                status: 200,
                statusText: "OK",
                timestamp: 1.0,
                encodedBodyLength: 64,
                responseBody: shortPreviewJSONBody(kind: "response-only")
            )
            return
        case .detailRequestAndResponseShort:
            applyRequest(
                to: network,
                requestID: "1001",
                url: "https://telemetry.example/log.json",
                method: "POST",
                resourceType: .xhr,
                responseMimeType: "application/json",
                status: 200,
                statusText: "OK",
                timestamp: 1.0,
                encodedBodyLength: 64,
                requestHeaders: ["content-type": "application/json"],
                postData: shortPreviewJSONBody(kind: "request"),
                responseBody: shortPreviewJSONBody(kind: "response")
            )
            return
        case .detailResponseOnlyLong:
            applyRequest(
                to: network,
                requestID: "1001",
                url: "https://api.example.com/v1/status.json",
                method: "GET",
                resourceType: .xhr,
                responseMimeType: "application/json",
                status: 200,
                statusText: "OK",
                timestamp: 1.0,
                encodedBodyLength: 1_024,
                responseBody: longPreviewJSONBody(kind: "response-only")
            )
            return
        case .detailRequestAndResponseLong:
            applyRequest(
                to: network,
                requestID: "1001",
                url: "https://telemetry.example/log.json",
                method: "POST",
                resourceType: .xhr,
                responseMimeType: "application/json",
                status: 200,
                statusText: "OK",
                timestamp: 1.0,
                encodedBodyLength: 1_024,
                requestHeaders: ["content-type": "application/json"],
                postData: longPreviewJSONBody(kind: "request"),
                responseBody: longPreviewJSONBody(kind: "response")
            )
            return
        case .root, .rootLongTitle, .detail:
            break
        }

        applyRequest(
            to: network,
            requestID: "1001",
            url: "https://telemetry.example/log",
            method: "POST",
            resourceType: .xhr,
            responseMimeType: "application/json",
            status: 200,
            statusText: "OK",
            timestamp: 1.0,
            encodedBodyLength: 64
        )
        applyRequest(
            to: network,
            requestID: "1002",
            url: "https://static.example/images/icons/trending-up.png",
            resourceType: .image,
            responseMimeType: "image/png",
            status: 200,
            statusText: "OK",
            timestamp: 0.9,
            encodedBodyLength: 0
        )

        if mode == .rootLongTitle {
            applyRequest(
                to: network,
                requestID: "1999",
                url: "https://cdn.example.com/assets/network/preview/super-long-file-name-for-line-wrap-validation-with-json-tag-rendering-and-truncation-check.json",
                resourceType: .xhr,
                responseMimeType: "application/json",
                status: 200,
                statusText: "OK",
                timestamp: 1.9,
                encodedBodyLength: 512
            )
        }
    }

    @discardableResult
    private static func applyRequest(
        to network: NetworkSession,
        requestID: String,
        url: String,
        method: String = "GET",
        resourceType: NetworkRequest.ResourceType,
        responseMimeType: String,
        status: Int,
        statusText: String,
        timestamp: Double,
        encodedBodyLength: Int,
        requestHeaders: [String: String]? = nil,
        postData: String? = nil,
        responseBody: String? = nil
    ) -> NetworkRequest.ID {
        let targetID = ProtocolTarget.ID("preview-page")
        let requestID = NetworkRequest.ProtocolID(requestID)
        let resolvedPostData = postData ?? (method == "POST" ? "sample=true&source=wi-preview" : nil)
        let resolvedRequestHeaders = requestHeaders
            ?? (resolvedPostData == nil ? [:] : ["content-type": "application/x-www-form-urlencoded"])
        let key = network.applyRequestWillBeSent(
            targetID: targetID,
            requestID: requestID,
            frameID: DOMFrame.ID("preview-frame"),
            loaderID: "preview-loader",
            documentURL: "https://example.com",
            request: NetworkRequest.Payload(
                url: url,
                method: method,
                headers: resolvedRequestHeaders,
                postData: resolvedPostData
            ),
            resourceType: resourceType,
            timestamp: timestamp,
            walltime: 1_700_000_000 + timestamp
        )
        network.applyResponseReceived(
            targetID: targetID,
            requestID: requestID,
            resourceType: resourceType,
            response: NetworkRequest.Response.Payload(
                url: url,
                status: status,
                statusText: statusText,
                headers: [
                    "content-length": String(encodedBodyLength),
                    "content-type": responseMimeType,
                ],
                mimeType: responseMimeType
            ),
            timestamp: timestamp + 0.1
        )
        network.applyDataReceived(
            targetID: targetID,
            requestID: requestID,
            dataLength: encodedBodyLength,
            encodedDataLength: encodedBodyLength,
            timestamp: timestamp + 0.11
        )
        network.applyLoadingFinished(
            targetID: targetID,
            requestID: requestID,
            timestamp: timestamp + 0.2
        )
        if responseMimeType == "application/json" {
            network.request(for: key)?.applyResponseBody(
                NetworkBody.Payload(
                    body: responseBody ?? #"{"result":"ok","items":[1,2,3],"source":"preview"}"#,
                    base64Encoded: false
                )
            )
        }
        return key
    }

    private static func shortPreviewJSONBody(kind: String) -> String {
        #"{"kind":"\#(kind)","result":"ok","source":"preview"}"#
    }

    private static func longPreviewJSONBody(kind: String) -> String {
        let items = (1...24).map { index in
            let enabled = index.isMultiple(of: 2) ? "true" : "false"
            return #"{"id":\#(index),"name":"\#(kind)-item-\#(index)","enabled":\#(enabled)}"#
        }.joined(separator: ",")
        return #"{"kind":"\#(kind)","result":"ok","items":[\#(items)],"metadata":{"source":"preview","count":24}}"#
    }
}
