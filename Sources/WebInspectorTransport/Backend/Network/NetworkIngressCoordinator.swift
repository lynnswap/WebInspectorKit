import OSLog
import WebKit

@MainActor
package final class NetworkIngressCoordinator {
    private let registry: WISharedTransportRegistry
    private let eventConsumerIdentifier = UUID()

    private var lease: WISharedTransportRegistry.Lease?
    private var attachTask: Task<Void, Never>?

    package init(registry: WISharedTransportRegistry) {
        self.registry = registry
    }

    package var supportSnapshot: WITransportSupportSnapshot? {
        lease?.supportSnapshot
    }

    package var inspectorTransportCapabilities: Set<InspectorTransportCapability> {
        lease?.inspectorTransportCapabilities ?? []
    }

    package var currentLease: WISharedTransportRegistry.Lease? {
        lease
    }

    package func waitForAttachForTesting() async {
        await attachTask?.value
    }

    package func attach(
        to webView: WKWebView,
        onEnvelope: @escaping @MainActor (WITransportEventEnvelope) -> Void,
        onAttachWork: @escaping @MainActor (WISharedTransportRegistry.Lease) async throws -> Void,
        onFailure: @escaping @MainActor (Error, WISharedTransportRegistry.Lease) -> Void
    ) {
        attachTask?.cancel()
        attachTask = nil
        releaseCurrentLease()

        let lease = registry.acquireLease(for: webView)
        self.lease = lease
        lease.addNetworkConsumer(eventConsumerIdentifier) { envelope in
            onEnvelope(envelope)
        }

        attachTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                try await lease.ensureAttached()
                try await lease.ensureNetworkEventIngress()
                try await onAttachWork(lease)
            } catch {
                onFailure(error, lease)
                if self.lease === lease {
                    self.releaseCurrentLease()
                }
            }

            self.attachTask = nil
        }
    }

    package func detach() {
        attachTask?.cancel()
        attachTask = nil
        releaseCurrentLease()
    }

    package func prepareForNavigationReconnect() {
        detach()
    }

    package func resumeAfterNavigationReconnect(
        to webView: WKWebView,
        onEnvelope: @escaping @MainActor (WITransportEventEnvelope) -> Void,
        onAttachWork: @escaping @MainActor (WISharedTransportRegistry.Lease) async throws -> Void,
        onFailure: @escaping @MainActor (Error, WISharedTransportRegistry.Lease) -> Void
    ) {
        guard lease == nil else {
            return
        }
        attach(
            to: webView,
            onEnvelope: onEnvelope,
            onAttachWork: onAttachWork,
            onFailure: onFailure
        )
    }
}

private extension NetworkIngressCoordinator {
    func releaseCurrentLease() {
        lease?.removeNetworkConsumer(eventConsumerIdentifier)
        lease?.release()
        lease = nil
    }
}
