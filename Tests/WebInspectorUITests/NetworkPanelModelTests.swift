import Testing
import WebInspectorDataKit
import WebInspectorProxyKit
@testable import WebInspectorUI
@testable import WebInspectorUIBase
@testable import WebInspectorUIDOM
@testable import WebInspectorUINetwork

@Suite
struct NetworkPanelModelTests {

@Test
@MainActor
func displayRequestsApplySearchFilterAndNewestFirstOrder() async throws {
    let context = makeContext()
    applyRequest(
        to: context,
        requestID: "1",
        url: "https://example.com/index.html",
        resourceType: .document,
        mimeType: "text/html",
        timestamp: 1
    )
    let scriptID = applyRequest(
        to: context,
        requestID: "2",
        url: "https://cdn.example.com/app.js",
        resourceType: .script,
        mimeType: "text/javascript",
        timestamp: 2
    )
    applyRequest(
        to: context,
        requestID: "3",
        url: "https://cdn.example.com/photo.png",
        resourceType: .image,
        mimeType: "image/png",
        timestamp: 3
    )

    let model = NetworkPanelModel(context: context)
    model.setSearchText("cdn")
    model.setResourceFilter(.script, enabled: true)

    #expect(model.displayRequests.map(\.id) == [scriptID])
}

@Test(
    "Network display names use URL path segments with authority fallback",
    arguments: [
        ("https://www.google.com/", "www.google.com"),
        ("https://www.google.com", "www.google.com"),
        ("https://example.com/foo/", "foo"),
        ("https://example.com/a%20b", "a b"),
        ("https://example.com/a%2Fb", "a/b"),
        ("https://example.com/画像.png", "画像.png"),
        ("https://cdn.example.com/photo 1.png", "photo 1.png"),
        ("https://cdn.example.com/photo%ZZ.png", "photo%ZZ.png"),
        ("https://example.com:8443/", "example.com:8443"),
        ("about:blank", "blank"),
        ("data:text/plain,hello", "data:text/plain,hello"),
    ]
)
@MainActor
func requestDisplayUsesReadableURLDisplayName(url: String, expectedDisplayName: String) async throws {
    let context = makeContext()
    let requestID = applyRequest(
        to: context,
        requestID: "1",
        url: url,
        resourceType: .document,
        mimeType: "text/html",
        timestamp: 1
    )
    let request = try #require(context.registeredRequest(for: requestID))

    #expect(request.displayName == expectedDisplayName)
}

@Test
@MainActor
func requestDisplayUsesEncodingFallbackForURLDerivedLabelsAndFilters() async throws {
    let context = makeContext()
    let spacedURLRequestID = applyRequest(
        to: context,
        requestID: "1",
        url: "https://cdn.example.com/photo 1.png",
        resourceType: .fetch,
        mimeType: nil,
        timestamp: 1
    )
    let invalidEscapeRequestID = applyRequest(
        to: context,
        requestID: "2",
        url: "https://cdn.example.com/photo%ZZ.png",
        resourceType: .fetch,
        mimeType: nil,
        timestamp: 2
    )
    let model = NetworkPanelModel(context: context)
    let spacedURLRequest = try #require(context.registeredRequest(for: spacedURLRequestID))
    let invalidEscapeRequest = try #require(context.registeredRequest(for: invalidEscapeRequestID))

    #expect(spacedURLRequest.displayName == "photo 1.png")
    #expect(spacedURLRequest.fileTypeLabel == "png")
    #expect(invalidEscapeRequest.displayName == "photo%ZZ.png")
    #expect(invalidEscapeRequest.fileTypeLabel == "png")

    model.setResourceFilter(.media, enabled: true)
    #expect(model.displayRequestIDs == [invalidEscapeRequestID, spacedURLRequestID])
}

@Test
@MainActor
func mediaFilterIncludesPreviewableMediaResponses() async throws {
    let context = makeContext()
    let imageID = applyRequest(
        to: context,
        requestID: "1",
        url: "https://cdn.example.com/photo.png",
        resourceType: .image,
        mimeType: "image/png",
        timestamp: 1
    )
    let movieID = applyRequest(
        to: context,
        requestID: "2",
        url: "https://cdn.example.com/movie.mp4",
        resourceType: .media,
        mimeType: "video/mp4",
        timestamp: 2
    )
    let avifResponseID = applyRequest(
        to: context,
        requestID: "3",
        url: "https://api.example.com/avatar",
        resourceType: .xhr,
        mimeType: "image/avif",
        timestamp: 3
    )
    let avifURLID = applyRequest(
        to: context,
        requestID: "4",
        url: "https://api.example.com/avatar.avif",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 4
    )
    let hlsID = applyRequest(
        to: context,
        requestID: "5",
        url: "https://media.example.com/live/master.m3u8",
        resourceType: .xhr,
        mimeType: "application/vnd.apple.mpegurl",
        timestamp: 5
    )
    let mp4URLID = applyRequest(
        to: context,
        requestID: "6",
        url: "https://media.example.com/clip.mp4",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 6
    )
    let mp3URLID = applyRequest(
        to: context,
        requestID: "7",
        url: "https://media.example.com/song.mp3",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 7
    )
    let apngResponseID = applyRequest(
        to: context,
        requestID: "8",
        url: "https://cdn.example.com/animated.apng",
        resourceType: .xhr,
        mimeType: "image/apng",
        timestamp: 8
    )
    let svgID = applyRequest(
        to: context,
        requestID: "9",
        url: "https://cdn.example.com/icon.svg",
        resourceType: .image,
        mimeType: "image/svg+xml",
        timestamp: 9
    )
    applyRequest(
        to: context,
        requestID: "10",
        url: "https://cdn.example.com/font.woff2",
        resourceType: .font,
        mimeType: "font/woff2",
        timestamp: 10
    )
    applyRequest(
        to: context,
        requestID: "11",
        url: "https://api.example.com/data.json",
        resourceType: .xhr,
        mimeType: "application/json",
        timestamp: 11
    )
    applyRequest(
        to: context,
        requestID: "12",
        url: "https://cdn.example.com/app.js",
        resourceType: .script,
        mimeType: "text/javascript",
        timestamp: 12
    )
    applyRequest(
        to: context,
        requestID: "13",
        url: "https://cdn.example.com/player.mp4",
        resourceType: .script,
        mimeType: "text/javascript",
        timestamp: 13
    )
    applyRequest(
        to: context,
        requestID: "14",
        url: "https://cdn.example.com/theme.png",
        resourceType: .stylesheet,
        mimeType: "text/css",
        timestamp: 14
    )
    applyRequest(
        to: context,
        requestID: "15",
        url: "https://api.example.com/download",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 15
    )
    let apngURLID = applyRequest(
        to: context,
        requestID: "16",
        url: "https://cdn.example.com/animated.apng",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 16
    )
    applyRequest(
        to: context,
        requestID: "17",
        url: "https://cdn.example.com/player.mp4",
        resourceType: .script,
        mimeType: "application/octet-stream",
        timestamp: 17
    )
    applyPendingRequest(
        to: context,
        requestID: "18",
        url: "https://api.example.com/pending-avatar.png",
        resourceType: .xhr,
        timestamp: 18
    )
    let headerMediaID = applyRequest(
        to: context,
        requestID: "19",
        url: "https://api.example.com/thumbnail",
        resourceType: .xhr,
        mimeType: nil,
        responseHeaders: ["Content-Type": "image/png; charset=utf-8"],
        timestamp: 19
    )

    let model = NetworkPanelModel(context: context)
    model.setResourceFilter(.media, enabled: true)

    #expect(model.displayRequests.map(\.id) == [
        headerMediaID,
        apngURLID,
        svgID,
        apngResponseID,
        mp3URLID,
        mp4URLID,
        hlsID,
        avifURLID,
        avifResponseID,
        movieID,
        imageID,
    ])
}

