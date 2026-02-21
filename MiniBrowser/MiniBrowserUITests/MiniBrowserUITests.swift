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
        let app = XCUIApplication()
        app.launch()
        XCTAssertEqual(app.state, .runningForeground)

        let openInspectorButton = app.buttons["MiniBrowser.openInspectorButton"]
        XCTAssertTrue(openInspectorButton.waitForExistence(timeout: 10))
        openInspectorButton.tap()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(tabBar.buttons.count, 1, "Expected at least one inspector tab")
    }
}
