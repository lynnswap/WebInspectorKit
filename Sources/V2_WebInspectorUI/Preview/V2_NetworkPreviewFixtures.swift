#if DEBUG
import V2_WebInspectorCore

@MainActor
enum V2_NetworkPreviewFixtures {
    enum Mode {
        case root
        case rootLongTitle
    }

    static func makeListModel(mode: Mode) -> V2_NetworkListModel {
        let network = NetworkSession()
        applySampleData(to: network, mode: mode)
        return V2_NetworkListModel(network: network)
    }

    static func applySampleData(to network: NetworkSession, mode: Mode) {
        applyRequest(
            to: network,
            requestID: "1001",
            url: "https://play.google.com/log?format=json&hasfast=true",
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
            url: "https://www.gstatic.com/images/icons/material/system/2x/trending_up_grey600_24dp.png",
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

    private static func applyRequest(
        to network: NetworkSession,
        requestID: String,
        url: String,
        method: String = "GET",
        resourceType: NetworkResourceType,
        responseMimeType: String,
        status: Int,
        statusText: String,
        timestamp: Double,
        encodedBodyLength: Int
    ) {
        let targetID = ProtocolTargetIdentifier("preview-page")
        let requestID = NetworkRequestIdentifier(requestID)
        network.applyRequestWillBeSent(
            targetID: targetID,
            requestID: requestID,
            frameID: DOMFrameIdentifier("preview-frame"),
            loaderID: "preview-loader",
            documentURL: "https://example.com",
            request: NetworkRequestPayload(
                url: url,
                method: method,
                headers: method == "POST" ? ["content-type": "application/x-www-form-urlencoded"] : [:],
                postData: method == "POST" ? "hl=ja&gl=JP&source=wi-preview" : nil
            ),
            resourceType: resourceType,
            timestamp: timestamp,
            walltime: 1_700_000_000 + timestamp
        )
        network.applyResponseReceived(
            targetID: targetID,
            requestID: requestID,
            resourceType: resourceType,
            response: NetworkResponsePayload(
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
    }
}
#endif
