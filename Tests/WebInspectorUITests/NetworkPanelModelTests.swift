import ObservationBridge
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

    let model = try await NetworkPanelModel.make(context: context)
    model.setSearchText("cdn")
    model.setResourceFilter(.script, enabled: true)
    await model.waitForQueryUpdates()

    #expect(model.requests.snapshot.itemIDs == [scriptID])
}

@Test
@MainActor
func rapidCriteriaChangesPublishOnlyTheLatestConcreteQuery() async throws {
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
    let model = try await NetworkPanelModel.make(context: context)

    model.setSearchText("cdn")
    model.setResourceFilter(.script, enabled: true)
    model.setSearchText("app.js")
    await model.waitForQueryUpdates()

    #expect(
        model.query == NetworkQuery(
            search: "app.js",
            resourceCategories: [.script],
            sort: .requestTimeDescending,
            section: .initiatorNode
        )
    )
    #expect(model.appliedQueryRevision == model.queryRevision)
    #expect(model.requests.snapshot.itemIDs == [scriptID])
}

@Test
@MainActor
func queryScheduledAfterClearWaitsForClearAndRemainsActive() async throws {
    let context = makeContext()
    let clearedRequestID = await applyRequest(
        to: context,
        requestID: "1",
        url: "https://example.com/old-endpoint",
        resourceType: .xhr,
        mimeType: "application/json",
        timestamp: 1
    )
    let model = try await NetworkPanelModel.make(context: context)

    model.setSearchText("old-endpoint")
    model.clearRequests()
    model.setSearchText("new-endpoint")
    await model.waitForQueryUpdates()

    #expect(try context.networkRequest(id: clearedRequestID) == nil)
    #expect(model.query.search == "new-endpoint")
    #expect(model.appliedQueryRevision == model.queryRevision)
    #expect(model.requests.snapshot.itemIDs.isEmpty)

    let newRequestID = await applyRequest(
        to: context,
        requestID: "2",
        url: "https://example.com/new-endpoint",
        resourceType: .xhr,
        mimeType: "application/json",
        timestamp: 2
    )

    #expect(model.requests.snapshot.itemIDs == [newRequestID])
}

