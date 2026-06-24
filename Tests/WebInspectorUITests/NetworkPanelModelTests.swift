import Testing
import Synchronization
import WebInspectorTransport
@testable import WebInspectorCore
@testable import WebInspectorCoreConsoleNetwork
@testable import WebInspectorCoreDOMCSS
@testable import WebInspectorCoreRuntime
@testable import WebInspectorCoreSupport
@testable import WebInspectorUI
@testable import WebInspectorUISyntaxBody
@testable import WebInspectorUINetwork
@testable import WebInspectorUIDOM
@testable import WebInspectorUIBase

@Suite
struct NetworkPanelModelTests {

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
    let network = NetworkSession()
    let requestID = applyRequest(
        to: network,
        requestID: "1",
        url: url,
        resourceType: .document,
        mimeType: "text/html",
        timestamp: 1
    )
    let request = try #require(network.request(for: requestID))

    #expect(request.displayName == expectedDisplayName)
}

@Test
@MainActor
func requestDisplayUsesEncodingFallbackForURLDerivedLabelsAndFilters() async throws {
    let network = NetworkSession()
    let spacedURLRequestID = applyRequest(
        to: network,
        requestID: "1",
        url: "https://cdn.example.com/photo 1.png",
        resourceType: .fetch,
        mimeType: nil,
        timestamp: 1
    )
    let invalidEscapeRequestID = applyRequest(
        to: network,
        requestID: "2",
        url: "https://cdn.example.com/photo%ZZ.png",
        resourceType: .fetch,
        mimeType: nil,
        timestamp: 2
    )
    let model = NetworkPanelModel(network: network)
    let spacedURLRequest = try #require(network.request(for: spacedURLRequestID))
    let invalidEscapeRequest = try #require(network.request(for: invalidEscapeRequestID))

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
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: "image/avif", url: nil) == .image)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: nil, url: "https://cdn.example.com/photo.avif") == .image)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: "image/apng", url: nil) == .image)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: nil, url: "https://cdn.example.com/animated.apng") == .image)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: "application/octet-stream", url: "https://cdn.example.com/animated.apng") == .image)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: "image/x-png", url: nil) == .image)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: "image/pjpeg", url: nil) == .image)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: "image/x-unknown", url: "https://cdn.example.com/photo.png") == .image)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: nil, url: "https://cdn.example.com/画像.png") == .image)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: "image/svg+xml", url: "https://cdn.example.com/icon.svg") == nil)
    #expect(NetworkRequest.Display.MediaPreviewSupport.classification(mimeType: "image/svg+xml", url: "https://cdn.example.com/icon.svg") == .notPreviewable)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: "text/javascript", url: "https://cdn.example.com/player.mp4") == nil)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: "text/css", url: "https://cdn.example.com/theme.png") == nil)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: "application/octet-stream", url: "https://api.example.com/download") == nil)
    #expect(NetworkRequest.Display.MediaPreviewSupport.temporaryFileExtension(
        mimeType: "video/mp4",
        url: "https://api.example.com/download.php"
    ) == "mp4")
    #expect(NetworkRequest.Display.MediaPreviewSupport.temporaryFileExtension(
        mimeType: "application/vnd.apple.mpegurl",
        url: "https://api.example.com/download.php"
    ) == "m3u8")
    #expect(NetworkRequest.Display.MediaPreviewSupport.temporaryFileExtension(
        mimeType: "application/octet-stream",
        url: "https://cdn.example.com/player.mp4"
    ) == "mp4")
}

@Test
func mediaPreviewSupportClassifiesHLSPlaylists() {
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(
        mimeType: "application/vnd.apple.mpegurl",
        url: nil
    ) == .hlsPlaylist)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(
        mimeType: "application/x-mpegurl; charset=utf-8",
        url: nil
    ) == .hlsPlaylist)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(
        mimeType: "audio/mpegurl",
        url: nil
    ) == .hlsPlaylist)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(
        mimeType: nil,
        url: "https://media.example.com/live/master.m3u8?token=abc"
    ) == .hlsPlaylist)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(
        mimeType: "application/octet-stream",
        url: "https://media.example.com/live/master.m3u8"
    ) == .hlsPlaylist)
}