@Test
func mediaPreviewSupportClassifiesAVIFAndExcludesSVG() {
    #expect(NetworkDisplay.MediaPreviewSupport.previewKind(mimeType: "image/avif", url: nil) == .image)
    #expect(NetworkDisplay.MediaPreviewSupport.previewKind(mimeType: nil, url: "https://cdn.example.com/photo.avif") == .image)
    #expect(NetworkDisplay.MediaPreviewSupport.previewKind(mimeType: "image/apng", url: nil) == .image)
    #expect(NetworkDisplay.MediaPreviewSupport.previewKind(mimeType: nil, url: "https://cdn.example.com/animated.apng") == .image)
    #expect(NetworkDisplay.MediaPreviewSupport.previewKind(mimeType: "application/octet-stream", url: "https://cdn.example.com/animated.apng") == .image)
    #expect(NetworkDisplay.MediaPreviewSupport.previewKind(mimeType: "image/x-png", url: nil) == .image)
    #expect(NetworkDisplay.MediaPreviewSupport.previewKind(mimeType: "image/pjpeg", url: nil) == .image)
    #expect(NetworkDisplay.MediaPreviewSupport.previewKind(mimeType: "image/x-unknown", url: "https://cdn.example.com/photo.png") == .image)
    #expect(NetworkDisplay.MediaPreviewSupport.previewKind(mimeType: nil, url: "https://cdn.example.com/画像.png") == .image)
    #expect(NetworkDisplay.MediaPreviewSupport.previewKind(mimeType: "image/svg+xml", url: "https://cdn.example.com/icon.svg") == nil)
    #expect(NetworkDisplay.MediaPreviewSupport.classification(mimeType: "image/svg+xml", url: "https://cdn.example.com/icon.svg") == .notPreviewable)
    #expect(NetworkDisplay.MediaPreviewSupport.previewKind(mimeType: "text/javascript", url: "https://cdn.example.com/player.mp4") == nil)
    #expect(NetworkDisplay.MediaPreviewSupport.previewKind(mimeType: "text/css", url: "https://cdn.example.com/theme.png") == nil)
    #expect(NetworkDisplay.MediaPreviewSupport.previewKind(mimeType: "application/octet-stream", url: "https://api.example.com/download") == nil)
    #expect(NetworkDisplay.MediaPreviewSupport.temporaryFileExtension(
        mimeType: "video/mp4",
        url: "https://api.example.com/download.php"
    ) == "mp4")
    #expect(NetworkDisplay.MediaPreviewSupport.temporaryFileExtension(
        mimeType: "application/vnd.apple.mpegurl",
        url: "https://api.example.com/download.php"
    ) == "m3u8")
    #expect(NetworkDisplay.MediaPreviewSupport.temporaryFileExtension(
        mimeType: "application/octet-stream",
        url: "https://cdn.example.com/player.mp4"
    ) == "mp4")
}

