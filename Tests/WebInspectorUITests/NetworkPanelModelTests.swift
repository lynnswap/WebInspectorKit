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
        url: "https://example.test/index.html",
        resourceType: .document,
        mimeType: "text/html",
        timestamp: 1
    )
    applyRequest(
        to: network,
        requestID: "2",
        url: "https://cdn.example.test/app.js",
        resourceType: .script,
        mimeType: "text/javascript",
        timestamp: 2
    )
    applyRequest(
        to: network,
        requestID: "3",
        url: "https://cdn.example.test/photo.png",
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
        ("https://www.search.example.test/", "www.search.example.test"),
        ("https://www.search.example.test", "www.search.example.test"),
        ("https://example.test/foo/", "foo"),
        ("https://example.test/a%20b", "a b"),
        ("https://example.test/a%2Fb", "a/b"),
        ("https://example.test/画像.png", "画像.png"),
        ("https://cdn.example.test/photo 1.png", "photo 1.png"),
        ("https://cdn.example.test/photo%ZZ.png", "photo%ZZ.png"),
        ("https://example.test:8443/", "example.test:8443"),
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
        url: "https://cdn.example.test/photo 1.png",
        resourceType: .fetch,
        mimeType: nil,
        timestamp: 1
    )
    let invalidEscapeRequestID = applyRequest(
        to: network,
        requestID: "2",
        url: "https://cdn.example.test/photo%ZZ.png",
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
        url: "https://cdn.example.test/photo.png",
        resourceType: .image,
        mimeType: "image/png",
        timestamp: 1
    )
    applyRequest(
        to: network,
        requestID: "2",
        url: "https://cdn.example.test/movie.mp4",
        resourceType: .fetch,
        mimeType: "video/mp4",
        timestamp: 2
    )
    applyRequest(
        to: network,
        requestID: "3",
        url: "https://api.example.test/avatar",
        resourceType: .xhr,
        mimeType: "image/avif",
        timestamp: 3
    )
    applyRequest(
        to: network,
        requestID: "4",
        url: "https://api.example.test/avatar.avif",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 4
    )
    applyRequest(
        to: network,
        requestID: "5",
        url: "https://media.example.test/live/master.m3u8",
        resourceType: .xhr,
        mimeType: "application/vnd.apple.mpegurl",
        timestamp: 5
    )
    applyRequest(
        to: network,
        requestID: "6",
        url: "https://media.example.test/clip.mp4",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 6
    )
    applyRequest(
        to: network,
        requestID: "7",
        url: "https://media.example.test/song.mp3",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 7
    )
    applyRequest(
        to: network,
        requestID: "8",
        url: "https://cdn.example.test/animated.apng",
        resourceType: .xhr,
        mimeType: "image/apng",
        timestamp: 8
    )
    applyRequest(
        to: network,
        requestID: "9",
        url: "https://cdn.example.test/icon.svg",
        resourceType: .image,
        mimeType: "image/svg+xml",
        timestamp: 9
    )
    applyRequest(
        to: network,
        requestID: "10",
        url: "https://cdn.example.test/font.woff2",
        resourceType: .font,
        mimeType: "font/woff2",
        timestamp: 10
    )
    applyRequest(
        to: network,
        requestID: "11",
        url: "https://api.example.test/data.json",
        resourceType: .xhr,
        mimeType: "application/json",
        timestamp: 11
    )
    applyRequest(
        to: network,
        requestID: "12",
        url: "https://cdn.example.test/app.js",
        resourceType: .script,
        mimeType: "text/javascript",
        timestamp: 12
    )
    applyRequest(
        to: network,
        requestID: "13",
        url: "https://cdn.example.test/player.mp4",
        resourceType: .script,
        mimeType: "text/javascript",
        timestamp: 13
    )
    applyRequest(
        to: network,
        requestID: "14",
        url: "https://cdn.example.test/theme.png",
        resourceType: .styleSheet,
        mimeType: "text/css",
        timestamp: 14
    )
    applyRequest(
        to: network,
        requestID: "15",
        url: "https://api.example.test/download",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 15
    )
    applyRequest(
        to: network,
        requestID: "16",
        url: "https://cdn.example.test/animated.apng",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 16
    )
    applyRequest(
        to: network,
        requestID: "17",
        url: "https://cdn.example.test/player.mp4",
        resourceType: .script,
        mimeType: "application/octet-stream",
        timestamp: 17
    )
    applyPendingRequest(
        to: network,
        requestID: "18",
        url: "https://api.example.test/pending-avatar.png",
        resourceType: .xhr,
        timestamp: 18
    )
    applyRequest(
        to: network,
        requestID: "19",
        url: "https://api.example.test/thumbnail",
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
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: nil, url: "https://cdn.example.test/photo.avif") == .image)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: "image/apng", url: nil) == .image)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: nil, url: "https://cdn.example.test/animated.apng") == .image)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: "application/octet-stream", url: "https://cdn.example.test/animated.apng") == .image)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: "image/x-png", url: nil) == .image)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: "image/pjpeg", url: nil) == .image)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: "image/x-unknown", url: "https://cdn.example.test/photo.png") == .image)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: nil, url: "https://cdn.example.test/画像.png") == .image)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: "image/svg+xml", url: "https://cdn.example.test/icon.svg") == nil)
    #expect(NetworkRequest.Display.MediaPreviewSupport.classification(mimeType: "image/svg+xml", url: "https://cdn.example.test/icon.svg") == .notPreviewable)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: "text/javascript", url: "https://cdn.example.test/player.mp4") == nil)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: "text/css", url: "https://cdn.example.test/theme.png") == nil)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(mimeType: "application/octet-stream", url: "https://api.example.test/download") == nil)
    #expect(NetworkRequest.Display.MediaPreviewSupport.temporaryFileExtension(
        mimeType: "video/mp4",
        url: "https://api.example.test/download.php"
    ) == "mp4")
    #expect(NetworkRequest.Display.MediaPreviewSupport.temporaryFileExtension(
        mimeType: "application/vnd.apple.mpegurl",
        url: "https://api.example.test/download.php"
    ) == "m3u8")
    #expect(NetworkRequest.Display.MediaPreviewSupport.temporaryFileExtension(
        mimeType: "application/octet-stream",
        url: "https://cdn.example.test/player.mp4"
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
        url: "https://media.example.test/live/master.m3u8?token=abc"
    ) == .hlsPlaylist)
    #expect(NetworkRequest.Display.MediaPreviewSupport.previewKind(
        mimeType: "application/octet-stream",
        url: "https://media.example.test/live/master.m3u8"
    ) == .hlsPlaylist)
}

