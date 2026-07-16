#if canImport(UIKit)
import AVFoundation
import ObservationBridge
import Synchronization
import Testing
@testable import WebInspectorDataKit
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
    func listUsesFixedMetricFlowLayoutInsteadOfWholeListCompositionalSolving() throws {
        let model = NetworkPanelModel(context: makeContext())
        let viewController = NetworkListViewController(model: model)
        let window = showInWindow(viewController, makeVisible: true)
        defer { window.isHidden = true }

        let layout = try #require(
            viewController.collectionViewForTesting.collectionViewLayout
                as? UICollectionViewFlowLayout
        )

        #expect(layout.scrollDirection == .vertical)
        #expect(layout.estimatedItemSize == .zero)
        #expect(layout.minimumLineSpacing == 0)
        #expect(layout.minimumInteritemSpacing == 0)
        #expect(layout.itemSize.width > 0)
        #expect(layout.itemSize.height >= 44)
    }

    @Test
    func fixedFlowLayoutPreservesInsetGroupedRowContentAccessoriesAndSelection() async throws {
        let context = makeContext()
        _ = context.seedNetworkRequest(
            requestID: "fixed-layout-first",
            url: "https://example.test/first.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 0
        )
        let selectedRequestID = context.seedNetworkRequest(
            requestID: "fixed-layout-selected",
            url: "https://example.test/a-long-network-resource-name-that-can-use-two-lines.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 1
        )
        _ = context.seedNetworkRequest(
            requestID: "fixed-layout-last",
            url: "https://example.test/last.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 2
        )
        let request = try #require(context.registeredRequest(for: selectedRequestID))
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = NetworkListViewController(model: model)
        let window = showInWindow(viewController, makeVisible: true)
        defer { window.isHidden = true }

        await viewController.flushPendingSnapshotUpdateForTesting()
        viewController.view.layoutIfNeeded()
        viewController.collectionViewForTesting.layoutIfNeeded()

        let layout = try #require(
            viewController.collectionViewForTesting.collectionViewLayout
                as? UICollectionViewFlowLayout
        )
        let firstCell = try #require(viewController.networkListCellForTesting(
            at: IndexPath(item: 0, section: 0)
        ))
        let selectedCell = try #require(viewController.networkListCellForTesting(
            at: IndexPath(item: 1, section: 0)
        ))
        let lastCell = try #require(viewController.networkListCellForTesting(
            at: IndexPath(item: 2, section: 0)
        ))
        let expectedWidth = viewController.collectionViewForTesting.bounds.width
            - viewController.collectionViewForTesting.adjustedContentInset.left
            - viewController.collectionViewForTesting.adjustedContentInset.right
            - layout.sectionInset.left
            - layout.sectionInset.right

        #expect(layout.sectionInset.left == NetworkListViewController.horizontalSectionInset)
        #expect(layout.sectionInset.right == NetworkListViewController.horizontalSectionInset)
        #expect(layout.sectionInset.bottom == NetworkListViewController.bottomSectionInset)
        #expect(layout.itemSize.width == expectedWidth)
        #expect(layout.itemSize.height == NetworkListCell.rowHeight(
            compatibleWith: viewController.traitCollection
        ))
        #expect(selectedCell.contentNumberOfLinesForTesting == 2)
        #expect(selectedCell.accessories.count == 3)
        #expect(selectedCell.separatorViewForTesting.superview === selectedCell)
        #expect(firstCell.listPositionForTesting == .first)
        #expect(firstCell.separatorViewForTesting.isHidden == false)
        #expect(firstCell.backgroundCornerRadiusForTesting ?? 0 > 0)
        #expect(firstCell.layer.masksToBounds == false)
        #expect(selectedCell.listPositionForTesting == .middle)
        #expect(selectedCell.separatorViewForTesting.isHidden == false)
        #expect(selectedCell.backgroundCornerRadiusForTesting == 0)
        #expect(selectedCell.layer.masksToBounds == false)
        #expect(lastCell.listPositionForTesting == .last)
        #expect(lastCell.separatorViewForTesting.isHidden)
        #expect(lastCell.backgroundCornerRadiusForTesting ?? 0 > 0)
        #expect(lastCell.layer.masksToBounds == false)
        #expect(
            viewController.collectionViewForTesting.indexPathsForSelectedItems
                == [IndexPath(item: 1, section: 0)]
        )
    }

    @Test
    func fixedFlowLayoutRecomputesRowMetricForContentSizeCategoryChanges() throws {
        let model = NetworkPanelModel(context: makeContext())
        let viewController = NetworkListViewController(model: model)
        let window = showInWindow(viewController, makeVisible: true)
        defer { window.isHidden = true }
        let layout = try #require(
            viewController.collectionViewForTesting.collectionViewLayout
                as? UICollectionViewFlowLayout
        )
        let regularHeight = layout.itemSize.height

        viewController.traitOverrides.preferredContentSizeCategory =
            .accessibilityExtraExtraExtraLarge
        viewController.view.layoutIfNeeded()

        #expect(layout.estimatedItemSize == .zero)
        #expect(layout.itemSize.height > regularHeight)
        #expect(layout.itemSize.height == NetworkListCell.rowHeight(
            compatibleWith: viewController.traitCollection
        ))
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
    func syntaxBodyPreviewAppliesBackgroundPolicyAfterLazyInstall() {
        guard #available(iOS 26.0, *) else {
            return
        }

        let viewController = NetworkBodyViewController()
        viewController.traitOverrides.webInspectorDrawsBackground = false

        viewController.loadViewIfNeeded()
        viewController.setSurface(.unavailableBodyPlaceholder)
        viewController.resumeRendering()

        #expect(viewController.syntaxViewForTesting.backgroundColor == .clear)
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
        _ = try #require(await applyRequest(
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
            await applyRequest(
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

        let didRenderPreview = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .preview
                && viewController.previewViewForTesting.isHidden == false
                && viewController.headersTextViewForTesting.isHidden
                && viewController.isPreviewRoleControlHiddenForTesting == false
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
    func headersRenderRedirectChainBeforeFinalRequestAndResponse() async throws {
        let context = makeContext()
        let requestID = Network.Request.ID("redirect-chain")
        await context.apply(
            .requestWillBeSent(
                id: requestID,
                request: Network.Request(
                    id: requestID,
                    url: "https://example.com/start",
                    method: "POST",
                    headers: ["x-start": "one"]
                ),
                resourceType: .document,
                redirectResponse: nil,
                timestamp: 1
            )
        )
        await context.apply(
            .requestWillBeSent(
                id: requestID,
                request: Network.Request(
                    id: requestID,
                    url: "https://example.com/final",
                    method: "GET",
                    headers: ["x-final-request": "two"]
                ),
                resourceType: .document,
                redirectResponse: Network.Response(
                    url: "https://example.com/start",
                    status: 302,
                    statusText: "Found",
                    headers: ["location": "https://example.com/final"]
                ),
                timestamp: 2
            )
        )
        await context.apply(
            .responseReceived(
                id: requestID,
                response: Network.Response(
                    url: "https://example.com/final",
                    status: 200,
                    statusText: "OK",
                    headers: ["x-final-response": "three"]
                ),
                resourceType: .document,
                timestamp: 3
            )
        )

        let request = try #require(context.registeredRequest(forProxyID: requestID))
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = makeNetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderChain = await waitUntilRendered(in: viewController) {
            let text = viewController.headersTextViewForTesting.renderedTextForTesting
            return text.contains("POST /start")
                && text.contains("302 Found")
                && text.contains("GET /final")
                && text.contains("200 OK")
                && text.contains("x-start: one")
                && text.contains("location: https://example.com/final")
                && text.contains("x-final-request: two")
                && text.contains("x-final-response: three")
        }
        #expect(didRenderChain)

        let text = viewController.headersTextViewForTesting.renderedTextForTesting
        let redirectRequest = try #require(text.range(of: "POST /start"))
        let redirectResponse = try #require(text.range(of: "302 Found"))
        let finalRequest = try #require(text.range(of: "GET /final"))
        let finalResponse = try #require(text.range(
            of: "200 OK",
            range: finalRequest.upperBound..<text.endIndex
        ))
        #expect(redirectRequest.lowerBound < redirectResponse.lowerBound)
        #expect(redirectResponse.lowerBound < finalRequest.lowerBound)
        #expect(finalRequest.lowerBound < finalResponse.lowerBound)
    }

    @Test
    func previewRequestWithoutBodyReplacesPreviousBodyWithUnavailablePlaceholder() async throws {
        let context = makeContext()
        let bodyRequest = try #require(
            await applyRequestWithoutResponse(
                to: context,
                requestID: "body",
                url: "https://example.com/form",
                requestHeaders: ["content-type": "application/x-www-form-urlencoded"],
                postData: "name=Jane+Doe"
            )
        )
        let emptyRequest = try #require(
            await applyRequestWithoutResponse(
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
            await applyRequest(
                to: context,
                requestID: "response-only",
                url: "https://example.com/response.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        let requestAndResponse = try #require(
            await applyRequest(
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
            await applyRequest(
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
            await applyRequest(
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
            await applyRequestWithoutResponse(
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
            await applyRequestWithoutResponse(
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

        await applyResponseReceived(
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
            await applyRequest(
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
        }
        #expect(didRenderBody)
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
            await applyRequest(
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
        model.selectRequest(errorRequest)
        let viewController = makeNetworkDetailViewController(
            model: model,
            initialMode: .preview
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(await waitUntilPreparedTextPreviewRendered(in: viewController) {
            viewController.previewRequestIDForTesting == errorRequest.id
                && viewController.syntaxBodyViewControllerForTesting
                    .syntaxViewForTesting.text.contains(#""error" : "not found""#)
        })
        #expect(model.selectedRequests.map(\.id) == [successfulRequest.id, errorRequest.id])
    }

    @Test
    func hiddenDetailDoesNotFetchResponseBodyUntilAppearingAgain() async throws {
        let context = makeContext()
        let request = try #require(
            await applyRequest(
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
            await applyRequest(
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

        let didRenderVisibleBody = await waitUntilPreparedTextPreviewRendered(in: viewController) {
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

        let didRenderHiddenBody = await waitUntilPreparedTextPreviewRendered(in: viewController) {
            viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text.contains(#""hidden" : true"#)
        }
        #expect(didRenderHiddenBody)
    }

    @Test
    func deeplyNestedJSONPreviewFallsBackToRawText() async throws {
        let context = makeContext()
        let request = try #require(
            await applyRequest(
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
            await applyRequest(
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

        let didRenderPrettyBody = await waitUntilPreparedTextPreviewRendered(in: viewController) {
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
        let viewController = makeNetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.syntaxBodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didShowPlayer = await waitUntilRendered(in: viewController) {
            viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting?.absoluteString
                == playlistURL
        }
        await Task.yield()

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

        for _ in 0..<100 {
            if viewController.hasMoviePreviewFailureForTesting {
                break
            }
            await Task.yield()
        }
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
            let viewController = makeNetworkDetailViewController(
                model: model,
                initialMode: .preview
            )
            var playerCreationCount = 0
            viewController.syntaxBodyViewControllerForTesting
                .setMoviePreviewPlayerFactoryForTesting {
                    playerCreationCount += 1
                    return StubMoviePreviewPlayer()
                }
            let window = showInWindow(viewController)
            defer { window.isHidden = true }

            #expect(await waitUntilRendered(in: viewController) {
                viewController.currentModeForTesting == .preview
                    && viewController.syntaxBodyViewControllerForTesting
                        .syntaxViewForTesting.text.isEmpty == false
                    && viewController.responseBodyFetchObservationDeliveryForTesting == nil
            }, Comment(rawValue: input.name))
            #expect(
                viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting == nil,
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
        let viewController = makeNetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.syntaxBodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didShowPlaylistText = await waitUntilPreparedTextPreviewRendered(in: viewController) {
            viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text == playlist
        }

        #expect(didShowPlaylistText)
        guard case .loaded = request.responseBody.phase else {
            Issue.record("Unsafe HLS should fetch its response body for syntax display")
            return
        }
        #expect(viewController.responseBodyFetchObservationDeliveryForTesting != nil)
        #expect(viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting == nil)
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
        let viewController = makeNetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.syntaxBodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didShowRemoteMovie = await waitUntilRendered(in: viewController) {
            viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting?.absoluteString
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
            let viewController = makeNetworkDetailViewController(model: model)
            let window = showInWindow(viewController)
            defer { window.isHidden = true }
            viewController.setModeForTesting(.preview)

            let didSettleWithoutRemotePlayback = await waitUntilRendered(in: viewController) {
                guard viewController.currentModeForTesting == .preview,
                      viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting == nil,
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
                viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting == nil,
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
        let viewController = NetworkBodyViewController(
            moviePreviewPlayerFactory: playerFactory.makePlayer
        )
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
        let viewController = makeNetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.syntaxBodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer
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
        #expect(playerFactory.players.count == 1)
        #expect(FileManager.default.fileExists(atPath: temporaryFileURL.path))

        viewController.setModeForTesting(.headers)

        let didReleaseMediaPreview = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .headers
                && viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting == nil
                && FileManager.default.fileExists(atPath: temporaryFileURL.path) == false
        }
        #expect(didReleaseMediaPreview)
        #expect(playerFactory.players.count == 1)

        viewController.setModeForTesting(.preview)
        await waitUntilMediaPreviewPrepared(in: viewController)

        let didRestoreMediaPreview = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .preview
                && viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting?.pathExtension == "mp4"
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
        let viewController = makeNetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.syntaxBodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer
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
        #expect(playerFactory.players.count == 1)

        await applyDataReceived(
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
        let viewController = makeNetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.syntaxBodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer
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
        let viewController = makeNetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.syntaxBodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer
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
        #expect(playerFactory.players.count == 1)
        #expect(FileManager.default.fileExists(atPath: temporaryFileURL.path))

        model.selectRequest(nil)

        let didReleaseMediaPreview = await waitUntilRendered(in: viewController) {
            viewController.contentUnavailableConfiguration != nil
                && viewController.previewViewForTesting.isHidden
                && viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting == nil
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
        let viewController = makeNetworkDetailViewController(model: model)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.syntaxBodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer
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
        #expect(playerFactory.players.count == 1)
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
            await applyRequest(
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

        await applyLoadingFinished(to: context, requestID: "1", timestamp: 3)

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
            await applyRequest(
                to: context,
                requestID: "1",
                url: "https://example.com/api/data.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        let model = NetworkPanelModel(context: context)
        model.fetchResponseBodyIfNeeded(for: request)
        let didFailInitialFetch = await waitForNetworkBodyPhase(in: request.responseBody) { phase in
            if case .failed = phase {
                return true
            }
            return false
        } != nil
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
            await applyRequest(
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
            await applyRequest(
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

        await applyDataReceived(
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
            await applyRequest(
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
        await applyResponseReceived(
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
            await applyRequest(
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
        let bodyPreview = RecordingNetworkBodyPreviewViewController()
        let viewController = makeNetworkDetailViewController(
            model: model,
            makeBodyViewController: { _ in bodyPreview }
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didRenderPreview = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .preview
                && viewController.isPreviewRoleControlHiddenForTesting == false
        }
        #expect(didRenderPreview)

        viewController.selectPreviewRoleForTesting(.request)

        let requestBody = try #require(request.requestBody)
        let didRenderRequestBody = await waitUntilRendered(in: viewController) {
            viewController.currentPreviewRoleForTesting == .request
                && bodyPreview.currentBodyForTesting === requestBody
                && viewController.responseBodyFetchObservationDeliveryForTesting == nil
        }
        #expect(didRenderRequestBody)

        await applyLoadingFinished(to: context, requestID: "1", timestamp: 3)

        let didStayOnRequestBody = await waitUntilRendered(in: viewController) {
            viewController.currentPreviewRoleForTesting == .request
                && bodyPreview.currentBodyForTesting === requestBody
                && viewController.responseBodyFetchObservationDeliveryForTesting == nil
        }
        #expect(didStayOnRequestBody)
        #expect(request.responseBody.phase == .available)
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

        await applyResponseReceived(
            to: context,
            requestID: "1",
            url: "https://example.com/first.json",
            responseHeaders: ["x-old-request": "stale"],
            responseMimeType: "application/json",
            timestamp: 4
        )

        #expect(viewController.headersTextViewForTesting.renderedTextForTesting.contains("x-old-request: stale") == false)

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
    }

    @Test
    func textPreviewCoordinatorIgnoresCancelledPreparationResult() async throws {
        let firstBody = NetworkBody(
            role: .response,
            kind: .text,
            full: #"{"first":true}"#,
            sourceSyntaxKind: .json,
            phase: .loaded
        )
        let secondBody = NetworkBody(
            role: .response,
            kind: .text,
            full: #"{"second":true}"#,
            sourceSyntaxKind: .json,
            phase: .loaded
        )
        let coordinator = NetworkTextPreviewCoordinator()
        var resultActions: [NetworkTextPreviewResultAction] = []

        await coordinator.suspendNextPreparationForTesting()
        let firstAction = coordinator.preparePreview(for: firstBody) { action in
            resultActions.append(action)
        }
        let firstBodyID = ObjectIdentifier(firstBody)
        guard case .active = firstAction else {
            Issue.record("Expected the first JSON body to start asynchronous preparation")
            return
        }
        #expect(coordinator.activePreparationBodyIDForTesting == firstBodyID)
        await coordinator.waitForPreparationSuspensionForTesting()

        let secondAction = coordinator.preparePreview(for: secondBody) { action in
            resultActions.append(action)
        }
        guard case .active = secondAction else {
            Issue.record("Expected the second JSON body to replace the first asynchronous preparation")
            return
        }
        #expect(coordinator.activePreparationBodyIDForTesting == ObjectIdentifier(secondBody))

        await coordinator.resumeSuspendedPreparationForTesting()
        await coordinator.waitUntilPreparationFinishedForTesting()

        let resultAction = try #require(resultActions.first)
        guard case .show(let text, let syntaxKind) = resultAction else {
            Issue.record("Expected the current preparation to publish rendered text")
            return
        }
        #expect(resultActions.count == 1)
        #expect(text.contains(#""second" : true"#))
        #expect(text.contains("first") == false)
        #expect(syntaxKind == .json)
        #expect(coordinator.activePreparationBodyIDForTesting == nil)
    }

    @Test
    func compactContainerPushesAndPopsDetailFromSelection() async throws {
        let context = makeContext()
        let request = try #require(await applyRequest(to: context, requestID: "1", url: "https://example.com/app.js"))
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
    func compactContainerCanPushSameRequestAfterBackNavigation() async throws {
        let context = makeContext()
        _ = try #require(await applyRequest(to: context, requestID: "1", url: "https://example.com/app.js"))
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

        let poppedViewController = withUIKitAnimationsDisabled {
            navigationController.popDetailFromUserNavigationForTesting()
        }
        #expect(poppedViewController === detailViewController)
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
    func compactContainerDoesNotReplayDeferredDetailAfterUserPop() async throws {
        let context = makeContext()
        let request = try #require(
            await applyRequest(to: context, requestID: "1", url: "https://example.com/app.js")
        )
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = makeNetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        model.selectRequest(request)
        navigationController.syncStackForTesting()
        #expect(navigationController.viewControllers == [listViewController, detailViewController])

        let poppedViewController = navigationController.popDetailFromUserNavigationForTesting {
            navigationController.syncStackForTesting()
        }

        #expect(poppedViewController === detailViewController)
        #expect(model.selectedRequest == nil)
        #expect(navigationController.viewControllers == [listViewController])
    }

    @Test
    func compactContainerDoesNotRepushDetailWhenUserPopOvertakesPushCompletion() async throws {
        let context = makeContext()
        let request = try #require(
            await applyRequest(to: context, requestID: "1", url: "https://example.com/app.js")
        )
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = makeNetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        model.selectRequest(request)
        navigationController.syncStackForTesting()
        #expect(navigationController.viewControllers == [listViewController, detailViewController])

        let poppedViewController =
            navigationController.popDetailWhilePushTransitionIsStillTrackedForTesting()
        navigationController.syncStackForTesting()

        #expect(poppedViewController === detailViewController)
        #expect(model.selectedRequest == nil)
        #expect(navigationController.viewControllers == [listViewController])
    }

    @Test
    func compactContainerKeepsDetailAfterCancelledUserPop() async throws {
        let context = makeContext()
        let request = try #require(
            await applyRequest(to: context, requestID: "1", url: "https://example.com/app.js")
        )
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = makeNetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        model.selectRequest(request)
        navigationController.syncStackForTesting()

        navigationController.cancelDetailPopFromUserNavigationForTesting {
            navigationController.syncStackForTesting()
        }

        #expect(model.selectedRequest === request)
        #expect(navigationController.viewControllers == [listViewController, detailViewController])
    }

    @Test
    func compactContainerConvergesToReplacementSelectionAfterUserPop() async throws {
        let context = makeContext()
        let firstRequest = try #require(
            await applyRequest(to: context, requestID: "1", url: "https://example.com/first.js")
        )
        let secondRequest = try #require(
            await applyRequest(to: context, requestID: "2", url: "https://example.com/second.js")
        )
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = makeNetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        model.selectRequest(firstRequest)
        navigationController.syncStackForTesting()

        let poppedViewController = navigationController.popDetailFromUserNavigationForTesting {
            model.selectRequest(secondRequest)
            navigationController.syncStackForTesting()
        }

        #expect(poppedViewController === detailViewController)
        #expect(model.selectedRequest === secondRequest)
        #expect(navigationController.viewControllers == [listViewController, detailViewController])
    }

    @Test
    func compactContainerReleasesDetailMediaPreviewResourcesWhenDetailIsRemoved() async throws {
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
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = makeNetworkDetailViewController(model: model)
        detailViewController.setModeForTesting(.preview)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        detailViewController.syntaxBodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer
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
        #expect(playerFactory.players.count == 1)
        #expect(FileManager.default.fileExists(atPath: temporaryFileURL.path))

        model.selectRequest(nil)

        let didReturnToListAndReleasePreview = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers == [listViewController]
                && model.selectedRequest == nil
                && detailViewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting == nil
                && FileManager.default.fileExists(atPath: temporaryFileURL.path) == false
        }
        #expect(didReturnToListAndReleasePreview)
        #expect(playerFactory.players.count == 1)
    }

    @Test
    func compactContainerPopsDetailWhenSelectedRequestDisappears() async throws {
        let context = makeContext()
        let request = try #require(await applyRequest(to: context, requestID: "1", url: "https://example.com/app.js"))
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
        let rawTransactionBaseline = model.rawTransactionDeliveryCountForTesting

        withUIKitAnimationsDisabled {
            context.clearNetworkRequests()
        }
        #expect(await model.waitForRawTransactionDeliveryForTesting(after: rawTransactionBaseline))
        #expect(model.selectedRequestID == nil)

        let didPop = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers == [listViewController]
        }
        #expect(didPop)
    }

    @Test
    func visibleListAppliesLiveInsertThroughFetchedResultsTransactions() async throws {
        let context = makeContext()
        let firstRequest = try #require(await applyRequest(
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
        let transactionDeliveryCountBeforeInsert = listViewController.fetchedResultsTransactionDeliveryCountForTesting
        let secondRequest = try #require(await applyRequest(
            to: context,
            requestID: "2",
            url: "https://example.com/second.js"
        ))

        let didRenderInsert = await waitUntilListShows(
            [secondRequest.id, firstRequest.id],
            in: listViewController,
            afterTransactionDeliveryCount: transactionDeliveryCountBeforeInsert
        )
        #expect(didRenderInsert)
        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeInsert + 1)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyCountBeforeInsert + 1)
    }

    @Test
    func visibleListCoalescesContinuousTopologyTransactionsAtDisplayUpdateBoundary() async throws {
        let context = makeContext()
        let selectedRequestID = context.seedNetworkRequest(
            requestID: "selected-request",
            url: "https://example.test/selected.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: -1
        )
        let model = NetworkPanelModel(context: context)
        let selectedRequest = try #require(context.registeredRequest(for: selectedRequestID))
        model.selectRequest(selectedRequest)
        let frameScheduler = ManualNetworkListFrameScheduler()
        let snapshotBuilder = BarrierNetworkListSnapshotBuilderFactory()
        let listViewController = NetworkListViewController(
            model: model,
            listFrameScheduler: frameScheduler,
            listSnapshotBuilderFactory: snapshotBuilder
        )
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }

        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(1)
        await snapshotBuilder.releaseBuild(1)
        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedRequestIDsForTesting == [selectedRequest.id])
        let snapshotApplyBaseline = listViewController.snapshotApplyCountForTesting
        let projectionFlushBaseline = listViewController.listProjectionFlushCountForTesting
        let targetCaptureBaseline = listViewController.displayRequestIDsEvaluationCountForTesting
        let scheduledFrameBaseline = frameScheduler.scheduledFrameCount
        let insertedRequestCount = 2_305
        let frameRequestDeliveryBaseline = listViewController.fetchedResultsTransactionDeliveryCountForTesting
        let rawTransactionBaseline = model.rawTransactionDeliveryCountForTesting
        for index in 0..<insertedRequestCount {
            context.seedNetworkRequest(
                requestID: "request-\(index)",
                url: "https://example.test/\(index).json",
                resourceTypeRawValue: "Fetch",
                responseMIMEType: "application/json",
                responseStatus: 200,
                responseStatusText: "OK",
                timestamp: Double(index)
            )
        }

        #expect(await model.waitForRawTransactionDeliveryForTesting(
            after: rawTransactionBaseline + insertedRequestCount - 1,
            timeout: .seconds(10)
        ))
        #expect(await listViewController.waitForFetchedResultsTransactionDeliveryForTesting(
            after: frameRequestDeliveryBaseline
        ))
        #expect(frameScheduler.scheduledFrameCount == scheduledFrameBaseline + 1)
        #expect(frameScheduler.hasScheduledFrame)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyBaseline)

        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(2)
        let buildStatistics = await snapshotBuilder.statistics()
        #expect(buildStatistics.startedBuildCount == 2)
        #expect(buildStatistics.maximumActiveBuildCount == 1)
        await snapshotBuilder.releaseBuild(2)
        await listViewController.waitForListSnapshotBuildIdleForTesting()

        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyBaseline)
        #expect(frameScheduler.scheduledFrameCount == scheduledFrameBaseline + 2)
        #expect(frameScheduler.hasScheduledFrame)

        frameScheduler.fireScheduledFrame()
        await listViewController.waitForSnapshotPipelineQuiescenceForTesting()

        let finalEntryIDs = model.displayEntryIDs
        #expect(listViewController.displayedEntryIDsForTesting == finalEntryIDs)
        #expect(finalEntryIDs.count == insertedRequestCount + 1)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyBaseline + 1)
        #expect(listViewController.listProjectionFlushCountForTesting == projectionFlushBaseline + 1)
        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == targetCaptureBaseline + 1)
        #expect(model.selectedRequest === selectedRequest)
        let selectedEntryID = try #require(model.selectedEntryID)
        #expect(
            listViewController.collectionViewForTesting.indexPathsForSelectedItems
                == [IndexPath(
                    item: try #require(finalEntryIDs.firstIndex(of: selectedEntryID)),
                    section: 0
                )]
        )
    }

    @Test
    func completedListSnapshotBuildWaitsForDisplayFrameBeforeApplying() async throws {
        let context = makeContext()
        let requestID = context.seedNetworkRequest(
            requestID: "frame-admission",
            url: "https://example.test/frame-admission.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 0
        )
        let model = NetworkPanelModel(context: context)
        let request = try #require(context.registeredRequest(for: requestID))
        let frameScheduler = ManualNetworkListFrameScheduler()
        let snapshotBuilder = BarrierNetworkListSnapshotBuilderFactory()
        let listViewController = NetworkListViewController(
            model: model,
            listFrameScheduler: frameScheduler,
            listSnapshotBuilderFactory: snapshotBuilder
        )
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }

        #expect(listViewController.snapshotApplyCountForTesting == 0)
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(1)
        await snapshotBuilder.releaseBuild(1)
        await listViewController.waitForListSnapshotBuildIdleForTesting()

        try #require(listViewController.snapshotApplyCountForTesting == 0)
        try #require(frameScheduler.hasScheduledFrame)

        frameScheduler.fireScheduledFrame()
        await listViewController.waitForSnapshotPipelineQuiescenceForTesting()

        #expect(listViewController.snapshotApplyCountForTesting == 1)
        #expect(listViewController.displayedRequestIDsForTesting == [request.id])
    }

    @Test
    func concreteListSnapshotBuilderFactoryMakesDedicatedActors() async throws {
        let context = makeContext()
        context.seedNetworkRequest(
            requestID: "actor-builder",
            url: "https://example.test/actor-builder.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 0
        )
        let model = NetworkPanelModel(context: context)
        let target = NetworkPanelListProjection(
            version: NetworkPanelListVersion(revision: 41, entryIdentityGeneration: 0),
            entryIDs: model.displayEntryIDs
        )
        let input = makeNetworkListSnapshotBuildInput(target: target)
        let builderFactory = NetworkListSnapshotBuilderFactory()
        let builder = builderFactory.makeBuilder()
        let nextBuilder = builderFactory.makeBuilder()

        let artifact = try await builder.build(input)

        #expect(ObjectIdentifier(builder) != ObjectIdentifier(nextBuilder))
        #expect(artifact.input == input)
        #expect(artifact.snapshot.sectionIdentifiers == [.main])
        #expect(artifact.snapshot.itemIdentifiers == input.target.entryIDs)
        #expect(artifact.changeCounts.inserted == 1)
    }

    @Test
    func concreteListSnapshotBuilderRetainsEveryEntryAcrossCooperativeBatches() async throws {
        let context = makeContext()
        let entryCount = 769
        for index in 0..<entryCount {
            context.seedNetworkRequest(
                requestID: "cooperative-builder-\(index)",
                url: "https://example.test/cooperative-builder-\(index).json",
                resourceTypeRawValue: "Fetch",
                responseMIMEType: "application/json",
                responseStatus: 200,
                responseStatusText: "OK",
                timestamp: Double(index)
            )
        }
        let target = NetworkPanelListProjection(
            version: NetworkPanelListVersion(revision: 42, entryIdentityGeneration: 0),
            entryIDs: NetworkPanelModel(context: context).displayEntryIDs
        )
        let input = makeNetworkListSnapshotBuildInput(target: target)
        let builder = NetworkListSnapshotBuilderFactory().makeBuilder()

        let artifact = try await builder.build(input)

        #expect(input.target.entryIDs.count == entryCount)
        #expect(artifact.input == input)
        #expect(artifact.snapshot.itemIdentifiers == input.target.entryIDs)
        #expect(artifact.changeCounts.inserted == entryCount)
    }

    @Test
    func listInvalidationAccumulatorCoalescesBurstAndRetainsEntryIdentityGeneration() async {
        let accumulator = NetworkListInvalidationAccumulator()

        for revision in 1...2_305 {
            await accumulator.receiveForTesting(NetworkPanelListInvalidation(
                version: NetworkPanelListVersion(
                    revision: UInt64(revision),
                    entryIdentityGeneration: revision >= 1_024 ? 1 : 0
                )
            ))
        }

        var state = await accumulator.stateForTesting
        #expect(state.latestVersion == NetworkPanelListVersion(
            revision: 2_305,
            entryIdentityGeneration: 1
        ))
        #expect(state.frameRequestPublicationCount == 1)
        #expect(state.frameRequestOutstanding)

        await accumulator.didCapture(NetworkPanelListVersion(
            revision: 2_305,
            entryIdentityGeneration: 1
        ))
        state = await accumulator.stateForTesting
        #expect(state.frameRequestPublicationCount == 1)
        #expect(state.frameRequestOutstanding == false)
    }

    @Test
    func displayCriteriaChangesDoNotAdvanceEntryIdentityGeneration() async throws {
        let context = makeContext()
        for name in ["alpha", "beta"] {
            context.seedNetworkRequest(
                requestID: "criteria-\(name)",
                url: "https://example.test/criteria-\(name).json",
                resourceTypeRawValue: "Fetch",
                responseMIMEType: "application/json",
                responseStatus: 200,
                responseStatusText: "OK",
                timestamp: 0
            )
        }
        let model = NetworkPanelModel(context: context)
        let baselineProjection = model.captureListProjection()
        let baseline = makeNetworkListSnapshotBaseline(
            entryIDs: baselineProjection.entryIDs,
            version: baselineProjection.version,
            generation: 5
        )

        model.setSearchText("alpha")
        let filteredProjection = model.captureListProjection()
        let artifact = try await NetworkListSnapshotBuilder().build(
            makeNetworkListSnapshotBuildInput(
                baseline: baseline,
                target: filteredProjection
            )
        )

        #expect(filteredProjection.entryIDs.count == 1)
        #expect(
            filteredProjection.version.entryIdentityGeneration
                == baselineProjection.version.entryIdentityGeneration
        )
        #expect(artifact.changeCounts.reconfigured == 0)
        #expect(artifact.snapshot.reconfiguredItemIdentifiers.isEmpty)

        model.setSearchText("no-match")
        let emptyProjection = model.captureListProjection()
        #expect(emptyProjection.entryIDs.isEmpty)
        #expect(emptyProjection.version.revision > filteredProjection.version.revision)
        #expect(
            emptyProjection.version.entryIdentityGeneration
                == baselineProjection.version.entryIdentityGeneration
        )
    }

    @Test
    func concreteListSnapshotBuilderReconfiguresStableRowsAfterReset() async throws {
        let context = makeContext()
        for index in 0..<3 {
            context.seedNetworkRequest(
                requestID: "reset-rebind-\(index)",
                url: "https://example.test/reset-rebind-\(index).json",
                resourceTypeRawValue: "Fetch",
                responseMIMEType: "application/json",
                responseStatus: 200,
                responseStatusText: "OK",
                timestamp: Double(index)
            )
        }
        let entryIDs = NetworkPanelModel(context: context).displayEntryIDs
        let baseline = makeNetworkListSnapshotBaseline(
            entryIDs: entryIDs,
            version: NetworkPanelListVersion(revision: 7, entryIdentityGeneration: 0),
            generation: 3
        )
        let input = makeNetworkListSnapshotBuildInput(
            baseline: baseline,
            target: NetworkPanelListProjection(
                version: NetworkPanelListVersion(revision: 8, entryIdentityGeneration: 1),
                entryIDs: entryIDs
            )
        )

        let artifact = try await NetworkListSnapshotBuilder().build(input)

        #expect(artifact.snapshot.itemIdentifiers == entryIDs)
        #expect(Set(artifact.snapshot.reconfiguredItemIdentifiers) == Set(entryIDs))
        #expect(artifact.cleanSnapshot.reconfiguredItemIdentifiers.isEmpty)
        #expect(artifact.changeCounts == NetworkListSnapshotChangeCounts(
            inserted: 0,
            deleted: 0,
            moved: 0,
            reconfigured: entryIDs.count
        ))
    }

    @Test
    func visibleStableRowRebindsToRebuiltEntryAfterModelReset() async throws {
        let context = makeContext()
        let request = try #require(await applyRequest(
            to: context,
            requestID: "stable-reset-rebind",
            url: "https://example.test/stable-reset-rebind.json"
        ))
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }
        await listViewController.flushPendingSnapshotUpdateForTesting()
        listViewController.collectionViewForTesting.layoutIfNeeded()

        let entryID = try #require(model.entryID(containing: request.id))
        let originalEntry = try #require(model.entry(for: entryID))
        let indexPath = try #require(listViewController.collectionViewForTesting.indexPathsForVisibleItems.first)
        let cell = try #require(listViewController.networkListCellForTesting(at: indexPath))
        #expect(cell.observedEntryForTesting === originalEntry)
        let frameRequestBaseline = listViewController.fetchedResultsTransactionDeliveryCountForTesting

        model.rebuildEntriesForTesting()
        #expect(await listViewController.waitForFetchedResultsTransactionDeliveryForTesting(
            after: frameRequestBaseline
        ))
        await listViewController.flushPendingSnapshotUpdateForTesting()
        listViewController.collectionViewForTesting.layoutIfNeeded()

        let rebuiltEntry = try #require(model.entry(for: entryID))
        #expect(rebuiltEntry !== originalEntry)
        #expect(cell.observedEntryForTesting === rebuiltEntry)
    }

    @Test
    func concreteListSnapshotBuilderAppliesExactTenThousandRowDelta() async throws {
        let context = makeContext()
        let entryCount = 10_000
        for index in 0..<entryCount {
            context.seedNetworkRequest(
                requestID: "ten-thousand-\(index)",
                url: "https://example.test/ten-thousand-\(index).json",
                resourceTypeRawValue: "Fetch",
                responseMIMEType: "application/json",
                responseStatus: 200,
                responseStatusText: "OK",
                timestamp: Double(index)
            )
        }
        let allEntryIDs = NetworkPanelModel(context: context).displayEntryIDs
        let baselineEntryIDs = Array(allEntryIDs.prefix(entryCount - 10))
        let deletedEntryIDs = Set(allEntryIDs[200..<210])
        let rotatedEntryIDs = Array(allEntryIDs[100..<5_000])
            + Array(allEntryIDs[0..<100])
            + Array(allEntryIDs[5_000..<entryCount])
        let targetEntryIDs = rotatedEntryIDs.filter { deletedEntryIDs.contains($0) == false }
        let baseline = makeNetworkListSnapshotBaseline(
            entryIDs: baselineEntryIDs,
            version: NetworkPanelListVersion(revision: 11, entryIdentityGeneration: 0),
            generation: 4
        )
        let input = makeNetworkListSnapshotBuildInput(
            baseline: baseline,
            target: NetworkPanelListProjection(
                version: NetworkPanelListVersion(revision: 12, entryIdentityGeneration: 0),
                entryIDs: targetEntryIDs
            )
        )

        let artifact = try await NetworkListSnapshotBuilder().build(input)

        #expect(artifact.snapshot.itemIdentifiers == targetEntryIDs)
        #expect(artifact.cleanSnapshot.itemIdentifiers == targetEntryIDs)
        #expect(artifact.changeCounts.inserted == 10)
        #expect(artifact.changeCounts.deleted == 10)
        #expect(artifact.changeCounts.moved > 0)
        #expect(artifact.changeCounts.reconfigured == 0)
    }

    @Test
    func concreteListSnapshotBuilderObservesCancellationBeforeConstruction() async throws {
        let context = makeContext()
        for index in 0..<769 {
            context.seedNetworkRequest(
                requestID: "cancel-builder-\(index)",
                url: "https://example.test/cancel-builder-\(index).json",
                resourceTypeRawValue: "Fetch",
                responseMIMEType: "application/json",
                responseStatus: 200,
                responseStatusText: "OK",
                timestamp: Double(index)
            )
        }
        let target = NetworkPanelListProjection(
            version: NetworkPanelListVersion(revision: 13, entryIdentityGeneration: 0),
            entryIDs: NetworkPanelModel(context: context).displayEntryIDs
        )
        let input = makeNetworkListSnapshotBuildInput(target: target)
        let gate = NetworkListBuilderStartGate()
        let builder = NetworkListSnapshotBuilder()
        let task = Task {
            await gate.waitForRelease()
            return try await builder.build(input)
        }

        await gate.waitUntilWaiting()
        task.cancel()
        await gate.release()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test
    func staleReadySnapshotNeverAppliesAfterNewerTransactionArrives() async throws {
        let context = makeContext()
        let initialRequestID = context.seedNetworkRequest(
            requestID: "applying-a",
            url: "https://example.test/applying-a.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 0
        )
        let model = NetworkPanelModel(context: context)
        _ = try #require(context.registeredRequest(for: initialRequestID))
        let frameScheduler = ManualNetworkListFrameScheduler()
        let snapshotBuilder = BarrierNetworkListSnapshotBuilderFactory()
        let applyCompletionScheduler = ManualNetworkListSnapshotApplyCompletionScheduler()
        let listViewController = NetworkListViewController(
            model: model,
            listFrameScheduler: frameScheduler,
            listSnapshotBuilderFactory: snapshotBuilder,
            snapshotApplyCompletionScheduler: applyCompletionScheduler
        )
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }

        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(1)
        await snapshotBuilder.releaseBuild(1)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await applyCompletionScheduler.waitUntilScheduledCompletionCount(1)
        #expect(listViewController.snapshotApplyCountForTesting == 1)

        var transactionDeliveryBaseline = listViewController.fetchedResultsTransactionDeliveryCountForTesting
        context.seedNetworkRequest(
            requestID: "ready-b",
            url: "https://example.test/ready-b.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 1
        )
        #expect(await listViewController.waitForFetchedResultsTransactionDeliveryForTesting(
            after: transactionDeliveryBaseline
        ))
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(2)
        await snapshotBuilder.releaseBuild(2)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        #expect(listViewController.hasPendingSnapshotUpdateForTesting)
        #expect(listViewController.snapshotApplyCountForTesting == 1)
        try #require(frameScheduler.hasScheduledFrame)

        transactionDeliveryBaseline = listViewController.fetchedResultsTransactionDeliveryCountForTesting
        context.seedNetworkRequest(
            requestID: "latest-c",
            url: "https://example.test/latest-c.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 2
        )
        #expect(await listViewController.waitForFetchedResultsTransactionDeliveryForTesting(
            after: transactionDeliveryBaseline
        ))

        applyCompletionScheduler.runNextCompletion()
        #expect(listViewController.snapshotApplyCountForTesting == 1)
        #expect(frameScheduler.hasScheduledFrame)

        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(3)
        #expect(listViewController.hasPendingSnapshotUpdateForTesting == false)
        #expect(listViewController.snapshotApplyCountForTesting == 1)

        await snapshotBuilder.releaseBuild(3)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        #expect(listViewController.snapshotApplyCountForTesting == 1)
        try #require(frameScheduler.hasScheduledFrame)

        frameScheduler.fireScheduledFrame()
        await applyCompletionScheduler.waitUntilScheduledCompletionCount(2)

        #expect(listViewController.snapshotApplyCountForTesting == 2)
        #expect(listViewController.displayedEntryIDsForTesting == model.displayEntryIDs)

        applyCompletionScheduler.runNextCompletion()
        await listViewController.waitForSnapshotPipelineQuiescenceForTesting()

        #expect(listViewController.displayedEntryIDsForTesting == model.displayEntryIDs)
        #expect(listViewController.snapshotApplyCountForTesting == 2)
        #expect(applyCompletionScheduler.pendingCompletionCount == 0)
    }

    @Test
    func listSnapshotBuildSerializesRunningWorkAndKeepsLatestReplacement() async throws {
        let context = makeContext()
        let selectedRequestID = context.seedNetworkRequest(
            requestID: "selected-request",
            url: "https://example.test/selected.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 0
        )
        let model = NetworkPanelModel(context: context)
        let selectedRequest = try #require(context.registeredRequest(for: selectedRequestID))
        model.selectRequest(selectedRequest)
        let frameScheduler = ManualNetworkListFrameScheduler()
        let snapshotBuilder = BarrierNetworkListSnapshotBuilderFactory()
        let listViewController = NetworkListViewController(
            model: model,
            listFrameScheduler: frameScheduler,
            listSnapshotBuilderFactory: snapshotBuilder
        )
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }

        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(1)
        await snapshotBuilder.releaseBuild(1)
        await listViewController.waitForSnapshotPipelineQuiescenceForTesting()
        #expect(listViewController.displayedRequestIDsForTesting == [selectedRequest.id])
        let snapshotApplyBaseline = listViewController.snapshotApplyCountForTesting
        let projectionFlushBaseline = listViewController.listProjectionFlushCountForTesting
        let scheduledFrameBaseline = frameScheduler.scheduledFrameCount

        var transactionDeliveryBaseline = listViewController.fetchedResultsTransactionDeliveryCountForTesting
        context.seedNetworkRequest(
            requestID: "first-replacement",
            url: "https://example.test/first.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 1
        )
        #expect(await listViewController.waitForFetchedResultsTransactionDeliveryForTesting(
            after: transactionDeliveryBaseline
        ))
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(2)

        transactionDeliveryBaseline = listViewController.fetchedResultsTransactionDeliveryCountForTesting
        context.seedNetworkRequest(
            requestID: "superseded-replacement",
            url: "https://example.test/superseded.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 2
        )
        #expect(await listViewController.waitForFetchedResultsTransactionDeliveryForTesting(
            after: transactionDeliveryBaseline
        ))
        frameScheduler.fireScheduledFrame()

        transactionDeliveryBaseline = listViewController.fetchedResultsTransactionDeliveryCountForTesting
        context.seedNetworkRequest(
            requestID: "latest-replacement",
            url: "https://example.test/latest.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 3
        )
        #expect(await listViewController.waitForFetchedResultsTransactionDeliveryForTesting(
            after: transactionDeliveryBaseline
        ))
        frameScheduler.fireScheduledFrame()

        var buildStatistics = await snapshotBuilder.statistics()
        #expect(buildStatistics.startedBuildCount == 2)
        #expect(buildStatistics.activeBuildCount == 1)
        #expect(buildStatistics.maximumActiveBuildCount == 1)

        await snapshotBuilder.releaseBuild(2)
        await snapshotBuilder.waitUntilStartedBuildCount(3)
        buildStatistics = await snapshotBuilder.statistics()
        #expect(buildStatistics.startedBuildCount == 3)
        #expect(buildStatistics.activeBuildCount == 1)
        #expect(buildStatistics.maximumActiveBuildCount == 1)

        await snapshotBuilder.releaseBuild(3)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        #expect(frameScheduler.scheduledFrameCount == scheduledFrameBaseline + 4)
        #expect(frameScheduler.hasScheduledFrame)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyBaseline)

        frameScheduler.fireScheduledFrame()
        await listViewController.waitForSnapshotPipelineQuiescenceForTesting()

        let finalEntryIDs = model.displayEntryIDs
        #expect(listViewController.displayedEntryIDsForTesting == finalEntryIDs)
        #expect(finalEntryIDs.count == 4)
        #expect(listViewController.listProjectionFlushCountForTesting == projectionFlushBaseline + 3)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyBaseline + 1)
        #expect(model.selectedRequest === selectedRequest)
        let selectedEntryID = try #require(model.selectedEntryID)
        #expect(
            listViewController.collectionViewForTesting.indexPathsForSelectedItems
                == [IndexPath(
                    item: try #require(finalEntryIDs.firstIndex(of: selectedEntryID)),
                    section: 0
                )]
        )
    }

    @Test
    func visibleListContentUpdateSkipsSnapshotAndRendersObservedCell() async throws {
        let context = makeContext()
        let request = try #require(await applyRequestWithoutResponse(
            to: context,
            requestID: "content-update",
            url: "https://example.test/content-update"
        ))
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }

        await listViewController.flushPendingSnapshotUpdateForTesting()
        listViewController.collectionViewForTesting.layoutIfNeeded()
        let cell = try #require(listViewController.networkListCellForTesting(
            at: IndexPath(item: 0, section: 0)
        ))
        let entryObservation = try #require(cell.entryObservationForTesting)
        let renderedFileType = await entryObservation.values {
            cell.fileTypeLabelForTesting
        }
        defer { renderedFileType.cancel() }
        let snapshotApplyBaseline = listViewController.snapshotApplyCountForTesting
        let transactionDeliveryBaseline = listViewController.fetchedResultsTransactionDeliveryCountForTesting

        await applyResponseReceived(
            to: context,
            requestID: "content-update",
            url: request.url,
            responseHeaders: ["content-type": "text/css"],
            responseMimeType: "text/css",
            timestamp: 4
        )

        #expect(await renderedFileType.waitUntilValue("css"))
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyBaseline)
        #expect(
            listViewController.fetchedResultsTransactionDeliveryCountForTesting
                == transactionDeliveryBaseline
        )
        #expect(listViewController.displayedRequestIDsForTesting == [request.id])
    }

    @Test
    func visibleListAppliesDescriptorResetThroughFetchedResultsTransactions() async throws {
        let context = makeContext()
        _ = try #require(await applyRequest(
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
        let transactionDeliveryCountBeforeUpdate = listViewController.fetchedResultsTransactionDeliveryCountForTesting

        model.setSearchText("does-not-match")
        let didRenderReset = await waitUntilListShows(
            [],
            in: listViewController,
            afterTransactionDeliveryCount: transactionDeliveryCountBeforeUpdate
        )

        #expect(didRenderReset)
        #expect(model.displayRequestIDs.isEmpty)
        #expect(listViewController.displayedRequestIDsForTesting.isEmpty)
        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeUpdate + 1)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyCountBeforeUpdate + 1)
    }

    @Test
    func hiddenListDefersSnapshotEvaluationUntilAppearingAgain() async throws {
        let context = makeContext()
        _ = try #require(await applyRequest(
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
        let transactionDeliveryCountBeforeHiddenUpdate = listViewController
            .fetchedResultsTransactionDeliveryCountForTesting

        listViewController.suspendRenderingForTesting()
        model.setSearchText("does-not-match")
        #expect(await listViewController.waitForFetchedResultsTransactionDeliveryForTesting(
            after: transactionDeliveryCountBeforeHiddenUpdate
        ))

        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate)
        #expect(listViewController.displayedRequestIDsForTesting.count == 1)

        listViewController.resumeRenderingForTesting()
        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedRequestIDsForTesting.isEmpty)
        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate + 1)
    }

    @Test
    func repeatedHideShowBoundsRetiredSnapshotBuildsAndAppliesLatestRevision() async throws {
        let context = makeContext()
        let firstRequestID = context.seedNetworkRequest(
            requestID: "first",
            url: "https://example.test/first.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 0
        )
        let model = NetworkPanelModel(context: context)
        let firstRequest = try #require(context.registeredRequest(for: firstRequestID))
        let frameScheduler = ManualNetworkListFrameScheduler()
        let snapshotBuilder = BarrierNetworkListSnapshotBuilderFactory()
        let listViewController = NetworkListViewController(
            model: model,
            listFrameScheduler: frameScheduler,
            listSnapshotBuilderFactory: snapshotBuilder
        )
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }

        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(1)
        await snapshotBuilder.releaseBuild(1)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await listViewController.waitForSnapshotPipelineQuiescenceForTesting()
        #expect(listViewController.displayedRequestIDsForTesting == [firstRequest.id])
        var transactionDeliveryBaseline = listViewController.fetchedResultsTransactionDeliveryCountForTesting
        let secondRequestID = context.seedNetworkRequest(
            requestID: "second",
            url: "https://example.test/second.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 1
        )
        let secondRequest = try #require(context.registeredRequest(for: secondRequestID))
        #expect(await listViewController.waitForFetchedResultsTransactionDeliveryForTesting(
            after: transactionDeliveryBaseline
        ))

        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(2)
        #expect(listViewController.hasActiveListSnapshotBuildForTesting)

        listViewController.suspendRenderingForTesting()
        #expect(listViewController.hasActiveListSnapshotBuildForTesting == false)
        #expect(frameScheduler.hasScheduledFrame == false)
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 1)
        await snapshotBuilder.waitUntilCancellationObservedCount(1)

        listViewController.resumeRenderingForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        #expect(listViewController.hasDeferredListSnapshotBuildForTesting)
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 1)
        var statistics = await snapshotBuilder.statistics()
        #expect(statistics.startedBuildCount == 2)
        await snapshotBuilder.releaseBuild(2)
        await snapshotBuilder.waitUntilCancelledBuildCount(1)
        await snapshotBuilder.waitUntilStartedBuildCount(3)
        await snapshotBuilder.releaseBuild(3)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await listViewController.waitForSnapshotPipelineQuiescenceForTesting()

        #expect(listViewController.displayedRequestIDsForTesting == [secondRequest.id, firstRequest.id])
        statistics = await snapshotBuilder.statistics()
        #expect(statistics.activeBuildCount == 0)
        #expect(statistics.cancellationObservedCount == 1)
        #expect(statistics.cancelledBuildCount == 1)
        #expect(statistics.finishedBuildIDs.contains(3))
        #expect(statistics.maximumActiveBuildCount == 1)
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 0)

        transactionDeliveryBaseline = listViewController.fetchedResultsTransactionDeliveryCountForTesting
        let thirdRequestID = context.seedNetworkRequest(
            requestID: "third",
            url: "https://example.test/third.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 2
        )
        let thirdRequest = try #require(context.registeredRequest(for: thirdRequestID))
        #expect(await listViewController.waitForFetchedResultsTransactionDeliveryForTesting(
            after: transactionDeliveryBaseline
        ))
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(4)
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 1)

        listViewController.suspendRenderingForTesting()
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 1)
        #expect(frameScheduler.hasScheduledFrame == false)
        await snapshotBuilder.waitUntilCancellationObservedCount(2)

        listViewController.resumeRenderingForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        #expect(listViewController.hasDeferredListSnapshotBuildForTesting)
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 1)
        statistics = await snapshotBuilder.statistics()
        #expect(statistics.startedBuildCount == 4)

        await snapshotBuilder.releaseBuild(4)
        await snapshotBuilder.waitUntilCancelledBuildCount(2)
        await snapshotBuilder.waitUntilStartedBuildCount(5)
        #expect(listViewController.hasDeferredListSnapshotBuildForTesting == false)
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 1)
        await snapshotBuilder.releaseBuild(5)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await listViewController.waitForSnapshotPipelineQuiescenceForTesting()
        #expect(
            listViewController.displayedRequestIDsForTesting
                == [thirdRequest.id, secondRequest.id, firstRequest.id]
        )

        transactionDeliveryBaseline = listViewController.fetchedResultsTransactionDeliveryCountForTesting
        let fourthRequestID = context.seedNetworkRequest(
            requestID: "fourth",
            url: "https://example.test/fourth.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 3
        )
        let fourthRequest = try #require(context.registeredRequest(for: fourthRequestID))
        #expect(await listViewController.waitForFetchedResultsTransactionDeliveryForTesting(
            after: transactionDeliveryBaseline
        ))
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(6)
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 1)

        listViewController.suspendRenderingForTesting()
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 1)
        #expect(frameScheduler.hasScheduledFrame == false)
        await snapshotBuilder.waitUntilCancellationObservedCount(3)

        listViewController.resumeRenderingForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        #expect(listViewController.hasDeferredListSnapshotBuildForTesting)
        statistics = await snapshotBuilder.statistics()
        #expect(statistics.startedBuildCount == 6)
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 1)

        await snapshotBuilder.releaseBuild(6)
        await snapshotBuilder.waitUntilCancelledBuildCount(3)
        await snapshotBuilder.waitUntilStartedBuildCount(7)
        #expect(listViewController.hasDeferredListSnapshotBuildForTesting == false)
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 1)
        await snapshotBuilder.releaseBuild(7)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await listViewController.waitForSnapshotPipelineQuiescenceForTesting()

        #expect(
            listViewController.displayedRequestIDsForTesting
                == [fourthRequest.id, thirdRequest.id, secondRequest.id, firstRequest.id]
        )
        #expect(listViewController.displayedEntryIDsForTesting == model.displayEntryIDs)
        statistics = await snapshotBuilder.statistics()
        #expect(statistics.activeBuildCount == 0)
        #expect(statistics.maximumActiveBuildCount == 1)
        #expect(statistics.cancellationObservedCount == 3)
        #expect(statistics.cancelledBuildCount == 3)
        #expect(statistics.finishedBuildIDs.isSuperset(of: [3, 5, 7]))
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 0)

        await listViewController.waitForTrackedListSnapshotBuildTasksForTesting()
        statistics = await snapshotBuilder.statistics()
        #expect(statistics.activeBuildCount == 0)
        #expect(statistics.cancelledBuildCount == 3)
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 0)
        #expect(statistics.startedBuildPriorities.allSatisfy { $0 == .userInitiated })
    }

    @Test
    func hiddenListReconcilesAfterInFlightApplyCompletesWhileHidden() async throws {
        let context = makeContext()
        let request = try #require(await applyRequest(
            to: context,
            requestID: "1",
            url: "https://media.example.com/clip.mp4",
            responseHeaders: ["content-type": "video/mp4"],
            responseMimeType: "video/mp4"
        ))
        let model = NetworkPanelModel(context: context)
        let frameScheduler = ManualNetworkListFrameScheduler()
        let snapshotBuilder = BarrierNetworkListSnapshotBuilderFactory()
        let applyCompletionScheduler = ManualNetworkListSnapshotApplyCompletionScheduler()
        let listViewController = NetworkListViewController(
            model: model,
            listFrameScheduler: frameScheduler,
            listSnapshotBuilderFactory: snapshotBuilder,
            snapshotApplyCompletionScheduler: applyCompletionScheduler
        )
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }

        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(1)
        await snapshotBuilder.releaseBuild(1)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await applyCompletionScheduler.waitUntilScheduledCompletionCount(1)
        applyCompletionScheduler.runNextCompletion()
        await listViewController.waitForSnapshotPipelineQuiescenceForTesting()
        #expect(listViewController.displayedRequestIDsForTesting == [request.id])

        var transactionDeliveryBaseline = listViewController.fetchedResultsTransactionDeliveryCountForTesting
        model.setSearchText("does-not-match")
        #expect(await listViewController.waitForFetchedResultsTransactionDeliveryForTesting(
            after: transactionDeliveryBaseline
        ))
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(2)
        await snapshotBuilder.releaseBuild(2)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await applyCompletionScheduler.waitUntilScheduledCompletionCount(2)

        #expect(listViewController.snapshotApplyCountForTesting == 2)
        #expect(listViewController.displayedRequestIDsForTesting.isEmpty)

        let evaluationCountBeforeHiddenUpdate = listViewController.displayRequestIDsEvaluationCountForTesting
        listViewController.suspendRenderingForTesting()
        #expect(listViewController.hasPendingSnapshotUpdateForTesting == false)
        #expect(frameScheduler.hasScheduledFrame == false)

        transactionDeliveryBaseline = listViewController.fetchedResultsTransactionDeliveryCountForTesting
        model.setSearchText("")
        #expect(await listViewController.waitForFetchedResultsTransactionDeliveryForTesting(
            after: transactionDeliveryBaseline
        ))
        applyCompletionScheduler.runNextCompletion()

        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate)
        #expect(listViewController.displayedRequestIDsForTesting.isEmpty)
        #expect(frameScheduler.hasScheduledFrame == false)

        listViewController.resumeRenderingForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(3)
        await snapshotBuilder.releaseBuild(3)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await applyCompletionScheduler.waitUntilScheduledCompletionCount(3)
        applyCompletionScheduler.runNextCompletion()
        await listViewController.waitForSnapshotPipelineQuiescenceForTesting()

        #expect(listViewController.displayedRequestIDsForTesting == [request.id])
        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate + 1)
        #expect(applyCompletionScheduler.pendingCompletionCount == 0)
    }

    @Test
    func hiddenFilteredListSkipsSnapshotReloadWhenRowsRemainVisible() async throws {
        let context = makeContext()
        let request = try #require(await applyRequest(
            to: context,
            requestID: "1",
            url: "https://media.example.com/clip.mp4",
            responseHeaders: ["content-type": "video/mp4"],
            responseMimeType: "video/mp4"
        ))
        let model = NetworkPanelModel(context: context)
        model.setResourceFilter(.media, enabled: true)
        let listViewController = NetworkListViewController(model: model)
        listViewController.loadViewIfNeeded()
        listViewController.resumeRenderingForTesting()
        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedRequestIDsForTesting == [request.id])

        let evaluationCountBeforeHiddenUpdate = listViewController.displayRequestIDsEvaluationCountForTesting
        let snapshotApplyCountBeforeHiddenUpdate = listViewController.snapshotApplyCountForTesting

        listViewController.suspendRenderingForTesting()
        await applyResponseReceived(
            to: context,
            requestID: "1",
            url: request.url,
            responseHeaders: ["content-type": "image/png"],
            responseMimeType: "image/png",
            timestamp: 4
        )

        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyCountBeforeHiddenUpdate)
        #expect(listViewController.displayedRequestIDsForTesting == [request.id])

        listViewController.resumeRenderingForTesting()

        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyCountBeforeHiddenUpdate)
        #expect(listViewController.displayedRequestIDsForTesting == [request.id])

        await listViewController.flushPendingSnapshotUpdateForTesting()

        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyCountBeforeHiddenUpdate)
        #expect(listViewController.displayedRequestIDsForTesting == [request.id])
    }

    @Test
    func networkListCellSuspendsBoundRenderingUntilReactivated() async throws {
        let context = makeContext()
        let request = try #require(await applyRequest(
            to: context,
            requestID: "1",
            url: "https://media.example.com/clip.mp4",
            responseHeaders: ["content-type": "video/mp4"],
            responseMimeType: "video/mp4"
        ))
        let model = NetworkPanelModel(context: context)
        let entry = try #require(model.displayEntries.first)
        let cell = NetworkListCell(frame: CGRect(x: 0, y: 0, width: 390, height: 44))
        cell.bind(entry: entry, renderingActive: true)
        #expect(cell.fileTypeLabelForTesting == "mp4")
        #expect(cell.hasActiveRequestObservationForTesting)

        cell.setRenderingActive(false)
        #expect(cell.hasActiveRequestObservationForTesting == false)

        await applyResponseReceived(
            to: context,
            requestID: "1",
            url: request.url,
            responseHeaders: ["content-type": "text/css"],
            responseMimeType: "text/css",
            timestamp: 4
        )

        #expect(cell.fileTypeLabelForTesting == "mp4")

        cell.setRenderingActive(true)

        #expect(cell.hasActiveRequestObservationForTesting)
        #expect(cell.fileTypeLabelForTesting == "css")
    }

    @Test
    func groupedHeadersRenderEveryMemberInChronologicalOrder() async throws {
        let context = makeContext()
        let frameID = FrameID("main-frame")
        let nodeID = DOM.Node.ID("grouped-loader")
        installNavigationVisit(in: context, frameID: frameID)
        let firstRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "first",
            url: "https://example.com/first.js",
            frameID: frameID,
            initiatorNodeID: nodeID,
            requestHeaders: ["x-member": "first"],
            responseHeaders: ["content-type": "text/javascript"],
            responseMIMEType: "text/javascript",
            timestamp: 1
        ))
        let secondRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "second",
            url: "https://example.com/second.js",
            frameID: frameID,
            initiatorNodeID: nodeID,
            requestHeaders: ["x-member": "second"],
            responseHeaders: ["content-type": "text/javascript"],
            responseMIMEType: "text/javascript",
            timestamp: 4
        ))
        let model = NetworkPanelModel(context: context)
        model.selectRequest(secondRequest)
        let viewController = makeNetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderAllMembers = await waitUntilRendered(in: viewController) {
            let text = viewController.headersTextViewForTesting.renderedTextForTesting
            return text.contains("1. first.js")
                && text.contains("2. second.js")
                && text.contains("x-member: first")
                && text.contains("x-member: second")
        }
        #expect(didRenderAllMembers)
        let renderedText = viewController.headersTextViewForTesting.renderedTextForTesting
        let firstHeading = try #require(renderedText.range(of: "1. first.js"))
        let secondHeading = try #require(renderedText.range(of: "2. second.js"))
        #expect(firstHeading.lowerBound < secondHeading.lowerBound)
        #expect(model.selectedRequest === firstRequest)
        #expect(model.selectedRequests.map(\.id) == [firstRequest.id, secondRequest.id])
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
        model.selectRequest(partialSegmentRequest)
        let viewController = makeNetworkDetailViewController(model: model, initialMode: .preview)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didSelectHLSPreview = await waitUntilRendered(in: viewController) {
            viewController.previewRequestIDForTesting == hlsRequest.id
                && viewController.currentModeForTesting == .preview
                && viewController.previewViewForTesting.isHidden == false
        }
        #expect(didSelectHLSPreview)
        #expect(model.selectedRequest?.id == hlsRequest.id)
        #expect(model.selectedRequests.map(\.id) == [hlsRequest.id, partialSegmentRequest.id])
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
        model.selectRequest(firstRequest)
        let viewController = makeNetworkDetailViewController(model: model, initialMode: .preview)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.syntaxBodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(await waitUntilRendered(in: viewController) {
            viewController.previewRequestIDForTesting == firstRequest.id
                && playerFactory.players.count == 1
        })
        let firstPlayerID = try #require(
            viewController.syntaxBodyViewControllerForTesting.mediaPlayerIdentityForTesting
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
            viewController.syntaxBodyViewControllerForTesting.mediaPlayerIdentityForTesting
                != firstPlayerID
        )
        #expect(model.selectedRequests.map(\.id) == [firstRequest.id, secondRequest.id])
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
        model.selectRequest(firstRequest)
        let viewController = makeNetworkDetailViewController(model: model, initialMode: .preview)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.syntaxBodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(await waitUntilRendered(in: viewController) {
            viewController.previewRequestIDForTesting == firstRequest.id
                && viewController.syntaxBodyViewControllerForTesting
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
                && viewController.syntaxBodyViewControllerForTesting
                    .mediaPlayerURLForTesting?.absoluteString == secondRequest.url
                && playerFactory.players.count == 2
        })
        #expect(model.selectedRequests.map(\.id) == [firstRequest.id, secondRequest.id])
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
        model.selectRequest(partialRequest)
        let viewController = makeNetworkDetailViewController(model: model, initialMode: .preview)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.syntaxBodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
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
        model.selectRequest(noContentRequest)
        let viewController = makeNetworkDetailViewController(model: model, initialMode: .preview)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didSelectHealthyPreview = await waitUntilRendered(in: viewController) {
            viewController.previewRequestIDForTesting == healthyRequest.id
                && viewController.currentModeForTesting == .preview
                && viewController.previewViewForTesting.isHidden == false
        }
        #expect(didSelectHealthyPreview)
        #expect(model.selectedRequests.map(\.id) == [healthyRequest.id, failedRequest.id, noContentRequest.id])
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
        model.selectRequest(unavailableMediaRequest)
        let viewController = makeNetworkDetailViewController(model: model, initialMode: .preview)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(await waitUntilRendered(in: viewController) {
            viewController.previewRequestIDForTesting == standardRequest.id
        })
        viewController.selectPreviewRoleForTesting(.request)
        #expect(await waitUntilRendered(in: viewController) {
            viewController.currentPreviewRoleForTesting == .request
                && viewController.syntaxBodyViewControllerForTesting.syntaxViewForTesting.text
                    .contains("metadata")
        })
    }

    @Test
    func visibleGroupedListKeepsEntryIdentityWhenMemberArrives() async throws {
        let context = makeContext()
        let frameID = FrameID("main-frame")
        let nodeID = DOM.Node.ID("grouped-loader")
        installNavigationVisit(in: context, frameID: frameID)
        let firstRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "first",
            url: "https://example.com/first.js",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 1
        ))
        let model = NetworkPanelModel(context: context)
        let stableEntryID = try #require(model.entryID(containing: firstRequest.id))
        let stableEntry = try #require(model.entry(for: stableEntryID))
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }
        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedEntryIDsForTesting == [stableEntryID])

        let transactionDeliveryBaseline = listViewController.fetchedResultsTransactionDeliveryCountForTesting
        let entryObservation = withPortableContinuousObservation { _ in
            _ = stableEntry.requests
        }
        let groupedRequestIDs = await entryObservation.values {
            stableEntry.requests.map(\.id)
        }
        defer {
            groupedRequestIDs.cancel()
            entryObservation.cancel()
        }
        let secondRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "second",
            url: "https://example.com/second.js",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 4
        ))
        let didUpdateStableEntry = await groupedRequestIDs.waitUntilValue([
            firstRequest.id,
            secondRequest.id,
        ])

        #expect(didUpdateStableEntry)
        #expect(listViewController.fetchedResultsTransactionDeliveryCountForTesting == transactionDeliveryBaseline)
        #expect(listViewController.displayedEntryIDsForTesting == [stableEntryID])
        #expect(model.entry(for: stableEntryID) === stableEntry)
        #expect(stableEntry.requests.map(\.id) == [firstRequest.id, secondRequest.id])
    }

    @Test
    func filteredOutSelectionRendersLaterMembersFromSameGroup() async throws {
        let context = makeContext()
        let frameID = FrameID("main-frame")
        let nodeID = DOM.Node.ID("filtered-group")
        installNavigationVisit(in: context, frameID: frameID)
        let firstRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "first",
            url: "https://example.com/first.js",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 1
        ))
        let model = NetworkPanelModel(context: context)
        model.selectRequest(firstRequest)
        let viewController = makeNetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        #expect(await waitUntilRendered(in: viewController) {
            viewController.headersTextViewForTesting.renderedTextForTesting.contains("first.js")
        })

        model.setSearchText("does-not-match")
        #expect(model.displayEntryIDs.isEmpty)

        let secondRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "second",
            url: "https://example.com/second.js",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 4
        ))

        #expect(await waitUntilRendered(in: viewController) {
            let text = viewController.headersTextViewForTesting.renderedTextForTesting
            return text.contains("first.js") && text.contains("second.js")
        })
        #expect(model.displayEntryIDs.isEmpty)
        #expect(model.selectedRequests.map(\.id) == [firstRequest.id, secondRequest.id])
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

    private func installNavigationVisit(
        in context: WebInspectorContext,
        frameID: FrameID
    ) {
        context.apply(WebInspectorTargetLifecycleEvent.frameNavigated(WebInspectorPageFrameLifecycle(
            id: frameID,
            parentID: nil,
            pageBindingID: "page",
            loaderID: "loader",
            name: "Main",
            url: "https://example.com",
            securityOrigin: "https://example.com",
            mimeType: "text/html"
        )))
    }

    private func applyGroupedRequest(
        to context: WebInspectorContext,
        requestID rawRequestID: String,
        url: String,
        frameID: FrameID,
        initiatorNodeID: DOM.Node.ID,
        requestHeaders: [String: String] = [:],
        postData: String? = nil,
        responseHeaders: [String: String] = ["content-type": "text/javascript"],
        responseMIMEType: String = "text/javascript",
        responseStatus: Int = 200,
        resourceType: Network.ResourceType = .script,
        finishes: Bool = true,
        timestamp: Double
    ) async -> NetworkRequest? {
        let requestID = Network.Request.ID(rawRequestID)
        await context.apply(.requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: url,
                method: postData == nil ? "GET" : "POST",
                headers: requestHeaders,
                postData: postData,
                origin: Network.Request.Origin(
                    frameID: frameID,
                    loaderID: "loader",
                    targetID: "page"
                )
            ),
            initiator: Network.Initiator(kind: "script", nodeID: initiatorNodeID),
            resourceType: resourceType,
            redirectResponse: nil,
            timestamp: timestamp
        ))
        await context.apply(.responseReceived(
            id: requestID,
            response: Network.Response(
                url: url,
                status: responseStatus,
                statusText: responseStatus == 206 ? "Partial Content" : "OK",
                mimeType: responseMIMEType,
                headers: responseHeaders,
                source: Network.Source(rawValue: "network"),
                requestHeaders: requestHeaders
            ),
            resourceType: resourceType,
            timestamp: timestamp + 1
        ))
        if finishes {
            await context.apply(.loadingFinished(
                id: requestID,
                timestamp: timestamp + 2,
                sourceMapURL: nil,
                metrics: nil
            ))
        }
        return context.registeredRequest(forProxyID: requestID)
    }

    private func applyRequest(
        to context: WebInspectorContext,
        requestID rawRequestID: String,
        url: String,
        requestHeaders: [String: String] = [:],
        postData: String? = nil,
        responseHeaders: [String: String] = ["content-type": "text/javascript"],
        responseMimeType: String = "text/javascript",
        responseStatus: Int = 200,
        resourceType: Network.ResourceType = .script,
        method: String? = nil,
        finishes: Bool = true
    ) async -> NetworkRequest? {
        let requestID = Network.Request.ID(rawRequestID)
        await context.apply(
            .requestWillBeSent(
                id: requestID,
                request: Network.Request(
                    id: requestID,
                    url: url,
                    method: method ?? (postData == nil ? "GET" : "POST"),
                    headers: requestHeaders,
                    postData: postData
                ),
                resourceType: resourceType,
                redirectResponse: nil,
                timestamp: 1
            )
        )
        await context.apply(
            .responseReceived(
                id: requestID,
                response: Network.Response(
                    url: url,
                    status: responseStatus,
                    statusText: responseStatus == 206 ? "Partial Content" : "OK",
                    mimeType: responseMimeType,
                    headers: responseHeaders,
                    source: Network.Source(rawValue: "network"),
                    requestHeaders: requestHeaders
                ),
                resourceType: resourceType,
                timestamp: 2
            )
        )
        if finishes {
            await context.apply(
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
    ) async -> NetworkRequest? {
        let requestID = Network.Request.ID(rawRequestID)
        await context.apply(
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
    ) async {
        let requestID = Network.Request.ID(rawRequestID)
        await context.apply(
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
        makeVisible: Bool = true,
        useUIKitVisibility: Bool = false
    ) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = viewController
        viewController.loadViewIfNeeded()
        viewController.view.frame = window.bounds
        if makeVisible, useUIKitVisibility {
            window.makeKeyAndVisible()
        } else if makeVisible {
            activateNetworkRenderingForTesting(in: viewController)
        }
        window.layoutIfNeeded()
        return window
    }

    private func activateNetworkRenderingForTesting(in viewController: UIViewController) {
        if let navigationController = viewController as? NetworkCompactNavigationController {
            navigationController.resumeSelectionObservationForTesting()
            for child in navigationController.viewControllers {
                activateNetworkRenderingForTesting(in: child)
            }
            return
        }

        if let navigationController = viewController as? UINavigationController {
            for child in navigationController.viewControllers {
                activateNetworkRenderingForTesting(in: child)
            }
            return
        }

        if let listViewController = viewController as? NetworkListViewController {
            listViewController.resumeRenderingForTesting()
        }

        if let detailViewController = viewController as? NetworkDetailViewController {
            detailViewController.resumeRenderingForTesting()
        }
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

    private func waitUntilPreparedTextPreviewRendered(
        in viewController: NetworkDetailViewController,
        _ condition: @escaping @MainActor @Sendable () -> Bool
    ) async -> Bool {
        if await waitUntilRendered(in: viewController, condition) {
            return true
        }
        await viewController.syntaxBodyViewControllerForTesting.waitUntilTextPreviewPreparationFinishedForTesting()
        return await waitUntilRendered(in: viewController, condition)
    }

    private func waitUntilListShows(
        _ requestIDs: [NetworkRequest.ID],
        in viewController: NetworkListViewController,
        afterTransactionDeliveryCount transactionDeliveryCount: Int
    ) async -> Bool {
        guard await viewController.waitForFetchedResultsTransactionDeliveryForTesting(
            after: transactionDeliveryCount
        ) else {
            return false
        }
        await viewController.flushPendingSnapshotUpdateForTesting()
        return viewController.displayedRequestIDsForTesting == requestIDs
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
                if navigationController.view.window?.isHidden != false {
                    navigationController.syncStackForTesting()
                    for child in navigationController.viewControllers {
                        activateNetworkRenderingForTesting(in: child)
                    }
                }
                return condition()
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
        var deliveries = [
            viewController.modelObservationDeliveryForTesting,
            viewController.selectedRequestRenderObservationDeliveryForTesting,
            viewController.responseBodyFetchObservationDeliveryForTesting,
        ].compactMap { $0 }
        if let syntaxBodyViewController = viewController.bodyViewControllerForTesting as? NetworkBodyViewController {
            deliveries.append(contentsOf: [
                syntaxBodyViewController.bodyObservationDeliveryForTesting,
                syntaxBodyViewController.previewRenderObservationDeliveryForTesting,
            ].compactMap { $0 })
        }
        return deliveries
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
        private(set) var players: [StubMoviePreviewPlayer] = []

        func makePlayer() -> AVPlayer {
            let player = StubMoviePreviewPlayer()
            players.append(player)
            return player
        }
    }
}
}

@MainActor
private func makeNetworkDetailViewController(
    model: NetworkPanelModel,
    initialMode: NetworkDetailViewController.Mode = .headers,
    makeBodyViewController: @escaping NetworkBodyViewControllerFactory = NetworkBodyPreviewFactory.make(scrollEdgeSink:)
) -> NetworkDetailViewController {
    NetworkDetailViewController(
        model: model,
        initialMode: initialMode,
        makeBodyViewController: makeBodyViewController
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

private func makeNetworkListSnapshotBaseline(
    entryIDs: [NetworkListEntry.ID] = [],
    version: NetworkPanelListVersion = NetworkPanelListVersion(
        revision: 0,
        entryIdentityGeneration: 0
    ),
    generation: UInt64 = 0
) -> NetworkListSnapshotBaseline {
    var snapshot = NSDiffableDataSourceSnapshot<NetworkListSnapshotSection, NetworkListEntry.ID>()
    snapshot.appendSections([.main])
    snapshot.appendItems(entryIDs, toSection: .main)
    return NetworkListSnapshotBaseline(
        generation: generation,
        version: version,
        entryIDs: entryIDs,
        snapshot: snapshot
    )
}

private func makeNetworkListSnapshotBuildInput(
    baseline: NetworkListSnapshotBaseline = makeNetworkListSnapshotBaseline(),
    target: NetworkPanelListProjection
) -> NetworkListSnapshotBuildInput {
    NetworkListSnapshotBuildInput(baseline: baseline, target: target)
}

private actor NetworkListBuilderStartGate {
    private var isWaiting = false
    private var isReleased = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var waitingContinuations: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        isWaiting = true
        let continuations = waitingContinuations
        waitingContinuations.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume()
        }
        guard isReleased == false else {
            return
        }
        await withCheckedContinuation { continuation in
            precondition(releaseContinuation == nil)
            releaseContinuation = continuation
        }
    }

    func waitUntilWaiting() async {
        guard isWaiting == false else {
            return
        }
        await withCheckedContinuation { continuation in
            waitingContinuations.append(continuation)
        }
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
private final class RecordingNetworkBodyPreviewViewController: UIViewController, NetworkBodyPreviewControlling {
    private var surface = NetworkBodySurface.none
    private(set) var isRenderingActiveForTesting = false

    var currentBodyForTesting: NetworkBody? {
        surface.body
    }

    func setSurface(_ nextSurface: NetworkBodySurface) {
        surface = nextSurface
    }

    func resumeRendering() {
        isRenderingActiveForTesting = true
    }

    func suspendKeepingSurface() {
        isRenderingActiveForTesting = false
    }
}

@MainActor
private final class ManualNetworkListFrameScheduler: NetworkListFrameScheduling {
    private var pendingAction: (@MainActor () -> Void)?
    private(set) var scheduledFrameCount = 0

    var hasScheduledFrame: Bool {
        pendingAction != nil
    }

    func schedule(_ action: @escaping @MainActor () -> Void) {
        guard pendingAction == nil else {
            return
        }
        pendingAction = action
        scheduledFrameCount += 1
    }

    func cancel() {
        pendingAction = nil
    }

    func invalidate() {
        cancel()
    }

    func fireScheduledFrame() {
        guard let action = pendingAction else {
            preconditionFailure("Expected a scheduled Network list projection frame.")
        }
        pendingAction = nil
        action()
    }
}

@MainActor
private final class ManualNetworkListSnapshotApplyCompletionScheduler:
    NetworkListSnapshotApplyCompletionScheduling
{
    private struct Waiter {
        var targetCount: Int
        var continuation: CheckedContinuation<Void, Never>
    }

    private var scheduledCompletionCount = 0
    private var pendingCompletions: [@MainActor @Sendable () -> Void] = []
    private var waiters: [Waiter] = []

    var pendingCompletionCount: Int {
        pendingCompletions.count
    }

    func schedule(_ completion: @escaping @MainActor @Sendable () -> Void) {
        scheduledCompletionCount += 1
        pendingCompletions.append(completion)
        resumeWaiters()
    }

    func waitUntilScheduledCompletionCount(_ targetCount: Int) async {
        guard scheduledCompletionCount < targetCount else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(
                Waiter(
                    targetCount: targetCount,
                    continuation: continuation
                )
            )
        }
    }

    func runNextCompletion() {
        guard pendingCompletions.isEmpty == false else {
            preconditionFailure("Expected a pending Network list snapshot apply completion.")
        }
        pendingCompletions.removeFirst()()
    }

    private func resumeWaiters() {
        var remainingWaiters: [Waiter] = []
        for waiter in waiters {
            if scheduledCompletionCount >= waiter.targetCount {
                waiter.continuation.resume()
            } else {
                remainingWaiters.append(waiter)
            }
        }
        waiters = remainingWaiters
    }
}

private struct BarrierNetworkListSnapshotBuilderFactory: NetworkListSnapshotBuilderMaking {
    private let state = BarrierNetworkListSnapshotBuildState()

    func makeBuilder() -> any NetworkListSnapshotBuilding {
        BarrierNetworkListSnapshotBuilder(state: state)
    }

    func waitUntilStartedBuildCount(_ targetCount: Int) async {
        await state.waitUntilStartedBuildCount(targetCount)
    }

    func releaseBuild(_ buildID: Int) async {
        await state.releaseBuild(buildID)
    }

    func waitUntilCancellationObservedCount(_ targetCount: Int) async {
        await state.waitUntilCancellationObservedCount(targetCount)
    }

    func waitUntilCancelledBuildCount(_ targetCount: Int) async {
        await state.waitUntilCancelledBuildCount(targetCount)
    }

    func statistics() async -> BarrierNetworkListSnapshotBuildState.Statistics {
        await state.statistics()
    }
}

private actor BarrierNetworkListSnapshotBuilder: NetworkListSnapshotBuilding {
    private let state: BarrierNetworkListSnapshotBuildState

    init(state: BarrierNetworkListSnapshotBuildState) {
        self.state = state
    }

    func build(
        _ input: NetworkListSnapshotBuildInput
    ) async throws(CancellationError) -> NetworkListSnapshotArtifact {
        let buildID = await state.buildDidStart(priority: Task.currentPriority)
        await withTaskCancellationHandler {
            await state.waitForRelease(of: buildID)
        } onCancel: {
            Task {
                await state.buildDidObserveCancellation(buildID)
            }
        }
        guard !Task.isCancelled else {
            await state.buildDidCancel(buildID)
            throw CancellationError()
        }

        let artifact = try await NetworkListSnapshotBuilder().build(input)
        await state.buildDidFinish(buildID)
        return artifact
    }
}

private actor BarrierNetworkListSnapshotBuildState {
    struct Statistics: Equatable, Sendable {
        var startedBuildCount: Int
        var activeBuildCount: Int
        var maximumActiveBuildCount: Int
        var cancellationObservedCount: Int
        var cancelledBuildCount: Int
        var finishedBuildIDs: Set<Int>
        var startedBuildPriorities: [TaskPriority]
    }

    private struct CountWaiter {
        var targetCount: Int
        var continuation: CheckedContinuation<Void, Never>
    }

    private var startedBuildCount = 0
    private var activeBuildIDs: Set<Int> = []
    private var maximumActiveBuildCount = 0
    private var cancellationObservedBuildIDs: Set<Int> = []
    private var cancelledBuildCount = 0
    private var finishedBuildIDs: Set<Int> = []
    private var startedBuildPriorities: [TaskPriority] = []
    private var releasedBuilds: Set<Int> = []
    private var releaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var startedBuildWaiters: [CountWaiter] = []
    private var cancellationObservedWaiters: [CountWaiter] = []
    private var cancelledBuildWaiters: [CountWaiter] = []

    func buildDidStart(priority: TaskPriority) -> Int {
        startedBuildCount += 1
        let buildID = startedBuildCount
        precondition(activeBuildIDs.insert(buildID).inserted)
        maximumActiveBuildCount = Swift.max(maximumActiveBuildCount, activeBuildIDs.count)
        startedBuildPriorities.append(priority)
        resumeStartedBuildWaiters()
        return buildID
    }

    func buildDidObserveCancellation(_ buildID: Int) {
        if cancellationObservedBuildIDs.insert(buildID).inserted {
            resumeCancellationObservedWaiters()
        }
    }

    func buildDidCancel(_ buildID: Int) {
        precondition(
            activeBuildIDs.remove(buildID) != nil,
            "A canceled Network list snapshot build must still be active."
        )
        cancelledBuildCount += 1
        resumeCancelledBuildWaiters()
    }

    func buildDidFinish(_ buildID: Int) {
        precondition(
            activeBuildIDs.remove(buildID) != nil && finishedBuildIDs.insert(buildID).inserted,
            "A Network list snapshot build must finish exactly once."
        )
    }

    func waitUntilStartedBuildCount(_ targetCount: Int) async {
        guard startedBuildCount < targetCount else {
            return
        }
        await withCheckedContinuation { continuation in
            startedBuildWaiters.append(
                CountWaiter(
                    targetCount: targetCount,
                    continuation: continuation
                )
            )
        }
    }

    func releaseBuild(_ buildID: Int) {
        if let waiter = releaseWaiters.removeValue(forKey: buildID) {
            waiter.resume()
        } else {
            releasedBuilds.insert(buildID)
        }
    }

    func waitUntilCancellationObservedCount(_ targetCount: Int) async {
        guard cancellationObservedBuildIDs.count < targetCount else {
            return
        }
        await withCheckedContinuation { continuation in
            cancellationObservedWaiters.append(
                CountWaiter(
                    targetCount: targetCount,
                    continuation: continuation
                )
            )
        }
    }

    func waitUntilCancelledBuildCount(_ targetCount: Int) async {
        guard cancelledBuildCount < targetCount else {
            return
        }
        await withCheckedContinuation { continuation in
            cancelledBuildWaiters.append(
                CountWaiter(
                    targetCount: targetCount,
                    continuation: continuation
                )
            )
        }
    }

    func statistics() -> Statistics {
        Statistics(
            startedBuildCount: startedBuildCount,
            activeBuildCount: activeBuildIDs.count,
            maximumActiveBuildCount: maximumActiveBuildCount,
            cancellationObservedCount: cancellationObservedBuildIDs.count,
            cancelledBuildCount: cancelledBuildCount,
            finishedBuildIDs: finishedBuildIDs,
            startedBuildPriorities: startedBuildPriorities
        )
    }

    func waitForRelease(of buildID: Int) async {
        if releasedBuilds.remove(buildID) == nil {
            await withCheckedContinuation { continuation in
                precondition(
                    releaseWaiters[buildID] == nil,
                    "A Network list snapshot build can only wait on one release barrier."
                )
                releaseWaiters[buildID] = continuation
            }
        }
    }

    private func resumeStartedBuildWaiters() {
        var remainingWaiters: [CountWaiter] = []
        for waiter in startedBuildWaiters {
            if startedBuildCount >= waiter.targetCount {
                waiter.continuation.resume()
            } else {
                remainingWaiters.append(waiter)
            }
        }
        startedBuildWaiters = remainingWaiters
    }

    private func resumeCancelledBuildWaiters() {
        var remainingWaiters: [CountWaiter] = []
        for waiter in cancelledBuildWaiters {
            if cancelledBuildCount >= waiter.targetCount {
                waiter.continuation.resume()
            } else {
                remainingWaiters.append(waiter)
            }
        }
        cancelledBuildWaiters = remainingWaiters
    }

    private func resumeCancellationObservedWaiters() {
        var remainingWaiters: [CountWaiter] = []
        for waiter in cancellationObservedWaiters {
            if cancellationObservedBuildIDs.count >= waiter.targetCount {
                waiter.continuation.resume()
            } else {
                remainingWaiters.append(waiter)
            }
        }
        cancellationObservedWaiters = remainingWaiters
    }
}
#endif
