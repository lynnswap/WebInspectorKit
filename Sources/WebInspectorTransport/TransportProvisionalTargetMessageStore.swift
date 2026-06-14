import Foundation

struct TransportProvisionalTargetMessageStore: Sendable {
    private var messagesByTargetID: [ProtocolTarget.ID: [ParsedProtocolMessage]] = [:]

    mutating func append(_ message: ParsedProtocolMessage, for targetID: ProtocolTarget.ID) {
        messagesByTargetID[targetID, default: []].append(message)
    }

    mutating func removeAll() {
        messagesByTargetID.removeAll()
    }

    mutating func removeTarget(_ targetID: ProtocolTarget.ID) {
        messagesByTargetID.removeValue(forKey: targetID)
    }

    mutating func retargetMessages(from oldTargetID: ProtocolTarget.ID, to newTargetID: ProtocolTarget.ID) {
        guard oldTargetID != newTargetID,
              let messages = messagesByTargetID.removeValue(forKey: oldTargetID),
              messages.isEmpty == false else {
            return
        }
        messagesByTargetID[newTargetID, default: []].append(contentsOf: messages)
    }

    mutating func takeMessages(for targetID: ProtocolTarget.ID) -> [ParsedProtocolMessage] {
        messagesByTargetID.removeValue(forKey: targetID) ?? []
    }
}