@Test
@MainActor
func retireCancelsAndAwaitsOwnedQueryWork() async throws {
    let context = makeContext()
    var model: NetworkPanelModel? = try await NetworkPanelModel.make(context: context)
    weak let retainedModel = model

    model?.setSearchText("first")
    model?.setSearchText("latest")
    await model?.retire()

    #expect(model?.isRetiredForTesting == true)

    model = nil

    #expect(retainedModel == nil)
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
    let model = try await NetworkPanelModel.make(context: context)
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
    await model.waitForQueryUpdates()

    #expect(model.isEmpty)
    #expect(model.requests.snapshot.itemIDs.isEmpty)
    #expect(model.hasClearableRequests)

    model.clearRequests()
    await model.waitForQueryUpdates()

    #expect(model.hasClearableRequests == false)
    #expect(await observedValues.waitUntilValue(false))
    #expect(try context.networkRequest(id: requestID) == nil)
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
    let request = try #require(try context.networkRequest(id: requestID))
    let model = try await NetworkPanelModel.make(context: context)
    let groupID = try #require(context.networkRequestGroupID(containing: requestID))

    model.selectRequest(request)
    model.setSearchText("does-not-match")
    await model.waitForQueryUpdates()

    #expect(model.requests.snapshot.itemIDs.isEmpty)
    #expect(model.selectedEntryID == groupID)
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
    let request = try #require(try context.networkRequest(id: requestID))
    let model = try await NetworkPanelModel.make(context: context)
    model.selectRequest(request)
    let selectionToken = try #require(model.selectionToken)
    model.setSearchText("does-not-match")
    await model.waitForQueryUpdates()
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

    #expect(model.requests.snapshot.itemIDs.isEmpty)
    #expect(model.selectedRequest === request)

    await context.clearNetworkRequests()

    #expect(model.selectionToken == selectionToken)
    #expect(model.selectedEntryID == nil)
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
    let request = try #require(try context.networkRequest(id: requestID))

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
    let model = try await NetworkPanelModel.make(context: context)
    let spacedURLRequest = try #require(try context.networkRequest(id: spacedURLRequestID))
    let invalidEscapeRequest = try #require(try context.networkRequest(id: invalidEscapeRequestID))

    #expect(spacedURLRequest.displayName == "photo 1.png")
    #expect(spacedURLRequest.fileTypeLabel == "png")
    #expect(invalidEscapeRequest.displayName == "photo%ZZ.png")
    #expect(invalidEscapeRequest.fileTypeLabel == "png")

    model.setResourceFilter(.media, enabled: true)
    await model.waitForQueryUpdates()
    #expect(model.requests.snapshot.itemIDs == [invalidEscapeRequestID, spacedURLRequestID])
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

    let model = try await NetworkPanelModel.make(context: context)
    model.setResourceFilter(.media, enabled: true)
    await model.waitForQueryUpdates()

    #expect(model.requests.snapshot.itemIDs == [
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
    let model = try await NetworkPanelModel.make(context: context)
    model.setResourceFilter(.media, enabled: true)
    await model.waitForQueryUpdates()

    #expect(model.requests.snapshot.itemIDs.isEmpty)

    await applyResponseReceived(
        to: context,
        requestID: "1",
        url: "https://api.example.com/avatar",
        resourceType: .xhr,
        mimeType: "image/png",
        timestamp: 1.1
    )
    #expect(model.requests.snapshot.itemIDs == [requestID])
    let request = try #require(try context.networkRequest(id: requestID))
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
    let request = try #require(try context.networkRequest(id: requestID))

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
    let model = try await NetworkPanelModel.make(context: context)

    model.setSearchText("new-endpoint")
    await model.waitForQueryUpdates()
    #expect(model.requests.snapshot.itemIDs.isEmpty)

    await applyRedirectRequest(
        to: context,
        requestID: "1",
        url: "https://api.example.com/new-endpoint",
        method: "PATCH",
        resourceType: .xhr,
        redirectURL: "https://api.example.com/old",
        timestamp: 2
    )
    #expect(model.requests.snapshot.itemIDs == [requestID])
    model.setSearchText("PATCH")
    await model.waitForQueryUpdates()
    #expect(model.requests.snapshot.itemIDs == [requestID])
    model.setSearchText("/old")
    await model.waitForQueryUpdates()
    #expect(model.requests.snapshot.itemIDs == [requestID])

    model.setSearchText("json")
    await model.waitForQueryUpdates()
    #expect(model.requests.snapshot.itemIDs.isEmpty)

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
    #expect(model.requests.snapshot.itemIDs == [requestID])
    model.setSearchText("Created")
    await model.waitForQueryUpdates()
    #expect(model.requests.snapshot.itemIDs == [requestID])
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
    let model = try await NetworkPanelModel.make(context: context)
    let request = try #require(try context.networkRequest(id: requestID))

    #expect(request.fileTypeLabel == "xhr")
    model.setSearchText("json")
    await model.waitForQueryUpdates()
    #expect(model.requests.snapshot.itemIDs.isEmpty)

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
    #expect(model.requests.snapshot.itemIDs == [requestID])
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
    let model = try await NetworkPanelModel.make(context: context)
    model.setSearchText("clip")
    model.setResourceFilter(.media, enabled: true)
    await model.waitForQueryUpdates()

    #expect(model.requests.snapshot.itemIDs == [requestID])

    await applyDataReceived(to: context, requestID: "1", dataLength: 1024, encodedDataLength: 512, timestamp: 2)
    await applyLoadingFinished(to: context, requestID: "1", timestamp: 3)

    #expect(model.requests.snapshot.itemIDs == [requestID])
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
    let model = try await NetworkPanelModel.make(context: context)
    model.setSearchText("cdn")
    await model.waitForQueryUpdates()

    #expect(model.requests.snapshot.itemIDs.count == 2)

    model.setResourceFilter(.script, enabled: true)
    await model.waitForQueryUpdates()
    #expect(model.requests.snapshot.itemIDs == [scriptID])
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
    let model = try await NetworkPanelModel.make(context: context)
    model.setSearchText("cdn")
    await model.waitForQueryUpdates()

    #expect(model.requests.snapshot.itemIDs.count == 1)

    await context.clearNetworkRequests()

    #expect(model.requests.snapshot.itemIDs.isEmpty)
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
    let model = try await NetworkPanelModel.make(context: context)
    model.setResourceFilter(.media, enabled: true)
    await model.waitForQueryUpdates()

    #expect(model.requests.snapshot.itemIDs == [mediaID])

    await applyDataReceived(to: context, requestID: "1", dataLength: 1024, encodedDataLength: 512, timestamp: 3)
    #expect(model.requests.snapshot.itemIDs == [mediaID])

    await applyResponseReceived(
        to: context,
        requestID: "1",
        url: "https://api.example.com/data.mp4",
        resourceType: .fetch,
        mimeType: "video/mp4",
        timestamp: 4
    )
    #expect(model.requests.snapshot.itemIDs == [mediaID, jsonID])
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
    let model = try await NetworkPanelModel.make(context: context)

    #expect(model.requests.snapshot.itemIDs == [requestID])
    let request = try #require(try context.networkRequest(id: requestID))
    #expect(request.displayName == "clip.mp4")

    model.setSearchText("clip")
    await model.waitForQueryUpdates()
    #expect(model.requests.snapshot.itemIDs == [requestID])

    model.setResourceFilter(.media, enabled: true)
    await model.waitForQueryUpdates()
    #expect(model.requests.snapshot.itemIDs == [requestID])
}

