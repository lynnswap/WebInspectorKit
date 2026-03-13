#if canImport(UIKit)
import UIKit
import WebInspectorKit
import XCTest
@testable import MiniBrowser

@MainActor
final class BrowserViewportStateTests: XCTestCase {
    func testResolvedInsetsUseVisibleChromeHeights() {
        let state = BrowserViewportState(
            safeAreaInsets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
            topObscuredHeight: 103,
            bottomObscuredHeight: 88,
            keyboardOverlapHeight: 0,
            inputAccessoryOverlapHeight: 0,
            bottomChromeMode: .normal
        )

        XCTAssertEqual(state.finalObscuredInsets.top, 103)
        XCTAssertEqual(state.finalObscuredInsets.bottom, 88)
    }

    func testResolvedInsetsPreferKeyboardWhenBottomChromeIsHidden() {
        let state = BrowserViewportState(
            safeAreaInsets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
            topObscuredHeight: 103,
            bottomObscuredHeight: 88,
            keyboardOverlapHeight: 336,
            inputAccessoryOverlapHeight: 0,
            bottomChromeMode: .hiddenForKeyboard
        )

        XCTAssertEqual(state.finalObscuredInsets.top, 103)
        XCTAssertEqual(state.finalObscuredInsets.bottom, 336)
    }

    func testResolvedInsetsUseInputAccessoryOverlapWhenLargerThanKeyboard() {
        let state = BrowserViewportState(
            safeAreaInsets: .zero,
            topObscuredHeight: 88,
            bottomObscuredHeight: 0,
            keyboardOverlapHeight: 200,
            inputAccessoryOverlapHeight: 244,
            bottomChromeMode: .hiddenForKeyboard
        )

        XCTAssertEqual(state.finalObscuredInsets.bottom, 244)
    }

    func testSafeAreaAffectedEdgesIncludeTopAndBottom() {
        let state = BrowserViewportState(
            safeAreaInsets: .zero,
            topObscuredHeight: 88,
            bottomObscuredHeight: 52,
            keyboardOverlapHeight: 0,
            inputAccessoryOverlapHeight: 0,
            bottomChromeMode: .normal
        )

        XCTAssertEqual(state.safeAreaAffectedEdges, [.top, .bottom])
    }

    func testViewportMetricsRoundInsetsToPixelBoundaries() {
        let first = BrowserViewportMetrics(
            state: BrowserViewportState(
                safeAreaInsets: UIEdgeInsets(top: 58.97, left: 0, bottom: 34.02, right: 0),
                topObscuredHeight: 102.98,
                bottomObscuredHeight: 87.96,
                keyboardOverlapHeight: 0,
                inputAccessoryOverlapHeight: 0,
                bottomChromeMode: .normal
            ),
            screenScale: 3
        )

        let second = BrowserViewportMetrics(
            state: BrowserViewportState(
                safeAreaInsets: UIEdgeInsets(top: 59.01, left: 0, bottom: 34.04, right: 0),
                topObscuredHeight: 103.01,
                bottomObscuredHeight: 87.99,
                keyboardOverlapHeight: 0,
                inputAccessoryOverlapHeight: 0,
                bottomChromeMode: .normal
            ),
            screenScale: 3
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.obscuredInsets.top, 103)
        XCTAssertEqual(first.obscuredInsets.bottom, 88)
    }
}
#endif