@Test
func mediaPreviewSupportClassifiesHLSPlaylists() {
    #expect(NetworkDisplay.MediaPreviewSupport.previewKind(
        mimeType: "application/vnd.apple.mpegurl",
        url: nil
    ) == .hlsPlaylist)
    #expect(NetworkDisplay.MediaPreviewSupport.previewKind(
        mimeType: "application/x-mpegurl; charset=utf-8",
        url: nil
    ) == .hlsPlaylist)
    #expect(NetworkDisplay.MediaPreviewSupport.previewKind(
        mimeType: "audio/mpegurl",
        url: nil
    ) == .hlsPlaylist)
    #expect(NetworkDisplay.MediaPreviewSupport.previewKind(
        mimeType: nil,
        url: "https://media.example.com/live/master.m3u8?token=abc"
    ) == .hlsPlaylist)
    #expect(NetworkDisplay.MediaPreviewSupport.previewKind(
        mimeType: "application/octet-stream",
        url: "https://media.example.com/live/master.m3u8"
    ) == .hlsPlaylist)
}

@Test
@MainActor
func displayResourceFilterUpdatesWhenResponseMIMEBecomesPreviewable() async throws {
    let context = makeContext()
    let requestID = applyPendingRequest(
        to: context,
        requestID: "1",
        url: "https://api.example.com/avatar",
        resourceType: .xhr,
        timestamp: 1
    )
    let model = NetworkPanelModel(context: context)
    model.setResourceFilter(.media, enabled: true)

    #expect(model.displayRequestIDs.isEmpty)

    applyResponseReceived(
        to: context,
        requestID: "1",
        url: "https://api.example.com/avatar",
        resourceType: .xhr,
        mimeType: "image/png",
        timestamp: 1.1
    )
    #expect(model.displayRequestIDs == [requestID])
    let request = try #require(context.registeredRequest(for: requestID))
    #expect(request.displayResourceFilter(mediaPreviewClassifier: { mimeType, url in
        NetworkDisplay.MediaPreviewSupport.classification(mimeType: mimeType, url: url)
    }) == .media)
}

