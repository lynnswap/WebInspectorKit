#if os(macOS)
import AppKit
import WebInspectorKit
import WebKit
import XCTest
@testable import Monocly

final class BrowserStoreInspectorRegressionTests: XCTestCase {
    @MainActor
    private final class RetainedState {
        var windows: [NSWindow] = []
        var inspectors: [WIInspectorController] = []
        var temporaryDirectories: [URL] = []
    }

    private let retainedState = RetainedState()

    override func tearDown() {
        let retainedState = retainedState
        let performMainActorCleanup: @MainActor () async -> Void = {
            @MainActor
            func closeWindow(_ window: NSWindow) {
                window.orderOut(nil)
                window.toolbar = nil
                window.contentViewController = nil
                window.close()
            }

            @MainActor
            func drainMainRunLoop(cycles: Int = 5, interval: TimeInterval = 0.05) {
                for _ in 0..<cycles {
                    RunLoop.main.run(until: Date().addingTimeInterval(interval))
                }
            }

            let windowsToClose = retainedState.windows
            retainedState.windows.removeAll()
            let inspectorsToDisconnect = retainedState.inspectors
            retainedState.inspectors.removeAll()
            let directoriesToDelete = retainedState.temporaryDirectories
            retainedState.temporaryDirectories.removeAll()

            windowsToClose.forEach(closeWindow)

            NSApp.windows
                .filter { $0.title == "Web Inspector" }
                .forEach(closeWindow)

            for _ in 0..<10 {
                await Task.yield()
            }

            for inspector in inspectorsToDisconnect {
                await inspector.disconnect()
            }
            MonoclyWindowContextStore.shared.resetForTesting()
            drainMainRunLoop()
            for directoryURL in directoriesToDelete {
                try? FileManager.default.removeItem(at: directoryURL)
            }
        }

        let cleanupExpectation = XCTestExpectation(description: "run tearDown cleanup on MainActor")
        Task { @MainActor in
            await performMainActorCleanup()
            cleanupExpectation.fulfill()
        }
        let cleanupWaitResult = XCTWaiter().wait(for: [cleanupExpectation], timeout: 10)
        if cleanupWaitResult != .completed {
            XCTFail("Timed out while running MainActor tearDown cleanup.")
        }
        super.tearDown()
    }

    @MainActor
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

        let model = BrowserStore(url: initialURL)
        let inspectorController = WIInspectorController()
        retainedState.inspectors.append(inspectorController)
        let (browserWindow, _) = makeBrowserWindow(model: model, inspectorController: inspectorController)

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

