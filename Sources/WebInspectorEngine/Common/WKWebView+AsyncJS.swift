import WebKit

package typealias WIAny = Any

package extension WKWebView {
    @MainActor
    func callAsyncVoidJavaScript(
        _ script: String,
        arguments: [String: WIAny] = [:],
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
