import Testing
import WebInspectorTransport
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
func mediaFilterIncludesPreviewableMediaResponses() async throws {
    let network = NetworkSession()
    applyRequest(
        to: network,
        requestID: "1",
        url: "https://cdn.example.com/photo.png",
        resourceType: .image,
        mimeType: "image/png",
        timestamp: 1
    )
    applyRequest(
        to: network,
        requestID: "2",
        url: "https://cdn.example.com/movie.mp4",
        resourceType: .media,
        mimeType: "video/mp4",
        timestamp: 2
    )
    applyRequest(
        to: network,
        requestID: "3",
        url: "https://api.example.com/avatar",
        resourceType: .xhr,
        mimeType: "image/avif",
        timestamp: 3
    )
    applyRequest(
        to: network,
        requestID: "4",
        url: "https://api.example.com/avatar.avif",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 4
    )
    applyRequest(
        to: network,
        requestID: "5",
        url: "https://media.example.com/live/master.m3u8",
        resourceType: .xhr,
        mimeType: "application/vnd.apple.mpegurl",
        timestamp: 5
    )
    applyRequest(
        to: network,
        requestID: "6",
        url: "https://media.example.com/clip.mp4",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 6
    )
    applyRequest(
        to: network,
        requestID: "7",
        url: "https://media.example.com/song.mp3",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 7
    )
    applyRequest(
        to: network,
        requestID: "8",
        url: "https://cdn.example.com/animated.apng",
        resourceType: .xhr,
        mimeType: "image/apng",
        timestamp: 8
    )
    applyRequest(
        to: network,
        requestID: "9",
        url: "https://cdn.example.com/icon.svg",
        resourceType: .image,
        mimeType: "image/svg+xml",
        timestamp: 9
    )
    applyRequest(
        to: network,
        requestID: "10",
        url: "https://cdn.example.com/font.woff2",
        resourceType: .font,
        mimeType: "font/woff2",
        timestamp: 10
    )
    applyRequest(
        to: network,
        requestID: "11",
        url: "https://api.example.com/data.json",
        resourceType: .xhr,
        mimeType: "application/json",
        timestamp: 11
    )
    applyRequest(
        to: network,
        requestID: "12",
        url: "https://cdn.example.com/app.js",
        resourceType: .script,
        mimeType: "text/javascript",
        timestamp: 12
    )
    applyRequest(
        to: network,
        requestID: "13",
        url: "https://cdn.example.com/player.mp4",
        resourceType: .script,
        mimeType: "text/javascript",
        timestamp: 13
    )
    applyRequest(
        to: network,
        requestID: "14",
        url: "https://cdn.example.com/theme.png",
        resourceType: .styleSheet,
        mimeType: "text/css",
        timestamp: 14
    )
    applyRequest(
        to: network,
        requestID: "15",
        url: "https://api.example.com/download",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 15
    )
    applyRequest(
        to: network,
        requestID: "16",
        url: "https://cdn.example.com/animated.apng",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 16
    )

    let model = NetworkPanelModel(network: network)
    model.setResourceFilter(.media, enabled: true)

    #expect(model.displayRequests.map(\.id.requestID.rawValue) == ["16", "8", "7", "6", "5", "4", "3", "2", "1"])
}

@Test
func mediaPreviewSupportClassifiesAVIFAndExcludesSVG() {
    #expect(NetworkMediaPreviewSupport.previewKind(mimeType: "image/avif", url: nil) == .image)
    #expect(NetworkMediaPreviewSupport.previewKind(mimeType: nil, url: "https://cdn.example.com/photo.avif") == .image)
    #expect(NetworkMediaPreviewSupport.previewKind(mimeType: "image/apng", url: nil) == .image)
    #expect(NetworkMediaPreviewSupport.previewKind(mimeType: nil, url: "https://cdn.example.com/animated.apng") == .image)
    #expect(NetworkMediaPreviewSupport.previewKind(mimeType: "application/octet-stream", url: "https://cdn.example.com/animated.apng") == .image)
    #expect(NetworkMediaPreviewSupport.previewKind(mimeType: "image/svg+xml", url: "https://cdn.example.com/icon.svg") == nil)
    #expect(NetworkMediaPreviewSupport.classification(mimeType: "image/svg+xml", url: "https://cdn.example.com/icon.svg") == .notPreviewable)
    #expect(NetworkMediaPreviewSupport.previewKind(mimeType: "text/javascript", url: "https://cdn.example.com/player.mp4") == nil)
    #expect(NetworkMediaPreviewSupport.previewKind(mimeType: "text/css", url: "https://cdn.example.com/theme.png") == nil)
    #expect(NetworkMediaPreviewSupport.previewKind(mimeType: "application/octet-stream", url: "https://api.example.com/download") == nil)
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