@Test
@MainActor
func requestStatusSeverityUpdatesWhenResponseChanges() async throws {
    let context = makeContext()
    let requestID = applyRequest(
        to: context,
        requestID: "1",
        url: "https://api.example.com/data.json",
        resourceType: .xhr,
        mimeType: "application/json",
        status: 500,
        statusText: "Server Error",
        timestamp: 1
    )
    let request = try #require(context.registeredRequest(for: requestID))

    #expect(request.statusSeverity == .error)

    applyResponseReceived(
        to: context,
        requestID: "1",
        url: "https://api.example.com/data.json",
        resourceType: .xhr,
        mimeType: "application/json",
        status: 204,
        statusText: "No Content",
        timestamp: 2
    )
    #expect(request.statusSeverity == .success)
}

@Test
@MainActor
func displaySearchFieldsUpdateWhenRequestChanges() async throws {
    let context = makeContext()
    let requestID = applyPendingRequest(
        to: context,
        requestID: "1",
        url: "https://api.example.com/old",
        method: "POST",
        resourceType: .xhr,
        timestamp: 1
    )
    let model = NetworkPanelModel(context: context)

    model.setSearchText("new-endpoint")
    #expect(model.displayRequestIDs.isEmpty)

    applyRedirectRequest(
        to: context,
        requestID: "1",
        url: "https://api.example.com/new-endpoint",
        method: "PATCH",
        resourceType: .xhr,
        redirectURL: "https://api.example.com/old",
        timestamp: 2
    )
    #expect(model.displayRequestIDs == [requestID])
    model.setSearchText("PATCH")
    #expect(model.displayRequestIDs == [requestID])

    model.setSearchText("json")
    #expect(model.displayRequestIDs.isEmpty)

    applyResponseReceived(
        to: context,
        requestID: "1",
        url: "https://api.example.com/new-endpoint",
        resourceType: .xhr,
        mimeType: "application/json",
        status: 201,
        statusText: "Created",
        timestamp: 2.1
    )
    #expect(model.displayRequestIDs == [requestID])
    model.setSearchText("Created")
    #expect(model.displayRequestIDs == [requestID])
}

@Test
@MainActor
func requestFileTypeAndSearchUpdateWhenRawMIMETypeAppears() async throws {
    let context = makeContext()
    let requestID = applyPendingRequest(
        to: context,
        requestID: "1",
        url: "https://api.example.com/resource",
        resourceType: .xhr,
        timestamp: 1
    )
    applyResponseReceived(
        to: context,
        requestID: "1",
        url: "https://api.example.com/resource",
        resourceType: .xhr,
        mimeType: nil,
        responseHeaders: ["Content-Type": "application/json"],
        timestamp: 1.1
    )
    let model = NetworkPanelModel(context: context)
    let request = try #require(context.registeredRequest(for: requestID))

    #expect(request.fileTypeLabel == "xhr")
    model.setSearchText("json")
    #expect(model.displayRequestIDs.isEmpty)

    applyResponseReceived(
        to: context,
        requestID: "1",
        url: "https://api.example.com/resource",
        resourceType: .xhr,
        mimeType: "application/json",
        responseHeaders: ["Content-Type": "application/json"],
        timestamp: 1.2
    )
    #expect(request.fileTypeLabel == "json")
    #expect(model.displayRequestIDs == [requestID])
}

