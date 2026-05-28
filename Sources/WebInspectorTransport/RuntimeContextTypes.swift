package struct RuntimeExecutionContextKey: Hashable, Sendable {
    package var runtimeAgentTargetID: ProtocolTargetIdentifier
    package var contextID: ExecutionContextID

    package init(runtimeAgentTargetID: ProtocolTargetIdentifier, contextID: ExecutionContextID) {
        self.runtimeAgentTargetID = runtimeAgentTargetID
        self.contextID = contextID
    }
}

package struct RuntimeExecutionContextType: RawRepresentable, Hashable, Codable, Sendable {
    package let rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package static let normal = Self("normal")
    package static let user = Self("user")
    package static let `internal` = Self("internal")
}

package struct RuntimeExecutionContextRecord: Equatable, Sendable {
    package var id: ExecutionContextID
    package var targetID: ProtocolTargetIdentifier
    package var runtimeAgentTargetID: ProtocolTargetIdentifier
    package var type: RuntimeExecutionContextType
    package var name: String
    package var frameID: DOMFrameIdentifier?

    package init(
        id: ExecutionContextID,
        targetID: ProtocolTargetIdentifier,
        runtimeAgentTargetID: ProtocolTargetIdentifier? = nil,
        type: RuntimeExecutionContextType = .normal,
        name: String = "",
        frameID: DOMFrameIdentifier? = nil
    ) {
        self.id = id
        self.targetID = targetID
        self.runtimeAgentTargetID = runtimeAgentTargetID ?? targetID
        self.type = type
        self.name = name
        self.frameID = frameID
    }

    package var key: RuntimeExecutionContextKey {
        RuntimeExecutionContextKey(runtimeAgentTargetID: runtimeAgentTargetID, contextID: id)
    }

    package static func stableOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.runtimeAgentTargetID != rhs.runtimeAgentTargetID {
            return lhs.runtimeAgentTargetID.rawValue < rhs.runtimeAgentTargetID.rawValue
        }
        if lhs.id != rhs.id {
            return lhs.id.rawValue < rhs.id.rawValue
        }
        if lhs.targetID != rhs.targetID {
            return lhs.targetID.rawValue < rhs.targetID.rawValue
        }
        if lhs.frameID != rhs.frameID {
            return (lhs.frameID?.rawValue ?? "") < (rhs.frameID?.rawValue ?? "")
        }
        if lhs.type != rhs.type {
            return lhs.type.rawValue < rhs.type.rawValue
        }
        return lhs.name < rhs.name
    }
}
