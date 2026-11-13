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
struct NetworkDetailHeadersModeTests: NetworkDetailTestSupport {
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
        let viewController = NetworkDetailViewController(model: model)
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
    func headersModeClearsSelectionWhenResponseSectionAppears() async throws {
        let context = makeContext()
        let request = try #require(await applyRequestWithoutResponse(
            to: context,
            requestID: "headers-response-selection",
            url: "https://example.com/pending"
        ))
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(await waitUntilRendered(in: viewController) {
            viewController.headersTextViewForTesting.renderedTextForTesting
                .contains("GET /pending")
        })
        viewController.headersTextViewForTesting.selectedRangeForTesting = NSRange(
            location: 2,
            length: 4
        )

        await applyResponseReceived(
            to: context,
            requestID: "headers-response-selection",
            url: request.url,
            responseHeaders: ["x-response": "inserted"],
            responseMimeType: "text/plain",
            timestamp: 2
        )

        #expect(await waitUntilRendered(in: viewController) {
            viewController.headersTextViewForTesting.renderedTextForTesting
                .contains("x-response: inserted")
        })
        #expect(
            viewController.headersTextViewForTesting.selectedRangeForTesting
                == NSRange(location: 0, length: 0)
        )
    }

    @Test
    func headersDocumentShowsOutcomeContextAndOrderedQueryAndFormParameters() async throws {
        let context = makeContext()
        let canceledID = Network.Request.ID("headers-context-canceled")
        let requestHeaders = ["Content-Type": "application/x-www-form-urlencoded"]
        let url = "https://example.com/submit?alpha=one&empty=&bad=%GG&alpha=two#ignored"
        await context.apply(
            .requestWillBeSent(
                id: canceledID,
                request: Network.Request(
                    id: canceledID,
                    url: url,
                    method: "POST",
                    headers: requestHeaders,
                    postData: "field=one&empty=&bad=%GG&field=two"
                ),
                initiator: Network.Initiator(
                    kind: "script",
                    url: "https://example.com/app.js",
                    line: 1,
                    nodeID: DOM.Node.ID("42", scopedToTargetRawValue: "page-target")
                ),
                resourceType: .xhr,
                redirectResponse: nil,
                timestamp: 1
            ))
        await context.apply(
            .responseReceived(
                id: canceledID,
                response: Network.Response(
                    url: url,
                    status: 200,
                    statusText: "OK",
                    mimeType: "application/json",
                    headers: ["content-type": "text/plain"],
                    source: Network.Source(rawValue: "network"),
                    requestHeaders: requestHeaders
                ),
                resourceType: .xhr,
                timestamp: 2
            ))
        await context.apply(
            .loadingFailed(
                id: canceledID,
                errorText: "The user canceled the upload",
                canceled: true,
                timestamp: 3
            ))
        let canceledRequest = try #require(context.registeredRequest(forProxyID: canceledID))

        let failedID = Network.Request.ID("headers-context-failed")
        await context.apply(
            .requestWillBeSent(
                id: failedID,
                request: Network.Request(
                    id: failedID,
                    url: "https://example.com/failure",
                    method: "GET"
                ),
                resourceType: .fetch,
                redirectResponse: nil,
                timestamp: 4
            ))
        await context.apply(
            .loadingFailed(
                id: failedID,
                errorText: "The connection was reset",
                canceled: false,
                timestamp: 5
            ))
        let failedRequest = try #require(context.registeredRequest(forProxyID: failedID))

        let model = NetworkPanelModel(context: context)
        model.selectRequest(canceledRequest)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let overviewTitle = String(
            localized: "network.detail.section.overview",
            bundle: WebInspectorUILocalization.bundle
        )
        let requestTitle = String(
            localized: "network.section.request",
            bundle: WebInspectorUILocalization.bundle
        )
        let responseTitle = String(
            localized: "network.section.response",
            bundle: WebInspectorUILocalization.bundle
        )
        let queryTitle = String(
            localized: "network.headers.section.query",
            defaultValue: "Query String Parameters",
            bundle: WebInspectorUILocalization.bundle
        )
        let requestDataTitle = String(
            localized: "network.headers.section.request_data",
            defaultValue: "Request Data",
            bundle: WebInspectorUILocalization.bundle
        )
        let outcomeLabel = String(
            localized: "network.headers.summary.outcome",
            defaultValue: "Outcome",
            bundle: WebInspectorUILocalization.bundle
        )
        let canceledValue = String(
            localized: "network.headers.summary.outcome.canceled",
            defaultValue: "Canceled",
            bundle: WebInspectorUILocalization.bundle
        )
        let failedValue = String(
            localized: "network.headers.summary.outcome.failed",
            defaultValue: "Failed",
            bundle: WebInspectorUILocalization.bundle
        )
        let failureReasonLabel = String(
            localized: "network.headers.summary.failure_reason",
            defaultValue: "Failure Reason",
            bundle: WebInspectorUILocalization.bundle
        )
        let resourceTypeLabel = String(
            localized: "network.headers.summary.resource_type",
            defaultValue: "Resource Type",
            bundle: WebInspectorUILocalization.bundle
        )
        let mimeTypeLabel = String(
            localized: "network.headers.summary.mime_type",
            defaultValue: "MIME Type",
            bundle: WebInspectorUILocalization.bundle
        )
        let initiatorKindLabel = String(
            localized: "network.headers.summary.initiator_kind",
            defaultValue: "Initiator Kind",
            bundle: WebInspectorUILocalization.bundle
        )
        let initiatorURLLabel = String(
            localized: "network.headers.summary.initiator_url",
            defaultValue: "Initiator URL",
            bundle: WebInspectorUILocalization.bundle
        )
        let initiatorLineLabel = String(
            localized: "network.headers.summary.initiator_line",
            defaultValue: "Initiator Line",
            bundle: WebInspectorUILocalization.bundle
        )
        let initiatorNodeLabel = String(
            localized: "network.headers.summary.initiator_node",
            defaultValue: "Initiator Node",
            bundle: WebInspectorUILocalization.bundle
        )

        #expect(
            await waitUntilRendered(in: viewController) {
                let text = viewController.headersTextViewForTesting.renderedTextForTesting
                return text.contains("\(outcomeLabel): \(canceledValue)")
                    && text.contains("\(failureReasonLabel): The user canceled the upload")
                    && text.contains("\(resourceTypeLabel): XHR")
                    && text.contains("\(mimeTypeLabel): application/json")
                    && text.contains("\(initiatorKindLabel): script")
                    && text.contains("\(initiatorURLLabel): https://example.com/app.js")
                    && text.contains("\(initiatorLineLabel): 1")
                    && text.contains("\(initiatorNodeLabel): 42")
                    && text.contains("page-target") == false
                    && text.contains("\u{1E}") == false
            })

        let text = viewController.headersTextViewForTesting.renderedTextForTesting
        let overviewRange = try #require(text.range(of: "\(overviewTitle)\n"))
        let requestRange = try #require(
            text.range(
                of: "\(requestTitle)\n",
                range: overviewRange.upperBound..<text.endIndex
            ))
        let responseRange = try #require(
            text.range(
                of: "\(responseTitle)\n",
                range: requestRange.upperBound..<text.endIndex
            ))
        let queryRange = try #require(
            text.range(
                of: "\(queryTitle)\n",
                range: responseRange.upperBound..<text.endIndex
            ))
        let requestDataRange = try #require(
            text.range(
                of: "\(requestDataTitle)\n",
                range: queryRange.upperBound..<text.endIndex
            ))
        #expect(overviewRange.lowerBound < requestRange.lowerBound)
        #expect(requestRange.lowerBound < responseRange.lowerBound)
        #expect(responseRange.lowerBound < queryRange.lowerBound)
        #expect(queryRange.lowerBound < requestDataRange.lowerBound)

        let queryText = String(text[queryRange.upperBound..<requestDataRange.lowerBound])
        let queryAlphaOne = try #require(queryText.range(of: "alpha: one"))
        let queryEmpty = try #require(
            queryText.range(
                of: "empty: ",
                range: queryAlphaOne.upperBound..<queryText.endIndex
            ))
        let queryMalformed = try #require(
            queryText.range(
                of: "bad=%GG",
                range: queryEmpty.upperBound..<queryText.endIndex
            ))
        let queryAlphaTwo = try #require(
            queryText.range(
                of: "alpha: two",
                range: queryMalformed.upperBound..<queryText.endIndex
            ))
        #expect(queryAlphaOne.lowerBound < queryEmpty.lowerBound)
        #expect(queryEmpty.lowerBound < queryMalformed.lowerBound)
        #expect(queryMalformed.lowerBound < queryAlphaTwo.lowerBound)
        #expect(queryText.contains("ignored") == false)

        let requestDataText = String(text[requestDataRange.upperBound...])
        let formOne = try #require(requestDataText.range(of: "field: one"))
        let formEmpty = try #require(
            requestDataText.range(
                of: "empty: ",
                range: formOne.upperBound..<requestDataText.endIndex
            ))
        let formMalformed = try #require(
            requestDataText.range(
                of: "bad=%GG",
                range: formEmpty.upperBound..<requestDataText.endIndex
            ))
        let formTwo = try #require(
            requestDataText.range(
                of: "field: two",
                range: formMalformed.upperBound..<requestDataText.endIndex
            ))
        #expect(formOne.lowerBound < formEmpty.lowerBound)
        #expect(formEmpty.lowerBound < formMalformed.lowerBound)
        #expect(formMalformed.lowerBound < formTwo.lowerBound)
        #expect(
            requestDataText.contains(
                String(
                    localized: "network.headers.parameters.error.percent_escape",
                    defaultValue: "Malformed percent escape",
                    bundle: WebInspectorUILocalization.bundle
                )))
        #expect(viewController.headersTextViewForTesting.requestPreviewTagRangesForTesting.isEmpty)

        model.selectRequest(failedRequest)
        #expect(
            await waitUntilRendered(in: viewController) {
                let text = viewController.headersTextViewForTesting.renderedTextForTesting
                return text.contains("\(outcomeLabel): \(failedValue)")
                    && text.contains("\(failureReasonLabel): The connection was reset")
                    && text.contains("\(outcomeLabel): \(canceledValue)") == false
            })
    }

    @Test
    func staleHeadersPreviewActionCannotPromoteAReplacementSelection() async throws {
        let context = makeContext()
        let first = try #require(await applyRequest(
            to: context,
            requestID: "headers-stale-action-first",
            url: "https://example.com/first",
            requestHeaders: ["Content-Type": "application/json"],
            postData: #"{"request":"first"}"#,
            finishes: false
        ))
        let second = try #require(await applyRequest(
            to: context,
            requestID: "headers-stale-action-second",
            url: "https://example.com/second",
            requestHeaders: ["Content-Type": "application/json"],
            postData: #"{"request":"second"}"#,
            finishes: false
        ))
        let model = NetworkPanelModel(context: context)
        model.selectRequest(first)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        #expect(await waitUntilRendered(in: viewController) {
            viewController.headersTextViewForTesting.requestPreviewTagRangesForTesting.count == 1
        })
        let staleAction = try #require(
            viewController.headersTextViewForTesting.captureRequestPreviewActionForTesting()
        )

        model.selectRequest(second)
        let replacementSubject = try #require(model.detailSubject)
        staleAction()

        #expect(model.detailSubject?.hasSameIdentity(as: replacementSubject) == true)
        #expect(model.detailSubject?.activeRequest === second)
        #expect(viewController.currentModeForTesting == .headers)
        #expect(await waitUntilRendered(in: viewController) {
            viewController.headersTextViewForTesting.renderedTextForTesting
                .contains("https://example.com/second")
        })
    }

    @Test
    func capturedHeadersActionKeepsTheExactRepresentativeShownByItsDocument() async throws {
        let context = makeContext()
        let frameID = FrameID("headers-captured-representative-frame")
        let nodeID = DOM.Node.ID("headers-captured-representative-node")
        installNavigationVisit(in: context, frameID: frameID)
        let originalRepresentative = try #require(await applyGroupedRequest(
            to: context,
            requestID: "headers-captured-representative",
            url: "https://example.com/original-representative",
            frameID: frameID,
            initiatorNodeID: nodeID,
            requestHeaders: ["Content-Type": "application/json"],
            postData: #"{"request":"original"}"#,
            timestamp: 10
        ))
        let model = NetworkPanelModel(context: context)
        try selectEntry(containing: originalRepresentative, in: model)
        let originalIntentID = try #require(model.detailSubject?.intentID)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        #expect(await waitUntilRendered(in: viewController) {
            viewController.headersTextViewForTesting.requestPreviewTagRangesForTesting.count == 1
        })
        let capturedAction = try #require(
            viewController.headersTextViewForTesting.captureRequestPreviewActionForTesting()
        )

        let transactionBaseline = model.rawTransactionDeliveryCountForTesting
        let newRepresentative = try #require(await applyGroupedRequest(
            to: context,
            requestID: "headers-new-representative",
            url: "https://example.com/new-representative",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 5
        ))
        #expect(await model.waitForRawTransactionDeliveryForTesting(after: transactionBaseline))
        #expect(model.detailSubject?.intentID == originalIntentID)
        #expect(model.detailSubject?.activeRequest === newRepresentative)

        capturedAction()

        #expect(model.detailSubject?.scope == .request)
        #expect(model.detailSubject?.activeRequest === originalRepresentative)
        #expect(viewController.currentModeForTesting == .preview)
        #expect(viewController.currentPreviewRoleForTesting == .request)
    }

    @Test
    func webSocketRequestDataNeverExposesBodyPreviewAction() async throws {
        let context = makeContext()
        let requestID = Network.Request.ID("headers-websocket-body")
        await context.apply(
            .webSocket(
                .created(
                    id: requestID,
                    url: "wss://example.com/socket"
                )))
        await context.apply(
            .webSocket(
                .handshakeRequest(
                    id: requestID,
                    request: Network.Request(
                        id: requestID,
                        url: "wss://example.com/socket",
                        method: "GET",
                        headers: [
                            "Content-Type": "application/json",
                            "Upgrade": "websocket",
                        ],
                        postData: #"{"websocket":"secret"}"#
                    ),
                    timestamp: 1
                )))
        let request = try #require(context.registeredRequest(forProxyID: requestID))
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let requestDataTitle = String(
            localized: "network.headers.section.request_data",
            defaultValue: "Request Data",
            bundle: WebInspectorUILocalization.bundle
        )
        #expect(
            await waitUntilRendered(in: viewController) {
                let headers = viewController.headersTextViewForTesting
                return headers.renderedTextForTesting.contains(requestDataTitle)
                    && headers.renderedTextForTesting.contains(#"{"websocket":"secret"}"#) == false
                    && headers.requestPreviewTagRangesForTesting.isEmpty
            })

        viewController.headersTextViewForTesting.activateRequestPreviewForTesting()
        #expect(viewController.currentModeForTesting == .headers)
        #expect(model.selectedRequest === request)
    }

    @Test
    func hiddenHeadersCatchUpRequestDataClassificationAndSelectionClearRemovesAction() async throws {
        let context = makeContext()
        let request = try #require(
            await applyRequest(
                to: context,
                requestID: "hidden-request-data",
                url: "https://example.com/submit",
                requestHeaders: ["Content-Type": "application/json"],
                postData: "field=value",
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json",
                finishes: false
            ))
        let body = try #require(request.requestBody)
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(
            await waitUntilRendered(in: viewController) {
                viewController.headersTextViewForTesting.requestPreviewTagRangesForTesting.count == 1
            })

        viewController.beginAppearanceTransition(false, animated: false)
        viewController.endAppearanceTransition()
        let transactionBaseline = model.rawTransactionDeliveryCountForTesting
        await applyLoadingFinished(
            to: context,
            requestID: "hidden-request-data",
            timestamp: 4,
            requestHeaders: ["Content-Type": "application/x-www-form-urlencoded"]
        )
        #expect(await model.waitForRawTransactionDeliveryForTesting(after: transactionBaseline))
        #expect(request.requestBody === body)
        #expect(viewController.headersTextViewForTesting.requestPreviewTagRangesForTesting.count == 1)
        viewController.headersTextViewForTesting.activateRequestPreviewForTesting()
        #expect(viewController.currentModeForTesting == .headers)
        #expect(model.selectedRequest === request)

        viewController.beginAppearanceTransition(true, animated: false)
        viewController.endAppearanceTransition()
        #expect(
            await waitUntilRendered(in: viewController) {
                viewController.headersTextViewForTesting.requestPreviewTagRangesForTesting.isEmpty
                    && viewController.headersTextViewForTesting.renderedTextForTesting
                        .contains("field: value")
            })
        #expect(request.requestBody === body)

        model.selectRequest(nil)
        #expect(
            await waitUntilRendered(in: viewController) {
                viewController.contentUnavailableConfiguration != nil
                    && viewController.headersTextViewForTesting.renderedTextForTesting.isEmpty
                    && viewController.headersTextViewForTesting.requestPreviewTagRangesForTesting.isEmpty
            })
    }

    @Test
    func headersRequestDataActionTargetsSameIDReregistrationAfterClearAndIgnoresClearedInstance() async throws {
        let context = makeContext()
        let original = try #require(
            await applyRequest(
                to: context,
                requestID: "headers-request-data-instance",
                url: "https://example.com/original",
                requestHeaders: ["Content-Type": "application/json"],
                postData: #"{"instance":"original"}"#,
                responseHeaders: ["content-type": "application/json"],
                responseMimeType: "application/json",
                finishes: false
            ))
        let model = NetworkPanelModel(context: context)
        model.selectRequest(original)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(
            await waitUntilRendered(in: viewController) {
                viewController.headersTextViewForTesting.requestPreviewTagRangesForTesting.count == 1
            })

        let proxyID = Network.Request.ID("headers-request-data-instance")
        let reregistrationTransactionBaseline = model.rawTransactionDeliveryCountForTesting
        context.clearNetworkRequests()
        let reregistered = try #require(
            await applyRequestWithoutResponse(
                to: context,
                requestID: "headers-request-data-instance",
                url: "https://example.com/reregistered",
                requestHeaders: [
                    "Content-Type": "application/json",
                    "content-type": "text/plain",
                ],
                postData: #"{"instance":"reregistered"}"#
            ))
        #expect(
            await model.waitForRawTransactionDeliveryForTesting(
                after: reregistrationTransactionBaseline + 1
            ))
        model.selectRequest(reregistered)
        let ambiguousContentTypeLabel = String(
            localized: "network.headers.request_data.content_type_ambiguous",
            defaultValue: "Ambiguous Content Type",
            bundle: WebInspectorUILocalization.bundle
        )

        #expect(
            await waitUntilRendered(in: viewController) {
                let text = viewController.headersTextViewForTesting.renderedTextForTesting
                return model.selectedRequest === reregistered
                    && text.contains("https://example.com/reregistered")
                    && text.contains("application/json")
                    && text.contains("text/plain")
                    && text.components(separatedBy: ambiguousContentTypeLabel).count == 2
                    && viewController.headersTextViewForTesting.requestPreviewTagRangesForTesting.count == 1
            })

        viewController.headersTextViewForTesting.activateRequestPreviewForTesting()
        let unavailable = String(
            localized: "network.body.unavailable",
            bundle: WebInspectorUILocalization.bundle
        )
        #expect(
            await waitUntilRendered(in: viewController) {
                viewController.currentModeForTesting == .preview
                    && model.selectedRequest === reregistered
                    && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text == unavailable
            })

        viewController.setModeForTesting(.headers)
        #expect(
            await waitUntilRendered(in: viewController) {
                viewController.currentModeForTesting == .headers
                    && viewController.headersTextViewForTesting.requestPreviewTagRangesForTesting.count == 1
            })

        original.applyRequestWillBeSent(
            request: Network.Request(
                id: proxyID,
                url: "https://example.com/stale",
                method: "POST",
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                postData: "stale=value"
            ),
            initiator: original.initiator,
            navigationVisit: original.navigationVisit,
            resourceType: original.resourceType,
            timestamp: 5,
            chronologySequence: 5
        )
        #expect(
            viewController.headersTextViewForTesting.renderedTextForTesting
                .contains("https://example.com/stale") == false)
        #expect(viewController.headersTextViewForTesting.requestPreviewTagRangesForTesting.count == 1)

        reregistered.applyRequestWillBeSent(
            request: Network.Request(
                id: proxyID,
                url: "https://example.com/current",
                method: "POST",
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                postData: "current=value"
            ),
            initiator: reregistered.initiator,
            navigationVisit: reregistered.navigationVisit,
            resourceType: reregistered.resourceType,
            timestamp: 6,
            chronologySequence: 6
        )
        #expect(
            await waitUntilRendered(in: viewController) {
                viewController.headersTextViewForTesting.renderedTextForTesting
                    .contains("https://example.com/current")
                    && viewController.headersTextViewForTesting.renderedTextForTesting
                        .contains("current: value")
                    && viewController.headersTextViewForTesting.requestPreviewTagRangesForTesting.isEmpty
            })
    }

    @Test
    func headersSemanticSignatureTracksKeyValueAttributeBoundaries() async throws {
        let context = makeContext()
        let request = try #require(
            await applyRequest(
                to: context,
                requestID: "headers-semantic-signature",
                url: "https://example.com/signature",
                responseHeaders: ["a: b": ""],
                responseMimeType: "text/plain",
                finishes: false
            ))
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(
            await waitUntilRendered(in: viewController) {
                viewController.headersTextViewForTesting.renderedTextForTesting.contains("a: b\n")
            })
        let renderedText = viewController.headersTextViewForTesting.renderedTextForTesting
        let assignmentCount = viewController.headersTextViewForTesting
            .attributedTextAssignmentCountForTesting

        await applyResponseReceived(
            to: context,
            requestID: "headers-semantic-signature",
            url: request.url,
            responseHeaders: ["a": "b"],
            responseMimeType: "text/plain",
            timestamp: 4
        )

        #expect(
            await waitUntilRendered(in: viewController) {
                viewController.headersTextViewForTesting.attributedTextAssignmentCountForTesting
                    == assignmentCount + 1
            })
        #expect(viewController.headersTextViewForTesting.renderedTextForTesting == renderedText)
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
        try selectEntry(containing: secondRequest, in: model)
        let viewController = NetworkDetailViewController(model: model)
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
        #expect(model.selectedEntryRequests.map(\.id) == [firstRequest.id, secondRequest.id])
    }

    @Test
    func explicitGroupedMemberHeadersRenderOnlyThatRequest() async throws {
        let context = makeContext()
        let frameID = FrameID("main-frame")
        let nodeID = DOM.Node.ID("explicit-headers")
        installNavigationVisit(in: context, frameID: frameID)
        let firstRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "first-explicit-header",
            url: "https://example.com/first-explicit.js",
            frameID: frameID,
            initiatorNodeID: nodeID,
            requestHeaders: ["x-member": "first"],
            timestamp: 1
        ))
        let secondRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "second-explicit-header",
            url: "https://example.com/second-explicit.js",
            frameID: frameID,
            initiatorNodeID: nodeID,
            requestHeaders: ["x-member": "second"],
            timestamp: 4
        ))
        let model = NetworkPanelModel(context: context)
        model.selectRequest(secondRequest)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(await waitUntilRendered(in: viewController) {
            let text = viewController.headersTextViewForTesting.renderedTextForTesting
            return viewController.previewRequestIDForTesting == secondRequest.id
                && text.contains("x-member: second")
                && text.contains("x-member: first") == false
        })
        #expect(model.selectedRequest === secondRequest)
        #expect(model.selectedRequest !== firstRequest)
    }
}
}
#endif