@Test
@MainActor
func displayRequestsIgnoreContentOnlyUpdatesDuringActiveFiltering() async throws {
    let context = makeContext()
    let requestID = applyRequest(
        to: context,
        requestID: "1",
        url: "https://media.example.com/clip.mp4",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 1
    )
    let model = NetworkPanelModel(context: context)
    model.setSearchText("clip")
    model.setResourceFilter(.media, enabled: true)

    #expect(model.displayRequestIDs == [requestID])
    let initialRevision = model.displayRowsInvalidationRevision

    applyDataReceived(to: context, requestID: "1", dataLength: 1024, encodedDataLength: 512, timestamp: 2)
    applyLoadingFinished(to: context, requestID: "1", timestamp: 3)

    #expect(model.displayRequestIDs == [requestID])
    #expect(model.displayRowsInvalidationRevision == initialRevision)
}

@Test
@MainActor
func displayRequestsUpdateWhenCriteriaChanges() async throws {
    let context = makeContext()
    let scriptID = applyRequest(
        to: context,
        requestID: "1",
        url: "https://cdn.example.com/app.js",
        resourceType: .script,
        mimeType: "text/javascript",
        timestamp: 1
    )
    applyRequest(
        to: context,
        requestID: "2",
        url: "https://cdn.example.com/photo.png",
        resourceType: .image,
        mimeType: "image/png",
        timestamp: 2
    )
    let model = NetworkPanelModel(context: context)
    model.setSearchText("cdn")

    #expect(model.displayRequestIDs.count == 2)

    model.setResourceFilter(.script, enabled: true)
    #expect(model.displayRequestIDs == [scriptID])
}

@Test
@MainActor
func displayRequestsClearAfterReset() async throws {
    let context = makeContext()
    applyRequest(
        to: context,
        requestID: "1",
        url: "https://cdn.example.com/app.js",
        resourceType: .script,
        mimeType: "text/javascript",
        timestamp: 1
    )
    let model = NetworkPanelModel(context: context)
    model.setSearchText("cdn")

    #expect(model.displayRequestIDs.count == 1)

    context.clearNetworkRequests()

    #expect(model.displayRequestIDs.isEmpty)
}

@Test
@MainActor
func displayRowsInvalidationIgnoresByteCountUpdates() async throws {
    let context = makeContext()
    let requestID = applyRequest(
        to: context,
        requestID: "1",
        url: "https://media.example.com/clip",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 1
    )
    let model = NetworkPanelModel(context: context)
    model.setResourceFilter(.media, enabled: true)

    let initialRevision = model.displayRowsInvalidationRevision
    applyDataReceived(to: context, requestID: "1", dataLength: 1024, encodedDataLength: 512, timestamp: 2)
    #expect(model.displayRowsInvalidationRevision == initialRevision)

    applyResponseReceived(
        to: context,
        requestID: "1",
        url: "https://media.example.com/clip.mp4",
        resourceType: .fetch,
        mimeType: "video/mp4",
        timestamp: 3
    )
    #expect(model.displayRowsInvalidationRevision != initialRevision)
    #expect(context.registeredRequest(for: requestID) != nil)
}

@Test
@MainActor
func displayRowsInvalidationRevisionHasNoPerRequestEntries() async throws {
    let context = makeContext()
    let requestID = applyRequest(
        to: context,
        requestID: "1",
        url: "https://media.example.com/clip.mp4",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 1
    )
    let model = NetworkPanelModel(context: context)
    model.setResourceFilter(.media, enabled: true)

    let revision = model.displayRowsInvalidationRevision
    #expect(revision.entries.isEmpty)

    #expect(model.displayRequestIDs == [requestID])
}

