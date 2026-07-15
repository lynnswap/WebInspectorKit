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

package enum ProtocolNetworkPageMembership: Equatable, Sendable {
    case currentPage
    case otherPage
    case unresolved
}

package struct ProtocolEvent: Equatable, Sendable {
    package var sequence: UInt64
    package var domain: ProtocolDomain
    package var method: String
    package var targetID: ProtocolTarget.ID?
    package var sourceTargetID: ProtocolTarget.ID?
    package var pageBindingTargetID: ProtocolTarget.ID?
    package var networkOriginTargetID: ProtocolTarget.ID?
    /// Stable request scope captured when a root Network request first
    /// arrives. `targetID` may move to a committed target so routing remains
    /// live, while this scope keeps the externally projected request ID stable.
    package var networkScopeTargetID: ProtocolTarget.ID?
    /// Event-time current-page membership for latest root Network delivery.
    /// Target commits can remove the original record before a subscriber
    /// evaluates the event, so membership cannot be reconstructed later.
    package var networkPageMembership: ProtocolNetworkPageMembership?
    /// Root Page events in WebKit 625 are emitted by a page-bound
    /// `ProxyingPageAgent`, so current-page membership is known even when the
    /// corresponding frame target has not arrived yet.
    package var rootPageBelongedToCurrentPage: Bool?
    package var receivedDomainSequences: [ProtocolDomain: UInt64]
    package var paramsData: Data
    /// Event-time fact for `Target.targetDestroyed`: whether the destroyed
    /// target was the current main page target when the event arrived. The
    /// registry forgets the destroyed record before subscribers consume the
    /// event, so consumers cannot reconstruct this from a snapshot.
    package var destroyedCurrentMainPageTarget: Bool
    /// Event-time fact for a destroyed provisional target. This lets the
    /// semantic page route retire navigation state after the registry removes
    /// the target record.
    package var destroyedProvisionalTargetInCurrentPageHierarchy: Bool
    /// Event-time fact for `Page.frameDetached`: whether the detached frame
    /// target belonged to the current page before topology was removed.
    package var detachedCurrentPageFrameTarget: Bool

    package init(
        sequence: UInt64,
        domain: ProtocolDomain,
        method: String,
        targetID: ProtocolTarget.ID?,
        sourceTargetID: ProtocolTarget.ID? = nil,
        pageBindingTargetID: ProtocolTarget.ID? = nil,
        networkOriginTargetID: ProtocolTarget.ID? = nil,
        networkScopeTargetID: ProtocolTarget.ID? = nil,
        networkPageMembership: ProtocolNetworkPageMembership? = nil,
        rootPageBelongedToCurrentPage: Bool? = nil,
        receivedDomainSequences: [ProtocolDomain: UInt64] = [:],
        paramsData: Data,
        destroyedCurrentMainPageTarget: Bool = false,
        destroyedProvisionalTargetInCurrentPageHierarchy: Bool = false,
        detachedCurrentPageFrameTarget: Bool = false
    ) {
        self.sequence = sequence
        self.domain = domain
        self.method = method
        self.targetID = targetID
        self.sourceTargetID = sourceTargetID
        self.pageBindingTargetID = pageBindingTargetID
        self.networkOriginTargetID = networkOriginTargetID
        self.networkScopeTargetID = networkScopeTargetID
        self.networkPageMembership = networkPageMembership
        self.rootPageBelongedToCurrentPage = rootPageBelongedToCurrentPage
        self.receivedDomainSequences = receivedDomainSequences
        self.paramsData = paramsData
        self.destroyedCurrentMainPageTarget = destroyedCurrentMainPageTarget
        self.destroyedProvisionalTargetInCurrentPageHierarchy = destroyedProvisionalTargetInCurrentPageHierarchy
        self.detachedCurrentPageFrameTarget = detachedCurrentPageFrameTarget
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
        package var parentFrameIDsByFrameID: [ProtocolFrame.ID: ProtocolFrame.ID]
        package var executionContextsByKey: [RuntimeContext.Key: RuntimeContext.Record]
        package var pendingRootReplyIDs: [UInt64]
        package var pendingTargetReplyKeys: [ReplyKey]

        package init(
            currentMainPageTargetID: ProtocolTarget.ID?,
            targetsByID: [ProtocolTarget.ID: ProtocolTarget.Record],
            frameTargetIDsByFrameID: [ProtocolFrame.ID: ProtocolTarget.ID],
            parentFrameIDsByFrameID: [ProtocolFrame.ID: ProtocolFrame.ID],
            executionContextsByKey: [RuntimeContext.Key: RuntimeContext.Record],
            pendingRootReplyIDs: [UInt64],
            pendingTargetReplyKeys: [ReplyKey]
        ) {
            self.currentMainPageTargetID = currentMainPageTargetID
            self.targetsByID = targetsByID
            self.frameTargetIDsByFrameID = frameTargetIDsByFrameID
            self.parentFrameIDsByFrameID = parentFrameIDsByFrameID
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
        case unsupportedDomain(ProtocolDomain, targetID: ProtocolTarget.ID)
        case replyTimeout(method: String, targetID: ProtocolTarget.ID?)
        case remoteError(method: String, targetID: ProtocolTarget.ID?, message: String)
        case transportClosed
    }
}
