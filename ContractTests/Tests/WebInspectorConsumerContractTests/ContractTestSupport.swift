import Foundation
import Testing
import WebViewDataKit
import WebViewProxyKit
import WebViewProxyKitTesting

enum ContractTestSupport {
    static func enqueueDataKitStartupReplies(
        on backend: WebViewTestBackend,
        document: DOM.Node = WebViewProxyTestFixtures.domDocument()
    ) async {
        await backend.enqueue((), for: "Runtime", method: "enable")
        await backend.enqueue((), for: "Network", method: "enable")
        await backend.enqueue(document, for: "DOM", method: "getDocument")
        await backend.enqueue((), for: "Console", method: "enable")
    }

    static func enqueueDataKitShutdownReplies(on backend: WebViewTestBackend) async {
        await backend.enqueue((), for: "Console", method: "disable")
        await backend.enqueue((), for: "Runtime", method: "disable")
        await backend.enqueue((), for: "Network", method: "disable")
    }

    @MainActor
    static func startDataKitContext(
        runtime: WebViewProxyTestRuntime,
        document: DOM.Node = WebViewProxyTestFixtures.domDocument()
    ) async throws -> (WebViewTarget, WebViewModelContainer, WebViewModelContext) {
        let target = try await runtime.proxy.waitForCurrentPage()
        await enqueueDataKitStartupReplies(on: runtime.backend, document: document)

        let container = WebViewModelContainer(proxy: runtime.proxy)
        let context = container.mainContext
        try await waitForDataKitSubscribers(runtime: runtime, target: target)
        try await waitUntil { context.state == .attached }
        return (target, container, context)
    }

    @MainActor
    static func waitForDataKitSubscribers(
        runtime: WebViewProxyTestRuntime,
        target: WebViewTarget
    ) async throws {
        try await runtime.backend.waitForSubscribers(domain: "DOM", target: target, count: 1)
        try await runtime.backend.waitForSubscribers(domain: "Inspector", target: target, count: 1)
        try await runtime.backend.waitForSubscribers(domain: "CSS", target: target, count: 1)
        try await runtime.backend.waitForSubscribers(domain: "Network", target: target, count: 1)
        try await runtime.backend.waitForSubscribers(domain: "Console", target: target, count: 1)
        try await runtime.backend.waitForSubscribers(domain: "Runtime", target: target, count: 1)
    }

    static func emitFinishedRequest(
        _ request: Network.Request,
        target: WebViewTarget,
        backend: WebViewTestBackend
    ) async {
        await backend.emit(
            .requestWillBeSent(
                id: request.id,
                request: request,
                resourceType: .fetch,
                redirectResponse: nil,
                timestamp: 1
            ),
            target: target
        )
        await backend.emit(
            .responseReceived(
                id: request.id,
                response: Network.Response(
                    status: 200,
                    mimeType: "application/json",
                    headers: ["Content-Type": "application/json"]
                ),
                resourceType: .fetch,
                timestamp: 2
            ),
            target: target
        )
        await backend.emit(
            .dataReceived(id: request.id, dataLength: 7, encodedDataLength: 4, timestamp: 3),
            target: target
        )
        await backend.emit(
            .loadingFinished(
                id: request.id,
                timestamp: 4,
                sourceMapURL: "data.json.map",
                metrics: Network.Metrics(encodedDataLength: 4, decodedBodyLength: 7)
            ),
            target: target
        )
    }

    @MainActor
    static func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor @Sendable () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while condition() == false {
            if clock.now >= deadline {
                throw TimedOut()
            }
            await Task.yield()
        }
    }

    @MainActor
    static func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while await condition() == false {
            if clock.now >= deadline {
                throw TimedOut()
            }
            await Task.yield()
        }
    }

    static func value<T: Sendable>(
        of task: Task<T, Never>,
        timeout: Duration = .seconds(1)
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                await task.value
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimedOut()
            }
            guard let value = try await group.next() else {
                throw TimedOut()
            }
            group.cancelAll()
            return value
        }
    }
}

struct TimedOut: Error {}
