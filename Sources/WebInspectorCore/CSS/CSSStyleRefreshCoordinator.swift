import Foundation
import WebInspectorTransport

@MainActor
final class CSSStyleRefreshCoordinator {
    private enum RefreshCommandResult: Sendable {
        case success(ProtocolCommand.Result)
        case failure(RefreshCommandFailure)

        var failure: RefreshCommandFailure? {
            guard case let .failure(failure) = self else {
                return nil
            }
            return failure
        }

        func requireSuccess() throws -> ProtocolCommand.Result {
            switch self {
            case let .success(result):
                return result
            case let .failure(failure):
                throw failure.error
            }
        }
    }

    private enum RefreshCommandFailure: Error, Sendable {
        case cancellation
        case transport(TransportSession.Error)
        case inspector(InspectorSessionError)
        case other(String)

        init(_ error: any Error) {
            if error is CancellationError {
                self = .cancellation
            } else if let error = error as? TransportSession.Error {
                self = .transport(error)
            } else if let error = error as? InspectorSessionError {
                self = .inspector(error)
            } else {
                self = .other(String(describing: error))
            }
        }

        var error: any Error {
            switch self {
            case .cancellation:
                CancellationError()
            case let .transport(error):
                error
            case let .inspector(error):
                error
            case let .other(message):
                InspectorSessionError(message)
            }
        }

        var isCancellation: Bool {
            guard case .cancellation = self else {
                return false
            }
            return true
        }
    }

    private var commandChannel: ProtocolCommandChannel?
    private let protocolCommands: CSSProtocolCommands

    init(protocolCommands: CSSProtocolCommands = CSSProtocolCommands()) {
        self.protocolCommands = protocolCommands
    }

    func bindProtocolChannel(_ commandChannel: ProtocolCommandChannel) {
        self.commandChannel = commandChannel
    }

    func unbindProtocolChannel() {
        commandChannel = nil
    }

    @discardableResult
    func perform(_ intent: CSSCommandIntent) async throws -> ProtocolCommand.Result {
        let commandChannel = try requireCommandChannel()
        return try await commandChannel.send(try protocolCommands.command(for: intent))
    }

    func fetchRefreshResults(for identity: CSSNodeStyleIdentity) async throws -> CSSSession.RefreshResults {
        do {
            return try await fetchRefreshResultsWithoutCompatibilityRetry(for: identity)
        } catch {
            guard shouldRetryAfterEnablingCSSAgent(error) else {
                throw error
            }
            try await enableAgentForCompatibility(targetID: identity.targetID)
            return try await fetchRefreshResultsWithoutCompatibilityRetry(for: identity)
        }
    }

    func setStyleTextResult(from result: ProtocolCommand.Result) throws -> CSSStylePayload {
        try protocolCommands.setStyleTextResult(from: result)
    }

    private func fetchRefreshResultsWithoutCompatibilityRetry(
        for identity: CSSNodeStyleIdentity
    ) async throws -> CSSSession.RefreshResults {
        async let matched = performRefreshCommand(.getMatchedStyles(identity: identity))
        async let inline = performRefreshCommand(.getInlineStyles(identity: identity))
        async let computed = performRefreshCommand(.getComputedStyle(identity: identity))
        let results = await (matched, inline, computed)
        let failures = [results.0, results.1, results.2].compactMap(\.failure)
        if failures.contains(where: \.isCancellation) {
            throw CancellationError()
        }
        if let retryFailure = failures.first(where: { shouldRetryAfterEnablingCSSAgent($0.error) }) {
            throw retryFailure.error
        }
        if let failure = failures.first {
            throw failure.error
        }
        let matchedResult = try results.0.requireSuccess()
        let inlineResult = try results.1.requireSuccess()
        let computedResult = try results.2.requireSuccess()
        return CSSSession.RefreshResults(
            matched: try protocolCommands.matchedStyles(from: matchedResult),
            inline: try protocolCommands.inlineStyles(from: inlineResult),
            computed: try protocolCommands.computedStyles(from: computedResult)
        )
    }

    private func performRefreshCommand(_ intent: CSSCommandIntent) async -> RefreshCommandResult {
        do {
            return .success(try await perform(intent))
        } catch {
            return .failure(RefreshCommandFailure(error))
        }
    }

    private func enableAgentForCompatibility(targetID: ProtocolTarget.ID) async throws {
        let commandChannel = try requireCommandChannel()
        guard commandChannel.cssAgentShouldBeEnabledForCompatibility(targetID: targetID) else {
            return
        }

        // Do not enable the WebKit CSS agent proactively. On current simulator
        // WebContent, CSS.enable can crash while synchronizing stylesheet
        // headers during page load, while the read commands work without it.
        _ = try await perform(.enable(targetID: targetID))
        commandChannel.markEnabled(.css, targetID: targetID)
    }

    private func shouldRetryAfterEnablingCSSAgent(_ error: any Error) -> Bool {
        guard case let TransportSession.Error.remoteError(method, _, message) = error,
              method.hasPrefix("CSS.") else {
            return false
        }

        let normalizedMessage = message.lowercased()
        return normalizedMessage.contains("enable")
            || normalizedMessage.contains("enabled")
    }

    private func requireCommandChannel() throws -> ProtocolCommandChannel {
        guard let commandChannel else {
            throw InspectorSessionError("Inspector session is not attached.")
        }
        try commandChannel.requireAttached()
        return commandChannel
    }
}
