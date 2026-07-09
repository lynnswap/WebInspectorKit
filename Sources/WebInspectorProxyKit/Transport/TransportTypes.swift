import Foundation

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

package struct ProtocolCommand: Equatable, Sendable {
    package enum Routing: Equatable, Sendable {
        case root
        case target(ProtocolTarget.ID)
        case octopus(pageTarget: ProtocolTarget.ID?)
    }

    package struct Result: Equatable, Sendable {
        package var domain: ProtocolDomain
        package var method: String
        package var targetID: ProtocolTarget.ID?
        package var receivedSequence: UInt64
        package var receivedDomainSequences: [ProtocolDomain: UInt64]
        package var resultData: Data

        package init(
            domain: ProtocolDomain,
            method: String,
            targetID: ProtocolTarget.ID?,
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

    package var domain: ProtocolDomain
    package var method: String
    package var routing: Routing
    package var parametersData: Data

    package init(
        domain: ProtocolDomain,
        method: String,
        routing: Routing,
        parametersData: Data = Data("{}".utf8)
    ) {
        self.domain = domain
        self.method = method
        self.routing = routing
        self.parametersData = parametersData
    }
}

package struct ProtocolEvent: Equatable, Sendable {
    package var sequence: UInt64
    package var domain: ProtocolDomain
    package var method: String
    package var targetID: ProtocolTarget.ID?
    package var sourceTargetID: ProtocolTarget.ID?
    package var receivedDomainSequences: [ProtocolDomain: UInt64]
    package var paramsData: Data
    /// Event-time fact for `Target.targetDestroyed`: whether the destroyed
    /// target was the current main page target when the event arrived. The
    /// registry forgets the destroyed record before subscribers consume the
    /// event, so consumers cannot reconstruct this from a snapshot.
    package var destroyedCurrentMainPageTarget: Bool

    package init(
        sequence: UInt64,
        domain: ProtocolDomain,
        method: String,
        targetID: ProtocolTarget.ID?,
        sourceTargetID: ProtocolTarget.ID? = nil,
        receivedDomainSequences: [ProtocolDomain: UInt64] = [:],
        paramsData: Data,
        destroyedCurrentMainPageTarget: Bool = false
    ) {
        self.sequence = sequence
        self.domain = domain
        self.method = method
        self.targetID = targetID
        self.sourceTargetID = sourceTargetID
        self.receivedDomainSequences = receivedDomainSequences
        self.paramsData = paramsData
        self.destroyedCurrentMainPageTarget = destroyedCurrentMainPageTarget
    }

    package func receivedSequence(for domain: ProtocolDomain) -> UInt64 {
        receivedDomainSequences[domain] ?? 0
    }
}

package extension TransportSession {
    struct Snapshot: Equatable, Sendable {
        package var currentMainPageTargetID: ProtocolTarget.ID?
        package var targetsByID: [ProtocolTarget.ID: ProtocolTarget.Record]
        package var frameTargetIDsByFrameID: [ProtocolFrame.ID: ProtocolTarget.ID]
        package var executionContextsByKey: [RuntimeContext.Key: RuntimeContext.Record]
        package var pendingRootReplyIDs: [UInt64]
        package var pendingTargetReplyKeys: [ReplyKey]

        package init(
            currentMainPageTargetID: ProtocolTarget.ID?,
            targetsByID: [ProtocolTarget.ID: ProtocolTarget.Record],
            frameTargetIDsByFrameID: [ProtocolFrame.ID: ProtocolTarget.ID],
            executionContextsByKey: [RuntimeContext.Key: RuntimeContext.Record],
            pendingRootReplyIDs: [UInt64],
            pendingTargetReplyKeys: [ReplyKey]
        ) {
            self.currentMainPageTargetID = currentMainPageTargetID
            self.targetsByID = targetsByID
            self.frameTargetIDsByFrameID = frameTargetIDsByFrameID
            self.executionContextsByKey = executionContextsByKey
            self.pendingRootReplyIDs = pendingRootReplyIDs
            self.pendingTargetReplyKeys = pendingTargetReplyKeys
        }
    }

    struct MainPageTarget: Equatable, Sendable {
        package var targetID: ProtocolTarget.ID
        package var receivedSequence: UInt64

        package init(targetID: ProtocolTarget.ID, receivedSequence: UInt64) {
            self.targetID = targetID
            self.receivedSequence = receivedSequence
        }
    }

    struct ReplyKey: Hashable, Comparable, Sendable {
        package var targetID: ProtocolTarget.ID
        package var commandID: UInt64

        package init(targetID: ProtocolTarget.ID, commandID: UInt64) {
            self.targetID = targetID
            self.commandID = commandID
        }

        package static func < (lhs: ReplyKey, rhs: ReplyKey) -> Bool {
            if lhs.targetID.rawValue == rhs.targetID.rawValue {
                return lhs.commandID < rhs.commandID
            }
            return lhs.targetID.rawValue < rhs.targetID.rawValue
        }
    }

    enum Error: Swift.Error, Equatable, Sendable {
        case malformedMessage
        case missingTarget(ProtocolTarget.ID)
        case missingMainPageTarget
        case replyTimeout(method: String, targetID: ProtocolTarget.ID?)
        case remoteError(method: String, targetID: ProtocolTarget.ID?, message: String)
        case transportClosed
        case transportFailure(String)
    }
}
