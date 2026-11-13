#if canImport(UIKit)
import AVFoundation
import ObservationBridge
import Synchronization
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import UIKit
@testable import WebInspectorKit
@testable import WebInspectorUINetwork
@testable import WebInspectorUIBase

extension WebInspectorUIRenderingTests {
@MainActor
@Suite
struct NetworkDetailMediaPreviewTests: NetworkDetailTestSupport {
    @Test
    func groupedPreviewTreatsNonMediaErrorResponseAsInspectable() async throws {
        let context = makeContext()
        let frameID = FrameID("main-frame")
        let nodeID = DOM.Node.ID("grouped-error-response")
        installNavigationVisit(in: context, frameID: frameID)
        let successfulRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "successful-json",
            url: "https://example.com/success.json",
            frameID: frameID,
            initiatorNodeID: nodeID,
            responseHeaders: ["content-type": "application/json"],
            responseMIMEType: "application/json",
            resourceType: .xhr,
            timestamp: 1
        ))
        let errorRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "error-json",
            url: "https://example.com/error.json",
            frameID: frameID,
            initiatorNodeID: nodeID,
            responseHeaders: ["content-type": "application/json"],
            responseMIMEType: "application/json",
            responseStatus: 404,
            resourceType: .xhr,
            timestamp: 4
        ))
        applyResponseBody(
            to: context,
            request: successfulRequest,
            body: #"{"result":"success"}"#,
            base64Encoded: false
        )
        applyResponseBody(
            to: context,
            request: errorRequest,
            body: #"{"error":"not found"}"#,
            base64Encoded: false
        )
        let model = NetworkPanelModel(context: context)
        try selectEntry(containing: errorRequest, in: model)
        let viewController = NetworkDetailViewController(
            model: model,
            initialMode: .preview
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(await waitUntilPreparedTextPreviewRendered(in: viewController) {
            viewController.previewRequestIDForTesting == errorRequest.id
                && viewController.bodyViewControllerForTesting
                    .syntaxViewForTesting.text.contains(#""error" : "not found""#)
        })
        #expect(model.selectedEntryRequests.map(\.id) == [successfulRequest.id, errorRequest.id])
    }

    @Test
    func hlsResponsePreviewCoordinatorUsesOriginalPlaylistURL() throws {
        let playlistURL = "https://media.example.com/live/master.m3u8"
        let body = NetworkBody(
            role: .response,
            kind: .binary,
            full: """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=1280000
            media/playlist.m3u8
            """,
            sourceSyntaxKind: .plainText,
            phase: .loaded
        )
        let coordinator = NetworkMediaPreviewCoordinator()

        let action = coordinator.preparePreview(
            for: body,
            metadata: NetworkMediaPreviewMetadata(
                mimeType: "application/vnd.apple.mpegurl",
                url: playlistURL,
                sourcePolicy: .preferredRemotePlayback(try #require(URL(string: playlistURL))),
                remotePlaybackHTTPUserAgent: "Inspector Fixture"
            )
        ) { _ in
            Issue.record("HLS response preview should not require body payload preparation")
        }

        guard case .remoteMovie(let preview) = action else {
            Issue.record("Expected HLS response preview to use the remote playlist URL")
            return
        }
        #expect(preview.url.absoluteString == playlistURL)
        #expect(preview.httpUserAgent == "Inspector Fixture")
    }

    @Test
    func hlsResponsePreviewCoordinatorUsesPlaylistURLBeforeBodyLoads() throws {
        let playlistURL = "https://media.example.com/live/master.m3u8"
        let body = NetworkBody(
            role: .response,
            kind: .binary,
            sourceSyntaxKind: .plainText,
            phase: .available
        )
        let coordinator = NetworkMediaPreviewCoordinator()

        let action = coordinator.preparePreview(
            for: body,
            metadata: NetworkMediaPreviewMetadata(
                mimeType: "application/vnd.apple.mpegurl",
                url: playlistURL,
                sourcePolicy: .preferredRemotePlayback(try #require(URL(string: playlistURL)))
            )
        ) { _ in
            Issue.record("HLS response preview should not fetch or prepare body payloads")
        }

        guard case .remoteMovie(let preview) = action else {
            Issue.record("Expected HLS response preview to use the remote playlist URL before the body loads")
            return
        }
        #expect(preview.url.absoluteString == playlistURL)
    }

    @Test
    func remoteHLSPreviewShowsPlayerWithoutFetchingResponseBody() async throws {
        let context = makeContext()
        let playlistURL = "https://media.example.com/live/master.m3u8"
        let request = try #require(
            await applyRequest(
                to: context,
                requestID: "playlist",
                url: playlistURL,
                requestHeaders: ["User-Agent": "Inspector Fixture"],
                responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
                responseMimeType: "application/vnd.apple.mpegurl"
            )
        )
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.bodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didShowPlayer = await waitUntilRendered(in: viewController) {
            viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting?.absoluteString
                == playlistURL
        }
        #expect(didShowPlayer)
        #expect(playerFactory.players.count == 1)
        #expect(request.responseBody.phase == .available)
        #expect(viewController.responseBodyFetchObservationDeliveryForTesting == nil)
    }

    @Test
    func hlsPlaybackFailureKeepsPlayerSurfaceUntilSurfaceTeardown() async throws {
        let playlistURL = "https://media.example.com/live/failing.m3u8"
        let body = NetworkBody(
            role: .response,
            kind: .binary,
            sourceSyntaxKind: .plainText,
            phase: .available
        )
        let viewController = NetworkBodyViewController()
        viewController.setSurface(.body(
            body,
            metadata: NetworkMediaPreviewMetadata(
                mimeType: "application/vnd.apple.mpegurl",
                url: playlistURL,
                sourcePolicy: .preferredRemotePlayback(
                    try #require(URL(string: playlistURL))
                )
            )
        ))
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.resumeRendering()

        let item = try #require(viewController.mediaPlayerItemForTesting)
        #expect(viewController.mediaPlayerURLForTesting?.absoluteString == playlistURL)
        #expect(viewController.hasMoviePreviewObservationForTesting)
        let playerViewControllerIdentity = try #require(
            viewController.mediaPlayerViewControllerIdentityForTesting
        )
        let observation = try #require(viewController.previewRenderObservationDeliveryForTesting)
        let renderedFailure = await observation.values {
            viewController.isMoviePreviewStatusVisibleForTesting
                && viewController.mediaPlayerStatusConfigurationForTesting?.secondaryText
                    == "Simulated HLS playback failure."
        }
        defer { renderedFailure.cancel() }

        let failureHandled = ReplyPromise<Void>()
        viewController.setMoviePreviewFailureHandlerForTesting {
            failureHandled.fulfill(.success(()))
        }
        defer { viewController.setMoviePreviewFailureHandlerForTesting(nil) }
        viewController.suspendKeepingSurface()
        NotificationCenter.default.post(
            name: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            userInfo: [
                AVPlayerItemFailedToPlayToEndTimeErrorKey: NSError(
                    domain: "WebInspectorUITests",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Simulated HLS playback failure."
                    ]
                )
            ]
        )

        try await waitForUITestSignal(failureHandled)
        #expect(viewController.hasMoviePreviewFailureForTesting)
        #expect(viewController.isMoviePreviewStatusVisibleForTesting == false)
        #expect(viewController.mediaPlayerViewControllerIdentityForTesting == playerViewControllerIdentity)

        viewController.resumeRendering()
        #expect(await renderedFailure.waitUntil { $0 } != nil)
        #expect(viewController.mediaPlayerViewControllerIdentityForTesting == playerViewControllerIdentity)
        #expect(viewController.mediaPlayerItemForTesting == nil)
        #expect(viewController.hasMoviePreviewObservationForTesting == false)
        #expect(viewController.isMoviePreviewStatusHostedInPlayerOverlayForTesting)

        viewController.setSurface(.unavailableBodyPlaceholder)

        #expect(viewController.mediaPlayerViewControllerIdentityForTesting == nil)
        #expect(viewController.mediaPlayerItemForTesting == nil)
        #expect(viewController.hasMoviePreviewObservationForTesting == false)
    }

    @Test
    func nonBodyMediaResponseDoesNotStartPlaybackOrFetch() async throws {
        let inputs: [(
            name: String,
            pathExtension: String,
            mimeType: String,
            method: String,
            status: Int,
            finishes: Bool
        )] = [
            ("HLS HEAD", "m3u8", "application/vnd.apple.mpegurl", "HEAD", 200, true),
            ("HLS 204", "m3u8", "application/vnd.apple.mpegurl", "GET", 204, true),
            ("HLS 404", "m3u8", "application/vnd.apple.mpegurl", "GET", 404, true),
            ("MP4 HEAD", "mp4", "video/mp4", "HEAD", 200, true),
            ("MP4 204", "mp4", "video/mp4", "GET", 204, true),
            ("MP4 404", "mp4", "video/mp4", "GET", 404, true),
            ("MP4 incomplete", "mp4", "video/mp4", "GET", 200, false),
        ]

        for (index, input) in inputs.enumerated() {
            let context = makeContext()
            let request = try #require(await applyRequest(
                to: context,
                requestID: "unavailable-media-\(index)",
                url: "https://media.example.com/unavailable-\(index).\(input.pathExtension)",
                responseHeaders: ["content-type": input.mimeType],
                responseMimeType: input.mimeType,
                responseStatus: input.status,
                resourceType: .media,
                method: input.method,
                finishes: input.finishes
            ))
            let model = NetworkPanelModel(context: context)
            model.selectRequest(request)
            let viewController = NetworkDetailViewController(
                model: model,
                initialMode: .preview
            )
            var playerCreationCount = 0
            viewController.bodyViewControllerForTesting
                .setMoviePreviewPlayerFactoryForTesting {
                    playerCreationCount += 1
                    return StubMoviePreviewPlayer()
                }
            let window = showInWindow(viewController)
            defer { window.isHidden = true }

            #expect(await waitUntilRendered(in: viewController) {
                viewController.currentModeForTesting == .preview
                    && viewController.bodyViewControllerForTesting
                        .syntaxViewForTesting.text.isEmpty == false
                    && viewController.responseBodyFetchObservationDeliveryForTesting == nil
            }, Comment(rawValue: input.name))
            #expect(
                viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting == nil,
                Comment(rawValue: input.name)
            )
            #expect(playerCreationCount == 0, Comment(rawValue: input.name))
            #expect(request.responseBody.phase == .available, Comment(rawValue: input.name))
        }
    }

    @Test
    func unsafeHLSRequestShowsFetchedPlaylistTextInsteadOfRemotePlayer() async throws {
        let context = makeContext()
        let playlistURL = "https://media.example.com/live/master.m3u8"
        let request = try #require(await applyRequest(
            to: context,
            requestID: "unsafe-playlist",
            url: playlistURL,
            requestHeaders: ["Referer": "https://media.example.com/player"],
            responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
            responseMimeType: "application/vnd.apple.mpegurl"
        ))
        let playlist = """
        #EXTM3U
        #EXTINF:1.0,
        segment.ts
        """
        let encodedPlaylist = Data(playlist.utf8).base64EncodedString()
        applyResponseBody(
            to: context,
            request: request,
            body: encodedPlaylist,
            base64Encoded: true
        )
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.bodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didShowPlaylistText = await waitUntilPreparedTextPreviewRendered(in: viewController) {
            viewController.bodyViewControllerForTesting.syntaxViewForTesting.text == playlist
        }

        #expect(didShowPlaylistText)
        guard case .loaded = request.responseBody.phase else {
            Issue.record("Unsafe HLS should fetch its response body for syntax display")
            return
        }
        #expect(viewController.responseBodyFetchObservationDeliveryForTesting != nil)
        #expect(viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting == nil)
        #expect(playerFactory.players.isEmpty)
    }

    @Test
    func partialMoviePreviewUsesRemoteURLWithoutFetchingResponseBody() async throws {
        let context = makeContext()
        let movieURL = "https://media.example.com/segment.mp4"
        let request = try #require(await applyRequest(
            to: context,
            requestID: "partial-movie",
            url: movieURL,
            responseHeaders: [
                "content-type": "video/mp4",
                "content-range": "bytes 0-1023/4096",
            ],
            responseMimeType: "video/mp4",
            responseStatus: 206,
            resourceType: .media
        ))
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.bodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didShowRemoteMovie = await waitUntilRendered(in: viewController) {
            viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting?.absoluteString
                == movieURL
        }

        #expect(didShowRemoteMovie)
        #expect(request.responseBody.phase == .available)
        #expect(viewController.responseBodyFetchObservationDeliveryForTesting == nil)
    }

    @Test
    func partialMoviePreviewDoesNotReplayUnrepeatableOrUnsatisfiedRequests() async throws {
        let inputs: [(
            id: String,
            requestHeaders: [String: String],
            postData: String?,
            responseHeaders: [String: String],
            responseStatus: Int
        )] = [
            (
                id: "partial-post",
                requestHeaders: [:],
                postData: "media request body",
                responseHeaders: ["content-type": "video/mp4"],
                responseStatus: 206
            ),
            (
                id: "partial-authorization",
                requestHeaders: ["Authorization": "Bearer fixture"],
                postData: nil,
                responseHeaders: ["content-type": "video/mp4"],
                responseStatus: 206
            ),
            (
                id: "partial-custom-header",
                requestHeaders: ["X-Media-Token": "fixture"],
                postData: nil,
                responseHeaders: ["content-type": "video/mp4"],
                responseStatus: 206
            ),
            (
                id: "unsatisfied-range",
                requestHeaders: [:],
                postData: nil,
                responseHeaders: [
                    "content-type": "video/mp4",
                    "content-range": "bytes */1024",
                ],
                responseStatus: 416
            ),
        ]

        for input in inputs {
            let context = makeContext()
            let request = try #require(await applyRequest(
                to: context,
                requestID: input.id,
                url: "https://media.example.com/\(input.id).mp4",
                requestHeaders: input.requestHeaders,
                postData: input.postData,
                responseHeaders: input.responseHeaders,
                responseMimeType: "video/mp4",
                responseStatus: input.responseStatus,
                resourceType: .media
            ))
            let model = NetworkPanelModel(context: context)
            model.selectRequest(request)
            let viewController = NetworkDetailViewController(model: model)
            let window = showInWindow(viewController)
            defer { window.isHidden = true }
            viewController.setModeForTesting(.preview)

            let didSettleWithoutRemotePlayback = await waitUntilRendered(in: viewController) {
                guard viewController.currentModeForTesting == .preview,
                      viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting == nil,
                      viewController.responseBodyFetchObservationDeliveryForTesting == nil else {
                    return false
                }
                if input.responseStatus == 416 {
                    return request.responseBody.phase == .available
                }
                if case .failed = request.responseBody.phase {
                    return true
                }
                return false
            }

            #expect(didSettleWithoutRemotePlayback, Comment(rawValue: input.id))
            #expect(
                viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting == nil,
                Comment(rawValue: input.id)
            )
        }
    }

    @Test
    func failedMoviePayloadPreparationRemainsMemoized() async throws {
        let body = NetworkBody(
            role: .response,
            kind: .binary,
            full: "not valid base64",
            isBase64Encoded: true,
            sourceSyntaxKind: .plainText,
            phase: .loaded
        )
        let metadata = NetworkMediaPreviewMetadata(
            mimeType: "video/mp4",
            url: "https://media.example.com/movie.mp4",
            sourcePolicy: .body
        )
        let coordinator = NetworkMediaPreviewCoordinator()
        var resultCount = 0

        let firstAction = coordinator.preparePreview(for: body, metadata: metadata) { action in
            guard case .fallback = action else {
                Issue.record("Invalid movie payload preparation should fail")
                return
            }
            resultCount += 1
        }
        guard case .loadingMovie = firstAction else {
            Issue.record("A movie payload should install its loading surface before preparation")
            return
        }
        await coordinator.waitUntilPreparationFinishedForTesting()
        #expect(resultCount == 1)

        for _ in 0..<2 {
            let repeatedAction = coordinator.preparePreview(
                for: body,
                metadata: metadata
            ) { _ in
                resultCount += 1
            }
            guard case .unavailableMovie = repeatedAction else {
                Issue.record("A failed movie payload should remain unavailable without re-preparation")
                return
            }
        }
        await coordinator.waitUntilPreparationFinishedForTesting()
        #expect(resultCount == 1)
    }

    @Test
    func movieBodySurfaceKeepsPlayerIdentityWhileBodyLoads() async throws {
        let context = makeContext()
        let request = try #require(await applyRequest(
            to: context,
            requestID: "loading-movie",
            url: "https://media.example.com/movie.mp4",
            responseHeaders: ["content-type": "video/mp4"],
            responseMimeType: "video/mp4",
            resourceType: .media
        ))
        let playerFactory = MoviePreviewPlayerFactorySpy()
        let viewController = NetworkBodyViewController()
        viewController.setMoviePreviewPlayerFactoryForTesting(playerFactory.makePlayer)
        viewController.setSurface(.body(
            request.responseBody,
            metadata: NetworkMediaPreviewMetadata(
                mimeType: "video/mp4",
                url: request.url,
                sourcePolicy: .body
            )
        ))
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.resumeRendering()

        let playerViewControllerIdentity = try #require(
            viewController.mediaPlayerViewControllerIdentityForTesting
        )
        let loadingPlayerIdentity = try #require(viewController.mediaPlayerIdentityForTesting)
        #expect(viewController.mediaPlayerItemForTesting == nil)
        #expect(viewController.isMoviePreviewStatusVisibleForTesting)
        #expect(viewController.moviePreviewStatusForTesting == .loading)
        #expect(viewController.isMoviePreviewStatusHostedInPlayerOverlayForTesting)
        let renderObservation = try #require(viewController.previewRenderObservationDeliveryForTesting)
        let renderedMovie = await renderObservation.values {
            viewController.mediaPlayerItemForTesting != nil
                && viewController.moviePreviewStatusForTesting == nil
        }
        defer { renderedMovie.cancel() }
        applyResponseBody(
            to: context,
            request: request,
            body: "movie payload",
            base64Encoded: false
        )

        #expect(await renderedMovie.waitUntil { $0 } != nil)
        #expect(viewController.mediaPlayerViewControllerIdentityForTesting == playerViewControllerIdentity)
        #expect(viewController.mediaPlayerIdentityForTesting == loadingPlayerIdentity)
        #expect(viewController.mediaPlayerItemForTesting != nil)
        #expect(viewController.mediaPlayerURLForTesting?.pathExtension == "mp4")
        #expect(viewController.isMoviePreviewStatusVisibleForTesting == false)
        #expect(playerFactory.players.count == 1)

        let renderedLoading = await renderObservation.values {
            viewController.mediaPlayerItemForTesting == nil
                && viewController.isMoviePreviewStatusVisibleForTesting
                && viewController.moviePreviewStatusForTesting == .loading
        }
        defer { renderedLoading.cancel() }
        await applyResponseReceived(
            to: context,
            requestID: "loading-movie",
            url: request.url,
            responseHeaders: ["content-type": "video/mp4"],
            responseMimeType: "video/mp4",
            timestamp: 4
        )

        #expect(await renderedLoading.waitUntil { $0 } != nil)
        #expect(viewController.mediaPlayerViewControllerIdentityForTesting == playerViewControllerIdentity)
        #expect(viewController.mediaPlayerIdentityForTesting == loadingPlayerIdentity)
        #expect(playerFactory.players.count == 1)

        let renderedUnavailable = await renderObservation.values {
            viewController.mediaPlayerItemForTesting == nil
                && viewController.isMoviePreviewStatusVisibleForTesting
                && viewController.moviePreviewStatusForTesting == .unavailable
        }
        defer { renderedUnavailable.cancel() }
        applyResponseBody(
            to: context,
            request: request,
            body: "",
            base64Encoded: false
        )
        await viewController.waitUntilMediaPreviewPreparationFinishedForTesting()

        #expect(await renderedUnavailable.waitUntil { $0 } != nil)
        #expect(viewController.mediaPlayerViewControllerIdentityForTesting == playerViewControllerIdentity)
        #expect(viewController.mediaPlayerIdentityForTesting == loadingPlayerIdentity)
        #expect(playerFactory.players.count == 1)
    }

    @Test
    func hlsRequestBodyPreviewCoordinatorDoesNotUseRemotePlaylist() throws {
        let body = NetworkBody(
            role: .request,
            kind: .text,
            full: """
            #EXTM3U
            #EXT-X-VERSION:3
            """,
            sourceSyntaxKind: .plainText,
            phase: .loaded
        )
        let coordinator = NetworkMediaPreviewCoordinator()

        let action = coordinator.preparePreview(
            for: body,
            metadata: NetworkMediaPreviewMetadata(
                mimeType: nil,
                url: "https://media.example.com/upload.m3u8",
                sourcePolicy: .body
            )
        ) { _ in
            Issue.record("HLS request bodies should stay on the syntax preview path")
        }

        guard case .unavailable = action else {
            Issue.record("Expected HLS request bodies to avoid remote movie preview")
            return
        }
    }

    @Test
    func mediaResponsePreviewReleasesPlayerAndTemporaryFileWhenShowingHeaders() async throws {
        let context = makeContext()
        let request = try #require(
            await applyRequest(
                to: context,
                requestID: "1",
                url: "https://media.example.com/download.php",
                responseHeaders: ["content-type": "video/mp4"],
                responseMimeType: "video/mp4"
            )
        )
        applyResponseBody(to: context, request: request, body: "not a real movie", base64Encoded: false)
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.bodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)
        await waitUntilMediaPreviewPrepared(in: viewController)

        let didRenderMediaPreview = await waitUntilRendered(in: viewController) {
            viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting?.pathExtension == "mp4"
        }
        #expect(didRenderMediaPreview)
        let temporaryFileURL = try #require(viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting)
        #expect(playerFactory.players.count == 1)
        #expect(FileManager.default.fileExists(atPath: temporaryFileURL.path))

        viewController.setModeForTesting(.headers)

        let didReleaseMediaPreview = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .headers
                && viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting == nil
                && FileManager.default.fileExists(atPath: temporaryFileURL.path) == false
        }
        #expect(didReleaseMediaPreview)
        #expect(playerFactory.players.count == 1)

        viewController.setModeForTesting(.preview)
        await waitUntilMediaPreviewPrepared(in: viewController)

        let didRestoreMediaPreview = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .preview
                && viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting?.pathExtension == "mp4"
        }
        #expect(didRestoreMediaPreview)
        #expect(playerFactory.players.count == 2)
    }

    @Test
    func mediaResponsePreviewReusesPlayerAndTemporaryFileWhenRequestUpdateDoesNotChangeBody() async throws {
        let context = makeContext()
        let request = try #require(
            await applyRequest(
                to: context,
                requestID: "1",
                url: "https://media.example.com/download.php",
                responseHeaders: ["content-type": "video/mp4"],
                responseMimeType: "video/mp4"
            )
        )
        applyResponseBody(to: context, request: request, body: "not a real movie", base64Encoded: false)
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.bodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)
        await waitUntilMediaPreviewPrepared(in: viewController)

        let didRenderMediaPreview = await waitUntilRendered(in: viewController) {
            viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting?.pathExtension == "mp4"
                && viewController.bodyViewControllerForTesting.mediaPlayerIdentityForTesting != nil
        }
        #expect(didRenderMediaPreview)
        let temporaryFileURL = try #require(viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting)
        let playerIdentity = try #require(viewController.bodyViewControllerForTesting.mediaPlayerIdentityForTesting)
        #expect(playerFactory.players.count == 1)

        await applyDataReceived(
            to: context,
            requestID: "1",
            dataLength: 128,
            encodedDataLength: 64,
            timestamp: 4
        )

        #expect(request.encodedDataLength == 64)
        #expect(viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting == temporaryFileURL)
        #expect(viewController.bodyViewControllerForTesting.mediaPlayerIdentityForTesting == playerIdentity)
        #expect(FileManager.default.fileExists(atPath: temporaryFileURL.path))
        #expect(playerFactory.players.count == 1)
    }

    @Test
    func mediaPreviewCoordinatorReusesTemporaryFileForEquivalentBodyPublication() async throws {
        let body = NetworkBody(
            role: .response,
            kind: .binary,
            full: "not a real movie",
            isBase64Encoded: false,
            sourceSyntaxKind: .plainText,
            phase: .loaded
        )
        let metadata = NetworkMediaPreviewMetadata(
            mimeType: "video/mp4",
            url: "https://media.example.com/download.php",
            sourcePolicy: .body
        )
        let coordinator = NetworkMediaPreviewCoordinator()
        var publishedPreviews: [NetworkMoviePreview] = []

        let firstAction = coordinator.preparePreview(for: body, metadata: metadata) { result in
            guard case .showMovie(let preview) = result else {
                Issue.record("Movie preparation should publish a temporary-file preview")
                return
            }
            publishedPreviews.append(preview)
        }
        guard case .loadingMovie = firstAction else {
            Issue.record("The first movie body publication should start preparation")
            return
        }
        await coordinator.waitUntilPreparationFinishedForTesting()

        let firstPreview = try #require(publishedPreviews.first)
        #expect(FileManager.default.fileExists(atPath: firstPreview.url.path))

        let equivalentAction = coordinator.preparePreview(for: body, metadata: metadata) { _ in
            Issue.record("An equivalent body publication should reuse the prepared preview")
        }
        guard case .active = equivalentAction else {
            Issue.record("An equivalent body publication should keep the active preview")
            return
        }
        #expect(publishedPreviews.count == 1)
        #expect(FileManager.default.fileExists(atPath: firstPreview.url.path))

        coordinator.cancel()
        #expect(FileManager.default.fileExists(atPath: firstPreview.url.path) == false)
    }

    @Test
    func mediaResponsePreviewPausesPlayerButKeepsSurfaceWhenHidden() async throws {
        let context = makeContext()
        let request = try #require(
            await applyRequest(
                to: context,
                requestID: "1",
                url: "https://media.example.com/download.php",
                responseHeaders: ["content-type": "video/mp4"],
                responseMimeType: "video/mp4"
            )
        )
        applyResponseBody(to: context, request: request, body: "not a real movie", base64Encoded: false)
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.bodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)
        await waitUntilMediaPreviewPrepared(in: viewController)

        let didRenderMediaPreview = await waitUntilRendered(in: viewController) {
            viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting?.pathExtension == "mp4"
        }
        #expect(didRenderMediaPreview)
        let temporaryFileURL = try #require(viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting)
        let player = try #require(playerFactory.players.first)
        #expect(playerFactory.players.count == 1)
        #expect(player.pauseCallCount == 0)
        #expect(FileManager.default.fileExists(atPath: temporaryFileURL.path))

        viewController.beginAppearanceTransition(false, animated: false)
        viewController.endAppearanceTransition()

        #expect(player.pauseCallCount == 1)
        #expect(viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting == temporaryFileURL)
        #expect(FileManager.default.fileExists(atPath: temporaryFileURL.path))

        viewController.beginAppearanceTransition(true, animated: false)
        viewController.endAppearanceTransition()
        await waitUntilMediaPreviewPrepared(in: viewController)

        #expect(playerFactory.players.count == 1)
        #expect(viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting == temporaryFileURL)
        #expect(player.pauseCallCount == 1)
    }

    @Test
    func mediaResponsePreviewReleasesPlayerAndTemporaryFileWhenSelectionClears() async throws {
        let context = makeContext()
        let request = try #require(
            await applyRequest(
                to: context,
                requestID: "1",
                url: "https://media.example.com/download.php",
                responseHeaders: ["content-type": "video/mp4"],
                responseMimeType: "video/mp4"
            )
        )
        applyResponseBody(to: context, request: request, body: "not a real movie", base64Encoded: false)
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.bodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)
        await waitUntilMediaPreviewPrepared(in: viewController)

        let didRenderMediaPreview = await waitUntilRendered(in: viewController) {
            viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting?.pathExtension == "mp4"
        }
        #expect(didRenderMediaPreview)
        let temporaryFileURL = try #require(viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting)
        #expect(playerFactory.players.count == 1)
        #expect(FileManager.default.fileExists(atPath: temporaryFileURL.path))

        model.selectRequest(nil)

        let didReleaseMediaPreview = await waitUntilRendered(in: viewController) {
            viewController.contentUnavailableConfiguration != nil
                && viewController.previewViewForTesting.isHidden
                && viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting == nil
                && FileManager.default.fileExists(atPath: temporaryFileURL.path) == false
        }
        #expect(didReleaseMediaPreview)
        #expect(playerFactory.players.count == 1)
    }

    @Test
    func hiddenMediaResponsePreviewReleasesPlayerAndTemporaryFileWhenSelectionClearsBeforeReappearing() async throws {
        let context = makeContext()
        let request = try #require(
            await applyRequest(
                to: context,
                requestID: "1",
                url: "https://media.example.com/download.php",
                responseHeaders: ["content-type": "video/mp4"],
                responseMimeType: "video/mp4"
            )
        )
        applyResponseBody(to: context, request: request, body: "not a real movie", base64Encoded: false)
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.bodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)
        await waitUntilMediaPreviewPrepared(in: viewController)

        let didRenderMediaPreview = await waitUntilRendered(in: viewController) {
            viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting?.pathExtension == "mp4"
        }
        #expect(didRenderMediaPreview)
        let temporaryFileURL = try #require(viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting)
        #expect(playerFactory.players.count == 1)
        #expect(FileManager.default.fileExists(atPath: temporaryFileURL.path))

        viewController.beginAppearanceTransition(false, animated: false)
        viewController.endAppearanceTransition()
        model.selectRequest(nil)

        #expect(viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting == temporaryFileURL)
        #expect(FileManager.default.fileExists(atPath: temporaryFileURL.path))

        viewController.beginAppearanceTransition(true, animated: false)
        viewController.endAppearanceTransition()

        let didReleaseMediaPreview = await waitUntilRendered(in: viewController) {
            viewController.contentUnavailableConfiguration != nil
                && viewController.previewViewForTesting.isHidden
                && viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting == nil
                && FileManager.default.fileExists(atPath: temporaryFileURL.path) == false
        }
        #expect(didReleaseMediaPreview)
        #expect(playerFactory.players.count == 1)
    }

    @Test
    func imageResponsePreviewUsesScrollViewAndFitsLargeImage() async throws {
        let imageSize = CGSize(width: 600, height: 1400)
        let context = makeContext()
        let request = try #require(
            await applyRequest(
                to: context,
                requestID: "1",
                url: "https://media.example.com/large.png",
                postData: "metadata=1",
                responseHeaders: ["content-type": "image/png"],
                responseMimeType: "image/png"
            )
        )
        applyResponseBody(to: context, request: request, body: pngBase64String(size: imageSize), base64Encoded: true)
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        viewController.bodyViewControllerForTesting.additionalSafeAreaInsets = UIEdgeInsets(
            top: 44,
            left: 0,
            bottom: 34,
            right: 0
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)
        await waitUntilMediaPreviewPrepared(in: viewController)

        let didRenderImage = await waitUntilRendered(in: viewController) {
            let bodyViewController = viewController.bodyViewControllerForTesting
            let imageLayout = bodyViewController.imagePreviewRenderSnapshotForTesting
            let didCompleteImageLayout = imageLayout.map { layout in
                let fitScale = min(
                    layout.visibleBoundsSize.width / layout.imageSize.width,
                    layout.visibleBoundsSize.height / layout.imageSize.height
                )
                let expectedMinimumZoomScale = min(1, fitScale)
                return layout.imageSize == imageSize
                    && abs(layout.minimumZoomScale - expectedMinimumZoomScale) < 0.001
                    && abs(layout.zoomScale - expectedMinimumZoomScale) < 0.001
            } ?? false
            return bodyViewController.isImagePreviewVisibleForTesting
                && bodyViewController.imageViewForTesting.image?.size == imageSize
                && didCompleteImageLayout
        }
        #expect(didRenderImage)

        let imageScrollView = viewController.bodyViewControllerForTesting.imageScrollViewForTesting
        #expect(imageScrollView.contentInsetAdjustmentBehavior == .automatic)
        #expect(imageScrollView.contentAlignmentPoint == CGPoint(x: 0.5, y: 0.5))
        let fitScale = expectedImageFitScale(scrollView: imageScrollView, imageSize: imageSize)
        let expectedMinimumZoomScale = min(1, fitScale)
        #expect(abs(imageScrollView.minimumZoomScale - expectedMinimumZoomScale) < 0.001)
        #expect(abs(imageScrollView.zoomScale - expectedMinimumZoomScale) < 0.001)
        #expect(imageScrollView.maximumZoomScale >= 1)
    }

    @Test
    func imageResponsePreviewKeepsAutoFitWhenBoundsShrink() async throws {
        let imageSize = CGSize(width: 600, height: 1400)
        let context = makeContext()
        let request = try #require(
            await applyRequest(
                to: context,
                requestID: "1",
                url: "https://media.example.com/large.png",
                responseHeaders: ["content-type": "image/png"],
                responseMimeType: "image/png"
            )
        )
        applyResponseBody(to: context, request: request, body: pngBase64String(size: imageSize), base64Encoded: true)
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)
        await waitUntilMediaPreviewPrepared(in: viewController)

        let didRenderImage = await waitUntilRendered(in: viewController) {
            viewController.bodyViewControllerForTesting.isImagePreviewVisibleForTesting
        }
        #expect(didRenderImage)

        let imageScrollView = viewController.bodyViewControllerForTesting.imageScrollViewForTesting
        let initialBounds = imageScrollView.bounds
        let initialMinimumZoomScale = imageScrollView.minimumZoomScale
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        viewController.view.frame = window.bounds
        viewController.view.setNeedsLayout()
        viewController.view.layoutIfNeeded()
        window.layoutIfNeeded()

        let didRefitAfterBoundsChange = await waitUntilRendered(in: viewController) {
            let fitScale = expectedImageFitScale(scrollView: imageScrollView, imageSize: imageSize)
            let expectedMinimumZoomScale = min(1, fitScale)
            return imageScrollView.bounds.height < initialBounds.height
                && expectedMinimumZoomScale < initialMinimumZoomScale
                && abs(imageScrollView.minimumZoomScale - expectedMinimumZoomScale) < 0.001
                && abs(imageScrollView.zoomScale - expectedMinimumZoomScale) < 0.001
        }
        #expect(didRefitAfterBoundsChange)
    }

    @Test
    func smallImageResponsePreviewStaysAtOneXAndCentersImage() async throws {
        let imageSize = CGSize(width: 24, height: 12)
        let context = makeContext()
        let request = try #require(
            await applyRequest(
                to: context,
                requestID: "1",
                url: "https://media.example.com/icon.png",
                responseHeaders: ["content-type": "image/png"],
                responseMimeType: "image/png"
            )
        )
        applyResponseBody(to: context, request: request, body: pngBase64String(size: imageSize), base64Encoded: true)
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)
        await waitUntilMediaPreviewPrepared(in: viewController)

        let didRenderImage = await waitUntilRendered(in: viewController) {
            viewController.bodyViewControllerForTesting.isImagePreviewVisibleForTesting
        }
        #expect(didRenderImage)

        let imageScrollView = viewController.bodyViewControllerForTesting.imageScrollViewForTesting
        #expect(imageScrollView.minimumZoomScale == 1)
        #expect(imageScrollView.zoomScale == 1)
        #expect(imageScrollView.contentInset == .zero)
        #expect(imageScrollView.contentAlignmentPoint == CGPoint(x: 0.5, y: 0.5))
    }

    @Test
    func groupedRequestPreviewActionPromotesRepresentativeInsteadOfRoutingToHLSSibling() async throws {
        let context = makeContext()
        let frameID = FrameID("headers-preview-group")
        let nodeID = DOM.Node.ID("headers-preview-initiator")
        installNavigationVisit(in: context, frameID: frameID)
        let representative = try #require(
            await applyGroupedRequest(
                to: context,
                requestID: "headers-preview-representative",
                url: "https://example.com/submit.json",
                frameID: frameID,
                initiatorNodeID: nodeID,
                requestHeaders: ["Content-Type": "application/json"],
                postData: #"{"member":"representative"}"#,
                responseHeaders: ["content-type": "application/json"],
                responseMIMEType: "application/json",
                resourceType: .fetch,
                timestamp: 1
            ))
        let hlsSibling = try #require(
            await applyGroupedRequest(
                to: context,
                requestID: "headers-preview-hls",
                url: "https://media.example.com/master.m3u8",
                frameID: frameID,
                initiatorNodeID: nodeID,
                requestHeaders: ["Content-Type": "application/json"],
                postData: #"{"member":"hls"}"#,
                responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
                responseMIMEType: "application/vnd.apple.mpegurl",
                resourceType: .media,
                timestamp: 4
            ))
        let model = NetworkPanelModel(context: context)
        try selectEntry(containing: hlsSibling, in: model)
        let viewController = NetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.bodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(
            await waitUntilRendered(in: viewController) {
                let headers = viewController.headersTextViewForTesting
                return model.selectedRequest === representative
                    && headers.renderedTextForTesting.contains("1. submit.json")
                    && headers.renderedTextForTesting.contains("2. master.m3u8")
                    && headers.requestPreviewTagRangesForTesting.count == 1
            })
        let groupedHeaders = viewController.headersTextViewForTesting
        let groupedText = groupedHeaders.renderedTextForTesting as NSString
        let representativeHeadingRange = groupedText.range(of: "1. submit.json")
        let hlsHeadingRange = groupedText.range(of: "2. master.m3u8")
        let groupedTagRange = try #require(groupedHeaders.requestPreviewTagRangesForTesting.first)
        #expect(representativeHeadingRange.location != NSNotFound)
        #expect(hlsHeadingRange.location != NSNotFound)
        #expect(groupedTagRange.location > representativeHeadingRange.location)
        #expect(NSMaxRange(groupedTagRange) < hlsHeadingRange.location)

        viewController.headersTextViewForTesting.activateRequestPreviewForTesting()
        #expect(
            await waitUntilRendered(in: viewController) {
                guard case let .request(_, requestID) = model.selection else {
                    return false
                }
                return requestID == representative.id
                    && model.selectedRequest === representative
                    && viewController.currentModeForTesting == .preview
                    && viewController.currentPreviewRoleForTesting == .request
                    && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text.contains(#""member" : "representative""#)
            })
        #expect(playerFactory.players.isEmpty)
        #expect(representative.responseBody.phase == .available)
        #expect(hlsSibling.responseBody.phase == .available)

        viewController.setModeForTesting(.headers)
        model.selectRequest(hlsSibling)
        #expect(
            await waitUntilRendered(in: viewController) {
                model.selectedRequest === hlsSibling
                    && viewController.currentModeForTesting == .headers
                    && viewController.headersTextViewForTesting.renderedTextForTesting
                        .contains("master.m3u8")
                    && viewController.headersTextViewForTesting.requestPreviewTagRangesForTesting.count == 1
            })

        viewController.headersTextViewForTesting.activateRequestPreviewForTesting()
        #expect(
            await waitUntilRendered(in: viewController) {
                model.selectedRequest === hlsSibling
                    && viewController.currentModeForTesting == .preview
                    && viewController.currentPreviewRoleForTesting == .request
                    && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text.contains(#""member" : "hls""#)
                    && viewController.responseBodyFetchObservationDeliveryForTesting == nil
            })
        #expect(playerFactory.players.isEmpty)
        #expect(representative.responseBody.phase == .available)
        #expect(hlsSibling.responseBody.phase == .available)
    }

    @Test
    func groupedPreviewKeepsMasterPlaylistAheadOfNewerPartialSegment() async throws {
        let context = makeContext()
        let frameID = FrameID("main-frame")
        let nodeID = DOM.Node.ID("grouped-player")
        installNavigationVisit(in: context, frameID: frameID)
        let hlsRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "playlist",
            url: "https://media.example.com/live/master.m3u8",
            frameID: frameID,
            initiatorNodeID: nodeID,
            responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
            responseMIMEType: "application/vnd.apple.mpegurl",
            resourceType: .media,
            timestamp: 1
        ))
        let partialSegmentRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "partial-segment",
            url: "https://media.example.com/segment.mp4",
            frameID: frameID,
            initiatorNodeID: nodeID,
            responseHeaders: [
                "content-type": "video/mp4",
                "content-range": "bytes 0-1023/4096",
            ],
            responseMIMEType: "video/mp4",
            responseStatus: 206,
            resourceType: .media,
            timestamp: 4
        ))
        let model = NetworkPanelModel(context: context)
        try selectEntry(containing: partialSegmentRequest, in: model)
        let viewController = NetworkDetailViewController(model: model, initialMode: .preview)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didSelectHLSPreview = await waitUntilRendered(in: viewController) {
            viewController.previewRequestIDForTesting == hlsRequest.id
                && viewController.currentModeForTesting == .preview
                && viewController.previewViewForTesting.isHidden == false
        }
        #expect(didSelectHLSPreview)
        #expect(model.selectedRequest?.id == hlsRequest.id)
        #expect(model.selectedEntryRequests.map(\.id) == [hlsRequest.id, partialSegmentRequest.id])
    }

    @Test
    func groupedHLSPreviewUsesLatestRequestWhenURLsMatch() async throws {
        let context = makeContext()
        let frameID = FrameID("main-frame")
        let nodeID = DOM.Node.ID("grouped-shared-playlist")
        let playlistURL = "https://media.example.com/shared.m3u8"
        installNavigationVisit(in: context, frameID: frameID)
        let firstRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "first-shared-playlist",
            url: playlistURL,
            frameID: frameID,
            initiatorNodeID: nodeID,
            responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
            responseMIMEType: "application/vnd.apple.mpegurl",
            resourceType: .media,
            timestamp: 1
        ))
        let model = NetworkPanelModel(context: context)
        try selectEntry(containing: firstRequest, in: model)
        let viewController = NetworkDetailViewController(model: model, initialMode: .preview)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.bodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(await waitUntilRendered(in: viewController) {
            viewController.previewRequestIDForTesting == firstRequest.id
                && playerFactory.players.count == 1
        })
        let firstPlayerID = try #require(
            viewController.bodyViewControllerForTesting.mediaPlayerIdentityForTesting
        )

        let secondRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "second-shared-playlist",
            url: playlistURL,
            frameID: frameID,
            initiatorNodeID: nodeID,
            responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
            responseMIMEType: "application/vnd.apple.mpegurl",
            resourceType: .media,
            timestamp: 4
        ))

        #expect(await waitUntilRendered(in: viewController) {
            viewController.previewRequestIDForTesting == secondRequest.id
                && playerFactory.players.count == 2
        })
        #expect(
            viewController.bodyViewControllerForTesting.mediaPlayerIdentityForTesting
                != firstPlayerID
        )
        #expect(model.selectedEntryRequests.map(\.id) == [firstRequest.id, secondRequest.id])
    }

    @Test
    func groupedPreviewFollowsNewerPlaylist() async throws {
        let context = makeContext()
        let frameID = FrameID("main-frame")
        let nodeID = DOM.Node.ID("grouped-changing-playlist")
        installNavigationVisit(in: context, frameID: frameID)
        let firstRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "first-playlist",
            url: "https://media.example.com/first.m3u8",
            frameID: frameID,
            initiatorNodeID: nodeID,
            responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
            responseMIMEType: "application/vnd.apple.mpegurl",
            resourceType: .media,
            timestamp: 1
        ))
        let model = NetworkPanelModel(context: context)
        try selectEntry(containing: firstRequest, in: model)
        let viewController = NetworkDetailViewController(model: model, initialMode: .preview)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.bodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(await waitUntilRendered(in: viewController) {
            viewController.previewRequestIDForTesting == firstRequest.id
                && viewController.bodyViewControllerForTesting
                    .mediaPlayerURLForTesting?.absoluteString == firstRequest.url
                && playerFactory.players.count == 1
        })

        let secondRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "second-playlist",
            url: "https://media.example.com/second.m3u8",
            frameID: frameID,
            initiatorNodeID: nodeID,
            responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
            responseMIMEType: "application/vnd.apple.mpegurl",
            resourceType: .media,
            timestamp: 4
        ))

        #expect(await waitUntilRendered(in: viewController) {
            viewController.previewRequestIDForTesting == secondRequest.id
                && viewController.bodyViewControllerForTesting
                    .mediaPlayerURLForTesting?.absoluteString == secondRequest.url
                && playerFactory.players.count == 2
        })
        #expect(model.selectedEntryRequests.map(\.id) == [firstRequest.id, secondRequest.id])
    }

    @Test
    func groupedPreviewTreatsPartialMediaAsAnOrdinaryMovieCandidate() async throws {
        let context = makeContext()
        let frameID = FrameID("main-frame")
        let nodeID = DOM.Node.ID("grouped-partial-movie")
        installNavigationVisit(in: context, frameID: frameID)
        let fullRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "full",
            url: "https://media.example.com/full.mp4",
            frameID: frameID,
            initiatorNodeID: nodeID,
            responseHeaders: ["content-type": "video/mp4"],
            responseMIMEType: "video/mp4",
            resourceType: .media,
            timestamp: 1
        ))
        let ignoredRangeRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "ignored-range",
            url: "https://media.example.com/ignored-range.mp4",
            frameID: frameID,
            initiatorNodeID: nodeID,
            requestHeaders: ["range": "bytes=0-1023"],
            responseHeaders: ["content-type": "video/mp4"],
            responseMIMEType: "video/mp4",
            resourceType: .media,
            timestamp: 2
        ))
        let partialRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "partial",
            url: "https://media.example.com/partial.mp4",
            frameID: frameID,
            initiatorNodeID: nodeID,
            requestHeaders: ["range": "bytes=0-1023"],
            responseHeaders: [
                "content-type": "video/mp4",
                "content-range": "bytes 0-1023/4096",
            ],
            responseMIMEType: "video/mp4",
            responseStatus: 206,
            resourceType: .media,
            timestamp: 3
        ))
        for request in [fullRequest, ignoredRangeRequest, partialRequest] {
            applyResponseBody(
                to: context,
                request: request,
                body: "AAAA",
                base64Encoded: true
            )
        }
        let model = NetworkPanelModel(context: context)
        try selectEntry(containing: partialRequest, in: model)
        let viewController = NetworkDetailViewController(model: model, initialMode: .preview)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.bodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(await waitUntilRendered(in: viewController) {
            viewController.previewRequestIDForTesting == partialRequest.id
                && playerFactory.players.count == 1
        })
    }

    @Test
    func groupedPreviewSkipsFailedAndNoContentHLSMembers() async throws {
        let context = makeContext()
        let frameID = FrameID("main-frame")
        let nodeID = DOM.Node.ID("grouped-player")
        installNavigationVisit(in: context, frameID: frameID)
        let healthyRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "healthy-playlist",
            url: "https://media.example.com/healthy.m3u8",
            frameID: frameID,
            initiatorNodeID: nodeID,
            responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
            responseMIMEType: "application/vnd.apple.mpegurl",
            resourceType: .media,
            timestamp: 1
        ))
        let failedRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "failed-playlist",
            url: "https://media.example.com/failed.m3u8",
            frameID: frameID,
            initiatorNodeID: nodeID,
            responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
            responseMIMEType: "application/vnd.apple.mpegurl",
            resourceType: .media,
            finishes: false,
            timestamp: 4
        ))
        await context.apply(.loadingFailed(
            id: Network.Request.ID("failed-playlist"),
            errorText: "Cancelled",
            canceled: true,
            timestamp: 5
        ))
        let noContentRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "no-content-playlist",
            url: "https://media.example.com/no-content.m3u8",
            frameID: frameID,
            initiatorNodeID: nodeID,
            responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
            responseMIMEType: "application/vnd.apple.mpegurl",
            responseStatus: 204,
            resourceType: .media,
            timestamp: 7
        ))
        let model = NetworkPanelModel(context: context)
        try selectEntry(containing: noContentRequest, in: model)
        let viewController = NetworkDetailViewController(model: model, initialMode: .preview)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didSelectHealthyPreview = await waitUntilRendered(in: viewController) {
            viewController.previewRequestIDForTesting == healthyRequest.id
                && viewController.currentModeForTesting == .preview
                && viewController.previewViewForTesting.isHidden == false
        }
        #expect(didSelectHealthyPreview)
        #expect(model.selectedEntryRequests.map(\.id) == [healthyRequest.id, failedRequest.id, noContentRequest.id])
    }

    @Test
    func groupedPreviewPrefersUsableStandardBodyOverUnavailableMedia() async throws {
        let context = makeContext()
        let frameID = FrameID("main-frame")
        let nodeID = DOM.Node.ID("grouped-mixed-preview")
        installNavigationVisit(in: context, frameID: frameID)
        let standardRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "metadata",
            url: "https://media.example.com/metadata.json",
            frameID: frameID,
            initiatorNodeID: nodeID,
            postData: #"{"kind":"metadata"}"#,
            responseHeaders: ["content-type": "application/json"],
            responseMIMEType: "application/json",
            resourceType: .xhr,
            timestamp: 1
        ))
        let unavailableMediaRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "no-content-playlist",
            url: "https://media.example.com/no-content.m3u8",
            frameID: frameID,
            initiatorNodeID: nodeID,
            responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
            responseMIMEType: "application/vnd.apple.mpegurl",
            responseStatus: 204,
            resourceType: .media,
            timestamp: 4
        ))
        let model = NetworkPanelModel(context: context)
        try selectEntry(containing: unavailableMediaRequest, in: model)
        let viewController = NetworkDetailViewController(model: model, initialMode: .preview)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(await waitUntilRendered(in: viewController) {
            viewController.previewRequestIDForTesting == standardRequest.id
        })
        viewController.selectPreviewRoleForTesting(.request)
        #expect(await waitUntilRendered(in: viewController) {
            viewController.currentPreviewRoleForTesting == .request
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text
                    .contains("metadata")
        })
    }
}
}
#endif
