#if os(iOS)
import XCTest

final class BrowserInspectorNavigationUITests: XCTestCase {
    private enum AccessibilityID {
        static let currentURL = "Monocly.diagnostics.currentURL"
        static let openInspector = "Monocly.inspectorHarness.openInspector"
        static let beginNativeSelection = "Monocly.inspectorHarness.beginNativeSelection"
        static let browserURL = "Monocly.inspectorHarness.browserURL"
        static let domDocumentURL = "Monocly.inspectorHarness.domDocumentURL"
        static let domContextID = "Monocly.inspectorHarness.domContextID"
        static let domIsSelecting = "Monocly.inspectorHarness.domIsSelecting"
        static let domSelectedPreview = "Monocly.inspectorHarness.domSelectedPreview"
        static let domSelectedSelector = "Monocly.inspectorHarness.domSelectedSelector"
        static let domTreeSelectedPreview = "Monocly.inspectorHarness.domTreeSelectedPreview"
        static let domTreeSelectedVisible = "Monocly.inspectorHarness.domTreeSelectedVisible"
        static let domRootState = "Monocly.inspectorHarness.domRootState"
        static let domError = "Monocly.inspectorHarness.domError"
        static let loadPage1 = "Monocly.inspectorHarness.loadPage1"
        static let loadPage2 = "Monocly.inspectorHarness.loadPage2"
        static let selectNode1 = "Monocly.inspectorHarness.selectNode1"
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
    func testDOMInspectorLoadsCurrentDocumentWhenOpenedAfterInitialPageLoad() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MONOCLY_UI_TEST_SCENARIO"] = "domOpenInspectorAfterInitialLoad"
        app.launch()

        let currentURLLabel = app.staticTexts[AccessibilityID.currentURL]
        XCTAssertTrue(currentURLLabel.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForCondition(timeout: 15) {
                currentURLLabel.label.contains("dom-page-1.html")
            },
            "Initial page did not finish loading before inspector open: \(currentURLLabel.label)"
        )

        let openInspectorButton = app.buttons[AccessibilityID.openInspector]
        XCTAssertTrue(openInspectorButton.waitForExistence(timeout: 10))
        openInspectorButton.tap()

        _ = try waitForHarnessState(
            in: app,
            pageFilename: "dom-page-1.html",
            canGoBack: false,
            canGoForward: false
        )
    }

    @MainActor
    func testDOMInspectorSelectionHarnessSelectsExpectedNode() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MONOCLY_UI_TEST_SCENARIO"] = "domOpenInspectorAfterInitialLoad"
        app.launch()

        let currentURLLabel = app.staticTexts[AccessibilityID.currentURL]
        XCTAssertTrue(currentURLLabel.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForCondition(timeout: 15) {
                currentURLLabel.label.contains("dom-page-1.html")
            }
        )

        let openInspectorButton = app.buttons[AccessibilityID.openInspector]
        XCTAssertTrue(openInspectorButton.waitForExistence(timeout: 10))
        openInspectorButton.tap()

        _ = try waitForHarnessState(
            in: app,
            pageFilename: "dom-page-1.html",
            canGoBack: false,
            canGoForward: false
        )

        let selectNodeButton = app.buttons[AccessibilityID.selectNode1]
        XCTAssertTrue(selectNodeButton.waitForExistence(timeout: 10))
        selectNodeButton.tap()

        let domSelectedPreviewLabel = app.staticTexts[AccessibilityID.domSelectedPreview]
        let domSelectedSelectorLabel = app.staticTexts[AccessibilityID.domSelectedSelector]
        let domErrorLabel = app.staticTexts[AccessibilityID.domError]

        let resolved = waitForCondition(timeout: 15) {
            domSelectedPreviewLabel.exists
                && domSelectedSelectorLabel.exists
                && domSelectedPreviewLabel.label.contains("<html>")
                && domSelectedSelectorLabel.label.contains("html")
                && domErrorLabel.label == "domError=n/a"
        }

