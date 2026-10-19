import ObservationBridge
import UIKit
import WebKit
@testable import WebInspectorDataKit
import WebKitScreenTimeWorkaround
@testable import Monocly
@testable import WebInspectorProxyKit
import XCTest

#if os(iOS)
final class WebInspectorProxyKitIntegrationTests: XCTestCase {
    @MainActor
    private static let sharedAttachmentWebView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }()

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        if #available(iOS 26.1, *) {
            try ScreenTimeWorkaround.install()
        }
        try await PortableObservationTracking.prepare()
    }

    @MainActor
    func testLateInspectorAttachmentRestoresPageAndChildFrameResources() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("late-inspector-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        for (name, contents) in [
            "index.html": "<html><head><link rel='stylesheet' href='style.css'><script src='app.js'></script></head><body><iframe src='child.html'></iframe></body></html>",
            "style.css": "body { color: rgb(255, 0, 0); }",
            "other.html": "<html><body>Other page</body></html>",
            "app.js": "window.fixtureLoaded = true; addEventListener('message', e => { if (e.data === 'child-fixture-loaded') { window.childFixtureLoaded = true; window.webkit.messageHandlers.fixtureReady.postMessage(null); } });",
            "child.html": "<html><head><script src='child.js'></script></head><body>Child</body></html>",
            "child.js": "parent.postMessage('child-fixture-loaded', '*');"
        ] {
            try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let fixture = try HostedWebViewFixture()
        defer { fixture.cleanup() }
        let readiness = FixtureReadinessProbe()
        let contentController = fixture.webView.configuration.userContentController
        contentController.add(readiness, name: "fixtureReady")
        defer { contentController.removeScriptMessageHandler(forName: "fixtureReady") }
        try await fixture.loadFileURL(directory.appendingPathComponent("index.html"))
        try await withIntegrationTimeout("the child frame fixture to finish") {
            try await readiness.signal.value()
        }
        let loaded = try await fixture.webView.evaluateJavaScript("window.fixtureLoaded === true && window.childFixtureLoaded === true")
        XCTAssertEqual(loaded as? Bool, true)

        let container = try await WebInspectorContainer(attachingTo: fixture.webView)
        do {
            let context = container.mainContext
            try await waitForUpdates(
                context.statusUpdates,
                description: "inspector startup"
            ) {
                switch context.state {
                case .attaching:
                    return false
                case .attached:
                    return true
                case .failed(let error):
                    throw error
                case .detached:
                    throw WebContentProcessHarnessError.contextDetached
                }
            }
            XCTAssertEqual(context.state, .attached)
            XCTAssertNil(context.networkResourceTreeError)
            let requests = context.network.fetchedResults().items
            for name in ["index.html", "style.css", "app.js", "child.html", "child.js"] {
                let url = directory.appendingPathComponent(name).absoluteString
                XCTAssertEqual(requests.filter { $0.url == url }.count, 1, "Missing or duplicated \(name)")
            }
            let stylesheet = try XCTUnwrap(requests.first { $0.url.hasSuffix("/style.css") })
            XCTAssertNil(stylesheet.requestSentTimestamp)
            XCTAssertNil(stylesheet.status)
            await stylesheet.fetchResponseBody()
            XCTAssertEqual(stylesheet.responseBody.phase, .loaded)
            let tree = context.rootTreeController()
            let documentUpdates = tree.updates
            let otherURL = directory.appendingPathComponent("other.html")
            try await fixture.loadFileURL(otherURL)
            try await waitForUpdates(documentUpdates, description: "the navigated DOM document") {
                let snapshot = tree.snapshot
                return snapshot.rootNodeID.flatMap { snapshot.node(for: $0)?.documentURL }
                    == otherURL.absoluteString
            }
            XCTAssertEqual(context.rootNode?.documentURL, otherURL.absoluteString)
            let networkResults = context.network.fetchedResults()
            let networkController = WebInspectorFetchedResultsController(fetchedResults: networkResults)
            let networkUpdates = networkController.transactions
            try await fixture.goBack()
            try await waitForUpdates(networkUpdates, description: "the restored stylesheet resource") {
                networkResults.items.contains {
                    $0 !== stylesheet && $0.url == stylesheet.url && $0.state == .finished
                }
            }
            let restored = try XCTUnwrap(networkResults.items.last { $0 !== stylesheet && $0.url == stylesheet.url })
            await restored.fetchResponseBody()
            XCTAssertEqual(restored.responseBody.phase, .loaded)
            await container.close()
        } catch {
            await container.close()
            throw error
        }
    }

    @MainActor
    func testSameDocumentHistoryNavigationSettlesWhileInspectorIsAttached() async throws {
        let documentURL = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID()).html")
        try "<html><body>History</body></html>".write(to: documentURL, atomically: true, encoding: .utf8)
        addTeardownBlock { try FileManager.default.removeItem(at: documentURL) }
        let tab = BrowserTab(url: documentURL, automaticallyLoadsInitialRequest: false)
        let fixture = try HostedWebViewFixture(webView: tab.webView)
        defer { fixture.cleanup() }
        try await fixture.loadFileURL(documentURL)
        tab.webView.navigationDelegate = tab
        let proxy = try await WebInspectorProxy(attachingTo: tab.webView)
        for name in ["_webView:navigation:didSameDocumentNavigation:", "_webView:backForwardListItemAdded:removed:"] {
            XCTAssertTrue(tab.webView.navigationDelegate?.responds(to: NSSelectorFromString(name)) == true)
        }
        do {
            let historyChanges = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let historyObservation = tab.webView.observe(\.canGoBack, options: [.initial, .new]) { _, change in
                if let canGoBack = change.newValue {
                    historyChanges.continuation.yield(canGoBack)
                }
            }
            defer {
                historyObservation.invalidate()
                historyChanges.continuation.finish()
            }
            _ = try await tab.webView.evaluateJavaScript("history.pushState({}, '', '#second')")
            try await waitForUpdates(historyChanges.stream, description: "same-document back history") {
                tab.webView.canGoBack
            }
            XCTAssertTrue(tab.webView.canGoBack)
            tab.goBack()
            XCTAssertTrue(tab.isShowingProgress)
            XCTAssertNil(tab.interactionStateData)

            let observation = withPortableContinuousObservation { _ in
                _ = tab.isShowingProgress
                _ = tab.interactionStateData
            }
            defer { observation.cancel() }
            let values = await observation.values {
                !tab.isShowingProgress && tab.interactionStateData != nil
            }
            defer { values.cancel() }
            guard await values.waitUntil(timeout: .seconds(10), { $0 }) != nil else {
                throw WebContentProcessHarnessError.timedOut("same-document navigation to settle")
            }
            XCTAssertFalse(tab.isShowingProgress)
            XCTAssertNotNil(tab.interactionStateData)
            XCTAssertNil(tab.webView.url?.fragment)
            await proxy.close()
        } catch {
            await proxy.close()
            throw error
        }
    }

    @MainActor
    func testNavigationContinuesAfterClientDelegateIsReleased() async throws {
        let fixture = try HostedWebViewFixture(webView: Self.sharedAttachmentWebView)
        defer { fixture.cleanup() }
        try await fixture.loadHTMLString("<html><body>Initial page</body></html>")

        let proxy = try await WebInspectorProxy(attachingTo: fixture.webView)
        weak var weakClient: NavigationPolicyProbe?
        autoreleasepool {
            let client = NavigationPolicyProbe()
            weakClient = client
            fixture.webView.navigationDelegate = client
            XCTAssertTrue(fixture.webView.navigationDelegate?.responds(to: NSSelectorFromString(
                "webView:decidePolicyForNavigationAction:decisionHandler:"
            )) == true)
            XCTAssertFalse(fixture.webView.navigationDelegate?.responds(to: NSSelectorFromString(
                "webView:decidePolicyForNavigationAction:preferences:decisionHandler:"
            )) == true)
        }
        XCTAssertNil(weakClient)

        let loaded = expectation(description: "Navigation finishes without a client delegate")
        let observation = fixture.webView.observe(\.title, options: [.new]) { _, change in
            if (change.newValue ?? nil) == "Released delegate" {
                loaded.fulfill()
            }
        }
        fixture.webView.loadHTMLString(
            "<html><head><title>Released delegate</title></head><body>Loaded</body></html>",
            baseURL: nil
        )
        await fulfillment(of: [loaded], timeout: 10)
        observation.invalidate()
        await proxy.close()
        XCTAssertNil(fixture.webView.navigationDelegate)
    }

    @MainActor
    func testClientPreferencesPolicyTakesPrecedenceOverLegacyPolicy() async throws {
        let fixture = try HostedWebViewFixture(webView: Self.sharedAttachmentWebView)
        defer { fixture.cleanup() }
        try await fixture.loadHTMLString("<html><body>Initial page</body></html>")
        let proxy = try await WebInspectorProxy(attachingTo: fixture.webView)
        let decided = expectation(description: "Client decides the navigation policy")
        let client = PreferencesNavigationPolicyProbe()
        client.didDecide = { decided.fulfill() }
        fixture.webView.navigationDelegate = client

        fixture.webView.loadHTMLString("<html><body>Cancelled page</body></html>", baseURL: nil)
        await fulfillment(of: [decided], timeout: 10)
        XCTAssertEqual(client.preferenceDecisionCount, 1)
        XCTAssertEqual(client.legacyDecisionCount, 0)

        await proxy.close()
        XCTAssertTrue(fixture.webView.navigationDelegate === client)
    }

    @MainActor
    func testNativeInspectablePageRestoresOriginalInspectability() {
        let webView = WKWebView(frame: .zero)
        webView.isInspectable = false

        let page = NativeInspectablePage(webView: webView)

        XCTAssertTrue(webView.isInspectable)

        page.restoreInspectabilityIfNeeded()

        XCTAssertFalse(webView.isInspectable)

        page.restoreInspectabilityIfNeeded()

        XCTAssertFalse(webView.isInspectable)
    }

    @MainActor
    func testNativeInspectorReconnectsAfterWebContentProcessTermination() async throws {
        let fixture = try HostedWebViewFixture()
        defer { fixture.cleanup() }

        try await fixture.loadHTMLString(
            "<html><body><button>Inspect</button></body></html>"
        )

        let proxy = try await WebInspectorProxy(attachingTo: fixture.webView)
        do {
            let initialPage = try await proxy.waitForCurrentPage()
            let initialDocument = try await initialPage.dom.getDocument()
            XCTAssertEqual(initialDocument.nodeName, "#document")

            let replacementDelegate = WebContentProcessNavigationProbe()
            fixture.webView.navigationDelegate = replacementDelegate
            let lifecycleEvents = initialPage.lifecycleEvents
            try await withIntegrationTimeout("the lifecycle event subscription to register") {
                await initialPage.proxy.waitForEventSubscription(
                    targetID: initialPage.id,
                    route: initialPage.route,
                    domain: .target
                )
            }

            async let relaunch: Void = replacementDelegate.terminateProcessAndWaitForRelaunch(
                of: fixture.webView,
                loading: "<html><body><button>Inspect after relaunch</button></body></html>"
            )
            try await waitForTargetDestruction(
                targetID: initialPage.id,
                events: lifecycleEvents
            )
            try await relaunch

            guard let replacementPage = try await proxy.waitForCurrentPageReplacement(gracePeriod: .seconds(10)) else {
                throw WebContentProcessHarnessError.replacementPageWasUnavailable
            }
            let replacementDocument = try await replacementPage.dom.getDocument()
            XCTAssertEqual(replacementDocument.nodeName, "#document")
            try await replacementPage.dom.setInspectMode(enabled: true)
            try await replacementPage.dom.setInspectMode(enabled: false)

            await proxy.close()
            XCTAssertTrue(fixture.webView.navigationDelegate === replacementDelegate)
        } catch {
            await proxy.close()
            throw error
        }
    }

    @MainActor
    func testOverlappingNativeInspectablePagesRestoreOnlyAfterLastOwner() {
        let webView = WKWebView(frame: .zero)
        webView.isInspectable = false

        let firstPage = NativeInspectablePage(webView: webView)
        let secondPage = NativeInspectablePage(webView: webView)

        XCTAssertTrue(webView.isInspectable)

        secondPage.restoreInspectabilityIfNeeded()

        XCTAssertTrue(webView.isInspectable)

        firstPage.restoreInspectabilityIfNeeded()

        XCTAssertFalse(webView.isInspectable)
    }

    @MainActor
    func testSecondNativeInspectorAttachmentFailsWithoutReplacingDelegate() async throws {
        let fixture = try HostedWebViewFixture(webView: Self.sharedAttachmentWebView)
        defer { fixture.cleanup() }

        try await fixture.loadHTMLString(
            "<html><body>Shared delegate proxy</body></html>"
        )

        let firstProxy = try await WebInspectorProxy(attachingTo: fixture.webView)
        let replacementDelegate = WebContentProcessNavigationProbe()
        fixture.webView.navigationDelegate = replacementDelegate

        do {
            do {
                let unexpectedProxy = try await WebInspectorProxy(attachingTo: fixture.webView)
                await unexpectedProxy.close()
                XCTFail("Expected a second native inspector attachment to fail.")
            } catch {
                XCTAssertEqual(
                    error as? WebInspectorProxyError,
                    .attachFailed("This WKWebView already has an attached native inspector.")
                )
            }

            XCTAssertFalse(fixture.webView.navigationDelegate === replacementDelegate)
            let page = try await firstProxy.waitForCurrentPage()
            let document = try await page.dom.getDocument()
            XCTAssertEqual(document.nodeName, "#document")

            await firstProxy.close()
            XCTAssertTrue(fixture.webView.navigationDelegate === replacementDelegate)
        } catch {
            await firstProxy.close()
            throw error
        }
    }
}

