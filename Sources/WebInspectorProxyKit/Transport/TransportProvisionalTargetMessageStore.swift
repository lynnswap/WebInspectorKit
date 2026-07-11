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

    mutating func takeMessages(for targetID: ProtocolTarget.ID) -> [ParsedProtocolMessage] {
        messagesByTargetID.removeValue(forKey: targetID) ?? []
    }
}