@Test
@MainActor
func displayResourceFilterUpdatesWhenResponseMIMEBecomesPreviewable() async throws {
    let network = NetworkSession()
    let requestID = applyPendingRequest(
        to: network,
        requestID: "1",
        url: "https://api.example.test/avatar",
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
            url: "https://api.example.test/avatar",
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
        url: "https://api.example.test/data.json",
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
            url: "https://api.example.test/data.json",
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
        documentURL: "https://example.test",
        request: NetworkRequest.Payload(url: "https://api.example.test/old", method: "POST"),
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
        documentURL: "https://example.test",
        request: NetworkRequest.Payload(url: "https://api.example.test/new-endpoint", method: "PATCH"),
        resourceType: .xhr,
        redirectResponse: NetworkRequest.Response.Payload(url: "https://api.example.test/old", status: 302),
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
            url: "https://api.example.test/new-endpoint",
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
        documentURL: "https://example.test",
        request: NetworkRequest.Payload(url: "https://api.example.test/resource", method: "GET"),
        resourceType: .xhr,
        timestamp: 1
    )
    network.applyResponseReceived(
        targetID: targetID,
        requestID: rawRequestID,
        resourceType: .xhr,
        response: NetworkRequest.Response.Payload(
            url: "https://api.example.test/resource",
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
            url: "https://api.example.test/resource",
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
func displayProjectionCachesRepeatedReadOnlyAccessors() async throws {
    let network = NetworkSession()
    let requestID = applyRequest(
        to: network,
        requestID: "1",
        url: "https://media.example.test/clip.mp4",
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

    let rows = model.displayRows
    #expect(rows.map(\.id) == [.resource(requestID)])
    #expect(classificationCount.withLock { $0 } == 1)
    #expect(model.displayProjectionBuildCountForTesting == 1)

    #expect(model.displayRequestIDs == [requestID])
    #expect(model.displayEntryIDs == [.resource(requestID)])
    #expect(model.displayRequests.map(\.id) == [requestID])
    #expect(model.displayEntryPresentation(for: .resource(requestID))?.displayName == "clip.mp4")
    #expect(classificationCount.withLock { $0 } == 1)
    #expect(model.displayProjectionBuildCountForTesting == 1)

    network.applyDataReceived(
        targetID: requestID.targetID,
        requestID: requestID.requestID,
        dataLength: 1024,
        encodedDataLength: 512,
        timestamp: 2
    )
    #expect(model.displayRequestIDs == [requestID])
    #expect(model.displayRequests.map(\.id) == [requestID])
    #expect(classificationCount.withLock { $0 } == 1)
    #expect(model.displayProjectionBuildCountForTesting == 1)
}

@Test
@MainActor
func displayRowsInvalidationIgnoresByteCountUpdates() async throws {
    let network = NetworkSession()
    let requestID = applyRequest(
        to: network,
        requestID: "1",
        url: "https://media.example.test/clip",
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
            url: "https://media.example.test/clip.mp4",
            status: 200,
            mimeType: "video/mp4"
        ),
        timestamp: 3
    )
    #expect(model.displayRowsInvalidationRevision != initialRevision)
}

@Test
@MainActor
func contentUpdatesDoNotInvalidateCachedProjection() async throws {
    let network = NetworkSession()
    let requestID = applyPendingRequest(
        to: network,
        requestID: "1",
        url: "https://media.example.test/clip.mp4",
        resourceType: NetworkRequest.ResourceType("Media"),
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

    #expect(model.displayRows.map(\.id) == [.resource(requestID)])
    let initialRevision = model.displayRowsInvalidationRevision
    #expect(model.displayProjectionBuildCountForTesting == 1)
    #expect(classificationCount.withLock { $0 } == 0)

    network.applyDataReceived(
        targetID: requestID.targetID,
        requestID: requestID.requestID,
        dataLength: 2048,
        encodedDataLength: 1024,
        timestamp: 2
    )
    network.applyLoadingFinished(
        targetID: requestID.targetID,
        requestID: requestID.requestID,
        timestamp: 3
    )

    #expect(model.displayRowsInvalidationRevision == initialRevision)
    #expect(model.displayRequestIDs == [requestID])
    #expect(model.displayProjectionBuildCountForTesting == 1)
    #expect(classificationCount.withLock { $0 } == 0)
}

@Test
@MainActor
func loadingCompletionRefreshesPresentationWithoutRebuildingProjection() async throws {
    let network = NetworkSession()
    let requestID = applyPendingRequest(
        to: network,
        requestID: "1",
        url: "https://media.example.test/pending",
        resourceType: NetworkRequest.ResourceType("Media"),
        timestamp: 1
    )
    let model = NetworkPanelModel(network: network)
    model.setResourceFilter(.media, enabled: true)

    #expect(model.displayEntryPresentation(for: .resource(requestID))?.statusSeverity == .neutral)
    let buildCount = model.displayProjectionBuildCountForTesting
    let topologyRevision = model.displayRowsInvalidationRevision

    network.applyLoadingFinished(
        targetID: requestID.targetID,
        requestID: requestID.requestID,
        timestamp: 2
    )

    #expect(model.displayRowsInvalidationRevision == topologyRevision)
    #expect(model.displayEntryPresentation(for: .resource(requestID))?.statusSeverity == .success)
    #expect(model.displayProjectionBuildCountForTesting == buildCount)
}

@Test
@MainActor
func loadingFinishedMetricsRequestHeadersInvalidateDisplayFacts() async throws {
    let network = NetworkSession()
    let requestID = applyPendingRequest(
        to: network,
        requestID: "1",
        url: "https://media.example.test/segment.part",
        resourceType: .other,
        timestamp: 1
    )
    let model = NetworkPanelModel(network: network)
    model.setResourceFilter(.media, enabled: true)

    #expect(model.displayRequestIDs.isEmpty)

    network.applyLoadingFinished(
        targetID: requestID.targetID,
        requestID: requestID.requestID,
        timestamp: 2,
        metrics: NetworkRequest.Metrics.Payload(requestHeaders: [
            "Range": "bytes=10-19",
        ])
    )

    #expect(model.displayRequestIDs == [requestID])
    #expect(model.displayEntryPresentation(for: .resource(requestID))?.secondaryText == "Byte Range 10-19")
}

@Test
@MainActor
func displayRequestIDsSkipsMediaClassificationWhenUnfilteredOrSearchOnly() async throws {
    let network = NetworkSession()
    let requestID = applyRequest(
        to: network,
        requestID: "1",
        url: "https://media.example.test/clip.mp4",
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
func displayRowsGroupMediaWithoutMediaClassificationWhenUnfiltered() async throws {
    let network = NetworkSession()
    let targetID = ProtocolTarget.ID("page")
    let resolver = FakeNetworkDOMNodeResolver(targetID: targetID)
    _ = resolver.addNode(rawNodeID: .init(7), localName: "video")
    let videoGroupID = networkDOMNodeGroupID(targetID: targetID, rawNodeID: 7)
    let firstRequestID = applyRequest(
        to: network,
        requestID: "video-1",
        url: "https://media.example.test/clip-1.mp4",
        resourceType: .fetch,
        mimeType: "video/mp4",
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 1
    )
    let secondRequestID = applyRequest(
        to: network,
        requestID: "video-2",
        url: "https://media.example.test/clip-2.mp4",
        resourceType: .fetch,
        mimeType: "video/mp4",
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 2
    )
    let classificationCount = Mutex(0)
    let model = NetworkPanelModel(
        network: network,
        domNodeResolver: resolver,
        mediaPreviewClassifier: { mimeType, url in
            classificationCount.withLock { $0 += 1 }
            return NetworkRequest.Display.MediaPreviewSupport.classification(mimeType: mimeType, url: url)
        }
    )
    model.groupMediaRequestsByDOMNode = true

    let rows = model.displayRows

    #expect(rows.map(\.id) == [
        .domNodeGroup(videoGroupID),
        .resource(secondRequestID),
        .resource(firstRequestID),
    ])
    #expect(rows.map(\.presentation.indentLevel) == [0, 1, 1])
    #expect(rows[0].presentation.isExpanded)
    #expect(classificationCount.withLock { $0 } == 0)

    _ = rows.map(\.presentation)
    #expect(classificationCount.withLock { $0 } == 0)
}

@Test
@MainActor
func mediaFilterClassificationIsCachedAcrossGroupedRows() async throws {
    let network = NetworkSession()
    let targetID = ProtocolTarget.ID("page")
    let resolver = FakeNetworkDOMNodeResolver(targetID: targetID)
    _ = resolver.addNode(rawNodeID: .init(7), localName: "video")
    let videoGroupID = networkDOMNodeGroupID(targetID: targetID, rawNodeID: 7)
    let firstRequestID = applyRequest(
        to: network,
        requestID: "video-1",
        url: "https://media.example.test/clip-1.mp4",
        resourceType: .fetch,
        mimeType: "video/mp4",
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 1
    )
    let secondRequestID = applyRequest(
        to: network,
        requestID: "video-2",
        url: "https://media.example.test/clip-2.mp4",
        resourceType: .fetch,
        mimeType: "video/mp4",
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 2
    )
    let classificationCount = Mutex(0)
    let model = NetworkPanelModel(
        network: network,
        domNodeResolver: resolver,
        mediaPreviewClassifier: { mimeType, url in
            classificationCount.withLock { $0 += 1 }
            return NetworkRequest.Display.MediaPreviewSupport.classification(mimeType: mimeType, url: url)
        }
    )
    model.setResourceFilter(.media, enabled: true)
    model.groupMediaRequestsByDOMNode = true

    #expect(model.displayEntryIDs == [
        .domNodeGroup(videoGroupID),
        .resource(secondRequestID),
        .resource(firstRequestID),
    ])
    #expect(classificationCount.withLock { $0 } == 2)

    _ = model.displayRows
    _ = model.displayEntryPresentation(for: .resource(firstRequestID))
    _ = model.displayEntryPresentation(for: .resource(secondRequestID))
    #expect(classificationCount.withLock { $0 } == 2)
}

@Test
@MainActor
func requestedByteRangeUsesClosedCaseInsensitiveRangeHeaderOnly() async throws {
    let network = NetworkSession()
    let firstRangeID = applyRequest(
        to: network,
        requestID: "range-1",
        url: "https://media.example.test/clip.part",
        resourceType: .other,
        mimeType: "application/octet-stream",
        requestHeaders: ["Range": "bytes=10-19"],
        timestamp: 1
    )
    let openEndedRangeID = applyRequest(
        to: network,
        requestID: "range-open",
        url: "https://media.example.test/open.part",
        resourceType: .other,
        mimeType: "application/octet-stream",
        requestHeaders: ["Range": "bytes=20-"],
        timestamp: 2
    )
    let suffixRangeID = applyRequest(
        to: network,
        requestID: "range-suffix",
        url: "https://media.example.test/suffix.part",
        resourceType: .other,
        mimeType: "application/octet-stream",
        requestHeaders: ["Range": "bytes=-99"],
        timestamp: 3
    )
    let uppercaseRangeID = applyRequest(
        to: network,
        requestID: "range-2",
        url: "https://media.example.test/clip-2.part",
        resourceType: .other,
        mimeType: "application/octet-stream",
        requestHeaders: ["rAnGe": "BYTES=30-39"],
        timestamp: 4
    )

    #expect(network.request(for: firstRangeID)?.requestedByteRange == NetworkByteRange(start: 10, end: 19))
    #expect(network.request(for: openEndedRangeID)?.requestedByteRange == nil)
    #expect(network.request(for: suffixRangeID)?.requestedByteRange == nil)
    #expect(network.request(for: uppercaseRangeID)?.requestedByteRange == NetworkByteRange(start: 30, end: 39))

    let model = NetworkPanelModel(network: network)
    model.setResourceFilter(.media, enabled: true)
    #expect(model.displayRequestIDs == [uppercaseRangeID, firstRangeID])
    #expect(model.displayEntryPresentation(for: .resource(firstRangeID))?.secondaryText == "Byte Range 10-19")
    #expect(model.displayEntryPresentation(for: .resource(uppercaseRangeID))?.secondaryText == "Byte Range 30-39")
}

@Test
@MainActor
func redirectEntriesAreDisplayProjectionAndCollapseRedirectSelectionToResource() async throws {
    let network = NetworkSession()
    let targetID = ProtocolTarget.ID("page")
    let rawRequestID = NetworkRequest.ProtocolID("redirect-1")
    let requestID = network.applyRequestWillBeSent(
        targetID: targetID,
        requestID: rawRequestID,
        frameID: DOMFrame.ID("main"),
        loaderID: "loader",
        documentURL: "https://example.test/",
        request: NetworkRequest.Payload(url: "https://redirect.example.test/start"),
        resourceType: .document,
        timestamp: 1
    )
    _ = network.applyRequestWillBeSent(
        targetID: targetID,
        requestID: rawRequestID,
        frameID: DOMFrame.ID("main"),
        loaderID: "loader",
        documentURL: "https://example.test/",
        request: NetworkRequest.Payload(url: "https://example.test/final"),
        resourceType: .document,
        redirectResponse: NetworkRequest.Response.Payload(
            url: "https://redirect.example.test/start",
            status: 302,
            statusText: "Found"
        ),
        timestamp: 2
    )
    let redirectID = NetworkRequest.RedirectHop.ID(requestKey: requestID, redirectIndex: 0)
    let model = NetworkPanelModel(network: network)

    #expect(model.displayEntryIDs == [.resource(requestID)])

    model.setRedirectsExpanded(true, for: requestID)
    #expect(model.displayEntryIDs == [.resource(requestID), .redirect(redirectID)])

    model.selectEntry(.redirect(redirectID))
    model.setRedirectsExpanded(false, for: requestID)

    #expect(model.displayEntryIDs == [.resource(requestID)])
    #expect(model.selectedEntryID == .resource(requestID))
    #expect(model.selectedRequestID == requestID)
}

@Test
@MainActor
func groupMediaRequestsUsesResolvedInitiatorDOMNode() async throws {
    let network = NetworkSession()
    let targetID = ProtocolTarget.ID("page")
    let resolver = FakeNetworkDOMNodeResolver(targetID: targetID)
    let videoNodeID = resolver.addNode(rawNodeID: .init(7), localName: "video", attributes: [
        .init(name: "id", value: "player"),
    ])
    let imageNodeID = resolver.addNode(rawNodeID: .init(8), localName: "img")
    let videoGroupID = networkDOMNodeGroupID(targetID: targetID, rawNodeID: 7)
    let imageGroupID = networkDOMNodeGroupID(targetID: targetID, rawNodeID: 8)
    let firstVideoRequestID = applyRequest(
        to: network,
        requestID: "video-1",
        url: "https://media.example.test/clip-1.mp4",
        resourceType: .fetch,
        mimeType: "video/mp4",
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 1
    )
    let secondVideoRequestID = applyRequest(
        to: network,
        requestID: "video-2",
        url: "https://media.example.test/clip-2.mp4",
        resourceType: .fetch,
        mimeType: "video/mp4",
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 2
    )
    let singleImageRequestID = applyRequest(
        to: network,
        requestID: "image-1",
        url: "https://cdn.example.test/poster.png",
        resourceType: .image,
        mimeType: "image/png",
        initiator: .init(type: .parser, nodeID: .init(8)),
        timestamp: 3
    )
    let scriptRequestID = applyRequest(
        to: network,
        requestID: "script-1",
        url: "https://cdn.example.test/player.js",
        resourceType: .script,
        mimeType: "text/javascript",
        initiator: .init(type: .parser, nodeID: .init(7)),
        timestamp: 4
    )
    let model = NetworkPanelModel(network: network, domNodeResolver: resolver)

    #expect(model.groupMediaRequestsByDOMNode == false)
    #expect(model.displayEntryIDs == [
        .resource(scriptRequestID),
        .resource(singleImageRequestID),
        .resource(secondVideoRequestID),
        .resource(firstVideoRequestID),
    ])

    model.selectEntry(.resource(firstVideoRequestID))
    model.groupMediaRequestsByDOMNode = true
    #expect(model.selectedEntryID == .resource(firstVideoRequestID))
    #expect(model.isDOMNodeGroupExpanded(for: videoGroupID))
    #expect(model.displayEntryPresentation(for: .domNodeGroup(videoGroupID))?.isExpanded == true)
    #expect(model.displayEntryIDs == [
        .resource(scriptRequestID),
        .resource(singleImageRequestID),
        .domNodeGroup(videoGroupID),
        .resource(secondVideoRequestID),
        .resource(firstVideoRequestID),
    ])
    let expandedRows = model.displayRows
    #expect(expandedRows.map(\.id) == [
        .resource(scriptRequestID),
        .resource(singleImageRequestID),
        .domNodeGroup(videoGroupID),
        .resource(secondVideoRequestID),
        .resource(firstVideoRequestID),
    ])
    #expect(expandedRows.map(\.presentation.indentLevel) == [0, 0, 0, 1, 1])

    model.setDOMNodeGroupExpanded(false, for: videoGroupID)

    #expect(model.selectedEntryID == .domNodeGroup(videoGroupID))
    #expect(model.isDOMNodeGroupExpanded(for: videoGroupID) == false)
    #expect(model.displayEntryIDs == [
        .resource(scriptRequestID),
        .resource(singleImageRequestID),
        .domNodeGroup(videoGroupID),
    ])
    #expect(model.nodeDisplayName(for: videoNodeID) == "<video#player>")
    #expect(model.nodeDisplayName(for: imageNodeID) == "<img>")
    #expect(model.displayEntryIDs.contains(.domNodeGroup(imageGroupID)) == false)
}

