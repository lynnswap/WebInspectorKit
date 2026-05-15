import Testing
@testable import WebInspectorCore
@testable import WebInspectorUI

@Test
@MainActor
func displayRequestsApplySearchFilterAndNewestFirstOrder() async throws {
    let network = NetworkSession()
    applyRequest(
        to: network,
        requestID: "1",
        url: "https://example.com/index.html",
        resourceType: .document,
        mimeType: "text/html",
        timestamp: 1
    )
    applyRequest(
        to: network,
        requestID: "2",
        url: "https://cdn.example.com/app.js",
        resourceType: .script,
        mimeType: "text/javascript",
        timestamp: 2
    )
    applyRequest(
        to: network,
        requestID: "3",
        url: "https://cdn.example.com/photo.png",
        resourceType: .image,
        mimeType: "image/png",
        timestamp: 3
    )

    let model = NetworkPanelModel(network: network)
    model.setSearchText("cdn")
    model.setResourceFilter(.script, enabled: true)

    let requests = model.displayRequests
    #expect(requests.map(\.id.requestID.rawValue) == ["2"])
}

@Test
@MainActor
func clearRequestsClearsSelectionButPreservesDisplayCriteria() async throws {
    let network = NetworkSession()
    let requestID = applyRequest(
        to: network,
        requestID: "1",
        url: "https://cdn.example.com/app.js",
        resourceType: .script,
        mimeType: "text/javascript",
        timestamp: 1
    )
    let model = NetworkPanelModel(network: network)

    model.setSearchText("cdn")
    model.setResourceFilter(.script, enabled: true)
    model.selectRequest(network.request(for: requestID))
    model.clearRequests()

    #expect(model.selectedRequestID == nil)
    #expect(model.searchText == "cdn")
    #expect(model.activeResourceFilters == [.script])
    #expect(model.displayRequests.isEmpty)
}

@MainActor
@discardableResult
private func applyRequest(
    to network: NetworkSession,
    requestID rawRequestID: String,
    url: String,
    resourceType: NetworkResourceType,
    mimeType: String,
    timestamp: Double
) -> NetworkRequest.ID {
    let targetID = ProtocolTargetIdentifier("page")
    let requestID = NetworkRequestIdentifier(rawRequestID)
    let key = network.applyRequestWillBeSent(
        targetID: targetID,
        requestID: requestID,
        frameID: DOMFrameIdentifier("main"),
        loaderID: "loader",
        documentURL: "https://example.com",
        request: NetworkRequestPayload(url: url),
        resourceType: resourceType,
        timestamp: timestamp
    )
    network.applyResponseReceived(
        targetID: targetID,
        requestID: requestID,
        resourceType: resourceType,
        response: NetworkResponsePayload(
            url: url,
            status: 200,
            statusText: "OK",
            mimeType: mimeType
        ),
        timestamp: timestamp + 0.1
    )
    network.applyLoadingFinished(
        targetID: targetID,
        requestID: requestID,
        timestamp: timestamp + 0.2
    )
    return key
}
