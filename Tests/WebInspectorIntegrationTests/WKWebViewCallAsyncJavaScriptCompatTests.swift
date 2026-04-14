import Testing
import WebInspectorTestSupport
import WebKit
@testable import WebInspectorEngine

private struct UnsafeTestTransfer<Value>: @unchecked Sendable {
    let value: Value
}

@MainActor
@Suite(.serialized, .webKitIsolated)
struct WKWebViewCallAsyncJavaScriptCompatTests {
    @Test
    func asyncCallReturnsExpectedValue() async throws {
        let webView = makeIsolatedTestWebView()

        let result = try await webView.callAsyncJavaScriptCompat(
            "return a + b;",
            arguments: [
                "a": 1,
                "b": 2,
            ],
            contentWorld: .page
        ) as? Int

        #expect(result == 3)
    }

    @Test
    func asyncCallReturnsNilForUndefined() async throws {
        let webView = makeIsolatedTestWebView()

        let result = try await webView.callAsyncJavaScriptCompat(
            "console.log('hello');",
            contentWorld: .page
        )

        #expect(result == nil)
    }

    @Test
    func completionCallBoxesNilForUndefined() async {
        let webView = makeIsolatedTestWebView()

        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<UnsafeTestTransfer<Result<Any, any Error>>, Never>) in
            webView.callAsyncJavaScriptCompat(
                "console.log('hello');",
                in: nil,
                in: .page,
                completionHandler: { result in
                    continuation.resume(returning: UnsafeTestTransfer(value: result))
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
    func asyncCallReturnsNSNullForNull() async throws {
        let webView = makeIsolatedTestWebView()

        let result = try await webView.callAsyncJavaScriptCompat(
            "return null;",
            contentWorld: .page
        )

        #expect(result is NSNull)
    }

    @Test
    func asyncCallPreservesNestedArguments() async throws {
        let webView = makeIsolatedTestWebView()

        let result = try await webView.callAsyncJavaScriptCompat(
            """
            return payload.items.map(item => item.name).join(',') + ':' + payload.count;
            """,
            arguments: [
                "payload": [
                    "items": [
                        ["name": "alpha"],
                        ["name": "beta"],
                    ],
                    "count": 2,
                ],
            ],
            contentWorld: .page
        ) as? String

        #expect(result == "alpha,beta:2")
    }

    @Test
    func asyncCallPropagatesJavaScriptExceptions() async throws {
        let webView = makeIsolatedTestWebView()

        await #expect(throws: (any Error).self) {
            _ = try await webView.callAsyncJavaScriptCompat(
                "throw new Error('boom');",
                contentWorld: .page
            )
        }
    }

    @Test
    func asyncCallPropagatesRejectedPromises() async throws {
        let webView = makeIsolatedTestWebView()

        await #expect(throws: (any Error).self) {
            _ = try await webView.callAsyncJavaScriptCompat(
                "return Promise.reject('boom');",
                contentWorld: .page
            )
        }
    }
}
