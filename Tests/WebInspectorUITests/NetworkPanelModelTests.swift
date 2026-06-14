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
    applyRequest(
        to: network,
        requestID: "17",
        url: "https://cdn.example.com/player.mp4",
        resourceType: .script,
        mimeType: "application/octet-stream",
        timestamp: 17
    )
    applyPendingRequest(
        to: network,
        requestID: "18",
        url: "https://api.example.com/pending-avatar.png",
        resourceType: .xhr,
        timestamp: 18
    )
    applyRequest(
        to: network,
        requestID: "19",
        url: "https://api.example.com/thumbnail",
        resourceType: .xhr,
        mimeType: nil,
        responseHeaders: ["Content-Type": "image/png; charset=utf-8"],
        timestamp: 19
    )

    let model = NetworkPanelModel(network: network)
    model.setResourceFilter(.media, enabled: true)

    #expect(model.displayRequests.map(\.id.requestID.rawValue) == ["19", "16", "9", "8", "7", "6", "5", "4", "3", "2", "1"])
}

@Test
func mediaPreviewSupportClassifiesAVIFAndExcludesSVG() {
    #expect(NetworkMediaPreviewSupport.previewKind(mimeType: "image/avif", url: nil) == .image)
    #expect(NetworkMediaPreviewSupport.previewKind(mimeType: nil, url: "https://cdn.example.com/photo.avif") == .image)
    #expect(NetworkMediaPreviewSupport.previewKind(mimeType: "image/apng", url: nil) == .image)
    #expect(NetworkMediaPreviewSupport.previewKind(mimeType: nil, url: "https://cdn.example.com/animated.apng") == .image)
    #expect(NetworkMediaPreviewSupport.previewKind(mimeType: "application/octet-stream", url: "https://cdn.example.com/animated.apng") == .image)
    #expect(NetworkMediaPreviewSupport.previewKind(mimeType: "image/x-png", url: nil) == .image)
    #expect(NetworkMediaPreviewSupport.previewKind(mimeType: "image/pjpeg", url: nil) == .image)
    #expect(NetworkMediaPreviewSupport.previewKind(mimeType: "image/x-unknown", url: "https://cdn.example.com/photo.png") == .image)
    #expect(NetworkMediaPreviewSupport.previewKind(mimeType: "image/svg+xml", url: "https://cdn.example.com/icon.svg") == nil)
    #expect(NetworkMediaPreviewSupport.classification(mimeType: "image/svg+xml", url: "https://cdn.example.com/icon.svg") == .notPreviewable)
    #expect(NetworkMediaPreviewSupport.previewKind(mimeType: "text/javascript", url: "https://cdn.example.com/player.mp4") == nil)
    #expect(NetworkMediaPreviewSupport.previewKind(mimeType: "text/css", url: "https://cdn.example.com/theme.png") == nil)
    #expect(NetworkMediaPreviewSupport.previewKind(mimeType: "application/octet-stream", url: "https://api.example.com/download") == nil)
    #expect(NetworkMediaPreviewSupport.temporaryFileExtension(
        mimeType: "video/mp4",
        url: "https://api.example.com/download.php"
    ) == "mp4")
    #expect(NetworkMediaPreviewSupport.temporaryFileExtension(
        mimeType: "application/vnd.apple.mpegurl",
        url: "https://api.example.com/download.php"
    ) == "m3u8")
    #expect(NetworkMediaPreviewSupport.temporaryFileExtension(
        mimeType: "application/octet-stream",
        url: "https://cdn.example.com/player.mp4"
    ) == "mp4")
}

@Test
@MainActor
func displayProjectionCacheInvalidatesWhenResponseMIMEBecomesPreviewable() async throws {
    let network = NetworkSession()
    let requestID = applyPendingRequest(
        to: network,
        requestID: "1",
        url: "https://api.example.com/avatar",
        resourceType: .xhr,
        timestamp: 1
    )
    let model = NetworkPanelModel(network: network)
    model.setResourceFilter(.media, enabled: true)

    #expect(model.displayRequestIDs.isEmpty)

    network.applyResponseReceived(
        targetID: requestID.targetID,
        requestID: requestID.requestID,
        resourceType: .xhr,
        response: NetworkResponsePayload(
            url: "https://api.example.com/avatar",
            status: 200,
            statusText: "OK",
            mimeType: "image/png"
        ),
        timestamp: 1.1
    )

    #expect(model.displayRequestIDs == [requestID])
    #expect(model.displayProjection(for: requestID)?.resourceFilter == .media)
}

