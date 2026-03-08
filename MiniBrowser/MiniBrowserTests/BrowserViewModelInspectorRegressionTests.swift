#if os(macOS)
import AppKit
import SwiftUI
import WebInspectorKit
import WebKit
import XCTest
@testable import MiniBrowser

@MainActor
final class BrowserViewModelInspectorRegressionTests: XCTestCase {
    private var retainedWindows: [NSWindow] = []
    private var retainedInspectors: [WIModel] = []
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        retainedInspectors.forEach { inspector in
            inspector.disconnect()
        }
        retainedInspectors.removeAll()

        retainedWindows.forEach { window in
            window.orderOut(nil)
            window.close()
        }
        retainedWindows.removeAll()

        NSApp.windows
            .filter { $0.title == "Web Inspector" }
            .forEach { window in
                window.orderOut(nil)
                window.close()
            }

        for directoryURL in temporaryDirectories {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        temporaryDirectories.removeAll()

        super.tearDown()
    }

    func testOpeningInspectorKeepsMainWebViewAliveAcrossFollowUpNavigation() async throws {
        let initialURL = try makeTemporaryHTMLURL(
            named: "initial",
            html: """
            <html>
                <body>
                    <main id="content">Initial Page</main>
                </body>
            </html>
            """
        )
        let followUpURL = try makeTemporaryHTMLURL(
            named: "followup",
            html: """
            <html>
                <body>
                    <main id="content">Follow Up Page</main>
                </body>
            </html>
            """
        )

        let model = BrowserViewModel(url: initialURL)
        let inspectorController = WIModel()
        retainedInspectors.append(inspectorController)
        let browserWindow = makeBrowserWindow(model: model)

        browserWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let initialLoadReady = await waitForCondition(description: "initial file load") {
            guard model.didFinishNavigationCount >= 1 else {
                return false
            }
            guard model.webContentTerminationCount == 0 else {
                return false
            }
            return await self.mainFrameText(in: model.webView) == "Initial Page"
        }
        XCTAssertTrue(initialLoadReady, "The initial page did not finish loading before the inspector opened.")

        presentInspectorWindow(
            model: model,
            inspectorController: inspectorController,
            tabs: [.dom(), .network()],
            parentWindow: browserWindow
        )

        let inspectorWindowAppeared = await waitForCondition(description: "inspector window") {
            NSApp.windows.contains { $0.title == "Web Inspector" && $0.isVisible }
        }
        XCTAssertTrue(inspectorWindowAppeared, "The inspector window did not appear.")

        let stayedAliveAfterAttach = await assertWebContentStaysAlive(model: model, duration: .seconds(2))
        XCTAssertTrue(
            stayedAliveAfterAttach,
            "The main WKWebView terminated immediately after opening the inspector. lastURL=\(model.lastWebContentTerminationURL?.absoluteString ?? "n/a")"
        )

        model.webView.load(URLRequest(url: followUpURL))
        let followUpLoaded = await waitForCondition(description: "follow-up navigation") {
            guard model.currentURL == followUpURL else {
                return false
            }
            guard model.didFinishNavigationCount >= 2 else {
                return false
            }
            guard model.webContentTerminationCount == 0 else {
                return false
            }
            return await self.mainFrameText(in: model.webView) == "Follow Up Page"
        }
        XCTAssertTrue(
            followUpLoaded,
            "The main WKWebView could not complete a follow-up navigation after opening the inspector."
        )
    }

