#if canImport(UIKit)
import AVFoundation
import Dispatch
import ObservationBridge
import Synchronization
import Testing
import WebInspectorTransport
import UIKit
@testable import WebInspectorCore
@testable import WebInspectorUI

extension WebInspectorUIRenderingTests {
@MainActor
@Suite
struct NetworkDetailViewControllerTests {
    @Test
    func resourceFilterSpecialistTitlesFollowWebInspectorLabels() {
        #expect(NetworkRequest.Display.ResourceFilter.stylesheet.localizedTitle == "CSS")
        #expect(NetworkRequest.Display.ResourceFilter.media.localizedTitle == String(localized: "network.filter.media", bundle: .module))
        #expect(localizedResourceString("network.filter.media", locale: "en") == "Media")
        #expect(NetworkRequest.Display.ResourceFilter.script.localizedTitle == "JS")
        #expect(NetworkRequest.Display.ResourceFilter.xhrFetch.localizedTitle == "XHR / Fetch")
    }

    @Test
    func listShowsSimpleEmptyStateWithoutRequests() {
        let model = NetworkPanelModel(network: NetworkSession())
        let viewController = NetworkListViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(viewController.collectionViewForTesting.isHidden)
        #expect(viewController.contentUnavailableConfiguration != nil)
        let configuration = viewController.contentUnavailableConfiguration as? UIContentUnavailableConfiguration
        #expect(configuration?.text?.isEmpty == false)
        #expect(configuration?.secondaryText == nil)
        #expect(configuration?.image == nil)
        #expect(configuration?.textProperties.color == .secondaryLabel)
    }

    @Test
    func detailShowsEmptyStateWithoutSelection() {
        let model = NetworkPanelModel(network: NetworkSession())
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(viewController.previewViewForTesting.isHidden)
        #expect(viewController.headersTextViewForTesting.isHidden)
        #expect(viewController.contentUnavailableConfiguration != nil)
        let configuration = viewController.contentUnavailableConfiguration as? UIContentUnavailableConfiguration
        #expect(configuration?.text?.isEmpty == false)
        #expect(configuration?.secondaryText == nil)
        #expect(configuration?.image == nil)
        #expect(configuration?.textProperties.color == .secondaryLabel)
    }

    @Test
    func detailCanDisableBackgroundDrawing() {
        guard #available(iOS 26.0, *) else {
            return
        }

        let model = NetworkPanelModel(network: NetworkSession())
        let viewController = NetworkDetailViewController(model: model)
        viewController.traitOverrides.webInspectorDrawsBackground = false

        viewController.loadViewIfNeeded()

        #expect(viewController.view.backgroundColor == .clear)
        #expect(viewController.headersTextViewForTesting.backgroundColor == .clear)
        #expect(viewController.bodyViewControllerForTesting.view.backgroundColor == .clear)
    }

    @Test
    func listCanDisableBackgroundDrawing() {
        guard #available(iOS 26.0, *) else {
            return
        }

        let model = NetworkPanelModel(network: NetworkSession())
        let viewController = NetworkListViewController(model: model)
        viewController.traitOverrides.webInspectorDrawsBackground = false

        viewController.loadViewIfNeeded()

