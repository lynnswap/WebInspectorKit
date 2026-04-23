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
            switch locator {
            case .networkRequest(let requestID, let targetIdentifier):
                switch role {
                case .request:
                    let response = try await codec.decode(
                        NetworkGetRequestPostDataResponse.self,
                        from: try await session.sendPageData(
                            method: WITransportMethod.Network.getRequestPostData,
                            targetIdentifier: targetIdentifier,
                            parametersData: try await codec.encode(
                                NetworkRequestIDParameters(requestId: requestID)
                            )
                        )
                    )
                    guard !response.postData.isEmpty else {
                        return .bodyUnavailable
                    }
                    return .fetched(
                        NetworkBody(
                            kind: .text,
                            preview: nil,
                            full: response.postData,
                            size: response.postData.utf8.count,
                            isBase64Encoded: false,
                            isTruncated: false,
                            summary: nil,
                            formEntries: [],
                            fetchState: .full,
                            role: .request
                        )
                    )
                case .response:
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
                }
            case .pageResource(let targetIdentifier, let frameID, let url):
                guard role == .response else {
                    return .bodyUnavailable
                }
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
            case .opaqueHandle:
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
        allocateRequestID: @escaping () -> Int,
        defaultSessionID: @escaping (String?) -> String,
        normalizeScopeID: @escaping (String?) -> String?,
        logFailure: @escaping @MainActor (String) -> Void
    ) async throws -> NetworkBootstrapLoad {
        if session.shouldAttemptStableNetworkBootstrap() {
            do {
                let load = try await StableBootstrapSource().load(
                    using: session,
                    targetIdentifier: targetIdentifier,
                    allocateRequestID: allocateRequestID,
                    defaultSessionID: defaultSessionID,
                    normalizeScopeID: normalizeScopeID
                )
                session.markStableNetworkBootstrapAvailable()
                return load
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if shouldDisableStableBootstrap(after: error),
                   session.markStableNetworkBootstrapUnavailable() {
                    logFailure("stable network bootstrap disabled: \(error.localizedDescription)")
                }
            }
        }

        do {
            return try await HistoricalBootstrapSource().load(
                using: session,
                targetIdentifier: targetIdentifier,
                allocateRequestID: allocateRequestID,
                defaultSessionID: defaultSessionID,
                normalizeScopeID: normalizeScopeID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logFailure("historical network bootstrap skipped: \(error.localizedDescription)")
            return NetworkBootstrapLoad(snapshots: [])
        }
    }
}

private extension NetworkTransportClient {
    func shouldDisableStableBootstrap(after error: any Error) -> Bool {
        guard let transportError = error as? WITransportError else {
            return false
        }
        switch transportError {
        case .unsupported:
            return true
        case .remoteError:
            return true
        case .invalidResponse:
            return true
        default:
            return false
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

private struct NetworkGetRequestPostDataResponse: Decodable, Sendable {
    let postData: String
}

private struct PageGetResourceContentResponse: Decodable, Sendable {
    let content: String
    let base64Encoded: Bool
}
