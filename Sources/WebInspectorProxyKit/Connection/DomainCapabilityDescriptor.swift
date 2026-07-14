import Foundation

package struct WebInspectorCapabilityConfigurationID: RawRepresentable, Hashable, Sendable {
    package let rawValue: String

    package init(rawValue: String) { self.rawValue = rawValue }
    package static let `default` = Self(rawValue: "default")
}

package struct WebInspectorCapabilityMutationOwner: RawRepresentable, Hashable, Sendable {
    package let rawValue: String

    package init(rawValue: String) { self.rawValue = rawValue }
}

package enum WebInspectorCapabilityAgentResolution: Hashable, Sendable {
    case selectedTarget
    case currentPage
    case root
}

package enum WebInspectorCapabilityReacquisitionPolicy: Hashable, Sendable {
    case enable
    case retainPhysicalState
}

package enum WebInspectorCapabilityReleasePolicy: Sendable {
    case disable(WebInspectorWireCommand<Void>)
    case retainEnabled
}

package struct WebInspectorDomainCapabilityDescriptor: Sendable {
    package let domain: WebInspectorProtocolDomainToken
    package let configurationID: WebInspectorCapabilityConfigurationID
    package let agentResolution: WebInspectorCapabilityAgentResolution
    package let dependencies: [WebInspectorDomainCapabilityDescriptor]
    package let enable: WebInspectorWireCommand<Void>?
    package let release: WebInspectorCapabilityReleasePolicy
    package let reacquisition: WebInspectorCapabilityReacquisitionPolicy
    package let mutationOwner: WebInspectorCapabilityMutationOwner

    package init(
        domain: WebInspectorProtocolDomainToken,
        configurationID: WebInspectorCapabilityConfigurationID = .default,
        agentResolution: WebInspectorCapabilityAgentResolution = .selectedTarget,
        dependencies: [WebInspectorDomainCapabilityDescriptor] = [],
        enable: WebInspectorWireCommand<Void>?,
        release: WebInspectorCapabilityReleasePolicy,
        reacquisition: WebInspectorCapabilityReacquisitionPolicy = .enable,
        mutationOwner: WebInspectorCapabilityMutationOwner
    ) {
        self.domain = domain
        self.configurationID = configurationID
        self.agentResolution = agentResolution
        self.dependencies = dependencies
        self.enable = enable
        self.release = release
        self.reacquisition = reacquisition
        self.mutationOwner = mutationOwner
    }
}

package struct ConnectionCapabilityKey: Hashable, Sendable {
    package let agentTargetID: ProtocolTarget.ID?
    package let domain: WebInspectorProtocolDomainToken
    package let configurationID: WebInspectorCapabilityConfigurationID
}

package struct ConnectionCapabilityRegistry: Sendable {
    package enum PhysicalState: Sendable {
        case inactive
        case enabling(operationID: UInt64, completion: ReplyPromise<Void>)
        case enabled
        case disabling(operationID: UInt64, completion: ReplyPromise<Void>)
        case unknown
        case retained
    }

    package struct Lease: Hashable, Sendable {
        package let scopeID: WebInspectorOrderedScopeID
        package let key: ConnectionCapabilityKey
    }

    package struct Entry: Sendable {
        package var descriptor: WebInspectorDomainCapabilityDescriptor
        package var owners: Set<WebInspectorOrderedScopeID>
        package var physical: PhysicalState
    }

    package var entries: [ConnectionCapabilityKey: Entry] = [:]
    private var nextOperationID: UInt64 = 0

    package init() {}

    package mutating func allocateOperationID() -> UInt64 {
        nextOperationID &+= 1
        return nextOperationID
    }

    package mutating func entry(
        for key: ConnectionCapabilityKey,
        descriptor: WebInspectorDomainCapabilityDescriptor
    ) -> Entry {
        entries[key] ?? Entry(descriptor: descriptor, owners: [], physical: .inactive)
    }

    package mutating func set(_ entry: Entry, for key: ConnectionCapabilityKey) {
        entries[key] = entry
    }

    package mutating func removeIfInactiveAndUnowned(_ key: ConnectionCapabilityKey) {
        guard let entry = entries[key], entry.owners.isEmpty else { return }
        if case .inactive = entry.physical {
            entries.removeValue(forKey: key)
        }
    }

    package mutating func targetDisappeared(_ targetID: ProtocolTarget.ID) -> [WebInspectorOrderedScopeID] {
        let affected = entries.keys.filter { $0.agentTargetID == targetID }
        var scopes: Set<WebInspectorOrderedScopeID> = []
        for key in affected {
            guard let entry = entries.removeValue(forKey: key) else { continue }
            scopes.formUnion(entry.owners)
            switch entry.physical {
            case let .enabling(_, completion), let .disabling(_, completion):
                completion.fulfill(.failure(WebInspectorProxyError.pageUnavailable))
            case .inactive, .enabled, .unknown, .retained:
                break
            }
        }
        return Array(scopes)
    }
}
