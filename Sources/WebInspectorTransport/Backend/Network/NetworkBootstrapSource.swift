import Foundation
import WebInspectorEngine

package struct NetworkBootstrapLoad {
    package let snapshots: [NetworkEntry.Snapshot]

    package init(snapshots: [NetworkEntry.Snapshot]) {
        self.snapshots = snapshots
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
package struct PageResourceTreeBootstrapSource: NetworkBootstrapSource {
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
