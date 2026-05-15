#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorCore
@testable import WebInspectorUI

@MainActor
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
        }
        #expect(didSwitch)
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
        let didPop = await waitUntil {
            navigationController.viewControllers == [listViewController]
        }
        #expect(didPop)
    }

    private func applyRequest(
        to network: NetworkSession,
        requestID rawRequestID: String,
        url: String,
        requestHeaders: [String: String] = [:],
        postData: String? = nil,
        responseHeaders: [String: String] = ["content-type": "text/javascript"],
        responseMimeType: String = "text/javascript"
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
        network.applyLoadingFinished(
            targetID: targetID,
            requestID: requestID,
            timestamp: 3
        )
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
}
#endif