@Test
@MainActor
func requestsWithTheSameInitiatorNodeProjectAsOneEntry() async throws {
    let context = makeContext()
    let nodeID = DOM.Node.ID("media-element")
    let playlistID = await applyRequest(
        to: context,
        requestID: "playlist",
        url: "https://media.example.com/master.m3u8",
        resourceType: .media,
        mimeType: "application/vnd.apple.mpegurl",
        timestamp: 1,
        initiatorNodeID: nodeID
    )
    let unrelatedID = await applyRequest(
        to: context,
        requestID: "unrelated",
        url: "https://example.com/app.js",
        resourceType: .script,
        mimeType: "text/javascript",
        timestamp: 2
    )
    let segmentID = await applyRequest(
        to: context,
        requestID: "segment",
        url: "https://media.example.com/segment-1.ts",
        resourceType: .media,
        mimeType: "video/mp2t",
        timestamp: 3,
        initiatorNodeID: nodeID
    )

    let model = try await NetworkPanelModel.make(context: context)
    let groupedEntryID = try #require(context.networkRequestGroupID(containing: playlistID))
    let unrelatedEntryID = try #require(context.networkRequestGroupID(containing: unrelatedID))

    #expect(model.requests.snapshot.sectionIDs == [unrelatedEntryID, groupedEntryID])
    #expect(model.requests.snapshot.itemIDs == [unrelatedID, playlistID, segmentID])
    #expect(model.requests[section: groupedEntryID]?.items.map(\.id) == [playlistID, segmentID])

    model.selectRequest(try context.networkRequest(id: segmentID))
    #expect(model.selectedEntryID == groupedEntryID)
    #expect(model.selectedRequests.map(\.id) == [playlistID, segmentID])
}

