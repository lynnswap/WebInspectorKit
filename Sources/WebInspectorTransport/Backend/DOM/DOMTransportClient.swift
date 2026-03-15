import WebInspectorCore

@MainActor
package struct DOMTransportClient {
    package init() {}

    package func resolvedLease(
        from lease: WISharedTransportRegistry.Lease?
    ) throws -> WISharedTransportRegistry.Lease {
        guard let lease else {
            throw WebInspectorCoreError.scriptUnavailable
        }
        return lease
    }

    package func preparedCSSLease(
        from lease: WISharedTransportRegistry.Lease?
    ) async throws -> WISharedTransportRegistry.Lease {
        let lease = try resolvedLease(from: lease)
        try await lease.ensureAttached()
        try await lease.ensureCSSDomainReady()
        return lease
    }

    package func preparedDOMEventLease(
        from lease: WISharedTransportRegistry.Lease?
    ) async throws -> WISharedTransportRegistry.Lease {
        let lease = try resolvedLease(from: lease)
        try await lease.ensureAttached()
        try await lease.ensureDOMEventIngress()
        return lease
    }

    package func preparedDOMSnapshotLease(
        from lease: WISharedTransportRegistry.Lease?
    ) async throws -> WISharedTransportRegistry.Lease {
        let lease = try await preparedDOMEventLease(from: lease)
        try await lease.ensureCSSDomainReady()
        return lease
    }

    package func sendPage<C: WITransportPageCommand>(
        _ command: C,
        using lease: WISharedTransportRegistry.Lease?
    ) async throws -> C.Response {
        let lease = try resolvedLease(from: lease)
        return try await lease.sendPage(command)
    }
}
