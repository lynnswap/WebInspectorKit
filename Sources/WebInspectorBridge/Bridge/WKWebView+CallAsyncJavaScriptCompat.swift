import WebInspectorBridgeObjCShim
import WebKit

extension WKWebView {
    @MainActor
    @preconcurrency
    public func callAsyncJavaScriptCompat(
        _ functionBody: String,
        arguments: [String: Any] = [:],
        in frame: WKFrameInfo? = nil,
        in contentWorld: WKContentWorld,
        completionHandler: ((Result<Any, any Error>) -> Void)? = nil
    ) {
        let thunk = completionHandler.map { handler in
            WIKObjCBlockConversion.boxingNilAsAnyForCompatibility(WIKUnsafeTransfer(value: handler))
        }
        self.wi_callAsyncJavaScript(
            functionBody,
            arguments: arguments,
            inFrame: frame,
            in: contentWorld,
            completionHandler: thunk
        )
    }

    @MainActor
    public func callAsyncJavaScriptCompat(
        _ functionBody: String,
        arguments: [String: Any] = [:],
        in frame: WKFrameInfo? = nil,
        contentWorld: WKContentWorld
    ) async throws -> Any? {
        let transferredResult = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<WIKUnsafeTransfer<Any?>, Error>) in
            self.wi_callAsyncJavaScript(
                functionBody,
                arguments: arguments,
                inFrame: frame,
                in: contentWorld
            ) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: WIKUnsafeTransfer(value: result))
                }
            }
        }
        return transferredResult.value
    }
}
