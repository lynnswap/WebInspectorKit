package struct ProtocolTargetIdentifier: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
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

package struct DOMFrameIdentifier: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
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

package struct ExecutionContextID: RawRepresentable, Hashable, Codable, Sendable {
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

    package init(protocolType: String) {
        switch protocolType {
        case "page":
            self = .page
        case "frame":
            self = .frame
        case "worker":
            self = .worker
        case "service-worker":
            self = .serviceWorker
        default:
            self = .other(protocolType)
        }
    }
}

package struct ProtocolTargetCapabilities: OptionSet, Equatable, Hashable, Sendable {
    package let rawValue: UInt8

    package init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    package static let dom = Self(rawValue: 1 << 0)
    package static let runtime = Self(rawValue: 1 << 1)
    package static let target = Self(rawValue: 1 << 2)
    package static let inspector = Self(rawValue: 1 << 3)
    package static let network = Self(rawValue: 1 << 4)
    package static let css = Self(rawValue: 1 << 5)

    package static let pageDefault: Self = [.dom, .runtime, .target, .inspector, .network, .css]
    package static let frameDefault: Self = []
    package static let workerDefault: Self = [.runtime]
    package static let serviceWorkerDefault: Self = [.runtime, .network]

    package static func protocolDefault(for kind: ProtocolTargetKind) -> Self {
        switch kind {
        case .page:
            return .pageDefault
        case .frame:
            return .frameDefault
        case .worker:
            return .workerDefault
        case .serviceWorker:
            return .serviceWorkerDefault
        case .other:
            return []
        }
    }

    package init(domainNames: [String]) {
        var capabilities: Self = []
        for domainName in domainNames {
            switch domainName.lowercased() {
            case "dom":
                capabilities.insert(.dom)
            case "runtime":
                capabilities.insert(.runtime)
            case "target":
                capabilities.insert(.target)
            case "inspector":
                capabilities.insert(.inspector)
            case "network":
                capabilities.insert(.network)
            case "css":
                capabilities.insert(.css)
            default:
                break
            }
        }
        self = capabilities
    }
}

package struct ProtocolTargetRecord: Equatable, Sendable {
    package var id: ProtocolTargetIdentifier
    package var kind: ProtocolTargetKind
    package var frameID: DOMFrameIdentifier?
    package var parentFrameID: DOMFrameIdentifier?
    package var capabilities: ProtocolTargetCapabilities
    package var isProvisional: Bool
    package var isPaused: Bool

    package init(
        id: ProtocolTargetIdentifier,
        kind: ProtocolTargetKind,
        frameID: DOMFrameIdentifier? = nil,
        parentFrameID: DOMFrameIdentifier? = nil,
        capabilities: ProtocolTargetCapabilities = [],
        isProvisional: Bool = false,
        isPaused: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.frameID = frameID
        self.parentFrameID = parentFrameID
        self.capabilities = capabilities
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
