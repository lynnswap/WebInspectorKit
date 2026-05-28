import WebInspectorTransport

@MainActor
package final class ProtocolCommandChannel {
    private let transport: TransportSession
    private let isCurrent: @MainActor () -> Bool
    private let isAttached: @MainActor () -> Bool
    private let appliedSequence: @MainActor () -> UInt64
    private let shouldEnableCompatibilityCSS: @MainActor (ProtocolTargetIdentifier) -> Bool
    private let markTargetDomainEnabled: @MainActor (ProtocolTargetIdentifier, ProtocolTargetCapabilities) -> Void

    package init(
        transport: TransportSession,
        isCurrent: @escaping @MainActor () -> Bool,
        isAttached: @escaping @MainActor () -> Bool,
        appliedSequence: @escaping @MainActor () -> UInt64,
        shouldEnableCompatibilityCSS: @escaping @MainActor (ProtocolTargetIdentifier) -> Bool,
        markTargetDomainEnabled: @escaping @MainActor (ProtocolTargetIdentifier, ProtocolTargetCapabilities) -> Void
    ) {
        self.transport = transport
        self.isCurrent = isCurrent
        self.isAttached = isAttached
        self.appliedSequence = appliedSequence
        self.shouldEnableCompatibilityCSS = shouldEnableCompatibilityCSS
        self.markTargetDomainEnabled = markTargetDomainEnabled
    }

    package var currentAppliedSequence: UInt64 {
        appliedSequence()
    }

    package var acceptsActiveCommands: Bool {
        isAttached()
    }

    package func snapshot() async -> TransportSnapshot {
        await transport.snapshot()
    }

    package func requireAttached() throws {
        guard isAttached() else {
            throw InspectorSessionError("Inspector session is not attached.")
        }
    }

    @discardableResult
    package func send(_ command: ProtocolCommand) async throws -> ProtocolCommandResult {
        guard isCurrent() else {
            throw TransportError.transportClosed
        }
        let result: ProtocolCommandResult
        do {
            result = try await transport.send(command)
        } catch {
            InspectorRuntimeLog.error("command.error method=\(command.method) routing=\(command.routing) error=\(error)")
            throw error
        }
        guard isCurrent() else {
            throw TransportError.transportClosed
        }
        return result
    }

    package func cssAgentShouldBeEnabledForCompatibility(targetID: ProtocolTargetIdentifier) -> Bool {
        shouldEnableCompatibilityCSS(targetID)
    }

    package func markEnabled(_ domain: ProtocolTargetCapabilities, targetID: ProtocolTargetIdentifier) {
        markTargetDomainEnabled(targetID, domain)
    }
}
