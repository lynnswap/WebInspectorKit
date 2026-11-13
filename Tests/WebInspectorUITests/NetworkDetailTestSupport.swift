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

@MainActor
protocol NetworkDetailTestSupport {}

extension NetworkDetailTestSupport {
    func makeLiveNetworkDetailFixture() async throws -> (
        runtime: WebInspectorProxyTestRuntime,
        target: WebInspectorTarget,
        context: WebInspectorContext
    ) {
        let runtime = try await WebInspectorProxyTestRuntime.start()
        let target = try await runtime.proxy.waitForCurrentPage()
        await runtime.backend.enqueue((), for: "Inspector", method: "enable")
        await runtime.backend.enqueue((), for: "Inspector", method: "initialized")
        await runtime.backend.enqueue((), for: "Page", method: "enable")
        await runtime.backend.enqueue((), for: "Runtime", method: "enable")
        await runtime.backend.enqueue((), for: "Network", method: "enable")
        await runtime.backend.enqueue(
            DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document"),
            for: "DOM",
            method: "getDocument"
        )
        await runtime.backend.enqueue((), for: "Console", method: "enable")

        let container = WebInspectorContainer(proxy: runtime.proxy)
        let context = container.mainContext
        try await runtime.backend.waitForSubscribers(domain: "DOM", target: target, count: 1)
        try await runtime.backend.waitForSubscribers(domain: "Inspector", target: target, count: 1)
        try await runtime.backend.waitForSubscribers(domain: "CSS", target: target, count: 1)
        try await runtime.backend.waitForSubscribers(domain: "Network", target: target, count: 1)
        try await runtime.backend.waitForSubscribers(domain: "Console", target: target, count: 1)
        try await runtime.backend.waitForSubscribers(domain: "Runtime", target: target, count: 1)
        _ = await waitForObservedValue({ context.state }, until: { $0 != .attaching })
        #expect(context.state == .attached)
        return (runtime, target, context)
    }

    func responseBodyCommandRequestIDs(
        in backend: WebInspectorTestBackend
    ) async -> [Network.Request.ID?] {
        await backend.recordedCommands()
            .filter { $0.domain == "Network" && $0.method == "getResponseBody" }
            .map { $0.payload.cast(as: Network.GetResponseBodyPayload.self)?.id }
    }

    func makeContext() -> WebInspectorContext {
        WebInspectorContext.preview()
    }

    func selectEntry(
        containing request: NetworkRequest,
        in model: NetworkPanelModel
    ) throws {
        let entryID: NetworkListEntry.ID = try #require(
            model.entryID(containing: request.id)
        )
        model.selectEntry(try #require(model.entry(for: entryID)))
    }

