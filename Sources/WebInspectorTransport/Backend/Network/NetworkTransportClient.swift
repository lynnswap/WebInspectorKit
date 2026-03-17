import Foundation
import WebInspectorEngine

@MainActor
package struct NetworkTransportClient {
    package init() {}

    package func fetchBodyResult(
        using lease: WISharedTransportRegistry.Lease,
        locator: NetworkDeferredBodyLocator,
        role: NetworkBody.Role
    ) async -> WINetworkBodyFetchResult {
        do {
            try await lease.ensureAttached()
            try await lease.ensureNetworkEventIngress()
            switch locator {
            case .networkRequest(let requestID, let targetIdentifier):
                switch role {
                case .request:
                    let response: WITransportCommands.Network.GetRequestPostData.Response
                    if let targetIdentifier {
                        response = try await lease.sendPage(
                            WITransportCommands.Network.GetRequestPostData(requestId: requestID),
                            targetIdentifier: targetIdentifier
                        )
                    } else {
                        response = try await lease.sendPage(
                            WITransportCommands.Network.GetRequestPostData(requestId: requestID)
                        )
                    }
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
                    let response: WITransportCommands.Network.GetResponseBody.Response
                    if let targetIdentifier {
                        response = try await lease.sendPage(
                            WITransportCommands.Network.GetResponseBody(requestId: requestID),
                            targetIdentifier: targetIdentifier
                        )
                    } else {
                        response = try await lease.sendPage(
                            WITransportCommands.Network.GetResponseBody(requestId: requestID)
                        )
                    }
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
                let response: WITransportCommands.Page.GetResourceContent.Response
                if let targetIdentifier {
                    response = try await lease.sendPage(
                        WITransportCommands.Page.GetResourceContent(frameId: frameID, url: url),
                        targetIdentifier: targetIdentifier
                    )
                } else {
                    response = try await lease.sendPage(
                        WITransportCommands.Page.GetResourceContent(frameId: frameID, url: url)
                    )
                }
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
            case .remoteError, .requestTimedOut, .invalidResponse, .invalidCommandEncoding, .invalidChannelScope:
                return .bodyUnavailable
            }
        } catch {
            return .bodyUnavailable
        }
    }

    package func loadBootstrapResources(
        using lease: WISharedTransportRegistry.Lease,
        allocateRequestID: @escaping () -> Int,
        defaultSessionID: @escaping (String?) -> String,
        normalizeScopeID: @escaping (String?) -> String?,
        logFailure: @escaping @MainActor (String) -> Void
    ) async throws -> NetworkBootstrapLoad {
        if lease.supportSnapshot.capabilities.contains(.networkBootstrapSnapshot) {
            do {
                return try await StableBootstrapSource().load(
                    using: lease,
                    allocateRequestID: allocateRequestID,
                    defaultSessionID: defaultSessionID,
                    normalizeScopeID: normalizeScopeID
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logFailure("stable network bootstrap skipped: \(error.localizedDescription)")
            }
        }

        do {
            return try await HistoricalBootstrapSource().load(
                using: lease,
                allocateRequestID: allocateRequestID,
                defaultSessionID: defaultSessionID,
                normalizeScopeID: normalizeScopeID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logFailure("historical network bootstrap skipped: \(error.localizedDescription)")
            return NetworkBootstrapLoad(seeds: [])
        }
    }
}
