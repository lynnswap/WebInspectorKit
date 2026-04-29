import Foundation
import WebInspectorEngine

package struct NetworkBootstrapLoad {
    package let snapshots: [NetworkEntry.Snapshot]
    package let bindings: [NetworkTimelineResolver.Binding]

    package init(
        snapshots: [NetworkEntry.Snapshot],
        bindings: [NetworkTimelineResolver.Binding] = []
    ) {
        self.snapshots = snapshots
        self.bindings = bindings
    }
}

@MainActor
package protocol NetworkBootstrapSource {
    func load(
        using session: WITransportSession,
        targetIdentifier: String,
        allocateRequestID: @escaping @MainActor () -> Int,
        defaultSessionID: @escaping @MainActor (String?) -> String,
        normalizeScopeID: @escaping @MainActor (String?) -> String?
    ) async throws -> NetworkBootstrapLoad
}

@MainActor
package struct StableBootstrapSource: NetworkBootstrapSource {
    private let codec = WITransportCodec.shared

    package init() {}

    package func load(
        using session: WITransportSession,
        targetIdentifier: String,
        allocateRequestID: @escaping @MainActor () -> Int,
        defaultSessionID: @escaping @MainActor (String?) -> String,
        normalizeScopeID: @escaping @MainActor (String?) -> String?
    ) async throws -> NetworkBootstrapLoad {
        let result = try await session.sendPageData(
            method: WITransportMethod.Network.getBootstrapSnapshot,
            targetIdentifier: targetIdentifier
        )
        let snapshot = try await codec.decode(
            NetworkGetBootstrapSnapshotResponse.self,
            from: result
        )
        let syntheticDefaultSessionID = defaultSessionID(nil)
        let now = Date().timeIntervalSince1970
        let snapshotsAndBindings = snapshot.resources.map { resource -> (NetworkEntry.Snapshot, NetworkTimelineResolver.Binding?) in
            let normalizedOwnerSessionID = normalizeScopeID(resource.ownerSessionID)
            let resolvedFrameID = normalizeScopeID(resource.bodyFetchDescriptor?.frameId)
                ?? normalizeScopeID(resource.frameID)
            let resolvedOwnerSessionID = normalizedOwnerSessionID
                ?? normalizeScopeID(resource.targetIdentifier)
                ?? defaultSessionID(targetIdentifier)
            let resolvedTargetIdentifier = normalizeScopeID(resource.bodyFetchDescriptor?.targetIdentifier)
                ?? normalizeScopeID(resource.targetIdentifier)
                ?? ((resolvedOwnerSessionID == defaultSessionID(targetIdentifier)
                    || resolvedOwnerSessionID == syntheticDefaultSessionID)
                    ? normalizeScopeID(targetIdentifier)
                    : normalizedOwnerSessionID)
            let resolvedRequestTargetIdentifier = normalizeScopeID(resource.targetIdentifier)
                ?? ((resolvedOwnerSessionID == defaultSessionID(targetIdentifier)
                    || resolvedOwnerSessionID == syntheticDefaultSessionID)
                    ? normalizeScopeID(targetIdentifier)
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

            let entrySnapshot = NetworkEntry.Snapshot(
                sessionID: resolvedOwnerSessionID,
                requestID: requestID,
                request: .init(
                    url: resource.url,
                    method: resource.method.isEmpty ? "UNKNOWN" : resource.method.uppercased(),
                    headers: NetworkHeaders(dictionary: resource.requestHeaders ?? [:]),
                    body: makeDeferredRequestBody(
                        method: resource.method,
                        rawRequestID: normalizeScopeID(resource.rawRequestID),
                        targetIdentifier: resolvedRequestTargetIdentifier
                    ),
                    bodyBytesSent: nil,
                    type: resource.requestType,
                    wallTime: nil
                ),
                response: .init(
                    statusCode: statusCode,
                    statusText: statusText,
                    mimeType: resource.mimeType,
                    headers: NetworkHeaders(dictionary: resource.responseHeaders ?? [:]),
                    body: responseBodyLocator.map {
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
                    },
                    blockedCookies: [],
                    errorDescription: errorDescription
                ),
                transfer: .init(
                    startTimestamp: now,
                    endTimestamp: phase == .pending ? nil : now,
                    duration: phase == .pending ? nil : 0,
                    encodedBodyLength: nil,
                    decodedBodyLength: nil,
                    phase: phase
                )
            )

            let binding: NetworkTimelineResolver.Binding?
            if phase == .pending, let rawRequestID = normalizeScopeID(resource.rawRequestID) {
                binding = .init(
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

            return (entrySnapshot, binding)
        }

        return NetworkBootstrapLoad(
            snapshots: snapshotsAndBindings.map(\.0),
            bindings: snapshotsAndBindings.compactMap(\.1)
        )
    }
}

private struct NetworkGetBootstrapSnapshotResponse: Decodable, Sendable {
    let resources: [WITransportNetworkBootstrapResource]
}

@MainActor
package struct HistoricalBootstrapSource: NetworkBootstrapSource {
    private let codec = WITransportCodec.shared

    package init() {}

    package func load(
        using session: WITransportSession,
        targetIdentifier: String,
        allocateRequestID: @escaping @MainActor () -> Int,
        defaultSessionID: @escaping @MainActor (String?) -> String,
        normalizeScopeID: @escaping @MainActor (String?) -> String?
    ) async throws -> NetworkBootstrapLoad {
        let result = try await session.sendPageData(
            method: WITransportMethod.Page.getResourceTree,
            targetIdentifier: targetIdentifier
        )
        let response = try await codec.decode(
            WITransportPageGetResourceTreeResponse.self,
            from: result
        )
        let defaultTargetIdentifier = normalizeScopeID(targetIdentifier)
        let now = Date().timeIntervalSince1970
        var snapshots: [NetworkEntry.Snapshot] = []

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
            snapshots.append(
                NetworkEntry.Snapshot(
                    sessionID: subtreeSessionID,
                    requestID: allocateRequestID(),
                    request: .init(
                        url: subtree.frame.url,
                        method: "UNKNOWN",
                        headers: NetworkHeaders(),
                        body: nil,
                        bodyBytesSent: nil,
                        type: WITransportPageResourceType.document.rawValue,
                        wallTime: nil
                    ),
                    response: .init(
                        statusCode: nil,
                        statusText: "",
                        mimeType: subtree.frame.mimeType,
                        headers: NetworkHeaders(),
                        body: responseBodyLocator(
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
                        },
                        blockedCookies: [],
                        errorDescription: nil
                    ),
                    transfer: .init(
                        startTimestamp: now,
                        endTimestamp: now,
                        duration: 0,
                        encodedBodyLength: nil,
                        decodedBodyLength: nil,
                        phase: .completed
                    )
                )
            )

            for resource in subtree.resources {
                let resourceTargetIdentifier = normalizeScopeID(resource.targetId)
                let ownerSessionID = resourceTargetIdentifier.map(defaultSessionID) ?? subtreeSessionID
                let resolvedTargetIdentifier = resourceTargetIdentifier ?? subtreeTargetIdentifier
                let isFailed = (resource.failed ?? false) || (resource.canceled ?? false)
                snapshots.append(
                    NetworkEntry.Snapshot(
                        sessionID: ownerSessionID,
                        requestID: allocateRequestID(),
                        request: .init(
                            url: resource.url,
                            method: "UNKNOWN",
                            headers: NetworkHeaders(),
                            body: nil,
                            bodyBytesSent: nil,
                            type: resource.type.rawValue,
                            wallTime: nil
                        ),
                        response: .init(
                            statusCode: isFailed ? 0 : nil,
                            statusText: resource.canceled == true ? "Canceled" : "",
                            mimeType: resource.mimeType,
                            headers: NetworkHeaders(),
                            body: isFailed ? nil : responseBodyLocator(
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
                            },
                            blockedCookies: [],
                            errorDescription: resource.canceled == true ? "Canceled" : nil
                        ),
                        transfer: .init(
                            startTimestamp: now,
                            endTimestamp: now,
                            duration: 0,
                            encodedBodyLength: nil,
                            decodedBodyLength: nil,
                            phase: isFailed ? .failed : .completed
                        )
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
            from: response.frameTree,
            parentSessionID: defaultSessionID(targetIdentifier),
            parentTargetIdentifier: defaultTargetIdentifier
        )
        return NetworkBootstrapLoad(snapshots: snapshots)
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