@MainActor
private final class NavigationPolicyProbe: NSObject, WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(.allow)
    }
}

@MainActor
private final class PreferencesNavigationPolicyProbe: NSObject, WKNavigationDelegate {
    var legacyDecisionCount = 0
    var preferenceDecisionCount = 0
    var didDecide: (() -> Void)?

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        legacyDecisionCount += 1
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        preferenceDecisionCount += 1
        decisionHandler(.cancel, preferences)
        didDecide?()
    }
}

@MainActor
private func withIntegrationTimeout(
    _ description: String,
    operation: @escaping @MainActor @Sendable () async throws -> Void
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        defer { group.cancelAll() }
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(10))
            throw WebContentProcessHarnessError.timedOut(description)
        }
        try await group.next()
    }
}

@MainActor
private func waitForUpdates<Event: Sendable>(
    _ updates: AsyncStream<Event>,
    description: String,
    until condition: @escaping @MainActor @Sendable () throws -> Bool
) async throws {
    try await withIntegrationTimeout(description) {
        if try condition() {
            return
        }
        for await _ in updates {
            try Task.checkCancellation()
            if try condition() {
                return
            }
        }
        try Task.checkCancellation()
        throw WebContentProcessHarnessError.updatesEnded(description)
    }
}

@MainActor
private func waitForTargetDestruction(
    targetID: WebInspectorTarget.ID,
    events: AsyncStream<WebInspectorTargetLifecycleEvent>
) async throws {
    try await withIntegrationTimeout("the original inspector target to be destroyed") {
        for await event in events {
            try Task.checkCancellation()
            if case .targetDestroyed(targetID) = event {
                return
            }
        }
        try Task.checkCancellation()
        throw WebContentProcessHarnessError.lifecycleEndedBeforeTargetDestruction
    }
}