@Test
@MainActor
func displayProjectionCacheInvalidatesStatusSeverity() async throws {
    let network = NetworkSession()
    let requestID = applyRequest(
        to: network,
        requestID: "1",
        url: "https://api.example.com/data.json",
        resourceType: .xhr,
        mimeType: "application/json",
        status: 500,
        statusText: "Server Error",
        timestamp: 1
    )
    let model = NetworkPanelModel(network: network)

    #expect(model.displayProjection(for: requestID)?.statusSeverity == .error)

    network.applyResponseReceived(
        targetID: requestID.targetID,
        requestID: requestID.requestID,
        resourceType: .xhr,
        response: NetworkResponsePayload(
            url: "https://api.example.com/data.json",
            status: 204,
            statusText: "No Content",
            mimeType: "application/json"
        ),
        timestamp: 2
    )

    #expect(model.displayProjection(for: requestID)?.statusSeverity == .success)
}

@Test
@MainActor
func displayProjectionCacheInvalidatesSearchFields() async throws {
    let network = NetworkSession()
    let targetID = ProtocolTarget.ID("page")
    let rawRequestID = NetworkRequestIdentifier("1")
    let requestID = network.applyRequestWillBeSent(
        targetID: targetID,
        requestID: rawRequestID,
        frameID: DOMFrame.ID("main"),
        loaderID: "loader",
        documentURL: "https://example.com",
        request: NetworkRequestPayload(url: "https://api.example.com/old", method: "POST"),
        resourceType: .xhr,
        timestamp: 1
    )
    let model = NetworkPanelModel(network: network)

    model.setSearchText("new-endpoint")
    #expect(model.displayRequestIDs.isEmpty)

    _ = network.applyRequestWillBeSent(
        targetID: targetID,
        requestID: rawRequestID,
        frameID: DOMFrame.ID("main"),
        loaderID: "loader",
        documentURL: "https://example.com",
        request: NetworkRequestPayload(url: "https://api.example.com/new-endpoint", method: "PATCH"),
        resourceType: .xhr,
        redirectResponse: NetworkResponsePayload(url: "https://api.example.com/old", status: 302),
        timestamp: 2
    )

    #expect(model.displayRequestIDs == [requestID])
    model.setSearchText("PATCH")
    #expect(model.displayRequestIDs == [requestID])

    model.setSearchText("json")
    #expect(model.displayRequestIDs.isEmpty)

    network.applyResponseReceived(
        targetID: targetID,
        requestID: rawRequestID,
        resourceType: .xhr,
        response: NetworkResponsePayload(
            url: "https://api.example.com/new-endpoint",
            status: 201,
            statusText: "Created",
            mimeType: "application/json"
        ),
        timestamp: 2.1
    )

    #expect(model.displayRequestIDs == [requestID])
    model.setSearchText("Created")
    #expect(model.displayRequestIDs == [requestID])
}

@Test
@MainActor
func displayProjectionCacheInvalidatesWhenRawMIMETypeAppears() async throws {
    let network = NetworkSession()
    let targetID = ProtocolTarget.ID("page")
    let rawRequestID = NetworkRequestIdentifier("1")
    let requestID = network.applyRequestWillBeSent(
        targetID: targetID,
        requestID: rawRequestID,
        frameID: DOMFrame.ID("main"),
        loaderID: "loader",
        documentURL: "https://example.com",
        request: NetworkRequestPayload(url: "https://api.example.com/resource", method: "GET"),
        resourceType: .xhr,
        timestamp: 1
    )
    network.applyResponseReceived(
        targetID: targetID,
        requestID: rawRequestID,
        resourceType: .xhr,
        response: NetworkResponsePayload(
            url: "https://api.example.com/resource",
            status: 200,
            statusText: "OK",
            headers: ["Content-Type": "application/json"],
            mimeType: nil
        ),
        timestamp: 1.1
    )
    let model = NetworkPanelModel(network: network)

    #expect(model.displayProjection(for: requestID)?.fileTypeLabel == "xhr")
    model.setSearchText("json")
    #expect(model.displayRequestIDs.isEmpty)

    network.applyResponseReceived(
        targetID: targetID,
        requestID: rawRequestID,
        resourceType: .xhr,
        response: NetworkResponsePayload(
            url: "https://api.example.com/resource",
            status: 200,
            statusText: "OK",
            headers: ["Content-Type": "application/json"],
            mimeType: "application/json"
        ),
        timestamp: 1.2
    )

    #expect(model.displayProjection(for: requestID)?.fileTypeLabel == "json")
    #expect(model.displayRequestIDs == [requestID])
}

