//
//  MiniBrowserUITests.swift
//  MiniBrowserUITests
//
//  Created by lynnswap on 2025/12/03.
//

import XCTest

final class MiniBrowserUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testInspectorTabSwitchStressDoesNotTerminateApp() throws {
        let app = XCUIApplication()
        app.launch()

        let openInspectorButton = app.buttons["MiniBrowser.openInspectorButton"]
        XCTAssertTrue(openInspectorButton.waitForExistence(timeout: 10))
        openInspectorButton.tap()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        var tabButtons = tabBar.buttons.allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(tabButtons.count, 2, "Expected at least 2 inspector tabs")
        for _ in 0..<20 {
            tabButtons = tabBar.buttons.allElementsBoundByIndex
            for tabButton in tabButtons {
                XCTAssertTrue(tabButton.waitForExistence(timeout: 3))
                tabButton.tap()
                XCTAssertEqual(app.state, .runningForeground)
            }
        }
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