@Test
@MainActor
func mediaGroupingUsesRequestTargetForInitiatorNodeWhenOriginatingTargetDiffers() async throws {
    let network = NetworkSession()
    let pageTargetID = ProtocolTarget.ID("page")
    let frameTargetID = ProtocolTarget.ID("frame")
    let resolver = FakeNetworkDOMNodeResolver(targetID: pageTargetID)
    _ = resolver.addNode(rawNodeID: .init(7), localName: "video")
    let groupID = networkDOMNodeGroupID(targetID: pageTargetID, rawNodeID: 7)
    let firstRawRequestID = NetworkRequest.ProtocolID("video-1")
    let firstRequestID = network.applyRequestWillBeSent(
        targetID: pageTargetID,
        requestID: firstRawRequestID,
        frameID: DOMFrame.ID("main"),
        loaderID: "loader",
        documentURL: "https://example.test/",
        request: NetworkRequest.Payload(url: "https://media.example.test/clip-1.mp4"),
        resourceType: .fetch,
        originatingTargetID: frameTargetID,
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 1
    )
    network.applyResponseReceived(
        targetID: pageTargetID,
        requestID: firstRawRequestID,
        resourceType: .fetch,
        response: NetworkRequest.Response.Payload(
            url: "https://media.example.test/clip-1.mp4",
            status: 200,
            statusText: "OK",
            mimeType: "video/mp4"
        ),
        timestamp: 1.1
    )
    let secondRawRequestID = NetworkRequest.ProtocolID("video-2")
    let secondRequestID = network.applyRequestWillBeSent(
        targetID: pageTargetID,
        requestID: secondRawRequestID,
        frameID: DOMFrame.ID("main"),
        loaderID: "loader",
        documentURL: "https://example.test/",
        request: NetworkRequest.Payload(url: "https://media.example.test/clip-2.mp4"),
        resourceType: .fetch,
        originatingTargetID: frameTargetID,
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 2
    )
    network.applyResponseReceived(
        targetID: pageTargetID,
        requestID: secondRawRequestID,
        resourceType: .fetch,
        response: NetworkRequest.Response.Payload(
            url: "https://media.example.test/clip-2.mp4",
            status: 200,
            statusText: "OK",
            mimeType: "video/mp4"
        ),
        timestamp: 2.1
    )
    let model = NetworkPanelModel(network: network, domNodeResolver: resolver)
    model.groupMediaRequestsByDOMNode = true

    #expect(model.displayEntryIDs == [
        .domNodeGroup(groupID),
        .resource(secondRequestID),
        .resource(firstRequestID),
    ])
    #expect(model.displayEntryPresentation(for: .domNodeGroup(groupID))?.displayName == "<video>")
}

