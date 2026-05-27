#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorCore
@testable import WebInspectorUI

@MainActor
@Suite(.serialized)
struct NetworkDetailViewControllerTests {
    @Test
    func detailShowsEmptyStateWithoutSelection() {
        let model = NetworkPanelModel(network: NetworkSession())
        let viewController = NetworkDetailViewController(model: model)

        viewController.loadViewIfNeeded()

        #expect(viewController.collectionViewForTesting.isHidden)
        #expect(viewController.contentUnavailableConfiguration != nil)
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
    func detailRendersOverviewRequestAndResponseHeaders() async throws {
        let network = NetworkSession()
        let request = try #require(
            applyRequest(
                to: network,
                requestID: "1",
                url: "https://example.com/api/data.json",
                requestHeaders: ["accept": "application/json"],
                responseHeaders: ["content-type": "application/json"]
            )
        )
        let model = NetworkPanelModel(network: network)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let collectionView = viewController.collectionViewForTesting
        let didRender = await waitUntil {
            collectionView.numberOfSections == 3
                && collectionView.numberOfItems(inSection: 0) == 1
                && collectionView.numberOfItems(inSection: 1) == 1
                && collectionView.numberOfItems(inSection: 2) == 1
                && listCellSecondaryText(in: collectionView, at: IndexPath(item: 0, section: 0)) == "https://example.com/api/data.json"
                && listCellText(in: collectionView, at: IndexPath(item: 0, section: 1)) == "accept"
                && listCellSecondaryText(in: collectionView, at: IndexPath(item: 0, section: 1)) == "application/json"
                && listCellText(in: collectionView, at: IndexPath(item: 0, section: 2)) == "content-type"
                && listCellSecondaryText(in: collectionView, at: IndexPath(item: 0, section: 2)) == "application/json"
        }

        #expect(didRender)
        #expect(viewController.contentUnavailableConfiguration == nil)
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

        let didRenderEmptyResponseHeaders = await waitUntil {
            let collectionView = viewController.collectionViewForTesting
            return collectionView.numberOfSections == 3
                && collectionView.numberOfItems(inSection: 2) == 1
                && listCellText(in: collectionView, at: IndexPath(item: 0, section: 2)) == "No headers"
        }
        #expect(didRenderEmptyResponseHeaders)

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
            let collectionView = viewController.collectionViewForTesting
            return collectionView.numberOfItems(inSection: 2) == 1
                && listCellText(in: collectionView, at: IndexPath(item: 0, section: 2)) == "content-type"
                && listCellSecondaryText(in: collectionView, at: IndexPath(item: 0, section: 2)) == "application/json"
        }
        #expect(didRenderResponseHeaders)
    }

    @Test
    func detailModeMenuUsesCoreBodyAvailabilityAndRendersRequestBody() async throws {
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

        let didRender = await waitUntil {
            viewController.collectionViewForTesting.numberOfSections == 3
        }
        #expect(didRender)

        let requestAction = try action(for: .requestBody, in: viewController.modeMenuForTesting)
        #expect(requestAction.attributes.contains(.disabled) == false)

        requestAction.performWithSender(nil, target: nil)

        let didSwitch = await waitUntil {
            viewController.currentModeForTesting == .requestBody
                && viewController.bodyTextViewForTesting.text == "name=Jane Doe\ncity=Tokyo East"
                && viewController.bodyTextViewForTesting.configuration.drawsBackground == false
        }
        #expect(didSwitch)
    }

    @Test
    func detailModeMenuDisablesWhenSelectedRequestDisappears() async throws {
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
            viewController.navigationItem.trailingItemGroups.first?.barButtonItems.first?.isEnabled == true
        }
        #expect(didEnableMenu)

        network.reset()

        let didDisableMenu = await waitUntil {
            viewController.navigationItem.trailingItemGroups.first?.barButtonItems.first?.isEnabled == false
                && viewController.contentUnavailableConfiguration != nil
        }
        #expect(didDisableMenu)
    }

    @Test
    func responseBodyModeRequestsRuntimeFetchWhenBodyIsAvailable() async throws {
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
        viewController.setModeForTesting(.responseBody)

        let didFetch = await waitUntil {
            fetchedIDs == [request.id]
        }
        #expect(didFetch)
    }

    @Test
    func responseBodyModePrewarmsSyntaxAndShowsNavigationActivityWhileFetching() async throws {
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

        let indicatorItem = try #require(bodyFetchIndicatorItem(in: viewController))
        viewController.setModeForTesting(.responseBody)

        let didStartFetching = await waitUntil {
            guard let activityIndicator = indicatorItem.customView as? UIActivityIndicatorView else {
                return false
            }
            return fetchedIDs == [request.id]
                && viewController.currentModeForTesting == .responseBody
                && viewController.bodyTextViewForTesting.text.isEmpty
                && viewController.bodyTextViewForTesting.configuration.language == .json
                && indicatorItem.isHidden == false
                && activityIndicator.isAnimating
        }
        #expect(didStartFetching)

        request.applyResponseBody(
            NetworkBodyPayload(
                body: #"{"ok":true}"#,
                base64Encoded: false
            )
        )

        let didRenderBody = await waitUntil {
            guard let activityIndicator = indicatorItem.customView as? UIActivityIndicatorView else {
                return false
            }
            return viewController.bodyTextViewForTesting.text.contains(#""ok""#)
                && indicatorItem.isHidden
                && activityIndicator.isAnimating == false
        }
        #expect(didRenderBody)
    }

    @Test
    func responseBodyModeWaitsForLoadingFinishedBeforeFetching() async throws {
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

        viewController.setModeForTesting(.responseBody)
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

        viewController.setModeForTesting(.responseBody)

        let didRenderFailure = await waitUntil {
            viewController.currentModeForTesting == .responseBody
                && viewController.bodyTextViewForTesting.text.contains("Body unavailable")
        }
        #expect(didRenderFailure)
        #expect(fetchedIDs.isEmpty)

        request.markResponseBodyFailed(.unknown("Still unavailable"))

        let didStayIdle = await waitUntil {
            viewController.bodyTextViewForTesting.text.contains("Still unavailable")
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

        model.selectRequest(nil)
        let didPop = await waitUntilAllowingAnimations {
            navigationController.viewControllers == [listViewController]
        }
        #expect(didPop)
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

        network.reset()
        #expect(model.selectedRequestID == request.id)
        #expect(model.selectedRequest == nil)

        let didPop = await waitUntilAllowingAnimations {
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

    private func action(
        for mode: NetworkDetailMode,
        in menu: UIMenu
    ) throws -> UIAction {
        try #require(action(title: mode.title, in: menu))
    }

    private func action(title: String, in menu: UIMenu) -> UIAction? {
        for child in menu.children {
            if let action = child as? UIAction, action.title == title {
                return action
            }
            if let submenu = child as? UIMenu, let nested = action(title: title, in: submenu) {
                return nested
            }
        }
        return nil
    }

    private func bodyFetchIndicatorItem(in viewController: NetworkDetailViewController) -> UIBarButtonItem? {
        viewController.navigationItem.trailingItemGroups
            .flatMap(\.barButtonItems)
            .first {
                $0.accessibilityIdentifier == "WebInspector.Network.BodyFetchIndicatorItem"
            }
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

    private func waitUntilAllowingAnimations(
        maxTicks: Int = 256,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<maxTicks {
            if condition() {
                return true
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}
#endif