@Test
@MainActor
func displayRequestsUpdateWhenResourceCategoryChanges() async throws {
    let context = makeContext()
    let jsonID = applyRequest(
        to: context,
        requestID: "1",
        url: "https://api.example.com/data.json",
        resourceType: .fetch,
        mimeType: "application/json",
        timestamp: 1
    )
    let mediaID = applyRequest(
        to: context,
        requestID: "2",
        url: "https://media.example.com/clip.mp4",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 2
    )
    let model = NetworkPanelModel(context: context)
    model.setResourceFilter(.media, enabled: true)

    #expect(model.displayRequestIDs == [mediaID])

    applyDataReceived(to: context, requestID: "1", dataLength: 1024, encodedDataLength: 512, timestamp: 3)
    #expect(model.displayRequestIDs == [mediaID])

    applyResponseReceived(
        to: context,
        requestID: "1",
        url: "https://api.example.com/data.mp4",
        resourceType: .fetch,
        mimeType: "video/mp4",
        timestamp: 4
    )
    #expect(model.displayRequestIDs == [mediaID, jsonID])
}

@Test
@MainActor
func displayRequestIDsUseDataKitClassificationForMediaFiltering() async throws {
    let context = makeContext()
    let requestID = applyRequest(
        to: context,
        requestID: "1",
        url: "https://media.example.com/clip.mp4",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 1
    )
    let model = NetworkPanelModel(context: context)

    #expect(model.displayRequestIDs == [requestID])
    let request = try #require(context.registeredRequest(for: requestID))
    #expect(request.displayName == "clip.mp4")

    model.setSearchText("clip")
    #expect(model.displayRequestIDs == [requestID])

    model.setResourceFilter(.media, enabled: true)
    #expect(model.displayRequestIDs == [requestID])
}

@Test
@MainActor
func clearRequestsClearsSelectionButPreservesDisplayCriteria() async throws {
    let context = makeContext()
    let requestID = applyRequest(
        to: context,
        requestID: "1",
        url: "https://cdn.example.com/app.js",
        resourceType: .script,
        mimeType: "text/javascript",
        timestamp: 1
    )
    let model = NetworkPanelModel(context: context)

    model.setSearchText("cdn")
    model.setResourceFilter(.script, enabled: true)
    model.selectRequest(context.registeredRequest(for: requestID))
    model.clearRequests()

    #expect(model.selectedRequestID == nil)
    #expect(model.searchText == "cdn")
    #expect(model.activeResourceFilters == [.script])
    #expect(model.displayRequests.isEmpty)
    #expect(context.registeredRequest(for: requestID) == nil)
}

@Test
@MainActor
func displayRowsInvalidationIgnoresContentUpdatesWhenUnfiltered() async throws {
    let context = makeContext()
    applyRequest(
        to: context,
        requestID: "1",
        url: "https://media.example.com/clip",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 1
    )
    let model = NetworkPanelModel(context: context)

    let initialRevision = model.displayRowsInvalidationRevision
    #expect(initialRevision.entries.isEmpty)
    applyResponseReceived(
        to: context,
        requestID: "1",
        url: "https://media.example.com/clip.mp4",
        resourceType: .fetch,
        mimeType: "video/mp4",
        timestamp: 2
    )

    #expect(model.displayRowsInvalidationRevision == initialRevision)
}

@Test
@MainActor
func responseBodyFetchMovesUnavailablePreviewContextToFailedPhase() async throws {
    let context = makeContext()
    let requestID = applyRequest(
        to: context,
        requestID: "1",
        url: "https://api.example.com/data.json",
        resourceType: .xhr,
        mimeType: "application/json",
        timestamp: 1
    )
    let request = try #require(context.registeredRequest(for: requestID))
    let model = NetworkPanelModel(context: context)

    #expect(request.canFetchResponseBody)
    model.fetchResponseBodyIfNeeded(for: request)

    try await waitUntil {
        if case .failed = request.responseBody.phase {
            return true
        }
        return false
    }
}
}