@Test
@MainActor
func mediaGroupingDoesNotIndentUngroupedRows() async throws {
    let network = NetworkSession()
    let targetID = ProtocolTarget.ID("page")
    let resolver = FakeNetworkDOMNodeResolver(targetID: targetID)
    _ = resolver.addNode(rawNodeID: .init(7), localName: "video")
    let videoRequestID = applyRequest(
        to: network,
        requestID: "video-1",
        url: "https://media.example.test/clip-1.mp4",
        resourceType: .fetch,
        mimeType: "video/mp4",
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 1
    )
    let scriptRequestID = applyRequest(
        to: network,
        requestID: "script-1",
        url: "https://cdn.example.test/player.js",
        resourceType: .script,
        mimeType: "text/javascript",
        initiator: .init(type: .parser, nodeID: .init(7)),
        timestamp: 2
    )
    let model = NetworkPanelModel(network: network, domNodeResolver: resolver)
    model.groupMediaRequestsByDOMNode = true

    let rows = model.displayRows
    #expect(rows.map(\.id) == [
        .resource(scriptRequestID),
        .resource(videoRequestID),
    ])
    #expect(rows.map(\.presentation.indentLevel) == [0, 0])
}

@Test
@MainActor
func groupMediaRequestsUsesStableRawNodeIDWhenResolverIsUnresolved() async throws {
    let network = NetworkSession()
    let targetID = ProtocolTarget.ID("page")
    let resolver = FakeNetworkDOMNodeResolver(targetID: targetID)
    let groupID = networkDOMNodeGroupID(targetID: targetID, rawNodeID: 7)
    let firstRequestID = applyRequest(
        to: network,
        requestID: "video-1",
        url: "https://media.example.test/clip-1.mp4",
        resourceType: .fetch,
        mimeType: "video/mp4",
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 1
    )
    let secondRequestID = applyRequest(
        to: network,
        requestID: "video-2",
        url: "https://media.example.test/clip-2.mp4",
        resourceType: .fetch,
        mimeType: "video/mp4",
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 2
    )
    let classificationCount = Mutex(0)
    let model = NetworkPanelModel(
        network: network,
        domNodeResolver: resolver,
        mediaPreviewClassifier: { mimeType, url in
            classificationCount.withLock { $0 += 1 }
            return NetworkRequest.Display.MediaPreviewSupport.classification(mimeType: mimeType, url: url)
        }
    )

    model.groupMediaRequestsByDOMNode = true

    #expect(model.displayEntryIDs == [
        .domNodeGroup(groupID),
        .resource(secondRequestID),
        .resource(firstRequestID),
    ])
    #expect(model.displayEntryPresentation(for: .domNodeGroup(groupID))?.displayName == "DOM node 7")
    #expect(classificationCount.withLock { $0 } == 0)
}

