import Foundation

struct TransportInboundMessageQueue: Sendable {
    private var messages: [String] = []
    private var messageStartIndex = 0
    private var isDraining = false

    mutating func append(_ message: String) {
        messages.append(message)
    }

    mutating func startDraining() -> Bool {
        guard !isDraining else {
            return false
        }
        isDraining = true
        return true
    }

    mutating func finishDraining() {
        isDraining = false
    }

    mutating func popNext() -> String? {
        guard messageStartIndex < messages.count else {
            messages.removeAll(keepingCapacity: true)
            messageStartIndex = 0
            return nil
        }

        let message = messages[messageStartIndex]
        messageStartIndex += 1
        compactIfNeeded()
        return message
    }

    private mutating func compactIfNeeded() {
        if messageStartIndex == messages.count {
            messages.removeAll(keepingCapacity: true)
            messageStartIndex = 0
        } else if messageStartIndex >= 64 && messageStartIndex * 2 >= messages.count {
            messages.removeFirst(messageStartIndex)
            messageStartIndex = 0
        }
    }
}
