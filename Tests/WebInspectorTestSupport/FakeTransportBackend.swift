import Foundation
import WebInspectorTransport

package struct SentTargetMessage: Equatable, Sendable {
    package var message: String
    package var targetIdentifier: ProtocolTarget.ID
    package var outerIdentifier: UInt64

    package init(message: String, targetIdentifier: ProtocolTarget.ID, outerIdentifier: UInt64) {
        self.message = message
        self.targetIdentifier = targetIdentifier
        self.outerIdentifier = outerIdentifier
    }
}

package actor FakeTransportBackend: TransportBackend {
    private struct MessageWaiter: Sendable {
        var id: UInt64
        var ordinal: Int
        var after: Int
        var continuation: CheckedContinuation<String, Error>
    }

    private struct TargetMessageWaiter: Sendable {
        var id: UInt64
        var method: String?
        var ordinal: Int
        var after: Int
        var continuation: CheckedContinuation<SentTargetMessage, Error>
    }

    private struct MessageWaiterRegistration: Sendable {
        var ordinal: Int
        var after: Int
    }

    private struct TargetMessageWaiterRegistration: Sendable {
        var method: String?
        var ordinal: Int
        var after: Int
    }

    private struct MessageWaiterRegistrationWaiter {
        var ordinal: Int
        var after: Int
        var continuation: CheckedContinuation<Void, Never>
    }

    private struct TargetMessageWaiterRegistrationWaiter {
        var method: String?
        var ordinal: Int
        var after: Int
        var continuation: CheckedContinuation<Void, Never>
    }

    private var messages: [String]
    private var sendError: (any Error)?
    private var detached: Bool
    private var messageWaiters: [MessageWaiter]
    private var nextMessageWaiterID: UInt64
    private var cancelledMessageWaiterIDs: Set<UInt64>
    private var messageWaiterRegistrations: [MessageWaiterRegistration]
    private var messageWaiterRegistrationWaiters: [MessageWaiterRegistrationWaiter]
    private var targetMessageWaiters: [TargetMessageWaiter]
    private var nextTargetMessageWaiterID: UInt64
    private var cancelledTargetMessageWaiterIDs: Set<UInt64>
    private var targetMessageWaiterRegistrations: [TargetMessageWaiterRegistration]
    private var targetMessageWaiterRegistrationWaiters: [TargetMessageWaiterRegistrationWaiter]

    package init() {
        messages = []
        detached = false
        messageWaiters = []
        nextMessageWaiterID = 0
        cancelledMessageWaiterIDs = []
        messageWaiterRegistrations = []
        messageWaiterRegistrationWaiters = []
        targetMessageWaiters = []
        nextTargetMessageWaiterID = 0
        cancelledTargetMessageWaiterIDs = []
        targetMessageWaiterRegistrations = []
        targetMessageWaiterRegistrationWaiters = []
    }

    package func sendJSONString(_ message: String) async throws {
        if let sendError {
            throw sendError
        }
        messages.append(message)
        resumeMessageWaiters()
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

    package func waitUntilMessageWaiterRegistered(ordinal: Int = 0, after count: Int = 0) async {
        guard hasMessageWaiterRegistration(ordinal: ordinal, after: count) == false else {
            return
        }
        await withCheckedContinuation { continuation in
            if hasMessageWaiterRegistration(ordinal: ordinal, after: count) {
                continuation.resume()
            } else {
                messageWaiterRegistrationWaiters.append(
                    MessageWaiterRegistrationWaiter(
                        ordinal: ordinal,
                        after: count,
                        continuation: continuation
                    )
                )
            }
        }
    }

    package func waitUntilTargetMessageWaiterRegistered(
        method: String,
        ordinal: Int = 0,
        after count: Int = 0
    ) async {
        await waitUntilTargetMessageWaiterRegistered(method: method as String?, ordinal: ordinal, after: count)
    }

    package func waitUntilTargetMessageWaiterRegistered(
        ordinal: Int = 0,
        after count: Int = 0
    ) async {
        await waitUntilTargetMessageWaiterRegistered(method: nil, ordinal: ordinal, after: count)
    }

    package func waitForMessage(ordinal: Int = 0, after count: Int = 0) async throws -> String {
        try Task.checkCancellation()
        if let message = message(ordinal: ordinal, after: count) {
            return message
        }

        nextMessageWaiterID &+= 1
        let waiterID = nextMessageWaiterID
        let message = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerMessageWaiter(
                    id: waiterID,
                    ordinal: ordinal,
                    after: count,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelMessageWaiter(waiterID)
            }
        }
        try Task.checkCancellation()
        return message
    }

    package func waitForTargetMessage(ordinal: Int = 0, after count: Int = 0) async throws -> SentTargetMessage {
        try await waitForTargetMessage(method: nil, ordinal: ordinal, after: count)
    }

    package func waitForTargetMessage(method: String, ordinal: Int = 0, after count: Int = 0) async throws -> SentTargetMessage {
        try await waitForTargetMessage(method: method as String?, ordinal: ordinal, after: count)
    }

    private func waitForTargetMessage(method: String?, ordinal: Int, after count: Int) async throws -> SentTargetMessage {
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

    private func resumeMessageWaiters() {
        var remainingWaiters: [MessageWaiter] = []
        for waiter in messageWaiters {
            if cancelledMessageWaiterIDs.remove(waiter.id) != nil {
                waiter.continuation.resume(throwing: CancellationError())
            } else if let message = message(ordinal: waiter.ordinal, after: waiter.after) {
                waiter.continuation.resume(returning: message)
            } else {
                remainingWaiters.append(waiter)
            }
        }
        messageWaiters = remainingWaiters
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

    private func registerMessageWaiter(
        id: UInt64,
        ordinal: Int,
        after count: Int,
        continuation: CheckedContinuation<String, Error>
    ) {
        guard cancelledMessageWaiterIDs.remove(id) == nil else {
            continuation.resume(throwing: CancellationError())
            return
        }
        if let message = message(ordinal: ordinal, after: count) {
            continuation.resume(returning: message)
            return
        }
        messageWaiterRegistrations.append(MessageWaiterRegistration(ordinal: ordinal, after: count))
        messageWaiters.append(
            MessageWaiter(
                id: id,
                ordinal: ordinal,
                after: count,
                continuation: continuation
            )
        )
        resumeMessageWaiterRegistrationWaiters()
    }

    private func registerTargetMessageWaiter(
        id: UInt64,
        method: String?,
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
        targetMessageWaiterRegistrations.append(TargetMessageWaiterRegistration(
            method: method,
            ordinal: ordinal,
            after: count
        ))
        targetMessageWaiters.append(
            TargetMessageWaiter(
                id: id,
                method: method,
                ordinal: ordinal,
                after: count,
                continuation: continuation
            )
        )
        resumeTargetMessageWaiterRegistrationWaiters()
    }

    private func waitUntilTargetMessageWaiterRegistered(
        method: String?,
        ordinal: Int,
        after count: Int
    ) async {
        guard hasTargetMessageWaiterRegistration(method: method, ordinal: ordinal, after: count) == false else {
            return
        }
        await withCheckedContinuation { continuation in
            if hasTargetMessageWaiterRegistration(method: method, ordinal: ordinal, after: count) {
                continuation.resume()
            } else {
                targetMessageWaiterRegistrationWaiters.append(
                    TargetMessageWaiterRegistrationWaiter(
                        method: method,
                        ordinal: ordinal,
                        after: count,
                        continuation: continuation
                    )
                )
            }
        }
    }

    private func resumeMessageWaiterRegistrationWaiters() {
        var remainingWaiters: [MessageWaiterRegistrationWaiter] = []
        for waiter in messageWaiterRegistrationWaiters {
            if hasMessageWaiterRegistration(ordinal: waiter.ordinal, after: waiter.after) {
                waiter.continuation.resume()
            } else {
                remainingWaiters.append(waiter)
            }
        }
        messageWaiterRegistrationWaiters = remainingWaiters
    }

    private func resumeTargetMessageWaiterRegistrationWaiters() {
        var remainingWaiters: [TargetMessageWaiterRegistrationWaiter] = []
        for waiter in targetMessageWaiterRegistrationWaiters {
            if hasTargetMessageWaiterRegistration(method: waiter.method, ordinal: waiter.ordinal, after: waiter.after) {
                waiter.continuation.resume()
            } else {
                remainingWaiters.append(waiter)
            }
        }
        targetMessageWaiterRegistrationWaiters = remainingWaiters
    }

    private func hasMessageWaiterRegistration(ordinal: Int, after count: Int) -> Bool {
        messageWaiterRegistrations.contains {
            $0.ordinal == ordinal && $0.after == count
        }
    }

    private func hasTargetMessageWaiterRegistration(method: String?, ordinal: Int, after count: Int) -> Bool {
        targetMessageWaiterRegistrations.contains {
            $0.method == method && $0.ordinal == ordinal && $0.after == count
        }
    }

    private func cancelMessageWaiter(_ id: UInt64) {
        guard let index = messageWaiters.firstIndex(where: { $0.id == id }) else {
            cancelledMessageWaiterIDs.insert(id)
            return
        }
        let waiter = messageWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func cancelTargetMessageWaiter(_ id: UInt64) {
        guard let index = targetMessageWaiters.firstIndex(where: { $0.id == id }) else {
            cancelledTargetMessageWaiterIDs.insert(id)
            return
        }
        let waiter = targetMessageWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func message(ordinal: Int, after count: Int) -> String? {
        let matches = Array(messages.dropFirst(count))
        guard matches.indices.contains(ordinal) else {
            return nil
        }
        return matches[ordinal]
    }

    private func targetMessage(method: String?, ordinal: Int, after count: Int) -> SentTargetMessage? {
        let matches = sentTargetMessages().dropFirst(count).filter { sentMessage in
            guard let method else {
                return true
            }
            return Self.messageMethod(from: sentMessage.message) == method
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
            targetIdentifier: ProtocolTarget.ID(targetIdentifier),
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