@Test
@MainActor
func unresolvedDOMGroupKeepsIdentityCollapseAndSelectionAfterNodeResolution() async throws {
    let network = NetworkSession()
    let targetID = ProtocolTarget.ID("page")
    let resolver = FakeNetworkDOMNodeResolver(targetID: targetID)
    let groupID = networkDOMNodeGroupID(targetID: targetID, rawNodeID: 7)
    let firstRequestID = applyRequest(
        to: network,
        requestID: "video-1",
        url: "https://media.example.test/clip-1.mp4",
        resourceType: .fetch,
        mimeType: "video/mp4",
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 1
    )
    let secondRequestID = applyRequest(
        to: network,
        requestID: "video-2",
        url: "https://media.example.test/clip-2.mp4",
        resourceType: .fetch,
        mimeType: "video/mp4",
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 2
    )
    let model = NetworkPanelModel(network: network, domNodeResolver: resolver)
    model.groupMediaRequestsByDOMNode = true

    #expect(model.displayEntryIDs == [
        .domNodeGroup(groupID),
        .resource(secondRequestID),
        .resource(firstRequestID),
    ])
    model.selectEntry(.resource(firstRequestID))
    model.setDOMNodeGroupExpanded(false, for: groupID)
    #expect(model.selectedEntryID == .domNodeGroup(groupID))
    #expect(model.displayEntryIDs == [.domNodeGroup(groupID)])
    let buildCount = model.displayProjectionBuildCountForTesting

    _ = resolver.addNode(rawNodeID: .init(7), localName: "video", attributes: [
        .init(name: "id", value: "player"),
    ])

    #expect(model.selectedEntryID == .domNodeGroup(groupID))
    #expect(model.isDOMNodeGroupExpanded(for: groupID) == false)
    #expect(model.displayEntryIDs == [.domNodeGroup(groupID)])
    #expect(model.displayEntryPresentation(for: .domNodeGroup(groupID))?.displayName == "<video#player>")
    #expect(model.displayProjectionBuildCountForTesting == buildCount)
}

