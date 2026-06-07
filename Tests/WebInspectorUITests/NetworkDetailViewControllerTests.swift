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

        #expect(viewController.collectionViewForTesting.isHidden)
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
        #expect(viewController.collectionViewForTesting.backgroundColor == .clear)
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
    func detailModeControlRendersBodyLinkAndHeadersForSelectedSide() async throws {
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://example.com/api/data.json",
                requestHeaders: ["accept": "application/json"],
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        let model = NetworkPanelModel(network: network)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let collectionView = viewController.collectionViewForTesting
        let didRenderRequest = await waitUntil {
            collectionView.numberOfSections == 2
                && collectionView.numberOfItems(inSection: 0) == 1
                && collectionView.numberOfItems(inSection: 1) == 1
                && listCellText(in: collectionView, at: IndexPath(item: 0, section: 1)) == "accept"
                && listCellSecondaryText(in: collectionView, at: IndexPath(item: 0, section: 1)) == "application/json"
        }

        #expect(didRenderRequest)
        #expect(viewController.contentUnavailableConfiguration == nil)

        selectMode(.response, on: viewController)

        let didRenderResponse = await waitUntil {
            collectionView.numberOfSections == 2
                && collectionView.numberOfItems(inSection: 0) == 2
                && collectionView.numberOfItems(inSection: 1) == 1
                && listCellSecondaryText(in: collectionView, at: IndexPath(item: 0, section: 0)) == "application/json"
                && listCellText(in: collectionView, at: IndexPath(item: 0, section: 1)) == "content-type"
                && listCellSecondaryText(in: collectionView, at: IndexPath(item: 0, section: 1)) == "application/json"
        }

        #expect(didRenderResponse)
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

        let didRenderRequestBodyOnly = await waitUntil {
            let collectionView = viewController.collectionViewForTesting
            return collectionView.numberOfSections == 1
                && viewController.isDetailModeEnabledForTesting(.response) == false
                && collectionView.numberOfItems(inSection: 0) == 1
        }
        #expect(didRenderRequestBodyOnly)

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

        let didEnableResponseMode = await waitUntil {
            viewController.isDetailModeEnabledForTesting(.response)
        }
        #expect(didEnableResponseMode)

        selectMode(.response, on: viewController)

        let didRenderResponseHeaders = await waitUntil {
            let collectionView = viewController.collectionViewForTesting
            return collectionView.numberOfItems(inSection: 0) == 2
                && listCellSecondaryText(in: collectionView, at: IndexPath(item: 0, section: 0)) == "application/json"
                && collectionView.numberOfItems(inSection: 1) == 1
                && listCellText(in: collectionView, at: IndexPath(item: 0, section: 1)) == "content-type"
                && listCellSecondaryText(in: collectionView, at: IndexPath(item: 0, section: 1)) == "application/json"
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
        let navigationController = UINavigationController(rootViewController: viewController)
        let window = showInWindow(navigationController)
        defer { window.isHidden = true }

        let didRender = await waitUntil {
            viewController.collectionViewForTesting.numberOfSections == 2
        }
        #expect(didRender)

        #expect(viewController.currentModeForTesting == .request)
        viewController.selectBodyLinkForTesting()

        let didPushBody = await waitUntil {
            bodyViewController(in: navigationController)?.syntaxViewForTesting.text == "name=Jane Doe\ncity=Tokyo East"
                && bodyViewController(in: navigationController)?.syntaxViewForTesting.model.language == .plainText
                && bodyViewController(in: navigationController)?.syntaxViewForTesting.model.drawsBackground == false
        }
        #expect(didPushBody)
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
    func responseModeRequestsRuntimeFetchWhenBodyIsAvailable() async throws {
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

        viewController.loadViewIfNeeded()
        viewController.setModeForTesting(.response)

        let didFetch = await waitUntil {
            fetchedIDs == [request.id]
        }
        #expect(didFetch)
    }

    @Test
    func responseBodyLinkPrewarmsSyntaxWhileFetching() async throws {
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
        let navigationController = UINavigationController(rootViewController: viewController)
        let window = showInWindow(navigationController)
        defer { window.isHidden = true }

        viewController.setModeForTesting(.response)
        viewController.selectBodyLinkForTesting()

        let didStartFetching = await waitUntil {
            let bodyViewController = bodyViewController(in: navigationController)
            return fetchedIDs == [request.id]
                && viewController.currentModeForTesting == .response
                && bodyViewController?.syntaxViewForTesting.text.isEmpty == true
                && bodyViewController?.syntaxViewForTesting.model.language == .json
        }
        #expect(didStartFetching)

        request.applyResponseBody(
            NetworkBodyPayload(
                body: #"{"ok":true}"#,
                base64Encoded: false
            )
        )

        let didRenderBody = await waitUntil {
            return bodyViewController(in: navigationController)?.syntaxViewForTesting.text.contains(#""ok""#) == true
        }
        #expect(didRenderBody)
    }

    @Test
    func responseModeWaitsForLoadingFinishedBeforeFetching() async throws {
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

        viewController.setModeForTesting(.response)
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
        let navigationController = UINavigationController(rootViewController: viewController)
        let window = showInWindow(navigationController)
        defer { window.isHidden = true }

        viewController.setModeForTesting(.response)
        viewController.selectBodyLinkForTesting()

        let didRenderFailure = await waitUntil {
            viewController.currentModeForTesting == .response
                && bodyViewController(in: navigationController)?.syntaxViewForTesting.text.isEmpty == false
        }
        #expect(didRenderFailure)
        #expect(fetchedIDs.isEmpty)

        request.markResponseBodyFailed(.unknown("Still unavailable"))

        let didStayIdle = await waitUntil {
            bodyViewController(in: navigationController)?.syntaxViewForTesting.text.contains("Still unavailable") == true
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

    private func bodyViewController(in navigationController: UINavigationController) -> NetworkBodyViewController? {
        navigationController.topViewController as? NetworkBodyViewController
    }

    private func selectListItem(
        at indexPath: IndexPath,
        in viewController: NetworkListViewController
    ) {
        let collectionView = viewController.collectionViewForTesting
        collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        viewController.collectionView(collectionView, didSelectItemAt: indexPath)
    }

    private func listCellText(
        in collectionView: UICollectionView,
        at indexPath: IndexPath
    ) -> String? {
        collectionView.cellForItem(at: indexPath)?
            .contentConfiguration
            .flatMap { $0 as? UIListContentConfiguration }?
            .text
    }

    private func listCellSecondaryText(
        in collectionView: UICollectionView,
        at indexPath: IndexPath
    ) -> String? {
        collectionView.cellForItem(at: indexPath)?
            .contentConfiguration
            .flatMap { $0 as? UIListContentConfiguration }?
            .secondaryText
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