    @MainActor
    func testOpeningInspectorKeepsMainWebViewAliveAcrossCrossOriginHTTPSNavigation() async throws {
        let initialURL = try XCTUnwrap(URL(string: "https://example.com/"))
        let followUpURL = try XCTUnwrap(URL(string: "https://example.org/"))

        let model = BrowserStore(url: initialURL)
        let inspectorController = WIInspectorController()
        retainedState.inspectors.append(inspectorController)
        let (browserWindow, _) = makeBrowserWindow(model: model, inspectorController: inspectorController)

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

    @MainActor
    func testOpeningDOMOnlyInspectorCharacterizesHTTPSAttachRegression() async throws {
        try await assertInspectorAttachBehaviorAcrossHTTPSNavigation(
            tabs: [.dom()]
        )
    }

    @MainActor
    func testOpeningNetworkOnlyInspectorCharacterizesHTTPSAttachRegression() async throws {
        try await assertInspectorAttachBehaviorAcrossHTTPSNavigation(
            tabs: [.network()]
        )
    }

    @MainActor
    func testBrowserWindowInstallsToolbarOnceAfterWindowAttachment() async throws {
        let initialURL = try XCTUnwrap(URL(string: "about:blank"))
        let model = BrowserStore(url: initialURL)
        let inspectorController = WIInspectorController()
        retainedState.inspectors.append(inspectorController)
        let placeholderController = NSViewController()
        placeholderController.view = NSView()
        let (browserWindow, browserController) = makeBrowserWindow(
            model: model,
            inspectorController: inspectorController,
            contentViewController: placeholderController
        )

        browserController.forceWindowAttachmentForTesting(in: browserWindow)
        browserController.forceWindowAttachmentForTesting(in: browserWindow)

        XCTAssertTrue(browserWindow.toolbar != nil, "The Monocly window did not install its NSToolbar after attaching to a window.")
        XCTAssertEqual(browserController.toolbarInstallationCountForTesting, 1)
    }

    @MainActor
    func testFinalizingBrowserRootDisconnectsInspectorWithoutDisappear() async throws {
        let initialURL = try XCTUnwrap(URL(string: "about:blank"))
        let model = BrowserStore(url: initialURL)
        let inspectorController = WIInspectorController()
        retainedState.inspectors.append(inspectorController)
        let (browserWindow, browserController) = makeBrowserWindow(model: model, inspectorController: inspectorController)

        browserWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let connected = await waitForCondition(description: "browser root connects inspector") {
            inspectorController.lifecycle == .active && inspectorController.dom.hasPageWebView
        }
        XCTAssertTrue(connected, "The browser root did not connect the inspector after appearing.")

        browserController.finalizeInspectorSession()

        let disconnected = await waitForCondition(description: "browser root finalization disconnects inspector") {
            inspectorController.lifecycle == .disconnected && inspectorController.dom.hasPageWebView == false
        }
        XCTAssertTrue(disconnected, "Finalizing the browser root did not disconnect the inspector session.")
    }

    @MainActor
    func testBrowserRootDisappearOnlySuspendsInspectorUntilVisibleAgain() async throws {
        let initialURL = try XCTUnwrap(URL(string: "about:blank"))
        let model = BrowserStore(url: initialURL)
        let inspectorController = WIInspectorController()
        retainedState.inspectors.append(inspectorController)
        let (browserWindow, browserController) = makeBrowserWindow(model: model, inspectorController: inspectorController)

        browserWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let connected = await waitForCondition(description: "browser root connects inspector before suspension") {
            inspectorController.lifecycle == .active && inspectorController.dom.hasPageWebView
        }
        XCTAssertTrue(connected, "The browser root did not connect the inspector before the suspension test.")

        browserController.viewDidDisappear()
        let suspended = await waitForCondition(description: "browser root suspends inspector on disappear") {
            inspectorController.lifecycle == .suspended && inspectorController.dom.hasPageWebView == false
        }
        XCTAssertTrue(suspended, "The browser root did not suspend the inspector after disappearing.")

        browserController.viewDidAppear()
        let reconnected = await waitForCondition(description: "browser root reconnects inspector on appear") {
            inspectorController.lifecycle == .active && inspectorController.dom.hasPageWebView
        }
        XCTAssertTrue(reconnected, "The browser root did not reconnect the inspector after appearing again.")
    }

    @MainActor
    func testInspectorWindowPresentationUsesCurrentWindowContextWhenParentWindowIsNil() async throws {
        let initialURL = try XCTUnwrap(URL(string: "about:blank"))
        let model = BrowserStore(url: initialURL)
        let inspectorController = WIInspectorController()
        retainedState.inspectors.append(inspectorController)
        let (browserWindow, _) = makeBrowserWindow(model: model, inspectorController: inspectorController)

        browserWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        MonoclyWindowContextStore.shared.setCurrentWindowForTesting(browserWindow)

        let didPresent = BrowserInspectorCoordinator.present(
            from: nil,
            browserStore: model,
            inspectorController: inspectorController,
            tabs: [.dom(), .network()]
        )
        XCTAssertTrue(didPresent, "The inspector coordinator failed to present using the current window context.")

        let inspectorWindowAppeared = await waitForCondition(description: "inspector window from current context") {
            NSApp.windows.contains { $0.title == "Web Inspector" && $0.isVisible }
        }
        XCTAssertTrue(inspectorWindowAppeared, "The inspector window did not appear when the current window context was used.")

        let inspectorWindow = try XCTUnwrap(
            NSApp.windows.first { $0.title == "Web Inspector" && $0.isVisible }
        )
        XCTAssertEqual(inspectorWindow.frame.midX, browserWindow.frame.midX, accuracy: 40)
        XCTAssertEqual(inspectorWindow.frame.midY, browserWindow.frame.midY, accuracy: 40)
    }

    @MainActor
    func testInspectorWindowPresentationPrefersExplicitParentWindowOverCurrentContext() async throws {
        let initialURL = try XCTUnwrap(URL(string: "about:blank"))
        let model = BrowserStore(url: initialURL)
        let inspectorController = WIInspectorController()
        retainedState.inspectors.append(inspectorController)
        let (browserWindow, _) = makeBrowserWindow(model: model, inspectorController: inspectorController)
        let alternateWindow = NSWindow(contentViewController: NSViewController())
        alternateWindow.setContentSize(NSSize(width: 800, height: 600))
        alternateWindow.title = "Alternate Window"
        retainedState.windows.append(alternateWindow)

        browserWindow.setFrameOrigin(NSPoint(x: 200, y: 200))
        alternateWindow.setFrameOrigin(NSPoint(x: 1200, y: 200))
        browserWindow.makeKeyAndOrderFront(nil)
        alternateWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        MonoclyWindowContextStore.shared.setCurrentWindowForTesting(alternateWindow)

        let didPresent = BrowserInspectorCoordinator.present(
            from: browserWindow,
            browserStore: model,
            inspectorController: inspectorController,
            tabs: [.dom(), .network()]
        )
        XCTAssertTrue(didPresent, "The inspector coordinator failed to present using the explicit parent window.")

        let inspectorWindowAppeared = await waitForCondition(description: "inspector window from explicit parent") {
            NSApp.windows.contains { $0.title == "Web Inspector" && $0.isVisible }
        }
        XCTAssertTrue(inspectorWindowAppeared, "The inspector window did not appear when the explicit parent window was used.")

        let inspectorWindow = try XCTUnwrap(
            NSApp.windows.first { $0.title == "Web Inspector" && $0.isVisible }
        )
        XCTAssertEqual(inspectorWindow.frame.midX, browserWindow.frame.midX, accuracy: 40)
        XCTAssertEqual(inspectorWindow.frame.midY, browserWindow.frame.midY, accuracy: 40)
        XCTAssertGreaterThan(abs(inspectorWindow.frame.midX - alternateWindow.frame.midX), 200)
    }

    @MainActor
    func testClosingCurrentWindowContextFallsBackToNextMainWindow() {
        let firstWindow = NSWindow()
        let secondWindow = NSWindow()

        MonoclyWindowContextStore.shared.setCurrentWindowForTesting(firstWindow)
        MonoclyWindowContextStore.shared.refreshCurrentWindowForTesting(
            keyWindow: nil,
            mainWindow: secondWindow
        )

        XCTAssertTrue(MonoclyWindowContextStore.shared.currentWindow === secondWindow)
    }
}

@MainActor
private extension BrowserStoreInspectorRegressionTests {
    func assertInspectorAttachBehaviorAcrossHTTPSNavigation(
        tabs: [WITab]
    ) async throws {
        let tabIdentifiers = tabs.map(\.identifier).joined(separator: ",")
        let initialURL = try XCTUnwrap(URL(string: "https://example.com/"))
        let followUpURL = try XCTUnwrap(URL(string: "https://example.org/"))

        let model = BrowserStore(url: initialURL)
        let inspectorController = WIInspectorController()
        retainedState.inspectors.append(inspectorController)
        let (browserWindow, _) = makeBrowserWindow(model: model, inspectorController: inspectorController)

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

    func makeBrowserWindow(
        model: BrowserStore,
        inspectorController: WIInspectorController,
        contentViewController: NSViewController? = nil
    ) -> (NSWindow, BrowserRootViewController) {
        let controller = BrowserRootViewController(
            store: model,
            inspectorController: inspectorController,
            launchConfiguration: BrowserLaunchConfiguration(initialURL: model.currentURL ?? URL(string: "about:blank")!),
            contentViewController: contentViewController
        )
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 1024, height: 768))
        window.styleMask = NSWindow.StyleMask([.titled, .closable, .resizable])
        window.title = "Monocly Test Host"
        retainedState.windows.append(window)
        return (window, controller)
    }

    func presentInspectorWindow(
        model: BrowserStore,
        inspectorController: WIInspectorController,
        tabs: [WITab],
        parentWindow: NSWindow
    ) {
        let didPresent = BrowserInspectorCoordinator.present(
            from: parentWindow,
            browserStore: model,
            inspectorController: inspectorController,
            tabs: tabs
        )
        XCTAssertTrue(didPresent, "The inspector coordinator failed to present the inspector window.")
    }

    func makeTemporaryHTMLURL(named name: String, html: String) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonoclyInspectorRegression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        retainedState.temporaryDirectories.append(directoryURL)

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
        model: BrowserStore,
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
        let rawValue = try? await webView.callAsyncJavaScriptCompat(
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