@Test
@MainActor
func byteRangeGroupingUsesOpenAndClosedRangesButOnlyClosedRangesHaveLabels() async throws {
    let network = NetworkSession()
    let targetID = ProtocolTarget.ID("page")
    let resolver = FakeNetworkDOMNodeResolver(targetID: targetID)
    _ = resolver.addNode(rawNodeID: .init(7), localName: "video")
    let groupID = networkDOMNodeGroupID(targetID: targetID, rawNodeID: 7)
    let closedRangeID = applyRequest(
        to: network,
        requestID: "range-closed",
        url: "https://media.example.test/clip-closed.part",
        resourceType: .other,
        mimeType: "application/octet-stream",
        requestHeaders: ["Range": "bytes=10-19"],
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 1
    )
    let openRangeID = applyRequest(
        to: network,
        requestID: "range-open",
        url: "https://media.example.test/clip-open.part",
        resourceType: .other,
        mimeType: "application/octet-stream",
        requestHeaders: ["Range": "bytes=20-"],
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 2
    )
    let model = NetworkPanelModel(network: network, domNodeResolver: resolver)
    model.groupMediaRequestsByDOMNode = true

    #expect(model.displayEntryIDs == [
        .domNodeGroup(groupID),
        .resource(openRangeID),
        .resource(closedRangeID),
    ])
    #expect(model.displayEntryPresentation(for: .resource(closedRangeID))?.secondaryText == "Byte Range 10-19")
    #expect(model.displayEntryPresentation(for: .resource(openRangeID))?.secondaryText == nil)
}

@Test
@MainActor
func mediaGroupingHappensAfterFilteringAndRequiresTwoMatchingChildren() async throws {
    let network = NetworkSession()
    let targetID = ProtocolTarget.ID("page")
    let resolver = FakeNetworkDOMNodeResolver(targetID: targetID)
    _ = resolver.addNode(rawNodeID: .init(7), localName: "video")
    let groupID = networkDOMNodeGroupID(targetID: targetID, rawNodeID: 7)
    let firstRequestID = applyRequest(
        to: network,
        requestID: "video-1",
        url: "https://media.example.test/clip-1.mp4",
        resourceType: .fetch,
        mimeType: "video/mp4",
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 1
    )
    let secondRequestID = applyRequest(
        to: network,
        requestID: "video-2",
        url: "https://media.example.test/clip-2.mp4",
        resourceType: .fetch,
        mimeType: "video/mp4",
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 2
    )
    let scriptRequestID = applyRequest(
        to: network,
        requestID: "script-1",
        url: "https://cdn.example.test/clip-helper.js",
        resourceType: .script,
        mimeType: "text/javascript",
        initiator: .init(type: .parser, nodeID: .init(7)),
        timestamp: 3
    )
    let model = NetworkPanelModel(network: network, domNodeResolver: resolver)
    model.groupMediaRequestsByDOMNode = true
    model.setResourceFilter(.media, enabled: true)

    model.setSearchText("clip-1")
    #expect(model.displayEntryIDs == [.resource(firstRequestID)])

    model.setSearchText("clip")
    #expect(model.displayEntryIDs == [
        .domNodeGroup(groupID),
        .resource(secondRequestID),
        .resource(firstRequestID),
    ])
    #expect(model.displayEntryIDs.contains(.resource(scriptRequestID)) == false)
}

@Test
@MainActor
func nonMediaResourceFilterDoesNotApplyMediaGrouping() async throws {
    let network = NetworkSession()
    let targetID = ProtocolTarget.ID("page")
    let resolver = FakeNetworkDOMNodeResolver(targetID: targetID)
    _ = resolver.addNode(rawNodeID: .init(7), localName: "script")
    let firstScriptID = applyRequest(
        to: network,
        requestID: "script-1",
        url: "https://cdn.example.test/player-1.mp4",
        resourceType: .script,
        mimeType: "text/javascript",
        initiator: .init(type: .parser, nodeID: .init(7)),
        timestamp: 1
    )
    let secondScriptID = applyRequest(
        to: network,
        requestID: "script-2",
        url: "https://cdn.example.test/player-2.mp4",
        resourceType: .script,
        mimeType: "text/javascript",
        initiator: .init(type: .parser, nodeID: .init(7)),
        timestamp: 2
    )
    let model = NetworkPanelModel(network: network, domNodeResolver: resolver)
    model.groupMediaRequestsByDOMNode = true
    model.setResourceFilter(.script, enabled: true)

    #expect(model.displayEntryIDs == [
        .resource(secondScriptID),
        .resource(firstScriptID),
    ])
}

