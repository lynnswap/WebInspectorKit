import Foundation
import V2_WebInspectorCore

package protocol TransportBackend: Sendable {
    func sendRootJSONString(_ message: String) async throws
    func sendTargetJSONString(
        _ message: String,
        targetIdentifier: ProtocolTargetIdentifier,
        outerIdentifier: UInt64
    ) async throws
    func detach() async
}

package struct SentTargetMessage: Equatable, Sendable {
    package var message: String
    package var targetIdentifier: ProtocolTargetIdentifier
    package var outerIdentifier: UInt64

    package init(message: String, targetIdentifier: ProtocolTargetIdentifier, outerIdentifier: UInt64) {
        self.message = message
        self.targetIdentifier = targetIdentifier
        self.outerIdentifier = outerIdentifier
    }
}

package actor FakeTransportBackend: TransportBackend {
    private var rootMessages: [String]
    private var targetMessages: [SentTargetMessage]
    private var rootSendError: (any Error)?
    private var targetSendError: (any Error)?
    private var detached: Bool

    package init() {
        rootMessages = []
        targetMessages = []
        detached = false
    }

    package func sendRootJSONString(_ message: String) async throws {
        if let rootSendError {
            throw rootSendError
        }
        rootMessages.append(message)
    }

    package func sendTargetJSONString(
        _ message: String,
        targetIdentifier: ProtocolTargetIdentifier,
        outerIdentifier: UInt64
    ) async throws {
        if let targetSendError {
            throw targetSendError
        }
        targetMessages.append(
            SentTargetMessage(
                message: message,
                targetIdentifier: targetIdentifier,
                outerIdentifier: outerIdentifier
            )
        )
    }

    package func detach() async {
        detached = true
    }

    package func setRootSendError(_ error: (any Error)?) {
        rootSendError = error
    }

    package func setTargetSendError(_ error: (any Error)?) {
        targetSendError = error
    }

    package func sentRootMessages() -> [String] {
        rootMessages
    }

    package func sentTargetMessages() -> [SentTargetMessage] {
        targetMessages
    }

    package func isDetached() -> Bool {
        detached
    }
}
