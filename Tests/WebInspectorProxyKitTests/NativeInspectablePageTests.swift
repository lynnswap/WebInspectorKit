#if canImport(UIKit)
import Darwin
import Testing
import UIKit
import WebKit
@testable import WebInspectorProxyKit

@MainActor
@Test
func nativeInspectablePageRestoresOriginalInspectability() {
    let webView = WKWebView(frame: .zero)
    webView.isInspectable = false

    let page = NativeInspectablePage(webView: webView)

    #expect(webView.isInspectable == true)

    page.restoreInspectabilityIfNeeded()

    #expect(webView.isInspectable == false)

    page.restoreInspectabilityIfNeeded()

    #expect(webView.isInspectable == false)
}

@MainActor
@Test
func overlappingNativeInspectablePagesRestoreOnlyAfterLastOwner() {
    let webView = WKWebView(frame: .zero)
    webView.isInspectable = false

    let firstPage = NativeInspectablePage(webView: webView)
    let secondPage = NativeInspectablePage(webView: webView)

    #expect(webView.isInspectable == true)

    secondPage.restoreInspectabilityIfNeeded()

    #expect(webView.isInspectable == true)

    firstPage.restoreInspectabilityIfNeeded()

    #expect(webView.isInspectable == false)
}

@MainActor
@Test
func nativeInspectablePageReloadFailsWhenWebViewIsUnavailable() {
    let page = NativeInspectablePage(missingWebViewForTesting: ())

    #expect(page.canReload == false)
    do {
        try page.reload()
        Issue.record("Expected reload to fail when the inspected WKWebView is unavailable.")
    } catch {
        #expect(String(describing: error) == "Inspected WKWebView is no longer available.")
    }
}

@MainActor
@Test
func nativeInspectorReconnectsAfterWebContentProcessTermination() async throws {
    let webView = WKWebView(frame: .zero)
    let navigationProbe = WebContentProcessNavigationProbe()
    webView.navigationDelegate = navigationProbe

    let initialNavigation = Task {
        await navigationProbe.waitForNextFinishedNavigation()
    }
    webView.loadHTMLString("<html><body><button>Inspect</button></body></html>", baseURL: nil)
    await initialNavigation.value

    let proxy = try await WebInspectorProxy(
        attachingTo: webView,
        configuration: .init(
            responseTimeout: .seconds(10),
            bootstrapTimeout: .seconds(10)
        )
    )
    do {
        let initialPage = try await proxy.waitForCurrentPage()
        _ = try await initialPage.dom.getDocument()

        let replacementNavigationProbe = WebContentProcessNavigationProbe()
        webView.navigationDelegate = replacementNavigationProbe
        let termination = Task {
            await replacementNavigationProbe.waitForNextProcessTermination()
        }
        let processIdentifier = try #require(
            (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value
        )
        #expect(kill(processIdentifier, SIGKILL) == 0)
        await termination.value

        let replacementTask = Task {
            try await proxy.waitForCurrentPageReplacement(gracePeriod: .seconds(10))
        }
        let replacementNavigation = Task {
            await replacementNavigationProbe.waitForNextFinishedNavigation()
        }
        webView.loadHTMLString(
            "<html><body><button>Inspect after relaunch</button></body></html>",
            baseURL: nil
        )
        await replacementNavigation.value

        let replacementPage = try #require(try await replacementTask.value)
        _ = try await replacementPage.dom.getDocument()
        try await replacementPage.dom.setInspectMode(enabled: true)
        await proxy.close()
        #expect(webView.navigationDelegate === replacementNavigationProbe)
    } catch {
        await proxy.close()
        throw error
    }
}

@MainActor
@Test
func secondNativeInspectorAttachmentFailsWithoutReplacingDelegate() async throws {
    let webView = WKWebView(frame: .zero)
    let initialNavigationProbe = WebContentProcessNavigationProbe()
    webView.navigationDelegate = initialNavigationProbe

    let initialNavigation = Task {
        await initialNavigationProbe.waitForNextFinishedNavigation()
    }
    webView.loadHTMLString("<html><body>Shared delegate proxy</body></html>", baseURL: nil)
    await initialNavigation.value

    let configuration = WebInspectorProxy.Configuration(
        responseTimeout: .seconds(10),
        bootstrapTimeout: .seconds(10)
    )
    let firstProxy = try await WebInspectorProxy(
        attachingTo: webView,
        configuration: configuration
    )
    let replacementNavigationProbe = WebContentProcessNavigationProbe()
    webView.navigationDelegate = replacementNavigationProbe

    do {
        let unexpectedProxy = try await WebInspectorProxy(
            attachingTo: webView,
            configuration: configuration
        )
        await unexpectedProxy.close()
        Issue.record("Expected a second native inspector attachment to fail.")
    } catch {
        #expect(
            error as? WebInspectorProxyError
                == .attachFailed("This WKWebView already has an attached native inspector.")
        )
    }

    #expect(webView.navigationDelegate !== replacementNavigationProbe)
    _ = try await firstProxy.waitForCurrentPage()
    await firstProxy.close()
    #expect(webView.navigationDelegate === replacementNavigationProbe)
}

@MainActor
private final class WebContentProcessNavigationProbe: NSObject, WKNavigationDelegate {
    private var finishedNavigationCount = 0
    private var consumedFinishedNavigationCount = 0
    private var finishedNavigationWaiters: [CheckedContinuation<Void, Never>] = []
    private var processTerminationCount = 0
    private var consumedProcessTerminationCount = 0
    private var processTerminationWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForNextFinishedNavigation() async {
        if consumedFinishedNavigationCount < finishedNavigationCount {
            consumedFinishedNavigationCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            finishedNavigationWaiters.append(continuation)
        }
    }

    func waitForNextProcessTermination() async {
        if consumedProcessTerminationCount < processTerminationCount {
            consumedProcessTerminationCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            processTerminationWaiters.append(continuation)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishedNavigationCount += 1
        if finishedNavigationWaiters.isEmpty == false {
            consumedFinishedNavigationCount += 1
            finishedNavigationWaiters.removeFirst().resume()
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        processTerminationCount += 1
        if processTerminationWaiters.isEmpty == false {
            consumedProcessTerminationCount += 1
            processTerminationWaiters.removeFirst().resume()
        }
    }
}
#endif
