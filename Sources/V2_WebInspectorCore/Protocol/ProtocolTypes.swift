package struct ProtocolTargetIdentifier: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    package let rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package var description: String {
        rawValue
    }
}

package struct DOMFrameIdentifier: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    package let rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package var description: String {
        rawValue
    }
}

package struct ExecutionContextID: RawRepresentable, Hashable, Sendable {
    package let rawValue: Int

    package init(_ rawValue: Int) {
        self.rawValue = rawValue
    }

    package init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

package enum ProtocolTargetKind: Equatable, Sendable {
    case page
    case frame
    case worker
    case serviceWorker
    case other(String)
}

package struct ProtocolTargetRecord: Equatable, Sendable {
    package var id: ProtocolTargetIdentifier
    package var kind: ProtocolTargetKind
    package var frameID: DOMFrameIdentifier?
    package var parentFrameID: DOMFrameIdentifier?
    package var isProvisional: Bool
    package var isPaused: Bool

    package init(
        id: ProtocolTargetIdentifier,
        kind: ProtocolTargetKind,
        frameID: DOMFrameIdentifier? = nil,
        parentFrameID: DOMFrameIdentifier? = nil,
        isProvisional: Bool = false,
        isPaused: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.frameID = frameID
        self.parentFrameID = parentFrameID
        self.isProvisional = isProvisional
        self.isPaused = isPaused
    }
}

package struct ExecutionContextRecord: Equatable, Sendable {
    package var id: ExecutionContextID
    package var targetID: ProtocolTargetIdentifier
    package var frameID: DOMFrameIdentifier?

    package init(
        id: ExecutionContextID,
        targetID: ProtocolTargetIdentifier,
        frameID: DOMFrameIdentifier? = nil
    ) {
        self.id = id
        self.targetID = targetID
        self.frameID = frameID
    }
}
