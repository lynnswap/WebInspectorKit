import WebKit

extension WKWebView {
    @MainActor
    func callAsyncVoidJavaScript(
        _ script: String,
        arguments: [String: Any] = [:],
        in frame: WKFrameInfo? = nil,
        contentWorld: WKContentWorld
    ) async throws {
        _ = try await callAsyncJavaScript(
            "(() => { \(script); })();",
            arguments: arguments,
            in: frame,
            contentWorld: contentWorld
        )
    }
}