    func testOpeningInspectorKeepsMainWebViewAliveAcrossCrossOriginHTTPSNavigation() async throws {
        let initialURL = try XCTUnwrap(URL(string: "https://example.com/"))
        let followUpURL = try XCTUnwrap(URL(string: "https://example.org/"))

        let model = BrowserViewModel(url: initialURL)
        let inspectorController = WIModel()
        retainedInspectors.append(inspectorController)
        let browserWindow = makeBrowserWindow(model: model)

        browserWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let initialLoadReady = await waitForCondition(description: "initial HTTPS load", attempts: 400) {
            guard model.didFinishNavigationCount >= 1 else {
                return false
            }
            guard model.webContentTerminationCount == 0 else {
                return false
            }
            guard model.currentURL?.host == "example.com" else {
                return false
            }
            return (await self.mainFrameText(in: model.webView))?.contains("Example Domain") == true
        }
        XCTAssertTrue(initialLoadReady, "The initial HTTPS page did not load before opening the inspector.")

        presentInspectorWindow(
            model: model,
            inspectorController: inspectorController,
            tabs: [.dom(), .network()],
            parentWindow: browserWindow
        )

        let inspectorWindowAppeared = await waitForCondition(description: "inspector window for cross-origin HTTPS test") {
            NSApp.windows.contains { $0.title == "Web Inspector" && $0.isVisible }
        }
        XCTAssertTrue(inspectorWindowAppeared, "The inspector window did not appear for the cross-origin HTTPS test.")

        let stayedAliveAfterAttach = await assertWebContentStaysAlive(model: model, duration: .seconds(2))
        XCTExpectFailure(
            "Known regression: opening the macOS native inspector on an HTTPS page can terminate the main WKWebView immediately after attach."
        )
        XCTAssertTrue(
            stayedAliveAfterAttach,
            "The main WKWebView terminated immediately after opening the inspector during the HTTPS test. lastURL=\(model.lastWebContentTerminationURL?.absoluteString ?? "n/a")"
        )
        guard stayedAliveAfterAttach else {
            return
        }

        model.webView.load(URLRequest(url: followUpURL))
        let followUpLoaded = await waitForCondition(description: "cross-origin HTTPS follow-up navigation", attempts: 400) {
            guard model.currentURL == followUpURL else {
                return false
            }
            guard model.didFinishNavigationCount >= 2 else {
                return false
            }
            guard model.webContentTerminationCount == 0 else {
                return false
            }
            return (await self.mainFrameText(in: model.webView))?.contains("Example Domain") == true
        }
        XCTAssertTrue(
            followUpLoaded,
            """
            The main WKWebView could not complete a cross-origin HTTPS navigation after opening the inspector.
            lastError=\(model.lastNavigationErrorDescription ?? "n/a")
            terminatedURL=\(model.lastWebContentTerminationURL?.absoluteString ?? "n/a")
            """
        )
    }

    func testOpeningDOMOnlyInspectorCharacterizesHTTPSAttachRegression() async throws {
        try await assertInspectorAttachBehaviorAcrossHTTPSNavigation(
            tabs: [.dom()],
            expectedFailureReason: "Known regression under investigation: DOM-only macOS inspector attach may still terminate the main WKWebView immediately after attach."
        )
    }

    func testOpeningNetworkOnlyInspectorCharacterizesHTTPSAttachRegression() async throws {
        try await assertInspectorAttachBehaviorAcrossHTTPSNavigation(
            tabs: [.network()],
            expectedFailureReason: "Known regression under investigation: Network-only macOS inspector attach may still terminate the main WKWebView immediately after attach."
        )
    }
}

