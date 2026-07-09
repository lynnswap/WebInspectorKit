#if canImport(UIKit)
import Testing
import UIKit

@MainActor
@Suite(.serialized, UIKitAnimationsDisabled())
struct WebInspectorUIRenderingTests {}

@MainActor
private struct UIKitAnimationsDisabled: SuiteTrait, TestTrait, TestScoping {
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: () async throws -> Void
    ) async throws {
        let wereAnimationsEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(wereAnimationsEnabled)
        }
        try await function()
    }
}
#endif