@Test
@MainActor
func rawProtocolMediaResourceTypeRemainsUIMediaWithoutProtocolConvenience() async throws {
    let network = NetworkSession()
    let targetID = ProtocolTarget.ID("page")
    let resolver = FakeNetworkDOMNodeResolver(targetID: targetID)
    _ = resolver.addNode(rawNodeID: .init(7), localName: "video")
    let videoGroupID = networkDOMNodeGroupID(targetID: targetID, rawNodeID: 7)
    let firstMediaRequestID = applyPendingRequest(
        to: network,
        requestID: "raw-media-1",
        url: "https://media.example.test/raw-stream-1",
        resourceType: NetworkRequest.ResourceType("Media"),
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 1
    )
    let secondMediaRequestID = applyPendingRequest(
        to: network,
        requestID: "raw-media-2",
        url: "https://media.example.test/raw-stream-2",
        resourceType: NetworkRequest.ResourceType("Media"),
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 2
    )
    let model = NetworkPanelModel(network: network, domNodeResolver: resolver)

    model.setResourceFilter(.media, enabled: true)
    #expect(model.displayRequestIDs == [secondMediaRequestID, firstMediaRequestID])

    model.clearResourceFilters()
    model.groupMediaRequestsByDOMNode = true
    #expect(model.displayEntryIDs == [
        .domNodeGroup(videoGroupID),
        .resource(secondMediaRequestID),
        .resource(firstMediaRequestID),
    ])
}

@Test
@MainActor
func displayRowsInvalidationTracksDisplayChangesForDOMNodeMediaGrouping() async throws {
    let network = NetworkSession()
    let targetID = ProtocolTarget.ID("page")
    let resolver = FakeNetworkDOMNodeResolver(targetID: targetID)
    _ = resolver.addNode(rawNodeID: .init(7), localName: "video")
    let videoGroupID = networkDOMNodeGroupID(targetID: targetID, rawNodeID: 7)
    let firstVideoRequestID = applyRequest(
        to: network,
        requestID: "video-1",
        url: "https://media.example.test/clip-1.mp4",
        resourceType: .fetch,
        mimeType: "video/mp4",
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 1
    )
    let pendingVideoRequestID = applyPendingRequest(
        to: network,
        requestID: "video-2",
        url: "https://media.example.test/clip-2",
        resourceType: .fetch,
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 2
    )
    let model = NetworkPanelModel(network: network, domNodeResolver: resolver)
    model.groupMediaRequestsByDOMNode = true

    #expect(model.displayEntryIDs == [
        .resource(pendingVideoRequestID),
        .resource(firstVideoRequestID),
    ])
    let initialRevision = model.displayRowsInvalidationRevision

    network.applyResponseReceived(
        targetID: targetID,
        requestID: pendingVideoRequestID.requestID,
        resourceType: .fetch,
        response: NetworkRequest.Response.Payload(
            url: "https://media.example.test/clip-2",
            status: 200,
            statusText: "OK",
            mimeType: "video/mp4"
        ),
        timestamp: 2.1
    )

    #expect(model.displayRowsInvalidationRevision != initialRevision)
    #expect(model.displayEntryIDs == [
        .domNodeGroup(videoGroupID),
        .resource(pendingVideoRequestID),
        .resource(firstVideoRequestID),
    ])
}

@Test
@MainActor
func redirectPresentationKeepsNestedIndentInsideDOMNodeMediaGroup() async throws {
    let network = NetworkSession()
    let targetID = ProtocolTarget.ID("page")
    let resolver = FakeNetworkDOMNodeResolver(targetID: targetID)
    _ = resolver.addNode(rawNodeID: .init(7), localName: "video")
    let videoGroupID = networkDOMNodeGroupID(targetID: targetID, rawNodeID: 7)
    let rawRedirectRequestID = NetworkRequest.ProtocolID("video-redirect")
    let redirectedRequestID = network.applyRequestWillBeSent(
        targetID: targetID,
        requestID: rawRedirectRequestID,
        frameID: DOMFrame.ID("main"),
        loaderID: "loader",
        documentURL: "https://example.test/",
        request: NetworkRequest.Payload(url: "https://redirect.example.test/clip-start"),
        resourceType: .fetch,
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 1
    )
    _ = network.applyRequestWillBeSent(
        targetID: targetID,
        requestID: rawRedirectRequestID,
        frameID: DOMFrame.ID("main"),
        loaderID: "loader",
        documentURL: "https://example.test/",
        request: NetworkRequest.Payload(url: "https://media.example.test/clip-final.mp4"),
        resourceType: .fetch,
        initiator: .init(type: .other, nodeID: .init(7)),
        redirectResponse: NetworkRequest.Response.Payload(
            url: "https://redirect.example.test/clip-start",
            status: 302,
            statusText: "Found"
        ),
        timestamp: 2
    )
    network.applyResponseReceived(
        targetID: targetID,
        requestID: rawRedirectRequestID,
        resourceType: .fetch,
        response: NetworkRequest.Response.Payload(
            url: "https://media.example.test/clip-final.mp4",
            status: 200,
            statusText: "OK",
            mimeType: "video/mp4"
        ),
        timestamp: 2.1
    )
    let siblingRequestID = applyRequest(
        to: network,
        requestID: "video-sibling",
        url: "https://media.example.test/clip-sibling.mp4",
        resourceType: .fetch,
        mimeType: "video/mp4",
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 3
    )
    let redirectID = NetworkRequest.RedirectHop.ID(requestKey: redirectedRequestID, redirectIndex: 0)
    let model = NetworkPanelModel(network: network, domNodeResolver: resolver)
    model.groupMediaRequestsByDOMNode = true
    #expect(model.isDOMNodeGroupExpanded(for: videoGroupID))
    model.setRedirectsExpanded(true, for: redirectedRequestID)

    #expect(model.displayEntryIDs == [
        .domNodeGroup(videoGroupID),
        .resource(siblingRequestID),
        .resource(redirectedRequestID),
        .redirect(redirectID),
    ])
    #expect(model.displayEntryPresentation(for: .resource(redirectedRequestID))?.indentLevel == 1)
    #expect(model.displayEntryPresentation(for: .redirect(redirectID))?.indentLevel == 2)
}

