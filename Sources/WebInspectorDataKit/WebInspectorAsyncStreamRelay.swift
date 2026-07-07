import Foundation
import Synchronization

final class WebInspectorAsyncStreamRelay<Element: Sendable>: Sendable {
    private struct State {
        var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
        var isFinished = false
    }

    private let state = Mutex(State())

    var hasContinuations: Bool {
        state.withLock { state in
            state.continuations.isEmpty == false
        }
    }

    func makeStream() -> AsyncStream<Element> {
        makeStream(initialElementIfAny: nil)
    }

    func makeStream(initialElement: Element) -> AsyncStream<Element> {
        makeStream(initialElementIfAny: initialElement)
    }

    private func makeStream(initialElementIfAny initialElement: Element?) -> AsyncStream<Element> {
        let id = UUID()
        let pair = AsyncStream<Element>.makeStream(bufferingPolicy: .unbounded)
        let shouldFinish = state.withLock { state in
            guard state.isFinished == false else {
                return true
            }
            state.continuations[id] = pair.continuation
            return false
        }
        if shouldFinish {
            pair.continuation.finish()
            return pair.stream
        }

        if let initialElement {
            pair.continuation.yield(initialElement)
        }
        pair.continuation.onTermination = { [weak self] _ in
            self?.removeStream(id)
        }
        return pair.stream
    }

    func yield(_ element: Element) {
        let continuations = state.withLock { state in
            Array(state.continuations.values)
        }
        for continuation in continuations {
            continuation.yield(element)
        }
    }

    func finish() {
        let continuations: [AsyncStream<Element>.Continuation] = state.withLock { state in
            guard state.isFinished == false else {
                return []
            }
            state.isFinished = true
            let continuations = Array(state.continuations.values)
            state.continuations.removeAll(keepingCapacity: false)
            return continuations
        }
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func removeStream(_ id: UUID) {
        let continuation = state.withLock { state in
            state.continuations.removeValue(forKey: id)
        }
        continuation?.finish()
    }

    deinit {
        finish()
    }
}
