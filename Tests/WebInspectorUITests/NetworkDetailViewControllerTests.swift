#if canImport(UIKit)
import AVFoundation
import ObservationBridge
import Synchronization
import Testing
import WebInspectorDataKit
import WebInspectorProxyKit
import UIKit
@testable import WebInspectorUI
@testable import WebInspectorUISyntaxBody
@testable import WebInspectorUINetwork
@testable import WebInspectorUIBase

extension WebInspectorUIRenderingTests {
@MainActor
@Suite
struct NetworkDetailViewControllerTests {
    @Test
    func resourceFilterSpecialistTitlesFollowWebInspectorLabels() {
        #expect(NetworkDisplay.ResourceFilter.stylesheet.localizedTitle == "CSS")
        #expect(NetworkDisplay.ResourceFilter.media.localizedTitle == String(localized: "network.filter.media", bundle: WebInspectorUILocalization.bundle))
        #expect(localizedResourceString("network.filter.media", locale: "en") == "Media")
        #expect(NetworkDisplay.ResourceFilter.script.localizedTitle == "JS")
        #expect(NetworkDisplay.ResourceFilter.xhrFetch.localizedTitle == "XHR / Fetch")
    }

    @Test
    func listShowsSimpleEmptyStateWithoutRequests() {
        let model = NetworkPanelModel(context: makeContext())
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
        let model = NetworkPanelModel(context: makeContext())
        let viewController = makeNetworkDetailViewController(model: model)
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

        let model = NetworkPanelModel(context: makeContext())
        let viewController = makeNetworkDetailViewController(model: model)
        viewController.traitOverrides.webInspectorDrawsBackground = false

        viewController.loadViewIfNeeded()

        #expect(viewController.view.backgroundColor == .clear)
        #expect(viewController.headersTextViewForTesting.backgroundColor == .clear)
        #expect(viewController.syntaxBodyViewControllerForTesting.view.backgroundColor == .clear)
    }

    @Test
    func listCanDisableBackgroundDrawing() {
        guard #available(iOS 26.0, *) else {
            return
        }

        let model = NetworkPanelModel(context: makeContext())
        let viewController = NetworkListViewController(model: model)
        viewController.traitOverrides.webInspectorDrawsBackground = false

        viewController.loadViewIfNeeded()

        #expect(viewController.collectionViewForTesting.backgroundColor == .clear)
    }

    @Test
    func listLoadDefersFilterMenuBuildUntilPresentation() throws {
        let model = NetworkPanelModel(context: makeContext())
        model.setResourceFilter(.media, enabled: true)
        let viewController = NetworkListViewController(model: model)

        viewController.loadViewIfNeeded()

        let filterItem = viewController.filterItemForTesting
        #expect(filterItem.accessibilityIdentifier == "WebInspector.Network.FilterButton")
        #expect(filterItem.isSelected)
        #expect(viewController.filterMenuBuildCountForTesting == 0)
        let menu = try #require(filterItem.menu)
        #expect(menu.children.count == 1)
        let child = try #require(menu.children.first)
        #expect(child is UIDeferredMenuElement)
    }

