#if canImport(UIKit)
import AVFoundation
import ObservationBridge
import Synchronization
import Testing
import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import WebInspectorTestSupport
import UIKit
@testable import WebInspectorUI
@testable import WebInspectorUISyntaxBody
@testable import WebInspectorUINetwork
@testable import WebInspectorUIBase

extension WebInspectorUIRenderingTests {
@MainActor
@Suite
struct NetworkDetailViewControllerTests {
    private struct UnavailableMediaPreviewCase: Sendable {
        let name: String
        let pathExtension: String
        let mimeType: String
        let method: String
        let status: Int
        let finishes: Bool
    }

    @Test
    func resourceFilterSpecialistTitlesFollowWebInspectorLabels() {
        #expect(NetworkDisplay.ResourceFilter.stylesheet.localizedTitle == "CSS")
        #expect(NetworkDisplay.ResourceFilter.media.localizedTitle == String(localized: "network.filter.media", bundle: WebInspectorUILocalization.bundle))
        #expect(localizedResourceString("network.filter.media", locale: "en") == "Media")
        #expect(NetworkDisplay.ResourceFilter.script.localizedTitle == "JS")
        #expect(NetworkDisplay.ResourceFilter.xhrFetch.localizedTitle == "XHR / Fetch")
    }

    @Test
    func listShowsSimpleEmptyStateWithoutRequests() async throws {
        let model = try await NetworkPanelModel.make(context: makeContext())
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
    func detailShowsEmptyStateWithoutSelection() async throws {
        let model = try await NetworkPanelModel.make(context: makeContext())
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
    func detailCanDisableBackgroundDrawing() async throws {
        guard #available(iOS 26.0, *) else {
            return
        }

        let model = try await NetworkPanelModel.make(context: makeContext())
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
    func responseBodyPreflightFailurePopulatesSyntaxPresentation() {
        let body = NetworkBody(
            role: .response,
            kind: .text,
            sourceSyntaxKind: .plainText,
            phase: .failed(.model(.commandRejected(
                method: "Network.getResponseBody",
                message: "The response body is no longer available."
            )))
        )
        let viewController = NetworkBodyViewController()
        viewController.loadViewIfNeeded()
        viewController.setSurface(.body(body, metadata: nil))
        viewController.resumeRendering()

        #expect(
            viewController.syntaxModelTextForTesting
                .contains("The response body is no longer available.")
        )
    }

    @Test
    func listCanDisableBackgroundDrawing() async throws {
        guard #available(iOS 26.0, *) else {
            return
        }

        let model = try await NetworkPanelModel.make(context: makeContext())
        let viewController = NetworkListViewController(model: model)
        viewController.traitOverrides.webInspectorDrawsBackground = false

        viewController.loadViewIfNeeded()

        #expect(viewController.collectionViewForTesting.backgroundColor == .clear)
    }

    @Test
    func listLoadDefersFilterMenuBuildUntilPresentation() async throws {
        let model = try await NetworkPanelModel.make(context: makeContext())
        model.setResourceFilter(.media, enabled: true)
        await model.waitForQueryUpdates()
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
        let model = try await NetworkPanelModel.make(context: context)
        let viewController = NetworkListViewController(model: model)

        viewController.loadViewIfNeeded()

        #expect(viewController.entryIDsEvaluationCountForTesting == 0)
        #expect(viewController.displayedEntryIDsForTesting.isEmpty)

        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        await viewController.flushPendingSnapshotUpdateForTesting()

        #expect(viewController.displayedEntryIDsForTesting == model.requests.snapshot.sectionIDs)
        #expect(viewController.entryIDsEvaluationCountForTesting == 1)
    }

