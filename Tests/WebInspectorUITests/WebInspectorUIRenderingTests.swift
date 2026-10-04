#if canImport(UIKit)
import Testing
import UIKit
import WebInspectorKit

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
        try await WebInspectorSession.prepare()
        let wereAnimationsEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(wereAnimationsEnabled)
        }
        try await function()
    }
}
#endif