@MainActor
private extension BrowserViewModelInspectorRegressionTests {
    func assertInspectorAttachBehaviorAcrossHTTPSNavigation(
        tabs: [WITab],
        expectedFailureReason: String
    ) async throws {
        let tabIdentifiers = tabs.map { $0.identifier }.joined(separator: ",")
        let initialURL = try XCTUnwrap(URL(string: "https://example.com/"))
        let followUpURL = try XCTUnwrap(URL(string: "https://example.org/"))

        let model = BrowserViewModel(url: initialURL)
        let inspectorController = WIModel()
        retainedInspectors.append(inspectorController)
        let browserWindow = makeBrowserWindow(model: model)

        browserWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let initialLoadReady = await waitForCondition(description: "initial HTTPS load for characterization", attempts: 400) {
            guard model.didFinishNavigationCount >= 1 else {
                return false
            }
            guard model.webContentTerminationCount == 0 else {
                return false
            }
            guard model.currentURL?.host == "example.com" else {
                return false
            }
            return (await self.mainFrameText(in: model.webView))?.contains("Example Domain") == true
        }
        XCTAssertTrue(initialLoadReady, "The initial HTTPS page did not load before opening the inspector.")

        presentInspectorWindow(
            model: model,
            inspectorController: inspectorController,
            tabs: tabs,
            parentWindow: browserWindow
        )

        let inspectorWindowAppeared = await waitForCondition(description: "inspector window for characterization") {
            NSApp.windows.contains { $0.title == "Web Inspector" && $0.isVisible }
        }
        XCTAssertTrue(inspectorWindowAppeared, "The inspector window did not appear for the characterization test.")

        let stayedAliveAfterAttach = await assertWebContentStaysAlive(model: model, duration: .seconds(2))
        XCTExpectFailure(expectedFailureReason, strict: false)
        XCTAssertTrue(
            stayedAliveAfterAttach,
            "The main WKWebView terminated immediately after opening the inspector. tabs=\(tabIdentifiers) lastURL=\(model.lastWebContentTerminationURL?.absoluteString ?? "n/a")"
        )
        guard stayedAliveAfterAttach else {
            return
        }

        model.webView.load(URLRequest(url: followUpURL))
        let followUpLoaded = await waitForCondition(description: "characterization follow-up navigation", attempts: 400) {
            guard model.currentURL == followUpURL else {
                return false
            }
            guard model.didFinishNavigationCount >= 2 else {
                return false
            }
            guard model.webContentTerminationCount == 0 else {
                return false
            }
            return (await self.mainFrameText(in: model.webView))?.contains("Example Domain") == true
        }
        XCTAssertTrue(
            followUpLoaded,
            """
            The main WKWebView could not complete a cross-origin HTTPS navigation after opening the inspector.
            tabs=\(tabIdentifiers)
            lastError=\(model.lastNavigationErrorDescription ?? "n/a")
            terminatedURL=\(model.lastWebContentTerminationURL?.absoluteString ?? "n/a")
            """
        )
    }

    func makeBrowserWindow(model: BrowserViewModel) -> NSWindow {
        let controller = NSHostingController(rootView: ContentWebView(model: model))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 1024, height: 768))
        window.styleMask = [.titled, .closable, .resizable]
        window.title = "MiniBrowser Test Host"
        retainedWindows.append(window)
        return window
    }

    func presentInspectorWindow(
        model: BrowserViewModel,
        inspectorController: WIModel,
        tabs: [WITab],
        parentWindow: NSWindow
    ) {
        let container = WITabViewController(
            inspectorController,
            webView: model.webView,
            tabs: tabs
        )
        let window = NSWindow(contentViewController: container)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Web Inspector"
        window.setContentSize(NSSize(width: 960, height: 720))
        window.minSize = NSSize(width: 640, height: 480)

        let parentFrame = parentWindow.frame
        let origin = NSPoint(
            x: parentFrame.midX - (window.frame.width / 2),
            y: parentFrame.midY - (window.frame.height / 2)
        )
        window.setFrameOrigin(origin)
        retainedWindows.append(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func makeTemporaryHTMLURL(named name: String, html: String) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiniBrowserInspectorRegression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        temporaryDirectories.append(directoryURL)

        let fileURL = directoryURL.appendingPathComponent("\(name).html")
        try html.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    func waitForCondition(
        description: String,
        attempts: Int = 200,
        interval: Duration = .milliseconds(50),
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: interval)
        }
        XCTFail("Timed out while waiting for \(description).")
        return await condition()
    }

    func assertWebContentStaysAlive(
        model: BrowserViewModel,
        duration: Duration,
        pollInterval: Duration = .milliseconds(100)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + duration

        while clock.now < deadline {
            if model.webContentTerminationCount > 0 {
                return false
            }
            guard await mainFrameText(in: model.webView) != nil else {
                return false
            }
            try? await Task.sleep(for: pollInterval)
        }

        guard model.webContentTerminationCount == 0 else {
            return false
        }
        return await mainFrameText(in: model.webView) != nil
    }

    func mainFrameText(in webView: WKWebView) async -> String? {
        let rawValue = try? await webView.callAsyncJavaScript(
            "return document.getElementById('content')?.textContent ?? document.body?.textContent ?? null;",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        if let text = rawValue as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let number = rawValue as? NSNumber {
            return number.stringValue
        }
        return nil
    }
}
#endif
