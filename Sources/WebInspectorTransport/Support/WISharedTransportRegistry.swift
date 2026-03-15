import Foundation
import WebKit

@MainActor
package final class WISharedTransportRegistry {
    package static let shared = WISharedTransportRegistry()
    package typealias SessionFactory = @MainActor (WKWebView) -> WITransportSession

    @MainActor
    package final class Lease: InspectorTransportCapabilityProviding {
        private weak var registry: WISharedTransportRegistry?
        fileprivate let entry: TransportSessionPool.Entry
        private var released = false

        fileprivate init(registry: WISharedTransportRegistry, entry: TransportSessionPool.Entry) {
            self.registry = registry
            self.entry = entry
        }

        package var onNetworkIngressReadyForTesting: (@MainActor () -> Void)? {
            get { entry.eventHub.onNetworkIngressReadyForTesting }
            set { entry.eventHub.onNetworkIngressReadyForTesting = newValue }
        }

        package var onDOMIngressReadyForTesting: (@MainActor () -> Void)? {
            get { entry.eventHub.onDOMIngressReadyForTesting }
            set { entry.eventHub.onDOMIngressReadyForTesting = newValue }
        }

        package var inspectorTransportCapabilities: Set<InspectorTransportCapability> {
            entry.inspectorTransportCapabilities
        }

        package var inspectorTransportSupportSnapshot: WITransportSupportSnapshot? {
            supportSnapshot
        }

        package var supportSnapshot: WITransportSupportSnapshot {
            entry.supportSnapshot
        }

        package func ensureAttached() async throws {
            try await entry.ensureAttached()
        }

        package func sendPage<C: WITransportPageCommand>(_ command: C) async throws -> C.Response {
            try await entry.sendPage(command)
        }

        package func sendPageCapturingCurrentTarget<C: WITransportPageCommand>(
            _ command: C
        ) async throws -> (targetIdentifier: String, response: C.Response) {
            try await entry.sendPageCapturingCurrentTarget(command)
        }

        package func sendPage<C: WITransportPageCommand>(
            _ command: C,
            targetIdentifier: String
        ) async throws -> C.Response {
            try await entry.sendPage(command, targetIdentifier: targetIdentifier)
        }

        package func currentPageTargetIdentifier() async -> String? {
            await entry.currentPageTargetIdentifier()
        }

        package func pageTargetIdentifiers() async -> [String] {
            await entry.pageTargetIdentifiers()
        }

        package func sendRoot<C: WITransportRootCommand>(_ command: C) async throws -> C.Response {
            try await entry.sendRoot(command)
        }

        package func addNetworkConsumer(
            _ identifier: UUID,
            handler: @escaping @MainActor (WITransportEventEnvelope) -> Void
        ) {
            entry.eventHub.addNetworkConsumer(identifier, handler: handler)
        }

        package func removeNetworkConsumer(_ identifier: UUID) {
            entry.eventHub.removeNetworkConsumer(identifier)
        }

        package func addDOMConsumer(
            _ identifier: UUID,
            handler: @escaping @MainActor (WITransportEventEnvelope) -> Void
        ) {
            entry.eventHub.addDOMConsumer(identifier, handler: handler)
        }

        package func ensureNetworkEventIngress() async throws {
            try await entry.eventHub.ensureNetworkEventIngress()
        }

        package func removeDOMConsumer(_ identifier: UUID) {
            entry.eventHub.removeDOMConsumer(identifier)
        }

        package func ensureDOMEventIngress() async throws {
            try await entry.eventHub.ensureDOMEventIngress()
        }

        package func ensureCSSDomainReady() async throws {
            try await entry.ensureCSSDomainReady()
        }

        package func release() {
            guard !released else {
                return
            }
            released = true
            registry?.releaseLease(self)
        }
    }

    private let sessionPool: TransportSessionPool

    init(sessionFactory: @escaping SessionFactory = { _ in WITransportSession() }) {
        self.sessionPool = TransportSessionPool(sessionFactory: sessionFactory)
    }

    package func acquireLease(for webView: WKWebView) -> Lease {
        Lease(
            registry: self,
            entry: sessionPool.acquireEntry(for: webView)
        )
    }

    private func releaseLease(_ lease: Lease) {
        sessionPool.releaseEntry(lease.entry)
    }
}
