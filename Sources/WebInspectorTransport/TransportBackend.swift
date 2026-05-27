import Foundation
import WebInspectorCore

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
    private struct TargetMessageWaiter: Sendable {
        var id: UInt64
        var method: String
        var ordinal: Int
        var after: Int
        var continuation: CheckedContinuation<SentTargetMessage, Error>
    }

    private var messages: [String]
    private var sendError: (any Error)?
    private var detached: Bool
    private var targetMessageWaiters: [TargetMessageWaiter]
    private var nextTargetMessageWaiterID: UInt64
    private var cancelledTargetMessageWaiterIDs: Set<UInt64>

    package init() {
        messages = []
        detached = false
        targetMessageWaiters = []
        nextTargetMessageWaiterID = 0
        cancelledTargetMessageWaiterIDs = []
    }

    package func sendJSONString(_ message: String) async throws {
        if let sendError {
            throw sendError
        }
        messages.append(message)
        resumeTargetMessageWaiters()
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

    package func waitForTargetMessage(method: String, ordinal: Int = 0, after count: Int = 0) async throws -> SentTargetMessage {
        try Task.checkCancellation()
        if let message = targetMessage(method: method, ordinal: ordinal, after: count) {
            return message
        }

        nextTargetMessageWaiterID &+= 1
        let waiterID = nextTargetMessageWaiterID
        let message = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerTargetMessageWaiter(
                    id: waiterID,
                    method: method,
                    ordinal: ordinal,
                    after: count,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelTargetMessageWaiter(waiterID)
            }
        }
        try Task.checkCancellation()
        return message
    }

    package func isDetached() -> Bool {
        detached
    }

    private func resumeTargetMessageWaiters() {
        var remainingWaiters: [TargetMessageWaiter] = []
        for waiter in targetMessageWaiters {
            if cancelledTargetMessageWaiterIDs.remove(waiter.id) != nil {
                waiter.continuation.resume(throwing: CancellationError())
            } else if let message = targetMessage(method: waiter.method, ordinal: waiter.ordinal, after: waiter.after) {
                waiter.continuation.resume(returning: message)
            } else {
                remainingWaiters.append(waiter)
            }
        }
        targetMessageWaiters = remainingWaiters
    }

    private func registerTargetMessageWaiter(
        id: UInt64,
        method: String,
        ordinal: Int,
        after count: Int,
        continuation: CheckedContinuation<SentTargetMessage, Error>
    ) {
        guard cancelledTargetMessageWaiterIDs.remove(id) == nil else {
            continuation.resume(throwing: CancellationError())
            return
        }
        if let message = targetMessage(method: method, ordinal: ordinal, after: count) {
            continuation.resume(returning: message)
            return
        }
        targetMessageWaiters.append(
            TargetMessageWaiter(
                id: id,
                method: method,
                ordinal: ordinal,
                after: count,
                continuation: continuation
            )
        )
    }

    private func cancelTargetMessageWaiter(_ id: UInt64) {
        guard let index = targetMessageWaiters.firstIndex(where: { $0.id == id }) else {
            cancelledTargetMessageWaiterIDs.insert(id)
            return
        }
        let waiter = targetMessageWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func targetMessage(method: String, ordinal: Int, after count: Int) -> SentTargetMessage? {
        let matches = sentTargetMessages().dropFirst(count).filter { sentMessage in
            Self.messageMethod(from: sentMessage.message) == method
        }
        guard matches.indices.contains(ordinal) else {
            return nil
        }
        return matches[ordinal]
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

    private static func messageMethod(from message: String) -> String? {
        guard let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["method"] as? String
    }
}
