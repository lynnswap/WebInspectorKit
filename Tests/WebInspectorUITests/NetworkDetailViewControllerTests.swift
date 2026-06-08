#if canImport(UIKit)
import Testing
import WebInspectorTransport
import UIKit
@testable import WebInspectorCore
@testable import WebInspectorUI

@MainActor
@Suite(.serialized)
struct NetworkDetailViewControllerTests {
    @Test
    func resourceFilterSpecialistTitlesFollowWebInspectorLabels() {
        #expect(NetworkResourceFilter.stylesheet.localizedTitle == "CSS")
        #expect(NetworkResourceFilter.script.localizedTitle == "JS")
        #expect(NetworkResourceFilter.xhrFetch.localizedTitle == "XHR / Fetch")
    }

    @Test
    func listShowsSimpleEmptyStateWithoutRequests() {
        let model = NetworkPanelModel(network: NetworkSession())
        let viewController = NetworkListViewController(model: model)

        viewController.loadViewIfNeeded()

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

        viewController.loadViewIfNeeded()

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

        let didRenderHeaders = await waitUntil {
            let text = viewController.headersTextViewForTesting.renderedTextForTesting
            return viewController.currentModeForTesting == .headers
                && viewController.previewViewForTesting.isHidden
                && viewController.headersTextViewForTesting.isHidden == false
                && viewController.headersTextViewForTesting.usesTextKit2ForTesting
                && viewController.headersTextViewForTesting.isSelectableForTesting
                && text.contains("accept: application/json")
                && text.contains("content-type: application/json")
                && text.contains("200 OK")
        }

        #expect(didRenderHeaders)
        #expect(viewController.contentUnavailableConfiguration == nil)

        selectMode(.preview, on: viewController)

        let didRenderPreview = await waitUntil {
            viewController.currentModeForTesting == .preview
                && viewController.previewViewForTesting.isHidden == false
                && viewController.headersTextViewForTesting.isHidden
                && viewController.isPreviewRoleControlHiddenForTesting == false
        }
        #expect(didRenderPreview)

        viewController.selectPreviewRoleForTesting(.request)

        let didRenderRequestPreview = await waitUntil {
            viewController.currentPreviewRoleForTesting == .request
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text == "name=Jane Doe\ncity=Tokyo East"
        }
        #expect(didRenderRequestPreview)
    }

