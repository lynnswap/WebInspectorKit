import ObservationBridge
import Testing
import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
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
    await applyRequest(
        to: context,
        requestID: "1",
        url: "https://example.com/index.html",
        resourceType: .document,
        mimeType: "text/html",
        timestamp: 1
    )
    let scriptID = await applyRequest(
        to: context,
        requestID: "2",
        url: "https://cdn.example.com/app.js",
        resourceType: .script,
        mimeType: "text/javascript",
        timestamp: 2
    )
    await applyRequest(
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

@Test
@MainActor
func clearAvailabilityUsesUnfilteredRequestsWhenFiltersHideEveryRequest() async throws {
    let context = makeContext()
    let requestID = await applyRequest(
        to: context,
        requestID: "1",
        url: "https://cdn.example.com/app.js",
        resourceType: .script,
        mimeType: "text/javascript",
        timestamp: 1
    )
    let model = NetworkPanelModel(context: context)
    let observation = withPortableContinuousObservation { _ in
        _ = model.hasClearableRequests
    }
    let observedValues = await observation.values {
        model.hasClearableRequests
    }
    defer {
        observedValues.cancel()
        observation.cancel()
    }

    #expect(model.hasClearableRequests)
    #expect(observedValues.latestValue == true)

    model.setSearchText("does-not-match")

    #expect(model.isEmpty)
    #expect(model.displayRequestIDs.isEmpty)
    #expect(model.hasClearableRequests)

    model.clearRequests()

    #expect(model.hasClearableRequests == false)
    #expect(await observedValues.waitUntilValue(false))
    #expect(context.registeredRequest(for: requestID) == nil)
}

@Test
@MainActor
func selectedRequestUsesUnfilteredContextWhenFiltersHideRequest() async throws {
    let context = makeContext()
    let requestID = await applyRequest(
        to: context,
        requestID: "1",
        url: "https://cdn.example.com/app.js",
        resourceType: .script,
        mimeType: "text/javascript",
        timestamp: 1
    )
    let request = try #require(context.registeredRequest(for: requestID))
    let model = NetworkPanelModel(context: context)

    model.selectRequest(request)
    model.setSearchText("does-not-match")

    #expect(model.displayRequestIDs.isEmpty)
    #expect(model.selectedRequestID == requestID)
    #expect(model.selectedRequest === request)
}

@Test
@MainActor
func selectedRequestInvalidatesWhenUnfilteredRequestDisappears() async throws {
    let context = makeContext()
    let requestID = await applyRequest(
        to: context,
        requestID: "1",
        url: "https://cdn.example.com/app.js",
        resourceType: .script,
        mimeType: "text/javascript",
        timestamp: 1
    )
    let request = try #require(context.registeredRequest(for: requestID))
    let model = NetworkPanelModel(context: context)
    model.selectRequest(request)
    model.setSearchText("does-not-match")
    let observation = withPortableContinuousObservation { _ in
        _ = model.selectedRequest
    }
    let observedValues = await observation.values {
        model.selectedRequest == nil
    }
    defer {
        observedValues.cancel()
        observation.cancel()
    }

    #expect(model.displayRequestIDs.isEmpty)
    #expect(model.selectedRequest === request)

    context.clearNetworkRequests()

    #expect(model.selectedRequestID == requestID)
    #expect(model.selectedRequest == nil)
    #expect(await observedValues.waitUntilValue(true))
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
    let requestID = await applyRequest(
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
    let spacedURLRequestID = await applyRequest(
        to: context,
        requestID: "1",
        url: "https://cdn.example.com/photo 1.png",
        resourceType: .fetch,
        mimeType: nil,
        timestamp: 1
    )
    let invalidEscapeRequestID = await applyRequest(
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
    let imageID = await applyRequest(
        to: context,
        requestID: "1",
        url: "https://cdn.example.com/photo.png",
        resourceType: .image,
        mimeType: "image/png",
        timestamp: 1
    )
    let movieID = await applyRequest(
        to: context,
        requestID: "2",
        url: "https://cdn.example.com/movie.mp4",
        resourceType: .media,
        mimeType: "video/mp4",
        timestamp: 2
    )
    let avifResponseID = await applyRequest(
        to: context,
        requestID: "3",
        url: "https://api.example.com/avatar",
        resourceType: .xhr,
        mimeType: "image/avif",
        timestamp: 3
    )
    let avifURLID = await applyRequest(
        to: context,
        requestID: "4",
        url: "https://api.example.com/avatar.avif",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 4
    )
    let hlsID = await applyRequest(
        to: context,
        requestID: "5",
        url: "https://media.example.com/live/master.m3u8",
        resourceType: .xhr,
        mimeType: "application/vnd.apple.mpegurl",
        timestamp: 5
    )
    let mp4URLID = await applyRequest(
        to: context,
        requestID: "6",
        url: "https://media.example.com/clip.mp4",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 6
    )
    let mp3URLID = await applyRequest(
        to: context,
        requestID: "7",
        url: "https://media.example.com/song.mp3",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 7
    )
    let apngResponseID = await applyRequest(
        to: context,
        requestID: "8",
        url: "https://cdn.example.com/animated.apng",
        resourceType: .xhr,
        mimeType: "image/apng",
        timestamp: 8
    )
    let svgID = await applyRequest(
        to: context,
        requestID: "9",
        url: "https://cdn.example.com/icon.svg",
        resourceType: .image,
        mimeType: "image/svg+xml",
        timestamp: 9
    )
    await applyRequest(
        to: context,
        requestID: "10",
        url: "https://cdn.example.com/font.woff2",
        resourceType: .font,
        mimeType: "font/woff2",
        timestamp: 10
    )
    await applyRequest(
        to: context,
        requestID: "11",
        url: "https://api.example.com/data.json",
        resourceType: .xhr,
        mimeType: "application/json",
        timestamp: 11
    )
    await applyRequest(
        to: context,
        requestID: "12",
        url: "https://cdn.example.com/app.js",
        resourceType: .script,
        mimeType: "text/javascript",
        timestamp: 12
    )
    await applyRequest(
        to: context,
        requestID: "13",
        url: "https://cdn.example.com/player.mp4",
        resourceType: .script,
        mimeType: "text/javascript",
        timestamp: 13
    )
    await applyRequest(
        to: context,
        requestID: "14",
        url: "https://cdn.example.com/theme.png",
        resourceType: .stylesheet,
        mimeType: "text/css",
        timestamp: 14
    )
    await applyRequest(
        to: context,
        requestID: "15",
        url: "https://api.example.com/download",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 15
    )
    let apngURLID = await applyRequest(
        to: context,
        requestID: "16",
        url: "https://cdn.example.com/animated.apng",
        resourceType: .fetch,
        mimeType: "application/octet-stream",
        timestamp: 16
    )
    await applyRequest(
        to: context,
        requestID: "17",
        url: "https://cdn.example.com/player.mp4",
        resourceType: .script,
        mimeType: "application/octet-stream",
        timestamp: 17
    )
    await applyPendingRequest(
        to: context,
        requestID: "18",
        url: "https://api.example.com/pending-avatar.png",
        resourceType: .xhr,
        timestamp: 18
    )
    let headerMediaID = await applyRequest(
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
    let requestID = await applyPendingRequest(
        to: context,
        requestID: "1",
        url: "https://api.example.com/avatar",
        resourceType: .xhr,
        timestamp: 1
    )
    let model = NetworkPanelModel(context: context)
    model.setResourceFilter(.media, enabled: true)

    #expect(model.displayRequestIDs.isEmpty)

    await applyResponseReceived(
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
    let requestID = await applyRequest(
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

    await applyResponseReceived(
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
    let requestID = await applyPendingRequest(
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

    await applyRedirectRequest(
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
    model.setSearchText("/old")
    #expect(model.displayRequestIDs == [requestID])
    model.setSearchText("302")
    #expect(model.displayRequestIDs == [requestID])

    model.setSearchText("json")
    #expect(model.displayRequestIDs.isEmpty)

    await applyResponseReceived(
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
    let requestID = await applyPendingRequest(
        to: context,
        requestID: "1",
        url: "https://api.example.com/resource",
        resourceType: .xhr,
        timestamp: 1
    )
    await applyResponseReceived(
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

    await applyResponseReceived(
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
    let requestID = await applyRequest(
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

    await applyDataReceived(to: context, requestID: "1", dataLength: 1024, encodedDataLength: 512, timestamp: 2)
    await applyLoadingFinished(to: context, requestID: "1", timestamp: 3)

    #expect(model.displayRequestIDs == [requestID])
}

@Test
@MainActor
func displayRequestsUpdateWhenCriteriaChanges() async throws {
    let context = makeContext()
    let scriptID = await applyRequest(
        to: context,
        requestID: "1",
        url: "https://cdn.example.com/app.js",
        resourceType: .script,
        mimeType: "text/javascript",
        timestamp: 1
    )
    await applyRequest(
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
    await applyRequest(
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
func displayRequestsUpdateWhenResourceCategoryChanges() async throws {
    let context = makeContext()
    let jsonID = await applyRequest(
        to: context,
        requestID: "1",
        url: "https://api.example.com/data.json",
        resourceType: .fetch,
        mimeType: "application/json",
        timestamp: 1
    )
    let mediaID = await applyRequest(
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

    await applyDataReceived(to: context, requestID: "1", dataLength: 1024, encodedDataLength: 512, timestamp: 3)
    #expect(model.displayRequestIDs == [mediaID])

    await applyResponseReceived(
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
    let requestID = await applyRequest(
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
    let requestID = await applyRequest(
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
func responseBodyFetchMovesUnavailablePreviewContextToFailedPhase() async throws {
    let context = makeContext()
    let requestID = await applyRequest(
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
    let expectedBody = request.responseBody
    model.fetchResponseBodyIfNeeded(for: request)

    #expect(await waitForNetworkBodyPhase(in: expectedBody) { phase in
        if case .failed = phase {
            return true
        }
        return false
    } != nil)
}

@Test
@MainActor
func responseBodyFetchStartsCurrentRevisionWhilePriorRevisionIsInFlight() async throws {
    let fixture = try await makeLiveNetworkModelFixture()
    let requestID = Network.Request.ID("response-revision")
    let initialEventSequence = fixture.context.eventPumpAppliedSequenceForTesting

    await fixture.runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "https://example.com/initial.txt",
                method: "GET"
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: fixture.target
    )
    await fixture.runtime.backend.emit(
        .responseReceived(
            id: requestID,
            response: Network.Response(
                url: "https://example.com/initial.txt",
                status: 200,
                mimeType: "text/plain"
            ),
            resourceType: .fetch,
            timestamp: 2
        ),
        target: fixture.target
    )
    await fixture.runtime.backend.emit(
        .loadingFinished(id: requestID, timestamp: 3, sourceMapURL: nil, metrics: nil),
        target: fixture.target
    )
    #expect(await fixture.context.waitForEventPumpAppliedSequenceForTesting(
        after: initialEventSequence,
        count: 3
    ))

    let request = try #require(
        fixture.context.registeredRequest(forProxyID: requestID)
    )
    let responseBody = request.responseBody
    let model = NetworkPanelModel(context: fixture.context)
    let gate = WebInspectorTestGate()
    await fixture.runtime.backend.hold(
        domain: "Network",
        method: "getResponseBody",
        gate: gate
    )
    await fixture.runtime.backend.enqueue(
        Network.Body(data: "current payload", base64Encoded: false),
        for: "Network",
        method: "getResponseBody"
    )
    await fixture.runtime.backend.enqueue(
        Network.Body(data: "current payload", base64Encoded: false),
        for: "Network",
        method: "getResponseBody"
    )

    model.fetchResponseBodyIfNeeded(for: request)
    let initialCommands = await fixture.runtime.backend.waitForRecordedCommands(
        domain: "Network",
        method: "getResponseBody",
        count: 1
    )
    #expect(initialCommands.count == 1)
    #expect(responseBody.phase == .fetching)

    model.fetchResponseBodyIfNeeded(for: request)
    model.fetchResponseBodyIfNeeded(for: request)
    #expect(await responseBodyCommandCount(on: fixture.runtime.backend) == 1)

    let replacementEventSequence = fixture.context.eventPumpAppliedSequenceForTesting
    await fixture.runtime.backend.emit(
        .responseReceived(
            id: requestID,
            response: Network.Response(
                url: "https://example.com/replacement.json",
                status: 200,
                mimeType: "application/json"
            ),
            resourceType: .fetch,
            timestamp: 4
        ),
        target: fixture.target
    )
    await fixture.runtime.backend.emit(
        .loadingFinished(id: requestID, timestamp: 5, sourceMapURL: nil, metrics: nil),
        target: fixture.target
    )
    #expect(await fixture.context.waitForEventPumpAppliedSequenceForTesting(
        after: replacementEventSequence,
        count: 2
    ))
    #expect(request.responseBody === responseBody)
    #expect(responseBody.phase == .available)

    model.fetchResponseBodyIfNeeded(for: request)
    let currentRevisionStarted = await waitForNetworkBodyPhase(in: responseBody) {
        $0 == .fetching
    } != nil
    if currentRevisionStarted {
        model.fetchResponseBodyIfNeeded(for: request)
        model.fetchResponseBodyIfNeeded(for: request)
        let currentCommands = await fixture.runtime.backend.waitForRecordedCommands(
            domain: "Network",
            method: "getResponseBody",
            count: 2
        )
        #expect(currentCommands.count == 2)
    }

    await gate.open()
    if currentRevisionStarted {
        #expect(await waitForNetworkBodyPhase(in: responseBody) { $0 == .loaded } != nil)
        #expect(responseBody.full == "current payload")
        #expect(await responseBodyCommandCount(on: fixture.runtime.backend) == 2)
    }
    #expect(currentRevisionStarted)
}
}

@MainActor
private func makeContext() -> WebInspectorContext {
    WebInspectorContext.preview(isolation: MainActor.shared)
}

private struct LiveNetworkModelFixture {
    var runtime: WebInspectorProxyTestRuntime
    var target: WebInspectorTarget
    var context: WebInspectorContext
}

@MainActor
private func makeLiveNetworkModelFixture() async throws -> LiveNetworkModelFixture {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    await runtime.backend.enqueue((), for: "Inspector", method: "enable")
    await runtime.backend.enqueue((), for: "Inspector", method: "initialized")
    await runtime.backend.enqueue((), for: "Page", method: "enable")
    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    await runtime.backend.enqueue((), for: "Network", method: "enable")
    await runtime.backend.enqueue(
        DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document"),
        for: "DOM",
        method: "getDocument"
    )
    await runtime.backend.enqueue((), for: "Console", method: "enable")

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await runtime.backend.waitForSubscribers(domain: "DOM", target: target, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "Inspector", target: target, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "CSS", target: target, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "Network", target: target, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "Console", target: target, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "Runtime", target: target, count: 1)
    for await status in context.statusUpdates {
        if status.state == .attached {
            break
        }
        if status.state != .attaching {
            Issue.record("Expected live Network context to attach; got \(status.state).")
            break
        }
    }
    #expect(context.state == .attached)
    return LiveNetworkModelFixture(runtime: runtime, target: target, context: context)
}

private func responseBodyCommandCount(on backend: WebInspectorTestBackend) async -> Int {
    await backend.recordedCommands()
        .filter { $0 == RecordedCommand(domain: "Network", method: "getResponseBody") }
        .count
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
) async -> NetworkRequest.ID {
    let requestID = await applyPendingRequest(
        to: context,
        requestID: rawRequestID,
        url: url,
        method: method,
        resourceType: resourceType,
        timestamp: timestamp
    )
    await applyResponseReceived(
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
    await applyLoadingFinished(to: context, requestID: rawRequestID, timestamp: timestamp + 0.2)
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
) async -> NetworkRequest.ID {
    let requestID = Network.Request.ID(rawRequestID)
    await context.apply(
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
) async {
    let requestID = Network.Request.ID(rawRequestID)
    await context.apply(
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
) async {
    let requestID = Network.Request.ID(rawRequestID)
    await context.apply(
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
) async {
    await context.apply(
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
) async {
    await context.apply(
        .loadingFinished(
            id: Network.Request.ID(rawRequestID),
            timestamp: timestamp,
            sourceMapURL: nil,
            metrics: nil
        )
    )
}
