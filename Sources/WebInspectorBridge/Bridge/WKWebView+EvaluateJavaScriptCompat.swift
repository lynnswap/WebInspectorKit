import WebInspectorBridgeObjCShim
import WebKit

extension WKWebView {
    @MainActor
    @preconcurrency
    public func evaluateJavaScriptCompat(
        _ javaScript: String,
        in frame: WKFrameInfo? = nil,
        in contentWorld: WKContentWorld,
        completionHandler: ((Result<Any, any Error>) -> Void)? = nil
    ) {
        let thunk = completionHandler.map { handler in
            WIKObjCBlockConversion.boxingNilAsAnyForCompatibility(WIKUnsafeTransfer(value: handler))
        }
        WIKRuntimeBridge.evaluateJavaScript(
            on: self,
            javaScript: javaScript,
            inFrame: frame,
            in: contentWorld,
            completionHandler: thunk
        )
    }

    @MainActor
    public func evaluateJavaScriptCompat(
        _ javaScript: String,
        in frame: WKFrameInfo? = nil,
        contentWorld: WKContentWorld
    ) async throws -> Any? {
        let transferredResult = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<WIKUnsafeTransfer<Any?>, Error>) in
            WIKRuntimeBridge.evaluateJavaScript(
                on: self,
                javaScript: javaScript,
                inFrame: frame,
                in: contentWorld,
                completionHandler: { result, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: WIKUnsafeTransfer(value: result))
                    }
                }
            )
        }
        return transferredResult.value
    }
}