@Test
@MainActor
func displayProjectionCacheReusesMediaClassificationForUnchangedRequests() async throws {
    let network = NetworkSession()
    let requestID = applyRequest(
        to: network,
        requestID: "1",
        url: "https://media.example.com/clip.mp4",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 1
    )
    var classificationCount = 0
    let model = NetworkPanelModel(
        network: network,
        mediaPreviewClassifier: { mimeType, url in
            classificationCount += 1
            return NetworkMediaPreviewSupport.classification(mimeType: mimeType, url: url)
        }
    )
    model.setResourceFilter(.media, enabled: true)

    #expect(model.displayRequestIDs == [requestID])
    #expect(classificationCount == 1)

    #expect(model.displayRequestIDs == [requestID])
    #expect(model.displayRequests.map(\.id) == [requestID])
    #expect(classificationCount == 1)

    network.applyDataReceived(
        targetID: requestID.targetID,
        requestID: requestID.requestID,
        dataLength: 1024,
        encodedDataLength: 512,
        timestamp: 2
    )

    #expect(model.displayRequestIDs == [requestID])
    #expect(classificationCount == 1)
}

@Test
@MainActor
func displayProjectionCacheSkipsMediaClassificationWhenUnfiltered() async throws {
    let network = NetworkSession()
    let requestID = applyRequest(
        to: network,
        requestID: "1",
        url: "https://media.example.com/clip.mp4",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 1
    )
    var classificationCount = 0
    let model = NetworkPanelModel(
        network: network,
        mediaPreviewClassifier: { mimeType, url in
            classificationCount += 1
            return NetworkMediaPreviewSupport.classification(mimeType: mimeType, url: url)
        }
    )

    #expect(model.displayRequestIDs == [requestID])
    #expect(model.displayProjection(for: requestID)?.displayName == "clip.mp4")
    #expect(classificationCount == 0)

    model.setSearchText("clip")
    #expect(model.displayRequestIDs == [requestID])
    #expect(classificationCount == 0)

    model.setResourceFilter(.media, enabled: true)
    #expect(model.displayRequestIDs == [requestID])
    #expect(classificationCount == 1)
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
    #expect(model.displayProjection(for: requestID) == nil)
}

@Test
@MainActor
func responseBodyFetchesAreDeduplicatedWhileInFlight() async throws {
    let network = NetworkSession()
    let requestID = applyRequest(
        to: network,
        requestID: "1",
        url: "https://api.example.com/data.json",
        resourceType: .xhr,
        mimeType: "application/json",
        timestamp: 1
    )
    let request = try #require(network.request(for: requestID))
    let probe = ResponseBodyFetchProbe()
    let model = NetworkPanelModel(network: network) { id in
        await probe.fetch(id)
    }

    #expect(request.canFetchResponseBody)

    model.fetchResponseBodyIfNeeded(for: request)
    await probe.waitForFetchCount(1)
    model.fetchResponseBodyIfNeeded(for: request)

    #expect(probe.fetchedIDs == [requestID])

    probe.finishCurrentFetch()
}

@MainActor
@discardableResult
private func applyRequest(
    to network: NetworkSession,
    requestID rawRequestID: String,
    url: String,
    resourceType: NetworkResourceType,
    mimeType: String?,
    responseHeaders: [String: String] = [:],
    status: Int = 200,
    statusText: String = "OK",
    timestamp: Double
) -> NetworkRequest.ID {
    let targetID = ProtocolTarget.ID("page")
    let requestID = NetworkRequestIdentifier(rawRequestID)
    let key = network.applyRequestWillBeSent(
        targetID: targetID,
        requestID: requestID,
        frameID: DOMFrame.ID("main"),
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
            status: status,
            statusText: statusText,
            headers: responseHeaders,
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

@MainActor
@discardableResult
private func applyPendingRequest(
    to network: NetworkSession,
    requestID rawRequestID: String,
    url: String,
    resourceType: NetworkResourceType,
    timestamp: Double
) -> NetworkRequest.ID {
    network.applyRequestWillBeSent(
        targetID: ProtocolTarget.ID("page"),
        requestID: NetworkRequestIdentifier(rawRequestID),
        frameID: DOMFrame.ID("main"),
        loaderID: "loader",
        documentURL: "https://example.com",
        request: NetworkRequestPayload(url: url),
        resourceType: resourceType,
        timestamp: timestamp
    )
}

@MainActor
private final class ResponseBodyFetchProbe {
    private struct Waiter {
        var count: Int
        var continuation: CheckedContinuation<Void, Never>
    }

    private(set) var fetchedIDs: [NetworkRequest.ID] = []
    private var waiters: [Waiter] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func fetch(_ id: NetworkRequest.ID) async {
        fetchedIDs.append(id)
        resumeSatisfiedWaiters()
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }

    func waitForFetchCount(_ count: Int) async {
        guard fetchedIDs.count < count else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(count: count, continuation: continuation))
        }
    }

    func finishCurrentFetch() {
        finishContinuation?.resume()
        finishContinuation = nil
    }

    private func resumeSatisfiedWaiters() {
        var remaining: [Waiter] = []
        for waiter in waiters {
            if fetchedIDs.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}
