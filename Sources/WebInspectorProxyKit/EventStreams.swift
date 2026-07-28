import Foundation

package func finishedStream<Element: Sendable>(of type: Element.Type = Element.self) -> AsyncStream<Element> {
    AsyncStream<Element> { continuation in
        continuation.finish()
    }
}
