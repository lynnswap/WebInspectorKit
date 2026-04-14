import WebInspectorBridgeObjCShim
import WebKit

private struct WIKUnsafeTransfer<Value>: @unchecked Sendable {
    let value: Value
}

private enum WIKObjCBlockConversion {
    static nonisolated func boxingNilAsAnyForCompatibility(
        _ transferredHandler: WIKUnsafeTransfer<(Result<Any, any Error>) -> Void>
    ) -> @Sendable (Any?, (any Error)?) -> Void {
        { value, error in
            if let error {
                transferredHandler.value(.failure(error))
            } else if let value {
                transferredHandler.value(.success(value))
            } else {
                transferredHandler.value(.success(Optional<Any>.none as Any))
            }
        }
    }
}

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
        wki_callAsyncJavaScript(
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
            wki_callAsyncJavaScript(
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