        XCTAssertTrue(
            resolved,
            """
            Harness did not resolve the expected selected node.
            selectedPreview=\(domSelectedPreviewLabel.label)
            selectedSelector=\(domSelectedSelectorLabel.label)
            domError=\(domErrorLabel.label)
            """
        )
    }

    @MainActor
    func testDOMInspectorNativeSelectionCanTapPageBehindMediumSheet() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MONOCLY_UI_TEST_SCENARIO"] = "domOpenInspectorAfterInitialLoad"
        app.launch()

        let currentURLLabel = app.staticTexts[AccessibilityID.currentURL]
        XCTAssertTrue(currentURLLabel.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForCondition(timeout: 15) {
                currentURLLabel.label.contains("dom-page-1.html")
            }
        )

        let openInspectorButton = app.buttons[AccessibilityID.openInspector]
        XCTAssertTrue(openInspectorButton.waitForExistence(timeout: 10))
        openInspectorButton.tap()

        _ = try waitForHarnessState(
            in: app,
            pageFilename: "dom-page-1.html",
            canGoBack: false,
            canGoForward: false
        )

        let beginNativeSelectionButton = app.buttons[AccessibilityID.beginNativeSelection]
        XCTAssertTrue(beginNativeSelectionButton.waitForExistence(timeout: 10))
        beginNativeSelectionButton.tap()

        let selectingLabel = app.staticTexts[AccessibilityID.domIsSelecting]
        XCTAssertTrue(
            waitForCondition(timeout: 15) {
                selectingLabel.exists && selectingLabel.label == "domIsSelecting=1"
            },
            "DOM selection mode did not start: \(selectingLabel.label)"
        )

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22)).tap()

        let domSelectedPreviewLabel = app.staticTexts[AccessibilityID.domSelectedPreview]
        let domTreeSelectedPreviewLabel = app.staticTexts[AccessibilityID.domTreeSelectedPreview]
        let domTreeSelectedVisibleLabel = app.staticTexts[AccessibilityID.domTreeSelectedVisible]
        let domErrorLabel = app.staticTexts[AccessibilityID.domError]
        let resolved = waitForCondition(timeout: 15) {
            domSelectedPreviewLabel.exists
                && domSelectedPreviewLabel.label != "domSelectedPreview=n/a"
                && domSelectedPreviewLabel.label.contains("<")
                && domTreeSelectedPreviewLabel.label != "domTreeSelectedPreview=n/a"
                && domTreeSelectedVisibleLabel.label == "domTreeSelectedVisible=1"
                && domErrorLabel.label == "domError=n/a"
                && selectingLabel.label == "domIsSelecting=0"
        }

        XCTAssertTrue(
            resolved,
            """
            Page tap did not resolve a real DOM selection.
            selectedPreview=\(domSelectedPreviewLabel.label)
            treeSelectedPreview=\(domTreeSelectedPreviewLabel.label)
            treeSelectedVisible=\(domTreeSelectedVisibleLabel.label)
            selecting=\(selectingLabel.label)
            domError=\(domErrorLabel.label)
            """
        )
    }

    @MainActor
    func testDOMInspectorNativeSelectionLeavesPageInteractiveAfterSelection() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MONOCLY_UI_TEST_SCENARIO"] = "domOpenInspectorAfterInitialLoad"
        app.launch()

        let currentURLLabel = app.staticTexts[AccessibilityID.currentURL]
        XCTAssertTrue(currentURLLabel.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForCondition(timeout: 15) {
                currentURLLabel.label.contains("dom-page-1.html")
            }
        )

        let openInspectorButton = app.buttons[AccessibilityID.openInspector]
        XCTAssertTrue(openInspectorButton.waitForExistence(timeout: 10))
        openInspectorButton.tap()

        _ = try waitForHarnessState(
            in: app,
            pageFilename: "dom-page-1.html",
            canGoBack: false,
            canGoForward: false
        )

        let beginNativeSelectionButton = app.buttons[AccessibilityID.beginNativeSelection]
        XCTAssertTrue(beginNativeSelectionButton.waitForExistence(timeout: 10))
        beginNativeSelectionButton.tap()

        let selectingLabel = app.staticTexts[AccessibilityID.domIsSelecting]
        XCTAssertTrue(
            waitForCondition(timeout: 15) {
                selectingLabel.exists && selectingLabel.label == "domIsSelecting=1"
            }
        )

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22)).tap()

        let domSelectedPreviewLabel = app.staticTexts[AccessibilityID.domSelectedPreview]
        XCTAssertTrue(
            waitForCondition(timeout: 15) {
                domSelectedPreviewLabel.exists
                    && domSelectedPreviewLabel.label != "domSelectedPreview=n/a"
                    && selectingLabel.label == "domIsSelecting=0"
            }
        )

        let page2Link = tappablePageLink(in: app, label: "Go to Page 2")
        XCTAssertTrue(
            page2Link.waitForExistence(timeout: 10),
            "Fixture link did not expose an accessibility element."
        )
        page2Link.tap()

        _ = try waitForHarnessState(
            in: app,
            pageFilename: "dom-page-2.html",
            canGoBack: true,
            canGoForward: false
        )
    }

    @MainActor
    func testDOMInspectorNativeSelectionRemainsStableAcrossRepeatedSelections() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MONOCLY_UI_TEST_SCENARIO"] = "domOpenInspectorAfterInitialLoad"
        app.launch()

        let currentURLLabel = app.staticTexts[AccessibilityID.currentURL]
        XCTAssertTrue(currentURLLabel.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForCondition(timeout: 15) {
                currentURLLabel.label.contains("dom-page-1.html")
            }
        )

        let openInspectorButton = app.buttons[AccessibilityID.openInspector]
        XCTAssertTrue(openInspectorButton.waitForExistence(timeout: 10))
        openInspectorButton.tap()

        _ = try waitForHarnessState(
            in: app,
            pageFilename: "dom-page-1.html",
            canGoBack: false,
            canGoForward: false
        )

        let selectingLabel = app.staticTexts[AccessibilityID.domIsSelecting]
        let domSelectedPreviewLabel = app.staticTexts[AccessibilityID.domSelectedPreview]
        let domTreeSelectedPreviewLabel = app.staticTexts[AccessibilityID.domTreeSelectedPreview]
        let domTreeSelectedVisibleLabel = app.staticTexts[AccessibilityID.domTreeSelectedVisible]
        let domErrorLabel = app.staticTexts[AccessibilityID.domError]
        let beginNativeSelectionButton = app.buttons[AccessibilityID.beginNativeSelection]
        XCTAssertTrue(beginNativeSelectionButton.waitForExistence(timeout: 10))

        for _ in 0..<3 {
            beginNativeSelectionButton.tap()

            XCTAssertTrue(
                waitForCondition(timeout: 15) {
                    selectingLabel.exists && selectingLabel.label == "domIsSelecting=1"
                }
            )

            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22)).tap()

            let resolved = waitForCondition(timeout: 15) {
                domSelectedPreviewLabel.exists
                    && domSelectedPreviewLabel.label != "domSelectedPreview=n/a"
                    && domSelectedPreviewLabel.label.contains("<")
                    && domTreeSelectedPreviewLabel.label != "domTreeSelectedPreview=n/a"
                    && domTreeSelectedVisibleLabel.label == "domTreeSelectedVisible=1"
                    && domErrorLabel.label == "domError=n/a"
                    && selectingLabel.label == "domIsSelecting=0"
            }

            XCTAssertTrue(
                resolved,
                """
                Repeated native selection became unstable.
                selectedPreview=\(domSelectedPreviewLabel.label)
                treeSelectedPreview=\(domTreeSelectedPreviewLabel.label)
                treeSelectedVisible=\(domTreeSelectedVisibleLabel.label)
                selecting=\(selectingLabel.label)
                domError=\(domErrorLabel.label)
                """
            )
        }
    }

    @MainActor
    func testDOMInspectorStaysStableAcrossRapidSwitchesAndRepeatedHistoryTraversal() throws {
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
        app.buttons[AccessibilityID.loadPage1].tap()

        let reloadedPage1ContextLabel = try waitForHarnessState(
            in: app,
            pageFilename: "dom-page-1.html",
            canGoBack: true,
            canGoForward: false
        )
        XCTAssertNotEqual(reloadedPage1ContextLabel, initialContextLabel)

        var currentPage1ContextLabel = reloadedPage1ContextLabel
        for _ in 0..<2 {
            let backButton = app.buttons[AccessibilityID.goBack]
            XCTAssertTrue(backButton.isEnabled)
            backButton.tap()

            let page2ContextLabel = try waitForHarnessState(
                in: app,
                pageFilename: "dom-page-2.html",
                canGoBack: true,
                canGoForward: true
            )
            XCTAssertNotEqual(page2ContextLabel, currentPage1ContextLabel)

            let forwardButton = app.buttons[AccessibilityID.goForward]
            XCTAssertTrue(forwardButton.isEnabled)
            forwardButton.tap()

            currentPage1ContextLabel = try waitForHarnessState(
                in: app,
                pageFilename: "dom-page-1.html",
                canGoBack: true,
                canGoForward: false
            )
            XCTAssertNotEqual(currentPage1ContextLabel, page2ContextLabel)
        }
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
        let domNativeSelectionStateLabel = app.staticTexts["Monocly.inspectorHarness.domNativeSelectionState"]
        let domTreeSelectedPreviewLabel = app.staticTexts[AccessibilityID.domTreeSelectedPreview]
        let domTreeSelectedVisibleLabel = app.staticTexts[AccessibilityID.domTreeSelectedVisible]
        let domRootStateLabel = app.staticTexts[AccessibilityID.domRootState]
        let domErrorLabel = app.staticTexts[AccessibilityID.domError]
        let backButton = app.buttons[AccessibilityID.goBack]
        let forwardButton = app.buttons[AccessibilityID.goForward]

        let resolved = waitForCondition(timeout: timeout) {
            browserURLLabel.exists
                && domDocumentURLLabel.exists
                && domContextIDLabel.exists
                && domTreeSelectedPreviewLabel.exists
                && domTreeSelectedVisibleLabel.exists
                && domRootStateLabel.exists
                && domErrorLabel.exists
                && domNativeSelectionStateLabel.exists
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
            domTreeSelectedPreview=\(domTreeSelectedPreviewLabel.label)
            domTreeSelectedVisible=\(domTreeSelectedVisibleLabel.label)
            domNativeSelectionState=\(domNativeSelectionStateLabel.label)
            domRootState=\(domRootStateLabel.label)
            domError=\(domErrorLabel.label)
            backEnabled=\(backButton.isEnabled)
            forwardEnabled=\(forwardButton.isEnabled)
            """
        )

        return domContextIDLabel.label
    }

    @MainActor
    private func tappablePageLink(in app: XCUIApplication, label: String) -> XCUIElement {
        let link = app.links[label]
        if link.exists {
            return link
        }

        let button = app.buttons[label]
        if button.exists {
            return button
        }

        return link
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
