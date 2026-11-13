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
struct NetworkDetailViewControllerTests: NetworkDetailTestSupport {
    @Test
    func detailShowsEmptyStateWithoutSelection() {
        let model = NetworkPanelModel(context: makeContext())
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(viewController.previewViewForTesting.isHidden)
        #expect(viewController.headersTextViewForTesting.isHidden)
        #expect(viewController.securityViewControllerForTesting.view.isHidden)
        #expect(viewController.securityViewControllerForTesting.snapshotForTesting.itemIdentifiers.isEmpty)
        #expect(viewController.cookiesViewControllerForTesting.view.isHidden)
        #expect(viewController.cookiesViewControllerForTesting.snapshotForTesting.itemIdentifiers.isEmpty)
        #expect(viewController.webSocketPreviewViewControllerForTesting.view.isHidden)
        #expect(
            viewController.webSocketPreviewViewControllerForTesting
                .snapshotForTesting.itemIdentifiers.isEmpty
        )
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

        let model = NetworkPanelModel(context: makeContext())
        let viewController = NetworkDetailViewController(model: model)
        viewController.traitOverrides.webInspectorDrawsBackground = false

        viewController.loadViewIfNeeded()

        #expect(viewController.view.backgroundColor == .clear)
        #expect(viewController.headersTextViewForTesting.backgroundColor == .clear)
        #expect(viewController.securityViewControllerForTesting.collectionView.backgroundColor == .clear)
        #expect(viewController.cookiesViewControllerForTesting.collectionView.backgroundColor == .clear)
        #expect(
            viewController.webSocketPreviewViewControllerForTesting.collectionView.backgroundColor
                == .clear
        )
        #expect(viewController.bodyViewControllerForTesting.view.backgroundColor == .clear)
    }

    @Test
    func detailContentKeepsPreviewRoleControlInSafeArea() {
        let model = NetworkPanelModel(context: makeContext())
        let viewController = NetworkDetailViewController(model: model)
        viewController.additionalSafeAreaInsets = UIEdgeInsets(top: 44, left: 120, bottom: 10, right: 24)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        viewController.view.layoutIfNeeded()

        let leadingInset = viewController.view.safeAreaLayoutGuide.layoutFrame.minX
        let topInset = viewController.view.safeAreaLayoutGuide.layoutFrame.minY
        let trailingInset = viewController.view.safeAreaLayoutGuide.layoutFrame.maxX
        let bounds = viewController.view.bounds
        let securityView: UIView = viewController.securityViewControllerForTesting.view
        let cookiesView: UIView = viewController.cookiesViewControllerForTesting.view
        let webSocketView: UIView = viewController.webSocketPreviewViewControllerForTesting.view
        for contentView in [
            viewController.headersTextViewForTesting,
            viewController.previewViewForTesting,
            securityView,
            cookiesView,
            webSocketView,
        ] {
            #expect(contentView.frame.minX == leadingInset)
            #expect(contentView.frame.maxX == trailingInset)
            #expect(contentView.frame.maxY == bounds.maxY)
        }
        #expect(viewController.headersTextViewForTesting.frame.minY == bounds.minY)
        #expect(viewController.previewViewForTesting.frame.minY == bounds.minY)
        #expect(securityView.frame.minY == bounds.minY)
        #expect(cookiesView.frame.minY == bounds.minY)
        #expect(webSocketView.frame.minY == bounds.minY)
        #expect(viewController.previewRoleControlContainerViewForTesting.frame.minY == topInset)
    }

    @Test
    func detailModeControlSwitchesHeadersPreviewCookiesAndSecurity() async throws {
        let context = makeContext()
        let request = try #require(
            await applyRequest(
                to: context,
                requestID: "1",
                url: "https://example.com/api/data.json",
                requestHeaders: [
                    "accept": "application/json",
                    "Cookie": "request-cookie=1",
                    "content-type": "application/x-www-form-urlencoded",
                ],
                postData: "name=Jane+Doe&city=Tokyo%20East",
                responseHeaders: [
                    "content-type": "application/json",
                    "Set-Cookie": "response-cookie=2; HttpOnly",
                ],
                responseMimeType: "application/json"
            )
        )
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderHeaders = await waitUntilRendered(in: viewController) {
            let text = viewController.headersTextViewForTesting.renderedTextForTesting
            return viewController.currentModeForTesting == .headers
                && viewController.previewViewForTesting.isHidden
                && viewController.headersTextViewForTesting.isHidden == false
                && viewController.securityViewControllerForTesting.view.isHidden
                && viewController.cookiesViewControllerForTesting.view.isHidden
                && viewController.webSocketPreviewViewControllerForTesting.view.isHidden
                && viewController.headersTextViewForTesting.usesTextKit2ForTesting
                && viewController.headersTextViewForTesting.isSelectableForTesting
                && text.contains("accept: application/json")
                && text.contains("content-type: application/json")
                && text.contains("200 OK")
        }

        #expect(didRenderHeaders)
        #expect(viewController.contentUnavailableConfiguration == nil)
        #expect(NetworkDetailViewController.Mode.allCases == [.headers, .preview, .cookies, .security])

        selectMode(.cookies, on: viewController)

        let didRenderCookies = await waitUntilRendered(in: viewController) {
            let items = viewController.cookiesViewControllerForTesting
                .snapshotForTesting.itemIdentifiers
            return viewController.currentModeForTesting == .cookies
                && viewController.previewViewForTesting.isHidden
                && viewController.headersTextViewForTesting.isHidden
                && viewController.securityViewControllerForTesting.view.isHidden
                && viewController.cookiesViewControllerForTesting.view.isHidden == false
                && viewController.webSocketPreviewViewControllerForTesting.view.isHidden
                && items.contains(where: isRequestCookieItem)
                && items.contains(where: isResponseCookieItem)
        }
        #expect(didRenderCookies)
        #expect(
            viewController.contentScrollView(for: .top)
                === viewController.cookiesViewControllerForTesting.collectionView
        )

        selectMode(.security, on: viewController)

        let didRenderSecurity = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .security
                && viewController.previewViewForTesting.isHidden
                && viewController.headersTextViewForTesting.isHidden
                && viewController.cookiesViewControllerForTesting.view.isHidden
                && viewController.webSocketPreviewViewControllerForTesting.view.isHidden
                && viewController.securityViewControllerForTesting.view.isHidden == false
                && viewController.securityViewControllerForTesting.snapshotForTesting.sectionIdentifiers
                    == [.status]
        }
        #expect(didRenderSecurity)
        #expect(
            viewController.contentScrollView(for: .top)
                === viewController.securityViewControllerForTesting.collectionView
        )
        #expect(viewController.responseBodyFetchObservationDeliveryForTesting == nil)
        #expect(request.responseBody.phase == .available)

        selectMode(.preview, on: viewController)

        let didRenderPreview = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .preview
                && viewController.previewViewForTesting.isHidden == false
                && viewController.headersTextViewForTesting.isHidden
                && viewController.securityViewControllerForTesting.view.isHidden
                && viewController.cookiesViewControllerForTesting.view.isHidden
                && viewController.webSocketPreviewViewControllerForTesting.view.isHidden
                && viewController.isPreviewRoleControlHiddenForTesting == false
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
    func detailModeControlDisablesWhenSelectedRequestDisappears() async throws {
        let context = makeContext()
        let request = try #require(
            await applyRequest(
                to: context,
                requestID: "1",
                url: "https://example.com/form",
                postData: "name=Jane+Doe"
            )
        )
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didEnableMenu = await waitUntilRendered(in: viewController) {
            viewController.isDetailModeControlEnabledForTesting
        }
        #expect(didEnableMenu)

        context.clearNetworkRequests()

        let didDisableMenu = await waitUntilRendered(in: viewController) {
            viewController.isDetailModeControlEnabledForTesting == false
                && viewController.contentUnavailableConfiguration != nil
        }
        #expect(didDisableMenu)
    }

    @Test
    func selectedRequestRebindingIgnoresOldRequestMutations() async throws {
        let context = makeContext()
        let firstRequest = try #require(
            await applyRequest(
                to: context,
                requestID: "1",
                url: "https://example.com/first.json",
                responseHeaders: ["x-request": "first"],
                responseMimeType: "application/json"
            )
        )
        let secondRequest = try #require(
            await applyRequest(
                to: context,
                requestID: "2",
                url: "https://example.com/second.json",
                responseHeaders: ["x-request": "second"],
                responseMimeType: "application/json"
            )
        )
        let model = NetworkPanelModel(context: context)
        model.selectRequest(firstRequest)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.headers)

        let didRenderFirst = await waitUntilRendered(in: viewController) {
            viewController.headersTextViewForTesting.renderedTextForTesting.contains("x-request: first")
        }
        #expect(didRenderFirst)

        viewController.headersTextViewForTesting.selectedRangeForTesting = NSRange(
            location: 2,
            length: 4
        )
        model.selectRequest(secondRequest)
        let didRenderSecond = await waitUntilRendered(in: viewController) {
            viewController.headersTextViewForTesting.renderedTextForTesting.contains("x-request: second")
        }
        #expect(didRenderSecond)
        #expect(
            viewController.headersTextViewForTesting.selectedRangeForTesting
                == NSRange(location: 0, length: 0)
        )

        let currentSelection = NSRange(location: 3, length: 5)
        viewController.headersTextViewForTesting.selectedRangeForTesting = currentSelection

        await applyResponseReceived(
            to: context,
            requestID: "1",
            url: "https://example.com/first.json",
            responseHeaders: ["x-old-request": "stale"],
            responseMimeType: "application/json",
            timestamp: 4
        )

        #expect(viewController.headersTextViewForTesting.renderedTextForTesting.contains("x-old-request: stale") == false)
        #expect(viewController.headersTextViewForTesting.selectedRangeForTesting == currentSelection)

        await applyResponseReceived(
            to: context,
            requestID: "2",
            url: "https://example.com/second.json",
            responseHeaders: ["x-current-request": "updated"],
            responseMimeType: "application/json",
            timestamp: 5
        )

        let didRenderCurrentUpdate = await waitUntilRendered(in: viewController) {
            let text = viewController.headersTextViewForTesting.renderedTextForTesting
            return text.contains("x-current-request: updated")
                && text.contains("x-old-request: stale") == false
        }
        #expect(didRenderCurrentUpdate)
        #expect(
            viewController.headersTextViewForTesting.selectedRangeForTesting
                == NSRange(location: 0, length: 0)
        )
    }
}
}
#endif
