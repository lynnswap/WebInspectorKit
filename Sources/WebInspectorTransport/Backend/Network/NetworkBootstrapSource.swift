import Foundation
import WebInspectorCore

package struct NetworkBootstrapLoad {
    package let seeds: [NetworkEntrySeed]
    package let bindings: [NetworkContinuationBinding]

    package init(
        seeds: [NetworkEntrySeed],
        bindings: [NetworkContinuationBinding] = []
    ) {
        self.seeds = seeds
        self.bindings = bindings
    }
}

@MainActor
package protocol NetworkBootstrapSource {
    func load(
        using lease: WISharedTransportRegistry.Lease,
        allocateRequestID: @escaping () -> Int,
        defaultSessionID: @escaping (String?) -> String,
        normalizeScopeID: @escaping (String?) -> String?
    ) async throws -> NetworkBootstrapLoad
}

@MainActor
package struct StableBootstrapSource: NetworkBootstrapSource {
    package init() {}

    package func load(
        using lease: WISharedTransportRegistry.Lease,
        allocateRequestID: @escaping () -> Int,
        defaultSessionID: @escaping (String?) -> String,
        normalizeScopeID: @escaping (String?) -> String?
    ) async throws -> NetworkBootstrapLoad {
        let result = try await lease.sendPageCapturingCurrentTarget(
            WITransportCommands.Network.GetBootstrapSnapshot()
        )
        let capturedTargetIdentifier = result.targetIdentifier
        let syntheticDefaultSessionID = defaultSessionID(nil)
        let now = Date().timeIntervalSince1970
        let seedsAndBindings = result.response.resources.map { resource -> (NetworkEntrySeed, NetworkContinuationBinding?) in
            let normalizedOwnerSessionID = normalizeScopeID(resource.ownerSessionID)
            let resolvedFrameID = normalizeScopeID(resource.bodyFetchDescriptor?.frameId)
                ?? normalizeScopeID(resource.frameID)
            let resolvedOwnerSessionID = normalizedOwnerSessionID
                ?? normalizeScopeID(resource.targetIdentifier)
                ?? defaultSessionID(capturedTargetIdentifier)
            let resolvedTargetIdentifier = normalizeScopeID(resource.bodyFetchDescriptor?.targetIdentifier)
                ?? normalizeScopeID(resource.targetIdentifier)
                ?? ((resolvedOwnerSessionID == defaultSessionID(capturedTargetIdentifier)
                    || resolvedOwnerSessionID == syntheticDefaultSessionID)
                    ? normalizeScopeID(capturedTargetIdentifier)
                    : normalizedOwnerSessionID)
            let resolvedRequestTargetIdentifier = normalizeScopeID(resource.targetIdentifier)
                ?? ((resolvedOwnerSessionID == defaultSessionID(capturedTargetIdentifier)
                    || resolvedOwnerSessionID == syntheticDefaultSessionID)
                    ? normalizeScopeID(capturedTargetIdentifier)
                    : normalizedOwnerSessionID)
            let requestID = allocateRequestID()
            let responseBodyLocator: NetworkDeferredBodyLocator?
            if resource.phase != .failed,
               let resolvedTargetIdentifier,
               let resolvedFrameID {
                responseBodyLocator = .pageResource(
                    targetIdentifier: resolvedTargetIdentifier,
                    frameID: resolvedFrameID,
                    url: resource.bodyFetchDescriptor?.url ?? resource.url
                )
            } else {
                responseBodyLocator = nil
            }

            let phase: NetworkEntry.Phase
            switch resource.phase {
            case .completed:
                phase = .completed
            case .failed:
                phase = .failed
            case .inFlight:
                phase = .pending
            }

            var statusCode = resource.statusCode
            var statusText = resource.statusText ?? ""
            var errorDescription = resource.errorDescription
            if phase == .failed {
                if statusCode == nil {
                    statusCode = 0
                }
                if statusText.isEmpty, resource.canceled == true {
                    statusText = "Canceled"
                }
                if errorDescription == nil, resource.canceled == true {
                    errorDescription = "Canceled"
                }
            }

            let seed = NetworkEntrySeed(
                kind: .stable,
                sessionID: resolvedOwnerSessionID,
                requestID: requestID,
                url: resource.url,
                method: resource.method.isEmpty ? "UNKNOWN" : resource.method.uppercased(),
                requestHeaders: NetworkHeaders(dictionary: resource.requestHeaders ?? [:]),
                responseHeaders: NetworkHeaders(dictionary: resource.responseHeaders ?? [:]),
                startTimestamp: now,
                wallTime: nil,
                statusCode: statusCode,
                statusText: statusText,
                mimeType: resource.mimeType,
                errorDescription: errorDescription,
                requestType: resource.requestType,
                phase: phase,
                requestBody: makeDeferredRequestBody(
                    method: resource.method,
                    rawRequestID: normalizeScopeID(resource.rawRequestID),
                    targetIdentifier: resolvedRequestTargetIdentifier
                ),
                responseBody: responseBodyLocator.map {
                    NetworkBody(
                        kind: .other,
                        preview: nil,
                        full: nil,
                        size: nil,
                        isBase64Encoded: false,
                        isTruncated: false,
                        summary: nil,
                        deferredLocator: $0,
                        formEntries: [],
                        fetchState: .inline,
                        role: .response
                    )
                }
            )

            let binding: NetworkContinuationBinding?
            if phase == .pending, let rawRequestID = normalizeScopeID(resource.rawRequestID) {
                binding = NetworkContinuationBinding(
                    seedKind: .stable,
                    allowsCrossTargetRebind: true,
                    canonicalRequestID: requestID,
                    sessionID: resolvedOwnerSessionID,
                    requestTargetIdentifier: resolvedRequestTargetIdentifier,
                    responseTargetIdentifier: resolvedTargetIdentifier,
                    rawRequestID: rawRequestID,
                    url: resource.url,
                    requestType: resource.requestType
                )
            } else {
                binding = nil
            }

            return (seed, binding)
        }

        return NetworkBootstrapLoad(
            seeds: seedsAndBindings.map(\.0),
            bindings: seedsAndBindings.compactMap(\.1)
        )
    }
}

