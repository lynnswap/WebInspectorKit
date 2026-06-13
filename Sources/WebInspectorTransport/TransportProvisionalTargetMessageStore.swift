import Foundation

struct TransportProvisionalTargetMessageStore: Sendable {
    private var messagesByTargetID: [ProtocolTargetIdentifier: [ParsedProtocolMessage]] = [:]

    mutating func append(_ message: ParsedProtocolMessage, for targetID: ProtocolTargetIdentifier) {
        messagesByTargetID[targetID, default: []].append(message)
    }

    mutating func removeAll() {
        messagesByTargetID.removeAll()
    }

    mutating func removeTarget(_ targetID: ProtocolTargetIdentifier) {
        messagesByTargetID.removeValue(forKey: targetID)
    }

    mutating func retargetMessages(from oldTargetID: ProtocolTargetIdentifier, to newTargetID: ProtocolTargetIdentifier) {
        guard oldTargetID != newTargetID,
              let messages = messagesByTargetID.removeValue(forKey: oldTargetID),
              messages.isEmpty == false else {
            return
        }
        messagesByTargetID[newTargetID, default: []].append(contentsOf: messages)
    }

    mutating func takeMessages(for targetID: ProtocolTargetIdentifier) -> [ParsedProtocolMessage] {
        messagesByTargetID.removeValue(forKey: targetID) ?? []
    }
}