        #expect(viewController.collectionViewForTesting.backgroundColor == .clear)
    }

    @Test
    func listLoadDoesNotEvaluateDisplayRequestsUntilAppearing() async throws {
        let network = NetworkSession()
        _ = try #require(applyRequest(
            to: network,
            requestID: "1",
            url: "https://example.com/api/data.json",
            responseHeaders: ["content-type": "application/json"],
            responseMimeType: "application/json"
        ))
        let model = NetworkPanelModel(network: network)
        let viewController = NetworkListViewController(model: model)

        viewController.loadViewIfNeeded()

        #expect(viewController.displayRequestIDsEvaluationCountForTesting == 0)
        #expect(viewController.displayedRequestIDsForTesting.isEmpty)

        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        await viewController.flushPendingSnapshotUpdateForTesting()

        #expect(viewController.displayedRequestIDsForTesting == model.displayRequestIDs)
        #expect(viewController.displayRequestIDsEvaluationCountForTesting == 1)
    }

    @Test
    func regularSplitKeepsPrimarySecondaryLayout() throws {
        let model = NetworkPanelModel(network: NetworkSession())
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = NetworkDetailViewController(model: model)
        let splitViewController = NetworkSplitViewController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )

        splitViewController.loadViewIfNeeded()

        let listNavigationController = try #require(
            splitViewController.viewController(for: .primary) as? UINavigationController
        )
        let detailNavigationController = try #require(
            splitViewController.viewController(for: .secondary) as? UINavigationController
        )
        #expect(listNavigationController.viewControllers.first === listViewController)
        #expect(detailNavigationController.viewControllers.first === detailViewController)
        if #available(iOS 26.0, *) {
            #expect(splitViewController.viewController(for: .inspector) == nil)
        }
        #expect(splitViewController.preferredDisplayMode == .oneBesideSecondary)
        #expect(splitViewController.preferredSplitBehavior == .tile)
        #expect(splitViewController.presentsWithGesture == false)
    }

    @Test
    func detailContentKeepsPreviewRoleControlInSafeArea() {
        let model = NetworkPanelModel(network: NetworkSession())
        let viewController = NetworkDetailViewController(model: model)
        viewController.additionalSafeAreaInsets = UIEdgeInsets(top: 44, left: 120, bottom: 10, right: 24)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        viewController.view.layoutIfNeeded()

        let leadingInset = viewController.view.safeAreaLayoutGuide.layoutFrame.minX
        let topInset = viewController.view.safeAreaLayoutGuide.layoutFrame.minY
        let trailingInset = viewController.view.safeAreaLayoutGuide.layoutFrame.maxX
        let bounds = viewController.view.bounds
        for contentView in [
            viewController.headersTextViewForTesting,
            viewController.previewViewForTesting,
        ] {
            #expect(contentView.frame.minX == leadingInset)
            #expect(contentView.frame.maxX == trailingInset)
            #expect(contentView.frame.maxY == bounds.maxY)
        }
        #expect(viewController.headersTextViewForTesting.frame.minY == bounds.minY)
        #expect(viewController.previewViewForTesting.frame.minY == bounds.minY)
        #expect(viewController.previewRoleControlContainerViewForTesting.frame.minY == topInset)
    }

    @Test
    func detailModeControlSwitchesPreviewAndHeaders() async throws {
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://example.com/api/data.json",
                requestHeaders: [
                    "accept": "application/json",
                    "content-type": "application/x-www-form-urlencoded",
                ],
                postData: "name=Jane+Doe&city=Tokyo%20East",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        let model = NetworkPanelModel(network: network)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderHeaders = await waitUntilRendered(in: viewController) {
            let text = viewController.headersTextViewForTesting.renderedTextForTesting
            let didRenderHeaders = viewController.currentModeForTesting == .headers
                && viewController.previewViewForTesting.isHidden
                && viewController.headersTextViewForTesting.isHidden == false
                && viewController.headersTextViewForTesting.usesTextKit2ForTesting
                && viewController.headersTextViewForTesting.isSelectableForTesting
                && text.contains("accept: application/json")
                && text.contains("content-type: application/json")
                && text.contains("200 OK")
            if #available(iOS 26.0, *) {
                return didRenderHeaders
                    && viewController.contentScrollView(for: .top) === viewController.headersTextViewForTesting.contentScrollView
                    && viewController.contentScrollView(for: .bottom) === viewController.headersTextViewForTesting.contentScrollView
            }
            return didRenderHeaders
        }

        #expect(didRenderHeaders)
        #expect(viewController.contentUnavailableConfiguration == nil)

        selectMode(.preview, on: viewController)

        let didRenderPreview = await waitUntilRendered(in: viewController) {
            let didRenderPreview = viewController.currentModeForTesting == .preview
                && viewController.previewViewForTesting.isHidden == false
                && viewController.headersTextViewForTesting.isHidden
                && viewController.isPreviewRoleControlHiddenForTesting == false
            if #available(iOS 26.0, *) {
                return didRenderPreview
                    && viewController.previewRoleScrollEdgeInteractionForTesting?.edge == .top
                    && viewController.previewRoleScrollEdgeInteractionForTesting?.scrollView === viewController.bodyViewControllerForTesting.syntaxViewForTesting
                    && viewController.contentScrollView(for: .top) === viewController.bodyViewControllerForTesting.syntaxViewForTesting
                    && viewController.contentScrollView(for: .bottom) === viewController.bodyViewControllerForTesting.syntaxViewForTesting
            }
            return didRenderPreview
        }
        #expect(didRenderPreview)

        viewController.selectPreviewRoleForTesting(.request)

        let didRenderRequestPreview = await waitUntilRendered(in: viewController) {
            viewController.currentPreviewRoleForTesting == .request
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text == "name=Jane Doe\ncity=Tokyo East"
        }
        #expect(didRenderRequestPreview)
    }

    @Test
    func previewTextBodyUsesAutomaticInsetsAsRegisteredContentScrollView() async throws {
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://example.com/api/data.txt",
                responseHeaders: ["content-type": "text/plain"],
                responseMimeType: "text/plain"
            )
        )
        request.applyResponseBody(
            NetworkBody.Payload(
                body: "sample=true\nsource=preview",
                base64Encoded: false
            )
        )
        let model = NetworkPanelModel(network: network)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didRenderPreview = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .preview
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text == "sample=true\nsource=preview"
        }
        #expect(didRenderPreview)

        let bodyViewController = viewController.bodyViewControllerForTesting
        window.layoutIfNeeded()

        let syntaxView = bodyViewController.syntaxViewForTesting
        #expect(syntaxView.contentInsetAdjustmentBehavior == .automatic)
        #expect(syntaxView.frame == bodyViewController.view.bounds)
        #expect(bodyViewController.view.frame == viewController.previewViewForTesting.bounds)
        if #available(iOS 26.0, *) {
            #expect(viewController.contentScrollView(for: .top) === syntaxView)
            #expect(viewController.contentScrollView(for: .bottom) === syntaxView)
        }
    }

    @Test
    func previewRequestWithoutBodyReplacesPreviousBodyWithUnavailablePlaceholder() async throws {
        let network = NetworkSession()
        let bodyRequest = try #require(
            applyRequestWithoutResponse(
                to: network,
                requestID: "body",
                url: "https://example.com/form",
                requestHeaders: ["content-type": "application/x-www-form-urlencoded"],
                postData: "name=Jane+Doe"
            )
        )
        let emptyRequest = try #require(
            applyRequestWithoutResponse(
                to: network,
                requestID: "empty",
                url: "https://example.com/no-body"
            )
        )
        let model = NetworkPanelModel(network: network)
        model.selectRequest(bodyRequest)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didRenderBody = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .preview
                && viewController.currentPreviewRoleForTesting == .request
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text == "name=Jane Doe"
        }
        #expect(didRenderBody)

        model.selectRequest(emptyRequest)

        let unavailableText = String(localized: "network.body.unavailable", bundle: .module)
        let didReplaceBody = await waitUntilRendered(in: viewController) {
            viewController.previewViewForTesting.isHidden == false
                && viewController.isPreviewRoleControlHiddenForTesting
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text == unavailableText
        }
        #expect(didReplaceBody)
        #expect(viewController.bodyViewControllerForTesting.syntaxViewForTesting.text.contains("Jane") == false)
    }

    @Test
    func previewRequestWithoutBodyRendersPlaceholderWhenBodySurfaceResumes() async throws {
        let network = NetworkSession()
        let request = try #require(
            applyRequestWithoutResponse(
                to: network,
                requestID: "1",
                url: "https://example.com/no-body"
            )
        )
        let model = NetworkPanelModel(network: network)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderHeaders = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .headers
                && viewController.previewViewForTesting.isHidden
                && viewController.headersTextViewForTesting.renderedTextForTesting.contains("GET /no-body")
        }
        #expect(didRenderHeaders)

        viewController.setModeForTesting(.preview)

        let unavailableText = String(localized: "network.body.unavailable", bundle: .module)
        let didRenderPlaceholder = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .preview
                && viewController.previewViewForTesting.isHidden == false
                && viewController.isPreviewRoleControlHiddenForTesting
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text == unavailableText
        }
        #expect(didRenderPlaceholder)
    }

    @Test
    func detailUpdatesResponseHeadersAfterSelection() async throws {
        let network = NetworkSession()
        let targetID = ProtocolTarget.ID("page")
        let requestID = NetworkRequest.ProtocolID("1")
        let key = network.applyRequestWillBeSent(
            targetID: targetID,
            requestID: requestID,
            frameID: DOMFrame.ID("main"),
            loaderID: "loader",
            documentURL: "https://example.com",
            request: NetworkRequest.Payload(
                url: "https://example.com/api/data.json",
                method: "GET"
            ),
            resourceType: .script,
            timestamp: 1
        )
        let request = try #require(network.request(for: key))
        let model = NetworkPanelModel(network: network)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.headers)

        let didRenderRequestHeaders = await waitUntilRendered(in: viewController) {
            viewController.headersTextViewForTesting.renderedTextForTesting.contains("GET /api/data.json")
        }
        #expect(didRenderRequestHeaders)

        network.applyResponseReceived(
            targetID: targetID,
            requestID: requestID,
            resourceType: .script,
            response: NetworkRequest.Response.Payload(
                url: "https://example.com/api/data.json",
                status: 200,
                statusText: "OK",
                headers: ["content-type": "application/json"],
                mimeType: "application/json"
            ),
            timestamp: 2
        )

        let didRenderResponseHeaders = await waitUntilRendered(in: viewController) {
            viewController.headersTextViewForTesting.renderedTextForTesting.contains("content-type: application/json")
        }
        #expect(didRenderResponseHeaders)
    }

    @Test
    func detailModeControlUsesCoreBodyAvailabilityAndRendersRequestBody() async throws {
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://example.com/form",
                requestHeaders: ["content-type": "application/x-www-form-urlencoded"],
                postData: "name=Jane+Doe&city=Tokyo%20East",
                responseHeaders: [:],
                responseMimeType: "text/plain"
            )
        )
        let model = NetworkPanelModel(network: network)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didRender = await waitUntilRendered(in: viewController) {
            viewController.previewViewForTesting.isHidden == false
                && viewController.isPreviewRoleControlHiddenForTesting == false
        }
        #expect(didRender)

        #expect(viewController.currentModeForTesting == .preview)
        viewController.selectPreviewRoleForTesting(.request)

        let didRenderBody = await waitUntilRendered(in: viewController) {
            viewController.bodyViewControllerForTesting.syntaxViewForTesting.text == "name=Jane Doe\ncity=Tokyo East"
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.model.language == .plainText
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.model.drawsBackground == false
        }
        #expect(didRenderBody)
    }

    @Test
    func detailModeControlDisablesWhenSelectedRequestDisappears() async throws {
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://example.com/form",
                postData: "name=Jane+Doe"
            )
        )
        let model = NetworkPanelModel(network: network)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didEnableMenu = await waitUntilRendered(in: viewController) {
            viewController.isDetailModeControlEnabledForTesting
        }
        #expect(didEnableMenu)

        network.reset()

        let didDisableMenu = await waitUntilRendered(in: viewController) {
            viewController.isDetailModeControlEnabledForTesting == false
                && viewController.contentUnavailableConfiguration != nil
        }
        #expect(didDisableMenu)
    }

    @Test
    func responsePreviewRequestsRuntimeFetchWhenBodyIsAvailable() async throws {
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://example.com/api/data.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        var fetchedIDs: [NetworkRequest.ID] = []
        let model = NetworkPanelModel(network: network) { id in
            fetchedIDs.append(id)
            request.markResponseBodyFetching()
        }
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didFetch = await waitUntilRendered(in: viewController) {
            fetchedIDs == [request.id]
                && viewController.currentModeForTesting == .preview
                && viewController.currentPreviewRoleForTesting == .response
        }
        #expect(didFetch)
    }

    @Test
    func responsePreviewPrewarmsSyntaxWhileFetching() async throws {
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://example.com/api/data.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        var fetchedIDs: [NetworkRequest.ID] = []
        let model = NetworkPanelModel(network: network) { id in
            fetchedIDs.append(id)
            request.markResponseBodyFetching()
        }
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didStartFetching = await waitUntilRendered(in: viewController) {
            return fetchedIDs == [request.id]
                && viewController.currentModeForTesting == .preview
                && viewController.currentPreviewRoleForTesting == .response
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text.isEmpty == true
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.model.language == .json
        }
        #expect(didStartFetching)

        request.applyResponseBody(
            NetworkBody.Payload(
                body: #"{"ok":true}"#,
                base64Encoded: false
            )
        )

        let didRenderBody = await waitUntilRendered(in: viewController) {
            return viewController.bodyViewControllerForTesting.syntaxViewForTesting.text.contains(#""ok""#)
        }
        #expect(didRenderBody)
    }

    @Test
    func hiddenDetailDoesNotFetchResponseBodyUntilAppearingAgain() async throws {
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://example.com/api/data.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        var fetchedIDs: [NetworkRequest.ID] = []
        let model = NetworkPanelModel(network: network) { id in
            fetchedIDs.append(id)
            request.markResponseBodyFetching()
        }
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.headers)

        let didRenderHeaders = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .headers
                && viewController.headersTextViewForTesting.renderedTextForTesting.contains("content-type: application/json")
        }
        #expect(didRenderHeaders)
        #expect(fetchedIDs.isEmpty)

        viewController.beginAppearanceTransition(false, animated: false)
        viewController.endAppearanceTransition()
        viewController.setModeForTesting(.preview)
        await Task.yield()
        await Task.yield()

        #expect(fetchedIDs.isEmpty)
        #expect(viewController.headersTextViewForTesting.renderedTextForTesting.contains("content-type: application/json"))

        viewController.beginAppearanceTransition(true, animated: false)
        viewController.endAppearanceTransition()

        let didFetchOnReturn = await waitUntilRendered(in: viewController) {
            fetchedIDs == [request.id]
                && viewController.currentModeForTesting == .preview
                && viewController.currentPreviewRoleForTesting == .response
        }
        #expect(didFetchOnReturn)
    }

    @Test
    func hiddenDetailKeepsDisplayedBodyAndReconcilesBodyOnReturn() async throws {
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://example.com/api/data.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        request.applyResponseBody(
            NetworkBody.Payload(
                body: #"{"visible":true}"#,
                base64Encoded: false
            )
        )
        let model = NetworkPanelModel(network: network)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model, initialMode: .preview)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderVisibleBody = await waitUntilRendered(in: viewController) {
            viewController.bodyViewControllerForTesting.syntaxViewForTesting.text.contains(#""visible" : true"#)
        }
        #expect(didRenderVisibleBody)
        let renderedBodyBeforeHide = viewController.bodyViewControllerForTesting.syntaxViewForTesting.text

        viewController.beginAppearanceTransition(false, animated: false)
        viewController.endAppearanceTransition()
        request.applyResponseBody(
            NetworkBody.Payload(
                body: #"{"hidden":true}"#,
                base64Encoded: false
            )
        )
        await Task.yield()
        await Task.yield()

        #expect(viewController.bodyViewControllerForTesting.syntaxViewForTesting.text == renderedBodyBeforeHide)

        viewController.beginAppearanceTransition(true, animated: false)
        viewController.endAppearanceTransition()

        let didRenderHiddenBody = await waitUntilRendered(in: viewController) {
            viewController.bodyViewControllerForTesting.syntaxViewForTesting.text.contains(#""hidden" : true"#)
        }
        #expect(didRenderHiddenBody)
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
                url: playlistURL
            )
        ) { _ in
            Issue.record("HLS response preview should not require body payload preparation")
        }

        guard case .remoteMovie(let url) = action else {
            Issue.record("Expected HLS response preview to use the remote playlist URL")
            return
        }
        #expect(url.absoluteString == playlistURL)
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
                url: playlistURL
            )
        ) { _ in
            Issue.record("HLS response preview should not fetch or prepare body payloads")
        }

        guard case .remoteMovie(let url) = action else {
            Issue.record("Expected HLS response preview to use the remote playlist URL before the body loads")
            return
        }
        #expect(url.absoluteString == playlistURL)
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
                url: "https://media.example.com/upload.m3u8"
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
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://media.example.com/download.php",
                responseHeaders: ["content-type": "video/mp4"],
                responseMimeType: "video/mp4"
            )
        )
        request.applyResponseBody(
            NetworkBody.Payload(
                body: "not a real movie",
                base64Encoded: false
            )
        )
        let model = NetworkPanelModel(network: network)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.bodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer(for:)
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
        #expect(playerFactory.requestedURLs == [temporaryFileURL])
        #expect(FileManager.default.fileExists(atPath: temporaryFileURL.path))

        viewController.setModeForTesting(.headers)

        let didReleaseMediaPreview = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .headers
                && viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting == nil
                && FileManager.default.fileExists(atPath: temporaryFileURL.path) == false
        }
        #expect(didReleaseMediaPreview)
        #expect(playerFactory.requestedURLs == [temporaryFileURL])

        viewController.setModeForTesting(.preview)
        await waitUntilMediaPreviewPrepared(in: viewController)

        let didRestoreMediaPreview = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .preview
                && viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting?.pathExtension == "mp4"
        }
        #expect(didRestoreMediaPreview)
        #expect(playerFactory.requestedURLs.count == 2)
        #expect(playerFactory.requestedURLs.allSatisfy { $0.pathExtension == "mp4" })
    }

    @Test
    func mediaResponsePreviewReusesPlayerAndTemporaryFileWhenRequestUpdateDoesNotChangeBody() async throws {
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://media.example.com/download.php",
                responseHeaders: ["content-type": "video/mp4"],
                responseMimeType: "video/mp4",
                finishes: false
            )
        )
        request.applyResponseBody(
            NetworkBody.Payload(
                body: "not a real movie",
                base64Encoded: false
            )
        )
        let model = NetworkPanelModel(network: network)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.bodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer(for:)
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
        let delivery = try #require(viewController.selectedRequestRenderObservationDeliveryForTesting)
        #expect(playerFactory.requestedURLs == [temporaryFileURL])

        network.applyDataReceived(
            targetID: request.id.targetID,
            requestID: request.id.requestID,
            dataLength: 128,
            encodedDataLength: 64,
            timestamp: 4
        )

        let observedValues = await delivery.values {
            request.encodedDataLength == 64
                && viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting == temporaryFileURL
                && viewController.bodyViewControllerForTesting.mediaPlayerIdentityForTesting == playerIdentity
                && FileManager.default.fileExists(atPath: temporaryFileURL.path)
        }
        #expect(observedValues.latestValue == true)
        #expect(playerFactory.requestedURLs == [temporaryFileURL])
    }

    @Test
    func mediaResponsePreviewPausesPlayerButKeepsSurfaceWhenHidden() async throws {
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://media.example.com/download.php",
                responseHeaders: ["content-type": "video/mp4"],
                responseMimeType: "video/mp4"
            )
        )
        request.applyResponseBody(
            NetworkBody.Payload(
                body: "not a real movie",
                base64Encoded: false
            )
        )
        let model = NetworkPanelModel(network: network)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.bodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer(for:)
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
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://media.example.com/download.php",
                responseHeaders: ["content-type": "video/mp4"],
                responseMimeType: "video/mp4"
            )
        )
        request.applyResponseBody(
            NetworkBody.Payload(
                body: "not a real movie",
                base64Encoded: false
            )
        )
        let model = NetworkPanelModel(network: network)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.bodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer(for:)
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
        #expect(playerFactory.requestedURLs == [temporaryFileURL])
        #expect(FileManager.default.fileExists(atPath: temporaryFileURL.path))

        model.selectRequest(nil)

        let didReleaseMediaPreview = await waitUntilRendered(in: viewController) {
            viewController.contentUnavailableConfiguration != nil
                && viewController.previewViewForTesting.isHidden
                && viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting == nil
                && FileManager.default.fileExists(atPath: temporaryFileURL.path) == false
        }
        #expect(didReleaseMediaPreview)
        #expect(playerFactory.requestedURLs == [temporaryFileURL])
    }

    @Test
    func hiddenMediaResponsePreviewReleasesPlayerAndTemporaryFileWhenSelectionClearsBeforeReappearing() async throws {
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://media.example.com/download.php",
                responseHeaders: ["content-type": "video/mp4"],
                responseMimeType: "video/mp4"
            )
        )
        request.applyResponseBody(
            NetworkBody.Payload(
                body: "not a real movie",
                base64Encoded: false
            )
        )
        let model = NetworkPanelModel(network: network)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.bodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer(for:)
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
        #expect(playerFactory.requestedURLs == [temporaryFileURL])
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
        #expect(playerFactory.requestedURLs == [temporaryFileURL])
    }

    @Test
    func imageResponsePreviewUsesScrollViewAndFitsLargeImage() async throws {
        let imageSize = CGSize(width: 600, height: 1400)
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://media.example.com/large.png",
                postData: "metadata=1",
                responseHeaders: ["content-type": "image/png"],
                responseMimeType: "image/png"
            )
        )
        request.applyResponseBody(
            NetworkBody.Payload(
                body: pngBase64String(size: imageSize),
                base64Encoded: true
            )
        )
        let model = NetworkPanelModel(network: network)
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
            let imageScrollView = bodyViewController.imageScrollViewForTesting
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
            let didRenderImage = bodyViewController.isImagePreviewVisibleForTesting
                && bodyViewController.syntaxViewForTesting.isHidden
                && bodyViewController.imageViewForTesting.image?.size == imageSize
                && didCompleteImageLayout
            if #available(iOS 26.0, *) {
                return didRenderImage
                    && viewController.previewRoleScrollEdgeInteractionForTesting?.edge == .top
                    && viewController.previewRoleScrollEdgeInteractionForTesting?.scrollView === imageScrollView
                    && viewController.contentScrollView(for: .top) === imageScrollView
                    && viewController.contentScrollView(for: .bottom) === imageScrollView
            }
            return didRenderImage
        }
        #expect(didRenderImage)

        let imageScrollView = viewController.bodyViewControllerForTesting.imageScrollViewForTesting
        #expect(imageScrollView.contentInsetAdjustmentBehavior == .automatic)
        #expect(imageScrollView.contentAlignmentPoint == CGPoint(x: 0.5, y: 0.5))
        #expect(imageScrollView.contentInset == .zero)
        #expect(imageScrollView.adjustedContentInset.top > imageScrollView.contentInset.top)
        let fitScale = expectedImageFitScale(scrollView: imageScrollView, imageSize: imageSize)
        let expectedMinimumZoomScale = min(1, fitScale)
        #expect(abs(imageScrollView.minimumZoomScale - expectedMinimumZoomScale) < 0.001)
        #expect(abs(imageScrollView.zoomScale - expectedMinimumZoomScale) < 0.001)
        #expect(imageScrollView.maximumZoomScale >= 1)
    }

    @Test
    func imageResponsePreviewKeepsAutoFitWhenBoundsShrink() async throws {
        let imageSize = CGSize(width: 600, height: 1400)
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://media.example.com/large.png",
                responseHeaders: ["content-type": "image/png"],
                responseMimeType: "image/png"
            )
        )
        request.applyResponseBody(
            NetworkBody.Payload(
                body: pngBase64String(size: imageSize),
                base64Encoded: true
            )
        )
        let model = NetworkPanelModel(network: network)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController, makeVisible: true)
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
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://media.example.com/icon.png",
                responseHeaders: ["content-type": "image/png"],
                responseMimeType: "image/png"
            )
        )
        request.applyResponseBody(
            NetworkBody.Payload(
                body: pngBase64String(size: imageSize),
                base64Encoded: true
            )
        )
        let model = NetworkPanelModel(network: network)
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
    func responsePreviewWaitsForLoadingFinishedBeforeFetching() async throws {
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://example.com/api/data.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json",
                finishes: false
            )
        )
        var fetchedIDs: [NetworkRequest.ID] = []
        let model = NetworkPanelModel(network: network) { id in
            fetchedIDs.append(id)
            request.markResponseBodyFetching()
        }
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        #expect(fetchedIDs.isEmpty)

        network.applyLoadingFinished(
            targetID: request.id.targetID,
            requestID: request.id.requestID,
            timestamp: 3
        )

        let didFetch = await waitUntilRendered(in: viewController) {
            fetchedIDs == [request.id]
        }
        #expect(didFetch)
    }

    @Test
    func failedResponseBodyDoesNotRefetchFromRendering() async throws {
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://example.com/api/data.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        request.markResponseBodyFailed(.unavailable)

        var fetchedIDs: [NetworkRequest.ID] = []
        let model = NetworkPanelModel(network: network) { id in
            fetchedIDs.append(id)
        }
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didRenderFailure = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .preview
                && viewController.currentPreviewRoleForTesting == .response
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text.isEmpty == false
        }
        #expect(didRenderFailure)
        #expect(fetchedIDs.isEmpty)

        request.markResponseBodyFailed(.unknown("Still unavailable"))

        let didStayIdle = await waitUntilRendered(in: viewController) {
            viewController.bodyViewControllerForTesting.syntaxViewForTesting.text.contains("Still unavailable")
                && fetchedIDs.isEmpty
        }
        #expect(didStayIdle)
    }

    @Test
    func headersModeDoesNotFetchResponseBody() async throws {
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://example.com/api/data.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        var fetchedIDs: [NetworkRequest.ID] = []
        let model = NetworkPanelModel(network: network) { id in
            fetchedIDs.append(id)
        }
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.headers)

        let didRenderHeaders = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .headers
                && viewController.headersTextViewForTesting.renderedTextForTesting.contains("content-type: application/json")
        }
        #expect(didRenderHeaders)
        #expect(fetchedIDs.isEmpty)
    }

    @Test
    func headersModePreservesSelectionWhenRequestUpdateDoesNotChangeDocument() async throws {
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://example.com/api/data.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json",
                finishes: false
            )
        )
        let model = NetworkPanelModel(network: network)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.headers)

        let didRenderHeaders = await waitUntilRendered(in: viewController) {
            viewController.headersTextViewForTesting.renderedTextForTesting.contains("content-type: application/json")
        }
        #expect(didRenderHeaders)

        let selectedRange = NSRange(location: 2, length: 4)
        viewController.headersTextViewForTesting.selectedRangeForTesting = selectedRange
        let assignmentCount = viewController.headersTextViewForTesting.attributedTextAssignmentCountForTesting
        let delivery = try #require(viewController.selectedRequestRenderObservationDeliveryForTesting)

        network.applyDataReceived(
            targetID: request.id.targetID,
            requestID: request.id.requestID,
            dataLength: 128,
            encodedDataLength: 64,
            timestamp: 4
        )

        let observedValues = await delivery.values {
            request.encodedDataLength == 64
                && viewController.headersTextViewForTesting.attributedTextAssignmentCountForTesting == assignmentCount
                && viewController.headersTextViewForTesting.selectedRangeForTesting == selectedRange
        }
        #expect(observedValues.latestValue == true)
    }

    @Test
    func hiddenDetailKeepsHeadersAndRebindsSameSelectedRequestOnReturn() async throws {
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://example.com/api/data.json",
                responseHeaders: ["x-request": "visible"],
                responseMimeType: "application/json"
            )
        )
        let model = NetworkPanelModel(network: network)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.headers)

        let didRenderInitialHeaders = await waitUntilRendered(in: viewController) {
            viewController.headersTextViewForTesting.renderedTextForTesting.contains("x-request: visible")
        }
        #expect(didRenderInitialHeaders)
        let renderedHeadersBeforeHide = viewController.headersTextViewForTesting.renderedTextForTesting

        viewController.beginAppearanceTransition(false, animated: false)
        viewController.endAppearanceTransition()
        network.applyResponseReceived(
            targetID: request.id.targetID,
            requestID: request.id.requestID,
            resourceType: .script,
            response: NetworkRequest.Response.Payload(
                url: "https://example.com/api/data.json",
                status: 200,
                statusText: "OK",
                headers: ["x-request": "hidden-update"],
                mimeType: "application/json"
            ),
            timestamp: 4
        )
        await Task.yield()
        await Task.yield()

        #expect(viewController.headersTextViewForTesting.renderedTextForTesting == renderedHeadersBeforeHide)

        viewController.beginAppearanceTransition(true, animated: false)
        viewController.endAppearanceTransition()

        let didRenderHiddenUpdate = await waitUntilRendered(in: viewController) {
            viewController.headersTextViewForTesting.renderedTextForTesting.contains("x-request: hidden-update")
        }
        #expect(didRenderHiddenUpdate)
    }

    @Test
    func requestPreviewRoleDoesNotFetchResponseBodyAfterLoadingFinishes() async throws {
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://example.com/api/data.json",
                requestHeaders: ["content-type": "application/x-www-form-urlencoded"],
                postData: "name=Jane+Doe",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json",
                finishes: false
            )
        )
        var fetchedIDs: [NetworkRequest.ID] = []
        let model = NetworkPanelModel(network: network) { id in
            fetchedIDs.append(id)
        }
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didRenderPreview = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .preview
                && viewController.isPreviewRoleControlHiddenForTesting == false
        }
        #expect(didRenderPreview)

        viewController.selectPreviewRoleForTesting(.request)

        let didRenderRequestBody = await waitUntilRendered(in: viewController) {
            viewController.currentPreviewRoleForTesting == .request
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text == "name=Jane Doe"
        }
        #expect(didRenderRequestBody)

        network.applyLoadingFinished(
            targetID: request.id.targetID,
            requestID: request.id.requestID,
            timestamp: 3
        )

        let didStayOnRequestBody = await waitUntilRendered(in: viewController) {
            viewController.currentPreviewRoleForTesting == .request
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text == "name=Jane Doe"
        }
        #expect(didStayOnRequestBody)
        #expect(fetchedIDs.isEmpty)
    }

    @Test
    func selectedRequestRebindingIgnoresOldRequestMutations() async throws {
        let network = NetworkSession()
        let firstRequest = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://example.com/first.json",
                responseHeaders: ["x-request": "first"],
                responseMimeType: "application/json"
            )
        )
        let secondRequest = try #require(
            applyRequest(
                to: network,
                requestID: "2",
                url: "https://example.com/second.json",
                responseHeaders: ["x-request": "second"],
                responseMimeType: "application/json"
            )
        )
        let model = NetworkPanelModel(network: network)
        model.selectRequest(firstRequest)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.headers)

        let didRenderFirst = await waitUntilRendered(in: viewController) {
            viewController.headersTextViewForTesting.renderedTextForTesting.contains("x-request: first")
        }
        #expect(didRenderFirst)

        model.selectRequest(secondRequest)
        let didRenderSecond = await waitUntilRendered(in: viewController) {
            viewController.headersTextViewForTesting.renderedTextForTesting.contains("x-request: second")
        }
        #expect(didRenderSecond)

        network.applyResponseReceived(
            targetID: firstRequest.id.targetID,
            requestID: firstRequest.id.requestID,
            resourceType: .script,
            response: NetworkRequest.Response.Payload(
                url: "https://example.com/first.json",
                status: 200,
                statusText: "OK",
                headers: ["x-old-request": "stale"],
                mimeType: "application/json"
            ),
            timestamp: 4
        )

        #expect(viewController.headersTextViewForTesting.renderedTextForTesting.contains("x-old-request: stale") == false)

        network.applyResponseReceived(
            targetID: secondRequest.id.targetID,
            requestID: secondRequest.id.requestID,
            resourceType: .script,
            response: NetworkRequest.Response.Payload(
                url: "https://example.com/second.json",
                status: 200,
                statusText: "OK",
                headers: ["x-current-request": "updated"],
                mimeType: "application/json"
            ),
            timestamp: 5
        )

        let didRenderCurrentUpdate = await waitUntilRendered(in: viewController) {
            let text = viewController.headersTextViewForTesting.renderedTextForTesting
            return text.contains("x-current-request: updated")
                && text.contains("x-old-request: stale") == false
        }
        #expect(didRenderCurrentUpdate)
    }

    @Test
    func previewRoleSwitchPreservesInstalledBodyViews() async throws {
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://example.com/api/data.json",
                requestHeaders: ["content-type": "application/x-www-form-urlencoded"],
                postData: "name=Jane+Doe",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        let model = NetworkPanelModel(network: network)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didRenderPreview = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .preview
                && viewController.isPreviewRoleControlHiddenForTesting == false
        }
        #expect(didRenderPreview)

        let bodyViewControllerID = ObjectIdentifier(viewController.bodyViewControllerForTesting)
        let syntaxViewID = ObjectIdentifier(viewController.bodyViewControllerForTesting.syntaxViewForTesting)

        viewController.selectPreviewRoleForTesting(.request)
        let didRenderRequest = await waitUntilRendered(in: viewController) {
            viewController.currentPreviewRoleForTesting == .request
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text == "name=Jane Doe"
        }
        #expect(didRenderRequest)

        viewController.selectPreviewRoleForTesting(.response)
        let didRenderResponse = await waitUntilRendered(in: viewController) {
            viewController.currentPreviewRoleForTesting == .response
        }
        #expect(didRenderResponse)
        #expect(ObjectIdentifier(viewController.bodyViewControllerForTesting) == bodyViewControllerID)
        #expect(ObjectIdentifier(viewController.bodyViewControllerForTesting.syntaxViewForTesting) == syntaxViewID)
    }

    @Test
    func rebindingPreviewBodyCancelsOutgoingTextPreparation() async throws {
        let network = NetworkSession()
        let firstRequest = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://example.com/api/large.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        let secondRequest = try #require(
            applyRequest(
                to: network,
                requestID: "2",
                url: "https://example.com/api/current.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        let largeJSON = "[" + (0..<80_000).map { #"{"value":\#($0),"enabled":true}"# }.joined(separator: ",") + "]"
        firstRequest.applyResponseBody(
            NetworkBody.Payload(body: largeJSON, base64Encoded: false)
        )
        secondRequest.applyResponseBody(
            NetworkBody.Payload(body: #"{"ok":true}"#, base64Encoded: false)
        )
        let firstBody = try #require(firstRequest.responseBody)
        let model = NetworkPanelModel(network: network)
        model.selectRequest(firstRequest)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let firstBodyID = ObjectIdentifier(firstBody)
        let didStartFirstPreparation = await waitUntilRendered(in: viewController) {
            viewController.currentPreviewRoleForTesting == .response
                && viewController.bodyViewControllerForTesting.activeTextPreviewPreparationBodyIDForTesting == firstBodyID
        }
        #expect(didStartFirstPreparation)

        model.selectRequest(secondRequest)

        let didRenderSecondRequest = await waitUntilRendered(in: viewController) {
            viewController.bodyViewControllerForTesting.syntaxViewForTesting.text.contains(#""ok""#)
                && viewController.bodyViewControllerForTesting.activeTextPreviewPreparationBodyIDForTesting != firstBodyID
        }
        #expect(didRenderSecondRequest)
        #expect(viewController.bodyViewControllerForTesting.activeTextPreviewPreparationBodyIDForTesting != firstBodyID)
    }

    @Test
    func compactContainerPushesAndPopsDetailFromSelection() async throws {
        let network = NetworkSession()
        let request = try #require(applyRequest(to: network, requestID: "1", url: "https://example.com/app.js"))
        let model = NetworkPanelModel(network: network)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = NetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        let window = showInWindow(navigationController, makeVisible: true)
        defer { window.isHidden = true }

        model.selectRequest(request)
        let didPush = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers.last === detailViewController
        }
        #expect(didPush)
        await waitForNavigationTransitionToFinish(in: navigationController)

        withUIKitAnimationsDisabled {
            model.selectRequest(nil)
        }
        let didPop = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers == [listViewController]
        }
        #expect(didPop)
    }

    @Test
    func compactProgrammaticPopKeepsDetailSurfaceUntilTransitionCompletes() async throws {
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://example.com/api/data.txt",
                responseHeaders: ["content-type": "text/plain"],
                responseMimeType: "text/plain"
            )
        )
        request.applyResponseBody(
            NetworkBody.Payload(body: "visible detail body", base64Encoded: false)
        )
        let model = NetworkPanelModel(network: network)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = NetworkDetailViewController(model: model)
        detailViewController.setModeForTesting(.preview)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        let window = showInWindow(navigationController, makeVisible: true)
        defer { window.isHidden = true }

        model.selectRequest(request)
        let didPush = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers.last === detailViewController
        }
        #expect(didPush)
        await waitForNavigationTransitionToFinish(in: navigationController)

        let didRenderDetail = await waitUntilRendered(in: detailViewController) {
            detailViewController.previewViewForTesting.isHidden == false
                && detailViewController.bodyViewControllerForTesting.syntaxViewForTesting.text == "visible detail body"
        }
        #expect(didRenderDetail)

        model.selectRequest(nil)
        if navigationController.transitionCoordinator != nil {
            #expect(detailViewController.previewViewForTesting.isHidden == false)
            #expect(detailViewController.bodyViewControllerForTesting.syntaxViewForTesting.text == "visible detail body")
        }

        let didPop = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers == [listViewController]
        }
        #expect(didPop)
        await waitForNavigationTransitionToFinish(in: navigationController)
        #expect(detailViewController.previewViewForTesting.isHidden)
    }

    @Test
    func compactUserPopDiscardsDetailSurfaceWhenSelectionClearsBeforeTransitionCompletes() async throws {
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://example.com/api/data.txt",
                responseHeaders: ["content-type": "text/plain"],
                responseMimeType: "text/plain"
            )
        )
        request.applyResponseBody(
            NetworkBody.Payload(body: "visible detail body", base64Encoded: false)
        )
        let model = NetworkPanelModel(network: network)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = NetworkDetailViewController(model: model)
        detailViewController.setModeForTesting(.preview)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        let window = showInWindow(navigationController, makeVisible: true)
        defer { window.isHidden = true }

        model.selectRequest(request)
        let didPush = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers.last === detailViewController
        }
        #expect(didPush)
        await waitForNavigationTransitionToFinish(in: navigationController)

        let didRenderDetail = await waitUntilRendered(in: detailViewController) {
            detailViewController.previewViewForTesting.isHidden == false
                && detailViewController.bodyViewControllerForTesting.syntaxViewForTesting.text == "visible detail body"
        }
        #expect(didRenderDetail)

        _ = navigationController.popViewController(animated: true)
        if navigationController.transitionCoordinator != nil {
            model.selectRequest(nil)
            #expect(detailViewController.previewViewForTesting.isHidden == false)
            #expect(detailViewController.bodyViewControllerForTesting.syntaxViewForTesting.text == "visible detail body")
        }

        let didPopAndDiscard = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers == [listViewController]
                && detailViewController.previewViewForTesting.isHidden
        }
        #expect(didPopAndDiscard)
    }

    @Test
    func compactContainerCanPushSameRequestAfterBackNavigation() async throws {
        let network = NetworkSession()
        _ = try #require(applyRequest(to: network, requestID: "1", url: "https://example.com/app.js"))
        let model = NetworkPanelModel(network: network)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = NetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        let window = showInWindow(navigationController, makeVisible: true)
        defer { window.isHidden = true }

        let didRenderList = await waitForObservedCondition(
            deliveries: {
                [listViewController.displayRowsObservationDeliveryForTesting].compactMap { $0 }
            },
            sample: {
                listViewController.displayedRequestIDsForTesting.count == 1
            }
        )
        #expect(didRenderList)

        selectListItem(at: IndexPath(item: 0, section: 0), in: listViewController)
        let didPush = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers.last === detailViewController
        }
        #expect(didPush)
        await waitForNavigationTransitionToFinish(in: navigationController)

        _ = withUIKitAnimationsDisabled {
            navigationController.popViewController(animated: false)
        }
        let didReturnToList = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers == [listViewController]
                && model.selectedRequest == nil
                && (listViewController.collectionViewForTesting.indexPathsForSelectedItems ?? []).isEmpty
        }
        #expect(didReturnToList)

        selectListItem(at: IndexPath(item: 0, section: 0), in: listViewController)
        let didPushAgain = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers.last === detailViewController
        }
        #expect(didPushAgain)
    }

    @Test
    func compactContainerBackNavigationReleasesDetailMediaPreviewResources() async throws {
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://media.example.com/download.php",
                responseHeaders: ["content-type": "video/mp4"],
                responseMimeType: "video/mp4"
            )
        )
        request.applyResponseBody(
            NetworkBody.Payload(
                body: "not a real movie",
                base64Encoded: false
            )
        )
        let model = NetworkPanelModel(network: network)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = NetworkDetailViewController(model: model)
        detailViewController.setModeForTesting(.preview)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        detailViewController.bodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer(for:)
        )
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        let window = showInWindow(navigationController, makeVisible: true)
        defer { window.isHidden = true }

        model.selectRequest(request)
        let didPush = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers.last === detailViewController
        }
        #expect(didPush)
        await waitForNavigationTransitionToFinish(in: navigationController)
        await waitUntilMediaPreviewPrepared(in: detailViewController)

        let didRenderMediaPreview = await waitUntilRendered(in: detailViewController) {
            detailViewController.bodyViewControllerForTesting.mediaPlayerURLForTesting?.pathExtension == "mp4"
        }
        #expect(didRenderMediaPreview)
        let temporaryFileURL = try #require(detailViewController.bodyViewControllerForTesting.mediaPlayerURLForTesting)
        #expect(playerFactory.requestedURLs == [temporaryFileURL])
        #expect(FileManager.default.fileExists(atPath: temporaryFileURL.path))

        _ = withUIKitAnimationsDisabled {
            navigationController.popViewController(animated: false)
        }

        let didReturnToListAndReleasePreview = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers == [listViewController]
                && model.selectedRequest == nil
                && detailViewController.bodyViewControllerForTesting.mediaPlayerURLForTesting == nil
                && FileManager.default.fileExists(atPath: temporaryFileURL.path) == false
        }
        #expect(didReturnToListAndReleasePreview)
        #expect(playerFactory.requestedURLs == [temporaryFileURL])
    }

    @Test
    func compactContainerPopsDetailWhenSelectedRequestDisappears() async throws {
        let network = NetworkSession()
        let request = try #require(applyRequest(to: network, requestID: "1", url: "https://example.com/app.js"))
        let model = NetworkPanelModel(network: network)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = NetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        let window = showInWindow(navigationController, makeVisible: true)
        defer { window.isHidden = true }

        model.selectRequest(request)
        let didPush = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers.last === detailViewController
        }
        #expect(didPush)
        await waitForNavigationTransitionToFinish(in: navigationController)

        withUIKitAnimationsDisabled {
            network.reset()
        }
        #expect(model.selectedRequestID == request.id)
        #expect(model.selectedRequest == nil)

        let didPop = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers == [listViewController]
        }
        #expect(didPop)
    }

    @Test
    func listDefersDisplayRequestEvaluationUntilThrottledReload() async throws {
        let network = NetworkSession()
        _ = try #require(applyRequest(
            to: network,
            requestID: "1",
            url: "https://media.example.com/clip.mp4",
            responseHeaders: ["content-type": "video/mp4"],
            responseMimeType: "video/mp4"
        ))
        let model = NetworkPanelModel(network: network)
        model.setResourceFilter(.media, enabled: true)
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }

        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedRequestIDsForTesting.count == 1)

        let evaluationCountBeforeUpdate = listViewController.displayRequestIDsEvaluationCountForTesting
        let observation = try #require(listViewController.displayRowsObservationDeliveryForTesting)
        let observedSearchText = await observation.values {
            model.searchText
        }

        model.setSearchText("does-not-match")
        #expect(await observedSearchText.waitUntilValue("does-not-match"))
        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeUpdate)

        await listViewController.flushThrottledDisplayRowsReloadForTesting()

        #expect(model.displayRequestIDs.isEmpty)
        #expect(listViewController.displayedRequestIDsForTesting.isEmpty)
        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeUpdate + 1)
    }

    @Test
    func hiddenListDefersSnapshotEvaluationUntilAppearingAgain() async throws {
        let network = NetworkSession()
        _ = try #require(applyRequest(
            to: network,
            requestID: "1",
            url: "https://media.example.com/clip.mp4",
            responseHeaders: ["content-type": "video/mp4"],
            responseMimeType: "video/mp4"
        ))
        let model = NetworkPanelModel(network: network)
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController)
        defer { window.isHidden = true }
        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedRequestIDsForTesting.count == 1)

        let evaluationCountBeforeHiddenUpdate = listViewController.displayRequestIDsEvaluationCountForTesting
        let observation = try #require(listViewController.displayRowsObservationDeliveryForTesting)
        let observedInvalidations = await observation.values {
            model.displayRowsInvalidationRevision
        }
        defer {
            observedInvalidations.cancel()
        }

        listViewController.beginAppearanceTransition(false, animated: false)
        listViewController.endAppearanceTransition()
        model.setSearchText("does-not-match")
        let hiddenInvalidationRevision = model.displayRowsInvalidationRevision
        #expect(await observedInvalidations.waitUntil { $0 == hiddenInvalidationRevision } != nil)
        await listViewController.flushThrottledDisplayRowsReloadForTesting()

        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate)
        #expect(listViewController.displayedRequestIDsForTesting.count == 1)

        listViewController.beginAppearanceTransition(true, animated: false)
        listViewController.endAppearanceTransition()
        await listViewController.flushPendingSnapshotUpdateForTesting()

        #expect(listViewController.displayedRequestIDsForTesting.isEmpty)
        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate + 1)
    }

    @Test
    func hiddenListDefersQueuedSnapshotApplyUntilAppearingAgain() async throws {
        let network = NetworkSession()
        let request = try #require(applyRequest(
            to: network,
            requestID: "1",
            url: "https://media.example.com/clip.mp4",
            responseHeaders: ["content-type": "video/mp4"],
            responseMimeType: "video/mp4"
        ))
        let model = NetworkPanelModel(network: network)
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController)
        defer { window.isHidden = true }
        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedRequestIDsForTesting == [request.id])

        let evaluationCountBeforeHiddenUpdate = listViewController.displayRequestIDsEvaluationCountForTesting
        listViewController.beginSnapshotApplyForTesting(requestIDs: [request.id])
        listViewController.queueSnapshotUpdateForTesting(requestIDs: [])
        #expect(listViewController.hasPendingSnapshotUpdateForTesting)

        listViewController.beginAppearanceTransition(false, animated: false)
        listViewController.endAppearanceTransition()
        #expect(listViewController.hasPendingSnapshotUpdateForTesting == false)

        model.setSearchText("does-not-match")
        listViewController.finishSnapshotApplyForTesting(requestIDs: [request.id])
        await listViewController.flushPendingSnapshotUpdateForTesting()

        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate)
        #expect(listViewController.displayedRequestIDsForTesting == [request.id])

        listViewController.beginAppearanceTransition(true, animated: false)
        listViewController.endAppearanceTransition()
        await listViewController.flushPendingSnapshotUpdateForTesting()

        #expect(listViewController.displayedRequestIDsForTesting.isEmpty)
        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate + 1)
    }

    @Test
    func listControllerDeallocatesWhileDisplayRequestObservationIsActive() async throws {
        let model = NetworkPanelModel(network: NetworkSession())
        let deinitProbe = UITestDeinitProbe()
        weak var weakViewController: NetworkListViewController?

        do {
            let viewController = NetworkListViewController(model: model)
            viewController.loadViewIfNeeded()
            viewController.setDeinitHandlerForTesting {
                deinitProbe.signalDeinit()
            }
            weakViewController = viewController
        }

        let didDeallocate = await deinitProbe.wait()
        #expect(didDeallocate)
        #expect(weakViewController == nil)
    }

    private func applyRequest(
        to network: NetworkSession,
        requestID rawRequestID: String,
        url: String,
        requestHeaders: [String: String] = [:],
        postData: String? = nil,
        responseHeaders: [String: String] = ["content-type": "text/javascript"],
        responseMimeType: String = "text/javascript",
        finishes: Bool = true
    ) -> NetworkRequest? {
        let targetID = ProtocolTarget.ID("page")
        let requestID = NetworkRequest.ProtocolID(rawRequestID)
        let key = network.applyRequestWillBeSent(
            targetID: targetID,
            requestID: requestID,
            frameID: DOMFrame.ID("main"),
            loaderID: "loader",
            documentURL: "https://example.com",
            request: NetworkRequest.Payload(
                url: url,
                method: postData == nil ? "GET" : "POST",
                headers: requestHeaders,
                postData: postData
            ),
            resourceType: .script,
            timestamp: 1
        )
        network.applyResponseReceived(
            targetID: targetID,
            requestID: requestID,
            resourceType: .script,
            response: NetworkRequest.Response.Payload(
                url: url,
                status: 200,
                statusText: "OK",
                headers: responseHeaders,
                mimeType: responseMimeType
            ),
            timestamp: 2
        )
        if finishes {
            network.applyLoadingFinished(
                targetID: targetID,
                requestID: requestID,
                timestamp: 3
            )
        }
        return network.request(for: key)
    }

    private func applyRequestWithoutResponse(
        to network: NetworkSession,
        requestID rawRequestID: String,
        url: String,
        requestHeaders: [String: String] = [:],
        postData: String? = nil
    ) -> NetworkRequest? {
        let key = network.applyRequestWillBeSent(
            targetID: ProtocolTarget.ID("page"),
            requestID: NetworkRequest.ProtocolID(rawRequestID),
            frameID: DOMFrame.ID("main"),
            loaderID: "loader",
            documentURL: "https://example.com",
            request: NetworkRequest.Payload(
                url: url,
                method: postData == nil ? "GET" : "POST",
                headers: requestHeaders,
                postData: postData
            ),
            resourceType: .xhr,
            timestamp: 1
        )
        return network.request(for: key)
    }

    private func selectMode(
        _ mode: NetworkDetailViewController.Mode,
        on viewController: NetworkDetailViewController
    ) {
        #expect(viewController.isDetailModeEnabledForTesting(mode))
        viewController.selectModeForTesting(mode)
    }

    private func selectListItem(
        at indexPath: IndexPath,
        in viewController: NetworkListViewController
    ) {
        let collectionView = viewController.collectionViewForTesting
        collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        viewController.collectionView(collectionView, didSelectItemAt: indexPath)
    }

    private func showInWindow(
        _ viewController: UIViewController,
        makeVisible: Bool = true
    ) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = viewController
        if makeVisible {
            window.makeKeyAndVisible()
        }
        viewController.loadViewIfNeeded()
        window.layoutIfNeeded()
        return window
    }

    private func pngBase64String(size: CGSize) -> String {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        .base64EncodedString()
    }

    private func expectedImageFitScale(scrollView: UIScrollView, imageSize: CGSize) -> CGFloat {
        let visibleSize = imageVisibleBoundsSize(scrollView)
        return min(
            visibleSize.width / imageSize.width,
            visibleSize.height / imageSize.height
        )
    }

    private func imageVisibleBoundsSize(_ scrollView: UIScrollView) -> CGSize {
        let adjustedInset = scrollView.adjustedContentInset
        return CGSize(
            width: max(scrollView.bounds.width - adjustedInset.left - adjustedInset.right, 0),
            height: max(scrollView.bounds.height - adjustedInset.top - adjustedInset.bottom, 0)
        )
    }

    private func waitUntilRendered(
        in viewController: NetworkDetailViewController,
        _ condition: @escaping @MainActor @Sendable () -> Bool
    ) async -> Bool {
        await waitForObservedCondition(
            deliveries: {
                observationDeliveries(in: viewController)
            },
            sample: {
                sampleRenderedCondition(in: viewController, condition: condition)
            }
        )
    }

    private func waitUntilMediaPreviewPrepared(
        in viewController: NetworkDetailViewController
    ) async {
        await viewController.bodyViewControllerForTesting.waitUntilMediaPreviewPreparationFinishedForTesting()
        viewController.view.layoutIfNeeded()
    }

    private func waitUntilNavigationStackSynced(
        in navigationController: NetworkCompactNavigationController,
        _ condition: @escaping @MainActor @Sendable () -> Bool
    ) async -> Bool {
        await waitForObservedCondition(
            deliveries: {
                [navigationController.selectionObservationDeliveryForTesting].compactMap { $0 }
            },
            sample: {
                condition()
            }
        )
    }

    private func waitUntilNavigationStackSynced(
        in navigationController: UINavigationController,
        _ condition: @escaping @MainActor @Sendable () -> Bool
    ) async -> Bool {
        guard let compactNavigationController = navigationController as? NetworkCompactNavigationController else {
            return condition()
        }
        return await waitUntilNavigationStackSynced(in: compactNavigationController, condition)
    }

    private func observationDeliveries(in viewController: NetworkDetailViewController) -> [PortableObservationTracking.Token] {
        [
            viewController.modelObservationDeliveryForTesting,
            viewController.selectedRequestRenderObservationDeliveryForTesting,
            viewController.responseBodyFetchObservationDeliveryForTesting,
            viewController.bodyViewControllerForTesting.bodyObservationDeliveryForTesting,
            viewController.bodyViewControllerForTesting.previewRenderObservationDeliveryForTesting,
        ].compactMap { $0 }
    }

    private func sampleRenderedCondition(
        in viewController: NetworkDetailViewController,
        condition: @MainActor @Sendable () -> Bool
    ) -> Bool {
        viewController.view.layoutIfNeeded()
        return condition()
    }

    private func waitForNavigationTransitionToFinish(in navigationController: UINavigationController) async {
        guard let transitionCoordinator = navigationController.transitionCoordinator else {
            return
        }
        await withCheckedContinuation { continuation in
            let didRegister = transitionCoordinator.animate(alongsideTransition: nil) { _ in
                continuation.resume()
            }
            if didRegister == false {
                continuation.resume()
            }
        }
    }

    private func withUIKitAnimationsDisabled<T>(_ body: () -> T) -> T {
        let wereAnimationsEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(wereAnimationsEnabled) }
        return body()
    }

    private func localizedResourceString(_ key: String, locale: String) -> String? {
        guard let bundleURL = Bundle.module.url(forResource: locale, withExtension: "lproj"),
              let bundle = Bundle(url: bundleURL) else {
            return nil
        }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    private final class BlockingMediaPreviewClassifier: @unchecked Sendable {
        private struct State: Sendable {
            var shouldBlockNextCall = true
            var isBlocked = false
        }

        private let state = Mutex(State())
        private let unblockSemaphore = DispatchSemaphore(value: 0)

        func classify(
            mimeType: String?,
            url: String?
        ) -> NetworkRequest.Display.MediaPreviewClassification {
            let shouldBlock = state.withLock { state in
                guard state.shouldBlockNextCall else {
                    return false
                }
                state.shouldBlockNextCall = false
                return true
            }
            if shouldBlock {
                state.withLock { state in
                    state.isBlocked = true
                }
                unblockSemaphore.wait()
            }
            return NetworkRequest.Display.MediaPreviewSupport.classification(mimeType: mimeType, url: url)
        }

        func waitUntilBlocked() async -> Bool {
            for _ in 0..<100 {
                if state.withLock({ $0.isBlocked }) {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }

        func unblock() {
            unblockSemaphore.signal()
        }
    }

    @MainActor
    private final class MoviePreviewPlayerFactorySpy {
        private(set) var requestedURLs: [URL] = []
        private(set) var players: [StubMoviePreviewPlayer] = []

        func makePlayer(for url: URL) -> AVPlayer {
            let player = StubMoviePreviewPlayer()
            requestedURLs.append(url)
            players.append(player)
            return player
        }
    }

    private final class StubMoviePreviewPlayer: AVPlayer {
        private(set) var pauseCallCount = 0

        override func pause() {
            pauseCallCount += 1
        }
    }
}
}
#endif