@Test
@MainActor
func collapsingDOMNodeGroupWithSelectedChildRedirectSelectsGroup() async throws {
    let network = NetworkSession()
    let targetID = ProtocolTarget.ID("page")
    let resolver = FakeNetworkDOMNodeResolver(targetID: targetID)
    _ = resolver.addNode(rawNodeID: .init(7), localName: "video")
    let groupID = networkDOMNodeGroupID(targetID: targetID, rawNodeID: 7)
    let rawRedirectRequestID = NetworkRequest.ProtocolID("video-redirect")
    let redirectedRequestID = network.applyRequestWillBeSent(
        targetID: targetID,
        requestID: rawRedirectRequestID,
        frameID: DOMFrame.ID("main"),
        loaderID: "loader",
        documentURL: "https://example.test/",
        request: NetworkRequest.Payload(url: "https://redirect.example.test/clip-start"),
        resourceType: .fetch,
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 1
    )
    _ = network.applyRequestWillBeSent(
        targetID: targetID,
        requestID: rawRedirectRequestID,
        frameID: DOMFrame.ID("main"),
        loaderID: "loader",
        documentURL: "https://example.test/",
        request: NetworkRequest.Payload(url: "https://media.example.test/clip-final.mp4"),
        resourceType: .fetch,
        initiator: .init(type: .other, nodeID: .init(7)),
        redirectResponse: NetworkRequest.Response.Payload(
            url: "https://redirect.example.test/clip-start",
            status: 302,
            statusText: "Found"
        ),
        timestamp: 2
    )
    network.applyResponseReceived(
        targetID: targetID,
        requestID: rawRedirectRequestID,
        resourceType: .fetch,
        response: NetworkRequest.Response.Payload(
            url: "https://media.example.test/clip-final.mp4",
            status: 200,
            statusText: "OK",
            mimeType: "video/mp4"
        ),
        timestamp: 2.1
    )
    let siblingRequestID = applyRequest(
        to: network,
        requestID: "video-sibling",
        url: "https://media.example.test/clip-sibling.mp4",
        resourceType: .fetch,
        mimeType: "video/mp4",
        initiator: .init(type: .other, nodeID: .init(7)),
        timestamp: 3
    )
    let redirectID = NetworkRequest.RedirectHop.ID(requestKey: redirectedRequestID, redirectIndex: 0)
    let model = NetworkPanelModel(network: network, domNodeResolver: resolver)
    model.groupMediaRequestsByDOMNode = true
    model.setRedirectsExpanded(true, for: redirectedRequestID)

    #expect(model.displayEntryIDs == [
        .domNodeGroup(groupID),
        .resource(siblingRequestID),
        .resource(redirectedRequestID),
        .redirect(redirectID),
    ])

    model.selectEntry(.redirect(redirectID))
    model.setDOMNodeGroupExpanded(false, for: groupID)

    #expect(model.selectedEntryID == .domNodeGroup(groupID))
    #expect(model.displayEntryIDs == [.domNodeGroup(groupID)])
}

@Test
@MainActor
func clearRequestsClearsSelectionButPreservesDisplayCriteria() async throws {
    let network = NetworkSession()
    let requestID = applyRequest(
        to: network,
        requestID: "1",
        url: "https://cdn.example.test/app.js",
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
        url: "https://api.example.test/data.json",
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
    requestHeaders: [String: String] = [:],
    responseHeaders: [String: String] = [:],
    initiator: NetworkRequest.Initiator.Payload? = nil,
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
        documentURL: "https://example.test",
        request: NetworkRequest.Payload(url: url, headers: requestHeaders),
        resourceType: resourceType,
        initiator: initiator,
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
    initiator: NetworkRequest.Initiator.Payload? = nil,
    timestamp: Double
) -> NetworkRequest.ID {
    network.applyRequestWillBeSent(
        targetID: ProtocolTarget.ID("page"),
        requestID: NetworkRequest.ProtocolID(rawRequestID),
        frameID: DOMFrame.ID("main"),
        loaderID: "loader",
        documentURL: "https://example.test",
        request: NetworkRequest.Payload(url: url),
        resourceType: resourceType,
        initiator: initiator,
        timestamp: timestamp
    )
}

private func networkDOMNodeGroupID(
    targetID: ProtocolTarget.ID,
    rawNodeID: Int
) -> NetworkDOMNodeGroup.ID {
    NetworkDOMNodeGroup.ID(targetID: targetID, rawNodeID: .init(rawNodeID))
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

@MainActor
private final class FakeNetworkDOMNodeResolver: NetworkDOMNodeResolving {
    private let targetID: ProtocolTarget.ID
    private let documentID: DOMDocument.ID
    private var currentNodeIDByProtocolID: [DOMNode.ProtocolID: DOMNode.ID] = [:]
    private var nodesByID: [DOMNode.ID: DOMNode] = [:]
    private(set) var networkDOMRevision: UInt64 = 0

    init(targetID: ProtocolTarget.ID) {
        self.targetID = targetID
        self.documentID = DOMDocument.ID(
            targetID: targetID,
            localDocumentLifetimeID: .init(1)
        )
    }

    @discardableResult
    func addNode(
        rawNodeID: DOMNode.ProtocolID,
        localName: String,
        attributes: [DOMNode.Attribute] = []
    ) -> DOMNode.ID {
        let nodeID = DOMNode.ID(documentID: documentID, nodeID: rawNodeID)
        nodesByID[nodeID] = DOMNode(
            id: nodeID,
            payload: DOMNode.Payload(
                nodeID: rawNodeID,
                nodeType: .element,
                nodeName: localName.uppercased(),
                localName: localName,
                attributes: attributes
            ),
            parentID: nil
        )
        currentNodeIDByProtocolID[rawNodeID] = nodeID
        networkDOMRevision += 1
        return nodeID
    }

    func networkCurrentNodeID(
        targetID: ProtocolTarget.ID,
        rawNodeID: DOMNode.ProtocolID
    ) -> DOMNode.ID? {
        guard targetID == self.targetID else {
            return nil
        }
        return currentNodeIDByProtocolID[rawNodeID]
    }

    func networkNode(for nodeID: DOMNode.ID) -> DOMNode? {
        nodesByID[nodeID]
    }
}

}
