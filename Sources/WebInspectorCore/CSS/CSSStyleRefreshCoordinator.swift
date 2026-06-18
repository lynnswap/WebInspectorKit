import Foundation
import WebInspectorTransport

extension CSSSession {
    @MainActor
    final class StyleRefreshCoordinator {
    private enum RefreshCommandResult: Sendable {
        case success(ProtocolCommand.Result)
        case failure(RefreshCommandFailure)
    }

    private enum RefreshCommandKind: Sendable {
        case matched
        case inline
        case computed
    }

    private struct RefreshCommandOutput: Sendable {
        var kind: RefreshCommandKind
        var result: RefreshCommandResult
    }

    private struct RefreshCommandResults: Sendable {
        var matched: ProtocolCommand.Result?
        var inline: ProtocolCommand.Result?
        var computed: ProtocolCommand.Result?
    }

    private enum RefreshCommandFailure: Error, Sendable {
        case cancellation
        case transport(TransportSession.Error)
        case inspector(InspectorSession.Error)
        case other(String)

        init(_ error: any Error) {
            if error is CancellationError {
                self = .cancellation
            } else if let error = error as? TransportSession.Error {
                self = .transport(error)
            } else if let error = error as? InspectorSession.Error {
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
                InspectorSession.Error(message)
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
    func perform(_ intent: CSSCommand.Intent) async throws -> ProtocolCommand.Result {
        let commandChannel = try requireCommandChannel()
        return try await commandChannel.send(try protocolCommands.command(for: intent))
    }

    func fetchRefreshResults(for id: CSSNodeStyles.ID) async throws -> CSSSession.RefreshResults {
        do {
            return try await fetchRefreshResultsWithoutCompatibilityRetry(for: id)
        } catch {
            guard shouldRetryAfterEnablingCSSAgent(error) else {
                throw error
            }
            try await enableAgentForCompatibility(targetID: id.targetID)
            return try await fetchRefreshResultsWithoutCompatibilityRetry(for: id)
        }
    }

    func setStyleTextResult(from result: ProtocolCommand.Result) throws -> CSSStyle.Payload {
        try protocolCommands.setStyleTextResult(from: result)
    }

    private func fetchRefreshResultsWithoutCompatibilityRetry(
        for id: CSSNodeStyles.ID
    ) async throws -> CSSSession.RefreshResults {
        let results = try await collectRefreshCommandResults(for: id)
        guard let matchedResult = results.matched,
              let inlineResult = results.inline,
              let computedResult = results.computed else {
            throw InspectorSession.Error("CSS style refresh did not produce all required results.")
        }
        return CSSSession.RefreshResults(
            matched: try protocolCommands.matchedStyles(from: matchedResult),
            inline: try protocolCommands.inlineStyles(from: inlineResult),
            computed: try protocolCommands.computedStyles(from: computedResult)
        )
    }

    private func collectRefreshCommandResults(
        for id: CSSNodeStyles.ID
    ) async throws -> RefreshCommandResults {
        try await withThrowingTaskGroup(of: RefreshCommandOutput.self) { group in
            group.addTask {
                await RefreshCommandOutput(
                    kind: .matched,
                    result: self.performRefreshCommand(.getMatchedStyles(id: id))
                )
            }
            group.addTask {
                await RefreshCommandOutput(
                    kind: .inline,
                    result: self.performRefreshCommand(.getInlineStyles(id: id))
                )
            }
            group.addTask {
                await RefreshCommandOutput(
                    kind: .computed,
                    result: self.performRefreshCommand(.getComputedStyle(id: id))
                )
            }

            var collected = RefreshCommandResults()
            var firstNonRetryFailure: RefreshCommandFailure?
            while let output = try await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    throw CancellationError()
                }
                switch output.result {
                case let .success(result):
                    switch output.kind {
                    case .matched:
                        collected.matched = result
                    case .inline:
                        collected.inline = result
                    case .computed:
                        collected.computed = result
                    }
                case let .failure(failure):
                    if failure.isCancellation {
                        group.cancelAll()
                        throw CancellationError()
                    }
                    if shouldRetryAfterEnablingCSSAgent(failure.error) {
                        group.cancelAll()
                        throw failure.error
                    }
                    if firstNonRetryFailure == nil {
                        firstNonRetryFailure = failure
                    }
                }
            }

            if let firstNonRetryFailure {
                throw firstNonRetryFailure.error
            }
            return collected
        }
    }

    private func performRefreshCommand(_ intent: CSSCommand.Intent) async -> RefreshCommandResult {
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
            throw InspectorSession.Error("Inspector session is not attached.")
        }
        try commandChannel.requireAttached()
        return commandChannel
    }
    }
}
