import Foundation

package func finishedStream<Element: Sendable>(of type: Element.Type = Element.self) -> AsyncStream<Element> {
    AsyncStream<Element> { continuation in
        continuation.finish()
    }
}

public enum WebViewTargetChange: Sendable {
    case created(WebViewTarget)
    case committed(WebViewTarget)
    case destroyed(WebViewTarget.ID)
}

public struct WebViewTargetChanges: AsyncSequence, Sendable {
    public typealias Element = WebViewTargetChange
    public typealias AsyncIterator = AsyncStream<WebViewTargetChange>.Iterator

    private let makeStream: @Sendable () -> AsyncStream<WebViewTargetChange>

    package init(
        _ makeStream: @escaping @Sendable () -> AsyncStream<WebViewTargetChange> = {
            finishedStream(of: WebViewTargetChange.self)
        }
    ) {
        self.makeStream = makeStream
    }

    public func makeAsyncIterator() -> AsyncIterator {
        makeStream().makeAsyncIterator()
    }
}
