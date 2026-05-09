import Foundation
import WebInspectorEngine

@MainActor
package struct NetworkTransportClient {
    private let codec = WITransportCodec.shared

    package init() {}

    package func fetchBodyResult(
        using session: WITransportSession,
        locator: NetworkDeferredBodyLocator,
        role: NetworkBody.Role
    ) async -> WINetworkBodyFetchResult {
        do {
            switch (locator, role) {
            case (.networkRequest, .request):
                return .bodyUnavailable
            case let (.networkRequest(requestID, targetIdentifier), .response):
                let response = try await codec.decode(
                    NetworkGetResponseBodyResponse.self,
                    from: try await session.sendPageData(
                        method: WITransportMethod.Network.getResponseBody,
                        targetIdentifier: targetIdentifier,
                        parametersData: try await codec.encode(
                            NetworkRequestIDParameters(requestId: requestID)
                        )
                    )
                )
                return .fetched(
                    NetworkBody(
                        kind: response.base64Encoded ? .binary : .text,
                        preview: nil,
                        full: response.body,
                        size: nil,
                        isBase64Encoded: response.base64Encoded,
                        isTruncated: false,
                        summary: nil,
                        formEntries: [],
                        fetchState: .full,
                        role: .response
                    )
                )
            case let (.pageResource(targetIdentifier, frameID, url), .response):
                let response = try await codec.decode(
                    PageGetResourceContentResponse.self,
                    from: try await session.sendPageData(
                        method: WITransportMethod.Page.getResourceContent,
                        targetIdentifier: targetIdentifier,
                        parametersData: try await codec.encode(
                            PageGetResourceContentParameters(frameId: frameID, url: url)
                        )
                    )
                )
                return .fetched(
                    NetworkBody(
                        kind: response.base64Encoded ? .binary : .text,
                        preview: nil,
                        full: response.content,
                        size: nil,
                        isBase64Encoded: response.base64Encoded,
                        isTruncated: false,
                        summary: nil,
                        formEntries: [],
                        fetchState: .full,
                        role: .response
                    )
                )
            case (.pageResource, .request), (.opaqueHandle, _):
                return .bodyUnavailable
            }
        } catch let error as WITransportError {
            switch error {
            case .unsupported, .alreadyAttached, .notAttached, .attachFailed, .pageTargetUnavailable, .transportClosed:
                return .agentUnavailable
            case .remoteError, .requestTimedOut, .invalidResponse, .invalidCommandEncoding:
                return .bodyUnavailable
            }
        } catch {
            return .bodyUnavailable
        }
    }

    package func loadBootstrapResources(
        using session: WITransportSession,
        targetIdentifier: String,
        allocateRequestID: @escaping @MainActor () -> Int,
        defaultSessionID: @escaping @MainActor (String?) -> String,
        normalizeScopeID: @escaping @MainActor (String?) -> String?,
        logFailure: @escaping @MainActor (String) -> Void
    ) async throws -> NetworkBootstrapLoad {
        do {
            return try await PageResourceTreeBootstrapSource().load(
                using: session,
                targetIdentifier: targetIdentifier,
                allocateRequestID: allocateRequestID,
                defaultSessionID: defaultSessionID,
                normalizeScopeID: normalizeScopeID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logFailure("resource tree network bootstrap skipped: \(error.localizedDescription)")
            return NetworkBootstrapLoad(snapshots: [])
        }
    }
}

private struct NetworkRequestIDParameters: Encodable, Sendable {
    let requestId: String
}

private struct PageGetResourceContentParameters: Encodable, Sendable {
    let frameId: String
    let url: String
}

private struct NetworkGetResponseBodyResponse: Decodable, Sendable {
    let body: String
    let base64Encoded: Bool
}

private struct PageGetResourceContentResponse: Decodable, Sendable {
    let content: String
    let base64Encoded: Bool
}