    @Test
    func listLoadDoesNotEvaluateDisplayRequestsUntilAppearing() async throws {
        let context = makeContext()
        _ = try #require(applyRequest(
            to: context,
            requestID: "1",
            url: "https://example.com/api/data.json",
            responseHeaders: ["content-type": "application/json"],
            responseMimeType: "application/json"
        ))
        let model = NetworkPanelModel(context: context)
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
        let model = NetworkPanelModel(context: makeContext())
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = makeNetworkDetailViewController(model: model)
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
        let model = NetworkPanelModel(context: makeContext())
        let viewController = makeNetworkDetailViewController(model: model)
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
        let context = makeContext()
        let request = try #require(
            applyRequest(
                to: context,
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
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = makeNetworkDetailViewController(model: model)
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
                    && viewController.previewRoleScrollEdgeInteractionForTesting?.scrollView === viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting
                    && viewController.contentScrollView(for: .top) === viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting
                    && viewController.contentScrollView(for: .bottom) === viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting
            }
            return didRenderPreview
        }
        #expect(didRenderPreview)

        viewController.selectPreviewRoleForTesting(.request)

        let didRenderRequestPreview = await waitUntilRendered(in: viewController) {
            viewController.currentPreviewRoleForTesting == .request
                && viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text == "name=Jane Doe\ncity=Tokyo East"
        }
        #expect(didRenderRequestPreview)
    }

    @Test
    func previewTextBodyUsesAutomaticInsetsAsRegisteredContentScrollView() async throws {
        let context = makeContext()
        let request = try #require(
            applyRequest(
                to: context,
                requestID: "1",
                url: "https://example.com/api/data.txt",
                responseHeaders: ["content-type": "text/plain"],
                responseMimeType: "text/plain"
            )
        )
        applyResponseBody(to: context, request: request, body: "sample=true\nsource=preview", base64Encoded: false)
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = makeNetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didRenderPreview = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .preview
                && viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text == "sample=true\nsource=preview"
        }
        #expect(didRenderPreview)

        let bodyViewController = viewController.syntaxBodyViewControllerForTesting
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
        let context = makeContext()
        let bodyRequest = try #require(
            applyRequestWithoutResponse(
                to: context,
                requestID: "body",
                url: "https://example.com/form",
                requestHeaders: ["content-type": "application/x-www-form-urlencoded"],
                postData: "name=Jane+Doe"
            )
        )
        let emptyRequest = try #require(
            applyRequestWithoutResponse(
                to: context,
                requestID: "empty",
                url: "https://example.com/no-body"
            )
        )
        let model = NetworkPanelModel(context: context)
        model.selectRequest(bodyRequest)
        let viewController = makeNetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didRenderBody = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .preview
                && viewController.currentPreviewRoleForTesting == .request
                && viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text == "name=Jane Doe"
        }
        #expect(didRenderBody)

        model.selectRequest(emptyRequest)

        let unavailableText = String(localized: "network.body.unavailable", bundle: WebInspectorUILocalization.bundle)
        let didReplaceBody = await waitUntilRendered(in: viewController) {
            viewController.previewViewForTesting.isHidden == false
                && viewController.isPreviewRoleControlHiddenForTesting
                && viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text == unavailableText
        }
        #expect(didReplaceBody)
        #expect(viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text.contains("Jane") == false)
    }

    @Test
    func responseOnlyPreviewRoleExpandsToBothWithoutChangingLogicalSelection() async throws {
        let context = makeContext()
        let responseOnlyRequest = try #require(
            applyRequest(
                to: context,
                requestID: "response-only",
                url: "https://example.com/response.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        let requestAndResponse = try #require(
            applyRequest(
                to: context,
                requestID: "both",
                url: "https://example.com/both.json",
                requestHeaders: ["content-type": "application/x-www-form-urlencoded"],
                postData: "name=Jane+Doe",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        let model = NetworkPanelModel(context: context)
        model.selectRequest(responseOnlyRequest)
        let viewController = makeNetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didRenderResponseOnly = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .preview
                && viewController.currentPreviewRoleForTesting == .response
                && viewController.isPreviewRoleControlHiddenForTesting
        }
        #expect(didRenderResponseOnly)

        model.selectRequest(requestAndResponse)

        let didRenderBoth = await waitUntilRendered(in: viewController) {
            viewController.currentPreviewRoleForTesting == .response
                && viewController.isPreviewRoleControlHiddenForTesting == false
        }
        #expect(didRenderBoth)
    }

    @Test
    func requestPreviewRoleSurvivesResponseOnlySelection() async throws {
        let context = makeContext()
        let requestAndResponse = try #require(
            applyRequest(
                to: context,
                requestID: "both",
                url: "https://example.com/both.json",
                requestHeaders: ["content-type": "application/x-www-form-urlencoded"],
                postData: "name=Jane+Doe",
                responseHeaders: ["content-type": "text/plain"],
                responseMimeType: "text/plain"
            )
        )
        let responseOnlyRequest = try #require(
            applyRequest(
                to: context,
                requestID: "response-only",
                url: "https://example.com/response.txt",
                responseHeaders: ["content-type": "text/plain"],
                responseMimeType: "text/plain"
            )
        )
        applyResponseBody(to: context, request: responseOnlyRequest, body: "response only body", base64Encoded: false)
        let model = NetworkPanelModel(context: context)
        model.selectRequest(requestAndResponse)
        let viewController = makeNetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didRenderBoth = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .preview
                && viewController.isPreviewRoleControlHiddenForTesting == false
        }
        #expect(didRenderBoth)

        viewController.selectPreviewRoleForTesting(.request)

        let didRenderRequestPreview = await waitUntilRendered(in: viewController) {
            viewController.currentPreviewRoleForTesting == .request
                && viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text == "name=Jane Doe"
        }
        #expect(didRenderRequestPreview)

        model.selectRequest(responseOnlyRequest)

        let didRenderResponseOnly = await waitUntilRendered(in: viewController) {
            viewController.currentPreviewRoleForTesting == .response
                && viewController.logicalPreviewRoleForTesting == .request
                && viewController.isPreviewRoleControlHiddenForTesting
                && viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text == "response only body"
        }
        #expect(didRenderResponseOnly)

        model.selectRequest(requestAndResponse)

        let didRestoreRequestPreview = await waitUntilRendered(in: viewController) {
            viewController.currentPreviewRoleForTesting == .request
                && viewController.logicalPreviewRoleForTesting == .request
                && viewController.isPreviewRoleControlHiddenForTesting == false
                && viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text == "name=Jane Doe"
        }
        #expect(didRestoreRequestPreview)
    }

    @Test
    func previewRequestWithoutBodyRendersPlaceholderWhenBodySurfaceResumes() async throws {
        let context = makeContext()
        let request = try #require(
            applyRequestWithoutResponse(
                to: context,
                requestID: "1",
                url: "https://example.com/no-body"
            )
        )
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = makeNetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderHeaders = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .headers
                && viewController.previewViewForTesting.isHidden
                && viewController.headersTextViewForTesting.renderedTextForTesting.contains("GET /no-body")
        }
        #expect(didRenderHeaders)

        viewController.setModeForTesting(.preview)

        let unavailableText = String(localized: "network.body.unavailable", bundle: WebInspectorUILocalization.bundle)
        let didRenderPlaceholder = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .preview
                && viewController.previewViewForTesting.isHidden == false
                && viewController.isPreviewRoleControlHiddenForTesting
                && viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text == unavailableText
        }
        #expect(didRenderPlaceholder)
    }

    @Test
    func detailUpdatesResponseHeadersAfterSelection() async throws {
        let context = makeContext()
        let request = try #require(
            applyRequestWithoutResponse(
                to: context,
                requestID: "1",
                url: "https://example.com/api/data.json"
            )
        )
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = makeNetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.headers)

        let didRenderRequestHeaders = await waitUntilRendered(in: viewController) {
            viewController.headersTextViewForTesting.renderedTextForTesting.contains("GET /api/data.json")
        }
        #expect(didRenderRequestHeaders)

        applyResponseReceived(
            to: context,
            requestID: "1",
            url: "https://example.com/api/data.json",
            responseHeaders: ["content-type": "application/json"],
            responseMimeType: "application/json",
            timestamp: 2
        )

        let didRenderResponseHeaders = await waitUntilRendered(in: viewController) {
            viewController.headersTextViewForTesting.renderedTextForTesting.contains("content-type: application/json")
        }
        #expect(didRenderResponseHeaders)
    }

    @Test
    func detailModeControlUsesCoreBodyAvailabilityAndRendersRequestBody() async throws {
        let context = makeContext()
        let request = try #require(
            applyRequest(
                to: context,
                requestID: "1",
                url: "https://example.com/form",
                requestHeaders: ["content-type": "application/x-www-form-urlencoded"],
                postData: "name=Jane+Doe&city=Tokyo%20East",
                responseHeaders: [:],
                responseMimeType: "text/plain"
            )
        )
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = makeNetworkDetailViewController(model: model)
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
            viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text == "name=Jane Doe\ncity=Tokyo East"
                && viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.model.language == .plainText
                && viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.model.drawsBackground == false
        }
        #expect(didRenderBody)
    }

    @Test
    func detailModeControlDisablesWhenSelectedRequestDisappears() async throws {
        let context = makeContext()
        let request = try #require(
            applyRequest(
                to: context,
                requestID: "1",
                url: "https://example.com/form",
                postData: "name=Jane+Doe"
            )
        )
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = makeNetworkDetailViewController(model: model)
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
    func responsePreviewRequestsRuntimeFetchWhenBodyIsAvailable() async throws {
        let context = makeContext()
        let request = try #require(
            applyRequest(
                to: context,
                requestID: "1",
                url: "https://example.com/api/data.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = makeNetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didFetch = await waitUntilRendered(in: viewController) {
            guard case .failed = request.responseBody.phase else {
                return false
            }
            return viewController.currentModeForTesting == .preview
                && viewController.currentPreviewRoleForTesting == .response
        }
        #expect(didFetch)
    }

    @Test
    func responsePreviewPrewarmsSyntaxWhileFetching() async throws {
        let context = makeContext()
        let request = try #require(
            applyRequest(
                to: context,
                requestID: "1",
                url: "https://example.com/api/data.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = makeNetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didStartFetching = await waitUntilRendered(in: viewController) {
            guard case .failed = request.responseBody.phase else {
                return false
            }
            return viewController.currentModeForTesting == .preview
                && viewController.currentPreviewRoleForTesting == .response
                && viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.model.language == .json
        }
        #expect(didStartFetching)

        applyResponseBody(to: context, request: request, body: #"{"ok":true}"#, base64Encoded: false)

        let didRenderBody = await waitUntilRendered(in: viewController) {
            return viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text.contains(#""ok""#)
        }
        #expect(didRenderBody)
    }

    @Test
    func hiddenDetailDoesNotFetchResponseBodyUntilAppearingAgain() async throws {
        let context = makeContext()
        let request = try #require(
            applyRequest(
                to: context,
                requestID: "1",
                url: "https://example.com/api/data.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = makeNetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.headers)

        let didRenderHeaders = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .headers
                && viewController.headersTextViewForTesting.renderedTextForTesting.contains("content-type: application/json")
        }
        #expect(didRenderHeaders)
        #expect(request.responseBody.phase == .available)

        viewController.beginAppearanceTransition(false, animated: false)
        viewController.endAppearanceTransition()
        viewController.setModeForTesting(.preview)

        #expect(request.responseBody.phase == .available)
        #expect(viewController.headersTextViewForTesting.renderedTextForTesting.contains("content-type: application/json"))

        viewController.beginAppearanceTransition(true, animated: false)
        viewController.endAppearanceTransition()

        let didFetchOnReturn = await waitUntilRendered(in: viewController) {
            guard case .failed = request.responseBody.phase else {
                return false
            }
            return viewController.currentModeForTesting == .preview
                && viewController.currentPreviewRoleForTesting == .response
        }
        #expect(didFetchOnReturn)
    }

    @Test
    func hiddenDetailKeepsDisplayedBodyAndReconcilesBodyOnReturn() async throws {
        let context = makeContext()
        let request = try #require(
            applyRequest(
                to: context,
                requestID: "1",
                url: "https://example.com/api/data.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        applyResponseBody(to: context, request: request, body: #"{"visible":true}"#, base64Encoded: false)
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = makeNetworkDetailViewController(model: model, initialMode: .preview)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderVisibleBody = await waitUntilRendered(in: viewController) {
            viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text.contains(#""visible" : true"#)
        }
        #expect(didRenderVisibleBody)
        let renderedBodyBeforeHide = viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text

        viewController.beginAppearanceTransition(false, animated: false)
        viewController.endAppearanceTransition()
        applyResponseBody(to: context, request: request, body: #"{"hidden":true}"#, base64Encoded: false)

        #expect(viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text == renderedBodyBeforeHide)

        viewController.beginAppearanceTransition(true, animated: false)
        viewController.endAppearanceTransition()

        let didRenderHiddenBody = await waitUntilRendered(in: viewController) {
            viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text.contains(#""hidden" : true"#)
        }
        #expect(didRenderHiddenBody)
    }

    @Test
    func deeplyNestedJSONPreviewFallsBackToRawText() async throws {
        let context = makeContext()
        let request = try #require(
            applyRequest(
                to: context,
                requestID: "1",
                url: "https://example.com/api/deep.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        let bodyText = String(repeating: "[", count: 160) + "0" + String(repeating: "]", count: 160)
        applyResponseBody(to: context, request: request, body: bodyText, base64Encoded: false)
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = makeNetworkDetailViewController(model: model, initialMode: .preview)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderRawBody = await waitUntilRendered(in: viewController) {
            viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text == bodyText
        }
        #expect(didRenderRawBody)

        await viewController.syntaxBodyViewControllerForTesting.waitUntilTextPreviewPreparationFinishedForTesting()

        #expect(viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text == bodyText)
    }

    @Test
    func jsonPreviewFormatsCRLFWhitespace() async throws {
        let context = makeContext()
        let request = try #require(
            applyRequest(
                to: context,
                requestID: "1",
                url: "https://example.com/api/data.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        let bodyText = "{\r\n\"a\":1,\r\n\"b\":[true]\r\n}"
        applyResponseBody(to: context, request: request, body: bodyText, base64Encoded: false)
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = makeNetworkDetailViewController(model: model, initialMode: .preview)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderPrettyBody = await waitUntilRendered(in: viewController) {
            viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text == """
            {
              "a" : 1,
              "b" : [
                true
              ]
            }
            """
        }

        #expect(didRenderPrettyBody)
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
        let context = makeContext()
        let request = try #require(
            applyRequest(
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
        let viewController = makeNetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.syntaxBodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer(for:)
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)
        await waitUntilMediaPreviewPrepared(in: viewController)

        let didRenderMediaPreview = await waitUntilRendered(in: viewController) {
            viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting?.pathExtension == "mp4"
        }
        #expect(didRenderMediaPreview)
        let temporaryFileURL = try #require(viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting)
        #expect(playerFactory.requestedURLs == [temporaryFileURL])
        #expect(FileManager.default.fileExists(atPath: temporaryFileURL.path))

        viewController.setModeForTesting(.headers)

        let didReleaseMediaPreview = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .headers
                && viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting == nil
                && FileManager.default.fileExists(atPath: temporaryFileURL.path) == false
        }
        #expect(didReleaseMediaPreview)
        #expect(playerFactory.requestedURLs == [temporaryFileURL])

        viewController.setModeForTesting(.preview)
        await waitUntilMediaPreviewPrepared(in: viewController)

        let didRestoreMediaPreview = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .preview
                && viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting?.pathExtension == "mp4"
        }
        #expect(didRestoreMediaPreview)
        #expect(playerFactory.requestedURLs.count == 2)
        #expect(playerFactory.requestedURLs.allSatisfy { $0.pathExtension == "mp4" })
    }

    @Test
    func mediaResponsePreviewReusesPlayerAndTemporaryFileWhenRequestUpdateDoesNotChangeBody() async throws {
        let context = makeContext()
        let request = try #require(
            applyRequest(
                to: context,
                requestID: "1",
                url: "https://media.example.com/download.php",
                responseHeaders: ["content-type": "video/mp4"],
                responseMimeType: "video/mp4",
                finishes: false
            )
        )
        applyResponseBody(to: context, request: request, body: "not a real movie", base64Encoded: false)
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = makeNetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.syntaxBodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer(for:)
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)
        await waitUntilMediaPreviewPrepared(in: viewController)

        let didRenderMediaPreview = await waitUntilRendered(in: viewController) {
            viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting?.pathExtension == "mp4"
                && viewController.syntaxBodyViewControllerForTesting.mediaPlayerIdentityForTesting != nil
        }
        #expect(didRenderMediaPreview)
        let temporaryFileURL = try #require(viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting)
        let playerIdentity = try #require(viewController.syntaxBodyViewControllerForTesting.mediaPlayerIdentityForTesting)
        #expect(playerFactory.requestedURLs == [temporaryFileURL])

        applyDataReceived(
            to: context,
            requestID: "1",
            dataLength: 128,
            encodedDataLength: 64,
            timestamp: 4
        )

        #expect(request.encodedDataLength == 64)
        #expect(viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting == temporaryFileURL)
        #expect(viewController.syntaxBodyViewControllerForTesting.mediaPlayerIdentityForTesting == playerIdentity)
        #expect(FileManager.default.fileExists(atPath: temporaryFileURL.path))
        #expect(playerFactory.requestedURLs == [temporaryFileURL])
    }

    @Test
    func mediaResponsePreviewPausesPlayerButKeepsSurfaceWhenHidden() async throws {
        let context = makeContext()
        let request = try #require(
            applyRequest(
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
        let viewController = makeNetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.syntaxBodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer(for:)
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)
        await waitUntilMediaPreviewPrepared(in: viewController)

        let didRenderMediaPreview = await waitUntilRendered(in: viewController) {
            viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting?.pathExtension == "mp4"
        }
        #expect(didRenderMediaPreview)
        let temporaryFileURL = try #require(viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting)
        let player = try #require(playerFactory.players.first)
        #expect(playerFactory.players.count == 1)
        #expect(player.pauseCallCount == 0)
        #expect(FileManager.default.fileExists(atPath: temporaryFileURL.path))

        viewController.beginAppearanceTransition(false, animated: false)
        viewController.endAppearanceTransition()

        #expect(player.pauseCallCount == 1)
        #expect(viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting == temporaryFileURL)
        #expect(FileManager.default.fileExists(atPath: temporaryFileURL.path))

        viewController.beginAppearanceTransition(true, animated: false)
        viewController.endAppearanceTransition()
        await waitUntilMediaPreviewPrepared(in: viewController)

        #expect(playerFactory.players.count == 1)
        #expect(viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting == temporaryFileURL)
        #expect(player.pauseCallCount == 1)
    }

    @Test
    func mediaResponsePreviewReleasesPlayerAndTemporaryFileWhenSelectionClears() async throws {
        let context = makeContext()
        let request = try #require(
            applyRequest(
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
        let viewController = makeNetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.syntaxBodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer(for:)
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)
        await waitUntilMediaPreviewPrepared(in: viewController)

        let didRenderMediaPreview = await waitUntilRendered(in: viewController) {
            viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting?.pathExtension == "mp4"
        }
        #expect(didRenderMediaPreview)
        let temporaryFileURL = try #require(viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting)
        #expect(playerFactory.requestedURLs == [temporaryFileURL])
        #expect(FileManager.default.fileExists(atPath: temporaryFileURL.path))

        model.selectRequest(nil)

        let didReleaseMediaPreview = await waitUntilRendered(in: viewController) {
            viewController.contentUnavailableConfiguration != nil
                && viewController.previewViewForTesting.isHidden
                && viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting == nil
                && FileManager.default.fileExists(atPath: temporaryFileURL.path) == false
        }
        #expect(didReleaseMediaPreview)
        #expect(playerFactory.requestedURLs == [temporaryFileURL])
    }

    @Test
    func hiddenMediaResponsePreviewReleasesPlayerAndTemporaryFileWhenSelectionClearsBeforeReappearing() async throws {
        let context = makeContext()
        let request = try #require(
            applyRequest(
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
        let viewController = makeNetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.syntaxBodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer(for:)
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)
        await waitUntilMediaPreviewPrepared(in: viewController)

        let didRenderMediaPreview = await waitUntilRendered(in: viewController) {
            viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting?.pathExtension == "mp4"
        }
        #expect(didRenderMediaPreview)
        let temporaryFileURL = try #require(viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting)
        #expect(playerFactory.requestedURLs == [temporaryFileURL])
        #expect(FileManager.default.fileExists(atPath: temporaryFileURL.path))

        viewController.beginAppearanceTransition(false, animated: false)
        viewController.endAppearanceTransition()
        model.selectRequest(nil)

        #expect(viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting == temporaryFileURL)
        #expect(FileManager.default.fileExists(atPath: temporaryFileURL.path))

        viewController.beginAppearanceTransition(true, animated: false)
        viewController.endAppearanceTransition()

        let didReleaseMediaPreview = await waitUntilRendered(in: viewController) {
            viewController.contentUnavailableConfiguration != nil
                && viewController.previewViewForTesting.isHidden
                && viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting == nil
                && FileManager.default.fileExists(atPath: temporaryFileURL.path) == false
        }
        #expect(didReleaseMediaPreview)
        #expect(playerFactory.requestedURLs == [temporaryFileURL])
    }

    @Test
    func imageResponsePreviewUsesScrollViewAndFitsLargeImage() async throws {
        let imageSize = CGSize(width: 600, height: 1400)
        let context = makeContext()
        let request = try #require(
            applyRequest(
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
        let viewController = makeNetworkDetailViewController(model: model)
        viewController.syntaxBodyViewControllerForTesting.additionalSafeAreaInsets = UIEdgeInsets(
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
            let bodyViewController = viewController.syntaxBodyViewControllerForTesting
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

        let imageScrollView = viewController.syntaxBodyViewControllerForTesting.imageScrollViewForTesting
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
            applyRequest(
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
        let viewController = makeNetworkDetailViewController(model: model)
        let window = showInWindow(viewController, makeVisible: true)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)
        await waitUntilMediaPreviewPrepared(in: viewController)

        let didRenderImage = await waitUntilRendered(in: viewController) {
            viewController.syntaxBodyViewControllerForTesting.isImagePreviewVisibleForTesting
        }
        #expect(didRenderImage)

        let imageScrollView = viewController.syntaxBodyViewControllerForTesting.imageScrollViewForTesting
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
        let context = makeContext()
        let request = try #require(
            applyRequest(
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
        let viewController = makeNetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)
        await waitUntilMediaPreviewPrepared(in: viewController)

        let didRenderImage = await waitUntilRendered(in: viewController) {
            viewController.syntaxBodyViewControllerForTesting.isImagePreviewVisibleForTesting
        }
        #expect(didRenderImage)

        let imageScrollView = viewController.syntaxBodyViewControllerForTesting.imageScrollViewForTesting
        #expect(imageScrollView.minimumZoomScale == 1)
        #expect(imageScrollView.zoomScale == 1)
        #expect(imageScrollView.contentInset == .zero)
        #expect(imageScrollView.contentAlignmentPoint == CGPoint(x: 0.5, y: 0.5))
    }

    @Test
    func responsePreviewWaitsForLoadingFinishedBeforeFetching() async throws {
        let context = makeContext()
        let request = try #require(
            applyRequest(
                to: context,
                requestID: "1",
                url: "https://example.com/api/data.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json",
                finishes: false
            )
        )
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = makeNetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        #expect(request.responseBody.phase == .available)

        applyLoadingFinished(to: context, requestID: "1", timestamp: 3)

        let didFetch = await waitUntilRendered(in: viewController) {
            guard case .failed = request.responseBody.phase else {
                return false
            }
            return true
        }
        #expect(didFetch)
    }

    @Test
    func failedResponseBodyDoesNotRefetchFromRendering() async throws {
        let context = makeContext()
        let request = try #require(
            applyRequest(
                to: context,
                requestID: "1",
                url: "https://example.com/api/data.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        let model = NetworkPanelModel(context: context)
        model.fetchResponseBodyIfNeeded(for: request)
        let didFailInitialFetch = await waitUntilNetworkBodyPhase {
            if case .failed = request.responseBody.phase {
                return true
            }
            return false
        }
        #expect(didFailInitialFetch)

        model.selectRequest(request)
        let viewController = makeNetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didRenderFailure = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .preview
                && viewController.currentPreviewRoleForTesting == .response
                && viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text.isEmpty == false
        }
        #expect(didRenderFailure)
        let failedPhase = request.responseBody.phase

        model.fetchResponseBodyIfNeeded(for: request)

        let didStayIdle = await waitUntilRendered(in: viewController) {
            request.responseBody.phase == failedPhase
        }
        #expect(didStayIdle)
    }

    @Test
    func headersModeDoesNotFetchResponseBody() async throws {
        let context = makeContext()
        let request = try #require(
            applyRequest(
                to: context,
                requestID: "1",
                url: "https://example.com/api/data.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = makeNetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.headers)

        let didRenderHeaders = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .headers
                && viewController.headersTextViewForTesting.renderedTextForTesting.contains("content-type: application/json")
        }
        #expect(didRenderHeaders)
        #expect(request.responseBody.phase == .available)
    }

    @Test
    func headersModePreservesSelectionWhenRequestUpdateDoesNotChangeDocument() async throws {
        let context = makeContext()
        let request = try #require(
            applyRequest(
                to: context,
                requestID: "1",
                url: "https://example.com/api/data.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json",
                finishes: false
            )
        )
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = makeNetworkDetailViewController(model: model)
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

        applyDataReceived(
            to: context,
            requestID: "1",
            dataLength: 128,
            encodedDataLength: 64,
            timestamp: 4
        )

        #expect(request.encodedDataLength == 64)
        #expect(viewController.headersTextViewForTesting.attributedTextAssignmentCountForTesting == assignmentCount)
        #expect(viewController.headersTextViewForTesting.selectedRangeForTesting == selectedRange)
    }

    @Test
    func hiddenDetailKeepsHeadersAndRebindsSameSelectedRequestOnReturn() async throws {
        let context = makeContext()
        let request = try #require(
            applyRequest(
                to: context,
                requestID: "1",
                url: "https://example.com/api/data.json",
                responseHeaders: ["x-request": "visible"],
                responseMimeType: "application/json"
            )
        )
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = makeNetworkDetailViewController(model: model)
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
        applyResponseReceived(
            to: context,
            requestID: "1",
            url: "https://example.com/api/data.json",
            responseHeaders: ["x-request": "hidden-update"],
            responseMimeType: "application/json",
            timestamp: 4
        )

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
        let context = makeContext()
        let request = try #require(
            applyRequest(
                to: context,
                requestID: "1",
                url: "https://example.com/api/data.json",
                requestHeaders: ["content-type": "application/x-www-form-urlencoded"],
                postData: "name=Jane+Doe",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json",
                finishes: false
            )
        )
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = makeNetworkDetailViewController(model: model)
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
                && viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text == "name=Jane Doe"
        }
        #expect(didRenderRequestBody)

        applyLoadingFinished(to: context, requestID: "1", timestamp: 3)

        let didStayOnRequestBody = await waitUntilRendered(in: viewController) {
            viewController.currentPreviewRoleForTesting == .request
                && viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text == "name=Jane Doe"
        }
        #expect(didStayOnRequestBody)
        #expect(request.responseBody.phase == .available)
    }

    @Test
    func selectedRequestRebindingIgnoresOldRequestMutations() async throws {
        let context = makeContext()
        let firstRequest = try #require(
            applyRequest(
                to: context,
                requestID: "1",
                url: "https://example.com/first.json",
                responseHeaders: ["x-request": "first"],
                responseMimeType: "application/json"
            )
        )
        let secondRequest = try #require(
            applyRequest(
                to: context,
                requestID: "2",
                url: "https://example.com/second.json",
                responseHeaders: ["x-request": "second"],
                responseMimeType: "application/json"
            )
        )
        let model = NetworkPanelModel(context: context)
        model.selectRequest(firstRequest)
        let viewController = makeNetworkDetailViewController(model: model)
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

        applyResponseReceived(
            to: context,
            requestID: "1",
            url: "https://example.com/first.json",
            responseHeaders: ["x-old-request": "stale"],
            responseMimeType: "application/json",
            timestamp: 4
        )

        #expect(viewController.headersTextViewForTesting.renderedTextForTesting.contains("x-old-request: stale") == false)

        applyResponseReceived(
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
    }

    @Test
    func previewRoleSwitchPreservesInstalledBodyViews() async throws {
        let context = makeContext()
        let request = try #require(
            applyRequest(
                to: context,
                requestID: "1",
                url: "https://example.com/api/data.json",
                requestHeaders: ["content-type": "application/x-www-form-urlencoded"],
                postData: "name=Jane+Doe",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = makeNetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didRenderPreview = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .preview
                && viewController.isPreviewRoleControlHiddenForTesting == false
        }
        #expect(didRenderPreview)

        let bodyViewControllerID = ObjectIdentifier(viewController.syntaxBodyViewControllerForTesting)
        let syntaxViewID = ObjectIdentifier(viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting)

        viewController.selectPreviewRoleForTesting(.request)
        let didRenderRequest = await waitUntilRendered(in: viewController) {
            viewController.currentPreviewRoleForTesting == .request
                && viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text == "name=Jane Doe"
        }
        #expect(didRenderRequest)

        viewController.selectPreviewRoleForTesting(.response)
        let didRenderResponse = await waitUntilRendered(in: viewController) {
            viewController.currentPreviewRoleForTesting == .response
        }
        #expect(didRenderResponse)
        #expect(ObjectIdentifier(viewController.syntaxBodyViewControllerForTesting) == bodyViewControllerID)
        #expect(ObjectIdentifier(viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting) == syntaxViewID)
    }

    @Test
    func rebindingPreviewBodyCancelsOutgoingTextPreparation() async throws {
        let context = makeContext()
        let firstRequest = try #require(
            applyRequest(
                to: context,
                requestID: "1",
                url: "https://example.com/api/large.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        let secondRequest = try #require(
            applyRequest(
                to: context,
                requestID: "2",
                url: "https://example.com/api/current.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        let largeJSON = "[" + (0..<80_000).map { #"{"value":\#($0),"enabled":true}"# }.joined(separator: ",") + "]"
        applyResponseBody(to: context, request: firstRequest, body: largeJSON, base64Encoded: false)
        applyResponseBody(to: context, request: secondRequest, body: #"{"ok":true}"#, base64Encoded: false)
        let firstBody = try #require(firstRequest.responseBody)
        let model = NetworkPanelModel(context: context)
        model.selectRequest(firstRequest)
        let viewController = makeNetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let firstBodyID = ObjectIdentifier(firstBody)
        let didStartFirstPreparation = await waitUntilRendered(in: viewController) {
            viewController.currentPreviewRoleForTesting == .response
                && viewController.syntaxBodyViewControllerForTesting.activeTextPreviewPreparationBodyIDForTesting == firstBodyID
        }
        #expect(didStartFirstPreparation)

        model.selectRequest(secondRequest)

        let didRenderSecondRequest = await waitUntilRendered(in: viewController) {
            viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text.contains(#""ok""#)
                && viewController.syntaxBodyViewControllerForTesting.activeTextPreviewPreparationBodyIDForTesting != firstBodyID
        }
        #expect(didRenderSecondRequest)
        #expect(viewController.syntaxBodyViewControllerForTesting.activeTextPreviewPreparationBodyIDForTesting != firstBodyID)
    }

    @Test
    func compactContainerPushesAndPopsDetailFromSelection() async throws {
        let context = makeContext()
        let request = try #require(applyRequest(to: context, requestID: "1", url: "https://example.com/app.js"))
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = makeNetworkDetailViewController(model: model)
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
        let context = makeContext()
        let request = try #require(
            applyRequest(
                to: context,
                requestID: "1",
                url: "https://example.com/api/data.txt",
                responseHeaders: ["content-type": "text/plain"],
                responseMimeType: "text/plain"
            )
        )
        applyResponseBody(to: context, request: request, body: "visible detail body", base64Encoded: false)
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = makeNetworkDetailViewController(model: model)
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
                && detailViewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text == "visible detail body"
        }
        #expect(didRenderDetail)

        model.selectRequest(nil)
        if navigationController.transitionCoordinator != nil {
            #expect(detailViewController.previewViewForTesting.isHidden == false)
            #expect(detailViewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text == "visible detail body")
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
        let context = makeContext()
        let request = try #require(
            applyRequest(
                to: context,
                requestID: "1",
                url: "https://example.com/api/data.txt",
                responseHeaders: ["content-type": "text/plain"],
                responseMimeType: "text/plain"
            )
        )
        applyResponseBody(to: context, request: request, body: "visible detail body", base64Encoded: false)
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = makeNetworkDetailViewController(model: model)
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
                && detailViewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text == "visible detail body"
        }
        #expect(didRenderDetail)

        _ = navigationController.popViewController(animated: true)
        if navigationController.transitionCoordinator != nil {
            model.selectRequest(nil)
            #expect(detailViewController.previewViewForTesting.isHidden == false)
            #expect(detailViewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text == "visible detail body")
        }

        let didPopAndDiscard = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers == [listViewController]
                && detailViewController.previewViewForTesting.isHidden
        }
        #expect(didPopAndDiscard)
    }

    @Test
    func compactContainerCanPushSameRequestAfterBackNavigation() async throws {
        let context = makeContext()
        _ = try #require(applyRequest(to: context, requestID: "1", url: "https://example.com/app.js"))
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = makeNetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        let window = showInWindow(navigationController, makeVisible: true)
        defer { window.isHidden = true }

        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedRequestIDsForTesting.count == 1)

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
        let context = makeContext()
        let request = try #require(
            applyRequest(
                to: context,
                requestID: "1",
                url: "https://media.example.com/download.php",
                responseHeaders: ["content-type": "video/mp4"],
                responseMimeType: "video/mp4"
            )
        )
        applyResponseBody(to: context, request: request, body: "not a real movie", base64Encoded: false)
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = makeNetworkDetailViewController(model: model)
        detailViewController.setModeForTesting(.preview)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        detailViewController.syntaxBodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
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
            detailViewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting?.pathExtension == "mp4"
        }
        #expect(didRenderMediaPreview)
        let temporaryFileURL = try #require(detailViewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting)
        #expect(playerFactory.requestedURLs == [temporaryFileURL])
        #expect(FileManager.default.fileExists(atPath: temporaryFileURL.path))

        _ = withUIKitAnimationsDisabled {
            navigationController.popViewController(animated: false)
        }

        let didReturnToListAndReleasePreview = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers == [listViewController]
                && model.selectedRequest == nil
                && detailViewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting == nil
                && FileManager.default.fileExists(atPath: temporaryFileURL.path) == false
        }
        #expect(didReturnToListAndReleasePreview)
        #expect(playerFactory.requestedURLs == [temporaryFileURL])
    }

    @Test
    func compactContainerPopsDetailWhenSelectedRequestDisappears() async throws {
        let context = makeContext()
        let request = try #require(applyRequest(to: context, requestID: "1", url: "https://example.com/app.js"))
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = makeNetworkDetailViewController(model: model)
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
            context.clearNetworkRequests()
        }
        #expect(model.selectedRequestID == request.id)
        #expect(model.selectedRequest == nil)

        let didPop = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers == [listViewController]
        }
        #expect(didPop)
    }

    @Test
    func visibleListAppliesLiveInsertThroughFetchedResultsTransactions() async throws {
        let context = makeContext()
        let firstRequest = try #require(applyRequest(
            to: context,
            requestID: "1",
            url: "https://example.com/first.js"
        ))
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }

        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedRequestIDsForTesting == [firstRequest.id])

        let evaluationCountBeforeInsert = listViewController.displayRequestIDsEvaluationCountForTesting
        let snapshotApplyCountBeforeInsert = listViewController.snapshotApplyCountForTesting
        let secondRequest = try #require(applyRequest(
            to: context,
            requestID: "2",
            url: "https://example.com/second.js"
        ))

        let didRenderInsert = await waitUntilListShows(
            [secondRequest.id, firstRequest.id],
            in: listViewController
        )
        #expect(didRenderInsert)
        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeInsert)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyCountBeforeInsert + 1)
    }

    @Test
    func visibleListAppliesDescriptorResetThroughFetchedResultsTransactions() async throws {
        let context = makeContext()
        _ = try #require(applyRequest(
            to: context,
            requestID: "1",
            url: "https://media.example.com/clip.mp4",
            responseHeaders: ["content-type": "video/mp4"],
            responseMimeType: "video/mp4"
        ))
        let model = NetworkPanelModel(context: context)
        model.setResourceFilter(.media, enabled: true)
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }

        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedRequestIDsForTesting.count == 1)

        let evaluationCountBeforeUpdate = listViewController.displayRequestIDsEvaluationCountForTesting
        let snapshotApplyCountBeforeUpdate = listViewController.snapshotApplyCountForTesting

        model.setSearchText("does-not-match")
        let didRenderReset = await waitUntilListShows([], in: listViewController)

        #expect(didRenderReset)
        #expect(model.displayRequestIDs.isEmpty)
        #expect(listViewController.displayedRequestIDsForTesting.isEmpty)
        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeUpdate)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyCountBeforeUpdate + 1)
    }

    @Test
    func hiddenListDefersSnapshotEvaluationUntilAppearingAgain() async throws {
        let context = makeContext()
        _ = try #require(applyRequest(
            to: context,
            requestID: "1",
            url: "https://media.example.com/clip.mp4",
            responseHeaders: ["content-type": "video/mp4"],
            responseMimeType: "video/mp4"
        ))
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController)
        defer { window.isHidden = true }
        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedRequestIDsForTesting.count == 1)

        let evaluationCountBeforeHiddenUpdate = listViewController.displayRequestIDsEvaluationCountForTesting

        listViewController.suspendRenderingForTesting()
        model.setSearchText("does-not-match")
        await settleNetworkListTransactions()

        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate)
        #expect(listViewController.displayedRequestIDsForTesting.count == 1)

        listViewController.resumeRenderingForTesting()
        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedRequestIDsForTesting.isEmpty)
        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate + 1)
    }

    @Test
    func hiddenListDefersQueuedSnapshotApplyUntilAppearingAgain() async throws {
        let context = makeContext()
        let request = try #require(applyRequest(
            to: context,
            requestID: "1",
            url: "https://media.example.com/clip.mp4",
            responseHeaders: ["content-type": "video/mp4"],
            responseMimeType: "video/mp4"
        ))
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController)
        defer { window.isHidden = true }
        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedRequestIDsForTesting == [request.id])

        let evaluationCountBeforeHiddenUpdate = listViewController.displayRequestIDsEvaluationCountForTesting
        listViewController.beginSnapshotApplyForTesting(requestIDs: [request.id])
        listViewController.queueSnapshotUpdateForTesting(requestIDs: [])
        #expect(listViewController.hasPendingSnapshotUpdateForTesting)

        listViewController.suspendRenderingForTesting()
        #expect(listViewController.hasPendingSnapshotUpdateForTesting == false)

        model.setSearchText("does-not-match")
        listViewController.finishSnapshotApplyForTesting(requestIDs: [request.id])
        await listViewController.flushPendingSnapshotUpdateForTesting()

        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate)
        #expect(listViewController.displayedRequestIDsForTesting == [request.id])

        listViewController.resumeRenderingForTesting()
        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedRequestIDsForTesting.isEmpty)
        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate + 1)
    }

    @Test
    func hiddenFilteredListSkipsSnapshotReloadWhenRowsRemainVisible() async throws {
        let context = makeContext()
        let request = try #require(applyRequest(
            to: context,
            requestID: "1",
            url: "https://media.example.com/clip.mp4",
            responseHeaders: ["content-type": "video/mp4"],
            responseMimeType: "video/mp4"
        ))
        let model = NetworkPanelModel(context: context)
        model.setResourceFilter(.media, enabled: true)
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController)
        defer { window.isHidden = true }
        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedRequestIDsForTesting == [request.id])
        listViewController.collectionViewForTesting.layoutIfNeeded()

        let indexPath = IndexPath(item: 0, section: 0)
        let cell = try #require(listViewController.networkListCellForTesting(at: indexPath))
        #expect(cell.fileTypeLabelForTesting == "mp4")

        let evaluationCountBeforeHiddenUpdate = listViewController.displayRequestIDsEvaluationCountForTesting
        let snapshotApplyCountBeforeHiddenUpdate = listViewController.snapshotApplyCountForTesting

        listViewController.beginAppearanceTransition(false, animated: false)
        listViewController.endAppearanceTransition()
        applyResponseReceived(
            to: context,
            requestID: "1",
            url: request.url,
            responseHeaders: ["content-type": "image/png"],
            responseMimeType: "image/png",
            timestamp: 4
        )
        await settleNetworkListTransactions()

        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyCountBeforeHiddenUpdate)
        #expect(listViewController.displayedRequestIDsForTesting == [request.id])
        #expect(cell.fileTypeLabelForTesting == "mp4")

        listViewController.beginAppearanceTransition(true, animated: false)
        listViewController.endAppearanceTransition()

        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyCountBeforeHiddenUpdate)
        #expect(listViewController.displayedRequestIDsForTesting == [request.id])
        #expect(cell.fileTypeLabelForTesting == "png")

        await listViewController.flushPendingSnapshotUpdateForTesting()

        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyCountBeforeHiddenUpdate)
        #expect(listViewController.displayedRequestIDsForTesting == [request.id])
    }

    @Test
    func hiddenListSuspendsBoundCellRenderingUntilAppearingAgain() async throws {
        let context = makeContext()
        let request = try #require(applyRequest(
            to: context,
            requestID: "1",
            url: "https://media.example.com/clip.mp4",
            responseHeaders: ["content-type": "video/mp4"],
            responseMimeType: "video/mp4"
        ))
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController)
        defer { window.isHidden = true }
        await listViewController.flushPendingSnapshotUpdateForTesting()
        listViewController.collectionViewForTesting.layoutIfNeeded()

        let indexPath = IndexPath(item: 0, section: 0)
        let cell = try #require(listViewController.networkListCellForTesting(at: indexPath))
        #expect(cell.fileTypeLabelForTesting == "mp4")
        #expect(cell.hasActiveRequestObservationForTesting)
        let snapshotApplyCountBeforeHiddenContentUpdate = listViewController.snapshotApplyCountForTesting

        listViewController.beginAppearanceTransition(false, animated: false)
        listViewController.endAppearanceTransition()
        #expect(cell.hasActiveRequestObservationForTesting == false)

        applyResponseReceived(
            to: context,
            requestID: "1",
            url: request.url,
            responseHeaders: ["content-type": "text/css"],
            responseMimeType: "text/css",
            timestamp: 4
        )

        #expect(cell.fileTypeLabelForTesting == "mp4")

        listViewController.beginAppearanceTransition(true, animated: false)
        listViewController.endAppearanceTransition()

        #expect(cell.hasActiveRequestObservationForTesting)
        #expect(cell.fileTypeLabelForTesting == "css")
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyCountBeforeHiddenContentUpdate)
    }

    @Test
    func listControllerDeallocatesWhileFetchedResultsTransactionTaskIsActive() async throws {
        let model = NetworkPanelModel(context: makeContext())
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

    private func makeContext() -> WebInspectorContext {
        WebInspectorContext.preview(isolation: MainActor.shared)
    }

    private func applyRequest(
        to context: WebInspectorContext,
        requestID rawRequestID: String,
        url: String,
        requestHeaders: [String: String] = [:],
        postData: String? = nil,
        responseHeaders: [String: String] = ["content-type": "text/javascript"],
        responseMimeType: String = "text/javascript",
        finishes: Bool = true
    ) -> NetworkRequest? {
        let requestID = Network.Request.ID(rawRequestID)
        context.apply(
            .requestWillBeSent(
                id: requestID,
                request: Network.Request(
                    id: requestID,
                    url: url,
                    method: postData == nil ? "GET" : "POST",
                    headers: requestHeaders,
                    postData: postData
                ),
                resourceType: .script,
                redirectResponse: nil,
                timestamp: 1
            )
        )
        context.apply(
            .responseReceived(
                id: requestID,
                response: Network.Response(
                    url: url,
                    status: 200,
                    statusText: "OK",
                    mimeType: responseMimeType,
                    headers: responseHeaders,
                    source: Network.Source(rawValue: "network"),
                    requestHeaders: requestHeaders
                ),
                resourceType: .script,
                timestamp: 2
            )
        )
        if finishes {
            context.apply(
                .loadingFinished(
                    id: requestID,
                    timestamp: 3,
                    sourceMapURL: nil,
                    metrics: nil
                )
            )
        }
        return context.registeredRequest(forProxyID: requestID)
    }

    private func applyRequestWithoutResponse(
        to context: WebInspectorContext,
        requestID rawRequestID: String,
        url: String,
        requestHeaders: [String: String] = [:],
        postData: String? = nil
    ) -> NetworkRequest? {
        let requestID = Network.Request.ID(rawRequestID)
        context.apply(
            .requestWillBeSent(
                id: requestID,
                request: Network.Request(
                    id: requestID,
                    url: url,
                    method: postData == nil ? "GET" : "POST",
                    headers: requestHeaders,
                    postData: postData
                ),
                resourceType: .xhr,
                redirectResponse: nil,
                timestamp: 1
            )
        )
        return context.registeredRequest(forProxyID: requestID)
    }

    private func applyResponseReceived(
        to context: WebInspectorContext,
        requestID rawRequestID: String,
        url: String,
        responseHeaders: [String: String],
        responseMimeType: String,
        timestamp: Double
    ) {
        let requestID = Network.Request.ID(rawRequestID)
        context.apply(
            .responseReceived(
                id: requestID,
                response: Network.Response(
                    url: url,
                    status: 200,
                    statusText: "OK",
                    mimeType: responseMimeType,
                    headers: responseHeaders,
                    source: Network.Source(rawValue: "network")
                ),
                resourceType: .script,
                timestamp: timestamp
            )
        )
    }

    private func applyDataReceived(
        to context: WebInspectorContext,
        requestID rawRequestID: String,
        dataLength: Int,
        encodedDataLength: Int,
        timestamp: Double
    ) {
        context.apply(
            .dataReceived(
                id: Network.Request.ID(rawRequestID),
                dataLength: dataLength,
                encodedDataLength: encodedDataLength,
                timestamp: timestamp
            )
        )
    }

    private func applyLoadingFinished(
        to context: WebInspectorContext,
        requestID rawRequestID: String,
        timestamp: Double
    ) {
        context.apply(
            .loadingFinished(
                id: Network.Request.ID(rawRequestID),
                timestamp: timestamp,
                sourceMapURL: nil,
                metrics: nil
            )
        )
    }

    private func applyResponseBody(
        to context: WebInspectorContext,
        request: NetworkRequest,
        body: String,
        base64Encoded: Bool = false
    ) {
        context.seedResponseBody(for: request.id, body: body, base64Encoded: base64Encoded)
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

    private func waitUntilNetworkBodyPhase(
        timeout: Duration = .seconds(1),
        _ condition: @escaping @MainActor @Sendable () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while condition() == false {
            guard clock.now < deadline else {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func waitUntilListShows(
        _ requestIDs: [NetworkRequest.ID],
        in viewController: NetworkListViewController,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while viewController.displayedRequestIDsForTesting != requestIDs {
            guard clock.now < deadline else {
                return false
            }
            await viewController.flushPendingSnapshotUpdateForTesting()
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func settleNetworkListTransactions() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }

    private func waitUntilMediaPreviewPrepared(
        in viewController: NetworkDetailViewController
    ) async {
        await viewController.syntaxBodyViewControllerForTesting.waitUntilMediaPreviewPreparationFinishedForTesting()
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
            viewController.syntaxBodyViewControllerForTesting.bodyObservationDeliveryForTesting,
            viewController.syntaxBodyViewControllerForTesting.previewRenderObservationDeliveryForTesting,
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
        guard let bundleURL = WebInspectorUILocalization.bundle.url(forResource: locale, withExtension: "lproj"),
              let bundle = Bundle(url: bundleURL) else {
            return nil
        }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
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
}
}

@MainActor
private func makeNetworkDetailViewController(
    model: NetworkPanelModel,
    initialMode: NetworkDetailViewController.Mode = .headers
) -> NetworkDetailViewController {
    NetworkDetailViewController(
        model: model,
        initialMode: initialMode,
        makeBodyViewController: NetworkBodyPreviewFactory.make(scrollEdgeSink:)
    )
}

@MainActor
private extension NetworkDetailViewController {
    var syntaxBodyViewControllerForTesting: NetworkBodyViewController {
        guard let viewController = bodyViewControllerForTesting as? NetworkBodyViewController else {
            preconditionFailure("Expected NetworkDetailViewController to use NetworkBodyViewController in tests.")
        }
        return viewController
    }
}

private final class StubMoviePreviewPlayer: AVPlayer {
    private let pauseCounter = Mutex(0)

    var pauseCallCount: Int {
        pauseCounter.withLock { $0 }
    }

    override func pause() {
        pauseCounter.withLock { $0 += 1 }
    }
}
#endif
