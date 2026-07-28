import Darwin
import UIKit
import WebKit
@testable import WebInspectorProxyKit
import XCTest

#if os(iOS)
final class WebInspectorProxyKitIntegrationTests: XCTestCase {
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
            await initialPage.proxy.waitForEventSubscription(
                targetID: initialPage.id,
                route: initialPage.route,
                domain: .target
            )

            async let relaunch: Void = replacementDelegate.terminateProcessAndWaitForRelaunch(
                of: fixture.webView,
                loading: "<html><body><button>Inspect after relaunch</button></body></html>"
            )
            try await waitForTargetDestruction(
                targetID: initialPage.id,
                events: lifecycleEvents
            )
            try await relaunch

            guard let replacementPage = try await proxy.waitForCurrentPageReplacement(gracePeriod: nil) else {
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
    func testSecondNativeInspectorAttachmentFailsWithoutReplacingDelegate() async throws {
        let fixture = try HostedWebViewFixture()
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

private func waitForTargetDestruction(
    targetID: WebInspectorTarget.ID,
    events: AsyncStream<WebInspectorTargetLifecycleEvent>
) async throws {
    for await event in events {
        try Task.checkCancellation()
        if case .targetDestroyed(targetID) = event {
            return
        }
    }

    try Task.checkCancellation()
    throw WebContentProcessHarnessError.lifecycleEndedBeforeTargetDestruction
}

@MainActor
private final class HostedWebViewFixture {
    let webView: WKWebView

    private let navigationProbe: WebContentProcessNavigationProbe
    private let previousKeyWindow: UIWindow?
    private let window: UIWindow

    init() throws {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            throw WebContentProcessHarnessError.missingWindowScene
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
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
        try await navigationProbe.loadHTMLString(html, in: webView)
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
    case processIdentifierWasUnavailable
    case processTerminationFailed(Int32)
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

    func loadHTMLString(_ html: String, in webView: WKWebView) async throws {
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
                guard let navigation = webView.loadHTMLString(html, baseURL: nil) else {
                    continuation.resume(
                        throwing: WebContentProcessHarnessError.navigationWasNotCreated
                    )
                    return
                }
                navigationOperation = NavigationOperation(
                    navigation: navigation,
                    continuation: continuation
                )
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancelPendingOperation()
            }
        }
    }

    func terminateProcessAndWaitForRelaunch(
        of webView: WKWebView,
        loading html: String
    ) async throws {
        guard let processIdentifier =
                (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value,
              processIdentifier > 0 else {
            throw WebContentProcessHarnessError.processIdentifierWasUnavailable
        }

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
                relaunchOperation = RelaunchOperation(
                    didObserveTermination: false,
                    navigation: nil,
                    html: html,
                    continuation: continuation
                )
                guard kill(processIdentifier, SIGKILL) == 0 else {
                    relaunchOperation = nil
                    continuation.resume(
                        throwing: WebContentProcessHarnessError.processTerminationFailed(errno)
                    )
                    return
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancelPendingOperation()
            }
        }
    }

    func cancelPendingOperation() {
        let navigationContinuation = navigationOperation?.continuation
        navigationOperation = nil
        let relaunchContinuation = relaunchOperation?.continuation
        relaunchOperation = nil
        navigationContinuation?.resume(throwing: CancellationError())
        relaunchContinuation?.resume(throwing: CancellationError())
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
        if let operation = navigationOperation {
            navigationOperation = nil
            operation.continuation.resume(
                throwing: WebContentProcessHarnessError.processTerminatedWhileLoading
            )
            return
        }

        guard var operation = relaunchOperation else {
            return
        }
        guard operation.didObserveTermination == false else {
            relaunchOperation = nil
            operation.continuation.resume(
                throwing: WebContentProcessHarnessError.processTerminatedAgainBeforeRelaunch
            )
            return
        }
        operation.didObserveTermination = true
        guard let navigation = webView.loadHTMLString(operation.html, baseURL: nil) else {
            relaunchOperation = nil
            operation.continuation.resume(
                throwing: WebContentProcessHarnessError.relaunchNavigationWasNotCreated
            )
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
            operation.continuation.resume(with: result)
            return
        }

        guard let operation = relaunchOperation,
              let expectedNavigation = operation.navigation,
              expectedNavigation === navigation else {
            return
        }
        relaunchOperation = nil
        operation.continuation.resume(with: result)
    }
}
#endif