    @Test
    func regularSplitKeepsPrimarySecondaryLayout() async throws {
        let model = try await NetworkPanelModel.make(context: makeContext())
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
    func detailContentKeepsPreviewRoleControlInSafeArea() async throws {
        let model = try await NetworkPanelModel.make(context: makeContext())
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
        let model = try await NetworkPanelModel.make(context: context)
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
                initiator: Network.Initiator(kind: "other"),
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
                initiator: Network.Initiator(kind: "other"),
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
        let model = try await NetworkPanelModel.make(context: context)
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
        let model = try await NetworkPanelModel.make(context: context)
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
        let model = try await NetworkPanelModel.make(context: context)
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
        let model = try await NetworkPanelModel.make(context: context)
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
        let model = try await NetworkPanelModel.make(context: context)
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
        let model = try await NetworkPanelModel.make(context: context)
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
        let model = try await NetworkPanelModel.make(context: context)
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
        let model = try await NetworkPanelModel.make(context: context)
        model.selectRequest(request)
        let viewController = makeNetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didEnableMenu = await waitUntilRendered(in: viewController) {
            viewController.isDetailModeControlEnabledForTesting
        }
        #expect(didEnableMenu)

        await context.clearNetworkRequests()

        let didDisableMenu = await waitUntilRendered(in: viewController) {
            viewController.isDetailModeControlEnabledForTesting == false
                && viewController.contentUnavailableConfiguration != nil
        }
        #expect(didDisableMenu)
    }

    @Test
    func responsePreviewRequestsRuntimeFetchWhenBodyIsAvailable() async throws {
        try await withLiveNetworkContext { fixture in
            let request = try #require(
                await applyRequest(
                    to: fixture.context,
                    requestID: "1",
                    url: "https://example.com/api/data.json",
                    responseHeaders: ["content-type": "application/json"],
                    responseMimeType: "application/json"
                )
            )
            let model = try await NetworkPanelModel.make(context: fixture.context)
            model.selectRequest(request)
            let viewController = makeNetworkDetailViewController(model: model)
            let window = showInWindow(viewController)
            defer { window.isHidden = true }
            await fixture.wire.fail(
                "Network.getResponseBody",
                message: "Intentional response-body failure."
            )
            viewController.setModeForTesting(.preview)

            let didFetch = await waitUntilRendered(in: viewController) {
                guard case .failed = request.responseBody.phase else {
                    return false
                }
                return viewController.currentModeForTesting == .preview
                    && viewController.currentPreviewRoleForTesting == .response
            }
            #expect(didFetch)
            #expect(await waitUntilRendered(in: viewController) {
                viewController.syntaxBodyViewControllerForTesting
                    .syntaxViewForTesting.text
                    .contains("Intentional response-body failure.")
            })
            #expect(fixture.wire.observations.commands.filter {
                $0.method == "Network.getResponseBody"
            }.count == 1)
        }
    }

    @Test
    func hiddenDetailDoesNotFetchResponseBodyUntilAppearingAgain() async throws {
        try await withLiveNetworkContext { fixture in
            let request = try #require(
                await applyRequest(
                    to: fixture.context,
                    requestID: "1",
                    url: "https://example.com/api/data.json",
                    responseHeaders: ["content-type": "application/json"],
                    responseMimeType: "application/json"
                )
            )
            let model = try await NetworkPanelModel.make(context: fixture.context)
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
            #expect(fixture.wire.observations.commands.contains {
                $0.method == "Network.getResponseBody"
            } == false)
            await fixture.wire.fail(
                "Network.getResponseBody",
                message: "Intentional response-body failure."
            )

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
            #expect(fixture.wire.observations.commands.filter {
                $0.method == "Network.getResponseBody"
            }.count == 1)
        }
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
        let model = try await NetworkPanelModel.make(context: context)
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
        let model = try await NetworkPanelModel.make(context: context)
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
        let model = try await NetworkPanelModel.make(context: context)
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
                url: playlistURL
            )
        ) { _ in
            Issue.record("HLS response preview should not require body payload preparation")
        }

        guard case .remoteMovie(let preview) = action else {
            Issue.record("Expected HLS response preview to use the remote playlist URL")
            return
        }
        #expect(preview.url.absoluteString == playlistURL)
        #expect(preview.bodyID == ObjectIdentifier(body))
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

        guard case .remoteMovie(let preview) = action else {
            Issue.record("Expected HLS response preview to use the remote playlist URL before the body loads")
            return
        }
        #expect(preview.url.absoluteString == playlistURL)
        #expect(preview.bodyID == ObjectIdentifier(body))
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
    func hlsPreviewShowsPlayerImmediately() async throws {
        let context = makeContext()
        let playlistURL = "https://media.example.com/live/master.m3u8"
        let request = try #require(await applyRequest(
            to: context,
            requestID: "playlist",
            url: playlistURL,
            responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
            responseMimeType: "application/vnd.apple.mpegurl",
            resourceType: .media
        ))
        applyResponseBody(to: context, request: request, body: "#EXTM3U")
        let model = try await NetworkPanelModel.make(context: context)
        model.selectRequest(request)
        let viewController = makeNetworkDetailViewController(model: model, initialMode: .preview)
        var playerCreationCount = 0
        viewController.syntaxBodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting { _ in
            playerCreationCount += 1
            return StubMoviePreviewPlayer()
        }
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didShowPlayer = await waitUntilRendered(in: viewController) {
            viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting?.absoluteString == playlistURL
        }
        #expect(didShowPlayer)
        #expect(playerCreationCount == 1)
    }

    @Test
    func hlsPlaybackFailureReplacesPlayerWithVisibleErrorAndTearsDownObservers() async throws {
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
                url: playlistURL
            )
        ))
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.resumeRendering()

        let item = try #require(viewController.mediaPlayerItemForTesting)
        #expect(viewController.mediaPlayerURLForTesting?.absoluteString == playlistURL)
        #expect(viewController.hasMoviePreviewObservationForTesting)
        let observation = try #require(viewController.previewRenderObservationDeliveryForTesting)
        let renderedFailure = await observation.values {
            viewController.mediaPlayerURLForTesting == nil
                && viewController.syntaxViewForTesting.text.contains("Simulated HLS playback failure.")
        }
        defer { renderedFailure.cancel() }

        NotificationCenter.default.post(
            name: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            userInfo: [
                AVPlayerItemFailedToPlayToEndTimeErrorKey: NSError(
                    domain: "WebInspectorUITests",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Simulated HLS playback failure.",
                    ]
                ),
            ]
        )

        #expect(await renderedFailure.waitUntil { $0 } != nil)
        #expect(viewController.hasMoviePreviewObservationForTesting == false)
        #expect(viewController.mediaPlayerItemForTesting == nil)
    }

    @Test
    func remoteHLSPreviewShowsPlayerWithoutFetchingResponseBody() async throws {
        try await withLiveNetworkContext { fixture in
            let playlistURL = "https://media.example.com/live/master.m3u8"
            let request = try #require(await applyRequest(
                to: fixture.context,
                requestID: "playlist",
                url: playlistURL,
                responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
                responseMimeType: "application/vnd.apple.mpegurl",
                resourceType: .media
            ))
            #expect(request.responseBody.phase == .available)
            let model = try await NetworkPanelModel.make(context: fixture.context)
            model.selectRequest(request)
            let viewController = makeNetworkDetailViewController(model: model, initialMode: .preview)
            var playerCreationCount = 0
            viewController.syntaxBodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting { _ in
                playerCreationCount += 1
                return StubMoviePreviewPlayer()
            }
            let window = showInWindow(viewController)
            defer { window.isHidden = true }

            let didShowPlayer = await waitUntilRendered(in: viewController) {
                viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting?.absoluteString
                    == playlistURL
            }

            #expect(didShowPlayer)
            #expect(playerCreationCount == 1)
            #expect(request.responseBody.phase == .available)
            #expect(fixture.wire.observations.commands.filter {
                $0.method == "Network.getResponseBody"
            }.isEmpty)
        }
    }

    @Test
    func unavailableMediaResponseDoesNotStartPlaybackOrFetch() async throws {
        let inputs = [
            UnavailableMediaPreviewCase(
                name: "HLS HEAD",
                pathExtension: "m3u8",
                mimeType: "application/vnd.apple.mpegurl",
                method: "HEAD",
                status: 200,
                finishes: true
            ),
            UnavailableMediaPreviewCase(
                name: "HLS 204",
                pathExtension: "m3u8",
                mimeType: "application/vnd.apple.mpegurl",
                method: "GET",
                status: 204,
                finishes: true
            ),
            UnavailableMediaPreviewCase(
                name: "HLS 404",
                pathExtension: "m3u8",
                mimeType: "application/vnd.apple.mpegurl",
                method: "GET",
                status: 404,
                finishes: true
            ),
            UnavailableMediaPreviewCase(
                name: "HLS 206",
                pathExtension: "m3u8",
                mimeType: "application/vnd.apple.mpegurl",
                method: "GET",
                status: 206,
                finishes: true
            ),
            UnavailableMediaPreviewCase(
                name: "MP4 HEAD",
                pathExtension: "mp4",
                mimeType: "video/mp4",
                method: "HEAD",
                status: 200,
                finishes: true
            ),
            UnavailableMediaPreviewCase(
                name: "MP4 204",
                pathExtension: "mp4",
                mimeType: "video/mp4",
                method: "GET",
                status: 204,
                finishes: true
            ),
            UnavailableMediaPreviewCase(
                name: "MP4 404",
                pathExtension: "mp4",
                mimeType: "video/mp4",
                method: "GET",
                status: 404,
                finishes: true
            ),
            UnavailableMediaPreviewCase(
                name: "MP4 206",
                pathExtension: "mp4",
                mimeType: "video/mp4",
                method: "GET",
                status: 206,
                finishes: true
            ),
            UnavailableMediaPreviewCase(
                name: "MP4 incomplete",
                pathExtension: "mp4",
                mimeType: "video/mp4",
                method: "GET",
                status: 200,
                finishes: false
            ),
        ]
        try await withLiveNetworkContext { fixture in
            for (index, input) in inputs.enumerated() {
                var responseHeaders = ["content-type": input.mimeType]
                if input.status == 206 {
                    responseHeaders["content-range"] = "bytes 0-99/1000"
                }
                let request = try #require(await applyRequest(
                    to: fixture.context,
                    requestID: "unavailable-media-\(index)",
                    url: "https://media.example.com/unavailable-\(index).\(input.pathExtension)",
                    responseHeaders: responseHeaders,
                    responseMimeType: input.mimeType,
                    responseStatus: input.status,
                    resourceType: .media,
                    method: input.method,
                    finishes: input.finishes
                ))
                let model = try await NetworkPanelModel.make(context: fixture.context)
                model.selectRequest(request)
                let viewController = makeNetworkDetailViewController(
                    model: model,
                    initialMode: .preview
                )
                var playerCreationCount = 0
                viewController.syntaxBodyViewControllerForTesting
                    .setMoviePreviewPlayerFactoryForTesting { _ in
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
                })
                #expect(viewController.previewRequestIDForTesting == request.id)
                #expect(
                    viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting == nil,
                    Comment(rawValue: input.name)
                )
                #expect(playerCreationCount == 0, Comment(rawValue: input.name))
                #expect(request.responseBody.phase == .available, Comment(rawValue: input.name))
                #expect(fixture.wire.observations.commands.filter {
                    $0.method == "Network.getResponseBody"
                }.isEmpty, Comment(rawValue: input.name))
            }
        }
    }

    @Test
    func nonMediaErrorResponseStillFetchesItsInspectableBody() async throws {
        try await withLiveNetworkContext { fixture in
            let request = try #require(await applyRequest(
                to: fixture.context,
                requestID: "error-json",
                url: "https://example.com/error.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json",
                responseStatus: 404,
                resourceType: .xhr
            ))
            let model = try await NetworkPanelModel.make(context: fixture.context)
            model.selectRequest(request)
            let viewController = makeNetworkDetailViewController(
                model: model,
                initialMode: .preview
            )
            let window = showInWindow(viewController)
            defer { window.isHidden = true }
            await fixture.wire.fail(
                "Network.getResponseBody",
                message: "Inspectable error body fetch reached the wire."
            )

            #expect(await waitUntilRendered(in: viewController) {
                guard case .failed = request.responseBody.phase else {
                    return false
                }
                return viewController.syntaxBodyViewControllerForTesting
                    .syntaxViewForTesting.text
                    .contains("Inspectable error body fetch reached the wire.")
            })
            #expect(fixture.wire.observations.commands.filter {
                $0.method == "Network.getResponseBody"
            }.count == 1)
        }
    }

    @Test
    func groupedPreviewFollowsNewerPlaylist() async throws {
        let context = makeContext()
        let nodeID = DOM.Node.ID("unplayed-video")
        let firstRequest = try #require(await applyRequest(
            to: context,
            requestID: "first-unplayed-playlist",
            url: "https://media.example.com/first-unplayed.m3u8",
            responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
            responseMimeType: "application/vnd.apple.mpegurl",
            resourceType: .media,
            timestamp: 1,
            initiatorNodeID: nodeID
        ))
        applyResponseBody(to: context, request: firstRequest, body: "#EXTM3U")
        let model = try await NetworkPanelModel.make(context: context)
        model.selectRequest(firstRequest)
        let viewController = makeNetworkDetailViewController(model: model, initialMode: .preview)
        viewController.syntaxBodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting { _ in
            StubMoviePreviewPlayer()
        }
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didShowFirstRequest = await waitUntilRendered(in: viewController) {
            viewController.previewRequestIDForTesting == firstRequest.id
                && viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting?.absoluteString
                    == "https://media.example.com/first-unplayed.m3u8"
        }
        #expect(didShowFirstRequest)

        let secondRequest = try #require(await applyRequest(
            to: context,
            requestID: "second-unplayed-playlist",
            url: "https://media.example.com/second-unplayed.m3u8",
            responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
            responseMimeType: "application/vnd.apple.mpegurl",
            resourceType: .media,
            timestamp: 2,
            initiatorNodeID: nodeID
        ))
        applyResponseBody(to: context, request: secondRequest, body: "#EXTM3U")

        let didFollowSecondRequest = await waitUntilRendered(in: viewController) {
            model.selectedRequests.count == 2
                && viewController.previewRequestIDForTesting == secondRequest.id
                && viewController.syntaxBodyViewControllerForTesting.mediaPlayerURLForTesting?.absoluteString
                    == "https://media.example.com/second-unplayed.m3u8"
        }
        #expect(didFollowSecondRequest)
    }

    @Test
    func groupedPreviewSkipsCancelledAndNoContentMediaForHealthyMember() async throws {
        let context = makeContext()
        let nodeID = DOM.Node.ID("healthy-media-candidate")
        let healthyRequest = try #require(await applyRequest(
            to: context,
            requestID: "healthy-playlist",
            url: "https://media.example.com/healthy.m3u8",
            responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
            responseMimeType: "application/vnd.apple.mpegurl",
            resourceType: .media,
            timestamp: 1,
            initiatorNodeID: nodeID
        ))
        let cancelledRequest = try #require(await applyRequest(
            to: context,
            requestID: "cancelled-playlist",
            url: "https://media.example.com/cancelled.m3u8",
            responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
            responseMimeType: "application/vnd.apple.mpegurl",
            resourceType: .media,
            timestamp: 2,
            initiatorNodeID: nodeID,
            finishes: false
        ))
        await applyLoadingFailed(
            to: context,
            requestID: "cancelled-playlist",
            errorText: "Cancelled",
            canceled: true,
            timestamp: 2.2
        )
        let noContentRequest = try #require(await applyRequest(
            to: context,
            requestID: "no-content-playlist",
            url: "https://media.example.com/no-content.m3u8",
            responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
            responseMimeType: "application/vnd.apple.mpegurl",
            responseStatus: 204,
            resourceType: .media,
            timestamp: 3,
            initiatorNodeID: nodeID
        ))
        let model = try await NetworkPanelModel.make(context: context)
        model.selectRequest(noContentRequest)
        let viewController = makeNetworkDetailViewController(model: model, initialMode: .preview)
        viewController.syntaxBodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting { _ in
            StubMoviePreviewPlayer()
        }
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(await waitUntilRendered(in: viewController) {
            model.selectedRequests.count == 3
                && viewController.previewRequestIDForTesting == healthyRequest.id
                && viewController.syntaxBodyViewControllerForTesting
                    .mediaPlayerURLForTesting?.absoluteString == "https://media.example.com/healthy.m3u8"
        })
        #expect(cancelledRequest.responseBody.phase == .failed(.loadingFailed(
            errorText: "Cancelled",
            canceled: true
        )))
    }

    @Test
    func groupedHLSPreviewReplacesPlayerForNewRequestWithSameURL() async throws {
        let context = makeContext()
        let nodeID = DOM.Node.ID("same-url-playlist")
        let playlistURL = "https://media.example.com/shared.m3u8"
        let firstRequest = try #require(await applyRequest(
            to: context,
            requestID: "first-shared-playlist",
            url: playlistURL,
            responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
            responseMimeType: "application/vnd.apple.mpegurl",
            resourceType: .media,
            timestamp: 1,
            initiatorNodeID: nodeID
        ))
        let model = try await NetworkPanelModel.make(context: context)
        model.selectRequest(firstRequest)
        let viewController = makeNetworkDetailViewController(model: model, initialMode: .preview)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        viewController.syntaxBodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer(for:)
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

        let secondRequest = try #require(await applyRequest(
            to: context,
            requestID: "second-shared-playlist",
            url: playlistURL,
            responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
            responseMimeType: "application/vnd.apple.mpegurl",
            resourceType: .media,
            timestamp: 2,
            initiatorNodeID: nodeID
        ))

        #expect(await waitUntilRendered(in: viewController) {
            viewController.previewRequestIDForTesting == secondRequest.id
                && playerFactory.players.count == 2
        })
        #expect(
            viewController.syntaxBodyViewControllerForTesting.mediaPlayerIdentityForTesting
                != firstPlayerID
        )
        let expectedPlaylistURL = try #require(URL(string: playlistURL))
        #expect(playerFactory.requestedURLs == [
            expectedPlaylistURL,
            expectedPlaylistURL,
        ])
    }

    @Test
    func filteredOutDetailSelectionRendersLaterMembersFromTheSameGroup() async throws {
        let context = makeContext()
        let nodeID = DOM.Node.ID("filtered-detail-video")
        let playlist = try #require(await applyRequest(
            to: context,
            requestID: "playlist",
            url: "https://media.example.com/master.m3u8",
            responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
            responseMimeType: "application/vnd.apple.mpegurl",
            resourceType: .media,
            timestamp: 1,
            initiatorNodeID: nodeID
        ))
        let model = try await NetworkPanelModel.make(context: context)
        model.selectRequest(playlist)
        let viewController = makeNetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        #expect(await waitUntilRendered(in: viewController) {
            viewController.headersTextViewForTesting.renderedTextForTesting.contains("master.m3u8")
        })

        model.setSearchText("does-not-match")
        await model.waitForQueryUpdates()
        #expect(model.requests.snapshot.sections.isEmpty)

        let segmentProxyID = Network.Request.ID("segment")
        await context.apply(.requestWillBeSent(
            id: segmentProxyID,
            request: Network.Request(
                id: segmentProxyID,
                url: "https://media.example.com/segment-1.ts",
                method: "GET"
            ),
            initiator: Network.Initiator(kind: "other", nodeID: nodeID),
            resourceType: .media,
            redirectResponse: nil,
            timestamp: 2
        ))
        _ = try #require(context.registeredRequest(forProxyID: segmentProxyID))

        let didRenderLaterMember = await waitUntilRendered(in: viewController) {
            let text = viewController.headersTextViewForTesting.renderedTextForTesting
            return model.selectedRequests.count == 2
                && text.contains("master.m3u8")
                && text.contains("segment-1.ts")
        }
        #expect(didRenderLaterMember)
        #expect(model.requests.snapshot.sections.isEmpty)
    }

    @Test
    func groupedPreviewUsesResponseEvidenceToSkipPartialMedia() async throws {
        let context = makeContext()
        let nodeID = DOM.Node.ID("audio")
        let fullRequest = try #require(await applyRequest(
            to: context,
            requestID: "full",
            url: "https://media.example.com/full.mp4",
            responseHeaders: ["content-type": "video/mp4"],
            responseMimeType: "video/mp4",
            resourceType: .media,
            timestamp: 1,
            initiatorNodeID: nodeID
        ))
        let partialRequest = try #require(await applyRequest(
            to: context,
            requestID: "partial",
            url: "https://media.example.com/partial.mp4",
            requestHeaders: ["range": "bytes=0-1023"],
            responseHeaders: [
                "content-type": "video/mp4",
                "content-range": "bytes 0-1023/4096",
            ],
            responseMimeType: "video/mp4",
            responseStatus: 206,
            resourceType: .media,
            timestamp: 3,
            initiatorNodeID: nodeID
        ))
        let ignoredRangeRequest = try #require(await applyRequest(
            to: context,
            requestID: "ignored-range",
            url: "https://media.example.com/ignored-range.mp4",
            requestHeaders: ["range": "bytes=0-1023"],
            responseHeaders: ["content-type": "video/mp4"],
            responseMimeType: "video/mp4",
            responseStatus: 200,
            resourceType: .media,
            timestamp: 2,
            initiatorNodeID: nodeID
        ))
        applyResponseBody(to: context, request: fullRequest, body: "AAAA", base64Encoded: true)
        applyResponseBody(to: context, request: ignoredRangeRequest, body: "AAAA", base64Encoded: true)
        applyResponseBody(to: context, request: partialRequest, body: "AAAA", base64Encoded: true)
        let model = try await NetworkPanelModel.make(context: context)
        model.selectRequest(partialRequest)
        let viewController = makeNetworkDetailViewController(model: model, initialMode: .preview)
        viewController.syntaxBodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting { _ in
            StubMoviePreviewPlayer()
        }
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didSelectCompleteResponse = await waitUntilRendered(in: viewController) {
            viewController.previewRequestIDForTesting == ignoredRangeRequest.id
        }
        #expect(didSelectCompleteResponse)
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
        let model = try await NetworkPanelModel.make(context: context)
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
            await applyRequest(
                to: context,
                requestID: "1",
                url: "https://media.example.com/download.php",
                responseHeaders: ["content-type": "video/mp4"],
                responseMimeType: "video/mp4"
            )
        )
        applyResponseBody(to: context, request: request, body: "not a real movie", base64Encoded: false)
        let model = try await NetworkPanelModel.make(context: context)
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
        #expect(playerFactory.requestedURLs == [temporaryFileURL])
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
        let model = try await NetworkPanelModel.make(context: context)
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
            await applyRequest(
                to: context,
                requestID: "1",
                url: "https://media.example.com/download.php",
                responseHeaders: ["content-type": "video/mp4"],
                responseMimeType: "video/mp4"
            )
        )
        applyResponseBody(to: context, request: request, body: "not a real movie", base64Encoded: false)
        let model = try await NetworkPanelModel.make(context: context)
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
            await applyRequest(
                to: context,
                requestID: "1",
                url: "https://media.example.com/download.php",
                responseHeaders: ["content-type": "video/mp4"],
                responseMimeType: "video/mp4"
            )
        )
        applyResponseBody(to: context, request: request, body: "not a real movie", base64Encoded: false)
        let model = try await NetworkPanelModel.make(context: context)
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
        let model = try await NetworkPanelModel.make(context: context)
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
        let model = try await NetworkPanelModel.make(context: context)
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
        let model = try await NetworkPanelModel.make(context: context)
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
        try await withLiveNetworkContext { fixture in
            let request = try #require(
                await applyRequest(
                    to: fixture.context,
                    requestID: "1",
                    url: "https://example.com/api/data.json",
                    responseHeaders: ["content-type": "application/json"],
                    responseMimeType: "application/json",
                    finishes: false
                )
            )
            let model = try await NetworkPanelModel.make(context: fixture.context)
            model.selectRequest(request)
            let viewController = makeNetworkDetailViewController(model: model)
            let window = showInWindow(viewController)
            defer { window.isHidden = true }
            viewController.setModeForTesting(.preview)

            #expect(request.responseBody.phase == .available)
            #expect(fixture.wire.observations.commands.contains {
                $0.method == "Network.getResponseBody"
            } == false)

            await fixture.wire.fail(
                "Network.getResponseBody",
                message: "Intentional response-body failure."
            )
            await applyLoadingFinished(to: fixture.context, requestID: "1", timestamp: 3)

            let didFetch = await waitUntilRendered(in: viewController) {
                guard case .failed = request.responseBody.phase else {
                    return false
                }
                return true
            }
            #expect(didFetch)
            #expect(fixture.wire.observations.commands.filter {
                $0.method == "Network.getResponseBody"
            }.count == 1)
        }
    }

    @Test
    func failedResponseBodyDoesNotRefetchFromRendering() async throws {
        try await withLiveNetworkContext { fixture in
            let request = try #require(
                await applyRequest(
                    to: fixture.context,
                    requestID: "1",
                    url: "https://example.com/api/data.json",
                    responseHeaders: ["content-type": "application/json"],
                    responseMimeType: "application/json"
                )
            )
            let model = try await NetworkPanelModel.make(context: fixture.context)
            await fixture.wire.fail(
                "Network.getResponseBody",
                message: "Intentional response-body failure."
            )
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
            #expect(fixture.wire.observations.commands.filter {
                $0.method == "Network.getResponseBody"
            }.count == 1)
        }
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
        let model = try await NetworkPanelModel.make(context: context)
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
        let model = try await NetworkPanelModel.make(context: context)
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
        let model = try await NetworkPanelModel.make(context: context)
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
        let model = try await NetworkPanelModel.make(context: context)
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
        let model = try await NetworkPanelModel.make(context: context)
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
        let model = try await NetworkPanelModel.make(context: context)
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
        let model = try await NetworkPanelModel.make(context: context)
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
        #expect(listViewController.displayedEntryIDsForTesting.count == 1)

        selectListItem(at: IndexPath(item: 0, section: 0), in: listViewController)
        let didPush = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers.last === detailViewController
        }
        #expect(didPush)
        await waitForNavigationTransitionToFinish(in: navigationController)

        let poppedViewController = await navigationController.popDetailFromUserNavigationForTesting()
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
        let model = try await NetworkPanelModel.make(context: context)
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

        let poppedViewController = await navigationController.popDetailFromUserNavigationForTesting {
            navigationController.syncStackForTesting()
        }

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
        let model = try await NetworkPanelModel.make(context: context)
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
        let model = try await NetworkPanelModel.make(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = makeNetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        model.selectRequest(firstRequest)
        navigationController.syncStackForTesting()

        let poppedViewController = await navigationController.popDetailFromUserNavigationForTesting {
            model.selectRequest(secondRequest)
            navigationController.syncStackForTesting()
        }

        #expect(poppedViewController === detailViewController)
        #expect(model.selectedRequest === secondRequest)
        #expect(navigationController.viewControllers == [listViewController, detailViewController])
    }

    @Test
    func compactUserPopDoesNotClearSameGroupSelectionFromANewerSourceEpoch() async throws {
        let context = makeContext()
        let nodeID = DOM.Node.ID("stable-media-node")
        let firstRequest = try #require(await applyRequest(
            to: context,
            requestID: "first",
            url: "https://media.example.com/first.ts",
            resourceType: .media,
            initiatorNodeID: nodeID
        ))
        let model = try await NetworkPanelModel.make(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = makeNetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        model.selectRequest(firstRequest)
        let oldToken = try #require(model.selectionToken)
        navigationController.syncStackForTesting()

        var capturedReplacementToken: NetworkPanelSelectionToken?
        let poppedViewController = await navigationController.popDetailFromUserNavigationForTesting {
            await context.clearNetworkRequests()
            guard let replacementRequest = await applyRequest(
                to: context,
                requestID: "replacement",
                url: "https://media.example.com/replacement.ts",
                resourceType: .media,
                timestamp: 2,
                initiatorNodeID: nodeID
            ) else {
                Issue.record("Expected a replacement request")
                return
            }
            model.selectRequest(replacementRequest)
            capturedReplacementToken = model.selectionToken
            navigationController.syncStackForTesting()
        }

        let replacementToken = try #require(capturedReplacementToken)
        #expect(poppedViewController === detailViewController)
        #expect(replacementToken.groupID == oldToken.groupID)
        #expect(replacementToken.sourceEpoch != oldToken.sourceEpoch)
        #expect(model.selectionToken == replacementToken)
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
        let model = try await NetworkPanelModel.make(context: context)
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

        model.selectRequest(nil)

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
        let request = try #require(await applyRequest(to: context, requestID: "1", url: "https://example.com/app.js"))
        let model = try await NetworkPanelModel.make(context: context)
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
        let selectionToken = try #require(model.selectionToken)
        let didPush = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers.last === detailViewController
        }
        #expect(didPush)
        await waitForNavigationTransitionToFinish(in: navigationController)

        await withUIKitAnimationsDisabled {
            await context.clearNetworkRequests()
        }
        #expect(model.selectionToken == selectionToken)
        #expect(model.selectedEntryID == nil)
        #expect(model.selectedRequest == nil)

        let didPop = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers == [listViewController]
        }
        #expect(didPop)
    }

    @Test
    func pendingListUpdatesKeepLatestTopologyAndUnionDirtyEntries() async throws {
        let model = try await NetworkPanelModel.make(context: makeContext())
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }
        await listViewController.flushPendingSnapshotUpdateForTesting()

        let first: WebInspectorFetchSectionID = "first"
        let second: WebInspectorFetchSectionID = "second"
        listViewController.beginSnapshotApplyForTesting()
        listViewController.queueSnapshotUpdateForTesting(
            entryIDs: [first],
            reconfigureEntryIDs: [first]
        )
        listViewController.queueSnapshotUpdateForTesting(
            entryIDs: [second],
            reconfigureEntryIDs: [first, second],
            requiresFullReconfigure: true
        )
        listViewController.queueSnapshotUpdateForTesting(
            entryIDs: [first],
            reconfigureEntryIDs: [first]
        )

        #expect(listViewController.pendingRowsForTesting == [first])
        #expect(listViewController.pendingReconfigureEntryIDsForTesting == [first, second])
        #expect(listViewController.pendingRequiresFullReconfigureForTesting)

        listViewController.finishSnapshotApplyForTesting()
        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedEntryIDsForTesting == [first])
        #expect(listViewController.displayedUIKitSectionCountForTesting == 1)
    }

    @Test
    func suspendedListKeepsPendingProjectionUntilResumeWithoutFullReload() async throws {
        let model = try await NetworkPanelModel.make(context: makeContext())
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }
        await listViewController.flushPendingSnapshotUpdateForTesting()

        let entryID: WebInspectorFetchSectionID = "pending"
        let evaluationCount = listViewController.entryIDsEvaluationCountForTesting
        listViewController.beginSnapshotApplyForTesting()
        listViewController.queueSnapshotUpdateForTesting(entryIDs: [entryID])
        listViewController.suspendRenderingForTesting()
        listViewController.finishSnapshotApplyForTesting()

        #expect(listViewController.hasPendingSnapshotUpdateForTesting)
        #expect(listViewController.entryIDsEvaluationCountForTesting == evaluationCount)

        listViewController.resumeRenderingForTesting()
        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedEntryIDsForTesting == [entryID])
        #expect(listViewController.entryIDsEvaluationCountForTesting == evaluationCount)
    }

    @Test
    func sectionReducerHandlesNontrivialMultipleMoveOrder() async throws {
        let model = try await NetworkPanelModel.make(context: makeContext())
        let listViewController = NetworkListViewController(model: model)
        let old: [WebInspectorFetchSectionID] = ["0", "1", "2", "3"]
        let new: [WebInspectorFetchSectionID] = ["2", "1", "3", "0"]

        let reduced = listViewController.reduceSectionChangesForTesting(
            oldEntryIDs: old,
            newEntryIDs: new,
            changes: [
                .move(sectionID: "2", from: 2, to: 0),
                .move(sectionID: "3", from: 3, to: 2),
                .move(sectionID: "0", from: 0, to: 3),
            ]
        )

        #expect(reduced == new)
    }

    @Test
    func sectionReducerHandlesInsertDeleteAndMultipleMovesTogether() async throws {
        let model = try await NetworkPanelModel.make(context: makeContext())
        let listViewController = NetworkListViewController(model: model)
        let old: [WebInspectorFetchSectionID] = ["0", "1", "2", "3"]
        let new: [WebInspectorFetchSectionID] = ["2", "4", "1", "0"]

        let reduced = listViewController.reduceSectionChangesForTesting(
            oldEntryIDs: old,
            newEntryIDs: new,
            changes: [
                .delete(sectionID: "3", index: 3),
                .insert(sectionID: "4", index: 1),
                .move(sectionID: "2", from: 2, to: 0),
                .move(sectionID: "1", from: 1, to: 2),
                .move(sectionID: "0", from: 0, to: 3),
            ]
        )

        #expect(reduced == new)
    }

    @Test
    func insertingSameGroupMemberReconfiguresOnlyItsSingleRow() async throws {
        let context = makeContext()
        let nodeID = DOM.Node.ID("video")
        let firstRequest = try #require(await applyRequest(
            to: context,
            requestID: "playlist",
            url: "https://media.example.com/master.m3u8",
            responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
            responseMimeType: "application/vnd.apple.mpegurl",
            resourceType: .media,
            timestamp: 1,
            initiatorNodeID: nodeID
        ))
        let model = try await NetworkPanelModel.make(context: context)
        let groupID = try #require(context.networkRequestGroupID(containing: firstRequest.id))
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }
        await listViewController.flushPendingSnapshotUpdateForTesting()

        #expect(listViewController.displayedEntryIDsForTesting == [groupID])
        #expect(listViewController.displayedUIKitSectionCountForTesting == 1)
        let evaluationCount = listViewController.entryIDsEvaluationCountForTesting
        let applyCount = listViewController.snapshotApplyCountForTesting
        let fetchedResultsRevision = model.requests.revision

        let segmentProxyID = Network.Request.ID("segment")
        await context.apply(.requestWillBeSent(
            id: segmentProxyID,
            request: Network.Request(
                id: segmentProxyID,
                url: "https://media.example.com/segment-1.ts",
                method: "GET"
            ),
            initiator: Network.Initiator(kind: "other", nodeID: nodeID),
            resourceType: .media,
            redirectResponse: nil,
            timestamp: 2
        ))
        _ = try #require(context.registeredRequest(forProxyID: segmentProxyID))

        #expect(await listViewController.waitForFetchedResultsRevisionForTesting(
            fetchedResultsRevision + 1
        ))
        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedEntryIDsForTesting == [groupID])
        #expect(listViewController.entryIDsEvaluationCountForTesting == evaluationCount)
        #expect(listViewController.snapshotApplyCountForTesting == applyCount + 1)
        #expect(listViewController.lastAppliedReconfigureEntryIDsForTesting == [groupID])

        listViewController.collectionViewForTesting.layoutIfNeeded()
        let cell = try #require(listViewController.networkListCellForTesting(
            at: IndexPath(item: 0, section: 0)
        ))
        #expect(cell.fileTypeLabelForTesting?.hasSuffix("×2") == true)
    }

    @Test
    func thousandMemberGroupUsesOneListRowAndRendersEveryDetailEntry() async throws {
        let context = makeContext()
        let nodeID = DOM.Node.ID("large-media-group")
        for index in 0..<1_000 {
            context.seedNetworkRequest(
                requestID: "segment-\(index)",
                url: "https://media.example.com/segment-\(index).ts",
                resourceTypeRawValue: "Media",
                responseMIMEType: "video/mp2t",
                responseStatus: 200,
                responseStatusText: "OK",
                initiator: Network.Initiator(kind: "other", nodeID: nodeID),
                timestamp: Double(index)
            )
        }
        let model = try await NetworkPanelModel.make(context: context)
        let groupID = try #require(model.requests.snapshot.sectionIDs.first)
        let listViewController = NetworkListViewController(model: model)
        let listWindow = showInWindow(listViewController, makeVisible: true)
        defer { listWindow.isHidden = true }
        await listViewController.flushPendingSnapshotUpdateForTesting()

        #expect(listViewController.displayedEntryIDsForTesting == [groupID])
        #expect(listViewController.displayedUIKitSectionCountForTesting == 1)
        listViewController.collectionViewForTesting.layoutIfNeeded()
        let cell = try #require(listViewController.networkListCellForTesting(
            at: IndexPath(item: 0, section: 0)
        ))
        #expect(cell.fileTypeLabelForTesting?.hasSuffix("×1000") == true)

        model.selectEntry(groupID)
        let detailViewController = makeNetworkDetailViewController(model: model)
        let detailWindow = showInWindow(detailViewController)
        defer { detailWindow.isHidden = true }
        let didRenderAllMembers = await waitUntilRendered(in: detailViewController) {
            let text = detailViewController.headersTextViewForTesting.renderedTextForTesting
            return model.selectedRequests.count == 1_000
                && text.contains("segment-0.ts")
                && text.contains("segment-999.ts")
        }
        #expect(didRenderAllMembers)
    }

    @Test
    func visibleListAppliesLiveInsertThroughFetchedResultsUpdates() async throws {
        let context = makeContext()
        let firstRequest = try #require(await applyRequest(
            to: context,
            requestID: "1",
            url: "https://example.com/first.js"
        ))
        let model = try await NetworkPanelModel.make(context: context)
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }

        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedEntryIDsForTesting == [try #require(context.networkRequestGroupID(containing: firstRequest.id))])

        let evaluationCountBeforeInsert = listViewController.entryIDsEvaluationCountForTesting
        let snapshotApplyCountBeforeInsert = listViewController.snapshotApplyCountForTesting
        let updateDeliveryCountBeforeInsert = listViewController.fetchedResultsUpdateDeliveryCountForTesting
        let secondProxyID = Network.Request.ID("2")
        await context.apply(.requestWillBeSent(
            id: secondProxyID,
            request: Network.Request(
                id: secondProxyID,
                url: "https://example.com/second.js",
                method: "GET"
            ),
            initiator: Network.Initiator(kind: "other"),
            resourceType: .script,
            redirectResponse: nil,
            timestamp: 2
        ))
        let secondRequest = try #require(context.registeredRequest(forProxyID: secondProxyID))
        let secondEntryID = try #require(context.networkRequestGroupID(containing: secondRequest.id))
        let firstEntryID = try #require(context.networkRequestGroupID(containing: firstRequest.id))

        let didRenderInsert = await waitUntilListShowsEntries(
            [secondEntryID, firstEntryID],
            in: listViewController,
            afterUpdateDeliveryCount: updateDeliveryCountBeforeInsert
        )
        #expect(didRenderInsert)
        #expect(listViewController.entryIDsEvaluationCountForTesting == evaluationCountBeforeInsert)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyCountBeforeInsert + 1)
    }

    @Test
    func visibleListAppliesDescriptorResetThroughFetchedResultsUpdates() async throws {
        let context = makeContext()
        _ = try #require(await applyRequest(
            to: context,
            requestID: "1",
            url: "https://media.example.com/clip.mp4",
            responseHeaders: ["content-type": "video/mp4"],
            responseMimeType: "video/mp4"
        ))
        let model = try await NetworkPanelModel.make(context: context)
        model.setResourceFilter(.media, enabled: true)
        await model.waitForQueryUpdates()
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }

        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedEntryIDsForTesting.count == 1)

        let evaluationCountBeforeUpdate = listViewController.entryIDsEvaluationCountForTesting
        let snapshotApplyCountBeforeUpdate = listViewController.snapshotApplyCountForTesting
        let updateDeliveryCountBeforeUpdate = listViewController.fetchedResultsUpdateDeliveryCountForTesting

        model.setSearchText("does-not-match")
        await model.waitForQueryUpdates()
        let didRenderReset = await waitUntilListShowsEntries(
            [],
            in: listViewController,
            afterUpdateDeliveryCount: updateDeliveryCountBeforeUpdate
        )

        #expect(didRenderReset)
        #expect(model.requests.snapshot.sectionIDs.isEmpty)
        #expect(listViewController.displayedEntryIDsForTesting.isEmpty)
        #expect(listViewController.entryIDsEvaluationCountForTesting == evaluationCountBeforeUpdate)
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
        let model = try await NetworkPanelModel.make(context: context)
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController)
        defer { window.isHidden = true }
        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedEntryIDsForTesting.count == 1)

        let evaluationCountBeforeHiddenUpdate = listViewController.entryIDsEvaluationCountForTesting
        let updateDeliveryCountBeforeHiddenUpdate = listViewController
            .fetchedResultsUpdateDeliveryCountForTesting

        listViewController.suspendRenderingForTesting()
        model.setSearchText("does-not-match")
        await model.waitForQueryUpdates()
        #expect(await listViewController.waitForFetchedResultsUpdateDeliveryForTesting(
            after: updateDeliveryCountBeforeHiddenUpdate
        ))

        #expect(listViewController.entryIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate)
        #expect(listViewController.displayedEntryIDsForTesting.count == 1)

        listViewController.resumeRenderingForTesting()
        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedEntryIDsForTesting.isEmpty)
        #expect(listViewController.entryIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate + 1)
    }

    @Test
    func hiddenListDefersQueuedSnapshotApplyUntilAppearingAgain() async throws {
        let context = makeContext()
        let request = try #require(await applyRequest(
            to: context,
            requestID: "1",
            url: "https://media.example.com/clip.mp4",
            responseHeaders: ["content-type": "video/mp4"],
            responseMimeType: "video/mp4"
        ))
        let model = try await NetworkPanelModel.make(context: context)
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController)
        defer { window.isHidden = true }
        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedEntryIDsForTesting == [try #require(context.networkRequestGroupID(containing: request.id))])

        let evaluationCountBeforeHiddenUpdate = listViewController.entryIDsEvaluationCountForTesting
        let updateDeliveryCountBeforeHiddenUpdate = listViewController
            .fetchedResultsUpdateDeliveryCountForTesting
        listViewController.beginSnapshotApplyForTesting()
        listViewController.queueSnapshotUpdateForTesting(entryIDs: [])
        #expect(listViewController.hasPendingSnapshotUpdateForTesting)

        listViewController.suspendRenderingForTesting()
        #expect(listViewController.hasPendingSnapshotUpdateForTesting)

        model.setSearchText("does-not-match")
        await model.waitForQueryUpdates()
        #expect(await listViewController.waitForFetchedResultsUpdateDeliveryForTesting(
            after: updateDeliveryCountBeforeHiddenUpdate
        ))
        #expect(listViewController.hasPendingSnapshotUpdateForTesting == false)
        listViewController.finishSnapshotApplyForTesting()
        await listViewController.flushPendingSnapshotUpdateForTesting()

        #expect(listViewController.entryIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate)
        #expect(listViewController.displayedEntryIDsForTesting == [try #require(context.networkRequestGroupID(containing: request.id))])

        listViewController.resumeRenderingForTesting()
        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedEntryIDsForTesting.isEmpty)
        #expect(listViewController.entryIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate + 1)
    }

    @Test
    func hiddenFilteredListReloadsOnceEvenWhenRowsRemainVisible() async throws {
        let context = makeContext()
        let request = try #require(await applyRequest(
            to: context,
            requestID: "1",
            url: "https://media.example.com/clip.mp4",
            responseHeaders: ["content-type": "video/mp4"],
            responseMimeType: "video/mp4"
        ))
        let model = try await NetworkPanelModel.make(context: context)
        model.setResourceFilter(.media, enabled: true)
        await model.waitForQueryUpdates()
        let listViewController = NetworkListViewController(model: model)
        listViewController.loadViewIfNeeded()
        listViewController.resumeRenderingForTesting()
        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedEntryIDsForTesting == [try #require(context.networkRequestGroupID(containing: request.id))])

        let evaluationCountBeforeHiddenUpdate = listViewController.entryIDsEvaluationCountForTesting
        let snapshotApplyCountBeforeHiddenUpdate = listViewController.snapshotApplyCountForTesting
        listViewController.suspendRenderingForTesting()
        await applyResponseReceived(
            to: context,
            requestID: "1",
            url: request.url,
            responseHeaders: [
                "content-type": "video/mp4",
                "x-hidden-update": "true",
            ],
            responseMimeType: "video/mp4",
            timestamp: 4
        )
        #expect(await listViewController.waitForFetchedResultsRevisionForTesting(
            model.requests.revision
        ))

        #expect(listViewController.entryIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyCountBeforeHiddenUpdate)
        #expect(listViewController.displayedEntryIDsForTesting == [try #require(context.networkRequestGroupID(containing: request.id))])

        listViewController.resumeRenderingForTesting()

        #expect(listViewController.entryIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate + 1)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyCountBeforeHiddenUpdate + 1)
        #expect(listViewController.displayedEntryIDsForTesting == [try #require(context.networkRequestGroupID(containing: request.id))])

        await listViewController.flushPendingSnapshotUpdateForTesting()

        #expect(listViewController.entryIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate + 1)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyCountBeforeHiddenUpdate + 1)
        #expect(listViewController.displayedEntryIDsForTesting == [try #require(context.networkRequestGroupID(containing: request.id))])
    }

    @Test
    func networkListCellRendersOnlyWhenConfigured() async throws {
        let context = makeContext()
        let request = try #require(await applyRequest(
            to: context,
            requestID: "1",
            url: "https://media.example.com/clip.mp4",
            responseHeaders: ["content-type": "video/mp4"],
            responseMimeType: "video/mp4"
        ))
        let cell = NetworkListCell(frame: CGRect(x: 0, y: 0, width: 390, height: 44))
        cell.configure(requests: [request])
        #expect(cell.fileTypeLabelForTesting == "mp4")

        await applyResponseReceived(
            to: context,
            requestID: "1",
            url: request.url,
            responseHeaders: ["content-type": "text/css"],
            responseMimeType: "text/css",
            timestamp: 4
        )

        #expect(cell.fileTypeLabelForTesting == "mp4")

        cell.configure(requests: [request])

        #expect(cell.fileTypeLabelForTesting == "css")
    }

    @Test
    func listControllerDeallocatesWhileFetchedResultsUpdateTaskIsActive() async throws {
        let model = try await NetworkPanelModel.make(context: makeContext())
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

    private func makeContext() -> WebInspectorModelContext {
        WebInspectorModelContext.preview()
    }

    private struct LiveNetworkContextFixture {
        let runtime: WebInspectorProxyTestRuntime
        let wire: WebInspectorRawWireDriver
        let context: WebInspectorModelContext
    }

    private func withLiveNetworkContext<Output>(
        _ operation: @MainActor (LiveNetworkContextFixture) async throws -> Output
    ) async throws -> Output {
        let runtime = try await WebInspectorProxyTestRuntime.start()
        let wire = WebInspectorRawWireDriver(peer: runtime.peer)
        await wire.start()
        await wire.respond(to: "Network.enable")
        let context = WebInspectorModelContext(
            configuration: .init(domains: [.network])
        )
        do {
            try await context.attach(to: runtime.proxy, isolation: MainActor.shared)
        } catch {
            await runtime.close()
            await wire.stop()
            throw error
        }

        let fixture = LiveNetworkContextFixture(
            runtime: runtime,
            wire: wire,
            context: context
        )
        let result: Result<Output, any Error>
        do {
            result = .success(try await operation(fixture))
        } catch {
            result = .failure(error)
        }

        await wire.respond(to: "Network.disable")
        await context.close()
        await runtime.close()
        await wire.stop()
        return try result.get()
    }

    private func applyRequest(
        to context: WebInspectorModelContext,
        requestID rawRequestID: String,
        url: String,
        requestHeaders: [String: String] = [:],
        postData: String? = nil,
        responseHeaders: [String: String] = ["content-type": "text/javascript"],
        responseMimeType: String = "text/javascript",
        responseStatus: Int = 200,
        resourceType: Network.ResourceType = .script,
        method: String? = nil,
        timestamp: Double = 1,
        initiatorNodeID: DOM.Node.ID? = nil,
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
                initiator: Network.Initiator(kind: "other", nodeID: initiatorNodeID),
                resourceType: resourceType,
                redirectResponse: nil,
                timestamp: timestamp
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
                timestamp: timestamp + 0.1
            )
        )
        if finishes {
            await context.apply(
                .loadingFinished(
                    id: requestID,
                    timestamp: timestamp + 0.2,
                    sourceMapURL: nil,
                    metrics: nil
                )
            )
        }
        return context.registeredRequest(forProxyID: requestID)
    }

    private func applyRequestWithoutResponse(
        to context: WebInspectorModelContext,
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
                initiator: Network.Initiator(kind: "other"),
                resourceType: .xhr,
                redirectResponse: nil,
                timestamp: 1
            )
        )
        return context.registeredRequest(forProxyID: requestID)
    }

    private func applyResponseReceived(
        to context: WebInspectorModelContext,
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

    private func applyLoadingFailed(
        to context: WebInspectorModelContext,
        requestID rawRequestID: String,
        errorText: String,
        canceled: Bool,
        timestamp: Double
    ) async {
        await context.apply(
            .loadingFailed(
                id: Network.Request.ID(rawRequestID),
                errorText: errorText,
                canceled: canceled,
                timestamp: timestamp
            )
        )
    }

    private func applyResponseBody(
        to context: WebInspectorModelContext,
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

    private func waitUntilListShowsEntries(
        _ entryIDs: [WebInspectorFetchSectionID],
        in viewController: NetworkListViewController,
        afterUpdateDeliveryCount updateDeliveryCount: Int
    ) async -> Bool {
        guard await viewController.waitForFetchedResultsUpdateDeliveryForTesting(
            after: updateDeliveryCount
        ) else {
            return false
        }
        await viewController.flushPendingSnapshotUpdateForTesting()
        return viewController.displayedEntryIDsForTesting == entryIDs
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

    private func withUIKitAnimationsDisabled<T>(_ body: () async -> T) async -> T {
        let wereAnimationsEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(wereAnimationsEnabled) }
        return await body()
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
#endif
