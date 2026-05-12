import Foundation
import V2_WebInspectorCore

package protocol TransportBackend: Sendable {
    func sendJSONString(_ message: String) async throws
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
    private var messages: [String]
    private var sendError: (any Error)?
    private var detached: Bool

    package init() {
        messages = []
        detached = false
    }

    package func sendJSONString(_ message: String) async throws {
        if let sendError {
            throw sendError
        }
        messages.append(message)
    }

    package func detach() async {
        detached = true
    }

    package func setSendError(_ error: (any Error)?) {
        sendError = error
    }

    package func sentMessages() -> [String] {
        messages
    }

    package func sentTargetMessages() -> [SentTargetMessage] {
        messages.compactMap { Self.sentTargetMessage(from: $0) }
    }

    package func isDetached() -> Bool {
        detached
    }

    private static func sentTargetMessage(from message: String) -> SentTargetMessage? {
        guard let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String,
              method == "Target.sendMessageToTarget",
              let params = object["params"] as? [String: Any],
              let targetIdentifier = params["targetId"] as? String,
              let innerMessage = params["message"] as? String else {
            return nil
        }

        let outerIdentifier: UInt64
        if let number = object["id"] as? NSNumber {
            outerIdentifier = number.uint64Value
        } else if let string = object["id"] as? String,
                  let identifier = UInt64(string) {
            outerIdentifier = identifier
        } else {
            return nil
        }

        return SentTargetMessage(
            message: innerMessage,
            targetIdentifier: ProtocolTargetIdentifier(targetIdentifier),
            outerIdentifier: outerIdentifier
        )
    }
}