@Test
@MainActor
func filteringOneGroupMemberKeepsTheWholeEntryForDetail() async throws {
    let context = makeContext()
    let nodeID = DOM.Node.ID("video")
    let playlistID = await applyRequest(
        to: context,
        requestID: "playlist",
        url: "https://media.example.com/master.m3u8",
        resourceType: .media,
        mimeType: "application/vnd.apple.mpegurl",
        timestamp: 1,
        initiatorNodeID: nodeID
    )
    let segmentID = await applyRequest(
        to: context,
        requestID: "segment",
        url: "https://media.example.com/unique-segment.ts",
        resourceType: .media,
        mimeType: "video/mp2t",
        timestamp: 2,
        initiatorNodeID: nodeID
    )
    let model = try await NetworkPanelModel.make(context: context)
    let groupedEntryID = try #require(context.networkRequestGroupID(containing: playlistID))

    model.setSearchText("unique-segment")
    await model.waitForQueryUpdates()

    #expect(model.requests.snapshot.sectionIDs == [groupedEntryID])
    #expect(model.requests.snapshot.itemIDs == [playlistID, segmentID])
    #expect(model.requests[section: groupedEntryID]?.items.map(\.id) == [playlistID, segmentID])
}

@Test
@MainActor
func filteredOutSelectionReceivesLaterMembersFromTheUnfilteredStore() async throws {
    let context = makeContext()
    let nodeID = DOM.Node.ID("video-selection")
    let playlistID = await applyRequest(
        to: context,
        requestID: "playlist",
        url: "https://media.example.com/master.m3u8",
        resourceType: .media,
        mimeType: "application/vnd.apple.mpegurl",
        timestamp: 1,
        initiatorNodeID: nodeID
    )
    let model = try await NetworkPanelModel.make(context: context)
    let groupID = try #require(context.networkRequestGroupID(containing: playlistID))
    model.selectEntry(groupID)
    let selectionToken = try #require(model.selectionToken)

    model.setSearchText("does-not-match")
    await model.waitForQueryUpdates()
    #expect(model.requests.snapshot.sections.isEmpty)
    #expect(model.selectedRequests.map(\.id) == [playlistID])

    let segmentID = await applyRequest(
        to: context,
        requestID: "segment",
        url: "https://media.example.com/segment-1.ts",
        resourceType: .media,
        mimeType: "video/mp2t",
        timestamp: 2,
        initiatorNodeID: nodeID
    )

    #expect(model.requests.snapshot.sections.isEmpty)
    #expect(model.selectionToken == selectionToken)
    #expect(model.selectedEntryID == groupID)
    #expect(model.selectedRequests.map(\.id) == [playlistID, segmentID])
}

@Test
@MainActor
func reseedingTheSameRawGroupCreatesANewSelectionEpoch() async throws {
    let context = makeContext()
    let nodeID = DOM.Node.ID("stable-node")
    let firstID = await applyRequest(
        to: context,
        requestID: "first",
        url: "https://media.example.com/first.ts",
        resourceType: .media,
        mimeType: "video/mp2t",
        timestamp: 1,
        initiatorNodeID: nodeID
    )
    let model = try await NetworkPanelModel.make(context: context)
    model.selectRequest(try context.networkRequest(id: firstID))
    let oldToken = try #require(model.selectionToken)

    await context.clearNetworkRequests()
    #expect(model.selectedEntryID == nil)

    let replacementID = await applyRequest(
        to: context,
        requestID: "replacement",
        url: "https://media.example.com/replacement.ts",
        resourceType: .media,
        mimeType: "video/mp2t",
        timestamp: 2,
        initiatorNodeID: nodeID
    )
    let replacementGroupID = try #require(context.networkRequestGroupID(containing: replacementID))
    model.selectEntry(replacementGroupID)
    let replacementToken = try #require(model.selectionToken)

    #expect(replacementToken.groupID == oldToken.groupID)
    #expect(replacementToken.sourceEpoch != oldToken.sourceEpoch)
    #expect(replacementToken != oldToken)

    model.clearSelection(ifStillSelected: oldToken)
    #expect(model.selectionToken == replacementToken)
    #expect(model.selectedEntryID == replacementGroupID)
}

