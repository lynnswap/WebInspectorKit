#if os(iOS)
import XCTest

final class BrowserInspectorNavigationUITests: XCTestCase {
    private enum AccessibilityID {
        static let browserURL = "Monocly.inspectorHarness.browserURL"
        static let domDocumentURL = "Monocly.inspectorHarness.domDocumentURL"
        static let domContextID = "Monocly.inspectorHarness.domContextID"
        static let domRootState = "Monocly.inspectorHarness.domRootState"
        static let domError = "Monocly.inspectorHarness.domError"
        static let loadPage1 = "Monocly.inspectorHarness.loadPage1"
        static let loadPage2 = "Monocly.inspectorHarness.loadPage2"
        static let goBack = "Monocly.inspectorHarness.goBack"
        static let goForward = "Monocly.inspectorHarness.goForward"
    }

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDOMInspectorTracksPageSwitchBackAndForward() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MONOCLY_UI_TEST_SCENARIO"] = "domNavigationBackForward"
        app.launch()

        XCTAssertTrue(app.buttons[AccessibilityID.loadPage1].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[AccessibilityID.loadPage2].waitForExistence(timeout: 10))

        let initialContextLabel = try waitForHarnessState(
            in: app,
            pageFilename: "dom-page-1.html",
            canGoBack: false,
            canGoForward: false
        )

        app.buttons[AccessibilityID.loadPage2].tap()

        let page2ContextLabel = try waitForHarnessState(
            in: app,
            pageFilename: "dom-page-2.html",
            canGoBack: true,
            canGoForward: false
        )
        XCTAssertNotEqual(page2ContextLabel, initialContextLabel)

        let backButton = app.buttons[AccessibilityID.goBack]
        XCTAssertTrue(backButton.isEnabled)
        backButton.tap()

        let backContextLabel = try waitForHarnessState(
            in: app,
            pageFilename: "dom-page-1.html",
            canGoBack: false,
            canGoForward: true
        )
        XCTAssertNotEqual(backContextLabel, page2ContextLabel)

        let forwardButton = app.buttons[AccessibilityID.goForward]
        XCTAssertTrue(forwardButton.isEnabled)
        forwardButton.tap()

        let forwardContextLabel = try waitForHarnessState(
            in: app,
            pageFilename: "dom-page-2.html",
            canGoBack: true,
            canGoForward: false
        )
        XCTAssertNotEqual(forwardContextLabel, backContextLabel)
    }

    @MainActor
    private func waitForHarnessState(
        in app: XCUIApplication,
        pageFilename: String,
        canGoBack: Bool,
        canGoForward: Bool,
        timeout: TimeInterval = 15
    ) throws -> String {
        let browserURLLabel = app.staticTexts[AccessibilityID.browserURL]
        let domDocumentURLLabel = app.staticTexts[AccessibilityID.domDocumentURL]
        let domContextIDLabel = app.staticTexts[AccessibilityID.domContextID]
        let domRootStateLabel = app.staticTexts[AccessibilityID.domRootState]
        let domErrorLabel = app.staticTexts[AccessibilityID.domError]
        let backButton = app.buttons[AccessibilityID.goBack]
        let forwardButton = app.buttons[AccessibilityID.goForward]

        let resolved = waitForCondition(timeout: timeout) {
            browserURLLabel.exists
                && domDocumentURLLabel.exists
                && domContextIDLabel.exists
                && domRootStateLabel.exists
                && domErrorLabel.exists
                && browserURLLabel.label.contains(pageFilename)
                && domDocumentURLLabel.label.contains(pageFilename)
                && domRootStateLabel.label == "domRootReady=1"
                && domErrorLabel.label == "domError=n/a"
                && backButton.isEnabled == canGoBack
                && forwardButton.isEnabled == canGoForward
                && domContextIDLabel.label != "domContextID=n/a"
        }

        XCTAssertTrue(
            resolved,
            """
            Harness did not reach the expected state.
            browserURL=\(browserURLLabel.label)
            domDocumentURL=\(domDocumentURLLabel.label)
            domContextID=\(domContextIDLabel.label)
            domRootState=\(domRootStateLabel.label)
            domError=\(domErrorLabel.label)
            backEnabled=\(backButton.isEnabled)
            forwardEnabled=\(forwardButton.isEnabled)
            """
        )

        return domContextIDLabel.label
    }

    @MainActor
    private func waitForCondition(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.1,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return condition()
    }
}
#endif
