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
struct NetworkDetailBodyPreviewTests: NetworkDetailTestSupport {
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
    func failedBodyPreparesUnavailableMessageOnlyOnce() {
        let viewController = NetworkBodyViewController()
        let body = NetworkBody(phase: .failed(.closed))
        viewController.loadViewIfNeeded()

        viewController.setSurface(.body(body, metadata: nil))
        viewController.resumeRendering()

        let unavailable = String(
            localized: "network.body.unavailable",
            bundle: WebInspectorUILocalization.bundle
        )
        #expect(viewController.syntaxViewForTesting.model.text == unavailable)
    }

    @Test
    func previewRequestWithoutBodyReplacesPreviousBodyWithEmptyPlaceholder() async throws {
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

        let emptyText = String(
            localized: "network.body.empty",
            defaultValue: "No Body",
            bundle: WebInspectorUILocalization.bundle
        )
        let didReplaceBody = await waitUntilRendered(in: viewController) {
            viewController.previewViewForTesting.isHidden == false
                && viewController.isPreviewRoleControlHiddenForTesting
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text == emptyText
        }
        #expect(didReplaceBody)
        #expect(viewController.bodyViewControllerForTesting.syntaxViewForTesting.text.contains("Jane") == false)
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
        let viewController = NetworkDetailViewController(model: model)
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
        let viewController = NetworkDetailViewController(model: model)
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
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text == "name=Jane Doe"
        }
        #expect(didRenderRequestPreview)

        model.selectRequest(responseOnlyRequest)

        let didRenderResponseOnly = await waitUntilRendered(in: viewController) {
            viewController.currentPreviewRoleForTesting == .response
                && viewController.logicalPreviewRoleForTesting == .request
                && viewController.isPreviewRoleControlHiddenForTesting
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text == "response only body"
        }
        #expect(didRenderResponseOnly)

        model.selectRequest(requestAndResponse)

