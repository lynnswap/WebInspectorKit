import WebInspectorTransport

@MainActor
package final class ProtocolCommandChannel {
    private let transport: TransportSession
    private let isCurrent: @MainActor () -> Bool
    private let isAttached: @MainActor () -> Bool
    private let appliedSequence: @MainActor () -> UInt64
    private let shouldEnableCompatibilityCSS: @MainActor (ProtocolTarget.ID) -> Bool
    private let markTargetDomainEnabled: @MainActor (ProtocolTarget.ID, ProtocolTarget.Capabilities) -> Void

    package init(
        transport: TransportSession,
        isCurrent: @escaping @MainActor () -> Bool,
        isAttached: @escaping @MainActor () -> Bool,
        appliedSequence: @escaping @MainActor () -> UInt64,
        shouldEnableCompatibilityCSS: @escaping @MainActor (ProtocolTarget.ID) -> Bool,
        markTargetDomainEnabled: @escaping @MainActor (ProtocolTarget.ID, ProtocolTarget.Capabilities) -> Void
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

    package func snapshot() async -> TransportSession.Snapshot {
        await transport.snapshot()
    }

    package func requireAttached() throws {
        guard isAttached() else {
            throw InspectorSession.Error("Inspector session is not attached.")
        }
    }

    @discardableResult
    package func send(_ command: ProtocolCommand) async throws -> ProtocolCommand.Result {
        guard isCurrent() else {
            throw TransportSession.Error.transportClosed
        }
        let result: ProtocolCommand.Result
        do {
            result = try await transport.send(command)
        } catch {
            InspectorRuntimeLog.error("command.error method=\(command.method) routing=\(command.routing) error=\(error)")
            throw error
        }
        guard isCurrent() else {
            throw TransportSession.Error.transportClosed
        }
        return result
    }

    package func cssAgentShouldBeEnabledForCompatibility(targetID: ProtocolTarget.ID) -> Bool {
        shouldEnableCompatibilityCSS(targetID)
    }

    package func markEnabled(_ domain: ProtocolTarget.Capabilities, targetID: ProtocolTarget.ID) {
        markTargetDomainEnabled(targetID, domain)
    }
}
