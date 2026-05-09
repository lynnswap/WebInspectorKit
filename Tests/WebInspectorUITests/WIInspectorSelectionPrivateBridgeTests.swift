#if canImport(UIKit)
import Testing
@testable import WebInspectorBridge

@MainActor
struct WIInspectorSelectionPrivateBridgeTests {
    @Test
    func nodeSearchCommitGestureCommitsTapsAndRejectsDrags() {
        #expect(
            WIInspectorSelectionPrivateBridge.shouldCommitNodeSearchForTesting(
                didMoveBeyondTapTolerance: false
            )
        )
        #expect(
            WIInspectorSelectionPrivateBridge.shouldCommitNodeSearchForTesting(
                didMoveBeyondTapTolerance: true
            ) == false
        )
    }
}
#endif
