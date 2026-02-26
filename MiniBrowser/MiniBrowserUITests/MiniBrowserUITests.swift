//
//  MiniBrowserUITests.swift
//  MiniBrowserUITests
//
//  Created by lynnswap on 2025/12/03.
//

import XCTest

final class MiniBrowserUITests: XCTestCase {
    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchAndPresentInspector() throws {
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = XCUIApplication()
        app.launch()
        XCTAssertEqual(app.state, .runningForeground)

        openInspector(app)

        let tabSwitcher = app.segmentedControls["WI.Regular.TabSwitcher"]
        XCTAssertTrue(tabSwitcher.waitForExistence(timeout: 10))

        let pickButton = app.buttons["WI.DOM.PickButton"]
        let menuButton = app.buttons["WI.DOM.MenuButton"]
        XCTAssertTrue(pickButton.waitForExistence(timeout: 10))
        XCTAssertTrue(menuButton.waitForExistence(timeout: 10))

        let midYDiff = abs(tabSwitcher.frame.midY - pickButton.frame.midY)
        XCTAssertLessThanOrEqual(midYDiff, 24, "Tab switcher and DOM actions should share one navigation row")

        if tabSwitcher.buttons["Network"].exists {
            tabSwitcher.buttons["Network"].tap()
        } else {
            app.buttons["Network"].tap()
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(pickButton.exists, "DOM action button should be hidden on Network tab")
        XCTAssertFalse(menuButton.exists, "DOM menu button should be hidden on Network tab")

        // Allow split/tab transition animations to settle before capture.
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        captureInspectorScreenshot(named: "MiniBrowser-Inspector")
    }

    @MainActor
    func testCompactNetworkTabShowsListPane() throws {
        XCUIDevice.shared.orientation = .portrait

        let app = XCUIApplication()
        app.launch()
        XCTAssertEqual(app.state, .runningForeground)

        openInspector(app)

        let networkButton = app.buttons["Network"]
        XCTAssertTrue(networkButton.waitForExistence(timeout: 10))
        networkButton.tap()

        let networkListPane = app.otherElements["WI.Network.ListPane"]
        XCTAssertTrue(networkListPane.waitForExistence(timeout: 10))
    }

    @MainActor
    private func openInspector(_ app: XCUIApplication) {
        let openInspectorButton = app.buttons["MiniBrowser.openInspectorButton"]
        XCTAssertTrue(openInspectorButton.waitForExistence(timeout: 10))
        openInspectorButton.tap()
    }

    @MainActor
    private func captureInspectorScreenshot(named name: String) {
        let screenshot = XCUIScreen.main.screenshot()

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let destinationPath = ProcessInfo.processInfo.environment["MINIBROWSER_UI_SCREENSHOT_PATH"]
            ?? "/tmp/\(name).png"
        let destinationURL = URL(fileURLWithPath: destinationPath)

        do {
            let parent = destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try screenshot.pngRepresentation.write(to: destinationURL)
            XCTContext.runActivity(named: "Saved screenshot to \(destinationURL.path)") { _ in }
        } catch {
            XCTFail("Failed to save screenshot: \(error)")
        }
    }
}
