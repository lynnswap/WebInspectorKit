import Foundation
import WebKit

public actor WebViewProxy {
    public struct Configuration: Equatable, Sendable {
        public var responseTimeout: Duration
        public var bootstrapTimeout: Duration

        public init(
            responseTimeout: Duration = .seconds(5),
            bootstrapTimeout: Duration = .seconds(5)
        ) {
            self.responseTimeout = responseTimeout
            self.bootstrapTimeout = bootstrapTimeout
        }
    }

    private let configuration: Configuration
    private let backend: (any WebViewProxyBackend)?
    private var pageTarget: WebViewTarget?
    private var targetsByID: [WebViewTarget.ID: WebViewTarget]
    private var nextTargetOrdinal: UInt64
    private var closed: Bool

    @MainActor
    public init(
        attachingTo webView: WKWebView,
        configuration: Configuration = .init()
    ) async throws {
        _ = webView
        self.configuration = configuration
        backend = nil
        pageTarget = nil
        targetsByID = [:]
        nextTargetOrdinal = 0
        closed = false
        throw WebViewProxyError.unsupported([
            "Native WKWebView attachment is not implemented in the WebViewProxyKit shell."
        ])
    }

    package init(
        configuration: Configuration = .init(),
        backend: (any WebViewProxyBackend)? = nil
    ) {
        self.configuration = configuration
        self.backend = backend
        pageTarget = nil
        targetsByID = [:]
        nextTargetOrdinal = 0
        closed = false
    }

    public var currentPage: WebViewTarget? {
        pageTarget
    }

    public nonisolated var targets: WebViewTargetChanges {
        WebViewTargetChanges { [self] in
            AsyncStream<WebViewTargetChange> { continuation in
                Task {
                    let targets = await currentTargetsSnapshot()
                    for target in targets {
                        continuation.yield(.created(target))
                    }
                    continuation.finish()
                }
            }
        }
    }

    public var canReload: Bool {
        false
    }

    public func waitForCurrentPage() async throws -> WebViewTarget {
        if let pageTarget {
            return pageTarget
        }
        throw WebViewProxyError.disconnected("WebViewProxyKit shell has no current page target.")
    }

    public func reload() async throws {
        throw unimplementedCommand(domain: "Page", method: "reload")
    }

    public func close() async {
        closed = true
        pageTarget = nil
        targetsByID.removeAll()
    }

    public func waitUntilClosed() async throws {
        guard closed else {
            throw WebViewProxyError.disconnected("WebViewProxyKit shell is not connected.")
        }
    }

    package func installTargetForTesting(
        kind: WebViewTarget.Kind = .page,
        frameID: FrameID? = nil,
        isProvisional: Bool = false
    ) -> WebViewTarget {
        let ordinal = nextTargetOrdinal
        nextTargetOrdinal += 1
        let target = WebViewTarget(
            id: WebViewTarget.ID("test-target-\(ordinal)"),
            kind: kind,
            frameID: frameID,
            isProvisional: isProvisional,
            proxy: self,
            route: RoutingTargetID("test-route-\(ordinal)")
        )
        targetsByID[target.id] = target
        if kind == .page && isProvisional == false {
            pageTarget = target
        }
        return target
    }

    private func currentTargetsSnapshot() -> [WebViewTarget] {
        Array(targetsByID.values)
    }
}