@MainActor
package struct HistoricalBootstrapSource: NetworkBootstrapSource {
    package init() {}

    package func load(
        using lease: WISharedTransportRegistry.Lease,
        allocateRequestID: @escaping () -> Int,
        defaultSessionID: @escaping (String?) -> String,
        normalizeScopeID: @escaping (String?) -> String?
    ) async throws -> NetworkBootstrapLoad {
        let result = try await lease.sendPageCapturingCurrentTarget(
            WITransportCommands.Page.GetResourceTree()
        )
        let capturedTargetIdentifier = result.targetIdentifier
        let defaultTargetIdentifier = normalizeScopeID(capturedTargetIdentifier)
        let now = Date().timeIntervalSince1970
        var seeds: [NetworkEntrySeed] = []

        func responseBodyLocator(
            targetIdentifier: String?,
            frameID: String?,
            url: String
        ) -> NetworkDeferredBodyLocator? {
            guard let targetIdentifier, let frameID else {
                return nil
            }
            return .pageResource(
                targetIdentifier: targetIdentifier,
                frameID: frameID,
                url: url
            )
        }

        func appendResources(
            from subtree: WITransportFrameResourceTree,
            parentSessionID: String,
            parentTargetIdentifier: String?
        ) {
            let scopedTargetIdentifiers = Set(
                subtree.resources.compactMap { resource in
                    normalizeScopeID(resource.targetId)
                }
            )
            let subtreeTargetIdentifier: String?
            if scopedTargetIdentifiers.count == 1 {
                subtreeTargetIdentifier = scopedTargetIdentifiers.first ?? parentTargetIdentifier
            } else {
                subtreeTargetIdentifier = parentTargetIdentifier
            }
            let subtreeSessionID = subtreeTargetIdentifier.map(defaultSessionID) ?? parentSessionID
            let frameID = normalizeScopeID(subtree.frame.id)
            seeds.append(
                NetworkEntrySeed(
                    kind: .historical,
                    sessionID: subtreeSessionID,
                    requestID: allocateRequestID(),
                    url: subtree.frame.url,
                    method: "UNKNOWN",
                    startTimestamp: now,
                    statusCode: nil,
                    statusText: "",
                    mimeType: subtree.frame.mimeType,
                    requestType: WITransportPageResourceType.document.rawValue,
                    phase: .completed,
                    responseBody: responseBodyLocator(
                        targetIdentifier: subtreeTargetIdentifier,
                        frameID: frameID,
                        url: subtree.frame.url
                    )
                    .map {
                        NetworkBody(
                            kind: .other,
                            preview: nil,
                            full: nil,
                            size: nil,
                            isBase64Encoded: false,
                            isTruncated: false,
                            summary: nil,
                            deferredLocator: $0,
                            formEntries: [],
                            fetchState: .inline,
                            role: .response
                        )
                    }
                )
            )

            for resource in subtree.resources {
                let resourceTargetIdentifier = normalizeScopeID(resource.targetId)
                let ownerSessionID = resourceTargetIdentifier.map(defaultSessionID) ?? subtreeSessionID
                let resolvedTargetIdentifier = resourceTargetIdentifier ?? subtreeTargetIdentifier
                let isFailed = (resource.failed ?? false) || (resource.canceled ?? false)
                seeds.append(
                    NetworkEntrySeed(
                        kind: .historical,
                        sessionID: ownerSessionID,
                        requestID: allocateRequestID(),
                        url: resource.url,
                        method: "UNKNOWN",
                        startTimestamp: now,
                        statusCode: isFailed ? 0 : nil,
                        statusText: resource.canceled == true ? "Canceled" : "",
                        mimeType: resource.mimeType,
                        errorDescription: resource.canceled == true ? "Canceled" : nil,
                        requestType: resource.type.rawValue,
                        phase: isFailed ? .failed : .completed,
                        responseBody: isFailed ? nil : responseBodyLocator(
                            targetIdentifier: resolvedTargetIdentifier,
                            frameID: frameID,
                            url: resource.url
                        )
                        .map {
                            NetworkBody(
                                kind: .other,
                                preview: nil,
                                full: nil,
                                size: nil,
                                isBase64Encoded: false,
                                isTruncated: false,
                                summary: nil,
                                deferredLocator: $0,
                                formEntries: [],
                                fetchState: .inline,
                                role: .response
                            )
                        }
                    )
                )
            }

            for childFrame in subtree.childFrames ?? [] {
                appendResources(
                    from: childFrame,
                    parentSessionID: subtreeSessionID,
                    parentTargetIdentifier: subtreeTargetIdentifier
                )
            }
        }

        appendResources(
            from: result.response.frameTree,
            parentSessionID: defaultSessionID(capturedTargetIdentifier),
            parentTargetIdentifier: defaultTargetIdentifier
        )
        return NetworkBootstrapLoad(seeds: seeds)
    }
}

private func makeDeferredRequestBody(
    method: String,
    rawRequestID: String?,
    targetIdentifier: String?
) -> NetworkBody? {
    guard let rawRequestID, requestMethodMayCarryBody(method) else {
        return nil
    }
    return NetworkBody(
        kind: .text,
        preview: nil,
        full: nil,
        size: nil,
        isBase64Encoded: false,
        isTruncated: true,
        summary: nil,
        deferredLocator: .networkRequest(id: rawRequestID, targetIdentifier: targetIdentifier),
        formEntries: [],
        fetchState: .inline,
        role: .request
    )
}

private func requestMethodMayCarryBody(_ method: String) -> Bool {
    switch method.uppercased() {
    case "GET", "HEAD":
        false
    default:
        true
    }
}