@MainActor
private func makeContext() -> WebInspectorContext {
    WebInspectorContext.preview(isolation: MainActor.shared)
}

@MainActor
@discardableResult
private func applyRequest(
    to context: WebInspectorContext,
    requestID rawRequestID: String,
    url: String,
    method: String = "GET",
    resourceType: Network.ResourceType,
    mimeType: String?,
    responseHeaders: [String: String] = [:],
    status: Int = 200,
    statusText: String = "OK",
    timestamp: Double
) -> NetworkRequest.ID {
    let requestID = applyPendingRequest(
        to: context,
        requestID: rawRequestID,
        url: url,
        method: method,
        resourceType: resourceType,
        timestamp: timestamp
    )
    applyResponseReceived(
        to: context,
        requestID: rawRequestID,
        url: url,
        resourceType: resourceType,
        mimeType: mimeType,
        responseHeaders: responseHeaders,
        status: status,
        statusText: statusText,
        timestamp: timestamp + 0.1
    )
    applyLoadingFinished(to: context, requestID: rawRequestID, timestamp: timestamp + 0.2)
    return requestID
}

@MainActor
@discardableResult
private func applyPendingRequest(
    to context: WebInspectorContext,
    requestID rawRequestID: String,
    url: String,
    method: String = "GET",
    resourceType: Network.ResourceType,
    timestamp: Double
) -> NetworkRequest.ID {
    let requestID = Network.Request.ID(rawRequestID)
    context.apply(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(id: requestID, url: url, method: method),
            resourceType: resourceType,
            redirectResponse: nil,
            timestamp: timestamp
        )
    )
    return context.registeredRequest(forProxyID: requestID)!.id
}

@MainActor
private func applyRedirectRequest(
    to context: WebInspectorContext,
    requestID rawRequestID: String,
    url: String,
    method: String,
    resourceType: Network.ResourceType,
    redirectURL: String,
    timestamp: Double
) {
    let requestID = Network.Request.ID(rawRequestID)
    context.apply(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(id: requestID, url: url, method: method),
            resourceType: resourceType,
            redirectResponse: Network.Response(url: redirectURL, status: 302),
            timestamp: timestamp
        )
    )
}

@MainActor
private func applyResponseReceived(
    to context: WebInspectorContext,
    requestID rawRequestID: String,
    url: String,
    resourceType: Network.ResourceType,
    mimeType: String?,
    responseHeaders: [String: String] = [:],
    status: Int = 200,
    statusText: String = "OK",
    timestamp: Double
) {
    let requestID = Network.Request.ID(rawRequestID)
    context.apply(
        .responseReceived(
            id: requestID,
            response: Network.Response(
                url: url,
                status: status,
                statusText: statusText,
                mimeType: mimeType,
                headers: responseHeaders,
                source: Network.Source(rawValue: "network")
            ),
            resourceType: resourceType,
            timestamp: timestamp
        )
    )
}

@MainActor
private func applyDataReceived(
    to context: WebInspectorContext,
    requestID rawRequestID: String,
    dataLength: Int,
    encodedDataLength: Int,
    timestamp: Double
) {
    context.apply(
        .dataReceived(
            id: Network.Request.ID(rawRequestID),
            dataLength: dataLength,
            encodedDataLength: encodedDataLength,
            timestamp: timestamp
        )
    )
}

@MainActor
private func applyLoadingFinished(
    to context: WebInspectorContext,
    requestID rawRequestID: String,
    timestamp: Double
) {
    context.apply(
        .loadingFinished(
            id: Network.Request.ID(rawRequestID),
            timestamp: timestamp,
            sourceMapURL: nil,
            metrics: nil
        )
    )
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while condition() == false {
        if clock.now >= deadline {
            Issue.record("Timed out waiting for condition.")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