@Test
@MainActor
func displayResourceFilterUpdatesWhenResponseMIMEBecomesPreviewable() async throws {
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
        response: NetworkRequest.Response.Payload(
            url: "https://api.example.com/avatar",
            status: 200,
            statusText: "OK",
            mimeType: "image/png"
        ),
        timestamp: 1.1
    )
    #expect(model.displayRequestIDs == [requestID])
    let request = try #require(network.request(for: requestID))
    #expect(request.displayResourceFilter(mediaPreviewClassifier: { mimeType, url in
        NetworkRequest.Display.MediaPreviewSupport.classification(mimeType: mimeType, url: url)
    }) == .media)
}

@Test
@MainActor
func requestStatusSeverityUpdatesWhenResponseChanges() async throws {
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
    let request = try #require(network.request(for: requestID))

    #expect(request.statusSeverity == .error)

    network.applyResponseReceived(
        targetID: requestID.targetID,
        requestID: requestID.requestID,
        resourceType: .xhr,
        response: NetworkRequest.Response.Payload(
            url: "https://api.example.com/data.json",
            status: 204,
            statusText: "No Content",
            mimeType: "application/json"
        ),
        timestamp: 2
    )
    #expect(request.statusSeverity == .success)
}

@Test
@MainActor
func displaySearchFieldsUpdateWhenRequestChanges() async throws {
    let network = NetworkSession()
    let targetID = ProtocolTarget.ID("page")
    let rawRequestID = NetworkRequest.ProtocolID("1")
    let requestID = network.applyRequestWillBeSent(
        targetID: targetID,
        requestID: rawRequestID,
        frameID: DOMFrame.ID("main"),
        loaderID: "loader",
        documentURL: "https://example.com",
        request: NetworkRequest.Payload(url: "https://api.example.com/old", method: "POST"),
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
        request: NetworkRequest.Payload(url: "https://api.example.com/new-endpoint", method: "PATCH"),
        resourceType: .xhr,
        redirectResponse: NetworkRequest.Response.Payload(url: "https://api.example.com/old", status: 302),
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
        response: NetworkRequest.Response.Payload(
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
func requestFileTypeAndSearchUpdateWhenRawMIMETypeAppears() async throws {
    let network = NetworkSession()
    let targetID = ProtocolTarget.ID("page")
    let rawRequestID = NetworkRequest.ProtocolID("1")
    let requestID = network.applyRequestWillBeSent(
        targetID: targetID,
        requestID: rawRequestID,
        frameID: DOMFrame.ID("main"),
        loaderID: "loader",
        documentURL: "https://example.com",
        request: NetworkRequest.Payload(url: "https://api.example.com/resource", method: "GET"),
        resourceType: .xhr,
        timestamp: 1
    )
    network.applyResponseReceived(
        targetID: targetID,
        requestID: rawRequestID,
        resourceType: .xhr,
        response: NetworkRequest.Response.Payload(
            url: "https://api.example.com/resource",
            status: 200,
            statusText: "OK",
            headers: ["Content-Type": "application/json"],
            mimeType: nil
        ),
        timestamp: 1.1
    )
    let model = NetworkPanelModel(network: network)
    let request = try #require(network.request(for: requestID))

    #expect(request.fileTypeLabel == "xhr")
    model.setSearchText("json")
    #expect(model.displayRequestIDs.isEmpty)

    network.applyResponseReceived(
        targetID: targetID,
        requestID: rawRequestID,
        resourceType: .xhr,
        response: NetworkRequest.Response.Payload(
            url: "https://api.example.com/resource",
            status: 200,
            statusText: "OK",
            headers: ["Content-Type": "application/json"],
            mimeType: "application/json"
        ),
        timestamp: 1.2
    )
    #expect(request.fileTypeLabel == "json")
    #expect(model.displayRequestIDs == [requestID])
}

@Test
@MainActor
func displayResourceFilteringCachesDisplayEntriesAcrossRepeatedReads() async throws {
    let network = NetworkSession()
    let requestID = applyRequest(
        to: network,
        requestID: "1",
        url: "https://media.example.com/clip.mp4",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 1
    )
    let classificationCount = Mutex(0)
    let model = NetworkPanelModel(
        network: network,
        mediaPreviewClassifier: { mimeType, url in
            classificationCount.withLock { $0 += 1 }
            return NetworkRequest.Display.MediaPreviewSupport.classification(mimeType: mimeType, url: url)
        }
    )
    model.setResourceFilter(.media, enabled: true)

    #expect(model.displayRequestIDs == [requestID])
    #expect(classificationCount.withLock { $0 } == 1)
    #expect(model.displayEntryBuildCountForTesting == 1)

    model.resetDisplayIndexTestingCounters()
    #expect(model.displayRequestIDs == [requestID])
    #expect(classificationCount.withLock { $0 } == 1)
    #expect(model.displayEntryBuildCountForTesting == 0)

    #expect(model.displayRequests.map(\.id) == [requestID])
    #expect(classificationCount.withLock { $0 } == 1)

    network.applyDataReceived(
        targetID: requestID.targetID,
        requestID: requestID.requestID,
        dataLength: 1024,
        encodedDataLength: 512,
        timestamp: 2
    )
    #expect(model.displayRequestIDs == [requestID])
    #expect(classificationCount.withLock { $0 } == 1)
    #expect(model.displayEntryBuildCountForTesting == 0)
}

@Test
@MainActor
func displayIndexRebuildsOnlyDirtyRequestDisplayEntry() async throws {
    let network = NetworkSession()
    let firstID = applyRequest(
        to: network,
        requestID: "1",
        url: "https://cdn.example.com/app.js",
        resourceType: .script,
        mimeType: "text/javascript",
        timestamp: 1
    )
    let secondID = applyRequest(
        to: network,
        requestID: "2",
        url: "https://cdn.example.com/data.json",
        resourceType: .xhr,
        mimeType: "application/json",
        timestamp: 2
    )
    let thirdID = applyRequest(
        to: network,
        requestID: "3",
        url: "https://cdn.example.com/photo.png",
        resourceType: .image,
        mimeType: "image/png",
        timestamp: 3
    )
    let model = NetworkPanelModel(network: network)
    model.setSearchText("cdn")

    #expect(model.displayRequestIDs == [thirdID, secondID, firstID])
    model.resetDisplayIndexTestingCounters()

    network.applyResponseReceived(
        targetID: secondID.targetID,
        requestID: secondID.requestID,
        resourceType: .xhr,
        response: NetworkRequest.Response.Payload(
            url: "https://api.example.com/data-v2.json",
            status: 200,
            mimeType: "application/json"
        ),
        timestamp: 4
    )

    #expect(model.displayRequestIDs == [thirdID, secondID, firstID])
    #expect(model.displayEntryBuildCountForTesting == 1)
    #expect(model.rebuiltDisplayRequestIDsForTesting == [secondID])
}

@Test
@MainActor
func displayIndexIgnoresContentOnlyUpdatesDuringActiveFiltering() async throws {
    let network = NetworkSession()
    let requestID = applyRequest(
        to: network,
        requestID: "1",
        url: "https://media.example.com/clip.mp4",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 1
    )
    let model = NetworkPanelModel(network: network)
    model.setSearchText("clip")
    model.setResourceFilter(.media, enabled: true)

    #expect(model.displayRequestIDs == [requestID])
    model.resetDisplayIndexTestingCounters()

    network.applyDataReceived(
        targetID: requestID.targetID,
        requestID: requestID.requestID,
        dataLength: 1024,
        encodedDataLength: 512,
        timestamp: 2
    )
    network.applyLoadingFinished(
        targetID: requestID.targetID,
        requestID: requestID.requestID,
        timestamp: 3
    )

    #expect(model.displayRequestIDs == [requestID])
    #expect(model.displayEntryBuildCountForTesting == 0)
    #expect(model.rebuiltDisplayRequestIDsForTesting.isEmpty)
}

@Test
@MainActor
func displayIndexReusesEntriesWhenCriteriaChanges() async throws {
    let network = NetworkSession()
    let scriptID = applyRequest(
        to: network,
        requestID: "1",
        url: "https://cdn.example.com/app.js",
        resourceType: .script,
        mimeType: "text/javascript",
        timestamp: 1
    )
    applyRequest(
        to: network,
        requestID: "2",
        url: "https://cdn.example.com/photo.png",
        resourceType: .image,
        mimeType: "image/png",
        timestamp: 2
    )
    let model = NetworkPanelModel(network: network)
    model.setSearchText("cdn")

    #expect(model.displayRequestIDs.count == 2)
    model.resetDisplayIndexTestingCounters()

    model.setResourceFilter(.script, enabled: true)
    #expect(model.displayRequestIDs == [scriptID])
    #expect(model.displayEntryBuildCountForTesting == 0)
    #expect(model.fullMembershipEvaluationCountForTesting == 1)
}

@Test
@MainActor
func displayIndexClearsStaleCacheAfterReset() async throws {
    let network = NetworkSession()
    applyRequest(
        to: network,
        requestID: "1",
        url: "https://cdn.example.com/app.js",
        resourceType: .script,
        mimeType: "text/javascript",
        timestamp: 1
    )
    let model = NetworkPanelModel(network: network)
    model.setSearchText("cdn")

    #expect(model.displayRequestIDs.count == 1)
    #expect(model.displayEntryCacheCountForTesting == 1)

    network.reset()

    #expect(model.displayRequestIDs.isEmpty)
    #expect(model.displayEntryCacheCountForTesting == 0)
}

@Test
@MainActor
func displayRowsInvalidationIgnoresByteCountUpdates() async throws {
    let network = NetworkSession()
    let requestID = applyRequest(
        to: network,
        requestID: "1",
        url: "https://media.example.com/clip",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 1
    )
    let model = NetworkPanelModel(network: network)
    model.setResourceFilter(.media, enabled: true)

    let initialRevision = model.displayRowsInvalidationRevision
    network.applyDataReceived(
        targetID: requestID.targetID,
        requestID: requestID.requestID,
        dataLength: 1024,
        encodedDataLength: 512,
        timestamp: 2
    )
    #expect(model.displayRowsInvalidationRevision == initialRevision)

    network.applyResponseReceived(
        targetID: requestID.targetID,
        requestID: requestID.requestID,
        resourceType: .fetch,
        response: NetworkRequest.Response.Payload(
            url: "https://media.example.com/clip.mp4",
            status: 200,
            mimeType: "video/mp4"
        ),
        timestamp: 3
    )
    #expect(model.displayRowsInvalidationRevision != initialRevision)
}

@Test
@MainActor
func displayRequestIDsSkipsMediaClassificationWhenUnfilteredOrSearchOnly() async throws {
    let network = NetworkSession()
    let requestID = applyRequest(
        to: network,
        requestID: "1",
        url: "https://media.example.com/clip.mp4",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 1
    )
    let classificationCount = Mutex(0)
    let model = NetworkPanelModel(
        network: network,
        mediaPreviewClassifier: { mimeType, url in
            classificationCount.withLock { $0 += 1 }
            return NetworkRequest.Display.MediaPreviewSupport.classification(mimeType: mimeType, url: url)
        }
    )

    #expect(model.displayRequestIDs == [requestID])
    let request = try #require(network.request(for: requestID))
    #expect(request.displayName == "clip.mp4")
    #expect(classificationCount.withLock { $0 } == 0)

    model.setSearchText("clip")
    #expect(model.displayRequestIDs == [requestID])
    #expect(classificationCount.withLock { $0 } == 0)

    model.setResourceFilter(.media, enabled: true)
    #expect(model.displayRequestIDs == [requestID])
    #expect(classificationCount.withLock { $0 } == 1)
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
    #expect(network.request(for: requestID) == nil)
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
    resourceType: NetworkRequest.ResourceType,
    mimeType: String?,
    responseHeaders: [String: String] = [:],
    status: Int = 200,
    statusText: String = "OK",
    timestamp: Double
) -> NetworkRequest.ID {
    let targetID = ProtocolTarget.ID("page")
    let requestID = NetworkRequest.ProtocolID(rawRequestID)
    let key = network.applyRequestWillBeSent(
        targetID: targetID,
        requestID: requestID,
        frameID: DOMFrame.ID("main"),
        loaderID: "loader",
        documentURL: "https://example.com",
        request: NetworkRequest.Payload(url: url),
        resourceType: resourceType,
        timestamp: timestamp
    )
    network.applyResponseReceived(
        targetID: targetID,
        requestID: requestID,
        resourceType: resourceType,
        response: NetworkRequest.Response.Payload(
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
    resourceType: NetworkRequest.ResourceType,
    timestamp: Double
) -> NetworkRequest.ID {
    network.applyRequestWillBeSent(
        targetID: ProtocolTarget.ID("page"),
        requestID: NetworkRequest.ProtocolID(rawRequestID),
        frameID: DOMFrame.ID("main"),
        loaderID: "loader",
        documentURL: "https://example.com",
        request: NetworkRequest.Payload(url: url),
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

}