    func installNavigationVisit(
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

    func applyGroupedPendingRequest(
        to context: WebInspectorContext,
        requestID rawRequestID: String,
        frameID: FrameID,
        initiatorNodeID: DOM.Node.ID,
        timestamp: Double
    ) async {
        let requestID = Network.Request.ID(rawRequestID)
        await context.apply(.requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "https://example.com/\(rawRequestID)",
                method: "GET",
                origin: Network.Request.Origin(
                    frameID: frameID,
                    loaderID: "loader",
                    targetID: "page"
                )
            ),
            initiator: Network.Initiator(kind: "script", nodeID: initiatorNodeID),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: timestamp
        ))
    }

    func applyGroupedRequest(
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

    func applyRequest(
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

    func applyRequestWithoutResponse(
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

    func applyWebSocket(
        to context: WebInspectorContext,
        requestID rawRequestID: String,
        url: String,
        requestTimestamp: Double? = 10,
        responseTimestamp: Double? = 11
    ) async throws -> NetworkRequest {
        let requestID = Network.Request.ID(rawRequestID)
        await context.apply(.webSocket(.created(id: requestID, url: url)))
        await context.apply(.webSocket(.handshakeRequest(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: url,
                method: "GET",
                headers: ["Upgrade": "websocket"]
            ),
            timestamp: requestTimestamp
        )))
        await context.apply(.webSocket(.handshakeResponse(
            id: requestID,
            response: Network.Response(
                url: url,
                status: 101,
                statusText: "Switching Protocols",
                headers: ["Upgrade": "websocket"]
            ),
            timestamp: responseTimestamp
        )))
        return try #require(context.registeredRequest(forProxyID: requestID))
    }

    func applyGroupedWebSocket(
        to context: WebInspectorContext,
        requestID rawRequestID: String,
        url: String,
        frameID: FrameID,
        initiatorNodeID: DOM.Node.ID,
        timestamp: Double
    ) async throws -> NetworkRequest {
        let requestID = Network.Request.ID(rawRequestID)
        await context.apply(.requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: url,
                method: "GET",
                headers: ["Upgrade": "websocket"],
                origin: Network.Request.Origin(
                    frameID: frameID,
                    loaderID: "loader",
                    targetID: "page"
                )
            ),
            initiator: Network.Initiator(kind: "script", nodeID: initiatorNodeID),
            resourceType: .webSocket,
            redirectResponse: nil,
            timestamp: timestamp
        ))
        await context.apply(.webSocket(.handshakeResponse(
            id: requestID,
            response: Network.Response(
                url: url,
                status: 101,
                statusText: "Switching Protocols",
                headers: ["Upgrade": "websocket"]
            ),
            timestamp: timestamp + 1
        )))
        return try #require(context.registeredRequest(forProxyID: requestID))
    }

    func applyResponseReceived(
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

    func applyDataReceived(
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

    func applyLoadingFinished(
        to context: WebInspectorContext,
        requestID rawRequestID: String,
        timestamp: Double,
        requestHeaders: [String: String]? = nil
    ) async {
        await context.apply(
            .loadingFinished(
                id: Network.Request.ID(rawRequestID),
                timestamp: timestamp,
                sourceMapURL: nil,
                metrics: requestHeaders.map {
                    Network.Metrics().reporting(requestHeaders: $0)
                }
            )
        )
    }

    func applyResponseBody(
        to context: WebInspectorContext,
        request: NetworkRequest,
        body: String,
        base64Encoded: Bool = false
    ) {
        context.seedResponseBody(for: request.id, body: body, base64Encoded: base64Encoded)
    }

    func renderCookies(
        _ sections: NetworkCookieSections,
        requestEpoch: NetworkCookiesViewController.RequestEpoch? = nil,
        in viewController: NetworkCookiesViewController
    ) async {
        let requestEpoch = requestEpoch
            ?? NetworkCookiesViewController.RequestEpoch.testing(viewController)
        await withCheckedContinuation { continuation in
            viewController.render(sections, requestEpoch: requestEpoch) {
                continuation.resume()
            }
        }
        viewController.collectionView.layoutIfNeeded()
    }

    func resumeWebSocketPreview(
        _ viewController: NetworkWebSocketPreviewViewController
    ) async {
        await withCheckedContinuation { continuation in
            viewController.setNextSnapshotApplyCompletionForTesting {
                continuation.resume()
            }
            viewController.resumeRendering()
        }
        viewController.collectionView.layoutIfNeeded()
    }

    func fireWebSocketRenderingFrame(
        _ frameScheduler: ManualNetworkFrameScheduler,
        in viewController: NetworkWebSocketPreviewViewController
    ) async {
        await withCheckedContinuation { continuation in
            viewController.setNextSnapshotApplyCompletionForTesting {
                continuation.resume()
            }
            frameScheduler.fireScheduledFrame()
        }
        viewController.collectionView.layoutIfNeeded()
    }

    func waitUntilWebSocketRenderingFrameScheduled(
        _ frameScheduler: ManualNetworkFrameScheduler,
        in viewController: NetworkWebSocketPreviewViewController
    ) async -> Bool {
        await waitForObservedCondition(
            deliveries: {
                [viewController.timelineObservationDeliveryForTesting].compactMap { $0 }
            },
            sample: {
                frameScheduler.hasScheduledFrame
            }
        )
    }

    func waitUntilWebSocketPreviewBound(
        to request: NetworkRequest,
        webSocket expectedWebSocket: WebSocketState? = nil,
        in viewController: NetworkDetailViewController
    ) async -> Bool {
        let webSocketPreview = viewController.webSocketPreviewViewControllerForTesting
        guard await waitUntilRendered(in: viewController, {
            guard webSocketPreview.boundRequestForTesting === request else {
                return false
            }
            guard let expectedWebSocket else {
                return true
            }
            return webSocketPreview.boundWebSocketForTesting === expectedWebSocket
        }) else {
            return false
        }
        await webSocketPreview.waitForTimelineObservationStartForTesting()
        webSocketPreview.collectionView.layoutIfNeeded()
        return webSocketPreview.boundRequestForTesting === request
            && webSocketPreview.timelineObservationDeliveryForTesting?.isActive == true
    }

    func requestCookieName(in viewController: NetworkDetailViewController) -> String? {
        requestCookieContent(in: viewController)?.fields.first?.value
    }

    func requestCookieValue(in viewController: NetworkDetailViewController) -> String? {
        guard let fields = requestCookieContent(in: viewController)?.fields,
              fields.indices.contains(1) else {
            return nil
        }
        return fields[1].value
    }

    func isRequestCookieItem(
        _ itemID: NetworkCookiesViewController.ItemID
    ) -> Bool {
        if case .requestCookie = itemID {
            return true
        }
        return false
    }

    func isResponseCookieItem(
        _ itemID: NetworkCookiesViewController.ItemID
    ) -> Bool {
        if case .responseCookie = itemID {
            return true
        }
        return false
    }

    func isCookieStateItem(
        _ itemID: NetworkCookiesViewController.ItemID,
        section: NetworkCookiesViewController.SectionID,
        kind: NetworkCookiesViewController.StateKind
    ) -> Bool {
        guard case let .state(_, itemSection, itemKind) = itemID else {
            return false
        }
        return itemSection == section && itemKind == kind
    }

    func requestCookieContent(
        in viewController: NetworkDetailViewController
    ) -> NetworkCookieRowContent? {
        let cookies = viewController.cookiesViewControllerForTesting
        guard let itemID = cookies.snapshotForTesting.itemIdentifiers(inSection: .request).first(where: {
            if case .requestCookie = $0 {
                return true
            }
            return false
        }) else {
            return nil
        }
        return cookies.cookieContentForTesting(itemID)
    }

    func selectMode(
        _ mode: NetworkDetailViewController.Mode,
        on viewController: NetworkDetailViewController
    ) {
        #expect(viewController.isDetailModeControlEnabledForTesting)
        viewController.selectModeForTesting(mode)
    }

    func selectPickerItem(
        at indexPath: IndexPath,
        in viewController: NetworkDetailRequestPickerViewController
    ) throws {
        let collectionView = try #require(viewController.collectionView)
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        collectionView.layoutIfNeeded()
        _ = try #require(
            collectionView.cellForItem(at: indexPath) as? NetworkDetailRequestPickerCell
        )
        collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        viewController.collectionView(collectionView, didSelectItemAt: indexPath)
    }

    func showInWindow(
        _ viewController: UIViewController,
        makeVisible: Bool = true,
        useUIKitVisibility: Bool = false
    ) -> UIWindow {
        let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window: UIWindow
        if useUIKitVisibility,
           let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else {
            window = UIWindow(frame: frame)
        }
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

    func activateNetworkRenderingForTesting(in viewController: UIViewController) {
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

    func pngBase64String(size: CGSize) -> String {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        .base64EncodedString()
    }

    func expectedImageFitScale(scrollView: UIScrollView, imageSize: CGSize) -> CGFloat {
        let visibleSize = imageVisibleBoundsSize(scrollView)
        return min(
            visibleSize.width / imageSize.width,
            visibleSize.height / imageSize.height
        )
    }

    func imageVisibleBoundsSize(_ scrollView: UIScrollView) -> CGSize {
        let adjustedInset = scrollView.adjustedContentInset
        return CGSize(
            width: max(scrollView.bounds.width - adjustedInset.left - adjustedInset.right, 0),
            height: max(scrollView.bounds.height - adjustedInset.top - adjustedInset.bottom, 0)
        )
    }

    func waitUntilRendered(
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

    func waitUntilPreparedTextPreviewRendered(
        in viewController: NetworkDetailViewController,
        _ condition: @escaping @MainActor @Sendable () -> Bool
    ) async -> Bool {
        if await waitUntilRendered(in: viewController, condition) {
            return true
        }
        await viewController.bodyViewControllerForTesting.waitUntilTextPreviewPreparationFinishedForTesting()
        return await waitUntilRendered(in: viewController, condition)
    }

    func waitUntilListShows(
        _ requestIDs: [NetworkRequest.ID],
        in viewController: NetworkListViewController,
        afterTransactionDeliveryCount transactionDeliveryCount: Int
    ) async -> Bool {
        guard await viewController.waitForListTransactionDeliveryForTesting(
            after: transactionDeliveryCount
        ) else {
            return false
        }
        await viewController.flushPendingSnapshotUpdateForTesting()
        return viewController.displayedRequestIDsForTesting == requestIDs
    }

    func waitUntilMediaPreviewPrepared(
        in viewController: NetworkDetailViewController
    ) async {
        await viewController.bodyViewControllerForTesting.waitUntilMediaPreviewPreparationFinishedForTesting()
        viewController.view.layoutIfNeeded()
    }

    func waitUntilNavigationStackSynced(
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

    func waitUntilNavigationStackSynced(
        in navigationController: UINavigationController,
        _ condition: @escaping @MainActor @Sendable () -> Bool
    ) async -> Bool {
        guard let compactNavigationController = navigationController as? NetworkCompactNavigationController else {
            return condition()
        }
        return await waitUntilNavigationStackSynced(in: compactNavigationController, condition)
    }

    func observationDeliveries(in viewController: NetworkDetailViewController) -> [PortableObservationTracking.Token] {
        var deliveries = [
            viewController.modelObservationDeliveryForTesting,
            viewController.selectedRequestRenderObservationDeliveryForTesting,
            viewController.responseBodyFetchObservationDeliveryForTesting,
            viewController.webSocketPreviewViewControllerForTesting
                .timelineObservationDeliveryForTesting,
        ].compactMap { $0 }
        let bodyViewController = viewController.bodyViewControllerForTesting
        deliveries.append(contentsOf: [
            bodyViewController.bodyObservationDeliveryForTesting,
            bodyViewController.previewRenderObservationDeliveryForTesting,
        ].compactMap { $0 })
        return deliveries
    }

    func sampleRenderedCondition(
        in viewController: NetworkDetailViewController,
        condition: @MainActor @Sendable () -> Bool
    ) -> Bool {
        viewController.view.layoutIfNeeded()
        return condition()
    }

    func waitForNavigationTransitionToFinish(in navigationController: UINavigationController) async {
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

    func withUIKitAnimationsDisabled<T>(_ body: () -> T) -> T {
        let wereAnimationsEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(wereAnimationsEnabled) }
        return body()
    }

    func localizedResourceString(_ key: String, locale: String) -> String? {
        guard let bundleURL = WebInspectorUILocalization.bundle.url(forResource: locale, withExtension: "lproj"),
              let bundle = Bundle(url: bundleURL) else {
            return nil
        }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    func localized(
        _ key: StaticString,
        defaultValue: String.LocalizationValue
    ) -> String {
        String(
            localized: key,
            defaultValue: defaultValue,
            bundle: WebInspectorUILocalization.bundle
        )
    }
}

@MainActor
final class MoviePreviewPlayerFactorySpy {
    private(set) var players: [StubMoviePreviewPlayer] = []

    func makePlayer() -> AVPlayer {
        let player = StubMoviePreviewPlayer()
        players.append(player)
        return player
    }
}

final class StubMoviePreviewPlayer: AVPlayer {
    private let pauseCounter = Mutex(0)

    var pauseCallCount: Int {
        pauseCounter.withLock { $0 }
    }

    override func pause() {
        pauseCounter.withLock { $0 += 1 }
    }
}

func makeNetworkListSnapshotBaseline(
    entryIDs: [NetworkListEntry.ID] = [],
    version: NetworkPanelListVersion = NetworkPanelListVersion(
        revision: 0,
        entryIdentityGeneration: 0
    ),
    generation: UInt64 = 0
) -> NetworkListSnapshotBaseline {
    NetworkListSnapshotBaseline(
        generation: generation,
        version: version,
        entryIDs: entryIDs
    )
}

func makeNetworkListSnapshotBuildInput(
    baseline: NetworkListSnapshotBaseline = makeNetworkListSnapshotBaseline(),
    target: NetworkPanelListProjection
) -> NetworkListSnapshotBuildInput {
    NetworkListSnapshotBuildInput(baseline: baseline, target: target)
}

actor NetworkListBuilderStartGate {
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
final class ManualNetworkFrameScheduler: NetworkFrameScheduling {
    private var pendingAction: (@MainActor () -> Void)?
    private(set) var scheduledFrameCount = 0
    private(set) var invalidationCount = 0

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
        invalidationCount += 1
        cancel()
    }

    func fireScheduledFrame() {
        guard let action = pendingAction else {
            preconditionFailure("Expected a scheduled Network rendering frame.")
        }
        pendingAction = nil
        action()
    }
}

@MainActor
final class ManualNetworkListSnapshotApplyCompletionScheduler:
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

struct BarrierNetworkListSnapshotBuilderFactory: NetworkListSnapshotBuilderMaking {
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

actor BarrierNetworkListSnapshotBuilder: NetworkListSnapshotBuilding {
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

actor BarrierNetworkListSnapshotBuildState {
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
