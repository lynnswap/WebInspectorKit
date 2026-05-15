import Foundation
import WebInspectorCore

package enum ProtocolDomain: Hashable, Sendable, CustomStringConvertible {
    case target
    case runtime
    case dom
    case css
    case network
    case console
    case page
    case inspector
    case storage
    case other(String)

    package init(method: String) {
        guard let prefix = method.split(separator: ".", maxSplits: 1).first else {
            self = .other(method)
            return
        }
        switch prefix {
        case "Target":
            self = .target
        case "Runtime":
            self = .runtime
        case "DOM":
            self = .dom
        case "CSS":
            self = .css
        case "Network":
            self = .network
        case "Console":
            self = .console
        case "Page":
            self = .page
        case "Inspector":
            self = .inspector
        case "Storage":
            self = .storage
        default:
            self = .other(String(prefix))
        }
    }

    package var description: String {
        switch self {
        case .target:
            "Target"
        case .runtime:
            "Runtime"
        case .dom:
            "DOM"
        case .css:
            "CSS"
        case .network:
            "Network"
        case .console:
            "Console"
        case .page:
            "Page"
        case .inspector:
            "Inspector"
        case .storage:
            "Storage"
        case let .other(value):
            value
        }
    }
}

package enum ProtocolCommandRouting: Equatable, Sendable {
    case root
    case target(ProtocolTargetIdentifier)
    case octopus(pageTarget: ProtocolTargetIdentifier?)
}

package struct ProtocolCommand: Equatable, Sendable {
    package var domain: ProtocolDomain
    package var method: String
    package var routing: ProtocolCommandRouting
    package var parametersData: Data

    package init(
        domain: ProtocolDomain,
        method: String,
        routing: ProtocolCommandRouting,
        parametersData: Data = Data("{}".utf8)
    ) {
        self.domain = domain
        self.method = method
        self.routing = routing
        self.parametersData = parametersData
    }
}

package struct ProtocolCommandResult: Equatable, Sendable {
    package var domain: ProtocolDomain
    package var method: String
    package var targetID: ProtocolTargetIdentifier?
    package var receivedSequence: UInt64
    package var receivedDomainSequences: [ProtocolDomain: UInt64]
    package var resultData: Data

    package init(
        domain: ProtocolDomain,
        method: String,
        targetID: ProtocolTargetIdentifier?,
        receivedSequence: UInt64 = 0,
        receivedDomainSequences: [ProtocolDomain: UInt64] = [:],
        resultData: Data
    ) {
        self.domain = domain
        self.method = method
        self.targetID = targetID
        self.receivedSequence = receivedSequence
        self.receivedDomainSequences = receivedDomainSequences
        self.resultData = resultData
    }

    package func receivedSequence(for domain: ProtocolDomain) -> UInt64 {
        receivedDomainSequences[domain] ?? 0
    }
}

package struct ProtocolEventEnvelope: Equatable, Sendable {
    package var sequence: UInt64
    package var domain: ProtocolDomain
    package var method: String
    package var targetID: ProtocolTargetIdentifier?
    package var paramsData: Data

    package init(
        sequence: UInt64,
        domain: ProtocolDomain,
        method: String,
        targetID: ProtocolTargetIdentifier?,
        paramsData: Data
    ) {
        self.sequence = sequence
        self.domain = domain
        self.method = method
        self.targetID = targetID
        self.paramsData = paramsData
    }
}

package struct TransportSnapshot: Equatable, Sendable {
    package var currentMainPageTargetID: ProtocolTargetIdentifier?
    package var targetsByID: [ProtocolTargetIdentifier: ProtocolTargetRecord]
    package var frameTargetIDsByFrameID: [DOMFrameIdentifier: ProtocolTargetIdentifier]
    package var executionContextsByID: [ExecutionContextID: ExecutionContextRecord]
    package var pendingRootReplyIDs: [UInt64]
    package var pendingTargetReplyKeys: [TargetReplyKey]

    package init(
        currentMainPageTargetID: ProtocolTargetIdentifier?,
        targetsByID: [ProtocolTargetIdentifier: ProtocolTargetRecord],
        frameTargetIDsByFrameID: [DOMFrameIdentifier: ProtocolTargetIdentifier],
        executionContextsByID: [ExecutionContextID: ExecutionContextRecord],
        pendingRootReplyIDs: [UInt64],
        pendingTargetReplyKeys: [TargetReplyKey]
    ) {
        self.currentMainPageTargetID = currentMainPageTargetID
        self.targetsByID = targetsByID
        self.frameTargetIDsByFrameID = frameTargetIDsByFrameID
        self.executionContextsByID = executionContextsByID
        self.pendingRootReplyIDs = pendingRootReplyIDs
        self.pendingTargetReplyKeys = pendingTargetReplyKeys
    }
}

package struct TransportMainPageTarget: Equatable, Sendable {
    package var targetID: ProtocolTargetIdentifier
    package var receivedSequence: UInt64

    package init(targetID: ProtocolTargetIdentifier, receivedSequence: UInt64) {
        self.targetID = targetID
        self.receivedSequence = receivedSequence
    }
}

package struct TargetReplyKey: Hashable, Comparable, Sendable {
    package var targetID: ProtocolTargetIdentifier
    package var commandID: UInt64

    package init(targetID: ProtocolTargetIdentifier, commandID: UInt64) {
        self.targetID = targetID
        self.commandID = commandID
    }

    package static func < (lhs: TargetReplyKey, rhs: TargetReplyKey) -> Bool {
        if lhs.targetID.rawValue == rhs.targetID.rawValue {
            return lhs.commandID < rhs.commandID
        }
        return lhs.targetID.rawValue < rhs.targetID.rawValue
    }
}

package enum TransportError: Error, Equatable, Sendable {
    case malformedMessage
    case missingTarget(ProtocolTargetIdentifier)
    case missingMainPageTarget
    case replyTimeout(method: String, targetID: ProtocolTargetIdentifier?)
    case remoteError(method: String, targetID: ProtocolTargetIdentifier?, message: String)
    case transportClosed
}
