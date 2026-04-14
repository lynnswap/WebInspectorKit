import Testing
import WebInspectorTestSupport
import WebKit
@testable import WebInspectorBridge

private struct UnsafeEvaluateTestTransfer<Value>: @unchecked Sendable {
    let value: Value
}

@MainActor
@Suite(.serialized, .webKitIsolated)
struct WKWebViewEvaluateJavaScriptCompatTests {
    @Test
    func asyncEvaluateReturnsExpectedValue() async throws {
        let webView = makeIsolatedTestWebView()

        let result = try await webView.evaluateJavaScriptCompat(
            "1 + 2",
            in: nil,
            contentWorld: .page
        ) as? Int

        #expect(result == 3)
    }

    @Test
    func asyncEvaluateReturnsNilForUndefined() async throws {
        let webView = makeIsolatedTestWebView()

        let result = try await webView.evaluateJavaScriptCompat(
            "console.log('x')",
            in: nil,
            contentWorld: .page
        )

        #expect(result == nil)
    }

    @Test
    func completionEvaluateBoxesNilForUndefined() async {
        let webView = makeIsolatedTestWebView()

        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<UnsafeEvaluateTestTransfer<Result<Any, any Error>>, Never>) in
            webView.evaluateJavaScriptCompat(
                "console.log('x')",
                in: nil,
                in: .page,
                completionHandler: { result in
                    continuation.resume(returning: UnsafeEvaluateTestTransfer(value: result))
                }
            )
        }.value

        switch result {
        case .success(let value):
            let mirror = Mirror(reflecting: value)
            #expect(mirror.displayStyle == .optional)
            #expect(mirror.children.isEmpty)
        case .failure(let error):
            Issue.record("Expected success but received error: \(error)")
        }
    }

    @Test
    func asyncEvaluatePropagatesJavaScriptExceptions() async throws {
        let webView = makeIsolatedTestWebView()

        await #expect(throws: (any Error).self) {
            _ = try await webView.evaluateJavaScriptCompat(
                "throw new Error('boom')",
                in: nil,
                contentWorld: .page
            )
        }
    }
}