        let didRestoreRequestPreview = await waitUntilRendered(in: viewController) {
            viewController.currentPreviewRoleForTesting == .request
                && viewController.logicalPreviewRoleForTesting == .request
                && viewController.isPreviewRoleControlHiddenForTesting == false
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text == "name=Jane Doe"
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

        let emptyText = String(
            localized: "network.body.empty",
            defaultValue: "No Body",
            bundle: WebInspectorUILocalization.bundle
        )
        let didRenderPlaceholder = await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .preview
                && viewController.previewViewForTesting.isHidden == false
                && viewController.isPreviewRoleControlHiddenForTesting
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text == emptyText
        }
        #expect(didRenderPlaceholder)
    }

    @Test
    func responsePreviewRequestsRuntimeFetchWhenBodyIsAvailable() async throws {
        let fixture = try await makeLiveNetworkDetailFixture()
        let request = try #require(
            await applyRequest(
                to: fixture.context,
                requestID: "preview-fetch",
                url: "https://example.com/api/data.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        await fixture.runtime.backend.enqueue(
            Network.Body(data: #"{"fetched":true}"#, base64Encoded: false),
            for: "Network",
            method: "getResponseBody"
        )
        let model = NetworkPanelModel(context: fixture.context)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        let didRenderFetchedBody = await waitUntilPreparedTextPreviewRendered(in: viewController) {
            viewController.currentModeForTesting == .preview
                && viewController.currentPreviewRoleForTesting == .response
                && viewController.bodyViewControllerForTesting
                    .syntaxViewForTesting.text.contains(#""fetched" : true"#)
        }
        #expect(didRenderFetchedBody)
        #expect(await responseBodyCommandRequestIDs(in: fixture.runtime.backend) == [request.proxyID])

        await fixture.runtime.backend.enqueue((), for: "Console", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Runtime", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Network", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Page", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Inspector", method: "disable")
        await fixture.context.stop()
        #expect(fixture.context.state == .detached)
    }

    @Test
    func hiddenDetailDoesNotFetchResponseBodyUntilAppearingAgain() async throws {
        let fixture = try await makeLiveNetworkDetailFixture()
        let request = try #require(
            await applyRequest(
                to: fixture.context,
                requestID: "hidden-fetch",
                url: "https://example.com/api/data.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        let model = NetworkPanelModel(context: fixture.context)
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
        #expect(request.responseBody.phase == .available)

        viewController.beginAppearanceTransition(false, animated: false)
        viewController.endAppearanceTransition()
        viewController.setModeForTesting(.preview)

        #expect(request.responseBody.phase == .available)
        #expect(viewController.fetchResponseBodyIfNeededForVisibleResponse(request) == false)
        #expect(viewController.headersTextViewForTesting.renderedTextForTesting.contains("content-type: application/json"))

        await fixture.runtime.backend.enqueue(
            Network.Body(data: #"{"returned":true}"#, base64Encoded: false),
            for: "Network",
            method: "getResponseBody"
        )
        viewController.beginAppearanceTransition(true, animated: false)
        viewController.endAppearanceTransition()

        let didRenderFetchedBodyOnReturn = await waitUntilPreparedTextPreviewRendered(in: viewController) {
            viewController.currentModeForTesting == .preview
                && viewController.currentPreviewRoleForTesting == .response
                && viewController.bodyViewControllerForTesting
                    .syntaxViewForTesting.text.contains(#""returned" : true"#)
        }
        #expect(didRenderFetchedBodyOnReturn)
        #expect(await responseBodyCommandRequestIDs(in: fixture.runtime.backend) == [request.proxyID])

        await fixture.runtime.backend.enqueue((), for: "Console", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Runtime", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Network", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Page", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Inspector", method: "disable")
        await fixture.context.stop()
        #expect(fixture.context.state == .detached)
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
        let viewController = NetworkDetailViewController(model: model, initialMode: .preview)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderVisibleBody = await waitUntilPreparedTextPreviewRendered(in: viewController) {
            viewController.bodyViewControllerForTesting.syntaxViewForTesting.text.contains(#""visible" : true"#)
        }
        #expect(didRenderVisibleBody)
        let renderedBodyBeforeHide = viewController.bodyViewControllerForTesting.syntaxViewForTesting.text

        viewController.beginAppearanceTransition(false, animated: false)
        viewController.endAppearanceTransition()
        applyResponseBody(to: context, request: request, body: #"{"hidden":true}"#, base64Encoded: false)

        #expect(viewController.bodyViewControllerForTesting.syntaxViewForTesting.text == renderedBodyBeforeHide)

        viewController.beginAppearanceTransition(true, animated: false)
        viewController.endAppearanceTransition()

        let didRenderHiddenBody = await waitUntilPreparedTextPreviewRendered(in: viewController) {
            viewController.bodyViewControllerForTesting.syntaxViewForTesting.text.contains(#""hidden" : true"#)
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
        let viewController = NetworkDetailViewController(model: model, initialMode: .preview)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderRawBody = await waitUntilRendered(in: viewController) {
            viewController.bodyViewControllerForTesting.syntaxViewForTesting.text == bodyText
        }
        #expect(didRenderRawBody)

        await viewController.bodyViewControllerForTesting.waitUntilTextPreviewPreparationFinishedForTesting()

        #expect(viewController.bodyViewControllerForTesting.syntaxViewForTesting.text == bodyText)
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
        let viewController = NetworkDetailViewController(model: model, initialMode: .preview)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderPrettyBody = await waitUntilPreparedTextPreviewRendered(in: viewController) {
            viewController.bodyViewControllerForTesting.syntaxViewForTesting.text == """
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
    func responsePreviewWaitsForLoadingFinishedBeforeFetching() async throws {
        let fixture = try await makeLiveNetworkDetailFixture()
        let request = try #require(
            await applyRequest(
                to: fixture.context,
                requestID: "finish-before-fetch",
                url: "https://example.com/api/data.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json",
                finishes: false
            )
        )
        let model = NetworkPanelModel(context: fixture.context)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        viewController.setModeForTesting(.preview)

        #expect(request.responseBody.phase == .available)
        #expect(viewController.fetchResponseBodyIfNeededForVisibleResponse(request) == false)

        await fixture.runtime.backend.enqueue(
            Network.Body(data: #"{"finished":true}"#, base64Encoded: false),
            for: "Network",
            method: "getResponseBody"
        )
        await applyLoadingFinished(to: fixture.context, requestID: "finish-before-fetch", timestamp: 3)

        let didRenderFetchedBody = await waitUntilPreparedTextPreviewRendered(in: viewController) {
            viewController.bodyViewControllerForTesting
                .syntaxViewForTesting.text.contains(#""finished" : true"#)
        }
        #expect(didRenderFetchedBody)
        #expect(await responseBodyCommandRequestIDs(in: fixture.runtime.backend) == [request.proxyID])

        await fixture.runtime.backend.enqueue((), for: "Console", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Runtime", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Network", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Page", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Inspector", method: "disable")
        await fixture.context.stop()
        #expect(fixture.context.state == .detached)
    }

    @Test
    func groupedPreviewFetchesTheVisibleNonRepresentativeResponseBody() async throws {
        let fixture = try await makeLiveNetworkDetailFixture()
        let frameID = FrameID("grouped-response-fetch-frame")
        let nodeID = DOM.Node.ID("grouped-response-fetch-node")
        installNavigationVisit(in: fixture.context, frameID: frameID)
        let representative = try #require(await applyGroupedRequest(
            to: fixture.context,
            requestID: "grouped-response-representative",
            url: "https://example.test/representative.json",
            frameID: frameID,
            initiatorNodeID: nodeID,
            responseHeaders: ["content-type": "application/json"],
            responseMIMEType: "application/json",
            resourceType: .xhr,
            timestamp: 1
        ))
        let visibleCandidate = try #require(await applyGroupedRequest(
            to: fixture.context,
            requestID: "grouped-response-visible-candidate",
            url: "https://example.test/visible.json",
            frameID: frameID,
            initiatorNodeID: nodeID,
            responseHeaders: ["content-type": "application/json"],
            responseMIMEType: "application/json",
            resourceType: .xhr,
            timestamp: 4
        ))
        await fixture.runtime.backend.enqueue(
            Network.Body(data: #"{"visible":true}"#, base64Encoded: false),
            for: "Network",
            method: "getResponseBody"
        )
        let model = NetworkPanelModel(context: fixture.context)
        try selectEntry(containing: visibleCandidate, in: model)
        let viewController = NetworkDetailViewController(
            model: model,
            initialMode: .preview
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(model.detailSubject?.activeRequest === representative)
        #expect(await waitUntilRendered(in: viewController) {
            viewController.previewRequestIDForTesting == visibleCandidate.id
        })
        let commands = await fixture.runtime.backend.waitForRecordedCommands(
            domain: "Network",
            method: "getResponseBody",
            count: 1
        )
        #expect(commands.count == 1)
        #expect(
            await waitForNetworkBodyPhase(in: visibleCandidate.responseBody) {
                $0 == .loaded
            } != nil
        )
        #expect(visibleCandidate.responseBody.text == #"{"visible":true}"#)
        #expect(representative.responseBody.phase == .available)
        #expect(await fixture.runtime.backend.recordedCommands().filter {
            $0.domain == "Network" && $0.method == "getResponseBody"
        }.count == 1)

        await fixture.runtime.backend.enqueue((), for: "Console", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Runtime", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Network", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Page", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Inspector", method: "disable")
        await fixture.context.stop()
        #expect(fixture.context.state == .detached)
    }

    @Test
    func supersededResponseObservationCannotFetchThePreviouslySelectedRequest() async throws {
        let fixture = try await makeLiveNetworkDetailFixture()
        let first = try #require(await applyRequest(
            to: fixture.context,
            requestID: "stale-fetch-first",
            url: "https://example.test/first.json",
            responseHeaders: ["content-type": "application/json"],
            responseMimeType: "application/json",
            finishes: false
        ))
        let second = try #require(await applyRequest(
            to: fixture.context,
            requestID: "stale-fetch-second",
            url: "https://example.test/second.json",
            responseHeaders: ["content-type": "application/json"],
            responseMimeType: "application/json",
            finishes: false
        ))
        let model = NetworkPanelModel(context: fixture.context)
        model.selectRequest(first)
        let viewController = NetworkDetailViewController(
            model: model,
            initialMode: .preview
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        #expect(await waitUntilRendered(in: viewController) {
            viewController.previewRequestIDForTesting == first.id
                && viewController.responseBodyFetchObservationDeliveryForTesting != nil
        })
        model.selectRequest(second)
        first.finish(timestamp: 3, sourceMapURL: nil, metrics: nil)
        #expect(viewController.fetchResponseBodyIfNeededForVisibleResponse(first) == false)

        #expect(await waitUntilRendered(in: viewController) {
            viewController.previewRequestIDForTesting == second.id
                && viewController.responseBodyFetchObservationDeliveryForTesting != nil
        })
        await fixture.runtime.backend.enqueue(
            Network.Body(data: #"{"current":true}"#, base64Encoded: false),
            for: "Network",
            method: "getResponseBody"
        )

        second.finish(timestamp: 4, sourceMapURL: nil, metrics: nil)
        viewController.fetchResponseBodyIfNeededForVisibleResponse(second)

        let responseBodyCommands = await fixture.runtime.backend.waitForRecordedCommands(
            domain: "Network",
            method: "getResponseBody",
            count: 1
        )
        #expect(responseBodyCommands.count == 1)
        #expect(await waitForNetworkBodyPhase(in: second.responseBody) { $0 == .loaded } != nil)
        await fixture.runtime.backend.enqueue((), for: "Console", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Runtime", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Network", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Page", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Inspector", method: "disable")
        await fixture.context.stop()
        #expect(fixture.context.state == .detached)
    }

    @Test
    func failedResponseBodyDoesNotRefetchFromRendering() async throws {
        let fixture = try await makeLiveNetworkDetailFixture()
        let request = try #require(
            await applyRequest(
                to: fixture.context,
                requestID: "failed-fetch",
                url: "https://example.com/api/data.json",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json"
            )
        )
        let fetchFailure = WebInspectorProxyError.commandFailed(
            domain: "Network",
            method: "getResponseBody",
            message: "Response body is unavailable."
        )
        await fixture.runtime.backend.enqueueFailure(
            fetchFailure,
            for: "Network",
            method: "getResponseBody"
        )
        let model = NetworkPanelModel(context: fixture.context)
        model.fetchResponseBodyIfNeeded(for: request)
        let initialPhase = await waitForNetworkBodyPhase(in: request.responseBody) { phase in
            if case .failed = phase {
                return true
            }
            return false
        }
        #expect(initialPhase == .failed(fetchFailure))
        #expect(await responseBodyCommandRequestIDs(in: fixture.runtime.backend) == [request.proxyID])

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

        #expect(model.fetchResponseBodyIfNeeded(for: request) == false)
        #expect(request.responseBody.phase == .failed(fetchFailure))

        await fixture.runtime.backend.enqueue((), for: "Console", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Runtime", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Network", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Page", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Inspector", method: "disable")
        await fixture.context.stop()
        #expect(fixture.context.state == .detached)
    }

    @Test
    func requestDataMetadataActionShowsUnavailablePreviewForOpaqueBody() async throws {
        let context = makeContext()
        let request = try #require(
            await applyRequest(
                to: context,
                requestID: "request-preview-action",
                url: "https://example.com/upload",
                requestHeaders: [
                    "Content-Type":
                        "multipart/form-data; boundary=\"A;=B\"; charset=utf-8; boundary=second; broken"
                ],
                postData: "raw-body-secret",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json",
                finishes: false
            ))
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let mediaTypeLabel = String(
            localized: "network.headers.request_data.media_type",
            defaultValue: "Media Type",
            bundle: WebInspectorUILocalization.bundle
        )
        let boundaryLabel = String(
            localized: "network.headers.request_data.boundary",
            defaultValue: "Boundary",
            bundle: WebInspectorUILocalization.bundle
        )
        let encodingLabel = String(
            localized: "network.headers.request_data.encoding",
            defaultValue: "Encoding",
            bundle: WebInspectorUILocalization.bundle
        )
        let unparsedContentTypeParameterLabel = String(
            localized: "network.headers.request_data.content_type_parameter_unparsed",
            defaultValue: "Unparsed Content-Type Parameters",
            bundle: WebInspectorUILocalization.bundle
        )

        #expect(
            await waitUntilRendered(in: viewController) {
                let headers = viewController.headersTextViewForTesting
                let text = headers.renderedTextForTesting
                return text.contains("\(mediaTypeLabel): multipart/form-data")
                    && text.contains("\(boundaryLabel): A;=B")
                    && text.contains("\(boundaryLabel): second")
                    && text.contains("\(encodingLabel): utf-8")
                    && text.contains("\(unparsedContentTypeParameterLabel):  broken")
                    && text.contains("raw-body-secret") == false
                    && headers.requestPreviewTagRangesForTesting.count == 1
            })

        let headers = viewController.headersTextViewForTesting
        let tagRange = try #require(headers.requestPreviewTagRangesForTesting.first)
        #expect(
            (headers.renderedTextForTesting as NSString).substring(with: tagRange)
                == String(
                    localized: "network.headers.request_data.view_preview.inline",
                    defaultValue: "View Preview",
                    bundle: WebInspectorUILocalization.bundle
                )
        )
        let selectedRange = NSRange(location: 4, length: 8)
        headers.selectedRangeForTesting = selectedRange
        let initialFontSize = try #require(headers.requestPreviewFontPointSizeForTesting)
        let initialAssignmentCount = headers.attributedTextAssignmentCountForTesting
        viewController.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        viewController.updateTraitsIfNeeded()
        headers.updateTraitsIfNeeded()
        headers.layoutIfNeeded()
        #expect(headers.attributedTextAssignmentCountForTesting > initialAssignmentCount)
        #expect(try #require(headers.requestPreviewFontPointSizeForTesting) > initialFontSize)
        #expect(headers.selectedRangeForTesting == selectedRange)

        headers.semanticContentAttribute = .forceLeftToRight
        headers.setNeedsLayout()
        headers.layoutIfNeeded()
        let leftToRightRuleX = try #require(headers.sectionRuleRectsForTesting.first).minX
        headers.semanticContentAttribute = .forceRightToLeft
        headers.setNeedsLayout()
        headers.layoutIfNeeded()
        let rightToLeftRuleX = try #require(headers.sectionRuleRectsForTesting.first).minX
        #expect(headers.effectiveLayoutDirectionForTesting == .rightToLeft)
        #expect(rightToLeftRuleX > leftToRightRuleX)

        headers.activateRequestPreviewForTesting()

        let unavailable = String(
            localized: "network.body.unavailable",
            bundle: WebInspectorUILocalization.bundle
        )
        #expect(
            await waitUntilRendered(in: viewController) {
                viewController.currentModeForTesting == .preview
                    && viewController.currentPreviewRoleForTesting == .request
                    && model.selectedRequest === request
                    && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text == unavailable
                    && viewController.responseBodyFetchObservationDeliveryForTesting == nil
            })
        #expect(request.requestBody?.full == "raw-body-secret")
        #expect(request.responseBody.phase == .available)
    }

    @Test
    func requestPreviewRoleDoesNotFetchResponseBodyAfterLoadingFinishes() async throws {
        let fixture = try await makeLiveNetworkDetailFixture()
        let context = fixture.context
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
                && viewController.responseBodyFetchObservationDeliveryForTesting == nil
        }
        #expect(didRenderRequestBody)

        await applyLoadingFinished(to: context, requestID: "1", timestamp: 3)

        let didStayOnRequestBody = await waitUntilRendered(in: viewController) {
            viewController.currentPreviewRoleForTesting == .request
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text == "name=Jane Doe"
                && viewController.responseBodyFetchObservationDeliveryForTesting == nil
        }
        #expect(didStayOnRequestBody)
        #expect(request.responseBody.phase == .available)
        #expect(await fixture.runtime.backend.recordedCommands().filter {
            $0.domain == "Network" && $0.method == "getResponseBody"
        }.isEmpty)

        await fixture.runtime.backend.enqueue((), for: "Console", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Runtime", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Network", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Page", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Inspector", method: "disable")
        await context.stop()
        #expect(context.state == .detached)
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
    func explicitGroupedMemberPreviewDoesNotJumpToAnotherMember() async throws {
        let context = makeContext()
        let frameID = FrameID("main-frame")
        let nodeID = DOM.Node.ID("explicit-preview")
        installNavigationVisit(in: context, frameID: frameID)
        let hlsRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "explicit-playlist",
            url: "https://media.example.com/live/explicit.m3u8",
            frameID: frameID,
            initiatorNodeID: nodeID,
            responseHeaders: ["content-type": "application/vnd.apple.mpegurl"],
            responseMIMEType: "application/vnd.apple.mpegurl",
            resourceType: .media,
            timestamp: 1
        ))
        let partialSegmentRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "explicit-partial-segment",
            url: "https://media.example.com/explicit-segment.mp4",
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
        let viewController = NetworkDetailViewController(model: model, initialMode: .preview)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(await waitUntilRendered(in: viewController) {
            viewController.previewRequestIDForTesting == partialSegmentRequest.id
                && viewController.previewViewForTesting.isHidden == false
        })
        #expect(model.selectedRequest === partialSegmentRequest)
        #expect(viewController.previewRequestIDForTesting != hlsRequest.id)
    }
}
}
#endif