@Test
@MainActor
func thousandMemberGroupRemainsOneEntryWithStoreBackedDetailMembers() async throws {
    let context = makeContext()
    let nodeID = DOM.Node.ID("large-media-group")
    var requestIDs: [NetworkRequest.ID] = []
    requestIDs.reserveCapacity(1_000)
    for index in 0..<1_000 {
        requestIDs.append(context.seedNetworkRequest(
            requestID: "segment-\(index)",
            url: "https://media.example.com/segment-\(index).ts",
            resourceTypeRawValue: "Media",
            responseMIMEType: "video/mp2t",
            responseStatus: 200,
            responseStatusText: "OK",
            initiator: Network.Initiator(kind: "other", nodeID: nodeID),
            timestamp: Double(index)
        ))
    }
    let model = try await NetworkPanelModel.make(context: context)
    let groupID = try #require(context.networkRequestGroupID(containing: requestIDs[0]))

    #expect(model.requests.snapshot.sectionIDs == [groupID])
    #expect(model.requests[section: groupID]?.items.count == 1_000)
    #expect(context.networkRequestGroup(id: groupID)?.items.count == 1_000)

    model.selectEntry(groupID)
    #expect(model.selectedRequests.count == 1_000)
    #expect(model.selectedRequests.map(\.id) == requestIDs)
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
    let model = try await NetworkPanelModel.make(context: context)

    model.setSearchText("cdn")
    model.setResourceFilter(.script, enabled: true)
    model.selectRequest(try context.networkRequest(id: requestID))
    model.clearRequests()
    await model.waitForQueryUpdates()

    #expect(model.selectionToken == nil)
    #expect(model.searchText == "cdn")
    #expect(model.activeResourceFilters == [.script])
    #expect(model.requests.snapshot.sections.isEmpty)
    #expect(try context.networkRequest(id: requestID) == nil)
}

}

@MainActor
private func makeContext() -> WebInspectorModelContext {
    WebInspectorModelContext.preview()
}

@MainActor
@discardableResult
private func applyRequest(
    to context: WebInspectorModelContext,
    requestID rawRequestID: String,
    url: String,
    method: String = "GET",
    resourceType: Network.ResourceType,
    mimeType: String?,
    responseHeaders: [String: String] = [:],
    status: Int = 200,
    statusText: String = "OK",
    timestamp: Double,
    initiatorNodeID: DOM.Node.ID? = nil
) async -> NetworkRequest.ID {
    let requestID = await applyPendingRequest(
        to: context,
        requestID: rawRequestID,
        url: url,
        method: method,
        resourceType: resourceType,
        timestamp: timestamp,
        initiatorNodeID: initiatorNodeID
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
    to context: WebInspectorModelContext,
    requestID rawRequestID: String,
    url: String,
    method: String = "GET",
    resourceType: Network.ResourceType,
    timestamp: Double,
    initiatorNodeID: DOM.Node.ID? = nil
) async -> NetworkRequest.ID {
    let requestID = Network.Request.ID(rawRequestID)
    await context.apply(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(id: requestID, url: url, method: method),
            initiator: Network.Initiator(kind: "other", nodeID: initiatorNodeID),
            resourceType: resourceType,
            redirectResponse: nil,
            timestamp: timestamp
        )
    )
    return context.registeredRequest(forProxyID: requestID)!.id
}

@MainActor
private func applyRedirectRequest(
    to context: WebInspectorModelContext,
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
            initiator: Network.Initiator(kind: "other"),
            resourceType: resourceType,
            redirectResponse: Network.Response(url: redirectURL, status: 302),
            timestamp: timestamp
        )
    )
}

@MainActor
private func applyResponseReceived(
    to context: WebInspectorModelContext,
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
    to context: WebInspectorModelContext,
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
    to context: WebInspectorModelContext,
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