    @Test
    func detailUpdatesResponseHeadersAfterSelection() async throws {
        let network = NetworkSession()
        let targetID = ProtocolTargetIdentifier("page")
        let requestID = NetworkRequestIdentifier("1")
        let key = network.applyRequestWillBeSent(
            targetID: targetID,
            requestID: requestID,
            frameID: DOMFrameIdentifier("main"),
            loaderID: "loader",
            documentURL: "https://example.com",
            request: NetworkRequestPayload(
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

        let didRenderRequestHeaders = await waitUntil {
            viewController.headersTextViewForTesting.renderedTextForTesting.contains("GET /api/data.json")
        }
        #expect(didRenderRequestHeaders)

        network.applyResponseReceived(
            targetID: targetID,
            requestID: requestID,
            resourceType: .script,
            response: NetworkResponsePayload(
                url: "https://example.com/api/data.json",
                status: 200,
                statusText: "OK",
                headers: ["content-type": "application/json"],
                mimeType: "application/json"
            ),
            timestamp: 2
        )

        let didRenderResponseHeaders = await waitUntil {
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

        let didRender = await waitUntil {
            viewController.previewViewForTesting.isHidden == false
                && viewController.isPreviewRoleControlHiddenForTesting == false
        }
        #expect(didRender)

        #expect(viewController.currentModeForTesting == .preview)
        viewController.selectPreviewRoleForTesting(.request)

        let didRenderBody = await waitUntil {
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

        let didEnableMenu = await waitUntil {
            viewController.isDetailModeControlEnabledForTesting
        }
        #expect(didEnableMenu)

        network.reset()

        let didDisableMenu = await waitUntil {
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

        let didFetch = await waitUntil {
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

        let didStartFetching = await waitUntil {
            return fetchedIDs == [request.id]
                && viewController.currentModeForTesting == .preview
                && viewController.currentPreviewRoleForTesting == .response
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text.isEmpty == true
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.model.language == .json
        }
        #expect(didStartFetching)

        request.applyResponseBody(
            NetworkBodyPayload(
                body: #"{"ok":true}"#,
                base64Encoded: false
            )
        )

        let didRenderBody = await waitUntil {
            return viewController.bodyViewControllerForTesting.syntaxViewForTesting.text.contains(#""ok""#)
        }
        #expect(didRenderBody)
    }

    @Test
    func hlsResponsePreviewUsesOriginalPlaylistURLForPlayer() async throws {
        let network = NetworkSession()
        let playlistURL = "https://media.example.com/live/master.m3u8"
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: playlistURL,
                responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
                responseMimeType: "application/vnd.apple.mpegurl"
            )
        )
        request.applyResponseBody(
            NetworkBodyPayload(
                body: """
                #EXTM3U
                #EXT-X-STREAM-INF:BANDWIDTH=1280000
                media/playlist.m3u8
                """,
                base64Encoded: false
            )
        )
        let model = NetworkPanelModel(network: network)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didRenderHLSPreview = await waitUntil {
            viewController.bodyViewControllerForTesting.mediaPlayerURLForTesting?.absoluteString == playlistURL
        }
        #expect(didRenderHLSPreview)
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

        let didFetch = await waitUntil {
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

        let didRenderFailure = await waitUntil {
            viewController.currentModeForTesting == .preview
                && viewController.currentPreviewRoleForTesting == .response
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text.isEmpty == false
        }
        #expect(didRenderFailure)
        #expect(fetchedIDs.isEmpty)

        request.markResponseBodyFailed(.unknown("Still unavailable"))

        let didStayIdle = await waitUntil {
            viewController.bodyViewControllerForTesting.syntaxViewForTesting.text.contains("Still unavailable")
                && fetchedIDs.isEmpty
        }
        #expect(didStayIdle)
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
        let window = showInWindow(navigationController)
        defer { window.isHidden = true }

        model.selectRequest(request)
        let didPush = await waitUntil {
            navigationController.viewControllers.last === detailViewController
        }
        #expect(didPush)
        await waitForNavigationTransitionToFinish(in: navigationController)

        withUIKitAnimationsDisabled {
            model.selectRequest(nil)
        }
        let didPop = await waitUntil {
            navigationController.viewControllers == [listViewController]
        }
        #expect(didPop)
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
        let window = showInWindow(navigationController)
        defer { window.isHidden = true }

        let didRenderList = await waitUntil {
            listViewController.collectionViewForTesting.numberOfItems(inSection: 0) == 1
        }
        #expect(didRenderList)

        selectListItem(at: IndexPath(item: 0, section: 0), in: listViewController)
        let didPush = await waitUntil {
            navigationController.viewControllers.last === detailViewController
        }
        #expect(didPush)
        await waitForNavigationTransitionToFinish(in: navigationController)

        _ = withUIKitAnimationsDisabled {
            navigationController.popViewController(animated: false)
        }
        let didReturnToList = await waitUntil {
            navigationController.viewControllers == [listViewController]
                && model.selectedRequest == nil
                && (listViewController.collectionViewForTesting.indexPathsForSelectedItems ?? []).isEmpty
        }
        #expect(didReturnToList)

        selectListItem(at: IndexPath(item: 0, section: 0), in: listViewController)
        let didPushAgain = await waitUntil {
            navigationController.viewControllers.last === detailViewController
        }
        #expect(didPushAgain)
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
        let window = showInWindow(navigationController)
        defer { window.isHidden = true }

        model.selectRequest(request)
        let didPush = await waitUntil {
            navigationController.viewControllers.last === detailViewController
        }
        #expect(didPush)
        await waitForNavigationTransitionToFinish(in: navigationController)

        withUIKitAnimationsDisabled {
            network.reset()
        }
        #expect(model.selectedRequestID == request.id)
        #expect(model.selectedRequest == nil)

        let didPop = await waitUntil {
            navigationController.viewControllers == [listViewController]
        }
        #expect(didPop)
    }

    @Test
    func listControllerDeallocatesWhileDisplayRequestObservationIsActive() async throws {
        let model = NetworkPanelModel(network: NetworkSession())
        weak var weakViewController: NetworkListViewController?

        do {
            let viewController = NetworkListViewController(model: model)
            viewController.loadViewIfNeeded()
            weakViewController = viewController
        }

        let didDeallocate = await waitUntil {
            weakViewController == nil
        }
        #expect(didDeallocate)
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
        let targetID = ProtocolTargetIdentifier("page")
        let requestID = NetworkRequestIdentifier(rawRequestID)
        let key = network.applyRequestWillBeSent(
            targetID: targetID,
            requestID: requestID,
            frameID: DOMFrameIdentifier("main"),
            loaderID: "loader",
            documentURL: "https://example.com",
            request: NetworkRequestPayload(
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
            response: NetworkResponsePayload(
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

    private func selectMode(
        _ mode: NetworkDetailMode,
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

    private func showInWindow(_ viewController: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        viewController.loadViewIfNeeded()
        window.layoutIfNeeded()
        return window
    }

    private func waitUntil(
        maxTicks: Int = 256,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<maxTicks {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return false
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
}
#endif
