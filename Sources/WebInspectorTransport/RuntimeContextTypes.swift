extension RuntimeContext {
    package struct Key: Hashable, Sendable {        package var runtimeAgentTargetID: ProtocolTarget.ID
        package var contextID: RuntimeContext.ID

        package init(runtimeAgentTargetID: ProtocolTarget.ID, contextID: RuntimeContext.ID) {
            self.runtimeAgentTargetID = runtimeAgentTargetID
            self.contextID = contextID
        }
    }
}

extension RuntimeContext {
    package struct Kind: RawRepresentable, Hashable, Codable, Sendable {        package let rawValue: String

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
}

extension RuntimeContext {
    package struct Record: Equatable, Sendable {        package var id: RuntimeContext.ID
        package var targetID: ProtocolTarget.ID
        package var runtimeAgentTargetID: ProtocolTarget.ID
        package var type: RuntimeContext.Kind
        package var name: String
        package var frameID: ProtocolFrame.ID?

        package init(
            id: RuntimeContext.ID,
            targetID: ProtocolTarget.ID,
            runtimeAgentTargetID: ProtocolTarget.ID? = nil,
            type: RuntimeContext.Kind = .normal,
            name: String = "",
            frameID: ProtocolFrame.ID? = nil
        ) {
            self.id = id
            self.targetID = targetID
            self.runtimeAgentTargetID = runtimeAgentTargetID ?? targetID
            self.type = type
            self.name = name
            self.frameID = frameID
        }

        package var key: RuntimeContext.Key {
            RuntimeContext.Key(runtimeAgentTargetID: runtimeAgentTargetID, contextID: id)
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
}
