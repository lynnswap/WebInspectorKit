import WebInspectorProxyKit

extension WebInspectorModelContext {
    /// Clears canonical Network membership for every context at the same
    /// container commit boundary.
    public nonisolated(nonsending) func clearNetworkRequests() async throws {
        preconditionOwnerIsolation()
        try requireConfigured(.network)
        try await container.core.clearNetworkRequests()
    }

    package func loadCanonicalResponseBody(
        _ body: NetworkBody,
        isolation: isolated (any Actor) = #isolation
    ) async throws -> NetworkBody {
        _ = isolation
        preconditionOwnerIsolation()
        try requireConfigured(.network)
        guard let requestID = body.boundCanonicalRequestID,
            let request: NetworkRequest = registeredModel(for: requestID),
            request.responseBody === body,
            request.modelContext === self
        else {
            throw WebInspectorModelError.staleModel
        }

        let coreForNewFetch: WebInspectorModelContainerCore?
        if case .available = body.phase {
            guard request.canFetchResponseBody else {
                throw WebInspectorModelError.commandRejected(
                    method: "Network.getResponseBody",
                    message: "The response body is not available for this request."
                )
            }
            coreForNewFetch = container.core
        } else {
            coreForNewFetch = nil
        }

        let lease: NetworkBody.ResponseFetchLease
        switch body.acquireResponseFetch() {
        case .loaded:
            return body
        case let .failed(failure):
            try Self.throwResponseBodyFailure(failure)
        case let .waiter(existingLease):
            lease = existingLease
        case let .owner(newLease):
            guard let core = coreForNewFetch else {
                preconditionFailure(
                    "An available NetworkBody lost its Container Core preflight."
                )
            }
            lease = newLease
            let completion = newLease.completion
            let task = Task { [weak body] in
                _ = isolation
                let result = await Self.loadResponseBody(
                    from: core,
                    requestID: requestID.canonicalStorage
                )
                guard let body else {
                    completion.fulfill(
                        .failure(WebInspectorProxyError.staleIdentifier)
                    )
                    return
                }
                body.finishResponseFetch(result, for: newLease)
            }
            body.installResponseFetchTask(task, for: newLease)
        }

        do {
            _ = try await lease.completion.value()
        } catch WebInspectorProxyError.staleIdentifier {
            guard body.isCurrentResponseFetch(lease) else {
                throw WebInspectorModelError.staleModel
            }
            throw WebInspectorProxyError.staleIdentifier
        }
        guard let current: NetworkRequest = registeredModel(for: requestID),
            current === request,
            current.responseBody === body,
            body.isCurrentResponseFetch(lease)
        else {
            throw WebInspectorModelError.staleModel
        }
        return body
    }

    private nonisolated static func loadResponseBody(
        from core: WebInspectorModelContainerCore,
        requestID: CanonicalNetworkRequestIDStorage
    ) async -> Result<Network.Body, WebInspectorProxyError> {
        do {
            return .success(
                try await core.loadNetworkResponseBody(for: requestID)
            )
        } catch is CancellationError {
            return .failure(.staleIdentifier)
        } catch let error as WebInspectorNetworkResponseBodyCommandError {
            switch error {
            case .closed:
                return .failure(.closed)
            case .staleRequest, .requestNotFound, .staleResponse:
                return .failure(.staleIdentifier)
            case let .proxy(proxyError):
                return .failure(proxyError)
            case .detached, .domainNotConfigured, .foreignStore,
                .agentTargetUnavailable, .responseMissing,
                .responseNotFinished, .webSocketIneligible,
                .authorization, .invalidReply:
                return .failure(.commandFailed(
                    domain: "Network",
                    method: "getResponseBody",
                    message: String(describing: error)
                ))
            }
        } catch {
            return .failure(.commandFailed(
                domain: "Network",
                method: "getResponseBody",
                message: String(describing: error)
            ))
        }
    }

    private nonisolated static func throwResponseBodyFailure(
        _ failure: NetworkBody.Failure
    ) throws -> Never {
        switch failure {
        case .loadingFailed:
            throw failure
        case let .model(error):
            throw error
        case let .proxy(error):
            throw error
        }
    }
}