@MainActor
private final class FixtureReadinessProbe: NSObject, WKScriptMessageHandler {
    let signal = ReplyPromise<Void>()

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        signal.fulfill(.success(()))
    }
}

@MainActor
private final class HostedWebViewFixture {
    let webView: WKWebView

    private let navigationProbe: WebContentProcessNavigationProbe
    private let previousKeyWindow: UIWindow?
    private let window: UIWindow

    init(webView suppliedWebView: WKWebView? = nil) throws {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            throw WebContentProcessHarnessError.missingWindowScene
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = suppliedWebView ?? WKWebView(frame: .zero, configuration: configuration)
        navigationProbe = WebContentProcessNavigationProbe()
        webView.navigationDelegate = navigationProbe
        previousKeyWindow = windowScene.windows.first { $0.isKeyWindow }

        let rootViewController = UIViewController()
        rootViewController.view.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: rootViewController.view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: rootViewController.view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: rootViewController.view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: rootViewController.view.bottomAnchor),
        ])

        window = UIWindow(windowScene: windowScene)
        window.frame = windowScene.coordinateSpace.bounds
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        rootViewController.loadViewIfNeeded()
        rootViewController.view.layoutIfNeeded()
        window.layoutIfNeeded()
    }

    func loadHTMLString(_ html: String) async throws {
        try await navigationProbe.load(in: webView) {
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func loadFileURL(_ url: URL) async throws {
        try await navigationProbe.load(in: webView) {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    func goBack() async throws {
        try await navigationProbe.load(in: webView) { webView.goBack() }
    }

    func cleanup() {
        navigationProbe.cancelPendingOperation()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }
}

private enum WebContentProcessHarnessError: Error {
    case missingWindowScene
    case navigationWasNotCreated
    case processTerminationIsUnsupported
    case timedOut(String)
    case updatesEnded(String)
    case contextDetached
    case processTerminatedWhileLoading
    case processTerminatedAgainBeforeRelaunch
    case relaunchNavigationWasNotCreated
    case lifecycleEndedBeforeTargetDestruction
    case replacementPageWasUnavailable
}

@MainActor
private final class WebContentProcessNavigationProbe: NSObject, WKNavigationDelegate {
    private struct NavigationOperation {
        let navigation: WKNavigation
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct RelaunchOperation {
        var didObserveTermination: Bool
        var navigation: WKNavigation?
        let html: String
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var navigationOperation: NavigationOperation?
    private var relaunchOperation: RelaunchOperation?
    private var timeoutTask: Task<Void, Never>?
    private var pendingOperationID: UUID?

    func load(in webView: WKWebView, _ startNavigation: () -> WKNavigation?) async throws {
        let operationID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard Task.isCancelled == false else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                precondition(
                    navigationOperation == nil && relaunchOperation == nil,
                    "A navigation probe can own only one operation at a time."
                )
                guard let navigation = startNavigation() else {
                    continuation.resume(
                        throwing: WebContentProcessHarnessError.navigationWasNotCreated
                    )
                    return
                }
                pendingOperationID = operationID
                navigationOperation = NavigationOperation(
                    navigation: navigation,
                    continuation: continuation
                )
                startTimeout(in: webView, operationID: operationID, description: "navigation to finish")
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancelPendingOperation(id: operationID)
            }
        }
    }

    func terminateProcessAndWaitForRelaunch(
        of webView: WKWebView,
        loading html: String
    ) async throws {
        // The AndResetState variant would also clear the page state under test.
        let terminateSelector = NSSelectorFromString("_killWebContentProcess")
        guard webView.responds(to: terminateSelector) else {
            throw WebContentProcessHarnessError.processTerminationIsUnsupported
        }
        let operationID = UUID()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard Task.isCancelled == false else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                precondition(
                    navigationOperation == nil && relaunchOperation == nil,
                    "A navigation probe can own only one operation at a time."
                )
                pendingOperationID = operationID
                relaunchOperation = RelaunchOperation(
                    didObserveTermination: false,
                    navigation: nil,
                    html: html,
                    continuation: continuation
                )
                startTimeout(in: webView, operationID: operationID, description: "WebContent process termination and relaunch")
                _ = unsafe webView.perform(terminateSelector)
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancelPendingOperation(id: operationID)
            }
        }
    }

    @discardableResult
    func cancelPendingOperation(id: UUID? = nil, error: any Error = CancellationError()) -> Bool {
        guard pendingOperationID != nil, id == nil || pendingOperationID == id else {
            return false
        }
        pendingOperationID = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        let navigationContinuation = navigationOperation?.continuation
        navigationOperation = nil
        let relaunchContinuation = relaunchOperation?.continuation
        relaunchOperation = nil
        navigationContinuation?.resume(throwing: error)
        relaunchContinuation?.resume(throwing: error)
        return true
    }

    private func startTimeout(in webView: WKWebView, operationID: UUID, description: String) {
        timeoutTask = Task { @MainActor [weak self, weak webView] in
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            guard self?.cancelPendingOperation(
                id: operationID,
                error: WebContentProcessHarnessError.timedOut(description)
            ) == true else {
                return
            }
            webView?.stopLoading()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(navigation: navigation, result: .success(()))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        finish(navigation: navigation, result: .failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        finish(navigation: navigation, result: .failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if navigationOperation != nil {
            cancelPendingOperation(error: WebContentProcessHarnessError.processTerminatedWhileLoading)
            return
        }

        guard var operation = relaunchOperation else {
            return
        }
        guard operation.didObserveTermination == false else {
            cancelPendingOperation(error: WebContentProcessHarnessError.processTerminatedAgainBeforeRelaunch)
            return
        }
        operation.didObserveTermination = true
        guard let navigation = webView.loadHTMLString(operation.html, baseURL: nil) else {
            cancelPendingOperation(error: WebContentProcessHarnessError.relaunchNavigationWasNotCreated)
            return
        }
        operation.navigation = navigation
        relaunchOperation = operation
    }

    private func finish(
        navigation: WKNavigation?,
        result: Result<Void, any Error>
    ) {
        if let operation = navigationOperation,
           operation.navigation === navigation {
            navigationOperation = nil
            pendingOperationID = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            operation.continuation.resume(with: result)
            return
        }

        guard let operation = relaunchOperation,
              let expectedNavigation = operation.navigation,
              expectedNavigation === navigation else {
            return
        }
        relaunchOperation = nil
        pendingOperationID = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        operation.continuation.resume(with: result)
    }
}
#endif
