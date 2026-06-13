import Foundation

struct TransportTargetRegistry: Sendable {
    var targetsByID: [ProtocolTargetIdentifier: ProtocolTargetRecord] = [:]
    var frameTargetIDsByFrameID: [DOMFrameIdentifier: ProtocolTargetIdentifier] = [:]
    var currentMainPageTargetID: ProtocolTargetIdentifier?
}
